[CmdletBinding()]
param(
    [string]$ToolRoot = 'C:/Users/Osman/AppData/Local/Temp/Doorlight-scale-trust-20261101',
    [string]$OutputDirectory = 'C:/Users/Osman/AppData/Local/Temp/Doorlight-scale-trust-20261101/out',
    [switch]$IncludeFixture
)
$ErrorActionPreference = 'Stop'
$version = '1.27.3'
$sdkHash = 'F26081F438319757F8A1B46D7D0B2C5EC7583D4038E485E0AA725CFDE7885FFF'
New-Item -ItemType Directory -Force -Path $ToolRoot, $OutputDirectory | Out-Null
$archive = Join-Path $ToolRoot "go$version.windows-amd64.zip"
if (!(Test-Path -LiteralPath $archive)) {
    Invoke-WebRequest "https://go.dev/dl/go$version.windows-amd64.zip" -OutFile $archive
}
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $sdkHash) {
    throw 'The Go SDK archive failed SHA256 verification.'
}
$go = Join-Path $ToolRoot 'go/bin/go.exe'
if (!(Test-Path -LiteralPath $go)) { Expand-Archive -LiteralPath $archive -DestinationPath $ToolRoot }
$names = @('GOCACHE','GOMODCACHE','GOPATH','GOTOOLCHAIN','CGO_ENABLED','GOOS','GOARCH','TEMP','TMP')
$saved = @{}
foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
Push-Location $PSScriptRoot
try {
    $env:GOCACHE = Join-Path $ToolRoot 'cache'
    $env:GOMODCACHE = Join-Path $ToolRoot 'modules'
    $env:GOPATH = Join-Path $ToolRoot 'gopath'
    $env:GOTOOLCHAIN = 'local'
    $env:CGO_ENABLED = '0'
    $env:GOOS = 'windows'
    $env:GOARCH = 'amd64'
    $env:TEMP = $ToolRoot
    $env:TMP = $ToolRoot
    & $go mod verify
    if ($LASTEXITCODE -ne 0) { throw 'Go module verification failed.' }
    & $go test -mod=readonly -count=1 -v ./... 2>&1 | Tee-Object -FilePath (Join-Path $OutputDirectory 'trust-tests.log')
    if ($LASTEXITCODE -ne 0) { throw 'Trust tests failed.' }
    & $go vet -mod=readonly ./...
    if ($LASTEXITCODE -ne 0) { throw 'Go vet failed.' }
    & $go build -mod=readonly -trimpath -buildvcs=false -ldflags '-s -w' -o (Join-Path $OutputDirectory 'DoorlightTrust.exe') .
    if ($LASTEXITCODE -ne 0) { throw 'Trust build failed.' }
    Get-FileHash -LiteralPath (Join-Path $OutputDirectory 'DoorlightTrust.exe') -Algorithm SHA256
    if ($IncludeFixture) {
        & $go test -mod=readonly -tags doorlight_fixture -count=1 -v ./... 2>&1 | Tee-Object -FilePath (Join-Path $OutputDirectory 'trust-fixture-tests.log')
        if ($LASTEXITCODE -ne 0) { throw 'Trust fixture tests failed.' }
        & $go build -mod=readonly -trimpath -buildvcs=false -tags doorlight_fixture -ldflags '-s -w' -o (Join-Path $OutputDirectory 'DoorlightTrust.Fixture.exe') .
        if ($LASTEXITCODE -ne 0) { throw 'Trust fixture build failed.' }
        Get-FileHash -LiteralPath (Join-Path $OutputDirectory 'DoorlightTrust.Fixture.exe') -Algorithm SHA256
    }
} finally {
    Pop-Location
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
}
