import NVStorageCore

extension Database {
    func operation(_ id: OperationID, selection: LocalStoreSelection, protection: ObjectProtectionV1) throws -> IdentifiedOperation? {
        if try rows("SELECT 1 FROM operations WHERE operation_id=?", [.blob(id.bytes)]).isEmpty { return nil }
        return try checkingRetainedHistory {
            let ref = try operationOccurrence(id)
            guard let p = try payload(ref.locator, collection: selection.descriptor.collection, protection: protection),
                  Int64(ref.index.rawValue) < Int64(p.operations.count), p.operations[Int(ref.index.rawValue)].operation.id == id else {
                throw StorageError.integrity
            }
            return p.operations[Int(ref.index.rawValue)].operation
        }
    }
    func action(_ id: ActionID, selection: LocalStoreSelection, protection: ObjectProtectionV1) throws -> ActionV1? {
        if try rows("SELECT 1 FROM actions WHERE action_id=?", [.blob(id.bytes)]).isEmpty { return nil }
        return try checkingRetainedHistory {
            let ref = try actionOccurrence(id)
            guard let p = try payload(ref.locator, collection: selection.descriptor.collection, protection: protection),
                  Int64(ref.index.rawValue) < Int64(p.actions.count), p.actions[Int(ref.index.rawValue)].action.id == id else {
                throw StorageError.integrity
            }
            return p.actions[Int(ref.index.rawValue)].action
        }
    }
    /// Advances one complete acceptance batch in a guarded current-state transaction.
    @discardableResult
    func catchUp(selection: LocalStoreSelection, protection: ObjectProtectionV1) throws -> Bool {
        try measuring(.materialization) {
            try materializeAcceptedSuffix(selection: selection, protection: protection)
        }
    }

    private func materializeAcceptedSuffix(selection: LocalStoreSelection, protection: ObjectProtectionV1) throws -> Bool {
        try transaction {
            let meta = try rows("SELECT through_seq,authoring_context FROM view_meta WHERE singleton=1")
            guard meta.count == 1 else { throw StorageError.integrity }
            let start = try meta[0][0].number, available = try acceptedThrough()
            guard start > 0, start <= available else { throw StorageError.incomplete }
            if start == available { return true }
            let target = start < available ? start + 1 : available
            var context = try AuthoringContextV1.decodeV1(meta[0][1].bytes)
            try each("SELECT o.writer_epoch,o.sequence,o.object_id,o.encoded,a.seq FROM accepted_objects a JOIN objects o USING(object_id) WHERE a.seq>? AND a.seq<=? AND o.kind=1 ORDER BY a.seq,o.object_id", [.integer(start), .integer(target)]) { r in
                let (locator, p) = try self.checkingRetainedHistory {
                    self.countWork { $0.historyReads += 1; $0.envelopeDecodes += 1 }
                    let locator = try SegmentLocator.decodeV1(r[0].bytes + r[1].bytes + r[2].bytes)
                    let opened = try ObjectEnvelopeV1.open(r[3].bytes, collection: selection.descriptor.collection,
                        protection: protection, expectedLocator: locator)
                    return try (locator, ChangesPayloadV1.decodeV1(opened.payload))
                }
                for (index, record) in p.actions.enumerated() {
                    let a = record.action
                    let first = try self.rows("SELECT source_object,first_seq FROM actions WHERE action_id=?", [.blob(a.id.bytes)])
                    guard first == [[.blob(locator.segmentID.bytes), r[4]]] else { continue }
                    let occurrence = StoredActionReferenceV1(locator: locator, index: ActionIndex(UInt32(index)), id: a.id)
                    for entry in a.affected {
                        let old = try self.rows("SELECT cell FROM current_notes WHERE birth=?", [.blob(entry.birth.bytes)])
                        let cell = try old.first.map { try CurrentNoteCellV1.decodeV1($0[0].bytes) }
                        switch entry.before {
                        case .freshBirthAbsence: guard cell == nil else { throw StorageError.unsupported }
                        case .value(let id): guard cell?.revision.id == id else { throw StorageError.unsupported }
                        case .deleted: throw StorageError.unsupported
                        }
                        switch entry.after {
                        case .freshBirthAbsence: throw StorageError.integrity
                        case .deleted:
                            try self.run("DELETE FROM current_notes WHERE birth=?", [.blob(entry.birth.bytes)])
                        case .value(let id):
                            guard let op = p.operations.first(where: { $0.operation.id == id })?.operation,
                                  let value = op.effect.noteValue else { throw StorageError.integrity }
                            let scope = a.scope == .note(entry.birth) ? [occurrence] : (cell?.scopeFrontier ?? [])
                            let next = try CurrentNoteCellV1(birth: entry.birth, value: value,
                                revision: self.operationOccurrence(id), scopeFrontier: scope)
                            try self.run("INSERT INTO current_notes VALUES(?,?) ON CONFLICT(birth) DO UPDATE SET cell=excluded.cell",
                                [.blob(entry.birth.bytes), .blob(next.encodedV1())])
                        }
                    }
                    if a.scope == .collection {
                        context = try AuthoringContextV1(operations: context.operations,
                            collectionActions: context.collectionActions.filter { !a.scopeParents.contains($0.id) } + [occurrence])
                    }
                }
                for record in p.operations {
                    let op = record.operation
                    let first = try self.rows("SELECT source_object,first_seq FROM operations WHERE operation_id=?", [.blob(op.id.bytes)])
                    guard first == [[.blob(locator.segmentID.bytes), r[4]]] else { continue }
                    let maxima = advancingFrontier(Set(context.operations.map(\.id)), adding: [op.id], parents: Set(op.causalParents.ids))
                    context = try AuthoringContextV1(operations: context.operations.filter { maxima.contains($0.id) } + [self.operationOccurrence(op.id)],
                        collectionActions: context.collectionActions)
                }
            }
            try run("UPDATE view_meta SET through_seq=?,authoring_context=? WHERE singleton=1 AND through_seq=?",
                [.integer(target), .blob(context.encodedV1()), .integer(start)])
            return target == available
        }
    }
}

extension DatabaseLane {
    /// Yields the database lane between complete materialized prefixes.
    nonisolated func catchUp(selection: LocalStoreSelection, protection: ObjectProtectionV1) async throws {
        while try await !perform({ try $0.catchUp(selection: selection, protection: protection) }) { }
    }
}

extension OperationEffectV1 {
    var noteValue: PlaintextNoteValue? {
        switch self { case .create(_, _, let value), .put(_, _, let value), .importNote(_, _, let value): value; default: nil }
    }
}
