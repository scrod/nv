import Foundation
import Testing
import NVStorageCore
import NVStorageTestSupport
@testable import NVStorageRuntime

#if canImport(Darwin)
import Darwin
private struct PhysicalReplacementFixture {
    let store: LocalStoreSession
    let root: RepositoryRootSession
    let path: String
    let birth: NoteBirth
    let protection: ObjectProtectionV1
    let input: PreparedProjectionReplacement
    let source: ProjectionFileSnapshot

    static func make(utf16: Bool = false) async throws -> Self {
        let base = try await PhysicalSourceFixture.make(utf16: utf16)
        let store = base.store, birth = base.birth
        _ = try await put("B", birth: birth, generation: 1, session: store)
        try await base.intend(name: "Note.txt", utf16: utf16)
        let input = try await store.prepareProjectionReplacement(observations: store.projectionObservations(for: birth), basedOn: store.snapshot())
        return Self(store: store, root: base.root, path: base.path, birth: birth, protection: base.protection, input: input, source: base.source)
    }

    func disk(_ name: String = "Note.txt") throws -> [UInt8] { Array(try Data(contentsOf: URL(fileURLWithPath: path + "/" + name))) }
    func close() async throws { await root.close(); try await store.quiesce() }

    /// Seeds an accepted comparison while keeping the real frozen output and historical source owned.
    func preparing(physical: PassivePlatformRecordV1) async throws -> PreparedProjectionReplacement {
        let prior = try #require(await store.projectionObservations(for: birth).value)
        let source = try #require(prior.accepted), frozen = try #require(prior.frozen)
        let accepted = try AcceptedProjectionV1(output: source.output, physical: physical, encoding: source.encoding,
            tags: source.tags, created: source.created, modified: source.modified)
        let transition = try IntendedProjectionV1(output: frozen.output, source: accepted)
        let value = try ProjectionObservationsV1(profile: .plaintextFiles, scope: prior.scope, association: prior.association,
            birth: birth, accepted: accepted, intended: transition, frozen: transition)
        try await store.lane.perform { try $0.run("UPDATE private_groups SET generation=generation+1,payload=? WHERE group_key=?",
            [.blob(value.encodedV1()), .blob(Array(("projection/" + String(repeating: "01", count: 16)).utf8))]) }
        return try await store.prepareProjectionReplacement(observations: store.projectionObservations(for: birth), basedOn: store.snapshot())
    }
}

/// One real verified source shared by replacement and relocation test setup.
private struct PhysicalSourceFixture {
    let store: LocalStoreSession
    let root: RepositoryRootSession
    let path: String
    let birth: NoteBirth
    let protection: ObjectProtectionV1
    let source: ProjectionFileSnapshot

    static func make(utf16: Bool = false) async throws -> Self {
        let (initial, protection) = try testInitial(false), store = try await newSession(initial, protection)
        let path: String
        if let parent = ProcessInfo.processInfo.environment["NV_P62_REPOSITORY_PARENT"] {
            path = URL(fileURLWithPath: parent).appendingPathComponent(UUID().uuidString).path
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        } else { path = try emptyRepository() }
        let root = try await RepositoryRootSession.open(directory: path)
        let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
        let association = try await root.association(for: store.selection, id: .init(bytes: Array(repeating: 13, count: 16)))
        try await store.saveLocalAssociation(association, basedOn: store.localAssociation())
        func intendInitial() async throws {
            let prepared = try await store.prepareProjectionIntent(for: birth, filename: .init(ExactUTF8(bytes: Array("Note.txt".utf8))),
                basedOn: store.snapshot(), observations: store.projectionObservations(for: birth),
                requestedEncoding: .init(rawValue: utf16 ? 10 : 4))
            try await store.retainProjectionIntent(prepared)
            _ = try await store.freezeProjectionIntent(observations: store.projectionObservations(for: birth))
        }
        try await intendInitial()
        let creation = try await store.prepareProjectionCreation(observations: store.projectionObservations(for: birth), basedOn: store.snapshot())
        guard case .verified = try await root.createProjection(creation, from: store, using: root.permission()) else {
            throw StorageError.incomplete
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path + "/Note.txt")
        let observation = try await root.observe("Note.txt", using: root.permission())
        guard case .snapshot(let source) = try await root.readProjection(observation, maximumBytes: 1024, using: root.permission()) else {
            throw StorageError.incomplete
        }
        let prior = try #require(await store.projectionObservations(for: birth).value)
        // Seed the later settlement layer's passive accepted record from a real verified creation.
        let accepted = try AcceptedProjectionV1(output: creation.output, physical: source.physicalRecord,
            encoding: nil, tags: nil, created: nil, modified: nil)
        let state = try ProjectionObservationsV1(profile: .plaintextFiles, scope: prior.scope, association: prior.association,
            birth: birth, accepted: accepted, intended: nil)
        try await store.lane.perform { try $0.run("UPDATE private_groups SET generation=generation+1,payload=? WHERE group_key=?",
            [.blob(state.encodedV1()), .blob(Array(("projection/" + String(repeating: "01", count: 16)).utf8))]) }
        return Self(store: store, root: root, path: path, birth: birth, protection: protection, source: source)
    }

    func disk(_ name: String = "Note.txt") throws -> [UInt8] { Array(try Data(contentsOf: URL(fileURLWithPath: path + "/" + name))) }
    func close() async throws { await root.close(); try await store.quiesce() }

    func intend(name: String, utf16: Bool, freeze: Bool = true) async throws {
        let prepared = try await store.prepareProjectionIntent(for: birth,
            filename: .init(ExactUTF8(bytes: Array(name.utf8))), basedOn: store.snapshot(),
            observations: store.projectionObservations(for: birth), requestedEncoding: .init(rawValue: utf16 ? 10 : 4))
        try await store.retainProjectionIntent(prepared)
        if freeze { _ = try await store.freezeProjectionIntent(observations: store.projectionObservations(for: birth)) }
    }
}

private struct PhysicalRelocationFixture {
    let base: PhysicalSourceFixture
    let input: PreparedProjectionRelocation
    var store: LocalStoreSession { base.store }
    var root: RepositoryRootSession { base.root }
    var path: String { base.path }
    var birth: NoteBirth { base.birth }
    var source: ProjectionFileSnapshot { base.source }
    var target: String { input.output.binding.descriptor.filename.spelling.string }

    static func make(utf16: Bool = false, target: String = "Moved.txt") async throws -> Self {
        let base = try await PhysicalSourceFixture.make(utf16: utf16)
        _ = try await put("B", birth: base.birth, generation: 1, session: base.store)
        try await base.intend(name: target, utf16: utf16)
        let input = try await base.store.prepareProjectionRelocation(observations: base.store.projectionObservations(for: base.birth),
            basedOn: base.store.snapshot())
        return Self(base: base, input: input)
    }
}

