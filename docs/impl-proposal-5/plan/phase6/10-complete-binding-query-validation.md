# P6.1 — Complete-binding query qualification

Contract: [complete bindings and owned outputs](10-complete-binding-query-contract.md).
The query/output slice is qualified at the scope recorded below. The full P6.1
completion gates remain tracked separately.

## Required observations

- Ordinary, equal, merged and automatic source queries agree with independent
  expected values and with the existing stamp consumer. Foreign collection,
  invalid birth/locator/index/identity keep their exact passive classifications.
- Forty-eight real concurrently authored equal revisions produce a complete
  descriptor exceeding 4 KiB. Optional stamp preparation must report full
  omission. The complete query still returns the expected body and all represented
  operation IDs; its 49 selected envelopes each decode once.
- Held complete-binding queries reject history changes before issuance. Actual
  consumers reject other stores, old sessions and changed views, including a
  caller presenting the original capture after the database advanced.
- One selected accepted envelope returns exactly its descriptions; pending input
  returns `nil`, ordinary history without descriptions returns `[]`, wrong
  locators fail, and fresh reopening preserves exact bytes and descriptions.
- UTF-8 and native-encoded output remain readable after a logical Delete and
  reopening. Wrong private ownership, a fabricated digest and stale observations
  fail. A held UTF-8 read followed by a filename-only intent change must fail even
  though the accepted history prefix is unchanged.
- The child-process output probe uses the complete output consumer. Existing
  crash/ENOSPC/EIO schedules and Mac-to-Linux native-byte recovery remain intact;
  an additional UTF-8 case preserves NFD/Japanese bytes after a separately committed
  Delete, with no private byte chunks.
- Ordinary/same-module issuer, substitution, private-value and immutable-binding
  probes expand the private suite from 60 to 68 checks. Existing checks remain.
  Five new targeted mutations and the three shared inbound-reader controls must
  fail at the designated runtime assertions, with passing companions.

The first wide fixture used forty heads, which still fit inside the stamp limit.
Its required boundary assertion failed; the fixture was enlarged rather than
weakening that assertion. One optimized build overlapped a test-file edit and was
rejected by Swift; that interrupted run supplies no qualification evidence.

## Commands

```sh
make -C tests run-swift-storage \
  'SWIFT_STORAGE_TEST_FLAGS=-c debug --no-parallel --filter projectionHistory --filter projectionCompleteBinding --filter projectionDescriptions --filter projectionOutput --filter projectionEncoded --filter projectionTransport'
# Repeat with -c release; Linux uses --jobs 1.
# Before building standalone products, also run the existing shared-reader consumers:
make -C tests run-swift-storage \
  'SWIFT_STORAGE_TEST_FLAGS=-c debug --no-parallel --filter scopedSharedEnvelopeKeepsCompleteGroupsAndDeletedScope --filter scopedQueryRejectsSelectedEvidenceDamage --filter scopedQueryKeepsCapturedPrefixAcrossHistoryArrival'
# Repeat with -c release. These filters can join the first selection in one build.
python3 tools/test-storage-private-types.py --modules NVStorage/.build/debug/Modules
# Repeat against optimized modules and the actual Linux target-triple directories.
python3 tools/test-storage-runtime-mutations.py --configuration debug \
  --only p61-binding-output-owner --only p61-binding-stale-issuance \
  --only p61-binding-stale-consumer --only p61-binding-output-digest \
  --only p61-binding-envelope-locator --only p61-inbound-ignore-identity \
  --only p61-inbound-stale-issuance --only p61-inbound-stale-consumer
# Repeat with --configuration release; every existing cross-product remains.
```

Rebuild the standalone probe with the [strict product commands](08-portable-projection-validation.md#commands)
and require explicit product completion, then run
`test-projection-output-process.py` as described in the
[exact-output ledger](09-exact-output-validation.md#commands). Reuse unchanged Core
codec/compiler fixtures and prior encoding/API experiments at their original scope.

## Results

On macOS arm64 / Swift 6.4, all 25 focused functions passed in debug (32.512 s)
and optimized (27.808 s). On Ubuntu arm64 / Swift 6.4 they passed in debug
(6.642 s) and optimized (2.474 s). The 68 private compiler checks passed in both
configurations on both hosts (31 ordinary clients, 37 same-module checks).

The three existing shared-envelope Undo/conflict tests passed on macOS in debug
(13.464 s) and optimized (5.635 s), covering both profiles, complete groups,
deleted scopes, twelve damage cases and captured-prefix arrival races. The
unchanged unrelated-history growth benchmark retains its earlier qualification;
this reader extension adds no SQL statement or historical traversal to that path.

All eight selected mutation controls reached their designated runtime assertions
in both configurations, with passing companions. Reports are under the macOS
temporary directory in `nv-runtime-mutations-dbj5ipnk/results.json` (debug) and
`nv-runtime-mutations-p0ygnf3b/results.json` (optimized). The existing mutation
cross-product and all earlier controls remain intact.

Explicit standalone product builds completed, followed by all five process-failure
schedules plus the historical UTF-8/Delete process case on both platforms and
configurations. Both Linux products also recovered the exact Mac-produced native
bytes with original NFD spelling. Linux ELF hardening checks passed. SHA-256
inventories match across all 234 source/test/package inputs on Mac and Ubuntu;
only Finder metadata is excluded. The legacy app build passed with the previously
approved deployment-target diagnostic override.

Local logs: `/tmp/nv-p61-binding-query-{debug,release}-qualified.log`,
`/tmp/nv-p61-binding-query-types-{debug,release}.log`,
`/tmp/nv-p61-binding-query-shared-{debug,release}.log`,
`/tmp/nv-p61-binding-query-process-{debug,release}.log`,
`/tmp/nv-p61-binding-query-app-build.log`. Ubuntu logs:
`/tmp/nv-p61-binding-query-linux-{debug,release}.log`,
`/tmp/nv-p61-binding-query-linux-types-{debug,release}.log`,
`/tmp/nv-p61-binding-query-linux-process-{debug,release}.log`,
`/tmp/nv-p61-binding-query-linux-crosshost-{debug,release}.log`.

This report qualifies its query boundary. Subsequent producer, ownership and
[settlement/platform results](14-settlement-record-validation.md) close P6.1's
record gates, as mapped by the [completion ledger](06-completion-ledger.md).
Physical file effects and power-loss durability remain separately qualified.
