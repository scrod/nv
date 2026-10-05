import Foundation
import NVStorageCore
import Testing

@Test func literalRestorationActionAndCanonicalSources() throws {
    let file = try #require(Bundle.module.url(forResource: "restoration", withExtension: "json", subdirectory: "Fixtures"))
    let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
    let s = Array(try #require(fixture["action"]))
    let bytes = stride(from: 0, to: s.count, by: 2).map { UInt8(String(s[$0...$0+1]), radix: 16)! }
    let locator = SegmentLocator(writerEpoch: try WriterEpoch(bytes: Array(repeating: 9, count: 16)), sequence: 0,
        segmentID: try SegmentID(bytes: Array(repeating: 10, count: 32)))
    let dependencies = try DependencyLocatorTable([locator])
    let a = try ActionID(bytes: Array(repeating: 2, count: 16)), b = try NoteBirth(bytes: Array(repeating: 3, count: 16))
    let value = try PlaintextNoteValue(title: ExactUTF8(bytes: [84]), body: ExactUTF8(bytes: [104, 105]),
        labels: CanonicalLabels([]), created: DisplayDate(secondsSinceReferenceDate: 0), modified: DisplayDate(secondsSinceReferenceDate: 1))
    let op = try IdentifiedOperation(nonce: OperationNonce(bytes: Array(repeating: 1, count: 16)),
        effect: .create(action: a, birth: b, value: value),
        causalParents: CausalParentSet([OperationID(bytes: Array(repeating: 6, count: 32))]), notePredecessors: NotePredecessorSet([]))
    let decoded = try ActionRecordV1.decodeV1(bytes, dependencies: dependencies, operations: [op], earlierActions: [])
    #expect(decoded.action.kind == .restoreBatch && decoded.action.scope == .collection)
    #expect(decoded.action.members == [op.id] && decoded.action.affected[0].after == .value(op.id))
    let source = try #require(decoded.action.restorations.first)
    #expect(source.birth == b && source.sourceBirth.bytes == Array(repeating: 4, count: 16))
    #expect(source.deletionAction.bytes == Array(repeating: 5, count: 16) && source.revision.bytes == Array(repeating: 7, count: 32))
    #expect(try decoded.encodedV1(dependencies: dependencies, operations: [op], earlierActions: []) == bytes)
    for count in bytes.indices {
        #expect(throws: (any Error).self) { try ActionRecordV1.decodeV1(Array(bytes.prefix(count)), dependencies: dependencies, operations: [op], earlierActions: []) }
    }
    #expect(throws: CanonicalEncodingError.trailingBytes) { try ActionRecordV1.decodeV1(bytes + [0], dependencies: dependencies, operations: [op], earlierActions: []) }
    func rebuild(_ sources: [RestorationReference], kind: ActionKindV1 = .restoreBatch) throws -> ActionRecordV1 {
        try ActionRecordV1(id: a, origin: decoded.action.origin, previousOrigin: nil, scope: .collection,
            scopeParents: decoded.scopeReferences, kind: kind, members: decoded.memberIndices,
            affected: decoded.affectedReferences, operations: [op], earlierActions: [], restorations: sources)
    }
    #expect(throws: CanonicalEncodingError.invalidAction) { try rebuild([]) }
    #expect(throws: CanonicalEncodingError.invalidAction) { try rebuild(decoded.restorationReferences + decoded.restorationReferences) }
    #expect(throws: CanonicalEncodingError.invalidAction) { try rebuild(decoded.restorationReferences, kind: .createImportBatch) }
}
