# Live Vision + Reachy Mini + Cosmos3-Edge

A minimal, low-RAM camera/VLM web UI that runs a locally-hosted **NVIDIA Cosmos3-Edge** model on a
Jetson Orin over TensorRT-Edge-LLM, with live **Reachy Mini** robot control (motors, onboard apps,
pose, text-to-speech) alongside it. No cloud calls, no framework - the server is a single
stdlib-only Python file.

```
USB webcam ──┐
             ├─▶ browser (getUserMedia) ──▶ Live Vision :8091 (http, redirects) / :8443 (https) ──▶ Cosmos3-Edge shim
Reachy Mini ─┘        │                           │
  camera/mic           │                    /api/reachy/* ──▶ Reachy Mini daemon :8000 (on the robot)
  (needs the bridge,    │                           │
   see below)           ▼                           ▼
                   /api/engines/*              motors, apps, speaker (Piper TTS)
                   (TensorRT engine swap)
```

Browser camera access requires a secure context, so :8091 (http) auto-redirects to :8443 (https,
self-signed - accept the browser warning once). Open `https://<orin-ip>:8443/` directly to skip
the redirect hop.

## What's here

| Path | What it is |
|---|---|
| `ui/` | Live Vision: `scripts/serve_ui.py` (stdlib-only `http.server`, no framework) + `web/`. Camera/VLM UI, Reachy motor/app/TTS control, engine switching with a live progress bar. |
| `reachy/reachy.py` | Thin REST client for the Reachy Mini daemon (motors, pose, apps, volume, sound upload/play). Only third-party dependency: `requests`. |
| `reachy/reachy_mjpeg_bridge.py` | WebRTC-to-HTTP bridge for the robot's camera/mic (needed only for "switch to Reachy Mini" as a *video* source - motor/app/TTS control works without it). |
| `shim/cosmos3_shim_v1.py` | The Cosmos3-Edge TensorRT-Edge-LLM serving shim - an OpenAI-compatible `/v1/chat/completions` endpoint in front of the built engine. |
| `systemd/` | Unit templates for the three services (UI, shim, Reachy bridge) and two drop-ins for running a multi-GB resident model on an 8 GB board without swap thrashing. |
| `ui/tests/`, run via `python3 -m unittest discover -s ui/tests` and `node --test ui/tests/test_engine_switch.js` | 50 tests, no device or GPU required - a fake HTTP backend and a fake DOM stand in for both. |
| `scripts/bootstrap.sh` | Run **from a laptop** (any OS, GPU optional - it does no compute itself). Copies this repo to the Orin over SSH and runs `setup-orin.sh` there. |
| `scripts/setup-orin.sh` | Run **on the Orin** (`bootstrap.sh` does this for you). Idempotent, one-shot: builds TensorRT-Edge-LLM, downloads and quantizes the Cosmos3-Edge checkpoint, builds the engine, installs Piper/TLS/systemd, starts the services. |
| `scripts/flash-jetpack-sd-mac.sh` | Optional Mac one-shot: clean JetPack SD → USB first boot → verified SSH; helpers in `scripts/jetpack/`, agent skill in `.agents/skills/flash-jetpack-sd-mac/`. |
| `vendor/quantize_cosmos3_rtn.py` | The CPU-only INT4 RTN quantizer `setup-orin.sh` calls. Not part of NVIDIA's public TensorRT-Edge-LLM SDK - see NOTICE.md for provenance. |
| `AGENTS.md` | Setup/deployment recipe written for an AI coding agent to follow unattended, plus the "don't change these without re-deriving them" list for the pinned build constants below. `CLAUDE.md` points here. |

## Quickstart: automated setup

**Already running JetPack 7.2.1 / Jetson Linux 39.2.1? Keep it.** A fresh JetPack
installation is not needed; setup installs any missing pinned CUDA/TensorRT components.

**Need a fresh SD card first?** On an Apple Silicon MacBook with macOS 15+, 16 GB RAM,
60 GiB free disk, Apple Command Line Tools, Homebrew, internet, an SD reader, a USB-C data cable, and
administrator/disk-access permission, run in Terminal:

```bash
brew install python qemu zstd
diskutil list                       # identify the 64 GB+ SD card
./scripts/flash-jetpack-sd-mac.sh --disk /dev/diskN --erase
```

