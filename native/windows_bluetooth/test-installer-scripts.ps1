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
        throw "Expected '$MessagePattern', received: $($_.Exception.Message)"
    }
    throw "Expected '$MessagePattern', but no error was thrown."
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Action)
    try {
        & $Action
        Write-Host "PASS $Name"
    } catch {
        $script:Failures++
        Write-Host "FAIL $Name -- $($_.Exception.Message) -- $($_.ScriptStackTrace)"
    }
}

$install = Join-Path $PSScriptRoot "install-driver.ps1"
$uninstall = Join-Path $PSScriptRoot "uninstall-driver.ps1"
$build = Join-Path $PSScriptRoot "build-driver.ps1"
$prepare = Join-Path $PSScriptRoot "prepare-driver.ps1"
$infTemplate = Join-Path $PSScriptRoot "SplatplostBluetooth.inx"

Invoke-Test "installer scripts parse without errors" {
    foreach ($path in @($install, $uninstall, $build, $prepare, $PSCommandPath)) {
        $tokens = $null
        $errors = $null
        [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
        Assert-True ($errors.Count -eq 0) "$path has parser errors: $($errors -join '; ')"
    }
}

Invoke-Test "embedded native interop compiles with the expected ABI" {
    foreach ($path in @($install, $uninstall)) {
        $source = Get-Content -LiteralPath $path -Raw
        $match = [regex]::Match(
            $source,
            '(?s)Add-Type\s+-TypeDefinition\s+@"\r?\n(?<code>.*?)\r?\n"@'
        )
        Assert-True $match.Success "Could not locate the embedded C# definition in $path."
        Add-Type -TypeDefinition $match.Groups['code'].Value -Language CSharp
    }

    $installMethod = [Splatplost.NativeStatus].GetMethod('SetLocalServiceEnabled')
    $radioMethod = [Splatplost.NativeStatus].GetMethod('GetSingleRadioAddress')
    $driverStoreMethod = [Splatplost.NativeStatus].GetMethod('GetInfDriverStoreLocation')
    $uninstallMethod = [Splatplost.LocalProfile].GetMethod('SetEnabled')
    Assert-True ($installMethod.ReturnType -eq [uint32]) "Installer Bluetooth API return type is not DWORD/UInt32."
    Assert-True ($radioMethod.ReturnType -eq [uint32]) "Installer exact-radio enumeration API is missing."
    Assert-True ($driverStoreMethod.ReturnType -eq [string]) "SetupAPI Driver Store resolver is missing from the installer interop."
    Assert-True ($uninstallMethod.ReturnType -eq [uint32]) "Uninstaller Bluetooth API return type is not DWORD/UInt32."

    $flags = [Reflection.BindingFlags]::NonPublic -bor [Reflection.BindingFlags]::DeclaredOnly
    $installStruct = [Splatplost.NativeStatus].GetNestedType('BluetoothLocalServiceInfo', $flags)
    $uninstallStruct = [Splatplost.LocalProfile].GetNestedType('BluetoothLocalServiceInfo', $flags)
    Assert-True ($null -ne $installStruct -and $null -ne $uninstallStruct) "BLUETOOTH_LOCAL_SERVICE_INFO interop type is missing."
    Assert-True ([Runtime.InteropServices.Marshal]::SizeOf([type]$installStruct) -eq 1040) "Installer BLUETOOTH_LOCAL_SERVICE_INFO layout is not the x64 Windows SDK layout."
    Assert-True ([Runtime.InteropServices.Marshal]::SizeOf([type]$uninstallStruct) -eq 1040) "Uninstaller BLUETOOTH_LOCAL_SERVICE_INFO layout is not the x64 Windows SDK layout."
}

Invoke-Test "isolated installer signature copy stays byte-exact and pinned" {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($install, [ref]$tokens, [ref]$errors)
    foreach ($functionName in @(
        "Get-SplatplostReadOnlyStreamSha256",
        "Get-IsolatedAuthenticodeSignature"
    )) {
        $functionAst = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
        }, $true)
        Assert-True ($null -ne $functionAst) "$functionName was not found."
        . ([scriptblock]::Create($functionAst.Extent.Text))
    }

    $source = Get-Content -LiteralPath $install -Raw
    Assert-True ($source -match '\$sourcePin = \[Splatplost\.NativeStatus\]::OpenPinnedPackageFile') "The original SYS is not pinned during isolated signature verification."
    Assert-True ($source -match '\$copyPin = \[Splatplost\.NativeStatus\]::OpenPinnedPackageFile') "The isolated SYS copy is not pinned during Authenticode verification."
    Assert-True ($source -match 'FileMode\]::CreateNew') "The isolated copy is not created atomically."
    Assert-True ($source -match 'FileShare\]::None') "The isolated copy can be observed before it is complete."
    Assert-True ($source -match 'isolated signature copy does not exactly match its pinned source') "Source/copy byte identity is not checked."
    Assert-True ($source -match 'changed during Authenticode verification') "Source/copy byte identity is not rechecked after Authenticode verification."

    $temporary = Join-Path ([IO.Path]::GetTempPath()) ("splatplost-isolated-installer-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $temporary -Force | Out-Null
    try {
        $script:IsolatedSource = Join-Path $temporary "source.sys"
        $script:IsolatedReplacement = Join-Path $temporary "replacement.sys"
        Set-Content -LiteralPath $script:IsolatedSource -Value "signed-source-fixture" -Encoding ASCII
        Set-Content -LiteralPath $script:IsolatedReplacement -Value "replacement-fixture" -Encoding ASCII
        $sourceHash = (Get-FileHash -LiteralPath $script:IsolatedSource -Algorithm SHA256).Hash
        $script:IsolatedCopyPath = $null
        $script:IsolatedBlockedMutations = 0

        function Get-AuthenticodeSignature {
            [CmdletBinding()]
            param([Parameter(Mandatory = $true)][string]$LiteralPath)

            $script:IsolatedCopyPath = $LiteralPath
            foreach ($attack in @(
                { Set-Content -LiteralPath $LiteralPath -Value "write-attack" -Encoding ASCII },
                { Move-Item -LiteralPath $LiteralPath -Destination "$LiteralPath.renamed" },
                {
                    [IO.File]::Replace(
                        $script:IsolatedReplacement,
                        $LiteralPath,
                        "$LiteralPath.backup"
                    )
                },
                { Set-Content -LiteralPath $script:IsolatedSource -Value "source-write-attack" -Encoding ASCII }
            )) {
                $blocked = $false
                try {
                    & $attack
                } catch {
                    $blocked = $true
                }
                if (-not $blocked) {
                    throw "A pinned isolated-signature mutation unexpectedly succeeded."
                }
                $script:IsolatedBlockedMutations++
            }
            return [pscustomobject]@{ Status = "MockedValid"; Path = $LiteralPath }
        }

        try {
            $signature = Get-IsolatedAuthenticodeSignature -Path $script:IsolatedSource
        } finally {
            Remove-Item -LiteralPath Function:\Get-AuthenticodeSignature -Force -ErrorAction SilentlyContinue
        }
        Assert-True ($signature.Status -eq "MockedValid") "The normal pinned signature path did not return its signature result."
        Assert-True ($script:IsolatedBlockedMutations -eq 4) "Not every source/copy mutation attack was blocked."
        Assert-True (-not (Test-Path -LiteralPath $script:IsolatedCopyPath)) "The isolated signature copy was not cleaned up."
        Assert-True ((Get-FileHash -LiteralPath $script:IsolatedSource -Algorithm SHA256).Hash -eq $sourceHash) "The pinned source changed during signature verification."
    } finally {
        Remove-Item -LiteralPath Function:\Get-AuthenticodeSignature -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "signature checks fail before machine mutation" {
    $source = Get-Content -LiteralPath $install -Raw
    $signatureBoundary = $source.IndexOf('$isMicrosoftSigned = [bool](')
    $unsignedRejection = $source.IndexOf('neither Microsoft hardware-signed')
    $firstMachineMutation = $source.IndexOf('New-ItemProperty -Path $parametersKey')
    Assert-True ($signatureBoundary -ge 0) "Microsoft signature classification is missing."
    Assert-True ($unsignedRejection -gt $signatureBoundary) "Unsigned-package rejection is missing."
    Assert-True ($firstMachineMutation -gt $unsignedRejection) "The installer mutates Windows before rejecting an untrusted package."

    foreach ($required in @(
        'SplatplostBluetooth.sys',
        'SplatplostBluetooth.cat',
        'SignatureStatus]::Valid',
        '1.3.6.1.4.1.311.10.3.5.1',
        '1.3.6.1.4.1.311.10.3.5',
        'Get-IsolatedAuthenticodeSignature',
        'Confirm-SecureBootUEFI -ErrorAction Stop',
        'Win32_DeviceGuard',
        'SecurityServicesRunning',
        'IsTestSigningEnabled()'
    )) {
        Assert-True ($source.Contains($required)) "Missing fail-closed installer check: $required"
    }
    Assert-True ($source -match 'catalogSignature\.SignerCertificate\.Thumbprint -ne \$developmentCertificate\.Thumbprint') "Catalog/certificate identity is not enforced."
    Assert-True ($source -match 'driverSignature\.SignerCertificate\.Thumbprint -ne \$developmentCertificate\.Thumbprint') "Driver/certificate identity is not enforced."
    Assert-True ($source -match 'Is64BitOperatingSystem -or -not \[Environment\]::Is64BitProcess') "Installer does not reject a 32-bit PowerShell host."
    Assert-True ($source -match 'CreateFile\(path, 0, 0x00000003') "Installer status probe requests data-controller access."
    Assert-True ($source -notmatch 'Import-Certificate') "Installer reopens the package certificate path after validation."
    Assert-True ($source -match 'Add-ExactCertificateToLocalMachineStore') "Installer does not import the validated in-memory certificate object."
    Assert-True ($source -match 'StoreLocation\]::LocalMachine') "Development trust is not constrained to LocalMachine stores."
    Assert-True ($source -match 'OpenFlags\]::ReadWrite[\s\S]*OpenFlags\]::OpenExistingOnly') "Certificate stores are not opened with the minimum existing-store write flags."
    Assert-True ($source -match '\$store\.Close\(\)') "Certificate store handles are not closed deterministically."
    Assert-True ($source -match 'trustedCatalogSignature\.SignerCertificate\.Thumbprint -ne \$developmentCertificate\.Thumbprint') "Post-import catalog identity is not pinned to the validated certificate."
    Assert-True ($source -match 'trustedDriverSignature\.SignerCertificate\.Thumbprint -ne \$developmentCertificate\.Thumbprint') "Post-import driver identity is not pinned to the validated certificate."
}

Invoke-Test "installed binary identity and published INF are pinned" {
    $source = Get-Content -LiteralPath $install -Raw
    Assert-True ($source -match "\^oem\\d\+\\\.inf\$") "Published INF is not constrained to oem*.inf."
    Assert-True ($source -match 'Get-FileHash -LiteralPath \$driver -Algorithm SHA256') "Package SYS is not hashed."
    Assert-True ($source -match 'Get-FileHash -LiteralPath \$installedDriver -Algorithm SHA256') "Installed SYS is not hashed."
    Assert-True ($source -match '\$packageDriverHash -ne \$installedDriverHash') "Package and installed SYS hashes are not compared."
    Assert-True ($source -match 'active published INF does not match this package') "Active published INF bytes are not pinned to the package."
    Assert-True ($source -match 'PublishedInfName') "Published INF is not saved for deterministic cleanup."
}

Invoke-Test "package provenance and mutation order are fail closed" {
    $source = Get-Content -LiteralPath $install -Raw
    $osCheck = $source.IndexOf('CurrentBuildNumber')
    $manifestCheck = $source.IndexOf('$buildManifest = Get-Content')
    $signatureCheck = $source.IndexOf('$catalogSignature = Get-AuthenticodeSignature')
    $prestage = $source.IndexOf('/add-driver $inf | Out-Host')
    $classMutation = $source.IndexOf('New-ItemProperty -Path $parametersKey -Name "COD Major"')
    $profileMutation = $source.IndexOf('$serviceExitCode = [uint32][Splatplost.NativeStatus]::SetLocalServiceEnabled(')
    Assert-True ($osCheck -ge 0 -and $osCheck -lt $manifestCheck) "Unsupported Windows versions are not rejected before package processing."
    Assert-True ($source -match '\$windowsBuild -lt 19041') "Installer minimum version does not match the PnPUtil commands it uses."
    Assert-True ($manifestCheck -ge 0 -and $manifestCheck -lt $signatureCheck) "Build provenance is not checked before signature classification."
    Assert-True ($prestage -gt $signatureCheck -and $prestage -lt $classMutation) "Windows does not validate INF/catalog policy before Bluetooth mutation."
    Assert-True ($profileMutation -gt $classMutation) "Profile mutation order is not deterministic."
    Assert-True ($source -match 'Package support file.*does not match the submitted build') "Support-file hashes are not enforced."
    Assert-True ($source -match 'Confirm-MicrosoftReleaseManifest') "Microsoft-signed release manifest is not enforced."
    Assert-True ($source -match 'release manifest contains a duplicate entry') "Release-manifest duplicate names are not rejected."
    Assert-True ($source -match 'release folder contains unrecorded files') "Unrecorded release files are not rejected."
    Assert-True ($source -notmatch 'SplatplostBluetoothService\.exe') "Installer still depends on an unsigned elevated helper executable."
    Assert-True ($source -match 'rollback was incomplete') "Installation rollback is missing."
    Assert-True ($source -match 'managedStateSnapshot') "Failed reinstall metadata is not restored."
    Assert-True ($source -match 'Get-SplatplostBindingSnapshot') "The active driver binding is not snapshotted before upgrade."
    Assert-True ($source -match 'Restore-SplatplostBindingSnapshot') "A failed upgrade does not restore its prior binding."
    Assert-True ($source -match 'SetupGetInfDriverStoreLocationW') "The prior package is not resolved through the supported SetupAPI mapping."
    Assert-True ($source -match 'System32\\DriverStore\\FileRepository') "Rollback does not constrain its source package to FileRepository."
    Assert-True ($source -match 'Get-SplatplostDriverStorePackageSnapshot') "The exact prior Driver Store package is not snapshotted."
    Assert-True ($source -match 'Compare-SplatplostDeviceSnapshot') "Rollback does not compare exact per-instance PnP state."
    Assert-True ($source -match 'Wait-SplatplostBindingSnapshotRestored') "Rollback does not poll until the exact prior per-instance state settles."
    Assert-True ($source -match '\$null -eq \$state\.ProblemCode') "A missing pre-install ProblemCode can be cast to healthy zero."
    Assert-True ($source -match '\$null -eq \$state\.ProblemStatus') "A missing pre-install ProblemStatus can be cast to healthy zero."
    Assert-True ($source -match 'ProblemStatus -ne 0') "Healthy pre-install ProblemStatus is not required."
    Assert-True ($source -match 'Status -ine "OK"') "Healthy pre-install device Status is not required."
    Assert-True ($source -match '/delete-driver \$name /uninstall /force') "Binding rollback does not remove the newly active package."
    Assert-True ($source -match '/add-driver \$priorInfPath /install') "Binding rollback does not rebind the prior package."
    Assert-True ($source -match 'if \(\$packagePrestageAttempted\)') "First-install/prestage rollback is skipped when the prior INF set is empty."
    Assert-True ($source -match 'Get-SplatplostPublishedPackageInventory') "Rollback does not inventory inactive published Splatplost packages."
    Assert-True ($source -match 'Compare-SplatplostPublishedPackageInventory') "Rollback does not prove the complete published package set was restored."
    Assert-True ($source -match 'Test-SplatplostInstallingPackageIdentity') "Post-snapshot package deletion is not bound to the exact INF/SYS being installed."
    Assert-True ($source -match 'SplatplostWindowsBluetoothDriverOperation-v1') "Installer/uninstaller mutation serialization mutex is missing."
    Assert-True ($source -match 'SplatplostDriverPendingInstall') "Crash-safe pending install journal is missing."
    Assert-True ($source -match 'New-SplatplostPendingInstallJournal') "Pending journal is not created before package/trust mutation."
    Assert-True ($source -match 'CertificateRootExistedBefore') "Pre-import Root certificate ownership is not journaled."
    Assert-True ($source -match 'package-prestaging') "Package prestage is not phase-journaled."
    Assert-True ($source -match 'pending-install recovery journal could not be removed') "Verified rollback does not require pending-journal cleanup."
    Assert-True ($source -match 'GetSingleRadioAddress') "Installer does not enumerate the exact Bluetooth radio."
    Assert-True ($source -match 'supports exactly one enabled Windows Bluetooth radio') "Multi-radio systems are not rejected explicitly."
    Assert-True ($source -match 'InstalledRadioAddress') "The selected Bluetooth radio address is not persisted."
    Assert-True ($source -notmatch 'disableCode -in @\(\[uint32\]0, \[uint32\]20, \[uint32\]1168\)') "No-radio errors are still accepted as successful profile removal."
    Assert-True ($source -match 'could not be disabled before binding rollback') "First-install profile rollback is not ordered before empty-binding verification."
    Assert-True ($source.Contains('Code 52 on the next boot')) "First-install certificate retention does not account for an active failed binding."
    Assert-True ($source -match 'rollback is not yet proven') "A reboot-required rollback is incorrectly treated as final."
    Assert-True ($source -match 'service binary after rollback does not match') "Binding rollback does not verify the prior SYS identity."
    Assert-True ($source -match 'InstallationKind.*recovery-required') "Incomplete binding rollback does not preserve explicit recovery state."
    Assert-True ($source -match 'Remove-CertificateAddedByThisRun') "Certificate rollback is not verified."
    Assert-True ($source -match 'Wait-SplatplostDeviceStates.*TimeoutSeconds 30') "Asynchronous PnP startup is not polled with a bound."
    Assert-True ($source -match 'bridgeDeadline = \[DateTime\]::UtcNow\.AddSeconds\(30\)') "Driver readiness is not polled with a bound."
    Assert-True ($source -match 'ProblemStatus -ne 0 -or \$deviceState\.Status -ine "OK"') "A code-0 device can be committed with unhealthy ProblemStatus/Status."
    Assert-True ($source -match 'if \(\$problemCode -eq 14\)') "Restart-pending PnP state is not handled explicitly."
}

Invoke-Test "package files stay read-only pinned through prestage commit and rollback" {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($install, [ref]$tokens, [ref]$errors)
    foreach ($functionName in @(
        "Assert-SplatplostPackagePathIsLocalAndUnaliased",
        "Get-SplatplostPinnedStreamSha256",
        "Get-SplatplostPinnedPackageSnapshot",
        "Assert-SplatplostPinnedPackageSnapshot",
        "Close-SplatplostPackagePin",
        "New-SplatplostPackagePin"
    )) {
        $functionAst = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
        }, $true)
        Assert-True ($null -ne $functionAst) "$functionName was not found."
        . ([scriptblock]::Create($functionAst.Extent.Text))
    }

    $source = Get-Content -LiteralPath $install -Raw
    $pinAcquisition = $source.IndexOf('$packagePin = New-SplatplostPackagePin')
    $manifestRead = $source.IndexOf('$buildManifest = Get-Content')
    $prestageCheckpoint = $source.IndexOf('-Checkpoint "immediately before package prestaging"')
    $prestage = $source.IndexOf('/add-driver $inf | Out-Host')
    $finalCheckpoint = $source.IndexOf('-Checkpoint "immediately before installation commit"')
    $commit = $source.IndexOf('# Commit uninstall metadata only after')
    $closeCall = $source.LastIndexOf('Close-SplatplostPackagePin -PackagePin $packagePin')
    $rollback = $source.LastIndexOf('throw $failure')
    Assert-True ($pinAcquisition -ge 0 -and $pinAcquisition -lt $manifestRead) "Package files are not pinned before provenance validation."
    Assert-True ($prestageCheckpoint -gt $manifestRead -and $prestageCheckpoint -lt $prestage) "The pinned package is not rechecked immediately before PnPUtil prestaging."
    Assert-True ($finalCheckpoint -gt $prestage -and $finalCheckpoint -lt $commit) "The pinned package is not rechecked immediately before commit."
    Assert-True ($closeCall -gt $rollback) "Package handles can be released before rollback finishes."
    Assert-True ($source -match 'FILE_SHARE_READ\s*=\s*0x00000001') "Pinned package objects do not use read-only sharing."
    Assert-True ($source -match 'FILE_FLAG_OPEN_REPARSE_POINT') "Pinned package objects can traverse a substituted leaf reparse point."
    Assert-True ($source -match 'OpenPinnedPackageDirectory') "The package directory itself is not held against path substitution."
    Assert-True ($source -match '\$installingInfSha256 = \[string\]\$pinnedInitialPackageSnapshot') "The journal INF identity is not taken from the pinned initial snapshot."
    Assert-True ($source -match '\$installingDriverSha256 = \[string\]\$pinnedInitialPackageSnapshot') "The journal SYS identity is not taken from the pinned initial snapshot."

    $temporary = Join-Path ([IO.Path]::GetTempPath()) ("splatplost-package-pin-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $temporary -Force | Out-Null
    $pin = $null
    try {
        $core = Join-Path $temporary "core.bin"
        $support = Join-Path $temporary "support.ps1"
        $optional = Join-Path $temporary "optional.json"
        Set-Content -LiteralPath $core -Value "validated-core" -Encoding ASCII
        Set-Content -LiteralPath $support -Value "validated-support" -Encoding ASCII

        $pin = New-SplatplostPackagePin `
            -PackageDirectory $temporary `
            -RequiredNames @("core.bin", "support.ps1") `
            -OptionalNames @("optional.json")
        Assert-True ((Get-Content -LiteralPath $core -Raw) -match "validated-core") "FileShare.Read did not allow a second reader such as PnPUtil."

        $sharingFailure = '(?i)(used by another process|process cannot access|sharing violation|access.*denied|being used|could not be pinned for read-only sharing)'
        Assert-Throws -MessagePattern $sharingFailure -Action {
            Set-Content -LiteralPath $core -Value "substituted" -Encoding ASCII
        }
        Assert-Throws -MessagePattern $sharingFailure -Action {
            Move-Item -LiteralPath $core -Destination (Join-Path $temporary "moved.bin")
        }
        Assert-Throws -MessagePattern $sharingFailure -Action {
            Remove-Item -LiteralPath $core -Force
        }

        Set-Content -LiteralPath $optional -Value "inserted-after-validation" -Encoding ASCII
        $insertedSnapshot = Get-SplatplostPinnedPackageSnapshot -PackagePin $pin
        Assert-Throws -MessagePattern "package changed while pinned" -Action {
            Assert-SplatplostPinnedPackageSnapshot `
                -Expected $pin.InitialSnapshot `
                -Actual $insertedSnapshot `
                -Checkpoint "optional insertion regression"
        }

        Close-SplatplostPackagePin -PackagePin $pin
        $pin = $null
        Set-Content -LiteralPath $core -Value "write-after-close" -Encoding ASCII
        $moved = Join-Path $temporary "moved.bin"
        Move-Item -LiteralPath $core -Destination $moved
        Remove-Item -LiteralPath $moved -Force

        Set-Content -LiteralPath $core -Value "writer-conflict" -Encoding ASCII
        $writer = [IO.File]::Open(
            $core,
            [IO.FileMode]::Open,
            [IO.FileAccess]::ReadWrite,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        )
        try {
            Assert-Throws -MessagePattern $sharingFailure -Action {
                New-SplatplostPackagePin `
                    -PackageDirectory $temporary `
                    -RequiredNames @("core.bin", "support.ps1") `
                    -OptionalNames @("optional.json") | Out-Null
            }
        } finally {
            $writer.Dispose()
        }

        $junctionTarget = Join-Path ([IO.Path]::GetTempPath()) ("splatplost-package-pin-target-" + [Guid]::NewGuid().ToString("N"))
        $junction = Join-Path ([IO.Path]::GetTempPath()) ("splatplost-package-pin-junction-" + [Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $junctionTarget -Force | Out-Null
        try {
            Set-Content -LiteralPath (Join-Path $junctionTarget "core.bin") -Value "junction-core" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $junctionTarget "support.ps1") -Value "junction-support" -Encoding ASCII
            New-Item -ItemType Junction -Path $junction -Target $junctionTarget | Out-Null
            Assert-Throws -MessagePattern "reparse point|unsafe" -Action {
                New-SplatplostPackagePin `
                    -PackageDirectory $junction `
                    -RequiredNames @("core.bin", "support.ps1") `
                    -OptionalNames @("optional.json") | Out-Null
            }
        } finally {
            if ([IO.Directory]::Exists($junction)) {
                [IO.Directory]::Delete($junction)
            }
            Remove-Item -LiteralPath $junctionTarget -Recurse -Force -ErrorAction SilentlyContinue
        }
    } finally {
        if ($null -ne $pin) {
            Close-SplatplostPackagePin -PackagePin $pin
        }
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "certificate rollback is verified and PnP polling waits for complete state" {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($install, [ref]$tokens, [ref]$errors)
    foreach ($functionName in @(
        "Remove-CertificateAddedByThisRun",
        "Wait-SplatplostDeviceStates",
        "Compare-SplatplostDeviceSnapshot"
    )) {
        $functionAst = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
        }, $true)
        Assert-True ($null -ne $functionAst) "$functionName was not found."
        . ([scriptblock]::Create($functionAst.Extent.Text))
    }

    $temporary = Join-Path ([IO.Path]::GetTempPath()) ("splatplost-installer-cleanup-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $temporary | Out-Null
    try {
        $removable = Join-Path $temporary "removable.cer"
        Set-Content -LiteralPath $removable -Value "fixture" -Encoding ASCII
        $cleanupError = Remove-CertificateAddedByThisRun -Path $removable -Description "fixture certificate"
        Assert-True (-not $cleanupError -and -not (Test-Path -LiteralPath $removable)) "Successful cleanup was not verified."

        $locked = Join-Path $temporary "locked.cer"
        Set-Content -LiteralPath $locked -Value "fixture" -Encoding ASCII
        $lock = [IO.File]::Open($locked, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $cleanupError = Remove-CertificateAddedByThisRun -Path $locked -Description "fixture certificate"
            Assert-True ($cleanupError -match "could not be removed") "A failed cleanup was silently accepted."
            Assert-True (Test-Path -LiteralPath $locked -PathType Leaf) "Locked fixture unexpectedly disappeared."
        } finally {
            $lock.Dispose()
        }

        $script:PollAttempts = 0
        function Get-SplatplostPresentDevices { return @([pscustomobject]@{ InstanceId = "fixture" }) }
        function Get-SplatplostDeviceStates {
            param([object[]]$Devices)
            $script:PollAttempts++
            if ($script:PollAttempts -lt 3) {
                return @([pscustomobject]@{
                    InstanceId = $null
                    Status = $null
                    Service = $null
                    ProblemCode = $null
                    ProblemStatus = $null
                    DriverInfPath = $null
                })
            }
            return @([pscustomobject]@{
                InstanceId = "fixture"
                Status = "OK"
                Service = "SplatplostBluetooth"
                ProblemCode = 0
                ProblemStatus = 0
                DriverInfPath = "oem1.inf"
            })
        }
        $states = @(Wait-SplatplostDeviceStates -InstanceIdPattern "fixture*" -TimeoutSeconds 2)
        Assert-True ($script:PollAttempts -ge 3) "PnP polling returned before state became complete."
        Assert-True ($states.Count -eq 1 -and $states[0].Service -eq "SplatplostBluetooth") "PnP polling did not return the complete state."
    } finally {
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "in-memory certificate store add proves exact identity" {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($install, [ref]$tokens, [ref]$errors)
    $functionAst = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Add-ExactCertificateToOpenedStore"
    }, $true)
    Assert-True ($null -ne $functionAst) "Add-ExactCertificateToOpenedStore was not found."
    . ([scriptblock]::Create($functionAst.Extent.Text))

    $certificate = [pscustomobject]@{
        Thumbprint = "0123456789ABCDEF0123456789ABCDEF01234567"
        RawData = [byte[]](1, 2, 3, 4)
    }
    $store = [pscustomobject]@{
        Certificates = @()
        AddCount = 0
    }
    $store | Add-Member -MemberType ScriptMethod -Name Add -Value {
        param($value)
        $this.AddCount++
        $this.Certificates = @($this.Certificates) + $value
    }

    $added = Add-ExactCertificateToOpenedStore -Certificate $certificate -Store $store
    Assert-True $added "An absent exact certificate was not reported as added."
    Assert-True ($store.AddCount -eq 1 -and $store.Certificates.Count -eq 1) "The exact in-memory certificate was not added once."
    $addedAgain = Add-ExactCertificateToOpenedStore -Certificate $certificate -Store $store
    Assert-True (-not $addedAgain -and $store.AddCount -eq 1) "An existing exact certificate was added or claimed again."

    $mismatchedStore = [pscustomobject]@{
        Certificates = @([pscustomobject]@{
            Thumbprint = $certificate.Thumbprint
            RawData = [byte[]](9, 9, 9)
        })
    }
    $mismatchedStore | Add-Member -MemberType ScriptMethod -Name Add -Value { param($value) }
    Assert-Throws -MessagePattern "ambiguous or mismatched" -Action {
        Add-ExactCertificateToOpenedStore -Certificate $certificate -Store $mismatchedStore | Out-Null
    }

    $substitutingStore = [pscustomobject]@{
        Certificates = @()
    }
    $substitutingStore | Add-Member -MemberType ScriptMethod -Name Add -Value {
        param($value)
        $this.Certificates = @([pscustomobject]@{
            Thumbprint = $value.Thumbprint
            RawData = [byte[]](8, 8, 8)
        })
    }
    Assert-Throws -MessagePattern "exact validated development certificate was not present" -Action {
        Add-ExactCertificateToOpenedStore -Certificate $certificate -Store $substitutingStore | Out-Null
    }
}

Invoke-Test "installer COD rollback preserves external changes per property" {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($install, [ref]$tokens, [ref]$errors)
    $functionAst = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Get-SplatplostCodRollbackDecision"
    }, $true)
    Assert-True ($null -ne $functionAst) "Get-SplatplostCodRollbackDecision was not found."
    . ([scriptblock]::Create($functionAst.Extent.Text))

    $snapshot = [pscustomobject]@{
        'COD Major' = 7
        'COD Type' = 3
    }
    $managedCurrent = [pscustomobject]@{
        'COD Major' = 5
        'COD Type' = 2
    }
    $majorRestore = Get-SplatplostCodRollbackDecision `
        -SnapshotProperties $snapshot `
        -CurrentProperties $managedCurrent `
        -RegistryValueName "COD Major" `
        -ManagedValue 5
    Assert-True ($majorRestore.Action -eq "restore" -and $majorRestore.SnapshotValue -eq 7) "A still-owned COD Major was not selected for rollback restoration."

    $snapshotWithoutMajor = [pscustomobject]@{ 'COD Type' = 3 }
    $majorRemove = Get-SplatplostCodRollbackDecision `
        -SnapshotProperties $snapshotWithoutMajor `
        -CurrentProperties $managedCurrent `
        -RegistryValueName "COD Major" `
        -ManagedValue 5
    Assert-True ($majorRemove.Action -eq "remove") "A COD Major created by the failed install was not selected for removal."

    $missingCurrent = [pscustomobject]@{ 'COD Type' = 2 }
    $majorMissing = Get-SplatplostCodRollbackDecision `
        -SnapshotProperties $snapshot `
        -CurrentProperties $missingCurrent `
        -RegistryValueName "COD Major" `
        -ManagedValue 5
    Assert-True ($majorMissing.Action -eq "preserve-missing") "An externally removed COD Major was selected for rollback overwrite."

    $partiallyChanged = [pscustomobject]@{
        'COD Major' = 9
        'COD Type' = 2
    }
    $majorChanged = Get-SplatplostCodRollbackDecision `
        -SnapshotProperties $snapshot `
        -CurrentProperties $partiallyChanged `
        -RegistryValueName "COD Major" `
        -ManagedValue 5
    $typeRestore = Get-SplatplostCodRollbackDecision `
        -SnapshotProperties $snapshot `
        -CurrentProperties $partiallyChanged `
        -RegistryValueName "COD Type" `
        -ManagedValue 2
    Assert-True ($majorChanged.Action -eq "preserve-changed" -and $majorChanged.CurrentValue -eq 9) "An externally changed COD Major was selected for rollback overwrite."
    Assert-True ($typeRestore.Action -eq "restore" -and $typeRestore.SnapshotValue -eq 3) "A partial COD conflict prevented the independently owned COD Type from restoring."

    $source = Get-Content -LiteralPath $install -Raw
    Assert-True ($source -match 'external change during installation is preserved') "Installer COD rollback conflicts do not emit a clear warning."
    Assert-True ($source -match 'did not restore the owned pre-install COD state') "Installer COD rollback mutation is not verified."
}

