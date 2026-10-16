import Foundation
import Testing
@testable import NVStorageCore

private func observationLiterals() throws -> [String: [UInt8]] {
    let url = try #require(Bundle.module.url(forResource: "projection-observations", withExtension: "json", subdirectory: "Fixtures"))
    let strings = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    return strings.mapValues { text in
        let chars = Array(text)
        return stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0+1]), radix: 16)! }
    }
}

@Test func projectionSourceAttemptIndependentLayout() throws {
    let literals = try observationLiterals(), bytes = try #require(literals["source_attempt"])
    let prior = try ProjectionObservationsV1.decodeV1(#require(literals["present_empty"]), profile: .plaintextFiles)
    let source = try #require(prior.accepted), occurrence = try #require(source.output.binding.occurrences.first)
    let expected = try ProjectionSourceAttemptV1(profile: .plaintextFiles, scope: prior.scope, association: prior.association,
        attempt: .init(bytes: [7,7,7,7,7,7,71,7,135,7,7,7,7,7,7,7]),
        deletion: .init(locator: occurrence.locator, index: ActionIndex(2), id: .init(bytes: Array(repeating: 12, count: 16))),
        source: source, root: .init(codec: 1, bytes: Array("root".utf8)), observation: .init(codec: 1, bytes: Array("fresh source".utf8)))
    let decoded = try ProjectionSourceAttemptV1.decodeV1(bytes, profile: .plaintextFiles)
    #expect(decoded == expected && decoded.birth == source.output.binding.birth)
    #expect(try expected.encodedV1() == bytes)
    #expect(decoded.recoveryName == ".nv-source-07070707070747078707070707070707.backup")
    for n in bytes.indices {
        #expect(throws: (any Error).self) { try ProjectionSourceAttemptV1.decodeV1(Array(bytes.prefix(n)), profile: .plaintextFiles) }
    }
    #expect(throws: CanonicalEncodingError.trailingBytes) { try ProjectionSourceAttemptV1.decodeV1(bytes + [0], profile: .plaintextFiles) }
    #expect(throws: CanonicalEncodingError.wrongScope) { try ProjectionSourceAttemptV1.decodeV1(bytes, profile: .encryptedSegments) }
    var unsupported = bytes; unsupported[9] = 2
    #expect(throws: CanonicalEncodingError.unsupportedFormat) { try ProjectionSourceAttemptV1.decodeV1(unsupported, profile: .plaintextFiles) }
    var excessive = bytes; excessive.replaceSubrange(182..<186, with: [255,255,255,255])
    #expect(throws: CanonicalEncodingError.lengthLimit) { try ProjectionSourceAttemptV1.decodeV1(excessive, profile: .plaintextFiles) }
    let wrong = try PrivateRecordScopeV1(collection: .init(bytes: Array(repeating: 8, count: 16)), store: prior.scope.store, descriptor: prior.scope.descriptor)
    #expect(throws: CanonicalEncodingError.wrongScope) {
        try ProjectionSourceAttemptV1(profile: .plaintextFiles, scope: wrong, association: prior.association,
            attempt: decoded.attempt, deletion: decoded.deletion, source: source, root: decoded.root, observation: decoded.observation)
    }
    #expect(throws: (any Error).self) { try ProjectionSourceAttemptID(bytes: [1]) }
}

