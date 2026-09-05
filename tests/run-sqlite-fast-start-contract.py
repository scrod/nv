#!/usr/bin/env python3
"""Executable fast-start SQL contract, synthetic values, no production codec.

Reads the normative DDL. Transaction rollback is tested here; actual process/VFS
crash and SQLCipher checks live in run-sqlite-collection-protocol.py.
"""
import hashlib
import json
from pathlib import Path
import sqlite3
import struct
import tempfile


ROOT = Path(__file__).resolve().parents[1]
DDL = (ROOT / "docs/impl-proposal-5/LocalStore.md").read_text().split("```sql\n", 1)[1].split("```", 1)[0]
SCOPE = b"fixture/store/profile/reducer-v1"


def token(n):
    return n.to_bytes(16, "big")


def canonical(rows):
    # Fixture cell bytes stand for the entire value AND authoring context.
    result = b"fixture-current-state-v1" + struct.pack(">Q", len(rows))
    for birth, cell in sorted(rows.items()):
        result += struct.pack(">Q", len(birth)) + birth
        result += struct.pack(">Q", len(cell)) + cell
    return result


def digest(data):
    return hashlib.sha256(data).digest()


def packed(rows):
    # JSON is deliberately only a probe codec, not StartupCacheV1.
    return json.dumps([[k.hex(), v.hex()] for k, v in sorted(rows.items())]).encode()


def unpack(data):
    pairs = [(bytes.fromhex(k), bytes.fromhex(v)) for k, v in json.loads(data)]
    assert pairs == sorted(pairs) and len(dict(pairs)) == len(pairs)
    return dict(pairs)


class Store:
    def __init__(self, path):
        self.db = sqlite3.connect(path)
        self.db.execute("PRAGMA foreign_keys=ON")
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")

    def create(self):
        self.db.executescript(DDL)
        self.db.executescript("""
            CREATE TABLE fixture_history(seq INTEGER PRIMARY KEY, mutation BLOB NOT NULL);
            CREATE TABLE fixture_dependencies(child INTEGER, parent INTEGER, PRIMARY KEY(child,parent));
            CREATE INDEX fixture_reverse ON fixture_dependencies(parent,child);
            CREATE TABLE fixture_received(id INTEGER PRIMARY KEY);
            CREATE TABLE fixture_accepted(id INTEGER PRIMARY KEY);
            CREATE TABLE fixture_ready(id INTEGER PRIMARY KEY);
        """)
        with self.db:
            self.db.execute("INSERT INTO view_meta VALUES(1,?,0,0,0,?)", (token(100), b"empty"))

    def meta(self):
        return self.db.execute("SELECT epoch,through_seq,cache_epoch,delta_floor,authoring_context FROM view_meta").fetchone()

    def high(self):
        return self.db.execute("SELECT COALESCE(MAX(seq),0) FROM acceptance_batches").fetchone()[0]

    def rows(self):
        return dict(self.db.execute("SELECT birth,cell FROM current_notes ORDER BY birth"))

    def accept(self, changes, branch=0):
        seq = self.high() + 1
        mutation = json.dumps([[k.hex(), v.hex() if v is not None else None] for k, v in changes.items()]).encode()
        with self.db:
            self.db.execute("INSERT INTO fixture_history VALUES(?,?)", (seq, mutation))
            self.db.execute("INSERT INTO acceptance_batches VALUES(?,?)", (seq, token(branch * 100 + seq)))
        return seq

    def materialize(self, mutation="safe", fail=False):
        start = self.meta()[1]
        tail = self.db.execute("SELECT seq,mutation FROM fixture_history WHERE seq>? ORDER BY seq", (start,)).fetchall()
        with self.db:
            for seq, data in tail:
                for key, val in json.loads(data):
                    birth = bytes.fromhex(key)
                    cell = None if val is None else bytes.fromhex(val)
                    if cell is None:
                        self.db.execute("DELETE FROM current_notes WHERE birth=?", (birth,))
                    else:
                        self.db.execute("INSERT INTO current_notes VALUES(?,?,?) ON CONFLICT(birth) DO UPDATE SET cell=excluded.cell, changed_seq=excluded.changed_seq", (birth, cell, seq))
                    if not (mutation == "omitDelete" and cell is None) and mutation != "omitContext":
                        self.db.execute("INSERT INTO view_changes VALUES(?,?)", (seq, birth))
                self.db.execute("UPDATE view_meta SET through_seq=?,authoring_context=?", (seq, token(seq)))
                if fail:
                    raise OSError("injected materialization failure")

    def capture(self):
        self.db.execute("BEGIN")
        try:
            epoch, cut, cache_epoch, _, _ = self.meta()
            bt = self.db.execute("SELECT token FROM acceptance_batches WHERE seq=?", (cut,)).fetchone()[0]
            rows = self.rows()
            return dict(scope=SCOPE, epoch=epoch, cut=cut, cache_epoch=cache_epoch,
                        token=bt, count=len(rows), source=digest(canonical(rows)), payload=packed(rows))
        finally:
            self.db.rollback()

    def publish_cache(self, cap, mutation="safe"):
        rows = unpack(cap["payload"])
        if mutation != "trustOutput" and (len(rows) != cap["count"] or digest(canonical(rows)) != cap["source"]):
            return False
        with self.db:
            epoch, through, cache_epoch, floor, _ = self.meta()
            bt = self.db.execute("SELECT token FROM acceptance_batches WHERE seq=?", (cap["cut"],)).fetchone()
            old = self.db.execute("SELECT through_seq FROM startup_cache").fetchone()
            if cap["scope"] != SCOPE or cap["epoch"] != epoch or cap["cut"] > through:
                return False
            if mutation != "staleBuilder" and (cap["cache_epoch"] != cache_epoch or cap["cut"] < floor):
                return False
            if not bt or bt[0] != cap["token"] or (old and old[0] > cap["cut"]):
                return False
            source = digest(canonical(rows)) if mutation == "trustOutput" else cap["source"]
            self.db.execute("INSERT OR REPLACE INTO startup_cache VALUES(1,?,?,?,?,?,?,?,?)", (
                cap["scope"], cap["epoch"], cap["cut"], cap["token"], cap["count"], source,
                digest(cap["payload"]), cap["payload"]))
        return True

    def discard_cache(self):
        with self.db:
            self.db.execute("DELETE FROM startup_cache")
            self.db.execute("UPDATE view_meta SET cache_epoch=cache_epoch+1,delta_floor=through_seq")
            self.db.execute("DELETE FROM view_changes WHERE seq <= (SELECT delta_floor FROM view_meta)")

    def prepare(self, mutation="safe"):
        # Caller owns startup admission fence; test can deliberately violate it.
        assert self.meta()[1] == self.high(), "materialization not caught up"
        self.db.execute("BEGIN")
        try:
            epoch, through, _, floor, context = self.meta()
            cache = self.db.execute("SELECT scope,view_epoch,through_seq,batch_token,row_count,state_digest,payload_digest,payload FROM startup_cache").fetchone()
            rows, used = None, False
            if cache:
                scope, ce, cut, bt, count, sd, pd, data = cache
                actual = self.db.execute("SELECT token FROM acceptance_batches WHERE seq=?", (cut,)).fetchone()
                valid = scope == SCOPE and ce == epoch and floor <= cut <= through and actual
                valid = valid and (mutation == "ignoreToken" or actual[0] == bt)
                if valid and digest(data) == pd:
                    try:
                        candidate = unpack(data)
                    except (ValueError, TypeError, AssertionError):
                        candidate = None
                    if candidate is not None and len(candidate) == count and digest(canonical(candidate)) == sd:
                        rows, used = candidate, True
                        for (birth,) in self.db.execute("SELECT DISTINCT birth FROM view_changes WHERE seq>? AND seq<=?", (cut, through)):
                            row = self.db.execute("SELECT cell FROM current_notes WHERE birth=?", (birth,)).fetchone()
                            if row:
                                rows[birth] = row[0]
                            else:
                                rows.pop(birth, None)
            if rows is None:
                rows = self.rows()
            return dict(rows=rows, context=context, epoch=epoch, through=through, used=used)
        finally:
            self.db.rollback()

    def publish_model(self, result, mutation="safe"):
        epoch, through, _, _, _ = self.meta()
        return result["epoch"] == epoch and result["through"] == through and (mutation == "staleStartup" or through == self.high())


