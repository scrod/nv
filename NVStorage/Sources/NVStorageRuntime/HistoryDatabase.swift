import Foundation
import NVStorageCore

/// Two validation attempts observed newer accepted history and need a fresh pass.
enum HistoryValidationInterrupted: Error { case historyAdvanced }

private struct HistoryUnit {
    let objects: [SegmentLocator: [UInt8]]
    let payloads: [SegmentLocator: ChangesPayloadV1]
    let dependencies: [SegmentLocator: [SegmentLocator]]
    let descriptor: BootstrapDescriptorV1?
}

private enum HistoryWorkerRequired: Error { case fullValidation }

/// Completed validation bound to exact bytes and the owner's accepted prefix.
private struct CheckedHistoryWork: Sendable {
    let bytes: [UInt8]
    let locator: SegmentLocator
    let payload: ChangesPayloadV1
    let through: Int64
}

/// Ordinary-action inputs read from one complete, owned current materialization.
/// The constructor matches the incoming operation chain to that exact history.
private struct CheckedCurrentBasis {
    let scope: Set<ActionID>
    let notes: [NoteBirth: OrdinaryNoteInputsV1]
    let represented: Set<OperationID>

    init?(database db: Database, payload: ChangesPayloadV1) throws {
        guard payload.actions.count == 1, let action = payload.actions.first?.action,
              action.members == payload.operations.map(\.operation.id),
              action.members.count == action.affected.count else { return nil }
        let ops = payload.operations.map(\.operation)
        guard Set(ops.compactMap(\.effect.targetBirth)).count == ops.count else { return nil }
        for op in ops {
            switch op.effect { case .create, .put, .delete: break; default: return nil }
            if try !db.rows("SELECT 1 FROM operations WHERE operation_id=?", [.blob(op.id.bytes)]).isEmpty { return nil }
        }
        guard try db.rows("SELECT 1 FROM actions WHERE action_id=?", [.blob(action.id.bytes)]).isEmpty else { return nil }
        let meta = try db.rows("SELECT epoch,reducer_version,through_seq,authoring_context FROM view_meta WHERE singleton=1")
        guard meta.count == 1, try meta[0][0].bytes.count == 16, meta[0][1] == .integer(1),
              try meta[0][2].number > 0, try meta[0][2].number == db.acceptedThrough() else { return nil }
        let context: AuthoringContextV1
        do { context = try AuthoringContextV1.decodeV1(meta[0][3].bytes) }
        catch is CanonicalEncodingError { return nil }
        guard !context.operations.isEmpty else { return nil }
        for (index, op) in ops.enumerated() {
            let expected = index == 0 ? Set(context.operations.map(\.id)) : [ops[index - 1].id]
            guard Set(op.causalParents.ids) == expected else { return nil }
        }
        var states: [NoteBirth: OrdinaryNoteInputsV1] = [:]
        var revisions: Set<OperationID> = []
        var scope = Set(context.collectionActions.map(\.id))
        let byBirth = Dictionary(uniqueKeysWithValues: ops.map { ($0.effect.targetBirth!, $0) })
        for entry in action.affected {
            let rows = try db.rows("SELECT cell FROM current_notes WHERE birth=?", [.blob(entry.birth.bytes)])
            let cell: CurrentNoteCellV1?
            do { cell = try rows.first.map { try CurrentNoteCellV1.decodeV1($0[0].bytes) } }
            catch is CanonicalEncodingError { return nil }
            guard cell == nil || cell?.birth == entry.birth else { return nil }
            let heads: Set<OperationID> = cell.map { [$0.revision.id] } ?? []
            guard entry.before == (cell.map { .value($0.revision.id) } ?? .freshBirthAbsence) else { return nil }
            guard let op = byBirth[entry.birth] else { return nil }
            let expectedPredecessors: Set<OperationID>
            if case .put = op.effect { expectedPredecessors = heads } else { expectedPredecessors = [] }
            guard Set(op.notePredecessors.ids) == expectedPredecessors else { return nil }
            if case .create = op.effect,
               try !db.rows("SELECT 1 FROM operations WHERE birth=? LIMIT 1", [.blob(entry.birth.bytes)]).isEmpty {
                throw OrdinaryHistoryError.reusedBirth
            }
            if case .note(let birth) = action.scope {
                guard birth == entry.birth else { return nil }
                scope = Set(cell?.scopeFrontier.map(\.id) ?? [])
            }
            states[entry.birth] = OrdinaryNoteInputsV1(heads: heads, deleted: false)
            revisions.formUnion(heads)
        }
        guard scope == Set(action.scopeParents) else { return nil }
        self.scope = scope; notes = states; represented = revisions
    }
}

