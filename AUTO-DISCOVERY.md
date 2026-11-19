# USB/IP Auto-Discovery

This document explains how `usbip-bind-all.ps1` discovers and keeps USB/IP
devices attached automatically — why it exists, what it does each cycle, the
design decisions behind it, and how to configure and diagnose it.

## The problem it solves

A naive client hardcodes the server bus-IDs of the devices it wants:

```powershell
$BusIds = @('1-4', '1-9', '1-10.1')
foreach ($b in $BusIds) { usbip attach -r $Server -b $b }
```

This breaks because **USB/IP bus-IDs are not stable**. They are assigned by the
server's USB topology, and they change whenever a device is re-plugged, a hub
is moved, or the server re-enumerates its bus. Concretely, an FTDI chip that was
`1-10.1` became `1-5.1` after being re-plugged — and the old ID `1-10.1` had
meanwhile been taken over by a *different* device (the Thesycon). Hardcoded IDs
therefore attach the wrong device, or nothing at all.

The fix is to stop hardcoding and **re-discover the exportable set every cycle**.

## Design overview

`usbip-bind-all.ps1` runs in an infinite loop (every `$Interval` seconds) and
reconciles the *desired* state (everything the server exports, minus
exclusions) with the *actual* state (what is currently attached):

```
        desired = exportable - excluded
        actual  = attached
        reconcile: detach (actual - desired)   # only excluded ones
                   attach  (desired - actual)
```

Reconciliation is keyed by **VID:PID** (stable identity), never bus-ID.

## The reconcile cycle, step by step

Each 30-second cycle performs five steps.

### 1. Query exportable devices

```powershell
usbip list -r xaver-ThinkCentre-M720t
```

"Exportable" means the server has bound the device with `usbip bind` and no
client currently has it attached. Output looks like:

```
   1-5.1   : Future Technology Devices ... : FT232 Serial (UART) IC (0403:6001)
           : /sys/devices/...
           : (Defined at Interface level) (00/00/00)
```

The script (`Get-Exportable`) extracts **bus-ID** and **VID:PID** from the
device line with:

```
(?m)^\s*([0-9]+-[0-9.]+)\s*:\s*.*?\(([0-9a-fA-F]{4}:[0-9a-fA-F]{4})\)\s*$
```

The bus-ID (`1-5.1`) is captured for the *attach command only*; the VID:PID
(`0403:6001`) is the stable key used for all decisions.

### 2. Query currently-attached devices

```powershell
usbip port
```

Output:

```
Port 01: device in use at High Speed(480Mbps)
         Keil Software, Inc. : unknown product (c251:2740)
           -> usbip://xaver-ThinkCentre-M720t:3240/1-4
```

`Get-Attached` splits this into per-port blocks and extracts **port number**,
**bus-ID** and **VID:PID**:

```
(?ms)^\s*Port (\d+):\s*(.*?)(?=^\s*Port \d+:|\z)
```

### 3. Detach excluded devices

For every attached device whose VID:PID is in `$ExcludeVidPid`, the script runs
`usbip detach -p <port>`. This enforces the exclusion even if something else
(the driver stash, an old config) attached it.

### 4. Attach missing devices

For every exportable device that is **not** excluded and **not** already
attached, the script runs `usbip attach -r <server> -b <bus-id>`.

### 5. Sync the driver stash

If either step 3 or 4 changed anything, the script runs:

```powershell
usbip port --stash
```

which rewrites the driver's `PersistentDevices` registry value to the *current*
attached set. This keeps the fast reconnect layer in sync and auto-heals stale
bus-IDs after devices move.

## Key design decisions

### Keyed by VID:PID, not bus-ID

Bus-ID changes; VID:PID does not. All exclude/skip decisions use VID:PID. The
bus-ID is used only transiently, to tell `usbip attach` which slot to grab in
the *current* export list.

Consequence: **two devices with the same VID:PID are treated as one identity.**
The two STM32 VCPs (`0483:5740`) are indistinguishable to the reconciler — if
you wanted to attach only *one* of them, VID:PID exclusion could not express
that. (This has not been needed in practice.)

### "Exportable" and "attached" are disjoint

A device is either exportable (not attached by anyone) or attached to this
client — the server removes an attached device from its export list. So
`usbip list -r` normally lists only devices that are *not* attached, and the
"skip already-attached" check in step 4 is a defensive guard rather than the
primary mechanism. It matters for the brief window where a freshly-attached
device still lingers in the export list, and it is what makes the loop
idempotent: the service never re-attaches a device it already has.

### The stash is a fast layer, not the source of truth

The driver's persistent stash gives fast, kernel-level reconnect (with
exponential backoff) after a drop or reboot. The service is the source of truth:
it discovers the correct set and re-stashes it whenever it changes. Without the
re-stash, the stash would keep re-attaching stale bus-IDs on boot.

## Configuration

All knobs are at the top of `usbip-bind-all.ps1`:

| Variable | Default | Meaning |
|----------|---------|---------|
| `$Server` | `xaver-ThinkCentre-M720t` | USB/IP server hostname (resolves via mDNS) |
| `$Interval` | `30` | Seconds between reconcile cycles |
| `$ExcludeVidPid` | `@('0bda:0129')` | VID:PIDs to never attach (card reader) |
| `$UsbipExe` | `C:\Program Files\usbip\usbip.exe` | Path to the usbip-win2 client |

To exclude more devices, append VID:PIDs (lower-case, case-insensitive match):

```powershell
$ExcludeVidPid = @('0bda:0129', '046d:0825')   # card reader, webcam
```

To attach *everything* the server exports, leave the list at `@()`.

## Diagnostics

The service writes one line per action to
`C:\binary\usbip\usbip-bind-all.out.log`. A healthy steady state produces **no
output** (nothing changes between cycles). Output appears only when:

- a new device is attached (`Attaching <bus-id> (<vid:pid>) ...`),
- an excluded device is detached (`Detaching excluded device ...`), or
- the stash is updated (`stash updated`).

A busy log full of repeated `Attaching` lines means the server-side bus-IDs are
churning (devices being re-plugged) or a device is flapping; each attach line
should be followed by `stash updated` in the same cycle.

## Edge cases and limitations

- **Isochronous devices (webcams, audio).** Webcams such as `046d:0825` attach
  and are auto-discovered like any other device, but their isochronous
  endpoints do not transport reliably over USB/IP; they may drop, enumerate
  with errors, or stutter. This is a protocol limitation, not an auto-discovery
  bug. Exclude such devices if they misbehave.
- **Server reboot / unbind.** `usbip bind` on the server does not survive a
  reboot, and a device that is not bound never appears in `usbip list -r`, so
  the client cannot attach it. The #1 cause of "my new device never appears" is
  a missing `usbip bind` on the server.
- **Duplicate VID:PIDs.** Identical devices are treated as one identity (see
  above). Distinguishing them would require a different key (e.g. serial
  number), which the export list does not provide.
- **mDNS dependency.** `$Server` is a bare hostname resolved by mDNS; if the
  server is on a different subnet, switch to its IP or a `.local` name.
