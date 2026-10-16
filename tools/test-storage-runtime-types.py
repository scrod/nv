#!/usr/bin/env python3
"""Construction and authority boundaries for ordinary and same-module runtime clients."""
import argparse
from pathlib import Path
import subprocess
import importlib.util
import sys

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('typechecks', ROOT / 'tools/test-swift-storage-types.py')
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


def matches_expected(code, diagnostic, path, source, expected):
    alternatives = expected if isinstance(expected, tuple) else (expected,)
    return any(checker.matches_contract(code, diagnostic, path, source, text) for text in alternatives)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--modules', type=Path, required=True)
    parser.add_argument('--actors-only', action='store_true')
    parser.add_argument('--review-only', action='store_true', help='Check graph issuance and exhaustive reducer routing with their valid companion.')
    parser.add_argument('--locality-only', action='store_true', help='Check current-row and maintenance boundaries with their valid companion.')
    parser.add_argument('--batch-size', type=checker.batch_size, default=8,
                        help='Maximum compatible negative clients per compile; 1 preserves isolated checking.')
    args = parser.parse_args()
    if args.actors_only and args.review_only:
        parser.error('Select one focused probe family at a time')
    visibility = ("'ValidatedHistoryBatch' is inaccessible due to 'private' protection level",
                  "cannot find 'ValidatedHistoryBatch' in scope")
    actor_await = ("actor-isolated instance method 'perform' cannot be called from outside of the actor",
                   "expression is 'async' but is not marked with 'await'")
    example_path, example = Path('/probe/Client.swift'), 'ValidatedHistoryBatch.self // expected-error\n'
    for text in visibility:
        diagnostic = f'{example_path}:1:24: error: {text}'
        assert matches_expected(1, diagnostic, example_path, example, visibility)
        assert not matches_expected(0, diagnostic, example_path, example, visibility)
        assert not matches_expected(1, diagnostic.replace(':1:24:', ':2:24:'), example_path, example, visibility)
        assert not matches_expected(1, diagnostic.replace('ValidatedHistoryBatch', 'MissingModule'), example_path, example, visibility)
    assert not matches_expected(1, 'compiler unavailable', example_path, example, visibility)
    for text in actor_await:
        diagnostic = f'{example_path}:1:24: error: {text}'
        assert matches_expected(1, diagnostic, example_path, example, actor_await)
        assert not matches_expected(0, diagnostic, example_path, example, actor_await)
        assert not matches_expected(1, diagnostic.replace(':1:24:', ':2:24:'), example_path, example, actor_await)
    assert not matches_expected(1, 'compiler unavailable', example_path, example, actor_await)
    print('PASS: exact visibility-diagnostic classifier self-checks', flush=True)
    modules = args.modules.resolve()
    valid = ('public runtime client', '''
func use(_ session: LocalStoreSession, _ capture: CapturedActionGroup) async throws -> CommitOutcome {
    try await session.persist(capture: capture)
}
func status(_ session: LocalStoreSession, _ locator: SegmentLocator) async throws -> Int {
    switch try await session.receivedObjectStatus(at: locator) {
    case .pendingValidation: return 1
    case .retainedForAssembly: return 2
    case .accepted: return 0
    case .waiting(let missing): return missing.count
    case .blocked(let roots, let unaccepted): return roots.count + unaccepted.count
    }
}
func history(_ session: LocalStoreSession, _ birth: NoteBirth) async throws -> HistoryPreview? {
    let page = try await session.history(for: .note(birth))
    guard let entry = page.entries.first else { return nil }
    return try await session.preview(entry)
}
func restore(_ session: LocalStoreSession, _ entry: HistoryEntry, _ generation: CapturedNoteGeneration) async throws -> CapturedActionGroup {
    let source = try await session.restoration(from: entry, as: generation)
    return try await CapturedActionGroup(snapshot: session.snapshot(), restoring: [source])
}
func merge(_ session: LocalStoreSession, _ birth: NoteBirth) async throws -> NoteReductionPreview {
    try await session.reductionPreview(for: birth)
}
func commands(_ session: LocalStoreSession, _ birth: NoteBirth, _ revision: OperationID) async throws -> CompensationPreparation {
    let _ = try await session.undoCandidates(scope: .note(birth), direction: .undo)
    let _ = try await session.conflicts(for: birth)
    let _ = try await session.copyVersion(for: birth, revision: revision, generation: 1)
    let _ = try await session.chooseVersion(for: birth, revision: revision, generation: 1)
    return try await session.prepareCompensation(scope: .note(birth), direction: .undo)
}
func ordinary(_ snapshot: StoreSnapshot, _ changes: [CapturedNoteChange]) throws -> [CapturedActionGroup] {
    try [OrdinaryActionKind.savedEdit, .rename, .labels, .createImportBatch, .deleteBatch].map {
        try CapturedActionGroup(snapshot: snapshot, kind: $0, changes: changes)
    }
}
func compensation(_ session: LocalStoreSession, _ automatic: AutomaticCompensation, _ review: CompensationReview) async throws {
    let _ = try await session.applyCompensation(automatic)
    let _ = try await session.applyReviewedCompensation(review)
    let _ = try await session.applyReviewedCompensation(automatic.forReview())
}
func snapshot(_ session: LocalStoreSession, _ preview: GeneralSnapshotPreviewV1) async throws -> VerifiedGeneralSnapshotClaims {
    let _: GeneralSnapshotCapture = try await session.captureGeneralSnapshot()
    return try await session.verifyGeneralSnapshot(preview)
}
func saveSnapshot(_ session: LocalStoreSession, _ handle: SnapshotCommitHandle) async throws -> SnapshotCommitOutcome {
    let _ = try await session.persistGeneralSnapshot(capture: session.captureGeneralSnapshot())
    return try await session.retry(snapshot: handle)
}
func bootstrap(_ selection: LocalStoreSelection, _ root: SegmentLocator, _ protection: ObjectProtectionV1) async throws -> LocalStoreSession {
    let candidate = try await BootstrapCandidate.resume(selection: selection, protection: protection)
    return try await candidate.complete(snapshot: root)
}
func rebuild(_ session: LocalStoreSession) async throws -> StoreSnapshot {
    try await session.rebuildCurrentRows()
}
''', None)
    issuers = [
        ('scoped history visibility', '''
func wrong() { _ = CheckedQueryHistory.self } // expected-error
''', ("cannot find 'CheckedQueryHistory' in scope", "'CheckedQueryHistory' is inaccessible due to 'internal' protection level")),
        ('checked envelope visibility', '''
func wrong() { _ = CheckedEnvelopeRecords.self } // expected-error
''', ("cannot find 'CheckedEnvelopeRecords' in scope", "'CheckedEnvelopeRecords' is inaccessible due to 'internal' protection level")),
        ('bootstrap construction issuer', '''
func wrong(_ selection: LocalStoreSelection, _ protection: ObjectProtectionV1) {
    let _ = BootstrapCandidate(selection: selection, lane: .init(), protection: protection) // expected-error
}
''', "'BootstrapCandidate' initializer is inaccessible due to 'private' protection level"),
        ('waiting requirement versus saved receipt', '''
func wrong(_ model: inout HeadlessModel, _ r: ObjectRequirement) throws {
    try model.complete(r) // expected-error
}
''', "cannot convert value of type 'ObjectRequirement' to expected argument type 'AcceptedHistoryReceipt'"),
        ('receive outcome versus saved generations', '''
func wrong(_ model: inout HeadlessModel, _ r: ObjectAcceptanceOutcome) throws {
    try model.complete(r) // expected-error
}
''', "cannot convert value of type 'ObjectAcceptanceOutcome' to expected argument type 'AcceptedHistoryReceipt'"),
        ('snapshot commit issuer', '''
func wrong(_ c: GeneralSnapshotCapture) {
    let _ = SnapshotCommitHandle(session: UUID(), capture: c) // expected-error
}
''', "'SnapshotCommitHandle' initializer is inaccessible due to 'private' protection level"),
        ('snapshot receipt issuer', '''
func wrong(_ r: AcceptedSnapshotReceipt) {
    let _ = AcceptedSnapshotReceipt(store: r.store, session: UUID(), sequence: r.sequence, snapshot: r.snapshot, pages: r.pages) // expected-error
}
''', "'AcceptedSnapshotReceipt' initializer is inaccessible due to 'private' protection level"),
        ('snapshot coverage versus saved generations', '''
func wrong(_ model: inout HeadlessModel, _ r: AcceptedSnapshotReceipt) throws {
    try model.complete(r) // expected-error
}
''', "cannot convert value of type 'AcceptedSnapshotReceipt' to expected argument type 'AcceptedHistoryReceipt'"),
        ('snapshot receipt decoding boundary', '''
func take<T: Decodable>(_ type: T.Type) {}
func wrong() { take(AcceptedSnapshotReceipt.self) } // expected-error
''', "requires that 'AcceptedSnapshotReceipt' conform to 'Decodable'"),
        ('snapshot capture issuer', '''
func wrong(_ c: GeneralSnapshotCapture) {
    let _ = GeneralSnapshotCapture(store: c.store, collection: c.collection, through: c.through, bootstrapSnapshot: c.bootstrapSnapshot, records: c.records, retentionParents: c.retentionParents, session: UUID()) // expected-error
}
''', "'GeneralSnapshotCapture' initializer is inaccessible due to 'private' protection level"),
        ('snapshot semantic issuer', '''
func wrong(_ c: VerifiedGeneralSnapshotClaims, _ id: UUID) {
    let _ = VerifiedGeneralSnapshotClaims(store: c.store, collection: c.collection, session: id, snapshot: c.snapshot, through: c.checkedThrough, operationIDs: c.operationIDs) // expected-error
}
''', "'VerifiedGeneralSnapshotClaims' initializer is inaccessible due to 'private' protection level"),
        ('preview requires semantic verification', '''
func take(_ c: VerifiedGeneralSnapshotClaims) {}
func wrong(_ c: GeneralSnapshotPreviewV1) { take(c) } // expected-error
''', "cannot convert value of type 'GeneralSnapshotPreviewV1' to expected argument type 'VerifiedGeneralSnapshotClaims'"),
        ('snapshot evidence decoding boundary', '''
func take<T: Decodable>(_ type: T.Type) {}
func wrong() { take(VerifiedGeneralSnapshotClaims.self) } // expected-error
''', "requires that 'VerifiedGeneralSnapshotClaims' conform to 'Decodable'"),
        ('undo candidates issuer', '''
func wrong(_ s: CausalUndoSelectionV1) {
    let _ = UndoCandidates(scope: .collection, direction: .undo, selection: s) // expected-error
}
''', "'UndoCandidates' initializer is inaccessible due to 'fileprivate' protection level"),
        ('compensation proposal issuer', '''
func wrong(_ c: UndoCandidates, _ s: StoreSnapshot, _ t: ActionReference, _ id: ActionID) throws {
    let _ = try CompensationProposal(candidate: id, candidates: c, effects: [], snapshot: s, testedBirths: [], target: t, restorations: [], generation: 1) // expected-error
}
''', "'CompensationProposal' initializer is inaccessible due to 'fileprivate' protection level"),
        ('automatic compensation issuer', '''
func wrong(_ p: CompensationProposal) {
    let _ = AutomaticCompensation(p) // expected-error
}
''', "'AutomaticCompensation' initializer is inaccessible due to 'fileprivate' protection level"),
        ('review compensation issuer', '''
func wrong(_ p: CompensationProposal) {
    let _ = CompensationReview(p) // expected-error
}
''', "'CompensationReview' initializer is inaccessible due to 'fileprivate' protection level"),
        ('conflict revisions issuer', '''
func wrong(_ c: CurrentNoteCellV1) {
    let _ = ConflictRevisions(current: c, alternatives: [], representedSeparately: []) // expected-error
}
''', "'ConflictRevisions' initializer is inaccessible due to 'fileprivate' protection level"),
        ('reduction preview issuer', '''
func wrong(_ birth: NoteBirth, _ reduction: NoteReductionV1) {
    let _ = NoteReductionPreview(birth: birth, through: 1, reduction: reduction) // expected-error
}
''', "'NoteReductionPreview' initializer is inaccessible due to 'fileprivate' protection level"),
        ('restoration issuer', '''
func wrong(_ g: CapturedNoteGeneration, _ v: PlaintextNoteValue, _ s: LocalStoreID, _ r: RestorationReference) {
    let _ = CapturedRestoration(generation: g, value: v, session: UUID(), store: s, through: 1, reference: r) // expected-error
}
''', "'CapturedRestoration' initializer is inaccessible due to 'fileprivate' protection level"),
        ('history cursor issuer', '''
func wrong(_ s: StoreSnapshot, _ id: OperationID) {
    let _ = HistoryCursor(session: UUID(), store: s.store, query: .deletions, through: s.through, after: id) // expected-error
}
''', "'HistoryCursor' initializer is inaccessible due to 'fileprivate' protection level"),
        ('history entry issuer', '''
func wrong(_ s: StoreSnapshot, _ id: OperationID, _ b: NoteBirth, _ a: ActionID) {
    let _ = HistoryEntry(operation: id, birth: b, action: a, session: UUID(), store: s.store, through: s.through) // expected-error
}
''', "'HistoryEntry' initializer is inaccessible due to 'fileprivate' protection level"),
        ('history preview issuer', '''
func wrong(_ e: HistoryEntry, _ a: ActionV1, _ state: HistoricalNoteState) {
    let _ = HistoryPreview(entry: e, action: a, state: state) // expected-error
}
''', "'HistoryPreview' initializer is inaccessible due to 'fileprivate' protection level"),
        ('commit handle issuer', '''
func wrong(_ c: CapturedActionGroup) { let _ = CommitHandle(session: UUID(), id: UUID(), capture: c) } // expected-error
''', "'CommitHandle' initializer is inaccessible due to 'fileprivate' protection level"),
        ('receipt issuer', '''
func wrong(_ r: AcceptedHistoryReceipt, _ c: CapturedActionGroup) {
    let _ = AcceptedHistoryReceipt(session: UUID(), store: r.store, sequence: r.sequence, object: r.object, capture: c) // expected-error
}
''', "'AcceptedHistoryReceipt' initializer is inaccessible due to 'fileprivate' protection level"),
        ('prepared change issuer', '''
func wrong(_ s: StoreSnapshot) { let _ = PreparedModelChange(snapshot: s, liveGeneration: 1) } // expected-error
''', "'PreparedModelChange' initializer is inaccessible due to 'fileprivate' protection level"),
        ('snapshot issuer', '''
func wrong(_ s: StoreSnapshot) {
    let _ = StoreSnapshot(session: UUID(), store: s.store, through: s.through, viewEpoch: s.viewEpoch, notes: s.notes, context: s.context, presentationEpoch: UUID()) // expected-error
}
''', "'StoreSnapshot' initializer is inaccessible due to 'fileprivate' protection level"),
        ('settings issuer', '''
func wrong(_ s: StoreSnapshot) { let _ = EmptySettingsState(generation: 1, store: s.store, session: UUID()) } // expected-error
''', "'EmptySettingsState' initializer is inaccessible due to 'fileprivate' protection level"),
    ]
    extra = [
        ('blocked diagnostic is not commit ownership', '''
func wrong(_ s: LocalStoreSession, _ b: RejectedPrerequisite) async throws {
    let _ = try await s.retry(commit: b) // expected-error
}
''', "cannot convert value of type 'RejectedPrerequisite' to expected argument type 'CommitHandle'"),
        ('exact history object boundary', '''
func wrong() { let _ = HistoryObject.self } // expected-error
''', "cannot find 'HistoryObject' in scope"),
        ('history input issuer', '''
func wrong() { let _ = ValidatedHistoryBatch.self } // expected-error
''', "cannot find 'ValidatedHistoryBatch' in scope"),
        ('checked current basis issuer', '''
func wrong() { let _ = CheckedCurrentBasis.self } // expected-error
''', "cannot find 'CheckedCurrentBasis' in scope"),
        ('capture generations immutable', '''
func wrong(_ input: CapturedActionGroup) { var c = input; c.covered = [] } // expected-error
''', "cannot assign to property: 'covered' is a 'let' constant"),
        ('review requires explicit apply', '''
func wrong(_ s: LocalStoreSession, _ review: CompensationReview) async throws {
    let _ = try await s.applyCompensation(review) // expected-error
}
''', "cannot convert value of type 'CompensationReview' to expected argument type 'AutomaticCompensation'"),
        ('disclosed effects alone grant no automatic admission', '''
func wrong(_ s: LocalStoreSession, _ p: CompensationProposal) async throws {
    let _ = try await s.applyCompensation(p) // expected-error
}
''', "cannot convert value of type 'CompensationProposal' to expected argument type 'AutomaticCompensation'"),
        ('receipt is not a retry handle', '''
func wrong(_ s: LocalStoreSession, _ r: AcceptedHistoryReceipt) async throws {
    let _ = try await s.retry(commit: r) // expected-error
}
''', "cannot convert value of type 'AcceptedHistoryReceipt' to expected argument type 'CommitHandle'"),
        ('receipt cannot be deserialized', '''
func decode<T: Decodable>(_ t: T.Type) {}
func wrong() { decode(AcceptedHistoryReceipt.self) } // expected-error
''', "requires that 'AcceptedHistoryReceipt' conform to 'Decodable'"),
        ('no fixed nonce sealer', '''
func wrong(_ c: CollectionID, _ w: WriterEpoch, _ p: ObjectProtectionV1) throws {
    let _ = try ObjectEnvelopeV1.seal(payload: [], kind: .changes, collection: c, writer: w, sequence: 0, protection: p, testNonce: nil) // expected-error
}
''', "extra argument 'testNonce' in call"),
    ]
    for kind in ['undo', 'redo', 'nativeUndo', 'historicalRecovery', 'conflictChoice', 'conflictCopy', 'restoreBatch']:
        extra.append((kind + ' requires its issued command inputs', '''
func wrong(_ s: StoreSnapshot, _ changes: [CapturedNoteChange]) throws {
    let _ = try CapturedActionGroup(snapshot: s, kind: .%s, changes: changes) // expected-error
}
''' % kind, "type 'OrdinaryActionKind' has no member '%s'" % kind))
    with checker.temporary_artifacts(prefix='nv-runtime-typecheck-') as tmp:
        command = ['swiftc', '-swift-version', '6', '-strict-concurrency=complete', '-strict-memory-safety',
                   '-warnings-as-errors', '-typecheck', '-I', str(modules),
                   '-module-cache-path', checker.compiler_cache_path('swiftc', modules, tmp),
                   '-Xcc', '-I' + str(ROOT / 'NVStorage/.deps/sqlcipher/include'),
                   '-Xcc', '-I' + str(ROOT/'NVStorage/Sources/CStorageIO/include')]
        if sys.platform == 'darwin':
            apple = modules.parent/'CAppleFileAccess.build/module.modulemap'
            assert apple.is_file(), apple
            command += ['-Xcc', '-fmodule-map-file=' + str(apple)]
        for p in [modules.parent / 'CArgon2.build/module.modulemap', modules.parent / 'CStorageIO.build/module.modulemap',
                  modules.parent / 'CSQLMaintenance.build/module.modulemap',
                  ROOT / 'NVStorage/Sources/CSQLCipher/module.modulemap', modules.parent / 'CZstd.build/module.modulemap']:
            assert p.is_file(), p
            command.extend(['-Xcc', '-fmodule-map-file=' + str(p)])
        runtime = sorted((ROOT / 'NVStorage/Sources/NVStorageRuntime').glob('*.swift'))
        runtime += [modules.parent / 'NVStorageRuntime.build/DerivedSources/resource_bundle_accessor.swift']
        count = 0
        locality = [
            ('current codec and maintenance companion', '''
func use(_ owner: LocalStoreSession, _ cell: CurrentNoteCellV1, _ bytes: [UInt8]) async throws {
    let dictionary = try CurrentRowDictionaryV1(bytes: bytes)
    let encoder = try CurrentRowEncoderV1(dictionary: dictionary), decoder = try CurrentRowDecoderV1()
    let _ = try decoder.decode(encoder.encode(cell)) { _ in dictionary }
    let _ = try await owner.recodeCurrentRows(basedOn: owner.snapshot(), maximumRows: 32, trainDictionary: true)
    await owner.cancelOptionalMaintenance()
    switch try await owner.compactPrivateStore(budget: VacuumBudget()) {
    case .completed, .interrupted: break
    case .skipped(let reason):
        switch reason { case .requiredWork, .storeBudget, .spaceHeadroom: break }
    }
}
''', None),
            ('encoder resources stay on their worker', '''
func take<T: Sendable>(_ value: T) {}
func wrong(_ encoder: CurrentRowEncoderV1) { take(encoder) } // expected-error
''', "does not conform to the 'Sendable' protocol"),
            ('decoder resources stay on their worker', '''
func take<T: Sendable>(_ value: T) {}
func wrong(_ decoder: CurrentRowDecoderV1) { take(decoder) } // expected-error
''', "does not conform to the 'Sendable' protocol"),
            ('dictionary digest is immutable', '''
func wrong(_ dictionary: CurrentRowDictionaryV1) {
    var d = dictionary; d.digest = [] // expected-error
}
''', "cannot assign to property: 'digest' is a 'let' constant"),
            ('recode applicability belongs to its reader', '''
func wrong() { _ = CurrentRecodeCapture.self } // expected-error
''', ("'CurrentRecodeCapture' is inaccessible due to 'private' protection level", "cannot find 'CurrentRecodeCapture' in scope")),
            ('ordinary row batch belongs to its reader', '''
func wrong() { _ = OrdinaryRowBatch.self } // expected-error
''', ("'OrdinaryRowBatch' is inaccessible due to 'private' protection level", "cannot find 'OrdinaryRowBatch' in scope")),
            ('interrupt identity belongs to its connection', '''
func wrong() { _ = VacuumRequest(connection: UUID(), identity: 1) } // expected-error
''', "'VacuumRequest' initializer is inaccessible due to 'fileprivate' protection level"),
        ]
        sibling_command = command + ['-package-name', 'nvstorage', '-module-name', 'NVStorageRuntime', *map(str, runtime)]
        completed = checker.run_probes(sibling_command,
            [(name, 'import Foundation\nimport NVStorageCore\n' + source, error) for name, source, error in locality],
            Path(tmp)/'locality', label='same-module', timeout=60, maximum=args.batch_size)
        assert completed == len(locality)
        if args.locality_only:
            return
        for same in ([] if args.actors_only or args.review_only else [False, True]):
            clients = []
            for name, source, error in [valid] + issuers + extra:
                if same and name == 'history input issuer':
                    error = visibility
                if same and name == 'checked current basis issuer':
                    error = tuple(s.replace('ValidatedHistoryBatch', 'CheckedCurrentBasis') for s in visibility)
                if same and name == 'exact history object boundary':
                    error = tuple(s.replace('ValidatedHistoryBatch', 'HistoryObject') for s in visibility)
                if same and name in ['scoped history visibility', 'checked envelope visibility']:
                    error = None
                source = 'import Foundation\nimport NVStorageCore\n' + ('' if same else 'import NVStorageRuntime\n') + source
                clients.append((name, source, error))
            count += checker.run_probes(sibling_command if same else command, clients,
                Path(tmp)/('same' if same else 'ordinary'), label='same-module' if same else 'ordinary',
                timeout=60, maximum=args.batch_size)
        assert count == (0 if args.actors_only or args.review_only else 92)
        if not args.actors_only:
            graph_cases = [
                ('checked graph cut companion', '''
func use(_ lane: DatabaseLane, _ selection: LocalStoreSelection, _ protection: ObjectProtectionV1) async throws -> RetainedGraph {
    let graph = try await lane.retainedGraph(through: 1, selection: selection, protection: protection)
    return try await graph.causalCut(frontier: Set(graph.operations.keys))
}
''', None),
                ('retained graph constructor belongs to its issuer', '''
func wrong() {
    let _ = RetainedGraph(operations: [:], actions: [:], operationReferences: [:], actionReferences: [:]) // expected-error
}
''', "'RetainedGraph' initializer is inaccessible due to 'private' protection level"),
                ('retained graph checking belongs to its read boundary', '''
func wrong() throws {
    let _ = try RetainedGraph.checked(operations: [:], actions: [:], operationReferences: [:], actionReferences: [:]) // expected-error
}
''', "'checked' is inaccessible due to 'fileprivate' protection level"),
                ('verification admission issuer', '''
func wrong(_ record: VerificationRecord) {
    let _ = AdmittedVerification(record: record, connection: UUID()) // expected-error
}
''', "'AdmittedVerification' initializer is inaccessible due to 'private' protection level"),
                ('checked traversal issuer', '''
func wrong(_ graph: RetainedGraph, _ store: LocalStoreID) {
    let _ = CheckedHistoryTraversal(graph: graph, through: 1, scope: .allOccurrences, connection: UUID(), store: store) // expected-error
}
''', "'CheckedHistoryTraversal' initializer is inaccessible due to 'private' protection level"),
                ('scoped query issuer', '''
func wrong(_ snapshot: StoreSnapshot, _ birth: NoteBirth) {
    let _ = CheckedQueryHistory(scope: .undo(birth), snapshot: snapshot, connection: UUID(), actions: [], alternatives: [], dispositions: []) // expected-error
}
''', "'CheckedQueryHistory' initializer is inaccessible due to 'private' protection level"),
                ('checked envelope issuer', '''
func wrong(_ locator: SegmentLocator) {
    let _ = CheckedEnvelopeRecords(locator: locator, sequence: 1, operations: [], actions: [], operationReferences: [:], actionReferences: [:]) // expected-error
}
''', "'CheckedEnvelopeRecords' initializer is inaccessible due to 'private' protection level"),
                ('scoped query is distinct from complete graph', '''
func use(_ checked: CheckedQueryHistory) {
    let _: RetainedGraph = checked // expected-error
}
''', "cannot convert value of type 'CheckedQueryHistory' to specified type 'RetainedGraph'"),
                ('scoped query companion', '''
import Foundation
func use(_ lane: DatabaseLane, _ selection: LocalStoreSelection, _ protection: ObjectProtectionV1, _ snapshot: StoreSnapshot, _ birth: NoteBirth) async throws -> [ActionV1] {
    let checked = try await CheckedQueryHistory.read(scope: .undo(birth), snapshot: snapshot, session: snapshot.session, lane: lane, selection: selection, protection: protection)
    return try await lane.perform { try checked.undoActions(for: birth, snapshot: snapshot, database: $0, selection: selection) }
}
''', None),
            ]
            count += checker.run_probes(sibling_command,
                [(name, 'import NVStorageCore\n' + source, error) for name, source, error in graph_cases],
                Path(tmp)/'graph', label='same-module', timeout=60, maximum=args.batch_size)
            graph = ROOT / 'NVStorage/Sources/NVStorageRuntime/GraphMaterialization.swift'
            source = graph.read_text() + '''
private func uncheckedGraph() {
    let _ = RetainedGraph(operations: [:], actions: [:], operationReferences: [:], actionReferences: [:]) // expected-error
}
'''
            path = Path(tmp) / 'GraphMaterialization.swift'
            path.write_text(source)
            inputs = [path if p == graph else p for p in runtime]
            run = subprocess.run(command + ['-package-name', 'nvstorage', '-module-name', 'NVStorageRuntime', *map(str, inputs)],
                                 text=True, capture_output=True, timeout=60)
            error = "'RetainedGraph' initializer is inaccessible due to 'private' protection level"
            assert matches_expected(run.returncode, run.stderr, path, source, error), run.stderr
            print('PASS: same-file retained graph construction requires its checked issuer', flush=True); count += 1
            for filename, type_name, source in [
                ('Verification.swift', 'VerifiedVerification', '''
private func wrong(_ admitted: AdmittedVerification) {
    let _ = VerifiedVerification(admitted: admitted) // expected-error
}
'''),
                ('GraphMaterialization.swift', 'CheckedGraphRows', '''
private func wrong(_ context: AuthoringContextV1, _ selection: LocalStoreSelection, _ bootstrap: SegmentLocator) {
    let _ = CheckedGraphRows(start: [], target: 1, cells: [], context: context, connection: UUID(), selection: selection, bootstrap: bootstrap, purpose: .opening) // expected-error
}
'''),
            ]:
                issuer = ROOT/'NVStorage/Sources/NVStorageRuntime'/filename
                source = issuer.read_text() + source
                path = Path(tmp)/filename
                path.write_text(source)
                inputs = [path if p == issuer else p for p in runtime]
                run = subprocess.run(command + ['-package-name', 'nvstorage', '-module-name', 'NVStorageRuntime', *map(str, inputs)], text=True, capture_output=True, timeout=60)
                error = f"'{type_name}' initializer is inaccessible due to 'private' protection level"
                assert matches_expected(run.returncode, run.stderr, path, source, error), run.stderr
                print('PASS: same-file', type_name, 'construction requires its issuer', flush=True); count += 1
            routing = ROOT / 'NVStorage/Sources/NVStorageRuntime/OrdinaryDatabase.swift'
            original = routing.read_text()
            for name, switch, member in [
                ('action routing', 'switch kind {', ', .undo'),
                ('effect routing', 'switch effect {', ', .adoptAutomatic'),
            ]:
                assert original.count(switch) == 1 and original.count(member) == 1
                source = original.replace(switch, switch + ' // expected-error', 1).replace(member, '', 1)
                path = Path(tmp) / 'OrdinaryDatabase.swift'
                path.write_text(source)
                inputs = [path if p == routing else p for p in runtime]
                run = subprocess.run(command + ['-package-name', 'nvstorage', '-module-name', 'NVStorageRuntime', *map(str, inputs)],
                                     text=True, capture_output=True, timeout=60)
                assert matches_expected(run.returncode, run.stderr, path, source, 'switch must be exhaustive'), run.stderr
                print('PASS: actual', name, 'requires every supported variant', flush=True); count += 1
            if args.review_only:
                assert count == 14
                return
            # Command provenance remains required inside the Runtime module too.
            intents = [
                ('restore', 'missing argument for parameter #1 in call'),
                ('choice', "missing arguments for parameters 'selected', 'heads' in call"),
                ('copy', "missing arguments for parameters 'source', 'revision', 'key', 'slot', 'reused' in call"),
                ('historical', "missing arguments for parameters 'source', 'revision', 'fields' in call"),
                ('compensation', "missing arguments for parameters 'direction', 'target', 'authorization', 'restorations' in call"),
                ('native', 'missing argument for parameter #1 in call'),
            ]
            count += checker.run_probes(sibling_command,
                [(name + ' requires command provenance',
                  'import NVStorageCore\nfunc wrong() { let _: CapturedActionIntent = .%s() } // expected-error\n' % name, error)
                 for name, error in intents],
                Path(tmp)/'intent', label='same-module', timeout=60, maximum=args.batch_size)

            history = ROOT / 'NVStorage/Sources/NVStorageRuntime/HistoryDatabase.swift'
            source = history.read_text() + '''
private func uncheckedBatch() {
    let _ = ValidatedHistoryBatch(objects: [], descriptor: nil) // expected-error
}
'''
            path = Path(tmp) / 'HistoryDatabase.swift'
            path.write_text(source)
            inputs = [path if p == history else p for p in runtime]
            cmd = command + ['-package-name', 'nvstorage', '-module-name', 'NVStorageRuntime', *map(str, inputs)]
            run = subprocess.run(cmd, text=True, capture_output=True, timeout=60)
            error = "'ValidatedHistoryBatch' initializer is inaccessible due to 'private' protection level"
            assert matches_expected(run.returncode, run.stderr, path, source, error), run.stderr
            print('PASS: actual acceptance bundle restricts issuance to validators', flush=True); count += 1

            rejection = ROOT / 'NVStorage/Sources/NVStorageRuntime/ReceiveRejection.swift'
            original = rejection.read_text()
            for name, branch in [
                ('storage', 'case .unsupported: self = .unsupported'),
                ('history', 'case .invalidBeforeAfter: self = .invalidBeforeAfter'),
                ('encoding', 'case .missingDependency, .keyDerivationFailure: return nil'),
            ]:
                assert original.count(branch) == 1
                start = 'private init%s(%s error:' % ('' if name == 'history' else '?', name)
                prefix, section = original.split(start, 1)
                assert section.count('switch error {') >= 1
                section = section.replace('switch error {', 'switch error { // expected-error', 1)
                source = (prefix + start + section).replace(branch, '', 1)
                path = Path(tmp) / 'ReceiveRejection.swift'
                path.write_text(source)
                inputs = [path if p == rejection else p for p in runtime]
                cmd = command + ['-package-name', 'nvstorage', '-module-name', 'NVStorageRuntime', *map(str, inputs)]
                run = subprocess.run(cmd, text=True, capture_output=True, timeout=60)
                assert matches_expected(run.returncode, run.stderr, path, source, 'switch must be exhaustive'), (name, run.stderr)
                print('PASS: actual', name, 'receive classification requires complete case handling', flush=True); count += 1
        # Same-module callers exercise actor and connection boundaries directly.
        actor_cases = [
            ('connection context belongs to opening checks', '''
func wrong(_ db: Database) {
    db.checkedContext = nil // expected-error
}
''', "'checkedContext' is inaccessible due to 'private' protection level"),
            ('owned operation scope belongs to the connection', '''
func wrong(_ db: Database) {
    db.ownedOperationActive = true // expected-error
}
''', "'ownedOperationActive' is inaccessible due to 'private' protection level"),
            ('owned operation entry belongs to its actor boundary', '''
func wrong(_ db: Database) throws {
    try db.withOwnedOperation {} // expected-error
}
''', "'withOwnedOperation' is inaccessible due to 'fileprivate' protection level"),
            ('prepared reconstruction issuer', '''
func wrong() { _ = PreparedReconstruction.self } // expected-error
''', ("'PreparedReconstruction' is inaccessible due to 'private' protection level", "cannot find 'PreparedReconstruction' in scope")),
            ('received preparation boundary', '''
func wrong() { _ = PreparedCandidate.self } // expected-error
''', ("'PreparedCandidate' is inaccessible due to 'fileprivate' protection level", "cannot find 'PreparedCandidate' in scope")),
            ('checked snapshot issuer', '''
func wrong(_ preview: GeneralSnapshotPreviewV1, _ selection: LocalStoreSelection, _ protection: ObjectProtectionV1) {
    let _ = CheckedSnapshotAcceptance(preview: preview, through: 1, operationIDs: [], selection: selection, protection: protection, connection: UUID(), parents: .init()) // expected-error
}
''', "'CheckedSnapshotAcceptance' initializer is inaccessible due to 'private' protection level"),
            ('checked retention-parent issuer', '''
func wrong() { _ = CheckedRetentionParents.self } // expected-error
''', ("'CheckedRetentionParents' is inaccessible due to 'private' protection level", "cannot find 'CheckedRetentionParents' in scope")),
            ('checked executor and queue key', '''
import Dispatch
func acceptSendable<T: Sendable>(_ value: T) {}
func use(_ executor: StorageExecutor) {
    acceptSendable(executor)
    acceptSendable(DispatchSpecificKey<UInt8>())
}
''', None),
            ('actor caller', '''
func use(_ owner: DatabaseLane) async throws -> Int64 {
    try await owner.perform { try $0.acceptedThrough() }
}
''', None),
            ('actor access requires await', '''
func wrong(_ owner: DatabaseLane) async throws {
    let _ = try owner.perform { try $0.acceptedThrough() } // expected-error
}
''', actor_await),
            ('connection stays owned', '''
func wrong(_ owner: DatabaseLane) async throws {
    let _ = try await owner.perform { $0 } // expected-error
}
''', "type 'Database' does not conform to the 'Sendable' protocol"),
            ('transaction turn stays synchronous', '''
func wrong(_ owner: DatabaseLane) async throws {
    let _ = try await owner.perform { db in await Task.yield(); return try db.acceptedThrough() } // expected-error
}
''', "cannot pass function of type '@Sendable (Database) async throws -> Int64' to parameter expecting synchronous function type"),
            ('session lifecycle is controlled', '''
extension LocalStoreSession {
    func wrong() { lifecycle = .open } // expected-error
}
''', "cannot assign to property: 'lifecycle' setter is inaccessible"),
            ('running commit owns complete input', '''
func wrong() { let _: LocalCommitState = .running() } // expected-error
''', 'missing argument for parameter #1 in call'),
        ]
        for name, source, error in actor_cases:
            path = Path(tmp) / 'Client.swift'
            source = 'import Foundation\nimport NVStorageCore\n' + source
            path.write_text(source)
            # Emit SIL as well as type-checking to include region-isolation diagnostics.
            cmd = [x for x in command if x != '-typecheck'] + ['-emit-sil', '-o', str(Path(tmp)/'probe.sil'),
                '-whole-module-optimization', '-package-name', 'nvstorage', '-module-name', 'NVStorageRuntime',
                *map(str, runtime), str(path)]
            run = subprocess.run(cmd, text=True, capture_output=True, timeout=60)
            assert matches_expected(run.returncode, run.stderr, path, source, error), (name, run.stderr)
            print('PASS: same-module', name, flush=True); count += 1
        # The actual executor's conformance must keep checking its stored state.
        database = ROOT / 'NVStorage/Sources/NVStorageRuntime/Database.swift'
        declaration = 'final class StorageExecutor: SerialExecutor {'
        original = database.read_text()
        assert original.count(declaration) == 1, 'Review the checked executor boundary after changing its declaration'
        changed = original.replace(declaration, declaration + '\n    var mutableProbeState = 0 // expected-error', 1)
        path = Path(tmp) / 'Database.swift'
        path.write_text(changed)
        probe_sources = [path if p == database else p for p in runtime]
        cmd = [x for x in command if x != '-typecheck'] + ['-emit-sil', '-o', str(Path(tmp)/'probe.sil'),
            '-whole-module-optimization', '-package-name', 'nvstorage', '-module-name', 'NVStorageRuntime',
            *map(str, probe_sources)]
        run = subprocess.run(cmd, text=True, capture_output=True, timeout=60)
        diagnostic = "stored property 'mutableProbeState' of 'Sendable'-conforming class 'StorageExecutor' is mutable"
        assert matches_expected(run.returncode, run.stderr, path, changed, diagnostic), run.stderr
        print('PASS: actual executor rejects mutable shared storage', flush=True); count += 1
        transfer = 'let retired = unsafe RetiredHandles(handle: handle, owner: owner)'
        assert original.count(transfer) == 1, 'Review the final handle-release boundary after changing its construction'
        changed = original.replace(transfer, transfer + '''
        func requireSendable<T: Sendable>(_ value: T) {}
        unsafe requireSendable(retired) // expected-error''', 1)
        path.write_text(changed)
        run = subprocess.run(cmd, text=True, capture_output=True, timeout=60)
        diagnostic = "type 'StorageExecutor.RetiredHandles' does not conform to the 'Sendable' protocol"
        assert matches_expected(run.returncode, run.stderr, path, changed, diagnostic), run.stderr
        print('PASS: final C handles remain confined to synchronous release', flush=True); count += 1
        synchronous = 'queue.sync { self.checkIsolation(); release() }'
        assert original.count(synchronous) == 1, 'Review the nonescaping final-release closure after changing its queue hop'
        changed = original.replace(synchronous, synchronous.replace('queue.sync', 'queue.async') + ' // expected-error', 1)
        path.write_text(changed)
        run = subprocess.run(cmd, text=True, capture_output=True, timeout=60)
        diagnostic = ("escaping closure captures non-escaping parameter 'release'",
                      "capture of 'release' with non-Sendable type '() -> Void' in a '@Sendable' closure")
        assert matches_expected(run.returncode, run.stderr, path, changed, diagnostic), run.stderr
        print('PASS: actual final-release closure rejects an asynchronous queue hop', flush=True); count += 1
        # The work-item overload isolates the language's lifetime check from SDK Sendable annotations.
        changed = original.replace(synchronous,
            'queue.async(execute: DispatchWorkItem { self.checkIsolation(); release() }) // expected-error', 1)
        path.write_text(changed)
        run = subprocess.run(cmd, text=True, capture_output=True, timeout=60)
        diagnostic = "escaping closure captures non-escaping parameter 'release'"
        assert matches_expected(run.returncode, run.stderr, path, changed, diagnostic), run.stderr
        print('PASS: actual final-release borrow rejects an escaping work item', flush=True); count += 1
        # A new raw C borrow must be explicitly acknowledged at its actual call site.
        key_call = 'try unsafe check(sqlite3_key(handle, $0.baseAddress, Int32($0.count))) }'
        assert original.count(key_call) == 1, 'Review the scoped SQLCipher key borrow after changing its call'
        changed = original.replace(key_call, key_call.replace('try unsafe', 'try') + ' // expected-error', 1)
        path.write_text(changed)
        run = subprocess.run(cmd, text=True, capture_output=True, timeout=60)
        diagnostic = "expression uses unsafe constructs but is not marked with 'unsafe'"
        assert matches_expected(run.returncode, run.stderr, path, changed, diagnostic), run.stderr
        print('PASS: actual C key borrow requires an explicit memory-safety boundary', flush=True); count += 1
        assert count == (19 if args.actors_only else 135)


if __name__ == '__main__':
    main()