extension Database {
    /// Validates the exact bootstrap closure and commits its complete retained membership.
    func acceptBootstrap(_ initial: InitialCollectionV1, selection: LocalStoreSelection,
                         protection: ObjectProtectionV1) throws -> InitialBootstrapValidationV1 {
        try transaction {
            try validateHeader(store: selection.store, descriptor: selection.descriptor, requireBootstrap: false)
            let checked = try InitialBootstrapValidationV1.validate(descriptor: selection.descriptor,
                expectedCollection: selection.descriptor.collection, protection: protection, snapshot: initial.snapshot) { initial.objects[$0] }
            let unit = try bootstrapUnit(objects: initial.objects, descriptor: selection.descriptor, protection: protection)
            _ = try accept(unit, collection: selection.descriptor.collection, protection: protection)
            return checked
        }
    }

    /// Joins exact envelope bytes, declared-history validation and retained membership.
    func acceptOrdinary(_ bytes: [UInt8], locator: SegmentLocator,
                        selection: LocalStoreSelection, protection: ObjectProtectionV1) throws -> Int64 {
        try transaction {
            try validateHeader(store: selection.store, descriptor: selection.descriptor)
            return try acceptReadyOrdinary(bytes, locator: locator, selection: selection, protection: protection)
        }
    }

    /// Validates and installs ordinary history inside the caller's acceptance transaction.
    private func acceptReadyOrdinary(_ bytes: [UInt8], locator: SegmentLocator,
                                        selection: LocalStoreSelection, protection: ObjectProtectionV1) throws -> Int64 {
        let payload = try measuring(.validation) {
            countWork { $0.envelopeDecodes += 1 }
            let opened = try ObjectEnvelopeV1.open(bytes, collection: selection.descriptor.collection,
                protection: protection, expectedLocator: locator)
            guard opened.kind == .changes else { throw StorageError.unsupported }
            let payload = try ChangesPayloadV1.decodeV1(opened.payload)
            if let basis = try CheckedCurrentBasis(database: self, payload: payload) {
                try payload.checkExternalReferences(at: locator,
                    resolve: { try self.payload($0, collection: selection.descriptor.collection, protection: protection) })
                let operations = Dictionary(uniqueKeysWithValues: payload.operations.map { ($0.operation.id, $0.operation) })
                let action = payload.actions[0].action
                try OrdinaryHistoryV1.validateAction(action, scopeMaxima: basis.scope, states: basis.notes,
                    operation: { guard let op = operations[$0] else { throw CanonicalEncodingError.invalidAction }; return op },
                    previousOriginIsObserved: { try self.action($0, selection: selection, protection: protection)?.origin == action.origin },
                    observes: { id, _ in basis.represented.contains(id) })
                countWork { $0.fastChecks += 1 }
            } else {
                throw HistoryWorkerRequired.fullValidation
            }
            return payload
        }
        return try measuring(.acceptance) { try accept(HistoryUnit(objects: [locator: bytes], payloads: [locator: payload],
            dependencies: [locator: payload.dependencies.entries], descriptor: nil),
            collection: selection.descriptor.collection, protection: protection) }
    }

