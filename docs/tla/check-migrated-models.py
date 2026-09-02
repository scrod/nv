#!/usr/bin/env python3
"""Exhaustive checks plus assertion-specific negative controls; stdlib only.

Each mutant is a disposable copy, never an edit to the working model.
Timeout, parse failure, evaluation error, or an undetected mutation is failure.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile

MODELS = (
    "JournalRecoverySafety", "MultiJournalRecoverySafety", "StartupSafety",
    "JournalLifecycle", "QuitSafety", "ReconciliationDecisionSafety",
    "StorageTransitionSafety",
    "ReconciliationDurabilityBridge", "StorageStartupBridge",
)

# Audit regression: corrupt the implementation helper, not its independent
# per-UUID assertions. Exercise installation, recovery cleanup, and reopening.
DROP_BRIDGE_BASE = [(r'''Apply(store,records) ==
 {row \in store: row[1] \notin IDs(records)} \cup
 {row \in records: row[2][1] # "absent"}''',
 r'''Apply(store,records) ==
 ({row \in store: row[1] \notin IDs(records)} \cup
 {row \in records: row[2][1] # "absent"}) \
 (IF records \ Base # {} THEN Base ELSE {})''')]

# model, label, assertion kind/name, exact textual mutation(s).
# A three-part edit names an imported module; an empty edit list is a
# reachability witness (the deliberately false "unreachable" claim must fail).
CASES = [
    ("JournalRecoverySafety", "empty-checkpoint-serializer", "INVARIANT",
     "DeletedWALHasActualRepresentation",
     [(r'Serialize(live) == {<<n,live[n]>>: n \in {m \in Notes: live[m] # "deleted"}}',
       'Serialize(live) == {}')]),
    ("JournalRecoverySafety", "replay-wrong-record", "INVARIANT",
     "ReplayMatchesOrderedPrefix",
     [(r"r == s.records[s.pos + 1]", r"r == s.records[1]")]),
    ("JournalRecoverySafety", "accept-invalid-suffix", "INVARIANT",
     "UncertainSuffixNeverAuthorizesCleanup",
     [('IF s.prefix = 2 THEN "settle" ELSE "blocked"', '"settle"')]),
    ("JournalRecoverySafety", "drop-v8-retirement", "INVARIANT",
     "ReplayMatchesOrderedPrefix",
     [(r'!.retired = IF r = <<"v8", "deleted">> THEN @ \cup {"v8"} ELSE @',
       r'!.retired = @')]),
    ("JournalRecoverySafety", "represented-cleanup-ignores-retirement", "INVARIANT",
     "DeletedWALHasActualRepresentation",
     [(r'''CompleteCoverage ==
  s.checkpoint = Serialize(s.live) /\ s.checkpointConflicts = s.conflicts /\
  s.checkpointRetired = s.retired''',
       r'''CompleteCoverage ==
  s.checkpoint = Serialize(s.live) /\ s.checkpointConflicts = s.conflicts''')]),
    ("MultiJournalRecoverySafety", "serializer-drops-unchanged-notes", "INVARIANT",
     "DeletedMembersHaveActualCompleteCheckpoint",
     [(r'Serialize(live) == {R(n,live[n]): n \in {m \in Notes: live[m] # "deleted"}}',
       r'Serialize(live) == {R(n,live[n]): n \in {m \in Notes: live[m] \notin {"base","deleted"}}}')]),
    ("MultiJournalRecoverySafety", "combine-incomplete-wals", "INVARIANT",
     "SettledPreservesBothBranches",
     [(r's.phase = "replay" /\ \A j \in Journals: s.pos[j] = 2',
       r's.phase = "replay"')]),
    ("MultiJournalRecoverySafety", "omit-checkpoint-retirements", "INVARIANT",
     "InstalledCheckpointContainsAllResults",
     [(r'!.checkpointRetired = s.retired]', r'!.checkpointRetired = {}]')]),
    ("StartupSafety", "offline-with-incomplete-input", "INVARIANT",
     "OfflineRequiresCompleteInputs",
     [('\n' + r' /\ s.bytesGood /\ s.walKind # "uncertain"', '\n' + r' /\ TRUE')]),
    ("StartupSafety", "implicit-existing-folder-creation", "PROPERTY",
     "CreationRequiresConsentOrExclusiveOwnership",
     [(r's.status = "absent" /\ (s.owned \/ s.consent)', r's.status = "absent"')]),
    ("StartupSafety", "stale-rebuild-catalog", "PROPERTY",
     "RebuildInstallIsCompleteAndCurrent",
     [(r'(s.source = "rebuild" => s.catalog = s.capturedCatalog)', 'TRUE')]),
    ("StartupSafety", "edit-before-fresh-directory-sync", "INVARIANT",
     "EditingRequiresCompleteDurableStartup",
     [(r's.phase = "header" /\ s.headerDurable /\ s.freshDirectoryDurable',
       r's.phase = "header" /\ s.headerDurable')]),
    ("JournalLifecycle", "two-local-lock-owners", "INVARIANT",
     "AtMostOneLocalWriter",
     [(r's.phase[p] = "idle" /\ s.locks = {}', r's.phase[p] = "idle"')]),
    ("JournalLifecycle", "drop-directory-lock-on-move", "INVARIANT",
     "RootLockSpansSession",
     [(r'!.pathRevision = 1]', r'!.pathRevision = 1, !.locks = {}]')]),
    ("JournalLifecycle", "drop-directory-lock-on-authority-handoff", "INVARIANT",
     "RootLockSpansSession",
     [(r'!.session = 2, !.providerReady = FALSE]',
       r'!.session = 2, !.providerReady = FALSE, !.locks = {}]')]),
    ("JournalLifecycle", "expose-before-directory-sync", "INVARIANT",
     "DescriptorRequiresDurableAssociatedCreation",
     [(r's.phase[p] = "ready" /\ p \in s.locks', r's.phase[p] = "directory" /\ p \in s.locks'),
      (r's.id[p] \in s.headerSynced /\ s.id[p] \in s.directorySynced',
       r's.id[p] \in s.headerSynced')]),
    ("JournalLifecycle", "publish-old-authority", "PROPERTY",
     "ProviderPublicationUsesCurrentAuthority",
     [(r's.providerReady /\ s.associated /\ s.snapshot[p] = s.session',
       r's.providerReady /\ s.associated')]),
    ("QuitSafety", "empty-wal-ignores-preferences", "PROPERTY",
     "EmptyCloseRequiresAllCheckpointScopedStateUnchanged",
     [(r'~s.walRecords /\ ~s.metadataDirty /\ ~s.remoteNeeded',
       r'~s.walRecords /\ ~s.remoteNeeded')]),
    ("QuitSafety", "drop-directory-lock-at-wal-unlink", "INVARIANT",
     "RootLockSpansClose",
     [(r'!.wal = FALSE, !.phase = "unlinked"]',
       r'!.wal = FALSE, !.phase = "unlinked", !.rootLocked = FALSE]')]),
    ("QuitSafety", "release-directory-before-observer-drain", "PROPERTY",
     "RootLockReleaseFollowsLocalClose",
     [(r'/\ s.phase = "release"', r'/\ s.phase = "barrier"')]),
    ("QuitSafety", "unbounded-automatic-contention-retry", "PROPERTY",
     "SecondMismatchCannotAutomaticallyRetry",
     [('IF s.attempt = 0 THEN "drain" ELSE "paused"', '"drain"')]),
    ("QuitSafety", "skip-merged-retirement-settlement", "PROPERTY",
     "EveryInstallUsesExactSettledLiveInput",
     [(r'(~s.remoteNeeded \/ (s.remoteDurable /\ s.remoteFile))', 'TRUE')]),
    ("ReconciliationDecisionSafety", "trust-unsettled-checkpoint-base", "INVARIANT",
     "NoMergeFromUnsettledCheckpointBase",
     [(r'TrustworthyBase == s.origin \in {"file","settledCheckpoint"}',
       r'TrustworthyBase == s.origin \in {"file","settledCheckpoint","unsettledCheckpoint"}')]),
    ("ReconciliationDecisionSafety", "accept-wrong-volume-identity", "INVARIANT",
     "UnqualifiedIdentityAlwaysImportsFresh",
     [(r'Associated == s.evidence \in {"document","file","fallback","changedIDFallback"}',
       r'Associated == s.evidence \in {"document","file","fallback","changedIDFallback","wrongVolume"}')]),
    ("ReconciliationDecisionSafety", "ignore-conflicting-renames", "INVARIANT",
     "ConflictingRenamesPreserveRemote",
     [(r'''NameConflict ==
 s.local[2] # "base" /\ s.remote[2] # "base" /\ s.local[2] # s.remote[2]''',
       'NameConflict == FALSE')]),
    ("ReconciliationDecisionSafety", "discard-safe-merge-result", "INVARIANT",
     "PreparedDecisionMatchesIndependentTable",
     [('A("merged",CombinedName)', 'A("local",CombinedName)')]),
    ("ReconciliationDecisionSafety", "publish-stale-input", "PROPERTY",
     "PublicationRequiresEveryCurrentFence",
     [('Publish ==\n' + r' /\ s.phase = "prepared" /\ s.drift = "none"',
       'Publish ==\n' + r' /\ s.phase = "prepared"')]),
    ("ReconciliationDecisionSafety", "overwrite-unrelated-automatic-candidate", "PROPERTY",
     "RoutinePreservationLeavesAutomaticCandidateUntouched",
     [(r'!.livePreserved = s.preserved,',
       r'!.livePreserved = s.preserved, !.automaticSlot = "exact",')]),
    ("ReconciliationDecisionSafety", "retirement-suppresses-routine-conflict", "INVARIANT",
     "RoutineDeletionPreservesChangedLocal",
     [(r'!.livePreserved = s.preserved,',
       r'!.livePreserved = IF s.automaticSlot \in {"free","exact"} THEN s.preserved ELSE {},')]),
    ("StorageTransitionSafety", "reference-unvalidated-key", "INVARIANT",
     "EveryInstalledCheckpointHasItsCredential",
     [(r'~NeedsKey(s.mode) \/ (s.targetKey = "new" /\ s.keyValidated)',
       r'~NeedsKey(s.mode) \/ (s.targetKey = "new")')]),
    ("StorageTransitionSafety", "remove-old-key-before-cutover", "INVARIANT",
     "EveryInstalledCheckpointHasItsCredential",
     [(r's.targetVerified /\ ~SaveAs(s.mode) /\ "old" \in s.keys',
       r'~SaveAs(s.mode) /\ "old" \in s.keys'),
      (r's.phase \in {"fresh","editing"}', r's.phase \in {"prepare","fresh","editing"}')]),
    ("StorageTransitionSafety", "save-as-aliases-source-key", "INVARIANT",
     "SaveAsDestinationCredentialIsIndependent",
     [(r'!.target = Live,' + "\n" +
       r'      !.targetKeyRef = IF NeedsKey(s.mode) THEN s.targetKey ELSE "none",',
       r'!.target = Live,' + "\n" +
       r'      !.targetKeyRef = IF NeedsKey(s.mode) THEN "old" ELSE "none",')]),
    ("StorageTransitionSafety", "ignore-export-fence", "PROPERTY",
     "PlaintextInstallRequiresCompleteStableExport",
     [(r"""(~Plain(s.mode) \/ (s.catalog = s.capturedCatalog /\
       s.files = s.snapshotFiles /\ s.files = s.desired /\ s.disclosure))""",
       'TRUE')]),
    ("ReconciliationDurabilityBridge", "omit-conflict-admission", "INVARIANT",
     "AdmissionCarriesEveryPublishedRow",
     [(r"!.pending = PublishedRows' \ Base",
       r'''!.pending = {row \in PublishedRows' \ Base: row[1] # "conflict"}''')]),
    ("ReconciliationDurabilityBridge", "barrier-with-wrong-wal-payload", "INVARIANT",
     "BarrierCarriesExactRows",
     [(r"ForIDs(b.pending,w'.appended \ w.appended)", '{}')]),
    ("ReconciliationDurabilityBridge", "omit-conflict-checkpoint-row", "INVARIANT",
     "InstalledCheckpointContainsDecision",
     [(r'!.checkpoint = Apply(Base,b.pending)',
       r'!.checkpoint = Apply(Base,{row \in b.pending: row[1] # "conflict"})')]),
    ("ReconciliationDurabilityBridge", "apply-drops-base-at-install", "INVARIANT",
     "InstalledCheckpointContainsDecision", DROP_BRIDGE_BASE),
    ("ReconciliationDurabilityBridge", "apply-drops-base-at-recovery-cleanup", "INVARIANT",
     "StartupCleanupHasActualCoverage", DROP_BRIDGE_BASE),
    ("ReconciliationDurabilityBridge", "apply-drops-base-at-reopen", "INVARIANT",
     "EditingContainsDurableDecision", DROP_BRIDGE_BASE),
    ("ReconciliationDurabilityBridge", "drop-restart-wal-payload", "INVARIANT",
     "EditingContainsDurableDecision",
     [(r'!.restartWAL = records', r'!.restartWAL = {}')]),
    ("ReconciliationDurabilityBridge", "settled-flag-without-recovery-files", "PROPERTY",
     "RecoveryInstallUsesActualSettledFiles",
     [(r'!.recoveryFiles = DecodeStartup', r'!.recoveryFiles = {}')]),
    ("ReconciliationDurabilityBridge", "dependency-drops-conflict", "INVARIANT",
     "AdmissionCarriesEveryPublishedRow",
     [("ReconciliationDecisionSafety.tla",
       r'!.livePreserved = s.preserved,', r'!.livePreserved = {},')]),
    ("ReconciliationDurabilityBridge", "dependency-suppresses-retired-routine-conflict", "INVARIANT",
     "EditingContainsDurableDecision",
     [("ReconciliationDecisionSafety.tla", r'!.livePreserved = s.preserved,',
       r'!.livePreserved = IF s.automaticSlot = "retired" THEN {} ELSE s.preserved,')]),
    ("ReconciliationDurabilityBridge", "dependency-edits-before-directory-sync", "INVARIANT",
     "EditingContainsDurableDecision",
     [("StartupSafety.tla",
       r's.phase = "header" /\ s.headerDurable /\ s.freshDirectoryDurable',
       r's.phase = "header" /\ s.headerDurable')]),
    ("ReconciliationDurabilityBridge", "dependency-ignores-current-witness", "PROPERTY",
     "StartupInstallUsesExactCurrent",
     [("StartupSafety.tla",
       r'''s.phase = "accessor" /\ ~s.cancelRequested
 /\ s.current = s.expected /\ s.root = s.capturedRoot''',
       r'''s.phase = "accessor" /\ ~s.cancelRequested
 /\ s.root = s.capturedRoot''')]),
    ("ReconciliationDurabilityBridge", "witness-crash-recovery", "INVARIANT",
     "NoCrashRecoveryEditing", []),
    ("ReconciliationDurabilityBridge", "witness-clean-reopen", "INVARIANT",
     "NoCleanReopenEditing", []),
    ("ReconciliationDurabilityBridge", "witness-retired-candidate-routine-recovery", "INVARIANT",
     "NoRetiredCandidateRoutineRecovery", []),
    ("ReconciliationDurabilityBridge", "witness-unchanged-source-and-import", "INVARIANT",
     "NoUnchangedSourceImportReopen", []),
    ("StorageStartupBridge", "read-source-instead-of-target", "INVARIANT",
     "HandoffUsesActualRootArtifacts",
     [(r'!.bytes = RootBytes(root)', r'!.bytes = t.source')]),
    ("StorageStartupBridge", "transplant-source-wal", "INVARIANT",
     "NoSourceWALTransplant",
     [(r'IF root = "source" /\ t.oldWAL THEN {3} ELSE {}',
       r'IF t.oldWAL THEN {3} ELSE {}')]),
    ("StorageStartupBridge", "reuse-source-credential", "INVARIANT",
     "HandoffUsesActualRootArtifacts",
     [(r'!.key = RootKey(root)', r'!.key = t.sourceKey')]),
    ("StorageStartupBridge", "skip-provider-conversion", "INVARIANT",
     "ProviderEditingRequiresCompletedConversion",
     [(r'~b.provider \/ b.format = "plaintext"', 'TRUE')]),
    ("StorageStartupBridge", "skip-credential-read", "INVARIANT",
     "AcceptedDataHasItsOwnCredential",
     [('BeginStartup ==\n' + r' /\ b.phase = "reading" /\ b.credentialRead',
       'BeginStartup ==\n' + r' /\ b.phase = "reading"')]),
    ("StorageStartupBridge", "drop-source-wal-on-replay", "INVARIANT",
     "ReopenedDataMatchesCrashArtifacts",
     [(r'b.bytes \cup (IF 2 \in r.store THEN b.walBytes ELSE {})', 'b.bytes')]),
    ("StorageStartupBridge", "witness-unverified-target-reopen", "INVARIANT",
     "UnverifiedInstalledTargetCanReopen", []),
    ("StorageStartupBridge", "witness-old-source-wal-recovery", "INVARIANT",
     "OldSourceWALCanReopen", []),
    ("StorageStartupBridge", "witness-converted-provider-reopen", "INVARIANT",
     "ConvertedProviderCanReopen", []),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--java", default="java")
    parser.add_argument("--jar", required=True, type=Path)
    parser.add_argument("--model", action="append", choices=MODELS)
    parser.add_argument("--timeout", type=int, default=120)
    args = parser.parse_args()
    source = Path(__file__).resolve().parent
    output = Path(tempfile.mkdtemp(prefix="notation-tla-migration-check-"))
    print(f"Results: {output}", flush=True)
    results = []

    def run(model, label, mutations=(), assertion=None):
        directory = output / label
        directory.mkdir()
        # INSTANCE bridges execute working dependencies. Mutations can target
        # the handoff or an imported action; production files remain untouched.
        modules = {p.name: p.read_text() for p in source.glob("*.tla")}
        for edit in mutations:
            filename, before, after = (f"{model}.tla", *edit) if len(edit) == 2 else edit
            count = modules[filename].count(before)
            if count != 1:
                raise AssertionError(f"{label}: mutation must match once, got {count}: {before!r}")
            modules[filename] = modules[filename].replace(before, after, 1)
        for filename, body in modules.items():
            (directory / filename).write_text(body)
        config = (source / f"{model}.cfg").read_text()
        if assertion:
            config = f"SPECIFICATION Spec\n{assertion[0]} {assertion[1]}\nCHECK_DEADLOCK FALSE\n"
        (directory / f"{model}.cfg").write_text(config)
        command = [args.java, "-Xmx1g", "-XX:+UseParallelGC", "-jar",
                   str(args.jar.resolve()), "-workers", "4", "-lncheck", "final",
                   "-coverage", "60", "-metadir", str(directory / "states"),
                   "-config", f"{model}.cfg", f"{model}.tla"]
        with (directory / "tlc.log").open("w") as log:
            completed = subprocess.run(command, cwd=directory, stdout=log,
                                       stderr=subprocess.STDOUT, timeout=args.timeout)
        text = (directory / "tlc.log").read_text()
        if assertion:
            violation = re.search(
                rf"(?:Invariant|Action property) {re.escape(assertion[1])}\b.*violated",
                text) or "Temporal properties were violated" in text
            if completed.returncode == 0 or not violation:
                raise AssertionError(f"{label}: expected {assertion[1]} counterexample; see {directory}")
        else:
            if (completed.returncode != 0 or
                    "Model checking completed. No error has been found." not in text or
                    "0 states left on queue." not in text):
                raise AssertionError(f"{label}: exhaustive check failed; see {directory}")
            dead_actions = re.findall(r"^<([^>]+)>: 0:0$", text, re.MULTILINE)
            if dead_actions:
                raise AssertionError(f"{label}: unexercised action(s): {dead_actions}")
        counts = re.findall(r"(\d+) states generated, (\d+) distinct states found, 0 states left on queue", text)
        results.append(dict(model=model, label=label, assertion=assertion,
                            counts=counts[-1] if counts else None,
                            outcome=("counterexample" if mutations else "witness")
                            if assertion else "exhaustive-pass"))
        (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        print(f"PASS {label}" + (f" -> {assertion[1]}" if assertion else ""), flush=True)

    selected = args.model or MODELS
    for model in selected:
        run(model, model)
        for item in CASES:
            owner, label, kind, name, mutations = item
            if owner == model:
                run(model, f"{model}-{label}", mutations, (kind, name))
    print(f"All {len(results)} checks passed; logs and counterexamples: {output}", flush=True)


if __name__ == "__main__":
    main()
