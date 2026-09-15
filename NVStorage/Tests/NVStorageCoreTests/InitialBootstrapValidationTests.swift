import Crypto
import Foundation
import NVStorageCore
import Testing

private struct LiteralBootstrap: Decodable {
    struct Object: Decodable { let locator: String; let bytes: String }
    let collection: String
    let descriptor: String
    let snapshot: String
    let completion: String
    let actionID: String
    let births: [String]
    let bodies: [String]
    let objects: [Object]
}

private func bytes(_ hex: String) throws -> [UInt8] {
    let chars = Array(hex)
    return try stride(from: 0, to: chars.count, by: 2).map {
        try #require(UInt8(String(chars[$0...($0 + 1)]), radix: 16))
    }
}

@Test func independentCompleteBootstrapFixture() throws {
    let url = try #require(Bundle.module.url(forResource: "initial-bootstrap", withExtension: "json", subdirectory: "Fixtures"))
    let f = try JSONDecoder().decode(LiteralBootstrap.self, from: Data(contentsOf: url))
    let objects = try Dictionary(uniqueKeysWithValues: f.objects.map {
        (try SegmentLocator.decodeV1(bytes($0.locator)), try bytes($0.bytes))
    })
    let result = try InitialBootstrapValidationV1.validate(descriptor: BootstrapDescriptorV1.decodeV1(bytes(f.descriptor)),
        expectedCollection: CollectionID(bytes: bytes(f.collection)), protection: .publicHash,
        snapshot: SegmentLocator.decodeV1(bytes(f.snapshot))) { objects[$0] }
    #expect(result.completion.bytes == (try bytes(f.completion)))
    #expect(result.rows.map(\.birth.bytes) == (try f.births.map(bytes)))
    #expect(result.rows.map(\.value.body.bytes) == f.bodies.map { Array($0.utf8) })
    #expect(result.actions.count == 1)
    #expect(result.scopeFrontiers[.collection]?.actionIDs == [try ActionID(bytes: bytes(f.actionID))])
    #expect(result.requiredObjects == Set(objects.keys))
    #expect(result.snapshot == (try SegmentLocator.decodeV1(bytes(f.snapshot))))
    #expect(result.descriptor.encodedBytes == (try bytes(f.descriptor)))
}

private func idBytes(_ n: UInt8, count: Int = 16) -> [UInt8] { .init(repeating: n, count: count) }
private func birth(_ n: UInt8) throws -> NoteBirth { try NoteBirth(bytes: idBytes(n)) }
private func value(_ body: String) throws -> PlaintextNoteValue {
    try PlaintextNoteValue(title: ExactUTF8(bytes: Array("Title".utf8)), body: ExactUTF8(bytes: Array(body.utf8)),
        labels: CanonicalLabels([]), created: DisplayDate(secondsSinceReferenceDate: 0),
        modified: DisplayDate(secondsSinceReferenceDate: 1))
}

private struct ImportBatch {
    let locator: SegmentLocator
    let payload: ChangesPayloadV1
    let references: [OperationReference]
    let actionReference: ActionReference
}

/// Builds complete imports and seals deliberately varied semantic claims in
/// valid envelopes, letting tests reach the history validator's own checks.
private struct BootstrapFixture {
    let collection = try! CollectionID(bytes: idBytes(1))
    let writer = try! WriterEpoch(bytes: idBytes(2))
    let importID = try! ImportID(bytes: idBytes(3))
    let origin = try! ActionOriginID(bytes: idBytes(4))
    let protection: ObjectProtectionV1
    let expected: [(NoteBirth, PlaintextNoteValue)]
    let digest: InitialValuesDigest
    var objects: [SegmentLocator: [UInt8]] = [:]
    var genesis: OperationReference!
    var descriptor: BootstrapDescriptorV1!
    var batches: [ImportBatch] = []
    var nextNonce: UInt8 = 10

