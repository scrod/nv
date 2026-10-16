#ifndef NV_STORAGE_IO_H
#define NV_STORAGE_IO_H
#include <stdint.h>
#include "NVRepositoryRoot.h"
#include "NVProjectionFiles.h"
typedef struct NVStorageOwner NVStorageOwner;
/* Caller owns the returned lease until close. errno reports native failures. */
NVStorageOwner *nv_storage_owner_open(const char *directory, int create);
/* Shares the existing lease's open description; either borrower can close independently. */
NVStorageOwner *nv_storage_owner_borrow(NVStorageOwner *owner);
/* Installs one immutable descriptor, with exact-existing comparison and durability barriers. */
int nv_storage_owner_descriptor(NVStorageOwner *owner, const char *leaf, const char *stage, const uint8_t *bytes, uint64_t count);
/* Lstat classification: 0 absent, 1 regular, 2 directory, 3 symlink, 4 other. */
int nv_storage_entry_kind(const char *path, int *kind);
/* Quiesced evidence copy includes the main file and every present required journal. */
int nv_storage_preserve_copy(const char *source, const char *destination, uint64_t observation[25]);
int nv_storage_owner_matches(NVStorageOwner *owner, const uint64_t observation[25]);
/* Captures the owned main file and journals after the SQL connection has settled. */
int nv_storage_owner_observe(NVStorageOwner *owner, uint64_t observation[25]);
typedef struct NVSelectionOwner NVSelectionOwner;
NVSelectionOwner *nv_selection_open(const char *directory);
int nv_selection_validate(NVSelectionOwner *owner);
int nv_selection_identity(NVSelectionOwner *owner, uint64_t identity[2]);
int nv_selection_read(NVSelectionOwner *owner, const char *leaf, uint8_t bytes[90], int *present);
int nv_selection_prepare(NVSelectionOwner *owner, const char *leaf, const uint8_t *expected, int present,
                         const uint8_t bytes[90], const char *stage_directory, const char *stage_leaf);
const char *nv_selection_destination(NVSelectionOwner *owner);
const char *nv_selection_stage_path(NVSelectionOwner *owner);
int nv_selection_expected(NVSelectionOwner *owner);
int nv_selection_install_portable(NVSelectionOwner *owner);
int nv_selection_complete(NVSelectionOwner *owner, const char *backup_leaf);
void nv_selection_close(NVSelectionOwner *owner);
typedef struct NVRepositoryOwner NVRepositoryOwner;
typedef struct NVRepositoryCatalog NVRepositoryCatalog;
/* Rooted copy primitives preserve exclusive destinations and compare captured entry generations. */
/* Duplicates an owned root descriptor for a copy confined to that root's coordinated turns. */
NVRepositoryOwner *nv_repository_borrow_root(NVRootOwner *owner);
int nv_repository_validate(NVRepositoryOwner *owner);
NVRepositoryCatalog *nv_repository_catalog(NVRepositoryOwner *owner, const char *relative);
/* Checks that a resumed directory stream still names the observed directory object. */
int nv_repository_catalog_validate(NVRepositoryOwner *owner, NVRepositoryCatalog *catalog, const char *relative);
const char *nv_repository_next(NVRepositoryCatalog *catalog);
void nv_repository_catalog_close(NVRepositoryCatalog *catalog);
int nv_repository_observe(NVRepositoryOwner *owner, const char *relative, uint64_t words[9]);
int nv_repository_read_open(NVRepositoryOwner *owner, const char *relative, const uint64_t expected[9]);
int nv_repository_mkdir(NVRepositoryOwner *owner, const char *relative);
int nv_repository_copy(NVRepositoryOwner *source, NVRepositoryOwner *destination, const char *relative, const uint64_t expected[9]);
int nv_repository_sync(NVRepositoryOwner *owner);
void nv_repository_close(NVRepositoryOwner *owner);
int nv_storage_owner_validate(NVStorageOwner *owner);
const char *nv_storage_owner_database(NVStorageOwner *owner);
void nv_storage_owner_close(NVStorageOwner *owner);
#endif
