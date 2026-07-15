param(
    [switch]$EnableTestSigning
)

$ErrorActionPreference = "Stop"
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this installer from an Administrator PowerShell window."
}

if (-not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) {
    throw "The Splatplost Bluetooth installer requires a 64-bit PowerShell process on 64-bit Windows."
}
$windowsVersion = Get-ItemProperty `
    -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" `
    -ErrorAction Stop
$windowsBuild = 0
if (
    -not [int]::TryParse(
        [string]$windowsVersion.CurrentBuildNumber,
        [ref]$windowsBuild
    ) -or
    $windowsBuild -lt 19041
) {
    throw "The Splatplost Bluetooth installer requires Windows 10 version 2004 (build 19041) or newer."
}

$operationMutex = [Threading.Mutex]::new(
    $false,
    "Global\SplatplostWindowsBluetoothDriverOperation-v1"
)
$operationMutexAcquired = $false
$packagePin = $null
try {
    try {
        $operationMutexAcquired = $operationMutex.WaitOne(0)
    } catch [Threading.AbandonedMutexException] {
        $operationMutexAcquired = $true
        Write-Warning "Recovered an abandoned Splatplost driver-operation lock. Pending recovery state will still be checked."
    }
    if (-not $operationMutexAcquired) {
        throw "Another Splatplost driver install or uninstall operation is already running. Wait for it to finish and retry."
    }

$package = Split-Path -Parent $MyInvocation.MyCommand.Path
$certificate = Join-Path $package "SplatplostDevelopment.cer"
$inf = Join-Path $package "SplatplostBluetooth.inf"
$driver = Join-Path $package "SplatplostBluetooth.sys"
$catalog = Join-Path $package "SplatplostBluetooth.cat"
$buildManifestPath = Join-Path $package "SplatplostBluetooth-build-manifest.json"
$releaseManifestPath = Join-Path $package "SplatplostBluetooth-release-manifest.json"
$serviceGuid = "{f6fd1f11-2d8a-4ce4-8794-261e461e6c53}"
$hardwareId = "BTHENUM\$serviceGuid"
$bridgePath = "\\.\SplatplostBluetooth"
$stateKey = "HKLM:\SOFTWARE\Splatplost"
$pendingStateKey = "HKLM:\SOFTWARE\SplatplostDriverPendingInstall"

if (-not ("Splatplost.NativeStatus" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Splatplost
{
    public static class NativeStatus
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

        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);

        [StructLayout(LayoutKind.Sequential)]
        private struct ByHandleFileInformation
        {
            public uint FileAttributes;
            public uint CreationTimeLow;
            public uint CreationTimeHigh;
            public uint LastAccessTimeLow;
            public uint LastAccessTimeHigh;
            public uint LastWriteTimeLow;
            public uint LastWriteTimeHigh;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(
            IntPtr file,
            out ByHandleFileInformation information);

        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool SetupGetInfDriverStoreLocationW(
            string fileName,
            IntPtr alternatePlatformInfo,
            string localeName,
            StringBuilder returnBuffer,
            uint returnBufferSize,
            out uint requiredSize);

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

        public static string GetInfDriverStoreLocation(string publishedInfPath)
        {
            uint requiredSize;
            if (SetupGetInfDriverStoreLocationW(
                publishedInfPath,
                IntPtr.Zero,
                null,
                null,
                0,
                out requiredSize))
            {
                throw new InvalidOperationException(
                    "SetupGetInfDriverStoreLocationW unexpectedly accepted an empty output buffer.");
            }

            int error = Marshal.GetLastWin32Error();
            const int ERROR_INSUFFICIENT_BUFFER = 122;
            if (error != ERROR_INSUFFICIENT_BUFFER || requiredSize == 0)
            {
                throw new Win32Exception(error);
            }

            StringBuilder result = new StringBuilder(checked((int)requiredSize));
            if (!SetupGetInfDriverStoreLocationW(
                publishedInfPath,
                IntPtr.Zero,
                null,
                result,
                requiredSize,
                out requiredSize))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            return result.ToString();
        }

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

        public static uint GetSingleRadioAddress(out ulong radioAddress, out uint radioCount)
        {
            IntPtr radio;
            uint result = OpenOnlyRadio(out radio, out radioAddress, out radioCount);
            if (radio != IntPtr.Zero)
            {
                CloseHandle(radio);
            }
            return result;
        }

        public static uint SetLocalServiceEnabled(
            string serviceGuid,
            bool enabled,
            ulong expectedRadioAddress,
            out ulong actualRadioAddress,
            out uint radioCount)
        {
            const uint TOKEN_ADJUST_PRIVILEGES = 0x20;
            const uint TOKEN_QUERY = 0x08;
            const uint SE_PRIVILEGE_ENABLED = 0x02;
            const int ERROR_SUCCESS = 0;
            const int ERROR_PRIVILEGE_NOT_HELD = 1314;
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
                SetLastError(ERROR_SUCCESS);
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
                if (privilegeError != ERROR_SUCCESS)
                {
                    return unchecked((uint)(privilegeError == 0 ? ERROR_PRIVILEGE_NOT_HELD : privilegeError));
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

        public static bool IsTestSigningEnabled()
        {
            SystemCodeIntegrityInformation information = new SystemCodeIntegrityInformation();
            information.Length = (uint)Marshal.SizeOf(information);
            int returnLength;
            int status = NtQuerySystemInformation(103, ref information, (int)information.Length, out returnLength);
            if (status < 0)
            {
                throw new InvalidOperationException("Unable to read the current Windows code-integrity mode.");
            }
            return (information.CodeIntegrityOptions & 0x02) != 0;
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
                    "The package object could not be pinned for read-only sharing: " + path);
            }

            try
            {
                ByHandleFileInformation information;
                if (!GetFileInformationByHandle(rawHandle, out information))
                {
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(),
                        "The pinned package object identity could not be read: " + path);
                }
                bool isDirectory = (information.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
                bool isReparsePoint = (information.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
                if (isReparsePoint || isDirectory != requireDirectory)
                {
                    throw new IOException(
                        "The package object is an unsafe reparse point or has the wrong type: " + path);
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

        public static int ProbeBridge(
            string path,
            out uint driverStatus,
            out uint driverStage,
            out ulong localAddress)
        {
            driverStatus = 0;
            driverStage = 0;
            localAddress = 0;
            IntPtr handle = CreateFile(path, 0, 0x00000003, IntPtr.Zero, 3, 0, IntPtr.Zero);
            if (handle == new IntPtr(-1))
            {
                return Marshal.GetLastWin32Error();
            }

            byte[] statusBuffer = new byte[16];
            uint bytesReturned;
            int result = 0;
            if (!DeviceIoControl(handle, 0x00222000, IntPtr.Zero, 0, statusBuffer, (uint)statusBuffer.Length, out bytesReturned, IntPtr.Zero))
            {
                result = Marshal.GetLastWin32Error();
            }
            else if (bytesReturned < statusBuffer.Length)
            {
                result = 122; // ERROR_INSUFFICIENT_BUFFER
            }
            else
            {
                uint channelsAndStage = BitConverter.ToUInt32(statusBuffer, 0);
                driverStage = channelsAndStage >> 16;
                driverStatus = BitConverter.ToUInt32(statusBuffer, 4);
                localAddress = BitConverter.ToUInt64(statusBuffer, 8);
            }
            CloseHandle(handle);
            return result;
        }
    }
}
"@
}

function Get-SplatplostReadOnlyStreamSha256 {
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
        "splatplost-installer-signature-{0}.sys" -f [Guid]::NewGuid().ToString("N")
    )
    try {
        $sourcePin = [Splatplost.NativeStatus]::OpenPinnedPackageFile($Path)
        $sourceHash = Get-SplatplostReadOnlyStreamSha256 -Stream $sourcePin

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

        $copyPin = [Splatplost.NativeStatus]::OpenPinnedPackageFile($copy)
        $copyHash = Get-SplatplostReadOnlyStreamSha256 -Stream $copyPin
        if (
            $copyHash -ne $sourceHash -or
            (Get-SplatplostReadOnlyStreamSha256 -Stream $sourcePin) -ne $sourceHash
        ) {
            throw "The isolated signature copy does not exactly match its pinned source."
        }

        $signature = Get-AuthenticodeSignature -LiteralPath $copy
        if (
            (Get-SplatplostReadOnlyStreamSha256 -Stream $copyPin) -ne $sourceHash -or
            (Get-SplatplostReadOnlyStreamSha256 -Stream $sourcePin) -ne $sourceHash
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

function Get-CertificateEkuOids {
    param([Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)

    if (-not $Certificate) { return @() }
    return @($Certificate.Extensions |
        Where-Object { $_.Oid.Value -eq "2.5.29.37" } |
        ForEach-Object {
            $enhanced = [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]$_
            @($enhanced.EnhancedKeyUsages | ForEach-Object { $_.Value })
        })
}

function Resolve-KernelImagePath {
    param([Parameter(Mandatory = $true)][string]$ImagePath)

    $path = [Environment]::ExpandEnvironmentVariables($ImagePath.Trim().Trim('"'))
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

    # Filtering in PowerShell deliberately distinguishes a genuine no-match
    # from a PnP provider/query failure. Get-PnpDevice reports no wildcard
    # matches as a non-terminating error when -InstanceId is supplied, which
    # previously forced every error to be silenced and made failures look like
    # an empty device set.
    $presentDevices = @(Get-PnpDevice -PresentOnly -ErrorAction Stop)
    return @($presentDevices | Where-Object {
        [string]$_.InstanceId -like $InstanceIdPattern
    })
}

function Wait-SplatplostPresentDevices {
    param(
        [Parameter(Mandatory = $true)][string]$InstanceIdPattern,
        [int]$TimeoutSeconds = 30
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $devices = @(Get-SplatplostPresentDevices -InstanceIdPattern $InstanceIdPattern)
        if ($devices.Count -gt 0) { return $devices }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    return @()
}

function Get-SplatplostDeviceStates {
    param([Parameter(Mandatory = $true)][object[]]$Devices)

    return @($Devices | ForEach-Object {
        $device = $_
        $serviceProperty = Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName "DEVPKEY_Device_Service" -ErrorAction SilentlyContinue
        $problemCodeProperty = Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName "DEVPKEY_Device_ProblemCode" -ErrorAction SilentlyContinue
        $problemStatusProperty = Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName "DEVPKEY_Device_ProblemStatus" -ErrorAction SilentlyContinue
        $infProperty = Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName "DEVPKEY_Device_DriverInfPath" -ErrorAction SilentlyContinue
        [pscustomobject]@{
            Device = $device
            InstanceId = [string]$device.InstanceId
            Status = [string]$device.Status
            Service = if ($serviceProperty) { $serviceProperty.Data } else { $null }
            ProblemCode = if ($problemCodeProperty) { $problemCodeProperty.Data } else { $null }
            ProblemStatus = if ($problemStatusProperty) { $problemStatusProperty.Data } else { $null }
            DriverInfPath = if ($infProperty) { $infProperty.Data } else { $null }
        }
    })
}

function Wait-SplatplostDeviceStates {
    param(
        [Parameter(Mandatory = $true)][string]$InstanceIdPattern,
        [int]$TimeoutSeconds = 30
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $states = @()
    do {
        $states = @(Get-SplatplostDeviceStates -Devices @(Get-SplatplostPresentDevices -InstanceIdPattern $InstanceIdPattern))
        $incomplete = @($states | Where-Object {
            [string]::IsNullOrWhiteSpace([string]$_.InstanceId) -or
            [string]::IsNullOrWhiteSpace([string]$_.Status) -or
            [string]::IsNullOrWhiteSpace([string]$_.Service) -or
            $null -eq $_.ProblemCode -or
            $null -eq $_.ProblemStatus -or
            [string]::IsNullOrWhiteSpace([string]$_.DriverInfPath)
        })
        if ($states.Count -gt 0 -and $incomplete.Count -eq 0) { return $states }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    return $states
}

function Test-SplatplostPublishedInfIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$InfName,
        [Parameter(Mandatory = $true)][string]$ExpectedHardwareId
    )

    if ($InfName -notmatch '^oem\d+\.inf$') { return $false }
    $path = Join-Path (Join-Path $env:SystemRoot "INF") $InfName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    $content = Get-Content -LiteralPath $path -Raw
    return [bool](
        $content.IndexOf($ExpectedHardwareId, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        $content -match '(?im)^\s*AddService\s*=\s*SplatplostBluetooth\s*,' -and
        $content -match '(?im)^\s*ProviderString\s*=\s*"Splatplost"\s*$'
    )
}

function Get-SplatplostDriverStorePackageSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$InfName,
        [Parameter(Mandatory = $true)][string]$ExpectedHardwareId
    )

    if (-not (Test-SplatplostPublishedInfIdentity -InfName $InfName -ExpectedHardwareId $ExpectedHardwareId)) {
        throw "The published package $InfName does not have the expected Splatplost identity."
    }

    $publishedInfPath = [IO.Path]::GetFullPath((Join-Path (Join-Path $env:SystemRoot "INF") $InfName))
    $driverStoreInfPath = [IO.Path]::GetFullPath(
        [Splatplost.NativeStatus]::GetInfDriverStoreLocation($publishedInfPath)
    )
    $repositoryRoot = [IO.Path]::GetFullPath(
        (Join-Path $env:SystemRoot "System32\DriverStore\FileRepository")
    ).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $packageDirectory = [IO.Path]::GetFullPath((Split-Path -Parent $driverStoreInfPath))
    $packageParent = [IO.Path]::GetFullPath((Split-Path -Parent $packageDirectory)).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    if (-not [string]::Equals($packageParent, $repositoryRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "SetupAPI returned a driver package outside the trusted FileRepository root: $driverStoreInfPath"
    }
    if (-not (Test-Path -LiteralPath $driverStoreInfPath -PathType Leaf)) {
        throw "The prior Driver Store INF is missing: $driverStoreInfPath"
    }

    $packageDirectoryItem = Get-Item -LiteralPath $packageDirectory -Force
    if (([IO.FileAttributes]$packageDirectoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The prior Driver Store package directory is a reparse point and cannot be trusted."
    }

    $packageItems = @(Get-ChildItem -LiteralPath $packageDirectory -Recurse -Force)
    $reparseItems = @($packageItems | Where-Object {
        ([IO.FileAttributes]$_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    })
    if ($reparseItems.Count -ne 0) {
        throw "The prior Driver Store package contains a reparse point and cannot be snapshotted safely."
    }

    $directoryPrefix = $packageDirectory.TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    ) + [IO.Path]::DirectorySeparatorChar
    $files = @{}
    foreach ($file in @($packageItems | Where-Object { -not $_.PSIsContainer } | Sort-Object FullName)) {
        $fullPath = [IO.Path]::GetFullPath($file.FullName)
        if (-not $fullPath.StartsWith($directoryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "A Driver Store package file escaped its package directory: $fullPath"
        }
        $relativePath = $fullPath.Substring($directoryPrefix.Length)
        if ($files.ContainsKey($relativePath)) {
            throw "The Driver Store package contains a duplicate relative path: $relativePath"
        }
        $files[$relativePath] = [pscustomobject]@{
            Length = [int64]$file.Length
            Sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash
        }
    }
    if ($files.Count -eq 0) {
        throw "The prior Driver Store package is empty."
    }

    $publishedInfHash = (Get-FileHash -LiteralPath $publishedInfPath -Algorithm SHA256).Hash
    $driverStoreInfHash = (Get-FileHash -LiteralPath $driverStoreInfPath -Algorithm SHA256).Hash
    if ($publishedInfHash -ne $driverStoreInfHash) {
        throw "The published INF and its SetupAPI-resolved Driver Store INF do not match."
    }

    return [pscustomobject]@{
        PublishedInfName = $InfName.ToLowerInvariant()
        PublishedInfPath = $publishedInfPath
        PublishedInfSha256 = $publishedInfHash
        DriverStoreInfPath = $driverStoreInfPath
        DriverStoreInfSha256 = $driverStoreInfHash
        Files = $files
    }
}

function Compare-SplatplostDeviceSnapshot {
    param(
        [Parameter(Mandatory = $true)][object[]]$Expected,
        [Parameter(Mandatory = $true)][object[]]$Actual
    )

    $errors = @()
    $expectedByInstance = @{}
    $actualByInstance = @{}
    foreach ($state in @($Expected)) {
        $instanceId = [string]$state.InstanceId
        if ([string]::IsNullOrWhiteSpace($instanceId) -or $expectedByInstance.ContainsKey($instanceId)) {
            $errors += "The pre-install device snapshot contains a missing or duplicate instance ID."
            continue
        }
        $expectedByInstance[$instanceId] = $state
    }
    foreach ($state in @($Actual)) {
        $instanceId = [string]$state.InstanceId
        if ([string]::IsNullOrWhiteSpace($instanceId) -or $actualByInstance.ContainsKey($instanceId)) {
            $errors += "The rollback device state contains a missing or duplicate instance ID."
            continue
        }
        $actualByInstance[$instanceId] = $state
    }
    if ($Expected.Count -ne $Actual.Count -or $expectedByInstance.Count -ne $actualByInstance.Count) {
        $errors += "The present device instance count after rollback does not match the pre-install snapshot."
    }

    foreach ($instanceId in @($expectedByInstance.Keys)) {
        if (-not $actualByInstance.ContainsKey($instanceId)) {
            $errors += "The prior present device instance was not restored: $instanceId"
            continue
        }
        $before = $expectedByInstance[$instanceId]
        $after = $actualByInstance[$instanceId]
        if (
            [string]::IsNullOrWhiteSpace([string]$after.Status) -or
            [string]::IsNullOrWhiteSpace([string]$after.Service) -or
            $null -eq $after.ProblemCode -or
            $null -eq $after.ProblemStatus -or
            [string]::IsNullOrWhiteSpace([string]$after.DriverInfPath)
        ) {
            $errors += "The rollback state is incomplete for device $instanceId."
        }
        if (-not [string]::Equals([string]$before.Service, [string]$after.Service, [StringComparison]::OrdinalIgnoreCase)) {
            $errors += "The service binding after rollback differs for device $instanceId."
        }
        if (-not [string]::Equals([string]$before.DriverInfPath, [string]$after.DriverInfPath, [StringComparison]::OrdinalIgnoreCase)) {
            $errors += "The active INF after rollback differs for device $instanceId."
        }
        if ([int]$before.ProblemCode -ne [int]$after.ProblemCode) {
            $errors += "The PnP problem code after rollback differs for device $instanceId."
        }
        if ([uint32]$before.ProblemStatus -ne [uint32]$after.ProblemStatus) {
            $errors += "The PnP problem status after rollback differs for device $instanceId."
        }
        if (-not [string]::Equals([string]$before.Status, [string]$after.Status, [StringComparison]::OrdinalIgnoreCase)) {
            $errors += "The device status after rollback differs for device $instanceId."
        }
    }
    foreach ($instanceId in @($actualByInstance.Keys)) {
        if (-not $expectedByInstance.ContainsKey($instanceId)) {
            $errors += "An unexpected present device instance exists after rollback: $instanceId"
        }
    }

    return [pscustomobject]@{
        Verified = $errors.Count -eq 0
        Errors = $errors
    }
}

function Wait-SplatplostBindingSnapshotRestored {
    param(
        [Parameter(Mandatory = $true)][object[]]$ExpectedDevices,
        [Parameter(Mandatory = $true)][string]$InstanceIdPattern,
        [int]$TimeoutSeconds = 30
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $states = @()
    $comparison = [pscustomobject]@{
        Verified = $false
        Errors = @("The rollback device state has not been observed yet.")
    }
    do {
        $states = @(Get-SplatplostDeviceStates -Devices @(
            Get-SplatplostPresentDevices -InstanceIdPattern $InstanceIdPattern
        ))
        $comparison = Compare-SplatplostDeviceSnapshot `
            -Expected $ExpectedDevices `
            -Actual $states
        if ($comparison.Verified) {
            return [pscustomobject]@{
                Verified = $true
                Errors = @()
                States = $states
            }
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)

    return [pscustomobject]@{
        Verified = $false
        Errors = @($comparison.Errors)
        States = $states
    }
}

function Test-SplatplostDriverStorePackageSnapshotsEqual {
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Actual
    )

    if (-not [string]::Equals(
        [string]$Expected.PublishedInfName,
        [string]$Actual.PublishedInfName,
        [StringComparison]::OrdinalIgnoreCase
    )) { return $false }
    if (-not [string]::Equals(
        [string]$Expected.DriverStoreInfPath,
        [string]$Actual.DriverStoreInfPath,
        [StringComparison]::OrdinalIgnoreCase
    )) { return $false }
    if (
        [string]$Expected.PublishedInfSha256 -ne [string]$Actual.PublishedInfSha256 -or
        [string]$Expected.DriverStoreInfSha256 -ne [string]$Actual.DriverStoreInfSha256 -or
        $Expected.Files.Count -ne $Actual.Files.Count
    ) { return $false }
    foreach ($relativePath in @($Expected.Files.Keys)) {
        if (-not $Actual.Files.ContainsKey($relativePath)) { return $false }
        if (
            [int64]$Expected.Files[$relativePath].Length -ne [int64]$Actual.Files[$relativePath].Length -or
            [string]$Expected.Files[$relativePath].Sha256 -ne [string]$Actual.Files[$relativePath].Sha256
        ) { return $false }
    }
    return $true
}

function Test-SplatplostDriverStorePackageUnchanged {
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)][string]$ExpectedHardwareId
    )

    $actual = Get-SplatplostDriverStorePackageSnapshot `
        -InfName ([string]$Expected.PublishedInfName) `
        -ExpectedHardwareId $ExpectedHardwareId
    return Test-SplatplostDriverStorePackageSnapshotsEqual `
        -Expected $Expected `
        -Actual $actual
}

function Get-SplatplostPublishedPackageInventory {
    param([Parameter(Mandatory = $true)][string]$ExpectedHardwareId)

    $inventory = @{}
    $infRoot = Join-Path $env:SystemRoot "INF"
    foreach ($publishedInf in @(Get-ChildItem -LiteralPath $infRoot -Filter "oem*.inf" -File -Force)) {
        $name = $publishedInf.Name.ToLowerInvariant()
        if (-not (Test-SplatplostPublishedInfIdentity -InfName $name -ExpectedHardwareId $ExpectedHardwareId)) {
            continue
        }
        if ($inventory.ContainsKey($name)) {
            throw "The published Splatplost package inventory contains a duplicate name: $name"
        }
        $inventory[$name] = Get-SplatplostDriverStorePackageSnapshot `
            -InfName $name `
            -ExpectedHardwareId $ExpectedHardwareId
    }
    return $inventory
}

function Test-SplatplostInstallingPackageIdentity {
    param(
        [Parameter(Mandatory = $true)]$PackageSnapshot,
        [Parameter(Mandatory = $true)][string]$ExpectedInfSha256,
        [Parameter(Mandatory = $true)][string]$ExpectedDriverSha256
    )

    if ([string]$PackageSnapshot.PublishedInfSha256 -ne $ExpectedInfSha256) {
        return $false
    }
    $driverFiles = @($PackageSnapshot.Files.Keys | Where-Object {
        [IO.Path]::GetFileName([string]$_) -ieq "SplatplostBluetooth.sys"
    })
    if ($driverFiles.Count -ne 1) { return $false }
    return [string]$PackageSnapshot.Files[$driverFiles[0]].Sha256 -eq $ExpectedDriverSha256
}

function Compare-SplatplostPublishedPackageInventory {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Expected,
        [Parameter(Mandatory = $true)][hashtable]$Actual
    )

    $errors = @()
    if ($Expected.Count -ne $Actual.Count) {
        $errors += "The published Splatplost Driver Store package count changed during rollback."
    }
    foreach ($name in @($Expected.Keys)) {
        if (-not $Actual.ContainsKey($name)) {
            $errors += "A pre-existing published Splatplost package was not restored: $name"
            continue
        }
        if (-not (Test-SplatplostDriverStorePackageSnapshotsEqual `
            -Expected $Expected[$name] `
            -Actual $Actual[$name])) {
            $errors += "The pre-existing published Splatplost package changed: $name"
        }
    }
    foreach ($name in @($Actual.Keys)) {
        if (-not $Expected.ContainsKey($name)) {
            $errors += "A newly published Splatplost package remains after rollback: $name"
        }
    }
    return [pscustomobject]@{
        Verified = $errors.Count -eq 0
        Errors = $errors
    }
}

function Get-SplatplostBindingSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$InstanceIdPattern,
        [Parameter(Mandatory = $true)][string]$ExpectedHardwareId
    )

    $devices = @(Get-SplatplostPresentDevices -InstanceIdPattern $InstanceIdPattern)
    if ($devices.Count -eq 0) {
        return [pscustomobject]@{
            Devices = @()
            InfNames = @()
            Packages = @{}
            DriverPath = $null
            DriverSha256 = $null
        }
    }
    $states = @(Wait-SplatplostDeviceStates -InstanceIdPattern $InstanceIdPattern -TimeoutSeconds 10)
    if ($states.Count -ne $devices.Count) {
        throw "The existing Splatplost binding could not be snapshotted safely before installation."
    }

    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $packages = @{}
    $deviceSnapshot = @()
    foreach ($state in $states) {
        $name = ([string]$state.DriverInfPath).ToLowerInvariant()
        if (
            [string]::IsNullOrWhiteSpace([string]$state.InstanceId) -or
            $state.Service -ine "SplatplostBluetooth" -or
            $null -eq $state.ProblemCode -or
            [int]$state.ProblemCode -ne 0 -or
            $null -eq $state.ProblemStatus -or
            [uint32]$state.ProblemStatus -ne 0 -or
            $state.Status -ine "OK" -or
            -not (Test-SplatplostPublishedInfIdentity -InfName $name -ExpectedHardwareId $ExpectedHardwareId)
        ) {
            throw "The existing Splatplost PnP binding is not healthy or has an unverified service/INF identity. Restart or uninstall it before installing this package."
        }
        [void]$names.Add($name)
        $deviceSnapshot += [pscustomobject]@{
            InstanceId = [string]$state.InstanceId
            Status = [string]$state.Status
            Service = [string]$state.Service
            ProblemCode = [int]$state.ProblemCode
            ProblemStatus = [uint32]$state.ProblemStatus
            DriverInfPath = $name
        }
    }
    foreach ($name in @($names)) {
        $packages[$name] = Get-SplatplostDriverStorePackageSnapshot `
            -InfName $name `
            -ExpectedHardwareId $ExpectedHardwareId
    }

    $driverPath = $null
    $driverHash = $null
    $serviceKey = "HKLM:\SYSTEM\CurrentControlSet\Services\SplatplostBluetooth"
    if (Test-Path -LiteralPath $serviceKey) {
        $imagePath = (Get-ItemProperty -LiteralPath $serviceKey -Name ImagePath -ErrorAction Stop).ImagePath
        $driverPath = Resolve-KernelImagePath -ImagePath ([string]$imagePath)
        if (-not (Test-Path -LiteralPath $driverPath -PathType Leaf)) {
            throw "The existing Splatplost service binary is missing: $driverPath"
        }
        $driverHash = (Get-FileHash -LiteralPath $driverPath -Algorithm SHA256).Hash
    }
    return [pscustomobject]@{
        Devices = @($deviceSnapshot | Sort-Object InstanceId)
        InfNames = @($names)
        Packages = $packages
        DriverPath = $driverPath
        DriverSha256 = $driverHash
    }
}

function Restore-SplatplostBindingSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)][hashtable]$PriorPublishedPackages,
        [Parameter(Mandatory = $true)][string]$InstanceIdPattern,
        [Parameter(Mandatory = $true)][string]$ExpectedHardwareId,
        [Parameter(Mandatory = $true)][string]$InstallingInfSha256,
        [Parameter(Mandatory = $true)][string]$InstallingDriverSha256
    )

    $errors = @()
    $priorNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @($Snapshot.InfNames)) { [void]$priorNames.Add([string]$name) }

    $currentPublishedPackages = Get-SplatplostPublishedPackageInventory `
        -ExpectedHardwareId $ExpectedHardwareId
    foreach ($name in @($currentPublishedPackages.Keys)) {
        if ($PriorPublishedPackages.ContainsKey($name)) {
            if (-not (Test-SplatplostDriverStorePackageSnapshotsEqual `
                -Expected $PriorPublishedPackages[$name] `
                -Actual $currentPublishedPackages[$name])) {
                $errors += "A pre-existing published package was replaced during installation: $name"
            }
            continue
        }
        if (-not (Test-SplatplostInstallingPackageIdentity `
            -PackageSnapshot $currentPublishedPackages[$name] `
            -ExpectedInfSha256 $InstallingInfSha256 `
            -ExpectedDriverSha256 $InstallingDriverSha256)) {
            $errors += "Refusing to remove post-snapshot package $name because it does not match the exact package being installed."
            continue
        }
        & "$env:SystemRoot\System32\pnputil.exe" /delete-driver $name /uninstall /force | Out-Host
        if ($LASTEXITCODE -in @(3010, 1641)) {
            $errors += "Removing newly bound package $name requires a restart, so rollback is not yet proven."
        } elseif ($LASTEXITCODE -ne 0) {
            $errors += "PnPUtil could not remove newly bound package $name (exit code $LASTEXITCODE)."
        }
    }

    foreach ($name in @($priorNames)) {
        if (-not $Snapshot.Packages.ContainsKey($name)) {
            $errors += "The prior package snapshot is missing $name."
            continue
        }
        $priorPackage = $Snapshot.Packages[$name]
        try {
            if (-not (Test-SplatplostDriverStorePackageUnchanged `
                -Expected $priorPackage `
                -ExpectedHardwareId $ExpectedHardwareId)) {
                $errors += "The prior Driver Store package $name changed after the pre-install snapshot."
                continue
            }
        } catch {
            $errors += "The prior Driver Store package $name could not be verified: $($_.Exception.Message)"
            continue
        }
        $priorInfPath = [string]$priorPackage.DriverStoreInfPath
        & "$env:SystemRoot\System32\pnputil.exe" /add-driver $priorInfPath /install | Out-Host
        if ($LASTEXITCODE -in @(3010, 1641)) {
            $errors += "Rebinding prior package $name requires a restart, so rollback is not yet proven."
        } elseif ($LASTEXITCODE -notin @(0, 259)) {
            $errors += "PnPUtil could not rebind prior package $name (exit code $LASTEXITCODE)."
        }
    }

    & "$env:SystemRoot\System32\pnputil.exe" /scan-devices | Out-Host
    if ($LASTEXITCODE -in @(3010, 1641)) {
        $errors += "The rollback device rescan requires a restart, so rollback is not yet proven."
    } elseif ($LASTEXITCODE -ne 0) {
        $errors += "PnPUtil could not rescan devices during binding rollback (exit code $LASTEXITCODE)."
    }

    $settledBinding = Wait-SplatplostBindingSnapshotRestored `
        -ExpectedDevices @($Snapshot.Devices) `
        -InstanceIdPattern $InstanceIdPattern `
        -TimeoutSeconds 30
    $finalStates = @($settledBinding.States)
    $finalNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($state in $finalStates) {
        if ([string]$state.DriverInfPath -match '^oem\d+\.inf$') {
            [void]$finalNames.Add(([string]$state.DriverInfPath).ToLowerInvariant())
        }
    }
    if (-not $settledBinding.Verified) {
        $errors += @($settledBinding.Errors)
    }

    try {
        $finalPublishedPackages = Get-SplatplostPublishedPackageInventory `
            -ExpectedHardwareId $ExpectedHardwareId
        $packageComparison = Compare-SplatplostPublishedPackageInventory `
            -Expected $PriorPublishedPackages `
            -Actual $finalPublishedPackages
        if (-not $packageComparison.Verified) {
            $errors += @($packageComparison.Errors)
        }
    } catch {
        $errors += "The complete published package inventory could not be verified after rollback: $($_.Exception.Message)"
    }

    foreach ($name in @($priorNames)) {
        try {
            if (-not $Snapshot.Packages.ContainsKey($name) -or -not (Test-SplatplostDriverStorePackageUnchanged `
                -Expected $Snapshot.Packages[$name] `
                -ExpectedHardwareId $ExpectedHardwareId)) {
                $errors += "The prior Driver Store package $name does not match after rollback."
            }
        } catch {
            $errors += "The prior Driver Store package $name could not be verified after rollback: $($_.Exception.Message)"
        }
    }

    if ($Snapshot.DriverSha256) {
        try {
            $imagePath = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\SplatplostBluetooth" -Name ImagePath -ErrorAction Stop).ImagePath
            $currentDriverPath = Resolve-KernelImagePath -ImagePath ([string]$imagePath)
            $currentHash = (Get-FileHash -LiteralPath $currentDriverPath -Algorithm SHA256).Hash
            if (
                -not [string]::Equals($currentDriverPath, [string]$Snapshot.DriverPath, [StringComparison]::OrdinalIgnoreCase) -or
                $currentHash -ne [string]$Snapshot.DriverSha256
            ) {
                $errors += "The service binary after rollback does not match the pre-install snapshot."
            }
        } catch {
            $errors += "The service binary could not be verified after rollback: $($_.Exception.Message)"
        }
    }

    return [pscustomobject]@{
        Verified = $errors.Count -eq 0
        Errors = $errors
        ActiveInfNames = @($finalNames)
    }
}

