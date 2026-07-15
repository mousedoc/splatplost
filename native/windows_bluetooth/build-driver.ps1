param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",
    [ValidateSet("x64")]
    [string]$Platform = "x64",
    [string]$Output = (Join-Path $PSScriptRoot "out"),
    [string]$DriverVersion,
    [string]$DriverDate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-SplatplostDriverVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if ($Value -notmatch '^(0|[1-9][0-9]{0,4})(\.(0|[1-9][0-9]{0,4})){3}$') {
        throw "DriverVersion must use canonical w.x.y.z notation with four non-negative decimal components."
    }

    $components = @($Value.Split('.') | ForEach-Object { [int]$_ })
    # Microsoft documents each DriverVer component as strictly less than 65535.
    if (@($components | Where-Object { $_ -ge 65535 }).Count -ne 0) {
        throw "Each DriverVersion component must be less than 65535."
    }
    if (@($components | Where-Object { $_ -ne 0 }).Count -eq 0) {
        throw "DriverVersion 0.0.0.0 is not valid for a Windows driver package."
    }

    return ($components -join '.')
}

function Resolve-SplatplostDriverDate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $parsed = [DateTime]::MinValue
    $valid = [DateTime]::TryParseExact(
        $Value,
        "MM/dd/yyyy",
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None,
        [ref]$parsed
    )
    if (-not $valid) {
        throw "DriverDate must be a real calendar date in MM/dd/yyyy notation."
    }
    if ($parsed.Date -gt [DateTime]::UtcNow.Date) {
        throw "DriverDate cannot be later than the current UTC date."
    }

    return $parsed.ToString("MM/dd/yyyy", [Globalization.CultureInfo]::InvariantCulture)
}

function Get-SplatplostDriverVer {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $text = Get-Content -LiteralPath $Path -Raw
    $pattern = '(?im)^[ \t]*DriverVer[ \t]*=[ \t]*(?<date>[0-9]{2}/[0-9]{2}/[0-9]{4})[ \t]*,[ \t]*(?<version>[0-9]+(?:\.[0-9]+){3})[ \t]*(?=\r?$)'
    $matches = @([regex]::Matches($text, $pattern))
    if ($matches.Count -ne 1) {
        throw "Expected exactly one valid DriverVer directive in $Path."
    }

    return [pscustomobject]@{
        Date = Resolve-SplatplostDriverDate -Value $matches[0].Groups['date'].Value
        Version = Resolve-SplatplostDriverVersion -Value $matches[0].Groups['version'].Value
    }
}

function Set-SplatplostDriverVer {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Version,
        [Parameter(Mandatory = $true)]
        [string]$Date
    )

    $resolvedVersion = Resolve-SplatplostDriverVersion -Value $Version
    $resolvedDate = Resolve-SplatplostDriverDate -Value $Date
    $text = Get-Content -LiteralPath $Path -Raw
    $pattern = '(?im)^(?<prefix>[ \t]*DriverVer[ \t]*=[ \t]*)(?<value>[^\r\n]*)(?=\r?$)'
    $matches = @([regex]::Matches($text, $pattern))
    if ($matches.Count -ne 1) {
        throw "Expected exactly one DriverVer directive in $Path."
    }

    $match = $matches[0]
    $replacement = $match.Groups['prefix'].Value + $resolvedDate + ',' + $resolvedVersion
    $stamped = $text.Substring(0, $match.Index) + $replacement + $text.Substring($match.Index + $match.Length)
    Set-Content -LiteralPath $Path -Value $stamped -Encoding ASCII -NoNewline
}

$requestedDriverVersion = if ([string]::IsNullOrWhiteSpace($DriverVersion)) {
    $null
} else {
    Resolve-SplatplostDriverVersion -Value $DriverVersion
}
$requestedDriverDate = if ([string]::IsNullOrWhiteSpace($DriverDate)) {
    $null
} else {
    Resolve-SplatplostDriverDate -Value $DriverDate
}

$source = & (Join-Path $PSScriptRoot "prepare-driver.ps1")
$source = $source[-1]

$preparedInx = Join-Path $source "bluetooth\bthecho\bthsrv\sys\SplatplostBluetooth.inx"
$templateDriverVer = Get-SplatplostDriverVer -Path $preparedInx
$effectiveDriverVersion = if ($requestedDriverVersion) { $requestedDriverVersion } else { $templateDriverVer.Version }
$effectiveDriverDate = if ($requestedDriverDate) {
    $requestedDriverDate
} else {
    [DateTime]::UtcNow.ToString("MM/dd/yyyy", [Globalization.CultureInfo]::InvariantCulture)
}
Set-SplatplostDriverVer -Path $preparedInx -Version $effectiveDriverVersion -Date $effectiveDriverDate

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw "Visual Studio Installer was not found." }
$msbuild = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find MSBuild\**\Bin\amd64\MSBuild.exe | Select-Object -First 1
if (-not $msbuild) {
    $msbuild = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find MSBuild\**\Bin\MSBuild.exe | Select-Object -First 1
}
if (-not $msbuild) { throw "MSBuild was not found." }

