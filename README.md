# LGTM on a three-server HA RKE2 cluster

A highly available, on-premise-style Kubernetes cluster that runs the Grafana LGTM+P stack: Loki, Grafana,
Tempo, Mimir and Pyroscope, with Grafana Alloy as the single telemetry entry point. The three servers are
simulated with Vagrant/libvirt VMs and set up with Ansible. No cloud services are used.

**The servers are fully offline.** They have no internet access: the libvirt networks are isolated. Everything
they need is downloaded once onto the Ansible host (`artifacts/`), then installed from there:

* RKE2 installs in tarball mode with its air-gap image bundles.
* All other container images are pre-loaded into containerd.
* The Helm charts are deployed from local `.tgz` files.

```
                         host: /etc/hosts  *.org -> 192.168.56.10 (VIP)
                                              │
        ┌──────────── kube-vip (ARP leader election) moves the VIP between servers ──────────┐
        │  :6443 Kubernetes API   :9345 RKE2 join   :80/:443 Traefik (hostPort)  :3900 Garage S3 │
        ▼                                     ▼                                     ▼
  lgtm1 192.168.56.11               lgtm2 192.168.56.12                 lgtm3 192.168.56.13
  RKE2 server (etcd, CP, worker)    RKE2 server (etcd, CP, worker)      RKE2 server (etcd, CP, worker)
  Garage (5 × 100 MB disks)         Garage (5 × 100 MB disks)           Garage (5 × 100 MB disks)

  namespace lgtm:  loki ×3 (RF 3) · mimir ×3 (RF 3) · pyroscope ×3 (raft) · tempo ×1 · grafana ×1 · alloy (DaemonSet)
  namespace demo:  shop ×2 ──HTTP──▶ inventory ×2      (Spring Boot + OTel Java agent + Pyroscope)
```