This optional route targets the **Orin Nano Super 8 GB developer kit (P3767-0005)**
with compatible R39.2.1 QSPI firmware already installed. It prepares OS and NVIDIA drivers
only. The same command writes/verifies/ejects the card, waits while you move it to the
Orin, opens USB first-boot setup, then checks SD boot, filesystem expansion, and SSH.
Use the Orin's power supply and wired Ethernet to your router; select **Ethernet PCI**
in first-boot network setup. Complete NVIDIA's license/account
prompts locally; there are no default credentials. Already flashed? Resume with
`./scripts/flash-jetpack-sd-mac.sh --first-boot-only`. [Workflow and USB limitations](docs/jetpack-sd-mac.md).
Validated on a **fresh 64 GB SD card** using this script and
[agent skill](.agents/skills/flash-jetpack-sd-mac/SKILL.md): writing and full image
readback passed on 2026-09-29. The USB first-boot prompt was observed; SD root,
expansion, and SSH verification are still pending.
See the [Mac workflow and validation record](docs/jetpack-sd-mac.md) for scope.

Starting point: a Jetson Orin with **JetPack already flashed and booting**, reachable over
SSH, and nothing else installed - plus any laptop (any OS, a GPU not required; the laptop
does no compute, it just drives the Orin over SSH). End point: a working
`https://<orin-ip>:8443/` serving live camera captions from a locally-built TensorRT engine.

```bash
export HF_TOKEN=hf_...                  # see "Hugging Face access" just below
export REACHY_MINI_IP=192.168.1.50      # optional - omit if you have no Reachy Mini
./scripts/bootstrap.sh jetson-user@orin-ip
```

That's the whole setup. It clones and builds TensorRT-Edge-LLM, downloads and quantizes the
Cosmos3-Edge checkpoint, exports and builds the engine, installs Piper/TLS/systemd, and
starts everything - entirely on the Orin, over SSH from whatever laptop you ran it from. It
takes well over an hour on an Orin Nano, dominated by the on-device TensorRT-Edge-LLM native
build; it's idempotent, so if it fails partway (a flaky download, a transient apt mirror),
fix the reported problem and re-run it - completed stages are not repeated.

**Hugging Face access:** `nvidia/Cosmos3-Edge` is a gated model. Visit
https://huggingface.co/nvidia/Cosmos3-Edge, accept the license, then create a **read** token
at https://huggingface.co/settings/tokens. This is the one step that can't be automated away
- everything downstream of it is unattended.

If you're an AI coding agent doing this setup for someone, read `AGENTS.md` first - it
covers what to do when `HF_TOKEN` isn't available yet, and which build parameters are
pinned to a measured working configuration rather than being arbitrary defaults.

The rest of this README (below) is the manual, step-by-step reference the automation is
built from - useful for understanding what a stage actually does, debugging a failure, or
adapting the pipeline to a different checkpoint revision.

## Requirements

- **Jetson Orin (Nano or better) booting JetPack 7.2.1 / L4T 39.2.1.** Keep an existing
  compatible installation, or use the optional [Mac SD workflow](docs/jetpack-sd-mac.md)
  for the supported Orin Nano Super developer kit before application setup.
- **A 64 GB SD card or larger is recommended.** The application layer itself (this repo, the built
  engine, Piper, and the TensorRT-Edge-LLM Python environment the shim runs in) is roughly 5 GB;
  the complete build also needs CUDA/TensorRT development packages and intermediate model
  files. Use at least 64 GB for this workflow; the setup script checks available build space.
- **NVIDIA's [TensorRT-Edge-LLM](https://github.com/NVIDIA/TensorRT-Edge-LLM) SDK**, built on
  device, to both build the Cosmos3-Edge engine and provide the Python venv the shim runs from.
  Not vendored in this repo - it's a substantial NVIDIA SDK with its own license and update cycle.
- Reachy Mini robot on the same LAN, if you want the robot-control features. Everything else
  (webcam + Cosmos3-Edge captioning) works without one.

## Setup

