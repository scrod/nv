import NVStorageTestSupport
import Foundation
import Crypto
import Testing
import NVStorageCore
@testable import NVStorageRuntime

@Test(arguments: [false, true], [1, 2, 16, 64])
func repositoryMetadataBatchesMatchExactObservations(portable: Bool, budget: Int) async throws {
    let path = try repositoryDirectory(), directory = RepositoryProtocolDirectory.keys
    let base = path + "/" + directory.relativePath
    try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
    let names = (0..<67).map { "file-\($0)" } + [String(repeating: "é", count: 60), String(repeating: "x", count: 255)]
    for (index, name) in names.enumerated() { try Data(repeating: UInt8(index), count: index + 1).write(to: URL(fileURLWithPath: base + "/" + name)) }
    try FileManager.default.createDirectory(atPath: base + "/directory", withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(atPath: base + "/symlink", withDestinationPath: "file-0")
    try FileManager.default.linkItem(atPath: base + "/file-1", toPath: base + "/hardlink")
    let root = try await RepositoryRootSession.open(directory: path), permit = try await root.permission()
    _ = await root.measureMetadata(true)
    var cursor: RepositoryListingCursor?, seen: Set<String> = [], finished = false, turns = 0
    while !finished {
        let page = try await root.metadata(directory, continuing: cursor, budget: budget, portable: portable, using: permit)
        #expect(page.entries.count <= 64)
        #expect(await root.listingResourceCount() == 1)
        for entry in page.entries {
            let relative = try entry.leaf.relativePath(in: directory)
            #expect(seen.insert(relative).inserted)
            guard case .observed(let observation) = entry.result else { Issue.record("Readable leaf lost its metadata"); continue }
            let exact = try await root.observe(relative, using: permit)
            #expect(observation.kind == exact.kind && observation.byteCount == exact.byteCount)
            #expect(try await root.discoveryHint(observation, using: permit).fingerprint == root.discoveryHint(exact, using: permit).fingerprint)
        }
        cursor = page.cursor; finished = page.finished; turns += 1
        try #require(turns < 512)
    }
    #expect(seen == Set((names + ["directory", "symlink", "hardlink"]).map { baseName in directory.relativePath + "/" + baseName }))
    let work = try #require(await root.measureMetadata(false))
    #expect(work.largestBatch <= 64 && work.largestNameBytes <= 64 * 255 && work.ancestorChecks == 2 * work.batches)
    #expect(work.bodyReads == 0)
    if portable { #expect(work.bulkCalls == 0 && work.statCalls == seen.count) }
    try await root.cancelListing(try #require(cursor), using: permit)
    #expect(await root.listingResourceCount() == 0)
    await #expect(throws: RepositoryRootError.wrongContext) { try await root.metadata(directory, continuing: cursor, budget: budget, using: permit) }
    await root.close()
}

@Test(arguments: [false, true])
func repositoryMetadataRefreshKeepsEOFAndRechecksChangedNames(portable: Bool) async throws {
    let path = try repositoryDirectory(), directory = RepositoryProtocolDirectory.keys
    try deliverFile([1], relative: directory.relativePath + "/retained", to: path)
    let root = try await RepositoryRootSession.open(directory: path), permit = try await root.permission()
    var cursor: RepositoryListingCursor?, entry: RepositoryMetadataEntry?, finished = false
    while !finished {
        let page = try await root.metadata(directory, continuing: cursor, budget: 16, portable: portable, using: permit)
        entry = page.entries.first ?? entry; cursor = page.cursor; finished = page.finished
    }
    let original = try #require(entry)
    guard case .observed(let old) = original.result else { throw StorageError.incomplete }
    try deliverFile([2, 3, 4], relative: directory.relativePath + "/retained", to: path)
    let refreshed = try await root.metadata(directory, continuing: cursor, refreshing: [original.leaf], budget: 1, using: permit)
    #expect(refreshed.finished && refreshed.entries.count == 1)
    guard case .observed(let current) = refreshed.entries[0].result else { throw StorageError.incomplete }
    #expect(current.byteCount == 3)
    #expect(try await root.discoveryHint(old, using: permit).fingerprint != root.discoveryHint(current, using: permit).fingerprint)
    guard case .unavailable(.changed) = try await root.read(old, maximumBytes: 4096, using: permit) else { Issue.record("Old captured contents were reused after replacement"); return }
    guard case .contents(let contents) = try await root.read(current, maximumBytes: 4096, using: permit) else { throw StorageError.incomplete }
    #expect(contents.bytes == [2, 3, 4])
    await #expect(throws: RepositoryRootError.wrongContext) { try await root.metadata(directory, continuing: cursor, budget: 1, using: permit) }
    try await root.cancelListing(refreshed.cursor, using: permit); await root.close()
}

@Test(arguments: [false, true])
func repositoryHintBatchSparseAnswersAndContext(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let other = try await newSession(initial, protection), path = try repositoryDirectory()
    let root = try await RepositoryRootSession.open(directory: path), permit = try await root.permission()
    let otherRoot = try await RepositoryRootSession.open(directory: repositoryDirectory())
    var hints: [RepositoryObservationHint] = []
    for index in 0..<8 {
        let relative = "NV Data/v1/keys/\(index)"
        try deliverFile([UInt8(index)], relative: relative, to: path)
        hints.append(try await root.discoveryHint(root.observe(relative, using: permit), using: permit))
    }
    let ids = try await store.lane.perform { try $0.rows("SELECT object_id FROM accepted_objects ORDER BY object_id").map { try SegmentID(bytes: $0[0].bytes) } }
    try #require(ids.count >= 2)
    let requests = hints + [hints[1]], known = ids[0], second = ids[1]
    let input = hints
    try await store.lane.perform { db in
        for index in 1..<8 {
            let hint = input[index], id = index == 6 ? [UInt8](repeating: 253, count: 32) : (index == 7 ? second.bytes : known.bytes)
            var fp = hint.fingerprint
            if index == 4 { fp[0] ^= 1 }
            var digest = Array(SHA256.hash(data: Array("NV repository observation hint\0v1\0".utf8) + hint.key + fp + id))
            if index == 5 { digest[0] ^= 1 }
            var payload = fp + id + digest
            if index == 3 { payload.removeLast() }
            try db.run("INSERT INTO private_groups VALUES(?,1,?,?)", [.blob(hint.key), .integer(index == 2 ? 2 : 1), .blob(payload)])
        }
        db.work = StorageWork()
    }
    let lookup = try await store.knownDiscoveryHints(requests, permission: permit)
    let answers = try await root.validateDiscoveryHints(lookup, hints: requests, for: store)
    #expect(answers == [.read, .accepted(known), .read, .read, .read, .read, .read, .accepted(second), .accepted(known)])
    let counts = try await store.lane.perform { db in let result = db.work!; db.work = nil; return result }
    #expect(counts.stages.values.reduce(0) { $0 + $1.discoveryHintBatches } == 1)
    #expect(counts.stages.values.reduce(0) { $0 + $1.discoveryHintInputs } == 9)
    #expect(counts.stages.values.reduce(0) { $0 + $1.discoveryHintHits } == 3)
    #expect(counts.stages.values.reduce(0) { $0 + $1.envelopeDecodes + $1.historyReads } == 0)
    #expect(counts.stages.values.flatMap { $0.statementCalls.filter { $0.key.hasPrefix("WITH requested") }.values }.reduce(0, +) == 1)
    #expect(counts.stages.values.reduce(0) { $0 + $1.statements } == 1)
    #expect(counts.stages.values.reduce(0) { $0 + $1.connectionContextChecks + $1.fullScanSteps } == 0)
    #expect(counts.stages.values.reduce(0) { $0 + $1.physicalOwnerChecks } == 4)
    let maximum = Array(repeating: hints[1], count: 64)
    let full = try await store.knownDiscoveryHints(maximum, permission: permit)
    #expect(try await root.validateDiscoveryHints(full, hints: maximum, for: store) == Array(repeating: .accepted(known), count: 64))
    await #expect(throws: StorageError.limit) { try await store.knownDiscoveryHints(maximum + [hints[1]], permission: permit) }
    try await store.lane.perform { $0.work = StorageWork() }
    let empty = try await store.knownDiscoveryHints([], permission: permit)
    #expect(try await root.validateDiscoveryHints(empty, hints: [], for: store).isEmpty)
    #expect(try await store.lane.perform { db in let work = db.work!; db.work = nil; return work.stages.values.reduce(0) { $0 + $1.discoveryHintBatches } } == 0)
    await #expect(throws: RepositoryRootError.wrongContext) { try await root.validateDiscoveryHints(lookup, hints: Array(requests.reversed()), for: store) }
    await #expect(throws: RepositoryRootError.wrongContext) { try await root.validateDiscoveryHints(lookup, hints: requests, for: other) }
    await #expect(throws: RepositoryRootError.wrongContext) { try await otherRoot.validateDiscoveryHints(lookup, hints: requests, for: store) }
    await root.invalidate()
    await #expect(throws: RepositoryRootError.stalePermission) { try await root.validateDiscoveryHints(lookup, hints: requests, for: store) }
    #expect(try await root.revalidate(candidate: path) == .same)
    let currentLookup = try await store.knownDiscoveryHints(requests, permission: root.permission())
    let selection = await store.selection
    try await store.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    await #expect(throws: RepositoryRootError.wrongContext) { try await root.validateDiscoveryHints(currentLookup, hints: requests, for: reopened) }
    try await reopened.quiesce(); try await other.quiesce(); await root.close(); await otherRoot.close()
}

@Test(arguments: [false, true], ["damage", "header", "query"])
func repositoryHintBatchStoreFailuresKeepTheirMeaning(encrypted: Bool, fault: String) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let path = try repositoryDirectory(), root = try await RepositoryRootSession.open(directory: path)
    let birth = try NoteBirth(bytes: .init(repeating: 1, count: 16))
    let saved = try await put("known before store failure", birth: birth, generation: 1, session: store)
    let relative = ImmutableRepositoryLocator.segment(saved.object).relativePath
    try await deliverFile(store.retainedObject(at: saved.object), relative: relative, to: path)
    _ = try await discoverPass(root, into: store)
    let permit = try await root.permission(), hint = try await root.discoveryHint(root.observe(relative, using: permit), using: permit)
    let healthy = try await store.knownDiscoveryHints([hint], permission: permit)
    #expect(try await root.validateDiscoveryHints(healthy, hints: [hint], for: store) == [.accepted(saved.object.segmentID)])
    if fault == "header" {
        // Later disk damage is qualified at the next opening's fixed-context checks.
        let selection = await store.selection
        try await store.lane.perform { try $0.run("UPDATE store_header SET local_store_id=?", [.blob(Array(repeating: 254, count: 16))]) }
        try await store.quiesce()
        await #expect(throws: StorageError.wrongContext) { try await LocalStoreSession.open(selection: selection, protection: protection) }
        await root.close()
        return
    } else if fault == "damage" {
        await #expect(throws: StorageError.integrity) {
            try await store.lane.perform { db in try db.checkingRetainedHistory { throw StorageError.integrity } }
        }
    } else {
        try await store.lane.perform { try $0.exec("CREATE TEMP VIEW private_groups AS SELECT missing_hint_function() AS group_key,1 AS codec,X'00' AS payload") }
    }
    let expected: StorageError = fault == "damage" ? .integrity : .database(1)
    await #expect(throws: expected) { try await store.knownDiscoveryHints([hint], permission: permit) }
    await #expect(throws: expected) { try await discoverPass(root, into: store) }
    if fault == "query" { try await store.lane.perform { try $0.exec("DROP VIEW temp.private_groups") } }
    let selection = await store.selection
    try await store.quiesce(); await root.close()
    if fault == "damage" {
        await #expect(throws: StorageError.integrity) { try await LocalStoreSession.open(selection: selection, protection: protection) }
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
func repositoryHintBatchHeldAnswerRechecksOwners(encrypted: Bool, closeStore: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let path = try repositoryDirectory(), root = try await RepositoryRootSession.open(directory: path)
    let birth = try NoteBirth(bytes: .init(repeating: 1, count: 16))
    let saved = try await put("previously checked", birth: birth, generation: 1, session: store)
    try await deliverFile(store.retainedObject(at: saved.object), relative: ImmutableRepositoryLocator.segment(saved.object).relativePath, to: path)
    _ = try await discoverPass(root, into: store)
    let gate = ImprovementGate()
    let scan = Task { try await root.discover(into: store, opportunity: .foreground, budget: 64,
        hooks: RepositoryDiscoveryHooks(hintsReturned: { await gate.hold() })) }
    await gate.wait()
    if closeStore { try await store.quiesce() } else { await root.invalidate() }
    await gate.release()
    if closeStore { await #expect(throws: StorageError.closed) { try await scan.value } }
    else { await #expect(throws: RepositoryRootError.stalePermission) { try await scan.value } }
    await root.close(); if !closeStore { try await store.quiesce() }
}

@Test(arguments: [false, true], [false, true])
func repositoryBatchBufferedNamesRefreshAcrossMixedBudgets(encrypted: Bool, portable: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    let destination = try await newSession(initial, protection), path = try repositoryDirectory()
    let root = try await RepositoryRootSession.open(directory: path), birth = try NoteBirth(bytes: .init(repeating: 1, count: 16))
    var ids: Set<SegmentID> = []
    for number in 1...8 {
        let receipt = try await put("buffered \(number)", birth: birth, generation: UInt64(number), session: source)
        ids.insert(receipt.object.segmentID)
        try await deliverFile(source.retainedObject(at: receipt.object), relative: ImmutableRepositoryLocator.segment(receipt.object).relativePath, to: path)
    }
    _ = try await discoverPass(root, into: destination)
    var previous: [RepositoryDiscoveryEntry] = [], pending: String?
    for _ in 0..<100 {
        let turn = try await root.discover(into: destination, opportunity: .foreground, budget: portable ? 2 : 1,
            hooks: .init(portableMetadata: portable))
        previous += turn.entries
        if let frame = await root.discoveryState?.frames.last, frame.directory != .segments,
           let name = frame.names.last { pending = try name.relativePath(in: frame.directory); break }
    }
    let relative = try #require(pending)
    let displaced = try ObjectEnvelopeV1.open(Array(Data(contentsOf: URL(fileURLWithPath: path + "/" + relative))),
        collection: initial.descriptor.collection, protection: protection).locator.segmentID
    let replacement = try await put("changed while its raw name was buffered", birth: birth, generation: 9, session: source)
    try await deliverFile(source.retainedObject(at: replacement.object), relative: relative, to: path)
    let budgets = [1, 2, 16, 64, 2, 1], reads = RepositoryReadCounter()
    var results = previous, ended = false
    for round in 0..<100 {
        let turn = try await root.discover(into: destination, opportunity: .backgroundTurn, budget: budgets[round % budgets.count],
            hooks: .init(read: { _ in await reads.add() }, portableMetadata: portable))
        try await root.validate(turn, for: destination)
        #expect(turn.entries.count <= budgets[round % budgets.count])
        #expect(await root.listingResourceCount() <= 2)
        results += turn.entries; ended = turn.passEnded
        if ended { break }
    }
    #expect(ended)
    #expect(await reads.count == 1)
    let observedIDs = results.compactMap { entry -> SegmentID? in
        switch entry.outcome { case .unchangedAccepted(let id): id; case .received(let locator, _, _): locator.segmentID; default: nil }
    }
    #expect(observedIDs.count == 8 && Set(observedIDs) == ids.subtracting([displaced]).union([replacement.object.segmentID]))
    #expect(try await destination.snapshot().notes.first { $0.birth == birth }?.value.body.string == "changed while its raw name was buffered")
    #expect(try await destination.retainedObject(at: replacement.object) == source.retainedObject(at: replacement.object))
    try await source.quiesce(); try await destination.quiesce(); await root.close()
}

@Test(arguments: [false, true])
func repositoryBatchHintWriteFailurePreservesEarlierHandoffs(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    var destination = try await newSession(initial, protection)
    let path = try repositoryDirectory(), root = try await RepositoryRootSession.open(directory: path)
    let birth = try NoteBirth(bytes: .init(repeating: 1, count: 16))
    var expected: [(SegmentLocator, [UInt8])] = []
    for number in 1...6 {
        let receipt = try await put("partial hint failure \(number)", birth: birth, generation: UInt64(number), session: source)
        let bytes = try await source.retainedObject(at: receipt.object)
        expected.append((receipt.object, bytes))
        try deliverFile(bytes, relative: ImmutableRepositoryLocator.segment(receipt.object).relativePath, to: path)
    }
    let lane = await destination.lane, delivered = RepositoryReadCounter()
    let beforeCount = try await lane.perform { try $0.rows("SELECT COUNT(*) FROM objects")[0][0].number }
    await #expect(throws: StorageError.database(1811)) {
        for _ in 0..<100 {
            let turn = try await root.discover(into: destination, opportunity: .foreground, budget: 64,
                hooks: .init(delivered: { _ in
                    await delivered.add()
                    if await delivered.count == 1 {
                        try await lane.perform { db in
                            try db.exec("CREATE TEMP TRIGGER fail_batch_hint BEFORE INSERT ON private_groups WHEN substr(NEW.group_key,1,16)=CAST('repository-seen/' AS BLOB) BEGIN SELECT RAISE(ABORT,'batch hint failure'); END")
                        }
                    }
                }))
            if turn.passEnded { Issue.record("Required hint write failure was bypassed"); break }
        }
    }
    #expect(await delivered.count == 1)
    let retained = try await lane.perform { try $0.rows("SELECT object_id,encoded FROM objects ORDER BY object_id") }
    #expect(Int64(retained.count) >= beforeCount + 2)
    await #expect(throws: StorageError.database(1811)) { try await discoverPass(root, into: destination) }
    #expect(try await lane.perform { try $0.rows("SELECT object_id,encoded FROM objects ORDER BY object_id") } == retained)
    let selection = await destination.selection
    try await destination.quiesce()
    destination = try await LocalStoreSession.open(selection: selection, protection: protection)
    _ = try await discoverPass(root, into: destination)
    for (locator, bytes) in expected { #expect(try await destination.retainedObject(at: locator) == bytes) }
    #expect(try await destination.snapshot().notes.first { $0.birth == birth }?.value.body.string == "partial hint failure 6")
    let membership = try await destination.lane.perform { try $0.rows("SELECT object_id FROM accepted_objects ORDER BY object_id") }
    #expect(try await membership == source.lane.perform { try $0.rows("SELECT object_id FROM accepted_objects ORDER BY object_id") })
    _ = try await discoverPass(root, into: destination)
    #expect(try await destination.lane.perform { try $0.rows("SELECT object_id FROM accepted_objects ORDER BY object_id") } == membership)
    try await destination.quiesce(); try await source.quiesce(); await root.close()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func repositoryHintHitChangedAfterLookupRemainsDiscoverable(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    let receiver = try await newSession(initial, protection), path = try repositoryDirectory()
    let root = try await RepositoryRootSession.open(directory: path)
    let birth = try NoteBirth(bytes: .init(repeating: 1, count: 16))
    let first = try await put("observed generation", birth: birth, generation: 1, session: source)
    let firstBytes = try await source.retainedObject(at: first.object)
    let relative = ImmutableRepositoryLocator.segment(first.object).relativePath
    try deliverFile(firstBytes, relative: relative, to: path)
    _ = try await discoverPass(root, into: receiver)
    let newer = try await put("changed after matching lookup", birth: birth, generation: 2, session: source)
    let newerBytes = try await source.retainedObject(at: newer.object), gate = ImprovementGate()
    let held = Task { try await root.discover(into: receiver, opportunity: .foreground, budget: 64,
        hooks: .init(hintsReturned: { await gate.hold() })) }
    await gate.wait()
    try deliverFile(newerBytes, relative: relative, to: path)
    await gate.release()
    let observed = try await held.value
    #expect(observed.entries.contains { if case .unchangedAccepted(let id) = $0.outcome { id == first.object.segmentID } else { false } })
    #expect(try await receiver.snapshot().notes.first { $0.birth == birth }?.value.body.string == "observed generation")
    let reads = RepositoryReadCounter()
    var next: [RepositoryDiscoveryEntry] = [], finished = false
    for _ in 0..<100 {
        let turn = try await root.discover(into: receiver, opportunity: .backgroundTurn, budget: 16,
            hooks: .init(read: { _ in await reads.add() }))
        try await root.validate(turn, for: receiver)
        next += turn.entries
        if turn.passEnded { finished = true; break }
    }
    #expect(finished)
    #expect(next.contains { if case .received(let locator, _, _) = $0.outcome { locator == newer.object } else { false } })
    #expect(await reads.count == 1)
    #expect(try await receiver.snapshot().notes.first { $0.birth == birth }?.value.body.string == "changed after matching lookup")
    #expect(try await receiver.retainedObject(at: first.object) == firstBytes)
    #expect(try await receiver.retainedObject(at: newer.object) == newerBytes)
    try await receiver.quiesce(); try await source.quiesce(); await root.close()
}
