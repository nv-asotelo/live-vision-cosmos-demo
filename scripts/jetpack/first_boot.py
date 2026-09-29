# SPDX-License-Identifier: Apache-2.0
"""Guide NVIDIA's USB first-boot console, verify SD boot, then verify pinned SSH."""
import base64
from contextlib import contextmanager
from datetime import datetime, timezone
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import select
import shlex
import stat
import subprocess
import sys
import tempfile
import termios
import time
import tty
import zlib

from write_sd import require

HERE = Path(__file__).resolve().parent


class Disconnected(Exception):
    pass


def ports_from_registry(roots):
    ports = {}

    def visit(node, device=None):
        if node.get("IOObjectClass") == "IOUSBHostDevice":
            device = node if node.get("idVendor") == 0x0955 else None
        port = node.get("IOCalloutDevice", "")
        if device and port.startswith("/dev/cu.usbmodem") and device.get("USB Serial Number"):
            ports[port] = {"port": port, "serial": device["USB Serial Number"],
                           "product": device.get("USB Product Name", "NVIDIA USB serial")}
        for child in node.get("IORegistryEntryChildren", []):
            visit(child, device)

    for root in roots:
        visit(root)
    return list(ports.values())


def discover_ports():
    # -l is necessary: without it ioreg omits children's IOCalloutDevice properties.
    data = subprocess.check_output(["ioreg", "-a", "-l", "-p", "IOService", "-r", "-c", "IOUSBHostDevice"])
    return ports_from_registry(plistlib.loads(data))


def choose_port(ports, requested=None, serial=None):
    matches = [item for item in ports if (not requested or item["port"] == requested) and
               (not serial or item["serial"] == serial)]
    require(len(matches) <= 1, "Multiple NVIDIA serial ports found. Select one with --serial-port: " +
            ", ".join(item["port"] for item in matches))
    return matches[0] if matches else None


def wait_for_port(requested=None, serial=None, timeout=600):
    deadline = time.monotonic() + timeout
    while True:
        device = choose_port(discover_ports(), requested, serial)
        if device:
            return device
        require(time.monotonic() < deadline,
                "No NVIDIA USB serial console appeared. Check power/data cable and boot selection; "
                "recovery/APX mode cannot run first-boot setup. Resume with --first-boot-only.")
        time.sleep(2)


@contextmanager
def serial_connection(port):
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    settings = None
    try:
        require(stat.S_ISCHR(os.fstat(fd).st_mode), "Serial port must be a character device")
        fcntl.ioctl(fd, termios.TIOCEXCL)
        settings = termios.tcgetattr(fd)
        tty.setraw(fd, termios.TCSANOW)
        configured = termios.tcgetattr(fd)
        configured[2] |= termios.CLOCAL | termios.CREAD
        configured[4] = configured[5] = termios.B115200
        termios.tcsetattr(fd, termios.TCSANOW, configured)
        yield fd
    finally:
        if settings is not None:
            try:
                termios.tcsetattr(fd, termios.TCSANOW, settings)
                fcntl.ioctl(fd, termios.TIOCNXCL)
            except (OSError, termios.error):
                pass  # The USB gadget may have re-enumerated during NVIDIA setup.
        os.close(fd)


@contextmanager
def raw_terminal():
    fd = sys.stdin.fileno()
    settings = termios.tcgetattr(fd)
    try:
        tty.setraw(fd, termios.TCSANOW)
        yield fd
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, settings)


def read_serial(fd):
    try:
        data = os.read(fd, 16384)
    except OSError as error:
        if error.errno in (errno.EIO, errno.ENXIO, errno.ENODEV):
            raise Disconnected() from error
        raise
    if not data:
        raise Disconnected()
    return data


def send(fd, data):
    deadline = time.monotonic() + 15
    while data:
        if not select.select([], [fd], [], 1)[1]:
            require(time.monotonic() < deadline, "Serial write timed out")
            continue
        try:
            data = data[os.write(fd, data):]
        except OSError as error:
            if error.errno in (errno.EIO, errno.ENXIO, errno.ENODEV):
                raise Disconnected() from error
            raise


def display(data):
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()


def user_console(fd):
    print("\nPress Enter for NVIDIA setup. Complete its license/account/network prompts locally, then log in.\n"
          "Network: select Ethernet PCI if wired to your router, or Wireless ethernet for Wi-Fi; USB supplies no internet.\n"
          "At the Linux shell prompt, press Ctrl-] to verify SD boot and enable SSH. Ctrl-Q stops.\n"
          "No default credentials; passwords and console input are never logged.\n", flush=True)
    with raw_terminal() as keyboard:
        while True:
            ready, _, _ = select.select([fd, keyboard], [], [])
            if fd in ready:
                display(read_serial(fd))
            if keyboard in ready:
                data = os.read(keyboard, 4096)
                if not data or b"\x11" in data:
                    raise KeyboardInterrupt
                if b"\x1d" in data:
                    # Only an explicit user gesture starts commands; never guess an OOBE/password prompt.
                    return
                send(fd, data)


