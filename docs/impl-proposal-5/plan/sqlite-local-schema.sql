-- Private collection schema, first save/reopen increment. See sqlite-local-schema.md.
-- Initialize a NEW, exclusively owned, keyed database inside one transaction.
-- Deliberately no IF NOT EXISTS: an existing/incomplete/unknown schema is not init.
-- Configure and verify foreign_keys=ON BEFORE BEGIN on every connection.
-- Local counters are signed Int64. Wire UInt64 sequences are big-endian BLOBs.

CREATE TABLE store_header (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    schema_version INTEGER NOT NULL CHECK (schema_version = 1),
    local_store_id BLOB NOT NULL CHECK (typeof(local_store_id) = 'blob' AND length(local_store_id) = 16),
    collection_id BLOB NOT NULL CHECK (typeof(collection_id) = 'blob' AND length(collection_id) = 16),
    profile INTEGER NOT NULL CHECK (profile IN (1, 2)),
    key_id BLOB NOT NULL CHECK (typeof(key_id) = 'blob' AND length(key_id) = 16),
    note_codec INTEGER NOT NULL CHECK (note_codec = 1),
    merge_policy INTEGER NOT NULL CHECK (merge_policy = 1),
    genesis_locator BLOB NOT NULL CHECK (typeof(genesis_locator) = 'blob' AND length(genesis_locator) = 56),
    bootstrap_descriptor BLOB NOT NULL CHECK (typeof(bootstrap_descriptor) = 'blob' AND length(bootstrap_descriptor) = 32),
    CHECK ((profile = 1 AND key_id = zeroblob(16)) OR (profile = 2 AND key_id != zeroblob(16)))
);

-- Ordinary rowid table: large envelope BLOBs do not live in an index B-tree.
-- kind 0 = descriptor; 1/2/3 = changes/snapshot root/snapshot page envelope.
CREATE TABLE objects (
    object_id BLOB NOT NULL UNIQUE CHECK (typeof(object_id) = 'blob' AND length(object_id) = 32),
    kind INTEGER NOT NULL CHECK (kind IN (0, 1, 2, 3)),
    writer_epoch BLOB,
    sequence BLOB,
    -- Payload ceiling PLUS 124-byte header and the larger 32-byte public trailer.
    encoded BLOB NOT NULL CHECK (typeof(encoded) = 'blob' AND length(encoded) BETWEEN 1 AND 67174556),
    CHECK ((kind = 0 AND writer_epoch IS NULL AND sequence IS NULL AND length(encoded) <= 16384)
        OR (kind != 0 AND typeof(writer_epoch) = 'blob' AND length(writer_epoch) = 16
            AND typeof(sequence) = 'blob' AND length(sequence) = 8))
);
-- Never UNIQUE(writer_epoch, sequence): restored/cloned writers can disclose forks.
CREATE INDEX objects_locator ON objects(writer_epoch, sequence, object_id);
CREATE TRIGGER objects_no_update BEFORE UPDATE ON objects BEGIN
    SELECT RAISE(ABORT, 'immutable object');
END;
CREATE TRIGGER objects_no_replace BEFORE INSERT ON objects
WHEN EXISTS (SELECT 1 FROM objects WHERE object_id = NEW.object_id) BEGIN
    SELECT RAISE(ABORT, 'compare existing object; do not replace');
END;

CREATE TABLE acceptance_batches (
    seq INTEGER PRIMARY KEY CHECK (seq > 0)
);
CREATE TABLE accepted_objects (
    object_id BLOB PRIMARY KEY REFERENCES objects(object_id),
    seq INTEGER NOT NULL REFERENCES acceptance_batches(seq),
    UNIQUE (object_id, seq)
) WITHOUT ROWID;
CREATE INDEX accepted_objects_batch ON accepted_objects(seq, object_id);

-- Actual validated object closure, not operation causality or note supersession.
-- Deferred constraints permit acceptance of one completely validated bootstrap unit.
CREATE TABLE accepted_dependencies (
    child BLOB NOT NULL REFERENCES accepted_objects(object_id) DEFERRABLE INITIALLY DEFERRED,
    prerequisite BLOB NOT NULL REFERENCES accepted_objects(object_id) DEFERRABLE INITIALLY DEFERRED,
    CHECK (child != prerequisite),
    PRIMARY KEY (child, prerequisite)
) WITHOUT ROWID;
CREATE INDEX accepted_dependencies_reverse ON accepted_dependencies(prerequisite, child);

