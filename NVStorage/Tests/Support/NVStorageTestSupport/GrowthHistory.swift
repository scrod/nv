import Foundation
import Dispatch
import NVStorageCore
import NVStorageRuntime

/// One complete saved edit and its exact transport bytes in a linear history.
package struct GrowthHistoryObject: Equatable, Sendable {
    package let locator: SegmentLocator
    package let bytes: [UInt8]
    fileprivate init(locator: SegmentLocator, bytes: [UInt8]) {
        self.locator = locator; self.bytes = bytes
    }
}

/// Closed, checked prefix stores that issue a fresh physical copy to each consumer.
package struct GrowthHistoryFixture: Sendable {
    package let initial: InitialCollectionV1
    package let protection: ObjectProtectionV1
    package let history: [GrowthHistoryObject]
    package let following: GrowthHistoryObject
    private let sender: CompletePrivateBackup
    private let receiver: CompletePrivateBackup
    private let tip: StoredOperationReferenceV1

    fileprivate init(initial: InitialCollectionV1, protection: ObjectProtectionV1,
        history: [GrowthHistoryObject], following: GrowthHistoryObject, sender: CompletePrivateBackup,
        receiver: CompletePrivateBackup, tip: StoredOperationReferenceV1) {
        self.initial = initial; self.protection = protection; self.history = history; self.following = following
        self.sender = sender; self.receiver = receiver; self.tip = tip
    }

    package func openSender() async throws -> LocalStoreSession { try await copyAndOpen(sender) }
    package func openReceiver() async throws -> LocalStoreSession { try await copyAndOpen(receiver) }

    private func copyAndOpen(_ backup: CompletePrivateBackup) async throws -> LocalStoreSession {
        let directory = privateTempPath()
        try FileManager.default.copyItem(atPath: backup.selection.directory, toPath: directory)
        let selection = LocalStoreSelection(directory: directory, store: backup.selection.store,
            descriptor: backup.selection.descriptor)
        let store = try await LocalStoreSession.open(selection: selection, protection: protection)
        do {
            let snapshot = try await store.snapshot()
            let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
            guard snapshot.through == backup.through,
                  snapshot.notes.map(\.value.body.string).sorted() == ["E\(history.count)", "untouched"],
                  snapshot.context.operations == [tip],
                  snapshot.notes.first(where: { $0.birth == birth })?.revision == tip else {
                throw StorageError.integrity
            }
            return store
        } catch { try? await store.quiesce(); throw error }
    }
}

/// Checkpoints exposed to small fixture lifecycle tests.
package enum GrowthHistoryBuildEvent: Equatable, Sendable {
    case started
    case checkpoint(Int)
}

