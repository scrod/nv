import Foundation
import Testing

/// Supplies the test-only synchronization interposer to fresh-process participants.
public func projectionSyncFaultSource() throws -> URL {
    try #require(Bundle.module.url(forResource: "ProjectionFilesSyncFault", withExtension: "c", subdirectory: "Resources"))
}