    func acceptedThrough() throws -> Int64 {
        try rows("SELECT COALESCE(MAX(seq),0) FROM acceptance_batches")[0][0].number
    }
    func payload(_ locator: SegmentLocator, collection: CollectionID, protection: ObjectProtectionV1) throws -> ChangesPayloadV1? {
        guard let (_, opened) = try acceptedEnvelope(locator, collection: collection, protection: protection) else { return nil }
        guard opened.kind == .changes else { throw CanonicalEncodingError.invalidReference }
        return try checkingRetainedHistory {
            return try ChangesPayloadV1.decodeV1(opened.payload)
        }
    }
    func acceptedEnvelope(_ locator: SegmentLocator, collection: CollectionID,
                          protection: ObjectProtectionV1) throws -> ([UInt8], OpenedObjectV1)? {
        countWork { $0.historyReads += 1 }
        let r = try rows("SELECT o.encoded,o.writer_epoch,o.sequence FROM accepted_objects a LEFT JOIN objects o USING(object_id) WHERE a.object_id=?",
            [.blob(locator.segmentID.bytes)])
        guard let row = r.first else { return nil }
        guard row[0] != .null else { return try checkingRetainedHistory { throw StorageError.incomplete } }
        // Validate the caller's locator against the stored address before checking retained bytes for damage.
        guard row[1] == .blob(locator.writerEpoch.bytes), row[2] == .blob(Array(locator.encodedV1()[16..<24])) else {
            throw CanonicalEncodingError.invalidReference
        }
        return try checkingRetainedHistory {
            let bytes = try row[0].bytes
            countWork { $0.envelopeDecodes += 1 }
            return try (bytes, ObjectEnvelopeV1.open(bytes, collection: collection, protection: protection, expectedLocator: locator))
        }
    }
    func initialize(store: LocalStoreID, descriptor: BootstrapDescriptorV1, snapshot: SegmentLocator) throws {
        let schema = try String(contentsOf: Bundle.module.url(forResource: "SchemaV1", withExtension: "sql", subdirectory: "Resources")!, encoding: .utf8)
        try transaction {
            try exec(schema)
            try run("INSERT INTO store_header VALUES(1,1,?,?,?, ?,1,1,?,?)", [
                .blob(store.bytes), .blob(descriptor.collection.bytes), .integer(descriptor.keyID == nil ? 1 : 2),
                .blob(descriptor.keyID?.bytes ?? Array(repeating: 0, count: 16)),
                .blob(descriptor.genesis.encodedV1()), .blob(descriptor.descriptorID)])
            try run("INSERT INTO private_groups VALUES(?,1,1,?)", [.blob(Array("bootstrap".utf8)), .blob(snapshot.encodedV1())])
            try run("INSERT INTO private_groups VALUES(?,1,1,?)", [.blob(Array("settings".utf8)), .blob([])])
            try run("INSERT INTO view_meta VALUES(1,?,1,0,?)", [.blob(uuidBytes()), .blob(try AuthoringContextV1(operations: [], collectionActions: []).encodedV1())])
        }
    }
    func validateHeader(store: LocalStoreID, descriptor: BootstrapDescriptorV1, requireBootstrap: Bool = true) throws {
        let tables = try rows("SELECT name FROM sqlite_schema WHERE type='table' AND name IN ('store_header','objects','accepted_objects','private_groups','view_meta','current_notes','retained_frontier','retained_descriptors','ready_objects','object_waits')")
        guard tables.count == 10 else { throw StorageError.incomplete }
        let r = try rows("SELECT schema_version,local_store_id,collection_id,profile,key_id,note_codec,merge_policy,genesis_locator,bootstrap_descriptor FROM store_header WHERE singleton=1")
        guard r.count == 1 else { throw StorageError.incomplete }
        let expected: [SQLValue] = [.integer(1), .blob(store.bytes), .blob(descriptor.collection.bytes),
            .integer(descriptor.keyID == nil ? 1 : 2), .blob(descriptor.keyID?.bytes ?? Array(repeating: 0, count: 16)),
            .integer(1), .integer(1), .blob(descriptor.genesis.encodedV1()), .blob(descriptor.descriptorID)]
        guard r[0][0] == .integer(1), r[0][5] == .integer(1), r[0][6] == .integer(1) else { throw StorageError.unsupported }
        guard r[0] == expected else { throw StorageError.wrongContext }
        try run("SELECT object_id,validator_version,reason FROM rejected_objects LIMIT 0")
        guard try rows("SELECT 1 FROM private_groups WHERE group_key=?", [.blob(Array("history-damage".utf8))]).isEmpty else {
            throw StorageError.integrity
        }
        let settings = try rows("SELECT codec,payload FROM private_groups WHERE group_key=?", [.blob(Array("settings".utf8))])
        guard !settings.isEmpty else { throw StorageError.incomplete }
        guard settings == [[.integer(1), .blob([])]] else { throw StorageError.unsupported }
        let bootstrap = try rows("SELECT codec,payload FROM private_groups WHERE group_key=?", [.blob(Array("bootstrap".utf8))])
        guard bootstrap.count == 1 else { throw StorageError.incomplete }
        guard bootstrap[0][0] == .integer(1) else { throw StorageError.unsupported }
        let root = try SegmentLocator.decodeV1(bootstrap[0][1].bytes)
        guard requireBootstrap else { return }
        guard try !rows("SELECT 1 FROM accepted_objects a JOIN objects o USING(object_id) WHERE o.object_id=? AND o.kind=2 AND o.writer_epoch=? AND o.sequence=?", [.blob(root.segmentID.bytes), .blob(root.writerEpoch.bytes), .blob(Array(root.encodedV1()[16..<24]))]).isEmpty else { throw StorageError.incomplete }
    }

