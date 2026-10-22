# LGTM on a three-server HA RKE2 cluster

A highly available, on-premise Kubernetes cluster that runs the Grafana LGTM+P stack: Loki, Grafana,
Tempo, Mimir and Pyroscope, with Grafana Alloy as the single telemetry entry point.

* **Offline nodes.** The servers need no internet access. Everything is downloaded once onto the Ansible host
  (`artifacts/`):
  * RKE2 is installed in tarball mode.
  * All container images are preloaded.
  * The charts are served to Argo CD from a Helm repository.
* **GitOps.** Ansible prepares the servers and bootstraps **Argo CD**. Argo CD deploys the rest from Git as an
  *app of apps*.
* **Lab and real site are separated.** `lab/` simulates the servers with Vagrant/libvirt VMs and runs stand-ins for
  company services: CA, DNS, IdP, Git. The playbooks in `ansible/` are the same for the lab and a real site. Only the
  inventory differs.

```
             DNS: *.lgtm.company.org -> ingress VIP                     Kubernetes API -> control-plane VIP
                          │                                                         │
   ┌───── kube-vip (ARP): two floating IPs, each moves to a surviving server ───────┴────────────────┐
   │  ingress VIP  :80/:443  Traefik -> grafana|loki|tempo|mimir|pyroscope|alloy|garage|argocd.<domain> │
   │  control-plane VIP  :6443 API, :9345 RKE2 join                                                     │
   ▼                                   ▼                                   ▼
 server 1                           server 2                           server 3
 RKE2 server (etcd, CP, worker)     RKE2 server (etcd, CP, worker)     RKE2 server (etcd, CP, worker)
 Garage S3 (data disks)             Garage S3 (data disks)             Garage S3 (data disks)

 argocd:  Argo CD  ── app of apps (argocd/root) ──▶ everything below
 lgtm:    loki ×3 · mimir ×3 · pyroscope ×3 · tempo ×1 · alloy (DaemonSet) · grafana ×2 · postgres ×3 (CloudNativePG)
 demo:    shop ×2 ──HTTP──▶ inventory ×2      (Spring Boot + OTel Java agent + Pyroscope)
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
| kube-state-metrics | 2.20.0 (chart 8.6.0) | object state for the "Cluster health" dashboard |
| OS | Ubuntu 26.04 LTS | `sudo-rs` replaced by classic sudo (Ansible's become can't drive sudo-rs) |

## Repository layout

```
ansible/                          the playbooks - identical for the lab and a real site
  site.yml                        servers: sudo, Garage, OTLP/JSON import dirs, RKE2 (tarball) + kube-vip, kubeconfig
  lgtm.yml                        Secrets, publish repo + charts, Argo CD, root Application, Grafana tenant orgs
  demo.yml                        build the demo image, load it on the servers
  download.yml                    the only online step: RKE2 tarballs, charts, images, plugins -> artifacts/
  group_vars/all.yml              site-independent settings: versions, charts, generated secrets
  roles/garage, rke2, otel_import
  tasks/                          apply-set (apply + prune), gitops-publish, grafana-tenants
  templates/                      secrets, root Application, Grafana datasources
argocd/
  root/                           app of apps: one Argo CD Application per component
  platform/                       ingress VIP, ingresses, TLS, Grafana database, dashboards
k8s/values/                       Helm values of every chart (no secrets)
k8s/alloy/                        Alloy pipeline (config.alloy) and the OTLP/JSON import script
k8s/argocd/                       Argo CD resource health check (Lua)
k8s/demo/                         demo app manifests
apps/demo/                        Spring Boot demo app
inventories/example/              template for a real site (all site settings)
lab/                              LAB ONLY
  Vagrantfile                     3 Ubuntu 26.04 VMs, 5 data disks each, isolated networks
  inventory/                      lab servers + lab site settings
  external.yml, external/         stand-in company services (docker compose): Keycloak, Pebble, BIND, Gitea
  templates/                      their configuration (Keycloak realm, Pebble, BIND, keycloak.env)
