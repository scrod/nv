#ifndef NV_APPLE_NAMESPACE_INTERNAL_H
#define NV_APPLE_NAMESPACE_INTERNAL_H
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

NS_ASSUME_NONNULL_BEGIN
/* Builds the existing rooted reference representation for exact namespace checks. */
static inline CFURLRef NVAppleNamespaceAppend(CFURLRef root, CFStringRef relative) CF_RETURNS_RETAINED {
    NSURL *value = (__bridge NSURL *)root;
    for (NSString *component in [(__bridge NSString *)relative componentsSeparatedByString:@"/"]) {
        if (component.length) value = [value URLByAppendingPathComponent:component];
    }
    return CFBridgingRetain(value);
}

/* Matches canonical leaf spellings and the exact issued root reference. */
static inline bool NVAppleNamespaceHasRoot(CFURLRef actual, CFURLRef root, CFStringRef relative) {
    if (!CFURLIsFileReferenceURL(actual) && ![(__bridge NSURL *)actual isFileURL]) return false;
    CFURLRef requested = NVAppleNamespaceAppend(root, relative);
    bool exact = CFEqual(actual, requested);
    CFRelease(requested);
    if (exact) return true;
    CFURLRef candidate = CFRetain(actual);
    NSArray<NSString *> *components = [(__bridge NSString *)relative componentsSeparatedByString:@"/"];
    for (NSString *component in components.reverseObjectEnumerator) {
        if (!component.length) continue;
        CFStringRef leaf = CFURLCopyLastPathComponent(candidate);
        bool equal = leaf && [[(__bridge NSString *)leaf precomposedStringWithCanonicalMapping]
            isEqualToString:component.precomposedStringWithCanonicalMapping];
        if (leaf) CFRelease(leaf);
        if (!equal) { CFRelease(candidate); return false; }
        CFURLRef parent = CFURLCreateCopyDeletingLastPathComponent(kCFAllocatorDefault, candidate);
        CFRelease(candidate); candidate = parent;
        if (!candidate) return false;
    }
    CFURLRef reference = CFURLCreateFileReferenceURL(kCFAllocatorDefault, candidate, NULL);
    CFRelease(candidate);
    bool equal = reference && CFEqual(reference, root);
    if (reference) CFRelease(reference);
    return equal;
}
NS_ASSUME_NONNULL_END
#endif
