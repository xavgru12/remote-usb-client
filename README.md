# remote-usb-client

Windows USB/IP client setup for using USB devices that are shared by a Linux
USB/IP server. This repo contains the scripts that **auto-discover and attach**
the devices, keep them attached automatically (on boot and after network
drops), and install everything as a Windows service.

## Architecture

Two complementary layers keep devices attached:

1. **Keepalive service** (`usbip-bindall`, NSSM) — the *primary* layer. Every
   30 s it asks the server which devices it exports, attaches anything missing,
   and reconciles the set. This is what makes a newly plugged-in device "just
   appear" on the client with no manual step.
2. **Driver persistent devices** (usbip-win2 "stash") — the *fast* layer. The
   driver re-attaches the stashed set every time it loads, and reconnects (with
   exponential backoff) when a device drops. The service keeps this list in
   sync automatically, so it never goes stale.

### Why auto-discovery instead of hardcoded bus-IDs

USB/IP **bus-IDs are not stable**. A device exported as `1-10.2` can become
`1-4.4` after being re-plugged or after the server's USB tree changes (e.g. a
hub is moved). Hardcoding bus-IDs caused devices to be attached to the *wrong*
device after a re-plug — for example an FTDI chip's old ID `1-10.1` silently
grabbed a different device that had taken over that slot.

The service therefore re-discovers the exportable list on every cycle and
reconciles against what is currently attached, keyed by **VID:PID** (stable)
rather than bus-ID (unstable).

## Topology

