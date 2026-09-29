# Notices

This repository's own code (including `scripts/` and the agent skill) is licensed
under Apache License 2.0 - see `LICENSE`. It builds on and talks to the third-party components
below, each under its own license. None of this is legal advice; if you plan to redistribute this
project further, verify current license terms for each component yourself.

## NVIDIA Cosmos

Licensed by NVIDIA Corporation under the [NVIDIA Open Model
License](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/).

**Built on NVIDIA Cosmos.**

This repository does not ship Cosmos model weights. `shim/cosmos3_shim_v1.py` serves a
TensorRT engine you build yourself from a separately-downloaded `nvidia/Cosmos3-Edge` checkpoint -
see "Building the Cosmos3-Edge engine" in `README.md`. If you redistribute a built engine or
checkpoint derived from Cosmos, review the NVIDIA Open Model License's own distribution
requirements (Sections 3.1-3.2), including providing recipients a copy of that license.

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

## `vendor/quantize_cosmos3_rtn.py`

A CPU-only INT4 round-to-nearest quantization converter for the Cosmos3-Edge checkpoint.
There is no upstream RTN quantizer in NVIDIA's public TensorRT-Edge-LLM SDK pin this repo
builds against, so this script is vendored, unmodified, from a separate Cosmos3-Edge-on-Orin
bring-up task on the same hardware family and account. That workspace's own newly-authored
code is licensed Apache-2.0. No model architecture, weights, or NVIDIA source code is
included in it - it reads an official NVIDIA checkpoint and writes a quantized derivative;
the underlying Cosmos3-Edge model and its license remain NVIDIA's, per the NVIDIA Cosmos
section above.

## Reachy Mini

Made by [Pollen Robotics](https://www.pollen-robotics.com/), now part of
[Hugging Face](https://huggingface.co/blog/hugging-face-pollen-robotics-acquisition) (acquired
April 2025). SDK: [pollen-robotics/reachy_mini](https://github.com/pollen-robotics/reachy_mini),
Apache License 2.0.

> Made with ❤️ by Pollen Robotics and Hugging Face.

`reachy/reachy.py` is an independent REST client this project wrote against the robot's onboard
daemon API; it is not part of Pollen Robotics' or Hugging Face's own SDK and is not published or
endorsed by them.

## Mac JetPack SD preparation

The Mac orchestration, card writer, USB console/first-boot and validation helpers, and agent skill are original
Apache-2.0 code adapted from this project's Jetson bring-up workflow. Python helpers
use only the standard library. No third-party source, OS image, NVIDIA binary, or
model weight is redistributed with this workflow.

Thanks to NVIDIA for Jetson Linux and its image-creation tools, and the QEMU, Ubuntu,
Python, OpenSSH, Zstandard, and Homebrew contributors for the host tooling:

| Downloaded or separately installed component | License / acknowledgement |
|---|---|
| NVIDIA JetPack / Jetson Linux BSP and rootfs | NVIDIA's accompanying Jetson software terms and individual component licenses apply. The downloaded `jetson-disk-image-creator.sh` is marked `LicenseRef-NvidiaProprietary`; `l4t_flash_prerequisites.sh` is BSD-3-Clause. The build makes one local performance edit to the image creator's `dd` invocation (4 MiB blocks, flush, progress), preserving its full NVIDIA copyright/license header. No NVIDIA script is vendored here. [Official downloads](https://developer.nvidia.com/embedded/jetpack/downloads). |
| QEMU | [GNU GPL version 2, with component-specific licenses](https://www.qemu.org/docs/master/about/license.html); QEMU is a trademark of Fabrice Bellard. |
| Ubuntu 22.04 cloud image | Canonical and the included package authors; [individual package licenses apply](https://ubuntu.com/legal/intellectual-property-policy). Guest package copyright files are under `/usr/share/doc/*/copyright`. |
| Python | [Python Software Foundation License and included component notices](https://docs.python.org/3/license.html). |
| OpenSSH | The Mac's separately supplied SSH client/key scanner and Ubuntu's SSH server; [OpenSSH's BSD-style and component license notices](https://github.com/openssh/openssh-portable/blob/master/LICENCE) apply. No OpenSSH source is bundled. |
| Zstandard | Meta Platforms, Inc. and affiliates; [BSD-3-Clause](https://github.com/facebook/zstd/blob/dev/LICENSE), alternatively GPL-2.0. |
| Homebrew | Homebrew contributors; [BSD-2-Clause](https://github.com/Homebrew/brew/blob/master/LICENSE.txt). Used to install tools; not bundled. |

Generated images retain the upstream packages and their licenses; the repository's
Apache-2.0 license does not relicense those images or downloaded tools.

## Development

Developed by Alex Sotelo ([@nv-asotelo](https://github.com/nv-asotelo)), with Claude Sonnet/Opus 5
(Anthropic) on the Cosmos3-Edge engine build and deployment, and OpenAI GPT-6 Astra on the Live
Vision web UI - fixes and iteration by both throughout.
