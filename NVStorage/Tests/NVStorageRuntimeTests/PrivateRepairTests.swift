import NVStorageTestSupport
import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

private actor RepairReads {
    private(set) var counts: [[UInt8]: Int] = [:]
    private(set) var largestBytes = 0
    func record(_ id: [UInt8], _ bytes: Int) {
        counts[id, default: 0] += 1; largestBytes = max(largestBytes, bytes)
    }
}

@Test(.timeLimit(.minutes(10)), arguments: [false, true], [64, 256, 1024])
func privateRepairGrowthReadsExactObjectsIndividually(encrypted: Bool, actions: Int) async throws {
    let fixture = try await GrowthHistoryFixtures.shared.fixture(encrypted: encrypted, actions: actions)
    let source = try await fixture.openSender(), original = await source.selection
    let start = ContinuousClock.now
    let evidence = try await source.preserveForRepair(to: privateTempPath())
    let sourceImage = try repairSourceImage(original)
    let salvageTime = start.duration(to: .now), reads = RepairReads(), buildStart = ContinuousClock.now
    let replacement = try await LocalStoreSession.buildVerifiedReplacement(to: privateTempPath(), primary: evidence,
        protection: fixture.protection, work: .init(read: { await reads.record($0, $1) }))
    let buildTime = buildStart.duration(to: .now)
    try await replacement.close()
    let reopened = try await LocalStoreSession.open(selection: replacement.selection, protection: fixture.protection)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["E\(actions)", "untouched"])
    let expected = fixture.initial.objects.map { ($0.key.segmentID.bytes, $0.value) }
        + fixture.history.map { ($0.locator.segmentID.bytes, $0.bytes) }
        + [(fixture.initial.descriptor.descriptorID, fixture.initial.descriptor.encodedBytes)]
    let actual = try await reopened.lane.perform { try $0.rows("SELECT object_id,length(encoded) FROM objects ORDER BY object_id") }
    #expect(try actual.map { try $0[0].bytes } == expected.map(\.0).sorted { $0.lexicographicallyPrecedes($1) })
    for (id, bytes) in expected {
        let stored = try await reopened.lane.perform { try $0.rows("SELECT encoded FROM objects WHERE object_id=?", [.blob(id)]) }
        #expect(stored == [[.blob(bytes)]])
    }
    let counts = await reads.counts, maximum = await reads.largestBytes
    #expect(counts.count == expected.count)
    #expect(counts[fixture.initial.descriptor.descriptorID] == 1)
    #expect(counts.filter { $0.key != fixture.initial.descriptor.descriptorID }.values.allSatisfy { $0 == 2 })
    #expect(maximum == expected.map { $0.1.count }.max())
    #expect(try repairSourceImage(original) == sourceImage)
    print("PRIVATE-REPAIR-GROWTH encrypted=\(encrypted) actions=\(actions) objects=\(expected.count) largestRead=\(maximum) salvage=\(salvageTime) reconstruction=\(buildTime)")
    try await reopened.quiesce()
}

private enum RepairWorkingChange: CaseIterable, Sendable {
    case intact, body, metadata, missing, context, afterFirstRead
}

