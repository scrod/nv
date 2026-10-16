import Foundation
import NVStorageCore

/// Store-issued capture of a note's required private projection descriptions.
public struct ProjectionObservationState: Sendable {
    public let birth: NoteBirth
    public let generation: Int64
    public let value: ProjectionObservationsV1?
    fileprivate let store: LocalStoreID
    fileprivate let session: UUID
    fileprivate init(birth: NoteBirth, generation: Int64, value: ProjectionObservationsV1?, store: LocalStoreID, session: UUID) {
        self.birth = birth; self.generation = generation; self.value = value; self.store = store; self.session = session
    }
}

/// History-checked exact output prepared for one guarded private intent transaction.
public struct PreparedProjectionIntent: Sendable {
    public let output: ProjectionOutputV1
    public let bytes: [UInt8]
    fileprivate let snapshot: StoreSnapshot
    fileprivate let previous: ProjectionObservationState
    fileprivate let association: LocalAssociationV1
    fileprivate let associationGeneration: Int64
    fileprivate let connection: UUID
    fileprivate init(output: ProjectionOutputV1, bytes: [UInt8], snapshot: StoreSnapshot, previous: ProjectionObservationState,
                     association: LocalAssociationV1, associationGeneration: Int64, connection: UUID) {
        self.output = output; self.bytes = bytes; self.snapshot = snapshot; self.previous = previous; self.association = association
        self.associationGeneration = associationGeneration; self.connection = connection
    }
}

/// Frozen portable description and its exact sealed bytes, retained by the caller through retry.
public struct ProjectionDescriptionHandle: Sendable {
    public let object: SegmentLocator
    public let binding: ProjectionBindingV1
    fileprivate let bytes: [UInt8]
    fileprivate let store: LocalStoreID
    fileprivate let session: UUID
    fileprivate init(object: SegmentLocator, binding: ProjectionBindingV1, bytes: [UInt8], store: LocalStoreID, session: UUID) {
        self.object = object; self.binding = binding; self.bytes = bytes; self.store = store; self.session = session
    }
}

/// Durable acceptance of one exact portable description by its issuing store.
public struct AcceptedProjectionDescriptionReceipt: Sendable {
    public let object: SegmentLocator
    public let binding: ProjectionBindingV1
    public let store: LocalStoreID
    public let sequence: Int64
    fileprivate init(handle: ProjectionDescriptionHandle, sequence: Int64) {
        object = handle.object; binding = handle.binding; store = handle.store; self.sequence = sequence
    }
}

public enum ProjectionDescriptionOutcome: Sendable {
    case accepted(AcceptedProjectionDescriptionReceipt)
    case pending(ProjectionDescriptionHandle, StorageError)
}

/// Exact durable frozen output authorized for an exclusive first installation.
public struct PreparedProjectionCreation: Sendable {
    public let output: ProjectionOutputV1
    let attempt: UUID
    let bytes: [UInt8]
    let value: PlaintextNoteValue
    let association: LocalAssociationV1
    fileprivate let associationGeneration: Int64
    fileprivate let snapshot: StoreSnapshot
    fileprivate let connection: UUID
    fileprivate init(output: ProjectionOutputV1, bytes: [UInt8], value: PlaintextNoteValue,
                     association: LocalAssociationV1, associationGeneration: Int64,
                     snapshot: StoreSnapshot, connection: UUID) {
        self.output = output; attempt = UUID(); self.bytes = bytes; self.value = value; self.association = association
        self.associationGeneration = associationGeneration; self.snapshot = snapshot; self.connection = connection
    }
}

/// Exact durable old and new contents for replacing one accepted projection at its current name.
public struct PreparedProjectionReplacement: Sendable {
    public let output: ProjectionOutputV1
    let attempt: UUID
    let bytes: [UInt8]
    let value: PlaintextNoteValue
    let source: AcceptedProjectionV1
    let sourceBytes: [UInt8]
    let association: LocalAssociationV1
    fileprivate let associationGeneration: Int64
    fileprivate let snapshot: StoreSnapshot
    fileprivate let connection: UUID
    fileprivate init(output: ProjectionOutputV1, bytes: [UInt8], value: PlaintextNoteValue,
                     source: AcceptedProjectionV1, sourceBytes: [UInt8], association: LocalAssociationV1,
                     associationGeneration: Int64, snapshot: StoreSnapshot, connection: UUID) {
        self.output = output; attempt = UUID(); self.bytes = bytes; self.value = value
        self.source = source; self.sourceBytes = sourceBytes; self.association = association
        self.associationGeneration = associationGeneration; self.snapshot = snapshot; self.connection = connection
    }
}

/// Exact durable source and output for a frozen transition to a different filename.
struct PreparedProjectionRelocation: Sendable {
    let output: ProjectionOutputV1
    let attempt: UUID
    let bytes: [UInt8]
    let value: PlaintextNoteValue
    let source: AcceptedProjectionV1
    let sourceBytes: [UInt8]
    let association: LocalAssociationV1
    fileprivate let associationGeneration: Int64
    fileprivate let snapshot: StoreSnapshot
    fileprivate let connection: UUID
    fileprivate init(output: ProjectionOutputV1, bytes: [UInt8], value: PlaintextNoteValue,
                     source: AcceptedProjectionV1, sourceBytes: [UInt8], association: LocalAssociationV1,
                     associationGeneration: Int64, snapshot: StoreSnapshot, connection: UUID) {
        self.output = output; attempt = UUID(); self.bytes = bytes; self.value = value
        self.source = source; self.sourceBytes = sourceBytes; self.association = association
        self.associationGeneration = associationGeneration; self.snapshot = snapshot; self.connection = connection
    }
}

/// Accepted source contents checked while the captured local Delete is still applicable.
struct PreparedProjectionDeletion: Sendable {
    let birth: NoteBirth
    let source: AcceptedProjectionV1
    let bytes: [UInt8]
    let association: LocalAssociationV1
    fileprivate let capture: CapturedActionGroup
    fileprivate let snapshot: StoreSnapshot
    fileprivate let observations: ProjectionObservationState
    fileprivate let associationGeneration: Int64
    fileprivate let connection: UUID
    fileprivate init(birth: NoteBirth, source: AcceptedProjectionV1, bytes: [UInt8], association: LocalAssociationV1,
                     capture: CapturedActionGroup, snapshot: StoreSnapshot, observations: ProjectionObservationState,
                     associationGeneration: Int64, connection: UUID) {
        self.birth = birth; self.source = source; self.bytes = bytes; self.association = association
        self.capture = capture; self.snapshot = snapshot; self.observations = observations
        self.associationGeneration = associationGeneration; self.connection = connection
    }
}

/// Original live file capture paired with its exact locally committed Delete.
struct AuthorizedProjectionDeletion: Sendable {
    let original: CapturedProjectionDeleteSource
    let deletion: StoredActionReferenceV1
    fileprivate let receipt: AcceptedHistoryReceipt
    fileprivate init(original: CapturedProjectionDeleteSource, deletion: StoredActionReferenceV1, receipt: AcceptedHistoryReceipt) {
        self.original = original; self.deletion = deletion; self.receipt = receipt
    }
}

/// Exact committed candidate paired with its original live deletion permission.
struct ReservedProjectionSource: Sendable {
    let record: ProjectionSourceAttemptV1
    let authorization: AuthorizedProjectionDeletion
    fileprivate init(record: ProjectionSourceAttemptV1, authorization: AuthorizedProjectionDeletion) {
        self.record = record; self.authorization = authorization
    }
}

/// Historical comparison contents checked in the recovering store's live connection.
struct ProjectionSourceRecoveryInput: Sendable {
    let record: ProjectionSourceAttemptV1
    let bytes: [UInt8]
    fileprivate let store: LocalStoreID
    fileprivate let session, connection: UUID
    fileprivate init(record: ProjectionSourceAttemptV1, bytes: [UInt8], store: LocalStoreID, session: UUID, connection: UUID) {
        self.record = record; self.bytes = bytes; self.store = store; self.session = session; self.connection = connection
    }
    func checkInspection(_ other: Self) throws {
        guard record == other.record, store == other.store, session == other.session, connection == other.connection else {
            throw StorageError.wrongContext
        }
    }
}

