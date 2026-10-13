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
func unhex(_ text: String) -> [UInt8] {
    let chars = Array(text)
    return stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0+1]), radix: 16)! }
}

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

/// Writes independently sealed incoming snapshots for child-process receive schedules.
actor ProbeSnapshotFiles {
    let collection: CollectionID
    let protection: ObjectProtectionV1
    let directory: URL
    let writer = try! WriterEpoch(bytes: withUnsafeBytes(of: UUID().uuid) { Array($0) })
    var sequence: UInt64 = 0
    var files: [[String: Any]] = []
    init(collection: CollectionID, protection: ObjectProtectionV1, directory: URL) {
        self.collection = collection; self.protection = protection; self.directory = directory
    }
    func emit(_ kind: ProviderObjectKind, _ payload: [UInt8]) throws -> SegmentLocator {
        let bytes = try ObjectEnvelopeV1.seal(payload: payload, kind: kind, collection: collection, writer: writer, sequence: sequence, protection: protection)
        sequence += 1
        let locator = try ObjectEnvelopeV1.open(bytes, collection: collection, protection: protection).locator
        let file = directory.appendingPathComponent(hex(locator.segmentID.bytes) + ".object")
        try Data(bytes).write(to: file)
        files.append(["id": hex(locator.segmentID.bytes), "file": file.path, "kind": kind.rawValue, "locator": hex(locator.encodedV1())])
        return locator
    }
    func manifest() -> [[String: String]] {
        files.map { row in ["id": row["id"] as! String, "file": row["file"] as! String, "kind": String(row["kind"] as! UInt8), "locator": row["locator"] as! String] }
    }
}

func armProbeFault(_ args: [String], at index: Int) {
    let event = Int32(args[index])!, ordinal = Int32(args[index + 1])!, result = Int32(args[index + 2])!
    switch args.count > index + 3 ? args[index + 3] : "retention" {
    case "acceptance": nv_faults_arm_on_history_acceptance(event, ordinal, result)
    case "parking": nv_faults_arm_on_parking(event, ordinal, result)
    case "rejection": nv_faults_arm_on_rejection(event, ordinal, result)
    case "materialization": nv_faults_arm_on_materialization(event, ordinal, result)
    default: nv_faults_arm(event, ordinal, result)
    }
}

