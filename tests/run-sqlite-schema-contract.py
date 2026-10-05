#!/usr/bin/env python3
"""Exercise the actual first-increment DDL with SQLite, not a Swift NV adapter.

Object/record/cell bodies below are conspicuously synthetic, NOT wire fixtures or
an authentication/reducer oracle. SQL constraints, indexed access, transaction
visibility and process-exit recovery are real. No power-loss claim is made.
"""
import hashlib
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
DDL = (ROOT / "docs/impl-proposal-5/plan/sqlite-local-schema.sql").read_text()


def ident(n, width=16):
    return n.to_bytes(width, "big")


def fixture_object(name, kind=1, sequence=1):
    raw = b"NOT AN NV ENVELOPE: " + name.encode()
    oid = hashlib.sha256(raw).digest()
    return (oid, kind, ident(900) if kind else None,
            ident(sequence, 8) if kind else None, raw)


PARENT = fixture_object("genesis")
DESCRIPTOR = fixture_object("descriptor", kind=0)
CHILD = fixture_object("create", sequence=2)
LATE = fixture_object("late prerequisite", sequence=3)
G = ident(1, 32)
OP = ident(2, 32)
ACTION = ident(3)
BIRTH = ident(4)


def connect(path):
    db = sqlite3.connect(path)
    db.execute("PRAGMA foreign_keys=ON")
    assert db.execute("PRAGMA foreign_keys").fetchone() == (1,)
    assert db.execute("PRAGMA journal_mode=WAL").fetchone() == ("wal",)
    db.execute("PRAGMA synchronous=FULL")
    assert db.execute("PRAGMA synchronous").fetchone() == (2,)
    return db


def locator(obj):
    return obj[2] + obj[3] + obj[0]


def retain(db, obj):
    # Candidate retention + scheduling is a single caller-owned transaction.
    old = db.execute("SELECT kind,writer_epoch,sequence,encoded FROM objects WHERE object_id=?", (obj[0],)).fetchone()
    if old is not None:
        if old != obj[1:]:
            raise ValueError("contradictory exact object")
        return False
    db.execute("INSERT INTO objects VALUES(?,?,?,?,?)", obj)
    db.execute("INSERT INTO ready_objects VALUES(?)", (obj[0],))
    return True


def park(db, child, prerequisites):
    # Recheck after installing captured missing IDs: a stale worker cannot erase a wakeup.
    db.execute("DELETE FROM object_waits WHERE child=?", (child,))
    db.executemany("INSERT INTO object_waits VALUES(?,?)", [(child, p) for p in prerequisites])
    newly_satisfied = db.execute("""SELECT 1 FROM object_waits w JOIN accepted_objects a
        ON a.object_id=w.prerequisite WHERE w.child=? LIMIT 1""", (child,)).fetchone()
    if newly_satisfied:
        db.execute("INSERT INTO ready_objects VALUES(?) ON CONFLICT DO NOTHING", (child,))
    else:
        db.execute("DELETE FROM ready_objects WHERE object_id=?", (child,))


