import Foundation
import NVStorageCore

/// Prepared physical rows for a guarded materialization transaction.
struct EncodedCurrentRows: Sendable {
    let rows: [(NoteBirth, [UInt8])]
    let dictionary: CurrentRowDictionaryV1?
    init(cells: [CurrentNoteCellV1], dictionary: CurrentRowDictionaryV1? = nil) throws {
        let encoder = try? CurrentRowEncoderV1(dictionary: dictionary)
        rows = cells.map { cell in (cell.birth, encoder?.encode(cell) ?? CurrentRowEncoderV1.raw(cell)) }
        self.dictionary = rows.contains { (try? CurrentRowFrameV1(bytes: $0.1).dictionaryDigest) == dictionary?.digest } ? dictionary : nil
    }
    /// Installs codec metadata and referencing rows inside the consumer's fenced transaction.
    func install(database db: Database) throws {
        if let dictionary { try db.retainCurrentDictionary(dictionary) }
        for (birth, bytes) in rows {
            try db.run("INSERT INTO current_notes VALUES(?,?) ON CONFLICT(birth) DO UPDATE SET cell=excluded.cell", [.blob(birth.bytes), .blob(bytes)])
        }
    }
}

/// Scoped decoder resources shared by a current-table capture or affected-note read.
final class CurrentRowRead {
    private let decoder: CurrentRowDecoderV1
    init() throws { decoder = try CurrentRowDecoderV1() }
    func decode(_ bytes: [UInt8], database db: Database) throws -> CurrentNoteCellV1 {
        let frame = try CurrentRowFrameV1(bytes: bytes)
        db.countWork { $0.currentCellDecodes += 1; $0.currentEncodedBytes += bytes.count; $0.currentExpandedBytes += frame.expandedCount }
        return try decoder.decode(bytes) { digest in
            db.countWork { $0.dictionaryLoads += 1 }
            let rows = try db.rows("SELECT encoded FROM current_dictionaries WHERE dictionary_id=?", [.blob(digest)])
            guard rows.count == 1 else { throw CanonicalEncodingError.missingDependency }
            let dictionary = try CurrentRowDictionaryV1(bytes: rows[0][0].bytes)
            guard dictionary.digest == digest else { throw CanonicalEncodingError.identityMismatch }
            return dictionary
        }
    }
}

extension Database {
    func currentCell(_ bytes: [UInt8]) throws -> CurrentNoteCellV1 { try CurrentRowRead().decode(bytes, database: self) }
    /// Reads one optional compression candidate; referenced dictionaries are checked by their row reader.
    func currentDictionary() throws -> CurrentRowDictionaryV1? {
        let rows = try self.rows("SELECT dictionary_id,encoded FROM current_dictionaries ORDER BY rowid DESC LIMIT 1")
        guard let row = rows.first else { return nil }
        do {
            let value = try CurrentRowDictionaryV1(bytes: row[1].bytes)
            return value.digest == (try row[0].bytes) ? value : nil
        } catch is CanonicalEncodingError { return nil }
    }
    func retainCurrentDictionary(_ dictionary: CurrentRowDictionaryV1) throws {
        let previous = try rows("SELECT encoded FROM current_dictionaries WHERE dictionary_id=?", [.blob(dictionary.digest)])
        if previous.isEmpty {
            try run("INSERT INTO current_dictionaries VALUES(?,?)", [.blob(dictionary.digest), .blob(dictionary.bytes)])
        } else { guard previous == [[.blob(dictionary.bytes)]] else { throw StorageError.integrity } }
    }
}

/// Exact physical batch and logical view captured before optional representation work.
private struct CurrentRecodeCapture: Sendable {
    let connection: UUID
    let selection: LocalStoreSelection
    let snapshot: StoreSnapshot
    let previous: [[SQLValue]]
    let cells: [CurrentNoteCellV1]
    let dictionary: CurrentRowDictionaryV1?
    func install(_ rows: EncodedCurrentRows, database db: Database) throws {
        guard connection == db.incarnation else { throw StorageError.wrongContext }
        try db.transaction {
            try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
            try db.checkCurrentView(snapshot)
            for row in previous {
                guard try db.rows("SELECT birth,cell FROM current_notes WHERE birth=?", [row[0]]) == [row] else { throw StorageError.staleCapture }
            }
            try rows.install(database: db)
        }
    }
}

