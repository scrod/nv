import Foundation
import NVStorageCore

/// Two validation attempts observed newer accepted history and need a fresh pass.
enum HistoryValidationInterrupted: Error { case historyAdvanced }

private enum HistoryWorkerRequired: Error { case fullValidation }

/// Exact envelope bytes paired with the contents decoded from those bytes.
private struct HistoryObject: Sendable {
    let bytes: [UInt8]
    let locator: SegmentLocator
    let contents: ReceivedPayload
    let rootReferences: [SegmentLocator]

    init(bytes: [UInt8], locator: SegmentLocator, collection: CollectionID, protection: ObjectProtectionV1) throws {
        let opened = try ObjectEnvelopeV1.open(bytes, collection: collection, protection: protection, expectedLocator: locator)
        try self.init(bytes: bytes, opened: opened)
    }
    init(bytes: [UInt8], opened: OpenedObjectV1, rootReferences: [SegmentLocator]? = nil) throws {
        let locator = opened.locator
        self.bytes = bytes; self.locator = locator
        contents = try ReceivedPayload(opened)
        if case .generalRoot = contents, rootReferences == nil { throw StorageError.unsupported }
        self.rootReferences = rootReferences ?? []
    }

    var kind: ProviderObjectKind {
        switch contents { case .changes: .changes; case .page, .generalPage: .snapshotPage; case .root, .generalRoot: .snapshotRoot }
    }
    var dependencies: [SegmentLocator] {
        switch contents {
        case .changes(let payload): payload.dependencies.entries
        case .page(let page): page.dependencies.entries
        case .root(let root): Array(Set(root.dependencies.entries + root.pages.map(\.locator)))
        case .generalPage(let page):
            if case .index(let children) = page.contents { children.map(\.locator) } else { [] }
        case .generalRoot(let root): Array(Set(rootReferences + [root.tree.locator]))
        }
    }
    var changes: ChangesPayloadV1? {
        if case .changes(let payload) = contents { payload } else { nil }
    }
}

/// Acceptance input issued by complete bootstrap or declared-history validation.
private struct ValidatedHistoryBatch: Sendable {
    private enum Source: Sendable {
        case decoded([HistoryObject])
        case snapshot(CheckedSnapshotAcceptance)
        case bootstrap(InitialBootstrapValidationV1, LocalStoreSelection, ObjectProtectionV1, UUID)
    }
    private let source: Source
    let descriptor: BootstrapDescriptorV1?

    private init(objects: [HistoryObject], descriptor: BootstrapDescriptorV1? = nil) {
        source = .decoded(objects); self.descriptor = descriptor
    }
    private init(snapshot: CheckedSnapshotAcceptance) { source = .snapshot(snapshot); descriptor = nil }
    private init(bootstrap: InitialBootstrapValidationV1, selection: LocalStoreSelection,
                 protection: ObjectProtectionV1, connection: UUID) {
        source = .bootstrap(bootstrap, selection, protection, connection); descriptor = selection.descriptor
    }

    static func snapshot(_ checked: CheckedSnapshotAcceptance, database: Database, selection: LocalStoreSelection) throws -> Self {
        try checked.check(database: database, selection: selection)
        guard try database.missing(Array(checked.preview.historyLocators)).isEmpty else { throw StorageError.incomplete }
        return Self(snapshot: checked)
    }
    /// Consumes one stored page buffer at a time within the acceptance transaction.
    func forEach(database: Database, _ body: (HistoryObject) throws -> Void) throws {
        switch source {
        case .decoded(let objects): for object in objects { try body(object) }
        case .snapshot(let checked):
            let preview = checked.preview
            for locator in Array(preview.pages) + [preview.snapshot] {
                let (bytes, opened) = try checked.envelope(locator, database: database)
                try body(HistoryObject(bytes: bytes, opened: opened, rootReferences: Array(preview.historyLocators)))
            }
        case .bootstrap(let checked, let selection, let protection, let connection):
            guard database.incarnation == connection else { throw StorageError.wrongContext }
            try database.validateHeader(store: selection.store, descriptor: selection.descriptor, requireBootstrap: false)
            guard try database.stagedBootstrap() == checked.snapshot else { throw StorageError.wrongContext }
            for locator in checked.requiredObjects {
                guard let bytes = try database.snapshotCandidate(locator, collection: checked.collection, protection: protection) else {
                    throw InitialBootstrapValidationError.missingObject(locator)
                }
                try body(HistoryObject(bytes: bytes, locator: locator, collection: checked.collection, protection: protection))
            }
        }
    }

