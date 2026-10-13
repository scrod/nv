#ifndef NV_SQL_MAINTENANCE_H
#define NV_SQL_MAINTENANCE_H
#include <stdint.h>
#include <sqlite3.h>

/* Register one owner-confined VACUUM; cancellation uses its unique scalar identity. */
int nv_sql_vacuum_begin(sqlite3 *connection, uint64_t *identity);
/* Run and settle on the connection's owner. Pre-start cancellation is remembered. */
int nv_sql_vacuum_run(sqlite3 *connection, uint64_t identity);
/* Retire on the owner after running, or after abandoning before the run. */
void nv_sql_vacuum_finish(uint64_t identity);
/* Thread-safe: request cancellation of the registered job with this exact identity. */
void nv_sql_vacuum_cancel(uint64_t identity);
#endif