-- Missing prerequisite IDs MUST NOT reference objects/accepted_objects: absence is valid here.
CREATE TABLE object_waits (
    child BLOB NOT NULL REFERENCES objects(object_id),
    prerequisite BLOB NOT NULL CHECK (typeof(prerequisite) = 'blob' AND length(prerequisite) = 32),
    CHECK (child != prerequisite),
    PRIMARY KEY (child, prerequisite)
) WITHOUT ROWID;
CREATE INDEX object_waits_reverse ON object_waits(prerequisite, child);
CREATE TABLE ready_objects (
    object_id BLOB PRIMARY KEY REFERENCES objects(object_id)
) WITHOUT ROWID;

-- Wakeups are part of the accepting transaction, not post-commit callbacks.
-- Waking on ANY parent is intentional; validation rechecks ALL prerequisites.
CREATE TRIGGER accepted_object_ready AFTER INSERT ON accepted_objects BEGIN
    DELETE FROM ready_objects WHERE object_id = NEW.object_id;
    DELETE FROM object_waits WHERE child = NEW.object_id;
    INSERT INTO ready_objects(object_id)
        SELECT child FROM object_waits WHERE prerequisite = NEW.object_id
        AND NOT EXISTS (SELECT 1 FROM accepted_objects a WHERE a.object_id = child)
        ON CONFLICT(object_id) DO NOTHING;
END;

