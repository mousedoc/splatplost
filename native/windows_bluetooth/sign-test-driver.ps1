param(
    [Parameter(Mandatory=$true)]
    [string]$PackageDirectory
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-SplatplostValidatedBuildManifest {
    param([Parameter(Mandatory = $true)][string]$Package)

    $manifestPath = Join-Path $Package "SplatplostBluetooth-build-manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Driver build manifest was not found: $manifestPath"
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($null -eq $manifest -or
            $null -eq $manifest.PSObject.Properties["schemaVersion"] -or
            [int]$manifest.schemaVersion -ne 1 -or
            $null -eq $manifest.PSObject.Properties["files"] -or
            $null -eq $manifest.files) {
        throw "The driver build manifest is invalid or unsupported."
    }

    foreach ($name in @("SplatplostBluetooth.inf", "SplatplostBluetooth.sys", "SplatplostBluetooth.pdb")) {
        $path = Join-Path $Package $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Development package file was not found: $path"
        }
        $entries = @($manifest.files | Where-Object { [string]$_.name -ceq $name })
        if ($entries.Count -ne 1 -or [string]$entries[0].sha256 -notmatch '^[0-9a-fA-F]{64}$') {
            throw "The driver build manifest does not contain exactly one valid identity for ${name}."
        }
        $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        if ($actualHash -ne [string]$entries[0].sha256) {
            throw "$name does not match the driver build manifest. Rebuild before development signing."
        }
    }

    return [PSCustomObject]@{
        Path = [IO.Path]::GetFullPath($manifestPath)
        Document = $manifest
    }
}

function Set-SplatplostDevelopmentManifestIdentity {
    param(
        [Parameter(Mandatory = $true)]$ManifestState,
        [Parameter(Mandatory = $true)][string]$SignedDriverPath
    )

    $signedHash = (Get-FileHash -LiteralPath $SignedDriverPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $entries = @($ManifestState.Document.files | Where-Object { [string]$_.name -ceq "SplatplostBluetooth.sys" })
    if ($entries.Count -ne 1) {
        throw "The driver build manifest lost its unique SYS identity during development signing."
    }
    $entries[0].sha256 = $signedHash

    $temporaryManifest = Join-Path `
        ([IO.Path]::GetDirectoryName($ManifestState.Path)) `
        (".SplatplostBluetooth-build-manifest.staging-" + [Guid]::NewGuid().ToString("N") + ".json")
    $backupManifest = Join-Path `
        ([IO.Path]::GetDirectoryName($ManifestState.Path)) `
        (".SplatplostBluetooth-build-manifest.backup-" + [Guid]::NewGuid().ToString("N") + ".json")
    try {
        $ManifestState.Document | ConvertTo-Json -Depth 5 | Set-Content `
            -LiteralPath $temporaryManifest `
            -Encoding UTF8
        $candidate = Get-Content -LiteralPath $temporaryManifest -Raw | ConvertFrom-Json
        $candidateEntries = @($candidate.files | Where-Object { [string]$_.name -ceq "SplatplostBluetooth.sys" })
        if ($candidateEntries.Count -ne 1 -or [string]$candidateEntries[0].sha256 -cne $signedHash) {
            throw "The staged development build manifest does not contain the signed SYS identity."
        }
        [IO.File]::Replace($temporaryManifest, [string]$ManifestState.Path, $backupManifest, $true)
    } finally {
        Remove-Item -LiteralPath $temporaryManifest -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backupManifest -Force -ErrorAction SilentlyContinue
    }
}

$package = [IO.Path]::GetFullPath($PackageDirectory)
$buildManifestState = Get-SplatplostValidatedBuildManifest -Package $package
$toolRoots = @(
    "${env:ProgramFiles(x86)}\Windows Kits\10\bin",
    (Join-Path $env:USERPROFILE ".nuget\packages\microsoft.windows.wdk.x64")
) | Where-Object { Test-Path $_ }
$signtool = Get-ChildItem $toolRoots -Recurse -Filter signtool.exe | Where-Object FullName -Match '(\\x64\\|\\amd64\\)' | Sort-Object FullName -Descending | Select-Object -First 1
$inf2cat = Get-ChildItem $toolRoots -Recurse -Filter Inf2Cat.exe | Sort-Object FullName -Descending | Select-Object -First 1
if (-not $signtool -or -not $inf2cat) { throw "WDK signing tools were not found." }

$certificate = New-SelfSignedCertificate `
    -Type CodeSigningCert `
    -Subject "CN=Splatplost Development Driver" `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -KeyAlgorithm RSA `
    -KeyLength 3072 `
    -HashAlgorithm SHA256 `
    -KeyExportPolicy Exportable `
    -NotAfter (Get-Date).AddYears(2)

Export-Certificate -Cert $certificate -FilePath (Join-Path $package "SplatplostDevelopment.cer") | Out-Null
& $signtool.FullName sign /v /fd SHA256 /sha1 $certificate.Thumbprint (Join-Path $package "SplatplostBluetooth.sys")
if ($LASTEXITCODE -ne 0) { throw "The test driver signing step failed." }
& $inf2cat.FullName "/driver:$package" "/os:10_VB_X64,10_CO_X64,10_NI_X64,10_GE_X64"
if ($LASTEXITCODE -ne 0) { throw "The driver catalog generation step failed." }
& $signtool.FullName sign /v /fd SHA256 /sha1 $certificate.Thumbprint (Join-Path $package "SplatplostBluetooth.cat")
if ($LASTEXITCODE -ne 0) { throw "The test catalog signing step failed." }
Set-SplatplostDevelopmentManifestIdentity `
    -ManifestState $buildManifestState `
    -SignedDriverPath (Join-Path $package "SplatplostBluetooth.sys")
Get-SplatplostValidatedBuildManifest -Package $package | Out-Null
