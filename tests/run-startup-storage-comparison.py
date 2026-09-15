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
import shutil
import statistics
import subprocess
import tempfile

LAYOUTS = ["aged", "rebuilt", "compacted", "birth-order", "deferred-index", "bounded-reserved",
           "deferred-birth", "recycled", "reserved", "reserved-inline", "contiguous-pool", "transfer", "reverse-rowid", "level6-compacted", "recompressed", "recompressed-compacted"]
LAYOUTS += [name + "-hinted" for name in LAYOUTS] + ["hinted"]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--notes", nargs="+", type=int, default=[1000, 10000])
    p.add_argument("--body-chars", type=int, default=4096)
    p.add_argument("--history", type=int, default=100000)
    p.add_argument("--repeats", type=int, default=5)
    p.add_argument("--page-size", type=int, choices=[4096, 16384], default=4096)
    p.add_argument("--skip-build", action="store_true", help="Use already refreshed app objects")
    p.add_argument("--sqlcipher-build", type=Path, help="Isolated source build containing sqlite3.h and libsqlite3.a")
    p.add_argument("--zstd-prefix", type=Path, help="Optional experiment-only prefix containing include/zstd.h and lib/libzstd.a")
    p.add_argument("--zstd-level", type=int, choices=[1, 3, 6, 9, 15, 19], default=3)
    p.add_argument("--zstd-min-match", type=int, choices=[0, 4, 6], default=0, help="0 uses the selected level's default")
    p.add_argument("--zstd-strategy", choices=["default", "dfast"], default="default")
    p.add_argument("--dictionary-size", type=int, choices=[0, 8192, 32768, 65536], default=0,
                   help="Train a private shared dictionary when recompressing current cells")
    p.add_argument("--dictionary-pattern", choices=["words", "mixed", "random"], default="words",
                   help="Independent synthetic training family; may differ from measured notes")
    p.add_argument("--dictionary-training", choices=["held-out", "current", "all-current"], default="held-out",
                   help="Independent generated records, a bounded current-cell sample, or every current cell (128-MiB fixture limit)")
    p.add_argument("--dictionary-sample-limit", type=int, default=1024, help="Maximum current cells considered for sampled training")
    p.add_argument("--dictionary-sample-budget", type=int, default=8*1024*1024, help="Maximum total decoded bytes retained for sampled training")
    p.add_argument("--dictionary-contracts", action="store_true", help="Small-fixture dictionary faults and abrupt-exit transaction checks")
    p.add_argument("--expect-training-fallback", action="store_true", help="Negative control: require training to decline and complete startup without dictionary cells")
    p.add_argument("--dictionary-micro-baseline", type=Path, help="Additional alternating decode-only comparison with a matching no-dictionary store.sqlite")
    p.add_argument("--dictionary-example-comparison", action="store_true", help="Compare strict wrapper, official-example core API, and refDDict API on validated frames")
    p.add_argument("--key-mode", choices=["none", "raw", "pass"], default="none")
    p.add_argument("--aged", action="store_true", help="Actual-DDL, clean-exit locality experiment; ignores --kinds")
    p.add_argument("--churn-rounds", type=int, default=10)
    p.add_argument("--context-bytes", type=int, default=256, help="Synthetic authoring-reference bytes per current cell")
    p.add_argument("--layouts", nargs="+", choices=LAYOUTS, default=["aged", "rebuilt", "compacted"])
    p.add_argument("--secondary", action="store_true", help="Also vary page-cache size, temporary lifetimes and raw reads")
    p.add_argument("--reuse-aged-root", type=Path, help="Reuse completed clean fixture images; write new measurements separately")
    p.add_argument("--source-layout", choices=LAYOUTS, help="Use this layout from --reuse-aged-root as the immutable source for NEW variants")
    p.add_argument("--rewrite-passes", type=int, default=1, help="Repeat the chosen physical layout operation without intervening logical changes")
    p.add_argument("--rewrite-cache-kib", type=int, default=0, help="0 preserves the existing maintenance connection default")
    p.add_argument("--rewrite-spill", choices=["default", "off"], default="default")
    p.add_argument("--rewrite-secure-delete", choices=["default", "off"], default="default", help="Synthetic cost-isolation control only; not a privacy policy change")
    p.add_argument("--rewrite-chunk-mib", type=int, default=0, help="Native SQLite VFS chunk-size hint; not a B-tree reservation")
    p.add_argument("--reserve-budget-mib", type=int, default=16, help="Maximum temporary payload in bounded-reserved control")
    p.add_argument("--read-ahead", choices=["default", "off"], default="default", help="Aged probe's measured read descriptor only")
    p.add_argument("--hole-interval", type=int, default=0, help="Retain then release a 16-KiB private buffer every N mutations (0=off)")
    p.add_argument("--cell-codec", choices=["raw", "zlib", "zstd"], default="raw", help="Aged experiment only: independently compressed current cells")
    p.add_argument("--cell-decoder", choices=["allocate", "scratch", "stream"], default="allocate", help="Per-cell allocation baseline, reusable output buffer, or buffer plus reusable inflater")
    p.add_argument("--body-pattern", choices=["words", "random", "mixed"], default="words", help="Aged experiment: repeated words, high-entropy ASCII, or six mixed note genres")
    p.add_argument("--prefetch-workers", type=int, choices=[1, 4, 8, 16], default=1, help="Bounded raw ciphertext read-ahead concurrency")
    p.add_argument("--prefetch-amplification", type=int, choices=[1, 2, 4], default=1, help="Coalesce ranges with at most this ratio of read pages to requested current pages")
    p.add_argument("--hint-fault", choices=["none", "empty", "malformed", "wrong-pages"], default="none", help="Read-ahead hint fault injection; all note values must still come from ordinary SQL")
    p.add_argument("--aged-kinds", nargs="+", choices=["table", "uuid", "flat", "compressed", "zstd", "table-prefetch"], default=["table", "uuid", "flat", "compressed"])
    p.add_argument("--conditions", nargs="+", choices=["warm", "cold", "nocache"], default=["warm", "cold", "nocache"])
    p.add_argument("--kinds", nargs="+", choices=["frozen-file", "frozen", "flat-file", "flat", "compressed", "rows", "rows-direct"],
                   default=["frozen-file", "frozen", "flat-file", "flat", "compressed", "rows", "rows-direct"])
    args = p.parse_args()
    if args.key_mode != "none" and not args.sqlcipher_build:
        p.error("encryption requires --sqlcipher-build")
    if not 8 <= args.dictionary_sample_limit <= 4096 or not 65536 <= args.dictionary_sample_budget <= 32*1024*1024:
        p.error("sample limits: 8–4096 candidates and 64 KiB–32 MiB")
    if args.source_layout and not args.reuse_aged_root:
        p.error("--source-layout requires --reuse-aged-root")
    if not 1 <= args.rewrite_passes <= 8 or not 0 <= args.rewrite_cache_kib <= 65536 or not 0 <= args.rewrite_chunk_mib <= 64 or not 1 <= args.reserve_budget_mib <= 64:
        p.error("invalid bounded rewrite experiment option")
    if (args.cell_codec == "zstd" or "zstd" in args.aged_kinds) and not args.zstd_prefix:
        p.error("zstd tests require --zstd-prefix")
    if args.dictionary_size and (not args.aged or args.cell_codec != "zstd" or args.zstd_min_match or args.zstd_strategy != "default"
            or not all(x.startswith("recompressed") for x in args.layouts)):
        p.error("dictionary experiments require zstd/default strategy/default min-match and recompressed layouts")
    if args.body_pattern == "mixed" and not args.zstd_prefix:
        p.error("mixed fixture generator requires the optional zstd experiment build")
    if args.dictionary_contracts and (not args.dictionary_size or min(args.notes)<2 or max(args.notes)>1000 or len(args.layouts)!=1):
        p.error("dictionary contracts require one dictionary layout and 2–1000 notes")
    if (args.dictionary_micro_baseline or args.dictionary_example_comparison) and (not args.dictionary_size or args.cell_decoder != "stream"):
        p.error("dictionary microbenchmark requires a dictionary and reusable decoder")
    if not 0 <= args.churn_rounds <= 100 or not 0 <= args.context_bytes <= 65536 or args.hole_interval < 0:
        p.error("invalid churn/context size")
    if args.aged and "nocache" in args.conditions:
        p.error("--aged supports --conditions warm cold (cold includes verified OS eviction)")
    if args.aged and args.aged_kinds == ["table-prefetch"] and not any(x == "hinted" or x.endswith("-hinted") for x in args.layouts):
        p.error("table-prefetch requires a hinted layout; refusing an empty benchmark matrix")
    environment = dict(os.environ, NV_PROBE_KEY_MODE=args.key_mode, NV_PROBE_CIPHER_PAGE_SIZE=str(args.page_size), NV_PROBE_READ_AHEAD=args.read_ahead, NV_PROBE_CELL_CODEC=args.cell_codec, NV_PROBE_BODY_PATTERN=args.body_pattern)
    environment["NV_PROBE_PREFETCH_WORKERS"] = str(args.prefetch_workers)
    environment["NV_PROBE_PREFETCH_AMPLIFICATION"] = str(args.prefetch_amplification)
    environment["NV_PROBE_HINT_FAULT"] = args.hint_fault
    environment["NV_PROBE_CELL_DECODER"] = args.cell_decoder
    environment["NV_PROBE_ZSTD_LEVEL"] = str(args.zstd_level)
    environment["NV_PROBE_ZSTD_MIN_MATCH"] = str(args.zstd_min_match)
    environment["NV_PROBE_ZSTD_STRATEGY"] = args.zstd_strategy
    environment["NV_PROBE_DICTIONARY_SIZE"] = str(args.dictionary_size)
    environment["NV_PROBE_DICTIONARY_PATTERN"] = args.dictionary_pattern
    environment["NV_PROBE_DICTIONARY_TRAINING"] = args.dictionary_training
    environment["NV_PROBE_DICTIONARY_SAMPLE_LIMIT"] = str(args.dictionary_sample_limit)
    environment["NV_PROBE_DICTIONARY_SAMPLE_BUDGET"] = str(args.dictionary_sample_budget)
    environment["NV_PROBE_REWRITE_CACHE_KIB"] = str(args.rewrite_cache_kib)
    environment["NV_PROBE_REWRITE_SPILL"] = args.rewrite_spill
    environment["NV_PROBE_REWRITE_SECURE_DELETE"] = args.rewrite_secure_delete
    environment["NV_PROBE_REWRITE_CHUNK_MIB"] = str(args.rewrite_chunk_mib)
    environment["NV_PROBE_RESERVE_BUDGET_MIB"] = str(args.reserve_budget_mib)
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
               "-I", str(root), str(root / ("tests/AgedStartupStorageComparison.m" if args.aged else "tests/StartupStorageComparison.m")), *map(str, objects),
               "-F", str(root), f"-Wl,-rpath,{root}", f"-Wl,-sectcreate,__TEXT,__info_plist,{info}"]
    for framework in frameworks:
        command += ["-framework", framework]
    linkage = ["-lsqlite3"]
    if args.sqlcipher_build:
        linkage = ["-I", str(args.sqlcipher_build), "-DNV_SQLCIPHER_PROBE", "-DSQLITE_HAS_CODEC", str(args.sqlcipher_build / "libsqlite3.a")]
    if args.zstd_prefix:
        linkage += ["-DNV_PROBE_ZSTD", "-I", str(args.zstd_prefix / "include"), str(args.zstd_prefix / "lib/libzstd.a")]
    subprocess.run(command + ["-lz", *linkage, "-o", str(binary)], check=True)

    def run(*argv, expected=0):
        process = subprocess.run([str(binary), *map(str, argv)], capture_output=True, text=True, timeout=300, env=environment)
        with (out / "calls.jsonl").open("a") as f:
            f.write(json.dumps(dict(args=list(map(str, argv)), code=process.returncode,
                                   stdout=process.stdout, stderr=process.stderr)) + "\n")
        if process.returncode != expected:
            raise RuntimeError(f"{argv}: {process.returncode}\n{process.stdout}\n{process.stderr}")
        if expected:
            return dict(expected_exit=expected, stderr=process.stderr)
        return json.loads(process.stdout)

    result = dict(platform=platform.platform(), arguments={k: str(v) if isinstance(v, Path) else v for k,v in vars(args).items()}, fixtures=[], measurements=[], preparations=[])
    if args.aged:
        run_aged(args, root, out, run, result)
        return
    kinds = args.kinds
    randomizer = random.Random(4701)
    for count in args.notes:
        fixture = out / f"notes-{count}"
        fixture.mkdir(mode=0o700)
        seeded = run("seed", fixture, count, args.body_chars, args.history, args.page_size)
        result["fixtures"].append(seeded)
        search_hits = None
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
            if search_hits is None:
                search_hits = row["search_hits"]
            assert row["search_hits"] == search_hits
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
                for key in ("load_ms", "decode_ms", "total_ms", "search_ms", "kernel_read_bytes", "pread_calls"):
                    summary[key] = statistics.median(r[key] for r in rows)
                print("SUMMARY " + json.dumps(summary), flush=True)
    print(f"PASS: {len(result['measurements'])} measured loads, exact common-field equality and uncached I/O gates. {out / 'results.json'}", flush=True)


