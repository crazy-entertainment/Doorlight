param(
    [Parameter(Mandatory)][ValidateSet('Prepare','Verify')][string]$Action,
    [Parameter(Mandatory)][string]$BuildRoot,
    [ValidateSet('Debug','Release')][string]$Configuration = 'Release',
    [ValidateSet('x86','x64','ARM64')][string]$Architecture = 'x64'
)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
Set-Location -LiteralPath $repo
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$buildParent = [IO.Path]::GetFullPath((Join-Path $repo 'local/tmp/widget-build')) + [IO.Path]::DirectorySeparatorChar
if (-not $BuildRoot.StartsWith($buildParent, [StringComparison]::OrdinalIgnoreCase)) { throw 'Widget staging must stay in local/tmp/widget-build.' }
$rid = 'win-' + $Architecture.ToLowerInvariant()
$receiptPath = Join-Path $BuildRoot 'payload.json'
$publish = Join-Path $BuildRoot 'publish'
$manifest = [xml][IO.File]::ReadAllText((Join-Path $repo 'apps/widget/app/Package.appxmanifest'))
$version = $manifest.Package.Identity.Version
if ($Action -eq 'Prepare') {
    if (Test-Path -LiteralPath $BuildRoot) { throw 'Widget staging must be fresh for this build invocation.' }
    New-Item -ItemType Directory -Path $BuildRoot | Out-Null
    $intermediate = (Join-Path $BuildRoot 'obj') + '/'
    $binary = (Join-Path $BuildRoot 'bin') + '/'
    $cache = Join-Path $repo 'local/dev/nuget'
    Push-Location (Join-Path $repo 'apps/widget')
    try {
        & dotnet publish (Join-Path $repo 'apps/widget/bootstrap/helper.csproj') --configuration $Configuration --runtime $rid --self-contained true --output $publish --nologo -v quiet "-p:BaseIntermediateOutputPath=$intermediate" "-p:OutputPath=$binary" "-p:RestorePackagesPath=$cache" "-p:RestoreConfigFile=$repo/apps/widget/NuGet.Config" -p:RestoreLockedMode=true -p:ImportDirectoryBuildProps=false -p:ImportDirectoryBuildTargets=false -p:ImportDirectoryPackagesProps=false "-p:AssemblyVersion=$version"
        if ($LASTEXITCODE -ne 0) { throw "Bootstrap publish failed: $LASTEXITCODE" }
    } finally { Pop-Location }
    foreach ($required in @('helper.exe','helper.dll','helper.runtimeconfig.json','coreclr.dll','hostfxr.dll','companion-links.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $publish $required) -PathType Leaf)) { throw "Missing self-contained helper file: $required" }
    }
    $runtime = Get-Content -LiteralPath (Join-Path $publish 'helper.runtimeconfig.json') -Raw | ConvertFrom-Json
    if ($runtime.runtimeOptions.framework -or -not $runtime.runtimeOptions.includedFrameworks) { throw 'Bootstrap must include its own runtime.' }
    # Include the exact runtime pack's retained redistribution notices.
    $runtimeVersion = [string]($runtime.runtimeOptions.includedFrameworks | Where-Object name -eq 'Microsoft.NETCore.App').version
    $runtimePack = Join-Path $cache "microsoft.netcore.app.runtime.$rid/$runtimeVersion"
    foreach ($notice in @('LICENSE.TXT','THIRD-PARTY-NOTICES.TXT')) {
        $source = @(Get-ChildItem -LiteralPath $runtimePack -Recurse -File | Where-Object Name -ieq $notice)
        if ($source.Count -ne 1) { throw "Missing exact runtime notice: $notice" }
        Copy-Item -LiteralPath $source[0].FullName -Destination (Join-Path $publish $notice)
    }
    $assets = Get-Content -LiteralPath (Join-Path $repo 'apps/widget/app/obj/project.assets.json') -Raw | ConvertFrom-Json
    $lock = Get-Content -LiteralPath (Join-Path $repo 'apps/widget/app/packages.lock.json') -Raw | ConvertFrom-Json
    $framework = $lock.dependencies.PSObject.Properties | Select-Object -First 1
    $sdkVersion = $framework.Value.'Microsoft.Gaming.XboxGameBar'.resolved
    $sdkLicense = @($assets.packageFolders.PSObject.Properties.Name | ForEach-Object { Join-Path $_ "microsoft.gaming.xboxgamebar/$sdkVersion/license.txt" } | Where-Object { Test-Path -LiteralPath $_ }) | Select-Object -First 1
    if (-not $sdkLicense) { throw 'Missing locked Game Bar SDK license.' }
    Copy-Item -LiteralPath $sdkLicense -Destination (Join-Path $publish 'GAME-BAR-SDK-LICENSE.TXT')
    $files = @(Get-ChildItem -LiteralPath $publish -Recurse -File | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($publish.Length + 1).Replace('\','/')
        if ($relative -match '(?i)\.(pdb|pfx|pem|key|log)$') { throw "Unexpected bootstrap output: $relative" }
        [ordered]@{ path=$relative; size=$_.Length; sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    })
    [ordered]@{ configuration=$Configuration; rid=$rid; version=$version; runtime=$runtimeVersion; files=$files } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $receiptPath -Encoding utf8
    Write-Output "Published fresh $Configuration $rid bootstrap ($($files.Count) files)."
    return
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
if ($receipt.configuration -cne $Configuration -or $receipt.rid -cne $rid -or $receipt.version -cne $version) { throw 'Bootstrap build receipt does not match the package invocation.' }
$packages = @(Get-ChildItem -LiteralPath (Join-Path $BuildRoot 'packages') -Recurse -File -Filter *.msix)
if ($packages.Count -ne 1) { throw 'Expected exactly one widget MSIX from this invocation.' }
$archive = [IO.Compression.ZipFile]::OpenRead($packages[0].FullName)
try {
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $archive.Entries) {
        if (-not $names.Add($entry.FullName)) { throw 'Duplicate package entry.' }
        if ($entry.FullName -match '(?i)(^|/)(sybl\.exe|flutter_windows\.dll|libjami[^/]*|app\.so)$|\.(pfx|pem|key|log|pdb)$') { throw "Unexpected package payload: $($entry.FullName)" }
        if ($Configuration -eq 'Release' -and $entry.FullName -match '(?i)(^|/)(ucrtbased|vcruntime\d+d|msvcp\d+d)\.dll$') { throw 'Debug runtime in Release widget.' }
    }
    $companion = @($archive.Entries | Where-Object { $_.FullName.StartsWith('Companion/', [StringComparison]::Ordinal) -and $_.Name })
    if ($companion.Count -ne $receipt.files.Count) { throw 'Unexpected or missing helper package files.' }
    foreach ($file in $receipt.files) {
        $entry = $archive.GetEntry('Companion/' + $file.path)
        if (-not $entry -or $entry.Length -ne $file.size) { throw "Bootstrap payload mismatch: $($file.path)" }
        $stream = $entry.Open(); $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = [Convert]::ToHexString($sha.ComputeHash($stream)) } finally { $stream.Dispose(); $sha.Dispose() }
        if ($hash -cne $file.sha256) { throw "Bootstrap payload hash mismatch: $($file.path)" }
    }
    $reader = [IO.StreamReader]::new($archive.GetEntry('AppxManifest.xml').Open())
    try { $packaged = [xml]$reader.ReadToEnd() } finally { $reader.Dispose() }
    if ($packaged.Package.Identity.Name -cne $manifest.Package.Identity.Name -or $packaged.Package.Identity.Publisher -cne $manifest.Package.Identity.Publisher -or $packaged.Package.Identity.Version -cne $version -or $packaged.Package.Identity.ProcessorArchitecture -cne $Architecture.ToLowerInvariant()) { throw 'Packaged widget identity differs from the build input.' }
    if ($Configuration -eq 'Release' -and @($packaged.Package.Dependencies.PackageDependency | Where-Object Name -match 'Debug').Count) { throw 'Debug framework dependency in Release widget.' }
    foreach ($notice in @('Notices/LICENSE-Microsoft.txt','Assets/Flags/NOTICE.txt','Assets/Flags/LICENSE.txt','Assets/Fonts/OFL-Fraunces.txt','Assets/Fonts/OFL-HankenGrotesk.txt','Assets/CountryCentres-NOTICE.txt')) {
        if (-not $archive.GetEntry($notice)) { throw "Missing packaged notice: $notice" }
    }
} finally { $archive.Dispose() }
Write-Output "Verified widget package and all $($receipt.files.Count) bootstrap hashes: $($packages[0].FullName)"
