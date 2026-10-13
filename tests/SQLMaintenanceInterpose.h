#include <sqlite3.h>
void nv_test_progress_handler(sqlite3 *, int, int (*)(void *), void *);
#define sqlite3_progress_handler nv_test_progress_handler
