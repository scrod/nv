import Foundation
import CStorageIO
import NVStorageCore
import Crypto
#if canImport(Darwin)
import CoreFoundation
import FileProvider
import CAppleFileAccess
#endif

/// Classifies physical root access and session applicability for repository work.
public enum RepositoryRootError: Error, Equatable, Sendable {
    case contention, unsupported(Int32), unavailable(Int32), unsafePath
    case wrongContext, stalePermission, busy, fenced, closed
}

#if canImport(Darwin)
/// Copies a coordinator failure into the rooted access error vocabulary.
func repositoryCoordinationCode(_ error: NSError?) -> Int32 {
    guard let error else { return EIO }
    if error.domain == NSPOSIXErrorDomain, let code = Int32(exactly: error.code), code > 0 { return code }
    if error.domain == NSCocoaErrorDomain {
        switch error.code {
        case NSUserCancelledError: return ECANCELED
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return ENOENT
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return EACCES
        case NSFileWriteOutOfSpaceError: return ENOSPC
        case NSFileWriteVolumeReadOnlyError: return EROFS
        default: break
        }
    }
    return EIO
}
#endif

/// The owned directory's relationship to a freshly observed candidate.
public enum RepositoryRootContinuity: Equatable, Sendable {
    case same, different, unavailable(Int32)
}

/// Repository admission and final resource teardown have separate lifecycle stages.
public enum RepositoryRootState: Equatable, Sendable {
    case active, fenced, closing, closed
}

/// Captures the issuing owner's current admission generation for one rooted turn.
public struct RepositoryRootPermission: Sendable {
    fileprivate let session: UUID
    fileprivate let generation: UInt64
    fileprivate init(session: UUID, generation: UInt64) {
        self.session = session; self.generation = generation
    }
}

/// A copied entry observation scoped to the root and admission generation that read it.
public struct RepositoryEntryObservation: Sendable {
    public enum Kind: UInt64, Sendable { case regularFile = 1, directory, symbolicLink, other }
    public let kind: Kind
    public let byteCount: UInt64
    fileprivate let permission: RepositoryRootPermission
    fileprivate let identity: [UInt64]
    fileprivate let relative: String
    fileprivate init(permission: RepositoryRootPermission, words: [UInt64], relative: String) throws {
        guard words.count == 9, let kind = Kind(rawValue: words[0]) else { throw RepositoryRootError.wrongContext }
        self.permission = permission; self.identity = words
        self.kind = kind; self.byteCount = words[3]; self.relative = relative
    }
}

/// Classifies current-file evidence separately from root ownership failures.
public enum RepositoryFileFailure: Equatable, Sendable {
    case absent, changed, kindCollision, hardLinked, sizeLimit, conflict
    case unsupported(Int32), io(Int32), staleContext
    init(code: Int32) {
        switch code {
        case ENOENT: self = .absent
        case ESTALE: self = .changed
        case ENOTDIR, ELOOP: self = .kindCollision
        case EMLINK: self = .hardLinked
        case EFBIG: self = .sizeLimit
        case EEXIST: self = .conflict
        case ENOTSUP, ENOSYS, EINVAL: self = .unsupported(code)
        default: self = .io(code)
        }
    }
}

public enum RepositoryObservationResult: Sendable {
    case observed(RepositoryEntryObservation), unavailable(RepositoryFileFailure)
}

/// The exact bytes obtained from a coherent bounded read under one admission context.
public struct RepositoryFileContents: Sendable {
    public let bytes: [UInt8]
    fileprivate let observation: RepositoryEntryObservation
    fileprivate init(bytes: [UInt8], observation: RepositoryEntryObservation) { self.bytes = bytes; self.observation = observation }
}

/// A freshly rooted file observation whose stable fingerprint reuses accepted bytes across sessions.
struct RepositoryObservationHint: Sendable {
    let key: [UInt8]
    let fingerprint: [UInt8]
    fileprivate init(observation: RepositoryEntryObservation) {
        key = Array("repository-seen/".utf8) + Array(SHA256.hash(data: Array(observation.relative.utf8)))
        let encoded = observation.identity.flatMap { word in
            (0..<8).reversed().map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) }
        }
        fingerprint = Array(SHA256.hash(data: Array("NV repository file observation\0v1\0".utf8) + encoded))
    }
}

public enum RepositoryReadResult: Sendable {
    case contents(RepositoryFileContents), unavailable(RepositoryFileFailure)
}

/// Exact raw attributes retain empty presence and filesystem capability separately.
public enum ProjectionFileAttribute: Equatable, Sendable {
    case absent, present([UInt8]), unsupported
}

/// A filesystem timestamp expressed without floating-point rounding.
public struct ProjectionFileTime: Equatable, Sendable {
    public let seconds: Int64
    public let nanoseconds: UInt32
    fileprivate init(seconds: Int64, nanoseconds: UInt32) {
        self.seconds = seconds; self.nanoseconds = nanoseconds
    }
}

/// A coherent direct-child body and its raw metadata, issued by the live root owner.
public struct ProjectionFileSnapshot: Sendable {
    public let name: ProjectionLeafNameV1
    public let bytes: [UInt8]
    public let encoding: ProjectionFileAttribute
    public let tags: ProjectionFileAttribute
    public let finderTags: ProjectionFileAttribute
    public let stamp: ProjectionFileAttribute
    public let permissions: UInt32
    public let created: ProjectionFileTime?
    public let modified: ProjectionFileTime
    fileprivate let observation: RepositoryEntryObservation
    fileprivate init(name: ProjectionLeafNameV1, value: ProjectionReadValues, observation: RepositoryEntryObservation) {
        self.name = name; bytes = value.bytes; encoding = value.encoding
        tags = value.tags; finderTags = value.finderTags; stamp = value.stamp
        permissions = value.permissions; created = value.created
        modified = ProjectionFileTime(seconds: Int64(bitPattern: observation.identity[5]),
                                      nanoseconds: UInt32(observation.identity[6]))
        self.observation = observation
    }

    /// Binds the local file identity and complete raw metadata to an accepted observation.
    var physicalRecord: PassivePlatformRecordV1 {
        get throws {
            try .init(codec: 0x50524601, bytes: physicalWords + Array(SHA256.hash(
                data: Array("NV projection metadata\0v1\0".utf8) + metadataBytes)))
        }
    }

    /// Retains the original local identity and raw metadata for interrupted source accounting.
    fileprivate var sourceRecord: PassivePlatformRecordV1 {
        get throws { try .init(codec: 0x50525301, bytes: physicalWords + metadataBytes) }
    }

    private var physicalWords: [UInt8] {
        observation.identity.flatMap { sourceInteger($0, width: 8) }
    }

    private var metadataBytes: [UInt8] {
        var record = sourceInteger(UInt64(permissions), width: 4)
        if let created {
            record += [1] + sourceInteger(UInt64(bitPattern: created.seconds), width: 8)
                + sourceInteger(UInt64(created.nanoseconds), width: 4)
        } else { record += [0] }
        for attribute in [encoding, tags, finderTags, stamp] {
            switch attribute {
            case .absent: record += [0]
            case .unsupported: record += [2]
            case .present(let bytes): record += [1] + sourceInteger(UInt64(bytes.count), width: 4) + bytes
            }
        }
        return record
    }

    /// Borrows all buffers for the complete synchronous source operation.
    @safe
    fileprivate func withNativeSource<Result>(_ body: (inout NVProjectionRead) -> Result) -> Result {
        bytes.withUnsafeBufferPointer { data in
            encoding.withNativeObservation { encoding in
                tags.withNativeObservation { tags in
                    finderTags.withNativeObservation { finder in
                        stamp.withNativeObservation { stamp in
                            let w = observation.identity
                            var native = unsafe NVProjectionRead(bytes: .init(mutating: data.baseAddress), count: UInt64(data.count),
                                words: (w[0],w[1],w[2],w[3],w[4],w[5],w[6],w[7],w[8]),
                                encoding: encoding, tags: tags, finder_tags: finder, stamp: stamp, permissions: permissions,
                                has_birth: created == nil ? 0 : 1, birth_seconds: created?.seconds ?? 0,
                                birth_nanoseconds: created?.nanoseconds ?? 0)
                            return unsafe body(&native)
                        }
                    }
                }
            }
        }
    }
}

extension ProjectionFileAttribute {
    @safe
    fileprivate func withNativeObservation<Result>(_ body: (NVProjectionAttribute) -> Result) -> Result {
        let state: Int32, bytes: [UInt8]
        switch self {
        case .absent: state = 0; bytes = []
        case .present(let value): state = 1; bytes = value
        case .unsupported: state = 2; bytes = []
        }
        return bytes.withUnsafeBufferPointer { buffer in
            unsafe body(.init(bytes: .init(mutating: buffer.baseAddress), count: UInt32(buffer.count), state: state))
        }
    }
}

private func sourceInteger(_ value: UInt64, width: Int) -> [UInt8] {
    (0..<width).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
}

/// Shares one immutable descriptor lease across the original command's retry inputs.
private final class ProjectionSourceLease: Sendable {
    private let descriptor: Int32
    fileprivate init(owning descriptor: Int32) { precondition(descriptor >= 0); self.descriptor = descriptor }
    deinit { _ = close(descriptor) }

    fileprivate func withDescriptor<Result>(_ body: (Int32) throws -> Result) rethrows -> Result {
        try withExtendedLifetime(self) { try body(descriptor) }
    }
}

/// One coherent capture and the descriptor retained by that same read.
private struct ProjectionSourceRead: Sendable {
    let file: ProjectionFileSnapshot
    let lease: ProjectionSourceLease
}

/// Root-issued source snapshot attached to a still-live, pre-admission local Delete.
struct CapturedProjectionDeleteSource: Sendable {
    let input: PreparedProjectionDeletion
    fileprivate let source: ProjectionFileSnapshot
    private let lease: ProjectionSourceLease
    fileprivate init(input: PreparedProjectionDeletion, source: ProjectionFileSnapshot, lease: ProjectionSourceLease) {
        self.input = input; self.source = source; self.lease = lease
    }
    var capturedObservation: PassivePlatformRecordV1 { get throws { try source.sourceRecord } }
    fileprivate func withDescriptor<Result>(_ body: (Int32) throws -> Result) rethrows -> Result {
        try lease.withDescriptor(body)
    }
    fileprivate func sameCapture(as other: Self) -> Bool { lease === other.lease }
}

/// Evidence that an attempt ended before creating an owned protected directory.
struct UncapturedProjectionSource: Sendable {
    let reserved: ReservedProjectionSource
    fileprivate init(_ reserved: ReservedProjectionSource) { self.reserved = reserved }
}

/// Independent current observations and errors from one retained source attempt.
struct ProjectionSourceEffect: Sendable {
    let record: ProjectionSourceAttemptV1
    let source: ProjectionFileReadResult
    let cleanup: ProjectionCleanupReadResult
    let reason: RepositoryFileFailure?
    let storageFailure: StorageError?
    let directorySyncError: Int32?
    fileprivate init(record: ProjectionSourceAttemptV1, source: ProjectionFileReadResult,
                     reason: RepositoryFileFailure?, storageFailure: StorageError? = nil, sync: Int32 = 0,
                     cleanup: ProjectionCleanupReadResult = .unavailable(.staleContext)) {
        self.record = record; self.source = source; self.reason = reason
        self.storageFailure = storageFailure; directorySyncError = sync == 0 ? nil : sync
        self.cleanup = cleanup
    }
}

/// Verified removal of the original authorized source, with fresh observations for accounting.
struct ProjectionSourceRemovalReceipt: Sendable {
    let effect: ProjectionSourceEffect
    fileprivate let reserved: ReservedProjectionSource
    fileprivate let permission: RepositoryRootPermission
    fileprivate init(effect: ProjectionSourceEffect, reserved: ReservedProjectionSource, permission: RepositoryRootPermission) {
        self.effect = effect; self.reserved = reserved; self.permission = permission
    }
}

enum ProjectionSourceRemovalResult: Sendable {
    case removed(ProjectionSourceRemovalReceipt), notRemoved(ProjectionSourceEffect), uncertain(ProjectionSourceEffect)
}

/// Fresh read-only observations of the source and its retained recovery locations.
struct ProjectionSourceInspection: Sendable {
    let source: ProjectionFileReadResult
    let cleanup: ProjectionCleanupReadResult
    fileprivate let input: ProjectionSourceRecoveryInput
    fileprivate let permission: RepositoryRootPermission
    fileprivate init(source: ProjectionFileReadResult, cleanup: ProjectionCleanupReadResult,
                     input: ProjectionSourceRecoveryInput, permission: RepositoryRootPermission) {
        self.source = source; self.cleanup = cleanup; self.input = input; self.permission = permission
    }
}

/// Read-only contents at one attempt's nested protected recovery location.
struct ProjectionCleanupSnapshot: Sendable {
    let record: ProjectionSourceAttemptV1
    fileprivate let observation: RepositoryEntryObservation
    fileprivate let value: ProjectionReadValues
    var bytes: [UInt8] { value.bytes }
    var encoding: ProjectionFileAttribute { value.encoding }
    var tags: ProjectionFileAttribute { value.tags }
    var finderTags: ProjectionFileAttribute { value.finderTags }
    var stamp: ProjectionFileAttribute { value.stamp }
    var permissions: UInt32 { value.permissions }
    var created: ProjectionFileTime? { value.created }
    var modified: ProjectionFileTime { .init(seconds: Int64(bitPattern: observation.identity[5]), nanoseconds: UInt32(observation.identity[6])) }
    fileprivate init(record: ProjectionSourceAttemptV1, observation: RepositoryEntryObservation, value: ProjectionReadValues) {
        self.record = record; self.observation = observation; self.value = value
    }
}

enum ProjectionCleanupReadResult: Sendable {
    case snapshot(ProjectionCleanupSnapshot), placeholder, unavailable(RepositoryFileFailure)
}

private enum ProjectionNativeObservation: Sendable {
    case value(ProjectionReadValues, [UInt64]), placeholder, unavailable(RepositoryFileFailure)
}

private struct ProjectionSourceRemovalNative: Sendable {
    var result = NVProjectionCleanupResult()
    var source: ProjectionNativeObservation = .unavailable(.staleContext)
    var cleanup: ProjectionNativeObservation = .unavailable(.staleContext)
}

public enum ProjectionFileReadResult: Sendable {
    case snapshot(ProjectionFileSnapshot), placeholder, unavailable(RepositoryFileFailure)
}

private struct ProjectionReadValues: Sendable {
    let bytes: [UInt8]
    let encoding, tags, finderTags, stamp: ProjectionFileAttribute
    let permissions: UInt32
    let created: ProjectionFileTime?
}

/// Optional advisory metadata has a separate outcome from the required file contents.
public enum ProjectionStampWriteResult: Equatable, Sendable {
    case written, omittedOversized, failed(Int32)
}

/// A temporary preparation location retained for inspection and later owned cleanup.
public struct ProjectionStagingResidue: Sendable {
    fileprivate let directory: URL
    fileprivate init(directory: URL) { self.directory = directory }
}

/// Exact physical installation under one live root permission and frozen history input.
public struct ProjectionCreationReceipt: Sendable {
    public let file: ProjectionFileSnapshot
    public let stamp: ProjectionStampWriteResult
    public let finderTagsError: Int32?
    public let directorySyncError: Int32?
    fileprivate let input: PreparedProjectionCreation
    fileprivate init(file: ProjectionFileSnapshot, input: PreparedProjectionCreation, native: ProjectionCreationNative) {
        self.file = file; self.input = input
        stamp = native.effect.stamp_error != 0 ? .failed(native.effect.stamp_error) :
            (native.omittedStamp ? .omittedOversized : .written)
        finderTagsError = native.effect.finder_tags_error == 0 ? nil : native.effect.finder_tags_error
        directorySyncError = native.effect.directory_sync_error == 0 ? nil : native.effect.directory_sync_error
    }
}

/// Keeps frozen retry input and temporary material separate from an installation receipt.
public struct ProjectionCreationFailure: Sendable {
    public let reason: RepositoryFileFailure
    public let retry: PreparedProjectionCreation
    public let residue: ProjectionStagingResidue?
    public let storageFailure: StorageError?
    fileprivate init(reason: RepositoryFileFailure, input: PreparedProjectionCreation, native: ProjectionCreationNative,
                     storageFailure: StorageError? = nil) {
        self.reason = reason; retry = input; residue = native.stage.map { .init(directory: $0) }
        self.storageFailure = storageFailure
    }
}

public enum ProjectionCreationResult: Sendable {
    case verified(ProjectionCreationReceipt), notInstalled(ProjectionCreationFailure), uncertain(ProjectionCreationFailure)
}

private struct ProjectionCreationNative: Sendable {
    var effect = NVProjectionEffect()
    var stage: URL?
    var value: ProjectionReadValues?
    var words: [UInt64] = []
    var omittedStamp = false
}

/// Exact installed and displaced observations from one still-applicable replacement.
struct ProjectionReplacementReceipt: Sendable {
    let file, displaced: ProjectionFileSnapshot
    let sourceMatched: Bool
    let reservation: ProjectionReplacementAttemptV1
    let stamp: ProjectionStampWriteResult
    let finderTagsError, directorySyncError: Int32?
    fileprivate let input: PreparedProjectionReplacement
    fileprivate init(file: ProjectionFileSnapshot, displaced: ProjectionFileSnapshot,
                     reserved: ReservedProjectionReplacement, sourceMatched: Bool, native: ProjectionReplacementNative) {
        self.file = file; self.displaced = displaced; self.sourceMatched = sourceMatched
        reservation = reserved.record; input = reserved.input
        let effect = native.result.installation
        stamp = effect.stamp_error != 0 ? .failed(effect.stamp_error) : (native.omittedStamp ? .omittedOversized : .written)
        finderTagsError = effect.finder_tags_error == 0 ? nil : effect.finder_tags_error
        directorySyncError = effect.directory_sync_error == 0 ? nil : effect.directory_sync_error
    }
}

/// Retains exact retry ownership and artifact locations after an incomplete physical operation.
struct ProjectionReplacementFailure: Sendable {
    let reason: RepositoryFileFailure
    let reservation: ProjectionReplacementAttemptV1
    let residue: ProjectionStagingResidue?
    let storageFailure: StorageError?
    fileprivate init(reason: RepositoryFileFailure, reserved: ReservedProjectionReplacement,
                     native: ProjectionReplacementNative, storageFailure: StorageError? = nil) {
        self.reason = reason; reservation = reserved.record; residue = native.stage.map { .init(directory: $0) }
        self.storageFailure = storageFailure
    }
}

enum ProjectionReplacementResult: Sendable {
    case installed(ProjectionReplacementReceipt), notInstalled(ProjectionReplacementFailure), uncertain(ProjectionReplacementFailure)
}

/// Independently coherent observations of the two retained names under one live recovery attempt.
/// Later settlement revalidates these observations before changing files or private ownership.
struct ProjectionReplacementInspection: Sendable {
    let current, backup: ProjectionFileReadResult
    fileprivate let input: ProjectionReplacementRecoveryInput
    fileprivate let permission: RepositoryRootPermission
    fileprivate init(current: ProjectionFileReadResult, backup: ProjectionFileReadResult,
                     input: ProjectionReplacementRecoveryInput, permission: RepositoryRootPermission) {
        self.current = current; self.backup = backup; self.input = input; self.permission = permission
    }
}

/// A returned native operation that preserved the destination namespace permits candidate retirement.
struct UninstalledProjectionReplacement: Sendable {
    let reserved: ReservedProjectionReplacement
    fileprivate init(_ reserved: ReservedProjectionReplacement) { self.reserved = reserved }
}

private struct ProjectionReplacementNative: Sendable {
    var result = NVProjectionReplacementResult()
    var stage: URL?
    var installed, displaced: ProjectionReadValues?
    var installedWords: [UInt64] = [], displacedWords: [UInt64] = []
    var omittedStamp = false
}

/// A durably reserved relocation that returned before capturing its source.
struct UncapturedProjectionRelocation: Sendable {
    let reserved: ReservedProjectionRelocation
    fileprivate init(_ reserved: ReservedProjectionRelocation) { self.reserved = reserved }
}