-- One logical record; full values remain in exact object bytes, not a second history BLOB.
-- The representative occurrence supplies bounded, lazy access to its original record.
CREATE TABLE operations (
    operation_id BLOB PRIMARY KEY CHECK (typeof(operation_id) = 'blob' AND length(operation_id) = 32),
    kind INTEGER NOT NULL CHECK (kind IN (1, 2, 3, 4, 5, 6)),
    birth BLOB,
    action_id BLOB REFERENCES actions(action_id) DEFERRABLE INITIALLY DEFERRED,
    source_object BLOB NOT NULL,
    source_index INTEGER NOT NULL CHECK (typeof(source_index) = 'integer' AND source_index BETWEEN 0 AND 4294967295),
    first_seq INTEGER NOT NULL,
    CHECK ((kind IN (1, 2) AND birth IS NULL AND action_id IS NULL)
        OR (kind BETWEEN 3 AND 6 AND typeof(birth) = 'blob' AND length(birth) = 16
            AND typeof(action_id) = 'blob' AND length(action_id) = 16)),
    UNIQUE (operation_id, action_id),
    FOREIGN KEY (source_object, first_seq) REFERENCES accepted_objects(object_id, seq),
    FOREIGN KEY (source_object, source_index, operation_id)
        REFERENCES operation_occurrences(object_id, record_index, operation_id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (action_id, operation_id)
        REFERENCES action_members(action_id, operation_id) DEFERRABLE INITIALLY DEFERRED
) WITHOUT ROWID;
CREATE INDEX operations_batch ON operations(first_seq, operation_id);
CREATE INDEX operations_birth ON operations(birth, operation_id);
CREATE TABLE operation_occurrences (
    object_id BLOB NOT NULL REFERENCES accepted_objects(object_id),
    record_index INTEGER NOT NULL CHECK (typeof(record_index) = 'integer' AND record_index BETWEEN 0 AND 4294967295),
    operation_id BLOB NOT NULL REFERENCES operations(operation_id),
    PRIMARY KEY (object_id, record_index),
    UNIQUE (object_id, record_index, operation_id),
    UNIQUE (object_id, operation_id)
) WITHOUT ROWID;
CREATE INDEX operation_occurrences_identity ON operation_occurrences(operation_id, object_id);
CREATE TABLE operation_parents (
    child BLOB NOT NULL REFERENCES operations(operation_id),
    parent BLOB NOT NULL REFERENCES operations(operation_id),
    CHECK (child != parent),
    PRIMARY KEY (child, parent)
) WITHOUT ROWID;
CREATE INDEX operation_parents_reverse ON operation_parents(parent, child);
CREATE TABLE note_predecessors (
    child BLOB NOT NULL REFERENCES operations(operation_id),
    predecessor BLOB NOT NULL REFERENCES operations(operation_id),
    CHECK (child != predecessor),
    PRIMARY KEY (child, predecessor)
) WITHOUT ROWID;
CREATE INDEX note_predecessors_reverse ON note_predecessors(predecessor, child);

CREATE TABLE actions (
    action_id BLOB PRIMARY KEY CHECK (typeof(action_id) = 'blob' AND length(action_id) = 16),
    origin_id BLOB NOT NULL CHECK (typeof(origin_id) = 'blob' AND length(origin_id) = 16),
    previous_origin_action BLOB REFERENCES actions(action_id) DEFERRABLE INITIALLY DEFERRED,
    scope_birth BLOB CHECK (scope_birth IS NULL OR (typeof(scope_birth) = 'blob' AND length(scope_birth) = 16)),
    kind INTEGER NOT NULL CHECK (kind IN (1, 2, 3, 4, 5)),
    source_object BLOB NOT NULL,
    source_index INTEGER NOT NULL CHECK (typeof(source_index) = 'integer' AND source_index BETWEEN 0 AND 4294967295),
    first_seq INTEGER NOT NULL,
    CHECK (previous_origin_action IS NULL OR previous_origin_action != action_id),
    FOREIGN KEY (source_object, first_seq) REFERENCES accepted_objects(object_id, seq),
    FOREIGN KEY (source_object, source_index, action_id)
        REFERENCES action_occurrences(object_id, record_index, action_id) DEFERRABLE INITIALLY DEFERRED
) WITHOUT ROWID;
CREATE INDEX actions_batch ON actions(first_seq, action_id);
CREATE INDEX actions_scope ON actions(scope_birth, action_id);
CREATE INDEX actions_origin ON actions(origin_id, action_id);
CREATE INDEX actions_previous_origin ON actions(previous_origin_action, action_id);
CREATE TABLE action_occurrences (
    object_id BLOB NOT NULL REFERENCES accepted_objects(object_id),
    record_index INTEGER NOT NULL CHECK (typeof(record_index) = 'integer' AND record_index BETWEEN 0 AND 4294967295),
    action_id BLOB NOT NULL REFERENCES actions(action_id),
    PRIMARY KEY (object_id, record_index),
    UNIQUE (object_id, record_index, action_id),
    UNIQUE (object_id, action_id)
) WITHOUT ROWID;
CREATE INDEX action_occurrences_identity ON action_occurrences(action_id, object_id);
CREATE TABLE action_members (
    action_id BLOB NOT NULL REFERENCES actions(action_id),
    ordinal INTEGER NOT NULL CHECK (typeof(ordinal) = 'integer' AND ordinal BETWEEN 0 AND 4294967295),
    operation_id BLOB NOT NULL,
    PRIMARY KEY (action_id, ordinal),
    UNIQUE (action_id, operation_id),
    FOREIGN KEY (operation_id, action_id) REFERENCES operations(operation_id, action_id)
) WITHOUT ROWID;
CREATE INDEX action_members_operation ON action_members(operation_id, action_id);
CREATE TABLE action_scope_parents (
    child BLOB NOT NULL REFERENCES actions(action_id),
    parent BLOB NOT NULL REFERENCES actions(action_id),
    CHECK (child != parent),
    PRIMARY KEY (child, parent)
) WITHOUT ROWID;
CREATE INDEX action_scope_parents_reverse ON action_scope_parents(parent, child);

-- The required pin is not derived from current notes or publication flags.
CREATE TABLE retained_frontier (
    object_id BLOB PRIMARY KEY REFERENCES accepted_objects(object_id),
    locator BLOB NOT NULL CHECK (typeof(locator) = 'blob' AND length(locator) = 56
        AND substr(locator, 25, 32) = object_id)
) WITHOUT ROWID;
CREATE TABLE retained_descriptors (
    object_id BLOB PRIMARY KEY REFERENCES accepted_objects(object_id)
) WITHOUT ROWID;

-- Independently versioned settings/association groups; no aggregate state overwrite.
-- A new state group codec is enabled explicitly, not by accepting arbitrary names.
CREATE TABLE private_groups (
    group_key BLOB NOT NULL UNIQUE CHECK (typeof(group_key) = 'blob' AND length(group_key) BETWEEN 1 AND 256),
    generation INTEGER NOT NULL CHECK (typeof(generation) = 'integer' AND generation > 0),
    codec INTEGER NOT NULL CHECK (typeof(codec) = 'integer' AND codec > 0),
    payload BLOB NOT NULL CHECK (typeof(payload) = 'blob' AND length(payload) <= 67108864)
);

-- Current-row startup; no packed representation or cache-only delta tables.
CREATE TABLE view_meta (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    epoch BLOB NOT NULL CHECK (typeof(epoch) = 'blob' AND length(epoch) = 16),
    reducer_version INTEGER NOT NULL CHECK (reducer_version = 1),
    through_seq INTEGER NOT NULL CHECK (typeof(through_seq) = 'integer' AND through_seq >= 0),
    authoring_context BLOB NOT NULL CHECK (typeof(authoring_context) = 'blob')
);
CREATE TABLE current_notes (
    birth BLOB NOT NULL UNIQUE CHECK (typeof(birth) = 'blob' AND length(birth) = 16),
    cell BLOB NOT NULL CHECK (typeof(cell) = 'blob')
);
