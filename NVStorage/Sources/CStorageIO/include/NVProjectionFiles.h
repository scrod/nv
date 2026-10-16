#ifndef NV_PROJECTION_FILES_H
#define NV_PROJECTION_FILES_H
#include "NVRepositoryRoot.h"

/* Raw metadata distinguishes absent values, present empty values and unsupported storage. */
typedef struct { uint8_t *bytes; uint32_t count; int state; } NVProjectionAttribute;
typedef struct {
    uint8_t *bytes;
    uint64_t count, words[9];
    NVProjectionAttribute encoding, tags, finder_tags, stamp;
    uint32_t permissions;
    int has_birth;
    int64_t birth_seconds;
    uint32_t birth_nanoseconds;
} NVProjectionRead;

/* Copies one coherent direct-child file through its held descriptor. Results are
 * 0 complete, 1 dataless, -1 file failure, -2 root failure. The caller owns *output. */
int nv_projection_read(NVRootOwner *owner, const char *leaf, const uint64_t expected[9],
                       uint64_t maximum, NVProjectionRead **output);
/* Transfers the descriptor of the same successful coherent read to the caller.
 * Failure leaves *descriptor at -1; success gives the caller its sole close duty. */
int nv_projection_read_retaining(NVRootOwner *owner, const char *leaf, const uint64_t expected[9],
    uint64_t maximum, NVProjectionRead **output, int *descriptor);
void nv_projection_read_close(NVProjectionRead *read);

/* Borrowed exact attribute bytes prepared by the note-output owner. */
typedef struct { const uint8_t *bytes; uint32_t count; int present; } NVProjectionAttributeValue;
typedef struct {
    NVProjectionAttributeValue encoding, tags, finder_tags, stamp;
    uint32_t permissions;
    int has_birth;
    int64_t birth_seconds, modified_seconds;
    uint32_t birth_nanoseconds, modified_nanoseconds;
} NVProjectionMetadata;
typedef struct NVProjectionStage NVProjectionStage;
enum { NV_PROJECTION_NO_EFFECT = 0, NV_PROJECTION_STAGED = 1,
       NV_PROJECTION_INSTALLED = 2, NV_PROJECTION_UNCERTAIN = 3 };
typedef struct {
    int outcome, error, root_lost;
    int stamp_error, finder_tags_error, directory_sync_error;
    uint64_t installed_words[9];
    int installed_has_birth;
    int64_t installed_birth_seconds;
    uint32_t installed_birth_nanoseconds;
} NVProjectionEffect;

/* Retains a private same-volume directory and its exclusively created stage.
 * A returned owner retains even failed preparation; close releases descriptors
 * while preserving named artifacts for the operation's settlement. */
NVProjectionStage *nv_projection_prepare(NVRootOwner *owner, int private_directory,
    const char *stage_leaf, const uint8_t *bytes, uint64_t count,
    const NVProjectionMetadata *metadata, NVProjectionEffect *effect);
void nv_projection_stage_close(NVProjectionStage *stage);

/* Exclusively moves the prepared stage to one direct-child destination, then
 * verifies exact body/metadata through the same retained file descriptor. */
void nv_projection_create(NVRootOwner *owner, NVProjectionStage *stage,
    const char *destination, const uint8_t *bytes, uint64_t count,
    const NVProjectionMetadata *metadata, NVProjectionEffect *effect);

/* Prepares a replacement while preserving the checked original's permissions and
 * custom metadata. The expected bytes describe the original operation's source. */
NVProjectionStage *nv_projection_prepare_replacement(NVRootOwner *owner, int private_directory,
    const char *stage_leaf, const char *destination, const uint64_t expected[9],
    const uint8_t *previous, uint64_t previous_count, const uint8_t *bytes, uint64_t count,
    const NVProjectionMetadata *metadata, NVProjectionEffect *effect);

enum { NV_PROJECTION_BACKUP_UNCHECKED = 0, NV_PROJECTION_BACKUP_EXPECTED = 1,
       NV_PROJECTION_BACKUP_CHANGED = 2 };