@Test(arguments: [false, true], ["Moved.txt", "note.txt", "Note.html", "Résumé.txt"])
func projectionRelocationInstallsExactOutputAndRecovers(utf16: Bool, target: String) async throws {
    let f = try await PhysicalRelocationFixture.make(utf16: utf16, target: target)
    let before = try await f.store.projectionObservations(for: f.birth), selection = await f.store.selection
    let permission = try await f.root.permission()
    let result = try await f.root.relocateProjection(f.input, source: f.source,
        from: f.store, using: permission, maximumDisplacedBytes: 1024)
    guard case .installed(let receipt) = result else {
        Issue.record("Expected installed relocation: \(result)"); try await f.base.close(); return
    }
    let old: [UInt8] = utf16 ? [255,254,65,0] : [65], next: [UInt8] = utf16 ? [255,254,66,0] : [66]
    #expect(receipt.file.bytes == next && receipt.displaced.bytes == old && receipt.sourceMatched)
    #expect(receipt.file.permissions == 0o640 && receipt.displaced.permissions == 0o640)
    #expect(receipt.reservation.operation == .relocation)
    #expect(try f.base.disk(target) == next && f.base.disk(receipt.reservation.backupName) == old)
    #expect(try await f.store.projectionObservations(for: f.birth).value == before.value)
    switch receipt.source {
    case .snapshot(let alias):
        #expect(target == "note.txt" && alias.bytes == next)
        #expect(try alias.physicalRecord == receipt.file.physicalRecord)
    case .unavailable(let failure): #expect(failure == .absent)
    case .placeholder: Issue.record("The locally installed source alias is materialized")
    }
    try await f.root.validate(receipt, for: f.input, from: f.store, using: permission)
    let otherInput = try await f.store.prepareProjectionRelocation(observations: f.store.projectionObservations(for: f.birth), basedOn: f.store.snapshot())
    await #expect(throws: RepositoryRootError.wrongContext, "The relocation receipt belongs to its exact prepared operation") {
        try await f.root.validate(receipt, for: otherInput, from: f.store, using: permission)
    }
    await #expect(throws: StorageError.busy) {
        try await f.root.relocateProjection(f.input, source: f.source, from: f.store, using: permission, maximumDisplacedBytes: 1024)
    }
    await #expect(throws: StorageError.wrongContext) { try await f.store.prepareProjectionReplacementRecovery(for: f.birth) }
    try await f.base.close()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: f.base.protection)
    let root = try await RepositoryRootSession.open(directory: f.path)
    let recovery = try await reopened.prepareProjectionRelocationRecovery(for: f.birth)
    #expect(recovery.sourceBytes == old && recovery.outputBytes == next && recovery.record == receipt.reservation)
    let inspection = try await root.inspectProjectionRelocation(recovery, from: reopened, maximumBytes: 1024, using: root.permission())
    guard case .snapshot(let current) = inspection.current, case .snapshot(let backup) = inspection.backup else { throw StorageError.incomplete }
    #expect(current.bytes == next && backup.bytes == old)
    #expect(try await reopened.projectionObservations(for: f.birth).value == before.value)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["B", "untouched"])
    await root.close(); try await reopened.quiesce()
}

@Test func projectionRelocationBurnsOnlyUncapturedCandidates() async throws {
    let f = try await PhysicalRelocationFixture.make()
    var names = Set<String>()
    for _ in 0..<2 {
        let result = try await f.root.relocateProjection(f.input, source: f.source, from: f.store,
            using: f.root.permission(), maximumDisplacedBytes: 1024, reserved: { record in
                try Data([88]).write(to: URL(fileURLWithPath: f.path + "/" + record.backupName), options: .withoutOverwriting)
            })
        guard case .notInstalled(let failure) = result else { throw StorageError.incomplete }
        #expect(failure.reason == .conflict && names.insert(failure.reservation.backupName).inserted)
        #expect(try f.base.disk() == [65] && f.base.disk(failure.reservation.backupName) == [88])
        #expect(try await f.store.pendingProjectionReplacement(for: f.birth) == nil)
    }
    guard case .installed(let receipt) = try await f.root.relocateProjection(f.input, source: f.source,
        from: f.store, using: f.root.permission(), maximumDisplacedBytes: 1024) else { throw StorageError.incomplete }
    #expect(!names.contains(receipt.reservation.backupName))
    for name in names { #expect(try f.base.disk(name) == [88]) }
    try await f.base.close()
}

@Test func projectionRelocationRetirementFailurePreservesCandidate() async throws {
    let f = try await PhysicalRelocationFixture.make()
    try await f.store.lane.perform { try $0.exec("CREATE TEMP TRIGGER relocation_retire_fail BEFORE DELETE ON private_groups BEGIN SELECT RAISE(ABORT,'retirement failure'); END") }
    for _ in 0..<2 {
        await #expect(throws: StorageError.database(1811)) {
            try await f.root.relocateProjection(f.input, source: f.source, from: f.store,
                using: f.root.permission(), maximumDisplacedBytes: 1024, reserved: { record in
                    try Data([88]).write(to: URL(fileURLWithPath: f.path + "/" + record.backupName), options: .withoutOverwriting)
                })
        }
        let candidate = try #require(await f.store.pendingProjectionReplacement(for: f.birth))
        #expect(try f.base.disk() == [65] && f.base.disk(candidate.backupName) == [88])
        #expect(!FileManager.default.fileExists(atPath: f.path + "/" + f.target))
        let recovery = try await f.store.prepareProjectionRelocationRecovery(for: f.birth)
        let read = try await f.root.inspectProjectionRelocation(recovery, from: f.store, maximumBytes: 1024, using: f.root.permission())
        guard case .snapshot(let original) = read.source, case .snapshot(let foreign) = read.backup,
            case .unavailable(.absent) = read.current else { throw StorageError.incomplete }
        #expect(original.bytes == [65] && foreign.bytes == [88])
        await #expect(throws: StorageError.busy) {
            try await f.root.relocateProjection(f.input, source: f.source, from: f.store, using: f.root.permission(), maximumDisplacedBytes: 1024)
        }
        // Repeat the same failed recovery write while retaining every filesystem occupant.
        await #expect(throws: StorageError.database(1811)) {
            try await f.store.lane.perform { try $0.run("DELETE FROM private_groups WHERE group_key=?",
                [.blob(Array(("projection-replacement/" + String(repeating: "01", count: 16)).utf8))]) }
        }
        break
    }
    try await f.store.lane.perform { try $0.exec("DROP TRIGGER relocation_retire_fail") }
    #expect(try await f.store.pendingProjectionReplacement(for: f.birth) != nil)
    try await f.base.close()
}

@Test(arguments: ["destination", "source", "backup", "permissions", "created"])
func projectionRelocationPreservesPostEffectInterference(change: String) async throws {
    let f = try await PhysicalRelocationFixture.make()
    let recordURL = URL(fileURLWithPath: f.path + "/reserved-name")
    let result = try await f.root.relocateProjection(f.input, source: f.source, from: f.store,
        using: f.root.permission(), maximumDisplacedBytes: 1024,
        reserved: { record in try Data(record.backupName.utf8).write(to: recordURL) },
        afterInstall: {
            do {
                let backup = try String(contentsOf: recordURL, encoding: .utf8)
                switch change {
                case "source": try Data([88]).write(to: URL(fileURLWithPath: f.path + "/Note.txt"), options: .withoutOverwriting)
                case "backup": try Data([88]).write(to: URL(fileURLWithPath: f.path + "/" + backup), options: .atomic)
                case "permissions": try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.path + "/Moved.txt")
                case "created": try changeProjectionFixtureMetadata("created", at: f.path + "/Moved.txt")
                default: try Data([88]).write(to: URL(fileURLWithPath: f.path + "/Moved.txt"), options: .atomic)
                }
            } catch { Issue.record(error) }
        })
    if change == "source" {
        guard case .installed(let receipt) = result, case .snapshot(let returned) = receipt.source else { throw StorageError.incomplete }
        #expect(returned.bytes == [88] && receipt.sourceMatched)
    } else { guard case .uncertain = result else { Issue.record("Changed output or backup must remain unresolved"); try await f.base.close(); return } }
    let record = try #require(await f.store.pendingProjectionReplacement(for: f.birth))
    #expect(try f.base.disk(record.backupName) == (change == "backup" ? [88] : [65]))
    #expect(try f.base.disk("Moved.txt") == (change == "destination" ? [88] : [66]))
    #expect(try await f.store.projectionObservations(for: f.birth).value?.frozen?.output == f.input.output)
    try await f.base.close()
}

