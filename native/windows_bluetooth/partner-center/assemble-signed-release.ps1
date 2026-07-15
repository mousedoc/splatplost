param(
    [Parameter(Mandatory = $true)]
    [string]$SignedPackagePath,

    [Parameter(Mandatory = $true)]
    [string]$BuildOutputDirectory,

    [string]$OutputDirectory = (Join-Path $PWD "SplatplostBluetooth-microsoft-signed-x64"),
    [string]$ZipPath = (Join-Path $PWD "SplatplostBluetooth-microsoft-signed-x64.zip"),
    [string]$SignToolPath,
    [string]$InfVerifPath,
    [switch]$RunInfVerif,
    [switch]$AllowAttestation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "path-safety.ps1")

function Get-NormalizedFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return Get-SplatplostLexicalFullPath -Path $Path
}

function Assert-DisjointPaths {
    param([Parameter(Mandatory = $true)][array]$NamedPaths)

    $canonicalPaths = @($NamedPaths | ForEach-Object {
        [PSCustomObject]@{
            Name = $_.Name
            OriginalPath = $_.Path
            Path = Get-SplatplostCanonicalPath -Path $_.Path
        }
    })

    for ($leftIndex = 0; $leftIndex -lt $canonicalPaths.Count; $leftIndex++) {
        for ($rightIndex = $leftIndex + 1; $rightIndex -lt $canonicalPaths.Count; $rightIndex++) {
            $left = $canonicalPaths[$leftIndex]
            $right = $canonicalPaths[$rightIndex]
            if ((Test-SplatplostPathsAlias -Left $left.OriginalPath -Right $right.OriginalPath) -or
                    (Test-SplatplostSameOrDescendantPath -Candidate $left.Path -Ancestor $right.Path) -or
                    (Test-SplatplostSameOrDescendantPath -Candidate $right.Path -Ancestor $left.Path)) {
                throw "Path overlap is not allowed between $($left.Name) '$($left.OriginalPath)' and $($right.Name) '$($right.OriginalPath)'."
            }
        }
    }
}

function Assert-NoReparsePointAliases {
    param([Parameter(Mandatory = $true)][array]$NamedPaths)

    foreach ($namedPath in $NamedPaths) {
        $current = $namedPath.Path
        while ($current) {
            if (Test-Path -LiteralPath $current) {
                $item = Get-Item -LiteralPath $current -Force
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Reparse points are not allowed in release assembly paths because they can alias protected inputs: $($namedPath.Name) '$current'."
                }
            }
            $parent = [IO.Path]::GetDirectoryName($current)
            if (-not $parent -or [string]::Equals($parent, $current, [StringComparison]::OrdinalIgnoreCase)) {
                break
            }
            $current = $parent
        }
    }
}

function Assert-ExistingOutputOwned {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$AllowedNames
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "OutputDirectory exists but is not a directory: $Path"
    }

    $unexpected = @(Get-ChildItem -LiteralPath $Path -Force | Where-Object {
        $_.PSIsContainer -or $AllowedNames -notcontains $_.Name
    })
    if ($unexpected.Count -ne 0) {
        throw "OutputDirectory contains files not owned by this assembler: $($unexpected.Name -join ', ')"
    }
}

function Assert-DirectoryHasExactFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$ExpectedNames
    )

    $entries = @(Get-ChildItem -LiteralPath $Path -Force)
    $directories = @($entries | Where-Object { $_.PSIsContainer })
    if ($directories.Count -ne 0) {
        throw "The staged release must be flat; found directories: $($directories.Name -join ', ')"
    }
    $actualNames = @($entries | ForEach-Object { $_.Name } | Sort-Object)
    $expectedSorted = @($ExpectedNames | Sort-Object)
    $difference = @(Compare-Object -ReferenceObject $expectedSorted -DifferenceObject $actualNames)
    if ($actualNames.Count -ne $expectedSorted.Count -or $difference.Count -ne 0) {
        throw "Unexpected staged release contents: $($actualNames -join ', ')"
    }
}

