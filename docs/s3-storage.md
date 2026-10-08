# S3 storage for the LGTM cluster

*Researched 2026-10-08.*

Loki, Tempo, Mimir and Pyroscope keep their long-term data (chunks, blocks, traces, profiles) in object storage.
They only need a small part of the S3 API: `PUT`/`GET`/`HEAD`/`DELETE`, `ListObjectsV2`, multipart uploads,
path-style addressing and static access keys. They do not need versioning, object lock, ACLs, bucket policies or
lifecycle rules, because each component runs its own retention.

What we want for an on-premise cluster of three servers:

* Survives the loss of one server (replication across nodes).
* Simple to run: few components, little configuration, easy to recover.
* Actively maintained, with a license that is fine for internal use.
* Light enough to share the servers with Kubernetes and the LGTM stack.

## Candidates

| | **Garage** | **SeaweedFS** | **MinIO** | **Ceph RGW** | **RustFS** |
|---|---|---|---|---|---|
| Latest release | v2.4.1 (2026-09) | 4.48 (2026-09) | 2025-10 (archived) | active | 1.0.1 (2026-10) |
| License | AGPL-3.0 | Apache-2.0 | AGPL-3.0 | LGPL-2.1/3 | Apache-2.0 |
| Language | Rust | Go | Go | C++ | Rust |
| Processes per node | 1 binary | master + volume + filer + s3 (one binary, several roles) | 1 | MON, MGR, OSD per disk, RGW (Rook in K8s) | 1 |
| Redundancy | Replication (1–3 copies), zone-aware | Replication + erasure coding (EC for warm data) | Erasure coding | Replication / EC (CRUSH) | Erasure coding |
| Metadata | Built-in (LMDB/SQLite), replicated | Filer store (LevelDB per filer; Postgres/Redis/etc. for HA) | Inline with objects | RADOS | Inline |
| Min. useful cluster | 3 nodes, heterogeneous disks are fine | 3 nodes | 4+ drives, uniform | 3 nodes, several OSDs, lots of RAM | 4+ drives |
| Ops complexity | **Low** | Medium | Low | **High** | Low |
| Maturity | Production use since 2020 (Deuxfleurs, NLnet-funded) | Very mature, big feature set | Mature but **unmaintained** | Very mature (industry standard) | Young (1.0 just released) |

### MinIO: ruled out
In 2025 MinIO stripped the admin console from the community edition and stopped shipping binaries and Docker
images. It then put the repository into maintenance-only mode. The GitHub repository `minio/minio` is now
**archived** (last push 2026-04-24, last release 2025-10). Community forks exist (e.g. `pgsty/minio`), but building
a new cluster on an unmaintained or forked storage layer is a bad starting point.

### Ceph RGW: ruled out for this size
Ceph is the most capable option (block + file + object, erasure coding, huge scale). For three small servers it is
far too heavy. You need monitors, managers, one OSD per disk, RADOS gateways and usually Rook on Kubernetes.
Recommended memory is several GB per OSD, and operating it well takes dedicated knowledge. It is worth revisiting
only if you also need block/file storage at scale.

### RustFS: promising, too young
RustFS is an Apache-licensed MinIO-like server (single binary, erasure coding) that just reached 1.0. It is the
most natural "MinIO replacement", but there is little production track record yet. Re-evaluate in a year.

### SeaweedFS: good, more moving parts
SeaweedFS is fast, Apache-licensed, very feature-rich (erasure coding, tiering to cloud, FUSE mount, WebDAV,
Iceberg). The S3 API sits on top of the *filer*. For HA you run several masters (raft), volume servers, and several
filers that need a shared metadata store (e.g. Postgres or Redis) or careful filer peering. That is 3–4 roles to
configure and monitor instead of one. It's a good choice when the cluster grows to many nodes and you want erasure
coding to save disk space.

### Garage: chosen
Garage is built for exactly this case: a small number of self-hosted nodes, possibly with odd-sized disks, with
replicated data and no single point of failure.

