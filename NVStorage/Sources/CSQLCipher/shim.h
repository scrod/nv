#define SQLITE_HAS_CODEC 1
#include <sqlite3.h>
/* Move checkpoint work into explicit maintenance rather than handle destruction. */
static inline int nv_sqlcipher_explicit_checkpoints(sqlite3 *db) {
    int enabled = 0;
    int rc = sqlite3_db_config(db, SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, 1, &enabled);
    return rc == SQLITE_OK && enabled != 1 ? SQLITE_ERROR : rc;
}
