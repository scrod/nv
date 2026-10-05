import Testing
import NVStorageCore
@testable import NVStorageRuntime

@Test(arguments: [false, true])
func rejectedPrerequisitesRemainDistinctFromMissingAndInvalidDescendants(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let source = try await newSession(initial, protection)
    var receiver = try await newSession(initial, protection)
    let saved = try await put("independent", birth: NoteBirth(bytes: Array(repeating: 1, count: 16)), generation: 1, session: source)
    let good = try await source.retainedObject(at: saved.object)
    let p = try ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(good,
        collection: initial.descriptor.collection, protection: protection).payload)
    func seal(_ payload: [UInt8], _ writer: UInt8) throws -> ([UInt8], SegmentLocator) {
        let bytes = try ObjectEnvelopeV1.seal(payload: payload, kind: .changes,
            collection: initial.descriptor.collection, writer: WriterEpoch(bytes: Array(repeating: writer, count: 16)),
            sequence: 0, protection: protection)
        return (bytes, try ObjectEnvelopeV1.open(bytes, collection: initial.descriptor.collection, protection: protection).locator)
    }
    let future = try seal(Array("NVCHG1\r\n".utf8) + [0, 2], 81)
    let malformed = try seal([], 82)
    let missing = try seal([], 83)
    func child(_ parents: [SegmentLocator], _ writer: UInt8) throws -> ([UInt8], SegmentLocator) {
        let payload = try ChangesPayloadV1(dependencies: DependencyLocatorTable(p.dependencies.entries + parents),
            operations: p.operations, actions: p.actions)
        return try seal(payload.encodedV1(), writer)
    }
    let lower = try child([future.1, malformed.1, missing.1], 84)
    let upper = try child([lower.1, future.1], 85)
    guard case .waiting = try await receiver.receive(upper.0),
          case .waiting = try await receiver.receive(lower.0) else { Issue.record("descendants must park"); return }
    await #expect(throws: CanonicalEncodingError.unsupportedFormat) { try await receiver.receive(future.0) }
    await #expect(throws: CanonicalEncodingError.truncated) { try await receiver.receive(malformed.0) }
    let selection = await receiver.selection
    for round in 0..<2 {
        guard case .blocked(let roots, let unaccepted) = try await receiver.receivedObjectStatus(at: upper.1) else {
            Issue.record("transitive rejected prerequisite must be reported"); return
        }
        #expect(Set(roots.map(\.object)) == Set([future.1.segmentID, malformed.1.segmentID]))
        #expect(roots.first { $0.object == future.1.segmentID }?.reason == .unsupportedFormat)
        #expect(roots.first { $0.object == malformed.1.segmentID }?.reason == .truncated)
        #expect(Set(unaccepted) == Set([lower.1, future.1].map(ObjectRequirement.acceptedHistory)))
        guard case .blocked(_, let direct) = try await receiver.receive(lower.0) else {
            Issue.record("repeated blocked receive must keep its diagnostic"); return
        }
        #expect(Set(direct) == Set([future.1, malformed.1, missing.1].map(ObjectRequirement.acceptedHistory)))
        let lane = await receiver.lane
        let state = try await lane.perform { db in
            (try db.rows("SELECT object_id FROM rejected_objects"),
             try db.rows("SELECT object_id FROM ready_objects"),
             try db.rows("SELECT encoded FROM objects WHERE object_id=?", [.blob(upper.1.segmentID.bytes)]),
             try db.rows("SELECT encoded FROM objects WHERE object_id=?", [.blob(lower.1.segmentID.bytes)]))
        }
        #expect(state.0.count == 2)
        #expect(state.1.isEmpty)
        #expect(state.2 == [[.blob(upper.0)]] && state.3 == [[.blob(lower.0)]])
        #expect(try await receiver.snapshot().through == 1)
        if round == 0 {
            try await receiver.quiesce()
            receiver = try await LocalStoreSession.open(selection: selection, protection: protection)
        }
    }
    _ = try await receiver.receive(good)
    #expect(try await receiver.snapshot().notes.map(\.value.body.string).sorted() == ["independent", "untouched"])
    #expect(try await receiver.snapshot().through == 2)
    let wrong = SegmentLocator(writerEpoch: try WriterEpoch(bytes: Array(repeating: 99, count: 16)),
        sequence: upper.1.sequence, segmentID: upper.1.segmentID)
    await #expect(throws: CanonicalEncodingError.invalidReference) { try await receiver.receivedObjectStatus(at: wrong) }
    try await receiver.quiesce(); try await source.quiesce()
}
