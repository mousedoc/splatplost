param(
    [string]$EvidencePath = (Join-Path $PWD "SplatplostBluetooth-runtime-evidence.json"),
    [string]$PackageDirectory,
    [string]$SignToolPath,
    [string]$BridgePath = "\\.\SplatplostBluetooth",
    [switch]$RequireConnected
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$hardwareIdPrefix = "BTHENUM\{f6fd1f11-2d8a-4ce4-8794-261e461e6c53}"
$driverServiceName = "SplatplostBluetooth"
$controlPsm = 0x0011
$interruptPsm = 0x0013
$readyStage = 5

function New-Check {
    return [ordered]@{
        readable = $false
        passed = $false
        error = $null
    }
}

function Get-ErrorText {
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    $message = $ErrorRecord.Exception.Message
    if ($ErrorRecord.Exception.InnerException) {
        $message = "$message Inner error: $($ErrorRecord.Exception.InnerException.Message)"
    }
    return $message
}

function Format-UInt32Hex {
    param([uint32]$Value)
    return "0x{0:X8}" -f $Value
}

function Format-BluetoothAddress {
    param([uint64]$Value)

    $bytes = [BitConverter]::GetBytes($Value)
    $parts = for ($index = 5; $index -ge 0; $index--) {
        "{0:X2}" -f $bytes[$index]
    }
    return $parts -join ":"
}

function Resolve-KernelImagePath {
    param([Parameter(Mandatory = $true)][string]$ImagePath)

    $path = $ImagePath.Trim().Trim('"')
    $path = [Environment]::ExpandEnvironmentVariables($path)
    if ($path.StartsWith("\??\", [StringComparison]::Ordinal)) {
        $path = $path.Substring(4)
    }
    if ($path.StartsWith("\SystemRoot\", [StringComparison]::OrdinalIgnoreCase)) {
        $path = Join-Path $env:SystemRoot $path.Substring("\SystemRoot\".Length)
    } elseif ($path.StartsWith("System32\", [StringComparison]::OrdinalIgnoreCase)) {
        $path = Join-Path $env:SystemRoot $path
    }
    return [IO.Path]::GetFullPath($path)
}

function Get-WindowsKitsBinRoot {
    $programFilesX86 = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::ProgramFilesX86
    )
    if ([string]::IsNullOrWhiteSpace($programFilesX86)) {
        throw "Windows could not resolve the protected Program Files (x86) directory."
    }
    $root = [IO.Path]::GetFullPath(
        (Join-Path $programFilesX86 "Windows Kits\10\bin")
    ).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "The Windows Kits x64 tool directory was not found: $root"
    }
    return $root
}

function Assert-CanonicalWindowsKitsSignToolPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$KitsBinRoot
    )

    $root = [IO.Path]::GetFullPath($KitsBinRoot).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $candidate = [IO.Path]::GetFullPath($Path)
    $prefix = $root + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "SignTool must be inside the protected Windows Kits x64 bin root: $root"
    }
    $relative = $candidate.Substring($prefix.Length)
    $segments = @($relative -split '[\\/]')
    $sdkVersion = $null
    if (
        $segments.Count -ne 3 -or
        -not [Version]::TryParse($segments[0], [ref]$sdkVersion) -or
        -not [string]::Equals($segments[1], "x64", [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals($segments[2], "signtool.exe", [StringComparison]::OrdinalIgnoreCase)
    ) {
        throw "SignTool must use the canonical Windows Kits path '<version>\x64\signtool.exe': $candidate"
    }
    return $candidate
}

function Get-TrustedFileSystemPrincipals {
    $trusted = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($sid in @("S-1-5-18", "S-1-5-32-544")) {
        [void]$trusted.Add($sid)
    }
    try {
        $trustedInstaller = [Security.Principal.NTAccount]::new("NT SERVICE", "TrustedInstaller")
        [void]$trusted.Add(
            $trustedInstaller.Translate([Security.Principal.SecurityIdentifier]).Value
        )
    } catch {
        throw "Windows could not resolve the TrustedInstaller identity used to protect Windows Kits."
    }
    return $trusted
}

function Assert-TrustedSignToolFileSystemPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TrustedRoot
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $resolvedRoot = [IO.Path]::GetFullPath($TrustedRoot).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $rootPrefix = $resolvedRoot + [IO.Path]::DirectorySeparatorChar
    if (
        -not [string]::Equals($resolvedPath, $resolvedRoot, [StringComparison]::OrdinalIgnoreCase) -and
        -not $resolvedPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)
    ) {
        throw "The SignTool path escapes its trusted filesystem root."
    }

    $components = @($resolvedRoot)
    if (-not [string]::Equals($resolvedPath, $resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $current = $resolvedRoot
        foreach ($segment in @($resolvedPath.Substring($rootPrefix.Length) -split '[\\/]')) {
            $current = Join-Path $current $segment
            $components += $current
        }
    }
    foreach ($component in $components) {
        $item = Get-Item -LiteralPath $component -Force -ErrorAction Stop
        if (([IO.FileAttributes]$item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "The SignTool path contains a symbolic link, junction, or other reparse point: $component"
        }
    }

    $fileItem = Get-Item -LiteralPath $resolvedPath -Force -ErrorAction Stop
    if ($fileItem.PSIsContainer) {
        throw "SignTool is not a regular file: $resolvedPath"
    }
    [uint32]$numberOfLinks = 0
    [uint32]$fileAttributes = 0
    $fileIdentity = [Splatplost.EvidenceFileIdentityV1]::GetExistingFileIdentity(
        $resolvedPath,
        [ref]$numberOfLinks,
        [ref]$fileAttributes
    )
    if ($numberOfLinks -ne 1) {
        throw "SignTool must not be reachable through multiple hard links: $resolvedPath"
    }
    if (
        ([IO.FileAttributes]$fileAttributes -band [IO.FileAttributes]::Directory) -ne 0 -or
        ([IO.FileAttributes]$fileAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    ) {
        throw "SignTool is not a regular non-reparse file: $resolvedPath"
    }

    $trustedPrincipals = Get-TrustedFileSystemPrincipals
    [uint32]$writeMask = [uint32](
        [Security.AccessControl.FileSystemRights]::WriteData -bor
        [Security.AccessControl.FileSystemRights]::AppendData -bor
        [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
        [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership
    )
    foreach ($component in $components) {
        $acl = Get-Acl -LiteralPath $component -ErrorAction Stop
        $ownerSid = ([Security.Principal.NTAccount]$acl.Owner).Translate(
            [Security.Principal.SecurityIdentifier]
        ).Value
        if (-not $trustedPrincipals.Contains($ownerSid)) {
            throw "The SignTool path has an untrusted owner and may be user-writable: $component"
        }
        foreach ($rule in @($acl.Access)) {
            if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) {
                continue
            }
            if (
                ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0
            ) {
                continue
            }
            [uint32]$ruleRights = [BitConverter]::ToUInt32(
                [BitConverter]::GetBytes([int32]$rule.FileSystemRights),
                0
            )
            if (($ruleRights -band $writeMask) -eq 0) {
                continue
            }
            $ruleSid = $rule.IdentityReference.Translate(
                [Security.Principal.SecurityIdentifier]
            ).Value
            if (-not $trustedPrincipals.Contains($ruleSid)) {
                throw "The SignTool path grants write access to an untrusted principal '$ruleSid': $component"
            }
        }
    }

    return [pscustomobject]@{
        Path = $resolvedPath
        FileIdentity = $fileIdentity
        NumberOfLinks = $numberOfLinks
        Length = [int64]$fileItem.Length
    }
}

function Get-PeMachine {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [IO.File]::Open(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        $dosHeader = [byte[]]::new(64)
        if ($stream.Read($dosHeader, 0, $dosHeader.Length) -ne $dosHeader.Length -or
            $dosHeader[0] -ne 0x4D -or $dosHeader[1] -ne 0x5A) {
            throw "SignTool does not contain a valid DOS/PE header."
        }
        $peOffset = [BitConverter]::ToInt32($dosHeader, 0x3C)
        if ($peOffset -lt 64 -or $peOffset -gt $stream.Length - 6) {
            throw "SignTool contains an invalid PE header offset."
        }
        [void]$stream.Seek($peOffset, [IO.SeekOrigin]::Begin)
        $peHeader = [byte[]]::new(6)
        if ($stream.Read($peHeader, 0, $peHeader.Length) -ne $peHeader.Length -or
            $peHeader[0] -ne 0x50 -or $peHeader[1] -ne 0x45 -or
            $peHeader[2] -ne 0 -or $peHeader[3] -ne 0) {
            throw "SignTool does not contain a valid PE signature."
        }
        return [uint16][BitConverter]::ToUInt16($peHeader, 4)
    } finally {
        $stream.Dispose()
    }
}

function Assert-TrustedSignToolMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$OriginalFilename,
        [Parameter(Mandatory = $true)][uint16]$PeMachine,
        [Parameter(Mandatory = $true)]$Signature,
        [Parameter(Mandatory = $true)][string[]]$EkuOids,
        [Parameter(Mandatory = $true)][bool]$ChainValid,
        [Parameter(Mandatory = $true)][string]$ChainRootSubject
    )

    if (-not [string]::Equals($OriginalFilename, "signtool.exe", [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to execute a renamed Microsoft binary whose original filename is not signtool.exe."
    }
    if ($PeMachine -ne [uint16]0x8664) {
        throw "Refusing to execute SignTool because it is not an x64 PE image."
    }
    if (
        $Signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
        -not $Signature.SignerCertificate -or
        $Signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)' -or
        $Signature.SignerCertificate.Issuer -notmatch 'Microsoft.*Code Signing PCA' -or
        $EkuOids -notcontains "1.3.6.1.5.5.7.3.3" -or
        -not $ChainValid -or
        $ChainRootSubject -notmatch 'Microsoft.*Root Certificate Authority'
    ) {
        throw "Refusing to execute SignTool because its Microsoft Authenticode signer, chain, or code-signing EKU is invalid."
    }
}

function Get-TrustedSignToolSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$KitsBinRoot
    )

    $candidate = Assert-CanonicalWindowsKitsSignToolPath -Path $Path -KitsBinRoot $KitsBinRoot
    $programFilesX86 = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::ProgramFilesX86
    )
    $fileSystem = Assert-TrustedSignToolFileSystemPath -Path $candidate -TrustedRoot $programFilesX86
    $item = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
    $peMachine = Get-PeMachine -Path $candidate
    $signature = Get-AuthenticodeSignature -LiteralPath $candidate
    $ekuOids = @()
    if ($signature.SignerCertificate) {
        $ekuOids = @($signature.SignerCertificate.Extensions |
            Where-Object { $_.Oid.Value -eq "2.5.29.37" } |
            ForEach-Object {
                $enhanced = [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]$_
                @($enhanced.EnhancedKeyUsages | ForEach-Object { $_.Value })
            })
    }
    $chain = [Security.Cryptography.X509Certificates.X509Chain]::new()
    try {
        $chain.ChainPolicy.RevocationMode = [Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        $chain.ChainPolicy.VerificationFlags = [Security.Cryptography.X509Certificates.X509VerificationFlags]::IgnoreNotTimeValid
        $chainValid = [bool]($signature.SignerCertificate -and $chain.Build($signature.SignerCertificate))
        $chainRootSubject = if ($chain.ChainElements.Count -gt 0) {
            $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate.Subject
        } else {
            ""
        }
    } finally {
        $chain.Dispose()
    }
    Assert-TrustedSignToolMetadata `
        -OriginalFilename ([string]$item.VersionInfo.OriginalFilename) `
        -PeMachine $peMachine `
        -Signature $signature `
        -EkuOids $ekuOids `
        -ChainValid $chainValid `
        -ChainRootSubject $chainRootSubject

    $sha256 = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
    $finalFileSystem = Assert-TrustedSignToolFileSystemPath -Path $candidate -TrustedRoot $programFilesX86
    $finalSha256 = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
    if (
        $fileSystem.FileIdentity -ne $finalFileSystem.FileIdentity -or
        $fileSystem.Length -ne $finalFileSystem.Length -or
        $sha256 -ne $finalSha256
    ) {
        throw "SignTool changed while its trusted identity was being established."
    }

    return [pscustomobject]@{
        Path = $candidate
        KitsBinRoot = [IO.Path]::GetFullPath($KitsBinRoot)
        FileIdentity = $fileSystem.FileIdentity
        Length = $fileSystem.Length
        Sha256 = $sha256
        OriginalFilename = [string]$item.VersionInfo.OriginalFilename
        PeMachine = "0x{0:X4}" -f $peMachine
        SignerThumbprint = $signature.SignerCertificate.Thumbprint
        SignerSubject = $signature.SignerCertificate.Subject
        ChainRootSubject = $chainRootSubject
    }
}

function Assert-TrustedSignToolSnapshotMatches {
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Actual
    )

    foreach ($name in @(
        "Path", "KitsBinRoot", "FileIdentity", "Length", "Sha256",
        "OriginalFilename", "PeMachine", "SignerThumbprint", "SignerSubject", "ChainRootSubject"
    )) {
        if (-not [string]::Equals(
            [string]$Expected.$name,
            [string]$Actual.$name,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw "SignTool changed after its trusted identity was established ($name mismatch)."
        }
    }
}

function Resolve-TrustedSignTool {
    param([string]$ExplicitPath)

    $kitsBinRoot = Get-WindowsKitsBinRoot
    if ($ExplicitPath) {
        $candidate = [IO.Path]::GetFullPath($ExplicitPath)
    } else {
        $candidate = Get-ChildItem -LiteralPath $kitsBinRoot -Directory -ErrorAction Stop |
            Where-Object { $_.Name -as [Version] } |
            Sort-Object { [Version]$_.Name } -Descending |
            ForEach-Object { Join-Path $_.FullName "x64\signtool.exe" } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            Select-Object -First 1
    }
    if (-not $candidate) {
        throw "A trusted x64 SignTool is required to prove catalog membership. Install the Windows SDK or pass its canonical x64 -SignToolPath explicitly."
    }
    return Get-TrustedSignToolSnapshot -Path $candidate -KitsBinRoot $kitsBinRoot
}

function Invoke-TrustedSignTool {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)]$PackagePin
    )

    $before = Get-TrustedSignToolSnapshot -Path $Snapshot.Path -KitsBinRoot $Snapshot.KitsBinRoot
    Assert-TrustedSignToolSnapshotMatches -Expected $Snapshot -Actual $before
    $packageBefore = Get-PinnedVerificationPackageSnapshot -PackagePin $PackagePin
    Assert-PinnedVerificationPackageSnapshot `
        -Expected $PackagePin.InitialSnapshot `
        -Actual $packageBefore `
        -Checkpoint "immediately before SignTool execution"
    $output = @()
    $exitCode = $null
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 surfaces native stderr as ErrorRecord objects
        # and would otherwise turn harmless SignTool help/verbose output into a
        # terminating PowerShell error before its process exit code is read.
        $ErrorActionPreference = "Continue"
        $output = @(& $before.Path @Arguments *>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
        try {
            $after = Get-TrustedSignToolSnapshot -Path $Snapshot.Path -KitsBinRoot $Snapshot.KitsBinRoot
            Assert-TrustedSignToolSnapshotMatches -Expected $Snapshot -Actual $after
        } finally {
            $packageAfter = Get-PinnedVerificationPackageSnapshot -PackagePin $PackagePin
            Assert-PinnedVerificationPackageSnapshot `
                -Expected $PackagePin.InitialSnapshot `
                -Actual $packageAfter `
                -Checkpoint "immediately after SignTool execution"
        }
    }
    return [pscustomobject]@{
        Output = $output
        ExitCode = $exitCode
    }
}

