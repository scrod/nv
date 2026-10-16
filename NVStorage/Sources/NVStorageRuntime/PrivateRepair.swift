import Foundation
import Crypto
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

/// Selection durability and integrated ownership settle independently after sibling repair.
public enum CollectionPrivateRepairOutcome: Sendable {
    case opened(CollectionSession, selected: SelectedStoreState)
    case activationPending(VerifiedReplacement, StoreActivationOutcome)
    case activatedNeedsReopen(LocalStoreSelection, selected: SelectedStoreState, cause: StorageError)
}

/// Owns a verified independent private copy while its original source remains editable.
struct PreparedPrivateStoreCopy: Sendable {
    let selection: LocalStoreSelection
    let through: Int64
    fileprivate let candidate: LocalStoreSession
    fileprivate let backup: CapturedPrivateBackup
    fileprivate init(candidate: LocalStoreSession, through: Int64, backup: CapturedPrivateBackup) {
        self.candidate = candidate; selection = candidate.selection; self.through = through; self.backup = backup
    }
    func checkSource(_ source: LocalStoreSession) async throws { try await source.checkBackupSource(backup) }
    func close() async throws { try await candidate.quiesce() }
    func copyRepository(from root: RepositoryRootSession?, to destination: String,
        captured: (@Sendable (String) async -> Void)?) async throws -> ActiveRepositoryCopy {
        try await candidate.copyRepositoryAndSavedWork(from: root, to: destination, captured: captured)
    }
    func bindDestination(_ root: RepositoryRootSession) async throws {
        try await candidate.verifyCopiedHistory(at: root, through: through)
        let before = try await candidate.localAssociation()
        guard let prior = before.value else { throw StorageError.incomplete }
        let value = try await root.association(for: selection, id: prior.id)
        try await candidate.saveLocalAssociation(value, basedOn: before)
        guard try await root.matches(value) == .same else { throw StorageError.wrongContext }
    }
    /// Only a checked, retired source can authorize replacement of its selected identity.
    func retireSource(_ source: LocalStoreSession, destination: RepositoryRootSession) async throws -> VerifiedReplacement {
        guard let association = try await candidate.localAssociation().value,
              try await destination.matches(association) == .same else { throw StorageError.wrongContext }
        let original = source.selection
        let observation = try await source.retireForCopy(backup)
        return VerifiedReplacement(candidate: candidate, selection: selection, through: through,
            sources: [ActivationSource(selection: original, observation: observation)])
    }
}

/// Preserved working-copy evidence separates committed membership from available byte validity.
public struct PrivateRepairEvidence: Sendable {
    public let selection: LocalStoreSelection
    public let workingDirectory: String
    public let unavailableCommittedObjects: Set<[UInt8]>
    fileprivate let accepted: [[SQLValue]]
    fileprivate let objects: [RepairObjectReference]
    fileprivate let privateTables: [String: [[SQLValue]]]
    fileprivate let bootstrap: SegmentLocator
    fileprivate let sourceObservation: [UInt64]
    fileprivate init(selection: LocalStoreSelection, workingDirectory: String, accepted: [[SQLValue]], objects: [RepairObjectReference],
                     privateTables: [String: [[SQLValue]]], bootstrap: SegmentLocator, missing: Set<[UInt8]>, observation: [UInt64]) {
        self.selection = selection; self.workingDirectory = workingDirectory; self.accepted = accepted
        self.objects = objects; self.privateTables = privateTables; self.bootstrap = bootstrap; unavailableCommittedObjects = missing
        sourceObservation = observation
    }
}

