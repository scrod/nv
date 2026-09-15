import Crypto
import Foundation
@testable import NVStorageCore
import Testing

private func hex(_ text: String) -> [UInt8] {
    let chars = Array(text)
    return stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...($0 + 1)]), radix: 16)! }
}

private struct EnvelopeFixture: Decodable {
    let kind: UInt8, suite: UInt8
    let compressed: Bool
    let payload: String, envelope: String, segmentID: String
    let derivedKey: String?
}

@Test func independentEnvelopeFixtures() throws {
    let url = try #require(Bundle.module.url(forResource: "envelopes", withExtension: "json", subdirectory: "Fixtures"))
    let fixtures = try JSONDecoder().decode([EnvelopeFixture].self, from: Data(contentsOf: url))
    #expect(fixtures.count == 12)
    let collection = try CollectionID(bytes: .init(repeating: 1, count: 16))
    let keyID = try CollectionKeyID(bytes: .init(repeating: 2, count: 16))
    let writer = try WriterEpoch(bytes: .init(repeating: 3, count: 16))
    let key = SymmetricKey(data: Array(UInt8(0)...31))
    for f in fixtures {
        let kind = try #require(ProviderObjectKind(rawValue: f.kind))
        let protection: ObjectProtectionV1 = f.suite == 0 ? .publicHash : .encrypted(keyID: keyID, key: key)
        let bytes = hex(f.envelope)
        let locator = try SegmentLocator(writerEpoch: writer, sequence: 7, segmentID: SegmentID(bytes: hex(f.segmentID)))
        let result = try ObjectEnvelopeV1.open(bytes, collection: collection, protection: protection, expectedLocator: locator)
        #expect(result.payload == hex(f.payload) && result.kind == kind && result.locator == locator)
        if let derived = f.derivedKey {
            #expect(try ObjectEnvelopeV1.objectKey(key, collection: collection, keyID: keyID, kind: kind, writer: writer)
                == SymmetricKey(data: hex(derived)))
        }
        let encoded = try ObjectEnvelopeV1.seal(payload: hex(f.payload), kind: kind, collection: collection,
            writer: writer, sequence: 7, protection: protection, compress: f.compressed)
// Encoder choices may vary across Zstandard releases; compare decoded payloads.
        if !f.compressed && f.suite == 0 { #expect(encoded == bytes) }
        if !f.compressed, let derived = f.derivedKey {
            #expect(Array(encoded.prefix(112)) == Array(bytes.prefix(112)))
            let box = try AES.GCM.seal(hex(f.payload), using: SymmetricKey(data: hex(derived)),
                nonce: AES.GCM.Nonce(data: encoded[112..<124]),
                authenticating: Array("NV object envelope\0v1\0".utf8) + encoded.prefix(124))
            #expect(Array(encoded.dropFirst(124)) == Array(box.ciphertext) + Array(box.tag))
        }
        #expect(try ObjectEnvelopeV1.open(encoded, collection: collection, protection: protection).payload == hex(f.payload))
        for cut in bytes.indices {
            #expect(throws: (any Error).self) { try ObjectEnvelopeV1.open(Array(bytes.prefix(cut)), collection: collection, protection: protection) }
        }
        for i in bytes.indices {
            var damaged = bytes; damaged[i] ^= 1
            #expect(throws: (any Error).self) { try ObjectEnvelopeV1.open(damaged, collection: collection, protection: protection) }
        }
        #expect(throws: CanonicalEncodingError.lengthLimit) { try ObjectEnvelopeV1.open(bytes + [0], collection: collection, protection: protection) }
        #expect(throws: CanonicalEncodingError.wrongScope) {
            try ObjectEnvelopeV1.open(bytes, collection: CollectionID(bytes: .init(repeating: 9, count: 16)), protection: protection)
        }
        if f.suite == 1 {
            #expect(throws: CanonicalEncodingError.authenticationFailure) {
                try ObjectEnvelopeV1.open(bytes, collection: collection, protection: .encrypted(keyID: keyID, key: SymmetricKey(data: [UInt8](repeating: 0, count: 32))))
            }
            #expect(throws: CanonicalEncodingError.wrongScope) { try ObjectEnvelopeV1.open(bytes, collection: collection, protection: .publicHash) }
        }
    }
}

