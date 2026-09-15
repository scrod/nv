/* Hold the pinned engine's extra-init hook to expose its cold-start boundary. */
#include <sqlite3.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

extern int sqlcipher_extra_init(const char *);
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t condition = PTHREAD_COND_INITIALIZER;
static int entered, released, initializeFirst, initializationResult;

int nv_test_extra_init(const char *argument) {
    int rc = initializeFirst ? sqlcipher_extra_init(argument) : SQLITE_OK;
    pthread_mutex_lock(&mutex);
    entered = 1;
    pthread_cond_broadcast(&condition);
    while (!released) pthread_cond_wait(&condition, &mutex);
    pthread_mutex_unlock(&mutex);
    return initializeFirst ? rc : sqlcipher_extra_init(argument);
}

static void *initialize(void *unused) {
    (void)unused;
    initializationResult = sqlite3_initialize();
    return NULL;
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    initializeFirst = strcmp(argv[1], "after") == 0;
    pthread_t thread;
    if (pthread_create(&thread, NULL, initialize, NULL)) return 3;
    pthread_mutex_lock(&mutex);
    while (!entered) pthread_cond_wait(&condition, &mutex);
    pthread_mutex_unlock(&mutex);
    sqlite3 *database = NULL;
    int opened = sqlite3_open(":memory:", &database);
    int keyed = opened == SQLITE_OK ? sqlite3_key(database, "synthetic key", 13) : opened;
    pthread_mutex_lock(&mutex);
    released = 1;
    pthread_cond_broadcast(&condition);
    pthread_mutex_unlock(&mutex);
    pthread_join(thread, NULL);
    int retry = sqlite3_key(database, "synthetic key", 13);
    int write = sqlite3_exec(database, "CREATE TABLE probe(value); INSERT INTO probe VALUES(42)", NULL, NULL, NULL);
    sqlite3_close(database);
    printf("open=%d held-key=%d initialization=%d retry-key=%d write=%d\n", opened, keyed, initializationResult, retry, write);
    return opened != SQLITE_OK || keyed != (initializeFirst ? SQLITE_OK : SQLITE_ERROR)
        || initializationResult != SQLITE_OK || retry != SQLITE_OK || write != SQLITE_OK;
}
