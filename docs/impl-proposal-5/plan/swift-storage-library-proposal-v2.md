# Cross-platform Swift storage library — proposal v2

**Status:** proposed implementation architecture, not an adopted wire-format change or a claim of implementation completion.  
**Date:** 2026-09-09.  
**Basis:** the adopted proposal-5 specification, format checklist, vocabulary, verification coverage map, and companion conformance strategy. [P1–P6]

Aligned with the current specification on 2026-09-10. Follow the [phased implementation/testing plan](swift-storage-implementation-plan.md) for sequencing. Canonical definitions are written directly in Swift without CUE or code generation. This document supplies the portable library's architectural rationale; it does not change product semantics or claim completed implementation.

## Summary

Implement the new storage engine as a cross-platform Swift package while retaining the existing application’s live in-memory store, synchronous search, admission behavior, and AppKit integration. Concentrate the strongest enforcement at the boundaries where a value becomes suitable for a new use: interpreting bytes, assigning identity, resolving history, acknowledging durability, publishing into the live model, and performing filesystem effects.

The organizing principle is:

> **Types constrain which evidence a call must receive. Constructors and validators establish that evidence. Runtime fences establish its current applicability. Model checks explore abstract interleavings. Concrete tests exercise the implementation and operating system.**

No one layer substitutes for the others. In particular, a type called `AcceptedHistoryReceipt` does not prove that its issuer called the right filesystem barriers, and a passing kill-process test does not establish power-loss behavior. The project’s coverage map already distinguishes bounded model checking from implementation refinement and OS evidence. [P5]

The most important changes from the earlier proposal are:

| Area | Revised recommendation |
|---|---|
| Validation stages | Use named evidence and capability types, not one universal linear `Segment<State>` progression. |
| Identity | Distinguish a referenced/claimed identifier from an object whose identifier was recomputed and matched. Missing dependencies must remain nameable. |
| Graphs | Give causal parents, note predecessors, scope frontiers, and compensation targets different nominal types. Bind graph-derived facts to their exact evaluation context. |
| Concurrency | Use Swift 6 checking, but retain explicit in-flight state, non-suspending decisions, generation fences, and separate blocking-I/O execution. Actors are not transactions. |
| Parser | Avoid committing to a long-lived parser fork. A small bounded cursor is a viable baseline; a narrowly adapted `BinaryParsing` remains an alternative after a compatibility probe. |
| Canonical encoding | Define canonical values and encodings directly in Swift; keep semantic identity separate from transport-reference encoding. |
| Automatic enforcement | Add compile-fail tests, exhaustive limit-fixture mappings, independent layout/field-participation checks, deterministic implementation simulation, and assertion-specific mutation controls. |
| Verification independence | Literal expected bytes and independent semantic expectations must not be derived by the production encoder/reducer under test. |
| Platform support | Separate portable protocol conformance from each platform’s qualified filesystem, credential, and document-import behavior. |

No estimate of parser size, percentage of safety retained, or proportion of prose rules converted to compile errors is a measured project result. The model coverage and conformance strategy identify concrete boundary failures to challenge, not a statistical ranking of implementation bug classes. [P4, P5]

## 1. Scope, authority, and package boundaries

This proposal changes implementation organization, not the meaning of retained history. Keep immutable segments, the retained-history pin, independent local and provider progress, full action-group atomicity, and the distinction between Current’s represented revisions and the applied causal frontier. Keep epoch-4 opening/recovery/export on its existing compatibility path. The adopted private SQLite database stores local history, required state and derived current rows; it is never provider transport. Do not introduce a mutable shared head, second application WAL, provider acknowledgment registry, history pruning, or new synchronization authority. [P1, P2]

Adopting a substantial Swift core would explicitly supersede the earlier implementation-only instruction to add merely a narrow CryptoKit bridge. It does not authorize converting the application to SwiftUI, moving live search onto a worker, or rewriting native editing/undo behavior. Those remain separate integration boundaries. [P2, P6]

Use a small number of production targets. The following is a starting organization, not a requirement to create a package for every abstraction:

```text
NVStorageCore
    nominal identities and exact byte values
    bounded codecs and canonical identity encoding
    structural and graph validators
    pure history, merge, deletion, and undo reducers
    narrow cryptographic/normalization value operations

NVStorageRuntime
    local-store and repository coordination
    explicit operation phases and effect completion
    immutable installation, private-state commit, recovery
    platform-specific filesystem adapters

NVStorageApple
    existing rooted-helper integration
    provider coordination, presenters, and observation conversion
    Keychain, bookmarks, legacy import/export boundary
    Objective-C / main-actor application bridge

TestSupport — never a production dependency
    virtual filesystem, deterministic event scheduler
    fixture import, reference-oracle adapters, fault injection
```

Keep dependencies acyclic. Co-locate a proof type and its issuing validator when necessary; do not solve a target-dependency problem by adding a public unchecked initializer. Separate subtargets later only when they create a useful, enforceable dependency boundary.

“Pure reducer” means a deterministic function of explicit values, without filesystem access, implicit clocks, random allocation, or provider callbacks. Swift does not automatically prove that purity. Enforce the intended boundary through restricted dependencies, narrow inputs, source checks, and deterministic tests—not by presenting `Sendable` as an effect system.

**Portability has two levels.** Byte encoding, identity, graph interpretation, merge behavior, and undo selection should be identical across platforms. Writable storage additionally requires an OS adapter that satisfies the relevant root-ownership and durability contract. A platform without a qualified adapter must not silently simulate those guarantees with weaker operations. Windows support, Linux metadata conventions, and non-Darwin equivalents to directory locking require explicit qualification; “builds on that OS” is not the qualification.

## 2. Compiler enforcement and the trusted boundary

Use **Swift 6 language mode** for new first-party Swift targets. Swift 6 enables full data-race checking; it does not eliminate logical races across suspension points or verify external code. [S1]

Add **strict memory-safety checking** on a pinned toolchain that supports it. Swift’s SE-0458, implemented in Swift 6.2, adds `-strict-memory-safety` and diagnostics that can be escalated with `-Werror StrictMemorySafety`. The mode identifies unsafe constructs; an `unsafe` acknowledgment is an audit marker, not a proof of correctness. [S2]

The package now requires Swift 6.4 or newer, explicitly selects Swift 6 language
mode, and enables strict memory-safety checking with warnings as errors for Core
and Runtime using typed SwiftPM settings. The
[qualification report](swift64-platform-qualification.md) inventories the audited
C/crypto/executor boundaries and exercises the actual issuer and consumer code.
The macOS 11.5 library deployment target remains separately qualified.

Proposed build rules:

- Core targets have no unexplained `@unchecked Sendable`, `nonisolated(unsafe)`, unchecked casts, or arbitrary pointer manipulation. Necessary C/OS interoperation is confined to named adapters with an inventory of assumptions and tests.
- Reject safety-disabling release flags, particularly `-Ounchecked`, disabled exclusivity, and access-control bypasses. Test the optimized build as well as the debug build.
- Do not satisfy warnings by globally adding `@preconcurrency` or broad unchecked conformances. Record narrowly necessary compatibility exceptions and prevent their spread through CI.

Keep compiler version, Swift language mode, SDK version, and deployment target separate. A recent compiler feature does not automatically require the corresponding recent macOS release, but a library API may do so. Pin the selected toolchain and dependency revisions, then build and run a representative executable on macOS 11.5 before claiming that deployment target. The reported isolated Linux compiler probes do not establish Darwin backdeployment.

