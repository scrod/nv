#!/usr/bin/env python3
"""Measure selected initial-bootstrap tests' sensitivity to production guard faults.

Runs an unchanged baseline and isolated source mutations in a temporary package.
Artifacts retain source/fixture hashes, exact patches, commands and complete logs.
"""
import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path("Sources/NVStorageCore/InitialBootstrapValidationV1.swift")
TESTS = Path("Tests/NVStorageCoreTests/InitialBootstrapValidationTests.swift")
# Each assertion has a valid companion in the same filtered baseline.
MUTATIONS = [
    ("M07-incomplete-frontier", "guard Set(action.scopeParents) == maxima else {",
     "guard Set(action.scopeParents).isSubset(of: maxima) else {",
     "scopeClaimsNeedTheirCompleteDeclaredCausalBasis", "missingMaximum",
     "#expect(throws: InitialBootstrapValidationError.invalidActionHistory)"),
    ("snapshot-wrong-body", "value == row.value else", "true else",
     "snapshotMustMatchExactImportedRecord", "wrongBody",
     "#expect(throws: InitialBootstrapValidationError.invalidSnapshot)"),
    ("completion-missing-branch", "represented == Set(operations.keys)",
     "represented.isSubset(of: Set(operations.keys))",
     "authenticatedInitialHistoryCanStillBeWrong", "coverage", "#expect(throws: expected)"),
    ("unchecked-values-digest", "guard try hasher.finish() == digest, UInt64(rows.count) == count else {",
     "guard UInt64(rows.count) == count else {",
     "authenticatedInitialHistoryCanStillBeWrong", "digest", "#expect(throws: expected)"),
    ("wrong-genesis-pin", "              payloads[descriptor.genesis]!.operations.contains(where: { $0.operation.id == genesis.id }),\n", "",
     "exactDescriptorGenesisIsNotJustAnyObjectFromTheCollection", None,
     "#expect(throws: InitialBootstrapValidationError.invalidCommitment)"),
    ("wrong-descriptor-key", "guard descriptor.collection == expectedCollection,\n              (descriptor.keyID?.bytes ?? [UInt8](repeating: 0, count: 16)) == protection.keyIDBytes else {",
     "guard descriptor.collection == expectedCollection else {",
     "matchingEncryptedObjectsCannotBlessADifferentDescriptorKeyID", None,
     "#expect(throws: CanonicalEncodingError.wrongScope)"),
    ("M22-reject-valid-context", "guard descriptor.collection == expectedCollection,",
     "guard descriptor.collection != expectedCollection,",
     "authenticatedInitialHistoryCanStillBeWrong", "valid", "#require(try? f.validate(root))"),
]
REQUIRED = sorted({m[3] for m in MUTATIONS} | {"completeInitialImportValidatesAcrossObjects"})


def sha(path):
    return hashlib.file_digest(path.open("rb"), "sha256").hexdigest()


def replace_once(text, before, after):
    if before == after or text.count(before) != 1:
        raise ValueError("Mutation must alter exactly one source occurrence")
    return text.replace(before, after)


def assertion_line(source, function, assertion):
    lines = source.splitlines()
    start = next(i for i, s in enumerate(lines) if re.search(rf"\bfunc {re.escape(function)}\(", s))
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("@Test")), len(lines))
    hits = [i + 1 for i in range(start, end) if assertion in lines[i]]
    if len(hits) != 1:
        raise ValueError(f"Ambiguous/missing assertion for {function}: {hits}")
    return hits[0]


def discovered(log):
    return set(re.findall(r"Test (\w+)\([^\n]*\) started\.", log))


def classify(code, log, function, line, argument, positive=False):
    if "Build complete!" not in log or "Test run started." not in log:
        return "compile-blocked" if re.search(r"\.swift:\d+:\d+: error:", log) else "unrelated failure"
    if not set(REQUIRED).issubset(discovered(log)):
        return "inconclusive: required test missing"
    if code == 0:
        return "survived"
    # Credit the exact expected-error assertion, not a fixture/setup throw or
    # another error category. Swift Testing includes parameter values on issues.
    message = "Expectation failed:" if positive else "an error was expected but none was thrown"
    issues = [s for s in log.splitlines() if f"Test {function}(" in s and
              "recorded an issue" in s and f" at {TESTS.name}:{line}:" in s and message in s]
    if argument is not None:
        issues = [s for s in issues if f'"{argument}"' in s]
    return "targeted runtime failure" if issues else "unrelated failure"


