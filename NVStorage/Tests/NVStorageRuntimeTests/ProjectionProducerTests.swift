import Foundation
import Testing
import NVStorageCore
import NVStorageTestSupport
@testable import NVStorageRuntime

private func producerOutput(_ store: LocalStoreSession, native: Bool = false, name: String = "Producer.txt") async throws -> ProjectionOutputV1 {
    let selection = await store.selection
    let association = try await store.localAssociation()
    if association.value == nil {
        let value = try LocalAssociationV1(id: LocalAssociationID(bytes: Array(repeating: 13, count: 16)),
            scope: .init(collection: selection.descriptor.collection, store: selection.store, descriptor: selection.descriptor.descriptorID),
            bookmark: .init(codec: 1, bytes: [1]))
        try await store.saveLocalAssociation(value, basedOn: association)
    }
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let intent = try await store.prepareProjectionIntent(for: birth, filename: .init(ExactUTF8(bytes: Array(name.utf8))),
        basedOn: store.snapshot(), observations: store.projectionObservations(for: birth),
        requestedEncoding: native ? .init(rawValue: 10) : .utf8)
    try await store.retainProjectionIntent(intent)
    return intent.output
}

private func producerHandle(_ store: LocalStoreSession, _ output: ProjectionOutputV1) async throws -> ProjectionDescriptionHandle {
    try await store.prepareProjectionDescription(for: output, observations: store.projectionObservations(for: output.binding.birth), basedOn: store.snapshot())
}

private func acceptedDescription(_ result: ProjectionDescriptionOutcome) throws -> AcceptedProjectionDescriptionReceipt {
    guard case .accepted(let receipt) = result else { throw StorageError.incomplete }
    return receipt
}

@Test(arguments: [false, true]) func projectionProducerPreservesExactOutputAndMetadataNeutrality(_ native: Bool) async throws {
    let (initial, protection) = try testInitial(false), store = try await newSession(initial, protection)
    let output = try await producerOutput(store, native: native), handle = try await producerHandle(store, output)
    let before = try await store.snapshot(), observations = try await store.projectionObservations(for: output.binding.birth)
    let actions = try await store.lane.perform { try ($0.rows("SELECT * FROM actions"), $0.rows("SELECT * FROM operations")) }
    let receipt = try acceptedDescription(await store.persistProjectionDescription(handle))
    #expect(receipt.object == handle.object && receipt.binding == output.binding && receipt.store == before.store)
    #expect(receipt.sequence == before.through + 1)
    let bytes = try await store.retainedObject(at: handle.object)
    let opened = try ObjectEnvelopeV1.open(bytes, collection: initial.descriptor.collection, protection: protection)
    let payload = try ChangesPayloadV1.decodeV1(opened)
    #expect(opened.locator == handle.object && payload.projections == [output.binding])
    #expect(payload.operations.isEmpty && payload.actions.isEmpty && payload.dependencies == output.binding.dependencies)
    #expect(output.binding.descriptor.digest == .compute(native ? [0xff, 0xfe, 0x41, 0] : [0x41]))
    #expect(try await store.snapshot().notes == before.notes)
    #expect(try await store.snapshot().context == before.context)
    #expect(try await store.projectionObservations(for: output.binding.birth).value == observations.value)
    #expect(try await store.lane.perform { try ($0.rows("SELECT * FROM actions") == actions.0 && $0.rows("SELECT * FROM operations") == actions.1) })
    #expect(try acceptedDescription(await store.persistProjectionDescription(handle)).sequence == receipt.sequence)
    #expect(try await store.retainedObject(at: handle.object) == bytes)
    let peer = try await newSession(initial, protection)
    _ = try await peer.receive(bytes)
    #expect(try await peer.snapshot().notes == before.notes)
    #expect(try await peer.projectionDescriptions(in: handle.object, basedOn: peer.snapshot()) == [output.binding])
    #expect(try await peer.projectionObservations(for: output.binding.birth).value == nil)
    try await peer.quiesce(); try await store.quiesce()
}

