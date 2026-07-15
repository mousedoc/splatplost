param(
    [string]$DevelopmentPackageDirectory,
    [string]$SignToolPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:Failures = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$MessagePattern)

    try {
        & $Action
    } catch {
        if ($_.Exception.Message -match $MessagePattern) {
            return
        }
        throw "Expected error matching '$MessagePattern', but received: $($_.Exception.Message)"
    }
    throw "Expected an error matching '$MessagePattern', but no error was thrown."
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Action)

    try {
        & $Action
        Write-Host "PASS $Name"
    } catch {
        $script:Failures++
        Write-Host "FAIL $Name -- $($_.Exception.Message)"
    }
}

function Get-PathFingerprint {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return "<absent>"
    }

    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) {
        return "F|$($item.Length)|$($item.LastWriteTimeUtc.Ticks)|$((Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash)"
    }

    $root = [IO.Path]::GetFullPath($item.FullName).TrimEnd([char[]]@('\', '/'))
    $entries = @(Get-ChildItem -LiteralPath $root -Force -Recurse | Sort-Object FullName | ForEach-Object {
        $relativePath = $_.FullName.Substring($root.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
        if ($_.PSIsContainer) {
            "D|$relativePath|$($_.LastWriteTimeUtc.Ticks)"
        } else {
            "F|$relativePath|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
        }
    })
    return "DROOT|$($item.LastWriteTimeUtc.Ticks)`n$($entries -join "`n")"
}

function Assert-NoAssemblyTransactionArtifacts {
    param([Parameter(Mandatory = $true)]$Fixture)

    $parents = @(
        [IO.Path]::GetDirectoryName($Fixture.Output),
        [IO.Path]::GetDirectoryName($Fixture.Zip)
    ) | Select-Object -Unique
    foreach ($parent in $parents) {
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            continue
        }
        $leftovers = @(Get-ChildItem -LiteralPath $parent -Force | Where-Object {
            $_.Name -match '\.(staging|backup)-'
        })
        $leftoverNames = @($leftovers | ForEach-Object { $_.Name })
        Assert-True ($leftovers.Count -eq 0) "Transaction artifacts remain in ${parent}: $($leftoverNames -join ', ')"
    }
}

function Set-SyntheticUInt16 {
    param([byte[]]$Bytes, [int]$Offset, [uint16]$Value)
    [Array]::Copy([BitConverter]::GetBytes($Value), 0, $Bytes, $Offset, 2)
}

function Set-SyntheticUInt32 {
    param([byte[]]$Bytes, [int]$Offset, [uint32]$Value)
    [Array]::Copy([BitConverter]::GetBytes($Value), 0, $Bytes, $Offset, 4)
}

function New-SyntheticPeImage {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$WithAuthenticodeTable,
        [byte]$ContentMarker = 0x5a
    )

    $peOffset = 0x80
    $optionalOffset = $peOffset + 24
    $securityDirectoryOffset = $optionalOffset + 112 + (4 * 8)
    $unsignedLength = 0x200
    $bytes = New-Object byte[] $unsignedLength
    $bytes[0] = 0x4d
    $bytes[1] = 0x5a
    Set-SyntheticUInt32 -Bytes $bytes -Offset 0x3c -Value $peOffset
    $bytes[$peOffset] = 0x50
    $bytes[$peOffset + 1] = 0x45
    Set-SyntheticUInt16 -Bytes $bytes -Offset ($peOffset + 4) -Value 0x8664
    Set-SyntheticUInt16 -Bytes $bytes -Offset ($peOffset + 20) -Value 0x00f0
    Set-SyntheticUInt16 -Bytes $bytes -Offset $optionalOffset -Value 0x020b
    Set-SyntheticUInt32 -Bytes $bytes -Offset ($optionalOffset + 60) -Value $unsignedLength
    Set-SyntheticUInt32 -Bytes $bytes -Offset ($optionalOffset + 108) -Value 16
    $bytes[0x1f0] = $ContentMarker

    if ($WithAuthenticodeTable) {
        Set-SyntheticUInt32 -Bytes $bytes -Offset ($optionalOffset + 64) -Value 0x12345678
        Set-SyntheticUInt32 -Bytes $bytes -Offset $securityDirectoryOffset -Value $unsignedLength
        Set-SyntheticUInt32 -Bytes $bytes -Offset ($securityDirectoryOffset + 4) -Value 16
        $signedBytes = New-Object byte[] ($unsignedLength + 16)
        [Array]::Copy($bytes, 0, $signedBytes, 0, $bytes.Length)
        for ($index = $unsignedLength; $index -lt $signedBytes.Length; $index++) {
            $signedBytes[$index] = [byte](0xa0 + ($index - $unsignedLength))
        }
        [IO.File]::WriteAllBytes($Path, $signedBytes)
    } else {
        [IO.File]::WriteAllBytes($Path, $bytes)
    }
}

function New-SyntheticAssemblyFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$AssemblerSource
    )

    $fixtureRoot = Join-Path $Root $Name
    $harness = Join-Path $fixtureRoot "harness"
    $support = Join-Path $fixtureRoot "support"
    $signed = Join-Path $fixtureRoot "signed"
    foreach ($directory in @($harness, $support, $signed)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $fixtureAssembler = Join-Path $harness "assemble-signed-release.ps1"
    Copy-Item -LiteralPath $AssemblerSource -Destination $fixtureAssembler
    Copy-Item `
        -LiteralPath (Join-Path (Split-Path -Parent $AssemblerSource) "path-safety.ps1") `
        -Destination (Join-Path $harness "path-safety.ps1")
    $mockVerifier = @'
param(
    [Parameter(Mandatory = $true)][string]$SignedPackagePath,
    [string]$EvidencePath,
    [string]$SignToolPath,
    [string]$InfVerifPath,
    [switch]$RunInfVerif
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $SignedPackagePath -PathType Container)) {
    throw "Synthetic verifier requires an extracted package directory."
}
foreach ($name in @("SplatplostBluetooth.inf", "SplatplostBluetooth.sys", "SplatplostBluetooth.cat")) {
    $matches = @(Get-ChildItem -LiteralPath $SignedPackagePath -Recurse -File -Filter $name)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one $name in the synthetic signed result; found $($matches.Count)."
    }
}

if ((Test-Path -LiteralPath (Join-Path $PSScriptRoot "fail-final.marker")) -and
        [IO.Path]::GetFileName($EvidencePath) -eq "SplatplostBluetooth-signature-evidence.json") {
    throw "Synthetic staged verification failure."
}

$signingKind = "hlk-whcp"
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot "attestation.marker")) {
    $signingKind = "attestation"
}

$evidenceParent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($EvidencePath))
if (-not (Test-Path -LiteralPath $evidenceParent -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $evidenceParent | Out-Null
}
[ordered]@{
    schemaVersion = 1
    signingKind = $signingKind
    verifiedAtUtc = [DateTime]::UtcNow.ToString("o")
} | ConvertTo-Json | Set-Content -LiteralPath $EvidencePath -Encoding UTF8

[PSCustomObject]@{
    SigningKind = $signingKind
    Evidence = $EvidencePath
}
'@
    Set-Content -LiteralPath (Join-Path $harness "verify-signed-package.ps1") -Value $mockVerifier -Encoding UTF8

    $buildFiles = [ordered]@{
        "SplatplostBluetooth.inf" = "synthetic INF identity"
        "SplatplostBluetooth.pdb" = "synthetic private symbols"
        "install-driver.ps1" = "Write-Host 'synthetic install'"
        "install-driver.cmd" = "@echo synthetic install"
        "uninstall-driver.ps1" = "Write-Host 'synthetic uninstall'"
        "uninstall-driver.cmd" = "@echo synthetic uninstall"
        "verify-runtime.ps1" = "Write-Host 'synthetic runtime verification'"
        "THIRD_PARTY_NOTICES.md" = "Synthetic third-party notices"
    }
    foreach ($entry in $buildFiles.GetEnumerator()) {
        Set-Content -LiteralPath (Join-Path $support $entry.Key) -Value $entry.Value -Encoding UTF8
    }
    New-SyntheticPeImage -Path (Join-Path $support "SplatplostBluetooth.sys")
    $buildFiles["SplatplostBluetooth.sys"] = "<binary>"

    $manifestEntries = @($buildFiles.Keys | ForEach-Object {
        $path = Join-Path $support $_
        [ordered]@{
            name = $_
            sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
    [ordered]@{
        schemaVersion = 1
        createdAtUtc = [DateTime]::UtcNow.ToString("o")
        files = $manifestEntries
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $support "SplatplostBluetooth-build-manifest.json") -Encoding UTF8

    Copy-Item -LiteralPath (Join-Path $support "SplatplostBluetooth.inf") -Destination (Join-Path $signed "SplatplostBluetooth.inf")
    New-SyntheticPeImage -Path (Join-Path $signed "SplatplostBluetooth.sys") -WithAuthenticodeTable
    Set-Content -LiteralPath (Join-Path $signed "SplatplostBluetooth.cat") -Value "Microsoft synthetic catalog" -Encoding UTF8

    return [PSCustomObject]@{
        Root = $fixtureRoot
        Harness = $harness
        AssembleScript = $fixtureAssembler
        Signed = $signed
        Support = $support
        Output = (Join-Path (Join-Path $fixtureRoot "publish") "release")
        Zip = (Join-Path (Join-Path $fixtureRoot "archive") "release.zip")
    }
}

function New-SyntheticSubmissionFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$OmitDriverVersion,
        [switch]$MutatePdbDuringCatalogCheck
    )

    $fixtureRoot = Join-Path $Root $Name
    $package = Join-Path $fixtureRoot "package"
    $tools = Join-Path $fixtureRoot "tools"
    New-Item -ItemType Directory -Force -Path $package, $tools | Out-Null

    $buildFiles = [ordered]@{
        "SplatplostBluetooth.inf" = "synthetic submission INF"
        "SplatplostBluetooth.sys" = "synthetic submission driver"
        "SplatplostBluetooth.pdb" = "synthetic submission symbols"
    }
    foreach ($entry in $buildFiles.GetEnumerator()) {
        Set-Content -LiteralPath (Join-Path $package $entry.Key) -Value $entry.Value -Encoding UTF8
    }
    Set-Content -LiteralPath (Join-Path $package "SplatplostBluetooth.cat") -Value "synthetic catalog accepted by the test verifier" -Encoding UTF8

    $manifestEntries = @($buildFiles.Keys | ForEach-Object {
        $path = Join-Path $package $_
        [ordered]@{
            name = $_
            sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
    $buildManifest = [ordered]@{
        schemaVersion = 1
        files = $manifestEntries
    }
    if (-not $OmitDriverVersion) {
        $buildManifest["driverVersion"] = "1.0.0.1"
    }
    $buildManifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $package "SplatplostBluetooth-build-manifest.json") -Encoding UTF8

    $mockSignTool = Join-Path $tools "mock-signtool.ps1"
    @'
$global:LASTEXITCODE = 0
Write-Output "File is signed in catalog: synthetic"
'@ | Set-Content -LiteralPath $mockSignTool -Encoding UTF8
    if ($MutatePdbDuringCatalogCheck) {
        @'
if ($args.Count -gt 0 -and [IO.Path]::GetFileName([string]$args[$args.Count - 1]) -eq "SplatplostBluetooth.sys") {
    $driverDirectory = [IO.Path]::GetDirectoryName([string]$args[$args.Count - 1])
    Set-Content -LiteralPath (Join-Path $driverDirectory "SplatplostBluetooth.pdb") -Value "mutated during catalog verification" -Encoding UTF8
}
'@ | Add-Content -LiteralPath $mockSignTool -Encoding UTF8
    }

    $output = Join-Path (Join-Path $fixtureRoot "publish") "submission.cab"
    return [PSCustomObject]@{
        Root = $fixtureRoot
        Package = $package
        Symbols = (Join-Path $package "SplatplostBluetooth.pdb")
        SignTool = $mockSignTool
        Output = $output
        Manifest = "$output.manifest.json"
    }
}

$prepareScript = Join-Path $PSScriptRoot "prepare-submission-cab.ps1"
$verifyScript = Join-Path $PSScriptRoot "verify-signed-package.ps1"
$assembleScript = Join-Path $PSScriptRoot "assemble-signed-release.ps1"
$pathSafetyScript = Join-Path $PSScriptRoot "path-safety.ps1"
$driverRoot = Split-Path -Parent $PSScriptRoot
$buildScript = Join-Path $driverRoot "build-driver.ps1"
$signTestScript = Join-Path $driverRoot "sign-test-driver.ps1"
$repositoryRoot = Split-Path -Parent (Split-Path -Parent $driverRoot)

Invoke-Test "PowerShell scripts parse without errors" {
    foreach ($scriptPath in @($prepareScript, $verifyScript, $assembleScript, $pathSafetyScript, $buildScript, $signTestScript, $PSCommandPath)) {
        $tokens = $null
        $parseErrors = $null
        [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
        Assert-True ($parseErrors.Count -eq 0) "$scriptPath has parser errors: $($parseErrors -join '; ')"
    }
}

Invoke-Test "development signing repins the build manifest after catalog signing" {
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($signTestScript, [ref]$tokens, [ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) "Development signing script could not be parsed for the manifest regression test."
    $functionAst = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq "Set-SplatplostDevelopmentManifestIdentity"
    }, $true)
    Assert-True ($null -ne $functionAst) "Development manifest identity updater was not found."
    . ([ScriptBlock]::Create($functionAst.Extent.Text))

    $root = Join-Path ([IO.Path]::GetTempPath()) ("splatplost-development-manifest-test-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    try {
        $driver = Join-Path $root "SplatplostBluetooth.sys"
        $manifestPath = Join-Path $root "SplatplostBluetooth-build-manifest.json"
        Set-Content -LiteralPath $driver -Value "signed development driver" -NoNewline
        $document = [PSCustomObject]@{
            schemaVersion = 1
            files = @([PSCustomObject]@{
                name = "SplatplostBluetooth.sys"
                sha256 = ("0" * 64)
            })
        }
        $document | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        $state = [PSCustomObject]@{ Path = $manifestPath; Document = $document }
        Set-SplatplostDevelopmentManifestIdentity -ManifestState $state -SignedDriverPath $driver
        $published = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $expectedHash = (Get-FileHash -LiteralPath $driver -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-True ([string]$published.files[0].sha256 -ceq $expectedHash) "The signed SYS identity was not published atomically."

        $source = Get-Content -LiteralPath $signTestScript -Raw
        $catalogSigned = $source.IndexOf('throw "The test catalog signing step failed."')
        $manifestUpdated = $source.LastIndexOf('Set-SplatplostDevelopmentManifestIdentity')
        Assert-True ($catalogSigned -ge 0 -and $catalogSigned -lt $manifestUpdated) "The manifest is repinned before catalog signing succeeds."
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "WDK resolver accepts the official x86 Inf2Cat host tool" {
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($prepareScript, [ref]$tokens, [ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) "Submission script could not be parsed for the WDK resolver regression test."
    foreach ($functionName in @("Resolve-ExistingFile", "Resolve-WdkTool")) {
        $functionAst = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $functionName
        }, $true)
        Assert-True ($null -ne $functionAst) "$functionName was not found."
        . ([ScriptBlock]::Create($functionAst.Extent.Text))
    }

    $root = Join-Path ([IO.Path]::GetTempPath()) ("splatplost-wdk-tool-test-" + [Guid]::NewGuid().ToString("N"))
    $programFilesX86 = Join-Path $root "Program Files (x86)"
    $inf2Cat = Join-Path $programFilesX86 "Windows Kits\10\bin\10.0.26100.0\x86\Inf2Cat.exe"
    $oldProgramFilesX86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)", "Process")
    $oldPath = $env:PATH
    try {
        New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($inf2Cat)) | Out-Null
        Set-Content -LiteralPath $inf2Cat -Value "mock" -NoNewline
        [Environment]::SetEnvironmentVariable("ProgramFiles(x86)", $programFilesX86, "Process")
        $env:PATH = ""
        $resolved = Resolve-WdkTool -Name "Inf2Cat.exe"
        Assert-True (
            [string]::Equals($resolved, $inf2Cat, [StringComparison]::OrdinalIgnoreCase)
        ) "The x86 Inf2Cat host utility was not resolved."
    } finally {
        $env:PATH = $oldPath
        [Environment]::SetEnvironmentVariable("ProgramFiles(x86)", $oldProgramFilesX86, "Process")
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "build copies the PDB adjacent to the selected SYS" {
    $source = Get-Content -LiteralPath $buildScript -Raw
    Assert-True ($source -match 'Join-Path \$driverBuildDirectory "SplatplostBluetooth\.pdb"') "build-driver.ps1 does not bind symbols to the exact selected build directory."
    Assert-True ($source -match 'Copy-Item -Force \$symbols\.FullName \(Join-Path \$output "SplatplostBluetooth\.pdb"\)') "build-driver.ps1 does not copy the PDB to out."
}

Invoke-Test "signed release assembly is fail-closed" {
    $source = Get-Content -LiteralPath $assembleScript -Raw
    Assert-True ($source -match 'Assert-DisjointPaths') "Assembler does not reject path overlaps."
    Assert-True ($source -match '-Phase "Preflight"') "Signed package is not verified before assembly."
    Assert-True ($source -match '-Phase "Staged release"') "Staged package is not verified before publication."
    Assert-True ($source -match 'Assert-ArchiveMatchesDirectory') "Staged ZIP contents are not validated."
    Assert-True ($source -match '\.staging-') "Assembler does not use sibling transaction staging."
    Assert-True ($source -match 'SplatplostDevelopment\.cer') "Assembler does not recognize and replace a stale development certificate."
    Assert-True ($source -match 'files not owned by this assembler') "Assembler accepts unrelated output files."
    Assert-True ($source -match 'verify-runtime\.ps1') "Runtime evidence tool is missing from the signed package."
    Assert-True ($source -match '\[switch\]\$AllowAttestation') "Assembler has no explicit attestation opt-in."
    Assert-True ($source -match 'Attestation signing is testing-only') "Assembler does not reject attestation signing by default."
    Assert-True ($source -match 'sha256-pe-excluding-authenticode-fields') "Assembler does not record a signing-independent same-build SYS identity."
}

Invoke-Test "ZIP validation rejects a duplicate entry that replaces an expected name" {
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($assembleScript, [ref]$tokens, [ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) "Assembler could not be parsed for the archive regression test."
    $functionAst = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq "Assert-ArchiveMatchesDirectory"
    }, $true)
    Assert-True ($null -ne $functionAst) "Assert-ArchiveMatchesDirectory was not found."
    . ([ScriptBlock]::Create($functionAst.Extent.Text))

    $root = Join-Path ([IO.Path]::GetTempPath()) ("splatplost-duplicate-zip-" + [Guid]::NewGuid().ToString("N"))
    $directory = Join-Path $root "directory"
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    try {
        Set-Content -LiteralPath (Join-Path $directory "A.txt") -Value "A" -NoNewline
        Set-Content -LiteralPath (Join-Path $directory "B.txt") -Value "B" -NoNewline
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archivePath = Join-Path $root "duplicate.zip"
        $archive = [IO.Compression.ZipFile]::Open($archivePath, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($entryName in @("A.txt", "A.txt")) {
                $entry = $archive.CreateEntry($entryName)
                $entryStream = $entry.Open()
                try {
                    $entryBytes = [Text.Encoding]::UTF8.GetBytes("A")
                    $entryStream.Write($entryBytes, 0, $entryBytes.Length)
                } finally {
                    $entryStream.Dispose()
                }
            }
        } finally {
            $archive.Dispose()
        }
        Assert-Throws -MessagePattern "duplicate entry|every expected release file exactly once" -Action {
            Assert-ArchiveMatchesDirectory -ArchivePath $archivePath -DirectoryPath $directory
        }
    } finally {
        if (Test-Path -LiteralPath $root) {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }
}

Invoke-Test "submission CAB publication is transactional" {
    $source = Get-Content -LiteralPath $prepareScript -Raw
    Assert-True ($source -match '10_VB_X64,10_CO_X64,10_NI_X64,10_GE_X64') "Submission catalog validation does not cover the declared Windows 10 2004 through Windows 11 24H2 targets."
    Assert-True ($source -match 'Assert-SubmissionManifest') "Submission manifest is not parsed and validated before publication."
    Assert-True ($source -match '\.staging-') "Submission artifacts do not use sibling staging paths."
    Assert-True ($source -match '\.backup-') "Submission replacement does not retain rollback backups."
    Assert-True ($source -match 'rollback was incomplete') "Submission replacement has no explicit rollback failure handling."
    Assert-True (-not ($source -match 'Copy-Item -LiteralPath \$createdCab -Destination \$output')) "Temporary CAB is still copied directly over the final output."
    Assert-True ($source -match 'Get-AuthenticodeSignature -LiteralPath \$createdCab') "Optional signing is not fully verified on the temporary CAB candidate."
    Assert-True ($source -match 'CAB member bytes do not match the validated staging snapshot') "Expanded CAB bytes are not bound to the validated staging snapshot."
    Assert-True ($source -match 'temporary directory could not be removed') "Submission cleanup can still mask a completed transaction or its original error."
}

Invoke-Test "signed-package evidence output is fail-closed" {
    $source = Get-Content -LiteralPath $verifyScript -Raw
    Assert-True ($source -match 'Test-SplatplostPathsAlias') "Signed-package verifier does not reject EvidencePath aliases."
    Assert-True ($source -match 'temporary directory could not be removed') "Verifier cleanup can still mask its verification result or original error."
}

$evidenceCollisionRoot = Join-Path ([IO.Path]::GetTempPath()) ("splatplost-evidence-collision-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $evidenceCollisionRoot | Out-Null
try {
    Invoke-Test "verifier rejects an extended-path EvidencePath alias of its input before overwrite" {
        $inputZip = Join-Path $evidenceCollisionRoot "signedPackage.zip"
        Set-Content -LiteralPath $inputZip -Value "synthetic signed package bytes" -Encoding UTF8
        $before = Get-PathFingerprint -Path $inputZip
        $extendedAlias = "\\?\" + [IO.Path]::GetFullPath($inputZip)
        Assert-Throws -MessagePattern "EvidencePath must not alias or overwrite the signed-package input" -Action {
            & $verifyScript -SignedPackagePath $inputZip -EvidencePath $extendedAlias | Out-Null
        }
        Assert-True ((Get-PathFingerprint -Path $inputZip) -eq $before) "Input ZIP changed while rejecting an aliased EvidencePath."
    }

    Invoke-Test "verifier rejects EvidencePath collision with a discovered payload file" {
        $payload = Join-Path $evidenceCollisionRoot "payload"
        New-Item -ItemType Directory -Force -Path $payload | Out-Null
        foreach ($name in @("SplatplostBluetooth.inf", "SplatplostBluetooth.sys", "SplatplostBluetooth.cat")) {
            Set-Content -LiteralPath (Join-Path $payload $name) -Value "synthetic $name" -Encoding UTF8
        }
        $driverPath = Join-Path $payload "SplatplostBluetooth.sys"
        $before = Get-PathFingerprint -Path $driverPath
        Assert-Throws -MessagePattern "EvidencePath must not alias or overwrite a signed payload file" -Action {
            & $verifyScript -SignedPackagePath $payload -EvidencePath $driverPath | Out-Null
        }
        Assert-True ((Get-PathFingerprint -Path $driverPath) -eq $before) "Signed payload changed while rejecting an EvidencePath collision."
    }


    Invoke-Test "verifier rejects a hard-link EvidencePath alias of a payload file" {
        $payload = Join-Path $evidenceCollisionRoot "hardlink-payload"
        New-Item -ItemType Directory -Force -Path $payload | Out-Null
        foreach ($name in @("SplatplostBluetooth.inf", "SplatplostBluetooth.sys", "SplatplostBluetooth.cat")) {
            Set-Content -LiteralPath (Join-Path $payload $name) -Value "synthetic $name" -Encoding UTF8
        }
        $driverPath = Join-Path $payload "SplatplostBluetooth.sys"
        $hardLink = Join-Path $evidenceCollisionRoot "evidence-hardlink.json"
        New-Item -ItemType HardLink -Path $hardLink -Target $driverPath | Out-Null
        $before = Get-PathFingerprint -Path $driverPath
        Assert-Throws -MessagePattern "EvidencePath must not alias or overwrite a signed payload file" -Action {
            & $verifyScript -SignedPackagePath $payload -EvidencePath $hardLink | Out-Null
        }
        Assert-True ((Get-PathFingerprint -Path $driverPath) -eq $before) "Signed payload changed while rejecting a hard-link EvidencePath alias."
    }
} finally {
    if (Test-Path -LiteralPath $evidenceCollisionRoot) {
        Remove-Item -LiteralPath $evidenceCollisionRoot -Recurse -Force
    }
}

$submissionTestRoot = Join-Path ([IO.Path]::GetTempPath()) ("splatplost-submission-tests-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $submissionTestRoot | Out-Null
try {
    Invoke-Test "submission CAB and manifest replace an existing pair only after full validation" {
        $fixture = New-SyntheticSubmissionFixture -Root $submissionTestRoot -Name "success"
        New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($fixture.Output)) | Out-Null
        Set-Content -LiteralPath $fixture.Output -Value "old CAB that must not survive success" -Encoding UTF8
        Set-Content -LiteralPath $fixture.Manifest -Value "old manifest that must not survive success" -Encoding UTF8

        $oldCab = Get-PathFingerprint -Path $fixture.Output
        $oldManifest = Get-PathFingerprint -Path $fixture.Manifest
        $packageBefore = Get-PathFingerprint -Path $fixture.Package
        $parameters = @{
            PackageDirectory = $fixture.Package
            SymbolsPath = $fixture.Symbols
            OutputPath = $fixture.Output
            SignToolPath = $fixture.SignTool
            PrepareOnly = $true
        }
        $result = @(& $prepareScript @parameters)[-1]

        $cabHash = (Get-FileHash -LiteralPath $fixture.Output -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-True ((Get-PathFingerprint -Path $fixture.Output) -ne $oldCab) "Validated CAB did not replace the prior CAB."
        Assert-True ((Get-PathFingerprint -Path $fixture.Manifest) -ne $oldManifest) "Validated manifest did not replace the prior manifest."
        Assert-True ((Get-PathFingerprint -Path $fixture.Package) -eq $packageBefore) "Submission preparation changed its package input."
        Assert-True ($result.Cab -eq [IO.Path]::GetFullPath($fixture.Output)) "Submission result reports the wrong final CAB path."
        Assert-True ($result.Manifest -eq [IO.Path]::GetFullPath($fixture.Manifest)) "Submission result reports the wrong final manifest path."
        Assert-True ($result.Sha256 -eq $cabHash) "Submission result reports the wrong CAB digest."
        Assert-True (-not $result.Signed) "PrepareOnly unexpectedly reported a signed CAB."

        $manifest = Get-Content -LiteralPath $fixture.Manifest -Raw | ConvertFrom-Json
        Assert-True ([int]$manifest.schemaVersion -eq 1) "Submission manifest schema changed unexpectedly."
        Assert-True ([IO.Path]::GetFullPath([string]$manifest.cab.path) -eq [IO.Path]::GetFullPath($fixture.Output)) "Submission manifest reports the wrong final CAB path."
        Assert-True ([string]$manifest.cab.sha256 -eq $cabHash) "Submission manifest CAB digest does not match the published CAB."
        Assert-True (-not [bool]$manifest.cab.signed) "Submission manifest incorrectly reports an unsigned structural CAB as signed."
        $expectedMembers = @(
            "SplatplostBluetooth/SplatplostBluetooth.cat",
            "SplatplostBluetooth/SplatplostBluetooth.inf",
            "SplatplostBluetooth/SplatplostBluetooth.pdb",
            "SplatplostBluetooth/SplatplostBluetooth.sys"
        ) | Sort-Object
        $actualMembers = @($manifest.files | ForEach-Object { [string]$_ } | Sort-Object)
        Assert-True (($actualMembers -join "`n") -ceq ($expectedMembers -join "`n")) "Submission manifest does not contain the exact CAB membership."
        $recordedHashes = @($manifest.fileHashes)
        Assert-True ($recordedHashes.Count -eq $expectedMembers.Count) "Submission manifest does not record every CAB member digest."
        $expanded = Join-Path $fixture.Root "expanded-published-cab"
        New-Item -ItemType Directory -Force -Path $expanded | Out-Null
        & "$env:SystemRoot\System32\expand.exe" -F:* $fixture.Output $expanded | Out-Null
        Assert-True ($LASTEXITCODE -eq 0) "Published structural CAB could not be expanded for digest verification."
        foreach ($expectedMember in $expectedMembers) {
            $entries = @($recordedHashes | Where-Object { [string]$_.path -ceq $expectedMember })
            Assert-True ($entries.Count -eq 1) "Submission manifest does not record exactly one digest for $expectedMember."
            $expandedFile = Join-Path $expanded ($expectedMember.Replace("/", "\"))
            $actualHash = (Get-FileHash -LiteralPath $expandedFile -Algorithm SHA256).Hash.ToLowerInvariant()
            Assert-True ([string]$entries[0].sha256 -ceq $actualHash) "Published CAB bytes do not match the recorded digest for $expectedMember."
        }
        Assert-NoAssemblyTransactionArtifacts -Fixture ([PSCustomObject]@{ Output = $fixture.Output; Zip = $fixture.Manifest })
    }

    Invoke-Test "submission rejects a staged build file changed during catalog verification" {
        $fixture = New-SyntheticSubmissionFixture `
            -Root $submissionTestRoot `
            -Name "catalog-check-mutation" `
            -MutatePdbDuringCatalogCheck
        $packageBefore = Get-PathFingerprint -Path $fixture.Package
        $parameters = @{
            PackageDirectory = $fixture.Package
            SymbolsPath = $fixture.Symbols
            OutputPath = $fixture.Output
            SignToolPath = $fixture.SignTool
            PrepareOnly = $true
        }
        Assert-Throws -MessagePattern "staged build file changed during catalog verification: SplatplostBluetooth.pdb" -Action {
            & $prepareScript @parameters | Out-Null
        }
        Assert-True (-not (Test-Path -LiteralPath $fixture.Output)) "A CAB was published after a staged PDB provenance failure."
        Assert-True (-not (Test-Path -LiteralPath $fixture.Manifest)) "A manifest was published after a staged PDB provenance failure."
        Assert-True ((Get-PathFingerprint -Path $fixture.Package) -eq $packageBefore) "Staging provenance validation changed its package input."
        Assert-NoAssemblyTransactionArtifacts -Fixture ([PSCustomObject]@{ Output = $fixture.Output; Zip = $fixture.Manifest })
    }

    Invoke-Test "late temporary manifest failure preserves the existing CAB and manifest" {
        $fixture = New-SyntheticSubmissionFixture -Root $submissionTestRoot -Name "late-manifest-failure" -OmitDriverVersion
        New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($fixture.Output)) | Out-Null
        Set-Content -LiteralPath $fixture.Output -Value "known-good existing CAB" -Encoding UTF8
        Set-Content -LiteralPath $fixture.Manifest -Value "known-good existing manifest" -Encoding UTF8

        $cabBefore = Get-PathFingerprint -Path $fixture.Output
        $manifestBefore = Get-PathFingerprint -Path $fixture.Manifest
        $packageBefore = Get-PathFingerprint -Path $fixture.Package
        $parameters = @{
            PackageDirectory = $fixture.Package
            SymbolsPath = $fixture.Symbols
            OutputPath = $fixture.Output
            SignToolPath = $fixture.SignTool
            PrepareOnly = $true
        }
        Assert-Throws -MessagePattern "driverVersion" -Action {
            & $prepareScript @parameters | Out-Null
        }

        Assert-True ((Get-PathFingerprint -Path $fixture.Output) -eq $cabBefore) "Existing CAB changed after temporary manifest generation failed."
        Assert-True ((Get-PathFingerprint -Path $fixture.Manifest) -eq $manifestBefore) "Existing manifest changed after temporary manifest generation failed."
        Assert-True ((Get-PathFingerprint -Path $fixture.Package) -eq $packageBefore) "Package input changed after temporary manifest generation failed."
        Assert-NoAssemblyTransactionArtifacts -Fixture ([PSCustomObject]@{ Output = $fixture.Output; Zip = $fixture.Manifest })
    }

    Invoke-Test "submission pair rolls back when the existing manifest cannot be moved" {
        $fixture = New-SyntheticSubmissionFixture -Root $submissionTestRoot -Name "transaction-rollback"
        New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($fixture.Output)) | Out-Null
        Set-Content -LiteralPath $fixture.Output -Value "known-good existing CAB" -Encoding UTF8
        Set-Content -LiteralPath $fixture.Manifest -Value "known-good existing manifest" -Encoding UTF8

        $cabBefore = Get-PathFingerprint -Path $fixture.Output
        $manifestBefore = Get-PathFingerprint -Path $fixture.Manifest
        $packageBefore = Get-PathFingerprint -Path $fixture.Package
        $parameters = @{
            PackageDirectory = $fixture.Package
            SymbolsPath = $fixture.Symbols
            OutputPath = $fixture.Output
            SignToolPath = $fixture.SignTool
            PrepareOnly = $true
        }

        $manifestLock = [IO.File]::Open($fixture.Manifest, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $submissionFailed = $false
        try {
            try {
                & $prepareScript @parameters | Out-Null
            } catch {
                $submissionFailed = $true
            }
        } finally {
            $manifestLock.Dispose()
        }

        Assert-True $submissionFailed "Submission unexpectedly succeeded while the existing manifest denied delete sharing."
        Assert-True ((Get-PathFingerprint -Path $fixture.Output) -eq $cabBefore) "Existing CAB was not restored after submission transaction failure."
        Assert-True ((Get-PathFingerprint -Path $fixture.Manifest) -eq $manifestBefore) "Existing manifest changed after submission transaction failure."
        Assert-True ((Get-PathFingerprint -Path $fixture.Package) -eq $packageBefore) "Package input changed during submission transaction rollback."
        Assert-NoAssemblyTransactionArtifacts -Fixture ([PSCustomObject]@{ Output = $fixture.Output; Zip = $fixture.Manifest })
    }
} finally {
    if (Test-Path -LiteralPath $submissionTestRoot) {
        Remove-Item -LiteralPath $submissionTestRoot -Recurse -Force
    }
}

