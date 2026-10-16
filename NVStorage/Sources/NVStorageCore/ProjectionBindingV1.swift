/// Complete retained-history claim for an exact named plaintext output.
public struct ProjectionBindingV1: Equatable, Sendable {
    public let collection: CollectionID
    public let birth: NoteBirth
    public let descriptor: ProjectionDescriptorV1
    public let state: ProjectionStateReferenceV1
    public let dependencies: DependencyLocatorTable
    public let occurrences: [StoredOperationReferenceV1]
    let encodedByteCount: UInt64

    public init(profile: CollectionProfileV1, collection: CollectionID, birth: NoteBirth,
                descriptor: ProjectionDescriptorV1, state: ProjectionStateReferenceV1) throws {
        guard profile == .plaintextFiles else { throw CanonicalEncodingError.wrongScope }
        var occurrences: [StoredOperationReferenceV1] = []
        for ref in state.references {
            guard case .external(let locator, let index, let id) = ref else { throw CanonicalEncodingError.invalidReference }
            occurrences.append(.init(locator: locator, index: index, id: id))
        }
        if case .automatic(let source) = state {
            guard try source.key.birth() == birth else { throw CanonicalEncodingError.invalidReference }
        }
        dependencies = try DependencyLocatorTable(Array(Set(occurrences.map(\.locator))))
        let size = 50 + UInt64(descriptor.encodedV1().count) + UInt64(dependencies.entries.count) * 56 + state.encodedByteCount
        guard size <= ObjectLimitsV1.decodedPayloadBytes else { throw CanonicalEncodingError.lengthLimit }
        encodedByteCount = size
        self.collection = collection; self.birth = birth; self.descriptor = descriptor
        self.state = state; self.occurrences = occurrences
    }

    public func encodedV1() throws -> [UInt8] {
        let descriptorBytes = descriptor.encodedV1()
        return try Array("NVPBD1\r\n".utf8) + bigEndianBytes(UInt16(1)) + collection.bytes + birth.bytes
            + bigEndianBytes(UInt32(descriptorBytes.count)) + descriptorBytes + dependencies.encodedV1() + state.encoded(dependencies)
    }

    public static func decodeV1(_ bytes: [UInt8], profile: CollectionProfileV1) throws -> Self {
        guard UInt64(bytes.count) <= ObjectLimitsV1.decodedPayloadBytes else { throw CanonicalEncodingError.lengthLimit }
        var c = ByteCursor(bytes: bytes)
        guard try c.fixedBytes(8) == Array("NVPBD1\r\n".utf8), try c.unsigned16() == 1 else { throw CanonicalEncodingError.unsupportedFormat }
        let collection = try CollectionID(bytes: c.fixedBytes(16)), birth = try NoteBirth(bytes: c.fixedBytes(16))
        let descriptor = try ProjectionDescriptorV1.decodeV1(c.lengthPrefixedBytes(), profile: profile)
        let dependencies = try DependencyLocatorTable.decode(&c), tag = try c.byte()
        let state: ProjectionStateReferenceV1
        switch tag {
        case 1:
            guard case .external(let locator, let index, let id) = try OperationReference.decode(&c, dependencies: dependencies) else { throw CanonicalEncodingError.invalidReference }
            state = .revision(.init(locator: locator, index: index, id: id))
        case 2: state = try .automatic(.decode(&c, dependencies: dependencies))
        case 3, 4: state = try .derived(.decode(&c, dependencies: dependencies, earlierOperations: [], tag: tag))
        default: throw CanonicalEncodingError.invalidDiscriminant
        }
        try c.requireEnd()
        let result = try Self(profile: profile, collection: collection, birth: birth, descriptor: descriptor, state: state)
        guard result.dependencies == dependencies else { throw CanonicalEncodingError.noncanonicalSet }
        return result
    }

    /// Reconstructs source contents for comparison with the owner's checked current cell.
    public func reconstructedValue(operations: [OperationID: IdentifiedOperation]) throws -> PlaintextNoteValue {
        let sourceBirth: NoteBirth
        let claim: ActionStateV1
        switch state {
        case .revision(let ref): sourceBirth = birth; claim = .value(ref.id)
        case .derived(let derived): sourceBirth = birth; claim = .derived(derived.state)
        case .automatic(let source):
            sourceBirth = source.birth
            claim = try .automatic(source.expanded([]))
        }
        for ref in occurrences {
            guard let operation = operations[ref.id] else { throw CanonicalEncodingError.missingDependency }
            guard operation.id == ref.id, operation.effect.targetBirth == sourceBirth,
                  operation.effect.noteValue != nil else { throw CanonicalEncodingError.invalidReference }
        }
        if case .automatic(let source) = state {
            let id = try source.revision.expandedID(earlierOperations: [])
            guard let value = operations[id]?.effect.noteValue,
                  try AutomaticConflictKeyV1.compute(source: source.birth, value: value) == source.key else { throw CanonicalEncodingError.identityMismatch }
        }
        guard let value = try CompensationV1.value(claim, operations: operations) else { throw CanonicalEncodingError.invalidReference }
        return value
    }
}
