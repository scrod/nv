#!/usr/bin/env python3
"""Retired proposal-4 UUID assignment checks; not segment acceptance coverage."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile

RACE = "UUIDAssignmentRace"
TEMPORAL = {"EventualAgreement"}


def experiments():
    for model, policy in ((RACE, "scoped"), (RACE, "stable")):
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
    for assertion in ("NeverReachedIndependentImports", "NeverReachedMerge", "NeverReachedRecovery"):
        yield RACE, "witness-" + assertion, "scoped", "close", assertion, "counterexample", []
    yield RACE, "witness-distinct-live-IDs", "stable", "close", "NeverMergedWithDistinctLiveIDs", "counterexample", []
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--java", default="java")
    parser.add_argument("--jar", required=True, type=Path)
    parser.add_argument("--timeout", type=int, default=60)
    parser.add_argument("--only", help="Run labels containing this substring")
    args = parser.parse_args()
    source = Path(__file__).resolve().parent
    output = Path(tempfile.mkdtemp(prefix="notation-tla-retired-uuid-"))
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
        if assertion:
            kind = "PROPERTY" if assertion in TEMPORAL | {"ExactCheckpointCAS"} else "INVARIANT"
            spec = "FairSpec" if assertion in TEMPORAL else "Spec"
            config = f'CONSTANT Policy = "{policy}"\n'
            if model == RACE:
                config += f'CONSTANT Mode = "{mode}"\n'
            config += f"SPECIFICATION {spec}\nINVARIANT TypeOK\n{kind} {assertion}\nCHECK_DEADLOCK FALSE\n"
        else:
            config = (source / f"{model}.cfg").read_text()
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
            if dead:
                raise AssertionError(f"{label}: unexercised actions: {dead}")
        print(f"{outcome.upper()} {label}", flush=True)
    if not results:
        raise AssertionError("No experiments selected")
    print(f"All {len(results)} expected outcomes verified; logs and traces: {output}", flush=True)


if __name__ == "__main__":
    main()