### Access control is part of the argument

A nominal wrapper only carries a useful guarantee when its construction and mutation paths are controlled. Hide stored representation, suppress unchecked/memberwise construction, and put the issuing factory in the narrowest practical scope. Do not give proof or authority types synthesized `Decodable`, public raw-value constructors, permissive setters, or “test convenience” factories in production.

`internal` means the whole module can use the declaration; it is not an issuer-only boundary. Use private/file-private construction where appropriate and explicitly identify any larger trusted module. Swift’s access controls are documented language boundaries, not protection against malicious code using unsafe memory operations. [S3]

Test the public boundary from a separate client target without `@testable import`. Use normal unit tests for internal algorithms, but do not let an internal testing shortcut become the only route by which tests obtain validated values.

The [storage review implementation](storage-review-follow-up.md) applies this
boundary to `RetainedGraph`: checked store reads issue complete prefixes and a
graph's causal-cut method issues complete subgraphs. Current values carry one
`CurrentNoteProvenanceV1` variant, and reducer routing switches exhaustively over
supported action/effect cases. Independent bytes and ordinary/same-module
construction probes qualify these representations.

## 3. Parser choice: borrow the safety model, not necessarily the package

Treat parser maintenance and runtime availability as separate questions. The guidance cited in the original revision describes core `Span` backdeployment separately from `UTF8Span` and individual convenience APIs; the inspected package manifest then required macOS 13. Recheck the selected revision and actual 11.5 binary rather than treating either statement as a present compatibility certificate. **`Span` alone is not evidence that an 11.5 adaptation requires replacing the package with `ArraySlice`**. [S4, S5]

The revised decision is to avoid an unbounded fork, not to assume that a hand-written parser is inherently safer:

| Candidate | Acceptance condition |
|---|---|
| Pinned upstream `BinaryParsing`, with a narrow compatibility adaptation | Actual 11.5 build/run evidence; supported API subset; small documented delta; upstream update procedure; no weakening of lifetime/bounds checks. |
| Small first-party bounded cursor over owned bytes | Minimal primitive surface; checked arithmetic; exact subrecord bounds; complete-consumption checks; malformed-input corpus and fuzzing; measured allocation/performance. |
| Reimplementation of the entire upstream API | Do not pursue merely to preserve a package name or an earlier recommendation. |

A small bounded cursor is the provisional low-dependency baseline. A short compatibility experiment can replace that choice if an upstream-compatible adaptation is materially cheaper to maintain. Do not claim a fixed line count or safety percentage before implementing and testing the representative records.

The cursor should expose fixed-width integer reads, checked byte extraction, bounded subreaders, and exact completion. It should not become a general parser-combinator framework.

### Required byte-handling invariants

Acquire a bounded immutable byte snapshot before decoding, hashing, and authentication. The bytes verified must be the bytes later interpreted. Do not authenticate one view of a mutable/mapped source and decode another. A transport read should enforce the outer object cap while reading, not only after an unbounded allocation.

For every untrusted length, check wire-to-index conversion, the applicable protocol limit, and the remaining input before indexing or allocating. Check multiplication for counted fixed-width records. Prefer comparisons against remaining length to unchecked `offset + length`. `ArraySlice` indices need not begin at zero; account for its actual bounds. Avoid retaining a whole large source buffer accidentally through a tiny long-lived slice.

Every nested record gets its own bounded reader and must consume it completely. Reject duplicate IDs, invalid ordering, forward references, and trailing bytes where the grammar prohibits them. Failed parsing must produce a typed result, not trigger an input-dependent `precondition`, force unwrap, or out-of-range access.

Swift’s checked collections prevent many forms of undefined memory access; a process-terminating bounds trap is nevertheless a decoder defect for malformed external data. Resource exhaustion is another distinct concern. These require explicit checks and runtime tests, regardless of parser choice.

## 4. Strong domain types and identity evidence

Retain distinct nominal types for `CollectionID`, `LocalStoreID`, `WriterEpoch`, `ActionOriginID`, `ActionID`, `NoteBirth`, `OperationID`, and `SegmentID`. Distinguish byte counts, operation indices, display dates, local generations, and protocol sequence numbers when confusing them could change behavior. No ordinary `UUID` or generic digest parameter should erase those roles. [P2, P3]

Use enums for operation variants, content formats, note-state references, and mutually exclusive compensation kinds. A complete action record should not be a bag of optional `undoOf`, `redoOf`, and unrelated fields whose invalid combinations are accepted until much later.

### Computed object identity is not the same as a reference to an object

Compute and check identity for **identified objects**, with a necessary distinction:

| Value | Permitted source | What it establishes |
|---|---|---|
| `OperationReference` / referenced operation ID | Bounded decoding of a digest token | A claim that names evidence, which may not yet be available. |
| `SegmentLocator` | Validated widths, scalar ranges, and grammar | A safe-to-render object name, not proof that the named bytes exist or authenticate. |
| `IdentifiedOperation` | Canonical semantic encoding plus hash computation; comparison with any asserted ID | The object’s computed identity. It is not yet proof of complete graph validity. |
| `HashCheckedEnvelope` | Hash of the exact complete envelope matched to the requested identity where one exists | Exact byte identity, not necessarily authenticity, semantic validity, or durability. |

Reject an asserted/computed mismatch with a typed `identityMismatch`. Reject contradictory action identity or object claims with the appropriate integrity classification. Keep nominal reference IDs usable for fetching missing parents: a policy that allowed **no ID value until the referenced object was present** would prevent representing incomplete dependency closure.

Random IDs are different again. Collection IDs, action IDs, ordinary births, and writer epochs are allocated, not computed from a content digest. Deterministic recovery births retain their specified hash-domain and slot rules. Do not redesign those identities under one generic “hashed ID” API. [P2]

Hash construction does not verify that the correct fields or domain separator were hashed. That remains the canonical encoder’s obligation. A reference to the wrong compensation target can also be a perfectly valid hash: graph meaning still needs validation.

## 5. Canonical values and encoding directly in Swift

Maintain separate, explicit definitions for **semantic identity encoding** and **transport encoding**. An external locator or backward intra-segment index is a transport representation; operation hashing expands these references to canonical operation IDs. Hashing the segment payload directly would violate the existing design. [P2, P3]

The production canonical encoder should accept **intrinsically validated, canonically representable values**, not arbitrary dictionaries or loosely decoded records. It must not require durable acceptance as a prerequisite: otherwise encoding a new operation would depend on already having persisted it.

The authoring order remains acyclic: allocate action identity; freeze mutation inputs; resolve earlier local references; compute operation identities including action membership; construct the action record naming those operations; validate membership and before/after agreement; frame complete groups; seal. Full external dependency closure and local pinning are later acceptance requirements. Do not insert the action record’s own hash into member identities or reintroduce a reference to the enclosing segment’s not-yet-existing identity.

Use one canonical field traversal with appropriately typed byte, hash, and size sinks where it reduces duplication. This avoids maintaining different field ordering in a “hash builder” and a “canonical writer.” It does **not** imply that semantic canonical bytes and compressed transport bytes are identical.

### Direct definitions, not a schema language

Define fixed tags, widths, domains, versions and limits in ordinary versioned Swift declarations beside explicit bounded codecs. Record field order, framing, presence and identity participation in those codecs and the reviewed Protocol/Encryption field tables. There is no separate executable schema, CUE dependency, ConcreteIR, Swift DSL, macro system or generation step.

