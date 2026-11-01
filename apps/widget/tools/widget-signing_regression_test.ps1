param([Parameter(Mandatory)][string]$Package)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/widget-signing.ps1"
$test = Join-Path ([IO.Path]::GetPathRoot($PSScriptRoot)) ('Syb-L-Release/check-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $test | Out-Null
Assert-WidgetPrivateTree $test
$checks = 1
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;
public static class WidgetRestrictedAccessCheck {
    [StructLayout(LayoutKind.Sequential)] struct SidAndAttributes { public IntPtr Sid; public uint Attributes; }
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr process, uint access, out SafeAccessTokenHandle token);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool ConvertStringSidToSid(string text, out IntPtr sid);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool CreateRestrictedToken(SafeAccessTokenHandle token,uint flags,uint disable,IntPtr disabled,uint deletePrivileges,IntPtr deleted,uint count,SidAndAttributes[] restrict,out SafeAccessTokenHandle result);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr value);
    public static void AssertDenied(string directory, string file) {
        SafeAccessTokenHandle original, restricted;
        if(!OpenProcessToken(GetCurrentProcess(),0xE,out original)) throw new System.ComponentModel.Win32Exception();
        using(original) {
            var entries=new SidAndAttributes[3]; var names=new[]{"S-1-1-0","S-1-5-11","S-1-5-32-545"};
            try {
                for(int i=0;i<3;i++) { if(!ConvertStringSidToSid(names[i],out entries[i].Sid)) throw new System.ComponentModel.Win32Exception(); }
                if(!CreateRestrictedToken(original,1,0,IntPtr.Zero,0,IntPtr.Zero,3,entries,out restricted)) throw new System.ComponentModel.Win32Exception();
                using(restricted) WindowsIdentity.RunImpersonated(restricted,()=> {
                    Denied(()=>Directory.GetFileSystemEntries(directory));
                    Denied(()=>{using(var stream=File.Open(file,FileMode.Open,FileAccess.Read)){} });
                    Denied(()=>{using(var stream=File.Open(file,FileMode.Open,FileAccess.Write)){} });
                    Denied(()=>File.Delete(file));
                    Denied(()=>Directory.CreateDirectory(Path.Combine(directory,"untrusted")));
                });
            } finally { foreach(var entry in entries) if(entry.Sid!=IntPtr.Zero) LocalFree(entry.Sid); }
        }
    }
    static void Denied(Action operation) { try { operation(); } catch(UnauthorizedAccessException) { return; } throw new Exception("Ordinary-principal operation unexpectedly allowed"); }
}
'@
function Reject([scriptblock]$Run, [string]$Message) {
    try { & $Run | Out-Null } catch { if ($_.Exception.Message.Contains($Message)) { $script:checks++; return }; throw }
    throw "Expected refusal: $Message"
}
Reject { Assert-WidgetPrivateTree (Split-Path -Parent $PSScriptRoot) } 'Untrusted write'
$copy = Join-Path $test 'widget.msix'
Copy-Item -LiteralPath $Package -Destination $copy
[WidgetRestrictedAccessCheck]::AssertDenied($test, $copy)
$checks += 5
$before = Get-WidgetPackageInventory $copy
Assert-WidgetSignedPayload $before $before
$checks++
$stream = [IO.File]::Open($copy,'Open','Read','Read')
try {
    $identity = [DoorlightSigningFile]::Identity($stream.SafeFileHandle)
    $digest = (Get-FileHash -LiteralPath $copy).Hash
    Assert-WidgetFileBinding $stream $identity $digest $copy
    $checks++
    Reject { [IO.File]::OpenWrite($copy).Dispose() } 'another process'
    Reject { [IO.File]::Move($copy, (Join-Path $test 'replaced.msix')) } 'another process'
} finally { $stream.Dispose() }
$link = Join-Path $test 'linked.msix'
New-Item -ItemType HardLink -Path $link -Target $copy | Out-Null
$stream = [IO.File]::OpenRead($link)
try { Reject { [DoorlightSigningFile]::Identity($stream.SafeFileHandle) } 'one link' } finally { $stream.Dispose() }
# Remove only the test alias, never the original package or retained signing material.
Remove-Item -LiteralPath $link
$replacement = Join-Path $test 'replacement.msix'
Copy-Item -LiteralPath $copy -Destination $replacement
$stream = [IO.File]::OpenRead($replacement)
try { Reject { Assert-WidgetFileBinding $stream $identity $digest $replacement } 'identity or digest changed' } finally { $stream.Dispose() }
$write = [IO.File]::Open($copy,'Open','Write','None')
try { $write.WriteByte(0) } finally { $write.Dispose() }
$stream = [IO.File]::OpenRead($copy)
try { Reject { Assert-WidgetFileBinding $stream $identity $digest $copy } 'identity or digest changed' } finally { $stream.Dispose() }
Copy-Item -LiteralPath $Package -Destination $copy -Force
$zip = [IO.Compression.ZipFile]::Open($copy, 'Update')
try {
    $entry = $zip.GetEntry('WidgetSampleCS.exe'); $entry.Delete(); $entry = $zip.CreateEntry('WidgetSampleCS.exe')
    $write=$entry.Open(); try { $write.WriteByte(0) } finally { $write.Dispose() }
} finally { $zip.Dispose() }
Reject { Assert-WidgetSignedPayload $before (Get-WidgetPackageInventory $copy) } 'Payload changed'
$junction = Join-Path $test 'redirect'
New-Item -ItemType Junction -Path $junction -Target (Split-Path -Parent $PSScriptRoot) | Out-Null
Reject { Assert-WidgetAcl $junction } 'Reparse point'
$acl = Get-Acl $copy
$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),'Write','Allow'))
Set-Acl -LiteralPath $copy -AclObject $acl
Reject { Assert-WidgetAcl $copy } 'Untrusted write'
Write-Output "$checks signing boundary and legitimate-control checks passed."
