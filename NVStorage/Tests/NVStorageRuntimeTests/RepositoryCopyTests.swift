import NVStorageTestSupport
import Foundation
import Crypto
import CStorageFaults
import Testing
import NVStorageCore
@testable import NVStorageRuntime

private actor CopyTurnGate {
    private var entered = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true; arrival?.resume(); arrival = nil
        await withCheckedContinuation { release = $0 }
    }
    func wait() async { if !entered { await withCheckedContinuation { arrival = $0 } } }
    func resume() { release?.resume(); release = nil }
}

@Test(arguments: [false, true], [64, 256, 1024])
func repositorySavedCopyStreamsFixedHistory(encrypted: Bool, actions: Int) async throws {
    let fixture = try await GrowthHistoryFixtures.shared.fixture(encrypted: encrypted, actions: actions)
    let source = try await fixture.openSender(), lane = await source.lane
    let expected = fixture.initial.objects.values.map { $0 } + [fixture.initial.descriptor.encodedBytes] + fixture.history.map(\.bytes)
    let hashes = Set(expected.map { Array(SHA256.hash(data: $0)) })
    try await lane.perform { $0.work = StorageWork() }
    let start = ContinuousClock.now
    let copied = try await source.copyRepositoryAndSavedWork(from: emptyRepository(), to: privateTempPath())
    let copyTime = start.duration(to: .now)
    #expect(copied.repository.capturedInventoryComplete && copied.repository.unmetRequirements.isEmpty)
    #expect(copied.through == Int64(actions + 1))
    #expect(Set(copied.repository.files.map(\.sha256)) == hashes)
    for file in copied.repository.files {
        #expect(Array(SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: copied.repository.destination + "/" + file.path)))) == file.sha256)
    }
    let root = try await RepositoryRootSession.open(directory: copied.repository.destination)
    let verificationStart = ContinuousClock.now
    try await source.verifyCopiedHistory(at: root, through: copied.through)
    let verificationTime = verificationStart.duration(to: .now)
    let work = try await lane.perform { db in let work = db.work!; db.work = nil; return work }
    let counts = Array(work.stages.values)
    #expect(counts.map(\.largestPublicationObjects).max() == 16)
    #expect(counts.map(\.largestPublicationBytes).max()! <= 4 * 1024 * 1024)
    #expect(counts.reduce(0) { $0 + $1.historyReads } == 4 * expected.count)
    #expect(counts.reduce(0) { $0 + $1.publicationBatches } == 4 * ((expected.count + 15) / 16))
    #expect(try await source.snapshot().notes.map(\.value.body.string).sorted() == ["E\(actions)", "untouched"])
    print("SAVED-COPY encrypted=\(encrypted) actions=\(actions) objects=\(expected.count) maxObjects=\(counts.map(\.largestPublicationObjects).max()!) maxBytes=\(counts.map(\.largestPublicationBytes).max()!) copy=\(copyTime) verify=\(verificationTime)")
    await root.close(); try await source.quiesce()
}