function Get-VerificationReadOnlyStreamSha256 {
    param([Parameter(Mandatory = $true)][IO.FileStream]$Stream)

    if (-not $Stream.CanRead -or -not $Stream.CanSeek) {
        throw "A signature-verification stream is not readable and seekable."
    }
    $originalPosition = $Stream.Position
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $Stream.Position = 0
        $hashBytes = $algorithm.ComputeHash($Stream)
        return ([BitConverter]::ToString($hashBytes)).Replace("-", "")
    } finally {
        $algorithm.Dispose()
        $Stream.Position = $originalPosition
    }
}

function Get-IsolatedAuthenticodeSignature {
    param([Parameter(Mandatory = $true)][string]$Path)

    $sourcePin = $null
    $copyPin = $null
    $creationStream = $null
    $copyCreated = $false
    $copy = Join-Path ([IO.Path]::GetTempPath()) (
        "splatplost-signature-{0}.sys" -f [Guid]::NewGuid().ToString("N")
    )
    try {
        $sourcePin = [Splatplost.EvidenceFileIdentityV1]::OpenPinnedPackageFile($Path)
        $sourceHash = Get-VerificationReadOnlyStreamSha256 -Stream $sourcePin

        $creationStream = [IO.File]::Open(
            $copy,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
        $copyCreated = $true
        $sourcePin.Position = 0
        $sourcePin.CopyTo($creationStream)
        $creationStream.Flush()
        $creationStream.Dispose()
        $creationStream = $null

        $copyPin = [Splatplost.EvidenceFileIdentityV1]::OpenPinnedPackageFile($copy)
        $copyHash = Get-VerificationReadOnlyStreamSha256 -Stream $copyPin
        if (
            $copyHash -ne $sourceHash -or
            (Get-VerificationReadOnlyStreamSha256 -Stream $sourcePin) -ne $sourceHash
        ) {
            throw "The isolated signature copy does not exactly match its pinned source."
        }

        $signature = Get-AuthenticodeSignature -LiteralPath $copy
        if (
            (Get-VerificationReadOnlyStreamSha256 -Stream $copyPin) -ne $sourceHash -or
            (Get-VerificationReadOnlyStreamSha256 -Stream $sourcePin) -ne $sourceHash
        ) {
            throw "The pinned signature source or isolated copy changed during Authenticode verification."
        }
        return $signature
    } finally {
        if ($null -ne $creationStream) { $creationStream.Dispose() }
        if ($null -ne $copyPin) { $copyPin.Dispose() }
        if ($null -ne $sourcePin) { $sourcePin.Dispose() }
        if ($copyCreated) {
            Remove-Item -LiteralPath $copy -Force -ErrorAction SilentlyContinue
        }
    }
}

function Convert-SignatureToEvidence {
    param([Parameter(Mandatory = $true)]$Signature)

    $ekuOids = @()
    if ($Signature.SignerCertificate) {
        $ekuOids = @($Signature.SignerCertificate.Extensions |
            Where-Object { $_.Oid.Value -eq "2.5.29.37" } |
            ForEach-Object {
                $enhanced = [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]$_
                @($enhanced.EnhancedKeyUsages | ForEach-Object { $_.Value })
            })
    }
    $attestationOid = "1.3.6.1.4.1.311.10.3.5.1"
    $whcpOid = "1.3.6.1.4.1.311.10.3.5"
    $hardwareSigningKind = if ($ekuOids -contains $attestationOid) {
        "attestation"
    } elseif ($ekuOids -contains $whcpOid) {
        "hlk-whcp"
    } else {
        $null
    }
    $validMicrosoftSignature = [bool](
        $Signature.Status -eq [System.Management.Automation.SignatureStatus]::Valid -and
        $Signature.SignerCertificate -and
        $Signature.SignerCertificate.Subject -match "Microsoft"
    )

    return [ordered]@{
        status = [string]$Signature.Status
        statusMessage = $Signature.StatusMessage
        subject = if ($Signature.SignerCertificate) { $Signature.SignerCertificate.Subject } else { $null }
        issuer = if ($Signature.SignerCertificate) { $Signature.SignerCertificate.Issuer } else { $null }
        thumbprint = if ($Signature.SignerCertificate) { $Signature.SignerCertificate.Thumbprint } else { $null }
        timestampSubject = if ($Signature.TimeStamperCertificate) { $Signature.TimeStamperCertificate.Subject } else { $null }
        ekuOids = $ekuOids
        hardwareSigningKind = $hardwareSigningKind
        validMicrosoftSignature = $validMicrosoftSignature
        validMicrosoftHardwareSignature = [bool]($validMicrosoftSignature -and $hardwareSigningKind)
    }
}

function Assert-VerificationPackagePathIsLocalAndUnaliased {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    if ($fullPath -match '^\\\\') {
        throw "The release package must be extracted to a local Windows drive before verification."
    }
    $root = [IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw "The release package path is not an absolute local path."
    }
    $current = $root
    foreach ($segment in @($fullPath.Substring($root.Length) -split '[\\/]' | Where-Object { $_ })) {
        $current = Join-Path $current $segment
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "The release package path contains a junction, symbolic link, or other reparse point: $current"
        }
    }
    return $fullPath
}

