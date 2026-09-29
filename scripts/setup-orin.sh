#!/usr/bin/env bash
# One-shot Orin-side build + install for Live Vision + Reachy Mini + Cosmos3-Edge.
#
# Everything that needs a GPU, a large download, or a compiler runs here, on the Orin.
# scripts/bootstrap.sh (run from a laptop) copies this repo to the Orin and invokes this
# script over SSH; it does not need a GPU or any particular OS itself.
#
# Idempotent: each stage records a marker file under $INSTALL_DIR/.setup-state/ and is
# skipped on re-run once its marker exists. Delete a marker (or the whole directory) to
# force that stage to redo its work. Safe to re-run after a failure - fix the reported
# problem and run it again; completed stages are not repeated.
#
# Required: HF_TOKEN (a Hugging Face access token that has accepted nvidia/Cosmos3-Edge's
# gated-model terms at https://huggingface.co/nvidia/Cosmos3-Edge). This is the one step
# that cannot be automated away - someone has to click "Agree" on NVIDIA's license once.
#
# Optional: REACHY_MINI_IP (skip Reachy Mini bridge/motor setup entirely if unset).
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
QUANT_SCOPE="${QUANT_SCOPE:-all-linears}"   # matches this repo's actual deployed checkpoint
PIPER_VERSION="1.2.0"
PIPER_VOICE="${PIPER_VOICE:-en_US-ljspeech-medium}"   # see NOTICE.md before changing voices
SERVICE_USER="${SERVICE_USER:-$(id -un)}"
REACHY_MINI_IP="${REACHY_MINI_IP:-}"
HF_TOKEN="${HF_TOKEN:-}"

STATE_DIR="$INSTALL_DIR/.setup-state"
EDGELLM_DIR="$INSTALL_DIR/external/TensorRT-Edge-LLM"
EDGELLM_PY="$EDGELLM_DIR/.venv/bin/python"
CKPT_ROOT="$INSTALL_DIR/checkpoints/Cosmos3-Edge"
RAW_DIR="$CKPT_ROOT/raw"
QUANT_DIR="$CKPT_ROOT/quantized"
ONNX_DIR="$CKPT_ROOT/onnx/reasoning"
ENGINE_DIR="$INSTALL_DIR/engines/reasoning"

log() { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mFATAL\033[0m %s\n' "$*" >&2; exit 1; }

stage_done() { [[ -e "$STATE_DIR/$1" ]]; }
stage_mark() { mkdir -p "$STATE_DIR"; touch "$STATE_DIR/$1"; }
stage() {
  local name="$1"; shift
  if stage_done "$name"; then
    log "skip: $name (already done - rm $STATE_DIR/$name to redo)"
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
  [[ -n "$HF_TOKEN" ]] || die "HF_TOKEN is not set. Accept the license at https://huggingface.co/nvidia/Cosmos3-Edge, create a read token at https://huggingface.co/settings/tokens, and re-run with HF_TOKEN=hf_... set."
  command -v python3 >/dev/null || die "python3 not found - is JetPack actually flashed and booted?"
  command -v nvcc >/dev/null || [[ -x /usr/local/cuda*/bin/nvcc ]] || warn "nvcc not found on PATH yet - fine if it's under /usr/local/cuda-*/bin, the build stage adds that explicitly."
  local avail_kb; avail_kb=$(df -Pk "$(dirname "$INSTALL_DIR")" | awk 'NR==2{print $4}')
  local avail_gb=$((avail_kb / 1024 / 1024))
  [[ "$avail_gb" -ge 25 ]] || die "only ${avail_gb} GiB free under $(dirname "$INSTALL_DIR") - this build needs roughly 25-30 GiB (checkpoint + TensorRT-Edge-LLM build tree + exported engines). Free up space or point INSTALL_DIR's parent at a larger disk/SD card."
  [[ "$avail_gb" -ge 40 ]] || warn "${avail_gb} GiB free is tight. The build will likely fit, but there's little margin - consider a 64 GB+ card if this is a fresh flash."
  mkdir -p "$INSTALL_DIR"
  id -u "$SERVICE_USER" >/dev/null 2>&1 || die "SERVICE_USER=$SERVICE_USER does not exist. Set SERVICE_USER to the account that should own and run these services (not root)."
  chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
}

do_system_packages() {
  apt-get update -o Acquire::Retries=3
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential binutils cmake git ca-certificates \
    python3-venv python3-dev python3-pip \
    curl jq sox openssl
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
  mkdir -p "$(dirname "$EDGELLM_DIR")"
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
  [[ -n "$cuda_bin" ]] || die "no /usr/local/cuda-*/bin found - JetPack's CUDA toolkit isn't installed. Install the JetPack compute components (nvidia-l4t stack) before running this script."
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
  # --parallel 1: this is an 8 GB board: cosmos-edge's own build receipts show ~1.9 GB peak
  # RSS at parallel 1; more workers OOMs a stock Orin Nano rather than finishing faster.
  sudo -u "$SERVICE_USER" env "${envs[@]}" cmake --build "$EDGELLM_DIR/build" --parallel 1 \
    --target _edgellm_runtime NvInfer_edgellm_plugin llm_build visual_build
  sudo -u "$SERVICE_USER" env "${envs[@]}" "$EDGELLM_PY" -m pip install -e "$EDGELLM_DIR[server,server-tools]"
  # JetPack's system SciPy/CFFI don't satisfy the server extras' pins under --system-site-packages;
  # shadow them inside the venv only (documented, measured incompatibility - see cosmos-edge's own
  # research/python-system-site-compatibility.md for the exact wheel hashes this was checked against).
  sudo -u "$SERVICE_USER" env "${envs[@]}" "$EDGELLM_PY" -m pip install --only-binary=:all: \
    'numpy==2.2.6' 'scipy==1.15.3' 'cffi==2.0.0'
  sudo -u "$SERVICE_USER" env "${envs[@]}" "$EDGELLM_PY" -m pip check
  sudo -u "$SERVICE_USER" env "${envs[@]}" "$EDGELLM_PY" -c \
    'from experimental.server.runtime.engine import _import_runtime; r=_import_runtime(); assert hasattr(r,"LLMRuntime"); print("native runtime import OK:", r.__file__)'
}

do_download_checkpoint() {
  mkdir -p "$RAW_DIR"
  chown -R "$SERVICE_USER:$SERVICE_USER" "$CKPT_ROOT"
  # Two-pass: fetch the root index first to learn shard filenames, then fetch exactly those
  # shards plus tokenizer/vision assets. vae/ (the separate image/video generation decoder)
  # and other omni components are never downloaded - this demo only runs the reasoner.
  sudo -u "$SERVICE_USER" env HF_TOKEN="$HF_TOKEN" "$EDGELLM_PY" - "$RAW_DIR" <<'PY'
import json, os, sys
from pathlib import Path
from huggingface_hub import hf_hub_download, snapshot_download

target = Path(sys.argv[1])
repo = "nvidia/Cosmos3-Edge"
revision = "344d602b128d1bbdacb43b08d0a3626f46343e29"
token = os.environ["HF_TOKEN"]

index_path = hf_hub_download(repo, "model.safetensors.index.json", revision=revision, token=token)
shards = sorted(set(json.loads(Path(index_path).read_text())["weight_map"].values()))
allow = [
    "config.json", "model.safetensors.index.json",
    "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json",
    "chat_template.jinja", "generation_config.json",
    "vision_encoder/*",
    *shards,
]
snapshot_download(repo, revision=revision, local_dir=str(target), token=token, allow_patterns=allow)
print(target)
PY
  [[ -f "$RAW_DIR/config.json" && -f "$RAW_DIR/model.safetensors.index.json" ]] \
    || die "download completed but config.json / model.safetensors.index.json is missing under $RAW_DIR - check HF_TOKEN has accepted nvidia/Cosmos3-Edge's license and has read access."
}

do_generate_manifest() {
  # vendor/quantize_cosmos3_rtn.py refuses to run without this exact provenance receipt -
  # it re-verifies every source file's hash against it before and during conversion, as a
  # guard against a corrupted or tampered checkpoint. Generated fresh from the just-downloaded
  # files; snapshot_download already verified them against Hugging Face's own recorded hashes.
  mkdir -p "$INSTALL_DIR/results"
  "$EDGELLM_PY" - "$RAW_DIR" "$INSTALL_DIR/results/model-download.json" "$COSMOS_MODEL_REVISION" <<'PY'
import hashlib, json, sys
from pathlib import Path

raw, out, revision = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]

def sha256_of(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(4 << 20), b""):
            h.update(block)
    return h.hexdigest()

files = {}
def record(relpath):
    p = raw / relpath
    files[relpath] = {"sha256": sha256_of(p), "size_bytes": p.stat().st_size}

record("config.json")
record("model.safetensors.index.json")
index = json.loads((raw / "model.safetensors.index.json").read_text())
for shard in sorted(set(index["weight_map"].values())):
    record(shard)
for p in sorted(raw.iterdir()):
    if p.is_file() and p.suffix in (".json", ".jinja", ".md") and p.name != "model.safetensors.index.json":
        files.setdefault(p.name, {"sha256": sha256_of(p), "size_bytes": p.stat().st_size})

out.write_text(json.dumps({"revision": revision, "complete": True, "files": files}, indent=2))
print(f"wrote {out} ({len(files)} files)")
PY
  chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/results/model-download.json"
}

do_quantize() {
  # The vendored quantizer refuses to run if --output already exists (it builds in a temp
  # dir and renames on success) - do not mkdir QUANT_DIR ahead of it.
  mkdir -p "$(dirname "$QUANT_DIR")"
  sudo -u "$SERVICE_USER" "$EDGELLM_PY" "$INSTALL_DIR/vendor/quantize_cosmos3_rtn.py" \
    --source "$RAW_DIR" \
    --output "$QUANT_DIR" \
    --quantization-scope "$QUANT_SCOPE" --apply
  [[ -f "$QUANT_DIR/model.safetensors.index.json" ]] || die "quantization finished but $QUANT_DIR/model.safetensors.index.json is missing."
  # The quantizer copies config.json, the tokenizer, and the chat template into its own
  # output itself - nothing else to stage here.
}

do_fix_quant_config() {
  # The upstream checkpoint's config.json (copied through unchanged by the quantizer) is
  # missing four multimodal token IDs the exporter needs and does not derive on its own.
  # These exact values are confirmed against this repo's own actual deployed engine's
  # config.json, not guessed - do not change them without re-deriving from a real build.
  "$EDGELLM_PY" - "$QUANT_DIR/config.json" <<'PY'
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
}

do_export_onnx() {
  mkdir -p "$ONNX_DIR"
  local llm_export="$EDGELLM_DIR/.venv/bin/tensorrt-edgellm-export"
  [[ -x "$llm_export" ]] || die "tensorrt-edgellm-export not found in the venv - the build_edgellm_runtime stage should have installed it via pip install -e '.[server,server-tools]'."
  # V1 (legacy AWQ-swizzled) plugin, not the default V2: V2's cuteDSL fragment-layout ONNX
  # fails IBuilder::buildSerializedNetwork with "Error Code 9: could not find any supported
  # formats" on this checkpoint. V1 exports and builds cleanly - do not change this default.
  sudo -u "$SERVICE_USER" "$llm_export" "$QUANT_DIR" "$ONNX_DIR" \
    --task reasoning --skip-visual --int4-gemm-plugin-version 1 --quantization int4_awq
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

do_build_engine() {
  mkdir -p "$ENGINE_DIR"
  local llm_build="$EDGELLM_DIR/build/examples/llm/llm_build"
  local visual_build="$EDGELLM_DIR/build/examples/multimodal/visual_build"
  [[ -x "$llm_build" ]] || die "llm_build binary not found at $llm_build - the build_edgellm_runtime stage should have built it."
  [[ -x "$visual_build" ]] || die "visual_build binary not found at $visual_build."
  # These exact capacities match this repo's actual deployed engine's own config.json
  # (builder_config: max_batch_size=1, max_input_len=1024, max_kv_cache_capacity=1024,
  # max_kv_pool_pages=8) - do not "helpfully" raise them without re-measuring RAM headroom.
  sudo -u "$SERVICE_USER" "$llm_build" \
    --onnxDir "$ONNX_DIR/llm" --engineDir "$ENGINE_DIR" \
    --maxInputLen 1024 --maxKVCacheCapacity 1024 --maxKVPoolPages 8 --maxBatchSize 1
  sudo -u "$SERVICE_USER" "$visual_build" \
    --onnxDir "$ONNX_DIR/visual" --engineDir "$ENGINE_DIR" \
    --minImageTokens 4 --maxImageTokens 1024 --maxImageTokensPerImage 512
  [[ -f "$ENGINE_DIR/llm.engine" ]] || die "llm_build ran but $ENGINE_DIR/llm.engine is missing."
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
    curl -fsSL -o "$tmp/piper.tar.gz" \
      "https://github.com/rhasspy/piper/releases/download/v${PIPER_VERSION}/piper_linux_aarch64.tar.gz"
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
  mkdir -p "$INSTALL_DIR/tls"
  [[ -f "$INSTALL_DIR/tls/cert.pem" ]] || sudo -u "$SERVICE_USER" openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
    -keyout "$INSTALL_DIR/tls/key.pem" -out "$INSTALL_DIR/tls/cert.pem" -subj "/CN=live-vision-cosmos-demo"
}

do_install_systemd_units() {
  local reachy_flag=""
  [[ -n "$REACHY_MINI_IP" ]] && reachy_flag="--reachy-daemon-url http://$REACHY_MINI_IP:8000"
  for unit in live-vision-cosmos-demo-shim.service live-vision-cosmos-demo-ui.service; do
    sed -e "s/YOUR_USERNAME/$SERVICE_USER/g" "$INSTALL_DIR/systemd/$unit" > "/etc/systemd/system/$unit"
  done
  # The UI unit's --reachy-daemon-url flag needs either a real IP or removal; substitute
  # if set, drop the line entirely if not (no robot on this LAN is a supported mode).
  if [[ -n "$REACHY_MINI_IP" ]]; then
    sed -i "s/REACHY-MINI-IP/$REACHY_MINI_IP/g" "/etc/systemd/system/live-vision-cosmos-demo-ui.service"
  else
    sed -i '/--reachy-daemon-url/d' "/etc/systemd/system/live-vision-cosmos-demo-ui.service"
  fi
  cp "$INSTALL_DIR/systemd/dropins/99-live-vision-cosmos-demo-swap.conf" /etc/sysctl.d/
  install -d "/etc/systemd/system/live-vision-cosmos-demo-shim.service.d"
  cp "$INSTALL_DIR/systemd/dropins/live-vision-cosmos-demo-shim.service.d-10-no-swap.conf" \
    "/etc/systemd/system/live-vision-cosmos-demo-shim.service.d/10-no-swap.conf"
  if [[ -n "$REACHY_MINI_IP" ]]; then
    sed -e "s/YOUR_USERNAME/$SERVICE_USER/g" -e "s/REACHY-MINI-IP/$REACHY_MINI_IP/g" \
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
  systemctl enable --now live-vision-cosmos-demo-shim live-vision-cosmos-demo-ui
  [[ -n "$REACHY_MINI_IP" ]] && systemctl enable --now reachy-mjpeg-bridge
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
  stage preflight               do_preflight
  stage system_packages         do_system_packages
  stage fetch_repo_self         do_fetch_repo_self
  stage fetch_edgellm           do_fetch_edgellm
  stage edgellm_venv            do_edgellm_venv
  stage build_edgellm_runtime   do_build_edgellm_runtime
  stage download_checkpoint     do_download_checkpoint
  stage generate_manifest       do_generate_manifest
  stage quantize                do_quantize
  stage fix_quant_config        do_fix_quant_config
  stage export_onnx             do_export_onnx
  stage fix_chat_template       do_fix_chat_template
  stage build_engine            do_build_engine
  stage link_engine             do_link_engine
  stage setup_piper             do_setup_piper
  stage setup_reachy_env        do_setup_reachy_env
  stage setup_tls               do_setup_tls
  stage install_systemd_units   do_install_systemd_units
  stage setup_sudoers           do_setup_sudoers
  stage enable_services         do_enable_services
  stage smoke_test              do_smoke_test
}
main "$@"
