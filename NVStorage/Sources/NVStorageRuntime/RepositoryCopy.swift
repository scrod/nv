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
    /// Reuses the caller's continuously owned root for an active collection's copy.
    public static func preserveAvailable(from source: RepositoryRootSession, to destination: String,
        requirements: [RepositoryByteRequirement] = []) async throws -> RepositoryCopyResult {
        try await source.copyRepository(to: destination, requirements: requirements)
    }
    public static func preserveAvailable(from source: String, to destination: String,
        requirements: [RepositoryByteRequirement] = []) async throws -> RepositoryCopyResult {
        try await RepositoryCopyWorker().copy(source: source, destination: destination, requirements: requirements)
    }
    static func preserveAvailable(from source: String, to destination: String, requirements: [RepositoryByteRequirement] = [],
        captured: @escaping @Sendable (String) async -> Void) async throws -> RepositoryCopyResult {
        try await RepositoryCopyWorker().copy(source: source, destination: destination, requirements: requirements, captured: captured)
    }
}

/// Synchronous accessor grants surround each bounded discovery or complete file effect.
protocol RepositoryCopyCoordination: AnyObject {
    func reading<Value>(_ path: String, metadataOnly: Bool, _ action: () throws -> Value) throws -> Value
    func writing<Value>(_ path: String, _ action: () throws -> Value) throws -> Value
    func copying<Value>(_ path: String, _ action: () throws -> Value) throws -> Value
    func install(_ bytes: [UInt8], at path: String) throws
}

