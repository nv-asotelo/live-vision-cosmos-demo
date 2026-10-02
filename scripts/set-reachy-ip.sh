#!/usr/bin/env bash
# Point this demo at a Reachy Mini - or a different one - by its LAN address.
#
# Run ON THE ORIN (through bash, like setup-orin.sh, so it works however the file got there):
#   sudo bash /opt/live-vision-cosmos-demo/scripts/set-reachy-ip.sh 192.0.2.77
#   sudo bash /opt/live-vision-cosmos-demo/scripts/set-reachy-ip.sh reachy-mini.local
#   bash /opt/live-vision-cosmos-demo/scripts/set-reachy-ip.sh          # print the current address
# or from a laptop:
#   ssh -t user@orin sudo bash /opt/live-vision-cosmos-demo/scripts/set-reachy-ip.sh 192.0.2.77
#
# It first checks that a Reachy Mini daemon answers at the new address, and changes nothing if
# one doesn't - a typo shouldn't take down a working setup. --force skips that check (a robot
# that's switched off right now, say). Then it writes the address to reachy.env, the one file the
# UI (motors, apps, speech) and the camera/microphone bridge both read when they start, and
# restarts those two services. Takes seconds; inference keeps running throughout.
#
# On an Orin set up without a robot, or by a version of this repo that wrote the address into the
# systemd units themselves, it instead re-runs the Reachy stages of setup-orin.sh once (bridge
# venv - pip, so it needs internet - units, service enablement). That also restarts the
# inference shim, which takes about a minute to reload the model. Every later change takes the
# fast path above. An Orin set up by a version of this repo from before this script existed has
# no copy of it: refresh the repo there first, from a laptop checkout -
#   git archive --format=tar HEAD | ssh user@orin "tar -x -C /opt/live-vision-cosmos-demo"
set -euo pipefail

INSTALL_DIR=/opt/live-vision-cosmos-demo
# shellcheck source=reachy-address.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/reachy-address.sh"

BRIDGE_UNIT=/etc/systemd/system/reachy-mjpeg-bridge.service
UI_UNIT=/etc/systemd/system/live-vision-cosmos-demo-ui.service

die() { printf 'set-reachy-ip: %s\n' "$*" >&2; exit 1; }
usage() {
  echo "usage: sudo bash $0 [--force] <robot-ip-or-hostname>   (no argument: print the current address)"
}

force=0 address=""
for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; die "unknown option: $arg" ;;
    *) [[ -z "$address" ]] || die "one address only"; address="$arg" ;;
  esac
done

if [[ -z "$address" ]]; then
  current="$(reachy_address_configured)"
  if [[ -z "$current" && -f "$BRIDGE_UNIT" ]]; then
    # Units from before reachy.env existed carry the address in ExecStart.
    current="$(sed -n 's/.*--robot-host \([^ ]*\).*/\1/p' "$BRIDGE_UNIT")"
  fi
  echo "${current:-none - no Reachy Mini is configured on this Orin}"
  exit 0
fi

reachy_address_valid "$address" \
  || die "'$address' is not an IPv4 address or a hostname - give just the address, e.g. 192.0.2.77 or reachy-mini.local"
[[ "$EUID" -eq 0 ]] || die "run with sudo: it rewrites $REACHY_ENV_FILE and restarts services"

if [[ "$force" -eq 0 ]]; then
  curl -fsS --max-time 5 "http://$address:8000/api/daemon/status" >/dev/null 2>&1 \
    || die "no Reachy Mini daemon answered at http://$address:8000 - nothing changed. Check the address and that the robot is on, or pass --force to set it anyway."
fi

if grep -qs 'EnvironmentFile=.*reachy\.env' "$BRIDGE_UNIT" && grep -qs -- '--reachy-daemon-url' "$UI_UNIT"; then
  reachy_address_write "$address"
  systemctl restart reachy-mjpeg-bridge live-vision-cosmos-demo-ui
  echo "Reachy Mini set to $address; restarted the camera/mic bridge and the UI."
else
  # No robot at setup time (no bridge unit, no robot flags in the UI unit), or units that bake the
  # address into ExecStart, where rewriting reachy.env alone would change nothing. Either way the
  # units need rendering once - by setup-orin.sh's own stages, not a second copy of them here.
  reachy_address_write "$address"
  rm -f "$INSTALL_DIR/.setup-state/"{setup_reachy_env,install_systemd_units,enable_services}
  echo "First Reachy setup on this Orin: re-running its Reachy stages of setup-orin.sh (restarts inference, about a minute)."
  SERVICE_USER="$(stat -c %U "$INSTALL_DIR")" REACHY_MINI_IP="$address" bash "$INSTALL_DIR/scripts/setup-orin.sh"
  echo "Reachy Mini set to $address."
fi

# The bridge reconnects in the background; report whether it has, without failing either way.
for _ in $(seq 1 15); do
  # Top-level "live" only - grepping would also match the nested audio.live.
  if curl -fsS --max-time 2 http://127.0.0.1:8099/healthz 2>/dev/null \
      | python3 -c 'import json, sys; sys.exit(0 if json.load(sys.stdin).get("live") else 1)' 2>/dev/null; then
    echo "Camera/mic bridge is live on the new robot."
    exit 0
  fi
  sleep 2
done
echo "Camera/mic bridge has not gone live yet (it keeps retrying) - check: journalctl -u reachy-mjpeg-bridge -n 50"
