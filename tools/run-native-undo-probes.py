#!/usr/bin/env python3
"""Run synthetic AppKit undo scenarios in isolated bounded processes.

No NV launch, notes, cloud files, general pasteboard, or UI automation. A pass
means the named concrete checks passed, not that every observed rule is safe.
Remote body-replacement observations intentionally expose unsupported usage.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

CASES = (
    "typing", "capture-passive", "capture-break", "marker-first", "marker-every", "marker-before",
    "metadata", "metadata-first", "metadata-before", "selection-backspace", "paste-format", "composition", "replacement",
    "remote-storage", "remote-notified", "remote-reset", "remote-title",
    "refusal-inside", "refusal-preflight", "nested-command",
    "auto-marker-typing", "auto-marker-selection", "auto-marker-format",
    "auto-marker-capture", "auto-marker-replacement", "auto-marker-composition",
    "span-partial-undo", "span-format", "span-branch", "capture-same-event", "redo-new-edit",
    "shared-roundtrip", "shared-alternate", "shared-alternate-break", "shared-retarget",
    "shared-close-origin", "shared-close-all", "shared-selection-layout", "shared-refusal",
    "shared-paste-format", "shared-composition", "shared-replacement",
    "shared-close-all-bare", "shared-empty-lifetime", "shared-composition-peer", "shared-composition-guard",
    "shared-undo-refusal", "shared-composition-close", "shared-composition-cancel",
    "shared-close-all-format", "shared-retarget-all-control",
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--only", default="")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--interactive", action="store_true", help="opt-in synthetic keyboard window; close to finish")
    parser.add_argument("--interactive-shared", action="store_true", help="opt-in two-window keyboard/IME probe; close both to finish")
    args = parser.parse_args()
    directory = args.output or Path(tempfile.mkdtemp(prefix="nv-native-undo-"))
    directory.mkdir(parents=True, exist_ok=True)
    print(f"Artifacts: {directory}", flush=True)
    results = []
    interactive = args.interactive or args.interactive_shared
    selected = ["shared-interactive" if args.interactive_shared else "interactive"] if interactive else [name for name in CASES if args.only in name]
    if not selected:
        parser.error("no matching cases")
    for name in selected:
        try:
            child = subprocess.run([str(args.binary.resolve()), name], text=True,
                                   capture_output=True, timeout=600 if interactive else 20)
            (directory / f"{name}.jsonl").write_text(child.stdout)
            (directory / f"{name}.stderr").write_text(child.stderr)
            records = [json.loads(line) for line in child.stdout.splitlines()]
            summaries = [r for r in records if "result" in r]
            passed = child.returncode == 0 and len(summaries) == 1 and summaries[0]["result"]
            result = dict(name=name, passed=passed, exit=child.returncode,
                          observational=interactive or (bool(summaries) and not summaries[0]["checks"]),
                          summary=summaries, observations=[r for r in records if "observation" in r])
        except (subprocess.TimeoutExpired, ValueError, OSError) as exc:
            result = dict(name=name, passed=False, error=str(exc))
        results.append(result)
        status = "OBSERVE" if result.get("observational") and result["passed"] else "PASS" if result["passed"] else "FAIL"
        print(f"{status} {name}", flush=True)
    (directory / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    return 0 if all(r["passed"] for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
