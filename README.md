# LGTM on a three-server HA RKE2 cluster

A highly available, on-premise Kubernetes cluster that runs the Grafana LGTM+P stack: Loki, Grafana,
Tempo, Mimir and Pyroscope, with Grafana Alloy as the single telemetry entry point.

* **Offline nodes.** The servers need no internet access. Everything is downloaded once onto the Ansible host
  (`artifacts/`):
  * RKE2 is installed in tarball mode.
  * Container images and Helm charts are pushed to the company's **artifact repository** (Sonatype Nexus).
    The nodes pull images from it and Argo CD reads the charts from it.
* **GitOps.** Ansible prepares the servers and bootstraps **Argo CD**. Argo CD deploys the rest from Git as an
  *app of apps*.
* **Lab and real site are separated.** `lab/` simulates the servers with Vagrant/libvirt VMs and runs stand-ins for
  company services: CA, DNS, IdP, Git, Nexus. The playbooks in `ansible/` are the same for the lab and a real site. Only the
  inventory differs.

```
             DNS: *.lgtm.company.org -> ingress VIP                     Kubernetes API -> control-plane VIP
                          │                                                         │
   ┌───── kube-vip (ARP): two floating IPs, each moves to a surviving server ───────┴────────────────┐
   │  ingress VIP  :80/:443  Traefik -> grafana|loki|tempo|mimir|pyroscope|alloy|faro|garage|argocd|headlamp|pgbackweb │
   │               :5432     Grafana's PostgreSQL (TCP passthrough)                                                 │
   │  control-plane VIP  :6443 API, :9345 RKE2 join                                                     │
   ▼                                   ▼                                   ▼
 server 1                           server 2                           server 3
 RKE2 server (etcd, CP, worker)     RKE2 server (etcd, CP, worker)     RKE2 server (etcd, CP, worker)
 Garage S3 (data disks)             Garage S3 (data disks)             Garage S3 (data disks)
 TopoLVM VG (1 disk)                TopoLVM VG (1 disk)                TopoLVM VG (1 disk)

 argocd:  Argo CD  ── app of apps (argocd/root) ──▶ everything below
 lgtm:    loki ×3 · mimir ×3 · pyroscope ×3 · tempo ×1 · alloy (DaemonSet) · grafana ×2 · postgres ×3 (CloudNativePG)
          · pgbackweb ×1
 demo:    shop ×1 ──HTTP──▶ inventory ×1      (Spring Boot + OTel Java agent + Pyroscope)

 outside: Nexus (images, charts) · Git: this repo (Argo CD) + Grafana's dashboard repo (Git Sync) · IdP · CA · DNS
```

