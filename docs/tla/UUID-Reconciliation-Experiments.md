# UUID reconciliation experiments

Status: experimental, **not adopted product policy**. No production code, normative specification, or ADR was changed. UUID xattrs, aliases, and an NV-managed Trash protocol still require a policy decision and implementation design.

## What the experiments establish

Choosing a common UUID and establishing common file identity are different problems. The first has useful convergent rules. The second cannot always be solved automatically from database UUIDs, xattrs, names, and content: distinct histories can expose exactly the same inputs.

The strongest tested candidate keeps the existing live database UUID stable, treats xattrs as claims, and reconciles through **durable aliases scoped to a positively established file incarnation**. It preserves both hosts' edit payloads and old-UUID WAL references in the bounded assignment experiment. That is conditional: no existing Apple API is presumed to supply the necessary cross-host association proof. Unknown association or intent remains unresolved, with inputs retained; it is not silently classified as a new note or a deletion.

## Connection to the current implementation and contracts

- [`NoteObject.m`](../../NoteObject.m) initializes fresh note identities with `CFUUIDCreate`; [`NotationDirectoryManager.m`](../../NotationDirectoryManager.m) prepares external additions independently and publishes a detached transaction.
- [Proposal #4](../impl-proposal-4/README.md), under current-file identity and checkpoint-current reconciliation, gives unmatched files fresh UUIDs and associates competing checkpoint records by UUID. It explicitly prohibits UUID xattrs. Thus a common external file need not have a common logical UUID on two independently importing hosts.
- [`CONTEXT.md`](../../CONTEXT.md), the [spec](../iCloud-Drive-Support-Spec.md), and [ADR-0014](../adr/0014-use-current-visible-sync-and-explicit-conflict-copying.md) distinguish local filesystem association, logical UUIDs, pending deletion evidence, and checkpoint omission. These experiments do not collapse those identity domains.
- [Apple contract observations](../Apple-API-Contract-Validation.md) show syncable custom attributes arriving on both Macs, surviving tested eviction/materialization and rename, being copied by Finder, and being removed by generic atomic replacement. Historical conflict bodies did not reliably carry them. Missing attributes therefore are not proof of a new note; equal attributes are not proof of the same incarnation. No reverse File Provider lookup or portable historical `persistentIdentifier` is assumed.

Existing checkpoint/cross-machine models begin with an already-identified source UUID. These experiments test that missing premise, rather than claiming those existing proofs cover independent import.

## 1. Concurrent assignment and checkpoint/WAL reconciliation

[`UUIDAssignmentRace`](UUIDAssignmentRace.tla) has two hosts, one external file, two proposed UUIDs, one edit payload per host, and at most two successful checkpoint installations. Both hosts start from the same empty checkpoint for this file. Each can independently import it and capture an initial xattr proposal before seeing the other's write.

Import, initial stamping, provider delivery, reassignment, edit/WAL admission, checkpoint capture, exact-current attempt, merge, settlement, crash, and recovery are separate actions. A close can race metadata convergence. The second closer must reconcile against the actually installed checkpoint; recovery consumes that checkpoint and the actual modeled old-UUID WAL row, not an invented already-normalized recovery result.

The model stores finite sets of edit payload tokens, not text or diff-match-patch output. A joined row is one logical identity with both payloads retained; this is not permission to concatenate conflicting text. Concrete conflict-note allocation, payload ordering, and file installation remain separate obligations.

| Rule | Effective UUID eventually agrees¹ | No duplicate logical row after both closes | Old WAL replay does not fork identity | Old WAL UUID remains in local aliases and installed checkpoint | Live DB UUID never changes |
| --- | --- | --- | --- | --- | --- |
| `database`: ignore tags | No | No | No | Yes | Yes |
| `restamp`: keep DB UUID and correct differing observed tags | No | No | No | Yes | Yes |
| `xattr`: adopt the observed tag | Yes | No | No | No | No |
| `eagerMinimum`: choose smaller UUID and periodically restamp | No | No | No | No | No |
| `minimum`: choose smaller UUID; write only to correct observed metadata | Yes | No | No | No | No |
| `aliases`: minimum plus retained learned UUID aliases | Yes | No | No | Yes | No |
| `scoped`: additionally join positively associated checkpoint rows | Yes | Yes² | Yes² | Yes | No |
| `stable`: scoped aliases, but retain each live DB UUID | Yes³ | Yes² | Yes² | Yes | Yes |

¹ Only in the separate `Mode = "settle"` configuration, with no closing and weak fairness for local processing and latest-state delivery. This is not a promise of convergence while offline, nor delivery of every intermediate metadata value. Close/recovery safety uses no fairness assumption.

² The one-file model gives `scoped` and `stable` a positive same-file association for these rows. Blindly applying their union operation across all records would be unsafe. The second model tests that limitation, including a control that injects a false-positive proof.

³ Both live DB UUIDs can remain different. Agreement is on the effective alias representative, not mutation of both `NoteObject` identities. Checkpoint reconciliation chooses a canonical representative while retaining claims needed to replay old local UUIDs. The witness `NeverMergedWithDistinctLiveIDs` reaches a single merged row with two distinct live IDs.

### Counterexamples worth retaining

1. **Independent imports survive a correct checkpoint CAS as duplicates.** Both import before either tag is visible, creating UUIDs A and B. A closes with `{A}`. B's stale installation is correctly rejected, but UUID-only reconciliation sees two additions and installs `{A,B}`. Both payloads survive; logical identity does not converge. This is the current-policy hypothesis, not an invented overwrite bug.
2. **Correct metadata convergence can happen too late.** Even minimum/alias rules allow closing before either host observes the competing claim. Learned aliases alone cannot join checkpoint rows whose association was never learned.
3. **Reassignment is a durability change.** A WAL row exists under A, then the live record adopts B. If only B is serialized, A's durable reference is no longer represented by the identity mapping. Merely changing the in-memory UUID or xattr is insufficient. The serializer and replay controls detect missing alias coverage.
4. **Periodic re-stamping can prevent its own convergence.** An A host writes A; a B host blindly re-stamps B before observing A. The cycle is weakly fair because B never has a continuously enabled opportunity to read A. The change-triggered minimum variant stops the unnecessary write and passes under the same fairness assumptions; stronger provider fairness was not added to hide the failure.

## 2. Association, copies, deletion intent, and restoration

[`UUIDAssociationLab`](UUIDAssociationLab.tla) exhaustively explores 24 explicit fixtures (23 in the initial run) and one optional edit, replacement, restoration, or checkpoint disturbance between capture and publication. It does not take the Cartesian product of unlimited histories. Each fixture contains two candidate records, their observable UUID/tag/name/body/epoch evidence, and separately held ground-truth origin/intent used only by assertions.

The decision function can inspect only its captured observation. It cannot inspect the fixture name or ground truth. `proof = same/different/unknown` is an explicit conditional input: verified **same incarnation**, not equal tags, local inode values compared across Macs, filenames, or historical version identifiers. Positive Trash fixtures additionally assume the record is genuine NV deletion evidence for that incarnation; a plain user-created subdirectory supplies no such guarantee by itself.

| Rule family | No false joining of copies | No incorrect final separation of one file | No false intentional deletion |
| --- | --- | --- | --- |
| DB UUID wins | Fails | Fails | Fails |
| Xattr wins | Fails | Fails | Fails |
| Minimum DB/xattr UUID | Fails | Fails | Fails |
| Equal filename and body | Fails | Fails | Fails |
| Global UUID alias set | Fails | Fails | Fails |
| Equal UUID plus copied incarnation xattr | Fails | Passes by deferring nonmatches | Fails |
| Checkpoint omission overrides intent uncertainty | Fails | Fails | Fails |
| Revalidated incarnation evidence; otherwise defer | Passes conditionally | Passes conditionally | Passes conditionally |

The passing evidence rule actually joins independent imports, keeps known copies separate, accepts positively identified Trash deletion, preserves the local edit from a delete/edit race, keeps a restored source, and installs/reopens its results. Separate reachability traces require each of those paths. It is not an always-defer policy. Nevertheless `NoDeferral` deliberately fails: some fixtures cannot safely finish automatically.

These are isolated rule hypotheses, not a claim that today's implementation applies each rule or can produce every hypothetical UUID/xattr combination. In particular, the first model's duplicate-import trace tests the current UUID-only checkpoint-association premise; the second model also exercises proposed xattr/alias protocols that are not implemented.

### Indistinguishable histories

The model checks that these pairs expose identical complete decision inputs but different required classifications:

- Two imports sharing a tag, versus a copied tag on a different file that was assigned another local DB UUID.
- A safe-save replacement that stripped the tag, versus a newly created, unrelated file with the same name/body and no tag.
- An old Trash entry followed by restoration and another unexplained disappearance, versus intentional deletion of the original incarnation. Copying the incarnation attribute does not distinguish them.
- A complete competing checkpoint that never contained the note, versus a checkpoint whose writer intentionally deleted it. A receiver's base membership plus the incoming checkpoint's omission does not establish that incoming branch's ancestry.
- A real intentional deletion whose Trash evidence has been purged before observation, versus unexplained external disappearance.

This fixture-equality assertion is a sanity check on the indistinguishability construction, not a separately deep safety proof. Its consequence is information-theoretic: a deterministic decision function receiving equal observations returns equal decisions. When the correct automatic answers differ, at least one answer is wrong unless additional evidence or an unresolved state is allowed. Random tie-breaking cannot provide an all-behaviors safety guarantee either.

Trash-first delivery keeps the still-visible source. Source-absence-first delivery without corresponding intent evidence defers. Restored/new incarnations cannot inherit an old incarnation's deletion authority. None of these actions physically unlinks a current file; the original expected-snapshot removal rule remains a separate constraint.

## Candidate rules to carry forward

The most promising direction is `stable` plus the second model's guarded evidence policy, **not unconditional xattr authority**:

1. Keep a live DB UUID as a stable local handle. Use an xattr to advertise/discover a candidate identity, not to overwrite an existing note merely because it differs.
2. Establish whether competing records refer to the same incarnation before joining them. A different proven incarnation is a separate identity even if it copied the UUID and every attribute. Unknown remains unresolved; missing metadata is not proof of separation.
3. For an established association, retain all necessary old UUID aliases and choose a deterministic representative. Do not repeatedly restamp without an observed reason. Persist aliases with the checkpoint and make replay use them; dropping them after merely changing a live object is unsafe.
4. Scope aliases and deletion evidence to the established incarnation. Do not let global transitive UUID aliases join a later copy or let an old Trash record delete a restored note. An NV-authored restore can issue a fresh incarnation, but an external byte/attribute-identical restore is still ambiguous.
5. Accept automatic remote deletion only with both relevant intentional-deletion evidence and current incarnation applicability. Otherwise preserve the in-memory note and offer/retain the confirmation decision. A filename, equal UUID, timeout, or arbitrary incoming checkpoint omission cannot supply the missing facts.

These two modules are complementary experiments, **not an executable refinement/composition proving this combined protocol**. Before adopting it, the design must specify how positive cross-host association and intent evidence are obtained and persisted. In particular, a durable alias is not useful if its incarnation binding was guessed. Existing local, volume-qualified filesystem matching does not automatically bind a remote checkpoint row to that same file.

The stable-handle variant also requires an explicit rule for alias-aware pending sets, undo/external-edit references, source-UUID-derived deterministic conflict identities, and alias retirement. Those implementation and schema costs are not proven away by the small model. No alias garbage-collection protocol or universal fully automatic resolution has been established.

## Verification and bounds

In the initial 2026-09-04 run, TLC 2.19 with the Wolfram-bundled Java 21 runtime verified all **97 expected outcomes**: 29 exhaustive passes, 46 rejected policy/property hypotheses, 11 reachability witnesses, and 11 detected mutations. The combined baselines visited 533 states (`scoped` assignment), 463 (`stable` assignment), and 401 (evidence/intent lab), with zero states left on every passing queue. These are finite model-checking results, not an unbounded theorem about all files or histories. The [two-Mac follow-up](Incarnation-Metadata-Experiments.md#two-mac-follow-up-measured-binding-and-intent-transport) expands the shared matrix to 125 verified outcomes, including concrete local-observation rules and deletion-intent transport; it does not establish portable binding for independent imports.

Run `check-uuid-experiments.py` as described in the [suite README](README.md). It runs combined safety baselines, each policy/property pair separately, liveness checks, deliberately false unreachability claims, and mutations of disposable source copies. Baselines also reject unexercised top-level actions. A timeout, parse/evaluation error, or wrong assertion failure is a failed experiment, never a proof.

Controls drop incoming checkpoint data, omit serialized/replayed aliases, bypass exact-current CAS, trust copied/false-positive association evidence, bypass publication fencing, drop a delete/edit preservation result, serialize an empty checkpoint, discard deferred inputs, and indefinitely stall an unknown-evidence decision. Each must fail its designated assertion. The false-positive-evidence control is particularly important: the conditional passing policy must fail if its supposed association proof lies.

The finite bounds keep these runs small; no state/depth constraint truncates exploration. One optional disturbance is sufficient to challenge captured input applicability, but is not an arbitrary-race proof. `UUIDAssociationLab` checks capture → decision → fenced publication → abstract local barrier → checkpoint install → reopen, plus rejection/deferral. It does not model a crash before every intermediate barrier. Deferred inputs remain owned in the model; permission to quit would require separately proven durable preservation, not merely a UI flag.

`UUIDAssignmentRace` checks old-UUID WAL recovery after both checkpoint closes, before modeled WAL cleanup. It does not establish torn-record recovery, exact LSN ordering, all crashes during alias migration, arbitrary host/file counts, or permanent host loss. Existing durability models retain their responsibilities but would need actual alias-bearing payload bridges after a protocol is selected.

No live Apple API tests were rerun for the initial UUID experiment. The subsequent [incarnation metadata experiments](Incarnation-Metadata-Experiments.md) add causal-state checks and local APFS/iCloud API probes without adopting a protocol. Any proposed new association/Trash protocol still needs two-Mac tests for independent import, copy, external safe save, offline restore, asymmetric delivery, and checkpoint/file ordering. Current API observations justify treating attributes as fallible evidence, not assuming a portable identity mechanism that has not been demonstrated.
