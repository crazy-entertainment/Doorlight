# Windows delivery from GitHub

Users receive compiled installers and update packages. Flutter, Visual Studio,
Go and the .NET SDK run on GitHub's Windows builder, never on users' computers.
The separate Game Bar widget uses its own Store/MSIX delivery route.
Packages include the app-local Microsoft C++ release runtime from that build's
Visual Studio redistributables. Its x64 format, version and Microsoft signatures
are checked before packaging; the runtime's separate notices and receipt ship
with the app. It requires no system-wide runtime installation or development SDK.

`.github/workflows/windows-release.yml` runs for pushes to `main` and manual
dispatches of `main`. It downloads pinned tools and the exact reviewed native
input archive, checks its complete manifest and the existing native hash gates,
runs Windows source/build checks, then packages both installer variants. Version
`1.<workflow-run-number>.<attempt>` increases across runs/retries; Windows' fourth
version component stays zero. The signed policy sequence is independent.

The build job has read-only repository access and no update-signing keys. The
publication job verifies the candidate's commit, version, native-input identity
and every deliverable hash before signing or uploading. It runs in the
`windows-release` GitHub environment, whose deployment rule allows only `main`.
That environment contains only `DOORLIGHT_TUF_TARGETS_KEY`,
`DOORLIGHT_TUF_SNAPSHOT_KEY` and `DOORLIGHT_TUF_TIMESTAMP_KEY`. Never provision a
root key there. Owner recovery custody is outside the checkout and follows the
owner's secret-recovery procedure.

Versioned `windows-v<version>` releases contain offline/online installers, the
stable `Doorlight-Setup.exe` download (byte-identical to that version's offline
installer), the full ZIP update, its manifest, the application source archive
and the build receipt. The source archive uses a strict allowlist for the
Windows build surface: `.github/workflows/windows-release.yml`, `apps/`,
`native/`, `installer/`, `web/`, `services/`, root `global.json` SDK pin,
`LICENSE`, `README.md`, `.gitignore`, `.gitattributes`, and the four
`tools/windows-native-{inputs,sources}*.ps1` scripts. The Go verifier's LF source
bytes are preserved across Windows checkouts and exported archives so its pinned
binary hash stays reproducible.
It excludes historical private roots such as `docs/`, `design/`, `sybl/`,
`widget/`, `patches/`, and unrelated legacy tools. Required app, daemon,
installer and native-input source paths are checked before export. The release
links the separately hash-pinned native corresponding source. The initial
publisher uses full updates; existing client delta support remains available
but CI delta generation is not enabled here.
The native input configuration and candidate receipt also bind the exact
`native/jami` Git tree. A daemon source change cannot silently ship the old
compiled library: its native inputs must be rebuilt and qualified first.

The mutable `update-feed` release contains the public TUF root, immutable
versioned targets/snapshot metadata, hash-named rollout policies and the current
`timestamp.json`. All payloads and immutable metadata are uploaded first. The
timestamp is uploaded under a staging name, the old head is checked again, and
the staged asset is promoted last. GitHub has no atomic asset replacement:
clients can briefly see a missing timestamp and retry. A failed promotion
attempts to restore the old head. Never overwrite immutable assets to repair a
failure. A subsequent attempt reserves metadata versions above any already
uploaded orphan generation, so failed publication cannot reuse those names.

A weekly job refreshes signatures without rebuilding or releasing the app.
Timestamp validity is 14 days, snapshot 30 days and targets 90 days, bounded by
root expiry. Monitor failed scheduled workflow runs and refresh before expiry.
GitHub may disable scheduled workflows after extended repository inactivity;
check Actions status before depending on unattended long-term maintenance.
Root rotation is not implemented; qualify it before changing keys or approaching
the five-year root expiry. See [publisher contracts](../trust/publisher/README.md).

## Test delivery and qualification

`config.json` enables owner-authorized unsigned Windows test delivery for the
owner and his brother. It records the successful
[GitHub-hosted qualification build](https://github.com/crazy-entertainment/Doorlight/actions/runs/41465291514)
and matching native/source digests. This is not general release acceptance.
Setting a flag alone does not establish release qualification. When delivery is
disabled, no public binary candidate is uploaded and no feed is published.

Publication and installed qualification proceed in this order:

1. Export the exact native input layout with `tools/windows-native-inputs.ps1`
   and qualify its dependency provenance, corresponding source and notices.
   Publish the reviewed archive, sidecar and corresponding source at immutable
   HTTPS URLs; record their SHA-256 values in `config.json`. Byte transport
   checks do not establish reconstruction or licensing.
2. Review the project's private compliance and acceptance requirements for the
   intended scope. The owner authorized unsigned Windows testing on his and his brother's PCs;
   this does not establish general distribution acceptance. Production
   Authenticode signing remains separate from TUF signatures.
3. Verify an actual GitHub-hosted build while publication is disabled. Record
   the actual reviewer/date/evidence URL and matching native/source digests in
   `qualification`, with the test scope and remaining acceptance gaps explicit.
4. Enable the reviewed test delivery configuration. The next `main` push can
   publish after its checks pass. A real hosted-feed installation requires this
   first publication; do not claim that result before testing it.
5. Verify an installed update through the public signed feed, including
   interruption/recovery and profile continuity, before calling the updater
   qualified. Local and synthetic tests do not substitute for installed-artifact
   evidence. Each test PC needs the updater-enabled installer once; old
   unconfigured builds cannot discover a trust root they never contained.

A source push cannot bypass failed build or publication gates. A client checks
within a minute of startup and periodically thereafter; publication is not an
immediate forced restart on every PC.

The bootstrap root and three encrypted online environment secrets have been
provisioned. Their local recovery coverage is verified. GitHub secret metadata
readback confirms the expected names and main-only environment; successful build
qualification alone does not prove workflow signing or installed updates.
The qualified native inputs, complete corresponding source and notices are hosted in the immutable
[native-input release](https://github.com/crazy-entertainment/Doorlight/releases/tag/windows-native-1248cd07a061-4ca99786).
[Native qualification](native-qualification.json) records the final exported-root
Windows build, 80 passing CTests (one microphone skip), 200 remote-input stress
runs and unchanged installed identity key/certificate. Installed hosted-feed
updates and general distribution require their separate acceptance evidence.

## Local checks

```powershell
python -m unittest discover -s installer/release -p test_publish.py
pwsh -NoProfile -File installer/release/build-test.ps1
pwsh -NoProfile -File tools/windows-native-inputs-test.ps1
# From installer/trust with the documented pinned Go toolchain:
go test -mod=readonly ./...
go vet -mod=readonly ./...
```

Use Actionlint against the workflow as well. Publisher tests use disposable
synthetic keys and an HTTPS test server, not production keys or hosting.
Use short packaging output paths: Inno's input file handling still has a
260-character limit even where .NET archive operations accept longer paths.
