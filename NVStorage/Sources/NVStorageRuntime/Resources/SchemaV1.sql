-- Private collection schema, first save/reopen increment. See sqlite-local-schema.md.
-- Initialize a NEW, exclusively owned, keyed database inside one transaction.
-- Deliberately no IF NOT EXISTS: an existing/incomplete/unknown schema is not init.
-- Configure and verify foreign_keys=ON BEFORE BEGIN on every connection.
-- Local counters are signed Int64. Wire UInt64 sequences are big-endian BLOBs.

CREATE TABLE store_header (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    schema_version INTEGER NOT NULL CHECK (schema_version = 3),
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

-- Preserved candidates rejected by the named validator revision.
CREATE TABLE rejected_objects (
    object_id BLOB PRIMARY KEY REFERENCES objects(object_id),
    validator_version INTEGER NOT NULL CHECK (validator_version = 1),
    reason INTEGER NOT NULL CHECK (typeof(reason) = 'integer' AND (reason BETWEEN 1 AND 7 OR reason BETWEEN 20 AND 37))
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
    kind INTEGER NOT NULL CHECK (typeof(kind) = 'integer' AND kind BETWEEN 1 AND 9),
    birth BLOB,
    action_id BLOB REFERENCES actions(action_id) DEFERRABLE INITIALLY DEFERRED,
    source_object BLOB NOT NULL,
    source_index INTEGER NOT NULL CHECK (typeof(source_index) = 'integer' AND source_index BETWEEN 0 AND 4294967295),
    first_seq INTEGER NOT NULL,
    CHECK ((kind IN (1, 2) AND birth IS NULL AND action_id IS NULL)
        OR (kind BETWEEN 3 AND 9 AND typeof(birth) = 'blob' AND length(birth) = 16
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
-- Lazy Recently Deleted enumeration seeks through explicit Delete identities.
CREATE INDEX operations_deletions ON operations(operation_id) WHERE kind=6;
-- Bound reverse foreign-key checks when inserting an action with deferred members.
CREATE INDEX operations_action ON operations(action_id, operation_id);
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
    kind INTEGER NOT NULL CHECK (typeof(kind) = 'integer' AND kind BETWEEN 1 AND 12),
    source_object BLOB NOT NULL,
    source_index INTEGER NOT NULL CHECK (typeof(source_index) = 'integer' AND source_index BETWEEN 0 AND 4294967295),
    first_seq INTEGER NOT NULL,
    CHECK (previous_origin_action IS NULL OR previous_origin_action != action_id),
    FOREIGN KEY (source_object, first_seq) REFERENCES accepted_objects(object_id, seq),
    FOREIGN KEY (source_object, source_index, action_id)
        REFERENCES action_occurrences(object_id, record_index, action_id) DEFERRABLE INITIALLY DEFERRED
) WITHOUT ROWID;
CREATE INDEX actions_batch ON actions(first_seq, action_id);
CREATE INDEX actions_conflict_copies ON actions(first_seq, action_id) WHERE kind=9;
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

-- First accepted restoration per source entry; full provenance stays in action records.
CREATE TABLE restorations (
    source_birth BLOB NOT NULL CHECK (typeof(source_birth) = 'blob' AND length(source_birth) = 16),
    deletion_action BLOB NOT NULL REFERENCES actions(action_id) DEFERRABLE INITIALLY DEFERRED,
    action_id BLOB NOT NULL REFERENCES actions(action_id) DEFERRABLE INITIALLY DEFERRED,
    PRIMARY KEY (source_birth, deletion_action)
) WITHOUT ROWID;
CREATE INDEX restorations_action ON restorations(action_id);
CREATE INDEX restorations_deletion ON restorations(deletion_action);

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
-- Retained previews and frozen decisions have independent indexed owners.
CREATE TABLE pending_payloads (
    snapshot_id BLOB NOT NULL UNIQUE CHECK (typeof(snapshot_id)='blob' AND length(snapshot_id)=16),
    codec INTEGER NOT NULL CHECK (typeof(codec)='integer' AND codec>0),
    encoded BLOB NOT NULL CHECK (typeof(encoded)='blob' AND length(encoded) BETWEEN 1 AND 67108864)
);
CREATE TRIGGER pending_payloads_immutable BEFORE UPDATE ON pending_payloads BEGIN
    SELECT RAISE(ABORT, 'immutable pending input');
END;
CREATE TABLE pending_items (
    item_id BLOB PRIMARY KEY CHECK (typeof(item_id)='blob' AND length(item_id)=16),
    generation INTEGER NOT NULL CHECK (typeof(generation)='integer' AND generation>0),
    latest BLOB REFERENCES pending_payloads(snapshot_id),
    status INTEGER NOT NULL CHECK (typeof(status)='integer' AND status IN (1,2,3)),
    CHECK (latest IS NOT NULL OR status=3)
) WITHOUT ROWID;
CREATE INDEX pending_items_latest ON pending_items(latest);
CREATE TABLE pending_reservations (
    reservation_id BLOB NOT NULL UNIQUE CHECK (typeof(reservation_id)='blob' AND length(reservation_id)=16),
    item_id BLOB NOT NULL REFERENCES pending_items(item_id),
    snapshot_id BLOB NOT NULL REFERENCES pending_payloads(snapshot_id),
    operation_id BLOB CHECK (operation_id IS NULL OR (typeof(operation_id)='blob' AND length(operation_id)=32)),
    codec INTEGER NOT NULL CHECK (typeof(codec)='integer' AND codec>0),
    encoded BLOB NOT NULL CHECK (typeof(encoded)='blob' AND length(encoded) BETWEEN 1 AND 67108864)
);
CREATE INDEX pending_reservations_item ON pending_reservations(item_id,reservation_id);
CREATE UNIQUE INDEX pending_reservations_observation ON pending_reservations(item_id,snapshot_id);
CREATE INDEX pending_reservations_snapshot ON pending_reservations(snapshot_id);
CREATE INDEX pending_reservations_operation ON pending_reservations(operation_id);
-- Historical consumed-observation links survive payload release and later note Delete.
CREATE TABLE pending_settlements (
    item_id BLOB NOT NULL REFERENCES pending_items(item_id),
    snapshot_id BLOB NOT NULL CHECK (typeof(snapshot_id)='blob' AND length(snapshot_id)=16),
    reservation_id BLOB NOT NULL CHECK (typeof(reservation_id)='blob' AND length(reservation_id)=16),
    operation_id BLOB CHECK (operation_id IS NULL OR (typeof(operation_id)='blob' AND length(operation_id)=32)),
    birth BLOB NOT NULL CHECK (typeof(birth)='blob' AND length(birth)=16),
    decision_digest BLOB NOT NULL CHECK (typeof(decision_digest)='blob' AND length(decision_digest)=32),
    observation_codec INTEGER NOT NULL CHECK (typeof(observation_codec)='integer' AND observation_codec>0),
    observation BLOB NOT NULL CHECK (typeof(observation)='blob' AND length(observation)<=67108864),
    PRIMARY KEY(item_id,snapshot_id)
);
CREATE INDEX pending_settlements_operation ON pending_settlements(operation_id);

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

-- Derived immutable codec metadata; current cells carry the complete digest.
CREATE TABLE current_dictionaries (
    dictionary_id BLOB NOT NULL UNIQUE CHECK (typeof(dictionary_id) = 'blob' AND length(dictionary_id) = 32),
    encoded BLOB NOT NULL CHECK (typeof(encoded) = 'blob' AND length(encoded) BETWEEN 8 AND 8192)
);
CREATE TRIGGER current_dictionaries_no_update BEFORE UPDATE ON current_dictionaries BEGIN
    SELECT RAISE(ABORT, 'immutable current dictionary');
END;
CREATE TRIGGER current_dictionaries_no_replace BEFORE INSERT ON current_dictionaries
WHEN EXISTS (SELECT 1 FROM current_dictionaries WHERE dictionary_id = NEW.dictionary_id) BEGIN
    SELECT RAISE(ABORT, 'compare existing current dictionary');
END;