def receive_marker(fd, marker, timeout, interactive=False):
    deadline, buffered, displayed = time.monotonic() + timeout, b"", 0
    prefix = marker.encode()
    with raw_terminal() as keyboard:
        while time.monotonic() < deadline:
            ready, _, _ = select.select([fd, keyboard] if interactive else [fd], [], [], 1)
            if fd in ready:
                data = read_serial(fd)
                buffered += data.replace(b"\r", b"\n")
                while b"\n" in buffered:
                    line, buffered = buffered.split(b"\n", 1)
                    if line.startswith(prefix):
                        return line[len(prefix):].decode("utf-8")
                    if interactive:
                        display(line[displayed:] + b"\r\n")
                    displayed = 0
                # Show native sudo prompts immediately, even without a newline,
                # while keeping transport markers and machine-readable JSON out
                # of the user's setup flow.
                if interactive and not (buffered.startswith(prefix) or prefix.startswith(buffered)):
                    display(buffered[displayed:])
                    displayed = len(buffered)
                if len(buffered) > 65536:
                    displayed = max(0, displayed - (len(buffered) - 65536))
                    buffered = buffered[-65536:]
            if interactive and keyboard in ready:
                data = os.read(keyboard, 4096)
                if not data or b"\x11" in data:
                    send(fd, b"\x03")
                    raise KeyboardInterrupt
                send(fd, data)
    send(fd, b"\x03")
    raise RuntimeError("Console verification timed out. Log in at the Linux shell and resume with --first-boot-only.")


def probe_payload(marker, enable_ssh=False, expected=None):
    source = ("EXPAND_SD_SOURCE=" + repr((HERE / "expand_sd.py").read_bytes()) + "\n").encode() + \
        (HERE / "verify_orin.py").read_bytes() + (
        "\nemit_result(" + repr(marker) + "," + repr(enable_ssh) + "," + repr(expected or {}) + ")\n").encode()
    return base64.b64encode(zlib.compress(source)).decode()


def probe_command(marker, enable_ssh=False, expected=None):
    loader = "import base64,zlib;exec(zlib.decompress(base64.b64decode(" + \
             repr(probe_payload(marker, enable_ssh, expected)) + ")))"
    return "python3 -c " + shlex.quote(loader)


def decode_result(value):
    result = json.loads(value)
    require(result.get("ok") is True, result.get("error", "Invalid verification response"))
    return result["report"]


def serial_verify(fd, expected=None):
    token = "JETPACK_" + secrets.token_hex(12)
    handshake = token + "_SHELL"
    marker = token + "_RESULT:"
    payload = probe_payload(marker, True, expected)
    # The launcher proves Python is ready before sending each acknowledged chunk.
    # The subshell restores the Jetson's echo even on a failed check or Ctrl-C.
    # sudo keeps the real TTY; input()/base64 is only for our source, never passwords.
    ack = token + "_CHUNK"
    loader = ("import base64,zlib\nprint(" + repr("\n" + handshake) + ",flush=True)\nchunks=[]\n"
              "while True:\n    chunk=input()\n    if chunk=='.': break\n    chunks.append(chunk)\n"
              "    print(" + repr("\n" + ack) + ",flush=True)\n"
              "exec(zlib.decompress(base64.b64decode(''.join(chunks))))")
    launcher = "(_lv_tty=$(stty -g); trap 'stty \"$_lv_tty\"' EXIT; stty -echo; python3 -c " + shlex.quote(loader) + ")"
    send(fd, ("\r" + launcher + "\r").encode())
    receive_marker(fd, handshake, 10)
    # Short physical lines avoid canonical TTY input limits as the helper grows.
    for offset in range(0, len(payload), 512):
        send(fd, (payload[offset:offset + 512] + "\r").encode())
        receive_marker(fd, ack, 10)
    send(fd, b".\r")
    return decode_result(receive_marker(fd, marker, 300, interactive=True))


def valid_host(host):
    return bool(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]{0,252}", host))


def find_ssh_host(report, requested=None, timeout=90):
    hosts = [requested] if requested else list(dict.fromkeys(["192.168.55.1"] + report["addresses"]))
    require(all(valid_host(host) for host in hosts), "Use an IPv4 address or hostname for --host")
    require(len(hosts) <= 16, "Unexpectedly many network addresses on the Jetson; select --host explicitly")
    deadline = time.monotonic() + timeout
    print("Waiting for SSH over USB or the Jetson's LAN; checking the host key learned over USB...", flush=True)
    while True:
        for host in hosts:
            try:
                scan = subprocess.run(["ssh-keyscan", "-T", "2", "-t", "ed25519", host],
                                      stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=10)
            except subprocess.TimeoutExpired:
                continue
            for line in scan.stdout.splitlines():
                fields = line.split()
                if len(fields) >= 3 and " ".join(fields[1:3]) == report["ssh_host_key"]:
                    return host
        require(time.monotonic() < deadline,
                "No network path to this Jetson's SSH key. Check USB networking or connect Ethernet to your router; "
                "resume with --first-boot-only --host <Jetson-LAN-IP>.")
        time.sleep(3)