@Test(arguments: [false, true], ["save", "missing", "corrupt", "closed", "cancel"])
func repositorySavedCopyRechecksCapturedHistory(encrypted: Bool, change: String) async throws {
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    var last: AcceptedHistoryReceipt?
    for generation in 1...17 {
        last = try await put("copy E\(generation)", birth: birth, generation: UInt64(generation), session: source)
    }
    let tip = try #require(last), through = try await source.snapshot().through
    let expectedTip = try await source.retainedObject(at: tip.object)
    let captured = try await source.captureRepositoryHistory(through: through)
    let expectedCount = initial.objects.count + 1 + 17
    #expect(captured.requirements.count == expectedCount)
    let gate = CopyTurnGate()
    let stream = Task {
        var seen: [[UInt8]] = [], batches = 0
        try await captured.forEachBatch { objects in
            #expect(objects.count <= 16)
            batches += 1; seen += objects.map(\.bytes)
            if batches == 1 { await gate.hold() }
        }
        return seen
    }
    await gate.wait()
    let lane = await source.lane
    switch change {
    case "save": _ = try await put("saved during copy", birth: birth, generation: 18, session: source)
    case "missing":
        try await lane.perform { db in
            try db.run("PRAGMA foreign_keys=OFF")
            try db.run("DELETE FROM accepted_objects WHERE object_id=?", [.blob(tip.object.segmentID.bytes)])
            try db.run("PRAGMA foreign_keys=ON")
        }
    case "corrupt":
        try await lane.perform { db in
            try db.exec("DROP TRIGGER objects_no_update")
            try db.run("UPDATE objects SET encoded=? WHERE object_id=?", [.blob([1, 2, 3]), .blob(tip.object.segmentID.bytes)])
        }
    case "closed": try await source.quiesce()
    default: stream.cancel()
    }
    await gate.resume()
    switch change {
    case "save":
        let bytes = try await stream.value
        #expect(bytes.count == expectedCount && bytes.contains(expectedTip))
        #expect(Set(bytes.map { Array(SHA256.hash(data: $0)) }) == Set(captured.requirements.map(\.sha256)))
        let exported = try await RepositoryCopyWorker().export(captured, to: privateTempPath())
        #expect(exported.unmetRequirements.isEmpty && exported.files.count == expectedCount)
        #expect(try await source.snapshot().notes.map(\.value.body.string).sorted() == ["saved during copy", "untouched"])
    case "missing": await #expect(throws: StorageError.incomplete) { try await stream.value }
    case "corrupt": await #expect(throws: (any Error).self) { try await stream.value }
    case "closed": await #expect(throws: StorageError.closed) { try await stream.value }
    default: await #expect(throws: CancellationError.self) { try await stream.value }
    }
    if change != "closed" { try await source.quiesce() }
    if change == "missing" || change == "corrupt" {
        let inspection = DatabaseLane(), selection = await source.selection
        try await inspection.open(directory: selection.directory, create: false,
            key: PrivateDatabaseKeyV1.derive(collection: initial.descriptor.collection, protection: protection))
        #expect(try await inspection.perform { try $0.rows("SELECT payload FROM private_groups WHERE group_key=?", [.blob(Array("history-damage".utf8))]) } == [[.blob([])]])
        await inspection.close()
    }
}

@Test(arguments: [false, true], [false, true])
func recoveryCopyReservesVerifiedNamesAfterInstallFailure(encrypted: Bool, failStage: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let original = try await session.copyRepositoryAndSavedWork(from: emptyRepository(), to: privateTempPath()).repository
    let chosen = try #require(original.files.first { $0.path.hasSuffix(".nvseg") })
    let sourceFile = URL(fileURLWithPath: original.destination + "/" + chosen.path)
    let verified = try Data(contentsOf: sourceFile), damage = Data("damaged source evidence".utf8)
    try damage.write(to: sourceFile)
    let root = try await RepositoryRootSession.open(directory: original.destination)
    let destination = privateTempPath(), heldStage = destination + "/held-stage"
    let result = try await session.copyRepositoryAndSavedWork(from: Optional(root), to: destination, captured: nil,
        beforeInstall: { path in
            guard failStage, path == chosen.path, !FileManager.default.fileExists(atPath: heldStage) else { return }
            do {
                let stage = try #require(FileManager.default.contentsOfDirectory(atPath: destination).first { $0.hasPrefix(".nv-stage-") })
                try FileManager.default.moveItem(atPath: destination + "/" + stage, toPath: heldStage)
                try Data("substituted stage".utf8).write(to: URL(fileURLWithPath: destination + "/" + stage))
            } catch { Issue.record(error) }
        })
    #expect(result.repository.issues.contains { $0.path == chosen.path })
    let target = URL(fileURLWithPath: destination + "/" + chosen.path)
    if failStage {
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(result.repository.unmetRequirements.map(\.path) == [chosen.path])
        #expect(try Data(contentsOf: URL(fileURLWithPath: heldStage)) == verified)
    } else {
        #expect(try Data(contentsOf: target) == verified)
        #expect(result.repository.unmetRequirements.isEmpty)
    }
    #expect(try Data(contentsOf: sourceFile) == damage)
    #expect(try await session.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    await root.close(); try await session.quiesce()
}

