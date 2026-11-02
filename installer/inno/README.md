# Windows installer and updater

First installation, manual updates and automatic updates use the same
`SetupWindow` controller and native Win32/GDI+ presentation. The default
700 × 500 logical-pixel outer window matches Doorlight's Cozy frame, fonts and
colors, with an eight-pixel gap from the primary work area's lower right corner.
The door opens with measured installation progress; the wave and activity spinner
run independently of Windows animation settings. Updates inherit the app's motion
preference.

Inno supplies per-user extraction, shortcuts, registration and uninstallation.
Its wizard stays offscreen. Explicit bounded JSON messages connect the engine to
the shared frontend; Inno logs are diagnostic evidence, not a protocol. The
frontend executable is extracted from the same bundled helper used by updates.
The helper is compiled with NativeAOT; it does not bundle the .NET Desktop runtime.
The engine watches the actual frontend process and uses normal cancellation if
it exits unexpectedly. Transient Windows reader/scanner locks defer status
publication; they do not abort extraction. Retrying blocked preparation follows
Inno's ordinary Back-to-Ready/Next transition.

The installer starts immediately. There are no Next/Finish pages or license
acceptance checkbox. Licenses remain available from the surface and installed
files. A healthy same-version or newer installation is opened; an incomplete or
modified same-version bundle is repaired through a fresh stage. Pending
transactions are recovered before an existing installation can be opened.

## Packaging

Build from a qualified Windows bundle containing `sybl.exe`, its DLLs, assets and
notices. Debug symbols and test executables are excluded.

```powershell
./installer/trust/build.ps1 -ToolRoot <private-tool-cache> -OutputDirectory <trust-output>
./installer/delta/provision.ps1 -ToolsDir <new-delta-tool-directory>
./installer/build.ps1 -BundleDir <qualified-bundle> -Version 1.0.0 `
  -OutputDir <new-output> -TrustVerifier <trust-output>/DoorlightTrust.exe `
  -TrustNoticesDirectory <trust-output>/notices `
  -DeltaToolsConfig <new-delta-tool-directory>/tools.json
