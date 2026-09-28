# Notices

This repository's own code (the `ui/`, `shim/`, `reachy/`, `systemd/` directories) is licensed
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
terms they differ meaningfully.)

Piper embeds [espeak-ng](https://github.com/espeak-ng/espeak-ng) (GPL-3.0) for phonemization.

**Voice model:** this repository does not ship a voice model file - the setup steps in
`README.md` download `en_US-libritts-high` at install time, MIT-licensed, trained from scratch on
the CC BY 4.0-licensed `train-clean-360` subset of LibriTTS
([source](http://www.openslr.org/60/), model card on
[Hugging Face](https://huggingface.co/rhasspy/piper-voices/blob/main/en/en_US/libritts/high/MODEL_CARD)).
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

## Development

Developed by Alex Sotelo ([@nv-asotelo](https://github.com/nv-asotelo)), with Claude Sonnet/Opus 5
(Anthropic) on the Cosmos3-Edge engine build and deployment, and OpenAI GPT-6 Astra on the Live
Vision web UI - fixes and iteration by both throughout.
