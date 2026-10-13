#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include "NVRepositoryRoot.h"

NS_ASSUME_NONNULL_BEGIN
/* Creates a system reference positively bound to the held directory, using the selected path as a candidate. */
CFURLRef _Nullable NVAppleCreateRootReference(NVRootOwner *owner, const char *selectedPath) CF_RETURNS_RETAINED;
CFURLRef NVAppleAppendReference(CFURLRef root, CFStringRef relative) CF_RETURNS_RETAINED;
/* Checks exact relative components and the opaque, system-issued root reference. */
bool NVAppleReferenceHasRoot(CFURLRef actual, CFURLRef root, CFStringRef relative);

/* Accessors borrow their actual reference URLs synchronously on the calling executor. */
void NVAppleCoordinateRead(NSFileCoordinator *coordinator, CFURLRef url, NSFileCoordinatorReadingOptions options,
    NSError * _Nullable * _Nullable error, void (NS_NOESCAPE ^accessor)(CFURLRef actual));
void NVAppleCoordinateWrite(NSFileCoordinator *coordinator, CFURLRef url, NSFileCoordinatorWritingOptions options,
    NSError * _Nullable * _Nullable error, void (NS_NOESCAPE ^accessor)(CFURLRef actual));
void NVAppleCoordinateInstall(NSFileCoordinator *coordinator, CFURLRef source, CFURLRef destination,
    NSError * _Nullable * _Nullable error, void (NS_NOESCAPE ^accessor)(CFURLRef actualSource, CFURLRef actualDestination));

typedef struct {
    int ubiquitous, downloading, uploaded, unresolved, download;
    int status_domain, download_domain, upload_domain;
    int64_t status_code, download_code, upload_code;
} NVAppleAvailability;
void NVAppleReadAvailability(CFURLRef url, NVAppleAvailability *status);
bool NVAppleRequestMaterialization(CFURLRef url, NSError * _Nullable * _Nullable error);

typedef struct NVApplePresenter NVApplePresenter;
typedef NS_ENUM(int, NVApplePresenterEvent) {
    NVApplePresenterChanged, NVApplePresenterMoved, NVApplePresenterDeleting, NVApplePresenterEvicting
};
/* The presenter owns an independent reply queue and an NSLock-protected NSURL snapshot. */
NVApplePresenter *NVApplePresenterCreate(CFURLRef url, void (NS_SWIFT_SENDABLE ^event)(NVApplePresenterEvent));
/* Associates each rooted operation with its initiating presenter. */
NSFileCoordinator *NVApplePresenterCoordinator(NVApplePresenter * _Nullable presenter);
void NVApplePresenterRegister(NVApplePresenter *presenter, CFURLRef url);
bool NVApplePresenterIsRegistered(NVApplePresenter *presenter);
void NVApplePresenterClose(NVApplePresenter *presenter);
NS_ASSUME_NONNULL_END