@Test(.timeLimit(.minutes(1)), arguments: ["edit", "delete", "cancel", "close"])
func projectionRelocationFencesHeldCompletion(change: String) async throws {
    let f = try await PhysicalRelocationFixture.make(), permission = try await f.root.permission()
    let entered = ImprovementGate(), release = DispatchSemaphore(value: 0)
    let watchdog = Task {
        do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
        Issue.record("Relocation did not settle held effect"); await entered.signal(); release.signal()
    }
    defer { watchdog.cancel(); release.signal() }
    let work = Task {
        try await f.root.relocateProjection(f.input, source: f.source, from: f.store, using: permission,
            maximumDisplacedBytes: 1024, afterInstall: { Task { await entered.signal() }; release.wait() })
    }
    await entered.wait()
    var closing: Task<Void, Never>?
    switch change {
    case "edit":
        _ = try await put("C", birth: f.birth, generation: 2, session: f.store)
        try await f.base.intend(name: "Later.txt", utf16: false, freeze: false)
    case "delete":
        let deletion = try await CapturedActionGroup(snapshot: f.store.snapshot(), kind: .deleteBatch,
            changes: [.delete(.init(birth: f.birth, generation: 2))])
        _ = try requireReceipt(await f.store.persist(capture: deletion))
    case "cancel": work.cancel()
    default:
        closing = Task { await f.root.close() }
        while await f.root.state == .active { await Task.yield() }
        #expect(await f.root.state == .closing)
    }
    let pending = try await f.store.projectionObservations(for: f.birth)
    release.signal()
    let result = try await work.value
    if change == "edit" { #expect({ if case .installed = result { true } else { false } }()) }
    else { #expect({ if case .uncertain = result { true } else { false } }(), "Changed context fences relocation completion") }
    let retained = try #require(await f.store.pendingProjectionReplacement(for: f.birth))
    #expect(try f.base.disk(f.target) == [66] && f.base.disk(retained.backupName) == [65])
    #expect(!FileManager.default.fileExists(atPath: f.path + "/Note.txt"))
    #expect(try await f.store.projectionObservations(for: f.birth).value == pending.value)
    #expect(try await f.store.snapshot().notes.map(\.value.body.string).sorted() ==
        (change == "delete" ? ["untouched"] : [change == "edit" ? "C" : "B", "untouched"]))
    if let closing { await closing.value }
    try await f.base.close()
}

/// Reads the kernel observation independently of Runtime's snapshot representation.
private func projectionFixtureStatWords(_ path: String) throws -> [UInt64] {
    var value = stat()
    try #require(path.withCString { unsafe lstat($0, &value) } == 0)
    return [1, UInt64(value.st_dev), value.st_ino, UInt64(value.st_size), UInt64(value.st_nlink),
        UInt64(bitPattern: Int64(value.st_mtimespec.tv_sec)), UInt64(value.st_mtimespec.tv_nsec),
        UInt64(bitPattern: Int64(value.st_ctimespec.tv_sec)), UInt64(value.st_ctimespec.tv_nsec)]
}

@Test(arguments: ["creation", "replacement", "relocation"], ["permissions", "created", "stamp", "finder"])
func projectionInstallationChecksCompleteMetadata(operation: String, change: String) async throws {
    let requireCoarseWitness = ProcessInfo.processInfo.environment["NV_P62_REQUIRE_COARSE_METADATA"] == "1"
    var witnessedEqualWords = false
    for _ in 0..<(requireCoarseWitness ? 8 : 1) {
        let f = try await PhysicalSourceFixture.make(), target = operation == "replacement" ? "Note.txt" : "Other.txt"
        let birth = operation == "creation" ? try NoteBirth(bytes: Array(repeating: 2, count: 16)) : f.birth
        if operation != "creation" { _ = try await put("B", birth: birth, generation: 1, session: f.store) }
        let intent = try await f.store.prepareProjectionIntent(for: birth, filename: .init(ExactUTF8(bytes: Array(target.utf8))),
            basedOn: f.store.snapshot(), observations: f.store.projectionObservations(for: birth))
        try await f.store.retainProjectionIntent(intent)
        _ = try await f.store.freezeProjectionIntent(observations: f.store.projectionObservations(for: birth))
        let evidence = URL(fileURLWithPath: f.path + "/metadata-stat.json"), path = f.path + "/" + target
        let interfere: @Sendable () -> Void = {
            do {
                let before = try projectionFixtureStatWords(path)
                switch change {
                case "permissions": try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: path)
                case "created": try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: path)
                default: try changeProjectionFixtureMetadata(change, at: path)
                }
                let after = try projectionFixtureStatWords(path)
                try JSONEncoder().encode([before, after]).write(to: evidence)
            } catch { Issue.record(error) }
        }
        let uncertain: Bool
        switch operation {
        case "creation":
            let input = try await f.store.prepareProjectionCreation(observations: f.store.projectionObservations(for: birth), basedOn: f.store.snapshot())
            let result = try await f.root.createProjection(input, from: f.store, using: f.root.permission(), staged: { _ in }, beforeInstall: {}, afterInstall: interfere)
            uncertain = { if case .uncertain = result { true } else { false } }()
        case "replacement":
            let input = try await f.store.prepareProjectionReplacement(observations: f.store.projectionObservations(for: birth), basedOn: f.store.snapshot())
            let result = try await f.root.replaceProjection(input, source: f.source, from: f.store, using: f.root.permission(), maximumDisplacedBytes: 1024, afterInstall: interfere)
            uncertain = { if case .uncertain = result { true } else { false } }()
        default:
            let input = try await f.store.prepareProjectionRelocation(observations: f.store.projectionObservations(for: birth), basedOn: f.store.snapshot())
            let result = try await f.root.relocateProjection(input, source: f.source, from: f.store, using: f.root.permission(), maximumDisplacedBytes: 1024, afterInstall: interfere)
            uncertain = { if case .uncertain = result { true } else { false } }()
        }
        #expect(uncertain, "Fresh installation readback checks complete metadata")
        let words = try JSONDecoder().decode([[UInt64]].self, from: Data(contentsOf: evidence))
        try #require(words.count == 2 && words.allSatisfy { $0.count == 9 })
        witnessedEqualWords = words[0] == words[1]
        #expect(try await f.store.projectionObservations(for: birth).value?.frozen?.output == intent.output)
        #expect(try f.disk(target) == (operation == "creation" ? Array("untouched".utf8) : [66]))
        try await f.close()
        if witnessedEqualWords { break }
    }
    if requireCoarseWitness { #expect(witnessedEqualWords, "The coarse-stat companion actually exercises unchanged physical words") }
}

@Test func projectionRelocationRecoveryChecksCandidateAndContext() async throws {
    let f = try await PhysicalRelocationFixture.make(), other = try await PhysicalRelocationFixture.make()
    guard case .installed(let receipt) = try await f.root.relocateProjection(f.input, source: f.source, from: f.store,
        using: f.root.permission(), maximumDisplacedBytes: 1024) else { throw StorageError.incomplete }
    let input = try await f.store.prepareProjectionRelocationRecovery(for: f.birth), permission = try await f.root.permission()
    await #expect(throws: StorageError.wrongContext) { try await other.store.checkProjectionRelocationRecovery(input) }
    await #expect(throws: RepositoryRootError.wrongContext, "Relocation recovery belongs to its captured root") {
        try await other.root.inspectProjectionRelocation(input, from: f.store, maximumBytes: 1024, using: other.root.permission())
    }
    let inspection = try await f.root.inspectProjectionRelocation(input, from: f.store, maximumBytes: 1024, using: permission)
    try await f.root.validate(inspection, for: input, from: f.store, using: permission)
    let old = receipt.reservation
    let next = try ProjectionReplacementAttemptV1(profile: .plaintextFiles, scope: old.scope, association: old.association,
        attempt: .init(bytes: Array(repeating: 42, count: 16)), transition: old.transition, root: old.root, source: old.source)
    try await f.store.lane.perform { try $0.run("UPDATE private_groups SET payload=? WHERE group_key=?",
        [.blob(next.encodedV1()), .blob(Array(("projection-replacement/" + String(repeating: "01", count: 16)).utf8))]) }
    let nextInput = try await f.store.prepareProjectionRelocationRecovery(for: f.birth)
    await #expect(throws: StorageError.wrongContext, "Relocation inspection belongs to its exact candidate") {
        try await f.root.validate(inspection, for: nextInput, from: f.store, using: permission)
    }
    let fresh = try await f.root.inspectProjectionRelocation(nextInput, from: f.store, maximumBytes: 1024, using: permission)
    try await f.root.validate(fresh, for: nextInput, from: f.store, using: permission)
    #expect(try f.base.disk(f.target) == [66] && f.base.disk(old.backupName) == [65])
    let selection = await f.store.selection
    try await f.base.close()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: f.base.protection)
    await #expect(throws: StorageError.wrongContext) { try await reopened.checkProjectionRelocationRecovery(nextInput) }
    _ = try await reopened.prepareProjectionRelocationRecovery(for: f.birth)
    try await reopened.quiesce(); try await other.base.close()
}

