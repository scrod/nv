import Crypto
import Foundation
import Testing
@testable import NVStorageCore

private func transportLiterals() throws -> [String: [UInt8]] {
    let url = try #require(Bundle.module.url(forResource: "projection-transport", withExtension: "json", subdirectory: "Fixtures"))
    let strings = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    return strings.mapValues { text in
        let chars = Array(text)
        return stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0+1]), radix: 16)! }
    }
}

@Test func projectionTransportIndependentBytesAndCanonicalAbsence() throws {
    let literal = try transportLiterals(), bytes = try #require(literal["payload"]), absent = try #require(literal["absent"])
    let binding = try ProjectionBindingV1.decodeV1(#require(literal["binding"]), profile: .plaintextFiles)
    let payload = try ChangesPayloadV1(dependencies: binding.dependencies, operations: [], actions: [], projections: [binding])
    #expect(try payload.encodedV1() == bytes)
    #expect(try ChangesPayloadV1.decodeV1(bytes) == payload)
    #expect(try ChangesPayloadV1.decodeV1(absent).projections.isEmpty)
    let envelope = try ObjectEnvelopeV1.seal(payload: bytes, kind: .changes, collection: binding.collection,
        writer: WriterEpoch(bytes: Array(repeating: 9, count: 16)), sequence: 8, protection: .publicHash)
    #expect(envelope == literal["envelope"])
    let opened = try ObjectEnvelopeV1.open(envelope, collection: binding.collection, protection: .publicHash)
    #expect(opened.locator.segmentID.bytes == literal["segment_id"])
    #expect(try ChangesPayloadV1.decodeV1(opened) == payload)
    for n in bytes.indices where n != absent.count {
        #expect(throws: (any Error).self) { try ChangesPayloadV1.decodeV1(Array(bytes.prefix(n))) }
    }
    #expect(throws: CanonicalEncodingError.trailingBytes) { try ChangesPayloadV1.decodeV1(bytes + [0]) }
    #expect(throws: CanonicalEncodingError.noncanonicalSet) {
        try ChangesPayloadV1.decodeV1(absent + Array("NVPRJ1\r\n".utf8) + [0, 0, 0, 0])
    }
    #expect(throws: CanonicalEncodingError.noncanonicalSet) {
        try ChangesPayloadV1(dependencies: binding.dependencies, operations: [], actions: [], projections: [binding, binding])
    }
    #expect(throws: CanonicalEncodingError.invalidReference) {
        try ChangesPayloadV1(dependencies: DependencyLocatorTable([]), operations: [], actions: [], projections: [binding])
    }
}

