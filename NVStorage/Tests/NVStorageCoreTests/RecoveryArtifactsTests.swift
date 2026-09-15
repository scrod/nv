import Crypto
@testable import NVStorageCore
import Testing

// Independently reproduced by tools/check-recovery-artifact-fixtures.py.
private let selectionHex = "4e5653454c310d0a0001010101010101010101010101010101010202020202020202020202020202020203030303030303030303030303030303f4f80d73f9a41b34186b8310f7f3d7f6ecba9ebad2d3f02b52ff9c8d68397c45"
private let recoverySequence = "nvrk1pqqqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9ccrydpk8qarc0smf0s36"
private let recoveryZero = "nvrk1pqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqjayj3r"

@Test func selectedStoreLiteralAndDamage() throws {
    let chars = Array(selectionHex)
    let expected = stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...($0 + 1)]), radix: 16)! }
    let value = try SelectedStoreRecordV1(association: LocalAssociationID(bytes: .init(repeating: 1, count: 16)),
        store: LocalStoreID(bytes: .init(repeating: 2, count: 16)),
        generation: SelectionGeneration(bytes: .init(repeating: 3, count: 16)))
    #expect(value.encodedV1() == expected)
    #expect(try SelectedStoreRecordV1.decodeV1(expected) == value)
    for i in expected.indices {
        #expect(throws: (any Error).self) { try SelectedStoreRecordV1.decodeV1(Array(expected.prefix(i))) }
        var damaged = expected; damaged[i] ^= 1
        #expect(throws: (any Error).self) { try SelectedStoreRecordV1.decodeV1(damaged) }
    }
    #expect(throws: CanonicalEncodingError.invalidPayload) { try SelectedStoreRecordV1.decodeV1(expected + [0]) }
    #expect(throws: CanonicalEncodingError.invalidIdentifier) { try SelectionGeneration(bytes: .init(repeating: 0, count: 16)) }
}

@Test func recoveryKeysAndTypos() throws {
    for (key, text) in [(Array(UInt8(0)...31), recoverySequence), ([UInt8](repeating: 0, count: 32), recoveryZero)] {
        #expect(try RecoveryKeyV1.encode(SymmetricKey(data: key)) == text)
        #expect(try RecoveryKeyV1.decode(text) == SymmetricKey(data: key))
        #expect(try RecoveryKeyV1.decode(text.uppercased()) == SymmetricKey(data: key))
        #expect(try RecoveryKeyV1.decode(" \n" + text + "\t") == SymmetricKey(data: key))
        let original = Array(text.utf8)
        // Exhaustive single-symbol substitutions, every deletion and nontrivial adjacent swap.
        for i in original.indices {
            for c in RecoveryKeyV1.alphabet where c != original[i] {
                var bad = original; bad[i] = c
                #expect(throws: (any Error).self) { try RecoveryKeyV1.decode(String(decoding: bad, as: UTF8.self)) }
            }
            var missing = original; missing.remove(at: i)
            #expect(throws: (any Error).self) { try RecoveryKeyV1.decode(String(decoding: missing, as: UTF8.self)) }
            if i > 0 && original[i] != original[i - 1] {
                var swapped = original; swapped.swapAt(i, i - 1)
                #expect(throws: (any Error).self) { try RecoveryKeyV1.decode(String(decoding: swapped, as: UTF8.self)) }
            }
        }
    }
    #expect(throws: CanonicalEncodingError.invalidPayload) { try RecoveryKeyV1.decode("N" + recoverySequence.dropFirst()) }
    #expect(throws: CanonicalEncodingError.invalidPayload) { try RecoveryKeyV1.decode("\u{200b}" + recoverySequence) }
    #expect(throws: CanonicalEncodingError.lengthLimit) { try RecoveryKeyV1.decode(String(repeating: " ", count: 1025)) }
    #expect(throws: CanonicalEncodingError.invalidPayload) { try RecoveryKeyV1.encode(SymmetricKey(size: .bits128)) }
}

@Test func recoveryKeyRejectsValidChecksumWithBadVersionOrPadding() throws {
    let payload = Array(try RecoveryKeyV1.encode(SymmetricKey(data: [UInt8](repeating: 0, count: 32))).utf8)
    var symbols = payload.dropFirst(5).map { UInt8(RecoveryKeyV1.alphabet.firstIndex(of: $0)!) }
    for (index, replacement) in [(0, UInt8(2)), (52, UInt8(1))] {
        var changed = Array(symbols.prefix(53)); changed[index] = replacement
        let c = RecoveryKeyV1.polymod(RecoveryKeyV1.expandedPrefix + changed + [0, 0, 0, 0, 0, 0]) ^ 0x2bc830a3
        for shift in stride(from: 25, through: 0, by: -5) { changed.append(UInt8((c >> shift) & 31)) }
        let text = "nvrk1" + String(decoding: changed.map { RecoveryKeyV1.alphabet[Int($0)] }, as: UTF8.self)
        #expect(throws: index == 0 ? CanonicalEncodingError.unsupportedFormat : .invalidPayload) { try RecoveryKeyV1.decode(text) }
    }
    symbols.removeAll() // Test buffers contain only the published all-zero fixture.
}
