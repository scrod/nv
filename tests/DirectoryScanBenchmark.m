#import "NVRootedDirectory_Private.h"
#include "NVRepositoryRoot.h"
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

/* Measures the production scanners against the same established file inventory. */
static void Require(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "%s\n", [message UTF8String]); exit(2); }
}

static double Now(void) {
    struct timespec value;
    Require(clock_gettime(CLOCK_MONOTONIC, &value) == 0, @"Read monotonic clock");
    return (double)value.tv_sec + (double)value.tv_nsec / 1e9;
}

/* A comparison labeled bulk requires the production fast path on this filesystem. */
@interface NVBenchmarkRootedDirectory : NVRootedDirectory
@end
@implementation NVBenchmarkRootedDirectory
- (NVRootedDirectoryCatalog *)_newFoundationCatalog:(NSError **)error {
    (void)error;
    Require(NO, @"Bulk scanner fell back to Foundation; classify this filesystem separately");
    return nil;
}
@end

static NSUInteger NativeScan(NVRootOwner *root, NSArray *directories, BOOL metadata,
                             unsigned budget, NSMutableDictionary *inventory) {
    NSUInteger count = 0;
    for (NSString *directory in directories) {
        NVRootListing *listing = nv_root_list_open(root, [directory UTF8String]);
        Require(listing != NULL, @"Open production listing");
        int ended = 0;
        while (!ended) {
            uint8_t bytes[256 * 257]; unsigned used = 0;
            Require(nv_root_list_next(root, listing, budget, bytes, sizeof(bytes), &used, &ended) == 0,
                    @"Continue production listing");
            for (unsigned offset = 0; offset < used;) {
                unsigned length = bytes[offset++];
                Require(length && length <= used - offset, @"Decode complete native leaf");
                char leaf[256]; memcpy(leaf, bytes + offset, length); leaf[length] = 0; offset += length;
                if (metadata) {
                    char relative[1024];
                    int written = snprintf(relative, sizeof(relative), "%s/%s", [directory UTF8String], leaf);
                    Require(written > 0 && (size_t)written < sizeof(relative), @"Build benchmark relative path");
                    uint64_t words[9];
                    Require(nv_root_snapshot(root, relative, words) == 0 && words[0] == 1, @"Observe regular fixture");
                    if (inventory) [inventory setObject:@(words[2]) forKey:[NSString stringWithUTF8String:relative]];
                }
                count++;
            }
        }
        nv_root_list_close(listing);
    }
    return count;
}

static NSUInteger LegacyScan(NSArray *roots, NSArray *directories, BOOL fence,
                             NSMutableDictionary *inventory) {
    NSUInteger count = 0;
    for (NSUInteger i = 0; i < [roots count]; i++) {
        NSError *error = nil;
        NVRootedDirectoryCatalog *catalog = [[roots objectAtIndex:i] newCatalog:&error];
        Require(catalog != nil, [NSString stringWithFormat:@"Production legacy catalog: %@", error]);
        count += [catalog count];
        if (inventory) {
            NoteCatalogEntry *entries = [catalog entries];
            for (size_t n = 0; n < [catalog count]; n++)
                [inventory setObject:@(entries[n].fileID) forKey:
                    [[directories objectAtIndex:i] stringByAppendingPathComponent:(NSString *)entries[n].filename]];
        }
        if (fence) {
            NVRootedDirectoryCatalog *second = [[roots objectAtIndex:i] newCatalog:&error];
            Require(second != nil && [catalog isExactlyEqualToCatalog:second], @"Stable legacy catalog fence");
            [second release];
        }
        [catalog release];
    }
    return count;
}

