import NVStorageCore

/// Exact inputs needed either to assemble a snapshot or to interpret accepted history.
public enum ObjectRequirement: Hashable, Sendable {
    case retainedBytes(SegmentLocator)
    case acceptedHistory(SegmentLocator)

    public var locator: SegmentLocator {
        switch self { case .retainedBytes(let locator), .acceptedHistory(let locator): locator }
    }
}

/// Canonical payload dispatch shared by intake, assembly and history acceptance.
enum ReceivedPayload: Sendable {
    case changes(ChangesPayloadV1)
    case page(InitialSnapshotPageV1)
    case root(InitialSnapshotRootV1)
    case generalPage(GeneralSnapshotPageV1)
    case generalRoot(GeneralSnapshotRootV1)

    init(_ opened: OpenedObjectV1) throws {
        switch opened.kind {
        case .changes: self = .changes(try ChangesPayloadV1.decodeV1(opened.payload))
        case .snapshotPage:
            if opened.payload.starts(with: Array("NVGPG1\r\n".utf8)) {
                self = .generalPage(try GeneralSnapshotPageV1.decodeV1(opened.payload))
            } else { self = .page(try InitialSnapshotPageV1.decodeV1(opened.payload)) }
        case .snapshotRoot:
            if opened.payload.starts(with: Array("NVGRT1\r\n".utf8)) {
                self = .generalRoot(try GeneralSnapshotRootV1.decodeV1(opened.payload))
            } else { self = .root(try InitialSnapshotRootV1.decodeV1(opened.payload)) }
        }
    }

    var requirements: [ObjectRequirement] {
        switch self {
        case .changes(let payload): payload.dependencies.entries.map(ObjectRequirement.acceptedHistory)
        case .page(let page): page.dependencies.entries.map(ObjectRequirement.acceptedHistory)
        case .root(let root): root.pages.map { .retainedBytes($0.locator) } + root.dependencies.entries.map(ObjectRequirement.acceptedHistory)
        case .generalPage(let page):
            if case .index(let children) = page.contents { children.map { .retainedBytes($0.locator) } } else { [] }
        case .generalRoot(let root): [.retainedBytes(root.tree.locator), .acceptedHistory(root.bootstrapSnapshot)]
        }
    }
}

/// Discovery found an exact prerequisite whose validation or bytes remain unavailable.
struct ReceiveWait: Error, Sendable {
    let requirements: [ObjectRequirement]
}

extension Database {
    /// Retains one checked envelope and its arrival wakeups in the caller's transaction.
    func retainCandidate(_ bytes: [UInt8], opened: OpenedObjectV1, ready: Bool) throws {
        let locator = opened.locator, id = SQLValue.blob(locator.segmentID.bytes)
        let expected: [SQLValue] = [.integer(Int64(opened.kind.rawValue)), .blob(locator.writerEpoch.bytes),
                                   .blob(Array(locator.encodedV1()[16..<24])), .blob(bytes)]
        let old = try rows("SELECT kind,writer_epoch,sequence,encoded FROM objects WHERE object_id=?", [id])
        if old.isEmpty { try run("INSERT INTO objects VALUES(?,?,?,?,?)", [id] + expected) }
        else if old != [expected] { throw StorageError.integrity }
        if ready {
            try run("INSERT INTO ready_objects SELECT object_id FROM objects WHERE object_id=? AND NOT EXISTS(SELECT 1 FROM accepted_objects WHERE object_id=?) AND NOT EXISTS(SELECT 1 FROM rejected_objects WHERE object_id=?) ON CONFLICT DO NOTHING", [id, id, id])
        }
        try wakeArrivedCandidate(id)
    }

    /// Rechecks reverse waits when exact bytes arrive, including duplicate deliveries.
    func wakeArrivedCandidate(_ id: SQLValue) throws {
        try run("INSERT INTO ready_objects SELECT w.child FROM object_waits w JOIN objects o ON o.object_id=w.child WHERE w.prerequisite=? AND NOT EXISTS(SELECT 1 FROM accepted_objects a WHERE a.object_id=w.child) AND NOT EXISTS(SELECT 1 FROM rejected_objects r WHERE r.object_id=w.child) ON CONFLICT DO NOTHING", [id])
    }

    /// Reconstructs requirement roles from immutable inputs; only exact IDs occupy SQL waits.
    func missingRequirements(_ requirements: [ObjectRequirement]) throws -> [ObjectRequirement] {
        try requirements.filter { requirement in
            let locator = requirement.locator, id = SQLValue.blob(locator.segmentID.bytes)
            let rows = try rows("SELECT writer_epoch,sequence FROM objects WHERE object_id=?", [id])
            if rows.isEmpty {
                if try !self.rows("SELECT 1 FROM accepted_objects WHERE object_id=?", [id]).isEmpty {
                    return try checkingRetainedHistory { throw StorageError.incomplete }
                }
                return true
            }
            guard rows == [[.blob(locator.writerEpoch.bytes), .blob(Array(locator.encodedV1()[16..<24]))]] else {
                throw CanonicalEncodingError.invalidReference
            }
            if try receivedRejection(id) != nil { return true }
            switch requirement {
            case .retainedBytes: return false
            case .acceptedHistory: return try self.rows("SELECT 1 FROM accepted_objects WHERE object_id=?", [id]).isEmpty
            }
        }
    }

    /// Publishes waits after rechecking every discovered requirement in the same write transaction.
    func parkReceived(_ locator: SegmentLocator, requirements: [ObjectRequirement]) throws {
        let id = SQLValue.blob(locator.segmentID.bytes)
        try transaction {
            let missing = try missingRequirements(requirements)
            try run("DELETE FROM object_waits WHERE child=?", [id])
            if missing.isEmpty {
                try run("INSERT INTO ready_objects VALUES(?) ON CONFLICT DO NOTHING", [id])
            } else {
                for prerequisite in Set(missing.map { $0.locator.segmentID }) {
                    try run("INSERT INTO object_waits VALUES(?,?)", [id, .blob(prerequisite.bytes)])
                }
                try run("DELETE FROM ready_objects WHERE object_id=?", [id])
            }
        }
    }
}
