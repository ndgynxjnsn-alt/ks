#!/usr/bin/env bash
# Provisions one node: data disks, Garage (S3), RKE2 server, kube-vip.
# Env from Vagrantfile: NODE_IP VIP FIRST_NODE LAST_NODE ALL_NODE_IPS RKE2_VERSION KUBEVIP_VERSION GARAGE_VERSION
set -euo pipefail
set -a; source /vagrant/.secrets/cluster.env; set +a

IFACE=$(ip -o -4 addr show | awk -v ip="$NODE_IP" '$4 ~ "^"ip"/" {print $2}')
echo ">>> $(hostname): node-ip $NODE_IP on $IFACE"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq jq curl gettext-base >/dev/null
cat >/etc/sysctl.d/90-lgtm.conf <<EOF
fs.inotify.max_user_instances = 1024
fs.inotify.max_user_watches = 1048576
EOF
sysctl --system >/dev/null

# ---------------------------------------------------------------- data disks
i=0
for dev in /dev/vd{b,c,d,e,f}; do
  i=$((i + 1))
  mnt=/srv/garage/data$i
  blkid "$dev" >/dev/null 2>&1 || mkfs.ext4 -q -L "garage$i" -m 0 "$dev"
  mkdir -p "$mnt"
  grep -q "LABEL=garage$i " /etc/fstab || echo "LABEL=garage$i $mnt ext4 defaults,noatime 0 2" >>/etc/fstab
done
systemctl daemon-reload
mount -a

# ---------------------------------------------------------------- Garage S3
if ! /usr/local/bin/garage --version 2>/dev/null | grep -q "${GARAGE_VERSION}"; then
  curl -sfL -o /usr/local/bin/garage \
    "https://garagehq.deuxfleurs.fr/_releases/${GARAGE_VERSION}/x86_64-unknown-linux-musl/garage"
  chmod +x /usr/local/bin/garage
fi
mkdir -p /var/lib/garage/meta
cat >/etc/garage.toml <<EOF
replication_factor = 3
metadata_dir = "/var/lib/garage/meta"
data_dir = [
  { path = "/srv/garage/data1", capacity = "80M" },
  { path = "/srv/garage/data2", capacity = "80M" },
  { path = "/srv/garage/data3", capacity = "80M" },
  { path = "/srv/garage/data4", capacity = "80M" },
  { path = "/srv/garage/data5", capacity = "80M" },
]
db_engine = "lmdb"
compression_level = 1

rpc_secret = "${GARAGE_RPC_SECRET}"
rpc_bind_addr = "[::]:3901"
rpc_public_addr = "${NODE_IP}:3901"

[s3_api]
api_bind_addr = "[::]:3900"
s3_region = "garage"
root_domain = ".s3.garage"

[admin]
api_bind_addr = "[::]:3903"
admin_token = "${GARAGE_ADMIN_TOKEN}"
metrics_token = "${GARAGE_ADMIN_TOKEN}"
EOF
chmod 600 /etc/garage.toml
cat >/etc/systemd/system/garage.service <<EOF
[Unit]
Description=Garage S3 object storage
After=network-online.target local-fs.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/garage -c /etc/garage.toml server
Restart=always
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now garage
systemctl restart garage
until garage -c /etc/garage.toml status >/dev/null 2>&1; do sleep 2; done

if [ "$LAST_NODE" = "true" ]; then
  /vagrant/provision/garage-cluster.sh
fi

# ---------------------------------------------------------------- RKE2
mkdir -p /etc/rancher/rke2 /var/lib/rancher/rke2/server/manifests
{
  echo "token: ${RKE2_TOKEN}"
  echo "node-ip: ${NODE_IP}"
  echo "tls-san: [\"${VIP}\", \"${NODE_IP}\"]"
  echo "write-kubeconfig-mode: \"0644\""
  [ "$FIRST_NODE" = "true" ] || echo "server: https://${VIP}:9345"
} >/etc/rancher/rke2/config.yaml

# Cluster add-ons that RKE2 applies itself from its manifests directory (same files on every server).
export VIP IFACE KUBEVIP_VERSION
for f in /vagrant/provision/manifests/*.yaml; do
  envsubst '${VIP} ${IFACE} ${KUBEVIP_VERSION}' <"$f" >"/var/lib/rancher/rke2/server/manifests/$(basename "$f")"
done

if ! command -v rke2 >/dev/null || ! rke2 --version | grep -q "${RKE2_VERSION}"; then
  curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION="${RKE2_VERSION}" sh -
fi
systemctl enable rke2-server
systemctl start rke2-server

cat >/etc/profile.d/rke2.sh <<'EOF'
export PATH=$PATH:/var/lib/rancher/rke2/bin
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export CONTAINERD_ADDRESS=/run/k3s/containerd/containerd.sock CONTAINERD_NAMESPACE=k8s.io
EOF

echo ">>> waiting for the API VIP ${VIP} (kube-vip)"
until curl -sfk "https://${VIP}:9345/ping" >/dev/null; do sleep 5; done
echo ">>> $(hostname) ready"
