# Startup publication and scoped history queries: validation

Date: 2026-10-08. Implemented and qualified within the portable Runtime boundaries.
The [implementation plan](startup-and-scoped-queries.md) preserves the acceptance,
recovery, causal Undo/Redo and conflict contracts. Production witnesses now use
ordinary assertions for REVIEW-START-2 and REVIEW-HISTORY-1. The subsequent
[snapshot-retention report](snapshot-retention-coverage-validation.md) replaces
the REVIEW-START-3 classification for sequential covering chains and records
the separate concurrent-width limit. The campaign results below preserve this
increment's original counts and encodings.

## Production boundaries

Returning open uses exhaustive `ReadyDrainPolicy.startupRequired`. Its recursive
selection starts from ready/parked Changes and follows their waiting edges;
independent snapshots cannot conceal required work behind queue order. Required
verification requests, retained-history checks, bootstrap and reconstruction
remain ahead of editable publication. Only a successful checked host `publish`
synchronously reserves the existing receive owner and launches background work.
Repeated publication coalesces; existing receive ownership continues to drain.
The existing worker, bounded database turns and save-completion notifications
provide progress after finite interference. Close stops optional preparation;
failed work retains its exact queue, bytes and verification obligations for the
existing explicit retry/recovery paths.

`CheckedEnvelopeRecords` authenticates/decodes one selected Changes envelope and
checks complete occurrences, record identities, representative addresses, indexed
parents, scope links, action membership and external-reference addresses. The
full reader and selected query reader share this boundary. A selected record is
accessed by its checked encoded index; each source is decoded once per query.
Missing indexed records inside a complete accepted envelope are integrity errors.
Missing retained object bytes report incomplete history; contradictory indexed
evidence reports integrity failure. Both fence the owner and retain recovery
obligations. The selected-read tests assert these exact distinct diagnostics.
Nested read failures preserve the originating diagnostic after fencing damaged
history; they cannot produce success or release its unresolved verification.

Privately constructed `CheckedQueryHistory` binds immutable results to store,
session, connection, captured prefix, view/presentation and query scope. Consumers
check those contexts. It remains distinct from complete `RetainedGraph` evidence.
Note-scoped Undo selects complete actions through `actions_scope`, including
compensation/native-coverage relationships, and uses the existing selector.
Collection-scoped queries and command preparation/execution retain full reading.
Conflict queries load current alternatives and all verified conflict-copy actions
needed by the existing collection-wide copied-source result. Copy deletion leaves
its recorded disposition intact; derived/automatic Current provenance is retained.

Private schema revision 3 adds one partial derived index:
`actions_conflict_copies(first_seq, action_id) WHERE kind=9`. New candidates install
it through the versioned DDL. Returning validation checks its exact definition;
older development schemas return unsupported, and a missing/contradictory index
returns incomplete. Opening performs no implicit index migration.

## Executable checks

Startup tests hold optional work across actual checked publication; place required
Changes and snapshot prerequisites behind it; cover reconstruction, unfinished
verification and damaged required-history companions; reject stale/throwing host
publication; and exercise receive contention, repeated publication, finite local
saves, cancellation, close, restart and repeated rejection-write failures.

Scoped-query tests compare selected results with the full reader and independent
expected IDs, bodies and dispositions. They cover shared envelopes, complete
multi-note/collection actions, deleted and missing notes, native and portable
Undo/Redo, compensation forks, derived/automatic values, reciprocal copies and
later copy deletion. Occurrence, scope/member/parent/address corruption must fence
the owner. Wrong-store/session/scope/connection evidence is rejected by the actual
consumer; later accepted history preserves a read's exact captured prefix.

The fresh-process snapshot driver observes both durable ready-queue settlement
and current-row catch-up before inspecting the final model. Queue removal occurs
in the acceptance transaction, before materialization; queue emptiness alone was
an insufficient completion witness. This observation waits for the real worker
without redelivery or driving catch-up. Recovery receives only surviving storage
and normal selection/unlock inputs. Independent envelope inspection checks exact
retention, membership, values, private state and subsequent edits.

The completed campaigns below separate executable/model evidence from outstanding
physical power-loss, application and provider qualification.

### Completed independent campaigns

