#include "NVStorageFaults.h"
#include <sqlite3.h>
#include <stdatomic.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/xattr.h>

int nv_fixture_set_attribute(const char *path, const char *name, const uint8_t *bytes, uint64_t count) {
#if defined(__APPLE__)
    return setxattr(path, name, bytes, (size_t)count, 0, XATTR_NOFOLLOW);
#else
    return lsetxattr(path, name, bytes, (size_t)count, 0);
#endif
}
int64_t nv_fixture_get_attribute(const char *path, const char *name, uint8_t *bytes, uint64_t count) {
#if defined(__APPLE__)
    return getxattr(path, name, bytes, (size_t)count, 0, XATTR_NOFOLLOW);
#else
    return lgetxattr(path, name, bytes, (size_t)count);
#endif
}

static sqlite3_vfs *base;
static sqlite3_vfs wrapper;
static _Atomic int armed, ordinal, resultCode, hits;
static _Atomic int rejectionEvent, rejectionOrdinal, rejectionResult;
static _Atomic int acceptanceEvent, acceptanceOrdinal, acceptanceResult;
static _Atomic int parkingEvent, parkingOrdinal, parkingResult;
static _Atomic int damageEvent, damageOrdinal, damageResult;
static _Atomic int verificationEvent, verificationOrdinal, verificationResult;
static _Atomic int materializationEvent, materializationOrdinal, materializationResult;
static _Atomic int settlementEvent, settlementOrdinal, settlementResult;
static _Atomic int repairEvent, repairOrdinal, repairResult;
static _Atomic int associationEvent, associationOrdinal, associationResult;
static _Atomic int64_t steps;
static pthread_mutex_t holdMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t holdCondition = PTHREAD_COND_INITIALIZER;
static int held, released;
typedef struct { sqlite3_file file; sqlite3_file *real; } File;

static int hit(int event) {
    if (atomic_load(&armed) != event) return SQLITE_OK;
    if (atomic_fetch_add(&hits, 1) + 1 != atomic_load(&ordinal)) return SQLITE_OK;
    atomic_store(&armed, 0);
    int code = atomic_load(&resultCode);
    if (code == -2) {
        pthread_mutex_lock(&holdMutex);
        held = 1; pthread_cond_broadcast(&holdCondition);
        while (!released) pthread_cond_wait(&holdCondition, &holdMutex);
        pthread_mutex_unlock(&holdMutex);
        return SQLITE_OK;
    }
    if (code < 0) _exit(86);
    return code;
}
void nv_faults_arm(int event, int n, int code) {
    atomic_store(&armed, 0); atomic_store(&hits, 0);
    atomic_store(&ordinal, n); atomic_store(&resultCode, code); atomic_store(&armed, event);
}
void nv_faults_arm_on_rejection(int event, int n, int code) {
    nv_faults_arm(0, 0, 0);
    atomic_store(&rejectionOrdinal, n); atomic_store(&rejectionResult, code);
    atomic_store(&rejectionEvent, event);
}
void nv_faults_arm_on_association(int event, int n, int code) {
    nv_faults_arm(0, 0, 0);
    atomic_store(&associationOrdinal, n); atomic_store(&associationResult, code);
    atomic_store(&associationEvent, event);
}
void nv_faults_arm_on_history_acceptance(int event, int n, int code) {
    nv_faults_arm(0, 0, 0);
    atomic_store(&acceptanceOrdinal, n); atomic_store(&acceptanceResult, code);
    atomic_store(&acceptanceEvent, event);
}
void nv_faults_arm_on_parking(int event, int n, int code) {
    nv_faults_arm(0, 0, 0);
    atomic_store(&parkingOrdinal, n); atomic_store(&parkingResult, code);
    atomic_store(&parkingEvent, event);
}
void nv_faults_arm_on_damage(int event, int n, int code) {
    nv_faults_arm(0, 0, 0);
    atomic_store(&damageOrdinal, n); atomic_store(&damageResult, code);
    atomic_store(&damageEvent, event);
}
void nv_faults_arm_on_verification_settlement(int event, int n, int code) {
    nv_faults_arm(0, 0, 0);
    atomic_store(&verificationOrdinal, n); atomic_store(&verificationResult, code);
    atomic_store(&verificationEvent, event);
}
void nv_faults_arm_on_materialization(int event, int n, int code) {
    nv_faults_arm(0, 0, 0);
    atomic_store(&materializationOrdinal, n); atomic_store(&materializationResult, code);
    atomic_store(&materializationEvent, event);
}
void nv_faults_arm_on_pending_settlement(int event, int n, int code) {
    nv_faults_arm(0, 0, 0);
    atomic_store(&settlementOrdinal, n); atomic_store(&settlementResult, code);
    atomic_store(&settlementEvent, event);
}
void nv_faults_arm_on_repair_private_installation(int event, int n, int code) {
    nv_faults_arm(0, 0, 0);
    atomic_store(&repairOrdinal, n); atomic_store(&repairResult, code);
    atomic_store(&repairEvent, event);
}
static int containsFolded(const char *text, const char *needle) {
    int count = (int)strlen(needle);
    for (const char *p = text; *p; p++) if (!sqlite3_strnicmp(p, needle, count)) return 1;
    return 0;
}
int nv_faults_hits(void) { return atomic_load(&hits); }
int64_t nv_faults_steps(void) { return atomic_load(&steps); }
void nv_faults_reset_steps(void) { atomic_store(&steps, 0); }
void nv_faults_hold(int event, int n) {
    pthread_mutex_lock(&holdMutex); held = 0; released = 0; pthread_mutex_unlock(&holdMutex);
    nv_faults_arm(event, n, -2);
}
void nv_faults_wait_until_held(void) {
    pthread_mutex_lock(&holdMutex);
    while (!held) pthread_cond_wait(&holdCondition, &holdMutex);
    pthread_mutex_unlock(&holdMutex);
}
void nv_faults_release(void) {
    pthread_mutex_lock(&holdMutex); released = 1;
    pthread_cond_broadcast(&holdCondition); pthread_mutex_unlock(&holdMutex);
}

