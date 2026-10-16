import Foundation
import NVStorageCore
import CStorageIO
#if canImport(Darwin)
import CoreFoundation
import CAppleFileAccess
#endif

/// Native metadata derived from the exact history-checked output being installed.
struct ProjectionOutputMetadata: Sendable {
    let encoding, tags: [UInt8]
    let stamp: [UInt8]?
    let created, modified: (seconds: Int64, nanoseconds: UInt32)
    let permissions: UInt32

    init(_ input: PreparedProjectionCreation) throws {
        try self.init(output: input.output, value: input.value, permissions: 0o600)
    }

    init(_ input: PreparedProjectionReplacement, permissions: UInt32) throws {
        try self.init(output: input.output, value: input.value, permissions: permissions)
    }

    init(_ input: PreparedProjectionRelocation, permissions: UInt32) throws {
        try self.init(output: input.output, value: input.value, permissions: permissions)
    }

    private init(output: ProjectionOutputV1, value: PlaintextNoteValue, permissions: UInt32) throws {
        self.permissions = permissions
        #if canImport(Darwin)
        let requested: UInt64
        switch output.encoding {
        case .utf8: requested = ProjectionEncodingV1.utf8.rawValue
        case .captured(let encoding, _): requested = encoding.rawValue
        }
        guard let native = UInt(exactly: requested) else { throw RepositoryRootError.unsupported(EINVAL) }
        let cf = CFStringConvertNSStringEncodingToEncoding(native)
        guard cf != kCFStringEncodingInvalidId, let charset = CFStringConvertEncodingToIANACharSetName(cf) else {
            throw RepositoryRootError.unsupported(EINVAL)
        }
        encoding = Array(((charset as String) + ";" + String(cf)).utf8)
        #else
        // The current native Linux adapter explicitly lacks mandatory creation-date setting.
        throw RepositoryRootError.unsupported(ENOTSUP)
        #endif
        #if canImport(Darwin)
        tags = Array(try PropertyListSerialization.data(fromPropertyList: value.labels.entries.map(\.string),
            format: .binary, options: 0))
        guard UInt64(tags.count) <= ObjectLimitsV1.decodedPayloadBytes else { throw RepositoryRootError.unsupported(EFBIG) }
        switch try ProjectionStampV1.prepare(profile: .plaintextFiles, collection: output.binding.collection,
            birth: output.binding.birth, format: output.binding.descriptor.format,
            digest: output.binding.descriptor.digest, state: output.binding.state) {
        case .stamp(let value): stamp = try value.encodedV1()
        case .omittedOversized: stamp = nil
        }
        created = try Self.time(value.created); modified = try Self.time(value.modified)
        #endif
    }

    private static func time(_ date: DisplayDate) throws -> (seconds: Int64, nanoseconds: UInt32) {
        let unix = date.secondsSinceReferenceDate + 978_307_200
        let whole = unix.rounded(.down)
        guard let seconds = Int64(exactly: whole),
              let fraction = UInt32(exactly: ((unix - whole) * 1_000_000_000).rounded(.towardZero)),
              fraction < 1_000_000_000 else { throw RepositoryRootError.unsupported(EOVERFLOW) }
        return (seconds, fraction)
    }

    /// Borrows each Swift buffer for the complete synchronous native call.
    @safe
    private func withNative<Result>(_ body: (inout NVProjectionMetadata) -> Result) -> Result {
        encoding.withUnsafeBufferPointer { encoded in
            tags.withUnsafeBufferPointer { labelled in
                (stamp ?? []).withUnsafeBufferPointer { stamped in
                    var native = unsafe NVProjectionMetadata(
                        encoding: .init(bytes: encoded.baseAddress, count: UInt32(encoded.count), present: 1),
                        tags: .init(bytes: labelled.baseAddress, count: UInt32(labelled.count), present: 1),
                        finder_tags: .init(bytes: labelled.baseAddress, count: UInt32(labelled.count), present: 1),
                        stamp: .init(bytes: stamped.baseAddress, count: UInt32(stamped.count), present: stamp == nil ? 0 : 1),
                        permissions: permissions, has_birth: 1,
                        birth_seconds: created.seconds, modified_seconds: modified.seconds,
                        birth_nanoseconds: created.nanoseconds, modified_nanoseconds: modified.nanoseconds)
                    return unsafe body(&native)
                }
            }
        }
    }