@Test(arguments: ["edit", "delete", "candidate", "root", "store"])
func projectionRelocationRecoveryFencesCompletion(change: String) async throws {
    let f = try await PhysicalRelocationFixture.make()
    guard case .installed(let receipt) = try await f.root.relocateProjection(f.input, source: f.source, from: f.store,
        using: f.root.permission(), maximumDisplacedBytes: 1024) else { throw StorageError.incomplete }
    let input = try await f.store.prepareProjectionRelocationRecovery(for: f.birth), permission = try await f.root.permission()
    func inspect() async throws -> ProjectionRelocationInspection {
        try await f.root.inspectProjectionRelocation(input, from: f.store, maximumBytes: 1024, using: permission, afterRead: {
            switch change {
            case "edit": _ = try await put("C", birth: f.birth, generation: 2, session: f.store)
            case "delete":
                let deletion = try await CapturedActionGroup(snapshot: f.store.snapshot(), kind: .deleteBatch,
                    changes: [.delete(.init(birth: f.birth, generation: 2))])
                _ = try requireReceipt(await f.store.persist(capture: deletion))
            case "candidate": try await f.store.lane.perform { try $0.run("DELETE FROM private_groups WHERE group_key=?",
                [.blob(Array(("projection-replacement/" + String(repeating: "01", count: 16)).utf8))]) }
            case "root": await f.root.invalidate()
            default: try await f.store.quiesce()
            }
        })
    }
    if change == "candidate" { await #expect(throws: StorageError.staleCapture, "Recovery requires its final retained candidate") { try await inspect() } }
    else if change == "root" { await #expect(throws: RepositoryRootError.stalePermission) { try await inspect() } }
    else if change == "store" { await #expect(throws: StorageError.closed) { try await inspect() } }
    else {
        let inspected = try await inspect()
        guard case .snapshot(let current) = inspected.current, case .snapshot(let backup) = inspected.backup,
            case .unavailable(.absent) = inspected.source else { throw StorageError.incomplete }
        #expect(current.bytes == [66] && backup.bytes == [65])
    }
    #expect(try f.base.disk(f.target) == [66] && f.base.disk(receipt.reservation.backupName) == [65])
    await f.root.close(); if change != "store" { try await f.store.quiesce() }
}

@Test(arguments: ["permissions", "encoding", "tags", "tags-empty", "finder", "stamp", "created"])
func projectionReplacementRejectsAcceptedMetadataChanges(change: String) async throws {
    let f = try await PhysicalReplacementFixture.make()
    if change == "permissions" { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.path + "/Note.txt") }
    else { try changeProjectionFixtureMetadata(change, at: f.path + "/Note.txt") }
    guard case .snapshot(let changed) = try await f.root.readProjection(f.root.observe("Note.txt", using: f.root.permission()),
        maximumBytes: 1024, using: f.root.permission()) else { throw StorageError.incomplete }
    let before = try f.source.physicalRecord, after = try changed.physicalRecord
    #expect(before.bytes.suffix(32) != after.bytes.suffix(32))
    let input = try await f.preparing(physical: .init(codec: before.codec, bytes: Array(after.bytes.prefix(72)) + before.bytes.suffix(32)))
    await #expect(throws: RepositoryRootError.wrongContext, "Accepted metadata must match before replacement") {
        try await f.root.replaceProjection(input, source: changed, from: f.store, using: f.root.permission(), maximumDisplacedBytes: 1024)
    }
    #expect(try await f.store.pendingProjectionReplacement(for: f.birth) == nil)
    #expect(try f.disk() == [65])
    let current = try await f.preparing(physical: after)
    guard case .installed(let receipt) = try await f.root.replaceProjection(current, source: changed, from: f.store,
        using: f.root.permission(), maximumDisplacedBytes: 1024) else { throw StorageError.incomplete }
    #expect(receipt.file.bytes == [66] && receipt.displaced.bytes == [65])
    try await f.close()
}

@Test(arguments: [false, true])
func projectionReplacementInstallsAndRetainsDisplacedSource(utf16: Bool) async throws {
    let f = try await PhysicalReplacementFixture.make(utf16: utf16)
    let before = try await f.store.projectionObservations(for: f.birth)
    let result = try await f.root.replaceProjection(f.input, source: f.source, from: f.store,
        using: f.root.permission(), maximumDisplacedBytes: 1024)
    guard case .installed(let receipt) = result else { Issue.record("Expected installed replacement: \(result)"); try await f.close(); return }
    let old: [UInt8] = utf16 ? [255,254,65,0] : [65], new: [UInt8] = utf16 ? [255,254,66,0] : [66]
    #expect(receipt.file.bytes == new && receipt.displaced.bytes == old && receipt.sourceMatched)
    #expect(receipt.file.permissions == 0o640 && receipt.displaced.permissions == 0o640)
    #expect(receipt.stamp == .written && receipt.finderTagsError == nil)
    #expect(receipt.file.tags == f.source.tags && receipt.displaced.tags == f.source.tags)
    #expect(receipt.file.created == f.source.created && receipt.displaced.created == f.source.created)
    #expect(receipt.file.modified.seconds == 978_307_201 && receipt.file.modified.nanoseconds == 0)
    #expect(try f.disk() == new && f.disk(receipt.reservation.backupName) == old)
    #expect(receipt.file.encoding == .present(Array((utf16 ? "utf-16;256" : "utf-8;134217984").utf8)))
    #expect(try await f.store.pendingProjectionReplacement(for: f.birth) == receipt.reservation)
    #expect(try await f.store.projectionObservations(for: f.birth).value == before.value)
    try await f.root.validate(receipt, for: f.input, from: f.store, using: f.root.permission())
    let another = try await f.store.prepareProjectionReplacement(observations: before, basedOn: f.store.snapshot())
    await #expect(throws: RepositoryRootError.wrongContext) {
        try await f.root.validate(receipt, for: another, from: f.store, using: f.root.permission())
    }
    await #expect(throws: StorageError.busy) {
        try await f.root.replaceProjection(f.input, source: f.source, from: f.store, using: f.root.permission(), maximumDisplacedBytes: 1024)
    }
    let selection = await f.store.selection
    try await f.close()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: f.protection)
    #expect(try await reopened.pendingProjectionReplacement(for: f.birth) == receipt.reservation)
    #expect(try await reopened.projectionObservations(for: f.birth).value == before.value)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["B", "untouched"])
    #expect(try f.disk() == new && f.disk(receipt.reservation.backupName) == old)
    try await reopened.quiesce()
}

