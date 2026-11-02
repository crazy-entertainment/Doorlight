param(
    [Parameter(Mandatory)][string]$BundleDir,
    [string]$VsDevCmd,
    [string]$VisualStudioRoot
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-PlainPath([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    while ($null -ne $item) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            ($item.PSObject.Properties['LinkType'] -and $item.LinkType)) {
            throw "Runtime paths must not contain links: $($item.FullName)"
        }
        $item = if ($item -is [IO.DirectoryInfo]) { $item.Parent } else { $item.Directory }
    }
}

if ($VsDevCmd -and $VisualStudioRoot) { throw 'Supply VsDevCmd or VisualStudioRoot, not both.' }
if (-not $VisualStudioRoot) {
    if (-not $VsDevCmd) {
        $VsDevCmd = & (Join-Path $PSScriptRoot '../windows-toolchain.ps1')
    }
    Assert-PlainPath $VsDevCmd
    $VsDevCmd = (Resolve-Path -LiteralPath $VsDevCmd).Path
    $toolsDirectory = Split-Path -Parent $VsDevCmd
    $commonDirectory = Split-Path -Parent $toolsDirectory
    if ([IO.Path]::GetFileName($VsDevCmd) -ine 'VsDevCmd.bat' -or
        (Split-Path -Leaf $toolsDirectory) -ine 'Tools' -or
        (Split-Path -Leaf $commonDirectory) -ine 'Common7') {
        throw 'Expected Visual Studio Common7/Tools/VsDevCmd.bat.'
    }
    $VisualStudioRoot = Split-Path -Parent $commonDirectory
}
$vsRoot = (Resolve-Path -LiteralPath $VisualStudioRoot).Path
$bundle = (Resolve-Path -LiteralPath $BundleDir).Path
Assert-PlainPath $vsRoot
Assert-PlainPath $bundle
if (-not (Get-Item -LiteralPath $bundle).PSIsContainer) { throw 'BundleDir must be a staged directory.' }
foreach ($entry in Get-ChildItem -LiteralPath $bundle -Recurse -Force) { Assert-PlainPath $entry.FullName }

# Match the default toolset used by this Visual Studio build, not the newest directory on disk.
$build = Join-Path $vsRoot 'VC/Auxiliary/Build'
$versions = @{}
foreach ($kind in @('VCTools', 'VCRedist')) {
    $metadata = Join-Path $build "Microsoft.${kind}Version.default.txt"
    Assert-PlainPath $metadata
    $value = (Get-Content -LiteralPath $metadata -Raw).Trim()
    if ($value -notmatch '^14\.\d+\.\d+$') { throw "Invalid $kind version metadata." }
    $versions[$kind] = $value
}
$toolset = [version]$versions.VCTools
$source = Join-Path $vsRoot "VC/Redist/MSVC/$($versions.VCRedist)/x64/Microsoft.VC143.CRT"
Assert-PlainPath $source
$allow = @('concrt140.dll', 'msvcp140.dll', 'msvcp140_1.dll', 'msvcp140_2.dll',
    'msvcp140_atomic_wait.dll', 'msvcp140_codecvt_ids.dll', 'vccorlib140.dll',
    'vcruntime140.dll', 'vcruntime140_1.dll', 'vcruntime140_threads.dll')
