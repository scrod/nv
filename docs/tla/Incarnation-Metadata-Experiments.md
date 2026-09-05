# Incarnation metadata experiments

Status: experimental, 2026-09-04. These extend the [UUID reconciliation experiments](UUID-Reconciliation-Experiments.md); they do **not** adopt xattrs, aliases, causal deletion records, or an NV-managed Trash protocol into the spec or proposal #4.

## What would strengthen `stable`

Keep the live database UUID stable. Add evidence about **which lifetime and operation** a claim concerns, rather than repeatedly electing a new database UUID. Richer metadata helps reject stale claims; it does not make a copied file prove that it is the original.

| Candidate metadata | Useful property | Remaining condition |
| --- | --- | --- |
| Versioned collection/lineage namespace plus a fresh **birth/incarnation token** | Separates a logical note's lifetime from its local DB UUID. NV-created restoration gets a new birth; an old deletion targets only the old birth. | A copied token is still copied. Independent external imports still need association evidence before birth claims can be unified. A copied collection identifier is not proof of root continuity. |
| Revision envelope: birth, unique operation ID, parent revision(s), actual-body SHA-256 | Detects metadata left behind by an external content edit, duplicate operation delivery, and competing descendants of one known revision. | Hash agreement means compatible bytes, not identity or freshness. Equal-byte copies and same-body ABA changes can pass. Hash the exact represented encoding/bytes; a logical canonical-body hash is a different contract. |
| Causal context: live birth dots plus dots actually observed | Distinguishes "never observed" from "observed and removed"; stale additions do not undo an already-observed removal, while a fresh restoration survives. | Context must be durable, correctly scoped, and delivered. It cannot be reconstructed from the maximum timestamp in unrelated file metadata. |
| Explicit intent envelope: operation ID, `delete`, target birth(s), expected revision | Carries an explicit NV deletion claim instead of inferring intent from absence. Can accompany a proposed Trash entry or durable operation record. | Issuance/applicability still require validation. Unlinking the only file carrying it destroys the signal. Old/copied intent cannot authorize deleting another incarnation, or bypass the original expected-snapshot file-removal rule. |
| Independently queried local provider item/domain binding, optionally a host-local association record | Detects the tested local copy even when all xattrs are identical; helps preserve association through a positively established local continuity chain. | Must query the actual item, not trust an item ID copied inside its xattr. Missing/changed identity is inconclusive. The two-Mac follow-up found unequal cross-host IDs for the same synchronized file. |
| Typed ancestry: `copiedFrom` / `restoredFrom` versus `sameIncarnationAlias` | Preserves useful provenance without making every related file the same logical note. | A copy/restore edge must never enter equivalence-class union. The existing `aliasCopy` experiment rejects indiscriminate global alias joining; these edge encodings are not implemented. |

A small initial experiment could use one versioned envelope containing collection, birth, operation, parent, and body digest, with authoritative aliases and causal context in durable database/WAL state. Splitting identity and revision into separate attributes permits different preservation flags, but then their birth/schema references must agree. Neither representation makes body-plus-metadata publication or remote delivery atomic. Missing, malformed, mismatched, or stale metadata must remain unknown, preserving available inputs.

A more elaborate claim could carry `{replicaEpoch, proposedNoteUUID, birth, providerWitness}` for each participating host. Each host could check its own witness against the actual local item without assuming portable provider IDs. This can expose copied claims on a host that already has binding history, but a new host still cannot verify the remote witness merely by reading it. Claim sets also require merge/delivery rules. Keep this as a possible extension, not a new mandatory ledger in every file.

The following are **not** useful substitutes for independent binding:

- A signature/HMAC authenticates who issued a claim, not which physical copy currently carries it; a clone replays a valid signature unchanged. It would require an additional issuer/key-distribution threat model to justify the cost.
- A wall-clock timestamp or “larger counter wins” is not proof of causality. Replica identities/counters require durable, non-reused epochs; restoring an old Application Support backup must not reuse issued dots.
- A host-local seal stored only in a nonsyncable xattr is still cloneable locally. An external host-local record helps only where its own continuity is established.
- An expiring lease needs an actual authority and clock/fencing protocol. No consumer-side coordinated accessor provides a cross-Mac lease.

## Borrowing from replicated sets

