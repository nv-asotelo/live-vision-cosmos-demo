# Agent instructions

## This branch: TensorRT-Edge-LLM 0.11 migration candidate

Use SDK commit `95515c2f87fba8982db5a519f9022277667b3cc9`. Read
[the upgrade assessment](docs/edgellm-0.11-upgrade.md) before deployment. Offline checks
do not establish Orin build success, visual accuracy, RAM footprint or latency. Historical
measurements below describe the 0.10.1 deployment. Re-export and rebuild both engines;
do not reuse 0.10.1 serialized engines or apply its JSON chat-template repair. The current
installer validates the checkpoint's original Jinja and invalidates stale SDK-dependent
stage markers. Use a fresh SD installation for this trial so the existing demo stays available.

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
[its workflow](docs/jetpack-sd-mac.md) before returning here. OS preparation requires
identifying the card and macOS administrator authentication.

### First boot is a separate acceptance gate

Read [First-boot setup and recovery](docs/first-boot-recovery.md) before discovering
or configuring a newly connected board. Identify it through the USB connection or
its local console; never probe a historical Orin IP to find a new device. Keep an
existing deployment untouched unless the user explicitly targets it. Do not remove
another board's SSH key or accept a mismatch to bypass device identification.

Use `python3 scripts/jetpack/first_boot.py probe --json` for a read-only USB/serial
inventory. If USB is absent, check power and reconnect the data cable once before
inferring anything about firmware. A login prompt does not validate account creation.
Stop after one controlled failed login with explicitly supplied credentials; do not
guess usernames/passwords or assume wizard cancellation was safe. For an account
failure, identify the returned SD by reader, size and available serial, then use the
guide's read-only offline audit before choosing a repair. The audit is not a reset.

Before running bootstrap, verify a fresh successful login, the intended account,
SD root device, L4T release, filesystem expansion and this board's network identity.
State unknowns explicitly. Neither a flash receipt nor a reachable login prompt
establishes those results.

## Network changes after installation

Follow [the network-switching guide](docs/network-switching.md) only after verified
real-image inference over Ethernet. Keep an authenticated USB console during the
Wi-Fi test, identify profiles from the actual board, and enter Wi-Fi secrets in
the local prompt. Restore Ethernet and verify another caption before declaring
the network test complete. Keep device details and secrets out of source control.

## Model access needs no human

No Hugging Face token is needed: `nvidia/Cosmos3-Edge`, at the revision this repo pins, is
public and not gated, and setup downloads it without one. Do not ask the user for a token
(if `HF_TOKEN` is set anyway, the download uses it). If Hugging Face ever refuses the
download because the model has been gated since, setup stops with a message saying what the
user has to do.

Everything below is safe to run autonomously, except typing passwords - the only step that
needs a human. `bootstrap.sh` (and anything below run with `sudo` on the Orin) needs the Orin
account's sudo password unless that account has passwordless sudo, and `bootstrap.sh` needs the
account's SSH password at every connection unless you log in with a key - see "Running it".

## Running it

From any laptop with `bash`, `ssh`, `scp`, `tar`, and network access to the Orin - no GPU, no
particular OS, no local Python/CUDA toolchain needed there:

```bash
export REACHY_MINI_IP=192.0.2.50   # optional - omit if there's no robot
./scripts/bootstrap.sh jetson-user@orin-ip
```

`bootstrap.sh` asks for the Orin account's sudo password twice: once to create
`/opt/live-vision-cosmos-demo` and make the SSH login account its owner, then again to run
`setup-orin.sh` as root. An unattended run needs passwordless sudo on the Orin and SSH key login
to it (`bootstrap.sh` opens a new SSH connection for each step, so a password login is asked for
at every one); otherwise the user has to be there to type the passwords.

The robot's address is kept in `/opt/live-vision-cosmos-demo/reachy.env`. If the user later
needs a different robot (a spare, a new DHCP lease, or adding one where there was none), run
`sudo bash /opt/live-vision-cosmos-demo/scripts/set-reachy-ip.sh <address>` on the Orin - don't
re-run setup or hand-edit systemd units. With no argument it prints the current address. It
refuses an address where no Reachy Mini daemon answers unless given `--force`; if it refuses,
check the address with the user rather than forcing it. Normally it then just rewrites
`reachy.env` and restarts the UI and camera/mic bridge services - seconds, with inference
running throughout. If robot-daemon recovery was turned on (the drop-in
`/etc/systemd/system/reachy-mjpeg-bridge.service.d/10-recover.conf` exists), run
`bash /opt/live-vision-cosmos-demo/reachy/setup_robot_recovery.sh` again afterwards, on the Orin
as the bridge's service account (not root; it asks for the robot's `pollen` password): its key
is installed per robot, and recovery follows `REACHY_MINI_IP` to the new one. With no arguments
the script targets the robot in `reachy.env` - now the new one.