function Get-PinnedVerificationPackageSnapshot {
    param([Parameter(Mandatory = $true)]$PackagePin)

    $snapshot = @{}
    foreach ($name in @($PackagePin.Records.Keys | Sort-Object)) {
        $record = $PackagePin.Records[$name]
        if (-not (Test-Path -LiteralPath $record.Path -PathType Leaf)) {
            throw "The pinned release package changed: '$name' is missing or is not a regular file."
        }
        $item = Get-Item -LiteralPath $record.Path -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "The pinned release package changed: '$name' became a reparse point."
        }
        [uint32]$numberOfLinks = 0
        [uint32]$fileAttributes = 0
        $fileIdentity = [Splatplost.EvidenceFileIdentityV1]::GetExistingFileIdentity(
            $record.Path,
            [ref]$numberOfLinks,
            [ref]$fileAttributes
        )
        $snapshot[$name] = [pscustomobject]@{
            FileIdentity = [string]$fileIdentity
            NumberOfLinks = [uint32]$numberOfLinks
            FileAttributes = [uint32]$fileAttributes
            Length = [long]$item.Length
            Sha256 = [string](Get-FileHash -LiteralPath $record.Path -Algorithm SHA256).Hash
        }
    }
    return $snapshot
}

function Assert-PinnedVerificationPackageSnapshot {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Expected,
        [Parameter(Mandatory = $true)][hashtable]$Actual,
        [Parameter(Mandatory = $true)][string]$Checkpoint
    )

    if ($Expected.Count -ne $Actual.Count) {
        throw "The pinned release package changed at $Checkpoint (file-set size changed)."
    }
    foreach ($name in @($Expected.Keys | Sort-Object)) {
        if (-not $Actual.ContainsKey($name)) {
            throw "The pinned release package changed at $Checkpoint (missing '$name')."
        }
        foreach ($field in @("FileIdentity", "NumberOfLinks", "FileAttributes", "Length", "Sha256")) {
            if (-not [string]::Equals(
                [string]$Expected[$name].$field,
                [string]$Actual[$name].$field,
                [StringComparison]::OrdinalIgnoreCase
            )) {
                throw "The pinned release package changed at $Checkpoint ($name $field mismatch)."
            }
        }
    }
}

function Close-VerificationPackagePin {
    param([Parameter(Mandatory = $true)]$PackagePin)

    foreach ($handle in @($PackagePin.Handles)) {
        if ($null -ne $handle) {
            $handle.Dispose()
        }
    }
    $PackagePin.Handles.Clear()
}

function New-VerificationPackagePin {
    param([Parameter(Mandatory = $true)][string]$PackageDirectory)

    $fullPackageDirectory = Assert-VerificationPackagePathIsLocalAndUnaliased -Path $PackageDirectory
    $handles = [Collections.Generic.List[IDisposable]]::new()
    $records = @{}
    try {
        $directoryHandle = [Splatplost.EvidenceFileIdentityV1]::OpenPinnedPackageDirectory(
            $fullPackageDirectory
        )
        [void]$handles.Add($directoryHandle)

        $manifestName = "SplatplostBluetooth-release-manifest.json"
        $manifestPath = Join-Path $fullPackageDirectory $manifestName
        $manifestStream = [Splatplost.EvidenceFileIdentityV1]::OpenPinnedPackageFile($manifestPath)
        [void]$handles.Add($manifestStream)
        $records[$manifestName] = [pscustomobject]@{ Path = $manifestPath }

        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        if ([int]$manifest.schemaVersion -ne 1 -or -not $manifest.files) {
            throw "The release manifest is invalid or unsupported, so its files cannot be pinned."
        }
        $recordedNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in @($manifest.files)) {
            $name = [string]$entry.name
            $expectedHash = [string]$entry.sha256
            if (
                $name -notmatch '^[A-Za-z0-9_.-]+$' -or
                $expectedHash -notmatch '^[0-9A-Fa-f]{64}$' -or
                $name -in @($manifestName, "SplatplostBluetooth-runtime-evidence.json") -or
                -not $recordedNames.Add($name)
            ) {
                throw "The release manifest contains an unsafe, reserved, or duplicate file entry: '$name'."
            }
            $path = Join-Path $fullPackageDirectory $name
            $stream = [Splatplost.EvidenceFileIdentityV1]::OpenPinnedPackageFile($path)
            [void]$handles.Add($stream)
            $records[$name] = [pscustomobject]@{ Path = $path }
        }

        $packagePin = [pscustomobject]@{
            PackageDirectory = $fullPackageDirectory
            Records = $records
            Handles = $handles
            InitialSnapshot = $null
        }
        $packagePin.InitialSnapshot = Get-PinnedVerificationPackageSnapshot -PackagePin $packagePin
        return $packagePin
    } catch {
        foreach ($handle in @($handles)) {
            if ($null -ne $handle) {
                $handle.Dispose()
            }
        }
        throw
    }
}

