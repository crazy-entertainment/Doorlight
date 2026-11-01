param(
    [ValidateSet('Build','Update')][string]$Action = 'Build',
    [ValidatePattern('^$|^\d+\.\d+\.\d+$')][string]$Version = '',
    [ValidateSet('Debug','Release')][string]$Configuration = 'Release',
    [string]$VisualStudioPath = $env:VSINSTALLDIR
)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$previousLocation = Get-Location
$previousEnvironment = @{}
foreach ($name in @('PATH','TEMP','TMP','VSINSTALLDIR','VCINSTALLDIR','VCTargetsPath','MSBUILDDISABLENODEREUSE')) { $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
try {
Set-Location -LiteralPath $repo
$root = Join-Path $repo 'apps/widget'
$releaseHome = Join-Path ([IO.Path]::GetPathRoot($repo)) 'Syb-L-Release'
$protectedSource = $repo.StartsWith($releaseHome + '\', [StringComparison]::OrdinalIgnoreCase)
if ($Action -eq 'Update' -and -not $protectedSource) {
    throw 'Signing is disabled in the development checkout. Run widget-dev.ps1 from the reviewed protected release workspace.'
}
if ($protectedSource) {
    . "$PSScriptRoot/widget-signing.ps1"
    Assert-WidgetPrivateTree $repo
    $visualStudio = Join-Path $releaseHome 'toolchain/vs2022'
    if (-not (Test-Path -LiteralPath (Join-Path $visualStudio 'verified-copy.json'))) { throw 'Private toolchain copy is incomplete' }
    foreach ($trusted in @($visualStudio, $PSHOME, 'C:/Program Files/dotnet', 'C:/Program Files (x86)/Windows Kits/10', "$env:USERPROFILE/.nuget")) { Assert-WidgetPrivateTree $trusted }
    $env:PATH = "$PSHOME;C:\Program Files\dotnet;C:\Windows\System32;C:\Windows"
    $env:VSINSTALLDIR = $visualStudio + '\'
    $env:VCINSTALLDIR = Join-Path $visualStudio 'VC/'
    $env:VCTargetsPath = Join-Path $visualStudio 'MSBuild/Microsoft/VC/v170/'
    $env:MSBUILDDISABLENODEREUSE = '1'
    $env:TEMP = $env:TMP = Join-Path $repo 'local/tmp/system-temp'
    New-Item -ItemType Directory -Path $env:TEMP -Force | Out-Null
} else {
    if (-not $VisualStudioPath) {
        $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
        if (Test-Path -LiteralPath $vswhere) {
            $VisualStudioPath = & $vswhere -latest -products '*' -requires Microsoft.Component.MSBuild -property installationPath
            if ($LASTEXITCODE -ne 0) { throw 'Visual Studio discovery failed.' }
        }
    }
    if (-not $VisualStudioPath) { throw 'Specify -VisualStudioPath for the Visual Studio installation.' }
    $visualStudio = $VisualStudioPath
}
$msbuild = Join-Path $visualStudio 'MSBuild/Current/Bin/amd64/MSBuild.exe'
$manifest = Join-Path $root 'app/Package.appxmanifest'
if (!$Version) {
    $candidateVersion = [version]([xml][IO.File]::ReadAllText($manifest)).Package.Identity.Version
    if ($Action -eq 'Update') {
        $currentPackage = Get-AppxPackage DoorlightOverlayProto
        if ($currentPackage -and [version]$currentPackage.Version -ge $candidateVersion) {
            $candidateVersion = [version]$currentPackage.Version
            if ($candidateVersion.Build -ge 65535) { throw 'Choose the next widget minor version explicitly.' }
            $candidateVersion = [version]::new($candidateVersion.Major, $candidateVersion.Minor, $candidateVersion.Build + 1, 0)
        }
    }
    $Version = "$($candidateVersion.Major).$($candidateVersion.Minor).$($candidateVersion.Build)"
}
$manifestText = [IO.File]::ReadAllText($manifest) -replace '(?s)(<Identity.*?Version=")[\d.]+(")', "`${1}$Version.0`$2"
[IO.File]::WriteAllText($manifest, $manifestText)
$buildRoot = Join-Path $repo ('local/tmp/widget-build/' + [guid]::NewGuid().ToString('N'))
& $msbuild "$root/app/WidgetSampleCS.csproj" /restore /p:RestoreLockedMode=true "/p:RestoreConfigFile=$root/NuGet.Config" "/p:RestorePackagesPath=$repo/local/dev/nuget" /p:ImportDirectoryBuildProps=false /p:ImportDirectoryBuildTargets=false /p:ImportDirectoryPackagesProps=false "/p:Configuration=$Configuration" /p:Platform=x64 "/p:DoorlightBuildRoot=$buildRoot" /m /nodeReuse:false /v:quiet /nologo
if ($LASTEXITCODE -ne 0) { throw "Widget build failed: $LASTEXITCODE" }
& "$PSScriptRoot/widget-package.ps1" -Action Verify -BuildRoot $buildRoot -Configuration $Configuration -Architecture x64
$packages = @(Get-ChildItem -LiteralPath (Join-Path $buildRoot 'packages') -Recurse -File -Filter *.msix)
if ($packages.Count -ne 1) { throw 'Expected exactly one freshly built widget package' }
if ($Action -eq 'Build') {
    if ($protectedSource) { Write-Output "Protected unsigned candidate SHA256 $((Get-FileHash -LiteralPath $packages[0].FullName).Hash): $($packages[0].FullName)" }
    return
}
$certificate = @(Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq 'CN=DoorlightProto' -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) })
if ($certificate.Count -ne 1) { throw 'Expected the retained development signer; no signing material was created or changed' }
$signTool = Get-ChildItem 'C:/Program Files (x86)/Windows Kits/10/bin/*/x64/signtool.exe' | Sort-Object FullName | Select-Object -Last 1
Invoke-WidgetSignedInstall -Package $packages[0].FullName -BuildRoot $buildRoot -Configuration $Configuration -SignTool $signTool.FullName -Thumbprint $certificate[0].Thumbprint -Install {
    param($protectedPackage)
    $previous = Get-AppxPackage DoorlightOverlayProto
    if ($previous) {
        foreach ($processName in @('WidgetSampleCS','helper')) {
            Get-Process -Name $processName -ErrorAction SilentlyContinue | Where-Object {
                $_.Path -and $_.Path.StartsWith($previous.InstallLocation + '\', [StringComparison]::OrdinalIgnoreCase)
            } | Stop-Process -Force
        }
    }
    Add-AppxPackage -Path $protectedPackage -ForceApplicationShutdown
}
$installed = Get-AppxPackage DoorlightOverlayProto
if ($installed.Version.ToString() -ne "$Version.0") { throw 'Installed widget version differs from the candidate' }
Start-Process "ms-gamebar://launch/activate/$($installed.PackageFamilyName)_App_Helper" -WindowStyle Hidden
Write-Output "Installed Doorlight widget $($installed.Version) from tracked source."
} finally {
    Set-Location -LiteralPath $previousLocation.Path
    foreach ($name in $previousEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process') }
}
