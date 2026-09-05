/* Exploratory local-store experiment, NOT the NV format or a production adapter.
 * One synthetic object per operation; no encryption, causal reducer, or AppKit.
 * The VFS shim counts SQLite read requests, not physical SSD reads. mmap is off.
 */
#include <sqlite3.h>
#include <assert.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

enum { NOTES = 1000, BODY = 1024, PAYLOAD = 4096, TAIL = 32 };
typedef struct { uint64_t note, object; unsigned char body[BODY]; } CachedNote;
typedef struct {
    sqlite3_file base;
    sqlite3_file *real;
    int flags;
} File;
static sqlite3_vfs *underlying;
static sqlite3_vfs counting;
static uint64_t reads, readBytes, dbReads, walReads, otherReads, jumps, syncs;
static uint64_t writes, writtenBytes, walHighWater, journalHighWater;
static sqlite3_int64 lastEnd = -1;
static int writeCut, syncCut, failWrite, failSync;

static void stop_for_kill(const char *stage) {
    printf("READY %s\n", stage); fflush(stdout);
    for (;;) pause();
}
static sqlite3_file *real(sqlite3_file *f) { return ((File *)f)->real; }
static int fClose(sqlite3_file *f) { return real(f)->pMethods->xClose(real(f)); }
static int fRead(sqlite3_file *f, void *b, int n, sqlite3_int64 off) {
    reads++; readBytes += (uint64_t)n;
    int flags = ((File *)f)->flags;
    if (flags & SQLITE_OPEN_MAIN_DB) {
        dbReads++;
        if (lastEnd >= 0 && lastEnd != off) jumps++;
        lastEnd = off + n;
    } else if (flags & SQLITE_OPEN_WAL) walReads++;
    else otherReads++;
    return real(f)->pMethods->xRead(real(f), b, n, off);
}
static int fWrite(sqlite3_file *f, const void *b, int n, sqlite3_int64 off) {
    writes++; writtenBytes += (uint64_t)n;
    if (failWrite && --failWrite == 0) return SQLITE_FULL;
    int rc = real(f)->pMethods->xWrite(real(f), b, n, off);
    if (rc == SQLITE_OK) {
        uint64_t end = (uint64_t)off + (uint64_t)n;
        if (((File *)f)->flags & SQLITE_OPEN_WAL) { if (end > walHighWater) walHighWater = end; }
        if (((File *)f)->flags & SQLITE_OPEN_MAIN_JOURNAL) { if (end > journalHighWater) journalHighWater = end; }
    }
    if (writeCut && --writeCut == 0) stop_for_kill("vfs-write");
    return rc;
}
static int fTruncate(sqlite3_file *f, sqlite3_int64 n) { return real(f)->pMethods->xTruncate(real(f), n); }
static int fSync(sqlite3_file *f, int flags) {
    if (failSync && --failSync == 0) { syncs++; return SQLITE_IOERR_FSYNC; }
    int rc = real(f)->pMethods->xSync(real(f), flags); syncs++;
    if (syncCut && --syncCut == 0) stop_for_kill("vfs-sync");
    return rc;
}
static int fSize(sqlite3_file *f, sqlite3_int64 *n) { return real(f)->pMethods->xFileSize(real(f), n); }
static int fLock(sqlite3_file *f, int n) { return real(f)->pMethods->xLock(real(f), n); }
static int fUnlock(sqlite3_file *f, int n) { return real(f)->pMethods->xUnlock(real(f), n); }
static int fReserved(sqlite3_file *f, int *n) { return real(f)->pMethods->xCheckReservedLock(real(f), n); }
static int fControl(sqlite3_file *f, int op, void *p) { return real(f)->pMethods->xFileControl(real(f), op, p); }
static int fSector(sqlite3_file *f) { return real(f)->pMethods->xSectorSize(real(f)); }
static int fDevice(sqlite3_file *f) { return real(f)->pMethods->xDeviceCharacteristics(real(f)); }
static int fMap(sqlite3_file *f, int pg, int size, int extend, void volatile **out) {
    return real(f)->pMethods->xShmMap(real(f), pg, size, extend, out);
}
static int fShmLock(sqlite3_file *f, int off, int n, int flags) { return real(f)->pMethods->xShmLock(real(f), off, n, flags); }
static void fBarrier(sqlite3_file *f) { real(f)->pMethods->xShmBarrier(real(f)); }
static int fUnmap(sqlite3_file *f, int del) { return real(f)->pMethods->xShmUnmap(real(f), del); }
static const sqlite3_io_methods methods = {
    .iVersion = 2, .xClose = fClose, .xRead = fRead, .xWrite = fWrite,
    .xTruncate = fTruncate, .xSync = fSync, .xFileSize = fSize,
    .xLock = fLock, .xUnlock = fUnlock, .xCheckReservedLock = fReserved,
    .xFileControl = fControl, .xSectorSize = fSector, .xDeviceCharacteristics = fDevice,
    .xShmMap = fMap, .xShmLock = fShmLock, .xShmBarrier = fBarrier, .xShmUnmap = fUnmap
};
static int vOpen(sqlite3_vfs *v, const char *name, sqlite3_file *out, int flags, int *resultFlags) {
    (void)v;
    File *f = (File *)out;
    memset(f, 0, sizeof(*f));
    f->real = (sqlite3_file *)((unsigned char *)out + sizeof(*f)); f->flags = flags;
    int rc = underlying->xOpen(underlying, name, f->real, flags, resultFlags);
    if (rc == SQLITE_OK) f->base.pMethods = &methods;
    return rc;
}
static void setup_vfs(void) {
    underlying = sqlite3_vfs_find(NULL); assert(underlying);
    counting = *underlying; counting.pNext = NULL; counting.zName = "nv-local-probe";
    counting.szOsFile += (int)sizeof(File); counting.xOpen = vOpen;
    assert(sqlite3_vfs_register(&counting, 0) == SQLITE_OK);
}
static void check(sqlite3 *db, int rc) {
    if (rc != SQLITE_OK) { fprintf(stderr, "SQLite %d: %s\n", rc, sqlite3_errmsg(db)); exit(1); }
}
static void sql(sqlite3 *db, const char *s) { check(db, sqlite3_exec(db, s, NULL, NULL, NULL)); }
static sqlite3_stmt *prepare(sqlite3 *db, const char *s) {
    sqlite3_stmt *q = NULL; check(db, sqlite3_prepare_v2(db, s, -1, &q, NULL)); return q;
}
static void done(sqlite3 *db, sqlite3_stmt *q) {
    int rc = sqlite3_step(q); if (rc != SQLITE_DONE) check(db, rc);
    check(db, sqlite3_reset(q)); check(db, sqlite3_clear_bindings(q));
}
static int64_t scalar(sqlite3 *db, const char *s) {
    sqlite3_stmt *q = prepare(db, s); assert(sqlite3_step(q) == SQLITE_ROW);
    int64_t result = sqlite3_column_int64(q, 0); assert(sqlite3_step(q) == SQLITE_DONE);
    check(db, sqlite3_finalize(q)); return result;
}
static double now(void) {
    struct timespec t; assert(clock_gettime(CLOCK_MONOTONIC, &t) == 0);
    return t.tv_sec + t.tv_nsec / 1e9;
}
/* Public synthetic fixture keys ONLY; never use this helper with user data.
 * sqlite3_key's raw-key input is the x'hex' syntax, not arbitrary 32 bytes. */