/// Reads exact SQL rows for independent retention, acceptance and recovery observations.
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
        if try await runRepositoryRootProbe(args) { return }
        if try await runRepositoryFilesProbe(args) { return }
        if try await runRepositoryExchangeProbe(args) { return }
        if try await runRepositoryDriverProbe(args) { return }
        if try await runCollectionControllerProbe(args) { return }
        if try await runCollectionStartupProbe(args) { return }
        if args.count == 4, args[0] == "seed-pair" {
            let protection: ObjectProtectionV1 = args[2] == "encrypted" ? .encrypted(keyID: try .init(bytes: Array(repeating: 3, count: 16)), key: SymmetricKey(data: Array(repeating: 4, count: 32))) : .publicHash
            let initial = try InitialCollectionV1.build(collection: CollectionID(bytes: Array(repeating: 1, count: 16)),
                notes: [(NoteBirth(bytes: Array(repeating: 1, count: 16)), value(args[3])), (NoteBirth(bytes: Array(repeating: 2, count: 16)), value("untouched"))],
                protection: protection, passphrase: args[2] == "encrypted" ? "probe password" : nil)
            var report: [String: String] = [:]
            for side in ["left", "right", "third"] {
                let owner = try await LocalStoreSession.create(directory: args[1] + "/" + side, initial: initial, protection: protection)
                let selection = await owner.selection
                report[side] = String(decoding: try JSONEncoder().encode(SelectionFile(store: selection.store.bytes, descriptor: selection.descriptor.encodedBytes)), as: UTF8.self)
                try await owner.quiesce()
            }
            try output(report); return
        }
        if args.count == 3, args[0] == "merge-pair" {
            let encrypted = args[2] == "encrypted"
            let protection: ObjectProtectionV1 = encrypted ? .encrypted(keyID: try CollectionKeyID(bytes: Array(repeating: 3, count: 16)),
                key: SymmetricKey(data: Array(repeating: 4, count: 32))) : .publicHash
            let collection = try CollectionID(bytes: Array(repeating: 1, count: 16)), birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
            let initial = try InitialCollectionV1.build(collection: collection, notes: [(birth, value("a\ngap\nz"))],
                protection: protection, passphrase: encrypted ? "probe password" : nil)
            var report: [String: Any] = [:]
            for (side, body) in [("left", "A\ngap\nz"), ("right", "a\ngap\nZ")] {
                let store = try await LocalStoreSession.create(directory: args[1] + "/" + side, initial: initial, protection: protection)
                let capture = try await CapturedActionGroup(snapshot: store.snapshot(), kind: .savedEdit,
                    changes: [.put(CapturedNoteGeneration(birth: birth, generation: 1), value(body))])
                guard case .accepted(let receipt) = try await store.persist(capture: capture) else { throw StorageError.incomplete }
                let selection = await store.selection
                let selected = SelectionFile(store: selection.store.bytes, descriptor: selection.descriptor.encodedBytes)
                let state = try await store.snapshot()
                report[side] = ["selection": String(decoding: try JSONEncoder().encode(selected), as: UTF8.self),
                    "envelope": hex(try await store.retainedObject(at: receipt.object)), "head": hex(state.notes[0].revision.id.bytes)]
                try await store.quiesce()
            }
            try output(report); return
        }
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
        if command == "bootstrap-seed" {
            let encrypted = args[2] == "encrypted", count = Int(args[5])!
            let protection: ObjectProtectionV1 = encrypted ? .encrypted(keyID: try CollectionKeyID(bytes: Array(repeating: 3, count: 16)),
                key: SymmetricKey(data: Array(repeating: 4, count: 32))) : .publicHash
            let notes = try (0..<count).map { n -> (NoteBirth, PlaintextNoteValue) in
                var bytes = [UInt8](repeating: 0, count: 16); bytes[0] = 10
                bytes[14] = UInt8(n >> 8); bytes[15] = UInt8(n & 255)
                return try (NoteBirth(bytes: bytes), value("initial-\(n)"))
            }
            var writer = try InitialCollectionWriterV1(collection: CollectionID(bytes: Array(repeating: 1, count: 16)),
                notes: notes, protection: protection, passphrase: encrypted ? "probe password" : nil, targetBytes: 4096, notesPerAction: 3)
            let input = URL(fileURLWithPath: args[4]); try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
            var manifest: [String: String] = [:]
            while let envelope = try writer.next() {
                let filename = hex(envelope.locator.segmentID.bytes) + ".object"
                try Data(envelope.bytes).write(to: input.appendingPathComponent(filename))
                manifest[hex(envelope.locator.encodedV1())] = filename
            }
            guard let root = writer.snapshot else { throw StorageError.incomplete }
            let selection = try LocalStoreSelection(directory: directory, store: LocalStoreID(bytes: withUnsafeBytes(of: UUID().uuid) { Array($0) }), descriptor: writer.descriptor)
            try JSONEncoder().encode(SelectionFile(store: selection.store.bytes, descriptor: writer.descriptor.encodedBytes)).write(to: URL(fileURLWithPath: args[3]))
            try JSONSerialization.data(withJSONObject: ["root": hex(root.encodedV1()), "objects": manifest], options: [.sortedKeys]).write(to: input.appendingPathComponent("manifest.json"))
            let candidate = try await BootstrapCandidate.create(selection: selection, snapshot: root, protection: protection)
            try await candidate.close(); try output(["objects": manifest.count]); return
        }
        if command == "create" || command == "current-seed" {
            let encrypted = args[2] == "encrypted"
            let collection = try CollectionID(bytes: Array(repeating: 1, count: 16))
            let protection: ObjectProtectionV1 = encrypted ? try .encrypted(keyID: CollectionKeyID(bytes: Array(repeating: 3, count: 16)), key: SymmetricKey(data: [UInt8](repeating: 4, count: 32))) : .publicHash
            let notes: [(NoteBirth, PlaintextNoteValue)]
            if command == "current-seed" {
                notes = try (1...32).map { index in
                    (try NoteBirth(bytes: Array(repeating: UInt8(index), count: 16)), try value(currentProbeBody(index)))
                }
            } else {
                notes = try [(NoteBirth(bytes: Array(repeating: 1, count: 16)), value("A")),
                             (NoteBirth(bytes: Array(repeating: 2, count: 16)), value("untouched"))]
            }
            let initial = try InitialCollectionV1.build(collection: collection, notes: notes,
                protection: protection, passphrase: encrypted ? "probe password" : nil)
            let store = try LocalStoreID(bytes: withUnsafeBytes(of: UUID().uuid) { Array($0) })
            let selectionData = try JSONEncoder().encode(SelectionFile(store: store.bytes, descriptor: initial.descriptor.encodedBytes))
            if args.count >= 4 { try selectionData.write(to: URL(fileURLWithPath: args[3]), options: .atomic) }
            if args.count >= 7 { armProbeFault(args, at: 4) }
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
        if command == "bootstrap-retain" || command == "bootstrap-complete" {
            let input = URL(fileURLWithPath: args[3])
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: input.appendingPathComponent("manifest.json"))) as! [String: Any]
            let candidate = try await BootstrapCandidate.resume(selection: selection, protection: protection)
            if command == "bootstrap-retain" {
                let objects = manifest["objects"] as! [String: String]
                let names = args.count > 4 ? Array(args.dropFirst(4)) : objects.values.sorted().reversed().map { $0 }
                for name in names { _ = try await candidate.retain(Array(Data(contentsOf: input.appendingPathComponent(name)))) }
                try await candidate.close(); try output(["retained": names.count]); return
            }
            if args.count >= 7 { armProbeFault(args, at: 4) }
            let session = try await candidate.complete(snapshot: SegmentLocator.decodeV1(unhex(manifest["root"] as! String)))
            let state = try await session.snapshot()
            try await session.quiesce(); try output(["notes": state.notes.count, "through": state.through, "hits": nv_faults_hits()]); return
        }
        if command == "invalidate-view" {
            let inspector = try Inspector(selection, protection: protection)
            _ = try inspector.rows("BEGIN IMMEDIATE")
            _ = try inspector.rows("DELETE FROM current_notes")
            _ = try inspector.rows("DELETE FROM view_meta")
            _ = try inspector.rows("INSERT INTO private_groups VALUES(X'7333342D73656E74696E656C',9,1,X'01020304')")
            _ = try inspector.rows("COMMIT")
            try output(["invalidated": true]); return
        }
        if command == "abandon-session" {
            let mode = args.count == 5 ? args[4] : "abandon"
            try await abandonSession(selection: selection, protection: protection, body: args[3], mode: mode)
            // Observe final actor disposal before async-main hands control to process exit handlers.
            try await drainAbandonedOwner(selection: selection, protection: protection)
            return
        }
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
        if command == "verify-interrupt" {
            let session = try await LocalStoreSession.open(selection: selection, protection: protection)
            let bytes = try [UInt8](Data(contentsOf: URL(fileURLWithPath: args[3])))
            let locator = try ObjectEnvelopeV1.open(bytes, collection: selection.descriptor.collection, protection: protection).locator
            nv_faults_arm(Int32(args[4])!, Int32(args[5])!, Int32(args[6])!)
            guard try await session.retainedObject(at: locator) == bytes else { throw StorageError.integrity }
            try output(["verified": true]); try await session.quiesce(); return
        }
        if command == "verify-recovery-failure" {
            nv_faults_arm_on_verification_settlement(Int32(NV_FAULT_WRITE), 1, SQLITE_FULL)
            do { _ = try await LocalStoreSession.open(selection: selection, protection: protection); throw StorageError.unsupported }
            catch StorageError.database(let code) {
                guard code & 0xff == SQLITE_FULL, nv_faults_hits() > 0 else { throw StorageError.incomplete }
                nv_faults_arm(0, 0, 0); try output(["recovery_write_failed": true]); return
            }
        }
        if command == "diagnose-old-damage" {
            let session = try await LocalStoreSession.open(selection: selection, protection: protection)
            let prepared = try await session.prepareReduction(liveGeneration: 1)
            let bytes = try [UInt8](Data(contentsOf: URL(fileURLWithPath: args[3])))
            let locator = try ObjectEnvelopeV1.open(bytes, collection: selection.descriptor.collection, protection: protection).locator
            let inspector = try Inspector(selection, protection: protection)
            guard try inspector.rows("SELECT 1 FROM retained_frontier WHERE object_id=X'" + hex(locator.segmentID.bytes) + "'").isEmpty else { throw StorageError.integrity }
            _ = try inspector.rows("DROP TRIGGER objects_no_update")
            _ = try inspector.rows("UPDATE objects SET encoded=X'00' WHERE object_id=X'" + hex(locator.segmentID.bytes) + "'")
            nv_faults_arm_on_damage(Int32(NV_FAULT_WRITE), 1, SQLITE_FULL)
            do { _ = try await session.retainedObject(at: locator); throw StorageError.unsupported }
            catch CanonicalEncodingError.lengthLimit { }
            guard nv_faults_hits() > 0 else { throw StorageError.incomplete }
            for _ in 0..<2 {
                nv_faults_arm(Int32(NV_FAULT_WRITE), 1, SQLITE_FULL)
                do { _ = try await session.publish(prepared, liveGeneration: 1) { $0.notes.count }; throw StorageError.unsupported }
                catch StorageError.integrity { }
                guard nv_faults_hits() > 0 else { throw StorageError.incomplete }
            }
            nv_faults_arm(0, 0, 0)
            guard try inspector.rows("SELECT 1 FROM private_groups WHERE group_key=X'686973746F72792D64616D616765'").isEmpty else { throw StorageError.integrity }
            try output(["nonfrontier": true, "live_publication_blocked": true, "marker_failed": true])
            // Ends the process before a later successful marker write can conceal the interrupted diagnosis.
            _exit(86)
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
            if repeatedFailure { nv_faults_arm_on_damage(Int32(NV_FAULT_WRITE), 1, ioCode) }
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
                if args.count == 7 || args.count == 8 { armProbeFault(args, at: 4) }
                let outcome = try await session.receive(bytes)
                switch outcome {
                case .pendingValidation: try output(["status": "pending-validation"])
                case .blocked(let reasons, let unaccepted):
                    try output(["status": "blocked", "rejections": reasons.map { ["id": hex($0.object.bytes), "reason": String($0.reason.rawValue)] }, "unaccepted": unaccepted.count])
                case .waiting(let missing): try output(["status": "waiting", "missing": missing.count, "hits": nv_faults_hits()])
                case .retainedForAssembly: try output(["status": "retained", "hits": nv_faults_hits()])
                case .accepted(let sequence): try output(["status": "accepted", "sequence": sequence, "hits": nv_faults_hits()])
                }
            } else {
                guard args.count == 6, let n = UInt8(args[4]) else { throw StorageError.unsupported }
                let generation = try CapturedNoteGeneration(birth: NoteBirth(bytes: Array(repeating: n, count: 16)), generation: 1)
                let kind: OrdinaryActionKind, change: CapturedNoteChange
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
                if command == "receive-file", args.count >= 7 {
                    let hits = nv_faults_hits(); nv_faults_arm(0, 0, 0)
                    try output(["status": "failed", "error": String(describing: error), "hits": hits])
                    try? await session.quiesce(); return
                }
                try? await session.quiesce()
                throw error
            }
        }
        if command == "merge-inspect" {
            let inspector = try Inspector(selection, protection: protection)
            let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
            let rows = try inspector.rows("SELECT hex(encoded) FROM objects JOIN accepted_objects USING(object_id) WHERE kind=1")
            var byID: [OperationID: IdentifiedOperation] = [:]
            for row in rows {
                let envelope = try ObjectEnvelopeV1.open(unhex(row[0]), collection: selection.descriptor.collection, protection: protection)
                for record in try ChangesPayloadV1.decodeV1(envelope.payload).operations where record.operation.effect.targetBirth == birth {
                    if let prior = byID[record.operation.id], prior != record.operation { throw StorageError.integrity }
                    byID[record.operation.id] = record.operation
                }
            }
            let reduction = try NoteReductionV1.compute(collection: selection.descriptor.collection, birth: birth, operations: Array(byID.values))
            guard case .current(let result) = reduction.outcome, let merge = result.merge else { throw StorageError.incomplete }
            try output(["body": result.value.body.string, "heads": reduction.heads.map { hex($0.bytes) },
                "base": hex(merge.base.bytes), "identity": hex(merge.id.bytes), "preimage": hex(merge.identityPreimageV1()),
                "value": hex(result.value.encodedV1()), "birth": hex(birth.bytes), "collection": hex(selection.descriptor.collection.bytes),
                "operations": byID.count, "actions": inspector.rows("SELECT count(*) FROM actions")[0][0]])
            return
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
                    "settings-version": "UPDATE private_groups SET codec=99 WHERE group_key=X'73657474696E6773'",
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
            report["restorations"] = try inspector.rows("SELECT hex(source_birth),hex(deletion_action),hex(action_id) FROM restorations ORDER BY source_birth,deletion_action")
            report["cells"] = try inspector.rows("SELECT hex(birth),hex(cell) FROM current_notes ORDER BY birth")
            report["dictionaries"] = try inspector.rows("SELECT hex(dictionary_id),hex(encoded) FROM current_dictionaries ORDER BY dictionary_id")
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
        if command == "open-crash", args.count == 6 || args.count == 7 {
            armProbeFault(args, at: 3)
        }
        let session = try await LocalStoreSession.open(selection: selection, protection: protection)
        let snapshot = try await session.snapshot()
        if command == "publish-drain" || command == "publish-drain-crash" {
            if command == "publish-drain-crash" { armProbeFault(args, at: 3) }
            let published = try await session.publish(session.prepareReduction(liveGeneration: 0), liveGeneration: 0) { $0 }
            let inspector = try Inspector(selection, protection: protection)
            // Observe durable queue settlement and current-row catch-up without driving the worker.
            let deadline = Date().addingTimeInterval(30)
            while try !inspector.rows("SELECT 1 WHERE EXISTS(SELECT 1 FROM ready_objects) OR NOT EXISTS(SELECT 1 FROM view_meta WHERE singleton=1 AND through_seq=(SELECT COALESCE(MAX(seq),0) FROM acceptance_batches))").isEmpty {
                guard Date() < deadline else { throw StorageError.incomplete }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            let final = try await session.snapshot()
            try output(["publishedThrough": published.through, "through": final.through,
                "publishedNotes": published.notes.map { $0.value.body.string }.sorted(),
                "notes": final.notes.map { ["birth": hex($0.birth.bytes), "body": $0.value.body.string, "cell": hex($0.encodedV1())] },
                "context": hex(final.context.encodedV1()), "steps": nv_faults_steps()])
            try await session.quiesce(); return
        }
        if try await privateCommand(args, session: session, protection: protection) { return }
        if try await currentMaintenanceCommand(args, session: session) { return }
        if command == "snapshot-export" {
            let destination = URL(fileURLWithPath: args[3])
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let capture = try await session.captureGeneralSnapshot()
            let sink = ProbeSnapshotFiles(collection: selection.descriptor.collection, protection: protection, directory: destination)
            let root = try await GeneralSnapshotV1.write(records: capture.records, bootstrapSnapshot: capture.bootstrapSnapshot,
                retentionParents: capture.retentionParents, chunkBytes: 256, fanout: 2) { try await sink.emit($0, $1) }
            let bad = try await sink.emit(.snapshotRoot, [])
            try output(["root": hex(root.segmentID.bytes), "bad": hex(bad.segmentID.bytes), "files": await sink.manifest()])
            try await session.quiesce(); return
        }
        if command == "snapshot-series" {
            guard args.count == 4, let count = Int(args[3]), count > 0, count <= 256 else { throw StorageError.limit }
            var roots: [String] = []
            for _ in 0..<count {
                guard case .accepted(let receipt) = try await session.persistGeneralSnapshot(capture: session.captureGeneralSnapshot()) else {
                    throw StorageError.incomplete
                }
                roots.append(hex(receipt.snapshot.segmentID.bytes))
            }
            try output(["roots": roots, "through": try await session.snapshot().through])
            try await session.quiesce(); return
        }
        if command == "snapshot-save" || command == "snapshot-candidate" {
            let capture = try await session.captureGeneralSnapshot()
            if args.count == 6 {
                let event = Int32(args[3])!, ordinal = Int32(args[4])!, code = Int32(args[5])!
                if command == "snapshot-save", event != NV_FAULT_VIEW_UPDATE && event != NV_FAULT_CURRENT_INSERT {
                    nv_faults_arm_on_history_acceptance(event, ordinal, code)
                } else { nv_faults_arm(event, ordinal, code) }
            }
            let result = try await session.persistGeneralSnapshot(capture: capture)
            let receipt: AcceptedSnapshotReceipt, status: String, failure: String, hits = nv_faults_hits()
            switch result {
            case .accepted(let saved): receipt = saved; status = "accepted"; failure = ""
            case .pending(let handle, let error):
                status = "pending"; failure = String(describing: error); nv_faults_arm(0, 0, 0)
                guard case .accepted(let saved) = try await session.retry(snapshot: handle) else { throw StorageError.incomplete }
                receipt = saved
            }
            try output(["initial": status, "error": failure, "hits": hits, "sequence": receipt.sequence,
                "root": hex(receipt.snapshot.segmentID.bytes), "pages": receipt.pages.map { hex($0.segmentID.bytes) }.sorted()])
            try await session.quiesce(); return
        }
        if command == "semantic" {
            guard args.count == 4 || args.count == 7,
                  let request = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[3]))) as? [String: Any],
                  let kind = request["kind"] as? String else { throw StorageError.unsupported }
            let birth = try NoteBirth(bytes: unhex(request["birth"] as? String ?? String(repeating: "01", count: 16)))
            let capture: CapturedActionGroup?
            var compensation: CompensationPreparation?
            switch kind {
            case "put", "delete":
                let generation = try CapturedNoteGeneration(birth: birth, generation: 1)
                capture = try CapturedActionGroup(snapshot: snapshot, kind: kind == "put" ? .savedEdit : .deleteBatch,
                    changes: kind == "put" ? [.put(generation, value(request["body"] as! String))] : [.delete(generation)])
            case "copy", "choose":
                let revision = try OperationID(bytes: unhex(request["revision"] as! String))
                capture = try await kind == "copy" ? session.copyVersion(for: birth, revision: revision, generation: 1) : session.chooseVersion(for: birth, revision: revision, generation: 1)
            case "undo", "redo":
                let scope: ActionScopeV1 = request["collection"] as? Bool == true ? .collection : .note(birth)
                let candidate = try (request["candidate"] as? String).map { try ActionID(bytes: unhex($0)) }
                switch try await session.prepareCompensation(scope: scope, direction: kind == "undo" ? .undo : .redo, candidate: candidate) {
                case .automatic(let prepared): compensation = .automatic(prepared)
                case .review(let prepared): compensation = .review(prepared)
                case .noEffect: try output(["initial": "no-effect"]); try await session.quiesce(); return
                default: throw StorageError.incomplete
                }
                capture = nil
            case "restore":
                let source = try NoteBirth(bytes: unhex(request["source"] as! String))
                let entry = try await session.history(for: .deletions).entries.first { $0.birth == source }
                guard let entry else { throw StorageError.incomplete }
                let restored = try await session.restoration(from: entry, as: .init(birth: birth, generation: 1))
                capture = try CapturedActionGroup(snapshot: snapshot, restoring: [restored])
            case "native":
                let steps = try (request["steps"] as! [[String: Any]]).map { step in
                    try NativeCompensationStep(value: value(step["body"] as! String), coverage: (step["coverage"] as! [[String: Any]]).map { record in
                        try .init(action: ActionID(bytes: unhex(record["action"] as! String)), complete: record["complete"] as! Bool)
                    })
                }
                capture = try await session.nativeCompensation(for: birth, steps: steps, generation: 1)
            default: throw StorageError.unsupported
            }
            if args.count == 7 {
                let event = Int32(args[4])!, ordinal = Int32(args[5])!, code = Int32(args[6])!
                if event == NV_FAULT_VIEW_UPDATE || event == NV_FAULT_CURRENT_INSERT {
                    nv_faults_arm(event, ordinal, code)
                } else { nv_faults_arm_on_history_acceptance(event, ordinal, code) }
            }
            let outcome: CommitOutcome
            switch compensation {
            case .automatic(let prepared):
                outcome = try await request["review"] as? Bool == true ? session.applyReviewedCompensation(prepared.forReview()) : session.applyCompensation(prepared)
            case .review(let review):
                guard request["review"] as? Bool == true else { throw StorageError.staleCapture }
                outcome = try await session.applyReviewedCompensation(review)
            default: outcome = try await session.persist(capture: capture!)
            }
            let receipt: AcceptedHistoryReceipt, initial: String, error: String, hits = nv_faults_hits()
            switch outcome {
            case .accepted(let saved): receipt = saved; initial = "accepted"; error = ""
            case .pending(let handle, let failure):
                initial = "pending"; error = String(describing: failure); nv_faults_arm(0, 0, 0)
                guard case .accepted(let saved) = try await session.retry(commit: handle) else { throw StorageError.incomplete }; receipt = saved
            }
            let bytes = try await session.retainedObject(at: receipt.object)
            let payload = try ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(bytes, collection: selection.descriptor.collection, protection: protection).payload)
            try output(["initial": initial, "error": error, "hits": hits, "sequence": receipt.sequence, "envelope": hex(bytes),
                "births": receipt.covered.map { hex($0.birth.bytes) }, "action": hex(payload.actions[0].action.id.bytes), "operations": payload.operations.map { hex($0.operation.id.bytes) }])
            try await session.quiesce(); return
        } else if command == "candidates" {
            let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
            let scope: ActionScopeV1 = args.count == 4 && args[3] == "collection" ? .collection : .note(birth)
            let undo = try await session.undoCandidates(scope: scope, direction: .undo), redo = try await session.undoCandidates(scope: scope, direction: .redo)
            try output(["undo": undo.ids.map { hex($0.bytes) }, "redo": redo.ids.map { hex($0.bytes) },
                "undo_mode": String(describing: undo.mode), "redo_mode": String(describing: redo.mode)])
        } else if command == "conflicts" {
            let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16)), state = try await session.conflicts(for: birth)
            try output(["represented": state.current.represented.map { hex($0.id.bytes) }, "heads": state.current.heads.map { hex($0.id.bytes) },
                "alternatives": state.alternatives.map { hex($0.id.bytes) }, "dispositions": state.representedSeparately.map { hex($0.bytes) }.sorted()])
        } else if command == "recently-deleted" {
            var cursor: HistoryCursor?, rows: [[String: String]] = []
            repeat {
                let page = try await session.history(for: .recentlyDeleted, after: cursor, limit: 1)
                rows += page.entries.map { ["birth": hex($0.birth.bytes), "action": hex($0.action.bytes), "operation": hex($0.operation.bytes)] }
                cursor = page.continuation
            } while cursor != nil
            try output(rows)
        } else if command == "history" {
            let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
            var cursor: HistoryCursor?, rows: [[String: Any]] = []
            repeat {
                let page = try await session.history(for: .note(birth), after: cursor, limit: 1)
                for entry in page.entries {
                    let preview = try await session.preview(entry)
                    let op: IdentifiedOperation, body: String, prior: String
                    switch preview.state {
                    case .value(let value):
                        op = value; prior = ""
                        switch value.effect {
                        case .create(_, _, let v), .importNote(_, _, let v), .put(_, _, let v): body = v.body.string
                        default: throw StorageError.integrity
                        }
                    case .deleted(let deletion, let before):
                        op = deletion; prior = hex(before.id.bytes)
                        switch before.effect {
                        case .create(_, _, let v), .importNote(_, _, let v), .put(_, _, let v): body = v.body.string
                        default: throw StorageError.integrity
                        }
                    case .deletedState(let deletion, let before, let value):
                        op = deletion; prior = before.represented.map { hex($0.bytes) }.joined(separator: ","); body = value.body.string
                    }
                    rows.append(["id": hex(op.id.bytes), "action": hex(preview.action.id.bytes),
                        "body": body, "prior": prior, "parents": op.causalParents.ids.map { hex($0.bytes) },
                        "predecessors": op.notePredecessors.ids.map { hex($0.bytes) }])
                }
                cursor = page.continuation
            } while cursor != nil
            let deleted = try await session.history(for: .deletions)
            try output(["history": rows, "deletions": deleted.entries.map { hex($0.operation.bytes) },
                "through": snapshot.through])
        } else if command == "dump" || command == "open-crash" {
            try output(["through": snapshot.through, "notes": snapshot.notes.map { ["birth": hex($0.birth.bytes), "body": $0.value.body.string, "cell": hex($0.encodedV1())] },
                        "context": hex(snapshot.context.encodedV1()), "steps": nv_faults_steps()])
        } else if command == "held-completion" || command == "held-owner-loss" {
            let a = try NoteBirth(bytes: Array(repeating: 1, count: 16))
            var model = HeadlessModel(snapshot: snapshot)
            _ = try model.put(value("edited"), birth: a)
            let capture = try model.capture(a, at: snapshot)
            nv_faults_hold(Int32(NV_FAULT_COMMIT_END), 1)
            nv_faults_arm_on_history_acceptance(Int32(NV_FAULT_COMMIT_END), 1, -2)
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
        } else if ["edit", "delete", "restore", "delete-restored"].contains(command) {
            let a = try NoteBirth(bytes: Array(repeating: command == "delete-restored" ? 3 : 1, count: 16))
            let generation = try CapturedNoteGeneration(birth: a, generation: 1)
            let capture: CapturedActionGroup
            if command == "restore" {
                guard let entry = try await session.history(for: .deletions).entries.first(where: { $0.birth == a }) else { throw StorageError.incomplete }
                let source = try await session.restoration(from: entry,
                    as: CapturedNoteGeneration(birth: NoteBirth(bytes: Array(repeating: 3, count: 16)), generation: 1))
                capture = try CapturedActionGroup(snapshot: snapshot, restoring: [source])
            } else {
                capture = try CapturedActionGroup(snapshot: snapshot, kind: command == "edit" ? .savedEdit : .deleteBatch,
                    changes: command == "edit" ? [.put(generation, value("edited"))] : [.delete(generation)])
            }
            if args.count == 6 || args.count == 7 {
                armProbeFault(args, at: 3)
            }
            let result = try await session.persist(capture: capture)
            let hits = nv_faults_hits()
            switch result {
            case .accepted(let receipt): try output(["initial": "accepted", "sequence": receipt.sequence, "hits": hits])
            case .pending(let handle, let error):
                nv_faults_arm(0, 0, 0)
                let stillVisible = try await session.history(for: .recentlyDeleted).entries.contains { $0.birth == a }
                do { try await session.quiesce(); throw StorageError.integrity }
                catch StorageError.busy { }
                guard case .accepted(let receipt) = try await session.retry(commit: handle) else { throw StorageError.incomplete }
                try output(["initial": "pending", "sequence": receipt.sequence, "error": String(describing: error), "hits": hits,
                    "source_visible_before_retry": stillVisible])
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

    /// Drops a live owner after a saved action or an observed retryable write failure.
    private static func abandonSession(selection: LocalStoreSelection, protection: ObjectProtectionV1,
                                       body: String, mode: String) async throws {
        let session = try await LocalStoreSession.open(selection: selection, protection: protection)
        let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
        let capture = try await CapturedActionGroup(snapshot: session.snapshot(), kind: .savedEdit,
            changes: [.put(.init(birth: birth, generation: 1), value(body))])
        if mode == "write-error" || mode == "full" {
            nv_faults_arm_on_history_acceptance(Int32(NV_FAULT_WRITE), 1,
                mode == "write-error" ? SQLITE_IOERR | (3 << 8) : SQLITE_FULL)
            guard case .pending(_, .database) = try await session.persist(capture: capture),
                  nv_faults_hits() > 0 else { throw StorageError.incomplete }
            nv_faults_arm(0, 0, 0)
            do { try await session.quiesce(); throw StorageError.integrity }
            catch StorageError.busy { }
            try output(["pending": true, "close": "busy"])
        } else {
            guard case .accepted(let receipt) = try await session.persist(capture: capture) else { throw StorageError.incomplete }
            try output(["sequence": receipt.sequence, "object": hex(receipt.object.segmentID.bytes)])
            if mode == "quiesce" { try await session.quiesce() }
        }
    }

    /// Proves abandoned-owner lease release and drains the verifier before orderly process exit.
    private static func drainAbandonedOwner(selection: LocalStoreSelection, protection: ObjectProtectionV1) async throws {
        for _ in 0..<1_000 {
            do {
                let verifier = try await LocalStoreSession.open(selection: selection, protection: protection)
                try await verifier.quiesce()
                return
            } catch StorageError.ownership(let code) where code == EWOULDBLOCK || code == EAGAIN {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        throw StorageError.busy
    }
}
