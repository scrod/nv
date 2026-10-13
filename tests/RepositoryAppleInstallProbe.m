#import "NVAppleFileAccess.h"
#include <stdio.h>
#include <errno.h>

/* Diagnoses the exact stage binding across real Foundation grants in an owned fixture. */
static void report(const char *phase, NVRootInstallResult result, const uint64_t words[9]) {
    NSMutableArray *values = [NSMutableArray array];
    for (unsigned index = 0; index < 9; index++) [values addObject:@(words[index])];
    NSDictionary *state = @{@"phase":@(phase), @"outcome":@(result.outcome), @"error":@(result.error),
        @"retained":@(result.stage_retained), @"namespace":@(result.namespace_changed), @"words":values};
    NSData *data = [NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingSortedKeys error:NULL];
    fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout); fflush(stdout);
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2) return 2;
        NVRootOwner *owner = nv_root_open(argv[1]);
        if (!owner) return 3;
        CFURLRef reference = NVAppleCreateRootReference(owner, argv[1]);
        if (!reference) { nv_root_close(owner); return 4; }
        /* An unrelated candidate either fails or still yields the independently held root. */
        CFURLRef unrelated = NVAppleCreateRootReference(owner, "/");
        bool sameOwner = !unrelated || CFEqual(reference, unrelated);
        if (unrelated) CFRelease(unrelated);
        printf("{\"phase\":\"reference\",\"unrelated_preserves_owner\":%s}\n", sameOwner ? "true" : "false");
        if (!sameOwner) { CFRelease(reference); nv_root_close(owner); return 7; }
        NSString *stage = [@".nv-stage-" stringByAppendingString:NSUUID.UUID.UUIDString];
        NSData *bytes = [@"NV synthetic coordinated stage diagnostic" dataUsingEncoding:NSUTF8StringEncoding];
        CFURLRef source = NVAppleAppendReference(reference, (__bridge CFStringRef)stage);
        CFURLRef destination = NVAppleAppendReference(reference, CFSTR("diagnostic.nvseg"));
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        NSError *error = nil;
        __block NVRootInstallResult prepared = {0}, installed = {0};
        __block NVRootPreparedStage *owned = NULL;
        uint64_t captured[9] = {0};
        uint64_t *expected = captured;
        NVAppleCoordinateWrite(coordinator, source, 0, &error, ^(CFURLRef actual) {
            if (!NVAppleReferenceHasRoot(actual, reference, (__bridge CFStringRef)stage)) { prepared.error=ESTALE; return; }
            owned = nv_root_prepare_owned_stage(owner, stage.UTF8String, bytes.bytes, bytes.length, &prepared);
            (void)nv_root_snapshot(owner, stage.UTF8String, expected);
            report("prepared", prepared, expected);
        });
        if (error || prepared.outcome != NV_ROOT_INSTALL_VERIFIED) {
            report("prepare-failed", prepared, expected); nv_root_prepared_stage_close(owned); CFRelease(source); CFRelease(destination); CFRelease(reference); nv_root_close(owner); return 5;
        }
        NVAppleCoordinateInstall(coordinator, source, destination, &error, ^(CFURLRef actualSource, CFURLRef actualDestination) {
            uint64_t current[9] = {0};
            int sourceMatches = NVAppleReferenceHasRoot(actualSource, reference, (__bridge CFStringRef)stage);
            int targetMatches = NVAppleReferenceHasRoot(actualDestination, reference, CFSTR("diagnostic.nvseg"));
            printf("{\"source_matches\":%d,\"destination_matches\":%d}\n", sourceMatches, targetMatches);
            if (nv_root_snapshot(owner, stage.UTF8String, current)) { installed.error=errno; report("snapshot-failed", installed, current); return; }
            report("entered", installed, current);
            if (!sourceMatches || !targetMatches) { installed.error=ESTALE; return; }
            nv_root_install_owned_stage(owner, "diagnostic.nvseg", owned, bytes.bytes, bytes.length, &installed);
            report("installed", installed, current);
        });
        report(error ? "coordinate-failed" : "complete", installed, expected);
        nv_root_prepared_stage_close(owned); CFRelease(source); CFRelease(destination); CFRelease(reference); nv_root_close(owner);
        return error || installed.outcome != NV_ROOT_INSTALL_VERIFIED ? 6 : 0;
    }
}
