# Shared by the protected release entry point and its regression checks.
$script:WidgetOwner = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$script:WidgetWriters = @($script:WidgetOwner, 'S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
if (-not ('DoorlightSigningFile' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class DoorlightSigningFile {
    [StructLayout(LayoutKind.Sequential)] struct Attributes { public int Length; public IntPtr Descriptor; public int Inherit; }
    [StructLayout(LayoutKind.Sequential)] struct Info { public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write; public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow; }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateDirectory(string path, ref Attributes attributes);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string text, uint revision, out IntPtr descriptor, IntPtr length);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr value);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern SafeFileHandle CreateFile(string path, uint access, uint sharing, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle handle, out Info info);
    public static void CreatePrivateDirectory(string path, string owner) {
        IntPtr sd;
        if (!ConvertStringSecurityDescriptorToSecurityDescriptor("O:"+owner+"D:P(A;OICI;FA;;;"+owner+")(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)",1,out sd,IntPtr.Zero)) throw new Win32Exception();
        try { var sa=new Attributes {Length=Marshal.SizeOf<Attributes>(),Descriptor=sd}; if(!CreateDirectory(path,ref sa)) throw new Win32Exception(); }
        finally { LocalFree(sd); }
    }
    public static SafeFileHandle LockDirectory(string path) {
        var handle=CreateFile(path,0x80,1,IntPtr.Zero,3,0x02200000,IntPtr.Zero);
        if(handle.IsInvalid) throw new Win32Exception();
        Info info;
        if(!GetFileInformationByHandle(handle,out info) || (info.Attributes & 0x400)!=0) { handle.Dispose(); throw new InvalidOperationException("Reparse point or unreadable directory in toolchain source"); }
        return handle;
    }
    public static string Identity(SafeFileHandle handle) {
        Info info; if(!GetFileInformationByHandle(handle,out info)) throw new Win32Exception();
        if(info.Links!=1 || (info.Attributes & 0x400)!=0) throw new InvalidOperationException("Signing input must be a regular file with one link");
        return info.Volume+":"+info.IndexHigh+":"+info.IndexLow;
    }
}
'@
}
function Assert-WidgetAcl([string]$Path, [switch]$Ancestor) {
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point in signing inputs: $Path" }
    $acl = Get-Acl -LiteralPath $Path
    $descriptor = [Security.AccessControl.RawSecurityDescriptor]::new($acl.GetSecurityDescriptorBinaryForm(), 0)
    if ($null -eq $descriptor.DiscretionaryAcl) { throw "Null DACL in signing inputs: $Path" }
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $script:WidgetWriters) { throw "Untrusted signing owner: $Path" }
    # Ancestors may admit new siblings, but must not permit replacement of this subtree.
    $mask = if ($Ancestor) { 0x500D0040L } else { 0x500D0156L }
    if ($item.FullName -eq [IO.Path]::GetPathRoot($item.FullName)) { $mask = $mask -band (-bnot 0x10000L) }
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne 'Allow' -or ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)) { continue }
        if ($rule.IdentityReference.Value -notin $script:WidgetWriters -and ([long]$rule.FileSystemRights -band $mask)) { throw "Untrusted write access to signing input: $Path" }
    }
}
function Assert-WidgetAncestors([string]$Path) {
    $parent = [IO.DirectoryInfo][IO.Path]::GetFullPath($Path)
    while ($parent) { Assert-WidgetAcl $parent.FullName -Ancestor; $parent = $parent.Parent }
}
function Assert-WidgetPrivateTree([string]$Path) {
    Assert-WidgetAncestors $Path
    Assert-WidgetAcl $Path
    foreach ($item in Get-ChildItem -LiteralPath $Path -Recurse -Force) { Assert-WidgetAcl $item.FullName }
}
function Get-WidgetPackageInventory([string]$Path) {
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    $files = @{}
    try {
        foreach ($entry in $zip.Entries) {
            if ($files.ContainsKey($entry.FullName)) { throw 'Duplicate package entry' }
            $stream = $entry.Open(); $sha = [Security.Cryptography.SHA256]::Create()
            try { $files[$entry.FullName] = [Convert]::ToHexString($sha.ComputeHash($stream)) } finally { $stream.Dispose(); $sha.Dispose() }
        }
        $reader = [IO.StreamReader]::new($zip.GetEntry('[Content_Types].xml').Open())
        try { $types = [xml]$reader.ReadToEnd() } finally { $reader.Dispose() }
        $contentTypes = @($types.DocumentElement.ChildNodes | ForEach-Object { $_.OuterXml })
        return @{ Files=$files; ContentTypes=$contentTypes }
    } finally { $zip.Dispose() }
}
function Assert-WidgetSignedPayload($Before, $After) {
    foreach ($name in $Before.Files.Keys) {
        if ($name -eq '[Content_Types].xml') { continue }
        if ($After.Files[$name] -cne $Before.Files[$name]) { throw "Payload changed during signing: $name" }
    }
    foreach ($name in $After.Files.Keys) {
        if (-not $Before.Files.ContainsKey($name) -and $name -notin @('AppxSignature.p7x','AppxMetadata/CodeIntegrity.cat')) { throw "Unexpected signing output: $name" }
    }
    if (-not $After.Files.ContainsKey('AppxSignature.p7x')) { throw 'Missing package signature' }
    $allowedTypes = @('<Override PartName="/AppxSignature.p7x" ContentType="application/vnd.ms-appx.signature" xmlns="http://schemas.openxmlformats.org/package/2006/content-types" />', '<Override PartName="/AppxMetadata/CodeIntegrity.cat" ContentType="application/vnd.ms-pkiseccat" xmlns="http://schemas.openxmlformats.org/package/2006/content-types" />')
    $remaining = @($After.ContentTypes | Where-Object { $_ -cnotin $allowedTypes })
    $original = @($Before.ContentTypes | Where-Object { $_ -cnotin $allowedTypes })
    if (Compare-Object @($original | Sort-Object) @($remaining | Sort-Object) -CaseSensitive) { throw 'Unexpected signed content types' }
}
function Assert-WidgetFileBinding($Stream, [string]$Identity, [string]$Digest, [string]$Path) {
    if ([DoorlightSigningFile]::Identity($Stream.SafeFileHandle) -cne $Identity -or (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -cne $Digest) { throw 'Verified package identity or digest changed' }
}
function Invoke-WidgetSignedInstall([string]$Package, [string]$BuildRoot, [string]$Configuration, [string]$SignTool, [string]$Thumbprint, [scriptblock]$Install) {
    $Package = [IO.Path]::GetFullPath($Package)
    if (-not $Package.StartsWith([IO.Path]::GetFullPath($BuildRoot) + '\packages\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Signing package must belong to this build' }
    Assert-WidgetPrivateTree $BuildRoot
    $unsigned = [IO.File]::Open($Package, 'Open', 'Read', 'Read')
    try {
        $identity = [DoorlightSigningFile]::Identity($unsigned.SafeFileHandle)
        $digest = (Get-FileHash -LiteralPath $Package -Algorithm SHA256).Hash
        & "$PSScriptRoot/widget-package.ps1" -Action Verify -BuildRoot $BuildRoot -Configuration $Configuration -Architecture x64
        $inventory = Get-WidgetPackageInventory $Package
        if ($inventory.Files.ContainsKey('AppxSignature.p7x')) { throw 'Signing requires the fresh unsigned build output' }
    } finally { $unsigned.Dispose() }
    # The private ACL excludes other principals; this handle also prevents pathname replacement while SignTool writes.
    $signing = [IO.File]::Open($Package, 'Open', 'Read', 'ReadWrite')
    try {
        Assert-WidgetFileBinding $signing $identity $digest $Package
        & $SignTool sign /q /fd SHA256 /sha1 $Thumbprint $Package
        if ($LASTEXITCODE -ne 0) { throw "Widget signing failed: $LASTEXITCODE" }
        if ([DoorlightSigningFile]::Identity($signing.SafeFileHandle) -cne $identity) { throw 'Signing file identity changed' }
    } finally { $signing.Dispose() }
    $signed = [IO.File]::Open($Package, 'Open', 'Read', 'Read')
    try {
        if ([DoorlightSigningFile]::Identity($signed.SafeFileHandle) -cne $identity) { throw 'Signed package was replaced' }
        Assert-WidgetSignedPayload $inventory (Get-WidgetPackageInventory $Package)
        & $SignTool verify /pa /all /q $Package
        if ($LASTEXITCODE -ne 0) { throw "Widget signature verification failed: $LASTEXITCODE" }
        $signature = Get-AuthenticodeSignature -LiteralPath $Package
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Thumbprint -cne $Thumbprint) { throw 'Unexpected widget signer' }
        $signedHash = (Get-FileHash -LiteralPath $Package -Algorithm SHA256).Hash
        & $Install $Package
        if ((Get-FileHash -LiteralPath $Package).Hash -cne $signedHash) { throw 'Installed package file changed' }
        Write-Output "Verified and installed protected package SHA256 $signedHash"
    } finally { $signed.Dispose() }
}
