#include "NVSQLMaintenance.h"
#include "NVStorageFaults.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The instrumented existing VFS observes every buffer passed to an actual write. */
void nv_private_reset(void);
int nv_private_writes(void);
int nv_private_marker_hits(void);
int nv_private_temp_writes(void);

static void run_sql(sqlite3 *db, const char *sql) {
    assert(sqlite3_exec(db, sql, NULL, NULL, NULL) == SQLITE_OK);
}

int main(int argc, char **argv) {
    assert(argc == 4);
    int fixture = atoi(argv[2]), fault = atoi(argv[3]);
    assert(fixture >= 0 && fixture <= 2);
    assert(fault == 0 || fault == SQLITE_IOERR_WRITE || fault == SQLITE_FULL);
    assert(nv_faults_install() == SQLITE_OK);
    sqlite3 *db = NULL;
    assert(sqlite3_open_v2(argv[1], &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, NULL) == SQLITE_OK);
    if (fixture) {
        char key[68];
        memcpy(key, "x'", 2);
        for (int i = 0; i < 32; ++i) { key[2 + 2*i] = '0'; key[3 + 2*i] = (char)('0' + fixture); }
        key[66] = '\''; key[67] = 0;
        assert(sqlite3_key(db, key, 67) == SQLITE_OK);
        memset(key, 0, sizeof(key));
    }
    assert(sqlite3_extended_result_codes(db, 1) == SQLITE_OK);
    run_sql(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA temp_store=MEMORY; PRAGMA mmap_size=0; PRAGMA wal_autocheckpoint=0; PRAGMA fullfsync=ON; PRAGMA checkpoint_fullfsync=ON;");
    run_sql(db, "CREATE TABLE private_payloads(id INTEGER PRIMARY KEY,value BLOB); WITH RECURSIVE x(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM x WHERE n<2000) INSERT INTO private_payloads SELECT n,'NVStoragePrivateWriteMarker-87cb9a934dae' || printf('%08d',n) || zeroblob(1024) FROM x;");
    nv_private_reset();
    if (fault) nv_faults_arm(NV_FAULT_WRITE, 1, fault);
    uint64_t request = 0;
    assert(nv_sql_vacuum_begin(db, &request) == SQLITE_OK);
    int result = nv_sql_vacuum_run(db, request);
    nv_sql_vacuum_finish(request);
    assert(result == fault);
    assert(nv_private_writes() > 0);
    if (fault) assert(nv_faults_hits() == 1);
    assert(nv_private_marker_hits() == 0);
    printf("PASS: keyed fixture=%d fault=%d writes=%d temp_writes=%d\n", fixture, fault, nv_private_writes(), nv_private_temp_writes());
    /* Successful retry reaches the complete physical copy after the failed write. */
    nv_private_reset();
    assert(nv_sql_vacuum_begin(db, &request) == SQLITE_OK);
    assert(nv_sql_vacuum_run(db, request) == SQLITE_OK);
    nv_sql_vacuum_finish(request);
    assert(nv_private_writes() > 0 && nv_private_marker_hits() == 0);
    sqlite3_stmt *rows = NULL;
    assert(sqlite3_prepare_v2(db, "SELECT id,value FROM private_payloads ORDER BY id", -1, &rows, NULL) == SQLITE_OK);
    for (int id=1; id<=2000; ++id) {
        assert(sqlite3_step(rows) == SQLITE_ROW && sqlite3_column_int(rows, 0) == id);
        char expected[64];
        int prefix = snprintf(expected, sizeof(expected), "NVStoragePrivateWriteMarker-87cb9a934dae%08d", id);
        assert(prefix > 0 && prefix < (int)sizeof(expected));
        int count = sqlite3_column_bytes(rows, 1);
        const unsigned char *bytes = sqlite3_column_blob(rows, 1);
        assert(bytes && count == prefix + 1024 && memcmp(bytes,expected,(size_t)prefix) == 0);
        for (int i=prefix; i<count; ++i) assert(bytes[i] == 0);
    }
    assert(sqlite3_step(rows) == SQLITE_DONE);
    assert(sqlite3_finalize(rows) == SQLITE_OK);
    assert(sqlite3_close(db) == SQLITE_OK);
    puts("PASS: exact synthetic private values remain readable after maintenance/retry");
    return 0;
}
