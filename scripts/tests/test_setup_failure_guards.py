# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Offline installer failures: temporary fixtures, no root, devices or downloads."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SDK = "95515c2f87fba8982db5a519f9022277667b3cc9"
HEAVY_STAGES = (
    "fetch_edgellm", "edgellm_venv", "build_edgellm_runtime", "quantize",
    "export_onnx_llm", "export_onnx_visual", "validate_chat_template", "build_engine",
)
ARTIFACTS = (
    "sdk/.venv/bin/python", "sdk/build/examples/llm/llm_build",
    "sdk/build/examples/multimodal/visual_build", "sdk/build/libNvInfer_edgellm_plugin.so",
    "onnx/llm/model.onnx", "onnx/visual/model.onnx",
    "engines/llm.engine", "engines/visual/visual.engine", "engines/chat_template.jinja",
)

COMMON = r'''
STATE_DIR="$FIXTURE/state"
EDGELLM_DIR="$FIXTURE/sdk"
EDGELLM_PY="$EDGELLM_DIR/.venv/bin/python"
ONNX_DIR="$FIXTURE/onnx"
ENGINE_DIR="$FIXTURE/engines"
BUILD_SWAPFILE="$FIXTURE/build-swap.img"
'''

# These stand in for all privileged/Linux-specific operations. Sparse fixture files
# use logical 4 GiB sizes without allocating that much disk space or memory.
SWAP_FAKE = r'''
stat() {
  "$TEST_PYTHON" - "$2" "${@: -1}" <<'PY'
import os, sys
s = os.stat(sys.argv[2])
print(s.st_size if sys.argv[1] == "%s" else f"{s.st_dev}:{s.st_ino}")
PY
}
fallocate() {
  echo allocate >> "$FIXTURE/events"
  [[ "${FAIL_ALLOCATE:-0}" == 0 ]] || return 1
  "$TEST_PYTHON" - "$BUILD_SWAPFILE" "$BUILD_SWAP_BYTES" <<'PY'
import sys
with open(sys.argv[1], "r+b") as f:
    f.truncate(int(sys.argv[2]))
PY
}
dd() { echo allocation-fallback >> "$FIXTURE/events"; return 1; }
mkswap() {
  echo initialize >> "$FIXTURE/events"
  [[ "${FAIL_INITIALIZE:-0}" == 0 ]]
}
swapon() {
  if [[ "$1" == --show ]]; then
    [[ "${FAIL_INVENTORY:-0}" == 0 ]] || return 1
    [[ ! -f "$FIXTURE/active" ]] || cat "$FIXTURE/active"
    return 0
  fi
  echo activate >> "$FIXTURE/events"
  [[ "${FAIL_ACTIVATE:-0}" == 0 ]] || { echo 'fixture: swapon rejected file' >&2; return 1; }
  [[ "${LIE_ACTIVATE:-0}" == 0 ]] || return 0
  printf '%s %s\n' "$BUILD_SWAPFILE" "$((BUILD_SWAP_BYTES - $(getconf PAGESIZE)))" >> "$FIXTURE/active"
}
swapoff() {
  echo deactivate >> "$FIXTURE/events"
  [[ "${FAIL_DEACTIVATE:-0}" == 0 ]] || return 1
  [[ "${LIE_DEACTIVATE:-0}" == 0 ]] || return 0
  awk -v path="$BUILD_SWAPFILE" '$1 != path' "$FIXTURE/active" > "$FIXTURE/remaining"
  mv "$FIXTURE/remaining" "$FIXTURE/active"
  [[ -s "$FIXTURE/active" ]] || rm -f "$FIXTURE/active"
}
trap 'setup_exit_cleanup "$?"' EXIT
'''


