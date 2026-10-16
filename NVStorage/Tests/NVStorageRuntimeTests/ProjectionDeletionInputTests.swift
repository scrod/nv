import Foundation
import Testing
import NVStorageCore
import NVStorageTestSupport
import CStorageFaults
@testable import NVStorageRuntime
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct DeletionFixture: Sendable {
    let store: LocalStoreSession
    let root: RepositoryRootSession
    let path: String
    let birth: NoteBirth
    let protection: ObjectProtectionV1
    let source: ProjectionFileSnapshot

    static func make(utf16: Bool = false) async throws -> Self {
        let (initial, protection) = try testInitial(false), store = try await newSession(initial, protection)
        let path = try emptyRepository(), root = try await RepositoryRootSession.open(directory: path)
        let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
        let association = try await root.association(for: store.selection, id: .init(bytes: Array(repeating: 13, count: 16)))
        try await store.saveLocalAssociation(association, basedOn: store.localAssociation())
        return try await bind(store: store, root: root, path: path, birth: birth, name: "Note.txt",
            bytes: utf16 ? [255,254,65,0] : [65], encoding: utf16 ? 10 : 4)
    }

    /// Gives the collection's other initial note its own real accepted file relationship.
    func sibling() async throws -> Self {
        try await Self.bind(store: store, root: root, path: path, birth: .init(bytes: Array(repeating: 2, count: 16)),
            name: "Other.txt", bytes: Array("untouched".utf8), encoding: 4)
    }

    private static func bind(store: LocalStoreSession, root: RepositoryRootSession, path: String,
                             birth: NoteBirth, name: String, bytes: [UInt8], encoding: UInt64) async throws -> Self {
        let output = try await store.prepareProjectionIntent(for: birth, filename: .init(ExactUTF8(bytes: Array(name.utf8))),
            basedOn: store.snapshot(), observations: store.projectionObservations(for: birth),
            requestedEncoding: .init(rawValue: encoding))
        try await store.retainProjectionIntent(output)
        try Data(bytes).write(to: URL(fileURLWithPath: path + "/" + name))
        let observed = try await root.observe(name, using: root.permission())
        guard case .snapshot(let source) = try await root.readProjection(observed, maximumBytes: 1024, using: root.permission()) else {
            throw StorageError.incomplete
        }
        let prior = try #require(await store.projectionObservations(for: birth).value)
        // Seed P6.4's accepted relationship from the actual coherent file and its checked history output.
        let accepted = try AcceptedProjectionV1(output: output.output, physical: source.physicalRecord,
            encoding: nil, tags: nil, created: nil, modified: nil)
        let value = try ProjectionObservationsV1(profile: .plaintextFiles, scope: prior.scope, association: prior.association,
            birth: birth, accepted: accepted, intended: nil)
        try await store.lane.perform { try $0.run("UPDATE private_groups SET generation=generation+1,payload=? WHERE group_key=?",
            [.blob(value.encodedV1()), .blob(key(birth))]) }
        return Self(store: store, root: root, path: path, birth: birth, protection: .publicHash, source: source)
    }

    static func key(_ birth: NoteBirth) -> [UInt8] {
        Array(("projection/" + birth.bytes.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()).utf8)
    }

    func prepare(generation: UInt64 = 2, batch: Bool = false) async throws -> (CapturedActionGroup, PreparedProjectionDeletion) {
        let snapshot = try await store.snapshot()
        let births = batch ? snapshot.notes.map(\.birth) : [birth]
        let capture = try CapturedActionGroup(snapshot: snapshot, kind: .deleteBatch,
            changes: births.map { .delete(try .init(birth: $0, generation: generation)) })
        let input = try await store.prepareProjectionDeletion(capture: capture, birth: birth,
            observations: store.projectionObservations(for: birth), basedOn: snapshot)
        return (capture, input)
    }

    func original(_ input: PreparedProjectionDeletion) async throws -> CapturedProjectionDeleteSource {
        try await root.captureProjectionDeletion(input, source: source, from: store, using: root.permission())
    }

    func close() async throws { await root.close(); try await store.quiesce() }
    func disk() throws -> [UInt8] { Array(try Data(contentsOf: URL(fileURLWithPath: path + "/Note.txt"))) }
    func authorize() async throws -> AuthorizedProjectionDeletion {
        let (capture, input) = try await prepare(), capturedSource = try await self.original(input)
        let receipt = try requireReceipt(await store.persist(capture: capture))
        return try await store.authorizeProjectionDeletion(capturedSource, committed: receipt)
    }

    /// Seeds a captured accepted observation while retaining the exact historical output.
    func acceptedPhysical(_ physical: PassivePlatformRecordV1) async throws {
        let prior = try #require(await store.projectionObservations(for: birth).value)
        let source = try #require(prior.accepted)
        let accepted = try AcceptedProjectionV1(output: source.output, physical: physical, encoding: source.encoding,
            tags: source.tags, created: source.created, modified: source.modified)
        let value = try ProjectionObservationsV1(profile: .plaintextFiles, scope: prior.scope, association: prior.association,
            birth: birth, accepted: accepted, intended: nil)
        try await store.lane.perform { try $0.run("UPDATE private_groups SET generation=generation+1,payload=? WHERE group_key=?",
            [.blob(value.encodedV1()), .blob(Self.key(birth))]) }
    }
}

/// Counts the process's live descriptors for one independently observed physical file.
private func projectionSourceDescriptors(at path: String) throws -> [Int32] {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    let device = try #require(attributes[.systemNumber] as? NSNumber).uint64Value
    let inode = try #require(attributes[.systemFileNumber] as? NSNumber).uint64Value
    return try projectionSourceDescriptors(device: device, inode: inode)
}

private func projectionSourceDescriptors(device: UInt64, inode: UInt64) throws -> [Int32] {
    return try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").compactMap { entry in
        guard let descriptor = Int32(entry) else { return nil }
        var state = stat()
        guard unsafe fstat(descriptor, &state) == 0,
              UInt64(state.st_dev) == device, UInt64(state.st_ino) == inode else { return nil }
        return descriptor
    }
}

@Test(arguments: [false, true])
func projectionSourceDescriptorFollowsLiveCapture(closeRoot: Bool) async throws {
    let f = try await DeletionFixture.make(), path = f.path + "/Note.txt"
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    let device = try #require(attributes[.systemNumber] as? NSNumber).uint64Value
    let inode = try #require(attributes[.systemFileNumber] as? NSNumber).uint64Value
    #expect(try projectionSourceDescriptors(at: path).isEmpty)
    func exercise() async throws {
        let (capture, input) = try await f.prepare()
        let original = try await f.root.captureProjectionDeletion(input, source: f.source, from: f.store,
            using: f.root.permission(), beforeIssue: { () async throws in
                #expect(try projectionSourceDescriptors(at: path).count == 1, "Coherent read retains its descriptor before suspension")
                await Task.yield()
            })
        let receipt = try requireReceipt(await f.store.persist(capture: capture))
        let grant = try await f.store.authorizeProjectionDeletion(original, committed: receipt)
        let descriptors = try projectionSourceDescriptors(at: path)
        #expect(descriptors.count == 1, "Copies share the original descriptor")
        if closeRoot {
            let permission = try await f.root.permission()
            await f.root.close()
            await #expect(throws: RepositoryRootError.stalePermission) {
                try await f.root.removeProjectionSource(grant, from: f.store, using: permission, maximumBytes: 1024)
            }
            withExtendedLifetime(grant) { #expect(descriptors.allSatisfy { fcntl($0, F_GETFD) >= 0 }) }
        } else {
            guard case .removed(let result) = try await f.root.removeProjectionSource(grant,
                from: f.store, using: f.root.permission(), maximumBytes: 1024, reserved: { _ async throws in
                    #expect(try projectionSourceDescriptors(at: path) == descriptors)
                }) else { throw StorageError.incomplete }
            withExtendedLifetime(result) {
                #expect(descriptors.allSatisfy { fcntl($0, F_GETFD) >= 0 })
            }
        }
    }
    try await exercise()
    #expect(try projectionSourceDescriptors(device: device, inode: inode).isEmpty, "Last capture release closes the descriptor")
    try await f.close()
}

