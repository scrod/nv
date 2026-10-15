import Foundation
import CStorageIO
import NVStorageCore

/// Exact selected bytes and physical parent identity captured by the selection owner.
public struct SelectedStoreState: Sendable {
    public let record: SelectedStoreRecordV1?
    fileprivate let owner: UUID
    fileprivate let parent: [UInt64]
    fileprivate init(record: SelectedStoreRecordV1?, owner: UUID, parent: [UInt64]) {
        self.record = record; self.owner = owner; self.parent = parent
    }
}

/// A cutover distinguishes durable activation from a readback after an uncertain effect.
public enum StoreActivationOutcome: Sendable {
    case activated(SelectedStoreState)
    case unchanged(SelectedStoreState, StorageError)
    case uncertain(observed: SelectedStoreRecordV1?, cause: StorageError)
}

enum SelectionCut: Sendable { case beforeInstall, afterInstall, beforeDurability, afterDurability }

/// Owns the selection parent and runs its bounded filesystem effects on a dedicated executor.
public actor SelectedStoreOwner {
    nonisolated private let executor = StorageExecutor(label: "org.notationalvelocity.storage.selection", qos: .utility)
    nonisolated public var unownedExecutor: UnownedSerialExecutor { unsafe executor.asUnownedSerialExecutor() }
    private let directory: String
    private let leaf: String
    private let identity = UUID()
    private var lease: SelectionLease?
    private var working = false
    private var fault: (@Sendable (SelectionCut) throws -> Void)?
    private struct PendingSelection {
        let input: VerifiedActivationInput
        let record: SelectedStoreRecordV1
        let backup: String?
        let sources: [SourceSelectionLease]
    }
    private var pending: PendingSelection?

    private init(directory: String, leaf: String) { self.directory = directory; self.leaf = leaf }
    public static func open(directory: String, leaf: String = "Selected Store") async throws -> SelectedStoreOwner {
        let result = SelectedStoreOwner(directory: directory, leaf: leaf)
        try await result.acquire()
        return result
    }
    private func acquire() throws {
        guard !directory.utf8.contains(0), !leaf.utf8.contains(0), !leaf.isEmpty,
              leaf != ".", leaf != "..", !leaf.contains("/") else { throw StorageError.wrongContext }
        lease = try SelectionLease(directory: directory, executor: executor)
    }
    public func capture() throws -> SelectedStoreState {
        guard !working, pending == nil, let lease else { throw StorageError.busy }
        return try SelectedStoreState(record: lease.read(leaf: leaf), owner: identity, parent: lease.parent())
    }
    public func close() throws {
        guard !working else { throw StorageError.busy }
        for source in pending?.sources ?? [] { source.close() }
        lease?.close(); lease = nil; pending = nil
    }
    func setFault(_ fault: (@Sendable (SelectionCut) throws -> Void)?) { self.fault = fault }

    /// Consumes fresh-open evidence while both candidate and original store leases remain held.
    func install(_ input: VerifiedActivationInput, basedOn state: SelectedStoreState) throws -> StoreActivationOutcome {
        try Task.checkCancellation()
        guard !working, let lease else { throw StorageError.closed }
        guard pending == nil else { throw StorageError.busy }
        guard state.owner == identity, try lease.parent() == state.parent else { throw StorageError.wrongContext }
        guard try lease.read(leaf: leaf) == state.record else { throw StorageError.staleCapture }
        guard state.record.map({ current in current.association == input.association &&
              input.sources.contains(where: { $0.selection.store == current.store }) }) ?? true else {
            throw StorageError.wrongContext
        }
        working = true
        defer {
            working = false
            if pending == nil { lease.close(); self.lease = nil }
        }
        var sources: [SourceSelectionLease] = []
        defer { if pending == nil { for source in sources { source.close() } } }
        for source in input.sources { sources.append(try SourceSelectionLease(source, executor: executor)) }
        let record = try SelectedStoreRecordV1(association: input.association, store: input.candidate.store,
                                             generation: SelectionGeneration(bytes: uuidBytes()))
        let destination = URL(fileURLWithPath: directory).appendingPathComponent(leaf)
        let stageDirectory: String
        #if os(macOS)
        stageDirectory = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: destination, create: true).path
        #else
        stageDirectory = directory
        #endif
        let stageLeaf = ".nv-selection-" + UUID().uuidString
        var attempted = false
        do {
            try lease.prepare(leaf: leaf, expected: state.record, replacement: record,
                              stageDirectory: stageDirectory, stageLeaf: stageLeaf)
            try fault?(.beforeInstall)
            for source in sources { try source.check() }
            try lease.checkExpected()
            try Task.checkCancellation()
            attempted = true
            var backup: String?
            #if os(macOS)
            if state.record != nil {
                backup = ".nv-previous-selection-" + UUID().uuidString
                pending = PendingSelection(input: input, record: record, backup: backup, sources: sources)
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: URL(fileURLWithPath: lease.stagePath()),
                    backupItemName: backup, options: [.withoutDeletingBackupItem, .usingNewMetadataOnly])
            } else {
                pending = PendingSelection(input: input, record: record, backup: nil, sources: sources)
                try lease.installPortable()
            }
            #else
            pending = PendingSelection(input: input, record: record, backup: nil, sources: sources)
            try lease.installPortable()
            #endif
            try fault?(.afterInstall)
            return try finishSelection(record: record, backup: backup, lease: lease)
        } catch {
            let cause = filesystemFailure(error)
            let observed = try? lease.read(leaf: leaf)
            if !attempted, observed == state.record, let parent = try? lease.parent() {
                return .unchanged(SelectedStoreState(record: observed, owner: identity, parent: parent), cause)
            }
            return .uncertain(observed: observed, cause: cause)
        }
    }

    /// Rechecks the held installed item and completes its durability barriers after an ambiguous result.
    func resume(_ input: VerifiedActivationInput) throws -> StoreActivationOutcome {
        try Task.checkCancellation()
        guard !working, let lease else { throw StorageError.closed }
        guard let pending else { throw StorageError.staleCapture }
        guard pending.input.candidate.store == input.candidate.store,
              pending.input.candidate.directory == input.candidate.directory,
              pending.input.candidate.descriptor.encodedBytes == input.candidate.descriptor.encodedBytes,
              pending.input.association == input.association else { throw StorageError.wrongContext }
        working = true
        defer {
            working = false
            if self.pending == nil { lease.close(); self.lease = nil }
        }
        do {
            for source in pending.sources { try source.check() }
            return try finishSelection(record: pending.record, backup: pending.backup, lease: lease)
        } catch {
            return .uncertain(observed: try? lease.read(leaf: leaf), cause: filesystemFailure(error))
        }
    }

    private func finishSelection(record: SelectedStoreRecordV1, backup: String?, lease: SelectionLease) throws -> StoreActivationOutcome {
        try fault?(.beforeDurability)
        try lease.complete(backup: backup)
        try fault?(.afterDurability)
        let observed = try lease.read(leaf: leaf)
        guard observed == record else { throw StorageError.staleCapture }
        let state = try SelectedStoreState(record: observed, owner: identity, parent: lease.parent())
        for source in pending?.sources ?? [] { source.close() }
        pending = nil
        return .activated(state)
    }
}