/// Verified output plus independently observed original and retained backup.
struct ProjectionRelocationReceipt: Sendable {
    let file, displaced: ProjectionFileSnapshot
    let source: ProjectionFileReadResult
    let sourceMatched: Bool
    let reservation: ProjectionReplacementAttemptV1
    let stamp: ProjectionStampWriteResult
    let finderTagsError, directorySyncError: Int32?
    fileprivate let input: PreparedProjectionRelocation
    private let original: ProjectionSourceRead
    fileprivate init(file: ProjectionFileSnapshot, displaced: ProjectionFileSnapshot, source: ProjectionFileReadResult,
                     original: ProjectionSourceRead, reserved: ReservedProjectionRelocation, native: ProjectionRelocationNative) {
        self.file = file; self.displaced = displaced; self.source = source; self.original = original
        input = reserved.input; reservation = reserved.record
        let old = original.file
        sourceMatched = displaced.observation.identity.prefix(7).elementsEqual(old.observation.identity.prefix(7)) &&
            displaced.bytes == old.bytes && displaced.permissions == old.permissions && displaced.created == old.created &&
            displaced.encoding == old.encoding && displaced.tags == old.tags && displaced.finderTags == old.finderTags && displaced.stamp == old.stamp
        let effect = native.result.replacement.installation
        stamp = effect.stamp_error != 0 ? .failed(effect.stamp_error) : (native.omittedStamp ? .omittedOversized : .written)
        finderTagsError = effect.finder_tags_error == 0 ? nil : effect.finder_tags_error
        directorySyncError = effect.directory_sync_error == 0 ? nil : effect.directory_sync_error
    }
}

/// Retained attempt and original descriptor after incomplete relocation work.
struct ProjectionRelocationFailure: Sendable {
    let reason: RepositoryFileFailure
    let reservation: ProjectionReplacementAttemptV1
    let residue: ProjectionStagingResidue?
    let storageFailure: StorageError?
    private let original: ProjectionSourceRead
    fileprivate init(reason: RepositoryFileFailure, reserved: ReservedProjectionRelocation, original: ProjectionSourceRead,
                     native: ProjectionRelocationNative, storageFailure: StorageError? = nil) {
        self.reason = reason; reservation = reserved.record; residue = native.stage.map { .init(directory: $0) }
        self.original = original; self.storageFailure = storageFailure
    }
}

enum ProjectionRelocationResult: Sendable {
    case installed(ProjectionRelocationReceipt), notInstalled(ProjectionRelocationFailure), uncertain(ProjectionRelocationFailure)
}

/// Three fresh read-only observations bound to one retained relocation input.
struct ProjectionRelocationInspection: Sendable {
    let source, current, backup: ProjectionFileReadResult
    fileprivate let input: ProjectionRelocationRecoveryInput
    fileprivate let permission: RepositoryRootPermission
    fileprivate init(source: ProjectionFileReadResult, current: ProjectionFileReadResult, backup: ProjectionFileReadResult,
                     input: ProjectionRelocationRecoveryInput, permission: RepositoryRootPermission) {
        self.source = source; self.current = current; self.backup = backup; self.input = input; self.permission = permission
    }
}

private struct ProjectionRelocationNative: Sendable {
    var result = NVProjectionRelocationResult()
    var stage: URL?
    var installed, displaced: ProjectionReadValues?
    var installedWords: [UInt64] = [], displacedWords: [UInt64] = []
    var omittedStamp = false
}

/// Local file residency is separate from successful reading and provider freshness.
public enum RepositoryResidency: Equatable, Sendable { case materialized, dataless, unknown }
public enum RepositoryDownloadStatus: Equatable, Sendable { case notDownloaded, downloaded, current, unknown }
public enum RepositoryProviderManagement: Equatable, Sendable { case ubiquitous, unknown }

/// Copies error categories without retaining provider descriptions or filesystem paths.
public struct RepositoryStatusError: Equatable, Sendable {
    public enum Domain: Sendable { case posix, cocoa, fileProvider, other }
    public let domain: Domain
    public let code: Int
    fileprivate init(_ error: any Error) {
        let error = error as NSError
        switch error.domain {
        case NSPOSIXErrorDomain: domain = .posix
        case NSCocoaErrorDomain: domain = .cocoa
#if canImport(Darwin)
        case NSFileProviderErrorDomain: domain = .fileProvider
#endif
        default: domain = .other
        }
        code = error.code
    }
    fileprivate init?(domain: Int32, code: Int64) {
        guard domain != 0, let code = Int(exactly: code) else { return nil }
        switch domain {
        case 1: self.domain = .posix
        case 2: self.domain = .cocoa
        case 3: self.domain = .fileProvider
        default: self.domain = .other
        }
        self.code = code
    }
}

/// Supplemental selected-item status bound to the exact rooted observation that supplied it.
public struct RepositoryItemAvailability: Sendable {
    public let residency: RepositoryResidency
    public let management: RepositoryProviderManagement
    public let download: RepositoryDownloadStatus
    public let downloading: Bool?
    public let uploaded: Bool?
    public let unresolvedVersions: Bool?
    public let statusError: RepositoryStatusError?
    public let downloadError: RepositoryStatusError?
    public let uploadError: RepositoryStatusError?
    fileprivate let observation: RepositoryEntryObservation
    fileprivate init(_ values: AvailabilityValues, observation: RepositoryEntryObservation) {
        residency = values.residency; management = values.management; download = values.download
        downloading = values.downloading; uploaded = values.uploaded; unresolvedVersions = values.unresolvedVersions
        statusError = values.statusError; downloadError = values.downloadError; uploadError = values.uploadError
        self.observation = observation
    }
}

public enum RepositoryAvailabilityResult: Sendable {
    case observed(RepositoryItemAvailability), unavailable(RepositoryFileFailure)
}
public enum RepositoryMaterializationRequest: Equatable, Sendable {
    case requested, unsupported, failed(RepositoryStatusError)
}

/// A canonical named object with unread bytes, captured by a live physical root.
public struct DisclosedRepositoryObject: Sendable {
    public let locator: SegmentLocator
    fileprivate let observation: RepositoryEntryObservation
    fileprivate let availability: RepositoryItemAvailability
    fileprivate init(locator: SegmentLocator, observation: RepositoryEntryObservation, availability: RepositoryItemAvailability) {
        self.locator = locator; self.observation = observation; self.availability = availability
    }
}
public enum RepositoryObjectDisclosure: Sendable {
    case readable([UInt8]), unread(DisclosedRepositoryObject), unavailable(RepositoryFileFailure)
}

/// Provider identity remains an opaque equality value supplied by the forward lookup API.
public struct RepositoryProviderIdentity: Equatable, Sendable {
    fileprivate let item: String
    fileprivate let domain: String
    fileprivate init(item: String, domain: String) { self.item = item; self.domain = domain }
}
public enum RepositoryProviderLookup: Sendable {
    case identified(RepositoryProviderIdentity), unknown(RepositoryStatusError?), unsupported
}

public struct RepositoryProviderObservation: Sendable {
    public let lookup: RepositoryProviderLookup
    fileprivate let permission: RepositoryRootPermission
    fileprivate init(_ lookup: RepositoryProviderLookup, permission: RepositoryRootPermission) {
        self.lookup = lookup; self.permission = permission
    }
}

/// Carries one live shallow stream's owner, generation and selected directory.
public struct RepositoryListingCursor: Sendable {
    fileprivate let identifier: UUID
    fileprivate let permission: RepositoryRootPermission
    fileprivate let directory: RepositoryProtocolDirectory
    fileprivate init(identifier: UUID, permission: RepositoryRootPermission, directory: RepositoryProtocolDirectory) {
        self.identifier = identifier; self.permission = permission; self.directory = directory
    }
}

/// Discovery names remain raw untrusted bytes until an exact object read validates them.
public struct RepositoryListingPage: Sendable {
    public let names: [RepositoryDiscoveredLeaf]
    public let continuation: RepositoryListingCursor?
    fileprivate init(names: [[UInt8]], continuation: RepositoryListingCursor?) {
        self.names = names.map(RepositoryDiscoveredLeaf.init); self.continuation = continuation
    }
}

/// Preserves an untrusted raw directory leaf independently of canonical object locators.
public struct RepositoryDiscoveredLeaf: Sendable {
    public let bytes: [UInt8]
    fileprivate init(bytes: [UInt8]) { self.bytes = bytes }
    public func relativePath(in directory: RepositoryProtocolDirectory) throws -> String {
        guard let name = String(bytes: bytes, encoding: .utf8), !bytes.isEmpty, bytes.count <= 255,
              !bytes.contains(0), !bytes.contains(47), name != ".", name != ".." else { throw RepositoryRootError.unsafePath }
        return directory.relativePath + "/" + name
    }
}

/// A copied metadata outcome for one raw leaf observed through its held directory.
enum RepositoryMetadataResult: Sendable {
    case observed(RepositoryEntryObservation), unavailable(RepositoryFileFailure), invalidName
}

struct RepositoryMetadataEntry: Sendable {
    let leaf: RepositoryDiscoveredLeaf
    let result: RepositoryMetadataResult
    fileprivate init(leaf: RepositoryDiscoveredLeaf, result: RepositoryMetadataResult) {
        self.leaf = leaf; self.result = result
    }
}

/// Keeps an EOF stream applicable while discovery consumes its bounded pending-name tail.
struct RepositoryMetadataBatch: Sendable {
    let entries: [RepositoryMetadataEntry]
    let cursor: RepositoryListingCursor
    let finished: Bool
    fileprivate init(entries: [RepositoryMetadataEntry], cursor: RepositoryListingCursor, finished: Bool) {
        self.entries = entries; self.cursor = cursor; self.finished = finished
    }
}

/// Opt-in observations of the real rooted metadata/read boundary.
struct RepositoryMetadataWork: Sendable {
    var batches = 0, bulkCalls = 0, statCalls = 0, ancestorChecks = 0
    var singleObservations = 0, bodyReads = 0, bodyBytes = 0, largestBatch = 0, largestNameBytes = 0
}

/// Exact provider-file installation evidence issued after readback and all namespace barriers.
public struct ImmutableInstallation: Sendable {
    public let locator: ImmutableRepositoryLocator
    public let reusedExisting: Bool
    fileprivate let permission: RepositoryRootPermission
    fileprivate let operation: UUID
    fileprivate let collection: CollectionID
    fileprivate let keyID: CollectionKeyID?
    fileprivate init(object: ImmutableRepositoryObject, permission: RepositoryRootPermission, operation: UUID, existing: Bool) {
        self.locator = object.locator; self.collection = object.collection; self.keyID = object.keyID; self.permission = permission
        self.operation = operation; self.reusedExisting = existing
    }
}

/// Preserves effect accounting and exact retry inputs after an unsuccessful installation.
public enum RepositoryNamespaceEffect: Equatable, Sendable { case unchanged, changed, unknown }

/// Captures protocol-name effects separately from retained disposable staging evidence.
public struct RepositoryInstallationFailure: Sendable {
    public let reason: RepositoryFileFailure
    public let protocolNamespaceEffect: RepositoryNamespaceEffect
    public let stageRetained: Bool
    public let cleanupError: Int32?
    public let retry: ImmutableRepositoryObject
    fileprivate init(reason: RepositoryFileFailure, result: NVRootInstallResult, retry: ImmutableRepositoryObject) {
        self.reason = reason
        protocolNamespaceEffect = result.namespace_changed != 0 ? .changed :
            (result.outcome == NV_ROOT_INSTALL_UNCERTAIN ? .unknown : .unchanged)
        stageRetained = result.stage_retained != 0
        cleanupError = result.cleanup_error == 0 ? nil : result.cleanup_error; self.retry = retry
    }
}

public enum RepositoryInstallationResult: Sendable {
    case verified(ImmutableInstallation), notInstalled(RepositoryInstallationFailure), uncertain(RepositoryInstallationFailure)
}

/// An attempt-owned hold keeps repair effects bound to the observed NV Data directory.
struct RepositoryRepairNamespace: Sendable {
    fileprivate let permission: RepositoryRootPermission
    fileprivate let identity: UUID
    fileprivate init(permission: RepositoryRootPermission, identity: UUID) {
        self.permission = permission; self.identity = identity
    }
}

