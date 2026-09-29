# SPDX-License-Identifier: Apache-2.0
"""Exercise device selection, serial transport, SD safety gates, and SSH identity."""
from contextlib import contextmanager, nullcontext, redirect_stdout
import base64
import io
import json
import os
from pathlib import Path
import pty
import signal
import subprocess
import tempfile
import termios
import time
import unittest
from unittest.mock import patch
import zlib

import first_boot as boot
import verify_orin as orin


def ready_report():
    return {
        "architecture": "aarch64", "model": "NVIDIA Jetson Orin Nano Developer Kit Super",
        "root_device": "/dev/mmcblk0p1", "ubuntu_version": "24.04",
        "l4t_release": "# R39 (release), REVISION: 2.1, GCID: example", "l4t_package": "39.2.1-20260901",
        "uid": 1000, "username": "jetson", "card_capacity_bytes": 62883102720,
        "root_partition_bytes": 60900000000, "filesystem_size_bytes": 59700000000,
        "sd_serial": "0x12345678", "machine_id": "a" * 32, "ssh_active": True,
        "ssh_host_key": "ssh-ed25519 " + base64.b64encode(b"test-public-key").decode(),
        "addresses": ["192.168.55.1", "192.168.1.5"],
    }


class DiscoveryTests(unittest.TestCase):
    def test_only_nvidia_descendant_serial_ports_are_selected(self):
        def usb(vendor, port, serial):
            return {"IOObjectClass": "IOUSBHostDevice", "idVendor": vendor, "USB Serial Number": serial,
                    "IORegistryEntryChildren": [{"IORegistryEntryChildren": [{"IOCalloutDevice": port}]}]}
        roots = [usb(0x0955, "/dev/cu.usbmodem123", "123"), usb(0x1234, "/dev/cu.usbmodem456", "456"),
                 {"IOCalloutDevice": "/dev/cu.debug-console"}]
        self.assertEqual([p["port"] for p in boot.ports_from_registry(roots)], ["/dev/cu.usbmodem123"])

    def test_recovery_usb_is_not_a_serial_console(self):
        self.assertEqual(boot.ports_from_registry([
            {"IOObjectClass": "IOUSBHostDevice", "idVendor": 0x0955, "USB Product Name": "APX"}]), [])

    def test_ambiguous_devices_need_explicit_selection_and_reconnect_uses_identity(self):
        ports = [{"port": "/dev/cu.usbmodem1", "serial": "one"},
                 {"port": "/dev/cu.usbmodem2", "serial": "two"}]
        with self.assertRaisesRegex(RuntimeError, "Multiple NVIDIA"):
            boot.choose_port(ports)
        self.assertEqual(boot.choose_port(ports, requested=ports[1]["port"]), ports[1])
        ports[0]["port"] = "/dev/cu.usbmodemNEW"
        self.assertEqual(boot.choose_port(ports, serial="one"), ports[0])
        self.assertIsNone(boot.choose_port(ports, serial="missing"))


