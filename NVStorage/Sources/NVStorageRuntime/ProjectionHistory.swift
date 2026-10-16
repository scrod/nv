import Foundation
import NVStorageCore

/// The relationship of a checked historical source to the captured current note.
public enum ProjectionCurrentRelation: Sendable { case matchesCurrent, differentCurrent, absent }

/// Exact historical source contents, fenced to the store and current view used for their read.
public struct CheckedProjectionHistory: Sendable {
    public let stamp: ProjectionStampV1
    public let currentRelation: ProjectionCurrentRelation
    private let value: PlaintextNoteValue
    private let snapshot: StoreSnapshot
    private let connection: UUID

    fileprivate init(stamp: ProjectionStampV1, value: PlaintextNoteValue, snapshot: StoreSnapshot, connection: UUID) throws {
        self.stamp = stamp; self.value = value; self.snapshot = snapshot; self.connection = connection
        currentRelation = try projectionRelation(birth: stamp.birth, state: stamp.state, snapshot: snapshot)
    }

    fileprivate func checkedValue(snapshot current: StoreSnapshot, session: UUID, selection: LocalStoreSelection,
                                  database: Database) throws -> PlaintextNoteValue {
        try checkProjectionView(captured: snapshot, connection: connection, current: current,
            session: session, selection: selection, database: database)
        return value
    }
}

/// Historical validation results for an advisory stamp supplied by a file.
public enum ProjectionHistoryAssessment: Sendable {
    case foreignCollection
    case invalidClaim
    case waiting([SegmentLocator])
    case blocked(prerequisites: [RejectedPrerequisite], unaccepted: [SegmentLocator])
    case checked(CheckedProjectionHistory)
}

/// Complete historical description checked against one owned current-view capture.
public struct CheckedProjectionBindingHistory: Sendable {
    public let binding: ProjectionBindingV1
    public let currentRelation: ProjectionCurrentRelation
    private let value: PlaintextNoteValue
    private let snapshot: StoreSnapshot
    private let connection: UUID

    fileprivate init(binding: ProjectionBindingV1, value: PlaintextNoteValue, snapshot: StoreSnapshot, connection: UUID) throws {
        self.binding = binding; self.value = value; self.snapshot = snapshot; self.connection = connection
        currentRelation = try projectionRelation(birth: binding.birth, state: binding.state, snapshot: snapshot)
    }

    fileprivate func checkedValue(snapshot current: StoreSnapshot, session: UUID, selection: LocalStoreSelection,
                                  database: Database) throws -> PlaintextNoteValue {
        try checkProjectionView(captured: snapshot, connection: connection, current: current,
            session: session, selection: selection, database: database)
        return value
    }
}

/// Source validation outcomes for complete portable projection descriptions.
public enum ProjectionBindingHistoryAssessment: Sendable {
    case foreignCollection
    case invalidClaim
    case waiting([SegmentLocator])
    case blocked(prerequisites: [RejectedPrerequisite], unaccepted: [SegmentLocator])
    case checked(CheckedProjectionBindingHistory)
}

/// Shared source fields for bounded stamps and complete retained descriptions.
private struct ProjectionHistoryClaim: Sendable {
    let collection: CollectionID
    let birth: NoteBirth
    let state: ProjectionStateReferenceV1
    let dependencies: DependencyLocatorTable
}

private enum ProjectionSourceAssessment: Sendable {
    case foreignCollection, invalidClaim
    case waiting([SegmentLocator])
    case blocked(prerequisites: [RejectedPrerequisite], unaccepted: [SegmentLocator])
    case checked(PlaintextNoteValue)
}

