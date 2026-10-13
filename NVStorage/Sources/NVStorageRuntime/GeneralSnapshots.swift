import Foundation
import NVStorageCore

/// Neutral portable claims captured from one complete owned acceptance prefix.
public struct GeneralSnapshotCapture: Sendable {
    public let store: LocalStoreID
    public let collection: CollectionID
    public let through: Int64
    public let bootstrapSnapshot: SegmentLocator
    public let records: [GeneralSnapshotRecordV1]
    public let retentionParents: [SegmentLocator]
    private let session: UUID
    private init(store: LocalStoreID, collection: CollectionID, through: Int64,
                 bootstrapSnapshot: SegmentLocator, records: [GeneralSnapshotRecordV1], retentionParents: [SegmentLocator], session: UUID) {
        self.store = store; self.collection = collection; self.through = through
        self.bootstrapSnapshot = bootstrapSnapshot; self.records = records
        self.session = session
        self.retentionParents = retentionParents
    }
    func checkOwner(_ owner: LocalStoreSession) throws {
        guard session == owner.incarnation, store == owner.selection.store,
              collection == owner.selection.descriptor.collection else { throw StorageError.wrongContext }
    }
    fileprivate static func read(session: LocalStoreSession) async throws -> Self {
        let (selection, protection) = (session.selection, session.protection)
        let (through, bootstrap, parents) = try await session.snapshotHistoryContext()
        let graph = try await session.lane.snapshotHistoryGraph(through: through, selection: selection, protection: protection)
        let records = try await session.lane.checkedSnapshotRecords(graph, collection: selection.descriptor.collection)
        try await session.checkSnapshotOwner(through: through)
        return Self(store: selection.store, collection: selection.descriptor.collection, through: through,
                    bootstrapSnapshot: bootstrap, records: records, retentionParents: parents, session: session.incarnation)
    }
}

/// A complete preview whose logical claims match exact history retained by this owner.
public struct VerifiedGeneralSnapshotClaims: Sendable {
    public let store: LocalStoreID
    public let collection: CollectionID
    public let snapshot: SegmentLocator
    public let checkedThrough: Int64
    public let operationIDs: Set<OperationID>
    private let session: UUID
    private init(store: LocalStoreID, collection: CollectionID, session: UUID, snapshot: SegmentLocator, through: Int64, operationIDs: Set<OperationID>) {
        self.store = store; self.collection = collection; self.session = session
        self.snapshot = snapshot; checkedThrough = through; self.operationIDs = operationIDs
    }
    fileprivate static func verify(_ preview: GeneralSnapshotPreviewV1, session: LocalStoreSession) async throws -> Self {
        let (selection, protection) = (session.selection, session.protection)
        let checked = try await CheckedSnapshotAcceptance.verify(preview, lane: session.lane, selection: selection, protection: protection)
        try await session.checkSnapshotOwner(through: checked.through)
        return Self(store: selection.store, collection: selection.descriptor.collection, session: session.incarnation,
                    snapshot: preview.snapshot, through: checked.through, operationIDs: checked.operationIDs)
    }
}

/// Store-backed assembly whose exact claims match a complete accepted history cut.
struct CheckedSnapshotAcceptance: Sendable {
    let preview: GeneralSnapshotPreviewV1
    let through: Int64
    let operationIDs: Set<OperationID>
    private let store: LocalStoreID
    private let collection: CollectionID
    private let protection: ObjectProtectionV1
    private let connection: UUID
    private let parents: CheckedRetentionParents

