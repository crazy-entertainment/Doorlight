param(
    [ValidateSet('Pack', 'Expand')][string]$Mode,
    [string]$SourceRoot,
    [string]$OutputZip,
    [string]$ManifestPath,
    [string]$ArchivePath,
    [string]$TargetRoot
)

$ErrorActionPreference = 'Stop'
$script:MaxManifestBytes = 16MB
$script:MaxManifestFiles = 200000
$script:MaxBundleBytes = 8GB

function Get-ProductionPins {
    return @{
        'build/lib/jami-core.lib' = '0627fc0bb451a2512af9149bf36975b7e881488b7b60ad15b65fe7aa5ac3bb97'
        'contrib/build/openssl/libssl-3-x64.dll' = '3439682725f47df19c93b5e449642812ae9f9135468137e03d8966bad7c9d0f8'
        'contrib/build/openssl/libcrypto-3-x64.dll' = '7766156d8f8270e5156025db483b7306e8ba248e3e43ea5f2f8457656fd7e5fe'
    }
}

function Get-NativeInputScopes {
    return @(
        @{ Path = 'build/lib/jami-core.lib'; Kind = 'File' }
        @{ Path = 'contrib/build/openssl/libssl-3-x64.dll'; Kind = 'File' }
        @{ Path = 'contrib/build/openssl/libcrypto-3-x64.dll'; Kind = 'File' }
        @{ Path = 'contrib/build/jsoncpp/src/lib_json/json_reader.cpp'; Kind = 'File' }
        @{ Path = 'contrib/build/jsoncpp/src/lib_json/json_value.cpp'; Kind = 'File' }
        @{ Path = 'contrib/build/jsoncpp/src/lib_json/json_writer.cpp'; Kind = 'File' }
        @{ Path = 'contrib/build/jsoncpp/src/lib_json/json_tool.h'; Kind = 'File' }
        @{ Path = 'contrib/build/jsoncpp/src/lib_json/json_valueiterator.inl'; Kind = 'File' }
        @{ Path = 'contrib/build/jsoncpp/include'; Kind = 'Headers' }
        @{ Path = 'contrib/build/ffmpeg/Build/win32/x64/include'; Kind = 'Headers' }
        @{ Path = 'contrib/msvc/lib/x64'; Kind = 'Libraries' }
        @{ Path = 'contrib/build/ffmpeg/Build/win32/x64/lib'; Kind = 'Libraries' }
        @{ Path = 'contrib/build/opendht/build/Release'; Kind = 'Libraries' }
        @{ Path = 'contrib/build/argon2/vs2015/Argon2Ref/vs2015/build'; Kind = 'Libraries' }
        @{ Path = 'contrib/build/yaml-cpp/build/Release'; Kind = 'Libraries' }
        @{ Path = 'contrib/build/natpmp/build/Release'; Kind = 'Libraries' }
        @{ Path = 'contrib/build/pjproject/pjsip/lib'; Kind = 'Libraries' }
        @{ Path = 'contrib/build/pjproject/pjmedia/lib'; Kind = 'Libraries' }
        @{ Path = 'contrib/build/pjproject/pjlib-util/lib'; Kind = 'Libraries' }
        @{ Path = 'contrib/build/pjproject/pjlib/lib'; Kind = 'Libraries' }
        @{ Path = 'contrib/build/pjproject/pjnath/lib'; Kind = 'Libraries' }
        @{ Path = 'contrib/build/fmt/msvc/Release'; Kind = 'Libraries' }
        @{ Path = 'contrib/build/llhttp/build/Release'; Kind = 'Libraries' }
        @{ Path = 'contrib/build/openssl'; Kind = 'Libraries' }
        @{ Path = 'contrib/build/speexdsp/lib'; Kind = 'Libraries' }
        @{ Path = 'contrib/build/webrtc-audio-processing/build/Release'; Kind = 'Libraries' }
        @{ Path = 'contrib/build/portaudio/build/Release'; Kind = 'Libraries' }
        @{ Path = 'contrib/build/libgit2/build/Release'; Kind = 'Libraries' }
        @{ Path = 'contrib/build/dhtnet/build/Release'; Kind = 'Libraries' }
        @{ Path = 'notices/native'; Kind = 'Notices' }
        @{ Path = 'contrib/build/simdutf/build/src/Release'; Kind = 'Libraries' }
    )
}

