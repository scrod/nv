import Foundation
import Crypto
import NVStorageCore
import NVStorageRuntime
import CSQLCipher
import CStorageFaults

struct SelectionFile: Codable {
    let store: [UInt8]
    let descriptor: [UInt8]
    func selection(_ directory: String) throws -> LocalStoreSelection {
        try .init(directory: directory, store: LocalStoreID(bytes: store), descriptor: .decodeV1(descriptor))
    }
}
func value(_ body: String) throws -> PlaintextNoteValue {
    try .init(title: ExactUTF8(bytes: Array("Title".utf8)), body: ExactUTF8(bytes: Array(body.utf8)), labels: CanonicalLabels([]),
        created: DisplayDate(secondsSinceReferenceDate: 0), modified: DisplayDate(secondsSinceReferenceDate: 1))
}
func output(_ object: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
}
func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

/// Release a cold batch only after every independent collection worker arrives.
actor ColdStartGate {
    let count: Int
    var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ count: Int) { self.count = count }
    func arrive() async {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            if waiters.count == count {
                for waiter in waiters { waiter.resume() }
                waiters.removeAll()
            }
        }
    }
}

/// Independent SQL inspection bypasses the runtime's materializer and receipt path.
final class Inspector {
    var db: OpaquePointer?
    init(_ selection: LocalStoreSelection, protection: ObjectProtectionV1) throws {
        guard sqlite3_open_v2(selection.directory + "/Collection.sqlite", &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { throw StorageError.integrity }
        let key = try PrivateDatabaseKeyV1.derive(collection: selection.descriptor.collection, protection: protection)
        let raw = "x'" + hex(key) + "'"
        guard sqlite3_key(db, raw, Int32(raw.utf8.count)) == SQLITE_OK else { throw StorageError.integrity }
    }
    deinit { sqlite3_close(db) }
    func rows(_ sql: String) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw StorageError.integrity }
        defer { sqlite3_finalize(statement) }
        var rows: [[String]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw StorageError.database(result) }
            var row: [String] = []
            for n in 0..<sqlite3_column_count(statement) {
                if let s = sqlite3_column_text(statement, n) { row.append(String(cString: s)) } else { row.append("") }
            }
            rows.append(row)
        }
        return rows
    }
}