actor RepositoryCopyWorker {
    nonisolated private let executor = StorageExecutor(label: "org.notationalvelocity.storage.repository-copy", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { unsafe executor.asUnownedSerialExecutor() }
    private struct Frame {
        let path: String
        var catalog: RepositoryCatalogLease?
        var names: [String] = []
        var finished = false
    }
    func copy(source: String, destination: String, requirements: [RepositoryByteRequirement],
              captured: (@Sendable (String) async -> Void)? = nil,
              saved: CapturedRepositoryHistory? = nil) async throws -> RepositoryCopyResult {
        guard !source.utf8.contains(0), !destination.utf8.contains(0) else { throw StorageError.wrongContext }
        guard URL(fileURLWithPath: source).standardizedFileURL != URL(fileURLWithPath: destination).standardizedFileURL else {
            throw StorageError.wrongContext
        }
        let root: RepositoryRootSession
        do { root = try await RepositoryRootSession.open(directory: source) }
        catch {
            guard let saved else { throw error }
            return try await export(saved, to: destination, unavailable: filesystemFailure(error))
        }
        do {
            let copied = try await root.copyRepository(to: destination, requirements: requirements, saved: saved, captured: captured)
            await root.close(); return copied
        } catch { await root.close(); throw error }
    }

    static func copyOwned(from: RepositoryLease, to: RepositoryLease, destination: String,
                          requirements: [RepositoryByteRequirement], saved: CapturedRepositoryHistory?,
                          access: any RepositoryCopyCoordination,
                          captured: (@Sendable (String) async -> Void)?,
                          isolation: isolated any Actor) async throws -> RepositoryCopyResult {
        var frames = [Frame(path: "")], files: [CopiedRepositoryFile] = [], issues: [RepositoryCopyIssue] = []
        defer { for frame in frames { frame.catalog?.close() } }
        // Verified saved history occupies its canonical names in the fresh destination.
        if let saved { try await installSaved(saved, files: &files, issues: &issues, access: access, isolation: isolation) }
        let savedFiles = Dictionary((saved?.requirements ?? []).map { ($0.path, $0.sha256) }, uniquingKeysWith: { first, _ in first })
        while !frames.isEmpty {
            try Task.checkCancellation()
            let index = frames.count - 1, directory = frames[index].path
            do {
                if frames[index].names.isEmpty {
                    if frames[index].finished { frames.removeLast().catalog?.close(); continue }
                    let page = try access.reading(directory, metadataOnly: true) {
                        if frames[index].catalog == nil { frames[index].catalog = try from.catalog(directory) }
                        let catalog = frames[index].catalog!
                        try from.validate(catalog, at: directory)
                        let page = try catalog.next(budget: 16)
                        try from.validate(catalog, at: directory)
                        return page
                    }
                    frames[index].names = page.names
                    frames[index].finished = page.finished
                    continue
                }
                let leaf = frames[index].names.removeFirst()
                let path = directory.isEmpty ? leaf : directory + "/" + leaf
                do {
                    let observation = try access.reading(path, metadataOnly: true) { try from.observe(path) }
                    await captured?(path)
                    switch observation[0] {
                    case 1:
                        let hash = try access.reading(path, metadataOnly: false) { try from.digest(path, observation: observation) }
                        if let expected = savedFiles[path] {
                            guard hash == expected else { throw StorageError.integrity }
                            try access.writing(path) {
                                let target = try to.observe(path)
                                guard try to.digest(path, observation: target) == expected else { throw StorageError.integrity }
                            }
                        } else {
                            if isProtocolFile(path), observation[3] > 0 {
                                let bytes = try access.reading(path, metadataOnly: false) { try from.readProtocolBytes(path, observation: observation) }
                                guard Array(SHA256.hash(data: bytes)) == hash else { throw StorageError.staleCapture }
                                try access.install(bytes, at: path)
                            } else {
                                try access.copying(path) { try from.copy(path, to: to, observation: observation) }
                            }
                            try access.writing(path) {
                                let target = try to.observe(path)
                                guard target[3] == observation[3], try to.digest(path, observation: target) == hash else { throw StorageError.integrity }
                            }
                            try access.reading(path, metadataOnly: true) {
                                guard try from.observe(path) == observation else { throw StorageError.staleCapture }
                            }
                            files.append(CopiedRepositoryFile(path: path, byteCount: observation[3], sha256: hash))
                        }
                    case 2:
                        try access.copying(path) {
                            guard try from.observe(path) == observation else { throw StorageError.staleCapture }
                            do { try to.mkdir(path) }
                            catch { guard try to.observe(path)[0] == 2 else { throw error } }
                        }
                        frames.append(Frame(path: path))
                    default: throw StorageError.unsupported
                    }
                } catch { issues.append(RepositoryCopyIssue(path: path, cause: filesystemFailure(error))) }
                try Task.checkCancellation()
                await Task.yield()
            } catch {
                issues.append(RepositoryCopyIssue(path: directory, cause: filesystemFailure(error)))
                frames.removeLast().catalog?.close()
            }
            try Task.checkCancellation()
        }
        try access.reading("", metadataOnly: true) { try from.validate() }
        try access.writing("") { try to.sync() }
        return RepositoryCopyResult(destination: destination, files: files.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) },
            issues: issues, requirements: requirements + (saved?.requirements ?? []))
    }
    func export(_ saved: CapturedRepositoryHistory, to destination: String,
                unavailable: StorageError? = nil) async throws -> RepositoryCopyResult {
        let issues = unavailable.map { [RepositoryCopyIssue(path: "", cause: $0)] } ?? []
        return try await RepositoryRootSession.exportHistory(saved, to: destination, issues: issues)
    }
    static func exportOwned(_ saved: CapturedRepositoryHistory, destination: String,
                            issues initialIssues: [RepositoryCopyIssue], access: any RepositoryCopyCoordination,
                            isolation: isolated any Actor) async throws -> RepositoryCopyResult {
        var files: [CopiedRepositoryFile] = [], issues = initialIssues
        try await installSaved(saved, files: &files, issues: &issues, access: access, isolation: isolation)
        return RepositoryCopyResult(destination: destination, files: files, issues: issues, requirements: saved.requirements)
    }
    private static func installSaved(_ saved: CapturedRepositoryHistory,
                              files: inout [CopiedRepositoryFile], issues: inout [RepositoryCopyIssue],
                              access: any RepositoryCopyCoordination, isolation: isolated any Actor) async throws {
        var installed = Dictionary(files.map { ($0.path, $0.sha256) }, uniquingKeysWith: { a, _ in a })
        try await saved.forEachBatch(isolation: isolation) { objects in
            for object in objects {
                try Task.checkCancellation()
                let path = object.locator.relativePath, hash = Array(SHA256.hash(data: object.bytes))
                do {
                    if let prior = installed[path] {
                        guard prior == hash else { throw StorageError.integrity }; continue
                    }
                    try access.install(object.bytes, at: path)
                    files.append(CopiedRepositoryFile(path: path, byteCount: UInt64(object.bytes.count), sha256: hash))
                    installed[path] = hash
                } catch { issues.append(RepositoryCopyIssue(path: path, cause: filesystemFailure(error))) }
                try Task.checkCancellation()
                await Task.yield()
            }
        }
    }
    private static func isProtocolFile(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        return (parts.count == 4 && parts.prefix(3) == ["NV Data", "v1", "keys"])
            || (parts.count == 5 && parts.prefix(3) == ["NV Data", "v1", "segments"])
    }
}