class BootSafetyTests(unittest.TestCase):
    def test_wrong_boot_stops_before_ssh_or_sd_reads(self):
        for key, value in (("root_device", "/dev/nvme0n1p1"), ("l4t_package", "36.4.4-1"),
                           ("ubuntu_version", "22.04"), ("uid", 0), ("model", "Other board")):
            report = ready_report()
            report[key] = value
            with self.subTest(key=key), patch.object(orin, "snapshot", return_value=report), \
                 patch.object(orin.subprocess, "run") as mutation, patch.object(orin.Path, "read_text") as read, \
                 self.assertRaises(RuntimeError):
                orin.verify(enable_ssh=True)
            mutation.assert_not_called()
            read.assert_not_called()

    def test_unexpanded_or_wrong_card_is_rejected(self):
        report = ready_report()
        orin.validate_card(report, {"serial": "0x12345678", "TotalSize": report["card_capacity_bytes"]})
        for key, value in (("root_partition_bytes", 8 * 1024**3), ("filesystem_size_bytes", 8 * 1024**3),
                           ("card_capacity_bytes", 32 * 1024**3), ("sd_serial", "0xffffffff")):
            changed = {**report, key: value}
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                orin.validate_card(changed, {"serial": "0x12345678", "TotalSize": report["card_capacity_bytes"]})

    def test_failed_expansion_never_enables_ssh(self):
        report = ready_report()
        files = {"/sys/class/block/mmcblk0/size": str(report["card_capacity_bytes"] // 512),
                 "/sys/class/block/mmcblk0p1/size": str(8 * 1024**3 // 512),
                 "/sys/class/block/mmcblk0/device/serial": report["sd_serial"]}
        with patch.object(orin, "snapshot", return_value=report), \
             patch.object(orin.Path, "read_text", lambda path: files[str(path)]), \
             patch.object(orin.subprocess, "run") as mutation, self.assertRaisesRegex(RuntimeError, "expanded"):
            orin.verify(False)
        mutation.assert_not_called()

    def test_failed_growth_never_enables_ssh(self):
        report = ready_report()
        files = {"/sys/class/block/mmcblk0/size": str(report["card_capacity_bytes"] // 512),
                 "/sys/class/block/mmcblk0p1/size": str(8 * 1024**3 // 512),
                 "/sys/class/block/mmcblk0/device/serial": report["sd_serial"]}
        with patch.object(orin, "snapshot", return_value=report), \
             patch.object(orin.Path, "read_text", lambda path: files[str(path)]), \
             patch.dict(orin.__dict__, {"EXPAND_SD_SOURCE": b"# fixture"}), \
             patch.object(orin.subprocess, "run", side_effect=RuntimeError("growth failed")) as mutation, \
             redirect_stdout(io.StringIO()), self.assertRaisesRegex(RuntimeError, "growth failed"):
            orin.verify(True)
        self.assertEqual(mutation.call_count, 1)
        self.assertEqual(mutation.call_args.args[0][:3], ["sudo", "/usr/bin/python3", "-c"])


class SerialTransportTests(unittest.TestCase):
    def test_real_shell_handshake_payload_and_echo_restore(self):
        # Real PTY + bash, but a harmless probe replaces all Jetson commands.
        # This catches echoed-command false positives, line limits, and TTY cleanup.
        for ok in (True, False):
            with self.subTest(ok=ok):
                pid, master = pty.fork()
                if pid == 0:
                    os.execve("/bin/bash", ["bash", "--noprofile", "--norc", "--noediting", "-i"],
                              {**os.environ, "PS1": "TEST$ ", "PROMPT_COMMAND": ""})
                keyboard, keep_open = os.pipe()

                def payload(marker, *args):
                    result = {"ok": ok, "report": {"transport": "passed"}, "error": "expected test failure"}
                    source = "print('\\n' + " + repr(marker + json.dumps(result)) + ", flush=True)\n#" + \
                             base64.b64encode(os.urandom(6000)).decode()
                    return base64.b64encode(zlib.compress(source.encode())).decode()

                try:
                    with patch.object(boot, "raw_terminal", lambda: nullcontext(keyboard)), \
                         patch.object(boot, "display"), patch.object(boot, "probe_payload", side_effect=payload):
                        if ok:
                            self.assertEqual(boot.serial_verify(master), {"transport": "passed"})
                        else:
                            with self.assertRaisesRegex(RuntimeError, "expected test failure"):
                                boot.serial_verify(master)
                    deadline = time.monotonic() + 3
                    while not termios.tcgetattr(master)[3] & termios.ECHO and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertTrue(termios.tcgetattr(master)[3] & termios.ECHO)
                finally:
                    os.close(keyboard)
                    os.close(keep_open)
                    os.close(master)
                    try:
                        os.kill(pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                    os.waitpid(pid, 0)

    def test_shipping_probe_fits_serial_line_and_preserves_source(self):
        payload = boot.probe_payload("JETPACK_" + "f" * 24 + "_RESULT:", True,
                                     {"serial": "0x12345678", "TotalSize": 62883102720})
        self.assertGreater(len(payload), 4000)  # Exercises the need for chunking.
        decoded = zlib.decompress(base64.b64decode(payload))
        self.assertIn((boot.HERE / "verify_orin.py").read_bytes(), decoded)
        compile(decoded, "serial-probe", "exec")


class SshTests(unittest.TestCase):
    def test_network_candidate_must_match_key_from_physical_usb(self):
        report = ready_report()

        def scan(args, **kwargs):
            key = "ssh-ed25519 wrong-key" if args[-1] == "192.168.55.1" else report["ssh_host_key"]
            return subprocess.CompletedProcess(args, 0, stdout=args[-1] + " " + key + "\n")

        with patch.object(boot.subprocess, "run", side_effect=scan), redirect_stdout(io.StringIO()):
            self.assertEqual(boot.find_ssh_host(report), "192.168.1.5")

    def test_ssh_uses_strict_private_known_hosts_and_rejects_other_device(self):
        report = ready_report()

        def ssh(args, **kwargs):
            self.assertIn("StrictHostKeyChecking=yes", args)
            self.assertIn("GlobalKnownHostsFile=/dev/null", args)
            self.assertIn("/dev/null", args)
            self.assertNotIn("-t", args)
            changed = {**report, "machine_id": "other-device"}
            return subprocess.CompletedProcess(args, 0, stdout=args[-1] + json.dumps({"ok": True, "report": changed}))

        with tempfile.TemporaryDirectory() as folder, patch.object(boot, "probe_command", side_effect=lambda marker, **kw: marker), \
             patch.object(boot.subprocess, "run", side_effect=ssh), redirect_stdout(io.StringIO()), \
             self.assertRaisesRegex(RuntimeError, "SSH identity differs"):
            boot.ssh_verify(report, "192.168.55.1", Path(folder))


class ReceiptTests(unittest.TestCase):
    @contextmanager
    def workflow(self, cache, fail_ssh=False, disconnect=False, expansion_reboot=False):
        report = ready_report()
        device = {"port": "/dev/cu.usbmodemTEST", "serial": "same-jetson", "product": "Linux for Tegra"}
        with patch.object(boot.sys.stdin, "isatty", return_value=True), \
             patch.object(boot.sys.stdout, "isatty", return_value=True), \
             patch.object(boot, "wait_for_port", return_value=device) as wait, \
             patch.object(boot, "serial_connection", lambda port: nullcontext(99)), \
             patch.object(boot, "user_console", side_effect=[boot.Disconnected(), None] if disconnect else None), \
             patch.object(boot, "serial_verify", return_value=report,
                          side_effect=[{**report, "reboot_required": True}, report] if expansion_reboot else None), \
             patch.object(boot, "receive_marker", side_effect=boot.Disconnected()), \
             patch.object(boot, "find_ssh_host", return_value="192.168.55.1"), \
             patch.object(boot, "ssh_verify", side_effect=RuntimeError("SSH failed") if fail_ssh else None,
                          return_value=report):
            yield wait

    def test_no_success_receipt_when_ssh_fails(self):
        with tempfile.TemporaryDirectory() as folder, redirect_stdout(io.StringIO()):
            with self.workflow(folder, fail_ssh=True), self.assertRaisesRegex(RuntimeError, "SSH failed"):
                boot.first_boot(Path(folder))
            self.assertEqual(list(Path(folder).rglob("*receipt*")), [])

    def test_expansion_reboot_reconnects_before_ssh_and_receipt(self):
        with tempfile.TemporaryDirectory() as folder, redirect_stdout(io.StringIO()):
            with self.workflow(folder, expansion_reboot=True) as wait:
                receipt = boot.first_boot(Path(folder))
                self.assertEqual(wait.call_count, 2)
                wait.assert_called_with(serial="same-jetson")
            self.assertTrue(receipt["sd_boot_verified"])
            self.assertNotIn("reboot_required", receipt)

    def test_reconnect_pins_device_and_success_receipt_has_no_identifiers(self):
        with tempfile.TemporaryDirectory() as folder, redirect_stdout(io.StringIO()):
            with self.workflow(folder, disconnect=True) as wait:
                receipt = boot.first_boot(Path(folder))
                wait.assert_called_with(serial="same-jetson")
            self.assertEqual(receipt["status"], "first_boot_verified")
            self.assertTrue(receipt["ssh_verified"])
            self.assertFalse(receipt["demo_installation_run"])
            for key in ("sd_serial", "machine_id", "username", "addresses", "ssh_host_key"):
                self.assertNotIn(key, receipt)
            self.assertEqual(len(list(Path(folder).rglob("first-boot-receipt.json"))), 1)


if __name__ == "__main__":
    unittest.main()
