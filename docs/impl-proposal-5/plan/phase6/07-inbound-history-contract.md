# P6.1 — Standalone projection history validation

This slice resolves a parsed advisory stamp against accepted immutable history.
It supplies a history-checked source to the later file classifier. Physical
readback, exact encoded-byte comparison, duplicate-file detection and association
permission remain separate P6.2/P6.3 checks.

## Read and evidence boundary

`LocalStoreSession.projectionHistory(for:basedOn:)` requires an owned plaintext
collection and a store-issued current capture. It distinguishes foreign collection,
invalid claim, missing accepted input, rejected prerequisite and checked history.
Waiting and blocked results retain exact locators and existing rejection reasons;
they cannot turn a delay into a fresh import. Unsupported prerequisites remain
potentially usable by a later implementation.

For accepted inputs, use `CheckedEnvelopeRecords` to authenticate exact retained
bytes and verify operation/action occurrence addresses, complete membership and
indexed links. Reuse each selected envelope once within this query. Ordinary and
automatic sources require their exact value-producing operation; automatic sources
also recompute their key and conflict-copy presentation value. Derived sources
follow the claimed heads' complete note-predecessor closure, then invoke the same
reduction/result/base/merge-ID checks as segment validation. Later heads elsewhere
in the accepted collection do not invalidate an older historical value. The
standalone Core entry point has external occurrences rather than a fictitious
enclosing segment or local prefix.

The reader compares incoming addresses with intact retained occurrences. A forged
address or invalid source claim is a passive `invalidClaim` result. Damage found
inside required retained bytes or their index evidence uses the existing durable
verification request and history-damage outcome. These paths remain distinct so
untrusted file metadata cannot poison a healthy private store.

`CheckedProjectionHistory` has a file-private issuer, immutable stamp and Current
relationship, and private source contents. `projectionValue(from:basedOn:)`
rechecks the store, session, connection, accepted prefix and current-view fence
before supplying those contents. Both issuance and consumption reject a changed
view. The relationship compares logical operation/derived/automatic identities;
another accepted envelope containing the same operation does not change that
logical relationship. A valid source can match Current, differ from Current, or
refer to a birth absent from Current. Absence never grants restoration/deletion
permission.

This adds no table, encoding, persistent validation cache or physical receipt.
The existing verification mechanism retains interrupted checks. Query-local
memory grows with selected ancestry and envelopes, rather than unrelated history.

## Required executable evidence

- Literal Core equal/merged fixtures, exact occurrence lookup, local-prefix
  rejection, missing inputs, wrong values and incomplete ancestry.
- Actual accepted ordinary/equal/merged/automatic sources; independently expected
  bodies and complete values; each selected envelope decoded once.
- Valid old claims after later edits/deletion, same-operation repackaging, missing
  and rejected inputs across restart, and actual retained corruption versus a
  malicious claim.
- A held production read with an intervening save, same-type/wrong-store evidence,
  stale consumption and reopening; all must reach their intended fence.
- Ordinary and same-module construction/substitution/private-value probes, plus
  mutations targeting source identity, result validation and the final view checks.

The [qualification ledger](07-inbound-history-validation.md) records completed
commands and remaining coverage. `ProjectionStampSafety`'s history predicate is
unchanged: these tests refine part of its concrete input validation. No model
assertion is weakened, and executable history checks alone do not qualify its
physical-byte or unique-association assumptions.

The [complete-binding consumer](10-complete-binding-query-contract.md) shares this
traversal and these fences, retaining its complete source set even when optional
stamp preparation reports an oversized omission. Its qualification is recorded
separately from the original stamp-only results.
