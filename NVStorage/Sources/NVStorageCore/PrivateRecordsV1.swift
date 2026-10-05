import Crypto

/// Canonical private records and passive host observations protected by database pages.
/// The owned runtime checks their contextual references before installation or settlement.
public struct PendingItemID: Equatable, Hashable, Sendable {
    public let bytes: [UInt8]
    public init(bytes: [UInt8]) throws { self.bytes = try identifierBytes(bytes, count: 16) }
}
public struct PendingSnapshotID: Equatable, Hashable, Sendable {
    public let bytes: [UInt8]
    public init(bytes: [UInt8]) throws { self.bytes = try identifierBytes(bytes, count: 16) }
}
public struct PendingReservationID: Equatable, Hashable, Sendable {
    public let bytes: [UInt8]
    public init(bytes: [UInt8]) throws { self.bytes = try identifierBytes(bytes, count: 16) }
}

/// Bounded host-coded bytes whose interpretation belongs to the platform adapter.
public struct PassivePlatformRecordV1: Equatable, Sendable {
    public let codec: UInt32
    public let bytes: [UInt8]
    public init(codec: UInt32, bytes: [UInt8]) throws {
        guard codec > 0 else { throw CanonicalEncodingError.unsupportedFormat }
        try privateSize(8 + UInt64(bytes.count))
        self.codec = codec; self.bytes = bytes
    }
    func encoded() -> [UInt8] { bigEndianBytes(codec) + privateBlob(bytes) }
    static func decode(_ c: inout ByteCursor) throws -> Self {
        try Self(codec: c.unsigned32(), bytes: c.lengthPrefixedBytes())
    }
}

/// Exact ordered filename extensions and the selected entry for one legacy format slot.
public struct FileExtensionGroupV1: Equatable, Sendable {
    public let extensions: [ExactUTF8]
    public let chosen: UInt32
    public init(extensions: [ExactUTF8], chosen: UInt32) throws {
        guard !extensions.isEmpty, UInt64(chosen) < UInt64(extensions.count) else { throw CanonicalEncodingError.invalidPayload }
        try privateSize(8 + extensions.reduce(UInt64(0)) { $0 + 4 + UInt64($1.bytes.count) })
        self.extensions = extensions; self.chosen = chosen
    }
    func encoded() -> [UInt8] {
        bigEndianBytes(UInt32(extensions.count)) + extensions.flatMap { $0.encodedV1() } + bigEndianBytes(chosen)
    }
    static func decode(_ c: inout ByteCursor) throws -> Self {
        let count = try c.count(minimumElementBytes: 4)
        var values: [ExactUTF8] = []
        for _ in 0..<count { values.append(try c.text()) }
        return try Self(extensions: values, chosen: c.unsigned32())
    }
}

/// A remembered UTF-16 selection that the host clamps against freshly displayed text.
public struct RememberedCursorV1: Equatable, Sendable {
    public let birth: NoteBirth
    public let anchor: UInt64
    public let length: UInt64
    public init(birth: NoteBirth, anchor: UInt64, length: UInt64) throws {
        guard !anchor.addingReportingOverflow(length).overflow else { throw CanonicalEncodingError.lengthLimit }
        self.birth = birth; self.anchor = anchor; self.length = length
    }
}

/// Supported collection overrides, with each field carrying its own value type.
public enum CollectionSettingV1: Equatable, Sendable {
    case storageFormat(UInt64), secureTextEntry(Bool), confirmFileDeletion(Bool)
    case baseBodyFont(PassivePlatformRecordV1), foregroundColor(PassivePlatformRecordV1)
    case pathExtensions([FileExtensionGroupV1]), cursors([RememberedCursorV1]), rememberUnlocking(Bool)
    var key: UInt16 {
        switch self {
        case .storageFormat: 1; case .secureTextEntry: 2; case .confirmFileDeletion: 3
        case .baseBodyFont: 4; case .foregroundColor: 5; case .pathExtensions: 6
        case .cursors: 7; case .rememberUnlocking: 8
        }
    }
    var size: UInt64 {
        switch self {
        case .storageFormat: 8
        case .secureTextEntry, .confirmFileDeletion, .rememberUnlocking: 1
        case .baseBodyFont(let p), .foregroundColor(let p): 8 + UInt64(p.bytes.count)
        case .pathExtensions(let groups): 4 + groups.reduce(0) { $0 + 8 + $1.extensions.reduce(UInt64(0)) { $0 + 4 + UInt64($1.bytes.count) } }
        case .cursors(let cursors): 4 + 32 * UInt64(cursors.count)
        }
    }
    func encoded() -> [UInt8] {
        let payload: [UInt8]
        switch self {
        case .storageFormat(let n): payload = bigEndianBytes(n)
        case .secureTextEntry(let b), .confirmFileDeletion(let b), .rememberUnlocking(let b): payload = [b ? 1 : 0]
        case .baseBodyFont(let p), .foregroundColor(let p): payload = p.encoded()
        case .pathExtensions(let groups): payload = bigEndianBytes(UInt32(groups.count)) + groups.flatMap { $0.encoded() }
        case .cursors(let cursors):
            payload = bigEndianBytes(UInt32(cursors.count)) + cursors.flatMap { $0.birth.bytes + bigEndianBytes($0.anchor) + bigEndianBytes($0.length) }
        }
        return bigEndianBytes(key) + payload
    }
}