    /// Checks the original commitment and every incidental complete group before issuing acceptance input.
    static func storedBootstrap(snapshot: SegmentLocator, lane: DatabaseLane, selection: LocalStoreSelection,
                                protection: ObjectProtectionV1) async throws -> Self {
        let connection = try await lane.perform { db in
            try db.validateHeader(store: selection.store, descriptor: selection.descriptor, requireBootstrap: false)
            guard try db.stagedBootstrap() == snapshot else { throw StorageError.wrongContext }
            return db.incarnation
        }
        let checked = try await InitialBootstrapValidationV1.validateStored(descriptor: selection.descriptor,
            expectedCollection: selection.descriptor.collection, protection: protection, snapshot: snapshot) { locator in
                try await lane.perform { db in
                    try db.validateHeader(store: selection.store, descriptor: selection.descriptor, requireBootstrap: false)
                    return try db.snapshotCandidate(locator, collection: selection.descriptor.collection, protection: protection)
                }
            }
        func payload(_ locator: SegmentLocator) async throws -> ChangesPayloadV1? {
            let bytes = try await lane.perform { db in
                try db.snapshotCandidate(locator, collection: selection.descriptor.collection, protection: protection)
            }
            guard let bytes else { return nil }
            return try await lane.historyWork {
                let opened = try ObjectEnvelopeV1.open(bytes, collection: checked.collection, protection: protection, expectedLocator: locator)
                guard opened.kind == .changes else { throw CanonicalEncodingError.invalidReference }
                return try ChangesPayloadV1.decodeV1(opened.payload)
            }
        }
        var operationRefs: [OperationID: StoredOperationReferenceV1] = [:]
        var actionRefs: [ActionID: StoredActionReferenceV1] = [:]
        for locator in checked.changesOrder {
            guard let p = try await payload(locator) else { throw StorageError.incomplete }
            for (i, record) in p.operations.enumerated() {
                operationRefs[record.operation.id] = .init(locator: locator, index: OperationIndex(UInt32(i)), id: record.operation.id)
            }
            for (i, record) in p.actions.enumerated() {
                actionRefs[record.action.id] = .init(locator: locator, index: ActionIndex(UInt32(i)), id: record.action.id)
            }
        }
        var validatedOperations = checked.operationIDs, validatedActions = Set(checked.actions.map(\.id))
        var births = Set(checked.rows.map(\.birth))
        for locator in checked.changesOrder {
            guard let p = try await payload(locator) else { throw StorageError.incomplete }
            if p.operations.contains(where: { !validatedOperations.contains($0.operation.id) }) ||
               p.actions.contains(where: { !validatedActions.contains($0.action.id) }) {
                let knownOps = validatedOperations, knownActions = validatedActions, knownBirths = births
                let refs = operationRefs, actionAddresses = actionRefs
                try await OrdinaryHistoryV1.validate(p, at: locator, collection: checked.collection,
                    payloadAt: { try await payload($0) },
                    operationByID: { id in
                        guard knownOps.contains(id), let ref = refs[id], let p = try await payload(ref.locator) else { return nil }
                        return p.operations[Int(ref.index.rawValue)].operation
                    }, actionByID: { id in
                        guard knownActions.contains(id), let ref = actionAddresses[id], let p = try await payload(ref.locator) else { return nil }
                        return p.actions[Int(ref.index.rawValue)].action
                    }, birthExists: { knownBirths.contains($0) })
            }
            validatedOperations.formUnion(p.operations.map(\.operation.id)); validatedActions.formUnion(p.actions.map(\.action.id))
            births.formUnion(p.operations.compactMap { $0.operation.effect.targetBirth })
        }
        return Self(bootstrap: checked, selection: selection, protection: protection, connection: connection)
    }

