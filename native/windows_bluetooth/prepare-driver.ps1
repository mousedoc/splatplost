param(
    [string]$Destination = (Join-Path $PSScriptRoot "_deps\windows-driver-samples")
)

$ErrorActionPreference = "Stop"
$sampleCommit = "2ee527bfeb0aeb6be11f0a8b6dce4011b358ce89"
$sampleUrl = "https://github.com/microsoft/windows-driver-samples.git"
$destination = [IO.Path]::GetFullPath($Destination)
$ownedRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "_deps"))

if (-not $destination.StartsWith($ownedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "The dependency directory must stay inside $ownedRoot"
}

if (-not (Test-Path (Join-Path $destination ".git"))) {
    New-Item -ItemType Directory -Force -Path $ownedRoot | Out-Null
    git clone --filter=blob:none --no-checkout $sampleUrl $destination
    if ($LASTEXITCODE -ne 0) { throw "Unable to clone Windows driver samples." }
}

git -C $destination sparse-checkout init --cone
git -C $destination sparse-checkout set bluetooth/bthecho
git -C $destination checkout --force $sampleCommit
if ($LASTEXITCODE -ne 0) { throw "Unable to check out Windows driver samples commit $sampleCommit." }

# This directory is generated and owned by this script, so restoring it is safe.
git -C $destination reset --hard $sampleCommit
git -C $destination clean -fd -- bluetooth/bthecho
git -C $destination apply (Join-Path $PSScriptRoot "windows-driver-samples.patch")
if ($LASTEXITCODE -ne 0) { throw "Unable to apply the Splatplost Bluetooth driver patch." }

$serverSource = Join-Path $destination "bluetooth\bthecho\bthsrv\sys"
Remove-Item -LiteralPath (Join-Path $serverSource "BthEchoSampleSrv.inx") -Force
Copy-Item -Force (Join-Path $PSScriptRoot "SplatplostBluetooth.inx") $serverSource
python (Join-Path $PSScriptRoot "generate_switch_sdp.py") `
    (Join-Path $PSScriptRoot "switch-controller.xml") `
    (Join-Path $serverSource "switch_sdp.h")
if ($LASTEXITCODE -ne 0) { throw "Unable to generate the Switch HID SDP record." }

Write-Output $destination
