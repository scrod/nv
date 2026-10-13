import Foundation
import Crypto
import NVStorageCore
import NVStorageRuntime

private func repositoryFixtureUUID() -> [UInt8] { withUnsafeBytes(of: UUID().uuid) { Array($0) } }

/// Creates or reopens actual profile-specific envelopes through the public rooted boundary.
func runRepositoryFilesProbe(_ args: [String]) async throws -> Bool {
    guard args.count == 3, ["files-prepare", "files-install", "files-read"].contains(args[0]) else { return false }
    let fixtures = URL(fileURLWithPath: args[1]), repository = args[2]
    let descriptorFile = fixtures.appendingPathComponent("descriptor.fixture")
    let objectFile = fixtures.appendingPathComponent("sealed.fixture")
    let profileFile = fixtures.appendingPathComponent("profile.fixture")
    if args[0] == "files-prepare" {
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        let encrypted = repository == "encrypted"
        guard encrypted || repository == "public" else { throw RepositoryRootError.wrongContext }
        let collection = try CollectionID(bytes: repositoryFixtureUUID()), writer = try WriterEpoch(bytes: repositoryFixtureUUID())
        let key = SymmetricKey(size: .bits256), keyID = try CollectionKeyID(bytes: repositoryFixtureUUID())
        let protection: ObjectProtectionV1 = encrypted ? .encrypted(keyID: keyID, key: key) : .publicHash
        let bytes = try ObjectEnvelopeV1.seal(payload: Array("independent subprocess fixture\n".utf8), kind: .changes,
            collection: collection, writer: writer, sequence: 1, protection: protection)
        let opened = try ObjectEnvelopeV1.open(bytes, collection: collection, protection: protection)
        let descriptor = try encrypted ? BootstrapDescriptorV1.wrap(collection: collection, keyID: keyID, genesis: opened.locator,
            collectionKey: key, passphrase: "isolated fixture password") : .publicDescriptor(collection: collection, genesis: opened.locator)
        try Data(bytes).write(to: objectFile)
        try Data(descriptor.encodedBytes).write(to: descriptorFile)
        try Data(repository.utf8).write(to: profileFile)
        let object = try ImmutableRepositoryObject.envelope(bytes, locator: opened.locator, collection: collection, protection: protection)
        try output(["path": object.locator.relativePath, "bytes": bytes.count, "profile": repository])
        return true
    }
    let descriptor = try BootstrapDescriptorV1.decodeV1(Array(Data(contentsOf: descriptorFile)))
    let protection: ObjectProtectionV1
    if let keyID = descriptor.keyID { protection = .encrypted(keyID: keyID, key: try descriptor.unwrap(passphrase: "isolated fixture password")) }
    else { protection = .publicHash }
    let bytes = try Array(Data(contentsOf: objectFile))
    let object = try ImmutableRepositoryObject.envelope(bytes, locator: descriptor.genesis, collection: descriptor.collection, protection: protection)
    let root = try await RepositoryRootSession.open(directory: repository), permission = try await root.permission()
    do {
        if args[0] == "files-install" {
            let result = try await root.install(object, for: descriptor, using: permission)
            switch result {
            case .verified(let evidence):
                try await root.validate(evidence, for: object, using: permission)
                try output(["state": "verified", "existing": evidence.reusedExisting, "path": evidence.locator.relativePath])
            case .notInstalled(let failure), .uncertain(let failure):
                try output(["state": "unverified", "reason": String(describing: failure.reason), "retainedStage": failure.stageRetained])
            }
        } else {
            let observation = try await root.observe(object.locator.relativePath, using: permission)
            guard case .contents(let read) = try await root.read(observation, maximumBytes: bytes.count, using: permission) else { throw StorageError.integrity }
            let opened = try ObjectEnvelopeV1.open(read.bytes, collection: descriptor.collection, protection: protection, expectedLocator: descriptor.genesis)
            try output(["state": "read", "hex": hex(read.bytes), "payload": String(decoding: opened.payload, as: UTF8.self)])
        }
        await root.close()
    } catch { await root.close(); throw error }
    return true
}