Keep cross-record and graph semantics in named validators. A canonical set type establishes ordering/uniqueness; it cannot establish the **complete maximal scope frontier of the declared inputs** without executing graph logic.

Compiler checks and independent fixtures must catch duplicate/reserved tags, missing limit mappings, incorrect field participation and layout drift. Test the fixed 124-byte header and exact offsets directly. Never substitute native structure layout, Swift `Hasher`, reflection or dictionary iteration for canonical encoding. Test expected constants/preimages remain independent even when production byte/hash/size sinks share one traversal.

Existing normative choices constrain these Swift definitions. Unresolved TODO semantics must remain unresolved, not receive convenient defaults. Production encoding of an unfinished record remains unavailable or explicitly unsupported—not silently assigned provisional bytes. Finish the smallest complete record subset needed for real local acceptance before expanding to every feature.

### Independent checks of shared encoding logic

No second codec or generator is required. Reuse the existing Python semantic vectors and keep these kinds of evidence separate:

| Evidence | Finds | Can share the same defect? |
|---|---|---|
| Cross-platform Swift corpus | Divergent platform/library behavior for the same implementation | Yes: all platforms may execute the same incorrect encoding. |
| Hand-annotated golden bytes/preimages and published primitive vectors | Shared encoding mistakes and incorrect fixed constants | Still require review, but must not be regenerated by the production encoder. |
| Independent semantic expectations and model-derived scenarios | Incorrect history, compensation, merge, and lifecycle behavior | Yes, if the expected-result path merely calls the production reducer. Avoid that construction. |

Start with direct definitions and a shared fixture directory. Independently expected values are intentional test duplication, not another production format authority. No runtime reflection or general serialization framework is required.

## 6. Separate graph-edge roles and contextual invariants

The graph distinctions are fundamental enough to be nominal API distinctions, not aliases for the same array type. [P2]

| Proposed type | Meaning |
|---|---|
| `CausalParentSet` | Operation history observed by an operation. |
| `NotePredecessorSet` | Revisions superseded by the new note value. |
| `ScopeFrontier` | All maximal actions of one scope represented by specific declared inputs. |
| `CompensationTarget` | The actual action/effect being reversed. |
| `RepresentedRevisions` | The exact input revisions embodied by Current. |
| `UncoveredMaximalEdits` | The source states eligible for automatic delete/edit preservation in a specific history view. |

Do not provide convenience conversions that turn one into another by copying an array. `CompensationTarget` should identify the target’s actual compensation relationship and birth mapping, not simply rename an arbitrary `ActionID`.

A role mismatch then becomes a compiler error. Selecting the **wrong value of the right role** does not: for example, both the original forward action and a later Redo may be legitimate actions, but only the required actual action is the current target. Centralized semantic validation and the existing “actual compensation” tests remain necessary.

### Split canonical sets from graph-derived frontiers

`CanonicalSet<ActionID>` should establish only intrinsic properties: permitted IDs, sorted canonical bytes, and no duplicates. `ScopeFrontier` is stronger: it additionally establishes scope agreement, acyclicity of the relevant evidence, maximality, and completeness relative to the writer’s declared causal inputs.

For received data, require:

```text
declared scope parents == computed maxima for the declared scope and inputs
```

Do not silently drop a nonmaximal member or add an omitted maximum. For locally authored data, compute the frontier from the authoring view. These are different entry points into one implementation of the rule.

Store the exact relevant history/context identity in graph-derived values. A frontier can remain correct about a captured immutable history while ceasing to be current. Likewise, `UncoveredMaximalEdits` must be recomputed when accepted Deletes or source revisions change; its existence cannot make an obsolete automatic copy permanent.

The authoring context must include earlier admitted pending actions on which the live value depends, not only durable accepted history. Conversely, received-but-unapplied objects cannot enter that frontier. Validate incoming action claims against the **writer’s declared inputs**, not the receiving Mac’s current note value. [P2]

## 7. Evidence is a product of facts, not one linear state ladder

Avoid the earlier universal sequence `decoded → accepted → reducer` and the generic `Segment<State>` diagram as a complete model. A local admitted edit is visible before durability; incoming bytes may be installed before dependencies arrive; sealed bytes may be publishable after restart even if no previous callback completed. [P1, P2]

Use a small set of concrete evidence types with documented issuers:

| Evidence | Sole issuing responsibility | Still does not establish |
|---|---|---|
| `AuthenticatedProviderEnvelope` | Encrypted envelope verification under a pinned profile/key/context | Payload semantics, history closure, or physical root authority. |
| `StructurallyValidSegment` | Complete bounded payload validation | Truth of external references or action/graph agreement. |
| `DependencyClosedSegment` | Identity/reference resolution and semantic checks over the required evidence | Durable local retention. |
| `DurableObjectBytes` | Qualified installer’s file/directory barrier and exact verification | Complete parent closure or retained-pin commitment. |
| `AcceptedHistoryReceipt` | Store-owned acceptance commit joining valid complete history, durable objects, and the durable retained pin | Global freshness, another Mac’s receipt, or permanently valid file-operation authority. |
| `PreparedModelChange` | Pure reduction over captured live/history inputs | Permission to publish after those inputs change. |

The names are proposed; align final names one-to-one with CONTEXT and the specification’s boundary definitions. Do not rename `DurableObjectBytes` to something that suggests an entire history closure has been accepted.

Two orthogonal tracks converge at acceptance:

```text
bounded exact bytes ── integrity/authentication ── structure ── dependency semantics
        │                                                            │
        └──────── qualified local installation ── durable bytes ────────┤
                                                                     ▼
                          durable closure + retained-pin commit + readback
                                                                     │
                                                        AcceptedHistoryReceipt
```

The join checks that all facts describe the **same objects, collection, private store, and store incarnation**. Merely receiving two correctly typed arguments is insufficient: a proof about segment A must not bless bytes B, and a receipt issued by store X must not authorize operations in store Y.

The concrete Runtime acceptance boundary uses a private `ValidatedHistoryBatch`.
Its issuing factories perform bootstrap, current-basis or complete declared-history
validation; each object keeps its exact bytes and decoded payload together.
Dependency edges come from that payload. The acceptance transaction consumes the
same batch after checking the owner/header and, for asynchronous validation, the
captured accepted prefix. This narrows the issuer without adding stored evidence.

`CapturedActionIntent` carries each command's required provenance in one enum
variant. `AutomaticCompensation` and `CompensationReview` have distinct consumers;
the reviewed consumer is the explicit approval action. Both revalidate the same
captured whole-command context. Normal commands can intentionally enter review
through `forReview()`. Referenced values still require their existing semantic
checks; these types constrain composition, rather than replace validation.

### Immutable evidence versus revocable authority

Hash validity and a record’s relationship to its declared immutable ancestors are evidence about fixed data. Root ownership, unlock state, selected collection, current undo candidates, and expected file generations are revocable session facts. Do not serialize the latter as reusable permission.

A `RootSessionHandle` keeps ownership/lifetime associated with the right resources; the effect runner still revalidates session and expected-file evidence at the required point. Noncopyable handles can prevent accidental duplication, but cannot stop a provider from replacing a file. Object durability receipts similarly require invalidation/revalidation after restart, store repair, lock loss, or detected damage; they are not promises against arbitrary later deletion by the environment.

Recovery reconstructs acceptance from verified final objects, closure, and the pin. It must also discover installed final objects whose acknowledgment was lost. Never require a previously serialized capability or success callback to recover them. [P2]