@Test(arguments: [false, true]) func projectionProducerKeepsCapturedDescriptionAfterNewerWork(_ delete: Bool) async throws {
    let (initial, protection) = try testInitial(false), store = try await newSession(initial, protection)
    let output = try await producerOutput(store), handle = try await producerHandle(store, output)
    let old = try await store.projectionObservations(for: output.binding.birth)
    _ = try await put("newer", birth: output.binding.birth, generation: 1, session: store)
    let newer = try await producerOutput(store, name: "Newer.txt")
    if delete {
        _ = try requireReceipt(await store.persist(capture: CapturedActionGroup(snapshot: store.snapshot(), kind: .deleteBatch,
            changes: [.delete(.init(birth: output.binding.birth, generation: 2))])))
    }
    let current = try await store.snapshot()
    await #expect(throws: StorageError.staleCapture) {
        try await store.prepareProjectionDescription(for: output, observations: old, basedOn: current)
    }
    let receipt = try acceptedDescription(await store.persistProjectionDescription(handle))
    #expect(receipt.binding == output.binding)
    #expect(try await store.snapshot().notes == current.notes)
    #expect(try await store.projectionObservations(for: output.binding.birth).value?.intended?.output == newer)
    let peer = try await newSession(initial, protection)
    await #expect(throws: StorageError.wrongContext) { try await peer.persistProjectionDescription(handle) }
    try await peer.quiesce()
    let selection = await store.selection
    try await store.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    await #expect(throws: StorageError.wrongContext) { try await reopened.persistProjectionDescription(handle) }
    #expect(try await reopened.projectionDescriptions(in: receipt.object, basedOn: reopened.snapshot()) == [output.binding])
    #expect(try await reopened.projectionObservations(for: output.binding.birth).value?.intended?.output == newer)
    try await reopened.quiesce()
}

@Test(arguments: ["retention", "acceptance", "callback"])
func projectionProducerRetriesExactBytesAfterFailure(_ stage: String) async throws {
    let (initial, protection) = try testInitial(false), store = try await newSession(initial, protection)
    let output = try await producerOutput(store), handle = try await producerHandle(store, output)
    let before = try await store.snapshot()
    try await store.lane.perform { db in
        if stage == "callback" {
            db.work = StorageWork(); db.work?.receiveRetentionCompletion = { _ in throw CancellationError() }
        } else {
            try db.exec("CREATE TEMP TRIGGER reject_producer BEFORE INSERT ON \(stage == "retention" ? "objects" : "accepted_objects") BEGIN SELECT RAISE(ABORT,'producer qualification'); END")
        }
    }
    for _ in 0..<2 {
        guard case .pending(let retry, let error) = try await store.persistProjectionDescription(handle) else { Issue.record("failed persistence must return exact retry input"); return }
        #expect(retry.object == handle.object && retry.binding == handle.binding)
        #expect(error == (stage == "callback" ? .cancelled : .database(1811)))
        #expect(try await store.snapshot().through == before.through)
    }
    let retained = try await store.lane.perform { db in
        try db.rows("SELECT encoded FROM objects JOIN ready_objects USING(object_id) WHERE object_id=?", [.blob(handle.object.segmentID.bytes)])
    }
    #expect(retained.isEmpty == (stage == "retention"))
    try await store.lane.perform { db in
        if stage == "callback" { db.work = nil } else { try db.exec("DROP TRIGGER reject_producer") }
    }
    let receipt = try acceptedDescription(await store.persistProjectionDescription(handle))
    #expect(receipt.object == handle.object && receipt.sequence == before.through + 1)
    if let row = retained.first { #expect(try await store.retainedObject(at: handle.object) == row[0].bytes) }
    #expect(try acceptedDescription(await store.persistProjectionDescription(handle)).sequence == receipt.sequence)
    #expect(try await store.snapshot().notes == before.notes)
    try await store.quiesce()
}

@Test(.timeLimit(.minutes(1))) func projectionProducerOwnedReceiveSurvivesCloseAndBusyRetry() async throws {
    let (initial, protection) = try testInitial(false), store = try await newSession(initial, protection)
    let output = try await producerOutput(store), handle = try await producerHandle(store, output), gate = ImprovementGate()
    try await store.lane.perform { db in db.work = StorageWork(); db.work?.receiveRetentionCompletion = { _ in await gate.hold() } }
    let writing = Task { try await store.persistProjectionDescription(handle) }
    await gate.wait()
    guard case .pending(let retry, .busy) = try await store.persistProjectionDescription(handle) else { Issue.record("receive owner must serialize duplicate attempts"); return }
    #expect(retry.object == handle.object)
    let closing = Task { try await store.quiesce() }
    while await store.lifecycle != .quiescing { await Task.yield() }
    #expect(await store.lifecycle == .quiescing)
    await gate.release()
    let receipt = try acceptedDescription(await writing.value)
    try await closing.value
    let reopened = try await LocalStoreSession.open(selection: store.selection, protection: protection)
    #expect(try await reopened.projectionDescriptions(in: receipt.object, basedOn: reopened.snapshot()) == [output.binding])
    try await reopened.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: ["private", "history", "close"])
func projectionProducerFencesPreparationCompletion(_ change: String) async throws {
    let (initial, protection) = try testInitial(false), store = try await newSession(initial, protection)
    let output = try await producerOutput(store), gate = ImprovementGate()
    try await store.lane.perform { db in db.work = StorageWork(); db.work?.projectionDescriptionSealed = { await gate.hold() } }
    let preparing = Task { try await producerHandle(store, output) }
    await gate.wait()
    if change == "private" { _ = try await producerOutput(store, name: "New.txt") }
    else if change == "history" { _ = try await put("changed", birth: output.binding.birth, generation: 1, session: store) }
    else { try await store.quiesce() }
    await gate.release()
    await #expect(throws: change == "close" ? StorageError.closed : .staleCapture) { try await preparing.value }
    if change != "close" {
        try await store.lane.perform { $0.work = nil }
        let companion = try await producerHandle(store, producerOutput(store))
        _ = try acceptedDescription(await store.persistProjectionDescription(companion))
        try await store.quiesce()
    }
}

@Test func projectionProducerReservesDistinctAddressesAndRejectsEncryptedProfile() async throws {
    let (initial, protection) = try testInitial(false), store = try await newSession(initial, protection)
    let output = try await producerOutput(store)
    async let a = producerHandle(store, output)
    async let b = producerHandle(store, output)
    let (first, second) = try await (a, b)
    #expect(first.object.writerEpoch == second.object.writerEpoch && first.object.sequence != second.object.sequence)
    #expect(first.object.segmentID != second.object.segmentID)
    let receiptA = try acceptedDescription(await store.persistProjectionDescription(first))
    let receiptB = try acceptedDescription(await store.persistProjectionDescription(second))
    #expect(receiptB.sequence == receiptA.sequence + 1)
    let (encrypted, key) = try testInitial(true), other = try await newSession(encrypted, key)
    await #expect(throws: StorageError.unsupported) {
        try await other.prepareProjectionDescription(for: output, observations: other.projectionObservations(for: output.binding.birth), basedOn: other.snapshot())
    }
    try await other.quiesce(); try await store.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: ["cancel", "committedCallback"])
