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

## Requirements

- **Jetson Orin (Nano or better) with JetPack already flashed and booting.** This repo is the
  application layer only - it does not flash or provision the OS.
- **A 64 GB SD card or larger is recommended.** The application layer itself (this repo, the built
  engine, Piper, and the TensorRT-Edge-LLM Python environment the shim runs in) is roughly 5 GB;
  JetPack's own base install is the majority of what a card needs to hold. A 32 GB card is
  possible if you are careful about what else you install, but leaves it noticeably tighter.
- **NVIDIA's [TensorRT-Edge-LLM](https://github.com/NVIDIA/TensorRT-Edge-LLM) SDK**, built on
  device, to both build the Cosmos3-Edge engine and provide the Python venv the shim runs from.
  Not vendored in this repo - it's a substantial NVIDIA SDK with its own license and update cycle.
- Reachy Mini robot on the same LAN, if you want the robot-control features. Everything else
  (webcam + Cosmos3-Edge captioning) works without one.

## Setup

### 1. Build TensorRT-Edge-LLM and the Cosmos3-Edge engine

Clone and build [NVIDIA/TensorRT-Edge-LLM](https://github.com/NVIDIA/TensorRT-Edge-LLM) per its
own instructions, then:

1. **Download `nvidia/Cosmos3-Edge`** from Hugging Face (see NOTICE.md - NVIDIA Open Model
   License). It's a Mixture-of-Transformers Omni checkpoint: one `transformer/` subfolder with two
   towers (autoregressive text, diffusion image/video/action), selected at export time by
   `--task {policy,reasoning}`. Point quantization/export at the `transformer/` subfolder
   specifically, not the snapshot root - the snapshot root has zero flat `.safetensors` files and
   the quantizer silently no-ops against it.
2. **Quantize to INT4**: `scripts/rtn_int4_quantize.py --src .../transformer --dst
   cosmos3_int4_ckpt` (RTN, groupwise).
3. **Fix the checkpoint's `config.json` and index filename** before export - the quantizer copies
   the source through unchanged, and two things are missing for this checkpoint specifically:
   - Add `"model_type": "cosmos3_edge"` and the four multimodal token IDs (`image_token_id`,
     `video_token_id`, `vision_start_token_id`, `vision_end_token_id`) from the *snapshot root's*
     `config.json` (not `transformer/config.json`, which lacks them).
   - Rename `diffusion_pytorch_model.safetensors.index.json` to `model.safetensors.index.json`
     (the name the exporter's loader requires) and add the quantizer's `.weight_scale` index
     entries by hand.
   - Copy `tokenizer.json`, `tokenizer_config.json`, `special_tokens_map.json`,
     `chat_template.jinja` from the snapshot root into the checkpoint dir.
4. **Export with `--int4-gemm-plugin-version 1`, not the default 2.** The default V2 (cuteDSL
   fragment-layout) plugin produces an ONNX that fails at `IBuilder::buildSerializedNetwork` with
   `Error Code 9: could not find any supported formats consistent with input/output data types` on
   an ordinary `Int4GroupwiseGemmPluginV2` node. V1 (the legacy AWQ-swizzled plugin) exports and
   builds cleanly: `tensorrt-edgellm-export --task reasoning --skip-visual
   --int4-gemm-plugin-version 1`.
5. **Build the vision engine too, from the same source checkpoint** (`vision_encoder/` + the
   snapshot root's `config.json`, `--skip-llm`). A vision engine built against a *different*
   checkpoint's externalized/refit weights will not load (`missing tensor
   model.projector.linear_fc1.bias`) - always build both from the same source.
6. **Manually populate `content_types` in `processed_chat_template.json`** after export, if the
   exporter's automatic chat-template extraction produced an empty `"content_types": {}` stub
   (check the output - it fails silently, not with an error). Confirm the correct value against
   the checkpoint's own `chat_template.jinja`; for Cosmos3-Edge (Qwen3-VL-based text tower) this is
   `{"image": {"format": "<|vision_start|><|image_pad|><|vision_end|>"}, "video": {"format":
   "<|vision_start|><|video_pad|><|vision_end|>"}}`.
7. **Compile `llm_build`/`visual_build`** if their binaries don't already exist: `cmake --build
   build --target llm_build -j$(nproc)` (and `visual_build`), from within TensorRT-Edge-LLM's own
   build tree - both link against `libNvInfer_edgellm_plugin.so`, already built by the SDK's own
   setup.
8. **Build the engine**, pointing `--engine` at wherever you want the final `llm.engine` +
   `config.json` to live - `shim/cosmos3_shim_v1.py`'s `--engine` argument points here.

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
