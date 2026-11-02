param(
    [Parameter(Mandatory)][string]$BundleDir,
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [Parameter(Mandatory)][string]$OutputDir,
    [Parameter(Mandatory)][string]$TrustVerifier,
    [Parameter(Mandatory)][string]$TrustNoticesDirectory,
    [Parameter(Mandatory)][string]$DeltaToolsConfig,
    [string]$TrustVerifierSha256 = '7f50f6dbf1984feebbfdc08891703ad93bf305603332e1a0bcfd21cc0d59d591',
    [string]$FeedConfig,
    [string]$TrustRoot,
    [string]$PackageId = 'Doorlight',
    [switch]$FixtureBuild,
    [string]$InnoCompiler = 'C:/Program Files (x86)/Inno Setup 6/ISCC.exe',
    [string]$VsDevCmd
)
$ErrorActionPreference = 'Stop'
$vs = & (Join-Path $PSScriptRoot 'windows-toolchain.ps1') -VsDevCmd $VsDevCmd
$bundle = (Resolve-Path -LiteralPath $BundleDir).Path
$output = [IO.Path]::GetFullPath($OutputDir)
$fixtureLabel = if ($FixtureBuild) { '-Fixture' } else { '' }
if ($FixtureBuild -and $output -notmatch '(?i)fixture') { throw 'Fixture builds require an explicitly named fixture output directory.' }
foreach ($artifact in @('Doorlight.Package.zip', 'Doorlight.Package.json', "Doorlight-${Version}${fixtureLabel}-Setup.exe", "Doorlight-${Version}${fixtureLabel}-Online-Setup.exe", 'distribution')) {
    if (Test-Path -LiteralPath (Join-Path $output $artifact)) { throw 'Use a new output directory for each candidate.' }
}
if ($output.StartsWith($bundle.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or $output -eq $bundle) {
    throw 'Keep output outside the input bundle.'
}
if (-not (Test-Path -LiteralPath $InnoCompiler -PathType Leaf)) { throw 'Inno Setup 6 is required.' }
if (([string]::IsNullOrEmpty($FeedConfig)) -ne ([string]::IsNullOrEmpty($TrustRoot))) { throw 'Supply both public feed configuration and public trust root, or neither.' }
$trust = (Resolve-Path -LiteralPath $TrustVerifier).Path
if ((Get-FileHash -LiteralPath $trust).Hash -ne $TrustVerifierSha256) { throw 'Trust verifier does not match its pinned build digest.' }
$deltaTools = Get-Content -LiteralPath $DeltaToolsConfig -Raw | ConvertFrom-Json
foreach ($property in @('PatchExe', 'VpkDll', 'License', 'Notices')) {
    if ([string]::IsNullOrWhiteSpace([string]$deltaTools.$property) -or
        -not (Test-Path -LiteralPath $deltaTools.$property -PathType Leaf)) {
        throw "Delta tool configuration is missing $property; provision the pinned tools into a fresh directory."
    }
}
if ($deltaTools.Version -ne '1.2.161' -or
    (Get-FileHash -LiteralPath $deltaTools.PatchExe).Hash -ne '9b5d28a356446c6ab61c0ec8f808fcb8a92af3cd0623a6d8fc634f1a5a1e6580' -or
    (Get-FileHash -LiteralPath $deltaTools.VpkDll).Hash -ne 'f86d38eecbfe18127402f4d54f4c38cdca33d68a60dc7fb741d1f6155554c530') { throw 'Delta tools do not match the pinned release.' }
if ($FeedConfig) {
    $FeedConfig = (Resolve-Path -LiteralPath $FeedConfig).Path
    $TrustRoot = (Resolve-Path -LiteralPath $TrustRoot).Path
    $feed = Get-Content -LiteralPath $FeedConfig -Raw | ConvertFrom-Json
    if ($feed.schema -ne 1 -or $feed.verifierSha256 -cne $TrustVerifierSha256 -or
        $feed.verifierLength -ne (Get-Item -LiteralPath $trust).Length -or
        $feed.rootSha256 -cne (Get-FileHash -LiteralPath $TrustRoot).Hash.ToLowerInvariant() -or
        $feed.updaterVersion -cne $Version -or $feed.packageId -cne $PackageId) { throw 'Public feed configuration does not match these build inputs.' }
}
foreach ($required in @('sybl.exe', 'flutter_windows.dll', 'data/app.so', 'data/icudtl.dat', 'data/flutter_assets/NOTICES.Z')) {
    if (-not (Test-Path -LiteralPath (Join-Path $bundle $required) -PathType Leaf)) { throw "Bundle is missing $required" }
}
$entries = @(Get-ChildItem -LiteralPath $bundle -Force -Recurse)
if (@($entries | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -or
    ((Get-Item -LiteralPath $bundle).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'Bundle must not contain links or junctions.'
}
foreach ($entry in Get-ChildItem -LiteralPath $bundle -Force) {
    if (($entry.PSIsContainer -and $entry.Name -notin @('data', 'notices')) -or
        (-not $entry.PSIsContainer -and $entry.Extension -notin @('.exe', '.dll', '.pdb', '.json') -and $entry.Name -notin @('LICENSE.txt', 'Doorlight.version')) -or
        ($entry.Extension -eq '.exe' -and $entry.Name -ne 'sybl.exe') -or
        ($entry.Extension -eq '.json' -and $entry.Name -ne 'native_assets.json')) {
        throw "Unexpected bundle input: $($entry.Name)"
    }
}
if ((Test-Path -LiteralPath (Join-Path $bundle 'Doorlight.version')) -and
    (Get-Content -LiteralPath (Join-Path $bundle 'Doorlight.version') -Raw).Trim() -ne $Version) { throw 'Input bundle version differs from the requested version.' }
New-Item -ItemType Directory -Force -Path $output | Out-Null
$work = Join-Path $output ('.package-' + [Guid]::NewGuid().ToString('N'))
$staged = Join-Path $work 'bundle'
New-Item -ItemType Directory -Path $staged -Force | Out-Null
foreach ($entry in $entries | Where-Object { -not $_.PSIsContainer -and $_.Extension -ne '.pdb' }) {
    $relative = [IO.Path]::GetRelativePath($bundle, $entry.FullName)
    $target = Join-Path $staged $relative
    New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
    Copy-Item -LiteralPath $entry.FullName -Destination $target
}
[IO.File]::WriteAllText((Join-Path $staged 'Doorlight.version'), $Version, [Text.UTF8Encoding]::new($false))
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../LICENSE') -Destination (Join-Path $staged 'LICENSE.txt')
$runtime = & (Join-Path $PSScriptRoot 'release/windows-runtime.ps1') -BundleDir $staged -VsDevCmd $vs
function CompressResource([string]$Source, [string]$Destination) {
    $inputStream = [IO.File]::OpenRead($Source)
    $outputStream = [IO.File]::Create($Destination)
    try {
        $compressed = [IO.Compression.BrotliStream]::new($outputStream, [IO.Compression.CompressionLevel]::SmallestSize, $true)
        try { $inputStream.CopyTo($compressed) } finally { $compressed.Dispose() }
    } finally { $inputStream.Dispose(); $outputStream.Dispose() }
}
Push-Location $PSScriptRoot
try {
    $native = Join-Path $work 'native-ui'
    & (Join-Path $PSScriptRoot 'native-ui/build.ps1') -OutputDir $native -VsDevCmd $vs
    $nativeLibrary = Join-Path $native 'doorlight_ui.lib'
    $trustCompressed = Join-Path $work 'Doorlight.Trust.exe.br'
    $deltaCompressed = Join-Path $work 'Doorlight.Delta.exe.br'
    CompressResource $trust $trustCompressed
    CompressResource $deltaTools.PatchExe $deltaCompressed
    $artifacts = (Join-Path $work 'dotnet').Replace('\', '/')
    & dotnet restore windows --locked-mode --artifacts-path $artifacts
    if ($LASTEXITCODE -ne 0) { throw 'Updater dependency restore failed.' }
    $updaterOutput = Join-Path $work 'updater'
    $publishArguments = @('publish', (Join-Path $PSScriptRoot 'windows'), '-c', 'Release', '--no-restore',
        '--artifacts-path', $artifacts, '-o', $updaterOutput)
    $properties = [ordered]@{DoorlightNativeLibrary=$nativeLibrary;DoorlightTrustCompressed=$trustCompressed;
        DoorlightDeltaCompressed=$deltaCompressed;DoorlightFeedConfig=$FeedConfig;DoorlightTrustRoot=$TrustRoot;
        DefineConstants=$(if ($FixtureBuild) { 'DOORLIGHT_FEED_FIXTURE' } else { '' })}
    # NativeAOT needs the already-provisioned MSVC environment; keep changes in a child shell.
    foreach ($argument in $publishArguments) { if ($argument -match '["%&|<>^\r\n]') { throw 'Unsupported build argument character.' } }
    foreach ($value in $properties.Values) { if ($value -match '["%&|<>^\r\n]') { throw 'Unsupported build property character.' } }
    $quotedArguments = ($publishArguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $publishCommand = Join-Path $work 'publish.cmd'
    $commands = @('@echo off',
        ('call "' + $vs + '" -arch=x64 -host_arch=x64 >nul'),
        'if errorlevel 1 exit /b 1')
    foreach ($key in $properties.Keys) { $commands += 'set "' + $key + '=' + $properties[$key] + '"' }
    $commands += @("dotnet $quotedArguments", 'exit /b %errorlevel%')
    [IO.File]::WriteAllLines($publishCommand, $commands)
    & cmd.exe /d /c $publishCommand
    if ($LASTEXITCODE -ne 0) { throw 'Updater publish failed.' }
    $setup = Join-Path $staged '_setup'
    New-Item -ItemType Directory -Path $setup | Out-Null
    $updater = Join-Path $setup 'DoorlightUpdater.exe'
    Copy-Item -LiteralPath (Join-Path $updaterOutput 'DoorlightUpdater.exe') -Destination $updater
    $tools = Join-Path $setup 'tools'
    New-Item -ItemType Directory -Path $tools | Out-Null
    Copy-Item -LiteralPath $deltaTools.PatchExe -Destination (Join-Path $tools 'Update.exe')
    $notices = Join-Path $setup 'licenses'
    New-Item -ItemType Directory -Path $notices | Out-Null
    $cache = if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else { Join-Path $env:USERPROFILE '.nuget/packages' }
    $runtimeVersion = ([xml](Get-Content (Join-Path $PSScriptRoot 'windows/Doorlight.Setup.csproj') -Raw)).Project.PropertyGroup.RuntimeFrameworkVersion
    Copy-Item -LiteralPath (Join-Path $cache "microsoft.netcore.app.runtime.win-x64/$runtimeVersion/LICENSE.TXT") -Destination (Join-Path $notices 'LICENSE-dotnet-runtime.txt')
    Copy-Item -LiteralPath (Join-Path $cache "microsoft.netcore.app.runtime.win-x64/$runtimeVersion/THIRD-PARTY-NOTICES.TXT") -Destination (Join-Path $notices 'THIRD-PARTY-NOTICES-dotnet.txt')
    Copy-Item -LiteralPath $deltaTools.License -Destination (Join-Path $notices 'LICENSE-Velopack.txt')
    Copy-Item -LiteralPath $deltaTools.Notices -Destination (Join-Path $notices 'THIRD-PARTY-NOTICES-Velopack.md')
    foreach ($notice in Get-ChildItem -LiteralPath $TrustNoticesDirectory -File) {
        Copy-Item -LiteralPath $notice.FullName -Destination (Join-Path $notices ('trust-' + $notice.Name))
    }
    Copy-Item -LiteralPath (Join-Path (Split-Path $InnoCompiler) 'License.txt') -Destination (Join-Path $notices 'LICENSE-inno.txt')
    foreach ($fontNotice in @('OFL-Fraunces.txt', 'OFL-HankenGrotesk.txt')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "../apps/doorlight/assets/fonts/$fontNotice") -Destination (Join-Path $notices $fontNotice)
    }
    $files = @(Get-ChildItem -LiteralPath $staged -File -Recurse | Sort-Object FullName | ForEach-Object {
        if ($_.FullName.Length -ge 260) { throw 'Inno Setup input exceeds the Windows path limit; use a shorter output directory.' }
        [ordered]@{
            Path = [IO.Path]::GetRelativePath($staged, $_.FullName).Replace('\', '/')
            Size = $_.Length
            Sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
    $manifest = Join-Path $output 'Doorlight.Package.json'
    [IO.File]::WriteAllText($manifest, ([ordered]@{ Schema = 1; Version = $Version; Files = $files } | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    $package = Join-Path $output 'Doorlight.Package.zip'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($staged, $package, [IO.Compression.CompressionLevel]::Optimal, $false)
    & dotnet restore tests --locked-mode --artifacts-path $artifacts
    if ($LASTEXITCODE -ne 0) { throw 'Package verifier dependency restore failed.' }
    $verifier = Join-Path $work 'verifier'
    & dotnet build tests --no-restore --artifacts-path $artifacts -o $verifier
    if ($LASTEXITCODE -ne 0) { throw 'Package verifier build failed.' }
    Push-Location $work
    try {
        & dotnet exec (Join-Path $verifier 'Doorlight.Setup.Checks.dll') --verify $package $manifest
        if ($LASTEXITCODE -ne 0) { throw 'Release package verification failed.' }
    } finally { Pop-Location }
    $vpkBundle = Join-Path $work 'vpk-bundle'
    Copy-Item -LiteralPath $staged -Destination $vpkBundle -Recurse
    $distribution = Join-Path $output 'distribution'
    & dotnet $deltaTools.VpkDll pack --packId $PackageId --packVersion $Version --packDir $vpkBundle --mainExe sybl.exe --skipVeloAppCheck --noInst --delta None --runtime win-x64 --outputDir $distribution --skip-updates --yes
    if ($LASTEXITCODE -ne 0) { throw 'Full update package creation failed.' }
    $full = @(Get-ChildItem -LiteralPath $distribution -Filter '*-full.nupkg')
    if ($full.Count -ne 1) { throw 'Expected one full update package.' }
    $archive = [IO.Compression.ZipFile]::OpenRead($full[0].FullName)
    try {
        $members = @{}
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName.StartsWith('lib/app/', [StringComparison]::Ordinal) -and !$entry.FullName.EndsWith('/')) {
                $relative = $entry.FullName.Substring(8)
                if ($members.ContainsKey($relative)) { throw 'Duplicate update package file.' }
                $members[$relative] = $entry
            }
        }
        foreach ($file in $files) {
            $entry = $members[$file.Path]
            if (!$entry -or $entry.Length -ne $file.Size) { throw 'Update package content does not match the manifest.' }
            $content = $entry.Open()
            try { $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($content)).ToLowerInvariant() } finally { $content.Dispose() }
            if ($digest -cne $file.Sha256) { throw "Update packager changed $($file.Path)." }
            $members.Remove($file.Path)
        }
        if (@($members.Keys | Where-Object { $_ -notin @('Squirrel.exe', 'sq.version', "${PackageId}_ExecutionStub.exe") }).Count) { throw 'Unexpected update packaging content.' }
    } finally { $archive.Dispose() }
    $innoArguments = @("/DUpdaterExe=$updater", "/DUpdaterNoticesDir=$notices", "/DAppVersion=$Version", "/DOutputDir=$output")
    if ($FixtureBuild) { $innoArguments += '/DFixtureBuild=1' }
    & $InnoCompiler @innoArguments "/DBundleDir=$staged" "/DManifestFile=$manifest" (Join-Path $PSScriptRoot 'inno/Doorlight.iss')
    if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed.' }
    & $InnoCompiler @innoArguments '/DOnlineBootstrap=1' (Join-Path $PSScriptRoot 'inno/Doorlight.iss')
    if ($LASTEXITCODE -ne 0) { throw 'Online bootstrap compilation failed.' }
    [ordered]@{Version=$Version;Sdk='10.0.401';Runtime=$runtimeVersion;FeedConfigured=[bool]$FeedConfig;FixtureBuild=[bool]$FixtureBuild;
        TrustVerifierSha256=$TrustVerifierSha256;DeltaVersion=$deltaTools.Version;DeltaSha256=$deltaTools.PatchSha256;
        UpdaterBytes=(Get-Item $updater).Length;TrustResourceBytes=(Get-Item $trustCompressed).Length;
        DeltaResourceBytes=(Get-Item $deltaCompressed).Length;FullUpdateBytes=$full[0].Length} |
        ConvertTo-Json | Set-Content (Join-Path $output 'build-provenance.json') -Encoding utf8
} finally { Pop-Location }
Get-ChildItem -LiteralPath $output -File | Get-FileHash -Algorithm SHA256