/// A durably recorded backup candidate and its still-owned frozen replacement input.
struct ReservedProjectionReplacement: Sendable {
    let record: ProjectionReplacementAttemptV1
    let input: PreparedProjectionReplacement
    fileprivate init(record: ProjectionReplacementAttemptV1, input: PreparedProjectionReplacement) {
        self.record = record; self.input = input
    }
}

/// One committed relocation candidate and its exact still-live authoring context.
struct ReservedProjectionRelocation: Sendable {
    let record: ProjectionReplacementAttemptV1
    let input: PreparedProjectionRelocation
    fileprivate init(record: ProjectionReplacementAttemptV1, input: PreparedProjectionRelocation) {
        self.record = record; self.input = input
    }
}

/// Retained source/output bytes for read-only inspection of a pending relocation.
struct ProjectionRelocationRecoveryInput: Sendable {
    let record: ProjectionReplacementAttemptV1
    let sourceBytes, outputBytes: [UInt8]
    fileprivate let store: LocalStoreID
    fileprivate let session, connection: UUID
    fileprivate init(record: ProjectionReplacementAttemptV1, sourceBytes: [UInt8], outputBytes: [UInt8],
                     store: LocalStoreID, session: UUID, connection: UUID) {
        self.record = record; self.sourceBytes = sourceBytes; self.outputBytes = outputBytes
        self.store = store; self.session = session; self.connection = connection
    }
    func checkContext(_ other: Self) throws {
        guard record == other.record, store == other.store, session == other.session, connection == other.connection else {
            throw StorageError.wrongContext
        }
    }
}

/// Retained replacement inputs checked in the recovering store's current connection.
struct ProjectionReplacementRecoveryInput: Sendable {
    let record: ProjectionReplacementAttemptV1
    let sourceBytes, outputBytes: [UInt8]
    fileprivate let store: LocalStoreID
    fileprivate let session, connection: UUID
    fileprivate init(record: ProjectionReplacementAttemptV1, sourceBytes: [UInt8], outputBytes: [UInt8],
                     store: LocalStoreID, session: UUID, connection: UUID) {
        self.record = record; self.sourceBytes = sourceBytes; self.outputBytes = outputBytes
        self.store = store; self.session = session; self.connection = connection
    }

    /// Matches the exact retained attempt within its issuing session and connection.
    func checkContext(_ other: ProjectionReplacementRecoveryInput) throws {
        guard record == other.record, store == other.store, session == other.session, connection == other.connection else {
            throw StorageError.wrongContext
        }
    }
}

extension LocalStoreSession {
    /// Checks source history and captures its ownership before the local Delete is admitted.
    func prepareProjectionDeletion(capture: CapturedActionGroup, birth: NoteBirth,
                                   observations state: ProjectionObservationState,
                                   basedOn snapshot: StoreSnapshot) async throws -> PreparedProjectionDeletion {
        guard !closed, !quiescing else { throw StorageError.closed }
        guard selection.descriptor.keyID == nil else { throw StorageError.unsupported }
        guard capture.session == incarnation, capture.store == selection.store,
              snapshot.session == incarnation, snapshot.store == selection.store,
              state.session == incarnation, state.store == selection.store, state.birth == birth else { throw StorageError.wrongContext }
        guard capture.through == snapshot.through, capture.viewEpoch == snapshot.viewEpoch,
              capture.presentationEpoch == snapshot.presentationEpoch, capture.context == snapshot.context,
              capture.before[birth] == snapshot.notes.first(where: { $0.birth == birth }),
              capture.changes.contains(where: { if case .delete(let change) = $0 { change.birth == birth } else { false } }),
              let source = state.value?.accepted, state.value?.frozen == nil else { throw StorageError.staleCapture }
        let selection = selection, protection = protection
        let (association, generation, connection) = try await lane.perform { db in
            try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
            try db.checkCurrentView(snapshot); try db.validateCapture(capture, selection: selection, protection: protection)
            try db.checkProjectionCapture(state, selection: selection)
            guard let row = try db.privateGroup("association") else { throw StorageError.incomplete }
            let association = try db.decodedAssociation(row, selection: selection)
            guard association.id == state.value?.association else { throw StorageError.staleCapture }
            return try (association, row[0].number, db.incarnation)
        }
        let (_, bytes) = try await readFrozenProjection(source.output, observations: state, basedOn: snapshot)
        let input = PreparedProjectionDeletion(birth: birth, source: source, bytes: bytes, association: association,
            capture: capture, snapshot: snapshot, observations: state, associationGeneration: generation, connection: connection)
        try await checkProjectionDeletionCapture(input)
        return input
    }

    /// Rechecks the exact pre-admission model and association at the rooted capture boundary.
    func checkProjectionDeletionCapture(_ input: PreparedProjectionDeletion) async throws {
        guard !closed, !quiescing else { throw StorageError.closed }
        guard input.snapshot.session == incarnation, input.snapshot.store == selection.store else { throw StorageError.wrongContext }
        let selection = selection, protection = protection
        try await lane.perform { db in
            try db.checkProjectionDeletionOwner(input, selection: selection)
            try db.checkCurrentView(input.snapshot)
            try db.validateCapture(input.capture, selection: selection, protection: protection)
        }
        guard !closed, !quiescing else { throw StorageError.closed }
    }

    /// Issues live removal evidence only for the original capture's exact accepted local command.
    func authorizeProjectionDeletion(_ original: CapturedProjectionDeleteSource,
                                     committed receipt: AcceptedHistoryReceipt) async throws -> AuthorizedProjectionDeletion {
        let input = original.input
        guard receipt.belongs(to: input.capture) else { throw StorageError.wrongContext }
        let selection = selection, protection = protection
        guard !closed, !quiescing else { throw StorageError.closed }
        guard input.snapshot.session == incarnation, input.snapshot.store == selection.store else { throw StorageError.wrongContext }
        let deletion = try await lane.verifying(.history(receipt.sequence)) { [lane] in
            let envelope = try await CheckedEnvelopeRecords.read(source: receipt.object.segmentID.bytes, through: receipt.sequence,
                attempt: UUID(), lane: lane, selection: selection, protection: protection)
            guard envelope.locator == receipt.object, envelope.sequence == receipt.sequence,
                  envelope.actions.contains(where: { $0.id == input.capture.action }) else { throw StorageError.integrity }
            return try await lane.perform { db in
                try db.checkProjectionDeletionOwner(input, selection: selection)
                guard let accepted = try db.existingCapture(input.capture, selection: selection, protection: protection),
                      accepted.0 <= receipt.sequence else { throw StorageError.integrity }
                return try db.actionOccurrence(input.capture.action)
            }
        }
        let authorized = AuthorizedProjectionDeletion(original: original, deletion: deletion, receipt: receipt)
        try await checkProjectionDeletion(authorized)
        return authorized
    }

    /// Keeps physical permission confined to the original live owner and unchanged source relationship.
    func checkProjectionDeletion(_ authorized: AuthorizedProjectionDeletion) async throws {
        guard !closed, !quiescing else { throw StorageError.closed }
        let input = authorized.original.input, selection = selection
        guard input.snapshot.session == incarnation, input.snapshot.store == selection.store,
              authorized.receipt.belongs(to: input.capture) else { throw StorageError.wrongContext }
        try await lane.perform { db in
            try db.checkOriginalProjectionDeletion(authorized, selection: selection)
        }
        guard !closed, !quiescing else { throw StorageError.closed }
    }

    /// Commits the protected recovery location and original inputs before physical capture.
    func reserveProjectionSource(_ authorized: AuthorizedProjectionDeletion) async throws -> ReservedProjectionSource {
        try await checkProjectionDeletion(authorized)
        let input = authorized.original.input, selection = selection
        let id = UUID().uuid
        let record = try ProjectionSourceAttemptV1(profile: .plaintextFiles,
            scope: .init(collection: selection.descriptor.collection, store: selection.store, descriptor: selection.descriptor.descriptorID),
            association: input.association.id,
            attempt: .init(bytes: [id.0,id.1,id.2,id.3,id.4,id.5,id.6,id.7,id.8,id.9,id.10,id.11,id.12,id.13,id.14,id.15]),
            deletion: authorized.deletion, source: input.source, root: input.association.bookmark,
            observation: authorized.original.capturedObservation)
        let bytes = try record.encodedV1(), sourceKey = sourceAttemptGroup(input.birth)
        cancelMaintenance()
        try await lane.perform { db in
            try db.transaction {
                try db.checkOriginalProjectionDeletion(authorized, selection: selection)
                guard try db.privateGroup(sourceKey) == nil else { throw StorageError.busy }
                try db.run("INSERT INTO private_groups VALUES(?,1,1,?)", [.blob(Array(sourceKey.utf8)), .blob(bytes)])
            }
        }
        guard !closed, !quiescing else { throw StorageError.closed }
        return ReservedProjectionSource(record: record, authorization: authorized)
    }