function Add-OwnedDevelopmentCertificateRecord {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Records,
        [Parameter(Mandatory = $true)][string]$Thumbprint,
        [bool]$RootOwned,
        [bool]$PublisherOwned
    )

    if ($Thumbprint -notmatch '^[0-9A-Fa-f]{40,64}$') {
        return
    }
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

function Get-SplatplostCodRollbackDecision {
    param(
        [Parameter(Mandatory = $true)]$SnapshotProperties,
        [Parameter(Mandatory = $true)]$CurrentProperties,
        [Parameter(Mandatory = $true)][string]$RegistryValueName,
        [Parameter(Mandatory = $true)][int]$ManagedValue
    )

    $snapshotProperty = $SnapshotProperties.PSObject.Properties[$RegistryValueName]
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
        Action = if ($snapshotProperty) { "restore" } else { "remove" }
        RegistryValueName = $RegistryValueName
        SnapshotValue = if ($snapshotProperty) { $snapshotProperty.Value } else { $null }
        CurrentValue = $currentProperty.Value
    }
}

function Get-OwnedDevelopmentCertificateRecords {
    param([Parameter(Mandatory = $true)]$ExistingState)

    $records = @{}
    $ownedProperty = $ExistingState.PSObject.Properties['OwnedDevelopmentCertificates']
    if ($ownedProperty) {
        foreach ($record in @($ownedProperty.Value)) {
            if ([string]$record -match '^(?<thumbprint>[0-9A-Fa-f]{40,64})\|(?<root>[01])\|(?<publisher>[01])$') {
                Add-OwnedDevelopmentCertificateRecord `
                    -Records $records `
                    -Thumbprint $Matches.thumbprint `
                    -RootOwned ([bool][int]$Matches.root) `
                    -PublisherOwned ([bool][int]$Matches.publisher)
            }
        }
    }

    # Migrate state written by releases that tracked only one certificate.
    $legacyThumbprint = $ExistingState.PSObject.Properties['DevelopmentCertificateThumbprint']
    if ($legacyThumbprint) {
        $legacyRoot = $ExistingState.PSObject.Properties['DevelopmentCertificateAddedToRoot']
        $legacyPublisher = $ExistingState.PSObject.Properties['DevelopmentCertificateAddedToTrustedPublisher']
        Add-OwnedDevelopmentCertificateRecord `
            -Records $records `
            -Thumbprint ([string]$legacyThumbprint.Value) `
            -RootOwned ([bool]($legacyRoot -and $legacyRoot.Value)) `
            -PublisherOwned ([bool]($legacyPublisher -and $legacyPublisher.Value))
    }
    return $records
}