Invoke-Test "COD restore preserves external changes per property" {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($uninstall, [ref]$tokens, [ref]$errors)
    $functionAst = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Get-SplatplostCodRestoreDecision"
    }, $true)
    Assert-True ($null -ne $functionAst) "Get-SplatplostCodRestoreDecision was not found."
    . ([scriptblock]::Create($functionAst.Extent.Text))

    $stateWithValues = [pscustomobject]@{
        HadCodMajor = 1
        CodMajor = 7
        HadCodType = 1
        CodType = 3
    }
    $managedCurrent = [pscustomobject]@{
        'COD Major' = 5
        'COD Type' = 2
    }
    $majorRestore = Get-SplatplostCodRestoreDecision `
        -State $stateWithValues `
        -CurrentProperties $managedCurrent `
        -RegistryValueName "COD Major" `
        -SnapshotPresenceName "HadCodMajor" `
        -SnapshotValueName "CodMajor" `
        -ManagedValue 5
    Assert-True ($majorRestore.Action -eq "restore" -and $majorRestore.SnapshotValue -eq 7) "A still-managed COD Major was not restored to its snapshot."

    $stateWithoutMajor = [pscustomobject]@{
        HadCodMajor = 0
        HadCodType = 1
        CodType = 3
    }
    $majorRemove = Get-SplatplostCodRestoreDecision `
        -State $stateWithoutMajor `
        -CurrentProperties $managedCurrent `
        -RegistryValueName "COD Major" `
        -SnapshotPresenceName "HadCodMajor" `
        -SnapshotValueName "CodMajor" `
        -ManagedValue 5
    Assert-True ($majorRemove.Action -eq "remove") "A Splatplost-created COD Major was not selected for removal."

    $missingCurrent = [pscustomobject]@{ 'COD Type' = 2 }
    $majorMissing = Get-SplatplostCodRestoreDecision `
        -State $stateWithValues `
        -CurrentProperties $missingCurrent `
        -RegistryValueName "COD Major" `
        -SnapshotPresenceName "HadCodMajor" `
        -SnapshotValueName "CodMajor" `
        -ManagedValue 5
    Assert-True ($majorMissing.Action -eq "preserve-missing") "A missing externally changed COD Major was selected for restoration."

    $partiallyChanged = [pscustomobject]@{
        'COD Major' = 9
        'COD Type' = 2
    }
    $majorChanged = Get-SplatplostCodRestoreDecision `
        -State $stateWithValues `
        -CurrentProperties $partiallyChanged `
        -RegistryValueName "COD Major" `
        -SnapshotPresenceName "HadCodMajor" `
        -SnapshotValueName "CodMajor" `
        -ManagedValue 5
    $typeUnchanged = Get-SplatplostCodRestoreDecision `
        -State $stateWithValues `
        -CurrentProperties $partiallyChanged `
        -RegistryValueName "COD Type" `
        -SnapshotPresenceName "HadCodType" `
        -SnapshotValueName "CodType" `
        -ManagedValue 2
    Assert-True ($majorChanged.Action -eq "preserve-changed" -and $majorChanged.CurrentValue -eq 9) "A changed COD Major was selected for restoration."
    Assert-True ($typeUnchanged.Action -eq "restore" -and $typeUnchanged.SnapshotValue -eq 3) "A partial COD conflict prevented the independent unchanged property from restoring."

    $uninstallSource = Get-Content -LiteralPath $uninstall -Raw
    Assert-True ($uninstallSource -match 'external post-install change is preserved') "COD ownership conflicts do not emit a clear warning."
    Assert-True ($uninstallSource -match 'pre-install Class-of-Device state was not restored exactly') "COD restoration is not verified after mutation."
}