@Test(arguments: ["throw", "cancel", "edit"])
func projectionSourceFailedCaptureClosesDescriptor(failure: String) async throws {
    let f = try await DeletionFixture.make(), (_, input) = try await f.prepare(), path = f.path + "/Note.txt"
    let task = Task {
        try await f.root.captureProjectionDeletion(input, source: f.source, from: f.store, using: f.root.permission(), beforeIssue: { () async throws in
            #expect(try projectionSourceDescriptors(at: path).count == 1)
            switch failure {
            case "throw": throw StorageError.incomplete
            case "cancel": withUnsafeCurrentTask { $0?.cancel() }
            default: _ = try await put("B", birth: f.birth, generation: 2, session: f.store)
            }
        })
    }
    do { _ = try await task.value; Issue.record("Interrupted capture must fail") }
    catch {
        if failure == "cancel" { #expect(error is CancellationError) }
        else { #expect(error as? StorageError == (failure == "edit" ? .staleCapture : .incomplete)) }
    }
    #expect(try projectionSourceDescriptors(at: path).isEmpty)
    #expect(try await f.store.pendingProjectionSource(for: f.birth) == nil)
    #expect(try f.disk() == [65])
    try await f.close()
}

@Test(arguments: ["body", "metadata", "equal-replacement"])
func projectionSourceCaptureRereadsTheOriginal(change: String) async throws {
    let f = try await DeletionFixture.make(), (_, input) = try await f.prepare(), path = f.path + "/Note.txt"
    if change == "metadata" { try changeProjectionFixtureMetadata("tags", at: path) }
    else { try Data(change == "body" ? [66] : [65]).write(to: URL(fileURLWithPath: path), options: .atomic) }
    do {
        _ = try await f.original(input)
        Issue.record("Stale coherent read cannot issue a source capture")
    } catch let error as RepositoryRootError {
        #expect(error == .wrongContext || error == .unavailable(ESTALE))
    }
    #expect(try projectionSourceDescriptors(at: path).isEmpty)
    #expect(try await f.store.snapshot().notes.count == 2)
    #expect(try await f.store.pendingProjectionSource(for: f.birth) == nil)
    #expect(try f.disk() == (change == "body" ? [66] : [65]))
    try await f.close()
}

@Test(arguments: [false, true])
func projectionSourceCleanupRemovesOnlyOwnedArtifact(newOccupant: Bool) async throws {
    let f = try await DeletionFixture.make(), grant = try await f.authorize()
    let before = try await f.store.projectionObservations(for: f.birth)
    let result = try await f.root.removeProjectionSource(grant, from: f.store,
        using: f.root.permission(), maximumBytes: 1024, afterRemoval: {
            if newOccupant {
                do { try Data([88]).write(to: URL(fileURLWithPath: f.path + "/Note.txt"), options: .withoutOverwriting) }
                catch { Issue.record(error) }
            }
        })
    let effect: ProjectionSourceEffect
    switch result {
    case .removed(let receipt):
        #expect(!newOccupant)
        try await f.root.validate(receipt, for: grant, from: f.store, using: f.root.permission())
        effect = receipt.effect
    case .uncertain(let value): #expect(newOccupant); effect = value
    default: throw StorageError.incomplete
    }
    let record = effect.record
    #expect(!FileManager.default.fileExists(atPath: f.path + "/" + record.cleanupDirectoryName + "/item"))
    if newOccupant {
        #expect(try f.disk() == [88])
        guard case .snapshot(let current) = effect.source else { throw StorageError.incomplete }
        #expect(current.bytes == [88])
    } else { #expect(!FileManager.default.fileExists(atPath: f.path + "/Note.txt")) }
    #expect(try await f.store.pendingProjectionSource(for: f.birth) == record)
    #expect(try await f.store.projectionObservations(for: f.birth).value == before.value)
    await #expect(throws: StorageError.busy) {
        try await f.root.removeProjectionSource(grant, from: f.store, using: f.root.permission(), maximumBytes: 1024)
    }
    if newOccupant { #expect(try f.disk() == [88]) }
    let selection = await f.store.selection
    try await f.close()
    let store = try await LocalStoreSession.open(selection: selection, protection: f.protection)
    let root = try await RepositoryRootSession.open(directory: f.path)
    let input = try await store.prepareProjectionSourceRecovery(for: f.birth)
    let inspection = try await root.inspectProjectionSource(input, from: store, maximumBytes: 1024, using: root.permission())
    guard case .unavailable(.absent) = inspection.cleanup else { throw StorageError.incomplete }
    if newOccupant { #expect(try f.disk() == [88]) }
    #expect(try await store.snapshot().notes.map(\.value.body.string) == ["untouched"])
    await #expect(throws: RepositoryRootError.wrongContext) {
        try await root.removeProjectionSource(grant, from: store, using: root.permission(), maximumBytes: 1024)
    }
    await root.close(); try await store.quiesce()
}

@Test(arguments: ["body", "metadata", "mode", "renamed-away", "directory", "hardlink"])
func projectionSourceCleanupPreservesChangedArtifact(change: String) async throws {
    let f = try await DeletionFixture.make(), grant = try await f.authorize()
    let path = f.path + "/Note.txt"
    let result = try await f.root.removeProjectionSource(grant, from: f.store, using: f.root.permission(), maximumBytes: 1024,
        beforeRemoval: {
            do {
                switch change {
                case "body": try Data([88]).write(to: URL(fileURLWithPath: path), options: .atomic)
                case "metadata": try changeProjectionFixtureMetadata("tags", at: path)
                case "mode": try changeProjectionFixtureMetadata("permissions", at: path)
                case "renamed-away": try FileManager.default.moveItem(atPath: path, toPath: f.path + "/preserved")
                case "directory":
                    try FileManager.default.moveItem(atPath: path, toPath: f.path + "/preserved")
                    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
                default: try FileManager.default.linkItem(atPath: path, toPath: f.path + "/preserved")
                }
            } catch { Issue.record(error) }
        })
    #expect({ if case .notRemoved = result { true } else { false } }(), "Changed artifacts require reconciliation")
    #expect(try await f.store.pendingProjectionSource(for: f.birth) == nil)
    if change == "renamed-away" || change == "directory" { #expect(try Data(contentsOf: URL(fileURLWithPath: f.path + "/preserved")) == Data([65])) }
    else { #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data(change == "body" ? [88] : [65])) }
    try await f.close()
}

@Test(arguments: ["root", "record", "cancel", "new-source", "new-protected-artifact"])
func projectionSourceCleanupFencesCompletion(change: String) async throws {
    let f = try await DeletionFixture.make(), grant = try await f.authorize()
    let work = Task { try await f.root.removeProjectionSource(grant, from: f.store, using: f.root.permission(), maximumBytes: 1024,
        afterRemoval: {
            if change == "cancel" { withUnsafeCurrentTask { $0?.cancel() }; return }
            if change == "new-source" || change == "new-protected-artifact" {
                do {
                    let directory = try #require(FileManager.default.contentsOfDirectory(atPath: f.path).first(where: { $0.hasPrefix(".nv-source-") }))
                    let name = change == "new-source" ? "Note.txt" : directory + "/item"
                    try Data([88]).write(to: URL(fileURLWithPath: f.path + "/" + name), options: .withoutOverwriting)
                }
                catch { Issue.record(error) }
                return
            }
            let done = DispatchSemaphore(value: 0)
            Task {
                defer { done.signal() }
                do {
                    if change == "root" { await f.root.invalidate() }
                    else {
                        try await f.store.lane.perform { try $0.run("UPDATE private_groups SET generation=2 WHERE group_key=?",
                            [.blob(Array(("projection-source/" + String(repeating: "01", count: 16)).utf8))]) }
                    }
                } catch { Issue.record(error) }
            }
            if done.wait(timeout: .now() + 20) != .success { Issue.record("Cleanup interference timed out") }
        }) }
    let result = try await work.value
    #expect({ if case .uncertain = result { true } else { false } }(), "Cleanup completion requires its final owner and artifact checks")
    guard case .uncertain(let effect) = result else { throw StorageError.incomplete }
    if change == "record" {
        await #expect(throws: StorageError.integrity) { try await f.store.pendingProjectionSource(for: f.birth) }
        let rows = try await f.store.lane.perform { try $0.rows("SELECT generation,payload FROM private_groups WHERE group_key=?",
            [.blob(Array(("projection-source/" + String(repeating: "01", count: 16)).utf8))]) }
        #expect(rows == [[.integer(2), .blob(try effect.record.encodedV1())]])
    } else { #expect(try await f.store.pendingProjectionSource(for: f.birth) == effect.record) }
    if change == "new-source" {
        #expect(try f.disk() == [88])
    } else {
        #expect(!FileManager.default.fileExists(atPath: f.path + "/Note.txt"))
    }
    if change == "new-protected-artifact" {
        guard case .snapshot(let file) = effect.cleanup else { throw StorageError.incomplete }
        #expect(file.bytes == [88] && file.record == effect.record)
    }
    try await f.close()
}

@Test(arguments: ["exact", "changed", "public-occupant", "hardlink", "symlink", "directory"])
func projectionSourceProtectedRecoveryInspectsRetainedContents(kind: String) async throws {
    let f = try await DeletionFixture.make(), grant = try await f.authorize()
    await #expect(throws: StorageError.incomplete) {
        try await f.root.removeProjectionSource(grant, from: f.store, using: f.root.permission(), maximumBytes: 1024,
            reserved: { record in
                // Reproduce the native capture-cut fixture while retaining the real durable attempt.
                let directory = f.path + "/" + record.cleanupDirectoryName
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try FileManager.default.moveItem(atPath: f.path + "/Note.txt", toPath: directory + "/item")
                throw StorageError.incomplete
            })
    }
    let record = try #require(await f.store.pendingProjectionSource(for: f.birth))
    let directory = f.path + "/" + record.cleanupDirectoryName, path = directory + "/item"
    switch kind {
    case "changed": try Data([88]).write(to: URL(fileURLWithPath: path), options: .atomic)
    case "public-occupant": try Data([89]).write(to: URL(fileURLWithPath: f.path + "/Note.txt"))
    case "hardlink": try FileManager.default.linkItem(atPath: path, toPath: f.path + "/second")
    case "symlink", "directory":
        try FileManager.default.moveItem(atPath: path, toPath: directory + "/preserved")
        if kind == "symlink" { try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: "preserved") }
        else { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false) }
    default: break
    }
    let selection = await f.store.selection
    try await f.close()
    let store = try await LocalStoreSession.open(selection: selection, protection: f.protection)
    let root = try await RepositoryRootSession.open(directory: f.path)
    for _ in 0..<2 {
        let input = try await store.prepareProjectionSourceRecovery(for: f.birth)
        let budget = ["hardlink", "symlink", "directory"].contains(kind) ? 0 : 1024
        let inspection = try await root.inspectProjectionSource(input, from: store, maximumBytes: budget, using: root.permission())
        try await root.validate(inspection, for: input, from: store, using: root.permission())
        switch kind {
        case "hardlink":
            guard case .unavailable(let failure) = inspection.cleanup else { throw StorageError.incomplete }
            #expect(failure == .hardLinked, "Protected link ownership is checked before byte budget")
        case "symlink", "directory":
            guard case .unavailable(let failure) = inspection.cleanup else { throw StorageError.incomplete }
            #expect(failure == .kindCollision, "Protected kind is checked before byte budget")
        default:
            guard case .snapshot(let file) = inspection.cleanup else { throw StorageError.incomplete }
            #expect(file.bytes == (kind == "changed" ? [88] : [65]) && file.record == record)
        }
        if kind == "public-occupant" {
            guard case .snapshot(let file) = inspection.source else { throw StorageError.incomplete }
            #expect(file.bytes == [89])
        }
        #expect(try await store.pendingProjectionSource(for: f.birth) == record)
    }
    #expect(try await store.snapshot().notes.map(\.value.body.string) == ["untouched"])
    await root.close(); try await store.quiesce()
}

@Test(arguments: [false, true])
func projectionSourceCleanupReceiptRequiresExactCapture(sameCommand: Bool) async throws {
    let f = try await DeletionFixture.make(), sibling = try await f.sibling()
    let (capture, input) = try await f.prepare(), original = try await f.original(input), independent = try await f.original(input)
    let committed = try requireReceipt(await f.store.persist(capture: capture))
    let first = try await f.store.authorizeProjectionDeletion(original, committed: committed)
    let other = sameCommand ? try await f.store.authorizeProjectionDeletion(independent, committed: committed) : try await sibling.authorize()
    guard case .removed(let receipt) = try await f.root.removeProjectionSource(first, from: f.store,
        using: f.root.permission(), maximumBytes: 1024) else { throw StorageError.incomplete }
    await #expect(throws: RepositoryRootError.wrongContext, "Cleanup receipt belongs to its exact source capture") {
        try await f.root.validate(receipt, for: other, from: f.store, using: f.root.permission())
    }
    try await f.root.validate(receipt, for: first, from: f.store, using: f.root.permission())
    #expect(try Data(contentsOf: URL(fileURLWithPath: f.path + "/Other.txt")) == Data(Array("untouched".utf8)))
    try await f.close()
}

/// Changes real metadata through the existing platform-specific fixture bridge.
func changeProjectionFixtureMetadata(_ change: String, at path: String) throws {
    if change == "permissions" { try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path); return }
    if change == "modified" {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_001)], ofItemAtPath: path); return
    }
    if change == "created" {
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_700_000_002)], ofItemAtPath: path); return
    }
    let name: String
    switch change {
    case "encoding": name = "com.apple.TextEncoding"
    case "tags", "tags-empty": name = "com.apple.metadata:kMDItemOMUserTags"
    case "finder": name = "com.apple.metadata:_kMDItemUserTags"
    default: name = "org.notationalvelocity.projection#S"
    }
    #if canImport(Darwin)
    let key = name
    #else
    let key = "user." + name
    #endif
    let bytes: [UInt8] = change == "tags-empty" ? [] : [0,255,1]
    try #require(bytes.withUnsafeBufferPointer { unsafe nv_fixture_set_attribute(path, key, $0.baseAddress, UInt64($0.count)) } == 0)
}

