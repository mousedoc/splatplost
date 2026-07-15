$ErrorActionPreference = "Stop"
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this uninstaller from an Administrator PowerShell window."
}
if (-not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) {
    throw "The Splatplost Bluetooth uninstaller requires a 64-bit PowerShell process on 64-bit Windows."
}

$operationMutex = [Threading.Mutex]::new(
    $false,
    "Global\SplatplostWindowsBluetoothDriverOperation-v1"
)
$operationMutexAcquired = $false
try {
    try {
        $operationMutexAcquired = $operationMutex.WaitOne(0)
    } catch [Threading.AbandonedMutexException] {
        $operationMutexAcquired = $true
        Write-Warning "Recovered an abandoned Splatplost driver-operation lock."
    }
    if (-not $operationMutexAcquired) {
        throw "Another Splatplost driver install or uninstall operation is already running. Wait for it to finish and retry."
    }

if (-not ("Splatplost.LocalProfile" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace Splatplost
{
    public static class LocalProfile
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct Luid
        {
            public uint LowPart;
            public int HighPart;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct TokenPrivileges
        {
            public uint PrivilegeCount;
            public Luid Luid;
            public uint Attributes;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct BluetoothLocalServiceInfo
        {
            [MarshalAs(UnmanagedType.Bool)]
            public bool Enabled;
            public ulong BluetoothAddress;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
            public string Name;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
            public string DeviceString;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct BluetoothFindRadioParams
        {
            public uint Size;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct BluetoothRadioInfo
        {
            public uint Size;
            public ulong Address;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 248)]
            public string Name;
            public uint ClassOfDevice;
            public ushort LmpSubversion;
            public ushort Manufacturer;
        }

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetCurrentProcess();

        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll")]
        private static extern void SetLastError(uint errorCode);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool OpenProcessToken(
            IntPtr processHandle,
            uint desiredAccess,
            out IntPtr tokenHandle);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool LookupPrivilegeValue(
            string systemName,
            string name,
            out Luid luid);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool AdjustTokenPrivileges(
            IntPtr tokenHandle,
            bool disableAllPrivileges,
            ref TokenPrivileges newState,
            uint bufferLength,
            IntPtr previousState,
            IntPtr returnLength);

        [DllImport("BluetoothApis.dll", CharSet = CharSet.Unicode)]
        private static extern uint BluetoothSetLocalServiceInfo(
            IntPtr radio,
            ref Guid classGuid,
            uint instance,
            ref BluetoothLocalServiceInfo serviceInfo);

        [DllImport("BluetoothApis.dll", SetLastError = true)]
        private static extern IntPtr BluetoothFindFirstRadio(
            ref BluetoothFindRadioParams parameters,
            out IntPtr radio);

        [DllImport("BluetoothApis.dll", SetLastError = true)]
        private static extern bool BluetoothFindNextRadio(
            IntPtr findHandle,
            out IntPtr radio);

        [DllImport("BluetoothApis.dll")]
        private static extern bool BluetoothFindRadioClose(IntPtr findHandle);

        [DllImport("BluetoothApis.dll")]
        private static extern uint BluetoothGetRadioInfo(
            IntPtr radio,
            ref BluetoothRadioInfo info);

        private static uint OpenOnlyRadio(
            out IntPtr selectedRadio,
            out ulong radioAddress,
            out uint radioCount)
        {
            const int ERROR_NO_MORE_ITEMS = 259;
            const uint ERROR_MORE_DATA = 234;
            selectedRadio = IntPtr.Zero;
            radioAddress = 0;
            radioCount = 0;

            BluetoothFindRadioParams parameters = new BluetoothFindRadioParams();
            parameters.Size = (uint)Marshal.SizeOf(parameters);
            IntPtr firstRadio;
            IntPtr findHandle = BluetoothFindFirstRadio(ref parameters, out firstRadio);
            if (findHandle == IntPtr.Zero)
            {
                return unchecked((uint)Marshal.GetLastWin32Error());
            }
            try
            {
                BluetoothRadioInfo info = new BluetoothRadioInfo();
                info.Size = (uint)Marshal.SizeOf(info);
                uint infoResult = BluetoothGetRadioInfo(firstRadio, ref info);
                if (infoResult != 0)
                {
                    CloseHandle(firstRadio);
                    return infoResult;
                }
                radioCount = 1;
                radioAddress = info.Address;

                IntPtr secondRadio;
                if (BluetoothFindNextRadio(findHandle, out secondRadio))
                {
                    radioCount = 2;
                    CloseHandle(secondRadio);
                    CloseHandle(firstRadio);
                    return ERROR_MORE_DATA;
                }
                int enumerationError = Marshal.GetLastWin32Error();
                if (enumerationError != 0 && enumerationError != ERROR_NO_MORE_ITEMS)
                {
                    CloseHandle(firstRadio);
                    return unchecked((uint)enumerationError);
                }
                selectedRadio = firstRadio;
                return 0;
            }
            finally
            {
                BluetoothFindRadioClose(findHandle);
            }
        }

        public static uint SetEnabled(
            string serviceGuid,
            bool enabled,
            ulong expectedRadioAddress,
            out ulong actualRadioAddress,
            out uint radioCount)
        {
            const uint TOKEN_ADJUST_PRIVILEGES = 0x20;
            const uint TOKEN_QUERY = 0x08;
            const uint SE_PRIVILEGE_ENABLED = 0x02;
            const uint ERROR_NOT_FOUND = 1168;

            actualRadioAddress = 0;
            radioCount = 0;

            IntPtr token;
            if (!OpenProcessToken(
                GetCurrentProcess(),
                TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY,
                out token))
            {
                return unchecked((uint)Marshal.GetLastWin32Error());
            }
            try
            {
                Luid luid;
                if (!LookupPrivilegeValue(null, "SeLoadDriverPrivilege", out luid))
                {
                    return unchecked((uint)Marshal.GetLastWin32Error());
                }
                TokenPrivileges privileges = new TokenPrivileges();
                privileges.PrivilegeCount = 1;
                privileges.Luid = luid;
                privileges.Attributes = SE_PRIVILEGE_ENABLED;
                SetLastError(0);
                if (!AdjustTokenPrivileges(
                    token,
                    false,
                    ref privileges,
                    (uint)Marshal.SizeOf(privileges),
                    IntPtr.Zero,
                    IntPtr.Zero))
                {
                    return unchecked((uint)Marshal.GetLastWin32Error());
                }
                int privilegeError = Marshal.GetLastWin32Error();
                if (privilegeError != 0)
                {
                    return unchecked((uint)privilegeError);
                }

                Guid guid = new Guid(serviceGuid);
                IntPtr radio;
                uint radioResult = OpenOnlyRadio(
                    out radio,
                    out actualRadioAddress,
                    out radioCount);
                if (radioResult != 0)
                {
                    return radioResult;
                }
                if (expectedRadioAddress != 0 && actualRadioAddress != expectedRadioAddress)
                {
                    CloseHandle(radio);
                    return ERROR_NOT_FOUND;
                }
                BluetoothLocalServiceInfo serviceInfo = new BluetoothLocalServiceInfo();
                serviceInfo.Enabled = enabled;
                serviceInfo.BluetoothAddress = 0;
                serviceInfo.Name = "Pro Controller";
                serviceInfo.DeviceString = String.Empty;
                try
                {
                    return BluetoothSetLocalServiceInfo(
                        radio,
                        ref guid,
                        0,
                        ref serviceInfo);
                }
                finally
                {
                    CloseHandle(radio);
                }
            }
            finally
            {
                CloseHandle(token);
            }
        }
    }
}
"@
}

$hardwareId = "BTHENUM\{f6fd1f11-2d8a-4ce4-8794-261e461e6c53}"
$parametersKey = "HKLM:\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters"
$stateKey = "HKLM:\SOFTWARE\Splatplost"
$pendingStateKey = "HKLM:\SOFTWARE\SplatplostDriverPendingInstall"

function Format-NativeStatus {
    param([Parameter(Mandatory = $true)][uint32]$Code)

    $hex = "0x{0:X8}" -f $Code
    if ($Code -le [uint32][int]::MaxValue) {
        try {
            $message = [ComponentModel.Win32Exception]::new([int]$Code).Message
            return "$Code ($hex, $message)"
        } catch {
            # Some Bluetooth APIs return NTSTATUS values rather than Win32 errors.
        }
    }
    return $hex
}

function Get-SplatplostPresentDevices {
    param([Parameter(Mandatory = $true)][string]$InstanceIdPattern)

    # Query every present device with terminating errors, then filter locally.
    # Suppressing Get-PnpDevice's wildcard no-match error would also suppress
    # real provider failures and could falsely prove that profile removal was
    # complete before development trust is removed.
    $presentDevices = @(Get-PnpDevice -PresentOnly -ErrorAction Stop)
    return @($presentDevices | Where-Object {
        [string]$_.InstanceId -like $InstanceIdPattern
    })
}

$state = if (Test-Path -LiteralPath $stateKey) {
    Get-ItemProperty -LiteralPath $stateKey
} else {
    $null
}
$pendingState = if (Test-Path -LiteralPath $pendingStateKey) {
    Get-ItemProperty -LiteralPath $pendingStateKey
} else {
    $null
}

function Get-StateValue {
    param([Parameter(Mandatory = $true)][string]$Name)

    if ($state) {
        $property = $state.PSObject.Properties[$Name]
        if ($property) { return $property.Value }
    }
    return $null
}

function Get-PendingStateValue {
    param([Parameter(Mandatory = $true)][string]$Name)

    if ($pendingState) {
        $property = $pendingState.PSObject.Properties[$Name]
        if ($property) { return $property.Value }
    }
    return $null
}

function Add-OwnedDevelopmentCertificateRecord {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Records,
        [Parameter(Mandatory = $true)][string]$Thumbprint,
        [bool]$RootOwned,
        [bool]$PublisherOwned
    )

    if ($Thumbprint -notmatch '^[0-9A-Fa-f]{40,64}$') { return }
    $normalized = $Thumbprint.ToUpperInvariant()
    if (-not $Records.ContainsKey($normalized)) {
        $Records[$normalized] = @{
            RootOwned = $false
            PublisherOwned = $false
        }
    }
    $Records[$normalized].RootOwned = [bool]($Records[$normalized].RootOwned -or $RootOwned)
    $Records[$normalized].PublisherOwned = [bool]($Records[$normalized].PublisherOwned -or $PublisherOwned)
}

function Test-SplatplostDevelopmentCertificate {
    param([Parameter(Mandatory = $true)]$Certificate)

    if ($Certificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -ne "Splatplost Development Driver") {
        return $false
    }
    $ekuOids = @($Certificate.Extensions |
        Where-Object { $_.Oid.Value -eq "2.5.29.37" } |
        ForEach-Object {
            $enhanced = [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]$_
            @($enhanced.EnhancedKeyUsages | ForEach-Object { $_.Value })
        })
    return $ekuOids -contains "1.3.6.1.5.5.7.3.3"
}

$ownedCertificates = @{}
if ($state) {
    $ownedProperty = $state.PSObject.Properties['OwnedDevelopmentCertificates']
    if ($ownedProperty) {
        foreach ($record in @($ownedProperty.Value)) {
            if ([string]$record -match '^(?<thumbprint>[0-9A-Fa-f]{40,64})\|(?<root>[01])\|(?<publisher>[01])$') {
                Add-OwnedDevelopmentCertificateRecord `
                    -Records $ownedCertificates `
                    -Thumbprint $Matches.thumbprint `
                    -RootOwned ([bool][int]$Matches.root) `
                    -PublisherOwned ([bool][int]$Matches.publisher)
            }
        }
    }

    # Backward compatibility with state created before certificate rotation was
    # represented as a MultiString list.
    Add-OwnedDevelopmentCertificateRecord `
        -Records $ownedCertificates `
        -Thumbprint ([string](Get-StateValue -Name "DevelopmentCertificateThumbprint")) `
        -RootOwned ([bool](Get-StateValue -Name "DevelopmentCertificateAddedToRoot")) `
        -PublisherOwned ([bool](Get-StateValue -Name "DevelopmentCertificateAddedToTrustedPublisher"))
}

if ($pendingState) {
    $pendingThumbprint = [string](Get-PendingStateValue -Name "DevelopmentCertificateThumbprint")
    $pendingPhase = [string](Get-PendingStateValue -Name "Phase")
    $rootBeforeProperty = $pendingState.PSObject.Properties['CertificateRootExistedBefore']
    $publisherBeforeProperty = $pendingState.PSObject.Properties['CertificatePublisherExistedBefore']
    if ($pendingThumbprint -match '^[0-9A-Fa-f]{40,64}$') {
        if (
            $pendingPhase -ne "prepared" -and
            (-not $rootBeforeProperty -or -not $publisherBeforeProperty)
        ) {
            throw "The interrupted install journal does not contain complete certificate ownership. Preserve it and remove the certificate manually after verifying its thumbprint."
        }
        if ($rootBeforeProperty -and $publisherBeforeProperty) {
            Add-OwnedDevelopmentCertificateRecord `
                -Records $ownedCertificates `
                -Thumbprint $pendingThumbprint `
                -RootOwned (-not [bool]$rootBeforeProperty.Value) `
                -PublisherOwned (-not [bool]$publisherBeforeProperty.Value)
        }
    }
}

function Test-SplatplostPublishedInfIdentity {
    param([Parameter(Mandatory = $true)][string]$InfName)

    if ($InfName -notmatch '^oem\d+\.inf$') { return $false }
    $path = Join-Path (Join-Path $env:SystemRoot "INF") $InfName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    $content = Get-Content -LiteralPath $path -Raw
    return [bool](
        $content.IndexOf($hardwareId, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        $content -match '(?im)^\s*AddService\s*=\s*SplatplostBluetooth\s*,' -and
        $content -match '(?im)^\s*ProviderString\s*=\s*"Splatplost"\s*$'
    )
}

function Get-SplatplostPublishedInfNames {
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($publishedInf in @(Get-ChildItem -LiteralPath (Join-Path $env:SystemRoot "INF") -Filter "oem*.inf" -File -Force)) {
        $name = $publishedInf.Name.ToLowerInvariant()
        if (Test-SplatplostPublishedInfIdentity -InfName $name) {
            [void]$names.Add($name)
        }
    }
    return $names
}

function Save-SplatplostUninstallRecoveryState {
    param(
        [Parameter(Mandatory = $true)][uint64]$RadioAddress,
        [Parameter(Mandatory = $true)][string[]]$RemainingInfNames
    )

    if (-not (Test-Path -LiteralPath $stateKey)) {
        New-Item -Path $stateKey -Force | Out-Null
    }
    New-ItemProperty -Path $stateKey -Name "StateVersion" -PropertyType DWord -Value 4 -Force | Out-Null
    New-ItemProperty -Path $stateKey -Name "InstallationKind" -PropertyType String -Value "uninstall-reboot-required" -Force | Out-Null
    if ($RadioAddress -ne 0) {
        New-ItemProperty -Path $stateKey -Name "InstalledRadioAddress" -PropertyType QWord -Value $RadioAddress -Force | Out-Null
    }
    if ($RemainingInfNames.Count -gt 0) {
        New-ItemProperty -Path $stateKey -Name "PendingRemovalInfNames" -PropertyType MultiString -Value $RemainingInfNames -Force | Out-Null
    } else {
        Remove-ItemProperty -LiteralPath $stateKey -Name "PendingRemovalInfNames" -ErrorAction SilentlyContinue
    }
}

function Get-SplatplostCodRestoreDecision {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$CurrentProperties,
        [Parameter(Mandatory = $true)][string]$RegistryValueName,
        [Parameter(Mandatory = $true)][string]$SnapshotPresenceName,
        [Parameter(Mandatory = $true)][string]$SnapshotValueName,
        [Parameter(Mandatory = $true)][int]$ManagedValue
    )

    $hadProperty = $State.PSObject.Properties[$SnapshotPresenceName]
    $snapshotProperty = $State.PSObject.Properties[$SnapshotValueName]
    if (-not $hadProperty -or ([bool]$hadProperty.Value -and -not $snapshotProperty)) {
        return [pscustomobject]@{
            Action = "incomplete-snapshot"
            RegistryValueName = $RegistryValueName
            SnapshotValue = $null
            CurrentValue = $null
        }
    }

    $currentProperty = $CurrentProperties.PSObject.Properties[$RegistryValueName]
    if (-not $currentProperty) {
        return [pscustomobject]@{
            Action = "preserve-missing"
            RegistryValueName = $RegistryValueName
            SnapshotValue = if ($snapshotProperty) { $snapshotProperty.Value } else { $null }
            CurrentValue = $null
        }
    }
    if ([int64]$currentProperty.Value -ne [int64]$ManagedValue) {
        return [pscustomobject]@{
            Action = "preserve-changed"
            RegistryValueName = $RegistryValueName
            SnapshotValue = if ($snapshotProperty) { $snapshotProperty.Value } else { $null }
            CurrentValue = $currentProperty.Value
        }
    }

    return [pscustomobject]@{
        Action = if ([bool]$hadProperty.Value) { "restore" } else { "remove" }
        RegistryValueName = $RegistryValueName
        SnapshotValue = if ($snapshotProperty) { $snapshotProperty.Value } else { $null }
        CurrentValue = $currentProperty.Value
    }
}

$recordedRadioAddresses = [Collections.Generic.HashSet[uint64]]::new()
foreach ($candidateAddress in @(
    (Get-StateValue -Name "InstalledRadioAddress"),
    (Get-PendingStateValue -Name "TargetRadioAddress")
)) {
    if ($null -ne $candidateAddress -and [uint64]$candidateAddress -ne 0) {
        [void]$recordedRadioAddresses.Add([uint64]$candidateAddress)
    }
}
if ($recordedRadioAddresses.Count -gt 1) {
    throw "Installed and pending recovery state refer to different Bluetooth radios. Preserve state and investigate before uninstalling."
}
[uint64]$expectedRadioAddress = if ($recordedRadioAddresses.Count -eq 1) {
    @($recordedRadioAddresses)[0]
} else {
    0
}
[uint64]$actualRadioAddress = 0
[uint32]$actualRadioCount = 0
$serviceExitCode = [uint32][Splatplost.LocalProfile]::SetEnabled(
    "{f6fd1f11-2d8a-4ce4-8794-261e461e6c53}",
    $false,
    $expectedRadioAddress,
    [ref]$actualRadioAddress,
    [ref]$actualRadioCount
)
if (
    $serviceExitCode -ne 0 -or
    $actualRadioCount -ne 1 -or
    $actualRadioAddress -eq 0 -or
    ($expectedRadioAddress -ne 0 -and $actualRadioAddress -ne $expectedRadioAddress)
) {
    throw "The exact installed Bluetooth radio must be enabled so its local profile can be removed ($(Format-NativeStatus -Code $serviceExitCode), radios $actualRadioCount). No package trust or state was removed."
}

$removalErrors = @()
$restartRequired = $false
& "$env:SystemRoot\System32\pnputil.exe" /scan-devices | Out-Host
$scanExitCode = $LASTEXITCODE
if ($scanExitCode -in @(3010, 1641)) {
    $restartRequired = $true
} elseif ($scanExitCode -ne 0) {
    $removalErrors += "Windows could not rescan devices while removing Splatplost (PnPUtil exit code $scanExitCode)."
}

$publishedInfNames = @(Get-SplatplostPublishedInfNames)
foreach ($publishedInfName in @($publishedInfNames)) {
    & "$env:SystemRoot\System32\pnputil.exe" /delete-driver $publishedInfName /uninstall /force | Out-Host
    $deleteExitCode = $LASTEXITCODE
    if ($deleteExitCode -in @(3010, 1641)) {
        $restartRequired = $true
    } elseif ($deleteExitCode -ne 0) {
        $removalErrors += "Windows could not remove Driver Store package $publishedInfName (PnPUtil exit code $deleteExitCode)."
    }
}

& "$env:SystemRoot\System32\pnputil.exe" /scan-devices | Out-Host
$finalScanExitCode = $LASTEXITCODE
if ($finalScanExitCode -in @(3010, 1641)) {
    $restartRequired = $true
} elseif ($finalScanExitCode -ne 0) {
    $removalErrors += "Windows could not perform the final device rescan (PnPUtil exit code $finalScanExitCode)."
}

$deadline = [DateTime]::UtcNow.AddSeconds(30)
do {
    $presentDevices = @(Get-SplatplostPresentDevices -InstanceIdPattern "$hardwareId*")
    if ($presentDevices.Count -eq 0) { break }
    Start-Sleep -Milliseconds 250
} while ([DateTime]::UtcNow -lt $deadline)
if ($presentDevices.Count -ne 0) {
    $removalErrors += "$($presentDevices.Count) Splatplost profile device(s) are still present after profile removal."
}

$remainingInfNames = @(Get-SplatplostPublishedInfNames)
if ($remainingInfNames.Count -ne 0) {
    $removalErrors += "Verified Splatplost Driver Store packages remain: $(@($remainingInfNames) -join ', ')"
}

if ($restartRequired -or $removalErrors.Count -ne 0) {
    Save-SplatplostUninstallRecoveryState `
        -RadioAddress $actualRadioAddress `
        -RemainingInfNames @($remainingInfNames)
    $detail = if ($removalErrors.Count -ne 0) { $removalErrors -join '; ' } else { "Windows reported that a restart is required." }
    throw "Splatplost removal is not yet proven complete. $detail Restart Windows, keep the development trust/state in place, and run uninstall-driver.cmd again."
}

$hadCodMajorProperty = if ($state) { $state.PSObject.Properties['HadCodMajor'] } else { $null }
$hadCodTypeProperty = if ($state) { $state.PSObject.Properties['HadCodType'] } else { $null }
$codMajorProperty = if ($state) { $state.PSObject.Properties['CodMajor'] } else { $null }
$codTypeProperty = if ($state) { $state.PSObject.Properties['CodType'] } else { $null }
$hasCompleteCodSnapshot = [bool](
    $state -and
    $hadCodMajorProperty -and
    $hadCodTypeProperty -and
    (-not [bool]$hadCodMajorProperty.Value -or $codMajorProperty) -and
    (-not [bool]$hadCodTypeProperty.Value -or $codTypeProperty)
)
if ($hasCompleteCodSnapshot) {
    $currentCodProperties = Get-ItemProperty -LiteralPath $parametersKey -ErrorAction Stop
    $codRestoreDecisions = @(
        Get-SplatplostCodRestoreDecision `
            -State $state `
            -CurrentProperties $currentCodProperties `
            -RegistryValueName "COD Major" `
            -SnapshotPresenceName "HadCodMajor" `
            -SnapshotValueName "CodMajor" `
            -ManagedValue 5
        Get-SplatplostCodRestoreDecision `
            -State $state `
            -CurrentProperties $currentCodProperties `
            -RegistryValueName "COD Type" `
            -SnapshotPresenceName "HadCodType" `
            -SnapshotValueName "CodType" `
            -ManagedValue 2
    )
    foreach ($decision in $codRestoreDecisions) {
        switch ($decision.Action) {
            "restore" {
                New-ItemProperty `
                    -Path $parametersKey `
                    -Name $decision.RegistryValueName `
                    -PropertyType DWord `
                    -Value ([int]$decision.SnapshotValue) `
                    -Force | Out-Null
            }
            "remove" {
                Remove-ItemProperty `
                    -LiteralPath $parametersKey `
                    -Name $decision.RegistryValueName `
                    -ErrorAction Stop
            }
            "preserve-missing" {
                Write-Warning "$($decision.RegistryValueName) is now missing, so its external post-install change is preserved instead of applying the pre-install snapshot."
            }
            "preserve-changed" {
                Write-Warning "$($decision.RegistryValueName) is now $($decision.CurrentValue), so its external post-install change is preserved instead of applying the pre-install snapshot."
            }
            default {
                throw "The Class-of-Device restore decision is invalid for $($decision.RegistryValueName): $($decision.Action)"
            }
        }
    }

    $verifiedCodProperties = Get-ItemProperty -LiteralPath $parametersKey -ErrorAction Stop
    foreach ($decision in @($codRestoreDecisions | Where-Object { $_.Action -in @("restore", "remove") })) {
        $verifiedProperty = $verifiedCodProperties.PSObject.Properties[$decision.RegistryValueName]
        if (
            ($decision.Action -eq "restore" -and (
                -not $verifiedProperty -or
                [int64]$verifiedProperty.Value -ne [int64]$decision.SnapshotValue
            )) -or
            ($decision.Action -eq "remove" -and $verifiedProperty)
        ) {
            throw "The pre-install Class-of-Device state was not restored exactly for $($decision.RegistryValueName)."
        }
    }
} elseif ($state) {
    Write-Warning "No complete pre-install Bluetooth Class-of-Device snapshot exists; leaving the current global COD values unchanged."
}

$certificateErrors = @()
foreach ($certificateThumbprint in @($ownedCertificates.Keys)) {
    $ownership = $ownedCertificates[$certificateThumbprint]
    foreach ($certificateTarget in @(
        [pscustomobject]@{ Owned = [bool]$ownership.RootOwned; Path = "Cert:\LocalMachine\Root\$certificateThumbprint"; Name = "Root" },
        [pscustomobject]@{ Owned = [bool]$ownership.PublisherOwned; Path = "Cert:\LocalMachine\TrustedPublisher\$certificateThumbprint"; Name = "TrustedPublisher" }
    )) {
        if (-not $certificateTarget.Owned) { continue }
        $existingCertificate = Get-Item -LiteralPath $certificateTarget.Path -ErrorAction SilentlyContinue
        if ($existingCertificate) {
            if (-not (Test-SplatplostDevelopmentCertificate -Certificate $existingCertificate)) {
                $certificateErrors += "Refusing to remove a non-Splatplost certificate from $($certificateTarget.Name): $certificateThumbprint"
                continue
            }
            try {
                Remove-Item -LiteralPath $certificateTarget.Path -Force -ErrorAction Stop
            } catch {
                $certificateErrors += "$($certificateTarget.Name) certificate removal failed: $($_.Exception.Message)"
                continue
            }
            if (Test-Path -LiteralPath $certificateTarget.Path) {
                $certificateErrors += "$($certificateTarget.Name) certificate is still present after removal: $certificateThumbprint"
            }
        }
    }
}
if ($certificateErrors.Count -ne 0) {
    Save-SplatplostUninstallRecoveryState -RadioAddress $actualRadioAddress -RemainingInfNames @()
    throw "Driver/profile removal succeeded, but development trust cleanup is incomplete: $($certificateErrors -join '; '). Run uninstall-driver.cmd again."
}

if (Test-Path -LiteralPath $stateKey) {
    Remove-Item -LiteralPath $stateKey -Recurse -Force -ErrorAction Stop
}
if (Test-Path -LiteralPath $pendingStateKey) {
    Remove-Item -LiteralPath $pendingStateKey -Recurse -Force -ErrorAction Stop
}

Write-Host "Splatplost Bluetooth profile, every verified Driver Store package, owned development trust, and recovery state were removed."
} finally {
    if ($operationMutexAcquired) {
        $operationMutex.ReleaseMutex()
    }
    $operationMutex.Dispose()
}
