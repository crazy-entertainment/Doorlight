param([Parameter(Mandatory)][string]$ToolsDir)
$ErrorActionPreference = 'Stop'
$version = '1.2.161'
$archiveHash = '2b56ce117f803fc70c103cb423bd040e395e40370f6ff6e10818e9ff9c26a323'
$helperHash = '9b5d28a356446c6ab61c0ec8f808fcb8a92af3cd0623a6d8fc634f1a5a1e6580'
$cliHash = 'f86d38eecbfe18127402f4d54f4c38cdca33d68a60dc7fb741d1f6155554c530'
$licenseHash = '91845db83551c877ebbb1118e0fb92e4e527290d23b995c55dcd438b3293943f'
$commit = '92d6a1c91716729d449034df5c50307dcce39493'
$root = [IO.Path]::GetFullPath($ToolsDir)
if (Test-Path -LiteralPath $root) { throw 'Choose a new tool directory.' }
New-Item -ItemType Directory -Path $root | Out-Null
$archive = Join-Path $root "vpk.$version.nupkg"
$url = "https://github.com/velopack/velopack/releases/download/$version/vpk.$version.nupkg"
Invoke-WebRequest $url -OutFile $archive
if ((Get-FileHash -LiteralPath $archive).Hash -ne $archiveHash) { throw 'Pinned vpk archive hash mismatch.' }
$tool = Join-Path $root 'tool'
[IO.Compression.ZipFile]::ExtractToDirectory($archive, $tool)
$helper = Join-Path $tool 'vendor/update.exe'
if ((Get-FileHash -LiteralPath $helper).Hash -ne $helperHash) { throw 'Pinned patch helper hash mismatch.' }
Invoke-WebRequest "https://raw.githubusercontent.com/velopack/velopack/$commit/LICENSE" -OutFile (Join-Path $root 'LICENSE-Velopack')
$cli = Join-Path $tool 'tools/net8.0/any/vpk.dll'
if ((Get-FileHash -LiteralPath $cli).Hash -ne $cliHash) { throw 'Pinned CLI hash mismatch.' }
if ((Get-FileHash -LiteralPath (Join-Path $root 'LICENSE-Velopack')).Hash -ne $licenseHash) { throw 'Pinned license hash mismatch.' }
Copy-Item -LiteralPath (Join-Path $tool 'vendor/THIRD_PARTY_NOTICES.md') -Destination (Join-Path $root 'THIRD-PARTY-NOTICES-Velopack.md')
$config = [ordered]@{Version=$version; Commit=$commit; Source=$url; ArchiveSha256=$archiveHash; VpkDll=$cli; VpkSha256=$cliHash; PatchExe=$helper; PatchSha256=$helperHash; License=(Join-Path $root 'LICENSE-Velopack');LicenseSha256=$licenseHash;Notices=(Join-Path $root 'THIRD-PARTY-NOTICES-Velopack.md')}
$config | ConvertTo-Json | Set-Content (Join-Path $root 'tools.json') -Encoding utf8
Get-Item (Join-Path $root 'tools.json')
