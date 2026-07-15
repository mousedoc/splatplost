param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:Failures = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$MessagePattern)

    try {
        & $Action
    } catch {
        if ($_.Exception.Message -match $MessagePattern) { return }
        throw "Expected error matching '$MessagePattern', but received: $($_.Exception.Message)"
    }
    throw "Expected an error matching '$MessagePattern', but no error was thrown."
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Action)

    try {
        & $Action
        Write-Host "PASS $Name"
    } catch {
        $script:Failures++
        Write-Host "FAIL $Name -- $($_.Exception.Message)"
    }
}

$buildScript = Join-Path $PSScriptRoot "build-driver.ps1"
$infTemplate = Join-Path $PSScriptRoot "SplatplostBluetooth.inx"
$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$workflow = Join-Path $repositoryRoot ".github\workflows\windows-build.yml"

# Load only the pure versioning functions. Dot-sourcing build-driver.ps1 would
# prepare and compile the WDK sample, which is intentionally outside this unit test.
$tokens = $null
$parseErrors = $null
$buildAst = [Management.Automation.Language.Parser]::ParseFile(
    $buildScript,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -ne 0) {
    throw "$buildScript has parser errors: $($parseErrors -join '; ')"
}
$requiredFunctions = @(
    "Resolve-SplatplostDriverVersion",
    "Resolve-SplatplostDriverDate",
    "Get-SplatplostDriverVer",
    "Set-SplatplostDriverVer"
)
$definitions = @($buildAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $requiredFunctions -contains $node.Name
}, $true))
if ($definitions.Count -ne $requiredFunctions.Count) {
    throw "Unable to locate every build-driver versioning function."
}
foreach ($definition in $definitions) {
    . ([scriptblock]::Create($definition.Extent.Text))
}

Invoke-Test "Windows driver versions are canonical and bounded" {
    Assert-True ((Resolve-SplatplostDriverVersion "1.2.3.4") -eq "1.2.3.4") "A valid version changed."
    Assert-True ((Resolve-SplatplostDriverVersion "65534.0.0.1") -eq "65534.0.0.1") "The documented maximum component was rejected."
    foreach ($invalid in @(
        "0.0.0.0",
        "1.2.3",
        "1.2.3.4.5",
        "01.2.3.4",
        "65535.0.0.1",
        "65536.0.0.1",
        "1.2.-3.4"
    )) {
        Assert-Throws -MessagePattern "DriverVersion|component|0\.0\.0\.0" -Action {
            Resolve-SplatplostDriverVersion $invalid | Out-Null
        }
    }
}

Invoke-Test "Windows driver dates use strict non-future UTC-safe notation" {
    Assert-True ((Resolve-SplatplostDriverDate "01/02/2024") -eq "01/02/2024") "A valid date changed."
    foreach ($invalid in @("1/02/2024", "02/30/2024", "2024-01-02", "12/31/9999")) {
        Assert-Throws -MessagePattern "DriverDate" -Action {
            Resolve-SplatplostDriverDate $invalid | Out-Null
        }
    }
}