/// Complete generation-replaced settings; absent fields remain unstored host overrides.
public struct CollectionSettingsV1: Equatable, Sendable {
    public let fields: [CollectionSettingV1]
    public init(_ fields: [CollectionSettingV1]) throws {
        guard fields.count <= 8, Set(fields.map(\.key)).count == fields.count else { throw CanonicalEncodingError.noncanonicalSet }
        for field in fields {
            switch field {
            case .storageFormat(let n): guard n <= 3 else { throw CanonicalEncodingError.unsupportedFormat }
            case .pathExtensions(let groups): guard groups.count == 4 else { throw CanonicalEncodingError.invalidPayload }
            case .cursors(let cursors):
                try privateSize(4 + UInt64(cursors.count) * 32)
                for i in cursors.indices.dropFirst() {
                    guard cursors[i - 1].birth.bytes.lexicographicallyPrecedes(cursors[i].birth.bytes) else { throw CanonicalEncodingError.noncanonicalSet }
                }
            case .secureTextEntry, .confirmFileDeletion, .baseBodyFont, .foregroundColor, .rememberUnlocking: break
            }
        }
        try privateSize(14 + fields.reduce(UInt64(0)) { $0 + 2 + $1.size })
        self.fields = fields.sorted { $0.key < $1.key }
    }
    public func encodedV1() -> [UInt8] { privateHeader("NVSET1\r\n") + bigEndianBytes(UInt32(fields.count)) + fields.flatMap { $0.encoded() } }
    public static func decodeV1(_ bytes: [UInt8]) throws -> Self {
        var c = try privateCursor(bytes, magic: "NVSET1\r\n")
        let count = try c.count(minimumElementBytes: 3)
        guard count <= 8 else { throw CanonicalEncodingError.unsupportedFormat }
        var fields: [CollectionSettingV1] = [], previous: UInt16 = 0
        for _ in 0..<count {
            let key = try c.unsigned16()
            guard key > previous else { throw CanonicalEncodingError.noncanonicalSet }; previous = key
            switch key {
            case 1: fields.append(.storageFormat(try c.unsigned64()))
            case 2: fields.append(.secureTextEntry(try privateBool(&c)))
            case 3: fields.append(.confirmFileDeletion(try privateBool(&c)))
            case 4: fields.append(.baseBodyFont(try .decode(&c)))
            case 5: fields.append(.foregroundColor(try .decode(&c)))
            case 6:
                guard try c.unsigned32() == 4 else { throw CanonicalEncodingError.invalidPayload }
                var groups: [FileExtensionGroupV1] = []
                for _ in 0..<4 { groups.append(try .decode(&c)) }; fields.append(.pathExtensions(groups))
            case 7:
                let n = try c.count(minimumElementBytes: 32); var cursors: [RememberedCursorV1] = []
                for _ in 0..<n { cursors.append(try .init(birth: NoteBirth(bytes: c.fixedBytes(16)), anchor: c.unsigned64(), length: c.unsigned64())) }
                fields.append(.cursors(cursors))
            case 8: fields.append(.rememberUnlocking(try privateBool(&c)))
            default: throw CanonicalEncodingError.unsupportedFormat
            }
        }
        try c.requireEnd(); return try Self(fields)
    }
}