| | |
|---|---|
| Server | `xaver-ThinkCentre-M720t` (Ubuntu Linux, USB/IP server) |
| Server address | resolves via mDNS to `192.168.10.82`, port `3240` |
| Client | Windows 10 x64 (this machine) |
| Client software | [usbip-win2](https://github.com/vadimgrn/usbip-win2) v0.9.7.3, `C:\Program Files\usbip\usbip.exe` |
| Keepalive service | `usbip-bindall` (NSSM, Automatic start) |

## Current devices (snapshot)

> Bus-IDs change on re-plug; this is the state at the time of writing, not a
> fixed mapping.

| Bus-ID | Device | VID:PID | COM |
|--------|--------|---------|-----|
| `1-4.4` | PEAK PCAN-USB | `0c72:000c` | — |
| `1-4.3` | STM32 Virtual COM Port | `0483:5740` | COM20 |
| `1-4.1` | STM32 Virtual COM Port | `0483:5740` | COM19 |
| `1-5.3` | FTDI FT231X Bridge (I2C/SPI/UART/FIFO) | `0403:6015` | COM35 |
| `1-5.2` | FTDI FT232 Serial (UART) | `0403:6001` | COM31 |
| `1-5.1` | FTDI FT232 Serial (UART) | `0403:6001` | COM7 |
| `1-4.2.1` | Thesycon SiE Multiinterface | `152a:8427` | COM3 |
| `1-8` | Keil ULINKpro D (debugger) | `c251:2740` | — |
| *(excluded)* | Realtek RTS5129 card reader | `0bda:0129` | — |

The card reader is **excluded** (see below): the server still exports it, but
the client deliberately does not attach it.

## How the service reconciles

Each 30 s cycle of `usbip-bind-all.ps1`:

1. Query exportable devices: `usbip list -r <host>`.
2. Query currently attached devices: `usbip port`.
3. **Detach** any attached device whose VID:PID is in the exclude list.
4. **Attach** any exportable device that is neither excluded nor already
   attached (so it never re-attaches what is already there).
5. If anything changed, run `usbip port --stash` to sync the driver's
   persistent list (auto-heals stale bus-IDs).

Exclusion is by **VID:PID**, not bus-ID. To exclude more devices, edit
`$ExcludeVidPid` at the top of `usbip-bind-all.ps1`, e.g.:

```powershell
$ExcludeVidPid = @('0bda:0129', '046d:0825')   # card reader, webcam
```

Full detail — the discovery logic, parsing, design decisions and edge cases —
is in [AUTO-DISCOVERY.md](AUTO-DISCOVERY.md).

## Repository files

| File | Purpose |
|------|---------|
| `usbip-bind-all.ps1` | Keepalive script run by the service. Auto-discovers and reconciles devices; excludes by VID:PID; syncs the stash. |
| `usbip-install-service.ps1` | Installs and starts the `usbip-bindall` NSSM service. Run elevated. |
| `usbip-reconfigure-hostname.ps1` | One-off helper to re-attach all devices via a hostname instead of an IP. Run elevated. |
| `get-usbip-comport.ps1` | Lists each USB/IP device with its bus-ID, name, VID:PID and **COM port**. No detaching required. |

## Prerequisites

### Server (Linux)

Enable USB/IP and bind the devices you want to export:

```bash
sudo apt install linux-tools-generic linux-cloud-tools-generic   # Ubuntu
sudo modprobe -a usbip-core usbip-host
sudo usbipd -D

usbip list -l            # find bus ids
sudo usbip bind -b 1-4   # bind each device to make it exportable
```

> `usbip bind` does **not** survive a server reboot. Make it persistent with a
> systemd unit or a startup script. A device that is not bound will not appear
> on the client at all — this is the most common reason a new device "isn't
> showing up".

### Client (Windows)

- Windows 10 x64 build 1903 or later.
- [usbip-win2](https://github.com/vadimgrn/usbip-win2/releases) installed
  (default path `C:\Program Files\usbip`).
- [NSSM](https://nssm.cc/) (install via `choco install nssm`).

## Setup

1. On the server, bind the devices you want to export (see above).
2. Copy `usbip-bind-all.ps1` to `C:\binary\usbip\` (or edit
   `usbip-install-service.ps1` to point at your copy).
3. From an **elevated** PowerShell prompt:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\usbip-install-service.ps1
   ```

That is all — there is **no manual `usbip attach` step**. The service discovers
and attaches devices automatically, and the install script re-runs idempotently
(it stops/removes any existing service first).

## Usage

```powershell
$usbip = 'C:\Program Files\usbip\usbip.exe'

& $usbip list -r xaver-ThinkCentre-M720t   # exportable devices on the server
& $usbip port                              # currently imported devices
& $usbip list --stashed                    # persistent (auto-attach) devices

& $usbip attach -r xaver-ThinkCentre-M720t -b 1-4   # attach one device
& $usbip detach -p 1                       # detach by hub port
& $usbip detach --all                      # detach everything
```

Service management (elevated):

```powershell
nssm stop usbip-bindall
nssm start usbip-bindall
nssm status usbip-bindall
```

Service logs:

- `C:\binary\usbip\usbip-bind-all.out.log`
- `C:\binary\usbip\usbip-bind-all.err.log`

## Listing COM ports

`get-usbip-comport.ps1` prints a table of every USB/IP device with its
bus-ID, name, manufacturer, VID:PID and COM port:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\get-usbip-comport.ps1
```

It works without detaching and is fast (native `pnputil`/CIM, not the ~10 s
`Get-PnpDeviceProperty`). Two non-obvious details in the implementation:

- **Bus-ID resolution** — a device's server bus-ID is not exposed directly, and
  VID:PID alone is ambiguous when several devices share one (two FT232s, two
  STM32s). The script instead reads each device's registry `LocationInformation`
  (`Port_#NNNN`), which uniquely matches the local port in `usbip port`, and
  maps that to the server bus-ID.
- **Single-interface COM devices** — an STM32 Virtual COM Port *is* the USB
  device itself (no composite parent), so the COM port is found by walking up
  *from* the COM device *including* itself.

## How automatic reconnection works

Persistent devices are stored here (kept in sync by the service):

```
HKLM\SYSTEM\CurrentControlSet\Services\usbip2_ude\Parameters
  PersistentDevices = xaver-ThinkCentre-M720t,3240,<bus-id> ...
```

Reattach tuning values (same key):

| Value | Default | Meaning |
|-------|---------|---------|
| `ReattachFirstDelay` | 30 s | Delay before the first reattach attempt |
| `ReattachMaxDelay` | 8 min | Delay cap (each attempt is 1.5x the previous) |
| `ReattachMaxAttempts` | 20 | Stop after this many attempts (`0` disables) |

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| A new device never appears | It is not bound on the server. Run `usbip list -l` and `sudo usbip bind -b <bus-id>` on the server. |
| `error: No such host is known` | Hostname not resolving. Use the `.local` suffix (`xaver-ThinkCentre-M720t.local`) or the IP. Plain DNS does not resolve the bare name; mDNS does. |
| `Access is denied` | Service/driver operations need an elevated shell. |
| Bus-ID changed / device moved | Expected and handled. The service re-discovers every 30 s; no action needed. |
| Card reader shows `Error` in Device Manager | The RTS5129 driver does not virtualize cleanly over USB/IP. It is excluded by default (`0bda:0129`). |
| `Unexpected status SERVICE_START_PENDING` from `nssm start` | Harmless NSSM quirk; the service is running. Check `nssm status`. |
| Webcam won't enumerate or stutters | Webcams use **isochronous** transfers, which USB/IP handles less well than the bulk/interrupt traffic serial/CAN devices use. usbip-win2 does support isochronous, but expect possible frame drops depending on the LAN link. |

## Notes

- The hostname `xaver-ThinkCentre-M720t` resolves via mDNS, so the machine must
  be reachable on the same LAN. If the server uses DHCP and its IP changes, the
  hostname keeps working.
- Scripts contain this machine's hardcoded paths (`C:\Program Files\usbip`,
  `C:\binary\usbip`) and hostname; adjust before reusing elsewhere.
- Devices that are already attached are never re-attached (idempotent), so the
  service does not flap an existing device.
