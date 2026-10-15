import Foundation
import Crypto
import NVStorageCore
import NVStorageRuntime
import CSQLCipher
import CStorageFaults

/// Exercises integrated startup, choices and reassociation from a signed headless app.
func runCollectionControllerProbe(_ args: [String]) async throws -> Bool {
    guard args.count == 2, args[0] == "startup-controller" else { return false }
    guard nv_faults_install() == SQLITE_OK else { throw StorageError.unsupported }
    let config = try JSONDecoder().decode(DriverConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
    guard let input = FileHandle(forReadingAtPath: config.input), let output = FileHandle(forWritingAtPath: config.output) else {
        throw StorageError.incomplete
    }
    defer { try? input.close(); try? output.close() }
    func emit(_ result: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]); data.append(10)
        try output.write(contentsOf: data)
    }
    try emit(["state": "launched", "pid": ProcessInfo.processInfo.processIdentifier])
    var eviction = "not-requested"
#if canImport(Darwin)
    if let encoded = config.evict {
        let locator = try SegmentLocator.decodeV1(unhex(encoded))
        let sequence = String(locator.sequence)
        let relative = "NV Data/v1/segments/" + hex(locator.writerEpoch.bytes) + "/" +
            String(repeating: "0", count: 20 - sequence.count) + sequence + "-" + hex(locator.segmentID.bytes) + ".nvseg"
        let file = URL(fileURLWithPath: config.repository).appendingPathComponent(relative)
        do { try FileManager.default.evictUbiquitousItem(at: file); eviction = "requested" }
        catch { eviction = "unavailable" }
    }