/// Logical scope attached to a private capture; runtime ownership validates its current binding.
public struct PrivateRecordScopeV1: Equatable, Sendable {
    public let collection: CollectionID
    public let store: LocalStoreID
    public let descriptor: [UInt8]
    public init(collection: CollectionID, store: LocalStoreID, descriptor: [UInt8]) throws {
        self.collection = collection; self.store = store; self.descriptor = try identifierBytes(descriptor, count: 32)
    }
    func encoded() -> [UInt8] { collection.bytes + store.bytes + descriptor }
    static func decode(_ c: inout ByteCursor) throws -> Self {
        try Self(collection: CollectionID(bytes: c.fixedBytes(16)), store: LocalStoreID(bytes: c.fixedBytes(16)), descriptor: c.fixedBytes(32))
    }
}

public struct LocalAssociationV1: Equatable, Sendable {
    public let id: LocalAssociationID
    public let scope: PrivateRecordScopeV1
    public let bookmark: PassivePlatformRecordV1
    public init(id: LocalAssociationID, scope: PrivateRecordScopeV1, bookmark: PassivePlatformRecordV1) throws {
        try privateSize(98 + UInt64(bookmark.bytes.count)); self.id = id; self.scope = scope; self.bookmark = bookmark
    }
    public func encodedV1() -> [UInt8] { privateHeader("NVASC1\r\n") + id.bytes + scope.encoded() + bookmark.encoded() }
    public static func decodeV1(_ bytes: [UInt8]) throws -> Self {
        var c = try privateCursor(bytes, magic: "NVASC1\r\n")
        let r = try Self(id: LocalAssociationID(bytes: c.fixedBytes(16)), scope: .decode(&c), bookmark: .decode(&c))
        try c.requireEnd(); return r
    }
}

public enum ObservedFilePresenceV1: UInt8, Sendable { case present = 1, absent = 2, unreadable = 3 }

/// Immutable retained file bytes and their separately captured decoded value and observations.
public struct PendingSnapshotV1: Equatable, Sendable {
    public let id: PendingSnapshotID
    public let scope: PrivateRecordScopeV1
    public let presence: ObservedFilePresenceV1
    public let path: ExactUTF8
    public let observation: PassivePlatformRecordV1
    public let source: [UInt8]
    public let value: PlaintextNoteValue
    public init(id: PendingSnapshotID, scope: PrivateRecordScopeV1, presence: ObservedFilePresenceV1,
                path: ExactUTF8, observation: PassivePlatformRecordV1, source: [UInt8], value: PlaintextNoteValue) throws {
        try privateSize(111 + UInt64(path.bytes.count + observation.bytes.count + source.count) + value.encodedByteCount)
        self.id = id; self.scope = scope; self.presence = presence; self.path = path
        self.observation = observation; self.source = source; self.value = value
    }
    public func encodedV1() -> [UInt8] {
        privateHeader("NVPAY1\r\n") + id.bytes + scope.encoded() + [presence.rawValue] + path.encodedV1()
        + observation.encoded() + privateBlob(source) + privateBlob(value.encodedV1())
    }
    public static func decodeV1(_ bytes: [UInt8]) throws -> Self {
        var c = try privateCursor(bytes, magic: "NVPAY1\r\n")
        let id = try PendingSnapshotID(bytes: c.fixedBytes(16)), scope = try PrivateRecordScopeV1.decode(&c)
        guard let presence = ObservedFilePresenceV1(rawValue: try c.byte()) else { throw CanonicalEncodingError.invalidDiscriminant }
        let r = try Self(id: id, scope: scope, presence: presence, path: c.text(), observation: .decode(&c),
                         source: c.lengthPrefixedBytes(), value: PlaintextNoteValue.decodeV1(c.lengthPrefixedBytes()))
        try c.requireEnd(); return r
    }
}