@Test func projectionReplacementBurnsOccupiedCandidates() async throws {
    let f = try await PhysicalReplacementFixture.make()
    var names = Set<String>()
    for _ in 0..<2 {
        let result = try await f.root.replaceProjection(f.input, source: f.source, from: f.store,
            using: f.root.permission(), maximumDisplacedBytes: 1024, reserved: { record in
                let path = f.path + "/" + record.backupName
                if !FileManager.default.fileExists(atPath: path) {
                    try Data([88]).write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
                }
            })
        guard case .notInstalled(let failure) = result else { Issue.record("Occupied candidate must preserve both names"); try await f.close(); return }
        #expect(failure.reason == .conflict)
        #expect(names.insert(failure.reservation.backupName).inserted)
        #expect(try f.disk() == [65] && f.disk(failure.reservation.backupName) == [88])
        #expect(try await f.store.pendingProjectionReplacement(for: f.birth) == nil)
    }
    guard case .installed(let receipt) = try await f.root.replaceProjection(f.input, source: f.source, from: f.store,
        using: f.root.permission(), maximumDisplacedBytes: 1024) else { throw StorageError.incomplete }
    #expect(!names.contains(receipt.reservation.backupName))
    for name in names { #expect(try f.disk(name) == [88]) }
    #expect(try f.disk() == [66] && f.disk(receipt.reservation.backupName) == [65])
    try await f.close()
}

@Test func projectionReplacementReservationFailurePreventsEffect() async throws {
    let f = try await PhysicalReplacementFixture.make()
    try await f.store.lane.perform { try $0.exec("""
        CREATE TEMP TRIGGER fail_replacement BEFORE INSERT ON private_groups
        WHEN NEW.group_key>=X'70726F6A656374696F6E2D7265706C6163656D656E742F' AND NEW.group_key<X'70726F6A656374696F6E2D7265706C6163656D656E7430'
        BEGIN SELECT RAISE(ABORT,'injected reservation failure'); END;
        """) }
    for _ in 0..<2 {
        await #expect(throws: StorageError.database(1811)) {
            try await f.root.replaceProjection(f.input, source: f.source, from: f.store, using: f.root.permission(),
                maximumDisplacedBytes: 1024, staged: { _ in Issue.record("Failed reservation must precede staging") })
        }
        #expect(try f.disk() == [65])
        #expect(try await f.store.pendingProjectionReplacement(for: f.birth) == nil)
    }
    try await f.store.lane.perform { try $0.exec("DROP TRIGGER fail_replacement") }
    guard case .installed = try await f.root.replaceProjection(f.input, source: f.source, from: f.store,
        using: f.root.permission(), maximumDisplacedBytes: 1024) else { throw StorageError.incomplete }
    try await f.close()
}

@Test(arguments: ["before", "after", "backup", "budget"])
func projectionReplacementPreservesInterferingFiles(change: String) async throws {
    let f = try await PhysicalReplacementFixture.make()
    let result = try await f.root.replaceProjection(f.input, source: f.source, from: f.store,
        using: f.root.permission(), maximumDisplacedBytes: change == "budget" ? 0 : 1024, beforeInstall: {
            if change == "before" { do { try Data([88]).write(to: URL(fileURLWithPath: f.path + "/Note.txt"), options: .atomic) } catch { Issue.record(error) } }
        }, afterInstall: {
            do {
                if change == "after" { try Data([88]).write(to: URL(fileURLWithPath: f.path + "/Note.txt"), options: .atomic) }
                if change == "backup" {
                    let backup = try #require(FileManager.default.contentsOfDirectory(atPath: f.path).first { $0.hasPrefix(".nv-replacement-") })
                    try Data([88]).write(to: URL(fileURLWithPath: f.path + "/" + backup), options: .atomic)
                }
            } catch { Issue.record(error) }
        })
    if change == "before" {
        guard case .notInstalled(let failure) = result else { throw StorageError.incomplete }
        #expect(failure.reason == .changed)
        #expect(try f.disk() == [88])
        #expect(try await f.store.pendingProjectionReplacement(for: f.birth) == nil)
    } else {
        guard case .uncertain(let failure) = result else { throw StorageError.incomplete }
        #expect(try await f.store.pendingProjectionReplacement(for: f.birth) == failure.reservation)
        #expect(try f.disk() == (change == "after" ? [88] : [66]))
        #expect(try f.disk(failure.reservation.backupName) == (change == "backup" ? [88] : [65]))
    }
    #expect(try await f.store.projectionObservations(for: f.birth).value?.frozen?.output == f.input.output)
    try await f.close()
}

@Test func projectionReplacementRejectsForeignEvidenceBeforeEffect() async throws {
    let f = try await PhysicalReplacementFixture.make(), other = try await PhysicalReplacementFixture.make()
    await #expect(throws: RepositoryRootError.wrongContext) {
        try await f.root.replaceProjection(f.input, source: other.source, from: f.store,
            using: f.root.permission(), maximumDisplacedBytes: 1024)
    }
    await #expect(throws: StorageError.wrongContext) {
        try await f.root.replaceProjection(f.input, source: f.source, from: other.store,
            using: f.root.permission(), maximumDisplacedBytes: 1024)
    }
    #expect(try f.disk() == [65] && other.disk() == [65])
    #expect(try await f.store.pendingProjectionReplacement(for: f.birth) == nil)
    guard case .installed = try await f.root.replaceProjection(f.input, source: f.source, from: f.store,
        using: f.root.permission(), maximumDisplacedBytes: 1024) else { throw StorageError.incomplete }
    try await other.close(); try await f.close()
}

@Test func projectionReplacementFailedRetirementRetainsCandidate() async throws {
    let f = try await PhysicalReplacementFixture.make()
    try await f.store.lane.perform { try $0.exec("""
        CREATE TEMP TRIGGER fail_retirement BEFORE DELETE ON private_groups
        BEGIN SELECT RAISE(ABORT,'injected candidate retirement failure'); END;
        """) }
    await #expect(throws: StorageError.database(1811)) {
        try await f.root.replaceProjection(f.input, source: f.source, from: f.store,
            using: f.root.permission(), maximumDisplacedBytes: 1024, reserved: { record in
                try Data([88]).write(to: URL(fileURLWithPath: f.path + "/" + record.backupName), options: .withoutOverwriting)
            })
    }
    let record = try #require(await f.store.pendingProjectionReplacement(for: f.birth))
    #expect(try f.disk() == [65] && f.disk(record.backupName) == [88])
    #expect(try await f.store.projectionObservations(for: f.birth).value?.frozen?.output == f.input.output)
    try await f.store.lane.perform { try $0.exec("DROP TRIGGER fail_retirement") }
    await #expect(throws: StorageError.busy) {
        try await f.root.replaceProjection(f.input, source: f.source, from: f.store, using: f.root.permission(), maximumDisplacedBytes: 1024)
    }
    let selection = await f.store.selection
    try await f.close()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: f.protection)
    #expect(try await reopened.pendingProjectionReplacement(for: f.birth) == record)
    #expect(try f.disk() == [65] && f.disk(record.backupName) == [88])
    try await reopened.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: ["edit", "delete", "cancel", "close"])