/// Owns selection handles until their actor executor finishes every use and cleanup.
@safe
private final class SelectionLease {
    private var raw: OpaquePointer?
    private let executor: StorageExecutor
    init(directory: String, executor: StorageExecutor) throws {
        self.executor = executor
        unsafe raw = nv_selection_open(directory)
        guard unsafe raw != nil else { throw StorageError.ownership(errno) }
    }
    deinit { unsafe executor.retireSelection(raw) }
    func close() { if let raw = unsafe raw { unsafe nv_selection_close(raw); unsafe self.raw = nil } }
    private func handle() throws -> OpaquePointer {
        guard let raw = unsafe raw else { throw StorageError.closed }; return unsafe raw
    }
    func parent() throws -> [UInt64] {
        var words = [UInt64](repeating: 0, count: 2)
        let raw = unsafe try handle()
        let rc = words.withUnsafeMutableBufferPointer { unsafe nv_selection_identity(raw, $0.baseAddress) }
        guard rc == 0 else { throw StorageError.ownership(errno) }; return words
    }
    func read(leaf: String) throws -> SelectedStoreRecordV1? {
        var bytes = [UInt8](repeating: 0, count: SelectedStoreRecordV1.byteCount), present: Int32 = 0
        let raw = unsafe try handle()
        let rc = bytes.withUnsafeMutableBufferPointer { unsafe nv_selection_read(raw, leaf, $0.baseAddress, &present) }
        guard rc == 0 else { throw StorageError.ownership(errno) }
        return present == 0 ? nil : try SelectedStoreRecordV1.decodeV1(bytes)
    }
    func prepare(leaf: String, expected: SelectedStoreRecordV1?, replacement: SelectedStoreRecordV1,
                 stageDirectory: String, stageLeaf: String) throws {
        let old = expected?.encodedV1() ?? [], bytes = replacement.encodedV1()
        let raw = unsafe try handle()
        let rc = old.withUnsafeBufferPointer { old in bytes.withUnsafeBufferPointer { bytes in
            unsafe nv_selection_prepare(raw, leaf, old.baseAddress, expected == nil ? 0 : 1,
                bytes.baseAddress, stageDirectory, stageLeaf)
        } }
        guard rc == 0 else { throw StorageError.ownership(errno) }
    }
    func checkExpected() throws { guard unsafe try nv_selection_expected(handle()) == 0 else { throw StorageError.ownership(errno) } }
    func stagePath() throws -> String { unsafe String(cString: try nv_selection_stage_path(handle())) }
    func installPortable() throws { guard unsafe try nv_selection_install_portable(handle()) == 0 else { throw StorageError.ownership(errno) } }
    func complete(backup: String?) throws {
        let raw = unsafe try handle()
        let rc: Int32 = if let backup { unsafe nv_selection_complete(raw, backup) } else { unsafe nv_selection_complete(raw, nil) }
        guard rc == 0 else { throw StorageError.ownership(errno) }
    }
}

/// Holds each original physical store unchanged while the verified selection is installed.
@safe
private final class SourceSelectionLease {
    private var raw: OpaquePointer?
    private let observation: [UInt64]
    private let executor: StorageExecutor
    init(_ source: ActivationSource, executor: StorageExecutor) throws {
        self.executor = executor; observation = source.observation
        guard observation.count == 25 else { throw StorageError.wrongContext }
        unsafe raw = nv_storage_owner_open(source.selection.directory, 0)
        guard unsafe raw != nil else { throw StorageError.ownership(errno) }
        do { try check() } catch { close(); throw error }
    }
    deinit { unsafe executor.retireSource(raw) }
    func close() { if let raw = unsafe raw { unsafe nv_storage_owner_close(raw); unsafe self.raw = nil } }
    func check() throws {
        guard let raw = unsafe raw else { throw StorageError.closed }
        let rc = observation.withUnsafeBufferPointer { unsafe nv_storage_owner_matches(raw, $0.baseAddress) }
        guard rc == 0 else { throw StorageError.staleCapture }
    }
}