static void key_db(sqlite3 *db) {
#ifdef NV_SQLCIPHER_PROBE
    const char *mode = getenv("NV_PROBE_KEY_MODE");
    if (mode && strcmp(mode, "none")) {
        const char *key = !strcmp(mode, "raw") ?
            "x'000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'" :
            "SQLCipher public benchmark password";
        assert(!strcmp(mode, "raw") || !strcmp(mode, "pass"));
        check(db, sqlite3_key(db, key, (int)strlen(key)));
        const char *page = getenv("NV_PROBE_CIPHER_PAGE_SIZE");
        assert(!page || !strcmp(page,"4096") || !strcmp(page,"16384"));
        sql(db, page && !strcmp(page,"16384") ? "PRAGMA cipher_page_size=16384" : "PRAGMA cipher_page_size=4096");
    }
#else
    (void)db;
#endif
}
static sqlite3 *open_db(const char *path, int create) {
    sqlite3 *db = NULL;
    int flags = SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0);
    check(db, sqlite3_open_v2(path, &db, flags, counting.zName));
    key_db(db);
    sql(db, "PRAGMA mmap_size=0; PRAGMA cache_size=-4096; PRAGMA temp_store=MEMORY;"
            "PRAGMA foreign_keys=ON; PRAGMA synchronous=EXTRA; PRAGMA fullfsync=ON;");
    return db;
}
static void schema(sqlite3 *db, const char *mode) {
    assert(!strcmp(mode, "WAL") || !strcmp(mode, "DELETE"));
    sql(db, "PRAGMA page_size=4096; PRAGMA auto_vacuum=NONE;");
    sql(db, !strcmp(mode, "WAL") ? "PRAGMA journal_mode=WAL;" : "PRAGMA journal_mode=DELETE;");
    sql(db, "CREATE TABLE objects(row INTEGER PRIMARY KEY, oid BLOB NOT NULL UNIQUE, envelope BLOB NOT NULL);"
            "CREATE TABLE applications(seq INTEGER PRIMARY KEY, object_row INTEGER NOT NULL UNIQUE REFERENCES objects(row));"
            "CREATE TABLE current(note INTEGER PRIMARY KEY, object_row INTEGER NOT NULL REFERENCES objects(row), body BLOB NOT NULL);"
            "CREATE TABLE edges(child INTEGER NOT NULL, relation INTEGER NOT NULL, parent INTEGER NOT NULL, PRIMARY KEY(child,relation,parent)) WITHOUT ROWID;"
            "CREATE TABLE cache(id INTEGER PRIMARY KEY CHECK(id=1), through INTEGER NOT NULL, body BLOB NOT NULL);"
            "CREATE TABLE private_state(id INTEGER PRIMARY KEY CHECK(id=1), accepted_through INTEGER NOT NULL);"
            "CREATE TRIGGER immutable_update BEFORE UPDATE ON objects BEGIN SELECT RAISE(ABORT,'immutable'); END;"
            "CREATE TRIGGER immutable_delete BEFORE DELETE ON objects BEGIN SELECT RAISE(ABORT,'immutable'); END;");
}
static void identity(uint64_t id, unsigned char out[32]) {
    /* Random-looking deterministic keys, NOT cryptographic hashes. */
    uint64_t x = id;
    for (int k = 0; k < 4; k++) {
        x += UINT64_C(0x9e3779b97f4a7c15);
        uint64_t z = x; z = (z ^ (z >> 30)) * UINT64_C(0xbf58476d1ce4e5b9);
        z = (z ^ (z >> 27)) * UINT64_C(0x94d049bb133111eb); z ^= z >> 31;
        memcpy(out + 8*k, &z, 8);
    }
}
static void payload(uint64_t id, unsigned char *out, size_t n) {
    unsigned char key[32]; identity(id, key);
    for (size_t k = 0; k < n; k++) out[k] = key[k % 32];
    uint64_t note = id % NOTES; memcpy(out, &id, 8); memcpy(out + 8, &note, 8);
}
static uint64_t touch(const void *p, int n) {
    const unsigned char *b = p; uint64_t h = UINT64_C(1469598103934665603);
    for (int i = 0; i < n; i++) h = (h ^ b[i]) * UINT64_C(1099511628211);
    return h;
}
static void insert_object(sqlite3 *db, sqlite3_stmt *q, uint64_t id) {
    unsigned char oid[32], bytes[PAYLOAD]; identity(id, oid); payload(id, bytes, sizeof(bytes));
    check(db, sqlite3_bind_int64(q, 1, (sqlite3_int64)id));
    check(db, sqlite3_bind_blob(q, 2, oid, 32, SQLITE_TRANSIENT));
    check(db, sqlite3_bind_blob(q, 3, bytes, sizeof(bytes), SQLITE_TRANSIENT)); done(db, q);
}
static void apply(sqlite3 *db, sqlite3_stmt *a, sqlite3_stmt *c, int64_t seq, uint64_t id) {
    unsigned char bytes[BODY]; payload(id, bytes, sizeof(bytes));
    check(db, sqlite3_bind_int64(a, 1, seq)); check(db, sqlite3_bind_int64(a, 2, (sqlite3_int64)id)); done(db, a);
    check(db, sqlite3_bind_int(c, 1, (int)(id % NOTES)));
    check(db, sqlite3_bind_int64(c, 2, (sqlite3_int64)id));
    check(db, sqlite3_bind_blob(c, 3, bytes, BODY, SQLITE_TRANSIENT)); done(db, c);
}
static void snapshot(sqlite3 *db, int64_t through) {
    CachedNote *rows = calloc(NOTES, sizeof(*rows)); assert(rows);
    sqlite3_stmt *q = prepare(db, "SELECT note,object_row,body FROM current ORDER BY note");
    int count = 0, rc;
    while ((rc = sqlite3_step(q)) == SQLITE_ROW) {
        int note = sqlite3_column_int(q, 0); assert(note >= 0 && note < NOTES);
        rows[note].note = (uint64_t)note; rows[note].object = (uint64_t)sqlite3_column_int64(q, 1);
        assert(sqlite3_column_bytes(q, 2) == BODY); memcpy(rows[note].body, sqlite3_column_blob(q, 2), BODY); count++;
    }
    assert(rc == SQLITE_DONE && count == NOTES); check(db, sqlite3_finalize(q));
    q = prepare(db, "INSERT OR REPLACE INTO cache VALUES(1,?,?)");
    check(db, sqlite3_bind_int64(q, 1, through));
    check(db, sqlite3_bind_blob(q, 2, rows, NOTES*sizeof(*rows), SQLITE_TRANSIENT)); done(db, q);
    check(db, sqlite3_finalize(q)); free(rows);
}
static void seed(const char *path, int64_t n) {
    assert(n >= 2*NOTES); sqlite3 *db = open_db(path, 1); schema(db, "WAL");
    sqlite3_stmt *o = prepare(db, "INSERT INTO objects VALUES(?,?,?)");
    sqlite3_stmt *a = prepare(db, "INSERT INTO applications VALUES(?,?)");
    sqlite3_stmt *c = prepare(db, "INSERT OR REPLACE INTO current VALUES(?,?,?)");
    sqlite3_stmt *e = prepare(db, "INSERT INTO edges VALUES(?,0,?)");
    int64_t seq = 0; double start = now(); sql(db, "BEGIN IMMEDIATE");
    for (int64_t i = 1; i <= n; i++) {
        insert_object(db, o, (uint64_t)i);
        if (i != 7) {
            apply(db, a, c, ++seq, (uint64_t)i);
            if (i > 1) {
                check(db, sqlite3_bind_int64(e, 1, i)); check(db, sqlite3_bind_int64(e, 2, i == 8 ? 6 : i-1)); done(db, e);
            }
        }
        if (i % 2048 == 0) sql(db, "COMMIT; BEGIN IMMEDIATE");
    }
    snapshot(db, seq); sql(db, "INSERT INTO private_state SELECT 1,max(seq) FROM applications; COMMIT");
    sql(db, "BEGIN IMMEDIATE");
    for (int64_t i = n+1; i < n+TAIL; i++) {
        insert_object(db, o, (uint64_t)i); apply(db, a, c, ++seq, (uint64_t)i);
        check(db, sqlite3_bind_int64(e, 1, i)); check(db, sqlite3_bind_int64(e, 2, i-1)); done(db, e);
    }
    /* Previously stored object 7 becomes applicable only after new evidence arrives.
     * It must be in the application tail despite its OLD object row number. */
    apply(db, a, c, ++seq, 7);
    check(db, sqlite3_bind_int64(e, 1, 7)); check(db, sqlite3_bind_int64(e, 2, n+1)); done(db, e);
    sql(db, "UPDATE private_state SET accepted_through=(SELECT max(seq) FROM applications); COMMIT;");
    check(db, sqlite3_finalize(o)); check(db, sqlite3_finalize(a)); check(db, sqlite3_finalize(c)); check(db, sqlite3_finalize(e));
    sql(db, "PRAGMA wal_checkpoint(TRUNCATE)");
    int64_t pages = scalar(db, "PRAGMA page_count"), size = scalar(db, "PRAGMA page_size");
    check(db, sqlite3_close(db));
    printf("{\"kind\":\"seed\",\"history\":%" PRId64 ",\"db_bytes\":%" PRId64 ",\"seconds\":%.3f}\n", n, pages*size, now()-start);
}
static void expected(uint64_t state[NOTES], int64_t n) {
    memset(state, 0, NOTES*sizeof(*state));
    for (int64_t i = 1; i < n+TAIL; i++) if (i != 7) state[i % NOTES] = (uint64_t)i;
    state[7] = 7;
}
static void probe(const char *path, int64_t n, const char *kind) {
    double start = now(); sqlite3 *db = open_db(path, 0);
    uint64_t state[NOTES] = {0}, want[NOTES], digest = 0, rows = 0, outputBytes = 0;
    int64_t through = 0, fullscan = 0, steps = 0; sqlite3_stmt *q = NULL;
    sql(db, "BEGIN");
    if (!strcmp(kind, "startup")) {
        q = prepare(db, "SELECT through,body FROM cache WHERE id=1"); assert(sqlite3_step(q) == SQLITE_ROW);
        through = sqlite3_column_int64(q, 0); int bytes = sqlite3_column_bytes(q, 1);
        assert(bytes == NOTES*(int)sizeof(CachedNote));
        CachedNote *copy = malloc((size_t)bytes); assert(copy); memcpy(copy, sqlite3_column_blob(q, 1), (size_t)bytes);
        for (int i = 0; i < NOTES; i++) {
            assert(copy[i].note == (uint64_t)i); uint64_t bodyID; memcpy(&bodyID, copy[i].body, 8);
            assert(bodyID == copy[i].object); state[i] = copy[i].object;
        }
        digest ^= touch(copy, bytes); outputBytes += (uint64_t)bytes; free(copy);
        assert(sqlite3_step(q) == SQLITE_DONE); steps += sqlite3_stmt_status(q, SQLITE_STMTSTATUS_VM_STEP, 0);
        check(db, sqlite3_finalize(q));
        q = prepare(db, "SELECT a.seq,o.row,o.envelope FROM applications a JOIN objects o ON o.row=a.object_row WHERE a.seq>? ORDER BY a.seq");
        check(db, sqlite3_bind_int64(q, 1, through));
    } else if (!strcmp(kind, "replay")) {
        q = prepare(db, "SELECT a.seq,o.row,o.envelope FROM applications a JOIN objects o ON o.row=a.object_row ORDER BY a.seq");
    } else if (!strcmp(kind, "current")) {
        q = prepare(db, "SELECT note,object_row,body FROM current ORDER BY note");
    } else if (!strcmp(kind, "catalog")) {
        q = prepare(db, "SELECT oid FROM objects ORDER BY oid");
    } else if (!strcmp(kind, "point")) {
        q = prepare(db, "SELECT envelope FROM objects WHERE oid=?");
    } else if (!strcmp(kind, "lineage")) {
        q = prepare(db, "SELECT parent FROM edges WHERE child=? AND relation=0");
    } else { fprintf(stderr, "unknown probe\n"); exit(2); }
    int rc;
    if (!strcmp(kind, "point") || !strcmp(kind, "lineage")) {
        uint64_t child = (uint64_t)(n + TAIL - 1);
        for (int i = 0; i < 64; i++) {
            unsigned char id[32];
            uint64_t number = 1 + ((uint64_t)i*7919 % (uint64_t)(n+TAIL-1));
            if (!strcmp(kind, "point")) {
                identity(number, id);
                check(db, sqlite3_bind_blob(q, 1, id, 32, SQLITE_TRANSIENT));
            } else check(db, sqlite3_bind_int64(q, 1, (sqlite3_int64)child));
            assert(sqlite3_step(q) == SQLITE_ROW);
            if (!strcmp(kind, "point")) {
                int bytes = sqlite3_column_bytes(q, 0); assert(bytes == PAYLOAD);
                const void *body = sqlite3_column_blob(q, 0); uint64_t bodyID;
                memcpy(&bodyID, body, 8); assert(bodyID == number);
                digest ^= touch(body, bytes); outputBytes += (uint64_t)bytes;
            } else {
                uint64_t parent = (uint64_t)sqlite3_column_int64(q, 0);
                assert(parent == child-1); child = parent; digest ^= child;
            }
            rows++; assert(sqlite3_step(q) == SQLITE_DONE); check(db, sqlite3_reset(q));
        }
    } else {
        while ((rc = sqlite3_step(q)) == SQLITE_ROW) {
            int col = !strcmp(kind, "catalog") ? 0 : 2;
            int bytes = sqlite3_column_bytes(q, col); const void *data = sqlite3_column_blob(q, col);
            digest ^= touch(data, bytes); outputBytes += (uint64_t)bytes; rows++;
            if (col == 2) {
                uint64_t id = (uint64_t)sqlite3_column_int64(q, 1), bodyID;
                assert(bytes >= BODY); memcpy(&bodyID, data, 8); assert(bodyID == id);
                state[id % NOTES] = id;
            }
        }
        assert(rc == SQLITE_DONE);
    }
    fullscan += sqlite3_stmt_status(q, SQLITE_STMTSTATUS_FULLSCAN_STEP, 0);
    steps += sqlite3_stmt_status(q, SQLITE_STMTSTATUS_VM_STEP, 0); check(db, sqlite3_finalize(q));
    if (!strcmp(kind, "startup") || !strcmp(kind, "replay") || !strcmp(kind, "current")) {
        expected(want, n); assert(memcmp(state, want, sizeof(state)) == 0);
    }
    if (!strcmp(kind, "startup")) assert(rows == TAIL && through == n-1 && fullscan == 0);
    if (!strcmp(kind, "catalog")) assert(rows == (uint64_t)(n+TAIL-1));
    int miss, high; check(db, sqlite3_db_status(db, SQLITE_DBSTATUS_CACHE_MISS, &miss, &high, 0));
    double elapsed = now()-start;
    printf("{\"kind\":\"%s\",\"history\":%" PRId64 ",\"ms\":%.3f,\"rows\":%" PRIu64
           ",\"output_bytes\":%" PRIu64 ",\"read_calls\":%" PRIu64 ",\"read_bytes\":%" PRIu64
           ",\"db_reads\":%" PRIu64 ",\"wal_reads\":%" PRIu64 ",\"other_reads\":%" PRIu64
           ",\"nonsequential_db_reads\":%" PRIu64 ",\"cache_misses\":%d,\"fullscan_steps\":%" PRId64
           ",\"vm_steps\":%" PRId64 ",\"digest\":\"%016" PRIx64 "\"}\n",
           kind,n,elapsed*1000,rows,outputBytes,reads,readBytes,dbReads,walReads,otherReads,jumps,miss,fullscan,steps,digest);
    sql(db, "COMMIT"); check(db, sqlite3_close(db));
}
static void crash_init(const char *path, const char *mode) {
    sqlite3 *db = open_db(path, 1); schema(db, mode);
    sql(db, "BEGIN; INSERT INTO objects VALUES(1,x'01',zeroblob(4096));"
            "INSERT INTO applications VALUES(1,1); INSERT INTO current VALUES(1,1,x'01');"
            "INSERT INTO cache VALUES(1,1,x'01'); INSERT INTO private_state VALUES(1,1); COMMIT;");
    check(db, sqlite3_close(db));
}
static void crash_write(const char *path, const char *stage) {
    sqlite3 *db = open_db(path, 0); sql(db, "PRAGMA cache_size=8; PRAGMA wal_autocheckpoint=0; BEGIN IMMEDIATE;");
    if (!strcmp(stage,"vfs-write")) writeCut = 3;
    if (!strcmp(stage,"vfs-sync")) syncCut = 1;
    if (!strcmp(stage,"write-full")) failWrite = 1;
    int rc = sqlite3_exec(db,"INSERT INTO objects VALUES(2,x'02',zeroblob(1048576));",NULL,NULL,NULL);
    if (!strcmp(stage,"write-full")) {
        if (rc == SQLITE_OK) rc = sqlite3_exec(db,"COMMIT",NULL,NULL,NULL);
        if (rc != SQLITE_FULL) fprintf(stderr,"injected write result=%d remaining=%d message=%s\n",rc,failWrite,sqlite3_errmsg(db));
        assert(rc == SQLITE_FULL && failWrite == 0);
        if (!sqlite3_get_autocommit(db)) sql(db,"ROLLBACK");
        check(db,sqlite3_close(db)); puts("{\"kind\":\"write-full\",\"sqlite_full\":true}"); return;
    }
    check(db,rc);
    if (!strcmp(stage,"object-only")) { sql(db,"COMMIT"); stop_for_kill(stage); }
    if (!strcmp(stage,"after-object")) stop_for_kill(stage);
    sql(db,"INSERT INTO applications VALUES(2,2); UPDATE current SET object_row=2,body=x'02'; UPDATE private_state SET accepted_through=2;");
    if (!strcmp(stage,"after-apply")) stop_for_kill(stage);
    if (!strcmp(stage,"cache-separate")) sql(db,"COMMIT; BEGIN IMMEDIATE;");
    sql(db,"UPDATE cache SET through=2,body=x'02';");
    if (!strcmp(stage,"before-commit") || !strcmp(stage,"cache-separate")) stop_for_kill(stage);
    sql(db,"COMMIT"); stop_for_kill("after-commit");
}
static void crash_verify(const char *path) {
    sqlite3 *db = open_db(path,0);
    int64_t objects=scalar(db,"SELECT count(*) FROM objects"), applied=scalar(db,"SELECT count(*) FROM applications"),
        current=scalar(db,"SELECT object_row FROM current WHERE note=1"), pin=scalar(db,"SELECT accepted_through FROM private_state"),
        cache=scalar(db,"SELECT through FROM cache");
    sqlite3_stmt *q=prepare(db,"SELECT through,body FROM cache"); assert(sqlite3_step(q)==SQLITE_ROW);
    assert(sqlite3_column_bytes(q,1)==1); assert(*(const unsigned char*)sqlite3_column_blob(q,1)==sqlite3_column_int(q,0)); sqlite3_finalize(q);
    q=prepare(db,"PRAGMA integrity_check"); assert(sqlite3_step(q)==SQLITE_ROW); assert(!strcmp((const char*)sqlite3_column_text(q,0),"ok")); sqlite3_finalize(q);
    assert(scalar(db,"SELECT count(*) FROM pragma_foreign_key_check")==0);
    assert(applied==current && current==pin && cache<=current && objects>=applied);
    int rc=sqlite3_exec(db,"UPDATE objects SET envelope=x'ff' WHERE row=1",NULL,NULL,NULL); assert(rc==SQLITE_CONSTRAINT);
    /* Recover from cache plus actual application suffix, including the split-cache case. */
    int64_t recovered=cache;
    q=prepare(db,"SELECT object_row FROM applications WHERE seq>? ORDER BY seq"); sqlite3_bind_int64(q,1,cache);
    while ((rc=sqlite3_step(q))==SQLITE_ROW) recovered=sqlite3_column_int64(q,0);
    assert(rc==SQLITE_DONE && recovered==current); sqlite3_finalize(q);
    printf("{\"kind\":\"crash-verify\",\"objects\":%" PRId64 ",\"applied\":%" PRId64 ",\"current\":%" PRId64 ",\"pin\":%" PRId64 ",\"cache\":%" PRId64 ",\"recovered\":%" PRId64 "}\n",objects,applied,current,pin,cache,recovered);
    check(db,sqlite3_close(db));
}
int main(int argc, char **argv) {
    setup_vfs();
    if (argc==2 && !strcmp(argv[1],"version")) {
        printf("{\"sqlite\":\"%s\",\"source_id\":\"%s\"}\n",sqlite3_libversion(),sqlite3_sourceid()); return 0;
    }
    if (argc==4 && !strcmp(argv[1],"seed")) seed(argv[2],atoll(argv[3]));
    else if (argc==5 && !strcmp(argv[1],"probe")) probe(argv[2],atoll(argv[3]),argv[4]);
    else if (argc==4 && !strcmp(argv[1],"crash-init")) crash_init(argv[2],argv[3]);
    else if (argc==4 && !strcmp(argv[1],"crash-write")) crash_write(argv[2],argv[3]);
    else if (argc==3 && !strcmp(argv[1],"crash-verify")) crash_verify(argv[2]);
    else { fprintf(stderr,"usage: seed DB N | probe DB N KIND | crash-init DB MODE | crash-write DB STAGE | crash-verify DB | version\n"); return 2; }
    return 0;
}