extension LocalStoreSession {
    /// Reads descriptions from one exact accepted envelope at the captured history prefix.
    public func projectionDescriptions(in locator: SegmentLocator, basedOn snapshot: StoreSnapshot) async throws -> [ProjectionBindingV1]? {
        guard !closed, !quiescing else { throw StorageError.closed }
        guard snapshot.store == selection.store, snapshot.session == incarnation else { throw StorageError.wrongContext }
        guard selection.descriptor.keyID == nil else { throw StorageError.unsupported }
        let selection = selection, protection = protection, lane = lane
        return try await lane.verifying(.history(snapshot.through)) {
            let present = try await lane.perform { db in
                try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
                try db.checkCurrentView(snapshot)
                return try !db.rows("SELECT 1 FROM accepted_objects WHERE object_id=? AND seq<=?",
                    [.blob(locator.segmentID.bytes), .integer(snapshot.through)]).isEmpty
            }
            let result: [ProjectionBindingV1]?
            if present {
                let envelope = try await CheckedEnvelopeRecords.read(source: locator.segmentID.bytes, through: snapshot.through,
                    attempt: UUID(), lane: lane, selection: selection, protection: protection)
                guard envelope.locator == locator else { throw StorageError.wrongContext }
                result = envelope.projections
            } else { result = nil }
            try await lane.perform { try $0.checkCurrentView(snapshot) }
            return result
        }
    }

    /// Resolves a stamp's exact accepted source independently of file placement and byte encoding.
    public func projectionHistory(for stamp: ProjectionStampV1, basedOn snapshot: StoreSnapshot) async throws -> ProjectionHistoryAssessment {
        let (result, connection) = try await projectionSource(.init(collection: stamp.collection, birth: stamp.birth,
            state: stamp.state, dependencies: stamp.dependencies), basedOn: snapshot)
        switch result {
        case .foreignCollection: return .foreignCollection
        case .invalidClaim: return .invalidClaim
        case .waiting(let inputs): return .waiting(inputs)
        case .blocked(let reasons, let inputs): return .blocked(prerequisites: reasons, unaccepted: inputs)
        case .checked(let value): return try .checked(.init(stamp: stamp, value: value, snapshot: snapshot, connection: connection))
        }
    }

    /// Resolves a complete description's source, including sets larger than the optional stamp.
    public func projectionHistory(for binding: ProjectionBindingV1, basedOn snapshot: StoreSnapshot) async throws -> ProjectionBindingHistoryAssessment {
        let (result, connection) = try await projectionSource(.init(collection: binding.collection, birth: binding.birth,
            state: binding.state, dependencies: binding.dependencies), basedOn: snapshot)
        switch result {
        case .foreignCollection: return .foreignCollection
        case .invalidClaim: return .invalidClaim
        case .waiting(let inputs): return .waiting(inputs)
        case .blocked(let reasons, let inputs): return .blocked(prerequisites: reasons, unaccepted: inputs)
        case .checked(let value): return try .checked(.init(binding: binding, value: value, snapshot: snapshot, connection: connection))
        }
    }

    private func projectionSource(_ claim: ProjectionHistoryClaim, basedOn snapshot: StoreSnapshot) async throws -> (ProjectionSourceAssessment, UUID) {
        guard !closed, !quiescing else { throw StorageError.closed }
        guard snapshot.store == selection.store, snapshot.session == incarnation else { throw StorageError.wrongContext }
        guard selection.descriptor.keyID == nil else { throw StorageError.unsupported }
        let selection = selection, protection = protection, lane = lane
        return try await lane.verifying(.history(snapshot.through)) {
            let connection = try await lane.perform { db in
                try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
                try db.checkCurrentView(snapshot)
                return db.incarnation
            }
            let selected = try await lane.perform { $0.work?.querySelected }
            await selected?()
            var reader = ProjectionHistoryReader(lane: lane, selection: selection, protection: protection, through: snapshot.through)
            let assessment: ProjectionSourceAssessment
            if claim.collection != selection.descriptor.collection { assessment = .foreignCollection }
            else { assessment = try await reader.read(claim) }
            try await lane.perform { db in
                guard db.incarnation == connection else { throw StorageError.wrongContext }
                try db.checkCurrentView(snapshot)
            }
            return (assessment, connection)
        }
    }

    /// Supplies source contents to a consumer still using the checked store, session and current view.
    public func projectionValue(from history: CheckedProjectionHistory, basedOn snapshot: StoreSnapshot) async throws -> PlaintextNoteValue {
        guard !closed, !quiescing else { throw StorageError.closed }
        let selection = selection, session = incarnation
        return try await lane.perform { try history.checkedValue(snapshot: snapshot, session: session, selection: selection, database: $0) }
    }