    init(expected: [(NoteBirth, PlaintextNoteValue)], encrypted: Bool = false,
         wrongDigest: Bool = false, wrongGenesisProfile: Bool = false) throws {
        self.expected = expected
        protection = encrypted ? .encrypted(keyID: try CollectionKeyID(bytes: idBytes(5)),
            key: SymmetricKey(data: idBytes(6, count: 32))) : .publicHash
        var hash = InitialValuesHasherV1(expectedCount: UInt64(expected.count))
        for pair in expected.sorted(by: { $0.0.bytes.lexicographicallyPrecedes($1.0.bytes) }) {
            try hash.append(birth: pair.0, value: pair.1)
        }
        digest = try wrongDigest ? InitialValuesDigest(bytes: idBytes(9, count: 32)) : hash.finish()
        let effect = OperationEffectV1.genesis(importID: importID,
            profile: encrypted != wrongGenesisProfile ? .encryptedSegments : .plaintextFiles,
            initialCount: UInt64(expected.count), initialValuesDigest: digest)
        let record = try operation(effect, parents: [])
        let locator = try store(ChangesPayloadV1(dependencies: DependencyLocatorTable([]), operations: [record], actions: []))
        genesis = .external(locator: locator, index: OperationIndex(0), expectedID: record.operation.id)
        if encrypted {
            descriptor = try BootstrapDescriptorV1.wrap(collection: collection, keyID: CollectionKeyID(bytes: idBytes(5)),
                genesis: locator, collectionKey: SymmetricKey(data: idBytes(6, count: 32)), passphrase: "synthetic test password")
        } else { descriptor = try .publicDescriptor(collection: collection, genesis: locator) }
    }

