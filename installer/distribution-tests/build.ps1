[CmdletBinding()]
param([string]$Scratch = 'C:/Users/Osman/AppData/Local/Temp/Doorlight-scale-trust-20261101/distribution-checks',
      [string]$FixtureVerifier = 'C:/Users/Osman/AppData/Local/Temp/Doorlight-scale-trust-20261101/out/DoorlightTrust.Fixture.exe')
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $Scratch | Out-Null
$compressed = Join-Path $Scratch 'DoorlightTrust.Fixture.exe.br'
$inputFile = [IO.File]::OpenRead($FixtureVerifier)
$outputFile = [IO.File]::Create($compressed)
try {
    $brotli = [IO.Compression.BrotliStream]::new($outputFile, [IO.Compression.CompressionLevel]::SmallestSize, $true)
    try { $inputFile.CopyTo($brotli) } finally { $brotli.Dispose() }
} finally { $inputFile.Dispose(); $outputFile.Dispose() }
dotnet run --project (Join-Path $PSScriptRoot 'Doorlight.Distribution.Checks.csproj') --artifacts-path (Join-Path $Scratch 'build') "-p:FixtureVerifierCompressed=$compressed" -- $Scratch $FixtureVerifier 2>&1 | Tee-Object -FilePath (Join-Path $Scratch 'distribution-tests.log')
if ($LASTEXITCODE -ne 0) { throw 'Configured distribution checks failed.' }
