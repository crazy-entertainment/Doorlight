param([string]$OutputDir = 'C:/Users/Osman/AppData/Local/Temp/Doorlight-scale-native-ui-20261101', [switch]$Harness, [string]$VsDevCmd)
$ErrorActionPreference = 'Stop'
$vs = & (Join-Path $PSScriptRoot '../windows-toolchain.ps1') -VsDevCmd $VsDevCmd
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$source = $PSScriptRoot
$batch = Join-Path $OutputDir 'build-native-ui.cmd'
$commands = @("@echo off", "call `"$vs`" -arch=x64 -host_arch=x64 >nul", 'if errorlevel 1 exit /b 1', "cl /nologo /c /std:c++17 /O2 /MT /EHsc /W4 /DUNICODE /D_UNICODE /Fo`"$OutputDir/doorlight_ui.obj`" `"$source/doorlight_ui.cpp`"", 'if errorlevel 1 exit /b 1', "lib /nologo /OUT:`"$OutputDir/doorlight_ui.lib`" `"$OutputDir/doorlight_ui.obj`"", 'if errorlevel 1 exit /b 1')
if ($Harness) { $commands += "cl /nologo /std:c++17 /O2 /MT /EHsc /DUNICODE /D_UNICODE /Fo`"$OutputDir/harness.obj`" /Fe`"$OutputDir/harness.exe`" `"$source/harness.cpp`" `"$OutputDir/doorlight_ui.lib`" gdiplus.lib dwmapi.lib user32.lib gdi32.lib shell32.lib /link /SUBSYSTEM:WINDOWS"; $commands += 'if errorlevel 1 exit /b 1' }
[IO.File]::WriteAllLines($batch,$commands)
& cmd.exe /d /c $batch
if ($LASTEXITCODE -ne 0) { throw 'Native UI build failed.' }
Get-Item (Join-Path $OutputDir 'doorlight_ui.lib') | Select-Object FullName,Length
