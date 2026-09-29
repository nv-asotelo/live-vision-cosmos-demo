# Agent instructions

This repo is a one-shot deployable demo: **Live Vision UI + Reachy Mini robot control +
NVIDIA Cosmos3-Edge**, running on a Jetson Orin. If you were asked to "set up" or "deploy"
this demo, the goal is: a fresh Orin (JetPack already flashed, nothing else installed) plus
any laptop → this repo's automation → a working `https://<orin-ip>:8443/` serving live
camera captions from a locally-hosted TensorRT engine.

You do not need to understand TensorRT-Edge-LLM, Cosmos3-Edge's checkpoint format, or CUDA
to do this. The two scripts below encode all of that. Read this whole file before running
anything - it tells you which parts are safe to just run and which ones need a human.

## Optional JetPack preparation

Keep an existing booting JetPack 7.2.1 / L4T 39.2.1 installation. Missing CUDA/TensorRT
components are installed by demo setup; they are not a reason to reflash.
For an explicitly requested fresh SD card from a Mac, use
[the flash skill](.agents/skills/flash-jetpack-sd-mac/SKILL.md) and
[its workflow](docs/jetpack-sd-mac.md) before returning here. OS preparation needs no
Hugging Face token. It does require identifying the card and macOS administrator authentication.
The same command continues through USB first boot and SSH verification; the user
completes NVIDIA's license/account prompts in Terminal. Use `--first-boot-only`
for a card already flashed. A USB-C connection alone is not a Mac recovery flasher.

## Model access needs a human

**A Hugging Face access token that has accepted `nvidia/Cosmos3-Edge`'s gated-model
license.** You cannot click "Agree" on a license on someone's behalf. If you don't have a
token that's already accepted it:

1. Tell the user (or whoever you're doing this for) you need them to: visit
   https://huggingface.co/nvidia/Cosmos3-Edge, accept the license, then create a **read**
   token at https://huggingface.co/settings/tokens and give it to you as `HF_TOKEN`.
2. Do not proceed past this point without a real token. Every later stage depends on it.

Everything else below is safe to run autonomously.

## Running it

From any laptop with `bash`, `ssh`, `scp`, and network access to the Orin - no GPU, no
particular OS, no local Python/CUDA toolchain needed there:

```bash
export HF_TOKEN=hf_...                    # required, see above
export REACHY_MINI_IP=192.168.1.50        # optional - omit if there's no robot
./scripts/bootstrap.sh jetson-user@orin-ip
```

`bootstrap.sh` copies this repo to `/opt/live-vision-cosmos-demo` on the Orin over SSH, then
runs `scripts/setup-orin.sh` there via `sudo -E ssh -t`. That second script does every GPU-
and compute-heavy step **on the Orin**, in order:

1. Install apt build/runtime packages.
2. Clone NVIDIA's TensorRT-Edge-LLM SDK at its pinned commit and build its native runtime
   (CUDA kernels, `llm_build`/`visual_build` binaries) - this is the slow step, easily
   45+ minutes on an Orin Nano.
3. Download the Cosmos3-Edge checkpoint from Hugging Face (needs `HF_TOKEN`).
4. Quantize it to INT4 with the vendored `vendor/quantize_cosmos3_rtn.py` converter.
5. Export to ONNX, then build the final TensorRT engine.
6. Install Piper (TTS), the Reachy Mini bridge (if `REACHY_MINI_IP` is set), a self-signed
   TLS cert, and the three systemd services, then start them.
7. Poll the shim's health endpoint until it reports ready and print the final URL.

It is **idempotent** - every stage records a marker under
`/opt/live-vision-cosmos-demo/.setup-state/`. If it fails partway (a flaky download, a
transient apt mirror issue), fix whatever it reported and just run `bootstrap.sh` again;
completed stages are skipped, not redone. Do not try to skip ahead by hand-editing markers
unless you're certain a stage's actual output is already correct on disk.

## If bootstrap.sh isn't an option (no SSH from this laptop, air-gapped Orin, etc.)

SSH into the Orin yourself, get this repo onto it by whatever means you have (the point of
`bootstrap.sh` is just "get the repo there and run one script" - any transport works), then:

```bash
cd /opt/live-vision-cosmos-demo   # scripts/setup-orin.sh expects to live at this exact path -
                                   # systemd units and the shim's own defaults hardcode it
sudo -E HF_TOKEN=hf_... REACHY_MINI_IP=192.168.1.50 bash scripts/setup-orin.sh
```

## Verifying success

```bash
curl -k https://<orin-ip>:8443/          # UI responds
curl http://<orin-ip>:8001/health/ready  # shim reports {"status":"ready"}
```

Or just open `https://<orin-ip>:8443/` in a browser (accept the self-signed cert warning
once), grant camera permission, and confirm captions stream in.

## Boundaries - things not to "fix" without re-deriving them

Several values in `scripts/setup-orin.sh` look like arbitrary constants but are pinned to
match this repo's own actual, measured, working deployment. Don't change them speculatively:

- **`--int4-gemm-plugin-version 1`** in the export step. The default V2 plugin fails
  `IBuilder::buildSerializedNetwork` on this checkpoint (`Error Code 9`). V1 is the one that
  works. This was found by hitting the V2 failure directly, not by preference.
- **`--maxInputLen 1024 --maxKVCacheCapacity 1024 --maxKVPoolPages 8 --maxBatchSize 1`** in
  the `llm_build` step. These match this repo's actual deployed engine's own `config.json`
  `builder_config` byte-for-byte. Raising them changes RAM headroom on an 8 GB board - do
  not bump them without re-measuring.
  `--parallel 1` in the TensorRT-Edge-LLM native build. More workers OOMs a stock Orin Nano
  during compilation; this was a measured constraint, not a default left unchanged.
- **`--quantization-scope all-linears`**. This repo's actual deployed checkpoint's
  `exclude_modules` list confirms `all-linears` (not `mlp-only`) is what's really running,
  despite `mlp-only` scoring better on one internal quality benchmark elsewhere. Don't
  "improve" this without also validating the resulting engine's answers.
- The four `*_token_id` values injected into the quantized checkpoint's `config.json` before
  export are copied from this repo's actual deployed engine's own config, not derived from
  first principles. If a future Cosmos3-Edge checkpoint revision changes these, the fix is
  to re-derive them from a real working engine, not to guess.

If you hit a build failure this document doesn't cover, the full step-by-step manual recipe
(with the reasoning behind each fix) is in `README.md`'s "Setup" section - read that before
improvising a workaround, since several of its steps exist because the naive/obvious command
silently produces a broken checkpoint rather than an error.

## Testing changes to this repo's own code (not the Cosmos3-Edge build)

```bash
python3 -m unittest discover -s ui/tests
node --test ui/tests/test_engine_switch.js
```

50 tests, no device, network, GPU, or model required - fake HTTP backend and fake DOM stand
in for both. Run these after editing anything under `ui/`. They do not exercise
`scripts/setup-orin.sh` or the Cosmos3-Edge build pipeline itself (there is no way to test
that without an actual Orin and a real GPU build).

## Repo layout

See the table in `README.md` ("What's here") - it's the same information, kept there so it
has one home instead of two copies drifting apart.