    func target(_ ref: OperationReference) throws -> IdentifiedOperation {
        guard case .external(let locator, let index, _) = ref else { throw CanonicalEncodingError.invalidReference }
        return try ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(objects[locator]!, collection: collection,
            protection: protection).payload).operations[Int(index.rawValue)].operation
    }

    mutating func operation(_ effect: OperationEffectV1, parents: [OperationReference],
                            local: [IdentifiedOperation] = []) throws -> OperationRecordV1 {
        let ids = try parents.map { ref -> OperationID in
            switch ref {
            case .earlierLocal(let index): local[Int(index.rawValue)].id
            case .external: try target(ref).id
            }
        }
        let op = try IdentifiedOperation(nonce: OperationNonce(bytes: idBytes(nextNonce)), effect: effect,
            causalParents: CausalParentSet(ids), notePredecessors: NotePredecessorSet([]))
        nextNonce += 1
        return try OperationRecordV1(operation: op, causalReferences: parents, noteReferences: [], earlierOperations: local)
    }

    mutating func store(_ payload: ChangesPayloadV1) throws -> SegmentLocator {
        try store(payload.encodedV1(), kind: .changes)
    }

    mutating func store(_ payload: [UInt8], kind: ProviderObjectKind) throws -> SegmentLocator {
        let bytes = try ObjectEnvelopeV1.seal(payload: payload, kind: kind, collection: collection,
            writer: writer, sequence: UInt64(objects.count), protection: protection)
        let locator = try ObjectEnvelopeV1.open(bytes, collection: collection, protection: protection).locator
        objects[locator] = bytes
        return locator
    }

    func dependencies(_ refs: [OperationReference], actions: [ActionReference] = [],
                      extra: [SegmentLocator] = []) throws -> DependencyLocatorTable {
        var locators = Set(extra)
        for ref in refs { if case .external(let locator, _, _) = ref { locators.insert(locator) } }
        for ref in actions { if case .external(let locator, _, _) = ref { locators.insert(locator) } }
        return try DependencyLocatorTable(Array(locators))
    }

    mutating func add(_ notes: [(NoteBirth, PlaintextNoteValue)], parents: [OperationReference]? = nil,
                      scopeParents: [ActionReference] = [], previous: ActionReference? = nil,
                      scope: ActionScopeV1 = .collection) throws -> ImportBatch {
        let actionID = try ActionID(bytes: idBytes(UInt8(20 + batches.count)))
        let parents = parents ?? [genesis!]
        var records: [OperationRecordV1] = []
        for (birth, value) in notes {
            records.append(try operation(.importNote(action: actionID, birth: birth, value: value), parents: parents,
                local: records.map(\.operation)))
        }
        let action = try ActionRecordV1(id: actionID, origin: origin, previousOrigin: previous, scope: scope,
            scopeParents: scopeParents, kind: .createImportBatch,
            members: records.indices.map { OperationIndex(UInt32($0)) },
            affected: notes.enumerated().map { index, note in
                ActionAffectedReference(birth: note.0, before: .freshBirthAbsence,
                    after: .value(.earlierLocal(index: OperationIndex(UInt32(index)))))
            }, operations: records.map(\.operation), earlierActions: [])
        let table = try dependencies(parents, actions: scopeParents + (previous.map { [$0] } ?? []))
        let payload = try ChangesPayloadV1(dependencies: table, operations: records, actions: [action])
        let locator = try store(payload)
        let batch = ImportBatch(locator: locator, payload: payload,
            references: records.enumerated().map {
                .external(locator: locator, index: OperationIndex(UInt32($0)), expectedID: $1.operation.id)
            }, actionReference: .external(locator: locator, index: ActionIndex(0), expectedID: actionID))
        batches.append(batch)
        return batch
    }

    mutating func finish(parents: [OperationReference]? = nil, rows override: [InitialSnapshotRowV1]? = nil,
                         pageSize: Int = 1, extra: [SegmentLocator] = [], redundantFrontier: Bool = false,
                         wrongCompletion: Bool = false, wrongPageID: Bool = false) throws -> SegmentLocator {
        let parents = parents ?? (batches.isEmpty ? [genesis!] : batches.flatMap(\.references))
        let complete = try operation(.importComplete(importID: wrongCompletion ? ImportID(bytes: idBytes(90)) : importID,
            initialCount: UInt64(expected.count), initialValuesDigest: digest), parents: parents)
        let loc = try store(ChangesPayloadV1(dependencies: dependencies(parents), operations: [complete], actions: []))
        let ref = OperationReference.external(locator: loc, index: OperationIndex(0), expectedID: complete.operation.id)
        let rows = try override ?? batches.flatMap { batch in
            try batch.payload.operations.enumerated().map { index, op -> InitialSnapshotRowV1 in
                guard case .importNote(_, let birth, let value) = op.operation.effect else { throw CanonicalEncodingError.invalidPayload }
                return try InitialSnapshotRowV1(birth: birth, value: value, importReference: batch.references[index])
            }
        }.sorted { $0.birth.bytes.lexicographicallyPrecedes($1.birth.bytes) }
        var pages: [InitialSnapshotPageReferenceV1] = []
        for start in stride(from: 0, to: rows.count, by: pageSize) {
            let slice = Array(rows[start..<min(start + pageSize, rows.count)])
            let index = UInt32(pages.count)
            let page = try InitialSnapshotPageV1(importID: wrongPageID ? ImportID(bytes: idBytes(91)) : importID,
                index: index, dependencies: dependencies(slice.map(\.importReference)), rows: slice)
            let locator = try store(page.encodedV1(), kind: .snapshotPage)
            pages.append(InitialSnapshotPageReferenceV1(index: index, locator: locator, rowCount: UInt32(slice.count)))
        }
        let frontier = redundantFrontier ? [genesis!, ref] : [ref]
        let root = try InitialSnapshotRootV1(importID: importID, initialCount: UInt64(expected.count), digest: digest,
            dependencies: dependencies(frontier, extra: extra), completion: ref, frontier: frontier, pages: pages)
        return try store(root.encodedV1(), kind: .snapshotRoot)
    }

    func validate(_ root: SegmentLocator, objects other: [SegmentLocator: [UInt8]]? = nil) throws -> InitialBootstrapValidationV1 {
        try InitialBootstrapValidationV1.validate(descriptor: descriptor, expectedCollection: collection,
            protection: protection, snapshot: root) { (other ?? objects)[$0] }
    }
}