## 8. Scope, suite, version, and bootstrap boundaries

Keep provider envelopes distinct from private database row codecs/protection; private current/state rows do not need nested envelopes. Distinguish encrypted authentication from public checksum verification; do not call the public-suite result `AuthenticatedEnvelope`. Provider decoders have no successful result variant for host-private kinds or nonzero local scope. Encrypted-profile contexts have no successful public-suite path. [P1, P2]

This prevents accidental successful use after validation. It does **not** make an attacker’s cross-scope byte string unrepresentable: decoders must reject it using runtime comparisons against independently established profile, collection, key, kind, and scope expectations.

Pass a pinned bootstrap/profile context into the decoder. Do not select the security policy solely from the untrusted envelope’s suite byte. Local State’s unencrypted prefix may guide bounded unlock lookup but cannot authorize filesystem access or overwrite the pinned profile before verification.

Represent unsupported evidence explicitly. For example, a processing result may be ready, waiting for named dependencies, unsupported, invalid, or deferred by a scheduling budget. Preserve the specific meaning rather than converting all outcomes into `nil`, an empty operation list, or generic I/O failure.

Unknown envelope framing may permit only bounded opaque preservation, not authentication under rules the implementation does not understand. A known authenticated envelope containing an unknown required payload version can carry stronger evidence. Keep these cases distinct; do not claim an unrecognized format was verified merely because its prefix was readable.

Exhaustive enums force selection of a branch; they do not prevent a programmer from writing a wrong empty fallback in that branch. Add negative fixtures and restricted transition APIs so unsupported or incomplete evidence cannot satisfy editable-bootstrap prerequisites.

## 9. Constructed note values, text boundaries, and merge eligibility

Use dedicated value types for exact plaintext UTF-8 bytes, label values and display dates. Preserve exact byte identity where the protocol requires it; converting everything to a user-facing string representation must not change equality or hash inputs. The [first-save contract](first-save-reopen-contract.md) fixes exact stored label tokens separately from the host lookup index and finite binary64 reference-date seconds, with a working plaintext-value codec. New RTF/HTML codec, rendering and identity work is deferred pending its separate retain/remove decision; attachments are unsupported. Existing rich inputs retain their supported legacy path or explicit unsupported/conversion handling before migration, never silent flattening. [P1, P3]

`PassphraseV1` establishes NFC normalization followed by UTF-8 encoding, with a maximum of 1,024 normalized bytes and no trimming or case folding. Its compatibility policy must define the accepted character repertoire and treatment of code points unassigned in the selected Unicode baseline. Foundation’s NFC implementation is a valid implementation choice: conforming Unicode implementations produce identical normalization results for characters assigned in both supported versions. A bundled, versioned normalizer such as utf8proc is warranted when reproducing the v1 mapping requires behavior independent of host Unicode support. Qualify the selected implementation using Unicode conformance data and independent exact-byte/KDF fixtures. Stored note bodies remain outside this normalization path. [P2, S6, S7]

Do not implement length-limited passphrases via zero-terminated string functions. The foreign-function boundary must use explicit byte lengths and retain the required input representation. A passphrase wrapper does not prove erasure of all previous Swift/Objective-C string copies; bound ownership and wipe buffers where the implementation actually controls them without promising total plaintext elimination.

### Restrict the two-sided text kernel, not every accepted note

Separate `EligibleHeadPair` from `TwoSidedPlainTextMergeInputs`. The first validates the relevant two differing heads, live birth, complete evidence, and unique best common note ancestor. The second additionally contains exact plain-text LF tokens within the **10,000-token per-input two-sided limit**.

Perform equality and one-sided-change rules before requiring that second type. Large plain-text values may pass these rules. The protocol also permits opaque equality/one-sided rules for supported rich values; preserve that distinction if a rich codec is later retained, without implementing one now. The limit is not a universal maximum body length. [P1–P3]

The two-sided kernel accepts only `TwoSidedPlainTextMergeInputs`; there is no rich-text case. It implements the pinned single bounding edit, exact LF tokenization, and strictly separated intervals. Prepared output includes represented inputs, base, algorithm, and result digest for independent recomputation.

Expose one implementation of delete coverage/preservation and one candidate-selection implementation shared by menu validation, native routing, review preparation, and replay. Receivers and views must not each recreate slightly different predicates.

## 10. Limits that force implementation and test maintenance

Create a closed `ProtocolLimit` registry whose entries record units, inclusive/exclusive boundaries, stage, and rejection/deferral policy. Preserve the existing object, descriptor, stamp, passphrase, and merge limits; do not invent values for the remaining TODO rows. [P3]

Separate it from `WorkBudget`. Protocol limits define accepted representations; scheduling budgets govern how much work a machine does in one pass. Exhausting a traversal/fetch budget yields resumable deferred work, not invalid history or a truncated frontier. Ordinary collections must not age out because an arbitrary total ancestry-depth cap was added.

Choose unfinished limits using realistic input rates, whole-note memory and NSTextView/synchronous-search measurements, with headroom for action metadata and before/after representations. Preserve the fixed wire ceilings unless explicitly reviewed; no speculative live-note paging or oversized-note subsystem. Small current notes do not bound retained-history growth. [P3]

### Make compile-time fixture coverage concrete

`CaseIterable` by itself does not require a meaningful boundary test when an enum gains a case. Add a **hand-maintained exhaustive mapping with no `default`** from every limit to its integration fixture strategy. The strategy invokes the actual production entry point, not just a helper that compares integers.

Conceptually:

```swift
// Illustrative shape; names refer to the eventual fixture implementation.
func boundaryFixture(for limit: ProtocolLimit) -> BoundaryFixture {
    switch limit {
    case .decodedObjectBytes: return decodedObjectFixture()
    case .encodedObjectBytes: return encodedObjectFixture()
    case .descriptorBytes: return descriptorFixture()
    case .projectionStampBytes: return projectionStampFixture()
    case .normalizedPassphraseBytes: return passphraseFixture()
    case .twoSidedMergeTokens: return twoSidedMergeFixture()
    }
}
```

A newly added case then makes this mapping fail to compile until its fixture strategy is chosen. Parameterized tests iterate the registry and exercise below/at/above boundaries, the intended failure classification, and the complete production call path. Swift Testing provides the parameterization; the mapping supplies the project-specific exhaustiveness. [S8]

The at/above cases must reflect the operation’s semantics. For example, a 10,001-token two-sided merge requires review; it is not an invalid note or an invalid history object. At each boundary, keep unrelated constraints valid so the test cannot pass because the input failed earlier for a different reason.

Add a mutation check that removes or misroutes the enforcing guard and requires the corresponding test to fail. This distinguishes “a test exists for every enum case” from “every limit is enforced at its actual boundary.”

## 11. Filesystem capabilities and durable acceptance

Keep immutable exclusive creation and expected-current replacement as distinct entry points and plan types. A single installer with a Boolean `overwrite` flag defeats the intended separation.

| Plan | Required evidence | Permitted target |
|---|---|---|
| `ExclusiveObjectInstall` | Exact sealed bytes, generated locator, live owned destination context | New immutable provider object; an equal existing object requires verification and durability checks. |
| Private SQLite transaction | Current store/history/private-field generations and validated exact inputs | Atomic local history/index/pin acceptance, or a separately scoped settings/pending-state update. |
| `ExpectedProjectionReplacement` | Exact authorized current-file observation and intended output | A captured plaintext projection, not an arbitrary filename. |