/// Owns repository admission while blocking rooted effects execute on their own resource.
public actor RepositoryRootSession {
    private let session = UUID()
    private let lane: RootLane
    private let coordination: RootCoordinationControl
    private var generation: UInt64 = 0
    public private(set) var state: RepositoryRootState = .active
    private var running = false
    private var providerLookupRunning = false
    private var repairNamespace: UUID?
    var discoveryState: RepositoryDiscoveryState?
    var discoveryRunning = false
    var discoveryInvalidation: UInt64 = 0
    private var transport: (UUID, @Sendable (RepositoryTransportSignal) -> Void)?

    private init(lane: RootLane, coordination: RootCoordinationControl) { self.lane = lane; self.coordination = coordination }

    public static func open(directory: String) async throws -> RepositoryRootSession {
        try await open(directory: directory, securityScope: nil)
    }

    /// Retains applicable security-scoped access for the owned root's full lifetime.
    public static func open(directory: URL) async throws -> RepositoryRootSession {
        guard directory.isFileURL else { throw RepositoryRootError.unsafePath }
        return try await open(directory: directory.path, securityScope: directory)
    }

    /// Exclusively creates one destination beneath an existing parent and retains its root lease.
    public static func create(directory: URL) async throws -> RepositoryRootSession {
        guard directory.isFileURL else { throw RepositoryRootError.unsafePath }
        return try await open(directory: directory.path, securityScope: directory, create: true)
    }

    private static func open(directory: String, securityScope: URL?, create: Bool = false) async throws -> RepositoryRootSession {
        try Task.checkCancellation()
        guard !directory.isEmpty, !directory.utf8.contains(0) else { throw RepositoryRootError.unsafePath }
        let coordination = RootCoordinationControl(), lane = RootLane(coordination: coordination)
        try await lane.open(directory: directory, securityScope: securityScope, create: create)
        if Task.isCancelled { await lane.close(); throw CancellationError() }
        let owner = RepositoryRootSession(lane: lane, coordination: coordination)
        do {
            try await lane.registerPresenter { [weak owner] event in
                Task { await owner?.presented(event) }
            }
            try Task.checkCancellation()
            return owner
        } catch { await owner.close(); throw error }
    }

    private func presented(_ event: RootPresentationEvent) {
        switch state { case .closing, .closed: return; case .active, .fenced: break }
        switch event {
        case .changed, .moved: noteRepositoryChange()
        case .deleting, .evicting: invalidate()
        }
    }

    public func permission() throws -> RepositoryRootPermission {
        try requireActive()
        return RepositoryRootPermission(session: session, generation: generation)
    }

    /// Reserves an absent NV Data name through exclusive creation and namespace barriers.
    func createRepositoryNamespace() async throws {
        let permission = try permission()
        guard !running else { throw RepositoryRootError.busy }
        running = true; defer { settleTurn() }
        try await coordinatedTurn { try await lane.createRepositoryNamespace() }
        try validate(permission)
    }

    func beginRepairNamespace(_ observation: RepositoryEntryObservation,
                              using permission: RepositoryRootPermission) async throws -> RepositoryRepairNamespace {
        try validate(permission); try validate(observation.permission)
        guard observation.relative == "NV Data", observation.kind == .directory else { throw RepositoryRootError.wrongContext }
        guard !running, repairNamespace == nil else { throw RepositoryRootError.busy }
        running = true; defer { settleTurn() }
        do {
            try await coordinatedTurn { try await lane.beginRepairNamespace(observation.identity) }
            try validate(permission)
            let identity = UUID(); repairNamespace = identity
            return .init(permission: permission, identity: identity)
        } catch { await lane.endRepairNamespace(); throw error }
    }

    func createRepairNamespace(using permission: RepositoryRootPermission) async throws -> RepositoryRepairNamespace {
        try validate(permission)
        guard !running, repairNamespace == nil else { throw RepositoryRootError.busy }
        running = true; defer { settleTurn() }
        do {
            try await coordinatedTurn { try await lane.createRepairNamespace() }
            try validate(permission)
            let identity = UUID(); repairNamespace = identity
            return .init(permission: permission, identity: identity)
        } catch { await lane.endRepairNamespace(); throw error }
    }

    func endRepairNamespace(_ namespace: RepositoryRepairNamespace) async throws {
        guard namespace.permission.session == session, repairNamespace == namespace.identity else {
            throw RepositoryRootError.wrongContext
        }
        await lane.endRepairNamespace(); repairNamespace = nil
    }

    /// Captures a passive bookmark and physical hints from the continuously owned directory.
    public func association(for selection: LocalStoreSelection, id: LocalAssociationID) async throws -> LocalAssociationV1 {
        let permission = try permission()
        guard !running else { throw RepositoryRootError.busy }
        running = true; defer { settleTurn() }
        let bookmark = try await coordinatedTurn { try await lane.bookmark() }
        try validate(permission)
        return try LocalAssociationV1(id: id, scope: .init(collection: selection.descriptor.collection,
            store: selection.store, descriptor: selection.descriptor.descriptorID), bookmark: bookmark)
    }

    /// Resolves passive association input and compares it with this independently acquired owner.
    public func matches(_ association: LocalAssociationV1) async throws -> RepositoryRootContinuity {
        let permission = try permission()
        guard !running else { throw RepositoryRootError.busy }
        running = true; defer { settleTurn() }
        let result = try await coordinatedTurn { try await lane.matches(association.bookmark) }
        try validate(permission); return result
    }

    /// Observes one canonical object name; exact readable bytes remain a separate result.
    public func disclosure(at locator: SegmentLocator) async throws -> RepositoryObjectDisclosure {
        let permission = try permission()
        let path = ImmutableRepositoryLocator.segment(locator).relativePath
        let observation: RepositoryEntryObservation
        switch try await inspect(path, using: permission) {
        case .observed(let value): observation = value
        case .unavailable(let failure): return .unavailable(failure)
        }
        guard observation.kind == .regularFile else { return .unavailable(.kindCollision) }
        guard case .observed(let availability) = try await availability(observation, using: permission) else { return .unavailable(.changed) }
        if availability.residency == .dataless || availability.download == .notDownloaded {
            return .unread(.init(locator: locator, observation: observation, availability: availability))
        }
        switch try await read(observation, maximumBytes: Int(ObjectLimitsV1.encodedPayloadBytes + 156), using: permission) {
        case .contents(let contents): return .readable(contents.bytes)
        case .unavailable(let failure):
            switch failure {
            case .io: return .unread(.init(locator: locator, observation: observation, availability: availability))
            case .absent, .changed, .kindCollision, .hardLinked, .sizeLimit, .conflict, .unsupported, .staleContext: return .unavailable(failure)
            }
        }
    }

    /// Checks the disclosure's live owner generation while a provider turn may remain entered.
    func validateDisclosureContext(_ disclosure: DisclosedRepositoryObject) throws {
        try validate(disclosure.observation.permission)
    }
    /// Rechecks the named generation before requesting its bytes.
    func checkDisclosure(_ disclosure: DisclosedRepositoryObject) async throws {
        try validateDisclosureContext(disclosure)
        let current = try await observe(disclosure.observation.relative, using: disclosure.observation.permission)
        guard current.identity == disclosure.observation.identity else { throw RepositoryRootError.stalePermission }
    }
    /// Refreshes readability at choice consumption while preserving the original owner generation.
    func recheckDisclosure(_ evidence: DisclosedRepositoryObject) async throws -> RepositoryObjectDisclosure {
        try validate(evidence.observation.permission)
        let result = try await disclosure(at: evidence.locator)
        if case .unread(let current) = result, current.observation.identity != evidence.observation.identity {
            return .unavailable(.changed)
        }
        return result
    }
    func materialize(_ disclosure: DisclosedRepositoryObject) async throws -> RepositoryMaterializationRequest {
        try await checkDisclosure(disclosure)
        return try await requestMaterialization(disclosure.availability, using: disclosure.observation.permission)
    }

    func attachTransport(_ owner: UUID, signal: @escaping @Sendable (RepositoryTransportSignal) -> Void) throws {
        try requireActive()
        guard transport == nil else { throw RepositoryRootError.busy }
        transport = (owner, signal)
    }
    func detachTransport(_ owner: UUID) { if transport?.0 == owner { transport = nil } }
    func signalTransport(_ signal: RepositoryTransportSignal) { transport?.1(signal) }
    func transportReady() -> Bool { state == .active && !running && !discoveryRunning }
    private func settleTurn() { running = false; signalTransport(.rootSettled) }

    public func observe(_ relative: String, using permission: RepositoryRootPermission) async throws -> RepositoryEntryObservation {
        try await observe(relative, using: permission, beforeRead: {})
    }

    /// The hook brackets the real blocking turn for controlled execution/lifecycle tests.
    func observe(_ relative: String, using permission: RepositoryRootPermission,
                 beforeRead: @escaping @Sendable () -> Void,
                 beforeCoordination: @escaping @Sendable () -> Void = {}) async throws -> RepositoryEntryObservation {
        try Task.checkCancellation()
        try validate(permission)
        try Self.check(relative: relative)
        guard !running else { throw RepositoryRootError.busy }
        running = true
        defer { settleTurn() }
        let words: [UInt64]
        do { words = try await coordinatedTurn { try await lane.observe(relative, beforeRead: beforeRead, beforeCoordination: beforeCoordination) } }
        catch let failure as RootAccessFailure {
            try validate(permission)
            invalidate()
            throw RepositoryRootError.unavailable(failure.code)
        }
        catch { try validate(permission); throw error }
        try validate(permission)
        return try RepositoryEntryObservation(permission: permission, words: words, relative: relative)
    }

    public func inspect(_ relative: String, using permission: RepositoryRootPermission) async throws -> RepositoryObservationResult {
        do { return .observed(try await observe(relative, using: permission)) }
        catch RepositoryRootError.unavailable(let code) {
            try validate(permission)
            return .unavailable(RepositoryFileFailure(code: code))
        }
    }

    public func read(_ observation: RepositoryEntryObservation, maximumBytes: Int,
                     using permission: RepositoryRootPermission) async throws -> RepositoryReadResult {
        try Task.checkCancellation(); try validate(permission); try validate(observation.permission)
        guard maximumBytes >= 0, UInt64(maximumBytes) <= ObjectLimitsV1.encodedPayloadBytes + 156,
              observation.byteCount <= UInt64(maximumBytes) else { return .unavailable(.sizeLimit) }
        guard observation.kind == .regularFile else { return .unavailable(.kindCollision) }
        guard observation.identity[4] == 1 else { return .unavailable(.hardLinked) }
        guard !running else { throw RepositoryRootError.busy }
        running = true; defer { settleTurn() }
        do {
            let bytes = try await coordinatedTurn { try await lane.read(observation.relative, expected: observation.identity) }
            try validate(permission)
            return .contents(RepositoryFileContents(bytes: bytes, observation: observation))
        } catch let failure as RootAccessFailure {
            try validate(permission); invalidate(); throw RepositoryRootError.unavailable(failure.code)
        } catch RepositoryRootError.unavailable(let code) {
            try validate(permission); return .unavailable(RepositoryFileFailure(code: code))
        }
    }

    /// Reads a selected note through the coordinated descriptor and publishes its exact metadata.
    public func readProjection(_ observation: RepositoryEntryObservation, maximumBytes: Int,
                               using permission: RepositoryRootPermission) async throws -> ProjectionFileReadResult {
        try await readProjection(observation, maximumBytes: maximumBytes, using: permission, beforeRead: {})
    }

    /// Binds an accepted physical relationship to its original local Delete before admission.
    func captureProjectionDeletion(_ input: PreparedProjectionDeletion, source: ProjectionFileSnapshot,
                                   from store: LocalStoreSession, using permission: RepositoryRootPermission,
                                   beforeIssue: @escaping @Sendable () async throws -> Void = {}) async throws -> CapturedProjectionDeleteSource {
        try Task.checkCancellation(); try validate(permission); try validate(source.observation.permission)
        guard source.name == input.source.output.binding.descriptor.filename, source.bytes == input.bytes,
              try source.physicalRecord == input.source.physical else { throw RepositoryRootError.wrongContext }
        guard !running else { throw RepositoryRootError.busy }
        running = true; defer { settleTurn() }
        try await store.checkProjectionDeletionCapture(input)
        let relationship = try await coordinatedTurn { try await lane.matches(input.association.bookmark) }
        guard relationship == .same else { throw RepositoryRootError.wrongContext }
        let read: ProjectionSourceRead
        do { read = try await coordinatedTurn { try await lane.captureProjectionSource(source) } }
        catch let failure as RootAccessFailure {
            try validate(permission); invalidate(); throw RepositoryRootError.unavailable(failure.code)
        }
        guard read.file.bytes == source.bytes, try read.file.physicalRecord == source.physicalRecord else {
            throw RepositoryRootError.wrongContext
        }
        try validate(permission); try validate(source.observation.permission); try Task.checkCancellation()
        try await beforeIssue()
        try await store.checkProjectionDeletionCapture(input)
        try validate(permission); try Task.checkCancellation()
        return CapturedProjectionDeleteSource(input: input, source: read.file, lease: read.lease)
    }

    /// Checks original live file ownership and the exact committed Delete before reserved removal.
    func validate(_ deletion: AuthorizedProjectionDeletion, from store: LocalStoreSession,
                  using permission: RepositoryRootPermission) async throws {
        try Task.checkCancellation(); try validate(permission); try validate(deletion.original.source.observation.permission)
        guard !running else { throw RepositoryRootError.busy }
        running = true; defer { settleTurn() }
        try await store.checkProjectionDeletion(deletion)
        let relationship = try await coordinatedTurn { try await lane.matches(deletion.original.input.association.bookmark) }
        guard relationship == .same else { throw RepositoryRootError.wrongContext }
        try validate(permission); try Task.checkCancellation()
        try await store.checkProjectionDeletion(deletion)
        try validate(permission); try Task.checkCancellation()
    }

    /// Removes the original still-matching source within one reserved deletion accessor.
    func removeProjectionSource(_ deletion: AuthorizedProjectionDeletion, from store: LocalStoreSession,
                                using permission: RepositoryRootPermission, maximumBytes: Int,
                                reserved: @escaping @Sendable (ProjectionSourceAttemptV1) async throws -> Void = { _ in },
                                beforeRemoval: @escaping @Sendable () -> Void = {},
                                afterRemoval: @escaping @Sendable () -> Void = {}) async throws -> ProjectionSourceRemovalResult {
        try Task.checkCancellation(); try validate(permission); try validate(deletion.original.source.observation.permission)
        guard maximumBytes >= deletion.original.source.bytes.count else { throw RepositoryRootError.unsupported(EINVAL) }
        guard !running else { throw RepositoryRootError.busy }
        running = true; defer { settleTurn() }
        try await store.checkProjectionDeletion(deletion)
        let relationship = try await coordinatedTurn { try await lane.matches(deletion.original.input.association.bookmark) }
        guard relationship == .same else { throw RepositoryRootError.wrongContext }
        try validate(permission); try Task.checkCancellation()
        let attempt = try await store.reserveProjectionSource(deletion)
        try await reserved(attempt.record)
        try validate(permission); try Task.checkCancellation()
        try await store.checkProjectionSourceReservation(attempt)
        try validate(permission); try Task.checkCancellation()
        let native = await coordinatedTurn {
            await lane.removeProjectionSource(attempt, maximum: maximumBytes,
                beforeRemoval: beforeRemoval, afterRemoval: afterRemoval)
        }
        if native.result.root_lost != 0 { invalidate() }
        let sourceName = attempt.record.source.output.binding.descriptor.filename
        let source = try projectionObservation(native.source, name: sourceName, permission: permission)
        let cleanup = try cleanupObservation(native.cleanup, record: attempt.record, permission: permission)
        func effect(_ reason: RepositoryFileFailure? = nil, storage: StorageError? = nil) -> ProjectionSourceEffect {
            .init(record: attempt.record, source: source, reason: reason, storageFailure: storage,
                  sync: native.result.directory_sync_error, cleanup: cleanup)
        }
        do {
            try validate(permission); try Task.checkCancellation()
            try await store.checkProjectionSourceReservation(attempt)
            try validate(permission); try Task.checkCancellation()
        } catch { return .uncertain(effect(.staleContext, storage: classify(error))) }
        switch Int(native.result.outcome) {
        case NV_PROJECTION_CLEANUP_REMOVED:
            guard native.result.directory_created == 1 else { return .uncertain(effect(.changed)) }
            guard case .unavailable(.absent) = source else { return .uncertain(effect(.changed)) }
            guard case .unavailable(.absent) = cleanup else { return .uncertain(effect(.changed)) }
            return .removed(.init(effect: effect(), reserved: attempt, permission: permission))
        case NV_PROJECTION_CLEANUP_NO_EFFECT:
            if native.result.directory_created == 0 { try await store.retireProjectionSource(.init(attempt)) }
            return .notRemoved(effect(.init(code: native.result.error)))
        default: return .uncertain(effect(.init(code: native.result.error)))
        }
    }

    /// Rechecks a removal result against its exact original capture before later settlement.
    func validate(_ receipt: ProjectionSourceRemovalReceipt, for deletion: AuthorizedProjectionDeletion, from store: LocalStoreSession,
                  using permission: RepositoryRootPermission) async throws {
        try validate(permission); try validate(receipt.permission)
        guard receipt.reserved.authorization.deletion == deletion.deletion,
              receipt.reserved.authorization.original.sameCapture(as: deletion.original) else { throw RepositoryRootError.wrongContext }
        try validate(deletion.original.source.observation.permission)
        try await store.checkProjectionSourceReservation(receipt.reserved)
        try validate(permission)
    }

    /// Reads the public source and protected recovery child while preserving their durable owner.
    func inspectProjectionSource(_ input: ProjectionSourceRecoveryInput, from store: LocalStoreSession,
                                 maximumBytes: Int, using permission: RepositoryRootPermission,
                                 beforeRead: @escaping @Sendable (String) async throws -> Void = { _ in }) async throws -> ProjectionSourceInspection {
        try validate(permission); try Task.checkCancellation()
        guard maximumBytes >= 0 else { throw RepositoryRootError.unsupported(EINVAL) }
        guard !running else { throw RepositoryRootError.busy }
        running = true; defer { settleTurn() }
        try await store.checkProjectionSourceRecovery(input)
        let relationship = try await coordinatedTurn { try await lane.matches(input.record.root) }
        guard relationship == .same else { throw RepositoryRootError.wrongContext }
        let sourceName = input.record.source.output.binding.descriptor.filename
        try await beforeRead(sourceName.spelling.string)
        let source = try await inspectProjectionCandidate(sourceName, maximumBytes: maximumBytes, using: permission)
        try await beforeRead(input.record.cleanupDirectoryName + "/item")
        let retained = try await coordinatedTurn { try await lane.inspectProjectionCleanup(input.record, maximum: maximumBytes) }
        let cleanup = try cleanupObservation(retained, record: input.record, permission: permission)
        try await store.checkProjectionSourceRecovery(input)
        try validate(permission); try Task.checkCancellation()
        return .init(source: source, cleanup: cleanup, input: input, permission: permission)
    }

    func validate(_ inspection: ProjectionSourceInspection, for input: ProjectionSourceRecoveryInput, from store: LocalStoreSession,
                  using permission: RepositoryRootPermission) async throws {
        try validate(permission); try validate(inspection.permission)
        try inspection.input.checkInspection(input)
        try await store.checkProjectionSourceRecovery(input)
        try validate(permission)
    }

    private func projectionObservation(_ value: ProjectionNativeObservation, name: ProjectionLeafNameV1,
                                       permission: RepositoryRootPermission) throws -> ProjectionFileReadResult {
        switch value {
        case .value(let bytes, let words):
            let observation = try RepositoryEntryObservation(permission: permission, words: words, relative: name.spelling.string)
            return .snapshot(.init(name: name, value: bytes, observation: observation))
        case .placeholder: return .placeholder
        case .unavailable(let failure): return .unavailable(failure)
        }
    }

    private func cleanupObservation(_ value: ProjectionNativeObservation, record: ProjectionSourceAttemptV1,
                                    permission: RepositoryRootPermission) throws -> ProjectionCleanupReadResult {
        switch value {
        case .value(let bytes, let words):
            let observation = try RepositoryEntryObservation(permission: permission, words: words, relative: record.cleanupDirectoryName + "/item")
            return .snapshot(.init(record: record, observation: observation, value: bytes))
        case .placeholder: return .placeholder
        case .unavailable(let failure): return .unavailable(failure)
        }
    }

    /// Installs one exact durable frozen output at an exclusively acquired filename.
    public func createProjection(_ input: PreparedProjectionCreation, from store: LocalStoreSession,
                                 using permission: RepositoryRootPermission) async throws -> ProjectionCreationResult {
        try await createProjection(input, from: store, using: permission, staged: { _ in }, beforeInstall: {}, afterInstall: {})
    }

    /// Holds real stage/namespace boundaries for independently controlled interference.
    func createProjection(_ input: PreparedProjectionCreation, from store: LocalStoreSession,
                          using permission: RepositoryRootPermission, staged: @escaping @Sendable (URL) -> Void,
                          beforeInstall: @escaping @Sendable () -> Void,
                          afterInstall: @escaping @Sendable () -> Void) async throws -> ProjectionCreationResult {
        try Task.checkCancellation(); try validate(permission)
        guard !running else { throw RepositoryRootError.busy }
        running = true; defer { settleTurn() }
        try await store.checkProjectionCreation(input)
        let relationship = try await coordinatedTurn { try await lane.matches(input.association.bookmark) }
        guard relationship == .same else { throw RepositoryRootError.wrongContext }
        try validate(permission); try Task.checkCancellation()
        let native = await coordinatedTurn {
            await lane.createProjection(input, staged: staged, beforeInstall: beforeInstall, afterInstall: afterInstall)
        }
        if native.effect.root_lost != 0 { invalidate() }
        do { try validate(permission); try Task.checkCancellation() }
        catch { return .uncertain(.init(reason: .staleContext, input: input, native: native)) }
        do { try await store.checkProjectionCreation(input) }
        catch { return .uncertain(.init(reason: .staleContext, input: input, native: native, storageFailure: classify(error))) }
        do { try validate(permission); try Task.checkCancellation() }
        catch { return .uncertain(.init(reason: .staleContext, input: input, native: native)) }
        switch Int(native.effect.outcome) {
        case NV_PROJECTION_INSTALLED:
            guard let value = native.value else { return .uncertain(.init(reason: .changed, input: input, native: native)) }
            let observation = try RepositoryEntryObservation(permission: permission, words: native.words,
                relative: input.output.binding.descriptor.filename.spelling.string)
            let file = ProjectionFileSnapshot(name: input.output.binding.descriptor.filename, value: value, observation: observation)
            return .verified(.init(file: file, input: input, native: native))
        case NV_PROJECTION_NO_EFFECT, NV_PROJECTION_STAGED:
            return .notInstalled(.init(reason: .init(code: native.effect.error), input: input, native: native))
        default:
            return .uncertain(.init(reason: .init(code: native.effect.error), input: input, native: native))
        }
    }

    /// Fences a physical receipt to its original input, issuing root and current durable owner.
    public func validate(_ receipt: ProjectionCreationReceipt, for input: PreparedProjectionCreation,
                         from store: LocalStoreSession, using permission: RepositoryRootPermission) async throws {
        try validate(permission); try validate(receipt.file.observation.permission)
        guard receipt.input.attempt == input.attempt else { throw RepositoryRootError.wrongContext }
        try await store.checkProjectionCreation(input)
        try validate(permission); try validate(receipt.file.observation.permission)
    }

    /// Binds a durable backup reservation to one entered replacement and preserves its displaced source.
    func replaceProjection(_ input: PreparedProjectionReplacement, source: ProjectionFileSnapshot,
                           from store: LocalStoreSession, using permission: RepositoryRootPermission,
                           maximumDisplacedBytes: Int,
                           reserved: @escaping @Sendable (ProjectionReplacementAttemptV1) async throws -> Void = { _ in },
                           staged: @escaping @Sendable (URL) -> Void = { _ in },
                           beforeInstall: @escaping @Sendable () -> Void = {},
                           afterInstall: @escaping @Sendable () -> Void = {}) async throws -> ProjectionReplacementResult {
        try Task.checkCancellation(); try validate(permission); try validate(source.observation.permission)
        guard maximumDisplacedBytes >= 0, source.name == input.source.output.binding.descriptor.filename,
              source.bytes == input.sourceBytes else { throw RepositoryRootError.wrongContext }
        guard input.source.physical == (try source.physicalRecord) else { throw RepositoryRootError.wrongContext }
        guard !running else { throw RepositoryRootError.busy }
        running = true; defer { settleTurn() }
        try await store.checkProjectionReplacement(input)
        let relationship = try await coordinatedTurn { try await lane.matches(input.association.bookmark) }
        guard relationship == .same else { throw RepositoryRootError.wrongContext }
        try validate(permission); try Task.checkCancellation()
        let attempt = try await store.reserveProjectionReplacement(input, root: input.association.bookmark,
            source: source.physicalRecord)
        // After reservation every interruption retains a discoverable candidate for fresh inspection.
        try await reserved(attempt.record)
        try validate(permission); try Task.checkCancellation()
        try await store.checkProjectionReplacementReservation(attempt)
        try validate(permission); try Task.checkCancellation()
        let native = await coordinatedTurn {
            await lane.replaceProjection(attempt, source: source, maximumDisplacedBytes: maximumDisplacedBytes,
                staged: staged, beforeInstall: beforeInstall, afterInstall: afterInstall)
        }
        if native.result.installation.root_lost != 0 { invalidate() }
        do { try validate(permission); try Task.checkCancellation() }
        catch { return .uncertain(.init(reason: .staleContext, reserved: attempt, native: native)) }
        do { try await store.checkProjectionReplacementReservation(attempt) }
        catch { return .uncertain(.init(reason: .staleContext, reserved: attempt, native: native, storageFailure: classify(error))) }
        do { try validate(permission); try Task.checkCancellation() }
        catch { return .uncertain(.init(reason: .staleContext, reserved: attempt, native: native)) }
        switch Int(native.result.installation.outcome) {
        case NV_PROJECTION_INSTALLED:
            guard let installed = native.installed, let displaced = native.displaced else {
                return .uncertain(.init(reason: .changed, reserved: attempt, native: native))
            }
            let current = try RepositoryEntryObservation(permission: permission, words: native.installedWords,
                relative: input.output.binding.descriptor.filename.spelling.string)
            let backup = try RepositoryEntryObservation(permission: permission, words: native.displacedWords,
                relative: attempt.record.backupName)
            let backupName = try ProjectionLeafNameV1(ExactUTF8(bytes: Array(attempt.record.backupName.utf8)))
            return .installed(.init(file: .init(name: input.output.binding.descriptor.filename, value: installed, observation: current),
                displaced: .init(name: backupName, value: displaced, observation: backup),
                reserved: attempt, sourceMatched: displaced.bytes == input.sourceBytes, native: native))
        case NV_PROJECTION_NO_EFFECT, NV_PROJECTION_STAGED:
            try await store.retireProjectionReplacement(.init(attempt))
            return .notInstalled(.init(reason: .init(code: native.result.installation.error), reserved: attempt, native: native))
        default:
            return .uncertain(.init(reason: .init(code: native.result.installation.error), reserved: attempt, native: native))
        }
    }

    /// Captures the live original before reserving and entering its frozen rename/update.
    func relocateProjection(_ input: PreparedProjectionRelocation, source: ProjectionFileSnapshot,
                            from store: LocalStoreSession, using permission: RepositoryRootPermission,
                            maximumDisplacedBytes: Int,
                            reserved: @escaping @Sendable (ProjectionReplacementAttemptV1) async throws -> Void = { _ in },
                            staged: @escaping @Sendable (URL) -> Void = { _ in },
                            beforeInstall: @escaping @Sendable () -> Void = {},
                            afterInstall: @escaping @Sendable () -> Void = {}) async throws -> ProjectionRelocationResult {
        try Task.checkCancellation(); try validate(permission); try validate(source.observation.permission)
        let sourcePhysical = try source.physicalRecord
        guard maximumDisplacedBytes >= 0, source.name == input.source.output.binding.descriptor.filename,
              source.bytes == input.sourceBytes, sourcePhysical == input.source.physical else { throw RepositoryRootError.wrongContext }
        guard !running else { throw RepositoryRootError.busy }
        running = true; defer { settleTurn() }
        try await store.checkProjectionRelocation(input)
        guard try await store.pendingProjectionReplacement(for: input.output.binding.birth) == nil else { throw StorageError.busy }
        let relationship = try await coordinatedTurn { try await lane.matches(input.association.bookmark) }
        guard relationship == .same else { throw RepositoryRootError.wrongContext }
        let captured: ProjectionSourceRead
        do { captured = try await coordinatedTurn { try await lane.captureProjectionSource(source) } }
        catch let failure as RootAccessFailure {
            try validate(permission); invalidate(); throw RepositoryRootError.unavailable(failure.code)
        }
        guard captured.file.bytes == source.bytes, try captured.file.physicalRecord == sourcePhysical else { throw RepositoryRootError.wrongContext }
        try validate(permission); try Task.checkCancellation()
        let attempt = try await store.reserveProjectionRelocation(input, root: input.association.bookmark, source: captured.file.physicalRecord)
        try await reserved(attempt.record)
        try validate(permission); try Task.checkCancellation()
        try await store.checkProjectionRelocationReservation(attempt)
        try validate(permission); try Task.checkCancellation()
        let native = await coordinatedTurn {
            await lane.relocateProjection(attempt, original: captured, maximumDisplacedBytes: maximumDisplacedBytes,
                staged: staged, beforeInstall: beforeInstall, afterInstall: afterInstall)
        }
        if native.result.replacement.installation.root_lost != 0 { invalidate() }
        do {
            try validate(permission); try Task.checkCancellation()
            try await store.checkProjectionRelocationReservation(attempt)
            try validate(permission); try Task.checkCancellation()
        } catch {
            return .uncertain(.init(reason: .staleContext, reserved: attempt, original: captured, native: native, storageFailure: classify(error)))
        }
        switch Int(native.result.replacement.installation.outcome) {
        case NV_PROJECTION_INSTALLED:
            guard let installed = native.installed, let displaced = native.displaced else {
                return .uncertain(.init(reason: .changed, reserved: attempt, original: captured, native: native))
            }
            let current: ProjectionFileReadResult
            do {
                current = try await inspectProjectionCandidate(source.name, maximumBytes: maximumDisplacedBytes, using: permission)
                try await store.checkProjectionRelocationReservation(attempt)
                try validate(permission); try Task.checkCancellation()
            } catch {
                return .uncertain(.init(reason: .staleContext, reserved: attempt, original: captured, native: native, storageFailure: classify(error)))
            }
            let installedObservation = try RepositoryEntryObservation(permission: permission, words: native.installedWords,
                relative: input.output.binding.descriptor.filename.spelling.string)
            let backupName = try ProjectionLeafNameV1(ExactUTF8(bytes: Array(attempt.record.backupName.utf8)))
            let backupObservation = try RepositoryEntryObservation(permission: permission, words: native.displacedWords, relative: attempt.record.backupName)
            return .installed(.init(file: .init(name: input.output.binding.descriptor.filename, value: installed, observation: installedObservation),
                displaced: .init(name: backupName, value: displaced, observation: backupObservation), source: current,
                original: captured, reserved: attempt, native: native))
        case NV_PROJECTION_NO_EFFECT, NV_PROJECTION_STAGED:
            if native.result.source.outcome == NV_PROJECTION_SOURCE_NO_EFFECT {
                try await store.retireProjectionRelocation(.init(attempt))
            }
            return .notInstalled(.init(reason: .init(code: native.result.replacement.installation.error), reserved: attempt, original: captured, native: native))
        default:
            return .uncertain(.init(reason: .init(code: native.result.replacement.installation.error), reserved: attempt, original: captured, native: native))
        }
    }

    func validate(_ receipt: ProjectionRelocationReceipt, for input: PreparedProjectionRelocation,
                  from store: LocalStoreSession, using permission: RepositoryRootPermission) async throws {
        try validate(permission); try validate(receipt.file.observation.permission); try validate(receipt.displaced.observation.permission)
        guard receipt.input.attempt == input.attempt else { throw RepositoryRootError.wrongContext }
        try await store.checkProjectionRelocation(input)
        guard try await store.pendingProjectionReplacement(for: input.output.binding.birth) == receipt.reservation else { throw StorageError.staleCapture }
        try validate(permission)
    }

    /// Reads retained names without reconstructing the interrupted operation's move permission.
    func inspectProjectionRelocation(_ input: ProjectionRelocationRecoveryInput, from store: LocalStoreSession,
                                     maximumBytes: Int, using permission: RepositoryRootPermission,
                                     afterRead: @escaping @Sendable () async throws -> Void = {}) async throws -> ProjectionRelocationInspection {
        try Task.checkCancellation(); try validate(permission)
        guard maximumBytes >= 0 else { throw RepositoryRootError.wrongContext }
        guard !running else { throw RepositoryRootError.busy }
        running = true; defer { settleTurn() }
        try await store.checkProjectionRelocationRecovery(input)
        let same = try await coordinatedTurn { try await lane.matches(input.record.root) }
        guard same == .same, let previous = input.record.transition.source else { throw RepositoryRootError.wrongContext }
        try validate(permission); try Task.checkCancellation()
        let source = try await inspectProjectionCandidate(previous.output.binding.descriptor.filename, maximumBytes: maximumBytes, using: permission)
        let current = try await inspectProjectionCandidate(input.record.transition.output.binding.descriptor.filename, maximumBytes: maximumBytes, using: permission)
        let backupName = try ProjectionLeafNameV1(ExactUTF8(bytes: Array(input.record.backupName.utf8)))
        let backup = try await inspectProjectionCandidate(backupName, maximumBytes: maximumBytes, using: permission)
        try await afterRead()
        try validate(permission); try Task.checkCancellation()
        try await store.checkProjectionRelocationRecovery(input)
        try validate(permission); try Task.checkCancellation()
        return .init(source: source, current: current, backup: backup, input: input, permission: permission)
    }

    func validate(_ inspection: ProjectionRelocationInspection, for input: ProjectionRelocationRecoveryInput,
                  from store: LocalStoreSession, using permission: RepositoryRootPermission) async throws {
        try validate(permission); try validate(inspection.permission)
        try inspection.input.checkContext(input)
        try await store.checkProjectionRelocationRecovery(input)
        try validate(permission); try validate(inspection.permission)
    }

    /// Rechecks the root, input and durable reservation before a later physical receipt consumer proceeds.
    func validate(_ receipt: ProjectionReplacementReceipt, for input: PreparedProjectionReplacement,
                  from store: LocalStoreSession, using permission: RepositoryRootPermission) async throws {
        try validate(permission); try validate(receipt.file.observation.permission); try validate(receipt.displaced.observation.permission)
        guard receipt.input.attempt == input.attempt else { throw RepositoryRootError.wrongContext }
        try await store.checkProjectionReplacement(input)
        guard try await store.pendingProjectionReplacement(for: input.output.binding.birth) == receipt.reservation else {
            throw StorageError.staleCapture
        }
        try validate(permission)
    }

    /// Inspects the retained target and candidate using fresh reads after interruption or restart.
    func inspectProjectionReplacement(_ input: ProjectionReplacementRecoveryInput, from store: LocalStoreSession,
                                      maximumBytes: Int, using permission: RepositoryRootPermission,
                                      afterRead: @escaping @Sendable () async throws -> Void = {}) async throws -> ProjectionReplacementInspection {
        try Task.checkCancellation(); try validate(permission)
        guard maximumBytes >= 0 else { throw RepositoryRootError.wrongContext }
        guard !running else { throw RepositoryRootError.busy }
        running = true; defer { settleTurn() }
        try await store.checkProjectionReplacementRecovery(input)
        let same = try await coordinatedTurn { try await lane.matches(input.record.root) }
        guard same == .same else { throw RepositoryRootError.wrongContext }
        try validate(permission); try Task.checkCancellation()
        let current = try await inspectProjectionCandidate(input.record.transition.output.binding.descriptor.filename,
            maximumBytes: maximumBytes, using: permission)
        let backupName = try ProjectionLeafNameV1(ExactUTF8(bytes: Array(input.record.backupName.utf8)))
        let backup = try await inspectProjectionCandidate(backupName, maximumBytes: maximumBytes, using: permission)
        try await afterRead()
        try validate(permission); try Task.checkCancellation()
        try await store.checkProjectionReplacementRecovery(input)
        try validate(permission); try Task.checkCancellation()
        return ProjectionReplacementInspection(current: current, backup: backup, input: input, permission: permission)
    }

    /// Maintains the issuing root and durable candidate boundary for consumers of a past inspection.
    func validate(_ inspection: ProjectionReplacementInspection, for input: ProjectionReplacementRecoveryInput, from store: LocalStoreSession,
                  using permission: RepositoryRootPermission) async throws {
        try validate(permission); try validate(inspection.permission)
        try inspection.input.checkContext(input)
        try await store.checkProjectionReplacementRecovery(inspection.input)
        try validate(permission); try validate(inspection.permission)
    }

    private func inspectProjectionCandidate(_ name: ProjectionLeafNameV1, maximumBytes: Int,
                                            using permission: RepositoryRootPermission) async throws -> ProjectionFileReadResult {
        do {
            let relative = name.spelling.string
            let words = try await coordinatedTurn { try await lane.observe(relative, beforeRead: {}, beforeCoordination: {}) }
            try validate(permission); try Task.checkCancellation()
            let observation = try RepositoryEntryObservation(permission: permission, words: words, relative: relative)
            guard observation.kind == .regularFile else { return .unavailable(.kindCollision) }
            guard words[4] == 1 else { return .unavailable(.hardLinked) }
            guard observation.byteCount <= UInt64(maximumBytes) else { return .unavailable(.sizeLimit) }
            let value = try await coordinatedTurn {
                try await lane.readProjection(relative, expected: words, maximum: maximumBytes, beforeRead: {})
            }
            try validate(permission); try Task.checkCancellation()
            guard let value else { return .placeholder }
            return .snapshot(.init(name: name, value: value, observation: observation))
        } catch let failure as RootAccessFailure {
            try validate(permission); invalidate(); throw RepositoryRootError.unavailable(failure.code)
        } catch RepositoryRootError.unavailable(let code) {
            try validate(permission); return .unavailable(.init(code: code))
        }
    }

    /// Brackets the actual granted read for deterministic native-interference tests.
    func readProjection(_ observation: RepositoryEntryObservation, maximumBytes: Int,
                        using permission: RepositoryRootPermission,
                        beforeRead: @escaping @Sendable () -> Void) async throws -> ProjectionFileReadResult {
        try Task.checkCancellation(); try validate(permission); try validate(observation.permission)
        let name = try ProjectionLeafNameV1(ExactUTF8(bytes: Array(observation.relative.utf8)))
        guard observation.kind == .regularFile else { return .unavailable(.kindCollision) }
        guard observation.identity[4] == 1 else { return .unavailable(.hardLinked) }
        guard maximumBytes >= 0,
              observation.byteCount <= UInt64(maximumBytes) else { return .unavailable(.sizeLimit) }
        guard !running else { throw RepositoryRootError.busy }
        running = true; defer { settleTurn() }
        do {
            let value = try await coordinatedTurn {
                try await lane.readProjection(observation.relative, expected: observation.identity,
                                              maximum: maximumBytes, beforeRead: beforeRead)
            }
            try validate(permission)
            try Task.checkCancellation()
            guard let value else { return .placeholder }
            return .snapshot(ProjectionFileSnapshot(name: name, value: value, observation: observation))
        } catch let failure as RootAccessFailure {
            try validate(permission); invalidate(); throw RepositoryRootError.unavailable(failure.code)
        } catch RepositoryRootError.unavailable(let code) {
            try validate(permission); return .unavailable(RepositoryFileFailure(code: code))
        }
    }

    /// Reads metadata for one disclosed item while preserving exact generation and root checks.
    public func availability(_ observation: RepositoryEntryObservation,
                             using permission: RepositoryRootPermission) async throws -> RepositoryAvailabilityResult {
        try Task.checkCancellation(); try validate(permission); try validate(observation.permission)
        guard !running else { throw RepositoryRootError.busy }
        running = true; defer { settleTurn() }
        do {
            let values = try await coordinatedTurn { try await lane.availability(observation.relative, expected: observation.identity) }
            try validate(permission)
            return .observed(.init(values, observation: observation))
        } catch let failure as RootAccessFailure {
            try validate(permission); invalidate(); throw RepositoryRootError.unavailable(failure.code)
        } catch RepositoryRootError.unavailable(let code) {
            try validate(permission); return .unavailable(.init(code: code))
        }
    }

    public func validate(_ availability: RepositoryItemAvailability, using permission: RepositoryRootPermission) throws {
        try validate(permission); try validate(availability.observation.permission)
    }

    /// Requests one selected ubiquitous item; the subsequent exact read establishes usable bytes.
    public func requestMaterialization(_ availability: RepositoryItemAvailability,
                                       using permission: RepositoryRootPermission) async throws -> RepositoryMaterializationRequest {
        try Task.checkCancellation(); try validate(availability, using: permission)
        guard availability.management == .ubiquitous else { return .unsupported }
        guard !running else { throw RepositoryRootError.busy }
        running = true; defer { settleTurn() }
        let observation = availability.observation
        do {
            let request = try await coordinatedTurn { try await lane.materialize(observation.relative, expected: observation.identity) }
            try validate(permission); return request
        } catch let failure as RootAccessFailure {
            try validate(permission); invalidate(); throw RepositoryRootError.unavailable(failure.code)
        } catch { try validate(permission); throw error }
    }

    /// Obtains optional forward identity from a positively rooted URL, then checks its live issuer.
    public func providerObservation(using permission: RepositoryRootPermission) async throws -> RepositoryProviderObservation {
        try await providerObservation(using: permission, beforeDelivery: {})
    }

    func providerObservation(using permission: RepositoryRootPermission,
                             beforeDelivery: @Sendable () async -> Void) async throws -> RepositoryProviderObservation {
        try Task.checkCancellation(); try validate(permission)
        guard !providerLookupRunning else { throw RepositoryRootError.busy }
        providerLookupRunning = true; defer { providerLookupRunning = false }
#if canImport(Darwin)
        let invalidation = discoveryInvalidation
        guard let url = try await captureProviderURL(using: permission) else {
            return .init(.unknown(nil), permission: permission)
        }
        let lookup = await withCheckedContinuation { continuation in
            NSFileProviderManager.getIdentifierForUserVisibleFile(at: url) { item, domain, error in
                let result: RepositoryProviderLookup
                if let error { result = .unknown(.init(error)) }
                else if let item, let domain, !item.rawValue.isEmpty, !domain.rawValue.isEmpty {
                    result = .identified(.init(item: item.rawValue, domain: domain.rawValue))
                } else { result = .unknown(nil) }
                continuation.resume(returning: result)
            }
        }
        await beforeDelivery()
        try Task.checkCancellation(); try validate(permission)
        guard !running else { throw RepositoryRootError.busy }
        running = true; defer { settleTurn() }
        let continuity = await lane.compare(url.path, beforeCompare: {})
        try validate(permission)
        return .init(continuity == .same && discoveryInvalidation == invalidation ? lookup : .unknown(nil), permission: permission)
#else
        return .init(.unsupported, permission: permission)
#endif
    }

#if canImport(Darwin)
    private func captureProviderURL(using permission: RepositoryRootPermission) async throws -> URL? {
        guard !running else { throw RepositoryRootError.busy }
        running = true; defer { settleTurn() }
        do { let url = try await lane.providerURL(); try validate(permission); return url }
        catch let failure as RootAccessFailure { try validate(permission); invalidate(); throw RepositoryRootError.unavailable(failure.code) }
    }
#endif

    public func validate(_ provider: RepositoryProviderObservation, using permission: RepositoryRootPermission) throws {
        try validate(permission); try validate(provider.permission)
    }

    public func list(_ directory: RepositoryProtocolDirectory, continuing cursor: RepositoryListingCursor? = nil,
                     budget: Int = 128, using permission: RepositoryRootPermission) async throws -> RepositoryListingPage {
        try Task.checkCancellation(); try validate(permission)
        guard budget > 0, budget <= 256 else { throw RepositoryRootError.unsafePath }
        if let cursor {
            try validate(cursor.permission)
            guard cursor.directory == directory else { throw RepositoryRootError.wrongContext }
        }
        guard !running else { throw RepositoryRootError.busy }
        running = true; defer { settleTurn() }
        do {
            let result = try await coordinatedTurn { try await lane.list(directory.relativePath, identifier: cursor?.identifier, budget: budget) }
            try validate(permission)
            return RepositoryListingPage(names: result.names, continuation: result.finished ? nil :
                RepositoryListingCursor(identifier: result.identifier, permission: permission, directory: directory))
        } catch let failure as RootAccessFailure {
            try validate(permission); invalidate(); throw RepositoryRootError.unavailable(failure.code)
        } catch { try validate(permission); throw error }
    }

    /// Abandons this live stream and any nested streams while preserving its parent.
    public func cancelListing(_ cursor: RepositoryListingCursor, using permission: RepositoryRootPermission) async throws {
        try validate(permission); try validate(cursor.permission)
        guard !running else { throw RepositoryRootError.busy }
        running = true; defer { settleTurn() }
        try await lane.cancelListing(cursor.identifier, relative: cursor.directory.relativePath)
        try validate(permission)
    }

    func listingResourceCount() async -> Int { await lane.listingResourceCount() }

    /// Reserves the owned source through a byte-preserving, individually coordinated copy.
    func copyRepository(to destination: String, requirements: [RepositoryByteRequirement] = [],
                        saved: CapturedRepositoryHistory? = nil,
                        captured: (@Sendable (String) async -> Void)? = nil,
                        beforeInstall: @escaping @Sendable (String) -> Void = { _ in }) async throws -> RepositoryCopyResult {
        try Task.checkCancellation()
        guard !destination.isEmpty, !destination.utf8.contains(0) else { throw RepositoryRootError.unsafePath }
        let permission = try permission()
        guard !running, !discoveryRunning else { throw RepositoryRootError.busy }
        running = true; defer { settleTurn() }
        do {
            let result = try await coordinatedTurn {
                try await lane.copyRepository(to: destination, requirements: requirements, saved: saved, captured: captured, beforeInstall: beforeInstall)
            }
            try validate(permission)
            return result
        } catch let failure as RootAccessFailure {
            try validate(permission); invalidate(); throw RepositoryRootError.unavailable(failure.code)
        } catch { try validate(permission); throw error }
    }

    /// Exports captured history through a fresh root and the ordinary complete-file installer.
    static func exportHistory(_ saved: CapturedRepositoryHistory, to destination: String,
                              issues: [RepositoryCopyIssue]) async throws -> RepositoryCopyResult {
        let owner = try await create(directory: URL(fileURLWithPath: destination))
        do {
            let result = try await owner.installSavedHistory(saved, destination: destination, issues: issues)
            await owner.close(); return result
        } catch { await owner.close(); throw error }
    }

    private func installSavedHistory(_ saved: CapturedRepositoryHistory, destination: String,
                                    issues: [RepositoryCopyIssue]) async throws -> RepositoryCopyResult {
        let permission = try permission()
        guard !running else { throw RepositoryRootError.busy }
        running = true; defer { settleTurn() }
        let result = try await coordinatedTurn { try await lane.exportHistory(saved, destination: destination, issues: issues) }
        try validate(permission)
        return result
    }

    /// Observes or refreshes a bounded group under the stream's current single-use cursor.
    func metadata(_ directory: RepositoryProtocolDirectory, continuing cursor: RepositoryListingCursor? = nil,
                  refreshing names: [RepositoryDiscoveredLeaf]? = nil, budget: Int = 16,
                  portable: Bool = false, using permission: RepositoryRootPermission) async throws -> RepositoryMetadataBatch {
        try Task.checkCancellation(); try validate(permission)
        guard budget > 0, budget <= 64 else { throw RepositoryRootError.unsafePath }
        if let cursor {
            try validate(cursor.permission)
            guard cursor.directory == directory else { throw RepositoryRootError.wrongContext }
        }
        if let names {
            guard cursor != nil, !names.isEmpty, names.count <= budget else { throw RepositoryRootError.wrongContext }
        }
        guard !running else { throw RepositoryRootError.busy }
        running = true; defer { settleTurn() }
        do {
            let result = try await coordinatedTurn {
                try await lane.metadata(directory.relativePath, identifier: cursor?.identifier,
                    names: names?.map(\.bytes), budget: budget, portable: portable)
            }
            try validate(permission)
            let entries = try result.entries.map { entry -> RepositoryMetadataEntry in
                let leaf = RepositoryDiscoveredLeaf(bytes: entry.name)
                guard let path = try? leaf.relativePath(in: directory) else { return .init(leaf: leaf, result: .invalidName) }
                let outcome: RepositoryMetadataResult = entry.error == 0 ?
                    .observed(try RepositoryEntryObservation(permission: permission, words: entry.words, relative: path)) :
                    .unavailable(RepositoryFileFailure(code: entry.error))
                return .init(leaf: leaf, result: outcome)
            }
            return RepositoryMetadataBatch(entries: entries, cursor: RepositoryListingCursor(identifier: result.identifier,
                permission: permission, directory: directory), finished: result.finished)
        } catch let failure as RootAccessFailure {
            try validate(permission); invalidate(); throw RepositoryRootError.unavailable(failure.code)
        } catch { try validate(permission); throw error }
    }

    func measureMetadata(_ enabled: Bool) async -> RepositoryMetadataWork? { await lane.measureMetadata(enabled) }

    /// Refreshes exact canonical names in one owned directory and releases its temporary stream in the same turn.
    func inspectExpectedNames(_ names: [String], in directory: RepositoryProtocolDirectory,
                              using permission: RepositoryRootPermission) async throws -> [RepositoryMetadataEntry] {
        try Task.checkCancellation(); try validate(permission)
        guard !names.isEmpty, names.count <= 64 else { throw StorageError.limit }
        guard names.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 255 && !$0.contains("/") && !$0.utf8.contains(0) }) else {
            throw RepositoryRootError.unsafePath
        }
        guard !running else { throw RepositoryRootError.busy }
        running = true; defer { settleTurn() }
        do {
            let result = try await coordinatedTurn {
                try await lane.performExpectedMetadata(directory.relativePath, names: names.map { Array($0.utf8) })
            }
            try validate(permission)
            guard result.entries.map({ String(decoding: $0.name, as: UTF8.self) }) == names else { throw RepositoryRootError.wrongContext }
            return try result.entries.map { entry in
                let leaf = RepositoryDiscoveredLeaf(bytes: entry.name), path = try leaf.relativePath(in: directory)
                let outcome: RepositoryMetadataResult = entry.error == 0 ?
                    .observed(try RepositoryEntryObservation(permission: permission, words: entry.words, relative: path)) :
                    .unavailable(.init(code: entry.error))
                return .init(leaf: leaf, result: outcome)
            }
        } catch let failure as RootAccessFailure {
            try validate(permission); invalidate(); throw RepositoryRootError.unavailable(failure.code)
        } catch { try validate(permission); throw error }
    }

    public func install(_ object: ImmutableRepositoryObject, for descriptor: BootstrapDescriptorV1,
                        using permission: RepositoryRootPermission) async throws -> RepositoryInstallationResult {
        try await install(object, for: descriptor, using: permission, beforeInstall: {}, afterInstall: {})
    }

    /// Holds the actual rooted effect and its delayed completion for lifecycle qualification.
    func install(_ object: ImmutableRepositoryObject, for descriptor: BootstrapDescriptorV1,
                 using permission: RepositoryRootPermission, beforeInstall: @escaping @Sendable () -> Void,
                 afterInstall: @escaping @Sendable () -> Void) async throws -> RepositoryInstallationResult {
        try Task.checkCancellation(); try validate(permission)
        guard object.collection == descriptor.collection, object.keyID == descriptor.keyID,
              object.descriptorGenesis == nil || object.descriptorGenesis == descriptor.genesis else { throw RepositoryRootError.wrongContext }
        guard !running else { throw RepositoryRootError.busy }
        running = true; defer { settleTurn() }
        let operation = UUID()
        let result = await coordinatedTurn {
            await lane.install(object, stage: ".nv-stage-" + operation.uuidString.lowercased(),
                beforeInstall: beforeInstall, afterInstall: afterInstall)
        }
        do { try validate(permission) }
        catch { return .uncertain(RepositoryInstallationFailure(reason: .staleContext, result: result, retry: object)) }
        if result.root_lost != 0 { invalidate() }
        switch result.outcome {
        case NV_ROOT_INSTALL_VERIFIED:
            return .verified(ImmutableInstallation(object: object, permission: permission, operation: operation, existing: result.existing != 0))
        case NV_ROOT_INSTALL_NO_EFFECT:
            return .notInstalled(RepositoryInstallationFailure(reason: RepositoryFileFailure(code: result.error), result: result, retry: object))
        default:
            return .uncertain(RepositoryInstallationFailure(reason: RepositoryFileFailure(code: result.error), result: result, retry: object))
        }
    }

    /// Checks installation evidence at its contextual consumer before later publication bookkeeping.
    public func validate(_ installation: ImmutableInstallation, for object: ImmutableRepositoryObject,
                         using permission: RepositoryRootPermission) throws {
        try validate(permission); try validate(installation.permission)
        guard installation.collection == object.collection, installation.keyID == object.keyID,
              installation.locator == object.locator else { throw RepositoryRootError.wrongContext }
    }

    /// Invalidates captured work immediately while preserving the retained directory owner.
    public func invalidate() {
        coordination.cancel()
        switch state {
        case .active, .fenced: advanceGeneration(); state = .fenced; signalTransport(.rootFenced)
        case .closing, .closed: break
        }
    }

    /// Positive equality restores access to the same retained directory after a move or interruption.
    public func revalidate(candidate: String) async throws -> RepositoryRootContinuity {
        try await revalidate(candidate: candidate, beforeCompare: {})
    }

    /// The hook holds the actual comparison turn for invalidation and shutdown challenges.
    func revalidate(candidate: String, beforeCompare: @escaping @Sendable () -> Void) async throws -> RepositoryRootContinuity {
        try Task.checkCancellation()
        guard !candidate.isEmpty, !candidate.utf8.contains(0) else { throw RepositoryRootError.unsafePath }
        switch state {
        case .closing, .closed: throw RepositoryRootError.closed
        case .active, .fenced: break
        }
        guard !running else { throw RepositoryRootError.busy }
        invalidate()
        let captured = generation
        running = true
        defer { settleTurn() }
        let continuity = await coordinatedTurn { await lane.compare(candidate, beforeCompare: beforeCompare) }
        guard generation == captured, case .fenced = state else { throw RepositoryRootError.stalePermission }
        if continuity == .same { state = .active; signalTransport(.rootAvailable) }
        return continuity
    }

    /// Fences admission and settles entered filesystem work while retaining physical ownership.
    public func quiesce() async {
        switch state {
        case .active, .fenced: invalidate(); await lane.settle()
        case .closing, .closed: await lane.settle()
        }
    }

    /// Stops admission before waiting for entered work and final descriptor release.
    public func close() async {
        if case .closed = state { return }
        if case .closing = state { await lane.close(); state = .closed; return }
        advanceGeneration(); state = .closing
        signalTransport(.closed)
        coordination.cancel()
        await lane.close()
        state = .closed
    }

    private func validate(_ permission: RepositoryRootPermission) throws {
        guard permission.session == session else { throw RepositoryRootError.wrongContext }
        guard permission.generation == generation else { throw RepositoryRootError.stalePermission }
        try requireActive()
    }
    /// Shares the owner fence with contextual repository consumers in this module.
    func checkPermission(_ permission: RepositoryRootPermission) throws { try validate(permission) }
    func discoveryHint(_ observation: RepositoryEntryObservation, using permission: RepositoryRootPermission) throws -> RepositoryObservationHint {
        try validate(permission); try validate(observation.permission)
        return RepositoryObservationHint(observation: observation)
    }
    private func requireActive() throws {
        switch state {
        case .active: return
        case .fenced: throw RepositoryRootError.fenced
        case .closing, .closed: throw RepositoryRootError.closed
        }
    }
    private func advanceGeneration() {
        precondition(generation < UInt64.max, "Root generation exhausted")
        generation += 1
    }
    private func coordinatedTurn<Value: Sendable>(_ operation: () async throws -> Value) async rethrows -> Value {
        coordination.startTurn()
        let cancellation = coordination
        return try await withTaskCancellationHandler(operation: operation, onCancel: { cancellation.cancel() })
    }
    private static func check(relative: String) throws {
        guard relative.utf8.count <= 6 * 256 else { throw RepositoryRootError.unsafePath }
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count <= 6, !relative.utf8.contains(0),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else {
            throw RepositoryRootError.unsafePath
        }
    }
}

