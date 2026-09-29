# SPDX-License-Identifier: Apache-2.0
"""Regression checks for preserving failed privileged-write diagnostics."""
from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

import mac


class MacDiagnosticsTests(unittest.TestCase):
    def test_atomic_output_replaces_a_readonly_previous_log(self):
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            old, new = directory / "write.log", directory / "new.log"
            old.write_text("old failure")
            old.chmod(0o444)
            new.write_text("current failure")
            mac.atomic_copy(new, old)
            self.assertEqual(old.read_text(), "current failure")
            self.assertEqual(sorted(path.name for path in directory.iterdir()), ["new.log", "write.log"])

    def test_failed_helper_retains_stage_and_copies_error_log(self):
        stages = []

        def expand_image(*args, **kwargs):
            if args[0] == "/unused/zstd":
                Path(args[-1]).write_bytes(b"test")

        class FailedHelper:
            returncode = 1

            def __init__(self, command, **kwargs):
                self.assert_sudo(command)
                assert "preexec_fn" not in kwargs
                assert not kwargs.get("start_new_session", False)
                stage = Path(command[3]).parent
                stages.append(stage)
                kwargs["stdout"].write("Operation not permitted: /dev/rdisk4\n")

            @staticmethod
            def assert_sudo(command):
                assert command[:3] == ["/usr/bin/sudo", "/usr/bin/python3", "-u"]

            def poll(self):
                return 1

        try:
            with tempfile.TemporaryDirectory() as folder:
                directory = Path(folder)
                (directory / "image.json").write_text(json.dumps({"size_bytes": 4}))
                with patch.object(mac, "run", side_effect=expand_image), \
                     patch.object(mac.sys.stdin, "isatty", return_value=True), \
                     patch.object(mac.subprocess, "Popen", FailedHelper), redirect_stdout(io.StringIO()), \
                     self.assertRaisesRegex(RuntimeError, "Flash did not complete"):
                    mac.write_card(directory, "/dev/disk4", {}, "/unused/zstd")
                self.assertTrue(stages[0].is_dir())
                self.assertIn("Operation not permitted", (directory / "write.log").read_text())
                self.assertTrue((stages[0] / "write.log").exists())
                self.assertFalse((directory / "flash-receipt.json").exists())
        finally:
            for stage in stages:
                shutil.rmtree(stage)

    def test_noninteractive_write_stops_before_staging_or_authentication(self):
        with patch.object(mac.sys.stdin, "isatty", return_value=False), \
             patch.object(mac.tempfile, "mkdtemp") as stage, \
             patch.object(mac, "run") as run, \
             self.assertRaisesRegex(RuntimeError, "Run the flash command in Terminal"):
            mac.write_card(Path("unused"), "/dev/disk4", {}, "/unused/zstd")
        stage.assert_not_called()
        run.assert_not_called()


class MacWorkflowTests(unittest.TestCase):
    def invoke(self, cache, *arguments):
        with patch.object(mac.sys, "argv", ["mac.py", "--cache-dir", str(cache), *arguments]), \
             patch.object(mac.platform, "system", return_value="Darwin"), \
             patch.object(mac.platform, "machine", return_value="arm64"), \
             patch.object(mac.platform, "mac_ver", return_value=("26.7", "", "")), \
             patch.object(mac.os, "geteuid", return_value=501), redirect_stdout(io.StringIO()):
            mac.main()

    def test_resume_never_requires_image_builder_or_touches_disk(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(mac, "first_boot") as boot, \
             patch.object(mac, "target_identity") as disk, patch.object(mac, "build_image") as build, \
             patch.object(mac, "validate_image") as validate, patch.object(mac, "write_card") as write, \
             patch.object(mac.subprocess, "run") as command, patch.object(mac.shutil, "which") as dependency:
            self.invoke(folder, "--first-boot-only")
            boot.assert_called_once_with(Path(folder).resolve(), None, None)
            for operation in (disk, build, validate, write, command, dependency):
                operation.assert_not_called()

    def test_failed_flash_never_starts_first_boot_and_flash_only_stops_at_ejection(self):
        for mode in ("failure", "flash-only", "full"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as folder:
                cache = Path(folder)
                (cache / "image").mkdir()
                (cache / "image/image.json").write_text("{}")
                target = {"MediaName": "SD", "TotalSize": 62883102720, "BusProtocol": "Secure Digital", "serial": "0x12345678"}
                with patch.object(mac, "target_identity", return_value=target), \
                     patch.object(mac, "validate_image"), patch.object(mac.subprocess, "run") as command, \
                     patch.object(mac.shutil, "which", return_value="/unused/zstd"), \
                     patch.object(mac, "write_card", side_effect=RuntimeError("flash failed") if mode == "failure" else None), \
                     patch.object(mac, "first_boot") as boot:
                    command.return_value.returncode = 0
                    args = ["--disk", "/dev/disk4", "--erase"] + (["--flash-only"] if mode == "flash-only" else [])
                    if mode == "failure":
                        with self.assertRaisesRegex(RuntimeError, "flash failed"):
                            self.invoke(cache, *args)
                    else:
                        self.invoke(cache, *args)
                    if mode == "full":
                        boot.assert_called_once_with(cache.resolve(), None, None,
                                                     {"serial": "0x12345678", "TotalSize": target["TotalSize"]})
                    else:
                        boot.assert_not_called()


if __name__ == "__main__":
    unittest.main()
