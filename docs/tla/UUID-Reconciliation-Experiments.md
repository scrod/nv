# File-association experiments

Status: retained investigation, **not adopted product policy**. The active import policy is defined by [Protocol](../impl-proposal-5/Protocol.md#current-file-decision-matrix) and checked by the external-import models. Do not apply this older lab's blanket unknown-evidence deferral to ordinary eligible imports.

## Scope and evidence

Choosing a common logical UUID is different from establishing common physical-file identity. Copies, stripped attributes and restores can expose identical inputs while requiring different classifications. This report retains those counterexamples and their conditional evidence requirements, not an alternative storage protocol.

[`NoteObject.m`](../../NoteObject.m) allocates ordinary note identities independently. [Apple contract observations](../Apple-API-Contract-Validation.md) show why copied, absent or delayed xattrs are fallible evidence; they do not supply cross-host identity or a portable historical version key. The adopted spec uses committed birth identity and causal Delete, preserving independent imports where their relationship cannot be established.

## Association, copies, deletion intent, and restoration

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

These are isolated rule hypotheses, not a claim that today's implementation applies each rule or can produce every hypothetical UUID/xattr combination. The lab exercises proposed xattr/alias protocols that are not implemented; its conditional passing rule is not the current import classifier.

### Indistinguishable histories

The model checks that these pairs expose identical complete decision inputs but different required classifications:

- Two imports sharing a tag, versus a copied tag on a different file that was assigned another local DB UUID.
- A safe-save replacement that stripped the tag, versus a newly created, unrelated file with the same name/body and no tag.
- An old Trash entry followed by restoration and another unexplained disappearance, versus intentional deletion of the original incarnation. Copying the incarnation attribute does not distinguish them.
- A complete competing checkpoint that never contained the note, versus a checkpoint whose writer intentionally deleted it. A receiver's base membership plus the incoming checkpoint's omission does not establish that incoming branch's ancestry.
- A real intentional deletion whose Trash evidence has been purged before observation, versus unexplained external disappearance.

This fixture-equality assertion is a sanity check on the indistinguishability construction, not a separately deep safety proof. Its consequence is information-theoretic: a deterministic decision function receiving equal observations returns equal decisions. When the correct automatic answers differ, at least one answer is wrong unless additional evidence or an unresolved state is allowed. Random tie-breaking cannot provide an all-behaviors safety guarantee either.

Trash-first delivery keeps the still-visible source. Source-absence-first delivery without corresponding intent evidence defers. Restored/new incarnations cannot inherit an old incarnation's deletion authority. None of these actions physically unlinks a current file; the original expected-snapshot removal rule remains a separate constraint.


## Verification and limits

Run `python3 docs/tla/check-uuid-experiments.py --only UUIDAssociationLab --java /path/to/java --jar /path/to/tla2tools.jar`. This selects 46 existing cases: conditional baselines, rule/property comparisons, reachability witnesses and mutations. Expected counterexamples reject rules or establish reachability; timeouts, parse failures and unrelated assertion failures never pass. Source models are unchanged by the archive move.

The lab uses capture → decision → fenced publication → abstract local barrier → summary installation → reopen, plus rejection/deferral. Its field named `checkpoint` is an experimental local summary, not proof of the adopted segment/cache implementation. One optional disturbance is not arbitrary-race coverage; retained volatile inputs are not a real durable pending-file buffer. Positive `proof` inputs are assumptions, never outputs inferred from copied metadata. False-positive-proof and dropped-input controls must still fail.

Current independent-import/late-history behavior is checked by [ExternalImportAdmissionLab](ExternalImportAdmissionLab.tla); actual file-observation and pending-byte durability remain separate implementation obligations. The [metadata follow-up](Incarnation-Metadata-Experiments.md) and [protocol combinations](Protocol-Combination-Experiments.md) retain related investigative boundaries. No universal automatic association, alias garbage collection or provider identity guarantee has been established.
