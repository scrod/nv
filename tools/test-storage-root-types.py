#!/usr/bin/env python3
"""Ordinary/same-module construction and isolation probes for the actual root owner."""
import argparse
import importlib.util
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('typechecks', ROOT / 'tools/test-swift-storage-types.py')
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--modules', type=Path, required=True)
    parser.add_argument('--batch-size', type=checker.batch_size, default=8,
                        help='Maximum compatible negative clients per compile; 1 preserves isolated checking.')
    args = parser.parse_args()
    modules = args.modules.resolve()
    cases = [
        ('accepted-name cursor issuer', '''
func wrong(_ store: LocalStoreID) {
    _ = RepositoryInventoryCursor(store: store, session: UUID(), through: 1, afterSequence: 0, afterObject: []) // expected-error
}
''', ("cannot find 'RepositoryInventoryCursor' in scope", "'RepositoryInventoryCursor' initializer is inaccessible due to 'fileprivate' protection level")),
        ('accepted-name batch issuer', '''
func wrong() {
    _ = RepositoryInventoryBatch(context: fatalError(), entries: [], continuation: nil) // expected-error
}
''', ("cannot find 'RepositoryInventoryBatch' in scope", "'RepositoryInventoryBatch' initializer is inaccessible due to 'fileprivate' protection level")),
        ('accepted-name observation issuer', '''
func wrong(_ permission: RepositoryRootPermission) {
    _ = RepositoryInventoryCheck(batch: fatalError(), permission: permission, failures: [], reads: 0) // expected-error
}
''', ("cannot find 'RepositoryInventoryCheck' in scope", "'RepositoryInventoryCheck' initializer is inaccessible due to 'fileprivate' protection level")),
        ('verified provider observation issuer', '''
func wrong() {
    _ = VerifiedRepositoryObservation(context: fatalError(), hint: fatalError(), object: fatalError()) // expected-error
}
''', ("cannot find 'VerifiedRepositoryObservation' in scope", "'VerifiedRepositoryObservation' initializer is inaccessible due to 'fileprivate' protection level")),
        ('repair source issuer', '''
func wrong(_ root: RepositoryRootSession, _ permission: RepositoryRootPermission, _ descriptor: BootstrapDescriptorV1) {
    _ = RepositoryRepairSource(root: root, permission: permission, descriptor: descriptor) // expected-error
}
''', "'RepositoryRepairSource' initializer is inaccessible due to 'fileprivate' protection level"),
        ('repair status consumer', '''
func use(_ owner: CollectionSession) async {
    _ = await owner.repositoryRepairStatus()
}
''', None),
        ('complete repair prefix issuer', '''
func wrong(_ cursor: RepositoryPublicationCursor) {
    _ = CheckedRepositoryRepair(through: 1, objectCount: 1, beginning: cursor) // expected-error
}
''', ("cannot find 'CheckedRepositoryRepair' in scope", "'CheckedRepositoryRepair' initializer is inaccessible due to 'fileprivate' protection level")),
        ('repair namespace issuer', '''
func wrong(_ permission: RepositoryRootPermission) {
    _ = RepositoryRepairNamespace(permission: permission, identity: UUID()) // expected-error
}
''', ("cannot find 'RepositoryRepairNamespace' in scope", "'RepositoryRepairNamespace' initializer is inaccessible due to 'fileprivate' protection level")),
        ('root consumer companion', '''
func use(_ owner: RepositoryRootSession) async throws -> RepositoryEntryObservation {
    let permit = try await owner.permission()
    return try await owner.observe("NV Data", using: permit)
}
''', None),
        ('permission issuer', '''
func wrong() { _ = RepositoryRootPermission(session: UUID(), generation: 0) } // expected-error
''', "'RepositoryRootPermission' initializer is inaccessible due to 'fileprivate' protection level"),
        ('observation issuer', '''
func wrong(_ p: RepositoryRootPermission) throws { _ = try RepositoryEntryObservation(permission: p, words: [1,2,3,4,5,6,7,8,9], relative: "note") } // expected-error
''', "'RepositoryEntryObservation' initializer is inaccessible due to 'fileprivate' protection level"),
        ('owner construction', '''
func wrong() { _ = RepositoryRootSession(lane: fatalError()) } // expected-error
''', "'RepositoryRootSession' initializer is inaccessible due to 'private' protection level"),
        ('permission is live authority', '''
func decode<T: Decodable>(_ value: T.Type) {}
func wrong() { decode(RepositoryRootPermission.self) } // expected-error
''', "requires that 'RepositoryRootPermission' conform to 'Decodable'"),
        ('observation issuer survives decoding', '''
func decode<T: Decodable>(_ value: T.Type) {}
func wrong() { decode(RepositoryEntryObservation.self) } // expected-error
''', "requires that 'RepositoryEntryObservation' conform to 'Decodable'"),
        ('root lease confinement', '''
func wrong() { _ = RootLease.self } // expected-error
''', ("cannot find 'RootLease' in scope", "'RootLease' is inaccessible due to 'private' protection level")),
        ('lifecycle changes use owner methods', '''
func wrong(_ root: RepositoryRootSession) async { await root.state = .active } // expected-error
''', ("cannot assign to property: 'state' setter is inaccessible",
      "actor-isolated property 'state' can not be mutated from a nonisolated context")),
        ('permission is distinct from local capture', '''
func wrong(_ s: LocalStoreSession, _ p: RepositoryRootPermission) async throws {
    _ = try await s.persist(capture: p) // expected-error
}
''', "cannot convert value of type 'RepositoryRootPermission' to expected argument type 'CapturedActionGroup'"),
        ('root control is actor isolated', '''
func wrong(_ root: RepositoryRootSession) throws { _ = try root.permission() } // expected-error
''', ("call to actor-isolated instance method 'permission()' in a synchronous nonisolated context",
      "actor-isolated instance method 'permission()' cannot be called from outside of the actor")),
        ('immutable installation consumer companion', '''
func use(_ root: RepositoryRootSession, _ descriptor: BootstrapDescriptorV1) async throws {
    let object = try ImmutableRepositoryObject.descriptor(descriptor, collection: descriptor.collection, keyID: descriptor.keyID)
    let permit = try await root.permission()
    if case .verified(let receipt) = try await root.install(object, for: descriptor, using: permit) {
        try await root.validate(receipt, for: object, using: permit)
    }
}
''', None),
        ('immutable locator renderer', '''
func wrong() { _ = ImmutableRepositoryLocator("../foreign") } // expected-error
''', "'ImmutableRepositoryLocator' initializer is inaccessible due to 'private' protection level"),
        ('checked object issuer', '''
func wrong(_ locator: ImmutableRepositoryLocator, _ collection: CollectionID) {
    _ = ImmutableRepositoryObject(locator: locator, collection: collection, keyID: nil, bytes: []) // expected-error
}
''', "'ImmutableRepositoryObject' initializer is inaccessible due to 'private' protection level"),
        ('installation evidence issuer', '''
func wrong(_ object: ImmutableRepositoryObject, _ permit: RepositoryRootPermission) {
    _ = ImmutableInstallation(object: object, permission: permit, operation: UUID(), existing: false) // expected-error
}
''', "'ImmutableInstallation' initializer is inaccessible due to 'fileprivate' protection level"),
        ('coherent read issuer', '''
func wrong(_ observation: RepositoryEntryObservation) {
    _ = RepositoryFileContents(bytes: [], observation: observation) // expected-error
}
''', "'RepositoryFileContents' initializer is inaccessible due to 'fileprivate' protection level"),
        ('cursor issuer', '''
func wrong(_ permit: RepositoryRootPermission) {
    _ = RepositoryListingCursor(identifier: UUID(), permission: permit, directory: .keys) // expected-error
}
''', "'RepositoryListingCursor' initializer is inaccessible due to 'fileprivate' protection level"),
        ('raw discovery issuer', '''
func wrong() { _ = RepositoryDiscoveredLeaf(bytes: [47]) } // expected-error
''', "'RepositoryDiscoveredLeaf' initializer is inaccessible due to 'fileprivate' protection level"),
        ('installation evidence retains issuer across decoding', '''
func decode<T: Decodable>(_ value: T.Type) {}
func wrong() { decode(ImmutableInstallation.self) } // expected-error
''', "requires that 'ImmutableInstallation' conform to 'Decodable'"),
        ('provider installation is distinct from local acceptance', '''
func consume(_ receipt: AcceptedHistoryReceipt) {}
func wrong(_ installation: ImmutableInstallation) { consume(installation) } // expected-error
''', "cannot convert value of type 'ImmutableInstallation' to expected argument type 'AcceptedHistoryReceipt'"),
        ('discovery leaf is distinct from immutable locator', '''
func consume(_ locator: ImmutableRepositoryLocator) {}
func wrong(_ leaf: RepositoryDiscoveredLeaf) { consume(leaf) } // expected-error
''', "cannot convert value of type 'RepositoryDiscoveredLeaf' to expected argument type 'ImmutableRepositoryLocator'"),
        ('bounded exchange consumer companion', '''
func use(_ root: RepositoryRootSession, _ store: LocalStoreSession) async throws {
    let batch = try await store.captureRepositoryPublication(maximumObjects: 2)
    let permit = try await root.permission()
    if case .complete(let receipt) = try await root.publish(batch, from: store, using: permit) {
        try await root.validate(receipt, from: store, using: permit)
    }
    let turn = try await root.discover(into: store, opportunity: .foreground)
    try await root.validate(turn, for: store)
}
''', None),
        ('publication cursor issuer', '''
func wrong(_ store: LocalStoreID) {
    _ = RepositoryPublicationCursor(store: store, session: UUID(), through: 1, afterSequence: 0, afterObject: []) // expected-error
}
''', "'RepositoryPublicationCursor' initializer is inaccessible due to 'fileprivate' protection level"),
        ('publication batch issuer', '''
func wrong(_ store: LocalStoreID, _ descriptor: BootstrapDescriptorV1) {
    _ = RepositoryPublicationBatch(store: store, session: UUID(), descriptor: descriptor, through: 1, objects: [], continuation: nil) // expected-error
}
''', "'RepositoryPublicationBatch' initializer is inaccessible due to 'fileprivate' protection level"),
        ('publication result issuer', '''
func wrong(_ batch: RepositoryPublicationBatch) {
    _ = PublishedRepositoryBatch(batch: batch, installed: []) // expected-error
}
''', "'PublishedRepositoryBatch' initializer is inaccessible due to 'fileprivate' protection level"),
        ('discovery entry issuer', '''
func wrong() { _ = RepositoryDiscoveryEntry("foreign", .ignored) } // expected-error
''', "'RepositoryDiscoveryEntry' initializer is inaccessible due to 'fileprivate' protection level"),
        ('discovery turn issuer', '''
func wrong(_ permit: RepositoryRootPermission, _ store: LocalStoreSession) {
    _ = RepositoryDiscoveryTurn(entries: [], passEnded: true, captured: 0, latest: 0, permission: permit, target: fatalError()) // expected-error
}
''', "'RepositoryDiscoveryTurn' initializer is inaccessible due to 'fileprivate' protection level"),
        ('metadata batch issuer', '''
func wrong(_ cursor: RepositoryListingCursor) {
    _ = RepositoryMetadataBatch(entries: [], cursor: cursor, finished: true) // expected-error
}
''', ("cannot find 'RepositoryMetadataBatch' in scope", "'RepositoryMetadataBatch' initializer is inaccessible due to 'fileprivate' protection level")),
        ('metadata entry issuer', '''
func wrong(_ leaf: RepositoryDiscoveredLeaf) {
    _ = RepositoryMetadataEntry(leaf: leaf, result: .invalidName) // expected-error
}
''', ("cannot find 'RepositoryMetadataEntry' in scope", "'RepositoryMetadataEntry' initializer is inaccessible due to 'fileprivate' protection level")),
        ('hint batch issuer', '''
func wrong(_ permit: RepositoryRootPermission, _ store: LocalStoreID) {
    _ = RepositoryHintLookup(permission: permit, store: store, incarnation: UUID(), hints: [], answers: []) // expected-error
}
''', ("cannot find 'RepositoryHintLookup' in scope", "'RepositoryHintLookup' initializer is inaccessible due to 'fileprivate' protection level")),
        ('batch evidence preserves issuer across decoding', '''
func decode<T: Decodable>(_ value: T.Type) {}
func wrong() { decode(RepositoryHintLookup.self) } // expected-error
''', ("cannot find 'RepositoryHintLookup' in scope", "requires that 'RepositoryHintLookup' conform to 'Decodable'")),
        ('observation hint issuer', '''
func wrong(_ observation: RepositoryEntryObservation) {
    _ = RepositoryObservationHint(observation: observation) // expected-error
}
''', ("cannot find 'RepositoryObservationHint' in scope", "'RepositoryObservationHint' initializer is inaccessible due to 'fileprivate' protection level")),
        ('publication cursor preserves issuer across decoding', '''
func decode<T: Decodable>(_ type: T.Type) {}
func wrong() { decode(RepositoryPublicationCursor.self) } // expected-error
''', "requires that 'RepositoryPublicationCursor' conform to 'Decodable'"),
        ('publication batch preserves issuer across decoding', '''
func decode<T: Decodable>(_ type: T.Type) {}
func wrong() { decode(RepositoryPublicationBatch.self) } // expected-error
''', "requires that 'RepositoryPublicationBatch' conform to 'Decodable'"),
        ('discovery turn preserves issuer across decoding', '''
func decode<T: Decodable>(_ type: T.Type) {}
func wrong() { decode(RepositoryDiscoveryTurn.self) } // expected-error
''', "requires that 'RepositoryDiscoveryTurn' conform to 'Decodable'"),
        ('repository publication is distinct from local acknowledgment', '''
func consume(_ receipt: AcceptedHistoryReceipt) {}
func wrong(_ receipt: PublishedRepositoryBatch) { consume(receipt) } // expected-error
''', "cannot convert value of type 'PublishedRepositoryBatch' to expected argument type 'AcceptedHistoryReceipt'"),
        ('discovery is distinct from checked model publication', '''
func wrong(_ store: LocalStoreSession, _ turn: RepositoryDiscoveryTurn) async throws {
    _ = try await store.publish(turn, liveGeneration: 0) { $0.notes.count } // expected-error
}
''', "cannot convert value of type 'RepositoryDiscoveryTurn' to expected argument type 'PreparedModelChange'"),
    ]
    cases += [
        ('transport consumer companion', '''
func use(_ root: RepositoryRootSession, _ store: LocalStoreSession) async throws {
    let driver = try await RepositoryTransportDriver.start(root: root, store: store)
    await driver.revisit(.foreground)
    await driver.stop()
}
''', None),
        ('transport construction', '''
func wrong(_ root: RepositoryRootSession, _ store: LocalStoreSession) {
    _ = RepositoryTransportDriver(root: root, store: store, hooks: fatalError()) // expected-error
}
''', "'RepositoryTransportDriver' initializer is inaccessible due to 'private' protection level"),
        ('availability issuer', '''
func wrong(_ observation: RepositoryEntryObservation) {
    _ = RepositoryItemAvailability(fatalError(), observation: observation) // expected-error
}
''', "'RepositoryItemAvailability' initializer is inaccessible due to 'fileprivate' protection level"),
        ('provider observation issuer', '''
func wrong(_ p: RepositoryRootPermission) {
    _ = RepositoryProviderObservation(.unknown(nil), permission: p) // expected-error
}
''', "'RepositoryProviderObservation' initializer is inaccessible due to 'fileprivate' protection level"),
        ('provider identity issuer', '''
func wrong() { _ = RepositoryProviderIdentity(item: "untrusted", domain: "untrusted") } // expected-error
''', "'RepositoryProviderIdentity' initializer is inaccessible due to 'fileprivate' protection level"),
        ('provider status is distinct from permission', '''
func wrong(_ r: RepositoryRootSession, _ p: RepositoryProviderObservation) async throws {
    _ = try await r.observe("NV Data", using: p) // expected-error
}
''', "cannot convert value of type 'RepositoryProviderObservation' to expected argument type 'RepositoryRootPermission'"),
        ('accessor confinement', '''
func wrong() { _ = RootPresenter.self } // expected-error
''', ("cannot find 'RootPresenter' in scope", "'RootPresenter' is inaccessible due to 'private' protection level")),
        ('prepared stage issuer', '''
func wrong() { _ = RootPreparedStage.self } // expected-error
''', ("cannot find 'RootPreparedStage' in scope", "'RootPreparedStage' is inaccessible due to 'private' protection level")),
        ('availability preserves live issuer across decoding', '''
func decode<T: Decodable>(_ type: T.Type) {}
func wrong() { decode(RepositoryItemAvailability.self) } // expected-error
''', "requires that 'RepositoryItemAvailability' conform to 'Decodable'"),
        ('integrated startup consumer companion', '''
func use(_ owner: CollectionSession) async throws {
    switch await owner.decision() {
    case .ready, .editable:
        let prepared = try await owner.preparePublication(liveGeneration: 1)
        _ = try await owner.publish(prepared, liveGeneration: 1) { $0 }
    case .waiting(let choice): try await owner.workOffline(choice)
    case .recovery, .contention, .transition, .closed: break
    }
}
''', None),
        ('offline choice issuer', '''
func wrong(_ object: SegmentLocator) {
    _ = WorkOfflineChoice(object, owner: UUID(), attempt: UUID()) // expected-error
}
''', "'WorkOfflineChoice' initializer is inaccessible due to 'fileprivate' protection level"),
        ('publication integrates both issuers', '''
func wrong(_ model: PreparedModelChange) {
    _ = CollectionPreparedPublication(owner: UUID(), attempt: UUID(), model: model) // expected-error
}
''', "'CollectionPreparedPublication' initializer is inaccessible due to 'fileprivate' protection level"),
        ('integrated action issuer', '''
func wrong(_ action: CapturedActionGroup) {
    _ = CollectionCapturedAction(owner: UUID(), attempt: UUID(), action: action) // expected-error
}
''', "'CollectionCapturedAction' initializer is inaccessible due to 'fileprivate' protection level"),
        ('disclosure issuer', '''
func wrong(_ locator: SegmentLocator, _ observation: RepositoryEntryObservation, _ availability: RepositoryItemAvailability) {
    _ = DisclosedRepositoryObject(locator: locator, observation: observation, availability: availability) // expected-error
}
''', "'DisclosedRepositoryObject' initializer is inaccessible due to 'fileprivate' protection level"),
        ('preview issuer', '''
func wrong(_ collection: CollectionID, _ snapshot: SegmentLocator) {
    _ = BootstrapReadOnlyPreview(collection: collection, snapshot: snapshot, notes: []) // expected-error
}
''', "'BootstrapReadOnlyPreview' initializer is inaccessible due to 'fileprivate' protection level"),
        ('preview note issuer', '''
func wrong(_ birth: NoteBirth, _ value: PlaintextNoteValue) {
    _ = BootstrapReadOnlyPreview.Note(birth: birth, value: value) // expected-error
}
''', "'BootstrapReadOnlyPreview.Note' initializer is inaccessible due to 'fileprivate' protection level"),
        ('offline choice retains issuer across decoding', '''
func decode<T: Decodable>(_ type: T.Type) {}
func wrong() { decode(WorkOfflineChoice.self) } // expected-error
''', "requires that 'WorkOfflineChoice' conform to 'Decodable'"),
        ('publication retains issuer across decoding', '''
func decode<T: Decodable>(_ type: T.Type) {}
func wrong() { decode(CollectionPreparedPublication.self) } // expected-error
''', "requires that 'CollectionPreparedPublication' conform to 'Decodable'"),
        ('preview remains a read capability', '''
func wrong(_ owner: CollectionSession, _ preview: BootstrapReadOnlyPreview) async throws {
    _ = try await owner.persist(preview) // expected-error
}
''', "cannot convert value of type 'BootstrapReadOnlyPreview' to expected argument type 'CollectionCapturedAction'"),
        ('offline choice is immutable', '''
func wrong(_ choice: inout WorkOfflineChoice, _ locator: SegmentLocator) {
    choice.object = locator // expected-error
}
''', "cannot assign to property: 'object' is a 'let' constant"),
        ('integrated lifecycle is actor isolated', '''
func wrong(_ owner: CollectionSession) { _ = owner.decision() } // expected-error
''', ("call to actor-isolated instance method 'decision()' in a synchronous nonisolated context",
      "actor-isolated instance method 'decision()' cannot be called from outside of the actor")),
    ]
    with checker.temporary_artifacts(prefix='nv-root-types-') as tmp:
        command = ['swiftc', '-swift-version', '6', '-strict-concurrency=complete', '-strict-memory-safety',
                   '-warnings-as-errors', '-typecheck', '-I', str(modules),
                   '-module-cache-path', checker.compiler_cache_path('swiftc', modules, tmp),
                   '-Xcc', '-I' + str(ROOT/'NVStorage/.deps/sqlcipher/include'),
                   '-Xcc', '-I' + str(ROOT/'NVStorage/Sources/CStorageIO/include')]
        if sys.platform == 'darwin':
            apple = modules.parent/'CAppleFileAccess.build/module.modulemap'
            assert apple.is_file(), apple
            command += ['-Xcc', '-fmodule-map-file=' + str(apple)]
        for p in [modules.parent/'CArgon2.build/module.modulemap', modules.parent/'CStorageIO.build/module.modulemap',
                  modules.parent/'CSQLMaintenance.build/module.modulemap', modules.parent/'CZstd.build/module.modulemap',
                  ROOT/'NVStorage/Sources/CSQLCipher/module.modulemap']:
            assert p.is_file(), p
            command += ['-Xcc', '-fmodule-map-file=' + str(p)]
        runtime = sorted((ROOT/'NVStorage/Sources/NVStorageRuntime').glob('*.swift'))
        runtime += [modules.parent/'NVStorageRuntime.build/DerivedSources/resource_bundle_accessor.swift']
        count = 0
        for same in [False, True]:
            clients = [(name, 'import Foundation\nimport NVStorageCore\n' + ('' if same else 'import NVStorageRuntime\n') + source, expected)
                       for name, source, expected in cases]
            invocation = command + (['-package-name', 'nvstorage', '-module-name', 'NVStorageRuntime', *map(str, runtime)] if same else [])
            count += checker.run_probes(invocation, clients, Path(tmp)/('same' if same else 'ordinary'),
                label='same-module' if same else 'ordinary', timeout=90, maximum=args.batch_size)
        for name, source, diagnostic in [
            ('prepared directory unique ownership', '''
private func requireCopy<T>(_ value: borrowing T) {}
private func wrong(_ stage: borrowing RootPreparedDirectory) { requireCopy(stage) } // expected-error
''', "requires that 'RootPreparedDirectory' conform to 'Copyable'"),
            ('prepared directory executor confinement', '''
private func requireTransfer<T: ~Copyable & Sendable>(_ value: borrowing T) {}
private func wrong(_ stage: borrowing RootPreparedDirectory) { requireTransfer(stage) } // expected-error
''', "does not conform to the 'Sendable' protocol"),
            ('prepared stage unique ownership', '''
private func requireCopy<T>(_ value: borrowing T) {}
private func wrong(_ stage: borrowing RootPreparedStage) { requireCopy(stage) } // expected-error
''', "requires that 'RootPreparedStage' conform to 'Copyable'"),
            ('prepared stage executor confinement', '''
private func requireTransfer<T: ~Copyable & Sendable>(_ value: borrowing T) {}
private func wrong(_ stage: borrowing RootPreparedStage) { requireTransfer(stage) } // expected-error
''', "does not conform to the 'Sendable' protocol"),
        ]:
            original = ROOT/'NVStorage/Sources/NVStorageRuntime/RepositoryRoot.swift'
            path = Path(tmp)/'RepositoryRoot.swift'
            combined = original.read_text() + source
            path.write_text(combined)
            sources = [path if p == original else p for p in runtime]
            invocation = command + ['-package-name', 'nvstorage', '-module-name', 'NVStorageRuntime', *map(str, sources)]
            run = subprocess.run(invocation, text=True, capture_output=True, timeout=90)
            assert checker.matches_contract(run.returncode, run.stderr, path, combined, diagnostic), (name, run.stderr)
            print('PASS: actual-file', name, flush=True)
            count += 1
        assert count == 134


if __name__ == '__main__':
    main()
