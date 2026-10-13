import Foundation
import Dispatch
import NVStorageCore
import NVStorageRuntime
import CStorageFaults

func currentProbeBody(_ index: Int) -> String {
    (0..<40).map { "Synthetic paragraph \($0): durable history, private storage, user actions and Unicode café 日本語; note \(index)." }.joined(separator: "\n")
}

private func waitForHeldIO() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async { nv_faults_wait_until_held(); continuation.resume() }
    }
}

extension Probe {
    /// Exercises real physical-row and maintenance consumers in disposable child-owned collections.
    static func currentMaintenanceCommand(_ args: [String], session: LocalStoreSession) async throws -> Bool {
        switch args[0] {
        case "current-recode":
            let snapshot = try await session.snapshot()
            if args.count == 6 { armProbeFault(args, at: 3) }
            do {
                _ = try await session.recodeCurrentRows(basedOn: snapshot, maximumRows: 16, trainDictionary: true)
                try output(["recoded": true, "hits": nv_faults_hits()])
            } catch { try output(["recoded": false, "error": String(describing: error), "hits": nv_faults_hits()]) }
        case "current-vacuum":
            if args.count == 6 { armProbeFault(args, at: 3) }
            do { try output(["vacuum": String(describing: await session.compactPrivateStore()), "hits": nv_faults_hits()]) }
            catch { try output(["vacuum": "failed", "error": String(describing: error), "hits": nv_faults_hits()]) }
        case "current-vacuum-held-save":
            let capture = try await CapturedActionGroup(snapshot: session.snapshot(), kind: .savedEdit,
                changes: [.put(CapturedNoteGeneration(birth: NoteBirth(bytes: Array(repeating: 1, count: 16)), generation: 1), value("F after held VACUUM"))])
            nv_faults_hold(Int32(NV_FAULT_WRITE), Int32(args[3])!)
            let vacuum = Task { try await session.compactPrivateStore() }
            await waitForHeldIO()
            await session.cancelOptionalMaintenance()
            let start = DispatchTime.now().uptimeNanoseconds
            let save = Task { try await session.persist(capture: capture) }
            nv_faults_release()
            let result = try await vacuum.value
            guard case .accepted(let receipt) = try await save.value else { throw StorageError.incomplete }
            try output(["vacuum": String(describing: result), "barrierNanoseconds": DispatchTime.now().uptimeNanoseconds - start,
                "hits": nv_faults_hits(), "envelope": hex(try await session.retainedObject(at: receipt.object))])
        default: return false
        }
        nv_faults_arm(0, 0, 0)
        try await session.quiesce()
        return true
    }
}
