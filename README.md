# remote-usb-client

Windows USB/IP client setup for using USB devices that are shared by a Linux
USB/IP server. This repo contains the scripts that attach the devices, keep
them attached automatically (on boot and after network drops), and install
everything as a Windows service.

## Overview

A Windows machine connects over TCP/IP to a Linux box that exports its USB
devices via the [USB/IP](https://www.kernel.org/doc/html/latest/usb/usbip_protocol.html)
protocol. The client runs
[usbip-win2](https://github.com/vadimgrn/usbip-win2) (v0.9.7.3), which provides
a WHLK-certified UDE driver and a `usbip.exe` command-line tool.

Attachment is made automatic through **two complementary layers**:

1. **usbip-win2 native persistent devices** — stored in the driver's registry.
   The driver re-attaches them every time it loads and reconnects automatically
   (with exponential backoff) when a device drops.
2. **NSSM keepalive service** (`usbip-bindall`) — polls every 30 seconds and
   re-attaches any device that is missing.

## Topology

| | |
|---|---|
| Server | `xaver-ThinkCentre-M720t` (Ubuntu Linux, USB/IP server) |
| Server address | resolves via mDNS to `192.168.10.82`, port `3240` |
| Client | Windows 10 x64 (this machine) |
| Client software | usbip-win2 `C:\Program Files\usbip\usbip.exe` |

### Shared devices

| Bus-ID | Device | VID:PID | Windows status |
|--------|--------|---------|----------------|
| `1-4` | Keil ULINKpro D (debugger/programmer) | `c251:2740` | OK |
| `1-9` | Realtek RTS5129 card reader | `0bda:0129` | Error (driver quirk over IP) |
| `1-10.1` | FTDI FT232 serial (UART) | `0403:6001` | OK |

## Repository files

| File | Purpose |
|------|---------|
| `usbip-bind-all.ps1` | Keepalive script run by the service; attaches and monitors all devices. |
| `usbip-install-service.ps1` | Installs and starts the `usbip-bindall` NSSM service. Run elevated. |
| `usbip-reconfigure-hostname.ps1` | Re-attaches all devices using a hostname instead of an IP. Run elevated. |

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

> `usbip bind` does not survive a server reboot. Make it persistent with a
> systemd unit or a startup script if you need it.

### Client (Windows)

- Windows 10 x64 build 1903 or later.
- [usbip-win2](https://github.com/vadimgrn/usbip-win2/releases) installed
  (default path `C:\Program Files\usbip`).
- [NSSM](https://nssm.cc/) (install via `choco install nssm`).

## Setup

### 1. Attach and persist devices

```powershell
$usbip = 'C:\Program Files\usbip\usbip.exe'
& $usbip attach -r xaver-ThinkCentre-M720t -b 1-4
& $usbip attach -r xaver-ThinkCentre-M720t -b 1-9
& $usbip attach -r xaver-ThinkCentre-M720t -b 1-10.1
& $usbip port --stash          # mark them persistent (auto-attach on boot)
& $usbip list --stashed        # verify
```

### 2. Install the keepalive service

Run `usbip-install-service.ps1` from an **elevated** PowerShell prompt. It
creates an NSSM service named `usbip-bindall` (Automatic start) that runs
`usbip-bind-all.ps1`.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\usbip-install-service.ps1
```

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

## How automatic reconnection works

Persistent devices are stored here:

```
HKLM\SYSTEM\CurrentControlSet\Services\usbip2_ude\Parameters
  PersistentDevices = xaver-ThinkCentre-M720t,3240,1-4 / 1-9 / 1-10.1
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
| `error: No such host is known` | Hostname not resolving. Use the `.local` suffix (`xaver-ThinkCentre-M720t.local`) or the IP. Plain DNS did not resolve the bare name; mDNS does. |
| `Access is denied` | Service/driver operations need an elevated shell. |
| Card reader shows `Error` in Device Manager | The RTS5129 driver does not virtualize cleanly over USB/IP. Connection itself is fine; drop `1-9` if unused. |
| `Unexpected status SERVICE_START_PENDING` from `nssm start` | Harmless NSSM quirk; the service is running. Check `nssm status`. |

## Notes

- The hostname `xaver-ThinkCentre-M720t` resolves via mDNS, so the machine must
  be reachable on the same LAN. If the server uses DHCP and its IP changes, the
  hostname keeps working.
- Scripts contain this machine's hardcoded paths (`C:\Program Files\usbip`,
  `C:\binary\usbip`) and hostname; adjust before reusing elsewhere.