@Test(arguments: [false, true], [0, 1, 3])
func completeInitialImportValidatesAcrossObjects(encrypted: Bool, count: Int) throws {
    let notes = try (1...3).prefix(count).map { (try birth(UInt8($0)), try value("body \($0)\r\ne\u{301}")) }
    var f = try BootstrapFixture(expected: notes, encrypted: encrypted)
    var previous: ImportBatch?
    for note in notes {
        previous = try f.add([note], parents: previous?.references,
            scopeParents: previous.map { [$0.actionReference] } ?? [], previous: previous?.actionReference)
    }
    let root = try f.finish(parents: previous?.references)
    let result = try f.validate(root)
    #expect(result.rows.map(\.birth) == notes.map(\.0))
    #expect(result.rows.map(\.value) == notes.map(\.1))
    #expect(result.requiredObjects == Set(f.objects.keys))
    #expect(result.snapshot == root)
    #expect(result.descriptor.encodedBytes == f.descriptor.encodedBytes)
    #expect(result.actions.count == count)
    if let previous {
        let frontier = try #require(result.scopeFrontiers[.collection])
        #expect(frontier.actionIDs == [previous.payload.actions[0].action.id])
        #expect(frontier.scope == .collection && frontier.collection == f.collection)
        #expect(frontier.snapshot == root && frontier.completion == result.completion)
    } else { #expect(result.scopeFrontiers.isEmpty) }
}

@Test func concurrentImportFrontiersAreNotArrivalOrder() throws {
    let notes = try [(birth(1), value("a")), (birth(2), value("b"))]
    var f = try BootstrapFixture(expected: notes)
    let a = try f.add([notes[0]]), b = try f.add([notes[1]])
    let root = try f.finish()
    let result = try f.validate(root)
    #expect(result.scopeFrontiers[.collection]?.actionIDs == [a.payload.actions[0].action.id, b.payload.actions[0].action.id])
    #expect(try f.validate(root, objects: Dictionary(uniqueKeysWithValues: f.objects.reversed())).rows == result.rows)
}

@Test func multipleGroupsAndDifferentScopesInOneObject() throws {
    let notes = try [(birth(1), value("a")), (birth(2), value("b"))]
    var f = try BootstrapFixture(expected: notes)
    let a = try f.add([notes[0]], scope: .note(notes[0].0))
    // Construct a second group which observes a but has another scope and origin.
    // Its action may precede a's in the action section: it has no action edge to a.
    let actionID = try ActionID(bytes: idBytes(75))
    let op = try f.operation(.importNote(action: actionID, birth: notes[1].0, value: notes[1].1),
        parents: [.earlierLocal(index: OperationIndex(0))], local: a.payload.operations.map(\.operation))
    let records = a.payload.operations + [op]
    let action = try ActionRecordV1(id: actionID, origin: ActionOriginID(bytes: idBytes(76)), previousOrigin: nil,
        scope: .note(notes[1].0), scopeParents: [], kind: .createImportBatch, members: [OperationIndex(1)],
        affected: [ActionAffectedReference(birth: notes[1].0, before: .freshBirthAbsence,
            after: .value(.earlierLocal(index: OperationIndex(1))))], operations: records.map(\.operation), earlierActions: [])
    let payload = try ChangesPayloadV1(dependencies: a.payload.dependencies, operations: records,
        actions: [action, a.payload.actions[0]])
    let combined = try f.store(payload)
    let b = OperationReference.external(locator: combined, index: OperationIndex(1), expectedID: op.operation.id)
    let rows = try [InitialSnapshotRowV1(birth: notes[0].0, value: notes[0].1, importReference: a.references[0]),
        InitialSnapshotRowV1(birth: notes[1].0, value: notes[1].1, importReference: b)]
    let root = try f.finish(parents: [b], rows: rows)
    let result = try f.validate(root)
    #expect(result.rows.count == 2 && result.actions.count == 2 && result.scopeFrontiers.count == 2)
}

@Test func generalHistoryIsDeferredInsteadOfBeingSilentlyIgnored() throws {
    var f = try BootstrapFixture(expected: [])
    let actionID = try ActionID(bytes: idBytes(80))
    let note = try birth(1)
    let op = try f.operation(.create(action: actionID, birth: note, value: value("not initial import")), parents: [f.genesis!])
    let action = try ActionRecordV1(id: actionID, origin: f.origin, previousOrigin: nil, scope: .collection,
        scopeParents: [], kind: .createImportBatch, members: [OperationIndex(0)],
        affected: [ActionAffectedReference(birth: note, before: .freshBirthAbsence,
            after: .value(.earlierLocal(index: OperationIndex(0))))], operations: [op.operation], earlierActions: [])
    let tail = try f.store(ChangesPayloadV1(dependencies: f.dependencies([f.genesis!]), operations: [op], actions: [action]))
    let root = try f.finish(extra: [tail])
    #expect(throws: InitialBootstrapValidationError.requiresGeneralHistoryValidation) { try f.validate(root) }
}

@Test func missingEveryRequiredObjectNeverReturnsPartialBootstrap() throws {
    let notes = try [(birth(1), value("a")), (birth(2), value("b"))]
    var f = try BootstrapFixture(expected: notes)
    _ = try f.add(notes)
    let root = try f.finish()
    for locator in f.objects.keys {
        var unavailable = f.objects
        unavailable.removeValue(forKey: locator)
        #expect(throws: InitialBootstrapValidationError.missingObject(locator)) { try f.validate(root, objects: unavailable) }
// Restoring the missing object lets a fresh validation recover the complete rows.
        #expect(try f.validate(root).rows.count == 2)
    }
}

@Test(arguments: ["valid", "digest", "completion", "coverage", "pageID", "redundantFrontier", "duplicateBirth"])
func authenticatedInitialHistoryCanStillBeWrong(fault: String) throws {
    let notes = try [(birth(1), value("a")), (birth(2), value("b"))]
    var f = try BootstrapFixture(expected: notes, wrongDigest: fault == "digest")
    let a = try f.add([notes[0]])
    _ = try f.add([fault == "duplicateBirth" ? notes[0] : notes[1]])
// Individually valid pages can repeat a birth across pages; the global
    // coverage/order check must reject that duplication.
    let root = try f.finish(parents: fault == "coverage" ? a.references : nil,
        redundantFrontier: fault == "redundantFrontier", wrongCompletion: fault == "completion",
        wrongPageID: fault == "pageID")
    for (locator, bytes) in f.objects {
        #expect(try ObjectEnvelopeV1.open(bytes, collection: f.collection, protection: f.protection,
            expectedLocator: locator).locator == locator)
    }
    if fault == "valid" {
        let result = try #require(try? f.validate(root))
        #expect(result.rows.map(\.value) == notes.map(\.1))
    } else {
        let expected: InitialBootstrapValidationError =
            ["pageID", "redundantFrontier", "duplicateBirth"].contains(fault) ? .invalidSnapshot : .invalidCommitment
        #expect(throws: expected) { _ = try f.validate(root) }
    }
}