func projectionReplacementFencesHeldCompletion(change: String) async throws {
    let f = try await PhysicalReplacementFixture.make(), permission = try await f.root.permission()
    let entered = ImprovementGate(), release = DispatchSemaphore(value: 0)
    let watchdog = Task {
        do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
        Issue.record("Replacement did not settle held effect"); await entered.signal(); release.signal()
    }
    defer { watchdog.cancel(); release.signal() }
    let work = Task {
        try await f.root.replaceProjection(f.input, source: f.source, from: f.store, using: permission,
            maximumDisplacedBytes: 1024, afterInstall: { Task { await entered.signal() }; release.wait() })
    }
    await entered.wait()
    var closing: Task<Void, Never>?
    switch change {
    case "edit":
        _ = try await put("C", birth: f.birth, generation: 2, session: f.store)
        let newer = try await f.store.prepareProjectionIntent(for: f.birth, filename: .init(ExactUTF8(bytes: Array("Later.txt".utf8))),
            basedOn: f.store.snapshot(), observations: f.store.projectionObservations(for: f.birth))
        try await f.store.retainProjectionIntent(newer)
    case "delete":
        let deletion = try await CapturedActionGroup(snapshot: f.store.snapshot(), kind: .deleteBatch,
            changes: [.delete(.init(birth: f.birth, generation: 2))])
        _ = try requireReceipt(await f.store.persist(capture: deletion))
    case "cancel": work.cancel()
    default:
        closing = Task { await f.root.close() }
        while await f.root.state == .active { await Task.yield() }
        #expect(await f.root.state == .closing)
    }
    let pending = try await f.store.projectionObservations(for: f.birth)
    release.signal()
    let result = try await work.value
    if change == "edit" { #expect({ if case .installed = result { true } else { false } }()) }
    else { #expect({ if case .uncertain = result { true } else { false } }()) }
    let retained = try #require(await f.store.pendingProjectionReplacement(for: f.birth))
    #expect(try f.disk() == [66] && f.disk(retained.backupName) == [65])
    #expect(try await f.store.projectionObservations(for: f.birth).value == pending.value)
    #expect(try await f.store.snapshot().notes.map(\.value.body.string).sorted() ==
        (change == "delete" ? ["untouched"] : [change == "edit" ? "C" : "B", "untouched"]))
    if let closing { await closing.value }
    try await f.close()
}

@Test func projectionReplacementFollowsMovedRoot() async throws {
    let f = try await PhysicalReplacementFixture.make(), moved = f.path + "-moved"
    let result = try await f.root.replaceProjection(f.input, source: f.source, from: f.store, using: f.root.permission(),
        maximumDisplacedBytes: 1024, beforeInstall: {
            do {
                try FileManager.default.moveItem(atPath: f.path, toPath: moved)
                try FileManager.default.createDirectory(atPath: f.path, withIntermediateDirectories: false)
                try Data([88]).write(to: URL(fileURLWithPath: f.path + "/Note.txt"))
            } catch { Issue.record(error) }
        })
    guard case .installed(let receipt) = result else { Issue.record("Held directory must remain replacement target"); try await f.close(); return }
    #expect(try f.disk() == [88])
    #expect(try Data(contentsOf: URL(fileURLWithPath: moved + "/Note.txt")) == Data([66]))
    #expect(try Data(contentsOf: URL(fileURLWithPath: moved + "/" + receipt.reservation.backupName)) == Data([65]))
    try await f.close()
}
@Test(arguments: ["intact", "newer", "delete", "changed-backup", "missing-backup", "symlink", "missing-current", "budget"])
func projectionReplacementRecoveryInspectsRetainedFiles(change: String) async throws {
    let f = try await PhysicalReplacementFixture.make(utf16: true)
    guard case .installed(let receipt) = try await f.root.replaceProjection(f.input, source: f.source, from: f.store,
        using: f.root.permission(), maximumDisplacedBytes: 1024) else { throw StorageError.incomplete }
    let candidate = receipt.reservation
    if change == "newer" { _ = try await put("C", birth: f.birth, generation: 2, session: f.store) }
    if change == "delete" {
        let deletion = try await CapturedActionGroup(snapshot: f.store.snapshot(), kind: .deleteBatch,
            changes: [.delete(.init(birth: f.birth, generation: 2))])
        _ = try requireReceipt(await f.store.persist(capture: deletion))
    }
    let backup = URL(fileURLWithPath: f.path + "/" + candidate.backupName)
    if ["changed-backup", "missing-backup", "symlink"].contains(change) {
        try FileManager.default.moveItem(at: backup, to: backup.appendingPathExtension("preserved"))
        if change == "changed-backup" { try Data([88]).write(to: backup) }
        if change == "symlink" { try FileManager.default.createSymbolicLink(atPath: backup.path, withDestinationPath: "Note.txt") }
    }
    if change == "missing-current" { try FileManager.default.moveItem(atPath: f.path + "/Note.txt", toPath: f.path + "/preserved.txt") }
    let selection = await f.store.selection, before = try await f.store.projectionObservations(for: f.birth).value
    try await f.close()
    let store = try await LocalStoreSession.open(selection: selection, protection: f.protection)
    let root = try await RepositoryRootSession.open(directory: f.path), permission = try await root.permission()
    let input = try await store.prepareProjectionReplacementRecovery(for: f.birth)
    #expect(input.record == candidate && input.sourceBytes == [255,254,65,0] && input.outputBytes == [255,254,66,0])
    let inspected = try await root.inspectProjectionReplacement(input, from: store, maximumBytes: change == "budget" ? 0 : 1024, using: permission)
    try await root.validate(inspected, for: input, from: store, using: permission)
    if change == "missing-current" { if case .unavailable(.absent) = inspected.current {} else { Issue.record("Expected absent current file") } }
    else if change == "budget" { if case .unavailable(.sizeLimit) = inspected.current {} else { Issue.record("Expected bounded current read") } }
    else { guard case .snapshot(let file) = inspected.current else { throw StorageError.incomplete }; #expect(file.bytes == [255,254,66,0]) }
    switch change {
    case "missing-backup": if case .unavailable(.absent) = inspected.backup {} else { Issue.record("Expected absent backup") }
    case "symlink": if case .unavailable(.kindCollision) = inspected.backup {} else { Issue.record("Expected preserved symbolic link") }
    case "budget": if case .unavailable(.sizeLimit) = inspected.backup {} else { Issue.record("Expected bounded backup read") }
    default:
        guard case .snapshot(let file) = inspected.backup else { throw StorageError.incomplete }
        #expect(file.bytes == (change == "changed-backup" ? [88] : [255,254,65,0]))
    }
    #expect(try await store.pendingProjectionReplacement(for: f.birth) == candidate)
    #expect(try await store.projectionObservations(for: f.birth).value == before)
    #expect(try await store.snapshot().notes.map(\.value.body.string).sorted() ==
        (change == "delete" ? ["untouched"] : [change == "newer" ? "C" : "B", "untouched"]))
    await root.close(); try await store.quiesce()
}

@Test(arguments: ["edit", "delete", "candidate", "root", "store"])
func projectionReplacementRecoveryFencesCompletion(change: String) async throws {
    let f = try await PhysicalReplacementFixture.make()
    guard case .installed(let receipt) = try await f.root.replaceProjection(f.input, source: f.source, from: f.store,
        using: f.root.permission(), maximumDisplacedBytes: 1024) else { throw StorageError.incomplete }
    let input = try await f.store.prepareProjectionReplacementRecovery(for: f.birth), permission = try await f.root.permission()
    func inspect() async throws -> ProjectionReplacementInspection {
        try await f.root.inspectProjectionReplacement(input, from: f.store, maximumBytes: 1024, using: permission, afterRead: {
            switch change {
            case "edit": _ = try await put("C", birth: f.birth, generation: 2, session: f.store)
            case "delete":
                let deletion = try await CapturedActionGroup(snapshot: f.store.snapshot(), kind: .deleteBatch,
                    changes: [.delete(.init(birth: f.birth, generation: 2))])
                _ = try requireReceipt(await f.store.persist(capture: deletion))
            case "candidate":
                try await f.store.lane.perform { try $0.run("DELETE FROM private_groups WHERE group_key=?",
                    [.blob(Array(("projection-replacement/" + String(repeating: "01", count: 16)).utf8))]) }
            case "root": await f.root.invalidate()
            case "store": try await f.store.quiesce()
            default: throw StorageError.unsupported
            }
        })
    }
    if change == "candidate" { await #expect(throws: StorageError.staleCapture) { try await inspect() } }
    else if change == "root" { await #expect(throws: RepositoryRootError.stalePermission) { try await inspect() } }
    else if change == "store" { await #expect(throws: StorageError.closed) { try await inspect() } }
    else {
        let result = try await inspect()
        guard case .snapshot(let current) = result.current, case .snapshot(let backup) = result.backup else { throw StorageError.incomplete }
        #expect(current.bytes == [66] && backup.bytes == [65])
    }
    #expect(try f.disk() == [66] && f.disk(receipt.reservation.backupName) == [65])
    await f.root.close(); if change != "store" { try await f.store.quiesce() }
}

@Test func projectionReplacementRecoveryRejectsForeignAndPriorSessions() async throws {
    let f = try await PhysicalReplacementFixture.make(), other = try await PhysicalReplacementFixture.make()
    guard case .installed = try await f.root.replaceProjection(f.input, source: f.source, from: f.store,
        using: f.root.permission(), maximumDisplacedBytes: 1024) else { throw StorageError.incomplete }
    let input = try await f.store.prepareProjectionReplacementRecovery(for: f.birth)
    await #expect(throws: StorageError.wrongContext) { try await other.store.checkProjectionReplacementRecovery(input) }
    await #expect(throws: RepositoryRootError.wrongContext, "The retained candidate belongs to its captured root") {
        try await other.root.inspectProjectionReplacement(input, from: f.store, maximumBytes: 1024, using: other.root.permission())
    }
    let inspection = try await f.root.inspectProjectionReplacement(input, from: f.store, maximumBytes: 1024, using: f.root.permission())
    await #expect(throws: RepositoryRootError.wrongContext) {
        try await other.root.validate(inspection, for: input, from: f.store, using: other.root.permission())
    }
    let selection = await f.store.selection
    try await f.close()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: f.protection)
    await #expect(throws: StorageError.wrongContext) { try await reopened.checkProjectionReplacementRecovery(input) }
    _ = try await reopened.prepareProjectionReplacementRecovery(for: f.birth)
    try await reopened.quiesce(); try await other.close()
}

@Test func projectionReplacementRecoveryBindsInspectionToCandidate() async throws {
    let f = try await PhysicalReplacementFixture.make()
    guard case .installed(let receipt) = try await f.root.replaceProjection(f.input, source: f.source, from: f.store,
        using: f.root.permission(), maximumDisplacedBytes: 1024) else { throw StorageError.incomplete }
    let input = try await f.store.prepareProjectionReplacementRecovery(for: f.birth), permission = try await f.root.permission()
    let inspection = try await f.root.inspectProjectionReplacement(input, from: f.store, maximumBytes: 1024, using: permission)
    try await f.root.validate(inspection, for: input, from: f.store, using: permission)
    let old = receipt.reservation
    let next = try ProjectionReplacementAttemptV1(profile: .plaintextFiles, scope: old.scope, association: old.association,
        attempt: .init(bytes: Array(repeating: 42, count: 16)), transition: old.transition, root: old.root, source: old.source)
    // Seed a subsequent candidate while keeping the same store, root and frozen transition.
    try await f.store.lane.perform { try $0.run("UPDATE private_groups SET payload=? WHERE group_key=?",
        [.blob(next.encodedV1()), .blob(Array(("projection-replacement/" + String(repeating: "01", count: 16)).utf8))]) }
    let nextInput = try await f.store.prepareProjectionReplacementRecovery(for: f.birth)
    await #expect(throws: StorageError.wrongContext, "Inspection belongs to its exact candidate") {
        try await f.root.validate(inspection, for: nextInput, from: f.store, using: permission)
    }
    let fresh = try await f.root.inspectProjectionReplacement(nextInput, from: f.store, maximumBytes: 1024, using: permission)
    try await f.root.validate(fresh, for: nextInput, from: f.store, using: permission)
    #expect(try f.disk() == [66] && f.disk(old.backupName) == [65])
    #expect(try await f.store.pendingProjectionReplacement(for: f.birth) == next)
    try await f.close()
}