Only the path-rendering implementation converts validated locators into protocol filenames. External projection leaves use a different checked type with separator/NUL/reserved-name rules. Root authority remains separate from both. Preserve the existing rooted-helper contract on macOS rather than replacing it with generic URL writes. [P1, P2]

Use Swift System where it reduces low-level handling, but not as evidence of portable filesystem semantics. Its own documentation explicitly distinguishes a typed system interface from a cross-platform abstraction. [S9]

### One store-owned acceptance commit

The local owner should expose a cohesive commit operation that joins validated history, durable objects, and the retained pin. Callers should not manually compose a public sequence of `markDurable()`, `markPinned()`, and `acknowledge()` setters.

The [LocalStore contract](../LocalStore.md) maps that order to complete validation, then one qualified SQLite transaction containing exact immutable bytes, complete accepted membership, pin and reverse-dependency wakeups, before durability acknowledgment or incoming-history publication. Earlier same-envelope parents are valid with the complete atomic group; RAM-only external parents are not. Provider installation retains its own file/directory barriers. Current-row materialization is a separate derived transaction, never the only owner of required history/state. [P1, P2]

Record ambiguous outcomes explicitly. Retry queries exact committed object/operation identity; it does not reseal changed content or infer completion from a reservation/live note. Acceptance and pin commit together. Restart drains durable ready candidates and catches up current materialization before publishing a complete editable model.

A mock backend that simply returns `DurableObjectBytes` is a powerful test seam and part of the test trust boundary. Do not make arbitrary caller-supplied backends public proof issuers without explicitly weakening the guarantee to “assuming this backend satisfies its contract.”

## 12. Actors, blocking execution, cancellation, and stale results

Keep one local ownership coordinator and one repository/root coordinator per open collection, rather than creating actors for every note, operation, or record. They may own explicit state machines and immutable messages; the deterministic reducers themselves need no actor.

Evaluate actor-based ownership when implementing or revisiting a mutable-state
boundary, especially where it makes the implementation both simpler and safer.
Prefer compiler-checked isolation over manually enforced queue confinement when
the complete design reduces trusted plumbing. A small dispatch-backed actor
executor can preserve dedicated blocking-I/O execution while its actor owns the
connection and mutable state. Include asynchronous history lookups, resource
cleanup, cancellation and deployment support in that comparison. Keep synchronous
transactions and existing generation/admission checks intact. The adopted
[database actor](actor-database-adoption.md) follows the initial
[isolated experiment](actor-database-prototype.md): compiler-isolated live
connection state, synchronous database turns and asynchronous ancestry reads.
Release-only C-handle disposal remains a narrowly documented FFI responsibility.

**Actor isolation does not serialize an entire asynchronous transaction.** Actor-isolated synchronous work runs without another actor job interleaving, but assumptions may change across `await`. Apple’s guidance explicitly calls for rechecking them. [S10]

Before suspending, reserve the in-flight operation and freeze its operation ID, bytes, store incarnation, and relevant generations. On completion, match that operation before changing state. One local sealer must remain an explicit invariant, not an assumption about actor mailbox ordering. Multiple pin updates must not race and replace newer accepted history with an older captured pin.

Represent the control plane as a small closed state/event transition function where practical:

```text
(coordinator state, typed event) → (next coordinator state, typed effect requests)
```

Effects execute outside that pure transition and return typed completion events. Keep this specific to storage phases; do not introduce a generic workflow engine. A pending local commit can be distinct from independent provider requests, so provider delay has no transition that revokes a healthy local edit gate.

The concrete local coordinator uses `LocalStoreLifecycle` for open, quiescing and
closed admission. `LocalCommitState` distinguishes idle, pending and running
work; its owned value contains either the frozen capture or that capture's exact
sealed envelope. Reserving running work precedes suspension. Failure retains the
same owned work as pending, while successful acceptance releases it. A definitive
pre-seal encoding rejection releases the slot and returns the captured input in
its handle. Quiescing drains active work and returns to open admission when an
owned retry still requires attention. These enums replace independent flags and
the single-entry commit dictionary without introducing persistent state. The
[typed-boundary report](typed-runtime-boundaries-validation.md) records the actual
construction and consumer checks.

### Do not block the cooperative executor on provider work

Blocking syscalls and coordinated provider access need appropriately isolated execution. `Task.detached` alone does not create a dedicated blocking-I/O thread pool. Swift’s concurrency runtime expects forward progress from its cooperative threads. [S11]

Use a small, bounded blocking-I/O adapter with separate local and provider execution resources, compatible with the deployment target. Retain an existing serial queue where that is the smallest correct bridge. Do not assume a newer custom-executor API is backdeployable without checking it. Avoid waiting on semaphores from actor code to make asynchronous work “synchronous.”

Completion callbacks must retain their operation-owned buffers/handles and complete exactly once. Cancellation before admission can decline work; dismissal/cancellation after admission cannot erase pending text or revoke an installed operation. A deadline does not prove a provider accessor stopped. Keep its ownership until it returns or is safely fenced under the existing lifecycle contract. [P2]

### Publication remains a separate gate

Incoming accepted history produces a `PreparedModelChange` tied to captured live values, represented revisions, root/store/lifecycle, and relevant note generations. The main-thread bridge performs the final check and publication without an intervening suspension or external callback. Stale results are discarded/recomputed; they do not overwrite newer admitted work.

When a temporary local Current-head pin becomes releasable, schedule this reduction/publication even without another provider event. Keep Current paired with its represented revisions and recheck both; an unchanged causal frontier alone does not make an old prepared command applicable. [P1, P2]

A successful save completion clears only the pending generations it covered. It is not permission to reinstall the old captured body into the live store. Native typing, reviewed compensation, external editing, and earlier pending dependencies retain their distinct admission paths. [P2]

## 13. Selective noncopyable ownership

Use `~Copyable` for resources with genuinely unique ownership: an owned descriptor, a staging-file owner, or an operation ticket whose accidental duplication would be a defect. Swift’s noncopyable structs/enums support consumption and resource deinitialization; consuming a value prevents later use through that value. [S12]

Do not make immutable history facts, normal IDs, or retained sealed bytes noncopyable just to make the API appear stricter. Those values legitimately support sharing, retransmission, inspection, and recovery.

Noncopyability gives **at-most-once consumption**, not guaranteed eventual execution. A value may be dropped; process termination may bypass cleanup. Do not use `deinit` to promise a fallible durability commit, callback acknowledgment, or exactly-once external effect. Duplicate logical actions remain controlled by retained identities and idempotent installation, not by a transient Swift ownership feature.

For a one-shot approval or operation ticket, retain sufficient identity/context in the coordinator to detect a stale or duplicate runtime request as well. Two separately constructed tickets can still describe the same action unless the issuer prevents it.

The direct noncopyable cleanup prototype required additional ownership plumbing
across the synchronous dispatch callback. Runtime therefore retains its existing
actor-owned C resources and narrowly scoped synchronous disposal bridge. The
typed-boundary report records that experiment and the retained lifetime checks.

## 14. Crypto, compression, secrets, and document adapters

Keep the dependency surface small. **Swift Crypto** is the cross-platform API choice for the required CryptoKit-compatible primitives. Preserve the pinned Argon2 reference implementation and its exact v1 profile rather than replacing it with a convenience password API that changes parameters. On Apple platforms, credential storage remains the separately tested Keychain adapter. [P2, S13]