def accept_rows(db, obj, parents=(), operation=None, omit_member=False, batch=None,
                causal=(G,), predecessors=()):
    """Fixture transaction writes only; caller supplies already-decoded test records.

    This is NOT complete segment/action validation. Missing *declared* parents
    fail the deferred SQL FK. Omitted dependencies cannot be inferred by SQL.
    """
    if db.execute("SELECT 1 FROM accepted_objects WHERE object_id=?", (obj[0],)).fetchone():
        if db.execute("SELECT encoded FROM objects WHERE object_id=?", (obj[0],)).fetchone() != (obj[4],):
            raise ValueError("contradictory accepted bytes")
        return False
    retain(db, obj)
    seq = batch
    if seq is None:
        seq = db.execute("SELECT COALESCE(MAX(seq),0)+1 FROM acceptance_batches").fetchone()[0]
        db.execute("INSERT INTO acceptance_batches VALUES(?)", (seq,))
    db.execute("INSERT INTO accepted_objects VALUES(?,?)", (obj[0], seq))
    db.executemany("INSERT INTO accepted_dependencies VALUES(?,?)", [(obj[0], p) for p in parents])
    if operation:
        op, action, birth, kind = operation
        known = db.execute("SELECT 1 FROM operations WHERE operation_id=?", (op,)).fetchone()
        if not known:
            db.execute("INSERT INTO operations VALUES(?,?,?,?,?,?,?)", (op, kind, birth, action, obj[0], 0, seq))
            if action:
                action_kind = 5 if kind == 6 else 4 if kind in (3, 4) else 1
                db.execute("INSERT INTO actions VALUES(?,?,NULL,?,?,?,?,?)", (action, ident(500), birth, action_kind, obj[0], 0, seq))
                if not omit_member:
                    db.execute("INSERT INTO action_members VALUES(?,?,?)", (action, 0, op))
            if kind != 1:
                db.executemany("INSERT INTO operation_parents VALUES(?,?)", [(op, p) for p in causal])
            db.executemany("INSERT INTO note_predecessors VALUES(?,?)", [(op, p) for p in predecessors])
        db.execute("INSERT INTO operation_occurrences VALUES(?,?,?)", (obj[0], 0, op))
        if action:
            db.execute("INSERT INTO action_occurrences VALUES(?,?,?)", (obj[0], 0, action))
    # This fixture has a simple object chain; it is not the general maximal-pin reducer.
    db.executemany("DELETE FROM retained_frontier WHERE object_id=?", [(p,) for p in parents])
    if obj[1]:
        db.execute("INSERT INTO retained_frontier VALUES(?,?)", (obj[0], locator(obj)))
    else:
        db.execute("INSERT INTO retained_descriptors VALUES(?)", (obj[0],))
    return True


def initialize(db):
    db.executescript("BEGIN IMMEDIATE;\n" + DDL)
    try:
        db.execute("INSERT INTO store_header VALUES(1,1,?,?,1,?,1,1,?,?)",
                   (ident(10), ident(11), bytes(16), locator(PARENT), DESCRIPTOR[0]))
        db.execute("INSERT INTO view_meta VALUES(1,?,1,0,?)", (ident(12), b"fixture empty context"))
        db.execute("INSERT INTO private_groups VALUES(?,?,?,?)", (b"fixture-settings", 1, 1, b"original settings"))
        accept_rows(db, PARENT, operation=(G, None, None, 1))
        accept_rows(db, DESCRIPTOR, batch=1)
        db.commit()
    except BaseException:
        db.rollback()
        raise