def run_aged(args, root, out, run, result):
    """Compare identical final values/history. All fixture mutations precede timing."""
    randomizer = random.Random(9031)
    previous = None
    if args.reuse_aged_root:
        previous = json.loads((args.reuse_aged_root / "results.json").read_text())
        for key in ("body_chars", "history", "churn_rounds", "context_bytes", "page_size", "key_mode"):
            assert previous["arguments"][key] == getattr(args, key), ("different fixture", key)
        assert previous["arguments"].get("hole_interval", 0) == args.hole_interval
        assert previous["arguments"].get("cell_codec", "raw") == args.cell_codec
        assert previous["arguments"].get("body_pattern", "words") == args.body_pattern
    for count in args.notes:
        base = (args.reuse_aged_root or out) / f"notes-{count}-aged"
        if previous:
            seeded = next(f for f in previous["fixtures"] if f["kind"] == "aged-seed" and f["notes"] == count)
            prior_base = next((f for f in previous["fixtures"] if f.get("layout") == "aged" and f["notes"] == count), {})
            base = Path(previous.get("aged_roots", {}).get(str(count), prior_base.get("fixture_path", base)))
            if args.source_layout:
                base = Path(next(f["fixture_path"] for f in previous["fixtures"] if f.get("layout")==args.source_layout and f["notes"]==count))
        else:
            base.mkdir(mode=0o700)
            seeded = run("aged-seed", base, root / "docs/impl-proposal-5/plan/sqlite-local-schema.sql",
                         count, args.body_chars, args.history, args.churn_rounds, args.context_bytes, args.hole_interval)
        result["fixtures"].append(seeded)
        result.setdefault("aged_roots", {})[str(count)] = str(base)
        print(json.dumps(seeded), flush=True)
        fixtures = {}
        for layout in args.layouts:
            fixture = base if layout == "aged" else (args.reuse_aged_root or out) / f"notes-{count}-{layout}"
            prior = next((f for f in previous["fixtures"] if f.get("layout") == layout and f["notes"] == count), None) if previous else None
            if previous and any(previous["arguments"].get(k,d)!=getattr(args,k) for k,d in
                    [("rewrite_passes",1),("rewrite_cache_kib",0),("rewrite_spill","default"),("rewrite_secure_delete","default"),("rewrite_chunk_mib",0),("reserve_budget_mib",16)]):
                prior = None
            if args.source_layout or args.rewrite_passes!=1 or args.rewrite_cache_kib or args.rewrite_spill!="default" or args.rewrite_secure_delete!="default" or args.rewrite_chunk_mib or layout.startswith("bounded-reserved"):
                prior = None
            if prior and layout.startswith("recompressed") and any(prior.get(k, default) != getattr(args, k)
                    for k, default in [("zstd_level", 3), ("zstd_min_match", 0), ("zstd_strategy", "default"),
                                       ("dictionary_size", 0), ("dictionary_pattern", "words"),
                                       ("dictionary_training", "held-out"),
                                       ("dictionary_sample_limit",4096), ("dictionary_sample_budget",32*1024*1024)]):
                prior = None
            if prior:
                fixture = Path(prior.get("fixture_path", fixture))
            if prior and (fixture / "store.sqlite").is_file():
                info = dict(prior)
            else:
                # New variants never mutate a reused artifact directory.
                fixture=base if layout == "aged" and not args.reuse_aged_root else out / f"notes-{count}-{layout}"
                if fixture != base:
                    fixture.mkdir(mode=0o700)
                    for name in ("store.sqlite", "expected.dat"):
                        shutil.copyfile(base / name, fixture / name)
                passes = [run("layout", fixture / "store.sqlite", layout) for _ in range(args.rewrite_passes)]
                info = dict(passes[-1], rewrite_passes=passes)
            if args.dictionary_size and args.dictionary_training=="current":
                assert info["dictionary_sample_count"]<=args.dictionary_sample_limit
                assert info["dictionary_sample_bytes"]<=args.dictionary_sample_budget
            if args.expect_training_fallback:
                assert info["dictionary_training_status"] in ("too-few-samples","trainer-declined"),info
            info["notes"] = count
            info["fixture_path"] = str(fixture)
            result["fixtures"].append(info)
            fixtures[layout] = fixture
            print(json.dumps(info), flush=True)
        variants = [(layout, kind, 4096, 256, 1) for layout in args.layouts
                    for kind in args.aged_kinds if kind != "table-prefetch" or layout == "hinted" or layout.endswith("-hinted")]
        if args.secondary:
            # Keep the same file image while changing one factor at a time.
            assert "aged" in fixtures
            variants += [("aged", kind, cache, 256, 1) for kind in ("table", "uuid") for cache in (512, 65536)]
            variants += [("aged", kind, 4096, 0, 1) for kind in ("table", "flat")]
            variants += [(layout, kind, 4096, 256, 0) for layout in args.layouts for kind in ("table", "uuid")]
        assert variants, "empty benchmark matrix"
        combinations = [(variant, condition) for _ in range(args.repeats)
                        for variant in variants for condition in args.conditions]
        randomizer.shuffle(combinations)
        expected_hits = expected_context = expected_raw = None
        for (layout, kind, cache, pool, decode), condition in combinations:
            fixture = fixtures[layout]
            command = ("aged-read", fixture, kind, cache, pool, decode)
            if condition == "warm":
                preparation = run(*command)
            else:
                preparation = run("evict", fixture / "store.sqlite")
                assert preparation["resident_after"] == 0, preparation
            row = run(*command)
            row.update(layout=layout, condition=condition)
            assert row["notes"] == count and row["wal_reads"] == 0 and row["sorts"] == 0, row
            if args.dictionary_size and kind in ("table", "uuid", "table-prefetch"):
                if args.expect_training_fallback:
                    assert row["dictionary_cells"]==0,row
                else:
                    assert row["dictionary_count"] >= 1 and row["dictionary_cells"] > 0, row
            if kind == "table-prefetch":
                assert row["hint_used"] == (args.hint_fault not in ("empty", "malformed")), row
            if decode:
                if expected_hits is None:
                    expected_hits, expected_context = row["search_hits"], row["context_digest"]
                assert (row["search_hits"], row["context_digest"]) == (expected_hits, expected_context)
            else:
                if expected_raw is None:
                    expected_raw = row["context_digest"]
                assert row["context_digest"] == expected_raw
            if condition == "cold" and row["kernel_read_bytes"] < row["encoded_bytes"]:
                raise RuntimeError(f"Cold I/O not established: {row}")
            result["preparations"].append(preparation)
            result["measurements"].append(row)
            (out / "results.json").write_text(json.dumps(result, indent=2) + "\n")
            print(json.dumps({k: row[k] for k in ("notes", "layout", "kind", "condition", "cache_kib", "pool_batch", "decode", "total_ms", "pread_calls")}), flush=True)
        for layout, kind, cache, pool, decode in variants:
            for condition in args.conditions:
                rows = [r for r in result["measurements"] if
                        (r["notes"], r["layout"], r["kind"], r["cache_kib"], r["pool_batch"], r["decode"], r["condition"]) ==
                        (count, layout, kind, cache, pool, bool(decode), condition)]
                summary = dict(notes=count, layout=layout, kind=kind, cache_kib=cache, pool_batch=pool, decode=bool(decode), condition=condition)
                for key in ("total_ms", "pread_ms", "decode_ms", "inflate_ms", "construct_ms", "prefetch_ms", "kernel_read_bytes", "pread_calls", "unique_pages", "rss_high_water_bytes"):
                    summary[key] = statistics.median(r[key] for r in rows)
                summary["max_ms"] = max(r["total_ms"] for r in rows)
                print("SUMMARY " + json.dumps(summary), flush=True)
        if args.dictionary_contracts:
            run_dictionary_contracts(out, next(iter(fixtures.values())), run, result)
            (out / "results.json").write_text(json.dumps(result, indent=2) + "\n")
        if args.dictionary_micro_baseline:
            micro = run("dict-micro", args.dictionary_micro_baseline, next(iter(fixtures.values())) / "store.sqlite")
            result.setdefault("dictionary_micro", []).append(micro)
            (out / "results.json").write_text(json.dumps(result, indent=2) + "\n")
            print("DICTIONARY MICRO " + json.dumps({str(use): statistics.median(x["ms"] for x in micro["measurements"] if x["dictionary"] == use)
                                                  for use in (False, True)}), flush=True)
        if args.dictionary_example_comparison:
            comparison = run("dict-example", next(iter(fixtures.values())) / "store.sqlite")
            result.setdefault("dictionary_example", []).append(comparison)
            (out / "results.json").write_text(json.dumps(result, indent=2) + "\n")
            print("DICTIONARY EXAMPLE " + json.dumps({name: statistics.median(x["ms"] for x in comparison["measurements"] if x["variant"]==name)
                                                    for name in sorted({x["variant"] for x in comparison["measurements"]})}), flush=True)
    print(f"PASS: {len(result['measurements'])} clean-exit measured loads; full-decode paths passed exact value/context/search checks. {out / 'results.json'}", flush=True)