public enum PendingDecisionV1: UInt8, Sendable { case automaticImport = 1, explicitImport = 2, changedAssociation = 3, neutralAssociation = 4 }
/// Compact binding to a complete checked Current; its body stays in existing durable history.
public struct PendingNeutralStateV1: Equatable, Sendable {
    public let cellDigest: [UInt8]
    public let valueDigest: NoteValueDigest
    public init(cell: CurrentNoteCellV1) throws {
        cellDigest = Self.digest(cell)
        valueDigest = try cell.value.digestV1()
    }
    private init(cellDigest: [UInt8], valueDigest: NoteValueDigest) {
        self.cellDigest = cellDigest; self.valueDigest = valueDigest
    }
    public func matches(_ cell: CurrentNoteCellV1) throws -> Bool {
        try cellDigest == Self.digest(cell) && valueDigest == cell.value.digestV1()
    }
    private static func digest(_ cell: CurrentNoteCellV1) -> [UInt8] {
        Array(SHA256.hash(data: Array("NV pending Current\0v1\0".utf8) + cell.encodedV1()))
    }
    func encoded() -> [UInt8] { cellDigest + valueDigest.bytes }
    static func decode(_ c: inout ByteCursor) throws -> Self {
        try Self(cellDigest: c.fixedBytes(32), valueDigest: NoteValueDigest(bytes: c.fixedBytes(32)))
    }
}

public enum PendingExpectedEffectV1: Equatable, Sendable {
    case operation(id: OperationID, nonce: OperationNonce, action: ActionID, result: NoteValueDigest)
    case neutral(PendingNeutralStateV1)
}

/// Exact retry identity and frozen input for a prepared decision awaiting fresh applicability.
public struct PendingReservationV1: Equatable, Sendable {
    public let id: PendingReservationID
    public let snapshot: PendingSnapshotID
    public let decision: PendingDecisionV1
    public let birth: NoteBirth
    public let effect: PendingExpectedEffectV1
    public init(id: PendingReservationID, snapshot: PendingSnapshotID, decision: PendingDecisionV1,
                birth: NoteBirth, effect: PendingExpectedEffectV1) throws {
        switch effect {
        case .neutral:
            guard decision == .neutralAssociation else { throw CanonicalEncodingError.invalidReference }
        case .operation:
            guard decision != .neutralAssociation else { throw CanonicalEncodingError.invalidReference }
        }
        self.id = id; self.snapshot = snapshot; self.decision = decision; self.birth = birth; self.effect = effect
    }
    public func encodedV1() -> [UInt8] {
        let effectBytes: [UInt8]
        switch effect {
        case .operation(let id, let nonce, let action, let result): effectBytes = id.bytes + nonce.bytes + action.bytes + result.bytes
        case .neutral(let state): effectBytes = state.encoded()
        }
        return privateHeader("NVRSV1\r\n") + id.bytes + snapshot.bytes + [decision.rawValue] + birth.bytes + effectBytes
    }
    public static func decodeV1(_ bytes: [UInt8]) throws -> Self {
        var c = try privateCursor(bytes, magic: "NVRSV1\r\n")
        let id = try PendingReservationID(bytes: c.fixedBytes(16)), snapshot = try PendingSnapshotID(bytes: c.fixedBytes(16))
        guard let decision = PendingDecisionV1(rawValue: try c.byte()) else { throw CanonicalEncodingError.invalidDiscriminant }
        let birth = try NoteBirth(bytes: c.fixedBytes(16)), effect: PendingExpectedEffectV1
        if decision == .neutralAssociation { effect = .neutral(try .decode(&c)) }
        else { effect = try .operation(id: OperationID(bytes: c.fixedBytes(32)), nonce: OperationNonce(bytes: c.fixedBytes(16)),
                                      action: ActionID(bytes: c.fixedBytes(16)), result: NoteValueDigest(bytes: c.fixedBytes(32))) }
        try c.requireEnd(); return try Self(id: id, snapshot: snapshot, decision: decision, birth: birth, effect: effect)
    }
}

private func privateSize(_ count: UInt64) throws {
    guard count <= ObjectLimitsV1.decodedPayloadBytes else { throw CanonicalEncodingError.lengthLimit }
}
private func privateHeader(_ magic: String) -> [UInt8] { Array(magic.utf8) + bigEndianBytes(UInt16(1)) }
private func privateBlob(_ bytes: [UInt8]) -> [UInt8] { bigEndianBytes(UInt32(bytes.count)) + bytes }
private func privateBool(_ c: inout ByteCursor) throws -> Bool {
    let b = try c.byte(); guard b <= 1 else { throw CanonicalEncodingError.invalidDiscriminant }; return b == 1
}
private func privateCursor(_ bytes: [UInt8], magic: String) throws -> ByteCursor {
    try privateSize(UInt64(bytes.count)); var c = ByteCursor(bytes: bytes)
    guard try c.fixedBytes(8) == Array(magic.utf8), try c.unsigned16() == 1 else { throw CanonicalEncodingError.unsupportedFormat }
    return c
}