Invoke-Test "PnP enumeration distinguishes no match from provider failure" {
    foreach ($path in @($install, $uninstall)) {
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        $functionAst = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq "Get-SplatplostPresentDevices"
        }, $true)
        Assert-True ($null -ne $functionAst) "Get-SplatplostPresentDevices was not found in $path."
        . ([scriptblock]::Create($functionAst.Extent.Text))

        $script:PnpEnumerationArguments = $null
        function Get-PnpDevice {
            [CmdletBinding()]
            param([switch]$PresentOnly, [string]$InstanceId)

            $script:PnpEnumerationArguments = @{
                PresentOnly = [bool]$PresentOnly
                HasInstanceId = $PSBoundParameters.ContainsKey("InstanceId")
                ErrorAction = [string]$PSBoundParameters["ErrorAction"]
            }
            return @(
                [pscustomobject]@{ InstanceId = "BTHENUM\MATCH" },
                [pscustomobject]@{ InstanceId = "USB\OTHER" }
            )
        }

        $matching = @(Get-SplatplostPresentDevices -InstanceIdPattern "BTHENUM\*")
        Assert-True ($matching.Count -eq 1 -and $matching[0].InstanceId -eq "BTHENUM\MATCH") "PnP enumeration did not return the genuine local match from $path."
        $noMatch = @(Get-SplatplostPresentDevices -InstanceIdPattern "PCI\NO-SPLATPLOST-*" )
        Assert-True ($noMatch.Count -eq 0) "A genuine PnP no-match was not returned as an empty set from $path."
        Assert-True $script:PnpEnumerationArguments.PresentOnly "PnP enumeration did not request only present devices in $path."
        Assert-True (-not $script:PnpEnumerationArguments.HasInstanceId) "PnP enumeration still passes the wildcard to Get-PnpDevice in $path."
        Assert-True ($script:PnpEnumerationArguments.ErrorAction -eq "Stop") "PnP provider failures are not terminating in $path."

        function Get-PnpDevice {
            [CmdletBinding()]
            param([switch]$PresentOnly)
            throw "synthetic PnP provider failure"
        }
        Assert-Throws -MessagePattern "synthetic PnP provider failure" -Action {
            Get-SplatplostPresentDevices -InstanceIdPattern "BTHENUM\*" | Out-Null
        }
    }
}