/// Binds one validated envelope to its exact metadata and bytes for later bounded reads.
fileprivate struct RepairObjectReference: Sendable, Equatable {
    let metadata: [SQLValue]
    let path: String
    let byteCount: Int
    let digest: [UInt8]
    var id: [UInt8] { get throws { try metadata[0].bytes } }
    fileprivate init(row: [SQLValue], descriptor: BootstrapDescriptorV1, protection: ObjectProtectionV1) throws {
        guard row.count == 5 else { throw StorageError.integrity }
        let bytes = try row[4].bytes, id = try row[0].bytes
        if row[1] == .integer(0) {
            let decoded = try BootstrapDescriptorV1.decodeV1(bytes)
            guard decoded.descriptorID == id, decoded.collection == descriptor.collection,
                  decoded.genesis == descriptor.genesis, decoded.keyID == descriptor.keyID,
                  row[2] == .null, row[3] == .null else { throw StorageError.integrity }
            path = ImmutableRepositoryLocator.descriptor(decoded).relativePath
        } else {
            let opened = try ObjectEnvelopeV1.open(bytes, collection: descriptor.collection, protection: protection)
            guard opened.locator.segmentID.bytes == id, row[1] == .integer(Int64(opened.kind.rawValue)),
                  row[2] == .blob(opened.locator.writerEpoch.bytes),
                  row[3] == .blob(Array(opened.locator.encodedV1()[16..<24])) else { throw StorageError.integrity }
            path = ImmutableRepositoryLocator.segment(opened.locator).relativePath
        }
        metadata = Array(row.prefix(4)); byteCount = bytes.count; digest = Array(SHA256.hash(data: bytes))
    }
    func check(_ row: [SQLValue]) throws {
        guard row.count == 5, Array(row.prefix(4)) == metadata else { throw StorageError.integrity }
        let bytes = try row[4].bytes
        guard bytes.count == byteCount, Array(SHA256.hash(data: bytes)) == digest else { throw StorageError.integrity }
    }
}

private let repairObjectQuery = "SELECT object_id,kind,writer_epoch,sequence,CASE WHEN length(encoded)<=\(ObjectLimitsV1.encodedPayloadBytes + 156) THEN encoded ELSE NULL END FROM objects WHERE object_id=?"

/// Selects the preserved source for a checked inventory entry.
private enum RepairObjectSource: Sendable {
    case privateStore(PrivateRepairEvidence)
    case repository(RepositoryRepairReader)

    func read(_ reference: RepairObjectReference, protection: ObjectProtectionV1) async throws -> [SQLValue] {
        try Task.checkCancellation()
        let row: [SQLValue]
        switch self {
        case .privateStore(let evidence):
            guard let found = try await readRepairRows(selection: evidence.selection, directory: evidence.workingDirectory,
                protection: protection, sql: repairObjectQuery,
                args: [.blob(reference.id)]).first else { throw StorageError.incomplete }
            row = found
        case .repository(let reader): row = try await reader.reread(reference.path, descriptor: reference.metadata[1] == .integer(0))
        }
        try reference.check(row)
        return row
    }
}

/// Isolates damaged-page failures while checking the working copy's original collection context.
private func readRepairRows(selection: LocalStoreSelection, directory: String, protection: ObjectProtectionV1,
    sql: String, args: [SQLValue] = []) async throws -> [[SQLValue]] {
    let lane = DatabaseLane()
    try await lane.open(directory: directory, create: false,
        key: PrivateDatabaseKeyV1.derive(collection: selection.descriptor.collection, protection: protection))
    do {
        let result = try await lane.perform { db in
            let header = try db.rows("SELECT local_store_id,collection_id,bootstrap_descriptor,genesis_locator FROM store_header WHERE singleton=1")
            guard header == [[.blob(selection.store.bytes), .blob(selection.descriptor.collection.bytes),
                .blob(selection.descriptor.descriptorID), .blob(selection.descriptor.genesis.encodedV1())]] else { throw StorageError.wrongContext }
            return try db.rows(sql, args)
        }
        await lane.close(); return result
    } catch { await lane.close(); throw error }
}