    private init(preview: GeneralSnapshotPreviewV1, through: Int64, operationIDs: Set<OperationID>,
                 selection: LocalStoreSelection, protection: ObjectProtectionV1, connection: UUID, parents: CheckedRetentionParents) {
        self.preview = preview; self.through = through; self.operationIDs = operationIDs
        store = selection.store; collection = selection.descriptor.collection; self.protection = protection
        self.connection = connection
        self.parents = parents
    }
    func check(database: Database, selection: LocalStoreSelection) throws {
        guard connection == database.incarnation, store == selection.store,
              collection == selection.descriptor.collection else { throw StorageError.wrongContext }
        try database.validateHeader(store: store, descriptor: selection.descriptor)
        guard try database.acceptedThrough() >= through,
              try database.snapshotBootstrap() == preview.root.bootstrapSnapshot else { throw StorageError.staleCapture }
        try parents.check(database: database, selection: selection, protection: protection)
    }
    func objectBytes(_ locator: SegmentLocator, database: Database) throws -> [UInt8] {
        guard let bytes = try database.snapshotCandidate(locator, collection: collection, protection: protection) else {
            throw GeneralSnapshotError.missingObject(locator)
        }
        return bytes
    }
    func envelope(_ locator: SegmentLocator, database: Database) throws -> ([UInt8], OpenedObjectV1) {
        let bytes = try objectBytes(locator, database: database)
        return try (bytes, ObjectEnvelopeV1.open(bytes, collection: collection,
                                 protection: protection, expectedLocator: locator))
    }
    static func verify(_ preview: GeneralSnapshotPreviewV1, lane: DatabaseLane,
                       selection: LocalStoreSelection, protection: ObjectProtectionV1) async throws -> Self {
        try await verifyWithGraph(preview, lane: lane, selection: selection, protection: protection).0
    }
    static func verifyWithGraph(_ preview: GeneralSnapshotPreviewV1, lane: DatabaseLane,
                       selection: LocalStoreSelection, protection: ObjectProtectionV1,
                       checkedTraversal: CheckedHistoryTraversal? = nil) async throws -> (Self, RetainedGraph) {
        try preview.checkProtection(collection: selection.descriptor.collection, protection: protection)
        let (through, bootstrap, connection) = try await lane.perform { db in
            try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
            let through = try checkedTraversal?.through ?? db.acceptedThrough()
            guard try db.acceptedThrough() >= through else { throw StorageError.staleCapture }
            return try (through, db.snapshotBootstrap(), db.incarnation)
        }
        guard preview.root.bootstrapSnapshot == bootstrap else { throw GeneralSnapshotError.invalidState }
        guard !preview.retentionParents.contains(preview.snapshot) else { throw CanonicalEncodingError.invalidReference }
        let parents = try await lane.perform { db in
            try CheckedRetentionParents.read(preview.retentionParents, through: through,
                database: db, selection: selection, protection: protection)
        }
        let traversal: CheckedHistoryTraversal
        if let checkedTraversal { traversal = checkedTraversal }
        else { traversal = try await CheckedHistoryTraversal.read(through: through, scope: .allOccurrences,
            lane: lane, selection: selection, protection: protection) }
        let graph = traversal.graph
        let operationsByLocator = Dictionary(grouping: preview.records.flatMap(\.operationReferences), by: \.locator)
        let actionsByLocator = Dictionary(grouping: preview.records.flatMap(\.actionReferences), by: \.locator)
        // Resolve every stated occurrence, including references used only by continuation indexes.
        for locator in preview.historyLocators.sorted(by: { $0.encodedV1().lexicographicallyPrecedes($1.encodedV1()) }) {
            try Task.checkCancellation()
            try await lane.perform { db in
                try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
                if locator == bootstrap {
                    guard let (_, object) = try db.acceptedEnvelope(locator, collection: selection.descriptor.collection, protection: protection),
                          object.kind == .snapshotRoot, operationsByLocator[locator] == nil,
                          actionsByLocator[locator] == nil else { throw GeneralSnapshotError.invalidState }; return
                }
                try traversal.checkReferences(locator: locator, operations: operationsByLocator[locator] ?? [],
                    actions: actionsByLocator[locator] ?? [], database: db, selection: selection)
            }
        }
        let frontier = Set(preview.records.compactMap { record -> OperationID? in
            if case .frontier(let ref) = record { return ref.id }; return nil
        })
        let cut = try await snapshotCut(frontier: frontier, graph: graph)
        let expected = try await lane.checkedSnapshotRecords(cut, collection: selection.descriptor.collection)
        guard snapshotClaimsEqual(preview.records, expected) else { throw GeneralSnapshotError.invalidState }
        return (Self(preview: preview, through: through, operationIDs: Set(cut.operations.keys),
                    selection: selection, protection: protection, connection: connection, parents: parents), graph)
    }
}

