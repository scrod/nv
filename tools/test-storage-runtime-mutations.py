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
    ('resumption-waits-after-finished', R+'ReceivedObjects.swift',
     'while inFlight {', 'while true {',
     'ValidationResumptionTests.swift', 'validationResumesAfterTwoInterferingSaves',
     'try #require(completed, "owned receive must resume from save completion alone")'),
    ('resumption-discards-ready', R+'ReceivedObjects.swift',
     '} catch HistoryValidationInterrupted.historyAdvanced {',
     '} catch HistoryValidationInterrupted.historyAdvanced {\n                try await lane.perform { try $0.exec("DELETE FROM ready_objects") }',
     'ValidationResumptionTests.swift', 'validationResumesAfterTwoInterferingSaves',
     '#expect(try await lane.perform { try $0.rows("SELECT object_id FROM ready_objects") } == [[.blob(remote.object.segmentID.bytes)]])'),
    ('resumption-releases-reservation', R+'ReceivedObjects.swift',
     '} catch HistoryValidationInterrupted.historyAdvanced {',
     '} catch HistoryValidationInterrupted.historyAdvanced {\n                receiving = false',
     'ValidationResumptionTests.swift', 'validationResumesAfterTwoInterferingSaves',
     'try #require(waiting, "receive must wait for the active save after exhausting both checks")'),
    ('resumption-returns-busy', R+'HistoryDatabase.swift',
     'throw HistoryValidationInterrupted.historyAdvanced', 'throw StorageError.busy',
     'ValidationResumptionTests.swift', 'validationResumesAfterTwoInterferingSaves',
     'try #require(waiting, "receive must wait for the active save after exhausting both checks")'),
    ('resumption-loses-wakeup', R+'Commit.swift',
     'defer { inFlight = false; let waiters = drained; drained.removeAll(); for waiter in waiters { waiter.resume() } }',
     'defer { inFlight = false }',
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
     'for parent in unit.dependencies[locator] ?? [] {', 'for parent in [SegmentLocator]() {',
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
     'CurrentNoteCellV1(birth: entry.birth, value: value,', 'CurrentNoteCellV1(birth: entry.birth, value: cell?.value ?? value,',
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
    ('misaddressed-input-poisons-queue', R+'ReceivedObjects.swift',
     'else { throw CanonicalEncodingError.invalidReference }', 'else { throw StorageError.integrity }',
     'ReceiveIsolationTests.swift', 'misaddressedReceiveDependencyIsIsolated',
     'await #expect(throws: CanonicalEncodingError.invalidReference)'),
    ('ready-before-view-repair', R+'LocalStore.swift',
     'try await lane.perform { db in\n                try db.recoverMaterialization(selection: selection, protection: protection)\n            }\n            try await lane.drainReady(selection: selection, protection: protection)',
     'try await lane.drainReady(selection: selection, protection: protection)\n            try await lane.perform { db in\n                try db.recoverMaterialization(selection: selection, protection: protection)\n            }',
     'HistorySchedulingTests.swift', 'reopenRebuildsDamagedViewBeforeDrainingReadyHistory',
     'let reopened = try #require(recovered)'),
]
MUTATIONS += [
    ('actor-final-prefix', R+'HistoryDatabase.swift',
     'guard try db.acceptedThrough() == checked.through else', 'guard true else',
     'ActorAcceptanceTests.swift', 'actorAcceptanceRechecksAfterFinalHistoryRead',
     '#expect(try await lane.perform { $0.work![.validation].fullChecks } == 2)'),
    ('async-ancestry-obligation', 'Sources/NVStorageCore/OrdinaryHistoryV1.swift',
     'guard past.contains(requirement.parent) else', 'guard true else',
     'OrdinaryValidationTests.swift', 'ordinaryValidationUsesExactWriterBasisAndPreservesOriginForks',
     'await #expect(throws: OrdinaryHistoryError.invalidCausality)'),
]
REQUIRED = set(m[5] for m in MUTATIONS)


def classify(code, log, test, line, function):
    if code == 0:
        return 'survived'
    if 'Build complete!' not in log or 'Test run started.' not in log:
        return 'compile/setup failure'
    if not REQUIRED.issubset(helpers.discovered(log)):
        return 'missing required discovery'
    issues = [s for s in log.splitlines() if f'Test {function}(' in s and 'recorded an issue' in s
              and f' at {test}:{line}:' in s and 'Expectation failed:' in s]
    return 'targeted runtime failure' if issues else 'unrelated failure'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--configuration', choices=['debug', 'release'], default='debug')
    parser.add_argument('--self-test-only', action='store_true')
    parser.add_argument('--only', action='append', choices=[m[0] for m in MUTATIONS])
    args = parser.parse_args()
    for _, file, before, after, test, function, assertion in MUTATIONS:
        helpers.replace_once((ROOT/'NVStorage'/file).read_text(), before, after)
        helpers.assertion_line((ROOT/'NVStorage'/T/test).read_text(), function, assertion)
    assert classify(1, 'compiler unavailable', 'T.swift', 1, 'x') == 'compile/setup failure'
    assert classify(0, '', 'T.swift', 1, 'x') == 'survived'
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
    command = ['swift', 'test', '--build-system', 'native', '--package-path', str(package), '-c', args.configuration, '--filter', '|'.join(sorted(REQUIRED))]
    report = {'command': command, 'configuration': args.configuration, 'results': [],
              'sources': {str(p.relative_to(package)):helpers.sha(p) for p in package.rglob('*') if p.is_file() and '.build' not in p.parts}}

    def run(name):
        print('Running', name, flush=True)
        path = artifacts/(name+'.log')
        with path.open('w') as out:
            try: result = subprocess.run(command, stdout=out, stderr=subprocess.STDOUT, timeout=600).returncode
            except subprocess.TimeoutExpired: result = None
        # Preserve exact ASCII diagnostics when concurrent Unicode status icons interleave.
        return result, path.read_text(errors='backslashreplace')

    code, log = run('baseline')
    assert code == 0 and REQUIRED.issubset(helpers.discovered(log)), 'Invalid baseline or discovery; inspect baseline.log'
    for name, file, before, after, test, function, assertion in MUTATIONS:
        if args.only and name not in args.only:
            continue
        path = package/file; original = path.read_text(); changed = helpers.replace_once(original, before, after)
        (artifacts/(name+'.patch')).write_text(''.join(difflib.unified_diff(original.splitlines(True), changed.splitlines(True), fromfile=file, tofile=file)))
        line = helpers.assertion_line((package/T/test).read_text(), function, assertion)
        path.write_text(changed)
        try: code, log = run(name)
        finally: path.write_text(original)
        verdict = classify(code, log, test, line, function)
        report['results'].append({'name': name, 'returncode': code, 'verdict': verdict, 'test': function,
                                  'assertion_line': line, 'mutant_sha256': hashlib.sha256(changed.encode()).hexdigest()})
        (artifacts/'results.json').write_text(json.dumps(report, indent=2))
        print(name + ': ' + verdict, flush=True)
    assert all(r['verdict'] == 'targeted runtime failure' for r in report['results'])


if __name__ == '__main__':
    main()