class SchemaContract(unittest.TestCase):
    def setUp(self):
        if os.environ.get("NV_STORAGE_KEEP_ARTIFACTS") == "1":
            from types import SimpleNamespace
            self.tmp = SimpleNamespace(name=tempfile.mkdtemp(prefix="nv-sqlite-schema-"))
            print("Retained artifacts:", self.tmp.name, flush=True)
        else:
            self.tmp = tempfile.TemporaryDirectory(prefix="nv-sqlite-schema-")
            self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "Collection.sqlite"
        self.db = connect(self.path)
        self.addCleanup(self.db.close)
        initialize(self.db)

    def reject(self, sql, args=()):
        with self.assertRaises(sqlite3.IntegrityError):
            with self.db:
                self.db.execute(sql, args)

    def test_initialize_is_atomic_and_never_repairs_existing_schema(self):
        with self.assertRaises(sqlite3.OperationalError):
            self.db.executescript("BEGIN;\n" + DDL)
        self.db.rollback()
        self.assertEqual(self.db.execute("SELECT payload FROM private_groups").fetchone(), (b"original settings",))
        other = connect(Path(self.tmp.name) / "new.sqlite")
        try:
            other.executescript("BEGIN;\n" + DDL)
            other.rollback()
            self.assertEqual(other.execute("SELECT count(*) FROM sqlite_master").fetchone(), (0,))
        finally:
            other.close()

    def test_types_bounds_and_profile(self):
        for bad in ("x" * 32, b"x" * 31, None):
            self.reject("INSERT INTO objects VALUES(?,0,NULL,NULL,?)", (bad, b"fixture"))
        self.reject("INSERT INTO objects VALUES(?,0,NULL,NULL,zeroblob(16385))", (ident(90, 32),))
        self.reject("INSERT INTO acceptance_batches VALUES(0)")
        self.reject("INSERT INTO acceptance_batches VALUES(?)", ("not-an-integer",))
        self.reject("UPDATE store_header SET key_id=?", (ident(1),))
        self.reject("UPDATE store_header SET profile=2")
        self.reject("UPDATE private_groups SET generation=1.5")
        with self.db:
            accept_rows(self.db, CHILD, (PARENT[0],), (OP, ACTION, BIRTH, 3))
        self.reject("UPDATE operations SET kind=3.5 WHERE operation_id=?", (OP,))
        self.reject("UPDATE actions SET kind=4.5 WHERE action_id=?", (ACTION,))
        with self.db:
            retain(self.db, LATE)
            self.db.execute("INSERT INTO rejected_objects VALUES(?,1,1)", (LATE[0],))
        self.reject("UPDATE rejected_objects SET reason=1.5 WHERE object_id=?", (LATE[0],))
        self.reject("UPDATE rejected_objects SET reason=20.5 WHERE object_id=?", (LATE[0],))
        self.assertEqual(self.db.execute("SELECT reason FROM rejected_objects WHERE object_id=?", (LATE[0],)).fetchone(), (1,))

    def test_wire_uint64_and_forked_writer_slot_survive(self):
        one = fixture_object("fork one", sequence=2**64 - 1)
        two = fixture_object("fork two", sequence=2**64 - 1)
        with self.db:
            retain(self.db, one)
            retain(self.db, two)
        rows = self.db.execute("SELECT object_id FROM objects WHERE writer_epoch=? AND sequence=?", one[2:4]).fetchall()
        self.assertEqual({r[0] for r in rows}, {one[0], two[0]})

    def test_envelope_storage_bound_includes_header_and_trailer(self):
        # SQL retains exact envelope bytes, not just encodedLength payload bytes.
        with self.db:
            self.db.execute("INSERT INTO objects VALUES(?,1,?,?,zeroblob(67174556))",
                            (ident(91, 32), ident(900), ident(1, 8)))
        self.assertEqual(self.db.execute("SELECT length(encoded) FROM objects WHERE object_id=?",
                                        (ident(91, 32),)).fetchone(), (67174556,))
        self.reject("INSERT INTO objects VALUES(?,1,?,?,zeroblob(67174557))",
                    (ident(92, 32), ident(900), ident(1, 8)))

    def test_duplicate_object_and_no_replace(self):
        with self.db:
            self.assertFalse(accept_rows(self.db, PARENT))
        self.assertEqual(self.db.execute("SELECT count(*) FROM acceptance_batches").fetchone(), (1,))
        self.reject("UPDATE objects SET encoded=? WHERE object_id=?", (b"changed", PARENT[0]))
        self.reject("INSERT OR REPLACE INTO objects VALUES(?,?,?,?,?)", (*PARENT[:4], b"changed"))

    def test_pending_latest_frozen_and_consumed_reference_constraints(self):
        a, b, item, reservation = ident(101), ident(102), ident(103), ident(104)
        with self.db:
            self.db.execute("INSERT INTO pending_payloads VALUES(?,1,?)", (a, b"synthetic A"))
            self.db.execute("INSERT INTO pending_items VALUES(?,1,?,1)", (item, a))
            self.db.execute("INSERT INTO pending_reservations VALUES(?,?,?,NULL,1,?)", (reservation, item, a, b"synthetic reservation"))
        self.reject("INSERT INTO pending_reservations VALUES(?,?,?,NULL,1,?)", (ident(105), item, a, b"duplicate observation"))
        self.reject("UPDATE pending_payloads SET encoded=? WHERE snapshot_id=?", (b"changed A", a))
        self.reject("DELETE FROM pending_payloads WHERE snapshot_id=?", (a,))
        with self.assertRaises(sqlite3.IntegrityError):
            with self.db:
                self.db.execute("INSERT INTO pending_payloads VALUES(?,1,?)", (b, b"synthetic B"))
                self.db.execute("UPDATE pending_items SET generation=2,latest=? WHERE item_id=?", (ident(999), item))
        self.assertEqual(self.db.execute("SELECT latest FROM pending_items").fetchone(), (a,))
        self.assertEqual(self.db.execute("SELECT count(*) FROM pending_payloads").fetchone(), (1,))
        with self.db:
            self.db.execute("INSERT INTO pending_payloads VALUES(?,1,?)", (b, b"synthetic B"))
            self.db.execute("UPDATE pending_items SET generation=2,latest=? WHERE item_id=?", (b, item))
        self.reject("DELETE FROM pending_payloads WHERE snapshot_id=?", (a,))
        with self.db:
            self.db.execute("INSERT INTO pending_settlements VALUES(?,?,?,NULL,?,?,1,?)", (item, a, reservation, BIRTH, ident(106, 32), b"observed"))
            self.db.execute("DELETE FROM pending_reservations WHERE reservation_id=?", (reservation,))
            self.db.execute("DELETE FROM pending_payloads WHERE snapshot_id=?", (a,))
        self.assertEqual(self.db.execute("SELECT snapshot_id,birth FROM pending_settlements").fetchone(), (a, BIRTH))
        self.assertEqual(self.db.execute("SELECT latest FROM pending_items").fetchone(), (b,))
        plan = self.db.execute("EXPLAIN QUERY PLAN SELECT * FROM pending_reservations WHERE item_id=? AND snapshot_id=?", (item, a)).fetchall()
        self.assertTrue(any('pending_reservations_observation' in row[3] for row in plan), plan)
        self.reject("DELETE FROM objects WHERE object_id=?", (PARENT[0],))
        with self.assertRaisesRegex(ValueError, "contradictory"):
            retain(self.db, (*PARENT[:4], b"changed"))

    def test_missing_parent_and_incomplete_membership_cannot_commit(self):
        for parents, omit in (((LATE[0],), False), ((PARENT[0],), True)):
            with self.subTest(parents=parents, omit_member=omit):
                with self.assertRaises(sqlite3.IntegrityError):
                    with self.db:
                        accept_rows(self.db, CHILD, parents, (OP, ACTION, BIRTH, 3), omit_member=omit)
                self.assertEqual(self.db.execute("SELECT count(*) FROM acceptance_batches").fetchone(), (1,))
                self.assertIsNone(self.db.execute("SELECT 1 FROM objects WHERE object_id=?", (CHILD[0],)).fetchone())

    def test_duplicate_envelope_adds_occurrence_not_logical_action(self):
        duplicate = fixture_object("same canonical record different envelope", sequence=8)
        with self.db:
            accept_rows(self.db, CHILD, (PARENT[0],), (OP, ACTION, BIRTH, 3))
        with self.db:
            accept_rows(self.db, duplicate, (PARENT[0],), (OP, ACTION, BIRTH, 3))
        self.assertEqual(self.db.execute("SELECT count(*) FROM operations").fetchone(), (2,))
        self.assertEqual(self.db.execute("SELECT count(*) FROM actions").fetchone(), (1,))
        self.assertEqual(self.db.execute("SELECT first_seq,source_object FROM operations WHERE operation_id=?", (OP,)).fetchone(), (2, CHILD[0]))
        self.assertEqual(self.db.execute("SELECT count(*) FROM operation_occurrences WHERE operation_id=?", (OP,)).fetchone(), (2,))
        self.assertEqual(self.db.execute("SELECT count(*) FROM accepted_objects").fetchone(), (4,))
        # No SQL claim that the two envelopes' decoded semantics actually agree.

    def test_occurrence_reference_cannot_substitute_another_object_or_slot(self):
        with self.db:
            accept_rows(self.db, CHILD, (PARENT[0],), (OP, ACTION, BIRTH, 3))
        self.reject("UPDATE operations SET source_object=? WHERE operation_id=?", (PARENT[0], OP))
        self.reject("UPDATE operations SET source_index=1 WHERE operation_id=?", (OP,))
        self.reject("DELETE FROM operation_occurrences WHERE object_id=?", (CHILD[0],))
        self.reject("UPDATE action_members SET operation_id=?", (G,))
        self.reject("UPDATE retained_frontier SET locator=zeroblob(56)")

    def test_causal_knowledge_does_not_become_note_supersession(self):
        a, b, e = (fixture_object(name, sequence=n) for n, name in ((4, "branch A"), (5, "branch B"), (6, "edit A only")))
        aid, bid, eid = (ident(n, 32) for n in (30, 31, 32))
        with self.db:
            accept_rows(self.db, CHILD, (PARENT[0],), (OP, ACTION, BIRTH, 3))
        with self.db:
            accept_rows(self.db, a, (CHILD[0],), (aid, ident(40), BIRTH, 5), causal=(OP,), predecessors=(OP,))
        with self.db:
            accept_rows(self.db, b, (CHILD[0],), (bid, ident(41), BIRTH, 5), causal=(OP,), predecessors=(OP,))
        with self.db:
            accept_rows(self.db, e, (a[0], b[0]), (eid, ident(42), BIRTH, 5), causal=(aid, bid), predecessors=(aid,))
        self.assertEqual(self.db.execute("SELECT parent FROM operation_parents WHERE child=? ORDER BY parent", (eid,)).fetchall(), [(aid,), (bid,)])
        self.assertEqual(self.db.execute("SELECT predecessor FROM note_predecessors WHERE child=?", (eid,)).fetchall(), [(aid,)])
        self.assertIsNone(self.db.execute("SELECT child FROM note_predecessors WHERE predecessor=?", (bid,)).fetchone())

    def test_completed_operation_lookup_does_not_require_live_birth(self):
        deletion = fixture_object("later logical Delete", sequence=4)
        with self.db:
            accept_rows(self.db, CHILD, (PARENT[0],), (OP, ACTION, BIRTH, 3))
        with self.db:
            self.db.execute("INSERT INTO current_notes VALUES(?,?)", (BIRTH, b"fixture value"))
        with self.db:
            accept_rows(self.db, deletion, (CHILD[0],), (ident(55, 32), ident(56), BIRTH, 6), causal=(OP,))
        with self.db:
            self.db.execute("DELETE FROM current_notes WHERE birth=?", (BIRTH,))
            self.db.execute("UPDATE view_meta SET through_seq=3,authoring_context=?", (b"fixture deleted context",))
        self.assertIsNone(self.db.execute("SELECT 1 FROM current_notes WHERE birth=?", (BIRTH,)).fetchone())
        self.assertEqual(self.db.execute("SELECT action_id,first_seq FROM operations WHERE operation_id=?", (OP,)).fetchone(), (ACTION, 2))
        self.assertEqual(self.db.execute("SELECT encoded FROM objects WHERE object_id=?", (CHILD[0],)).fetchone(), (CHILD[4],))

    def test_ready_survives_parent_commit_and_rechecks_second_parent(self):
        with self.db:
            retain(self.db, CHILD)
            park(self.db, CHILD[0], (LATE[0],))
        self.assertIsNone(self.db.execute("SELECT 1 FROM ready_objects").fetchone())
        with self.db:
            accept_rows(self.db, LATE, (PARENT[0],))
        reader = connect(self.path)
        try:
            self.assertEqual(reader.execute("SELECT object_id FROM ready_objects").fetchall(), [(CHILD[0],)])
            self.assertIsNone(reader.execute("SELECT 1 FROM accepted_objects WHERE object_id=?", (CHILD[0],)).fetchone())
        finally:
            reader.close()
        # An old validation result arriving AFTER parent commit must not swallow the wakeup.
        with self.db:
            park(self.db, CHILD[0], (LATE[0],))
        self.assertEqual(self.db.execute("SELECT object_id FROM ready_objects").fetchall(), [(CHILD[0],)])
        absent = fixture_object("another missing parent")
        with self.assertRaises(sqlite3.IntegrityError):
            with self.db:
                accept_rows(self.db, CHILD, (LATE[0], absent[0]), (OP, ACTION, BIRTH, 3))
        with self.db:
            park(self.db, CHILD[0], (absent[0],))
        self.assertIsNone(self.db.execute("SELECT 1 FROM ready_objects").fetchone())
        with self.db:
            accept_rows(self.db, absent, (PARENT[0],))
        with self.db:
            accept_rows(self.db, CHILD, (LATE[0], absent[0]), (OP, ACTION, BIRTH, 3))
        self.assertEqual(self.db.execute("SELECT count(*) FROM object_waits").fetchone(), (0,))

    def test_failed_parent_commit_rolls_back_wakeup(self):
        with self.db:
            retain(self.db, CHILD)
            park(self.db, CHILD[0], (LATE[0],))
        with self.assertRaises(OSError):
            with self.db:
                accept_rows(self.db, LATE, (PARENT[0],))
                self.assertEqual(self.db.execute("SELECT object_id FROM ready_objects").fetchone(), (CHILD[0],))
                raise OSError("injected before commit")
        self.assertIsNone(self.db.execute("SELECT 1 FROM ready_objects").fetchone())
        self.assertEqual(self.db.execute("SELECT * FROM object_waits").fetchone(), (CHILD[0], LATE[0]))

    def test_reader_sees_whole_acceptance_and_no_stale_settings_overwrite(self):
        reader = connect(self.path)
        try:
            reader.execute("BEGIN")
            self.assertEqual(reader.execute("SELECT count(*) FROM operations").fetchone(), (1,))
            with self.db:
                self.db.execute("UPDATE private_groups SET generation=2,payload=? WHERE generation=1", (b"newer settings",))
            with self.db:
                accept_rows(self.db, CHILD, (PARENT[0],), (OP, ACTION, BIRTH, 3))
            self.assertEqual(reader.execute("SELECT count(*) FROM operations").fetchone(), (1,))
            reader.rollback()
            self.assertEqual(reader.execute("SELECT count(*) FROM operations").fetchone(), (2,))
            self.assertEqual(reader.execute("SELECT * FROM retained_frontier").fetchone(), (CHILD[0], locator(CHILD)))
            self.assertEqual(reader.execute("SELECT payload FROM private_groups").fetchone(), (b"newer settings",))
            with self.db:
                cur = self.db.execute("UPDATE private_groups SET payload=? WHERE group_key=? AND generation=1", (b"stale", b"fixture-settings"))
                self.assertEqual(cur.rowcount, 0)
        finally:
            reader.close()

    def test_materialization_is_independent_and_current_only(self):
        with self.db:
            accept_rows(self.db, CHILD, (PARENT[0],), (OP, ACTION, BIRTH, 3))
        self.assertEqual(self.db.execute("SELECT through_seq FROM view_meta").fetchone(), (0,))
        with self.assertRaises(OSError):
            with self.db:
                self.db.execute("INSERT INTO current_notes VALUES(?,?)", (BIRTH, b"fixture value and context"))
                self.db.execute("UPDATE view_meta SET through_seq=2")
                raise OSError("injected materialization failure")
        self.assertIsNone(self.db.execute("SELECT * FROM current_notes").fetchone())
        self.assertIsNotNone(self.db.execute("SELECT * FROM operations WHERE operation_id=?", (OP,)).fetchone())
        with self.db:
            self.db.execute("INSERT INTO current_notes VALUES(?,?)", (BIRTH, b"fixture value and context"))
            self.db.execute("UPDATE view_meta SET through_seq=2,authoring_context=?", (b"fixture global context",))
        self.assertEqual(self.db.execute("SELECT birth,cell FROM current_notes ORDER BY birth").fetchall(), [(BIRTH, b"fixture value and context")])
        self.assertIsNone(self.db.execute("SELECT name FROM sqlite_master WHERE name='startup_cache'").fetchone())

    def test_named_indexes_cover_tail_reverse_and_identity_queries(self):
        queries = [
            ("SELECT object_id FROM accepted_objects WHERE seq>? ORDER BY seq", (1,), "accepted_objects_batch"),
            ("SELECT child FROM object_waits WHERE prerequisite=?", (PARENT[0],), "object_waits_reverse"),
            ("SELECT operation_id FROM operations WHERE first_seq>?", (1,), "operations_batch"),
            ("SELECT operation_id FROM operations WHERE birth=? AND operation_id>? ORDER BY operation_id LIMIT 65", (BIRTH, G), "operations_birth"),
            ("SELECT operation_id FROM operations WHERE kind=6 AND operation_id>? ORDER BY operation_id LIMIT 65", (G,), "operations_deletions"),
            ("SELECT object_id FROM operation_occurrences WHERE operation_id=?", (G,), "operation_occurrences_identity"),
            ("SELECT child FROM note_predecessors WHERE predecessor=?", (G,), "note_predecessors_reverse"),
            ("SELECT action_id FROM actions WHERE scope_birth=?", (BIRTH,), "actions_scope"),
            ("SELECT action_id FROM restorations WHERE source_birth=? AND deletion_action=?", (BIRTH, ACTION), "PRIMARY KEY"),
        ]
        for sql, args, index in queries:
            with self.subTest(index=index):
                plan = " ".join(row[3] for row in self.db.execute("EXPLAIN QUERY PLAN " + sql, args))
                self.assertIn(index, plan)
                self.assertIn("SEARCH", plan)

    def test_foreign_key_negative_control(self):
        # The oracle detects the same forbidden orphan if connection setup omits FKs.
        self.db.execute("PRAGMA foreign_keys=OFF")
        with self.db:
            self.db.execute("INSERT INTO accepted_dependencies VALUES(?,?)", (PARENT[0], LATE[0]))
        self.assertTrue(self.db.execute("PRAGMA foreign_key_check").fetchall())

    def test_process_exit_before_and_after_commit(self):
        for boundary in ("before", "after"):
            with self.subTest(boundary=boundary):
                result = subprocess.run([sys.executable, __file__, "--crash-child", str(self.path), boundary], check=False)
                self.assertEqual(result.returncode, 73)
                reader = connect(self.path)
                try:
                    applied = boundary == "after"
                    self.assertEqual(reader.execute("SELECT count(*) FROM operations WHERE operation_id=?", (OP,)).fetchone(), (int(applied),))
                    self.assertEqual(reader.execute("SELECT count(*) FROM actions").fetchone(), (int(applied),))
                    expected_pin = (CHILD[0], locator(CHILD)) if applied else (PARENT[0], locator(PARENT))
                    self.assertEqual(reader.execute("SELECT * FROM retained_frontier").fetchone(), expected_pin)
                    self.assertEqual(reader.execute("PRAGMA foreign_key_check").fetchall(), [])
                    self.assertEqual(reader.execute("SELECT through_seq FROM view_meta").fetchone(), (0,))
                finally:
                    reader.close()


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--crash-child":
        connection = connect(sys.argv[2])
        connection.execute("BEGIN IMMEDIATE")
        accept_rows(connection, CHILD, (PARENT[0],), (OP, ACTION, BIRTH, 3))
        if sys.argv[3] == "after":
            connection.commit()
        os._exit(73)  # No clean close, rollback, callback or application state handoff.
    print("SQLite", sqlite3.sqlite_version, "— first-increment schema contract", flush=True)
    unittest.main(verbosity=2)