function Remove-CertificateAddedByThisRun {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
    } catch {
        return "$Description could not be removed: $($_.Exception.Message)"
    }
    if (Test-Path -LiteralPath $Path) {
        return "$Description is still present after removal: $Path"
    }
    return $null
}

function Add-ExactCertificateToOpenedStore {
    param(
        [Parameter(Mandatory = $true)]$Certificate,
        [Parameter(Mandatory = $true)]$Store
    )

    $thumbprint = [string]$Certificate.Thumbprint
    if ($thumbprint -notmatch '^[0-9A-Fa-f]{40,64}$') {
        throw "The validated development certificate has an invalid thumbprint."
    }
    $expectedRawData = [Convert]::ToBase64String([byte[]]$Certificate.RawData)
    $matchingBefore = @($Store.Certificates | Where-Object {
        [string]::Equals(
            [string]$_.Thumbprint,
            $thumbprint,
            [StringComparison]::OrdinalIgnoreCase
        )
    })
    if ($matchingBefore.Count -ne 0) {
        if (
            $matchingBefore.Count -ne 1 -or
            [Convert]::ToBase64String([byte[]]$matchingBefore[0].RawData) -ne $expectedRawData
        ) {
            throw "The target certificate store contains an ambiguous or mismatched certificate for thumbprint $thumbprint."
        }
        return $false
    }

    [void]$Store.Add($Certificate)
    $matchingAfter = @($Store.Certificates | Where-Object {
        [string]::Equals(
            [string]$_.Thumbprint,
            $thumbprint,
            [StringComparison]::OrdinalIgnoreCase
        )
    })
    if (
        $matchingAfter.Count -ne 1 -or
        [Convert]::ToBase64String([byte[]]$matchingAfter[0].RawData) -ne $expectedRawData
    ) {
        throw "The exact validated development certificate was not present after the store add operation."
    }
    return $true
}