@Test(arguments: [false, true], RepairWorkingChange.allCases)
private func privateRepairRechecksWorkingCopy(encrypted: Bool, change: RepairWorkingChange) async throws {
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: .init(repeating: 1, count: 16))
    let edit = try await put("retained exact bytes", birth: birth, generation: 1, session: source)
    let row = try #require(await source.lane.perform { try $0.rows("SELECT object_id,kind,writer_epoch,sequence,encoded FROM objects WHERE object_id=?", [.blob(edit.object.segmentID.bytes)]).first })
    let evidence = try await source.preserveForRepair(to: privateTempPath()), image = try repairSourceImage(evidence.selection)
    @Sendable func alter(restoring: Bool) async throws {
        let lane = DatabaseLane()
        try await lane.open(directory: evidence.workingDirectory, create: false,
            key: PrivateDatabaseKeyV1.derive(collection: initial.descriptor.collection, protection: protection))
        do {
            try await lane.perform { db in
                try db.exec("PRAGMA foreign_keys=OFF; DROP TRIGGER IF EXISTS objects_no_update; DROP TRIGGER IF EXISTS objects_no_delete")
                if restoring {
                    try db.run("UPDATE store_header SET local_store_id=?", [.blob(evidence.selection.store.bytes)])
                    try db.run("DELETE FROM objects WHERE object_id=?", [row[0]])
                    try db.run("INSERT INTO objects VALUES(?,?,?,?,?)", row)
                } else {
                    switch change {
                    case .intact: break
                    case .body, .afterFirstRead:
                        var bytes = try row[4].bytes; bytes[bytes.count - 1] ^= 1
                        try db.run("UPDATE objects SET encoded=? WHERE object_id=?", [.blob(bytes), row[0]])
                    case .metadata: try db.run("UPDATE objects SET kind=3 WHERE object_id=?", [row[0]])
                    case .missing: try db.run("DELETE FROM objects WHERE object_id=?", [row[0]])
                    case .context: try db.run("UPDATE store_header SET local_store_id=?", [.blob(.init(repeating: 98, count: 16))])
                    }
                }
            }
            await lane.close()
        } catch { await lane.close(); throw error }
    }
    let reads = RepairReads()
    let work = PrivateRepairWork(prepared: {
        if change != .afterFirstRead { try await alter(restoring: false) }
    }, read: { id, count in
        await reads.record(id, count)
        if change == .afterFirstRead, id == edit.object.segmentID.bytes, await reads.counts[id] == 1 {
            try await alter(restoring: false)
        }
    })
    if change == .intact {
        let replacement = try await LocalStoreSession.buildVerifiedReplacement(to: privateTempPath(), primary: evidence,
            protection: protection, work: work)
        try await replacement.close()
    } else {
        let expected: StorageError = change == .missing ? .incomplete : change == .context ? .wrongContext : .integrity
        await #expect(throws: expected) {
            try await LocalStoreSession.buildVerifiedReplacement(to: privateTempPath(), primary: evidence, protection: protection, work: work)
        }
        try await alter(restoring: true)
        let retry = try await LocalStoreSession.buildVerifiedReplacement(to: privateTempPath(), primary: evidence, protection: protection)
        try await retry.close()
        let reopened = try await LocalStoreSession.open(selection: retry.selection, protection: protection)
        #expect(try await reopened.retainedObject(at: edit.object) == row[4].bytes)
        #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["retained exact bytes", "untouched"])
        try await reopened.quiesce()
    }
    #expect(try repairSourceImage(evidence.selection) == image)
}

private enum RepairHistoryPair: CaseIterable, Sendable {
    case repackaged, independent, conflictingAction
}

/// Each source accepts its own complete history before repair combines their evidence.
@Test(arguments: [false, true], RepairHistoryPair.allCases)
private func repairUnionChecksLogicalIdentity(encrypted: Bool, pair: RepairHistoryPair) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let left = try await newSession(initial, protection), right = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let original = try await left.snapshot(), prior = try #require(original.notes.first { $0.birth == birth })
    let firstID = try ActionID(bytes: Array(repeating: 71, count: 16))
    func envelope(side: UInt8) throws -> [UInt8] {
        let actionID = try pair == .independent && side == 2 ? ActionID(bytes: Array(repeating: 72, count: 16)) : firstID
        let body = pair == .repackaged || side == 1 ? "Left" : "Right"
        let op = try IdentifiedOperation(nonce: OperationNonce(bytes: Array(repeating: 73, count: 16)),
            effect: .put(action: actionID, birth: birth, value: testValue(body)),
            causalParents: CausalParentSet(original.context.operations.map(\.id)),
            notePredecessors: NotePredecessorSet([prior.revision.id]))
        let record = try OperationRecordV1(operation: op, causalReferences: original.context.operations.map(\.reference),
            noteReferences: [prior.revision.reference], earlierOperations: [])
        let action = try ActionRecordV1(id: actionID, origin: ActionOriginID(bytes: Array(repeating: 74, count: 16)),
            previousOrigin: nil, scope: .note(birth), scopeParents: prior.scopeFrontier.map(\.reference), kind: .savedEdit,
            members: [OperationIndex(0)], affected: [.init(birth: birth, before: .value(prior.revision.reference),
                after: .value(.earlierLocal(index: OperationIndex(0))))], operations: [op], earlierActions: [])
        let dependencies = Set(original.context.operations.map(\.locator) + [prior.revision.locator] + prior.scopeFrontier.map(\.locator))
        let payload = try ChangesPayloadV1(dependencies: DependencyLocatorTable(Array(dependencies)), operations: [record], actions: [action])
        return try ObjectEnvelopeV1.seal(payload: payload.encodedV1(), kind: .changes, collection: initial.descriptor.collection,
            writer: WriterEpoch(bytes: Array(repeating: side, count: 16)), sequence: 0, protection: protection)
    }
    let leftBytes = try envelope(side: 1), rightBytes = try envelope(side: 2)
    let leftLocator = try ObjectEnvelopeV1.open(leftBytes, collection: initial.descriptor.collection, protection: protection).locator
    let rightLocator = try ObjectEnvelopeV1.open(rightBytes, collection: initial.descriptor.collection, protection: protection).locator
    #expect(leftLocator != rightLocator)
    _ = try await left.receive(leftBytes); _ = try await right.receive(rightBytes)
    #expect(try await left.snapshot().notes.first { $0.birth == birth }?.value.body.string == "Left")
    #expect(try await right.snapshot().notes.first { $0.birth == birth }?.value.body.string == (pair == .repackaged ? "Left" : "Right"))
    let primary = try await left.preserveForRepair(to: privateTempPath())
    let complement = try await right.preserveForRepair(to: privateTempPath())
    let leftImage = try repairSourceImage(primary.selection), rightImage = try repairSourceImage(complement.selection)
    for reversed in [false, true] {
        let first = reversed ? complement : primary, second = reversed ? primary : complement
        if pair == .conflictingAction {
            await #expect(throws: OrdinaryHistoryError.conflictingClaim) {
                try await LocalStoreSession.buildVerifiedReplacement(to: privateTempPath(), primary: first,
                    complementary: [second], protection: protection)
            }
        } else {
            let result = try await LocalStoreSession.buildVerifiedReplacement(to: privateTempPath(), primary: first,
                complementary: [second], protection: protection)
            try await result.close()
            let opened = try await LocalStoreSession.open(selection: result.selection, protection: protection)
            #expect(try await opened.retainedObject(at: leftLocator) == leftBytes)
            #expect(try await opened.retainedObject(at: rightLocator) == rightBytes)
            let entries = try await opened.history(for: .note(birth)).entries
            #expect(entries.count == (pair == .repackaged ? 2 : 3))
            let expected: Set<String> = pair == .repackaged ? ["A", "Left"] : ["A", "Left", "Right"]
            var bodies: Set<String> = []
            for entry in entries {
                if case .value(let operation) = try await opened.preview(entry).state,
                   let value = operation.effect.noteValue { bodies.insert(value.body.string) }
            }
            #expect(bodies == expected)
            let conflicts = try await opened.conflicts(for: birth)
            #expect(conflicts.alternatives.count == (pair == .repackaged ? 0 : 1))
            #expect(try await opened.snapshot().notes.first { $0.birth != birth }?.value.body.string == "untouched")
            try await opened.quiesce()
        }
        #expect(try repairSourceImage(primary.selection) == leftImage)
        #expect(try repairSourceImage(complement.selection) == rightImage)
    }
}

