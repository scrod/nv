# Binding, intent, and retirement combinations

Status: experimental, 2026-09-04. No xattr, alias, shared operation record,
handshake, or membership policy is adopted by this report. The normative
specification, ADR-0013/0014, and proposal #4 remain unchanged.

## Decision result

No tested combination simultaneously provides automatic independent-import
binding, correct handling of every externally restored copy, offline progress,
and history retirement without a bootstrap obligation. This is not a claim
that every possible protocol has been exhausted. It is a comparison of the
explicit finite policies below, including concrete indistinguishable histories.

The smallest useful **conditional** combination is:

1. Preserve local note UUIDs and scope associations to an established incarnation.
2. Carry sparse explicit deletion/restoration operations independently of the file.
3. Retain a durable sender outbox until a durable recipient acknowledgment;
   retain the recipient's applied/superseded disposition through recovery.
4. Give positively identified restorations fresh birth tokens.
5. Revalidate the live generation at publication and preserve concurrent edited inputs.
6. Preserve/edit unbound notes normally; do not turn a guessed association into
   deletion authority.

Fresh, fenced handshakes can increase automation in a restricted environment,
but do not remove the need for item 6. They add three metadata publications and
their observations, require a successful exchange, and still fail the explicit
relay and unobserved-restoration ceilings. Consequently they are an optional
binding aid to investigate, not the core of the minimal deletion design.

The existing body-merge and exact-snapshot file-removal protections remain
necessary. None of these experiments gives a later intent record authority to
unlink a same-named or same-UUID current file.

## What was compared

| Combination/change | Result in the named bounded environment | Trade-off or failure |
| --- | --- | --- |
| Static copied tag supplies association | Rejected | Joins an independent copy; its deletion can then remove the wrong logical note. |
| Challenge exchange with reused attempt nonce | Rejected | A copied old transcript satisfies a new attempt. |
| Fresh exchange without final local endpoint fence | Rejected | Copy/reassociation after observing the acknowledgment can publish a stale alias. |
| Fresh exchange plus final local endpoint fence | Safe for clean, static-copy, and one-copy/reassociation scenarios; clean conditional progress passes | Copy and offline cases may park. Three explicit metadata transplants can relay a valid fresh exchange between distinct files. |
| Fenced binding + durable outbox/receipt/disposition + fresh restore birth + generation fence + edit preservation (`guarded`) | All combined safety assertions pass for the ordinary lifecycle, static-copy, one-retarget, and offline-binding scenarios | Still rejects neither a fully relayed binding nor an entirely unobserved same-metadata restoration. |
| Remove fresh birth on a known restoration | Rejected | An unconsumed old deletion can target the restoration. |
| Keep acknowledgment but lose its receipt on crash | Rejected | The sender may have retired its outbox while the receiver forgot the operation. |
| Clean up the outbox because a local note checkpoint succeeded | Rejected | Local note coverage does not prove remote receipt. |
| A deletable Trash/intent artifact with no retained republishing source | Safety can pass; receipt progress fails | Purge before receipt loses the only delivered signal. |
| Remove publication-generation revalidation | Rejected | A prepared deletion overwrites intervening restoration. |
| Remove concurrent-edit preservation | Rejected | An already-durable edited input disappears. |
| Always defer binding | Safety can pass; automatic application progress fails | It is not scored as a complete solution. A witness confirms ordinary editing still works while unbound. |
| Maximum received operation number is a complete acknowledgment | Rejected | Receiving operation 2 does not imply receipt of operation 1. |
| Delete history after existing replicas acknowledge, without a snapshot | Rejected | A new replica or restored backup lacks the retired history. |
| Retain records or a snapshot, but allow an old backup to publish immediately | Rejected | Available recovery data does not help if replay is permitted before it is loaded. |
| Retained complete snapshot + explicit pinned-bootstrap/rejoin gate | Conditional retirement checks pass, including rejection of stale reads | Requires a correctly selected snapshot reference outside the stale backup. The model does not produce that authority or bound the snapshot's asymptotic size. |

