$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'windows-native-inputs.ps1')
Add-Type -AssemblyName System.IO.Compression

function Assert-True([bool]$Value, [string]$Message) {
    if (-not $Value) { throw "Assertion failed: $Message" }
}

function Assert-Throws([scriptblock]$Action, [string]$Message, [string]$Contains = '') {
    try { & $Action } catch {
        if ($Contains -and $_.Exception.Message -notlike "*$Contains*") { throw "Unexpected exception for '$Message': $($_.Exception.Message)" }
        return
    }
    throw "Expected rejection: $Message"
}

function New-Fixture([string]$Root, [switch]$OmitLastLibrary) {
    $scopes = Get-NativeInputScopes
    foreach ($scope in $scopes) {
        $path = Join-Path $Root ($scope.Path.Replace('/', [IO.Path]::DirectorySeparatorChar))
        if ($scope.Kind -eq 'File') {
            New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
            [IO.File]::WriteAllText($path, "fixture:$($scope.Path)")
            continue
        }
        if ($OmitLastLibrary -and $scope.Kind -eq 'Libraries' -and $scope.Path -eq $scopes[-1].Path) { continue }
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        $name = switch ($scope.Kind) { 'Headers' { 'fixture.h' }; 'Notices' { 'LICENSE.txt' }; default { 'fixture.lib' } }
        [IO.File]::WriteAllText((Join-Path $path $name), "fixture:$($scope.Path)")
    }
    $pins = @{}
    foreach ($pin in (Get-ProductionPins).Keys) {
        $pinPath = Join-Path $Root ($pin.Replace('/', [IO.Path]::DirectorySeparatorChar))
        $pins[$pin] = (Get-FileHash -LiteralPath $pinPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    return $pins
}

function New-ManualZip([string]$Path, [object[]]$Entries) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($item in $Entries) {
                $entry = $zip.CreateEntry($item.Name)
                if ($item.ContainsKey('Attributes') -and $item.Attributes) { $entry.ExternalAttributes = $item.Attributes }
                $content = $entry.Open()
                try { $bytes = [Text.Encoding]::UTF8.GetBytes($item.Content); $content.Write($bytes, 0, $bytes.Length) }
                finally { $content.Dispose() }
            }
        } finally { $zip.Dispose() }
    } finally { $stream.Dispose() }
}

function Rewrite-ZipEntry([string]$Source, [string]$Destination, [string]$Name, [string]$Content) {
    $inputZip = [IO.Compression.ZipFile]::OpenRead($Source)
    $stream = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $outputZip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($sourceEntry in $inputZip.Entries) {
                $entry = $outputZip.CreateEntry($sourceEntry.FullName)
                $entry.ExternalAttributes = $sourceEntry.ExternalAttributes
                $output = $entry.Open()
                try {
                    if ($sourceEntry.FullName -ceq $Name) {
                        $bytes = [Text.Encoding]::UTF8.GetBytes($Content)
                        $output.Write($bytes, 0, $bytes.Length)
                    } else {
                        $input = $sourceEntry.Open()
                        try { $input.CopyTo($output) } finally { $input.Dispose() }
                    }
                } finally { $output.Dispose() }
            }
        } finally { $outputZip.Dispose() }
    } finally { $stream.Dispose(); $inputZip.Dispose() }
}