function Confirm-SignedReleaseManifest {
    param([Parameter(Mandatory = $true)][string]$PackageDirectory)

    $manifestPath = Join-Path $PackageDirectory "SplatplostBluetooth-release-manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "The package is missing SplatplostBluetooth-release-manifest.json."
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ([int]$manifest.schemaVersion -ne 1 -or -not $manifest.files) {
        throw "The signed release manifest is invalid or unsupported."
    }

    $recordedNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($manifest.files)) {
        $name = [string]$entry.name
        $expectedHash = [string]$entry.sha256
        if ($name -notmatch '^[A-Za-z0-9_.-]+$' -or $expectedHash -notmatch '^[0-9A-Fa-f]{64}$') {
            throw "The signed release manifest contains an unsafe or invalid entry."
        }
        if (-not $recordedNames.Add($name)) {
            throw "The signed release manifest contains duplicate file '$name'."
        }
        $path = Join-Path $PackageDirectory $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "The signed release package is missing recorded file '$name'."
        }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $expectedHash) {
            throw "The signed release file '$name' does not match its release manifest."
        }
    }

    foreach ($requiredName in @(
        "SplatplostBluetooth.inf",
        "SplatplostBluetooth.sys",
        "SplatplostBluetooth.cat",
        "SplatplostBluetooth-build-manifest.json",
        "SplatplostBluetooth-signature-evidence.json",
        "install-driver.ps1",
        "install-driver.cmd",
        "uninstall-driver.ps1",
        "uninstall-driver.cmd",
        "verify-runtime.ps1",
        "THIRD_PARTY_NOTICES.md"
    )) {
        if (-not $recordedNames.Contains($requiredName)) {
            throw "The signed release manifest does not bind required file '$requiredName'."
        }
    }

    $unexpectedFiles = @(Get-ChildItem -LiteralPath $PackageDirectory -File -Force | Where-Object {
        $_.Name -ne "SplatplostBluetooth-release-manifest.json" -and
        $_.Name -ne "SplatplostBluetooth-runtime-evidence.json" -and
        -not $recordedNames.Contains($_.Name)
    })
    if ($unexpectedFiles.Count -ne 0) {
        throw "The signed release folder contains unrecorded files: $($unexpectedFiles.Name -join ', ')"
    }

    return [ordered]@{
        path = [IO.Path]::GetFullPath($manifestPath)
        sha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        fileCount = $recordedNames.Count
        verified = $true
    }
}

function Confirm-SignatureEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$PackageDirectory,
        [Parameter(Mandatory = $true)][hashtable]$ExpectedFiles
    )

    $evidencePath = Join-Path $PackageDirectory "SplatplostBluetooth-signature-evidence.json"
    $signatureEvidence = Get-Content -LiteralPath $evidencePath -Raw | ConvertFrom-Json
    $verifiedAtUtc = [DateTimeOffset]::MinValue
    $verifiedAtValue = $signatureEvidence.verifiedAtUtc
    if ($verifiedAtValue -is [DateTime] -and $verifiedAtValue.Kind -eq [DateTimeKind]::Utc) {
        # PowerShell 7.5+ materializes ISO JSON timestamps as DateTime by
        # default; Windows PowerShell 5.1 leaves the same JSON value a string.
        $verifiedAtUtc = [DateTimeOffset]$verifiedAtValue
        $validVerifiedAt = $true
    } elseif ($verifiedAtValue -is [DateTimeOffset]) {
        $verifiedAtUtc = [DateTimeOffset]$verifiedAtValue
        $validVerifiedAt = $true
    } else {
        $validVerifiedAt = [DateTimeOffset]::TryParseExact(
            [string]$verifiedAtValue,
            "o",
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$verifiedAtUtc
        )
    }
    if (
        [int]$signatureEvidence.schemaVersion -ne 1 -or
        [string]$signatureEvidence.signingKind -notin @("attestation", "hlk-whcp") -or
        $signatureEvidence.verified.microsoftCatalogSignature -isnot [bool] -or
        $signatureEvidence.verified.microsoftCatalogSignature -ne $true -or
        $signatureEvidence.verified.catalogCoversInfAndSys -isnot [bool] -or
        $signatureEvidence.verified.catalogCoversInfAndSys -ne $true -or
        $signatureEvidence.verified.embeddedDriverSignature -isnot [bool] -or
        $signatureEvidence.verified.embeddedDriverSignature -ne $true -or
        -not $validVerifiedAt -or
        $verifiedAtUtc.Offset -ne [TimeSpan]::Zero -or
        $verifiedAtUtc -gt [DateTimeOffset]::UtcNow.AddMinutes(5)
    ) {
        throw "The package signature evidence is invalid or incomplete."
    }

    foreach ($name in @($ExpectedFiles.Keys)) {
        $entries = @($signatureEvidence.files | Where-Object { $_.name -eq $name })
        if ($entries.Count -ne 1 -or [string]$entries[0].sha256 -notmatch '^[0-9A-Fa-f]{64}$') {
            throw "The package signature evidence does not contain exactly one valid '$name' identity."
        }
        if ([string]$entries[0].sha256 -ne [string]$ExpectedFiles[$name]) {
            throw "The package signature evidence does not match '$name'."
        }
    }

    return [ordered]@{
        path = [IO.Path]::GetFullPath($evidencePath)
        signingKind = [string]$signatureEvidence.signingKind
        verifiedAtUtc = $verifiedAtUtc.ToString("o", [Globalization.CultureInfo]::InvariantCulture)
        exactFileHashesVerified = $true
        catalogMembershipClaimed = $true
    }
}

function Test-SplatplostPnpReady {
    param(
        [Parameter(Mandatory = $true)][int]$PresentDeviceCount,
        [Parameter(Mandatory = $true)][bool]$AllDevicesHealthy,
        [Parameter(Mandatory = $true)][bool]$DriverRunning,
        [Parameter(Mandatory = $true)][bool]$InstalledRadioStateValid
    )

    return [bool](
        $PresentDeviceCount -eq 1 -and
        $AllDevicesHealthy -and
        $DriverRunning -and
        $InstalledRadioStateValid
    )
}

function Test-SplatplostBridgeReady {
    param(
        [Parameter(Mandatory = $true)][uint32]$Stage,
        [Parameter(Mandatory = $true)][uint32]$InitializationStatus,
        [Parameter(Mandatory = $true)][uint64]$LocalAddress,
        [Parameter(Mandatory = $true)][uint64]$InstalledRadioAddress
    )

    return [bool](
        $Stage -eq 5 -and
        $InitializationStatus -eq 0 -and
        $LocalAddress -ne 0 -and
        $InstalledRadioAddress -ne 0 -and
        $LocalAddress -eq $InstalledRadioAddress
    )
}

function Assert-ExactPackageSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Actual
    )

    foreach ($name in @(
        "ReleaseManifestSha256",
        "ReleaseManifestFileCount",
        "InfSha256",
        "SysSha256",
        "CatalogSha256",
        "InstalledSysSha256"
    )) {
        if (-not [string]::Equals(
            [string]$Expected.$name,
            [string]$Actual.$name,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw "The release package changed during runtime verification ($name mismatch)."
        }
    }
}