Invoke-Test "binding rollback requires exact healthy per-instance restoration" {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($install, [ref]$tokens, [ref]$errors)
    $functionAst = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Compare-SplatplostDeviceSnapshot"
    }, $true)
    Assert-True ($null -ne $functionAst) "Compare-SplatplostDeviceSnapshot was not found."
    . ([scriptblock]::Create($functionAst.Extent.Text))

    $expected = @(
        [pscustomobject]@{
            InstanceId = "BTHENUM\\ONE"
            Status = "OK"
            Service = "SplatplostBluetooth"
            ProblemCode = 0
            ProblemStatus = [uint32]0
            DriverInfPath = "oem1.inf"
        },
        [pscustomobject]@{
            InstanceId = "BTHENUM\\TWO"
            Status = "OK"
            Service = "SplatplostBluetooth"
            ProblemCode = 0
            ProblemStatus = [uint32]0
            DriverInfPath = "oem1.inf"
        }
    )
    $exact = Compare-SplatplostDeviceSnapshot -Expected $expected -Actual @($expected[1], $expected[0])
    Assert-True $exact.Verified "An exact per-instance restoration was rejected: $($exact.Errors -join '; ')"

    $missing = Compare-SplatplostDeviceSnapshot -Expected $expected -Actual @($expected[0])
    Assert-True (-not $missing.Verified) "A missing device instance was accepted as restored."

    foreach ($mutation in @(
        @{ Name = "service"; Property = "Service"; Value = "WrongService" },
        @{ Name = "INF"; Property = "DriverInfPath"; Value = "oem2.inf" },
        @{ Name = "problem code"; Property = "ProblemCode"; Value = 52 },
        @{ Name = "missing problem code"; Property = "ProblemCode"; Value = $null },
        @{
            Name = "problem status"
            Property = "ProblemStatus"
            Value = [uint32]::Parse("C0000428", [Globalization.NumberStyles]::HexNumber)
        },
        @{ Name = "device status"; Property = "Status"; Value = "Error" }
    )) {
        $changed = @($expected | ForEach-Object { $_.PSObject.Copy() })
        $changed[1].($mutation.Property) = $mutation.Value
        $comparison = Compare-SplatplostDeviceSnapshot -Expected $expected -Actual $changed
        Assert-True (-not $comparison.Verified) "A changed $($mutation.Name) was accepted as restored."
    }

    $snapshotFunctionAst = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Get-SplatplostBindingSnapshot"
    }, $true)
    Assert-True ($null -ne $snapshotFunctionAst) "Get-SplatplostBindingSnapshot was not found."
    . ([scriptblock]::Create($snapshotFunctionAst.Extent.Text))
    function Get-SplatplostPresentDevices {
        return @([pscustomobject]@{ InstanceId = "BTHENUM\\NULL-PROBLEM"; Status = "OK" })
    }
    function Wait-SplatplostDeviceStates {
        return @([pscustomobject]@{
            InstanceId = "BTHENUM\\NULL-PROBLEM"
            Status = "OK"
            Service = "SplatplostBluetooth"
            ProblemCode = $null
            ProblemStatus = $null
            DriverInfPath = "oem1.inf"
        })
    }
    Assert-Throws -MessagePattern "not healthy" -Action {
        Get-SplatplostBindingSnapshot `
            -InstanceIdPattern "BTHENUM\\*" `
            -ExpectedHardwareId "BTHENUM\\fixture" | Out-Null
    }
}

