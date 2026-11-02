$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$build = Join-Path $PSScriptRoot 'build.ps1'
$rootSdk = Join-Path $repo 'global.json'
$installerSdk = Join-Path $repo 'installer/global.json'
$rootSdkHash = (Get-FileHash -LiteralPath $rootSdk -Algorithm SHA256).Hash
$installerSdkHash = (Get-FileHash -LiteralPath $installerSdk -Algorithm SHA256).Hash
if ($rootSdkHash -cne $installerSdkHash) { throw 'Root and installer .NET SDK pins must be byte-identical.' }
$sdkPin = Get-Content -LiteralPath $rootSdk -Raw | ConvertFrom-Json
if ($sdkPin.sdk.version -cne '10.0.401' -or $sdkPin.sdk.rollForward -cne 'disable') { throw 'Root SDK pin must remain locked to .NET 10.0.401.' }
$workflow = Join-Path $repo '.github/workflows/windows-release.yml'
$tokens = $null
$parseErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile($build,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) { throw "build.ps1 PowerShell parse failed: $($parseErrors[0].Message)" }

$text = Get-Content -LiteralPath $workflow -Raw
foreach ($required in @(
    'group: windows-delivery',
    'cancel-in-progress: false',
    'windows-2022',
    'persist-credentials: false',
    "github.ref == 'refs/heads/main'",
    "outputs.delivery_enabled == 'true'",
    'actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6',
    'go-version: ''1.27.3''',
    'actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803',
    'actions/setup-dotnet@26b0ec14cb23fa6904739307f278c14f94c95bf1',
    'actions/setup-go@924ae3a1cded613372ab5595356fb5720e22ba16',
    'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02',
    'actions/download-artifact@634f93cb2916e3fdff6788551b99b062d0335ce0',
    'installer/release/publish.py',
    'public candidate upload and publication remain disabled',
    'python -m unittest discover -s installer/release -p test_publish.py',
    'steps.release-config.outputs.build_ready == ''true''',
    'steps.release-config.outputs.delivery_enabled == ''true''',
    'needs.build.outputs.build_ready == ''true'''
)) {
    if (-not $text.Contains($required)) { throw "Workflow is missing required fail-closed guard or pinned setting: $required" }
}
if ($text -match '(?m)^\s+pull_request\s*:') { throw 'Release workflow must not run on pull requests.' }
$buildText = Get-Content -LiteralPath $build -Raw
if (-not $buildText.Contains("--build-number '0'")) { throw 'Flutter Windows build number must fit the fourth 16-bit file-version component.' }
foreach ($required in @('release-bundle','Copy-ReleaseBundle','Test-InnoCompiler','InnoVersion','/CURRENTUSER','/NOICONS','-WindowStyle Hidden')) {
    if (-not $buildText.Contains($required)) { throw "Build helper is missing the packaging safety check: $required" }
}
foreach ($required in @('SourceArchivePathspec','RequiredSourceFiles','Export-ReleaseSourceArchive','Copy-OfflineInstallerAlias','--format=tar.gz','Doorlight-Setup.exe','global.json')) {
    if (-not $buildText.Contains($required)) { throw "Build helper is missing source archive or stable installer policy: $required" }
}

