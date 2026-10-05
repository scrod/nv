import Foundation
import NVStorageCore
import Testing

private func literalRecords() throws -> [String: [UInt8]] {
    let path = try #require(Bundle.module.url(forResource: "connected-records", withExtension: "json", subdirectory: "Fixtures"))
    let values = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: path))
    return try values.mapValues { text in
        let chars = Array(text)
        return try stride(from: 0, to: chars.count, by: 2).map { try #require(UInt8(String(chars[$0...$0+1]), radix: 16)) }
    }
}

@Test func connectedRecordLiteralLayoutsAndIdentities() throws {
    let fixtures = try literalRecords()
    let source = try NoteBirth(bytes: Array(repeating: 3, count: 16)), actionID = try ActionID(bytes: Array(repeating: 2, count: 16))
    let value = try PlaintextNoteValue(title: ExactUTF8(bytes: [84]), body: ExactUTF8(bytes: [104,105]), labels: CanonicalLabels([]), created: DisplayDate(secondsSinceReferenceDate: 0), modified: DisplayDate(secondsSinceReferenceDate: 1))
    let key = try ConflictRecoveryKeyV1.compute(source: source, body: value.body), automatic = try AutomaticConflictKeyV1.compute(source: source, value: value)
    #expect(key.bytes == fixtures["key"] && automatic.bytes == fixtures["automaticKey"])
    #expect(try key.birth(slot: 0).bytes == fixtures["slotBirth"])
    #expect(try automatic.birth().bytes == fixtures["automaticBirth"])
    let locator = SegmentLocator(writerEpoch: try WriterEpoch(bytes: Array(repeating: 9, count: 16)), sequence: 0, segmentID: try SegmentID(bytes: Array(repeating: 10, count: 32)))
    let dependencies = try DependencyLocatorTable([locator])
    for name in ["copyOperation", "retireOperation", "adoptOperation"] {
        let bytes = try #require(fixtures[name])
        let op = try OperationRecordV1.decodeV1(bytes, dependencies: dependencies, earlierOperations: [])
        #expect(try op.encodedV1(dependencies: dependencies, earlierOperations: []) == bytes)
        #expect(op.operation.effect.actionID == actionID)
        var changed = bytes; changed[0] ^= 1
        #expect(throws: CanonicalEncodingError.identityMismatch) { try OperationRecordV1.decodeV1(changed, dependencies: dependencies, earlierOperations: []) }
        for cut in bytes.indices { #expect(throws: (any Error).self) { try OperationRecordV1.decodeV1(Array(bytes.prefix(cut)), dependencies: dependencies, earlierOperations: []) } }
    }
    let nonce = try OperationNonce(bytes: Array(repeating: 1, count: 16)), causal = try CausalParentSet([OperationID(bytes: Array(repeating: 6, count: 32))])
    for name in ["historical", "choice", "copy", "undo", "redo", "native", "automaticBefore"] {
        let bytes = try #require(fixtures[name])
        let effect: OperationEffectV1
        if name == "copy" {
            effect = .recoverCopy(action: actionID, birth: try key.birth(slot: 0), source: .init(birth: source, revision: try OperationID(bytes: Array(repeating: 7, count: 32)), key: key, slot: 0, reused: nil), value: value)
        } else if name == "automaticBefore" {
            let op = try OperationRecordV1.decodeV1(#require(fixtures["adoptOperation"]), dependencies: dependencies, earlierOperations: [])
            effect = op.operation.effect
        } else { effect = .put(action: actionID, birth: source, value: value) }
        let predecessors = try NotePredecessorSet(effect.tagForTest == 5 ? [OperationID(bytes: Array(repeating: 7, count: 32))] : [])
        let op = try IdentifiedOperation(nonce: nonce, effect: effect, causalParents: causal, notePredecessors: predecessors)
        let record = try ActionRecordV1.decodeV1(bytes, dependencies: dependencies, operations: [op], earlierActions: [])
        #expect(try record.encodedV1(dependencies: dependencies, operations: [op], earlierActions: []) == bytes)
        #expect(record.action.id == actionID && record.action.members == [op.id])
        for cut in bytes.indices { #expect(throws: (any Error).self) { try ActionRecordV1.decodeV1(Array(bytes.prefix(cut)), dependencies: dependencies, operations: [op], earlierActions: []) } }
        #expect(throws: CanonicalEncodingError.trailingBytes) { try ActionRecordV1.decodeV1(bytes + [0], dependencies: dependencies, operations: [op], earlierActions: []) }
    }
}
private extension OperationEffectV1 {
    var tagForTest: UInt8 { if case .put = self { 5 } else { 0 } }
}

@Test func canonicalRecoveryKeysExcludePresentationAndRetainSource() throws {
    let source = try NoteBirth(bytes: Array(repeating: 3, count: 16)), other = try NoteBirth(bytes: Array(repeating: 4, count: 16))
    let first = try ExactUTF8(bytes: Array("e\u{301}".utf8)), second = try ExactUTF8(bytes: Array("é".utf8))
    #expect(try ConflictRecoveryKeyV1.compute(source: source, body: first) == ConflictRecoveryKeyV1.compute(source: source, body: second))
    #expect(try ConflictRecoveryKeyV1.compute(source: source, body: first) != ConflictRecoveryKeyV1.compute(source: other, body: first))
}