Invoke-Test "binding rollback polling waits for the exact prior instance set" {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($install, [ref]$tokens, [ref]$errors)
    foreach ($functionName in @(
        "Compare-SplatplostDeviceSnapshot",
        "Wait-SplatplostBindingSnapshotRestored"
    )) {
        $functionAst = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
        }, $true)
        Assert-True ($null -ne $functionAst) "$functionName was not found."
        . ([scriptblock]::Create($functionAst.Extent.Text))
    }

    $expected = @(
        [pscustomobject]@{
            InstanceId = "BTHENUM\\ONE"
            Status = "OK"
            Service = "SplatplostBluetooth"
            ProblemCode = 0
            ProblemStatus = [uint32]0
            DriverInfPath = "oem1.inf"
        },
        [pscustomobject]@{
            InstanceId = "BTHENUM\\TWO"
            Status = "OK"
            Service = "SplatplostBluetooth"
            ProblemCode = 0
            ProblemStatus = [uint32]0
            DriverInfPath = "oem1.inf"
        }
    )
    $script:BindingPollAttempts = 0
    function Get-SplatplostPresentDevices {
        $script:BindingPollAttempts++
        if ($script:BindingPollAttempts -lt 3) { return @($expected[0]) }
        return $expected
    }
    function Get-SplatplostDeviceStates { param([object[]]$Devices) return $Devices }

    $settled = Wait-SplatplostBindingSnapshotRestored `
        -ExpectedDevices $expected `
        -InstanceIdPattern "BTHENUM\\*" `
        -TimeoutSeconds 2
    Assert-True $settled.Verified "Exact prior binding did not settle: $($settled.Errors -join '; ')"
    Assert-True ($script:BindingPollAttempts -ge 3) "Rollback polling returned while one prior device was still missing."
}

Invoke-Test "uninstaller deletes only a verified Driver Store package" {
    $source = Get-Content -LiteralPath $uninstall -Raw
    Assert-True ($source -match "\^oem\\d\+\\\.inf\$") "Uninstaller accepts unrestricted INF names."
    Assert-True ($source -match 'AddService\\s\*=\\s\*SplatplostBluetooth') "Uninstaller does not bind cleanup to the Splatplost service."
    Assert-True ($source -match 'ProviderString\\s\*=\\s\*"Splatplost"') "Uninstaller does not bind cleanup to the Splatplost provider."
    Assert-True ($source -match 'Get-ChildItem.*"oem\*\.inf"') "Uninstaller does not enumerate inactive Splatplost packages."
    Assert-True ($source -match '/delete-driver \$publishedInfName /uninstall /force') "Driver Store removal is missing."
    Assert-True ($source -match 'DevelopmentCertificateAddedToRoot') "Root certificate ownership is not tracked."
    Assert-True ($source -match 'DevelopmentCertificateAddedToTrustedPublisher') "Publisher certificate ownership is not tracked."
    Assert-True ($source -match 'OwnedDevelopmentCertificates') "Certificate rotation ownership is not tracked."
    Assert-True ($source -match 'Test-SplatplostDevelopmentCertificate') "Owned certificates are not identity/EKU checked before deletion."
    Assert-True ($source -notmatch 'Get-StateValue -Name "PublishedInfName"') "Saved registry state is still trusted as deletion authority."
    Assert-True ($source -match 'Is64BitOperatingSystem -or -not \[Environment\]::Is64BitProcess') "Uninstaller does not reject a 32-bit PowerShell host."
    Assert-True ($source -match 'SplatplostWindowsBluetoothDriverOperation-v1') "Uninstaller does not share the installer mutation mutex."
    Assert-True ($source -match 'SplatplostDriverPendingInstall') "Uninstaller cannot recover an interrupted install journal."
    Assert-True ($source -match 'TargetRadioAddress') "Uninstaller does not pin profile removal to the journaled radio."
    Assert-True ($source -match 'actualRadioCount -ne 1') "Uninstaller does not require exactly one matching Bluetooth radio."
    Assert-True ($source -notmatch 'serviceExitCode -in @\(\[uint32\]20, \[uint32\]1168\)') "Uninstaller still accepts a missing radio as successful profile removal."
    Assert-True ($source -match 'uninstall-reboot-required') "Reboot-pending package removal does not retain recovery state."
    Assert-True ($source -match 'Get-SplatplostPublishedInfNames') "Uninstaller does not re-enumerate the final package set."
    Assert-True ($source -match 'Get-PnpDevice -PresentOnly') "Uninstaller does not prove that the profile PDO disappeared."
    Assert-True ($source -match 'certificate is still present after removal') "Uninstaller does not prove owned certificate removal."
    Assert-True ($source -match 'hasCompleteCodSnapshot') "Journal-only recovery can overwrite global COD without a complete pre-install snapshot."
    Assert-True ($source -match 'leaving the current global COD values unchanged') "Missing COD snapshot is not handled fail-safe."
}

Invoke-Test "build selects only fresh exact configuration outputs" {
    $buildSource = Get-Content -LiteralPath $build -Raw
    $prepareSource = Get-Content -LiteralPath $prepare -Raw
    $testSignSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot "sign-test-driver.ps1") -Raw
    Assert-True ($buildSource -match 'bthsrv\\sys\\\$Platform\\\$Configuration') "Driver output path is not configuration-specific."
    Assert-True ($buildSource -notmatch 'bthsrvinst\.vcxproj') "The obsolete elevated helper is still compiled."
    Assert-True ($buildSource -notmatch 'Copy-Item.*SplatplostBluetoothService\.exe') "The obsolete elevated helper is still packaged."
    Assert-True ($buildSource -match 'Bin\\amd64\\MSBuild\.exe') "64-bit MSBuild is not preferred for WDK tools."
    Assert-True ($buildSource -notmatch 'Get-ChildItem -Path \$base -Recurse') "Build can still pick a stale recursive match."
    Assert-True ($prepareSource -match 'clean -fdx -- bluetooth/bthecho') "Ignored stale build output is not cleaned."
    Assert-True ($prepareSource -match 'ReparsePoint') "Generated dependency cleanup does not reject path aliases."
    $infSource = Get-Content -LiteralPath $infTemplate -Raw
    Assert-True ($infSource -match 'NT\$ARCH\$\.10\.0\.\.\.19041') "DIRID 13 model sections are not limited to Windows 10 2004 or newer."
    Assert-True ($testSignSource -match '10_VB_X64,10_CO_X64,10_NI_X64,10_GE_X64') "Development catalog validation does not cover the declared Windows 10 2004 through Windows 11 24H2 targets."
}


Invoke-Test "dependency preparation rejects prefix path escapes before mutation" {
    $escaped = Join-Path $PSScriptRoot ("_deps-escape-" + [Guid]::NewGuid().ToString("N"))
    Assert-Throws -MessagePattern "must stay inside" -Action {
        & $prepare -Destination $escaped | Out-Null
    }
    Assert-True (-not (Test-Path -LiteralPath $escaped)) "Rejected dependency path was created."
}

if ($script:Failures -ne 0) {
    throw "$script:Failures installer script test(s) failed."
}

Write-Host "ALL TESTS PASSED"