static int closeFile(sqlite3_file *p) {
    File *f = (File *)p; int rc = f->real->pMethods->xClose(f->real);
    sqlite3_free(f->real); f->real = NULL; return rc;
}
static int readFile(sqlite3_file *p, void *b, int n, sqlite3_int64 offset) {
    File *f = (File *)p; return f->real->pMethods->xRead(f->real, b, n, offset);
}
static int writeFile(sqlite3_file *p, const void *b, int n, sqlite3_int64 offset) {
    int fault = hit(NV_FAULT_WRITE); if (fault) return fault;
    File *f = (File *)p; return f->real->pMethods->xWrite(f->real, b, n, offset);
}
static int truncateFile(sqlite3_file *p, sqlite3_int64 size) {
    File *f = (File *)p; return f->real->pMethods->xTruncate(f->real, size);
}
static int syncFile(sqlite3_file *p, int flags) {
    int fault = hit(NV_FAULT_SYNC); if (fault) return fault;
    File *f = (File *)p; int result = f->real->pMethods->xSync(f->real, flags);
    return result ? result : hit(NV_FAULT_SYNC_AFTER);
}
static int sizeFile(sqlite3_file *p, sqlite3_int64 *size) {
    File *f = (File *)p; return f->real->pMethods->xFileSize(f->real, size);
}
static int lockFile(sqlite3_file *p, int lock) {
    File *f = (File *)p; return f->real->pMethods->xLock(f->real, lock);
}
static int unlockFile(sqlite3_file *p, int lock) {
    File *f = (File *)p; return f->real->pMethods->xUnlock(f->real, lock);
}
static int reservedFile(sqlite3_file *p, int *out) {
    File *f = (File *)p; return f->real->pMethods->xCheckReservedLock(f->real, out);
}
static int controlFile(sqlite3_file *p, int op, void *arg) {
    File *f = (File *)p; return f->real->pMethods->xFileControl(f->real, op, arg);
}
static int sectorFile(sqlite3_file *p) { File *f = (File *)p; return f->real->pMethods->xSectorSize(f->real); }
static int deviceFile(sqlite3_file *p) { File *f = (File *)p; return f->real->pMethods->xDeviceCharacteristics(f->real); }
static int shmMapFile(sqlite3_file *p, int page, int size, int extend, void volatile **out) {
    File *f = (File *)p; return f->real->pMethods->xShmMap(f->real, page, size, extend, out);
}
static int shmLockFile(sqlite3_file *p, int offset, int n, int flags) {
    if (offset == 0 && (flags & SQLITE_SHM_LOCK) && (flags & SQLITE_SHM_EXCLUSIVE)) {
        int fault = hit(NV_FAULT_LOCK); if (fault) return fault;
    }
    File *f = (File *)p; return f->real->pMethods->xShmLock(f->real, offset, n, flags);
}
static void shmBarrierFile(sqlite3_file *p) { File *f = (File *)p; f->real->pMethods->xShmBarrier(f->real); }
static int shmUnmapFile(sqlite3_file *p, int remove) { File *f = (File *)p; return f->real->pMethods->xShmUnmap(f->real, remove); }
static int fetchFile(sqlite3_file *p, sqlite3_int64 offset, int size, void **out) {
    (void)p; (void)offset; (void)size; *out = NULL; return SQLITE_OK;
}
static int unfetchFile(sqlite3_file *p, sqlite3_int64 offset, void *ptr) {
    (void)p; (void)offset; (void)ptr; return SQLITE_OK;
}
static const sqlite3_io_methods methods = {3, closeFile, readFile, writeFile, truncateFile,
    syncFile, sizeFile, lockFile, unlockFile, reservedFile, controlFile, sectorFile, deviceFile,
    shmMapFile, shmLockFile, shmBarrierFile, shmUnmapFile, fetchFile, unfetchFile};