These are mechanism comparisons/ablations, not a Cartesian search over every
possible encoding. "Fewest trade-offs" is a product judgment, not a TLC property.
No state, depth, timeout, or always-defer shortcut is counted as an exhaustive pass.

## Models and composition boundaries

### `LiveBindingHandshake`

Two hosts, two transport items, one fresh attempt, and a retained old transcript.
Publication offers and local observation are separate actions. Safety allows
arbitrary replay of offered metadata; packets never spontaneously cross items.
The receiver compares only its own positive local handle with its captured
handle. Hidden item numbers route delivery and supply assertion ground truth;
they are not compared as portable provider IDs.

The retarget scenario can copy/reassociate after any protocol step, including
between acknowledgment observation and alias publication. The relay scenario
explicitly copies challenge, response, and acknowledgment metadata across the
two items. It requires three external transfers, not one ordinary Finder copy.
The old-transcript scenario and the static-copy scenario share the same copied
starting data; different nonce policies are tested without counting duplicate
positive configurations as additional coverage.

Progress uses a separate stable-endpoint, eventual-latest-delivery environment.
The ordering used to select that model's latest packet is attempt/stage order,
not an ordering on real random UUIDs. No unconditional iCloud delivery,
simultaneous online presence, or retry-after-process-crash guarantee is proved.

### `BindingIntentComposition`

This module instantiates the **actual handshake transition system**. Its
accepted/parked output drives alias admission; there is no `proof = same` input.
After projection, unused message history is discarded to avoid multiplying
every lifecycle state by irrelevant handshake snapshots.

The second phase covers a sender's explicit birth-1 deletion and a receiver's
separate import UUID, alias/WAL settlement, independent artifact/absence
visibility, one artifact purge, durable acknowledgment, outbox release, one
local edit, one known restoration, one receiver crash, and repeated delivery.
Capture, publication, note barrier, receipt barrier, and checkpoint are separate.
Durably acknowledged edits must remain either live or preserved. A durable
alias must survive recovery. No external disappearance creates an intent.

The `hiddenRestore` negative environment changes only assertion provenance:
an external delete/restore cycle returns the same observable metadata before NV
sees it. Even the generation fence cannot detect that history. This intentionally
tests the stronger desired restoration semantics; it does not assert that an
Apple API should reveal the invisible transition.

Important exclusions:

- Binding and lifecycle execution are phased, not fully interleaved. This is a
  real output-to-input bridge, not a proof of concurrent binding and deletion.
- The checkpoint action is a local covering-checkpoint abstraction. It is not
  proposal #4's competing-checkpoint CAS/three-input merge. Existing checkpoint
  models and `UUIDAssignmentRace` retain that separate coverage; the full
  alias-bearing checkpoint/recovery implementation is not proved by combining
  their test counts.
- One modeled receipt/operation is not a general exactly-once delivery service.
- No receiver action removes a physical file. Current-file replacement and
  removal retain their existing separate model/API obligations.
- Barriers abstract successful local durability, not byte codecs, fsync behavior,
  complete process recovery, or every crash point in an implementation.

### `IntentRetirementLab`

Two immutable intent operations can arrive out of order. Receipt and durable
acknowledgment are distinct; an assertion-only history distinguishes an invalid
initial acknowledgment from a later stale-backup rollback. Snapshot preparation
and installation are separate. Collection, newcomer bootstrap, backup restore,
and rejoin are independent actions.

The pinned-snapshot candidate assumes an explicitly selected immutable snapshot
reference with complete required context. A stale snapshot is rejected; it does
not become current because a retry ran or because it has a valid hash. Obtaining
that reference, membership/retirement agreement, and behavior while it remains
unavailable are unresolved protocol/product obligations. This model retains
finite event sets in its snapshot: it demonstrates safe retirement of separate
records, **not** an implementation of bounded vector compression or bounded
total metadata for arbitrarily many replicas/operations.

## Practical compiled check

The existing Objective-C harness gained `challenge`, `reply`, `ack`, and `relay`
actions within generated `nv-api-binding-` fixtures. They use the fixed `#S`
name, fresh random nonces, body-bound synthetic metadata, and public coordinated
xattr access. Relay requires an existing equal-body test target and never
changes either file's body. This is a primitive/transport probe, not a production
implementation of the complete binding protocol.