func projectionProducerRestartsRetainedWorkWithoutHandle(_ cut: String) async throws {
    let (initial, protection) = try testInitial(false), store = try await newSession(initial, protection)
    let output = try await producerOutput(store), handle = try await producerHandle(store, output), gate = ImprovementGate()
    let before = try await store.snapshot(), selection = await store.selection
    try await store.lane.perform { db in
        db.work = StorageWork()
        if cut == "cancel" { db.work?.receiveRetentionCompletion = { _ in await gate.hold() } }
        else { db.work?.acceptanceCompletion = { _ in throw StorageError.database(1034) } }
    }
    let writing = Task { try await store.persistProjectionDescription(handle) }
    if cut == "cancel" { await gate.wait(); writing.cancel(); await gate.release() }
    let result = try await writing.value
    let retained = try await store.lane.perform { db in
        try db.rows("SELECT o.encoded,a.seq FROM objects o LEFT JOIN accepted_objects a USING(object_id) WHERE o.object_id=?",
            [.blob(handle.object.segmentID.bytes)])
    }
    #expect(retained.count == 1)
    switch result {
    case .accepted(let receipt):
        #expect(cut == "cancel" && receipt.object == handle.object && retained[0][1] == .integer(receipt.sequence))
    case .pending(let retry, let error):
        #expect(retry.object == handle.object)
        #expect(error == (cut == "cancel" ? .cancelled : .database(1034)))
    }
    if cut == "committedCallback" { #expect(retained[0][1] == .integer(before.through + 1)) }
    try await store.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.snapshot().through == before.through + 1)
    #expect(try await reopened.snapshot().notes == before.notes)
    #expect(try await reopened.retainedObject(at: handle.object) == retained[0][0].bytes)
    #expect(try await reopened.projectionDescriptions(in: handle.object, basedOn: reopened.snapshot()) == [output.binding])
    try await reopened.quiesce()
}

private func descriptionTips(_ store: LocalStoreSession) async throws -> Set<[UInt8]> {
    try await store.lane.perform { db in
        try Set(db.rows("SELECT r.object_id FROM retained_frontier r JOIN objects o USING(object_id) WHERE o.kind=1").map { try $0[0].bytes })
    }
}