/// Confines synchronous filesystem turns and the physical lease to a dedicated executor.
private actor RootLane {
    nonisolated private let executor = StorageExecutor(label: "org.notationalvelocity.storage.root", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { unsafe executor.asUnownedSerialExecutor() }
    private var root: RootLease?
    private var metadataWork: RepositoryMetadataWork?
    private var copying = false
    private var copyWaiters: [CheckedContinuation<Void, Never>] = []
    private let coordination: RootCoordinationControl

    init(coordination: RootCoordinationControl) { self.coordination = coordination }

    func open(directory: String, securityScope: URL?, create: Bool) throws {
        try Task.checkCancellation()
        root = try RootLease.acquire(directory: directory, securityScope: securityScope, executor: executor,
                                     coordination: coordination, create: create)
    }
    func createRepositoryNamespace() throws {
        guard let root else { throw RepositoryRootError.closed }
        try root.createRepositoryNamespace()
    }
    func beginRepairNamespace(_ words: [UInt64]) throws {
        guard let root else { throw RepositoryRootError.closed }
        try root.beginRepairNamespace(words)
    }
    func createRepairNamespace() throws {
        guard let root else { throw RepositoryRootError.closed }
        try root.createRepairNamespace()
    }
    func endRepairNamespace() { root?.endRepairNamespace() }
    func registerPresenter(_ event: @escaping @Sendable (RootPresentationEvent) -> Void) throws {
#if canImport(Darwin)
        guard let root else { throw RepositoryRootError.closed }
        try root.registerPresenter(event)
#endif
    }
    func observe(_ relative: String, beforeRead: @Sendable () -> Void, beforeCoordination: @Sendable () -> Void) throws -> [UInt64] {
        guard let root else { throw RepositoryRootError.closed }
        if metadataWork != nil { metadataWork!.singleObservations += 1 }
        return try root.observe(relative, beforeRead: beforeRead, beforeCoordination: beforeCoordination)
    }
    func read(_ relative: String, expected: [UInt64]) throws -> [UInt8] {
        guard let root else { throw RepositoryRootError.closed }
        if metadataWork != nil { metadataWork!.bodyReads += 1; metadataWork!.bodyBytes += Int(expected[3]) }
        return try root.read(relative, expected: expected)
    }
    func readProjection(_ relative: String, expected: [UInt64], maximum: Int, beforeRead: @Sendable () -> Void) throws -> ProjectionReadValues? {
        guard let root else { throw RepositoryRootError.closed }
        if metadataWork != nil { metadataWork!.bodyReads += 1; metadataWork!.bodyBytes += Int(expected[3]) }
        return try root.readProjection(relative, expected: expected, maximum: maximum, beforeRead: beforeRead)
    }
    func createProjection(_ input: PreparedProjectionCreation, staged: @Sendable (URL) -> Void,
                          beforeInstall: @Sendable () -> Void, afterInstall: @Sendable () -> Void) -> ProjectionCreationNative {
        guard let root else {
            var result = ProjectionCreationNative(); result.effect.error = EBADF; result.effect.root_lost = 1; return result
        }
        return root.createProjection(input, staged: staged, beforeInstall: beforeInstall, afterInstall: afterInstall)
    }
    func captureProjectionSource(_ source: ProjectionFileSnapshot) throws -> ProjectionSourceRead {
        guard let root else { throw RepositoryRootError.closed }
        return try root.captureProjectionSource(source)
    }
    func removeProjectionSource(_ reserved: ReservedProjectionSource, maximum: Int,
                                beforeRemoval: @Sendable () -> Void, afterRemoval: @Sendable () -> Void) -> ProjectionSourceRemovalNative {
        guard let root else {
            var result = ProjectionSourceRemovalNative(); result.result.error = EBADF; result.result.root_lost = 1; return result
        }
        return root.removeProjectionSource(reserved, maximum: maximum, beforeRemoval: beforeRemoval, afterRemoval: afterRemoval)
    }
    func inspectProjectionCleanup(_ record: ProjectionSourceAttemptV1, maximum: Int) throws -> ProjectionNativeObservation {
        guard let root else { throw RepositoryRootError.closed }
        return try root.inspectProjectionCleanup(record, maximum: maximum)
    }
    func replaceProjection(_ reserved: ReservedProjectionReplacement, source: ProjectionFileSnapshot, maximumDisplacedBytes: Int,
                           staged: @Sendable (URL) -> Void, beforeInstall: @Sendable () -> Void,
                           afterInstall: @Sendable () -> Void) -> ProjectionReplacementNative {
        guard let root else {
            var result = ProjectionReplacementNative()
            result.result.installation.error = EBADF; result.result.installation.root_lost = 1; return result
        }
        return root.replaceProjection(reserved, source: source, maximumDisplacedBytes: maximumDisplacedBytes,
            staged: staged, beforeInstall: beforeInstall, afterInstall: afterInstall)
    }
    func relocateProjection(_ reserved: ReservedProjectionRelocation, original: ProjectionSourceRead, maximumDisplacedBytes: Int,
                            staged: @Sendable (URL) -> Void, beforeInstall: @Sendable () -> Void,
                            afterInstall: @Sendable () -> Void) -> ProjectionRelocationNative {
        guard let root else {
            var result = ProjectionRelocationNative()
            result.result.replacement.installation.error = EBADF; result.result.replacement.installation.root_lost = 1; return result
        }
        return root.relocateProjection(reserved, original: original, maximumDisplacedBytes: maximumDisplacedBytes,
            staged: staged, beforeInstall: beforeInstall, afterInstall: afterInstall)
    }
    func availability(_ relative: String, expected: [UInt64]) throws -> AvailabilityValues {
        guard let root else { throw RepositoryRootError.closed }
        return try root.availability(relative, expected: expected)
    }
    func materialize(_ relative: String, expected: [UInt64]) throws -> RepositoryMaterializationRequest {
        guard let root else { throw RepositoryRootError.closed }
        return try root.materialize(relative, expected: expected)
    }
    func bookmark() throws -> PassivePlatformRecordV1 {
        guard let root else { throw RepositoryRootError.closed }
        return try root.bookmark()
    }
    func matches(_ bookmark: PassivePlatformRecordV1) throws -> RepositoryRootContinuity {
        guard let root else { throw RepositoryRootError.closed }
        return try root.matches(bookmark)
    }
#if canImport(Darwin)
    func providerURL() throws -> URL? {
        guard let root else { throw RepositoryRootError.closed }
        return try root.providerURL()
    }
#endif
    func list(_ relative: String, identifier: UUID?, budget: Int) throws -> ListingTurn {
        guard let root else { throw RepositoryRootError.closed }
        return try root.list(relative, identifier: identifier, budget: budget)
    }
    func metadata(_ relative: String, identifier: UUID?, names: [[UInt8]]?, budget: Int, portable: Bool) throws -> MetadataTurn {
        guard let root else { throw RepositoryRootError.closed }
        let result = try root.metadata(relative, identifier: identifier, names: names, budget: budget, portable: portable)
        if metadataWork != nil {
            metadataWork!.batches += 1; metadataWork!.bulkCalls += result.bulkCalls
            metadataWork!.statCalls += result.statCalls; metadataWork!.ancestorChecks += result.ancestorChecks
            metadataWork!.largestBatch = max(metadataWork!.largestBatch, result.entries.count)
            metadataWork!.largestNameBytes = max(metadataWork!.largestNameBytes, result.entries.reduce(0) { $0 + $1.name.count })
        }
        return result
    }
    func measureMetadata(_ enabled: Bool) -> RepositoryMetadataWork? {
        let previous = metadataWork
        metadataWork = enabled ? RepositoryMetadataWork() : nil
        return previous
    }
    func performExpectedMetadata(_ relative: String, names: [[UInt8]]) throws -> MetadataTurn {
        guard let root else { throw RepositoryRootError.closed }
        let result = try root.expectedMetadata(relative, names: names)
        if metadataWork != nil {
            metadataWork!.batches += 1; metadataWork!.bulkCalls += result.bulkCalls
            metadataWork!.statCalls += result.statCalls; metadataWork!.ancestorChecks += result.ancestorChecks
            metadataWork!.largestBatch = max(metadataWork!.largestBatch, result.entries.count)
            metadataWork!.largestNameBytes = max(metadataWork!.largestNameBytes, result.entries.reduce(0) { $0 + $1.name.count })
        }
        return result
    }
    func cancelListing(_ identifier: UUID, relative: String) throws {
        guard let root else { throw RepositoryRootError.closed }
        try root.cancelListing(identifier, relative: relative)
    }
    func listingResourceCount() -> Int { root?.listingResourceCount ?? 0 }
    func copyRepository(to destination: String, requirements: [RepositoryByteRequirement],
                        saved: CapturedRepositoryHistory?, captured: (@Sendable (String) async -> Void)?,
                        beforeInstall: @escaping @Sendable (String) -> Void) async throws -> RepositoryCopyResult {
        guard let root else { throw RepositoryRootError.closed }
        guard !copying else { throw RepositoryRootError.busy }
        copying = true
        defer {
            copying = false
            let waiting = copyWaiters; copyWaiters = []
            for waiter in waiting { waiter.resume() }
        }
        let from = try root.borrowForCopy()
        defer { from.close() }
        let access = RootCopyAccess(root: root, destination: destination, beforeInstall: beforeInstall)
        let destinationRoot = try access.writing("") {
            try RootLease(directory: destination, securityScope: nil, executor: executor,
                          coordination: coordination, create: true, copySource: root)
        }
        defer { destinationRoot.close() }
        let to = try destinationRoot.borrowForCopy()
        defer { to.close() }
        try access.bind(destinationRoot)
        return try await RepositoryCopyWorker.copyOwned(from: from, to: to, destination: destination,
            requirements: requirements, saved: saved, access: access, captured: captured, isolation: self)
    }
    func exportHistory(_ saved: CapturedRepositoryHistory, destination: String,
                       issues initialIssues: [RepositoryCopyIssue]) async throws -> RepositoryCopyResult {
        guard let root else { throw RepositoryRootError.closed }
        guard !copying else { throw RepositoryRootError.busy }
        copying = true
        defer {
            copying = false
            let waiting = copyWaiters; copyWaiters = []
            for waiter in waiting { waiter.resume() }
        }
        let access = RootCopyAccess(root: root, destination: destination)
        try access.bind(root)
        let result = try await RepositoryCopyWorker.exportOwned(saved, destination: destination, issues: initialIssues,
                                                                access: access, isolation: self)
        try access.writing("") { try root.checkCopyRoot() }
        return result
    }
    func install(_ object: ImmutableRepositoryObject, stage: String, beforeInstall: @Sendable () -> Void,
                 afterInstall: @Sendable () -> Void) -> NVRootInstallResult {
        guard let root else { return NVRootInstallResult(outcome: NV_ROOT_INSTALL_NO_EFFECT, error: EBADF, existing: 0, namespace_changed: 0, stage_retained: 0, cleanup_error: 0, root_lost: 1) }
        return root.install(object, stage: stage, beforeInstall: beforeInstall, afterInstall: afterInstall)
    }
    func compare(_ candidate: String, beforeCompare: @Sendable () -> Void) -> RepositoryRootContinuity {
        guard let root else { return .unavailable(EBADF) }
        beforeCompare()
        return root.compare(candidate)
    }
    func close() async {
        root?.close(); root = nil
        while copying { await withCheckedContinuation { copyWaiters.append($0) } }
    }
    /// Joins entered filesystem turns on the root's execution resource.
    func settle() { executor.checkIsolation() }
}

/// Distinguishes failed retained-root checks from errors observing an ordinary child.
private struct RootAccessFailure: Error { let code: Int32 }
private struct ListingTurn: Sendable { let identifier: UUID; let names: [[UInt8]]; let finished: Bool }
private struct MetadataTurn: Sendable {
    struct Entry: Sendable { let name: [UInt8]; let words: [UInt64]; let error: Int32 }
    let identifier: UUID
    let entries: [Entry]
    let finished: Bool
    let bulkCalls: Int, statCalls: Int, ancestorChecks: Int
}

private struct AvailabilityValues: Sendable {
    var residency: RepositoryResidency = .unknown
    var management: RepositoryProviderManagement = .unknown
    var download: RepositoryDownloadStatus = .unknown
    var downloading: Bool?, uploaded: Bool?, unresolvedVersions: Bool?
    var statusError: RepositoryStatusError?, downloadError: RepositoryStatusError?, uploadError: RepositoryStatusError?
}

private enum RootPresentationEvent: Sendable { case changed, moved, deleting, evicting }

/// Exposes the documented cross-thread cancellation capability while accessors retain their owner.
private final class RootCoordinationControl: Sendable {
#if canImport(Darwin)
    private struct State { var cancelled = false; var coordinator: NSFileCoordinator? }
    private let lock = NSLock()
    nonisolated(unsafe) private var state = State()
    private func withState<Value>(_ operation: (inout State) -> Value) -> Value {
        lock.lock(); defer { lock.unlock() }
        return unsafe operation(&state)
    }
    func startTurn() {
        withState { state in
            precondition(state.coordinator == nil, "An entered accessor retains its coordination turn")
            state.cancelled = false
        }
    }
    func begin(_ coordinator: NSFileCoordinator) -> Bool {
        withState { state in
            guard !state.cancelled, state.coordinator == nil else { return false }
            state.coordinator = coordinator; return true
        }
    }
    func finish(_ coordinator: NSFileCoordinator) {
        withState { state in
            precondition(state.coordinator === coordinator)
            state.coordinator = nil
        }
    }
    func cancel() {
        withState { state in
            state.cancelled = true
            // Foundation permits this call from any thread; actual access remains on the root executor.
            state.coordinator?.cancel()
        }
    }
    func checkCopyCancellation() throws {
        if withState({ $0.cancelled }) { throw RepositoryRootError.unavailable(ECANCELED) }
    }
#else
    private let lock = NSLock()
    nonisolated(unsafe) private var cancelled = false
    func startTurn() { lock.lock(); unsafe cancelled = false; lock.unlock() }
    func cancel() { lock.lock(); unsafe cancelled = true; lock.unlock() }
    func checkCopyCancellation() throws {
        lock.lock(); let stopped = unsafe cancelled; lock.unlock()
        if stopped { throw RepositoryRootError.unavailable(ECANCELED) }
    }
#endif
}

#if canImport(Darwin)
/// Balances an applicable sandbox extension after the final rooted effect and disposal.
private final class RootSecurityScope {
    private let url: URL
    private let executor: StorageExecutor
    private var active: Bool
    init(_ url: URL, executor: StorageExecutor) {
        self.url = url; self.executor = executor
        active = url.startAccessingSecurityScopedResource()
    }
    deinit { if active { let url = url; executor.finishOnOwner { url.stopAccessingSecurityScopedResource() } } }
    func stop() { if active { active = false; url.stopAccessingSecurityScopedResource() } }
}

/// Owns a reference-URL presenter whose replies use Foundation's independent queue.
@safe
private final class RootPresenter {
    private var raw: OpaquePointer?
    private let executor: StorageExecutor
    init(location: CFURL, executor: StorageExecutor, event: @escaping @Sendable (RootPresentationEvent) -> Void) {
        self.executor = executor
        unsafe raw = NVApplePresenterCreate(location) { value in
            switch value {
            case .changed: event(.changed)
            case .moved: event(.moved)
            case .deleting: event(.deleting)
            case .evicting: event(.evicting)
            @unknown default: event(.changed)
            }
        }
    }
    deinit {
        if let raw = unsafe raw { executor.finishOnOwner { unsafe NVApplePresenterClose(raw) } }
    }
    func register(at location: CFURL) {
        if let raw = unsafe raw { unsafe NVApplePresenterRegister(raw, location) }
    }
    var isRegistered: Bool {
        guard let raw = unsafe raw else { return false }
        return unsafe NVApplePresenterIsRegistered(raw)
    }
    func makeCoordinator() -> NSFileCoordinator { unsafe NVApplePresenterCoordinator(raw) }
    func stop() {
        if let raw = unsafe raw { unsafe NVApplePresenterClose(raw); unsafe self.raw = nil }
    }
}
#endif

/// Keeps a uniquely owned, open stage across its creation and final installation grants.
@safe
private struct RootPreparedStage: ~Copyable {
    private let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { unsafe self.pointer = pointer }
    deinit { unsafe nv_root_prepared_stage_close(pointer) }
    func install(owner: OpaquePointer, at relative: String, bytes: [UInt8]) -> NVRootInstallResult {
        var result = NVRootInstallResult()
        bytes.withUnsafeBufferPointer {
            unsafe nv_root_install_owned_stage(owner, relative, pointer, $0.baseAddress, UInt64($0.count), &result)
        }
        return result
    }
}

/// Keeps the mutable-file stage's descriptor and directory on the root executor.
@safe
private struct RootProjectionStage: ~Copyable {
    private let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { unsafe self.pointer = pointer }
    deinit { unsafe nv_projection_stage_close(pointer) }
    func install(owner: OpaquePointer, destination: String, input: PreparedProjectionCreation,
                 metadata: ProjectionOutputMetadata, effect: inout NVProjectionEffect) {
        unsafe metadata.install(owner: owner, stage: pointer, destination: destination, bytes: input.bytes, effect: &effect)
    }
    #if canImport(Darwin)
    func replace(coordinator: NSFileCoordinator, root: CFURL, stageURL: CFURL, owner: OpaquePointer,
                 reserved: ReservedProjectionReplacement, expected: [UInt64], metadata: ProjectionOutputMetadata,
                 result: inout NVProjectionReplacementResult) {
        unsafe metadata.replace(coordinator: coordinator, root: root, stageURL: stageURL, owner: owner,
            stage: pointer, reserved: reserved, expected: expected, result: &result)
    }
    func relocate(coordinator: NSFileCoordinator, root: CFURL, stageURL: CFURL, owner: OpaquePointer,
                  reserved: ReservedProjectionRelocation, original: ProjectionSourceRead, maximum: Int,
                  metadata: ProjectionOutputMetadata, result: inout NVProjectionRelocationResult) {
        original.lease.withDescriptor { descriptor in
            original.file.withNativeSource { expected in
                unsafe metadata.relocate(coordinator: coordinator, root: root, stageURL: stageURL, owner: owner,
                    stage: pointer, reserved: reserved, expected: &expected, descriptor: descriptor, maximum: maximum, result: &result)
            }
        }
    }
    #endif
}

/// Owns an empty stage until its checked descriptor transfers to the repair attempt.
@safe
private struct RootPreparedDirectory: ~Copyable {
    private let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { unsafe self.pointer = pointer }
    deinit { unsafe nv_root_prepared_directory_close(pointer) }
    func install(owner: OpaquePointer) -> NVRootInstallResult {
        var result = NVRootInstallResult()
        unsafe nv_root_install_repair_directory(owner, pointer, &result)
        return result
    }
}

/// Retains one directory-object lock through rooted observations and owner handoffs.
@safe
private final class RootLease {
    private var raw: OpaquePointer?
    private let executor: StorageExecutor
    private let coordination: RootCoordinationControl
    private var listings: [RootListingLease] = []
#if canImport(Darwin)
    private var reference: CFURL?
    private var presenter: RootPresenter?
    private var securityScope: RootSecurityScope?
#endif
    var listingResourceCount: Int { listings.count }
    /// Creates the selected directory within its synchronous writer grant before opening the owner.
    static func acquire(directory: String, securityScope: URL?, executor: StorageExecutor,
                        coordination: RootCoordinationControl, create: Bool) throws -> RootLease {
#if canImport(Darwin)
        if create {
            let coordinator = NSFileCoordinator(filePresenter: nil), requested = URL(fileURLWithPath: directory) as CFURL
            guard coordination.begin(coordinator) else { throw RepositoryRootError.unavailable(ECANCELED) }
            defer { coordination.finish(coordinator) }
            var error: NSError?, result: Result<RootLease, Error>?
            unsafe NVAppleCoordinateWrite(coordinator, requested, [], &error) { actual in
                result = Result {
                    guard NVAppleReferenceHasRoot(actual, requested, "" as CFString) else { throw RepositoryRootError.stalePermission }
                    return try RootLease(directory: directory, securityScope: securityScope, executor: executor,
                                         coordination: coordination, create: true)
                }
            }
            guard let result else { throw RepositoryRootError.unavailable(repositoryCoordinationCode(error)) }
            return try result.get()
        }
#endif
        return try RootLease(directory: directory, securityScope: securityScope, executor: executor,
                             coordination: coordination, create: create)
    }
    func checkCopyRoot() throws {
        try coordination.checkCopyCancellation()
        guard let raw = unsafe raw else { throw RepositoryRootError.closed }
        guard unsafe nv_root_validate(raw) == 0 else { throw RootAccessFailure(code: errno) }
    }
    func borrowForCopy() throws -> RepositoryLease {
        guard let raw = unsafe raw else { throw RepositoryRootError.closed }
        return try coordinatedRead("", metadataOnly: true) { _ in
            try unsafe RepositoryLease(root: raw, executor: executor)
        }
    }

    func copyRead<Value>(_ path: String, metadataOnly: Bool, _ action: () throws -> Value) throws -> Value {
        try coordination.checkCopyCancellation()
        return try coordinatedRead(path, metadataOnly: metadataOnly) { _ in
            guard let raw = unsafe raw else { throw RepositoryRootError.closed }
            guard unsafe nv_root_validate(raw) == 0 else { throw RootAccessFailure(code: errno) }
            let result = try action()
            guard unsafe nv_root_validate(raw) == 0 else { throw RootAccessFailure(code: errno) }
            return result
        }
    }

#if canImport(Darwin)
    func copyWrite<Value>(base: CFURL, path: String, readSource: Bool, _ action: () throws -> Value) throws -> Value {
        let source = try currentReference(), target = NVAppleAppendReference(base, path as CFString)
        return try withCoordinator { coordinator in
            var error: NSError?, result: Result<Value, Error>?
            func write(_ actual: CFURL) {
                result = Result {
                    guard NVAppleReferenceHasRoot(actual, base, path as CFString) else { throw RepositoryRootError.unavailable(ESTALE) }
                    let value = try action()
                    _ = try self.currentReference()
                    return value
                }
            }
            if readSource {
                unsafe NVAppleCoordinateCopy(coordinator, NVAppleAppendReference(source, path as CFString), target, &error) { actualSource, actualTarget in
                    do { _ = try self.checkedRelative(actualSource, expected: path); write(actualTarget) }
                    catch { result = .failure(error) }
                }
            } else { unsafe NVAppleCoordinateWrite(coordinator, target, [], &error) { actual in write(actual) } }
            if let result { return try result.get() }
            _ = try currentReference()
            throw RepositoryRootError.unavailable(repositoryCoordinationCode(error))
        }
    }
#else
    func copyWrite<Value>(path: String, readSource: Bool, _ action: () throws -> Value) throws -> Value {
        try copyRead(readSource ? path : "", metadataOnly: !readSource, action)
    }
#endif
    init(directory: String, securityScope: URL?, executor: StorageExecutor, coordination: RootCoordinationControl,
         create: Bool, copySource: RootLease? = nil) throws {
        self.executor = executor
        self.coordination = coordination
#if canImport(Darwin)
        self.securityScope = securityScope.map { RootSecurityScope($0, executor: executor) }
#endif
        if let copySource {
            try copySource.checkCopyRoot()
            guard create, let source = unsafe copySource.raw else { throw RepositoryRootError.wrongContext }
            unsafe raw = nv_root_create_copy_destination(source, directory)
        } else { unsafe raw = create ? nv_root_create(directory) : nv_root_open(directory) }
        guard let opened = unsafe raw else {
            let code = errno
            if code == EWOULDBLOCK { throw RepositoryRootError.contention }
            if code == ENOTSUP || code == ENOSYS { throw RepositoryRootError.unsupported(code) }
            throw RepositoryRootError.unavailable(code)
        }
#if canImport(Darwin)
        // The system-issued reference follows the held directory through moves and long paths.
        guard let created = unsafe NVAppleCreateRootReference(opened, directory) else {
            let code = errno
            close()
            throw RepositoryRootError.unavailable(code)
        }
        reference = created
#endif
    }
    deinit {
#if canImport(Darwin)
        if let presenter { executor.finishOnOwner { presenter.stop() } }
#endif
        // The executor retains release ordering for each owned native resource.
        // Each stream retires its own descriptor before the root owner is released.
        listings.removeAll()
        unsafe executor.retireRoot(raw)
#if canImport(Darwin)
        if let securityScope { executor.finishOnOwner { securityScope.stop() } }
#endif
    }
    func close() {
#if canImport(Darwin)
        presenter?.stop(); presenter = nil
#endif
        for listing in listings { listing.close() }
        listings.removeAll()
        if let raw = unsafe raw { unsafe nv_root_close(raw); unsafe self.raw = nil }
#if canImport(Darwin)
        securityScope?.stop(); securityScope = nil
#endif
    }
    func observe(_ relative: String, beforeRead: @Sendable () -> Void, beforeCoordination: @Sendable () -> Void) throws -> [UInt64] {
        try coordinatedRead(relative, metadataOnly: true, beforeRequest: beforeCoordination) { actual in
            beforeRead()
            return try observeNative(actual)
        }
    }
    private func observeNative(_ relative: String) throws -> [UInt64] {
        guard let raw = unsafe raw else { throw RepositoryRootError.closed }
        var words = [UInt64](repeating: 0, count: 9)
        let result = words.withUnsafeMutableBufferPointer { unsafe nv_root_snapshot(raw, relative, $0.baseAddress) }
        if result == -2 { throw RootAccessFailure(code: errno) }
        guard result == 0 else { throw RepositoryRootError.unavailable(errno) }
        return words
    }
    func read(_ relative: String, expected: [UInt64]) throws -> [UInt8] {
        try coordinatedRead(relative, metadataOnly: false) { actual in
            try readNative(actual, expected: expected)
        }
    }
    private func readNative(_ relative: String, expected: [UInt64]) throws -> [UInt8] {
        guard let raw = unsafe raw else { throw RepositoryRootError.closed }
        var bytes = [UInt8](repeating: 0, count: Int(expected[3]))
        let result = bytes.withUnsafeMutableBufferPointer { output in
            expected.withUnsafeBufferPointer { unsafe nv_root_read(raw, relative, $0.baseAddress, output.baseAddress, UInt64(output.count)) }
        }
        if result == -2 { throw RootAccessFailure(code: errno) }
        guard result == 0 else { throw RepositoryRootError.unavailable(errno) }
        return bytes
    }
    func readProjection(_ relative: String, expected: [UInt64], maximum: Int, beforeRead: @Sendable () -> Void) throws -> ProjectionReadValues? {
        // Check known eviction before requesting content access under its separate grant.
        let resident = try coordinatedRead(relative, metadataOnly: true) { actual in
            try residencyNative(actual, expected: expected)
        }
        if resident == .dataless { return nil }
        return try coordinatedRead(relative, metadataOnly: false) { actual in
            beforeRead()
            return try readProjectionNative(actual, expected: expected, maximum: maximum)
        }
    }

    private func readProjectionNative(_ relative: String, expected: [UInt64], maximum: Int) throws -> ProjectionReadValues? {
        guard let raw = unsafe raw else { throw RepositoryRootError.closed }
        var output: UnsafeMutablePointer<NVProjectionRead>?
        let result = expected.withUnsafeBufferPointer {
            unsafe nv_projection_read(raw, relative, $0.baseAddress, UInt64(maximum), &output)
        }
        if result == -2 { throw RootAccessFailure(code: errno) }
        if result == 1 { return nil }
        guard result == 0, let output = unsafe output else { throw RepositoryRootError.unavailable(errno) }
        defer { unsafe nv_projection_read_close(output) }
        return copyProjectionRead(output)
    }

    /// Captures a source under coordination and transfers its still-open descriptor with the values.
    func captureProjectionSource(_ source: ProjectionFileSnapshot) throws -> ProjectionSourceRead {
        let name = source.name.spelling.string, words = source.observation.identity
        let resident = try coordinatedRead(name, metadataOnly: true) { actual in try residencyNative(actual, expected: words) }
        guard resident != .dataless else { throw RepositoryRootError.unavailable(EAGAIN) }
        return try coordinatedRead(name, metadataOnly: false) { actual in
            guard let raw = unsafe raw else { throw RepositoryRootError.closed }
            var output: UnsafeMutablePointer<NVProjectionRead>?, descriptor: Int32 = -1
            let result = words.withUnsafeBufferPointer {
                unsafe nv_projection_read_retaining(raw, actual, $0.baseAddress, UInt64(source.bytes.count), &output, &descriptor)
            }
            let lease = descriptor >= 0 ? ProjectionSourceLease(owning: descriptor) : nil
            defer { unsafe nv_projection_read_close(output) }
            if result == -2 { throw RootAccessFailure(code: errno) }
            guard result == 0, let output = unsafe output, let lease else { throw RepositoryRootError.unavailable(result == 1 ? EAGAIN : errno) }
            let file = ProjectionFileSnapshot(name: source.name, value: copyProjectionRead(output), observation: source.observation)
            return ProjectionSourceRead(file: file, lease: lease)
        }
    }

    @safe
    private func copyProjectionRead(_ output: UnsafeMutablePointer<NVProjectionRead>) -> ProjectionReadValues {
        let read = unsafe output.pointee
        let bytes = unsafe Array(UnsafeBufferPointer(start: read.bytes, count: Int(read.count)))
        let created = unsafe read.has_birth == 0 ? nil : ProjectionFileTime(seconds: read.birth_seconds, nanoseconds: read.birth_nanoseconds)
        return unsafe ProjectionReadValues(bytes: bytes, encoding: projectionAttribute(read.encoding),
            tags: projectionAttribute(read.tags), finderTags: projectionAttribute(read.finder_tags),
            stamp: projectionAttribute(read.stamp), permissions: read.permissions, created: created)
    }

    func createProjection(_ input: PreparedProjectionCreation, staged: @Sendable (URL) -> Void,
                          beforeInstall: @Sendable () -> Void, afterInstall: @Sendable () -> Void) -> ProjectionCreationNative {
        var result = ProjectionCreationNative()
        do {
            try Task.checkCancellation()
            let metadata = try ProjectionOutputMetadata(input)
            result.omittedStamp = metadata.stamp == nil
            #if canImport(Darwin)
            let base = try currentReference()
            let directory = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                appropriateFor: base as URL, create: true)
            result.stage = directory
            let descriptor = unsafe directory.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path = unsafe path else { return -1 }
                return unsafe open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else { throw RepositoryRootError.unavailable(errno) }
            defer { _ = Darwin.close(descriptor) }
            guard let raw = unsafe raw else { throw RepositoryRootError.closed }
            guard let created = metadata.prepare(owner: raw, directory: descriptor, leaf: "prepared",
                bytes: input.bytes, effect: &result.effect) else { return result }
            let stage = unsafe RootProjectionStage(created)
            guard result.effect.outcome == NV_PROJECTION_STAGED else { return result }
            staged(directory)
            try Task.checkCancellation()
            try coordinatedWrite(input.output.binding.descriptor.filename.spelling.string) { destination in
                try Task.checkCancellation()
                beforeInstall()
                unsafe stage.install(owner: raw, destination: destination, input: input, metadata: metadata, effect: &result.effect)
                afterInstall()
                guard result.effect.outcome == NV_PROJECTION_INSTALLED else { return }
                result.words = withUnsafeBytes(of: result.effect.installed_words) { unsafe Array($0.bindMemory(to: UInt64.self)) }
                guard let value = try readProjectionNative(destination, expected: result.words, maximum: input.bytes.count),
                      value.bytes == input.bytes, projectionMetadataMatches(value, metadata: metadata, effect: result.effect) else {
                    throw RepositoryRootError.unavailable(ESTALE)
                }
                result.value = value
            }
            #else
            throw RepositoryRootError.unsupported(ENOTSUP)
            #endif
        } catch {
            if result.effect.outcome == NV_PROJECTION_INSTALLED { result.effect.outcome = Int32(NV_PROJECTION_UNCERTAIN) }
            switch error {
            case let failure as RootAccessFailure: result.effect.error = failure.code; result.effect.root_lost = 1
            case RepositoryRootError.unavailable(let code), RepositoryRootError.unsupported(let code): result.effect.error = code
            case is CancellationError: result.effect.error = ECANCELED
            case RepositoryRootError.closed: result.effect.error = EBADF; result.effect.root_lost = 1
            #if canImport(Darwin)
            default: result.effect.error = repositoryCoordinationCode(error as NSError)
            #else
            default: result.effect.error = EIO
            #endif
            }
        }
        return result
    }

    func replaceProjection(_ reserved: ReservedProjectionReplacement, source: ProjectionFileSnapshot,
                           maximumDisplacedBytes: Int, staged: @Sendable (URL) -> Void,
                           beforeInstall: @Sendable () -> Void, afterInstall: @Sendable () -> Void) -> ProjectionReplacementNative {
        var result = ProjectionReplacementNative()
        let input = reserved.input
        do {
            try Task.checkCancellation()
            let metadata = try ProjectionOutputMetadata(input, permissions: source.permissions)
            result.omittedStamp = metadata.stamp == nil
            #if canImport(Darwin)
            let name = input.output.binding.descriptor.filename.spelling.string
            let base = try currentReference()
            let directory = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                appropriateFor: base as URL, create: true)
            result.stage = directory
            let descriptor = unsafe directory.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path = unsafe path else { return -1 }
                return unsafe open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else { throw RepositoryRootError.unavailable(errno) }
            defer { _ = Darwin.close(descriptor) }
            guard let raw = unsafe raw else { throw RepositoryRootError.closed }
            let created = try unsafe coordinatedRead(name, metadataOnly: false) { _ in
                metadata.prepareReplacement(owner: raw, directory: descriptor, expected: source.observation.identity,
                    input: input, effect: &result.result.installation)
            }
            guard let created = unsafe created else { return result }
            let stage = unsafe RootProjectionStage(created)
            guard result.result.installation.outcome == NV_PROJECTION_STAGED else { return result }
            staged(directory)
            try Task.checkCancellation()
            beforeInstall()
            try withCoordinator { coordinator in
                try Task.checkCancellation()
                unsafe stage.replace(coordinator: coordinator, root: try currentReference(),
                    stageURL: directory.appendingPathComponent("prepared") as CFURL, owner: raw, reserved: reserved,
                    expected: source.observation.identity, metadata: metadata, result: &result.result)
            }
            afterInstall()
            guard result.result.installation.outcome == NV_PROJECTION_INSTALLED else { return result }
            result.installedWords = withUnsafeBytes(of: result.result.installation.installed_words) { unsafe Array($0.bindMemory(to: UInt64.self)) }
            result.displacedWords = withUnsafeBytes(of: result.result.backup_words) { unsafe Array($0.bindMemory(to: UInt64.self)) }
            guard result.result.backup_comparison != NV_PROJECTION_BACKUP_UNCHECKED,
                  result.result.backup_error == 0,
                  let installed = try readProjection(name, expected: result.installedWords, maximum: input.bytes.count, beforeRead: {}),
                  installed.bytes == input.bytes, projectionMetadataMatches(installed, metadata: metadata, effect: result.result.installation),
                  let displaced = try readProjection(reserved.record.backupName, expected: result.displacedWords,
                      maximum: maximumDisplacedBytes, beforeRead: {}) else { throw RepositoryRootError.unavailable(ESTALE) }
            result.installed = installed; result.displaced = displaced
            #else
            throw RepositoryRootError.unsupported(ENOTSUP)
            #endif
        } catch {
            if result.result.installation.outcome == NV_PROJECTION_INSTALLED { result.result.installation.outcome = Int32(NV_PROJECTION_UNCERTAIN) }
            switch error {
            case let failure as RootAccessFailure: result.result.installation.error = failure.code; result.result.installation.root_lost = 1
            case RepositoryRootError.unavailable(let code), RepositoryRootError.unsupported(let code): result.result.installation.error = code
            case is CancellationError: result.result.installation.error = ECANCELED
            case RepositoryRootError.closed: result.result.installation.error = EBADF; result.result.installation.root_lost = 1
            #if canImport(Darwin)
            default: result.result.installation.error = repositoryCoordinationCode(error as NSError)
            #else
            default: result.result.installation.error = EIO
            #endif
            }
        }
        return result
    }

    func relocateProjection(_ reserved: ReservedProjectionRelocation, original: ProjectionSourceRead,
                            maximumDisplacedBytes: Int, staged: @Sendable (URL) -> Void,
                            beforeInstall: @Sendable () -> Void, afterInstall: @Sendable () -> Void) -> ProjectionRelocationNative {
        var result = ProjectionRelocationNative()
        let input = reserved.input, source = original.file
        do {
            try Task.checkCancellation()
            let metadata = try ProjectionOutputMetadata(input, permissions: source.permissions)
            result.omittedStamp = metadata.stamp == nil
            #if canImport(Darwin)
            let name = input.output.binding.descriptor.filename.spelling.string
            let oldName = input.source.output.binding.descriptor.filename.spelling.string
            let directory = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                appropriateFor: currentReference() as URL, create: true)
            result.stage = directory
            let descriptor = unsafe directory.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path = unsafe path else { return -1 }
                return unsafe open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else { throw RepositoryRootError.unavailable(errno) }
            defer { _ = Darwin.close(descriptor) }
            guard let raw = unsafe raw else { throw RepositoryRootError.closed }
            let created = try unsafe coordinatedRead(oldName, metadataOnly: false) { _ in
                metadata.prepareRelocation(owner: raw, directory: descriptor, expected: source.observation.identity,
                    input: input, effect: &result.result.replacement.installation)
            }
            guard let created = unsafe created else { return result }
            let stage = unsafe RootProjectionStage(created)
            guard result.result.replacement.installation.outcome == NV_PROJECTION_STAGED else { return result }
            staged(directory)
            try Task.checkCancellation()
            beforeInstall()
            try withCoordinator { coordinator in
                try Task.checkCancellation()
                unsafe stage.relocate(coordinator: coordinator, root: try currentReference(),
                    stageURL: directory.appendingPathComponent("prepared") as CFURL, owner: raw, reserved: reserved,
                    original: original, maximum: maximumDisplacedBytes, metadata: metadata, result: &result.result)
            }
            afterInstall()
            let effect = result.result.replacement.installation
            guard effect.outcome == NV_PROJECTION_INSTALLED else { return result }
            result.installedWords = withUnsafeBytes(of: effect.installed_words) { unsafe Array($0.bindMemory(to: UInt64.self)) }
            result.displacedWords = withUnsafeBytes(of: result.result.replacement.backup_words) { unsafe Array($0.bindMemory(to: UInt64.self)) }
            guard result.result.replacement.backup_comparison != NV_PROJECTION_BACKUP_UNCHECKED,
                  result.result.replacement.backup_error == 0,
                  let installed = try readProjection(name, expected: result.installedWords, maximum: input.bytes.count, beforeRead: {}),
                  installed.bytes == input.bytes, projectionMetadataMatches(installed, metadata: metadata, effect: effect),
                  let displaced = try readProjection(reserved.record.backupName, expected: result.displacedWords,
                      maximum: maximumDisplacedBytes, beforeRead: {}) else { throw RepositoryRootError.unavailable(ESTALE) }
            result.installed = installed; result.displaced = displaced
            #else
            throw RepositoryRootError.unsupported(ENOTSUP)
            #endif
        } catch {
            if result.result.replacement.installation.outcome == NV_PROJECTION_INSTALLED {
                result.result.replacement.installation.outcome = Int32(NV_PROJECTION_UNCERTAIN)
            }
            switch error {
            case let failure as RootAccessFailure: result.result.replacement.installation.error = failure.code; result.result.replacement.installation.root_lost = 1
            case RepositoryRootError.unavailable(let code), RepositoryRootError.unsupported(let code): result.result.replacement.installation.error = code
            case is CancellationError: result.result.replacement.installation.error = ECANCELED
            case RepositoryRootError.closed: result.result.replacement.installation.error = EBADF; result.result.replacement.installation.root_lost = 1
            #if canImport(Darwin)
            default: result.result.replacement.installation.error = repositoryCoordinationCode(error as NSError)
            #else
            default: result.result.replacement.installation.error = EIO
            #endif
            }
        }
        return result
    }

    /// Checks fresh raw metadata against the native verifier's exact filesystem representation.
    private func projectionMetadataMatches(_ value: ProjectionReadValues, metadata: ProjectionOutputMetadata, effect: NVProjectionEffect) -> Bool {
        let birth: ProjectionFileTime? = effect.installed_has_birth == 0 ? nil :
            .init(seconds: effect.installed_birth_seconds, nanoseconds: effect.installed_birth_nanoseconds)
        return value.encoding == .present(metadata.encoding) && value.tags == .present(metadata.tags) &&
            value.permissions == metadata.permissions && value.created == birth &&
            (effect.stamp_error != 0 || value.stamp == (metadata.stamp.map { .present($0) } ?? .absent)) &&
            (effect.finder_tags_error != 0 || value.finderTags == .present(metadata.tags))
    }

    func removeProjectionSource(_ reserved: ReservedProjectionSource, maximum: Int,
                                beforeRemoval: @Sendable () -> Void, afterRemoval: @Sendable () -> Void) -> ProjectionSourceRemovalNative {
        var result = ProjectionSourceRemovalNative()
        do {
            try Task.checkCancellation()
            guard let raw = unsafe raw else { throw RepositoryRootError.closed }
            let record = reserved.record, source = reserved.authorization.original.source
            let name = source.name.spelling.string
            beforeRemoval()
            #if canImport(Darwin)
            try withCoordinator { coordinator in
                let base = try currentReference()
                reserved.authorization.original.withDescriptor { descriptor in
                    source.withNativeSource { expected in
                        unsafe NVAppleRemoveProjectionSource(coordinator, base, raw, name, record.recoveryName, &expected, UInt64(maximum), descriptor, &result.result)
                    }
                }
            }
            #else
            reserved.authorization.original.withDescriptor { descriptor in
                source.withNativeSource { expected in
                    unsafe nv_projection_remove_source(raw, name, record.recoveryName, &expected, UInt64(maximum), descriptor, &result.result)
                }
            }
            #endif
            afterRemoval()
            result.source = try sourceObservation(name, maximum: maximum)
            result.cleanup = try inspectProjectionCleanup(record, maximum: maximum)
        } catch {
            if result.result.outcome != NV_PROJECTION_CLEANUP_NO_EFFECT { result.result.outcome = Int32(NV_PROJECTION_CLEANUP_UNCERTAIN) }
            switch error {
            case let failure as RootAccessFailure: result.result.error = failure.code; result.result.root_lost = 1
            case RepositoryRootError.unavailable(let code), RepositoryRootError.unsupported(let code): result.result.error = code
            case is CancellationError: result.result.error = ECANCELED
            case RepositoryRootError.closed: result.result.error = EBADF; result.result.root_lost = 1
            #if canImport(Darwin)
            default: result.result.error = repositoryCoordinationCode(error as NSError)
            #else
            default: result.result.error = EIO
            #endif
            }
        }
        return result
    }

    func inspectProjectionCleanup(_ record: ProjectionSourceAttemptV1, maximum: Int) throws -> ProjectionNativeObservation {
        let path = record.cleanupDirectoryName + "/item"
        do {
            let words = try observeNative(path)
            guard words[0] == 1 else { return .unavailable(.kindCollision) }
            guard words[4] == 1 else { return .unavailable(.hardLinked) }
            let resident = try coordinatedRead(path, metadataOnly: true) { actual in try residencyNative(actual, expected: words) }
            if resident == .dataless { return .placeholder }
            return try coordinatedRead(path, metadataOnly: false) { _ in
                guard let raw = unsafe raw else { throw RepositoryRootError.closed }
                var output: UnsafeMutablePointer<NVProjectionRead>?
                let status = unsafe nv_projection_read_cleanup(raw, record.recoveryName, UInt64(maximum), &output)
                defer { unsafe nv_projection_read_close(output) }
                if status == -2 { throw RootAccessFailure(code: errno) }
                if status == 1 { return .placeholder }
                guard status == 0, let output = unsafe output else { throw RepositoryRootError.unavailable(errno) }
                let record = unsafe output.pointee
                let w = unsafe record.words
                return .value(copyProjectionRead(output), [w.0,w.1,w.2,w.3,w.4,w.5,w.6,w.7,w.8])
            }
        } catch RepositoryRootError.unavailable(let code) { return .unavailable(.init(code: code)) }
    }

    private func sourceObservation(_ name: String, maximum: Int) throws -> ProjectionNativeObservation {
        do {
            let words = try observeNative(name)
            if let value = try readProjection(name, expected: words, maximum: maximum, beforeRead: {}) { return .value(value, words) }
            return .placeholder
        } catch RepositoryRootError.unavailable(let code) { return .unavailable(.init(code: code)) }
    }

    private func projectionAttribute(_ attribute: NVProjectionAttribute) -> ProjectionFileAttribute {
        switch unsafe attribute.state {
        case 1: return unsafe .present(Array(UnsafeBufferPointer(start: attribute.bytes, count: Int(attribute.count))))
        case 2: return .unsupported
        default: return .absent
        }
    }

    private func residencyNative(_ relative: String, expected: [UInt64]) throws -> RepositoryResidency {
        guard let raw = unsafe raw else { throw RepositoryRootError.closed }
        var dataless: Int32 = -1
        let result = expected.withUnsafeBufferPointer { unsafe nv_root_residency(raw, relative, $0.baseAddress, &dataless) }
        if result == -2 { throw RootAccessFailure(code: errno) }
        guard result == 0 else { throw RepositoryRootError.unavailable(errno) }
        switch dataless { case 0: return .materialized; case 1: return .dataless; default: return .unknown }
    }
    func availability(_ relative: String, expected: [UInt64]) throws -> AvailabilityValues {
#if canImport(Darwin)
        return try coordinatedURLRead(relative, metadataOnly: true) { actual, url in
            try availabilityNative(actual, expected: expected, url: url)
        }
#else
        return AvailabilityValues(residency: try residencyNative(relative, expected: expected))
#endif
    }
    func materialize(_ relative: String, expected: [UInt64]) throws -> RepositoryMaterializationRequest {
#if canImport(Darwin)
        let selected = try coordinatedURLRead(relative, metadataOnly: true) { actual, url in
            (try availabilityNative(actual, expected: expected, url: url), url)
        }
        guard selected.0.management == .ubiquitous else { return .unsupported }
        _ = try checkedRelative(selected.1, expected: relative)
        _ = try residencyNative(relative, expected: expected)
        var error: NSError?
        if unsafe NVAppleRequestMaterialization(selected.1, &error) { return .requested }
        return .failed(.init(error ?? NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))))
