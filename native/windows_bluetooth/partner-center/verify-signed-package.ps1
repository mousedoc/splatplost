param(
    [Parameter(Mandatory = $true)]
    [string]$SignedPackagePath,

    [string]$SignToolPath,
    [string]$InfVerifPath,
    [switch]$RunInfVerif,
    [string]$EvidencePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "path-safety.ps1")

function Resolve-WdkTool {
    param(
        [string]$ExplicitPath,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($ExplicitPath) {
        if (-not (Test-Path -LiteralPath $ExplicitPath -PathType Leaf)) {
            throw "$Name was not found: $ExplicitPath"
        }
        return [IO.Path]::GetFullPath($ExplicitPath)
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

$input = [IO.Path]::GetFullPath($SignedPackagePath)
if (-not (Test-Path -LiteralPath $input)) {
    throw "Signed package was not found: $input"
}

if (-not $EvidencePath) {
    $EvidencePath = Join-Path (Split-Path -Parent $input) "SplatplostBluetooth-signature-evidence.json"
}
$resolvedEvidencePath = Get-SplatplostLexicalFullPath -Path $EvidencePath
if (Test-Path -LiteralPath $resolvedEvidencePath -PathType Container) {
    throw "EvidencePath exists as a directory: $resolvedEvidencePath"
}
if (Test-SplatplostPathsAlias -Left $input -Right $resolvedEvidencePath) {
    throw "EvidencePath must not alias or overwrite the signed-package input: $resolvedEvidencePath"
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("splatplost-signed-package-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $temporaryRoot | Out-Null

try {
    if (Test-Path -LiteralPath $input -PathType Container) {
        $root = $input
    } elseif ([IO.Path]::GetExtension($input) -ieq ".zip") {
        Expand-Archive -LiteralPath $input -DestinationPath $temporaryRoot -Force
        $root = $temporaryRoot
    } else {
        throw "The Partner Center result must be an extracted directory or the downloaded .zip file."
    }

    $filesByName = [ordered]@{}
    foreach ($name in @("SplatplostBluetooth.inf", "SplatplostBluetooth.sys", "SplatplostBluetooth.cat")) {
        $matches = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter $name)
        if ($matches.Count -ne 1) {
            throw "Expected exactly one $name in the signed-package payload; found $($matches.Count). Pass only the Partner Center signedPackage download."
        }
        $filesByName[$name] = $matches[0]
    }
    $directories = @($filesByName.Values | ForEach-Object { $_.Directory.FullName } | Select-Object -Unique)
    if ($directories.Count -ne 1) {
        throw "The INF, SYS, and CAT are not in the same signed driver-package directory."
    }
    $inf = $filesByName["SplatplostBluetooth.inf"].FullName
    $sys = $filesByName["SplatplostBluetooth.sys"].FullName
    $cat = $filesByName["SplatplostBluetooth.cat"].FullName
    foreach ($payloadPath in @($inf, $sys, $cat)) {
        if (Test-SplatplostPathsAlias -Left $payloadPath -Right $resolvedEvidencePath) {
            throw "EvidencePath must not alias or overwrite a signed payload file: $payloadPath"
        }
    }

    $signtool = Resolve-WdkTool -ExplicitPath $SignToolPath -Name "signtool.exe"
    $signToolWarnings = @()
    & $signtool verify /kp /v $cat
    $catalogExitCode = $LASTEXITCODE
    if ($catalogExitCode -notin @(0, 2)) {
        throw "The catalog does not pass SignTool kernel-policy verification (exit code $catalogExitCode)."
    }
    if ($catalogExitCode -eq 2) {
        $signToolWarnings += "Catalog verification completed with SignTool warnings."
    }
    foreach ($file in @($inf, $sys)) {
        & $signtool verify /kp /c $cat $file
        $membershipExitCode = $LASTEXITCODE
        if ($membershipExitCode -notin @(0, 2)) {
            throw "The Microsoft catalog does not cover $file (SignTool exit code $membershipExitCode)."
        }
        if ($membershipExitCode -eq 2) {
            $signToolWarnings += "Catalog membership verification completed with warnings for $([IO.Path]::GetFileName($file))."
        }
    }
    & $signtool verify /pa /ph /v /d $sys
    $driverExitCode = $LASTEXITCODE
    if ($driverExitCode -notin @(0, 2)) {
        throw "The driver binary does not pass embedded-signature verification (exit code $driverExitCode)."
    }
    if ($driverExitCode -eq 2) {
        $signToolWarnings += "Embedded driver verification completed with SignTool warnings (for example, a non-boot driver may have no page hashes)."
    }

    $catalogSignature = Get-AuthenticodeSignature -LiteralPath $cat
    $embeddedOnly = Join-Path $temporaryRoot "embedded-only"
    New-Item -ItemType Directory -Force -Path $embeddedOnly | Out-Null
    $embeddedDriver = Join-Path $embeddedOnly "SplatplostBluetooth.sys"
    Copy-Item -LiteralPath $sys -Destination $embeddedDriver
    # Isolating the SYS from its CAT prevents Get-AuthenticodeSignature from
    # reporting the catalog signer in place of the embedded PE signer.
    $driverSignature = Get-AuthenticodeSignature -LiteralPath $embeddedDriver
    foreach ($signature in @($catalogSignature, $driverSignature)) {
        if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
            throw "Authenticode verification failed for $($signature.Path): $($signature.StatusMessage)"
        }
        if (-not $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch "Microsoft") {
            throw "The signer is not identified as Microsoft for $($signature.Path)."
        }
    }

    $ekuOids = @($catalogSignature.SignerCertificate.Extensions |
        Where-Object { $_.Oid.Value -eq "2.5.29.37" } |
        ForEach-Object {
            $enhanced = [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]$_
            @($enhanced.EnhancedKeyUsages | ForEach-Object { $_.Value })
        })
    $attestationOid = "1.3.6.1.4.1.311.10.3.5.1"
    $whcpOid = "1.3.6.1.4.1.311.10.3.5"
    $signingKind = if ($ekuOids -contains $attestationOid) {
        "attestation"
    } elseif ($ekuOids -contains $whcpOid) {
        "hlk-whcp"
    } else {
        "microsoft-unclassified"
    }
    if ($signingKind -eq "microsoft-unclassified") {
        throw "The catalog is Microsoft-signed but does not contain an accepted attestation or HLK/WHCP hardware-signing EKU."
    }

    $infVerifPassed = $null
    if ($RunInfVerif -or $InfVerifPath) {
        $infverif = Resolve-WdkTool -ExplicitPath $InfVerifPath -Name "InfVerif.exe"
        & $infverif /w $inf
        $infVerifPassed = ($LASTEXITCODE -eq 0)
        if (-not $infVerifPassed) {
            throw "InfVerif /w failed with exit code $LASTEXITCODE."
        }
    }

    $evidence = [ordered]@{
        schemaVersion = 1
        source = $input
        verifiedAtUtc = [DateTime]::UtcNow.ToString("o")
        signingKind = $signingKind
        catalogSigner = $catalogSignature.SignerCertificate.Subject
        driverSigner = $driverSignature.SignerCertificate.Subject
        ekuOids = @($ekuOids)
        signToolWarnings = @($signToolWarnings)
        infVerifPassed = $infVerifPassed
        files = @(
            [ordered]@{ name = "SplatplostBluetooth.inf"; sha256 = (Get-FileHash -LiteralPath $inf -Algorithm SHA256).Hash.ToLowerInvariant() },
            [ordered]@{ name = "SplatplostBluetooth.sys"; sha256 = (Get-FileHash -LiteralPath $sys -Algorithm SHA256).Hash.ToLowerInvariant() },
            [ordered]@{ name = "SplatplostBluetooth.cat"; sha256 = (Get-FileHash -LiteralPath $cat -Algorithm SHA256).Hash.ToLowerInvariant() }
        )
        verified = [ordered]@{
            microsoftCatalogSignature = $true
            catalogCoversInfAndSys = $true
            embeddedDriverSignature = $true
        }
        notVerified = @(
            "Partner Center policy/certification report",
            "HVCI runtime compatibility",
            "PnP installation and device start",
            "Bluetooth protocol initialization and Nintendo Switch functionality"
        )
    }
    $evidence | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resolvedEvidencePath -Encoding UTF8

    [PSCustomObject]@{
        Evidence = $resolvedEvidencePath
        SigningKind = $signingKind
        CatalogSigner = $catalogSignature.SignerCertificate.Subject
        DriverSigner = $driverSignature.SignerCertificate.Subject
    }
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        try {
            Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
        } catch {
            Write-Warning "Signed-package verification finished, but its temporary directory could not be removed: $temporaryRoot"
        }
    }
}