@Test(arguments: [false, true], [false, true])
func repairUnionPreservesOrRefusesPendingGroups(encrypted: Bool, conflicting: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let left = try await newSession(initial, protection), right = try await newSession(initial, protection)
    let leftItem = try PendingItemID(bytes: uuidBytes())
    let rightItem = try conflicting ? leftItem : PendingItemID(bytes: uuidBytes())
    let leftFrozen = try await pendingInput(left, body: "left frozen"), rightFrozen = try await pendingInput(right, body: "right frozen")
    try await left.retainPendingSnapshot(leftFrozen, basedOn: left.pendingItem(leftItem))
    try await right.retainPendingSnapshot(rightFrozen, basedOn: right.pendingItem(rightItem))
    let leftAction = try await left.preparePendingImport(basedOn: left.pendingItem(leftItem), automatic: false)
    let rightAction = try await right.preparePendingImport(basedOn: right.pendingItem(rightItem), automatic: false)
    let leftLatest = try await pendingInput(left, body: "left latest"), rightLatest = try await pendingInput(right, body: "right latest")
    try await left.retainPendingSnapshot(leftLatest, basedOn: left.pendingItem(leftItem))
    try await right.retainPendingSnapshot(rightLatest, basedOn: right.pendingItem(rightItem))
    let primary = try await left.preserveForRepair(to: privateTempPath())
    let complement = try await right.preserveForRepair(to: privateTempPath())
    let leftImage = try repairSourceImage(primary.selection), rightImage = try repairSourceImage(complement.selection)
    for reversed in [false, true] {
        let first = reversed ? complement : primary, second = reversed ? primary : complement
        if conflicting {
            await #expect(throws: StorageError.incomplete) {
                try await LocalStoreSession.buildVerifiedReplacement(to: privateTempPath(), primary: first,
                    complementary: [second], protection: protection)
            }
        } else {
            let result = try await LocalStoreSession.buildVerifiedReplacement(to: privateTempPath(), primary: first,
                complementary: [second], protection: protection)
            try await result.close()
            let opened = try await LocalStoreSession.open(selection: result.selection, protection: protection)
            for payload in [leftFrozen, leftLatest, rightFrozen, rightLatest] {
                #expect(try await opened.retainedPendingSnapshot(payload.id) == payload)
            }
            for (item, latest, action) in [(leftItem, leftLatest, leftAction), (rightItem, rightLatest, rightAction)] {
                #expect(try await opened.pendingItem(item).latest == latest.id)
                let recoveries = try await opened.pendingRecovery(item)
                #expect(recoveries.count == 1)
                guard case .review(let reservation) = try #require(recoveries.first) else {
                    Issue.record("Uncommitted retained input acquired committed consent"); continue
                }
                #expect(reservation == action.reservation)
            }
            #expect(try await opened.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
            try await opened.quiesce()
        }
        #expect(try repairSourceImage(primary.selection) == leftImage)
        #expect(try repairSourceImage(complement.selection) == rightImage)
    }
}

