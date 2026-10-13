#include "NVSQLMaintenance.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>

/* The registry owns a connection borrow until its owner retires the settled job. */
typedef struct VacuumWork {
    uint64_t identity;
    sqlite3 *connection;
    atomic_int cancelled;
    int running;
    struct VacuumWork *next;
} VacuumWork;

static pthread_mutex_t registry_lock = PTHREAD_MUTEX_INITIALIZER;
static VacuumWork *registry;
static uint64_t next_identity = 1;

int nv_sql_vacuum_begin(sqlite3 *connection, uint64_t *identity) {
    if (!connection || !identity) return SQLITE_MISUSE;
    VacuumWork *work = calloc(1, sizeof(*work));
    if (!work) return SQLITE_NOMEM;
    atomic_init(&work->cancelled, 0);
    pthread_mutex_lock(&registry_lock);
    for (VacuumWork *old = registry; old; old = old->next) {
        if (old->connection == connection) {
            pthread_mutex_unlock(&registry_lock); free(work); return SQLITE_BUSY;
        }
    }
    if (next_identity == 0) {
        pthread_mutex_unlock(&registry_lock); free(work); return SQLITE_FULL;
    }
    work->identity = next_identity++;
    work->connection = connection;
    work->next = registry; registry = work;
    *identity = work->identity;
    pthread_mutex_unlock(&registry_lock);
    return SQLITE_OK;
}

static int cancelled(void *context) {
    VacuumWork *work = context;
    return atomic_load_explicit(&work->cancelled, memory_order_relaxed);
}

int nv_sql_vacuum_run(sqlite3 *connection, uint64_t identity) {
    pthread_mutex_lock(&registry_lock);
    VacuumWork *work = registry;
    while (work && work->identity != identity) work = work->next;
    if (!work || work->connection != connection || work->running) {
        pthread_mutex_unlock(&registry_lock); return SQLITE_MISUSE;
    }
    work->running = 1;
    pthread_mutex_unlock(&registry_lock);
    /* A request between this check and sqlite3_exec reaches the progress handler. */
    int result = SQLITE_INTERRUPT;
    if (!cancelled(work)) {
        sqlite3_progress_handler(connection, 256, cancelled, work);
        result = sqlite3_exec(connection, "VACUUM main", NULL, NULL, NULL);
        sqlite3_progress_handler(connection, 0, NULL, NULL);
    }
    pthread_mutex_lock(&registry_lock);
    work->running = 0;
    pthread_mutex_unlock(&registry_lock);
    return result;
}

void nv_sql_vacuum_cancel(uint64_t identity) {
    pthread_mutex_lock(&registry_lock);
    for (VacuumWork *work = registry; work; work = work->next) {
        if (work->identity == identity) {
            atomic_store_explicit(&work->cancelled, 1, memory_order_relaxed);
            /* The registry lock keeps this connection borrow alive through the call. */
            if (work->running) sqlite3_interrupt(work->connection);
            break;
        }
    }
    pthread_mutex_unlock(&registry_lock);
}

void nv_sql_vacuum_finish(uint64_t identity) {
    pthread_mutex_lock(&registry_lock);
    VacuumWork **link = &registry;
    while (*link && (*link)->identity != identity) link = &(*link)->next;
    if (*link && !(*link)->running) {
        VacuumWork *work = *link; *link = work->next; free(work);
    }
    pthread_mutex_unlock(&registry_lock);
}
