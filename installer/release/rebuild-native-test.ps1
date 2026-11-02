#Requires -Version 7.0
[CmdletBinding()]
param([hashtable]$ValidationArguments)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$script = Join-Path $PSScriptRoot 'rebuild-native.ps1'
$parseErrors = $null
[Management.Automation.Language.Parser]::ParseFile($script, [ref]$null, [ref]$parseErrors) | Out-Null
if ($parseErrors.Count) { throw 'Native rebuild script has syntax errors.' }

function Expect-Failure([hashtable]$Arguments, [string]$MessagePattern) {
    try { & $script @Arguments; throw 'Unexpected validation success.' }
    catch { if ($_.Exception.Message -notmatch $MessagePattern) { throw } }
}
$missing = Join-Path ([IO.Path]::GetTempPath()) ('doorlight-missing-' + [Guid]::NewGuid().ToString('N'))
Expect-Failure @{ Workspace=$missing; ValidateOnly=$true } 'Workspace directory is missing'
Expect-Failure @{ Workspace='C:\bad%PATH%\workspace'; ValidateOnly=$true } 'unsupported shell characters'
Expect-Failure @{ Workspace=$missing; Jobs=17; ValidateOnly=$true } 'greater than|range|validation'

if ($ValidationArguments) {
    $arguments = @{} + $ValidationArguments
    $arguments.ValidateOnly = $true
    $workspace = [IO.Path]::GetFullPath($arguments.Workspace)
    $manifest = Join-Path $workspace 'source-manifest.json'
    $beforeHash = (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash
    $sourceFile = Join-Path $workspace 'source/jami-daemon/extras/scripts/winmake.py'
    $beforeSourceHash = (Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash
    $gnutlsSource = Join-Path $workspace 'source/jami-daemon/contrib/src/gnutls/source'
    $gnutlsHashes = @{}
    foreach ($name in @('UPSTREAM.json','gnulib-3639c57a.tar.gz','libtasn1-2b7ee166.tar.gz','gnulib-aa52cadc.tar.gz')) {
        $gnutlsHashes[$name] = (Get-FileHash -LiteralPath (Join-Path $gnutlsSource $name) -Algorithm SHA256).Hash
    }
    $outputs = @('logs','tmp','build-core','.native-rebuild.lock')
    $before = @{}
    foreach ($relative in $outputs) { $before[$relative] = Test-Path -LiteralPath (Join-Path $workspace $relative) }
    & $script @arguments
    if ((Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash -cne $beforeHash -or
        (Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash -cne $beforeSourceHash) {
        throw 'ValidateOnly changed source inputs.'
    }
    foreach ($name in $gnutlsHashes.Keys) {
        if ((Get-FileHash -LiteralPath (Join-Path $gnutlsSource $name) -Algorithm SHA256).Hash -cne $gnutlsHashes[$name]) {
            throw 'ValidateOnly changed retained GnuTLS source inputs.'
        }
    }
    foreach ($relative in $outputs) {
        if ((Test-Path -LiteralPath (Join-Path $workspace $relative)) -ne $before[$relative]) {
            throw 'ValidateOnly created an output path.'
        }
    }
    Write-Host 'Real source/tool validation passed with unchanged source files and output-path presence.'
}
Write-Host 'Native rebuild parser and fail-closed validation checks passed.'
