# P6.1 — Captured filename preparation

`ProjectionFilenameV1` selects an output leaf from an immutable capture of format
extension settings, the note's current leaf, other notes' actual leaves, and the
complete observed directory names. The result enters the existing
[history-checked intention transaction](03-history-observation-contract.md).
The rooted caller subsequently checks current occupancy and filesystem limits.

## Policy and source correspondence

Preserve `NotationDirectoryManager.uniqueFilenameForTitle:fromNote:` and the
extension settings in `NotationPrefs`:

1. Replace title `/` with `:` and an initial `.` with `_`. The admitted title is
   nonempty; the application's localized untitled-note choice stays at its host
   boundary. Reject an empty title or embedded NUL.
2. Retain the current leaf's extension, including its case, if allowed by the
   captured format settings. Otherwise use that format's selected extension.
   An allowed empty extension preserves extensionless output, without adding a
   dot. Validate the settings before preparing a name.
3. Reserve `5 + extension UTF-16 count` below 255 UTF-16 units, matching
   `NSString_NV.filenameExpectingAdditionalCharCount:`. End a truncation before
   a split surrogate pair; retain the legacy unit-count rule for combining text.
   Reject a suffix or extension that exceeds the budget.
4. Compare the candidate basename against other notes' basenames, even when
   their formats differ; compare its complete leaf against directory occupancy.
   Use the existing Foundation case-insensitive comparison. On collision, remove
   the original stem's final extension and try `.1`, `.2`, and subsequent suffixes.
5. Exclude only the exact current leaf from the captured occupied set. An
   inventory containing duplicate, case-aliased or normalization-aliased entries
   is explicitly ambiguous before that exclusion. Reserve `NV Data`,
   `Notes & Settings` and `Interim Note-Changes` as occupied names.

Sort the two captured name sets once and use binary search per candidate. Each
failed candidate consumes a distinct captured name, so the attempt bound is the
sum of those set sizes plus the initial candidate. Preparation performs no
filesystem enumeration. The later catalog transaction owns completeness and
generation checks; the helper owns only deterministic naming within its inputs.

`ProjectionLeafNameV1` retains exact output spelling. Normalization is a collision
comparison, never a rewrite of a selected or observed name. Filesystem byte-length,
kind, symlink and newly occupied-name checks remain the physical adapter's work.
No note identity, operation hash, wire format, persistent field or public physical
permission is added by this helper.

## Validation

The [qualification ledger](04-filename-preparation-validation.md) covers literal
independent naming examples, boundary and ambiguity cases, growing captured
inventories, and a production intent/reopen witness. Ordinary and same-module
compiler probes keep captured policy, selected leaf and issued intent distinct.
The existing projection models' generation/source-accounting conditions remain
unchanged; physical catalog/installation witnesses belong to P6.2/P6.3.
