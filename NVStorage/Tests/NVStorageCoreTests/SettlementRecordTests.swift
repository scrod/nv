import Foundation
import Testing
import NVStorageCore

private func settlementFixture(_ file: String, _ key: String) throws -> [UInt8] {
    let url = try #require(Bundle.module.url(forResource: file, withExtension: "json", subdirectory: "Fixtures"))
    let values = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    let chars = Array(try #require(values[key]))
    return try stride(from: 0, to: chars.count, by: 2).map { try #require(UInt8(String(chars[$0...$0+1]), radix: 16)) }
}

@Test(arguments: ["consumedSettlement", "neutralSettlement", "projectionSettlement"])
func pendingSettlementIndependentLayouts(_ key: String) throws {
    let bytes = try settlementFixture("private-records", key)
    let record = try PendingSettlementV1.decodeV1(bytes, profile: .plaintextFiles)
    #expect(try record.encodedV1() == bytes)
    #expect(record.item.bytes == Array(repeating: 12, count: 16))
    #expect(record.reservation.id.bytes == Array(repeating: 7, count: 16))
    #expect(record.reservation.snapshot.bytes == Array(repeating: 6, count: 16))
    #expect(record.scope.store.bytes == Array(repeating: 2, count: 16))
    #expect(record.subsequentSnapshot?.bytes == (key == "consumedSettlement" ? Array(repeating: 13, count: 16) : nil))
    if key == "projectionSettlement" {
        guard case .projection(let projection) = record.outcome else { Issue.record("lost physical outcome"); return }
        #expect(projection.relationshipGeneration == 11)
        #expect(projection.accepted.output.generation == 2 && projection.transition.source?.output.generation == 1)
        #expect(projection.sourceAccounting?.bytes == Array("source accounted".utf8))
        #expect(throws: CanonicalEncodingError.wrongScope) { try PendingSettlementV1.decodeV1(bytes, profile: .encryptedSegments) }
    } else {
        #expect(record.outcome == .consumed(try PassivePlatformRecordV1(codec: 1, bytes: Array("observed".utf8))))
        #expect(try PendingSettlementV1.decodeV1(bytes, profile: .encryptedSegments) == record)
    }
    for cut in bytes.indices { #expect(throws: (any Error).self) { try PendingSettlementV1.decodeV1(Array(bytes.prefix(cut)), profile: .plaintextFiles) } }
    #expect(throws: CanonicalEncodingError.trailingBytes) { try PendingSettlementV1.decodeV1(bytes + [0], profile: .plaintextFiles) }
    var unsupported = bytes; unsupported[9] = 2
    #expect(throws: CanonicalEncodingError.unsupportedFormat) { try PendingSettlementV1.decodeV1(unsupported, profile: .plaintextFiles) }
    #expect(throws: CanonicalEncodingError.invalidReference) {
        try PendingSettlementV1(scope: record.scope, item: record.item, reservation: record.reservation,
            outcome: record.outcome, subsequentSnapshot: record.reservation.snapshot)
    }
}

@Test func projectionSettlementTransfersExactFrozenOwners() throws {
    let settlement = try ProjectionSettlementV1.decodeV1(settlementFixture("projection-observations", "settlement"), profile: .plaintextFiles)
    #expect(try settlement.encodedV1() == settlementFixture("projection-observations", "settlement"))
    let newer = try ProjectionObservationsV1.decodeV1(settlementFixture("projection-observations", "newer"), profile: .plaintextFiles)
    let transferred = try settlement.transferringOwners(in: newer)
    #expect(transferred.accepted == settlement.accepted && transferred.frozen == nil)
    #expect(transferred.intended?.output.generation == 3)
    #expect(transferred.intended?.output == newer.intended?.output)
    #expect(transferred.intended?.source == settlement.accepted)
    #expect(transferred.ownedOutputs.map(\.generation) == [2, 3, 2])
    let current = try ProjectionObservationsV1.decodeV1(settlementFixture("projection-observations", "frozen"), profile: .plaintextFiles)
    let complete = try settlement.transferringOwners(in: current)
    #expect(complete.accepted == settlement.accepted && complete.intended == nil && complete.frozen == nil)
    #expect(throws: CanonicalEncodingError.invalidReference) { try settlement.transferringOwners(in: complete) }
    let unfrozen = try ProjectionObservationsV1.decodeV1(settlementFixture("projection-observations", "transition"), profile: .plaintextFiles)
    #expect(throws: CanonicalEncodingError.invalidReference) { try settlement.transferringOwners(in: unfrozen) }
    let wrongScope = try PrivateRecordScopeV1(collection: newer.scope.collection,
        store: LocalStoreID(bytes: Array(repeating: 99, count: 16)), descriptor: newer.scope.descriptor)
    let other = try ProjectionObservationsV1(profile: .plaintextFiles, scope: wrongScope, association: newer.association,
        birth: newer.birth, accepted: newer.accepted, intended: newer.intended, frozen: newer.frozen)
    #expect(throws: CanonicalEncodingError.wrongScope) { try settlement.transferringOwners(in: other) }
    let mismatch = try ProjectionObservationsV1(profile: .plaintextFiles, scope: newer.scope, association: newer.association,
        birth: newer.birth, accepted: nil, intended: newer.intended, frozen: newer.frozen)
    #expect(throws: CanonicalEncodingError.invalidReference) { try settlement.transferringOwners(in: mismatch) }
}

@Test func projectionSettlementRejectsIncompleteSourceAccounting() throws {
    let value = try ProjectionSettlementV1.decodeV1(settlementFixture("projection-observations", "settlement"), profile: .plaintextFiles)
    func make(_ generation: UInt64, _ accepted: AcceptedProjectionV1, _ accounting: PassivePlatformRecordV1?) throws -> ProjectionSettlementV1 {
        try .init(profile: .plaintextFiles, scope: value.scope, association: value.association,
            relationshipGeneration: generation, transition: value.transition, accepted: accepted, sourceAccounting: accounting)
    }
    #expect(throws: CanonicalEncodingError.invalidReference) { try make(11, value.accepted, nil) }
    #expect(throws: CanonicalEncodingError.invalidReference) { try make(0, value.accepted, value.sourceAccounting) }
    #expect(throws: CanonicalEncodingError.invalidReference) { try make(UInt64.max, value.accepted, value.sourceAccounting) }
    #expect(throws: CanonicalEncodingError.invalidReference) { try make(11, #require(value.transition.source), value.sourceAccounting) }
    let sourceFree = try IntendedProjectionV1(output: value.accepted.output, source: nil)
    let valid = try ProjectionSettlementV1(profile: .plaintextFiles, scope: value.scope, association: value.association,
        relationshipGeneration: 1, transition: sourceFree, accepted: value.accepted, sourceAccounting: nil)
    #expect(try ProjectionSettlementV1.decodeV1(valid.encodedV1(), profile: .plaintextFiles) == valid)
    #expect(throws: CanonicalEncodingError.invalidReference) {
        try ProjectionSettlementV1(profile: .plaintextFiles, scope: value.scope, association: value.association,
            relationshipGeneration: 1, transition: sourceFree, accepted: value.accepted, sourceAccounting: value.sourceAccounting)
    }
}
