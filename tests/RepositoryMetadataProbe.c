#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#if defined(__APPLE__)
#include <sys/attr.h>
static int test_bulk(int fd, struct attrlist *attrs, void *buffer, size_t size, uint64_t options);
#endif
static int test_stat(int fd, const char *name, struct stat *value, int flags);
static void test_event(const char *event, int fd);
#include "../NVStorage/Sources/CStorageIO/NVRepositoryRoot.c"
#if defined(__APPLE__)
#define getattrlistbulk test_bulk
#endif
#define fstatat test_stat
#define NV_REPOSITORY_EVENT(name, fd) test_event(name, fd)
#include "../NVStorage/Sources/CStorageIO/NVRepositoryFiles.c"
#undef fstatat
#if defined(__APPLE__)
#undef getattrlistbulk
#endif

static const char *mode;
static int bulk_calls, event_count;
static void require(int condition, const char *message) {
    if (!condition) { fprintf(stderr, "ASSERT: %s (errno=%d)\n", message, errno); exit(1); }
}
static int test_stat(int fd, const char *name, struct stat *value, int flags) {
    if (!strcmp(mode, "child-error") && !strcmp(name, "unavailable")) { errno = EACCES; return -1; }
    return fstatat(fd, name, value, flags);
}
static void test_event(const char *event, int fd) {
    if (strcmp(event, "metadata-after") || strcmp(mode, "ancestor")) return;
    event_count++;
    if (event_count != 1) return;
    require(renameat(fd, "../keys", fd, "../displaced-keys") == 0, "Move the held directory during its metadata turn");
    require(mkdirat(fd, "../keys", 0700) == 0, "Install a distinct directory at the original name");
}
#if defined(__APPLE__)
static int test_bulk(int fd, struct attrlist *attrs, void *buffer, size_t size, uint64_t options) {
    bulk_calls++;
    if (!strcmp(mode, "unsupported")) { errno = ENOTSUP; return -1; }
    if (!strcmp(mode, "io")) { errno = EIO; return -1; }
    int count = getattrlistbulk(fd, attrs, buffer, size, options);
    if (count > 0 && !strcmp(mode, "missing-attrs")) {
        uint8_t *bytes = buffer; size_t offset = 0;
        for (int i = 0; i < count; i++) {
            uint32_t length; attribute_set_t returned;
            memcpy(&length, bytes + offset, sizeof(length));
            memcpy(&returned, bytes + offset + sizeof(length), sizeof(returned));
            returned.commonattr &= ~(attrgroup_t)ATTR_CMN_FILEID;
            memcpy(bytes + offset + sizeof(length), &returned, sizeof(returned));
            offset += length;
        }
    }
    return count;
}

