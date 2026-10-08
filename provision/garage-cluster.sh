#!/usr/bin/env bash
# Runs once on the last node: joins all Garage nodes, applies the layout, creates buckets + access key.
set -euo pipefail
set -a; source /vagrant/.secrets/cluster.env; set +a
G="garage -c /etc/garage.toml"
BUCKETS="loki-chunks loki-ruler tempo-traces mimir-blocks mimir-ruler mimir-alertmanager pyroscope-data"

node_id() { # node id of the Garage daemon at $1 via its admin API
  curl -sf -H "Authorization: Bearer ${GARAGE_ADMIN_TOKEN}" "http://$1:3903/v2/GetNodeInfo?node=self" |
    jq -r '.success | keys[0]'
}

for ip in $ALL_NODE_IPS; do
  until id=$(node_id "$ip") && [ -n "$id" ] && [ "$id" != null ]; do echo "waiting for garage on $ip"; sleep 5; done
  $G node connect "${id}@${ip}:3901" || true
done

if [ "$($G layout show | grep -c 'dc1')" -lt 3 ]; then
  for ip in $ALL_NODE_IPS; do
    $G layout assign "$(node_id "$ip")" -z dc1 -c 400M -t "garage-${ip##*.}"
  done
  $G layout apply --version 1
fi

$G key info lgtm >/dev/null 2>&1 || $G key import --yes -n lgtm "$S3_ACCESS_KEY_ID" "$S3_SECRET_ACCESS_KEY"
for b in $BUCKETS; do
  $G bucket info "$b" >/dev/null 2>&1 || $G bucket create "$b"
  $G bucket allow --read --write --owner "$b" --key lgtm
done
$G status
$G bucket list
