import Foundation
import CStorageIO
import NVStorageCore

/// Independently recovered components remain available when a required scan prevents complete repair evidence.
public struct PartialPrivateSalvage: Sendable {
    public let workingDirectory: String
    public let componentFailures: [String: StorageError]
    public let readableObjectCount: Int
    public let knownCommittedObjectCount: Int
    fileprivate init(directory: String, failures: [String: StorageError], objects: Int, committed: Int) {
        workingDirectory = directory; componentFailures = failures
        readableObjectCount = objects; knownCommittedObjectCount = committed
    }
}
public enum PrivateSalvageOutcome: Sendable { case complete(PrivateRepairEvidence), partial(PartialPrivateSalvage) }

/// Preserved working-copy evidence separates committed membership from available byte validity.
public struct PrivateRepairEvidence: Sendable {
    public let selection: LocalStoreSelection
    public let workingDirectory: String
    public let unavailableCommittedObjects: Set<[UInt8]>
    fileprivate let accepted: [[SQLValue]]
    fileprivate let objects: [[SQLValue]]
    fileprivate let privateTables: [String: [[SQLValue]]]
    fileprivate let bootstrap: SegmentLocator
    fileprivate let sourceObservation: [UInt64]
    fileprivate init(selection: LocalStoreSelection, workingDirectory: String, accepted: [[SQLValue]], objects: [[SQLValue]],
                     privateTables: [String: [[SQLValue]]], bootstrap: SegmentLocator, missing: Set<[UInt8]>, observation: [UInt64]) {
        self.selection = selection; self.workingDirectory = workingDirectory; self.accepted = accepted
        self.objects = objects; self.privateTables = privateTables; self.bootstrap = bootstrap; unavailableCommittedObjects = missing
        sourceObservation = observation
    }
}

/// A fresh candidate remains owned after normal reopening and complete repair verification.
public struct VerifiedReplacement: Sendable {
    public let selection: LocalStoreSelection
    public let through: Int64
    fileprivate let candidate: LocalStoreSession
    fileprivate let sourceStores: Set<LocalStoreID>
    fileprivate let sources: [PrivateRepairEvidence]
    fileprivate init(candidate: LocalStoreSession, selection: LocalStoreSelection, through: Int64, sources: [PrivateRepairEvidence]) {
        self.candidate = candidate; self.selection = selection; self.through = through; self.sources = sources
        sourceStores = Set(sources.map(\.selection.store))
    }
    /// Releases the verified candidate while preserving its durable evidence for a later retry.
    public func close() async throws { try await candidate.quiesce() }
    /// Holds verified candidate ownership through the independently fenced selection effect.
    public func activate(using owner: SelectedStoreOwner, basedOn state: SelectedStoreState) async throws -> StoreActivationOutcome {
        try await candidate.reserveActivation(through: through)
        do {
            guard let association = try await candidate.localAssociation().value else { throw StorageError.incomplete }
            let input = VerifiedActivationInput(candidate: selection, association: association.id,
                sources: sources.map { ActivationSource(selection: $0.selection, observation: $0.sourceObservation) })
            let outcome = try await owner.install(input, basedOn: state)
            await candidate.settleActivation()
            return outcome
        } catch { await candidate.settleActivation(); throw error }
    }
}

struct ActivationSource: Sendable {
    let selection: LocalStoreSelection
    let observation: [UInt64]
    fileprivate init(selection: LocalStoreSelection, observation: [UInt64]) { self.selection = selection; self.observation = observation }
}

/// Fresh reopening and the candidate's live reservation issue the selection consumer's input.
struct VerifiedActivationInput: Sendable {
    let candidate: LocalStoreSelection
    let association: LocalAssociationID
    let sources: [ActivationSource]
    fileprivate init(candidate: LocalStoreSelection, association: LocalAssociationID, sources: [ActivationSource]) {
        self.candidate = candidate; self.association = association; self.sources = sources
    }
}

private let repairPrivateQueries: [String: String] = [
    "private_groups": "SELECT group_key,generation,codec,payload FROM private_groups ORDER BY group_key",
    "object_waits": "SELECT child,prerequisite FROM object_waits ORDER BY child,prerequisite",
    "ready_objects": "SELECT object_id FROM ready_objects ORDER BY object_id",
    "rejected_objects": "SELECT object_id,validator_version,reason FROM rejected_objects ORDER BY object_id"
]

