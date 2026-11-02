param(
    [Parameter(Mandatory)][string]$AssemblyPath,
    [Parameter(Mandatory)][string]$RequiredResources
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Reflection.Metadata
$inputStream = [IO.File]::OpenRead([IO.Path]::GetFullPath($AssemblyPath))
try {
    $image = [System.Reflection.PortableExecutable.PEReader]::new($inputStream)
    try {
        if (!$image.HasMetadata) { throw 'Resource verification requires the compiled managed assembly before NativeAOT.' }
        $metadata = [System.Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($image)
        $embedded = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($handle in $metadata.ManifestResources) {
            $resource = $metadata.GetManifestResource($handle)
            if ($resource.Implementation.IsNil) { [void]$embedded.Add($metadata.GetString($resource.Name)) }
        }
        $required = @($RequiredResources.Split('|') | Where-Object { $_ })
        if ($required.Count -eq 0) { throw 'No required setup resources were specified.' }
        foreach ($name in $required) {
            if (!$embedded.Contains($name)) {
                throw "Required neutral resource is missing: $name. Satellite resource assemblies cannot satisfy this NativeAOT dependency."
            }
        }
        Write-Output "Verified $($required.Count) neutral setup resources in the compiled managed assembly."
    } finally { $image.Dispose() }
} finally { $inputStream.Dispose() }