$assemblyTestRoot = Join-Path ([IO.Path]::GetTempPath()) ("splatplost-assembly-tests-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $assemblyTestRoot | Out-Null
try {
    Invoke-Test "assembler rejects every same, ancestor, and descendant path overlap" {
        $roles = @("SignedPackagePath", "BuildOutputDirectory", "OutputDirectory", "ZipPath")
        $caseNumber = 0
        for ($leftIndex = 0; $leftIndex -lt $roles.Count; $leftIndex++) {
            for ($rightIndex = $leftIndex + 1; $rightIndex -lt $roles.Count; $rightIndex++) {
                $leftRole = $roles[$leftIndex]
                $rightRole = $roles[$rightIndex]
                foreach ($relationship in @("same", "left-ancestor", "right-ancestor")) {
                    $caseNumber++
                    $caseRoot = Join-Path $assemblyTestRoot ("overlap-" + $caseNumber)
                    $parameters = @{
                        SignedPackagePath = (Join-Path $caseRoot "signed")
                        BuildOutputDirectory = (Join-Path $caseRoot "support")
                        OutputDirectory = (Join-Path $caseRoot "output")
                        ZipPath = (Join-Path $caseRoot "release.zip")
                    }

                    if ($relationship -eq "same") {
                        $sharedName = if ($leftRole -eq "ZipPath" -or $rightRole -eq "ZipPath") { "shared.zip" } else { "shared" }
                        $shared = Join-Path $caseRoot $sharedName
                        $parameters[$leftRole] = $shared
                        $parameters[$rightRole] = $shared
                    } elseif ($relationship -eq "left-ancestor") {
                        $ancestorName = if ($leftRole -eq "ZipPath") { "ancestor.zip" } else { "ancestor" }
                        $childName = if ($rightRole -eq "ZipPath") { "child.zip" } else { "child" }
                        $parameters[$leftRole] = Join-Path $caseRoot $ancestorName
                        $parameters[$rightRole] = Join-Path $parameters[$leftRole] $childName
                    } else {
                        $ancestorName = if ($rightRole -eq "ZipPath") { "ancestor.zip" } else { "ancestor" }
                        $childName = if ($leftRole -eq "ZipPath") { "child.zip" } else { "child" }
                        $parameters[$rightRole] = Join-Path $caseRoot $ancestorName
                        $parameters[$leftRole] = Join-Path $parameters[$rightRole] $childName
                    }

                    Assert-Throws -MessagePattern "Path overlap is not allowed" -Action {
                        & $assembleScript @parameters | Out-Null
                    }
                }
            }
        }
        Assert-True ($caseNumber -eq 18) "The overlap matrix did not cover all six pairs in all three directions."
    }

    Invoke-Test "extended-path aliases cannot bypass signed-input and output disjointness" {
        $fixture = New-SyntheticAssemblyFixture -Root $assemblyTestRoot -Name "extended-path-alias" -AssemblerSource $assembleScript
        $signedBefore = Get-PathFingerprint -Path $fixture.Signed
        $supportBefore = Get-PathFingerprint -Path $fixture.Support
        $aliasedOutput = "\\?\" + [IO.Path]::GetFullPath($fixture.Signed)
        $parameters = @{
            SignedPackagePath = $fixture.Signed
            BuildOutputDirectory = $fixture.Support
            OutputDirectory = $aliasedOutput
            ZipPath = $fixture.Zip
        }
        Assert-Throws -MessagePattern "Path overlap is not allowed" -Action {
            & $fixture.AssembleScript @parameters | Out-Null
        }
        Assert-True ((Get-PathFingerprint -Path $fixture.Signed) -eq $signedBefore) "Signed input changed while rejecting its extended-path output alias."
        Assert-True ((Get-PathFingerprint -Path $fixture.Support) -eq $supportBefore) "Support input changed while rejecting an extended-path alias."
        Assert-True (-not (Test-Path -LiteralPath $fixture.Zip)) "ZIP was created after rejecting an extended-path alias."
    }

    Invoke-Test "reparse-point aliases cannot redirect output into protected inputs" {
        $fixture = New-SyntheticAssemblyFixture -Root $assemblyTestRoot -Name "junction-alias" -AssemblerSource $assembleScript
        $junction = Join-Path $fixture.Root "publish-link"
        New-Item -ItemType Junction -Path $junction -Target $fixture.Support | Out-Null
        try {
            $aliasedOutput = Join-Path $junction "release"
            $signedBefore = Get-PathFingerprint -Path $fixture.Signed
            $supportBefore = Get-PathFingerprint -Path $fixture.Support
            $parameters = @{
                SignedPackagePath = $fixture.Signed
                BuildOutputDirectory = $fixture.Support
                OutputDirectory = $aliasedOutput
                ZipPath = $fixture.Zip
            }
            Assert-Throws -MessagePattern "Reparse points are not allowed" -Action {
                & $fixture.AssembleScript @parameters | Out-Null
            }
            Assert-True ((Get-PathFingerprint -Path $fixture.Signed) -eq $signedBefore) "Signed input changed while rejecting a reparse-point alias."
            Assert-True ((Get-PathFingerprint -Path $fixture.Support) -eq $supportBefore) "Support input changed while rejecting an output alias into it."
            Assert-True (-not (Test-Path -LiteralPath $aliasedOutput)) "Aliased output was created inside the support input."
            Assert-True (-not (Test-Path -LiteralPath $fixture.Zip)) "ZIP was created after rejecting a reparse-point alias."
            Assert-NoAssemblyTransactionArtifacts -Fixture ([PSCustomObject]@{ Output = $aliasedOutput; Zip = $fixture.Zip })
        } finally {
            if (Test-Path -LiteralPath $junction) {
                # Windows PowerShell 5.1 prompts (and can throw from a headless
                # host) when Remove-Item sees a junction to a non-empty target.
                # Directory.Delete removes the junction itself, not its target.
                [IO.Directory]::Delete($junction)
            }
        }
    }

    Invoke-Test "assembler publishes a verified release atomically without changing inputs" {
        $fixture = New-SyntheticAssemblyFixture -Root $assemblyTestRoot -Name "success" -AssemblerSource $assembleScript
        New-Item -ItemType Directory -Force -Path $fixture.Output | Out-Null
        Set-Content -LiteralPath (Join-Path $fixture.Output "install-driver.cmd") -Value "old owned output" -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $fixture.Output "SplatplostDevelopment.cer") -Value "stale development certificate" -Encoding UTF8
        New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($fixture.Zip)) | Out-Null
        Set-Content -LiteralPath $fixture.Zip -Value "old archive" -Encoding UTF8

        $signedBefore = Get-PathFingerprint -Path $fixture.Signed
        $supportBefore = Get-PathFingerprint -Path $fixture.Support
        $oldZipBefore = Get-PathFingerprint -Path $fixture.Zip
        $parameters = @{
            SignedPackagePath = $fixture.Signed
            BuildOutputDirectory = $fixture.Support
            OutputDirectory = $fixture.Output
            ZipPath = $fixture.Zip
        }
        $result = @(& $fixture.AssembleScript @parameters)[-1]

        Assert-True ((Get-PathFingerprint -Path $fixture.Signed) -eq $signedBefore) "Signed input was changed during successful assembly."
        Assert-True ((Get-PathFingerprint -Path $fixture.Support) -eq $supportBefore) "Support input was changed during successful assembly."
        Assert-True ((Get-PathFingerprint -Path $fixture.Zip) -ne $oldZipBefore) "The validated ZIP did not replace the prior owned ZIP."
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Output "SplatplostDevelopment.cer"))) "Stale development certificate survived release replacement."

        $expectedNames = @(
            "SplatplostBluetooth.inf",
            "SplatplostBluetooth.sys",
            "SplatplostBluetooth.cat",
            "install-driver.ps1",
            "install-driver.cmd",
            "uninstall-driver.ps1",
            "uninstall-driver.cmd",
            "verify-runtime.ps1",
            "THIRD_PARTY_NOTICES.md",
            "SplatplostBluetooth-build-manifest.json",
            "SplatplostBluetooth-signature-evidence.json",
            "SplatplostBluetooth-release-manifest.json"
        ) | Sort-Object
        $actualNames = @(Get-ChildItem -LiteralPath $fixture.Output -Force | ForEach-Object { $_.Name } | Sort-Object)
        $contentDifference = @(Compare-Object -ReferenceObject $expectedNames -DifferenceObject $actualNames)
        Assert-True ($actualNames.Count -eq $expectedNames.Count -and $contentDifference.Count -eq 0) "Published release has unexpected contents: $($actualNames -join ', ')"
        Assert-True ($result.SigningKind -eq "hlk-whcp") "Default production release did not preserve the verifier's HLK/WHCP signing kind."
        Assert-True ($result.Sha256 -eq (Get-FileHash -LiteralPath $fixture.Zip -Algorithm SHA256).Hash.ToLowerInvariant()) "Returned ZIP digest is incorrect."
        $releaseManifest = Get-Content -LiteralPath (Join-Path $fixture.Output "SplatplostBluetooth-release-manifest.json") -Raw | ConvertFrom-Json
        Assert-True ($releaseManifest.signingKind -eq "hlk-whcp") "Release manifest did not record HLK/WHCP signing."
        Assert-True (-not [bool]$releaseManifest.attestationTestingOptIn) "Release manifest incorrectly records attestation opt-in."
        Assert-True ($releaseManifest.driverContentIdentity.algorithm -eq "sha256-pe-excluding-authenticode-fields") "Release manifest does not identify the signed SYS same-build algorithm."
        Assert-True ([string]$releaseManifest.driverContentIdentity.sha256 -match '^[0-9a-f]{64}$') "Release manifest does not record a valid signing-independent SYS digest."
        $manifestNames = @($releaseManifest.files | ForEach-Object { [string]$_.name } | Sort-Object)
        $expectedManifestNames = @($expectedNames | Where-Object { $_ -ne "SplatplostBluetooth-release-manifest.json" })
        $manifestDifference = @(Compare-Object -ReferenceObject $expectedManifestNames -DifferenceObject $manifestNames)
        Assert-True ($manifestNames.Count -eq $expectedManifestNames.Count -and $manifestDifference.Count -eq 0) "Release manifest must identify every package file except itself exactly once."
        Assert-True (@($manifestNames | Select-Object -Unique).Count -eq $manifestNames.Count) "Release manifest contains duplicate file identities."
        foreach ($entry in @($releaseManifest.files)) {
            $publishedHash = (Get-FileHash -LiteralPath (Join-Path $fixture.Output ([string]$entry.name)) -Algorithm SHA256).Hash.ToLowerInvariant()
            Assert-True ($publishedHash -eq [string]$entry.sha256) "Release manifest digest does not match $($entry.name)."
        }
        Assert-NoAssemblyTransactionArtifacts -Fixture $fixture
    }

    Invoke-Test "unexpected existing output fails closed without touching output, ZIP, or inputs" {
        $fixture = New-SyntheticAssemblyFixture -Root $assemblyTestRoot -Name "unexpected-output" -AssemblerSource $assembleScript
        New-Item -ItemType Directory -Force -Path $fixture.Output | Out-Null
        Set-Content -LiteralPath (Join-Path $fixture.Output "user-data.txt") -Value "must survive" -Encoding UTF8
        New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($fixture.Zip)) | Out-Null
        Set-Content -LiteralPath $fixture.Zip -Value "existing archive" -Encoding UTF8

        $outputBefore = Get-PathFingerprint -Path $fixture.Output
        $zipBefore = Get-PathFingerprint -Path $fixture.Zip
        $signedBefore = Get-PathFingerprint -Path $fixture.Signed
        $supportBefore = Get-PathFingerprint -Path $fixture.Support
        $parameters = @{
            SignedPackagePath = $fixture.Signed
            BuildOutputDirectory = $fixture.Support
            OutputDirectory = $fixture.Output
            ZipPath = $fixture.Zip
        }
        Assert-Throws -MessagePattern "files not owned by this assembler" -Action {
            & $fixture.AssembleScript @parameters | Out-Null
        }

        Assert-True ((Get-PathFingerprint -Path $fixture.Output) -eq $outputBefore) "Unexpected existing output was changed."
        Assert-True ((Get-PathFingerprint -Path $fixture.Zip) -eq $zipBefore) "Existing ZIP was changed after output ownership rejection."
        Assert-True ((Get-PathFingerprint -Path $fixture.Signed) -eq $signedBefore) "Signed input was changed after output ownership rejection."
        Assert-True ((Get-PathFingerprint -Path $fixture.Support) -eq $supportBefore) "Support input was changed after output ownership rejection."
        Assert-NoAssemblyTransactionArtifacts -Fixture $fixture
    }

    Invoke-Test "signed INF from another build is rejected without replacing existing release" {
        $fixture = New-SyntheticAssemblyFixture -Root $assemblyTestRoot -Name "signed-inf-mismatch" -AssemblerSource $assembleScript
        Add-Content -LiteralPath (Join-Path $fixture.Signed "SplatplostBluetooth.inf") -Value "different build"
        New-Item -ItemType Directory -Force -Path $fixture.Output | Out-Null
        Set-Content -LiteralPath (Join-Path $fixture.Output "install-driver.cmd") -Value "old owned output" -Encoding UTF8
        New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($fixture.Zip)) | Out-Null
        Set-Content -LiteralPath $fixture.Zip -Value "existing archive" -Encoding UTF8

        $outputBefore = Get-PathFingerprint -Path $fixture.Output
        $zipBefore = Get-PathFingerprint -Path $fixture.Zip
        $signedBefore = Get-PathFingerprint -Path $fixture.Signed
        $supportBefore = Get-PathFingerprint -Path $fixture.Support
        $parameters = @{
            SignedPackagePath = $fixture.Signed
            BuildOutputDirectory = $fixture.Support
            OutputDirectory = $fixture.Output
            ZipPath = $fixture.Zip
        }
        Assert-Throws -MessagePattern "INF does not match this build manifest" -Action {
            & $fixture.AssembleScript @parameters | Out-Null
        }

        Assert-True ((Get-PathFingerprint -Path $fixture.Output) -eq $outputBefore) "Existing output changed after signed INF mismatch."
        Assert-True ((Get-PathFingerprint -Path $fixture.Zip) -eq $zipBefore) "Existing ZIP changed after signed INF mismatch."
        Assert-True ((Get-PathFingerprint -Path $fixture.Signed) -eq $signedBefore) "Signed input changed while rejecting signed INF mismatch."
        Assert-True ((Get-PathFingerprint -Path $fixture.Support) -eq $supportBefore) "Support input changed while rejecting signed INF mismatch."
        Assert-NoAssemblyTransactionArtifacts -Fixture $fixture
    }

    Invoke-Test "Microsoft-signed SYS from another same-INF build is rejected" {
        $fixture = New-SyntheticAssemblyFixture -Root $assemblyTestRoot -Name "signed-sys-mismatch" -AssemblerSource $assembleScript
        $signedDriverPath = Join-Path $fixture.Signed "SplatplostBluetooth.sys"
        $signedBytes = [IO.File]::ReadAllBytes($signedDriverPath)
        $signedBytes[0x1f0] = [byte]($signedBytes[0x1f0] -bxor 0xff)
        [IO.File]::WriteAllBytes($signedDriverPath, $signedBytes)
        New-Item -ItemType Directory -Force -Path $fixture.Output | Out-Null
        Set-Content -LiteralPath (Join-Path $fixture.Output "install-driver.cmd") -Value "old owned output" -Encoding UTF8
        New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($fixture.Zip)) | Out-Null
        Set-Content -LiteralPath $fixture.Zip -Value "existing archive" -Encoding UTF8

        $outputBefore = Get-PathFingerprint -Path $fixture.Output
        $zipBefore = Get-PathFingerprint -Path $fixture.Zip
        $signedBefore = Get-PathFingerprint -Path $fixture.Signed
        $supportBefore = Get-PathFingerprint -Path $fixture.Support
        $parameters = @{
            SignedPackagePath = $fixture.Signed
            BuildOutputDirectory = $fixture.Support
            OutputDirectory = $fixture.Output
            ZipPath = $fixture.Zip
        }
        Assert-Throws -MessagePattern "signed SYS does not match the submitted build after excluding Authenticode" -Action {
            & $fixture.AssembleScript @parameters | Out-Null
        }

        Assert-True ((Get-PathFingerprint -Path $fixture.Output) -eq $outputBefore) "Existing output changed after signed SYS identity mismatch."
        Assert-True ((Get-PathFingerprint -Path $fixture.Zip) -eq $zipBefore) "Existing ZIP changed after signed SYS identity mismatch."
        Assert-True ((Get-PathFingerprint -Path $fixture.Signed) -eq $signedBefore) "Signed input changed while rejecting a wrong-build SYS."
        Assert-True ((Get-PathFingerprint -Path $fixture.Support) -eq $supportBefore) "Support input changed while rejecting a wrong-build SYS."
        Assert-NoAssemblyTransactionArtifacts -Fixture $fixture
    }

    Invoke-Test "changed support file is rejected by the same-build manifest" {
        $fixture = New-SyntheticAssemblyFixture -Root $assemblyTestRoot -Name "support-mismatch" -AssemblerSource $assembleScript
        Add-Content -LiteralPath (Join-Path $fixture.Support "install-driver.ps1") -Value "changed after manifest"
        New-Item -ItemType Directory -Force -Path $fixture.Output | Out-Null
        Set-Content -LiteralPath (Join-Path $fixture.Output "install-driver.cmd") -Value "old owned output" -Encoding UTF8
        New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($fixture.Zip)) | Out-Null
        Set-Content -LiteralPath $fixture.Zip -Value "existing archive" -Encoding UTF8

        $outputBefore = Get-PathFingerprint -Path $fixture.Output
        $zipBefore = Get-PathFingerprint -Path $fixture.Zip
        $signedBefore = Get-PathFingerprint -Path $fixture.Signed
        $supportBefore = Get-PathFingerprint -Path $fixture.Support
        $parameters = @{
            SignedPackagePath = $fixture.Signed
            BuildOutputDirectory = $fixture.Support
            OutputDirectory = $fixture.Output
            ZipPath = $fixture.Zip
        }
        Assert-Throws -MessagePattern "changed after its manifest was written" -Action {
            & $fixture.AssembleScript @parameters | Out-Null
        }

        Assert-True ((Get-PathFingerprint -Path $fixture.Output) -eq $outputBefore) "Existing output changed after support manifest mismatch."
        Assert-True ((Get-PathFingerprint -Path $fixture.Zip) -eq $zipBefore) "Existing ZIP changed after support manifest mismatch."
        Assert-True ((Get-PathFingerprint -Path $fixture.Signed) -eq $signedBefore) "Signed input changed while rejecting support manifest mismatch."
        Assert-True ((Get-PathFingerprint -Path $fixture.Support) -eq $supportBefore) "Support input changed while rejecting its manifest mismatch."
        Assert-NoAssemblyTransactionArtifacts -Fixture $fixture
    }

    Invoke-Test "staged verification failure preserves the prior release" {
        $fixture = New-SyntheticAssemblyFixture -Root $assemblyTestRoot -Name "staged-verification-failure" -AssemblerSource $assembleScript
        Set-Content -LiteralPath (Join-Path $fixture.Harness "fail-final.marker") -Value "fail only staged verification" -Encoding UTF8
        New-Item -ItemType Directory -Force -Path $fixture.Output | Out-Null
        Set-Content -LiteralPath (Join-Path $fixture.Output "install-driver.cmd") -Value "old owned output" -Encoding UTF8
        New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($fixture.Zip)) | Out-Null
        Set-Content -LiteralPath $fixture.Zip -Value "existing archive" -Encoding UTF8

        $outputBefore = Get-PathFingerprint -Path $fixture.Output
        $zipBefore = Get-PathFingerprint -Path $fixture.Zip
        $signedBefore = Get-PathFingerprint -Path $fixture.Signed
        $supportBefore = Get-PathFingerprint -Path $fixture.Support
        $parameters = @{
            SignedPackagePath = $fixture.Signed
            BuildOutputDirectory = $fixture.Support
            OutputDirectory = $fixture.Output
            ZipPath = $fixture.Zip
        }
        Assert-Throws -MessagePattern "Synthetic staged verification failure" -Action {
            & $fixture.AssembleScript @parameters | Out-Null
        }

        Assert-True ((Get-PathFingerprint -Path $fixture.Output) -eq $outputBefore) "Existing output changed after staged verification failure."
        Assert-True ((Get-PathFingerprint -Path $fixture.Zip) -eq $zipBefore) "Existing ZIP changed after staged verification failure."
        Assert-True ((Get-PathFingerprint -Path $fixture.Signed) -eq $signedBefore) "Signed input changed after staged verification failure."
        Assert-True ((Get-PathFingerprint -Path $fixture.Support) -eq $supportBefore) "Support input changed after staged verification failure."
        Assert-NoAssemblyTransactionArtifacts -Fixture $fixture
    }

    Invoke-Test "replacement transaction rolls back when an existing ZIP cannot be moved" {
        $fixture = New-SyntheticAssemblyFixture -Root $assemblyTestRoot -Name "transaction-rollback" -AssemblerSource $assembleScript
        New-Item -ItemType Directory -Force -Path $fixture.Output | Out-Null
        Set-Content -LiteralPath (Join-Path $fixture.Output "install-driver.cmd") -Value "old owned output" -Encoding UTF8
        New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($fixture.Zip)) | Out-Null
        Set-Content -LiteralPath $fixture.Zip -Value "locked existing archive" -Encoding UTF8

        $outputBefore = Get-PathFingerprint -Path $fixture.Output
        $zipBefore = Get-PathFingerprint -Path $fixture.Zip
        $signedBefore = Get-PathFingerprint -Path $fixture.Signed
        $supportBefore = Get-PathFingerprint -Path $fixture.Support
        $parameters = @{
            SignedPackagePath = $fixture.Signed
            BuildOutputDirectory = $fixture.Support
            OutputDirectory = $fixture.Output
            ZipPath = $fixture.Zip
        }

        $zipLock = [IO.File]::Open($fixture.Zip, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $assemblyFailed = $false
        try {
            try {
                & $fixture.AssembleScript @parameters | Out-Null
            } catch {
                $assemblyFailed = $true
            }
        } finally {
            $zipLock.Dispose()
        }

        Assert-True $assemblyFailed "Assembly unexpectedly succeeded while the existing ZIP denied delete sharing."
        Assert-True ((Get-PathFingerprint -Path $fixture.Output) -eq $outputBefore) "Prior output was not restored after transaction failure."
        Assert-True ((Get-PathFingerprint -Path $fixture.Zip) -eq $zipBefore) "Prior ZIP changed after transaction failure."
        Assert-True ((Get-PathFingerprint -Path $fixture.Signed) -eq $signedBefore) "Signed input changed during transaction rollback."
        Assert-True ((Get-PathFingerprint -Path $fixture.Support) -eq $supportBefore) "Support input changed during transaction rollback."
        Assert-NoAssemblyTransactionArtifacts -Fixture $fixture
    }

    Invoke-Test "attestation requires explicit testing opt-in and is recorded" {
        $fixture = New-SyntheticAssemblyFixture -Root $assemblyTestRoot -Name "attestation" -AssemblerSource $assembleScript
        Set-Content -LiteralPath (Join-Path $fixture.Harness "attestation.marker") -Value "attestation" -Encoding UTF8
        $signedBefore = Get-PathFingerprint -Path $fixture.Signed
        $supportBefore = Get-PathFingerprint -Path $fixture.Support
        $parameters = @{
            SignedPackagePath = $fixture.Signed
            BuildOutputDirectory = $fixture.Support
            OutputDirectory = $fixture.Output
            ZipPath = $fixture.Zip
        }

        Assert-Throws -MessagePattern "Attestation signing is testing-only" -Action {
            & $fixture.AssembleScript @parameters | Out-Null
        }
        Assert-True (-not (Test-Path -LiteralPath $fixture.Output)) "Default attestation rejection created an output directory."
        Assert-True (-not (Test-Path -LiteralPath $fixture.Zip)) "Default attestation rejection created a ZIP."
        Assert-True ((Get-PathFingerprint -Path $fixture.Signed) -eq $signedBefore) "Signed input changed during default attestation rejection."
        Assert-True ((Get-PathFingerprint -Path $fixture.Support) -eq $supportBefore) "Support input changed during default attestation rejection."
        Assert-NoAssemblyTransactionArtifacts -Fixture $fixture

        $result = @(& $fixture.AssembleScript @parameters -AllowAttestation)[-1]
        Assert-True ($result.SigningKind -eq "attestation") "Explicit testing opt-in did not preserve attestation signing kind."
        $releaseManifest = Get-Content -LiteralPath (Join-Path $fixture.Output "SplatplostBluetooth-release-manifest.json") -Raw | ConvertFrom-Json
        Assert-True ($releaseManifest.signingKind -eq "attestation") "Attestation signing kind is missing from the release manifest."
        Assert-True ([bool]$releaseManifest.attestationTestingOptIn) "Release manifest does not record explicit attestation testing opt-in."
        Assert-True ((Get-PathFingerprint -Path $fixture.Signed) -eq $signedBefore) "Signed input changed during opted-in attestation assembly."
        Assert-True ((Get-PathFingerprint -Path $fixture.Support) -eq $supportBefore) "Support input changed during opted-in attestation assembly."
        Assert-NoAssemblyTransactionArtifacts -Fixture $fixture
    }
} finally {
    if (Test-Path -LiteralPath $assemblyTestRoot) {
        Remove-Item -LiteralPath $assemblyTestRoot -Recurse -Force
    }
}

