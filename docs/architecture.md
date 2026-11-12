# Architecture

Two Mermaid diagrams: the servers and the network around them, then the applications on top. The addresses
are the lab's (`lab/inventory`); a real site sets its own in its inventory (`inventories/example`).

## Servers, network, company services

Three identical servers. Each one is an RKE2 server (control plane, etcd and workloads together), a Garage
node and a TopoLVM node. Two floating IPs (kube-vip, ARP) move to a surviving server when one fails: one for
the Kubernetes API, one for every LGTM hostname.

```mermaid
flowchart TB
    users["Users and senders<br/>browsers, OTLP, Faro, Postgres clients"]
    admins["Admins<br/>kubectl, Ansible host"]
    dns["DNS<br/>*.lgtm.company.org → 192.168.56.20"]
    ingvip(["Ingress VIP 192.168.56.20 (kube-vip)<br/>:80 / :443 Traefik, :5432 PostgreSQL"])
    apivip(["API VIP 192.168.56.10 (kube-vip)<br/>:6443 Kubernetes API, :9345 RKE2 join"])

    subgraph cluster["RKE2 cluster"]
        direction LR
        subgraph n1["lgtm1 · .11"]
            direction TB
            k1["RKE2 server<br/>control plane, etcd,<br/>workloads, Traefik"]
            g1["Garage<br/>(systemd) S3 :3900"]
            d1[("disks<br/>1 TopoLVM, rest Garage")]
        end
        subgraph n2["lgtm2 · .12"]
            direction TB
            k2["RKE2 server<br/>control plane, etcd,<br/>workloads, Traefik"]
            g2["Garage<br/>(systemd) S3 :3900"]
            d2[("disks<br/>1 TopoLVM, rest Garage")]
        end
        subgraph n3["lgtm3 · .13"]
            direction TB
            k3["RKE2 server<br/>control plane, etcd,<br/>workloads, Traefik"]
            g3["Garage<br/>(systemd) S3 :3900"]
            d3[("disks<br/>1 TopoLVM, rest Garage")]
        end
    end

    subgraph company["Company services"]
        direction LR
        nexus["Nexus<br/>every image + Helm chart"]
        gitea["Gitea<br/>this repo → Argo CD"]
        gitlab["GitLab 17.2<br/>dashboards → Grafana Git Sync"]
        idp["Keycloak<br/>login: Grafana, Argo CD"]
        acme["ACME CA<br/>TLS certificates"]
    end

    users --> dns --> ingvip
    admins --> apivip
    ingvip -. "on one node at a time" .-> cluster
    apivip -. "on one node at a time" .-> cluster
    k1 --- g1 --- d1
    k2 --- g2 --- d2
    k3 --- g3 --- d3
    n1 <-. "etcd raft, Garage RPC" .-> n2 <-. "etcd raft, Garage RPC" .-> n3
    cluster ==>|"https / pulls"| company
```

| What | Where | Fails over by |
|---|---|---|
| Kubernetes API | API VIP `vip` | kube-vip moves the IP; etcd keeps quorum with 2 of 3 |
| All LGTM hostnames (`<name>.<domain>`) | Ingress VIP `ingress_vip` | kube-vip moves the IP to another node's Traefik |
| Object storage | Garage on every node, Service `garage.lgtm.svc:3900` | node taken out of the Service while its Garage is down |
| Block storage (PVCs) | TopoLVM, one local disk per node | not replicated: the applications replicate themselves |

## Applications and storage

Everything except Garage runs in Kubernetes, deployed by Argo CD. "Monolithic" means one binary that runs all
components (`-target=all`); the replicas form a ring (Loki, Mimir) or a raft group (Pyroscope) and replicate
the recent data among themselves. Long-term data goes to Garage.

```mermaid
flowchart LR
    senders["Apps, nodes, browsers<br/>OTLP, logs, profiles, Faro"]

    subgraph k8s["Kubernetes"]
        direction LR
        alloy["Alloy<br/>DaemonSet, 1 per node<br/>single entry point"]

        subgraph stores["Telemetry stores (multi-tenant)"]
            direction TB
            loki["Loki · monolithic<br/>3 replicas, replication factor 3"]
            mimir["Mimir · monolithic<br/>3 replicas, replication factor 3"]
            tempo["Tempo 3 · monolithic<br/>1 replica (singleton scheduler)<br/>WAL on emptyDir, quick reschedule"]
            pyro["Pyroscope v2 · single binary<br/>3 replicas, raft metastore"]
        end

        subgraph ui["UI"]
            direction TB
            grafana["Grafana 13 · 2 replicas<br/>orgs per tenant, Git Sync"]
            pgdb[("grafana-db · CloudNativePG<br/>PostgreSQL, 3 instances<br/>1 primary + 2 replicas")]
            pbw["PG Back Web · 1 replica"]
        end

        subgraph platform["Platform"]
            direction TB
            argocd["Argo CD (ns argocd)"]
            certs["cert-manager + trust-manager"]
            topolvm["TopoLVM (default StorageClass)"]
            other["kube-state-metrics, Headlamp,<br/>kube-vip, Traefik (RKE2)"]
        end
    end

    subgraph garage["Garage S3"]
        direction TB
        gnote["all 3 nodes, replication factor 3<br/>consistent mode: quorum 2 of 3<br/>every object on every node"]
        b1[("loki-chunks, loki-ruler")]
        b2[("mimir-blocks, mimir-ruler,<br/>mimir-alertmanager")]
        b3[("tempo-traces")]
        b4[("pyroscope-data")]
        b5[("grafana-db-backups (Barman, 7 days),<br/>pgbackweb (daily pg_dump)")]
    end

    senders --> alloy
    alloy -->|logs| loki
    alloy -->|metrics| mimir
    alloy -->|traces| tempo
    alloy -->|profiles| pyro
    tempo -->|"span + service-graph metrics"| mimir

    grafana -->|queries| loki & mimir & tempo & pyro
    grafana --> pgdb
    pbw -->|pg_dump| pgdb

    loki --> b1
    mimir --> b2
    tempo --> b3
    pyro --> b4
    pgdb -->|"WAL + base backups"| b5
    pbw --> b5

    topolvm -. "PVCs: Loki, Mimir, Pyroscope,<br/>grafana-db" .-> stores
```

| Component | Mode | Replicas | Redundancy | Storage |
|---|---|---|---|---|
| Garage | systemd service on every node | 3 | replication factor 3, consistent mode | its own disks on each node |
| Loki | monolithic (`deploymentMode: Monolithic`) | 3 | replication factor 3 | TopoLVM PVC 2 Gi + S3 |
| Mimir | monolithic (`-target=all`, NGDATA chart) | 3 | replication factor 3 | TopoLVM PVC 2 Gi + S3 |
| Tempo 3 | monolithic (`-target=all`) | 1 | rescheduled within ~1 min; data in S3 | emptyDir + S3 |
| Pyroscope v2 | single binary (`-target=all`) | 3 | raft metastore (quorum 2 of 3) | TopoLVM PVC 2 Gi + S3 |
| Grafana | — | 2 | state in PostgreSQL | none |
| grafana-db | CloudNativePG | 3 | streaming replication, automatic failover | TopoLVM PVC 1 Gi; backups in S3 |
| Alloy | DaemonSet | 1 per node | every node sends its own data | none |
| PG Back Web | — | 1 | schedules the backups itself, so one only | none (S3) |