/* Constructs independent packed records and challenges the production parser's byte boundary. */
static void parser_checks(void) {
    uint8_t bytes[512] = {0}; NVRootMetadataEntry entries[64];
    NVMetadataBulkRecord valid = {0}; struct attrlist attrs = metadata_attributes();
    valid.length = 104; valid.returned.commonattr = attrs.commonattr; valid.returned.fileattr = attrs.fileattr;
    valid.name.attr_dataoffset = (int32_t)(sizeof(valid) - offsetof(NVMetadataBulkRecord, name));
    valid.name.attr_length = 5; valid.type = VREG; valid.device = 7; valid.inode = 9; valid.links = 1; valid.size = 3;
    valid.modified.tv_sec = 11; valid.modified.tv_nsec = 13; valid.changed.tv_sec = 17; valid.changed.tv_nsec = 19;
    memcpy(bytes, &valid, sizeof(valid)); memcpy(bytes + sizeof(valid), "name", 5);
    require(metadata_parse(bytes, sizeof(bytes), 1, entries) == 0, "Valid packed record passes");
    const uint64_t expected[9] = {1,7,9,3,1,11,13,17,19};
    require(entries[0].error == 0 && entries[0].refresh == 0 && !memcmp(entries[0].words, expected, sizeof(expected)), "Packed fields preserve all nine independently expected words");
    bytes[sizeof(valid)] = 255;
    require(metadata_parse(bytes, sizeof(bytes), 1, entries) == 0 && entries[0].name[0] == 255, "Parser preserves raw non-UTF8 bytes for its typed consumer");
    bytes[sizeof(valid)] = 'n';
    for (int change = 0; change < 14; change++) {
        NVMetadataBulkRecord altered = valid; uint8_t test[512]; memcpy(test, bytes, sizeof(test));
        switch (change) {
        case 0: altered.length = 0; break;
        case 1: altered.length = 103; break;
        case 2: altered.length = 520; break;
        case 3: altered.name.attr_dataoffset = -1; break;
        case 4: altered.name.attr_dataoffset = 0; break;
        case 5: altered.name.attr_dataoffset = INT32_MAX; break;
        case 6: altered.name.attr_length = 0; break;
        case 7: altered.name.attr_length = 257; break;
        case 8: altered.returned.commonattr &= ~(attrgroup_t)ATTR_CMN_NAME; break;
        case 9: altered.returned.commonattr &= ~(attrgroup_t)ATTR_CMN_ERROR; break;
        case 10: altered.error = UINT32_MAX; break;
        case 11: test[sizeof(valid) + 4] = 1; break;
        case 12: test[sizeof(valid) + 1] = 0; break;
        case 13: test[sizeof(valid) + 1] = '/'; break;
        }
        memcpy(test, &altered, sizeof(altered));
        require(metadata_parse(test, sizeof(test), 1, entries) == -1, "Malformed packed record is rejected");
    }
    require(metadata_parse(bytes, sizeof(valid) - 1, 1, entries) == -1, "Truncated packed fields are rejected");
    require(metadata_parse(bytes, sizeof(bytes), 65, entries) == -1, "Oversized record count is rejected");
    for (int change = 0; change < 4; change++) {
        NVMetadataBulkRecord altered = valid;
        switch (change) {
        case 0: altered.returned.commonattr &= ~(attrgroup_t)ATTR_CMN_FILEID; break;
        case 1: altered.returned.fileattr &= ~(attrgroup_t)ATTR_FILE_LINKCOUNT; break;
        case 2: altered.modified.tv_nsec = 1000000000; break;
        case 3: altered.size = -1; break;
        }
        memcpy(bytes, &altered, sizeof(altered));
        require(metadata_parse(bytes, sizeof(bytes), 1, entries) == 0 && entries[0].refresh == 1, "Incomplete packed metadata requires a fresh stat");
    }
    valid.error = EACCES; memcpy(bytes, &valid, sizeof(valid));
    require(metadata_parse(bytes, sizeof(bytes), 1, entries) == 0 && entries[0].error == EACCES, "Per-entry errors retain their actual cause");
    /* Directory records carry their common fields and raw name before any file-specific fields. */
    valid.error = 0; valid.returned.fileattr = 0; valid.type = VDIR; valid.length = 96;
    valid.name.attr_dataoffset = (int32_t)(offsetof(NVMetadataBulkRecord, links) - offsetof(NVMetadataBulkRecord, name));
    memcpy(bytes, &valid, offsetof(NVMetadataBulkRecord, links)); memcpy(bytes + offsetof(NVMetadataBulkRecord, links), "name", 5);
    require(metadata_parse(bytes, sizeof(bytes), 1, entries) == 0 && entries[0].refresh == 1, "Directory-shaped records select stat fallback");
    uint32_t random = 0x91827;
    for (unsigned round = 0; round < 20000; round++) {
        for (unsigned index = 0; index < sizeof(bytes); index++) { random = random * 1664525U + 1013904223U; bytes[index] = (uint8_t)(random >> 24); }
        (void)metadata_parse(bytes, round % sizeof(bytes), round % 66, entries);
    }
    puts("PASS: packed parser valid, malformed, fallback and bounded fuzz cases");
}
#endif

