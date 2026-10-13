#ifndef NV_REPOSITORY_ROOT_H
#define NV_REPOSITORY_ROOT_H
#include <stdint.h>

typedef struct NVRootOwner NVRootOwner;
/* Owns an already existing directory and its nonblocking exclusive object lock. */
NVRootOwner *nv_root_open(const char *path);
/* Exclusively creates the selected final directory and retains its physical ownership. */
NVRootOwner *nv_root_create(const char *path);
/* Checks retained identity and delivered deletion/revocation events on that object. */
int nv_root_validate(NVRootOwner *owner);
/* Returns 1 for the same directory, 0 for another object, and -1 on failed observation. */
int nv_root_compare(NVRootOwner *owner, const char *candidate);
/* Copies the positively checked held directory's device/inode association hint. */
int nv_root_identity(NVRootOwner *owner, uint64_t words[2]);
/* Copies kind/device/inode/size/links; -1 denotes a child error, -2 a root-check error. */
int nv_root_observe(NVRootOwner *owner, const char *relative, uint64_t words[5]);
/* Exact observations include modification/change timestamps for coherent reads. */
int nv_root_snapshot(NVRootOwner *owner, const char *relative, uint64_t words[9]);
/* Reports dataless residency against an exact observation; -1 means unknown residency. */
int nv_root_residency(NVRootOwner *owner, const char *relative, const uint64_t expected[9], int *dataless);
/* Reads a bounded regular file against its exact observation. Root loss returns -2. */
int nv_root_read(NVRootOwner *owner, const char *relative, const uint64_t expected[9],
                 uint8_t *bytes, uint64_t count);

typedef struct NVRootListing NVRootListing;
/* A listing owns a shallow directory stream, resumed in bounded executor turns. */
NVRootListing *nv_root_list_open(NVRootOwner *owner, const char *relative);
/* Emits length-prefixed raw leaf bytes; budget bounds entries inspected, including dots. */
int nv_root_list_next(NVRootOwner *owner, NVRootListing *listing, unsigned budget,
                     uint8_t *bytes, unsigned capacity, unsigned *used, int *finished);
void nv_root_list_close(NVRootListing *listing);

/* Bounded copied metadata preserves raw names and coherent-read fingerprint fields. */
typedef struct {
    uint32_t length;
    int error, refresh;
    uint8_t name[256];
    uint64_t words[9];
} NVRootMetadataEntry;
typedef struct {
    unsigned count, stat_calls, bulk_calls, ancestor_checks;
    int finished;
} NVRootMetadataTurn;
/* Metadata streams choose bulk enumeration on Darwin or portable no-follow observations. */
NVRootListing *nv_root_metadata_open(NVRootOwner *owner, const char *relative, int portable);
/* Native read-ahead is capped at 64 copied entries, independently of the caller's leaf budget. */
int nv_root_metadata_next(NVRootOwner *owner, NVRootListing *listing, unsigned budget,
                         NVRootMetadataEntry entries[64], NVRootMetadataTurn *turn);
/* Refreshes retained names through the same held directory, including after native EOF. */
int nv_root_metadata_refresh(NVRootOwner *owner, NVRootListing *listing,
                            NVRootMetadataEntry *entries, unsigned count, NVRootMetadataTurn *turn);

typedef enum {
    NV_ROOT_INSTALL_VERIFIED = 1, NV_ROOT_INSTALL_NO_EFFECT = 2, NV_ROOT_INSTALL_UNCERTAIN = 3
} NVRootInstallOutcome;
typedef struct {
    NVRootInstallOutcome outcome;
    int error, existing, namespace_changed, stage_retained, cleanup_error, root_lost;
} NVRootInstallResult;
/* Installs complete staged bytes through the native exclusive-rename primitive. */
void nv_root_install(NVRootOwner *owner, const char *relative, const char *stage,
                     const uint8_t *bytes, uint64_t count, NVRootInstallResult *result);
/* Add-only single-directory preparation for an individually coordinated destination. */
void nv_root_make_directory(NVRootOwner *owner, const char *relative, NVRootInstallResult *result);
/* Reserves a newly initialized namespace by failing on every existing final entry. */
void nv_root_create_directory(NVRootOwner *owner, const char *relative, NVRootInstallResult *result);
typedef struct NVRootPreparedStage NVRootPreparedStage;
/* Retains the verified open stage across separately granted coordination intervals. */
NVRootPreparedStage *nv_root_prepare_owned_stage(NVRootOwner *owner, const char *stage,
    const uint8_t *bytes, uint64_t count, NVRootInstallResult *result);
/* Rechecks the held object, its current name and exact bytes before exclusive installation. */
void nv_root_install_owned_stage(NVRootOwner *owner, const char *relative, NVRootPreparedStage *stage,
    const uint8_t *bytes, uint64_t count, NVRootInstallResult *result);
/* Releases the held descriptor while preserving any retained stage artifact. */
void nv_root_prepared_stage_close(NVRootPreparedStage *stage);
/* Last-reference close releases ownership after all entered work has settled. */
void nv_root_close(NVRootOwner *owner);
#endif
