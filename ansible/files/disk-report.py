#!/usr/bin/env python3
"""Disks of this node and the suggested TopoLVM disk as JSON, for ansible/disks.yml. Read-only: lsblk,
/dev/disk/by-id and, with --bench, O_DIRECT reads (4 KiB random for latency, 1 MiB sequential for
throughput) - nothing is ever written."""
import json, mmap, os, random, subprocess, sys, time

BENCH = "--bench" in sys.argv
SECONDS = 4

def lsblk():
    out = subprocess.run(["lsblk", "-J", "-b", "-o", "NAME,TYPE,SIZE,ROTA,TRAN,MODEL,SERIAL,FSTYPE,MOUNTPOINTS"],
                         check=True, capture_output=True, text=True).stdout
    return json.loads(out)["blockdevices"]

def by_id():
    links = {}
    d = "/dev/disk/by-id"
    for name in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        if name.startswith(("lvm-pv-uuid-", "dm-", "md-uuid-")):    # names of contents, not of the hardware
            continue
        target = os.path.basename(os.path.realpath(os.path.join(d, name)))
        links.setdefault(target, []).append(name)
    # stable names first: wwn-/nvme-eui. are unique per device, vendor-model-serial names are readable
    for v in links.values():
        v.sort(key=lambda n: (n.startswith(("wwn-", "nvme-eui.", "nvme-nvme.")), len(n)))
    return links

def walk(dev):
    yield dev
    for c in dev.get("children") or []:
        yield from walk(c)

def usage(dev):
    """What uses the disk: mounts (incl. via LVM/partitions) and filesystems/LVM signatures."""
    mounts, fstypes = set(), set()
    for d in walk(dev):
        # kubelet's bind mounts of volumes are noise here; "/" etc. and /srv/garage/* tell what the disk is for
        mounts.update(m for m in (d.get("mountpoints") or []) if m and not m.startswith("/var/lib/kubelet/"))
        if d.get("fstype"):
            fstypes.add(d["fstype"])
    return sorted(mounts), sorted(fstypes)

def bench(path, size):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECT)
    try:
        buf4k, buf1m = mmap.mmap(-1, 4096), mmap.mmap(-1, 1 << 20)   # page-aligned buffers for O_DIRECT
        blocks = size // 4096
        lat, end = [], time.monotonic() + SECONDS
        while time.monotonic() < end:
            t = time.perf_counter()
            os.preadv(fd, [buf4k], random.randrange(blocks) * 4096)
            lat.append(time.perf_counter() - t)
        lat.sort()
        done, off, end = 0, 0, time.monotonic() + SECONDS
        start = time.monotonic()
        while time.monotonic() < end and off + (1 << 20) <= size:
            done += os.preadv(fd, [buf1m], off)
            off += 1 << 20
        mbps = done / (time.monotonic() - start) / 1e6
        return {"rand_read_iops": round(len(lat) / SECONDS), "rand_read_p50_ms": round(lat[len(lat) // 2] * 1e3, 3),
                "rand_read_p99_ms": round(lat[int(len(lat) * 0.99)] * 1e3, 3), "seq_read_mb_s": round(mbps)}
    finally:
        os.close(fd)

disks, ids = [], by_id()
for dev in lsblk():
    if dev["type"] != "disk" or dev["name"].startswith(("loop", "zram", "sr")):
        continue
    mounts, fstypes = usage(dev)
    d = {"name": dev["name"], "size_gb": round(int(dev["size"]) / 1e9, 1), "rotational": bool(dev["rota"]),
         "transport": dev.get("tran") or "", "model": (dev.get("model") or "").strip(),
         "serial": (dev.get("serial") or "").strip(), "by_id": ids.get(dev["name"], []),
         "partitions": len(dev.get("children") or []), "mounts": mounts, "fstypes": fstypes}
    if BENCH and int(dev["size"]) > 0:
        try:
            d["bench"] = bench("/dev/" + dev["name"], int(dev["size"]))
        except OSError as e:
            d["bench"] = {"error": str(e)}
    disks.append(d)
def use(d):
    if "/" in d["mounts"] or "/boot" in d["mounts"]:
        return "OS"
    if "LVM2_member" in d["fstypes"]:
        return "TopoLVM"     # (or another LVM volume group)
    if any(m.startswith("/srv/garage/") for m in d["mounts"]):
        return "Garage"
    return "in use" if d["mounts"] or d["partitions"] or d["fstypes"] else "free"

for d in disks:
    d["use"] = use(d)
# Candidates: not the OS disk, unused or used by this stack, with a stable name. Fastest first: SSD/NVMe before
# HDD, then lower random-read latency (with --bench), then the smaller disk (the big ones serve Garage better).
candidates = [d for d in disks if d["use"] in ("free", "TopoLVM", "Garage") and d["by_id"] and d["size_gb"] > 0]
candidates.sort(key=lambda d: (d["rotational"], d.get("bench", {}).get("rand_read_p50_ms", 0), d["size_gb"]))
print(json.dumps({"disks": disks, "suggestion": candidates[0] if candidates else None}))