Invoke-Test "prepared INX stamping changes exactly one DriverVer directive" {
    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("splatplost-version-test-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $temporaryRoot | Out-Null
    try {
        $inx = Join-Path $temporaryRoot "driver.inx"
        Copy-Item -LiteralPath $infTemplate -Destination $inx
        Set-SplatplostDriverVer -Path $inx -Version "2.4.6.8" -Date "01/02/2024"
        $identity = Get-SplatplostDriverVer -Path $inx
        Assert-True ($identity.Version -eq "2.4.6.8") "Stamped version was not recovered."
        Assert-True ($identity.Date -eq "01/02/2024") "Stamped date was not recovered."
        Assert-True (
            ([regex]::Matches((Get-Content -LiteralPath $inx -Raw), '(?im)^\s*DriverVer\s*=')).Count -eq 1
        ) "Stamping introduced multiple DriverVer directives."

        $duplicate = (Get-Content -LiteralPath $inx -Raw).TrimEnd("`r", "`n") +
            "`r`nDriverVer=01/02/2024,2.4.6.9`r`n"
        Set-Content -LiteralPath $inx -Value $duplicate -Encoding ASCII -NoNewline
        Assert-Throws -MessagePattern "exactly one DriverVer" -Action {
            Set-SplatplostDriverVer -Path $inx -Version "2.4.6.10" -Date "01/02/2024"
        }
    } finally {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "explicit identity validation precedes dependency preparation" {
    $source = Get-Content -LiteralPath $buildScript -Raw
    $versionValidation = $source.IndexOf('Resolve-SplatplostDriverVersion -Value $DriverVersion')
    $dateValidation = $source.IndexOf('Resolve-SplatplostDriverDate -Value $DriverDate')
    $prepare = $source.IndexOf('$source = & (Join-Path $PSScriptRoot "prepare-driver.ps1")')
    Assert-True ($versionValidation -ge 0 -and $versionValidation -lt $prepare) "DriverVersion is not rejected before preparing dependencies."
    Assert-True ($dateValidation -ge 0 -and $dateValidation -lt $prepare) "DriverDate is not rejected before preparing dependencies."
    Assert-True ($source.Contains('[DateTime]::UtcNow.ToString("MM/dd/yyyy"')) "The default build date is not the current UTC date."
    foreach ($field in @('driverDate = $builtDriverVer.Date', 'driverVersion = $builtDriverVer.Version', 'driverVer =')) {
        Assert-True ($source.Contains($field)) "Build manifest is missing the stamped identity field: $field"
    }
    Assert-True ($source.Contains('"/p:RunCodeAnalysis=true"')) "The WDK build does not run native code analysis."
}

Invoke-Test "tag and manual workflow builds supply validated driver identities" {
    $source = Get-Content -LiteralPath $workflow -Raw
    foreach ($required in @(
        'tags: ["v*.*.*"]',
        'driver_version:',
        'default: "0.3.1.0"',
        "Release tags must use canonical vX.Y.Z notation.",
        '$driverVersion = "$($Matches[''version'']).0"',
        '-DriverVersion $driverVersion',
        '-DriverDate $driverDate'
    )) {
        Assert-True ($source.Contains($required)) "Workflow version resolution is missing: $required"
    }
}

Invoke-Test "workflow uses current official action majors and idempotent release publishing" {
    $source = Get-Content -LiteralPath $workflow -Raw
    Assert-True ($source.Contains('actions/checkout@v7')) "checkout is not on v7."
    Assert-True ($source.Contains('actions/setup-python@v6')) "setup-python is not on v6."
    Assert-True ([regex]::Matches($source, 'actions/upload-artifact@v7').Count -eq 3) "Every artifact upload must use v7."
    foreach ($required in @('gh release view', 'gh release upload', '--clobber', 'gh release create')) {
        Assert-True ($source.Contains($required)) "Release rerun handling is missing: $required"
    }
    foreach ($required in @('--smoke-test', '--verify-windows-bluetooth', 'ci-application-evidence.json')) {
        Assert-True ($source.Contains($required)) "Packaged GUI/application acceptance smoke coverage is missing: $required"
    }
    Assert-True ($source.Contains('Get-FileHash -LiteralPath ".\dist\splatplost.exe" -Algorithm SHA256')) "Application evidence is not compared with the built executable hash."
    foreach ($required in @(
        'PowerShell 7',
        'Windows PowerShell 5.1',
        'System32\WindowsPowerShell\v1.0\powershell.exe',
        '-File $scriptPath'
    )) {
        Assert-True ($source.Contains($required)) "Dual PowerShell compatibility coverage is missing: $required"
    }
    foreach ($required in @(
        '[IO.BinaryReader]::new($stream)',
        '$machine -ne 0x8664',
        '$optionalMagic -ne 0x020B',
        '$subsystem -ne 2',
        'No-argument GUI exited prematurely',
        '/PID $guiProcess.Id /T /F'
    )) {
        Assert-True ($source.Contains($required)) "Packaged no-argument GUI/PE validation is missing: $required"
    }
}

if ($script:Failures -ne 0) {
    throw "$script:Failures build versioning test(s) failed."
}

Write-Host "ALL TESTS PASSED"
