# Offline feed publisher

Build from `installer/trust` using the same pinned Go SDK, module cache and
lockfiles as the verifier:

```
go test ./publisher
go vet ./publisher
go build -trimpath -o <scratch>/DoorlightPublish.exe ./publisher
```

The executable performs no HTTP requests or GitHub/provider operations. Its only
commands are:

```
DoorlightPublish.exe init --keys-dir <new-private-directory> --output-dir <new-public-directory>
DoorlightPublish.exe release --keys-dir <online-key-directory> --root-file <bootstrap.root.json> --policy-file <policy.json> --previous-dir <previous-public-feed> --output-dir <new-public-feed>
```

Omit `--previous-dir` only for the first publication. Every output directory must
be absent, with an existing parent. Custody and public output paths must not
overlap. Links/reparse ancestors are rejected. Files are written exclusively and
flushed; existing outputs are never replaced. A failed invocation can leave a
partial directory: retain it for diagnosis and use another fresh destination.
Only publish after exit 0. Diagnostics deliberately omit paths and input values.

Optional `release --metadata-version-floor N` reserves metadata numbers through
the supplied nonnegative int64 (default 0). Each new role version exceeds both
its authenticated previous version and N; overflow is rejected. Orchestration
should derive N from the highest hosted versioned targets/snapshot filename,
including orphan assets left by failed publication. These names reserve numbers
only: they authenticate no metadata, policy or keys. The previous published head
still undergoes full signature/linkage/policy validation. This permits retrying
without overwriting orphan immutable assets or advancing the old timestamp early.

`init` creates independent Ed25519 PKCS8 PEM files `root.pem`, `targets.pem`,
`snapshot.pem`, and `timestamp.pem`. Windows creates custody with a protected,
inheritable DACL granting full control only to the current user and SYSTEM;
other platforms use mode 0700. It creates public `bootstrap.root.json` and
`1.root.json` containing identical, self-signed, five-year root v1 bytes, with
consistent snapshots and one-key thresholds. These public root bytes are the
installer bootstrap input. Initialization is a secret-custody operation: perform
the owner's recovery protocol before considering production setup complete.

Keep `root.pem` offline. Provision only the other three PEMs into separately
restricted online custody. `release` requires exactly those three filenames;
root custody is neither accepted nor needed. The caller owns the restriction of
existing online custody and its recovery coverage. Never put keys, custody
directories, or private diagnostics in a release artifact or source checkout.

A successful release directory has exactly six flat public files:

- `bootstrap.root.json` and `1.root.json` (unchanged input root bytes);
- `N.targets.json` and `M.snapshot.json`;
- `<sha256>.rollout.json`;
- `timestamp.json`.

Targets and snapshot references include exact lengths and SHA256 hashes. Each
role version increments independently from its authenticated previous version.
Default validity is targets 90 days, snapshot 30 days, timestamp 14 days, capped
at root expiry. Refresh before timestamp expiry. An expired previous feed is
accepted for maintenance after signature, version, reference, hash and policy
checks; an expired root is always rejected.

Policies are bounded to 256 KiB, reject duplicates/unknown fields, and follow the
Doorlight `ReleasePolicy` schema: product `Doorlight`, channel slug, platform
`windows-x64`, positive sequence, three-part versions, rollout controls, and
HTTPS manifest/full-package descriptors with lengths and lowercase SHA256.
Optional deltas and widget descriptors are validated too. HTTPS URLs require
default port, no user information and no fragment. Sequence rollback and changes
to product/channel/platform are rejected. At the same sequence only semantically
identical policy may refresh; change the sequence for any rollout/policy edit.
This is deliberately stricter than the client's payload-binding rule.
Application versions cannot decrease, even at a higher sequence. At an unchanged
application version, manifest and full-package descriptors must stay identical;
a higher sequence may still edit rollout controls or the minimum updater version.

Supply the actual latest published feed as previous input. Offline cryptographic
verification cannot distinguish an older correctly signed feed from the latest
one without a trusted external head. Publication orchestration must serialize
writers, preserve immutable versioned metadata and policy assets, ensure versions
are never reused, and publish `timestamp.json` last. This command emits only the
current generation; retain earlier public generations at the host.

Root rotation and threshold/key changes are unsupported: only root v1 is
accepted. Plan a reviewed root-rotation implementation before expiry or replacing
any role key. The publisher does not sign executables, upload files, install the
application, or establish distribution acceptance.

Tests generate disposable synthetic custody only. They include a real pinned
go-tuf updater downloading the policy from a TLS test server, repeat publication,
expired-feed refresh, malformed input, tampering, wrong keys, sequence rollback,
equivocation, and overwrite rejection. They do not access production credentials
or live hosting.