function Add-ExactCertificateToLocalMachineStore {
    param(
        [Parameter(Mandatory = $true)][Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [Parameter(Mandatory = $true)][Security.Cryptography.X509Certificates.StoreName]$StoreName
    )

    if ($StoreName -notin @(
        [Security.Cryptography.X509Certificates.StoreName]::Root,
        [Security.Cryptography.X509Certificates.StoreName]::TrustedPublisher
    )) {
        throw "Development trust may be added only to LocalMachine Root or TrustedPublisher."
    }

    $store = [Security.Cryptography.X509Certificates.X509Store]::new(
        $StoreName,
        [Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine
    )
    try {
        [Security.Cryptography.X509Certificates.OpenFlags]$openFlags =
            [Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite -bor
            [Security.Cryptography.X509Certificates.OpenFlags]::OpenExistingOnly
        $store.Open($openFlags)
        return Add-ExactCertificateToOpenedStore -Certificate $Certificate -Store $store
    } finally {
        $store.Close()
    }
}

function New-SplatplostPendingInstallJournal {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$InfSha256,
        [Parameter(Mandatory = $true)][string]$DriverSha256,
        [Parameter(Mandatory = $true)][hashtable]$PriorPublishedPackages,
        [Parameter(Mandatory = $true)][bool]$HadManagedState,
        [Parameter(Mandatory = $true)][int]$PriorBindingDeviceCount,
        [Parameter(Mandatory = $true)][uint64]$TargetRadioAddress,
        [string]$DevelopmentCertificateThumbprint = "",
        [bool]$CertificateRootExistedBefore = $true,
        [bool]$CertificatePublisherExistedBefore = $true
    )

    if (Test-Path -LiteralPath $Path) {
        throw "A pending Splatplost driver transaction already exists. Run uninstall-driver.cmd before retrying."
    }
    New-Item -Path $Path -Force | Out-Null
    try {
        [string[]]$priorIdentities = @($PriorPublishedPackages.Keys | Sort-Object | ForEach-Object {
            $snapshot = $PriorPublishedPackages[$_]
            "$_|$([string]$snapshot.PublishedInfSha256)|$([string]$snapshot.DriverStoreInfSha256)"
        })
        New-ItemProperty -Path $Path -Name "JournalVersion" -PropertyType DWord -Value 1 -Force | Out-Null
        New-ItemProperty -Path $Path -Name "TransactionId" -PropertyType String -Value ([Guid]::NewGuid().ToString("D")) -Force | Out-Null
        New-ItemProperty -Path $Path -Name "StartedAtUtc" -PropertyType String -Value ([DateTime]::UtcNow.ToString("o", [Globalization.CultureInfo]::InvariantCulture)) -Force | Out-Null
        New-ItemProperty -Path $Path -Name "Phase" -PropertyType String -Value "prepared" -Force | Out-Null
        New-ItemProperty -Path $Path -Name "InstallingInfSha256" -PropertyType String -Value $InfSha256 -Force | Out-Null
        New-ItemProperty -Path $Path -Name "InstallingDriverSha256" -PropertyType String -Value $DriverSha256 -Force | Out-Null
        New-ItemProperty -Path $Path -Name "HadManagedState" -PropertyType DWord -Value ([int]$HadManagedState) -Force | Out-Null
        New-ItemProperty -Path $Path -Name "PriorBindingDeviceCount" -PropertyType DWord -Value $PriorBindingDeviceCount -Force | Out-Null
        New-ItemProperty -Path $Path -Name "TargetRadioAddress" -PropertyType QWord -Value $TargetRadioAddress -Force | Out-Null
        New-ItemProperty -Path $Path -Name "DevelopmentCertificateThumbprint" -PropertyType String -Value $DevelopmentCertificateThumbprint -Force | Out-Null
        New-ItemProperty -Path $Path -Name "CertificateRootExistedBefore" -PropertyType DWord -Value ([int]$CertificateRootExistedBefore) -Force | Out-Null
        New-ItemProperty -Path $Path -Name "CertificatePublisherExistedBefore" -PropertyType DWord -Value ([int]$CertificatePublisherExistedBefore) -Force | Out-Null
        if ($priorIdentities.Count -gt 0) {
            New-ItemProperty -Path $Path -Name "PriorPublishedPackageIdentities" -PropertyType MultiString -Value $priorIdentities -Force | Out-Null
        }
    } catch {
        throw "The durable pending-install journal could not be initialized completely. Run uninstall-driver.cmd before retrying. $($_.Exception.Message)"
    }
}

function Set-SplatplostPendingInstallPhase {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Phase
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "The durable pending-install journal disappeared during installation."
    }
    New-ItemProperty -Path $Path -Name "Phase" -PropertyType String -Value $Phase -Force | Out-Null
}

function Assert-SplatplostPackagePathIsLocalAndUnaliased {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    if ($fullPath -match '^\\\\') {
        throw "The driver package must be extracted to a local Windows drive before installation."
    }
    $root = [IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw "The driver package path is not an absolute local path."
    }

    $current = $root
    foreach ($segment in @($fullPath.Substring($root.Length) -split '[\\/]' | Where-Object { $_ })) {
        $current = Join-Path $current $segment
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "The driver package path contains a junction, symbolic link, or other reparse point: $current"
        }
    }
    return $fullPath
}

function Get-SplatplostPinnedStreamSha256 {
    param([Parameter(Mandatory = $true)][IO.FileStream]$Stream)

    if (-not $Stream.CanRead -or -not $Stream.CanSeek) {
        throw "A pinned package file stream is not readable and seekable."
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

function Get-SplatplostPinnedPackageSnapshot {
    param([Parameter(Mandatory = $true)]$PackagePin)

    $snapshot = @{}
    foreach ($name in @($PackagePin.Records.Keys | Sort-Object)) {
        $record = $PackagePin.Records[$name]
        $exists = Test-Path -LiteralPath $record.Path
        if (-not $exists) {
            $snapshot[$name] = [pscustomobject]@{
                Present = $false
                Length = [long]0
                Sha256 = ""
            }
            continue
        }
        if (-not (Test-Path -LiteralPath $record.Path -PathType Leaf)) {
            throw "The package changed while pinned: '$name' is no longer a regular file."
        }
        $item = Get-Item -LiteralPath $record.Path -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "The package changed while pinned: '$name' became a reparse point."
        }
        $snapshot[$name] = [pscustomobject]@{
            Present = $true
            Length = [long]$item.Length
            Sha256 = [string](Get-FileHash -LiteralPath $record.Path -Algorithm SHA256).Hash
        }
    }
    return $snapshot
}

function Assert-SplatplostPinnedPackageSnapshot {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Expected,
        [Parameter(Mandatory = $true)][hashtable]$Actual,
        [Parameter(Mandatory = $true)][string]$Checkpoint
    )

    if ($Expected.Count -ne $Actual.Count) {
        throw "The package changed while pinned at $Checkpoint (file-set size changed)."
    }
    foreach ($name in @($Expected.Keys | Sort-Object)) {
        if (-not $Actual.ContainsKey($name)) {
            throw "The package changed while pinned at $Checkpoint (missing snapshot entry '$name')."
        }
        $expectedRecord = $Expected[$name]
        $actualRecord = $Actual[$name]
        if (
            [bool]$expectedRecord.Present -ne [bool]$actualRecord.Present -or
            [long]$expectedRecord.Length -ne [long]$actualRecord.Length -or
            -not [string]::Equals(
                [string]$expectedRecord.Sha256,
                [string]$actualRecord.Sha256,
                [StringComparison]::OrdinalIgnoreCase
            )
        ) {
            throw "The package changed while pinned at $Checkpoint (identity mismatch for '$name')."
        }
    }
}

function Close-SplatplostPackagePin {
    param([Parameter(Mandatory = $true)]$PackagePin)

    foreach ($handle in @($PackagePin.Handles)) {
        if ($null -ne $handle) {
            $handle.Dispose()
        }
    }
    $PackagePin.Handles.Clear()
}

