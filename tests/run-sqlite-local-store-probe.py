#!/usr/bin/env python3
"""Compile/run a synthetic PRIVATE SQLite experiment; never touches NV data.

Fresh child process and SQLite pager for each read. OS/SSD caches are NOT evicted.
Counts are SQLite VFS read requests, not physical device I/O. No NV encryption,
codec/reducer, provider, or power-loss qualification. Artifacts are retained.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import selectors
import signal
import statistics
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sizes", nargs="+", type=int, default=[10000, 100000, 500000])
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--sqlcipher-build", type=Path)
    parser.add_argument("--key-mode", choices=["none", "raw", "pass"], default="none")
    args = parser.parse_args()
    if args.key_mode != "none" and not args.sqlcipher_build:
        parser.error("encryption requires --sqlcipher-build")
    environment = dict(os.environ, NV_PROBE_KEY_MODE=args.key_mode)
    if args.repeats < 1 or any(n < 2000 for n in args.sizes):
        parser.error("positive repeats and sizes >= 2000 required")
    out = Path(tempfile.mkdtemp(prefix="nv-sqlite-local-probe-"))
    binary = out / "probe"
    source = Path(__file__).with_name("SQLiteLocalStoreProbe.c")
    linkage = ["-lsqlite3"] if not args.sqlcipher_build else ["-I", str(args.sqlcipher_build), "-DNV_SQLCIPHER_PROBE", "-DSQLITE_HAS_CODEC", str(args.sqlcipher_build / "libsqlite3.a"), "-framework", "Security", "-framework", "CoreFoundation"]
    subprocess.run(["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                    str(source), *linkage, "-o", str(binary)], check=True)
    print(f"Artifacts: {out}", flush=True)

    def run(*argv, timeout=600):
        p = subprocess.run([str(binary), *map(str, argv)], text=True, capture_output=True, timeout=timeout, env=environment)
        with (out / "calls.jsonl").open("a") as f:
            f.write(json.dumps(dict(args=list(map(str, argv)), code=p.returncode,
                                   stdout=p.stdout, stderr=p.stderr)) + "\n")
        if p.returncode:
            raise RuntimeError(f"{argv}: {p.returncode}\n{p.stdout}\n{p.stderr}")
        return json.loads(p.stdout) if p.stdout.strip() else None

    result = dict(version=run("version"), platform=platform.platform(), machine=platform.machine(),
                  key_mode=args.key_mode, fixtures=[], measurements=[], crashes=[])
    print(json.dumps(result["version"]), flush=True)
    for size in args.sizes:
        db = out / f"history-{size}.sqlite"
        seeded = run("seed", db, size)
        result["fixtures"].append(seeded)
        print(json.dumps(seeded), flush=True)
        for kind in ("startup", "current", "catalog", "point", "lineage", "replay"):
            rows = [run("probe", db, size, kind) for _ in range(args.repeats)]
            # Correctness/page-work checks are not latency thresholds.
            assert all(r["digest"] == rows[0]["digest"] for r in rows)
            if kind == "startup":
                assert all(r["rows"] == 32 and r["fullscan_steps"] == 0 for r in rows)
            result["measurements"].extend(rows)
            summary = {k: rows[0][k] for k in ("kind", "history", "read_bytes", "read_calls", "fullscan_steps")}
            summary["median_ms"] = round(statistics.median(r["ms"] for r in rows), 3)
            print(json.dumps(summary), flush=True)
        (out / "results.json").write_text(json.dumps(result, indent=2) + "\n")

    for mode in ("WAL", "DELETE"):
        for stage in ("after-object", "after-apply", "before-commit", "after-commit",
                      "object-only", "cache-separate", "vfs-write", "vfs-sync", "write-full"):
            db = out / f"crash-{mode}-{stage}.sqlite"
            run("crash-init", db, mode)
            if stage == "write-full":
                run("crash-write", db, stage)
            else:
                p = subprocess.Popen([str(binary), "crash-write", str(db), stage],
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment)
                try:
                    with selectors.DefaultSelector() as sel:
                        sel.register(p.stdout, selectors.EVENT_READ)
                        if not sel.select(timeout=45):
                            raise RuntimeError(f"no crash barrier: {mode}/{stage}")
                        line = p.stdout.readline().strip()
                    if not line.startswith("READY "):
                        raise RuntimeError(f"bad crash barrier {line}: {p.stderr.read()}")
                    assert line == f"READY {stage}", line
                    os.kill(p.pid, signal.SIGKILL)
                    p.wait(timeout=10)
                    assert p.returncode == -signal.SIGKILL
                finally:
                    if p.poll() is None:
                        p.kill(); p.wait()
                    p.stdout.close(); p.stderr.close()
            verified = run("crash-verify", db)
            observed = tuple(verified[k] for k in ("objects", "applied", "current", "pin", "cache"))
            if stage == "after-commit":
                assert observed == (2, 2, 2, 2, 2), observed
            elif stage == "object-only":
                assert observed == (2, 1, 1, 1, 1), observed
            elif stage == "cache-separate":
                assert observed == (2, 2, 2, 2, 1), observed
            elif stage in ("vfs-write", "vfs-sync"):
                # The process may die after a commit frame is written but before
                # SQLite returns. Either complete transaction is legal; no halves.
                assert observed in ((1, 1, 1, 1, 1), (2, 2, 2, 2, 2)), observed
            else:
                assert observed == (1, 1, 1, 1, 1), observed
            verified.update(mode=mode, stage=stage)
            result["crashes"].append(verified)
            print(json.dumps(verified), flush=True)
    (out / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(f"PASS: {len(result['measurements'])} reads; {len(result['crashes'])} crash/error cases. {out / 'results.json'}", flush=True)


if __name__ == "__main__":
    main()