@Test func projectionReplacementRecoverySurvivesPrivateCopy() async throws {
    let f = try await PhysicalReplacementFixture.make(utf16: true)
    guard case .installed(let receipt) = try await f.root.replaceProjection(f.input, source: f.source, from: f.store,
        using: f.root.permission(), maximumDisplacedBytes: 1024) else { throw StorageError.incomplete }
    let prior = try await f.store.prepareProjectionReplacementRecovery(for: f.birth)
    let copy = try await f.store.preparePrivateStoreCopy(to: privateTempPath()), selection = copy.selection
    #expect(selection.store != receipt.reservation.scope.store)
    try await copy.close(); try await f.close()
    let store = try await LocalStoreSession.open(selection: selection, protection: f.protection)
    await #expect(throws: StorageError.wrongContext) { try await store.checkProjectionReplacementRecovery(prior) }
    let input = try #require(try? await store.prepareProjectionReplacementRecovery(for: f.birth))
    #expect(input.record == receipt.reservation && input.sourceBytes == [255,254,65,0] && input.outputBytes == [255,254,66,0])
    let root = try await RepositoryRootSession.open(directory: f.path), permission = try await root.permission()
    let inspected = try await root.inspectProjectionReplacement(input, from: store, maximumBytes: 1024, using: permission)
    try await root.validate(inspected, for: input, from: store, using: permission)
    guard case .snapshot(let current) = inspected.current, case .snapshot(let backup) = inspected.backup else { throw StorageError.incomplete }
    #expect(current.bytes == [255,254,66,0] && backup.bytes == [255,254,65,0])
    #expect(try await store.pendingProjectionReplacement(for: f.birth) == receipt.reservation)
    #expect(try await store.snapshot().notes.map(\.value.body.string).sorted() == ["B", "untouched"])
    await root.close(); try await store.quiesce()
}

private struct ReplacementProcessContext: Codable {
    let directory, repository: String
    let store, descriptor: [UInt8]
    func selection() throws -> LocalStoreSelection {
        try .init(directory: directory, store: .init(bytes: store), descriptor: .decodeV1(descriptor))
    }
}

@Test func projectionReplacementRecoveryRequiresHistoricalBytes() async throws {
    let f = try await PhysicalReplacementFixture.make(utf16: true)
    guard case .installed = try await f.root.replaceProjection(f.input, source: f.source, from: f.store,
        using: f.root.permission(), maximumDisplacedBytes: 1024) else { throw StorageError.incomplete }
    let good = try await f.store.prepareProjectionReplacementRecovery(for: f.birth)
    #expect(good.sourceBytes == [255,254,65,0])
    let original = try #require(f.input.source.output.binding.occurrences.first)
    try await f.store.lane.perform { db in
        try db.exec("DROP TRIGGER objects_no_update")
        try db.run("UPDATE objects SET encoded=? WHERE object_id=?", [.blob([0]), .blob(original.locator.segmentID.bytes)])
    }
    await #expect(throws: CanonicalEncodingError.lengthLimit) {
        try await f.store.prepareProjectionReplacementRecovery(for: f.birth)
    }
    await #expect(throws: StorageError.integrity) { try await f.store.snapshot() }
    #expect(try f.disk() == [255,254,66,0] && f.disk(good.record.backupName) == [255,254,65,0])
    await f.root.close(); await f.store.lane.close()
}

private struct ReplacementProcessReport: Codable {
    let current, backup: [UInt8]?
    let currentFailure, backupFailure: String?
    let record, observations: [UInt8]
    let notes: [String]
    let through: Int64
    var source: [UInt8]? = nil
    var sourceFailure: String? = nil
}

