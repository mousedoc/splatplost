param(
    [Parameter(Mandatory = $true)]
    [string]$PackageDirectory,

    [Parameter(Mandatory = $true)]
    [string]$SymbolsPath,

    [string]$CatalogPath,
    [string]$Inf2CatPath,
    [string]$OutputPath = (Join-Path $PWD "SplatplostBluetooth-attestation.cab"),

    [switch]$PrepareOnly,
    [string]$SigningCertificateThumbprint,
    [string]$TimestampUrl,
    [string]$SignToolPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-ExistingFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description was not found: $Path"
    }

    return [IO.Path]::GetFullPath($Path)
}

function Resolve-WdkTool {
    param(
        [string]$ExplicitPath,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($ExplicitPath) {
        return Resolve-ExistingFile -Path $ExplicitPath -Description $Name
    }

    $command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) {
        return $command.Source
    }

    $roots = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\bin",
        (Join-Path $env:USERPROFILE ".nuget\packages\microsoft.windows.wdk.x64")
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Container }

    foreach ($root in $roots) {
        $candidate = Get-ChildItem -LiteralPath $root -Recurse -Filter $Name -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match "\\(x64|amd64)\\" } |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if ($candidate) {
            return $candidate.FullName
        }
    }

    throw "$Name was not found. Install the current WDK or pass its path explicitly."
}

function Assert-SubmissionManifest {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$ExpectedCabPath,
        [Parameter(Mandatory = $true)][string]$ExpectedCabHash,
        [Parameter(Mandatory = $true)][bool]$ExpectedSigned,
        [Parameter(Mandatory = $true)][string[]]$ExpectedEntries,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$ExpectedFileHashes
    )

    $parsed = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    if ($null -eq $parsed -or
            $null -eq $parsed.PSObject.Properties["schemaVersion"] -or
            [int]$parsed.schemaVersion -ne 1 -or
            $null -eq $parsed.PSObject.Properties["cab"] -or
            $null -eq $parsed.cab -or
            $null -eq $parsed.cab.PSObject.Properties["path"] -or
            $null -eq $parsed.cab.PSObject.Properties["sha256"] -or
            $null -eq $parsed.cab.PSObject.Properties["signed"] -or
            $null -eq $parsed.PSObject.Properties["files"] -or
            $null -eq $parsed.PSObject.Properties["fileHashes"]) {
        throw "The generated submission manifest is invalid or unsupported: $ManifestPath"
    }

    $recordedCabPath = [IO.Path]::GetFullPath([string]$parsed.cab.path)
    if (-not [string]::Equals($recordedCabPath, $ExpectedCabPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The generated submission manifest records the wrong final CAB path."
    }
    if ([string]$parsed.cab.sha256 -cne $ExpectedCabHash -or [string]$parsed.cab.sha256 -notmatch '^[0-9a-f]{64}$') {
        throw "The generated submission manifest records the wrong CAB digest."
    }
    if ([bool]$parsed.cab.signed -ne $ExpectedSigned) {
        throw "The generated submission manifest records the wrong CAB signing state."
    }

    $actualEntries = @($parsed.files | ForEach-Object { [string]$_ } | Sort-Object)
    $expectedSorted = @($ExpectedEntries | Sort-Object)
    $differences = @(Compare-Object -ReferenceObject $expectedSorted -DifferenceObject $actualEntries -CaseSensitive)
    if ($actualEntries.Count -ne $expectedSorted.Count -or
            @($actualEntries | Select-Object -Unique).Count -ne $actualEntries.Count -or
            $differences.Count -ne 0) {
        throw "The generated submission manifest does not record the exact CAB membership."
    }

    $actualHashEntries = @($parsed.fileHashes)
    if ($actualHashEntries.Count -ne $ExpectedFileHashes.Count) {
        throw "The generated submission manifest does not record every CAB member digest exactly once."
    }
    foreach ($expectedPath in $ExpectedFileHashes.Keys) {
        $matches = @($actualHashEntries | Where-Object { [string]$_.path -ceq [string]$expectedPath })
        $expectedHash = [string]$ExpectedFileHashes[$expectedPath]
        if ($matches.Count -ne 1 -or
                [string]$matches[0].sha256 -cne $expectedHash -or
                [string]$matches[0].sha256 -notmatch '^[0-9a-f]{64}$') {
            throw "The generated submission manifest records an invalid CAB member digest: $expectedPath"
        }
    }
}

