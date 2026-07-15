param(
    [Parameter(Mandatory=$true)]
    [string]$PackageDirectory
)

$ErrorActionPreference = "Stop"
$package = [IO.Path]::GetFullPath($PackageDirectory)
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
