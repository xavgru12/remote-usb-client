# get-usbip-comport.ps1
# Lists every USB/IP-attached device with its name info and COM port:
#   BusID, Device, Manufacturer, VID:PID, COM, Server name.
#
# Correctly maps the server bus-id by matching each device's registry
# LocationInformation (Port_#NNNN) to the local port in "usbip port", so it
# works even when several devices share the same VID:PID. Also handles both
# composite devices (FTDI: COM port is a child) and single-interface devices
# (STM32 VCP: the device itself is the COM port).
#
# No detaching required. Uses native pnputil (fast) instead of slow WMI.

$UsbipExe = 'C:\Program Files\usbip\usbip.exe'

# --- 1. PnP tree: instance-id -> (description, parent) ---
$desc   = @{}
$parent = @{}
$cur    = $null
foreach ($ln in (pnputil /enum-devices /connected /relations)) {
    if ($ln -match '^\s*Instance ID:\s*(.+?)\s*$') {
        $cur = $Matches[1]
        $desc[$cur] = ''
        $parent[$cur] = ''
    }
    elseif ($cur -and $ln -match '^\s*Device Description:\s*(.+?)\s*$') {
        $desc[$cur] = $Matches[1]
    }
    elseif ($cur -and $ln -match '^\s*Parent:\s*(.+?)\s*$') {
        $parent[$cur] = $Matches[1]
    }
}

# --- 2. Locate the USB/IP controller(s), root hub(s), and attached devices ---
$ctrl     = @($desc.Keys | Where-Object { $desc[$_] -match 'usbip' })
$rootHubs = @($desc.Keys | Where-Object { $ctrl -contains $parent[$_] })
$devs     = @($desc.Keys | Where-Object { $rootHubs -contains $parent[$_] })

# --- 3. Map each usbip device to its local vhci port via LocationInformation ---
$portOfDev = @{}
foreach ($id in $devs) {
    $reg = "HKLM:\SYSTEM\CurrentControlSet\Enum\$id"
    $loc = (Get-ItemProperty -Path $reg -ErrorAction SilentlyContinue).LocationInformation
    if ($loc -match 'Port_#(\d+)') { $portOfDev[$id] = [int]$Matches[1] }
}

# --- 4. Parse "usbip port" -> local port -> { BusId, VidPid, SrvName } ---
$portTxt  = (& $UsbipExe port 2>$null | Out-String)
$portInfo = @{}
[regex]::Matches($portTxt, '(?ms)^\s*Port (\d+):\s*(.*?)(?=^\s*Port \d+:|\z)') | ForEach-Object {
    $pn   = [int]$_.Groups[1].Value
    $body = $_.Groups[2].Value
    $portInfo[$pn] = [PSCustomObject]@{
        BusId   = [regex]::Match($body, 'usbip://[^/\s]+/([0-9]+-[0-9.]+)').Groups[1].Value
        VidPid  = [regex]::Match($body, '\(([0-9a-fA-F]{4}:[0-9a-fA-F]{4})\)').Groups[1].Value.ToLower()
        SrvName = ([regex]::Match($body, '(?m)^\s*(.+?)\s*\([0-9a-fA-F]{4}:[0-9a-fA-F]{4}\)\s*$').Groups[1].Value).Trim()
    }
}

# --- 5. Map COM ports to usbip devices (walk up, including the device itself) ---
$comToDev = @{}
foreach ($comId in ($desc.Keys | Where-Object { $desc[$_] -match 'COM\d+' })) {
    $x = $comId
    for ($j = 0; $j -lt 12; $j++) {
        if ($devs -contains $x) { $comToDev[$x] = $comId; break }
        if (-not $parent.ContainsKey($x) -or -not $parent[$x]) { break }
        $x = $parent[$x]
    }
}

# --- 6. Manufacturer via CIM (one fast call) ---
$pnp = @{}
Get-CimInstance Win32_PnPEntity | ForEach-Object { $pnp[$_.DeviceID] = $_ }

# --- 7. Report ---
$devs | Sort-Object | ForEach-Object {
    $pn = $portOfDev[$_]
    $pi = $portInfo[$pn]

    $bus = if ($pi) { $pi.BusId } else { '-' }
    $srv = if ($pi) { $pi.SrvName } else { '' }

    $vm  = [regex]::Match($_, 'VID_([0-9a-fA-F]{4})&PID_([0-9a-fA-F]{4})')
    $vid = if ($vm.Success) { "$($vm.Groups[1].Value):$($vm.Groups[2].Value)".ToLower() }
           elseif ($pi)      { $pi.VidPid }
           else              { '-' }

    $com = if ($comToDev.ContainsKey($_)) { [regex]::Match($desc[$comToDev[$_]], 'COM\d+').Value } else { '-' }

    $mfg = $pnp[$_].Manufacturer
    if (-not $mfg -and $srv) { $mfg = ($srv -split '\s*:\s*')[0] }   # fall back to server vendor

    [PSCustomObject]@{
        BusID        = $bus
        Device       = $desc[$_]
        Manufacturer = $mfg
        'VID:PID'    = $vid
        COM          = $com
        'Server name' = $srv
    }
} | Format-Table -AutoSize -Wrap
