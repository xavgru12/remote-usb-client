# usbip-reconfigure-hostname.ps1
# Switch all USB/IP devices to use the hostname xaver-ThinkCentre-M720t
# Must be run elevated.

$ErrorActionPreference = 'Continue'
$log = 'C:\binary\usbip\usbip-reconfigure.log'
Start-Transcript -Path $log -Force

$usbip = 'C:\Program Files\usbip\usbip.exe'
$nssm  = 'C:\ProgramData\chocolatey\bin\nssm.exe'
$svc   = 'usbip-bindall'
$server = 'xaver-ThinkCentre-M720t'
$busids = @('1-4', '1-9', '1-10.1')

Write-Output "== Stop service =="
& $nssm stop $svc 2>&1 | Write-Output
Start-Sleep -Seconds 2
& $nssm status $svc 2>&1 | Write-Output

Write-Output "== Detach all =="
& $usbip detach --all 2>&1 | Write-Output
Start-Sleep -Seconds 1

Write-Output "== Attach all via hostname $server =="
foreach ($b in $busids) {
    Write-Output ("attaching {0} ..." -f $b)
    & $usbip attach -r $server -b $b 2>&1 | Write-Output
}

Write-Output "== Stash (persist) =="
& $usbip port --stash 2>&1 | Write-Output

Write-Output "== Start service =="
& $nssm start $svc 2>&1 | Write-Output
Start-Sleep -Seconds 3

Write-Output "== Final imported devices =="
& $usbip port 2>&1 | Write-Output
Write-Output "== Stashed devices =="
& $usbip list --stashed 2>&1 | Write-Output

Write-Output "== Service status =="
& $nssm status $svc 2>&1 | Write-Output
Write-Output "== done =="
Stop-Transcript
