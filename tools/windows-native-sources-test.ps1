[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows-native-sources.ps1') -Mode Library

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("doorlight-native-sources-test-" + [guid]::NewGuid().ToString('N'))
$repo = Join-Path $testRoot 'repo'
$export = Join-Path $testRoot 'export'
$treeExport = Join-Path $testRoot 'tree-export'
$null = New-Item -ItemType Directory -Path (Join-Path $repo 'native/jami') -Force
$null = New-Item -ItemType Directory -Path (Join-Path $repo 'native/jami/folder') -Force
$null = New-Item -ItemType Directory -Path $export,$treeExport -Force

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $threw = $false
    try { & $Action } catch { $threw = $true }
    Assert-True $threw $Message
}

try {
    Set-Content -LiteralPath (Join-Path $repo 'native/jami/COPYING') -Value 'license fixture' -NoNewline
    Set-Content -LiteralPath (Join-Path $repo 'native/jami/source.txt') -Value 'source fixture' -NoNewline
    Set-Content -LiteralPath (Join-Path $repo 'native/jami/folder/file.txt') -Value 'directory target' -NoNewline
    & git -C $repo init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'git init failed' }
    & git -C $repo config core.symlinks false
    & git -C $repo config user.name 'Synthetic Test'
    & git -C $repo config user.email 'synthetic@example.invalid'
    & git -C $repo add native/jami
    & git -C $repo commit --quiet -m fixture
    if ($LASTEXITCODE -ne 0) { throw 'fixture source commit failed' }

    $linkFileData = Join-Path $testRoot 'link-file-target.txt'
    $linkDirectoryData = Join-Path $testRoot 'link-directory-target.txt'
    Set-Content -LiteralPath $linkFileData -Value 'COPYING' -NoNewline
    Set-Content -LiteralPath $linkDirectoryData -Value 'folder' -NoNewline
    $fileOid = (& git -C $repo hash-object -w $linkFileData).Trim()
    $directoryOid = (& git -C $repo hash-object -w $linkDirectoryData).Trim()
    & git -C $repo update-index --add --cacheinfo "120000,$fileOid,native/jami/alias-file"
    & git -C $repo update-index --add --cacheinfo "120000,$directoryOid,native/jami/alias-directory"
    & git -C $repo checkout-index --all --force
    & git -C $repo commit --quiet -m symlink-fixtures
    if ($LASTEXITCODE -ne 0) { throw 'fixture symlink commit failed' }
    $tree = (& git -C $repo rev-parse 'HEAD:native/jami').Trim()
    Set-Content -LiteralPath (Join-Path $repo 'native/jami-source.json') -Value (@{ importedTree = $tree; upstream = 'fixture'; baseCommit = 'fixture' } | ConvertTo-Json) -NoNewline
    & git -C $repo add native/jami-source.json
    & git -C $repo commit --quiet -m identity
    if ($LASTEXITCODE -ne 0) { throw 'fixture identity commit failed' }

    $result = Export-CanonicalTree -Repo $repo -Destination $export -SourceRef 'HEAD' -ExpectedTree $tree
    Assert-True ($result.tree -eq $tree) 'export did not preserve the canonical Git subtree ID'
    Assert-True ($result.commit -eq (& git -C $repo rev-parse HEAD).Trim()) 'commit ref did not record its resolved commit'
    Assert-True ($result.files.Count -eq 5) 'export omitted tracked source or symlink entries'
    Assert-True ((Get-Content -LiteralPath (Join-Path $export 'COPYING') -Raw) -eq 'license fixture') 'exported file bytes differ'
    Assert-True ((Get-Content -LiteralPath (Join-Path $export 'alias-file') -Raw) -eq 'license fixture') 'file symlink was not safely materialized'
    Assert-True ((Get-Content -LiteralPath (Join-Path $export 'alias-directory/file.txt') -Raw) -eq 'directory target') 'directory symlink was not safely materialized'

    Assert-Throws { Resolve-ContainedPath -Root $export -RelativePath '../escape' } 'path traversal was accepted'
    Assert-Throws { Resolve-ContainedPath -Root $export -RelativePath 'C:/outside' } 'rooted/drive path was accepted'
    Assert-Throws { Resolve-ContainedLinkTarget -Root $export -LinkPath 'nested/link' -Target '../../outside' } 'escaping symlink target was accepted'
    $safeTarget = Resolve-ContainedLinkTarget -Root $export -LinkPath 'nested/link' -Target '../COPYING'
    Assert-True ($safeTarget -eq (Join-Path $export 'COPYING')) 'safe internal symlink target resolved incorrectly'

    $lfRecipe = Join-Path $testRoot 'recipe-lf.json'
    $crlfRecipe = Join-Path $testRoot 'recipe-crlf.json'
    [IO.File]::WriteAllText($lfRecipe, "{`n  `"version`": 1`n}`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($crlfRecipe, "{`r`n  `"version`": 1`r`n}`r`n", [Text.UTF8Encoding]::new($false))
    Assert-True (Test-LineContentEqual -LeftPath $lfRecipe -RightPath $crlfRecipe) 'equivalent recipe lines were treated as semantic differences'
    Assert-True ((Get-LineEndingStyle $lfRecipe) -eq 'LF') 'LF line endings were misclassified'
    Assert-True ((Get-LineEndingStyle $crlfRecipe) -eq 'CRLF') 'CRLF line endings were misclassified'

    $rootTree = (& git -C $repo rev-parse 'HEAD^{tree}').Trim()
    $treeResult = Export-CanonicalTree -Repo $repo -Destination $treeExport -SourceRef $rootTree -ExpectedTree $tree
    Assert-True ($treeResult.rootTree -eq $rootTree) 'tree ref did not record its exact root tree'
    Assert-True ($null -eq $treeResult.commit) 'a Git tree was incorrectly assigned a commit parent'

    Set-Content -LiteralPath (Join-Path $repo 'native/jami/source.txt') -Value 'dirty working copy' -NoNewline
    $dirtyResult = Export-CanonicalTree -Repo $repo -Destination (Join-Path $testRoot 'dirty-export') -SourceRef $rootTree -ExpectedTree $tree
    Assert-True ((Get-Content -LiteralPath (Join-Path $testRoot 'dirty-export/source.txt') -Raw) -eq 'source fixture') 'working-tree edits leaked into Git-object export'
    Assert-True ($dirtyResult.tree -eq $tree) 'dirty worktree changed selected Git-object tree'
    Assert-Throws { Export-CanonicalTree -Repo $repo -Destination (Join-Path $testRoot 'wrong-tree-export') -SourceRef $rootTree -ExpectedTree ('a' * 40) } 'unexpected selected source tree was accepted'

    Write-Output 'windows-native-sources synthetic tests passed'
} finally {
    # Test files are isolated under the OS temp directory.
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
