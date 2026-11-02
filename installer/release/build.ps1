[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Build','ValidateConfig','StageBundle','ExportSourceArchive','CopyOfflineAlias')][string]$Mode,
    [Parameter(Mandatory)][string]$ToolRoot,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$Commit,
    [Parameter(Mandatory)][string]$RunNumber,
    [Parameter(Mandatory)][string]$RunAttempt,
    [switch]$RequireDeliveryQualification,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [string]$RootPath = (Join-Path $PSScriptRoot 'bootstrap.root.json'),
    [string]$RepositoryRoot = (Join-Path $PSScriptRoot '../..'),
    [string]$SourceBundle,
    [string]$StagedBundle,
    [string]$SourceArchive,
    [string]$OfflineInstaller,
    [string]$StableInstaller
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:FlutterVersion = '3.44.2'
$script:FlutterRevision = 'c9a6c484230f8b5e408ec57be1ef71dee1e77020'
$script:FlutterArchiveSha256 = 'd79ae99807ba744b843e54f048308c629061456fdc7b0753251fb96eb5346a0e'
$script:FlutterManifestUrl = 'https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json'
$script:InnoVersion = '6.7.4'
$script:InnoInstallerSha256 = 'a549929319f9120716677c685535ca4671e4b937b5fdc87e2585f32d8eb30e8c'
$script:InnoInstallerUrl = 'https://github.com/jrsoftware/issrc/releases/download/is-6_7_4/innosetup-6.7.4.exe'
$script:SourceArchivePathspec = @(
    '.github/workflows/windows-release.yml', 'apps', 'native', 'installer', 'web', 'services',
    'LICENSE', 'README.md', '.gitignore',
    'tools/windows-native-inputs.ps1', 'tools/windows-native-inputs-test.ps1',
    'tools/windows-native-sources.ps1', 'tools/windows-native-sources-test.ps1'
)
$script:RequiredSourceFiles = @(
    '.github/workflows/windows-release.yml', 'apps/doorlight/pubspec.yaml', 'apps/doorlight/pubspec.lock',
    'apps/doorlight/windows/runner/CMakeLists.txt', 'apps/doorlight/windows/runner/jami_bridge.cpp',
    'native/jami/CMakeLists.txt', 'installer/global.json', 'installer/build.ps1',
    'installer/release/build.ps1', 'installer/release/config.json', 'installer/release/bootstrap.root.json',
    'installer/release/native-provenance.py', 'installer/release/native-notices.py',
    'installer/windows/Doorlight.Setup.csproj', 'web/site/index.html', 'services/wake-relay/package.json',
    'tools/windows-native-inputs.ps1', 'tools/windows-native-inputs-test.ps1',
    'tools/windows-native-sources.ps1', 'tools/windows-native-sources-test.ps1', 'LICENSE', 'README.md'
)

function Get-ReleaseSequence([string]$Number, [string]$Attempt) {
    if ($Number -cnotmatch '^[1-9][0-9]{0,8}$' -or $Attempt -cnotmatch '^[1-9][0-9]{0,4}$') {
        throw 'Run number and attempt must be positive decimal integers within the release version bounds.'
    }
    $run = [long]$Number
    $attemptNumber = [long]$Attempt
    if ($run -gt 65535 -or $attemptNumber -gt 65535) { throw 'Run number or attempt exceeds the supported release sequence bounds.' }
    return [long]($run * 65536 + $attemptNumber)
}

function Test-PublicHttpsUrl([string]$Value) {
    $uri = $null
    return [Uri]::TryCreate($Value,[UriKind]::Absolute,[ref]$uri) -and $uri.Scheme -ceq 'https' -and
        -not [string]::IsNullOrEmpty($uri.Host) -and [string]::IsNullOrEmpty($uri.UserInfo) -and
        [string]::IsNullOrEmpty($uri.Fragment) -and $uri.IsDefaultPort
}

function Read-ReleaseConfig([string]$Path,[switch]$RequireQualification,[string]$PublicRoot) {
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $config = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json -ErrorAction Stop
    if ($config.schema -ne 1 -or $config.repository -cne 'crazy-entertainment/Doorlight' -or
        $config.channel -cne 'stable' -or $config.feedTag -cne 'update-feed') {
        throw 'Release configuration schema, repository, channel, or tag is unsupported.'
    }
    foreach ($name in @('archiveUrl','archiveSha256','manifestUrl','manifestSha256','correspondingSourceUrl','correspondingSourceSha256')) {
        if ([string]::IsNullOrWhiteSpace([string]$config.nativeInputs.$name)) { throw "Release config nativeInputs.$name must be explicitly populated." }
    }
    foreach ($name in @('archiveUrl','manifestUrl','correspondingSourceUrl')) {
        if (-not (Test-PublicHttpsUrl ([string]$config.nativeInputs.$name))) { throw "nativeInputs.$name must be a public HTTPS URL." }
    }
    foreach ($name in @('archiveSha256','manifestSha256','correspondingSourceSha256')) {
        if ([string]$config.nativeInputs.$name -cnotmatch '^[0-9a-fA-F]{64}$') { throw "nativeInputs.$name must be a SHA-256 digest." }
    }
    if ([string]$config.nativeInputs.daemonSourceTree -cnotmatch '^[0-9a-f]{40}$') {
        throw 'Native inputs must identify the exact canonical daemon source tree.'
    }
    if (-not (Test-Path -LiteralPath $PublicRoot -PathType Leaf) -or
        [string]$config.rootSha256 -cnotmatch '^[0-9a-fA-F]{64}$' -or
        (Get-FileHash -LiteralPath $PublicRoot -Algorithm SHA256).Hash -ine [string]$config.rootSha256) {
        throw 'Public TUF root is absent or does not match the configured digest.'
    }
    if (-not $RequireQualification) { return [pscustomobject]@{ Path=$resolved; Value=$config } }
    if ($config.deliveryEnabled -ne $true) { throw 'Release delivery is disabled pending qualification.' }
    $review = $config.qualification
    $reviewDateValid = $false
    try {
        [void][DateTime]::ParseExact([string]$review.date,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None)
        $reviewDateValid = $true
    } catch { }
    if ([string]::IsNullOrWhiteSpace([string]$review.reviewer) -or
        -not $reviewDateValid -or
        -not (Test-PublicHttpsUrl ([string]$review.evidenceUrl)) -or
        [string]$review.nativeInputsSha256 -ine [string]$config.nativeInputs.archiveSha256 -or
        [string]$review.correspondingSourceSha256 -ine [string]$config.nativeInputs.correspondingSourceSha256) {
        throw 'Release qualification must identify its reviewer, date, evidence URL, and matching native/source digests.'
    }
    return [pscustomobject]@{ Path=$resolved; Value=$config }
}

function Copy-ReleaseBundle([string]$Source,[string]$Destination) {
    $sourcePath = (Resolve-Path -LiteralPath $Source -ErrorAction Stop).Path
    $destinationPath = [IO.Path]::GetFullPath($Destination)
    if (Test-Path -LiteralPath $destinationPath) { throw 'Release bundle staging destination must be new.' }
    if ($destinationPath.StartsWith($sourcePath.TrimEnd('\') + '\',[StringComparison]::OrdinalIgnoreCase) -or $destinationPath -eq $sourcePath) {
        throw 'Keep the staged bundle outside the Flutter build output.'
    }
    if ((Get-Item -LiteralPath $sourcePath).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Flutter output root must not be a link.' }
    $sourceEntries = @(Get-ChildItem -LiteralPath $sourcePath -Force -Recurse)
    if (@($sourceEntries | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Flutter output must not contain links or junctions.' }
    foreach ($required in @('sybl.exe','data/app.so','data/icudtl.dat','data/flutter_assets/NOTICES.Z')) {
        if (-not (Test-Path -LiteralPath (Join-Path $sourcePath $required) -PathType Leaf)) { throw "Flutter output is missing $required" }
    }
    New-Item -ItemType Directory -Path $destinationPath | Out-Null
    foreach ($entry in Get-ChildItem -LiteralPath $sourcePath -Force) {
        if ($entry.PSIsContainer) {
            if ($entry.Name -notin @('data','notices')) { continue }
            Copy-Item -LiteralPath $entry.FullName -Destination $destinationPath -Recurse
        } elseif ($entry.Name -eq 'sybl.exe' -or $entry.Extension -in @('.dll','.json')) {
            Copy-Item -LiteralPath $entry.FullName -Destination $destinationPath
        }
    }
    $stagedEntries = @(Get-ChildItem -LiteralPath $destinationPath -Force -Recurse)
    if (@($stagedEntries | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Staged release bundle unexpectedly contains links.' }
    foreach ($entry in Get-ChildItem -LiteralPath $destinationPath -Force) {
        if (($entry.PSIsContainer -and $entry.Name -notin @('data','notices')) -or
            (-not $entry.PSIsContainer -and $entry.Name -ne 'sybl.exe' -and $entry.Extension -notin @('.dll','.json')) -or
            ($entry.Name -like '*.exe' -and $entry.Name -cne 'sybl.exe')) { throw "Unexpected staged runtime input: $($entry.Name)" }
    }
    foreach ($sourceFile in $sourceEntries | Where-Object { -not $_.PSIsContainer }) {
        $relative = [IO.Path]::GetRelativePath($sourcePath,$sourceFile.FullName)
        $isRootRuntime = -not $relative.Contains([IO.Path]::DirectorySeparatorChar) -and
            ($sourceFile.Name -ceq 'sybl.exe' -or $sourceFile.Extension -in @('.dll','.json'))
        $isBundledDirectory = $relative.StartsWith('data' + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or
            $relative.StartsWith('notices' + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)
        if (-not ($isRootRuntime -or $isBundledDirectory)) { continue }
        $stagedFile = Join-Path $destinationPath $relative
        if (-not (Test-Path -LiteralPath $stagedFile -PathType Leaf) -or
            (Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $stagedFile -Algorithm SHA256).Hash) {
            throw "Staged release bundle differs at $relative."
        }
    }
    return $destinationPath
}

function Test-InnoCompiler([string]$Compiler) {
    if (-not (Test-Path -LiteralPath $Compiler -PathType Leaf)) { return $false }
    $compilerPath = (Resolve-Path -LiteralPath $Compiler).Path
    $compilerDirectory = [IO.Path]::GetFullPath((Split-Path -Parent $compilerPath)).TrimEnd('\')
    $registryPaths = @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1'
    )
    $registeredVersion = $false
    foreach ($registryPath in $registryPaths) {
        $installed = Get-ItemProperty -LiteralPath $registryPath -ErrorAction SilentlyContinue
        if ($installed -and $installed.DisplayVersion -ceq $script:InnoVersion -and $installed.InstallLocation) {
            $registeredDirectory = [IO.Path]::GetFullPath([string]$installed.InstallLocation).TrimEnd('\')
            if ($registeredDirectory -ieq $compilerDirectory) { $registeredVersion = $true; break }
        }
    }
    if (-not $registeredVersion) { return $false }
    $banner = @(& $Compiler '/?' 2>&1)
    $exitCode = $LASTEXITCODE
    $text = $banner -join "`n"
    return ($exitCode -in @(0,1) -and $text -match '(?m)^Inno Setup 6 Command-Line Compiler\s*$')
}

function Export-ReleaseSourceArchive([string]$Repository,[string]$Revision,[string]$Destination) {
    $repoPath = (Resolve-Path -LiteralPath $Repository -ErrorAction Stop).Path
    if ($Revision -cnotmatch '^[0-9a-fA-F]{40}$') { throw 'Source archive revision must be a full commit ID.' }
    $archivePath = [IO.Path]::GetFullPath($Destination)
    if (Test-Path -LiteralPath $archivePath) { throw 'Source archive output must be new.' }
    foreach ($relative in $script:RequiredSourceFiles) {
        & git -C $repoPath cat-file -e "${Revision}:$relative" 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Required release source path is absent at the requested commit: $relative" }
    }
    $parent = Split-Path -Parent $archivePath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'Source archive output parent must already exist.' }
    & git -C $repoPath archive --format=tar.gz --output=$archivePath $Revision -- @script:SourceArchivePathspec
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        throw 'Could not create the allowlisted release source archive.'
    }
    return $archivePath
}

function Copy-OfflineInstallerAlias([string]$Source,[string]$Destination) {
    $sourcePath = (Resolve-Path -LiteralPath $Source -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw 'Versioned offline installer is missing.' }
    $destinationPath = [IO.Path]::GetFullPath($Destination)
    if (Test-Path -LiteralPath $destinationPath) { throw 'Stable offline installer alias must be new.' }
    if (-not (Test-Path -LiteralPath (Split-Path -Parent $destinationPath) -PathType Container)) {
        throw 'Stable offline installer alias parent must exist.'
    }
    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath
    $sourceInfo = Get-Item -LiteralPath $sourcePath
    $destinationInfo = Get-Item -LiteralPath $destinationPath
    if ($sourceInfo.Length -ne $destinationInfo.Length -or
        (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash -cne
            (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash) {
        throw 'Stable offline installer alias differs from the versioned offline installer.'
    }
    return $destinationPath
}

$sequence = Get-ReleaseSequence $RunNumber $RunAttempt
$version = "1.$RunNumber.$RunAttempt"
if ($Mode -eq 'ExportSourceArchive') {
    if ([string]::IsNullOrWhiteSpace($SourceArchive)) { throw 'ExportSourceArchive mode requires -SourceArchive.' }
    Export-ReleaseSourceArchive $RepositoryRoot $Commit $SourceArchive
    return
}
if ($Mode -eq 'CopyOfflineAlias') {
    if ([string]::IsNullOrWhiteSpace($OfflineInstaller) -or [string]::IsNullOrWhiteSpace($StableInstaller)) {
        throw 'CopyOfflineAlias mode requires -OfflineInstaller and -StableInstaller.'
    }
    Copy-OfflineInstallerAlias $OfflineInstaller $StableInstaller
    return
}
$configInfo = Read-ReleaseConfig $ConfigPath -RequireQualification:$RequireDeliveryQualification -PublicRoot $RootPath
if ($Mode -eq 'StageBundle') {
    if ([string]::IsNullOrWhiteSpace($SourceBundle) -or [string]::IsNullOrWhiteSpace($StagedBundle)) { throw 'StageBundle mode requires -SourceBundle and -StagedBundle.' }
    Copy-ReleaseBundle $SourceBundle $StagedBundle
    return
}
if ($Mode -eq 'ValidateConfig') {
    [pscustomobject]@{ Version=$version; ReleaseSequence=$sequence; DeliveryEnabled=[bool]$configInfo.Value.deliveryEnabled; Config=$configInfo.Value } | ConvertTo-Json -Depth 8 -Compress
    return
}

$repo = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$commit = (& git -C $repo rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $commit -cne $Commit) { throw 'The checked out source commit does not match the requested release commit.' }
$daemonSourceTree = (& git -C $repo rev-parse "${Commit}:native/jami").Trim()
if ($LASTEXITCODE -ne 0 -or $daemonSourceTree -cne [string]$configInfo.Value.nativeInputs.daemonSourceTree) {
    throw 'Daemon source changed; rebuild and qualify its native inputs before releasing this revision.'
}
$toolRootFull = [IO.Path]::GetFullPath($ToolRoot)
$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
foreach ($path in @($toolRootFull,$outputFull)) {
    if (Test-Path -LiteralPath $path) { throw "Use a new scratch/output path: $path" }
}
New-Item -ItemType Directory -Path $toolRootFull,$outputFull | Out-Null

$config = $configInfo.Value
# CMake's checked-in default is this exact project-local path. Using that path
# avoids relying on an undocumented Flutter command-line hook for CMake args.
$nativeRoot = Join-Path $repo 'local/dev/jami-src/jami-daemon'
New-Item -ItemType Directory -Path (Split-Path -Parent $nativeRoot) -Force | Out-Null
$nativeArchive = Join-Path $toolRootFull 'native-inputs.zip'
$nativeManifest = Join-Path $toolRootFull 'native-inputs.manifest.json'
$sourceResponse = Join-Path $toolRootFull 'configured-native-source.tar.gz'
Invoke-WebRequest -Uri ([string]$config.nativeInputs.archiveUrl) -OutFile $nativeArchive
Invoke-WebRequest -Uri ([string]$config.nativeInputs.manifestUrl) -OutFile $nativeManifest
Invoke-WebRequest -Uri ([string]$config.nativeInputs.correspondingSourceUrl) -OutFile $sourceResponse
foreach ($check in @(
    @{Path=$nativeArchive;Hash=[string]$config.nativeInputs.archiveSha256;Name='native input archive'},
    @{Path=$nativeManifest;Hash=[string]$config.nativeInputs.manifestSha256;Name='native input manifest'},
    @{Path=$sourceResponse;Hash=[string]$config.nativeInputs.correspondingSourceSha256;Name='corresponding source archive'}
)) {
    if ((Get-FileHash -LiteralPath $check.Path -Algorithm SHA256).Hash -ine $check.Hash) { throw "$($check.Name) digest mismatch." }
}
& (Join-Path $repo 'tools/windows-native-inputs.ps1') -Mode Expand -ArchivePath $nativeArchive -ManifestPath $nativeManifest -TargetRoot $nativeRoot
if (-not $?) { throw 'Native input archive validation or extraction failed.' }
Remove-Item -LiteralPath $nativeArchive,$nativeManifest,$sourceResponse -Force

$flutterZip = Join-Path $toolRootFull 'flutter-windows.zip'
$flutterManifestPath = Join-Path $toolRootFull 'flutter-releases.json'
Invoke-WebRequest -Uri $script:FlutterManifestUrl -OutFile $flutterManifestPath
$flutterManifest = Get-Content -LiteralPath $flutterManifestPath -Raw | ConvertFrom-Json
$flutterRelease = @($flutterManifest.releases | Where-Object { $_.version -ceq $script:FlutterVersion -and $_.channel -ceq 'stable' -and $_.hash -ceq $script:FlutterRevision })
if ($flutterRelease.Count -ne 1 -or $flutterRelease[0].dart_sdk_version -cne '3.12.2' -or
    $flutterRelease[0].archive -cne 'stable/windows/flutter_windows_3.44.2-stable.zip' -or
    $flutterRelease[0].sha256 -cne $script:FlutterArchiveSha256) {
    throw 'Official Flutter release manifest differs from the pinned Windows SDK inputs.'
}
Invoke-WebRequest -Uri ($flutterManifest.base_url.TrimEnd('/') + '/' + $flutterRelease[0].archive) -OutFile $flutterZip
if ((Get-FileHash -LiteralPath $flutterZip -Algorithm SHA256).Hash -ine $script:FlutterArchiveSha256) { throw 'Flutter SDK archive digest mismatch.' }
$flutterExpand = Join-Path $toolRootFull 'flutter-sdk'
New-Item -ItemType Directory -Path $flutterExpand | Out-Null
Expand-Archive -LiteralPath $flutterZip -DestinationPath $flutterExpand
Remove-Item -LiteralPath $flutterZip -Force
$flutter = Join-Path $flutterExpand 'flutter/bin/flutter.bat'
if (-not (Test-Path -LiteralPath $flutter -PathType Leaf)) { throw 'Pinned Flutter archive has an unexpected layout.' }
$env:PATH = (Join-Path (Split-Path $flutter) '') + ';' + $env:PATH
$pubCache = Join-Path $toolRootFull 'pub-cache'
$env:PUB_CACHE = $pubCache

$inno = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe'
if (-not (Test-InnoCompiler $inno)) {
    $innoSetupDir = Join-Path $toolRootFull 'inno'
    $innoInstaller = Join-Path $toolRootFull 'innosetup-6.7.4.exe'
    Invoke-WebRequest -Uri $script:InnoInstallerUrl -OutFile $innoInstaller
    if ((Get-FileHash -LiteralPath $innoInstaller -Algorithm SHA256).Hash -ine $script:InnoInstallerSha256) { throw 'Pinned Inno Setup installer digest mismatch.' }
    $process = Start-Process -FilePath $innoInstaller -ArgumentList @('/CURRENTUSER','/NOICONS','/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/DIR=$innoSetupDir") -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw 'Pinned Inno Setup installation failed.' }
    $inno = Join-Path $innoSetupDir 'ISCC.exe'
}
if (-not (Test-InnoCompiler $inno)) { throw 'Pinned Inno Setup compiler hash or command-line banner is invalid.' }

$work = Join-Path $toolRootFull 'build'
New-Item -ItemType Directory -Path $work | Out-Null
$trustOutput = Join-Path $work 'trust'
$trustTools = Join-Path $work 'trust-tools'
& (Join-Path $repo 'installer/trust/build.ps1') -ToolRoot $trustTools -OutputDirectory $trustOutput -IncludeFixture
if (-not $?) { throw 'Trust verifier build failed.' }
$fixtureVerifier = Join-Path $trustOutput 'DoorlightTrust.Fixture.exe'
if (-not (Test-Path -LiteralPath $fixtureVerifier -PathType Leaf)) { throw 'Fixture verifier was not produced for isolated integration checks.' }
$go = Join-Path $trustTools 'go/bin/go.exe'
$moduleCache = Join-Path $trustTools 'modules'
$noticeRoot = Join-Path $work 'trust-notices'
New-Item -ItemType Directory -Path $noticeRoot | Out-Null
Push-Location (Join-Path $repo 'installer/trust')
try {
    $env:GOMODCACHE = $moduleCache
    $env:GOTOOLCHAIN = 'local'
    $moduleDirs = @(& $go list -mod=readonly -m -f '{{.Dir}}' all)
    if ($LASTEXITCODE -ne 0 -or $moduleDirs.Count -lt 2) { throw 'Could not enumerate pinned Go dependency modules for notices.' }
    $index = 0
    foreach ($moduleDir in $moduleDirs | Select-Object -Skip 1) {
        $legal = @(Get-ChildItem -LiteralPath $moduleDir -File -Force | Where-Object { $_.Name -match '^(LICENSE|COPYING|NOTICE|PATENTS)(\.|$)' })
        if (-not $legal.Count) { throw "Go dependency lacks a root legal notice: $moduleDir" }
        foreach ($notice in $legal) {
            $index++
            Copy-Item -LiteralPath $notice.FullName -Destination (Join-Path $noticeRoot ('{0:D4}-{1}' -f $index,$notice.Name))
        }
    }
} finally { Pop-Location }
$deltaRoot = Join-Path $work 'delta'
& (Join-Path $repo 'installer/delta/provision.ps1') -ToolsDir $deltaRoot
if (-not $?) { throw 'Pinned delta tool provisioning failed.' }

$savedDeltaHelper = $env:DOORLIGHT_DELTA_HELPER
try {
    $env:DOORLIGHT_DELTA_HELPER = Join-Path $deltaRoot 'tool/vendor/update.exe'
    $deltaOutput = Join-Path $work 'delta-tests'
    $deltaIntermediate = Join-Path $deltaOutput 'obj'
    $deltaBinary = Join-Path $deltaOutput 'bin'
    & dotnet build (Join-Path $repo 'installer/delta-tests') -c Release "-p:BaseIntermediateOutputPath=$deltaIntermediate/" "-p:OutputPath=$deltaBinary/"
    if ($LASTEXITCODE -ne 0) { throw 'Delta source/native-codec test build failed.' }
    & dotnet (Join-Path $deltaBinary 'Doorlight.Delta.Checks.dll')
    if ($LASTEXITCODE -ne 0) { throw 'Delta source/native-codec tests failed.' }
} finally { $env:DOORLIGHT_DELTA_HELPER = $savedDeltaHelper }

$feedProject = Join-Path $repo 'installer/feed-tests/Doorlight.Feed.Checks.csproj'
foreach ($fixture in @($false,$true)) {
    $feedName = if ($fixture) { 'feed-fixture' } else { 'feed-production' }
    $feedArtifacts = Join-Path $work $feedName
    & dotnet restore $feedProject --locked-mode --artifacts-path $feedArtifacts
    if ($LASTEXITCODE -ne 0) { throw "$feedName locked restore failed." }
    $feedArgs = @('run','--project',$feedProject,'--no-restore','--artifacts-path',$feedArtifacts)
    if ($fixture) {
        $feedArgs += @('-p:DefineConstants=DOORLIGHT_FEED_FIXTURE','--',$fixtureVerifier,(Join-Path $trustOutput 'DoorlightTrust.exe'))
    }
    & dotnet @feedArgs
    if ($LASTEXITCODE -ne 0) { throw "$feedName checks failed." }
}

$distributionScratch = Join-Path $work 'distribution-tests'
$distributionProject = Join-Path $repo 'installer/distribution-tests/Doorlight.Distribution.Checks.csproj'
$distributionArtifacts = Join-Path $distributionScratch 'build'
New-Item -ItemType Directory -Path $distributionScratch | Out-Null
& dotnet restore $distributionProject --locked-mode --artifacts-path $distributionArtifacts
if ($LASTEXITCODE -ne 0) { throw 'Distribution test locked restore failed.' }
& (Join-Path $repo 'installer/distribution-tests/build.ps1') -Scratch $distributionScratch -FixtureVerifier $fixtureVerifier
if (-not $?) { throw 'Configured distribution integration checks failed.' }

& (Join-Path $repo 'tools/windows-native-inputs-test.ps1')
if (-not $?) { throw 'Synthetic Windows native-input transport checks failed.' }
$coreProject = Join-Path $repo 'installer/tests/Doorlight.Setup.Checks.csproj'
$coreArtifacts = Join-Path $work 'core-checks'
& dotnet restore $coreProject --locked-mode --artifacts-path $coreArtifacts
if ($LASTEXITCODE -ne 0) { throw 'Installer core-check locked restore failed.' }
Push-Location $repo
try {
    & dotnet run --project $coreProject --no-restore --artifacts-path $coreArtifacts
    if ($LASTEXITCODE -ne 0) { throw 'Installer core checks failed.' }
} finally { Pop-Location }

$app = Join-Path $repo 'apps/doorlight'
Push-Location $app
try {
    & $flutter pub get --enforce-lockfile
    if ($LASTEXITCODE -ne 0) { throw 'Flutter dependency resolution failed.' }
    & $flutter analyze
    if ($LASTEXITCODE -ne 0) { throw 'Flutter analysis failed.' }
    & $flutter test
    if ($LASTEXITCODE -ne 0) { throw 'Flutter tests failed.' }
    & $flutter build windows --release --build-name $version --build-number '0'
    if ($LASTEXITCODE -ne 0) { throw 'Windows release build failed.' }
} finally { Pop-Location }

$windowsBuild = Join-Path $app 'build/windows/x64'
$cmakeCache = Join-Path $windowsBuild 'CMakeCache.txt'
if (-not (Test-Path -LiteralPath $cmakeCache -PathType Leaf)) { throw 'Flutter did not leave the expected Windows CMake build directory.' }
$cacheText = Get-Content -LiteralPath $cmakeCache -Raw
if ($cacheText -notmatch [Regex]::Escape($nativeRoot.Replace('\','/')) -and $cacheText -notmatch [Regex]::Escape($nativeRoot.Replace('/','\'))) {
    throw 'CMake did not configure against the freshly verified native input root.'
}
& cmake --build $windowsBuild --config Release --target ALL_BUILD
if ($LASTEXITCODE -ne 0) { throw 'Windows CTest target build failed.' }
& ctest --test-dir $windowsBuild -C Release --output-on-failure
if ($LASTEXITCODE -ne 0) { throw 'Windows native CTest qualification failed.' }
$flutterBundle = Join-Path $windowsBuild 'runner/Release'
if (-not (Test-Path -LiteralPath (Join-Path $flutterBundle 'sybl.exe') -PathType Leaf)) { throw 'Expected Windows release bundle is missing.' }
$bundle = Join-Path $work 'release-bundle'
Copy-ReleaseBundle $flutterBundle $bundle | Out-Null
$nativeNotices = Join-Path $nativeRoot 'notices/native'
if (-not (Test-Path -LiteralPath (Join-Path $nativeNotices 'index.json') -PathType Leaf)) {
    throw 'Qualified native inputs must contain their dependency notices and index.'
}
$bundleNotices = Join-Path $bundle 'notices'
New-Item -ItemType Directory -Path $bundleNotices -Force | Out-Null
Copy-Item -LiteralPath $nativeNotices -Destination (Join-Path $bundleNotices 'native') -Recurse

$trustedRoot = (Resolve-Path -LiteralPath $RootPath).Path
if (-not (Test-Path -LiteralPath $trustedRoot -PathType Leaf)) { throw 'Public TUF bootstrap root is not configured; refusing to build a release installer.' }
$actualRootHash = (Get-FileHash -LiteralPath $trustedRoot -Algorithm SHA256).Hash.ToLowerInvariant()
if ([string]$config.rootSha256 -cne $actualRootHash) { throw 'Configured root digest does not match bootstrap.root.json.' }
$feedConfig = Join-Path $work 'feed-config.json'
$feed = [ordered]@{
    schema=1
    metadataUrl="https://github.com/$($config.repository)/releases/download/$($config.feedTag)/"
    targetsUrl="https://github.com/$($config.repository)/releases/download/$($config.feedTag)/"
    rootSha256=$actualRootHash
    verifierSha256='7f50f6dbf1984feebbfdc08891703ad93bf305603332e1a0bcfd21cc0d59d591'
    verifierLength=(Get-Item -LiteralPath (Join-Path $trustOutput 'DoorlightTrust.exe')).Length
    updaterVersion=$version
    channel='stable'
    packageId='Doorlight'
}
[IO.File]::WriteAllText($feedConfig,($feed | ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
$packageOutput = Join-Path $work 'installer-output'
$packageArgs = @('-BundleDir',$bundle,'-Version',$version,'-OutputDir',$packageOutput,
    '-TrustVerifier',(Join-Path $trustOutput 'DoorlightTrust.exe'),'-TrustNoticesDirectory',$noticeRoot,
    '-DeltaToolsConfig',(Join-Path $deltaRoot 'tools.json'),'-FeedConfig',$feedConfig,'-TrustRoot',$trustedRoot,
    '-InnoCompiler',$inno,'-VsDevCmd',(& (Join-Path $repo 'installer/windows-toolchain.ps1')))
& (Join-Path $repo 'installer/build.ps1') @packageArgs
if (-not $?) { throw 'Installer and release package build failed.' }

# Archive only the explicit application/build source surface; historical
# private roots such as docs, design, sybl, widget, patches, and old tools are excluded.
$sourceArchive = Join-Path $outputFull 'Doorlight.Source.tar.gz'
Export-ReleaseSourceArchive $repo $Commit $sourceArchive | Out-Null
$deliverables = @(
    @{Source=(Join-Path $packageOutput 'Doorlight.Package.json');Name='Doorlight.Package.json'},
    @{Source=(Join-Path $packageOutput 'Doorlight.Package.zip');Name='Doorlight.Package.zip'},
    @{Source=(Join-Path $packageOutput "Doorlight-$version-Setup.exe");Name="Doorlight-$version-Setup.exe"},
    @{Source=(Join-Path $packageOutput "Doorlight-$version-Online-Setup.exe");Name="Doorlight-$version-Online-Setup.exe"}
)
foreach ($item in $deliverables) {
    if (-not (Test-Path -LiteralPath $item.Source -PathType Leaf)) { throw "Release output is missing $($item.Name)." }
    Copy-Item -LiteralPath $item.Source -Destination (Join-Path $outputFull $item.Name)
}
$versionedOfflineInstaller = Join-Path $packageOutput "Doorlight-$version-Setup.exe"
Copy-OfflineInstallerAlias $versionedOfflineInstaller (Join-Path $outputFull 'Doorlight-Setup.exe') | Out-Null
$fileRecords = @((Get-ChildItem -LiteralPath $outputFull -File | Sort-Object Name | ForEach-Object {
    [ordered]@{name=$_.Name;length=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
}))
$receipt = [ordered]@{
    schema=1
    commit=$Commit
    version=$version
    releaseSequence=$sequence
    nativeInputsSha256=([string]$config.nativeInputs.archiveSha256).ToLowerInvariant()
    daemonSourceTree=$daemonSourceTree
    correspondingSourceUrl=[string]$config.nativeInputs.correspondingSourceUrl
    correspondingSourceSha256=([string]$config.nativeInputs.correspondingSourceSha256).ToLowerInvariant()
    flutter=[ordered]@{version=$script:FlutterVersion;revision=$script:FlutterRevision;archiveSha256=$script:FlutterArchiveSha256}
    qualification='Windows build and source/native test qualification only; no device, Android, signing, or release acceptance is asserted.'
    files=$fileRecords
}
[IO.File]::WriteAllText((Join-Path $outputFull 'build-receipt.json'),($receipt | ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
Get-ChildItem -LiteralPath $outputFull -File | Get-FileHash -Algorithm SHA256
