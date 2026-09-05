#!/usr/bin/env python3
"""SQLCipher raw-key startup, WAL recovery, rekey and damage contingencies.

Synthetic fixtures only; keys are deliberately public. Does not install a
production dependency or touch Keychain/NV/provider files. Retains artifacts.
Pass a CommonCrypto source build with DBSTAT and TEMP_STORE=3 enabled.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import selectors
import shutil
import signal
import statistics
import subprocess
import tempfile


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--sqlcipher-build", required=True, type=Path)
    p.add_argument("--repeats", type=int, default=3)
    p.add_argument("--argon2-build", type=Path, help="Reference source build containing libargon2.a; enables wrapper probe")
    p.add_argument("--key-recovery-only", action="store_true", help="Run the adopted key/backup/partial-salvage mechanisms, not the benchmark/rekey survey")
    args = p.parse_args()
    if args.repeats < 1:
        p.error("positive repeats required")
    out = Path(tempfile.mkdtemp(prefix="nv-sqlcipher-variation-"))
    if args.key_recovery_only:
        if not args.argon2_build:
            p.error("--key-recovery-only requires --argon2-build")
        bridge = out / "bridge.h"
        bridge.write_text('#include "sqlite3.h"\n#include "argon2.h"\n')
        binary = out / "recovery-probe"
        subprocess.run(["xcrun", "swiftc", "-O", "-warnings-as-errors", "-module-cache-path", str(out / "module-cache"),
                        "-Xcc", "-DSQLITE_HAS_CODEC", "-I", str(args.sqlcipher_build),
                        "-I", str(args.argon2_build / "include"), "-import-objc-header", str(bridge),
                        str(Path(__file__).with_name("SQLCipherRecoveryProbe.swift")),
                        str(args.sqlcipher_build / "libsqlite3.a"), str(args.argon2_build / "libargon2.a"),
                        "-framework", "Security", "-o", str(binary)], check=True)
        proc = subprocess.run([str(binary), str(out)], text=True, capture_output=True, timeout=60)
        (out / "stdout.log").write_text(proc.stdout)
        (out / "stderr.log").write_text(proc.stderr)
        print(f"Artifacts: {out}", flush=True)
        if proc.returncode:
            raise RuntimeError(f"recovery probe exit {proc.returncode}: {proc.stderr}")
        result = json.loads(proc.stdout)
        # Independent stdlib vectors, not the Swift derivation checking itself.
        import hmac
        extract = hmac.digest(bytes(range(32, 64)), bytes(range(32)), "sha256")
        expected = hmac.digest(extract, b"NV private database key\0v1\0\x01", "sha256").hex()
        assert result["encrypted_key_vector"] == expected
        assert result["public_key_vector"] == hashlib.sha256(b"NV public local database key\0v1\0").hexdigest()
        result.update(platform=platform.platform(), independent_key_vectors=True)
        (out / "results.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))
        return
    binary = out / "probe"
    source = Path(__file__).with_name("SQLCipherVariationProbe.c")
    subprocess.run(["clang", "-O2", "-std=c11", "-Wall", "-Wextra", "-Werror",
                    "-DNV_SQLCIPHER_PROBE", "-DSQLITE_HAS_CODEC", "-I", str(args.sqlcipher_build),
                    str(source), str(args.sqlcipher_build / "libsqlite3.a"),
                    "-framework", "Security", "-framework", "CoreFoundation", "-o", str(binary)], check=True)
    print(f"Artifacts: {out}", flush=True)
    result = dict(platform=platform.platform(), source=str(args.sqlcipher_build), recoveries=[], unlock=[], rekeys=[], rekey_scaling=[], damage=[])

    def environment(mode):
        return dict(os.environ, NV_PROBE_KEY_MODE=mode)

    def run(*cmd, mode="raw"):
        proc = subprocess.run([str(binary), *map(str, cmd)], env=environment(mode), capture_output=True, text=True, timeout=300)
        with (out / "calls.jsonl").open("a") as f:
            f.write(json.dumps(dict(cmd=list(map(str, cmd)), mode=mode, code=proc.returncode,
                                   stdout=proc.stdout, stderr=proc.stderr)) + "\n")
        if proc.returncode:
            raise RuntimeError(f"{cmd}: {proc.returncode}\n{proc.stdout}\n{proc.stderr}")
        return json.loads(proc.stdout)

    def kill_at(cmd, expected, mode="raw"):
        proc = subprocess.Popen([str(binary), *map(str, cmd)], env=environment(mode),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            with selectors.DefaultSelector() as sel:
                sel.register(proc.stdout, selectors.EVENT_READ)
                if not sel.select(timeout=60):
                    raise RuntimeError(f"no barrier: {cmd}")
                line = proc.stdout.readline().strip()
            if line != f"READY {expected}":
                raise RuntimeError(f"bad barrier {line}: {cmd}")
            proc.kill(); proc.wait(timeout=10)
            assert proc.returncode == -signal.SIGKILL
        finally:
            if proc.poll() is None:
                proc.kill(); proc.wait(timeout=10)
            proc.stdout.close(); proc.stderr.close()

    def save():
        (out / "results.json").write_text(json.dumps(result, indent=2) + "\n")

    result["version"] = run("info")
    print(json.dumps(result["version"]), flush=True)
    # Same SQLCipher engine with encryption disabled is the control, not a
    # different SQLite version/build. No other benchmark runs concurrently.
    for mode in ("none", "raw"):
        for tail in (0, 1000, 10000):
            origin = out / f"wal-{mode}-{tail}.db"
            run("seed", origin, "WAL", 100, mode=mode)
            kill_at(["append", origin, tail, 0], "wal-backlog", mode)
            for repetition in range(args.repeats):
                db = out / f"reopen-{mode}-{tail}-{repetition}.db"
                shutil.copyfile(origin, db)
                wal = Path(str(origin) + "-wal")
                wal_size = wal.stat().st_size if wal.exists() else 0
                if wal_size:
                    shutil.copyfile(wal, str(db) + "-wal")
                    run("cold", str(db) + "-wal", mode=mode)
                # No shared-memory file in the copy: force WAL-index recovery.
                run("cold", db, mode=mode)
                row = run("read", db, 100 + tail, mode=mode)
                assert row["kernel_read_bytes"] >= 1048576
                if tail:
                    assert row["wal_reads"] > 0
                row.update(mode=mode, tail=tail, wal_bytes=wal_size)
                result["recoveries"].append(row)
            rows = result["recoveries"][-args.repeats:]
            print(json.dumps(dict(mode=mode, tail=tail, wal_bytes=wal_size,
                                  startup_ms=statistics.median(r["startup_ms"] for r in rows),
                                  open_schema_ms=statistics.median(r["open_schema_ms"] for r in rows))), flush=True)
            save()

    for mode in ("none", "raw", "pass"):
        db = out / f"unlock-{mode}.db"
        run("seed", db, "DELETE", 100, mode=mode)
        for _ in range(args.repeats):
            row = run("read", db, 100, mode=mode)
            row["mode"] = mode; result["unlock"].append(row)

    keyed = out / "unlock-raw.db"
    before = hashlib.sha256(keyed.read_bytes()).hexdigest()
    checks = {kind: run("key", keyed, kind) for kind in ("old", "wrong", "none", "bytes")}
    assert checks["old"]["read_return"] == 0
    assert all(checks[k]["read_return"] != 0 for k in ("wrong", "none", "bytes"))
    assert checks["wrong"]["key_return"] == 0  # Key acceptance is not validation.
    assert hashlib.sha256(keyed.read_bytes()).hexdigest() == before
    result["key_checks"] = checks

    for journal in ("DELETE", "WAL"):
        cuts = ["none", "write", "sync", "full", "sync-error-1", "sync-error-2"]
        for cut in cuts:
            db = out / f"rekey-{journal}-{cut}.db"
            run("seed", db, journal, 2000)
            if cut in ("write", "sync"):
                kill_at(["rekey", db, cut], "vfs-" + cut)
                row = dict(killed=True)
            else:
                row = run("rekey", db, cut)
            # Each candidate gets its own complete stopped fixture; trying one
            # key must not change the other's recovery experiment.
            candidates = {}
            for kind in ("old", "new"):
                candidate = out / f"candidate-{journal}-{cut}-{kind}.db"
                for suffix in ("", "-wal", "-journal"):
                    source = Path(str(db) + suffix)
                    if source.exists():
                        shutil.copyfile(source, str(candidate) + suffix)
                candidates[kind] = run("key", candidate, kind)
            old, new = candidates["old"], candidates["new"]
            assert (old["read_return"] == 0) != (new["read_return"] == 0), (journal, cut, old, new)
            winner = old if old["read_return"] == 0 else new
            assert winner["data_return"] == 101 and winner["verified_history_rows"] == 2000
            if cut == "none":
                assert row["rekey_return"] == 0 and new["read_return"] == 0
                cuts.append(f"full-at-{row['write_calls']}")
            if cut.startswith("full-at-"):
                assert row["fail_write_remaining"] == 0
            if cut.startswith("sync-error-"):
                assert row["fail_sync_remaining"] == 0
            row.update(journal=journal, cut=cut, old=old, new=new)
            row["success_without_new_key"] = row.get("rekey_return") == 0 and new["read_return"] != 0
            result["rekeys"].append(row); print(json.dumps(row), flush=True); save()

    # Retained history is unbounded; one larger fixture exposes rekey's linear
    # work and journal-space cost. This is a scaling sample, not a latency SLA.
    for journal in ("WAL", "DELETE"):
        db = out / f"large-rekey-{journal}.db"
        run("seed", db, journal, 100000)
        size = db.stat().st_size
        row = run("rekey", db, "none")
        verified = run("key", db, "new")
        assert row["rekey_return"] == 0 and verified["data_return"] == 101 and verified["verified_history_rows"] == 100000
        row.update(journal=journal, database_bytes=size, verified=verified)
        result["rekey_scaling"].append(row); print(json.dumps(row), flush=True); save()

    db = out / "reader.db"
    run("seed", db, "WAL", 100)
    result["reader_checkpoint"] = run("append", db, 1000, 1)
    # Damage a positively located historical overflow page, not a guessed offset.
    db = out / "damaged-history.db"
    run("seed", db, "DELETE", 100)
    location = run("corrupt", db, "locate")
    offset = (location["page"] - 1) * location["page_size"] + 100
    with db.open("r+b") as f:
        f.seek(offset); original = f.read(1); assert original
        f.seek(offset); f.write(bytes([original[0] ^ 1])); f.flush(); os.fsync(f.fileno())
    # Its separate cache and last row still work; this must not be advertised
    # as authentication of all unread retained history.
    result["damage"].append(dict(location=location, startup=run("read", db, 100), scan=run("corrupt", db, "scan")))
    assert result["damage"][0]["scan"]["read_return"] != 101
    assert result["damage"][0]["scan"]["cipher_integrity_errors"] > 0
    save()
    if args.argon2_build:
        bridge = out / "bridge.h"
        bridge.write_text('#include "sqlite3.h"\n#include "argon2.h"\n')
        wrapper = out / "wrapping-probe"
        subprocess.run(["xcrun", "swiftc", "-O", "-warnings-as-errors", "-module-cache-path", str(out / "module-cache"), "-Xcc", "-DSQLITE_HAS_CODEC",
                        "-I", str(args.sqlcipher_build), "-I", str(args.argon2_build / "include"),
                        "-import-objc-header", str(bridge),
                        str(Path(__file__).with_name("SQLCipherKeyWrappingProbe.swift")),
                        str(args.sqlcipher_build / "libsqlite3.a"), str(args.argon2_build / "libargon2.a"),
                        "-framework", "Security", "-o", str(wrapper)], check=True)
        wrapped = subprocess.run([str(wrapper), str(out)], text=True, capture_output=True, check=True, timeout=60)
        result["wrapping"] = json.loads(wrapped.stdout)
    save()
    unexpected = sum(r["success_without_new_key"] for r in result["rekeys"])
    print(f"Completed; preservation checks passed; {unexpected} rekey success/verification mismatches: {out / 'results.json'}", flush=True)
    if unexpected:
        raise SystemExit("REKEY QUALIFICATION FAILED: successful return did not establish the new key; see retained results")


if __name__ == "__main__":
    main()