function Complete-RuntimeEvidence {
    param(
        [Parameter(Mandatory = $true)]$Evidence,
        [Parameter(Mandatory = $true)][bool]$RequireConnected
    )

    $Evidence.failures = @()
    $installationChecks = @(
        "administrator",
        "secureBoot",
        "testSigning",
        "memoryIntegrity",
        "pnp",
        "microsoftSignedPackage",
        "bridgeInitialization"
    )
    foreach ($name in $installationChecks) {
        $check = $Evidence.checks[$name]
        if (-not $check.readable -or -not $check.passed) {
            $detail = if ($check.error) { $check.error } else { "readable=$($check.readable), passed=$($check.passed)" }
            $Evidence.failures += "$name failed: $detail"
        }
    }

    $channels = $Evidence.checks.hidChannels
    $Evidence.installationReady = -not [bool]$Evidence.failures.Count
    $Evidence.connectedReady = [bool](
        $Evidence.installationReady -and
        $channels.readable -and
        $channels.passed
    )
    if ($RequireConnected -and -not $Evidence.connectedReady) {
        $channelDetail = if ($channels.error) { $channels.error } else { "readable=$($channels.readable), passed=$($channels.passed)" }
        $Evidence.failures += "hidChannels failed: $channelDetail"
    }
    $Evidence.passed = if ($RequireConnected) { $Evidence.connectedReady } else { $Evidence.installationReady }
}

if (-not ("Splatplost.EvidenceFileIdentityV1" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Splatplost
{
    public static class EvidenceFileIdentityV1
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct ByHandleFileInformation
        {
            public uint FileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateFile(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(
            IntPtr file,
            out ByHandleFileInformation information);

        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);

        private static ByHandleFileInformation GetIdentity(string path)
        {
            IntPtr handle = CreateFile(path, 0, 7, IntPtr.Zero, 3, 0, IntPtr.Zero);
            if (handle == new IntPtr(-1))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "Unable to identify a runtime-evidence path safely.");
            }
            try
            {
                ByHandleFileInformation information;
                if (!GetFileInformationByHandle(handle, out information))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "Unable to identify a runtime-evidence path safely.");
                }
                return information;
            }
            finally
            {
                CloseHandle(handle);
            }
        }

        private static SafeFileHandle OpenPinnedPackageObject(
            string path,
            bool requireDirectory)
        {
            const uint GENERIC_READ = 0x80000000;
            const uint FILE_READ_ATTRIBUTES = 0x00000080;
            const uint FILE_SHARE_READ = 0x00000001;
            const uint OPEN_EXISTING = 3;
            const uint FILE_ATTRIBUTE_DIRECTORY = 0x00000010;
            const uint FILE_ATTRIBUTE_REPARSE_POINT = 0x00000400;
            const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
            const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;

            uint desiredAccess = requireDirectory ? FILE_READ_ATTRIBUTES : GENERIC_READ;
            uint flags = FILE_FLAG_OPEN_REPARSE_POINT;
            if (requireDirectory)
            {
                flags |= FILE_FLAG_BACKUP_SEMANTICS;
            }
            IntPtr rawHandle = CreateFile(
                path,
                desiredAccess,
                FILE_SHARE_READ,
                IntPtr.Zero,
                OPEN_EXISTING,
                flags,
                IntPtr.Zero);
            if (rawHandle == new IntPtr(-1))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "The release package object could not be pinned for read-only sharing: " + path);
            }

            try
            {
                ByHandleFileInformation information;
                if (!GetFileInformationByHandle(rawHandle, out information))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "The pinned release package object identity could not be read: " + path);
                }
                bool isDirectory = (information.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
                bool isReparsePoint = (information.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
                if (isReparsePoint || isDirectory != requireDirectory)
                {
                    throw new IOException(
                        "The release package object is an unsafe reparse point or has the wrong type: " + path);
                }

                SafeFileHandle safeHandle = new SafeFileHandle(rawHandle, true);
                rawHandle = IntPtr.Zero;
                return safeHandle;
            }
            finally
            {
                if (rawHandle != IntPtr.Zero)
                {
                    CloseHandle(rawHandle);
                }
            }
        }

        public static SafeFileHandle OpenPinnedPackageDirectory(string path)
        {
            return OpenPinnedPackageObject(path, true);
        }

        public static FileStream OpenPinnedPackageFile(string path)
        {
            SafeFileHandle handle = OpenPinnedPackageObject(path, false);
            try
            {
                FileStream stream = new FileStream(handle, FileAccess.Read);
                handle = null;
                return stream;
            }
            finally
            {
                if (handle != null)
                {
                    handle.Dispose();
                }
            }
        }

        public static bool AreSameExistingFile(string firstPath, string secondPath)
        {
            if (!File.Exists(firstPath) || !File.Exists(secondPath))
            {
                return false;
            }
            ByHandleFileInformation first = GetIdentity(firstPath);
            ByHandleFileInformation second = GetIdentity(secondPath);
            return first.VolumeSerialNumber == second.VolumeSerialNumber &&
                first.FileIndexHigh == second.FileIndexHigh &&
                first.FileIndexLow == second.FileIndexLow;
        }

        public static string GetExistingFileIdentity(
            string path,
            out uint numberOfLinks,
            out uint fileAttributes)
        {
            if (!File.Exists(path))
            {
                throw new FileNotFoundException(
                    "Unable to identify a trusted executable because it does not exist.",
                    path);
            }
            ByHandleFileInformation information = GetIdentity(path);
            numberOfLinks = information.NumberOfLinks;
            fileAttributes = information.FileAttributes;
            return String.Format(
                "{0:X8}:{1:X8}:{2:X8}",
                information.VolumeSerialNumber,
                information.FileIndexHigh,
                information.FileIndexLow);
        }
    }
}
"@
}

function Assert-SafeEvidenceDestination {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$ProtectedPaths
    )

    $resolved = [IO.Path]::GetFullPath($Path)
    if (Test-Path -LiteralPath $resolved -PathType Container) {
        throw "EvidencePath exists as a directory; specify a JSON file path: $resolved"
    }
    foreach ($protectedPath in @($ProtectedPaths)) {
        if ([string]::IsNullOrWhiteSpace($protectedPath)) { continue }
        $resolvedProtected = [IO.Path]::GetFullPath($protectedPath)
        $sameSpelling = [string]::Equals(
            $resolved.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar),
            $resolvedProtected.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar),
            [StringComparison]::OrdinalIgnoreCase
        )
        if ($sameSpelling -or [Splatplost.EvidenceFileIdentityV1]::AreSameExistingFile($resolved, $resolvedProtected)) {
            throw "EvidencePath would overwrite a protected verifier input: $resolvedProtected"
        }
    }
    return $resolved
}

function Write-RuntimeEvidenceAtomically {
    param(
        [Parameter(Mandatory = $true)]$Evidence,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $temporaryPath = Join-Path $directory (".{0}.{1}.tmp" -f [IO.Path]::GetFileName($Path), [Guid]::NewGuid().ToString("N"))
    try {
        $json = $Evidence | ConvertTo-Json -Depth 10
        [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "Runtime evidence was not published as the requested file: $Path"
        }
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

if (-not ("Splatplost.RuntimeEvidenceV1" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;

namespace Splatplost
{
    public sealed class RuntimeBridgeStatus
    {
        public uint BytesReturned { get; set; }
        public uint ChannelsAndStage { get; set; }
        public uint InitializationStatus { get; set; }
        public ulong LocalAddress { get; set; }
    }

    public static class RuntimeEvidenceV1
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

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool DeviceIoControl(
            IntPtr device,
            uint ioControlCode,
            IntPtr inputBuffer,
            uint inputBufferLength,
            [Out] byte[] outputBuffer,
            uint outputBufferLength,
            out uint bytesReturned,
            IntPtr overlapped);

        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);

        public static uint QueryCodeIntegrityOptions()
        {
            SystemCodeIntegrityInformation information = new SystemCodeIntegrityInformation();
            information.Length = (uint)Marshal.SizeOf(information);
            int returnLength;
            int status = NtQuerySystemInformation(
                103,
                ref information,
                Marshal.SizeOf(information),
                out returnLength);
            if (status < 0)
            {
                throw new InvalidOperationException(
                    String.Format("NtQuerySystemInformation failed with NTSTATUS 0x{0:X8}.", unchecked((uint)status)));
            }
            if (returnLength < Marshal.SizeOf(information))
            {
                throw new InvalidDataException("Windows returned an incomplete code-integrity state.");
            }
            return information.CodeIntegrityOptions;
        }

        public static RuntimeBridgeStatus QueryBridge(string path)
        {
            IntPtr handle = CreateFile(
                path,
                0,
                0x00000003,
                IntPtr.Zero,
                3,
                0,
                IntPtr.Zero);
            if (handle == new IntPtr(-1))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to open the Splatplost driver bridge.");
            }

            try
            {
                byte[] output = new byte[16];
                uint bytesReturned;
                if (!DeviceIoControl(
                    handle,
                    0x00222000,
                    IntPtr.Zero,
                    0,
                    output,
                    (uint)output.Length,
                    out bytesReturned,
                    IntPtr.Zero))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "The Splatplost status IOCTL failed.");
                }
                if (bytesReturned < output.Length)
                {
                    throw new InvalidDataException(
                        String.Format("The Splatplost status IOCTL returned {0} bytes; 16 are required.", bytesReturned));
                }

                return new RuntimeBridgeStatus
                {
                    BytesReturned = bytesReturned,
                    ChannelsAndStage = BitConverter.ToUInt32(output, 0),
                    InitializationStatus = BitConverter.ToUInt32(output, 4),
                    LocalAddress = BitConverter.ToUInt64(output, 8)
                };
            }
            finally
            {
                CloseHandle(handle);
            }
        }
    }
}
"@
}

