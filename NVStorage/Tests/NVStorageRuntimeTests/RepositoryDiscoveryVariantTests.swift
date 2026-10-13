import NVStorageTestSupport
import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

private struct DiscoveryVariantFixture: Codable {
    let directory: String
    let store: [UInt8]
    let descriptor: [UInt8]
    let files: [String]
    let identities: [[UInt8]]
}

/// Replays identical physical fixtures through isolated, fully checked optimization builds.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NV_STORAGE_DISCOVERY_VARIANTS"] != nil),
      .timeLimit(.minutes(20)), arguments: [false, true])
func repositoryDiscoveryVariantReplay(encrypted: Bool) async throws {
    let artifacts = try #require(ProcessInfo.processInfo.environment["NV_STORAGE_DISCOVERY_VARIANTS"])
    let variant = ProcessInfo.processInfo.environment["NV_STORAGE_DISCOVERY_VARIANT"] ?? "combined"
    let profile = encrypted ? "encrypted" : "public", config = URL(fileURLWithPath: artifacts + "/fixture-\(profile).json")
    let (initial, protection) = try testInitial(encrypted)
    let fixture: DiscoveryVariantFixture
    if FileManager.default.fileExists(atPath: config.path) {
        fixture = try JSONDecoder().decode(DiscoveryVariantFixture.self, from: Data(contentsOf: config))
    } else {
        let owner = try await newSession(initial, protection), base = artifacts + "/files-\(profile)"
        let birth = try NoteBirth(bytes: .init(repeating: 1, count: 16))
        var files: [String] = [], identities: [[UInt8]] = []
        for generation in 1...1024 {
            let saved = try await put("variant replay \(generation)", birth: birth, generation: UInt64(generation), session: owner)
            let relative = ImmutableRepositoryLocator.segment(saved.object).relativePath
            try await deliverFile(owner.retainedObject(at: saved.object), relative: relative, to: base)
            files.append(relative); identities.append(saved.object.segmentID.bytes)
        }
        let selection = await owner.selection
        fixture = DiscoveryVariantFixture(directory: selection.directory, store: selection.store.bytes,
            descriptor: selection.descriptor.encodedBytes, files: files, identities: identities)
        try await owner.quiesce()
        try JSONEncoder().encode(fixture).write(to: config, options: .atomic)
    }
    let selection = try LocalStoreSelection(directory: fixture.directory, store: LocalStoreID(bytes: fixture.store),
        descriptor: BootstrapDescriptorV1.decodeV1(fixture.descriptor))
    let store = try await LocalStoreSession.open(selection: selection, protection: protection)
    let before = try await store.snapshot(), beforeIDs = try await store.lane.perform { try $0.rows("SELECT object_id FROM accepted_objects ORDER BY object_id") }
    var measurements: [[String: Any]] = []
    for size in [64, 256, 1024] {
        let path = artifacts + "/repository-\(profile)-\(size)"
        if !FileManager.default.fileExists(atPath: path) {
            for relative in fixture.files.prefix(size) {
                let bytes = try Data(contentsOf: URL(fileURLWithPath: artifacts + "/files-\(profile)/" + relative))
                try deliverFile(Array(bytes), relative: relative, to: path)
            }
            try FileManager.default.createDirectory(atPath: path + "/NV Data/v1/keys", withIntermediateDirectories: true)
        }
        let expected = try Set(fixture.identities.prefix(size).map(SegmentID.init(bytes:)))
        let root = try await RepositoryRootSession.open(directory: path)
        _ = try await discoverPass(root, into: store, budget: 16)
        for budget in [16, 64] {
            var times: [Double] = []
            for round in 0...9 {
                let start = ContinuousClock.now
                let entries = try await discoverPass(root, into: store, budget: budget)
                let duration = start.duration(to: .now)
                let identities = entries.compactMap { entry -> SegmentID? in if case .unchangedAccepted(let id) = entry.outcome { id } else { nil } }
                #expect(identities.count == size && Set(identities) == expected)
                if round > 0 { times.append(Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15) }
            }
            measurements.append(["files": size, "budget": budget, "samplesMilliseconds": times])
        }
        await root.close()
    }
    #expect(try await store.snapshot().notes == before.notes)
    #expect(try await store.snapshot().context == before.context)
    #expect(try await store.lane.perform { try $0.rows("SELECT object_id FROM accepted_objects ORDER BY object_id") } == beforeIDs)
    try await store.quiesce()
    let result: [String: Any] = ["variant": variant, "profile": profile, "measurements": measurements,
        "expectedObjects": fixture.identities.count, "samePhysicalFixtures": true, "cache": "warm", "repetitions": 9]
    try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: URL(fileURLWithPath: artifacts + "/\(variant)-\(profile).json"), options: .atomic)
}
