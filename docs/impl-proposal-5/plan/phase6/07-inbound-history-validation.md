# P6.1 — Standalone history qualification

Contract: [standalone source reader](07-inbound-history-contract.md).
This ledger covers source-history validation and its current-view consumer.
File-byte/encoding comparison, copied-file uniqueness and physical settlement
remain separate gates in the [completion ledger](06-completion-ledger.md).

## Executable coverage

Eight new test functions contain 19 cases:

| Test | Independent observation / failure companion |
| --- | --- |
| `standaloneDerivedSourceUsesExactOccurrencesAndAncestry` (2) | Existing literal equal/merged fixtures reconstruct exact expected bodies and represented IDs; missing/misaddressed occurrences, wrong result, incomplete ancestry and local references fail |
| `projectionHistoryValidatesStandaloneAcceptedSources` (4) | Real accepted ordinary/equal/merged/automatic history produces independent expected bodies and complete current values; selected envelopes decode once; forged derived results preserve healthy history; later edits and Deletes retain old contents with a different/absent Current relationship |
| `projectionHistoryRejectsClaimsWithoutPoisoningRetainedHistory` (5) | Foreign collection, wrong birth, locator, index and ID receive passive classifications; the valid companion remains readable and accepted history unchanged |
| `projectionHistoryWaitsForExactAcceptedInputAndRetainsRejectionReason` | Missing exact input becomes readable after delivery; unsupported prerequisite retains its exact reason across reopen and unrelated accepted bytes survive |
| `projectionHistoryFencesConcurrentHistoryAndEvidenceConsumers` | Held production read plus save reaches the final stale-view fence; wrong store, old view and reopened session reject evidence; fresh evidence preserves historical A while Current remains newer |
| `projectionHistoryDiagnosesActualRetainedDamage` (4) | Previously valid source then damaged bytes, occurrence, action membership or locator metadata produces the specific integrity failure and fences Current access |
| `projectionHistoryRepackagingPreservesLogicalCurrent` | Another accepted envelope containing the same operation gives the same logical Current relationship and one operation row |
| `projectionHistoryEncryptedProfileRejectsPlaintextConsumer` | Plaintext-source API refuses encrypted-segment profile while the encrypted private store remains healthy |

The byte-damage test uses a one-byte envelope, for which the existing envelope
decoder returns `lengthLimit`; it does not substitute a broad thrown-error check.
The two corruption classes are exercised separately: forged input addresses
preserve healthy history, while a tampered stored locator is authenticated against
the actual retained envelope and diagnoses damage.

## Reproducible commands

```sh
make -C tests run-swift-storage \
  'SWIFT_STORAGE_TEST_FLAGS=-c debug --no-parallel --filter projectionHistory --filter standaloneDerived --filter derivedState --filter projectionIntent --filter projectionObservations --filter projectionStamp'
# Repeat with -c release. Linux uses the Makefile's strict linker/driver settings
# and may add --jobs 2 to bound compiler memory.
python3 tools/test-storage-private-types.py --modules NVStorage/.build/debug/Modules
# Repeat against release; Linux's actual module directory includes its target triple.
python3 tools/test-storage-runtime-mutations.py --configuration debug \
  --only p61-inbound-ignore-identity --only p61-inbound-stale-issuance \
  --only p61-inbound-stale-consumer --only p61-inbound-derived-result \
  --only derived-state-rebound-order --only derived-state-wrong-result \
  --only derived-state-omitted-input --only derived-state-wrong-identity \
  --only derived-state-wrong-base --only derived-state-wrong-occurrence
# Repeat with --configuration release.
```

The 58 private compiler probes include ordinary and same-module attempts to mint
`CheckedProjectionHistory`, substitute a parsed stamp, or access its private
contents directly. Passing clients use the actual checked consumer. Runtime
tests challenge the same evidence type in the wrong context.

The four new mutations remove source-ID comparison, the final issuance fence,
the consumption fence and derived-result verification. Six earlier derived-state
controls remain required because both entry points share the same semantic
checks. Their target assertions and cross-product remain unchanged. Three older
mutant definitions previously generated unused-binding errors under strict
compilation; their replacements now consume the omitted-check identifiers using
their fixed byte widths. They must still fail the original runtime assertions.
Compilation failure is explicitly not credited as mutation detection.

## Qualification results

Final-source regression selection: **27 functions**, including existing
stamp/private intent/observation and derived-state companions:

| Host | Debug | Optimized |
| --- | --- | --- |
| macOS arm64 / Swift 6.4 | Pass, 12.740 s | Pass, 9.818 s |
| Ubuntu arm64 / Swift 6.4 | Pass, 4.989 s | Pass, 1.112 s |

These are test durations, not startup benchmarks. Logs are
`/tmp/nv-p61-inbound-{debug,release}-final.log` locally and
`/tmp/nv-p61-inbound-linux-{debug-final,release}.log` on Ubuntu. All **58 private
compiler probes** (26 ordinary, 32 same-module) passed on both hosts in both
configurations. Linux logs are also preserved locally in
`/tmp/nv-p61-inbound-linux-logs.tar.gz`. All 330 project source inputs in the final
debug mutation manifest match both the local library and the Linux test copy.

All ten final-source mutations reached their designated runtime assertions in
both debug and optimized builds. Under
`/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/`, their artifact directories are
`nv-runtime-mutations-eu9x1tzp` (debug) and `nv-runtime-mutations-yxmbhhrn`
(optimized). The initial
campaign `nv-runtime-mutations-phd5qwqu` had three compile/setup failures; those
are excluded from qualification. The completed-campaign reuse request was also
refused by the runner; the final debug campaign reran all ten checks rather than
crediting that refused reuse.

Five independent fixture checks passed: derived state, stamp, descriptor,
observations and filename. The legacy app build passed using the documented
Xcode 27 deployment-target diagnostic override
(`/tmp/nv-p61-inbound-app-build.log`); its existing deployment/destination warnings
remain. Index self-tests, regeneration/completeness (431 source files, 156
documents) and `git diff --check` passed, including final ledger regeneration.

No encoded layout, schema, filesystem API, transaction ordering or TLA+ transition
changed. Independent byte-fixture checks and earlier physical/private commit
campaigns remain reusable within their recorded scope. This change adds actual
source-history validation rather than reclassifying a codec or model result as
physical association evidence. Full-suite, Intel-library and physical power-loss
qualification are not claimed by this increment.