#endif
    var owner: CollectionSession?
    var bootstrap: CollectionBootstrapSession?
    var generation: UInt64 = 0
    func saveSelection(_ selection: LocalStoreSelection) throws {
        try JSONEncoder().encode(SelectionFile(store: selection.store.bytes, descriptor: selection.descriptor.encodedBytes))
            .write(to: URL(fileURLWithPath: config.selection))
    }
    if config.mode == "create" {
        let encrypted = config.profile == "encrypted"
        let protection: ObjectProtectionV1 = encrypted ? .encrypted(keyID: try .init(bytes: Array(repeating: 3, count: 16)),
            key: SymmetricKey(data: Array(repeating: 4, count: 32))) : .publicHash
        let created = try await CollectionSession.create(repository: URL(fileURLWithPath: config.repository),
            intent: config.intent == "new" ? .createNewDirectory : .createInExistingDirectory,
            privateDirectory: config.directory, collection: .init(bytes: Array(repeating: 1, count: 16)),
            notes: [(NoteBirth(bytes: Array(repeating: 1, count: 16)), value("initial")),
                    (NoteBirth(bytes: Array(repeating: 2, count: 16)), value("untouched"))],
            protection: protection, passphrase: encrypted ? "probe password" : nil)
        owner = created; try await saveSelection(created.selection)
    } else {
        let selected = try JSONDecoder().decode(SelectionFile.self, from: Data(contentsOf: URL(fileURLWithPath: config.selection)))
        let selection = try selected.selection(config.directory)
        let protection: ObjectProtectionV1 = try selection.descriptor.keyID.map {
            try .encrypted(keyID: $0, key: selection.descriptor.unwrap(passphrase: "probe password"))
        } ?? .publicHash
        if config.mode == "bootstrap" {
            guard let snapshot = config.snapshot else { throw StorageError.incomplete }
            let entry = try await CollectionBootstrapSession.open(repository: URL(fileURLWithPath: config.repository),
                privateDirectory: config.directory, descriptor: selection.descriptor,
                snapshot: SegmentLocator.decodeV1(unhex(snapshot)), protection: protection)
            bootstrap = entry; try await saveSelection(entry.selection)
        } else {
            guard case .opened(let opened) = await CollectionSession.open(selection: selection, protection: protection,
                repository: URL(fileURLWithPath: config.repository)) else { throw StorageError.incomplete }
            owner = opened
        }
    }
    func transportStatus(_ owner: CollectionSession) async -> [String: Any] {
        guard let status = await owner.transportStatus() else { return [:] }
        return ["discovery": String(describing: status.discovery),
                "publication": String(describing: status.publication),
                "materialization": String(describing: status.materialization)]
    }
    func current(_ owner: CollectionSession) async throws -> [String: Any] {
        let decision = await owner.decision()
        var result: [String: Any] = ["decision": String(describing: decision)]
        switch decision {
        case .ready, .editable:
            var captured: StoreSnapshot?
            for _ in 0..<8 {
                generation += 1
                do {
                    captured = try await owner.publish(owner.preparePublication(liveGeneration: generation), liveGeneration: generation) { $0 }
                    break
                } catch StorageError.staleCapture { await Task.yield() }
            }
            guard let snapshot = captured else { throw StorageError.busy }
            result["notes"] = snapshot.notes.map { ["birth": hex($0.birth.bytes), "body": $0.value.body.string, "cell": hex($0.encodedV1())] }
            result["context"] = hex(snapshot.context.encodedV1()); result["through"] = snapshot.through
        case .waiting, .recovery, .contention, .transition, .closed: break
        }
        if let request = await owner.pendingRepositoryRequest() { result["recovery"] = String(describing: request.kind) }
        if let pending = await owner.pendingProviderObject() { result["pending"] = hex(pending.encodedV1()) }
        result["repair"] = String(describing: await owner.repositoryRepairStatus())
        result.merge(await transportStatus(owner)) { _, status in status }
        return result
    }
    func copied(_ result: ActiveRepositoryCopy) -> [String: Any] {
        ["through": result.through, "excludedPending": result.excludedPrivatePendingItems,
         "completeInventory": result.repository.capturedInventoryComplete,
         "files": result.repository.files.map { ["path": $0.path, "sha256": hex($0.sha256)] },
         "issues": result.repository.issues.map { ["path": $0.path, "cause": String(describing: $0.cause)] },
         "unmet": result.repository.unmetRequirements.map(\.path)]
    }
    func switchCollection(_ source: CollectionSession, request: DriverCommand) async throws -> [String: Any] {
        guard let repository = request.repository, let directory = request.privateDirectory,
              let selectionDirectory = request.selectionDirectory else { throw StorageError.incomplete }
        let initial = try await SelectedStoreOwner.open(directory: selectionDirectory)
        let first = try await initial.capture()
        if first.record == nil {
            guard case .activated = try await source.activateFreshSelection(using: initial, basedOn: first) else {
                throw StorageError.incomplete
            }
        } else { try await initial.close() }
        let selector = try await SelectedStoreOwner.open(directory: selectionDirectory)
        do {
            let result = try await source.switchRepositoryAndSavedWork(to: repository, privateDirectory: directory,
                using: selector, basedOn: selector.capture())
            if case .sourceRetained(let cause) = result.outcome {
                try? await selector.close()
                return ["outcome": "source-retained", "cause": String(describing: cause), "copy": copied(result.copy)]
            }
            guard case .opened(let successor, let selected) = result.outcome else { throw StorageError.incomplete }
            let selection = await successor.selection
            guard selected.record?.store == selection.store else { throw StorageError.wrongContext }
            owner = successor
            try saveSelection(selection)
            return ["outcome": "opened", "copy": copied(result.copy), "current": try await current(successor),
                    "store": hex(selection.store.bytes)]
        } catch { try? await selector.close(); throw error }
    }
    do {
        try emit(["state": "running", "pid": ProcessInfo.processInfo.processIdentifier, "eviction": eviction])
        while let request = try await driverCommand(input) {
            if request.command == "stop" {
                if let owner { try await owner.close() } else { try await bootstrap?.close() }
                try emit(["state": "stopped"]); return true
            }
            if let entry = bootstrap, owner == nil {
                switch request.command {
                case "discover":
                    let result = try await entry.discover(budget: 3)
                    try emit(["passEnded": result.passEnded])
                case "preview":
                    let preview = try await entry.preview()
                    try emit(["readOnly": true, "notes": preview.notes.map { ["birth": hex($0.birth.bytes), "body": $0.value.body.string] }])
                case "complete":
                    let completed = try await entry.complete()
                    owner = completed; bootstrap = nil
                    try await emit(current(completed))
                default: throw StorageError.unsupported
                }
                continue
            }
            guard let owner else { throw StorageError.incomplete }
            switch request.command {
            case "state": try await emit(current(owner))
            case "transport-status": try await emit(transportStatus(owner))
            case "copy":
                guard let repository = request.repository else { throw StorageError.incomplete }
                try await emit(copied(owner.copyRepositoryAndSavedWork(to: repository)))
            case "switch": try await emit(switchCollection(owner, request: request))
            case "put", "create", "delete":
                generation += 1
                let birth = try NoteBirth(bytes: Array(repeating: request.birth ?? 1, count: 16))
                let covered = try CapturedNoteGeneration(birth: birth, generation: generation)
                let kind: OrdinaryActionKind, change: CapturedNoteChange
                switch request.command {
                case "put": kind = .savedEdit; change = try .put(covered, value(request.body ?? ""))
                case "create": kind = .createImportBatch; change = try .create(covered, value(request.body ?? ""))
                default: kind = .deleteBatch; change = .delete(covered)
                }
                guard case .accepted(let receipt) = try await owner.persist(owner.capture(kind: kind, changes: [change])) else {
                    throw StorageError.incomplete
                }
                try emit(["object": hex(receipt.object.encodedV1()), "sequence": receipt.sequence])
            case "consider":
                guard let locator = request.locator else { throw StorageError.incomplete }
                do {
                    try await owner.considerProviderObject(SegmentLocator.decodeV1(unhex(locator)))
                    try await emit(current(owner))
                } catch { try emit(["unavailable": String(describing: error)]) }
            case "waiting-bytes": try await owner.requestWaitingBytes(); try emit(["requested": true])
            case "offline":
                do {
                    guard case .waiting(let choice) = await owner.decision() else { throw StorageError.staleCapture }
                    try await owner.workOffline(choice); try await emit(current(owner))
                } catch { try emit(["unavailable": String(describing: error)]) }
            case "retry":
                do { try await emit(["continuity": String(describing: owner.retryRepository(at: URL(fileURLWithPath: request.repository ?? config.repository)))]) }
                catch { try emit(["unavailable": String(describing: error)]) }
            case "reopen":
                try await owner.reopenRepository(at: URL(fileURLWithPath: request.repository ?? config.repository), descriptor: owner.selection.descriptor)
                try await emit(current(owner))
            default: throw StorageError.unsupported
            }
        }
        if let owner { try await owner.close() } else { try await bootstrap?.close() }
        return true
    } catch {
        try? emit(["state": "failed", "error": String(describing: error)])
        if let owner { try? await owner.close() } else { try? await bootstrap?.close() }
        throw error
    }
}
