import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

@Test func repositoryNestedListingPreservesParentAndBoundsResources() async throws {
    let path = try repositoryDirectory(), base = URL(fileURLWithPath: path + "/NV Data/v1/segments")
    var expected: Set<String> = []
    for n in 0..<19 {
        let epoch = try WriterEpoch(bytes: .init(repeating: UInt8(n + 1), count: 16))
        let leaf = epoch.bytes.map { String(format: "%02x", $0) }.joined()
        expected.insert(leaf)
        let directory = base.appendingPathComponent(leaf)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for i in 0..<5 { try Data([1]).write(to: directory.appendingPathComponent("child-\(i)")) }
    }
    let root = try await RepositoryRootSession.open(directory: path), permission = try await root.permission()
    var parent: RepositoryListingCursor?, found: Set<String> = [], finished = false
    repeat {
        let page = try await root.list(.segments, continuing: parent, budget: 3, using: permission)
        parent = page.continuation; finished = parent == nil
        for name in page.names {
            let text = String(decoding: name.bytes, as: UTF8.self)
            let bytes = stride(from: 0, to: text.count, by: 2).map { i in UInt8(text.dropFirst(i).prefix(2), radix: 16)! }
            let directory = RepositoryProtocolDirectory.writer(try WriterEpoch(bytes: bytes))
            var child: RepositoryListingCursor?, children: Set<String> = []
            repeat {
                let nested = try await root.list(directory, continuing: child, budget: 2, using: permission)
                children.formUnion(nested.names.map { String(decoding: $0.bytes, as: UTF8.self) })
                child = nested.continuation
                #expect(await root.listingResourceCount() <= 2)
            } while child != nil
            #expect(children == Set((0..<5).map { "child-\($0)" }))
            found.insert(text)
        }
    } while !finished
    #expect(found == expected)
    #expect(await root.listingResourceCount() == 0)
    await root.close()
}

@Test func repositoryNestedListingCancellationAndGenerationFence() async throws {
    let path = try repositoryDirectory(), epoch = try WriterEpoch(bytes: .init(repeating: 9, count: 16))
    let leaf = epoch.bytes.map { String(format: "%02x", $0) }.joined()
    let base = URL(fileURLWithPath: path + "/NV Data/v1/segments/" + leaf)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    for i in 0..<20 { try Data([1]).write(to: base.appendingPathComponent("child-\(i)")) }
    let root = try await RepositoryRootSession.open(directory: path), permission = try await root.permission()
    let parent = try #require(await root.list(.segments, budget: 1, using: permission).continuation)
    let child = try #require(await root.list(.writer(epoch), budget: 1, using: permission).continuation)
    #expect(await root.listingResourceCount() == 2)
    try await root.cancelListing(child, using: permission)
    #expect(await root.listingResourceCount() == 1)
    await #expect(throws: RepositoryRootError.wrongContext) { try await root.list(.writer(epoch), continuing: child, using: permission) }
    let resumed = try await root.list(.segments, continuing: parent, budget: 1, using: permission)
    let current = try #require(resumed.continuation)
    await root.invalidate()
    #expect(try await root.revalidate(candidate: path) == .same)
    let fresh = try await root.permission()
    await #expect(throws: RepositoryRootError.stalePermission) { try await root.list(.segments, continuing: current, using: fresh) }
    _ = try await root.list(.segments, budget: 1, using: fresh)
    #expect(await root.listingResourceCount() == 1)
    await root.close()
    #expect(await root.listingResourceCount() == 0)
}
