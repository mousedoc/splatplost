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
        Write-Host "FAIL $Name -- $($_.Exception.Message)"
    }
}

$verifier = Join-Path $PSScriptRoot "verify-runtime.ps1"

Invoke-Test "runtime verifier parses without errors" {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($verifier, [ref]$tokens, [ref]$errors) | Out-Null
    Assert-True ($errors.Count -eq 0) "Parser errors: $($errors -join '; ')"
}

Invoke-Test "runtime verifier contains every required fail-closed probe" {
    $source = Get-Content -LiteralPath $verifier -Raw
    foreach ($required in @(
        "Confirm-SecureBootUEFI",
        "NtQuerySystemInformation",
        "Win32_DeviceGuard",
        "SecurityServicesRunning",
        "0x400",
        "Get-PnpDevice",
        "DEVPKEY_Device_Service",
        "DEVPKEY_Device_ProblemCode",
        "publishedInfIdentityValid",
        "Get-AuthenticodeSignature",
        "1.3.6.1.4.1.311.10.3.5.1",
        "1.3.6.1.4.1.311.10.3.5",
        "0x00222000",
        "initializationStage",
        "0x0011",
        "0x0013",
        "Confirm-SignedReleaseManifest",
        "Confirm-SignatureEvidence",
        "Resolve-TrustedSignTool",
        "EvidenceFileIdentityV1",
        "Assert-SafeEvidenceDestination",
        "Write-RuntimeEvidenceAtomically",
        "RequireConnected"
    )) {
        Assert-True ($source.Contains($required)) "Missing required probe token: $required"
    }
    Assert-True ($source -match '\$stage -eq \$readyStage') "Ready stage is not enforced."
    Assert-True ($source -match 'InitializationStatus -eq 0') "Successful driver NTSTATUS is not enforced."
    Assert-True ($source -match '\$controlConnected -and \$interruptConnected') "Both HID channels are not enforced."
    Assert-True ($source -match '-not \$check\.readable -or -not \$check\.passed') "Unreadable values are not fail-closed."
    Assert-True ($source -match '\$signatureEvidence\.signingKind -ne \$catalogSignature\.hardwareSigningKind') "The claimed signing kind is not correlated to the live catalog."
    Assert-True (-not $source.Contains('$membershipVerified = [bool]$signatureEvidence')) "Unsigned JSON still establishes catalog membership."
    Assert-True ($source -match 'CreateFile\(\s*path,\s*0,') "The status query does not use a status-only handle."
    Assert-True ($source -match '\$catalogExitCode -ne 0') "SignTool warning exits are not fail-closed."
    Assert-True ($source -match 'signToolTranscripts') "SignTool verification output is not retained in evidence."
    Assert-True ($source -match 'Assert-CanonicalWindowsKitsSignToolPath') "SignTool is not constrained to the canonical Windows Kits x64 path."
    Assert-True ($source -match 'GetExistingFileIdentity') "SignTool file identity and hard-link count are not captured."
    Assert-True ($source -match 'OriginalFilename.*signtool\.exe') "A renamed Microsoft executable can impersonate SignTool."
    Assert-True ($source -match 'PeMachine -ne \[uint16\]0x8664') "SignTool is not required to be an x64 PE image."
    Assert-True ($source -match '1\.3\.6\.1\.5\.5\.7\.3\.3') "SignTool code-signing EKU is not enforced."
    Assert-True ($source -match 'Invoke-TrustedSignTool') "SignTool executions are not wrapped by identity revalidation."
    Assert-True ($source -match '(?s)\$before = Get-TrustedSignToolSnapshot.*finally\s*\{.*?\$after = Get-TrustedSignToolSnapshot') "SignTool is not revalidated immediately before and after execution."
    Assert-True ($source -match 'PresentDeviceCount -eq 1') "Runtime PnP evidence does not require exactly one profile device."
    Assert-True ($source -match '(?s)GetValueKind\("InstalledRadioAddress"\).*RegistryValueKind\]::QWord') "Installed radio state is not required to be a QWORD."
    Assert-True ($source -match '\$LocalAddress -eq \$InstalledRadioAddress') "Driver local address is not correlated to the installed radio state."
    Assert-True ([regex]::Matches($source, 'Confirm-SignedReleaseManifest -PackageDirectory \$resolvedPackage').Count -ge 2) "The complete release is not revalidated after SignTool checks."
    Assert-True ($source -match 'Assert-ExactPackageSnapshot -Expected \$packageStartSnapshot -Actual \$packageEndSnapshot') "Package start/end snapshots are not compared exactly."
    Assert-True ($source -match 'OpenPinnedPackageFile') "Release files are not held against transient replacement."
    Assert-True ($source -match 'OpenPinnedPackageDirectory') "The release directory is not held against path substitution."
    Assert-True ($source -match 'immediately before SignTool execution') "Pinned package identity is not checked immediately before SignTool."
    Assert-True ($source -match 'immediately after SignTool execution') "Pinned package identity is not checked immediately after SignTool."
    Assert-True ($source -match '(?s)Invoke-TrustedSignTool.*PackagePin') "SignTool verification is not bound to the pinned release package."
    Assert-True ($source -match '-PackageDirectory is required because the release manifest') "Verifier still has an impossible implicit Driver Store package mode."
    Assert-True ($source -notmatch 'splatplostbluetooth\.inf_\*') "Verifier still guesses a release folder from Driver Store directory names."
}