    /// Supplies the retained location for fresh inspection after interruption.
    func pendingProjectionSource(for birth: NoteBirth) async throws -> ProjectionSourceAttemptV1? {
        guard !closed else { throw StorageError.closed }
        let selection = selection
        return try await lane.perform { db in
            try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
            guard let row = try db.privateGroup(sourceAttemptGroup(birth)) else { return nil }
            return try db.decodedSourceAttempt(row, birth: birth, selection: selection)
        }
    }

    /// Rechecks both live authority and exact committed candidate before physical use.
    func checkProjectionSourceReservation(_ reserved: ReservedProjectionSource) async throws {
        try await checkProjectionDeletion(reserved.authorization)
        let selection = selection, bytes = try reserved.record.encodedV1(), key = sourceAttemptGroup(reserved.record.birth)
        try await lane.perform { db in
            try db.checkOriginalProjectionDeletion(reserved.authorization, selection: selection)
            guard try db.privateGroup(key) == [.integer(1), .integer(1), .blob(bytes)] else { throw StorageError.staleCapture }
        }
        guard !closed, !quiescing else { throw StorageError.closed }
    }

    /// Retires an attempt that created no protected directory, preserving source byte owners.
    func retireProjectionSource(_ proof: UncapturedProjectionSource) async throws {
        let reserved = proof.reserved
        try await checkProjectionSourceReservation(reserved)
        let selection = selection, key = sourceAttemptGroup(reserved.record.birth), bytes = try reserved.record.encodedV1()
        cancelMaintenance()
        try await lane.perform { db in
            try db.transaction {
                try db.checkOriginalProjectionDeletion(reserved.authorization, selection: selection)
                guard try db.privateGroup(key) == [.integer(1), .integer(1), .blob(bytes)] else { throw StorageError.staleCapture }
                try db.run("DELETE FROM private_groups WHERE group_key=?", [.blob(Array(key.utf8))])
            }
        }
    }

    /// Reconstructs comparison bytes for inspection while keeping the original grant session-bound.
    func prepareProjectionSourceRecovery(for birth: NoteBirth) async throws -> ProjectionSourceRecoveryInput {
        guard !closed, !quiescing else { throw StorageError.closed }
        guard let record = try await pendingProjectionSource(for: birth) else { throw StorageError.incomplete }
        let state = try await projectionObservations(for: birth), snapshot = try await snapshot()
        guard state.value?.accepted == record.source else { throw StorageError.staleCapture }
        let connection = try await lane.perform { $0.incarnation }
        let (_, bytes) = try await readFrozenProjection(record.source.output, observations: state, basedOn: snapshot)
        let input = ProjectionSourceRecoveryInput(record: record, bytes: bytes, store: selection.store, session: incarnation, connection: connection)
        try await checkProjectionSourceRecovery(input)
        return input
    }

    func checkProjectionSourceRecovery(_ input: ProjectionSourceRecoveryInput) async throws {
        guard !closed, !quiescing else { throw StorageError.closed }
        guard input.store == selection.store, input.session == incarnation else { throw StorageError.wrongContext }
        let selection = selection
        try await lane.perform { db in
            try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
            guard db.incarnation == input.connection else { throw StorageError.wrongContext }
            guard let row = try db.privateGroup(sourceAttemptGroup(input.record.birth)),
                  try db.decodedSourceAttempt(row, birth: input.record.birth, selection: selection) == input.record else {
                throw StorageError.staleCapture
            }
        }
        guard !closed, !quiescing else { throw StorageError.closed }
    }

    /// Reconstructs the exact frozen output from accepted history and its private byte owners.
    public func prepareProjectionCreation(observations state: ProjectionObservationState,
                                          basedOn snapshot: StoreSnapshot) async throws -> PreparedProjectionCreation {
        guard state.value?.frozen?.source == nil, state.value?.accepted == nil else { throw StorageError.wrongContext }
        let (frozen, association, generation, connection) = try await captureFrozenProjection(state, basedOn: snapshot)
        let (value, bytes) = try await readFrozenProjection(frozen.output, observations: state, basedOn: snapshot)
        let prepared = PreparedProjectionCreation(output: frozen.output, bytes: bytes, value: value,
            association: association, associationGeneration: generation, snapshot: snapshot, connection: connection)
        try await checkProjectionCreation(prepared)
        return prepared
    }

    /// Binds both sides to retained history and the same frozen, live file relationship.
    public func prepareProjectionReplacement(observations state: ProjectionObservationState,
                                             basedOn snapshot: StoreSnapshot) async throws -> PreparedProjectionReplacement {
        let (frozen, association, generation, connection) = try await captureFrozenProjection(state, basedOn: snapshot)
        guard let source = frozen.source, source == state.value?.accepted,
              source.output.binding.descriptor.filename == frozen.output.binding.descriptor.filename else {
            throw StorageError.wrongContext
        }
        let (value, bytes) = try await readFrozenProjection(frozen.output, observations: state, basedOn: snapshot)
        let (_, sourceBytes) = try await readFrozenProjection(source.output, observations: state, basedOn: snapshot)
        let prepared = PreparedProjectionReplacement(output: frozen.output, bytes: bytes, value: value,
            source: source, sourceBytes: sourceBytes, association: association,
            associationGeneration: generation, snapshot: snapshot, connection: connection)
        try await checkProjectionReplacement(prepared)
        return prepared
    }

    /// Issues a different-name transition after checking both exact historical values.
    func prepareProjectionRelocation(observations state: ProjectionObservationState,
                                     basedOn snapshot: StoreSnapshot) async throws -> PreparedProjectionRelocation {
        let (frozen, association, generation, connection) = try await captureFrozenProjection(state, basedOn: snapshot)
        guard let source = frozen.source, source == state.value?.accepted,
              source.output.binding.descriptor.filename != frozen.output.binding.descriptor.filename else {
            throw StorageError.wrongContext
        }
        let (value, bytes) = try await readFrozenProjection(frozen.output, observations: state, basedOn: snapshot)
        let original = try await readFrozenProjection(source.output, observations: state, basedOn: snapshot)
        let prepared = PreparedProjectionRelocation(output: frozen.output, bytes: bytes, value: value,
            source: source, sourceBytes: original.1, association: association, associationGeneration: generation,
            snapshot: snapshot, connection: connection)
        try await checkProjectionRelocation(prepared)
        return prepared
    }

    /// Records a fresh exclusive candidate before the source can move.
    func reserveProjectionRelocation(_ input: PreparedProjectionRelocation, root: PassivePlatformRecordV1,
                                     source: PassivePlatformRecordV1) async throws -> ReservedProjectionRelocation {
        try await checkProjectionRelocation(input)
        guard root == input.association.bookmark, source == input.source.physical else { throw StorageError.wrongContext }
        let selection = selection, id = UUID().uuid
        let record = try ProjectionReplacementAttemptV1(profile: .plaintextFiles,
            scope: .init(collection: selection.descriptor.collection, store: selection.store, descriptor: selection.descriptor.descriptorID),
            association: input.association.id,
            attempt: .init(bytes: [id.0,id.1,id.2,id.3,id.4,id.5,id.6,id.7,id.8,id.9,id.10,id.11,id.12,id.13,id.14,id.15]),
            transition: .init(output: input.output, source: input.source), root: root, source: source)
        let bytes = try record.encodedV1(), key = replacementAttemptGroup(input.output.binding.birth)
        cancelMaintenance()
        try await lane.perform { db in
            try db.transaction {
                try db.checkFrozenProjection(output: input.output, source: input.source, association: input.association,
                    associationGeneration: input.associationGeneration, snapshot: input.snapshot, connection: input.connection, selection: selection)
                guard try db.privateGroup(key) == nil else { throw StorageError.busy }
                try db.run("INSERT INTO private_groups VALUES(?,1,1,?)", [.blob(Array(key.utf8)), .blob(bytes)])
            }
        }
        guard !closed, !quiescing else { throw StorageError.closed }
        return ReservedProjectionRelocation(record: record, input: input)
    }

