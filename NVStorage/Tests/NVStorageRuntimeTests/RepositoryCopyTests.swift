import Foundation
import Crypto
import CStorageFaults
import Testing
import NVStorageCore
@testable import NVStorageRuntime

func emptyRepository() throws -> String {
    let path = privateTempPath()
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    return path
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
