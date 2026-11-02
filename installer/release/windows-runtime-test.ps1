param([string]$VisualStudioRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $VisualStudioRoot) {
    $devcmd = & (Join-Path $PSScriptRoot '../windows-toolchain.ps1')
    $VisualStudioRoot = Split-Path (Split-Path (Split-Path $devcmd))
}
$script = Join-Path $PSScriptRoot 'windows-runtime.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('Doorlight-runtime-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$passed = 0
function New-Bundle([string]$Name) {
    $path = Join-Path $root $Name
    New-Item -ItemType Directory -Path $path | Out-Null
    [IO.File]::WriteAllText((Join-Path $path 'preserve.txt'), 'preexisting unrelated file')
    return $path
}
function Assert-Rejected([scriptblock]$Action, [string]$Message) {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_.Exception.Message }
    if (-not $caught -or $caught -notmatch $Message) { throw "Expected rejection /$Message/; got: $caught" }
    $script:passed++
}
$good = New-Bundle 'valid'
$result = & $script -BundleDir $good -VisualStudioRoot $VisualStudioRoot
$receipt = Get-Content -LiteralPath $result.ReceiptPath -Raw | ConvertFrom-Json
if ($result.FileCount -ne 10 -or $receipt.files.Count -ne 10 -or $receipt.architecture -cne 'x64') { throw 'Incomplete runtime receipt.' }
foreach ($file in $receipt.files) {
    $path = Join-Path $good $file.name
    if ((Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -cne $file.sha256 -or
        (Get-AuthenticodeSignature -LiteralPath $path).Status -ne 'Valid') { throw "Copied runtime verification failed: $path" }
}
$before = (Get-ChildItem -LiteralPath $good -Recurse -File | Get-FileHash | ConvertTo-Json)
$devcmd = Join-Path $VisualStudioRoot 'Common7/Tools/VsDevCmd.bat'
& $script -BundleDir $good -VsDevCmd $devcmd | Out-Null
$after = (Get-ChildItem -LiteralPath $good -Recurse -File | Get-FileHash | ConvertTo-Json)
if ($before -cne $after) { throw 'Idempotent packaging changed existing files.' }
$passed++

$collision = New-Bundle 'collision'
[IO.File]::WriteAllText((Join-Path $collision 'msvcp140.dll'), 'preserve conflicting DLL')
Assert-Rejected { & $script -BundleDir $collision -VisualStudioRoot $VisualStudioRoot } 'Refusing to overwrite'
if ((Get-Content -LiteralPath (Join-Path $collision 'msvcp140.dll') -Raw) -cne 'preserve conflicting DLL' -or
    @(Get-ChildItem -LiteralPath $collision -Force).Count -ne 2) { throw 'Collision rejection partially modified the bundle.' }

# Use real signed inputs for successful checks; malicious fixtures never mock signature verification.
$fakeVs = Join-Path $root 'fixture-vs'
$metadata = Join-Path $fakeVs 'VC/Auxiliary/Build'
New-Item -ItemType Directory -Path $metadata -Force | Out-Null
foreach ($kind in @('VCTools', 'VCRedist')) {
    Copy-Item -LiteralPath (Join-Path $VisualStudioRoot "VC/Auxiliary/Build/Microsoft.${kind}Version.default.txt") -Destination $metadata
}
$redistVersion = (Get-Content -LiteralPath (Join-Path $metadata 'Microsoft.VCRedistVersion.default.txt') -Raw).Trim()
$fakeRuntime = Join-Path $fakeVs "VC/Redist/MSVC/$redistVersion/x64/Microsoft.VC143.CRT"
New-Item -ItemType Directory -Path $fakeRuntime -Force | Out-Null
Copy-Item -Path (Join-Path $result.RuntimeSource '*.dll') -Destination $fakeRuntime
$legal = Join-Path $fakeVs 'Licenses/1033'
New-Item -ItemType Directory -Path $legal -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $VisualStudioRoot 'Licenses/1033/Redist.txt') -Destination $legal