@main struct Probe {
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("probe failed: \(error)\n".utf8)); exit(2) }
    }
    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["zstd-envelopes"] {
            let collection = try CollectionID(bytes: .init(repeating: 1, count: 16))
            let writer = try WriterEpoch(bytes: .init(repeating: 3, count: 16))
            let keyID = try CollectionKeyID(bytes: .init(repeating: 2, count: 16))
            var results: [[String: Any]] = []
            for kind in [ProviderObjectKind.changes, .snapshotRoot, .snapshotPage] {
                for encrypted in [false, true] {
                    let protection: ObjectProtectionV1 = encrypted ? .encrypted(keyID: keyID,
                        key: SymmetricKey(data: Array(UInt8(0)...31))) : .publicHash
                    for size in [0, 4096] {
                        let payload = (0..<size).map { UInt8($0 % 251) }
                        let bytes = try ObjectEnvelopeV1.seal(payload: payload, kind: kind, collection: collection,
                            writer: writer, sequence: 7, protection: protection, compress: true)
                        results.append(["kind": kind.rawValue, "encrypted": encrypted, "size": size, "bytes": hex(bytes)])
                    }
                }
            }
            try output(results); return
        }
        guard args.count >= 3 else { throw StorageError.unsupported }
        let command = args[0], directory = args[1]
        if command == "cold-batch" {
            let encrypted = args[2] == "encrypted"
            let collection = try CollectionID(bytes: Array(repeating: 1, count: 16))
            let protection: ObjectProtectionV1 = encrypted ? try .encrypted(keyID: CollectionKeyID(bytes: Array(repeating: 3, count: 16)), key: SymmetricKey(data: [UInt8](repeating: 4, count: 32))) : .publicHash
            let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
            let initial = try InitialCollectionV1.build(collection: collection, notes: [(birth, value("cold startup"))],
                protection: protection, passphrase: encrypted ? "probe password" : nil)
            let gate = ColdStartGate(16)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<16 {
                    group.addTask {
                        await gate.arrive()
                        let owner = try await LocalStoreSession.create(directory: directory + "/\(index)", initial: initial, protection: protection)
                        let selection = await owner.selection
                        guard try await owner.snapshot().notes.map(\.value.body.string) == ["cold startup"] else { throw StorageError.integrity }
                        try await owner.quiesce()
                        let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
                        guard try await reopened.snapshot().notes.map(\.value.body.string) == ["cold startup"] else { throw StorageError.integrity }
                        try await reopened.quiesce()
                    }
                }
                try await group.waitForAll()
            }
            try output(["cold_opens_and_reopens": 16]); return
        }
        guard nv_faults_install() == SQLITE_OK else { throw StorageError.unsupported }
        if command == "create" {
            let encrypted = args[2] == "encrypted"
            let collection = try CollectionID(bytes: Array(repeating: 1, count: 16))
            let protection: ObjectProtectionV1 = encrypted ? try .encrypted(keyID: CollectionKeyID(bytes: Array(repeating: 3, count: 16)), key: SymmetricKey(data: [UInt8](repeating: 4, count: 32))) : .publicHash
            let initial = try InitialCollectionV1.build(collection: collection,
                notes: [(NoteBirth(bytes: Array(repeating: 1, count: 16)), value("A")),
                        (NoteBirth(bytes: Array(repeating: 2, count: 16)), value("untouched"))],
                protection: protection, passphrase: encrypted ? "probe password" : nil)
            let store = try LocalStoreID(bytes: withUnsafeBytes(of: UUID().uuid) { Array($0) })
            let selectionData = try JSONEncoder().encode(SelectionFile(store: store.bytes, descriptor: initial.descriptor.encodedBytes))
            if args.count >= 4 { try selectionData.write(to: URL(fileURLWithPath: args[3]), options: .atomic) }
            if args.count == 7 { nv_faults_arm(Int32(args[4])!, Int32(args[5])!, Int32(args[6])!) }
            let session = try await LocalStoreSession.create(directory: directory, initial: initial, protection: protection, storeID: store)
            let selection = await session.selection
            try await session.quiesce()
            guard selection.store == store else { throw StorageError.wrongContext }
            FileHandle.standardOutput.write(selectionData); FileHandle.standardOutput.write(Data([10])); return
        }
        let file = try JSONDecoder().decode(SelectionFile.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
        let selection = try file.selection(directory)
        let protection: ObjectProtectionV1
        if let id = selection.descriptor.keyID { protection = try .encrypted(keyID: id, key: selection.descriptor.unwrap(passphrase: "probe password")) }
        else { protection = .publicHash }
        if command == "reject-fault" {
            let session = try await LocalStoreSession.open(selection: selection, protection: protection)
            let bytes = try ObjectEnvelopeV1.seal(payload: [], kind: .changes,
                collection: selection.descriptor.collection, writer: WriterEpoch(bytes: Array(repeating: 97, count: 16)),
                sequence: 0, protection: protection)
            let candidatePath = URL(fileURLWithPath: args[3])
            // Repeated attempts and fresh processes share the exact originally sealed input.
            let candidate: [UInt8]
            if FileManager.default.fileExists(atPath: candidatePath.path) { candidate = try Array(Data(contentsOf: candidatePath)) }
            else { try Data(bytes).write(to: candidatePath); candidate = bytes }
            let event = Int32(args[4])!, code = Int32(args[5])!, count = Int(args[6])!
            var failures: [String] = []
            for _ in 0..<count {
                nv_faults_arm_on_rejection(event, 1, code)
                do { _ = try await session.receive(candidate); throw StorageError.integrity }
                catch {
                    guard nv_faults_hits() > 0 else { throw StorageError.incomplete }
                    failures.append(String(describing: error))
                }
            }
            nv_faults_arm(0, 0, 0)
            try output(["failures": failures, "id": hex(Array(SHA256.hash(data: candidate)))])
            try await session.quiesce(); return
        }
        if command == "damage-fence" || command == "damage-fence-io" {
            let session = try await LocalStoreSession.open(selection: selection, protection: protection)
            let prepared = try await session.prepareReduction(liveGeneration: 1)
            do { _ = try await session.receive([0]); throw StorageError.integrity }
            catch CanonicalEncodingError.lengthLimit { }
            guard try await session.publish(prepared, liveGeneration: 1, apply: { $0.notes.count }) == 2 else {
                throw StorageError.integrity
            }
            let inspector = try Inspector(selection, protection: protection)
            _ = try inspector.rows("DROP TRIGGER objects_no_update")
            _ = try inspector.rows("UPDATE objects SET encoded=X'00' WHERE object_id=X'" + hex(selection.descriptor.genesis.segmentID.bytes) + "'")
            let repeatedFailure = command == "damage-fence-io"
            let ioCode = args.count == 4 ? Int32(args[3])! : SQLITE_FULL
            if repeatedFailure { nv_faults_arm(Int32(NV_FAULT_WRITE), 1, ioCode) }
            do { _ = try await session.retainedObject(at: selection.descriptor.genesis); throw StorageError.unsupported }
            catch CanonicalEncodingError.lengthLimit { }
            if repeatedFailure {
                guard nv_faults_hits() > 0 else { throw StorageError.incomplete }
                for _ in 0..<2 {
                    guard try inspector.rows("SELECT 1 FROM private_groups WHERE group_key=X'686973746F72792D64616D616765'").isEmpty else {
                        throw StorageError.integrity
                    }
                    nv_faults_arm(Int32(NV_FAULT_WRITE), 1, ioCode)
                    do { _ = try await session.publish(prepared, liveGeneration: 1) { $0.notes.count }; throw StorageError.unsupported }
                    catch StorageError.integrity { }
                    guard nv_faults_hits() > 0 else { throw StorageError.incomplete }
                }
                nv_faults_arm(0, 0, 0)
            }
            do {
                _ = try await session.publish(prepared, liveGeneration: 1) { $0.notes.count }
                throw StorageError.unsupported
            } catch StorageError.integrity { }
            guard try inspector.rows("SELECT codec,length(payload) FROM private_groups WHERE group_key=X'686973746F72792D64616D616765'") == [["1", "0"]] else {
                throw StorageError.incomplete
            }
            try await session.quiesce()
            try output(["incoming_rejection_preserved_health": true, "known_damage_blocked_publication": true, "damage_marker_committed": true])
            return
        }
        if command == "apply" || command == "receive-file" {
            let session = try await LocalStoreSession.open(selection: selection, protection: protection)
            do {
            if command == "receive-file" {
                let bytes = try [UInt8](Data(contentsOf: URL(fileURLWithPath: args[3])))
                if args.count == 7 { nv_faults_arm(Int32(args[4])!, Int32(args[5])!, Int32(args[6])!) }
                let outcome = try await session.receive(bytes)
                switch outcome {
                case .pendingValidation: try output(["status": "pending-validation"])
                case .blocked(let reasons, let unaccepted):
                    try output(["status": "blocked", "rejections": reasons.map { ["id": hex($0.object.bytes), "reason": String($0.reason.rawValue)] }, "unaccepted": unaccepted.count])
                case .waiting(let missing): try output(["status": "waiting", "missing": missing.count, "hits": nv_faults_hits()])
                case .accepted(let sequence): try output(["status": "accepted", "sequence": sequence, "hits": nv_faults_hits()])
                }
            } else {
                guard args.count == 6, let n = UInt8(args[4]) else { throw StorageError.unsupported }
                let generation = try CapturedNoteGeneration(birth: NoteBirth(bytes: Array(repeating: n, count: 16)), generation: 1)
                let kind: ActionKindV1, change: CapturedNoteChange
                switch args[3] {
                case "create": kind = .createImportBatch; change = .create(generation, try value(args[5]))
                case "put": kind = .savedEdit; change = .put(generation, try value(args[5]))
                case "delete": kind = .deleteBatch; change = .delete(generation)
                default: throw StorageError.unsupported
                }
                let capture = try await CapturedActionGroup(snapshot: session.snapshot(), kind: kind, changes: [change])
                guard case .accepted(let receipt) = try await session.persist(capture: capture) else { throw StorageError.incomplete }
                try output(["sequence": receipt.sequence, "envelope": hex(try await session.retainedObject(at: receipt.object))])
            }
            try await session.quiesce(); return
            } catch {
                // Finish queued connection cleanup before the process runs cipher destructors.
                try? await session.quiesce()
                throw error
            }
        }
        if command == "inspect" || command == "tamper" || command == "truncate-wal" {
            let inspector = try Inspector(selection, protection: protection)
            if command == "truncate-wal" {
                guard try inspector.rows("PRAGMA wal_checkpoint(TRUNCATE)").first?.first == "0" else { throw StorageError.busy }
                return
            }
            if command == "tamper" {
                guard args.count == 4 else { throw StorageError.unsupported }
                let commands = [
                    "cell": "UPDATE current_notes SET cell=X'00'",
                    "settings": "DELETE FROM private_groups WHERE group_key=X'73657474696E6773'",
                    "settings-version": "UPDATE private_groups SET codec=2 WHERE group_key=X'73657474696E6773'",
                    "bootstrap": "DELETE FROM private_groups WHERE group_key=X'626F6F747374726170'",
                    "pin": "DELETE FROM retained_frontier",
                    "view": "UPDATE view_meta SET authoring_context=X'00'",
                    "prefix": "UPDATE view_meta SET through_seq=0",
                    "history-missing": "DELETE FROM objects WHERE kind=2",
                    "history-corrupt": "DROP TRIGGER objects_no_update; UPDATE objects SET encoded=zeroblob(length(encoded)) WHERE kind=2"
                ]
                guard let sql = commands[args[3]] else { throw StorageError.unsupported }
                for statement in sql.split(separator: ";") { _ = try inspector.rows(String(statement)) }
                try output(["tampered": args[3]]); return
            }
            var report: [String: Any] = [:]
            report["cipher"] = try inspector.rows("PRAGMA cipher_version")
            report["integrity"] = try inspector.rows("PRAGMA integrity_check")
            report["foreign_keys"] = try inspector.rows("PRAGMA foreign_key_check")
            report["objects"] = try inspector.rows("SELECT hex(o.object_id),o.kind,hex(o.writer_epoch),hex(o.sequence),hex(o.encoded),a.seq FROM objects o LEFT JOIN accepted_objects a USING(object_id) ORDER BY o.rowid")
            report["operations"] = try inspector.rows("SELECT hex(operation_id),kind,hex(birth),hex(action_id),hex(source_object),source_index,first_seq FROM operations ORDER BY operation_id")
            report["actions"] = try inspector.rows("SELECT hex(action_id),hex(origin_id),hex(previous_origin_action),hex(scope_birth),kind FROM actions ORDER BY action_id")
            report["cells"] = try inspector.rows("SELECT hex(birth),hex(cell) FROM current_notes ORDER BY birth")
            report["members"] = try inspector.rows("SELECT hex(action_id),ordinal,hex(operation_id) FROM action_members ORDER BY action_id,ordinal")
            report["operation_occurrences"] = try inspector.rows("SELECT hex(operation_id),hex(object_id),record_index FROM operation_occurrences ORDER BY operation_id,object_id,record_index")
            report["action_occurrences"] = try inspector.rows("SELECT hex(action_id),hex(object_id),record_index FROM action_occurrences ORDER BY action_id,object_id,record_index")
            report["dependencies"] = try inspector.rows("SELECT hex(child),hex(prerequisite) FROM accepted_dependencies ORDER BY child,prerequisite")
            report["parents"] = try inspector.rows("SELECT hex(child),hex(parent) FROM operation_parents ORDER BY child,parent")
            report["predecessors"] = try inspector.rows("SELECT hex(child),hex(predecessor) FROM note_predecessors ORDER BY child,predecessor")
            report["frontier"] = try inspector.rows("SELECT hex(object_id),hex(locator) FROM retained_frontier ORDER BY object_id")
            report["descriptors"] = try inspector.rows("SELECT hex(object_id) FROM retained_descriptors")
            report["private"] = try inspector.rows("SELECT hex(group_key),generation,codec,hex(payload) FROM private_groups ORDER BY group_key")
            report["view"] = try inspector.rows("SELECT hex(epoch),through_seq,hex(authoring_context) FROM view_meta")
            report["rejected"] = try inspector.rows("SELECT hex(object_id),validator_version,reason FROM rejected_objects ORDER BY object_id")
            report["ready"] = try inspector.rows("SELECT hex(object_id) FROM ready_objects ORDER BY object_id")
            report["waiting"] = try inspector.rows("SELECT hex(child),hex(prerequisite) FROM object_waits ORDER BY child,prerequisite")
            try output(report); return
        }
        nv_faults_reset_steps()
        if command == "open-crash", args.count == 6 {
            nv_faults_arm(Int32(args[3])!, Int32(args[4])!, Int32(args[5])!)
        }
        let session = try await LocalStoreSession.open(selection: selection, protection: protection)
        let snapshot = try await session.snapshot()
        if command == "dump" || command == "open-crash" {
            try output(["through": snapshot.through, "notes": snapshot.notes.map { ["birth": hex($0.birth.bytes), "body": $0.value.body.string, "cell": hex($0.encodedV1())] },
                        "context": hex(snapshot.context.encodedV1()), "steps": nv_faults_steps()])
        } else if command == "held-completion" || command == "held-owner-loss" {
            let a = try NoteBirth(bytes: Array(repeating: 1, count: 16))
            var model = HeadlessModel(snapshot: snapshot)
            _ = try model.put(value("edited"), birth: a)
            let capture = try model.capture(a, at: snapshot)
            nv_faults_hold(Int32(NV_FAULT_COMMIT_END), 1)
            let saving = Task { try await session.persist(capture: capture) }
            await withCheckedContinuation { continuation in
                DispatchQueue(label: "NVStorageProbe.commit-barrier").async {
                    nv_faults_wait_until_held(); continuation.resume()
                }
            }
            defer { nv_faults_release() }
            // The real COMMIT has completed; the runtime's serial writer is still held.
            if command == "held-owner-loss" {
                let pending = model.pending[a]
                try FileManager.default.moveItem(atPath: directory, toPath: directory + ".held")
                nv_faults_release()
                guard case .pending(let handle, .ownership) = try await saving.value,
                      model.pending[a] == pending else { throw StorageError.integrity }
                do { try await session.quiesce(); throw StorageError.integrity }
                catch StorageError.busy { }
                try FileManager.default.moveItem(atPath: directory + ".held", toPath: directory)
                guard case .accepted(let receipt) = try await session.retry(commit: handle) else { throw StorageError.incomplete }
                try model.complete(receipt)
                guard model.pending[a] == nil else { throw StorageError.integrity }
                try await session.quiesce()
                try output(["lost_owner_not_acknowledged": true, "recovered_exact_commit": receipt.sequence == 2]); return
            }
            saving.cancel()
            if args.count == 4 && args[3] == "delete" { _ = try model.delete(a) }
            else { _ = try model.put(value("newer pending"), birth: a) }
            let newer = model.pending[a]
            do { _ = try await session.persist(capture: capture); throw StorageError.integrity }
            catch StorageError.busy { }
            let quitting = Task { try await session.quiesce() }
            nv_faults_release()
            guard case .accepted(let receipt) = try await saving.value else { throw StorageError.incomplete }
            try model.complete(receipt)
            guard model.pending[a] == newer else { throw StorageError.integrity }
            try await quitting.value
            try output(["cancelled_waiter_committed": true, "newer_pending": true, "sequence": receipt.sequence])
            return
        } else if command == "edit" || command == "delete" {
            let a = try NoteBirth(bytes: Array(repeating: 1, count: 16))
            let generation = try CapturedNoteGeneration(birth: a, generation: 1)
            let capture = try CapturedActionGroup(snapshot: snapshot, kind: command == "delete" ? .deleteBatch : .savedEdit,
                changes: command == "delete" ? [.delete(generation)] : [.put(generation, value("edited"))])
            if args.count == 6 { nv_faults_arm(Int32(args[3])!, Int32(args[4])!, Int32(args[5])!) }
            let result = try await session.persist(capture: capture)
            let hits = nv_faults_hits()
            switch result {
            case .accepted(let receipt): try output(["initial": "accepted", "sequence": receipt.sequence, "hits": hits])
            case .pending(let handle, let error):
                nv_faults_arm(0, 0, 0)
                do { try await session.quiesce(); throw StorageError.integrity }
                catch StorageError.busy { }
                guard case .accepted(let receipt) = try await session.retry(commit: handle) else { throw StorageError.incomplete }
                try output(["initial": "pending", "sequence": receipt.sequence, "error": String(describing: error), "hits": hits])
            }
        } else if command == "seed-empty" {
            guard args.count == 4, let count = Int(args[3]), count >= 0 else { throw StorageError.unsupported }
            var parent = snapshot.context.operations[0].locator
            let writer = try WriterEpoch(bytes: Array(repeating: 77, count: 16))
            for n in 0..<count {
                let payload = try ChangesPayloadV1(dependencies: DependencyLocatorTable([parent]), operations: [], actions: [])
                let bytes = try ObjectEnvelopeV1.seal(payload: payload.encodedV1(), kind: .changes, collection: selection.descriptor.collection,
                    writer: writer, sequence: UInt64(n), protection: protection)
                _ = try await session.receive(bytes)
                parent = try ObjectEnvelopeV1.open(bytes, collection: selection.descriptor.collection, protection: protection).locator
            }
            try output(["added": count])
        } else { throw StorageError.unsupported }
        try await session.quiesce()
    }
}