extension DatabaseLane {
    /// Rechecks accepted snapshot assembly and claims using the captured complete occurrence audit.
    nonisolated func auditAcceptedSnapshots(_ traversal: CheckedHistoryTraversal, selection: LocalStoreSelection,
        protection: ObjectProtectionV1) async throws {
        var sequence: Int64 = 0, position: [UInt8] = []
        while true {
            let cursor = position, start = sequence
            let rows = try await perform { try $0.rows("SELECT a.seq,o.writer_epoch,o.sequence,o.object_id FROM accepted_objects a JOIN objects o USING(object_id) WHERE a.seq<=? AND (a.seq,a.object_id)>(?,?) AND o.kind IN(2,3) ORDER BY a.seq,a.object_id LIMIT 64", [.integer(traversal.through), .integer(start), .blob(cursor)]) }
            for row in rows {
                let locator = try SegmentLocator.decodeV1(row[1].bytes + row[2].bytes + row[3].bytes)
                do {
                    let input = try await perform { db in
                        guard let (_, object) = try db.acceptedEnvelope(locator, collection: selection.descriptor.collection, protection: protection) else { throw StorageError.incomplete }
                        return try db.checkingRetainedHistory { try ReceivedPayload(object) }
                    }
                    switch input {
                    case .generalRoot:
                        let preview = try await GeneralSnapshotPreviewV1.read(snapshot: locator, collection: selection.descriptor.collection, protection: protection) { target in
                            try await self.perform { try $0.snapshotCandidate(target, collection: selection.descriptor.collection, protection: protection) }
                        }
                        _ = try await CheckedSnapshotAcceptance.verifyWithGraph(preview, lane: self, selection: selection, protection: protection, checkedTraversal: traversal)
                    case .root:
                        _ = try await InitialBootstrapValidationV1.validateStored(descriptor: selection.descriptor, expectedCollection: selection.descriptor.collection,
                            protection: protection, snapshot: locator) { target in
                            try await self.perform { try $0.snapshotCandidate(target, collection: selection.descriptor.collection, protection: protection) }
                        }
                    default: break
                    }
                } catch {
                    if error is GeneralSnapshotError { return try await perform { db in try db.checkingRetainedHistory { throw StorageError.integrity } } }
                    return try await perform { db in try db.checkingRetainedHistory { throw error } }
                }
            }
            guard rows.count == 64 else { return }
            sequence = try rows.last![0].number; position = try rows.last![3].bytes
        }
    }
    /// Audits complete indexed membership against actual accepted envelopes at the captured prefix.
    nonisolated func snapshotHistoryGraph(through: Int64, selection: LocalStoreSelection,
                                          protection: ObjectProtectionV1) async throws -> RetainedGraph {
        try await CheckedHistoryTraversal.read(through: through, scope: .allOccurrences,
            lane: self, selection: selection, protection: protection).graph
    }
    /// Preserves discovered required-history damage while preparing neutral snapshot claims.
    nonisolated func checkedSnapshotRecords(_ graph: RetainedGraph, collection: CollectionID) async throws -> [GeneralSnapshotRecordV1] {
        do { return try await historyWork { try graph.snapshotRecords(collection: collection) } }
        catch { return try await perform { db in try db.checkingRetainedHistory { throw error } } }
    }
}

