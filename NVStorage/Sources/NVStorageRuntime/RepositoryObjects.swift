import Foundation
import NVStorageCore

/// A canonical provider-object destination derived from checked protocol identities.
public struct ImmutableRepositoryLocator: Equatable, Sendable {
    public let relativePath: String
    private init(_ path: String) { relativePath = path }

    static func descriptor(_ descriptor: BootstrapDescriptorV1) -> Self {
        Self("NV Data/v1/keys/" + hex(descriptor.descriptorID) + ".nvkey")
    }
    static func segment(_ locator: SegmentLocator) -> Self {
        let sequence = String(locator.sequence)
        return Self(writerDirectory(locator.writerEpoch) + "/"
                    + String(repeating: "0", count: 20 - sequence.count) + sequence + "-"
                    + hex(locator.segmentID.bytes) + ".nvseg")
    }
    static func writerDirectory(_ epoch: WriterEpoch) -> String { "NV Data/v1/segments/" + hex(epoch.bytes) }
    private static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        return String(decoding: bytes.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] }, as: UTF8.self)
    }
}

/// Freezes the exact checked envelope or descriptor bytes for installation and retry.
public struct ImmutableRepositoryObject: Sendable {
    public let locator: ImmutableRepositoryLocator
    public let collection: CollectionID
    public let keyID: CollectionKeyID?
    let bytes: [UInt8]
    let descriptorGenesis: SegmentLocator?
    private init(locator: ImmutableRepositoryLocator, collection: CollectionID,
                 keyID: CollectionKeyID?, bytes: [UInt8], descriptorGenesis: SegmentLocator? = nil) {
        self.locator = locator; self.collection = collection; self.keyID = keyID; self.bytes = bytes; self.descriptorGenesis = descriptorGenesis
    }
    public static func descriptor(_ descriptor: BootstrapDescriptorV1, collection: CollectionID,
                                  keyID: CollectionKeyID?) throws -> Self {
        guard descriptor.collection == collection, descriptor.keyID == keyID else { throw CanonicalEncodingError.wrongScope }
        return Self(locator: .descriptor(descriptor), collection: collection,
                    keyID: keyID, bytes: descriptor.encodedBytes, descriptorGenesis: descriptor.genesis)
    }
    public static func envelope(_ bytes: [UInt8], locator: SegmentLocator, collection: CollectionID,
                                protection: ObjectProtectionV1) throws -> Self {
        _ = try ObjectEnvelopeV1.open(bytes, collection: collection, protection: protection, expectedLocator: locator)
        let keyID: CollectionKeyID?
        switch protection { case .publicHash: keyID = nil; case .encrypted(let identifier, _): keyID = identifier }
        return Self(locator: .segment(locator), collection: collection, keyID: keyID, bytes: bytes)
    }
}

/// Restricts shallow discovery to the ordinary visible protocol namespace.
public enum RepositoryProtocolDirectory: Equatable, Sendable {
    case repository, version, keys, segments, writer(WriterEpoch)
    var relativePath: String {
        switch self {
        case .repository: "NV Data"
        case .version: "NV Data/v1"
        case .keys: "NV Data/v1/keys"
        case .segments: "NV Data/v1/segments"
        case .writer(let epoch): ImmutableRepositoryLocator.writerDirectory(epoch)
        }
    }
}
