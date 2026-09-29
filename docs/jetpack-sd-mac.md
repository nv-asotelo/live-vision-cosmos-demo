# Optional JetPack SD preparation from a Mac

Keep a working **JetPack 7.2.1 / L4T 39.2.1** installation. This step is only for a
fresh card. After boot, `bootstrap.sh` installs missing CUDA 13.2 / TensorRT 10.16.2
components before the demo build; OS-only media is intentionally not a full compute SDK.

## Requirements and scope

- Apple Silicon MacBook, macOS **15+**, **16 GB RAM**, **60 GiB free** on the build
  cache volume, internet, Apple Command Line Tools (`xcode-select --install`),
  [Homebrew](https://docs.brew.sh/Installation), administrator access, and macOS
  disk-access permission for the terminal/app running the command. QEMU uses 8 GiB
  and four virtual CPUs. No laptop GPU or CUDA is required.
- Writable **64 GB+ microSD**, built-in SD reader or a USB reader that reports removable
  media. The selected card is erased. The tested nominal 64 GB card reports 62,883,102,720 bytes.
- **Orin Nano Super 8 GB developer kit P3767-0005**, FAB 300, board revision T.1,
  chip SKU D5, RAMCODE 2. This recipe is pinned to that hardware; it is not a generic Orin flasher.
- Compatible **R39.2.1 QSPI firmware already installed**. The Mac card writer cannot
  update the Jetson's QSPI. For an unprepared board or another module, follow
  [NVIDIA's setup instructions](https://docs.nvidia.com/jetson/orin-nano-devkit/user-guide/setup_bsp.html).
- USB-C **data** cable, the Orin's normal power supply, and **wired Ethernet to
  your router (recommended)** for internet. Wi-Fi is an alternative. Leave its
  monitor disconnected before booting for serial setup.

## One command: card to first boot

```bash
brew install python qemu zstd
diskutil list
./scripts/flash-jetpack-sd-mac.sh --disk /dev/diskN --erase
```

Replace `diskN` with the identified **whole SD disk**. `--erase` is explicit
authorization; run in Terminal and enter your Mac password at the `sudo` prompt.
Allow removable-volume access if macOS requests it. Use `--dry-run`
instead to build and validate without writing, or `--build-only` without `--disk`.
`--flash-only` stops after ejection; the default continues through first boot.

The script downloads hash-pinned NVIDIA BSP/rootfs and Ubuntu 22.04 amd64 media,
runs NVIDIA's SD image creator in a disposable QEMU VM, checks GPT/ext4 and the clean
rootfs, then writes the card, verifies the entire image by SHA-256, and ejects it.
The image contains no Cosmos3-Edge, Live Vision UI, model weights, precreated user,
or deployment SSH keys. The builder VM has no USB or host-disk passthrough.
This is a project integration of [NVIDIA's image-creation tools](https://docs.nvidia.com/jetson/archives/r39.2.1/DeveloperGuide/SD/FlashingSupport.html#flashing-to-an-sd-card), not an NVIDIA-supported Mac recovery-flash path.

The first build can take an hour or more. Downloads and validated output are cached
in `~/Library/Caches/live-vision-jetpack/7.2.1`; successful builds remove their VM.
Failed builds retain a stopped VM and logs for diagnosis. `--cache-dir` selects another
volume; `--image-dir` reuses a directory containing the generated `.img.zst` and `image.json`.
Only the final writer uses `sudo`, with an expanded image staged outside protected
Documents/Desktop. The Mac's temporary volume also needs 11 GiB free for that image.
If macOS reports `Operation not permitted` for `/dev/rdiskN` after authentication,
check **System Settings → Privacy & Security → Files and Folders** for your terminal's
removable-volume permission (Full Disk Access may be needed). Use normal Terminal
`sudo`: AppleScript's administrator helper does not inherit an app's disk permission.
Administrator authentication and disk access are separate permissions
([Apple](https://support.apple.com/guide/security/controlling-app-access-to-files-secddd1d86a6/web)).
Failed writes retain their staging directory and log; resolve the reported cause before retrying.

## First boot from the Mac

The same command continues after verified ejection:

1. Move the card to the **powered-off** Orin, connect USB-C data to the Mac and
   Ethernet to your router, then connect normal power. No recovery jumper.
2. The script finds the NVIDIA serial console. Press **Enter**, complete
   [NVIDIA's first-boot license/account prompts](https://docs.nvidia.com/jetson/archives/r39.2.1/DeveloperGuide/SD/FlashingSupport.html#headless-mode-flow-in-oem-config),
   then log in. There is **no default username/password**. USB resets reconnect
   to the same Jetson automatically; close other serial apps before starting.
   At **Network configuration → Primary network interface**, select
   **`enP8p1s0: Ethernet PCI`** and press **Enter** for the recommended wired setup;
   connect that Ethernet port to your router. Interface names can vary: choose
   the **Ethernet PCI** entry. For Wi-Fi instead, choose **Wireless ethernet**.
   The `usb0`/`usb1` Mac link supplies no internet.
3. At the Linux shell prompt, press **Ctrl-]**. The script checks `/` is
   `/dev/mmcblk0p1`, Ubuntu is 24.04, L4T is R39 revision 2.1, and both the root
   partition and filesystem use most of the card. It checks the flashed card's
   capacity and serial when available in the same run. An NVMe boot stops here.
4. Only after those checks, it enables SSH; enter your new **Jetson** password
   at the local prompts. It checks USB/LAN reachability, pins the host key learned
   over the physical serial link, and verifies the same SD boot through SSH.

`JETPACK_READY` and a separate `first-boot-receipt.json` mean all these checks passed.
The terminal prints your SSH command and host fingerprint. Passwords are never
logged or saved; the script does not accept license terms or create an account
on your behalf. It installs no demo, model, compute SDK, or persistent agent.

For an **already-flashed card**, continue without rebuilding or erasing:

```bash
./scripts/flash-jetpack-sd-mac.sh --first-boot-only
```

This resume mode needs only the Mac's Python 3.9+ and built-in SSH tools; it does
not require QEMU, Zstandard, an SD reader, or the build's RAM/disk capacity.
Use `--serial-port /dev/cu.usbmodemXXXX` if multiple Jetsons are connected, or
`--host <Jetson-LAN-IP>` to select an SSH address. **Ctrl-Q** stops the console.
After an interrupted setup or a required reboot, run `--first-boot-only` again.

**Existing static IP / failed DHCP:** a fresh card does not inherit network settings
from the old installation. If the fixed IP is a **router DHCP reservation**, keep
automatic configuration; check the Ethernet link/router DHCP service and retry if
autoconfiguration fails. If the IP was **manually configured on the Orin**, choose
**Configure network manually** after the failure message (or continue at the manual
IP prompt). Enter the assigned IP/CIDR, subnet mask, gateway, and DNS from your
network configuration. Use the actual subnet prefix; do not assume `/24`. The Mac's
mask/gateway/DNS are useful references only when it is on the same LAN; the Orin
needs its own assigned IP. See [manual network configuration](https://www.debian.org/releases/stable/arm64/ch06s03.en.html#di-netcfg).
To verify SSH specifically over the fixed LAN address, add `--host YOUR_ORIN_IP`
to the first-boot command. Keep personal network addresses out of committed files.

The [USB-network address](https://docs.nvidia.com/jetson/orin-nano-devkit/user-guide/hardware_layout.html#usb-ports)
is normally `192.168.55.1` after setup; the script also tries the Jetson's LAN
addresses. USB alone supplies neither Orin power nor internet access. Continue
with the [demo Quickstart](../README.md#quickstart-automated-setup) only when ready
to install the application.

## Why still use the Mac's SD reader?

USB-C provides the console/network after Linux starts. Its small **L4T-README**
virtual disk is documentation, **not the SD card**. Direct USB recovery flashing
for this kit requires an Ubuntu x86_64 host; the Mac builder VM does not implement
recovery USB passthrough. NVIDIA also offers ISO installation using a separate
USB flash drive and the Jetson boot menu. The verified SD-reader path is the
workflow here; see [NVIDIA's installation options](https://docs.nvidia.com/jetson/orin-nano-devkit/user-guide/setup_bsp.html).

**If SD needs selecting in the boot menu:** USB-C serial appears after Linux
starts, so it cannot control UEFI. Use a DisplayPort monitor and keyboard
(**Esc → Boot Manager → SD**), or a USB-to-TTL serial adapter on the debug header
from your Mac; see [NVIDIA's serial boot-menu instructions](https://docs.nvidia.com/jetson/orin-nano-devkit/user-guide/quick_start.html).

## Validation

**Validated 2026-09-29 on a fresh nominal 64 GB SD card**, using the supplied script
and [agent skill](../.agents/skills/flash-jetpack-sd-mac/SKILL.md) on an Apple Silicon
MacBook (macOS 26.7, 36 GiB RAM, built-in reader). The `--image-dir` route wrote and
read back all **10,181,672,960 image bytes**, matched SHA-256, and safely ejected the
card. See the [validation record](validation/jetpack-sd-mac-2026-09-29.json).

Image creation from fresh NVIDIA BSP/rootfs archives, GPT/ext4 checks, and the
clean-rootfs scan passed in the bring-up workflow. The new wrapper's fresh VM
bootstrap was tested separately; its complete cold build has not been rerun.
On the connected Orin, NVIDIA USB discovery and the serial **"Press ENTER to start
System Configuration"** prompt were observed. The continuation's automated tests
cover serial transport, device selection/reconnection, refusal of an NVMe boot,
unexpanded filesystems, SSH identity, and receipts only after success. Physical
SD root/expansion/SSH verification, compute installation, and Live Vision remain
pending; a first-boot prompt alone does not establish those results.

The NVIDIA archive hashes in `scripts/jetpack/release.json` pin the official-download
bytes used in this bring-up; they are not claimed as publisher-signed checksums.
Ubuntu's pinned hash matches its published SHA256SUMS. Upstream licenses and
acknowledgements are in [NOTICE.md](../NOTICE.md#mac-jetpack-sd-preparation).