    static func bootstrap(snapshot: SegmentLocator, objects: [SegmentLocator: [UInt8]], selection: LocalStoreSelection,
                          protection: ObjectProtectionV1) throws -> (Self, InitialBootstrapValidationV1) {
        let checked = try InitialBootstrapValidationV1.validate(descriptor: selection.descriptor,
            expectedCollection: selection.descriptor.collection, protection: protection, snapshot: snapshot,
            checkCancellation: { try Task.checkCancellation() }) { objects[$0] }
        guard checked.requiredObjects == Set(objects.keys) else { throw StorageError.integrity }
        let decoded = try checked.requiredObjects.map { locator in
            guard let bytes = objects[locator] else { throw StorageError.incomplete }
            return try HistoryObject(bytes: bytes, locator: locator, collection: selection.descriptor.collection, protection: protection)
        }
        return (Self(objects: decoded, descriptor: selection.descriptor), checked)
    }

    static func current(_ bytes: [UInt8], locator: SegmentLocator, database db: Database,
                        selection: LocalStoreSelection, protection: ObjectProtectionV1) throws -> Self {
        db.countWork { $0.envelopeDecodes += 1 }
        let object = try HistoryObject(bytes: bytes, locator: locator, collection: selection.descriptor.collection, protection: protection)
        guard let payload = object.changes else { throw StorageError.unsupported }
        guard let basis = try CheckedCurrentBasis(database: db, payload: payload) else { throw HistoryWorkerRequired.fullValidation }
        try payload.checkExternalReferences(at: locator,
            resolve: { try db.payload($0, collection: selection.descriptor.collection, protection: protection) })
        let operations = Dictionary(uniqueKeysWithValues: payload.operations.map { ($0.operation.id, $0.operation) })
        let action = payload.actions[0].action
        try OrdinaryHistoryV1.validateAction(action, scopeMaxima: basis.scope, states: basis.notes,
            operation: { guard let op = operations[$0] else { throw CanonicalEncodingError.invalidAction }; return op },
            previousOriginIsObserved: { try db.action($0, selection: selection, protection: protection)?.origin == action.origin },
            observes: { id, _ in basis.represented.contains(id) })
        db.countWork { $0.fastChecks += 1 }
        return Self(objects: [object])
    }

    static func historical(_ bytes: [UInt8], locator: SegmentLocator, through: Int64, lane: DatabaseLane,
                           selection: LocalStoreSelection, protection: ObjectProtectionV1,
                           historyCheck: (@Sendable () async -> Void)?) async throws -> Self {
        let object = try await lane.historyWork {
            return try HistoryObject(bytes: bytes, locator: locator, collection: selection.descriptor.collection, protection: protection)
        }
        await historyCheck?()
        guard let payload = object.changes else { throw StorageError.unsupported }
        try await OrdinaryHistoryV1.validate(payload, at: locator, collection: selection.descriptor.collection,
            payloadAt: { target in try await lane.historyRead(through: through) {
                try $0.payload(target, collection: selection.descriptor.collection, protection: protection)
            } },
            operationByID: { id in try await lane.historyRead(through: through) {
                try $0.operation(id, selection: selection, protection: protection)
            } },
            actionByID: { id in try await lane.historyRead(through: through) {
                try $0.action(id, selection: selection, protection: protection)
            } },
            birthExists: { birth in try await lane.historyRead(through: through) {
                try !$0.rows("SELECT 1 FROM operations WHERE birth=? LIMIT 1", [.blob(birth.bytes)]).isEmpty
            } })
        return Self(objects: [object])
    }
}

/// Ordinary-action inputs read from one complete, owned current materialization.
/// The constructor matches the incoming operation chain to that exact history.
private struct CheckedCurrentBasis {
    let scope: Set<ActionID>
    let notes: [NoteBirth: OrdinaryNoteInputsV1]
    let represented: Set<OperationID>