#else
        _ = try residencyNative(relative, expected: expected)
        return .unsupported
#endif
    }
#if canImport(Darwin)
    func providerURL() throws -> URL? {
        let reference = try currentReference()
        guard let resolved = unsafe CFURLCreateFilePathURL(kCFAllocatorDefault, reference, nil) else { return nil }
        let candidate = unsafe resolved.takeRetainedValue() as URL
        guard candidate.isFileURL, let raw = unsafe raw else { return nil }
        return unsafe nv_root_compare(raw, candidate.path) == 1 ? candidate : nil
    }

    private func availabilityNative(_ relative: String, expected: [UInt64], url: CFURL) throws -> AvailabilityValues {
        var result = AvailabilityValues(residency: try residencyNative(relative, expected: expected))
        var values = NVAppleAvailability()
        unsafe NVAppleReadAvailability(url, &values)
        result.statusError = .init(domain: values.status_domain, code: values.status_code)
        if values.ubiquitous == 1 {
            result.management = .ubiquitous
            switch values.download {
            case 1: result.download = .notDownloaded
            case 2: result.download = .downloaded
            case 3: result.download = .current
            default: result.download = .unknown
            }
            result.downloading = values.downloading < 0 ? nil : values.downloading == 1
            result.uploaded = values.uploaded < 0 ? nil : values.uploaded == 1
            result.unresolvedVersions = values.unresolved < 0 ? nil : values.unresolved == 1
            result.downloadError = .init(domain: values.download_domain, code: values.download_code)
            result.uploadError = .init(domain: values.upload_domain, code: values.upload_code)
        }
        result.residency = try residencyNative(relative, expected: expected)
        return result
    }
