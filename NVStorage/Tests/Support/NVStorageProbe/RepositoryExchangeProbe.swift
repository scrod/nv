import Foundation
import NVStorageCore
import NVStorageRuntime
import CSQLCipher
import CStorageFaults

/// Exercises real transport and fresh private owners using only selection, unlock and repository inputs.
func runRepositoryExchangeProbe(_ args: [String]) async throws -> Bool {
    guard args.count >= 4, ["exchange-publish", "exchange-discover", "exchange-bootstrap"].contains(args[0]) else { return false }
    guard nv_faults_install() == SQLITE_OK else { throw StorageError.unsupported }
    let selected = try JSONDecoder().decode(SelectionFile.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
    let selection = try selected.selection(args[1]), root = try await RepositoryRootSession.open(directory: args[3])
    let protection: ObjectProtectionV1 = try selection.descriptor.keyID.map {
        try .encrypted(keyID: $0, key: selection.descriptor.unwrap(passphrase: "probe password"))
    } ?? .publicHash
    func emit(_ state: StoreSnapshot, extra: [String: Any] = [:]) throws {
        var result = extra
        result["through"] = state.through
        result["notes"] = state.notes.map { ["birth": hex($0.birth.bytes), "body": $0.value.body.string, "cell": hex($0.encodedV1())] }
        result["context"] = hex(state.context.encodedV1())
        result["hits"] = nv_faults_hits()
        try output(result)
    }
    var openedStore: LocalStoreSession?
    do {
        if args[0] == "exchange-bootstrap" {
            guard args.count == 6, ["create", "resume"].contains(args[5]) else { throw StorageError.unsupported }
            let snapshot = try SegmentLocator.decodeV1(unhex(args[4]))
            let candidate = try await args[5] == "create" ? BootstrapCandidate.create(selection: selection, snapshot: snapshot, protection: protection)
                : BootstrapCandidate.resume(selection: selection, protection: protection)
            do {
                var ended = false, turns = 0
                while !ended {
                    let turn = try await root.discover(into: candidate, opportunity: turns == 0 ? .initialOpen : .backgroundTurn, budget: 3)
                    ended = turn.passEnded; turns += 1
                }
                let store = try await candidate.complete(snapshot: snapshot)
                openedStore = store
                let state = try await store.publish(store.prepareReduction(liveGeneration: 0), liveGeneration: 0) { $0 }
                try await store.quiesce(); await root.close()
                try emit(state, extra: ["turns": turns]); return true
            } catch { try? await candidate.close(); throw error }
        }
        let store = try await LocalStoreSession.open(selection: selection, protection: protection)
        openedStore = store
        if args[0] == "exchange-publish" {
            guard args.count == 4 else { throw StorageError.unsupported }
            var cursor: RepositoryPublicationCursor?, paths: [String] = []
            let permission = try await root.permission()
            repeat {
                let batch = try await store.captureRepositoryPublication(continuing: cursor, maximumObjects: 2)
                guard case .complete(let result) = try await root.publish(batch, from: store, using: permission) else { throw StorageError.incomplete }
                try await root.validate(result, from: store, using: permission)
                paths += result.locators.map(\.relativePath); cursor = batch.continuation
            } while cursor != nil
            let state = try await store.snapshot()
            try await store.quiesce(); await root.close(); try emit(state, extra: ["paths": paths]); return true
        }
        if args.count >= 7 { armProbeFault(args, at: 4) }
        var ended = false, turns = 0, observations: [[String: String]] = []
        while !ended {
            let turn = try await root.discover(into: store, opportunity: turns == 0 ? .foreground : .backgroundTurn, budget: 3)
            try await root.validate(turn, for: store)
            for entry in turn.entries {
                let status: String
                switch entry.outcome {
                case .descriptor: status = "descriptor"
                case .received(_, _, .accepted): status = "accepted"
                case .received(_, _, .waiting): status = "waiting"
                case .received(_, _, .blocked): status = "blocked"
                case .received(_, _, .retainedForAssembly): status = "retained"
                case .received(_, _, .pendingValidation): status = "pending-validation"
                case .unchangedAccepted: status = "unchanged"
                case .rejected(let reason): status = "rejected-\(reason.rawValue)"
                case .invalid(let reason): status = "invalid-\(reason)"
                case .unavailable(let reason): status = "unavailable-\(reason)"
                case .ignored: status = "ignored"
                }
                observations.append(["path": entry.relativePath, "status": status])
            }
            ended = turn.passEnded; turns += 1
        }
        let state = try await store.publish(store.prepareReduction(liveGeneration: 0), liveGeneration: 0) { $0 }
        try await store.quiesce(); await root.close()
        try emit(state, extra: ["turns": turns, "observations": observations]); return true
    } catch {
        // Drain the owned connection before process-exit handlers dispose of cipher globals.
        let hits = nv_faults_hits()
        nv_faults_arm(0, 0, 0)
        if let openedStore { try? await openedStore.quiesce() }
        await root.close()
        if args.count >= 7 {
            try output(["status": "failed", "error": String(describing: error), "hits": hits])
        }
        throw error
    }
}