    /// Records the candidate before the rooted adapter enters a replacement accessor.
    func reserveProjectionReplacement(_ input: PreparedProjectionReplacement, root: PassivePlatformRecordV1,
                                      source: PassivePlatformRecordV1) async throws -> ReservedProjectionReplacement {
        try await checkProjectionReplacement(input)
        let selection = selection
        let id = UUID().uuid
        let record = try ProjectionReplacementAttemptV1(profile: .plaintextFiles,
            scope: .init(collection: selection.descriptor.collection, store: selection.store, descriptor: selection.descriptor.descriptorID),
            association: input.association.id,
            attempt: .init(bytes: [id.0,id.1,id.2,id.3,id.4,id.5,id.6,id.7,id.8,id.9,id.10,id.11,id.12,id.13,id.14,id.15]),
            transition: .init(output: input.output, source: input.source), root: root, source: source)
        let bytes = try record.encodedV1(), key = replacementAttemptGroup(input.output.binding.birth)
        cancelMaintenance()
        try await lane.perform { db in
            try db.transaction {
                try db.checkFrozenProjection(output: input.output, source: input.source, association: input.association,
                    associationGeneration: input.associationGeneration, snapshot: input.snapshot, connection: input.connection, selection: selection)
                guard try db.privateGroup(key) == nil else { throw StorageError.busy }
                try db.run("INSERT INTO private_groups VALUES(?,1,1,?)", [.blob(Array(key.utf8)), .blob(bytes)])
            }
        }
        guard !closed, !quiescing else { throw StorageError.closed }
        return ReservedProjectionReplacement(record: record, input: input)
    }

    /// Supplies retained candidate locations for a fresh rooted recovery inspection.
    public func pendingProjectionReplacement(for birth: NoteBirth) async throws -> ProjectionReplacementAttemptV1? {
        guard !closed else { throw StorageError.closed }
        let selection = selection
        return try await lane.perform { db in
            try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
            guard let row = try db.privateGroup(replacementAttemptGroup(birth)) else { return nil }
            return try db.decodedReplacementAttempt(row, birth: birth, selection: selection)
        }
    }

    /// Reconstructs historical comparison bytes even when a later Delete has removed the live note.
    func prepareProjectionReplacementRecovery(for birth: NoteBirth) async throws -> ProjectionReplacementRecoveryInput {
        guard !closed, !quiescing else { throw StorageError.closed }
        guard let record = try await pendingProjectionReplacement(for: birth),
              let source = record.transition.source else { throw StorageError.incomplete }
        guard record.operation == .replacement else { throw StorageError.wrongContext }
        let state = try await projectionObservations(for: birth), snapshot = try await snapshot()
        guard state.value?.frozen == record.transition else { throw StorageError.staleCapture }
        let connection = try await lane.perform { $0.incarnation }
        let (_, outputBytes) = try await readFrozenProjection(record.transition.output, observations: state, basedOn: snapshot)
        let (_, sourceBytes) = try await readFrozenProjection(source.output, observations: state, basedOn: snapshot)
        let input = ProjectionReplacementRecoveryInput(record: record, sourceBytes: sourceBytes,
            outputBytes: outputBytes, store: selection.store, session: incarnation, connection: connection)
        try await checkProjectionReplacementRecovery(input)
        return input
    }

    /// Checks exact retained ownership while allowing later note edits and deletion to remain independent.
    func checkProjectionReplacementRecovery(_ input: ProjectionReplacementRecoveryInput) async throws {
        guard !closed, !quiescing else { throw StorageError.closed }
        guard input.session == incarnation, input.store == selection.store, input.record.operation == .replacement else { throw StorageError.wrongContext }
        let selection = selection, birth = input.record.transition.output.binding.birth
        try await lane.perform { db in
            try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
            guard db.incarnation == input.connection else { throw StorageError.wrongContext }
            guard let row = try db.privateGroup(replacementAttemptGroup(birth)),
                  try db.decodedReplacementAttempt(row, birth: birth, selection: selection) == input.record else {
                throw StorageError.staleCapture
            }
        }
        guard !closed, !quiescing else { throw StorageError.closed }
    }

    /// Checks the committed candidate and frozen input immediately before physical use.
    func checkProjectionReplacementReservation(_ reserved: ReservedProjectionReplacement) async throws {
        try await checkProjectionReplacement(reserved.input)
        let selection = selection, key = replacementAttemptGroup(reserved.input.output.binding.birth)
        let bytes = try reserved.record.encodedV1()
        try await lane.perform { db in
            try db.checkFrozenProjection(output: reserved.input.output, source: reserved.input.source, association: reserved.input.association,
                associationGeneration: reserved.input.associationGeneration, snapshot: reserved.input.snapshot,
                connection: reserved.input.connection, selection: selection)
            guard try db.privateGroup(key) == [.integer(1), .integer(1), .blob(bytes)] else { throw StorageError.staleCapture }
        }
        guard !closed, !quiescing else { throw StorageError.closed }
    }

    /// Checks exact committed ownership before another relocation stage proceeds.
    func checkProjectionRelocationReservation(_ reserved: ReservedProjectionRelocation) async throws {
        try await checkProjectionRelocation(reserved.input)
        let input = reserved.input, selection = selection
        let key = replacementAttemptGroup(input.output.binding.birth), bytes = try reserved.record.encodedV1()
        try await lane.perform { db in
            try db.checkFrozenProjection(output: input.output, source: input.source, association: input.association,
                associationGeneration: input.associationGeneration, snapshot: input.snapshot, connection: input.connection, selection: selection)
            guard try db.privateGroup(key) == [.integer(1), .integer(1), .blob(bytes)] else { throw StorageError.staleCapture }
        }
        guard !closed, !quiescing else { throw StorageError.closed }
    }

    /// Reconstructs all three inspection locations through their retained frozen owner.
    func prepareProjectionRelocationRecovery(for birth: NoteBirth) async throws -> ProjectionRelocationRecoveryInput {
        guard !closed, !quiescing else { throw StorageError.closed }
        guard let record = try await pendingProjectionReplacement(for: birth),
              let source = record.transition.source else { throw StorageError.incomplete }
        guard record.operation == .relocation else { throw StorageError.wrongContext }
        let state = try await projectionObservations(for: birth), snapshot = try await snapshot()
        guard state.value?.frozen == record.transition else { throw StorageError.staleCapture }
        let connection = try await lane.perform { $0.incarnation }
        let output = try await readFrozenProjection(record.transition.output, observations: state, basedOn: snapshot)
        let original = try await readFrozenProjection(source.output, observations: state, basedOn: snapshot)
        let input = ProjectionRelocationRecoveryInput(record: record, sourceBytes: original.1, outputBytes: output.1,
            store: selection.store, session: incarnation, connection: connection)
        try await checkProjectionRelocationRecovery(input)
        return input
    }

    func checkProjectionRelocationRecovery(_ input: ProjectionRelocationRecoveryInput) async throws {
        guard !closed, !quiescing else { throw StorageError.closed }
        guard input.session == incarnation, input.store == selection.store, input.record.operation == .relocation else {
            throw StorageError.wrongContext
        }
        let selection = selection, birth = input.record.transition.output.binding.birth
        try await lane.perform { db in
            try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
            guard db.incarnation == input.connection else { throw StorageError.wrongContext }
            guard let row = try db.privateGroup(replacementAttemptGroup(birth)),
                  try db.decodedReplacementAttempt(row, birth: birth, selection: selection) == input.record else { throw StorageError.staleCapture }
        }
        guard !closed, !quiescing else { throw StorageError.closed }
    }

    /// Burns only a live candidate whose source was never moved by this operation.
    func retireProjectionRelocation(_ proof: UncapturedProjectionRelocation) async throws {
        guard !closed, !quiescing else { throw StorageError.closed }
        let reserved = proof.reserved, input = reserved.input, selection = selection
        guard input.snapshot.store == selection.store, input.snapshot.session == incarnation else { throw StorageError.wrongContext }
        let key = replacementAttemptGroup(input.output.binding.birth), bytes = try reserved.record.encodedV1()
        cancelMaintenance()
        try await lane.perform { db in
            try db.transaction {
                try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
                guard db.incarnation == input.connection else { throw StorageError.wrongContext }
                guard try db.privateGroup(key) == [.integer(1), .integer(1), .blob(bytes)] else { throw StorageError.staleCapture }
                try db.run("DELETE FROM private_groups WHERE group_key=?", [.blob(Array(key.utf8))])
            }
        }
    }