@Test(arguments: [false, true])
func projectionTransportChecksAuthenticatedContext(_ encrypted: Bool) throws {
    let literal = try transportLiterals(), payload = try #require(literal["payload"])
    let collection = try CollectionID(bytes: Array(repeating: 1, count: 16))
    let protection: ObjectProtectionV1 = encrypted ? try .encrypted(keyID: CollectionKeyID(bytes: Array(repeating: 2, count: 16)),
        key: SymmetricKey(data: Array(repeating: UInt8(3), count: 32))) : .publicHash
    for foreign in [false, true] {
        let target = try foreign ? CollectionID(bytes: Array(repeating: 4, count: 16)) : collection
        let envelope = try ObjectEnvelopeV1.seal(payload: payload, kind: .changes, collection: target,
            writer: WriterEpoch(bytes: Array(repeating: 9, count: 16)), sequence: 8, protection: protection)
        let opened = try ObjectEnvelopeV1.open(envelope, collection: target, protection: protection)
        if encrypted || foreign {
            #expect(throws: CanonicalEncodingError.wrongScope) { try ChangesPayloadV1.decodeV1(opened) }
        } else { #expect(try ChangesPayloadV1.decodeV1(opened).projections.count == 1) }
    }
}

@Test(arguments: [false, true])
func projectionTransportChecksDerivedSourceAndPreservesLogicalIdentity(_ equal: Bool) async throws {
    let f = try DerivedFixture(equal: equal), source = try f.payload(), claim = try f.claim(equal: equal)
    let expected = equal ? "A\ngap\nz" : "A\ngap\nZ"
    let descriptor = try ProjectionDescriptorV1(profile: .plaintextFiles,
        filename: .init(ExactUTF8(bytes: Array("Note.txt".utf8))), format: .plaintext, digest: .compute(Array(expected.utf8)))
    let binding = try ProjectionBindingV1(profile: .plaintextFiles, collection: f.graph.collection,
        birth: f.graph.birth, descriptor: descriptor, state: .derived(claim))
    let withDescription = try ChangesPayloadV1(dependencies: DependencyLocatorTable(source.dependencies.entries + [f.source]),
        operations: source.operations, actions: source.actions, projections: [binding])
    #expect(withDescription.operations == source.operations && withDescription.actions == source.actions)
    #expect(try withDescription.encodedV1() != source.encodedV1())
    var reads = 0
    #expect(try binding.validateSource(enclosing: f.enclosing) { _ in reads += 1; return source }.body.string == expected)
    #expect(reads == 1)
    #expect(try await binding.validateSource(enclosing: f.enclosing, resolve: { _ async in source }).body.string == expected)
    #expect(throws: CanonicalEncodingError.missingDependency) { try binding.validateSource(enclosing: f.enclosing, resolve: { _ in nil }) }
    #expect(throws: CanonicalEncodingError.invalidReference) { try binding.validateSource(enclosing: f.source, resolve: { _ in source }) }
    let wrong = try DerivedStateReferenceV1(kind: claim.kind, inputs: claim.inputReferences,
        result: NoteValueDigest(bytes: Array(repeating: 90, count: 32)), earlierOperations: [])
    let forged = try ProjectionBindingV1(profile: .plaintextFiles, collection: binding.collection, birth: binding.birth,
        descriptor: descriptor, state: .derived(wrong))
    #expect(throws: CanonicalEncodingError.identityMismatch) { try forged.validateSource(enclosing: f.enclosing, resolve: { _ in source }) }
}

@Test func projectionTransportValidatesCompleteOversizedSource() throws {
    let f = try DerivedFixture(), original = try f.payload()
    var records = [original.operations[0]], actions = [original.actions[0]]
    let heads = try (1...100).map { try f.graph.operation(UInt8($0 + 10), "same", parents: [f.base]) }
    let parent = OperationReference.earlierLocal(index: OperationIndex(0))
    for operation in heads {
        let index = OperationIndex(UInt32(records.count)), earlier = records.map(\.operation)
        records.append(try .init(operation: operation, causalReferences: [parent], noteReferences: [parent], earlierOperations: earlier))
        let id = try #require(operation.effect.actionID)
        actions.append(try .init(id: id, origin: ActionOriginID(bytes: id.bytes), previousOrigin: nil, scope: .note(f.graph.birth),
            scopeParents: [], kind: .savedEdit, members: [index], affected: [.init(birth: f.graph.birth, before: .value(parent), after: .value(.earlierLocal(index: index)))],
            operations: records.map(\.operation), earlierActions: actions.map(\.action)))
    }
    let source = try ChangesPayloadV1(dependencies: original.dependencies, operations: records, actions: actions)
    let value = try #require(heads[0].effect.noteValue)
    let references = heads.enumerated().map { OperationReference.external(locator: f.source, index: OperationIndex(UInt32($0.offset + 1)), expectedID: $0.element.id) }
    let state = try ProjectionStateReferenceV1.derived(.init(kind: .equal, inputs: references, result: value.digestV1(), earlierOperations: []))
    let descriptor = try ProjectionDescriptorV1(profile: .plaintextFiles, filename: .init(ExactUTF8(bytes: Array("Wide.txt".utf8))), format: .plaintext, digest: .compute(value.body.bytes))
    let binding = try ProjectionBindingV1(profile: .plaintextFiles, collection: f.graph.collection, birth: f.graph.birth, descriptor: descriptor, state: state)
    let payload = try ChangesPayloadV1(dependencies: binding.dependencies, operations: [], actions: [], projections: [binding])
    #expect(try ProjectionStampV1.prepare(profile: .plaintextFiles, collection: binding.collection, birth: binding.birth,
        format: descriptor.format, digest: descriptor.digest, state: state) == .omittedOversized)
    let decoded = try ChangesPayloadV1.decodeV1(payload.encodedV1())
    #expect(decoded.projections[0].occurrences.count == 100)
    var reads = 0
    try decoded.checkExternalReferences(at: f.enclosing) { locator in
        reads += 1; return locator == f.source ? source : nil
    }
    #expect(reads == 1)
    #expect(try binding.validateSource(enclosing: f.enclosing, resolve: { _ in source }).body.string == "same")
}