@Test(arguments: [false, true], ["normal", "occupied", "stage-substitution", "destination-move"])
func repositoryCopyStagesCanonicalBytesAndPreservesRaces(encrypted: Bool, kind: String) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let exported = try await session.copyRepositoryAndSavedWork(from: emptyRepository(), to: privateTempPath())
    try await session.quiesce()
    let source = exported.repository.destination, destination = privateTempPath()
    let chosen = try #require(exported.repository.files.first { $0.path.hasSuffix(".nvseg") })
    let original = try Data(contentsOf: URL(fileURLWithPath: source + "/" + chosen.path))
    let foreign = Data("competing bytes".utf8), preservedStage = destination + "/held-stage"
    let root = try await RepositoryRootSession.open(directory: source)
    try await confirmation("Exact stage observed at the installation boundary", expectedCount: 1) { confirmed in
        let operation = Task {
            try await root.copyRepository(to: destination, beforeInstall: { path in
                guard path == chosen.path else { return }
                confirmed()
                do {
                    let final = destination + "/" + path
                    #expect(!FileManager.default.fileExists(atPath: final))
                    let stages = try FileManager.default.contentsOfDirectory(atPath: destination).filter { $0.hasPrefix(".nv-stage-") }
                    let stage = try #require(stages.first)
                    #expect(stages.count == 1)
                    #expect(try Data(contentsOf: URL(fileURLWithPath: destination + "/" + stage)) == original)
                    switch kind {
                    case "occupied": try foreign.write(to: URL(fileURLWithPath: final))
                    case "stage-substitution":
                        try FileManager.default.moveItem(atPath: destination + "/" + stage, toPath: preservedStage)
                        try foreign.write(to: URL(fileURLWithPath: destination + "/" + stage))
                    case "destination-move":
                        try FileManager.default.moveItem(atPath: destination, toPath: destination + "-moved")
                        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: false)
                        try foreign.write(to: URL(fileURLWithPath: destination + "/foreign"))
                    default: break
                    }
                } catch { Issue.record(error) }
            })
        }
        if kind == "destination-move" {
            await #expect(throws: RepositoryRootError.stalePermission) { try await operation.value }
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination) == ["foreign"])
        } else {
            let result = try await operation.value
            if kind == "normal" {
                #expect(result.capturedInventoryComplete && result.files.count == exported.repository.files.count)
                #expect(try Data(contentsOf: URL(fileURLWithPath: destination + "/" + chosen.path)) == original)
            } else {
                #expect(result.issues.contains { $0.path == chosen.path })
                #expect(!result.files.contains { $0.path == chosen.path })
                if kind == "occupied" { #expect(try Data(contentsOf: URL(fileURLWithPath: destination + "/" + chosen.path)) == foreign) }
                else {
                    #expect(!FileManager.default.fileExists(atPath: destination + "/" + chosen.path))
                    #expect(try Data(contentsOf: URL(fileURLWithPath: preservedStage)) == original)
                }
            }
        }
    }
    #expect(try Data(contentsOf: URL(fileURLWithPath: source + "/" + chosen.path)) == original)
    await root.close()
}

@Test(.timeLimit(.minutes(1)), arguments: ["move", "invalidate", "cancel", "directory-replacement"])
func coordinatedRepositoryCopyKeepsOwnedSourceAndStopsStaleWork(kind: String) async throws {
    let path = try emptyRepository(), destination = privateTempPath(), gate = CopyTurnGate()
    try FileManager.default.createDirectory(atPath: path + "/branch", withIntermediateDirectories: false)
    let original = Data("owned original".utf8), foreign = Data("foreign replacement".utf8)
    try original.write(to: URL(fileURLWithPath: path + "/branch/note"))
    let root = try await RepositoryRootSession.open(directory: path)
    let copying = Task {
        try await root.copyRepository(to: destination) { relative in
            if relative == "branch/note" { await gate.hold() }
        }
    }
    await gate.wait()
    await #expect(throws: RepositoryRootError.busy) {
        try await RepositoryCopy.preserveAvailable(from: root, to: privateTempPath())
    }
    await #expect(throws: RepositoryRootError.contention) { try await RepositoryRootSession.open(directory: path) }
    switch kind {
    case "move":
        try FileManager.default.moveItem(atPath: path, toPath: path + "-moved")
        try FileManager.default.createDirectory(atPath: path + "/branch", withIntermediateDirectories: true)
        try foreign.write(to: URL(fileURLWithPath: path + "/branch/note"))
    case "invalidate": await root.invalidate()
    case "cancel": copying.cancel()
    default:
        try FileManager.default.moveItem(atPath: path + "/branch", toPath: path + "/preserved-branch")
        try FileManager.default.createDirectory(atPath: path + "/branch", withIntermediateDirectories: false)
        try foreign.write(to: URL(fileURLWithPath: path + "/branch/note"))
    }
    await gate.resume()
    switch kind {
    case "move":
        let result = try await copying.value
        #expect(result.capturedInventoryComplete && result.files.map(\.path) == ["branch/note"])
        #expect(try Data(contentsOf: URL(fileURLWithPath: destination + "/branch/note")) == original)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path + "/branch/note")) == foreign)
    case "invalidate":
        await #expect(throws: RepositoryRootError.stalePermission) { try await copying.value }
        #expect(!FileManager.default.fileExists(atPath: destination + "/branch/note"))
    case "cancel":
        await #expect(throws: CancellationError.self) { try await copying.value }
        #expect(!FileManager.default.fileExists(atPath: destination + "/branch/note"))
    default:
        let result = try await copying.value
        #expect(result.issues.contains { $0.path == "branch/note" })
        #expect(!FileManager.default.fileExists(atPath: destination + "/branch/note"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path + "/preserved-branch/note")) == original)
    }
    await root.close()
}