@Test(arguments: ["valid", "wrongBody", "wrongIndex", "wrongID", "pageOrder"], [false, true])
func snapshotMustMatchExactImportedRecord(fault: String, encrypted: Bool) throws {
    let notes = try [(birth(1), value("a")), (birth(2), value("b"))]
    var f = try BootstrapFixture(expected: notes, encrypted: encrypted)
    let batch = try f.add(notes)
    var ref = batch.references[0]
    if fault == "wrongIndex" {
        ref = .external(locator: batch.locator, index: OperationIndex(1), expectedID: batch.payload.operations[0].operation.id)
    } else if fault == "wrongID" {
        ref = .external(locator: batch.locator, index: OperationIndex(0), expectedID: batch.payload.operations[1].operation.id)
    }
    var rows = try [InitialSnapshotRowV1(birth: notes[0].0, value: fault == "wrongBody" ? value("forged") : notes[0].1,
        importReference: ref), InitialSnapshotRowV1(birth: notes[1].0, value: notes[1].1, importReference: batch.references[1])]
    if fault == "pageOrder" { rows.reverse() }
    let root = try f.finish(rows: rows)
    if fault == "valid" {
        #expect(try f.validate(root).rows.map(\.value) == notes.map(\.1))
    } else if fault == "wrongBody" || fault == "pageOrder" {
        #expect(throws: InitialBootstrapValidationError.invalidSnapshot) { _ = try f.validate(root) }
    } else { #expect(throws: CanonicalEncodingError.identityMismatch) { try f.validate(root) } }
}

@Test(arguments: ["valid", "missingMaximum", "unobservedParent", "redundantAncestor", "partialGroup", "unobservedOrigin"])
func scopeClaimsNeedTheirCompleteDeclaredCausalBasis(fault: String) throws {
    let notes = try [(birth(1), value("a")), (birth(2), value("b")), (birth(3), value("c"))]
    var f = try BootstrapFixture(expected: notes)
    if fault == "partialGroup" {
        let a = try f.add(Array(notes.prefix(2)))
        _ = try f.add([notes[2]], parents: [a.references[0]], scopeParents: [a.actionReference])
    } else {
        let a = try f.add([notes[0]])
        let b = try f.add([notes[1]], parents: fault == "redundantAncestor" ? a.references : nil,
            scopeParents: fault == "redundantAncestor" ? [a.actionReference] : [])
        let parents: [OperationReference]
        let scopes: [ActionReference]
        if fault == "unobservedParent" || fault == "unobservedOrigin" {
            parents = [f.genesis!]; scopes = fault == "unobservedParent" ? [a.actionReference] : []
        } else {
            parents = a.references + b.references; scopes = fault == "missingMaximum" ? [a.actionReference] : [a.actionReference, b.actionReference]
        }
        _ = try f.add([notes[2]], parents: parents, scopeParents: scopes,
            previous: fault == "unobservedOrigin" ? a.actionReference : nil)
    }
    let root = try f.finish()
    if fault == "valid" {
        let result = try f.validate(root)
        #expect(result.rows.map(\.value) == notes.map(\.1))
        #expect(result.scopeFrontiers[.collection]?.actionIDs == [f.batches[2].payload.actions[0].action.id])
    } else {
        #expect(throws: InitialBootstrapValidationError.invalidActionHistory) { _ = try f.validate(root) }
    }
}

@Test func repackedDuplicateClaimsAreIdempotentButContradictoryActionsFail() throws {
    let notes = try [(birth(1), value("a"))]
    var f = try BootstrapFixture(expected: notes)
    let batch = try f.add(notes)
    let duplicate = try f.store(batch.payload)
    let root = try f.finish(extra: [duplicate])
    #expect(try f.validate(root).actions.count == 1)
    #expect(try f.validate(root).rows.count == 1)
    let old = batch.payload.actions[0]
    let falseAction = try ActionRecordV1(id: old.action.id, origin: ActionOriginID(bytes: idBytes(99)), previousOrigin: nil,
        scope: old.action.scope, scopeParents: [], kind: old.action.kind, members: old.memberIndices,
        affected: old.affectedReferences, operations: batch.payload.operations.map(\.operation), earlierActions: [])
    let contradiction = try f.store(ChangesPayloadV1(dependencies: batch.payload.dependencies,
        operations: batch.payload.operations, actions: [falseAction]))
    let badRoot = try f.finish(extra: [duplicate, contradiction])
    #expect(throws: InitialBootstrapValidationError.conflictingClaim) { try f.validate(badRoot) }
}

@Test func selectionScopeAndExactEnvelopeBytesCannotBeSubstituted() throws {
    var f = try BootstrapFixture(expected: [])
    let root = try f.finish()
    #expect(throws: CanonicalEncodingError.wrongScope) {
        try InitialBootstrapValidationV1.validate(descriptor: f.descriptor, expectedCollection: CollectionID(bytes: idBytes(88)),
            protection: f.protection, snapshot: root) { f.objects[$0] }
    }
    var damaged = f.objects
    damaged[root]![124] ^= 1
    #expect(throws: CanonicalEncodingError.identityMismatch) { try f.validate(root, objects: damaged) }
// Reject a resolver response whose valid envelope belongs to a different locator.
    damaged = f.objects; damaged[root] = f.objects[f.descriptor.genesis]
    #expect(throws: CanonicalEncodingError.identityMismatch) { try f.validate(root, objects: damaged) }
    var wrong = try BootstrapFixture(expected: [], wrongGenesisProfile: true)
    let wrongRoot = try wrong.finish()
    #expect(throws: CanonicalEncodingError.wrongScope) { try wrong.validate(wrongRoot) }
}