    /// Releases only a returned no-effect candidate; the next attempt receives a fresh random name.
    func retireProjectionReplacement(_ proof: UninstalledProjectionReplacement) async throws {
        guard !closed, !quiescing else { throw StorageError.closed }
        let reserved = proof.reserved, input = reserved.input, selection = selection
        guard input.snapshot.store == selection.store, input.snapshot.session == incarnation else { throw StorageError.wrongContext }
        let key = replacementAttemptGroup(input.output.binding.birth), bytes = try reserved.record.encodedV1()
        cancelMaintenance()
        try await lane.perform { db in
            try db.transaction {
                try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
                guard db.incarnation == input.connection else { throw StorageError.wrongContext }
                guard try db.privateGroup(key) == [.integer(1), .integer(1), .blob(bytes)] else { throw StorageError.staleCapture }
                try db.run("DELETE FROM private_groups WHERE group_key=?", [.blob(Array(key.utf8))])
            }
        }
    }

    private func captureFrozenProjection(_ state: ProjectionObservationState, basedOn snapshot: StoreSnapshot) async throws
        -> (IntendedProjectionV1, LocalAssociationV1, Int64, UUID) {
        guard !closed, !quiescing else { throw StorageError.closed }
        guard state.store == selection.store, state.session == incarnation,
              snapshot.store == selection.store, snapshot.session == incarnation else { throw StorageError.wrongContext }
        guard selection.descriptor.keyID == nil else { throw StorageError.unsupported }
        guard let frozen = state.value?.frozen else { throw StorageError.incomplete }
        guard snapshot.notes.contains(where: { $0.birth == state.birth }) else { throw StorageError.staleCapture }
        let selection = selection
        let context = try await lane.perform { db in
            try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
            try db.checkCurrentView(snapshot); try db.checkProjectionCapture(state, selection: selection)
            guard let row = try db.privateGroup("association") else { throw StorageError.incomplete }
            let association = try db.decodedAssociation(row, selection: selection)
            guard association.id == state.value?.association else { throw StorageError.staleCapture }
            return try (association, row[0].number, db.incarnation)
        }
        return (frozen, context.0, context.1, context.2)
    }

    private func readFrozenProjection(_ output: ProjectionOutputV1, observations state: ProjectionObservationState,
                                      basedOn snapshot: StoreSnapshot) async throws -> (PlaintextNoteValue, [UInt8]) {
        let history: CheckedProjectionBindingHistory
        switch try await projectionHistory(for: output.binding, basedOn: snapshot) {
        case .checked(let checked): history = checked
        case .waiting, .blocked: throw StorageError.incomplete
        case .foreignCollection, .invalidClaim: throw StorageError.integrity
        }
        let value = try await projectionValue(fromBinding: history, basedOn: snapshot)
        let bytes: [UInt8]
        switch output.encoding {
        case .utf8: bytes = value.body.bytes
        case .captured: bytes = try await capturedProjectionBytes(output, observations: state)
        }
        guard try await lane.historyWork({ ProjectionBytesDigestV1.compute(bytes) }) == output.binding.descriptor.digest else {
            throw StorageError.integrity
        }
        return (value, bytes)
    }

    /// Keeps frozen B applicable while newer intended C remains independently owned.
    func checkProjectionCreation(_ prepared: PreparedProjectionCreation) async throws {
        try await checkFrozenProjection(output: prepared.output, source: nil, association: prepared.association,
            associationGeneration: prepared.associationGeneration, snapshot: prepared.snapshot, connection: prepared.connection)
    }

    func checkProjectionReplacement(_ prepared: PreparedProjectionReplacement) async throws {
        try await checkFrozenProjection(output: prepared.output, source: prepared.source, association: prepared.association,
            associationGeneration: prepared.associationGeneration, snapshot: prepared.snapshot, connection: prepared.connection)
    }

    func checkProjectionRelocation(_ prepared: PreparedProjectionRelocation) async throws {
        try await checkFrozenProjection(output: prepared.output, source: prepared.source, association: prepared.association,
            associationGeneration: prepared.associationGeneration, snapshot: prepared.snapshot, connection: prepared.connection)
    }

    private func checkFrozenProjection(output: ProjectionOutputV1, source: AcceptedProjectionV1?,
                                       association: LocalAssociationV1, associationGeneration: Int64,
                                       snapshot: StoreSnapshot, connection: UUID) async throws {
        guard !closed, !quiescing else { throw StorageError.closed }
        guard snapshot.store == selection.store, snapshot.session == incarnation else { throw StorageError.wrongContext }
        let selection = selection
        try await lane.perform { db in
            try db.checkFrozenProjection(output: output, source: source, association: association,
                associationGeneration: associationGeneration, snapshot: snapshot, connection: connection, selection: selection)
        }
    }

    /// Freezes one owned output's verified description under a uniquely reserved envelope address.
    public func prepareProjectionDescription(for output: ProjectionOutputV1, observations: ProjectionObservationState,
                                             basedOn snapshot: StoreSnapshot) async throws -> ProjectionDescriptionHandle {
        guard !closed, !quiescing else { throw StorageError.closed }
        guard selection.descriptor.keyID == nil else { throw StorageError.unsupported }
        _ = try await projectionBytes(for: output, observations: observations, basedOn: snapshot)
        guard !closed, !quiescing else { throw StorageError.closed }
        let (writer, sequence) = try reserveObjectAddress()
        let selection = selection, protection = protection, session = incarnation
        let dependencies = try await lane.perform { db in
            try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
            try db.checkCurrentView(snapshot)
            try db.checkProjectionCapture(observations, selection: selection)
            return try db.projectionDescriptionDependencies(output.binding, through: snapshot.through)
        }
        let handle = try await lane.prepare {
            let payload = try ChangesPayloadV1(dependencies: dependencies, operations: [], actions: [], projections: [output.binding])
            let bytes = try ObjectEnvelopeV1.seal(payload: payload.encodedV1(), kind: .changes,
                collection: selection.descriptor.collection, writer: writer, sequence: sequence, protection: protection)
            let opened = try ObjectEnvelopeV1.open(bytes, collection: selection.descriptor.collection, protection: protection)
            return ProjectionDescriptionHandle(object: opened.locator, binding: output.binding, bytes: bytes,
                store: selection.store, session: session)
        }
        let sealed = try await lane.perform { $0.work?.projectionDescriptionSealed }
        await sealed?()
        try await lane.perform { db in
            try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
            try db.checkCurrentView(snapshot)
            try db.checkProjectionCapture(observations, selection: selection)
        }
        guard !closed, !quiescing else { throw StorageError.closed }
        return handle
    }

    /// Retains and accepts the frozen envelope through the existing exact-byte receive path.
    public func persistProjectionDescription(_ handle: ProjectionDescriptionHandle) async throws -> ProjectionDescriptionOutcome {
        guard !closed, !quiescing else { throw StorageError.closed }
        guard handle.store == selection.store, handle.session == incarnation else { throw StorageError.wrongContext }
        do {
            switch try await receive(handle.bytes) {
            case .accepted(let sequence): return .accepted(.init(handle: handle, sequence: sequence))
            case .pendingValidation: return .pending(handle, .busy)
            case .waiting, .blocked, .retainedForAssembly: return .pending(handle, .incomplete)
            }
        } catch { return .pending(handle, classify(error)) }
    }

    public func projectionObservations(for birth: NoteBirth) async throws -> ProjectionObservationState {
        guard !closed else { throw StorageError.closed }
        let selection = selection, session = incarnation
        return try await lane.perform { db in
            try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
            let row = try db.privateGroup(projectionGroup(birth))
            return try ProjectionObservationState(birth: birth, generation: row?[0].number ?? 0,
                value: row.map { try db.decodedProjectionObservations($0, birth: birth, selection: selection) },
                store: selection.store, session: session)
        }
    }

    /// Reuses checked Current provenance and verifies its exact retained occurrences before preparing bytes.
    public func prepareProjectionIntent(for birth: NoteBirth, filename: ProjectionLeafNameV1,
                                        basedOn snapshot: StoreSnapshot,
                                        observations previous: ProjectionObservationState) async throws -> PreparedProjectionIntent {
        try await prepareProjectionIntent(for: birth, filename: filename, basedOn: snapshot,
            observations: previous, requestedEncoding: .utf8)
    }

