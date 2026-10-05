import NVStorageCore

/// Host-owned current values and latest unsaved generations for the command-line client.
public struct HeadlessModel: Sendable {
    private var basis: StoreSnapshot
    public private(set) var values: [NoteBirth: PlaintextNoteValue]
    public private(set) var pending: [NoteBirth: CapturedNoteGeneration] = [:]
    private var clock: UInt64 = 0
    public init(snapshot: StoreSnapshot) {
        basis = snapshot; values = Dictionary(uniqueKeysWithValues: snapshot.notes.map { ($0.birth, $0.value) })
    }
    @discardableResult public mutating func put(_ value: PlaintextNoteValue, birth: NoteBirth) throws -> CapturedNoteGeneration {
        guard values[birth] != nil, clock < UInt64.max else { throw StorageError.staleCapture }
        clock += 1
        let generation = try CapturedNoteGeneration(birth: birth, generation: clock)
        values[birth] = value; pending[birth] = generation
        return generation
    }
    @discardableResult public mutating func delete(_ birth: NoteBirth) throws -> CapturedNoteGeneration {
        guard values[birth] != nil, clock < UInt64.max else { throw StorageError.staleCapture }
        values.removeValue(forKey: birth)
        clock += 1
        let generation = try CapturedNoteGeneration(birth: birth, generation: clock)
        pending[birth] = generation
        return generation
    }
    public func capture(_ birth: NoteBirth, kind: OrdinaryActionKind = .savedEdit, at snapshot: StoreSnapshot) throws -> CapturedActionGroup {
        guard snapshot.store == basis.store, snapshot.session == basis.session, let generation = pending[birth] else {
            throw StorageError.wrongContext
        }
        let change = values[birth].map { CapturedNoteChange.put(generation, $0) } ?? .delete(generation)
        return try CapturedActionGroup(snapshot: snapshot, kind: values[birth] == nil ? .deleteBatch : kind, changes: [change])
    }
    public mutating func complete(_ receipt: AcceptedHistoryReceipt) throws {
        guard receipt.belongs(to: basis) else { throw StorageError.wrongContext }
        for generation in receipt.covered where pending[generation.birth] == generation {
            pending.removeValue(forKey: generation.birth)
        }
    }
}
