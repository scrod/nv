import Foundation
import NVStorageCore
import NVStorageRuntime
import CStorageFaults

/// Fresh-copy consumers receive the destination and ordinary unlock input independently of the source store.
func runRepositoryCopyProbe(_ args: [String]) async throws -> Bool {
    guard let command = args.first, command.hasPrefix("copy-") else { return false }
    if command == "copy-available", args.count == 3 {
        try copyReport(await RepositoryCopy.preserveAvailable(from: args[1], to: args[2]))
        return true
    }
    if ["copy-saved", "copy-saved-exit"].contains(command), args.count == 5 {
        let selected = try JSONDecoder().decode(SelectionFile.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
        let selection = try selected.selection(args[1]), descriptor = selection.descriptor
        let protection: ObjectProtectionV1 = try descriptor.keyID.map {
            .encrypted(keyID: $0, key: try descriptor.unwrap(passphrase: "probe password"))
        } ?? .publicHash
        let owner = try await LocalStoreSession.open(selection: selection, protection: protection)
        let copied = try await owner.copyRepositoryAndSavedWork(from: args[3], to: args[4])
        if command == "copy-saved-exit" { exit(86) }
        try await owner.quiesce()
        try copyReport(copied.repository)
        return true
    }
    if command == "copy-switch", args.count == 8 {
        guard nv_faults_install() == 0 else { throw StorageError.unsupported }
        let selected = try JSONDecoder().decode(SelectionFile.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
        let selection = try selected.selection(args[1]), descriptor = selection.descriptor
        let protection: ObjectProtectionV1 = try descriptor.keyID.map {
            .encrypted(keyID: $0, key: try descriptor.unwrap(passphrase: "probe password"))
        } ?? .publicHash
        let original = try await LocalStoreSession.open(selection: selection, protection: protection)
        let root = try await RepositoryRootSession.open(directory: args[3])
        let prior = try await original.localAssociation()
        let association = try await root.association(for: selection,
            id: prior.value?.id ?? LocalAssociationID(bytes: withUnsafeBytes(of: UUID().uuid) { Array($0) }))
        try await original.saveLocalAssociation(association, basedOn: prior)
        await root.close(); try await original.quiesce()
        guard case .opened(let owner) = await CollectionSession.open(selection: selection, protection: protection) else {
            throw StorageError.incomplete
        }
        let first = try await SelectedStoreOwner.open(directory: args[6])
        let firstState = try await first.capture()
        if firstState.record == nil {
            guard case .activated = try await owner.activateFreshSelection(using: first, basedOn: firstState) else {
                throw StorageError.incomplete
            }
        } else {
            guard firstState.record?.store == selection.store else { throw StorageError.wrongContext }
            try await first.close()
        }
        let selector = try await SelectedStoreOwner.open(directory: args[6]), state = try await selector.capture()
        let fault: (Int32, Int32)? = switch args[7] {
        case "private-before": (4, -1)
        case "private-after": (5, -1)
        case "private-enospc": (1, 13)
        case "private-eio": (2, 1034)
        default: nil
        }
        if let (event, code) = fault { nv_faults_arm_on_repair_private_installation(event, 1, code) }
        do {
            let result = try await owner.switchRepositoryAndSavedWork(to: args[4], privateDirectory: args[5], using: selector, basedOn: state)
            guard case .opened(let successor, let selectedState) = result.outcome else { throw StorageError.incomplete }
            if args[7] == "activated-exit" { exit(86) }
            let copySelection = await successor.selection
            guard selectedState.record?.store == copySelection.store else { throw StorageError.wrongContext }
            try await successor.close()
            try output(["switched": true, "store": hex(copySelection.store.bytes), "unmet": result.copy.repository.unmetRequirements.map(\.path)])
        } catch {
            guard fault != nil else { throw error }
            try await owner.close(); try await selector.close()
            try output(["switched": false, "hits": nv_faults_hits(), "error": String(describing: error)])
        }
        return true
    }
    guard command == "copy-bootstrap", args.count == 5 else { throw StorageError.unsupported }
    let root = try await RepositoryRootSession.open(directory: args[1]), permission = try await root.permission()
    func read(_ directory: RepositoryProtocolDirectory) async throws -> [[UInt8]] {
        var cursor: RepositoryListingCursor?, result: [[UInt8]] = []
        repeat {
            let page = try await root.list(directory, continuing: cursor, budget: 16, using: permission)
            cursor = page.continuation
            for leaf in page.names {
                let path = try leaf.relativePath(in: directory)
                let observation = try await root.observe(path, using: permission)
                guard case .contents(let contents) = try await root.read(observation,
                    maximumBytes: Int(ObjectLimitsV1.encodedPayloadBytes + 156), using: permission) else { throw StorageError.incomplete }
                result.append(contents.bytes)
            }
        } while cursor != nil
        return result
    }
    let descriptors = try await read(.keys).map(BootstrapDescriptorV1.decodeV1)
    guard descriptors.count == 1, let descriptor = descriptors.first else { throw StorageError.incomplete }
    let protection: ObjectProtectionV1 = try descriptor.keyID.map {
        .encrypted(keyID: $0, key: try descriptor.unwrap(passphrase: args[4]))
    } ?? .publicHash
    var cursor: RepositoryListingCursor?, roots: [SegmentLocator] = []
    repeat {
        let page = try await root.list(.segments, continuing: cursor, budget: 16, using: permission)
        cursor = page.continuation
        for leaf in page.names {
            let name = String(decoding: leaf.bytes, as: UTF8.self)
            guard name.count == 32, name.allSatisfy({ $0.isHexDigit }) else { throw StorageError.integrity }
            let writer = try WriterEpoch(bytes: unhex(name))
            for bytes in try await read(.writer(writer)) {
                let opened = try ObjectEnvelopeV1.open(bytes, collection: descriptor.collection, protection: protection)
                if opened.kind == .snapshotRoot, (try? InitialSnapshotRootV1.decodeV1(opened.payload)) != nil {
                    roots.append(opened.locator)
                }
            }
        }
    } while cursor != nil
    await root.close()
    guard roots.count == 1, let snapshot = roots.first else { throw StorageError.incomplete }
    let candidate = try await CollectionBootstrapSession.open(repository: URL(fileURLWithPath: args[1]),
        privateDirectory: args[2], descriptor: descriptor, snapshot: snapshot, protection: protection)
    var ended = false
    for _ in 0..<10000 { if try await candidate.discover(budget: 3).passEnded { ended = true; break } }
    guard ended else { throw StorageError.limit }
    let owner = try await candidate.complete()
    let state = try await owner.publish(owner.preparePublication(liveGeneration: 1), liveGeneration: 1) { $0 }
    let selection = await owner.selection
    try JSONEncoder().encode(SelectionFile(store: selection.store.bytes, descriptor: selection.descriptor.encodedBytes))
        .write(to: URL(fileURLWithPath: args[3]))
    try await owner.close()
    try output(["notes": state.notes.map { ["birth": hex($0.birth.bytes), "body": $0.value.body.string] }])
    return true
}

private func copyReport(_ result: RepositoryCopyResult) throws {
    try output(["completeInventory": result.capturedInventoryComplete,
        "files": result.files.map { ["path": $0.path, "sha256": hex($0.sha256)] },
        "issues": result.issues.map { ["path": $0.path, "cause": String(describing: $0.cause)] },
        "unmet": result.unmetRequirements.map(\.path)])
}