    /// Captures the requested encoding's actual output, promoting unrepresentable text to UTF-8.
    public func prepareProjectionIntent(for birth: NoteBirth, filename: ProjectionLeafNameV1,
                                        basedOn snapshot: StoreSnapshot, observations previous: ProjectionObservationState,
                                        requestedEncoding: ProjectionEncodingV1) async throws -> PreparedProjectionIntent {
        guard !closed, !quiescing else { throw StorageError.closed }
        guard snapshot.store == selection.store, snapshot.session == incarnation,
              previous.store == selection.store, previous.session == incarnation, previous.birth == birth else { throw StorageError.wrongContext }
        guard selection.descriptor.keyID == nil else { throw StorageError.unsupported }
        guard let cell = snapshot.notes.first(where: { $0.birth == birth }) else { throw StorageError.incomplete }
        let selection = selection, protection = protection, lane = lane
        return try await lane.verifying(.history(snapshot.through)) {
            let (connection, association, generation) = try await lane.perform { db in
                try db.checkCurrentView(snapshot)
                try db.checkProjectionCapture(previous, selection: selection)
                guard let row = try db.privateGroup("association") else { throw StorageError.incomplete }
                let association = try db.decodedAssociation(row, selection: selection)
                if let previous = previous.value {
                    guard previous.association == association.id else { throw StorageError.staleCapture }
                }
                return try (db.incarnation, association, row[0].number)
            }
            let state: ProjectionStateReferenceV1
            switch cell.provenance {
            case .revision: state = .revision(cell.revision)
            case .derived(let derived): state = .derived(derived)
            case .automatic(let source): state = .automatic(source)
            }
            let text = try await lane.historyWork { PreparedProjectionTextV1.prepare(cell.value.body, requested: requestedEncoding) }
            let descriptor = try ProjectionDescriptorV1(profile: .plaintextFiles, filename: filename,
                format: .plaintext, digest: .compute(text.bytes))
            let binding = try ProjectionBindingV1(profile: .plaintextFiles, collection: selection.descriptor.collection,
                birth: birth, descriptor: descriptor, state: state)
            var operations: [OperationID: IdentifiedOperation] = [:]
            let attempt = UUID()
            for locator in binding.dependencies.entries {
                try Task.checkCancellation()
                let envelope = try await CheckedEnvelopeRecords.read(source: locator.segmentID.bytes, through: snapshot.through,
                    attempt: attempt, lane: lane, selection: selection, protection: protection)
                do {
                    guard envelope.locator == locator else { throw StorageError.integrity }
                    for ref in binding.occurrences where ref.locator == locator {
                        guard Int(ref.index.rawValue) < envelope.operations.count,
                              envelope.operations[Int(ref.index.rawValue)].id == ref.id else { throw StorageError.integrity }
                        operations[ref.id] = envelope.operations[Int(ref.index.rawValue)]
                    }
                } catch { try await lane.failRetainedRead(error) }
            }
            do {
                guard try binding.reconstructedValue(operations: operations) == cell.value else { throw StorageError.integrity }
            } catch { try await lane.failRetainedRead(error) }
            let old = max(previous.value?.accepted?.output.generation ?? 0, previous.value?.intended?.output.generation ?? 0)
            guard old < Int64.max else { throw StorageError.limit }
            let encoding: ProjectionTextEncodingV1 = text.encoding == .utf8 ? .utf8 : .captured(encoding: text.encoding, byteCount: UInt64(text.bytes.count))
            let result = try PreparedProjectionIntent(output: .init(generation: old + 1, encoding: encoding, binding: binding),
                bytes: text.bytes, snapshot: snapshot, previous: previous, association: association, associationGeneration: generation, connection: connection)
            try await lane.perform { try $0.checkProjectionIntent(result, selection: selection) }
            return result
        }
    }

    /// Commits the next intended output while preserving the exact accepted representation.
    public func retainProjectionIntent(_ prepared: PreparedProjectionIntent) async throws {
        guard !closed, !quiescing else { throw StorageError.closed }
        guard prepared.previous.store == selection.store, prepared.previous.session == incarnation else { throw StorageError.wrongContext }
        let selection = selection, previous = prepared.previous
        let value = try ProjectionObservationsV1(profile: selection.descriptor.keyID == nil ? .plaintextFiles : .encryptedSegments,
            scope: prepared.association.scope, association: prepared.association.id, birth: previous.birth,
            accepted: previous.value?.accepted,
            intended: .init(output: prepared.output, source: previous.value?.accepted), frozen: previous.value?.frozen)
        let bytes = try value.encodedV1()
        cancelMaintenance()
        try await lane.perform { db in
            try db.transaction {
                try db.checkProjectionIntent(prepared, selection: selection)
                try db.retainProjectionBytes(prepared)
                try db.replacePrivateGroup(projectionGroup(previous.birth), generation: previous.generation, codec: 1, bytes: bytes)
                try db.releaseSupersededProjectionBytes(previous.value, retaining: value)
            }
        }
    }

    /// Pins the exact latest transition independently of subsequent intended outputs.
    public func freezeProjectionIntent(observations state: ProjectionObservationState) async throws -> ProjectionObservationState {
        guard !closed, !quiescing else { throw StorageError.closed }
        guard state.store == selection.store, state.session == incarnation else { throw StorageError.wrongContext }
        let selection = selection, session = incarnation
        cancelMaintenance()
        return try await lane.perform { db in
            try db.transaction {
                try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
                try db.checkProjectionCapture(state, selection: selection)
                guard let value = state.value, let intended = value.intended else { throw StorageError.incomplete }
                guard let row = try db.privateGroup("association"),
                      try db.decodedAssociation(row, selection: selection).id == value.association else { throw StorageError.staleCapture }
                if let frozen = value.frozen {
                    guard frozen == intended else { throw StorageError.busy }
                    return state
                }
                let frozen = try ProjectionObservationsV1(profile: .plaintextFiles, scope: value.scope,
                    association: value.association, birth: value.birth, accepted: value.accepted, intended: intended, frozen: intended)
                try db.replacePrivateGroup(projectionGroup(state.birth), generation: state.generation, codec: 1, bytes: frozen.encodedV1())
                return ProjectionObservationState(birth: state.birth, generation: state.generation + 1,
                    value: frozen, store: selection.store, session: session)
            }
        }
    }

    /// Reads a retained encoded output through its exact current private owner.
    public func projectionBytes(for output: ProjectionOutputV1, observations: ProjectionObservationState,
                                basedOn snapshot: StoreSnapshot) async throws -> [UInt8] {
        guard !closed, !quiescing else { throw StorageError.closed }
        guard observations.store == selection.store, observations.session == incarnation,
              snapshot.store == selection.store, snapshot.session == incarnation else { throw StorageError.wrongContext }
        let owned = observations.value?.ownedOutputs ?? []
        guard owned.contains(output) else { throw StorageError.wrongContext }
        let selection = selection
        try await lane.perform { db in
            try db.checkCurrentView(snapshot)
            try db.checkProjectionCapture(observations, selection: selection)
        }
        let bytes: [UInt8]
        switch output.encoding {
        case .utf8:
            switch try await projectionHistory(for: output.binding, basedOn: snapshot) {
            case .checked(let history): bytes = try await projectionValue(fromBinding: history, basedOn: snapshot).body.bytes
            case .waiting, .blocked: throw StorageError.incomplete
            case .foreignCollection, .invalidClaim: throw StorageError.integrity
            }
            let captured = bytes
            guard try await lane.historyWork({ ProjectionBytesDigestV1.compute(captured) }) == output.binding.descriptor.digest else { throw StorageError.integrity }
        case .captured:
            bytes = try await capturedProjectionBytes(output, observations: observations)
        }
        try await lane.perform { db in
            try db.checkCurrentView(snapshot)
            try db.checkProjectionCapture(observations, selection: selection)
        }
        return bytes
    }