extension LocalStoreSession {
    /// Captures neutral accepted values and continuation indexes for optional snapshot construction.
    public func captureGeneralSnapshot() async throws -> GeneralSnapshotCapture {
        guard !closed, !quiescing else { throw StorageError.closed }
        return try await lane.verifyingHistory { try await GeneralSnapshotCapture.read(session: self) }
    }
    /// Compares a fully assembled snapshot with its represented cut of locally accepted history.
    public func verifyGeneralSnapshot(_ preview: GeneralSnapshotPreviewV1) async throws -> VerifiedGeneralSnapshotClaims {
        guard !closed, !quiescing else { throw StorageError.closed }
        return try await lane.verifyingHistory { try await VerifiedGeneralSnapshotClaims.verify(preview, session: self) }
    }
    fileprivate func snapshotHistoryContext() async throws -> (Int64, SegmentLocator, [SegmentLocator]) {
        guard !closed, !quiescing else { throw StorageError.closed }
        let selection = selection
        return try await lane.perform { db in
            try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
            let parents = try db.rows("SELECT r.locator FROM retained_frontier r JOIN objects o USING(object_id) JOIN accepted_objects a USING(object_id) WHERE o.kind=2 ORDER BY r.locator")
                .map { try SegmentLocator.decodeV1($0[0].bytes) }
            return try (db.acceptedThrough(), db.snapshotBootstrap(), parents)
        }
    }
    fileprivate func checkSnapshotOwner(through: Int64) async throws {
        guard !closed, !quiescing else { throw StorageError.closed }
        let selection = selection
        try await lane.perform { db in
            try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
            guard try db.acceptedThrough() >= through else { throw StorageError.staleCapture }
        }
        guard !closed, !quiescing else { throw StorageError.closed }
    }
}

/// Exact accepted root bytes bound to the owner that checked their retention eligibility.
private struct CheckedRetentionParents: Sendable {
    private let roots: [(SegmentLocator, [UInt8])]
    private let through: Int64
    private let connection: UUID
    private let store: LocalStoreID

    private init(roots: [(SegmentLocator, [UInt8])], through: Int64, database: Database, selection: LocalStoreSelection) {
        self.roots = roots; self.through = through; connection = database.incarnation; store = selection.store
    }
    static func read(_ locators: [SegmentLocator], through: Int64, database: Database,
                     selection: LocalStoreSelection, protection: ObjectProtectionV1) throws -> Self {
        try database.validateHeader(store: selection.store, descriptor: selection.descriptor)
        let roots = try locators.map { locator in
            try (locator, rootBytes(locator, through: through, database: database, selection: selection, protection: protection))
        }
        return Self(roots: roots, through: through, database: database, selection: selection)
    }
    func check(database: Database, selection: LocalStoreSelection, protection: ObjectProtectionV1) throws {
        guard connection == database.incarnation, store == selection.store else { throw StorageError.wrongContext }
        for (locator, bytes) in roots {
            guard try Self.rootBytes(locator, through: through, database: database, selection: selection, protection: protection) == bytes else {
                throw StorageError.integrity
            }
        }
    }
    private static func rootBytes(_ locator: SegmentLocator, through: Int64, database db: Database,
                                  selection: LocalStoreSelection, protection: ObjectProtectionV1) throws -> [UInt8] {
        guard let row = try db.rows("SELECT seq FROM accepted_objects WHERE object_id=?", [.blob(locator.segmentID.bytes)]).first,
              try row[0].number <= through else { throw GeneralSnapshotError.missingObject(locator) }
        guard let (bytes, object) = try db.acceptedEnvelope(locator, collection: selection.descriptor.collection, protection: protection) else {
            throw GeneralSnapshotError.missingObject(locator)
        }
        guard object.kind == .snapshotRoot else { throw CanonicalEncodingError.invalidReference }
        _ = try db.checkingRetainedHistory { try ReceivedPayload(object) }
        db.countWork { $0.retentionParentChecks += 1 }
        return bytes
    }
}

