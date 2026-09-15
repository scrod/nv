import Crypto
import Foundation

/// Exact sealed objects for one complete initial import and its snapshot.
public struct InitialCollectionV1: Sendable {
    public let descriptor: BootstrapDescriptorV1
    public let snapshot: SegmentLocator
    public let objects: [SegmentLocator: [UInt8]]
    private init(descriptor: BootstrapDescriptorV1, snapshot: SegmentLocator, objects: [SegmentLocator: [UInt8]]) {
        self.descriptor = descriptor; self.snapshot = snapshot; self.objects = objects
    }

    /// Builds bounded single-note import groups. Run sealing and KDF work on a worker.
    public static func build(collection: CollectionID, notes: [(NoteBirth, PlaintextNoteValue)],
                             protection: ObjectProtectionV1, passphrase: String? = nil) throws -> Self {
        let notes = notes.sorted { $0.0.bytes.lexicographicallyPrecedes($1.0.bytes) }
        var hasher = InitialValuesHasherV1(expectedCount: UInt64(notes.count))
        for (birth, value) in notes { try hasher.append(birth: birth, value: value) }
        let digest = try hasher.finish(), importID = try ImportID(bytes: freshBytes())
        var writer = try WriterEpoch(bytes: freshBytes())
        let origin = try ActionOriginID(bytes: freshBytes())
        var objects: [SegmentLocator: [UInt8]] = [:]
        var sequence: UInt64 = 0
        func store(_ bytes: [UInt8], kind: ProviderObjectKind) throws -> SegmentLocator {
            if sequence == UInt64.max || (protection.suite == 1 && sequence >= 1 << 20) {
                writer = try WriterEpoch(bytes: freshBytes()); sequence = 0
            }
            let sealed = try ObjectEnvelopeV1.seal(payload: bytes, kind: kind, collection: collection,
                writer: writer, sequence: sequence, protection: protection)
            let locator = try ObjectEnvelopeV1.open(sealed, collection: collection, protection: protection).locator
            objects[locator] = sealed; sequence += 1; return locator
        }
        func operation(_ effect: OperationEffectV1, parent: OperationReference?) throws -> OperationRecordV1 {
            let refs = parent.map { [$0] } ?? []
            let ids = try refs.map { try $0.expandedID(earlierOperations: []) }
            let op = try IdentifiedOperation(nonce: OperationNonce(bytes: freshBytes()), effect: effect,
                causalParents: CausalParentSet(ids), notePredecessors: NotePredecessorSet([]))
            return try OperationRecordV1(operation: op, causalReferences: refs, noteReferences: [], earlierOperations: [])
        }
        func table(_ parent: OperationReference?) throws -> DependencyLocatorTable {
            guard let parent else { return try DependencyLocatorTable([]) }
            guard case .external(let locator, _, _) = parent else { throw CanonicalEncodingError.invalidReference }
            return try DependencyLocatorTable([locator])
        }
        let genesis = try operation(.genesis(importID: importID,
            profile: protection.suite == 0 ? .plaintextFiles : .encryptedSegments,
            initialCount: UInt64(notes.count), initialValuesDigest: digest), parent: nil)
        let genesisLocator = try store(ChangesPayloadV1(dependencies: table(nil), operations: [genesis], actions: []).encodedV1(), kind: .changes)
        let descriptor: BootstrapDescriptorV1
        switch protection {
        case .publicHash: descriptor = try .publicDescriptor(collection: collection, genesis: genesisLocator)
        case .encrypted(let id, let key):
            guard let passphrase else { throw CanonicalEncodingError.wrongScope }
            descriptor = try .wrap(collection: collection, keyID: id, genesis: genesisLocator,
                collectionKey: key, passphrase: passphrase)
        }
        var parent = OperationReference.external(locator: genesisLocator, index: OperationIndex(0), expectedID: genesis.operation.id)
        var previousAction: ActionReference?
        var rows: [InitialSnapshotRowV1] = []
        for (birth, value) in notes {
            let id = try ActionID(bytes: freshBytes())
            let record = try operation(.importNote(action: id, birth: birth, value: value), parent: parent)
            let action = try ActionRecordV1(id: id, origin: origin, previousOrigin: previousAction,
                scope: .collection, scopeParents: previousAction.map { [$0] } ?? [], kind: .createImportBatch,
                members: [OperationIndex(0)], affected: [.init(birth: birth, before: .freshBirthAbsence,
                    after: .value(.earlierLocal(index: OperationIndex(0))))], operations: [record.operation], earlierActions: [])
            let locator = try store(ChangesPayloadV1(dependencies: table(parent), operations: [record], actions: [action]).encodedV1(), kind: .changes)
            parent = .external(locator: locator, index: OperationIndex(0), expectedID: record.operation.id)
            previousAction = .external(locator: locator, index: ActionIndex(0), expectedID: id)
            rows.append(try InitialSnapshotRowV1(birth: birth, value: value, importReference: parent))
        }
        let complete = try operation(.importComplete(importID: importID, initialCount: UInt64(notes.count), initialValuesDigest: digest), parent: parent)
        let completeLocator = try store(ChangesPayloadV1(dependencies: table(parent), operations: [complete], actions: []).encodedV1(), kind: .changes)
        let completion = OperationReference.external(locator: completeLocator, index: OperationIndex(0), expectedID: complete.operation.id)
        var pages: [InitialSnapshotPageReferenceV1] = []
        for (n, row) in rows.enumerated() {
            guard let index = UInt32(exactly: n) else { throw CanonicalEncodingError.lengthLimit }
            let page = try InitialSnapshotPageV1(importID: importID, index: index, dependencies: table(row.importReference), rows: [row])
            pages.append(InitialSnapshotPageReferenceV1(index: index, locator: try store(page.encodedV1(), kind: .snapshotPage), rowCount: 1))
        }
        let root = try InitialSnapshotRootV1(importID: importID, initialCount: UInt64(notes.count), digest: digest,
            dependencies: table(completion), completion: completion, frontier: [completion], pages: pages)
        let snapshot = try store(root.encodedV1(), kind: .snapshotRoot)
        _ = try InitialBootstrapValidationV1.validate(descriptor: descriptor, expectedCollection: collection,
            protection: protection, snapshot: snapshot) { objects[$0] }
        return Self(descriptor: descriptor, snapshot: snapshot, objects: objects)
    }
}

func freshBytes() -> [UInt8] {
    let u = UUID().uuid
    return [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
}

public enum PrivateDatabaseKeyV1 {
    public static func derive(collection: CollectionID, protection: ObjectProtectionV1) throws -> [UInt8] {
        switch protection {
        case .publicHash: return Array(SHA256.hash(data: Array("NV public local database key\0v1\0".utf8)))
        case .encrypted(let id, let key):
            guard key.bitCount == 256 else { throw CanonicalEncodingError.invalidPayload }
            let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: collection.bytes + id.bytes,
                info: Array("NV private database key\0v1\0".utf8), outputByteCount: 32)
            return derived.withUnsafeBytes { Array($0) }
        }
    }
}