    init?(database db: Database, payload: ChangesPayloadV1) throws {
        guard payload.actions.count == 1, let action = payload.actions.first?.action,
              action.restorations.isEmpty, action.details == nil,
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
            guard cell?.derived == nil, cell?.automatic == nil else { return nil }
            let heads = Set(cell?.represented.map(\.id) ?? [])
            guard entry.before == (cell?.state ?? .freshBirthAbsence) else { return nil }
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
    /// Joins exact envelope bytes, declared-history validation and retained membership.
    func acceptOrdinary(_ bytes: [UInt8], locator: SegmentLocator,
                        selection: LocalStoreSelection, protection: ObjectProtectionV1) throws -> Int64 {
        try verifying(.history(acceptedThrough())) { try transaction {
            try validateHeader(store: selection.store, descriptor: selection.descriptor)
            return try acceptReadyOrdinary(bytes, locator: locator, selection: selection, protection: protection)
        } }
    }

    /// Validates and installs ordinary history inside the caller's acceptance transaction.
    private func acceptReadyOrdinary(_ bytes: [UInt8], locator: SegmentLocator,
                                        selection: LocalStoreSelection, protection: ObjectProtectionV1) throws -> Int64 {
        let batch = try measuring(.validation) {
            try ValidatedHistoryBatch.current(bytes, locator: locator, database: self, selection: selection, protection: protection)
        }
        return try measuring(.acceptance) { try accept(batch) }
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
        guard try !rows("SELECT 1 FROM accepted_objects WHERE object_id=?", [.blob(locator.segmentID.bytes)]).isEmpty else { return nil }
        return try verifying(.object(locator)) { try readAcceptedEnvelope(locator, collection: collection, protection: protection) }
    }
    private func readAcceptedEnvelope(_ locator: SegmentLocator, collection: CollectionID,
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
            let opened = try ObjectEnvelopeV1.open(bytes, collection: collection, protection: protection, expectedLocator: locator)
            countWork { $0.historyEncodedBytes += bytes.count; $0.historyDecodedBytes += opened.payload.count }
            return (bytes, opened)
        }
    }
    func initialize(store: LocalStoreID, descriptor: BootstrapDescriptorV1, snapshot: SegmentLocator?) throws {
        let schema = try String(contentsOf: Bundle.module.url(forResource: "SchemaV1", withExtension: "sql", subdirectory: "Resources")!, encoding: .utf8)
        try transaction {
            try exec(schema)
            try run("INSERT INTO store_header VALUES(1,1,?,?,?, ?,1,1,?,?)", [
                .blob(store.bytes), .blob(descriptor.collection.bytes), .integer(descriptor.keyID == nil ? 1 : 2),
                .blob(descriptor.keyID?.bytes ?? Array(repeating: 0, count: 16)),
                .blob(descriptor.genesis.encodedV1()), .blob(descriptor.descriptorID)])
            try run("INSERT INTO private_groups VALUES(?,1,1,?)", [.blob(Array("bootstrap".utf8)), .blob(snapshot?.encodedV1() ?? [])])
            try run("INSERT INTO private_groups VALUES(?,1,1,?)", [.blob(Array("settings".utf8)), .blob([])])
            try run("INSERT INTO view_meta VALUES(1,?,1,0,?)", [.blob(uuidBytes()), .blob(try AuthoringContextV1(operations: [], collectionActions: []).encodedV1())])
        }
    }
    func validateHeader(store: LocalStoreID, descriptor: BootstrapDescriptorV1, requireBootstrap: Bool = true) throws {
        let tables = try rows("SELECT name FROM sqlite_schema WHERE type='table' AND name IN ('store_header','objects','accepted_objects','private_groups','view_meta','current_notes','retained_frontier','retained_descriptors','ready_objects','object_waits')")
        guard tables.count == 10 else { throw StorageError.incomplete }
        let pending = try rows("SELECT name FROM sqlite_schema WHERE type='table' AND name IN ('pending_payloads','pending_items','pending_reservations','pending_settlements')")
        guard pending.count == 4 else { throw StorageError.incomplete }
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
        guard let settings = try privateGroup("settings") else { throw StorageError.incomplete }
        _ = try decodedSettings(settings)
        if let association = try privateGroup("association") {
            _ = try decodedAssociation(association, selection: .init(directory: "", store: store, descriptor: descriptor))
        }
        let bootstrap = try rows("SELECT codec,payload FROM private_groups WHERE group_key=?", [.blob(Array("bootstrap".utf8))])
        guard bootstrap.count == 1 else { throw StorageError.incomplete }
        guard bootstrap[0][0] == .integer(1) else { throw StorageError.unsupported }
        guard requireBootstrap else { return }
        guard let root = try stagedBootstrap() else { throw StorageError.incomplete }
        guard try !rows("SELECT 1 FROM accepted_objects a JOIN objects o USING(object_id) WHERE o.object_id=? AND o.kind=2 AND o.writer_epoch=? AND o.sequence=?", [.blob(root.segmentID.bytes), .blob(root.writerEpoch.bytes), .blob(Array(root.encodedV1()[16..<24]))]).isEmpty else { throw StorageError.incomplete }
    }

