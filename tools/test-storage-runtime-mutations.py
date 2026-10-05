#!/usr/bin/env python3
"""Isolated production-source mutations with exact runtime-assertion attribution."""
import argparse
import difflib
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('bootstrap_mutations', ROOT / 'tools/test-bootstrap-mutations.py')
helpers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helpers)
R = 'Sources/NVStorageRuntime/'
T = 'Tests/NVStorageRuntimeTests/'
# (name, file, original, replacement, test file, function, exact assertion)
MUTATIONS = [
    ('pending-stale-current-coverage', R+'PendingFiles.swift',
     '''guard try db.rows("SELECT reducer_version,through_seq FROM view_meta WHERE singleton=1") ==
                [[.integer(1), .integer(db.acceptedThrough())]] else { throw StorageError.incomplete }''',
     '_ = try db.acceptedThrough()',
     'StorageHealthTests.swift', 'neutralPendingWaitsForAcceptedDeleteMaterialization',
     'await #expect(throws: StorageError.incomplete) {'),
    ('verification-no-admission', R+'Verification.swift',
     'try database.run("INSERT INTO private_groups VALUES(?,1,1,?)", [.blob(record.key), .blob(record.encoded)])',
     '_ = record.encoded',
     'VerificationTests.swift', 'verificationSiblingSettlementPreservesOtherRequest',
     'try #require(original.count == 1)'),
    ('verification-sibling-settlement', R+'Verification.swift',
     'try run("DELETE FROM private_groups WHERE group_key=?", [.blob(admitted.record.key)])',
     'try run("DELETE FROM private_groups WHERE group_key>=X\'766572696669636174696f6e2f\' AND group_key<X\'766572696669636174696f6e30\' AND ?>=X\'\'", [.blob(admitted.record.key)])',
     'VerificationTests.swift', 'verificationSiblingSettlementPreservesOtherRequest',
     '#expect(try await lane.perform { try $0.rows(reminderQuery, reminderRange) } == original, "B settles only its own request")'),
    ('verification-skipped-replay', R+'Verification.swift',
     'while let record = try await perform({ db -> VerificationRecord? in',
     'if selection.descriptor.collection.bytes.count == 16 { return }; while let record = try await perform({ db -> VerificationRecord? in',
     'VerificationTests.swift', 'verificationCancellationReplaysExactScope',
     '#expect(try await nextLane.perform { try $0.rows(reminderQuery, reminderRange) }.isEmpty)'),
    ('traversal-occurrence-omitted', R+'GraphMaterialization.swift',
     '''guard actualOps == payload.operations.enumerated().map({ [.integer(Int64($0.offset)), .blob($0.element.operation.id.bytes)] }),
                          actualActions == payload.actions.enumerated().map({ [.integer(Int64($0.offset)), .blob($0.element.action.id.bytes)] }) else { throw StorageError.integrity }''',
     'guard actualOps.count >= 0 && actualActions.count >= 0 else { throw StorageError.integrity }',
     'HistoryTraversalTests.swift', 'traversalDetectsExactIndexedRelationshipDamage',
     'await #expect(throws: StorageError.integrity) { try await lane.snapshotHistoryGraph(through: 3, selection: selection, protection: protection) }'),
    ('recovery-stale-target', R+'GraphMaterialization.swift',
     'purpose == .opening ? accepted == target : accepted >= target', 'accepted >= target',
     'HistoryTraversalTests.swift', 'recoveryGraphPreparationRechecksFinalContext',
     '#expect(work.stages.values.reduce(0) { $0 + $1.graphLoads } == (interference == "settings" ? 1 : 2))'),
    ('recovery-stale-epoch', R+'GraphMaterialization.swift',
     'try db.rows("SELECT through_seq,epoch,reducer_version,authoring_context FROM view_meta WHERE singleton=1") == start,',
     'try db.rows("SELECT through_seq FROM view_meta WHERE singleton=1") == [[start[0][0]]],',
     'HistoryTraversalTests.swift', 'recoveryGraphPreparationRechecksFinalContext',
     '#expect(work.stages.values.reduce(0) { $0 + $1.graphLoads } == (interference == "settings" ? 1 : 2))'),
    ('ordinary-route-undo-as-current-row', R+'OrdinaryDatabase.swift',
     '''case .savedEdit, .rename, .labels, .createImportBatch, .deleteBatch, .restoreBatch: .currentRows
        case .historicalRecovery, .conflictChoice, .conflictCopy, .undo, .redo, .nativeUndo: .noteGraph''',
     '''case .savedEdit, .rename, .labels, .createImportBatch, .deleteBatch, .restoreBatch, .undo: .currentRows
        case .historicalRecovery, .conflictChoice, .conflictCopy, .redo, .nativeUndo: .noteGraph''',
     'StorageReviewTests.swift', 'materializationRoutingCoversEverySupportedVariant',
     '#expect(MaterializationRoute.forAction(kind) == .noteGraph)'),
    ('reconstruction-omitted-tail', R+'GeneralSnapshots.swift',
     'let outside = Set(graph.operations.keys).subtracting(represented)', 'let outside = Set<OperationID>()',
     'BootstrapReconstructionTests.swift', 'reconstructionIncludesBranchesOnBothSidesOfSnapshotAcceptance',
     '#expect(rebuilt.notes.map(\\.value.body.string).sorted() == ["off-cut F", "snapshot E"])'),
    ('reconstruction-envelope-as-cut', R+'GeneralSnapshots.swift',
     'represented = verified.0.operationIDs',
     'represented = Set(graph.operations.filter { preview.historyLocators.contains(graph.operationReferences[$0.key]!.locator) }.keys)',
     'GeneralSnapshotRuntimeTests.swift', 'generalSnapshotTransportMembershipKeepsUnrepresentedGroup',
     '#expect(isolated.notes.map(\\.value.body.string).sorted() == ["E", "F"])'),
    ('reconstruction-stale-target', R+'GeneralSnapshots.swift',
     '''guard try db.snapshotBootstrap() == bootstrap, try db.acceptedThrough() == target,
                  try db.rows("SELECT epoch,reducer_version,through_seq,authoring_context FROM view_meta WHERE singleton=1") == start else {''',
     'guard try db.snapshotBootstrap() == bootstrap else {',
     'BootstrapReconstructionTests.swift', 'reconstructionRepreparesAfterSaveAndPreservesLivePendingWork',
     'let rebuilt = try #require(try? await task.value)'),
    ('reconstruction-stale-epoch', R+'GeneralSnapshots.swift',
     'try db.rows("SELECT epoch,reducer_version,through_seq,authoring_context FROM view_meta WHERE singleton=1") == start else {',
     'true else {',
     'BootstrapReconstructionTests.swift', 'reconstructionRechecksSameHistoryEpochAndKeepsPrivateGenerations',
     '#expect(try await lane.perform { $0.work?.stages.values.reduce(0) { $0 + $1.reconstructionSeeds } } == 3)'),
    ('reconstruction-resets-private', R+'GeneralSnapshots.swift',
     'try db.run("DELETE FROM current_notes")',
     'try db.run("DELETE FROM current_notes"); try db.run("UPDATE private_groups SET generation=1,payload=X\\\'\\\' WHERE group_key=X\\\'7265766965772D73656E74696E656C\\\'")',
     'BootstrapReconstructionTests.swift', 'reconstructionRechecksSameHistoryEpochAndKeepsPrivateGenerations',
     '#expect(try await lane.perform { try $0.rows("SELECT group_key,generation,codec,payload FROM private_groups WHERE group_key<? OR group_key>=? ORDER BY group_key", [.blob(VerificationRecord.prefix), .blob(VerificationRecord.end)]) } == privateState)'),
    ('reconstruction-body-only-continuation', R+'GeneralSnapshots.swift',
     'let recomputed = try graph.currentCells(collection: collection, affectedBirths: affected)',
     'let recomputed = try graph.currentCells(collection: collection, affectedBirths: affected).map { cell in seed.first(where: { $0.birth == cell.birth && $0.value.body == cell.value.body }) ?? cell }',
     'BootstrapReconstructionTests.swift', 'reconstructionKeepsBodyEqualContinuationAndUndoTargets',
     '#expect(rebuilt.notes.first { $0.birth == a }?.represented.map(\\.id) == [newRevision])'),
    ('historical-recovery-missing-adoption', 'Sources/NVStorageCore/ChangesPayloadV1.swift',
     '(.historicalRecovery, .adoptAutomatic)', '(.historicalRecovery, .genesis)',
     'ReviewRegressionTests.swift', 'historicalRecoveryAdoptsAutomaticNoteAndKeepsSaving',
     '#expect(reviewAccepted(outcome))'),
    ('rejected-capture-retains-slot', R+'Commit.swift',
     'failure == .staleCapture || error is RejectedCaptureEncoding', 'failure == .staleCapture',
     'ReviewRegressionTests.swift', 'definitiveCaptureEncodingFailureReturnsInputWithoutBlockingSaves',
     '#expect(await store.commitState.owned == nil, "definitive encoding rejection returns ownership to the handle")'),
    ('current-put-changes-birth-date', R+'OrdinaryDatabase.swift',
     'created: cell?.value.created ?? value.created', 'created: value.created',
     'ReviewRegressionTests.swift', 'currentCreationDateAgreesAcrossIncrementalReductionAndRebuild',
     '#expect(try await store.snapshot().notes.first { $0.birth == source }?.value == expected)'),
    ('command-calculation-on-owner', R+'Commit.swift',
     '''let worker = Task.detached {
            try await CommandWorker().perform {
                try Task.checkCancellation()
                gate?()
                let result = try work()
                try Task.checkCancellation()
                return result
            }
        }''',
     '''let eager: Result<T, any Error> = Result { gate?(); return try work() }
        let worker = Task.detached { try eager.get() }''',
     'CommandSchedulingTests.swift', 'commandCalculationYieldsToLocalSave', '#expect(gate.held)'),
    ('undo-maxima-only-direct-parents', 'Sources/NVStorageCore/CausalUndoV1.swift',
     'try ids.subtracting(preceding(ids))', 'ids.subtracting(ids.flatMap { records[$0]?.scopeParents ?? [] })',
     '../NVStorageCoreTests/CausalUndoQueryTests.swift', 'undoQueryMatchesIndependentSmallGraphClosure',
     '#expect(Set(result.candidates) == expected.0 && result.mode == expected.1 && Set(result.scopeFrontier) == expected.2)'),
    ('derived-state-rebound-order', 'Sources/NVStorageCore/DerivedStateReferenceV1.swift',
     'guard rebound.state == state, rebound.inputReferences == inputReferences else',
     'guard rebound.state == state else',
     '../NVStorageCoreTests/DerivedStateTests.swift', 'derivedStateMalformedEncodingAndLocalRebinding',
     '#expect(throws: CanonicalEncodingError.invalidReference) { try local.encodedV1(dependencies: DependencyLocatorTable([]), earlierOperations: swapped) }'),
    ('derived-state-wrong-result', 'Sources/NVStorageCore/DerivedStateReferenceV1.swift',
     'guard value.represented == state.inputs, try value.value.digestV1() == result else',
     'guard value.represented == state.inputs else',
     '../NVStorageCoreTests/DerivedStateTests.swift', 'derivedStateExactEvidenceAndWrongContext',
     'await #expect(throws: CanonicalEncodingError.identityMismatch) { try await f.reconstruct(wrongDigest) }'),
    ('derived-state-omitted-input', 'Sources/NVStorageCore/DerivedStateReferenceV1.swift',
     'guard value.represented == state.inputs, try value.value.digestV1() == result else',
     'guard try value.value.digestV1() == result else',
     '../NVStorageCoreTests/DerivedStateTests.swift', 'derivedStateChangedGraphAndUnchosenAlternatives',
     'await #expect(throws: CanonicalEncodingError.identityMismatch) { try await equal.reconstruct(equalClaim, history: equal.history + [duplicate]) }'),
    ('derived-state-wrong-identity', 'Sources/NVStorageCore/DerivedStateReferenceV1.swift',
     'merge.base == base, merge.id == id else', 'merge.base == base else',
     '../NVStorageCoreTests/DerivedStateTests.swift', 'derivedStateExactEvidenceAndWrongContext',
     'await #expect(throws: CanonicalEncodingError.identityMismatch) { try await f.reconstruct(wrongID) }'),
    ('derived-state-wrong-base', 'Sources/NVStorageCore/DerivedStateReferenceV1.swift',
     'merge.base == base, merge.id == id else', 'merge.id == id else',
     '../NVStorageCoreTests/DerivedStateTests.swift', 'derivedStateChecksUniqueBaseAndClaimKind',
     'await #expect(throws: CanonicalEncodingError.identityMismatch) { try await check(claim(0)) }'),
    ('derived-state-wrong-occurrence', 'Sources/NVStorageCore/DerivedStateReferenceV1.swift',
     'guard target.id == id else', 'guard true else',
     '../NVStorageCoreTests/DerivedStateTests.swift', 'derivedStateExactEvidenceAndWrongContext',
     'await #expect(throws: CanonicalEncodingError.identityMismatch) { try await f.reconstruct(misaddressed) }'),
    ('merge-touching-intervals', 'Sources/NVStorageCore/ConservativeMergeV1.swift',
     'a.range.upperBound < z.range.lowerBound || z.range.upperBound < a.range.lowerBound',
     'a.range.upperBound <= z.range.lowerBound || z.range.upperBound <= a.range.lowerBound',
     '../NVStorageCoreTests/ConservativeMergeTests.swift', 'mergeExactTextAndLimits',
     '#expect(try bodyResult(b, l, r).map { Array($0.utf8) } == expected.map { Array($0.utf8) })'),
    ('merge-knowledge-supersedes', 'Sources/NVStorageCore/NoteReductionV1.swift',
     'parents[op.id] = op.notePredecessors.ids',
     'parents[op.id] = op.notePredecessors.ids.isEmpty ? [] : op.causalParents.ids',
     '../NVStorageCoreTests/ConservativeMergeTests.swift', 'mergeGraphSelectionAndProvenance',
     '#expect(Set(knowledge.heads) == [aware.id, y.id], "causal knowledge preserves unchosen note heads")'),
    ('merge-dropped-represented-input', 'Sources/NVStorageCore/NoteReductionV1.swift',
     'represented: heads, merge: merge', 'represented: [heads[0]], merge: merge',
     'MergePreviewTests.swift', 'mergePreviewAcrossIndependentStores',
     '#expect(value.value.body.string == "A\\ngap\\nZ" && Set(value.represented) == [leftID, rightID])'),
    ('merge-omitted-collection-domain', 'Sources/NVStorageCore/NoteReductionV1.swift',
     '+ collection.bytes + birth.bytes +', '+ Array(repeating: UInt8(0), count: 16) + birth.bytes +',
     '../NVStorageCoreTests/ConservativeMergeTests.swift', 'mergeLiteralIdentityFixture',
     '#expect(hex(merge.identityPreimageV1()) == fixture["preimage"] && hex(merge.id.bytes) == fixture["identity"])'),
    ('restoration-omitted-provenance-index', R+'HistoryDatabase.swift',
     'for source in a.restorations {', 'for source in [RestorationV1]() {',
     'RestorationTests.swift', 'restorationPersistsExactEntryAcrossDeliveryAndReopen',
     '#expect(try await visible(in: source).isEmpty)'),
    ('restoration-requires-live-copy', R+'NoteHistory.swift',
     'FROM restorations r JOIN actions a ON a.action_id=r.action_id WHERE',
     'FROM restorations r JOIN actions a ON a.action_id=r.action_id JOIN action_members m ON m.action_id=r.action_id JOIN operations o ON o.operation_id=m.operation_id JOIN current_notes n ON n.birth=o.birth WHERE',
     'RestorationTests.swift', 'restorationPersistsExactEntryAcrossDeliveryAndReopen',
     '#expect(try await visible(in: source) == [fresh], "deleting the restored birth keeps the original handled")'),
    ('restoration-wrong-value', 'Sources/NVStorageCore/OrdinaryHistoryV1.swift',
     'guard value(revision) != nil, value(revision) == value(member) else',
     'guard value(revision) != nil else',
     'RestorationTests.swift', 'restorationRejectsNearValidSources',
     'await #expect { try await receiver.receive(bytes) } throws: { String(reflecting: $0) == String(reflecting: expected) }'),
    ('history-unbounded-chunk', R+'NoteHistory.swift',
     'bindings.append(.integer(Int64(limit + 1)))', 'bindings.append(.integer(Int64(limit + 1025)))',
     'NoteHistoryTests.swift', 'historyPagesFreezeTheirPrefixAndCheckConsumers',
     '#expect(querySteps.count == 1 && querySteps[0] < 100)'),
    ('history-hidden-delete', R+'NoteHistory.swift',
     'case .deletions, .recentlyDeleted: predicate = "kind=6"', 'case .deletions, .recentlyDeleted: predicate = "kind=5"',
     'NoteHistoryTests.swift', 'historySurvivesReorderedDeliveryAndReopen',
     '#expect(try await entries(.deletions, in: receiver).map(\\.operation) == [deletionID])'),
    ('history-wrong-prior', R+'NoteHistory.swift',
     'state = .deleted(operation: op, before: before)', 'state = .deleted(operation: op, before: op)',
     'NoteHistoryTests.swift', 'historySurvivesReorderedDeliveryAndReopen',
     '#expect(prior.id == editID)'),
    ('history-skipped-context', R+'NoteHistory.swift',
     'guard entry.session == incarnation, entry.store == selection.store else', 'guard true else',
     'NoteHistoryTests.swift', 'historyPagesFreezeTheirPrefixAndCheckConsumers',
     'await #expect(throws: StorageError.wrongContext) { try await other.preview(entry) }'),
    ('resumption-waits-after-finished', R+'ReceivedObjects.swift',
     'while inFlight {', 'while true {',
     'ValidationResumptionTests.swift', 'validationResumesAfterTwoInterferingSaves',
     'try #require(completed, "owned receive must resume from save completion alone")'),
    ('resumption-discards-ready', R+'ReceivedObjects.swift',
     'catch HistoryValidationInterrupted.historyAdvanced {',
     'catch HistoryValidationInterrupted.historyAdvanced {\n                try await lane.perform { try $0.exec("DELETE FROM ready_objects") }',
     'ValidationResumptionTests.swift', 'validationResumesAfterTwoInterferingSaves',
     '#expect(try await lane.perform { try $0.rows("SELECT object_id FROM ready_objects") } == [[.blob(remote.object.segmentID.bytes)]])'),
    ('resumption-releases-reservation', R+'ReceivedObjects.swift',
     'catch HistoryValidationInterrupted.historyAdvanced {',
     'catch HistoryValidationInterrupted.historyAdvanced {\n                receiveState = .idle',
     'ValidationResumptionTests.swift', 'validationResumesAfterTwoInterferingSaves',
     'try #require(waiting, "receive must wait for the active save after exhausting both checks")'),
    ('resumption-returns-busy', R+'HistoryDatabase.swift',
     'throw HistoryValidationInterrupted.historyAdvanced', 'throw StorageError.busy',
     'ValidationResumptionTests.swift', 'validationResumesAfterTwoInterferingSaves',
     'try #require(waiting, "receive must wait for the active save after exhausting both checks")'),
    ('resumption-loses-wakeup', R+'Commit.swift',
     'let waiters = drained; drained.removeAll(); for waiter in waiters { waiter.resume() }',
     'drained.removeAll()',
     'ValidationResumptionTests.swift', 'validationResumesAfterTwoInterferingSaves',
     'try #require(completed, "owned receive must resume from save completion alone")'),
    ('resumption-skips-condition-recheck', R+'ReceivedObjects.swift',
     'while inFlight {', 'if inFlight {',
     'ValidationResumptionTests.swift', 'validationResumesAfterTwoInterferingSaves',
     'try #require(waiting, "a woken receiver must recheck active save work")'),
    ('rejection-partial-commit', R+'ReceiveRejection.swift',
     'try transaction {', 'try measuring(.acceptance) {',
     'ReceiveIsolationTests.swift', 'rejectionCleanupFailureKeepsRetryableBytes',
     '#expect(state.0.isEmpty)'),
    ('blocked-only-direct', R+'ReceivedObjects.swift',
     'pending.append(contentsOf: parents)', 'if next == object { pending.append(contentsOf: parents) }',
     'RejectedDependencyTests.swift', 'rejectedPrerequisitesRemainDistinctFromMissingAndInvalidDescendants',
     '#expect(Set(roots.map(\\.object)) == Set([future.1.segmentID, malformed.1.segmentID]))'),
    ('current-basis-stale-prefix', R+'HistoryDatabase.swift',
     'try meta[0][2].number > 0, try meta[0][2].number == db.acceptedThrough() else',
     'try meta[0][2].number > 0 else',
     'CurrentBasisTests.swift', 'currentBasisRequiresCompleteMaterialization',
     'await #expect(throws: OrdinaryHistoryError.invalidAction) { try await receiver.receive(bytes) }'),
    ('current-basis-wrong-parents', R+'HistoryDatabase.swift',
     'guard Set(op.causalParents.ids) == expected else', 'guard true else',
     'CurrentBasisTests.swift', 'currentBasisRejectsNearValidClaims',
     'await #expect { try await receiver.receive(bytes) } throws: { sameError($0, expected) }'),
    ('current-basis-reused-birth', R+'HistoryDatabase.swift',
     'try !db.rows("SELECT 1 FROM operations WHERE birth=? LIMIT 1", [.blob(entry.birth.bytes)]).isEmpty {',
     'false {',
     'CurrentBasisTests.swift', 'currentBasisChecksHistoricalBirthReuse',
     'await #expect(throws: OrdinaryHistoryError.reusedBirth) { try await receiver.receive(bytes) }'),
    ('incomplete-object-frontier', R+'HistoryDatabase.swift',
     'DELETE FROM retained_frontier WHERE object_id IN (SELECT prerequisite FROM accepted_dependencies WHERE child=?)',
     'DELETE FROM retained_frontier WHERE object_id IN (SELECT prerequisite FROM accepted_dependencies WHERE child=?) OR object_id IN (SELECT object_id FROM retained_frontier)',
     'CurrentBasisTests.swift', 'currentBasisPreservesBranchFrontiers',
     '#expect(branchedPin == Set('),
    ('incomplete-operation-frontier', R+'OrdinaryDatabase.swift',
     'operations: context.operations.filter { maxima.contains($0.id) } + [self.operationOccurrence(op.id)],',
     'operations: [self.operationOccurrence(op.id)],',
     'CurrentBasisTests.swift', 'currentBasisPreservesBranchFrontiers',
     '#expect(Set(both.context.operations.map(\\.locator)) == [e.object, f.object])'),
    ('ignore-known-history-damage', R+'Database.swift',
     'guard !requiredHistoryDamaged else { throw StorageError.integrity }',
     'guard true else { throw StorageError.integrity }',
     'RetentionTests.swift', 'discoveredRequiredHistoryDamageBlocksPreparedPublication',
     'await #expect(throws: StorageError.integrity) { try await session.publish'),
    ('early-ack', R+'Commit.swift',
     'let accepted = try await lane.acceptScheduled(sealed.bytes, locator: sealed.locator,\n                selection: selection, protection: protection)',
     'let accepted = try await lane.perform { try $0.acceptedThrough() + 1 }',
     'SavedActionTests.swift', 'ordinaryEditDeleteAndCreateReopen', '#expect(second.notes.map'),
    ('omitted-dependencies', R+'HistoryDatabase.swift',
     'for parent in object.dependencies {', 'for parent in [SegmentLocator]() {',
     'RetentionTests.swift', 'acceptanceAndOlderSettingsPreserveExactRetention', '#expect(acceptedPin == expected)'),
    ('regressed-retention', R+'Publication.swift',
     'try db.run("UPDATE private_groups SET generation=generation+1 WHERE group_key=?", [.blob(Array("settings".utf8))])',
     'try db.run("UPDATE private_groups SET generation=generation+1 WHERE group_key=?", [.blob(Array("settings".utf8))]); try db.run("DELETE FROM retained_frontier")',
     'RetentionTests.swift', 'acceptanceAndOlderSettingsPreserveExactRetention', '#expect(afterSettings == expected)'),
    ('stale-completion', R+'HeadlessModel.swift',
     'for generation in receipt.covered where pending[generation.birth] == generation {', 'for generation in receipt.covered {',
     'RuntimeSchedulesTests.swift', 'oldCompletionPreservesNewerPendingWork', '#expect(model.pending[birth] == f)'),
    ('missed-wakeup', R+'Resources/SchemaV1.sql',
     'SELECT child FROM object_waits WHERE prerequisite = NEW.object_id',
     'SELECT child FROM object_waits WHERE prerequisite = NEW.object_id AND 0',
     'RuntimeSchedulesTests.swift', 'durableDependencyWakeupsAndRepackagedOperations', '#expect(complete.through == 4)'),
    ('skipped-store-context', R+'Commit.swift',
     'guard capture.session == incarnation, capture.store == selection.store else', 'guard true else',
     'SavedActionTests.swift', 'wrongStoreAndOldSessionCapturesAreRejectedByPersist', 'await #expect(throws: StorageError.wrongContext) { try await other.persist'),
    ('skipped-view-context', R+'Publication.swift',
     'guard change.liveGeneration == liveGeneration else', 'guard true else',
     'RuntimeSchedulesTests.swift', 'settingsAndPublicationHaveIndependentContextChecks', 'await #expect(throws: StorageError.staleCapture) { try await session.publish(prepared, liveGeneration: 2)'),
    ('wrong-materialization', R+'OrdinaryDatabase.swift',
     'CurrentNoteCellV1(birth: entry.birth, value: currentValue,', 'CurrentNoteCellV1(birth: entry.birth, value: cell?.value ?? currentValue,',
     'SavedActionTests.swift', 'ordinaryEditDeleteAndCreateReopen', '#expect(second.notes.map'),
    ('lost-rejection-evidence', R+'ReceiveRejection.swift',
     'try run("INSERT INTO rejected_objects VALUES(?,1,?) ON CONFLICT(object_id) DO NOTHING",',
     'try run("SELECT ?,?",',
     'ReceiveIsolationTests.swift', 'rejectedParkedChildPreservesIndependentProgress',
     '#expect(evidence.1 =='),
    ('history-work-ignores-prefix', R+'Database.swift',
     'guard try db.acceptedThrough() == through else', 'guard true else',
     'HistorySchedulingTests.swift', 'historyReadRejectsStalePrefix',
     'await #expect(throws: StorageError.staleCapture)'),
    ('unbounded-materialization', R+'OrdinaryDatabase.swift',
     'let target = start < available ? start + 1 : available', 'let target = available',
     'HistorySchedulingTests.swift', 'catchUpCommitsOneCompletePrefixAtATime',
     '#expect(result.1 =='),
    ('misaddressed-input-poisons-queue', R+'ReceiveInputs.swift',
     'throw CanonicalEncodingError.invalidReference', 'throw StorageError.integrity',
     'ReceiveIsolationTests.swift', 'misaddressedReceiveDependencyIsIsolated',
     'await #expect(throws: CanonicalEncodingError.invalidReference)'),
    ('ready-before-view-repair', R+'LocalStore.swift',
     'try await lane.reconstructIfNeeded(selection: selection, protection: protection)\n                _ = try await lane.drainReady(selection: selection, protection: protection)',
     '_ = try await lane.drainReady(selection: selection, protection: protection)\n                try await lane.reconstructIfNeeded(selection: selection, protection: protection)',
     'HistorySchedulingTests.swift', 'reopenRebuildsDamagedViewBeforeDrainingReadyHistory',
     'let reopened = try #require(recovered)'),
]
MUTATIONS += [
    ('snapshot-acceptance-missing-history-edges', R+'HistoryDatabase.swift',
     'Array(Set(rootReferences + [root.tree.locator]))', 'Array(Set(rootReferences.filter { _ in false } + [root.tree.locator]))',
     'SnapshotAcceptanceTests.swift', 'snapshotAcceptancePreservesValuesAndCompletePin',
     '#expect(rootEdges == expectedRoot)'),
    ('snapshot-acceptance-missing-tree-edges', R+'HistoryDatabase.swift',
     'children.map(\\.locator) } else { [] }', 'children.filter { _ in false }.map(\\.locator) } else { [] }',
     'SnapshotAcceptanceTests.swift', 'snapshotAcceptancePreservesValuesAndCompletePin',
     '#expect(edges == expected)'),
    ('snapshot-capture-wrong-owner', R+'GeneralSnapshots.swift',
     '''guard session == owner.incarnation, store == owner.selection.store,
              collection == owner.selection.descriptor.collection else''', 'guard true else',
     'SnapshotAcceptanceTests.swift', 'snapshotCaptureAndRetryRequireTheIssuingOwner',
     'await #expect(throws: StorageError.wrongContext) { try await right.persistGeneralSnapshot(capture: capture) }'),
    ('snapshot-acceptance-wrong-connection', R+'GeneralSnapshots.swift',
     'guard connection == database.incarnation, store == selection.store,',
     'guard store == selection.store,',
     'SnapshotAcceptanceTests.swift', 'snapshotCaptureAndRetryRequireTheIssuingOwner',
     'await #expect(throws: StorageError.wrongContext) { try await copiedLane.perform { try checked.check(database: $0, selection: copiedSelection) } }'),
    ('snapshot-ready-recovery-omitted', R+'LocalStore.swift',
     '_ = try await lane.drainReady(selection: selection, protection: protection)',
     'try await lane.perform { try $0.run("DELETE FROM ready_objects WHERE object_id IN (SELECT object_id FROM objects WHERE kind=2)") }; _ = try await lane.drainReady(selection: selection, protection: protection)',
     'SnapshotAcceptanceTests.swift', 'snapshotRootReadyRecoveryUsesRetainedExactCandidates',
     '#expect(try await reopened.snapshot().through == 2)'),
    ('snapshot-optional-work-blocks-close', R+'LocalStore.swift',
     'guard commitState.owned == nil else', 'guard commitState.owned == nil, snapshotState.owned == nil else',
     'SnapshotAcceptanceTests.swift', 'snapshotOptionalWorkAllowsDurableClose',
     'await #expect(throws: Never.self) { try await store.quiesce() }'),
    ('general-snapshot-omitted-membership-audit', R+'GraphMaterialization.swift',
     'case .allOccurrences: sources = try await acceptedSources(through: through, lane: lane)',
     'case .allOccurrences: sources = sourceIDs.sorted { $0.lexicographicallyPrecedes($1) }',
     'GeneralSnapshotRuntimeTests.swift', 'generalSnapshotDetectsUnindexedAcceptedLeaf',
     'await #expect(throws: StorageError.integrity) { try await store.captureGeneralSnapshot() }'),
    ('general-snapshot-unchecked-state', R+'GeneralSnapshots.swift',
     'guard snapshotClaimsEqual(preview.records, expected) else', 'guard snapshotClaimsEqual(expected, expected) else',
     'GeneralSnapshotRuntimeTests.swift', 'generalSnapshotRejectsAuthenticWrongClaims',
     'await #expect(throws: GeneralSnapshotError.invalidState) { try await store.verifyGeneralSnapshot(wrong) }'),
    ('general-snapshot-wrong-body', R+'GeneralSnapshots.swift',
     'lhs.value == rhs.value, lhs.state == rhs.state,', 'lhs.state == rhs.state,',
     'GeneralSnapshotRuntimeTests.swift', 'generalSnapshotRejectsAuthenticWrongClaims',
     'await #expect(throws: GeneralSnapshotError.invalidState) { try await store.verifyGeneralSnapshot(wrong) }'),
    ('general-snapshot-omitted-head', R+'GeneralSnapshots.swift',
     'lhs.heads.map(\\.id) == rhs.heads.map(\\.id),', '',
     'GeneralSnapshotRuntimeTests.swift', 'generalSnapshotRejectsAuthenticWrongClaims',
     'await #expect(throws: GeneralSnapshotError.invalidState) { try await store.verifyGeneralSnapshot(wrong) }'),
    ('general-snapshot-omitted-scope', R+'GeneralSnapshots.swift',
     'lhs.scopeFrontier.map(\\.id) == rhs.scopeFrontier.map(\\.id),', '',
     'GeneralSnapshotRuntimeTests.swift', 'generalSnapshotRejectsAuthenticWrongClaims',
     'await #expect(throws: GeneralSnapshotError.invalidState) { try await store.verifyGeneralSnapshot(wrong) }'),
    ('general-snapshot-partial-group', R+'GraphMaterialization.swift',
     'guard action.members.allSatisfy(seen.contains), action.scopeParents.allSatisfy(actionIDs.contains),',
     'guard action.scopeParents.allSatisfy(actionIDs.contains),',
     'GeneralSnapshotRuntimeTests.swift', 'generalSnapshotRejectsPartialActionCut',
     'await #expect(throws: GeneralSnapshotError.invalidState) { try await store.verifyGeneralSnapshot(wrong) }'),
    ('general-snapshot-bootstrap-occurrence', R+'GeneralSnapshots.swift',
     'object.kind == .snapshotRoot, operationsByLocator[locator] == nil,\n                          actionsByLocator[locator] == nil',
     'object.kind == .snapshotRoot',
     'GeneralSnapshotRuntimeTests.swift', 'generalSnapshotRejectsAuthenticWrongClaims',
     'await #expect(throws: GeneralSnapshotError.invalidState) { try await store.verifyGeneralSnapshot(wrong) }'),
    ('general-snapshot-profile-consumer', 'Sources/NVStorageCore/GeneralSnapshotV1.swift',
     '_ = try ObjectEnvelopeV1.open(rootBytes, collection: collection, protection: protection, expectedLocator: snapshot)',
     '_ = rootBytes',
     'GeneralSnapshotRuntimeTests.swift', 'generalSnapshotActualConsumerChecksProfileAndLifecycle',
     'await #expect(throws: CanonicalEncodingError.authenticationFailure) { try await store.verifyGeneralSnapshot(wrong) }'),
    ('general-snapshot-digest', 'Sources/NVStorageCore/GeneralSnapshotV1.swift',
     'counts == root.counts, Array(reader.hash.finalize()) == root.digest.bytes,', 'counts == root.counts,',
     '../NVStorageCoreTests/GeneralSnapshotTests.swift', 'generalSnapshotAuthenticFramingDefects',
     'await #expect { try await GeneralSnapshotPreviewV1.read(snapshot: snapshot, collection: sink.collection, protection: sink.protection, read: { map[$0] }) } throws:'),
    ('conflict-current-only-predecessors', R+'Commit.swift',
     'let inputs = capture.kind == .conflictChoice ? (old?.heads ?? []) : (old?.represented ?? [])',
     'let inputs = old?.heads ?? []',
     'ConnectedEdgeTests.swift', 'ordinaryConflictEditPreservesKnownUnchosenHeads',
     '#expect(Set(op.notePredecessors.ids) == Set(before.represented.map(\\.id)))'),
    ('conflict-slot-domain', R+'Commit.swift',
     'if cell.identity == identity, cell.represented.count == 1,',
     'if cell.represented.count == 1,',
     'ConnectedEdgeTests.swift', 'ordinaryIdentityCollisionPreservesFileAndSkipsRecoverySlot',
     '#expect(captured.covered[0].birth == (try key.birth(slot: 1)))'),
    ('delete-union-coverage', 'Sources/NVStorageCore/CollectionReductionV1.swift',
     'for deletion in deletes { covered.formUnion(try past(deletion)) }',
     'if let deletion = deletes.first { covered.formUnion(try past(deletion)) }',
     'ConnectedEdgeTests.swift', 'equalAutomaticKeyNeedsEverySourceCovered',
     '#expect(try await deleted.snapshot().notes.map(\\.value.body.string) == ["untouched"])'),
    ('copy-disposition-retention', 'Sources/NVStorageCore/CollectionReductionV1.swift',
     'if case .copy(_, let revision, _, _, _) = action.details { return revision }; return nil',
     'if case .copy(_, let revision, let key, let slot, _) = action.details, cells[try! key.birth(slot: slot)] != nil { return revision }; return nil',
     'ConnectedSemanticsTests.swift', 'reciprocalCopiesKeepSourceAndDurableDispositions',
     '#expect(try await left.conflicts(for: source).representedSeparately.isSuperset(of: [lID, rID]))'),
    ('undo-proposal-context', R+'CompensationCommands.swift',
     'guard proposal.session == incarnation, proposal.store == selection.store else',
     'guard true else',
     'CompensationTests.swift', 'reviewedCompensationRejectsChangedScopeButAllowsUnrelatedWork',
     'await #expect(throws: StorageError.wrongContext) { try await other.applyCompensation(first) }'),
    ('undo-stale-values', R+'CompensationCommands.swift',
     'for birth in proposal.testedBirths { guard current[birth] == proposal.before[birth] else',
     'for birth in Set<NoteBirth>() { guard current[birth] == proposal.before[birth] else',
     'ConnectedEdgeTests.swift', 'namedCompensationKeepsAllMembersAndRejectsStaleApproval',
     'await #expect(throws: StorageError.staleCapture) { try await store.applyReviewedCompensation(stale.forReview()) }'),
    ('undo-family-scope', 'Sources/NVStorageCore/CausalUndoV1.swift',
     'if !coverageContinuation && !root.isDisjoint(with: otherFamilies) { review = true }',
     'if !coverageContinuation { review = true }',
     'CompensationTests.swift', 'concurrentCompensationsNoOpAndIndependentFamily',
     '#expect(try await left.undoCandidates(scope: scope, direction: .undo).mode == .automatic)'),
    ('native-complete-any-claim', 'Sources/NVStorageCore/CausalUndoV1.swift',
     'claimants.filter({ maximalClaims.contains($0.id) }).allSatisfy({ action in',
     'claimants.filter({ maximalClaims.contains($0.id) }).contains(where: { action in',
     'NativeCoverageTests.swift', 'incomparableNativeCoveragePreservesRemainingFamily',
     '#expect(candidates.ids == [target] && candidates.mode == .review)'),
    ('native-remaining-original', 'Sources/NVStorageCore/CompensationV1.swift',
     'return states.first', 'return nil',
     'NativeCoverageTests.swift', 'nativeRemainingEffectAndActualRedoSurviveReopen',
     '#expect(isAutomaticCompensation(undoPreparation))'),
    ('command-omitted-choice-heads', 'Sources/NVStorageCore/OrdinaryHistoryV1.swift',
     'Set(heads) == Set(op.notePredecessors.ids), heads.contains(selected),',
     'heads.contains(selected),',
     'ConnectedValidationTests.swift', 'connectedCommandsRejectAuthenticatedNearValidClaims',
     'await #expect(throws: expected) { try await peer.receive(bytes) }'),
    ('native-inaccurate-coverage', 'Sources/NVStorageCore/OrdinaryHistoryV1.swift',
     'record.complete == actual.hasSameEditableFields(as: targetBefore) else',
     'true else',
     'ConnectedValidationTests.swift', 'connectedCommandsRejectAuthenticatedNearValidClaims',
     'await #expect(throws: expected) { try await peer.receive(bytes) }'),
    ('native-candidate-router', 'Sources/NVStorageCore/OrdinaryHistoryV1.swift',
     'guard eligible.mode == .automatic, eligible.candidates.count == 1,\n                  coverage.first(where: { $0.action == eligible.candidates[0] })?.remaining == .value(a.members[0]) else',
     'guard true else',
     'ConnectedValidationTests.swift', 'connectedCommandsRejectAuthenticatedNearValidClaims',
     'await #expect(throws: expected) { try await peer.receive(bytes) }'),
    ('actor-final-prefix', R+'HistoryDatabase.swift',
     'guard try db.acceptedThrough() == through else', 'guard true else',
     'ActorAcceptanceTests.swift', 'actorAcceptanceRechecksAfterFinalHistoryRead',
     '#expect(try await lane.perform { $0.work![.validation].fullChecks } == 2)'),
    ('async-ancestry-obligation', 'Sources/NVStorageCore/OrdinaryHistoryV1.swift',
     'guard past.contains(requirement.parent) else', 'guard true else',
     'OrdinaryValidationTests.swift', 'ordinaryValidationUsesExactWriterBasisAndPreservesOriginForks',
     'await #expect(throws: OrdinaryHistoryError.invalidCausality)'),
]
MUTATIONS += [
    ('received-snapshot-lost-arrival', R+'ReceiveInputs.swift',
     'WHERE w.prerequisite=? AND NOT EXISTS',
     'WHERE 0 AND w.prerequisite=? AND NOT EXISTS',
     'ReceivedSnapshotTests.swift', 'receivedSnapshotParkingRechecksConcurrentArrivals',
     '#expect(receivedAccepted(try await receiver.receivedObjectStatus(at: fixture.root)), "No further arrival may be required")'),
    ('received-snapshot-stale-parking', R+'ReceiveInputs.swift',
     'let missing = try missingRequirements(requirements)', 'let missing = requirements',
     'ReceivedSnapshotTests.swift', 'receivedSnapshotParkingRechecksConcurrentArrivals',
     '#expect(receivedAccepted(try await receiving.value), "Transaction recheck must avoid a stale wait")'),
    ('received-snapshot-inherited-rejection', R+'ReceivedObjects.swift',
     'let gate = try await perform { $0.work?.receiveDiscovered }',
     'if let blocker = try await rejectedPrerequisites(of: locator.segmentID, discovered: wait.requirements).first { try await perform { try $0.rejectReceived(.blob(locator.segmentID.bytes), reason: blocker.reason) } }; let gate = try await perform { $0.work?.receiveDiscovered }',
     'ReceivedSnapshotTests.swift', 'receivedSnapshotUnsupportedChildBlocksOnlyItsDependents',
     '#expect(receivedBlocked(blocked), "Root must report its prerequisite\'s own result")'),
    ('received-snapshot-optional-close-gate', R+'LocalStore.swift',
     'while inFlight || requiredReceiveInFlight || backupInFlight || activationInFlight || pendingPreparationInFlight {',
     'while inFlight || receiving || backupInFlight || activationInFlight || pendingPreparationInFlight {',
     'ReceivedSnapshotTests.swift', 'receivedSnapshotOptionalClosePreservesOwnedInputs',
     '#expect(closed, "Optional preparation or completion must permit close while held")'),
    ('received-snapshot-omitted-occurrence-audit', R+'GraphMaterialization.swift',
     'guard actualOps == payload.operations.enumerated().map({ [.integer(Int64($0.offset)), .blob($0.element.operation.id.bytes)] }),',
     'guard actualOps.count >= 0,',
     'ReceivedSnapshotTests.swift', 'receivedSnapshotRequiredDamageStaysBlockedDespiteMarkerFailure',
     'await #expect(throws: StorageError.integrity) { try await receiver.receive(fixture.objects[fixture.root]!) }'),
]
MUTATIONS += [
    ('pending-review-fresh-birth', R+'PendingFiles.swift',
     'let target = try birth ?? prior?.birth ?? NoteBirth(bytes: uuidBytes()), action',
     'let target = try birth ?? prior.map { _ in try NoteBirth(bytes: uuidBytes()) } ?? NoteBirth(bytes: uuidBytes()), action',
     'PrivateStateTests.swift', 'pendingCompetingReviewReusesBirthAndCommitsOnce',
     '#expect(reviewed.reservation.birth == first.reservation.birth)'),
    ('repair-drop-frozen-reference', R+'PrivateRepair.swift',
     'for name in ["pending_payloads", "pending_items", "pending_reservations", "pending_settlements"] {',
     'for name in ["pending_payloads", "pending_items", "pending_settlements"] {',
     'PrivateRepairTests.swift', 'complementaryRepairPreservesUnpublishedHistoryAndPrivateInputs',
     '#expect(recoveredReservations.count == 1)'),
    ('copy-drop-unpublished', R+'RepositoryCopy.swift',
     'for object in saved.objects {', 'for object in [CapturedRepositoryObject]() {',
     'RepositoryCopyTests.swift', 'activeRecoveryCopyIncludesUnpublishedHistoryAndKeepsPrivateBuffers',
     '#expect(copy.repository.capturedInventoryComplete && copy.repository.unmetRequirements.isEmpty)'),
]
REQUIRED = set(m[5] for m in MUTATIONS)


