# usbip-bind-all.ps1
# Keepalive service script: ensure all USB/IP devices from the server are attached.
# Designed to be run as a Windows service via NSSM.

$ErrorActionPreference = 'Continue'

$UsbipExe = 'C:\Program Files\usbip\usbip.exe'
$Server   = 'xaver-ThinkCentre-M720t'
$BusIds   = @('1-4', '1-9', '1-10.1')
$Interval = 30   # seconds between checks

function Write-Log {
    param([string]$Msg)
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Msg
    Write-Output $line
}

Write-Log "usbip bind-all: starting (server=$Server, devices=$($BusIds -join ','))"

while ($true) {
    # Snapshot of currently imported devices.
    $port = (& $UsbipExe port 2>$null | Out-String)

    foreach ($id in $BusIds) {
        if ($port -match [regex]::Escape("/$id")) {
            # Already attached; nothing to do.
        }
        else {
            Write-Log "Attaching $id ..."
            $result = (& $UsbipExe attach -r $Server -b $id 2>&1 | Out-String).Trim()
            Write-Log "  attach $id -> $result"
        }
    }

    Start-Sleep -Seconds $Interval
}