@Test(arguments: [false, true])
func repairUnionKeepsEarlierRepairCaptureScopes(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let source = try await newSession(initial, protection), primary = try await newSession(initial, protection)
    let item = try PendingItemID(bytes: uuidBytes()), frozen = try await pendingInput(source, body: "original frozen input")
    try await source.retainPendingSnapshot(frozen, basedOn: source.pendingItem(item))
    let action = try await source.preparePendingImport(basedOn: source.pendingItem(item), automatic: false)
    let latest = try await pendingInput(source, body: "original latest input")
    try await source.retainPendingSnapshot(latest, basedOn: source.pendingItem(item))
    let firstEvidence = try await source.preserveForRepair(to: privateTempPath())
    let firstRepair = try await LocalStoreSession.buildVerifiedReplacement(to: privateTempPath(), primary: firstEvidence, protection: protection)
    try await firstRepair.close()
    let onceRepaired = try await LocalStoreSession.open(selection: firstRepair.selection, protection: protection)
    #expect(try await onceRepaired.retainedPendingSnapshot(frozen.id) == frozen)
    let left = try await primary.preserveForRepair(to: privateTempPath())
    let right = try await onceRepaired.preserveForRepair(to: privateTempPath())
    let leftImage = try repairSourceImage(left.selection), rightImage = try repairSourceImage(right.selection)
    for reversed in [false, true] {
        let first = reversed ? right : left, second = reversed ? left : right
        let rebuilt = try? await LocalStoreSession.buildVerifiedReplacement(to: privateTempPath(), primary: first,
            complementary: [second], protection: protection)
        #expect(rebuilt != nil, "All retained capture scopes survive complementary repair")
        #expect(try repairSourceImage(left.selection) == leftImage)
        #expect(try repairSourceImage(right.selection) == rightImage)
        guard let result = rebuilt else { continue }
        try await result.close()
        let opened = try await LocalStoreSession.open(selection: result.selection, protection: protection)
        #expect(try await opened.retainedPendingSnapshot(frozen.id) == frozen)
        #expect(try await opened.retainedPendingSnapshot(latest.id) == latest)
        #expect(try await opened.pendingItem(item).latest == latest.id)
        let recoveries = try await opened.pendingRecovery(item)
        #expect(recoveries.count == 1)
        guard case .review(let reservation) = try #require(recoveries.first) else {
            Issue.record("Retained review acquired committed consent during second repair"); return
        }
        #expect(reservation == action.reservation)
        #expect(try await opened.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
        try await opened.quiesce()
        #expect(try repairSourceImage(left.selection) == leftImage)
        #expect(try repairSourceImage(right.selection) == rightImage)
    }
}

private enum RepairScopeFault: CaseIterable, Sendable { case valid, foreignCollection, missingDescriptor, unsupportedCodec }

@Test(arguments: [false, true], RepairScopeFault.allCases)
private func repairUnionValidatesInheritedCaptureScope(encrypted: Bool, fault: RepairScopeFault) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let source = try await newSession(initial, protection), primary = try await newSession(initial, protection)
    let scopeStore = try LocalStoreID(bytes: Array(repeating: 86, count: 16))
    let key = Array("repair-source/".utf8) + scopeStore.bytes
    let collection = fault == .foreignCollection ? Array(repeating: UInt8(87), count: 16) : initial.descriptor.collection.bytes
    let descriptor = fault == .missingDescriptor ? Array(repeating: UInt8(88), count: 32) : initial.descriptor.descriptorID
    let codec: Int64 = fault == .unsupportedCodec ? 2 : 1
    let row: [SQLValue] = [.blob(key), .integer(1), .integer(codec), .blob(collection + descriptor)]
    try await source.lane.perform { try $0.run("INSERT INTO private_groups VALUES(?,?,?,?)", row) }
    let left = try await primary.preserveForRepair(to: privateTempPath())
    let right = try await source.preserveForRepair(to: privateTempPath())
    let leftImage = try repairSourceImage(left.selection), rightImage = try repairSourceImage(right.selection)
    if fault == .valid {
        let result = try await LocalStoreSession.buildVerifiedReplacement(to: privateTempPath(), primary: left,
            complementary: [right], protection: protection)
        try await result.close()
        let opened = try await LocalStoreSession.open(selection: result.selection, protection: protection)
        let retained = try await opened.lane.perform {
            try $0.rows("SELECT group_key,generation,codec,payload FROM private_groups WHERE group_key=?", [.blob(key)])
        }
        #expect(retained == [row])
        try await opened.quiesce()
    } else {
        let expected: StorageError = switch fault {
        case .foreignCollection: .integrity
        case .missingDescriptor: .incomplete
        case .unsupportedCodec: .unsupported
        case .valid: .integrity
        }
        await #expect(throws: expected) {
            try await LocalStoreSession.buildVerifiedReplacement(to: privateTempPath(), primary: left,
                complementary: [right], protection: protection)
        }
    }
    #expect(try repairSourceImage(left.selection) == leftImage)
    #expect(try repairSourceImage(right.selection) == rightImage)
}

