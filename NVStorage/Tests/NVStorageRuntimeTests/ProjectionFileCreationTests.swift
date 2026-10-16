import Foundation
import Testing
import NVStorageCore
import NVStorageTestSupport
@testable import NVStorageRuntime

private struct CreationFixture {
    let store: LocalStoreSession
    let root: RepositoryRootSession
    let path: String
    let birth: NoteBirth
    let protection: ObjectProtectionV1

    static func make() async throws -> Self {
        let (initial, protection) = try testInitial(false)
        let store = try await newSession(initial, protection), path = try emptyRepository()
        let root = try await RepositoryRootSession.open(directory: path)
        let association = try await root.association(for: store.selection,
            id: .init(bytes: Array(repeating: 13, count: 16)))
        try await store.saveLocalAssociation(association, basedOn: store.localAssociation())
        return try Self(store: store, root: root, path: path,
            birth: NoteBirth(bytes: Array(repeating: 1, count: 16)), protection: protection)
    }

    func intend(_ name: String = "Note.txt", utf16: Bool = false) async throws -> PreparedProjectionIntent {
        let value = try await store.prepareProjectionIntent(for: birth,
            filename: .init(ExactUTF8(bytes: Array(name.utf8))), basedOn: store.snapshot(),
            observations: store.projectionObservations(for: birth), requestedEncoding: .init(rawValue: utf16 ? 10 : 4))
        try await store.retainProjectionIntent(value)
        return value
    }

    func freeze() async throws -> PreparedProjectionCreation {
        let state = try await store.freezeProjectionIntent(observations: store.projectionObservations(for: birth))
        return try await store.prepareProjectionCreation(observations: state, basedOn: store.snapshot())
    }

    func close() async throws { await root.close(); try await store.quiesce() }
}

@Test(arguments: [false, true])
func projectionCreationExactHistoryAndMetadata(utf16: Bool) async throws {
    let f = try await CreationFixture.make()
    let intended = try await f.intend(utf16: utf16), input = try await f.freeze()
    let before = try await f.store.projectionObservations(for: f.birth)
    let result = try await f.root.createProjection(input, from: f.store, using: f.root.permission())
    #if canImport(Darwin)
    guard case .verified(let receipt) = result else { Issue.record("Expected verified creation: \(result)"); try await f.close(); return }
    let bytes: [UInt8] = utf16 ? [255,254,65,0] : [65]
    #expect(receipt.file.bytes == bytes)
    #expect(try Data(contentsOf: URL(fileURLWithPath: f.path + "/Note.txt")) == Data(bytes))
    #expect(receipt.file.encoding == .present(Array((utf16 ? "utf-16;256" : "utf-8;134217984").utf8)))
    guard case .present(let tags) = receipt.file.tags else { Issue.record("Mandatory tags missing"); try await f.close(); return }
    #expect(try PropertyListSerialization.propertyList(from: Data(tags), format: nil) as? [String] == [])
    #expect(receipt.file.permissions == 0o600)
    #expect(receipt.file.created?.seconds == 978_307_200 && receipt.file.created?.nanoseconds == 0)
    #expect(receipt.file.modified.seconds == 978_307_201 && receipt.file.modified.nanoseconds == 0)
    #expect(receipt.stamp == .written)
    try await f.root.validate(receipt, for: input, from: f.store, using: f.root.permission())
    let otherInput = try await f.store.prepareProjectionCreation(observations: before, basedOn: f.store.snapshot())
    await #expect(throws: RepositoryRootError.wrongContext) {
        try await f.root.validate(receipt, for: otherInput, from: f.store, using: f.root.permission())
    }
    guard case .notInstalled(let collision) = try await f.root.createProjection(input, from: f.store, using: f.root.permission()) else {
        Issue.record("Repeated create must preserve occupied destination"); try await f.close(); return
    }
    #expect(collision.reason == .conflict && collision.residue != nil)
    #expect(try Data(contentsOf: URL(fileURLWithPath: f.path + "/Note.txt")) == Data(bytes))
    #else
    guard case .notInstalled(let failure) = result else { Issue.record("Expected explicit unsupported date capability"); try await f.close(); return }
    #expect(failure.reason == .unsupported(ENOTSUP) && failure.residue == nil)
    #expect(!FileManager.default.fileExists(atPath: f.path + "/Note.txt"))
    #endif
    #expect(try await f.store.projectionObservations(for: f.birth).value == before.value)
    #expect(before.value?.frozen?.output == intended.output)
    #expect(try await f.store.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    try await f.close()
}