Two initial attempts timed out before their new fixtures appeared on the Mini.
SSH worked; the origin reported uploaded with no upload error. Those bounded
attempts were inconclusive, not Apple API violations. A later fixture prepared
on the Mini arrived here, and using that fixture **completed all 11 stages
across macOS 14.8.9 and 26.6.2**. No fixture bytes were transported through SSH;
SSH only invoked the test process. The user's later Finder screenshot also
showed both earlier timeout fixtures, with no visible sync warning.

At every successful stage, separately observed body and metadata digests
matched across hosts. Both the ordinary exchange and the explicitly relayed
exchange completed. Source and copy kept their distinct local provider
identities on **each** Mac throughout the relays; item/domain values for the
same synchronized file differed across hosts. The nonce log confirms a fresh
second challenge and reply, not reuse of the first completed transcript.
This confirms the relay primitives are practical across these two Macs; it
does not establish their frequency in ordinary workflows, a portable identity
contract, or a guaranteed delivery deadline. It does not mean iCloud itself
spontaneously routed metadata to the wrong file.

A separately labeled same-Mac run using fresh observer processes also
completed all 11 stages. It remains separate evidence, not the basis for the
cross-Mac result.

No production note, account-wide synchronization state, or Apple historical
version was changed. New fixtures and logs were retained; this run deleted no
test files.

## Reproduction and results

Use the existing runner from [README](README.md):

```sh
python3 docs/tla/check-uuid-experiments.py --java /path/to/java --jar /path/to/tla2tools.jar
```

Selectors: `--only LiveBinding`, `--only BindingIntent`, or
`--only IntentRetirement`. Every expected counterexample must violate its named
assertion; parse failures, unrelated failures, and timeouts are errors.
Reachability checks exercise binding, parked editing, actual preserved edits,
recovery, replay, retirement, rejoin, and stale-snapshot rejection. Mutations
remove endpoint/nonce fences, recovered aliases, bootstrap validation, and the
rejoin gate without changing their assertions.

The addition contains 58 checks across three models. All 183 expected outcomes
in the shared experimental matrix were verified, including the preceding 125
regressions: 49 exhaustive passes, 76 rejected hypotheses/properties, 36
reachability witnesses, and 22 mutation controls. After making the handshake's
local-handle/hidden-item distinction explicit, all 43 affected handshake and
composition checks were rerun successfully. Representative exhaustive
state counts are 19,952 (handshake/retarget), 23,052 (combined ordinary lifecycle),
46,479 (combined retarget), and 407 (retirement with stale reads). No exploration
is cut off by a state/depth constraint.

- Full matrix: `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/notation-tla-uuid-av3ujy18`.
- Final 43-check local-handle clarification rerun: `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/notation-tla-uuid-ycjvr20r`.
- Failed two-Mac fixture delivery: `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-binding-results-oc6p312f/calls.jsonl`.
- Second fixture-delivery timeout: `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-binding-results-zljygjal/calls.jsonl`.
- Successful two-Mac nonce/relay run: `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-binding-results-y1loclsg/results.json` and `calls.jsonl` (`localOnly: false`).
- Successful same-Mac nonce/relay run: `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-binding-results-0lkjyrua/results.json` and `calls.jsonl`.
- iCloud fixtures: `nv-api-binding-966E658E-3DBD-4552-9BBD-E2005996C847` and `nv-api-binding-B951FAAD-4783-4E94-91EF-8D3D2EE43EE7` (initial delivery timeouts), `nv-api-binding-83A69745-9FD8-431C-9D6F-25C415D20FB9` (same-Mac run), and `nv-api-binding-EB137339-1579-4A94-A67E-90DC7B5EF349` (completed two-Mac run).
- Intel test binary: `/tmp/nv-handshake.fPthud/ICloudAPIContractTest` on the Mini.

Both Objective-C harness architectures compiled; `./build.sh` succeeded with
the existing Xcode environment warnings. See [IntegrationTests](../IntegrationTests.md)
for the practical runner. No new dependency was added.