extension Database {
    func snapshotBootstrap() throws -> SegmentLocator {
        let rows = try rows("SELECT codec,payload FROM private_groups WHERE group_key=?", [.blob(Array("bootstrap".utf8))])
        guard rows.count == 1, rows[0][0] == .integer(1) else { throw StorageError.incomplete }
        let bootstrap = try SegmentLocator.decodeV1(rows[0][1].bytes)
        guard try !self.rows("SELECT 1 FROM accepted_objects WHERE object_id=?", [.blob(bootstrap.segmentID.bytes)]).isEmpty else { throw StorageError.incomplete }
        return bootstrap
    }
    /// Reads an exact retained assembly input, classifying damage by accepted membership.
    func snapshotCandidate(_ locator: SegmentLocator, collection: CollectionID,
                           protection: ObjectProtectionV1) throws -> [UInt8]? {
        let rows = try rows("SELECT encoded,writer_epoch,sequence,kind FROM objects WHERE object_id=?", [.blob(locator.segmentID.bytes)])
        guard let row = rows.first else {
            if try !self.rows("SELECT 1 FROM accepted_objects WHERE object_id=?", [.blob(locator.segmentID.bytes)]).isEmpty {
                return try checkingRetainedHistory { throw StorageError.incomplete }
            }
            return nil
        }
        let accepted = try !self.rows("SELECT 1 FROM accepted_objects WHERE object_id=?", [.blob(locator.segmentID.bytes)]).isEmpty
        let read = {
            let bytes = try row[0].bytes
            let object = try ObjectEnvelopeV1.open(bytes, collection: collection, protection: protection)
            guard object.locator.segmentID == locator.segmentID,
                  row[1] == .blob(object.locator.writerEpoch.bytes),
                  row[2] == .blob(Array(object.locator.encodedV1()[16..<24])),
                  row[3] == .integer(Int64(object.kind.rawValue)) else { throw CanonicalEncodingError.identityMismatch }
            return (bytes, object.locator)
        }
        let (bytes, actual) = try accepted ? checkingRetainedHistory(read) : read()
        guard actual == locator else { throw CanonicalEncodingError.invalidReference }
        countWork { $0.candidateReads += 1; $0.candidateBytes += bytes.count; $0.largestCandidateBytes = max($0.largestCandidateBytes, bytes.count) }
        return bytes
    }
}

/// Reconstructs complete groups reachable through the claimed logical operation frontier.
private func snapshotCut(frontier: Set<OperationID>, graph: RetainedGraph) async throws -> RetainedGraph {
    try await graph.causalCut(frontier: frontier)
}

/// Complete derived replacement issued by exact snapshot/history verification under one owner.
private struct PreparedReconstruction: Sendable {
    let target: Int64
    let start: [[SQLValue]]
    let rows: EncodedCurrentRows
    let context: AuthoringContextV1
    private let connection: UUID
    private let store: LocalStoreID
    private let descriptor: [UInt8]
    private let basis: CheckedSnapshotAcceptance?
    private let bootstrap: SegmentLocator

    private init(target: Int64, start: [[SQLValue]], rows: EncodedCurrentRows, context: AuthoringContextV1,
                 connection: UUID, selection: LocalStoreSelection, basis: CheckedSnapshotAcceptance?, bootstrap: SegmentLocator) {
        self.target = target; self.start = start; self.rows = rows; self.context = context
        self.connection = connection; store = selection.store; descriptor = selection.descriptor.descriptorID
        self.basis = basis; self.bootstrap = bootstrap
    }
    /// Installs only the complete result prepared for this exact connection, history and prior view.
    func install(database db: Database, selection: LocalStoreSelection) throws {
        guard connection == db.incarnation, store == selection.store, descriptor == selection.descriptor.descriptorID else { throw StorageError.wrongContext }
        try db.transaction {
            try db.validateHeader(store: store, descriptor: selection.descriptor)
            try db.validateRequiredPrivateGroups(store: store, descriptor: selection.descriptor)
            try basis?.check(database: db, selection: selection)
            guard try db.snapshotBootstrap() == bootstrap, try db.acceptedThrough() == target,
                  try db.rows("SELECT epoch,reducer_version,through_seq,authoring_context FROM view_meta WHERE singleton=1") == start else {
                throw StorageError.staleCapture
            }
            try db.run("DELETE FROM current_notes")
            try rows.install(database: db)
            try db.run("INSERT INTO view_meta VALUES(1,?,1,?,?) ON CONFLICT(singleton) DO UPDATE SET epoch=excluded.epoch,reducer_version=1,through_seq=excluded.through_seq,authoring_context=excluded.authoring_context",
                [.blob(uuidBytes()), .integer(target), .blob(context.encodedV1())])
            db.countWork { $0.reconstructionInstallations += 1 }
        }
    }

