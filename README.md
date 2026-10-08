# LGTM on a three-server HA RKE2 cluster

A highly available, on-premise-style Kubernetes cluster that runs the Grafana LGTM+P stack: Loki, Grafana,
Tempo, Mimir and Pyroscope, with Grafana Alloy as the single telemetry entry point. The three servers are
simulated with Vagrant/libvirt VMs. No cloud services are used.

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
| Grafana | 13.2.3 (chart 13.4.0) | 1 replica, stateless, fully provisioned |

## Prerequisites (host)

* KVM + libvirt + the `vagrant-libvirt` plugin, user in the `libvirt` group:
  `sudo apt install qemu-kvm libvirt-daemon-system libvirt-dev build-essential rsync && vagrant plugin install vagrant-libvirt`
* About 22 GB of free RAM (3 × 7 GB VMs) and about 30 GB of disk.
* Java isn't needed for the cluster. The demo app builds with the bundled Maven wrapper and any JDK ≥ 25. No
  Docker daemon is needed either: the image is built with Jib.
* `kubectl` and `helm` are downloaded into `.bin/` by `scripts/host-setup.sh`.

## Bring it up

```bash
vagrant up                 # ~15 min: VMs, disks, Garage cluster + buckets, RKE2 HA cluster, kube-vip
scripts/host-setup.sh      # kubectl/helm into .bin/, ./kubeconfig pointing at https://192.168.56.10:6443
scripts/deploy.sh          # Loki, Mimir, Tempo, Pyroscope, Alloy, Grafana, ingresses
scripts/demo.sh            # build the demo image, import it on all nodes, deploy it
source scripts/env.sh      # use kubectl/helm from your shell
```

Point the hostnames at the VIP in `/etc/hosts`:

```
192.168.56.10 grafana.org loki.org tempo.org mimir.org alloy.org pyroscope.org
```

| URL | What |
|---|---|
| http://grafana.org | Grafana (`admin`, password in `.secrets/cluster.env` → `GRAFANA_ADMIN_PASSWORD`) |
| http://grafana.org/drilldown | Metrics, Logs, Traces and Profiles Drilldown apps |
| http://alloy.org | Alloy UI. Also accepts OTLP/HTTP (`/v1/traces`, `/v1/metrics`, `/v1/logs`) and Pyroscope pushes (`/ingest`) from outside the cluster |
| http://loki.org, http://mimir.org, http://tempo.org, http://pyroscope.org | Backend HTTP APIs (Pyroscope has its own UI) |

All secrets (RKE2 token, Garage keys, Grafana password) are generated on the first `vagrant up` into
`.secrets/cluster.env`, which git ignores.

## Repository layout

```
Vagrantfile                      3 VMs, 5 extra disks each, private network 192.168.56.0/24
provision/node.sh                disks → Garage → RKE2 server config → RKE2 install
provision/garage-cluster.sh      Garage layout, access key, buckets (runs once, on the last node)
provision/manifests/             applied by RKE2 itself: kube-vip, canal interface, local-path storage
k8s/values/*.yaml                Helm values (credentials are ${placeholders}, filled by deploy.sh)
k8s/ingress.yaml                 Traefik ingresses for *.org
k8s/demo.yaml                    demo app
apps/demo/                       Spring Boot 4 demo app
scripts/                         host-setup.sh, deploy.sh, demo.sh, env.sh
docs/s3-storage.md               S3 storage research and decision (Garage)
```

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
| Grafana | stateless and fully provisioned. It reschedules after 30 s like Tempo. Use an external database to run several replicas |
| Alloy | DaemonSet. The Service routes OTLP to any live instance |

Stateful pods with local-path volumes (Loki, Mimir, Pyroscope) stay `Pending` until their node returns. The
other two replicas carry the load in the meantime.

Notes:

* Garage is reached through the VIP. If Garage alone dies on the node that currently holds the VIP,
  S3 calls fail until the VIP moves (`systemctl restart garage` or move the VIP). In production, use a DNS name with all
  three node IPs or a small HAProxy instead.
* With 3 etcd members, losing **two** servers makes the API read-only and unavailable. That's inherent to quorum.

## From the lab to a real cluster

* Replace the Vagrant private network with your server network. Pick a free VIP in that subnet and set it in
  `Vagrantfile` / `scripts/env.sh`. In production, provision the same `provision/node.sh` steps with your
  configuration management.
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