@Test func compressedFramingAndFreshNonce() throws {
    let collection = try CollectionID(bytes: .init(repeating: 1, count: 16))
    let writer = try WriterEpoch(bytes: .init(repeating: 2, count: 16))
    let protection = try ObjectProtectionV1.encrypted(keyID: CollectionKeyID(bytes: .init(repeating: 3, count: 16)),
                                                    key: SymmetricKey(data: [UInt8](repeating: 4, count: 32)))
    let a = try ObjectEnvelopeV1.seal(payload: [], kind: .changes, collection: collection, writer: writer, sequence: 0, protection: protection, compress: true)
    let b = try ObjectEnvelopeV1.seal(payload: [], kind: .changes, collection: collection, writer: writer, sequence: 0, protection: protection, compress: true)
    #expect(a != b) // Production obtains a new random nonce; retries retain a, not reseal.
    #expect(try ObjectEnvelopeV1.open(a, collection: collection, protection: protection).payload.isEmpty)
    let packed = try ZstdFrameV1.compress([UInt8](repeating: 65, count: 4096))
    #expect(throws: CanonicalEncodingError.invalidPayload) { try ZstdFrameV1.expand(packed, count: 1) }
    #expect(throws: CanonicalEncodingError.invalidPayload) { try ZstdFrameV1.expand(packed, count: 4097) }
    #expect(throws: CanonicalEncodingError.invalidPayload) { try ZstdFrameV1.expand(packed + packed, count: 4096) }
    #expect(throws: CanonicalEncodingError.invalidPayload) { try ZstdFrameV1.expand(packed + [0], count: 4096) }
    #expect(throws: CanonicalEncodingError.invalidPayload) { try ZstdFrameV1.expand(Array(packed.dropLast()), count: 4096) }
    #expect(try ZstdFrameV1.expand(packed, count: 4096) == [UInt8](repeating: 65, count: 4096))
// A correctly checksummed public bomb exercises the claimed output bound
    // during decompression, after envelope checksum verification.
    let good = try ObjectEnvelopeV1.seal(payload: [UInt8](repeating: 65, count: 4096), kind: .changes,
        collection: collection, writer: writer, sequence: 0, protection: .publicHash, compress: true)
    var changed = Array(good.dropLast(32)); changed.replaceSubrange(104..<112, with: [0, 0, 0, 0, 0, 0, 0, 1])
    changed += Array(SHA256.hash(data: Array("NV object envelope\0v1\0".utf8) + changed))
    #expect(throws: CanonicalEncodingError.invalidPayload) { try ObjectEnvelopeV1.open(changed, collection: collection, protection: .publicHash) }
}

@Test func encryptedProtectionCrossesTaskBoundaries() async throws {
    let collection = try CollectionID(bytes: .init(repeating: 1, count: 16))
    let writer = try WriterEpoch(bytes: .init(repeating: 2, count: 16))
    let protection = try ObjectProtectionV1.encrypted(
        keyID: CollectionKeyID(bytes: .init(repeating: 3, count: 16)),
        key: SymmetricKey(data: [UInt8](repeating: 4, count: 32)))
    let payload = Array("synthetic cross-task secret".utf8)
    let envelopes = try await withThrowingTaskGroup(of: [UInt8].self) { group in
        for _ in 0..<8 {
            group.addTask {
                try ObjectEnvelopeV1.seal(payload: payload, kind: .changes, collection: collection,
                    writer: writer, sequence: 0, protection: protection)
            }
        }
        var results: [[UInt8]] = []
        for try await bytes in group { results.append(bytes) }
        return results
    }
    #expect(envelopes.count == 8)
    #expect(Set(envelopes.map { Array($0[112..<124]) }).count == 8)
    for bytes in envelopes {
        let opened = try ObjectEnvelopeV1.open(bytes, collection: collection, protection: protection)
        #expect(opened.payload == payload)
        #expect(opened.kind == .changes && opened.locator.writerEpoch == writer && opened.locator.sequence == 0)
    }
}

@Test func zstdProviderProfileRejectsOtherFrames() throws {
    // Literal regular frame containing one final raw block with the bytes "abc".
    let raw = hex("28b52ffd2003190000616263")
    let empty = hex("28b52ffd2000010000")
    #expect(try ZstdFrameV1.expand(raw, count: 3) == Array("abc".utf8))
    #expect(try ZstdFrameV1.expand(empty, count: 0).isEmpty)
    let checksummed = hex("28b52ffd2403190000616263990977ad")
    #expect(try ZstdFrameV1.expand(checksummed, count: 3) == Array("abc".utf8))
    var damagedChecksum = checksummed; damagedChecksum[damagedChecksum.count - 1] ^= 1
    #expect(throws: CanonicalEncodingError.invalidPayload) { try ZstdFrameV1.expand(damagedChecksum, count: 3) }
    let rejected: [([UInt8], Int)] = [
        (raw + empty, 3), // Even an empty second frame violates exact framing.
        (hex("502a4d1800000000"), 0), // Skippable frame.
        (hex("28b52ffd0000190000616263"), 3), // Unspecified content size.
        (hex("28b52ffd210003190000616263"), 3), // Dictionary-ID field, even zero.
        (hex("28b52ffd3003190000616263"), 3), // Unused bit.
        (hex("28b52ffd2803190000616263"), 3), // Reserved bit.
        (hex("28b52ffd808803000000190000616263"), 3), // 128-MiB window.
        (hex("789c4b4c4a0600024d0127"), 3), // Legacy zlib stream.
    ]
    for (bytes, count) in rejected {
        #expect(throws: CanonicalEncodingError.invalidPayload) { try ZstdFrameV1.expand(bytes, count: count) }
    }
    #expect(throws: CanonicalEncodingError.lengthLimit) { try ZstdFrameV1.expand(raw, count: -1) }
    #expect(throws: CanonicalEncodingError.lengthLimit) { try ZstdFrameV1.expand(raw, count: 64 * 1024 * 1024 + 1) }
    // Regular non-single-segment frame at the inclusive 64-MiB window limit.
    #expect(try ZstdFrameV1.expand(hex("28b52ffd808003000000190000616263"), count: 3) == Array("abc".utf8))
}

