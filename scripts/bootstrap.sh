#!/usr/bin/env bash
# Laptop-side bootstrap: copies this repo to a Jetson Orin over SSH and runs the Orin-side
# build (scripts/setup-orin.sh) there. Runs entirely on the laptop's CPU - no GPU, no
# particular OS, and no local Python/CUDA/build toolchain are needed here. Everything that
# needs a GPU or a big download happens on the Orin, over SSH.
#
# Requires only: bash, ssh, scp, tar (all present by default on macOS, Linux, and Windows
# via WSL or Git Bash/OpenSSH).
#
# Usage:
#   export HF_TOKEN=hf_...                  # required - see README "Hugging Face access"
#   export REACHY_MINI_IP=192.168.1.50      # optional - omit if you have no Reachy Mini
#   ./scripts/bootstrap.sh jetson@192.168.1.100
#
# The Orin needs JetPack already flashed and booting, SSH reachable, and an account with
# sudo. Everything else - cloning TensorRT-Edge-LLM, downloading and quantizing the
# checkpoint, building the engine, installing Piper/systemd - happens on the Orin itself.
set -euo pipefail

TARGET="${1:-}"
INSTALL_DIR="${INSTALL_DIR:-/opt/live-vision-cosmos-demo}"
SETUP_ORIN_USER="${SETUP_ORIN_USER:-}"   # defaults to the ssh login user, remote-side

if [[ -z "$TARGET" ]]; then
  cat >&2 <<'USAGE'
Usage: HF_TOKEN=hf_... ./scripts/bootstrap.sh user@orin-host-or-ip

Required env var:
  HF_TOKEN         Hugging Face access token that has accepted nvidia/Cosmos3-Edge's
                    license at https://huggingface.co/nvidia/Cosmos3-Edge (create a
                    read token at https://huggingface.co/settings/tokens).

Optional env vars:
  REACHY_MINI_IP    IP of a Reachy Mini robot on the same LAN. Omit for camera+captioning
                    only, with no robot-control panels.
  INSTALL_DIR       Where the demo lives on the Orin. Default: /opt/live-vision-cosmos-demo
  SETUP_ORIN_USER   Account setup-orin.sh should own the install and run services as.
                    Default: whichever account you SSH in as.
USAGE
  exit 2
fi

command -v ssh >/dev/null || { echo "ssh not found on this laptop - install an OpenSSH client." >&2; exit 2; }
command -v scp >/dev/null || { echo "scp not found on this laptop - install an OpenSSH client." >&2; exit 2; }
[[ -n "${HF_TOKEN:-}" ]] || { echo "HF_TOKEN is not set - see usage (run with no arguments) for what it's for." >&2; exit 2; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$REPO_ROOT/scripts/setup-orin.sh" ]] || { echo "internal error: $REPO_ROOT doesn't look like this repo (scripts/setup-orin.sh missing)." >&2; exit 2; }

echo "==> checking SSH reachability and target architecture: $TARGET"
REMOTE_UNAME="$(ssh -o ConnectTimeout=10 "$TARGET" 'uname -sm')" \
  || { echo "could not SSH to $TARGET - check the host/IP, that the Orin is powered on and on the network, and your credentials." >&2; exit 1; }
[[ "$REMOTE_UNAME" == "Linux aarch64" ]] \
  || { echo "$TARGET reports '$REMOTE_UNAME' - this needs to be run against the Jetson Orin (Linux aarch64), not a laptop or a different device." >&2; exit 1; }
echo "    ok: $REMOTE_UNAME"

echo "==> copying this repo to $TARGET:$INSTALL_DIR"
ssh "$TARGET" "sudo mkdir -p '$INSTALL_DIR' && sudo chown \$(whoami) '$INSTALL_DIR'"
if git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
  # Ships the last commit, not uncommitted local edits - use the tar fallback below (or
  # commit first) if you're iterating on scripts/ and want those changes deployed.
  git -C "$REPO_ROOT" archive --format=tar HEAD | ssh "$TARGET" "tar -x -C '$INSTALL_DIR'"
else
  tar --exclude=.git -cf - -C "$REPO_ROOT" . | ssh "$TARGET" "tar -x -C '$INSTALL_DIR'"
fi

echo "==> running scripts/setup-orin.sh on $TARGET (this takes a while - checkpoint download plus an on-device compiler build; expect well over an hour on an Orin Nano)"
REMOTE_USER="${SETUP_ORIN_USER:-$(ssh "$TARGET" whoami)}"
# HF_TOKEN travels over the SSH session's stdin-adjacent env passthrough, not argv, so it
# never appears in this shell's history or a `ps` listing on either end.
ssh -t "$TARGET" "sudo -E env HF_TOKEN='$HF_TOKEN' REACHY_MINI_IP='${REACHY_MINI_IP:-}' SERVICE_USER='$REMOTE_USER' bash '$INSTALL_DIR/scripts/setup-orin.sh'"

echo "==> done. See the URL setup-orin.sh printed above, or open https://$TARGET:8443/ using the Orin's actual IP (not the SSH hostname, if those differ)."