$unknown = Join-Path $fakeRuntime 'vcruntime140d.dll'
[IO.File]::WriteAllText($unknown, 'debug or unexpected DLL')
$bad = New-Bundle 'unknown-file'
Assert-Rejected { & $script -BundleDir $bad -VisualStudioRoot $fakeVs } 'Unexpected Microsoft.VC143.CRT contents'
Remove-Item -LiteralPath $unknown
$target = Join-Path $fakeRuntime 'concrt140.dll'
$original = [IO.File]::ReadAllBytes($target)
[IO.File]::WriteAllText($target, 'malicious fake runtime DLL')
$bad = New-Bundle 'fake-dll'
Assert-Rejected { & $script -BundleDir $bad -VisualStudioRoot $fakeVs } 'Invalid or older-than-toolset runtime'
[IO.File]::WriteAllBytes($target, $original)

$bytes = [byte[]]$original.Clone()
$peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
$bytes[$peOffset + 4] = 0x4c
$bytes[$peOffset + 5] = 0x01
[IO.File]::WriteAllBytes($target, $bytes)
$bad = New-Bundle 'wrong-architecture'
Assert-Rejected { & $script -BundleDir $bad -VisualStudioRoot $fakeVs } 'Not an x64 PE DLL'
[IO.File]::WriteAllBytes($target, $original)

$bytes = [byte[]]$original.Clone()
$bytes[0x40] = $bytes[0x40] -bxor 1
[IO.File]::WriteAllBytes($target, $bytes)
$bad = New-Bundle 'invalid-signature'
Assert-Rejected { & $script -BundleDir $bad -VisualStudioRoot $fakeVs } 'Microsoft Authenticode verification failed'
[IO.File]::WriteAllBytes($target, $original)

$versionFile = Join-Path $metadata 'Microsoft.VCToolsVersion.default.txt'
$versionBytes = [IO.File]::ReadAllBytes($versionFile)
[IO.File]::WriteAllText($versionFile, '14.99.99999')
$bad = New-Bundle 'runtime-older-than-toolset'
Assert-Rejected { & $script -BundleDir $bad -VisualStudioRoot $fakeVs } 'Invalid or older-than-toolset runtime'
[IO.File]::WriteAllBytes($versionFile, $versionBytes)

$other = Join-Path $fakeRuntime 'msvcp140.dll'
$otherBytes = [IO.File]::ReadAllBytes($other)
[IO.File]::WriteAllBytes($other, $original)
$bad = New-Bundle 'renamed-signed-dll'
Assert-Rejected { & $script -BundleDir $bad -VisualStudioRoot $fakeVs } 'Invalid or older-than-toolset runtime'
[IO.File]::WriteAllBytes($other, $otherBytes)

$linked = Join-Path $root 'linked-vs'
New-Item -ItemType Junction -Path $linked -Target $fakeVs | Out-Null
$bad = New-Bundle 'linked-source'
Assert-Rejected { & $script -BundleDir $bad -VisualStudioRoot $linked } 'must not contain links'
$bad = New-Bundle 'linked-bundle'
New-Item -ItemType Junction -Path (Join-Path $bad 'notices') -Target $legal | Out-Null
Assert-Rejected { & $script -BundleDir $bad -VisualStudioRoot $VisualStudioRoot } 'must not contain links'

foreach ($bundle in Get-ChildItem -LiteralPath $root -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'preserve.txt') }) {
    if ((Get-Content -LiteralPath (Join-Path $bundle.FullName 'preserve.txt') -Raw) -cne 'preexisting unrelated file') {
        throw 'A preexisting bundle file was modified.'
    }
}
[pscustomobject]@{ Passed = $passed; EvidenceDirectory = $root; RuntimeReceipt = $result.ReceiptPath }
