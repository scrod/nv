import NVStorageTestSupport
import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

func measuredPut(_ session: LocalStoreSession, birth: NoteBirth, generation: UInt64) async throws -> StorageWork {
    let lane = await session.lane
    try await lane.perform { $0.work = StorageWork() }
    let start = DispatchTime.now().uptimeNanoseconds
    _ = try await put("measured", birth: birth, generation: generation, session: session)
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    return try await lane.perform { db in
        var result = db.work!
        result.elapsedNanoseconds = elapsed
        db.work = nil
        return result
    }
}

func reportWork(_ work: StorageWork, count: Int, reopened: Bool, encrypted: Bool) {
    print("SAVE-TOTAL count=\(count) reopened=\(reopened) encrypted=\(encrypted) ns=\(work.elapsedNanoseconds)")
    for stage in StorageWork.Stage.allCases {
        let c = work[stage]
        print("SAVE-WORK count=\(count) reopened=\(reopened) encrypted=\(encrypted) stage=\(stage.rawValue) sql=\(c.statements) vm=\(c.vmSteps) rows=\(c.rows) reads=\(c.historyReads) decodes=\(c.envelopeDecodes) ancestors=\(c.ancestors) recursiveSQL=\(c.recursiveStatements) fast=\(c.fastChecks) full=\(c.fullChecks) ns=\(c.nanoseconds)")
        print("SAVE-SCAN stage=\(stage.rawValue) steps=\(c.fullScanSteps)")
        for (sql, steps) in c.statementSteps where steps > 500 { print("SAVE-SQL stage=\(stage.rawValue) \(steps) \(sql)") }
    }
}

@Test(arguments: [false, true]) func ordinarySaveWorkAcrossGrowingHistory(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    var session = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    var count = 0
    var first: [Bool: StorageWork] = [:]
    for target in [64, 256, 1024] {
        while count < target {
            _ = try await put("history", birth: birth, generation: UInt64(count + 1), session: session)
            count += 1
        }
        let warm = try await measuredPut(session, birth: birth, generation: UInt64(count + 1))
        count += 1
        reportWork(warm, count: target, reopened: false, encrypted: encrypted)
        let selection = await session.selection
        try await session.quiesce()
        session = try await LocalStoreSession.open(selection: selection, protection: protection)
        let reopened = try await measuredPut(session, birth: birth, generation: UInt64(count + 1))
        count += 1
        reportWork(reopened, count: target, reopened: true, encrypted: encrypted)
        for (cold, work) in [(false, warm), (true, reopened)] {
            #expect(work[.validation].fastChecks == 1)
            #expect(work[.validation].fullChecks == 0)
            for stage in StorageWork.Stage.allCases {
                #expect(work[stage].ancestors == 0)
                #expect(work[stage].recursiveStatements == 0)
                #expect(work[stage].connectionContextChecks == 0)
                #expect(work[stage].statementCalls["SELECT 1 FROM accepted_objects a JOIN objects o USING(object_id) WHERE o.object_id=? AND o.kind=2 AND o.writer_epoch=? AND o.sequence=?"] == nil)
                if let baseline = first[cold] {
                    #expect(work[stage].historyReads == baseline[stage].historyReads)
                    #expect(work[stage].envelopeDecodes == baseline[stage].envelopeDecodes)
                    #expect(work[stage].statements == baseline[stage].statements)
                    #expect(work[stage].rows == baseline[stage].rows)
                    #expect(work[stage].fullScanSteps == baseline[stage].fullScanSteps)
                    #expect(Set(work[stage].statementSteps.keys) == Set(baseline[stage].statementSteps.keys))
                    for (sql, steps) in work[stage].statementSteps {
                        let previous = try #require(baseline[stage].statementSteps[sql])
                        if sql == "DELETE FROM retained_frontier WHERE object_id IN (SELECT prerequisite FROM accepted_dependencies WHERE child=?)" {
                            // The child/prerequisite index has the same EOF-versus-
                            // following-key branch after its one matching dependency.
                            #expect([37, 38].contains(steps) && [37, 38].contains(previous))
                        } else {
                            #expect(steps == previous, "SQL work grew: \(sql)")
                        }
                    }
                }
            }
            if first[cold] == nil { first[cold] = work }
        }
        let values = try await session.snapshot().notes.map(\.value.body.string).sorted()
        #expect(values == ["measured", "untouched"])
    }
    try await session.quiesce()
}
