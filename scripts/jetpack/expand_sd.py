#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Grow only the mounted JetPack SD APP partition and ext4 filesystem."""
import argparse
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile

DISK = "/dev/mmcblk0"
ROOT = DISK + "p1"


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def layout():
    return json.loads(output("/usr/sbin/sfdisk", "--json", DISK))["partitiontable"]


def validate_layout(table, capacity):
    require(table.get("label") == "gpt" and table.get("device") == DISK and table.get("sectorsize") == 512,
            "SD expansion requires the expected 512-byte GPT layout")
    parts = table.get("partitions", [])
    app = [p for p in parts if p.get("node") == ROOT]
    require(len(app) == 1 and app[0].get("name") == "APP", "Expected SD partition 1 named APP")
    app = app[0]
    require(app.get("uuid") and app.get("type", "").lower() == "0fc63daf-8483-4772-8e79-3d69d8477de4",
            "APP must be a Linux filesystem partition with a UUID")
    require(0 < app["start"] * 512 < 4 * 1024**3 and capacity >= 60_000_000_000 and
            (app["start"] + app["size"]) * 512 <= capacity,
            "Unexpected APP geometry or SD capacity")
    for part in parts:
        if part["node"] != ROOT:
            require(part["node"].startswith(DISK + "p") and
                    part["start"] > 0 and part["size"] > 0 and
                    part["start"] + part["size"] <= app["start"],
                    "APP is not the final physical partition; refusing to move or overwrite another partition")
    return app


def validate_preserved(before, after):
    require(before.get("id") == after.get("id"), "Disk UUID changed during expansion")
    old = {p["node"]: p for p in before["partitions"]}
    new = {p["node"]: p for p in after["partitions"]}
    require(old.keys() == new.keys(), "Partition set changed during expansion")
    for name, part in old.items():
        changed = dict(new[name])
        if name == ROOT:
            require(changed["size"] >= part["size"], "APP shrank unexpectedly")
            changed["size"] = part["size"]
        require(part == changed, "A partition start, UUID, or boot partition changed during expansion")


def expand(expected=None):
    require(os.geteuid() == 0, "SD expansion needs administrator authentication on the Jetson")
    require(platform.machine() == "aarch64" and "Orin Nano" in Path("/proc/device-tree/model").read_text(),
            "SD expansion is limited to the supported Orin Nano")
    require(output("findmnt", "-n", "-o", "FSTYPE", "/") == "ext4" and
            os.path.realpath(output("findmnt", "-n", "-o", "SOURCE", "/")) == ROOT,
            "Refusing expansion: the running root is not the SD APP ext4 filesystem")
    require(output("dpkg-query", "-W", "-f=${Version}", "nvidia-l4t-core").split("-")[0] == "39.2.1",
            "Expected L4T 39.2.1 before SD expansion")
    capacity = int(Path("/sys/class/block/mmcblk0/size").read_text()) * 512
    serial = Path("/sys/class/block/mmcblk0/device/serial").read_text().strip()
    expected = expected or {}
    require(not expected.get("TotalSize") or capacity == expected["TotalSize"], "SD capacity changed")
    require(not expected.get("serial") or int(serial, 16) == int(expected["serial"], 16), "SD card identity changed")
    before = layout()
    app = validate_layout(before, capacity)
    free_tail = capacity - (app["start"] + app["size"]) * 512
    if free_tail > 4 * 1024**2:
        print("Expanding SD APP into unused space; keeping its start/UUID and all boot partitions.", flush=True)
        # /run is RAM-backed: recovery must work even when the small rootfs is full.
        with tempfile.TemporaryDirectory(prefix="jetpack-grow-", dir="/run") as temporary:
            env = {**os.environ, "TMPDIR": temporary, "LC_ALL": "C"}
            subprocess.run(["/usr/bin/growpart", DISK, "1"], env=env, check=True)
        after = layout()
        validate_preserved(before, after)
        app = validate_layout(after, capacity)
    kernel_size = int(Path("/sys/class/block/mmcblk0p1/size").read_text())
    require(kernel_size == app["size"], "SD partition grew; reboot to refresh its kernel size, then resume first boot")
    fs = os.statvfs("/")
    if fs.f_blocks * fs.f_frsize < app["size"] * 512 * 0.90:
        print("Expanding the mounted SD ext4 filesystem...", flush=True)
        subprocess.run(["/usr/sbin/resize2fs", ROOT], check=True)
    fs = os.statvfs("/")
    require(capacity - app["size"] * 512 <= 4 * 1024**3 and
            fs.f_blocks * fs.f_frsize >= app["size"] * 512 * 0.90,
            "SD filesystem expansion is incomplete")
    print("SD expansion verified.", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expand", action="store_true", required=True)
    parser.add_argument("--mark-complete", action="store_true")
    args = parser.parse_args()
    expand()
    if args.mark_complete:
        Path("/var/lib/jetpack-sd-expanded").touch(mode=0o644)