    /// Inserts a previously validated unit within the caller's acceptance transaction.
    fileprivate func accept(_ unit: HistoryUnit, collection: CollectionID, protection: ObjectProtectionV1) throws -> Int64 {
        var fresh: [SegmentLocator] = []
        func retain(id: [UInt8], kind: Int64, writer: SQLValue, sequence: SQLValue, bytes: [UInt8]) throws -> Bool {
            let old = try rows("SELECT kind,writer_epoch,sequence,encoded FROM objects WHERE object_id=?", [.blob(id)])
            let expected: [SQLValue] = [.integer(kind), writer, sequence, .blob(bytes)]
            if old.isEmpty {
                try run("INSERT INTO objects VALUES(?,?,?,?,?)", [.blob(id)] + expected)
                try run("INSERT INTO ready_objects VALUES(?)", [.blob(id)])
            } else if old != [expected] { throw StorageError.integrity }
            return try rows("SELECT seq FROM accepted_objects WHERE object_id=?", [.blob(id)]).isEmpty
        }
        for (locator, bytes) in unit.objects {
            countWork { $0.envelopeDecodes += 1 }
            let kind = try ObjectEnvelopeV1.open(bytes, collection: collection, protection: protection, expectedLocator: locator).kind
            if try retain(id: locator.segmentID.bytes, kind: Int64(kind.rawValue), writer: .blob(locator.writerEpoch.bytes),
                sequence: .blob(Array(locator.encodedV1()[16..<24])), bytes: bytes) { fresh.append(locator) }
        }
        var freshDescriptor = false
        if let d = unit.descriptor { freshDescriptor = try retain(id: d.descriptorID, kind: 0, writer: .null, sequence: .null, bytes: d.encodedBytes) }
        let before = try acceptedThrough()
        guard !fresh.isEmpty || freshDescriptor else { return before }
        guard before < Int64.max else { throw StorageError.limit }
        let seq = before + 1
        try run("INSERT INTO acceptance_batches VALUES(?)", [.integer(seq)])
        for locator in fresh { try run("INSERT INTO accepted_objects VALUES(?,?)", [.blob(locator.segmentID.bytes), .integer(seq)]) }
        if let d = unit.descriptor, freshDescriptor {
            try run("INSERT INTO accepted_objects VALUES(?,?)", [.blob(d.descriptorID), .integer(seq)])
            try run("INSERT INTO retained_descriptors VALUES(?)", [.blob(d.descriptorID)])
            try run("INSERT INTO accepted_dependencies VALUES(?,?)", [.blob(d.descriptorID), .blob(d.genesis.segmentID.bytes)])
        }
        for locator in fresh {
            for parent in unit.dependencies[locator] ?? [] {
                try run("INSERT INTO accepted_dependencies VALUES(?,?)", [.blob(locator.segmentID.bytes), .blob(parent.segmentID.bytes)])
            }
            guard let payload = unit.payloads[locator] else { continue }
            for (index, record) in payload.actions.enumerated() {
                let a = record.action
                if try rows("SELECT 1 FROM actions WHERE action_id=?", [.blob(a.id.bytes)]).isEmpty {
                    let scope: SQLValue
                    switch a.scope { case .collection: scope = .null; case .note(let b): scope = .blob(b.bytes) }
                    try run("INSERT INTO actions VALUES(?,?,?,?,?,?,?,?)", [.blob(a.id.bytes), .blob(a.origin.bytes),
                        a.previousOriginAction.map { .blob($0.bytes) } ?? .null, scope, .integer(Int64(a.kind.rawValue)),
                        .blob(locator.segmentID.bytes), .integer(Int64(index)), .integer(seq)])
                }
            }
            for (index, record) in payload.operations.enumerated() {
                let op = record.operation
                let old = try rows("SELECT source_object,source_index FROM operations WHERE operation_id=?", [.blob(op.id.bytes)])
                if old.isEmpty {
                    let tag: Int64
                    switch op.effect { case .genesis: tag = 1; case .importComplete: tag = 2; case .create: tag = 3
                    case .importNote: tag = 4; case .put: tag = 5; case .delete: tag = 6 }
                    try run("INSERT INTO operations VALUES(?,?,?,?,?,?,?)", [.blob(op.id.bytes), .integer(tag),
                        op.effect.targetBirth.map { .blob($0.bytes) } ?? .null, op.effect.actionID.map { .blob($0.bytes) } ?? .null,
                        .blob(locator.segmentID.bytes), .integer(Int64(index)), .integer(seq)])
                }
            }
        }
        for locator in fresh {
            guard let payload = unit.payloads[locator] else { continue }
            for (index, record) in payload.operations.enumerated() {
                let op = record.operation
                try run("INSERT INTO operation_occurrences VALUES(?,?,?)", [.blob(locator.segmentID.bytes), .integer(Int64(index)), .blob(op.id.bytes)])
                for parent in op.causalParents.ids { try run("INSERT INTO operation_parents VALUES(?,?) ON CONFLICT DO NOTHING", [.blob(op.id.bytes), .blob(parent.bytes)]) }
                for parent in op.notePredecessors.ids { try run("INSERT INTO note_predecessors VALUES(?,?) ON CONFLICT DO NOTHING", [.blob(op.id.bytes), .blob(parent.bytes)]) }
            }
            for (index, record) in payload.actions.enumerated() {
                let a = record.action
                try run("INSERT INTO action_occurrences VALUES(?,?,?)", [.blob(locator.segmentID.bytes), .integer(Int64(index)), .blob(a.id.bytes)])
                for (n, member) in a.members.enumerated() {
                    try run("INSERT INTO action_members VALUES(?,?,?) ON CONFLICT DO NOTHING", [.blob(a.id.bytes), .integer(Int64(n)), .blob(member.bytes)])
                }
                for parent in a.scopeParents { try run("INSERT INTO action_scope_parents VALUES(?,?) ON CONFLICT DO NOTHING", [.blob(a.id.bytes), .blob(parent.bytes)]) }
            }
        }
        // Add the complete batch before removing its direct prerequisites. Any
        // older indirect ancestor already has an accepted descendant above it.
        for locator in fresh {
            try run("INSERT INTO retained_frontier VALUES(?,?)", [.blob(locator.segmentID.bytes), .blob(locator.encodedV1())])
        }
        for locator in fresh {
            try run("DELETE FROM retained_frontier WHERE object_id IN (SELECT prerequisite FROM accepted_dependencies WHERE child=?)", [.blob(locator.segmentID.bytes)])
        }
        return seq
    }
    func operationOccurrence(_ id: OperationID) throws -> StoredOperationReferenceV1 {
        let r = try rows("SELECT o.writer_epoch,o.sequence,o.object_id,p.source_index FROM operations p JOIN objects o ON o.object_id=p.source_object WHERE p.operation_id=?", [.blob(id.bytes)])
        guard let row = r.first else { throw StorageError.incomplete }
        guard let index = UInt32(exactly: try row[3].number) else { throw StorageError.integrity }
        return try StoredOperationReferenceV1(locator: SegmentLocator.decodeV1(row[0].bytes + row[1].bytes + row[2].bytes), index: OperationIndex(index), id: id)
    }
    func actionOccurrence(_ id: ActionID) throws -> StoredActionReferenceV1 {
        let r = try rows("SELECT o.writer_epoch,o.sequence,o.object_id,a.source_index FROM actions a JOIN objects o ON o.object_id=a.source_object WHERE a.action_id=?", [.blob(id.bytes)])
        guard let row = r.first else { throw StorageError.incomplete }
        guard let index = UInt32(exactly: try row[3].number) else { throw StorageError.integrity }
        return try StoredActionReferenceV1(locator: SegmentLocator.decodeV1(row[0].bytes + row[1].bytes + row[2].bytes), index: ActionIndex(index), id: id)
    }
}

