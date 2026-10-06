# First-boot setup and recovery

Use this guide after preparing the [JetPack SD card](jetpack-sd-mac.md), before
running the demo installer. A verified card write, a USB console, a login prompt,
and a working user account are separate checkpoints.

## Start with the right board

1. Power off the intended Orin before inserting its SD card. Leave **FC REC
   unjumpered** for normal boot.
2. Connect its barrel-jack power supply, Ethernet, and a USB-C **data** cable to
   the Mac. USB-C is not the board's power input.
3. Observe the USB device and serial port that appear when this board is connected.
   Do not reuse an old Orin's IP address, hostname, credentials, or SSH host key.
4. Open the identified USB serial console at 115200 baud. With no display connected,
   the pinned image can present the first-time setup wizard there after Linux boots.
   Press Enter once when the console asks you to start setup.

The Mac can collect a read-only USB/serial inventory from this repository:

```bash
python3 scripts/jetpack/first_boot.py probe --json
```

This probe does not log into a Jetson or scan the network. Compare observations
before and after reconnecting the intended board. USB discovery alone does not
identify the boot disk or establish which account exists.

## If setup does not proceed

| What you see | What to do next | What it does not prove |
| --- | --- | --- |
| No USB device or serial port | Confirm barrel-jack power, then reconnect the data cable once and repeat the USB probe. Check for a data-capable cable or another direct Mac port. | No USB enumeration alone does not establish incompatible firmware or a failed SD image. |
| A USB device but no serial console | Record the observed device identity and boot state. Wait for Linux to start and probe again. Check whether another terminal already owns the newly appearing serial port. | A USB device is not necessarily a Linux login console. Do not change boot mode based on a guessed device type. |
| First-time setup appears | Complete the wizard in the terminal. Record the chosen username; type the password directly into its password fields. | The account is not verified until a fresh login succeeds. |
| Wireless setup appears while Ethernet is connected | Follow the wizard's displayed options. If leaving that screen appears stuck, inspect the console before making another change. | Canceling a network screen is not evidence that account creation finished or failed. |
| A screen looks frozen or arrow-key escape sequences are printed | Stop sending navigation keys. Capture the current prompt, check whether the serial session is still connected, and reopen that same console if necessary. | A stale terminal display is not proof that the board hung. Reconnecting the console does not complete the wizard. |
| `login:` appears after a setup interruption | Try the exact account you created once. A successful shell prompt is the next checkpoint. | A login prompt does not prove setup saved a usable account or password. |
| `Login incorrect` for the account you created | Stop retrying. Check the exact selected username and whether account creation was completed. If that remains uncertain, use the offline audit below. | Do not infer a default username/password, invent an account, or conclude the password was changed. |
| An old Orin answers at a familiar address | Stop. Return to the intended board's USB identity and obtain its address from its verified local console. | A responding service or familiar hostname is not permission to access another board. |
| The console works but SSH does not | First verify login, the active root filesystem, and the new board's network address from its local shell. Then inspect SSH on that board. | A fresh OS may need account or network setup; this alone does not call for reflashing. |
| No progress after these bounded checks | Preserve observations and identify the remaining uncertainty. Inspect the card offline or use NVIDIA's documented preboot console/firmware path as appropriate. | Do not enter recovery mode, reflash, or alter QSPI solely because USB was initially absent. |

**Do not assume Cancel or Ctrl-C safely completes first-time setup.** A visible
login prompt after either action still requires account validation. Do not issue
blind keystrokes, repeatedly submit credentials, or reset passwords on a reachable
board whose identity has not been established.

## Audit the SD card before repairing it

Use this route when account setup cannot be validated and no authorized local
administrator session is available.

1. Shut down or disconnect power from the **intended new board**, then return its
   SD card to the Mac. Leave any existing working Orin untouched.