@Test(arguments: ["replacement_attempt", "relocation_attempt"])
func projectionReplacementAttemptIndependentLayout(_ name: String) throws {
    let literals = try observationLiterals(), bytes = try #require(literals[name])
    let previous = try ProjectionObservationsV1.decodeV1(#require(literals["frozen"]), profile: .plaintextFiles)
    let decoded = try ProjectionReplacementAttemptV1.decodeV1(bytes, profile: .plaintextFiles)
    let id: [UInt8] = [7,7,7,7,7,7,71,7,135,7,7,7,7,7,7,7]
    let frozen = try #require(previous.frozen)
    let descriptor = frozen.output.binding.descriptor
    let binding = try ProjectionBindingV1(profile: .plaintextFiles, collection: frozen.output.binding.collection,
        birth: frozen.output.binding.birth,
        descriptor: .init(profile: .plaintextFiles, filename: .init(ExactUTF8(bytes: Array((name == "relocation_attempt" ? "Renamed.txt" : "Note.txt").utf8))),
            format: descriptor.format, digest: descriptor.digest), state: frozen.output.binding.state)
    let transition = try IntendedProjectionV1(output: .init(generation: frozen.output.generation, encoding: frozen.output.encoding, binding: binding), source: frozen.source)
    let expected = try ProjectionReplacementAttemptV1(profile: .plaintextFiles, scope: previous.scope,
        association: previous.association, attempt: .init(bytes: id), transition: transition,
        root: .init(codec: 1, bytes: Array("root".utf8)), source: .init(codec: 1, bytes: Array("fresh source".utf8)))
    #expect(decoded == expected)
    #expect(try expected.encodedV1() == bytes)
    #expect(decoded.backupName == ".nv-replacement-07070707070747078707070707070707.backup")
    #expect(decoded.transition.source == previous.accepted && decoded.transition.output.generation == 2)
    #expect(decoded.operation == (name == "relocation_attempt" ? .relocation : .replacement))
    for n in bytes.indices {
        #expect(throws: (any Error).self) { try ProjectionReplacementAttemptV1.decodeV1(Array(bytes.prefix(n)), profile: .plaintextFiles) }
    }
    #expect(throws: CanonicalEncodingError.trailingBytes) { try ProjectionReplacementAttemptV1.decodeV1(bytes + [0], profile: .plaintextFiles) }
    #expect(throws: CanonicalEncodingError.wrongScope) { try ProjectionReplacementAttemptV1.decodeV1(bytes, profile: .encryptedSegments) }
    var unsupported = bytes; unsupported[9] = 2
    #expect(throws: CanonicalEncodingError.unsupportedFormat) { try ProjectionReplacementAttemptV1.decodeV1(unsupported, profile: .plaintextFiles) }
    var excessive = bytes; excessive.replaceSubrange(106..<110, with: [255,255,255,255])
    #expect(throws: CanonicalEncodingError.lengthLimit) { try ProjectionReplacementAttemptV1.decodeV1(excessive, profile: .plaintextFiles) }
}

@Test func projectionReplacementAttemptRequiresSourceAndDerivesOperation() throws {
    let original = try ProjectionReplacementAttemptV1.decodeV1(#require(observationLiterals()["replacement_attempt"]), profile: .plaintextFiles)
    func record(_ transition: IntendedProjectionV1, scope: PrivateRecordScopeV1? = nil, attempt: [UInt8]? = nil) throws -> ProjectionReplacementAttemptV1 {
        try .init(profile: .plaintextFiles, scope: scope ?? original.scope, association: original.association,
                  attempt: .init(bytes: attempt ?? original.attempt.bytes), transition: transition, root: original.root, source: original.source)
    }
    let creation = try IntendedProjectionV1(output: original.transition.output, source: nil)
    #expect(throws: CanonicalEncodingError.invalidReference) { try record(creation) }
    let old = original.transition.output, descriptor = old.binding.descriptor
    let renamed = try ProjectionBindingV1(profile: .plaintextFiles, collection: old.binding.collection, birth: old.binding.birth,
        descriptor: .init(profile: .plaintextFiles, filename: .init(ExactUTF8(bytes: Array("Renamed.txt".utf8))),
            format: descriptor.format, digest: descriptor.digest), state: old.binding.state)
    let move = try IntendedProjectionV1(output: .init(generation: old.generation, encoding: old.encoding, binding: renamed), source: original.transition.source)
    #expect(try record(move).operation == .relocation)
    #expect(try record(original.transition).operation == .replacement)
    let wrong = try PrivateRecordScopeV1(collection: .init(bytes: Array(repeating: 8, count: 16)), store: original.scope.store, descriptor: original.scope.descriptor)
    #expect(throws: CanonicalEncodingError.wrongScope) { try record(original.transition, scope: wrong) }
    #expect(throws: (any Error).self) { try record(original.transition, attempt: [1]) }
}

@Test(arguments: ["empty", "absent", "present_empty", "transition", "frozen", "newer"])
func projectionObservationsIndependentLayouts(_ name: String) throws {
    let literals = try observationLiterals(), bytes = try #require(literals[name])
    let binding = try ProjectionBindingV1.decodeV1(#require(literals["binding"]), profile: .plaintextFiles)
    #expect(binding.collection.bytes == Array(repeating: 1, count: 16))
    #expect(binding.descriptor.filename.spelling.string == "Note.txt")
    #expect(binding.descriptor.digest == .compute(Array("A\r\nZ".utf8)))
    #expect(binding.occurrences.count == 1 && binding.occurrences[0].index == OperationIndex(3))
    #expect(try binding.encodedV1() == literals["binding"])
    let output = try ProjectionOutputV1(generation: 1, encoding: .utf8, binding: binding)
    let present = try PassivePlatformRecordV1(codec: 1, bytes: []), physical = try PassivePlatformRecordV1(codec: 1, bytes: Array("physical".utf8))
    let raw = name == "absent" ? nil : present
    let accepted = try AcceptedProjectionV1(output: output, physical: physical, encoding: raw, tags: raw, created: raw, modified: raw)
    let intended = try IntendedProjectionV1(output: .init(generation: 2, encoding: .utf8, binding: binding), source: accepted)
    let latest = try IntendedProjectionV1(output: .init(generation: 3, encoding: .utf8, binding: binding), source: accepted)
    let expected = try ProjectionObservationsV1(profile: .plaintextFiles,
        scope: .init(collection: binding.collection, store: LocalStoreID(bytes: Array(repeating: 4, count: 16)), descriptor: Array(repeating: 5, count: 32)),
        association: LocalAssociationID(bytes: Array(repeating: 6, count: 16)), birth: binding.birth,
        accepted: name == "empty" ? nil : accepted,
        intended: name == "newer" ? latest : ["transition", "frozen"].contains(name) ? intended : nil,
        frozen: ["frozen", "newer"].contains(name) ? intended : nil)
    let decoded = try ProjectionObservationsV1.decodeV1(bytes, profile: .plaintextFiles)
    #expect(decoded == expected)
    #expect(try expected.encodedV1() == bytes)
    for n in bytes.indices {
        #expect(throws: (any Error).self) { try ProjectionObservationsV1.decodeV1(Array(bytes.prefix(n)), profile: .plaintextFiles) }
    }
    #expect(throws: CanonicalEncodingError.trailingBytes) { try ProjectionObservationsV1.decodeV1(bytes + [0], profile: .plaintextFiles) }
    #expect(throws: CanonicalEncodingError.wrongScope) { try ProjectionObservationsV1.decodeV1(bytes, profile: .encryptedSegments) }
}

@Test func projectionFrozenOwnershipRejectsContradictoryGenerations() throws {
    let state = try ProjectionObservationsV1.decodeV1(#require(observationLiterals()["frozen"]), profile: .plaintextFiles)
    let accepted = try #require(state.accepted), frozen = try #require(state.frozen)
    func record(_ intended: IntendedProjectionV1?, _ held: IntendedProjectionV1?) throws -> ProjectionObservationsV1 {
        try .init(profile: .plaintextFiles, scope: state.scope, association: state.association, birth: state.birth,
                  accepted: accepted, intended: intended, frozen: held)
    }
    #expect(state.ownedOutputs.count == 5)
    #expect(throws: CanonicalEncodingError.invalidReference) { try record(nil, frozen) }
    let past = try IntendedProjectionV1(output: accepted.output, source: nil)
    #expect(throws: CanonicalEncodingError.invalidReference) { try record(frozen, past) }
    let future = try IntendedProjectionV1(output: .init(generation: 3, encoding: .utf8, binding: frozen.output.binding), source: accepted)
    #expect(throws: CanonicalEncodingError.invalidReference) { try record(frozen, future) }
    let different = try IntendedProjectionV1(output: .init(generation: 2, encoding: .captured(encoding: .init(rawValue: 10), byteCount: 3), binding: frozen.output.binding), source: accepted)
    #expect(throws: CanonicalEncodingError.invalidReference) { try record(frozen, different) }
    let wrongBirth = try ProjectionBindingV1(profile: .plaintextFiles, collection: state.scope.collection,
        birth: NoteBirth(bytes: Array(repeating: 99, count: 16)), descriptor: frozen.output.binding.descriptor, state: frozen.output.binding.state)
    let foreign = try IntendedProjectionV1(output: .init(generation: 2, encoding: .utf8, binding: wrongBirth), source: nil)
    #expect(throws: CanonicalEncodingError.wrongScope) { try record(frozen, foreign) }
}

@Test func projectionObservationsRejectWrongScopeAndOrdering() throws {
    let bytes = try #require(observationLiterals()["transition"])
    let state = try ProjectionObservationsV1.decodeV1(bytes, profile: .plaintextFiles)
    let accepted = try #require(state.accepted), intended = try #require(state.intended)
    #expect(throws: CanonicalEncodingError.invalidReference) { try IntendedProjectionV1(output: accepted.output, source: accepted) }
    #expect(throws: CanonicalEncodingError.invalidPayload) { try ProjectionOutputV1(generation: 0, encoding: .utf8, binding: accepted.output.binding) }
    #expect(throws: CanonicalEncodingError.invalidPayload) { try ProjectionOutputV1(generation: UInt64.max, encoding: .utf8, binding: accepted.output.binding) }
    #expect(throws: CanonicalEncodingError.wrongScope) {
        try ProjectionObservationsV1(profile: .plaintextFiles, scope: state.scope, association: state.association,
            birth: NoteBirth(bytes: Array(repeating: 3, count: 16)), accepted: accepted, intended: intended)
    }
    var bad = bytes; bad[9] = 99
    #expect(throws: CanonicalEncodingError.unsupportedFormat) { try ProjectionObservationsV1.decodeV1(bad, profile: .plaintextFiles) }
    bad = bytes; bad[106] = 2
    #expect(throws: CanonicalEncodingError.invalidDiscriminant) { try ProjectionObservationsV1.decodeV1(bad, profile: .plaintextFiles) }
    bad = bytes; bad.replaceSubrange(107..<111, with: [255,255,255,255])
    #expect(throws: CanonicalEncodingError.lengthLimit) { try ProjectionObservationsV1.decodeV1(bad, profile: .plaintextFiles) }
    let wrongCollection = try PrivateRecordScopeV1(collection: CollectionID(bytes: Array(repeating: 9, count: 16)), store: state.scope.store, descriptor: state.scope.descriptor)
    #expect(throws: CanonicalEncodingError.wrongScope) {
        try ProjectionObservationsV1(profile: .plaintextFiles, scope: wrongCollection, association: state.association,
            birth: state.birth, accepted: accepted, intended: nil)
    }
}

@Test(arguments: [false, true])
func projectionBindingReconstructsDerivedAndRetainsWideSources(equal: Bool) async throws {
    let f = try DerivedFixture(equal: equal), claim = try f.claim(equal: equal)
    let value = try await f.reconstruct(claim).value.value
    let descriptor = try ProjectionDescriptorV1(profile: .plaintextFiles, filename: .init(ExactUTF8(bytes: Array("Note.txt".utf8))), format: .plaintext, digest: .compute(value.body.bytes))
    let binding = try ProjectionBindingV1(profile: .plaintextFiles, collection: f.graph.collection, birth: f.graph.birth,
        descriptor: descriptor, state: .derived(claim))
    let records = Dictionary(uniqueKeysWithValues: f.history.map { ($0.id, $0) })
    #expect(try binding.reconstructedValue(operations: records) == value)
    #expect(throws: CanonicalEncodingError.missingDependency) { try binding.reconstructedValue(operations: [:]) }
    let bytes = try binding.encodedV1()
    #expect(try ProjectionBindingV1.decodeV1(bytes, profile: .plaintextFiles) == binding)
    for n in bytes.indices { #expect(throws: (any Error).self) { try ProjectionBindingV1.decodeV1(Array(bytes.prefix(n)), profile: .plaintextFiles) } }
    #expect(throws: CanonicalEncodingError.wrongScope) { try ProjectionBindingV1.decodeV1(bytes, profile: .encryptedSegments) }
    let wideHistory = try (1...100).map { try f.graph.operation(UInt8($0 + 10), "same", parents: [f.base]) }
    let wideValue = try #require(wideHistory[0].effect.noteValue)
    let refs = wideHistory.enumerated().map { index, operation in
        OperationReference.external(locator: f.source, index: .init(UInt32(index)), expectedID: operation.id)
    }
    let wide = try ProjectionStateReferenceV1.derived(.init(kind: .equal, inputs: refs, result: wideValue.digestV1(), earlierOperations: []))
    let durable = try ProjectionBindingV1(profile: .plaintextFiles, collection: f.graph.collection, birth: f.graph.birth, descriptor: descriptor, state: wide)
    #expect(try durable.encodedV1().count > 4096)
    #expect(try ProjectionBindingV1.decodeV1(durable.encodedV1(), profile: .plaintextFiles).occurrences.count == 100)
    #expect(try durable.reconstructedValue(operations: Dictionary(uniqueKeysWithValues: wideHistory.map { ($0.id, $0) })) == wideValue)
    #expect(try ProjectionStampV1.prepare(profile: .plaintextFiles, collection: f.graph.collection, birth: f.graph.birth,
        format: .plaintext, digest: descriptor.digest, state: wide) == .omittedOversized)
}