| Campaign | Executed result |
| --- | --- |
| Local arm64 / Swift 6.4, debug and optimized | Both complete 42-command inventories pass. Each Swift suite reports 300 functions: 295 executable functions discovered/passed and five skipped opt-in benchmarks, with only two expected snapshot-root-growth issues. Debug uses one integrated invocation; optimized uses the composite campaign below. |
| Intel macOS 11.7.11 | 40 received-snapshot termination/I/O/restart schedules and six scoped Undo/native-coverage/conflict-copy lifecycles pass for both profiles. The probe uses the documented macOS 11 metadata workaround and isolated concurrency runtime. |
| Intel Mac Mini / macOS 14.8.9 | The same 40 + six fresh-process schedules pass for both profiles, using the qualified Intel probe with the system concurrency runtime. |
| Ubuntu arm64 / Swift 6.4 | The final hardened probe passes the same 40 + six fresh-process schedules. The final optimized affected suite passes 20 functions; seven locality and 14 graph/query construction/routing probes pass with strict compiler checks, as do 19 independent schema tests. PIE, W^X, non-executable stack and RELRO checks pass; the deliberately RWX observer control is rejected. |
| Instrumented SQLCipher | ASan-instrumented production Runtime: 13 targeted test functions pass, including startup ordering, finite-interference progress, close/restart and selected-evidence corruption. The independent expired-handle control fails at its intended memory diagnostic; its valid companion passes. |
| Mutation controls | Eleven distinct affected controls reach their intended assertions with passing companions and nonzero test discovery. They challenge early publication, lost background reservation, discarded ready work, missing selection/member/compensation checks, truncated global dispositions, contextual evidence and the shared occurrence reader. |
| TLA+ | 17 new scheduling outcomes and 62 affected existing-model outcomes match their expected result. These 79 outcomes include deliberate counterexamples and reachability witnesses as well as positive exhaustive checks. |

Platform process recovery receives only surviving store/selection/unlock inputs.
The independent Node/envelope oracle remains in the parent. This is targeted
Linux/Intel macOS qualification, rather than a complete Swift Testing suite on
those systems. The Intel probes use the documented metadata workaround; these
runs do not qualify default compiler metadata, AppKit attribution or production
packaging.

Preserved campaign artifacts:

- Intel: `/tmp/nv-received-snapshot-process-dww8uqxj` and
  `/tmp/nv-scoped-platform-7q4vjs62` on Orbb.
- Mac Mini: `/tmp/nv-received-snapshot-process-isckkrv0` and
  `/tmp/nv-scoped-platform-vs_g_4tw`; the Intel probe and resource bundle are
  preserved under `/tmp/nv-startup-scope-mini.aZ0qEM`.
- Ubuntu: `/tmp/nv-received-snapshot-process-x0xv6jgb` and
  `/tmp/nv-scoped-platform-3lykqvyc` on the VM; ELF/build logs under
  `/var/lib/nv-storage-test-volume/nv-startup-scope.M2juR3`.
- Instrumented cipher: `nv-cipher-sanitizer-j9nnccss` in the local temporary
  artifacts directory.
- Mutation controls: `nv-runtime-mutations-1g8orejf`,
  `nv-runtime-mutations-u796n6y4`, `nv-runtime-mutations-57tkvi9r` and the
  corrected exact-member diagnostic rerun `nv-runtime-mutations-a480tbc_`.
- New scheduling model: `nv-improvements-tla-97e5vad8`. Affected existing
  families: `nv-improvements-tla-ve0jkxyy`, `nv-improvements-tla-uqmjz9el`,
  `nv-receive-tla-9t4i6gb7`, `nv-segment-tlc-y4qzb89v`,
  `nv-receive-tla-u_t6s9vj` and its two large-case reruns
  `nv-receive-tla-alo2sdyq`.

Four observation defects were corrected without changing production policy.
The snapshot process observer now waits for materialization as well as queue
settlement. The new scoped-query corruption test preserves the existing precise
`incomplete` result for missing retained bytes and `integrity` for contradictory
indexes; both still require the owner to be fenced on subsequent use/reopen.
Its selected-member mutation was rerun and failed at the intended assertion.
The older 22-case snapshot driver expected an optional root to be accepted during
`open`. Its crash cut now targets `publish-drain-crash`; the final child performs
actual checked publication and observes background settlement. It additionally
checks the independently expected publication prefix and notes, preserving every
prior byte, membership, context, frontier and subsequent-edit assertion. All 22
adapted cases pass with the final optimized probe.
The new scoped-process driver's initial post-Redo oracle used the original edit
ID. It now expects the latest Redo action, matching the existing causal-selector
contract and independently inspected retained actions. All six lifecycles pass
in both configurations and on the three qualified remote hosts.
Failed runs remain available alongside their successful replacements.
The Linux compiler campaign's first standalone setup lacked pinned headers;
the next attempt overlapped the optimized compiler build and hit its existing
60-second watchdog. The final standalone run passes every unchanged probe.
The earlier build rejected a test source modified while compiling; the complete
stable-source rerun passes. Neither compiler checks nor test assertions were
relaxed for these failures.

### Complete debug and optimized inventories

The debug integrated driver completes all 42 commands in one invocation.
`nv-storage-phase2-ue_bzpz3/results.json` records the command inventory, 295
discovered executable functions, schema hash and qualification limits. Its
300-function suite completes in 1,849.901 seconds; the optimized suite completes
in 1,283.281 seconds. These are whole-suite elapsed times, separate from the
startup/query observations below.

The complete 42-command optimized inventory passes through a composite campaign:
nine successful original commands, the corrected 22-case snapshot driver, then
all 32 remaining commands. This includes all fresh-process drivers, Core/Runtime/
private construction and consumer probes, 19 real-SQL tests, the independent
record/envelope/descriptor/current-frame fixtures and strict C diagnostics.
The original integrated invocation remains a failed invocation; it is not
presented as an uninterrupted pass. The corrected driver and continuation use
the original run's immutable qualified probe. All 68 captured production-source
hashes still match after completion.