/* Measures the production held-directory metadata primitive with exact inode inventory. */
static NSUInteger MetadataScan(NVRootOwner *root, NSArray *directories, BOOL portable,
                               NSMutableDictionary *inventory) {
    NSUInteger count = 0;
    for (NSString *directory in directories) {
        NVRootListing *listing = nv_root_metadata_open(root, [directory UTF8String], portable);
        Require(listing != NULL, @"Open production metadata stream");
        int ended = 0;
        while (!ended) {
            NVRootMetadataEntry entries[64]; NVRootMetadataTurn turn;
            Require(nv_root_metadata_next(root, listing, 16, entries, &turn) == 0 && turn.count <= 64,
                    @"Read bounded production metadata");
            for (unsigned i = 0; i < turn.count; i++) {
                Require(entries[i].error == 0 && entries[i].words[0] == 1, @"Observe regular comparison fixture");
                if (inventory) {
                    NSString *leaf = [[[NSString alloc] initWithBytes:entries[i].name length:entries[i].length
                                                           encoding:NSUTF8StringEncoding] autorelease];
                    Require(leaf != nil, @"Decode comparison fixture leaf");
                    [inventory setObject:@(entries[i].words[2]) forKey:[directory stringByAppendingPathComponent:leaf]];
                }
                count++;
            }
            ended = turn.finished;
        }
        nv_root_list_close(listing);
    }
    return count;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        Require(argc == 4, @"Usage: DirectoryScanBenchmark ROOT EXPECTED_FILES REPETITIONS");
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        NSUInteger expected = (NSUInteger)strtoull(argv[2], NULL, 10);
        NSUInteger repetitions = (NSUInteger)strtoull(argv[3], NULL, 10);
        Require(expected > 0 && repetitions >= 3 && repetitions <= 100, @"Positive fixture and bounded repetitions");
        NSString *segments = @"NV Data/v1/segments";
        NSArray *writers = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:
            [path stringByAppendingPathComponent:segments] error:NULL];
        Require([writers count] > 0, @"Enumerate fixture writers outside measured scans");
        NSMutableArray *directories = [NSMutableArray array], *roots = [NSMutableArray array];
        for (NSString *writer in [writers sortedArrayUsingSelector:@selector(compare:)]) {
            NSString *relative = [segments stringByAppendingPathComponent:writer];
            NSError *error = nil;
            NSURL *URL = [[NSURL fileURLWithPath:[path stringByAppendingPathComponent:relative] isDirectory:YES] fileReferenceURL];
            NVRootedDirectory *legacy = [[NVBenchmarkRootedDirectory alloc] initWithFileReferenceURL:URL error:&error];
            Require(legacy != nil, [NSString stringWithFormat:@"Open production legacy root: %@", error]);
            [roots addObject:legacy]; [legacy release]; [directories addObject:relative];
        }
        NVRootOwner *root = nv_root_open([path fileSystemRepresentation]);
        Require(root != NULL, @"Own production native root");
        NSMutableDictionary *legacyInventory = [NSMutableDictionary dictionary], *nativeInventory = [NSMutableDictionary dictionary];
        Require(LegacyScan(roots, directories, NO, legacyInventory) == expected, @"Exact legacy fixture count");
        Require(NativeScan(root, directories, YES, 16, nativeInventory) == expected, @"Exact native fixture count");
        Require([legacyInventory isEqual:nativeInventory], @"Independent names and file IDs agree");
        for (BOOL portable = NO;; portable = YES) {
            NSMutableDictionary *metadataInventory = [NSMutableDictionary dictionary];
            Require(MetadataScan(root, directories, portable, metadataInventory) == expected &&
                    [metadataInventory isEqual:legacyInventory], @"Production metadata preserves exact comparison inventory");
            if (portable) break;
        }
        NSArray *names = @[@"legacy-bulk-catalog", @"legacy-double-catalog-fence", @"native-names-16", @"native-names-256", @"native-observations-16", @"native-bulk-metadata", @"native-portable-metadata"];
        NSMutableDictionary *samples = [NSMutableDictionary dictionary];
        for (NSString *name in names) [samples setObject:[NSMutableArray array] forKey:name];
        /* The first interleaved round warms every implementation before measurement. */
        for (NSUInteger round = 0; round <= repetitions; round++) {
            for (NSUInteger n = 0; n < [names count]; n++) {
                NSUInteger choice = (n + round) % [names count];
                @autoreleasepool {
                    double start = Now(); NSUInteger observed = 0;
                    switch (choice) {
                        case 0: observed = LegacyScan(roots, directories, NO, nil); break;
                        case 1: observed = LegacyScan(roots, directories, YES, nil); break;
                        case 2: observed = NativeScan(root, directories, NO, 16, nil); break;
                        case 3: observed = NativeScan(root, directories, NO, 256, nil); break;
                        case 4: observed = NativeScan(root, directories, YES, 16, nil); break;
                        case 5: observed = MetadataScan(root, directories, NO, nil); break;
                        default: observed = MetadataScan(root, directories, YES, nil); break;
                    }
                    double milliseconds = (Now() - start) * 1000;
                    Require(observed == expected, @"Every measured scan preserves the exact fixture count");
                    if (round) [[samples objectForKey:[names objectAtIndex:choice]] addObject:@(milliseconds)];
                }
            }
        }
        nv_root_close(root);
        NSDictionary *result = @{@"files": @(expected), @"writerDirectories": @([directories count]), @"samplesMilliseconds": samples};
        NSData *JSON = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:NULL];
        Require(JSON != nil, @"Encode benchmark results");
        fwrite([JSON bytes], 1, [JSON length], stdout); fputc('\n', stdout);
    }
    return 0;
}