/// Copies under physical exclusion before any keyed recovery writes touch the working evidence.
private actor RepairReader {
    nonisolated private let executor = StorageExecutor(label: "org.notationalvelocity.storage.repair-copy", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { unsafe executor.asUnownedSerialExecutor() }
    func preserve(source: String, destination: String) throws -> [UInt64] {
        guard !source.utf8.contains(0), !destination.utf8.contains(0) else { throw StorageError.wrongContext }
        var observation = [UInt64](repeating: 0, count: 25)
        let rc = observation.withUnsafeMutableBufferPointer { unsafe nv_storage_preserve_copy(source, destination, $0.baseAddress) }
        guard rc == 0 else { throw StorageError.ownership(errno) }
        return observation
    }
}

extension LocalStoreSession {
    /// Stops owned connections without maintenance, then retains the original and its journals unchanged.
    public func preserveForRepair(to directory: String) async throws -> PrivateRepairEvidence {
        try await closeForPreservedRepair()
        return try await Self.salvagePrivateStore(selection: selection, protection: protection, workingDirectory: directory)
    }

    /// Independent SQL reads use fresh keyed connections after every component/page failure.
    public static func salvagePrivateStore(selection: LocalStoreSelection, protection: ObjectProtectionV1,
                                           workingDirectory: String) async throws -> PrivateRepairEvidence {
        switch try await salvagePrivateStoreDiagnosing(selection: selection, protection: protection, workingDirectory: workingDirectory) {
        case .complete(let evidence): return evidence
        case .partial: throw StorageError.incomplete
        }
    }

    /// Continues independent component and known-object reads after a failed scan, preserving a scoped partial result.
    public static func salvagePrivateStoreDiagnosing(selection: LocalStoreSelection, protection: ObjectProtectionV1,
        workingDirectory: String) async throws -> PrivateSalvageOutcome {
        let worker = RepairReader()
        let observation = try await worker.preserve(source: selection.directory, destination: workingDirectory)
        let working = LocalStoreSelection(directory: workingDirectory, store: selection.store, descriptor: selection.descriptor)
        func read(_ sql: String, _ args: [SQLValue] = []) async throws -> [[SQLValue]] {
            let lane = DatabaseLane()
            try await lane.open(directory: workingDirectory, create: false,
                key: PrivateDatabaseKeyV1.derive(collection: selection.descriptor.collection, protection: protection))
            do {
                let result = try await lane.perform { db in
                    let h = try db.rows("SELECT local_store_id,collection_id,bootstrap_descriptor,genesis_locator FROM store_header WHERE singleton=1")
                    guard h == [[.blob(working.store.bytes), .blob(working.descriptor.collection.bytes),
                                 .blob(working.descriptor.descriptorID), .blob(working.descriptor.genesis.encodedV1())]] else { throw StorageError.wrongContext }
                    return try db.rows(sql, args)
                }
                await lane.close(); return result
            } catch { await lane.close(); throw error }
        }
        var tables: [String: [[SQLValue]]] = [:], failures: [String: StorageError] = [:]
        var queries = repairPrivateQueries.merging(pendingPrivateQueries) { existing, _ in existing }
        queries["accepted_membership"] = "SELECT object_id,seq FROM accepted_objects ORDER BY object_id"
        queries["retained_pin"] = "SELECT object_id,locator FROM retained_frontier ORDER BY object_id"
        queries["bootstrap_root"] = "SELECT codec,payload FROM private_groups WHERE group_key=X'626f6f747374726170'"
        queries["available_catalog"] = "SELECT object_id FROM objects ORDER BY object_id"
        for (name, query) in queries.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            do { tables[name] = try await read(query) } catch { failures[name] = classify(error) }
        }
        let accepted = tables["accepted_membership"] ?? [], pin = tables["retained_pin"] ?? [], root = tables["bootstrap_root"] ?? []
        let bootstrap: SegmentLocator?
        if root.count == 1, root[0][0] == .integer(1) {
            do { bootstrap = try SegmentLocator.decodeV1(root[0][1].bytes) }
            catch { bootstrap = nil; failures["bootstrap_root"] = classify(error) }
        } else { bootstrap = nil; failures["bootstrap_root"] = .incomplete }
        if accepted.isEmpty { failures["accepted_membership"] = failures["accepted_membership"] ?? .incomplete }
        if pin.isEmpty { failures["retained_pin"] = failures["retained_pin"] ?? .incomplete }
        do {
            for row in pin {
                let locator = try SegmentLocator.decodeV1(row[1].bytes)
                guard locator.segmentID.bytes == (try row[0].bytes) else { throw StorageError.integrity }
            }
        } catch { failures["retained_pin"] = classify(error) }
        var ids = try Set(accepted.map { try $0[0].bytes })
        for name in ["object_waits", "ready_objects", "rejected_objects", "available_catalog"] {
            for row in tables[name] ?? [] { ids.insert(try row[0].bytes) }
        }
        var objects: [[SQLValue]] = [], missing: Set<[UInt8]> = []
        for id in ids.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            try Task.checkCancellation()
            do {
                guard let row = try await read("SELECT object_id,kind,writer_epoch,sequence,encoded FROM objects WHERE object_id=?", [.blob(id)]).first else {
                    missing.insert(id); continue
                }
                if row[1] == .integer(0) {
                    let d = try BootstrapDescriptorV1.decodeV1(row[4].bytes)
                    guard d.descriptorID == id, d.collection == selection.descriptor.collection, d.genesis == selection.descriptor.genesis,
                          d.keyID == selection.descriptor.keyID else { throw StorageError.integrity }
                } else {
                    let opened = try ObjectEnvelopeV1.open(row[4].bytes, collection: selection.descriptor.collection, protection: protection)
                    guard opened.locator.segmentID.bytes == id, row[1] == .integer(Int64(opened.kind.rawValue)),
                          row[2] == .blob(opened.locator.writerEpoch.bytes), row[3] == .blob(Array(opened.locator.encodedV1()[16..<24])) else { throw StorageError.integrity }
                }
                objects.append(row)
            } catch { missing.insert(id) }
        }
        let required = try Set(accepted.map { try $0[0].bytes })
        if let bootstrap, try pin.allSatisfy({ required.contains(try $0[0].bytes) }), required.contains(bootstrap.segmentID.bytes), failures.isEmpty {
            return .complete(PrivateRepairEvidence(selection: selection, workingDirectory: workingDirectory, accepted: accepted, objects: objects,
                privateTables: tables, bootstrap: bootstrap, missing: missing.intersection(required), observation: observation))
        }
        if failures.isEmpty { failures["required_closure"] = .incomplete }
        return .partial(PartialPrivateSalvage(directory: workingDirectory, failures: failures, objects: objects.count, committed: accepted.count))
    }

    /// Reaccepts the union through ordinary validators, preserving source scope instead of copying local sequence numbers.
    public static func buildVerifiedReplacement(to directory: String, primary: PrivateRepairEvidence,
        complementary: [PrivateRepairEvidence] = [], protection: ObjectProtectionV1) async throws -> VerifiedReplacement {
        let sources = [primary] + complementary, descriptor = primary.selection.descriptor
        guard sources.allSatisfy({ $0.selection.descriptor.collection == descriptor.collection && $0.selection.descriptor.genesis == descriptor.genesis
            && $0.selection.descriptor.keyID == descriptor.keyID && $0.bootstrap == primary.bootstrap }) else { throw StorageError.wrongContext }
        var objects: [[UInt8]: [SQLValue]] = [:], required: Set<[UInt8]> = []
        for source in sources {
            for row in source.accepted { required.insert(try row[0].bytes) }
            for row in source.objects {
                let id = try row[0].bytes
                guard objects[id] == nil || objects[id] == row else { throw StorageError.integrity }
                objects[id] = row
            }
        }
        guard required.isSubset(of: Set(objects.keys)) else { throw StorageError.incomplete }
        let selection = try LocalStoreSelection(directory: directory, store: LocalStoreID(bytes: uuidBytes()), descriptor: descriptor)
        let candidate = try await BootstrapCandidate.create(selection: selection, snapshot: primary.bootstrap, protection: protection)
        var session: LocalStoreSession?
        do {
            for (id, row) in objects where required.contains(id) && row[1] != .integer(0) { _ = try await candidate.retain(row[4].bytes) }
            let completed = try await candidate.complete(snapshot: primary.bootstrap); session = completed
            for id in required.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                guard let row = objects[id] else { throw StorageError.incomplete }
                if row[1] == .integer(0) {
                    let d = try BootstrapDescriptorV1.decodeV1(row[4].bytes)
                    if d.descriptorID != descriptor.descriptorID {
                        try await completed.lane.perform { db in
                            try db.transaction {
                                let seq = try db.acceptedThrough() + 1
                                try db.run("INSERT INTO acceptance_batches VALUES(?)", [.integer(seq)])
                                try db.run("INSERT INTO objects VALUES(?,?,?,?,?)", row)
                                try db.run("INSERT INTO accepted_objects VALUES(?,?)", [.blob(d.descriptorID), .integer(seq)])
                                try db.run("INSERT INTO retained_descriptors VALUES(?)", [.blob(d.descriptorID)])
                                try db.run("INSERT INTO accepted_dependencies VALUES(?,?)", [.blob(d.descriptorID), .blob(d.genesis.segmentID.bytes)])
                            }
                        }
                    }
                } else { _ = try await completed.receive(row[4].bytes) }
            }
            try await completed.lane.perform { [required] db in
                for id in required {
                    guard try !db.rows("SELECT 1 FROM accepted_objects WHERE object_id=?", [.blob(id)]).isEmpty else { throw StorageError.incomplete }
                }
            }
            try await completed.verifyCompletePrivateState()
            try await completed.installRepairPrivateState(primary: primary, sources: sources, objects: objects, required: required)
            try await completed.lane.catchUp(selection: selection, protection: protection)
            try await completed.verifyCompletePrivateState()
            try await completed.lane.perform { try $0.installUnlockDescriptor(descriptor) }
            try await completed.quiesce(); session = nil
            let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
            session = reopened
            try await reopened.verifyCompletePrivateState()
            let through = try await reopened.snapshot().through
            session = nil
            return VerifiedReplacement(candidate: reopened, selection: selection, through: through, sources: sources)
        } catch { try? await session?.quiesce(); try? await candidate.close(); throw error }
    }

    private func installRepairPrivateState(primary: PrivateRepairEvidence, sources: [PrivateRepairEvidence],
        objects: [[UInt8]: [SQLValue]], required: Set<[UInt8]>) async throws {
        let selection = selection, protection = protection
        try await lane.perform { db in
            let groups = primary.privateTables["private_groups"] ?? []
            guard let settings = groups.first(where: { $0[0] == .blob(Array("settings".utf8)) }) else { throw StorageError.incomplete }
            _ = try db.decodedSettings(Array(settings.dropFirst()))
            for source in sources {
                let old = source.selection
                for group in source.privateTables["private_groups"] ?? [] where (try group[0].bytes).starts(with: VerificationRecord.prefix) {
                    let record = try VerificationRecord.decode(key: group[0].bytes, codec: group[2].number, generation: group[1].number,
                        bytes: group[3].bytes, context: old.store.bytes + old.descriptor.collection.bytes + old.descriptor.descriptorID)
                    switch record.recipe {
                    case .history(let n):
                        let scope = try source.accepted.filter { try $0[1].number <= n }
                        guard n > 0, n <= (try source.accepted.map { try $0[1].number }.max() ?? 0),
                              try scope.allSatisfy({ required.contains(try $0[0].bytes) }) else { throw StorageError.incomplete }
                    case .bootstrap(let root): guard root == source.bootstrap else { throw StorageError.incomplete }
                    case .object(let loc):
                        guard let row = objects[loc.segmentID.bytes], row[1] != .integer(0),
                              row[2] == .blob(loc.writerEpoch.bytes), row[3] == .blob(Array(loc.encodedV1()[16..<24])) else { throw StorageError.incomplete }
                    }
                }
            }
            try db.transaction {
                // Available uncommitted bytes retain their original scheduling class independently of accepted intent.
                for (id, row) in objects where !required.contains(id) {
                    guard row[1] != .integer(0) else { continue }
                    let opened = try ObjectEnvelopeV1.open(row[4].bytes, collection: selection.descriptor.collection, protection: protection)
                    try db.retainCandidate(row[4].bytes, opened: opened, ready: false)
                }
                for source in sources {
                    let old = source.selection
                    try db.run("INSERT INTO private_groups VALUES(?,1,1,?) ON CONFLICT(group_key) DO NOTHING",
                        [.blob(Array("repair-source/".utf8) + old.store.bytes), .blob(old.descriptor.collection.bytes + old.descriptor.descriptorID)])
                }
                for group in groups {
                    let key = try group[0].bytes
                    if key == Array("bootstrap".utf8) || key == Array("history-damage".utf8) || key.starts(with: VerificationRecord.prefix) { continue }
                    var row = group
                    if key == Array("association".utf8) {
                        let old = try db.decodedAssociation(Array(group.dropFirst()), selection: primary.selection)
                        let new = try LocalAssociationV1(id: old.id, scope: PrivateRecordScopeV1(collection: selection.descriptor.collection,
                            store: selection.store, descriptor: selection.descriptor.descriptorID), bookmark: old.bookmark)
                        row[3] = .blob(new.encodedV1())
                    }
                    try db.run("INSERT INTO private_groups VALUES(?,?,?,?) ON CONFLICT(group_key) DO UPDATE SET generation=excluded.generation,codec=excluded.codec,payload=excluded.payload", row)
                }
                if try db.privateGroup("association") == nil {
                    let association = try LocalAssociationV1(id: LocalAssociationID(bytes: uuidBytes()),
                        scope: PrivateRecordScopeV1(collection: selection.descriptor.collection, store: selection.store,
                            descriptor: selection.descriptor.descriptorID), bookmark: PassivePlatformRecordV1(codec: 1, bytes: []))
                    try db.run("INSERT INTO private_groups VALUES(?,1,1,?)", [.blob(Array("association".utf8)), .blob(association.encodedV1())])
                }
                for name in ["pending_payloads", "pending_items", "pending_reservations", "pending_settlements"] {
                    var records: [[UInt8]: [SQLValue]] = [:]
                    for source in sources {
                        for row in source.privateTables[name] ?? [] {
                            let keyCount = name == "pending_settlements" ? 2 : 1
                            let key = try row.prefix(keyCount).flatMap { try $0.bytes }
                            if let prior = records[key] {
                                guard prior == row else { throw StorageError.incomplete }
                            } else { records[key] = row }
                        }
                    }
                    for row in records.values {
                        let parameters = Array(repeating: "?", count: row.count).joined(separator: ",")
                        try db.run("INSERT INTO \(name) VALUES(\(parameters))", row)
                    }
                }
                var rejected: [[UInt8]: [SQLValue]] = [:]
                for source in sources {
                    for row in source.privateTables["rejected_objects"] ?? [] {
                        let id = try row[0].bytes
                        guard objects[id] != nil else { throw StorageError.incomplete }
                        if required.contains(id) { continue }
                        guard rejected[id] == nil || rejected[id] == row else { throw StorageError.incomplete }
                        rejected[id] = row
                    }
                }
                for row in rejected.values { try db.run("INSERT INTO rejected_objects VALUES(?,?,?)", row) }
                for source in sources {
                    for row in source.privateTables["object_waits"] ?? [] {
                        let id = try row[0].bytes
                        guard objects[id] != nil else { throw StorageError.incomplete }
                        if required.contains(id) || rejected[id] != nil { continue }
                        if try db.rows("SELECT 1 FROM accepted_objects WHERE object_id=?", [row[1]]).isEmpty {
                            try db.run("INSERT INTO object_waits VALUES(?,?) ON CONFLICT DO NOTHING", row)
                        }
                        try db.run("INSERT INTO ready_objects VALUES(?) ON CONFLICT DO NOTHING", [row[0]])
                    }
                    for row in source.privateTables["ready_objects"] ?? [] {
                        let id = try row[0].bytes
                        guard objects[id] != nil else { throw StorageError.incomplete }
                        if required.contains(id) || rejected[id] != nil { continue }
                        try db.run("INSERT INTO ready_objects VALUES(?) ON CONFLICT DO NOTHING", row)
                    }
                }
            }
        }
    }
}