@Test func exactDescriptorGenesisIsNotJustAnyObjectFromTheCollection() throws {
    let notes = try [(birth(1), value("a"))]
    var f = try BootstrapFixture(expected: notes)
    let batch = try f.add(notes)
    let root = try f.finish()
    #expect(try f.validate(root).rows.map(\.value) == notes.map(\.1))
    // Both descriptors are well-formed, same collection/profile. Only the
    // original one pins the actual Genesis object rather than an Import object.
    let wrong = try BootstrapDescriptorV1.publicDescriptor(collection: f.collection, genesis: batch.locator)
    #expect(throws: InitialBootstrapValidationError.invalidCommitment) {
        _ = try InitialBootstrapValidationV1.validate(descriptor: wrong, expectedCollection: f.collection,
            protection: f.protection, snapshot: root) { f.objects[$0] }
    }
}

@Test func matchingEncryptedObjectsCannotBlessADifferentDescriptorKeyID() throws {
    var f = try BootstrapFixture(expected: [], encrypted: true)
    let root = try f.finish()
    #expect(try f.validate(root).rows.isEmpty)
    let wrong = try BootstrapDescriptorV1.wrap(collection: f.collection, keyID: CollectionKeyID(bytes: idBytes(99)),
        genesis: f.descriptor.genesis, collectionKey: SymmetricKey(data: idBytes(6, count: 32)),
        passphrase: "synthetic test password")
    #expect(throws: CanonicalEncodingError.wrongScope) {
        _ = try InitialBootstrapValidationV1.validate(descriptor: wrong, expectedCollection: f.collection,
            protection: f.protection, snapshot: root) { f.objects[$0] }
    }
}