    static func prepare(lane: DatabaseLane, selection: LocalStoreSelection, protection: ObjectProtectionV1) async throws -> Self {
        let (start, connection, bootstrap) = try await lane.perform { db in
            try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
            try db.checkRequiredLeaves(descriptor: selection.descriptor, protection: protection)
            return try (db.rows("SELECT epoch,reducer_version,through_seq,authoring_context FROM view_meta WHERE singleton=1"), db.incarnation, db.snapshotBootstrap())
        }
        // Accepted roots are indexed candidates. Every selected byte is rechecked as required history.
        let roots = try await lane.perform { db in
            try db.rows("SELECT o.writer_epoch,o.sequence,o.object_id FROM accepted_objects a JOIN objects o USING(object_id) WHERE o.kind=2 ORDER BY a.seq DESC,a.object_id")
        }
        var preview: GeneralSnapshotPreviewV1?
        for row in roots {
            let locator = try SegmentLocator.decodeV1(row[0].bytes + row[1].bytes + row[2].bytes)
            let general = try await lane.perform { db in
                guard let (_, opened) = try db.acceptedEnvelope(locator, collection: selection.descriptor.collection, protection: protection),
                      opened.kind == .snapshotRoot else { throw StorageError.incomplete }
                return opened.payload.starts(with: Array("NVGRT1\r\n".utf8))
            }
            if general {
                preview = try await GeneralSnapshotPreviewV1.read(snapshot: locator, collection: selection.descriptor.collection, protection: protection) { target in
                        try await lane.perform { db in
                            guard let (bytes, _) = try db.acceptedEnvelope(target, collection: selection.descriptor.collection, protection: protection) else {
                                return try db.checkingRetainedHistory { throw StorageError.incomplete }
                            }
                            return bytes
                        }
                }
                break
            }
        }
        let graph: RetainedGraph, represented: Set<OperationID>, seed: [CurrentNoteCellV1], basis: CheckedSnapshotAcceptance?, target: Int64
        if let preview {
            let verified = try await CheckedSnapshotAcceptance.verifyWithGraph(preview, lane: lane, selection: selection, protection: protection)
            basis = verified.0; graph = verified.1; target = verified.0.through
            represented = verified.0.operationIDs
            seed = preview.records.compactMap { if case .current(let cell) = $0 { cell } else { nil } }
            try await lane.perform { db in
                try db.checkingRetainedHistory {
                    guard try db.missing(Array(preview.pages) + [preview.snapshot]).isEmpty else { throw StorageError.incomplete }
                }
            }
        } else {
            target = try await lane.perform { try $0.acceptedThrough() }
            let checked = try await InitialBootstrapValidationV1.validateStored(descriptor: selection.descriptor,
                expectedCollection: selection.descriptor.collection, protection: protection, snapshot: bootstrap) { locator in
                    try await lane.perform { db in
                        guard let (bytes, _) = try db.acceptedEnvelope(locator, collection: selection.descriptor.collection, protection: protection) else {
                            return try db.checkingRetainedHistory { throw StorageError.incomplete }
                        }
                        return bytes
                    }
                }
            graph = try await lane.snapshotHistoryGraph(through: target, selection: selection, protection: protection)
            represented = checked.operationIDs; basis = nil
            seed = try checked.rows.map { row in
                guard case .external(let locator, let index, let id) = row.importReference else { throw StorageError.integrity }
                let actions = try (checked.scopeFrontiers[.note(row.birth)]?.actionIDs ?? []).map { id in
                    guard let ref = graph.actionReferences[id] else { throw StorageError.incomplete }; return ref
                }
                return try CurrentNoteCellV1(birth: row.birth, value: row.value,
                    revision: .init(locator: locator, index: index, id: id), scopeFrontier: actions)
            }
        }
        let result = try await lane.historyWork {
            try Self.reduce(seed: seed, represented: represented, graph: graph, collection: selection.descriptor.collection)
        }
        try await lane.perform { db in
            db.countWork {
                $0.reconstructionSeeds += 1; $0.reconstructionOutsideOperations += result.outside
                $0.reconstructionAffectedBirths += result.affected; $0.reconstructionReusedCells += result.reused
            }
        }
        let dictionary = try await lane.perform { try $0.currentDictionary() }
        let rows = try await lane.historyWork { try EncodedCurrentRows(cells: result.cells, dictionary: dictionary) }
        return Self(target: target, start: start, rows: rows, context: result.context,
                    connection: connection, selection: selection, basis: basis, bootstrap: bootstrap)
    }