/// Qualification observes inventory preparation and each bounded source read independently.
struct PrivateRepairWork: Sendable {
    var prepared: (@Sendable () async throws -> Void)?
    var read: (@Sendable ([UInt8], Int) async throws -> Void)?
}

/// A fresh candidate remains owned after normal reopening and complete repair verification.
public struct VerifiedReplacement: Sendable {
    public let selection: LocalStoreSelection
    public let through: Int64
    public let repositoryIssues: [RepositoryRepairSourceIssue]
    fileprivate let candidate: LocalStoreSession
    fileprivate let sources: [ActivationSource]
    fileprivate init(candidate: LocalStoreSession, selection: LocalStoreSelection, through: Int64, sources: [ActivationSource],
                     repositoryIssues: [RepositoryRepairSourceIssue] = []) {
        self.candidate = candidate; self.selection = selection; self.through = through; self.sources = sources
        self.repositoryIssues = repositoryIssues
    }
    /// Releases the verified candidate while preserving its durable evidence for a later retry.
    public func close() async throws { try await candidate.quiesce() }
    func adopt(repository: RepositoryRootSession) async throws -> CollectionSession {
        try await CollectionSession.bindRepaired(candidate, root: repository)
    }
    /// Holds verified candidate ownership through the independently fenced selection effect.
    public func activate(using owner: SelectedStoreOwner, basedOn state: SelectedStoreState) async throws -> StoreActivationOutcome {
        try await withActivationInput { try await owner.install($0, basedOn: state) }
    }
    /// Finishes the existing selection attempt through its retained physical handles and barriers.
    public func resumeActivation(using owner: SelectedStoreOwner) async throws -> StoreActivationOutcome {
        try await withActivationInput { try await owner.resume($0) }
    }
    private func withActivationInput(_ body: (VerifiedActivationInput) async throws -> StoreActivationOutcome) async throws -> StoreActivationOutcome {
        try await candidate.reserveActivation(through: through)
        do {
            guard let association = try await candidate.localAssociation().value else { throw StorageError.incomplete }
            let input = VerifiedActivationInput(candidate: selection, association: association.id,
                sources: sources)
            let outcome = try await body(input)
            await candidate.settleActivation()
            return outcome
        } catch { await candidate.settleActivation(); throw error }
    }
}

extension CollectionSession {
    /// Resumes an ambiguous selection barrier and adopts the verified owner after durable completion.
    public static func resumePrivateRepair(_ replacement: VerifiedReplacement, repository: URL? = nil,
        using selectionOwner: SelectedStoreOwner) async throws -> CollectionPrivateRepairOutcome {
        var root: RepositoryRootSession?
        do {
            if let repository {
                let opened = try await RepositoryRootSession.open(directory: repository)
                root = opened
                guard let association = try await replacement.candidate.localAssociation().value,
                      try await opened.matches(association) == .same else { throw StorageError.wrongContext }
            }
            let outcome = try await replacement.resumeActivation(using: selectionOwner)
            return await finishPrivateRepair(replacement, outcome: outcome, root: root)
        } catch { await root?.close(); throw error }
    }

    /// Combines preserved private evidence with an owned repository before checked selection activation.
    public static func repairPrivateStore(primary: PrivateRepairEvidence,
        complementary: [PrivateRepairEvidence] = [], repository: URL? = nil,
        to directory: String, protection: ObjectProtectionV1,
        using selectionOwner: SelectedStoreOwner, basedOn selected: SelectedStoreState) async throws -> CollectionPrivateRepairOutcome {
        guard selected.record?.store == primary.selection.store else { throw StorageError.wrongContext }
        var root: RepositoryRootSession?
        var replacement: VerifiedReplacement?
        do {
            var inputs: [RepositoryRepairSource] = []
            if let repository {
                let opened = try await RepositoryRootSession.open(directory: repository)
                root = opened
                inputs = [try await opened.repairSource(for: primary.selection.descriptor)]
            }
            let rebuilt = try await LocalStoreSession.buildVerifiedReplacement(to: directory, primary: primary,
                complementary: complementary, repositories: inputs, protection: protection)
            replacement = rebuilt
            if let root {
                guard let association = try await rebuilt.candidate.localAssociation().value,
                      try await root.matches(association) == .same else { throw StorageError.wrongContext }
            }
            let outcome = try await rebuilt.activate(using: selectionOwner, basedOn: selected)
            let result = await finishPrivateRepair(rebuilt, outcome: outcome, root: root)
            root = nil; replacement = nil
            return result
        } catch {
            try? await replacement?.close()
            await root?.close()
            throw error
        }
    }