@Test(arguments: [false, true], ["bytes", "directory", "hierarchy"])
func recoveryCopyUsesVerifiedHistoryAndReportsPreservedDamage(encrypted: Bool, kind: String) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let edit = try await put("saved after provider damage", birth: NoteBirth(bytes: Array(repeating: 1, count: 16)), generation: 1, session: session)
    let source = try await session.copyRepositoryAndSavedWork(from: emptyRepository(), to: privateTempPath()).repository
    let damagedPath = kind == "hierarchy" ? "NV Data" : ImmutableRepositoryLocator.segment(edit.object).relativePath
    let damagedURL = URL(fileURLWithPath: source.destination).appendingPathComponent(damagedPath)
    let marker = Data("preserved damaged source".utf8)
    if kind != "bytes" {
        try FileManager.default.moveItem(atPath: damagedURL.path, toPath: privateTempPath())
    }
    if kind == "directory" {
        try FileManager.default.createDirectory(at: damagedURL, withIntermediateDirectories: false)
        try marker.write(to: damagedURL.appendingPathComponent("unknown.bin"))
    } else { try marker.write(to: damagedURL) }
    let before = try FileManager.default.attributesOfItem(atPath: damagedURL.path)[.systemFileNumber] as? NSNumber
    let copied = try await session.copyRepositoryAndSavedWork(from: source.destination, to: privateTempPath())
    #expect(copied.repository.unmetRequirements.isEmpty)
    #expect(!copied.repository.capturedInventoryComplete)
    #expect(copied.repository.issues.map(\.path) == [damagedPath])
    let sourceMarker = kind == "directory" ? damagedURL.appendingPathComponent("unknown.bin") : damagedURL
    #expect(try Data(contentsOf: sourceMarker) == marker)
    #expect(try FileManager.default.attributesOfItem(atPath: damagedURL.path)[.systemFileNumber] as? NSNumber == before)
    #expect(Set(copied.repository.files.map(\.path)) == Set(source.files.map(\.path)))
    for file in source.files {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: copied.repository.destination).appendingPathComponent(file.path))
        #expect(Array(SHA256.hash(data: bytes)) == file.sha256)
    }
    let selection = try LocalStoreSelection(directory: privateTempPath(), store: LocalStoreID(bytes: uuidBytes()), descriptor: initial.descriptor)
    let candidate = try await BootstrapCandidate.create(selection: selection, snapshot: initial.snapshot, protection: protection)
    let history = try copied.repository.files.filter { $0.path.hasSuffix(".nvseg") }.map {
        Array(try Data(contentsOf: URL(fileURLWithPath: copied.repository.destination).appendingPathComponent($0.path)))
    }
    for bytes in history { _ = try await candidate.retain(bytes) }
    let recovered = try await candidate.complete(snapshot: initial.snapshot)
    for bytes in history { _ = try await recovered.receive(bytes) }
    #expect(try await recovered.snapshot().notes.map(\.value.body.string).sorted() == ["saved after provider damage", "untouched"])
    try await recovered.quiesce(); try await session.quiesce()
}