$verificationPackagePin = $null
$verificationPackagePinError = $null
try {
if (-not [string]::IsNullOrWhiteSpace($PackageDirectory)) {
    try {
        $verificationPackagePin = New-VerificationPackagePin -PackageDirectory $PackageDirectory
    } catch {
        $verificationPackagePinError = Get-ErrorText $_
    }
}

$evidence = [ordered]@{
    schemaVersion = 1
    generatedAtUtc = [DateTime]::UtcNow.ToString("o")
    computerName = $env:COMPUTERNAME
    osVersion = [Environment]::OSVersion.VersionString
    requireConnected = [bool]$RequireConnected
    bridgePath = $BridgePath
    checks = [ordered]@{
        administrator = New-Check
        secureBoot = New-Check
        testSigning = New-Check
        memoryIntegrity = New-Check
        pnp = New-Check
        microsoftSignedPackage = New-Check
        bridgeInitialization = New-Check
        hidChannels = New-Check
    }
    installationReady = $false
    connectedReady = $false
    passed = $false
    failures = @()
    limitations = @(
        "This verifier does not perform Nintendo Switch input/output or drawing validation.",
        "A passing connected check proves the driver reports both HID L2CAP channels, not that every controller protocol command succeeds."
    )
}

$administrator = $evidence.checks.administrator
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $administrator.value = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $administrator.identity = $identity.Name
    $administrator.readable = $true
    $administrator.passed = [bool]$administrator.value
} catch {
    $administrator.error = Get-ErrorText $_
}

$secureBoot = $evidence.checks.secureBoot
try {
    if (-not (Get-Command Confirm-SecureBootUEFI -ErrorAction SilentlyContinue)) {
        throw "Confirm-SecureBootUEFI is unavailable on this Windows installation."
    }
    $secureBoot.enabled = [bool](Confirm-SecureBootUEFI -ErrorAction Stop)
    $secureBoot.readable = $true
    $secureBoot.passed = $secureBoot.enabled
} catch {
    $secureBoot.error = Get-ErrorText $_
}

$testSigning = $evidence.checks.testSigning
$codeIntegrityOptions = $null
try {
    $codeIntegrityOptions = [Splatplost.RuntimeEvidenceV1]::QueryCodeIntegrityOptions()
    $testSigning.codeIntegrityOptions = Format-UInt32Hex $codeIntegrityOptions
    $testSigning.codeIntegrityEnabled = [bool](($codeIntegrityOptions -band 0x01) -ne 0)
    $testSigning.hvciKernelModeCodeIntegrityEnabled = [bool](($codeIntegrityOptions -band 0x400) -ne 0)
    $testSigning.enabled = [bool](($codeIntegrityOptions -band 0x02) -ne 0)
    $testSigning.readable = $true
    $testSigning.passed = -not $testSigning.enabled
} catch {
    $testSigning.error = Get-ErrorText $_
}

$memoryIntegrity = $evidence.checks.memoryIntegrity
try {
    $deviceGuard = Get-CimInstance -Namespace "root\Microsoft\Windows\DeviceGuard" -ClassName "Win32_DeviceGuard" -ErrorAction Stop
    if ($null -eq $deviceGuard) {
        throw "Win32_DeviceGuard returned no state."
    }
    $configured = @($deviceGuard.SecurityServicesConfigured | ForEach-Object { [int]$_ })
    $running = @($deviceGuard.SecurityServicesRunning | ForEach-Object { [int]$_ })
    $memoryIntegrity.virtualizationBasedSecurityStatus = [int]$deviceGuard.VirtualizationBasedSecurityStatus
    $memoryIntegrity.securityServicesConfigured = $configured
    $memoryIntegrity.securityServicesRunning = $running
    $memoryIntegrity.configured = $configured -contains 2
    $memoryIntegrity.running = $running -contains 2
    if ($null -eq $codeIntegrityOptions) {
        throw "Kernel code-integrity options could not be read, so active HVCI enforcement cannot be confirmed."
    }
    $memoryIntegrity.kernelModeCodeIntegrityEnabled = [bool](($codeIntegrityOptions -band 0x400) -ne 0)
    $memoryIntegrity.readable = $true
    $memoryIntegrity.passed = [bool](
        $memoryIntegrity.running -and
        $memoryIntegrity.virtualizationBasedSecurityStatus -eq 2 -and
        $memoryIntegrity.kernelModeCodeIntegrityEnabled
    )
} catch {
    $memoryIntegrity.error = Get-ErrorText $_
}

