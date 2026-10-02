#!/usr/bin/env bash
# One-shot Orin-side build + install for Live Vision + Reachy Mini + Cosmos3-Edge.
#
# Everything that needs a GPU, a large download, or a compiler runs here, on the Orin.
# scripts/bootstrap.sh (run from a laptop) copies this repo to the Orin and invokes this
# script over SSH; it does not need a GPU or any particular OS itself.
#
# Idempotent: each stage records a marker file under $INSTALL_DIR/.setup-state/ and is
# skipped on re-run once its marker exists. Delete a marker (sudo rm - they are root's) or the
# whole directory to force that stage to redo its work. Safe to re-run after a failure - fix the
# reported problem and run it again; completed stages are not repeated.
#
# No Hugging Face token is needed: nvidia/Cosmos3-Edge is public and not gated. If HF_TOKEN is
# set anyway - in the environment or, as scripts/bootstrap.sh passes it, in a file named by
# HF_TOKEN_FILE, which keeps it off command lines - the download uses it.
#
# Optional: REACHY_MINI_IP (skip Reachy Mini bridge/motor setup entirely if unset). It is kept
# in $INSTALL_DIR/reachy.env, so later re-runs don't need it again; change robots afterwards
# with scripts/set-reachy-ip.sh, which takes seconds and rebuilds nothing.
set -euo pipefail

# ---------------------------------------------------------------------------------------
# Configuration - pinned versions match the exact revisions this repo's shim and systemd
# units were built and tested against. Do not bump these without re-validating the whole
# pipeline; TensorRT-Edge-LLM's ABI and the Cosmos3-Edge checkpoint format both move.
# ---------------------------------------------------------------------------------------
INSTALL_DIR="/opt/live-vision-cosmos-demo"
EDGELLM_COMMIT="e8b29522938901f6df19ebeedd4b69bc8edbcd97"   # tag v0.10.1
COSMOS_MODEL_REPO="nvidia/Cosmos3-Edge"
COSMOS_MODEL_REVISION="344d602b128d1bbdacb43b08d0a3626f46343e29"
PIPER_VERSION="1.2.0"
PIPER_VOICE="${PIPER_VOICE:-en_US-ljspeech-medium}"   # see NOTICE.md before changing voices
SERVICE_USER="${SERVICE_USER:-${SUDO_USER:-$(id -un)}}"
REACHY_MINI_IP="${REACHY_MINI_IP:-}"
HF_TOKEN="${HF_TOKEN:-}"
# bootstrap.sh hands the token over in a 0600 file rather than on a command line, where `ps` on
# either machine and sudo's own log would show it. Read it and delete the file straight away.
HF_TOKEN_FILE="${HF_TOKEN_FILE:-}"
if [[ -n "$HF_TOKEN_FILE" ]]; then
  [[ -n "$HF_TOKEN" || ! -r "$HF_TOKEN_FILE" ]] || HF_TOKEN="$(tr -d '\r\n' < "$HF_TOKEN_FILE")"
  rm -f "$HF_TOKEN_FILE"
fi
export HF_TOKEN

STATE_DIR="$INSTALL_DIR/.setup-state"
EDGELLM_DIR="$INSTALL_DIR/external/TensorRT-Edge-LLM"
EDGELLM_PY="$EDGELLM_DIR/.venv/bin/python"
CKPT_ROOT="$INSTALL_DIR/checkpoints/Cosmos3-Edge"
RAW_DIR="$CKPT_ROOT/raw"
QUANT_DIR="$CKPT_ROOT/quantized"
ONNX_DIR="$CKPT_ROOT/onnx/reasoning"
ENGINE_DIR="$INSTALL_DIR/engines/reasoning"

# shellcheck source=reachy-address.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/reachy-address.sh"
# A re-run without REACHY_MINI_IP keeps the robot this Orin is already configured for, rather
# than quietly dropping it.
REACHY_MINI_IP="${REACHY_MINI_IP:-$(reachy_address_configured)}"

log() { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mFATAL\033[0m %s\n' "$*" >&2; exit 1; }

stage_done() { [[ -e "$STATE_DIR/$1" ]]; }
stage_mark() { mkdir -p "$STATE_DIR"; touch "$STATE_DIR/$1"; }
stage() {
  local name="$1"; shift
  if stage_done "$name"; then
    log "skip: $name (already done - sudo rm $STATE_DIR/$name to redo)"
    return 0
  fi
  log "stage: $name"
  "$@"
  stage_mark "$name"
}

# ---------------------------------------------------------------------------------------
# Stages
# ---------------------------------------------------------------------------------------

do_preflight() {
  [[ "$(uname -s)" == Linux && "$(uname -m)" == aarch64 ]] || die "run this on the Jetson Orin (aarch64 Linux), not here."
  [[ -r /proc/device-tree/model ]] && tr '\000' '\n' < /proc/device-tree/model | grep -qi 'Jetson.*Orin' \
    || warn "device-tree model doesn't say Jetson Orin - continuing anyway, but double check you're on the right box."
  [[ "$EUID" -eq 0 ]] || die "run with sudo: sudo -E bash $0"
  # It's written into reachy.env and a URL; reject anything that isn't plainly an address.
  [[ -z "$REACHY_MINI_IP" ]] || reachy_address_valid "$REACHY_MINI_IP" \
    || die "REACHY_MINI_IP='$REACHY_MINI_IP' is not an IPv4 address or a hostname - give just the robot's address, e.g. 192.0.2.50 or reachy-mini.local."
  # Also substituted into the UI unit, and split into lang-voice-quality by do_setup_piper.
  [[ "$PIPER_VOICE" =~ ^[A-Za-z0-9_]+-[A-Za-z0-9_]+-[A-Za-z0-9_]+$ ]] \
    || die "PIPER_VOICE='$PIPER_VOICE' isn't a Piper voice name (language_REGION-name-quality, e.g. en_US-ljspeech-medium)."
  command -v python3 >/dev/null || die "python3 not found - is JetPack actually flashed and booted?"
  [[ $(dpkg-query -W -f='${Version}' nvidia-l4t-core 2>/dev/null || true) == 39.2.1-* ]] \
    || die "This pinned demo requires JetPack 7.2.1 / L4T 39.2.1. An existing compatible installation is fine; for fresh Mac SD preparation see docs/jetpack-sd-mac.md."
  local avail_kb; avail_kb=$(df -Pk "$(dirname "$INSTALL_DIR")" | awk 'NR==2{print $4}')
  local avail_gb=$((avail_kb / 1024 / 1024))
  # 25 GiB covers the WHOLE pipeline from a cold start (checkpoint + build tree + exports +
  # engine). On a resume, the disk-heaviest stages (checkpoint download, quantize, the native
  # compile) are often already done and their output is already on disk - re-demanding the
  # full-pipeline minimum on every single invocation would wrongly block a resume that has
  # genuinely enough room left for what remains (export/engine-build/piper, a few GiB).
  local min_gb=25
  [[ -z "$(ls -A "$STATE_DIR" 2>/dev/null)" ]] || min_gb=8
  [[ "$avail_gb" -ge "$min_gb" ]] || die "only ${avail_gb} GiB free under $(dirname "$INSTALL_DIR") - need at least ${min_gb} GiB ($( [[ "$min_gb" -eq 25 ]] && echo "whole pipeline: checkpoint + TensorRT-Edge-LLM build tree + exported engines" || echo "resuming - remaining stages only" )). Free up space or point INSTALL_DIR's parent at a larger disk/SD card."
  [[ "$avail_gb" -ge 40 || "$min_gb" -eq 8 ]] || warn "${avail_gb} GiB free is tight. The build will likely fit, but there's little margin - consider a 64 GB+ card if this is a fresh flash."
  mkdir -p "$INSTALL_DIR"
  id -u "$SERVICE_USER" >/dev/null 2>&1 || die "SERVICE_USER=$SERVICE_USER does not exist. Set SERVICE_USER to the account that should own and run these services (not root)."
  # SERVICE_USER falls back to $SUDO_USER, then to id -un - but id -un reports the CURRENT
  # (already-root) identity if this was invoked via sudo without SUDO_USER set (e.g. `su -c`,
  # or a manually assembled `sudo env ...` that drops sudo's own env vars). That silently makes
  # every "sudo -u $SERVICE_USER" below a no-op, root-owning the whole install - which then
  # fails confusingly, hours later, at an unrelated pip/permission step. Catch it here instead.
  [[ "$SERVICE_USER" != root ]] || die "SERVICE_USER resolved to 'root' - set SERVICE_USER=<your-login-user> explicitly, or invoke via scripts/bootstrap.sh (which sets it correctly before escalating)."
  chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
}

do_system_packages() {
  apt-get update -o Acquire::Retries=3
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential binutils cmake git ca-certificates \
    python3-venv python3-dev python3-pip \
    python3-requests \
    curl jq sox openssl
  # python3-requests: the UI service runs the system python3, and with a robot configured
  # (--reachy-daemon-url) it imports reachy/reachy.py, which needs requests. Ubuntu's system
  # python is externally managed (PEP 668), so this - not pip - is how it gets there.
}

do_pin_clocks() {
  # Default nvpmodel on this board (Orin Nano Super) is "25W" (mode 1), one step below the
  # uncapped "MAXN_SUPER" (mode 2) - and jetson_clocks (which pins the GPU/CPU/EMC clocks to
  # whatever ceiling the active nvpmodel mode allows, instead of leaving them under the
  # schedutil governor's dynamic control) is never persistent across a reboot on its own,
  # regardless of nvpmodel mode. Measured effect of both together (images new to the shim, so
  # the vision encoder really runs):  GPU clock 306-918 MHz under the governor -> 1020 MHz
  # (MAXN_SUPER ceiling), decode 14.77 -> 13.20 ms/token, 640x480 image + 1 token 305 -> 284 ms
  # - 36-60 ms off every request, reproduced pinned/unpinned/pinned.
  # nvpmodel's mode selection is itself persistent (written to /etc/nvpmodel.conf's active
  # state); jetson_clocks needs the small boot-time unit below.
  nvpmodel -m 2
  # nvpmodel -m silently keeps the previous mode if the requested ID doesn't exist in
  # /etc/nvpmodel.conf on this board - mode IDs are not portable across Jetson modules. This
  # pipeline is already pinned to one specific board/JetPack combination (see do_preflight),
  # but confirm rather than assume: warn, don't die, since this is a performance optimization,
  # not a correctness requirement - a missing MAXN_SUPER mode shouldn't block the whole setup.
  [[ "$(nvpmodel -q 2>/dev/null | head -1)" == *MAXN_SUPER* ]] \
    || warn "nvpmodel did not report MAXN_SUPER after 'nvpmodel -m 2' - this board's mode IDs may differ from the Orin Nano Super this was measured on. Check 'nvpmodel -q' and /etc/nvpmodel.conf's POWER_MODEL list; decode latency will be higher without the uncapped power mode."
  cat > /etc/systemd/system/jetson-clocks.service <<'UNIT'
[Unit]
Description=Pin Jetson clocks to the active nvpmodel ceiling
After=nvpmodel.service
Wants=nvpmodel.service

[Service]
Type=oneshot
ExecStart=/usr/bin/jetson_clocks
# jetson_clocks writes the CPU and GPU floors with its errors discarded, and at boot those
# writes don't always take: in 6 measured boots the CPU floor stayed at nvpmodel's default in 3
# and the GPU floor in 1, with nothing logged. So check every 2 s for 30 s and pin again
# whenever a floor is below its ceiling.
ExecStartPost=/bin/bash -c 'pinned() { g=$$(ls -d /sys/class/devfreq/*.gpu 2>/dev/null | head -1); [ -n "$$g" ] && [ "$$(cat $$g/min_freq)" = "$$(cat $$g/max_freq)" ] || return 1; for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do [ "$$(cat $$c/scaling_min_freq)" = "$$(cat $$c/scaling_max_freq)" ] || return 1; done; }; for i in $$(seq 15); do sleep 2; pinned || /usr/bin/jetson_clocks; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  # enable + restart, not `enable --now` and not a bare jetson_clocks call. The unit Wants=
  # nvpmodel.service, so starting it re-runs nvpmodel.service, which re-applies the mode's
  # default clock floors - and `--now` on an already-active RemainAfterExit unit then never runs
  # jetson_clocks again to pin them back (measured: GPU floor left at 306 MHz on a re-run). A
  # restart re-executes the unit after nvpmodel.service finishes (After=), the same order as boot.
  systemctl enable jetson-clocks.service
  systemctl restart jetson-clocks.service
  local gpu cpu; gpu="$(ls -d /sys/class/devfreq/*.gpu 2>/dev/null | head -1)"
  [[ -n "$gpu" && "$(cat "$gpu/min_freq")" == "$(cat "$gpu/max_freq")" ]] \
    || warn "GPU clock floor is not pinned to its ceiling after jetson_clocks (${gpu:-no GPU devfreq node found}) - decode latency will be higher. Check 'sudo jetson_clocks --show'."
  for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
    [[ "$(cat "$cpu/scaling_min_freq")" == "$(cat "$cpu/scaling_max_freq")" ]] \
      || { warn "CPU clock floor ($cpu) is not pinned to its ceiling after jetson_clocks. Check 'sudo jetson_clocks --show'."; break; }
  done
}

do_jetpack_compute() {
  bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install-jetpack-compute.sh"
  # Downloaded .deb archives are never needed again once installed - on a real run this and
  # the pip cache purge in build_edgellm_runtime reclaim roughly 8 GB combined, which matters:
  # do_preflight's 25 GiB minimum for the whole pipeline (checkpoint, ONNX export, engine
  # build) assumes these caches aren't also sitting on disk at the same time.
  apt-get clean
}

do_fetch_repo_self() {
  # This script is expected to already be running from within a checkout at $INSTALL_DIR
  # (scripts/bootstrap.sh's job). If invoked some other way with the repo sitting elsewhere,
  # copy it into place so every later stage's relative paths (systemd units, ui/, etc.) work.
  local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if [[ "$here" != "$INSTALL_DIR" ]]; then
    log "repo checkout is at $here, copying to $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    cp -a "$here"/. "$INSTALL_DIR"/
    chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
  fi
}

do_fetch_edgellm() {
  # sudo -u, not plain mkdir: a root-owned parent here would make the git clone below (which
  # runs as $SERVICE_USER) fail with "Permission denied" creating its own work tree inside it.
  sudo -u "$SERVICE_USER" mkdir -p "$(dirname "$EDGELLM_DIR")"
  if [[ ! -e "$EDGELLM_DIR" ]]; then
    sudo -u "$SERVICE_USER" git -c credential.helper= clone --depth 1 \
      https://github.com/NVIDIA/TensorRT-Edge-LLM.git "$EDGELLM_DIR"
  fi
  [[ -z "$(sudo -u "$SERVICE_USER" git -C "$EDGELLM_DIR" status --porcelain)" ]] \
    || die "$EDGELLM_DIR has local changes - resolve or remove before re-running."
  sudo -u "$SERVICE_USER" git -c credential.helper= -C "$EDGELLM_DIR" fetch --depth 1 origin "$EDGELLM_COMMIT"
  sudo -u "$SERVICE_USER" git -C "$EDGELLM_DIR" checkout --detach "$EDGELLM_COMMIT"
  sudo -u "$SERVICE_USER" git -c credential.helper= -C "$EDGELLM_DIR" submodule update --init --recursive
}

do_edgellm_venv() {
  local cuda_bin; cuda_bin="$(ls -d /usr/local/cuda-*/bin 2>/dev/null | sort -V | tail -1)"
  [[ -n "$cuda_bin" ]] || die "CUDA toolkit missing; check the jetpack_compute stage and scripts/install-jetpack-compute.sh."
  local cuda_ver; cuda_ver="$(basename "$(dirname "$cuda_bin")" | sed 's/cuda-//')"
  sudo -u "$SERVICE_USER" python3 -m venv --system-site-packages "$EDGELLM_DIR/.venv"
  sudo -u "$SERVICE_USER" env PATH="$cuda_bin:$PATH" "$EDGELLM_PY" -m pip install --upgrade pip
  sudo -u "$SERVICE_USER" env PATH="$cuda_bin:$PATH" "$EDGELLM_PY" -m pip install \
    'pybind11==3.0.4' 'nvidia-cutlass-dsl[cu13]==4.7.0' 'cupy-cuda13x==13.6.0' 'cuda-python>=12.6,<14'
  echo "$cuda_ver" > "$STATE_DIR/.cuda-version"
}

do_build_edgellm_runtime() {
  local cuda_ver; cuda_ver="$(cat "$STATE_DIR/.cuda-version")"
  local cuda_bin="/usr/local/cuda-$cuda_ver/bin"
  local envs=(
    "PATH=$EDGELLM_DIR/.venv/bin:$cuda_bin:$PATH"
    "TRT_PACKAGE_DIR=/usr"
    "CUDA_PATH=/usr/local/cuda-$cuda_ver"
    "LD_LIBRARY_PATH=/usr/lib/aarch64-linux-gnu:/usr/local/cuda-$cuda_ver/lib64"
    "TMPDIR=$INSTALL_DIR/data/tmp"
    "XDG_CACHE_HOME=$INSTALL_DIR/data/cache"
    "CUDA_CACHE_PATH=$INSTALL_DIR/data/cache/cuda"
  )
  mkdir -p "$INSTALL_DIR/data/tmp" "$INSTALL_DIR/data/cache/cuda"
  chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/data"
  # Needs both FMHA (every build) and the INT4 V2 GEMM kernels (INT4 decode path).
  sudo -u "$SERVICE_USER" env "${envs[@]}" "$EDGELLM_PY" "$EDGELLM_DIR/kernelSrcs/build_cutedsl.py" \
    --gpu_arch sm_87 --arch aarch64 --cuda-version "$cuda_ver" --kernels fmha,int4_fp16_gemm --jobs 1
  sudo -u "$SERVICE_USER" env "${envs[@]}" cmake -S "$EDGELLM_DIR" -B "$EDGELLM_DIR/build" \
    -DCMAKE_BUILD_TYPE=Release -DTRT_PACKAGE_DIR=/usr \
    -DCMAKE_TOOLCHAIN_FILE="$EDGELLM_DIR/cmake/aarch64_linux_toolchain.cmake" \
    -DEMBEDDED_TARGET=jetson-orin -DCUDA_CTK_VERSION="$cuda_ver" \
    "-DENABLE_CUTE_DSL=fmha;int4_fp16_gemm" -DBUILD_PYTHON_BINDINGS=ON \
    -DPython_EXECUTABLE="$EDGELLM_PY" \
    -Dpybind11_DIR="$(sudo -u "$SERVICE_USER" env "${envs[@]}" "$EDGELLM_PY" -m pybind11 --cmakedir)"
  # --parallel 1: this is an 8 GB board: a measured build peaks at ~1.9 GB RSS at parallel 1;
  # more workers OOMs a stock Orin Nano rather than finishing faster.
  sudo -u "$SERVICE_USER" env "${envs[@]}" cmake --build "$EDGELLM_DIR/build" --parallel 1 \
    --target _edgellm_runtime NvInfer_edgellm_plugin llm_build visual_build
  # export (not just server,server-tools) - tensorrt-edgellm-export imports torch directly to
  # trace/export the checkpoint; the resident-runtime server path doesn't need it (it loads a
  # prebuilt engine through the native pybind11 bindings instead), which is why this was missed
  # until the export_onnx stage actually ran and failed with ModuleNotFoundError: No module
  # named 'torch'.
  # The visual (--skip-llm) export path unconditionally imports quantization_configs, which
  # transitively imports modelopt, datasets, scikit-learn (via transformers' own generation
  # internals) and more - even though this pipeline does no ModelOpt-based calibration. Tried
  # installing just nvidia-modelopt first; the same eager-import chain immediately needed
  # datasets next, then more. Installing the whole `tools` extra (torchvision/datasets/librosa/
  # soundfile/etc included) avoids further one-at-a-time whack-a-mole - confirmed as the actual
  # requirement, not a guess, by running the real visual export end to end with it installed.
  sudo -u "$SERVICE_USER" env "${envs[@]}" "$EDGELLM_PY" -m pip install -e "$EDGELLM_DIR[server,server-tools,export,tools]"
  # JetPack's system SciPy/CFFI/pandas don't satisfy the server/tools extras' pins under
  # --system-site-packages (measured); shadow them inside the venv only. pandas specifically:
  # sklearn (pulled in by transformers' generation.candidate_generator) imports it, and the
  # system copy at /usr/lib/python3/dist-packages was built against a different numpy ABI than
  # this venv's numpy 2.2.6, crashing with "numpy.dtype size changed" the instant it's imported.
  sudo -u "$SERVICE_USER" env "${envs[@]}" "$EDGELLM_PY" -m pip install --only-binary=:all: \
    'numpy==2.2.6' 'scipy==1.15.3' 'cffi==2.0.0' 'pandas==2.3.3'
  # Not `|| true`'d away entirely - logged, but not fatal: on aarch64, nvidia-cusparselt-cu13
  # (pulled in transitively by torch's CUDA extras) reports "not supported on this platform" in
  # pip check even though torch itself imports fine and torch.cuda.is_available() is True. That
  # single cosmetic platform-tag mismatch was killing the whole script under set -e.
  sudo -u "$SERVICE_USER" env "${envs[@]}" "$EDGELLM_PY" -m pip check \
    || warn "pip check reported the above conflict(s) - continuing; verify nothing beyond the known nvidia-cusparselt-cu13 platform-tag quirk shows up here before trusting this blindly on a future run."
  sudo -u "$SERVICE_USER" env "${envs[@]}" "$EDGELLM_PY" -c \
    'from experimental.server.runtime.engine import _import_runtime; r=_import_runtime(); assert hasattr(r,"LLMRuntime"); print("native runtime import OK:", r.__file__)'
  # XDG_CACHE_HOME (set above) scoped pip's download cache to here for this venv only, and
  # nothing after this stage does another pip install - torch's CUDA wheels alone leave a
  # multi-GB cache that's pure duplication of what's already unpacked into .venv.
  rm -rf "${INSTALL_DIR:?}/data/cache"/*
}

do_download_checkpoint() {
  mkdir -p "$RAW_DIR"
  chown -R "$SERVICE_USER:$SERVICE_USER" "$CKPT_ROOT"
  # Two-pass: fetch the root index first to learn shard filenames, then fetch exactly those
  # shards plus tokenizer/vision assets. vae/ (the separate image/video generation decoder)
  # and other omni components are never downloaded - this demo only runs the reasoner.
  # runuser, not sudo -u, and the token in the (exported) environment, not argv: `env
  # HF_TOKEN=...` would show it to `ps`, and sudo writes any variable passed with
  # --preserve-env=NAME into its log (measured: ENV=HF_TOKEN=hf_... in the journal). runuser
  # logs only the session.
  runuser -u "$SERVICE_USER" -- "$EDGELLM_PY" - "$RAW_DIR" <<'PY'
import json, os, sys
from pathlib import Path
from huggingface_hub import hf_hub_download, snapshot_download

target = Path(sys.argv[1])
repo = "nvidia/Cosmos3-Edge"
revision = "344d602b128d1bbdacb43b08d0a3626f46343e29"
token = os.environ.get("HF_TOKEN") or None   # not needed - the model is public


def fetch():
    index_path = hf_hub_download(repo, "model.safetensors.index.json", revision=revision, token=token)
    shards = sorted(set(json.loads(Path(index_path).read_text())["weight_map"].values()))
    allow = [
        "config.json", "model.safetensors.index.json",
        "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json",
        "chat_template.jinja", "generation_config.json",
        # The model card: it carries the checkpoint's license reference (OpenMDW 1.1), and
        # vendor/quantize_cosmos3_rtn.py copies it into the quantized checkpoint as
        # SOURCE_MODEL_CARD.md - only if it was downloaded. Keep in sync with bootstrap.sh.
        "README.md",
        # Root-level, not under vision_encoder/ despite being vision-specific - confirmed via the
        # repo's own file tree. Their absence doesn't fail the export step (just a warning), but
        # fails the shim at runtime: QwenViTRunner::initialize() refuses to start without
        # preprocessor_config.json, crash-looping the whole service.
        "preprocessor_config.json", "processor_config.json",
        "vision_encoder/*",
        *shards,
    ]
    snapshot_download(repo, revision=revision, local_dir=str(target), token=token, allow_patterns=allow)


try:
    fetch()
except Exception as e:
    status = getattr(getattr(e, "response", None), "status_code", None)
    if status in (401, 403) or "Gated" in type(e).__name__:
        sys.exit(f"Hugging Face refused the download (HTTP {status}). {repo} needed no token when "
                 f"this was written, so it has probably been gated since: accept its terms at "
                 f"https://huggingface.co/{repo} and re-run with HF_TOKEN set to a read token.")
    raise
print(target)
PY
  [[ -f "$RAW_DIR/config.json" && -f "$RAW_DIR/model.safetensors.index.json" ]] \
    || die "download completed but config.json / model.safetensors.index.json is missing under $RAW_DIR."
}

do_fix_raw_config() {
  # The exporter needs four multimodal token IDs in config.json and does not derive them on its
  # own. The pinned revision's config.json already carries them (every install so far reported
  # "no change"); this adds any that are missing. The values are confirmed against this repo's
  # own actual deployed engine's config.json, not guessed - do not change them without
  # re-deriving from a real build.
  sudo -u "$SERVICE_USER" "$EDGELLM_PY" - "$RAW_DIR/config.json" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
cfg = json.loads(p.read_text())
needed = {"image_token_id": 19, "video_token_id": 18, "vision_start_token_id": 20, "vision_end_token_id": 21}
missing = {k: v for k, v in needed.items() if k not in cfg}
if missing:
    cfg.update(missing)
    p.write_text(json.dumps(cfg, indent=2))
    print(f"patched {p}: added {list(missing)}")
else:
    print(f"{p} already has all four token IDs, no change")
PY
  # vendor/quantize_cosmos3_rtn.py's source_catalog() AND its own pre-conversion
  # re-verification (right before --apply touches any weight data) both require a "verified
  # official model-download receipt" at <repo-root>/results/model-download.json - not just
  # for config.json/the index, but a sha256 for EVERY top-level metadata file it may copy
  # through (tokenizer/chat-template/preprocessor configs etc - see its own "copy everything
  # else through unchanged" loop) and BOTH a size_bytes AND a sha256 for every shard (two
  # separate checks at two separate points, not redundant). This is the script's own
  # integrity check, not something setup-orin.sh can skip or fake - discovered the hard way
  # by hitting each missing field as a separate failure in turn. Generated here, after the
  # token-ID patch above, not right after download: the receipt's config.json hash must match
  # what's on disk at quantize time, which is the PATCHED file, not the as-downloaded one.
  sudo -u "$SERVICE_USER" "$EDGELLM_PY" - "$RAW_DIR" "$INSTALL_DIR/results/model-download.json" <<'PY'
import hashlib, json, sys
from pathlib import Path
source, out = Path(sys.argv[1]), Path(sys.argv[2])

def sha256_of(p):
    digest = hashlib.sha256()
    with p.open("rb") as f:
        for block in iter(lambda: f.read(4 << 20), b""):
            digest.update(block)
    return digest.hexdigest()

index = json.loads((source / "model.safetensors.index.json").read_text())["weight_map"]
shards = sorted(set(index.values()))
files = {}
for p in sorted(source.glob("*")):
    if p.is_file() and p.suffix in {".json", ".jinja", ".md"}:
        files[p.name] = {"sha256": sha256_of(p)}
for shard in shards:
    p = source / shard
    files[shard] = {"size_bytes": p.stat().st_size, "sha256": sha256_of(p)}
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps({"revision": "344d602b128d1bbdacb43b08d0a3626f46343e29",
                            "complete": True, "files": files}, indent=2))
print(f"wrote {out}: {len(files)} files")
PY
}

do_quantize() {
  # The exporter's own on-the-fly --quantization flag (tried here in an earlier version of
  # this script) turned out to be silently a no-op for this checkpoint: it's gated on
  # _needs_moe_quantization in tensorrt_edgellm/scripts/export.py, and Cosmos3-Edge's
  # reasoner is a DENSE model (config.json: backbone_type "cosmos3_edge_nemotron_dense"),
  # not MoE - the flag only ever applies to Mixture-of-Experts checkpoints. It exported
  # plain FP16 with zero warning, which happened to run and serve correctly (FP16 isn't
  # wrong, just ~4x the memory and meaningfully slower than actual INT4). A real
  # pre-quantization pass is required for this model; see vendor/quantize_cosmos3_rtn.py.
  # Skipped (adopt_host_export marks it done) when scripts/bootstrap.sh's --host-quantize
  # already ran this same script on a capable host and staged its export for adoption - see
  # adopt_host_export and README.md "Host-accelerated quantization".
  mkdir -p "$(dirname "$QUANT_DIR")"
  # A redo (marker deleted) or a resume after a failed run finds the previous output still
  # there, and the quantizer refuses to write over an existing directory. It's this stage's
  # own output, so start clean.
  rm -rf "${QUANT_DIR:?}"
  sudo -u "$SERVICE_USER" "$EDGELLM_PY" "$INSTALL_DIR/vendor/quantize_cosmos3_rtn.py" \
    --source "$RAW_DIR" \
    --output "$QUANT_DIR" \
    --quantization-scope all-linears --apply
  [[ -f "$QUANT_DIR/model.safetensors.index.json" ]] || die "quantization finished but $QUANT_DIR/model.safetensors.index.json is missing."
}

adopt_host_export() {
  # scripts/bootstrap.sh --host-quantize leaves the V2 LLM export it made on the laptop staged at
  # $ONNX_DIR/llm.host, flagged .complete only once its copy finished. Take it over: swap it in,
  # mark this machine's own quantize/export stages done (it replaces them), and clear the stages
  # built on top of the previous export - re-patch its chat template, rebuild the engine from it,
  # restart the services onto it, re-run the smoke test. On a fresh Orin those simply haven't run
  # yet; on one already set up, this is what upgrades it. Not a stage: runs whenever one is waiting.
  local staged="$ONNX_DIR/llm.host"
  [[ -d "$staged" ]] || return 0
  if [[ ! -f "$staged/.complete" || ! -f "$staged/model.onnx" ]]; then
    warn "removing an incomplete host export at $staged - its copy never finished; nothing adopted"
    rm -rf "$staged"
    return 0
  fi
  log "adopting the LLM export --host-quantize made on the laptop (V2/cuteDSL plugin)"
  rm -f "$staged/.complete"
  rm -rf "${ONNX_DIR:?}/llm"
  mv "$staged" "$ONNX_DIR/llm"
  chown -R "$SERVICE_USER:$SERVICE_USER" "$ONNX_DIR/llm"
  stage_mark quantize
  stage_mark export_onnx_llm
  rm -f "$STATE_DIR"/{fix_chat_template,build_engine,enable_services,smoke_test}
}

do_export_onnx_llm() {
  pause_inference
  # Split from the visual export (see do_export_onnx_visual) so that when scripts/bootstrap.sh's
  # --host-quantize already did this step on a capable host, adopt_host_export can mark just
  # this stage done - the visual export still always runs on the Orin, since it isn't the stage
  # that hits the OOM below.
  sudo -u "$SERVICE_USER" mkdir -p "$ONNX_DIR"
  local llm_export="$EDGELLM_DIR/.venv/bin/tensorrt-edgellm-export"
  [[ -x "$llm_export" ]] || die "tensorrt-edgellm-export not found in the venv - the build_edgellm_runtime stage should have installed it via pip install -e '.[server,server-tools,export,tools]'."
  # V1 (legacy AWQ-swizzled) plugin, not the default V2: exporting with V2 (cuteDSL
  # fragment-layout) on THIS box gets OOM-killed by the kernel partway through the export
  # itself, on an 8 GB Orin Nano - even idle, with every demo service stopped: measured
  # 6.8 GB resident at the kill (dmesg "Out of memory: Killed process ... tensorrt-edgell"),
  # 40 MB of system memory left. Run to completion on a bigger host it peaks at 8.96 GB. Not
  # a build-time format-support error as an earlier version of this comment claimed. V1's
  # export has a lower peak memory footprint and fits; V2 needs more RAM than this board has.
  # scripts/bootstrap.sh's --host-quantize does the V2 export on a capable host instead,
  # which is the only way to get the primary V2/cuteDSL plugin with this pipeline - see
  # README.md "Host-accelerated quantization".
  # No --quantization flag here: $QUANT_DIR is already quantized (see do_quantize); the
  # exporter auto-detects INT4 GPTQ packing from config.json's own quantization_config
  # (quant_method: "gptq") - see vendor/quantize_cosmos3_rtn.py's header comment for exactly
  # why this specific field is what makes that detection succeed.
  sudo -u "$SERVICE_USER" "$llm_export" "$QUANT_DIR" "$ONNX_DIR" \
    --task reasoning --skip-visual --int4-gemm-plugin-version 1
}

do_export_onnx_visual() {
  pause_inference
  sudo -u "$SERVICE_USER" mkdir -p "$ONNX_DIR"
  local llm_export="$EDGELLM_DIR/.venv/bin/tensorrt-edgellm-export"
  [[ -x "$llm_export" ]] || die "tensorrt-edgellm-export not found in the venv - the build_edgellm_runtime stage should have installed it via pip install -e '.[server,server-tools,export,tools]'."
  sudo -u "$SERVICE_USER" "$llm_export" "$RAW_DIR" "$ONNX_DIR" \
    --task reasoning --skip-llm
}

do_fix_chat_template() {
  local tmpl="$ONNX_DIR/llm/processed_chat_template.json"
  [[ -f "$tmpl" ]] || { warn "$tmpl not found, skipping chat-template content_types check."; return 0; }
  "$EDGELLM_PY" - "$tmpl" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
data = json.loads(p.read_text())
if not data.get("content_types"):
    # Qwen3-VL-based text tower's actual delimiters, confirmed against this checkpoint's own
    # chat_template.jinja - the exporter's auto-extraction can silently produce an empty stub.
    data["content_types"] = {
        "image": {"format": "<|vision_start|><|image_pad|><|vision_end|>"},
        "video": {"format": "<|vision_start|><|video_pad|><|vision_end|>"},
    }
    p.write_text(json.dumps(data, indent=2))
    print(f"patched {p}: populated content_types (was empty)")
else:
    print(f"{p} already has content_types, no change")
PY
}

BUILD_SWAPFILE="$INSTALL_DIR/data/build-swap.img"
# The export and engine-build stages need the memory the inference shim holds (~3.5 GB of an
# 8 GB Orin Nano, none of it swappable - see the shim's no-swap drop-in), and llm_build
# rewrites the engine file the shim has mapped. On a fresh Orin the shim isn't running yet;
# on one already set up - --host-quantize's upgrade, a deleted marker - it is. Stop it for
# those stages; resume_inference starts it again before the smoke test if enable_services
# didn't.
SHIM_PAUSED=0
pause_inference() {
  systemctl is-active --quiet live-vision-cosmos-demo-shim 2>/dev/null || return 0
  log "stopping the inference shim while this stage runs - it holds memory the build needs"
  systemctl stop live-vision-cosmos-demo-shim
  SHIM_PAUSED=1
}
resume_inference() {
  if [[ "$SHIM_PAUSED" -eq 1 ]] && ! systemctl is-active --quiet live-vision-cosmos-demo-shim; then
    log "starting the inference shim again"
    systemctl start live-vision-cosmos-demo-shim
  fi
}

enable_build_swap() {
  # llm_build's serialization step measurably needs more than an 8 GB Orin Nano's physical
  # RAM alone provides (observed: OOM-killed with "Total Weights Memory" already logged at
  # ~3.3 GB, right as it starts writing the engine file) - confirmed by reproducing the exact
  # same failure on a genuine FP16 build with no quantization involved at all, and confirmed
  # fixed by exactly this: enabling swap only unblocks it, memory pressure isn't from a bug.
  # Swap is for the build only: disable_build_swap turns it off again afterwards, for serving
  # stability.
  [[ -f "$BUILD_SWAPFILE" ]] || {
    fallocate -l 4G "$BUILD_SWAPFILE" 2>/dev/null || dd if=/dev/zero of="$BUILD_SWAPFILE" bs=1M count=4096 status=none
    chmod 600 "$BUILD_SWAPFILE"
    mkswap "$BUILD_SWAPFILE" >/dev/null
  }
  swapon "$BUILD_SWAPFILE" 2>/dev/null || true
}
disable_build_swap() {
  swapoff "$BUILD_SWAPFILE" 2>/dev/null || true
  rm -f "$BUILD_SWAPFILE"
}

do_build_engine() {
  pause_inference
  enable_build_swap
  sudo -u "$SERVICE_USER" mkdir -p "$ENGINE_DIR"
  local llm_build="$EDGELLM_DIR/build/examples/llm/llm_build"
  local visual_build="$EDGELLM_DIR/build/examples/multimodal/visual_build"
  [[ -x "$llm_build" ]] || die "llm_build binary not found at $llm_build - the build_edgellm_runtime stage should have built it."
  [[ -x "$visual_build" ]] || die "visual_build binary not found at $visual_build."
  # These exact capacities match this repo's actual deployed engine's own config.json
  # (builder_config: max_batch_size=1, max_input_len=1024, max_kv_cache_capacity=1024,
  # max_kv_pool_pages=8) - do not "helpfully" raise them without re-measuring RAM headroom.
  # EDGELLM_PLUGIN_PATH: both binaries default to the RELATIVE path
  # "build/libNvInfer_edgellm_plugin.so" (resolved from whatever directory they're invoked
  # from) if this isn't set, which fails to find the plugin unless you happen to be running
  # from inside $EDGELLM_DIR itself. Without it, TensorRT can't resolve the custom
  # AttentionPlugin ops the ONNX export emits and parsing the ONNX file fails outright.
  sudo -u "$SERVICE_USER" env EDGELLM_PLUGIN_PATH="$EDGELLM_DIR/build/libNvInfer_edgellm_plugin.so" "$llm_build" \
    --onnxDir "$ONNX_DIR/llm" --engineDir "$ENGINE_DIR" \
    --maxInputLen 1024 --maxKVCacheCapacity 1024 --maxKVPoolPages 8 --maxBatchSize 1
  sudo -u "$SERVICE_USER" env EDGELLM_PLUGIN_PATH="$EDGELLM_DIR/build/libNvInfer_edgellm_plugin.so" "$visual_build" \
    --onnxDir "$ONNX_DIR/visual" --engineDir "$ENGINE_DIR" \
    --minImageTokens 4 --maxImageTokens 1024 --maxImageTokensPerImage 512
  [[ -f "$ENGINE_DIR/llm.engine" ]] || die "llm_build ran but $ENGINE_DIR/llm.engine is missing."
  disable_build_swap
}

do_link_engine() {
  ln -sfn "$ENGINE_DIR" "$INSTALL_DIR/engine-link"
  chown -h "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/engine-link"
  [[ -f "$INSTALL_DIR/engines.json" ]] || sudo -u "$SERVICE_USER" cp "$INSTALL_DIR/ui/config/engines.example.json" "$INSTALL_DIR/engines.json"
  [[ -f "$INSTALL_DIR/services.json" ]] || echo '{}' | sudo -u "$SERVICE_USER" tee "$INSTALL_DIR/services.json" >/dev/null
}

do_setup_piper() {
  local dir="$INSTALL_DIR/piper"
  if [[ ! -x "$dir/piper" ]]; then
    mkdir -p "$dir"
    local tmp; tmp="$(mktemp -d)"
    # The release asset is named piper_arm64.tar.gz, not piper_linux_aarch64.tar.gz (confirmed
    # against the actual v1.2.0 release's asset list - the latter 404s outright).
    curl -fsSL -o "$tmp/piper.tar.gz" \
      "https://github.com/rhasspy/piper/releases/download/v${PIPER_VERSION}/piper_arm64.tar.gz"
    tar -xzf "$tmp/piper.tar.gz" -C "$tmp"
    cp -a "$tmp"/piper/. "$dir"/
    rm -rf "$tmp"
  fi
  # medium quality, not high: high-tier voices roughly double synthesis time on an Orin for
  # a marginal quality gain speech-through-a-small-speaker doesn't showcase. See NOTICE.md
  # before substituting a different voice - some inherit a non-commercial base-voice license.
  local voice_path; voice_path="$(python3 - "$PIPER_VOICE" <<'PY'
import sys
name = sys.argv[1]
parts = name.split("-")  # en_US-ljspeech-medium -> en/en_US/ljspeech/medium
lang, voice, quality = parts[0], parts[1], parts[2]
print(f"{lang.split('_')[0]}/{lang}/{voice}/{quality}")
PY
)"
  for ext in onnx onnx.json; do
    [[ -f "$dir/$PIPER_VOICE.$ext" ]] || curl -fsSL -o "$dir/$PIPER_VOICE.$ext" \
      "https://huggingface.co/rhasspy/piper-voices/resolve/main/$voice_path/$PIPER_VOICE.$ext"
  done
  chown -R "$SERVICE_USER:$SERVICE_USER" "$dir"
}

do_setup_reachy_env() {
  if [[ -z "$REACHY_MINI_IP" ]]; then
    log "REACHY_MINI_IP not set - skipping Reachy Mini bridge venv. Motor/app/TTS control needs no venv (talks to the robot's REST API directly); only 'switch to Reachy Mini' as a video source needs this."
    return 0
  fi
  [[ -d "$INSTALL_DIR/reachy_env" ]] || sudo -u "$SERVICE_USER" python3 -m venv "$INSTALL_DIR/reachy_env"
  sudo -u "$SERVICE_USER" "$INSTALL_DIR/reachy_env/bin/pip" install -r "$INSTALL_DIR/reachy/requirements.txt"
}

do_setup_tls() {
  sudo -u "$SERVICE_USER" mkdir -p "$INSTALL_DIR/tls"
  [[ -f "$INSTALL_DIR/tls/cert.pem" ]] || sudo -u "$SERVICE_USER" openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
    -keyout "$INSTALL_DIR/tls/key.pem" -out "$INSTALL_DIR/tls/cert.pem" -subj "/CN=live-vision-cosmos-demo"
}

do_install_systemd_units() {
  # The UI unit names the default voice's model file; point it at the voice actually installed
  # (PIPER_VOICE, validated in do_preflight), or speech breaks for any other voice.
  for unit in live-vision-cosmos-demo-shim.service live-vision-cosmos-demo-ui.service; do
    sed -e "s/YOUR_USERNAME/$SERVICE_USER/g" -e "s/en_US-ljspeech-medium\.onnx/$PIPER_VOICE.onnx/g" \
      "$INSTALL_DIR/systemd/$unit" > "/etc/systemd/system/$unit"
  done
  # The robot's address lives in reachy.env, which the UI and bridge units both read at start
  # (EnvironmentFile), not in the units themselves - so scripts/set-reachy-ip.sh can point
  # this Orin at a different robot later by rewriting one line and restarting two services.
  # No robot on this LAN is a supported mode too: then drop the UI's robot flags instead.
  if [[ -n "$REACHY_MINI_IP" ]]; then
    reachy_address_write "$REACHY_MINI_IP"
  else
    sed -i '/--reachy-daemon-url/d' "/etc/systemd/system/live-vision-cosmos-demo-ui.service"
    # serve_ui.py itself refuses to start with --piper-bin but no --reachy-daemon-url
    # ("speech plays through the robot") - drop both together or the UI service crash-loops
    # on every boot. Piper is still installed either way; it's just unreachable without a
    # robot to play audio through, so there's nothing useful --piper-bin would do here.
    sed -i '/--piper-bin/d' "/etc/systemd/system/live-vision-cosmos-demo-ui.service"
  fi
  cp "$INSTALL_DIR/systemd/dropins/99-live-vision-cosmos-demo-swap.conf" /etc/sysctl.d/
  install -d "/etc/systemd/system/live-vision-cosmos-demo-shim.service.d"
  cp "$INSTALL_DIR/systemd/dropins/live-vision-cosmos-demo-shim.service.d-10-no-swap.conf" \
    "/etc/systemd/system/live-vision-cosmos-demo-shim.service.d/10-no-swap.conf"
  if [[ -n "$REACHY_MINI_IP" ]]; then
    sed -e "s/YOUR_USERNAME/$SERVICE_USER/g" \
      "$INSTALL_DIR/systemd/reachy-mjpeg-bridge.service" > /etc/systemd/system/reachy-mjpeg-bridge.service
  fi
  sysctl --system >/dev/null
  systemctl daemon-reload
}

do_setup_sudoers() {
  local rule="$SERVICE_USER ALL=(root) NOPASSWD: /usr/bin/systemctl start live-vision-cosmos-demo-shim.service, /usr/bin/systemctl stop live-vision-cosmos-demo-shim.service"
  echo "$rule" > /etc/sudoers.d/live-vision-cosmos-demo
  chmod 0440 /etc/sudoers.d/live-vision-cosmos-demo
  visudo -cf /etc/sudoers.d/live-vision-cosmos-demo || die "generated sudoers rule failed validation"
}

do_enable_services() {
  # `enable --now` only starts a unit that isn't already running - on a resume where the
  # unit file changed (e.g. REACHY_MINI_IP added after an earlier no-Reachy run) an
  # already-active service keeps running with its OLD command line until something
  # explicitly restarts it. `enable` (config only) + `restart` (always re-execs) together
  # guarantee the running process matches whatever install_systemd_units just wrote,
  # whether this is a fresh start or a resume.
  systemctl enable live-vision-cosmos-demo-shim live-vision-cosmos-demo-ui
  systemctl restart live-vision-cosmos-demo-shim live-vision-cosmos-demo-ui
  if [[ -n "$REACHY_MINI_IP" ]]; then
    systemctl enable reachy-mjpeg-bridge
    systemctl restart reachy-mjpeg-bridge
  fi
}

do_smoke_test() {
  log "waiting for the shim to load the engine (can take 60-90s on first start)..."
  local ok=0
  for _ in $(seq 1 36); do
    if curl -fsS "http://127.0.0.1:8001/health/ready" >/dev/null 2>&1; then ok=1; break; fi
    sleep 5
  done
  [[ "$ok" -eq 1 ]] || die "shim did not become ready within 3 minutes - check: journalctl -u live-vision-cosmos-demo-shim -n 100 --no-pager"
  curl -fsS "http://127.0.0.1:8091/health/ready" >/dev/null 2>&1 || warn "UI health check did not respond on 127.0.0.1:8091 - check: journalctl -u live-vision-cosmos-demo-ui -n 100 --no-pager"
  local ip; ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  log "done. Open https://${ip:-<orin-ip>}:8443/ (accept the self-signed certificate warning once)."
}

# ---------------------------------------------------------------------------------------
main() {
  do_preflight
  adopt_host_export
  stage system_packages         do_system_packages
  stage pin_clocks               do_pin_clocks
  stage fetch_repo_self         do_fetch_repo_self
  stage jetpack_compute         do_jetpack_compute
  stage fetch_edgellm           do_fetch_edgellm
  stage edgellm_venv            do_edgellm_venv
  stage build_edgellm_runtime   do_build_edgellm_runtime
  stage download_checkpoint     do_download_checkpoint
  stage fix_raw_config          do_fix_raw_config
  stage quantize                do_quantize
  stage export_onnx_llm         do_export_onnx_llm
  stage export_onnx_visual      do_export_onnx_visual
  stage fix_chat_template       do_fix_chat_template
  stage build_engine            do_build_engine
  stage link_engine             do_link_engine
  stage setup_piper             do_setup_piper
  stage setup_reachy_env        do_setup_reachy_env
  stage setup_tls               do_setup_tls
  stage install_systemd_units   do_install_systemd_units
  stage setup_sudoers           do_setup_sudoers
  stage enable_services         do_enable_services
  resume_inference
  stage smoke_test              do_smoke_test
}
main "$@"
