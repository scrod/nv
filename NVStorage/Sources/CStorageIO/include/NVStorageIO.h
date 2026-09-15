#ifndef NV_STORAGE_IO_H
#define NV_STORAGE_IO_H
#include <stdint.h>
typedef struct NVStorageOwner NVStorageOwner;
/* Caller owns the returned lease until close. errno reports native failures. */
NVStorageOwner *nv_storage_owner_open(const char *directory, int create);
int nv_storage_owner_validate(NVStorageOwner *owner);
const char *nv_storage_owner_database(NVStorageOwner *owner);
void nv_storage_owner_close(NVStorageOwner *owner);
#endif