@Test(arguments: ["permissions", "encoding", "tags", "tags-empty", "finder", "stamp", "modified"])
func projectionSourceRejectsAcceptedMetadataChanges(change: String) async throws {
    let f = try await DeletionFixture.make(), before = try f.source.physicalRecord
    try changeProjectionFixtureMetadata(change, at: f.path + "/Note.txt")
    guard case .snapshot(let changed) = try await f.root.readProjection(f.root.observe("Note.txt", using: f.root.permission()),
        maximumBytes: 1024, using: f.root.permission()) else { throw StorageError.incomplete }
    let after = try changed.physicalRecord
    #expect(before.codec == 0x50524601 && before.bytes.count == 104 && after.bytes.count == 104)
    if change == "modified" {
        #expect(before.bytes.prefix(72) != after.bytes.prefix(72))
    } else {
        #expect(before.bytes.suffix(32) != after.bytes.suffix(32))
        // Equal stat words isolate the coarse-clock case while retaining the earlier metadata commitment.
        try await f.acceptedPhysical(.init(codec: before.codec, bytes: Array(after.bytes.prefix(72)) + before.bytes.suffix(32)))
    }
    let (_, input) = try await f.prepare()
    await #expect(throws: RepositoryRootError.wrongContext, "Accepted metadata must match before Delete capture") {
        try await f.root.captureProjectionDeletion(input, source: changed, from: f.store, using: f.root.permission())
    }
    #expect(try await f.store.pendingProjectionSource(for: f.birth) == nil)
    #expect(try f.disk() == [65])
    try await f.acceptedPhysical(after)
    let (_, current) = try await f.prepare()
    _ = try await f.root.captureProjectionDeletion(current, source: changed, from: f.store, using: f.root.permission())
    #expect(try await f.store.snapshot().notes.count == 2)
    try await f.close()
}

#if canImport(Darwin)
@Test func projectionSourceRejectsAcceptedCreationDateChange() async throws {
    try await projectionSourceRejectsAcceptedMetadataChanges(change: "created")
}
#endif

