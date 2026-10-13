import NVStorageTestSupport
import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

@Test(.timeLimit(.minutes(5)), arguments: try RepositoryLocalFixture.prepared.get())
func collectionStartupUsesOneCurrentCaptureAcrossGrowingAncestors(fixture: RepositoryLocalFixture) async throws {
    let selection = try await associatedSelection(fixture, repository: repositoryDirectory())
    var count = 0
    var reference: (statements: Int, leaves: Int)?
    for target in [64, 256, 1024] {
        let writer = try await LocalStoreSession.open(selection: selection, protection: fixture.protection)
        while count < target {
            count += 1
            _ = try await put("fixed current body", birth: .init(bytes: Array(repeating: 1, count: 16)), generation: UInt64(count), session: writer)
        }
        try await writer.quiesce()
        let start = DispatchTime.now().uptimeNanoseconds
        let background = ImprovementGate()
        defer { Task { await background.release() } }
        var measurement = StorageWork()
        measurement.publishedReceiveStart = { await background.hold() }
        let owner = try openedCollection(await CollectionSession.open(selection: selection, protection: fixture.protection,
            repository: nil, hooks: .init(measuring: measurement)))
        #expect(try await collectionBodies(owner) == ["fixed current body", "untouched"])
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let work = try #require(await owner.startupMeasurements())
        let counts = Array(work.stages.values)
        #expect(counts.reduce(0) { $0 + $1.historyReads } == 0)
        #expect(counts.reduce(0) { $0 + $1.graphLoads + $1.ancestors } == 0)
        #expect(counts.reduce(0) { $0 + $1.currentCellDecodes } == 2)
        let statements = counts.reduce(0) { $0 + $1.statements }, leaves = counts.reduce(0) { $0 + $1.retainedLeafChecks }
        if let reference {
            #expect(statements == reference.statements && leaves == reference.leaves)
        } else { reference = (statements, leaves) }
        print("COLLECTION-START profile=\(fixture.initial.descriptor.keyID == nil ? "public" : "encrypted") ancestors=\(target) ns=\(elapsed) sql=\(statements) requiredLeaves=\(leaves) currentDecodes=2 historyReads=0")
        await background.release()
        try await owner.close()
    }
}
