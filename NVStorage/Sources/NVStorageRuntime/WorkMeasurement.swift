import Dispatch
import NVStorageCore

/// Optional, queue-owned observations and completion gates for storage qualification.
struct StorageWork: Sendable {
    enum Stage: String, CaseIterable, Sendable { case preparation, validation, acceptance, materialization }
    struct Counts: Sendable {
        var statements = 0
        var vmSteps = 0
        var statementSteps: [String: Int] = [:]
        var fullScanSteps = 0
        var rows = 0
        var historyReads = 0
        var envelopeDecodes = 0
        var ancestors = 0
        var fastChecks = 0
        var fullChecks = 0
        var recursiveStatements = 0
        var nanoseconds: UInt64 = 0
    }
    var stages: [Stage: Counts] = [:]
    var elapsedNanoseconds: UInt64 = 0
    /// Qualification gates for a captured history prefix and an already committed result.
    var historyCheck: (@Sendable () -> Void)?
    var historyValidated: (@Sendable () async -> Void)?
    var acceptanceCompletion: (@Sendable (SegmentLocator) async throws -> Void)?
    subscript(_ stage: Stage) -> Counts { stages[stage] ?? Counts() }
}

extension Database {
    func measuring<T>(_ stage: StorageWork.Stage, _ body: () throws -> T) rethrows -> T {
        let previous = workStage
        workStage = stage
        let start = work == nil ? 0 : DispatchTime.now().uptimeNanoseconds
        defer {
            if work != nil { countWork { $0.nanoseconds += DispatchTime.now().uptimeNanoseconds - start } }
            workStage = previous
        }
        return try body()
    }
    func countWork(_ update: (inout StorageWork.Counts) -> Void) {
        guard work != nil else { return }
        update(&work!.stages[workStage, default: .init()])
    }
}
