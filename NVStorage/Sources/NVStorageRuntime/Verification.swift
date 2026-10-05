import Foundation
import NVStorageCore

/// Exact retained input or accepted prefix whose unfinished checks survive reopening.
enum VerificationRecipe: Equatable, Sendable {
    case object(SegmentLocator)
    case history(Int64)
    case bootstrap(SegmentLocator)

    func encoded() -> [UInt8] {
        switch self {
        case .object(let locator): return [1] + locator.encodedV1()
        case .bootstrap(let locator): return [3] + locator.encodedV1()
        case .history(let through):
            let n = UInt64(through)
            return [2] + (0..<8).reversed().map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) }
        }
    }
    static func decode(_ bytes: [UInt8]) throws -> Self {
        guard let kind = bytes.first else { throw StorageError.integrity }
        switch kind {
        case 1, 3:
            guard bytes.count == 57 else { throw StorageError.integrity }
            let locator = try SegmentLocator.decodeV1(Array(bytes.dropFirst()))
            return kind == 1 ? .object(locator) : .bootstrap(locator)
        case 2:
            guard bytes.count == 9 else { throw StorageError.integrity }
            let n = bytes.dropFirst().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard n > 0, n <= UInt64(Int64.max) else { throw StorageError.integrity }
            return .history(Int64(n))
        default: throw StorageError.unsupported
        }
    }
}

/// Durable private replay request bound to its original store and descriptor.
struct VerificationRecord: Equatable, Sendable {
    static let prefix = Array("verification/".utf8)
    static let end = Array("verification0".utf8)
    private static let magic = Array("NVVRFY1\n".utf8)
    let key: [UInt8]
    let context: [UInt8]
    let recipe: VerificationRecipe
    private init(key: [UInt8], context: [UInt8], recipe: VerificationRecipe) {
        self.key = key; self.context = context; self.recipe = recipe
    }
    fileprivate static func new(context: [UInt8], recipe: VerificationRecipe) -> Self {
        Self(key: prefix + uuidBytes(), context: context, recipe: recipe)
    }
    var encoded: [UInt8] { Self.magic + context + recipe.encoded() }
    static func decode(key: [UInt8], codec: Int64, generation: Int64, bytes: [UInt8], context: [UInt8]) throws -> Self {
        guard codec == 1 else { throw StorageError.unsupported }
        guard context.count == 64, generation == 1, key.count == prefix.count + 16, key.starts(with: prefix),
              bytes.starts(with: magic), bytes.count >= magic.count + context.count,
              Array(bytes[magic.count..<(magic.count + context.count)]) == context else { throw StorageError.integrity }
        return try Self(key: key, context: context, recipe: VerificationRecipe.decode(Array(bytes.dropFirst(magic.count + context.count))))
    }
}

/// Connection-owned permission issued after the exact replay request commits.
struct AdmittedVerification: Sendable {
    let record: VerificationRecord
    private let connection: UUID
    private init(record: VerificationRecord, connection: UUID) { self.record = record; self.connection = connection }
    fileprivate static func admit(database: Database, recipe: VerificationRecipe, existing: VerificationRecord? = nil) throws -> Self {
        let context = try database.verificationContext()
        if case .history(let through) = recipe, through <= 0 { throw StorageError.wrongContext }
        let record = existing ?? VerificationRecord.new(context: context, recipe: recipe)
        guard record.context == context, record.recipe == recipe else { throw StorageError.wrongContext }
        if existing == nil {
            try database.transaction {
                guard try database.rows("SELECT group_key FROM private_groups WHERE group_key>=? AND group_key<? LIMIT 64",
                    [.blob(VerificationRecord.prefix), .blob(VerificationRecord.end)]).count < 64 else { throw StorageError.busy }
                try database.run("INSERT INTO private_groups VALUES(?,1,1,?)", [.blob(record.key), .blob(record.encoded)])
            }
        } else {
            guard try database.rows("SELECT codec,generation,payload FROM private_groups WHERE group_key=?", [.blob(record.key)]) ==
                [[.integer(1), .integer(1), .blob(record.encoded)]] else { throw StorageError.staleCapture }
        }
        return Self(record: record, connection: database.incarnation)
    }
    func check(database: Database) throws {
        try database.validateOwner()
        guard connection == database.incarnation, record.context == (try database.verificationContext()) else { throw StorageError.wrongContext }
    }
    fileprivate func covers(_ recipe: VerificationRecipe, database: Database) throws -> Bool {
        try check(database: database)
        switch (record.recipe, recipe) {
        case (.bootstrap(let held), .bootstrap(let requested)): return held == requested
        case (.bootstrap, .history(let requested)): return requested <= 1
        case (.bootstrap, .object(let locator)):
            return try database.rows("SELECT seq FROM accepted_objects WHERE object_id=?", [.blob(locator.segmentID.bytes)]).first?.first?.number == 1
        case (.history(let bound), .history(let requested)): return requested <= bound
        case (.object(let held), .object(let requested)): return held == requested
        case (.history(let bound), .object(let locator)):
            guard let row = try database.rows("SELECT seq FROM accepted_objects WHERE object_id=?", [.blob(locator.segmentID.bytes)]).first else { return false }
            return try row[0].number <= bound
        default: return false
        }
    }
}