$pnp = $evidence.checks.pnp
$pnpDevices = @()
$installedBinaryPath = $null
$installedRadioAddress = [uint64]0
$installedRadioStateValid = $false
$activeInfHashes = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
try {
    $devices = @(Get-PnpDevice -PresentOnly -InstanceId "$hardwareIdPrefix*" -ErrorAction Stop)
    if ($devices.Count -eq 0) {
        throw "No present Splatplost BTHENUM profile device was found."
    }

    $allHealthy = $true
    foreach ($device in $devices) {
        $service = (Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName "DEVPKEY_Device_Service" -ErrorAction Stop).Data
        $problemCode = (Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName "DEVPKEY_Device_ProblemCode" -ErrorAction Stop).Data
        $problemStatus = (Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName "DEVPKEY_Device_ProblemStatus" -ErrorAction Stop).Data
        $driverInfPath = (Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName "DEVPKEY_Device_DriverInfPath" -ErrorAction Stop).Data
        if ($null -eq $service -or $null -eq $problemCode -or $null -eq $problemStatus -or $null -eq $driverInfPath) {
            throw "Windows returned an incomplete PnP property set for $($device.InstanceId)."
        }

        $publishedInfHealthy = [string]$driverInfPath -match '^oem\d+\.inf$'
        $publishedInfPath = $null
        $publishedInfHash = $null
        if ($publishedInfHealthy) {
            $publishedInfPath = Join-Path (Join-Path $env:SystemRoot "INF") ([string]$driverInfPath)
            if (-not (Test-Path -LiteralPath $publishedInfPath -PathType Leaf)) {
                $publishedInfHealthy = $false
            } else {
                $publishedInfText = Get-Content -LiteralPath $publishedInfPath -Raw
                $publishedInfHealthy = [bool](
                    $publishedInfText.IndexOf($hardwareIdPrefix, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
                    $publishedInfText -match '(?im)^\s*AddService\s*=\s*SplatplostBluetooth\s*,' -and
                    $publishedInfText -match '(?im)^\s*ProviderString\s*=\s*"Splatplost"\s*$'
                )
                if ($publishedInfHealthy) {
                    $publishedInfHash = (Get-FileHash -LiteralPath $publishedInfPath -Algorithm SHA256).Hash.ToLowerInvariant()
                    [void]$activeInfHashes.Add($publishedInfHash)
                }
            }
        }

        $healthy = [bool](
            [string]$service -eq $driverServiceName -and
            [int]$problemCode -eq 0 -and
            [uint32]$problemStatus -eq 0 -and
            [string]$device.Status -eq "OK" -and
            $publishedInfHealthy
        )
        if (-not $healthy) { $allHealthy = $false }
        $pnpDevices += [ordered]@{
            instanceId = $device.InstanceId
            friendlyName = $device.FriendlyName
            status = [string]$device.Status
            service = [string]$service
            problemCode = [int]$problemCode
            problemStatus = Format-UInt32Hex ([uint32]$problemStatus)
            driverInfPath = [string]$driverInfPath
            publishedInfPath = $publishedInfPath
            publishedInfSha256 = $publishedInfHash
            publishedInfIdentityValid = $publishedInfHealthy
            healthy = $healthy
        }
    }

    $serviceKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$driverServiceName"
    $serviceProperties = Get-ItemProperty -LiteralPath $serviceKey -Name ImagePath -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace([string]$serviceProperties.ImagePath)) {
        throw "The Splatplost driver service has no ImagePath."
    }
    $installedBinaryPath = Resolve-KernelImagePath ([string]$serviceProperties.ImagePath)
    if (-not (Test-Path -LiteralPath $installedBinaryPath -PathType Leaf)) {
        throw "The installed driver binary was not found: $installedBinaryPath"
    }

    $systemDriver = Get-CimInstance -ClassName Win32_SystemDriver -Filter "Name='$driverServiceName'" -ErrorAction Stop
    if ($null -eq $systemDriver) {
        throw "Win32_SystemDriver did not return the Splatplost service."
    }
    $driverRunning = [bool]($systemDriver.Started -and [string]$systemDriver.State -eq "Running")

    $managedStatePath = "HKLM:\SOFTWARE\Splatplost"
    $managedStateKey = Get-Item -LiteralPath $managedStatePath -ErrorAction Stop
    if (
        $managedStateKey.GetValueKind("InstalledRadioAddress") -ne
        [Microsoft.Win32.RegistryValueKind]::QWord
    ) {
        throw "InstalledRadioAddress is missing or is not a QWORD in the managed installation state."
    }
    $installedRadioAddress = [uint64]$managedStateKey.GetValue(
        "InstalledRadioAddress",
        [uint64]0,
        [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
    )
    if ($installedRadioAddress -eq 0) {
        throw "InstalledRadioAddress is zero in the managed installation state."
    }
    $installedRadioStateValid = $true

    $pnp.hardwareIdPrefix = $hardwareIdPrefix
    $pnp.devices = $pnpDevices
    $pnp.expectedPresentDeviceCount = 1
    $pnp.presentDeviceCount = $devices.Count
    $pnp.exactPresentDeviceCount = [bool]($devices.Count -eq 1)
    $pnp.installedBinaryPath = $installedBinaryPath
    $pnp.installedRadioAddress = Format-BluetoothAddress $installedRadioAddress
    $pnp.installedRadioAddressRegistryKind = "QWord"
    $pnp.systemDriverState = [string]$systemDriver.State
    $pnp.systemDriverStarted = [bool]$systemDriver.Started
    $pnp.readable = $true
    $pnp.passed = Test-SplatplostPnpReady `
        -PresentDeviceCount $devices.Count `
        -AllDevicesHealthy $allHealthy `
        -DriverRunning $driverRunning `
        -InstalledRadioStateValid $installedRadioStateValid
} catch {
    $pnp.hardwareIdPrefix = $hardwareIdPrefix
    $pnp.devices = $pnpDevices
    $pnp.installedBinaryPath = $installedBinaryPath
    $pnp.error = Get-ErrorText $_
}

$packageSignature = $evidence.checks.microsoftSignedPackage
$signTool = $null
$resolvedPackage = $null
try {
    if ([string]::IsNullOrWhiteSpace($PackageDirectory)) {
        throw "-PackageDirectory is required because the release manifest, signature evidence, and support-file hashes are not installed in Driver Store. Run this verifier from the extracted release-driver folder with -PackageDirectory ."
    }
    if ($verificationPackagePinError) {
        throw "The release package could not be pinned against transient replacement: $verificationPackagePinError"
    }
    if ($null -eq $verificationPackagePin) {
        throw "The release package was not pinned before evidence collection."
    }
    $resolvedPackage = [string]$verificationPackagePin.PackageDirectory
    if (-not (Test-Path -LiteralPath $resolvedPackage -PathType Container)) {
        throw "Package directory was not found: $resolvedPackage"
    }
    $packageEvidenceStart = Get-PinnedVerificationPackageSnapshot `
        -PackagePin $verificationPackagePin
    Assert-PinnedVerificationPackageSnapshot `
        -Expected $verificationPackagePin.InitialSnapshot `
        -Actual $packageEvidenceStart `
        -Checkpoint "package evidence start"

    $infPath = Join-Path $resolvedPackage "SplatplostBluetooth.inf"
    $sysPath = Join-Path $resolvedPackage "SplatplostBluetooth.sys"
    $catPath = Join-Path $resolvedPackage "SplatplostBluetooth.cat"
    foreach ($requiredPath in @($infPath, $sysPath, $catPath)) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "Microsoft-signed package evidence is missing: $requiredPath"
        }
    }
    if (-not $installedBinaryPath) {
        throw "The installed Splatplost service binary path could not be read, so package identity cannot be correlated."
    }

    $releaseManifest = Confirm-SignedReleaseManifest -PackageDirectory $resolvedPackage
    $infHash = (Get-FileHash -LiteralPath $infPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $packageHash = (Get-FileHash -LiteralPath $sysPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $catalogHash = (Get-FileHash -LiteralPath $catPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $installedHash = (Get-FileHash -LiteralPath $installedBinaryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $packageStartSnapshot = [pscustomobject]@{
        ReleaseManifestSha256 = $releaseManifest.sha256
        ReleaseManifestFileCount = $releaseManifest.fileCount
        InfSha256 = $infHash
        SysSha256 = $packageHash
        CatalogSha256 = $catalogHash
        InstalledSysSha256 = $installedHash
    }
    $hashesMatch = $packageHash -eq $installedHash
    $activeInfMatches = [bool]($activeInfHashes.Count -eq 1 -and $activeInfHashes.Contains($infHash))
    $signatureEvidence = Confirm-SignatureEvidence -PackageDirectory $resolvedPackage -ExpectedFiles @{
        "SplatplostBluetooth.inf" = $infHash
        "SplatplostBluetooth.sys" = $packageHash
        "SplatplostBluetooth.cat" = $catalogHash
    }
    $catalogSignature = Convert-SignatureToEvidence (Get-AuthenticodeSignature -LiteralPath $catPath)
    $driverSignature = Convert-SignatureToEvidence (Get-IsolatedAuthenticodeSignature $sysPath)

    if ($signatureEvidence.signingKind -ne $catalogSignature.hardwareSigningKind) {
        throw "The signature evidence signing kind does not match the live Microsoft catalog signature."
    }

    $membershipVerified = $false
    $membershipVerificationSource = $null
    $signToolSnapshot = Resolve-TrustedSignTool $SignToolPath
    $signTool = [string]$signToolSnapshot.Path
    $signToolTranscripts = [ordered]@{}
    $catalogVerification = Invoke-TrustedSignTool `
        -Snapshot $signToolSnapshot `
        -Arguments @("verify", "/kp", "/v", $catPath) `
        -PackagePin $verificationPackagePin
    $catalogOutput = @($catalogVerification.Output)
    $signToolTranscripts.catalog = $catalogOutput
    $catalogExitCode = $catalogVerification.ExitCode
    if ($catalogExitCode -ne 0) {
        throw "SignTool rejected or warned on the Microsoft catalog (exit code $catalogExitCode): $($catalogOutput -join ' | ')"
    }
    foreach ($member in @($infPath, $sysPath)) {
        $memberName = [IO.Path]::GetFileName($member)
        $memberVerification = Invoke-TrustedSignTool `
            -Snapshot $signToolSnapshot `
            -Arguments @("verify", "/kp", "/c", $catPath, $member) `
            -PackagePin $verificationPackagePin
        $memberOutput = @($memberVerification.Output)
        $signToolTranscripts[$memberName] = $memberOutput
        $memberExitCode = $memberVerification.ExitCode
        if ($memberExitCode -ne 0) {
            throw "SignTool rejected or warned on $memberName catalog membership (exit code $memberExitCode): $($memberOutput -join ' | ')"
        }
    }
    $membershipVerified = $true
    $membershipVerificationSource = "trusted Microsoft SignTool /kp"

    # Re-read the complete release manifest and every core binary after all
    # external signature checks. A user-writable extracted package must remain
    # one consistent snapshot for the entire verification interval.
    $endReleaseManifest = Confirm-SignedReleaseManifest -PackageDirectory $resolvedPackage
    $packageEndSnapshot = [pscustomobject]@{
        ReleaseManifestSha256 = $endReleaseManifest.sha256
        ReleaseManifestFileCount = $endReleaseManifest.fileCount
        InfSha256 = (Get-FileHash -LiteralPath $infPath -Algorithm SHA256).Hash.ToLowerInvariant()
        SysSha256 = (Get-FileHash -LiteralPath $sysPath -Algorithm SHA256).Hash.ToLowerInvariant()
        CatalogSha256 = (Get-FileHash -LiteralPath $catPath -Algorithm SHA256).Hash.ToLowerInvariant()
        InstalledSysSha256 = (Get-FileHash -LiteralPath $installedBinaryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    Assert-ExactPackageSnapshot -Expected $packageStartSnapshot -Actual $packageEndSnapshot
    $packageEvidenceEnd = Get-PinnedVerificationPackageSnapshot `
        -PackagePin $verificationPackagePin
    Assert-PinnedVerificationPackageSnapshot `
        -Expected $verificationPackagePin.InitialSnapshot `
        -Actual $packageEvidenceEnd `
        -Checkpoint "package evidence completion"

    $packageSignature.packageDirectory = $resolvedPackage
    $packageSignature.infPath = $infPath
    $packageSignature.sysPath = $sysPath
    $packageSignature.catPath = $catPath
    $packageSignature.installedBinaryPath = $installedBinaryPath
    $packageSignature.packageSysSha256 = $packageHash
    $packageSignature.installedSysSha256 = $installedHash
    $packageSignature.installedBinaryMatchesPackage = $hashesMatch
    $packageSignature.packageInfSha256 = $infHash
    $packageSignature.activePublishedInfSha256 = @($activeInfHashes)
    $packageSignature.activePublishedInfMatchesPackage = $activeInfMatches
    $packageSignature.releaseManifest = $releaseManifest
    $packageSignature.signatureEvidence = $signatureEvidence
    $packageSignature.catalogSignature = $catalogSignature
    $packageSignature.embeddedDriverSignature = $driverSignature
    $packageSignature.signToolPath = $signTool
    $packageSignature.signToolIdentity = $signToolSnapshot
    $packageSignature.startSnapshot = $packageStartSnapshot
    $packageSignature.endSnapshot = $packageEndSnapshot
    $packageSignature.endSnapshotVerified = $true
    $packageSignature.catalogMembershipVerified = $membershipVerified
    $packageSignature.catalogMembershipVerificationSource = $membershipVerificationSource
    $packageSignature.signToolTranscripts = $signToolTranscripts
    $packageSignature.readable = $true
    $packageSignature.passed = [bool](
        $hashesMatch -and
        $activeInfMatches -and
        $releaseManifest.verified -and
        $signatureEvidence.exactFileHashesVerified -and
        $catalogSignature.validMicrosoftHardwareSignature -and
        $driverSignature.validMicrosoftSignature -and
        $membershipVerified
    )
} catch {
    $packageSignature.error = Get-ErrorText $_
}

$bridge = $evidence.checks.bridgeInitialization
$channels = $evidence.checks.hidChannels
try {
    $status = [Splatplost.RuntimeEvidenceV1]::QueryBridge($BridgePath)
    $stage = [uint32]($status.ChannelsAndStage -shr 16)
    $channelMask = [uint32]($status.ChannelsAndStage -band 0xFFFF)
    $controlConnected = [bool](($channelMask -band 0x01) -ne 0)
    $interruptConnected = [bool](($channelMask -band 0x02) -ne 0)
    $localAddress = Format-BluetoothAddress $status.LocalAddress
    $localAddressMatchesInstalledState = [bool](
        $installedRadioStateValid -and
        $installedRadioAddress -ne 0 -and
        $status.LocalAddress -eq $installedRadioAddress
    )

    $bridge.bytesReturned = [uint32]$status.BytesReturned
    $bridge.initializationStage = $stage
    $bridge.initializationStageName = if ($stage -eq $readyStage) { "ready" } else { "not-ready" }
    $bridge.initializationStatus = Format-UInt32Hex ([uint32]$status.InitializationStatus)
    $bridge.localBluetoothAddress = $localAddress
    $bridge.localBluetoothAddressValid = [bool]($status.LocalAddress -ne 0)
    $bridge.installedRadioAddress = if ($installedRadioAddress -ne 0) {
        Format-BluetoothAddress $installedRadioAddress
    } else {
        $null
    }
    $bridge.localAddressMatchesInstalledState = $localAddressMatchesInstalledState
    $bridge.readable = $true
    $bridge.passed = Test-SplatplostBridgeReady `
        -Stage $stage `
        -InitializationStatus ([uint32]$status.InitializationStatus) `
        -LocalAddress ([uint64]$status.LocalAddress) `
        -InstalledRadioAddress $installedRadioAddress

    $channels.channelMask = "0x{0:X4}" -f $channelMask
    $channels.control = [ordered]@{ psm = "0x{0:X4}" -f $controlPsm; connected = $controlConnected }
    $channels.interrupt = [ordered]@{ psm = "0x{0:X4}" -f $interruptPsm; connected = $interruptConnected }
    $channels.readable = $true
    $channels.passed = [bool]($controlConnected -and $interruptConnected)
} catch {
    $bridge.error = Get-ErrorText $_
    $channels.error = "Channel state is unreadable because the bridge status query failed."
}

Complete-RuntimeEvidence -Evidence $evidence -RequireConnected ([bool]$RequireConnected)

if ($null -ne $verificationPackagePin) {
    try {
        $prePublicationPackageSnapshot = Get-PinnedVerificationPackageSnapshot `
            -PackagePin $verificationPackagePin
        Assert-PinnedVerificationPackageSnapshot `
            -Expected $verificationPackagePin.InitialSnapshot `
            -Actual $prePublicationPackageSnapshot `
            -Checkpoint "immediately before evidence publication"
    } catch {
        $packageSignature.readable = $false
        $packageSignature.passed = $false
        $packageSignature.error = Get-ErrorText $_
        Complete-RuntimeEvidence -Evidence $evidence -RequireConnected ([bool]$RequireConnected)
    }
}

$protectedEvidenceInputs = @($PSCommandPath)
foreach ($candidateInput in @($installedBinaryPath, $SignToolPath, $signTool)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$candidateInput)) {
        $protectedEvidenceInputs += [string]$candidateInput
    }
}
$packageDirectories = @($PackageDirectory, $resolvedPackage) | Where-Object {
    -not [string]::IsNullOrWhiteSpace([string]$_) -and (Test-Path -LiteralPath $_ -PathType Container)
} | ForEach-Object { [IO.Path]::GetFullPath([string]$_) } | Select-Object -Unique
foreach ($packagePath in $packageDirectories) {
    $protectedEvidenceInputs += @(Get-ChildItem -LiteralPath $packagePath -File -Force -Recurse | Where-Object {
        $_.Name -ne "SplatplostBluetooth-runtime-evidence.json"
    } | ForEach-Object { $_.FullName })
}

$resolvedEvidencePath = Assert-SafeEvidenceDestination -Path $EvidencePath -ProtectedPaths @($protectedEvidenceInputs)
Write-RuntimeEvidenceAtomically -Evidence $evidence -Path $resolvedEvidencePath

if (-not $evidence.passed) {
    throw "Splatplost runtime verification failed. Evidence: $resolvedEvidencePath. Failures: $($evidence.failures -join ' | ')"
}

[PSCustomObject]@{
    Evidence = $resolvedEvidencePath
    InstallationReady = $evidence.installationReady
    ConnectedReady = $evidence.connectedReady
    Passed = $evidence.passed
}
} finally {
    if ($null -ne $verificationPackagePin) {
        Close-VerificationPackagePin -PackagePin $verificationPackagePin
        $verificationPackagePin = $null
    }
}
