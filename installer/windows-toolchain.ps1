param([string]$VsDevCmd)
$ErrorActionPreference = 'Stop'
if (-not $VsDevCmd) {
    $localToolchain = 'F:/WORK/Creations/DevTools/VisualStudio2022/Common7/Tools/VsDevCmd.bat'
    if (Test-Path -LiteralPath $localToolchain) { $VsDevCmd = $localToolchain }
    else {
        $locator = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
        if (-not (Test-Path -LiteralPath $locator)) { throw 'Visual Studio C++ Build Tools are required.' }
        $installation = & $locator -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($LASTEXITCODE -ne 0 -or -not $installation) { throw 'Visual Studio C++ Build Tools were not found.' }
        $VsDevCmd = Join-Path $installation 'Common7/Tools/VsDevCmd.bat'
    }
}
if ($VsDevCmd -match '["%&|<>^\r\n]' -or -not (Test-Path -LiteralPath $VsDevCmd -PathType Leaf)) {
    throw 'Invalid Visual Studio toolchain path.'
}
(Resolve-Path -LiteralPath $VsDevCmd).Path