@Test func projectionCreationRequiresFrozenLiveOwner() async throws {
    let f = try await CreationFixture.make()
    _ = try await f.intend()
    await #expect(throws: StorageError.incomplete) {
        try await f.store.prepareProjectionCreation(observations: f.store.projectionObservations(for: f.birth), basedOn: f.store.snapshot())
    }
    let input = try await f.freeze()
    let other = try await CreationFixture.make()
    await #expect(throws: StorageError.wrongContext) {
        try await f.root.createProjection(input, from: other.store, using: f.root.permission())
    }
    await #expect(throws: RepositoryRootError.wrongContext) {
        try await other.root.createProjection(input, from: f.store, using: other.root.permission())
    }
    let deletion = try await CapturedActionGroup(snapshot: f.store.snapshot(), kind: .deleteBatch,
        changes: [.delete(.init(birth: f.birth, generation: 1))])
    _ = try requireReceipt(await f.store.persist(capture: deletion))
    await #expect(throws: StorageError.staleCapture) {
        try await f.root.createProjection(input, from: f.store, using: f.root.permission())
    }
    #expect(!FileManager.default.fileExists(atPath: f.path + "/Note.txt"))
    #expect(try await f.store.projectionObservations(for: f.birth).value?.frozen?.output == input.output)
    try await other.close(); try await f.close()
}

#if canImport(Darwin)
@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func projectionCreationCompletionPreservesNewerWork(delete: Bool) async throws {
    let f = try await CreationFixture.make()
    _ = try await f.intend(utf16: true)
    let input = try await f.freeze(), permission = try await f.root.permission()
    let entered = ImprovementGate(), release = DispatchSemaphore(value: 0)
    let watchdog = Task {
        do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
        Issue.record("Creation did not reach/settle held native operation"); await entered.signal(); release.signal()
    }
    defer { watchdog.cancel(); release.signal() }
    let creation = Task {
        try await f.root.createProjection(input, from: f.store, using: permission, staged: { _ in }, beforeInstall: {
            Task { await entered.signal() }; release.wait()
        }, afterInstall: {})
    }
    await entered.wait()
    if delete {
        let capture = try await CapturedActionGroup(snapshot: f.store.snapshot(), kind: .deleteBatch,
            changes: [.delete(.init(birth: f.birth, generation: 1))])
        _ = try requireReceipt(await f.store.persist(capture: capture))
    } else {
        _ = try await put("C", birth: f.birth, generation: 1, session: f.store)
        _ = try await f.intend("New.txt", utf16: true)
    }
    let pending = try await f.store.projectionObservations(for: f.birth)
    release.signal()
    let result = try await creation.value
    if delete {
        #expect({ if case .uncertain = result { true } else { false } }())
        guard case .uncertain(let failure) = result else { Issue.record("Deleted source must invalidate completion"); try await f.close(); return }
        #expect(failure.reason == .staleContext && failure.storageFailure == .staleCapture)
    } else {
        guard case .verified(let receipt) = result else { Issue.record("Frozen output must finish independently of newer edit"); try await f.close(); return }
        #expect(receipt.file.bytes == [255,254,65,0])
        #expect(pending.value?.intended?.output.binding.descriptor.filename.spelling.string == "New.txt")
    }
    #expect(try Data(contentsOf: URL(fileURLWithPath: f.path + "/Note.txt")) == Data([255,254,65,0]))
    #expect(try await f.store.projectionObservations(for: f.birth).value == pending.value)
    #expect(try await f.store.snapshot().notes.map(\.value.body.string).sorted() == (delete ? ["untouched"] : ["C", "untouched"]))
    let selection = await f.store.selection
    try await f.close()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: f.protection)
    #expect(try await reopened.projectionObservations(for: f.birth).value == pending.value)
    #expect(try await reopened.capturedProjectionBytes(input.output, observations: reopened.projectionObservations(for: f.birth)) == [255,254,65,0])
    try await reopened.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: ["cancel", "close", "reassociate"])
