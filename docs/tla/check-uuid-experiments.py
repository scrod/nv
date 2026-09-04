#!/usr/bin/env python3
"""Bounded UUID-policy experiments, reachability witnesses, and mutations.

Uses the existing migration runner's disposable-copy/logging convention.
Expected counterexamples are hypothesis rejections, not successful policies.
Timeouts, parser failures, and unrelated assertion failures never count.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile

RACE = "UUIDAssignmentRace"
LAB = "UUIDAssociationLab"
CAUSAL = "CausalIncarnationSafety"
INTENT = "DeletionIntentTransportSafety"
HANDSHAKE = "LiveBindingHandshake"
COMPOSITION = "BindingIntentComposition"
RETIREMENT = "IntentRetirementLab"
TEMPORAL = {"EventualAgreement", "EveryAttemptTerminates", "EventuallyBound", "EventuallyFinished",
            "EventuallyReceived", "EventuallyApplied"}


def experiments():
    # model, label, policy, mode, assertion, expected outcome, mutations
    for scenario in ("current", "staleRead"):
        yield RETIREMENT, scenario + "-safety", "pinnedSnapshot", scenario, "Safety", "pass", []
    yield RETIREMENT, "no-retirement", "retain", "current", "NeverCollectedAll", "pass", []
    for policy, scenario, assertion in (
            ("maxAck", "current", "NoAckForUnseenOperation"),
            ("retain", "current", "NoBackupResurrection"),
            ("acksOnly", "current", "NoNewcomerHistoryLoss"),
            ("acksOnly", "current", "RetiredHistoryStillAvailable"),
            ("snapshot", "current", "NoBackupResurrection"),
            ("snapshot", "staleRead", "NoNewcomerHistoryLoss")):
        yield RETIREMENT, scenario + "-" + assertion, policy, scenario, assertion, "counterexample", []
    for assertion in ("NeverCollectedAll", "NeverRejoinedAfterCollection",
                      "NeverBootstrappedAfterCollection", "NeverRejectedStaleSnapshot"):
        yield RETIREMENT, "witness-" + assertion, "pinnedSnapshot", "staleRead", assertion, "counterexample", []
    yield RETIREMENT, "trust-stale-bootstrap", "pinnedSnapshot", "staleRead", "NoNewcomerHistoryLoss", "counterexample", [
        ('r.fetched /\\ r.observed = Events', 'r.fetched')]
    yield RETIREMENT, "resume-before-bootstrap", "pinnedSnapshot", "staleRead", "NoBackupResurrection", "counterexample", [
        ('!.ready = Policy # "pinnedSnapshot"', '!.ready = TRUE')]
    for scenario in ("lifecycle", "copy", "retarget", "offline"):
        yield COMPOSITION, scenario + "-safety", "guarded", scenario, "Safety", "pass", []
    for policy, scenario, assertion in (
            ("tagBinding", "copy", "NoWrongIncarnationDeletion"),
            ("unfencedBinding", "retarget", "NoWrongIncarnationDeletion"),
            ("guarded", "relay", "NoWrongIncarnationDeletion"),
            ("guarded", "hiddenRestore", "NoWrongIncarnationDeletion"),
            ("reuseBirth", "lifecycle", "NoWrongIncarnationDeletion"),
            ("volatileReceipt", "lifecycle", "NoForgottenReceipt"),
            ("earlyCleanup", "clean", "NoForgottenOutbox"),
            ("noPublicationFence", "lifecycle", "NoWrongIncarnationDeletion"),
            ("noEditPreservation", "lifecycle", "NoLostDurableEdit")):
        yield COMPOSITION, scenario + "-" + assertion, policy, scenario, assertion, "counterexample", []
    for policy, assertion, expected in (
            ("guarded", "EventuallyReceived", "pass"), ("guarded", "EventuallyApplied", "pass"),
            ("trashOnly", "Safety", "pass"), ("trashOnly", "EventuallyReceived", "counterexample"),
            ("deferBinding", "Safety", "pass"), ("deferBinding", "EventuallyApplied", "counterexample")):
        yield COMPOSITION, "clean-" + assertion, policy, "clean", assertion, expected, []
    for assertion in ("NeverApplied", "NeverPreservedEdit", "NeverRecoveredDecision",
                      "NeverKeptRestoration", "NeverReplayedConsumedIntent"):
        yield COMPOSITION, "witness-" + assertion, "guarded", "lifecycle", assertion, "counterexample", []
    yield COMPOSITION, "witness-NeverEditedWhileUnbound", "guarded", "copy", "NeverEditedWhileUnbound", "counterexample", []
    yield COMPOSITION, "forget-recovered-alias", "guarded", "lifecycle", "DurableAliasesSurvive", "counterexample", [
        ('!.down = FALSE, !.note = s.wal,', '!.down = FALSE, !.note = [s.wal EXCEPT !.aliases = {2}],')]
    for scenario in ("clean", "copy", "retarget", "offline"):
        yield HANDSHAKE, scenario + "-safety", "fenced", scenario, "NoFalseBinding", "pass", []
    for policy, scenario in (("tag", "copy"), ("challenge", "retarget"),
                             ("reusedNonce", "stale"), ("fenced", "relay")):
        yield HANDSHAKE, scenario + "-rejection", policy, scenario, "NoFalseBinding", "counterexample", []
    for policy, scenario, expected in (("fenced", "clean", "pass"),
                                        ("defer", "clean", "counterexample"),
                                        ("fenced", "offline", "counterexample")):
        yield HANDSHAKE, scenario + "-progress", policy, scenario, "EventuallyBound", expected, []
    for scenario, assertion in (("clean", "NeverBound"), ("copy", "NeverParked"),
                                ("relay", "NeverBoundAfterRelay"), ("retarget", "NeverCopiedAfterAck")):
        yield HANDSHAKE, scenario + "-witness-" + assertion, "fenced", scenario, assertion, "counterexample", []
    yield HANDSHAKE, "remove-endpoint-fence", "fenced", "retarget", "NoFalseBinding", "counterexample", [
        ('Policy # "fenced" \\/ b.anchor = b.handle', 'TRUE')]
    yield HANDSHAKE, "reuse-attempt-nonce", "fenced", "stale", "NoFalseBinding", "counterexample", [
        ('Nonce == IF Policy = "reusedNonce" THEN 1 ELSE 2', 'Nonce == 1')]
    yield INTENT, "baseline", "retain", "close", None, "pass", []
    for policy, assertion in (("forgetOnPurge", "NoForgottenAcceptedIntent"),
                              ("ignoreBirth", "NoOldIntentDeletesRestoration")):
        yield INTENT, assertion, policy, "close", assertion, "counterexample", []
    for assertion in ("NeverAppliedAfterArtifactLoss", "NeverRecoveredReceipt",
                      "NeverMissedPurgedIntent", "NeverPreservedRestoration"):
        yield INTENT, "witness-" + assertion, "retain", "close", assertion, "counterexample", []
    yield INTENT, "forget-durable-receipt", "retain", "close", "NoForgottenAcceptedIntent", "counterexample", [
        ('!.down = TRUE, !.live = 0, !.captured = 0,', '!.down = TRUE, !.live = 0, !.captured = 0, !.receipt = 0,')]
    yield INTENT, "delete-on-absence", "retain", "close", "NoUnexplainedDeletion", "counterexample", [
        ('s.live # 0 /\\ s.receipt = 1', 's.live # 0'),
        ('Policy = "ignoreBirth" \\/ s.live = s.receipt', 'Policy = "ignoreBirth" \\/ s.live = 1')]
    yield LAB, "current-snapshot-baseline", "currentSnapshot", "close", None, "pass", []
    yield LAB, "reject-portable-provider-equality", "providerEquality", "close", "NoFalseSeparation", "counterexample", []
    for assertion in ("NeverJoined", "NeverSeparated", "NeverDeferredIndependentImport", "NeverReopened"):
        yield LAB, "witness-" + assertion, "currentSnapshot", "close", assertion, "counterexample", []
    yield LAB, "trust-remote-claims", "currentSnapshot", "close", "NoFalseJoin", "counterexample", [
        ('IF o.sameObservationFrame /\\ o.leftScope = o.rightScope /\\',
         'IF TRUE /\\ o.leftScope = o.rightScope /\\'),
        ('[] c = "hiddenCopy" -> [BaseObservation EXCEPT !.rightID = 1,',
         '[] c = "hiddenCopy" -> [BaseObservation EXCEPT !.rightScope = 1, !.rightItem = 11, !.rightID = 1,')]
    for scenario in ("restore", "gap"):
        yield CAUSAL, scenario + "-baseline", "causal", scenario, None, "pass", []
    for policy, scenario, assertion in (
            ("uuidDelete", "restore", "NoLostProtectedBirth"),
            ("dropContext", "restore", "NoResurrectionAfterObservedRemoval"),
            ("registerOnly", "restore", "NoResurrectionAfterObservedRemoval"),
            ("maxClock", "gap", "NoLostProtectedBirth")):
        yield CAUSAL, assertion, policy, scenario, assertion, "counterexample", []
    for scenario, assertion in (("restore", "NeverPreservedFreshRestore"),
                                ("gap", "NeverMergedUnseenBirths"),
                                ("restore", "NeverRecoveredDeletion")):
        yield CAUSAL, "witness-" + assertion, "causal", scenario, assertion, "counterexample", []
    yield CAUSAL, "reuse-birth", "causal", "restore", "NoResurrectionAfterObservedRemoval", "counterexample", [
        ('after == Envelope({2},{1,2},s.replica[2].deleted)', 'after == Envelope({1},{1},s.replica[2].deleted)')]
    yield CAUSAL, "delete-all-births", "causal", "restore", "NoLostProtectedBirth", "counterexample", [
        (r'kept == s.replica[1].live \ {1}', 'kept == {}')]
    yield CAUSAL, "drop-exchange", "causal", "gap", "CompleteExchangeAgrees", "counterexample", [
        ('after == Merge(s.replica[h],other)', 'after == s.replica[h]')]
    for model, policy in ((RACE, "scoped"), (RACE, "stable"), (LAB, "evidence")):
        yield model, "baseline", policy, "close", None, "pass", []
    for policy in ("database", "restamp", "xattr", "eagerMinimum", "minimum", "aliases", "scoped", "stable"):
        for assertion in ("NoDuplicateLogicalFile", "RecoveryDoesNotForkIdentity",
                          "WALIdentityStillRepresented", "CheckpointRemembersCommittedIDs",
                          "DatabaseIdentityStable", "EventualAgreement"):
            holds = (policy in {"scoped", "stable"})
            if assertion == "WALIdentityStillRepresented":
                holds = policy not in {"xattr", "eagerMinimum", "minimum"}
            if assertion == "CheckpointRemembersCommittedIDs":
                holds = policy not in {"xattr", "eagerMinimum", "minimum"}
            if assertion == "DatabaseIdentityStable":
                holds = policy in {"database", "restamp", "stable"}
            if assertion == "EventualAgreement":
                holds = policy not in {"database", "restamp", "eagerMinimum"}
            mode = "settle" if assertion == "EventualAgreement" else "close"
            yield RACE, assertion, policy, mode, assertion, "pass" if holds else "counterexample", []
    for policy in ("database", "xattr", "minimum", "fingerprint", "aliases",
                   "incarnation", "omission", "evidence"):
        for assertion in ("NoFalseJoin", "NoFalseSeparation", "NoFalseDeletion"):
            holds = (policy == "evidence" or
                     (policy == "incarnation" and assertion == "NoFalseSeparation"))
            yield LAB, assertion, policy, "close", assertion, "pass" if holds else "counterexample", []
    for assertion in ("NeverReachedIndependentImports", "NeverReachedMerge", "NeverReachedRecovery"):
        yield RACE, "witness-" + assertion, "scoped", "close", assertion, "counterexample", []
    yield RACE, "witness-distinct-live-IDs", "stable", "close", "NeverMergedWithDistinctLiveIDs", "counterexample", []
    for assertion in ("NeverJoined", "NeverSeparated", "NeverDeleted", "NeverPreservedEdit",
                      "NeverKeptRestored", "NeverReopened", "NoDeferral"):
        yield LAB, "witness-" + assertion, "evidence", "close", assertion, "counterexample", []
    # Mutate mechanics; keep the independent assertions unchanged.
    yield RACE, "drop-incoming", "scoped", "close", "NoPayloadLoss", "counterexample", [
        (r"Combine(s.captured[h] \cup s.incoming[h])", "Combine(s.captured[h])")]
    yield RACE, "forget-recovery-aliases", "scoped", "close", "RecoveryDoesNotForkIdentity", "counterexample", [
        (r"Combine(s.checkpoint \cup s.wal[h])", r"ByID(s.checkpoint \cup s.wal[h])")]
    yield RACE, "forget-serialized-aliases", "scoped", "close", "CheckpointRemembersCommittedIDs", "counterexample", [
        ('!.captured[h] = {Row(s.id[h],{h},s.aliases[h])}',
         '!.captured[h] = {Row(s.id[h],{h},{s.id[h]})}'),
        ('!.result[h] = {Row(s.id[h],{h},s.aliases[h])}',
         '!.result[h] = {Row(s.id[h],{h},{s.id[h]})}')]
    yield RACE, "overwrite-changed-checkpoint", "scoped", "close", "ExactCheckpointCAS", "counterexample", [
        ("IF s.expected[h] = s.version", "IF TRUE")]
    yield LAB, "trust-copied-proof", "evidence", "close", "NoFalseJoin", "counterexample", [
        ('o.proof = "same" -> "join"', 'o.proof # "unknown" -> "join"')]
    yield LAB, "false-positive-proof-input", "evidence", "close", "NoFalseJoin", "counterexample", [
        ('[] c \\in {"unknownSharedTag","copiedTagNewUUID"} ->\n       [BaseObservation EXCEPT !.leftTag = 2, !.rightTag = 2]',
         '[] c \\in {"unknownSharedTag","copiedTagNewUUID"} ->\n       [BaseObservation EXCEPT !.leftTag = 2, !.rightTag = 2, !.proof = "same"]')]
    yield LAB, "ignore-fence", "evidence", "close", "NoStalePublication", "counterexample", [
        ('Publish ==\n /\\ s.phase = "prepared" /\\ s.fence = s.capturedFence',
         'Publish ==\n /\\ s.phase = "prepared"')]
    yield LAB, "drop-delete-edit-copy", "evidence", "close", "NoPayloadLoss", "counterexample", [
        ('IF o.leftBody # o.baseBody THEN {{"L"}} ELSE {}', '{}')]
    yield LAB, "empty-checkpoint", "evidence", "close", "CheckpointMatchesPublication", "counterexample", [
        ('!.checkpoint = s.durableGroups', '!.checkpoint = {}')]
    yield LAB, "drop-deferred-inputs", "evidence", "close", "DeferredAndRejectedRetainInputs", "counterexample", [
        ('!.phase = "deferred"]', '!.phase = "deferred", !.captured = BaseObservation]')]
    yield LAB, "stall-unknown-evidence", "evidence", "close", "EveryAttemptTerminates", "counterexample", [
        ('Defer ==\n /\\ s.phase = "prepared"', 'Defer ==\n /\\ FALSE /\\ s.phase = "prepared"')]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--java", default="java")
    parser.add_argument("--jar", required=True, type=Path)
    parser.add_argument("--timeout", type=int, default=60)
    parser.add_argument("--only", help="Run labels containing this substring")
    args = parser.parse_args()
    source = Path(__file__).resolve().parent
    output = Path(tempfile.mkdtemp(prefix="notation-tla-uuid-"))
    print(f"Results: {output}", flush=True)
    results = []
    for model, label, policy, mode, assertion, expected, mutations in experiments():
        label = f"{model}-{policy}-{label}"
        if args.only and args.only not in label:
            continue
        directory = output / label
        directory.mkdir()
        body = (source / f"{model}.tla").read_text()
        for before, after in mutations:
            if body.count(before) != 1:
                raise AssertionError(f"{label}: mutation must match exactly once: {before!r}")
            body = body.replace(before, after, 1)
        (directory / f"{model}.tla").write_text(body)
        if model == COMPOSITION:
            (directory / f"{HANDSHAKE}.tla").write_text((source / f"{HANDSHAKE}.tla").read_text())
        if assertion:
            kind = "PROPERTY" if assertion in TEMPORAL | {"ExactCheckpointCAS"} else "INVARIANT"
            spec = "FairSpec" if assertion in TEMPORAL else "Spec"
            config = f'CONSTANT Policy = "{policy}"\n'
            if model == RACE:
                config += f'CONSTANT Mode = "{mode}"\n'
            if model in {CAUSAL, HANDSHAKE, COMPOSITION, RETIREMENT}:
                config += f'CONSTANT Scenario = "{mode}"\n'
            config += f"SPECIFICATION {spec}\nINVARIANT TypeOK\n{kind} {assertion}\nCHECK_DEADLOCK FALSE\n"
        else:
            config = (source / f"{model}.cfg").read_text()
            if model == LAB:
                config = config.replace('Policy = "evidence"', f'Policy = "{policy}"')
            if model == CAUSAL:
                config = config.replace('Scenario = "restore"', f'Scenario = "{mode}"')
            if policy == "stable":
                config = config.replace('Policy = "scoped"', 'Policy = "stable"')
                config += "INVARIANT DatabaseIdentityStable\n"
        (directory / f"{model}.cfg").write_text(config)
        command = [args.java, "-Xmx1g", "-XX:+UseParallelGC", "-jar", str(args.jar.resolve()),
                   "-workers", "4", "-lncheck", "final", "-coverage", "60",
                   "-metadir", str(directory / "states"), "-config", f"{model}.cfg", f"{model}.tla"]
        with (directory / "tlc.log").open("w") as log:
            completed = subprocess.run(command, cwd=directory, stdout=log,
                                       stderr=subprocess.STDOUT, timeout=args.timeout)
        text = (directory / "tlc.log").read_text()
        counts = re.findall(r"(\d+) states generated, (\d+) distinct states found, 0 states left on queue", text)
        exhaustive = (completed.returncode == 0 and counts and
                      "Model checking completed. No error has been found." in text)
        violation = assertion and re.search(
            rf"(?:Invariant|Action property) {re.escape(assertion)}\b.*violated", text)
        # There is exactly ONE temporal property in this configuration.
        if assertion in TEMPORAL:
            violation = ("Temporal properties were violated" in text and
                         "The following behavior constitutes a counter-example" in text)
        outcome = "pass" if exhaustive else "counterexample" if violation and completed.returncode else "error"
        result = dict(model=model, label=label, policy=policy, assertion=assertion,
                      expected=expected, outcome=outcome, counts=counts[-1] if exhaustive else None)
        results.append(result)
        (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        if outcome != expected:
            raise AssertionError(f"{label}: expected {expected}, got {outcome}; see {directory}")
        if not assertion:
            dead = re.findall(r"^<([^>]+)>: 0:0$", text, re.MULTILINE)
            if model == CAUSAL and mode == "gap":
                dead = [name for name in dead if not name.startswith(("DeleteOriginal ", "RestoreFresh "))]
            if dead:
                raise AssertionError(f"{label}: unexercised actions: {dead}")
        print(f"{outcome.upper()} {label}", flush=True)
    if not results:
        raise AssertionError("No experiments selected")
    print(f"All {len(results)} expected outcomes verified; logs and traces: {output}", flush=True)


if __name__ == "__main__":
    main()