function Normalize-ManifestPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Contains('\') -or $Path.Contains(':') -or
        $Path.StartsWith('/') -or $Path -match '[\x00-\x1f]') {
        throw "Invalid native input path: $Path"
    }
    $parts = $Path.Split('/')
    if ($parts.Count -eq 0 -or @($parts | Where-Object { $_ -in @('', '.', '..') }).Count) {
        throw "Invalid native input path: $Path"
    }
    return $Path
}

function Assert-AllowedNativePath([string]$Path) {
    $Path = Normalize-ManifestPath $Path
    foreach ($scope in Get-NativeInputScopes) {
        if ($scope.Kind -eq 'File' -and $Path -ceq $scope.Path) { return }
        if ($scope.Kind -ne 'File' -and $Path.StartsWith($scope.Path + '/', [StringComparison]::OrdinalIgnoreCase)) {
            if ($scope.Kind -eq 'Libraries' -and [IO.Path]::GetExtension($Path) -ine '.lib') { continue }
            return
        }
    }
    throw "Native input is outside the CMake input scope: $Path"
}

function Assert-NoReparseTree([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point is not allowed: $Path" }
    if ($item.PSIsContainer) {
        foreach ($child in Get-ChildItem -LiteralPath $Path -Force) { Assert-NoReparseTree $child.FullName }
    }
}

function Assert-NoReparseAncestors([string]$Root, [string]$RelativePath) {
    $current = [IO.Path]::GetFullPath($Root)
    foreach ($part in (Normalize-ManifestPath $RelativePath).Split('/')) {
        $current = Join-Path $current $part
        if (-not (Test-Path -LiteralPath $current)) { break }
        if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Reparse point in native input path: $current"
        }
    }
}