extension DatabaseLane {
    /// Checks current-state saves in one turn and suspends between other ancestry reads.
    nonisolated func acceptScheduled(_ bytes: [UInt8], locator: SegmentLocator, selection: LocalStoreSelection,
                         protection: ObjectProtectionV1) async throws -> Int64 {
        for _ in 0..<2 {
            do {
                let result = try await perform { db in
                    let old = try db.rows("SELECT a.seq,o.encoded FROM accepted_objects a JOIN objects o USING(object_id) WHERE object_id=?",
                                          [.blob(locator.segmentID.bytes)])
                    if let row = old.first {
                        guard row[1] == .blob(bytes) else { throw StorageError.integrity }
                        return (try row[0].number, db.work?.acceptanceCompletion)
                    }
                    let sequence = try db.acceptOrdinary(bytes, locator: locator, selection: selection, protection: protection)
                    return (sequence, db.work?.acceptanceCompletion)
                }
                try await result.1?(locator)
                return result.0
            } catch HistoryWorkerRequired.fullValidation { }
            do {
                let (through, historyCheck, historyValidated) = try await perform { db in
                    try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
                    db.measuring(.validation) { db.countWork { $0.fullChecks += 1 } }
                    return (try db.acceptedThrough(), db.work?.historyCheck, db.work?.historyValidated)
                }
                let payload = try await historyWork {
                    historyCheck?()
                    let opened = try ObjectEnvelopeV1.open(bytes, collection: selection.descriptor.collection,
                        protection: protection, expectedLocator: locator)
                    guard opened.kind == .changes else { throw StorageError.unsupported }
                    return try ChangesPayloadV1.decodeV1(opened.payload)
                }
                try await OrdinaryHistoryV1.validate(payload, at: locator,
                    payloadAt: { target in try await self.historyRead(through: through) {
                        try $0.payload(target, collection: selection.descriptor.collection, protection: protection)
                    } },
                    operationByID: { id in try await self.historyRead(through: through) {
                        try $0.operation(id, selection: selection, protection: protection)
                    } },
                    actionByID: { id in try await self.historyRead(through: through) {
                        try $0.action(id, selection: selection, protection: protection)
                    } },
                    birthExists: { birth in try await self.historyRead(through: through) {
                        try !$0.rows("SELECT 1 FROM operations WHERE birth=? LIMIT 1", [.blob(birth.bytes)]).isEmpty
                    } })
                let checked = CheckedHistoryWork(bytes: bytes, locator: locator, payload: payload, through: through)
                await historyValidated?()
                let result = try await perform { db in
                    let sequence = try db.transaction {
                        try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
                        guard try db.acceptedThrough() == checked.through else { throw StorageError.staleCapture }
                        return try db.measuring(.acceptance) {
                            try db.accept(HistoryUnit(objects: [checked.locator: checked.bytes],
                                payloads: [checked.locator: checked.payload],
                                dependencies: [checked.locator: checked.payload.dependencies.entries], descriptor: nil),
                                collection: selection.descriptor.collection, protection: protection)
                        }
                    }
                    return (sequence, db.work?.acceptanceCompletion)
                }
                try await result.1?(locator)
                return result.0
            } catch StorageError.staleCapture { continue }
        }
        throw HistoryValidationInterrupted.historyAdvanced
    }
}

private func bootstrapUnit(objects: [SegmentLocator: [UInt8]], descriptor: BootstrapDescriptorV1,
                           protection: ObjectProtectionV1) throws -> HistoryUnit {
    var payloads: [SegmentLocator: ChangesPayloadV1] = [:], dependencies: [SegmentLocator: [SegmentLocator]] = [:]
    for (locator, bytes) in objects {
        let o = try ObjectEnvelopeV1.open(bytes, collection: descriptor.collection, protection: protection, expectedLocator: locator)
        switch o.kind {
        case .changes:
            let p = try ChangesPayloadV1.decodeV1(o.payload); payloads[locator] = p; dependencies[locator] = p.dependencies.entries
        case .snapshotPage: dependencies[locator] = try InitialSnapshotPageV1.decodeV1(o.payload).dependencies.entries
        case .snapshotRoot:
            let r = try InitialSnapshotRootV1.decodeV1(o.payload)
            dependencies[locator] = Array(Set(r.dependencies.entries + r.pages.map(\.locator)))
        }
    }
    return HistoryUnit(objects: objects, payloads: payloads, dependencies: dependencies, descriptor: descriptor)
}

func uuidBytes() -> [UInt8] {
    let u = UUID().uuid
    return [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
}