/// Exact successful verification carried to its owning settlement transaction.
private struct VerifiedVerification: Sendable {
    let admitted: AdmittedVerification
    private init(admitted: AdmittedVerification) { self.admitted = admitted }
    fileprivate static func completed(_ admitted: AdmittedVerification) -> Self { Self(admitted: admitted) }
}

/// Inherited protection shared by a logical check and all of its nested reads.
enum VerificationScope {
    @TaskLocal static var current: AdmittedVerification?
}

extension Database {
    fileprivate func verificationContext() throws -> [UInt8] {
        let rows = try rows("SELECT local_store_id,collection_id,bootstrap_descriptor FROM store_header WHERE singleton=1")
        guard rows.count == 1 else { throw StorageError.incomplete }
        let context = try rows[0].flatMap { try $0.bytes }
        guard context.count == 64 else { throw StorageError.integrity }
        return context
    }
    /// Settles only the successful operation whose exact request remains owned.
    fileprivate func settleVerification(_ completed: VerifiedVerification) throws {
        try releaseVerification(completed.admitted)
    }
    /// Removes an exact request after a successful check or a definite candidate outcome.
    fileprivate func releaseVerification(_ admitted: AdmittedVerification) throws {
        try admitted.check(database: self)
        try requireHealthyHistory()
        try transaction {
            let row = try rows("SELECT codec,generation,payload FROM private_groups WHERE group_key=?", [.blob(admitted.record.key)])
            guard row.isEmpty || row == [[.integer(1), .integer(1), .blob(admitted.record.encoded)]] else { throw StorageError.integrity }
            try run("DELETE FROM private_groups WHERE group_key=?", [.blob(admitted.record.key)])
        }
    }
    /// Covers synchronous history checks with one committed request before inspection.
    func verifying<T>(_ recipe: VerificationRecipe, _ body: () throws -> T) throws -> T {
        if let admitted = VerificationScope.current, try admitted.covers(recipe, database: self) { return try body() }
        let admitted = try AdmittedVerification.admit(database: self, recipe: recipe)
        return try VerificationScope.$current.withValue(admitted) {
            do {
                let value = try body()
                try settleVerification(.completed(admitted))
                return value
            } catch {
                if requiredHistoryDamaged { try? recordRequiredHistoryDamage() }
                else if !verificationNeedsRetry(error) { try releaseVerification(admitted) }
                throw error
            }
        }
    }
}

private func verificationNeedsRetry(_ error: any Error) -> Bool {
    if error is CancellationError { return true }
    if let error = error as? StorageError {
        switch error { case .database, .closed, .ownership, .busy: return true; default: break }
    }
    return false
}