#endif
    func list(_ relative: String, identifier: UUID?, budget: Int) throws -> ListingTurn {
        try coordinatedRead(relative, metadataOnly: true) { actual in
            try listNative(actual, identifier: identifier, budget: budget)
        }
    }
    private func listNative(_ relative: String, identifier: UUID?, budget: Int) throws -> ListingTurn {
        guard let raw = unsafe raw else { throw RepositoryRootError.closed }
        let stream = try listing(relative, identifier: identifier, metadata: false, portable: false)
        guard let listing = unsafe stream.raw else { throw RepositoryRootError.wrongContext }
        var bytes = [UInt8](repeating: 0, count: budget * 257), used: UInt32 = 0, finished: Int32 = 0
        let result = bytes.withUnsafeMutableBufferPointer {
            unsafe nv_root_list_next(raw, listing, UInt32(budget), $0.baseAddress, UInt32($0.count), &used, &finished)
        }
        let code = errno
        if result != 0 || finished != 0 { listings.removeLast(); stream.close() }
        if result == -2 { throw RootAccessFailure(code: code) }
        guard result == 0 else { throw RepositoryRootError.unavailable(code) }
        guard Int(used) <= bytes.count else {
            if listings.last === stream { listings.removeLast() }; stream.close()
            throw RepositoryRootError.wrongContext
        }
        var names: [[UInt8]] = [], offset = 0
        while offset < Int(used) {
            let count = Int(bytes[offset]); offset += 1
            guard count > 0, offset + count <= Int(used) else { throw RepositoryRootError.wrongContext }
            names.append(Array(bytes[offset ..< offset + count])); offset += count
        }
        let continuation = UUID()
        if finished == 0 { stream.identifier = continuation }
        return ListingTurn(identifier: continuation, names: names, finished: finished != 0)
    }
    private func listing(_ relative: String, identifier: UUID?, metadata: Bool, portable: Bool) throws -> RootListingLease {
        guard let raw = unsafe raw else { throw RepositoryRootError.closed }
        if let identifier {
            guard let index = listings.firstIndex(where: { $0.identifier == identifier && $0.relative == relative && $0.metadata == metadata }) else { throw RepositoryRootError.wrongContext }
            listings.removeSubrange((index + 1)..<listings.count)
            return listings[index]
        } else {
            while let last = listings.last, !relative.hasPrefix(last.relative + "/") { listings.removeLast() }
            guard listings.count < 5 else { throw RepositoryRootError.wrongContext }
            let opened = unsafe metadata ? nv_root_metadata_open(raw, relative, portable ? 1 : 0) : nv_root_list_open(raw, relative)
            guard let opened = unsafe opened else {
                let code = errno
                if unsafe nv_root_validate(raw) != 0 { throw RootAccessFailure(code: errno) }
                throw RepositoryRootError.unavailable(code)
            }
            let stream = unsafe RootListingLease(raw: opened, relative: relative, metadata: metadata, executor: executor)
            listings.append(stream)
            return stream
        }
    }
    func metadata(_ relative: String, identifier: UUID?, names: [[UInt8]]?, budget: Int, portable: Bool) throws -> MetadataTurn {
        try coordinatedRead(relative, metadataOnly: true) { actual in
            try metadataNative(actual, identifier: identifier, names: names, budget: budget, portable: portable)
        }
    }
    func expectedMetadata(_ relative: String, names: [[UInt8]]) throws -> MetadataTurn {
        guard listings.isEmpty else { throw RepositoryRootError.busy }
        defer { listings.removeAll() }
        return try metadata(relative, identifier: nil, names: names, budget: names.count, portable: false)
    }
    private func metadataNative(_ relative: String, identifier: UUID?, names: [[UInt8]]?, budget: Int, portable: Bool) throws -> MetadataTurn {
        guard let raw = unsafe raw else { throw RepositoryRootError.closed }
        let stream = try listing(relative, identifier: identifier, metadata: true, portable: portable)
        guard let listing = unsafe stream.raw else { throw RepositoryRootError.wrongContext }
        var entries = [NVRootMetadataEntry](repeating: NVRootMetadataEntry(), count: 64), turn = NVRootMetadataTurn()
        if let names {
            guard !names.isEmpty, names.count <= budget else { throw RepositoryRootError.wrongContext }
            for (index, name) in names.enumerated() {
                guard !name.isEmpty, name.count <= 255, !name.contains(0), !name.contains(47) else { throw RepositoryRootError.unsafePath }
                entries[index].length = UInt32(name.count)
                withUnsafeMutableBytes(of: &entries[index].name) { output in
                    for i in name.indices { unsafe output[i] = name[i] }
                }
            }
        }
        let result = entries.withUnsafeMutableBufferPointer {
            if let names { return unsafe nv_root_metadata_refresh(raw, listing, $0.baseAddress, UInt32(names.count), &turn) }
            return unsafe nv_root_metadata_next(raw, listing, UInt32(budget), $0.baseAddress, &turn)
        }
        let code = errno
        if result != 0 { listings.removeLast(); stream.close() }
        if result == -2 { throw RootAccessFailure(code: code) }
        guard result == 0 else { throw RepositoryRootError.unavailable(code) }
        guard turn.count <= 64 else { throw RepositoryRootError.wrongContext }
        let copied = try entries.prefix(Int(turn.count)).map { entry -> MetadataTurn.Entry in
            guard entry.length > 0, entry.length <= 255 else { throw RepositoryRootError.wrongContext }
            let name = withUnsafeBytes(of: entry.name) { unsafe Array($0.prefix(Int(entry.length))) }
            let words = [entry.words.0, entry.words.1, entry.words.2, entry.words.3, entry.words.4,
                         entry.words.5, entry.words.6, entry.words.7, entry.words.8]
            return .init(name: name, words: words, error: entry.error)
        }
        stream.identifier = UUID()
        return MetadataTurn(identifier: stream.identifier, entries: copied, finished: turn.finished != 0,
            bulkCalls: Int(turn.bulk_calls), statCalls: Int(turn.stat_calls), ancestorChecks: Int(turn.ancestor_checks))
    }
    func cancelListing(_ identifier: UUID, relative: String) throws {
        guard let index = listings.firstIndex(where: { $0.identifier == identifier && $0.relative == relative }) else { throw RepositoryRootError.wrongContext }
        listings.removeSubrange(index..<listings.count)
    }
