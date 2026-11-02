# Doorlight feed verifier

This Windows x64 Go CLI uses the maintained `github.com/theupdateframework/go-tuf/v2`
client (pinned in `go.mod` and `go.sum`). It verifies a small JSON policy, not the
application archive, installs nothing, and never stops Doorlight. The C# installer
retains download progress, package verification, shutdown admission and recovery.

```
DoorlightTrust.exe verify --root-file <public-root.json> --metadata-url <HTTPS-base> --targets-url <HTTPS-base> --state-dir <private-persistent-directory> --target-name rollout.json --out <new-result.json>
```

Exit 0 means verification and result persistence succeeded. Every failure returns
nonzero with a generic diagnostic, without disclosing deployment URLs or paths.
The caller must require exit 0, bound/read the result, validate schema and policy,
and never consume an earlier result. `--out` must be nonexistent. The result is:

```json
{"schema":1,"targetName":"rollout.json","length":123,"sha256":"64 lowercase hex characters","target":{"schema":1},"rootVersion":1,"timestampVersion":1,"snapshotVersion":1,"targetsVersion":1,"expiresUtc":"2026-11-02T00:00:00Z"}
```

`target` is the authenticated JSON object. Its application schema and rollout
selection belong to the caller. `expiresUtc` is the earliest top-level metadata
expiry; the caller must not use the decision after it. Versions are TUF role
versions, not application versions. The trust root authenticates release policy;
initial installer trust and Windows executable signing remain separate concerns.

## Hosting contract

Metadata and target URLs are independent, replaceable HTTPS base URLs. No GitHub
REST call, token, Pages site or paid service is required. For example, bases can
be direct GitHub release asset prefixes ending `/releases/download/update-feed/`.
The feed location must permit replacement of `timestamp.json`; do not make that
metadata release immutable. Versioned app-package releases can remain immutable.
If the repository's release policy cannot provide a mutable metadata location,
use a separate HTTPS metadata host while keeping large packages on Releases.
Use consistent snapshots and flat assets:

- `N.root.json`: every root rotation retained, signed by old and new thresholds.
- `N.snapshot.json`, `N.targets.json`: immutable versioned metadata.
- `timestamp.json`: published last and refreshed before expiry.
- `<sha256>.rollout.json`: immutable policy target, declared as `rollout.json`
  with exactly one SHA256 hash in top-level targets metadata.

Only a top-level flat policy is supported; delegated targets are not followed.
Publisher tooling should use the maintained TUF metadata/signing APIs. This
directory intentionally contains no production root, private signing key, feed
publication command or credential. Test private keys are ephemeral memory only.

## State and bounds

The caller supplies a current-user-private directory outside the swappable app
bundle. Keep the same bootstrap root bytes across app updates: authenticated root
rotation happens through cached TUF metadata. Never delete this directory to
work around a trust failure; doing so discards rollback protection. A different
repository needs an explicitly distinct trust state. Local same-user compromise
is outside this cache's threat model.

The verifier rejects reparse-point ancestors, concurrent cache writers, missing
metadata after successful initialization, malformed JSON cache, bootstrap changes
and existing output files. The library persists verified metadata as refresh
progresses, including roots, so retries retain learned trust. Metadata is flushed
before a result is returned. An OS-released byte-range lock avoids stale PID locks.

Bounds: 60 seconds per CLI operation, 20 seconds per HTTP request, 2 MiB metadata,
64 KiB timestamp, 256 KiB policy, 32 consecutive root rotations. More historical
root rotations can be learned over subsequent refresh attempts. Cached policy
bytes are rehashed against current verified targets; metadata still refreshes
online. Production accepts HTTPS only and redirects only to configured origins
or GitHub's release-asset hosts. HTTP exists only in in-process loopback tests.

An offline installer must use its separately qualified embedded payload path;
this verifier never ignores metadata expiry or offers an unsafe offline mode.

## Build and verification

From repository root after initializing `local/dev/enter-sybl.ps1`:

```powershell
./installer/trust/build.ps1
```

The script downloads the pinned official Windows Go SDK ZIP, checks its published
SHA256, uses project-specific temporary caches, verifies locked module content,
runs focused tests and vet, then builds a self-contained executable without cgo.
All SDK/cache/binary/log outputs default to the authorized C-drive project scratch;
no global toolchain or PATH changes are made. Override paths explicitly for CI.
The build does not create keys, publish assets, change Git state or install apps.

## Separately built local integration fixture

`build.ps1 -IncludeFixture` additionally tests/builds `DoorlightTrust.Fixture.exe`
with Go build tag `doorlight_fixture`. Only this separately hashed binary accepts
loopback HTTP (`127.0.0.1`) and exposes the following command:

```
DoorlightTrust.Fixture.exe fixture --policy-file <synthetic-policy.json> --repository-dir <new-directory>
```

It generates temporary Ed25519 signing keys only in RAM, writes the public
`bootstrap.root.json`, four metadata files under `metadata/`, and the hash-prefixed
policy under `targets/`. The repository expires after 24 hours. Serve its root
with a local HTTP fixture server and invoke `verify` with separate `/metadata`
and `/targets` URLs. No private key is saved. The command does not exist in the
production binary.

Optional `--manifest-file`, `--package-file`, and `--artifact-base-url` together
copy public fixture artifacts into `artifacts/` and replace the input policy's
manifest/fullPackage URL, length and SHA256 fields. Package format `velopack`
selects `package.nupkg`; otherwise the copied name is `package.zip`. The supplied
artifact base should end in `/artifacts` without a trailing slash. No archive is
executed by this command. Use only project-owned synthetic fixture inputs.

The C# linked-source fixture may be compiled with `DOORLIGHT_FEED_FIXTURE` to
permit these loopback URLs; that compile-time symbol must never be enabled in
distributed installer/core builds. Production binaries have no insecure runtime
flag and no production trust anchor is created by this workflow.