function Get-NativeInputFiles([string]$Root) {
    $Root = [IO.Path]::GetFullPath($Root)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw "Native input root does not exist: $Root" }
    if ((Get-Item -LiteralPath $Root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Native input root is a reparse point: $Root" }
    $files = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($scope in Get-NativeInputScopes) {
        Assert-NoReparseAncestors $Root $scope.Path
        $source = Join-Path $Root ($scope.Path.Replace('/', [IO.Path]::DirectorySeparatorChar))
        if ($scope.Kind -eq 'File') {
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Required native input is missing: $($scope.Path)" }
            $candidates = @(Get-Item -LiteralPath $source -Force)
        } else {
            if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "Required native input directory is missing: $($scope.Path)" }
            Assert-NoReparseTree $source
            $candidates = @(
                if ($scope.Kind -in @('Headers', 'Notices')) {
                    Get-ChildItem -LiteralPath $source -File -Force -Recurse
                } else {
                    # CMake adds each directory itself to the linker search path; nested libraries would not be found.
                    Get-ChildItem -LiteralPath $source -File -Force | Where-Object Extension -IEQ '.lib'
                }
            )
            if ($candidates.Count -eq 0) { throw "Required native input directory has no $($scope.Kind.ToLowerInvariant()): $($scope.Path)" }
        }
        foreach ($file in $candidates) {
            Assert-NoReparseTree $file.FullName
            $relative = [IO.Path]::GetRelativePath($Root, $file.FullName).Replace('\', '/')
            Assert-AllowedNativePath $relative
            if (-not $seen.Add($relative)) { throw "Duplicate native input path: $relative" }
            $files.Add([pscustomobject]@{ Path = $relative; Source = $file.FullName })
        }
    }
    return @($files | Sort-Object Path)
}

function Read-NativeManifest([byte[]]$Bytes, [hashtable]$Pins = (Get-ProductionPins)) {
    if ($Bytes.Length -gt $script:MaxManifestBytes) { throw 'Native input manifest exceeds the size limit.' }
    $doc = [System.Text.Json.JsonDocument]::Parse([ReadOnlyMemory[byte]]::new($Bytes))
    try {
        $root = $doc.RootElement
        if ($root.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { throw 'Manifest root must be an object.' }
        $rootNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $root.EnumerateObject()) {
            if (-not $rootNames.Add($property.Name)) { throw "Duplicate manifest property: $($property.Name)" }
        }
        if ($rootNames.Count -ne 2 -or -not $rootNames.Contains('schema') -or -not $rootNames.Contains('files') -or
            $root.GetProperty('schema').GetInt32() -ne 1) { throw 'Unsupported native input manifest schema.' }
        $result = [Collections.Generic.List[object]]::new()
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $totalLength = 0L
        foreach ($entry in $root.GetProperty('files').EnumerateArray()) {
            if ($entry.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { throw 'Manifest file entry must be an object.' }
            $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($property in $entry.EnumerateObject()) {
                if (-not $names.Add($property.Name)) { throw "Duplicate manifest file property: $($property.Name)" }
            }
            if ($names.Count -ne 3 -or -not $names.Contains('path') -or -not $names.Contains('length') -or -not $names.Contains('sha256')) {
                throw 'Manifest file entry has unexpected fields.'
            }
            $path = Normalize-ManifestPath $entry.GetProperty('path').GetString()
            Assert-AllowedNativePath $path
            if (-not $seen.Add($path)) { throw "Duplicate manifest path: $path" }
            $length = $entry.GetProperty('length').GetInt64()
            $hash = $entry.GetProperty('sha256').GetString()
            if ($length -lt 0 -or $hash -cnotmatch '^[0-9a-f]{64}$') { throw "Invalid size or SHA-256 for $path" }
            if ($result.Count -ge $script:MaxManifestFiles -or $length -gt ($script:MaxBundleBytes - $totalLength)) { throw 'Native input manifest exceeds its file-count or expanded-size limit.' }
            $totalLength += $length
            $result.Add([pscustomobject]@{ Path = $path; Length = $length; Sha256 = $hash })
        }
        if ($result.Count -eq 0) { throw 'Native input manifest contains no files.' }
        foreach ($pin in $Pins.Keys) {
            $entry = @($result | Where-Object Path -CEQ $pin)
            if ($entry.Count -ne 1 -or $entry[0].Sha256 -cne $Pins[$pin]) { throw "Pinned native input is missing or changed: $pin" }
        }
        return @($result | Sort-Object Path)
    } finally { $doc.Dispose() }
}

function New-ManifestBytes([object[]]$Files) {
    $manifest = [ordered]@{
        schema = 1
        files = @($Files | ForEach-Object { [ordered]@{ path = $_.Path; length = [long]$_.Length; sha256 = $_.Sha256 } })
    }
    return [Text.UTF8Encoding]::new($false).GetBytes(($manifest | ConvertTo-Json -Depth 5 -Compress))
}

function New-NativeInputPackage([string]$Root, [string]$ZipPath, [string]$ManifestFile, [hashtable]$Pins = (Get-ProductionPins)) {
    $Root = [IO.Path]::GetFullPath($Root)
    $ZipPath = [IO.Path]::GetFullPath($ZipPath)
    $ManifestFile = [IO.Path]::GetFullPath($ManifestFile)
    if ($ZipPath -eq $ManifestFile -or $ZipPath.StartsWith($Root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $ManifestFile.StartsWith($Root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Outputs must be distinct and outside the native input root.' }
    if ((Test-Path -LiteralPath $ZipPath) -or (Test-Path -LiteralPath $ManifestFile)) { throw 'Native input outputs must be new.' }
    foreach ($path in @($ZipPath, $ManifestFile)) {
        $parent = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw "Output parent does not exist: $parent" }
    }

    $files = Get-NativeInputFiles $Root
    $tmpZip = "$ZipPath.tmp.$([guid]::NewGuid().ToString('N'))"
    $tmpManifest = "$ManifestFile.tmp.$([guid]::NewGuid().ToString('N'))"
    $archive = $null
    try {
        $stream = [IO.File]::Open($tmpZip, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
            $receipts = [Collections.Generic.List[object]]::new()
            foreach ($file in $files) {
                if ((Get-Item -LiteralPath $file.Source -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point is not allowed: $($file.Source)" }
                $input = [IO.File]::Open($file.Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
                try {
                    $entry = $archive.CreateEntry($file.Path, [IO.Compression.CompressionLevel]::Optimal)
                    $output = $entry.Open()
                    $sha = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
                    $length = 0L
                    try {
                        $buffer = [byte[]]::new(1048576)
                        while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
                            $output.Write($buffer, 0, $read)
                            $sha.AppendData($buffer, 0, $read)
                            $length += $read
                        }
                        $digest = [Convert]::ToHexString($sha.GetHashAndReset()).ToLowerInvariant()
                    } finally { $sha.Dispose(); $output.Dispose() }
                } finally { $input.Dispose() }
                if ($Pins.ContainsKey($file.Path) -and $digest -cne $Pins[$file.Path]) { throw "Pinned native input hash mismatch: $($file.Path)" }
                $receipts.Add([pscustomobject]@{ Path = $file.Path; Length = $length; Sha256 = $digest })
            }
            $manifestBytes = New-ManifestBytes @($receipts)
            $manifestEntry = $archive.CreateEntry('native-inputs.json', [IO.Compression.CompressionLevel]::Optimal)
            $manifestStream = $manifestEntry.Open()
            try { $manifestStream.Write($manifestBytes, 0, $manifestBytes.Length) } finally { $manifestStream.Dispose() }
        } finally {
            if ($archive) { $archive.Dispose() }
            $stream.Dispose()
        }
        # Re-read the packaged manifest through the same strict validator before publishing outputs.
        $check = [IO.Compression.ZipFile]::OpenRead($tmpZip)
        try {
            $manifestEntry = $check.GetEntry('native-inputs.json')
            $ms = $manifestEntry.Open()
            try {
                $memory = [IO.MemoryStream]::new(); $ms.CopyTo($memory); $embedded = $memory.ToArray(); $memory.Dispose()
            } finally { $ms.Dispose() }
            [void](Read-NativeManifest $embedded $Pins)
            [IO.File]::WriteAllBytes($tmpManifest, $embedded)
        } finally { $check.Dispose() }
        [IO.File]::Move($tmpZip, $ZipPath)
        try { [IO.File]::Move($tmpManifest, $ManifestFile) }
        catch { [IO.File]::Delete($ZipPath); throw }
        [pscustomobject]@{ Archive = $ZipPath; Manifest = $ManifestFile; ArchiveSha256 = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant(); Files = $files.Count }
    } finally {
        if (Test-Path -LiteralPath $tmpZip) { [IO.File]::Delete($tmpZip) }
        if (Test-Path -LiteralPath $tmpManifest) { [IO.File]::Delete($tmpManifest) }
    }
}

function Expand-NativeInputPackage([string]$ZipPath, [string]$ManifestFile, [string]$Destination, [hashtable]$Pins = (Get-ProductionPins)) {
    $ZipPath = [IO.Path]::GetFullPath($ZipPath)
    $ManifestFile = [IO.Path]::GetFullPath($ManifestFile)
    $Destination = [IO.Path]::GetFullPath($Destination)
    if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf) -or -not (Test-Path -LiteralPath $ManifestFile -PathType Leaf)) { throw 'Archive and manifest must exist.' }
    if (Test-Path -LiteralPath $Destination) { throw 'Extraction destination must be new.' }
    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw "Extraction parent does not exist: $parent" }
    $stage = Join-Path $parent ('.native-inputs-' + [guid]::NewGuid().ToString('N'))
    $archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $manifestEntries = [Collections.Generic.List[object]]::new()
        $dataEntries = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $archive.Entries) {
            $name = Normalize-ManifestPath $entry.FullName
            if (-not $names.Add($name)) { throw "Duplicate archive path: $name" }
            $unixType = ($entry.ExternalAttributes -shr 16) -band 0xF000
            if ($unixType -eq 0xA000 -or ($entry.ExternalAttributes -band [int][IO.FileAttributes]::ReparsePoint)) { throw "Archive links are not allowed: $name" }
            if ($name -ceq 'native-inputs.json') { $manifestEntries.Add($entry); continue }
            Assert-AllowedNativePath $name
            if ($entry.Name.Length -eq 0) { throw "Directory entries are not allowed: $name" }
            $dataEntries.Add($name, $entry)
        }
        if ($manifestEntries.Count -ne 1) { throw 'Archive must contain exactly one native-input manifest.' }
        if ($manifestEntries[0].Length -gt $script:MaxManifestBytes) { throw 'Native input manifest exceeds the size limit.' }
        $embeddedStream = $manifestEntries[0].Open()
        try { $memory = [IO.MemoryStream]::new(); $embeddedStream.CopyTo($memory); $embeddedBytes = $memory.ToArray(); $memory.Dispose() }
        finally { $embeddedStream.Dispose() }
        if ((Get-Item -LiteralPath $ManifestFile).Length -gt $script:MaxManifestBytes) { throw 'External native input manifest exceeds the size limit.' }
        $sidecar = [IO.File]::ReadAllBytes($ManifestFile)
        if (-not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
            [Security.Cryptography.SHA256]::HashData($embeddedBytes), [Security.Cryptography.SHA256]::HashData($sidecar))) {
            throw 'External manifest differs from the embedded manifest.'
        }
        $manifest = Read-NativeManifest $embeddedBytes $Pins
        if ($manifest.Count -ne $dataEntries.Count) { throw 'Archive file set does not match its manifest.' }
        foreach ($file in $manifest) {
            if (-not $dataEntries.ContainsKey($file.Path)) { throw "Manifest file is missing from archive: $($file.Path)" }
            if ($dataEntries[$file.Path].Length -ne $file.Length) { throw "Archive length mismatch: $($file.Path)" }
        }

        [void][IO.Directory]::CreateDirectory($stage)
        foreach ($file in $manifest) {
            $destinationFile = Join-Path $stage ($file.Path.Replace('/', [IO.Path]::DirectorySeparatorChar))
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destinationFile))
            $input = $dataEntries[$file.Path].Open()
            $output = [IO.File]::Open($destinationFile, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $sha = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
            $length = 0L
            try {
                $buffer = [byte[]]::new(1048576)
                while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $length += $read
                    if ($length -gt $file.Length) { throw "Archive expanded beyond its manifest length: $($file.Path)" }
                    $output.Write($buffer, 0, $read)
                    $sha.AppendData($buffer, 0, $read)
                }
                $digest = [Convert]::ToHexString($sha.GetHashAndReset()).ToLowerInvariant()
            } finally { $sha.Dispose(); $output.Dispose(); $input.Dispose() }
            if ($length -ne $file.Length -or $digest -cne $file.Sha256) { throw "Archive hash mismatch: $($file.Path)" }
            if ($Pins.ContainsKey($file.Path) -and $digest -cne $Pins[$file.Path]) { throw "Pinned native input hash mismatch: $($file.Path)" }
        }
        # Ensure the output layout still supplies every CMake-required scope.
        [void](Get-NativeInputFilesForValidation $stage)
        [IO.Directory]::Move($stage, $Destination)
        [pscustomobject]@{ Root = $Destination; Files = $manifest.Count }
    } catch {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
        throw
    } finally { $archive.Dispose() }
}

function Get-NativeInputFilesForValidation([string]$Root) {
    # The production packer performs the same exact CMake-scope/layout check.
    return Get-NativeInputFiles $Root
}

if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $Mode) { throw 'Choose -Mode Pack or -Mode Expand.' }
if ($Mode -eq 'Pack') {
    foreach ($name in @('SourceRoot', 'OutputZip', 'ManifestPath')) { if (-not (Get-Variable $name -ValueOnly)) { throw "-$name is required for Pack." } }
    New-NativeInputPackage $SourceRoot $OutputZip $ManifestPath | Format-List
} else {
    foreach ($name in @('ArchivePath', 'ManifestPath', 'TargetRoot')) { if (-not (Get-Variable $name -ValueOnly)) { throw "-$name is required for Expand." } }
    Expand-NativeInputPackage $ArchivePath $ManifestPath $TargetRoot | Format-List
}
