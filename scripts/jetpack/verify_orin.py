# SPDX-License-Identifier: Apache-2.0
"""Run on the Orin over serial/SSH; validate SD boot before enabling SSH.

Transported in memory by first_boot.py. No agent, credentials, or demo files are
installed. Keep this helper independent of Mac modules and third-party packages.
"""
import base64
import ipaddress
import json
import os
from pathlib import Path
import platform
import pwd
import re
import subprocess
import zlib


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def output(*command):
    return subprocess.check_output(command, text=True).strip()


def snapshot():
    root = output("findmnt", "-n", "-o", "SOURCE", "/")
    fs = os.statvfs("/")
    return {
        "architecture": platform.machine(),
        "model": Path("/proc/device-tree/model").read_text().strip("\x00\n"),
        "root_device": os.path.realpath(root),
        "ubuntu_version": platform.freedesktop_os_release().get("VERSION_ID"),
        "l4t_release": Path("/etc/nv_tegra_release").read_text().splitlines()[0],
        "l4t_package": output("dpkg-query", "-W", "-f=${Version}", "nvidia-l4t-core"),
        "uid": os.getuid(),
        "username": pwd.getpwuid(os.getuid()).pw_name,
        "filesystem_size_bytes": fs.f_blocks * fs.f_frsize,
    }


def validate_boot(report):
    require(report["architecture"] == "aarch64" and "Orin Nano" in report["model"],
            "Expected the supported Jetson Orin Nano developer kit")
    require(report["root_device"] == "/dev/mmcblk0p1",
            "Booted " + report["root_device"] + "; select the SD card in UEFI before continuing. SSH was not changed.")
    require(report["ubuntu_version"] == "24.04" and
            report["l4t_package"].split("-")[0] == "39.2.1" and
            re.search(r"# R39 .*REVISION: 2\.1(?:,|\s|$)", report["l4t_release"]),
            "Expected JetPack 7.2.1: Ubuntu 24.04 / L4T R39 revision 2.1")
    require(report["uid"] >= 1000 and re.fullmatch(r"[a-z_][a-z0-9_-]*", report["username"]),
            "Finish NVIDIA first-boot setup and log in with your new non-root account")


def validate_card_identity(report, expected):
    require(report["card_capacity_bytes"] >= 60_000_000_000, "Expected a 64 GB or larger SD card")
    if expected.get("TotalSize"):
        require(report["card_capacity_bytes"] == expected["TotalSize"], "SD capacity differs from the flashed card")
    if expected.get("serial"):
        require(int(report["sd_serial"], 16) == int(expected["serial"], 16),
                "This is a different SD card from the one just flashed")


def expanded(report):
    return (0 <= report["card_capacity_bytes"] - report["root_partition_bytes"] <= 4 * 1024**3 and
            report["filesystem_size_bytes"] >= report["root_partition_bytes"] * 0.90)


def validate_card(report, expected):
    validate_card_identity(report, expected)
    require(expanded(report),
            "The root filesystem has not expanded to use the SD card. Resume with --first-boot-only to repair it over USB.")


def verify(enable_ssh=False, expected=None):
    report = snapshot()
    validate_boot(report)  # In particular, refuse an existing NVMe boot before any mutation.
    report.update({
        "card_capacity_bytes": int(Path("/sys/class/block/mmcblk0/size").read_text()) * 512,
        "root_partition_bytes": int(Path("/sys/class/block/mmcblk0p1/size").read_text()) * 512,
        "sd_serial": Path("/sys/class/block/mmcblk0/device/serial").read_text().strip(),
    })
    validate_card_identity(report, expected or {})
    if enable_ssh and not expanded(report):
        print("The SD root is still small. Expanding this verified SD in place; enter your Jetson password if prompted.", flush=True)
        source = globals().get("EXPAND_SD_SOURCE")
        require(source, "Missing SD expansion helper")
        payload = base64.b64encode(zlib.compress(source)).decode()
        identity = {"TotalSize": report["card_capacity_bytes"], "serial": report["sd_serial"]}
        command = "import base64,zlib;ns={'__name__':'jetpack_expand_sd'};exec(zlib.decompress(base64.b64decode(" + \
                  repr(payload) + ")),ns);ns['expand'](" + repr(identity) + ")"
        try:
            subprocess.run(["sudo", "/usr/bin/python3", "-c", command], check=True)
        except subprocess.CalledProcessError:
            raise RuntimeError("SD expansion failed; inspect the error above. No SSH changes were made.") from None
        report["root_partition_bytes"] = int(Path("/sys/class/block/mmcblk0p1/size").read_text()) * 512
        fs = os.statvfs("/")
        report["filesystem_size_bytes"] = fs.f_blocks * fs.f_frsize
        validate_card(report, expected or {})
        # The old small image may have filled while OOBE created its swapfile.
        # A reboot lets those first-boot services retry with space available.
        report["reboot_required"] = True
        return report
    validate_card(report, expected or {})
    if enable_ssh:
        print("SD boot, L4T 39.2.1, and filesystem expansion passed. Enabling SSH.\n"
              "If prompted, enter your Jetson password in this terminal.", flush=True)
        # sudo reads directly from the Jetson TTY. Never use -S or pass a password.
        subprocess.run(["sudo", "/bin/sh", "-c",
                        "/usr/bin/ssh-keygen -A && /usr/bin/systemctl reset-failed ssh.service ssh.socket && "
                        "/usr/bin/systemctl enable --now ssh"], check=True)
    require(output("systemctl", "is-active", "ssh") == "active", "SSH service is not active")
    key = Path("/etc/ssh/ssh_host_ed25519_key.pub").read_text().split()
    require(len(key) >= 2 and key[0] == "ssh-ed25519", "Missing Ed25519 SSH host public key")
    addresses = []
    for interface in json.loads(output("ip", "-j", "-4", "address", "show", "up")):
        for info in interface.get("addr_info", []):
            address = ipaddress.ip_address(info["local"])
            if not address.is_loopback and not address.is_link_local and info.get("scope") == "global":
                addresses.append(str(address))
    report.update({
        "ssh_host_key": " ".join(key[:2]),
        "machine_id": Path("/etc/machine-id").read_text().strip(),
        "addresses": list(dict.fromkeys(addresses)),
        "ssh_active": True,
    })
    return report


def emit_result(marker, enable_ssh=False, expected=None):
    try:
        result = {"ok": True, "report": verify(enable_ssh, expected)}
    except Exception as error:
        result = {"ok": False, "error": str(error)}
    print("\n" + marker + json.dumps(result, separators=(",", ":")), flush=True)
    if result.get("ok") and result["report"].get("reboot_required"):
        print("SD expanded. Rebooting to let first-boot services retry; the Mac will reconnect.", flush=True)
        subprocess.run(["sudo", "/usr/bin/systemctl", "reboot"], check=True)
