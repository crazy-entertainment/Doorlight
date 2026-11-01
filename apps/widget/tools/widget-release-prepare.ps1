param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$Revision,
    [Parameter(Mandatory)][string]$SourceRepository,
    [Parameter(Mandatory)][string]$VisualStudioPath
)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. "$PSScriptRoot/widget-signing.ps1"
$homeDirectory = Join-Path ([IO.Path]::GetPathRoot($repo)) 'Syb-L-Release'
if (-not (Test-Path -LiteralPath $homeDirectory)) { [DoorlightSigningFile]::CreatePrivateDirectory($homeDirectory, $script:WidgetOwner) }
Assert-WidgetAncestors $homeDirectory
Assert-WidgetAcl $homeDirectory
$git = 'C:/Program Files/Git/cmd/git.exe'
Assert-WidgetPrivateTree 'C:/Program Files/Git'
$source = Join-Path $homeDirectory "revisions/$Revision"
if (Test-Path -LiteralPath $source) { throw 'Release source must be a new reviewed snapshot.' }
New-Item -ItemType Directory -Path $source | Out-Null
# Export immutable reviewed objects, never the working tree or ignored build outputs.
$env:GIT_NO_REPLACE_OBJECTS = '1'
$env:GIT_NO_LAZY_FETCH = '1'
$env:GIT_TERMINAL_PROMPT = '0'
& $git -C $SourceRepository fsck --strict --no-reflogs --no-dangling $Revision
if ($LASTEXITCODE -ne 0) { throw 'Git object integrity check failed' }
$archive = Join-Path $source 'reviewed-source.zip'
$paths = @('apps/widget', 'apps/doorlight/assets/companion-links.json')
& $git -C $SourceRepository -c core.autocrlf=false archive --format=zip "--output=$archive" $Revision -- @paths
if ($LASTEXITCODE -ne 0) { throw 'Reviewed source export failed' }
[IO.Compression.ZipFile]::ExtractToDirectory($archive, $source)
foreach ($entry in (& $git -C $SourceRepository ls-tree -r $Revision -- @paths)) {
    if ($entry -notmatch '^100644 blob ([0-9a-f]{40})\t(.+)$') { throw "Unsupported release source entry: $entry" }
    $expected = $Matches[1]; $file = Join-Path $source $Matches[2]
    $bytes = [IO.File]::ReadAllBytes($file)
    $sha = [Security.Cryptography.SHA1]::Create()
    try {
        $header = [Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
        [void]$sha.TransformBlock($header,0,$header.Length,$null,0)
        [void]$sha.TransformFinalBlock($bytes,0,$bytes.Length)
        if ([Convert]::ToHexString($sha.Hash).ToLowerInvariant() -cne $expected) { throw "Reviewed source mismatch: $file" }
    } finally { $sha.Dispose() }
}
$toolchain = Join-Path $homeDirectory 'toolchain/vs2022'
if (-not (Test-Path -LiteralPath $toolchain)) {
    $original = [IO.Path]::GetFullPath($VisualStudioPath)
    $locks = [Collections.Generic.List[IDisposable]]::new()
    try {
        # The installed tool files are protected, but their shared parent can be renamed.
        $chain = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
        $ancestor = [IO.DirectoryInfo]$original
        while ($ancestor) { $chain.Push($ancestor); $ancestor = $ancestor.Parent }
        foreach ($ancestor in $chain) {
            if ((Get-Item -LiteralPath $ancestor.FullName -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse point in toolchain source' }
            $locks.Add([DoorlightSigningFile]::LockDirectory($ancestor.FullName))
        }
        Assert-WidgetAcl $original
        foreach ($item in Get-ChildItem -LiteralPath $original -Recurse -Force) { Assert-WidgetAcl $item.FullName }
        New-Item -ItemType Directory -Path $toolchain | Out-Null
        & C:/Windows/System32/robocopy.exe $original $toolchain /E /COPY:DAT /DCOPY:DAT /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NP
        if ($LASTEXITCODE -ge 8) { throw 'Private toolchain copy failed' }
        foreach ($file in Get-ChildItem -LiteralPath $original -Recurse -File) {
            $relative = [IO.Path]::GetRelativePath($original, $file.FullName)
            if ((Get-FileHash -LiteralPath $file.FullName).Hash -cne (Get-FileHash -LiteralPath (Join-Path $toolchain $relative)).Hash) { throw "Private toolchain mismatch: $relative" }
        }
        [ordered]@{ source=$original; files=@(Get-ChildItem -LiteralPath $toolchain -Recurse -File).Count; msbuildSha256=(Get-FileHash -LiteralPath (Join-Path $toolchain 'MSBuild/Current/Bin/amd64/MSBuild.exe')).Hash } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $toolchain 'verified-copy.json')
    } finally { foreach ($handle in $locks) { $handle.Dispose() } }
}
if (-not (Test-Path -LiteralPath (Join-Path $toolchain 'verified-copy.json'))) { throw 'Private toolchain copy is incomplete; preserve it for diagnosis.' }
Assert-WidgetPrivateTree $toolchain
Assert-WidgetPrivateTree $source
Write-Output "Reviewed protected source: $source"
Write-Output "Release entry point: $source/apps/widget/tools/widget-dev.ps1 -Action Update"