/* The oracle uses stat directly and spells out the fingerprint fields separately. */
static void compare_stat(int fd, const NVRootMetadataEntry *entry) {
    struct stat st;
    require(fstatat(fd, (const char *)entry->name, &st, AT_SYMLINK_NOFOLLOW) == 0, "Oracle reads the disclosed physical entry");
    uint64_t expected[9] = {S_ISREG(st.st_mode) ? 1 : S_ISDIR(st.st_mode) ? 2 : S_ISLNK(st.st_mode) ? 3 : 4,
        (uint64_t)st.st_dev, (uint64_t)st.st_ino, (uint64_t)st.st_size, (uint64_t)st.st_nlink, 0,0,0,0};
#if defined(__APPLE__)
    expected[5] = (uint64_t)st.st_mtimespec.tv_sec; expected[6] = (uint64_t)st.st_mtimespec.tv_nsec;
    expected[7] = (uint64_t)st.st_ctimespec.tv_sec; expected[8] = (uint64_t)st.st_ctimespec.tv_nsec;
#else
    expected[5] = (uint64_t)st.st_mtim.tv_sec; expected[6] = (uint64_t)st.st_mtim.tv_nsec;
    expected[7] = (uint64_t)st.st_ctim.tv_sec; expected[8] = (uint64_t)st.st_ctim.tv_nsec;
#endif
    require(!memcmp(entry->words, expected, sizeof(expected)), "Metadata matches independent exact stat fields");
}

int main(int argc, char **argv) {
    require(argc == 4, "Arguments: root mode budget"); mode = argv[2];
#if defined(__APPLE__)
    if (!strcmp(mode, "parser")) { parser_checks(); return 0; }
#endif
    unsigned budget = (unsigned)strtoul(argv[3], NULL, 10);
    NVRootOwner *owner = nv_root_open(argv[1]); require(owner != NULL, "Acquire rooted owner");
    int portable = !strcmp(mode, "portable") || !strcmp(mode, "child-error");
    NVRootListing *listing = nv_root_metadata_open(owner, "NV Data/v1/keys", portable);
    require(listing != NULL, "Acquire held metadata directory");
    unsigned seen = 0, failed = 0, rounds = 0, stats = 0; int finished = 0;
    while (!finished) {
        NVRootMetadataEntry entries[64]; NVRootMetadataTurn turn;
        int result = nv_root_metadata_next(owner, listing, budget, entries, &turn);
        if (!strcmp(mode, "ancestor")) {
            require(result == -1 && errno == ESTALE && event_count == 1, "Ancestor replacement prevents issuing batch evidence");
            break;
        }
#if defined(__APPLE__)
        if (!strcmp(mode, "io")) { require(result == -1 && errno == EIO && bulk_calls == 1, "I/O failure retains failure meaning"); break; }
#endif
        require(result == 0 && turn.count <= 64 && turn.ancestor_checks == 2, "Bounded metadata completes both ownership checks");
        stats += turn.stat_calls;
        for (unsigned i = 0; i < turn.count; i++) {
            NVRootMetadataEntry *entry = &entries[i];
            require(entry->length > 0 && entry->length <= 255 && entry->name[entry->length] == 0, "Copied raw name stays bounded");
            if (entry->error) { require(!strcmp((char *)entry->name, "unavailable") && entry->error == EACCES, "Child failure preserves its exact cause"); failed++; }
            else compare_stat(dirfd(listing->stream), entry);
            printf("LEAF ");
            for (unsigned j = 0; j < entry->length; j++) printf("%02x", entry->name[j]);
            printf(" %d\n", entry->error); seen++;
        }
        finished = turn.finished; require(++rounds < 1000, "Enumeration makes bounded progress");
    }
    if (!strcmp(mode, "unsupported")) require(bulk_calls == 1 && stats == seen, "Capability fallback switches once to a separate portable stream");
    if (!strcmp(mode, "missing-attrs")) require(stats == seen, "Missing attributes obtain fresh per-entry observations");
    if (!strcmp(mode, "child-error")) require(failed == 1, "One inaccessible leaf preserves readable siblings");
    nv_root_list_close(listing); nv_root_close(owner);
    printf("PASS: metadata mode=%s seen=%u stats=%u bulk=%d\n", mode, seen, stats, bulk_calls);
    return 0;
}
