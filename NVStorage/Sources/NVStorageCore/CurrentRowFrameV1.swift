import Crypto
import CZstd

/// Immutable formatted zstd dictionary identified by the hash of its complete bytes.
public struct CurrentRowDictionaryV1: Equatable, Sendable {
    public static let maximumBytes = 8 * 1024
    public let bytes: [UInt8]
    public let digest: [UInt8]
    public let frameID: UInt32

    public init(bytes: [UInt8]) throws {
        guard bytes.count >= 8, bytes.count <= Self.maximumBytes,
              bytes.prefix(4).elementsEqual([0x37, 0xa4, 0x30, 0xec]) else {
            throw CanonicalEncodingError.invalidPayload
        }
        frameID = bytes.withUnsafeBytes { unsafe ZSTD_getDictID_fromDict($0.baseAddress, $0.count) }
        guard frameID != 0 else { throw CanonicalEncodingError.invalidPayload }
        let checked = bytes.withUnsafeBytes { unsafe ZSTD_createDDict($0.baseAddress, $0.count) }
        guard let checked = unsafe checked else { throw CanonicalEncodingError.invalidPayload }
        unsafe ZSTD_freeDDict(checked)
        self.bytes = bytes; digest = Array(SHA256.hash(data: bytes))
    }

    /// Trains one bounded candidate set; ineffective or cancelled training leaves ordinary compression usable.
    public static func train(bodies: [[UInt8]]) throws -> Self? {
        var samples: [UInt8] = [], sizes: [Int] = []
        for body in bodies.prefix(1024) {
            try Task.checkCancellation()
            guard body.count >= 8, body.count <= 8 * 1024 * 1024 - samples.count else { continue }
            samples += body; sizes.append(body.count)
        }
        guard sizes.count >= 8 else { return nil }
        var output = [UInt8](repeating: 0, count: maximumBytes)
        let size = output.withUnsafeMutableBytes { out in samples.withUnsafeBytes { input in
            sizes.withUnsafeBufferPointer { lengths in
                unsafe ZDICT_trainFromBuffer(out.baseAddress, out.count, input.baseAddress, lengths.baseAddress, UInt32(lengths.count))
            }
        } }
        try Task.checkCancellation()
        guard ZDICT_isError(size) == 0 else { return nil }
        output.removeSubrange(size..<output.count)
        return try Self(bytes: output)
    }
}

/// Parsed physical framing for one complete canonical private current cell.
public struct CurrentRowFrameV1: Sendable {
    public enum Encoding: UInt8, Sendable { case raw = 0, zstd = 1, dictionary = 2 }
    public let encoding: Encoding
    public let expandedCount: Int
    public let dictionaryDigest: [UInt8]?
    public let payload: [UInt8]
    public static let magic = Array("NVROW1\r\n".utf8)

    public init(bytes: [UInt8]) throws {
        guard UInt64(bytes.count) <= ObjectLimitsV1.encodedPayloadBytes + 51 else { throw CanonicalEncodingError.lengthLimit }
        var c = ByteCursor(bytes: bytes)
        // Development canonical rows have their own unambiguous magic and complete decoder.
        if bytes.starts(with: Array("NVCEL1\r\n".utf8)) {
            guard UInt64(bytes.count) <= ObjectLimitsV1.decodedPayloadBytes else { throw CanonicalEncodingError.lengthLimit }
            encoding = .raw; expandedCount = bytes.count; payload = bytes; dictionaryDigest = nil
            return
        }
        guard try c.fixedBytes(8) == Self.magic, try c.unsigned16() == 1 else { throw CanonicalEncodingError.unsupportedFormat }
        guard let encoding = Encoding(rawValue: try c.byte()) else { throw CanonicalEncodingError.invalidDiscriminant }
        let expanded = UInt64(try c.unsigned32()), stored = UInt64(try c.unsigned32())
        guard expanded > 0, expanded <= ObjectLimitsV1.decodedPayloadBytes, stored > 0,
              stored <= ObjectLimitsV1.encodedPayloadBytes else { throw CanonicalEncodingError.lengthLimit }
        let digest = encoding == .dictionary ? try c.fixedBytes(32) : nil
        let payload = try c.fixedBytes(Int(stored)); try c.requireEnd()
        if encoding == .raw, stored != expanded { throw CanonicalEncodingError.invalidPayload }
        self.encoding = encoding; expandedCount = Int(expanded); dictionaryDigest = digest; self.payload = payload
    }

    static func frame(_ payload: [UInt8], expanded: Int, dictionary: CurrentRowDictionaryV1? = nil,
                      compressed: Bool) -> [UInt8] {
        magic + bigEndianBytes(UInt16(1)) + [compressed ? (dictionary == nil ? 1 : 2) : 0] +
        bigEndianBytes(UInt32(expanded)) + bigEndianBytes(UInt32(payload.count)) + (dictionary?.digest ?? []) + payload
    }
}

/// Job-owned prepared encoder, reused while framing a bounded materialization batch.
@safe
public final class CurrentRowEncoderV1 {
    private let context: OpaquePointer
    private let prepared: OpaquePointer?
    private let dictionary: CurrentRowDictionaryV1?
    public init(dictionary: CurrentRowDictionaryV1? = nil) throws {
        let prepared: OpaquePointer?
        if let dictionary {
            unsafe prepared = dictionary.bytes.withUnsafeBytes { unsafe ZSTD_createCDict($0.baseAddress, $0.count, 3) }
            guard unsafe prepared != nil else { throw CanonicalEncodingError.lengthLimit }
        } else { unsafe prepared = nil }
        guard let context = unsafe ZSTD_createCCtx() else { unsafe ZSTD_freeCDict(prepared); throw CanonicalEncodingError.lengthLimit }
        unsafe self.context = context; unsafe self.prepared = prepared; self.dictionary = dictionary
    }
    deinit { unsafe ZSTD_freeCDict(prepared); unsafe ZSTD_freeCCtx(context) }

