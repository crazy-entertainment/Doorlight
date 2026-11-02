param(
    [Parameter(Mandatory)][string]$FeedConfig,
    [Parameter(Mandatory)][string]$TrustRoot,
    [Parameter(Mandatory)][string]$TrustVerifier,
    [Parameter(Mandatory)][string]$DeltaToolsConfig,
    [Parameter(Mandatory)][string]$NativeLibrary,
    [Parameter(Mandatory)][string]$UpdaterNoticesDirectory,
    [Parameter(Mandatory)][string]$OutputDir,
    [string]$InnoCompiler = 'C:/Program Files (x86)/Inno Setup 6/ISCC.exe'
)
$ErrorActionPreference = 'Stop'
$output = [IO.Path]::GetFullPath($OutputDir)
if (Test-Path -LiteralPath $output) { throw 'Use a new fixture output directory.' }
if ($output -notmatch '(?i)fixture') { throw 'Use an explicitly named fixture output directory.' }
$configPath = (Resolve-Path -LiteralPath $FeedConfig).Path
$rootPath = (Resolve-Path -LiteralPath $TrustRoot).Path
$verifier = (Resolve-Path -LiteralPath $TrustVerifier).Path
$native = (Resolve-Path -LiteralPath $NativeLibrary).Path
$notices = (Resolve-Path -LiteralPath $UpdaterNoticesDirectory).Path
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$verifierHash = '2ca69b25e2b0c823dedd4c44a818282693ce7538fa9216ea0550f99bb499b6d3'
if ($config.schema -ne 1 -or $config.verifierSha256 -cne $verifierHash -or
    (Get-FileHash -LiteralPath $verifier).Hash.ToLowerInvariant() -cne $verifierHash -or
    $config.verifierLength -ne (Get-Item -LiteralPath $verifier).Length -or
    $config.rootSha256 -cne (Get-FileHash -LiteralPath $rootPath).Hash.ToLowerInvariant() -or
    $config.updaterVersion -notmatch '^\d+\.\d+\.\d+$') { throw 'The fixture inputs do not match the pinned verifier and public root.' }
foreach ($url in @($config.metadataUrl, $config.targetsUrl)) {
    $uri = [Uri]::new($url)
    if (!$uri.IsAbsoluteUri -or !$uri.IsLoopback -or $uri.Scheme -ne 'http') { throw 'This fixture builder permits only local HTTP test feeds.' }
}
$tools = Get-Content -LiteralPath $DeltaToolsConfig -Raw | ConvertFrom-Json
if ((Get-FileHash -LiteralPath $tools.PatchExe).Hash -ne '9b5d28a356446c6ab61c0ec8f808fcb8a92af3cd0623a6d8fc634f1a5a1e6580') { throw 'Pinned patch codec mismatch.' }
New-Item -ItemType Directory -Path $output | Out-Null
function Compress([string]$source, [string]$target) {
    $inputStream = [IO.File]::OpenRead($source); $outputStream = [IO.File]::Create($target)
    try {
        $stream = [IO.Compression.BrotliStream]::new($outputStream, [IO.Compression.CompressionLevel]::Optimal, $true)
        try { $inputStream.CopyTo($stream) } finally { $stream.Dispose() }
    } finally { $inputStream.Dispose(); $outputStream.Dispose() }
}
$trustCompressed = Join-Path $output 'Doorlight.Trust.exe.br'
$deltaCompressed = Join-Path $output 'Doorlight.Delta.exe.br'
Compress $verifier $trustCompressed; Compress $tools.PatchExe $deltaCompressed
$artifacts = (Join-Path $output 'artifacts').Replace('\','/')
$publish = Join-Path $output 'publish'
$properties = [ordered]@{DefineConstants='DOORLIGHT_FEED_FIXTURE';DoorlightNativeLibrary=$native;
    DoorlightFeedConfig=$configPath;DoorlightTrustRoot=$rootPath;
    DoorlightTrustCompressed=$trustCompressed;DoorlightDeltaCompressed=$deltaCompressed}
foreach ($value in @($PSScriptRoot,$artifacts,$publish)+@($properties.Values)) {
    if ($value -match '["%&|<>^\r\n]') { throw 'Unsupported build path character.' }
}
Push-Location $PSScriptRoot
try {
    & dotnet restore windows --locked-mode --artifacts-path $artifacts
    if ($LASTEXITCODE -ne 0) { throw 'Fixture dependency restore failed.' }
    $commands = @('@echo off', 'call "F:\WORK\Creations\DevTools\VisualStudio2022\Common7\Tools\VsDevCmd.bat" -arch=x64 -host_arch=x64 >nul', 'if errorlevel 1 exit /b 1')
    foreach ($key in $properties.Keys) { $commands += 'set "' + $key + '=' + $properties[$key] + '"' }
    $commands += @("dotnet publish windows -c Release --no-restore --artifacts-path `"$artifacts`" -o `"$publish`"", 'exit /b %errorlevel%')
    $batch = Join-Path $output 'publish-fixture.cmd'
    [IO.File]::WriteAllLines($batch, $commands)
    & cmd.exe /d /c $batch
    if ($LASTEXITCODE -ne 0) { throw 'Fixture NativeAOT publish failed.' }
    & $InnoCompiler '/DFixtureBuild=1' '/DOnlineBootstrap=1' "/DUpdaterExe=$publish/DoorlightUpdater.exe" "/DUpdaterNoticesDir=$notices" "/DAppVersion=$($config.updaterVersion)" "/DOutputDir=$output" (Join-Path $PSScriptRoot 'inno/Doorlight.iss')
    if ($LASTEXITCODE -ne 0) { throw 'Fixture online installer compilation failed.' }
} finally { Pop-Location }
Get-ChildItem -LiteralPath $output -File -Filter '*.exe' | Get-FileHash -Algorithm SHA256
