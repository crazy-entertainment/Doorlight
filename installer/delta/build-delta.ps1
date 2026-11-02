param(
    [Parameter(Mandatory)][string]$OldDir,
    [Parameter(Mandatory)][string]$NewDir,
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$OldVersion,
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$NewVersion,
    [Parameter(Mandatory)][string]$ToolsConfig,
    [Parameter(Mandatory)][string]$OutputDir,
    [string]$PackageId = 'DoorlightDeltaResearch'
)
$ErrorActionPreference = 'Stop'
$tools = Get-Content -LiteralPath $ToolsConfig -Raw | ConvertFrom-Json
if ($tools.Version -ne '1.2.161' -or (Get-FileHash -LiteralPath $tools.PatchExe).Hash -ne '9b5d28a356446c6ab61c0ec8f808fcb8a92af3cd0623a6d8fc634f1a5a1e6580') { throw 'Unexpected Velopack patch helper.' }
if ((Get-FileHash -LiteralPath $tools.VpkDll).Hash -ne 'f86d38eecbfe18127402f4d54f4c38cdca33d68a60dc7fb741d1f6155554c530') { throw 'Unexpected Velopack CLI.' }
$output = [IO.Path]::GetFullPath($OutputDir)
if (Test-Path -LiteralPath $output) { throw 'Choose a new output directory.' }
$old = (Resolve-Path -LiteralPath $OldDir).Path
$new = (Resolve-Path -LiteralPath $NewDir).Path
foreach ($inputPath in @($old,$new)) {
    if ($output.StartsWith($inputPath.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Output must be outside source inputs.' }
    if ((Get-Item -LiteralPath $inputPath).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Input root must not be a link.' }
    if (@(Get-ChildItem -LiteralPath $inputPath -Force -Recurse | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Input must not contain links.' }
}
New-Item -ItemType Directory -Path $output | Out-Null
function Snapshot([string]$Path) {
    $result = @{}
    Get-ChildItem -LiteralPath $Path -File -Force -Recurse | ForEach-Object {
        $relative = [IO.Path]::GetRelativePath($Path,$_.FullName).Replace('\','/')
        $result[$relative] = [ordered]@{Size=$_.Length;Sha256=(Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant()}
    }
    return $result
}
function ArchiveSnapshot([string]$Path) {
    $result = @{}
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try { foreach ($entry in $archive.Entries) {
        if (!$entry.FullName.StartsWith('lib/app/',[StringComparison]::Ordinal) -or $entry.FullName.EndsWith('/')) { continue }
        $relative = $entry.FullName.Substring(8)
        if ($result.ContainsKey($relative)) { throw 'Duplicate package member.' }
        $stream = $entry.Open()
        try { $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant() } finally { $stream.Dispose() }
        $result[$relative] = [ordered]@{Size=$entry.Length;Sha256=$hash}
    }} finally { $archive.Dispose() }
    return $result
}
function Differences($Before,$After) {
    @(@($Before.Keys)+@($After.Keys) | Sort-Object -Unique | Where-Object {
        !$Before.ContainsKey($_) -or !$After.ContainsKey($_) -or $Before[$_].Size -ne $After[$_].Size -or $Before[$_].Sha256 -ne $After[$_].Sha256
    })
}
$originalOld = Snapshot $old; $originalNew = Snapshot $new
$timings = [ordered]@{}
$packages = @{}
$altered = @{}
foreach ($label in @('old','new')) {
    $source = if ($label -eq 'old') {$old} else {$new}
    $version = if ($label -eq 'old') {$OldVersion} else {$NewVersion}
    $copy = Join-Path $output "$label-input"
    Copy-Item -LiteralPath $source -Destination $copy -Recurse
    $before = Snapshot $copy
    $release = Join-Path $output "$label-release"
    $clock = [Diagnostics.Stopwatch]::StartNew()
    & dotnet $tools.VpkDll pack --packId $PackageId --packVersion $version --packDir $copy --mainExe sybl.exe --skipVeloAppCheck --noInst --delta None --runtime win-x64 --outputDir $release --skip-updates --yes
    if ($LASTEXITCODE -ne 0) { throw "vpk pack failed for $label." }
    $timings["${label}PackSeconds"] = $clock.Elapsed.TotalSeconds
    $full = @(Get-ChildItem -LiteralPath $release -Filter '*-full.nupkg')
    if ($full.Count -ne 1) { throw 'Expected exactly one full package.' }
    $packages[$label] = $full[0].FullName
    $payload = ArchiveSnapshot $full[0].FullName
    $altered[$label] = [ordered]@{InputChanges=@(Differences $before (Snapshot $copy)); PayloadDifferences=@(Differences $before $payload)}
    $before | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $output "$label-input-hashes.json") -Encoding utf8
    $payload | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $output "$label-package-hashes.json") -Encoding utf8
}
$delta = Join-Path $output "$PackageId-$NewVersion-delta.nupkg"
$clock = [Diagnostics.Stopwatch]::StartNew()
& dotnet $tools.VpkDll delta generate --base $packages.old --new $packages.new --output $delta --skip-updates --yes
if ($LASTEXITCODE -ne 0) { throw 'Delta creation failed.' }
$timings.DeltaSeconds = $clock.Elapsed.TotalSeconds
$reconstructed = Join-Path $output 'reconstructed-full.nupkg'
$clock.Restart()
# Deliberately never invoke Velopack apply/setup/start or any application hook.
$start = [Diagnostics.ProcessStartInfo]::new($tools.PatchExe)
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
foreach ($arg in @('patch','--old',$packages.old,'--delta',$delta,'--output',$reconstructed,'--log',(Join-Path $output 'patch.log'))) { $start.ArgumentList.Add($arg) }
$patchProcess = [Diagnostics.Process]::Start($start)
try {
    while (!$patchProcess.WaitForExit(1000)) { if ($clock.Elapsed.TotalMinutes -gt 10) { throw 'Patch exceeded ten minutes; process preserved for diagnosis.' } }
    if ($patchProcess.ExitCode -ne 0) { throw "Delta reconstruction failed: $($patchProcess.ExitCode)" }
} finally { $patchProcess.Dispose() }
$timings.PatchSeconds = $clock.Elapsed.TotalSeconds
$expected = ArchiveSnapshot $packages.new
$actual = ArchiveSnapshot $reconstructed
$mismatches = @(Differences $expected $actual)
if ($mismatches.Count) { throw "Reconstruction file mismatches: $($mismatches -join ', ')" }
if (@(Differences $originalOld (Snapshot $old)).Count -or @(Differences $originalNew (Snapshot $new)).Count) { throw 'Original source inputs changed.' }
$report = [ordered]@{Version='1.2.161';OldVersion=$OldVersion;NewVersion=$NewVersion;OldFullBytes=(Get-Item $packages.old).Length;NewFullBytes=(Get-Item $packages.new).Length;DeltaBytes=(Get-Item $delta).Length;PatchHelperBytes=(Get-Item $tools.PatchExe).Length;VerifiedFiles=$expected.Count;Mismatches=$mismatches;SourceChanges=@(Differences $originalOld $originalNew);PackChanges=$altered;Seconds=$timings}
$report | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $output 'roundtrip.json') -Encoding utf8
$report | ConvertTo-Json -Depth 8
