[CmdletBinding()]
param(
    [ValidateSet('Stage', 'Library')]
    [string]$Mode = 'Stage',
    [string]$Workspace,
    [string]$RepoRoot,
    [string]$SourceRef = 'HEAD',
    [string]$ExpectedSourceTree,
    [string]$DaemonRoot,
    [string]$DependencyManifest,
    [string]$ToolchainManifest,
    [string]$ToolchainDownloadRoot,
    [string]$PywinmakePackageRoot,
    [string]$OverlayRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-LineEndingStyle([string]$Path) {
    $text = [IO.File]::ReadAllText($Path)
    $crlf = [regex]::Matches($text, "`r`n").Count
    $lf = [regex]::Matches($text, "(?<!`r)`n").Count
    $cr = [regex]::Matches($text, "`r(?!`n)").Count
    if ($crlf -gt 0 -and $lf -eq 0 -and $cr -eq 0) { return 'CRLF' }
    if ($lf -gt 0 -and $crlf -eq 0 -and $cr -eq 0) { return 'LF' }
    if ($crlf -eq 0 -and $lf -eq 0 -and $cr -eq 0) { return 'none' }
    return 'mixed'
}

function Test-LineContentEqual([string]$LeftPath, [string]$RightPath) {
    $left = [IO.File]::ReadAllText($LeftPath).Replace("`r`n", "`n").Replace("`r", "`n")
    $right = [IO.File]::ReadAllText($RightPath).Replace("`r`n", "`n").Replace("`r", "`n")
    return $left -ceq $right
}

function Resolve-ContainedPath([string]$Root, [string]$RelativePath) {
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath.Contains(':')) {
        throw "Invalid relative path: $RelativePath"
    }
    $normalized = $RelativePath.Replace('/', '\')
    if ([IO.Path]::IsPathRooted($normalized)) { throw "Rooted path is not allowed: $RelativePath" }
    $segments = $normalized.Split('\')
    if ($segments | Where-Object { $_ -eq '' -or $_ -eq '.' -or $_ -eq '..' }) {
        throw "Unsafe path segment in: $RelativePath"
    }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $result = [IO.Path]::GetFullPath((Join-Path $Root $normalized))
    if (-not $result.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes root: $RelativePath"
    }
    return $result
}

function Resolve-ContainedLinkTarget([string]$Root, [string]$LinkPath, [string]$Target) {
    if ([string]::IsNullOrWhiteSpace($Target) -or [IO.Path]::IsPathRooted($Target) -or $Target.Contains(':')) {
        throw "Invalid symlink target '$Target' at '$LinkPath'"
    }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $linkFull = Resolve-ContainedPath -Root $Root -RelativePath $LinkPath
    $resolved = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $linkFull) $Target))
    if (-not $resolved.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Symlink target escapes root: $LinkPath -> $Target"
    }
    return $resolved
}

function Copy-GitBlob([string]$Repository, [string]$Oid, [string]$Destination) {
    $git = [Diagnostics.ProcessStartInfo]::new()
    $git.FileName = 'git'
    $git.ArgumentList.Add('cat-file')
    $git.ArgumentList.Add('blob')
    $git.ArgumentList.Add($Oid)
    $git.WorkingDirectory = $Repository
    $git.UseShellExecute = $false
    $git.RedirectStandardOutput = $true
    $git.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($git)
    try {
        $file = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $process.StandardOutput.BaseStream.CopyTo($file) } finally { $file.Dispose() }
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "git cat-file failed for $Oid`: $stderr" }
    } finally { $process.Dispose() }
}