/// Compares original database, journal and descriptor bytes after each repair attempt.
private func repairSourceImage(_ selection: LocalStoreSelection) throws -> [String: Data] {
    let root = URL(fileURLWithPath: selection.directory)
    return try Dictionary(uniqueKeysWithValues: FileManager.default.subpathsOfDirectory(atPath: selection.directory).map { path in
        let url = root.appendingPathComponent(path)
        let type = try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        switch type {
        case .typeRegular: return (path, try Data(contentsOf: url))
        case .typeDirectory: return (path + "/", Data())
        default: throw StorageError.integrity
        }
    })
}

@Test(arguments: [false, true])
func complementaryRepairPreservesUnpublishedHistoryAndPrivateInputs(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    let peer = try await newSession(initial, protection)
    let aBirth = try NoteBirth(bytes: Array(repeating: 1, count: 16)), bBirth = try NoteBirth(bytes: Array(repeating: 2, count: 16))
    let e = try await put("shared E", birth: aBirth, generation: 1, session: source)
    _ = try await peer.receive(source.retainedObject(at: e.object))
    let l = try await put("unpublished L", birth: bBirth, generation: 2, session: source)
    let r = try await put("peer R", birth: aBirth, generation: 1, session: peer)
    let settings = try CollectionSettingsV1([.secureTextEntry(true), .confirmFileDeletion(false)])
    try await source.saveCollectionSettings(settings, basedOn: source.collectionSettings())
    let item = try PendingItemID(bytes: uuidBytes()), frozen = try await pendingInput(source, body: "frozen A")
    try await source.retainPendingSnapshot(frozen, basedOn: source.pendingItem(item))
    let prepared = try await source.preparePendingImport(basedOn: source.pendingItem(item), automatic: false)
    let latest = try await pendingInput(source, body: "latest B")
    try await source.retainPendingSnapshot(latest, basedOn: source.pendingItem(item))
    let eBytes = try await source.retainedObject(at: e.object)
    try await source.lane.perform { db in
        try db.exec("DROP TRIGGER objects_no_update")
        try db.run("UPDATE objects SET encoded=? WHERE object_id=?", [.blob([0]), .blob(e.object.segmentID.bytes)])
    }
    let old = await source.selection
    let original = try Data(contentsOf: URL(fileURLWithPath: old.directory).appendingPathComponent("Collection.sqlite"))
    let left = try await source.preserveForRepair(to: privateTempPath())
    #expect(left.unavailableCommittedObjects.contains(e.object.segmentID.bytes))
    let right = try await peer.preserveForRepair(to: privateTempPath())
    await #expect(throws: StorageError.incomplete) {
        try await LocalStoreSession.buildVerifiedReplacement(to: privateTempPath(), primary: left, protection: protection)
    }
    let repaired = try await LocalStoreSession.buildVerifiedReplacement(to: privateTempPath(), primary: left, complementary: [right], protection: protection)
    #expect(repaired.selection.store != old.store)
    try await repaired.close()
    let opened = try await LocalStoreSession.open(selection: repaired.selection, protection: protection)
    #expect(try await opened.snapshot().notes.map(\.value.body.string).sorted() == ["peer R", "unpublished L"])
    #expect(try await opened.retainedObject(at: e.object) == eBytes)
    #expect(try await !opened.retainedObject(at: l.object).isEmpty)
    #expect(try await !opened.retainedObject(at: r.object).isEmpty)
    #expect(try await opened.collectionSettings().value == settings)
    #expect(try await opened.pendingItem(item).latest == latest.id)
    #expect(try await opened.retainedPendingSnapshot(frozen.id) == frozen)
    #expect(try await opened.retainedPendingSnapshot(latest.id) == latest)
    let recoveredReservations = try await opened.pendingRecovery(item)
    #expect(recoveredReservations.count == 1)
    guard case .review(let reservation) = try #require(recoveredReservations.first) else { Issue.record("unused reservation gained consent"); return }
    #expect(reservation == prepared.reservation)
    let history = try await opened.history(for: .note(aBirth))
    #expect(history.entries.count == 3)
    try await opened.quiesce()
    #expect(try Data(contentsOf: URL(fileURLWithPath: old.directory).appendingPathComponent("Collection.sqlite")) == original)
}

