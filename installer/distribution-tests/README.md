# Configured distribution facade checks

Run `installer/distribution-tests/build.ps1` from the initialized repository root.
The script embeds a Brotli-compressed **fixture-only** verifier in this isolated
linked-source test project. All archives, public metadata, update state, install
state, generated build outputs and logs remain under its C-drive scratch path.
It never accesses the real Doorlight update/profile/installation directories.

The fixture verifier generates signing keys only in RAM. A loopback server serves
the resulting signed repository and small header-valid PE bundle. Tests exercise
real `DistributionRuntime.Check`, downloads, manifest/package verification,
Velopack layout extraction, fresh `Refresh`, the actual bundle journal, and
accepted-base receipt creation. Startup acceptance is simulated: no fixture
executable or real application is launched.

Checks include optional corrupt-delta-cache fallback, prepared-manifest binding,
signed halt, tampered extracted verifier, cancellation during slow network refresh
without stage/install changes, and post-acceptance artifact maintenance. Pruning
keeps accepted/current-policy artifacts, recently written files and locked active
transfers, skips unknown names, and never removes TUF or release-sequence state.
It visits at most 8192 candidate names/4096 recognized files per call, removes
known unlocked files older than seven days, and reduces older cache content toward
a 2 GiB soft budget. Pinned/recent/locked files can legitimately exceed that budget.

`DOORLIGHT_FEED_FIXTURE` adds the resource/state injection seam only to test builds.
The production API has no arbitrary-state or insecure HTTP runtime switch. Tests
compile with AOT/trim analyzers and warnings as errors; this is not a Windows UI,
physical-device, real startup, production feed or distribution acceptance test.

Actual fixture installers use a separate `fixture-updates` state directory; they
never initialize or reset the production `updates` trust cache.