/// Retained root descriptors provide every child lookup and exclusive destination install.
@safe
final class RepositoryLease {
    private var raw: OpaquePointer?
    private let executor: StorageExecutor
    init(root: OpaquePointer, executor: StorageExecutor) throws {
        self.executor = executor
        unsafe raw = nv_repository_borrow_root(root)
        guard unsafe raw != nil else { throw StorageError.ownership(errno) }
    }
    deinit { unsafe executor.retireRepository(raw) }
    func close() { if let raw = unsafe raw { unsafe nv_repository_close(raw); unsafe self.raw = nil } }
    private func handle() throws -> OpaquePointer { guard let raw = unsafe raw else { throw StorageError.closed }; return unsafe raw }
    func validate() throws { guard unsafe try nv_repository_validate(handle()) == 0 else { throw StorageError.ownership(errno) } }
    func sync() throws { guard unsafe try nv_repository_sync(handle()) == 0 else { throw StorageError.ownership(errno) } }
    func catalog(_ relative: String) throws -> RepositoryCatalogLease {
        guard let catalog = unsafe try nv_repository_catalog(handle(), relative) else { throw StorageError.ownership(errno) }
        return unsafe RepositoryCatalogLease(catalog, executor: executor)
    }
    func validate(_ catalog: RepositoryCatalogLease, at path: String) throws {
        guard unsafe try nv_repository_catalog_validate(handle(), catalog.handle(), path) == 0 else { throw StorageError.staleCapture }
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
    func readProtocolBytes(_ path: String, observation: [UInt64]) throws -> [UInt8] {
        guard observation.count == 9, observation[3] <= ObjectLimitsV1.encodedPayloadBytes + 156 else { throw StorageError.limit }
        let raw = unsafe try handle()
        let fd = observation.withUnsafeBufferPointer { unsafe nv_repository_read_open(raw, path, $0.baseAddress) }
        guard fd >= 0 else { throw StorageError.ownership(errno) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var bytes: [UInt8] = []
        while bytes.count < observation[3] {
            try Task.checkCancellation()
            guard let part = try file.read(upToCount: min(65536, Int(observation[3]) - bytes.count)), !part.isEmpty else { throw StorageError.staleCapture }
            bytes.append(contentsOf: part)
        }
        guard try observe(path) == observation else { throw StorageError.staleCapture }
        return bytes
    }
}

/// Holds one shallow directory stream while a depth-first copy takes bounded turns.
@safe
final class RepositoryCatalogLease {
    private var raw: OpaquePointer?
    private let executor: StorageExecutor
    init(_ raw: OpaquePointer, executor: StorageExecutor) { unsafe self.raw = raw; self.executor = executor }
    deinit { executor.finishOnOwner { if let raw = unsafe raw { unsafe nv_repository_catalog_close(raw) } } }
    func close() { if let raw = unsafe raw { unsafe nv_repository_catalog_close(raw); unsafe self.raw = nil } }
    func handle() throws -> OpaquePointer { guard let raw = unsafe raw else { throw StorageError.closed }; return unsafe raw }
    func next(budget: Int) throws -> (names: [String], finished: Bool) {
        guard budget > 0, budget <= 16 else { throw StorageError.wrongContext }
        var names: [String] = []
        for _ in 0..<budget {
            guard let name = unsafe try nv_repository_next(handle()) else {
                guard errno == 0 else { throw StorageError.ownership(errno) }
                return (names, true)
            }
            guard let decoded = unsafe String(validatingCString: name) else { throw StorageError.unsupported }
            names.append(decoded)
        }
        return (names, false)
    }
}

private func checkRepositoryPath(_ path: String) throws {
    guard !path.utf8.contains(0), !path.isEmpty, !path.hasPrefix("/"),
          path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw StorageError.wrongContext }
}