Make cryptographic composition less ad hoc without overstating type guarantees. Centralize the exact domain-separation bytes, header encoder, kind/suite mappings, and HKDF information construction. Expose operations such as “seal this provider change under this pinned collection context,” not a general storage-level method accepting arbitrary `info` strings, AAD, and caller-selected nonces.

Use the same exact encoded header bytes for AAD and the stored envelope. Keep the specified object-kind and host-scope separation; production retries reuse sealed bytes. Fixed nonce/key injection belongs to test-only targets. Explicit scope/key wrappers prevent obvious call mismatches, while fixed vectors and mutation tests verify the actual byte composition.

Use the pinned portable zstd implementation for all new compression. Provider envelopes follow the [single-frame profile](../Encryption.md#compression-profile), with explicit content size, no dictionary dependency and bounded output/window. Authenticate encrypted data before decompression; require exact input/output consumption and reject truncation, concatenated/skippable frames and trailing bytes. Neither successful AEAD nor a wrapper type establishes those properties by itself. Private-row dictionary metadata is separately versioned. Zlib remains only in legacy database/WAL compatibility. [P2, P3]

Do not expose `AppKit`, `NSFileVersion`, arbitrary archived objects, or platform rich-text rendering as protocol values. New work is plaintext-first. Existing unsupported rich inputs must remain preserved or be explicitly handled before migration; do not flatten, reserialize on receipt or pretend an unsupported collection is plaintext. Any later supported rich codec requires exact received-byte identity and a separately reviewed import/rendering path.

Use closed diagnostic events containing approved IDs, counts, classifications, and codes. Avoid general-purpose `Any`/string logging interfaces inside the core. Keep titles, bodies, paths, bookmark data, secrets, and plaintext history out of these events. This reduces accidental disclosure; Swift’s type system is not a general information-flow or reflection-proof secrecy system.

## 15. The Objective-C bridge is an input boundary, not a proof issuer

Objective-C supplies immutable note snapshots, captured generations, user intent, and opaque handles issued by Swift. It does not construct trusted protocol IDs, `SegmentLocator`s, accepted-history receipts, or filesystem permission tokens. Existing legacy IDs and selected URLs may cross as **untrusted input to validation**, not as already-certified objects.

Retain a main-actor Swift bridge for interaction with the legacy live store. Copy/freeze inputs before worker transfer; do not wrap an `NSMutableData` or mutable note object in a struct and assume that makes it immutable. Keep checked conversion of lengths, integer widths, empty/absent values, enum discriminants, and error codes at the seam.

An opaque object wrapper alone does not enforce session validity or one-time use. The receiving owner validates the handle’s collection/store incarnation, generation, and current operation status. Prevent arbitrary bridge initialization, broad KVC-style reconstruction, and archived authority objects.

A typed bridge completion distinguishes admitted/pending, accepted locally, provider-installed, unsupported, stale, and failed-stage outcomes as appropriate. Do not collapse these into one Boolean “saved.” Preserve existing immediate editing/search and the rule that provider or materialization failure is not local data loss. [P1, P2]

Retain NV's 2.7-second idle and 15-second first-pending capture scheduling plus forced lifecycle/resolver/external-editor boundaries; these are not native action-group boundaries or hard durability deadlines. Follow ordinary AppKit input-context behavior for local focus/close/switch actions. Prefer deferring remote editor application to a safe input boundary, then revalidate; composition alone creates no conflict or prompt. No separate committed-text buffer or durable draft protocol is prescribed. Test supported registered external undo changes before considering the unaccepted Undo Saved Edit fallback; receiving history or presenting a derived merge must not author another portable action. [P1, P2, P6]

## 16. Automated enforcement at multiple levels

Maintain a compact **invariant ledger** connecting each requirement to its issuer, consumers, runtime checks, and tests. It is a review and CI input, not a new authority parallel to the specification.

| Obligation | Primary enforcement | Required challenge |
|---|---|---|
| IDs and graph roles cannot be substituted | Nominal types and restricted constructors | Separate-client compile-fail tests. |
| Wrong suite/scope cannot become usable payload | Closed envelope families plus pinned-context checks | Re-enveloped, copied, wrong-key/profile/scope fixtures. |
| Identity includes exactly the specified semantic fields | Explicit Swift canonical encoder and field participation | Independent preimages; semantic-field mutations; transport-repacking invariance. |
| Declared scope frontier is complete and maximal | One contextual graph validator | Omitted maximum, duplicate, cross-scope, nonmaximal, and cycle fixtures. |
| Two-sided merge requires bounded exact plaintext | Constructed kernel input | Wrong-role compile test; exact boundary and one-sided fallback tests; rich-input cases only if that codec is later enabled. |
| Acceptance requires closure, durable objects, and pin | Store-owned commit issuer | Fault injection, crash/reopen, and pin/object mismatch tests. |
| Freshness survives asynchronous execution | Context-bound plans plus final runtime fences | Deterministic stale-completion and ABA session scenarios. |
| Limits remain implemented and tested | Registry, exhaustive fixture mapping, integration tests | Add-a-case compile control and remove-guard mutations. |
| Swift format definitions match the reviewed protocol | Explicit definitions and independent layout checks | Literal golden corpus, header offsets, tag/limit checks and field-omission mutations. |
| Provider failure cannot block local durability | Separate execution/effect ownership | Hung-provider simulation plus continued local commits. |

A ledger entry should contain the specification anchor, relevant types and issuer, positive test, negative/compile-fail test where applicable, and its residual assumption. CI can reject missing references or test IDs. It cannot prove that the tests actually establish the claim merely because those fields are populated.

### Compile-fail tests

Compile intentionally invalid snippets against the ordinary built module: pass an `ActionID` as an `OperationID`; pass scope parents as a compensation target; attempt publication with parsed-only input; construct an acceptance receipt; decode a physical permission from storage; or consume a unique ticket twice.

Each case must fail for the expected diagnostic category at the intended line, with a positive companion using the valid API. A missing module, unrelated syntax error, or linker failure is not successful enforcement evidence. Pin the compiler used for diagnostic matching and update expectations deliberately on toolchain changes.

Source/API checks should also reject accidental escape hatches: public unchecked constructors, conformance of authority types to `Decodable`, unconstrained raw path publication, safety-disabling flags, and unreviewed unsafe annotations. Use narrowly scoped syntax-aware checks where needed; avoid claiming that a string grep is a proof of architectural isolation.

### Golden bytes, generated inputs, and property tests

Use the package's native Swift tests for parameterized fixtures, invoked through the existing Makefile on macOS and directly in portable jobs. Keep standalone legacy suites; qualify test-runner availability separately from the macOS 11.5 library/bridge executable. No third-party/duplicate test framework is needed. Keep synthetic fixture bytes, decoded values, exact canonical preimages, expected IDs, expected classifications, and provenance together. Encode large test integers as explicit decimal strings or byte encodings where JSON tooling could otherwise lose precision.

Add deterministic generators for valid operations and DAGs, followed by targeted invalid mutations. Preserve seeds and minimize failures. Useful properties include equal complete histories reducing identically across delivery permutations; duplicate receipt being idempotent; transport repacking preserving operation identity; Current-only edits preserving unrelated alternatives; and restoration/compensation maintaining distinct births.

Do not turn those into invalid global assertions: derived live notes are not monotonic because obsolete automatic preservation may retract, and an untouched copy’s eligibility can change as Deletes arrive. Accepted evidence is retained; the derived view can legitimately change. [P2]

## 17. Deterministic implementation simulation, model bridges, and real crashes

The largest new runtime-testing investment should be a **small deterministic simulator using production codecs, validators, reducers, and coordinator transitions**. Substitute only environmental operations: filesystem behavior, delivery, time, identity allocation, and controlled completion scheduling.

A virtual filesystem still distinguishes visible bytes, durable bytes and durable directory links for provider/projection operations. Private storage instead exercises the real SQLite engine and controlled VFS/transaction failures; do not simulate the removed private object-file/pin-file gap. A crash runs the real opener over surviving database/journal state, not a mock “save succeeded” flag. Current-row capture and indexed catch-up follow [LocalStore](../LocalStore.md), not received provider snapshot trust.

Start with the existing bounded scenarios, then vary installation/completion order, duplicated/out-of-order delivery, corrupt/unknown objects, provider delay, pin failure, stale model results, restart, and store repair. One deterministic event at a time makes failures reproducible without trying to exhaust Swift’s actual thread scheduler.

### Connect, do not equate, models and implementation

Use the shared fixture representation to carry model scenario inputs and independently expected observations into Swift. Record a projection from concrete implementation state to the modeled facts: installed objects, pinned closure, known action sets, note values, and candidate sets. Replay specific counterexamples and reachable success scenarios through the production path.

Retain the TLA+ suite and its assertion-specific broken policies. Where feasible, compare a bounded concrete transition trace against the corresponding model projection. A generated fixture corpus or matching finite trace is **conformance evidence**, not a refinement proof for arbitrary histories. Do not regenerate expected values by calling the same Swift function being tested. [P5]

Mutation controls should target the named obligation: allow early acknowledgment, omit a scope maximum, clear newer pending work, confuse actual Redo with original action, split a group, or publish before a repaired private pin commits. A timeout or unrelated failure does not count as catching the mutation.

### Fuzz at the right depths

Use raw-byte fuzzing for bounded framing/decoding and structured fuzzing for graph relationships. Fuzz plaintext payload entry points directly, in test-only access paths, so authentication failure does not prevent exercising deeper validators. Also test that production entry points cannot bypass authentication.

Swift documents libFuzzer integration. Verify the selected compiler, linker, runtime, and coverage instrumentation with an intentional-failure smoke test before calling the campaign operational. Run AddressSanitizer/ThreadSanitizer configurations where supported, and instrument C/C++ dependencies with the applicable Clang sanitizers, including UBSan. Do not describe UBSan as a general verifier of Swift semantics. [S14, S15]

### Qualify actual persistence independently

Kill-process tests exercise application-crash recovery, ownership teardown, and lost completions. They do not emulate loss of the kernel’s dirty cache. Power-loss/durability claims need the separate filesystem/platform evidence already required by the specification. Use actual OS tests for file/directory barriers, exact installed-file verification, directory locking, symlink/namespace races, metadata behavior, and provider access. [P1, P5]

Keep each test family’s scope visible: deterministic simulation proves properties only under its simulated storage model; OS probes test specific primitives; deployment smoke tests validate specific binaries/OS combinations; none establishes globally complete provider disclosure.

## 18. Delivery order, retained decisions, and completion criteria

Implement the smallest enforceable path before extending the abstraction surface:

| Step | Deliverable | Evidence required before expanding |
|---|---|---|
| A. Compatibility and boundary prototype | Pinned toolchain, parser decision, minimal package/bridge, nominal roles and issuer types | macOS 11.5 executable probe; cross-platform compile checks; correct negative diagnostics. |
| B. Minimal complete value/identity codec | Bounded cursor, direct Swift definitions, complete minimal actions/bootstrap/private state and public/encrypted envelopes | Independent golden bytes/hashes; at-boundary tests; malformed-input/fuzzer smoke checks. |
| C. Early local acceptance | Real installer, retained-pin commit, recovery, evidence issuers for that complete subset | Fault-injected production path; virtual-disk and actual crash tests; lost-callback recovery and newer pending edit. |
| D. Expanded semantics, two-store exchange and recovery | Complete action validation, contextual frontiers, merge/delete/undo reducers, snapshot/repair/copy | Independent expected histories through actual bytes/acceptance/reopen; relevant model scenarios, not shared in-memory indexes. |
| E. Provider and application seam | Independent execution, rooted effects, plaintext/pending decisions, main-thread publication and legacy integration | Stale-generation, repeat-import crash, cancellation, hung-provider, unsupported-input preservation and real application tests. |
| F. Qualification | Supported OS/filesystem/dependency matrix and operational limits | Actual target binaries, sanitizer/fuzz evidence, model reruns, and launch/latency/memory measurements. |

Keep Swift Crypto, the pinned Argon2 implementation, bounded zstd handling, and optionally pinned Unicode normalization behind narrow APIs. Add Swift System and selected Swift Collections types only where they remove work. Use the adopted private SQLite transaction boundary; avoid an additional database, generic state-machine framework, generic dependency-injection framework, custom actor runtime, or complex macro system merely to realize these invariants.

No schema/code-generation phase is planned. Add formal checks only for a demonstrated uncovered composition; they do not postpone the small trusted validators and real crash tests. The [phased plan](swift-storage-implementation-plan.md) gives detailed dependencies and exit gates.

### Decisions still requiring actual policy

The first-save contract supplies implemented scalar/note values and first-subset operation identities/records, plus later record layouts. Complete crypto/action/graph implementations and their fixtures still remain; a record with a computed ID can retain unresolved external claims. Remaining format choices include later record bounds, future optional-extension identity, general snapshot acceleration verification and the other unfinished layouts/vectors in Format TODO. Initial snapshot verification uses imported-history replay; new RTF/HTML support is a separate deferred decision and attachments are out of scope. Do not treat every unchecked layout as an unresolved product policy. [P2, P3]

NV-head copy policy is settled: `RecoverCopy` represents only the selected revision; it does not implicitly Keep Current or author source Put/Delete/supersession. Source-head reduction remains independent of unresolved attention, so reciprocal copies never make the original empty/absent. Completed disposition survives later copy edits/deletion; new descendants remain reviewable. Its exact encoding and integration still need tests. Ordinary eligible external files auto-import after mandatory exceptions and narrow repair-candidate checks; late independent births remain distinct. Pending latest/frozen ownership and reservation/receipt crash ordering are specified in Protocol, not open policy. [P1–P3]

New-platform root ownership, credential storage, projection metadata, filename behavior, and durability equivalence also need explicit contracts. Record any required normative amendment rather than treating it as an invisible implementation fallback.

### Completion means more than a successful build

The revised architecture is ready for implementation review when each important boundary has a named issuer and consumer, independent inputs cannot construct its proof, contextual facts carry a revalidation rule, and the corresponding challenge test is identified. Production completion additionally requires the actual codec, installer, integration, model, and platform evidence—not just the proposed type map.

The intended result is not “the compiler proves the storage system.” It is a smaller implementation in which many incorrect calls are rejected statically, the remaining dynamic invariants are established in a few places, and automation continuously challenges both those places and the claims made about them.

## Appendix A. Architecture decisions at a glance

| Area | Current direction |
|---|---|
| Staged validation and durability | Retained; decomposed into orthogonal evidence and one acceptance join, with explicit non-linear local/remote paths. |
| Replace the parser backport | Maintenance concern retained; blanket `Span` runtime premise corrected from implementation guidance; bounded reader adopted provisionally with a compatibility gate. |
| Compute identities rather than trust input | Retained for identified objects; reference tokens remain constructible so missing evidence can be requested. |
| Split envelope scope/suite | Retained; runtime pinned-context checks still reject attacking bytes and dynamic identity mismatches. |
| Distinct graph edges | Retained and extended to graph-context binding and wrong-value-of-right-type tests. |
| Constructed antichains and merge inputs | Split intrinsic canonical sets from complete graph frontiers; preserve rich/large equality and one-sided rules outside the two-sided kernel. |
| Limit enumeration forces test coverage | Made concrete with exhaustive fixture mapping, actual entry-point tests, and guard-removal mutations. |
| Typed unsupported outcomes | Retained; distinguish verified versus opaque unsupported evidence and test against empty fallback. |
| Separate immutable and mutable installers | Retained for provider/projection effects; private history/state instead use the qualified SQLite transaction mapping. |
| Canonical definitions and reference checks | Ordinary Swift definitions, no schema generator; independent literal bytes and existing semantic vectors. |
| Objective-C bridge discipline | Retained; raw legacy values remain valid validation inputs, and opaque handles still require runtime session checks. |
| Avoid generic typestate soup | Retained; use concrete evidence names and selective unique ownership. |
| Types cannot fix cryptographic strings | Extended: centralized typed composition removes casual call-site variation, while independent byte vectors still establish correctness of the composition. |

## Appendix B. Compiler checks performed for this revision

The original proposal reported nine small contract probes compiled with **Swift 6.2.1 on x86_64 Linux**, using Swift 6 language mode, strict memory-safety checking, and memory-safety warnings as errors. The reported `swift-storage-contract-probes.zip` is not present in this repository; the table below records that earlier report, not independently reproduced evidence for the planned package. Repeat these checks against the actual module. They exercise isolated language/API patterns, not storage implementation correctness.

| Probe | Observed result |
|---|---|
| Positive client uses matching identity, edge, and receipt types | Compiled. |
| Action ID supplied to an operation-ID parameter | Rejected with a type-conversion diagnostic. |
| Scope-parent value supplied as a compensation target | Rejected with a type-conversion diagnostic. |
| Parsed object supplied to accepted-receipt publication | Rejected with a type-conversion diagnostic. |
| Separate client constructs a privately initialized receipt | Rejected for inaccessible initializer. |
| Same noncopyable token consumed twice | Rejected for multiple consumption. |
| Existing closed limit enum and exhaustive fixture mapping | Compiled. |
| New limit enum case added without updating that mapping | Rejected for non-exhaustive switch. |
| New enum case with only `CaseIterable`, without a fixture mapping | Compiled, demonstrating that enumeration alone does not force test implementation. |

No macOS 11.5 run, parser-backport build, NV implementation test, cryptographic vector run, TLA+ rerun, or filesystem durability test was performed for this document. Those remain the named implementation gates rather than implied results of these probes.

## Sources and evidence basis

### Project material

**[P1]** [iCloud Drive specification](../../iCloud-Drive-Support-Spec.md), especially its requirement registry, input/content scope, local durability, publication, conflict-copy and external-import policies. Adopted requirements, not implementation results.

**[P2]** [Protocol](../Protocol.md), [Encryption](../Encryption.md), [Implementation](../Implementation.md) and [Verification](../Verification.md), with the rationale in [ADRs](../../adr). These actual repository files replace the earlier concatenated bundle references.

**[P3]** [Format TODO](../Format-TODO.md), §§1–10. Remaining encoding and validation work; no values are silently invented for unfinished rows.

**[P4]** [Conformance strategy](swift-storage-conformance-testing-strategy.md), for issuance/use/intent obligations, independent oracles and targeted mutation controls.

**[P5]** [Model coverage](../../tla/Proposal5-Coverage.md), [model guide](../../tla/README.md) and [runner](../../tla/check-segment-models.py), for bounded models, negative controls and scenario structure. Existing reported evidence is not represented as having been rerun for this documentation correction.

**[P6]** [CONTEXT](../../../CONTEXT.md), [AGENTS](../../../AGENTS.md), [integration tests](../../IntegrationTests.md), [Apple contracts](../../Apple-API-Contract-Validation.md) and [safe replacement](../../Foundation-Safe-Replacement-Migration.md), for vocabulary, deployment, live-store/search, legacy/AppKit and physical-effect boundaries.

### External primary sources retained from the original revision

The following references support the original language/library discussion, not the correctness of the proposed NV implementation or new API experiments in this documentation correction. Recheck mutable repository/API details and replace repository links with selected commit permalinks when implementation dependencies are pinned.

**[S1]** Swift migration guide, [Enable data-race safety checking](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/enabledataracesafety/).

**[S2]** Swift Evolution, [SE-0458: Opt-in Strict Memory Safety Checking](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0458-strict-memory-safety.md), implemented in Swift 6.2. Compiler diagnostics, unsafe acknowledgments, and build flags.

**[S3]** Swift language guide, [Access Control](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/accesscontrol/).

**[S4]** Guillaume Lessard, Swift Forums, [Supporting Span in packages](https://forums.swift.org/t/supporting-span-in-packages/81667), August 15, 2025. Core Span backdeployment and the distinct `UTF8Span` restriction; not a certification of `swift-binary-parsing` on macOS 11.5.

**[S5]** Apple, [`swift-binary-parsing` package manifest](https://github.com/apple/swift-binary-parsing/blob/main/Package.swift), inspected September 9, 2026. Declared platform and compiler/package settings.

**[S6]** Unicode Consortium, [UAX #15: Unicode Normalization Forms](https://unicode.org/reports/tr15/), especially normalization stability across versions for mutually assigned characters.

**[S7]** JuliaStrings, [utf8proc](https://github.com/JuliaStrings/utf8proc), normalization implementation and data versioning surface.

**[S8]** Swift project, [Swift Testing README](https://github.com/swiftlang/swift-testing). Parameterized tests, default parallel execution, and supported toolchains/platforms. Test-runner platform support is not an app deployment certificate.

**[S9]** Apple, [Swift System README](https://github.com/apple/swift-system), including the distinction between typed system interfaces and a cross-platform abstraction.

**[S10]** Apple, [Protect mutable state with Swift actors](https://developer.apple.com/videos/play/wwdc2021/10133/), WWDC21; Swift Evolution [SE-0306: Actors](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md). Synchronous actor execution and reentrancy across suspension.

**[S11]** Apple, [Swift concurrency: Behind the scenes](https://developer.apple.com/videos/play/wwdc2021/10254/), WWDC21. Cooperative execution and forward-progress constraints.

**[S12]** Swift Evolution, [SE-0390: Noncopyable structs and enums](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0390-noncopyable-structs-and-enums.md). Unique ownership and consumption; later generic extensions are not required for the isolated claims here.

**[S13]** Apple, [Swift Crypto README](https://github.com/apple/swift-crypto). Cross-platform CryptoKit-compatible primitive APIs; the NV composition remains defined by the project specification.

**[S14]** Swift compiler, [libFuzzer Integration](https://github.com/swiftlang/swift/blob/main/docs/libFuzzerIntegration.md). The actual toolchain/instrumentation combination still needs its smoke test.

**[S15]** Clang, [UndefinedBehaviorSanitizer](https://clang.llvm.org/docs/UndefinedBehaviorSanitizer.html), for C/C++ instrumentation; Apple, [Diagnosing memory, thread, and crash issues early](https://developer.apple.com/documentation/xcode/diagnosing-memory-thread-and-crash-issues-early), for platform diagnostics.