typedef struct {
    NVProjectionEffect installation;
    int backup_comparison, backup_error;
    uint64_t backup_words[9];
} NVProjectionReplacementResult;
/* The entered, synchronous Foundation adapter borrows the stage descriptor and
 * returns a POSIX error code, with zero denoting a successful replacement call. */
typedef int (*NVProjectionReplacementCall)(void *context, int stage_descriptor);
/* Rechecks both named inputs, invokes the entered replacement exactly once, then
 * checks the actual retained backup and installed output. Every artifact remains
 * owned for subsequent reconciliation/settlement, including uncertain effects. */
void nv_projection_replace(NVRootOwner *owner, NVProjectionStage *stage,
    const char *destination, const char *backup, const uint64_t expected[9],
    const uint8_t *previous, uint64_t previous_count, const uint8_t *bytes, uint64_t count,
    const NVProjectionMetadata *metadata, void *context, NVProjectionReplacementCall replace,
    NVProjectionReplacementResult *result);
enum { NV_PROJECTION_SOURCE_NO_EFFECT = 0, NV_PROJECTION_SOURCE_CAPTURED = 1,
       NV_PROJECTION_SOURCE_RESTORED = 2, NV_PROJECTION_SOURCE_RETAINED = 3,
       NV_PROJECTION_SOURCE_UNCERTAIN = 4 };
enum { NV_PROJECTION_NAME_UNAVAILABLE = 0, NV_PROJECTION_NAME_ABSENT = 1, NV_PROJECTION_NAME_PRESENT = 2 };
typedef struct {
    int outcome, error, root_lost, directory_sync_error;
    int artifact_state, source_state;
    uint64_t artifact_words[9], source_words[9];
} NVProjectionSourceResult;
/* Retains the actual source at an exclusive recovery name and compares it with
 * the original observation. A racing file is restored exclusively when possible.
 * Named contents remain available for the caller's durable source accounting. */
/* Synchronous move notices bracket the actual outbound/restoration calls.
 * restoring selects recovery-to-source; completed marks a successful rename. */
typedef void (*NVProjectionSourceMoveNotice)(void *context, int restoring, int completed);
void nv_projection_quarantine_source(NVRootOwner *owner, const char *source, const char *recovery,
    const NVProjectionRead *expected, uint64_t maximum, int descriptor,
    void *context, NVProjectionSourceMoveNotice notify,
    NVProjectionSourceResult *result);

/* Retains the captured original and independently reports installation at the new name. */
typedef struct {
    NVProjectionReplacementResult replacement;
    NVProjectionSourceResult source;
} NVProjectionRelocationResult;
/* Captures the exact source at the reserved backup, then installs the prepared
 * output exclusively. A known installation refusal restores the original
 * exclusively when possible. Every displaced stream remains available. */
void nv_projection_relocate(NVRootOwner *owner, NVProjectionStage *stage,
    const char *source, const char *destination, const char *backup,
    const NVProjectionRead *expected, uint64_t maximum, int descriptor, int prepared_descriptor,
    const uint8_t *bytes, uint64_t count, const NVProjectionMetadata *metadata,
    NVProjectionRelocationResult *result);

enum { NV_PROJECTION_CLEANUP_NO_EFFECT = 0, NV_PROJECTION_CLEANUP_REMOVED = 1,
       NV_PROJECTION_CLEANUP_UNCERTAIN = 2 };
typedef struct {
    int outcome, error, root_lost, directory_sync_error;
    int directory_created; /* Records exclusive acquisition of this attempt's protected directory. */
    int artifact_state, captured_state;
    uint64_t artifact_words[9], captured_words[9];
} NVProjectionCleanupResult;
/* Captures the original source directly into recovery + ".cleanup/item", verifies
 * its exact observation and removes only the matching protected item. */
void nv_projection_remove_source(NVRootOwner *owner, const char *source, const char *recovery,
    const NVProjectionRead *expected, uint64_t maximum, int descriptor, NVProjectionCleanupResult *result);
/* Reads the retained child in artifact + ".cleanup", through no-follow held
 * directories. Absence is ENOENT; this fresh inspection grants read authority. */
int nv_projection_read_cleanup(NVRootOwner *owner, const char *artifact, uint64_t maximum,
    NVProjectionRead **output);
#endif
