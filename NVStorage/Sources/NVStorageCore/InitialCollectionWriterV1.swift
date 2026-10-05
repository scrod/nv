/// One immutable envelope ready for exact-byte candidate retention.
package struct InitialEnvelopeV1: Sendable {
    package let locator: SegmentLocator
    package let bytes: [UInt8]
}

/// Incremental initial writer: frozen notes, compact references and one bounded output buffer.
package struct InitialCollectionWriterV1: Sendable {
    package let descriptor: BootstrapDescriptorV1
    package private(set) var snapshot: SegmentLocator?
    private let collection: CollectionID
    private let protection: ObjectProtectionV1
    private let notes: [(NoteBirth, PlaintextNoteValue)]
    private let importID: ImportID
    private let digest: InitialValuesDigest
    private let origin: ActionOriginID
    private var writer: WriterEpoch
    private var sequence: UInt64 = 1
    private var first: InitialEnvelopeV1?
    private var parent: OperationReference
    private var previousAction: ActionReference?
    private var rowReferences: [OperationReference] = []
    private var pages: [InitialSnapshotPageReferenceV1] = []
    private var nextNote = 0
    private var nextPage = 0
    private var completion: OperationReference?
    private let targetBytes: Int
    private let notesPerAction: Int

    package init(collection: CollectionID, notes: [(NoteBirth, PlaintextNoteValue)],
                 protection: ObjectProtectionV1, passphrase: String?,
                 targetBytes: Int = 262_144, notesPerAction: Int = 16) throws {
        guard targetBytes >= 1024, UInt64(targetBytes) <= ObjectLimitsV1.decodedPayloadBytes,
              notesPerAction > 0, notesPerAction <= 1024 else { throw CanonicalEncodingError.lengthLimit }
        let sorted = notes.sorted { $0.0.bytes.lexicographicallyPrecedes($1.0.bytes) }
        var hasher = InitialValuesHasherV1(expectedCount: UInt64(sorted.count))
        for (birth, value) in sorted { try hasher.append(birth: birth, value: value) }
        let digest = try hasher.finish(), importID = try ImportID(bytes: freshBytes())
        let writer = try WriterEpoch(bytes: freshBytes())
        let genesis = try IdentifiedOperation(nonce: OperationNonce(bytes: freshBytes()),
            effect: .genesis(importID: importID, profile: protection.suite == 0 ? .plaintextFiles : .encryptedSegments,
                initialCount: UInt64(sorted.count), initialValuesDigest: digest),
            causalParents: CausalParentSet([]), notePredecessors: NotePredecessorSet([]))
        let record = try OperationRecordV1(operation: genesis, causalReferences: [], noteReferences: [], earlierOperations: [])
        let bytes = try ObjectEnvelopeV1.seal(payload: ChangesPayloadV1(dependencies: DependencyLocatorTable([]),
            operations: [record], actions: []).encodedV1(), kind: .changes,
            collection: collection, writer: writer, sequence: 0, protection: protection)
        let locator = try ObjectEnvelopeV1.open(bytes, collection: collection, protection: protection).locator
        switch protection {
        case .publicHash: descriptor = try .publicDescriptor(collection: collection, genesis: locator)
        case .encrypted(let id, let key):
            guard let passphrase else { throw CanonicalEncodingError.wrongScope }
            descriptor = try .wrap(collection: collection, keyID: id, genesis: locator, collectionKey: key, passphrase: passphrase)
        }
        self.collection = collection; self.protection = protection; self.notes = sorted
        self.importID = importID; self.digest = digest; self.writer = writer
        origin = try ActionOriginID(bytes: freshBytes())
        parent = .external(locator: locator, index: OperationIndex(0), expectedID: genesis.id)
        first = InitialEnvelopeV1(locator: locator, bytes: bytes)
        self.targetBytes = targetBytes; self.notesPerAction = notesPerAction
    }

    /// Packs whole actions and pages while advancing only this writer's frozen construction.
    package mutating func next() throws -> InitialEnvelopeV1? {
        try Task.checkCancellation()
        if let first { self.first = nil; return first }
        if nextNote < notes.count { return try imports() }
        if completion == nil {
            let op = try IdentifiedOperation(nonce: OperationNonce(bytes: freshBytes()),
                effect: .importComplete(importID: importID, initialCount: UInt64(notes.count), initialValuesDigest: digest),
                causalParents: CausalParentSet([parent.expandedID(earlierOperations: [])]), notePredecessors: NotePredecessorSet([]))
            let record = try OperationRecordV1(operation: op, causalReferences: [parent], noteReferences: [], earlierOperations: [])
            let envelope = try seal(ChangesPayloadV1(dependencies: dependencies([parent]), operations: [record], actions: []).encodedV1(), kind: .changes)
            completion = .external(locator: envelope.locator, index: OperationIndex(0), expectedID: op.id)
            return envelope
        }
        if nextPage < notes.count {
            var end = nextPage, size = 128
            while end < notes.count {
                let added = Int(notes[end].1.encodedByteCount) + 128
                if end > nextPage, size + added > targetBytes { break }
                size += added; end += 1
            }
            let rows = try (nextPage..<end).map { try InitialSnapshotRowV1(birth: notes[$0].0, value: notes[$0].1, importReference: rowReferences[$0]) }
            let index = UInt32(pages.count)
            let page = try InitialSnapshotPageV1(importID: importID, index: index,
                dependencies: dependencies(Array(rowReferences[nextPage..<end])), rows: rows)
            let envelope = try seal(page.encodedV1(), kind: .snapshotPage)
            pages.append(.init(index: index, locator: envelope.locator, rowCount: UInt32(rows.count)))
            nextPage = end; return envelope
        }
        if snapshot == nil {
            guard let completion else { throw CanonicalEncodingError.invalidReference }
            let root = try InitialSnapshotRootV1(importID: importID, initialCount: UInt64(notes.count), digest: digest,
                dependencies: dependencies([completion]), completion: completion, frontier: [completion], pages: pages)
            let envelope = try seal(root.encodedV1(), kind: .snapshotRoot)
            snapshot = envelope.locator; return envelope
        }
        return nil
    }

    private mutating func imports() throws -> InitialEnvelopeV1 {
        var records: [OperationRecordV1] = [], actions: [ActionRecordV1] = [], size = 256
        let start = nextNote
        while nextNote < notes.count {
            // A single large note occupies its own complete action and envelope.
            var end = nextNote, groupSize = 256
            while end < notes.count, end - nextNote < notesPerAction {
                let added = Int(notes[end].1.encodedByteCount) + 256
                if end > nextNote, size + groupSize + added > targetBytes { break }
                groupSize += added; end += 1
            }
            if !records.isEmpty, size + groupSize > targetBytes { break }
            let actionID = try ActionID(bytes: freshBytes()), groupStart = records.count
            for index in nextNote..<end {
                let causal: OperationReference = records.isEmpty ? parent : .earlierLocal(index: OperationIndex(UInt32(records.count - 1)))
                let op = try IdentifiedOperation(nonce: OperationNonce(bytes: freshBytes()),
                    effect: .importNote(action: actionID, birth: notes[index].0, value: notes[index].1),
                    causalParents: CausalParentSet([causal.expandedID(earlierOperations: records.map(\.operation))]), notePredecessors: NotePredecessorSet([]))
                records.append(try OperationRecordV1(operation: op, causalReferences: [causal], noteReferences: [], earlierOperations: records.map(\.operation)))
            }
            let previous: ActionReference? = actions.isEmpty ? previousAction : .earlierLocal(index: ActionIndex(UInt32(actions.count - 1)))
            let members = (groupStart..<records.count).map { OperationIndex(UInt32($0)) }
            let affected = (nextNote..<end).enumerated().map { offset, n in
                ActionAffectedReference(birth: notes[n].0, before: .freshBirthAbsence,
                    after: .value(.earlierLocal(index: OperationIndex(UInt32(groupStart + offset)))))
            }
            actions.append(try ActionRecordV1(id: actionID, origin: origin, previousOrigin: previous,
                scope: .collection, scopeParents: previous.map { [$0] } ?? [], kind: .createImportBatch,
                members: members, affected: affected, operations: records.map(\.operation), earlierActions: actions.map(\.action)))
            nextNote = end; size += groupSize
            if size >= targetBytes { break }
        }
        let envelope = try seal(ChangesPayloadV1(dependencies: dependencies([parent]), operations: records, actions: actions).encodedV1(), kind: .changes)
        for index in records.indices {
            rowReferences.append(.external(locator: envelope.locator, index: OperationIndex(UInt32(index)), expectedID: records[index].operation.id))
        }
        guard nextNote > start, let last = rowReferences.last, let action = actions.last else { throw CanonicalEncodingError.invalidAction }
        parent = last; previousAction = .external(locator: envelope.locator, index: ActionIndex(UInt32(actions.count - 1)), expectedID: action.action.id)
        return envelope
    }
    private func dependencies(_ refs: [OperationReference]) throws -> DependencyLocatorTable {
        try DependencyLocatorTable(Array(Set(refs.compactMap { if case .external(let loc, _, _) = $0 { loc } else { nil } })))
    }
    private mutating func seal(_ payload: [UInt8], kind: ProviderObjectKind) throws -> InitialEnvelopeV1 {
        if sequence >= (protection.suite == 1 ? 1 << 20 : UInt64.max) { writer = try WriterEpoch(bytes: freshBytes()); sequence = 0 }
        let bytes = try ObjectEnvelopeV1.seal(payload: payload, kind: kind, collection: collection, writer: writer, sequence: sequence, protection: protection)
        sequence += 1
        return try .init(locator: ObjectEnvelopeV1.open(bytes, collection: collection, protection: protection).locator, bytes: bytes)
    }
}