* **One binary, one TOML file** per node. No separate metadata database.
* **Replication factor 3**: every object is on all three servers here; any one server can fail with no
  data loss and no downtime (`consistency_mode = "consistent"`, quorum 2 of 3).
* **Multiple data directories** per node with individual capacities, so the 5 disks per server map directly to
  5 `data_dir` entries and need no RAID or LVM.
* **Cluster layout** with zones and capacities is managed by `garage layout`, and changes are staged and then applied.
* Low resource use (tens of MB of RAM), fast restart, admin API + Prometheus metrics.
* Works with Loki, Mimir, Tempo and Pyroscope out of the box (path-style, region `garage`).

Limitations that don't matter for LGTM: no erasure coding (replication costs 3× raw disk), no versioning or
object lock, permissions only per key and bucket. **AGPL-3.0** only matters if you modify Garage and offer it to
others over a network.

## How Garage runs in this repository

Garage runs on each VM as a **systemd service, outside Kubernetes** (`provision/node.sh`). Storage is the lowest
layer. Running it beside Kubernetes means the cluster can be rebuilt without touching the data, and it needs
no PersistentVolume YAML for the 15 disks.

```
lgtm1/2/3: /dev/vd[b-f] (5 × 100 MB) -> ext4 -> /srv/garage/data1..5 -> garage (data_dir list)
           /var/lib/garage/meta (root disk) -> LMDB metadata
ports:     3900 S3 API · 3901 RPC between nodes · 3903 admin API + /metrics
```

* `provision/garage-cluster.sh` (runs on the last node) connects the nodes, assigns the layout
  (zone `dc1`, 400 MB per node), imports the access key from `.secrets/cluster.env` and creates the buckets:
  `loki-chunks loki-ruler tempo-traces mimir-blocks mimir-ruler mimir-alertmanager pyroscope-data`.
* Clients use **`http://192.168.56.10:3900`**, the kube-vip VIP. Every node serves the full S3 API and forwards
  internally, so the VIP always reaches a live Garage node.

Useful commands (on any node):

```bash
sudo garage -c /etc/garage.toml status          # nodes and health
sudo garage -c /etc/garage.toml layout show
sudo garage -c /etc/garage.toml bucket info mimir-blocks
sudo garage -c /etc/garage.toml stats -a        # disk usage per node / data dir
```

## For a real deployment

* **Disks:** 100 MB disks are only for the simulation (usable capacity here is ~400 MB because everything is
  stored 3×). Size data disks for `daily ingest × retention × 3`.
* **Metadata on SSD**, data on HDD is fine. Garage takes automatic metadata snapshots
  (`metadata_auto_snapshot_interval`).
* **TLS:** Garage speaks plain HTTP. Put it behind a TLS reverse proxy, or keep it on a dedicated storage network
  as done here.
* **Endpoint:** with a real DNS name (e.g. `s3.example.org`) pointing at the VIP or at all three nodes.
* **Backups:** replication is not a backup. Mirror critical buckets to another site (`rclone sync`).
* **Growth:** add nodes with `garage layout assign` and `garage layout apply`, and Garage rebalances.
  Consider SeaweedFS (erasure coding) once raw capacity cost matters more than simplicity.

## Sources

* Garage: https://garagehq.deuxfleurs.fr/ , configuration reference
  https://garagehq.deuxfleurs.fr/documentation/reference-manual/configuration/
* SeaweedFS: https://github.com/seaweedfs/seaweedfs
* MinIO repository (archived): https://github.com/minio/minio
* Reports on MinIO's maintenance mode and archival: https://blog.vonng.com/en/db/minio-resurrect/ ,
  https://www.youngju.dev/blog/2026-07-17-minio-archived-garage-seaweedfs-ceph-rgw.en
* Ceph: https://docs.ceph.com/en/latest/start/hardware-recommendations/
* RustFS: https://github.com/rustfs/rustfs