/// Coalesces one fully checked build per profile for the current test process.
package actor GrowthHistoryFixtures {
    package static let shared = try! GrowthHistoryFixtures(checkpoints: [64, 256, 1024])
    private let checkpoints: [Int]
    private let onBuildEvent: (@Sendable (GrowthHistoryBuildEvent) async throws -> Void)?
    private var builds: [Bool: Task<[Int: GrowthHistoryFixture], Error>] = [:]

    package init(checkpoints: [Int],
        onBuildEvent: (@Sendable (GrowthHistoryBuildEvent) async throws -> Void)? = nil) throws {
        guard !checkpoints.isEmpty, checkpoints == checkpoints.sorted(),
              Set(checkpoints).count == checkpoints.count,
              checkpoints.allSatisfy({ $0 > 0 && $0 <= 1024 }) else { throw StorageError.limit }
        self.checkpoints = checkpoints; self.onBuildEvent = onBuildEvent
    }

    package func fixture(encrypted: Bool, actions: Int) async throws -> GrowthHistoryFixture {
        guard checkpoints.contains(actions) else { throw StorageError.limit }
        let task: Task<[Int: GrowthHistoryFixture], Error>
        if let existing = builds[encrypted] { task = existing }
        else {
            let checkpoints = checkpoints, hook = onBuildEvent
            task = Task { try await Self.build(encrypted: encrypted, checkpoints: checkpoints, hook: hook) }
            builds[encrypted] = task
        }
        guard let fixture = try await task.value[actions] else { throw StorageError.incomplete }
        return fixture
    }

    private static func build(encrypted: Bool, checkpoints: [Int],
        hook: (@Sendable (GrowthHistoryBuildEvent) async throws -> Void)?) async throws -> [Int: GrowthHistoryFixture] {
        let start = DispatchTime.now().uptimeNanoseconds
        try await hook?(.started)
        let (initial, protection) = try testInitial(encrypted)
        let sender = try await newSession(initial, protection)
        var receiver: LocalStoreSession?
        do {
            let destination = try await newSession(initial, protection)
            receiver = destination
            let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
            let original = try await sender.snapshot()
            guard original.context.operations.count == 1,
                  let imported = original.notes.first(where: { $0.birth == birth }) else { throw StorageError.integrity }
            var parent = original.context.operations[0].id, predecessor = imported.revision.id
            var previousAction: ActionV1?
            var history: [GrowthHistoryObject] = []
            var copies: [Int: (sender: CompletePrivateBackup, receiver: CompletePrivateBackup, tip: StoredOperationReferenceV1)] = [:]
            let maximum = checkpoints[checkpoints.count - 1]
            for generation in 1...(maximum + 1) {
                let body = generation <= maximum ? "E\(generation)" : "one new file"
                let receipt = try await put(body, birth: birth, generation: UInt64(generation), session: sender)
                let bytes = try await sender.retainedObject(at: receipt.object)
                let opened = try ObjectEnvelopeV1.open(bytes, collection: initial.descriptor.collection, protection: protection)
                let payload = try ChangesPayloadV1.decodeV1(opened.payload)
                guard opened.locator == receipt.object, payload.operations.count == 1, payload.actions.count == 1 else {
                    throw StorageError.integrity
                }
                let operation = payload.operations[0].operation, action = payload.actions[0].action
                guard operation.effect == .put(action: action.id, birth: birth, value: try testValue(body)),
                      operation.causalParents.ids == [parent], operation.notePredecessors.ids == [predecessor],
                      action.kind == .savedEdit, action.members == [operation.id],
                      previousAction.map({ action.origin == $0.origin && action.previousOriginAction == $0.id && action.scopeParents == [$0.id] }) ?? true,
                      history.first.map({ $0.locator.writerEpoch == opened.locator.writerEpoch }) ?? true else {
                    throw StorageError.integrity
                }
                if generation <= maximum {
                    guard case .accepted = try await destination.receive(bytes) else { throw StorageError.incomplete }
                }
                history.append(GrowthHistoryObject(locator: receipt.object, bytes: bytes))
                parent = operation.id; predecessor = operation.id; previousAction = action
                if checkpoints.contains(generation) {
                    let sourceCopy = try await sender.backupPrivateStore(to: privateTempPath())
                    let receivedCopy = try await destination.backupPrivateStore(to: privateTempPath())
                    guard sourceCopy.through == Int64(generation + 1), receivedCopy.through == sourceCopy.through else {
                        throw StorageError.integrity
                    }
                    copies[generation] = (sourceCopy, receivedCopy,
                        .init(locator: receipt.object, index: OperationIndex(0), id: operation.id))
                    try await hook?(.checkpoint(generation))
                }
            }
            try await destination.quiesce(); receiver = nil
            try await sender.quiesce()
            print("GROWTH-FIXTURE encrypted=\(encrypted) actions=\(maximum) checkpoints=\(checkpoints) ns=\(DispatchTime.now().uptimeNanoseconds - start)")
            return copies.mapValues { copy in
                let count = Int(copy.sender.through - 1)
                return GrowthHistoryFixture(initial: initial, protection: protection,
                    history: Array(history.prefix(count)), following: history[count], sender: copy.sender,
                    receiver: copy.receiver, tip: copy.tip)
            }
        } catch {
            try? await receiver?.quiesce(); try? await sender.quiesce(); throw error
        }
    }
}