    /// Supplies complete-description contents under the same checked store and view.
    public func projectionValue(fromBinding history: CheckedProjectionBindingHistory, basedOn snapshot: StoreSnapshot) async throws -> PlaintextNoteValue {
        guard !closed, !quiescing else { throw StorageError.closed }
        let selection = selection, session = incarnation
        return try await lane.perform { try history.checkedValue(snapshot: snapshot, session: session, selection: selection, database: $0) }
    }
}

/// Query-local envelope reuse and note-predecessor traversal for an incoming source claim.
private struct ProjectionHistoryReader {
    let lane: DatabaseLane
    let selection: LocalStoreSelection
    let protection: ObjectProtectionV1
    let through: Int64
    private let attempt = UUID()
    private var envelopes: [SegmentID: CheckedEnvelopeRecords] = [:]

    init(lane: DatabaseLane, selection: LocalStoreSelection, protection: ObjectProtectionV1, through: Int64) {
        self.lane = lane; self.selection = selection; self.protection = protection; self.through = through
    }

    mutating func read(_ stamp: ProjectionHistoryClaim) async throws -> ProjectionSourceAssessment {
        let through = through
        var missing: [SegmentLocator] = [], blockers: Set<SegmentID> = [], rejected: [RejectedPrerequisite] = []
        for locator in stamp.dependencies.entries {
            let status = try await lane.perform { db -> DependencyStatus in
                let row = try db.rows("SELECT o.writer_epoch,o.sequence,o.kind,a.seq FROM objects o LEFT JOIN accepted_objects a USING(object_id) WHERE o.object_id=?", [.blob(locator.segmentID.bytes)]).first
                guard let row else {
                    if try !db.rows("SELECT 1 FROM accepted_objects WHERE object_id=?", [.blob(locator.segmentID.bytes)]).isEmpty {
                        return try db.checkingRetainedHistory { throw StorageError.incomplete }
                    }
                    return .missing
                }
                if row[3] != .null, try row[3].number <= through { return row[2] == .integer(1) ? .accepted : .invalid }
                guard row[0] == .blob(locator.writerEpoch.bytes), row[1] == .blob(Array(locator.encodedV1()[16..<24])),
                      row[2] == .integer(1) else { return .invalid }
                return .missing
            }
            switch status {
            case .invalid: return .invalidClaim
            case .accepted: break
            case .missing:
                missing.append(locator)
                for blocker in try await lane.rejectedPrerequisites(of: locator.segmentID) where blockers.insert(blocker.object).inserted {
                    rejected.append(blocker)
                }
            }
        }
        if !missing.isEmpty {
            return rejected.isEmpty ? .waiting(missing) : .blocked(prerequisites: rejected.sorted { $0.object.bytes.lexicographicallyPrecedes($1.object.bytes) }, unaccepted: missing)
        }
        let refs: [StoredOperationReferenceV1], sourceBirth: NoteBirth
        switch stamp.state {
        case .revision(let ref): refs = [ref]; sourceBirth = stamp.birth
        case .derived(let derived): refs = try derived.references.map(stored); sourceBirth = stamp.birth
        case .automatic(let source): refs = [try stored(source.revision)]; sourceBirth = source.birth
        }
        var exact: [StoredOperationReferenceV1: IdentifiedOperation] = [:]
        for ref in refs {
            let envelope = try await envelope(ref.locator.segmentID)
            guard envelope.locator == ref.locator, Int(ref.index.rawValue) < envelope.operations.count else { return .invalidClaim }
            let op = envelope.operations[Int(ref.index.rawValue)]
            guard op.id == ref.id, op.effect.targetBirth == sourceBirth, op.effect.noteValue != nil else { return .invalidClaim }
            exact[ref] = op
        }
        let history: [IdentifiedOperation]
        if case .derived = stamp.state { history = try await ancestry(Array(exact.values), birth: sourceBirth) }
        else { history = Array(exact.values) }
        let inputs = exact
        let value: PlaintextNoteValue
        do {
            value = try await lane.historyWork {
                switch stamp.state {
                case .revision(let ref):
                    guard let value = inputs[ref]?.effect.noteValue else { throw CanonicalEncodingError.invalidReference }
                    return value
                case .derived(let derived):
                    return try derived.reconstructStandalone(collection: stamp.collection, birth: stamp.birth, history: history) { inputs[$0] }.value.value
                case .automatic(let source):
                    guard let value = inputs[try stored(source.revision)]?.effect.noteValue,
                          try AutomaticConflictKeyV1.compute(source: source.birth, value: value) == source.key else { throw CanonicalEncodingError.identityMismatch }
                    return try value.conflictCopyValue()
                }
            }
        } catch is CanonicalEncodingError { return .invalidClaim }
        return .checked(value)
    }