$entries = @(Get-ChildItem -LiteralPath $source -Force)
if ($entries.Count -ne $allow.Count -or @($entries | Where-Object { $_.PSIsContainer -or $_.Name -cnotin $allow }).Count) {
    throw 'Unexpected Microsoft.VC143.CRT contents; review the runtime allowlist before packaging.'
}
$files = @()
foreach ($name in $allow) {
    $path = Join-Path $source $name
    Assert-PlainPath $path
    $file = Get-Item -LiteralPath $path
    $info = $file.VersionInfo
    $version = [version]::new($info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart)
    if ($info.IsDebug -or $info.OriginalFilename -ine $name -or $info.CompanyName -cne 'Microsoft Corporation' -or
        $version.Major -ne $toolset.Major -or $version -lt $toolset) {
        throw "Invalid or older-than-toolset runtime: $name ($version)."
    }
    $stream = [IO.File]::OpenRead($path)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5a4d) { throw "Not a PE DLL: $name" }
        $stream.Position = 0x3c
        $peOffset = $reader.ReadUInt32()
        if ($peOffset -gt $stream.Length - 24) { throw "Invalid PE header: $name" }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x8664) { throw "Not an x64 PE DLL: $name" }
        $stream.Position = $peOffset + 22
        if (-not ($reader.ReadUInt16() -band 0x2000)) { throw "Not a DLL: $name" }
    } finally { $reader.Dispose(); $stream.Dispose() }
    $signature = Get-AuthenticodeSignature -LiteralPath $path
    if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') {
        throw "Microsoft Authenticode verification failed for ${name}: $($signature.Status) $($signature.StatusMessage)"
    }
    $files += [ordered]@{
        name = $name; version = $version.ToString(); sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        signatureStatus = [string]$signature.Status; signer = $signature.SignerCertificate.Subject
        signerThumbprint = $signature.SignerCertificate.Thumbprint
        timestampSigner = $(if ($signature.TimeStamperCertificate) { $signature.TimeStamperCertificate.Subject } else { $null })
    }
}
$redistNotice = Join-Path $vsRoot 'Licenses/1033/Redist.txt'
Assert-PlainPath $redistNotice
$redistText = Get-Content -LiteralPath $redistNotice -Raw
if ($redistText -notmatch 'Visual Studio 2022' -or $redistText -notmatch 'https://aka.ms/vs/17/redist.txt') {
    throw 'Missing official Visual Studio 2022 redistribution notice.'
}
$receipt = [ordered]@{
    schema = 1; architecture = 'x64'; deployment = 'app-local'; toolsetVersion = $versions.VCTools
    redistDirectoryVersion = $versions.VCRedist; files = $files
}
$notice = @'
Microsoft Visual C++ 2022 Runtime (x64)
These unmodified Microsoft files are separate from Doorlight's GPL license.
Redistribution is subject to the Microsoft Software License Terms for the licensed Visual Studio installation used to build this package.
The installation's redistribution notice is preserved in Microsoft-VisualStudio-Redist.txt.
Microsoft license directory: https://visualstudio.microsoft.com/license-terms/
Visual Studio 2022 REDIST list: https://learn.microsoft.com/en-us/visualstudio/releases/2022/redistribution
Redistribution guidance: https://learn.microsoft.com/en-us/cpp/windows/redistributing-visual-cpp-files?view=msvc-170
Deployment/version guidance: https://learn.microsoft.com/en-us/cpp/windows/determining-which-dlls-to-redistribute?view=msvc-170
These app-local files receive security updates through Doorlight package updates.
'@
$notices = Join-Path $bundle 'notices'
if (Test-Path -LiteralPath $notices) { Assert-PlainPath $notices }
$outputs = @{}
foreach ($file in $files) { $outputs[(Join-Path $bundle $file.name)] = [IO.File]::ReadAllBytes((Join-Path $source $file.name)) }
$utf8 = [Text.UTF8Encoding]::new($false)
$outputs[(Join-Path $notices 'Microsoft-VisualStudio-Redist.txt')] = [IO.File]::ReadAllBytes($redistNotice)
$outputs[(Join-Path $notices 'Microsoft-VisualCpp-Runtime.txt')] = $utf8.GetBytes($notice)
$receiptPath = Join-Path $notices 'Microsoft-VisualCpp-Runtime.json'
$outputs[$receiptPath] = $utf8.GetBytes(($receipt | ConvertTo-Json -Depth 6))
# Validate every collision before writing anything; repeat packaging is byte-identical only.
foreach ($path in $outputs.Keys) {
    if (Test-Path -LiteralPath $path) {
        Assert-PlainPath $path
        if (-not [Linq.Enumerable]::SequenceEqual([byte[]][IO.File]::ReadAllBytes($path), [byte[]]$outputs[$path])) {
            throw "Refusing to overwrite different bundle content: $path"
        }
    }
}
New-Item -ItemType Directory -Path $notices -Force | Out-Null
foreach ($path in $outputs.Keys) {
    if (-not (Test-Path -LiteralPath $path)) {
        $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($outputs[$path], 0, $outputs[$path].Length) } finally { $stream.Dispose() }
    }
}
[pscustomobject]@{ BundleDir = $bundle; ReceiptPath = $receiptPath; RuntimeSource = $source; FileCount = $files.Count }
