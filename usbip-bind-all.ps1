# usbip-bind-all.ps1
# Keepalive service script (run by the NSSM service "usbip-bindall").
#
# Auto-discovers USB/IP devices exported by the server and keeps them attached:
#   - attaches every exportable device, except those in $ExcludeVidPid
#   - skips devices that are already attached (no redundant re-attach)
#   - detaches excluded devices that are still attached
#   - keeps the driver's persistent ("stash") list in sync when anything changes
#
# Bus-IDs are not stable (they change when devices are re-plugged on the server),
# so we re-discover them every cycle instead of hardcoding them.

$ErrorActionPreference = 'Continue'

$UsbipExe = 'C:\Program Files\usbip\usbip.exe'
$Server   = 'xaver-ThinkCentre-M720t'
$Interval = 30   # seconds between checks

# Devices to exclude, by VID:PID (case-insensitive).
# RTS5129 card reader = 0bda:0129
$ExcludeVidPid = @('0bda:0129')

function Write-Log {
    param([string]$Msg)
    Write-Output ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Msg)
}

# Parse "usbip list -r <host>" output -> { BusId, VidPid }
function Get-Exportable {
    $txt = & $UsbipExe list -r $Server 2>$null | Out-String
    [regex]::Matches($txt, '(?m)^\s*([0-9]+-[0-9.]+)\s*:\s*.*?\(([0-9a-fA-F]{4}:[0-9a-fA-F]{4})\)\s*$') |
        ForEach-Object { [PSCustomObject]@{ BusId = $_.Groups[1].Value; VidPid = $_.Groups[2].Value.ToLower() } }
}

# Parse "usbip port" output -> { Port, BusId, VidPid }
function Get-Attached {
    $txt = & $UsbipExe port 2>$null | Out-String
    [regex]::Matches($txt, '(?ms)^\s*Port (\d+):\s*(.*?)(?=^\s*Port \d+:|\z)') | ForEach-Object {
        $body = $_.Groups[2].Value
        [PSCustomObject]@{
            Port   = [int]$_.Groups[1].Value
            BusId  = [regex]::Match($body, 'usbip://[^/\s]+/([0-9]+-[0-9.]+)').Groups[1].Value
            VidPid = [regex]::Match($body, '\(([0-9a-fA-F]{4}:[0-9a-fA-F]{4})\)').Groups[1].Value.ToLower()
        }
    }
}

Write-Log "usbip bind-all: starting (server=$Server, auto-discover, exclude=$($ExcludeVidPid -join ','))"

while ($true) {
    $changed = $false

    $attached = @(Get-Attached)
    $export   = @(Get-Exportable)

    # 1. Detach excluded devices that are currently attached.
    foreach ($a in $attached) {
        if ($a.VidPid -and ($ExcludeVidPid -contains $a.VidPid)) {
            Write-Log "Detaching excluded device $($a.BusId) ($($a.VidPid)) from port $($a.Port) ..."
            $r = (& $UsbipExe detach -p $a.Port 2>&1 | Out-String).Trim()
            Write-Log "  detach -> $r"
            $changed = $true
        }
    }

    # 2. Attach exportable devices that are not excluded and not already attached.
    $attachedBusIds = @($attached | ForEach-Object { $_.BusId })
    foreach ($d in $export) {
        if ($ExcludeVidPid -contains $d.VidPid) { continue }
        if ($attachedBusIds -contains $d.BusId) { continue }
        Write-Log "Attaching $($d.BusId) ($($d.VidPid)) ..."
        $r = (& $UsbipExe attach -r $Server -b $d.BusId 2>&1 | Out-String).Trim()
        Write-Log "  attach $($d.BusId) -> $r"
        $changed = $true
    }

    # 3. Keep the driver's persistent list in sync (auto-heal stale bus-IDs).
    if ($changed) {
        & $UsbipExe port --stash 2>$null | Out-Null
        Write-Log "stash updated"
    }

    Start-Sleep -Seconds $Interval
}