    /// Chooses the smallest complete raw/plain/dictionary representation, keeping simpler ties.
    public func encode(_ cell: CurrentNoteCellV1) -> [UInt8] {
        let canonical = cell.encodedV1()
        var best = CurrentRowFrameV1.frame(canonical, expanded: canonical.count, compressed: false)
        if let compressed = try? compress(canonical, dictionary: false) {
            let frame = CurrentRowFrameV1.frame(compressed, expanded: canonical.count, compressed: true)
            if frame.count < best.count { best = frame }
        }
        if let dictionary, let compressed = try? compress(canonical, dictionary: true) {
            let frame = CurrentRowFrameV1.frame(compressed, expanded: canonical.count, dictionary: dictionary, compressed: true)
            if frame.count < best.count { best = frame }
        }
        return best
    }
    public static func raw(_ cell: CurrentNoteCellV1) -> [UInt8] {
        let bytes = cell.encodedV1()
        return CurrentRowFrameV1.frame(bytes, expanded: bytes.count, compressed: false)
    }
    private func compress(_ input: [UInt8], dictionary: Bool) throws -> [UInt8] {
        let capacity = min(ZSTD_compressBound(input.count), Int(ObjectLimitsV1.encodedPayloadBytes))
        var output = [UInt8](repeating: 0, count: capacity)
        let size = output.withUnsafeMutableBytes { out in input.withUnsafeBytes { source in
            if dictionary { return unsafe ZSTD_compress_usingCDict(context, out.baseAddress, out.count, source.baseAddress, source.count, prepared) }
            return unsafe ZSTD_compressCCtx(context, out.baseAddress, out.count, source.baseAddress, source.count, 3)
        } }
        guard ZSTD_isError(size) == 0 else { throw CanonicalEncodingError.lengthLimit }
        output.removeSubrange(size..<output.count); return output
    }
}

/// One current-row read's bounded zstd resources and full-digest dictionary working set.
@safe
public final class CurrentRowDecoderV1 {
    private let context: OpaquePointer
    private var dictionaries: [[UInt8]: PreparedDictionary] = [:]
    public init() throws {
        guard let context = unsafe ZSTD_createDCtx() else { throw CanonicalEncodingError.lengthLimit }
        unsafe self.context = context
    }
    deinit { unsafe ZSTD_freeDCtx(context) }
    public func decode(_ bytes: [UInt8], dictionary: ([UInt8]) throws -> CurrentRowDictionaryV1) throws -> CurrentNoteCellV1 {
        let frame = try CurrentRowFrameV1(bytes: bytes)
        if frame.encoding == .raw { return try CurrentNoteCellV1.decodeV1(frame.payload) }
        let source = frame.payload
        guard source.count >= 6, source.prefix(4).elementsEqual([0x28, 0xb5, 0x2f, 0xfd]), source[4] & 0x18 == 0 else {
            throw CanonicalEncodingError.invalidPayload
        }
        if source[4] & 0x20 == 0 {
            let exponent = Int(source[5] >> 3) + 10
            guard exponent <= 26 else { throw CanonicalEncodingError.lengthLimit }
            let base = UInt64(1) << exponent
            guard base + (base >> 3) * UInt64(source[5] & 7) <= ObjectLimitsV1.decodedPayloadBytes else { throw CanonicalEncodingError.lengthLimit }
        }
        let prepared: PreparedDictionary?
        if let digest = frame.dictionaryDigest {
            if let reused = dictionaries[digest] { prepared = reused }
            else {
                let value = try dictionary(digest)
                guard value.digest == digest else { throw CanonicalEncodingError.identityMismatch }
                prepared = try PreparedDictionary(value)
                if dictionaries.count == 4 { dictionaries.removeAll(keepingCapacity: true) }
                dictionaries[digest] = prepared
            }
        } else { prepared = nil }
        try source.withUnsafeBytes { input in
            guard unsafe ZSTD_getFrameContentSize(input.baseAddress, input.count) == UInt64(frame.expandedCount),
                  unsafe ZSTD_getDictID_fromFrame(input.baseAddress, input.count) == (prepared?.value.frameID ?? 0),
                  unsafe ZSTD_findFrameCompressedSize(input.baseAddress, input.count) == input.count else { throw CanonicalEncodingError.invalidPayload }
        }
        var output = [UInt8](repeating: 0, count: frame.expandedCount)
        let size = output.withUnsafeMutableBytes { out in source.withUnsafeBytes { input in
            if let prepared { return unsafe ZSTD_decompress_usingDDict(context, out.baseAddress, out.count, input.baseAddress, input.count, prepared.handle) }
            return unsafe ZSTD_decompressDCtx(context, out.baseAddress, out.count, input.baseAddress, input.count)
        } }
        guard ZSTD_isError(size) == 0, size == frame.expandedCount else { throw CanonicalEncodingError.invalidPayload }
        return try CurrentNoteCellV1.decodeV1(output)
    }
    @safe
    private final class PreparedDictionary {
        let value: CurrentRowDictionaryV1
        let handle: OpaquePointer
        init(_ value: CurrentRowDictionaryV1) throws {
            guard let handle = value.bytes.withUnsafeBytes({ unsafe ZSTD_createDDict($0.baseAddress, $0.count) }) else { throw CanonicalEncodingError.lengthLimit }
            self.value = value; unsafe self.handle = handle
        }
        deinit { unsafe ZSTD_freeDDict(handle) }
    }
}