@Test(arguments: [false, true])
func repairedVerificationUsesMembershipRatherThanCopiedSequence(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    _ = try await put("E", birth: birth, generation: 1, session: source)
    _ = try await put("F", birth: birth, generation: 2, session: source)
    let selection = await source.selection
    let requestKey = VerificationRecord.prefix + uuidBytes()
    let request = Array("NVVRFY1\n".utf8) + selection.store.bytes + selection.descriptor.collection.bytes
        + selection.descriptor.descriptorID + VerificationRecipe.history(3).encoded()
    try await source.lane.perform { try $0.run("INSERT INTO private_groups VALUES(?,1,1,?)", [.blob(requestKey), .blob(request)]) }
    let evidence = try await source.preserveForRepair(to: privateTempPath())
    let repaired = try await LocalStoreSession.buildVerifiedReplacement(to: privateTempPath(), primary: evidence, protection: protection)
    try await repaired.close()
    let opened = try await LocalStoreSession.open(selection: repaired.selection, protection: protection)
    #expect(try await opened.snapshot().notes.map(\.value.body.string).sorted() == ["F", "untouched"])
    #expect(try await opened.lane.perform { try $0.rows("SELECT 1 FROM private_groups WHERE group_key=?", [.blob(requestKey)]) }.isEmpty)
    let membership = try await opened.lane.perform { try $0.rows("SELECT object_id FROM accepted_objects ORDER BY object_id") }
    #expect(membership.count == initial.objects.count + 3)
    try await opened.quiesce()
}

@Test(arguments: [false, true])
func encryptedPageSalvageKeepsIndependentCommittedRows(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    let layout: Int64, pageSize: Int64
    do {
        layout = try await source.lane.perform { db in
            let rows = try db.rows("PRAGMA page_count")
            guard case .integer(let n) = rows[0][0] else { Issue.record("page_count returned \(rows)"); throw StorageError.integrity }
            return n
        }
        pageSize = try await source.lane.perform { db in
            let rows = try db.rows("PRAGMA cipher_page_size")
            guard case .text(let text) = rows[0][0], let n = Int64(text) else { Issue.record("cipher_page_size returned \(rows)"); throw StorageError.integrity }
            return n
        }
    } catch { Issue.record("healthy cipher page layout: \(error)"); throw error }
    var entropy: UInt64 = 0x123456789abcdef, bytes: [UInt8] = []
    for _ in 0..<262144 {
        entropy ^= entropy << 13; entropy ^= entropy >> 7; entropy ^= entropy << 17
        bytes.append(33 + UInt8(entropy % 90))
    }
    let body = String(decoding: bytes, as: UTF8.self)
    let saved: AcceptedHistoryReceipt
    do { saved = try await put(body, birth: NoteBirth(bytes: Array(repeating: 1, count: 16)), generation: 1, session: source) }
    catch { Issue.record("saving the healthy large note: \(error)"); throw error }
    let envelope: [UInt8]
    do { envelope = try await source.retainedObject(at: saved.object) }
    catch { Issue.record("reading the healthy large envelope: \(error)"); throw error }
    let selection = await source.selection
    try #require(envelope.count > Int(pageSize * 16))
    try await source.lane.perform { try $0.run("PRAGMA wal_checkpoint(TRUNCATE)") }
    do { try await source.quiesce() }
    catch { Issue.record("closing the healthy large store: \(error)"); throw error }
    let damaged = privateTempPath()
    try FileManager.default.copyItem(atPath: selection.directory, toPath: damaged)
    let databasePath = damaged + "/Collection.sqlite"
    let handle = try FileHandle(forUpdating: URL(fileURLWithPath: databasePath))
    let offset = UInt64((layout + 3) * pageSize + 200)
    try handle.seek(toOffset: offset)
    let original = try #require(handle.read(upToCount: 1)?.first)
    try handle.seek(toOffset: offset); try handle.write(contentsOf: Data([original ^ 0xff])); try handle.synchronize(); try handle.close()
    let preserved = try Data(contentsOf: URL(fileURLWithPath: databasePath))
    let claim = LocalStoreSelection(directory: damaged, store: selection.store, descriptor: selection.descriptor)
    let evidence: PrivateRepairEvidence
    do { evidence = try await LocalStoreSession.salvagePrivateStore(selection: claim, protection: protection, workingDirectory: privateTempPath()) }
    catch { Issue.record("encrypted-page working-copy salvage: \(error)"); throw error }
    try #require(evidence.unavailableCommittedObjects == [saved.object.segmentID.bytes])
    await #expect(throws: StorageError.incomplete) {
        try await LocalStoreSession.buildVerifiedReplacement(to: privateTempPath(), primary: evidence, protection: protection)
    }
    let peer = try await newSession(initial, protection)
    _ = try await peer.receive(envelope)
    let companion = try await peer.preserveForRepair(to: privateTempPath())
    let repaired: VerifiedReplacement
    do { repaired = try await LocalStoreSession.buildVerifiedReplacement(to: privateTempPath(), primary: evidence,
        complementary: [companion], protection: protection) }
    catch { Issue.record("encrypted-page complementary reconstruction: \(error)"); throw error }
    try await repaired.close()
    let reopened = try await LocalStoreSession.open(selection: repaired.selection, protection: protection)
    #expect(try await reopened.snapshot().notes.contains { $0.value.body.string == body })
    #expect(try await reopened.retainedObject(at: saved.object) == envelope)
    try await reopened.quiesce()
    #expect(try Data(contentsOf: URL(fileURLWithPath: databasePath)) == preserved)
}

