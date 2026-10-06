# Change Wi-Fi after the demo works

**Draft procedure; not yet validated on the trial hardware.** Command syntax was
checked against the official references below. Record hardware results separately;
do not treat these instructions as evidence that a network switch succeeded.

Start only after wired setup, a fresh login, adequate SD space, and **a real image
request producing a coherent caption** have passed. A ready endpoint alone is not
enough. Keep Ethernet connected and an authenticated USB serial console open on
the identified board. Use the console for changes so losing an SSH route does not
lose control. Leave other Orins untouched.

The final state for this procedure is **Ethernet active and preferred, with the
tested Wi-Fi profile saved but disconnected**. Network names, addresses, UUIDs and
test output belong in private deployment notes, not source control.

## 1. Identify interfaces and profiles

Run on the verified Orin, through its USB console:

```bash
hostname
whoami
findmnt -n -o SOURCE /
nmcli --version
systemctl is-active NetworkManager
nmcli -f DEVICE,TYPE,STATE,CONNECTION device status
nmcli -f NAME,UUID,TYPE,DEVICE connection show
ip -brief address
ip -4 route show default
ip -6 route show default
```

Confirm the board using the previously recorded USB/SSH identity, not its hostname
alone. Select the actual wired Ethernet and Wi-Fi devices; exclude USB networking,
bridges and VPNs. If NetworkManager does not manage them, stop and inspect the
installed networking configuration instead of starting a second network manager.

Replace every placeholder before using the remaining commands:

```bash
ETH_IFACE='<observed-wired-interface>'
ETH_UUID='<active-wired-profile-uuid>'
WIFI_IFACE='<observed-wifi-interface>'
TEST_HTTPS_URL='<reachable-public-HTTPS-URL>'
```