function Export-CanonicalTree([string]$Repo, [string]$Destination, [string]$SourceRef = 'HEAD', [string]$ExpectedTree) {
    if ($ExpectedTree -cnotmatch '^[0-9a-f]{40}$') { throw 'ExpectedSourceTree must be a full 40-digit Git tree ID.' }
    $sourceObject = (& git -C $Repo rev-parse --verify $SourceRef).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Unable to resolve source ref '$SourceRef'." }
    $rootTree = (& git -C $Repo rev-parse --verify "${sourceObject}^{tree}").Trim()
    if ($LASTEXITCODE -ne 0) { throw "Source ref '$SourceRef' does not resolve to a Git tree." }
    $commit = $null
    $candidateCommit = & git -C $Repo rev-parse --verify "${sourceObject}^{commit}" 2>$null
    if ($LASTEXITCODE -eq 0) { $commit = ($candidateCommit | Out-String).Trim() }
    $tree = (& git -C $Repo rev-parse --verify "${sourceObject}:native/jami").Trim()
    if ($LASTEXITCODE -ne 0) { throw "Source ref '$SourceRef' has no native/jami tree." }
    if ($tree -cne $ExpectedTree) { throw "Selected native/jami tree $tree does not match expected tree $ExpectedTree." }
    $identityOid = (& git -C $Repo rev-parse --verify "${sourceObject}:native/jami-source.json").Trim()
    if ($LASTEXITCODE -ne 0) { throw "Source ref '$SourceRef' has no native/jami-source.json metadata." }
    $identityJson = (& git -C $Repo cat-file blob $identityOid) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw 'Unable to read source-ref native/jami-source.json from Git objects.' }
    $identity = $identityJson | ConvertFrom-Json

    $lines = @(& git -C $Repo ls-tree -r $tree)
    if ($LASTEXITCODE -ne 0 -or $lines.Count -eq 0) { throw 'Unable to enumerate canonical native/jami tree.' }
    $entries = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $lines) {
        if ($line -notmatch '^(\d{6}) blob ([0-9a-f]{40,64})\t(.+)$') { throw "Unsupported Git tree entry: $line" }
        $mode = $Matches[1]
        $oid = $Matches[2]
        $relative = $Matches[3]
        $destinationPath = Resolve-ContainedPath -Root $Destination -RelativePath $relative
        if (-not $seen.Add($relative.Replace('/', '\'))) { throw "Case-insensitive duplicate path in source tree: $relative" }
        if ($mode -notin @('100644', '100755', '120000')) { throw "Unsupported Git mode $mode at $relative" }
        $entries.Add([pscustomobject]@{ mode = $mode; oid = $oid; path = $relative; destination = $destinationPath })
    }

    foreach ($entry in $entries | Where-Object mode -ne '120000') {
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $entry.destination) -Force
        Copy-GitBlob -Repository $Repo -Oid $entry.oid -Destination $entry.destination
    }

    $exported = [Collections.Generic.List[object]]::new()
    foreach ($entry in $entries) {
        if ($entry.mode -eq '120000') {
            $linkData = Join-Path ([IO.Path]::GetTempPath()) ("doorlight-link-" + [guid]::NewGuid().ToString('N') + '.tmp')
            try {
                Copy-GitBlob -Repository $Repo -Oid $entry.oid -Destination $linkData
                $target = [IO.File]::ReadAllText($linkData, [Text.Encoding]::UTF8)
            } finally { Remove-Item -LiteralPath $linkData -Force }
            $resolvedTarget = Resolve-ContainedLinkTarget -Root $Destination -LinkPath $entry.path -Target $target
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $entry.destination) -Force
            if (Test-Path -LiteralPath $resolvedTarget -PathType Leaf) {
                if ($entries | Where-Object { $_.destination -eq $resolvedTarget -and $_.mode -eq '120000' }) {
                    throw "Symlink points to another symlink: $($entry.path) -> $target"
                }
                Copy-Item -LiteralPath $resolvedTarget -Destination $entry.destination
                $exported.Add([pscustomobject]@{
                    path = $entry.path; gitMode = $entry.mode; gitBlob = $entry.oid
                    materializedAs = 'copy-of-contained-tracked-file'; symlinkTarget = $target
                    bytes = (Get-Item -LiteralPath $entry.destination).Length; sha256 = Get-Sha256 $entry.destination
                })
            } elseif (Test-Path -LiteralPath $resolvedTarget -PathType Container) {
                $prefix = $resolvedTarget.TrimEnd('\') + '\'
                $targets = @($entries | Where-Object { $_.destination.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
                if ($targets.Count -eq 0 -or ($targets | Where-Object mode -eq '120000')) {
                    throw "Symlink target directory is empty or contains a link: $($entry.path) -> $target"
                }
                $copies = [Collections.Generic.List[object]]::new()
                foreach ($targetEntry in $targets) {
                    $suffix = $targetEntry.destination.Substring($prefix.Length)
                    $aliasRelative = ($entry.path.Replace('/', '\') + '\' + $suffix)
                    $alias = Resolve-ContainedPath -Root $Destination -RelativePath $aliasRelative
                    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $alias) -Force
                    Copy-Item -LiteralPath $targetEntry.destination -Destination $alias
                    $copies.Add([pscustomobject]@{ path = $aliasRelative.Replace('\','/'); bytes = (Get-Item -LiteralPath $alias).Length; sha256 = Get-Sha256 $alias })
                }
                $exported.Add([pscustomobject]@{ path = $entry.path; gitMode = $entry.mode; gitBlob = $entry.oid; materializedAs = 'copy-of-contained-tracked-directory'; symlinkTarget = $target; copiedFiles = @($copies) })
            } else { throw "Symlink target is absent: $($entry.path) -> $target" }
        } else {
            $exported.Add([pscustomobject]@{
                path = $entry.path; gitMode = $entry.mode; gitBlob = $entry.oid
                materializedAs = 'regular-file'; bytes = (Get-Item -LiteralPath $entry.destination).Length
                sha256 = Get-Sha256 $entry.destination
            })
        }
    }
    return [pscustomobject]@{ sourceRef = $SourceRef; rootTree = $rootTree; commit = $commit; tree = $tree; historicalImportedTree = $identity.importedTree; upstream = $identity.upstream; baseCommit = $identity.baseCommit; files = @($exported) }
}

function Invoke-SourceStage {
    foreach ($required in @('Workspace','RepoRoot','DaemonRoot','DependencyManifest','ToolchainManifest','ToolchainDownloadRoot','PywinmakePackageRoot','OverlayRoot')) {
        if ([string]::IsNullOrWhiteSpace((Get-Variable -Name $required -ValueOnly))) { throw "-$required is required." }
    }
    $workspaceFull = [IO.Path]::GetFullPath($Workspace)
    if (Test-Path -LiteralPath $workspaceFull) { throw "Workspace already exists; refusing to overwrite: $workspaceFull" }
    $dependency = Get-Content -LiteralPath $DependencyManifest -Raw | ConvertFrom-Json
    if ($dependency.schema -ne 1 -or @($dependency.packages).Count -ne 32) { throw 'Expected schema-1 dependency manifest containing 32 source records.' }
    $toolchain = Get-Content -LiteralPath $ToolchainManifest -Raw | ConvertFrom-Json
    if ($toolchain.versions.pywinmake -ne '0.5.11') { throw 'Unexpected pywinmake version in toolchain manifest.' }

    $null = New-Item -ItemType Directory -Path $workspaceFull
    $sourceRoot = Join-Path $workspaceFull 'source'
    $daemonStage = Join-Path $sourceRoot 'jami-daemon'
    $vendorRoot = Join-Path $sourceRoot 'vendor'
    $evidenceRoot = Join-Path $workspaceFull 'qualification'
    $patchRoot = Join-Path $evidenceRoot 'patches'
    $null = New-Item -ItemType Directory -Path $daemonStage,$vendorRoot,$patchRoot -Force

    $expectedTree = $ExpectedSourceTree
    if ([string]::IsNullOrWhiteSpace($expectedTree)) {
        $releaseConfig = Get-Content -LiteralPath (Join-Path $RepoRoot 'installer/release/config.json') -Raw | ConvertFrom-Json
        $expectedTree = [string]$releaseConfig.nativeInputs.daemonSourceTree
    }
    $tree = Export-CanonicalTree -Repo $RepoRoot -Destination $daemonStage -SourceRef $SourceRef -ExpectedTree $expectedTree
    $archiveDirectory = Resolve-Path (Join-Path $DaemonRoot 'contrib/tarballs')
    $archiveRecords = [Collections.Generic.List[object]]::new()
    foreach ($package in $dependency.packages) {
        $name = [IO.Path]::GetFileName([string]$package.tarball)
        if ($name -ne $package.tarball -or $name -match '[\\/:]') { throw "Unsafe tarball filename: $($package.tarball)" }
        $sourceArchive = Join-Path $archiveDirectory.Path $name
        if (-not (Test-Path -LiteralPath $sourceArchive -PathType Leaf)) { throw "Missing retained source archive: $sourceArchive" }
        $info = Get-Item -LiteralPath $sourceArchive
        $sha = Get-Sha256 $sourceArchive
        if ($info.Length -ne [long]$package.tarballBytes -or $sha -ne $package.tarballSha256) {
            throw "Source archive differs from retained provenance record: $name"
        }
        $sourceRecipe = Join-Path (Join-Path $RepoRoot 'native/jami') $package.recipePath.Replace('/', '\')
        $recipe = Get-Content -LiteralPath $sourceRecipe -Raw | ConvertFrom-Json
        $resolvedUrl = ([string]$recipe.url).Replace('__VERSION__', [string]$recipe.version)
        if ($recipe.version -ne $package.version -or $resolvedUrl -ne $package.url) {
            throw "Canonical recipe version/URL does not match retained archive record for $($package.name)."
        }
        $destination = Resolve-ContainedPath -Root (Join-Path $daemonStage 'contrib/tarballs') -RelativePath $name
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force
        Copy-Item -LiteralPath $sourceArchive -Destination $destination
        if ((Get-Sha256 $destination) -ne $sha) { throw "Copied source archive hash mismatch: $name" }
        $externalRecipe = Join-Path (Join-Path $DaemonRoot 'contrib/src') $package.name
        $externalRecipe = Join-Path $externalRecipe 'package.json'
        $canonicalRecipeHash = Get-Sha256 $sourceRecipe
        $externalHash = if (Test-Path -LiteralPath $externalRecipe -PathType Leaf) { Get-Sha256 $externalRecipe } else { $null }
        $lineContentMatches = if ($externalHash) { Test-LineContentEqual -LeftPath $sourceRecipe -RightPath $externalRecipe } else { $false }
        $archiveRecords.Add([pscustomobject]@{
            name = $package.name; version = $package.version; url = $package.url
            tarball = $name; bytes = $info.Length; sha256 = $sha
            historicalRecipeSha256 = $package.recipeSha256; canonicalRecipeSha256 = $canonicalRecipeHash
            externalRecipeSha256 = $externalHash; externalRecipeMatchesCanonical = ($externalHash -eq $canonicalRecipeHash)
            externalRecipeLineContentMatches = $lineContentMatches
            canonicalRecipeLineEndings = (Get-LineEndingStyle $sourceRecipe)
            externalRecipeLineEndings = if ($externalHash) { Get-LineEndingStyle $externalRecipe } else { $null }
            buildHashFromHistoricalManifest = $package.buildHash
        })
    }

    $pywinmakeSource = Join-Path $vendorRoot 'pywinmake'
    $versionFile = Join-Path $PywinmakePackageRoot '__init__.py'
    if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf) -or (Get-Content -LiteralPath $versionFile -Raw) -notmatch "0\.5\.11") {
        throw 'The supplied local pywinmake source is not version 0.5.11.'
    }
    $null = New-Item -ItemType Directory -Path $pywinmakeSource -Force
    Get-ChildItem -LiteralPath $PywinmakePackageRoot -Force -Recurse |
        Where-Object { $_.FullName -notmatch '[\\/]__pycache__(?:[\\/]|$)' -and $_.Extension -ne '.pyc' } |
        ForEach-Object {
            $relative = $_.FullName.Substring($PywinmakePackageRoot.TrimEnd('\').Length).TrimStart('\')
            $target = Resolve-ContainedPath -Root $pywinmakeSource -RelativePath $relative
            if ($_.PSIsContainer) { $null = New-Item -ItemType Directory -Path $target -Force }
            else { $null = New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force; Copy-Item -LiteralPath $_.FullName -Destination $target }
        }
    $pywinmakePatch = Join-Path $OverlayRoot 'pywinmake-0.5.11.patch'
    $windowsPatch = Join-Path $OverlayRoot 'windows-tools.patch'
    foreach ($patch in @($pywinmakePatch, $windowsPatch)) {
        if (-not (Test-Path -LiteralPath $patch -PathType Leaf)) { throw "Required native build overlay not found: $patch" }
        Copy-Item -LiteralPath $patch -Destination (Join-Path $patchRoot ([IO.Path]::GetFileName($patch)))
    }
    $pyPatchPath = Join-Path $patchRoot 'pywinmake-0.5.11.patch'
    $pyApply = Start-Process -FilePath 'git' -ArgumentList @('-C', $vendorRoot, 'apply', '--reverse', '--check', $pyPatchPath) -NoNewWindow -Wait -PassThru
    $pywinmakeOverlayStatus = if ($pyApply.ExitCode -eq 0) { 'already-applied-in-source-copy' } else {
        $pyApply = Start-Process -FilePath 'git' -ArgumentList @('-C', $vendorRoot, 'apply', '--check', $pyPatchPath) -NoNewWindow -Wait -PassThru
        if ($pyApply.ExitCode -eq 0) {
            $pyApply = Start-Process -FilePath 'git' -ArgumentList @('-C', $vendorRoot, 'apply', $pyPatchPath) -NoNewWindow -Wait -PassThru
            if ($pyApply.ExitCode -ne 0) { throw 'Unable to apply the recorded pywinmake local overlay.' }
            'applied-by-stage-script'
        } else {
            $versioner = Get-Content -LiteralPath (Join-Path $pywinmakeSource 'package/versioner.py') -Raw
            $vsEnv = Get-Content -LiteralPath (Join-Path $pywinmakeSource 'dev_env/vs_env.py') -Raw
            if ($versioner -notmatch '_has_rebuilt_deps_since' -or $vsEnv -notmatch 'PYWINMAKE_MAX_JOBS') {
                throw 'Local pywinmake source differs from the recorded overlay and lacks its required build controls.'
            }
            'patch-context-mismatch; required local controls present; source files hashed in manifest'
        }
    }

    $toolRecords = [Collections.Generic.List[object]]::new()
    foreach ($executable in $toolchain.executables) {
        $path = [string]$executable.path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Pinned toolchain executable is missing: $path" }
        $info = Get-Item -LiteralPath $path
        $sha = Get-Sha256 $path
        if ($info.Length -ne [long]$executable.bytes -or $sha -ne $executable.sha256) { throw "Pinned toolchain executable differs from record: $path" }
        $toolRecords.Add([pscustomobject]@{ path = $path; bytes = $info.Length; sha256 = $sha })
    }
    $downloadRecords = [Collections.Generic.List[object]]::new()
    foreach ($download in $toolchain.downloads) {
        $path = Join-Path $ToolchainDownloadRoot $download.name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Pinned toolchain download is missing: $path" }
        $info = Get-Item -LiteralPath $path
        $sha = Get-Sha256 $path
        if ($info.Length -ne [long]$download.bytes -or $sha -ne $download.sha256) { throw "Pinned toolchain download differs from record: $path" }
        $downloadRecords.Add([pscustomobject]@{ name = $download.name; path = $path; bytes = $info.Length; sha256 = $sha })
    }
    $canonicalFfmpeg = Get-Content -LiteralPath (Join-Path $daemonStage 'contrib/src/ffmpeg/build_ffmpeg.bat') -Raw
    $canonicalUpnpPatch = Get-Content -LiteralPath (Join-Path $daemonStage 'contrib/src/upnp/libupnp-windows.patch') -Raw
    $windowsOverlayRepresented = $canonicalFfmpeg.Contains('MSYS2_BIN') -and $canonicalUpnpPatch.Contains('<UseOfMfc>false</UseOfMfc>')
    $sourceManifest = [ordered]@{
        schema = 1
        status = 'source-staged; native rebuild and release qualification not performed'
        source = [ordered]@{ selectedSourceRef = $tree.sourceRef; resolvedCommit = $tree.commit; rootTree = $tree.rootTree; materializedFrom = 'Git objects only'; canonicalPath = 'native/jami'; gitTree = $tree.tree; expectedSourceTree = $expectedTree; historicalImportedTree = $tree.historicalImportedTree; upstream = $tree.upstream; baseCommit = $tree.baseCommit }
        sourceFiles = $tree.files
        dependencySourceManifest = [ordered]@{ path = (Resolve-Path $DependencyManifest).Path; sha256 = Get-Sha256 $DependencyManifest; generatedUtc = $dependency.generatedUtc; daemonHeadAtCapture = $dependency.daemonHead; packages = $archiveRecords }
        nativeRecipeComparison = [ordered]@{
            externalDaemonRoot = [IO.Path]::GetFullPath($DaemonRoot)
            byteDifferences = @($archiveRecords | Where-Object { -not $_.externalRecipeMatchesCanonical } | Select-Object name,canonicalRecipeSha256,externalRecipeSha256,externalRecipeLineContentMatches,canonicalRecipeLineEndings,externalRecipeLineEndings)
            semanticDifferences = @($archiveRecords | Where-Object { -not $_.externalRecipeLineContentMatches } | Select-Object name,canonicalRecipeSha256,externalRecipeSha256)
            lineEndingOnlyCount = @($archiveRecords | Where-Object { -not $_.externalRecipeMatchesCanonical -and $_.externalRecipeLineContentMatches }).Count
        }
        buildTooling = [ordered]@{
            toolchainManifest = [ordered]@{ path = (Resolve-Path $ToolchainManifest).Path; sha256 = Get-Sha256 $ToolchainManifest; generatedUtc = $toolchain.generatedUtc; versions = $toolchain.versions; jobCaps = $toolchain.jobCaps }
            installedExecutables = @($toolRecords)
            downloadReferences = @($downloadRecords)
            pywinmake = [ordered]@{ version = '0.5.11'; sourcePath = [IO.Path]::GetFullPath($PywinmakePackageRoot); stagedPath = 'source/vendor/pywinmake'; sourceFiles = @(Get-ChildItem -LiteralPath $pywinmakeSource -File -Recurse | ForEach-Object { [pscustomobject]@{ path = $_.FullName.Substring($sourceRoot.TrimEnd('\').Length + 1).Replace('\','/'); bytes = $_.Length; sha256 = Get-Sha256 $_.FullName } }); license = 'MIT, per source SPDX headers'; licenseTextIncluded = $false; localOverlay = 'qualification/patches/pywinmake-0.5.11.patch'; overlaySha256 = Get-Sha256 $pywinmakePatch; overlayStatus = $pywinmakeOverlayStatus }
            windowsOverlay = [ordered]@{ path = 'qualification/patches/windows-tools.patch'; sha256 = Get-Sha256 $windowsPatch; alreadyRepresentedInCanonicalSource = $windowsOverlayRepresented; applyBeforeBuild = (-not $windowsOverlayRepresented) }
        }
    }
    $manifestPath = Join-Path $workspaceFull 'source-manifest.json'
    $sourceManifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath -Encoding utf8
    Copy-Item -LiteralPath $DependencyManifest -Destination (Join-Path $evidenceRoot 'dependency-sources.original.json')
    Copy-Item -LiteralPath $ToolchainManifest -Destination (Join-Path $evidenceRoot 'toolchain-and-downloads.original.json')
    Write-Output "Source tree staged at: $daemonStage"
    Write-Output "Source manifest: $manifestPath"
    $lineEndingOnly = @($archiveRecords | Where-Object { -not $_.externalRecipeMatchesCanonical -and $_.externalRecipeLineContentMatches }).Count
    $semanticDiffs = @($archiveRecords | Where-Object { -not $_.externalRecipeLineContentMatches }).Count
    Write-Output "External recipe byte differences: $(@($archiveRecords | Where-Object { -not $_.externalRecipeMatchesCanonical }).Count); line-ending-only: $lineEndingOnly; line-content differences: $semanticDiffs. Canonical source recipes were staged."
    Write-Output 'No native builds or qualification were performed.'
}

if ($Mode -eq 'Stage') { Invoke-SourceStage }