$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$scratchRoot = [IO.Path]::GetFullPath((Join-Path $repo 'local/tmp'))
if (-not (Test-Path -LiteralPath $scratchRoot -PathType Container)) { throw "Expected project scratch directory: $scratchRoot" }
$scratch = Join-Path $scratchRoot ('windows-native-inputs-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($scratch)
try {
    $source = Join-Path $scratch 'source'
    [void][IO.Directory]::CreateDirectory($source)
    $pins = New-Fixture $source
    $zip = Join-Path $scratch 'native-inputs.zip'
    $manifest = Join-Path $scratch 'native-inputs.json'
    $target = Join-Path $scratch 'expanded'

    $receipt = New-NativeInputPackage $source $zip $manifest $pins
    Assert-True (Test-Path -LiteralPath $zip -PathType Leaf) 'pack creates zip'
    Assert-True (Test-Path -LiteralPath $manifest -PathType Leaf) 'pack creates sidecar manifest'
    $expanded = Expand-NativeInputPackage $zip $manifest $target $pins
    Assert-True ($expanded.Files -gt 3) 'expand validates and extracts every scoped input'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $target 'build/lib/jami-core.lib')).Hash.ToLowerInvariant() -ceq $pins['build/lib/jami-core.lib']) 'core archive round-trips'

    $badHashZip = Join-Path $scratch 'bad-hash.zip'
    Rewrite-ZipEntry $zip $badHashZip 'contrib/build/jsoncpp/include/fixture.h' 'changed:contrib/build/jsoncpp/include'
    Assert-Throws { Expand-NativeInputPackage $badHashZip $manifest (Join-Path $scratch 'bad-hash-out') $pins } 'file hash mismatch' 'hash mismatch'

    $badSidecar = Join-Path $scratch 'bad-sidecar.json'
    [IO.File]::WriteAllText($badSidecar, ([IO.File]::ReadAllText($manifest) + ' '))
    Assert-Throws { Expand-NativeInputPackage $zip $badSidecar (Join-Path $scratch 'bad-sidecar-out') $pins } 'sidecar mismatch' 'differs from the embedded'

    $badPin = @{} + $pins
    $badPin['build/lib/jami-core.lib'] = '0' * 64
    Assert-Throws { Expand-NativeInputPackage $zip $manifest (Join-Path $scratch 'bad-pin-out') $badPin } 'pinned core mismatch' 'Pinned native input'

    $missingSource = Join-Path $scratch 'missing'
    [void][IO.Directory]::CreateDirectory($missingSource)
    [void](New-Fixture $missingSource -OmitLastLibrary)
    Assert-Throws { New-NativeInputPackage $missingSource (Join-Path $scratch 'missing.zip') (Join-Path $scratch 'missing.json') $pins } 'missing required CMake link directory' 'directory is missing'

    $traversalZip = Join-Path $scratch 'traversal.zip'
    New-ManualZip $traversalZip @(
        @{ Name = '../escape.lib'; Content = 'escape' }
        @{ Name = 'native-inputs.json'; Content = '{"schema":1,"files":[]}' }
    )
    [IO.File]::WriteAllText((Join-Path $scratch 'traversal.json'), '{"schema":1,"files":[]}')
    Assert-Throws { Expand-NativeInputPackage $traversalZip (Join-Path $scratch 'traversal.json') (Join-Path $scratch 'traversal-out') $pins } 'path traversal' 'Invalid native input path'

    $duplicateZip = Join-Path $scratch 'duplicate.zip'
    New-ManualZip $duplicateZip @(
        @{ Name = 'build/lib/jami-core.lib'; Content = 'first' }
        @{ Name = 'build/lib/jami-core.lib'; Content = 'second' }
        @{ Name = 'native-inputs.json'; Content = '{"schema":1,"files":[]}' }
    )
    [IO.File]::WriteAllText((Join-Path $scratch 'duplicate.json'), '{"schema":1,"files":[]}')
    Assert-Throws { Expand-NativeInputPackage $duplicateZip (Join-Path $scratch 'duplicate.json') (Join-Path $scratch 'duplicate-out') $pins } 'duplicate archive path' 'Duplicate archive path'

    $linkZip = Join-Path $scratch 'link.zip'
    New-ManualZip $linkZip @(
        @{ Name = 'build/lib/jami-core.lib'; Content = 'link'; Attributes = (0xA000 -shl 16) }
        @{ Name = 'native-inputs.json'; Content = '{"schema":1,"files":[]}' }
    )
    [IO.File]::WriteAllText((Join-Path $scratch 'link.json'), '{"schema":1,"files":[]}')
    Assert-Throws { Expand-NativeInputPackage $linkZip (Join-Path $scratch 'link.json') (Join-Path $scratch 'link-out') $pins } 'archive symlink' 'Archive links are not allowed'

    Write-Output 'Windows native input tooling synthetic checks passed.'
} finally {
    $resolvedScratch = [IO.Path]::GetFullPath($scratch)
    if (-not $resolvedScratch.StartsWith($scratchRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing to remove test scratch outside local/tmp.' }
    Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
}
