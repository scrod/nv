/* NV bridge declaration for the unchanged upstream implementation in src/core.c.
 * Signature matches src/core.h; expose only its explicit-wipe helper to Swift. */
#include <stddef.h>
void secure_wipe_memory(void *v, size_t n);
