import Foundation
import NVStorageCore

/// One exact accepted envelope whose records and complete indexed groups agree.
struct CheckedEnvelopeRecords: Sendable {
    let locator: SegmentLocator
    let sequence: Int64
    let operations: [IdentifiedOperation]
    let actions: [ActionV1]
    let operationReferences: [OperationID: StoredOperationReferenceV1]
    let actionReferences: [ActionID: StoredActionReferenceV1]
    private init(locator: SegmentLocator, sequence: Int64, operations: [IdentifiedOperation], actions: [ActionV1],
                 operationReferences: [OperationID: StoredOperationReferenceV1], actionReferences: [ActionID: StoredActionReferenceV1]) {
        self.locator = locator; self.sequence = sequence; self.operations = operations; self.actions = actions
        self.operationReferences = operationReferences; self.actionReferences = actionReferences
    }

    /// Opens each selected source once and checks its occurrences, record metadata and links in bounded turns.
    static func read(source: [UInt8], through: Int64, attempt: UUID, lane: DatabaseLane,
                     selection: LocalStoreSelection, protection: ObjectProtectionV1) async throws -> Self {
        try await lane.verifying(.history(through)) {
            do {
                let (bytes, locator, sequence) = try await lane.perform { db in
                    try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
                    let rows = try db.rows("SELECT o.encoded,o.writer_epoch,o.sequence,o.kind,a.seq FROM accepted_objects a LEFT JOIN objects o USING(object_id) WHERE a.object_id=?", [.blob(source)])
                    guard let row = rows.first, row[0] != .null else { throw StorageError.incomplete }
                    guard row[3] == .integer(1), try row[4].number <= through else { throw StorageError.integrity }
                    let locator = try SegmentLocator.decodeV1(row[1].bytes + row[2].bytes + source)
                    db.countWork { $0.historyReads += 1; $0.envelopeDecodes += 1; $0.traversalDecodes[attempt, default: [:]][locator.segmentID, default: 0] += 1 }
                    return try (row[0].bytes, locator, row[4].number)
                }
                let (payload, decodedBytes) = try await lane.historyWork {
                    let opened = try ObjectEnvelopeV1.open(bytes, collection: selection.descriptor.collection, protection: protection, expectedLocator: locator)
                    guard opened.kind == .changes else { throw StorageError.integrity }
                    return try (ChangesPayloadV1.decodeV1(opened.payload), opened.payload.count)
                }
                try await lane.perform { db in db.countWork {
                    $0.historyEncodedBytes += bytes.count; $0.historyDecodedBytes += decodedBytes
                    $0.traversalPayloadDecodes[attempt, default: [:]][locator.segmentID, default: 0] += 1
                } }
                let ops = try await occurrences("operation_occurrences", id: "operation_id", source: source, lane: lane)
                let acts = try await occurrences("action_occurrences", id: "action_id", source: source, lane: lane)
                guard ops == payload.operations.enumerated().map({ [.integer(Int64($0.offset)), .blob($0.element.operation.id.bytes)] }),
                      acts == payload.actions.enumerated().map({ [.integer(Int64($0.offset)), .blob($0.element.action.id.bytes)] }) else { throw StorageError.integrity }
                var operationRefs: [OperationID: StoredOperationReferenceV1] = [:], actionRefs: [ActionID: StoredActionReferenceV1] = [:]
                for (index, record) in payload.operations.enumerated() {
                    try Task.checkCancellation()
                    let op = record.operation
                    let row = try await lane.perform { db -> [SQLValue] in
                        let rows = try db.rows("SELECT * FROM operations WHERE operation_id=? AND first_seq<=?", [.blob(op.id.bytes), .integer(through)])
                        guard let row = rows.first else { throw StorageError.integrity }; return row
                    }
                    guard row[1] == .integer(operationTag(op.effect)),
                          row[2] == (op.effect.targetBirth.map { .blob($0.bytes) } ?? .null),
                          row[3] == (op.effect.actionID.map { .blob($0.bytes) } ?? .null),
                          try await links("operation_parents", column: "parent", child: op.id.bytes, lane: lane) == op.causalParents.ids.map(\.bytes).sorted(by: byteOrder),
                          try await links("note_predecessors", column: "predecessor", child: op.id.bytes, lane: lane) == op.notePredecessors.ids.map(\.bytes).sorted(by: byteOrder) else { throw StorageError.integrity }
                    if row[4] == .blob(source) {
                        guard row[5] == .integer(Int64(index)), row[6] == .integer(sequence) else { throw StorageError.integrity }
                        operationRefs[op.id] = .init(locator: locator, index: OperationIndex(UInt32(index)), id: op.id)
                    }
                    for ref in record.causalReferences + record.noteReferences { try await check(ref, through: through, lane: lane) }
                }
                for (index, record) in payload.actions.enumerated() {
                    try Task.checkCancellation()
                    let action = record.action
                    let row = try await lane.perform { db -> [SQLValue] in
                        let rows = try db.rows("SELECT * FROM actions WHERE action_id=? AND first_seq<=?", [.blob(action.id.bytes), .integer(through)])
                        guard let row = rows.first else { throw StorageError.integrity }; return row
                    }
                    let birth: SQLValue = { if case .note(let birth) = action.scope { .blob(birth.bytes) } else { .null } }()
                    guard row[1] == .blob(action.origin.bytes), row[2] == (action.previousOriginAction.map { .blob($0.bytes) } ?? .null),
                          row[3] == birth, row[4] == .integer(Int64(action.kind.rawValue)),
                          try await links("action_scope_parents", column: "parent", child: action.id.bytes, lane: lane) == action.scopeParents.map(\.bytes).sorted(by: byteOrder),
                          try await members(action: action.id, lane: lane) == action.members.map(\.bytes) else { throw StorageError.integrity }
                    if row[5] == .blob(source) {
                        guard row[6] == .integer(Int64(index)), row[7] == .integer(sequence) else { throw StorageError.integrity }
                        actionRefs[action.id] = .init(locator: locator, index: ActionIndex(UInt32(index)), id: action.id)
                    }
                    var actionReferences = record.scopeReferences
                    if let previous = record.previousOriginReference { actionReferences.append(previous) }
                    actionReferences += record.restorationReferences.map(\.deletionAction)
                    actionReferences += record.detailsReference?.actionReferences ?? []
                    for ref in actionReferences { try await check(ref, through: through, lane: lane) }
                    var operationReferences = record.detailsReference?.operationReferences ?? []
                    for entry in record.affectedReferences { operationReferences += references(entry.before) + references(entry.after) }
                    for restoration in record.restorationReferences {
                        operationReferences.append(restoration.revision)
                        if let state = restoration.priorState { operationReferences += references(state) }
                    }
                    for ref in operationReferences { try await check(ref, through: through, lane: lane) }
                }
                return Self(locator: locator, sequence: sequence, operations: payload.operations.map(\.operation), actions: payload.actions.map(\.action),
                            operationReferences: operationRefs, actionReferences: actionRefs)
            } catch { try await lane.failRetainedRead(error) }
        }
    }

