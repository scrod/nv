import Foundation
import NVStorageCore

/// Result of one optional whole-database compaction after its writer work has settled.
public enum VacuumOutcome: Equatable, Sendable {
    case completed, interrupted
    case skipped(VacuumSkipReason)
}

public enum VacuumSkipReason: Equatable, Sendable { case requiredWork, storeBudget, spaceHeadroom }

/// Qualification bounds for an explicit compaction attempt, admitted by an idle owner.
public struct VacuumBudget: Sendable {
    public let maximumStoreBytes: UInt64
    public let minimumFreeBytes: UInt64
    public init(maximumStoreBytes: UInt64 = 256 * 1024 * 1024, minimumFreeBytes: UInt64 = 64 * 1024 * 1024) throws {
        guard maximumStoreBytes > 0 else { throw StorageError.limit }
        self.maximumStoreBytes = maximumStoreBytes; self.minimumFreeBytes = minimumFreeBytes
    }
}

/// A single actor-owned reservation carries pre-start and running cancellation through settlement.
enum MaintenanceState: Sendable {
    case idle, preparing(cancelled: Bool), running(VacuumRequest)
    var active: Bool { if case .idle = self { false } else { true } }
}

extension LocalStoreSession {
    /// Signals resumed interaction while the operation keeps ownership through settlement.
    public func cancelOptionalMaintenance() { cancelMaintenance() }

    /// Requests cessation of the exact physical job before required work joins the database lane.
    func cancelMaintenance() {
        switch maintenance {
        case .idle: break
        case .preparing: maintenance = .preparing(cancelled: true)
        case .running(let request): request.cancel()
        }
    }

    /// Compacts a healthy idle store within advisory space/work bounds and settles cancellation before returning.
    public func compactPrivateStore(budget: VacuumBudget? = nil) async throws -> VacuumOutcome {
        guard !closed, !quiescing else { throw StorageError.closed }
        guard !maintenance.active else { throw StorageError.busy }
        guard !inFlight, commitState.owned == nil, !receiving, !snapshotState.isRunning,
              !backupInFlight, !activationInFlight, !pendingPreparationInFlight, !rowEncodingInFlight else { return .skipped(.requiredWork) }
        maintenance = .preparing(cancelled: false)
        defer {
            maintenance = .idle
            let waiters = drained; drained.removeAll(); for waiter in waiters { waiter.resume() }
        }
        let budget = try budget ?? VacuumBudget(), selection = selection
        let request = try await lane.perform { db -> VacuumRequest? in
            try db.validateOwner(); try db.requireHealthyHistory()
            try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
            guard try db.privateStoreBytes() <= budget.maximumStoreBytes else { return nil }
            return try db.beginVacuum()
        }
        guard let request else { return .skipped(.storeBudget) }
        if case .preparing(let cancelled) = maintenance, cancelled { request.cancel() }
        maintenance = .running(request)
        do {
            return try await withTaskCancellationHandler {
                let gate = try await lane.perform { $0.work?.vacuumPrepared }
                await gate?()
                if Task.isCancelled { request.cancel() }
                return try await lane.perform { db in
                    try db.runVacuum(request, directory: selection.directory, minimumFreeBytes: budget.minimumFreeBytes)
                }
            } onCancel: { request.cancel() }
        } catch {
            await lane.retireVacuum(request)
            throw error
        }
    }
}
