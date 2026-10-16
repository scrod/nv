#ifndef NV_APPLE_PROJECTION_REPLACEMENT_H
#define NV_APPLE_PROJECTION_REPLACEMENT_H
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include "NVProjectionFiles.h"

NS_ASSUME_NONNULL_BEGIN
/* Preserves the held directory as the namespace anchor through a leaf replacement. */
CFURLRef _Nullable NVAppleProjectionURL(CFURLRef root, CFStringRef leaf) CF_RETURNS_RETAINED;
/* Borrows the owned stage for one entered, fully checked Foundation replacement.
 * The root owner supplies its paired directory reference and a fresh backup leaf,
 * retaining all returned artifacts for reconciliation and settlement. */
void NVAppleReplaceProjection(NSFileCoordinator *coordinator, CFURLRef root, CFURLRef stageURL,
    NVRootOwner *owner, NVProjectionStage *stage, const char *destination, const char *backup,
    const uint64_t *expected, const uint8_t * _Nullable previous, uint64_t previousCount,
    const uint8_t * _Nullable bytes, uint64_t count, const NVProjectionMetadata *metadata,
    NVProjectionReplacementResult *result);
/* Coordinates both exact names while retaining the actual source for later accounting. */
void NVAppleQuarantineProjection(NSFileCoordinator *coordinator, CFURLRef root, NVRootOwner *owner,
    const char *source, const char *recovery, const NVProjectionRead *expected, uint64_t maximum, int descriptor,
    NVProjectionSourceResult *result);
/* Coordinates a public rename/update and its private prepared stage as one operation. */
void NVAppleRelocateProjection(NSFileCoordinator *coordinator, CFURLRef root, CFURLRef stageURL,
    NVRootOwner *owner, NVProjectionStage *stage, const char *source, const char *destination, const char *backup,
    const NVProjectionRead *expected, uint64_t maximum, int descriptor,
    const uint8_t * _Nullable bytes, uint64_t count, const NVProjectionMetadata *metadata,
    NVProjectionRelocationResult *result);
/* Coordinates one logical deletion, retaining raced contents under its attempt. */
void NVAppleRemoveProjectionSource(NSFileCoordinator *coordinator, CFURLRef root, NVRootOwner *owner,
    const char *source, const char *recovery, const NVProjectionRead *expected, uint64_t maximum, int descriptor,
    NVProjectionCleanupResult *result);
NS_ASSUME_NONNULL_END
#endif
