# Windows delta packaging adapter

These scripts qualify Velopack 1.2.161 as a **package codec only**. They do not
install, update, launch, terminate or register Doorlight. The existing Doorlight
transaction engine retains graceful shutdown, profile locks, startup health and
rollback authority. Runtime integration is a separate implementation boundary.

Run from the repository's initialized PowerShell environment:

```powershell
./installer/delta/provision.ps1 -ToolsDir C:/project-scratch/velopack-1.2.161
./installer/delta/build-delta.ps1 -OldDir C:/qualified/old -NewDir C:/qualified/new `
  -OldVersion 0.1.0 -NewVersion 0.1.1 `
  -ToolsConfig C:/project-scratch/velopack-1.2.161/tools.json `
  -OutputDir C:/project-scratch/delta-check
```

Both destinations must be new. Packaging copies source bundles before calling
the CLI and verifies originals remain unchanged. It records original and package
file hashes, additions/changes made by packaging, timings and round-trip evidence
in the output directory. Version arguments describe package metadata; they do
not rewrite the source `Doorlight.version` and must match real release versions
when this becomes a production build step. Synthetic test versions are not
release evidence.

## Provenance

Official release: <https://github.com/velopack/velopack/releases/tag/1.2.161>.
The release's `vpk.1.2.161.nupkg` is pinned by SHA-256:

`2b56ce117f803fc70c103cb423bd040e395e40370f6ff6e10818e9ff9c26a323`

The package provides a .NET 8 CLI at `tools/net8.0/any/vpk.dll`; installing a
global tool or .NET 10 is unnecessary. Its SHA-256 is
`f86d38eecbfe18127402f4d54f4c38cdca33d68a60dc7fb741d1f6155554c530`.
Native `vendor/update.exe` is pinned at
`9b5d28a356446c6ab61c0ec8f808fcb8a92af3cd0623a6d8fc634f1a5a1e6580`.
Do not substitute `update_x64.exe`: that is a different binary and hash.

The NuGet metadata identifies source commit
`92d6a1c91716729d449034df5c50307dcce39493` and MIT licensing.
Provisioning retains the commit-pinned upstream LICENSE and bundled vendor
notices. Shipping a helper requires retaining the applicable license/notices;
these scripts do not grant release approval or replace Compliance.

## Exact tool boundary

Packaging uses:

```text
dotnet vpk.dll pack --packId DoorlightDeltaResearch --packVersion VERSION
  --packDir COPY --mainExe sybl.exe --skipVeloAppCheck --noInst --delta None
  --runtime win-x64 --outputDir OUTPUT --skip-updates --yes
dotnet vpk.dll delta generate --base OLD-full.nupkg --new NEW-full.nupkg
  --output NEW-delta.nupkg --skip-updates --yes
update.exe patch --old OLD-full.nupkg --delta NEW-delta.nupkg
  --output reconstructed-full.nupkg --log PRIVATE-LOG
```

Velopack rejects combining `--noPortable` with `--noInst`, so the packaging
experiment creates an unused portable ZIP alongside each full package. Nothing
executes the packaged app, execution stub, setup program or installation hooks.
`update.exe` is a GUI-subsystem executable: the script explicitly waits for its
process and checks its exit code rather than trusting PowerShell's asynchronous
GUI command behavior. No timeout path kills the process.

The pinned [patch implementation](https://github.com/velopack/velopack/blob/92d6a1c91716729d449034df5c50307dcce39493/src/bins/src/commands/patch.rs)
extracts old and delta archives into temporary directories, applies Zstandard
dictionary patches, removes omitted files and recompresses an output package.
It does not perform app shutdown, replacement, health checks or rollback.
Its commented-out SHA-1 verification is not a verification contract. Doorlight
must verify reconstructed content against its authenticated SHA-256 manifest.

## Package-to-manifest mapping

Full packages are ZIP archives. Application files map exactly from
`lib/app/<relative-path>` to the existing Doorlight manifest `<relative-path>`.
The measured packages preserve all original app-file bytes and add three files
under `lib/app/`: `Squirrel.exe`, `sq.version` and
`<PackageId>_ExecutionStub.exe`. Root metadata includes the package `.nuspec`,
`[Content_Types].xml` and `_rels/.rels`. None of these additions belongs to the
Doorlight install manifest or may be executed by its adapter.

A production adapter must:

1. Authenticate and bound full/delta downloads and bind a delta to the exact
   cached base package and target version. If unavailable or invalid, download
   the full package instead.
2. Preflight archive paths, case-insensitive duplicates, links, counts and
   compressed/uncompressed sizes before handing archives to the native codec.
   Reject traversal, absolute/drive paths, alternate streams and ambiguous names.
3. Run only the pinned helper's `patch` verb in isolated staging, await completion
   and bound its output. Never delegate installation to its `apply`/`setup` verbs.
4. Read only canonical `lib/app/` members, map the suffix once, require every
   manifest file exactly once, and verify sizes and SHA-256 while writing into
   the existing safe staging mechanism. Skip only an explicit allowlist of
   known packaging metadata; reject unexpected application members.
5. Pass the verified complete stage to the existing Doorlight transaction engine.
   Preserve no-kill shutdown and pending-health rollback semantics.

The script compares file contents and sizes, not compressed ZIP bytes: the
native codec recompresses its result, so archive-byte equality is not required.
The script is a trusted-local-input qualification utility, not that production
download/extraction adapter.
