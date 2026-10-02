#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build clean JetPack SD media on a Mac; see docs/jetpack-sd-mac.md.
set -euo pipefail
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/jetpack/mac.py" "$@"