$package = [IO.Path]::GetFullPath($PackageDirectory)
if (-not (Test-Path -LiteralPath $package -PathType Container)) {
    throw "Driver package directory was not found: $package"
}

$inf = Resolve-ExistingFile -Path (Join-Path $package "SplatplostBluetooth.inf") -Description "Driver INF"
$sys = Resolve-ExistingFile -Path (Join-Path $package "SplatplostBluetooth.sys") -Description "Driver binary"
$pdb = Resolve-ExistingFile -Path $SymbolsPath -Description "Driver symbols"
if ([IO.Path]::GetExtension($pdb) -ine ".pdb") {
    throw "Driver symbols must be a PDB file: $pdb"
}
if ((Get-Item -LiteralPath $pdb).Length -eq 0) {
    throw "Driver symbols file is empty: $pdb"
}

$buildManifestPath = Resolve-ExistingFile `
    -Path (Join-Path $package "SplatplostBluetooth-build-manifest.json") `
    -Description "Driver build manifest"
$buildManifest = Get-Content -LiteralPath $buildManifestPath -Raw | ConvertFrom-Json
if ([int]$buildManifest.schemaVersion -ne 1 -or -not $buildManifest.files) {
    throw "The driver build manifest is invalid or unsupported."
}
$buildManifestHash = (Get-FileHash -LiteralPath $buildManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
$driverVersionProperty = $buildManifest.PSObject.Properties["driverVersion"]
$driverVersion = if ($null -ne $driverVersionProperty) { [string]$driverVersionProperty.Value } else { $null }
$expectedBuildHashes = [ordered]@{}
foreach ($requiredBuildFile in @(
    [ordered]@{ name = "SplatplostBluetooth.inf"; path = $inf },
    [ordered]@{ name = "SplatplostBluetooth.sys"; path = $sys },
    [ordered]@{ name = "SplatplostBluetooth.pdb"; path = $pdb }
)) {
    $entries = @($buildManifest.files | Where-Object { $_.name -eq $requiredBuildFile.name })
    if ($entries.Count -ne 1 -or [string]$entries[0].sha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw "The build manifest does not contain exactly one valid identity for $($requiredBuildFile.name)."
    }
    $actualHash = (Get-FileHash -LiteralPath $requiredBuildFile.path -Algorithm SHA256).Hash
    if ($actualHash -ne [string]$entries[0].sha256) {
        throw "$($requiredBuildFile.name) does not match the build manifest. Rebuild before preparing a submission."
    }
    $expectedBuildHashes[$requiredBuildFile.name] = ([string]$entries[0].sha256).ToLowerInvariant()
}

$output = [IO.Path]::GetFullPath($OutputPath)
if ([IO.Path]::GetExtension($output) -ine ".cab") {
    throw "The submission output must use the .cab extension: $output"
}
$outputDirectory = [IO.Path]::GetDirectoryName($output)
$cabName = [IO.Path]::GetFileName($output)
if (-not $outputDirectory -or -not $cabName) {
    throw "The submission output must have a parent directory and file name: $output"
}
if ($cabName -cnotmatch '^[A-Za-z0-9_.-]+$') {
    throw "Use only ASCII letters, digits, dot, underscore, and hyphen in the CAB file name: $cabName"
}
$manifestPath = "$output.manifest.json"
foreach ($finalPath in @($output, $manifestPath)) {
    if (Test-Path -LiteralPath $finalPath -PathType Container) {
        throw "A final submission path exists as a directory: $finalPath"
    }
}

$willSign = -not [string]::IsNullOrWhiteSpace($SigningCertificateThumbprint)
if (-not $willSign -and -not $PrepareOnly) {
    throw "Supply -SigningCertificateThumbprint and -TimestampUrl, or explicitly use -PrepareOnly to create an unsigned structural test CAB."
}
if ($willSign -and [string]::IsNullOrWhiteSpace($TimestampUrl)) {
    throw "The certificate provider's RFC 3161 URL is required when signing. Pass -TimestampUrl."
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("splatplost-partner-center-" + [Guid]::NewGuid().ToString("N"))
$driverFolderName = "SplatplostBluetooth"
$staging = Join-Path $temporaryRoot $driverFolderName
$cabWork = Join-Path $temporaryRoot "cab"
$transactionId = [Guid]::NewGuid().ToString("N")
$cabStem = [IO.Path]::GetFileNameWithoutExtension($cabName)
$manifestName = [IO.Path]::GetFileName($manifestPath)
$stagedCab = Join-Path $outputDirectory ("." + $cabStem + ".staging-" + $transactionId + ".cab")
$stagedManifest = Join-Path $outputDirectory ("." + $manifestName + ".staging-" + $transactionId + ".json")
$cabBackup = Join-Path $outputDirectory ("." + $cabName + ".backup-" + $transactionId)
$manifestBackup = Join-Path $outputDirectory ("." + $manifestName + ".backup-" + $transactionId)
$commitComplete = $false
$stagedCabOwned = $false
$stagedManifestOwned = $false
New-Item -ItemType Directory -Force -Path $staging, $cabWork | Out-Null

try {
    Copy-Item -LiteralPath $inf -Destination (Join-Path $staging "SplatplostBluetooth.inf")
    Copy-Item -LiteralPath $sys -Destination (Join-Path $staging "SplatplostBluetooth.sys")
    Copy-Item -LiteralPath $pdb -Destination (Join-Path $staging "SplatplostBluetooth.pdb")
    foreach ($name in @("SplatplostBluetooth.inf", "SplatplostBluetooth.sys", "SplatplostBluetooth.pdb")) {
        $stagedHash = (Get-FileHash -LiteralPath (Join-Path $staging $name) -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($stagedHash -cne [string]$expectedBuildHashes[$name]) {
            throw "The staged build file changed while the submission was being prepared: $name"
        }
    }

    $resolvedCatalog = $null
    if ($CatalogPath) {
        $resolvedCatalog = Resolve-ExistingFile -Path $CatalogPath -Description "Driver catalog"
    } else {
        $packageCatalog = Join-Path $package "SplatplostBluetooth.cat"
        if (Test-Path -LiteralPath $packageCatalog -PathType Leaf) {
            $resolvedCatalog = [IO.Path]::GetFullPath($packageCatalog)
        }
    }

    if ($resolvedCatalog) {
        Copy-Item -LiteralPath $resolvedCatalog -Destination (Join-Path $staging "SplatplostBluetooth.cat")
    } else {
        $inf2cat = Resolve-WdkTool -ExplicitPath $Inf2CatPath -Name "Inf2Cat.exe"
        & $inf2cat "/driver:$staging" "/os:10_VB_X64,10_CO_X64,10_NI_X64,10_GE_X64"
        if ($LASTEXITCODE -ne 0) {
            throw "Inf2Cat failed with exit code $LASTEXITCODE."
        }
    }

    $stagedCatalog = Join-Path $staging "SplatplostBluetooth.cat"
    if (-not (Test-Path -LiteralPath $stagedCatalog -PathType Leaf)) {
        throw "The staged package does not contain SplatplostBluetooth.cat."
    }

    # Inf2Cat /nocat checks package signability; it does not prove that a supplied
    # catalog contains the current INF/SYS hashes. SignTool /c performs that
    # membership check. A development catalog can have an untrusted signer, so
    # membership is accepted only when SignTool explicitly reports the file in
    # the catalog; trust of the submission is provided separately by the signed CAB.
    $signtool = Resolve-WdkTool -ExplicitPath $SignToolPath -Name "signtool.exe"
    foreach ($stagedFile in @(
        (Join-Path $staging "SplatplostBluetooth.inf"),
        (Join-Path $staging "SplatplostBluetooth.sys")
    )) {
        $catalogVerification = (& $signtool verify /v /c $stagedCatalog $stagedFile 2>&1 | Out-String)
        if ($catalogVerification -notmatch "File is signed in catalog:") {
            throw "The provided catalog does not cover $([IO.Path]::GetFileName($stagedFile)). SignTool output: $catalogVerification"
        }
    }

    $stagedMemberHashes = [ordered]@{}
    foreach ($name in @("SplatplostBluetooth.inf", "SplatplostBluetooth.sys", "SplatplostBluetooth.pdb")) {
        $stagedHash = (Get-FileHash -LiteralPath (Join-Path $staging $name) -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($stagedHash -cne [string]$expectedBuildHashes[$name]) {
            throw "The staged build file changed during catalog verification: $name"
        }
        $stagedMemberHashes["$driverFolderName/$name"] = $stagedHash
    }
    $stagedMemberHashes["$driverFolderName/SplatplostBluetooth.cat"] = `
        (Get-FileHash -LiteralPath $stagedCatalog -Algorithm SHA256).Hash.ToLowerInvariant()

    $ddf = Join-Path $cabWork "submission.ddf"
    $ddfLines = @(
        "; Splatplost Hardware Dev Center submission",
        ".OPTION EXPLICIT",
        ".Set CabinetFileCountThreshold=0",
        ".Set FolderFileCountThreshold=0",
        ".Set FolderSizeThreshold=0",
        ".Set MaxCabinetSize=0",
        ".Set MaxDiskFileCount=0",
        ".Set MaxDiskSize=0",
        ".Set CompressionType=MSZIP",
        ".Set Cabinet=on",
        ".Set Compress=on",
        ".Set CabinetNameTemplate=$cabName",
        ".Set DiskDirectoryTemplate=Disk1",
        ".Set DestinationDir=$driverFolderName",
        ('"{0}" SplatplostBluetooth.inf' -f (Join-Path $staging "SplatplostBluetooth.inf")),
        ('"{0}" SplatplostBluetooth.sys' -f (Join-Path $staging "SplatplostBluetooth.sys")),
        ('"{0}" SplatplostBluetooth.pdb' -f (Join-Path $staging "SplatplostBluetooth.pdb")),
        ('"{0}" SplatplostBluetooth.cat' -f $stagedCatalog)
    )
    Set-Content -LiteralPath $ddf -Value $ddfLines -Encoding Ascii

    Push-Location $cabWork
    try {
        & "$env:SystemRoot\System32\makecab.exe" /F $ddf
        if ($LASTEXITCODE -ne 0) {
            throw "MakeCab failed with exit code $LASTEXITCODE."
        }
    } finally {
        Pop-Location
    }

    $createdCab = Join-Path (Join-Path $cabWork "Disk1") $cabName
    if (-not (Test-Path -LiteralPath $createdCab -PathType Leaf)) {
        throw "MakeCab did not create the expected CAB: $createdCab"
    }

    $certificate = $null
    if ($willSign) {
        $normalizedThumbprint = $SigningCertificateThumbprint.Replace(" ", "").ToUpperInvariant()
        $machineStore = $false
        $certificate = Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
            Where-Object { $_.Thumbprint -eq $normalizedThumbprint } |
            Select-Object -First 1
        if (-not $certificate) {
            $certificate = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
                Where-Object { $_.Thumbprint -eq $normalizedThumbprint } |
                Select-Object -First 1
            $machineStore = [bool]$certificate
        }
        if (-not $certificate) {
            throw "The signing certificate was not found in CurrentUser/My or LocalMachine/My: $normalizedThumbprint"
        }
        if (-not $certificate.HasPrivateKey) {
            throw "The signing certificate does not expose an accessible private key: $normalizedThumbprint"
        }
        if ($certificate.NotAfter -le (Get-Date)) {
            throw "The signing certificate is expired: $($certificate.NotAfter.ToString('o'))"
        }

        $signArguments = @("sign", "/s", "MY")
        if ($machineStore) {
            $signArguments += "/sm"
        }
        $signArguments += @("/sha1", $normalizedThumbprint, "/fd", "SHA256", "/td", "SHA256", "/tr", $TimestampUrl, "/v", $createdCab)
        & $signtool @signArguments
        if ($LASTEXITCODE -ne 0) {
            throw "SignTool failed to sign the CAB with exit code $LASTEXITCODE."
        }
        & $signtool verify /pa /v $createdCab
        if ($LASTEXITCODE -ne 0) {
            throw "SignTool could not verify the signed CAB (exit code $LASTEXITCODE)."
        }
        $cabSignature = Get-AuthenticodeSignature -LiteralPath $createdCab
        if ($cabSignature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
            throw "Authenticode verification failed for the signed CAB: $($cabSignature.StatusMessage)"
        }
        if ($cabSignature.SignerCertificate.Thumbprint -ne $normalizedThumbprint) {
            throw "The CAB signer does not match the requested certificate thumbprint."
        }
    }

    # Validate the exact candidate that will be published. For signed CABs this
    # deliberately happens after signing so the signed bytes must still expand
    # to the exact Partner Center submission membership.
    $expanded = Join-Path $temporaryRoot "expanded"
    New-Item -ItemType Directory -Force -Path $expanded | Out-Null
    & "$env:SystemRoot\System32\expand.exe" -F:* $createdCab $expanded | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Expand failed while checking the CAB with exit code $LASTEXITCODE."
    }

    $actualEntries = @(Get-ChildItem -LiteralPath $expanded -Recurse -File |
        ForEach-Object { $_.FullName.Substring($expanded.Length + 1).Replace("\", "/") } |
        Sort-Object)
    $expectedEntries = @(
        "$driverFolderName/SplatplostBluetooth.cat",
        "$driverFolderName/SplatplostBluetooth.inf",
        "$driverFolderName/SplatplostBluetooth.pdb",
        "$driverFolderName/SplatplostBluetooth.sys"
    ) | Sort-Object
    if (($actualEntries -join "`n") -cne ($expectedEntries -join "`n")) {
        throw "CAB contents are invalid. Expected: $($expectedEntries -join ', '); actual: $($actualEntries -join ', ')"
    }
    foreach ($relativePath in $expectedEntries) {
        $expandedPath = Join-Path $expanded ($relativePath.Replace("/", "\"))
        $expandedHash = (Get-FileHash -LiteralPath $expandedPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($expandedHash -cne [string]$stagedMemberHashes[$relativePath]) {
            throw "CAB member bytes do not match the validated staging snapshot: $relativePath"
        }
    }

    $candidateCabHash = (Get-FileHash -LiteralPath $createdCab -Algorithm SHA256).Hash.ToLowerInvariant()
    $candidateManifest = Join-Path $temporaryRoot ($cabName + ".manifest.json")
    if ([string]::IsNullOrWhiteSpace($driverVersion)) {
        throw "The driver build manifest does not record driverVersion."
    }
    $manifest = [ordered]@{
        schemaVersion = 1
        purpose = "Microsoft Hardware Dev Center attestation submission preparation"
        cab = [ordered]@{
            path = $output
            sha256 = $candidateCabHash
            signed = $willSign
            signerThumbprint = if ($certificate) { $certificate.Thumbprint } else { $null }
        }
        architecture = "x64"
        sourceBuild = [ordered]@{
            manifestSha256 = $buildManifestHash
            driverVersion = $driverVersion
            infSha256 = [string]$expectedBuildHashes["SplatplostBluetooth.inf"]
            sysSha256 = [string]$expectedBuildHashes["SplatplostBluetooth.sys"]
            pdbSha256 = [string]$expectedBuildHashes["SplatplostBluetooth.pdb"]
            catalogSha256 = [string]$stagedMemberHashes["$driverFolderName/SplatplostBluetooth.cat"]
        }
        driverFolder = $driverFolderName
        files = @($expectedEntries)
        fileHashes = @($expectedEntries | ForEach-Object {
            [ordered]@{
                path = $_
                sha256 = [string]$stagedMemberHashes[$_]
            }
        })
        limitations = @(
            "This manifest proves only CAB structure and local signature verification.",
            "It does not prove that the signing certificate is currently registered with Partner Center or satisfies the selected submission policy.",
            "Partner Center acceptance, Microsoft signing, HVCI compatibility, installation, and device functionality require separate evidence."
        )
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $candidateManifest -Encoding UTF8
    Assert-SubmissionManifest `
        -ManifestPath $candidateManifest `
        -ExpectedCabPath $output `
        -ExpectedCabHash $candidateCabHash `
        -ExpectedSigned $willSign `
        -ExpectedEntries $expectedEntries `
        -ExpectedFileHashes $stagedMemberHashes
    $candidateManifestHash = (Get-FileHash -LiteralPath $candidateManifest -Algorithm SHA256).Hash.ToLowerInvariant()

    # Only after generation, catalog membership, expansion, optional signing,
    # and manifest validation have all succeeded do artifacts enter sibling
    # staging paths in the final output directory.
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
    $transactionPathCollisions = @(
        @($stagedCab, $stagedManifest, $cabBackup, $manifestBackup) |
            Where-Object { Test-Path -LiteralPath $_ }
    )
    if ($transactionPathCollisions.Count -ne 0) {
        throw "A submission staging or backup path unexpectedly already exists: $($transactionPathCollisions -join ', ')"
    }

    $stagedCabOwned = $true
    Copy-Item -LiteralPath $createdCab -Destination $stagedCab
    $stagedManifestOwned = $true
    Copy-Item -LiteralPath $candidateManifest -Destination $stagedManifest
    $stagedCabHash = (Get-FileHash -LiteralPath $stagedCab -Algorithm SHA256).Hash.ToLowerInvariant()
    $stagedManifestHash = (Get-FileHash -LiteralPath $stagedManifest -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($stagedCabHash -ne $candidateCabHash -or $stagedManifestHash -ne $candidateManifestHash) {
        throw "A sibling-staged submission artifact does not match its fully validated temporary candidate."
    }
    Assert-SubmissionManifest `
        -ManifestPath $stagedManifest `
        -ExpectedCabPath $output `
        -ExpectedCabHash $stagedCabHash `
        -ExpectedSigned $willSign `
        -ExpectedEntries $expectedEntries `
        -ExpectedFileHashes $stagedMemberHashes

    # Recheck final path types immediately before replacement so a concurrent
    # directory cannot be moved into a backup as if it were an owned artifact.
    foreach ($finalPath in @($output, $manifestPath)) {
        if (Test-Path -LiteralPath $finalPath -PathType Container) {
            throw "A final submission path exists as a directory: $finalPath"
        }
    }

    $cabBackedUp = $false
    $manifestBackedUp = $false
    $cabInstalled = $false
    $manifestInstalled = $false
    try {
        if (Test-Path -LiteralPath $output) {
            Move-Item -LiteralPath $output -Destination $cabBackup
            $cabBackedUp = $true
        }
        if (Test-Path -LiteralPath $manifestPath) {
            Move-Item -LiteralPath $manifestPath -Destination $manifestBackup
            $manifestBackedUp = $true
        }

        Move-Item -LiteralPath $stagedCab -Destination $output
        $stagedCabOwned = $false
        $cabInstalled = $true
        Move-Item -LiteralPath $stagedManifest -Destination $manifestPath
        $stagedManifestOwned = $false
        $manifestInstalled = $true

        # Retain backups until the installed pair has also been re-hashed and
        # the installed manifest has been parsed against the installed CAB.
        $finalCabHash = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()
        $finalManifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($finalCabHash -ne $candidateCabHash -or $finalManifestHash -ne $candidateManifestHash) {
            throw "A final submission artifact changed during the sibling replacement transaction."
        }
        Assert-SubmissionManifest `
            -ManifestPath $manifestPath `
            -ExpectedCabPath $output `
            -ExpectedCabHash $finalCabHash `
            -ExpectedSigned $willSign `
            -ExpectedEntries $expectedEntries `
            -ExpectedFileHashes $stagedMemberHashes
        $commitComplete = $true
    } catch {
        $commitError = $_
        $rollbackFailures = @()
        if ($manifestInstalled -and (Test-Path -LiteralPath $manifestPath)) {
            try { Remove-Item -LiteralPath $manifestPath -Force } catch { $rollbackFailures += $_.Exception.Message }
        }
        if ($cabInstalled -and (Test-Path -LiteralPath $output)) {
            try { Remove-Item -LiteralPath $output -Force } catch { $rollbackFailures += $_.Exception.Message }
        }
        if ($manifestBackedUp -and (Test-Path -LiteralPath $manifestBackup) -and -not (Test-Path -LiteralPath $manifestPath)) {
            try { Move-Item -LiteralPath $manifestBackup -Destination $manifestPath } catch { $rollbackFailures += $_.Exception.Message }
        }
        if ($cabBackedUp -and (Test-Path -LiteralPath $cabBackup) -and -not (Test-Path -LiteralPath $output)) {
            try { Move-Item -LiteralPath $cabBackup -Destination $output } catch { $rollbackFailures += $_.Exception.Message }
        }
        if ($rollbackFailures.Count -ne 0) {
            throw "Submission replacement failed and rollback was incomplete. Original error: $($commitError.Exception.Message). Rollback errors: $($rollbackFailures -join '; '). Retained backups: $cabBackup ; $manifestBackup"
        }
        throw $commitError
    }

    foreach ($backup in @($cabBackup, $manifestBackup)) {
        if (Test-Path -LiteralPath $backup) {
            try {
                Remove-Item -LiteralPath $backup -Force
            } catch {
                Write-Warning "The validated submission was installed, but an old transaction backup could not be removed: $backup"
            }
        }
    }

    [PSCustomObject]@{
        Cab = $output
        Manifest = $manifestPath
        Signed = $willSign
        Sha256 = $candidateCabHash
    }
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        try {
            Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
        } catch {
            Write-Warning "Submission processing finished, but its temporary directory could not be removed: $temporaryRoot"
        }
    }
    if (-not $commitComplete) {
        if ($stagedCabOwned -and (Test-Path -LiteralPath $stagedCab)) {
            Remove-Item -LiteralPath $stagedCab -Force -ErrorAction SilentlyContinue
        }
        if ($stagedManifestOwned -and (Test-Path -LiteralPath $stagedManifest)) {
            Remove-Item -LiteralPath $stagedManifest -Force -ErrorAction SilentlyContinue
        }
    }
}