func projectionCreationFencesLateCompletion(change: String) async throws {
    let f = try await CreationFixture.make()
    _ = try await f.intend()
    let input = try await f.freeze(), permission = try await f.root.permission()
    let entered = ImprovementGate(), release = DispatchSemaphore(value: 0)
    let watchdog = Task {
        do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
        Issue.record("Creation did not settle after lifecycle interference"); await entered.signal(); release.signal()
    }
    defer { watchdog.cancel(); release.signal() }
    let creation = Task {
        try await f.root.createProjection(input, from: f.store, using: permission, staged: { _ in }, beforeInstall: {}, afterInstall: {
            Task { await entered.signal() }; release.wait()
        })
    }
    await entered.wait()
    var closing: Task<Void, Never>?
    switch change {
    case "cancel": creation.cancel()
    case "close":
        closing = Task { await f.root.close() }
        while await f.root.state == .active { await Task.yield() }
        #expect(await f.root.state == .closing)
    default:
        let replacement = try await RepositoryRootSession.open(directory: emptyRepository())
        let association = try await replacement.association(for: f.store.selection, id: .init(bytes: Array(repeating: 31, count: 16)))
        try await f.store.saveLocalAssociation(association, basedOn: f.store.localAssociation())
        await replacement.close()
    }
    release.signal()
    let result = try await creation.value
    #expect({ if case .uncertain = result { true } else { false } }())
    #expect(try Data(contentsOf: URL(fileURLWithPath: f.path + "/Note.txt")) == Data([65]))
    #expect(try await f.store.projectionObservations(for: f.birth).value?.frozen?.output == input.output)
    if let closing { await closing.value }
    try await f.close()
}

@Test func projectionCreationFollowsRootMoveAndReopensExplicitAssociation() async throws {
    let f = try await CreationFixture.make()
    _ = try await f.intend()
    let input = try await f.freeze(), moved = f.path + "-moved"
    let result = try await f.root.createProjection(input, from: f.store, using: f.root.permission(), staged: { _ in }, beforeInstall: {
        do {
            try FileManager.default.moveItem(atPath: f.path, toPath: moved)
            try FileManager.default.createDirectory(atPath: f.path, withIntermediateDirectories: false)
            try Data([88]).write(to: URL(fileURLWithPath: f.path + "/Note.txt"))
        } catch { Issue.record(error) }
    }, afterInstall: {})
    guard case .verified = result else { Issue.record("Held root must remain creation target after moving"); try await f.close(); return }
    #expect(try Data(contentsOf: URL(fileURLWithPath: moved + "/Note.txt")) == Data([65]))
    #expect(try Data(contentsOf: URL(fileURLWithPath: f.path + "/Note.txt")) == Data([88]))
    let selection = await f.store.selection
    try await f.close()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: f.protection)
    let root = try await RepositoryRootSession.open(directory: moved)
    await #expect(throws: StorageError.wrongContext) {
        try await root.createProjection(input, from: reopened, using: root.permission())
    }
    // Explicit reopening records the selected held directory's fresh bookmark.
    let association = try await root.association(for: selection, id: input.association.id)
    try await reopened.saveLocalAssociation(association, basedOn: reopened.localAssociation())
    let fresh = try await reopened.prepareProjectionCreation(observations: reopened.projectionObservations(for: f.birth), basedOn: reopened.snapshot())
    guard case .notInstalled(let collision) = try await root.createProjection(fresh, from: reopened, using: root.permission()) else {
        Issue.record("Fresh retry must preserve installed output"); await root.close(); try await reopened.quiesce(); return
    }
    #expect(collision.reason == .conflict)
    await root.close(); try await reopened.quiesce()
}

@Test(arguments: [false, true])
func projectionCreationPreservesNamespaceInterference(after: Bool) async throws {
    let f = try await CreationFixture.make()
    _ = try await f.intend()
    let input = try await f.freeze()
    let file = URL(fileURLWithPath: f.path + "/Note.txt")
    let result = try await f.root.createProjection(input, from: f.store, using: f.root.permission(), staged: { directory in
        #expect(directory.path != f.path)
        do { #expect(try Data(contentsOf: directory.appendingPathComponent("prepared")) == Data([65])) }
        catch { Issue.record(error) }
        let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((attributes?[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }, beforeInstall: {
        if !after { do { try Data([88]).write(to: file) } catch { Issue.record(error) } }
    }, afterInstall: {
        if after { do { try Data([88]).write(to: file, options: .atomic) } catch { Issue.record(error) } }
    })
    if after {
        guard case .uncertain(let failure) = result else { Issue.record("Changed installed name must remain uncertain"); try await f.close(); return }
        #expect(failure.reason == .changed)
    } else {
        guard case .notInstalled(let failure) = result else { Issue.record("Late occupant must remain intact"); try await f.close(); return }
        #expect(failure.reason == .conflict && failure.residue != nil)
    }
    #expect(try Data(contentsOf: file) == Data([88]))
    #expect(try await f.store.projectionObservations(for: f.birth).value?.frozen?.output == input.output)
    try await f.close()
}
#endif
