# Isolated delta checks

This console project links only the delta adapter, package manifest and staging
sources. Its own JSON context avoids building or mutating the main installer
projects. Keep intermediate outputs and evidence in the project scratch space:

```powershell
$scratch = 'C:/project-scratch/doorlight-delta-checks'
dotnet build installer/delta-tests -c Release `
  -p:BaseIntermediateOutputPath="$scratch/obj/" -p:OutputPath="$scratch/bin/"
dotnet "$scratch/bin/Doorlight.Delta.Checks.dll"
```

Pure checks cover extraction, cache receipt binding, content corruption, unsafe
paths, case collisions, symlinks, unknown executable members, delta markers,
oversized/concatenated Zstandard frames, helper replacement and cancellation.

To exercise the pinned native codec, set `DOORLIGHT_DELTA_HELPER` to the
provisioned `vendor/update.exe`. Native checks reconstruct add/change/delete
fixtures and reject a codec exit-zero output whose bytes fail the target
manifest. To also exercise existing real bundle revisions, set
`DOORLIGHT_DELTA_REAL` to a completed `build-delta.ps1` output containing
`old-input`, `new-input`, both release directories and the delta package. Those
specific retained research bundles contain `Doorlight.version=0.1.0`, so this
test uses 0.1.0 application manifests despite synthetic 0.1.1 package labels.

The real test also observes codec startup before cancelling it and verifies
workspace removal. Cancellation terminates only the codec process created by
the adapter. Tests never launch Doorlight or invoke Velopack installation verbs.
Successful and failed scratch evidence is retained at the path printed by the
runner. These are local source/native-codec checks, not installed-app acceptance.