@Test
func repositoryCopyStreamsWideAndNestedInventories() async throws {
    let source = try emptyRepository()
    var expected: [String: Data] = [:]
    for index in 0..<49 {
        let directory = "branch-\(index)/nested"
        try FileManager.default.createDirectory(atPath: source + "/" + directory, withIntermediateDirectories: true)
        for child in 0..<3 {
            let path = directory + "/file-\(child)", data = Data([UInt8(index), UInt8(child)])
            try data.write(to: URL(fileURLWithPath: source + "/" + path)); expected[path] = data
        }
    }
    let copied = try await RepositoryCopy.preserveAvailable(from: source, to: privateTempPath())
    #expect(copied.capturedInventoryComplete && copied.files.count == 147)
    for file in copied.files {
        #expect(try Data(contentsOf: URL(fileURLWithPath: copied.destination + "/" + file.path)) == expected[file.path])
    }
}

@Test(arguments: [false, true])
func repositoryOnlyCopyPreservesLockedBytesMetadataAndUnknownFiles(encrypted: Bool) async throws {
    let (initial, _) = try testInitial(encrypted), source = try emptyRepository()
    let directory = URL(fileURLWithPath: source).appendingPathComponent("NV Data")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let opaque = try #require(initial.objects.values.first), raw = Data([0,1,2,255,99])
    try Data(opaque).write(to: directory.appendingPathComponent("opaque.nvseg"))
    try Data(initial.descriptor.encodedBytes).write(to: directory.appendingPathComponent("unlock.nvbootstrap"))
    try raw.write(to: URL(fileURLWithPath: source).appendingPathComponent("unknown.bin"))
    let file = URL(fileURLWithPath: source).appendingPathComponent("unknown.bin").path
    let attribute: [UInt8] = [1,2,255,0]
    #expect(attribute.withUnsafeBufferPointer { unsafe nv_fixture_set_attribute(file, "user.nv-copy-fixture", $0.baseAddress, UInt64($0.count)) } == 0)
    let requirement = try RepositoryByteRequirement(path: "NV Data/opaque.nvseg", sha256: Array(SHA256.hash(data: opaque)))
    let missing = try RepositoryByteRequirement(path: "NV Data/missing.nvseg", sha256: Array(repeating: 7, count: 32))
    let result = try await RepositoryCopy.preserveAvailable(from: source, to: privateTempPath(), requirements: [requirement, missing])
    #expect(result.capturedInventoryComplete && result.files.count == 3)
    #expect(result.unmetRequirements.map(\.path) == [missing.path])
    #expect(try Data(contentsOf: URL(fileURLWithPath: result.destination).appendingPathComponent("unknown.bin")) == raw)
    #expect(try Data(contentsOf: URL(fileURLWithPath: result.destination).appendingPathComponent(requirement.path)) == Data(opaque))
    var recovered = [UInt8](repeating: 0, count: 4)
    let read = recovered.withUnsafeMutableBufferPointer { unsafe nv_fixture_get_attribute(result.destination + "/unknown.bin", "user.nv-copy-fixture", $0.baseAddress, 4) }
    #expect(read == 4 && recovered == attribute)
    #expect(!FileManager.default.fileExists(atPath: result.destination + "/Collection.sqlite"))
}