def run():
    checks = []
    with tempfile.TemporaryDirectory(prefix="nv-fast-start-") as directory:
        def fresh(name):
            s = Store(str(Path(directory) / name))
            s.create()
            s.accept({b"a": b"A/context1", b"b": b"B/context1"})
            s.materialize()
            return s

        def check(name, condition):
            assert condition, name
            checks.append(name)

        s = fresh("main.sqlite")
        cap = s.capture()
        check("publish captured cache", s.publish_cache(cap))
        s.accept({b"a": None})
        s.accept({b"b": b"B/context3"})  # Displayed body unchanged, context advanced.
        try:
            s.materialize(fail=True)
        except OSError:
            pass
        check("view rollback does not undo acceptance", s.high() == 3 and s.meta()[1] == 1 and b"a" in s.rows())
        s.db.close()
        s = Store(str(Path(directory) / "main.sqlite"))
        s.materialize()
        result = s.prepare()
        check("cache catches deletion and metadata after reopen", result["used"] and result["rows"] == {b"b": b"B/context3"} and result["context"] == token(3))
        check("fresh startup publication", s.publish_model(result))
        s.accept({b"fresh-restored-birth": b"A/context4"})
        check("reject stale startup result", not s.publish_model(result))
        check("negative control stale publication", s.publish_model(result, "staleStartup"))
        s.materialize()
        check("restoration uses distinct birth", s.prepare()["rows"] == {b"b": b"B/context3", b"fresh-restored-birth": b"A/context4"})
        delayed = s.capture()
        s.accept({b"b": b"new/context5"})
        s.materialize()
        s.discard_cache()
        check("reject builder after delta pruning", not s.publish_cache(delayed))
        check("negative control stale builder", s.publish_cache(delayed, "staleBuilder"))
        check("reader floor guard rejects resurrected cache", not s.prepare()["used"])
        s.discard_cache()
        check("cacheless current rows", s.prepare()["rows"][b"b"] == b"new/context5")
        bad = s.capture()
        bad["payload"] = packed({b"b": b"wrong", b"fresh-restored-birth": b"A/context4"})
        check("reject semantically wrong but encodable cache", not s.publish_cache(bad))
        check("negative control trusting own output", s.publish_cache(bad, "trustOutput") and s.prepare()["rows"][b"b"] == b"wrong")
        check("good builder replaces bad cache", s.publish_cache(s.capture()) and s.prepare()["rows"][b"b"] == b"new/context5")
        with s.db:
            s.db.execute("UPDATE startup_cache SET batch_token=?", (token(999),))
        check("reject equal-number other-branch cache", not s.prepare()["used"])
        check("negative control numerical coverage only", s.prepare("ignoreToken")["used"])
        check("rebuild cache", s.publish_cache(s.capture()))
        with s.db:
            s.db.execute("UPDATE startup_cache SET payload_digest=?", (bytes(32),))
        check("corrupt optional cache falls back", not s.prepare()["used"] and b"b" in s.prepare()["rows"])
        with s.db:
            s.db.execute("UPDATE startup_cache SET payload=?,payload_digest=?", (b"invalid-json", digest(b"invalid-json")))
        check("valid-hash malformed cache falls back", not s.prepare()["used"])
        with s.db:
            s.db.execute("UPDATE startup_cache SET scope=?", (b"foreign",))
        check("foreign cache falls back", not s.prepare()["used"])

        for mutant, changes in (("omitDelete", {b"a": None}), ("omitContext", {b"b": b"B/context2"})):
            m = fresh(mutant)
            m.publish_cache(m.capture())
            m.accept(changes)
            m.materialize(mutant)
            check("negative control " + mutant, m.prepare()["rows"] != m.rows())
            m.db.close()

        # Multi-parent wakeup is a candidate queue, not authority to accept.
        with s.db:
            s.db.executemany("INSERT INTO fixture_dependencies VALUES(3,?)", [(1,), (2,)])
            s.db.execute("INSERT INTO fixture_received VALUES(3)")
        def parent_arrives(parent):
            with s.db:
                s.db.execute("INSERT OR IGNORE INTO fixture_accepted VALUES(?)", (parent,))
                s.db.execute("INSERT OR IGNORE INTO fixture_ready SELECT child FROM fixture_dependencies WHERE parent=? AND child NOT IN (SELECT id FROM fixture_accepted)", (parent,))
        def accept_child():
            with s.db:
                missing = s.db.execute("SELECT parent FROM fixture_dependencies WHERE child=3 AND parent NOT IN (SELECT id FROM fixture_accepted)").fetchall()
                if not missing:
                    s.db.execute("INSERT OR IGNORE INTO fixture_accepted VALUES(3)")
                s.db.execute("DELETE FROM fixture_ready WHERE id=3")
            return not missing
        parent_arrives(1)
        check("one parent cannot authorize child", not accept_child())
        parent_arrives(2)
        s.db.close()
        s = Store(str(Path(directory) / "main.sqlite"))
        check("late parent leaves durable wakeup across reopen", s.db.execute("SELECT id FROM fixture_ready").fetchall() == [(3,)])
        check("all parents permit child", accept_child())
        parent_arrives(2)
        check("duplicate parent cannot reaccept child", not s.db.execute("SELECT id FROM fixture_ready").fetchall())

        # Query/read boundaries, not a misleading cached-I/O speed benchmark.
        # Unread old BLOBs represent history already validated at acceptance.
        s.publish_cache(s.capture())
        with s.db:
            s.db.execute("CREATE TABLE fixture_old_objects(id INTEGER PRIMARY KEY, bytes BLOB)")
            s.db.executemany("INSERT INTO fixture_old_objects VALUES(?,zeroblob(4096))", [(i,) for i in range(10000)])
        reads = set()
        def authorize(action, table, column, database, trigger):
            if action == sqlite3.SQLITE_READ:
                reads.add(table)
                if table in {"fixture_old_objects", "fixture_history"}:
                    return sqlite3.SQLITE_DENY
            return sqlite3.SQLITE_OK
        s.db.set_authorizer(authorize)
        check("healthy fast path reads no old object/history rows", s.prepare()["used"])
        s.discard_cache()
        check("cacheless fast path reads no old object/history rows", not s.prepare()["used"])
        plans = s.db.execute("EXPLAIN QUERY PLAN SELECT DISTINCT birth FROM view_changes WHERE seq > ? AND seq <= ?", (1, 5)).fetchall()
        check("delta query uses bounded primary-key search", any("SEARCH view_changes USING PRIMARY KEY" in p[3] for p in plans))
        s.db.set_authorizer(None)
        s.db.close()
    print(json.dumps({"sqlite_version": sqlite3.sqlite_version, "checked": len(checks), "checks": checks}, indent=2))


if __name__ == "__main__":
    run()