static int openFile(sqlite3_vfs *v, const char *name, sqlite3_file *out, int flags, int *outFlags) {
    (void)v; File *f = (File *)out;
    memset(f, 0, sizeof(*f)); f->real = sqlite3_malloc64((sqlite3_uint64)base->szOsFile);
    if (!f->real) return SQLITE_NOMEM;
    memset(f->real, 0, (size_t)base->szOsFile);
    int rc = base->xOpen(base, name, f->real, flags, outFlags);
    if (rc) { sqlite3_free(f->real); f->real = NULL; return rc; }
    if (f->real->pMethods->iVersion < 2) { f->real->pMethods->xClose(f->real); sqlite3_free(f->real); f->real = NULL; return SQLITE_ERROR; }
    f->file.pMethods = &methods; return SQLITE_OK;
}
static int trace(unsigned event, void *context, void *statement, void *extra) {
    (void)context; (void)extra;
    const char *sql = sqlite3_sql(statement);
    if (!sql) return 0;
    if (event == SQLITE_TRACE_STMT) {
        if (!strncmp(sql, "INSERT INTO pending_settlements", sizeof("INSERT INTO pending_settlements") - 1)) {
            int next = atomic_exchange(&settlementEvent, 0);
            if (next) nv_faults_arm(next, atomic_load(&settlementOrdinal), atomic_load(&settlementResult));
        }
        if (!strncmp(sql, "INSERT INTO current_notes", sizeof("INSERT INTO current_notes") - 1) ||
            !strncmp(sql, "UPDATE view_meta SET", sizeof("UPDATE view_meta SET") - 1)) {
            int next = atomic_exchange(&materializationEvent, 0);
            if (next) nv_faults_arm(next, atomic_load(&materializationOrdinal), atomic_load(&materializationResult));
        }
        if (!strncmp(sql, "INSERT INTO private_groups", 26) || !strncmp(sql, "DELETE FROM private_groups", 26)) {
            char *expanded = sqlite3_expanded_sql(statement);
            if (expanded) {
                if (!strncmp(sql, "INSERT", 6) && containsFolded(expanded, "6173736f63696174696f6e")) {
                    int next = atomic_exchange(&associationEvent, 0);
                    if (next) nv_faults_arm(next, atomic_load(&associationOrdinal), atomic_load(&associationResult));
                }
                if (!strncmp(sql, "INSERT", 6) && containsFolded(expanded, "7265706169722d736f757263652f")) {
                    int next = atomic_exchange(&repairEvent, 0);
                    if (next) nv_faults_arm(next, atomic_load(&repairOrdinal), atomic_load(&repairResult));
                }
                if (containsFolded(expanded, "686973746f72792d64616d616765")) {
                    int next = atomic_exchange(&damageEvent, 0);
                    if (next) nv_faults_arm(next, atomic_load(&damageOrdinal), atomic_load(&damageResult));
                }
                if (!strncmp(sql, "DELETE", 6) && containsFolded(expanded, "766572696669636174696f6e2f")) {
                    int next = atomic_exchange(&verificationEvent, 0);
                    if (next) nv_faults_arm(next, atomic_load(&verificationOrdinal), atomic_load(&verificationResult));
                }
                sqlite3_free(expanded);
            }
        }
        if (!strncmp(sql, "INSERT INTO accepted_objects", sizeof("INSERT INTO accepted_objects") - 1)) {
            int next = atomic_exchange(&acceptanceEvent, 0);
            if (next) nv_faults_arm(next, atomic_load(&acceptanceOrdinal), atomic_load(&acceptanceResult));
        }
        if (!strncmp(sql, "INSERT INTO rejected_objects", 28)) {
            int next = atomic_exchange(&rejectionEvent, 0);
            if (next) nv_faults_arm(next, atomic_load(&rejectionOrdinal), atomic_load(&rejectionResult));
            (void)hit(NV_FAULT_REJECTION_BEGIN);
        }
        if (!strncmp(sql, "INSERT INTO object_waits", sizeof("INSERT INTO object_waits") - 1)) {
            int next = atomic_exchange(&parkingEvent, 0);
            if (next) nv_faults_arm(next, atomic_load(&parkingOrdinal), atomic_load(&parkingResult));
            (void)hit(NV_FAULT_PARK_BEGIN);
        }
        if (!strncmp(sql, "DELETE FROM ready_objects", 25)) (void)hit(NV_FAULT_REJECTION_CLEANUP);
        if (!strncmp(sql, "COMMIT", 6)) (void)hit(NV_FAULT_COMMIT_BEGIN);
        if (!strncmp(sql, "UPDATE view_meta SET", 20) ||
            (!strncmp(sql, "INSERT INTO view_meta", 21) && !strstr(sql, "VALUES(1,?,1,0,"))) (void)hit(NV_FAULT_VIEW_UPDATE);
        if (!strncmp(sql, "INSERT INTO current_notes", 25)) (void)hit(NV_FAULT_CURRENT_INSERT);
    } else if (event == SQLITE_TRACE_PROFILE) {
        atomic_fetch_add(&steps, sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 0));
        // Acceptance preflight precedes BEGIN's exclusive writer lock.
        if (atomic_load(&acceptanceEvent) == NV_FAULT_LOCK &&
            !strcmp(sql, "SELECT a.seq,o.encoded FROM accepted_objects a JOIN objects o USING(object_id) WHERE object_id=?")) {
            int next = atomic_exchange(&acceptanceEvent, 0);
            if (next) nv_faults_arm(next, atomic_load(&acceptanceOrdinal), atomic_load(&acceptanceResult));
        }
        if (!strncmp(sql, "COMMIT", 6)) (void)hit(NV_FAULT_COMMIT_END);
    }
    return 0;
}
static int extend(sqlite3 *db, char **message, const sqlite3_api_routines *api) {
    (void)message; (void)api;
    return sqlite3_trace_v2(db, SQLITE_TRACE_STMT | SQLITE_TRACE_PROFILE, trace, NULL);
}
int nv_faults_install(void) {
    if (base) return SQLITE_MISUSE;
    base = sqlite3_vfs_find(NULL); if (!base) return SQLITE_ERROR;
    wrapper = *base; wrapper.zName = "nv-storage-faults"; wrapper.pNext = NULL;
    wrapper.szOsFile = (int)sizeof(File); wrapper.xOpen = openFile;
    int rc = sqlite3_vfs_register(&wrapper, 1);
    if (!rc) rc = sqlite3_auto_extension((void (*)(void))extend);
    return rc;
}
