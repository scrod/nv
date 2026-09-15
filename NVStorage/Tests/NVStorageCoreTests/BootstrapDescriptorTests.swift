import Crypto
import Foundation
@testable import NVStorageCore
import Testing

private func bytes(_ hex: String) -> [UInt8] {
    let c = Array(hex)
    return stride(from: 0, to: c.count, by: 2).map { UInt8(String(c[$0...($0 + 1)]), radix: 16)! }
}
private struct DescriptorFixture: Decodable {
    let encrypted: Bool
    let password: String, descriptor: String, descriptorID: String
    let wrappingKey: String?
}

@Test func descriptorBytesAndFixedKDF() throws {
    let url = try #require(Bundle.module.url(forResource: "descriptors", withExtension: "json", subdirectory: "Fixtures"))
    let fixtures = try JSONDecoder().decode([DescriptorFixture].self, from: Data(contentsOf: url))
    #expect(fixtures.count == 2)
    let collection = try CollectionID(bytes: .init(repeating: 1, count: 16))
    let keyID = try CollectionKeyID(bytes: .init(repeating: 2, count: 16))
    let genesis = try SegmentLocator(writerEpoch: WriterEpoch(bytes: .init(repeating: 3, count: 16)),
        sequence: 7, segmentID: SegmentID(bytes: .init(repeating: 9, count: 32)))
    let key = SymmetricKey(data: Array(UInt8(0)...31))
    for f in fixtures {
        let raw = bytes(f.descriptor)
        let parsed = try BootstrapDescriptorV1.decodeV1(raw)
        #expect(parsed.collection == collection && parsed.genesis == genesis)
        #expect(parsed.descriptorID == bytes(f.descriptorID))
        if f.encrypted {
            let wrappingKey = try Argon2idV1.wrappingKey(passphrase: f.password, salt: .init(repeating: 5, count: 16))
            #expect(wrappingKey == SymmetricKey(data: bytes(try #require(f.wrappingKey))))
            #expect(try Argon2idV1.wrappingKey(passphrase: "cafe\u{301}", salt: .init(repeating: 5, count: 16)) == wrappingKey)
            #expect(try parsed.unwrap(passphrase: f.password) == key)
            #expect(try parsed.unwrap(wrappingKey: wrappingKey) == key)
            let result = try BootstrapDescriptorV1.wrap(collection: collection, keyID: keyID, genesis: genesis,
                collectionKey: key, passphrase: f.password)
            #expect(Array(result.encodedBytes.prefix(118)) == Array(raw.prefix(118)))
            let freshWrappingKey = try Argon2idV1.wrappingKey(passphrase: f.password, salt: Array(result.encodedBytes[118..<134]))
            let independentBox = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: result.encodedBytes[134..<146]),
                ciphertext: result.encodedBytes[150..<182], tag: result.encodedBytes[182..<198])
            #expect(try Array(AES.GCM.open(independentBox, using: freshWrappingKey,
                authenticating: Array("NV key wrap\0v1\0".utf8) + result.encodedBytes.prefix(150))) == Array(UInt8(0)...31))
            #expect(throws: CanonicalEncodingError.authenticationFailure) { try parsed.unwrap(passphrase: "wrong") }
            for i in raw.indices {
                var bad = raw; bad[i] ^= 1
                #expect(throws: (any Error).self) {
                    let d = try BootstrapDescriptorV1.decodeV1(bad)
                    _ = try d.unwrap(wrappingKey: wrappingKey)
                }
            }
        } else {
            #expect(try BootstrapDescriptorV1.publicDescriptor(collection: collection, genesis: genesis).encodedBytes == raw)
            #expect(throws: CanonicalEncodingError.wrongScope) { try parsed.unwrap(passphrase: "unused") }
            for i in raw.indices {
                var bad = raw; bad[i] ^= 1
                #expect(throws: (any Error).self) { try BootstrapDescriptorV1.decodeV1(bad) }
            }
        }
        for end in raw.indices {
            #expect(throws: (any Error).self) { try BootstrapDescriptorV1.decodeV1(Array(raw.prefix(end))) }
        }
        #expect(throws: CanonicalEncodingError.trailingBytes) { try BootstrapDescriptorV1.decodeV1(raw + [0]) }
    }
    #expect(throws: CanonicalEncodingError.lengthLimit) { try BootstrapDescriptorV1.decodeV1(.init(repeating: 0, count: 16385)) }
    #expect(throws: CanonicalEncodingError.lengthLimit) { try Argon2idV1.wrappingKey(passphrase: String(repeating: "a", count: 1025), salt: .init(repeating: 0, count: 16)) }
    #expect(throws: CanonicalEncodingError.invalidPayload) { try Argon2idV1.wrappingKey(passphrase: "a", salt: []) }
}