@Test func failedAuthenticationIsNotMaskedByAnOldLocator() throws {
    var f = try BootstrapFixture(expected: [], encrypted: true)
    let root = try f.finish()
    #expect(try f.validate(root).rows.isEmpty)
    var bytes = f.objects[root]!
    bytes[124] ^= 1 // Ciphertext, not outer framing or expected profile.
    let changed = try SegmentLocator(writerEpoch: root.writerEpoch, sequence: root.sequence,
        segmentID: SegmentID(bytes: Array(SHA256.hash(data: bytes))))
    var objects = f.objects; objects.removeValue(forKey: root); objects[changed] = bytes
    #expect(throws: CanonicalEncodingError.authenticationFailure) { try f.validate(changed, objects: objects) }
}

@Test func checkedFrontiersRetainTheirOwnImmutableContext() throws {
    var first = try BootstrapFixture(expected: [(birth(1), value("first"))])
    _ = try first.add(first.expected)
    let a = try first.finish()
    var second = try BootstrapFixture(expected: [(birth(1), value("second"))])
    _ = try second.add(second.expected)
    let b = try second.finish()
    let original = try first.validate(a), other = try second.validate(b)
    let left = try #require(original.scopeFrontiers[.collection])
    let right = try #require(other.scopeFrontiers[.collection])
// Each checked frontier retains its own snapshot and completion context,
    // even when the collections and allocated action IDs match.
    #expect(left.collection == right.collection && left.actionIDs == right.actionIDs)
    #expect(left.snapshot == a && right.snapshot == b && a != b)
    #expect(left.completion != right.completion)
    #expect(original.rows[0].value.body.bytes == Array("first".utf8))
}

@Test func bootstrapCancellationHasNoPartialSuccessOrPoisonedRetry() throws {
    enum Cancel: Error { case requested }
    let notes = try [(birth(1), value("a")), (birth(2), value("b"))]
    var f = try BootstrapFixture(expected: notes)
    _ = try f.add(notes)
    let root = try f.finish()
    var steps = 0
    _ = try InitialBootstrapValidationV1.validate(descriptor: f.descriptor, expectedCollection: f.collection,
        protection: f.protection, snapshot: root, checkCancellation: { steps += 1 }) { f.objects[$0] }
    #expect(steps > f.objects.count)
    for stop in 1...steps {
        var count = 0
        #expect(throws: Cancel.self) {
            try InitialBootstrapValidationV1.validate(descriptor: f.descriptor, expectedCollection: f.collection,
                protection: f.protection, snapshot: root, checkCancellation: {
                    count += 1
                    if count == stop { throw Cancel.requested }
                }) { f.objects[$0] }
        }
    }
    #expect(try f.validate(root).rows.count == 2)
}