@Test(.timeLimit(.minutes(5))) func projectionProducerRetentionBoundsStartupAndAcceptanceWork() async throws {
    let (initial, protection) = try testInitial(false)
    var store = try await newSession(initial, protection)
    let output = try await producerOutput(store), before = try await store.snapshot()
    var saved: [(SegmentLocator, [UInt8])] = []
    var reference: (Int, Int, Int)?
    for count in 1...64 {
        let handle = try await producerHandle(store, output)
        try await store.lane.perform { $0.work = StorageWork() }
        let start = DispatchTime.now().uptimeNanoseconds
        _ = try acceptedDescription(await store.persistProjectionDescription(handle))
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let work = try await store.lane.perform { try #require($0.work) }
        let reads = work.stages.values.reduce(0) { $0 + $1.historyReads }
        let decodes = work.stages.values.reduce(0) { $0 + $1.envelopeDecodes }
        let checks = work.stages.values.reduce(0) { $0 + $1.retentionParentChecks }
        #expect(checks == (count == 1 ? 0 : 1))
        #expect(work.stages.values.allSatisfy { $0.ancestors == 0 && $0.graphLoads == 0 && $0.recursiveStatements == 0 })
        if count > 1 {
            if let reference { #expect(reads == reference.0 && decodes == reference.1 && checks == reference.2) }
            else { reference = (reads, decodes, checks) }
        }
        let bytes = try await store.retainedObject(at: handle.object)
        let payload = try ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(bytes, collection: initial.descriptor.collection, protection: protection))
        let expected = Set(output.binding.dependencies.entries + (saved.last.map { [$0.0] } ?? []))
        #expect(Set(payload.dependencies.entries) == expected)
        #expect(try await descriptionTips(store) == [handle.object.segmentID.bytes])
        saved.append((handle.object, bytes))
        if [1, 8, 64].contains(count) {
            let selection = await store.selection
            try await store.quiesce()
            let openStart = DispatchTime.now().uptimeNanoseconds
            store = try await LocalStoreSession.open(selection: selection, protection: protection, measuring: StorageWork())
            let openElapsed = DispatchTime.now().uptimeNanoseconds - openStart
            let opening = try await store.lane.perform { try #require($0.work) }
            #expect(opening.stages.values.reduce(0) { $0 + $1.retainedLeafChecks } == 2)
            #expect(opening.stages.values.allSatisfy { $0.historyReads == 0 && $0.graphLoads == 0 && $0.ancestors == 0 })
            #expect(try await store.snapshot().notes == before.notes)
            #expect(try await store.snapshot().context == before.context)
            print("PROJECTION-RETENTION count=\(count) saveNS=\(elapsed) openNS=\(openElapsed) reads=\(reads) decodes=\(decodes) parentChecks=\(checks) leaves=2")
        }
    }
    for (locator, bytes) in saved { #expect(try await store.retainedObject(at: locator) == bytes) }
    #expect(try await store.rebuildCurrentRows().notes == before.notes)
    try await store.quiesce()
}

@Test func projectionProducerRetentionPreservesConcurrentTipsAndDelayedJoin() async throws {
    let (initial, protection) = try testInitial(false)
    let a = try await newSession(initial, protection), b = try await newSession(initial, protection)
    let outputA = try await producerOutput(a), outputB = try await producerOutput(b)
    let first = try await producerHandle(a, outputA), independent = try await producerHandle(b, outputB)
    _ = try acceptedDescription(await a.persistProjectionDescription(first))
    _ = try acceptedDescription(await b.persistProjectionDescription(independent))
    let firstBytes = try await a.retainedObject(at: first.object), independentBytes = try await b.retainedObject(at: independent.object)
    let stale = try await producerHandle(a, outputA)
    _ = try await a.receive(independentBytes)
    _ = try acceptedDescription(await a.persistProjectionDescription(stale))
    #expect(try await descriptionTips(a) == [stale.object.segmentID.bytes, independent.object.segmentID.bytes])
    let join = try await producerHandle(a, outputA)
    _ = try acceptedDescription(await a.persistProjectionDescription(join))
    #expect(try await descriptionTips(a) == [join.object.segmentID.bytes])
    let joined = try await a.retainedObject(at: join.object), staleBytes = try await a.retainedObject(at: stale.object)
    let peer = try await newSession(initial, protection), selection = await peer.selection
    guard case .waiting(let waits) = try await peer.receive(joined) else { Issue.record("join waits for both exact parents"); return }
    #expect(Set(waits.map(\.locator)) == [stale.object, independent.object])
    _ = try await peer.receive(staleBytes)
    _ = try await peer.receive(firstBytes)
    #expect(try await peer.projectionDescriptions(in: join.object, basedOn: peer.snapshot()) == nil)
    try await peer.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    _ = try await reopened.receive(independentBytes)
    #expect(try await descriptionTips(reopened) == [join.object.segmentID.bytes])
    #expect(try await reopened.projectionDescriptions(in: join.object, basedOn: reopened.snapshot()) == [outputA.binding])
    #expect(try await reopened.snapshot().notes == a.snapshot().notes)
    #expect(try await reopened.snapshot().context == a.snapshot().context)
    for (locator, bytes) in [(first.object, firstBytes), (independent.object, independentBytes), (stale.object, staleBytes), (join.object, joined)] {
        #expect(try await reopened.retainedObject(at: locator) == bytes)
    }
    try await a.quiesce(); try await b.quiesce(); try await reopened.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func projectionProducerRetentionRejectsDamagedParentBeforeCoverage(_ afterVerification: Bool) async throws {
    let (initial, protection) = try testInitial(false), store = try await newSession(initial, protection)
    let output = try await producerOutput(store), parent = try await producerHandle(store, output)
    _ = try acceptedDescription(await store.persistProjectionDescription(parent))
    let child = try await producerHandle(store, output), before = try await store.snapshot(), gate = ImprovementGate()
    if afterVerification {
        try await store.lane.perform { db in db.work = StorageWork(); db.work?.historyValidated = { await gate.hold() } }
    }
    func damage() async throws {
        try await store.lane.perform { db in
            try db.exec("DROP TRIGGER objects_no_update")
            try db.run("UPDATE objects SET encoded=? WHERE object_id=?", [.blob([0]), .blob(parent.object.segmentID.bytes)])
        }
    }
    if !afterVerification { try await damage() }
    let saving = Task { try await store.persistProjectionDescription(child) }
    if afterVerification { await gate.wait(); try await damage(); await gate.release() }
    let result = try await saving.value
    await #expect(throws: StorageError.integrity) { try await store.snapshot() }
    let selection = await store.selection
    await store.lane.close()
    let raw = DatabaseLane()
    try await raw.open(directory: selection.directory, create: false,
        key: PrivateDatabaseKeyV1.derive(collection: selection.descriptor.collection, protection: protection))
    #expect(try await raw.perform { try $0.acceptedThrough() } == before.through)
    #expect(try await raw.perform { try $0.rows("SELECT r.object_id FROM retained_frontier r JOIN objects o USING(object_id) WHERE o.kind=1") } == [[.blob(parent.object.segmentID.bytes)]])
    #expect(try await raw.perform { try $0.rows("SELECT 1 FROM accepted_dependencies WHERE child=?", [.blob(child.object.segmentID.bytes)]).isEmpty })
    await raw.close()
    guard case .pending(let retry, .integrity) = result else { Issue.record("damaged retention parent must prevent coverage"); return }
    #expect(retry.object == child.object)
    await #expect(throws: StorageError.integrity) { try await LocalStoreSession.open(selection: selection, protection: protection) }
}

@Test(arguments: ["kind", "locator"])
func projectionProducerRetentionRejectsMisaddressedCoverage(_ defect: String) async throws {
    let (initial, protection) = try testInitial(false), store = try await newSession(initial, protection)
    let output = try await producerOutput(store), parent = try await producerHandle(store, output)
    _ = try acceptedDescription(await store.persistProjectionDescription(parent))
    let before = try await store.snapshot()
    let invalid = defect == "kind" ? initial.snapshot : SegmentLocator(writerEpoch: parent.object.writerEpoch,
        sequence: parent.object.sequence + 1, segmentID: parent.object.segmentID)
    let payload = try ChangesPayloadV1(dependencies: .init(output.binding.dependencies.entries + [invalid]),
        operations: [], actions: [], projections: [output.binding])
    let bytes = try ObjectEnvelopeV1.seal(payload: payload.encodedV1(), kind: .changes, collection: initial.descriptor.collection,
        writer: WriterEpoch(bytes: Array(repeating: 73, count: 16)), sequence: 1, protection: protection)
    await #expect(throws: CanonicalEncodingError.invalidReference) { try await store.receive(bytes) }
    #expect(try await store.snapshot().through == before.through)
    #expect(try await descriptionTips(store) == [parent.object.segmentID.bytes])
    let valid = try await producerHandle(store, output)
    _ = try acceptedDescription(await store.persistProjectionDescription(valid))
    #expect(try await descriptionTips(store) == [valid.object.segmentID.bytes])
    try await store.quiesce()
}
