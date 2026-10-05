import Foundation
import Crypto
import CStorageIO
import NVStorageCore

/// A caller's exact known byte requirement, checked independently of discovery order.
public struct RepositoryByteRequirement: Sendable {
    public let path: String
    public let sha256: [UInt8]
    public init(path: String, sha256: [UInt8]) throws {
        try checkRepositoryPath(path)
        guard sha256.count == 32 else { throw StorageError.wrongContext }
        self.path = path; self.sha256 = sha256
    }
}

public struct CopiedRepositoryFile: Sendable {
    public let path: String
    public let byteCount: UInt64
    public let sha256: [UInt8]
    fileprivate init(path: String, byteCount: UInt64, sha256: [UInt8]) { self.path = path; self.byteCount = byteCount; self.sha256 = sha256 }
}

/// Entry-scoped omissions remain explicit alongside successfully preserved bytes.
public struct RepositoryCopyIssue: Sendable {
    public let path: String
    public let cause: StorageError
    fileprivate init(path: String, cause: StorageError) { self.path = path; self.cause = cause }
}

/// Captured available bytes and known requirements have separate completeness results.
public struct RepositoryCopyResult: Sendable {
    public let destination: String
    public let files: [CopiedRepositoryFile]
    public let issues: [RepositoryCopyIssue]
    public let unmetRequirements: [RepositoryByteRequirement]
    public var capturedInventoryComplete: Bool { issues.isEmpty }
    fileprivate init(destination: String, files: [CopiedRepositoryFile], issues: [RepositoryCopyIssue], requirements: [RepositoryByteRequirement]) {
        self.destination = destination; self.files = files; self.issues = issues
        let byPath = Dictionary(files.map { ($0.path, $0.sha256) }, uniquingKeysWith: { a, _ in a })
        unmetRequirements = requirements.filter { byPath[$0.path] != $0.sha256 }
    }
}

/// A standalone rooted byte copy accepts locked repositories and operates without private storage.
public enum RepositoryCopy {
    public static func preserveAvailable(from source: String, to destination: String,
        requirements: [RepositoryByteRequirement] = []) async throws -> RepositoryCopyResult {
        try await RepositoryCopyWorker().copy(source: source, destination: destination, requirements: requirements)
    }
    static func preserveAvailable(from source: String, to destination: String, requirements: [RepositoryByteRequirement] = [],
        captured: @escaping @Sendable (String) async -> Void) async throws -> RepositoryCopyResult {
        try await RepositoryCopyWorker().copy(source: source, destination: destination, requirements: requirements, captured: captured)
    }
}

actor RepositoryCopyWorker {
    nonisolated private let executor = StorageExecutor(label: "org.notationalvelocity.storage.repository-copy", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { unsafe executor.asUnownedSerialExecutor() }
    func copy(source: String, destination: String, requirements: [RepositoryByteRequirement],
              captured: (@Sendable (String) async -> Void)? = nil,
              saved: CapturedRepositoryHistory? = nil) async throws -> RepositoryCopyResult {
        guard !source.utf8.contains(0), !destination.utf8.contains(0) else { throw StorageError.wrongContext }
        let from = try RepositoryLease(source: source, executor: executor)
        let to = try RepositoryLease(destination: destination, source: from, executor: executor)
        defer { to.close(); from.close() }
        var directories = [""], files: [CopiedRepositoryFile] = [], issues: [RepositoryCopyIssue] = []
        while let directory = directories.popLast() {
            try Task.checkCancellation()
            do {
                for leaf in try from.names(directory) {
                    let path = directory.isEmpty ? leaf : directory + "/" + leaf
                    do {
                        let observation = try from.observe(path)
                        await captured?(path)
                        switch observation[0] {
                        case 1:
                            let hash = try from.digest(path, observation: observation)
                            try from.copy(path, to: to, observation: observation)
                            let target = try to.observe(path)
                            guard target[3] == observation[3], try to.digest(path, observation: target) == hash else { throw StorageError.integrity }
                            files.append(CopiedRepositoryFile(path: path, byteCount: observation[3], sha256: hash))
                        case 2:
                            guard try from.observe(path) == observation else { throw StorageError.staleCapture }
                            try to.mkdir(path); directories.append(path)
                        default: throw StorageError.unsupported
                        }
                    } catch { issues.append(RepositoryCopyIssue(path: path, cause: filesystemFailure(error))) }
                    try Task.checkCancellation()
                    await Task.yield()
                }
            } catch { issues.append(RepositoryCopyIssue(path: directory, cause: filesystemFailure(error))) }
            try Task.checkCancellation()
        }
        if let saved { try installSaved(saved, to: to, files: &files, issues: &issues) }
        try from.validate(); try to.sync()
        return RepositoryCopyResult(destination: destination, files: files.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) },
            issues: issues, requirements: requirements + (saved?.requirements ?? []))
    }
    func export(_ saved: CapturedRepositoryHistory, to destination: String) throws -> RepositoryCopyResult {
        let to = try RepositoryLease(freshDestination: destination, executor: executor)
        defer { to.close() }
        var files: [CopiedRepositoryFile] = [], issues: [RepositoryCopyIssue] = []
        try installSaved(saved, to: to, files: &files, issues: &issues)
        try to.sync()
        return RepositoryCopyResult(destination: destination, files: files, issues: issues, requirements: saved.requirements)
    }
    private func installSaved(_ saved: CapturedRepositoryHistory, to destination: RepositoryLease,
                              files: inout [CopiedRepositoryFile], issues: inout [RepositoryCopyIssue]) throws {
        var installed = Dictionary(files.map { ($0.path, $0.sha256) }, uniquingKeysWith: { a, _ in a })
        var directories: Set<String> = []
        for object in saved.objects {
            try Task.checkCancellation()
            do {
                if let prior = installed[object.path] {
                    guard prior == object.sha256 else { throw StorageError.integrity }; continue
                }
                let parts = object.path.split(separator: "/").dropLast()
                var parent = ""
                for part in parts {
                    parent = parent.isEmpty ? String(part) : parent + "/" + part
                    if directories.insert(parent).inserted {
                        do { try destination.mkdir(parent) }
                        catch {
                            // Captured/copied directories are revalidated before exclusive child creation.
                            guard try destination.observe(parent)[0] == 2 else { throw error }
                        }
                    }
                }
                try destination.install(object.bytes, path: object.path)
                files.append(CopiedRepositoryFile(path: object.path, byteCount: UInt64(object.bytes.count), sha256: object.sha256))
                installed[object.path] = object.sha256
            } catch { issues.append(RepositoryCopyIssue(path: object.path, cause: filesystemFailure(error))) }
        }
    }
}

