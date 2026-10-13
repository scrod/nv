import Foundation
import Testing
@testable import NVStorageRuntime

@Test func repositorySelectedAvailabilityKeepsReadAndIssuerIndependent() async throws {
    let path = try repositoryDirectory(), otherPath = try repositoryDirectory()
    let expected: [UInt8] = [0, 7, 255, 13]
    try Data(expected).write(to: URL(fileURLWithPath: path + "/selected"))
    let root = try await RepositoryRootSession.open(directory: path)
    let other = try await RepositoryRootSession.open(directory: otherPath)
    let permission = try await root.permission()
    let observed = try await root.observe("selected", using: permission)
    guard case .observed(let availability) = try await root.availability(observed, using: permission) else {
        Issue.record("The local selected-file companion must provide availability"); return
    }
#if canImport(Darwin)
    #expect(availability.residency == .materialized)
#else
    #expect(availability.residency == .unknown)
#endif
    #expect(availability.management == .unknown)
    #expect(availability.download == .unknown)
    #expect(availability.uploaded == nil)
    #expect(try await root.requestMaterialization(availability, using: permission) == .unsupported)
    guard case .contents(let contents) = try await root.read(observed, maximumBytes: 4, using: permission) else {
        Issue.record("Exact local bytes must remain readable independently of provider status"); return
    }
    #expect(contents.bytes == expected)
    await #expect(throws: RepositoryRootError.wrongContext) {
        try await other.validate(availability, using: other.permission())
    }
    await root.invalidate()
    await #expect(throws: RepositoryRootError.stalePermission) { try await root.validate(availability, using: permission) }
    #expect(try await root.revalidate(candidate: path) == .same)
    await #expect(throws: RepositoryRootError.stalePermission) {
        try await root.requestMaterialization(availability, using: root.permission())
    }
    #expect(try Array(Data(contentsOf: URL(fileURLWithPath: path + "/selected"))) == expected)
    await root.close(); await other.close()
}

@Test func repositoryProviderUnknownPreservesPhysicalOwnership() async throws {
    let path = try repositoryDirectory(), root = try await RepositoryRootSession.open(directory: path)
    let permission = try await root.permission()
    let observation = try await root.providerObservation(using: permission)
#if canImport(Darwin)
    if case .identified = observation.lookup { Issue.record("An unrelated local temporary directory unexpectedly has provider identity") }
#else
    guard case .unsupported = observation.lookup else { Issue.record("Portable provider lookup must report unsupported"); return }
#endif
    try await root.validate(observation, using: permission)
    let other = try await RepositoryRootSession.open(directory: repositoryDirectory())
    await #expect(throws: RepositoryRootError.wrongContext) { try await other.validate(observation, using: other.permission()) }
    await other.close()
    #expect(await root.state == .active)
    await #expect(throws: RepositoryRootError.contention) { try await RepositoryRootSession.open(directory: path) }
    await root.invalidate()
    await #expect(throws: RepositoryRootError.stalePermission) { try await root.validate(observation, using: permission) }
    #expect(try await root.revalidate(candidate: path) == .same)
    await root.close()
}

@Test func repositoryURLAcquisitionBalancesItsOwnedLifetime() async throws {
    let path = try repositoryDirectory(), url = URL(fileURLWithPath: path, isDirectory: true)
    let root = try await RepositoryRootSession.open(directory: url)
    await #expect(throws: RepositoryRootError.contention) { try await RepositoryRootSession.open(directory: url) }
    await root.close(); await root.close()
    let successor = try await RepositoryRootSession.open(directory: url)
    await successor.close()
    await #expect(throws: RepositoryRootError.unsafePath) {
        try await RepositoryRootSession.open(directory: #require(URL(string: "https://example.invalid/")))
    }
}

#if canImport(Darwin)
private actor ProviderDeliveryGate {
    private var entered = false, released = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    private(set) var expired = false
    func hold() async {
        entered = true; arrival?.resume(); arrival = nil
        if !released { await withCheckedContinuation { release = $0 } }
    }
    func wait() async { if !entered { await withCheckedContinuation { arrival = $0 } } }
    func resume() { released = true; release?.resume(); release = nil }
    func expire() { expired = true; arrival?.resume(); arrival = nil; resume() }
}

@Test(.timeLimit(.minutes(1)))
func repositoryDelayedProviderObservationRejectsChangedGeneration() async throws {
    let path = try repositoryDirectory(), gate = ProviderDeliveryGate()
    try Data([7]).write(to: URL(fileURLWithPath: path + "/note"))
    let root = try await RepositoryRootSession.open(directory: path), permission = try await root.permission()
    let watchdog = Task {
        do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
        await gate.expire()
    }
    defer { watchdog.cancel() }
    let query = Task { try await root.providerObservation(using: permission, beforeDelivery: { await gate.hold() }) }
    await gate.wait(); #expect(await !gate.expired)
    #expect(try await root.observe("note", using: permission).byteCount == 1)
    await root.invalidate(); await gate.resume()
    await #expect(throws: RepositoryRootError.stalePermission) { try await query.value }
    #expect(try await root.revalidate(candidate: path) == .same)
    #expect(try await root.observe("note", using: root.permission()).byteCount == 1)
    await root.close()
}
#endif
