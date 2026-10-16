# P6.1 — Complete-binding queries and owned output recovery

This connects the complete descriptor to the existing
[standalone source reader](07-inbound-history-contract.md) and
[private output owner](09-exact-output-contract.md). It introduces no encoding,
table, persistent index or validation cache.

## Accepted descriptions and checked sources

`projectionDescriptions(in:basedOn:)` reads one explicitly selected accepted
Changes envelope at the captured prefix. A not-yet-accepted object returns `nil`;
an accepted object containing no descriptions returns an empty array. Exact
locator mismatch is `wrongContext`. Actual damage in retained bytes or indexed
occurrences retains the established history-damage/verification-request outcome.
The shared checked-envelope reader opens the source once, checks complete indexed
records and returns its passive description members. A result is historical
provenance, not an installed-file receipt or a filename winner.

`projectionHistory(for:basedOn:)` now accepts either a bounded stamp or a complete
binding. Both use the same source traversal, dependency classification,
ordinary/equal/merged/automatic validation and final current-view fence. The
complete-binding path never constructs an intermediate stamp or truncates a
represented set. Exact file encoding, filename occupancy and unique applicability
remain separate physical checks.

The file-private issuer creates `CheckedProjectionBindingHistory` with immutable
binding and Current relationship. Source contents, captured view and connection
remain private. `projectionValue(fromBinding:basedOn:)` checks store, session,
connection, accepted prefix and current-view generations again before returning
contents. Decoding an ordinary `ProjectionBindingV1` cannot satisfy that consumer.
The existing stamp API and its evidence type remain intact. Shared functions
enforce the same relation and consumer fences for both types.

Later history can leave a valid source different from Current, or absent after a
Delete. Its historical contents remain recoverable; reading them does not restore
the birth or cancel the Delete. Wrong claims remain distinguishable from missing
history, rejected prerequisites and actual corruption.

## Complete owned output

`projectionBytes(for:observations:basedOn:)` accepts only an exact output named by
the current private accepted/intended/source description. It checks the captured
private generation and current view before and after asynchronous work.

- UTF-8: validate the complete historical binding, obtain its exact retained body,
  and check the descriptor's output digest. Historical title/body spelling is
  preserved. This also works after the birth has been logically deleted.
- Captured native encoding: read the existing bounded private chunks and verify
  the exact aggregate digest. Reopening on another platform reuses those bytes.

Digest work runs on the existing historical worker. An intervening intent change
invalidates the output result even if the note/history itself did not change.
Foreign ownership, stale view/private generation, missing required input and
corrupt output retain distinct outcomes. Private output corruption does not by
itself mark otherwise valid immutable history damaged.

## Qualification and remaining boundaries

[Qualification](10-complete-binding-query-validation.md) includes the actual
oversized source, each source variant, independent bytes, held reads, exact
locator checks, private-generation races, fresh reopen/process checks and issuer
probes. Existing TLA+ history and captured-input predicates are unchanged; no
modeled guard or assertion was relaxed.

Portable local production still needs admission/reservation/exact retry. Frozen
settlement ownership and encoded-byte release remain P6.1 record work. Physical
receipt issuance and installation/settlement consumers remain P6.2/P6.4.
