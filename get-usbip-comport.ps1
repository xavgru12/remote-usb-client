# get-usbip-comport.ps1
# Lists every USB/IP-attached device with its name info and COM port (if any):
#   BusID, Windows device, server-side name, manufacturer, VID:PID, COM.
# No detaching required. Uses native pnputil (fast) instead of slow WMI.

$UsbipExe = 'C:\Program Files\usbip\usbip.exe'

# --- 1. Build instance-id -> (description, parent) maps from the PnP tree ---
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

# --- 2. Locate the USB/IP controller(s), their root hub(s), and attached devices ---
$ctrl     = @($desc.Keys | Where-Object { $desc[$_] -match 'usbip' })
$rootHubs = @($desc.Keys | Where-Object { $ctrl -contains $parent[$_] })
$devs     = @($desc.Keys | Where-Object { $rootHubs -contains $parent[$_] })

# --- 3. Map each COM port back up to its USB/IP device ---
$comToDev = @{}
foreach ($id in ($desc.Keys | Where-Object { $desc[$_] -match 'COM\d+' })) {
    $x = $parent[$id]
    for ($j = 0; $j -lt 12; $j++) {
        if ($devs -contains $x) { $comToDev[$x] = $id; break }
        if (-not $parent.ContainsKey($x) -or -not $parent[$x]) { break }
        $x = $parent[$x]
    }
}

# --- 4. Manufacturer via CIM (one fast call) ---
$pnp = @{}
Get-CimInstance Win32_PnPEntity | ForEach-Object { $pnp[$_.DeviceID] = $_ }

# --- 5. Server-side info (bus id, vendor : product, vid:pid) via usbip port ---
$portTxt = (& $UsbipExe port 2>$null | Out-String)
$busids   = [regex]::Matches($portTxt, 'usbip://[^/\s]+/([0-9]+-[0-9.]+)') | ForEach-Object { $_.Groups[1].Value }
$vidpids  = [regex]::Matches($portTxt, '\(([0-9a-fA-F]{4}:[0-9a-fA-F]{4})\)') | ForEach-Object { $_.Groups[1].Value.ToLower() }
$srvNames = [regex]::Matches($portTxt, '(?m)^\s*([^\r\n]+?)\s*\([0-9a-fA-F]{4}:[0-9a-fA-F]{4}\)\s*$') | ForEach-Object { $_.Groups[1].Value.Trim() }

# --- 6. Report ---
$devs | Sort-Object | ForEach-Object {
    $m    = [regex]::Match($_, 'VID_([0-9a-fA-F]{4})&PID_([0-9a-fA-F]{4})')
    $vid  = if ($m.Success) { "$($m.Groups[1].Value):$($m.Groups[2].Value)".ToLower() } else { '-' }
    $idx  = [array]::IndexOf($vidpids, $vid)
    $bus  = if ($idx -ge 0 -and $idx -lt $busids.Count)   { $busids[$idx] } else { '-' }
    $srv  = if ($idx -ge 0 -and $idx -lt $srvNames.Count) { $srvNames[$idx] } else { '' }
    $com  = if ($comToDev.ContainsKey($_)) { [regex]::Match($desc[$comToDev[$_]], 'COM\d+').Value } else { '-' }

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
