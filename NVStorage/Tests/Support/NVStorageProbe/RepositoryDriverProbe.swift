import Foundation
import NVStorageCore
import NVStorageRuntime
import CSQLCipher
import CStorageFaults

struct DriverConfiguration: Decodable {
    let directory, selection, repository, input, output: String
    let mode, profile, snapshot, intent, evict: String?
}
struct DriverCommand: Decodable {
    let command: String
    let body: String?
    let birth: UInt8?
    let relative: String?
    let repository, locator: String?
}
private let driverControlQueue = DispatchQueue(label: "org.notationalvelocity.storage.contract-control")

/// Reads one owned FIFO message on a dedicated resource while transport actors continue running.
func driverCommand(_ input: FileHandle) async throws -> DriverCommand? {
    try await withCheckedThrowingContinuation { continuation in
        driverControlQueue.async {
            do {
                var bytes: [UInt8] = []
                while let next = try input.read(upToCount: 1), !next.isEmpty {
                    if next[0] == 10 { break }
                    guard bytes.count < 65536 else { throw StorageError.limit }
                    bytes.append(next[0])
                }
                continuation.resume(returning: bytes.isEmpty ? nil : try JSONDecoder().decode(DriverCommand.self, from: Data(bytes)))
            } catch { continuation.resume(throwing: error) }
        }
    }
}

/// Runs the production automatic driver through signed LaunchServices and fresh-process controllers.
func runRepositoryDriverProbe(_ args: [String]) async throws -> Bool {
    guard args.count == 2, args[0] == "exchange-driver" else { return false }
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
    let selected = try JSONDecoder().decode(SelectionFile.self, from: Data(contentsOf: URL(fileURLWithPath: config.selection)))
    let selection = try selected.selection(config.directory)
    let protection: ObjectProtectionV1 = try selection.descriptor.keyID.map {
        try .encrypted(keyID: $0, key: selection.descriptor.unwrap(passphrase: "probe password"))
    } ?? .publicHash
    let store = try await LocalStoreSession.open(selection: selection, protection: protection)
    try emit(["state": "store-opened"])
    let root = try await RepositoryRootSession.open(directory: config.repository)
    try emit(["state": "root-opened"])
    var driver = try await RepositoryTransportDriver.start(root: root, store: store)
    var generation: UInt64 = 0
    do {
        try emit(["state": "running", "pid": ProcessInfo.processInfo.processIdentifier])
        while let request = try await driverCommand(input) {
            let birth = try NoteBirth(bytes: .init(repeating: request.birth ?? 1, count: 16))
            switch request.command {
            case "state":
                let state = try await store.snapshot(), status = await driver.status()
                try emit(["through": state.through, "notes": state.notes.map {
                    ["birth": hex($0.birth.bytes), "body": $0.value.body.string, "cell": hex($0.encodedV1())]
                }, "context": hex(state.context.encodedV1()),
                    "discovery": String(describing: status.discovery), "publication": String(describing: status.publication)])
            case "put", "delete", "create":
                generation += 1
                let covered = try CapturedNoteGeneration(birth: birth, generation: generation)
                let kind: OrdinaryActionKind, change: CapturedNoteChange
                switch request.command {
                case "put": kind = .savedEdit; change = try .put(covered, value(request.body ?? ""))
                case "create": kind = .createImportBatch; change = try .create(covered, value(request.body ?? ""))
                default: kind = .deleteBatch; change = .delete(covered)
                }
                let capture = try await CapturedActionGroup(snapshot: store.snapshot(), kind: kind, changes: [change])
                guard case .accepted(let receipt) = try await store.persist(capture: capture) else { throw StorageError.incomplete }
                let bytes = try await store.retainedObject(at: receipt.object)
                try emit(["object": hex(receipt.object.encodedV1()), "envelope": hex(bytes), "sequence": receipt.sequence])
            case "snapshot-save":
                guard case .accepted(let receipt) = try await store.persistGeneralSnapshot(capture: store.captureGeneralSnapshot()) else {
                    throw StorageError.incomplete
                }
                try emit(["root": hex(receipt.snapshot.encodedV1()), "pages": receipt.pages.map { hex($0.encodedV1()) }])
            case "accepted":
                var cursor: RepositoryPublicationCursor?, paths: [String] = []
                repeat {
                    let batch = try await store.captureRepositoryPublication(continuing: cursor, maximumObjects: 64)
                    paths += batch.locators.map(\.relativePath); cursor = batch.continuation
                } while cursor != nil
                try emit(["paths": paths])
            case "conflicts":
                let result = try await store.conflicts(for: birth)
                try emit(["represented": result.current.represented.map { hex($0.id.bytes) }, "heads": result.current.heads.map { hex($0.id.bytes) },
                    "alternatives": result.alternatives.map { hex($0.id.bytes) }, "dispositions": result.representedSeparately.map { hex($0.bytes) }.sorted()])
            case "undo-candidates":
                let undo = try await store.undoCandidates(scope: .note(birth), direction: .undo)
                let redo = try await store.undoCandidates(scope: .note(birth), direction: .redo)
                try emit(["undo": undo.ids.map { hex($0.bytes) }, "redo": redo.ids.map { hex($0.bytes) }])
            case "provider":
                let observed = try await root.providerObservation(using: root.permission()), category: String
                switch observed.lookup { case .identified: category = "identified"; case .unknown: category = "unknown"; case .unsupported: category = "unsupported" }
                try emit(["provider": category, "root": String(describing: await root.state)])
            case "availability", "materialize":
                let permission = try await root.permission(), observation = try await root.observe(request.relative ?? "", using: permission)
                guard case .observed(let status) = try await root.availability(observation, using: permission) else { throw StorageError.incomplete }
                var result: [String: Any] = ["residency": String(describing: status.residency), "management": String(describing: status.management),
                    "download": String(describing: status.download)]
                if request.command == "materialize" { result["request"] = String(describing: try await root.requestMaterialization(status, using: permission)) }
                try emit(result)
            case "refresh": await driver.revisit(.foreground); try emit(["requested": true])
            case "pause-transport": await driver.stop(); try emit(["paused": true])
            case "resume-transport":
                guard await driver.status().stopped else { throw StorageError.busy }
                driver = try await RepositoryTransportDriver.start(root: root, store: store)
                try emit(["resumed": true])
            case "stop":
                await driver.stop(); await root.close(); try await store.quiesce()
                try emit(["state": "stopped"]); return true
            default: throw StorageError.unsupported
            }
        }
        await driver.stop(); await root.close(); try await store.quiesce(); return true
    } catch {
        try? emit(["state": "failed", "error": String(describing: error)])
        nv_faults_arm(0, 0, 0)
        await driver.stop(); await root.close(); try? await store.quiesce()
        throw error
    }
}