@Test(arguments: [false, true])
func partialPrivateSalvageContinuesIndependentReads(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    _ = try await put("retained history", birth: NoteBirth(bytes: Array(repeating: 1, count: 16)), generation: 1, session: source)
    let selection = await source.selection
    let count = try await source.lane.perform { try $0.rows("SELECT COUNT(*) FROM accepted_objects")[0][0].number }
    try await source.lane.perform { try $0.exec("DROP TABLE pending_reservations") }
    try await source.closeForPreservedRepair()
    let work = privateTempPath()
    guard case .partial(let result) = try await LocalStoreSession.salvagePrivateStoreDiagnosing(
        selection: selection, protection: protection, workingDirectory: work) else {
        Issue.record("missing required private table yielded complete repair evidence"); return
    }
    #expect(result.componentFailures["pending_reservations"] == .database(1))
    #expect(result.knownCommittedObjectCount == Int(count) && result.readableObjectCount == Int(count))
    #expect(result.workingDirectory == work)
    #expect(FileManager.default.fileExists(atPath: selection.directory + "/Collection.sqlite"))
}

@Test(arguments: [false, true])
func repairPreservesReceiveClassesAndWakesComplementedDependencies(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), writer = try await newSession(initial, protection)
    let left = try await newSession(initial, protection), right = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let e = try await put("parent E", birth: birth, generation: 1, session: writer)
    let f = try await put("child F", birth: birth, generation: 2, session: writer)
    let eBytes = try await writer.retainedObject(at: e.object), fBytes = try await writer.retainedObject(at: f.object)
    guard case .waiting = try await left.receive(fBytes) else { Issue.record("child did not park"); return }
    _ = try await right.receive(eBytes)
    let rejected = try ObjectEnvelopeV1.seal(payload: Array("NVCHG1\r\n".utf8) + [0, 2], kind: .changes,
        collection: initial.descriptor.collection, writer: WriterEpoch(bytes: Array(repeating: 77, count: 16)), sequence: 0, protection: protection)
    let rejectedID = try ObjectEnvelopeV1.open(rejected, collection: initial.descriptor.collection, protection: protection).locator
    await #expect(throws: CanonicalEncodingError.unsupportedFormat) { try await left.receive(rejected) }
    let orphanWriter = try await newSession(initial, protection)
    let o = try await put("uncommitted orphan O", birth: birth, generation: 1, session: orphanWriter)
    let orphan = try await orphanWriter.retainedObject(at: o.object)
    let orphanOpened = try ObjectEnvelopeV1.open(orphan, collection: initial.descriptor.collection, protection: protection)
    try await right.lane.perform { try $0.retainCandidate(orphan, opened: orphanOpened, ready: false) }
    let primary = try await left.preserveForRepair(to: privateTempPath())
    let complement = try await right.preserveForRepair(to: privateTempPath())
    let replacement = try await LocalStoreSession.buildVerifiedReplacement(to: privateTempPath(), primary: primary,
        complementary: [complement], protection: protection)
    try await replacement.close()
    let reopened = try await LocalStoreSession.open(selection: replacement.selection, protection: protection)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["child F", "untouched"])
    let states = try await reopened.lane.perform { db in
        (try db.rows("SELECT encoded FROM objects WHERE object_id=?", [.blob(o.object.segmentID.bytes)]),
         try db.rows("SELECT 1 FROM accepted_objects WHERE object_id=?", [.blob(o.object.segmentID.bytes)]),
         try db.rows("SELECT reason FROM rejected_objects WHERE object_id=?", [.blob(rejectedID.segmentID.bytes)]),
         try db.rows("SELECT 1 FROM object_waits WHERE child=?", [.blob(f.object.segmentID.bytes)]))
    }
    #expect(states.0 == [[.blob(orphan)]] && states.1.isEmpty)
    #expect(states.2 == [[.integer(ReceiveRejection.unsupportedFormat.rawValue)]] && states.3.isEmpty)
    #expect(try await reopened.retainedObject(at: f.object) == fBytes)
    _ = try await put("after repair", birth: birth, generation: 3, session: reopened)
    try await reopened.quiesce(); try await writer.quiesce(); try await orphanWriter.quiesce()
}

