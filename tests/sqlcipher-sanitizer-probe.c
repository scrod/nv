/* Qualifies instrumentation inside the separately compiled cipher library. */
#include <sqlite3.h>
#include <string.h>

int main(int argc, char **argv) {
    sqlite3 *database = NULL;
    if (sqlite3_open(":memory:", &database) != SQLITE_OK) return 2;
    if (argc == 2 && strcmp(argv[1], "expired-handle") == 0) {
        sqlite3_close(database);
        /* The negative control enters SQLCipher with an intentionally expired handle. */
        return sqlite3_total_changes(database);
    }
    if (sqlite3_exec(database, "CREATE TABLE t(v); INSERT INTO t VALUES(1)", NULL, NULL, NULL) != SQLITE_OK) return 3;
    if (sqlite3_total_changes(database) != 1) return 4;
    return sqlite3_close(database);
}