2. Re-identify the whole card using its reader, capacity, and serial when available.
   Compare against the flash receipt or locally saved identity. A disk number can
   change after reinsertion. If the identity differs or is ambiguous, stop before
   any write.
3. Inspect a read-only copy or a read-only mount in an isolated Linux repair
   environment. Avoid filesystem journal replay during diagnosis. Keep account
   databases and logs local: they can contain credentials, hashes, device details,
   and personal information. If the filesystem has a pending journal, a
   journal-free inspection is provisional: confirm findings after replaying the
   journal into a disposable copy or copy-on-write overlay whose backing card
   remains read-only. Never replay it onto the physical card just to inspect it.
4. In the Linux repair VM, run the audit against that read-only mounted root, using
   the username chosen during setup. `sudo` permits reading the protected account
   database; it does not make the mount writable:

   ```bash
   sudo python3 scripts/jetpack/first_boot.py audit-root \
     --root /path/to/read-only-mounted-root --user chosen-user --json
   ```

5. Review whether the account exists, whether its authentication record is usable,
   and what setup state was saved. Account presence or an unlocked password record
   does **not** verify that the entered password matches. Missing or unreadable
   evidence must remain unknown. In particular, a permission-denied shadow read
   does not establish that the account or password is missing.
6. Choose a repair only after the evidence identifies the failure. Before modifying
   the card, preserve a recoverable copy and recheck its identity. Limit a repair
   to the diagnosed account/setup problem; do not overwrite the installation with
   the original clean image just to retry login. If no account was saved and the
   first-time setup target remains enabled, resume that setup on normal boot before
   considering an offline account change.

The audit is diagnostic. It does not reset a password, create an account, mount or
unmount a disk, update firmware, or make the root filesystem writable. Password
changes, if a diagnosis calls for one, belong in an interactive local prompt rather
than chat, shell history, a source file, or a committed report. Do not post raw
`/etc/shadow`, password hashes, private keys, or complete device logs.

After an authorized repair, check the affected files/filesystem, finish any writes,
unmount, and eject safely. Tell the user the card is safe to remove only after
ejection succeeds. Verify a **fresh login on the board** before claiming the account
is repaired.

## Before installing Live Vision

From the new board's authenticated shell, collect:

```bash
whoami
findmnt -n -o SOURCE /
cat /etc/nv_tegra_release
df -h /
ip -brief address
```

