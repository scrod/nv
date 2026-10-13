import Foundation
import CStorageIO
import NVStorageCore

public enum StorageEntryKind: Int32, Sendable { case absent = 0, regular = 1, directory = 2, symlink = 3, other = 4 }
public struct StorageEntryHealth: Sendable {
    public let kind: StorageEntryKind?
    public let accessFailure: Int32?
}

/// Evidence categories preserve credential uncertainty and the scope of validated failure.
public enum StorageHealthCategory: Equatable, Sendable {
    case entryUnavailable, ownershipOrAccess, contextMismatch, unsupportedFormat
    case unlockingOrDatabaseUnreadable, requiredStateIncomplete, requiredStateInvalid
}
/// Names the real opening boundary reached before a failure, preserving interpretation scope.
public enum StorageOpenPhase: Equatable, Sendable { case namespaceAndUnlock, headerAndPrivateGroups, requiredHistory, currentReconstruction }
public struct StorageHealthReport: Sendable {
    public let directory: StorageEntryHealth
    public let database: StorageEntryHealth?
    public let category: StorageHealthCategory
    public let failure: StorageError
    public let phase: StorageOpenPhase
}
public enum DiagnosedStoreOpen: Sendable {
    case opened(LocalStoreSession)
    case recoveryRequired(StorageHealthReport)
}

private actor HealthInspector {
    private var phase: StorageOpenPhase = .namespaceAndUnlock
    nonisolated private let executor = StorageExecutor(label: "org.notationalvelocity.storage.health", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { unsafe executor.asUnownedSerialExecutor() }
    func entry(_ path: String) -> StorageEntryHealth {
        guard !path.utf8.contains(0) else { return StorageEntryHealth(kind: nil, accessFailure: EINVAL) }
        var raw: Int32 = -1
        let result = unsafe nv_storage_entry_kind(path, &raw)
        return StorageEntryHealth(kind: result == 0 ? StorageEntryKind(rawValue: raw) : nil, accessFailure: result == 0 ? nil : errno)
    }
    func entered(_ phase: StorageOpenPhase) { self.phase = phase }
    func lastPhase() -> StorageOpenPhase { phase }
}

extension StorageHealthReport {
    /// Copies current namespace diagnostics after an actual required-state consumer failed.
    static func requiredStateFailure(selection: LocalStoreSelection, failure: StorageError) async -> Self {
        let inspector = HealthInspector(), directory = await inspector.entry(selection.directory)
        let database = directory.kind == .directory ? await inspector.entry(selection.directory + "/Collection.sqlite") : nil
        return .init(directory: directory, database: database, category: .requiredStateInvalid,
            failure: failure, phase: .headerAndPrivateGroups)
    }
}

extension LocalStoreSession {
    /// Uses the real opener and reports ambiguous cipher failures as unlocking/database uncertainty.
    public static func openDiagnosing(selection: LocalStoreSelection, protection: ObjectProtectionV1) async -> DiagnosedStoreOpen {
        await openDiagnosing(selection: selection, protection: protection, measuring: nil)
    }
    static func openDiagnosing(selection: LocalStoreSelection, protection: ObjectProtectionV1, measuring: StorageWork?) async -> DiagnosedStoreOpen {
        let inspector = HealthInspector(), directory = await inspector.entry(selection.directory)
        let database = directory.kind == .directory ? await inspector.entry(selection.directory + "/Collection.sqlite") : nil
        do { return try await .opened(open(selection: selection, protection: protection, measuring: measuring,
            diagnosing: { await inspector.entered($0) })) }
        catch {
            let failure = classify(error), category: StorageHealthCategory
            if directory.kind != .directory || database?.kind != .regular { category = .entryUnavailable }
            else {
                switch failure {
                case .wrongContext: category = .contextMismatch
                case .unsupported: category = .unsupportedFormat
                case .incomplete: category = .requiredStateIncomplete
                case .integrity: category = .requiredStateInvalid
                case .database: category = .unlockingOrDatabaseUnreadable
                case .ownership, .busy, .closed, .staleCapture, .limit: category = .ownershipOrAccess
                }
            }
            return await .recoveryRequired(StorageHealthReport(directory: directory, database: database, category: category,
                failure: failure, phase: inspector.lastPhase()))
        }
    }
}