`nv-storage-phase2-33p2jhx7/composite-results.json` records the 42 commands,
their logs, source/schema/probe SHA-256 values and the retained failed log.
The corrected snapshot artifacts are `nv-snapshot-process-qkujye5m`.
Local artifact directories live under
`/private/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/`.
The complete debug logs and immutable probe are preserved in
`nv-storage-phase2-ue_bzpz3`.

### Reproduction entrypoints

The complete local campaigns use the existing integrated driver. It requires
the named production tests, passing completion, exact schema/independent fixtures,
fresh-process drivers and strict compiler probes:

```sh
python3 tools/test-storage-phase2.py --configuration debug
python3 tools/test-storage-phase2.py --configuration release
python3 tools/test-storage-runtime-types.py --review-only --modules NVStorage/.build/release/Modules
python3 tools/test-storage-scoped-platform.py --binary NVStorage/.build/release/NVStorageProbe
python3 tools/test-storage-received-snapshot-process.py --binary NVStorage/.build/release/NVStorageProbe
```

The compiler probes use the pinned SQLCipher headers under
`NVStorage/.deps/sqlcipher/include`. Linux builds additionally use the integrated
driver/manifest workaround and the existing `lld` hardening flags. SSH process
campaigns accept `--ssh-target`, `--ssh-key` and `--remote-env`; the independent
oracle stays local.

Affected mutation names for `tools/test-storage-runtime-mutations.py --only`:

- `optional-startup-drains-everything`, `optional-startup-lost-reservation`,
  `optional-startup-before-publication`, `optional-startup-discards-ready`;
- `scoped-query-omits-member-check`, `scoped-query-omits-compensation`,
  `scoped-query-omits-native-coverage`,
  `scoped-query-truncates-global-dispositions`,
  `scoped-query-reuses-foreign-connection`;
- `traversal-occurrence-omitted` and
  `received-snapshot-omitted-occurrence-audit` for the extracted shared reader.

Run the new scheduling family with `docs/tla/check-improvement-models.py --only
optional-startup --java <runtime> --jar <tla2tools.jar>`. The affected verification,
coalesced recovery, receive-resumption, SQLite fast-start and received-snapshot
families retain the commands and expected controls in `docs/tla/README.md`.
The two large received-snapshot positives required the unchanged bounds with a
900-second watchdog; their original 300-second timeouts remain failed campaign
artifacts, rather than being counted as passes.

The legacy app build also passes with Xcode 27 using the approved
`__DIAGNOSE_INVALID_DEPLOYMENT_TARGET_AS_ERROR=NO` setting and disabled signing.
The default `build.sh` invocation rejects the existing 11.5 deployment target
under that SDK. The project target, build script and interaction code remain
unchanged; SDK acceptance is separate from the exercised Intel process paths.

## Work bounds and interpretation

With fixed queried history and 64, 256 and 1,024 unrelated edits, combined selected
Undo/conflict queries read and decode one envelope, build zero full graphs and
execute 193 SQL statements in each tested profile/size. The untouched-note/no-copy
case reads zero historical envelopes. Selected shared envelopes decode once.
Assertions distinguish fixed schema/current-row work from historical table scans;
the fixed schema index check adds catalog work, rather than an ancestry traversal.
These are deterministic work counts, not constant-time database-lookup claims.

The final optimized two-note fixture observes 4.6–17.7 ms from open through
checked publication and 90.7–141.4 ms for background completion after releasing
the optional-work gate, with 16/64 prior edits and both profiles. Fixed-scope
Undo/conflict queries observe 22.5–42.9 ms across the 64/256/1,024 unrelated-action
cases. These warm observations were taken alongside other qualification work;
they neither establish cold-read latency nor promise a fixed UI deadline.

Global copied-ID work can grow with conflict-copy history. Querying a long history
for the selected note also grows with that scope; a packed envelope may contain
other records whose complete membership must be checked. Full collection commands,
conservative whole-prefix replay after interrupted verification, current-note
loading and snapshot-root accumulation retain their existing costs. Timing logs
separate actual publication from later background completion and query work.

## Model correspondence and limits

`OptionalReadyStartupSafety` separates required/optional work, snapshot validation,
acceptance, materialization, actual publication and receive ownership. It includes
late required delivery, finite save interference, interrupted preparation,
rejection-write failure and restart. Six finite exhaustive scenarios, seven
targeted mutation controls and four contested-state witnesses passed. Its progress
claims explicitly account for close and storage-stopped outcomes. Existing
verification, recovery, receive-resumption and SQLite fast-start models retain
their safety conditions; concrete byte/index checks are executable evidence.

No public result shape, semantic table, sidecar, replay-record encoding or maintained
query cache is added. Snapshot acceptance still leaves note values unchanged.
Snapshot retention-parent coverage, pruning, UI/provider integration and broader
command acceleration remain separate work. Real physical power-loss behavior is
unqualified; process termination, injected I/O errors and later corruption remain
distinct tested fault classes.
