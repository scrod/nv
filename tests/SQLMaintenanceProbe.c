#include "NVSQLMaintenance.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>

/* One owner thread pauses inside actual SQL while the caller signals cancellation. */
static pthread_mutex_t gate_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gate_condition = PTHREAD_COND_INITIALIZER;
static int entered, released, held_once;
static int (*owner_progress)(void *);
static void *owner_context;

static int gated_progress(void *ignored) {
    (void)ignored;
    pthread_mutex_lock(&gate_lock);
    if (!held_once) {
        held_once = 1; entered = 1; pthread_cond_broadcast(&gate_condition);
        while (!released) pthread_cond_wait(&gate_condition, &gate_lock);
    }
    pthread_mutex_unlock(&gate_lock);
    return owner_progress ? owner_progress(owner_context) : 0;
}

/* Interpose only progress-handler installation; execute the production callback. */
void nv_test_progress_handler(sqlite3 *db, int count, int (*callback)(void *), void *context) {
    owner_progress = callback; owner_context = context;
    sqlite3_progress_handler(db, count, count ? gated_progress : NULL, NULL);
}

typedef struct Job { sqlite3 *db; uint64_t token; int vacuum, result; } Job;
static void *run_job(void *arg) {
    Job *job = arg;
    if (job->vacuum) job->result = nv_sql_vacuum_run(job->db, job->token);
    else {
        nv_test_progress_handler(job->db, 256, NULL, NULL);
        job->result = sqlite3_exec(job->db, "INSERT INTO t SELECT value FROM t", NULL, NULL, NULL);
        nv_test_progress_handler(job->db, 0, NULL, NULL);
    }
    return NULL;
}
static pthread_t begin_job(Job *job) {
    pthread_t thread;
    pthread_mutex_lock(&gate_lock); entered = released = held_once = 0; pthread_mutex_unlock(&gate_lock);
    assert(pthread_create(&thread, NULL, run_job, job) == 0);
    pthread_mutex_lock(&gate_lock);
    while (!entered) pthread_cond_wait(&gate_condition, &gate_lock);
    pthread_mutex_unlock(&gate_lock);
    return thread;
}
static void finish_job(pthread_t thread) {
    pthread_mutex_lock(&gate_lock); released = 1; pthread_cond_broadcast(&gate_condition); pthread_mutex_unlock(&gate_lock);
    assert(pthread_join(thread, NULL) == 0);
}
static int row_count(sqlite3 *db) {
    sqlite3_stmt *statement = NULL;
    assert(sqlite3_prepare_v2(db, "SELECT count(*) FROM t", -1, &statement, NULL) == SQLITE_OK);
    assert(sqlite3_step(statement) == SQLITE_ROW);
    int count = sqlite3_column_int(statement, 0);
    assert(sqlite3_finalize(statement) == SQLITE_OK);
    return count;
}
int main(void) {
    sqlite3 *db = NULL, *other = NULL;
    assert(sqlite3_open_v2(":memory:", &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, NULL) == SQLITE_OK);
    assert(sqlite3_exec(db, "CREATE TABLE t(value BLOB); WITH RECURSIVE x(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM x WHERE n<2000) INSERT INTO t SELECT zeroblob(1024) FROM x", NULL, NULL, NULL) == SQLITE_OK);
    uint64_t first = 0, second = 0, running = 0;
    assert(nv_sql_vacuum_begin(db, &first) == SQLITE_OK);
    Job save = {db, first, 0, -1}; pthread_t thread = begin_job(&save);
    nv_sql_vacuum_cancel(first); finish_job(thread);
    assert(save.result == SQLITE_OK); /* pre-start cancellation preserves the admitted save */
    assert(row_count(db) == 4000);
    assert(nv_sql_vacuum_run(db, first) == SQLITE_INTERRUPT);
    nv_sql_vacuum_finish(first);
    assert(nv_sql_vacuum_begin(db, &second) == SQLITE_OK && second != first);
    save.token = second; thread = begin_job(&save);
    nv_sql_vacuum_cancel(first); finish_job(thread);
    assert(save.result == SQLITE_OK && row_count(db) == 8000);
    /* The genuine request also survives a foreign connection's attempted use. */
    assert(sqlite3_open(":memory:", &other) == SQLITE_OK);
    assert(nv_sql_vacuum_run(other, second) == SQLITE_MISUSE);
    assert(sqlite3_close(other) == SQLITE_OK);
    assert(nv_sql_vacuum_run(db, second) == SQLITE_OK);
    nv_sql_vacuum_finish(second);
    assert(nv_sql_vacuum_begin(db, &running) == SQLITE_OK);
    Job vacuum = {db, running, 1, -1}; thread = begin_job(&vacuum);
    nv_sql_vacuum_cancel(running); finish_job(thread);
    assert(vacuum.result == SQLITE_INTERRUPT); /* cancellation reaches running SQL */
    assert(row_count(db) == 8000);
    nv_sql_vacuum_finish(running);
    assert(sqlite3_close(db) == SQLITE_OK);
    nv_sql_vacuum_cancel(first); nv_sql_vacuum_cancel(second); nv_sql_vacuum_cancel(running);
    puts("PASS: pre-start save, foreign request, running interruption and late cancellation after close");
    return 0;
}
