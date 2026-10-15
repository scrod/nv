import Foundation
import NVStorageCore

/// An explicitly selected, continuously owned source supplies exact complementary bytes.
public struct RepositoryRepairSource: Sendable {
    fileprivate let root: RepositoryRootSession
    fileprivate let permission: RepositoryRootPermission
    fileprivate let descriptor: BootstrapDescriptorV1
    fileprivate init(root: RepositoryRootSession, permission: RepositoryRootPermission, descriptor: BootstrapDescriptorV1) {
        self.root = root; self.permission = permission; self.descriptor = descriptor
    }
}

public enum RepositoryRepairSourceError: Error, Equatable, Sendable {
    case unavailable(path: String, reason: RepositoryFileFailure)
}

/// Identifies unusable evidence within the caller's ordered complementary source list.
public struct RepositoryRepairSourceIssue: Sendable {
    public let sourceIndex: Int
    public let path: String
    public let failure: RepositoryTransportFailure
    fileprivate init(sourceIndex: Int, path: String, failure: RepositoryTransportFailure) {
        self.sourceIndex = sourceIndex; self.path = path; self.failure = failure
    }
    var error: any Error {
        switch failure {
        case .file(let reason): RepositoryRepairSourceError.unavailable(path: path, reason: reason)
        case .store(let reason): reason
        case .root(let reason): reason
        case .deadline: StorageError.incomplete
        }
    }
}

extension RepositoryRootSession {
    /// Freezes the selected collection context and current physical permission for repair reads.
    public func repairSource(for descriptor: BootstrapDescriptorV1) throws -> RepositoryRepairSource {
        .init(root: self, permission: try permission(), descriptor: descriptor)
    }
}