    private static func references(_ state: ActionStateReference) -> [OperationReference] {
        switch state {
        case .freshBirthAbsence: []
        case .value(let ref), .deleted(let ref): [ref]
        case .automatic(let source): [source.revision]
        case .derived(let state): state.references
        }
    }
    private static func check(_ ref: OperationReference, through: Int64, lane: DatabaseLane) async throws {
        if case .external(let locator, let index, let id) = ref {
            try await checkOccurrence(locator, index: index.rawValue, id: id.bytes, operation: true, through: through, lane: lane)
        }
    }
    private static func check(_ ref: ActionReference, through: Int64, lane: DatabaseLane) async throws {
        if case .external(let locator, let index, let id) = ref {
            try await checkOccurrence(locator, index: index.rawValue, id: id.bytes, operation: false, through: through, lane: lane)
        }
    }
    static func checkOccurrence(_ locator: SegmentLocator, index: UInt32, id: [UInt8], operation: Bool,
                                through: Int64, lane: DatabaseLane) async throws {
        try await lane.perform { db in
            let table = operation ? "operation_occurrences" : "action_occurrences", column = operation ? "operation_id" : "action_id"
            let rows = try db.rows("SELECT o.writer_epoch,o.sequence,o.kind,a.seq,c.\(column) FROM accepted_objects a LEFT JOIN objects o USING(object_id) LEFT JOIN \(table) c ON c.object_id=a.object_id AND c.record_index=? WHERE a.object_id=?", [.integer(Int64(index)), .blob(locator.segmentID.bytes)])
            guard let row = rows.first else { throw StorageError.incomplete }
            guard row[0] == .blob(locator.writerEpoch.bytes), row[1] == .blob(Array(locator.encodedV1()[16..<24])), row[2] == .integer(1),
                  try row[3].number <= through, row[4] == .blob(id) else { throw StorageError.integrity }
        }
    }
    private static func occurrences(_ table: String, id: String, source: [UInt8], lane: DatabaseLane) async throws -> [[SQLValue]] {
        var result: [[SQLValue]] = [], index: Int64 = -1
        while true {
            let after = index
            let rows = try await lane.perform { try $0.rows("SELECT record_index,\(id) FROM \(table) WHERE object_id=? AND record_index>? ORDER BY record_index LIMIT 64", [.blob(source), .integer(after)]) }
            result += rows
            guard rows.count == 64 else { return result }; index = try rows.last![0].number
        }
    }
    private static func operationTag(_ effect: OperationEffectV1) -> Int64 {
        switch effect { case .genesis: 1; case .importComplete: 2; case .create: 3; case .importNote: 4; case .put: 5; case .delete: 6; case .recoverCopy: 7; case .retireConflict: 8; case .adoptAutomatic: 9 }
    }
    private static func byteOrder(_ a: [UInt8], _ b: [UInt8]) -> Bool { a.lexicographicallyPrecedes(b) }
    private static func links(_ table: String, column: String, child: [UInt8], lane: DatabaseLane) async throws -> [[UInt8]] {
        var result: [[UInt8]] = [], position: [UInt8] = []
        while true {
            let cursor = position
            let rows = try await lane.perform { try $0.rows("SELECT \(column) FROM \(table) WHERE child=? AND \(column)>? ORDER BY \(column) LIMIT 64", [.blob(child), .blob(cursor)]) }
            result += try rows.map { try $0[0].bytes }
            guard rows.count == 64 else { return result }; position = try rows.last![0].bytes
        }
    }
    private static func members(action: ActionID, lane: DatabaseLane) async throws -> [[UInt8]] {
        var result: [[UInt8]] = [], position: Int64 = -1
        while true {
            let cursor = position
            let rows = try await lane.perform { try $0.rows("SELECT ordinal,operation_id FROM action_members WHERE action_id=? AND ordinal>? ORDER BY ordinal LIMIT 64", [.blob(action.bytes), .integer(cursor)]) }
            guard rows.enumerated().allSatisfy({ $0.element[0] == .integer(Int64(result.count + $0.offset)) }) else { throw StorageError.integrity }
            result += try rows.map { try $0[1].bytes }
            guard rows.count == 64 else { return result }; position = try rows.last![0].number
        }
    }
}
