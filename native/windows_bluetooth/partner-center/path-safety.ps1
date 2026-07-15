Set-StrictMode -Version Latest

if (-not ("Splatplost.PackagingPath" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Splatplost
{
    public static class PackagingPath
    {
        private const uint FileShareRead = 0x00000001;
        private const uint FileShareWrite = 0x00000002;
        private const uint FileShareDelete = 0x00000004;
        private const uint OpenExisting = 3;
        private const uint FileFlagBackupSemantics = 0x02000000;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandleW(
            SafeFileHandle file,
            StringBuilder filePath,
            uint filePathLength,
            uint flags);

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

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle file,
            out ByHandleFileInformation information);

        private static SafeFileHandle OpenPath(string path)
        {
            SafeFileHandle handle = CreateFileW(
                path,
                0,
                FileShareRead | FileShareWrite | FileShareDelete,
                IntPtr.Zero,
                OpenExisting,
                FileFlagBackupSemantics,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error,
                    "Could not open a packaging path for identity inspection: " + path);
            }
            return handle;
        }

        public static string GetFinalPathName(string path)
        {
            using (SafeFileHandle handle = OpenPath(path))
            {
                int capacity = 512;
                while (true)
                {
                    StringBuilder result = new StringBuilder(capacity);
                    uint length = GetFinalPathNameByHandleW(handle, result, (uint)result.Capacity, 0);
                    if (length == 0)
                    {
                        throw new Win32Exception(Marshal.GetLastWin32Error(),
                            "Could not canonicalize packaging path: " + path);
                    }
                    if (length < result.Capacity)
                    {
                        return result.ToString();
                    }
                    capacity = checked((int)length + 1);
                }
            }
        }

        public static string GetFileIdentity(string path)
        {
            using (SafeFileHandle handle = OpenPath(path))
            {
                ByHandleFileInformation information;
                if (!GetFileInformationByHandle(handle, out information))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(),
                        "Could not read packaging filesystem identity: " + path);
                }
                return information.VolumeSerialNumber.ToString("X8") + ":" +
                    information.FileIndexHigh.ToString("X8") + information.FileIndexLow.ToString("X8");
            }
        }
    }
}
'@
}

function ConvertFrom-SplatplostExtendedPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ($Path.StartsWith("\\?\UNC\", [StringComparison]::OrdinalIgnoreCase)) {
        return "\\" + $Path.Substring(8)
    }
    if ($Path.StartsWith("\\?\", [StringComparison]::OrdinalIgnoreCase) -and
            $Path.Length -ge 7 -and $Path[5] -eq ':') {
        return $Path.Substring(4)
    }
    return $Path
}

function Get-SplatplostLexicalFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::AltDirectorySeparatorChar -ne [IO.Path]::DirectorySeparatorChar) {
        $fullPath = $fullPath.Replace([IO.Path]::AltDirectorySeparatorChar, [IO.Path]::DirectorySeparatorChar)
    }
    $fullPath = ConvertFrom-SplatplostExtendedPath -Path $fullPath

    $root = [IO.Path]::GetPathRoot($fullPath)
    while ($root -and $fullPath.Length -gt $root.Length -and
            $fullPath.EndsWith([string][IO.Path]::DirectorySeparatorChar)) {
        $fullPath = $fullPath.Substring(0, $fullPath.Length - 1)
    }
    return $fullPath
}

function Get-SplatplostCanonicalPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = Get-SplatplostLexicalFullPath -Path $Path
    $existing = $fullPath
    $missingLeaves = New-Object 'System.Collections.Generic.List[string]'

    while (-not (Test-Path -LiteralPath $existing)) {
        $leaf = [IO.Path]::GetFileName($existing)
        $parent = [IO.Path]::GetDirectoryName($existing)
        if (-not $leaf -or -not $parent -or
                [string]::Equals($parent, $existing, [StringComparison]::OrdinalIgnoreCase)) {
            throw "No existing ancestor could be canonicalized for packaging path: $fullPath"
        }
        $missingLeaves.Insert(0, $leaf)
        $existing = $parent
    }

    $canonical = [Splatplost.PackagingPath]::GetFinalPathName($existing)
    $canonical = ConvertFrom-SplatplostExtendedPath -Path $canonical
    foreach ($leaf in $missingLeaves) {
        $canonical = [IO.Path]::Combine($canonical, $leaf)
    }
    return Get-SplatplostLexicalFullPath -Path $canonical
}

function Test-SplatplostSameOrDescendantPath {
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$Ancestor
    )

    if ([string]::Equals($Candidate, $Ancestor, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    $prefix = $Ancestor
    if (-not $prefix.EndsWith([string][IO.Path]::DirectorySeparatorChar)) {
        $prefix += [IO.Path]::DirectorySeparatorChar
    }
    return $Candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Test-SplatplostPathsAlias {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    $leftCanonical = Get-SplatplostCanonicalPath -Path $Left
    $rightCanonical = Get-SplatplostCanonicalPath -Path $Right
    if ([string]::Equals($leftCanonical, $rightCanonical, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    if ((Test-Path -LiteralPath $Left) -and (Test-Path -LiteralPath $Right)) {
        $leftIdentity = [Splatplost.PackagingPath]::GetFileIdentity($Left)
        $rightIdentity = [Splatplost.PackagingPath]::GetFileIdentity($Right)
        return [string]::Equals($leftIdentity, $rightIdentity, [StringComparison]::Ordinal)
    }
    return $false
}