On an Orin set up without a robot, or by an older version of this repo that wrote the address
into the systemd units, `set-reachy-ip.sh` instead re-runs `setup-orin.sh`'s Reachy stages once
(`setup_reachy_env` - a pip install, so the Orin needs internet - then `install_systemd_units`
and `enable_services`), which restarts the inference shim too: about a minute while the model
reloads. If the Orin has no `/opt/live-vision-cosmos-demo/scripts/set-reachy-ip.sh` at all (it
was set up before the script existed), refresh the repo there first, from the root of this
repo's checkout on the laptop:

```bash
git archive --format=tar HEAD | ssh jetson-user@orin-ip "tar -x -C /opt/live-vision-cosmos-demo"
```

`setup-orin.sh` runs every stage it has no marker for, so on an Orin set up by an earlier
version of this repo that slow path can do more than the Reachy stages: stages added since then
run too - `pin_clocks` (power mode and clock pinning), or both ONNX exports (`export_onnx_llm`
and `export_onnx_visual`, which replaced a single `export_onnx` stage), an on-device re-export
of the model with the shim still loaded, before the Reachy stages run.
So check first: if any stage in `main()` of `scripts/setup-orin.sh` has no marker in
`/opt/live-vision-cosmos-demo/.setup-state/`, tell the user before running `set-reachy-ip.sh`.

`bootstrap.sh` copies this repo to `/opt/live-vision-cosmos-demo` on the Orin over SSH - a
`git archive` of `HEAD`, so commit any local edits you want deployed (outside a git checkout
it tars the directory instead) - then runs `scripts/setup-orin.sh` there over `ssh -t`, under
`sudo -E` on the Orin. That second script does every GPU- and compute-heavy step **on the
Orin**, in order:

1. Install apt build/runtime packages.
2. Clone NVIDIA's TensorRT-Edge-LLM SDK at its pinned commit and build its native runtime
   (CUDA kernels, `llm_build`/`visual_build` binaries) - this is the slow step, easily
   45+ minutes on an Orin Nano.
3. Download the Cosmos3-Edge checkpoint from Hugging Face (no token needed).
4. Quantize the checkpoint to INT4 with the vendored RTN pre-quantization pass, export to
   ONNX, then build the final TensorRT engine.
5. Install Piper (TTS), the Reachy Mini bridge (if `REACHY_MINI_IP` is set), a self-signed
   TLS cert, and the systemd services - UI, shim and (with a robot) bridge - then start them.
6. Poll the shim's health endpoint until it reports ready and print the final URL.

It is **idempotent** - every stage records a marker under
`/opt/live-vision-cosmos-demo/.setup-state/`. If it fails partway (a flaky download, a
transient apt mirror issue), fix whatever it reported and just run `bootstrap.sh` again;
completed stages are skipped, not redone (the markers are root-owned files - `sudo rm` one to
make that stage run again). Do not try to skip ahead by hand-editing markers
unless you're certain a stage's actual output is already correct on disk.