extension DatabaseLane {
    /// Enables one bounded replay attempt for a live operation that leaves unfinished checks.
    func enableVerificationReplay(selection: LocalStoreSelection, protection: ObjectProtectionV1) {
        verificationReplayContext = (selection, protection)
    }
    private func resumeVerification(_ admitted: AdmittedVerification) {
        guard let (selection, protection) = verificationReplayContext else { return }
        Task {
            do {
                let hook = try self.perform { $0.work?.verificationReplayWillStart }
                await hook?()
                try await self.replayVerification(admitted.record, selection: selection, protection: protection)
                let finished = try self.perform { $0.work?.verificationReplayFinished }
                await finished?()
            } catch { /* The exact request remains available to the next owned opener. */ }
        }
    }
    /// Captures the existing accepted scope before a logical history operation begins.
    func verifyingHistory<T: Sendable>(isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T) async throws -> T {
        let through = try await perform { try $0.acceptedThrough() }
        if through == 0 {
            guard let root = try await perform({ try $0.stagedBootstrap() }) else { return try await body() }
            return try await verifying(.bootstrap(root), isolation: isolation, body)
        }
        return try await verifying(.history(through), isolation: isolation, body)
    }
    /// Owns a replay request through suspended reads and the final semantic check.
    func verifying<T: Sendable>(_ recipe: VerificationRecipe,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T) async throws -> T {
        if let admitted = VerificationScope.current,
           try await perform({ try admitted.covers(recipe, database: $0) }) {
            return try await body()
        }
        let admitted = try await perform { try AdmittedVerification.admit(database: $0, recipe: recipe) }
        return try await runVerification(admitted, isolation: isolation, body)
    }
    private func runVerification<T: Sendable>(_ admitted: AdmittedVerification,
        isolation: isolated (any Actor)? = #isolation,
        automaticallyRetry: Bool = true,
        _ body: () async throws -> T) async throws -> T {
        try await VerificationScope.$current.withValue(admitted) {
            do {
                let value = try await body()
                try await perform { try $0.settleVerification(.completed(admitted)) }
                return value
            } catch {
                if automaticallyRetry && !verificationNeedsRetry(error) {
                    // A damaged owner keeps its request until the damage marker commits.
                    try? await perform { try $0.releaseVerification(admitted) }
                } else if automaticallyRetry {
                    await resumeVerification(admitted)
                }
                throw error
            }
        }
    }
    /// Replays required private requests before editable publication, reusing their identities.
    nonisolated func replayVerifications(selection: LocalStoreSelection, protection: ObjectProtectionV1) async throws {
        while let record = try await perform({ db -> VerificationRecord? in
            let rows = try db.rows("SELECT group_key,codec,generation,payload FROM private_groups WHERE group_key>=? AND group_key<? ORDER BY group_key LIMIT 1",
                [.blob(VerificationRecord.prefix), .blob(VerificationRecord.end)])
            guard let row = rows.first else { return nil }
            let record = try VerificationRecord.decode(key: row[0].bytes, codec: row[1].number, generation: row[2].number,
                bytes: row[3].bytes, context: db.verificationContext())
            return record
        }) {
            try await replayVerification(record, selection: selection, protection: protection)
        }
    }
    private nonisolated func replayVerification(_ record: VerificationRecord, selection: LocalStoreSelection,
        protection: ObjectProtectionV1) async throws {
        guard let admitted = try await perform({ db -> AdmittedVerification? in
            guard try !db.rows("SELECT 1 FROM private_groups WHERE group_key=?", [.blob(record.key)]).isEmpty else { return nil }
            return try AdmittedVerification.admit(database: db, recipe: record.recipe, existing: record)
        }) else { return }
        try await runVerification(admitted, automaticallyRetry: false) {
                switch admitted.record.recipe {
                case .bootstrap(let root):
                    _ = try await InitialBootstrapValidationV1.validateStored(descriptor: selection.descriptor,
                        expectedCollection: selection.descriptor.collection, protection: protection, snapshot: root) { locator in
                        try await self.perform { try $0.snapshotCandidate(locator, collection: selection.descriptor.collection, protection: protection) }
                    }
                case .object(let locator):
                    try await self.perform { db in
                        guard let (_, object) = try db.acceptedEnvelope(locator, collection: selection.descriptor.collection, protection: protection) else {
                            return try db.checkingRetainedHistory { throw StorageError.incomplete }
                        }
                        _ = try db.checkingRetainedHistory { try ReceivedPayload(object) }
                    }
                case .history(let through):
                    guard try await self.perform({ try $0.acceptedThrough() }) >= through else { throw StorageError.incomplete }
                    let traversal = try await CheckedHistoryTraversal.read(through: through, scope: .allOccurrences, lane: self,
                        selection: selection, protection: protection)
                    let graph = traversal.graph
                    do { _ = try await self.historyWork { try graph.currentCells(collection: selection.descriptor.collection) } }
                    catch { return try await self.perform { db in try db.checkingRetainedHistory { throw error } } }
                    _ = try await self.checkedSnapshotRecords(graph, collection: selection.descriptor.collection)
                    try await self.auditAcceptedSnapshots(traversal, selection: selection, protection: protection)
                }
        }
    }
}
