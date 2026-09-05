#!/usr/bin/env python3
"""Compare actual FrozenNotation with hypothetical SQLite startup storage.

Synthetic fixtures only. Fresh child process per load. Cold reads use per-file
MS_INVALIDATE with residency and kernel disk-I/O checks. NOCACHE is a separate
bypass condition, not assumed to flush preexisting caches.
Leaves fixtures and raw JSON in a fresh temporary directory.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import random
import statistics
import subprocess
import tempfile


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--notes", nargs="+", type=int, default=[1000, 10000])
    p.add_argument("--body-chars", type=int, default=4096)
    p.add_argument("--history", type=int, default=100000)
    p.add_argument("--repeats", type=int, default=5)
    p.add_argument("--page-size", type=int, choices=[4096, 16384], default=4096)
    p.add_argument("--skip-build", action="store_true", help="Use already refreshed app objects")
    p.add_argument("--sqlcipher-build", type=Path, help="Isolated source build containing sqlite3.h and libsqlite3.a")
    p.add_argument("--key-mode", choices=["none", "raw", "pass"], default="none")
    p.add_argument("--conditions", nargs="+", choices=["warm", "cold", "nocache"], default=["warm", "cold", "nocache"])
    args = p.parse_args()
    if args.key_mode != "none" and not args.sqlcipher_build:
        p.error("encryption requires --sqlcipher-build")
    environment = dict(os.environ, NV_PROBE_KEY_MODE=args.key_mode, NV_PROBE_CIPHER_PAGE_SIZE=str(args.page_size))
    if min(args.notes) < 1 or max(args.notes) > 100000 or not 80 <= args.body_chars <= 1048576 or args.history < 0 or args.repeats < 1:
        p.error("invalid fixture size or repetition count")
    root = Path(__file__).resolve().parents[1]
    out = Path(tempfile.mkdtemp(prefix="nv-startup-comparison-"))
    print(f"Artifacts: {out}", flush=True)
    if not args.skip_build:
        subprocess.run(["zsh", "build.sh"], cwd=root, check=True)
    obj_dir = root / ("DerivedData/Build/Intermediates.noindex/ArchiveIntermediates/Notation/"
                      "IntermediateBuildFilesPath/Notation.build/Deployment/Notation.build/Objects-normal") / platform.machine()
    objects = sorted(x for x in obj_dir.glob("*.o") if x.name != "main.o" and not x.name.endswith("_vers.o"))
    assert objects and (obj_dir / "FrozenNotation.o").is_file()
    # A distinct bundle identity prevents accessing NV's actual preference domain.
    info = out / "Info.plist"
    info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "net.notational.velocity.tests.startup-storage",
                                    "CFBundleVersion": "1", "CFBundleName": "StartupStorageComparison"}))
    binary = out / "probe"
    frameworks = ["Sparkle", "Cocoa", "Carbon", "CoreServices", "SecurityInterface", "Security",
                  "WebKit", "ApplicationServices", "SystemConfiguration", "IOKit", "UniformTypeIdentifiers"]
    command = ["clang", "-O2", "-Wall", "-Wextra", "-Werror", "-fno-objc-arc", "-fblocks", "-mmacosx-version-min=11.5",
               "-I", str(root), str(root / "tests/StartupStorageComparison.m"), *map(str, objects),
               "-F", str(root), f"-Wl,-rpath,{root}", f"-Wl,-sectcreate,__TEXT,__info_plist,{info}"]
    for framework in frameworks:
        command += ["-framework", framework]
    linkage = ["-lsqlite3"]
    if args.sqlcipher_build:
        linkage = ["-I", str(args.sqlcipher_build), "-DNV_SQLCIPHER_PROBE", "-DSQLITE_HAS_CODEC", str(args.sqlcipher_build / "libsqlite3.a")]
    subprocess.run(command + ["-lz", *linkage, "-o", str(binary)], check=True)

    def run(*argv):
        process = subprocess.run([str(binary), *map(str, argv)], capture_output=True, text=True, timeout=300, env=environment)
        with (out / "calls.jsonl").open("a") as f:
            f.write(json.dumps(dict(args=list(map(str, argv)), code=process.returncode,
                                   stdout=process.stdout, stderr=process.stderr)) + "\n")
        if process.returncode:
            raise RuntimeError(f"{argv}: {process.returncode}\n{process.stdout}\n{process.stderr}")
        return json.loads(process.stdout)

    result = dict(platform=platform.platform(), arguments={k: str(v) if isinstance(v, Path) else v for k,v in vars(args).items()}, fixtures=[], measurements=[], preparations=[])
    kinds = ("frozen-file", "frozen", "flat-file", "flat", "compressed", "rows")
    randomizer = random.Random(4701)
    for count in args.notes:
        fixture = out / f"notes-{count}"
        fixture.mkdir(mode=0o700)
        seeded = run("seed", fixture, count, args.body_chars, args.history, args.page_size)
        result["fixtures"].append(seeded)
        print(json.dumps(seeded), flush=True)
        combinations = [(kind, condition) for _ in range(args.repeats) for kind in kinds for condition in args.conditions]
        randomizer.shuffle(combinations)
        for kind, condition in combinations:
            uncached = int(condition == "nocache")
            if condition == "warm":
                preparation = run("read", fixture, kind, 0, count)
                assert preparation["digest"] == seeded["expected_digest"]
            else:
                filename = kind.replace("-file", ".dat") if kind.endswith("-file") else "store.sqlite"
                preparation = run("evict", fixture / filename)
                assert preparation["resident_after"] == 0, preparation
            row = run("read", fixture, kind, uncached, count)
            row["condition"] = condition
            assert row["digest"] == seeded["expected_digest"]
            if condition != "warm" and row["kernel_read_bytes"] < row["encoded_bytes"]:
                raise RuntimeError(f"Uncached condition not established: {row}")
            result["preparations"].append(preparation)
            result["measurements"].append(row)
            (out / "results.json").write_text(json.dumps(result, indent=2) + "\n")
            print(json.dumps({key: row[key] for key in ("kind", "condition", "notes", "load_ms", "decode_ms", "kernel_read_bytes")}), flush=True)
        for kind in kinds:
            for condition in args.conditions:
                rows = [r for r in result["measurements"] if r["notes"] == count and r["kind"] == kind and r["condition"] == condition]
                summary = {"kind": kind, "notes": count, "condition": condition}
                for key in ("load_ms", "decode_ms", "total_ms", "kernel_read_bytes", "pread_calls"):
                    summary[key] = statistics.median(r[key] for r in rows)
                print("SUMMARY " + json.dumps(summary), flush=True)
    print(f"PASS: {len(result['measurements'])} measured loads, exact common-field equality and uncached I/O gates. {out / 'results.json'}", flush=True)


if __name__ == "__main__":
    main()