def self_test():
    for before, after, text in [("x", "x", "x"), ("x", "y", "xx"), ("x", "y", "z")]:
        try:
            replace_once(text, before, after)
        except ValueError:
            pass
        else:
            raise AssertionError("No-op or invalid mutation was accepted")
    assert replace_once("x", "x", "y") == "y"
    starts = "Build complete!\nTest run started.\n" + "\n".join(f"Test {t}() started." for t in REQUIRED)
    issue = f'Test {REQUIRED[0]}() recorded an issue with 1 argument fault → "bad" at {TESTS.name}:123:1: Expectation failed: an error was expected but none was thrown'
    assert classify(1, starts + issue, REQUIRED[0], 123, "bad") == "targeted runtime failure"
    assert classify(1, starts + issue, REQUIRED[0], 124, "bad") == "unrelated failure"
    assert classify(1, starts + issue, REQUIRED[0], 123, "other") == "unrelated failure"
    assert classify(0, starts, REQUIRED[0], 123, None) == "survived"
    assert classify(1, "compiler unavailable", REQUIRED[0], 123, None) == "unrelated failure"
    assert classify(0, "Build complete!\nTest run started.", REQUIRED[0], 123, None).startswith("inconclusive")
    assert assertion_line('@Test func example() {\n    #expect(true)\n}', "example", "#expect(true)") == 2


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test-only", action="store_true")
    parser.add_argument("--configuration", choices=["debug", "release"], default="debug")
    args = parser.parse_args()
    self_test()
    test_source = (ROOT / "NVStorage" / TESTS).read_text()
    original = (ROOT / "NVStorage" / SOURCE).read_text()
    for _, before, after, function, _, assertion in MUTATIONS:
        replace_once(original, before, after)
        assertion_line(test_source, function, assertion)
    print("PASS: mutation runner self-checks", flush=True)
    if args.self_test_only:
        return 0
    artifacts = Path(tempfile.mkdtemp(prefix="nv-bootstrap-mutations-"))
    os.environ['PKG_CONFIG_PATH'] = str(ROOT/'NVStorage/.deps/sqlcipher/lib/pkgconfig') + os.pathsep + os.environ.get('PKG_CONFIG_PATH', '')
    package = artifacts / "NVStorage"
    print(f"Artifacts: {artifacts}", flush=True)
    shutil.copytree(ROOT / "NVStorage", package, ignore=shutil.ignore_patterns(".build*", ".swiftpm", ".deps"))
    # Reuse only dependency downloads. Build products are compiled in isolation,
    # so neither the baseline nor a mutant can execute a stale workspace binary.
    old_build = ROOT / "NVStorage/.build"
    for folder in ["checkouts", "repositories"]:
        if (old_build / folder).is_dir():
            shutil.copytree(old_build / folder, package / ".build" / folder)
    command = ["swift", "test", "--build-system", "native", "--package-path", str(package), "-c", args.configuration,
               "--filter", "|".join(REQUIRED)]
    report = {
        "configuration": args.configuration, "required_tests": REQUIRED, "command": command,
        "compiler": subprocess.check_output(["swift", "--version"], text=True, stderr=subprocess.STDOUT),
        "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "inputs": {str(p.relative_to(package)): sha(p) for p in package.rglob("*")
                   if p.is_file() and ".build" not in p.parts},
        "runner_sha256": sha(Path(__file__)), "results": [],
    }
    original = (package / SOURCE).read_text()
    test_source = (package / TESTS).read_text()

    def run(name):
        print(f"Running {name}…", flush=True)
        log_path = artifacts / f"{name}.log"
        try:
            with log_path.open("w") as output:
                completed = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, timeout=600)
            code = completed.returncode
        except subprocess.TimeoutExpired:
            code = None
        log = log_path.read_text()
        binaries = {str(p.relative_to(package)): sha(p) for p in (package / ".build").rglob("*")
                    if p.is_file() and (p.name == "NVStoragePackageTests" or p.name.endswith(".xctest"))}
        return code, log, {"name": name, "returncode": code, "log": str(log_path),
                           "source_sha256": sha(package / SOURCE), "binaries": binaries}

    def save():
        (artifacts / "results.json").write_text(json.dumps(report, indent=2) + "\n")

    code, log, result = run("baseline")
    baseline_ok = code == 0 and set(REQUIRED).issubset(discovered(log)) and bool(result["binaries"])
    result["verdict"] = "passed" if baseline_ok else "invalid baseline"
    report["results"].append(result)
    save()
    if not baseline_ok:
        print("FAIL: baseline or required test discovery; inspect baseline.log", flush=True)
        return 1
    all_detected = True
    for name, before, after, function, argument, assertion in MUTATIONS:
        changed = replace_once(original, before, after)
        line = assertion_line(test_source, function, assertion)
        (artifacts / f"{name}.patch").write_text("".join(difflib.unified_diff(
            original.splitlines(keepends=True), changed.splitlines(keepends=True),
            fromfile=str(SOURCE), tofile=str(SOURCE))))
        (package / SOURCE).write_text(changed)
        code, log, result = run(name)
        result.update(test=function, argument=argument, assertion_line=line,
                      verdict="inconclusive: timeout" if code is None else classify(
                          code, log, function, line, argument, positive=name.startswith("M22-")))
        report["results"].append(result)
        save()
        print(f'{name}: {result["verdict"]}', flush=True)
        all_detected &= result["verdict"] == "targeted runtime failure"
    # Leave the isolated source ready for replay from its recorded baseline.
    (package / SOURCE).write_text(original)
    return 0 if all_detected else 1


if __name__ == "__main__":
    raise SystemExit(main())
