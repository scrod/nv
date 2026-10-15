import Dispatch
import Foundation
import NVStorageCore

/// Optional, queue-owned observations and completion gates for storage qualification.
struct StorageWork: Sendable {
    enum Stage: String, CaseIterable, Sendable { case preparation, validation, acceptance, materialization }
    enum DatabaseBoundary: Sendable { case returning, committing, committed }
    struct Counts: Sendable {
        var statements = 0
        var vmSteps = 0
        var statementSteps: [String: Int] = [:]
        var statementCalls: [String: Int] = [:]
        var leastStatementSteps: [String: Int] = [:]
        var mostStatementSteps: [String: Int] = [:]
        var statementScanSteps: [String: Int] = [:]
        var fullScanSteps = 0
        var rows = 0
        var historyReads = 0
        var envelopeDecodes = 0
        var traversalDecodes: [UUID: [SegmentID: Int]] = [:]
        var traversalPayloadDecodes: [UUID: [SegmentID: Int]] = [:]
        var historyEncodedBytes = 0
        var historyDecodedBytes = 0
        var currentCellDecodes = 0
        var currentEncodedBytes = 0
        var currentExpandedBytes = 0
        var dictionaryLoads = 0
        var retainedLeafChecks = 0
        var retentionParentChecks = 0
        var graphLoads = 0
        var ancestors = 0
        var fastChecks = 0
        var fullChecks = 0
        var recursiveStatements = 0
        var nanoseconds: UInt64 = 0
        var writerTurns = 0
        var maxWriterNanoseconds: UInt64 = 0
        var candidateReads = 0
        var candidateBytes = 0
        var largestCandidateBytes = 0
        var snapshotRecords = 0
        var snapshotRecordBytes = 0
        var reconstructionSeeds = 0
        var reconstructionOutsideOperations = 0
        var reconstructionAffectedBirths = 0
        var reconstructionReusedCells = 0
        var reconstructionInstallations = 0
        var discoveryHintBatches = 0
        var discoveryHintInputs = 0
        var discoveryHintHits = 0
        var publicationBatches = 0
        var largestPublicationObjects = 0
        var largestPublicationBytes = 0
        var physicalOwnerChecks = 0
        var connectionContextChecks = 0
    }
    var stages: [Stage: Counts] = [:]
    var elapsedNanoseconds: UInt64 = 0
    /// Qualification gates for a captured history prefix and an already committed result.
    var historyCheck: (@Sendable () async -> Void)?
    var currentRowsPrepared: (@Sendable () async -> Void)?
    var vacuumPrepared: (@Sendable () async -> Void)?
    var commandCheck: (@Sendable () -> Void)?
    var historyValidated: (@Sendable () async -> Void)?
    var acceptanceCompletion: (@Sendable (SegmentLocator) async throws -> Void)?
    var snapshotCandidateCompletion: (@Sendable (SegmentLocator) async throws -> Void)?
    var receiveRetentionCompletion: (@Sendable (SegmentLocator) async throws -> Void)?
    var receiveDiscovered: (@Sendable (SegmentLocator, [ObjectRequirement]) async -> Void)?
    var receiveRecordsPerTurn = 64
    var publishedReceiveStart: (@Sendable () async -> Void)?
    var querySelected: (@Sendable () async -> Void)?
    var snapshotPreparationYield: (@Sendable (SegmentLocator, Int) async -> Void)?
    var reconstructionPrepared: (@Sendable () async -> Void)?
    var recoveryPrepared: (@Sendable () async -> Void)?
    var verificationReplayWillStart: (@Sendable () async -> Void)?
    var verificationReplayFinished: (@Sendable () async -> Void)?
    var backupCaptured: (@Sendable () async -> Void)?
    /// Synchronous qualification gate immediately before an ownership boundary check.
    var databaseBoundary: (@Sendable (DatabaseBoundary) throws -> Void)?
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