extension Database {
    /// Rechecks the exact materialized history, context and presentation used by a current-row capture.
    func checkCurrentView(_ snapshot: StoreSnapshot) throws {
        try validateOwner()
        guard try rows("SELECT epoch,reducer_version,through_seq,authoring_context FROM view_meta WHERE singleton=1") ==
            [[.blob(snapshot.viewEpoch), .integer(1), .integer(snapshot.through), .blob(snapshot.context.encodedV1())]],
              try acceptedThrough() == snapshot.through, presentationEpoch == snapshot.presentationEpoch else { throw StorageError.staleCapture }
    }
}

extension LocalStoreSession {
    /// Reframes a bounded current-row batch using resident values and an optional bounded training job.
    /// The returned birth is a physical-work cursor for the caller's next idle turn.
    public func recodeCurrentRows(basedOn snapshot: StoreSnapshot, after birth: NoteBirth? = nil,
                                 maximumRows: Int = 64, trainDictionary: Bool = false) async throws -> NoteBirth? {
        guard !closed, !quiescing else { throw StorageError.closed }
        guard !rowEncodingInFlight else { throw StorageError.busy }
        guard snapshot.store == selection.store, snapshot.session == incarnation else { throw StorageError.wrongContext }
        guard maximumRows > 0, maximumRows <= 256 else { throw StorageError.limit }
        rowEncodingInFlight = true
        cancelMaintenance()
        defer {
            rowEncodingInFlight = false
            let waiters = drained; drained.removeAll(); for waiter in waiters { waiter.resume() }
        }
        let selection = selection
        let capture = try await lane.perform { db in
            try db.checkCurrentView(snapshot)
            let previous = try db.rows("SELECT birth,cell FROM current_notes WHERE birth>? ORDER BY birth LIMIT ?", [.blob(birth?.bytes ?? []), .integer(Int64(maximumRows))])
            let decoder = try CurrentRowRead()
            let cells = try previous.map { row in
                let cell = try decoder.decode(row[1].bytes, database: db)
                guard cell.birth.bytes == (try row[0].bytes) else { throw StorageError.staleCapture }
                return cell
            }
            return try CurrentRecodeCapture(connection: db.incarnation, selection: selection, snapshot: snapshot,
                previous: previous, cells: cells, dictionary: db.currentDictionary())
        }
        guard !capture.cells.isEmpty else { return nil }
        let train = trainDictionary && !(trainedRowView.map { $0.0 == snapshot.viewEpoch && $0.1 == snapshot.through } ?? false)
        if train { trainedRowView = (snapshot.viewEpoch, snapshot.through) }
        let rows = try await lane.historyWork {
            let births = Set(capture.cells.map(\.birth))
            let expected = snapshot.notes.filter { births.contains($0.birth) }
            let expectedByBirth = Dictionary(uniqueKeysWithValues: expected.map { ($0.birth, $0) })
            guard expected.count == capture.cells.count, capture.cells.allSatisfy({ expectedByBirth[$0.birth] == $0 }) else { throw StorageError.staleCapture }
            var dictionary = capture.dictionary
            if train {
                let count = min(1024, snapshot.notes.count)
                let bodies = (0..<count).map { snapshot.notes[$0 * snapshot.notes.count / count].value.body.bytes }
                dictionary = try CurrentRowDictionaryV1.train(bodies: bodies) ?? dictionary
            }
            try Task.checkCancellation()
            return try EncodedCurrentRows(cells: capture.cells, dictionary: dictionary)
        }
        let gate = try await lane.perform { $0.work?.currentRowsPrepared }
        await gate?()
        try Task.checkCancellation()
        try await lane.perform { try capture.install(rows, database: $0) }
        return capture.cells.last?.birth
    }
}
