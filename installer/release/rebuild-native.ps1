#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$Workspace,
    [string]$Python,
    [string]$CMake,
    [string]$VsDevCmd,
    [string]$MsysBash,
    [string]$Perl,
    [string]$Yasm,
    [string]$Nasm,
    [string]$MSBuildTargets,
    [ValidateRange(1,16)][int]$Jobs = 4,
    [switch]$ValidateOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-NoLinks([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        try {
            if ((Get-Item -LiteralPath $current -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Linked/reparse build paths are not accepted.'
            }
        } catch [Management.Automation.ItemNotFoundException] { }
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent) { break }
        $current = $parent.FullName
    }
}

function Full-Path([string]$Value) {
    # These paths will also be quoted in a cmd script; reject expansion characters.
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -match '[%"!\x00-\x1f]') {
        throw 'A required path is missing or contains unsupported shell characters.'
    }
    $result = [IO.Path]::GetFullPath($Value)
    Assert-NoLinks $result
    return $result
}

function Require-File([string]$Path) {
    Assert-NoLinks $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'A required build input is missing.' }
}

function Tool-Path([string]$Value, [string]$Name) {
    $path = Full-Path $Value
    Require-File $path
    if ([IO.Path]::GetFileName($path) -ine $Name) { throw "Expected executable $Name." }
    $stream = [IO.File]::OpenRead($path)
    try {
        if ($stream.ReadByte() -ne 77 -or $stream.ReadByte() -ne 90) { throw 'Build tool is not a Windows executable.' }
    } finally { $stream.Dispose() }
    return $path
}