| Component | Version | Mode / HA |
|---|---|---|
| RKE2 | v1.37.1+rke2r1 | 3 servers, embedded etcd (quorum 2/3), all schedulable |
| kube-vip | v1.2.4 | DaemonSet, ARP, VIP `192.168.56.10` |
| Traefik | bundled with RKE2 (default ingress since v1.36) | DaemonSet with hostPort 80/443 |
| Garage (S3) | v2.4.1 | systemd on every VM, replication factor 3, see [docs/s3-storage.md](docs/s3-storage.md) |
| Loki | 3.7.8 (chart 18.15.0) | monolithic, 3 replicas, replication factor 3 |
| Mimir | 3.2.2 ([NGDATA fork](https://github.com/NGDATA/mimir) chart 6.0.6) | monolithic, 3 replicas, replication factor 3 |
| Tempo | 3.1.0 (chart 3.1.0) | monolithic, 1 replica (see below) |
| Pyroscope | 2.3.2 (chart 2.3.2) | monolithic (v2 storage), 3 replicas, raft metastore |
| Alloy | 1.20.1 (chart 1.13.1) | DaemonSet |
| Grafana | 13.2.3 (chart 13.4.0) | 1 replica, stateless, fully provisioned; image with the Drilldown apps baked in |

## Prerequisites (host)

* KVM + libvirt + the `vagrant-libvirt` plugin, user in the `libvirt` group:
  `sudo apt install qemu-kvm libvirt-daemon-system libvirt-dev build-essential rsync && vagrant plugin install vagrant-libvirt`
* About 22 GB of free RAM (3 × 7 GB VMs) and about 30 GB of disk.
* Ansible ≥ 2.16 with the collections `ansible.posix`, `community.general` and `kubernetes.core`, plus `zstd`, `unzip` and `git`.
* Internet access on the host, for `download.yml` only.
* Java isn't needed for the cluster. The demo app builds with the bundled Maven wrapper and any JDK ≥ 25.
  No Docker daemon is needed: container images are fetched with `crane` and built with Jib/`crane append`.

## Bring it up

```bash
ansible-playbook ansible/download.yml   # host, online: RKE2 tarballs, charts, images, plugins → artifacts/ (~3 GB)
vagrant up                             # 3 bare VMs on isolated networks
ansible-playbook ansible/site.yml      # offline: disks, Garage cluster + buckets, RKE2 HA + kube-vip, ./kubeconfig
ansible-playbook ansible/lgtm.yml      # Loki, Mimir, Tempo, Pyroscope, Alloy, Grafana, ingresses
ansible-playbook ansible/demo.yml      # build the demo image (host), load it on the nodes, deploy it
source scripts/env.sh                  # kubectl/helm from artifacts/bin with ./kubeconfig
```

All playbooks are idempotent. Re-run `lgtm.yml` after changing anything in `k8s/`.

Point the hostnames at the VIP in `/etc/hosts`:

```
192.168.56.10 grafana.org loki.org tempo.org mimir.org alloy.org pyroscope.org
```

| URL | What |
|---|---|
| http://grafana.org | Grafana (`admin`, password in `.secrets/grafana_admin_password`) |
| http://grafana.org/drilldown | Metrics, Logs, Traces and Profiles Drilldown apps |
| http://alloy.org | Alloy UI. Also accepts OTLP/HTTP (`/v1/traces`, `/v1/metrics`, `/v1/logs`) and Pyroscope pushes (`/ingest`) from outside the cluster |
| http://loki.org, http://mimir.org, http://tempo.org, http://pyroscope.org | Backend HTTP APIs (Pyroscope has its own UI) |

Ansible generates all secrets (RKE2 token, Garage keys, Grafana password) on first use, one file each in
`.secrets/`. Git ignores that directory.

## Repository layout

```
Vagrantfile                      3 bare VMs, 5 extra disks each, isolated networks (no internet)
ansible.cfg
ansible/inventory.yml            the three nodes (copy for real servers)
ansible/group_vars/all.yml       versions, VIP, secrets (generated into .secrets/)
ansible/download.yml             host: fetch everything into artifacts/ (the only online step)
ansible/site.yml                 nodes: roles garage + rke2, fetch ./kubeconfig
ansible/roles/garage/            disks → ext4 → Garage systemd service; cluster layout, key, buckets
ansible/roles/rke2/              tarball install, image preload, config, kube-vip / canal / local-path manifests
ansible/lgtm.yml                 Helm releases from artifacts/charts + ingresses
ansible/demo.yml                 build + load + deploy the demo app
k8s/values/*.yaml                Helm values (S3 credentials and the Grafana password are added by lgtm.yml)
k8s/ingress.yaml                 Traefik ingresses for *.org
k8s/demo.yaml                    demo app
apps/demo/                       Spring Boot 4 demo app
docs/s3-storage.md               S3 storage research and decision (Garage)
```

## Offline installation

`download.yml` fills `artifacts/` (git ignores it). Copy that directory to the Ansible host of an air-gapped site:

| Directory | Contents | Used by |
|---|---|---|
| `rke2/` | `install.sh`, `rke2.linux-amd64.tar.gz`, checksums, `rke2-images-core` + `rke2-images-canal` bundles | `INSTALL_RKE2_ARTIFACT_PATH` tarball install |
| `images/` | every image the charts and manifests reference, found by `helm template`, pulled with `crane` as `.tar.zst` | copied to `/var/lib/rancher/rke2/agent/images/`, imported by RKE2 at start |
| `charts/` | Helm charts, including the packaged NGDATA Mimir chart | `lgtm.yml` |
| `bin/` | `garage`, `helm`, `kubectl`, `crane` | nodes (`garage`) and the Ansible host |
| `plugins/` | Grafana Drilldown apps | baked into `lgtm.local/grafana:13.2.3-drilldown` via `crane append` |

Images that exist only locally are named `lgtm.local/…` and use `imagePullPolicy: Never`. These are Grafana
with the plugins and the demo app. Everything else uses `IfNotPresent` with pinned tags, so kubelet never
contacts a registry.

## Data flow

```
demo app ── OTel Java agent ── OTLP/HTTP ─▶ Alloy :4318 ─┬─▶ Tempo     (traces)
         │   (traces, metrics + exemplars,                ├─▶ Mimir /otlp (metrics, exemplars)
         │    logs with trace_id/span_id)                 └─▶ Loki  /otlp (logs, structured metadata)
         └─ Pyroscope agent (in the OTel extension) ─▶ Alloy :9999 ─▶ Pyroscope (profiles with span_id)
all pods' stdout (except demo) ── Alloy (/var/log/pods) ─▶ Loki
Tempo metrics-generator (service graph, span metrics) ──▶ Mimir
Loki · Mimir · Tempo · Pyroscope ──▶ Garage S3 (via VIP :3900)
```

Grafana's datasources are linked to each other:
trace → logs (by trace id), trace → metrics, trace → CPU profile of the span, metric exemplar → trace,
log line → trace (`trace_id` structured metadata), and Tempo's service map from Mimir.

### The demo app

`apps/demo` is one Spring Boot 4.1 image deployed twice:

* **shop** runs a load generator (2 orders/s) and serves `/api/orders/{item}`. It calls **inventory**
  and computes a price in a CPU-heavy `@WithSpan("calculate-price")` method.
* **inventory** serves `/api/inventory/{item}` with random latency (the item `anvil` is slow) and about 5% HTTP 503 errors.

Instrumentation:

* **OpenTelemetry Java agent** 2.32.0: automatic traces (Spring MVC, RestClient, `@Scheduled`), logs from
  Logback with trace context, and metrics. HTTP duration histograms carry exemplars.
* **OTel API bridge**: the app only depends on `opentelemetry-instrumentation-annotations`.
  `@WithSpan`, `@SpanAttribute` and `Span.current()` are bridged into the agent's SDK at runtime. Micrometer
  meters (`shop.orders`) are bridged to OTel metrics through `OTEL_INSTRUMENTATION_MICROMETER_ENABLED`.
* **Pyroscope**: the `pyroscope-otel-javaagent-extension` 2.1.4 (Grafana's otel-profiling-java) bundles the
  Pyroscope Java agent and starts it. It also labels CPU samples with span ids, which enables
  "Profiles for this span" in Tempo.

## Fault tolerance

Stop any one VM with `vagrant halt lgtm2` (or `virsh destroy`). This is what keeps working:

| Layer | Why it survives one node loss |
|---|---|
| Kubernetes API | etcd quorum 2/3; kube-vip moves the VIP to a surviving server (measured 9–52 s: etcd must re-elect before the kube-vip lease can move) |
| Ingress | Traefik runs on every node via hostPort, and the VIP follows a live node |
| S3 | Garage stores 3 copies and serves reads and writes with 2 of 3 nodes |
| Loki / Mimir | 3 replicas, replication factor 3, quorum writes and reads on 2 of 3 |
| Pyroscope | raft metastore with 3 members (quorum 2), segment writers on every replica |
| Tempo | **single instance** (Tempo 3 monolithic doesn't support more than one `-target=all`). It runs without a PVC and tolerates an unreachable node for only 30 s, so it reschedules quickly. Traces still buffered in its WAL at that moment are lost. Already stored traces are in S3. For real HA, use `tempo-distributed` |
| Grafana | stateless and fully provisioned. It reschedules after 30 s like Tempo, and starts fast because the plugins are in the image. Use an external database to run several replicas |
| Alloy | DaemonSet. The Service routes OTLP to any live instance |

Stateful pods with local-path volumes (Loki, Mimir, Pyroscope) stay `Pending` until their node returns. The
other two replicas carry the load in the meantime.

Notes:

* Garage is reached through the VIP. If Garage alone dies on the node that currently holds the VIP,
  S3 calls fail until the VIP moves (`systemctl restart garage` or move the VIP). In production, use a DNS name with all
  three node IPs or a small HAProxy instead.
* With 3 etcd members, losing **two** servers makes the API read-only and unavailable. That's inherent to quorum.

## From the lab to a real cluster

* Write an inventory for your servers (address, user, key) and set `vip` in `ansible/group_vars/all.yml` to a free
  address in their subnet. The Garage roles expect data disks `vdb`–`vdf`: change `garage_disks` in
  `ansible/roles/garage/defaults/main.yml`.
* Use real DNS records (`grafana.example.org` …) for the VIP, and add TLS in Traefik (cert-manager, or a
  `default` TLSStore with your certificate).
* Data disks: see the sizing notes in [docs/s3-storage.md](docs/s3-storage.md). The local-path PVCs (WALs) live on the root disk under
  `/opt/local-path-provisioner`.
* Retention is 7 days for all signals (`k8s/values/*.yaml`).

## Useful commands

```bash
source scripts/env.sh
kubectl -n lgtm get pods -o wide
vagrant ssh lgtm1 -c 'sudo garage -c /etc/garage.toml status'
kubectl -n kube-system get lease plndr-cp-lock -o jsonpath='{.spec.holderIdentity}'   # current VIP holder
```