/// A depth-first bounded listing supplies one checked object at a time to private reconstruction.
actor RepositoryRepairReader {
    private struct Frame {
        let directory: RepositoryProtocolDirectory
        var cursor: RepositoryListingCursor?
        var names: [RepositoryDiscoveredLeaf] = []
        var finished = false
    }
    private let source: RepositoryRepairSource
    private let protection: ObjectProtectionV1
    private let wanted: Set<String>
    private let sourceIndex: Int
    private(set) var issues: [RepositoryRepairSourceIssue] = []
    private var frames: [Frame] = [.init(directory: .segments), .init(directory: .keys)]
    private var running = false

    init(source: RepositoryRepairSource, descriptor: BootstrapDescriptorV1,
         protection: ObjectProtectionV1, missing: Set<[UInt8]>, sourceIndex: Int = 0) throws {
        guard source.descriptor.collection == descriptor.collection, source.descriptor.genesis == descriptor.genesis,
              source.descriptor.keyID == descriptor.keyID else { throw StorageError.wrongContext }
        self.source = source; self.protection = protection; self.sourceIndex = sourceIndex
        let digits = Array("0123456789abcdef".utf8)
        wanted = Set(missing.map { bytes in
            String(decoding: bytes.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] }, as: UTF8.self)
        })
    }

    func next() async throws -> [SQLValue]? {
        guard !running else { throw StorageError.busy }
        running = true; defer { running = false }
        try await source.root.checkPermission(source.permission)
        while !frames.isEmpty {
            try Task.checkCancellation()
            let index = frames.count - 1, directory = frames[index].directory
            if frames[index].names.isEmpty {
                if frames[index].finished { frames.removeLast(); continue }
                let page: RepositoryListingPage
                do {
                    page = try await source.root.list(directory, continuing: frames[index].cursor, budget: 16, using: source.permission)
                } catch RepositoryRootError.unavailable(let code) {
                    try await source.root.checkPermission(source.permission)
                    if code != ENOENT {
                        issues.append(.init(sourceIndex: sourceIndex, path: directory.relativePath,
                                            failure: .file(.init(code: code))))
                    }
                    if let cursor = frames[index].cursor {
                        try? await source.root.cancelListing(cursor, using: source.permission)
                    }
                    frames.removeLast(); continue
                }
                frames[index].cursor = page.continuation
                frames[index].names = page.names
                frames[index].finished = page.continuation == nil
                continue
            }
            let leaf = frames[index].names.removeFirst()
            if directory == .segments {
                if let epoch = RepositoryRootSession.writerEpoch(leaf.bytes) { frames.append(.init(directory: .writer(epoch))) }
                continue
            }
            let name = String(decoding: leaf.bytes, as: UTF8.self)
            let id: String
            if directory == .keys {
                guard name.utf8.count == 70, name.hasSuffix(".nvkey") else { continue }
                id = String(name.prefix(64))
            } else {
                guard name.utf8.count == 91, name.hasSuffix(".nvseg") else { continue }
                id = String(name.dropFirst(21).prefix(64))
            }
            guard wanted.contains(id) else { continue }
            let path = try leaf.relativePath(in: directory)
            do { return try await read(path, descriptor: directory == .keys) }
            catch let failure as RepositoryRepairSourceError {
                switch failure {
                case .unavailable(_, let reason):
                    issues.append(.init(sourceIndex: sourceIndex, path: path, failure: .file(reason)))
                }
            } catch let failure as CanonicalEncodingError {
                issues.append(.init(sourceIndex: sourceIndex, path: path, failure: .store(classify(failure))))
            } catch StorageError.integrity {
                issues.append(.init(sourceIndex: sourceIndex, path: path, failure: .store(.integrity)))
            }
        }
        try Task.checkCancellation()
        try await source.root.checkPermission(source.permission)
        return nil
    }

    /// Reacquires exact captured inventory bytes under the source's original root permission.
    func reread(_ path: String, descriptor: Bool) async throws -> [SQLValue] {
        guard !running else { throw StorageError.busy }
        running = true; defer { running = false }
        try Task.checkCancellation()
        try await source.root.checkPermission(source.permission)
        let row = try await read(path, descriptor: descriptor)
        try await source.root.checkPermission(source.permission)
        return row
    }

    private func read(_ path: String, descriptor: Bool) async throws -> [SQLValue] {
        let observation: RepositoryEntryObservation
        switch try await source.root.inspect(path, using: source.permission) {
        case .observed(let entry): observation = entry
        case .unavailable(let failure): throw RepositoryRepairSourceError.unavailable(path: path, reason: failure)
        }
        guard observation.kind == .regularFile else { throw StorageError.integrity }
        let bytes: [UInt8]
        switch try await source.root.read(observation, maximumBytes: Int(ObjectLimitsV1.encodedPayloadBytes + 156), using: source.permission) {
        case .contents(let read): bytes = read.bytes
        case .unavailable(let failure): throw RepositoryRepairSourceError.unavailable(path: path, reason: failure)
        }
        if descriptor {
            let descriptor = try BootstrapDescriptorV1.decodeV1(bytes)
            guard descriptor.collection == source.descriptor.collection, descriptor.genesis == source.descriptor.genesis,
                  descriptor.keyID == source.descriptor.keyID, ImmutableRepositoryLocator.descriptor(descriptor).relativePath == path else {
                throw StorageError.integrity
            }
            return [.blob(descriptor.descriptorID), .integer(0), .null, .null, .blob(bytes)]
        }
        let opened = try ObjectEnvelopeV1.open(bytes, collection: source.descriptor.collection, protection: protection)
        guard ImmutableRepositoryLocator.segment(opened.locator).relativePath == path else { throw StorageError.integrity }
        return [.blob(opened.locator.segmentID.bytes), .integer(Int64(opened.kind.rawValue)),
            .blob(opened.locator.writerEpoch.bytes), .blob(Array(opened.locator.encodedV1()[16..<24])), .blob(bytes)]
    }

    func close() async throws {
        guard !running else { throw StorageError.busy }
        running = true; defer { running = false }
        let closing = frames
        frames = []
        for frame in closing {
            if let cursor = frame.cursor { try? await source.root.cancelListing(cursor, using: source.permission) }
        }
    }
}