#if canImport(Darwin)
    /// Registers the directory presenter inside a granted metadata interval.
    func registerPresenter(_ event: @escaping @Sendable (RootPresentationEvent) -> Void) throws {
        let registered = try coordinatedRead("", metadataOnly: true) { _ in
            let location = try currentReference()
            let value = RootPresenter(location: location, executor: executor, event: event)
            value.register(at: location)
            return value
        }
        presenter = registered
    }
#endif

    func install(_ object: ImmutableRepositoryObject, stage: String, beforeInstall: @Sendable () -> Void,
                 afterInstall: @Sendable () -> Void) -> NVRootInstallResult {
        installExact(bytes: object.bytes, at: object.locator.relativePath, stage: stage,
                     beforeInstall: beforeInstall, afterInstall: afterInstall)
    }

    /// Installs frozen copy bytes with the same owned stage, readbacks and barriers as publication.
    func installExact(bytes: [UInt8], at path: String, stage: String, beforeInstall: @Sendable () -> Void,
                      afterInstall: @Sendable () -> Void) -> NVRootInstallResult {
        guard let raw = unsafe raw else { return NVRootInstallResult(outcome: NV_ROOT_INSTALL_NO_EFFECT, error: EBADF, existing: 0, namespace_changed: 0, stage_retained: 0, cleanup_error: 0, root_lost: 1) }
        var changed = false, retainedStage = false
        do {
            let components = path.split(separator: "/")
            let directories = (1..<components.count).map { components.prefix($0).joined(separator: "/") }
            // Metadata identifies preparation work; every creation rechecks its exact parent.
            let missing = try coordinatedRead("", metadataOnly: true) { _ -> [String] in
                for (index, directory) in directories.enumerated() {
                    do {
                        guard try observeNative(directory)[0] == RepositoryEntryObservation.Kind.directory.rawValue else {
                            throw RepositoryRootError.unavailable(ENOTDIR)
                        }
                    } catch RepositoryRootError.unavailable(let code) where code == ENOENT {
                        return Array(directories[index...])
                    }
                }
                return []
            }
            for directory in missing {
                let prepared = try coordinatedWrite(directory) { actual in
                    var result = NVRootInstallResult()
                    unsafe nv_root_make_directory(raw, actual, &result)
                    return result
                }
                changed = changed || prepared.namespace_changed != 0
                guard prepared.outcome == NV_ROOT_INSTALL_VERIFIED else { return combining(prepared, changed: changed) }
            }
            var created: OpaquePointer?
            let prepared = try coordinatedWrite(stage) { actual in
                var result = NVRootInstallResult()
                bytes.withUnsafeBufferPointer { bytes in
                    unsafe created = nv_root_prepare_owned_stage(raw, actual, bytes.baseAddress, UInt64(bytes.count), &result)
                }
                return result
            }
            retainedStage = prepared.stage_retained != 0
            guard prepared.outcome == NV_ROOT_INSTALL_VERIFIED else { return combining(prepared, changed: changed) }
            guard let created = unsafe created else { throw RepositoryRootError.unavailable(EIO) }
            let heldStage = unsafe RootPreparedStage(created)
            let result = try coordinatedInstallation(stage, at: path) { _, destination in
                beforeInstall()
                let result = unsafe heldStage.install(owner: raw, at: destination, bytes: bytes)
                afterInstall()
                return result
            }
            return combining(result, changed: changed)
        } catch {
            let code: Int32, lost: Int32
            switch error {
            case let failure as RootAccessFailure: code = failure.code; lost = 1
            case RepositoryRootError.unavailable(let failure): code = failure; lost = 0
            default: code = EIO; lost = 0
            }
            return NVRootInstallResult(outcome: changed || retainedStage || lost != 0 ? NV_ROOT_INSTALL_UNCERTAIN : NV_ROOT_INSTALL_NO_EFFECT,
                error: code, existing: 0, namespace_changed: changed ? 1 : 0,
                stage_retained: retainedStage ? 1 : 0, cleanup_error: 0, root_lost: lost)
        }
    }
    func compare(_ candidate: String) -> RepositoryRootContinuity {
        guard let raw = unsafe raw else { return .unavailable(EBADF) }
        switch unsafe nv_root_compare(raw, candidate) {
        case 1:
#if canImport(Darwin)
            if let presenter, !presenter.isRegistered {
                do {
                    try coordinatedRead("", metadataOnly: true) { _ in presenter.register(at: try currentReference()) }
                } catch let failure as RootAccessFailure { return .unavailable(failure.code) }
                catch RepositoryRootError.unavailable(let code) { return .unavailable(code) }
                catch { return .unavailable(EIO) }
            }
#endif
            return .same
        case 0: return .different
        default: return .unavailable(errno)
        }
    }

    func createRepositoryNamespace() throws {
        guard let raw = unsafe raw else { throw RepositoryRootError.closed }
        let effect: (String) -> NVRootInstallResult = { relative in
            var result = NVRootInstallResult()
            unsafe nv_root_create_directory(raw, relative, &result)
            return result
        }
        let result: NVRootInstallResult
#if canImport(Darwin)
        result = try coordinatedWrite("NV Data", effect)
#else
        result = effect("NV Data")
#endif
        if result.root_lost != 0 { throw RootAccessFailure(code: result.error) }
        guard result.outcome == NV_ROOT_INSTALL_VERIFIED else { throw RepositoryRootError.unavailable(result.error) }
    }

    func createRepairNamespace() throws {
        guard let raw = unsafe raw else { throw RepositoryRootError.closed }
        let name = ".nv-stage-" + UUID().uuidString.lowercased()
        var created: OpaquePointer?
        let prepare: (String) throws -> Void = { actual in
            guard let pointer = unsafe nv_root_prepare_repair_directory(raw, actual) else {
                throw RepositoryRootError.unavailable(errno)
            }
            unsafe created = pointer
        }
#if canImport(Darwin)
        try coordinatedWrite(name, prepare)
#else
        try prepare(name)
#endif
        guard let pointer = unsafe created else { throw RepositoryRootError.unavailable(EIO) }
        let held = unsafe RootPreparedDirectory(pointer)
        let result: NVRootInstallResult
#if canImport(Darwin)
        result = try coordinatedInstallation(name, at: "NV Data") { _, _ in unsafe held.install(owner: raw) }
#else
        result = unsafe held.install(owner: raw)
#endif
        if result.root_lost != 0 { throw RootAccessFailure(code: result.error) }
        guard result.outcome == NV_ROOT_INSTALL_VERIFIED else { throw RepositoryRootError.unavailable(result.error) }
    }

    func beginRepairNamespace(_ words: [UInt64]) throws {
        guard let raw = unsafe raw else { throw RepositoryRootError.closed }
        guard words.count == 9 else { throw RepositoryRootError.wrongContext }
        let effect = {
            guard unsafe nv_root_begin_repair_namespace(raw, words[1], words[2]) == 0 else {
                throw RepositoryRootError.unavailable(errno)
            }
        }
#if canImport(Darwin)
        try coordinatedRead("NV Data", metadataOnly: true) { _ in try effect() }
#else
        try effect()
#endif
    }
    func endRepairNamespace() {
        if let raw = unsafe raw { unsafe nv_root_end_repair_namespace(raw) }
    }

    private func associationIdentity() throws -> [UInt8] {
        guard let raw = unsafe raw else { throw RepositoryRootError.closed }
        var words = [UInt64](repeating: 0, count: 2)
        let result = words.withUnsafeMutableBufferPointer { unsafe nv_root_identity(raw, $0.baseAddress) }
        guard result == 0 else { throw RootAccessFailure(code: errno) }
        return words.flatMap { word in (0..<8).reversed().map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) } }
    }
    func bookmark() throws -> PassivePlatformRecordV1 {
        let identity = try associationIdentity()
#if canImport(Darwin)
        let bytes = try coordinatedURLRead("", metadataOnly: true) { _, url in
            try Array((url as URL).bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        }
        guard try associationIdentity() == identity else { throw RepositoryRootError.stalePermission }
        return try .init(codec: 0x50553501, bytes: identity + bytes)
#else
        // Linux's passive hint is intentionally bound to the selected inode and device.
        return try .init(codec: 0x50553502, bytes: identity)
#endif
    }
    func matches(_ bookmark: PassivePlatformRecordV1) throws -> RepositoryRootContinuity {
        guard bookmark.bytes.count >= 16 else { throw StorageError.integrity }
        guard Array(bookmark.bytes.prefix(16)) == (try associationIdentity()) else { return .different }
#if canImport(Darwin)
        guard bookmark.codec == 0x50553501 else { throw StorageError.unsupported }
        var stale = false
        let candidate = try URL(resolvingBookmarkData: Data(bookmark.bytes.dropFirst(16)), options: [.withoutUI, .withoutMounting],
            relativeTo: nil, bookmarkDataIsStale: &stale)
        return compare(candidate.path)
#else
        guard bookmark.codec == 0x50553502, bookmark.bytes.count == 16 else { throw StorageError.unsupported }
        return .same
#endif
    }

    /// Keeps each native read within its granted interval on the root executor.
    private func coordinatedRead<Value>(_ relative: String, metadataOnly: Bool, beforeRequest: @Sendable () -> Void = {},
                                         _ read: (String) throws -> Value) throws -> Value {
#if canImport(Darwin)
        return try coordinatedURLRead(relative, metadataOnly: metadataOnly, beforeRequest: beforeRequest) { actual, _ in try read(actual) }
#else
        beforeRequest()
        return try read(relative)
#endif
    }

#if canImport(Darwin)
    private func coordinatedURLRead<Value>(_ relative: String, metadataOnly: Bool, beforeRequest: @Sendable () -> Void = {},
                                            _ read: (String, CFURL) throws -> Value) throws -> Value {
        let base = try currentReference()
        return try withCoordinator { coordinator in
            var error: NSError?
            var result: Result<Value, Error>?
            let options: NSFileCoordinator.ReadingOptions = metadataOnly ? .immediatelyAvailableMetadataOnly : .withoutChanges
            let requested = NVAppleAppendReference(base, relative as CFString)
            beforeRequest()
            unsafe NVAppleCoordinateRead(coordinator, requested, options, &error) { actual in
                result = Result {
                    let observed = try checkedRelative(actual, expected: relative)
                    return try read(observed, actual)
                }
            }
            if let result { return try result.get() }
            // Native loss checks keep provider access errors distinct from loss of the lease.
            _ = try currentReference()
            throw RepositoryRootError.unavailable(repositoryCoordinationCode(error))
        }
    }
    private func withCoordinator<Value>(_ operation: (NSFileCoordinator) throws -> Value) throws -> Value {
        let coordinator = presenter?.makeCoordinator() ?? NSFileCoordinator(filePresenter: nil)
        guard coordination.begin(coordinator) else { throw RepositoryRootError.unavailable(ECANCELED) }
        defer { coordination.finish(coordinator) }
        return try operation(coordinator)
    }

    /// Preserves the system-issued reference while checking the continuously held directory.
    private func currentReference() throws -> CFURL {
        guard let raw = unsafe raw else { throw RepositoryRootError.closed }
        guard unsafe nv_root_validate(raw) == 0 else { throw RootAccessFailure(code: errno) }
        guard let reference else { throw RootAccessFailure(code: ESTALE) }
        return reference
    }

    /// Binds Foundation's actual accessor URL to the owned root and a safe rooted path.
    private func checkedRelative(_ actual: CFURL, expected: String) throws -> String {
        let base = try currentReference()
        let tail = expected.isEmpty ? [] : expected.split(separator: "/").map(String.init)
        guard tail.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 && !$0.utf8.contains(0) }) else {
            throw RepositoryRootError.unsafePath
        }
        guard NVAppleReferenceHasRoot(actual, base, expected as CFString) else {
            throw RepositoryRootError.unavailable(ESTALE)
        }
        return tail.joined(separator: "/")
    }

    /// Coordinates one add-only destination while preserving its requested rooted name.
    private func coordinatedWrite<Value>(_ relative: String, _ write: (String) throws -> Value) throws -> Value {
        let base = try currentReference()
        return try withCoordinator { coordinator in
            var error: NSError?, result: Result<Value, Error>?
            let requested = NVAppleAppendReference(base, relative as CFString)
            unsafe NVAppleCoordinateWrite(coordinator, requested, [], &error) { actual in
                result = Result {
                    let observed = try checkedRelative(actual, expected: relative)
                    return try write(observed)
                }
            }
            if let result { return try result.get() }
            _ = try currentReference()
            throw RepositoryRootError.unavailable(repositoryCoordinationCode(error))
        }
    }

    /// Grants both exact names for the indivisible stage-to-final installation.
    private func coordinatedInstallation(_ stage: String, at destination: String,
                                         _ install: (String, String) -> NVRootInstallResult) throws -> NVRootInstallResult {
        let base = try currentReference()
        return try withCoordinator { coordinator in
            var error: NSError?, result: Result<NVRootInstallResult, Error>?
            // The private stage is consumed while a new immutable destination is installed.
            let source = NVAppleAppendReference(base, stage as CFString)
            let target = NVAppleAppendReference(base, destination as CFString)
            unsafe NVAppleCoordinateInstall(coordinator, source, target, &error) { source, target in
                result = Result {
                    let observedSource = try checkedRelative(source, expected: stage)
                    let observedTarget = try checkedRelative(target, expected: destination)
                    return install(observedSource, observedTarget)
                }
            }
            if let result { return try result.get() }
            _ = try currentReference()
            throw RepositoryRootError.unavailable(repositoryCoordinationCode(error))
        }
    }