    /// Commits exact objects and complete membership from one validated batch.
    fileprivate func accept(_ batch: ValidatedHistoryBatch) throws -> Int64 {
        // Snapshot membership keeps addresses and edges while each bounded page buffer is consumed.
        var fresh: [(locator: SegmentLocator, dependencies: [SegmentLocator])] = []
        func retain(id: [UInt8], kind: Int64, writer: SQLValue, sequence: SQLValue, bytes: [UInt8]) throws -> Bool {
            let old = try rows("SELECT kind,writer_epoch,sequence,encoded FROM objects WHERE object_id=?", [.blob(id)])
            let expected: [SQLValue] = [.integer(kind), writer, sequence, .blob(bytes)]
            if old.isEmpty {
                try run("INSERT INTO objects VALUES(?,?,?,?,?)", [.blob(id)] + expected)
                try run("INSERT INTO ready_objects VALUES(?)", [.blob(id)])
            } else if old != [expected] { throw StorageError.integrity }
            return try rows("SELECT seq FROM accepted_objects WHERE object_id=?", [.blob(id)]).isEmpty
        }
        try batch.forEach(database: self) { object in
            let locator = object.locator
            if try retain(id: locator.segmentID.bytes, kind: Int64(object.kind.rawValue), writer: .blob(locator.writerEpoch.bytes),
                sequence: .blob(Array(locator.encodedV1()[16..<24])), bytes: object.bytes) {
                fresh.append((locator, object.dependencies))
            }
        }
        var freshDescriptor = false
        if let d = batch.descriptor { freshDescriptor = try retain(id: d.descriptorID, kind: 0, writer: .null, sequence: .null, bytes: d.encodedBytes) }
        let before = try acceptedThrough()
        guard !fresh.isEmpty || freshDescriptor else { return before }
        guard before < Int64.max else { throw StorageError.limit }
        let seq = before + 1
        try run("INSERT INTO acceptance_batches VALUES(?)", [.integer(seq)])
        for object in fresh { try run("INSERT INTO accepted_objects VALUES(?,?)", [.blob(object.locator.segmentID.bytes), .integer(seq)]) }
        if let d = batch.descriptor, freshDescriptor {
            try run("INSERT INTO accepted_objects VALUES(?,?)", [.blob(d.descriptorID), .integer(seq)])
            try run("INSERT INTO retained_descriptors VALUES(?)", [.blob(d.descriptorID)])
            try run("INSERT INTO accepted_dependencies VALUES(?,?)", [.blob(d.descriptorID), .blob(d.genesis.segmentID.bytes)])
        }
        for object in fresh {
            let locator = object.locator
            for parent in object.dependencies {
                try run("INSERT INTO accepted_dependencies VALUES(?,?)", [.blob(locator.segmentID.bytes), .blob(parent.segmentID.bytes)])
            }
        }
        let freshIDs = Set(fresh.map { $0.locator })
        try batch.forEach(database: self) { object in
            guard freshIDs.contains(object.locator) else { return }
            let locator = object.locator
            guard let payload = object.changes else { return }
            for (index, record) in payload.actions.enumerated() {
                let a = record.action
                if try rows("SELECT 1 FROM actions WHERE action_id=?", [.blob(a.id.bytes)]).isEmpty {
                    let scope: SQLValue
                    switch a.scope { case .collection: scope = .null; case .note(let b): scope = .blob(b.bytes) }
                    try run("INSERT INTO actions VALUES(?,?,?,?,?,?,?,?)", [.blob(a.id.bytes), .blob(a.origin.bytes),
                        a.previousOriginAction.map { .blob($0.bytes) } ?? .null, scope, .integer(Int64(a.kind.rawValue)),
                        .blob(locator.segmentID.bytes), .integer(Int64(index)), .integer(seq)])
                    for source in a.restorations {
                        try run("INSERT INTO restorations VALUES(?,?,?) ON CONFLICT(source_birth,deletion_action) DO NOTHING",
                            [.blob(source.sourceBirth.bytes), .blob(source.deletionAction.bytes), .blob(a.id.bytes)])
                    }
                }
            }
            for (index, record) in payload.operations.enumerated() {
                let op = record.operation
                let old = try rows("SELECT source_object,source_index FROM operations WHERE operation_id=?", [.blob(op.id.bytes)])
                if old.isEmpty {
                    let tag: Int64
                    switch op.effect { case .genesis: tag = 1; case .importComplete: tag = 2; case .create: tag = 3
                    case .importNote: tag = 4; case .put: tag = 5; case .delete: tag = 6
                    case .recoverCopy: tag = 7; case .retireConflict: tag = 8; case .adoptAutomatic: tag = 9 }
                    try run("INSERT INTO operations VALUES(?,?,?,?,?,?,?)", [.blob(op.id.bytes), .integer(tag),
                        op.effect.targetBirth.map { .blob($0.bytes) } ?? .null, op.effect.actionID.map { .blob($0.bytes) } ?? .null,
                        .blob(locator.segmentID.bytes), .integer(Int64(index)), .integer(seq)])
                }
            }
        }
        try batch.forEach(database: self) { object in
            guard freshIDs.contains(object.locator) else { return }
            let locator = object.locator
            guard let payload = object.changes else { return }
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
        for object in fresh {
            let locator = object.locator
            try run("INSERT INTO retained_frontier VALUES(?,?)", [.blob(locator.segmentID.bytes), .blob(locator.encodedV1())])
        }
        for object in fresh {
            try run("DELETE FROM retained_frontier WHERE object_id IN (SELECT prerequisite FROM accepted_dependencies WHERE child=?)", [.blob(object.locator.segmentID.bytes)])
        }
        return seq
    }
    /// Reads the staged root address, including the explicitly unfinished local-writer state.
    func stagedBootstrap() throws -> SegmentLocator? {
        let r = try rows("SELECT codec,payload FROM private_groups WHERE group_key=?", [.blob(Array("bootstrap".utf8))])
        guard r.count == 1 else { throw StorageError.incomplete }
        guard r[0][0] == .integer(1) else { throw StorageError.unsupported }
        let bytes = try r[0][1].bytes
        return bytes.isEmpty ? nil : try SegmentLocator.decodeV1(bytes)
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
    /// Commits a verified stored bootstrap as one complete acceptance unit.
    nonisolated func acceptStoredBootstrap(_ snapshot: SegmentLocator, selection: LocalStoreSelection,
                                          protection: ObjectProtectionV1) async throws -> Int64 {
        let result = try await self.verifyingHistory {
            let batch = try await ValidatedHistoryBatch.storedBootstrap(snapshot: snapshot, lane: self, selection: selection, protection: protection)
            let result = try await perform { db in
                let sequence = try db.transaction { try db.measuring(.acceptance) { try db.accept(batch) } }
                return (sequence, db.work?.acceptanceCompletion)
            }
            return result
        }
        try await result.1?(snapshot)
        return result.0
    }
    /// Revalidates retained assembly and commits its complete membership under the live owner.
    nonisolated func acceptGeneralSnapshot(_ locator: SegmentLocator, selection: LocalStoreSelection,
                                          protection: ObjectProtectionV1, assembled: GeneralSnapshotPreviewV1? = nil) async throws -> (Int64, GeneralSnapshotPreviewV1) {
        let result = try await self.verifyingHistory { () async throws -> ((Int64, GeneralSnapshotPreviewV1), (@Sendable (SegmentLocator) async throws -> Void)?) in
            let previous = try await perform { db -> (Int64, (@Sendable (SegmentLocator) async throws -> Void)?)? in
                try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
                guard let row = try db.rows("SELECT seq FROM accepted_objects WHERE object_id=?", [.blob(locator.segmentID.bytes)]).first else { return nil }
                _ = try db.acceptedEnvelope(locator, collection: selection.descriptor.collection, protection: protection)
                return try (row[0].number, db.work?.acceptanceCompletion)
            }
            let preview: GeneralSnapshotPreviewV1
            do {
                if let assembled {
                    guard assembled.snapshot == locator else { throw StorageError.wrongContext }
                    preview = assembled
                } else {
                    preview = try await GeneralSnapshotPreviewV1.read(snapshot: locator, collection: selection.descriptor.collection,
                        protection: protection) { target in
                            try await self.perform { db in
                                try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
                                return try db.snapshotCandidate(target, collection: selection.descriptor.collection, protection: protection)
                            }
                        }
                }
            } catch {
                if previous != nil, error is GeneralSnapshotError {
                    return try await perform { db in try db.checkingRetainedHistory { throw StorageError.integrity } }
                }
                throw error
            }
            if let previous {
                try await perform { db in
                    try db.checkingRetainedHistory {
                        guard try db.missing(Array(preview.pages)).isEmpty else { throw StorageError.incomplete }
                    }
                }
                try? await catchUp(selection: selection, protection: protection)
                return ((previous.0, preview), previous.1)
            }
            let checked = try await CheckedSnapshotAcceptance.verify(preview, lane: self, selection: selection, protection: protection)
            let result = try await perform { db in
                let sequence = try db.transaction {
                    let batch = try ValidatedHistoryBatch.snapshot(checked, database: db, selection: selection)
                    // Ready recovery and the original caller may have completed the same exact root.
                    if let row = try db.rows("SELECT seq FROM accepted_objects WHERE object_id=?", [.blob(locator.segmentID.bytes)]).first {
                        return try row[0].number
                    }
                    return try db.measuring(.acceptance) { try db.accept(batch) }
                }
                return (sequence, db.work?.acceptanceCompletion)
            }
            try? await catchUp(selection: selection, protection: protection)
            return ((result.0, preview), result.1)
        }
        try await result.1?(locator)
        return result.0
    }

    /// Routes initial-format roots through complete import validation under the selected bootstrap.
    nonisolated func acceptReceivedBootstrap(_ locator: SegmentLocator, objects: [SegmentLocator: [UInt8]],
        selection: LocalStoreSelection, protection: ObjectProtectionV1) async throws -> Int64 {
        return try await self.verifyingHistory {
            let connection = try await perform { db in
                try db.validateHeader(store: selection.store, descriptor: selection.descriptor); return db.incarnation
            }
            let (batch, checked) = try await historyWork {
                try ValidatedHistoryBatch.bootstrap(snapshot: locator, objects: objects, selection: selection, protection: protection)
            }
            return try await perform { db in
                try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
                guard db.incarnation == connection else { throw StorageError.wrongContext }
                return try db.transaction {
                    for target in checked.requiredObjects {
                        guard try db.snapshotCandidate(target, collection: selection.descriptor.collection, protection: protection) == objects[target] else { throw StorageError.incomplete }
                    }
                    return try db.accept(batch)
                }
            }
        }
    }

    /// Checks current-state saves in one turn and suspends between other ancestry reads.
    nonisolated func acceptScheduled(_ bytes: [UInt8], locator: SegmentLocator, selection: LocalStoreSelection,
                         protection: ObjectProtectionV1) async throws -> Int64 {
        let result = try await self.verifyingHistory {
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
                    return result
                } catch HistoryWorkerRequired.fullValidation { }
                do {
                    let (through, historyCheck, historyValidated) = try await perform { db in
                        try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
                        db.measuring(.validation) { db.countWork { $0.fullChecks += 1 } }
                        return (try db.acceptedThrough(), db.work?.historyCheck, db.work?.historyValidated)
                    }
                    let checked = try await ValidatedHistoryBatch.historical(bytes, locator: locator, through: through, lane: self,
                        selection: selection, protection: protection, historyCheck: historyCheck)
                    await historyValidated?()
                    let result = try await perform { db in
                        let sequence = try db.transaction {
                            try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
                            guard try db.acceptedThrough() == through else { throw StorageError.staleCapture }
                            return try db.measuring(.acceptance) {
                                try db.accept(checked)
                            }
                        }
                        return (sequence, db.work?.acceptanceCompletion)
                    }
                    return result
                } catch StorageError.staleCapture { continue }
            }
            throw HistoryValidationInterrupted.historyAdvanced
        }
        try await result.1?(locator)
        return result.0
    }
}

func uuidBytes() -> [UInt8] {
    let u = UUID().uuid
    return [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
}
