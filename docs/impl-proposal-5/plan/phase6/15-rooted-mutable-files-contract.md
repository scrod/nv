# P6.2 — Rooted mutable-file operations

Status: **in progress**. Coherent reads, creation, internal replacement and
rename/update candidates are integrated with the root actor.
The native exclusive-creation primitive and its Swift history/intent consumer
have local APFS/HFS+/HFSX qualification, including OS staging-directory ownership.
ExFAT and live-provider qualification remain separate gates.
Replacement, rename/update, complete source accounting and finalization
also remain exit gates in the [dependency-ordered plan](../phase6-plaintext-reconciliation-plan.md#6-p62--qualify-actual-mutable-file-operations).
The [qualification record](15-rooted-mutable-files-validation.md) distinguishes
executed checks from the remaining native capability work.

Active-presenter experiments led to one original-Delete accessor. The Runtime
now connects its live permission, durable reservation and protected removal;
its new receipt and recovery consumers have the local/platform qualification
recorded in the validation ledger. Actual-document/provider qualification
and P6.4 settlement retain their separate gates. See
[the coordination correction](#active-presenter-correction-and-direct-removal-adapter).

## Coherent read and ownership

`RepositoryRootSession.readProjection` consumes a live session's issued entry
observation and permission. It validates the direct-child projection leaf,
caller-selected byte budget, kind and single-link ownership before reserving the
existing root lane. Both admission and publication check the issuing session and
generation. The existing actor, coordination controller and serial executor own
the full entered operation through cancellation and close.

On Darwin, an immediately-available-metadata grant checks known dataless state
before a separate content-reading grant. Body access occurs inside the content
grant. Eviction between these grants can still delay the latter; cancellation
and resource lifetime follow P5.4/P5.5, rather than treating metadata availability
as a promise that content coordination will return immediately. See Apple's
[metadata-only option](https://developer.apple.com/documentation/foundation/nsfilecoordinator/readingoptions/immediatelyavailablemetadataonly).

`nv_projection_read` checks the actual named regular file, retains its no-follow
descriptor, copies bytes and metadata, and checks the descriptor revision, final
name and held root. The final name must still identify that exact observed
revision. A failed or interrupted read publishes no snapshot. Empty successful
reads remain distinct from missing/unavailable data. Stable intermediate states
exposed by an uncoordinated in-place producer retain the existing limitation;
this read does not claim to infer an editor's future writes.

`ProjectionFileSnapshot` has a file-private issuer and immutable, Sendable
fields. It carries exact bytes, validated name, permissions, integer filesystem
times, and raw encoding/OpenMeta/Finder/stamp attributes. Each attribute
distinguishes absent, present (including zero bytes), and unsupported filesystem
storage. Darwin uses the established exact attribute names; Linux reads the
corresponding `user.` namespace. That Linux adapter is local filesystem handling,
not evidence that a provider transports these attributes between platforms.
Creation time is optional on platforms whose observation API lacks it.

The body budget is supplied by the caller and checked against the actual observed
size and representable allocation length. A legal canonical note can expand when
encoded for a separate file, so the reader adds no 64-MiB encoded-file ceiling.
Native reads use bounded 1-MiB requests. Individual raw attributes are bounded by
the existing 64-MiB private-record ceiling; later canonical stamp parsing still
enforces its independent 4-KiB bound. Raw observation does not reinterpret invalid
encoding or tag bytes as absence. P6.3's semantic decoding/classification must
preserve the explicit unsupported/malformed outcome and the readable input.

A snapshot proves a past coherent read. The type issues no write/remove permission
and has no Codable initializer. Actual physical transitions still need their
intent-specific history barrier, fresh root/item checks and final accounting.
Persisted P6.1 descriptions cannot construct this live evidence.

## Native exclusive creation

`nv_projection_prepare` retains a same-volume, current-user-owned private
directory and exclusively creates a no-follow stage. It writes the exact bytes,
applies permissions and mandatory encoding/OpenMeta attributes (including
present-empty tags), sets requested dates, synchronizes the descriptor, and
independently reads back the bytes and metadata. Optional stamp and Finder-tag
write failures are reported separately. The native stage owner captures the held
root identity and exact stage revision.

Date qualification uses the held stage volume's documented representation:
HFS+/HFSX stores whole seconds; the other qualified adapters preserve the requested
nanoseconds. Stage readback checks that precise representation, including both
creation and modification dates, and installation checks it again exactly.
History retains the original logical dates. This is the user-approved
filesystem-rounding rule, not an arbitrary time tolerance or an inference from
whatever timestamp happens to be read. Failure to query the volume fails
preparation. Final exact body/attribute/date readback follows synchronization, so
coarse change timestamps alone cannot certify unchanged metadata.

`nv_projection_create` consumes that prepared state at a validated direct-child
name through native exclusive rename. A late destination occupant is preserved;
the caller receives a staged collision and must re-observe. The primitive verifies
the installed file through the same descriptor, synchronizes it, performs the
existing best-effort note-directory synchronization, and checks the final named
revision and held root before reporting installation. A syscall error after a
possible effect remains uncertain. Failure paths independently report root loss.
The native owner releases descriptors while preserving named artifacts for later
settlement; it never performs speculative cleanup.

The outcome distinguishes no effect, verified private stage, verified installation
and uncertain effects. A staged result describes retained preparation, not a note
save acknowledgement. The Swift bridge consumes `PreparedProjectionCreation`,
issued from an exact durable frozen output whose source and accepted observation
are absent. Its factory resolves accepted history and retained encoding bytes,
checks the live note and association, and binds the input to the store connection
and session. It supports first installation; transitions with an old source retain
their separate source-accounting gate.

`createProjection` reserves the existing root actor across suspension, verifies
the input's associated directory, and obtains Foundation's
`itemReplacementDirectory` on the held root's volume. The native stage checks that
directory's ownership, permissions and volume. `RootProjectionStage` has unique,
executor-confined ownership; its destruction releases descriptors while preserving
named artifacts. The successful result includes a coherent read of the exact
installed revision. Final consumers recheck the root, connection, association,
frozen input and live note. Newer intended C remains independently owned while
frozen B finishes. A Delete, reassociation, cancellation or root invalidation
during physical work prevents a verified completion and preserves retry input.

`ProjectionCreationReceipt` proves that physical installation under its original
attempt and root. It is distinct from accepted-history evidence and completed
projection settlement. This bridge changes no accepted/intended/frozen private
records; P6.4 retains transactional accepted-state advancement and source accounting.
The receipt consumer also checks the original attempt, so another independently
prepared token cannot reuse it. A subsequent physical effect still requires fresh
file validation.

Foundation's temporary directory is not guaranteed to survive application exit.
Durable frozen history/private byte owners provide retry contents; an opaque
`ProjectionStagingResidue` identifies temporary material for later owned cleanup.
Neither an uncertain result nor an equal existing destination clears that input.
This adapter does not claim temporary staging is an independent recovery archive.

Linux's local native adapter qualifies exclusive rename and modification-time
handling. A requested creation timestamp returns explicit `ENOTSUP`, preserving
the mandatory-date contract. That partial native result does not qualify the full
macOS note-output contract or a silent Linux fallback. APFS/ext4 observations do
not establish HFS+/ExFAT/provider behavior; volume and actual staging-directory
qualification remain prerequisites to enabling the corresponding Swift path.

## Remaining physical gates

### Native conditional replacement — qualification in progress

`nv_projection_prepare_replacement` opens and compares the exact expected source,
copies its metadata with `fcopyfile(COPYFILE_METADATA)`, then applies and verifies
the exact note-controlled output through the shared stage preparer. Permissions
must match the checked source. Explicitly absent advisory attributes are removed
from the copied stage. The opaque stage retains its source name/revision and
owning root; creation and replacement consume their respective stage kinds.

`NVAppleReplaceProjection` coordinates the stage for moving and the destination
as an ordinary update (`0`), using the qualified directory-relative URL constructor. The
native consumer rechecks the stage, source bytes/revision and backup-name absence
inside that accessor. It invokes Foundation once, reads and compares the actual
displaced backup, and uses creation's exact post-install body/metadata/name/root
checks. API errors after a possible effect remain uncertain. Separate backup
outcomes distinguish exact expected contents, changed contents and failed
observation. All displaced material remains at its owned name for the later
reconciliation/settlement consumer; this primitive performs no cleanup.

The adapter under qualification uses `UsingNewMetadataOnly` together with retained
backup. The stage already contains preserved custom metadata and exact requested
note metadata. The initial default-option test reduced verified mode 0640 to
0600; the alternate option preserved it. Absolute-URL normalization did not fix
the default-option case. This is an observed capability difference, not an Apple
contract-violation claim. The migration's separate provider-identity and complete
metadata qualification gates apply before enabling the public Swift replacement
path or replacing the legacy caller.

`prepareProjectionReplacement` now issues an immutable, issuer-restricted input
after validating both the accepted source and frozen output against retained
history. It recovers their exact encoded bytes, checks the same filename and live
note, and binds them to the store, connection, association and current-view
context. Its final applicability check permits newer intended C to remain owned
while frozen B completes. Reopening prepares fresh evidence from the retained
observations; prior-session evidence is rejected.

The native entry point and its Swift consumer remain internal while qualification
is completed. The consumer reserves a fresh random backup name, retires a
confirmed no-effect candidate, and enforces final root/store/input fences.
Fresh recovery inspection is described below; artifact settlement remains a separate gate.
The public creation receipt and its constructor remain unchanged. Native
results alone cannot establish a durable logical operation or completed
projection settlement. See the [legacy-test coverage mapping](15-rooted-mutable-files-validation.md#lessons-carried-forward-from-the-objective-c-tests)
for inherited behavior and the remaining qualification gates.

### Durable replacement candidate reservation

Before entering physical replacement or rename/update, retain one `ProjectionReplacementAttemptV1`
under `private_groups`, keyed by `projection-replacement/` plus the birth's 32
lowercase hexadecimal digits. The current codec and generation are both 1. The
record retains the exact frozen transition, local capture scope and association,
the attempt's random UUID, and passive root/source observations supplied by the
rooted adapter. Its backup leaf is derived as `.nv-replacement-<32 lowercase UUID
hex digits>.backup`; it is not another independently stored path. This adds no
SQL table or provider sidecar.

The existing serialized database transaction checks the connection, association,
live note, current view and unchanged accepted/frozen inputs before inserting.
It refuses to overwrite an outstanding reservation. A failed or ambiguous commit
issues no reservation evidence; any committed row remains discoverable. Reopen
validates the framing, scope, key and frozen owner, and presents the passive
record for fresh inspection. A newer intention or logical Delete preserves it.
The record identifies a candidate location, not proof that Foundation created
the occupant. A decoded record grants no replay, physical cleanup or installation
permission. The live `ReservedProjectionReplacement` has a restricted issuer and
checks its exact committed row plus the original input before physical use.

The single current v1 encoding is: `NVPRA1\r\n`, u16(1), private scope (64),
association ID (16), attempt UUID (16), a u32-length complete intended-transition
blob, then passive root and source records (each u32 codec and u32-length bytes).
Integers are big-endian; the existing 64-MiB private-record ceiling and exact-end
checks apply. A source is mandatory. Equal source/output filenames derive the
replacement operation; different filenames derive relocation. The existing slot
admits only one outstanding operation for that birth. The role is derived from
retained names rather than encoded as independently mutable state. Separate typed
factories/reservations/recovery consumers enforce each role. These are revisions
of the current unreleased v1 format, with no draft migration branch.
The physical consumer still supplies and interprets the platform observations;
the portable codec validates their bounded framing. Independent wire fixtures
live alongside the projection observation vectors.

Complete backup/repair preserves this required private input and its frozen byte
owners. Contradictory candidates for one birth require explicit recovery rather
than selecting one by arrival order. The rooted consumer retires a candidate
after a verified no-effect collision before reserving a fresh UUID. After an
effect, record release belongs to checked source/artifact accounting and final
settlement. Those post-effect consumers remain implementation gates.

### Rooted replacement consumer — internal qualification

`replaceProjection` consumes a live root-issued coherent source snapshot and a
store-issued `PreparedProjectionReplacement`. It checks the snapshot's issuing
root, filename and exact source bytes, reserves the root turn before suspension,
and verifies its current store/root association. Before preparation or replacement
it commits the candidate record and rechecks its exact ownership. Each reservation
gets a new UUIDv4, including retries using the same captured output token.

The record's root field retains the positively matched association bookmark.
Its source field uses passive codec `0x50524601`: nine big-endian u64 words from
the coherent observation (kind, device, inode, size, link count, modification
seconds/nanoseconds, change seconds/nanoseconds), followed by a 32-byte SHA-256
metadata commitment. The domain is UTF-8 `NV projection metadata\0v1\0`;
the material is UInt32 permissions, creation-time presence and exact integer
time when present, then raw encoding, OpenMeta tags, Finder tags and stamp in
that order. Attributes use 0 absent, 1 present with UInt32 length and exact bytes,
or 2 unsupported. This reuses the original-observation metadata layout. The
physical record is exactly 104 bytes. Raw metadata remains available through
the existing snapshot/accepted-field/source-attempt owners, without duplicating
it into this fingerprint. This revises the current unreleased v1 layout directly.
Reopening retains those bytes
for fresh inspection; it cannot turn them into a live snapshot or replay grant.

The existing root executor owns the stage and all synchronous Foundation work.
Creation and replacement share `ProjectionOutputMetadata`; replacement uses the
checked source's permissions and the native preserved-metadata preparation.
The adapter reads back the installed file and the actual backup against their
returned exact observations. Fresh installed readback also checks permissions,
creation time and raw mandatory/advisory metadata. The native result supplies
its verified, filesystem-rounded creation time so Swift compares the same exact
representation. Coarse stat timestamps alone never replace this comparison.
The caller supplies a displaced-body read budget;
an oversized/unreadable backup leaves the operation uncertain with its record and
contents preserved. The internal installed receipt keeps both observations,
their exact source-content comparison and separate optional metadata/barrier
outcomes. Source accounting and completed projection settlement remain distinct.

A completed native no-effect/staged outcome can issue the file-private
`UninstalledProjectionReplacement` proof. Its SQL consumer checks the original
store connection and exact committed candidate before removing that one record.
It preserves the frozen bytes and every filesystem occupant. Failed retirement
keeps the record for recovery; a subsequent call reports the outstanding attempt.
After an effect, cancellation, root loss, store changes or failed readback preserve
the candidate instead. Final store/root checks permit frozen B to complete while
newer intended C remains owned, but a logical Delete invalidates completion.

The consumer is internal until its recovery/cleanup, connected crash and complete
filesystem/provider gates pass. The initial integration tests use real creation,
history and replacement with an explicitly seeded passive accepted record because
P6.4's accepted-state settlement is still separate work.

### Recovery inspection

`prepareProjectionReplacementRecovery` reconstructs both exact comparison bodies
from the retained transition, validated history and any owned encoded-byte chunks.
Its file-private issuer binds the resulting `ProjectionReplacementRecoveryInput`
to the recovering store session, connection and exact committed attempt. Recovery
can inspect these inputs after a later edit or logical Delete; that read-only
purpose does not require the original birth to remain live.
The issuing store is recorded separately in this temporary input. A verified
private copy or sibling repair may retain an earlier capture scope through its
existing `repair-source/` provenance. The usual captured-scope validation checks
that record; the input's live store/session/connection checks identify the new
owner. The durable attempt bytes and historical source/output remain unchanged.

`inspectProjectionReplacement` matches the captured root bookmark against the
held root, reserves the existing root turn, then obtains fresh coherent reads of
the current filename and backup candidate separately. Each reports readable
contents, known placeholder, or its precise failure (including absence, wrong
kind, link ambiguity and size budget). A failure for one name leaves the other
name's observation available. Root loss and cancelled or stale operations fence
the whole result. Final checks require the same store connection, frozen owner,
attempt and live root permission.

The immutable `ProjectionReplacementInspection` represents two independently
coherent observations, not an atomic two-file snapshot or a completed save. It
retains its originating input and root permission through private fields; its
consumer names the recovery input and checks that exact candidate, session and
connection against the inspection's captured input before checking current
durable ownership. It never clears the candidate, releases frozen
bytes, starts a new replacement, reinstalls a backup or removes an occupant.
In particular a crash after reservation but before the accessor's absence check
can leave an unrelated backup-name occupant. Recovery reports those exact bytes
for preservation and later source accounting, rather than inferring ownership
from the stored name or matching contents. P6.4 still owns accepted-state
advancement; cleanup requires its own fresh, intent-specific proof.

| Operation | Required implementation / test before completion |
| --- | --- |
| Exclusive creation | Integrated history/frozen-input bridge, OS stage, actor fences and uncertain outcomes qualified as recorded; finish additional claimed volume/provider gates, including ExFAT permissions |
| Existing-file replacement | Internal history-bound Swift consumer, fresh UUIDv4 reservation/no-effect retirement and fresh recovery inspection under qualification; finish artifact cleanup/accounting, `NSFileOriginalItemLocationKey` fallback inspection, full metadata atomicity, provider identity and supported volume checks |
| Rename/update | Internal history-bound input, pinned original, durable shared attempt, exact receipt and three-name read-only recovery under qualification, including case-only/format paths; finish source/artifact accounting and full filesystem/provider gates |
| Original Delete removal | Direct single-accessor Runtime bridge, exact-capture receipts, owned-directory failure retention and real native crash/reopen cuts qualified as recorded; finish actual-document/provider gates before application enablement. P6.4 owner transfer remains separate |
| Finalize | Exact mandatory encoding/tags/dates and body, optional stamp result, source obligations and owned residue; callback errors cannot erase completed effects |
| Connected qualification | Real failure/crash schedules, compiler consumers, process and volume/provider checks; unchanged P6.1 record/history evidence reused explicitly |

### Native source quarantine — candidate under qualification

`nv_projection_quarantine_source` supplies the preservation step for future
rename-source accounting and original-operation removal. It first obtains the
coherent source snapshot through the existing bounded reader, checks its exact
original bytes and metadata, then exclusively renames that filename to a caller-reserved
recovery leaf in the held root. It reads the actual moved item and compares
identity, bytes, mode, creation/modification times and raw note metadata with the
original root-issued snapshot. The caller lends the descriptor transferred by
the original capture's coherent read and keeps it open through return. This pins
that inode from capture through the rename gap; the native consumer checks the
borrowed descriptor against the fresh preflight. Rename changes ctime, so the post-move comparison checks
those concrete contents and metadata rather than requiring the old ctime.

The result distinguishes five observed outcomes:

| Native result | Observed meaning |
| --- | --- |
| `NO_EFFECT` | Input or preflight failed before attempting the move |
| `CAPTURED` | The recovery leaf contains the exact captured source, freshly verified after the move |
| `RESTORED` | The actual moved item differed; an exclusive move returned it to the available source name |
| `RETAINED` | The actual item remains at the recovery leaf, including when another source occupant prevents restoration or reading is unavailable/oversized |
| `UNCERTAIN` | A syscall may have taken effect, final named evidence changed, or root checks failed |

Each result separately reports the source and recovery name as present, absent
or unavailable. Failed metadata access remains unavailable while the other name
can still supply its own observation. A new
occupant at the source name survives even when the old expected source was
successfully captured. A mismatch restoration always uses exclusive rename;
another occupant takes precedence and both streams remain available. This step
preserves all named contents for later accounting. Releasing retained contents
requires the later ownership and settlement consumer.

The internal original-Delete consumer now supplies the durable reservation,
original local barrier and fresh root/file context described below. Rename/move
issuance and final source accounting retain separate gates. Owned original-Delete
artifact cleanup is implemented at its distinct boundary below. The
filesystem result alone supplies none of those logical permissions.

#### Final public destination and active editors

The presenter probe also invokes this existing native move adapter with
`Moved.txt` as the final public destination. It requires one explicit successful
move notification, the editor's URL changing to that destination, and a later
editor save affecting only that filename. A dirty draft remains in its editor;
the physical move preserves the exact captured on-disk contents. An occupied
destination stops before any move and preserves both streams. Equivalent
Foundation URL representations and foreign-root grants retain the same namespace
checks as other adapters.

This qualifies the native/public-presenter part of an ordinary rename, rather
than issuing a logical rename permission. Frozen-output integration, independent
source obligations, case-only changes and format/content-changing moves still
require their dedicated consumers. Source-preservation recovery names remain
distinct from the final user-facing destination. Filesystem-discovered movement
is observed separately from the adapter's required explicit notification.

### Native rename/update candidate

`nv_projection_relocate` consumes the privately prepared replacement stage, its
exact original source observation and pinned descriptor, a distinct destination
and reserved backup name. It checks the granted stage descriptor against the
owned stage, source/stage binding, complete prepared bytes/metadata, root and
destination before capture. An occupied destination is allowed only when it
addresses the same single-link original through its case/Unicode spelling.

The existing source-preservation primitive captures the actual original into
the backup and compares its complete state. Only a matching capture permits
exclusive installation of the prepared output. Both ordinary and case-only
paths use native exclusive rename. The old file stays retained; a late source
occupant remains independent. A known destination refusal restores the backup
exclusively when possible; an occupied original keeps both streams named.
I/O errors that may follow an effect retain uncertainty and all artifacts.

Source and installation results are separate. Final output/body/metadata/name
checks use creation's existing verifier. Backup substitution changes source
classification; it does not erase an independently verified installed output.
The caller must freshly inspect/account for both streams. A successful physical
result never clears accepted/intended/frozen private owners.

`NVAppleRelocateProjection` encloses the public source (`.forMoving`) and
exclusive destination (`0`) in the synchronous two-write accessor, then uses
that method's documented permitted single-write nesting for the private stage.
Every granted public name must belong to the exact held root. The stage grant
must identify the owned prepared descriptor. Internal preservation moves emit
no logical notices; a verified installation notifies the final public move.
Coordination errors after entered work preserve its observed effects and report
uncertainty.

Presenter tests independently verify exact file identity and later save targets.
For case-equivalent names the framework can retain the old URL capitalization,
as the direct coordinated control also does. NV's explicit notice and actual
on-disk spelling remain required. Distinct names retain the exact final URL and
move-delivery checks; another document at an occupied destination stays open.

`prepareProjectionRelocation` issues a distinct immutable input after checking
both exact historical values, the live note, accepted/frozen relationship,
association and current store/view/connection. Source and output filenames must
differ; same-name replacement keeps its own input type. Newer intended C remains
independent of frozen B. The root rereads and pins the accepted original through
the existing descriptor lease, then commits a fresh UUIDv4 candidate in the
existing per-birth attempt slot before native work. Reservation failure grants
no physical entry; a committed candidate remains discoverable after interruption.

The root reserves its existing turn across suspension. Native installation and
fresh readback retain final root, connection, frozen-owner and live-note fences.
The internal receipt retains exact installed/backup snapshots, an independent
original-name observation, the original descriptor lease and the exact prepared
operation token. Its source comparison checks bytes and complete metadata while
allowing the rename's own ctime change. Source/backup interference never grants
cleanup permission. A later Delete, invalidated root, cancelled operation or
lost ownership prevents completion and preserves the candidate/frozen bytes.

`prepareProjectionRelocationRecovery` rechecks retained history and issues fresh
session/connection-bound read-only evidence, including after a later edit/Delete
or verified private copy. `inspectProjectionRelocation` reports source, output
and backup separately, with per-name absence/placeholder/failure outcomes. Its
consumer checks the exact candidate and live root/store again. Recovery evidence
cannot enter either physical transition, and same-name recovery rejects a
relocation record. A decoded record grants only the locations to inspect.

Foundation may return canonical decomposition for an accented requested leaf.
Namespace checks compare canonical spellings with case preserved and still
require the exact held root. Native descriptor-relative operations use the
frozen name and retain their exclusive destination/identity checks. A changed
accent, other leaf or foreign root remains a rejected grant.

The live input, reservation, result, original-lease and recovery constructors
remain restricted to their issuing files. Both operations use the existing
single current attempt encoding and slot; this adds no table, sidecar or
long-lived validation state. P6.4 still owns accepted-state advancement,
source settlement and post-effect artifact retirement. Application enablement
retains the full physical/provider qualification gates.

An uninstalled-output result alone cannot issue no-effect retirement evidence
for a relocation. Capturing and restoring the source already changed its
physical observation; a retained/restored source still requires fresh accounting.
The separate same-name replacement retirement proof cannot substitute for that
obligation. A case-only late source may occupy the target's alias or survive
as a distinct entry on a case-sensitive volume; both require exact observations.

### Original local Delete permission — internal implementation

The Runtime separates three live, immutable inputs:

1. `prepareProjectionDeletion` issues `PreparedProjectionDeletion` while the
   captured local command and complete checked current view still apply. The
   command must contain a Delete for this birth. It resolves the accepted
   source's exact history and encoded bytes, captures the association and private
   observation generations, and rejects an unfinished frozen file transition.
   That transition's source obligations remain the later move/settlement path's
   responsibility.
2. `captureProjectionDeletion` issues `CapturedProjectionDeleteSource` under the
   live root. The coherent file must match the accepted filename, exact bytes and
   locally recorded physical observation (`0x50524601`, nine words plus the
   complete metadata commitment). It rereads under coordination and retains the
   descriptor from that same successful read. The association bookmark must identify this root. Both admission
   checks and final checks require the same pre-Delete current view; history
   changing during root matching or the retaining read invalidates the capture.
3. After ordinary persistence, `authorizeProjectionDeletion` issues
   `AuthorizedProjectionDeletion` only for that capture's locally issued
   `AcceptedHistoryReceipt`. The receipt privately carries its original command
   ID in addition to its existing store/session, object, acceptance sequence and
   covered generations. Another command's receipt is insufficient, even with
   identical covered generations. The issuer independently checks the complete
   accepted action and the receipt's exact checked envelope/sequence, unchanged source owners, and a
   fully caught-up view in which this birth is absent.

   A received equivalent envelope may accept that action before the original
   local envelope commits. Both envelopes remain retained. The command's first
   stored action occurrence may then belong to the earlier envelope, independently
   of the exact envelope named by the local receipt. Verify both roles rather
   than requiring the same first-acceptance sequence or locator.

All constructors stay file-private, and root/store consumers check the same
session, connection, association and source ownership. An unrelated subsequent
edit may proceed; restarting the store invalidates these live inputs. Passive
observations and historical receipts cannot reconstruct the original capture.
One file-private, compiler-checked `Sendable` resource owner shares that
descriptor across the immutable capture, authorized input and retry/result
copies. Its last release closes it exactly once. Failed capture, cancellation
and stale-context returns release their unissued resource. Ordinary file reads
still close their descriptors immediately. Descriptor exhaustion is a file
failure, with no reopen-based fallback. A live capture can retain the descriptor
after root closure, but the invalid root generation prevents further effects;
the lease itself neither retains root ownership nor survives process restart.
Large multi-file commands still require bounded admission/resource qualification
before being exposed by a batch driver.
The permission checks establish logical applicability. The internal consumer
below connects them to a durable reservation and coordinated protected removal.
P6.4's accepted-state producer is still pending;
the permission tests explicitly seed its passive accepted description from a
real coherent file plus checked history. The private source-attempt record below
stores recovery inputs, while the original permission remains session-bound.

The physical integration compares both preflight and actual moved observations
with the complete original root-issued snapshot. Coarse timestamps can leave all
nine words and body bytes equal after a metadata change, so raw metadata, mode
and supported dates receive their own comparisons. Native `CAPTURED` alone
cannot settle the original-source obligation.

### Durable original-source reservation and inspection

`reserveProjectionSource` consumes the live `AuthorizedProjectionDeletion` and
commits one `projection-source/<birth>` required-private row before physical
entry. `ProjectionSourceAttemptV1` retains the exact accepted source, accepted
Delete action occurrence, captured root/association and complete original
observation. Its UUIDv4 key derives `.nv-source-<hex>.backup.cleanup/item`.
The record shares the existing
private table and byte/history owners. The single current v1 layout is specified
in [private records](../private-record-contract.md); no provider sidecar is added.

`removeProjectionSource` reserves its existing root turn before suspending,
checks that the recorded association identifies that root, commits the candidate,
then repeats owner/context checks before entering the native operation. On macOS
an operation-local `NSFileCoordinator` accessor uses `.forDeleting` on the source
and `0` on the exclusive protected child. Exact component/root checks accept
legitimate normalized grants and reject redirects. The accessor performs the
complete protected capture, comparison and matching removal. Linux uses the
same native algorithm under its root owner. Internal preservation moves remain
implementation details; genuine public renames retain their own notifications.

After return, the original name and protected child are independently observed.
`ProjectionSourceRemovalReceipt` requires their checked absence and the same
live store/root/command. An issuer-restricted `UncapturedProjectionSource` can
retire the exact candidate only after a no-removal result that created no owned
directory. A foreign occupied candidate stays untouched and a later attempt uses
a fresh UUID. Native `directory_created` records exclusive acquisition, including
an empty directory surviving a later failure. That result retains its required
attempt and owners. Successful removal likewise retains the attempt until later
settlement. Directory-sync errors remain separate from the physical result.

After restart, `prepareProjectionSourceRecovery` validates the retained action,
source owner and captured scope, then reconstructs exact comparison bytes from
accepted history/private chunks. A verified private copy may preserve the
original capture scope via `repair-source/`; newly issued inputs bind to the
current live store, session and connection. `inspectProjectionSource` reads the
source and protected child under fresh root checks and repeats the exact private
record check before returning. Its immutable inspection is bound to that input.
Neither recovery input nor inspection reconstructs the old removal permission.

Opening/complete backup/repair validate and retain these required records.
Source settlement must still account for every observed
stream and transfer its byte owners atomically. These consumers, rename/update
integration and the large multi-note command-validation/resource bounds remain
required before enabling
the full application removal path.
Both original-Delete capture and existing-file replacement compare the complete
accepted physical record before reservation/effect. The metadata commitment
detects earlier raw-metadata changes even when stat words coincide on coarse
clocks. P6.4 must produce that record from its verified accepted observation and
retain its separate publication/source-accounting checks. Matching the captured
state still requires the original-operation identity-lifetime checks; the digest
is state equality evidence, not a permanent physical incarnation identifier.

### Owned original-source cleanup

**The earlier public-name unlink candidate failed the required final check/use schedule.** A
real child writer can replace the recovery leaf after its final `fstatat` and
before `unlinkat`; that candidate deleted the new file and reported removal.
`LAST_UNLINK_REPLACEMENT` remains a preservation assertion, not an accepted
limitation. The replacement implementation captures the public artifact before
private cleanup. Its qualification is recorded separately from the invalidated
22/25-case results. It remains internal until the relevant gates pass; P6.4
source-accounting/settlement and application enablement remain separate.

`removeProjectionSource` consumes the still-live `AuthorizedProjectionDeletion`
from the original local Delete. The source-attempt record must remain exact,
its original command barrier and accepted relationship must still apply, and
its root/session must remain live. `NVAppleRemoveProjectionSource` encloses
protected capture and removal in one deletion accessor. The native consumer rereads complete
bytes/raw metadata and checks the borrowed original descriptor before capture.
It exclusively creates `<recoveryName>.cleanup` at mode 0700, removes inherited
Darwin ACLs, retains its no-follow directory descriptor and checks its current
root membership, owner, permissions and volume. It synchronizes that directory
and the root before moving any source bytes into its fixed `item` child.

The approved UUIDv4 backup-name assumption concerns creating an **unseen** name
after an absence check. It does not exempt replacement of an observable retained
artifact before cleanup. No broader producer exclusion is adopted. The final
check and unlink are separate syscalls, so another check alone cannot satisfy
the required no-foreign-removal guarantee. The implementation instead preserves
the actual displaced item before deciding whether it can be deleted.

Capture the **actual** public artifact into that directory by exclusive rename,
then compare its full coherent state with the pinned original. Only an exact,
privately owned captured item can be cleaned. A mismatch is restored exclusively
while the parent/child context still applies, or remains named and recoverable;
another public occupant survives. Synchronize both directories after capture
before entering cleanup. An occupied directory candidate is preserved and stops
this attempt; opening an old directory never reconstructs cleanup ownership.
Directory substitution or lost context after capture yields uncertainty and
preserves retained bytes. Empty protected directories stay owned by the attempt
until later settlement; this increment adds no speculative directory collection.

The required record determines both locations; its encoding is unchanged. Fresh
inspection reads the original note name and protected `item` independently. A distinct,
issuer-restricted `ProjectionCleanupSnapshot` describes the nested read-only
artifact; it cannot be supplied as a direct-child note snapshot. All observations
retain their live root and exact recovery-input context. The existing original
descriptor retains its caller's sole close ownership throughout.

The protected child follows the same owned-private-namespace producer contract
as staging: NV controls its entries while the live operation holds it. This is
distinct from the exposed public artifact, whose replacement remains a mandatory
race test. Moving/deleting/replacing the enclosing directory is detected through
its held descriptor and current membership; fresh inspection reports inaccessible
or contradictory evidence rather than trusting the derived name. Supporting a
filesystem/provider requires qualifying this ownership/privacy/capture boundary.

Fresh protected inspection checks the observed kind and single-link ownership
before requesting content access or applying a body budget. A directory,
symlink or hard-linked item therefore keeps its specific collision/ownership
outcome even with a zero-byte budget. The failed low-budget companions exposed
an omitted typed-boundary check; neither error classification nor supported
file ownership was relaxed to accommodate Linux.

The root owner reads source and protected child after return and repeats the exact
private-record, command and lifecycle fences. An artifact that reappears prevents
a removal receipt at either location. A changed owner, cancellation or unavailable final evidence
returns uncertainty. `ProjectionSourceRemovalReceipt` has a file-private issuer,
binds its exact original capture and live permission, and carries these observations
for later accounting. Its consumer checks the existing descriptor-lease object's
identity, in addition to the exact Delete reference and live reservation. Two
independently read captures of the same file/command cannot exchange receipts;
copies of the actual capture keep their original lease. This adds no identifier
or tracked identity registry.

Removal never advances accepted projection or releases its byte owners. Its
source-attempt record remains required, including when the original was already
removed or an empty owned directory survived a failure. Only the narrowly
verified pre-capture no-owned-directory candidate can be retired here. Fresh-process
recovery inspects the record and current names; it cannot issue removal permission.
A second removal encountering the retained attempt is busy, rather than replaying
the physical operation. P6.4 must freshly account
for every observed source stream and atomically publish its own settlement;
the removal receipt is an earlier physical result, not that settlement.

### Active-presenter correction and direct-removal adapter

`ProjectionFilesPresenterProbe.m` registers a real `NSFilePresenter`, supplies
its serial operation queue and self-presenter coordinator, and exercises close,
dirty-save, refusal and keep-open choices plus a subsequent coordinated save.
It found two concrete mapping errors. `WritingForReplacing` asks an ordinary
save's peer editor to accommodate deletion; content safe saves must use `0`.
Also, the earlier source-to-public-recovery-to-protected sequence can redirect
an editor to an implementation-private name, which it may recreate after cleanup.
Simply changing flags while retaining separate accessors does not fix that path.

`NVAppleRemoveProjectionSource` instead coordinates `.forDeleting` on the
original public source and `0` on the protected child. Within one accessor,
`nv_projection_remove_source` uses the existing protected capture/compare/restore
algorithm, with the protected directory derived from the durable attempt key.
Only the exact matching private item is unlinked. Internal preservation moves
emit no logical move notices; actual public renames still require their own
notifications. Both accessor grants must name the exact components under the
issued root reference, including legitimate Foundation-normalized representations.

A dirty peer saving before deletion changes the original snapshot and blocks
removal. Refusal leaves the file. A peer that keeps its document open can later
recreate the original public filename, just as in the direct Foundation deletion
control; that is subsequent external work, not replayable deletion permission.
The tests inspect all retained bytes and the actual later save destination.
They exercise protocol interoperability, not a full AppKit `NSDocument` UI.

The single-accessor Runtime consumer retains the original reservation/barrier/
descriptor and fresh-inspection fences. The intermediate capture/result layer,
second cleanup method and its native wrapper are retired. No persistent field
or table is added. A test-only syscall interposer stops the actual Swift child
before capture, after capture and after unlink, or fails protected-directory
synchronization. Fresh processes recover solely from surviving storage; separate
changed/malformed fixtures retain their own classification. The strengthened
compiler and mutation probes cover the new receipt and pre-capture retirement
boundaries. Actual document/provider qualification and P6.4 settlement remain gates.

The P5.6 stop-and-Save-As policy applies to occupied damaged repository entries.
It does not replace the mutable-note contract. The legacy Objective-C caller and
all UI paths remain unchanged until their separate migration gates pass.

The [backup-name experiment](15-rooted-mutable-files-validation.md#backup-name-assumption-and-api-limit)
records Foundation's documented removal of a deliberately injected same-name
occupant. The user retained the migration's original fresh-random-name assumption.
Production must use a new UUIDv4 name for each attempt, check absence inside the
accessor and retire every observed occupied candidate. Deliberate injection at
that exact private name is outside this assumption. The source/target races and
retention of actual displaced contents remain mandatory. The native adapter
remains unavailable through the public Swift replacement API while its remaining
implementation and qualification gates are completed.

## Model correspondence and reuse

`ProjectionTransitionSafety` and `ProjectionRecoveryBridge` treat coherent file
observation and exact physical effect verification as environmental inputs. These
slices qualify part of that input boundary without changing model transitions,
history rules or safety assertions. Existing finite model results remain scoped
evidence; concrete replacement/removal qualification is recorded separately
in the validation ledger.

P6.1's canonical bytes, history binding, frozen owners and settlement-record
qualification remain applicable to unchanged files and consumers. The new read
primitive receives its own native, actor-lifecycle and compiler-boundary tests;
the completed P6.1 cross-product is not rerun merely because this adapter exists.