For a failure after both ONNX exports, read the
[installer recovery guidance](docs/first-boot-recovery.md#if-the-demo-installer-stops).
The preflight can select a 12 GiB remaining-space allowance only after checking all
preceding stages, exported tensor-file ranges and the provider Jinja. Do not lower
the threshold or create markers by hand. On util-linux 2.39.3, select swap report
columns with `swapon --show=NAME,SIZE`; `--output` silently selects a different option
and caused a verified false rejection of active swap during this trial.

**Optional `--host-quantize`** (`./scripts/bootstrap.sh --host-quantize jetson-user@orin-ip`)
does step 4's LLM quantize+export on the laptop instead of the Orin, getting the SDK's
primary V2/cuteDSL plugin instead of its legacy V1 fallback - see the Boundaries entry on
`--int4-gemm-plugin-version` below and README.md "Host-accelerated quantization" for why
this exists and its exact requirements (Linux, 12+ GB available RAM, and `python3`, `git` and
`rsync` on the laptop; no macOS at any RAM size, no GPU needed). It's a genuine improvement
when available, not required - the default path produces a fully functional engine either
way. The laptop copies its export to a staging directory on the Orin, which `setup-orin.sh`
adopts and rebuilds the engine from - so this also upgrades an Orin already set up on the
default path: re-run `bootstrap.sh` with `--host-quantize`, and the Orin skips the stages it
has already completed, such as the SDK build and the checkpoint download. If the laptop you're
working from is a Mac or visibly RAM-constrained, don't bother attempting it; say so and
proceed with the default path rather than letting the preflight check fail loudly for a user
who didn't ask for it.

## If bootstrap.sh isn't an option (no SSH from this laptop, etc.)

SSH into the Orin yourself, get this repo onto it by whatever means you have (the point of
`bootstrap.sh` is just "get the repo there and run one script" - any transport works), then:

```bash
cd /opt/live-vision-cosmos-demo   # scripts/setup-orin.sh expects to live at this exact path -
                                   # systemd units and the shim's own defaults hardcode it
export REACHY_MINI_IP=192.0.2.50   # optional - omit if there's no robot
sudo -E bash scripts/setup-orin.sh
```

The account that runs `sudo` owns the install and runs the services; export `SERVICE_USER` as
well to choose a different one. The Orin itself needs internet access on this path too: setup
downloads apt packages, the SDK, Python packages, the checkpoint and Piper.

## Verifying success

```bash
curl -k https://<orin-ip>:8443/          # UI responds
curl http://<orin-ip>:8001/health/ready  # shim reports {"status":"ready"}
```

**This is not enough on its own.** A broken checkpoint has been observed to pass both of
these checks - services active, health endpoints reporting ready, structurally valid
OpenAI-format API responses with correct token counts - while every actual generated
response was complete garbage (repeated nonsense characters, not real text in any
language). Always also submit a real request and read the actual text:

```bash
curl -s http://<orin-ip>:8001/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "nvidia/Cosmos3-Edge",
  "messages": [{"role": "user", "content": "Say hello and count from 1 to 5."}],
  "max_tokens": 32
}'
```

The response's `choices[0].message.content` must be coherent English matching the prompt.
If it isn't - even if every health check passed - something is genuinely broken; see
`vendor/quantize_cosmos3_rtn.py`'s header comment for the bug this once was: quantization
metadata the checkpoint loader couldn't recognize, so it read the packed INT4 weights as FP16.
(`scripts/setup-orin.sh`'s `do_quantize` comment covers the wrong fix tried first - an
on-the-fly quantization flag that silently exported FP16, which gave coherent text, so this
check can't catch it; see the Boundaries entry on `--quantization int4_awq` below.)
Or just open `https://<orin-ip>:8443/` in a browser (accept the self-signed cert warning
once), grant camera permission, and confirm captions stream in and actually describe what
the camera sees.

## Boundaries - things not to "fix" without re-deriving them

Several values in `scripts/setup-orin.sh` are retained from the measured 0.10.1
deployment to control the first comparison. They are not new 0.11 performance results.
Don't change them speculatively:

- **`nvpmodel -m 2` (`do_pin_clocks`).** Mode 2 is `MAXN_SUPER` on the Orin Nano Super this
  was measured on - an uncapped power mode one step above the board's "25W" default (mode 1).
  Combined with `jetson_clocks` (pinned to a boot-time systemd unit, since it is never
  persistent across a reboot on its own regardless of nvpmodel mode), measured effect on the
  `--host-quantize` build: GPU clock 306-918 MHz under the governor -> 1020 MHz fixed, decode
  14.77 -> 13.20 ms/token, a 640x480 image plus one token 305 -> 284 ms - 36-60 ms off every
  request (a 20-token answer: 583 -> 547 ms). Measured pinned, unpinned, then pinned again,
  every image new to the shim: the runtime caches vision-encoder output by image content, so a
  benchmark that repeats an image - even across separate runs - skips the encoder and
  understates latency. `nvpmodel -m`
  silently keeps the previous mode if the requested ID doesn't exist on a different board
  (mode IDs are not portable across Jetson modules), which is why `do_pin_clocks` checks
  `nvpmodel -q` reports `MAXN_SUPER` afterward and warns (doesn't die) if not.
- **`--int4-gemm-plugin-version 1`** in the on-Orin export step (`do_export_onnx_llm`).
  Exporting with the default V2 (cuteDSL) plugin **on an 8 GB Orin Nano gets OOM-killed by
  the kernel partway through the export itself**, even with every demo service stopped:
  measured on an idle Orin, it reached 6.8 GB resident before the kill (dmesg: `Out of
  memory: Killed process ... (tensorrt-edgell)`), with 40 MB of system memory left. Run to
  completion on a larger host, the same export peaks at 8.96 GB - more than the board has.
  (An older 3.7 GB figure came from a run with the inference shim still resident; don't cite
  it.) This is a RAM ceiling on the machine doing the export, not a format-compatibility
  error and not a limit on quantization accuracy - V1 and V2 compute the same INT4 GEMM math
  from byte-identical weights, just with different memory footprints during export.
  `scripts/bootstrap.sh --host-quantize` does the export on a capable host instead (Linux,
  12+ GB available RAM - no GPU needed, it's RAM-bound not GPU-bound) and gets the V2 plugin
  as a result; without it, or on a host that doesn't
  qualify (macOS at any RAM size, or a light-RAM Linux machine), the Orin does this step
  itself with V1 and the result is fully functional. See README.md "Host-accelerated
  quantization" for the full requirements and what actually differs. If you're setting this
  up unattended for someone on a Mac or a light-RAM laptop, tell them plainly that they got
  the on-Orin V1 build and why - don't silently stay quiet about it, and don't try to force
  V2 on the Orin directly; that just reproduces the OOM kill above.
- **`--maxInputLen 1024 --maxKVCacheCapacity 1024 --maxKVPoolPages 8 --maxBatchSize 1`** in
  the `llm_build` step. These match this repo's actual deployed engine's own `config.json`
  `builder_config` byte-for-byte. Raising them changes RAM headroom on an 8 GB board - do
  not bump them without re-measuring.
  `--parallel 1` in the TensorRT-Edge-LLM native build. More workers OOMs a stock Orin Nano
  during compilation; this was a measured constraint, not a default left unchanged.
- **Do not pass `--quantization int4_awq` (or any `--quantization` flag) to the export step.**
  It looks like the obvious way to get an INT4 engine, but it's a complete no-op for this
  checkpoint: it's gated on Mixture-of-Experts detection in
  `tensorrt_edgellm/scripts/export.py`, and Cosmos3-Edge's reasoner is a *dense* model. It
  silently exports plain FP16 with no warning or error - the engine builds, the service
  reports ready, and generated text is coherent, but the engine is ~4x oversized and
  meaningfully slower. This was the actual cause of a memory crisis (shim RSS
  5.9 GB on an 8 GB board, SSH sessions hanging under load) that looked, from the outside,
  like a stable working deployment until someone checked `free -h` or engine file size.
  INT4 quantization must happen as its own pass, via `vendor/quantize_cosmos3_rtn.py`,
  *before* export - see `do_quantize` in `scripts/setup-orin.sh`.
- **`vendor/quantize_cosmos3_rtn.py`'s output metadata format.** It must embed
  `"quantization_config": {"quant_method": "gptq", "group_size": 128}` directly inside the
  quantized checkpoint's own `config.json`. That is the *only* code path
  `tensorrt_edgellm/config.py`'s `_algo_to_quant_type()` recognizes as GPTQ-packed weights.
  Do not have it write a sidecar `hf_quant_config.json` file instead (even with a seemingly
  reasonable `quant_algo` field) - that file's mere *existence* short-circuits detection
  before the parser ever reaches the correct `config.json`-embedded path, silently falling
  back to `QUANT_FP16` and loading the packed INT4 tensors as raw FP16 bytes. This produces a
  checkpoint that builds and serves without any error, with structurally valid API responses,
  but generates complete garbage text (repeated nonsense characters) on every request -
  confirmed via direct ONNX weight-dtype inspection
  (`onnx.load(path, load_external_data=False)`, checking `graph.initializer` dtypes and
  whether `graph.node` op_types are `Int4GroupwiseGemmPlugin` vs plain `MatMul`) as the
  decisive test, since output coherence alone cannot distinguish "quantized correctly" from
  "silently not quantized" or "quantized but undiscoverable." The packing/zero-point math
  itself was correct the whole time; only the metadata was wrong.
- The four `*_token_id` values injected into the raw checkpoint's `config.json` before export
  are copied from this repo's actual deployed engine's own config, not derived from first
  principles. If a future Cosmos3-Edge checkpoint revision changes these, the fix is to
  re-derive them from a real working engine, not to guess.

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
in for both. Run these after editing anything under `ui/`.

For migration and SD-helper changes, run the corresponding offline checks:

```bash
python3 -m unittest discover -s scripts/tests
python3 -m unittest discover -s scripts/jetpack -p 'test_*.py'
```

The eight migration tests exercise stage invalidation, host-export receipts, template
validation and the shim's request/timing contract with a fake native runtime. The 13
SD-helper tests use fixtures and fake devices. None establishes a successful GPU build,
physical card write, boot, caption accuracy or inference performance.

## Repo layout

See the table in `README.md` ("What's here") - it's the same information, kept there so it
has one home instead of two copies drifting apart.