$scratch = Join-Path (Join-Path $repo 'local/tmp') ('release-build-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $scratch) | Out-Null
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    $validConfig = Join-Path $scratch 'valid.json'
    $native = [ordered]@{
        daemonSourceTree=('d' * 40)
        archiveUrl='https://example.invalid/native.zip'; archiveSha256=('a' * 64)
        manifestUrl='https://example.invalid/native.json'; manifestSha256=('b' * 64)
        correspondingSourceUrl='https://example.invalid/native-source.tar.gz'; correspondingSourceSha256=('c' * 64)
    }
    $rootFile = Join-Path $scratch 'bootstrap.root.json'
    [IO.File]::WriteAllText($rootFile,'{}',[Text.UTF8Encoding]::new($false))
    $config = [ordered]@{schema=1;repository='crazy-entertainment/Doorlight';channel='stable';feedTag='update-feed';deliveryEnabled=$false;nativeInputs=$native;rootSha256=(Get-FileHash -LiteralPath $rootFile -Algorithm SHA256).Hash.ToLowerInvariant();qualification=$null}
    [IO.File]::WriteAllText($validConfig,($config | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    $scriptPath = (Resolve-Path $build).Path
    $toolPath = Join-Path $scratch 'unused-tools'
    $outputPath = Join-Path $scratch 'unused-output'
    $json = & pwsh -NoProfile -File $scriptPath -Mode ValidateConfig -ToolRoot $toolPath -OutputDirectory $outputPath -Commit ('0' * 40) -RunNumber 42 -RunAttempt 3 -ConfigPath $validConfig -RootPath $rootFile | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $json.Version -cne '1.42.3' -or [long]$json.ReleaseSequence -ne (42 * 65536 + 3)) {
        throw 'Valid config/version/sequence validation did not return the expected release identity.'
    }
    if ($json.DeliveryEnabled -ne $false) { throw 'Disabled delivery config was reported as enabled.' }
    if ((Test-Path -LiteralPath $toolPath) -or (Test-Path -LiteralPath $outputPath)) { throw 'ValidateConfig unexpectedly created build output.' }

    # Verify a binary-stable latest-download alias is an exact copy of the offline installer.
    $offlineInstaller = Join-Path $scratch 'Doorlight-1.42.3-Setup.exe'
    $stableInstaller = Join-Path $scratch 'Doorlight-Setup.exe'
    $offlineBytes = [byte[]](0,1,2,127,128,254,255,17,0)
    [IO.File]::WriteAllBytes($offlineInstaller,$offlineBytes)
    & pwsh -NoProfile -File $scriptPath -Mode CopyOfflineAlias -ToolRoot $toolPath -OutputDirectory $outputPath -Commit ('0' * 40) -RunNumber 42 -RunAttempt 3 -OfflineInstaller $offlineInstaller -StableInstaller $stableInstaller *> $null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $stableInstaller -PathType Leaf)) { throw 'Stable offline installer alias copy failed.' }
    $stableBytes = [IO.File]::ReadAllBytes($stableInstaller)
    if ($offlineBytes.Length -ne $stableBytes.Length -or
        (($offlineBytes -join ',') -cne ($stableBytes -join ',')) -or
        (Get-FileHash -LiteralPath $offlineInstaller -Algorithm SHA256).Hash -cne
            (Get-FileHash -LiteralPath $stableInstaller -Algorithm SHA256).Hash) {
        throw 'Stable offline installer alias is not byte-identical to the versioned installer.'
    }

    # Exercise the actual source export helper on a historical tree that also
    # contains private-only paths; only the build-source allowlist may escape.
    $fixtureRepo = Join-Path $scratch 'source-fixture'
    New-Item -ItemType Directory -Path $fixtureRepo | Out-Null
    & git -C $fixtureRepo init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the source archive fixture.' }
    & git -C $fixtureRepo config user.name 'Fixture Builder'
    & git -C $fixtureRepo config user.email 'fixture@example.invalid'
    $fixturePaths = @(
        '.github/workflows/windows-release.yml', 'apps/doorlight/pubspec.yaml', 'apps/doorlight/pubspec.lock',
        'apps/doorlight/windows/runner/CMakeLists.txt', 'apps/doorlight/windows/runner/jami_bridge.cpp',
        'native/jami/CMakeLists.txt', 'installer/global.json', 'installer/build.ps1',
        'installer/release/build.ps1', 'installer/release/config.json', 'installer/release/bootstrap.root.json',
        'installer/release/native-provenance.py', 'installer/release/native-notices.py',
        'installer/windows/Doorlight.Setup.csproj', 'web/site/index.html', 'services/wake-relay/package.json',
        'tools/windows-native-inputs.ps1', 'tools/windows-native-inputs-test.ps1',
        'tools/windows-native-sources.ps1', 'tools/windows-native-sources-test.ps1', 'global.json', 'LICENSE', 'README.md', '.gitignore'
    )
    foreach ($relative in $fixturePaths) {
        $path = Join-Path $fixtureRepo $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [IO.File]::WriteAllText($path,"fixture:$relative",[Text.UTF8Encoding]::new($false))
    }
    $privateFixturePaths = @('docs/private-notes.md','design/private-assets.txt','sybl/legacy.dart',
        'widget/legacy.cs','patches/private.patch','tools/old-private-tool.ps1')
    foreach ($relative in $privateFixturePaths) {
        $path = Join-Path $fixtureRepo $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [IO.File]::WriteAllText($path,'private fixture content',[Text.UTF8Encoding]::new($false))
    }
    & git -C $fixtureRepo add --all
    if ($LASTEXITCODE -ne 0) { throw 'Could not add source archive fixture files.' }
    & git -C $fixtureRepo commit --quiet -m 'fixture source tree'
    if ($LASTEXITCODE -ne 0) { throw 'Could not commit source archive fixture files.' }
    $fixtureCommit = (& git -C $fixtureRepo rev-parse HEAD).Trim()
    $fixtureArchive = Join-Path $scratch 'fixture-source.tar.gz'
    $exportResult = @(& pwsh -NoProfile -File $scriptPath -Mode ExportSourceArchive -ToolRoot $toolPath -OutputDirectory $outputPath -Commit $fixtureCommit -RunNumber 42 -RunAttempt 3 -RepositoryRoot $fixtureRepo -SourceArchive $fixtureArchive 2>&1)
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $fixtureArchive -PathType Leaf)) {
        $exportResult | ForEach-Object { Write-Host $_ }
        throw 'Allowlisted source archive export failed.'
    }
    $archivePaths = @(& tar.exe -tzf $fixtureArchive)
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the synthetic source archive.' }
    foreach ($relative in $fixturePaths) {
        if ($archivePaths -notcontains $relative) { throw "Source archive omitted required build input: $relative" }
    }
    foreach ($relative in $privateFixturePaths) {
        if ($archivePaths -contains $relative) { throw "Source archive included private historical path: $relative" }
    }
    & git -C $fixtureRepo rm --quiet native/jami/CMakeLists.txt
    & git -C $fixtureRepo commit --quiet -m 'remove required source'
    if ($LASTEXITCODE -ne 0) { throw 'Could not create missing-source fixture revision.' }
    $missingCommit = (& git -C $fixtureRepo rev-parse HEAD).Trim()
    & pwsh -NoProfile -File $scriptPath -Mode ExportSourceArchive -ToolRoot $toolPath -OutputDirectory $outputPath -Commit $missingCommit -RunNumber 42 -RunAttempt 3 -RepositoryRoot $fixtureRepo -SourceArchive (Join-Path $scratch 'missing-source.tar.gz') *> $null
    if ($LASTEXITCODE -eq 0) { throw 'Source archive accepted a commit missing required native source.' }

    $qualifiedConfig = $config | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    $qualifiedConfig.deliveryEnabled = $true
    $qualifiedConfig.qualification = [pscustomobject]@{
        reviewer='release-reviewer'; date='2026-11-02'; evidenceUrl='https://example.invalid/review'
        nativeInputsSha256=$native.archiveSha256; correspondingSourceSha256=$native.correspondingSourceSha256
    }
    $qualifiedPath = Join-Path $scratch 'qualified.json'
    [IO.File]::WriteAllText($qualifiedPath,($qualifiedConfig | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    $qualified = & pwsh -NoProfile -File $scriptPath -Mode ValidateConfig -RequireDeliveryQualification -ToolRoot $toolPath -OutputDirectory $outputPath -Commit ('0' * 40) -RunNumber 42 -RunAttempt 3 -ConfigPath $qualifiedPath -RootPath $rootFile | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $qualified.DeliveryEnabled -ne $true) { throw 'Matching qualified release config was rejected.' }

    $sourceBundle = Join-Path $scratch 'flutter-release'
    $stagedBundle = Join-Path $scratch 'maintained-bundle'
    New-Item -ItemType Directory -Path (Join-Path $sourceBundle 'data/flutter_assets'),(Join-Path $sourceBundle 'notices'),(Join-Path $sourceBundle 'ctest') -Force | Out-Null
    foreach ($file in @(
        @{Path='sybl.exe';Text='runtime exe'},
        @{Path='flutter_windows.dll';Text='flutter dll'},
        @{Path='native_assets.json';Text='{}'},
        @{Path='test-runner.exe';Text='ctest exe'},
        @{Path='sybl.pdb';Text='debug symbols'},
        @{Path='data/app.so';Text='aot'},
        @{Path='data/icudtl.dat';Text='icu'},
        @{Path='data/flutter_assets/NOTICES.Z';Text='notices'},
        @{Path='notices/LICENSE.txt';Text='license'},
        @{Path='ctest/window_presentation_test.exe';Text='ctest binary'}
    )) {
        $path = Join-Path $sourceBundle $file.Path
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [IO.File]::WriteAllText($path,$file.Text,[Text.UTF8Encoding]::new($false))
    }
    & pwsh -NoProfile -File $scriptPath -Mode StageBundle -ToolRoot $toolPath -OutputDirectory $outputPath -Commit ('0' * 40) -RunNumber 42 -RunAttempt 3 -ConfigPath $validConfig -RootPath $rootFile -SourceBundle $sourceBundle -StagedBundle $stagedBundle *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Synthetic Flutter bundle staging failed.' }
    foreach ($required in @('sybl.exe','flutter_windows.dll','native_assets.json','data/app.so','data/icudtl.dat','data/flutter_assets/NOTICES.Z','notices/LICENSE.txt')) {
        if (-not (Test-Path -LiteralPath (Join-Path $stagedBundle $required) -PathType Leaf)) { throw "Staged runtime omitted $required." }
    }
    foreach ($excluded in @('test-runner.exe','sybl.pdb','ctest','ctest/window_presentation_test.exe')) {
        if (Test-Path -LiteralPath (Join-Path $stagedBundle $excluded)) { throw "Staged runtime retained test/debug output: $excluded" }
    }

    $badConfig = Join-Path $scratch 'missing-native-pin.json'
    $config.nativeInputs.archiveSha256 = $null
    [IO.File]::WriteAllText($badConfig,($config | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    $config.deliveryEnabled = $true
    [IO.File]::WriteAllText($badConfig,($config | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    & pwsh -NoProfile -File $scriptPath -Mode ValidateConfig -RequireDeliveryQualification -ToolRoot $toolPath -OutputDirectory $outputPath -Commit ('0' * 40) -RunNumber 42 -RunAttempt 3 -ConfigPath $badConfig -RootPath $rootFile *> $null
    if ($LASTEXITCODE -eq 0) { throw 'Missing native-input digest was accepted.' }

    $badUrlConfig = Join-Path $scratch 'non-https-native-url.json'
    $config.nativeInputs.archiveSha256 = ('a' * 64)
    $config.nativeInputs.archiveUrl = 'http://example.invalid/native.zip'
    [IO.File]::WriteAllText($badUrlConfig,($config | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    & pwsh -NoProfile -File $scriptPath -Mode ValidateConfig -RequireDeliveryQualification -ToolRoot $toolPath -OutputDirectory $outputPath -Commit ('0' * 40) -RunNumber 42 -RunAttempt 3 -ConfigPath $badUrlConfig -RootPath $rootFile *> $null
    if ($LASTEXITCODE -eq 0) { throw 'Non-HTTPS native-input URL was accepted.' }

    & pwsh -NoProfile -File $scriptPath -Mode ValidateConfig -ToolRoot $toolPath -OutputDirectory $outputPath -Commit ('0' * 40) -RunNumber 65536 -RunAttempt 1 -ConfigPath $validConfig -RootPath $rootFile *> $null
    if ($LASTEXITCODE -eq 0) { throw 'Out-of-range release sequence was accepted.' }
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
$global:LASTEXITCODE = 0
Write-Host 'Windows release build helper synthetic checks passed.'