@Test(arguments: [false, true])
func complementaryRepairKeepsConflictRestoreAndCausalRedo(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let left = try await newSession(initial, protection), right = try await newSession(initial, protection)
    let a = try NoteBirth(bytes: Array(repeating: 1, count: 16)), b = try NoteBirth(bytes: Array(repeating: 2, count: 16))
    let restoredBirth = try NoteBirth(bytes: Array(repeating: 3, count: 16))
    let l = try await put("Left", birth: a, generation: 1, session: left)
    let r = try await put("Right", birth: a, generation: 1, session: right)
    let lID = try #require(try await left.snapshot().notes.first { $0.birth == a }).revision.id
    let rID = try #require(try await right.snapshot().notes.first { $0.birth == a }).revision.id
    _ = try await left.receive(right.retainedObject(at: r.object)); _ = try await right.receive(left.retainedObject(at: l.object))
    let lc = try await left.copyVersion(for: a, revision: rID, generation: 2)
    let rc = try await right.copyVersion(for: a, revision: lID, generation: 2)
    let lr = try requireReceipt(await left.persist(capture: lc)), rr = try requireReceipt(await right.persist(capture: rc))
    _ = try await left.receive(right.retainedObject(at: rr.object)); _ = try await right.receive(left.retainedObject(at: lr.object))
    let copiedBirth = lc.covered[0].birth
    for target in [copiedBirth, b] {
        let deletion = try await CapturedActionGroup(snapshot: left.snapshot(), kind: .deleteBatch,
            changes: [.delete(CapturedNoteGeneration(birth: target, generation: 3))])
        _ = try requireReceipt(await left.persist(capture: deletion))
    }
    let entry = try #require(try await left.history(for: .recentlyDeleted).entries.first { $0.birth == b })
    let restoration = try await left.restoration(from: entry, as: CapturedNoteGeneration(birth: restoredBirth, generation: 4))
    let restoreCapture = try await CapturedActionGroup(snapshot: left.snapshot(), restoring: [restoration])
    _ = try requireReceipt(await left.persist(capture: restoreCapture))
    _ = try await put("post-Restore edit", birth: restoredBirth, generation: 5, session: left)
    guard case .automatic(let command) = try await left.prepareCompensation(scope: .note(restoredBirth), direction: .undo) else {
        Issue.record("ordinary restored-note edit was not undoable"); return
    }
    let undo = try requireReceipt(await left.applyCompensation(command))
    let undoPayload = try ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(await left.retainedObject(at: undo.object),
        collection: initial.descriptor.collection, protection: protection).payload)
    let undoID = undoPayload.actions[0].action.id
    _ = try snapshotReceipt(await left.persistGeneralSnapshot(capture: left.captureGeneralSnapshot()))
    try await left.lane.perform { db in
        try db.exec("DROP TRIGGER objects_no_update")
        try db.run("UPDATE objects SET encoded=? WHERE object_id=?", [.blob([0]), .blob(r.object.segmentID.bytes)])
    }
    let primary = try await left.preserveForRepair(to: privateTempPath()), complement = try await right.preserveForRepair(to: privateTempPath())
    let replacement = try await LocalStoreSession.buildVerifiedReplacement(to: privateTempPath(), primary: primary,
        complementary: [complement], protection: protection)
    try await replacement.close()
    let opened = try await LocalStoreSession.open(selection: replacement.selection, protection: protection)
    let current = try await opened.snapshot()
    let expectedOriginal = lID.bytes.lexicographicallyPrecedes(rID.bytes) ? "Left" : "Right"
    #expect(Set(current.notes.map(\.birth)) == [a, rc.covered[0].birth, restoredBirth])
    #expect(current.notes.first { $0.birth == a }?.value.body.string == expectedOriginal)
    #expect(current.notes.first { $0.birth == rc.covered[0].birth }?.value.body.string == "Left")
    #expect(current.notes.first { $0.birth == restoredBirth }?.value.body.string == "untouched")
    #expect(try await opened.conflicts(for: a).alternatives.isEmpty)
    #expect(try await opened.conflicts(for: a).representedSeparately.isSuperset(of: [lID, rID]))
    #expect(try await opened.history(for: .recentlyDeleted).entries.map(\.birth) == [copiedBirth])
    #expect(try await opened.history(for: .note(restoredBirth)).entries.count == 3)
    #expect(try await opened.undoCandidates(scope: .note(restoredBirth), direction: .redo).ids == [undoID])
    guard case .automatic(let redo) = try await opened.prepareCompensation(scope: .note(restoredBirth), direction: .redo) else {
        Issue.record("repair lost the portable causal Redo"); return
    }
    _ = try requireReceipt(await opened.applyCompensation(redo))
    #expect(try await opened.snapshot().notes.first { $0.birth == restoredBirth }?.value.body.string == "post-Restore edit")
    try await opened.quiesce()
}