```

The pinned .NET 10 SDK, native Windows compiler/linker, PowerShell 7 and Inno
Setup 6 are required. Each build uses a fresh output directory. It compiles the
native UI and NativeAOT helper, preserves dependency/font notices, constructs and
verifies the complete manifest and archives, then compiles both installer modes.
The offline setup contains the app; the online setup contains the shared helper
and registration engine and fetches an authenticated app package. Both use the
same presentation and startup-health transaction.

Online delivery requires the optional paired public feed configuration and
bootstrap root inputs. Their omission deliberately leaves online installation
and update delivery unconfigured. There is no fallback to unsigned hosting
metadata. Build tools do not create production signing keys or publish assets.

Outputs include unsigned `Doorlight-<version>-Setup.exe`,
`Doorlight-<version>-Online-Setup.exe`, `Doorlight.Package.json`, a ZIP and a
Velopack full package. Use the package format declared in signed release policy;
these archives are not interchangeable by filename. The original app-file bytes
are preserved in both package mappings.

These artifacts alone do not establish distribution qualification. Follow
[Compliance](../../docs/COMPLIANCE.md), including dependency rights, required
notices, corresponding source and signing requirements. On 2 November 2026 the
owner authorized preparing automatic Windows delivery from GitHub. Release and
native/source qualification still apply; see [delivery activation](../release/README.md#activation-and-current-limits).

## Update and restart contract

Installed builds ask the relocated native helper to verify TUF metadata at startup
(with up to one minute of random delay), then approximately every five to seven
hours. Failed checks use bounded exponential backoff with jitter. The Flutter app
does not call GitHub's Releases REST API or select executable assets itself.
The helper uses the pinned maintained go-tuf client and an embedded public trust
root. Release policy binds channel/platform, monotonic release sequence, manifest,
full package and optional delta hashes. Persistent metadata and policy high-water
marks live outside the replaceable app bundle and profile. Never erase this state
to bypass a verification failure.

A direct GitHub release-asset HTTPS base is a supported initial host; a separate
paid update service is not required. The transport can also use another HTTPS
host. Publish immutable versioned assets first and the TUF timestamp last. See
[feed hosting and trust](../trust/README.md). This checkout has no production
trust root or published feed; unconfigured builds offer no online update.

The signed policy supports staged installation cohorts and a release halt. Manual
checks may bypass the cohort percentage, but never a halt, expiry, minimum helper
version or rollback protection. The app passes the verified release sequence and
manifest digest into preparation. The helper refreshes eligibility before handing
off shutdown; a cancelled or changed selection cannot authorize replacement.

Full packages may use the legacy ZIP mapping or Velopack's package format.
Velopack is used only for packaging and the pinned pure `patch` operation. Its
installer/apply engine is not used because it force-stops running app processes.
A matching verified cached base enables a delta; unavailable or invalid bases or
patches fall back to the independently authenticated full package. Reconstructed
files must match the signed manifest, regardless of ZIP recompression differences.
The accepted base changes only after successful app startup and transaction
acceptance. See [delta boundaries](../delta/README.md).

Downloads are content-addressed, bounded and SHA-256 verified, with resumable
strong-ETag ranges, bounded retry/backoff and safe restart when the server ignores
ranges. Both app and helper entry points must be Windows x64 executables before
shutdown. Signature checks authenticate publisher policy; first-download installer
trust and Windows code signing remain separate release qualifications.

Preparation leaves the app usable. Manual update is one click; automatic restart
waits for an untouched startup or five minutes without app input while inactive.
Calls, transfers, unsent drafts, recording/composer operations, pairing, identity
operations, capture operations and settings writes defer restart. The Dart guard
and native reservation close new admission, drain earlier native commands and
recheck ownership/activity before normal shutdown. Input or foreground return
revokes an automatic handoff. The helper acknowledges readiness before the app
commits its quit, and the expected identity is captured at that handoff.
Native preparation, helper readiness and native commit have bounded waits.
Cancellation bypasses the native worker queue and invalidates late work by its
attempt ID before input is released. If quit has already committed, the helper
stays armed for that exit.

The helper never kills the app. It waits for process exit and exclusive setup and
profile locks. Normal quit before an authorized handoff cancels preparation.
Failed or cancelled preparation removes its verified private stage and discards
its owned reconstructed delta archive. Cached full/base packages, trust state and
transaction journals are not discarded by that cleanup. A locked or modified
stage is kept for inspection instead of weakening the deletion checks.
The original process handle stays pinned throughout preparation, preventing PID
reuse from authorizing a later handoff.
Cancellation remains available until shutdown handoff; replacement and startup
confirmation cannot be interrupted through the close button.

## Recovery and handoff

The installation root is `%LOCALAPPDATA%/Programs/Doorlight`.
`DoorlightUpdater.exe` is the stable launcher and `current/sybl.exe` is the app.
Workers relocate outside both paths before replacing them. The current and
previous complete bundles, stable helper and durable transaction journal are
managed together. Profiles remain outside the installation and are never rolled
back.

A candidate must acknowledge its exact process, version and expected identity
after startup, then present its app window before the transaction is accepted.
The setup surface stays until that handoff. A safe visible consent gate does not
require automatic consent to establish startup. A candidate that exits is rolled
back; an alive but unconfirmed candidate must quit before restoration. Recovery
guidance remains visible after an automatic update failure. A first installation
without an old bundle requires re-running the installer.

The stable launcher recovers unfinished transactions on the next launch. Rejected
versions are excluded from automatic retries; explicit retry is available.
After acceptance and journal retirement, older recognizable bundles are pruned,
keeping the immediate predecessor. Locked, linked or unrecognized older leftovers
remain for inspection and cannot invalidate an accepted installation.
Same-version repair is installer-only. Uninstall removes owned executable bundles
without following linked trees and leaves profiles intact. Abandoned private
session cleanup examines at most 32 directories per launch after two days;
active or unexpected trees are kept.
Startup checks do not establish real-peer functionality or release acceptance.

Core package/download/transaction tests:

```powershell
Set-Location installer
dotnet restore tests --locked-mode
dotnet run --project tests --no-restore
```


## Game Bar widget

The widget is a separate MSIX and is never replaced by the desktop package.
[Widget servicing metadata](../widget/README.md) prepares Windows-managed
App Installer updates while preserving package identity. Enrollment and actual
installed update behavior remain unqualified; a direct sideload does not become
auto-updating merely because an AppInstaller file exists. The desktop restart
guard waits for authenticated widget idle reports, including local drafts and
pending sends. Connected legacy widgets conservatively defer restart.