def classify(code, log, test, line, function, required=REQUIRED):
    if code == 0:
        return 'survived'
    if 'Build complete!' not in log or 'Test run started.' not in log:
        return 'compile/setup failure'
    if not required.issubset(helpers.discovered(log)):
        return 'missing required discovery'
    issues = [s for s in log.splitlines() if f'Test {function}(' in s and 'recorded an issue' in s
              and f' at {Path(test).name}:{line}:' in s and 'Expectation failed:' in s]
    return 'targeted runtime failure' if issues else 'unrelated failure'


def self_test():
    helpers.self_test()
    function = 'historySurvivesReorderedDeliveryAndReopen'
    missing = 'wrongStoreAndOldSessionCapturesAreRejectedByPersist'
    starts = 'Build complete!\nTest run started.\n' + '\n'.join(
        f'Test {name}() started.' for name in sorted(REQUIRED - {missing})) + '\n'
    completion = f'Test {missing}() passed after 0.148 seconds.\n'
    issue = (f'Test {function}(encrypted:childFirst:) recorded an issue with 2 arguments '
             'encrypted → false, childFirst → true at NoteHistoryTests.swift:66:13: '
             'Expectation failed: prior.id == editID\n')
    log = starts + completion + issue
    assert classify(1, log, 'NoteHistoryTests.swift', 66, function) == 'targeted runtime failure'
    assert classify(1, starts + issue, 'NoteHistoryTests.swift', 66, function) == 'missing required discovery'
    assert classify(1, log, 'NoteHistoryTests.swift', 67, function) == 'unrelated failure'
    assert classify(1, log, 'OtherTests.swift', 66, function) == 'unrelated failure'
    assert classify(1, starts + completion, 'NoteHistoryTests.swift', 66, function) == 'unrelated failure'
    assert classify(1, log.replace(issue, issue.replace(function, 'otherTest')),
                    'NoteHistoryTests.swift', 66, function) == 'unrelated failure'
    scoped = 'Build complete!\nTest run started.\n' + f'Test {function}() started.\n' + issue
    assert classify(1, scoped, 'NoteHistoryTests.swift', 66, function, {function}) == 'targeted runtime failure'
    assert classify(1, scoped, 'NoteHistoryTests.swift', 66, function, {function, missing}) == 'missing required discovery'
    assert classify(1, 'compiler unavailable', 'T.swift', 1, 'x') == 'compile/setup failure'
    assert classify(0, log, 'NoteHistoryTests.swift', 66, function) == 'survived'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--configuration', choices=['debug', 'release'], default='debug')
    parser.add_argument('--self-test-only', action='store_true')
    parser.add_argument('--only', action='append', choices=[m[0] for m in MUTATIONS])
    args = parser.parse_args()
    selected = [m for m in MUTATIONS if not args.only or m[0] in args.only]
    required = {m[5] for m in selected}
    for name, file, before, after, test, function, assertion in MUTATIONS:
        try:
            helpers.replace_once((ROOT/'NVStorage'/file).read_text(), before, after)
            helpers.assertion_line((ROOT/'NVStorage'/T/test).read_text(), function, assertion)
        except ValueError as error:
            raise ValueError(f'{name}: {error}') from error
    self_test()
    print('PASS: mutation setup checks', flush=True)
    if args.self_test_only:
        return
    artifacts = Path(tempfile.mkdtemp(prefix='nv-runtime-mutations-'))
    package = artifacts/'NVStorage'
    print('Artifacts:', artifacts, flush=True)
    shutil.copytree(ROOT/'NVStorage', package, ignore=shutil.ignore_patterns('.build*', '.swiftpm', '.deps'))
    for folder in ['checkouts', 'repositories']:
        old = ROOT/'NVStorage/.build'/folder
        if old.is_dir(): shutil.copytree(old, package/'.build'/folder)
    os.environ['PKG_CONFIG_PATH'] = str(ROOT/'NVStorage/.deps/sqlcipher/lib/pkgconfig') + os.pathsep + os.environ.get('PKG_CONFIG_PATH', '')
    # Reduce test-output interleaving while each test still drives its own concurrent tasks.
    command = ['swift', 'test', '--build-system', 'native', '--package-path', str(package), '-c', args.configuration, '--no-parallel', '--filter', '|'.join(sorted(required))]
    report = {'command': command, 'configuration': args.configuration, 'required_tests': sorted(required), 'results': [],
              'sources': {str(p.relative_to(package)):helpers.sha(p) for p in package.rglob('*') if p.is_file() and '.build' not in p.parts}}

    def run(name):
        print('Running', name, flush=True)
        path = artifacts/(name+'.log')
        with path.open('w') as out:
            with subprocess.Popen(command, stdout=out, stderr=subprocess.STDOUT, start_new_session=True) as process:
                try: result = process.wait(timeout=600)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait()
                    result = None
        # Preserve exact ASCII diagnostics when concurrent Unicode status icons interleave.
        return result, path.read_text(errors='backslashreplace')

    code, log = run('baseline')
    assert code == 0 and required.issubset(helpers.discovered(log)), 'Invalid baseline or discovery; inspect baseline.log'
    for name, file, before, after, test, function, assertion in selected:
        path = package/file; original = path.read_text(); changed = helpers.replace_once(original, before, after)
        (artifacts/(name+'.patch')).write_text(''.join(difflib.unified_diff(original.splitlines(True), changed.splitlines(True), fromfile=file, tofile=file)))
        line = helpers.assertion_line((package/T/test).read_text(), function, assertion)
        path.write_text(changed)
        try: code, log = run(name)
        finally: path.write_text(original)
        verdict = classify(code, log, test, line, function, required)
        report['results'].append({'name': name, 'returncode': code, 'verdict': verdict, 'test': function,
                                  'assertion_line': line, 'mutant_sha256': hashlib.sha256(changed.encode()).hexdigest()})
        (artifacts/'results.json').write_text(json.dumps(report, indent=2))
        print(name + ': ' + verdict, flush=True)
    assert all(r['verdict'] == 'targeted runtime failure' for r in report['results'])


if __name__ == '__main__':
    main()
