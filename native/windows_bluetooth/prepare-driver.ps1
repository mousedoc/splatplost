param(
    [string]$Destination = (Join-Path $PSScriptRoot "_deps\windows-driver-samples")
)

$ErrorActionPreference = "Stop"
$sampleCommit = "2ee527bfeb0aeb6be11f0a8b6dce4011b358ce89"
$sampleUrl = "https://github.com/microsoft/windows-driver-samples.git"
$destination = [IO.Path]::GetFullPath($Destination)
$ownedRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "_deps"))
$ownedPrefix = $ownedRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar

if (-not $destination.StartsWith($ownedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "The dependency directory must stay inside $ownedRoot"
}

# This script performs reset/clean operations, so refuse junctions or symlinks
# anywhere in the owned path that could redirect those operations elsewhere.
$pathToCheck = $destination
while ($pathToCheck -and $pathToCheck.StartsWith($ownedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    if (Test-Path -LiteralPath $pathToCheck) {
        $item = Get-Item -LiteralPath $pathToCheck -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "The generated dependency path must not contain a reparse point: $pathToCheck"
        }
    }
    $pathToCheck = [IO.Path]::GetDirectoryName($pathToCheck)
}
if (Test-Path -LiteralPath $ownedRoot) {
    $ownedRootItem = Get-Item -LiteralPath $ownedRoot -Force
    if (($ownedRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The generated dependency root must not be a reparse point: $ownedRoot"
    }
}

if (-not (Test-Path (Join-Path $destination ".git"))) {
    New-Item -ItemType Directory -Force -Path $ownedRoot | Out-Null
    git clone --filter=blob:none --no-checkout $sampleUrl $destination
    if ($LASTEXITCODE -ne 0) { throw "Unable to clone Windows driver samples." }
}

git -C $destination sparse-checkout init --cone
if ($LASTEXITCODE -ne 0) { throw "Unable to initialize the sparse Windows driver sample checkout." }
git -C $destination sparse-checkout set bluetooth/bthecho
if ($LASTEXITCODE -ne 0) { throw "Unable to select the Bluetooth sample source." }
git -C $destination checkout --force $sampleCommit
if ($LASTEXITCODE -ne 0) { throw "Unable to check out Windows driver samples commit $sampleCommit." }

# This directory is generated and owned by this script, so restoring it is safe.
git -C $destination reset --hard $sampleCommit
if ($LASTEXITCODE -ne 0) { throw "Unable to reset the generated Windows driver sample source." }
git -C $destination clean -fdx -- bluetooth/bthecho
if ($LASTEXITCODE -ne 0) { throw "Unable to clean generated Windows driver sample output." }
git -C $destination apply (Join-Path $PSScriptRoot "windows-driver-samples.patch")
if ($LASTEXITCODE -ne 0) { throw "Unable to apply the Splatplost Bluetooth driver patch." }
git -C $destination apply (Join-Path $PSScriptRoot "windows-driver-diagnostics.patch")
if ($LASTEXITCODE -ne 0) { throw "Unable to apply the Splatplost Bluetooth diagnostics patch." }
git -C $destination apply (Join-Path $PSScriptRoot "windows-driver-specific-psm.patch")
if ($LASTEXITCODE -ne 0) { throw "Unable to apply the device-specific HID PSM patch." }
git -C $destination apply (Join-Path $PSScriptRoot "windows-driver-runtime-hardening.patch")
if ($LASTEXITCODE -ne 0) { throw "Unable to apply the Windows runtime hardening patch." }

$serverSource = Join-Path $destination "bluetooth\bthecho\bthsrv\sys"
Remove-Item -LiteralPath (Join-Path $serverSource "BthEchoSampleSrv.inx") -Force
Copy-Item -Force (Join-Path $PSScriptRoot "SplatplostBluetooth.inx") $serverSource
python (Join-Path $PSScriptRoot "generate_switch_sdp.py") `
    (Join-Path $PSScriptRoot "switch-controller.xml") `
    (Join-Path $serverSource "switch_sdp.h")
if ($LASTEXITCODE -ne 0) { throw "Unable to generate the Switch HID SDP record." }

Write-Output $destination
