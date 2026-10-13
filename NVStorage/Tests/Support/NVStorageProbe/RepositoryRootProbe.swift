import Foundation
import NVStorageRuntime

private struct RootRequest: Decodable {
    let command: String
    let argument: String?
}

/// Exercises the production root owner under independent process and namespace control.
func runRepositoryRootProbe(_ args: [String]) async throws -> Bool {
    guard args.count == 2, args[0] == "root-hold" || args[0] == "root-try" else { return false }
    let root: RepositoryRootSession
    do { root = try await RepositoryRootSession.open(directory: args[1]) }
    catch RepositoryRootError.contention { try output(["state": "contention"]); return true }
    if args[0] == "root-try" { await root.close(); try output(["state": "acquired"]); return true }
    var permission = try await root.permission()
    let original = permission
    try output(["state": "owned"])
    while let line = readLine() {
        let request = try JSONDecoder().decode(RootRequest.self, from: Data(line.utf8))
        do {
            switch request.command {
            case "observe", "observe-old":
                let result = try await root.observe(request.argument ?? "", using: request.command == "observe" ? permission : original)
                try output(["kind": result.kind.rawValue, "bytes": result.byteCount])
            case "read":
                let observation = try await root.observe(request.argument ?? "", using: permission)
                guard case .contents(let contents) = try await root.read(observation, maximumBytes: 65536, using: permission) else {
                    throw RepositoryRootError.unavailable(EIO)
                }
                try output(["hex": hex(contents.bytes)])
            case "availability":
                let observation = try await root.observe(request.argument ?? "", using: permission)
                guard case .observed(let status) = try await root.availability(observation, using: permission) else {
                    throw RepositoryRootError.unavailable(EIO)
                }
                try output(["residency": String(describing: status.residency), "management": String(describing: status.management)])
            case "provider":
                let status = try await root.providerObservation(using: permission)
                let category: String
                switch status.lookup { case .identified: category = "identified"; case .unknown: category = "unknown"; case .unsupported: category = "unsupported" }
                try output(["provider": category, "state": String(describing: await root.state)])
            case "compare":
                let result = try await root.revalidate(candidate: request.argument ?? "")
                if result == .same { permission = try await root.permission() }
                try output(["continuity": String(describing: result), "state": String(describing: await root.state)])
            case "invalidate":
                await root.invalidate(); try output(["state": String(describing: await root.state)])
            case "quiesce":
                await root.quiesce(); try output(["state": String(describing: await root.state)])
            case "state":
                try output(["state": String(describing: await root.state)])
            case "fd-count":
                let directory = FileManager.default.fileExists(atPath: "/proc/self/fd") ? "/proc/self/fd" : "/dev/fd"
                try output(["descriptors": FileManager.default.contentsOfDirectory(atPath: directory).count])
            case "close":
                await root.close(); try output(["state": "closed"]); return true
            default: throw RepositoryRootError.wrongContext
            }
        } catch let error as RepositoryRootError { try output(["error": String(describing: error)]) }
    }
    await root.close()
    return true
}