Observed-remove sets associate each addition with a unique token and remove only tokens the operation observed. Causal summaries can replace per-removal tombstones, but contiguous vector summaries require the corresponding delivery/observation guarantees; out-of-order histories need exceptions. This is the relevant part of [the optimized OR-set design](https://arxiv.org/pdf/1210.3368), rather than simply attaching a deletion boolean to a UUID. [Dotted version vectors](https://arxiv.org/abs/1011.5808) similarly separate an individual event from its causal context.

Our bounded experiment uses explicit finite sets, not a production compact vector implementation:

```text
state = (live birth dots L, observed birth dots C)
merged live = (La ∩ Lb) ∪ (La − Cb) ∪ (Lb − Ca)
merged context = Ca ∪ Cb
```

Inference for NV: this could reduce ordinary per-deletion history if a complete collection-level causal state and correct replica epochs existed. A per-file maximum counter cannot summarize births on other files whose state was never received. A durable delivery/bootstrap/replica-retirement design would be new policy, not a free xattr optimization. Do not discard current durability obligations based on this experiment.

## Actual Apple API experiments

[`ICloudMetadataProbe.h`](../../tests/ICloudMetadataProbe.h) extends the existing contract harness, using its coordinated read, xattr, copy, rename, and Foundation replacement helpers. Synthetic files carry a small binary-plist envelope under six names generated by `xattr_name_with_flags`. It separately evaluates preservation intent and observes actual operations.

On macOS **26.6.2 arm64**, both a local APFS directory and the local iCloud Drive test directory produced:

| Operation | Observed attributes / body binding |
| --- | --- |
| `xattr_preserve_for_intent` for `SYNCABLE | ONLY_SAVING` (`#SX`) | Copy: no; save: yes; share: no; sync: yes; backup: yes. |
| `NSFileManager` copy | All six attributes copied, including `#SX`, `#X`, and `#NS`. Identical copied bodies passed the digest check. |
| Raw APFS `clonefile` | Same result: every attribute copied. |
| Foundation replacement, options `0`, no fresh staged xattr | Retained `#S`, `#SX`, `#PSX`, `#X`; dropped `#CS` and `#NS`. Retained envelopes failed the changed-body digest check. |
| `NSDataWritingAtomic` | All six attributes absent afterwards. |
| In-place content write | All six retained; every old envelope failed the changed-body digest check. |
| Rename | All retained; every body binding still valid. |
| Stage a fresh `#SX` or `#CS` envelope; Foundation replacement options `0` | The selected fresh staged envelope won and matched the new body. Other destination attributes followed the preservation behavior above. |
| Same staging with `UsingNewMetadataOnly` | Selected staged envelope matched; the other five destination attributes were absent. |

The flag result is **not a non-copyability guarantee**. Apple's [intent-policy implementation](https://github.com/apple-oss-distributions/copyfile/blob/main/xattr_flags.c) provides a decision to participating callers; our actual copy/clone results rule out relying on universal enforcement. Apple also documents [automatic APFS cloning by Foundation copy operations](https://developer.apple.com/documentation/foundation/about-apple-file-system). These observations do not establish a violation of Apple's API contracts. Finder's handling of these particular flag combinations was not tested.

Practical inference: `#SX` remains a plausible hint for an incarnation claim and `#CS` for a content-dependent revision claim. Neither flag replaces digest/association validation. Staging the intended value is promising, but these post-operation samples do not prove transient atomic visibility, crash durability, or the full metadata contract in [Foundation replacement migration](../Foundation-Safe-Replacement-Migration.md). Do not switch replacement options in production based on this test.

The iCloud source, Foundation copy, and raw clone had different positively returned provider item IDs despite identical xattrs. Re-inspecting the earlier fixture in a fresh process on this same Mac returned its original IDs. This is useful local evidence, **not** a claim that IDs are portable across Macs, or that this test established before/after identity continuity for every replacement operation.

### What can pass through File Provider APIs?

- Syncable custom xattrs are the available generic metadata channel. Apple's provider-side [`extendedAttributes`](https://developer.apple.com/documentation/fileprovider/nsfileprovideritemprotocol/extendedattributes) describes their projection, including metadata on dataless items and an approximately 32 KiB per-item syncable-attribute budget. Oversized attribute sets may have entries demoted to nonsyncable. Keep envelopes small; do not use them as unbounded alias or causal-history logs.
- `NSFileProviderItem.userInfo`, provider content/metadata versions, and [`requestModification`](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/requestmodification(of:foritemwithidentifier:options:completionhandler:)) are provider-side facilities, not a generic unrelated-consumer payload or remote compare-and-swap service. A persisted request is not evidence that the remote mutation finished.
- [`NSFileCoordinator.purposeIdentifier`](https://developer.apple.com/documentation/foundation/nsfilecoordinator/purposeidentifier) controls coordination relationships; it is not an NV delete-intent message delivered to the other Mac. A coordinated deletion by itself does not identify the user's originating application or intent remotely.
- There **is** an explicit custom consumer/provider channel: [`NSFileProviderService`](https://developer.apple.com/documentation/foundation/nsfileproviderservice). NV could define an idempotent `bind-if-unbound` or `delete-if-birth-matches` protocol, but a provider must implement and publish the agreed protocol. This could provide real authority if its server contract did so; NV cannot impose it on iCloud by naming a service.

The new read-only service probe successfully enumerated six iCloud services: CloudDocs sharing/BRItem/client-side collaboration/sharing operation, Messages collaboration, and iWork collaboration. Several explicitly contain `private` in their names. Enumeration establishes no supported identity/CAS protocol for NV. No XPC connection was opened, private protocol guessed, or service invoked. Outside a provider, enumeration returned an error; neither error nor an empty list proves permanent lack of capability.

## Model checks and counterexamples

[`CausalIncarnationSafety.tla`](CausalIncarnationSafety.tla) keeps two existing local UUIDs fixed and assumes their birth bindings are already valid. It explores local admission, independent last-writer publication and receipt, one crash/recovery, and separate capture/delivery steps for an explicit two-way exchange. It is **not** an executable composition proving `stable` acquires trustworthy birth bindings.

| Experiment | Result |
| --- | --- |
| Exact birth removal, fresh restoration, retained causal context | Exhaustive pass: 260 distinct states. An observed removal is not resurrected; a learned fresh birth is not lost; complete exchange agrees. |
| Independent unseen births / sparse context | Exhaustive pass: 209 distinct states. Both births survive exchange. |
| Delete by UUID-wide boolean | Counterexample: old deletion suppresses fresh restoration. |
| Drop removed dots from context | Counterexample: receiving stale state resurrects the old birth. |
| Treat publication to the current metadata register as sufficient to forget local durable state | Counterexample: another host overwrites the register; crash recovery loses deletion knowledge. |
| Compress a sparse context to its maximum observed counter | Counterexample: an unseen lower-numbered birth is incorrectly treated as removed. |
| Reuse birth on restore; remove every currently live birth; drop an exchange payload | Each mutation fails its designated resurrection, preservation, or agreement assertion. |

The **remove-every-birth** failure was found while constructing the model: a delayed old-incarnation deletion could erase an already-learned fresh restoration. The correction scopes the actual mutation to the captured birth, not just the initial lookup. The failing variant remains a regression control. Three reachability checks require actual preservation, unseen-birth merging, and recovery traces, so these properties are not passing solely because those situations cannot occur.

No fairness or arbitrary provider delivery is assumed in this model. `CompleteExchangeAgrees` applies after both actual captured replica states are delivered; it does not promise that iCloud performs that exchange. A last-writer metadata register is not a CRDT merge server. Local admissions are abstract already-durable operations; this does not prove WAL barriers, multi-xattr/body coherence, arbitrary host loss, text conflict preservation, or an external restore choosing a fresh birth.

Run only this addition with `check-uuid-experiments.py --only Causal ...`, or run the entire experiment matrix as described in the [TLA README](README.md). All **109** expected outcomes were verified: 31 exhaustive passing configurations, 50 rejected policy/property hypotheses, 14 reachability witnesses, and 14 mutation controls. The new addition contributes 12 checks; the previous 97 were rerun. No state/depth constraint truncates these finite explorations.

## Reproduction and remaining gaps

[Integration-test instructions](../IntegrationTests.md#exploratory-incarnation-metadata-probe) describe `metadata-probe` and read-only `metadata-inspect`. Both native and Intel harnesses compiled. `./build.sh` completed successfully (with existing Xcode environment warnings).

Run artifacts on this machine:

- TLC: `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/notation-tla-uuid-xmk2760u/results.json` and per-check logs/traces.
- Final local/API observations: `/tmp/nv-incarnation-metadata-local.log`, `/tmp/nv-incarnation-metadata-icloud.log`.
- Final peer-ready iCloud fixture: `API_Contract_Testing/nv-api-metadata-A9C6A0C5-911C-47AC-ACD8-B55D79EBB09C`. Earlier exploratory fixture `nv-api-metadata-CB28CA41-B68F-4550-A2D8-3FDBE531389B` also remains. These contain only synthetic bodies/metadata and are retained for peer inspection, not silently cleaned up.

The initial local-only run was blocked by the missing Intel SSH key and host resolution. The connection was restored later on 2026-09-04; the two-Mac follow-up below supersedes that limitation. Simultaneous body/metadata skew and real NV integration remain separate work.

## Two-Mac follow-up: measured binding and intent transport

The restored Mini runs macOS **14.8.9 x86_64**; the other Mac runs **26.6.2 arm64**. [`run-incarnation-experiments.py`](../../tests/run-incarnation-experiments.py) completed 23 lifecycle stages, with fresh observer processes on both hosts and exact synthetic body/xattr-digest comparisons before advancing. Separate corrected metadata runs covered both synchronization directions. This is a Foundation/File Provider harness, **not actual NV import, checkpoint, or WAL implementation testing**. Independent UUID assignment and crash recovery are modeled, not exercised by launching NV against the fixture.

### First finding: fix the test's attribute-name contract

The older runtime's `xattr_name_with_flags` omitted the unsupported `ONLY_SAVING` bit: the same source call generated `#SX` on 26 but `#S` on 14, `#PSX` versus `#PS`, and `#X` versus no suffix. The first peer inspection recomputed names locally and therefore queried different attributes. Direct inspection showed the original `#SX` attributes were present. Its missing-attribute conclusions were **test errors**, not provider failures.

The harness now serializes exact originating names in `origin.plist`, validates them, and queries those names on the peer. It rejects older manifests without names instead of guessing. The desired `ONLY_SAVING` intent behavior is observational on runtimes that omit the bit, not a failing Apple-contract assertion. Corrected fresh fixtures confirmed:

- All five syncable source attributes, including the exact `#SX`/`#PSX` names created on 26, arrived with equal bytes on 14. The reverse run likewise preserved its exact five syncable names. Nonsyncable local-seal attributes did not arrive.
- The fresh staged incarnation/revision values arrived and matched the corresponding new bodies. This is converged endpoint evidence, not proof of intermediate body/metadata atomicity.
- `#NS` also traveled with sync despite the intent evaluator's never-preserve result. Preserve-for-copy/save intent evaluation is not a universal transport enforcement mechanism.

**Design consequence:** a protocol must specify an exact, OS-independent attribute name. Do not let runtime support for optional preservation flags silently choose different identity keys on different Macs. A fixed versioned `#S` name is the simplest candidate; this remains exploratory, not adopted policy.

### What changed—and did not change—during the lifecycle

| Controlled operation | Observed identity / metadata |
| --- | --- |
| Same synchronized file on the two Macs | Both the opaque item and domain values differed across hosts. Simple portable equality is disproved for this setup. |
| Fresh process, rename from A, rename back from B | Each host retained its own item identity. |
| Fresh staged safe save from A, then B | Each host retained its own item identity; changed body and `#S` envelope converged. |
| Foundation copy preserving metadata | A separate item identity on each host; copied body and envelope equal to the source. |
| Eviction/rematerialization on the Mini | Eviction was positively observed. The `#S` envelope and provider identity remained readable while status stayed `NotDownloaded`; rematerialization restored the body and retained the local identity. |
| Move to the synthetic `Trash` subdirectory, then move back on B | Each host retained its original item identity and unchanged birth/revision claim. Neither is a fresh-birth signal. |
| External deletion after moving back | The original standalone intent record still existed. Its presence did not identify this later disappearance as a new NV delete command. |
| Unlink, then restore an attribute-identical backup | New provider item identity on each host, but the original body and envelope returned byte-for-byte. A matching claim alone cannot establish lifetime continuity. |
| Explicit fresh-birth safe replacement | New metadata claim with unchanged local provider item identity. Provider identity and logical birth are independently varying concepts. |
| Generic atomic content replacement | Local provider identity retained; `#S` claim absent afterwards. Missing metadata alone is not proof of a different note. |

Both a standalone intent-before-move schedule and a source-absence-before-intent schedule were observed. The latter deliberately withheld the intent write until the peer had observed absence, using a retained exact original snapshot to create the later synthetic record. These demonstrate controlled transport orders, **not** an assertion that a single provider rename spontaneously reordered its endpoints. No account-wide synchronization was paused, no machine rebooted, and no historical provider version was resolved or removed.

Only generated note files/intent files were unlinked; original synthetic backups remain under each test session. The test Trash is an ordinary subdirectory, not Finder's system Trash or an adopted NV feature.

### Concrete rule experiment and its limit

`UUIDAssociationLab` now has a `currentSnapshot` rule that does not read `proof` or ground truth. It compares positive item IDs only when both inputs belong to one scope-qualified, contemporaneous local observation frame; otherwise it defers. A remote checkpoint's stored claim cannot present itself as such a frame. Frame validation is an input obligation of the existing coordinated-catalog/root/model fences, not a new Apple cross-host guarantee.

The rule reaches real join, separation, checkpoint/reopen, and deferred-independent-import traces in the bounded model. The competing `providerEquality` rule incorrectly separates the same file's independent imports. Removing frame qualification and trusting a replayed claim incorrectly joins a copy. Existing UUID/xattr authority hypotheses continue to fail their designated controls.

This is **not a completed cross-machine alias protocol**: `currentSnapshot` explicitly cannot bind two independent cross-host imports, and its unknown outcome remains data-preserving deferral. The added same-local-snapshot fixture raises the lab to 24 fixtures. Existing `stable` checkpoint/WAL tests still have their conditional binding premise. We did not disguise the failed prerequisite by claiming a composed end-to-end convergence proof. A portable binding mechanism or explicit user-confirmed association remains a policy/design prerequisite for that composition.

### Deletion-intent transport model

[`DeletionIntentTransportSafety`](DeletionIntentTransportSafety.tla) independently delivers source absence and a genuine, already-bound intent artifact. The artifact can represent a Trash entry or a standalone record. Capture, local receipt barrier, artifact purge, fresh restoration, application, crash, and recovery are separate actions. It assumes correct birth binding; it does not use an old provider identity to manufacture that binding.

The guarded rule retains an accepted receipt locally and applies it only to the matching birth while the source is absent. It preserves a learned fresh restoration, survives the modeled crash, and never treats unexplained absence as deletion. Controls expose forgetting an accepted receipt when its remote artifact disappears, applying an old receipt to a new birth, losing the receipt on crash, and deleting on absence alone. A witness also reaches artifact purge **before any capture**: neither an ordinary Trash directory nor a deletable intent file guarantees eventual knowledge of every deletion.

The model therefore does not select between Trash and a record merely on safety grounds. Either needs an explicit retention/acknowledgment/bootstrap policy if guaranteed eventual intentional-deletion recognition is required. Receipt garbage collection is unmodeled; local barriers abstract successful durability and do not prove the implementation's byte-level WAL behavior.

### Follow-up verification and artifacts

The retained follow-up's 16 added checks passed. Its combined baselines visited 396 states (`currentSnapshot`) and 192 states (intent transport), with no depth/state truncation. These are exhaustive finite-model checks, not unbounded proofs. Historical aggregate counts including retired models are recorded only in the archive. Both harness architectures compiled and `./build.sh` succeeded, with Xcode environment warnings.

- Lifecycle: `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-binding-results-v5b01teb/results.json`, `calls.jsonl`, and `eviction.txt`.
- Final lifecycle fixture: `API_Contract_Testing/nv-api-binding-FAD82BE6-C39C-484A-8FE3-11747F429B0B`; preliminary 16-stage fixture: `nv-api-binding-B0741F66-E3A5-4F82-9B8C-F3B22E531EB2`.
- Corrected bidirectional metadata logs: `/tmp/nv-metadata-exact-A.log`, `/tmp/nv-metadata-exact-A-on-B.log`, `/tmp/nv-metadata-exact-B.log`, `/tmp/nv-metadata-exact-B-on-A.log`. Exact-name fixtures: `nv-api-metadata-B19CDBCD-2B79-4458-AEB2-E5753BC951CF` and `nv-api-metadata-C933CCD3-A6A4-4ABA-ADF9-A024896EAB9C`.
- Final TLC run: `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/notation-tla-uuid-52kl1fer`.
- Intel harness: `/tmp/nv-incarnation.0pYC2L/ICloudAPIContractTest` on the Mini. Fixtures and logs are retained; no automatic broad cleanup runs.
