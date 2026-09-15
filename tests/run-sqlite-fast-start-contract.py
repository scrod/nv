#!/usr/bin/env python3
"""Executable fast-start SQL contract, synthetic values, no production codec.

Reads the normative DDL. Transaction rollback is tested here; actual process/VFS
crash and SQLCipher checks live in run-sqlite-collection-protocol.py.
"""
import json
from pathlib import Path
import sqlite3
import tempfile


ROOT = Path(__file__).resolve().parents[1]
DDL = (ROOT / "docs/impl-proposal-5/plan/sqlite-local-schema.sql").read_text()


def token(n):
    return n.to_bytes(16, "big")


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
            self.db.execute("INSERT INTO view_meta VALUES(1,?,1,0,?)", (token(100), b"empty"))

    def meta(self):
        return self.db.execute("SELECT epoch,through_seq,authoring_context FROM view_meta").fetchone()

    def high(self):
        return self.db.execute("SELECT COALESCE(MAX(seq),0) FROM acceptance_batches").fetchone()[0]

    def rows(self):
        return dict(self.db.execute("SELECT birth,cell FROM current_notes ORDER BY rowid"))

    def accept(self, changes):
        seq = self.high() + 1
        mutation = json.dumps([[k.hex(), v.hex() if v is not None else None] for k, v in changes.items()]).encode()
        with self.db:
            self.db.execute("INSERT INTO fixture_history VALUES(?,?)", (seq, mutation))
            self.db.execute("INSERT INTO acceptance_batches VALUES(?)", (seq,))
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
                        if mutation == "omitDelete":
                            continue
                        self.db.execute("DELETE FROM current_notes WHERE birth=?", (birth,))
                    elif mutation != "omitContext":
                        self.db.execute("INSERT INTO current_notes VALUES(?,?) ON CONFLICT(birth) DO UPDATE SET cell=excluded.cell", (birth, cell))
                self.db.execute("UPDATE view_meta SET through_seq=?,authoring_context=?", (seq, token(seq)))
                if fail:
                    raise OSError("injected materialization failure")

    def prepare(self, concurrent=None):
        # Normal owner startup fence excludes concurrent acceptance; the test
        # deliberately permits it to exercise read consistency and final checks.
        self.db.execute("BEGIN")
        try:
            epoch, through, context = self.meta()
            assert through == self.high(), "materialization not caught up"
            if concurrent:
                concurrent()
            return dict(rows=self.rows(), context=context, epoch=epoch, through=through)
        finally:
            self.db.rollback()

    def publish_model(self, result, mutation="safe"):
        # Runs under the exclusive serial owner. Physical/lifecycle association
        # checks belong to the adapter, not this synthetic SQL fixture.
        epoch, through, _ = self.meta()
        return ((mutation == "staleEpoch" or result["epoch"] == epoch)
                and result["through"] == through
                and (mutation == "staleStartup" or through == self.high()))


def run():
    checks = []
    with tempfile.TemporaryDirectory(prefix="nv-fast-start-") as directory:
        def fresh(name):
            s = Store(str(Path(directory) / name))
            s.create()
            s.accept({token(1): b"A/context1", token(2): b"B/context1"})
            s.materialize()
            return s

        def check(name, condition):
            assert condition, name
            checks.append(name)

        s = fresh("main.sqlite")
        s.accept({token(1): None})
        s.accept({token(2): b"B/context3"})
        try:
            s.materialize(fail=True)
        except OSError:
            pass
        check("rollback preserves acceptance and complete old view", s.high() == 3 and s.meta()[1] == 1 and s.rows() == {token(1): b"A/context1", token(2): b"B/context1"})
        s.db.close()
        s = Store(str(Path(directory) / "main.sqlite"))
        s.materialize()
        result = s.prepare()
        check("reopen catches deletion and body-equal context", result["rows"] == {token(2): b"B/context3"} and result["context"] == token(3))
        check("fresh publication", s.publish_model(result))
        s.accept({token(3): b"A/context4"})
        check("reject newer unmaterialized acceptance", not s.publish_model(result))
        check("negative control stale startup", s.publish_model(result, "staleStartup"))
        s.materialize()
        check("restoration uses fresh birth", s.prepare()["rows"] == {token(2): b"B/context3", token(3): b"A/context4"})
        result = s.prepare()
        with s.db:
            s.db.execute("UPDATE view_meta SET epoch=?", (token(101),))
        check("reject old epoch at identical prefix", not s.publish_model(result))
        check("negative control stale epoch", s.publish_model(result, "staleEpoch"))
        check("fresh recapture succeeds", s.publish_model(s.prepare()))
        writer = Store(str(Path(directory) / "main.sqlite"))
        def advance():
            writer.accept({token(2): b"new/context5"})
            writer.materialize()
        captured = s.prepare(advance)
        check("read transaction cannot mix old prefix with new cells", captured["through"] == 4 and captured["rows"][token(2)] == b"B/context3")
        check("reject consistent but now stale capture", not s.publish_model(captured))
        writer.db.close()
        for mutant, changes, expected in (
            ("omitDelete", {token(1): None}, {token(2): b"B/context1"}),
            ("omitContext", {token(2): b"B/context2"}, {token(1): b"A/context1", token(2): b"B/context2"}),
        ):
            m = fresh(mutant)
            m.accept(changes)
            m.materialize(mutant)
            check("negative control " + mutant, m.prepare()["rows"] != expected)
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
        check("healthy startup reads no old object/history rows", s.prepare()["rows"] == {token(2): b"new/context5", token(3): b"A/context4"})
        check("no packed cache or delta tables", not s.db.execute("SELECT name FROM sqlite_master WHERE name IN ('startup_cache','view_changes')").fetchall())
        s.db.set_authorizer(None)
        plans = s.db.execute("EXPLAIN QUERY PLAN SELECT seq,mutation FROM fixture_history WHERE seq>? ORDER BY seq", (4,)).fetchall()
        check("catch-up uses indexed range search", any("SEARCH fixture_history USING INTEGER PRIMARY KEY" in p[3] for p in plans))
        plans = s.db.execute("EXPLAIN QUERY PLAN SELECT birth,cell FROM current_notes ORDER BY rowid").fetchall()
        check("startup scans current table without UUID index or sorting", any(p[3] == "SCAN current_notes" for p in plans)
              and not any("USING INDEX" in p[3] or "TEMP B-TREE" in p[3] for p in plans))
        s.db.close()
    print(json.dumps({"sqlite_version": sqlite3.sqlite_version, "checked": len(checks), "checks": checks}, indent=2))


if __name__ == "__main__":
    run()
