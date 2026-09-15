import CZstd

/// Dictionary-free provider frames with exact input/output and bounded window size.
enum ZstdFrameV1 {
    static func compress(_ bytes: [UInt8]) throws -> [UInt8] {
        guard UInt64(bytes.count) <= ObjectLimitsV1.decodedPayloadBytes else { throw CanonicalEncodingError.lengthLimit }
        let bound = ZSTD_compressBound(bytes.count)
        guard ZSTD_isError(bound) == 0 else { throw CanonicalEncodingError.lengthLimit }
        let capacity = min(bound, Int(ObjectLimitsV1.encodedPayloadBytes))
        var result = [UInt8](repeating: 0, count: capacity)
        let size = result.withUnsafeMutableBytes { out in bytes.withUnsafeBytes { input in
            ZSTD_compress(out.baseAddress, out.count, input.baseAddress, input.count, 3)
        } }
        guard ZSTD_isError(size) == 0 else { throw CanonicalEncodingError.lengthLimit }
        result.removeSubrange(size..<result.count)
        return result
    }

    static func expand(_ bytes: [UInt8], count: Int) throws -> [UInt8] {
        guard count >= 0, UInt64(count) <= ObjectLimitsV1.decodedPayloadBytes,
              UInt64(bytes.count) <= ObjectLimitsV1.encodedPayloadBytes else { throw CanonicalEncodingError.lengthLimit }
        // Regular frame magic, zero dictionary-ID width and zero reserved/unused bits.
        guard bytes.count >= 6, bytes.prefix(4).elementsEqual([0x28, 0xb5, 0x2f, 0xfd]),
              bytes[4] & 0x1b == 0 else { throw CanonicalEncodingError.invalidPayload }
        if bytes[4] & 0x20 == 0 {
            let exponent = Int(bytes[5] >> 3) + 10
            guard exponent <= 26 else { throw CanonicalEncodingError.invalidPayload }
            let base = UInt64(1) << exponent
            let window = base + (base >> 3) * UInt64(bytes[5] & 7)
            guard window <= ObjectLimitsV1.decodedPayloadBytes else { throw CanonicalEncodingError.invalidPayload }
        }
        try bytes.withUnsafeBytes { input in
            guard ZSTD_getFrameContentSize(input.baseAddress, input.count) == UInt64(count) else {
                throw CanonicalEncodingError.invalidPayload
            }
            let frameSize = ZSTD_findFrameCompressedSize(input.baseAddress, input.count)
            guard ZSTD_isError(frameSize) == 0, frameSize == input.count else {
                throw CanonicalEncodingError.invalidPayload
            }
        }
        // Fixed-capacity one-shot decoding uses the caller's output as history.
        var result = [UInt8](repeating: 0, count: max(1, count))
        let size = result.withUnsafeMutableBytes { out in bytes.withUnsafeBytes { input in
            ZSTD_decompress(out.baseAddress, count, input.baseAddress, input.count)
        } }
        guard ZSTD_isError(size) == 0, size == count else { throw CanonicalEncodingError.invalidPayload }
        result.removeSubrange(count..<result.count)
        return result
    }
}