$Workspace = Full-Path $Workspace
if (-not (Test-Path -LiteralPath $Workspace -PathType Container)) { throw 'Workspace directory is missing.' }
$source = Join-Path $Workspace 'source/jami-daemon'
$vendor = Join-Path $Workspace 'source/vendor'
foreach ($directory in @($source, $vendor)) {
    Assert-NoLinks $directory
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw 'Workspace source layout is incomplete.' }
}
Require-File (Join-Path $Workspace 'source-manifest.json')
$proof = Join-Path $PSScriptRoot 'native-provenance.py'
Require-File $proof
$Python = Tool-Path $Python 'python.exe'
$CMake = Tool-Path $CMake 'cmake.exe'
$ctest = Tool-Path (Join-Path (Split-Path $CMake -Parent) 'ctest.exe') 'ctest.exe'
$MsysBash = Tool-Path $MsysBash 'bash.exe'
$Perl = Tool-Path $Perl 'perl.exe'
$Yasm = Tool-Path $Yasm 'yasm.exe'
$Nasm = Tool-Path $Nasm 'nasm.exe'
$tar = Tool-Path (Join-Path $env:SystemRoot 'System32/tar.exe') 'tar.exe'
$VsDevCmd = Full-Path $VsDevCmd
Require-File $VsDevCmd
if ([IO.Path]::GetFileName($VsDevCmd) -ine 'VsDevCmd.bat') { throw 'Expected the installed VsDevCmd.bat.' }
$vsRoot = Split-Path (Split-Path (Split-Path $VsDevCmd -Parent) -Parent) -Parent
if (-not (Test-Path -LiteralPath (Join-Path $vsRoot 'VC') -PathType Container)) {
    throw 'VsDevCmd must belong to an installed Visual Studio Common7/Tools directory.'
}
$MSBuildTargets = Full-Path $MSBuildTargets
if ($MSBuildTargets.TrimEnd('\') -ieq $vsRoot.TrimEnd('\') -or
    $MSBuildTargets.StartsWith($vsRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Use an external private MSBuild targets overlay, not the installed Visual Studio tree.'
}
foreach ($relative in @('Microsoft.Cpp.Default.props','Microsoft.Cpp.props','Microsoft.Cpp.targets',
        'BuildCustomizations/yasm.props','BuildCustomizations/yasm.targets','BuildCustomizations/yasm.xml',
        'BuildCustomizations/nasm.props','BuildCustomizations/nasm.targets','BuildCustomizations/nasm.xml')) {
    Require-File (Join-Path $MSBuildTargets $relative)
}

# Reuse the source-delivery checks; neither compiler output nor old build evidence
# is needed to verify a freshly unpacked source snapshot.
$check = @'
import importlib.util, json, pathlib, sys
spec = importlib.util.spec_from_file_location('native_provenance', sys.argv[1])
p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p)
w = pathlib.Path(sys.argv[2])
m = json.loads((w / 'source-manifest.json').read_text(encoding='utf-8-sig'))
packages = m['dependencySourceManifest']['packages']
p.need(len(packages) == 32 and len({entry['name'] for entry in packages}) == 32, 'Expected 32 distinct dependency originals')
p.verify_sources(w, w, m)
p.verify_archives(w, w, m)
p.verify_expected_lite(w / 'source/jami-daemon')
p.verify_gnutls_submodules(w / 'source/jami-daemon')
print('Source snapshot, vendored build tool, 32 original archives, 3 GnuTLS submodule archives and expected-lite verified.')
'@
& $Python -B -c $check $proof $Workspace
if ($LASTEXITCODE -ne 0) { throw 'Source snapshot validation failed.' }
if ($ValidateOnly) {
    Write-Host 'Validation passed. No build, environment changes or output writes performed.'
    return
}

foreach ($relative in @('build-core','source/jami-daemon/contrib/build','source/jami-daemon/contrib/msvc')) {
    if (Test-Path -LiteralPath (Join-Path $Workspace $relative)) {
        throw 'Build output already exists. Keep this attempt and unpack a fresh source workspace.'
    }
}
$drive = Get-PSDrive -Name ([IO.Path]::GetPathRoot($Workspace).TrimEnd('\').TrimEnd(':'))
if ($drive.Free -lt 10GB) { throw 'Native rebuild requires at least 10 GiB free on the workspace drive.' }
$lockPath = Join-Path $Workspace '.native-rebuild.lock'
Assert-NoLinks $lockPath
$lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    $attempt = Join-Path $Workspace ('logs/rebuild-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [Guid]::NewGuid().ToString('N'))
    Assert-NoLinks $attempt
    [IO.Directory]::CreateDirectory($attempt) | Out-Null
    $temporary = Join-Path $Workspace 'tmp'
    Assert-NoLinks $temporary
    [IO.Directory]::CreateDirectory($temporary) | Out-Null
    $build = Join-Path $Workspace 'build-core'
    $toolPath = (@($Python,$CMake,$Perl,$Yasm,$Nasm) | ForEach-Object { Split-Path $_ -Parent } | Select-Object -Unique) -join ';'
    $lines = @(
        '@echo off', 'setlocal DisableDelayedExpansion', 'chcp 65001 >nul',
        ('call "{0}" -arch=x64 -host_arch=x64 >nul' -f $VsDevCmd), 'if errorlevel 1 exit /b %errorlevel%',
        ('set "PYTHONPATH={0}"' -f $vendor), ('set "PYWINMAKE_MAX_JOBS={0}"' -f $Jobs),
        ('set "CMAKE_BUILD_PARALLEL_LEVEL={0}"' -f $Jobs), ('set "MSYS2_BIN={0}"' -f $MsysBash),
        'set "MSYS2_PATH_TYPE=inherit"', ('set "YASMPATH={0}\"' -f (Split-Path $Yasm -Parent).TrimEnd('\')),
        ('set "NASMPATH={0}\"' -f (Split-Path $Nasm -Parent).TrimEnd('\')),
        ('set "VCTargetsPath={0}\"' -f $MSBuildTargets.TrimEnd('\')), ('set "PATH={0};%PATH%"' -f $toolPath),
        ('set "TEMP={0}"' -f $temporary), ('set "TMP={0}"' -f $temporary), ('cd /d "{0}"' -f $source),
        ('"{0}" extras\scripts\winmake.py --base-dir "{1}" -l 4 resolve' -f $Python,$source),
        'if errorlevel 1 exit /b %errorlevel%',
        ('"{0}" -S "{1}" -B "{2}" -G "Visual Studio 17 2022" -A x64 "-DCMAKE_GENERATOR_INSTANCE={3}" -DBUILD_CONTRIB=OFF -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=ON' -f $CMake,$source,$build,$vsRoot),
        'if errorlevel 1 exit /b %errorlevel%',
        ('"{0}" --build "{1}" --config Release --target jami-core ut_audio_transmission_gate --parallel {2}' -f $CMake,$build,$Jobs),
        'if errorlevel 1 exit /b %errorlevel%',
        ('"{0}" --test-dir "{1}" -C Release -R "^audio_transmission_gate$" --output-on-failure --no-tests=error' -f $ctest,$build),
        'exit /b %errorlevel%'
    )
    $command = Join-Path $attempt 'rebuild.cmd'
    [IO.File]::WriteAllLines($command, $lines, [Text.UTF8Encoding]::new($false))
    $process = Start-Process -FilePath $env:ComSpec -ArgumentList ('/d /q /c ""{0}""' -f $command) -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput (Join-Path $attempt 'stdout.log') -RedirectStandardError (Join-Path $attempt 'stderr.log')
    [IO.File]::WriteAllText((Join-Path $attempt 'exit-code.txt'), [string]$process.ExitCode)
    if ($process.ExitCode -ne 0) { throw "Native rebuild failed; preserve evidence at $attempt." }
    Write-Host "Native library and audio gate test built successfully. Evidence: $attempt"
} finally { $lock.Dispose() }