@Test(arguments: ["changed", "removed", "symlink", "foreign-destination", "nested-destination"])
func repositoryCopyReportsChangingOrUnsafeInputs(kind: String) async throws {
    let source = try emptyRepository(), file = source + "/note.txt", original = Data("original".utf8)
    try original.write(to: URL(fileURLWithPath: file))
    if kind == "foreign-destination" {
        let destination = try emptyRepository()
        try original.write(to: URL(fileURLWithPath: destination).appendingPathComponent("foreign"))
        await #expect(throws: (any Error).self) { try await RepositoryCopy.preserveAvailable(from: source, to: destination) }
        #expect(try Data(contentsOf: URL(fileURLWithPath: destination).appendingPathComponent("foreign")) == original)
        return
    }
    if kind == "nested-destination" {
        await #expect(throws: (any Error).self) { try await RepositoryCopy.preserveAvailable(from: source, to: source + "/nested") }
        #expect(!FileManager.default.fileExists(atPath: source + "/nested")); return
    }
    if kind == "symlink" {
        try FileManager.default.createSymbolicLink(atPath: source + "/outside-link", withDestinationPath: file)
    }
    let result = try await RepositoryCopy.preserveAvailable(from: source, to: privateTempPath()) { path in
        if path == "note.txt", kind == "changed" { try! Data("replacement".utf8).write(to: URL(fileURLWithPath: file)) }
        if path == "note.txt", kind == "removed" { try! FileManager.default.moveItem(atPath: file, toPath: source + "/retained-original") }
    }
    #expect(!result.capturedInventoryComplete)
    #expect(result.issues.map(\.path).contains(kind == "symlink" ? "outside-link" : "note.txt"))
    #expect(FileManager.default.fileExists(atPath: file) || FileManager.default.fileExists(atPath: source + "/retained-original"))
}

@Test(arguments: [false, true])
func activeRecoveryCopyIncludesUnpublishedHistoryAndKeepsPrivateBuffers(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let edit = try await put("unpublished", birth: NoteBirth(bytes: Array(repeating: 1, count: 16)), generation: 1, session: session)
    let item = try PendingItemID(bytes: uuidBytes()), pending = try await pendingInput(session, body: "private latest")
    try await session.retainPendingSnapshot(pending, basedOn: session.pendingItem(item))
    let root = try emptyRepository()
    try Data([10,11]).write(to: URL(fileURLWithPath: root).appendingPathComponent("unknown.bin"))
    let copy = try await session.copyRepositoryAndSavedWork(from: root, to: privateTempPath())
    #expect(copy.repository.capturedInventoryComplete && copy.repository.unmetRequirements.isEmpty)
    let hex: ([UInt8]) -> String = { $0.map { String(format: "%02x", $0) }.joined() }
    let descriptorPath = "NV Data/v1/keys/" + hex(initial.descriptor.descriptorID) + ".nvkey"
    #expect(copy.repository.files.contains { $0.path == descriptorPath })
    let editSequence = String(edit.object.sequence)
    let editLeaf = String(repeating: "0", count: 20 - editSequence.count) + editSequence + "-" + hex(edit.object.segmentID.bytes) + ".nvseg"
    let editPath = "NV Data/v1/segments/" + hex(edit.object.writerEpoch.bytes) + "/" + editLeaf
    #expect(copy.repository.files.contains { $0.path == editPath })
    #expect(copy.through == 2 && copy.excludedPrivatePendingItems == 1)
    #expect(try await session.retainedPendingSnapshot(pending.id) == pending)
    let bytes = try await session.retainedObject(at: edit.object)
    #expect(try copy.repository.files.contains { try Data(contentsOf: URL(fileURLWithPath: copy.repository.destination).appendingPathComponent($0.path)) == Data(bytes) })
    let history = copy.repository.files.filter { $0.path.hasSuffix(".nvseg") }
    let selection = try LocalStoreSelection(directory: privateTempPath(), store: LocalStoreID(bytes: uuidBytes()), descriptor: initial.descriptor)
    let candidate = try await BootstrapCandidate.create(selection: selection, snapshot: initial.snapshot, protection: protection)
    for file in history { _ = try await candidate.retain(Array(Data(contentsOf: URL(fileURLWithPath: copy.repository.destination).appendingPathComponent(file.path)))) }
    let reopened = try await candidate.complete(snapshot: initial.snapshot)
    for file in history { _ = try await reopened.receive(Array(Data(contentsOf: URL(fileURLWithPath: copy.repository.destination).appendingPathComponent(file.path)))) }
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["unpublished", "untouched"])
    #expect(try await reopened.history(for: .note(NoteBirth(bytes: Array(repeating: 1, count: 16)))).entries.count == 2)
    try await reopened.quiesce(); try await session.quiesce()
}