@Test func zstdProviderPayloadLimit() throws {
    var bytes = [UInt8](repeating: 65, count: Int(ObjectLimitsV1.decodedPayloadBytes))
    let frame = try ZstdFrameV1.compress(bytes)
    #expect(try ZstdFrameV1.expand(frame, count: bytes.count) == bytes)
    bytes.append(65)
    #expect(throws: CanonicalEncodingError.lengthLimit) { try ZstdFrameV1.compress(bytes) }
    bytes.removeLast()
    // Exercise encoded headroom with deterministic poorly compressible contents.
    var state: UInt32 = 0x12345678
    for index in bytes.indices {
        state = state &* 1664525 &+ 1013904223
        bytes[index] = UInt8(truncatingIfNeeded: state >> 24)
    }
    let noisy = try ZstdFrameV1.compress(bytes)
    #expect(noisy.count <= Int(ObjectLimitsV1.encodedPayloadBytes))
    #expect(try ZstdFrameV1.expand(noisy, count: bytes.count) == bytes)
}

@Test(arguments: [false, true]) func authenticatedZstdProfileChecks(encrypted: Bool) throws {
    let collection = try CollectionID(bytes: .init(repeating: 1, count: 16))
    let writer = try WriterEpoch(bytes: .init(repeating: 3, count: 16))
    let keyID = try CollectionKeyID(bytes: .init(repeating: 2, count: 16))
    let key = SymmetricKey(data: [UInt8](repeating: 4, count: 32))
    let protection: ObjectProtectionV1 = encrypted ? .encrypted(keyID: keyID, key: key) : .publicHash
    let original = try ObjectEnvelopeV1.seal(payload: Array("abc".utf8), kind: .changes,
        collection: collection, writer: writer, sequence: 0, protection: protection, compress: true)
    #expect(original[88] == ObjectCompressionV1.zstd.rawValue)
    let domain = Array("NV object envelope\0v1\0".utf8)
    func envelope(_ frame: [UInt8]) throws -> [UInt8] {
        var header = Array(original.prefix(124))
        header.replaceSubrange(96..<104, with: bigEndianBytes(UInt64(frame.count)))
        if !encrypted { return header + frame + Array(SHA256.hash(data: domain + header + frame)) }
        let derived = try ObjectEnvelopeV1.objectKey(key, collection: collection, keyID: keyID, kind: .changes, writer: writer)
        // Test-only frame assembly uses a fresh nonce on every seal.
        let nonce = AES.GCM.Nonce(); header.replaceSubrange(112..<124, with: Array(nonce))
        let box = try AES.GCM.seal(frame, using: derived, nonce: nonce, authenticating: domain + header)
        return header + Array(box.ciphertext) + Array(box.tag)
    }
    let raw = hex("28b52ffd2003190000616263"), empty = hex("28b52ffd2000010000")
    #expect(try ObjectEnvelopeV1.open(envelope(raw), collection: collection, protection: protection).payload == Array("abc".utf8))
    for frame in [raw + empty, hex("789c4b4c4a0600024d0127"), hex("28b52ffd0000190000616263")] {
        let validAuthentication = try envelope(frame)
        #expect(throws: CanonicalEncodingError.invalidPayload) {
            try ObjectEnvelopeV1.open(validAuthentication, collection: collection, protection: protection)
        }
        var badAuthentication = validAuthentication; badAuthentication[badAuthentication.count - 1] ^= 1
        #expect(throws: CanonicalEncodingError.authenticationFailure) {
            try ObjectEnvelopeV1.open(badAuthentication, collection: collection, protection: protection)
        }
    }
}
