param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",
    [ValidateSet("x64")]
    [string]$Platform = "x64",
    [string]$Output = (Join-Path $PSScriptRoot "out")
)

$ErrorActionPreference = "Stop"
$source = & (Join-Path $PSScriptRoot "prepare-driver.ps1")
$source = $source[-1]

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw "Visual Studio Installer was not found." }
$msbuild = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find MSBuild\**\Bin\MSBuild.exe | Select-Object -First 1
if (-not $msbuild) { throw "MSBuild was not found." }

$base = Join-Path $source "bluetooth\bthecho"
$properties = @(
    "/p:Configuration=$Configuration",
    "/p:Platform=$Platform",
    "/p:SignMode=Off",
    "/p:Inf2CatUseLocalTime=true",
    "/m",
    "/nologo"
)

& $msbuild (Join-Path $base "common\lib\bthecho.vcxproj") @properties
if ($LASTEXITCODE -ne 0) { throw "The Bluetooth support library build failed." }
& $msbuild (Join-Path $base "bthsrv\sys\BthEchoSampleSrv.vcxproj") @properties
if ($LASTEXITCODE -ne 0) { throw "The Splatplost Bluetooth driver build failed." }
& $msbuild (Join-Path $base "bthsrv\inst\bthsrvinst.vcxproj") @properties
if ($LASTEXITCODE -ne 0) { throw "The Bluetooth service installer build failed." }

$output = [IO.Path]::GetFullPath($Output)
New-Item -ItemType Directory -Force -Path $output | Out-Null

$driver = Get-ChildItem -Path $base -Recurse -Filter SplatplostBluetooth.sys | Select-Object -First 1
$inf = Get-ChildItem -Path $base -Recurse -Filter SplatplostBluetooth.inf | Select-Object -First 1
$installer = Get-ChildItem -Path $base -Recurse -Filter bthsrvinst.exe | Select-Object -First 1
if (-not $driver -or -not $inf -or -not $installer) {
    throw "One or more driver build outputs could not be located."
}

Copy-Item -Force $driver.FullName (Join-Path $output "SplatplostBluetooth.sys")
Copy-Item -Force $inf.FullName (Join-Path $output "SplatplostBluetooth.inf")
Copy-Item -Force $installer.FullName (Join-Path $output "SplatplostBluetoothService.exe")
Copy-Item -Force (Join-Path $PSScriptRoot "install-driver.ps1") $output
Copy-Item -Force (Join-Path $PSScriptRoot "uninstall-driver.ps1") $output
Copy-Item -Force (Join-Path $PSScriptRoot "THIRD_PARTY_NOTICES.md") $output

Write-Output $output