@Test(arguments: [false, true])
func activeRecoveryCopyPreservesSavedHistoryWithMissingRepository(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    let edit = try await put("saved while repository missing", birth: .init(bytes: .init(repeating: 1, count: 16)),
        generation: 1, session: source)
    let expectedBytes = try await source.retainedObject(at: edit.object)
    let pending = try await pendingInput(source, body: "retained privately")
    let item = try PendingItemID(bytes: uuidBytes())
    try await source.retainPendingSnapshot(pending, basedOn: source.pendingItem(item))
    let absent = privateTempPath(), destination = privateTempPath()
    let copied = try await source.copyRepositoryAndSavedWork(from: absent, to: destination)
    #expect(!copied.repository.capturedInventoryComplete)
    #expect(copied.repository.issues.count == 1 && copied.repository.issues[0].path == "")
    #expect(copied.repository.issues.first?.cause == .ownership(ENOENT))
    #expect(copied.repository.unmetRequirements.isEmpty)
    #expect(copied.excludedPrivatePendingItems == 1 && copied.through == 2)
    #expect(!FileManager.default.fileExists(atPath: absent))
    await #expect(throws: StorageError.wrongContext) { try await source.copyRepositoryAndSavedWork(from: absent, to: absent) }
    #expect(!FileManager.default.fileExists(atPath: absent))
    #expect(try await source.retainedPendingSnapshot(pending.id) == pending)
    let exactPath = destination + "/" + ImmutableRepositoryLocator.segment(edit.object).relativePath
    #expect(try Data(contentsOf: URL(fileURLWithPath: exactPath)) == Data(expectedBytes))
    try await source.quiesce()
    let selection = try LocalStoreSelection(directory: privateTempPath(), store: .init(bytes: uuidBytes()), descriptor: initial.descriptor)
    let candidate = try await BootstrapCandidate.create(selection: selection, snapshot: initial.snapshot, protection: protection)
    let history = try copied.repository.files.filter { $0.path.hasSuffix(".nvseg") }.map {
        Array(try Data(contentsOf: URL(fileURLWithPath: destination + "/" + $0.path)))
    }
    for bytes in history { _ = try await candidate.retain(bytes) }
    let rebuilt = try await candidate.complete(snapshot: initial.snapshot)
    for bytes in history { _ = try await rebuilt.receive(bytes) }
    #expect(try await rebuilt.snapshot().notes.map(\.value.body.string).sorted() == ["saved while repository missing", "untouched"])
    try await rebuilt.quiesce()
    let occupied = try emptyRepository()
    try Data([1, 2, 3]).write(to: URL(fileURLWithPath: occupied + "/foreign"))
    let reopened = try await LocalStoreSession.open(selection: source.selection, protection: protection)
    await #expect(throws: (any Error).self) { try await reopened.copyRepositoryAndSavedWork(from: absent, to: occupied) }
    #expect(try Data(contentsOf: URL(fileURLWithPath: occupied + "/foreign")) == Data([1, 2, 3]))
    try await reopened.quiesce()
}

@Test(arguments: [false, true])
func explicitCurrentExportHasFreshBirthsAndUsableCredentials(encrypted: Bool) async throws {
    let values = try [testValue("live unsaved"), testValue("also live")]
    let result = try await CurrentCollectionExport.create(values: values,
        profile: encrypted ? .encrypted(passphrase: "new independent password") : .passwordFree,
        toRepository: privateTempPath(), privateDirectory: privateTempPath())
    #expect(result.births.count == 2 && Set(result.births).count == 2)
    #expect(result.selection.descriptor.collection.bytes != Array(repeating: 1, count: 16))
    let protection: ObjectProtectionV1
    if encrypted {
        guard let id = result.selection.descriptor.keyID else { Issue.record("encrypted export lost key ID"); return }
        let ck = try result.selection.descriptor.unwrap(passphrase: "new independent password")
        protection = .encrypted(keyID: id, key: ck)
        for entry in result.repository.files {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: result.repository.destination).appendingPathComponent(entry.path))
            #expect(bytes.range(of: Data("live unsaved".utf8)) == nil)
        }
    } else { protection = .publicHash }
    let opened = try await LocalStoreSession.open(selection: result.selection, protection: protection)
    #expect(Set(try await opened.snapshot().notes.map(\.birth)) == Set(result.births))
    #expect(try await opened.snapshot().notes.map(\.value.body.string).sorted() == ["also live", "live unsaved"])
    #expect(try await opened.snapshot().through == 1)
    try await opened.quiesce()
}