function Assert-ArchiveMatchesDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$DirectoryPath
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $expectedFiles = @(Get-ChildItem -LiteralPath $DirectoryPath -File | Sort-Object Name)
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $archiveFiles = @($archive.Entries | Where-Object { $_.Name })
        $expectedNames = @($expectedFiles | ForEach-Object { $_.Name })
        $archiveNames = @($archiveFiles | ForEach-Object { $_.FullName })
        $seenNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach ($name in $archiveNames) {
            if (-not $seenNames.Add($name)) {
                throw "The staged ZIP contains a duplicate entry: $name"
            }
        }
        $nameDifferences = @(Compare-Object `
            -ReferenceObject $expectedNames `
            -DifferenceObject $archiveNames `
            -CaseSensitive)
        if ($archiveNames.Count -ne $expectedNames.Count -or $nameDifferences.Count -ne 0) {
            throw "The staged ZIP does not contain every expected release file exactly once. Expected: $($expectedNames -join ', '); actual: $($archiveNames -join ', ')"
        }
        foreach ($entry in $archiveFiles) {
            if ($entry.FullName -ne $entry.Name) {
                throw "The staged ZIP is not flat: $($entry.FullName)"
            }
            $matchingFile = @($expectedFiles | Where-Object { $_.Name -eq $entry.Name })
            if ($matchingFile.Count -ne 1) {
                throw "The staged ZIP contains an unexpected or duplicate entry: $($entry.Name)"
            }

            $stream = $entry.Open()
            $sha256 = [Security.Cryptography.SHA256]::Create()
            try {
                $archiveHash = ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace("-", "").ToLowerInvariant()
            } finally {
                $sha256.Dispose()
                $stream.Dispose()
            }
            $directoryHash = (Get-FileHash -LiteralPath $matchingFile[0].FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($archiveHash -ne $directoryHash) {
                throw "The staged ZIP content does not match the staged release file: $($entry.Name)"
            }
        }
    } finally {
        $archive.Dispose()
    }
}

function Get-PeSigningIndependentIdentity {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 0x100 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) {
        throw "Driver binary is not a valid PE image: $Path"
    }

    $peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
    if ($peOffset -lt 0x40 -or $peOffset -gt ($bytes.Length - 24) -or
            $bytes[$peOffset] -ne 0x50 -or $bytes[$peOffset + 1] -ne 0x45 -or
            $bytes[$peOffset + 2] -ne 0 -or $bytes[$peOffset + 3] -ne 0) {
        throw "Driver binary has an invalid PE header: $Path"
    }

    $coffOffset = $peOffset + 4
    $machine = [BitConverter]::ToUInt16($bytes, $coffOffset)
    $optionalHeaderSize = [BitConverter]::ToUInt16($bytes, $coffOffset + 16)
    $optionalOffset = $coffOffset + 20
    if ($optionalHeaderSize -lt 0x90 -or $optionalOffset + $optionalHeaderSize -gt $bytes.Length) {
        throw "Driver binary has a truncated PE optional header: $Path"
    }

    $magic = [BitConverter]::ToUInt16($bytes, $optionalOffset)
    if ($magic -eq 0x20b) {
        $numberOfDirectoriesOffset = $optionalOffset + 108
        $dataDirectoryOffset = $optionalOffset + 112
    } elseif ($magic -eq 0x10b) {
        $numberOfDirectoriesOffset = $optionalOffset + 92
        $dataDirectoryOffset = $optionalOffset + 96
    } else {
        throw "Driver binary has an unsupported PE optional-header magic: $Path"
    }

    $checksumOffset = $optionalOffset + 64
    $securityDirectoryOffset = $dataDirectoryOffset + (4 * 8)
    if ($numberOfDirectoriesOffset + 4 -gt $optionalOffset + $optionalHeaderSize -or
            $securityDirectoryOffset + 8 -gt $optionalOffset + $optionalHeaderSize) {
        throw "Driver binary does not contain a complete PE security directory: $Path"
    }
    $numberOfDirectories = [BitConverter]::ToUInt32($bytes, $numberOfDirectoriesOffset)
    if ($numberOfDirectories -le 4) {
        throw "Driver binary does not declare the PE security directory: $Path"
    }

    $certificateOffset = [BitConverter]::ToUInt32($bytes, $securityDirectoryOffset)
    $certificateSize = [BitConverter]::ToUInt32($bytes, $securityDirectoryOffset + 4)
    if (($certificateOffset -eq 0) -ne ($certificateSize -eq 0)) {
        throw "Driver binary has an inconsistent PE certificate-table entry: $Path"
    }
    if ($certificateSize -ne 0) {
        $certificateEnd = [uint64]$certificateOffset + [uint64]$certificateSize
        if (($certificateOffset % 8) -ne 0 -or
                $certificateOffset -lt ($optionalOffset + $optionalHeaderSize) -or
                $certificateEnd -gt [uint64]$bytes.Length) {
            throw "Driver binary has an invalid PE certificate-table range: $Path"
        }
    }

    # Authenticode excludes the PE checksum, the security-directory entry, and
    # the WIN_CERTIFICATE table. Removing precisely those mutable signing fields
    # produces a strict same-build identity while still allowing Microsoft to
    # replace or append the embedded signature returned by Partner Center.
    [Array]::Clear($bytes, $checksumOffset, 4)
    [Array]::Clear($bytes, $securityDirectoryOffset, 8)
    if ($certificateSize -eq 0) {
        $normalized = $bytes
    } else {
        $normalizedLength = $bytes.Length - [int]$certificateSize
        $normalized = New-Object byte[] $normalizedLength
        if ($certificateOffset -gt 0) {
            [Array]::Copy($bytes, 0, $normalized, 0, [int]$certificateOffset)
        }
        $suffixLength = $bytes.Length - ([int]$certificateOffset + [int]$certificateSize)
        if ($suffixLength -gt 0) {
            [Array]::Copy(
                $bytes,
                [int]$certificateOffset + [int]$certificateSize,
                $normalized,
                [int]$certificateOffset,
                $suffixLength)
        }
    }

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = ([BitConverter]::ToString($sha256.ComputeHash($normalized))).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha256.Dispose()
    }
    return [PSCustomObject]@{
        Sha256 = $hash
        Machine = [int]$machine
        OptionalHeaderMagic = [int]$magic
        CertificateTableSize = [uint64]$certificateSize
    }
}

function Invoke-SignedPackageVerification {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][hashtable]$Parameters,
        [Parameter(Mandatory = $true)][string]$Phase,
        [switch]$PermitAttestation
    )

    $verificationOutput = @(& $ScriptPath @Parameters)
    $verificationOutput | Out-Host
    $summaries = @($verificationOutput | Where-Object {
        $null -ne $_ -and $null -ne $_.PSObject.Properties["SigningKind"]
    })
    if ($summaries.Count -ne 1) {
        throw "$Phase verification did not return exactly one signing summary."
    }

    $signingKind = [string]$summaries[0].SigningKind
    if ($signingKind -eq "attestation" -and -not $PermitAttestation) {
        throw "Attestation signing is testing-only and is not accepted for a default end-user release. Re-run with -AllowAttestation only for an explicitly controlled test distribution."
    }
    if ($signingKind -notin @("hlk-whcp", "attestation")) {
        throw "$Phase verification returned an unsupported signing kind: $signingKind"
    }
    return $summaries[0]
}

$verifyScript = Join-Path $PSScriptRoot "verify-signed-package.ps1"
$signedInput = Get-NormalizedFullPath $SignedPackagePath
$supportRoot = Get-NormalizedFullPath $BuildOutputDirectory
$output = Get-NormalizedFullPath $OutputDirectory
$zip = Get-NormalizedFullPath $ZipPath

if ([IO.Path]::GetExtension($zip) -ine ".zip") {
    throw "ZipPath must end in .zip: $zip"
}
$releasePaths = @(
    [PSCustomObject]@{ Name = "SignedPackagePath"; Path = $signedInput },
    [PSCustomObject]@{ Name = "BuildOutputDirectory"; Path = $supportRoot },
    [PSCustomObject]@{ Name = "OutputDirectory"; Path = $output },
    [PSCustomObject]@{ Name = "ZipPath"; Path = $zip }
)
Assert-NoReparsePointAliases -NamedPaths $releasePaths
Assert-DisjointPaths -NamedPaths $releasePaths

$outputParent = [IO.Path]::GetDirectoryName($output)
$outputLeaf = [IO.Path]::GetFileName($output)
$zipParent = [IO.Path]::GetDirectoryName($zip)
$zipLeaf = [IO.Path]::GetFileName($zip)
if (-not $outputParent -or -not $outputLeaf) {
    throw "OutputDirectory cannot be a filesystem root: $output"
}
if (-not $zipParent -or -not $zipLeaf) {
    throw "ZipPath must have a parent directory and file name: $zip"
}

if (-not (Test-Path -LiteralPath $signedInput)) {
    throw "The Partner Center signed package was not found: $signedInput"
}
if (-not (Test-Path -LiteralPath $supportRoot -PathType Container)) {
    throw "The matching build output directory was not found: $supportRoot"
}
if (Test-Path -LiteralPath $zip -PathType Container) {
    throw "ZipPath exists as a directory: $zip"
}

$signedPayloadNames = @(
    "SplatplostBluetooth.inf",
    "SplatplostBluetooth.sys",
    "SplatplostBluetooth.cat"
)
$supportFiles = @(
    "install-driver.ps1",
    "install-driver.cmd",
    "uninstall-driver.ps1",
    "uninstall-driver.cmd",
    "verify-runtime.ps1",
    "THIRD_PARTY_NOTICES.md",
    "SplatplostBluetooth-build-manifest.json"
)
$releaseMetadataNames = @(
    "SplatplostBluetooth-signature-evidence.json",
    "SplatplostBluetooth-release-manifest.json"
)
$finalOutputNames = @($signedPayloadNames + $supportFiles + $releaseMetadataNames)
$allowedExistingOutputNames = @($finalOutputNames + "SplatplostDevelopment.cer")

Assert-ExistingOutputOwned -Path $output -AllowedNames $allowedExistingOutputNames

foreach ($name in $supportFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $supportRoot $name) -PathType Leaf)) {
        throw "The matching build output is incomplete; missing $name."
    }
}

$buildManifestPath = Join-Path $supportRoot "SplatplostBluetooth-build-manifest.json"
$buildManifestHash = (Get-FileHash -LiteralPath $buildManifestPath -Algorithm SHA256).Hash
$buildManifest = Get-Content -LiteralPath $buildManifestPath -Raw | ConvertFrom-Json
if ([int]$buildManifest.schemaVersion -ne 1 -or -not $buildManifest.files) {
    throw "The build manifest is invalid or unsupported: $buildManifestPath"
}
$manifestEntries = @($buildManifest.files)
$manifestNames = @($manifestEntries | ForEach-Object { [string]$_.name })
if (@($manifestNames | Select-Object -Unique).Count -ne $manifestNames.Count) {
    throw "The build manifest contains duplicate file identities."
}
foreach ($entry in $manifestEntries) {
    if ([string]$entry.name -notmatch '^[A-Za-z0-9_.-]+$' -or [string]$entry.sha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw "The build manifest contains an unsafe or invalid file entry."
    }
    $buildFile = Join-Path $supportRoot ([string]$entry.name)
    if (-not (Test-Path -LiteralPath $buildFile -PathType Leaf)) {
        throw "The matching build file recorded in the manifest is missing: $buildFile"
    }
    $actualHash = (Get-FileHash -LiteralPath $buildFile -Algorithm SHA256).Hash
    if ($actualHash -ne [string]$entry.sha256) {
        throw "The matching build output changed after its manifest was written: $($entry.name)"
    }
}

$requiredManifestNames = @("SplatplostBluetooth.inf", "SplatplostBluetooth.sys") + @($supportFiles | Where-Object {
    $_ -ne "SplatplostBluetooth-build-manifest.json"
})
foreach ($requiredName in $requiredManifestNames) {
    if (@($manifestEntries | Where-Object { [string]$_.name -eq $requiredName }).Count -ne 1) {
        throw "The build manifest must contain exactly one identity for $requiredName."
    }
}
$rawInfEntry = @($manifestEntries | Where-Object { [string]$_.name -eq "SplatplostBluetooth.inf" })

$transactionId = [Guid]::NewGuid().ToString("N")
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("splatplost-assemble-signed-" + $transactionId)
$stagingDirectory = Join-Path $outputParent ("." + $outputLeaf + ".staging-" + $transactionId)
$outputBackup = Join-Path $outputParent ("." + $outputLeaf + ".backup-" + $transactionId)
$stagedZip = Join-Path $zipParent ("." + $zipLeaf + ".staging-" + $transactionId + ".zip")
$zipBackup = Join-Path $zipParent ("." + $zipLeaf + ".backup-" + $transactionId)
$commitComplete = $false

New-Item -ItemType Directory -Force -Path $temporaryRoot | Out-Null
try {
    $preflightEvidence = Join-Path $temporaryRoot "preflight-evidence.json"
    $verifyParameters = @{
        SignedPackagePath = $signedInput
        EvidencePath = $preflightEvidence
    }
    if ($SignToolPath) { $verifyParameters.SignToolPath = $SignToolPath }
    if ($InfVerifPath) { $verifyParameters.InfVerifPath = $InfVerifPath }
    if ($RunInfVerif) { $verifyParameters.RunInfVerif = $true }
    $preflightSummary = Invoke-SignedPackageVerification `
        -ScriptPath $verifyScript `
        -Parameters $verifyParameters `
        -Phase "Preflight" `
        -PermitAttestation:$AllowAttestation

    if (Test-Path -LiteralPath $signedInput -PathType Container) {
        $signedRoot = $signedInput
    } else {
        if ([IO.Path]::GetExtension($signedInput) -ine ".zip") {
            throw "The signed package must be an extracted directory or Partner Center .zip download."
        }
        $signedRoot = Join-Path $temporaryRoot "expanded"
        Expand-Archive -LiteralPath $signedInput -DestinationPath $signedRoot -Force
    }

    $signedFiles = [ordered]@{}
    foreach ($name in $signedPayloadNames) {
        $matches = @(Get-ChildItem -LiteralPath $signedRoot -Recurse -File -Filter $name)
        if ($matches.Count -ne 1) {
            throw "Expected exactly one $name in the signed result; found $($matches.Count)."
        }
        $signedFiles[$name] = $matches[0].FullName
    }
    $signedInfHash = (Get-FileHash -LiteralPath $signedFiles["SplatplostBluetooth.inf"] -Algorithm SHA256).Hash
    if ($signedInfHash -ne [string]$rawInfEntry[0].sha256) {
        throw "The Microsoft-signed package INF does not match this build manifest. Use the exact build output submitted to Partner Center."
    }
    $unsignedDriverIdentity = Get-PeSigningIndependentIdentity `
        -Path (Join-Path $supportRoot "SplatplostBluetooth.sys")
    $signedDriverIdentity = Get-PeSigningIndependentIdentity `
        -Path $signedFiles["SplatplostBluetooth.sys"]
    if ($unsignedDriverIdentity.Machine -ne 0x8664 -or $signedDriverIdentity.Machine -ne 0x8664) {
        throw "Both the submitted and Microsoft-signed driver binaries must be x64 PE images."
    }
    if ($unsignedDriverIdentity.Sha256 -cne $signedDriverIdentity.Sha256) {
        throw "The Microsoft-signed SYS does not match the submitted build after excluding Authenticode signing fields."
    }

    New-Item -ItemType Directory -Force -Path $outputParent | Out-Null
    New-Item -ItemType Directory -Force -Path $zipParent | Out-Null
    Assert-NoReparsePointAliases -NamedPaths $releasePaths
    $transactionPathCollisions = @(
        @(
            $stagingDirectory,
            $stagedZip,
            $outputBackup,
            $zipBackup
        ) | Where-Object { Test-Path -LiteralPath $_ }
    )
    if ($transactionPathCollisions.Count -ne 0) {
        throw "A transaction staging or backup path unexpectedly already exists: $($transactionPathCollisions -join ', ')"
    }
    New-Item -ItemType Directory -Path $stagingDirectory | Out-Null

    foreach ($entry in $signedFiles.GetEnumerator()) {
        Copy-Item -LiteralPath $entry.Value -Destination (Join-Path $stagingDirectory $entry.Key)
    }
    foreach ($name in $supportFiles) {
        Copy-Item -LiteralPath (Join-Path $supportRoot $name) -Destination (Join-Path $stagingDirectory $name)
    }

    $stagedBuildManifestHash = (Get-FileHash -LiteralPath (Join-Path $stagingDirectory "SplatplostBluetooth-build-manifest.json") -Algorithm SHA256).Hash
    if ($stagedBuildManifestHash -ne $buildManifestHash) {
        throw "The staged build manifest changed while the release was being assembled."
    }

    foreach ($name in $supportFiles | Where-Object { $_ -ne "SplatplostBluetooth-build-manifest.json" }) {
        $manifestEntry = @($manifestEntries | Where-Object { [string]$_.name -eq $name })[0]
        $stagedHash = (Get-FileHash -LiteralPath (Join-Path $stagingDirectory $name) -Algorithm SHA256).Hash
        if ($stagedHash -ne [string]$manifestEntry.sha256) {
            throw "The staged support file does not match the submitted build manifest: $name"
        }
    }
    $stagedInfHash = (Get-FileHash -LiteralPath (Join-Path $stagingDirectory "SplatplostBluetooth.inf") -Algorithm SHA256).Hash
    if ($stagedInfHash -ne [string]$rawInfEntry[0].sha256) {
        throw "The staged signed INF no longer matches the submitted build manifest."
    }
    $stagedDriverIdentity = Get-PeSigningIndependentIdentity `
        -Path (Join-Path $stagingDirectory "SplatplostBluetooth.sys")
    if ($stagedDriverIdentity.Machine -ne 0x8664 -or
            $stagedDriverIdentity.Sha256 -cne $unsignedDriverIdentity.Sha256) {
        throw "The staged Microsoft-signed SYS no longer matches the submitted x64 build identity."
    }

    $finalEvidence = Join-Path $stagingDirectory "SplatplostBluetooth-signature-evidence.json"
    $verifyParameters.SignedPackagePath = $stagingDirectory
    $verifyParameters.EvidencePath = $finalEvidence
    $finalSummary = Invoke-SignedPackageVerification `
        -ScriptPath $verifyScript `
        -Parameters $verifyParameters `
        -Phase "Staged release" `
        -PermitAttestation:$AllowAttestation
    if ([string]$finalSummary.SigningKind -ne [string]$preflightSummary.SigningKind) {
        throw "The signing kind changed between preflight and staged verification."
    }
    if (-not (Test-Path -LiteralPath $finalEvidence -PathType Leaf)) {
        throw "Staged verification did not write signature evidence."
    }

    $manifestPath = Join-Path $stagingDirectory "SplatplostBluetooth-release-manifest.json"
    $manifest = [ordered]@{
        schemaVersion = 1
        assembledAtUtc = [DateTime]::UtcNow.ToString("o")
        signingKind = [string]$finalSummary.SigningKind
        attestationTestingOptIn = [bool]$AllowAttestation
        driverContentIdentity = [ordered]@{
            algorithm = "sha256-pe-excluding-authenticode-fields"
            sha256 = [string]$stagedDriverIdentity.Sha256
            machine = "0x8664"
        }
        signedSource = $signedInput
        supportBuildOutput = $supportRoot
        files = @(Get-ChildItem -LiteralPath $stagingDirectory -File | Sort-Object Name | ForEach-Object {
            [ordered]@{
                name = $_.Name
                sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        })
        limitations = @(
            "Microsoft signature and signed INF identity are verified against the exact submitted build manifest before assembly.",
            "Attestation-signed output is accepted only with explicit -AllowAttestation opt-in and is for controlled testing, not a default end-user release.",
            "The returned SYS is bound to the submitted build by a SHA-256 identity that excludes only the PE checksum, security-directory entry, and WIN_CERTIFICATE table changed by Authenticode signing.",
            "Installation, HVCI loading, Bluetooth channels, Switch protocol, and plotting require verify-runtime.ps1 and physical hardware evidence."
        )
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    Assert-DirectoryHasExactFiles -Path $stagingDirectory -ExpectedNames $finalOutputNames
    Compress-Archive -Path (Join-Path $stagingDirectory "*") -DestinationPath $stagedZip
    Assert-ArchiveMatchesDirectory -ArchivePath $stagedZip -DirectoryPath $stagingDirectory
    $stagedZipHash = (Get-FileHash -LiteralPath $stagedZip -Algorithm SHA256).Hash.ToLowerInvariant()

    # Recheck immediately before the transaction so a concurrently added user
    # file is never swept into the backup/replacement operation.
    Assert-NoReparsePointAliases -NamedPaths $releasePaths
    Assert-DisjointPaths -NamedPaths $releasePaths
    Assert-ExistingOutputOwned -Path $output -AllowedNames $allowedExistingOutputNames

    $outputBackedUp = $false
    $zipBackedUp = $false
    $outputInstalled = $false
    $zipInstalled = $false
    try {
        if (Test-Path -LiteralPath $output) {
            Move-Item -LiteralPath $output -Destination $outputBackup
            $outputBackedUp = $true
        }
        if (Test-Path -LiteralPath $zip) {
            Move-Item -LiteralPath $zip -Destination $zipBackup
            $zipBackedUp = $true
        }
        Move-Item -LiteralPath $stagingDirectory -Destination $output
        $outputInstalled = $true
        Move-Item -LiteralPath $stagedZip -Destination $zip
        $zipInstalled = $true

        # Keep the backups until the installed paths have been checked as well.
        # A same-parent move should preserve bytes, but this also fails closed if
        # another process races the replacement and changes either final path.
        Assert-DirectoryHasExactFiles -Path $output -ExpectedNames $finalOutputNames
        Assert-ArchiveMatchesDirectory -ArchivePath $zip -DirectoryPath $output
        $finalZipHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($finalZipHash -ne $stagedZipHash) {
            throw "The final ZIP hash changed during the sibling-path replacement transaction."
        }
        $commitComplete = $true
    } catch {
        $commitError = $_
        $rollbackFailures = @()
        if ($zipInstalled -and (Test-Path -LiteralPath $zip)) {
            try { Remove-Item -LiteralPath $zip -Force } catch { $rollbackFailures += $_.Exception.Message }
        }
        if ($outputInstalled -and (Test-Path -LiteralPath $output)) {
            try { Remove-Item -LiteralPath $output -Recurse -Force } catch { $rollbackFailures += $_.Exception.Message }
        }
        if ($zipBackedUp -and (Test-Path -LiteralPath $zipBackup) -and -not (Test-Path -LiteralPath $zip)) {
            try { Move-Item -LiteralPath $zipBackup -Destination $zip } catch { $rollbackFailures += $_.Exception.Message }
        }
        if ($outputBackedUp -and (Test-Path -LiteralPath $outputBackup) -and -not (Test-Path -LiteralPath $output)) {
            try { Move-Item -LiteralPath $outputBackup -Destination $output } catch { $rollbackFailures += $_.Exception.Message }
        }
        if ($rollbackFailures.Count -ne 0) {
            throw "Release replacement failed and rollback was incomplete. Original error: $($commitError.Exception.Message). Rollback errors: $($rollbackFailures -join '; '). Retained backups: $outputBackup ; $zipBackup"
        }
        throw $commitError
    }

    foreach ($backup in @($outputBackup, $zipBackup)) {
        if (Test-Path -LiteralPath $backup) {
            try {
                Remove-Item -LiteralPath $backup -Recurse -Force
            } catch {
                Write-Warning "The validated release was installed, but an old transaction backup could not be removed: $backup"
            }
        }
    }

    [PSCustomObject]@{
        OutputDirectory = $output
        Zip = $zip
        Evidence = (Join-Path $output "SplatplostBluetooth-signature-evidence.json")
        Manifest = (Join-Path $output "SplatplostBluetooth-release-manifest.json")
        SigningKind = [string]$finalSummary.SigningKind
        Sha256 = $finalZipHash
    }
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not $commitComplete) {
        if (Test-Path -LiteralPath $stagingDirectory) {
            Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $stagedZip) {
            Remove-Item -LiteralPath $stagedZip -Force -ErrorAction SilentlyContinue
        }
    }
}
