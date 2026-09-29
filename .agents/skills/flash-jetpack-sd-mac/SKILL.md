---
name: flash-jetpack-sd-mac
description: Flash a clean JetPack 7.2.1 SD card from an Apple Silicon Mac, then guide USB first boot and verify SSH on an Orin Nano Super before Live Vision demo setup. Also use to resume an already-flashed card with --first-boot-only.
---

Read [the Mac workflow](../../../docs/jetpack-sd-mac.md) for host requirements,
the supported module/revision, QSPI prerequisite, and current validation scope.
Commands below run at this repository's root.

Keep an existing booting JetPack 7.2.1 / L4T 39.2.1 installation unless the user asks
to replace it. Missing CUDA or TensorRT is handled by demo setup. Flashing the SD
must not install Cosmos3-Edge, Live Vision UI, model weights, users, or SSH keys.

1. Check the Mac requirements and `diskutil list` / `diskutil info /dev/diskN`.
   Identify the user's intended whole SD card by reader, capacity, and serial when
   available. A built-in reader can report **Internal: Yes**; its protocol is
   **Secure Digital**. Never infer the target from the highest disk number.
2. For an already-flashed card, skip disk selection/build/write and run
   `./scripts/flash-jetpack-sd-mac.sh --first-boot-only` in Mac Terminal.
   Otherwise use `--disk /dev/diskN --dry-run` to build/cache and validate without
   writing when a preflight is needed. The first build can take an hour or more;
   its isolated Ubuntu VM has no Jetson USB or host-disk passthrough.
   New images expand the SD before NVIDIA setup. The builder invalidates older
   cached images; never fabricate the manifest flag to make an old image pass.
3. If flashing this identified card is already authorized, run
   `./scripts/flash-jetpack-sd-mac.sh --disk /dev/diskN --erase`. It validates before
   writing and continues into first boot. Otherwise explain the selected card and
   obtain authorization before erasing. Run in Terminal and let the user authenticate with `sudo`;
   never collect their password in chat. Keep the card inserted through readback.
   For an agent without an interactive terminal, prepare the exact authorized command
   for the user to run in Terminal. Do not use AppleScript administrator elevation:
   its helper does not inherit the app's disk permission.
4. A successful run writes `flash-receipt.json` under the reported image directory
   and ejects the card. Confirm its status and SHA-256. On any error, inspect the
   reported log and resolve the cause; do not retry a write automatically.
   If macOS denies `/dev/rdiskN` despite administrator authentication, follow the
   workflow's disk-access guidance and wait for the user to grant that permission.
   Do not change privacy settings yourself. Staged files and logs are retained on
   failure; the helper stages outside Documents to avoid privacy-folder failures.
5. The same Terminal session waits for the user to move the card to the powered-off
   Orin and connect USB-C data, Ethernet, and normal power (no monitor/recovery jumper).
   It discovers NVIDIA serial and reconnects to that Jetson after USB restarts.
   Keep one setup window active; resume that window instead of opening duplicates.
   Have the user complete NVIDIA license/account prompts locally, log in, and press
   **Ctrl-]** at the Linux shell. Never enter/collect passwords or accept licenses
   for them. There are no default credentials.
   Recommend wired Ethernet to the router: choose **`enP8p1s0: Ethernet PCI`** in
   network setup (the interface name may vary), not the USB network entries.
   A fresh card loses the old OS's static network profile. Distinguish a router DHCP
   reservation (use automatic configuration) from a manually assigned Orin address
   (use the manual IP/mask/gateway/DNS prompts after failed DHCP). Do not assume
   `/24`; Mac settings apply only on the same LAN. Never commit personal addresses.
6. The script verifies SD root, L4T 39.2.1, filesystem expansion, and card identity
   when available before enabling SSH; an NVMe boot is a stop, not permission to
   modify NVMe. It then verifies SSH against the public host key obtained over USB.
   An older image with a small/full root is repaired in place after SD identity and
   partition-layout checks. Let the user authenticate locally; the script grows
   only the SD APP partition/filesystem and reboots. After reconnecting, have the
   user log in again and press **Ctrl-]**. Do not reflash or remove partition guards.
   Require `JETPACK_READY` and `first-boot-receipt.json` before claiming verified
   first boot. Keep flash/readback, Linux setup prompt, SD root/expansion, and demo
   validation distinct. Failure can resume with `--first-boot-only`; never reflash
   to retry account/network setup. `--flash-only` deliberately stops after ejection.

USB-C does not expose the SD as a Mac disk. Never write to the small L4T-README
virtual disk. Direct recovery flashing needs an Ubuntu x86_64 host and is outside
this script. Native USB-C serial starts after Linux and cannot control UEFI; for
SD boot-menu selection use a display/keyboard or the documented USB-to-TTL header
console. See [the workflow](../../../docs/jetpack-sd-mac.md#why-still-use-the-macs-sd-reader).

Return to [AGENTS.md](../../../AGENTS.md) for demo setup, which installs the
missing compute components and then the application. This skill does not update
QSPI or touch the Jetson's NVMe. For other boards or firmware, use NVIDIA's
documented flashing path rather than changing the pinned board values by guesswork.
