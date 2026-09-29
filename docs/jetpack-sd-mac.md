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

## Run on the Mac, then boot the Orin

```bash
brew install python qemu zstd
diskutil list
./scripts/flash-jetpack-sd-mac.sh --disk /dev/diskN --erase
```

Replace `diskN` with the identified **whole SD disk**. `--erase` is explicit
authorization; run in Terminal and enter your Mac password at the `sudo` prompt.
Allow removable-volume access if macOS requests it. Use `--dry-run`
instead to build and validate without writing, or `--build-only` without `--disk`.

The script downloads hash-pinned NVIDIA BSP/rootfs and Ubuntu 22.04 amd64 media,
runs NVIDIA's SD image creator in a disposable QEMU VM, checks GPT/ext4 and the clean
rootfs, then writes the card, verifies the entire image by SHA-256, and ejects it.
The image contains no Cosmos3-Edge, Live Vision UI, model weights, precreated user,
or deployment SSH keys. Nothing is passed through to the Jetson or its NVMe.
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

After ejection, move the card to the powered-off Orin. Complete first-boot setup
using a monitor and keyboard, or the Mac USB-serial procedure below.

## First boot from the Mac

There is **no default username or password**. Create your account through
[NVIDIA's headless first-boot setup](https://docs.nvidia.com/jetson/archives/r39.2.1/DeveloperGuide/SD/FlashingSupport.html#headless-mode-flow-in-oem-config):

1. Leave the Orin's monitor disconnected, insert the SD, connect its USB-C port to
   the Mac with a **data cable**, then connect its normal power supply. Boot normally,
   without a recovery jumper. Connect Ethernet to your router for internet access.
2. In **Mac Terminal**, find the new serial port and open it (replace `XXXX`):

   ```bash
   ls /dev/cu.usbmodem*
   screen /dev/cu.usbmodemXXXX 115200
   ```

   If no port appears, check the data cable, power, and whether Linux has booted.
3. Press **Enter**, complete the setup prompts, and choose your username/password.
   Reconnect the serial session if setup restarts USB, then log in.

Run **on the Jetson, inside the serial session**:

```bash
sudo systemctl enable --now ssh
findmnt -n -o SOURCE /
cat /etc/nv_tegra_release
df -h /
hostname -I
```

Expect `/dev/mmcblk0p1`, R39 revision 2.1, and a root filesystem expanded to use
most of the card. A root device such as `/dev/nvme0n1p1` means the
existing NVMe installation booted instead. Exit `screen` with **Ctrl-A**, then
**K**, then **Y**.

From a **new Mac Terminal window**, connect with the account you created:

```bash
ssh your-username@192.168.55.1
```

`192.168.55.1` is the Jetson's [USB-network address](https://docs.nvidia.com/jetson/orin-nano-devkit/user-guide/hardware_layout.html#usb-ports)
when that interface is active; otherwise use its Ethernet/Wi-Fi address from
`hostname -I`. The USB link alone does not provide internet access. Continue with
the [demo Quickstart](../README.md#quickstart-automated-setup).

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
SD boot, first-boot expansion, compute installation, and Live Vision on this card
remain untested. Flash verification does not establish those results.

The NVIDIA archive hashes in `scripts/jetpack/release.json` pin the official-download
bytes used in this bring-up; they are not claimed as publisher-signed checksums.
Ubuntu's pinned hash matches its published SHA256SUMS. Upstream licenses and
acknowledgements are in [NOTICE.md](../NOTICE.md#mac-jetpack-sd-preparation).