docs/s3-storage.md                S3 storage research and decision (Garage)
```

## Prerequisites (Ansible host)

* Ansible ≥ 2.16 and `ansible-galaxy collection install -r requirements.yml`, `sshpass` (password login),
  `zstd`, `unzip`, `git`, `jq`. Internet access is only needed for `download.yml` and the demo build.
* No Docker daemon for the cluster: images are fetched with `crane` and built with Jib/`crane append`.
* Lab: KVM + libvirt + `vagrant-libvirt` (user in group `libvirt`), about 22 GB free RAM (3 × 7 GB VMs), and
  Docker with compose for the stand-in services (`lab/external.yml` uses `sudo docker compose`, pass `-K`).

## Bring it up (lab)

```bash
ansible-playbook ansible/download.yml                        # online: everything into artifacts/ (~3 GB)
(cd lab && vagrant destroy -f)                               # optional: start from scratch
(cd lab && vagrant up)                                       # 3 bare VMs on isolated networks
ansible-playbook -i lab/inventory lab/external.yml -K        # Keycloak, Pebble (CA), BIND (DNS), Gitea (Git+Helm)
ansible-playbook -i lab/inventory ansible/site.yml           # offline: Garage, RKE2 HA + kube-vip, ./kubeconfig
ansible-playbook -i lab/inventory ansible/lgtm.yml           # Argo CD + app of apps -> the whole stack
ansible-playbook -i lab/inventory ansible/demo.yml           # demo image -> servers (Argo CD deploys the app)
source scripts/env.sh && k9s                                 # kubectl/helm/k9s with ./kubeconfig
```

Hosts file on the lab host, or use the lab DNS (`dig @192.168.56.1 -p 10053 grafana.lgtm.company.org`):

```
192.168.56.1  keycloak.company.org
192.168.56.20 grafana.lgtm.company.org loki.lgtm.company.org tempo.lgtm.company.org mimir.lgtm.company.org
192.168.56.20 pyroscope.lgtm.company.org alloy.lgtm.company.org garage.lgtm.company.org argocd.lgtm.company.org
```

| URL | What |
|---|---|
| https://grafana.lgtm.company.org | Grafana: Keycloak login, or `admin` / `.secrets/grafana_admin_password` |
| https://argocd.lgtm.company.org | Argo CD: `admin` / Secret `argocd/argocd-initial-admin-secret` |
| https://alloy.lgtm.company.org | Alloy UI. Also accepts OTLP/HTTP (`/v1/*`) and Pyroscope pushes (`/ingest`) |
| https://{loki,mimir,tempo,pyroscope,garage}.lgtm.company.org | backend APIs (multi-tenant: send `X-Scope-OrgID`) |

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
* the IdP;
* the Git and Helm repositories Argo CD reads from.

Keep secrets in ansible-vault. Then run `download.yml`, `site.yml` and `lgtm.yml` with `-i inventories/<site>`.

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
2. **Publishes** (lab, `gitops.publish`): pushes the committed `HEAD` to Gitea and uploads `artifacts/charts/*.tgz`
   to Gitea's Helm repository. At a company, CI does this.
   **Argo CD deploys what is committed**, and the playbook warns about uncommitted changes.
3. Installs **Argo CD** with Helm (the only Helm install).
4. Creates the root Application `lgtm`. It renders `argocd/root` with the site values from the inventory into one
   Application per component. Each one combines an upstream chart from the Helm repo with its values file from Git
   (`k8s/values/<name>.yaml`) and a site overlay. Sync waves order them:

   | Wave | Apps |
   |---|---|
   | −3 | cert-manager, CloudNativePG (CRDs) |
   | −2 | `argocd/platform`: ingress VIP Service, Garage endpoints, ingresses (one certificate each), ClusterIssuer, PostgreSQL cluster, dashboards |
   | 0 | Loki, Mimir, Tempo, Pyroscope, kube-state-metrics |
   | 1 | Alloy, Grafana |
   | 2 | demo |

   Applications sync automatically with prune and self-heal. Argo CD's health check for `Application`
   (`k8s/values/argocd.yaml`) lets each wave wait for the previous one.
5. Waits until every Application is healthy, then creates the Grafana org per tenant through the API.

To change something, edit, commit and run `lgtm.yml` again, or just push when Argo CD reads your Git server.
Clusters set up by earlier versions with plain Helm migrate in place: the Helm release records are deleted and
Argo CD adopts the resources.

### Re-running

All playbooks can be re-run, and a re-run applies new settings:
* `lgtm.yml` applies its Secrets and the root app as labelled sets and deletes what is no longer rendered.
  Argo CD prunes everything else; for example, a hostname removed from `lgtm_hosts` removes its ingresses.
* `site.yml` copies image archives only when containerd on the node lacks the image (`artifacts/images/index.yml`).
  Partial runs: `--tags images` ships new images, `--tags otel-import` updates the import directories.
* `demo.yml` loads the image and restarts the pods only when the image ID changed.
* Exception: `site.yml` **resets Garage** on every run.

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
  API from `ansible/templates/grafana-datasources.yaml.j2`, with dashboards from `tenants[].dashboards`. The
  **Main org** is for admins and sees all tenants (`demo|platform`). Pyroscope has no cross-tenant queries, so it
  gets one datasource per tenant.

## OAuth (Grafana ↔ IdP)

Grafana logs in with generic OAuth (OIDC, PKCE). The lab IdP is Keycloak (`http://keycloak.company.org:8080`, realm
`lgtm`, users `admin-user`, `alice` (demo), `bob` (platform); passwords in `.secrets/keycloak_user_<name>`).

| IdP group | Grafana |
|---|---|
| `grafana-admins` | Grafana server admin, Admin in every org |
| `tenant-<name>` | Editor in org `<name>` |

`auto_assign_org` is off, so tenant users never see the Main org, which shows all tenants.

## Self-observability: dashboard "Cluster health"

Alloy (one instance per node, each scrapes only its node) sends cluster metrics to Mimir as tenant `platform`:

* the node exporter (built into Alloy), kubelet and cAdvisor (trimmed to CPU, memory and network);
* etcd (`etcd-expose-metrics`) and Garage (admin API);
* the metrics ports of the LGTM, cert-manager, CloudNativePG, Argo CD and kube-system pods;
* Alloy itself, plus kube-state-metrics.

The dashboard **Cluster health** (`argocd/platform/dashboards/cluster-health.json`, in the Main and `platform` orgs)
shows:
* nodes ready, etcd leader, Argo CD app health, pods not ready, restarts, certificate expiry;
* per-node CPU, memory, disk and network, and usage per namespace;
* scrape targets, ingest rate per signal, ring health;
* Garage health and capacity, PostgreSQL replication lag.

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
