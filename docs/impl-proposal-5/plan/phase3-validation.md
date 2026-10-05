# Phase 3: connected portable semantics

Date: 2026-10-01. Status: portable implementation complete and qualified on the
available arm64/Intel macOS hosts, with the release limits below. This report is the completion map for the
[phase plan](swift-storage-implementation-plan.md#7-phase-3--portable-semantics-through-two-independent-stores)
and [schedule/observation matrix](phase3-schedule-observation-matrix.md).
The specification, Protocol, ADRs and CONTEXT retain semantic authority.

The subsequent [review corrections](phase3-review-corrections.md) qualify historical
adoption, pre-seal rejection ownership, cancellable command calculation, current
creation dates and synchronous final cipher disposal on the newer source revision.
The [typed-boundary follow-up](typed-runtime-boundaries-validation.md) strengthens
acceptance inputs, command intent, reviewed compensation and local commit states
while preserving the same history and recovery semantics.

## Implemented responsibilities

| Responsibility | Production boundary |
| --- | --- |
| Complete declared writer history | `OrdinaryHistoryV1`: complete membership, exact before/after states, causal dependencies, note predecessors, all same-scope maxima, previous-origin and command-specific evidence |
| Equal/merged editable Current | `NoteReductionV1`, `DerivedStateReferenceV1`, `CurrentNoteCellV1`: exact represented inputs, remaining heads, unique base, value digest and deterministic merge identity |
| Logical deletion/preservation | `CollectionReductionV1`: union of all Delete coverage, maximal uncovered sources, retractable automatic views, independently authored work and typed monotonic retirement |
| Source choices and copies | `chooseVersion`, `copyVersion`, `conflicts`: exact captured heads, body-only source replacement, verified recovery slots and retained separate-copy dispositions |
| History and Recently Deleted | `history`, `preview`, `recoverHistory`, `restoration`: bounded metadata pages, exact retained sources, selected field recovery, fresh ordinary copies and durable deletion-entry provenance |
| Portable Undo/Redo | `CausalUndoV1`, `CompensationV1`, `prepareCompensation`, `applyCompensation`, `applyReviewedCompensation`: direction-specific causal candidates, separate automatic/reviewed command values, actual inverses, complete named groups and fresh restored births |
| Native saved-group coverage | `nativeCompensation`: attributed member steps, each group's remaining state and completeness; cross-launch remaining reversal and actual Redo |
| SQL reduction/publication | `GraphMaterialization`, `Publication`: bounded database reads, off-connection computation, one complete guarded batch and final owner/view/host-generation checks |

Both profiles use the existing encrypted private database and share the same
acceptance/reopen path. The single-current save optimization remains intact.
General conflict/compensation/history queries read retained evidence in bounded
database turns; their full graph calculation is separate from healthy indexed
startup and ordinary single-current saving. No lifetime history cap is added.

The [connected record contract](phase3-connected-record-contract.md) freezes action
tags 7–12, operation tags 7–9, derived/automatic admission states and version-2
current cells. Full-state Restore retains its canonical optional-state presence
byte even when absent. The direct Restore fixture is 202 bytes. Independent
fixtures fix expanded identities and every nested scalar/reference layout.

Store-issued proposals/previews retain file-private construction. Capture and
consumption bind the owner session, store, current view/presentation epochs,
affected values and candidate frontier. Restricted receipts cover exact note
generations. The database actor owns its connection; immutable graph inputs and
computed rows cross its boundary as Sendable values. The host clears only matching
pending generations after a real acceptance barrier.

## Matrix coverage map

Names below are actual Swift tests or process-driver lifecycles. Each is required
by the existing qualification driver. All connected positives run under both
profiles unless an initial component report explicitly identifies a single-profile
context-only case.

| Matrix rows | Concrete tests and independently observed result |
| --- | --- |
| M1 | `concurrentHistoryIsRetainedAndReopensEditable`, `mergePreviewAcrossIndependentStores`, L1: exact merged/equal value, every input, subsequent edit predecessors and fresh editable reopen |
| M2 | `ordinaryConflictEditPreservesKnownUnchosenHeads`, `sourceChoiceFencesConsentAndHistoryFieldsStayExplicit`, `reciprocalCopiesKeepSourceAndDurableDispositions`: ordinary edits preserve incompatible heads; explicit choice covers its captured heads; pin release restores neutral selection and fences old presentation |
| M3 | `thirdWriterFencesPreparedMergeAndPreservesUnchosenHeads`, graph fixtures: real two-input preparation invalidated by T, three heads require review, a justified L/T descendant leaves R; ambiguous-base and equal-head companions |
| A1 | `ordinaryValidationUsesExactWriterBasisAndPreservesOriginForks`, `connectedCommandsRejectAuthenticatedNearValidClaims`, `completeNamedActionRejectsOneWrongMemberAtomically`: exact writer scope/values, valid later receiver history and complete-group rejection |
| D1 | `deleteCoverageRetractsOnlyUntouchedPreservation`, L1: temporary uncovered copy exists, later covering Delete retracts it, concurrent descendant remains historical/preserved as specified |
| D2 | `independentAutomaticEditSurvivesLateCoverageAndRetirement`, `independentPreservationAdmissionFencesRetractionPublication`, L2: actual independent admission, stale retraction rejected, captured originating evidence accepted on a peer already holding coverage |
| D3 | `equalAutomaticKeyNeedsEverySourceCovered`, `ordinaryIdentityCollisionPreservesFileAndSkipsRecoverySlot`, L2/L3: equal-key eligibility, typed retirement, unrelated ordinary identity preserved and exact copy deletion |
| D4 | `RestorationTests`, `mergedDeleteRestoresExactStateAndSelectedPriorBranch`, Restore process driver: full/selected prior state, fresh independent births, exact source-entry exclusion and callback-free recovery |
| C1 | `reciprocalCopiesKeepSourceAndDurableDispositions`, L3: original retained, two copies/dispositions, output deletion leaves both dispositions retained, later source work is assessed independently |
| C2 | `conflictCopySlotsVerifyStateAndRetainExactRetries`, identity-collision test: canonical body key, metadata-preserving reuse, modified/retired/occupied slots, exact-byte admitted retry and independently preserved output |
| C3 | `sourceChoiceFencesConsentAndHistoryFieldsStayExplicit`: stale pre-admission consent rejected, exact valid choice, body/all-field historical recovery, fresh ordinary copy, post-admission remote descendant survives reopen |
| U1 | `orderedUndoRedoKeepsActualValuesAndRemainingTail`, L4: ordered redo continuation and exact current-before/actual-after inverses, distinct from later settled Current |
| U2 | `reviewedCompensationRejectsChangedScopeButAllowsUnrelatedWork`, `compensationCompletionPreservesNewerPendingGeneration`, L4 fault cuts: actual consumer context checks and earlier durable compensation leaving newer edit/Delete pending |
| U3/U4 | `concurrentCompensationsNoOpAndIndependentFamily`, L4: separate compensation siblings, no-effect adds no record, opposite direction continues, independent family remains automatic |
| U5 | `concurrentDeleteUndoKeepsFreshBirthMappings`: R1/R2/R3 remain distinct, each actual inverse affects its own resulting birth and restoration history survives reopen |
| U6 | `namedCompensationKeepsAllMembersAndRejectsStaleApproval`, complete named-action negative, `NativeCoverageTests`: whole named group, partial span crossing saved groups, remaining coarse Undo and actual Redo, incomparable complete/partial claims retain review |
| X1 | `connectedParkedCopyResumesAfterFiniteSaveInterference`, six-order process fixtures, existing rejection/recovery tests: two exact prerequisites, finite interfering saves, completion-only wake-up, restart and distinct rejected/missing/required-damage outcomes |
| X2 | `runtimeMergeBoundaryPreservesValidHistory`, generated kernel/codec fixtures and `ordinarySaveWorkAcrossGrowingHistory`: 10,000/10,001-token two-sided cutoff, valid long equal/one-sided values, growing ancestral histories and bounded turns |

Component reports additionally retain independently constructed 3,249 edit pairs
in both orders, 315 five-node rooted DAGs, scalar/label/date/text limits, literal
merge identities, malformed derived references and every truncation of the short
canonical fixtures. They qualify those components; the rows above qualify their
actual Runtime consumers.

## Fresh-process schedules and independent inspection

`tools/test-storage-phase3-process.py` executes 60 named schedules: both profiles,
observed/concurrent L1 with three receive cuts, L2/L3/L4 with six selected save/fault
cuts, and all six delivery permutations of the three-envelope/two-prerequisite
copy graph. Exact repeats accompany the delivery graph. Each lifecycle includes
a second failure during derived-row recovery. These are selected crash/fault
combinations plus an exhaustive small delivery dimension, not the Cartesian
product of every environmental event.

The child receives surviving stores and normal selection/unlock inputs. The parent
owns the expected-state oracle. `inspect-storage-history.mjs` independently opens
actual retained envelopes, decodes expanded operations/actions/references, verifies
complete accepted membership, edges and retained coverage, and calculates the
expected logical state from those bytes. It compares current values, heads,
represented inputs, dispositions, typed identities and restoration records with
the fresh production opener. Peer agreement is supplementary evidence.

Every test stores its exact commands, outputs, envelopes and effects in `trace.json`.
L4 records actual Errands→Groceries compensation while its unchosen Shopping head
remains. Normal one-sided reduction can settle Current to Shopping; subsequent
inverses therefore record Shopping→Errands and Errands→Shopping. This distinction
prevents using an action's output as an oracle for the later reduced Current.

Because raw IDs select stable Current, L4 may create up to 64 fresh finite fixtures,
each with at most 16 valid concurrent Errands updates, to reach its fixed review
cut. Prefixes selecting a different Current are preserved and explicitly excluded
from completed-witness counts. Required named lifecycles must all reach their cut.

Crash cuts distinguish candidate retention, history acceptance, current-row update
and missing callbacks. Semantic-command COMMIT faults arm when the real acceptance
transaction inserts `accepted_objects`; read-only snapshots used for command
revalidation cannot consume that cut. Trace/hit assertions and independently
recovered membership identify the actual outcome. EIO, ENOSPC and busy failures
preserve exact retry bytes; process termination and later row corruption remain
separate fault classes. Physical power-loss survival is a separate qualification.

## Executed checks and artifacts

Development host: arm64 macOS 26.6.2 (25G83), Swift 6.4
`swiftlang-6.4.0.34.1`, pinned SQLCipher 4.19.0/CommonCrypto. Source base:
`932389b23c39cb2df9d131f7385d3307e40aa3ae` plus this uncommitted increment.

- Final debug and optimized Swift suites each passed 148 active functions; the runner
  reports 149 entries including the opt-in skipped history benchmark. Ten parameter
  cases cover the three new Runtime boundary functions. The later post-admission
  choice/reopen extension and real-cipher integral-tag rejection are included in
  the final suites; earlier targeted reruns retain their own evidence.
- Final instrumented SQLCipher/Runtime ASan campaign passed, including a valid
  handle companion and a targeted expired-handle negative demonstrating actual
  cipher instrumentation. Final artifacts: `nv-cipher-sanitizer-viizj2ga`;
  `nv-cipher-sanitizer-u9movw8m` preserves the preceding pass.
- Ordinary-client and same-module compiler probes passed 31 Core and 48 Runtime
  construction/consumption cases plus classifier self-checks, including actor
  isolation and file-private command/preview/receipt issuance.
- All 12 new semantic mutations compile and fail their designated assertions.
  Ten passed in `nv-runtime-mutations-ahweaaee`; two sensitivity corrections passed
  in `nv-runtime-mutations-4w7cyj5b`. The first campaign's two earlier verdicts are
  preserved rather than counted as successes. Corrected tests inspect emitted
  predecessor claims before downstream rejection, and retained copy dispositions
  even when the selected source is Current. Classifier/setup self-checks pass.
- Eight relevant model families passed 177 effective configurations: 68 positive
  exhaustive runs and 109 targeted negative/reachability controls. The existing
  bounds and model-specific abstractions remain explicit in the TLA README.
  `NativeCausalUndoBridge` adds 14 cases: ordered partial continuation, incomparable
  partial/complete claims with both stable selections, actual U/R/S/T inverses,
  one restart and conditional peer agreement. Positives explore 63–81 distinct
  states; six defects and two reachability witnesses produce their named
  counterexamples. Native attribution remains an AppKit integration obligation.
- The macOS app builds with the previously approved
  `__DIAGNOSE_INVALID_DEPLOYMENT_TARGET_AS_ERROR=NO` override. Xcode 27's target
  diagnostic persists without that override; deployment target remains 11.5.
  Application interaction source is unchanged.
- The stock epoch-4 smoke script encountered the same Xcode target diagnostic.
  Its build/write/historical-reader sequence then passed with the approved setting
  supplied explicitly to both Xcode invocations. The historical reader verified
  the newer-archive warning and exact expected note. Temporary replay script,
  sources and outputs are retained in `/tmp/nv-phase3-epoch4-final.x0tzVc`;
  the stock entrypoint and its assertions are unchanged.

The initial optimized full driver exposed a schema regression: expanded `BETWEEN`
tag constraints admitted fractional REAL values. Explicit integer storage-class
checks now cover operation/action tags and rejection reasons. All 17 schema tests
pass; `cipherSchemaRequiresIntegralHistoryTags` also rejects fractional updates
through actual SQLCipher under both profiles, verifies unchanged rows/values and
reopens successfully. The initial failure remains in `nv-storage-phase2-ylpqv3ni`;
it is not counted as a successful full-driver run.

The subsequent optimized campaign `nv-storage-phase2-ixc_3tjw` passed the corrected
schema and all 60 connected schedules, then stopped at a fixture-checker filename
typo. The driver now uses `check-connected-record-fixtures.py` and preflights every
fixture path before its long-running work. The remaining canonical/cipher fixtures
and strict C checks passed directly. The corrected complete optimized entrypoint
passed all 26 stages in `nv-storage-phase2-lcdvthig`: 148 discovered active Swift
functions, 60 connected schedules, underlying process/generated/rejection checks,
compiler clients, 17 schema tests, nine canonical fixture checkers, independent
envelope/descriptor fixtures and strict owner/fault C diagnostics. Its
`results.json` records exact commands and the final schema digest. Earlier failed
runs retain their actual scope.
The final connected inventory is `nv-phase3-process-ry5yg_q2`: 60 completed
required witnesses and two retained, excluded different-Current L4 prefixes.

The debug process campaign `nv-storage-phase2-ovmj86cq` also passed its 60 schedules
before that same checker-path failure. Its copied resource used the preceding
`1b014162…` DDL. The final 148-function debug suite separately used the corrected
`2dac5330…` DDL, including real-cipher rejection and fresh reopening. The old
campaign is semantic/fault evidence at its captured resource revision, not a claim
that it tested the subsequent constraint change.

Intel macOS 14.8.9 (23J631) passed all 60 connected schedules plus four history,
12 Restore and six merge-evidence process schedules. The executable was
cross-compiled with Swift 6.4 requesting x86_64/macOS 11.5, using the pinned Intel
SQLCipher/CommonCrypto archive, then executed on the real Mini. Its binary SHA-256
is `e6819a48f5f0ea29c123d55b41aff55075fcfd76a530775d56185c6b278688cf`;
its resource DDL matches `2dac5330…`. The temporary checksum-verified Node 25.0.0
oracle supports Argon2 and zstd. One valid different-Current L4 prefix was retained
and excluded; all 60 required witnesses completed. Traces and inventories are
preserved in `/tmp/nv-phase3-intel-connected-artifacts.tar.gz`; the Mini's working
directory is `/tmp/nv-phase3-intel.WQHexi`.

Subsequent Mach-O inspection found that SDK-27 SwiftPM had emitted a macOS 12
deployment target for that binary despite the requested 11.5 triple. These remain
actual macOS 14 results; they establish no macOS 11 execution. The
[review correction](phase3-review-corrections.md) records explicit compiler targeting
and renewed platform qualification, while retaining the declared 11.5 support policy.

The Mini's installed Swift 6.0.3 package-manifest linker failed before source
compilation, so this is executable/protocol qualification rather than a claim
that its local Swift Testing runner works. An earlier attempt was interrupted by
a Mini restart at 17:10; it is excluded from success counts. The successful rerun
used a new temporary directory. macOS 11 rejected available SSH authentication;
Linux timed out, and their original temporary identity files are absent. Neither
platform received relaxed production or test contracts.

Fixture SHA-256 values:

| Fixture | Digest |
| --- | --- |
| `connected-records.json` | `90de94ddca1fdf8e5c5fd1c33557c4feb5846a6ac3811014023c7c873be74b25` |
| `current-cell-v2.json` | `3aceed89c5f257ea96edf60a994788520330a3c2616dd1c50ab84a5a636ee3fa` |
| `restoration.json` | `bb47433a7c9e0c09a4314ac4a48166a7bd03d4bf821f70d4b17d791472c4c67f` |
| `derived-state.json` | `a69de0522276b3e8a073d87dfc351b0bd2a4cfb28b7a33761b087fd713bdb1e9` |
| `merge.json` | `98c61c2fdb66ccccd40205b0c90fc1f865455ca40e2763d63bab2dcae8fcc7c5` |
| Resource/schema DDL | `2dac5330cd87995d7c1a38366b051a1b3da90948312f85cc8312d849a64800e0` |

## Reproduction and qualification boundaries

```sh
python3 tools/test-storage-phase2.py --configuration debug
python3 tools/test-storage-phase2.py --configuration release
python3 tools/test-storage-runtime-mutations.py --self-test-only
python3 tools/test-storage-runtime-mutations.py --only conflict-current-only-predecessors --only conflict-slot-domain --only delete-union-coverage --only copy-disposition-retention --only undo-proposal-context --only undo-stale-values --only undo-family-scope --only native-complete-any-claim --only native-remaining-original --only command-omitted-choice-heads --only native-inaccurate-coverage --only native-candidate-router
python3 tools/test-storage-sanitizers.py --prefix NVStorage/.deps/sqlcipher-asan
```

Use the [TLA README](../../tla/README.md) runner for `SegmentMergeSafety`,
`SegmentDeletionOrderingSafety`, `NVConflictCopySafety`, `PortableCausalUndoSafety`,
`ConcurrentUndoExecutionSafety`, `CompensationOverlapBridge`, `NativeUndoSpanSafety`
and `NativeCausalUndoBridge`. A repeated `--only` flag on that runner replaces the
previous selection; use `--model` for a full family's effective cases.

Provider publication/discovery, physical projection installation/removal, Apple
version setters/verification, application resolver/history UI, native AppKit
attribution, actual input-method/view lifetime and repair/selected-store cutover
retain their later phases. Retained receipts and derived retraction grant logical
history/view authority; physical files require their separately captured exact
snapshot and installation/deletion policy. New rich encoders and attachments
remain deferred. macOS 11 and fresh Linux execution of this full increment require
their available platform campaigns; prior phase-2 evidence keeps its original scope.