    /// Subtracts logical operation IDs, then expands touched scopes to their linked preservation outputs.
    private static func reduce(seed: [CurrentNoteCellV1], represented: Set<OperationID>, graph: RetainedGraph,
                               collection: CollectionID) throws -> (cells: [CurrentNoteCellV1], context: AuthoringContextV1, outside: Int, affected: Int, reused: Int) {
        let outside = Set(graph.operations.keys).subtracting(represented)
        let actionIDs = Set(outside.compactMap { graph.operations[$0]?.effect.actionID })
        var affected = Set(outside.compactMap { graph.operations[$0]?.effect.targetBirth })
        for id in actionIDs {
            guard let action = graph.actions[id], action.members.allSatisfy(outside.contains) else { throw StorageError.integrity }
            affected.formUnion(action.affected.map(\.birth))
            if case .note(let birth) = action.scope { affected.insert(birth) }
        }
        for cell in seed {
            if let automatic = cell.automatic, affected.contains(cell.birth) { affected.insert(automatic.birth) }
        }
        let reused = seed.filter { !affected.contains($0.birth) && !($0.automatic.map { affected.contains($0.birth) } ?? false) }
        let recomputed = try graph.currentCells(collection: collection, affectedBirths: affected)
        var cells = Dictionary(uniqueKeysWithValues: reused.map { ($0.birth, $0) })
        for cell in recomputed { cells[cell.birth] = cell }
        let frontier = Set(graph.operations.keys).subtracting(graph.operations.values.flatMap { $0.causalParents.ids })
        let context = try AuthoringContextV1(operations: frontier.map {
            guard let ref = graph.operationReferences[$0] else { throw StorageError.incomplete }; return ref
        }, collectionActions: graph.scopeMaxima(.collection).map {
            guard let ref = graph.actionReferences[$0] else { throw StorageError.incomplete }; return ref
        })
        return (cells.values.sorted { $0.birth.bytes.lexicographicallyPrecedes($1.birth.bytes) }, context, outside.count, affected.count, reused.count)
    }
}

extension DatabaseLane {
    /// Keeps indexed returning startup separate from exceptional full verification and reconstruction.
    nonisolated func reconstructIfNeeded(selection: LocalStoreSelection, protection: ObjectProtectionV1, session: UUID) async throws -> StoreSnapshot? {
        switch try await perform({ try $0.usableMaterialization(selection: selection, session: session) }) {
        case .current(let snapshot): return snapshot
        case .lagged: return nil
        case .invalid: try await reconstruct(selection: selection, protection: protection); return nil
        }
    }
    nonisolated func reconstruct(selection: LocalStoreSelection, protection: ObjectProtectionV1) async throws {
        try await perform { try $0.validateRequiredPrivateGroups(store: selection.store, descriptor: selection.descriptor) }
        return try await self.verifyingHistory {
            while true {
                try Task.checkCancellation()
                do {
                    let prepared = try await PreparedReconstruction.prepare(lane: self, selection: selection, protection: protection)
                    let gate = try await perform { $0.work?.reconstructionPrepared }
                    await gate?()
                    try await perform { db in try db.measuring(.materialization) { try prepared.install(database: db, selection: selection) } }
                    return
                } catch StorageError.staleCapture { continue }
                catch let error as GeneralSnapshotError {
                    let failure: StorageError
                    switch error {
                    case .missingObject: failure = .incomplete
                    case .invalidManifest, .invalidState: failure = .integrity
                    }
                    return try await perform { db in try db.checkingRetainedHistory { throw failure } }
                } catch let error as InitialBootstrapValidationError {
                    let failure: StorageError
                    switch error {
                    case .missingObject: failure = .incomplete
                    case .requiresGeneralHistoryValidation: failure = .unsupported
                    case .cyclicDependencies, .conflictingClaim, .invalidCommitment, .invalidCausalHistory,
                         .invalidActionHistory, .invalidSnapshot: failure = .integrity
                    }
                    return try await perform { db in try db.checkingRetainedHistory { throw failure } }
                }
            }
        }
    }
}