Record the selected profiles' current autoconnect and IPv4/IPv6 route settings
locally before changing them. Profile UUIDs avoid ambiguities from duplicate names.
Never use `--show-secrets`, `wifi show-password`, or copy NetworkManager keyfiles
into reports. [NetworkManager profile selection and activation](https://networkmanager.dev/docs/api/latest/nmcli.html#connection).

## 2. Join Wi-Fi without unplugging Ethernet

For a human, run `sudo nmtui`, choose **Activate a connection**, and select the
intended wireless network. Enter credentials directly in the terminal, without
displaying them or recording that interaction. Keep the wired connection active.
Then continue with the interface checks below.
[NetworkManager's text interface](https://networkmanager.dev/docs/api/latest/nmtui.html).

For a command-line session, inspect available networks on the selected device:

```bash
nmcli radio wifi
nmcli device wifi list ifname "$WIFI_IFACE"
```

If Wi-Fi is disabled, establish why before enabling it. Use an existing matching
profile by its observed UUID, if available:

```bash
WIFI_UUID='<selected-existing-wifi-profile-uuid>'
sudo nmcli --ask connection up uuid "$WIFI_UUID" ifname "$WIFI_IFACE"
```

Otherwise, for an ordinary DHCP network supported by the simple Wi-Fi connection
command, let the human enter the password at the prompt:

```bash
sudo nmcli --ask device wifi connect '<chosen-SSID>' ifname "$WIFI_IFACE"
nmcli -f NAME,UUID,TYPE,DEVICE connection show --active
WIFI_UUID='<uuid-of-the-activated-wifi-profile>'
```

Do not put a password in command arguments, environment variables, history, chat
or scripts. An agent can prepare the command, then leave the secret prompt to the
human in Terminal. For enterprise/802.1X networking, use the required approved
profile and certificates; the simple connection command does not configure those.
[Official connection examples](https://networkmanager.dev/docs/api/latest/nmcli-examples.html).

## 3. Test the Wi-Fi path explicitly

Keep Ethernet connected during this first test:

```bash
nmcli -f GENERAL,IP4,IP6 device show "$WIFI_IFACE"
ip -4 route show dev "$WIFI_IFACE"
ip -6 route show dev "$WIFI_IFACE"
curl --interface "$WIFI_IFACE" --connect-timeout 10 --max-time 20 \
  --fail --silent --show-error --output /dev/null "$TEST_HTTPS_URL"
```

Confirm that Wi-Fi has a usable address and routes. The curl request binds its
connection to that interface; an ordinary successful request could still use
Ethernet. Name resolution can still use the system resolver, so this is not yet
proof of a complete Wi-Fi-only setup. Do not add insecure TLS flags to make an
unexplained failure pass. If interface binding needs privileges on the installed
system, repeat that specific check with `sudo` after inspecting the error.
[curl interface selection](https://curl.se/docs/manpage.html#--interface).

From the client, open the UI at the newly observed Wi-Fi address and verify it is
the same board. Check its known SSH fingerprint before accepting SSH at a new
address. Submit a real image and read its caption. Keep browser/network timing
separate from server inference timing when recording results.

## 4. Validate a brief Wi-Fi-only handover

Use the USB console, with no active installer/download. Confirm that the installed
`nmcli device help` includes `checkpoint` before using this command:

```bash
sudo nmcli device checkpoint --timeout 90 "$ETH_IFACE" "$WIFI_IFACE" -- \
  nmcli device disconnect "$ETH_IFACE"
```

The checkpoint asks for confirmation after the disconnect. While it waits, test
the UI and one real inference from the client over the observed Wi-Fi address.
If the test fails, leave the change unconfirmed so the checkpoint restores the
previous state. If it works, confirm in the USB console, then inspect the default
routes and repeat the HTTPS test without Ethernet. Ensure the tested traffic has
no alternative VPN or USB upstream route before calling it Wi-Fi-only.
[NetworkManager checkpoints](https://networkmanager.dev/docs/api/latest/nmcli.html#device).

Do not perform this handover from the only available SSH session. If checkpoint
support or the USB console is unavailable, keep Ethernet active and report the
handover as untested. Inspect one failure before trying again; do not cycle
profiles or reset the networking stack blindly.

## 5. Restore Ethernet as the final connection

Use the USB console to reactivate the exact saved wired profile:

```bash
sudo nmcli connection up uuid "$ETH_UUID" ifname "$ETH_IFACE"
nmcli -f GENERAL,IP4,IP6 device show "$ETH_IFACE"
curl --interface "$ETH_IFACE" --connect-timeout 10 --max-time 20 \
  --fail --silent --show-error --output /dev/null "$TEST_HTTPS_URL"
```

After Ethernet passes, keep the selected Wi-Fi profile saved for manual use and
disconnect that Wi-Fi device:

```bash
sudo nmcli connection modify uuid "$WIFI_UUID" connection.autoconnect no
sudo nmcli device disconnect "$WIFI_IFACE"
nmcli -f NAME,UUID,TYPE,DEVICE connection show
nmcli -f DEVICE,TYPE,STATE,CONNECTION device status
ip -4 route show default
ip -6 route show default
```

Confirm Ethernet owns the applicable default routes, Wi-Fi is disconnected, and
its profile still exists. Setting this profile's `connection.autoconnect` to `no`
is intentional: future use requires explicit activation. Other saved profiles or
VPNs need separate review; do not change them silently or claim reboot persistence
without testing it. Autoconnect priority chooses profiles, while route metrics
govern route preference; changing one does not replace checking the other.
[Connection autoconnect settings](https://networkmanager.dev/docs/api/latest/settings-connection.html),
[IPv4 route metrics](https://networkmanager.dev/docs/api/latest/settings-ipv4.html).

Reopen the UI at the verified Ethernet address and check another real caption.
To use the saved Wi-Fi later, explicitly activate its UUID with the `--ask`
command above, then repeat the connectivity checks before changing Ethernet.

## Agent completion record

Record each checkpoint as **observed**, **failed**, or **not tested**:

- Correct board, authenticated console, and real wired inference baseline.
- Selected Wi-Fi profile/device, address and routes; no secrets captured.
- Interface-bound connectivity and real caption over the Wi-Fi address.
- Optional Wi-Fi-only handover, rollback behavior, and any routing limitations.
- Ethernet restored, final real caption, Wi-Fi profile saved and disconnected.

This draft supplies a procedure only. Hardware results are pending; a completed
command or an active NetworkManager profile alone does not establish all checks.
