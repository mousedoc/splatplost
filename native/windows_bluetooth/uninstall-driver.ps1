$ErrorActionPreference = "Stop"
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this uninstaller from an Administrator PowerShell window."
}

$package = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $package "SplatplostBluetoothService.exe") /u

$parametersKey = "HKLM:\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters"
$statePath = Join-Path $env:ProgramData "Splatplost\bluetooth-state.json"
if (Test-Path $statePath) {
    $state = Get-Content -Raw $statePath | ConvertFrom-Json
    if ($state.HadCodMajor) {
        New-ItemProperty -Path $parametersKey -Name "COD Major" -PropertyType DWord -Value $state.CodMajor -Force | Out-Null
    } else {
        Remove-ItemProperty -Path $parametersKey -Name "COD Major" -ErrorAction SilentlyContinue
    }
    if ($state.HadCodType) {
        New-ItemProperty -Path $parametersKey -Name "COD Type" -PropertyType DWord -Value $state.CodType -Force | Out-Null
    } else {
        Remove-ItemProperty -Path $parametersKey -Name "COD Type" -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $statePath -Force
}

Write-Host "Splatplost Bluetooth was disabled and the original Bluetooth class was restored. Restart Windows."