def run_dictionary_contracts(out, source, run, result):
    checks = result.setdefault("dictionary_contracts", [])
    def clone(name):
        folder = out / ("dictionary-" + name)
        folder.mkdir(mode=0o700)
        for leaf in ("store.sqlite", "expected.dat"):
            shutil.copyfile(source / leaf, folder / leaf)
        return folder
    def state(folder):
        return run("dict-maintain", folder / "store.sqlite", "state")
    def same_values(row, baseline):
        assert all(row[k] == baseline[k] for k in ("notes", "current_hash", "history_hash")), row
    def load(folder):
        # Normal SQLite has already recovered/checkpointed the fault fixture;
        # the measured-read VFS intentionally accepts only closed clean images.
        row = run("aged-read", folder, "table", 4096, 256, 1)
        assert row["dictionary_cells"] == row["notes"] and row["wal_reads"] == 0
        return row
    api = clone("api")
    checks.append(dict(case="api", result=run("dict-api", api / "store.sqlite")))
    baseline = state(api)
    assert baseline["dictionary_count"] == baseline["referenced_count"] == 1
    for boundary, code, count in (("before", 77, 1), ("after", 78, 2)):
        folder = clone(boundary)
        run("dict-maintain", folder / "store.sqlite", "rotate-" + boundary, expected=code)
        recovered = state(folder)
        same_values(recovered, baseline)
        assert recovered["dictionary_count"] == recovered["referenced_count"] == count
        checks.append(dict(case="crash-" + boundary, result=recovered, full_load=load(folder)))
        if boundary == "after":
            kept = run("dict-maintain", folder / "store.sqlite", "prune")
            assert kept["removed"] == 0 and kept["dictionary_count"] == kept["referenced_count"] == 2
            same_values(kept, baseline)
            checks.append(dict(case="retain-referenced", result=kept, full_load=load(folder)))
            moved = run("dict-maintain", folder / "store.sqlite", "rotate-all")
            assert moved["changed"] == baseline["notes"] and moved["dictionary_count"] == 3 and moved["referenced_count"] == 1
            removed = run("dict-maintain", folder / "store.sqlite", "prune")
            assert removed["removed"] == 2 and removed["dictionary_count"] == removed["referenced_count"] == 1
            same_values(removed, baseline)
            checks.append(dict(case="retire-unreferenced", result=removed, full_load=load(folder)))
    for fault, reason in (("missing", "missing exact dictionary"), ("corrupt", "dictionary hash mismatch"),
                          ("unknown-ref", "missing exact dictionary"), ("wrong-frame-id", "frame/dictionary ID mismatch")):
        folder = clone(fault)
        run("dict-maintain", folder / "store.sqlite", fault)
        rejected = run("dict-maintain", folder / "store.sqlite", "state", expected=65)
        assert "DICTIONARY_REJECTED: " + reason in rejected["stderr"], rejected
        checks.append(dict(case=fault, result=rejected))
    print("DICTIONARY CONTRACTS PASS: 5 API checks; 2 crash cuts; retained/released dependencies; 4 rejection controls", flush=True)


if __name__ == "__main__":
    main()
