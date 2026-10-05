import Foundation
import NVStorageCore
import NVStorageRuntime
import CStorageFaults

extension Probe {
    /// Process cases receive surviving selection/unlock inputs and emit observations for the independent parent oracle.
    static func privateCommand(_ args: [String], session: LocalStoreSession, protection: ObjectProtectionV1) async throws -> Bool {
        let command = args[0], selection = await session.selection
        guard command.hasPrefix("private-") else { return false }
        let item = try PendingItemID(bytes: Array(repeating: 20, count: 16))
        func input(_ body: String) throws -> PendingSnapshotV1 {
            try PendingSnapshotV1(id: PendingSnapshotID(bytes: withUnsafeBytes(of: UUID().uuid) { Array($0) }),
                scope: PrivateRecordScopeV1(collection: selection.descriptor.collection, store: selection.store, descriptor: selection.descriptor.descriptorID),
                presence: .present, path: ExactUTF8(bytes: Array("external.txt".utf8)),
                observation: PassivePlatformRecordV1(codec: 1, bytes: [42]), source: Array(body.utf8), value: value(body))
        }
        switch command {
        case "private-seed":
            try await session.saveCollectionSettings(try CollectionSettingsV1([.secureTextEntry(true), .confirmFileDeletion(false)]), basedOn: session.collectionSettings())
            let a = try input("frozen A")
            try await session.retainPendingSnapshot(a, basedOn: session.pendingItem(item))
            let r = try await session.preparePendingImport(basedOn: session.pendingItem(item), automatic: false)
            try output(["snapshot": hex(a.id.bytes), "birth": hex(r.reservation.birth.bytes)])
        case "private-latest":
            let b = try input("latest B"), state = try await session.pendingItem(item)
            if args.count == 6 { armProbeFault(args, at: 3) }
            do {
                try await session.retainPendingSnapshot(b, basedOn: state)
                try output(["retained": true, "snapshot": hex(b.id.bytes), "hits": nv_faults_hits()])
            } catch { try output(["retained": false, "error": String(describing: error), "hits": nv_faults_hits()]) }
        case "private-import":
            let prepared = try await session.preparePendingImport(basedOn: session.pendingItem(item), automatic: false)
            if args.count == 6 { nv_faults_arm_on_history_acceptance(Int32(args[3])!, Int32(args[4])!, Int32(args[5])!) }
            let outcome = try await session.persistPendingAction(prepared)
            switch outcome {
            case .accepted(let receipt): try output(["accepted": true, "object": hex(receipt.object.segmentID.bytes), "birth": hex(prepared.reservation.birth.bytes), "hits": nv_faults_hits()])
            case .pending(_, let cause):
                try output(["accepted": false, "error": String(describing: cause), "hits": nv_faults_hits()])
                return true
            }
        case "private-delete", "private-settle":
            let recovery = try await session.pendingRecovery(item)
            guard case .committed(let r, _) = recovery.first else { throw StorageError.incomplete }
            if command == "private-delete" {
                let capture = try await CapturedActionGroup(snapshot: session.snapshot(), kind: .deleteBatch,
                    changes: [.delete(CapturedNoteGeneration(birth: r.birth, generation: 2))])
                guard case .accepted = try await session.persist(capture: capture) else { throw StorageError.incomplete }
            } else {
                if args.count == 6 { nv_faults_arm_on_pending_settlement(Int32(args[3])!, Int32(args[4])!, Int32(args[5])!) }
                do {
                    try await session.completePendingAssociation(r.id, basedOn: session.pendingItem(item)) { snapshot, matches in
                        guard snapshot.source == Array("frozen A".utf8), !matches else { throw StorageError.integrity }
                        return try PassivePlatformRecordV1(codec: 1, bytes: [77])
                    }
                    try output(["settled": true, "hits": nv_faults_hits()])
                } catch { try output(["settled": false, "error": String(describing: error), "hits": nv_faults_hits()]) }
            }
        case "private-backup":
            if args.count == 7 { armProbeFault(args, at: 4) }
            do {
                let copied = try await session.backupPrivateStore(to: args[3])
                try output(["selection": try JSONEncoder().encode(SelectionFile(store: copied.selection.store.bytes, descriptor: copied.selection.descriptor.encodedBytes)).base64EncodedString(), "through": copied.through])
            } catch {
                guard args.count == 7 else { throw error }
                try output(["copied": false, "error": String(describing: error), "hits": nv_faults_hits()])
            }
        case "private-repair":
            let root = URL(fileURLWithPath: args[3])
            let association = try LocalAssociationV1(id: LocalAssociationID(bytes: withUnsafeBytes(of: UUID().uuid) { Array($0) }),
                scope: PrivateRecordScopeV1(collection: selection.descriptor.collection, store: selection.store, descriptor: selection.descriptor.descriptorID),
                bookmark: PassivePlatformRecordV1(codec: 1, bytes: [42]))
            try await session.saveLocalAssociation(association, basedOn: session.localAssociation())
            let old = try SelectedStoreRecordV1(association: association.id, store: selection.store,
                generation: SelectionGeneration(bytes: withUnsafeBytes(of: UUID().uuid) { Array($0) }))
            try Data(old.encodedV1()).write(to: root.appendingPathComponent("Selected Store"))
            let evidence = try await session.preserveForRepair(to: root.appendingPathComponent("working").path)
            let cut = args.count > 4 ? args[4] : "normal"
            let repairFault: (Int32, Int32)? = switch cut {
            case "private-before": (4, -1)
            case "private-after": (5, -1)
            case "private-enospc": (1, 13)
            case "private-eio": (2, 1034)
            default: nil
            }
            if let (event, result) = repairFault { nv_faults_arm_on_repair_private_installation(event, 1, result) }
            let candidate: VerifiedReplacement
            do { candidate = try await LocalStoreSession.buildVerifiedReplacement(to: root.appendingPathComponent("candidate").path, primary: evidence, protection: protection) }
            catch {
                guard repairFault != nil else { throw error }
                try output(["built": false, "hits": nv_faults_hits(), "error": String(describing: error)])
                return true
            }
            try JSONEncoder().encode(SelectionFile(store: candidate.selection.store.bytes, descriptor: candidate.selection.descriptor.encodedBytes)).write(to: root.appendingPathComponent("selection.json"))
            if cut == "verified" { exit(86) }
            let owner = try await SelectedStoreOwner.open(directory: root.path), state = try await owner.capture()
            guard case .activated = try await candidate.activate(using: owner, basedOn: state) else { throw StorageError.incomplete }
            if cut == "activated" { exit(86) }
            try await candidate.close()
            if cut == "closed" { exit(86) }
            try output(["activated": true])
            return true
        case "private-dump":
            let state = try await session.pendingItem(item), latest = state.latest
            var rows: [[String: Any]] = []
            for recovery in try await session.pendingRecovery(item) {
                switch recovery {
                case .review(let r): rows.append(["status": "review", "birth": hex(r.birth.bytes), "snapshot": hex(r.snapshot.bytes)])
                case .committed(let r, let op): rows.append(["status": "committed", "birth": hex(r.birth.bytes), "snapshot": hex(r.snapshot.bytes), "operation": hex(op.bytes)])
                case .blocked(_, let error): rows.append(["status": "blocked", "error": String(describing: error)])
                }
            }
            let body: String
            if let latest { body = try await session.retainedPendingSnapshot(latest).value.body.string } else { body = "" }
            let inspector = try Inspector(selection, protection: protection)
            try output(["latest": body, "reservations": rows, "settings": hex(try await session.collectionSettings().value.encodedV1()),
                "settlements": inspector.rows("SELECT hex(snapshot_id),hex(birth),hex(operation_id) FROM pending_settlements ORDER BY item_id,snapshot_id"),
                "payloads": inspector.rows("SELECT hex(snapshot_id),hex(encoded) FROM pending_payloads ORDER BY snapshot_id"),
                "notes": try await session.snapshot().notes.map { ["birth": hex($0.birth.bytes), "body": $0.value.body.string] }])
        default: throw StorageError.unsupported
        }
        try await session.quiesce()
        return true
    }
}