Invoke-Test "trusted SignTool resolution rejects writable aliases and post-resolution mutation" {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($verifier, [ref]$tokens, [ref]$errors)
    $source = Get-Content -LiteralPath $verifier -Raw
    $interopMatch = [regex]::Matches(
        $source,
        '(?s)Add-Type\s+-TypeDefinition\s+@"\r?\n(?<code>.*?)\r?\n"@'
    ) | Where-Object {
        $_.Groups['code'].Value -match 'EvidenceFileIdentityV1'
    } | Select-Object -First 1
    Assert-True ($null -ne $interopMatch) "Evidence file-identity interop was not found."
    if (-not ("Splatplost.EvidenceFileIdentityV1" -as [type])) {
        Add-Type -TypeDefinition $interopMatch.Groups['code'].Value -Language CSharp
    }
    foreach ($functionName in @(
        "Get-WindowsKitsBinRoot",
        "Assert-CanonicalWindowsKitsSignToolPath",
        "Get-TrustedFileSystemPrincipals",
        "Assert-TrustedSignToolFileSystemPath",
        "Get-PeMachine",
        "Assert-TrustedSignToolMetadata",
        "Get-TrustedSignToolSnapshot",
        "Assert-TrustedSignToolSnapshotMatches",
        "Resolve-TrustedSignTool"
    )) {
        $functionAst = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
        }, $true)
        Assert-True ($null -ne $functionAst) "$functionName was not found."
        . ([scriptblock]::Create($functionAst.Extent.Text))
    }

    $temporary = Join-Path ([IO.Path]::GetTempPath()) ("splatplost-fake-tool-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $temporary | Out-Null
    $originalPath = $env:PATH
    try {
        $fake = Join-Path $temporary "signtool.exe"
        Set-Content -LiteralPath $fake -Value "not a signed executable" -Encoding ASCII
        $env:PATH = "$temporary;$originalPath"
        $resolved = Resolve-TrustedSignTool
        Assert-True (-not [string]::Equals($resolved.Path, $fake, [StringComparison]::OrdinalIgnoreCase)) "PATH-injected SignTool was selected."
        Assert-True ($resolved.Path -match '(?i)\\Windows Kits\\10\\bin\\[^\\]+\\x64\\signtool\.exe$') "The trusted Windows Kits SignTool was not selected: $($resolved.Path)"
        Assert-True ($resolved.PeMachine -eq "0x8664" -and $resolved.OriginalFilename -ieq "signtool.exe") "The resolved executable is not exact x64 SignTool."
        Assert-True ($resolved.Sha256 -match '^[0-9a-f]{64}$' -and $resolved.FileIdentity) "The resolved SignTool snapshot is incomplete."

        $explicit = Resolve-TrustedSignTool -ExplicitPath $resolved.Path
        Assert-TrustedSignToolSnapshotMatches -Expected $resolved -Actual $explicit
        Assert-Throws -MessagePattern "inside the protected Windows Kits" -Action {
            Resolve-TrustedSignTool -ExplicitPath $fake | Out-Null
        }

        Assert-Throws -MessagePattern "untrusted owner|user-writable" -Action {
            Assert-TrustedSignToolFileSystemPath -Path $fake -TrustedRoot $temporary | Out-Null
        }

        $renamedSignature = Get-AuthenticodeSignature -LiteralPath $resolved.Path
        Assert-Throws -MessagePattern "renamed Microsoft binary" -Action {
            Assert-TrustedSignToolMetadata `
                -OriginalFilename "notepad.exe" `
                -PeMachine ([uint16]0x8664) `
                -Signature $renamedSignature `
                -EkuOids @("1.3.6.1.5.5.7.3.3") `
                -ChainValid $true `
                -ChainRootSubject "CN=Microsoft Root Certificate Authority 2010, O=Microsoft Corporation"
        }

        $junctionTarget = Join-Path $temporary "junction-target"
        $junction = Join-Path $temporary "junction"
        New-Item -ItemType Directory -Path $junctionTarget | Out-Null
        Set-Content -LiteralPath (Join-Path $junctionTarget "tool.exe") -Value "fixture" -Encoding ASCII
        New-Item -ItemType Junction -Path $junction -Target $junctionTarget | Out-Null
        Assert-Throws -MessagePattern "symbolic link, junction, or other reparse point" -Action {
            Assert-TrustedSignToolFileSystemPath `
                -Path (Join-Path $junction "tool.exe") `
                -TrustedRoot $temporary | Out-Null
        }

        $hardLinkSource = Join-Path $temporary "hardlink-source.exe"
        $hardLinkAlias = Join-Path $temporary "hardlink-alias.exe"
        Set-Content -LiteralPath $hardLinkSource -Value "fixture" -Encoding ASCII
        New-Item -ItemType HardLink -Path $hardLinkAlias -Target $hardLinkSource | Out-Null
        Assert-Throws -MessagePattern "multiple hard links" -Action {
            Assert-TrustedSignToolFileSystemPath -Path $hardLinkAlias -TrustedRoot $temporary | Out-Null
        }

        $mutatedSnapshot = $resolved.PSObject.Copy()
        $mutatedSnapshot.Sha256 = "0" * 64
        Assert-Throws -MessagePattern "changed after its trusted identity" -Action {
            Assert-TrustedSignToolSnapshotMatches -Expected $resolved -Actual $mutatedSnapshot
        }
    } finally {
        $env:PATH = $originalPath
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "isolated verifier signature copy stays byte-exact and pinned" {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($verifier, [ref]$tokens, [ref]$errors)
    foreach ($functionName in @(
        "Get-VerificationReadOnlyStreamSha256",
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

    $source = Get-Content -LiteralPath $verifier -Raw
    Assert-True ($source -match '\$sourcePin = \[Splatplost\.EvidenceFileIdentityV1\]::OpenPinnedPackageFile') "The original SYS is not pinned during isolated verification."
    Assert-True ($source -match '\$copyPin = \[Splatplost\.EvidenceFileIdentityV1\]::OpenPinnedPackageFile') "The isolated SYS copy is not pinned during Authenticode verification."
    Assert-True ($source -match 'FileMode\]::CreateNew') "The verifier signature copy is not created atomically."
    Assert-True ($source -match 'FileShare\]::None') "The verifier signature copy is visible before it is complete."
    Assert-True ($source -match 'isolated signature copy does not exactly match its pinned source') "The verifier does not establish exact source/copy bytes."
    Assert-True ($source -match 'changed during Authenticode verification') "The verifier does not recheck source/copy bytes after Authenticode verification."

    $temporary = Join-Path ([IO.Path]::GetTempPath()) ("splatplost-isolated-verifier-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $temporary -Force | Out-Null
    try {
        $script:IsolatedVerifierSource = Join-Path $temporary "source.sys"
        $script:IsolatedVerifierReplacement = Join-Path $temporary "replacement.sys"
        Set-Content -LiteralPath $script:IsolatedVerifierSource -Value "signed-source-fixture" -Encoding ASCII
        Set-Content -LiteralPath $script:IsolatedVerifierReplacement -Value "replacement-fixture" -Encoding ASCII
        $sourceHash = (Get-FileHash -LiteralPath $script:IsolatedVerifierSource -Algorithm SHA256).Hash
        $script:IsolatedVerifierCopyPath = $null
        $script:IsolatedVerifierBlockedMutations = 0

        function Get-AuthenticodeSignature {
            [CmdletBinding()]
            param([Parameter(Mandatory = $true)][string]$LiteralPath)

            $script:IsolatedVerifierCopyPath = $LiteralPath
            foreach ($attack in @(
                { Set-Content -LiteralPath $LiteralPath -Value "write-attack" -Encoding ASCII },
                { Move-Item -LiteralPath $LiteralPath -Destination "$LiteralPath.renamed" },
                {
                    [IO.File]::Replace(
                        $script:IsolatedVerifierReplacement,
                        $LiteralPath,
                        "$LiteralPath.backup"
                    )
                },
                { Set-Content -LiteralPath $script:IsolatedVerifierSource -Value "source-write-attack" -Encoding ASCII }
            )) {
                $blocked = $false
                try {
                    & $attack
                } catch {
                    $blocked = $true
                }
                if (-not $blocked) {
                    throw "A pinned verifier signature mutation unexpectedly succeeded."
                }
                $script:IsolatedVerifierBlockedMutations++
            }
            return [pscustomobject]@{ Status = "MockedValid"; Path = $LiteralPath }
        }

        try {
            $signature = Get-IsolatedAuthenticodeSignature -Path $script:IsolatedVerifierSource
        } finally {
            Remove-Item -LiteralPath Function:\Get-AuthenticodeSignature -Force -ErrorAction SilentlyContinue
        }
        Assert-True ($signature.Status -eq "MockedValid") "The normal verifier signature path did not return its signature result."
        Assert-True ($script:IsolatedVerifierBlockedMutations -eq 4) "Not every verifier source/copy mutation attack was blocked."
        Assert-True (-not (Test-Path -LiteralPath $script:IsolatedVerifierCopyPath)) "The verifier signature copy was not cleaned up."
        Assert-True ((Get-FileHash -LiteralPath $script:IsolatedVerifierSource -Algorithm SHA256).Hash -eq $sourceHash) "The verifier source changed during signature verification."
    } finally {
        Remove-Item -LiteralPath Function:\Get-AuthenticodeSignature -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "release package pin blocks transient swap rename and write attacks" {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($verifier, [ref]$tokens, [ref]$errors)
    foreach ($functionName in @(
        "Get-WindowsKitsBinRoot",
        "Assert-CanonicalWindowsKitsSignToolPath",
        "Get-TrustedFileSystemPrincipals",
        "Assert-TrustedSignToolFileSystemPath",
        "Get-PeMachine",
        "Assert-TrustedSignToolMetadata",
        "Get-TrustedSignToolSnapshot",
        "Assert-TrustedSignToolSnapshotMatches",
        "Resolve-TrustedSignTool",
        "Invoke-TrustedSignTool",
        "Assert-VerificationPackagePathIsLocalAndUnaliased",
        "Get-PinnedVerificationPackageSnapshot",
        "Assert-PinnedVerificationPackageSnapshot",
        "Close-VerificationPackagePin",
        "New-VerificationPackagePin"
    )) {
        $functionAst = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
        }, $true)
        Assert-True ($null -ne $functionAst) "$functionName was not found."
        . ([scriptblock]::Create($functionAst.Extent.Text))
    }

    $source = Get-Content -LiteralPath $verifier -Raw
    $pinAcquisition = $source.IndexOf('$verificationPackagePin = New-VerificationPackagePin')
    $evidenceStart = $source.IndexOf('$evidence = [ordered]@{')
    $writeEvidence = $source.IndexOf('Write-RuntimeEvidenceAtomically -Evidence $evidence')
    $closePin = $source.LastIndexOf('Close-VerificationPackagePin -PackagePin $verificationPackagePin')
    Assert-True ($pinAcquisition -ge 0 -and $pinAcquisition -lt $evidenceStart) "Release files are not pinned before evidence collection starts."
    Assert-True ($closePin -gt $writeEvidence) "Release files are unpinned before evidence publication finishes."
    Assert-True ($source -match 'FILE_SHARE_READ\s*=\s*0x00000001') "Release pins do not deny write/delete sharing."
    Assert-True ($source -match 'FILE_FLAG_OPEN_REPARSE_POINT') "Release pins can traverse a substituted leaf reparse point."
    Assert-True ([regex]::Matches($source, '-PackagePin \$verificationPackagePin').Count -ge 3) "Not every SignTool invocation and checkpoint is bound to the package pin."

    function New-PackagePinFixture {
        param([Parameter(Mandatory = $true)][string]$Directory)

        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
        foreach ($name in @("core.bin", "support.ps1")) {
            Set-Content -LiteralPath (Join-Path $Directory $name) -Value "fixture-$name" -Encoding ASCII
        }
        $manifest = [ordered]@{
            schemaVersion = 1
            files = @(@("core.bin", "support.ps1") | ForEach-Object {
                [ordered]@{
                    name = $_
                    sha256 = (Get-FileHash -LiteralPath (Join-Path $Directory $_) -Algorithm SHA256).Hash
                }
            })
        }
        $manifest | ConvertTo-Json -Depth 5 | Set-Content `
            -LiteralPath (Join-Path $Directory "SplatplostBluetooth-release-manifest.json") `
            -Encoding UTF8
    }

    $temporary = Join-Path ([IO.Path]::GetTempPath()) ("splatplost-verifier-pin-" + [Guid]::NewGuid().ToString("N"))
    New-PackagePinFixture -Directory $temporary
    $pin = $null
    try {
        $core = Join-Path $temporary "core.bin"
        $replacement = Join-Path $temporary "replacement.bin"
        $pin = New-VerificationPackagePin -PackageDirectory $temporary
        $snapshot = Get-PinnedVerificationPackageSnapshot -PackagePin $pin
        Assert-PinnedVerificationPackageSnapshot `
            -Expected $pin.InitialSnapshot `
            -Actual $snapshot `
            -Checkpoint "fixture baseline"
        Assert-True ((Get-Content -LiteralPath $core -Raw) -match "fixture-core") "Pinned files did not allow a second reader such as SignTool."

        $trustedSignTool = Resolve-TrustedSignTool
        $normalInvocation = Invoke-TrustedSignTool `
            -Snapshot $trustedSignTool `
            -Arguments @("/?") `
            -PackagePin $pin
        Assert-True ($normalInvocation.ExitCode -eq 0) "Trusted SignTool did not execute normally while the release package was pinned."
        Assert-True (@($normalInvocation.Output).Count -gt 0) "Trusted SignTool normal-path output was not captured."

        $sharingFailure = '(?i)(used by another process|process cannot access|sharing violation|access.*denied|being used|could not be pinned for read-only sharing)'
        Assert-Throws -MessagePattern $sharingFailure -Action {
            Set-Content -LiteralPath $core -Value "write-attack" -Encoding ASCII
        }
        Assert-Throws -MessagePattern $sharingFailure -Action {
            Move-Item -LiteralPath $core -Destination (Join-Path $temporary "renamed.bin")
        }
        Assert-Throws -MessagePattern $sharingFailure -Action {
            Remove-Item -LiteralPath $core -Force
        }
        Set-Content -LiteralPath $replacement -Value "transient-old-valid-package" -Encoding ASCII
        Assert-Throws -MessagePattern $sharingFailure -Action {
            [IO.File]::Replace(
                $replacement,
                $core,
                (Join-Path $temporary "transient-backup.bin")
            )
        }

        $evidenceTemporary = Join-Path $temporary ".runtime-evidence.tmp"
        $evidencePublished = Join-Path $temporary "SplatplostBluetooth-runtime-evidence.json"
        Set-Content -LiteralPath $evidenceTemporary -Value '{"passed":true}' -Encoding ASCII
        Move-Item -LiteralPath $evidenceTemporary -Destination $evidencePublished
        Assert-True (Test-Path -LiteralPath $evidencePublished -PathType Leaf) "Holding the package pin blocked atomic publication of the separate runtime evidence file."

        Close-VerificationPackagePin -PackagePin $pin
        $pin = $null
        Set-Content -LiteralPath $core -Value "write-after-close" -Encoding ASCII
        Move-Item -LiteralPath $core -Destination (Join-Path $temporary "renamed-after-close.bin")

        Set-Content -LiteralPath $core -Value "writer-conflict" -Encoding ASCII
        $writer = [IO.File]::Open(
            $core,
            [IO.FileMode]::Open,
            [IO.FileAccess]::ReadWrite,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        )
        try {
            Assert-Throws -MessagePattern $sharingFailure -Action {
                New-VerificationPackagePin -PackageDirectory $temporary | Out-Null
            }
        } finally {
            $writer.Dispose()
        }

        $junctionTarget = Join-Path ([IO.Path]::GetTempPath()) ("splatplost-verifier-pin-target-" + [Guid]::NewGuid().ToString("N"))
        $junction = Join-Path ([IO.Path]::GetTempPath()) ("splatplost-verifier-pin-junction-" + [Guid]::NewGuid().ToString("N"))
        New-PackagePinFixture -Directory $junctionTarget
        try {
            New-Item -ItemType Junction -Path $junction -Target $junctionTarget | Out-Null
            Assert-Throws -MessagePattern "reparse point|unsafe" -Action {
                New-VerificationPackagePin -PackageDirectory $junction | Out-Null
            }
        } finally {
            if ([IO.Directory]::Exists($junction)) {
                [IO.Directory]::Delete($junction)
            }
            Remove-Item -LiteralPath $junctionTarget -Recurse -Force -ErrorAction SilentlyContinue
        }
    } finally {
        if ($null -ne $pin) {
            Close-VerificationPackagePin -PackagePin $pin
        }
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "release provenance rejects a changed package" {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($verifier, [ref]$tokens, [ref]$errors)
    foreach ($functionName in @("Confirm-SignedReleaseManifest", "Confirm-SignatureEvidence")) {
        $functionAst = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
        }, $true)
        Assert-True ($null -ne $functionAst) "$functionName was not found."
        . ([scriptblock]::Create($functionAst.Extent.Text))
    }

    $temporary = Join-Path ([IO.Path]::GetTempPath()) ("splatplost-runtime-manifest-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $temporary | Out-Null
    try {
        $requiredNames = @(
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
        )
        foreach ($name in $requiredNames | Where-Object { $_ -ne "SplatplostBluetooth-signature-evidence.json" }) {
            Set-Content -LiteralPath (Join-Path $temporary $name) -Value "fixture-$name" -Encoding UTF8
        }

        $signedNames = @("SplatplostBluetooth.inf", "SplatplostBluetooth.sys", "SplatplostBluetooth.cat")
        $signedHashes = @{}
        foreach ($name in $signedNames) {
            $signedHashes[$name] = (Get-FileHash -LiteralPath (Join-Path $temporary $name) -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $signatureFixture = [ordered]@{
            schemaVersion = 1
            verifiedAtUtc = [DateTime]::UtcNow.ToString("o")
            signingKind = "hlk-whcp"
            files = @($signedNames | ForEach-Object { [ordered]@{ name = $_; sha256 = $signedHashes[$_] } })
            verified = [ordered]@{
                microsoftCatalogSignature = $true
                catalogCoversInfAndSys = $true
                embeddedDriverSignature = $true
            }
        }
        $signatureFixture | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $temporary "SplatplostBluetooth-signature-evidence.json") -Encoding UTF8

        $releaseFixture = [ordered]@{
            schemaVersion = 1
            files = @($requiredNames | ForEach-Object {
                [ordered]@{
                    name = $_
                    sha256 = (Get-FileHash -LiteralPath (Join-Path $temporary $_) -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            })
        }
        $releaseFixture | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $temporary "SplatplostBluetooth-release-manifest.json") -Encoding UTF8

        $releaseResult = Confirm-SignedReleaseManifest -PackageDirectory $temporary
        Assert-True $releaseResult.verified "Exact release fixture did not verify."
        $signatureResult = Confirm-SignatureEvidence -PackageDirectory $temporary -ExpectedFiles $signedHashes
        Assert-True $signatureResult.catalogMembershipClaimed "Exact signature evidence did not parse as a strict claim."

        foreach ($field in @("microsoftCatalogSignature", "catalogCoversInfAndSys", "embeddedDriverSignature")) {
            $signatureFixture.verified[$field] = "false"
            $signatureFixture | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $temporary "SplatplostBluetooth-signature-evidence.json") -Encoding UTF8
            Assert-Throws -MessagePattern "invalid or incomplete" -Action {
                Confirm-SignatureEvidence -PackageDirectory $temporary -ExpectedFiles $signedHashes | Out-Null
            }
            $signatureFixture.verified[$field] = $true
        }
        $signatureFixture.verifiedAtUtc = "not-a-date"
        $signatureFixture | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $temporary "SplatplostBluetooth-signature-evidence.json") -Encoding UTF8
        Assert-Throws -MessagePattern "invalid or incomplete" -Action {
            Confirm-SignatureEvidence -PackageDirectory $temporary -ExpectedFiles $signedHashes | Out-Null
        }

        $signatureFixture.verifiedAtUtc = [DateTime]::UtcNow.ToString("o")
        $signatureFixture | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $temporary "SplatplostBluetooth-signature-evidence.json") -Encoding UTF8

        Add-Content -LiteralPath (Join-Path $temporary "install-driver.cmd") -Value "changed"
        Assert-Throws -MessagePattern "does not match its release manifest" -Action {
            Confirm-SignedReleaseManifest -PackageDirectory $temporary | Out-Null
        }
    } finally {
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "exact device radio and package snapshots reject inconsistent state" {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($verifier, [ref]$tokens, [ref]$errors)
    foreach ($functionName in @(
        "Test-SplatplostPnpReady",
        "Test-SplatplostBridgeReady",
        "Assert-ExactPackageSnapshot"
    )) {
        $functionAst = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
        }, $true)
        Assert-True ($null -ne $functionAst) "$functionName was not found."
        . ([scriptblock]::Create($functionAst.Extent.Text))
    }

    Assert-True (Test-SplatplostPnpReady -PresentDeviceCount 1 -AllDevicesHealthy $true -DriverRunning $true -InstalledRadioStateValid $true) "Exact healthy one-device PnP state did not pass."
    foreach ($count in @(0, 2)) {
        Assert-True (-not (Test-SplatplostPnpReady -PresentDeviceCount $count -AllDevicesHealthy $true -DriverRunning $true -InstalledRadioStateValid $true)) "PnP state passed with $count present devices."
    }
    Assert-True (-not (Test-SplatplostPnpReady -PresentDeviceCount 1 -AllDevicesHealthy $true -DriverRunning $true -InstalledRadioStateValid $false)) "PnP state passed without exact installed radio metadata."

    [uint64]$radioAddress = 0x001122334455
    Assert-True (Test-SplatplostBridgeReady -Stage 5 -InitializationStatus 0 -LocalAddress $radioAddress -InstalledRadioAddress $radioAddress) "Exact driver/installed radio address did not pass."
    Assert-True (-not (Test-SplatplostBridgeReady -Stage 5 -InitializationStatus 0 -LocalAddress $radioAddress -InstalledRadioAddress ([uint64]0x00AABBCCDDEE))) "A mismatched driver radio address passed."
    Assert-True (-not (Test-SplatplostBridgeReady -Stage 5 -InitializationStatus 0 -LocalAddress $radioAddress -InstalledRadioAddress 0)) "A missing installed radio address passed."

    $snapshot = [pscustomobject]@{
        ReleaseManifestSha256 = "1" * 64
        ReleaseManifestFileCount = 12
        InfSha256 = "2" * 64
        SysSha256 = "3" * 64
        CatalogSha256 = "4" * 64
        InstalledSysSha256 = "3" * 64
    }
    Assert-ExactPackageSnapshot -Expected $snapshot -Actual $snapshot.PSObject.Copy()
    foreach ($field in @(
        "ReleaseManifestSha256",
        "ReleaseManifestFileCount",
        "InfSha256",
        "SysSha256",
        "CatalogSha256",
        "InstalledSysSha256"
    )) {
        $changed = $snapshot.PSObject.Copy()
        $changed.$field = if ($field -eq "ReleaseManifestFileCount") { 13 } else { "0" * 64 }
        Assert-Throws -MessagePattern "$field mismatch" -Action {
            Assert-ExactPackageSnapshot -Expected $snapshot -Actual $changed
        }
    }
}

Invoke-Test "runtime evidence rejects a directory destination without leaving a hidden file" {
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ("splatplost-runtime-directory-" + [Guid]::NewGuid().ToString("N"))
    $evidenceDirectory = Join-Path $temporary "evidence-directory"
    New-Item -ItemType Directory -Force -Path $evidenceDirectory | Out-Null
    try {
        $message = $null
        try {
            & $verifier `
                -EvidencePath $evidenceDirectory `
                -BridgePath "\\.\SplatplostVerificationMissing$([Guid]::NewGuid().ToString('N'))" `
                -RequireConnected *>&1 | Out-Null
        } catch {
            $message = $_.Exception.Message
        }
        Assert-True ($message -match "exists as a directory") "Directory EvidencePath was not rejected: $message"
        Assert-True (@(Get-ChildItem -LiteralPath $evidenceDirectory -Force).Count -eq 0) "A hidden temporary evidence file was left in the directory."
    } finally {
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "runtime evidence cannot overwrite a package input through a hard link" {
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ("splatplost-runtime-collision-" + [Guid]::NewGuid().ToString("N"))
    $package = Join-Path $temporary "package"
    New-Item -ItemType Directory -Force -Path $package | Out-Null
    try {
        $protectedPath = Join-Path $package "SplatplostBluetooth.inf"
        $evidenceAlias = Join-Path $temporary "evidence-alias.json"
        Set-Content -LiteralPath $protectedPath -Value "protected-package-input" -Encoding UTF8
        New-Item -ItemType HardLink -Path $evidenceAlias -Target $protectedPath | Out-Null
        $beforeHash = (Get-FileHash -LiteralPath $protectedPath -Algorithm SHA256).Hash

        $message = $null
        try {
            $arguments = @{
                PackageDirectory = $package
                EvidencePath = $evidenceAlias
                BridgePath = "\\.\SplatplostVerificationMissing$([Guid]::NewGuid().ToString('N'))"
                RequireConnected = $true
            }
            & $verifier @arguments *>&1 | Out-Null
        } catch {
            $message = $_.Exception.Message
        }

        Assert-True ($message -match "would overwrite a protected verifier input") "The protected-path collision was not rejected: $message"
        $afterHash = (Get-FileHash -LiteralPath $protectedPath -Algorithm SHA256).Hash
        Assert-True ($afterHash -eq $beforeHash) "The package input changed despite collision rejection."
    } finally {
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test "mocked readiness rejects each missing connected requirement" {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($verifier, [ref]$tokens, [ref]$errors)
    $functionAst = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Complete-RuntimeEvidence"
    }, $true)
    Assert-True ($null -ne $functionAst) "Complete-RuntimeEvidence was not found."
    . ([scriptblock]::Create($functionAst.Extent.Text))

    function New-MockedEvidence {
        $checks = [ordered]@{}
        foreach ($name in @(
            "administrator",
            "secureBoot",
            "testSigning",
            "memoryIntegrity",
            "pnp",
            "microsoftSignedPackage",
            "bridgeInitialization",
            "hidChannels"
        )) {
            $checks[$name] = [ordered]@{ readable = $true; passed = $true; error = $null }
        }
        return [ordered]@{
            checks = $checks
            failures = @()
            installationReady = $false
            connectedReady = $false
            passed = $false
        }
    }

    $success = New-MockedEvidence
    Complete-RuntimeEvidence -Evidence $success -RequireConnected $true
    Assert-True $success.passed "All-good connected fixture did not pass."

    foreach ($name in @(
        "administrator",
        "secureBoot",
        "testSigning",
        "memoryIntegrity",
        "pnp",
        "microsoftSignedPackage",
        "bridgeInitialization",
        "hidChannels"
    )) {
        $fixture = New-MockedEvidence
        $fixture.checks[$name].passed = $false
        Complete-RuntimeEvidence -Evidence $fixture -RequireConnected $true
        Assert-True (-not $fixture.passed) "RequireConnected passed with $name failed."
        Assert-True ($fixture.failures.Count -gt 0) "No failure reason was recorded for $name."

        $unreadableFixture = New-MockedEvidence
        $unreadableFixture.checks[$name].readable = $false
        Complete-RuntimeEvidence -Evidence $unreadableFixture -RequireConnected $true
        Assert-True (-not $unreadableFixture.passed) "RequireConnected passed with $name unreadable."
    }
}

Invoke-Test "RequireConnected writes failing evidence for an unreadable bridge" {
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ("splatplost-runtime-negative-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $temporary | Out-Null
    try {
        $evidencePath = Join-Path $temporary "evidence.json"
        $missingBridge = "\\.\SplatplostVerificationMissing$([Guid]::NewGuid().ToString('N'))"
        $threw = $false
        try {
            & $verifier -EvidencePath $evidencePath -BridgePath $missingBridge -RequireConnected *>&1 | Out-Null
        } catch {
            $threw = $true
        }
        Assert-True $threw "RequireConnected unexpectedly returned success."
        Assert-True (Test-Path -LiteralPath $evidencePath -PathType Leaf) "Failure evidence was not written."
        $evidence = Get-Content -LiteralPath $evidencePath -Raw | ConvertFrom-Json
        Assert-True (-not $evidence.passed) "Failure evidence was marked passed."
        Assert-True (-not $evidence.connectedReady) "Unreadable bridge was marked connected."
        Assert-True (-not $evidence.checks.bridgeInitialization.readable) "Missing bridge was marked readable."
        Assert-True (-not $evidence.checks.hidChannels.passed) "Unreadable channels were marked passed."
        Assert-True ($evidence.failures.Count -gt 0) "Failure evidence contains no reasons."
    } finally {
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($script:Failures -ne 0) {
    throw "$script:Failures runtime verifier test(s) failed."
}

Write-Host "ALL TESTS PASSED"