function New-SplatplostPackagePin {
    param(
        [Parameter(Mandatory = $true)][string]$PackageDirectory,
        [Parameter(Mandatory = $true)][string[]]$RequiredNames,
        [Parameter(Mandatory = $true)][string[]]$OptionalNames
    )

    $fullPackageDirectory = Assert-SplatplostPackagePathIsLocalAndUnaliased -Path $PackageDirectory
    $records = @{}
    $baseline = @{}
    $handles = [Collections.Generic.List[IDisposable]]::new()
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    try {
        $directoryHandle = [Splatplost.NativeStatus]::OpenPinnedPackageDirectory($fullPackageDirectory)
        [void]$handles.Add($directoryHandle)

        foreach ($definition in @(
            @($RequiredNames | ForEach-Object { [pscustomobject]@{ Name = [string]$_; Required = $true } }) +
            @($OptionalNames | ForEach-Object { [pscustomobject]@{ Name = [string]$_; Required = $false } })
        )) {
            $name = $definition.Name
            if ($name -notmatch '^[A-Za-z0-9_.-]+$' -or -not $names.Add($name)) {
                throw "The package pin contains an unsafe or duplicate file name: '$name'."
            }
            $path = Join-Path $fullPackageDirectory $name
            $exists = Test-Path -LiteralPath $path
            if ($exists -and -not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "The package object '$name' is not a regular file."
            }
            if (-not $exists) {
                if ([bool]$definition.Required) {
                    throw "The required package file '$name' is missing. Extract the complete Windows release ZIP."
                }
                $record = [pscustomobject]@{
                    Path = $path
                    Required = $false
                    Present = $false
                }
                $records[$name] = $record
                $baseline[$name] = [pscustomobject]@{
                    Present = $false
                    Length = [long]0
                    Sha256 = ""
                }
                continue
            }

            $stream = [Splatplost.NativeStatus]::OpenPinnedPackageFile($path)
            [void]$handles.Add($stream)
            $record = [pscustomobject]@{
                Path = $path
                Required = [bool]$definition.Required
                Present = $true
            }
            $records[$name] = $record
            $baseline[$name] = [pscustomobject]@{
                Present = $true
                Length = [long]$stream.Length
                Sha256 = [string](Get-SplatplostPinnedStreamSha256 -Stream $stream)
            }
        }

        $packagePin = [pscustomobject]@{
            PackageDirectory = $fullPackageDirectory
            Records = $records
            Handles = $handles
            InitialSnapshot = $null
        }
        $initialSnapshot = Get-SplatplostPinnedPackageSnapshot -PackagePin $packagePin
        Assert-SplatplostPinnedPackageSnapshot `
            -Expected $baseline `
            -Actual $initialSnapshot `
            -Checkpoint "pin acquisition"
        $packagePin.InitialSnapshot = $initialSnapshot
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

function Confirm-MicrosoftReleaseManifest {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$PackageDirectory
    )

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "The Microsoft-signed package is missing SplatplostBluetooth-release-manifest.json. Assemble the exact Partner Center result with assemble-signed-release.ps1."
    }
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    if ([int]$manifest.schemaVersion -ne 1 -or -not $manifest.files) {
        throw "The Microsoft-signed release manifest is invalid or unsupported."
    }

    $recordedNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($manifest.files)) {
        $name = [string]$entry.name
        $expectedHash = [string]$entry.sha256
        if ($name -notmatch '^[A-Za-z0-9_.-]+$' -or $expectedHash -notmatch '^[0-9A-Fa-f]{64}$') {
            throw "The Microsoft-signed release manifest contains an unsafe or invalid entry."
        }
        if (-not $recordedNames.Add($name)) {
            throw "The Microsoft-signed release manifest contains a duplicate entry for '$name'."
        }
        $path = Join-Path $PackageDirectory $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "The Microsoft-signed release package is missing the recorded file '$name'."
        }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $expectedHash) {
            throw "The Microsoft-signed release file '$name' does not match its assembly manifest."
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
            throw "The Microsoft-signed release manifest does not bind required file '$requiredName'."
        }
    }

    $unexpectedFiles = @(Get-ChildItem -LiteralPath $PackageDirectory -File -Force | Where-Object {
        $_.Name -ne [IO.Path]::GetFileName($ManifestPath) -and
        $_.Name -ne "SplatplostBluetooth-runtime-evidence.json" -and
        -not $recordedNames.Contains($_.Name)
    })
    if ($unexpectedFiles.Count -ne 0) {
        throw "The Microsoft-signed release folder contains unrecorded files: $($unexpectedFiles.Name -join ', ')"
    }
    return $manifest
}

$requiredPackageFiles = @($inf, $driver, $catalog, $buildManifestPath)
if (@($requiredPackageFiles | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }).Count -ne 0) {
    throw "The driver package is incomplete. Extract the complete Windows release ZIP and try again."
}
$packagePin = New-SplatplostPackagePin `
    -PackageDirectory $package `
    -RequiredNames @(
        "SplatplostBluetooth.inf",
        "SplatplostBluetooth.sys",
        "SplatplostBluetooth.cat",
        "SplatplostBluetooth-build-manifest.json",
        "install-driver.ps1",
        "install-driver.cmd",
        "uninstall-driver.ps1",
        "uninstall-driver.cmd",
        "verify-runtime.ps1",
        "THIRD_PARTY_NOTICES.md"
    ) `
    -OptionalNames @(
        "SplatplostBluetooth-release-manifest.json",
        "SplatplostBluetooth-signature-evidence.json",
        "SplatplostDevelopment.cer"
    )
$pinnedInitialPackageSnapshot = $packagePin.InitialSnapshot
$hasPinnedDevelopmentCertificate = [bool]$packagePin.Records["SplatplostDevelopment.cer"].Present
if (Test-Path -LiteralPath $pendingStateKey) {
    throw "A previous Splatplost installation was interrupted and left a durable recovery journal. Run uninstall-driver.cmd before installing another package."
}

# A managed installation with no present PDO cannot be rolled back exactly if an
# upgrade fails. Stop before importing trust, staging a package, or changing the
# Bluetooth profile. Recovery state likewise requires deterministic uninstall.
if (Test-Path -LiteralPath $stateKey) {
    $preflightState = Get-ItemProperty -LiteralPath $stateKey -ErrorAction Stop
    $preflightInstallationKind = $preflightState.PSObject.Properties['InstallationKind']
    if (
        $preflightInstallationKind -and
        [string]$preflightInstallationKind.Value -in @("recovery-required", "uninstall-reboot-required")
    ) {
        throw "A previous installation or removal has recovery-required state. Restart if requested, then run uninstall-driver.cmd before installing another package."
    }
    if (@(Get-SplatplostPresentDevices -InstanceIdPattern "$hardwareId*").Count -eq 0) {
        throw "A prior Splatplost installation is recorded, but no present device binding can be snapshotted. Enable the Bluetooth radio and restart, or run uninstall-driver.cmd before upgrading."
    }
}

$buildManifest = Get-Content -LiteralPath $buildManifestPath -Raw | ConvertFrom-Json
if ([int]$buildManifest.schemaVersion -ne 1 -or -not $buildManifest.files) {
    throw "The driver build manifest is invalid or unsupported."
}
foreach ($supportName in @(
    "SplatplostBluetooth.inf",
    "install-driver.ps1",
    "install-driver.cmd",
    "uninstall-driver.ps1",
    "uninstall-driver.cmd",
    "verify-runtime.ps1",
    "THIRD_PARTY_NOTICES.md"
)) {
    $entries = @($buildManifest.files | Where-Object { $_.name -eq $supportName })
    $supportPath = Join-Path $package $supportName
    if (
        $entries.Count -ne 1 -or
        [string]$entries[0].sha256 -notmatch '^[0-9a-fA-F]{64}$' -or
        -not (Test-Path -LiteralPath $supportPath -PathType Leaf) -or
        (Get-FileHash -LiteralPath $supportPath -Algorithm SHA256).Hash -ne [string]$entries[0].sha256
    ) {
        throw "Package support file '$supportName' does not match the submitted build. Refusing installation."
    }
}

$installingInfSha256 = [string]$pinnedInitialPackageSnapshot["SplatplostBluetooth.inf"].Sha256
$installingDriverSha256 = [string]$pinnedInitialPackageSnapshot["SplatplostBluetooth.sys"].Sha256
$priorPublishedPackageInventory = Get-SplatplostPublishedPackageInventory `
    -ExpectedHardwareId $hardwareId
$priorBindingSnapshot = Get-SplatplostBindingSnapshot `
    -InstanceIdPattern "$hardwareId*" `
    -ExpectedHardwareId $hardwareId
[uint64]$targetRadioAddress = 0
[uint32]$availableRadioCount = 0
$radioQueryCode = [uint32][Splatplost.NativeStatus]::GetSingleRadioAddress(
    [ref]$targetRadioAddress,
    [ref]$availableRadioCount
)
if ($availableRadioCount -ne 1 -or $radioQueryCode -ne 0 -or $targetRadioAddress -eq 0) {
    if ($availableRadioCount -gt 1) {
        throw "Splatplost currently supports exactly one enabled Windows Bluetooth radio, but $availableRadioCount were found. Disable extra Bluetooth adapters and retry."
    }
    throw "Exactly one enabled Windows Bluetooth radio is required before installation ($(Format-NativeStatus -Code $radioQueryCode))."
}
if (Test-Path -LiteralPath $stateKey) {
    $recordedRadio = (Get-ItemProperty -LiteralPath $stateKey -ErrorAction Stop).PSObject.Properties['InstalledRadioAddress']
    if ($recordedRadio -and [uint64]$recordedRadio.Value -ne $targetRadioAddress) {
        throw "The enabled Bluetooth radio does not match the radio recorded by the existing installation. Re-enable the original adapter or run uninstall-driver.cmd."
    }
}

$catalogSignature = Get-AuthenticodeSignature -LiteralPath $catalog
$driverSignature = Get-IsolatedAuthenticodeSignature -Path $driver
$catalogEkus = Get-CertificateEkuOids -Certificate $catalogSignature.SignerCertificate
$hardwareSigningOids = @("1.3.6.1.4.1.311.10.3.5.1", "1.3.6.1.4.1.311.10.3.5")
$hasMicrosoftHardwareEku = @($hardwareSigningOids | Where-Object { $catalogEkus -contains $_ }).Count -gt 0
$isMicrosoftSigned = [bool](
    $catalogSignature.Status -eq [System.Management.Automation.SignatureStatus]::Valid -and
    $driverSignature.Status -eq [System.Management.Automation.SignatureStatus]::Valid -and
    $catalogSignature.SignerCertificate -and
    $driverSignature.SignerCertificate -and
    $catalogSignature.SignerCertificate.Subject -match "Microsoft" -and
    $driverSignature.SignerCertificate.Subject -match "Microsoft" -and
    $hasMicrosoftHardwareEku
)

$developmentCertificate = $null
$developmentCertificateAddedToRoot = $false
$developmentCertificateAddedToPublisher = $false
$pendingJournalCreated = $false
if ($isMicrosoftSigned) {
    if (
        -not [bool]$packagePin.Records["SplatplostBluetooth-release-manifest.json"].Present -or
        -not [bool]$packagePin.Records["SplatplostBluetooth-signature-evidence.json"].Present
    ) {
        throw "The Microsoft-signed package was not initially pinned with its release manifest and signature evidence."
    }
    $releaseManifest = Confirm-MicrosoftReleaseManifest `
        -ManifestPath $releaseManifestPath `
        -PackageDirectory $package
    if ($hasPinnedDevelopmentCertificate) {
        throw "A Microsoft-signed release package must not contain the development trust certificate."
    }
    if ($EnableTestSigning) {
        Write-Warning "-EnableTestSigning is unnecessary and was ignored because this package is Microsoft-signed."
    }
    if ([Splatplost.NativeStatus]::IsTestSigningEnabled()) {
        Write-Warning "Windows test-signing mode is still active. Disable it and restart before collecting production runtime evidence."
    }
    New-SplatplostPendingInstallJournal `
        -Path $pendingStateKey `
        -InfSha256 $installingInfSha256 `
        -DriverSha256 $installingDriverSha256 `
        -PriorPublishedPackages $priorPublishedPackageInventory `
        -HadManagedState (Test-Path -LiteralPath $stateKey) `
        -PriorBindingDeviceCount (@($priorBindingSnapshot.Devices).Count) `
        -TargetRadioAddress $targetRadioAddress
    $pendingJournalCreated = $true
    Write-Host "Verified a Microsoft hardware-signed driver package."
} elseif ($hasPinnedDevelopmentCertificate) {
    $developmentCertificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($certificate)
    if ($developmentCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -ne "Splatplost Development Driver") {
        throw "The development certificate has an unexpected identity. Refusing to trust it."
    }
    if ((Get-CertificateEkuOids -Certificate $developmentCertificate) -notcontains "1.3.6.1.5.5.7.3.3") {
        throw "The development certificate is not restricted to code signing. Refusing to trust it."
    }
    if (
        -not $catalogSignature.SignerCertificate -or
        -not $driverSignature.SignerCertificate -or
        $catalogSignature.SignerCertificate.Thumbprint -ne $developmentCertificate.Thumbprint -or
        $driverSignature.SignerCertificate.Thumbprint -ne $developmentCertificate.Thumbprint
    ) {
        throw "The development certificate does not match both driver signatures. The package may be mixed or damaged."
    }

    try {
        $secureBoot = [bool](Confirm-SecureBootUEFI -ErrorAction Stop)
    } catch {
        throw "Windows could not confirm that Secure Boot is disabled. Development-driver installation is blocked: $($_.Exception.Message)"
    }
    if ($secureBoot) {
        throw "Secure Boot is enabled. A development-signed driver cannot load; use a Microsoft-signed release driver."
    }

    try {
        $deviceGuard = Get-CimInstance -Namespace "root\Microsoft\Windows\DeviceGuard" -ClassName "Win32_DeviceGuard" -ErrorAction Stop
        if (@($deviceGuard.SecurityServicesRunning | ForEach-Object { [int]$_ }) -contains 2) {
            throw "Memory Integrity (HVCI) is running. A development-signed driver is not an ordinary secure installation; use a Microsoft-signed release driver."
        }
    } catch {
        if ($_.Exception.Message -match "Memory Integrity") { throw }
        throw "Windows could not confirm that Memory Integrity is disabled. Development-driver installation is blocked: $($_.Exception.Message)"
    }

    $testSigningActive = [Splatplost.NativeStatus]::IsTestSigningEnabled()
    if ($EnableTestSigning -and -not $testSigningActive) {
        & "$env:SystemRoot\System32\bcdedit.exe" /set testsigning on | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Windows test-signing mode could not be enabled." }
        Write-Warning "Test-signing mode was enabled. Restart Windows, then run this script again."
        return
    }
    if (-not $testSigningActive) {
        throw "Windows test-signing mode is not active. Run .\install-driver.ps1 -EnableTestSigning, restart Windows, then run .\install-driver.ps1 again."
    }

    $rootPath = "Cert:\LocalMachine\Root\$($developmentCertificate.Thumbprint)"
    $publisherPath = "Cert:\LocalMachine\TrustedPublisher\$($developmentCertificate.Thumbprint)"
    $certificateRootExistedBefore = Test-Path -LiteralPath $rootPath
    $certificatePublisherExistedBefore = Test-Path -LiteralPath $publisherPath
    New-SplatplostPendingInstallJournal `
        -Path $pendingStateKey `
        -InfSha256 $installingInfSha256 `
        -DriverSha256 $installingDriverSha256 `
        -PriorPublishedPackages $priorPublishedPackageInventory `
        -HadManagedState (Test-Path -LiteralPath $stateKey) `
        -PriorBindingDeviceCount (@($priorBindingSnapshot.Devices).Count) `
        -TargetRadioAddress $targetRadioAddress `
        -DevelopmentCertificateThumbprint $developmentCertificate.Thumbprint `
        -CertificateRootExistedBefore $certificateRootExistedBefore `
        -CertificatePublisherExistedBefore $certificatePublisherExistedBefore
    $pendingJournalCreated = $true
    Set-SplatplostPendingInstallPhase -Path $pendingStateKey -Phase "trust-importing"
    try {
        $developmentCertificateAddedToRoot = Add-ExactCertificateToLocalMachineStore `
            -Certificate $developmentCertificate `
            -StoreName ([Security.Cryptography.X509Certificates.StoreName]::Root)
        $developmentCertificateAddedToPublisher = Add-ExactCertificateToLocalMachineStore `
            -Certificate $developmentCertificate `
            -StoreName ([Security.Cryptography.X509Certificates.StoreName]::TrustedPublisher)

        $trustedCatalogSignature = Get-AuthenticodeSignature -LiteralPath $catalog
        $trustedDriverSignature = Get-IsolatedAuthenticodeSignature -Path $driver
        if (
            $trustedCatalogSignature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
            $trustedDriverSignature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
            -not $trustedCatalogSignature.SignerCertificate -or
            -not $trustedDriverSignature.SignerCertificate -or
            $trustedCatalogSignature.SignerCertificate.Thumbprint -ne $developmentCertificate.Thumbprint -or
            $trustedDriverSignature.SignerCertificate.Thumbprint -ne $developmentCertificate.Thumbprint
        ) {
            throw "The development signatures remain invalid after importing the matching certificate."
        }
        Set-SplatplostPendingInstallPhase -Path $pendingStateKey -Phase "trust-imported"
    } catch {
        $trustFailure = $_
        $cleanupFailures = @()
        if (-not $certificateRootExistedBefore) {
            $cleanupError = Remove-CertificateAddedByThisRun -Path $rootPath -Description "LocalMachine Root development certificate"
            if ($cleanupError) { $cleanupFailures += $cleanupError }
        }
        if (-not $certificatePublisherExistedBefore) {
            $cleanupError = Remove-CertificateAddedByThisRun -Path $publisherPath -Description "LocalMachine TrustedPublisher development certificate"
            if ($cleanupError) { $cleanupFailures += $cleanupError }
        }
        if ($cleanupFailures.Count -eq 0 -and $pendingJournalCreated) {
            try {
                Remove-Item -LiteralPath $pendingStateKey -Recurse -Force -ErrorAction Stop
                $pendingJournalCreated = $false
            } catch {
                $cleanupFailures += "The pending-install recovery journal could not be removed: $($_.Exception.Message)"
            }
        }
        if ($cleanupFailures.Count -ne 0) {
            throw "Development trust setup failed and certificate rollback was incomplete. Original error: $($trustFailure.Exception.Message). Cleanup errors: $($cleanupFailures -join '; ')"
        }
        throw $trustFailure
    }
    Write-Warning "Verified a development-signed package. This path requires reduced Windows security and is not suitable for this computer."
} else {
    throw "The driver is neither Microsoft hardware-signed nor accompanied by its exact development certificate. Refusing installation before changing Windows."
}

$stateKeyCreatedByThisRun = $false
$profileEnabledByThisRun = $false
$installationCompleted = $false
$properties = $null
$parametersKey = "HKLM:\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters"
$managedStateTypes = [ordered]@{
    StateVersion = "DWord"
    InstallationKind = "String"
    PublishedInfName = "String"
    InstalledRadioAddress = "QWord"
    DevelopmentCertificateThumbprint = "String"
    DevelopmentCertificateAddedToRoot = "DWord"
    DevelopmentCertificateAddedToTrustedPublisher = "DWord"
    OwnedDevelopmentCertificates = "MultiString"
}
$managedStateSnapshot = @{}
$packagePrestageAttempted = $false
$bindingInstallAttempted = $false

try {
    # Ask Windows to verify the INF/catalog membership and stage the package before
    # changing Bluetooth class/profile state. /install is intentionally deferred
    # until the matching BTHENUM device exists.
    $prestagePackageSnapshot = Get-SplatplostPinnedPackageSnapshot -PackagePin $packagePin
    Assert-SplatplostPinnedPackageSnapshot `
        -Expected $pinnedInitialPackageSnapshot `
        -Actual $prestagePackageSnapshot `
        -Checkpoint "immediately before package prestaging"
    Set-SplatplostPendingInstallPhase -Path $pendingStateKey -Phase "package-prestaging"
    $packagePrestageAttempted = $true
    & "$env:SystemRoot\System32\pnputil.exe" /add-driver $inf | Out-Host
    $prestageExitCode = $LASTEXITCODE
    if ($prestageExitCode -notin @(0, 259, 3010, 1641)) {
        throw "Windows rejected the INF/catalog membership or package policy before profile registration (PnPUtil exit code $prestageExitCode)."
    }
    Set-SplatplostPendingInstallPhase -Path $pendingStateKey -Phase "package-prestaged"

$properties = Get-ItemProperty -Path $parametersKey
$codChanged = (
    $null -eq $properties.'COD Major' -or
    [int]$properties.'COD Major' -ne 5 -or
    $null -eq $properties.'COD Type' -or
    [int]$properties.'COD Type' -ne 2
)
if (-not (Test-Path -LiteralPath $stateKey)) {
    New-Item -Path $stateKey -Force | Out-Null
    $stateKeyCreatedByThisRun = $true
    New-ItemProperty -Path $stateKey -Name "StateVersion" -PropertyType DWord -Value 2 -Force | Out-Null
    New-ItemProperty -Path $stateKey -Name "HadCodMajor" -PropertyType DWord -Value ([int]($null -ne $properties.'COD Major')) -Force | Out-Null
    if ($null -ne $properties.'COD Major') {
        New-ItemProperty -Path $stateKey -Name "CodMajor" -PropertyType DWord -Value ([int]$properties.'COD Major') -Force | Out-Null
    }
    New-ItemProperty -Path $stateKey -Name "HadCodType" -PropertyType DWord -Value ([int]($null -ne $properties.'COD Type')) -Force | Out-Null
    if ($null -ne $properties.'COD Type') {
        New-ItemProperty -Path $stateKey -Name "CodType" -PropertyType DWord -Value ([int]$properties.'COD Type') -Force | Out-Null
    }
} else {
    $stateBeforeRun = Get-ItemProperty -LiteralPath $stateKey -ErrorAction Stop
    foreach ($stateName in @($managedStateTypes.Keys)) {
        $stateProperty = $stateBeforeRun.PSObject.Properties[$stateName]
        if ($stateProperty) {
            $managedStateSnapshot[$stateName] = $stateProperty.Value
        }
    }
}

# Bluetooth Peripheral / Gamepad. HID service registration supplies the service bits.
New-ItemProperty -Path $parametersKey -Name "COD Major" -PropertyType DWord -Value 5 -Force | Out-Null
New-ItemProperty -Path $parametersKey -Name "COD Type" -PropertyType DWord -Value 2 -Force | Out-Null

# Register the local profile first. BthEnum creates the PDO only after this call.
Set-SplatplostPendingInstallPhase -Path $pendingStateKey -Phase "profile-enabling"
[uint64]$serviceRadioAddress = 0
[uint32]$serviceRadioCount = 0
$serviceExitCode = [uint32][Splatplost.NativeStatus]::SetLocalServiceEnabled(
    $serviceGuid,
    $true,
    $targetRadioAddress,
    [ref]$serviceRadioAddress,
    [ref]$serviceRadioCount
)
if ($serviceExitCode -ne 0) {
    throw "The local Bluetooth controller profile could not be registered ($(Format-NativeStatus -Code $serviceExitCode))."
}
if ($serviceRadioCount -ne 1 -or $serviceRadioAddress -ne $targetRadioAddress) {
    throw "The Bluetooth radio changed while the local profile was being registered."
}
$profileEnabledByThisRun = $true
Set-SplatplostPendingInstallPhase -Path $pendingStateKey -Phase "profile-enabled"

& "$env:SystemRoot\System32\pnputil.exe" /scan-devices | Out-Host
$scanExitCode = $LASTEXITCODE
if ($scanExitCode -notin @(0, 3010, 1641)) {
    throw "Windows could not rescan Bluetooth devices (PnPUtil exit code $scanExitCode)."
}

$bindingInstallAttempted = $true
Set-SplatplostPendingInstallPhase -Path $pendingStateKey -Phase "binding-installing"
& "$env:SystemRoot\System32\pnputil.exe" /add-driver $inf /install | Out-Host
$pnputilExitCode = $LASTEXITCODE

# 259 means that the matching device already has the best driver. 3010/1641
# mean that installation succeeded but a restart is required or in progress.
if ($pnputilExitCode -notin @(0, 259, 3010, 1641)) {
    throw "Windows rejected the Splatplost Bluetooth driver package (PnPUtil exit code $pnputilExitCode)."
}
$restartRequired = (
    $codChanged -or
    $prestageExitCode -in @(3010, 1641) -or
    $pnputilExitCode -in @(3010, 1641) -or
    $scanExitCode -in @(3010, 1641)
)
if ($pnputilExitCode -eq 259) {
    Write-Host "The Splatplost Bluetooth driver is already staged and current. Continuing."
}

$devices = @(Wait-SplatplostPresentDevices -InstanceIdPattern "$hardwareId*" -TimeoutSeconds 30)
if ($devices.Count -eq 0) {
    throw "The Bluetooth profile was registered, but Windows did not create its device within 30 seconds. Check %windir%\inf\setupapi.dev.log, restart Windows, and run this installer again."
}

foreach ($device in $devices) {
    & "$env:SystemRoot\System32\pnputil.exe" /restart-device $device.InstanceId | Out-Host
    $restartExitCode = $LASTEXITCODE
    if ($restartExitCode -in @(3010, 1641)) {
        $restartRequired = $true
    } elseif ($restartExitCode -ne 0) {
        throw "Windows could not restart the Splatplost Bluetooth device (PnPUtil exit code $restartExitCode)."
    }
}

$deviceStates = @(Wait-SplatplostDeviceStates -InstanceIdPattern "$hardwareId*" -TimeoutSeconds 30)
$incompleteStates = @($deviceStates | Where-Object {
    [string]::IsNullOrWhiteSpace([string]$_.InstanceId) -or
    [string]::IsNullOrWhiteSpace([string]$_.Status) -or
    [string]::IsNullOrWhiteSpace([string]$_.Service) -or
    $null -eq $_.ProblemCode -or
    $null -eq $_.ProblemStatus -or
    [string]::IsNullOrWhiteSpace([string]$_.DriverInfPath)
})
if ($deviceStates.Count -eq 0 -or $incompleteStates.Count -ne 0) {
    throw "Windows did not expose a complete Splatplost PnP state within 30 seconds. Check %windir%\inf\setupapi.dev.log, restart Windows, and retry."
}
if ($deviceStates.Count -ne 1) {
    throw "Splatplost requires exactly one present profile device for the single supported Bluetooth radio, but $($deviceStates.Count) were found."
}

$publishedInfNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($deviceState in $deviceStates) {
    if ($deviceState.Service -ne "SplatplostBluetooth") {
        throw "Windows did not bind the Splatplost driver to device '$($deviceState.Device.InstanceId)' (active service: '$($deviceState.Service)')."
    }
    if ([string]$deviceState.DriverInfPath -notmatch '^oem\d+\.inf$') {
        throw "Windows did not report a safe published INF name for device '$($deviceState.Device.InstanceId)' (reported: '$($deviceState.DriverInfPath)')."
    }
    [void]$publishedInfNames.Add(([string]$deviceState.DriverInfPath).ToLowerInvariant())

    $problemCode = [int]$deviceState.ProblemCode
    if ($problemCode -eq 14) {
        $restartRequired = $true
        continue
    }
    if ($problemCode -ne 0) {
        if ($problemCode -eq 52) {
            $signatureHint = if ($isMicrosoftSigned) {
                "The Microsoft-signed package did not satisfy this Windows code-integrity policy; retain the package and SetupAPI log for diagnosis."
            } else {
                "Confirm that Secure Boot and Memory Integrity are off, test-signing mode is active, and Windows was restarted."
            }
            throw "Windows blocked the driver signature on device '$($deviceState.Device.InstanceId)' (Device Manager code 52). $signatureHint"
        }
        $problemStatusText = "0x{0:X8}" -f [uint32]$deviceState.ProblemStatus
        throw "The Splatplost driver could not start on device '$($deviceState.Device.InstanceId)' (problem code $problemCode, NTSTATUS $problemStatusText, status $($deviceState.Device.Status))."
    }
    if ([uint32]$deviceState.ProblemStatus -ne 0 -or $deviceState.Status -ine "OK") {
        $problemStatusText = "0x{0:X8}" -f [uint32]$deviceState.ProblemStatus
        throw "The Splatplost driver reported an unhealthy started state on device '$($deviceState.InstanceId)' (problem code 0, NTSTATUS $problemStatusText, status $($deviceState.Status))."
    }
}
if ($publishedInfNames.Count -ne 1) {
    throw "The present Splatplost devices do not use exactly one published INF identity: $(@($publishedInfNames) -join ', ')"
}
$driverInfPath = @($publishedInfNames)[0]

$serviceKey = "HKLM:\SYSTEM\CurrentControlSet\Services\SplatplostBluetooth"
$serviceImagePath = (Get-ItemProperty -LiteralPath $serviceKey -Name ImagePath -ErrorAction Stop).ImagePath
$installedDriver = Resolve-KernelImagePath -ImagePath ([string]$serviceImagePath)
if (-not (Test-Path -LiteralPath $installedDriver -PathType Leaf)) {
    throw "Windows registered the driver service, but its installed binary is missing: $installedDriver"
}
$packageDriverHash = (Get-FileHash -LiteralPath $driver -Algorithm SHA256).Hash
$installedDriverHash = (Get-FileHash -LiteralPath $installedDriver -Algorithm SHA256).Hash
if ($packageDriverHash -ne $installedDriverHash) {
    throw "Windows is still using a different SplatplostBluetooth.sys. Uninstall the old package, restart, and install this package again."
}
$publishedInfPath = Join-Path (Join-Path $env:SystemRoot "INF") $driverInfPath
if (
    -not (Test-Path -LiteralPath $publishedInfPath -PathType Leaf) -or
    (Get-FileHash -LiteralPath $publishedInfPath -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $inf -Algorithm SHA256).Hash
) {
    throw "The active published INF does not match this package. Uninstall the old package, restart, and install this package again."
}

$driverInitializationStatus = [uint32]0
$driverInitializationStage = [uint32]0
$driverLocalAddress = [uint64]0
$bridgeError = -1
$bridgeReady = $false
$bridgeDeadline = [DateTime]::UtcNow.AddSeconds(30)
do {
    $bridgeError = [Splatplost.NativeStatus]::ProbeBridge(
        $bridgePath,
        [ref]$driverInitializationStatus,
        [ref]$driverInitializationStage,
        [ref]$driverLocalAddress
    )
    $bridgeReady = [bool](
        $bridgeError -eq 0 -and
        $driverInitializationStatus -eq 0 -and
        $driverInitializationStage -eq 5 -and
        $driverLocalAddress -eq $targetRadioAddress
    )
    if ($bridgeReady -or $restartRequired) { break }
    Start-Sleep -Milliseconds 250
} while ([DateTime]::UtcNow -lt $bridgeDeadline)

if ($bridgeError -ne 0 -and -not $restartRequired) {
    throw "The driver device started, but its application bridge is unavailable (Windows error $bridgeError)."
}

if (-not $bridgeReady -and -not $restartRequired) {
    $stageNames = @{
        1 = "local Bluetooth radio query"
        2 = "device-specific HID PSM registration after pairing"
        3 = "pairing-notification server registration"
        4 = "HID SDP record publication"
    }
    $stageName = $stageNames[[int]$driverInitializationStage]
    if (-not $stageName) { $stageName = "unknown initialization stage" }
    $driverStatusText = "0x{0:X8}" -f $driverInitializationStatus
    $addressText = "0x{0:X12}" -f $driverLocalAddress
    throw "The driver loaded, but Bluetooth initialization did not become ready within 30 seconds during $stageName (stage $driverInitializationStage, NTSTATUS $driverStatusText, local address $addressText)."
}

$finalPackageSnapshot = Get-SplatplostPinnedPackageSnapshot -PackagePin $packagePin
Assert-SplatplostPinnedPackageSnapshot `
    -Expected $pinnedInitialPackageSnapshot `
    -Actual $finalPackageSnapshot `
    -Checkpoint "immediately before installation commit"

# Commit uninstall metadata only after Windows selected the exact package and
# the driver either proved initialization readiness or explicitly needs a reboot.
$existingState = Get-ItemProperty -LiteralPath $stateKey
$ownedCertificates = Get-OwnedDevelopmentCertificateRecords -ExistingState $existingState
if ($developmentCertificate) {
    Add-OwnedDevelopmentCertificateRecord `
        -Records $ownedCertificates `
        -Thumbprint $developmentCertificate.Thumbprint `
        -RootOwned $developmentCertificateAddedToRoot `
        -PublisherOwned $developmentCertificateAddedToPublisher

    # Retain these legacy fields for safe removal by older uninstallers. Their
    # ownership flags describe this exact thumbprint only, never a previous one.
    New-ItemProperty -Path $stateKey -Name "DevelopmentCertificateThumbprint" -PropertyType String -Value $developmentCertificate.Thumbprint -Force | Out-Null
    New-ItemProperty -Path $stateKey -Name "DevelopmentCertificateAddedToRoot" -PropertyType DWord -Value ([int]$developmentCertificateAddedToRoot) -Force | Out-Null
    New-ItemProperty -Path $stateKey -Name "DevelopmentCertificateAddedToTrustedPublisher" -PropertyType DWord -Value ([int]$developmentCertificateAddedToPublisher) -Force | Out-Null
}
if ($ownedCertificates.Count -gt 0) {
    [string[]]$serializedCertificates = @($ownedCertificates.Keys | Sort-Object | ForEach-Object {
        $record = $ownedCertificates[$_]
        "$_|$([int][bool]$record.RootOwned)|$([int][bool]$record.PublisherOwned)"
    })
    New-ItemProperty -Path $stateKey -Name "OwnedDevelopmentCertificates" -PropertyType MultiString -Value $serializedCertificates -Force | Out-Null
}

$installationKind = if ($isMicrosoftSigned) { "microsoft-hardware-signed" } else { "development-signed" }
New-ItemProperty -Path $stateKey -Name "StateVersion" -PropertyType DWord -Value 3 -Force | Out-Null
New-ItemProperty -Path $stateKey -Name "InstallationKind" -PropertyType String -Value $installationKind -Force | Out-Null
New-ItemProperty -Path $stateKey -Name "PublishedInfName" -PropertyType String -Value ([string]$driverInfPath).ToLowerInvariant() -Force | Out-Null
New-ItemProperty -Path $stateKey -Name "InstalledRadioAddress" -PropertyType QWord -Value $targetRadioAddress -Force | Out-Null
Set-SplatplostPendingInstallPhase -Path $pendingStateKey -Phase "committed"
Remove-Item -LiteralPath $pendingStateKey -Recurse -Force -ErrorAction Stop
$pendingJournalCreated = $false
$installationCompleted = $true

if ($restartRequired -or $bridgeError -ne 0) {
    Write-Warning "Windows must be restarted before the first pairing. After restart, pair the Switch and run .\verify-runtime.ps1 -PackageDirectory . -RequireConnected."
} else {
    Write-Host "The installed binary matches this package and driver initialization is ready. Pair the Switch, then run .\verify-runtime.ps1 -PackageDirectory . -RequireConnected."
}
} catch {
    $failure = $_
    $cleanupFailures = @()
    $rollbackFailures = @()
    $bindingRollbackVerified = $true
    $bindingRollbackResult = $null
    $profileDisableAttemptedDuringBindingRollback = $false

    # On a first installation the profile-created PDO must disappear before an
    # empty pre-install binding can be proven. If disabling fails, retain any
    # newly imported development trust so a still-active driver cannot become
    # Code 52 on the next boot.
    if (
        $packagePrestageAttempted -and
        @($priorBindingSnapshot.Devices).Count -eq 0 -and
        $profileEnabledByThisRun
    ) {
        $profileDisableAttemptedDuringBindingRollback = $true
        try {
            [uint64]$rollbackRadioAddress = 0
            [uint32]$rollbackRadioCount = 0
            $disableCode = [uint32][Splatplost.NativeStatus]::SetLocalServiceEnabled(
                $serviceGuid,
                $false,
                $targetRadioAddress,
                [ref]$rollbackRadioAddress,
                [ref]$rollbackRadioCount
            )
            if (
                $disableCode -eq 0 -and
                $rollbackRadioCount -eq 1 -and
                $rollbackRadioAddress -eq $targetRadioAddress
            ) {
                $profileEnabledByThisRun = $false
            } else {
                $bindingRollbackVerified = $false
                $rollbackFailures += "The local Bluetooth profile could not be disabled before binding rollback ($(Format-NativeStatus -Code $disableCode))."
            }
        } catch {
            $bindingRollbackVerified = $false
            $rollbackFailures += "The local Bluetooth profile disable raised an error before binding rollback: $($_.Exception.Message)"
        }
    }

    if ($packagePrestageAttempted) {
        try {
            $bindingRollbackResult = Restore-SplatplostBindingSnapshot `
                -Snapshot $priorBindingSnapshot `
                -PriorPublishedPackages $priorPublishedPackageInventory `
                -InstanceIdPattern "$hardwareId*" `
                -ExpectedHardwareId $hardwareId `
                -InstallingInfSha256 $installingInfSha256 `
                -InstallingDriverSha256 $installingDriverSha256
            $bindingRollbackVerified = [bool](
                $bindingRollbackVerified -and $bindingRollbackResult.Verified
            )
            if (-not $bindingRollbackResult.Verified) {
                $rollbackFailures += @($bindingRollbackResult.Errors)
            }
        } catch {
            $bindingRollbackVerified = $false
            $rollbackFailures += "Binding rollback raised an error: $($_.Exception.Message)"
        }
    }

    # Restore every Class-of-Device value changed by this run. On a first-time
    # install, also remove the profile and state key created by this run. An
    # existing managed profile is retained so a failed upgrade cannot disable
    # the previously working installation.
    if (-not $installationCompleted) {
        try {
            if (
                $profileEnabledByThisRun -and
                @($priorBindingSnapshot.Devices).Count -eq 0 -and
                -not $profileDisableAttemptedDuringBindingRollback
            ) {
                [uint64]$rollbackRadioAddress = 0
                [uint32]$rollbackRadioCount = 0
                $disableCode = [uint32][Splatplost.NativeStatus]::SetLocalServiceEnabled(
                    $serviceGuid,
                    $false,
                    $targetRadioAddress,
                    [ref]$rollbackRadioAddress,
                    [ref]$rollbackRadioCount
                )
                if (
                    $disableCode -ne 0 -or
                    $rollbackRadioCount -ne 1 -or
                    $rollbackRadioAddress -ne $targetRadioAddress
                ) {
                    $bindingRollbackVerified = $false
                    $rollbackFailures += "The local Bluetooth profile could not be disabled ($(Format-NativeStatus -Code $disableCode))."
                } else {
                    $profileEnabledByThisRun = $false
                }
            }
            if ($properties) {
                $currentCodProperties = Get-ItemProperty -LiteralPath $parametersKey -ErrorAction Stop
                $codRollbackDecisions = @(
                    Get-SplatplostCodRollbackDecision `
                        -SnapshotProperties $properties `
                        -CurrentProperties $currentCodProperties `
                        -RegistryValueName "COD Major" `
                        -ManagedValue 5
                    Get-SplatplostCodRollbackDecision `
                        -SnapshotProperties $properties `
                        -CurrentProperties $currentCodProperties `
                        -RegistryValueName "COD Type" `
                        -ManagedValue 2
                )
                foreach ($decision in $codRollbackDecisions) {
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
                            Write-Warning "$($decision.RegistryValueName) is now missing, so its external change during installation is preserved instead of applying the rollback snapshot."
                        }
                        "preserve-changed" {
                            Write-Warning "$($decision.RegistryValueName) is now $($decision.CurrentValue), so its external change during installation is preserved instead of applying the rollback snapshot."
                        }
                        default {
                            throw "The installation COD rollback decision is invalid for $($decision.RegistryValueName): $($decision.Action)"
                        }
                    }
                }

                $verifiedCodProperties = Get-ItemProperty -LiteralPath $parametersKey -ErrorAction Stop
                foreach ($decision in @($codRollbackDecisions | Where-Object { $_.Action -in @("restore", "remove") })) {
                    $verifiedProperty = $verifiedCodProperties.PSObject.Properties[$decision.RegistryValueName]
                    if (
                        ($decision.Action -eq "restore" -and (
                            -not $verifiedProperty -or
                            [int64]$verifiedProperty.Value -ne [int64]$decision.SnapshotValue
                        )) -or
                        ($decision.Action -eq "remove" -and $verifiedProperty)
                    ) {
                        throw "The installation rollback did not restore the owned pre-install COD state for $($decision.RegistryValueName)."
                    }
                }
            }
            if ($stateKeyCreatedByThisRun -and $bindingRollbackVerified) {
                Remove-Item -LiteralPath $stateKey -Recurse -Force -ErrorAction Stop
            } elseif (Test-Path -LiteralPath $stateKey) {
                $currentState = Get-ItemProperty -LiteralPath $stateKey -ErrorAction Stop
                foreach ($stateName in @($managedStateTypes.Keys)) {
                    if ($managedStateSnapshot.ContainsKey($stateName)) {
                        New-ItemProperty `
                            -Path $stateKey `
                            -Name $stateName `
                            -PropertyType $managedStateTypes[$stateName] `
                            -Value $managedStateSnapshot[$stateName] `
                            -Force | Out-Null
                    } elseif ($currentState.PSObject.Properties[$stateName]) {
                        Remove-ItemProperty -LiteralPath $stateKey -Name $stateName -ErrorAction Stop
                    }
                }
            }
        } catch {
            $bindingRollbackVerified = $false
            $rollbackFailures += $_.Exception.Message
        }
    }

    if (-not $bindingRollbackVerified) {
        try {
            if (-not (Test-Path -LiteralPath $stateKey)) {
                New-Item -Path $stateKey -Force | Out-Null
            }
            New-ItemProperty -Path $stateKey -Name "StateVersion" -PropertyType DWord -Value 3 -Force | Out-Null
            New-ItemProperty -Path $stateKey -Name "InstallationKind" -PropertyType String -Value "recovery-required" -Force | Out-Null
            if ($bindingRollbackResult -and @($bindingRollbackResult.ActiveInfNames).Count -eq 1) {
                New-ItemProperty `
                    -Path $stateKey `
                    -Name "PublishedInfName" `
                    -PropertyType String `
                    -Value ([string]@($bindingRollbackResult.ActiveInfNames)[0]) `
                    -Force | Out-Null
            }
            if ($developmentCertificate -and ($developmentCertificateAddedToRoot -or $developmentCertificateAddedToPublisher)) {
                $recoveryState = Get-ItemProperty -LiteralPath $stateKey -ErrorAction Stop
                $recoveryCertificates = Get-OwnedDevelopmentCertificateRecords -ExistingState $recoveryState
                Add-OwnedDevelopmentCertificateRecord `
                    -Records $recoveryCertificates `
                    -Thumbprint $developmentCertificate.Thumbprint `
                    -RootOwned $developmentCertificateAddedToRoot `
                    -PublisherOwned $developmentCertificateAddedToPublisher
                [string[]]$serializedRecoveryCertificates = @($recoveryCertificates.Keys | Sort-Object | ForEach-Object {
                    $record = $recoveryCertificates[$_]
                    "$_|$([int][bool]$record.RootOwned)|$([int][bool]$record.PublisherOwned)"
                })
                New-ItemProperty -Path $stateKey -Name "OwnedDevelopmentCertificates" -PropertyType MultiString -Value $serializedRecoveryCertificates -Force | Out-Null
                New-ItemProperty -Path $stateKey -Name "DevelopmentCertificateThumbprint" -PropertyType String -Value $developmentCertificate.Thumbprint -Force | Out-Null
                New-ItemProperty -Path $stateKey -Name "DevelopmentCertificateAddedToRoot" -PropertyType DWord -Value ([int]$developmentCertificateAddedToRoot) -Force | Out-Null
                New-ItemProperty -Path $stateKey -Name "DevelopmentCertificateAddedToTrustedPublisher" -PropertyType DWord -Value ([int]$developmentCertificateAddedToPublisher) -Force | Out-Null
            }
            $rollbackFailures += "The prior driver binding was not restored exactly; recovery state was retained for uninstall-driver.cmd."
        } catch {
            $rollbackFailures += "Recovery metadata could not be retained: $($_.Exception.Message)"
        }
    }

    if ($bindingRollbackVerified -and $developmentCertificateAddedToRoot -and $developmentCertificate) {
        $cleanupError = Remove-CertificateAddedByThisRun `
            -Path "Cert:\LocalMachine\Root\$($developmentCertificate.Thumbprint)" `
            -Description "LocalMachine Root development certificate"
        if ($cleanupError) { $cleanupFailures += $cleanupError }
    }
    if ($bindingRollbackVerified -and $developmentCertificateAddedToPublisher -and $developmentCertificate) {
        $cleanupError = Remove-CertificateAddedByThisRun `
            -Path "Cert:\LocalMachine\TrustedPublisher\$($developmentCertificate.Thumbprint)" `
            -Description "LocalMachine TrustedPublisher development certificate"
        if ($cleanupError) { $cleanupFailures += $cleanupError }
    }
    if (
        $bindingRollbackVerified -and
        $rollbackFailures.Count -eq 0 -and
        $cleanupFailures.Count -eq 0 -and
        $pendingJournalCreated
    ) {
        try {
            Remove-Item -LiteralPath $pendingStateKey -Recurse -Force -ErrorAction Stop
            $pendingJournalCreated = $false
        } catch {
            $cleanupFailures += "The pending-install recovery journal could not be removed: $($_.Exception.Message)"
        }
    }
    if ($rollbackFailures.Count -ne 0 -or $cleanupFailures.Count -ne 0) {
        throw "Driver installation failed and rollback was incomplete. Original error: $($failure.Exception.Message). Machine rollback errors: $($rollbackFailures -join '; '). Certificate cleanup errors: $($cleanupFailures -join '; '). Run uninstall-driver.cmd before retrying."
    }
    throw $failure
}
} finally {
    try {
        if ($null -ne $packagePin) {
            Close-SplatplostPackagePin -PackagePin $packagePin
            $packagePin = $null
        }
    } finally {
        if ($operationMutexAcquired) {
            $operationMutex.ReleaseMutex()
        }
        $operationMutex.Dispose()
    }
}