The [Quickstart](#quickstart-automated-setup) above automates everything in this section via
`scripts/setup-orin.sh`. What follows is the manual, step-by-step version of the same
recipe - read it to understand what a build stage actually does, to debug a failure, or to
adapt the pipeline to a different checkpoint revision. It is not a second way to set this up;
it's what the automation runs, spelled out.

### 1. Build TensorRT-Edge-LLM and the Cosmos3-Edge engine

Clone [NVIDIA/TensorRT-Edge-LLM](https://github.com/NVIDIA/TensorRT-Edge-LLM) at commit
`e8b29522938901f6df19ebeedd4b69bc8edbcd97` (tag `v0.10.1`) and build its native runtime per
its own instructions (`kernelSrcs/build_cutedsl.py` for the `fmha` and `int4_fp16_gemm`
kernel groups, then a CMake configure/build for the `_edgellm_runtime`,
`NvInfer_edgellm_plugin`, `llm_build`, and `visual_build` targets - see
`scripts/setup-orin.sh`'s `do_build_edgellm_runtime` for the exact commands and environment
this repo builds against). Then:

1. **Download `nvidia/Cosmos3-Edge`** from Hugging Face (see NOTICE.md - NVIDIA Open Model
   License; it's gated, accept the license on the model page first). The reasoner's LLM
   weights are indexed directly at the snapshot root by `model.safetensors.index.json` (698
   tensors); the vision tower is a separate `vision_encoder/` subfolder. Neither needs the
   sibling `vae/` (image/video generation decoder) or other omni components this demo never
   loads - `scripts/setup-orin.sh`'s `do_download_checkpoint` reads the root index first to
   fetch exactly the shards it references, plus `vision_encoder/*` and the tokenizer files.
2. **Generate a source manifest** the quantizer requires: a `results/model-download.json`
   receipt with the SHA-256 and byte size of every downloaded file, keyed by relative path.
   The quantizer (next step) refuses to run without it and re-verifies every hash against it
   before and during conversion, as a guard against a corrupted or tampered checkpoint - see
   `do_generate_manifest`.
3. **Quantize to INT4**: `vendor/quantize_cosmos3_rtn.py --source <snapshot-root> --output
   <new-empty-dir> --quantization-scope all-linears --apply` (CPU-only, symmetric
   round-to-nearest, group-128; not part of the public TensorRT-Edge-LLM SDK - see NOTICE.md
   for where this script comes from). `--output` must be a new directory that doesn't exist
   yet; it copies `config.json`, the tokenizer, and the chat template through unchanged into
   its output itself, so there is no separate file-copying step after this one.
4. **Add four multimodal token IDs to the quantized checkpoint's `config.json`** before
   export - `image_token_id`, `video_token_id`, `vision_start_token_id`,
   `vision_end_token_id`. The quantizer copies `config.json` through from the source
   unchanged, and the upstream checkpoint's `config.json` doesn't have them; the exporter
   needs them and does not derive them on its own. This repo's actual deployed engine's own
   `config.json` confirms the correct values (`19`, `18`, `20`, `21` respectively) - see
   `do_fix_quant_config`.
5. **Export with `--int4-gemm-plugin-version 1`, not the default 2.** The default V2 (cuteDSL
   fragment-layout) plugin produces an ONNX that fails at `IBuilder::buildSerializedNetwork` with
   `Error Code 9: could not find any supported formats consistent with input/output data types` on
   an ordinary `Int4GroupwiseGemmPluginV2` node. V1 (the legacy AWQ-swizzled plugin) exports and
   builds cleanly: `tensorrt-edgellm-export <quantized-dir> <onnx-out> --task reasoning
   --skip-visual --int4-gemm-plugin-version 1 --quantization int4_awq`.
6. **Build the vision engine too, from the same downloaded snapshot** (`vision_encoder/` + the
   snapshot root's `config.json`, `--skip-llm`, no quantization - vision stays FP16). A vision
   engine built against a *different* checkpoint's externalized/refit weights will not load
   (`missing tensor model.projector.linear_fc1.bias`) - always build both from the same source.
7. **Manually populate `content_types` in `processed_chat_template.json`** after export, if the
   exporter's automatic chat-template extraction produced an empty `"content_types": {}` stub
   (check the output - it fails silently, not with an error). Confirm the correct value against
   the checkpoint's own `chat_template.jinja`; for Cosmos3-Edge (Qwen3-VL-based text tower) this is
   `{"image": {"format": "<|vision_start|><|image_pad|><|vision_end|>"}, "video": {"format":
   "<|vision_start|><|video_pad|><|vision_end|>"}}`.
8. **Build the engine** with `llm_build --onnxDir <onnx>/llm --engineDir <engine-dir>
   --maxInputLen 1024 --maxKVCacheCapacity 1024 --maxKVPoolPages 8 --maxBatchSize 1` and
   `visual_build --onnxDir <onnx>/visual --engineDir <engine-dir> --minImageTokens 4
   --maxImageTokens 1024 --maxImageTokensPerImage 512` (visual engine lands under
   `<engine-dir>/visual/` automatically). These specific input/KV/batch capacities match RAM
   headroom measured on an 8 GB Orin Nano - raising them needs re-measuring, not just a flag
   change. `<engine-dir>` is what `engine-link` should point at below -
   `shim/cosmos3_shim_v1.py` reads `llm.engine` + `config.json` from there.

### 2. Install this repo

```
sudo mkdir -p /opt/live-vision-cosmos-demo && sudo chown $USER /opt/live-vision-cosmos-demo
git clone https://github.com/nv-asotelo/live-vision-cosmos-demo /opt/live-vision-cosmos-demo
cd /opt/live-vision-cosmos-demo
ln -s /path/to/your/built/engine engine-link   # the directory containing llm.engine + config.json
cp ui/config/engines.example.json engines.json # edit "path" to match the engine-link above
```

### 3. Set up text-to-speech

```
mkdir piper && cd piper
# get a piper binary release for your architecture (aarch64 for Jetson) from
# https://github.com/rhasspy/piper/releases or build from source
curl -sL -o en_US-ljspeech-medium.onnx \
  "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/ljspeech/medium/en_US-ljspeech-medium.onnx"
curl -sL -o en_US-ljspeech-medium.onnx.json \
  "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/ljspeech/medium/en_US-ljspeech-medium.onnx.json"
```

`medium` quality, not `high`: measured directly on an Orin, `high`-tier voices roughly double
synthesis time for the same sentence, which fights this project's own "fastest latency" design
goal for a marginal quality gain speech-through-a-small-speaker doesn't showcase. See NOTICE.md
before substituting a different voice - several published Piper voices carry non-commercial-only
licenses inherited from their base voice, not obvious from the filename.

### 4. Set up the Reachy Mini bridge (optional - only for using Reachy Mini as a video source)

```
python3 -m venv reachy_env && reachy_env/bin/pip install -r reachy/requirements.txt
```

Installs cleanly from prebuilt aarch64 wheels on JetPack + Python 3.12, no compilation needed.
`requirements.txt`'s own header explains the pinned `aiortc==1.10.1` (a newer aiortc has an
RTX-decoding bug this version works around). Motor/app/TTS control (`--reachy-daemon-url`) does
not need this bridge - it talks to the robot's own REST API directly.

### 5. TLS certificate

```
mkdir tls && openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout tls/key.pem -out tls/cert.pem -subj "/CN=live-vision-cosmos-demo"
```

### 6. Services config and systemd units

```
cat > services.json <<'EOF'
{}
EOF
```

(`services.json` covers services this process does not itself manage besides the registered
engines - leave it empty unless you add more.)

Edit the `User`/`Group` and `REACHY-MINI-IP` placeholders in each `systemd/*.service`, then:

```
sudo cp systemd/*.service /etc/systemd/system/
sudo cp systemd/dropins/99-live-vision-cosmos-demo-swap.conf /etc/sysctl.d/
sudo install -d /etc/systemd/system/live-vision-cosmos-demo-shim.service.d
sudo cp systemd/dropins/live-vision-cosmos-demo-shim.service.d-10-no-swap.conf \
  /etc/systemd/system/live-vision-cosmos-demo-shim.service.d/10-no-swap.conf
sudo sysctl --system
sudo systemctl daemon-reload
sudo systemctl enable --now live-vision-cosmos-demo-shim live-vision-cosmos-demo-ui
sudo systemctl enable --now reachy-mjpeg-bridge   # only if you set up the bridge
```

Engine switching (`/api/engines/*`) restarts the shim via `sudo -n systemctl {start,stop}
live-vision-cosmos-demo-shim` - grant that specific, narrow passwordless sudo rule to whichever
user runs the UI service, rather than broader sudo access:

```
echo 'YOUR_USERNAME ALL=(root) NOPASSWD: /usr/bin/systemctl start live-vision-cosmos-demo-shim.service, /usr/bin/systemctl stop live-vision-cosmos-demo-shim.service' | sudo tee /etc/sudoers.d/live-vision-cosmos-demo
```

Open `https://<orin-ip>:8443/`.

## Adding a second engine

`engines.json` is a registry, not a single path - add a second entry with its own `backend_port`,
`service`, and `path` (pointing at a second built engine directory) to get a live model-switch
button between them, with a real elapsed-time progress bar during the swap. Every registered
`protocol` must currently be `"cosmos"` (an OpenAI-compatible `/v1/chat/completions` + `/health/ready`
shim, same contract as `shim/cosmos3_shim_v1.py`) - `ui/scripts/engine_backends.py` validates the
registry strictly and will refuse anything else.

## Running the tests

```
python3 -m unittest discover -s ui/tests
node --test ui/tests/test_engine_switch.js
```

50 tests total. No device, network, GPU, or model required - a fake HTTP backend (Python) and a
fake DOM (JS) stand in for both.

## License

This repository's own code is Apache License 2.0 - see `LICENSE`. It talks to and builds on
several third-party components under their own licenses - see `NOTICE.md` before redistributing,
particularly regarding the Piper voice model and NVIDIA Cosmos model weights, neither of which
this repository ships.