| Component | Version | Mode / HA |
|---|---|---|
| RKE2 | v1.37.1+rke2r1 | 3 servers, embedded etcd (quorum 2/3), all schedulable, air-gap tarball install |
| kube-vip | v1.3.1 | DaemonSet, ARP: control-plane VIP + one LoadBalancer IP for Traefik |
| Traefik | bundled with RKE2 | DaemonSet. Routes `*.<domain>` by Host header, http + https |
| Argo CD | 3.5.5 (chart 10.10.5) | app of apps from Git + Helm repository, automatic sync, prune, self-heal |
| cert-manager | v1.21.2 | one certificate per hostname (ACME + EAB, HTTP-01), automatic renewal |
| Garage (S3) | v2.4.1 | systemd on every server, replication factor 3, see [docs/s3-storage.md](docs/s3-storage.md) |
| Loki | 3.7.9 (chart 19.0.3) | monolithic, 3 replicas, replication factor 3, multi-tenant |
| Mimir | 3.2.3 ([NGDATA fork](https://github.com/NGDATA/mimir) chart 6.0.6) | monolithic, 3 replicas, replication factor 3, multi-tenant |
| Tempo | 3.1.1 (chart 3.2.1) | monolithic, 1 replica (see [Fault tolerance](#fault-tolerance)), multi-tenant |
| Pyroscope | 2.4.1 (chart 2.4.1) | monolithic (v2 storage), 3 replicas, raft metastore, multi-tenant |
| Alloy | 1.21.1 (chart 1.14.2) | DaemonSet: OTLP, profiles, pod logs, OTLP/JSON import, cluster metrics |
| Grafana | 13.2.4 (chart 14.0.1) | 2 replicas on PostgreSQL, one org per tenant, OAuth; Drilldown apps baked into the image |
| CloudNativePG | operator 1.30.1, PostgreSQL 18.6 | Grafana's database, 3 instances, automatic failover |
| Barman Cloud plugin | 0.15.1 (chart 0.8.1) | CloudNativePG backups: WAL archive + daily base backup to Garage, 7 days |
| PG Back Web | 0.5.2 | web UI for pg_dump backups (Garage, 7 days) and restores of Grafana's database |
| Sonatype Nexus (lab) | 3.98.0 Community | stand-in for the company's artifact repository: Docker + Helm hosted repositories |
| kube-state-metrics | 2.20.0 (chart 8.6.0) | object state for the "Cluster health" dashboard |
| TopoLVM | 0.42.0 (chart 17.3.0) | local PersistentVolumes from an LVM volume group per server; default StorageClass |
| Headlamp | 0.46.0 (chart 0.46.0) | Kubernetes web UI |
| trace-pong | 1.3.0 (Grafana panel plugin, unsigned) | live service traffic from Tempo traces on the service graph (dashboard "Live traffic") |
| OS | Ubuntu 26.04 LTS | `sudo-rs` replaced by classic sudo (Ansible's become can't drive sudo-rs) |

## Repository layout

```
ansible/                          the playbooks - identical for the lab and a real site
  site.yml                        servers: sudo, TopoLVM VG, Garage, OTLP/JSON import dirs, RKE2 + kube-vip, kubeconfig
  lgtm.yml                        Secrets, push repo, Argo CD, root Application, Grafana orgs + Git Sync, PG Back Web
  demo.yml                        build the demo image, push it to the artifact repository
  download.yml                    the only online step: RKE2 tarballs, charts, images, plugins -> artifacts/
  publish.yml                     artifacts/images + charts -> artifact repository (Nexus)
  disks.yml                       lists/benchmarks the servers' disks, suggests topolvm_disk (read-only)
  group_vars/all.yml              site-independent settings: versions, charts, generated secrets
  roles/garage, rke2, topolvm, otel_import
  tasks/                          apply-set (apply + prune), gitops-publish, grafana-*, pgbackweb
  templates/                      secrets, root Application, Grafana datasources
argocd/
  root/                           app of apps: one Argo CD Application per component
  platform/                       ingress VIP, ingresses, TLS, Grafana database + backups, PG Back Web
grafana/dashboards/               first content of Grafana's Git repository (not deployed from here)
certs/                            trusted CA certificates (*.pem, *.crt) -> trust-manager -> every namespace
k8s/values/                       Helm values of every chart (no secrets)
k8s/alloy/                        Alloy pipeline (config.alloy) and the OTLP/JSON import script
k8s/argocd/                       Argo CD resource health check (Lua), login page styles
k8s/demo/                         demo app manifests
apps/demo/                        Spring Boot demo app
inventories/example/              template for a real site (all site settings)
lab/                              LAB ONLY
  Vagrantfile                     3 Ubuntu 26.04 VMs, 5 data disks each, isolated networks
  inventory/                      lab servers + lab site settings
  external.yml, external/         stand-in company services (docker compose): Keycloak, Pebble, BIND, Gitea, Nexus
  tasks/, templates/              their setup and configuration (Nexus API, Grafana repo, Keycloak realm, ...)
examples/                         apps outside the cluster; alerting-matrix/ (untested sketch)
docs/s3-storage.md                S3 storage research and decision (Garage)
```

## Prerequisites (Ansible host)

* Ansible ≥ 2.16 and `ansible-galaxy collection install -r requirements.yml`, `sshpass` (password login),
  `zstd`, `unzip`, `git`, `jq`. Internet access is only needed for `download.yml` and the demo build.
* No Docker daemon for the cluster: images are fetched with `crane` and built with Jib/`crane append`.
* Lab: KVM + libvirt + `vagrant-libvirt` (user in group `libvirt`), about 20 GB free RAM (3 × 6 GB VMs plus
  ~1.5 GB for Nexus; the Docker Swarm examples need another 6 GB, 3 × 2 GB, which no longer fits next to the cluster
  in 32 GB), and Docker with compose for the stand-in services (user in group `docker`, or
  `-e lab_docker_sudo=true -K`).

## Bring it up (lab)

```bash
ansible-playbook ansible/download.yml                        # online: everything into artifacts/ (~3 GB)
(cd lab && vagrant destroy -f)                               # optional: start from scratch
(cd lab && vagrant up)                                       # 3 bare VMs on isolated networks
ansible-playbook -i lab/inventory lab/external.yml           # Keycloak, Pebble (CA), BIND (DNS), Gitea (Git), Nexus
ansible-playbook -i lab/inventory ansible/publish.yml        # images + charts -> Nexus
ansible-playbook -i lab/inventory ansible/disks.yml          # optional: the servers' disks, TopoLVM suggestion
ansible-playbook -i lab/inventory ansible/site.yml           # offline: TopoLVM, Garage, RKE2 HA + kube-vip, ./kubeconfig
ansible-playbook -i lab/inventory ansible/lgtm.yml           # Argo CD + app of apps -> the whole stack
ansible-playbook -i lab/inventory ansible/demo.yml           # demo image -> Nexus (Argo CD deploys the app)
(cd examples && docker compose up -d --build)                # optional: example apps on this machine (examples/)
source scripts/env.sh && k9s                                 # kubectl/helm/k9s with ./kubeconfig
```

Hosts file on the lab host, or use the lab DNS (`dig @192.168.56.1 -p 10053 grafana.lgtm.company.org`):

```
192.168.56.1  keycloak.company.org
192.168.56.20 grafana.lgtm.company.org loki.lgtm.company.org tempo.lgtm.company.org mimir.lgtm.company.org
192.168.56.20 pyroscope.lgtm.company.org alloy.lgtm.company.org garage.lgtm.company.org argocd.lgtm.company.org
192.168.56.20 headlamp.lgtm.company.org faro.lgtm.company.org postgres.lgtm.company.org pgbackweb.lgtm.company.org
```

| URL | What |
|---|---|
| https://grafana.lgtm.company.org | Grafana: goes straight to Keycloak. Local `admin` / `.secrets/grafana_admin_password` at `/login?disableAutoLogin=true` |
| https://argocd.lgtm.company.org | Argo CD: "Log in via Keycloak", or local `admin` / Secret `argocd/argocd-initial-admin-secret` |
| https://pgbackweb.lgtm.company.org | PG Back Web: `admin@lgtm.company.org` / `.secrets/pgbackweb_admin_password` |
| https://headlamp.lgtm.company.org | Headlamp (Kubernetes UI): token from `kubectl -n headlamp create token headlamp` |
| https://faro.lgtm.company.org/&lt;tenant&gt;/collect | Grafana Faro receiver for browser apps |
| postgres.lgtm.company.org:5432 | Grafana's PostgreSQL (see [below](#grafanas-postgresql-from-outside-the-cluster)) |
| https://alloy.lgtm.company.org | Alloy UI. Also accepts OTLP/HTTP (`/v1/*`) and Pyroscope pushes (`/ingest`) |
| https://{loki,mimir,tempo,pyroscope,garage}.lgtm.company.org | backend APIs (multi-tenant: send `X-Scope-OrgID`) |
| http://192.168.56.1:8091 | Nexus (lab): `admin` / `.secrets/nexus_admin_password`; Docker registry on `:8092` |
| https://192.168.56.1:3000 | Gitea (lab): `lgtm` / `.secrets/gitea_password`; repositories `lgtm` and `grafana` |

Everything is also served on plain http. Secrets are generated on first use, one file each in `.secrets/`
(ignored by git).

## Helm charts and compliance

`download.yml` pulls every chart from its **OCI** registry where the publisher provides one, and writes
`artifacts/helm-charts-oci.txt`: chart, version, `oci://` reference and manifest digest. Two charts have no OCI
artifact:
* **Alloy** is only published to the HTTPS repository `https://grafana.github.io/helm-charts`.
* **Mimir** comes from the NGDATA fork and is packaged from Git; the file records the commit.

Versions are in `ansible/group_vars/all.yml` (`charts`).

## A real site

Copy `inventories/example` to `inventories/<site>`, then fill in:

* the servers;
* two free IPs;
* the domain;
* the company CA (ACME URL and EAB credentials);
* the IdP, with two OAuth clients (Grafana, Argo CD);
* the hosts of the company services: `nexus_host` (artifact repository) and `git_host` (Git server), e.g.
  `nexus.company.org`. The lab sets both to the Ansible host's IP (`lab_host_ip`), where the stand-ins run;
* the artifact repository (`registry`: Docker registry for the nodes, Helm repository for Argo CD);
* the Git repository Argo CD reads from, and Grafana's own repository (`grafana_git_sync`);
* per server in `hosts.yml`: `topolvm_disk` (run `disks.yml` to see the disks).

Keep secrets in ansible-vault. Then run `download.yml`, `publish.yml`, `site.yml` and `lgtm.yml` with
`-i inventories/<site>`.

Requirements on the servers:
* Ubuntu 26.04.
* An admin user with sudo.
* Unpartitioned data disks for Garage. **Every unpartitioned whole disk is wiped on every `site.yml` run.**
  Remove the reset steps from `ansible/roles/garage/tasks/main.yml` once the cluster holds real data.

## Deployment: Ansible bootstraps, Argo CD deploys

`ansible/lgtm.yml` runs these steps:
1. Creates all **Secrets** (`ansible/templates/secrets.yaml.j2`): S3 keys, Grafana admin and OAuth client,
   ACME EAB key, Garage metrics token, and repository credentials. The values in Git only reference
   them. Loki, Mimir, Tempo and Pyroscope read the S3 keys from environment variables (`-config.expand-env`).
2. **Publishes** (lab, `gitops.publish`): pushes the committed `HEAD` to Gitea. At a company, CI does this. The
   charts are already in the Helm repository (`publish.yml`).
   **Argo CD deploys what is committed**, and the playbook warns about uncommitted changes.
3. Installs **Argo CD** with Helm (the only Helm install).
4. Creates the root Application `lgtm`. It renders `argocd/root` with the site values from the inventory into one
   Application per component. Each one combines an upstream chart from the Helm repo with its values file from Git
   (`k8s/values/<name>.yaml`) and a site overlay. Sync waves order them:

   | Wave | Apps |
   |---|---|
   | −3 | cert-manager, CloudNativePG + its Barman Cloud plugin (CRDs) |
   | −2 | trust-manager, TopoLVM; `argocd/platform`: ingress VIP Service, Garage endpoints, ingresses (one certificate each), ClusterIssuer, PostgreSQL cluster + backups, PG Back Web |
   | −1 | `certs`: the CA bundle from `certs/` |
   | 0 | Loki, Mimir, Tempo, Pyroscope, kube-state-metrics |
   | 1 | Alloy, Grafana |
   | 2 | demo |

   Applications sync automatically with prune and self-heal. Argo CD's health check for `Application`
   (`k8s/values/argocd.yaml`) lets each wave wait for the previous one.
5. Waits until every Application is synced and healthy, except apps marked `wait: false` (the demo: its image
   arrives with `demo.yml` afterwards). It first prints which apps it waits for and which not, then the
   sync/health state of every app (with Argo CD's message for those that aren't `Synced/Healthy`). After 30
   minutes it fails and names the apps that didn't get ready:
   ```
   Not synced and healthy after 30 minutes: mimir (Synced/Progressing: Waiting for rollout to finish ...)
   ```
   Then it creates the Grafana org per tenant through the API, connects every org to its directory of
   Grafana's Git repository (Git Sync), and sets up PG Back Web (login, database, S3 destination, daily backup).

To change something, edit, commit and run `lgtm.yml` again, or just push when Argo CD reads your Git server.
Clusters set up by earlier versions with plain Helm migrate in place: the Helm release records are deleted and
Argo CD adopts the resources.

### Re-running

All playbooks can be re-run, and a re-run applies new settings:
* `lgtm.yml` applies its Secrets and the root app as labelled sets and deletes what is no longer rendered.
  Argo CD prunes everything else; for example, a hostname removed from `lgtm_hosts` removes its ingresses.
* `publish.yml` pushes only images and charts the artifact repository doesn't have; a chart version is never
  overwritten.
* `site.yml`: partial runs `--tags otel-import` (import directories) and `--tags buckets` (new buckets of
  `garage_buckets`, without the Garage reset).
* `demo.yml` pushes the image and restarts the pods only when its digest changed.
* Exception: `site.yml` **resets Garage** on every run.

## Artifact repository (Nexus)

The nodes pull **every** image (except RKE2's own, which come with its air-gap bundles) from the artifact
repository. `publish.yml` pushes `artifacts/images/*` as `<registry.host>/<source registry>/<path>:<tag>`, e.g.
`docker.io/grafana/loki:3.7.9` becomes `192.168.56.1:8092/docker.io/grafana/loki:3.7.9`. `site.yml` writes
`/etc/rancher/rke2/registries.yaml`: one containerd mirror per source registry with a rewrite to that prefix.
So the manifests keep their upstream image names, and images built here (`lgtm.local/grafana`,
`lgtm.local/demo`) work the same way.

```yaml
registry:
  host: nexus.company.org:5000     # Docker API of the hosted repository
  ca_file: certs/company-root.crt  # https with a company CA (lab: insecure: true, plain http)
  username: ...                    # pull credentials, if anonymous read is off
  publish: { helm_upload_url: https://nexus.company.org/repository/lgtm-helm/, username: ..., password: ... }
gitops:
  helm_repo_url: https://nexus.company.org/repository/lgtm-helm/
```

Lab: Nexus 3.98 Community runs in `lab/external` (UI `:8091`, Docker `:8092`). `lab/external.yml` sets it up
through the REST API: repositories `lgtm-docker` and `lgtm-helm`, anonymous read, user `lgtm` (role
`lgtm-publisher`) for pushing. The Community Edition has usage limits (components, requests per day); a company
Nexus Pro or Harbor works the same way.

## Storage: TopoLVM

PersistentVolumes (Loki, Mimir, Pyroscope, Grafana's PostgreSQL) are logical volumes on the server where the
pod runs. **TopoLVM** carves them from the volume group `topolvm`. `site.yml` (`ansible/roles/topolvm`) creates
that volume group on one whole disk per server. Garage takes every other empty disk.

**Which disk?** Every server has its own disks, so `topolvm_disk` is set **per host** in `hosts.yml` (or
`host_vars/`): a name from `/dev/disk/by-id/` of that server (stable across reboots, unlike `sda`/`nvme0n1`), or
a full path.

```yaml
server1: { ansible_host: 10.0.10.11, topolvm_disk: nvme-Micron_7450_MTFDKBA960TFR_2223XXXXXXXX }
```

`ansible-playbook -i <inventory> ansible/disks.yml` lists every disk of every server: size, SSD/HDD, transport,
model, what uses it (OS, TopoLVM, Garage, free) and its by-id names. It suggests a disk per server.
`-e benchmark=true` adds a read-only benchmark (4 KiB random reads for latency, 1 MiB sequential reads for
throughput, ~8 s per disk).

* **Faster than Garage: yes.** TopoLVM holds the hot path. Loki's, Mimir's and Pyroscope's ingesters write their
  WAL and head blocks there with an fsync on every write, and PostgreSQL commits there. That load is
  latency-bound and small: about 7 GB per server with the default sizes. Use the fastest disk (NVMe/SSD), not
  the biggest.
* **Garage gets the big, slower disks.** It stores compacted chunks and blocks: written in large batches, read
  for queries over older data. That load is throughput- and capacity-bound, and HDDs are fine.
* **Not the OS disk.** etcd lives there (`/var/lib/rancher`) and needs low fsync latency. Ingester WALs on the
  same disk delay etcd writes, which leads to leader elections and an unstable API. The role also only takes
  whole disks.
* StorageClass `topolvm` is the default: `WaitForFirstConsumer`, so the volume is created on the node the pod
  is scheduled to, which TopoLVM picks by free space (storage capacity tracking). Volumes can be expanded.
* The volume group is created once and kept on re-runs; the disk is **not** wiped again.
* A disk that already holds something (a filesystem, partitions, another volume group, e.g. because Garage
  formatted it before it became the TopoLVM disk) is refused with a message saying what is on it.
  `site.yml -e force_disk_format=true` unmounts it, removes its fstab entries and wipes it. A disk that already
  is the TopoLVM volume group is never wiped, even with the flag.
* `local-path` (RKE2) is still installed, but no longer the default.
* Volumes are local: if a server is lost, so are its volumes. The workloads replicate (replication factor
  3, CloudNativePG replicas).

Lab: each VM has a 20 GB disk with the serial `topolvm` (`topolvm_disk: virtio-topolvm` per host).

## Headlamp

Kubernetes web UI at https://headlamp.<domain>. Log in with a ServiceAccount token, e.g. the chart's
cluster-admin account:

```bash
kubectl -n headlamp create token headlamp --duration 8h
```

## Grafana's PostgreSQL from outside the cluster

With `grafana_db_external: true`, port **5432 of the ingress VIP** leads to the primary of Grafana's
PostgreSQL (CloudNativePG, Service `grafana-db-rw`). Traefik has a TCP entrypoint `postgres` that passes the
connection through untouched.

**Does it need a hostname like `postgres.<domain>`?** Not for routing. PostgreSQL starts in plain text and
switches to TLS inside its own protocol, so a proxy can't read a hostname (SNI) from the connection. It can
only route by port: one database per port. `postgres.<domain>` works as a name anyway, because DNS
`*.<domain>` already points to the ingress VIP. The server certificate also contains `postgres.<domain>`, so
`verify-full` works with the cluster's CA:

```bash
kubectl -n lgtm get secret grafana-db-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > grafana-db-ca.crt
kubectl -n lgtm get secret grafana-db-app -o jsonpath='{.data.password}' | base64 -d; echo
psql "host=postgres.lgtm.company.org port=5432 dbname=grafana user=grafana sslmode=verify-full sslrootcert=grafana-db-ca.crt"
```

## Backups of Grafana's PostgreSQL

Two independent mechanisms write to Garage, each keeping **7 days**:

| | CloudNativePG + Barman Cloud plugin | PG Back Web (https://pgbackweb.&lt;domain&gt;) |
|---|---|---|
| What | WAL archive (continuous) + base backup daily at 02:00 | `pg_dump` daily at 03:00 |
| Bucket | `grafana-db-backups` | `pgbackweb` |
| Restore to | any point in time, into a **new** cluster | the running database, from a web UI |
| For | losing the database or all three servers | rolling back a bad change (deleted dashboards, a broken migration) |

CloudNativePG has no UI, so PG Back Web provides one. `lgtm.yml` sets it up completely: login
`admin@<domain>`, database `grafana`, destination `garage`, and backup `grafana-daily`. Its dumps use
`--clean --if-exists`, so restoring one replaces every object. PG Back Web is reachable from outside like every
host (`lgtm_hosts`). Its own data lives in the database `pgbackweb` of the same PostgreSQL cluster.

**Roll back** (PG Back Web): Executions → pick a backup → Restore → database `grafana`. The restore takes
seconds. Grafana keeps running and may log errors during that time. Afterwards, restart it so no cached state
survives: `kubectl -n lgtm delete pod -l app.kubernetes.io/name=grafana`. (Tested in the lab by restoring into a
scratch database: all 91 tables came back.) Dashboards are in Git anyway, so Git Sync restores them on its next
sync.

**Point-in-time recovery** (CloudNativePG): add a second `Cluster` that bootstraps from the object store,
check it, then point Grafana at it (or rename it):

```yaml
spec:
  bootstrap:
    recovery:
      source: grafana-db
      recoveryTarget: { targetTime: "2026-11-04 18:00:00+00" }   # omit for the latest state
  externalClusters:
    - name: grafana-db
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters: { barmanObjectName: grafana-db-backups, serverName: grafana-db }
```

Status: `kubectl -n lgtm get backups,scheduledbackups` and the condition `ContinuousArchiving` of
`kubectl -n lgtm get cluster grafana-db -o yaml`.

## Trusted CA certificates (`certs/`)

Put PEM files of the CAs the cluster should trust (company root and intermediate CAs) into `certs/` as `*.pem`
or `*.crt`, commit and push. The folder is a small Helm chart, deployed by the Argo CD app `certs`:
* its certificates go into the ConfigMap `cert-manager/company-ca-certs`;
* a trust-manager `Bundle` combines them with the public CAs (Debian's `ca-certificates`) and writes the
  ConfigMap **`company-ca-bundle`**, key `ca-certificates.crt`, into **every namespace**, and updates it when the
  folder changes. Pods that mount it see the new file after about a minute, without a restart.

Who uses it:
* **Argo CD repo-server** (`k8s/values/argocd.yaml`): `SSL_CERT_FILE` and `GIT_SSL_CAINFO` point to the bundle,
  so `git` and Helm trust https Git and Helm repositories signed by a company CA. Argo CD deploys trust-manager
  itself, so `lgtm.yml` creates a first `argocd/company-ca-bundle` from the Ansible host's CA bundle plus `certs/`
  when it doesn't exist yet; trust-manager takes it over afterwards.
* **Alloy** (`k8s/values/alloy.yaml`): mounted at `/etc/ssl/company/`. Scrape https targets with
  `tls_config { ca_file = "/etc/ssl/company/ca-certificates.crt" }` (example in `k8s/alloy/config.alloy`).
* Any other pod: mount the ConfigMap `company-ca-bundle` (`optional: true`) as a directory, not with `subPath`
  (`subPath` mounts don't receive updates).

Only public certificates belong there, never private keys. CAs that differ per site (the lab's generated CA)
go into the inventory instead: `trusted_ca_files` (paths on the Ansible host) are added to the same bundle.
Grafana mounts it too (`SSL_CERT_FILE`), for Git Sync.

## Networking and TLS

Two floating IPs (kube-vip, ARP) move to a surviving server on failure:
* `vip`: Kubernetes API and RKE2 join.
* `ingress_vip`: a LoadBalancer Service in front of Traefik (`externalTrafficPolicy: Local`). Traefik routes
  `<name>.<domain>` for every name in `lgtm_hosts` by Host header, on http and https.

**One certificate per hostname.** Every https Ingress carries the annotation `cert-manager.io/cluster-issuer`,
and cert-manager requests a certificate for it (Secret `<name>-tls`) from the company CA. It uses **ACME with External
Account Binding**: the CA hands out a key id and HMAC key, and only that account receives certificates. The challenge is
**HTTP-01**: the CA fetches a token from `http://<host>/.well-known/acme-challenge/` through a temporary Traefik
route, which is why plain http stays enabled. cert-manager renews each certificate when a third of its lifetime is left.

**Lab:**
* **Pebble** is the CA. It requires EAB, issues 7-day certificates, and resolves the hostnames on the lab DNS
  (**BIND**, `lab/external`, port 10053, `*.lgtm.company.org` → ingress VIP) to validate HTTP-01.
* Before asking the CA, cert-manager fetches the challenge itself. The cluster DNS doesn't know the lab domain, so
  `tls_issuer.http01_check_nameservers` points that self check at the lab DNS.
* Browsers don't trust Pebble's root (`https://192.168.56.1:15000/roots/0`).

```bash
kubectl get clusterissuer company-ca ; kubectl get certificate -A
```

## Tenants

Loki, Mimir, Tempo and Pyroscope are **multi-tenant**: every write and every query carries `X-Scope-OrgID`.

| Tenant | Data | How the tenant is set |
|---|---|---|
| `demo` | demo shop: traces, metrics, logs, profiles | OTLP header `X-Scope-OrgID=demo`, profile label `tenant=demo` |
| `platform` | the cluster itself: pod logs, cluster metrics | set by Alloy |

* **OTLP:** Alloy passes each sender's tenant header through (`include_metadata`, batch `metadata_keys`,
  `otelcol.auth.headers`). Data without the header is rejected.
* **Profiles:** Alloy routes them by the `tenant` label, because `pyroscope.receive_http` doesn't forward headers.
  A new tenant needs its pair of `pyroscope.relabel` and `pyroscope.write` in `k8s/values/alloy.yaml`.
* **Grafana:** every tenant has an **organization** whose datasources only see that tenant. They're created via the
  API from `ansible/templates/grafana-datasources.yaml.j2`; their dashboards come from Git (below). The
  **Main org** is for admins and sees all tenants (`demo|platform`). Pyroscope has no cross-tenant queries, so it
  gets one datasource per tenant.

## Grafana dashboards from Git (Git Sync)

Dashboards and folders live in a **second Git repository** (`grafana_git_sync`), one directory per org:
`main/`, `<tenant>/`. Grafana's Git Sync (pure Git over https) syncs each directory into the folder **LGTM**
of its org and commits what is saved in the UI back to the branch (`workflows: [write]`; `[branch]` opens pull
requests, `[]` is read-only). Neither Argo CD nor Ansible deploys dashboards, so there is exactly one source of
truth. `lgtm.yml` creates the connection per org once (Administration → Provisioning shows its state).

* **Alerts are not synced.** Git Sync only handles dashboards and folders (Grafana 13.2). Alert rules, contact
  points and policies stay in Grafana's database, which the PostgreSQL backups cover.
  [examples/alerting-matrix](examples/alerting-matrix) has an untested sketch of a rule that alerts into a
  Matrix room.
* Grafana refuses Git servers on private addresses unless they are allowed: `lgtm.yml` sets
  `[provisioning] allowed_git_urls` to the host of `grafana_git_sync.url`.
* Git Sync can't take over a dashboard whose UID already exists outside the repository: delete the old one first.

Lab: repository `grafana` on Gitea (https, lab CA). `lab/external.yml` creates it with the dashboards of
`grafana/dashboards` (`main/` gets all of them, each tenant its `tenants[].dashboards`), plus an access token
for Grafana.

## OAuth (Grafana, Argo CD ↔ IdP)

Both log in through the IdP with OIDC (PKCE), each with **its own OAuth client** (`oauth.client_id`,
`oauth.argocd_client_id`). The lab IdP is Keycloak (`http://keycloak.company.org:8080`, realm `lgtm`, users
`admin-user`, `alice` (demo), `bob` (platform); passwords in `.secrets/keycloak_user_<name>`).
`lab/external.yml` keeps an existing realm in step with `lab/templates/keycloak-realm.json.j2`.

| IdP group | Grafana | Argo CD |
|---|---|---|
| `grafana-admins` | Grafana server admin, Admin in every org | - |
| `tenant-<name>` | Editor in org `<name>` | - |
| `argocd-admins` | - | `role:admin` (`oauth.argocd_admin_groups`) |

Users outside these groups get nothing in Argo CD. `auto_assign_org` is off, so tenant users never see the Main
org, which shows all tenants.

**SSO first, local admin as the safety valve:**
* Grafana sends everyone straight to the IdP (`auto_login`). The local login form is still at
  `https://grafana.<domain>/login?disableAutoLogin=true`.
* Argo CD has no automatic redirect. Its login page (`k8s/argocd/login.css`) shows a large "Log in via Keycloak"
  button. Below it, labelled "local admin, only if SSO is down", the username/password form is dimmed until it is
  used.

## Self-observability: dashboard "Cluster health"

Alloy (one instance per node, each scrapes only its node) sends cluster metrics to Mimir as tenant `platform`:

* the node exporter (built into Alloy), kubelet and cAdvisor (trimmed to CPU, memory and network);
* etcd (`etcd-expose-metrics`) and Garage (admin API);
* the metrics ports of the LGTM, cert-manager, CloudNativePG, Argo CD and kube-system pods;
* Alloy itself, plus kube-state-metrics.

The dashboard **Cluster health** (`grafana/dashboards/cluster-health.json`, in the Main and `platform` orgs)
shows:
* nodes ready, etcd leader, Argo CD app health, pods not ready, restarts, certificate expiry;
* per-node CPU, memory, disk and network, and usage per namespace;
* scrape targets, ingest rate per signal, ring health;
* Garage health and capacity, PostgreSQL replication lag.

## Live traffic: trace-pong

The dashboard **Live traffic** (`grafana/dashboards/live-traffic.json`, in the Main and `demo` orgs) holds one
[trace-pong](https://github.com/ndgynxjnsn-alt/trace-pong) panel. It draws the service graph and replays real
calls from Tempo traces as balls flying between the services. The topology comes from
`traces_service_graph_*` in Mimir (Tempo's metrics-generator), and the traffic from Tempo's search.
* The plugin is baked into the Grafana image like the Drilldown apps (`grafana_plugins`, with a `url` because it
  isn't on grafana.com). It is unsigned and allowed by id (`plugins.allow_loading_unsigned_plugins`).
* Tempo's search sees traces 2 s after they end (`query_end_cutoff: 2s`, default 30 s), so the replay runs
  about 13 s behind real time.
* It renders with WebGPU: a current Chrome/Edge (or Firefox with WebGPU), over https.
* Every open panel polls Tempo on its own (up to 30 traces per second each).

## Frontend telemetry: Grafana Faro

Browser apps send Faro data to `http(s)://faro.<domain>/<tenant>/collect`. Alloy runs one `faro.receiver` per
tenant (ports 12347 `demo`, 12348 `platform`); Traefik strips the `/<tenant>` prefix and picks the
receiver by path. Each receiver writes to Loki (label `service_name` = the Faro app name, `kind` =
log/event/exception/measurement) and to Tempo, with its tenant. `faro.receiver` doesn't pass
request headers on, so the tenant can't come from `X-Scope-OrgID` the way it does for OTLP.
Adding a tenant: a receiver/loki.write/exporter triple in `k8s/alloy/config.alloy`, a port in
`k8s/values/alloy.yaml`, a path in `argocd/platform/templates/ingress.yaml`.

Example: `examples/frontend` (see [Example apps](#example-apps-outside-the-cluster)).

## Example apps outside the cluster

[`examples/`](examples/README.md) shows teams how to send telemetry from their own services. It isn't part of
any deployment.
* A React frontend with Faro.
* Five Spring Boot services in a diamond-shaped call graph, with the OTel Java agent and Pyroscope.
* PostgreSQL with a slow query log and an Alloy sidecar.
* An order id that can be followed from the browser to the database (dashboard **Order journey**).
* The same apps on a 3-node Docker Swarm without agents: Beyla, container logs, eBPF profiles, and one
  Prometheus scraper.

## OTLP/JSON import

```bash
scp traces.json ops@<server>:/var/lib/otel-import/<tenant>/
```

* **Formats:** one OTLP export request per file, or JSON Lines as written by the OTel Collector's file exporter.
* **Import:** a sidecar in the Alloy pod posts each file to Alloy's `import` receiver, with the directory as
  tenant. Alloy 1.20 has no OTLP-file receiver.
* **Cleanup:** imported files become `*.imported` or `*.failed`, and a systemd timer deletes them after 60 minutes.

## Data flow

```
demo app ── OTel Java agent ── OTLP/HTTP ─▶ Alloy :4318 ─┬─▶ Tempo     (traces)
         │   (traces, metrics + exemplars,                ├─▶ Mimir /otlp (metrics, exemplars)
         │    logs with trace_id/span_id)                 └─▶ Loki  /otlp (logs, structured metadata)
         └─ Pyroscope Java agent (+ OTel extension) ─▶ Alloy :9999 ─▶ Pyroscope (profiles with span_id)
pods' stdout (except demo) ── Alloy (/var/log/pods) ─▶ Loki (tenant platform)
node/kubelet/etcd/Garage/component metrics ── Alloy ─▶ Mimir (tenant platform)
Tempo metrics-generator (service graph, span metrics) ──▶ Mimir (same tenant)
Loki · Mimir · Tempo · Pyroscope ──▶ Garage S3 (Service garage.lgtm.svc -> the servers)
```

### Correlation in Grafana

All four signals share the labels `service_name` and `deployment_environment_name`. Mimir promotes the OTel
resource attributes to labels. Tempo's span metrics use `service`.

| From | To | How |
|---|---|---|
| metric (latency histogram) | trace | exemplars with `trace_id` (◆ in panels) |
| log line | trace | `trace_id` structured metadata → derived field "View trace" |
| trace span | logs | `{service_name="<service.name>"} \| trace_id="<id>"` |
| trace span | metrics | Tempo span metrics: request rate, error rate, p95 |
| trace span | CPU profile | flame graph of exactly that span (span labels from the Pyroscope OTel extension) |
| traces | service map | Tempo's service graph metrics |

The dashboard **LGTM demo shop** shows golden signals, exemplars, custom Micrometer metrics, logs, traces, the service
graph and a CPU flame graph. The Drilldown apps are at `/drilldown`.
The news feed ("Latest from the blog") is disabled because the cluster is offline.

**Log volume in Logs Drilldown:** Loki's `/drilldown-limits` endpoint needs a tenant header even without auth.
Logs Drilldown shows "Log volume has not been configured." on any error there. Every Loki datasource sends its
tenant, so this works.

### The demo app

`apps/demo` is one Spring Boot 4.1 image deployed twice:

* **shop** runs a load generator (2 orders/s per replica) and serves `/api/orders/{item}`. It calls inventory and
  prices the order in a CPU-heavy `@WithSpan` method.
* **inventory** serves `/api/inventory/{item}` with random latency and about 5% errors.

Its instrumentation:

* OTel Java agent 2.32.0 (traces, logs, metrics with exemplars, Micrometer bridge).
* Pyroscope Java agent 2.9.2 with the Pyroscope OTel extension 2.1.4 for span profiles.
  The Pyroscope agent is loaded *before* the OTel agent.

## Fault tolerance

Stop any one VM (`cd lab && vagrant halt lgtm2`, or `virsh destroy`). This keeps working:

| Layer | Why it survives one node loss |
|---|---|
| Kubernetes API | etcd quorum 2/3. The control-plane VIP moves within 9–52 s (etcd re-election first) |
| Ingress | Traefik runs on every node, and the ingress VIP moves to a surviving node |
| S3 | Garage keeps 3 copies and serves reads and writes with 2 of 3 nodes |
| Loki / Mimir | 3 replicas, replication factor 3, quorum 2 of 3. Dead ring members time out after 1 min |
| Pyroscope | raft metastore with 3 members (quorum 2) |
| Tempo | **single instance** (Tempo 3 monolithic supports only one `-target=all`). It reschedules after 30 s and loses the traces still in its WAL. Use `tempo-distributed` for real HA |
| Grafana | 2 replicas on PostgreSQL, alerting HA |
| PostgreSQL | CloudNativePG, 3 instances. A replica is promoted when the primary fails |
| Argo CD | deploys keep working once it reschedules. A short outage doesn't affect running workloads |

Notes:
* Pods with local-path volumes stay `Pending` until their node returns. Garage's endpoints are static node IPs
  that kube-proxy doesn't health-check.
* Losing **two** servers stops the API. That's inherent to etcd quorum.

## Development

```bash
.bin/uvx --from ansible-lint ansible-lint      # production profile, lines <= 120 (.ansible-lint, .yamllint)
.bin/uvx yamllint k8s lab/external
```

**Style:** configuration lives in files with their own syntax, not in inline strings:
* values overlays: `ansible/templates/*-values.yaml.j2`;
* the Alloy pipeline: `k8s/alloy/config.alloy`;
* scripts: `*.sh`; Lua: `*.lua`;
* systemd units and other config files: role templates.

**Re-runs from scratch:** removing something is idempotent (`state: absent` semantics). Objects or resource types
that don't exist yet count as nothing to remove.

`uv` is a single binary in `.bin/` (`curl -sfL https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-unknown-linux-gnu.tar.gz | tar xz -C .bin --strip-components=1`).
