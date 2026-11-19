# usbip-install-service.ps1
# Creates and starts the NSSM service that keeps all USB/IP devices attached.
# Must be run elevated (Administrator).

$ErrorActionPreference = 'Continue'
$log = 'C:\binary\usbip\usbip-service-setup.log'
Start-Transcript -Path $log -Force

$nssm   = 'C:\ProgramData\chocolatey\bin\nssm.exe'
$svc    = 'usbip-bindall'
$ps     = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$script = 'C:\binary\usbip\usbip-bind-all.ps1'

Write-Output "== Removing any existing service (idempotent) =="
& $nssm stop $svc   2>&1 | Write-Output
& $nssm remove $svc confirm 2>&1 | Write-Output

Write-Output "== Installing service =="
& $nssm install $svc $ps "-NoProfile -ExecutionPolicy Bypass -File `"$script`"" 2>&1 | Write-Output

& $nssm set $svc AppDirectory 'C:\binary\usbip'
& $nssm set $svc DisplayName 'USBIP Bind All'
& $nssm set $svc Description 'Keeps all USB/IP devices from 192.168.10.82 attached'
& $nssm set $svc AppStdout 'C:\binary\usbip\usbip-bind-all.out.log'
& $nssm set $svc AppStderr 'C:\binary\usbip\usbip-bind-all.err.log'
& $nssm set $svc AppRotateFiles 1
& $nssm set $svc AppRotateOnline 1
& $nssm set $svc AppRotateBytes 1048576
& $nssm set $svc AppExit Default Restart
& $nssm set $svc AppRestartDelay 5000
& $nssm set $svc Start SERVICE_AUTO_START

Write-Output "== Starting service =="
& $nssm start $svc 2>&1 | Write-Output

Start-Sleep -Seconds 5

Write-Output "== Service status =="
$s = Get-Service -Name $svc -ErrorAction SilentlyContinue
if ($s) {
    Write-Output ("State: {0}  StartType: {1}" -f $s.Status, $s.StartType)
} else {
    Write-Output "Get-Service did not find '$svc'"
}
Write-Output "== setup done =="
Stop-Transcript