$base = Join-Path $source "bluetooth\bthecho"
$properties = @(
    "/p:Configuration=$Configuration",
    "/p:Platform=$Platform",
    "/p:SignMode=Off",
    "/p:Inf2CatUseLocalTime=true",
    "/p:RunCodeAnalysis=true",
    "/m",
    "/nologo"
)

& $msbuild (Join-Path $base "common\lib\bthecho.vcxproj") @properties
if ($LASTEXITCODE -ne 0) { throw "The Bluetooth support library build failed." }
& $msbuild (Join-Path $base "bthsrv\sys\BthEchoSampleSrv.vcxproj") @properties
if ($LASTEXITCODE -ne 0) { throw "The Splatplost Bluetooth driver build failed." }

$output = [IO.Path]::GetFullPath($Output)
New-Item -ItemType Directory -Force -Path $output | Out-Null

$driverBuildDirectory = Join-Path $base "bthsrv\sys\$Platform\$Configuration"
$driver = Get-Item -LiteralPath (Join-Path $driverBuildDirectory "SplatplostBluetooth.sys") -ErrorAction SilentlyContinue
$inf = Get-Item -LiteralPath (Join-Path $driverBuildDirectory "SplatplostBluetooth.inf") -ErrorAction SilentlyContinue
$symbols = Get-Item -LiteralPath (Join-Path $driverBuildDirectory "SplatplostBluetooth.pdb") -ErrorAction SilentlyContinue
if (-not $driver -or -not $inf -or -not $symbols) {
    throw "One or more exact $Configuration/$Platform driver build outputs could not be located."
}

# Remove only files this build owns. This prevents a catalog or development
# certificate from an older build being mistaken for the current package.
@(
    "SplatplostBluetooth.sys",
    "SplatplostBluetooth.pdb",
    "SplatplostBluetooth.inf",
    "SplatplostBluetooth.cat",
    "SplatplostDevelopment.cer",
    "SplatplostBluetoothService.exe",
    "SplatplostBluetooth-build-manifest.json"
) | ForEach-Object {
    Remove-Item -LiteralPath (Join-Path $output $_) -Force -ErrorAction SilentlyContinue
}

Copy-Item -Force $driver.FullName (Join-Path $output "SplatplostBluetooth.sys")
Copy-Item -Force $symbols.FullName (Join-Path $output "SplatplostBluetooth.pdb")
Copy-Item -Force $inf.FullName (Join-Path $output "SplatplostBluetooth.inf")
Copy-Item -Force (Join-Path $PSScriptRoot "install-driver.ps1") $output
Copy-Item -Force (Join-Path $PSScriptRoot "install-driver.cmd") $output
Copy-Item -Force (Join-Path $PSScriptRoot "uninstall-driver.ps1") $output
Copy-Item -Force (Join-Path $PSScriptRoot "uninstall-driver.cmd") $output
Copy-Item -Force (Join-Path $PSScriptRoot "verify-runtime.ps1") $output
Copy-Item -Force (Join-Path $PSScriptRoot "THIRD_PARTY_NOTICES.md") $output

$manifestFileNames = @(
    "SplatplostBluetooth.sys",
    "SplatplostBluetooth.pdb",
    "SplatplostBluetooth.inf",
    "install-driver.ps1",
    "install-driver.cmd",
    "uninstall-driver.ps1",
    "uninstall-driver.cmd",
    "verify-runtime.ps1",
    "THIRD_PARTY_NOTICES.md"
)
$builtDriverVer = Get-SplatplostDriverVer -Path (Join-Path $output "SplatplostBluetooth.inf")
if ($builtDriverVer.Version -ne $effectiveDriverVersion -or $builtDriverVer.Date -ne $effectiveDriverDate) {
    throw "The built INF DriverVer does not match the requested stamp."
}
$buildManifest = [ordered]@{
    schemaVersion = 1
    generatedAtUtc = [DateTime]::UtcNow.ToString("o")
    upstreamCommit = "2ee527bfeb0aeb6be11f0a8b6dce4011b358ce89"
    configuration = $Configuration
    platform = $Platform
    driverDate = $builtDriverVer.Date
    driverVersion = $builtDriverVer.Version
    driverVer = "$($builtDriverVer.Date),$($builtDriverVer.Version)"
    files = @($manifestFileNames | ForEach-Object {
        $path = Join-Path $output $_
        [ordered]@{
            name = $_
            sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
}
$buildManifest | ConvertTo-Json -Depth 5 | Set-Content `
    -LiteralPath (Join-Path $output "SplatplostBluetooth-build-manifest.json") `
    -Encoding UTF8

Write-Output $output