if (-not $DevelopmentPackageDirectory) {
    Write-Host "SKIP package behavior tests -- pass -DevelopmentPackageDirectory with an INF/SYS/CAT development package."
} else {
    $package = [IO.Path]::GetFullPath($DevelopmentPackageDirectory)
    foreach ($name in @("SplatplostBluetooth.inf", "SplatplostBluetooth.sys", "SplatplostBluetooth.cat")) {
        if (-not (Test-Path -LiteralPath (Join-Path $package $name) -PathType Leaf)) {
            throw "Development package is missing ${name}: $package"
        }
    }

    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("splatplost-packaging-tests-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $temporaryRoot | Out-Null
    try {
        $symbols = Join-Path $package "SplatplostBluetooth.pdb"
        if (-not (Test-Path -LiteralPath $symbols -PathType Leaf)) {
            # The packaging script only checks the PDB boundary and never claims
            # that this placeholder is submission-ready. A real build must use
            # the PDB copied by build-driver.ps1.
            $symbols = Join-Path $temporaryRoot "structural-test-only.pdb"
            Copy-Item -LiteralPath (Join-Path $package "SplatplostBluetooth.sys") -Destination $symbols
        }

        $common = @{
            PackageDirectory = $package
            SymbolsPath = $symbols
        }
        if ($SignToolPath) {
            $common.SignToolPath = $SignToolPath
        }

        Invoke-Test "unsigned output requires explicit PrepareOnly" {
            $guardOutput = Join-Path $temporaryRoot "guard.cab"
            Assert-Throws -MessagePattern "explicitly use -PrepareOnly" -Action {
                & $prepareScript @common -OutputPath $guardOutput | Out-Null
            }
            Assert-True (-not (Test-Path -LiteralPath $guardOutput)) "Unsigned guard left a CAB behind."
        }

        Invoke-Test "matching development catalog produces an exact structural CAB" {
            $cab = Join-Path $temporaryRoot "structural.cab"
            $result = @(& $prepareScript @common -OutputPath $cab -PrepareOnly)[-1]
            Assert-True (Test-Path -LiteralPath $cab -PathType Leaf) "Structural CAB was not created."
            Assert-True (-not $result.Signed) "PrepareOnly unexpectedly reported a signed CAB."
            $manifest = Get-Content -LiteralPath "$cab.manifest.json" -Raw | ConvertFrom-Json
            Assert-True ($manifest.files.Count -eq 4) "Manifest must contain exactly INF, SYS, PDB, and CAT."
            Assert-True ($manifest.cab.sha256 -eq (Get-FileHash -LiteralPath $cab -Algorithm SHA256).Hash.ToLowerInvariant()) "Manifest CAB digest does not match."
        }

        Invoke-Test "provided catalog rejects a changed SYS" {
            $mutated = Join-Path $temporaryRoot "mutated"
            New-Item -ItemType Directory -Force -Path $mutated | Out-Null
            foreach ($name in @(
                "SplatplostBluetooth.inf",
                "SplatplostBluetooth.cat",
                "SplatplostBluetooth-build-manifest.json"
            )) {
                Copy-Item -LiteralPath (Join-Path $package $name) -Destination (Join-Path $mutated $name)
            }
            Copy-Item -LiteralPath (Join-Path $repositoryRoot "readme.md") -Destination (Join-Path $mutated "SplatplostBluetooth.sys")
            $mutatedManifestPath = Join-Path $mutated "SplatplostBluetooth-build-manifest.json"
            $mutatedManifest = Get-Content -LiteralPath $mutatedManifestPath -Raw | ConvertFrom-Json
            $mutatedSysEntries = @($mutatedManifest.files | Where-Object { [string]$_.name -ceq "SplatplostBluetooth.sys" })
            Assert-True ($mutatedSysEntries.Count -eq 1) "Mutated package fixture has no unique SYS identity."
            $mutatedSysEntries[0].sha256 = `
                (Get-FileHash -LiteralPath (Join-Path $mutated "SplatplostBluetooth.sys") -Algorithm SHA256).Hash.ToLowerInvariant()
            $mutatedManifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $mutatedManifestPath -Encoding UTF8
            $mutatedParameters = @{
                PackageDirectory = $mutated
                SymbolsPath = $symbols
                OutputPath = (Join-Path $temporaryRoot "mutated.cab")
                PrepareOnly = $true
            }
            if ($SignToolPath) {
                $mutatedParameters.SignToolPath = $SignToolPath
            }
            Assert-Throws -MessagePattern "catalog does not cover SplatplostBluetooth.sys" -Action {
                & $prepareScript @mutatedParameters | Out-Null
            }
        }

        Invoke-Test "Microsoft verifier rejects the development-signed package" {
            $verifyParameters = @{ SignedPackagePath = $package }
            if ($SignToolPath) {
                $verifyParameters.SignToolPath = $SignToolPath
            }
            Assert-Throws -MessagePattern "kernel-policy verification" -Action {
                & $verifyScript @verifyParameters *>&1 | Out-Null
            }
        }

        Invoke-Test "Microsoft verifier rejects duplicate payload copies" {
            $duplicateRoot = Join-Path $temporaryRoot "duplicate"
            foreach ($folder in @("one", "two")) {
                $destination = Join-Path $duplicateRoot $folder
                New-Item -ItemType Directory -Force -Path $destination | Out-Null
                foreach ($name in @("SplatplostBluetooth.inf", "SplatplostBluetooth.sys", "SplatplostBluetooth.cat")) {
                    Copy-Item -LiteralPath (Join-Path $package $name) -Destination (Join-Path $destination $name)
                }
            }
            $verifyParameters = @{ SignedPackagePath = $duplicateRoot }
            if ($SignToolPath) {
                $verifyParameters.SignToolPath = $SignToolPath
            }
            Assert-Throws -MessagePattern "Expected exactly one SplatplostBluetooth.inf" -Action {
                & $verifyScript @verifyParameters | Out-Null
            }
        }
    } finally {
        if (Test-Path -LiteralPath $temporaryRoot) {
            Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
        }
    }
}

if ($script:Failures -ne 0) {
    throw "$script:Failures packaging script test(s) failed."
}

$global:LASTEXITCODE = 0
Write-Host "ALL TESTS PASSED"