class SetupFailureGuards(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.fixture = Path(self.temporary.name)
        (self.fixture / "state").mkdir()

    def run_shell(self, command, *, swap=False):
        env = {
            **os.environ, "FIXTURE": str(self.fixture), "TEST_PYTHON": sys.executable,
            "REACHY_MINI_IP": "192.0.2.50", "HF_TOKEN_FILE": "", "HF_TOKEN": "",
        }
        # Sourcing defines functions but main() is guarded by BASH_SOURCE == $0.
        return subprocess.run(
            ["bash", "-c", 'source "$1"\n' + COMMON + (SWAP_FAKE if swap else "") + command,
             "test", str(ROOT / "scripts/setup-orin.sh")],
            env=env, text=True, capture_output=True, timeout=15,
        )

    def populate_completed_install(self):
        for stage in HEAVY_STAGES:
            (self.fixture / "state" / stage).write_text(SDK + "\n")
        for relative in ARTIFACTS:
            path = self.fixture / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture artifact\n")

    def swap_fixture(self):
        path = self.fixture / "build-swap.img"
        with path.open("wb") as handle:
            handle.truncate(4 * 1024**3)
        return path

    def events(self):
        path = self.fixture / "events"
        return path.read_text().splitlines() if path.exists() else []

    def test_early_or_unrelated_marker_does_not_lower_space_requirement(self):
        for marker in ("system_packages", "unrelated", "build_edgellm_runtime"):
            (self.fixture / "state" / marker).write_text(SDK)
            result = self.run_shell("minimum_free_space_gib")
            self.assertEqual((result.returncode, result.stdout.strip()), (0, "25"), result.stderr)

    def test_current_completed_install_keeps_maintenance_allowance(self):
        self.populate_completed_install()
        result = self.run_shell("minimum_free_space_gib")
        self.assertEqual((result.returncode, result.stdout.strip()), (0, "8"), result.stderr)
        # No quantized checkpoint exists: valid for a completed host-export installation.
        self.assertFalse((self.fixture / "checkpoints").exists())

    def test_stale_markers_and_missing_artifacts_require_build_headroom(self):
        self.populate_completed_install()
        marker = self.fixture / "state/build_engine"
        for stale in ("", "old-sdk"):
            marker.write_text(stale)
            self.assertEqual(self.run_shell("minimum_free_space_gib").stdout.strip(), "25")
        marker.write_text(SDK)
        for relative in ARTIFACTS:
            artifact = self.fixture / relative
            artifact.write_text("")
            self.assertEqual(self.run_shell("minimum_free_space_gib").stdout.strip(), "25", relative)
            artifact.write_text("fixture artifact\n")

    def test_new_swap_is_verified_then_removed_on_success(self):
        result = self.run_shell("enable_build_swap; echo BUILD; disable_build_swap", swap=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("BUILD", result.stdout)
        self.assertEqual(self.events(), ["allocate", "initialize", "activate", "deactivate"])
        self.assertFalse((self.fixture / "build-swap.img").exists())

    def test_rejected_or_unverified_activation_stops_before_build(self):
        for flag in ("FAIL_ACTIVATE", "LIE_ACTIVATE"):
            with self.subTest(flag=flag):
                result = self.run_shell(f"{flag}=1; enable_build_swap; echo MUST_NOT_BUILD", swap=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("MUST_NOT_BUILD", result.stdout)
                self.assertIn("no engine build was started", result.stderr)
                self.assertFalse((self.fixture / "build-swap.img").exists())

    def test_real_build_stage_cannot_start_or_mark_complete_after_swap_failure(self):
        result = self.run_shell('''
pause_inference() { SHIM_PAUSED=1; }
sudo() { echo MUST_NOT_INVOKE_BUILD; return 0; }
FAIL_ACTIVATE=1
stage build_engine do_build_engine
''', swap=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("MUST_NOT_INVOKE_BUILD", result.stdout)
        self.assertFalse((self.fixture / "state/build_engine").exists())
        self.assertIn("remains stopped", result.stderr)

    def test_allocation_and_initialization_errors_clean_only_created_file(self):
        for flag in ("FAIL_ALLOCATE", "FAIL_INITIALIZE"):
            with self.subTest(flag=flag):
                result = self.run_shell(f"{flag}=1; enable_build_swap; echo MUST_NOT_BUILD", swap=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("MUST_NOT_BUILD", result.stdout)
                self.assertFalse((self.fixture / "build-swap.img").exists())

    def test_build_failure_cleans_owned_swap_and_keeps_original_status(self):
        result = self.run_shell("enable_build_swap; SHIM_PAUSED=1; exit 42", swap=True)
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn("remains stopped", result.stderr)
        self.assertFalse((self.fixture / "build-swap.img").exists())
        self.assertIn("deactivate", self.events())

    def test_swapoff_failure_or_false_success_preserves_active_file(self):
        for flag in ("FAIL_DEACTIVATE", "LIE_DEACTIVATE"):
            with self.subTest(flag=flag):
                # Exercise exit cleanup once, after a failed builder.
                result = self.run_shell(f"enable_build_swap; {flag}=1; exit 42", swap=True)
                self.assertEqual(result.returncode, 42)
                self.assertIn("preserving", result.stderr)
                self.assertTrue((self.fixture / "build-swap.img").exists())
                self.assertTrue((self.fixture / "active").exists())
                (self.fixture / "build-swap.img").unlink()
                (self.fixture / "active").unlink()

    def test_preexisting_active_swap_is_never_disabled_or_deleted(self):
        path = self.swap_fixture()
        (self.fixture / "active").write_text(f"{path} {4 * 1024**3}\n")
        result = self.run_shell("enable_build_swap; disable_build_swap", swap=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events(), [])
        self.assertTrue(path.exists())
        self.assertTrue((self.fixture / "active").exists())

    def test_preexisting_inactive_file_is_preserved_after_use(self):
        path = self.swap_fixture()
        result = self.run_shell("enable_build_swap; disable_build_swap", swap=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events(), ["activate", "deactivate"])
        self.assertTrue(path.exists())
        self.assertFalse((self.fixture / "active").exists())

    def test_other_active_swap_is_untouched(self):
        other = "/dev/zram0 1073741824\n"
        (self.fixture / "active").write_text(other)
        result = self.run_shell("enable_build_swap; disable_build_swap", swap=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.fixture / "active").read_text(), other)
        self.assertFalse((self.fixture / "build-swap.img").exists())

    def test_existing_undersized_active_swap_blocks_build_without_changes(self):
        path = self.swap_fixture()
        (self.fixture / "active").write_text(f"{path} 1048576\n")
        result = self.run_shell("enable_build_swap; echo MUST_NOT_BUILD", swap=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("MUST_NOT_BUILD", result.stdout)
        self.assertIn("smaller than the required", result.stderr)
        self.assertTrue(path.exists())
        self.assertEqual(self.events(), [])

    def test_symlink_and_small_existing_file_are_not_rewritten(self):
        path = self.fixture / "build-swap.img"
        target = self.fixture / "unrelated"
        target.write_text("leave me alone")
        path.symlink_to(target)
        result = self.run_shell("enable_build_swap", swap=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(path.is_symlink())
        self.assertEqual(target.read_text(), "leave me alone")
        path.unlink()
        path.write_text("partial swap file")
        result = self.run_shell("enable_build_swap", swap=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(path.read_text(), "partial swap file")
        self.assertEqual(self.events(), [])

    def test_unavailable_inventory_does_not_create_or_delete_swap(self):
        result = self.run_shell("FAIL_INVENTORY=1; enable_build_swap", swap=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Cannot inspect active swap", result.stderr)
        self.assertEqual(self.events(), [])

    def test_unavailable_inventory_during_cleanup_preserves_owned_file(self):
        result = self.run_shell("enable_build_swap; FAIL_INVENTORY=1; exit 42", swap=True)
        self.assertEqual(result.returncode, 42)
        self.assertIn("Cannot inspect swap during cleanup", result.stderr)
        self.assertTrue((self.fixture / "build-swap.img").exists())
        self.assertTrue((self.fixture / "active").exists())

    def test_replaced_path_is_not_cleaned_up(self):
        result = self.run_shell('''
enable_build_swap
mv "$BUILD_SWAPFILE" "$FIXTURE/owned-original"
printf 'unrelated replacement' > "$BUILD_SWAPFILE"
exit 42
''', swap=True)
        self.assertEqual(result.returncode, 42)
        self.assertIn("path changed", result.stderr)
        self.assertEqual((self.fixture / "build-swap.img").read_text(), "unrelated replacement")
        self.assertNotIn("deactivate", self.events())


if __name__ == "__main__":
    unittest.main()