    /// Reads privately captured native-encoding bytes through their exact current owner.
    public func capturedProjectionBytes(_ output: ProjectionOutputV1,
                                        observations: ProjectionObservationState) async throws -> [UInt8] {
        guard !closed, !quiescing else { throw StorageError.closed }
        guard observations.store == selection.store, observations.session == incarnation else { throw StorageError.wrongContext }
        let owned = observations.value?.ownedOutputs ?? []
        guard owned.contains(output) else { throw StorageError.wrongContext }
        guard case .captured(_, let count) = output.encoding else { throw StorageError.unsupported }
        let selection = selection
        try await lane.perform { db in
            try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
            try db.checkProjectionCapture(observations, selection: selection)
            try db.checkProjectionByteInventory(output)
        }
        let selected = try await lane.perform { $0.work?.querySelected }
        await selected?()
        var bytes: [UInt8] = [], index: UInt64 = 0
        while UInt64(bytes.count) < count {
            try Task.checkCancellation()
            let key = projectionByteKey(output, index: index)
            let part = try await lane.perform { db in
                guard let row = try db.privateGroup(key), row[0] == .integer(1), row[1] == .integer(1) else {
                    try db.checkProjectionCapture(observations, selection: selection)
                    throw StorageError.integrity
                }
                return try row[2].bytes
            }
            guard !part.isEmpty, part.count <= projectionByteChunkSize,
                  UInt64(part.count) <= count - UInt64(bytes.count) else { throw StorageError.integrity }
            bytes.append(contentsOf: part); index += 1
        }
        let captured = bytes
        guard try await lane.historyWork({ ProjectionBytesDigestV1.compute(captured) }) == output.binding.descriptor.digest else { throw StorageError.integrity }
        try await lane.perform { db in
            try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
            try db.checkProjectionCapture(observations, selection: selection)
        }
        return bytes
    }
}

private let projectionByteChunkSize = 1024 * 1024
private func projectionBytePrefix(_ output: ProjectionOutputV1) -> String {
    let hex = { (bytes: [UInt8]) in bytes.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined() }
    return "projection-data/" + hex(output.binding.birth.bytes) + "/" + hex(output.binding.descriptor.digest.bytes) + "/"
}
private func projectionByteKey(_ output: ProjectionOutputV1, index: UInt64) -> String {
    let suffix = String(index, radix: 16)
    return projectionBytePrefix(output) + String(repeating: "0", count: 16 - suffix.count) + suffix
}

private func projectionGroup(_ birth: NoteBirth) -> String {
    "projection/" + birth.bytes.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
}

private func replacementAttemptGroup(_ birth: NoteBirth) -> String {
    "projection-replacement/" + birth.bytes.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
}

private func sourceAttemptGroup(_ birth: NoteBirth) -> String {
    "projection-source/" + birth.bytes.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
}

extension Database {
    fileprivate func checkOriginalProjectionDeletion(_ authorized: AuthorizedProjectionDeletion, selection: LocalStoreSelection) throws {
        let input = authorized.original.input
        try checkProjectionDeletionOwner(input, selection: selection)
        let through = try acceptedThrough()
        guard through >= authorized.receipt.sequence,
              try rows("SELECT epoch,reducer_version,through_seq FROM view_meta WHERE singleton=1") ==
                [[.blob(input.snapshot.viewEpoch), .integer(1), .integer(through)]],
              try rows("SELECT 1 FROM current_notes WHERE birth=?", [.blob(input.birth.bytes)]).isEmpty else {
            throw StorageError.staleCapture
        }
    }

    fileprivate func decodedSourceAttempt(_ row: [SQLValue], birth: NoteBirth,
                                          selection: LocalStoreSelection) throws -> ProjectionSourceAttemptV1 {
        guard row[1] == .integer(1) else { throw StorageError.unsupported }
        guard row[0] == .integer(1) else { throw StorageError.integrity }
        let value: ProjectionSourceAttemptV1
        do { value = try .decodeV1(row[2].bytes, profile: selection.descriptor.keyID == nil ? .plaintextFiles : .encryptedSegments) }
        catch { throw classify(error) }
        try checkCapturedPrivateScope(value.scope, selection: selection)
        guard value.birth == birth, let observed = try privateGroup(projectionGroup(birth)) else { throw StorageError.integrity }
        let owner = try decodedProjectionObservations(observed, birth: birth, selection: selection)
        guard owner.association == value.association, owner.accepted == value.source else { throw StorageError.integrity }
        let ref = value.deletion
        guard try rows("SELECT o.writer_epoch,o.sequence,o.kind,c.action_id FROM accepted_objects a JOIN objects o USING(object_id) JOIN action_occurrences c ON c.object_id=a.object_id WHERE a.object_id=? AND c.record_index=?",
            [.blob(ref.locator.segmentID.bytes), .integer(Int64(ref.index.rawValue))]) ==
            [[.blob(ref.locator.writerEpoch.bytes), .blob(Array(ref.locator.encodedV1()[16..<24])), .integer(1), .blob(ref.id.bytes)]],
              try !rows("SELECT 1 FROM operations o JOIN action_members m USING(operation_id,action_id) WHERE o.birth=? AND o.kind=6 AND m.action_id=?",
                [.blob(birth.bytes), .blob(ref.id.bytes)]).isEmpty else { throw StorageError.integrity }
        return value
    }

    /// Checks pending source locations and their retained byte/history owners during reopening.
    func validateProjectionSourceAttempts(selection: LocalStoreSelection) throws {
        try each("SELECT group_key,generation,codec,payload FROM private_groups WHERE group_key>=? AND group_key<? ORDER BY group_key",
            [.blob(Array("projection-source/".utf8)), .blob(Array("projection-source0".utf8))]) { row in
            guard row[2] == .integer(1) else { throw StorageError.unsupported }
            let record: ProjectionSourceAttemptV1
            do { record = try .decodeV1(row[3].bytes, profile: selection.descriptor.keyID == nil ? .plaintextFiles : .encryptedSegments) }
            catch { throw classify(error) }
            guard row[0] == .blob(Array(sourceAttemptGroup(record.birth).utf8)) else { throw StorageError.integrity }
            _ = try decodedSourceAttempt(Array(row.dropFirst()), birth: record.birth, selection: selection)
        }
    }

    fileprivate func checkProjectionDeletionOwner(_ input: PreparedProjectionDeletion, selection: LocalStoreSelection) throws {
        try validateHeader(store: selection.store, descriptor: selection.descriptor)
        guard incarnation == input.connection else { throw StorageError.wrongContext }
        guard let row = try privateGroup("association"), row[0] == .integer(input.associationGeneration),
              try decodedAssociation(row, selection: selection) == input.association else { throw StorageError.staleCapture }
        try checkProjectionCapture(input.observations, selection: selection)
    }

    fileprivate func checkFrozenProjection(output: ProjectionOutputV1, source: AcceptedProjectionV1?,
                                          association: LocalAssociationV1, associationGeneration: Int64,
                                          snapshot: StoreSnapshot, connection: UUID, selection: LocalStoreSelection) throws {
        try validateHeader(store: selection.store, descriptor: selection.descriptor)
        guard incarnation == connection else { throw StorageError.wrongContext }
        guard let row = try privateGroup("association"), row[0] == .integer(associationGeneration),
              try decodedAssociation(row, selection: selection) == association else { throw StorageError.staleCapture }
        guard let observed = try privateGroup(projectionGroup(output.binding.birth)) else { throw StorageError.staleCapture }
        let current = try decodedProjectionObservations(observed, birth: output.binding.birth, selection: selection)
        guard current.association == association.id, current.accepted == source,
              current.frozen?.source == source, current.frozen?.output == output else { throw StorageError.staleCapture }
        let through = try acceptedThrough()
        guard through >= snapshot.through,
              try rows("SELECT epoch,reducer_version,through_seq FROM view_meta WHERE singleton=1") ==
                [[.blob(snapshot.viewEpoch), .integer(1), .integer(through)]] else { throw StorageError.staleCapture }
        guard let note = try rows("SELECT cell FROM current_notes WHERE birth=?", [.blob(output.binding.birth.bytes)]).first else {
            throw StorageError.staleCapture
        }
        guard try currentCell(note[0].bytes).birth == output.binding.birth else { throw StorageError.integrity }
    }