    static func finishPrivateRepair(_ replacement: VerifiedReplacement, outcome: StoreActivationOutcome,
        root: RepositoryRootSession?) async -> CollectionPrivateRepairOutcome {
        switch outcome {
        case .activated(let state):
            do { return try await .opened(bindRepaired(replacement.candidate, root: root), selected: state) }
            catch {
                await root?.close(); try? await replacement.close()
                return .activatedNeedsReopen(replacement.selection, selected: state, cause: classify(error))
            }
        case .unchanged, .uncertain:
            await root?.close()
            return .activationPending(replacement, outcome)
        }
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
    /// Verifies a fixed backup before assigning independent private ownership and capture provenance.
    func preparePrivateStoreCopy(to directory: String, budget: PrivateBackupBudget? = nil) async throws -> PreparedPrivateStoreCopy {
        let backup = try await capturedPrivateBackup(to: directory, budget: budget)
        let original = backup.result.selection
        let copied = LocalStoreSelection(directory: directory, store: try LocalStoreID(bytes: uuidBytes()),
                                         descriptor: selection.descriptor)
        let lane = DatabaseLane()
        do {
            try await lane.open(directory: directory, create: false,
                key: PrivateDatabaseKeyV1.derive(collection: copied.descriptor.collection, protection: protection))
            try await lane.perform { db in
                try db.validateHeader(store: original.store, descriptor: original.descriptor)
                guard let association = try db.privateGroup("association") else { throw StorageError.incomplete }
                let old = try db.decodedAssociation(association, selection: original)
                let rebound = try LocalAssociationV1(id: old.id,
                    scope: .init(collection: copied.descriptor.collection, store: copied.store,
                                 descriptor: copied.descriptor.descriptorID), bookmark: old.bookmark)
                try db.transaction {
                    try db.run("UPDATE store_header SET local_store_id=? WHERE singleton=1", [.blob(copied.store.bytes)])
                    try db.run("INSERT INTO private_groups VALUES(?,1,1,?) ON CONFLICT(group_key) DO NOTHING",
                        [.blob(Array("repair-source/".utf8) + original.store.bytes),
                         .blob(original.descriptor.collection.bytes + original.descriptor.descriptorID)])
                    try db.replacePrivateGroup("association", generation: association[0].number, codec: 1, bytes: rebound.encodedV1())
                }
            }
            await lane.close()
        } catch { await lane.close(); throw error }
        let reopened = try await LocalStoreSession.open(selection: copied, protection: protection)
        do {
            try await reopened.verifyCompletePrivateState()
            return try await PreparedPrivateStoreCopy(candidate: reopened, through: reopened.snapshot().through, backup: backup)
        } catch { try? await reopened.quiesce(); throw error }
    }

    /// Normal owned opening, required state and a current capture issue fresh-selection activation evidence.
    func verifiedFreshSelection() async throws -> VerifiedReplacement {
        let selection = selection
        try await lane.perform { db in
            try db.requireHealthyHistory()
            try db.validateRequiredPrivateGroups(store: selection.store, descriptor: selection.descriptor)
        }
        let snapshot = try await snapshot()
        guard try await localAssociation().value != nil else { throw StorageError.incomplete }
        return VerifiedReplacement(candidate: self, selection: selection, through: snapshot.through, sources: [])
    }

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
        func read(_ sql: String, _ args: [SQLValue] = []) async throws -> [[SQLValue]] {
            try await readRepairRows(selection: selection, directory: workingDirectory, protection: protection, sql: sql, args: args)
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
        var objects: [RepairObjectReference] = [], missing: Set<[UInt8]> = []
        for id in ids.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            try Task.checkCancellation()
            do {
                guard let row = try await read(repairObjectQuery, [.blob(id)]).first else {
                    missing.insert(id); continue
                }
                guard try row[0].bytes == id else { throw StorageError.integrity }
                objects.append(try RepairObjectReference(row: row, descriptor: selection.descriptor, protection: protection))
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
        complementary: [PrivateRepairEvidence] = [], repositories: [RepositoryRepairSource] = [],
        protection: ObjectProtectionV1) async throws -> VerifiedReplacement {
        try await buildVerifiedReplacement(to: directory, primary: primary, complementary: complementary,
            repositories: repositories, protection: protection, work: nil)
    }

    static func buildVerifiedReplacement(to directory: String, primary: PrivateRepairEvidence,
        complementary: [PrivateRepairEvidence] = [], repositories: [RepositoryRepairSource] = [],
        protection: ObjectProtectionV1, work: PrivateRepairWork?) async throws -> VerifiedReplacement {
        let sources = [primary] + complementary, descriptor = primary.selection.descriptor
        guard sources.allSatisfy({ $0.selection.descriptor.collection == descriptor.collection && $0.selection.descriptor.genesis == descriptor.genesis
            && $0.selection.descriptor.keyID == descriptor.keyID && $0.bootstrap == primary.bootstrap }) else { throw StorageError.wrongContext }
        var objects: [[UInt8]: RepairObjectReference] = [:], origins: [[UInt8]: RepairObjectSource] = [:], required: Set<[UInt8]> = []
        for source in sources {
            for row in source.accepted { required.insert(try row[0].bytes) }
            for reference in source.objects {
                let id = try reference.id
                guard objects[id] == nil || objects[id] == reference else { throw StorageError.integrity }
                objects[id] = reference
                origins[id] = .privateStore(source)
            }
        }
        var repositoryIssues: [RepositoryRepairSourceIssue] = []
        for (index, repository) in repositories.enumerated() {
            let missing = required.subtracting(objects.keys)
            let reader = try RepositoryRepairReader(source: repository, descriptor: descriptor, protection: protection, missing: missing, sourceIndex: index)
            do {
                if !missing.isEmpty {
                    while let row = try await reader.next() {
                        let reference = try RepairObjectReference(row: row, descriptor: descriptor, protection: protection), id = try reference.id
                        guard objects[id] == nil || objects[id] == reference else { throw StorageError.integrity }
                        objects[id] = reference
                        origins[id] = .repository(reader)
                    }
                }
                try await reader.close()
                repositoryIssues += await reader.issues
            } catch { try? await reader.close(); throw error }
        }
        guard required.isSubset(of: Set(objects.keys)) else { throw repositoryIssues.first?.error ?? StorageError.incomplete }
        try await work?.prepared?()
        func read(_ id: [UInt8]) async throws -> [SQLValue] {
            guard let reference = objects[id], let source = origins[id] else { throw StorageError.incomplete }
            let row = try await source.read(reference, protection: protection)
            try await work?.read?(id, row[4].bytes.count)
            return row
        }
        let selection = try LocalStoreSelection(directory: directory, store: LocalStoreID(bytes: uuidBytes()), descriptor: descriptor)
        let candidate = try await BootstrapCandidate.create(selection: selection, snapshot: primary.bootstrap, protection: protection)
        var session: LocalStoreSession?
        do {
            for (id, reference) in objects where required.contains(id) && reference.metadata[1] != .integer(0) {
                _ = try await candidate.retain(read(id)[4].bytes)
            }
            let completed = try await candidate.complete(snapshot: primary.bootstrap); session = completed
            for id in required.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                let row = try await read(id)
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
            for (id, reference) in objects where !required.contains(id) && reference.metadata[1] != .integer(0) {
                let bytes = try await read(id)[4].bytes
                let opened = try ObjectEnvelopeV1.open(bytes, collection: descriptor.collection, protection: protection)
                try await completed.lane.perform { db in
                    try db.transaction { try db.retainCandidate(bytes, opened: opened, ready: false) }
                }
            }
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
            return VerifiedReplacement(candidate: reopened, selection: selection, through: through,
                sources: sources.map { ActivationSource(selection: $0.selection, observation: $0.sourceObservation) },
                repositoryIssues: repositoryIssues)
        } catch { try? await session?.quiesce(); try? await candidate.close(); throw error }
    }

    private func installRepairPrivateState(primary: PrivateRepairEvidence, sources: [PrivateRepairEvidence],
        objects: [[UInt8]: RepairObjectReference], required: Set<[UInt8]>) async throws {
        let selection = selection
        try await lane.perform { db in
            var groups = primary.privateTables["private_groups"] ?? []
            for source in sources {
                for group in source.privateTables["private_groups"] ?? [] {
                    let key = try group[0].bytes
                    guard key.starts(with: Array("projection/".utf8)) || key.starts(with: Array("projection-data/".utf8)) ||
                          key.starts(with: Array("projection-replacement/".utf8)) ||
                          key.starts(with: Array("projection-source/".utf8)) else { continue }
                    if let prior = groups.first(where: { $0[0] == group[0] }) {
                        guard prior == group else { throw StorageError.incomplete }
                    } else { groups.append(group) }
                }
            }
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
                        guard let row = objects[loc.segmentID.bytes]?.metadata, row[1] != .integer(0),
                              row[2] == .blob(loc.writerEpoch.bytes), row[3] == .blob(Array(loc.encodedV1()[16..<24])) else { throw StorageError.incomplete }
                    }
                }
            }
            try db.transaction {
                // Retained pending inputs keep their original capture scope through repeated repairs.
                func retainCaptureScope(_ row: [SQLValue]) throws {
                    let prefix = Array("repair-source/".utf8), key = try row[0].bytes, payload = try row[3].bytes
                    guard key.starts(with: prefix), key.count == prefix.count + 16, row[1] == .integer(1),
                          payload.count == 48, Array(payload.prefix(16)) == selection.descriptor.collection.bytes else {
                        throw StorageError.integrity
                    }
                    guard row[2] == .integer(1) else { throw StorageError.unsupported }
                    let descriptorID = Array(payload.suffix(32))
                    guard required.contains(descriptorID), objects[descriptorID]?.metadata[1] == .integer(0) else { throw StorageError.incomplete }
                    let prior = try db.rows("SELECT group_key,generation,codec,payload FROM private_groups WHERE group_key=?", [row[0]])
                    guard prior.isEmpty || prior == [row] else { throw StorageError.incomplete }
                    try db.run("INSERT INTO private_groups VALUES(?,?,?,?) ON CONFLICT(group_key) DO NOTHING", row)
                }
                for source in sources {
                    let old = source.selection
                    try retainCaptureScope([.blob(Array("repair-source/".utf8) + old.store.bytes), .integer(1), .integer(1),
                        .blob(old.descriptor.collection.bytes + old.descriptor.descriptorID)])
                    for group in source.privateTables["private_groups"] ?? [] where (try group[0].bytes).starts(with: Array("repair-source/".utf8)) {
                        try retainCaptureScope(group)
                    }
                }
                for group in groups {
                    let key = try group[0].bytes
                    if key == Array("bootstrap".utf8) || key == Array("history-damage".utf8) || key.starts(with: VerificationRecord.prefix)
                        || key.starts(with: Array("repair-source/".utf8)) { continue }
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