extension LocalStoreSession {
    /// Reconstructs complete derived rows while preserving independently owned pending and presentation state.
    public func rebuildCurrentRows() async throws -> StoreSnapshot {
        guard !closed, !quiescing else { throw StorageError.closed }
        let selection = selection, protection = protection
        try await lane.reconstruct(selection: selection, protection: protection)
        guard !closed, !quiescing else { throw StorageError.closed }
        return try await snapshot()
    }
}

private extension RetainedGraph {
    func snapshotRecords(collection: CollectionID) throws -> [GeneralSnapshotRecordV1] {
        let reduction = try CollectionReductionV1.compute(collection: collection, operations: Array(operations.values), actions: Array(actions.values))
        var records = try currentCells(collection: collection).map(GeneralSnapshotRecordV1.current)
        let frontier = Set(operations.keys).subtracting(operations.values.flatMap { $0.causalParents.ids })
        for id in frontier {
            guard let ref = operationReferences[id] else { throw StorageError.incomplete }; records.append(.frontier(ref))
        }
        for scope in Set(actions.values.map(\.scope)) {
            for id in scopeMaxima(scope) {
                guard let ref = actionReferences[id] else { throw StorageError.incomplete }; records.append(.scope(scope, ref))
            }
        }
        for op in operations.values {
            if case .delete(_, let birth) = op.effect {
                guard let ref = operationReferences[op.id] else { throw StorageError.incomplete }; records.append(.deleted(birth, ref))
            }
        }
        records += reduction.retired.map(GeneralSnapshotRecordV1.retired)
        records += reduction.dispositions.map(GeneralSnapshotRecordV1.disposition)
        for action in actions.values {
            records += action.restorations.map { .restored(source: $0.sourceBirth, deletion: $0.deletionAction, action: action.id, birth: $0.birth) }
        }
        return try GeneralSnapshotV1.canonicalOrder(records)
    }
}

/// Compares semantic state while permitting independently checked equivalent transport occurrences.
private func snapshotClaimsEqual(_ claims: [GeneralSnapshotRecordV1], _ expected: [GeneralSnapshotRecordV1]) -> Bool {
    guard claims.count == expected.count else { return false }
    for (claim, expected) in zip(claims, expected) {
        switch (claim, expected) {
        case (.current(let lhs), .current(let rhs)):
            guard lhs.birth == rhs.birth, lhs.value == rhs.value, lhs.state == rhs.state,
                  lhs.represented.map(\.id) == rhs.represented.map(\.id), lhs.heads.map(\.id) == rhs.heads.map(\.id),
                  lhs.scopeFrontier.map(\.id) == rhs.scopeFrontier.map(\.id), lhs.identity == rhs.identity else { return false }
        case (.frontier(let lhs), .frontier(let rhs)): if lhs.id != rhs.id { return false }
        case (.scope(let ls, let lhs), .scope(let rs, let rhs)): if ls != rs || lhs.id != rhs.id { return false }
        case (.deleted(let lb, let lhs), .deleted(let rb, let rhs)): if lb != rb || lhs.id != rhs.id { return false }
        default: if claim != expected { return false }
        }
    }
    return true
}