@Test(.timeLimit(.minutes(1)))
func projectionSourcePhysicalRecordIndependentOracle() async throws {
    let f = try await DeletionFixture.make()
    for kind in ["permissions", "encoding", "tags-empty", "finder", "stamp"] {
        try changeProjectionFixtureMetadata(kind, at: f.path + "/Note.txt")
    }
    guard case .snapshot(let file) = try await f.root.readProjection(f.root.observe("Note.txt", using: f.root.permission()),
        maximumBytes: 1024, using: f.root.permission()) else { throw StorageError.incomplete }
    func attribute(_ value: ProjectionFileAttribute) -> [String: Any] {
        switch value {
        case .absent: ["state": 0]
        case .unsupported: ["state": 2]
        case .present(let bytes): ["state": 1, "hex": bytes.map { String(format: "%02x", $0) }.joined()]
        }
    }
    let input: [String: Any] = ["path": f.path + "/Note.txt", "mode": file.permissions,
        "created": file.created.map { [$0.seconds, Int64($0.nanoseconds)] } as Any? ?? NSNull(),
        "attributes": [file.encoding, file.tags, file.finderTags, file.stamp].map(attribute)]
    let process = Process(), source = Pipe(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", "-c", #"""
import hashlib,json,os,struct,sys
v=json.load(sys.stdin); s=os.stat(v['path'],follow_symlinks=False)
ms,mn=divmod(s.st_mtime_ns,10**9); cs,cn=divmod(s.st_ctime_ns,10**9)
words=[1,s.st_dev,s.st_ino,s.st_size,s.st_nlink,ms,mn,cs,cn]
m=struct.pack('>I',v['mode']); b=v['created']
m+=b'\0' if b is None else b'\1'+struct.pack('>qI',*b)
for a in v['attributes']:
    m+=bytes([a['state']])
    if a['state']==1:
        raw=bytes.fromhex(a['hex']); m+=struct.pack('>I',len(raw))+raw
print((struct.pack('>9Q',*[w&((1<<64)-1) for w in words])+hashlib.sha256(b'NV projection metadata\0v1\0'+m).digest()).hex())
"""#]
    process.standardInput = source; process.standardOutput = output
    try process.run()
    try source.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: input))
    try source.fileHandleForWriting.close()
    let bytes = try output.fileHandleForReading.readToEnd() ?? Data()
    process.waitUntilExit()
    try #require(process.terminationReason == .exit && process.terminationStatus == 0)
    let expected = try #require(String(data: bytes, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(expected.count == 208)
    #expect(try file.physicalRecord.bytes.map { String(format: "%02x", $0) }.joined() == expected)
    try await f.close()
}

@Test(arguments: [false, true])
func projectionSourceCapturesOriginalAndRecoversAfterReopen(utf16: Bool) async throws {
    let f = try await DeletionFixture.make(utf16: utf16), grant = try await f.authorize()
    let prior = try await f.store.projectionObservations(for: f.birth)
    guard case .removed(let captured) = try await f.root.removeProjectionSource(grant, from: f.store,
        using: f.root.permission(), maximumBytes: 1024) else { throw StorageError.incomplete }
    let record = captured.effect.record
    #expect(!FileManager.default.fileExists(atPath: f.path + "/Note.txt"))
    #expect(!FileManager.default.fileExists(atPath: f.path + "/" + record.cleanupDirectoryName + "/item"))
    #expect(record.observation == (try grant.original.capturedObservation) && record.observation.codec == 0x50525301)
    #expect(record.attempt.bytes[6] & 0xf0 == 0x40 && record.attempt.bytes[8] & 0xc0 == 0x80)
    #expect(try await f.store.pendingProjectionSource(for: f.birth) == record)
    #expect(try await f.store.projectionObservations(for: f.birth).value == prior.value)
    try await f.root.validate(captured, for: grant, from: f.store, using: f.root.permission())
    await #expect(throws: StorageError.busy) { try await f.store.reserveProjectionSource(grant) }
    let selection = await f.store.selection
    try await f.close()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: f.protection)
    let root = try await RepositoryRootSession.open(directory: f.path), input = try await reopened.prepareProjectionSourceRecovery(for: f.birth)
    #expect(input.bytes == f.source.bytes && input.record == record)
    let inspected = try await root.inspectProjectionSource(input, from: reopened, maximumBytes: 1024, using: root.permission())
    if case .unavailable(.absent) = inspected.source {} else { Issue.record("Original name stays absent during read-only recovery") }
    guard case .unavailable(.absent) = inspected.cleanup else { throw StorageError.incomplete }
    try await root.validate(inspected, for: input, from: reopened, using: root.permission())
    await #expect(throws: StorageError.wrongContext) { try await reopened.checkProjectionDeletion(grant) }
    #expect(try await reopened.snapshot().notes.map(\.value.body.string) == ["untouched"])
    #expect(try await reopened.pendingProjectionSource(for: f.birth) == record)
    await root.close(); try await reopened.quiesce()
}

@Test func projectionSourceBurnsOccupiedRecoveryNames() async throws {
    let f = try await DeletionFixture.make(), grant = try await f.authorize()
    var names = Set<String>()
    for _ in 0..<2 {
        let result = try await f.root.removeProjectionSource(grant, from: f.store, using: f.root.permission(), maximumBytes: 1024,
            reserved: { record in
                let path = f.path + "/" + record.cleanupDirectoryName
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
                try Data([88]).write(to: URL(fileURLWithPath: path + "/foreign"), options: .withoutOverwriting)
            })
        guard case .notRemoved(let observed) = result else { throw StorageError.incomplete }
        #expect(observed.reason == .conflict && names.insert(observed.record.cleanupDirectoryName).inserted)
        #expect(try f.disk() == [65])
        #expect(try await f.store.pendingProjectionSource(for: f.birth) == nil)
    }
    guard case .removed(let captured) = try await f.root.removeProjectionSource(grant, from: f.store,
        using: f.root.permission(), maximumBytes: 1024) else { throw StorageError.incomplete }
    #expect(!names.contains(captured.effect.record.cleanupDirectoryName))
    for name in names { #expect(try Data(contentsOf: URL(fileURLWithPath: f.path + "/" + name + "/foreign")) == Data([88])) }
    try await f.close()
}

@Test func projectionSourceReservationFailurePreventsMove() async throws {
    let f = try await DeletionFixture.make(), grant = try await f.authorize()
    try await f.store.lane.perform { try $0.exec("""
        CREATE TEMP TRIGGER fail_source BEFORE INSERT ON private_groups
        WHEN CAST(NEW.group_key AS TEXT) LIKE 'projection-source/%'
        BEGIN SELECT RAISE(ABORT,'injected source reservation failure'); END;
        """) }
    for _ in 0..<2 {
        await #expect(throws: StorageError.database(1811)) {
            try await f.root.removeProjectionSource(grant, from: f.store, using: f.root.permission(), maximumBytes: 1024,
                reserved: { _ in Issue.record("A failed reservation must precede physical admission") })
        }
        #expect(try f.disk() == [65])
        #expect(try await f.store.pendingProjectionSource(for: f.birth) == nil)
    }
    try await f.store.lane.perform { try $0.exec("DROP TRIGGER fail_source") }
    guard case .removed = try await f.root.removeProjectionSource(grant, from: f.store, using: f.root.permission(), maximumBytes: 1024) else {
        throw StorageError.incomplete
    }
    try await f.close()
}

@Test func projectionSourceReservationPersistsBeforePhysicalEntry() async throws {
    let f = try await DeletionFixture.make(), grant = try await f.authorize()
    let reserved = try await f.store.reserveProjectionSource(grant)
    #expect(try await f.store.pendingProjectionSource(for: f.birth) == reserved.record)
    #expect(try f.disk() == [65])
    #expect(!FileManager.default.fileExists(atPath: f.path + "/" + reserved.record.cleanupDirectoryName))
    try await f.store.checkProjectionSourceReservation(reserved)
    try await f.close()
}

@Test func projectionSourceRetirementFailurePreservesAttemptAndForeignDirectory() async throws {
    let f = try await DeletionFixture.make(), grant = try await f.authorize()
    let before = try await f.store.projectionObservations(for: f.birth)
    try await f.store.lane.perform { try $0.exec("""
        CREATE TEMP TRIGGER fail_source_retire BEFORE DELETE ON private_groups
        WHEN CAST(OLD.group_key AS TEXT) LIKE 'projection-source/%'
        BEGIN SELECT RAISE(ABORT,'injected source retirement failure'); END;
        """) }
    await #expect(throws: StorageError.database(1811)) {
        try await f.root.removeProjectionSource(grant, from: f.store, using: f.root.permission(), maximumBytes: 1024,
            reserved: { record in
                let path = f.path + "/" + record.cleanupDirectoryName
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try Data([88]).write(to: URL(fileURLWithPath: path + "/item"), options: .withoutOverwriting)
            })
    }
    let record = try #require(await f.store.pendingProjectionSource(for: f.birth))
    #expect(try f.disk() == [65])
    #expect(try Data(contentsOf: URL(fileURLWithPath: f.path + "/" + record.cleanupDirectoryName + "/item")) == Data([88]))
    #expect(try await f.store.projectionObservations(for: f.birth).value == before.value)
    await #expect(throws: StorageError.busy) {
        try await f.root.removeProjectionSource(grant, from: f.store, using: f.root.permission(), maximumBytes: 1024)
    }
    let other = try NoteBirth(bytes: Array(repeating: 2, count: 16))
    _ = try await put("still editable", birth: other, generation: 2, session: f.store)
    try await f.store.verifyCompletePrivateState()
    let selection = await f.store.selection
    try await f.close()
    let store = try await LocalStoreSession.open(selection: selection, protection: f.protection)
    let root = try await RepositoryRootSession.open(directory: f.path)
    let input = try await store.prepareProjectionSourceRecovery(for: f.birth)
    let inspected = try await root.inspectProjectionSource(input, from: store, maximumBytes: 1024, using: root.permission())
    guard case .snapshot(let source) = inspected.source, case .snapshot(let retained) = inspected.cleanup else {
        throw StorageError.incomplete
    }
    #expect(source.bytes == [65] && retained.bytes == [88])
    #expect(try await store.pendingProjectionSource(for: f.birth) == record)
    #expect(try await store.snapshot().notes.map(\.value.body.string) == ["still editable"])
    await root.close(); try await store.quiesce()
}

@Test func projectionSourceKeepsChangedArtifactForRecovery() async throws {
    let f = try await DeletionFixture.make(), grant = try await f.authorize()
    let result = try await f.root.removeProjectionSource(grant, from: f.store, using: f.root.permission(), maximumBytes: 1024,
        afterRemoval: {
            do {
                let directory = try #require(FileManager.default.contentsOfDirectory(atPath: f.path).first(where: { $0.hasPrefix(".nv-source-") }))
                try Data([88]).write(to: URL(fileURLWithPath: f.path + "/" + directory + "/item"), options: .withoutOverwriting)
            } catch { Issue.record(error) }
        })
    guard case .uncertain(let observed) = result else { throw StorageError.incomplete }
    #expect(try await f.store.pendingProjectionSource(for: f.birth) == observed.record)
    #expect(try Data(contentsOf: URL(fileURLWithPath: f.path + "/" + observed.record.cleanupDirectoryName + "/item")) == Data([88]))
    #expect(try await f.store.prepareProjectionSourceRecovery(for: f.birth).bytes == [65])
    try await f.close()
}

@Test(arguments: ["body", "equal-body", "mode"])
func projectionSourcePreservesChangedOriginal(change: String) async throws {
    let f = try await DeletionFixture.make(), grant = try await f.authorize()
    let result = try await f.root.removeProjectionSource(grant, from: f.store, using: f.root.permission(), maximumBytes: 1024,
        beforeRemoval: {
            do {
                if change == "mode" { try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: f.path + "/Note.txt") }
                else { try Data(change == "body" ? [88] : [65]).write(to: URL(fileURLWithPath: f.path + "/Note.txt"), options: .atomic) }
            } catch { Issue.record(error) }
        })
    guard case .notRemoved = result else { throw StorageError.incomplete }
    #expect(try f.disk() == (change == "body" ? [88] : [65]))
    #expect(try await f.store.pendingProjectionSource(for: f.birth) == nil)
    #expect(try await f.store.snapshot().notes.map(\.value.body.string) == ["untouched"])
    try await f.close()
}

@Test func projectionSourceKeepsNewSourceOccupant() async throws {
    let f = try await DeletionFixture.make(), grant = try await f.authorize()
    guard case .uncertain(let effect) = try await f.root.removeProjectionSource(grant, from: f.store,
        using: f.root.permission(), maximumBytes: 1024, afterRemoval: {
            do { try Data([88]).write(to: URL(fileURLWithPath: f.path + "/Note.txt"), options: .withoutOverwriting) }
            catch { Issue.record(error) }
        }) else { throw StorageError.incomplete }
    guard case .snapshot(let newer) = effect.source else { throw StorageError.incomplete }
    #expect(newer.bytes == [88])
    #expect(try await f.store.prepareProjectionSourceRecovery(for: f.birth).bytes == [65])
    #expect(try f.disk() == [88])
    #expect(try await f.store.pendingProjectionSource(for: f.birth) == effect.record)
    try await f.close()
}

@Test func projectionSourceRecoverySurvivesPrivateCopy() async throws {
    let f = try await DeletionFixture.make(utf16: true), grant = try await f.authorize()
    guard case .removed(let capture) = try await f.root.removeProjectionSource(grant, from: f.store,
        using: f.root.permission(), maximumBytes: 1024) else { throw StorageError.incomplete }
    let prior = try await f.store.prepareProjectionSourceRecovery(for: f.birth)
    let copy = try await f.store.preparePrivateStoreCopy(to: privateTempPath()), selection = copy.selection
    #expect(selection.store != capture.effect.record.scope.store)
    try await copy.close(); try await f.close()
    let store = try await LocalStoreSession.open(selection: selection, protection: f.protection)
    await #expect(throws: StorageError.wrongContext) { try await store.checkProjectionSourceRecovery(prior) }
    let input = try #require(try? await store.prepareProjectionSourceRecovery(for: f.birth))
    #expect(input.bytes == [255,254,65,0] && input.record == capture.effect.record)
    let root = try await RepositoryRootSession.open(directory: f.path), permission = try await root.permission()
    let inspected = try await root.inspectProjectionSource(input, from: store, maximumBytes: 1024, using: permission)
    try await root.validate(inspected, for: input, from: store, using: permission)
    guard case .unavailable(.absent) = inspected.cleanup else { throw StorageError.incomplete }
    #expect(try await store.snapshot().notes.count == 1)
    await root.close(); try await store.quiesce()
}

@Test func projectionSourceRecoveryBindsExactInputAndFinalOwner() async throws {
    let f = try await DeletionFixture.make(), other = try await f.sibling()
    let grant = try await f.authorize(), otherGrant = try await other.authorize()
    guard case .removed(let capture) = try await f.root.removeProjectionSource(grant, from: f.store,
        using: f.root.permission(), maximumBytes: 1024),
          case .removed = try await other.root.removeProjectionSource(otherGrant, from: other.store,
            using: other.root.permission(), maximumBytes: 1024) else { throw StorageError.incomplete }
    let input = try await f.store.prepareProjectionSourceRecovery(for: f.birth)
    let foreign = try await other.store.prepareProjectionSourceRecovery(for: other.birth)
    let inspected = try await f.root.inspectProjectionSource(input, from: f.store, maximumBytes: 1024, using: f.root.permission())
    await #expect(throws: StorageError.wrongContext, "Source inspection belongs to its exact input") {
        try await f.root.validate(inspected, for: foreign, from: f.store, using: f.root.permission())
    }
    let foreignRoot = try await RepositoryRootSession.open(directory: emptyRepository())
    await #expect(throws: RepositoryRootError.wrongContext) {
        try await foreignRoot.inspectProjectionSource(input, from: f.store, maximumBytes: 1024, using: foreignRoot.permission())
    }
    await foreignRoot.close()
    await #expect(throws: StorageError.integrity, "Recovery must check the final source owner") {
        try await f.root.inspectProjectionSource(input, from: f.store, maximumBytes: 1024, using: f.root.permission(), beforeRead: { name in
            if name == input.record.cleanupDirectoryName + "/item" {
                try await withThrowingTaskGroup(of: Bool.self) { group in
                    group.addTask {
                        try await f.store.lane.perform { try $0.run("UPDATE private_groups SET generation=2 WHERE group_key=?",
                            [.blob(Array(("projection-source/" + String(repeating: "01", count: 16)).utf8))]) }
                        return true
                    }
                    group.addTask { try await Task.sleep(nanoseconds: 20_000_000_000); return false }
                    defer { group.cancelAll() }
                    try #require(try await group.next() == true, "Recovery interference timed out")
                }
            }
        })
    }
    #expect(!FileManager.default.fileExists(atPath: f.path + "/" + capture.effect.record.cleanupDirectoryName + "/item"))
    try await f.close()
}

@Test(arguments: ["association", "record", "root"])
func projectionSourceFencesHeldCompletion(change: String) async throws {
    let f = try await DeletionFixture.make(), grant = try await f.authorize()
    let result = try await f.root.removeProjectionSource(grant, from: f.store, using: f.root.permission(), maximumBytes: 1024,
        afterRemoval: {
            let done = DispatchSemaphore(value: 0)
            Task {
                defer { done.signal() }
                do {
                    if change == "root" { await f.root.invalidate() }
                    else if change == "record" {
                        try await f.store.lane.perform { try $0.run("UPDATE private_groups SET generation=2 WHERE group_key=?",
                            [.blob(Array(("projection-source/" + String(repeating: "01", count: 16)).utf8))]) }
                    } else {
                        let prior = try await f.store.localAssociation(), a = try #require(prior.value)
                        try await f.store.saveLocalAssociation(.init(id: a.id, scope: a.scope, bookmark: .init(codec: 1, bytes: [9])), basedOn: prior)
                    }
                } catch { Issue.record(error) }
            }
            if done.wait(timeout: .now() + 20) != .success { Issue.record("Post-move interference timed out") }
        })
    #expect({ if case .uncertain = result { true } else { false } }(), "A changed owner fences source completion")
    guard case .uncertain(let observed) = result else { throw StorageError.incomplete }
    #expect(!FileManager.default.fileExists(atPath: f.path + "/" + observed.record.cleanupDirectoryName + "/item"))
    #expect(!FileManager.default.fileExists(atPath: f.path + "/Note.txt"))
    let rows = try await f.store.lane.perform { try $0.rows("SELECT generation FROM private_groups WHERE group_key=?",
        [.blob(Array(("projection-source/" + String(repeating: "01", count: 16)).utf8))]) }
    #expect(rows == [[.integer(change == "record" ? 2 : 1)]])
    try await f.close()
}

@Test(arguments: ["codec", "payload", "key", "owner", "action"])
func projectionSourceValidatesRequiredRecoveryRecord(damage: String) async throws {
    let f = try await DeletionFixture.make(), (capture, input) = try await f.prepare(), original = try await f.original(input)
    let receipt = try requireReceipt(await f.store.persist(capture: capture))
    let grant = try await f.store.authorizeProjectionDeletion(original, committed: receipt), reserved = try await f.store.reserveProjectionSource(grant)
    let previous = try #require(await f.store.projectionObservations(for: f.birth).value)
    try await f.store.verifyCompletePrivateState()
    let key = Array(("projection-source/" + String(repeating: "01", count: 16)).utf8)
    try await f.store.lane.perform { db in
        switch damage {
        case "codec": try db.run("UPDATE private_groups SET codec=2 WHERE group_key=?", [.blob(key)])
        case "payload": try db.run("UPDATE private_groups SET payload=? WHERE group_key=?", [.blob([0]), .blob(key)])
        case "key": try db.run("UPDATE private_groups SET group_key=? WHERE group_key=?",
            [.blob(Array(("projection-source/" + String(repeating: "02", count: 16)).utf8)), .blob(key)])
        case "owner":
            let old = previous
            let state = try ProjectionObservationsV1(profile: .plaintextFiles, scope: old.scope, association: old.association,
                birth: old.birth, accepted: nil, intended: nil)
            try db.run("UPDATE private_groups SET generation=generation+1,payload=? WHERE group_key=?",
                [.blob(state.encodedV1()), .blob(DeletionFixture.key(f.birth))])
        default:
            let old = reserved.record, action = try #require(capture.context.collectionActions.first)
            let changed = try ProjectionSourceAttemptV1(profile: .plaintextFiles, scope: old.scope, association: old.association,
                attempt: old.attempt, deletion: action, source: old.source, root: old.root, observation: old.observation)
            try db.run("UPDATE private_groups SET payload=? WHERE group_key=?", [.blob(changed.encodedV1()), .blob(key)])
        }
    }
    let expected: StorageError = damage == "codec" ? .unsupported : .integrity
    await #expect(throws: expected) { try await f.store.verifyCompletePrivateState() }
    #expect(try f.disk() == [65])
    await f.root.close(); await f.store.lane.close()
}

private struct SourceProcessContext: Codable {
    let directory, repository: String
    let store, descriptor: [UInt8]
    let syncFaultLibrary: String
    func selection() throws -> LocalStoreSelection {
        try .init(directory: directory, store: .init(bytes: store), descriptor: .decodeV1(descriptor))
    }
}

private struct SourceProcessReport: Codable {
    let source: [UInt8]?
    let cleanup: [UInt8]?
    let record: [UInt8]?
    let notes: [String]
}

/// Builds the syscall fault layer used only by this fresh-process fixture.
private func sourceSyncFaultLibrary(in directory: URL) throws -> String {
    #if canImport(Darwin)
    let output = directory.appendingPathComponent("source-sync.dylib")
    let link = ["-dynamiclib"]
    #else
    let output = directory.appendingPathComponent("source-sync.so")
    let link = ["-shared", "-fPIC", "-ldl"]
    #endif
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wconversion", "-Wsign-conversion", "-O2"]
        + link + [try projectionSyncFaultSource().path, "-o", output.path]
    try process.run(); process.waitUntilExit()
    try #require(process.terminationReason == .exit && process.terminationStatus == 0)
    return output.path
}

private func sourceChild(_ context: URL, mode: String, status: Int32) throws {
    let arguments = CommandLine.arguments, process = Process()
    process.executableURL = URL(fileURLWithPath: arguments[0])
    var childArguments: [String] = []
    if let index = arguments.firstIndex(of: "--test-bundle-path") {
        try #require(index + 1 < arguments.count)
        childArguments += ["--test-bundle-path", arguments[index + 1]]
    }
    process.arguments = childArguments + ["--testing-library", "swift-testing", "--filter", "projectionSourceCrashChild"]
    var environment = ProcessInfo.processInfo.environment
    environment["NV_P62_SOURCE_CONTEXT"] = context.path; environment["NV_P62_SOURCE_MODE"] = mode
    let input = try JSONDecoder().decode(SourceProcessContext.self, from: Data(contentsOf: context))
    environment["NV_P62_SOURCE_REPOSITORY"] = input.repository
    #if canImport(Darwin)
    let injection = "DYLD_INSERT_LIBRARIES"
    #else
    let injection = "LD_PRELOAD"
    #endif
    environment[injection] = [environment[injection], input.syncFaultLibrary].compactMap { $0 }.joined(separator: ":")
    process.environment = environment
    let log = context.deletingLastPathComponent().appendingPathComponent(mode + "-" + UUID().uuidString + ".log")
    try Data().write(to: log, options: .withoutOverwriting)
    let output = try FileHandle(forWritingTo: log)
    defer { try? output.close() }
    process.standardOutput = output; process.standardError = output
    try process.run()
    let deadline = Date().addingTimeInterval(45)
    while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    if process.isRunning { process.terminate(); throw StorageError.busy }
    process.waitUntilExit()
    let text = try String(contentsOf: log, encoding: .utf8)
    try #require(process.terminationReason == .exit && process.terminationStatus == status, "Child log: \(log.path)\n\(text)")
    try #require(text.contains("projectionSourceCrashChild() started."), "The child must discover the intended participant")
    if status == 0 { try #require(text.contains("Test run with 1 test")) }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["NV_P62_SOURCE_CONTEXT"] != nil), .timeLimit(.minutes(1)))
func projectionSourceCrashChild() async throws {
    let url = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NV_P62_SOURCE_CONTEXT"]))
    let context = try JSONDecoder().decode(SourceProcessContext.self, from: Data(contentsOf: url))
    let mode = try #require(ProcessInfo.processInfo.environment["NV_P62_SOURCE_MODE"])
    let store = try await LocalStoreSession.open(selection: context.selection(), protection: .publicHash)
    let root = try await RepositoryRootSession.open(directory: context.repository), permission = try await root.permission()
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    if mode == "inspect" || mode == "inspect-exit" {
        let record = try await store.pendingProjectionSource(for: birth)
        var source: [UInt8]?, cleanup: [UInt8]?
        if record != nil {
            let input = try await store.prepareProjectionSourceRecovery(for: birth)
            let inspected = try await root.inspectProjectionSource(input, from: store, maximumBytes: 1024, using: permission)
            if case .snapshot(let file) = inspected.source { source = file.bytes }
            if case .snapshot(let file) = inspected.cleanup { cleanup = file.bytes }
        } else {
            if case .snapshot(let file) = try await root.readProjection(root.observe("Note.txt", using: permission), maximumBytes: 1024, using: permission) {
                source = file.bytes
            }
        }
        if mode == "inspect-exit" { _exit(86) }
        let report = try await SourceProcessReport(source: source, cleanup: cleanup, record: record?.encodedV1(),
            notes: store.snapshot().notes.map(\.value.body.string).sorted())
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        try encoder.encode(report).write(to: url.appendingPathExtension("report"), options: .atomic)
    } else {
        let snapshot = try await store.snapshot(), capture = try CapturedActionGroup(snapshot: snapshot, kind: .deleteBatch,
            changes: [.delete(.init(birth: birth, generation: 2))])
        let input = try await store.prepareProjectionDeletion(capture: capture, birth: birth, observations: store.projectionObservations(for: birth), basedOn: snapshot)
        guard case .snapshot(let source) = try await root.readProjection(root.observe("Note.txt", using: permission), maximumBytes: 1024, using: permission) else {
            throw StorageError.incomplete
        }
        let original = try await root.captureProjectionDeletion(input, source: source, from: store, using: permission)
        let receipt = try requireReceipt(await store.persist(capture: capture))
        let grant = try await store.authorizeProjectionDeletion(original, committed: receipt)
        if mode == "before-reservation" { _exit(86) }
        let result = try await root.removeProjectionSource(grant, from: store, using: permission, maximumBytes: 1024,
            reserved: { record in
                if mode == "reserved" { _exit(86) }
                if mode.hasPrefix("protected-") {
                    // Separate malformed/changed recovery fixtures from actual native interruption cuts.
                    let directory = context.repository + "/" + record.cleanupDirectoryName
                    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    try FileManager.default.moveItem(atPath: context.repository + "/Note.txt", toPath: directory + "/item")
                    if mode == "protected-edit-fixture" { try Data([88]).write(to: URL(fileURLWithPath: directory + "/item"), options: .atomic) }
                    if mode == "protected-and-public-fixture" { try Data([89]).write(to: URL(fileURLWithPath: context.repository + "/Note.txt")) }
                    _exit(86)
                }
            }, beforeRemoval: { if mode == "before-removal" { _exit(86) } },
            afterRemoval: { if mode == "after-removal" { _exit(86) } })
        if mode == "native-sync-failure" {
            guard case .notRemoved = result else { throw StorageError.incomplete }
            _exit(86)
        }
        guard case .removed = result else { throw StorageError.incomplete }
        if mode == "returned" { _exit(86) }
    }
    await root.close(); try await store.quiesce()
}

@Test(.timeLimit(.minutes(2)), arguments: ["before-reservation", "reserved", "before-removal", "after-removal", "returned",
    "native-before-capture", "native-captured", "native-unlinked", "native-sync-failure",
    "protected-capture-fixture", "protected-edit-fixture", "protected-and-public-fixture"])
func projectionSourceFreshProcessRecovery(cut: String) async throws {
    let f = try await DeletionFixture.make(utf16: true), selection = await f.store.selection
    let url = URL(fileURLWithPath: try emptyRepository()).appendingPathComponent("context.json")
    try JSONEncoder().encode(SourceProcessContext(directory: selection.directory, repository: f.path,
        store: selection.store.bytes, descriptor: selection.descriptor.encodedBytes,
        syncFaultLibrary: sourceSyncFaultLibrary(in: url.deletingLastPathComponent()))).write(to: url)
    try await f.close()
    try sourceChild(url, mode: cut, status: 86)
    try sourceChild(url, mode: "inspect-exit", status: 86)
    try sourceChild(url, mode: "inspect", status: 0)
    let first = try Data(contentsOf: url.appendingPathExtension("report"))
    try sourceChild(url, mode: "inspect", status: 0)
    #expect(try Data(contentsOf: url.appendingPathExtension("report")) == first)
    let report = try JSONDecoder().decode(SourceProcessReport.self, from: first)
    let expected: [UInt8] = [255,254,65,0], protected = cut.hasPrefix("protected-") || cut == "native-captured"
    let removed = ["after-removal", "returned", "native-unlinked"].contains(cut)
    let source: [UInt8]? = cut == "protected-and-public-fixture" ? [89] : protected || removed ? nil : expected
    let retained: [UInt8]? = cut == "protected-edit-fixture" ? [88] : protected ? expected : nil
    #expect(report.notes == ["untouched"] && report.source == source)
    #expect(report.cleanup == retained)
    #expect((report.record != nil) == (cut != "before-reservation"))
    if let bytes = report.record {
        let record = try ProjectionSourceAttemptV1.decodeV1(bytes, profile: .plaintextFiles)
        if !removed {
            let name = protected ? record.cleanupDirectoryName + "/item" : "Note.txt"
            #expect(try Data(contentsOf: URL(fileURLWithPath: f.path + "/" + name)) == Data(retained ?? expected))
        } else {
            #expect(!FileManager.default.fileExists(atPath: f.path + "/" + record.cleanupDirectoryName + "/item"))
        }
        let store = try await LocalStoreSession.open(selection: selection, protection: f.protection)
        #expect(try await store.retainedObject(at: record.deletion.locator).count > 0)
        await #expect(throws: StorageError.staleCapture) {
            try await CapturedActionGroup(snapshot: store.snapshot(), kind: .deleteBatch,
                changes: [.delete(.init(birth: f.birth, generation: 3))])
        }
        try await store.quiesce()
    }
}

private actor DeletionAcceptanceGate {
    let entered = ImprovementGate(), release = ImprovementGate()
    private var held = false
    func pauseFirst() async {
        guard !held else { return }
        held = true
        await entered.signal(); await release.wait()
    }
}

extension LocalStoreSession {
    fileprivate func sealedDeletionForTesting() throws -> SealedCommit {
        guard let sealed = commitState.owned?.sealed else { throw StorageError.incomplete }
        return sealed
    }
}

@Test(.timeLimit(.minutes(1)))
func projectionDeletionAcceptsRepackagedCommandBeforeLocalEnvelope() async throws {
    let f = try await DeletionFixture.make(), (capture, input) = try await f.prepare(), original = try await f.original(input)
    let gate = DeletionAcceptanceGate()
    try await f.store.lane.perform { db in
        db.work = StorageWork(); db.work?.localCommitSealed = { await gate.pauseFirst() }
    }
    let saving = Task { try await f.store.persist(capture: capture) }
    await gate.entered.wait()
    defer { Task { await gate.release.signal() } }
    let sealed = try await f.store.sealedDeletionForTesting(), selection = await f.store.selection
    let repackaged = try ObjectEnvelopeV1.seal(payload: sealed.payload.encodedV1(), kind: .changes,
        collection: selection.descriptor.collection, writer: .init(bytes: Array(repeating: 99, count: 16)),
        sequence: 0, protection: f.protection)
    let locator = try ObjectEnvelopeV1.open(repackaged, collection: selection.descriptor.collection, protection: f.protection).locator
    guard case .accepted(let sequence) = try await f.store.receive(repackaged) else { throw StorageError.incomplete }
    await gate.release.signal()
    let receipt = try requireReceipt(await saving.value)
    #expect(receipt.object == sealed.locator && receipt.object != locator && receipt.sequence == sequence + 1)
    let grant = try #require(try? await f.store.authorizeProjectionDeletion(original, committed: receipt),
        "A different envelope may already contain the accepted command")
    #expect(grant.deletion.id == capture.action && grant.deletion.locator == locator)
    try await f.root.validate(grant, from: f.store, using: f.root.permission())
    #expect(try await f.store.retainedObject(at: receipt.object) == sealed.bytes)
    #expect(try await f.store.retainedObject(at: locator) == repackaged)
    #expect(try await f.store.snapshot().notes.map(\.value.body.string) == ["untouched"])
    #expect(try f.disk() == [65])
    try await f.close()
}

@Test(arguments: [false, true], [false, true])
func projectionDeletionRequiresOriginalLocalBarrier(utf16: Bool, batch: Bool) async throws {
    let f = try await DeletionFixture.make(utf16: utf16), (capture, input) = try await f.prepare(batch: batch)
    let original = try await f.original(input), before = try await f.store.projectionObservations(for: f.birth)
    #expect(input.bytes == f.source.bytes)
    let receipt = try requireReceipt(await f.store.persist(capture: capture))
    let grant = try await f.store.authorizeProjectionDeletion(original, committed: receipt)
    try await f.root.validate(grant, from: f.store, using: f.root.permission())
    #expect(grant.deletion.id == capture.action && grant.deletion.locator == receipt.object)
    #expect(try await f.store.snapshot().notes.map(\.value.body.string) == (batch ? [] : ["untouched"]))
    #expect(try await f.store.projectionObservations(for: f.birth).value == before.value)
    #expect(try f.disk() == (utf16 ? [255,254,65,0] : [65]))
    await #expect(throws: StorageError.staleCapture) { try await f.original(input) }
    let retried = try requireReceipt(await f.store.persist(capture: capture))
    #expect(retried.object == receipt.object && retried.sequence == receipt.sequence)
    _ = try await f.store.authorizeProjectionDeletion(original, committed: retried)
    try await f.close()
}

@Test(arguments: ["put", "frozen", "history"])
func projectionDeletionRequiresCheckedOriginalSource(failure: String) async throws {
    let f = try await DeletionFixture.make()
    if failure == "put" {
        let snapshot = try await f.store.snapshot(), note = try #require(snapshot.notes.first(where: { $0.birth == f.birth }))
        let capture = try CapturedActionGroup(snapshot: snapshot, kind: .savedEdit,
            changes: [.put(.init(birth: f.birth, generation: 2), note.value)])
        await #expect(throws: StorageError.staleCapture, "Only captured Delete changes qualify") {
            try await f.store.prepareProjectionDeletion(capture: capture, birth: f.birth,
                observations: f.store.projectionObservations(for: f.birth), basedOn: snapshot)
        }
    } else if failure == "frozen" {
        _ = try await put("B", birth: f.birth, generation: 2, session: f.store)
        let intent = try await f.store.prepareProjectionIntent(for: f.birth,
            filename: .init(ExactUTF8(bytes: Array("Note.txt".utf8))), basedOn: f.store.snapshot(),
            observations: f.store.projectionObservations(for: f.birth))
        try await f.store.retainProjectionIntent(intent)
        _ = try await f.store.freezeProjectionIntent(observations: f.store.projectionObservations(for: f.birth))
        await #expect(throws: StorageError.staleCapture, "An unfinished frozen output retains its separate source obligation") { try await f.prepare() }
    } else {
        let prior = try #require(await f.store.projectionObservations(for: f.birth).value?.accepted)
        let ref = try #require(prior.output.binding.occurrences.first)
        try await f.store.lane.perform { db in
            try db.exec("DROP TRIGGER objects_no_update")
            try db.run("UPDATE objects SET encoded=? WHERE object_id=?", [.blob([0]), .blob(ref.locator.segmentID.bytes)])
        }
        await #expect(throws: CanonicalEncodingError.lengthLimit) { try await f.prepare() }
    }
    #expect(try f.disk() == [65])
    try await f.close()
}

@Test func projectionDeletionRejectsForeignStore() async throws {
    let f = try await DeletionFixture.make(), other = try await DeletionFixture.make()
    let (capture, input) = try await f.prepare(), original = try await f.original(input)
    await #expect(throws: StorageError.wrongContext) { try await other.store.checkProjectionDeletionCapture(input) }
    let receipt = try requireReceipt(await f.store.persist(capture: capture))
    let grant = try await f.store.authorizeProjectionDeletion(original, committed: receipt)
    await #expect(throws: StorageError.wrongContext) { try await other.store.checkProjectionDeletion(grant) }
    await #expect(throws: StorageError.wrongContext) { try await other.store.authorizeProjectionDeletion(original, committed: receipt) }
    #expect(try f.disk() == [65] && other.disk() == [65])
    try await f.close(); try await other.close()
}

@Test func projectionDeletionRejectsReceiptForAnotherCommand() async throws {
    let f = try await DeletionFixture.make()
    let wrong = try await put("B", birth: f.birth, generation: 2, session: f.store)
    let (capture, input) = try await f.prepare(), original = try await f.original(input)
    #expect(wrong.covered == capture.covered)
    await #expect(throws: StorageError.wrongContext, "Receipt must name the original Delete command") {
        try await f.store.authorizeProjectionDeletion(original, committed: wrong)
    }
    let receipt = try requireReceipt(await f.store.persist(capture: capture))
    let grant = try await f.store.authorizeProjectionDeletion(original, committed: receipt)
    try await f.root.validate(grant, from: f.store, using: f.root.permission())
    #expect(try f.disk() == [65])
    try await f.close()
}

@Test(arguments: ["body", "equal-replacement", "root"])
func projectionDeletionRequiresAcceptedPhysicalIdentity(change: String) async throws {
    let f = try await DeletionFixture.make(), (_, input) = try await f.prepare()
    let root: RepositoryRootSession, name = "Note.txt"
    if change == "root" {
        let path = try emptyRepository()
        try Data([65]).write(to: URL(fileURLWithPath: path + "/" + name))
        root = try await RepositoryRootSession.open(directory: path)
    } else {
        root = f.root
        try Data(change == "body" ? [88] : [65]).write(to: URL(fileURLWithPath: f.path + "/" + name), options: .atomic)
    }
    let observed = try await root.observe(name, using: root.permission())
    guard case .snapshot(let changed) = try await root.readProjection(observed, maximumBytes: 1024, using: root.permission()) else {
        throw StorageError.incomplete
    }
    await #expect(throws: RepositoryRootError.wrongContext, "Captured source must match the accepted physical observation") {
        try await f.root.captureProjectionDeletion(input, source: changed, from: f.store, using: f.root.permission())
    }
    #expect(try await f.store.snapshot().notes.count == 2)
    if change == "root" { await root.close() }
    try await f.close()
}

@Test(arguments: ["before", "during"])
func projectionDeletionFencesPreAdmissionCapture(when: String) async throws {
    let f = try await DeletionFixture.make(), (_, input) = try await f.prepare()
    if when == "before" { _ = try await put("B", birth: f.birth, generation: 2, session: f.store) }
    await #expect(throws: StorageError.staleCapture, "The original file capture must precede Delete admission") {
        try await f.root.captureProjectionDeletion(input, source: f.source, from: f.store, using: f.root.permission(), beforeIssue: {
            if when == "during" { _ = try await put("B", birth: f.birth, generation: 2, session: f.store) }
        })
    }
    #expect(try f.disk() == [65])
    #expect(try await f.store.snapshot().notes.map(\.value.body.string).sorted() == ["B", "untouched"])
    try await f.close()
}

@Test(arguments: ["association", "source", "reopen", "root"])
func projectionDeletionRejectsChangedLiveOwner(change: String) async throws {
    let f = try await DeletionFixture.make(), (capture, input) = try await f.prepare(), original = try await f.original(input)
    let receipt = try requireReceipt(await f.store.persist(capture: capture))
    let grant = try await f.store.authorizeProjectionDeletion(original, committed: receipt)
    switch change {
    case "association":
        let prior = try await f.store.localAssociation(), value = try #require(prior.value)
        try await f.store.saveLocalAssociation(.init(id: value.id, scope: value.scope, bookmark: .init(codec: 1, bytes: [9])), basedOn: prior)
        await #expect(throws: StorageError.staleCapture) { try await f.store.checkProjectionDeletion(grant) }
    case "source":
        try await f.store.lane.perform { try $0.run("UPDATE private_groups SET generation=generation+1 WHERE group_key=?",
            [.blob(DeletionFixture.key(f.birth))]) }
        await #expect(throws: StorageError.staleCapture) { try await f.store.checkProjectionDeletion(grant) }
    case "reopen":
        let selection = await f.store.selection
        try await f.store.quiesce()
        let reopened = try await LocalStoreSession.open(selection: selection, protection: f.protection)
        await #expect(throws: StorageError.wrongContext) { try await reopened.checkProjectionDeletion(grant) }
        await #expect(throws: StorageError.wrongContext) { try await reopened.authorizeProjectionDeletion(original, committed: receipt) }
        await #expect(throws: StorageError.wrongContext) { try await reopened.checkProjectionDeletionCapture(input) }
        #expect(try await reopened.snapshot().notes.map(\.value.body.string) == ["untouched"])
        try await reopened.quiesce()
        await f.root.close()
        #expect(try f.disk() == [65])
        return
    default:
        let permission = try await f.root.permission()
        await f.root.invalidate()
        await #expect(throws: RepositoryRootError.stalePermission) {
            try await f.root.validate(grant, from: f.store, using: permission)
        }
    }
    #expect(try f.disk() == [65])
    try await f.close()
}
