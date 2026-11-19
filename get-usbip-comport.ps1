# get-usbip-comport.ps1
# Lists every USB/IP-attached device and its Windows COM port (if any).
# No detaching required. Uses native pnputil (fast) instead of slow WMI.

# Build instance-id -> (description, parent) maps from the PnP relations tree.
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

# Locate the USB/IP controller(s), their virtual root hub(s), and the attached devices.
$ctrl     = @($desc.Keys | Where-Object { $desc[$_] -match 'usbip' })
$rootHubs = @($desc.Keys | Where-Object { $ctrl -contains $parent[$_] })
$devs     = @($desc.Keys | Where-Object { $rootHubs -contains $parent[$_] })

# Map each COM port back up to its USB/IP device.
$comToDev = @{}
foreach ($id in ($desc.Keys | Where-Object { $desc[$_] -match 'COM\d+' })) {
    $x = $parent[$id]
    for ($j = 0; $j -lt 12; $j++) {
        if ($devs -contains $x) { $comToDev[$x] = $id; break }
        if (-not $parent.ContainsKey($x) -or -not $parent[$x]) { break }
        $x = $parent[$x]
    }
}

# Report each USB/IP device with its COM port (or '-' if it has none).
$devs | Sort-Object | ForEach-Object {
    $com = if ($comToDev.ContainsKey($_)) { [regex]::Match($desc[$comToDev[$_]], 'COM\d+').Value } else { '-' }
    [PSCustomObject]@{
        Device     = $desc[$_]
        COM        = $com
        InstanceId = $_
    }
} | Format-Table -AutoSize -Wrap
