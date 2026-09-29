# SPDX-License-Identifier: Apache-2.0
"""Partition growth must preserve APP start/UUID and every other partition."""
import copy
from contextlib import contextmanager, redirect_stdout
import io
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import expand_sd as sd


def layout():
    return {"label": "gpt", "device": sd.DISK, "sectorsize": 512, "id": "disk-uuid", "partitions": [
        {"node": sd.ROOT, "name": "APP", "start": 3139584, "size": 16726016, "uuid": "app-uuid",
         "type": "0fc63daf-8483-4772-8e79-3d69d8477de4"},
        {"node": sd.DISK + "p2", "start": 2048, "size": 262144, "name": "kernel", "uuid": "kernel-uuid"}]}


class ExpansionTests(unittest.TestCase):
    @contextmanager
    def device(self, table, kernel_size, filesystem_blocks):
        files = {"/proc/device-tree/model": "NVIDIA Jetson Orin Nano",
                 "/sys/class/block/mmcblk0/size": "122818560",
                 "/sys/class/block/mmcblk0p1/size": str(kernel_size),
                 "/sys/class/block/mmcblk0/device/serial": "0x12345678"}

        def output(*args):
            if args[0] == "dpkg-query":
                return "39.2.1-1"
            return "ext4" if "FSTYPE" in args else sd.ROOT

        with patch.object(sd.os, "geteuid", return_value=0), \
             patch.object(sd.platform, "machine", return_value="aarch64"), \
             patch.object(sd.Path, "read_text", lambda path: files[str(path)]), \
             patch.object(sd, "output", side_effect=output), \
             patch.object(sd, "layout", side_effect=table), \
             patch.object(sd.os, "statvfs", side_effect=[
                 SimpleNamespace(f_blocks=n, f_frsize=4096) for n in filesystem_blocks]), \
             redirect_stdout(io.StringIO()):
            yield

    def test_only_final_physical_app_is_allowed(self):
        original = layout()
        sd.validate_layout(original, 62883102720)
        for field, value in (("device", "/dev/nvme0n1"), ("label", "dos"), ("sectorsize", 4096)):
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                sd.validate_layout({**original, field: value}, 62883102720)
        changed = copy.deepcopy(original)
        changed["partitions"][1]["start"] = 20_000_000
        with self.assertRaisesRegex(RuntimeError, "final physical"):
            sd.validate_layout(changed, 62883102720)

    def test_growth_preserves_all_identifiers_starts_and_other_partitions(self):
        before, after = layout(), layout()
        after["partitions"][0]["size"] += 1_000_000
        sd.validate_preserved(before, after)
        for index, key, value in ((0, "start", 9999), (0, "uuid", "new"), (1, "size", 999), (1, "uuid", "new")):
            changed = copy.deepcopy(after)
            changed["partitions"][index][key] = value
            with self.subTest(index=index, key=key), self.assertRaises(RuntimeError):
                sd.validate_preserved(before, changed)

    def test_nvme_root_refused_before_partition_tools(self):
        def output(*args):
            return "ext4" if "FSTYPE" in args else "/dev/nvme0n1p1"
        with patch.object(sd.os, "geteuid", return_value=0), \
             patch.object(sd.platform, "machine", return_value="aarch64"), \
             patch.object(sd.Path, "read_text", return_value="NVIDIA Jetson Orin Nano"), \
             patch.object(sd, "output", side_effect=output), patch.object(sd, "layout") as read, \
             patch.object(sd.subprocess, "run") as write, self.assertRaisesRegex(RuntimeError, "not the SD"):
            sd.expand()
        read.assert_not_called()
        write.assert_not_called()

    def test_full_root_can_grow_using_ram_then_resume_without_writes(self):
        before, after = layout(), layout()
        after["partitions"][0]["size"] = 119678943
        with self.device([before, after], 119678943, [2000000, 14959867]), \
             patch.object(sd.tempfile, "TemporaryDirectory") as temporary, \
             patch.object(sd.subprocess, "run") as write:
            temporary.return_value.__enter__.return_value = "/run/jetpack-test"
            sd.expand({"serial": "0x12345678", "TotalSize": 62883102720})
            self.assertEqual(temporary.call_args.kwargs["dir"], "/run")
            self.assertEqual(write.call_args_list[0].args[0], ["/usr/bin/growpart", sd.DISK, "1"])
            self.assertEqual(write.call_args_list[0].kwargs["env"]["TMPDIR"], "/run/jetpack-test")
            self.assertEqual(write.call_args_list[1].args[0], ["/usr/sbin/resize2fs", sd.ROOT])
            self.assertEqual(write.call_count, 2)
        with self.device([after], 119678943, [14959867, 14959867]), \
             patch.object(sd.subprocess, "run") as write:
            sd.expand()
            write.assert_not_called()

    def test_stale_kernel_partition_size_stops_before_filesystem_write(self):
        after = layout()
        after["partitions"][0]["size"] = 119678943
        with self.device([after], 16726016, []), patch.object(sd.subprocess, "run") as write, \
             self.assertRaisesRegex(RuntimeError, "reboot to refresh"):
            sd.expand()
        write.assert_not_called()


if __name__ == "__main__":
    unittest.main()
