param([Parameter(Mandatory)][string]$BuildRoot)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
Set-Location -LiteralPath $repo
Add-Type -AssemblyName System.IO.Compression.FileSystem
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$receipt = Get-Content -LiteralPath (Join-Path $BuildRoot 'payload.json') -Raw | ConvertFrom-Json
$package = @(Get-ChildItem -LiteralPath (Join-Path $BuildRoot 'packages') -Recurse -File -Filter *.msix)
if ($package.Count -ne 1) { throw 'Expected one built package to exercise.' }
$verify = Join-Path $PSScriptRoot 'widget-package.ps1'
& $verify -Action Verify -BuildRoot $BuildRoot -Configuration $receipt.configuration -Architecture $receipt.rid.Substring(4) | Out-Null
$checks = 1
function Reject([scriptblock]$Run, [string]$Expected) {
    try { & $Run | Out-Null } catch { if ($_.Exception.Message.Contains($Expected)) { $script:checks++; return }; throw }
    throw "Expected package refusal: $Expected"
}
Reject { & $verify -Action Prepare -BuildRoot $BuildRoot -Configuration $receipt.configuration -Architecture $receipt.rid.Substring(4) } 'must be fresh'
Reject { & $verify -Action Verify -BuildRoot $BuildRoot -Configuration $(if ($receipt.configuration -eq 'Release') { 'Debug' } else { 'Release' }) -Architecture $receipt.rid.Substring(4) } 'does not match'
foreach ($case in @('helper-hash','extra-helper','main-app','missing-notice')) {
    $fixture = Join-Path $repo ('local/tmp/widget-build/package-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $fixture 'packages') | Out-Null
    Copy-Item -LiteralPath (Join-Path $BuildRoot 'payload.json') -Destination (Join-Path $fixture 'payload.json')
    $copy = Join-Path $fixture 'packages/widget.msix'
    Copy-Item -LiteralPath $package[0].FullName -Destination $copy
    $zip = [IO.Compression.ZipFile]::Open($copy, [IO.Compression.ZipArchiveMode]::Update)
    try {
        switch ($case) {
            'helper-hash' {
                $entry = $zip.GetEntry('Companion/helper.dll'); $input = $entry.Open(); $bytes = [IO.MemoryStream]::new()
                try { $input.CopyTo($bytes); $body = $bytes.ToArray() } finally { $input.Dispose(); $bytes.Dispose() }
                $body[0] = $body[0] -bxor 1; $entry.Delete(); $entry = $zip.CreateEntry('Companion/helper.dll')
                $output = $entry.Open(); try { $output.Write($body, 0, $body.Length) } finally { $output.Dispose() }
            }
            'extra-helper' { $entry = $zip.CreateEntry('Companion/unexpected.exe'); $output = $entry.Open(); $output.Dispose() }
            'main-app' { $entry = $zip.CreateEntry('sybl.exe'); $output = $entry.Open(); $output.Dispose() }
            'missing-notice' { $zip.GetEntry('Notices/LICENSE-Microsoft.txt').Delete() }
        }
    } finally { $zip.Dispose() }
    $expected = switch ($case) { 'helper-hash' { 'hash mismatch' }; 'extra-helper' { 'Unexpected or missing helper' }; 'main-app' { 'Unexpected package payload' }; 'missing-notice' { 'Missing packaged notice' } }
    Reject { & $verify -Action Verify -BuildRoot $fixture -Configuration $receipt.configuration -Architecture $receipt.rid.Substring(4) } $expected
}
Write-Output "$checks package integrity and legitimate-control checks passed."
