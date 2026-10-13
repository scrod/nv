import Foundation
import Crypto
import NVStorageCore
import NVStorageRuntime
import CSQLCipher
import CStorageFaults

/// Fresh processes receive surviving selection/unlock inputs and explicit repository choices.
func runCollectionStartupProbe(_ args: [String]) async throws -> Bool {
    guard let command = args.first, command.hasPrefix("startup-") else { return false }
    guard nv_faults_install() == SQLITE_OK else { throw StorageError.unsupported }
    if command == "startup-create", args.count == 6 {
        let encrypted = args[4] == "encrypted"
        let protection: ObjectProtectionV1 = encrypted ? .encrypted(keyID: try .init(bytes: Array(repeating: 3, count: 16)),
            key: SymmetricKey(data: Array(repeating: 4, count: 32))) : .publicHash
        let owner = try await CollectionSession.create(repository: URL(fileURLWithPath: args[3]),
            intent: args[5] == "new" ? .createNewDirectory : .createInExistingDirectory,
            privateDirectory: args[1], collection: .init(bytes: Array(repeating: 1, count: 16)),
            notes: [(NoteBirth(bytes: Array(repeating: 1, count: 16)), value("initial")),
                    (NoteBirth(bytes: Array(repeating: 2, count: 16)), value("untouched"))],
            protection: protection, passphrase: encrypted ? "probe password" : nil)
        let selected = await owner.selection
        try JSONEncoder().encode(SelectionFile(store: selected.store.bytes, descriptor: selected.descriptor.encodedBytes))
            .write(to: URL(fileURLWithPath: args[2]))
        let state = try await owner.publish(owner.preparePublication(liveGeneration: 1), liveGeneration: 1) { $0 }
        try await owner.close()
        try output(["notes": state.notes.map { ["birth": hex($0.birth.bytes), "body": $0.value.body.string] }, "through": state.through])
        return true
    }
    guard args.count >= 3 else { throw StorageError.unsupported }
    let selected = try JSONDecoder().decode(SelectionFile.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
    let selection = try selected.selection(args[1])
    let protection: ObjectProtectionV1 = try selection.descriptor.keyID.map {
        try .encrypted(keyID: $0, key: selection.descriptor.unwrap(passphrase: "probe password"))
    } ?? .publicHash
    if command == "startup-bootstrap", args.count == 7 {
        let snapshot = try SegmentLocator.decodeV1(unhex(args[4]))
        let entry: CollectionBootstrapSession
        if args[6] == "resume" {
            entry = try await .resume(repository: URL(fileURLWithPath: args[3]), selection: selection, snapshot: snapshot, protection: protection)
        } else {
            entry = try await .open(repository: URL(fileURLWithPath: args[3]), privateDirectory: selection.directory,
                descriptor: selection.descriptor, snapshot: snapshot, protection: protection)
            let actual = await entry.selection
            try JSONEncoder().encode(SelectionFile(store: actual.store.bytes, descriptor: actual.descriptor.encodedBytes))
                .write(to: URL(fileURLWithPath: args[2]))
        }
        var ended = false
        for _ in 0..<10000 { if try await entry.discover(budget: 3).passEnded { ended = true; break } }
        guard ended else { throw StorageError.limit }
        if args[5] == "preview" {
            let preview = try await entry.preview()
            try await entry.close()
            try output(["readOnly": true, "notes": preview.notes.map { ["birth": hex($0.birth.bytes), "body": $0.value.body.string] }])
        } else {
            let owner = try await entry.complete()
            let state = try await owner.publish(owner.preparePublication(liveGeneration: 1), liveGeneration: 1) { $0 }
            try await owner.close()
            try output(["readOnly": false, "notes": state.notes.map { ["birth": hex($0.birth.bytes), "body": $0.value.body.string] }])
        }
        return true
    }
    let opened = await CollectionSession.open(selection: selection, protection: protection)
    guard case .opened(let owner) = opened else {
        try output(["recovery": String(describing: opened.recoveryRequest?.kind)]); return true
    }
    var failure: String?
    switch command {
    case "startup-bind":
        guard args.count == 4 || args.count == 7 else { throw StorageError.unsupported }
        if args.count == 7 { nv_faults_arm_on_association(Int32(args[4])!, Int32(args[5])!, Int32(args[6])!) }
        do { try await owner.reopenRepository(at: URL(fileURLWithPath: args[3]), descriptor: selection.descriptor) }
        catch { failure = String(describing: error) }
    case "startup-open", "startup-apply": break
    default: throw StorageError.unsupported
    }
    let decision = await owner.decision()
    let state: StoreSnapshot?
    switch decision {
    case .ready, .editable: state = try await owner.publish(owner.preparePublication(liveGeneration: 1), liveGeneration: 1) { $0 }
    case .waiting, .recovery, .contention, .transition, .closed: state = nil
    }
    if command == "startup-apply", args.count == 5 {
        guard state != nil else { throw StorageError.incomplete }
        let deletion = args[3] == "delete"
        let generation = try CapturedNoteGeneration(birth: NoteBirth(bytes: Array(repeating: deletion ? 2 : 1, count: 16)), generation: 1)
        let change: CapturedNoteChange = deletion ? .delete(generation) : .put(generation, try value(args[4]))
        let capture = try await owner.capture(kind: deletion ? .deleteBatch : .savedEdit, changes: [change])
        guard case .accepted(let receipt) = try await owner.persist(capture) else { throw StorageError.incomplete }
        let current = try await owner.publish(owner.preparePublication(liveGeneration: 2), liveGeneration: 2) { $0 }
        try await owner.close()
        try output(["object": hex(receipt.object.encodedV1()), "notes": current.notes.map { ["birth": hex($0.birth.bytes), "body": $0.value.body.string] },
            "context": hex(current.context.encodedV1()), "through": current.through])
        return true
    }
    try await owner.close()
    try output(["decision": String(describing: decision), "failure": failure as Any? ?? NSNull(),
        "hits": nv_faults_hits(), "notes": state?.notes.map { ["birth": hex($0.birth.bytes), "body": $0.value.body.string] } as Any? ?? NSNull(),
        "context": state.map { hex($0.context.encodedV1()) } as Any? ?? NSNull()])
    return true
}
