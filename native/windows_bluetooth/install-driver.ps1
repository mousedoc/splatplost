param(
    [switch]$EnableTestSigning
)

$ErrorActionPreference = "Stop"
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this installer from an Administrator PowerShell window."
}

$package = Split-Path -Parent $MyInvocation.MyCommand.Path
$certificate = Join-Path $package "SplatplostDevelopment.cer"
if (Test-Path $certificate) {
    if ($EnableTestSigning) {
        $secureBoot = $false
        try { $secureBoot = Confirm-SecureBootUEFI } catch { }
        if ($secureBoot) {
            throw "Secure Boot is enabled. A development-signed driver cannot load; use a Microsoft-signed release driver."
        }
        bcdedit /set testsigning on | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Windows test-signing mode could not be enabled." }
        Write-Warning "Test-signing mode was enabled. Restart Windows, then run this script again without -EnableTestSigning."
        return
    }
    Import-Certificate -FilePath $certificate -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
    Import-Certificate -FilePath $certificate -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null
}

$parametersKey = "HKLM:\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters"
$stateDirectory = Join-Path $env:ProgramData "Splatplost"
$statePath = Join-Path $stateDirectory "bluetooth-state.json"
New-Item -ItemType Directory -Force -Path $stateDirectory | Out-Null

if (-not (Test-Path $statePath)) {
    $properties = Get-ItemProperty -Path $parametersKey
    $state = [ordered]@{
        HadCodMajor = $null -ne $properties.'COD Major'
        CodMajor = $properties.'COD Major'
        HadCodType = $null -ne $properties.'COD Type'
        CodType = $properties.'COD Type'
    }
    $state | ConvertTo-Json | Set-Content -Encoding UTF8 $statePath
}

# Bluetooth Peripheral / Gamepad. HID service registration supplies the service bits.
New-ItemProperty -Path $parametersKey -Name "COD Major" -PropertyType DWord -Value 5 -Force | Out-Null
New-ItemProperty -Path $parametersKey -Name "COD Type" -PropertyType DWord -Value 2 -Force | Out-Null

pnputil /add-driver (Join-Path $package "SplatplostBluetooth.inf") /install | Out-Host
if ($LASTEXITCODE -ne 0) { throw "Windows rejected the Splatplost Bluetooth driver package." }
& (Join-Path $package "SplatplostBluetoothService.exe") /i
if ($LASTEXITCODE -ne 0) { throw "The local Bluetooth controller service could not be enabled." }

Write-Host "Splatplost Bluetooth was installed. Restart Windows before the first pairing."
