import Foundation
import NVStorageCore
import NVStorageRuntime
import CStorageFaults

extension Probe {
    /// Observes automatic repair through the public collection owner, including local saves while repair is paused.
    static func collectionRepositoryRepair(_ args: [String]) async throws -> Bool {
        guard args.first == "collection-repair", args.count == 6 else { return false }
        let selected = try JSONDecoder().decode(SelectionFile.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
        let selection = try selected.selection(args[1])
        let protection: ObjectProtectionV1 = try selection.descriptor.keyID.map {
            try .encrypted(keyID: $0, key: selection.descriptor.unwrap(passphrase: "probe password"))
        } ?? .publicHash
        let opened = await CollectionSession.open(selection: selection, protection: protection,
            repository: URL(fileURLWithPath: args[3]))
        guard case .opened(let owner) = opened else {
            guard case .recovery(let health) = opened else { throw StorageError.incomplete }
            try output(["open": "recovery", "failure": String(describing: health.failure),
                "phase": String(describing: health.phase), "category": String(describing: health.category)])
            return true
        }
        do {
            let deadline = Date().addingTimeInterval(30)
            var observation: [String: Any]?
            while observation == nil, Date() < deadline {
                let request = await owner.pendingRepositoryRequest()
                switch await owner.repositoryRepairStatus() {
                case .complete(let through, let objects):
                    observation = ["repair": "complete", "through": through, "objects": objects]
                case .paused(let failure):
                    var stopped: [String: Any] = ["repair": "paused", "failure": String(describing: failure)]
                    switch failure {
                    case .root(.unavailable(let code)): stopped["nativeError"] = code; stopped["boundary"] = "root"
                    case .file(.io(let code)): stopped["nativeError"] = code; stopped["boundary"] = "file"
                    default: break
                    }
                    observation = stopped
                case .idle where request?.kind == .preserveRepositoryCollision:
                    observation = ["repair": "preserved"]
                case .idle, .checking, .installing: await Task.yield()
                }
            }
            guard var result = observation else { throw StorageError.busy }
            if let request = await owner.pendingRepositoryRequest() { result["recovery"] = String(describing: request.kind) }
            _ = try await owner.publish(owner.preparePublication(liveGeneration: 0), liveGeneration: 0) { $0 }
            if args[4] == "save" {
                let change = try CapturedNoteChange.put(.init(birth: .init(bytes: .init(repeating: 1, count: 16)), generation: 1), value(args[5]))
                switch try await owner.persist(owner.capture(kind: .savedEdit, changes: [change])) {
                case .accepted(let receipt): result["saved"] = hex(receipt.object.segmentID.bytes)
                case .pending(_, let cause): result["saveFailure"] = String(describing: cause)
                }
            } else if args[4] != "normal", args[4] != "complete-exit" { throw StorageError.unsupported }
            let state = try await owner.publish(owner.preparePublication(liveGeneration: 0), liveGeneration: 0) { $0 }
            result["notes"] = state.notes.map { ["birth": hex($0.birth.bytes), "body": $0.value.body.string] }
            if args[4] == "complete-exit" {
                guard result["repair"] as? String == "complete" else { throw StorageError.incomplete }
                _exit(86)
            }
            try await owner.close()
            try output(result)
        } catch { try? await owner.close(); throw error }
        return true
    }

    /// Recovers a preserved damaged store using independently acquired repository bytes before ordinary opening.
    static func complementaryPrivateRepair(_ args: [String], selection: LocalStoreSelection,
        protection: ObjectProtectionV1) async throws -> Bool {
        guard args[0] == "private-repair-complementary", args.count == 7 else { return false }
        let repository = URL(fileURLWithPath: args[3]), selectedDirectory = args[4]
        let attempt = URL(fileURLWithPath: args[5]), cut = args[6]
        let evidence = try await LocalStoreSession.salvagePrivateStore(selection: selection, protection: protection,
            workingDirectory: attempt.appendingPathComponent("working").path)
        let selector = try await SelectedStoreOwner.open(directory: selectedDirectory), before = try await selector.capture()
        let fault: (Int32, Int32)? = switch cut {
        case "private-before": (4, -1)
        case "private-after": (5, -1)
        case "private-enospc": (1, 13)
        case "private-eio": (2, 1034)
        default: nil
        }
        if let (event, code) = fault { nv_faults_arm_on_repair_private_installation(event, 1, code) }
        let result: CollectionPrivateRepairOutcome
        do {
            result = try await CollectionSession.repairPrivateStore(primary: evidence, repository: repository,
                to: attempt.appendingPathComponent("candidate").path, protection: protection, using: selector, basedOn: before)
        } catch {
            let hits = nv_faults_hits()
            nv_faults_arm(0, 0, 0)
            try await selector.close()
            guard fault != nil, hits > 0 else { throw error }
            try output(["built": false, "hits": hits, "error": String(describing: error)]); return true
        }
        guard case .opened(let owner, let selected) = result else { throw StorageError.incomplete }
        let candidate = await owner.selection
        guard selected.record?.store == candidate.store else { throw StorageError.wrongContext }
        if cut == "activated" { _exit(86) }
        try JSONEncoder().encode(SelectionFile(store: candidate.store.bytes, descriptor: candidate.descriptor.encodedBytes))
            .write(to: attempt.appendingPathComponent("selection.json"))
        try await owner.close()
        try output(["built": true, "missingPrivate": evidence.unavailableCommittedObjects.map(hex).sorted()])
        return true
    }

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
        case "private-projection-create":
            guard args.count == 5 else { throw StorageError.unsupported }
            let root = try await RepositoryRootSession.open(directory: args[3])
            let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
            if args[4] == "prepare" {
                let association = try await root.association(for: selection,
                    id: .init(bytes: Array(repeating: 13, count: 16)))
                try await session.saveLocalAssociation(association, basedOn: session.localAssociation())
                let intent = try await session.prepareProjectionIntent(for: birth,
                    filename: .init(ExactUTF8(bytes: Array("Note.txt".utf8))), basedOn: session.snapshot(),
                    observations: session.projectionObservations(for: birth), requestedEncoding: .init(rawValue: 10))
                try await session.retainProjectionIntent(intent)
                _ = try await session.freezeProjectionIntent(observations: session.projectionObservations(for: birth))
                try output(["prepared": true])
            } else {
                let input = try await session.prepareProjectionCreation(observations: session.projectionObservations(for: birth), basedOn: session.snapshot())
                let result = try await root.createProjection(input, from: session, using: root.permission())
                switch result {
                case .verified(let receipt):
                    if args[4] == "exit-after-install" { _exit(86) }
                    try await root.validate(receipt, for: input, from: session, using: root.permission())
                    if args[4] == "install-dates" {
                        try output(["state": "verified", "bytes": hex(receipt.file.bytes),
                            "createdSeconds": receipt.file.created?.seconds as Any,
                            "createdNanoseconds": receipt.file.created?.nanoseconds as Any,
                            "modifiedSeconds": receipt.file.modified.seconds,
                            "modifiedNanoseconds": receipt.file.modified.nanoseconds])
                    } else {
                        try output(["state": "verified", "bytes": hex(receipt.file.bytes)])
                    }
                case .notInstalled(let failure): try output(["state": "notInstalled", "reason": String(describing: failure.reason)])
                case .uncertain(let failure): try output(["state": "uncertain", "reason": String(describing: failure.reason)])
                }
            }
            await root.close()
        case "private-projection-write", "private-projection-encoded-write", "private-projection-macroman-write":
            guard args.count == 4 || args.count == 7 else { throw StorageError.unsupported }
            let prior = try await session.localAssociation()
            if prior.value == nil {
                let association = try LocalAssociationV1(id: LocalAssociationID(bytes: Array(repeating: 13, count: 16)),
                    scope: .init(collection: selection.descriptor.collection, store: selection.store, descriptor: selection.descriptor.descriptorID),
                    bookmark: .init(codec: 1, bytes: []))
                try await session.saveLocalAssociation(association, basedOn: prior)
            }
            let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
            let prepared = try await session.prepareProjectionIntent(for: birth, filename: .init(ExactUTF8(bytes: Array(args[3].utf8))),
                basedOn: session.snapshot(), observations: session.projectionObservations(for: birth),
                requestedEncoding: .init(rawValue: command == "private-projection-encoded-write" ? 10 : command == "private-projection-macroman-write" ? 30 : 4))
            if args.count == 7 { armProbeFault(args, at: 4) }
            do {
                try await session.retainProjectionIntent(prepared)
                try output(["retained": true, "hits": nv_faults_hits()])
            } catch { try output(["retained": false, "hits": nv_faults_hits(), "error": String(describing: error)]) }
        case "private-projection-freeze":
            guard args.count == 3 || args.count == 6 else { throw StorageError.unsupported }
            let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
            let prior = try await session.projectionObservations(for: birth)
            if args.count == 6 { armProbeFault(args, at: 3) }
            do {
                let frozen = try await session.freezeProjectionIntent(observations: prior)
                try output(["retained": true, "generation": frozen.generation, "hits": nv_faults_hits()])
            } catch { try output(["retained": false, "hits": nv_faults_hits(), "error": String(describing: error)]) }
        case "private-projection-description":
            guard args.count == 3 || args.count == 6 else { throw StorageError.unsupported }
            let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
            let observed = try await session.projectionObservations(for: birth)
            guard let intent = observed.value?.intended else { throw StorageError.incomplete }
            let handle = try await session.prepareProjectionDescription(for: intent.output, observations: observed, basedOn: session.snapshot())
            if args.count == 6 { nv_faults_arm_on_history_acceptance(Int32(args[3])!, Int32(args[4])!, Int32(args[5])!) }
            switch try await session.persistProjectionDescription(handle) {
            case .accepted(let receipt):
                try output(["accepted": true, "object": hex(receipt.object.segmentID.bytes), "sequence": receipt.sequence, "hits": nv_faults_hits()])
            case .pending(let retry, let cause):
                try output(["accepted": false, "object": hex(retry.object.segmentID.bytes), "error": String(describing: cause), "hits": nv_faults_hits()])
            }
        case "private-projection-read":
            let inspector = try Inspector(selection, protection: protection)
            try output(["rows": inspector.rows("SELECT generation,codec,hex(payload) FROM private_groups WHERE group_key>=X'70726F6A656374696F6E2F' AND group_key<X'70726F6A656374696F6E30' ORDER BY group_key"),
                        "notes": try await session.snapshot().notes.map { $0.value.body.string }.sorted()])
        case "private-projection-encoded-read":
            let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
            let state = try await session.projectionObservations(for: birth)
            guard let retained = state.value?.intended?.output else { throw StorageError.incomplete }
            let bytes = try await session.projectionBytes(for: retained, observations: state, basedOn: session.snapshot())
            let frozenBytes: [UInt8]? = if let frozen = state.value?.frozen {
                try await session.projectionBytes(for: frozen.output, observations: state, basedOn: session.snapshot())
            } else { nil }
            let inspector = try Inspector(selection, protection: protection)
            try output(["bytes": hex(bytes), "generation": retained.generation,
                        "frozen": frozenBytes.map(hex) as Any? ?? NSNull(), "privateGeneration": state.generation,
                        "filename": retained.binding.descriptor.filename.spelling.string,
                        "private": inspector.rows("SELECT hex(group_key),generation,codec,hex(payload) FROM private_groups WHERE group_key>=X'70726F6A656374696F6E' AND group_key<X'70726F6A656374696F6F' ORDER BY group_key"),
                        "notes": try await session.snapshot().notes.map { $0.value.body.string }.sorted()])
        case "private-bind-repository":
            guard args.count == 5 else { throw StorageError.unsupported }
            let root = try await RepositoryRootSession.open(directory: args[3])
            let association = try await root.association(for: selection,
                id: LocalAssociationID(bytes: withUnsafeBytes(of: UUID().uuid) { Array($0) }))
            try await session.saveLocalAssociation(association, basedOn: session.localAssociation())
            await root.close()
            let selected = try SelectedStoreRecordV1(association: association.id, store: selection.store,
                generation: SelectionGeneration(bytes: withUnsafeBytes(of: UUID().uuid) { Array($0) }))
            try Data(selected.encodedV1()).write(to: URL(fileURLWithPath: args[4] + "/Selected Store"))
            try output(["bound": true])
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
        case "private-repair", "private-repair-integrated":
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
            if command == "private-repair-integrated" {
                let owner = try await SelectedStoreOwner.open(directory: root.path), state = try await owner.capture()
                let result: CollectionPrivateRepairOutcome
                do {
                    result = try await CollectionSession.repairPrivateStore(primary: evidence,
                        to: root.appendingPathComponent("candidate").path, protection: protection, using: owner, basedOn: state)
                } catch {
                    guard repairFault != nil else { throw error }
                    try await owner.close()
                    try output(["built": false, "hits": nv_faults_hits(), "error": String(describing: error)])
                    return true
                }
                guard case .opened(let collection, _) = result else { throw StorageError.incomplete }
                let candidate = await collection.selection
                try JSONEncoder().encode(SelectionFile(store: candidate.store.bytes, descriptor: candidate.descriptor.encodedBytes))
                    .write(to: root.appendingPathComponent("selection.json"))
                if cut == "activated" { exit(86) }
                try await collection.close()
                try output(["activated": true])
                return true
            }
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
                "settlementRecords": inspector.rows("SELECT hex(item_id),hex(snapshot_id),hex(reservation_id),hex(operation_id),hex(birth),hex(decision_digest),observation_codec,hex(observation) FROM pending_settlements ORDER BY item_id,snapshot_id"),
                "latestSnapshot": latest.map { hex($0.bytes) } ?? "",
                "payloads": inspector.rows("SELECT hex(snapshot_id),hex(encoded) FROM pending_payloads ORDER BY snapshot_id"),
                "notes": try await session.snapshot().notes.map { ["birth": hex($0.birth.bytes), "body": $0.value.body.string] }])
        default: throw StorageError.unsupported
        }
        try await session.quiesce()
        return true
    }
}