    @safe
    func prepare(owner: OpaquePointer, directory: Int32, leaf: String, bytes: [UInt8], effect: inout NVProjectionEffect) -> OpaquePointer? {
        withNative { metadata in
            bytes.withUnsafeBufferPointer {
                unsafe nv_projection_prepare(owner, directory, leaf, $0.baseAddress, UInt64($0.count), &metadata, &effect)
            }
        }
    }

    @safe
    func install(owner: OpaquePointer, stage: OpaquePointer, destination: String, bytes: [UInt8], effect: inout NVProjectionEffect) {
        withNative { metadata in
            bytes.withUnsafeBufferPointer {
                unsafe nv_projection_create(owner, stage, destination, $0.baseAddress, UInt64($0.count), &metadata, &effect)
            }
        }
    }

    @safe
    func prepareReplacement(owner: OpaquePointer, directory: Int32, expected: [UInt64],
                            input: PreparedProjectionReplacement, effect: inout NVProjectionEffect) -> OpaquePointer? {
        guard expected.count == 9 else { effect.error = EINVAL; return nil }
        return withNative { metadata in
            expected.withUnsafeBufferPointer { identity in
                input.sourceBytes.withUnsafeBufferPointer { previous in
                    input.bytes.withUnsafeBufferPointer { bytes in
                        unsafe nv_projection_prepare_replacement(owner, directory, "prepared",
                            input.output.binding.descriptor.filename.spelling.string, identity.baseAddress,
                            previous.baseAddress, UInt64(previous.count), bytes.baseAddress, UInt64(bytes.count), &metadata, &effect)
                    }
                }
            }
        }
    }

    #if canImport(Darwin)
    @safe
    func prepareRelocation(owner: OpaquePointer, directory: Int32, expected: [UInt64], input: PreparedProjectionRelocation,
                           effect: inout NVProjectionEffect) -> OpaquePointer? {
        guard expected.count == 9 else { effect.error = EINVAL; return nil }
        return withNative { metadata in
            expected.withUnsafeBufferPointer { identity in
                input.sourceBytes.withUnsafeBufferPointer { previous in
                    input.bytes.withUnsafeBufferPointer { bytes in
                        unsafe nv_projection_prepare_replacement(owner, directory, "prepared",
                            input.source.output.binding.descriptor.filename.spelling.string, identity.baseAddress,
                            previous.baseAddress, UInt64(previous.count), bytes.baseAddress, UInt64(bytes.count), &metadata, &effect)
                    }
                }
            }
        }
    }

    @safe
    func relocate(coordinator: NSFileCoordinator, root: CFURL, stageURL: CFURL, owner: OpaquePointer, stage: OpaquePointer,
                  reserved: ReservedProjectionRelocation, expected: inout NVProjectionRead, descriptor: Int32,
                  maximum: Int, result: inout NVProjectionRelocationResult) {
        withNative { metadata in
            reserved.input.bytes.withUnsafeBufferPointer { bytes in
                unsafe NVAppleRelocateProjection(coordinator, root, stageURL, owner, stage,
                    reserved.input.source.output.binding.descriptor.filename.spelling.string,
                    reserved.input.output.binding.descriptor.filename.spelling.string, reserved.record.backupName,
                    &expected, UInt64(maximum), descriptor, bytes.baseAddress, UInt64(bytes.count), &metadata, &result)
            }
        }
    }

    @safe
    func replace(coordinator: NSFileCoordinator, root: CFURL, stageURL: CFURL, owner: OpaquePointer,
                 stage: OpaquePointer, reserved: ReservedProjectionReplacement, expected: [UInt64],
                 result: inout NVProjectionReplacementResult) {
        let input = reserved.input
        withNative { metadata in
            expected.withUnsafeBufferPointer { identity in
                guard expected.count == 9, let address = identity.baseAddress else {
                    result.installation.error = EINVAL; return
                }
                input.sourceBytes.withUnsafeBufferPointer { previous in
                    input.bytes.withUnsafeBufferPointer { bytes in
                        unsafe NVAppleReplaceProjection(coordinator, root, stageURL, owner, stage,
                            input.output.binding.descriptor.filename.spelling.string, reserved.record.backupName,
                            address, previous.baseAddress, UInt64(previous.count),
                            bytes.baseAddress, UInt64(bytes.count), &metadata, &result)
                    }
                }
            }
        }
    }
    #endif
}