/// Executes the already-built bundle through the toolchain's current runner, retaining all child logs.
private func replacementChild(_ context: URL, mode: String, status: Int32) throws {
    let arguments = CommandLine.arguments
    let index = try #require(arguments.firstIndex(of: "--test-bundle-path"))
    try #require(index + 1 < arguments.count)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: arguments[0])
    process.arguments = ["--test-bundle-path", arguments[index + 1], "--testing-library", "swift-testing",
                         "--filter", "projectionReplacementRecoveryChild"]
    var environment = ProcessInfo.processInfo.environment
    environment["NV_P62_RECOVERY_CONTEXT"] = context.path
    environment["NV_P62_RECOVERY_MODE"] = mode
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
    try #require(text.contains("projectionReplacementRecoveryChild() started."), "The child must actually discover its designated test")
    if status == 0 { try #require(text.contains("Test run with 1 test"), "The child runs exactly its designated recovery participant") }
}

/// The exec'ed participant receives only storage locations and ordinary selection inputs.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NV_P62_RECOVERY_CONTEXT"] != nil), .timeLimit(.minutes(1)))
func projectionReplacementRecoveryChild() async throws {
    let contextURL = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NV_P62_RECOVERY_CONTEXT"]))
    let context = try JSONDecoder().decode(ReplacementProcessContext.self, from: Data(contentsOf: contextURL))
    let mode = try #require(ProcessInfo.processInfo.environment["NV_P62_RECOVERY_MODE"])
    let store = try await LocalStoreSession.open(selection: context.selection(), protection: .publicHash)
    let root = try await RepositoryRootSession.open(directory: context.repository), permission = try await root.permission()
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    if mode == "inspect" || mode == "inspect-exit" {
        let record = try #require(await store.pendingProjectionReplacement(for: birth))
        let sourceResult: ProjectionFileReadResult?, currentResult: ProjectionFileReadResult, backupResult: ProjectionFileReadResult
        switch record.operation {
        case .replacement:
            let input = try await store.prepareProjectionReplacementRecovery(for: birth)
            let inspected = try await root.inspectProjectionReplacement(input, from: store, maximumBytes: 1024, using: permission,
                afterRead: { if mode == "inspect-exit" { _exit(86) } })
            sourceResult = nil; currentResult = inspected.current; backupResult = inspected.backup
        case .relocation:
            let input = try await store.prepareProjectionRelocationRecovery(for: birth)
            let inspected = try await root.inspectProjectionRelocation(input, from: store, maximumBytes: 1024, using: permission,
                afterRead: { if mode == "inspect-exit" { _exit(86) } })
            sourceResult = inspected.source; currentResult = inspected.current; backupResult = inspected.backup
        }
        func observed(_ result: ProjectionFileReadResult) -> ([UInt8]?, String?) {
            switch result {
            case .snapshot(let file): (file.bytes, nil)
            case .placeholder: (nil, "placeholder")
            case .unavailable(let failure): (nil, String(describing: failure))
            }
        }
        let current = observed(currentResult), backup = observed(backupResult), snapshot = try await store.snapshot()
        let source = sourceResult.map(observed)
        let pending = try #require(await store.projectionObservations(for: birth).value)
        let report = try ReplacementProcessReport(current: current.0, backup: backup.0, currentFailure: current.1,
            backupFailure: backup.1, record: record.encodedV1(), observations: pending.encodedV1(),
            notes: snapshot.notes.map(\.value.body.string).sorted(), through: snapshot.through, source: source?.0, sourceFailure: source?.1)
        try JSONEncoder().encode(report).write(to: contextURL.appendingPathExtension("report"), options: .atomic)
    } else {
        guard case .snapshot(let source) = try await root.readProjection(root.observe("Note.txt", using: permission), maximumBytes: 1024, using: permission) else {
            throw StorageError.incomplete
        }
        let reserved: @Sendable (ProjectionReplacementAttemptV1) async throws -> Void = { record in
                if mode == "occupied" { try Data([88]).write(to: URL(fileURLWithPath: context.repository + "/" + record.backupName), options: .withoutOverwriting) }
                if mode == "reserved" || mode == "occupied" { _exit(86) }
        }
        let beforeInstall: @Sendable () -> Void = { if mode == "staged" { _exit(86) } }
        let afterInstall: @Sendable () -> Void = { if mode == "installed" { _exit(86) } }
        let transition = try #require(await store.projectionObservations(for: birth).value?.frozen)
        if transition.source?.output.binding.descriptor.filename == transition.output.binding.descriptor.filename {
            let input = try await store.prepareProjectionReplacement(observations: store.projectionObservations(for: birth), basedOn: store.snapshot())
            guard case .installed = try await root.replaceProjection(input, source: source, from: store, using: permission, maximumDisplacedBytes: 1024,
                reserved: reserved, beforeInstall: beforeInstall, afterInstall: afterInstall) else { throw StorageError.incomplete }
        } else {
            let input = try await store.prepareProjectionRelocation(observations: store.projectionObservations(for: birth), basedOn: store.snapshot())
            guard case .installed = try await root.relocateProjection(input, source: source, from: store, using: permission, maximumDisplacedBytes: 1024,
                reserved: reserved, beforeInstall: beforeInstall, afterInstall: afterInstall) else { throw StorageError.incomplete }
        }
        if mode == "callback" { _exit(86) }
        try #require(mode == "complete")
    }
    await root.close(); try await store.quiesce()
}

@Test(.timeLimit(.minutes(2)), arguments: ["reserved", "occupied", "staged", "installed", "callback", "complete", "second-crash", "delete", "newer"])
func projectionReplacementFreshProcessRecovery(cut: String) async throws {
    try await projectionFreshProcessRecovery(cut: cut, target: "Note.txt")
}

@Test(.timeLimit(.minutes(2)), arguments: ["reserved", "occupied", "staged", "installed", "callback", "complete", "second-crash", "delete", "newer"])
func projectionRelocationFreshProcessRecovery(cut: String) async throws {
    try await projectionFreshProcessRecovery(cut: cut, target: "Moved.txt")
}

/// Exercises each physical transition with the same independent child/reopen oracle.
private func projectionFreshProcessRecovery(cut: String, target: String) async throws {
    let f = try await PhysicalSourceFixture.make(utf16: true), selection = await f.store.selection
    _ = try await put("B", birth: f.birth, generation: 1, session: f.store)
    try await f.intend(name: target, utf16: true)
    let artifact = URL(fileURLWithPath: try emptyRepository()).appendingPathComponent("context.json")
    let context = ReplacementProcessContext(directory: selection.directory, repository: f.path,
        store: selection.store.bytes, descriptor: selection.descriptor.encodedBytes)
    try JSONEncoder().encode(context).write(to: artifact)
    let before = try #require(await f.store.projectionObservations(for: f.birth).value)
    var through = try await f.store.snapshot().through
    try await f.close()
    let mode = ["second-crash", "delete", "newer"].contains(cut) ? "installed" : cut
    try replacementChild(artifact, mode: mode, status: mode == "complete" ? 0 : 86)
    if cut == "delete" || cut == "newer" {
        let reopened = try await LocalStoreSession.open(selection: selection, protection: f.protection)
        if cut == "newer" { _ = try await put("C", birth: f.birth, generation: 2, session: reopened) }
        else {
            let deletion = try await CapturedActionGroup(snapshot: reopened.snapshot(), kind: .deleteBatch,
                changes: [.delete(.init(birth: f.birth, generation: 2))])
            _ = try requireReceipt(await reopened.persist(capture: deletion))
        }
        through = try await reopened.snapshot().through
        try await reopened.quiesce()
    }
    if cut == "second-crash" { try replacementChild(artifact, mode: "inspect-exit", status: 86) }
    // Two independent recovery processes must observe the same retained inputs and physical contents.
    var previous: Data?
    for _ in 0..<2 {
        try replacementChild(artifact, mode: "inspect", status: 0)
        let data = try Data(contentsOf: artifact.appendingPathExtension("report"))
        let report = try JSONDecoder().decode(ReplacementProcessReport.self, from: data)
        let record = try ProjectionReplacementAttemptV1.decodeV1(report.record, profile: .plaintextFiles)
        let beforeEffect = ["reserved", "occupied", "staged"].contains(cut)
        let current: [UInt8]? = beforeEffect ? (target == "Note.txt" ? [255,254,65,0] : nil) : [255,254,66,0]
        #expect(report.current == current && report.currentFailure == (current == nil ? "absent" : nil))
        if let current { #expect(try f.disk(target) == current) }
        else { #expect(!FileManager.default.fileExists(atPath: f.path + "/" + target)) }
        if target != "Note.txt" {
            #expect(record.operation == .relocation)
            #expect(report.source == (beforeEffect ? [255,254,65,0] : nil) && report.sourceFailure == (beforeEffect ? nil : "absent"))
            if beforeEffect { #expect(try f.disk() == [255,254,65,0]) }
            else { #expect(!FileManager.default.fileExists(atPath: f.path + "/Note.txt")) }
        } else { #expect(record.operation == .replacement && report.source == nil && report.sourceFailure == nil) }
        if beforeEffect && cut != "occupied" {
            #expect(report.backup == nil && report.backupFailure == "absent")
            #expect(!FileManager.default.fileExists(atPath: f.path + "/" + record.backupName))
        } else {
            let expected: [UInt8] = cut == "occupied" ? [88] : [255,254,65,0]
            #expect(report.backup == expected && report.backupFailure == nil)
            #expect(try f.disk(record.backupName) == expected)
        }
        #expect(report.observations == (try before.encodedV1()) && record.transition == before.frozen)
        #expect(report.through == through)
        #expect(report.notes == (cut == "delete" ? ["untouched"] : [cut == "newer" ? "C" : "B", "untouched"]))
        if let previous {
            let prior = try JSONDecoder().decode(ReplacementProcessReport.self, from: previous)
            #expect(report.record == prior.record && report.observations == prior.observations)
        }
        previous = data
    }
}
#endif