/// Retained root descriptors provide every child lookup and exclusive destination install.
@safe
final class RepositoryLease {
    private var raw: OpaquePointer?
    private let executor: StorageExecutor
    init(source: String, executor: StorageExecutor) throws {
        self.executor = executor
        unsafe raw = nv_repository_open(source)
        guard unsafe raw != nil else { throw StorageError.ownership(errno) }
    }
    init(destination: String, source: RepositoryLease, executor: StorageExecutor) throws {
        self.executor = executor
        unsafe raw = try nv_repository_create(source.handle(), destination)
        guard unsafe raw != nil else { throw StorageError.ownership(errno) }
    }
    init(freshDestination: String, executor: StorageExecutor) throws {
        self.executor = executor
        guard !freshDestination.utf8.contains(0) else { throw StorageError.wrongContext }
        unsafe raw = nv_repository_create(nil, freshDestination)
        guard unsafe raw != nil else { throw StorageError.ownership(errno) }
    }
    deinit { unsafe executor.retireRepository(raw) }
    func close() { if let raw = unsafe raw { unsafe nv_repository_close(raw); unsafe self.raw = nil } }
    private func handle() throws -> OpaquePointer { guard let raw = unsafe raw else { throw StorageError.closed }; return unsafe raw }
    func validate() throws { guard unsafe try nv_repository_validate(handle()) == 0 else { throw StorageError.ownership(errno) } }
    func sync() throws { guard unsafe try nv_repository_sync(handle()) == 0 else { throw StorageError.ownership(errno) } }
    func names(_ relative: String) throws -> [String] {
        guard let catalog = unsafe try nv_repository_catalog(handle(), relative) else { throw StorageError.ownership(errno) }
        defer { unsafe nv_repository_catalog_close(catalog) }
        var names: [String] = []
        while let name = unsafe nv_repository_next(catalog) {
            guard let decoded = unsafe String(validatingCString: name) else { throw StorageError.unsupported }
            names.append(decoded)
        }
        guard errno == 0 else { throw StorageError.ownership(errno) }
        return names
    }
    func observe(_ path: String) throws -> [UInt64] {
        try checkRepositoryPath(path)
        let raw = unsafe try handle()
        var words = [UInt64](repeating: 0, count: 9)
        let result = words.withUnsafeMutableBufferPointer { unsafe nv_repository_observe(raw, path, $0.baseAddress) }
        guard result == 0 else { throw StorageError.ownership(errno) }; return words
    }
    func mkdir(_ path: String) throws { try checkRepositoryPath(path); guard unsafe try nv_repository_mkdir(handle(), path) == 0 else { throw StorageError.ownership(errno) } }
    func copy(_ path: String, to destination: RepositoryLease, observation: [UInt64]) throws {
        let from = unsafe try handle(), to = unsafe try destination.handle()
        guard observation.count == 9 else { throw StorageError.wrongContext }
        let result = observation.withUnsafeBufferPointer { unsafe nv_repository_copy(from, to, path, $0.baseAddress) }
        guard result == 0 else { throw StorageError.ownership(errno) }
    }
    func digest(_ path: String, observation: [UInt64]) throws -> [UInt8] {
        let raw = unsafe try handle()
        guard observation.count == 9 else { throw StorageError.wrongContext }
        let fd = observation.withUnsafeBufferPointer { unsafe nv_repository_read_open(raw, path, $0.baseAddress) }
        guard fd >= 0 else { throw StorageError.ownership(errno) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var hash = SHA256(), count: UInt64 = 0
        while let data = try file.read(upToCount: 65536), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data); count += UInt64(data.count)
        }
        guard count == observation[3], try observe(path) == observation else { throw StorageError.staleCapture }
        return Array(hash.finalize())
    }
    func install(_ bytes: [UInt8], path: String) throws {
        try checkRepositoryPath(path)
        let raw = unsafe try handle()
        let result = bytes.withUnsafeBufferPointer { unsafe nv_repository_install(raw, path, $0.baseAddress, UInt64($0.count)) }
        guard result == 0 else { throw StorageError.ownership(errno) }
        let observed = try observe(path)
        guard observed[3] == bytes.count, try digest(path, observation: observed) == Array(SHA256.hash(data: bytes)) else { throw StorageError.integrity }
    }
}

private func checkRepositoryPath(_ path: String) throws {
    guard !path.utf8.contains(0), !path.isEmpty, !path.hasPrefix("/"),
          path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw StorageError.wrongContext }
}