def ssh_verify(report, host, directory, expected=None):
    known_hosts = directory / "known_hosts"
    known_hosts.write_text(host + " " + report["ssh_host_key"] + "\n")
    known_hosts.chmod(0o600)
    marker = "JETPACK_" + secrets.token_hex(12) + "_SSH:"
    print("Verifying SSH as " + report["username"] + "@" + host + ". Enter your Jetson password if prompted.", flush=True)
    result = subprocess.run([
        "ssh", "-F", "/dev/null", "-T", "-o", "StrictHostKeyChecking=yes",
        "-o", "GlobalKnownHostsFile=/dev/null", "-o", "UserKnownHostsFile=" + str(known_hosts),
        "-o", "HostKeyAlgorithms=ssh-ed25519", "-o", "UpdateHostKeys=no", "-o", "ClearAllForwardings=yes",
        "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3",
        "-l", report["username"], host, probe_command(marker, expected=expected)],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, text=True)
    require(result.returncode == 0, "SSH verification failed. Check the authentication/network error above, then resume with --first-boot-only.")
    values = [line[len(marker):] for line in result.stdout.splitlines() if line.startswith(marker)]
    require(len(values) == 1, "SSH did not return a boot verification result")
    verified = decode_result(values[0])
    for key in ("machine_id", "sd_serial", "ssh_host_key", "username"):
        require(verified[key] == report[key], "SSH identity differs from the USB console: " + key)
    return verified


def first_boot(cache, serial_port=None, host=None, expected=None):
    require(sys.stdin.isatty() and sys.stdout.isatty(), "Run --first-boot-only in Mac Terminal for local account/password entry")
    if host:
        require(valid_host(host), "Use an IPv4 address or hostname for --host")
    print("\nMove the ejected SD to the powered-off Orin. Leave its monitor disconnected for headless setup.\n"
          "Connect USB-C data to this Mac, Ethernet to your router, and the Orin's normal power supply.\n"
          "Boot normally, without a recovery jumper. Waiting for the NVIDIA USB console...", flush=True)
    device = wait_for_port(serial_port)
    while True:
        try:
            print("Connected: " + device["product"] + " (" + device["port"] + ")", flush=True)
            with serial_connection(device["port"]) as fd:
                user_console(fd)
                report = serial_verify(fd, expected)
                if report.get("reboot_required"):
                    print("\nSD expanded; waiting for the requested reboot, then log in again.\n", flush=True)
                    # Reboot disconnects USB. Keep password entry local if sudo
                    # needs it again, then reconnect through the existing handler.
                    receive_marker(fd, "REBOOT_DOES_NOT_RETURN_A_MARKER", 90, interactive=True)
            break
        except (Disconnected, FileNotFoundError):
            print("\nUSB restarted. Waiting for the same Jetson to reconnect...", flush=True)
            device = wait_for_port(serial=device["serial"])
    directory = Path(tempfile.mkdtemp(prefix="first-boot-", dir=cache))
    host = find_ssh_host(report, host)
    verified = ssh_verify(report, host, directory, expected)
    # Local, sanitized receipt: no password, console log, serial number, machine ID, or private key.
    receipt = {key: verified[key] for key in (
        "model", "root_device", "ubuntu_version", "l4t_release", "l4t_package",
        "card_capacity_bytes", "root_partition_bytes", "filesystem_size_bytes", "ssh_active")}
    receipt.update({"status": "first_boot_verified", "completed_at": datetime.now(timezone.utc).isoformat(),
                    "sd_boot_verified": True, "filesystem_expansion_verified": True, "ssh_verified": True,
                    "demo_installation_run": False})
    path = directory / "first-boot-receipt.json"
    path.write_text(json.dumps(receipt, indent=2) + "\n")
    fingerprint = base64.b64encode(hashlib.sha256(base64.b64decode(verified["ssh_host_key"].split()[1])).digest()).decode().rstrip("=")
    print("\nJETPACK_READY: SD boot, filesystem expansion, and SSH passed. Receipt: " + str(path), flush=True)
    print("SSH: " + shlex.join(["ssh", verified["username"] + "@" + host]) + "\nHost fingerprint: SHA256:" + fingerprint, flush=True)
    print("JetPack OS preparation is complete. For the separately requested demo, return to README Quickstart.", flush=True)
    return receipt
