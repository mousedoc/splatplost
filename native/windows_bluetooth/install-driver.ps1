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
$serviceInstaller = Join-Path $package "SplatplostBluetoothService.exe"
$inf = Join-Path $package "SplatplostBluetooth.inf"
$serviceGuid = "{f6fd1f11-2d8a-4ce4-8794-261e461e6c53}"
$hardwareId = "BTHENUM\$serviceGuid"
$bridgePath = "\\.\SplatplostBluetooth"

if (-not ("Splatplost.NativeStatus" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace Splatplost
{
    public static class NativeStatus
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct SystemCodeIntegrityInformation
        {
            public uint Length;
            public uint CodeIntegrityOptions;
        }

        [DllImport("ntdll.dll")]
        private static extern int NtQuerySystemInformation(
            int informationClass,
            ref SystemCodeIntegrityInformation information,
            int informationLength,
            out int returnLength);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateFile(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);

        public static bool IsTestSigningEnabled()
        {
            SystemCodeIntegrityInformation information = new SystemCodeIntegrityInformation();
            information.Length = (uint)Marshal.SizeOf(information);
            int returnLength;
            int status = NtQuerySystemInformation(103, ref information, (int)information.Length, out returnLength);
            if (status < 0)
            {
                throw new InvalidOperationException("Unable to read the current Windows code-integrity mode.");
            }
            return (information.CodeIntegrityOptions & 0x02) != 0;
        }

        public static int ProbeBridge(string path)
        {
            IntPtr handle = CreateFile(path, 0xC0000000, 0x00000003, IntPtr.Zero, 3, 0, IntPtr.Zero);
            if (handle == new IntPtr(-1))
            {
                return Marshal.GetLastWin32Error();
            }
            CloseHandle(handle);
            return 0;
        }
    }
}
"@
}

if (-not (Test-Path $serviceInstaller) -or -not (Test-Path $inf)) {
    throw "The driver package is incomplete. Extract the complete Windows release ZIP and try again."
}

if (Test-Path $certificate) {
    $secureBoot = $false
    try { $secureBoot = Confirm-SecureBootUEFI } catch { }
    if ($secureBoot) {
        throw "Secure Boot is enabled. A development-signed driver cannot load; use a Microsoft-signed release driver."
    }

    $testSigningActive = [Splatplost.NativeStatus]::IsTestSigningEnabled()
    if ($EnableTestSigning -and -not $testSigningActive) {
        & "$env:SystemRoot\System32\bcdedit.exe" /set testsigning on | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Windows test-signing mode could not be enabled." }
        Write-Warning "Test-signing mode was enabled. Restart Windows, then run this script again."
        return
    }
    if (-not $testSigningActive) {
        throw "Windows test-signing mode is not active. Run .\install-driver.ps1 -EnableTestSigning, restart Windows, then run .\install-driver.ps1 again."
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

# Register the local profile first. BthEnum creates the PDO only after this call.
& $serviceInstaller /i
$serviceExitCode = $LASTEXITCODE
if ($serviceExitCode -ne 0) {
    throw "The local Bluetooth controller profile could not be registered (exit code $serviceExitCode)."
}

& "$env:SystemRoot\System32\pnputil.exe" /scan-devices | Out-Host
$scanExitCode = $LASTEXITCODE
if ($scanExitCode -notin @(0, 3010, 1641)) {
    throw "Windows could not rescan Bluetooth devices (PnPUtil exit code $scanExitCode)."
}

& "$env:SystemRoot\System32\pnputil.exe" /add-driver $inf /install | Out-Host
$pnputilExitCode = $LASTEXITCODE

# 259 means that the matching device already has the best driver. 3010/1641
# mean that installation succeeded but a restart is required or in progress.
if ($pnputilExitCode -notin @(0, 259, 3010, 1641)) {
    throw "Windows rejected the Splatplost Bluetooth driver package (PnPUtil exit code $pnputilExitCode)."
}
$restartRequired = $pnputilExitCode -in @(3010, 1641) -or $scanExitCode -in @(3010, 1641)
if ($pnputilExitCode -eq 259) {
    Write-Host "The Splatplost Bluetooth driver is already staged and current. Continuing."
}

$devices = @(Get-PnpDevice -PresentOnly -InstanceId "$hardwareId*" -ErrorAction SilentlyContinue)
if ($devices.Count -eq 0) {
    throw "The Bluetooth profile was registered, but Windows did not create its device. Restart Bluetooth or Windows and run this installer again."
}

foreach ($device in $devices) {
    & "$env:SystemRoot\System32\pnputil.exe" /restart-device $device.InstanceId | Out-Host
    $restartExitCode = $LASTEXITCODE
    if ($restartExitCode -in @(3010, 1641)) {
        $restartRequired = $true
    } elseif ($restartExitCode -ne 0) {
        throw "Windows could not restart the Splatplost Bluetooth device (PnPUtil exit code $restartExitCode)."
    }
}

Start-Sleep -Milliseconds 500
$device = Get-PnpDevice -PresentOnly -InstanceId "$hardwareId*" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $device) {
    throw "The Splatplost Bluetooth device disappeared while Windows was starting it. Restart Windows and run this installer again."
}

$driverService = (Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName "DEVPKEY_Device_Service" -ErrorAction SilentlyContinue).Data
$problemCode = (Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName "DEVPKEY_Device_ProblemCode" -ErrorAction SilentlyContinue).Data
$problemStatus = (Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName "DEVPKEY_Device_ProblemStatus" -ErrorAction SilentlyContinue).Data
if ($driverService -ne "SplatplostBluetooth") {
    throw "Windows did not bind the Splatplost driver to the Bluetooth profile device (active service: '$driverService')."
}

if ($null -ne $problemCode -and [int]$problemCode -ne 0 -and [int]$problemCode -ne 14) {
    if ([int]$problemCode -eq 52) {
        throw "Windows blocked the development driver signature (Device Manager code 52). Confirm that Secure Boot is off, test-signing mode is active, and Windows was restarted."
    }
    $problemStatusText = if ($null -eq $problemStatus) { "unknown" } else { "0x{0:X8}" -f [uint32]$problemStatus }
    throw "The Splatplost Bluetooth driver could not start (Device Manager problem code $problemCode, NTSTATUS $problemStatusText, status $($device.Status))."
}
if ([int]$problemCode -eq 14) {
    $restartRequired = $true
}

$bridgeError = [Splatplost.NativeStatus]::ProbeBridge($bridgePath)
if ($bridgeError -eq 32) {
    Write-Host "The driver bridge is already open by another Splatplost process."
} elseif ($bridgeError -ne 0 -and -not $restartRequired) {
    throw "The driver device started, but its application bridge is unavailable (Windows error $bridgeError)."
}

if ($restartRequired -or $bridgeError -ne 0) {
    Write-Warning "Windows must be restarted before the first pairing."
} else {
    Write-Host "The Splatplost Bluetooth driver is installed and ready."
}