    fileprivate func decodedReplacementAttempt(_ row: [SQLValue], birth: NoteBirth,
                                               selection: LocalStoreSelection) throws -> ProjectionReplacementAttemptV1 {
        guard row[1] == .integer(1) else { throw StorageError.unsupported }
        guard row[0] == .integer(1) else { throw StorageError.integrity }
        let value: ProjectionReplacementAttemptV1
        do { value = try .decodeV1(row[2].bytes, profile: selection.descriptor.keyID == nil ? .plaintextFiles : .encryptedSegments) }
        catch { throw classify(error) }
        try checkCapturedPrivateScope(value.scope, selection: selection)
        guard value.transition.output.binding.birth == birth,
              let state = try privateGroup(projectionGroup(birth)) else { throw StorageError.integrity }
        let owner = try decodedProjectionObservations(state, birth: birth, selection: selection)
        guard owner.association == value.association, owner.frozen == value.transition else { throw StorageError.integrity }
        return value
    }

    /// Verifies every outstanding candidate while preserving its exact frozen owner.
    func validateProjectionReplacementAttempts(selection: LocalStoreSelection) throws {
        try each("SELECT group_key,generation,codec,payload FROM private_groups WHERE group_key>=? AND group_key<? ORDER BY group_key",
            [.blob(Array("projection-replacement/".utf8)), .blob(Array("projection-replacement0".utf8))]) { row in
            guard row[2] == .integer(1) else { throw StorageError.unsupported }
            let record: ProjectionReplacementAttemptV1
            do { record = try .decodeV1(row[3].bytes, profile: selection.descriptor.keyID == nil ? .plaintextFiles : .encryptedSegments) }
            catch { throw classify(error) }
            let birth = record.transition.output.binding.birth
            guard row[0] == .blob(Array(replacementAttemptGroup(birth).utf8)) else { throw StorageError.integrity }
            _ = try decodedReplacementAttempt(Array(row.dropFirst()), birth: birth, selection: selection)
        }
    }
    /// Captures accepted Changes tips alongside the exact source occurrences.
    fileprivate func projectionDescriptionDependencies(_ binding: ProjectionBindingV1, through: Int64) throws -> DependencyLocatorTable {
        try checkingRetainedHistory {
            let tips = try rows("SELECT r.locator,o.object_id,o.writer_epoch,o.sequence,a.seq FROM retained_frontier r LEFT JOIN objects o USING(object_id) LEFT JOIN accepted_objects a USING(object_id) WHERE o.kind=1 OR o.object_id IS NULL OR a.object_id IS NULL")
            var dependencies = Set(binding.dependencies.entries)
            for row in tips {
                guard row[1] != .null, row[4] != .null else { throw StorageError.incomplete }
                let locator = try SegmentLocator.decodeV1(row[0].bytes)
                guard row[1] == .blob(locator.segmentID.bytes), row[2] == .blob(locator.writerEpoch.bytes),
                      row[3] == .blob(Array(locator.encodedV1()[16..<24])), try row[4].number <= through else { throw StorageError.integrity }
                dependencies.insert(locator)
            }
            return try DependencyLocatorTable(Array(dependencies))
        }
    }

    fileprivate func retainProjectionBytes(_ prepared: PreparedProjectionIntent) throws {
        guard case .captured(_, let count) = prepared.output.encoding else { return }
        guard count == UInt64(prepared.bytes.count) else { throw StorageError.integrity }
        for start in stride(from: 0, to: prepared.bytes.count, by: projectionByteChunkSize) {
            let key = projectionByteKey(prepared.output, index: UInt64(start / projectionByteChunkSize))
            let bytes = Array(prepared.bytes[start..<min(start + projectionByteChunkSize, prepared.bytes.count)])
            if let existing = try privateGroup(key) {
                guard existing == [.integer(1), .integer(1), .blob(bytes)] else { throw StorageError.integrity }
            } else { try run("INSERT INTO private_groups VALUES(?,1,1,?)", [.blob(Array(key.utf8)), .blob(bytes)]) }
        }
    }
    fileprivate func checkProjectionByteInventory(_ output: ProjectionOutputV1) throws {
        guard case .captured(_, let count) = output.encoding else { return }
        let prefix = projectionBytePrefix(output)
        let rows = try rows("SELECT group_key,generation,codec,length(payload) FROM private_groups WHERE group_key>=? AND group_key<? ORDER BY group_key",
            [.blob(Array(prefix.utf8)), .blob(Array((prefix + "g").utf8))])
        let expected = count / UInt64(projectionByteChunkSize) + (count % UInt64(projectionByteChunkSize) == 0 ? 0 : 1)
        guard UInt64(rows.count) == expected else { throw StorageError.integrity }
        for (index, row) in rows.enumerated() {
            guard row[0] == .blob(Array(projectionByteKey(output, index: UInt64(index)).utf8)),
                  row[1] == .integer(1) else { throw StorageError.integrity }
            guard row[2] == .integer(1) else { throw StorageError.unsupported }
            guard row[3] == .integer(Int64(min(count - UInt64(index * projectionByteChunkSize), UInt64(projectionByteChunkSize)))) else { throw StorageError.integrity }
        }
    }
    /// Releases superseded chunks in the same transaction that transfers their owners.
    fileprivate func releaseSupersededProjectionBytes(_ previous: ProjectionObservationsV1?, retaining value: ProjectionObservationsV1) throws {
        let retained = Set(value.ownedOutputs.map(projectionBytePrefix))
        let superseded = Set((previous?.ownedOutputs ?? []).compactMap { output -> String? in
            guard case .captured = output.encoding else { return nil }
            return projectionBytePrefix(output)
        }).subtracting(retained)
        for prefix in superseded {
            try run("DELETE FROM private_groups WHERE group_key>=? AND group_key<?",
                [.blob(Array(prefix.utf8)), .blob(Array((prefix + "g").utf8))])
        }
    }
    fileprivate func checkProjectionCapture(_ state: ProjectionObservationState, selection: LocalStoreSelection) throws {
        let row = try privateGroup(projectionGroup(state.birth))
        guard try row?[0].number ?? 0 == state.generation else { throw StorageError.staleCapture }
        guard try row.map({ try decodedProjectionObservations($0, birth: state.birth, selection: selection) }) == state.value else { throw StorageError.integrity }
    }
    fileprivate func checkProjectionIntent(_ prepared: PreparedProjectionIntent, selection: LocalStoreSelection) throws {
        guard prepared.connection == incarnation else { throw StorageError.wrongContext }
        try validateHeader(store: selection.store, descriptor: selection.descriptor)
        try checkCurrentView(prepared.snapshot)
        try checkProjectionCapture(prepared.previous, selection: selection)
        guard let row = try privateGroup("association"), try row[0].number == prepared.associationGeneration,
              try decodedAssociation(row, selection: selection) == prepared.association else { throw StorageError.staleCapture }
    }
    func decodedProjectionObservations(_ row: [SQLValue], birth: NoteBirth, selection: LocalStoreSelection) throws -> ProjectionObservationsV1 {
        guard row[1] == .integer(1) else { throw StorageError.unsupported }
        let value: ProjectionObservationsV1
        do { value = try .decodeV1(row[2].bytes, profile: selection.descriptor.keyID == nil ? .plaintextFiles : .encryptedSegments) } catch { throw classify(error) }
        guard value.birth == birth, try row[0].number > 0 else { throw StorageError.integrity }
        try checkCapturedPrivateScope(value.scope, selection: selection)
        for output in value.ownedOutputs {
            try checkProjectionByteInventory(output)
        }
        return value
    }
    /// Streams required per-note descriptions during opening and exceptional private-store verification.
    func validateProjectionObservations(selection: LocalStoreSelection) throws {
        try each("SELECT group_key,generation,codec,payload FROM private_groups WHERE group_key>=? AND group_key<? ORDER BY group_key",
                 [.blob(Array("projection/".utf8)), .blob(Array("projection0".utf8))]) { row in
            let key = try row[0].bytes, prefix = Array("projection/".utf8), suffix = Array(key.dropFirst(prefix.count))
            guard suffix.count == 32 else { throw StorageError.integrity }
            var bytes: [UInt8] = []
            for index in stride(from: 0, to: suffix.count, by: 2) {
                guard let byte = UInt8(String(decoding: suffix[index...index+1], as: UTF8.self), radix: 16) else { throw StorageError.integrity }
                bytes.append(byte)
            }
            let birth: NoteBirth
            do { birth = try NoteBirth(bytes: bytes) } catch { throw classify(error) }
            guard key == Array(projectionGroup(birth).utf8) else { throw StorageError.integrity }
            _ = try decodedProjectionObservations(Array(row.dropFirst()), birth: birth, selection: selection)
        }
    }
}