Confirm the intended user, SD root on `mmcblk0p1`, expected L4T release, expanded
filesystem, and an address belonging to this board. Record its SSH host-key
fingerprint through the identified console before accepting it from the Mac.
Only then return to [the demo Quickstart](../README.md#quickstart-automated-setup).
Keep network and device identifiers in local deployment notes, not public source.

## If the demo installer stops

Read the reported stage and error before rerunning setup. Resume only on the same
verified board; never redirect bootstrap to another existing Orin to work around
a failure. Completed current-SDK stages can be reused, but stage markers are not
substitutes for their artifacts.

| Failure or state | Safe next step |
| --- | --- |
| Insufficient storage on a fresh, partial, or stale-SDK installation | Setup requires **25 GiB free**. Check the root device, filesystem expansion and available space. Free identified unrelated files or use larger storage; do not manufacture stage markers to obtain the lower threshold. |
| Maintenance of an already completed installation | The **8 GiB** threshold applies only when the heavy stages have current-SDK markers and the checked native runtime, ONNX exports, engines and Jinja template are present and nonempty. A partial resume still requires 25 GiB. |
| Build-swap creation, activation or verification fails | Engine construction requires the equivalent of a **4 GiB active swapfile** (allowing the swap header page). Inspect `df -h`, `free -h` and `swapon --show --bytes`; fix the reported cause before resuming. The installer stops before the engine build if it cannot verify this swap. |
| An old, unfamiliar or replaced `data/build-swap.img` exists | Inspect its identity and active-swap status. Existing files are not reformatted or deleted by this run. Already-active sufficient swap is preserved; if the run activates an existing inactive file, cleanup may deactivate it but preserves the file. A replaced path is left untouched. |
| A build fails normally, or receives an interrupt/termination signal | Cleanup removes only the unchanged swapfile created by that invocation, after verifying it is inactive. If inference was paused, it remains stopped because an engine may have been partially rewritten. Fix the error, rerun setup to finish the build, then verify real model output before serving. |
| `swapoff` or cleanup fails | Preserve the file and inspect available RAM and active swap. Never delete an active swapfile. Setup does not proceed to service startup after its post-build cleanup fails. |
| Power is lost or the process is killed with `SIGKILL` | Cleanup cannot run. Inspect the remaining swapfile, filesystem and partial build before resuming; do not blindly remove a file just because its name looks temporary. |

These guards manage temporary **build** resources. They do not authorize removing
unknown files, stopping unrelated workloads, changing another board, or claiming
that a completed build produces correct captions. Follow the
[application validation checks](../AGENTS.md#verifying-success) after recovery.

## Agent decision tree

```text
Identify the intended board and preserve any existing deployment.
  No USB evidence -> power/data-cable check -> reconnect once -> probe again.
    Still absent -> report evidence; diagnose boot/firmware without guessing.
  USB serial present -> identify/open that console -> inspect the actual prompt.
    Setup wizard -> user completes visible steps; do not send blind cancellation.
    Login prompt -> ask the selected username; prefer user-entered credentials.
      Explicitly supplied credentials -> at most one controlled login attempt.
      Rejected -> stop guessing; preserve evidence -> offline read-only card audit.
      Accepted -> verify user, SD root, release, capacity and board network identity.
        All verified -> bootstrap this board only.
  Repair needed -> establish cause, target identity and recoverable backup first.
    Repair complete -> eject -> require fresh on-board login before declaring success.
  Installer failed -> record stage/error -> inspect storage, swap and partial artifacts.
    Preserve unknown resources; keep paused inference stopped until build completes.
    Resume on the same verified board -> validate actual model output before serving.
```

Do not probe historical IP addresses to find the new board, remove an existing
board's SSH key to suppress a mismatch, or use the existing demo as a repair target.
Do not report an attempted action as successful without its resulting checkpoint.

## What has been observed

During this branch's first-boot trial, USB enumeration was initially absent. After
the data cable was reinserted, a Linux USB console and the first-time setup wizard
appeared. Later, leaving wireless setup was followed by a login prompt; a controlled
login attempt with the reported account was rejected.

The returned SD was identified and inspected read-only. It contained **no saved
regular user account**, and `default.target` still pointed to `nv-oobe.target`:
first-time setup remained enabled. The card had L4T 39.2.1 and an approximately
8 GiB root partition that had not expanded. Because its filesystem had a pending
journal, these findings were confirmed after journal replay in a disposable
copy-on-write overlay backed by the read-only card. The physical SD was unchanged.

OEM setup logs recorded four input/output errors while discovering the terminal
(`os.ttyname(0)`). This establishes a setup failure and explains why a login prompt
was not proof of a saved account. **The cause of the terminal errors remains
unknown**; the evidence does not establish a cable fault, a cancellation bug,
incompatible firmware, or a changed password.

The next step is to detach inspection mounts, eject safely, then boot the card
normally with a stable USB data connection. Complete the enabled setup wizard and
verify a fresh login, root device and filesystem expansion. No offline password
reset or reflash is needed for this diagnosed state.

For preboot access and firmware requirements, use NVIDIA's
[Orin Nano setup guide](https://docs.nvidia.com/jetson/orin-nano-devkit/user-guide/latest/quick_start.html)
and [USB interface documentation](https://docs.nvidia.com/jetson/orin-nano-devkit/user-guide/latest/hardware_layout.html).
Linux USB gadget serial is not a preboot UEFI or ISO-installer console.
