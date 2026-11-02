# Trusted feed and artifact checks

This console project compiles linked copies of only `ReleasePolicy.cs`,
`TrustedFeed.cs`, and `ArtifactCache.cs`, avoiding shared Core output during
parallel integration. It has no project reference and no external packages.

After initializing the repository environment, run:

```powershell
dotnet run --project installer/feed-tests/Doorlight.Feed.Checks.csproj --artifacts-path C:/Users/Osman/AppData/Local/Temp/Doorlight-scale-trust-20261101/feed-artifacts
```

Production APIs:

- `TrustedFeed(TrustVerifierOptions)` pins the Go verifier and public root SHA256.
  `Check(currentVersion, updaterVersion, token, manual)` authenticates current
  policy, persists a release-sequence high-water mark and stable random local
  cohort, and returns `FeedDecision(Release, Eligible, Reason)`.
- `RefreshCandidate(preparedPolicy, currentVersion, updaterVersion, token, manual)`
  always refreshes trust before handoff. It compares release sequence, version,
  manifest and payload binding, while allowing legitimate rollout/halt changes.
- Manual checks bypass only rollout percentage. Halt, expiry, updater minimum,
  app version and sequence integrity still apply.
- `ArtifactCache(cacheDirectory, allowedOrigins).Get(descriptor, progress, token)`
  returns only a completely hashed artifact path. Cache names derive from SHA256,
  with per-artifact locking and bounded resumable transfers. Pass origins from
  the authenticated policy/configuration. No credentials or installation IDs
  are sent; redirects stay on those origins or GitHub's release-asset hosts.

All paths must be current-user-private and outside the replaceable application
bundle and identity data. Do not erase policy/TUF state to work around a failure.
The verifier deadline is 75 seconds, enclosing the Go CLI's 60-second deadline.
Only the verifier subprocess can be terminated on timeout; the app is untouched.

Policy is strict camelCase JSON: schema/product/channel/platform/releaseSequence/
version/minimumUpdaterVersion/enabled/rolloutBasisPoints/salt/manifest/fullPackage.
Artifacts contain url/length/sha256; fullPackage also contains format (`zip` or
`velopack`). Optional deltas contain baseVersion/basePackageSha256/
baseManifestSha256/patch. The optional readonly widget object contains url/version
(four-component MSIX version)/packageFamily/publisher/minimumDesktopVersion/
maximumProtocol. Unknown/duplicate fields are rejected; add future fields with an
explicit schema/client compatibility plan.

Only separately named local builds may define `DOORLIGHT_FEED_FIXTURE`; it permits
127.0.0.1 HTTP for integration with `DoorlightTrust.Fixture.exe`. Neither this
symbol nor that executable belongs in a distributed package.

For actual subprocess integration, build both Go variants, then run the checks
with `-p:DefineConstants=DOORLIGHT_FEED_FIXTURE` and pass the full fixture and
production executable paths after `--`. Use a separate `--artifacts-path` for
that build. The fixture check constructs a public signed repository with RAM-only
keys, serves it on loopback, verifies it through the pinned subprocess, and checks
that the normal production verifier refuses that same HTTP repository. Both
ordinary and fixture checks also run with `-p:IsAotCompatible=true
-p:EnableTrimAnalyzer=true`; no serialization-reflection exemptions are needed.
