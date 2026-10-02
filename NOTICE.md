# Notices

This repository's own code (including `scripts/` and the agent skill) is licensed
under Apache License 2.0 - see `LICENSE`. It builds on and talks to the third-party components
below, each under its own license; two files in `reachy/reachy_stream/` are Pollen Robotics' own
code, copied unmodified (see below). None of this is legal advice; if you plan to redistribute this
project further, verify current license terms for each component yourself.

## NVIDIA Cosmos

`nvidia/Cosmos3-Edge`, at the revision this repo pins, is licensed by NVIDIA Corporation under the
[OpenMDW License 1.1](https://openmdw.ai/license/1-1/).

**Built on NVIDIA Cosmos.**

This repository does not ship Cosmos model weights. `shim/cosmos3_shim_v1.py` serves a
TensorRT engine you build yourself from a separately-downloaded `nvidia/Cosmos3-Edge` checkpoint -
see "1. Build TensorRT-Edge-LLM and the Cosmos3-Edge engine" (under "Setup") in `README.md`. If
you redistribute a built engine or checkpoint derived from Cosmos, review the OpenMDW License
1.1's own distribution requirements, including keeping a copy of that license, and the copyright
and other notices of origin that came with the model, in what you distribute.

## vendor/quantize_cosmos3_rtn.py

Apache License 2.0, by the same author as this repository; vendored here with a
patch. It is not part of NVIDIA's public TensorRT-Edge-LLM SDK, which has no RTN quantizer
at the commit this repo pins. The patch changes how the script records that a
checkpoint is quantized - embedding `quantization_config` directly in the checkpoint's own
`config.json` instead of writing a separate `hf_quant_config.json` sidecar file, so that
TensorRT-Edge-LLM's own checkpoint loader actually recognizes the result as INT4 rather than
silently treating it as FP16 - and the `README.md` it writes into the quantized checkpoint, which
now describes that `config.json` change and says whether the source model card was actually
copied. Neither touches the quantization algorithm or math itself, which was already correct.
See the file's own header comment for the full story of the `config.json` change, and
`do_quantize` in `scripts/setup-orin.sh` for why the pipeline needs this separate quantization
pass at all.

## Piper (text-to-speech engine)

The `piper` binary itself: MIT License, Copyright (c) 2022 Michael Hansen. Project:
[rhasspy/piper](https://github.com/rhasspy/piper). (Piper has since moved to active development
as [OHF-Voice/piper1-gpl](https://github.com/OHF-Voice/piper1-gpl) under the Open Home Foundation,
GPL-3.0 - confirm which build you are actually running before redistributing it, by license
terms they differ meaningfully.) `scripts/setup-orin.sh` downloads the official prebuilt
`v1.2.0` `aarch64` release binary from
[rhasspy/piper's GitHub releases](https://github.com/rhasspy/piper/releases) at install time;
this repository does not vendor the binary itself.

Piper embeds [espeak-ng](https://github.com/espeak-ng/espeak-ng) (GPL-3.0) for phonemization.

**Voice model:** this repository does not ship a voice model file - the setup steps in
`README.md` download `en_US-ljspeech-medium` at install time, MIT-licensed, trained from scratch
on the public-domain [LJ Speech Dataset](https://keithito.com/LJ-Speech-Dataset/) (model card on
[Hugging Face](https://huggingface.co/rhasspy/piper-voices/blob/main/en/en_US/ljspeech/medium/MODEL_CARD)).
If you substitute a different Piper voice, check its own MODEL_CARD - several published Piper
voices (including ones with "_r" in their name, trained by fine-tuning from another voice) carry
non-commercial-only research licenses inherited from their base voice.

## Reachy Mini

Made by [Pollen Robotics](https://www.pollen-robotics.com/), now part of
[Hugging Face](https://huggingface.co/blog/hugging-face-pollen-robotics-acquisition) (acquired
April 2025). SDK: [pollen-robotics/reachy_mini](https://github.com/pollen-robotics/reachy_mini),
Apache License 2.0.

> Made with ❤️ by Pollen Robotics and Hugging Face.

`reachy/reachy.py` is an independent REST client this project wrote against the robot's onboard
daemon API; it is not part of Pollen Robotics' or Hugging Face's own SDK and is not published or
endorsed by them.

## reachy/reachy_stream/

`reachy/reachy_stream/stream.py` and `reachy/reachy_stream/const.py` are unmodified copies of
`custom_components/reachy_mini/stream.py` and `const.py` from Pollen Robotics' Reachy Mini Home
Assistant integration,
[pollen-robotics/reachy_mini_homeassistant](https://github.com/pollen-robotics/reachy_mini_homeassistant):
Apache License 2.0, Copyright 2026 Pollen Robotics. As of 2026-10-01 both are identical to
upstream `main` (`855c1c09`); upstream last changed `stream.py` in `da5b0d64b1` and `const.py` in
`07972e3a07`, both on 2026-07-03. Neither file carries a license header and that repository ships
no NOTICE file, so the copyright line from its `LICENSE` is reproduced here; this repository's
`LICENSE` is the full Apache License 2.0 text. `reachy/reachy_stream/__init__.py` is this
project's own - upstream's package `__init__` imports Home Assistant, so it is not copied.
`reachy/reachy_mjpeg_bridge.py` builds its WebRTC session to the robot on `stream.py`'s
`ReachyMiniStreamClient`.

## Mac JetPack SD preparation

The Mac orchestration, card writer, validation helpers, and agent skill are original
Apache-2.0 code, adapted from earlier Jetson bring-up scripts by the same author. Python helpers
use only the standard library. No third-party source, OS image, NVIDIA binary, or
model weight is redistributed with this workflow.

Thanks to NVIDIA for Jetson Linux and its image-creation tools, and the QEMU, Ubuntu,
Python, Zstandard, and Homebrew contributors for the host tooling:

| Downloaded or separately installed component | License / acknowledgement |
|---|---|
| NVIDIA JetPack / Jetson Linux BSP and rootfs | NVIDIA's accompanying Jetson software terms and individual component licenses apply. The downloaded `jetson-disk-image-creator.sh` is marked `LicenseRef-NvidiaProprietary`; `l4t_flash_prerequisites.sh` is BSD-3-Clause. The build makes one local performance edit to the image creator's `dd` invocation (4 MiB blocks, flush, progress), preserving its full NVIDIA copyright/license header. No NVIDIA script is vendored here. [Official downloads](https://developer.nvidia.com/embedded/jetpack/downloads). |
| QEMU | [GNU GPL version 2, with component-specific licenses](https://www.qemu.org/docs/master/about/license.html); QEMU is a trademark of Fabrice Bellard. |
| Ubuntu 22.04 cloud image | Canonical and the included package authors; [individual package licenses apply](https://ubuntu.com/legal/intellectual-property-policy). Guest package copyright files are under `/usr/share/doc/*/copyright`. |
| Python | [Python Software Foundation License and included component notices](https://docs.python.org/3/license.html). |
| Zstandard | Meta Platforms, Inc. and affiliates; [BSD-3-Clause](https://github.com/facebook/zstd/blob/dev/LICENSE), alternatively GPL-2.0. |
| Homebrew | Homebrew contributors; [BSD-2-Clause](https://github.com/Homebrew/brew/blob/master/LICENSE.txt). Used to install tools; not bundled. |

Generated images retain the upstream packages and their licenses; the repository's
Apache-2.0 license does not relicense those images or downloaded tools.

## Development

Developed by Alex Sotelo ([@nv-asotelo](https://github.com/nv-asotelo)), with Claude Sonnet/Opus 5
(Anthropic) on the Cosmos3-Edge engine build and deployment, and OpenAI GPT-6 Astra on the Live
Vision web UI - fixes and iteration by both throughout.