    private mutating func envelope(_ id: SegmentID) async throws -> CheckedEnvelopeRecords {
        if let cached = envelopes[id] { return cached }
        let loaded = try await CheckedEnvelopeRecords.read(source: id.bytes, through: through, attempt: attempt,
            lane: lane, selection: selection, protection: protection)
        envelopes[id] = loaded
        return loaded
    }

    private mutating func ancestry(_ roots: [IdentifiedOperation], birth: NoteBirth) async throws -> [IdentifiedOperation] {
        var operations = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) }), pending = roots.flatMap { $0.notePredecessors.ids }
        while let id = pending.popLast() {
            try Task.checkCancellation()
            if operations[id] != nil { continue }
            let through = through
            let (source, index) = try await lane.perform { db -> (SegmentID, UInt32) in
                try db.checkingRetainedHistory {
                    guard let row = try db.rows("SELECT source_object,source_index FROM operations WHERE operation_id=? AND first_seq<=?", [.blob(id.bytes), .integer(through)]).first else { throw StorageError.incomplete }
                    guard let index = try UInt32(exactly: row[1].number) else { throw StorageError.integrity }
                    return try (SegmentID(bytes: row[0].bytes), index)
                }
            }
            let envelope = try await envelope(source)
            guard Int(index) < envelope.operations.count else { try await lane.failRetainedRead(StorageError.integrity) }
            let op = envelope.operations[Int(index)]
            guard op.id == id, op.effect.targetBirth == birth, op.effect.noteValue != nil else { try await lane.failRetainedRead(StorageError.integrity) }
            operations[id] = op
            pending.append(contentsOf: op.notePredecessors.ids)
        }
        return Array(operations.values)
    }
}

private enum DependencyStatus { case accepted, missing, invalid }
private func checkProjectionView(captured: StoreSnapshot, connection: UUID, current: StoreSnapshot,
                                 session: UUID, selection: LocalStoreSelection, database: Database) throws {
    guard captured.store == selection.store, captured.session == session,
          current.store == captured.store, current.session == captured.session,
          connection == database.incarnation else { throw StorageError.wrongContext }
    guard current.through == captured.through, current.viewEpoch == captured.viewEpoch,
          current.presentationEpoch == captured.presentationEpoch else { throw StorageError.staleCapture }
    try database.validateHeader(store: selection.store, descriptor: selection.descriptor)
    try database.checkCurrentView(captured)
}
private func projectionRelation(birth: NoteBirth, state: ProjectionStateReferenceV1,
                                snapshot: StoreSnapshot) throws -> ProjectionCurrentRelation {
    guard let cell = snapshot.notes.first(where: { $0.birth == birth }) else { return .absent }
    let current: ProjectionStateReferenceV1
    switch cell.provenance {
    case .revision: current = .revision(cell.revision)
    case .derived(let derived): current = .derived(derived)
    case .automatic(let source): current = .automatic(source)
    }
    return try sameLogicalSource(current, state) ? .matchesCurrent : .differentCurrent
}
private func sameLogicalSource(_ lhs: ProjectionStateReferenceV1, _ rhs: ProjectionStateReferenceV1) throws -> Bool {
    switch (lhs, rhs) {
    case (.revision(let a), .revision(let b)): a.id == b.id
    case (.derived(let a), .derived(let b)): a.state == b.state
    case (.automatic(let a), .automatic(let b)): try a.birth == b.birth && a.key == b.key && stored(a.revision).id == stored(b.revision).id
    default: false
    }
}
private func stored(_ ref: OperationReference) throws -> StoredOperationReferenceV1 {
    guard case .external(let locator, let index, let id) = ref else { throw CanonicalEncodingError.invalidReference }
    return .init(locator: locator, index: index, id: id)
}