#else
    private func coordinatedWrite<Value>(_ relative: String, _ write: (String) throws -> Value) throws -> Value {
        try checkCopyRoot()
        return try write(relative)
    }
    private func coordinatedInstallation(_ stage: String, at destination: String,
                                         _ install: (String, String) -> NVRootInstallResult) throws -> NVRootInstallResult {
        try checkCopyRoot()
        return install(stage, destination)
    }
#endif

    private func combining(_ result: NVRootInstallResult, changed: Bool) -> NVRootInstallResult {
        var value = result
        if changed {
            value.namespace_changed = 1
            if value.outcome == NV_ROOT_INSTALL_NO_EFFECT { value.outcome = NV_ROOT_INSTALL_UNCERTAIN }
        }
        return value
    }

}

/// Couples source coordination to the exclusively created destination's identity checks.
private final class RootCopyAccess: RepositoryCopyCoordination {
    private let root: RootLease
    private let destination: String
    private var destinationRoot: RootLease?
    private let beforeInstall: @Sendable (String) -> Void
#if canImport(Darwin)
    private var reference: CFURL
#endif
    init(root: RootLease, destination: String, beforeInstall: @escaping @Sendable (String) -> Void = { _ in }) {
        self.root = root
        self.destination = destination
        self.beforeInstall = beforeInstall
#if canImport(Darwin)
        reference = URL(fileURLWithPath: destination) as CFURL
#endif
    }
    func bind(_ destination: RootLease) throws {
        try destination.checkCopyRoot()
#if canImport(Darwin)
        guard let created = unsafe CFURLCreateFileReferenceURL(nil, reference, nil) else { throw RepositoryRootError.unavailable(ESTALE) }
        self.reference = unsafe created.takeRetainedValue()
#endif
        try destination.checkCopyRoot(); self.destinationRoot = destination
    }
    func install(_ bytes: [UInt8], at path: String) throws {
        try root.checkCopyRoot()
        guard let destinationRoot else { throw RepositoryRootError.wrongContext }
        try checkDestination()
        let beforeInstall = beforeInstall
        let result = destinationRoot.installExact(bytes: bytes, at: path,
            stage: ".nv-stage-" + UUID().uuidString.lowercased(), beforeInstall: { beforeInstall(path) }, afterInstall: {})
        try root.checkCopyRoot()
        try checkDestination()
        guard result.outcome == NV_ROOT_INSTALL_VERIFIED else {
            throw StorageError.ownership(result.error == 0 ? EIO : result.error)
        }
    }
    private func checkDestination() throws {
        if let destinationRoot {
            try destinationRoot.checkCopyRoot()
            guard destinationRoot.compare(destination) == .same else { throw RepositoryRootError.stalePermission }
        }
    }
    func reading<Value>(_ path: String, metadataOnly: Bool, _ action: () throws -> Value) throws -> Value {
        try root.copyRead(path, metadataOnly: metadataOnly, action)
    }
    func writing<Value>(_ path: String, _ action: () throws -> Value) throws -> Value {
        try grant(path, readSource: false, action)
    }
    func copying<Value>(_ path: String, _ action: () throws -> Value) throws -> Value {
        try grant(path, readSource: true, action)
    }
    private func grant<Value>(_ path: String, readSource: Bool, _ action: () throws -> Value) throws -> Value {
        let checked = {
            try self.checkDestination()
            let value = try action()
            try self.checkDestination()
            return value
        }
#if canImport(Darwin)
        return try root.copyWrite(base: reference, path: path, readSource: readSource, checked)
#else
        return try root.copyWrite(path: path, readSource: readSource, checked)
#endif
    }
}

/// Owns one shallow stream; the root's bounded stack preserves suspended parents.
@safe
private final class RootListingLease {
    var raw: OpaquePointer?
    let relative: String
    let metadata: Bool
    var identifier = UUID()
    private let executor: StorageExecutor
    init(raw: OpaquePointer, relative: String, metadata: Bool, executor: StorageExecutor) {
        unsafe self.raw = raw; self.relative = relative; self.metadata = metadata; self.executor = executor
    }
    deinit { unsafe executor.retireRootListing(raw) }
    func close() {
        if let raw = unsafe raw { unsafe nv_root_list_close(raw); unsafe self.raw = nil }
    }
}
