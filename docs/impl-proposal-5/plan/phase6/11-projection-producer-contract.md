# P6.1 — Local portable-description producer

The producer freezes a description of an already retained output. It uses the
existing Changes section, writer-address reservation and durable receive queue.
The [completion ledger](06-completion-ledger.md) separately tracks physical
settlement and captured-byte ownership.

## Preparation and ownership

`prepareProjectionDescription` consumes one exact output owned by a checked
private observation capture. The existing whole-output reader checks the source
history and output digest, including captured native-encoding bytes. Preparation
reserves a unique writer address before sealing and rechecks the current view,
private generation and session after sealing. Its immutable, issuer-restricted
handle owns the exact sealed bytes and locator. A failed preparation issues no
handle; an unused reserved address is harmless.

Preparation is caller-owned, like received input before its retention transaction.
The caller retains the handle through an unsuccessful persist attempt. Persist
uses the existing receive reservation before suspension. Once candidate retention
commits, the ordinary object/ready rows own recovery independently of the handle
or callback. No new table, journal, actor state or shutdown exception is needed.

## Acceptance, retries and subsequent edits

`persistProjectionDescription` accepts only a handle issued by the same live
store session. It passes its exact sealed bytes to ordinary receive validation.
The complete source/dependency, membership and retention transaction remains the
acceptance authority. Success issues a distinct description receipt containing
its exact locator, binding and acceptance sequence. Every pending result returns
the same handle. Retrying never seals again. Concurrent receive ownership reports
busy; cancellation and storage errors preserve the caller's handle and any
already committed candidate/ready rows.
Separate successful preparations reserve separate envelopes even for the same
output. Their descriptions share the same source identities and have zero logical
action effects; retry of one handle or retained candidate preserves its own exact
envelope identity.

A later edit, Delete or replacement intention may precede acceptance. The frozen
description still names its original historical value; it never substitutes the
new Current or clears pending private work. Reopening drains committed candidates
through normal startup recovery. A handle from an earlier session is rejected;
the surviving store determines committed membership. Receiving or accepting this
metadata emits zero note operations/actions and installs no file receipt.

## Qualification obligations

Exercise UTF-8 and captured native output, old descriptions after newer edits or
Delete, concurrent preparations with distinct reserved addresses, wrong store and
reopened sessions, changed preparation inputs, repeated retention/acceptance
failures, lost callbacks, cancellation and exact retry. Inspect actual envelope
bytes, dependencies, acceptance sequence, note/action counts and private intent.
Fresh-process recovery receives only normal selection/unlock inputs. Separate
client and sibling-file probes challenge handle/receipt construction and mutable
fields. Targeted mutations must fail the intended assertion with valid companions.

The existing models' metadata-neutrality and atomic dependency-retention premises
are unchanged. Actual file installation and receipt-driven settlement retain the
P6.2/P6.4 gates.

## Retention coverage

Preparation captures the accepted **Changes** tips in the existing retained
frontier under the same checked current prefix/private generation as the output.
Their exact locators join the source-binding dependencies in the envelope's
existing canonical dependency table. Snapshot roots keep their separate existing
retention mechanism. This adds no format version, persistent field or index.

Source bindings still identify exactly the represented note value. Additional
dependencies cover retained history without selecting note revisions or creating
operation/action parents. Received descriptions wait for every exact dependency.
`CheckedProjectionCoverage` opens the additional accepted Changes parents under
the owned history prefix, checks their supported payloads, and preserves their
exact bytes in short-lived file-private evidence. Acceptance checks those same
bytes/address/membership and connection/prefix again inside its transaction.
Previously accepted dependency closure is reused; ancestors stay retained and
remain subject to existing on-demand damage detection and verification reminders.

The ordinary atomic dependency/frontier update removes only declared parents.
Two concurrent captures can leave two tips; a later capture can cover both.
History arriving after capture leaves the frozen bytes unchanged. A sequential
description chain consequently leaves one Changes tip, alongside independently
required snapshot roots. Wide or genuinely independent tips require corresponding
work; this is a bound in terms of the live frontier, not constant-time SQL.

The [retention qualification](12-projection-retention-validation.md) separates
startup leaf checks, acceptance work and exceptional full reconstruction. It
preserves all earlier producer race/retry requirements and tests corruption before
and after parent verification. Physical installation remains a separate gate.
