/* Measures bounded metadata batches using the production listing's held parents. */
#include <sys/attr.h>
#include <sys/vnode.h>
#include <time.h>
#include <stddef.h>
#include "../NVStorage/Sources/CStorageIO/NVRepositoryFiles.c"

typedef struct { char name[256]; uint64_t words[9]; } Entry;
static Entry *inventory;
static unsigned char *seen;
static size_t inventory_count, emitted;
static int verifying;

static void require(int value, const char *message) {
    if (!value) { perror(message); exit(2); }
}
static double now(void) {
    struct timespec value; require(clock_gettime(CLOCK_MONOTONIC, &value) == 0, "clock");
    return value.tv_sec + value.tv_nsec / 1e9;
}
static int compare(const void *a, const void *b) { return strcmp(((const Entry *)a)->name, ((const Entry *)b)->name); }
static void emit(const char *name, const uint64_t words[9]) {
    emitted++;
    if (verifying) {
        Entry key = {0}; require(strlen(name) < sizeof(key.name), "leaf width"); strcpy(key.name, name);
        Entry *expected = bsearch(&key, inventory, inventory_count, sizeof(Entry), compare);
        require(expected && memcmp(expected->words, words, sizeof(expected->words)) == 0, "exact nine-word inventory");
        size_t index = (size_t)(expected - inventory);
        require(!seen[index], "unique observed leaf"); seen[index] = 1;
    }
}
static void full(NVRootOwner *owner, const char *relative, unsigned budget) {
    NVRootListing *listing = nv_root_list_open(owner, relative); require(listing != NULL, "full listing");
    int finished = 0;
    while (!finished) {
        uint8_t buffer[256 * 257]; unsigned used;
        require(nv_root_list_next(owner, listing, budget, buffer, sizeof(buffer), &used, &finished) == 0, "full next");
        for (unsigned offset = 0; offset < used;) {
            unsigned length = buffer[offset++]; char leaf[256], path[1537];
            require(length && length <= used - offset, "full name");
            memcpy(leaf, buffer + offset, length); leaf[length] = 0; offset += length;
            require(snprintf(path, sizeof(path), "%s/%s", relative, leaf) < (int)sizeof(path), "relative width");
            uint64_t words[9]; require(nv_root_snapshot(owner, path, words) == 0, "full observation"); emit(leaf, words);
        }
    }
    nv_root_list_close(listing);
}
static void held(NVRootOwner *owner, const char *relative, unsigned budget) {
    NVRootListing *listing = nv_root_list_open(owner, relative); require(listing != NULL, "held listing");
    int finished = 0;
    while (!finished) {
        require(listing_check(owner, listing) == 0, "held before");
        for (unsigned i = 0; i < budget; i++) {
            errno = 0; struct dirent *entry = readdir(listing->stream);
            if (!entry) { require(errno == 0, "held next"); finished = 1; break; }
            if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
            struct stat value; uint64_t words[9];
            require(fstatat(dirfd(listing->stream), entry->d_name, &value, AT_SYMLINK_NOFOLLOW) == 0, "held stat");
            file_words(&value, words); emit(entry->d_name, words);
        }
        require(listing_check(owner, listing) == 0, "held after");
    }
    nv_root_list_close(listing);
}
typedef struct __attribute__((packed, aligned(4))) {
    uint32_t length; attribute_set_t returned; uint32_t error; attrreference_t name;
    dev_t device; fsobj_type_t type; struct timespec modified, changed; uint64_t inode;
    uint32_t links; off_t size;
} BulkRecord;
static void bulk(NVRootOwner *owner, const char *relative, unsigned budget) {
    NVRootListing *listing = nv_root_list_open(owner, relative); require(listing != NULL, "bulk listing");
    struct attrlist requested = {0}; requested.bitmapcount = ATTR_BIT_MAP_COUNT;
    requested.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_ERROR | ATTR_CMN_NAME | ATTR_CMN_DEVID |
        ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_CHGTIME | ATTR_CMN_FILEID;
    requested.fileattr = ATTR_FILE_LINKCOUNT | ATTR_FILE_DATALENGTH;
    uint8_t buffer[64 * 1024];
    /* A complete packed record needs its fixed fields and at least four name bytes. */
    size_t capacity = budget * (sizeof(BulkRecord) + 4);
    require(capacity <= sizeof(buffer), "bulk capacity");
    for (;;) {
        require(listing_check(owner, listing) == 0, "bulk before");
        int count = getattrlistbulk(dirfd(listing->stream), &requested, buffer, capacity, FSOPT_PACK_INVAL_ATTRS);
        require(count >= 0 && (unsigned)count <= budget, "bulk count");
        size_t offset = 0;
        for (int i = 0; i < count; i++) {
            require(offset + sizeof(BulkRecord) <= capacity, "bulk fixed width");
            BulkRecord record; memcpy(&record, buffer + offset, sizeof(record));
            require(record.length >= sizeof(record) && record.length <= capacity - offset && record.error == 0, "bulk record");
            require((record.returned.commonattr & requested.commonattr) == requested.commonattr &&
                (record.returned.fileattr & requested.fileattr) == requested.fileattr && record.type == VREG, "bulk attributes");
            require(record.name.attr_dataoffset >= 0 && record.name.attr_length > 1, "bulk name reference");
            size_t start = offsetof(BulkRecord, name) + (size_t)record.name.attr_dataoffset;
            require(start >= sizeof(record) && start <= record.length && record.name.attr_length <= record.length - start, "bulk name bounds");
            const char *name = (const char *)buffer + offset + start;
            require(name[record.name.attr_length - 1] == 0 && strlen(name) + 1 == record.name.attr_length, "bulk name termination");
            uint64_t words[9] = {1, (uint64_t)record.device, record.inode, (uint64_t)record.size, record.links,
                (uint64_t)record.modified.tv_sec, (uint64_t)record.modified.tv_nsec,
                (uint64_t)record.changed.tv_sec, (uint64_t)record.changed.tv_nsec};
            emit(name, words); offset += record.length;
        }
        require(listing_check(owner, listing) == 0, "bulk after");
        if (!count) break;
    }
    nv_root_list_close(listing);
}
int main(int argc, char **argv) {
    require(argc == 4, "usage: ROOT WRITER_RELATIVE REPETITIONS");
    int repetitions = atoi(argv[3]); require(repetitions >= 3 && repetitions <= 100, "repetitions");
    NVRootOwner *owner = nv_root_open(argv[1]); require(owner != NULL, "root owner");
    NVRootListing *listing = nv_root_list_open(owner, argv[2]); require(listing != NULL, "inventory listing");
    struct dirent *entry;
    while ((entry = readdir(listing->stream))) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        Entry value = {0}; char path[1537];
        require(strlen(entry->d_name) < sizeof(value.name), "inventory name"); strcpy(value.name, entry->d_name);
        require(snprintf(path, sizeof(path), "%s/%s", argv[2], value.name) < (int)sizeof(path), "inventory path");
        require(nv_root_snapshot(owner, path, value.words) == 0 && value.words[0] == 1, "inventory observation");
        Entry *grown = realloc(inventory, (inventory_count + 1) * sizeof(Entry)); require(grown != NULL, "inventory allocation");
        inventory = grown; inventory[inventory_count++] = value;
    }
    nv_root_list_close(listing); require(inventory_count > 0, "nonempty inventory");
    qsort(inventory, inventory_count, sizeof(Entry), compare);
    seen = calloc(inventory_count, 1); require(seen != NULL, "inventory coverage");
    const char *names[] = {"production-16", "held-stat-16", "bulk-exact-16", "held-stat-64", "bulk-exact-64", "bulk-exact-256"};
    void (*functions[])(NVRootOwner *, const char *, unsigned) = {full, held, bulk, held, bulk, bulk};
    unsigned budgets[] = {16, 16, 16, 64, 64, 256};
    printf("{\"files\":%zu,\"exactObservationWords\":9,\"samplesMilliseconds\":{", inventory_count);
    for (unsigned variant = 0; variant < 6; variant++) {
        verifying = 1; emitted = 0; memset(seen, 0, inventory_count); functions[variant](owner, argv[2], budgets[variant]);
        require(emitted == inventory_count, "verified count"); verifying = 0;
        printf("%s\"%s\":[", variant ? "," : "", names[variant]);
        for (int round = 0; round < repetitions; round++) {
            emitted = 0; double start = now(); functions[variant](owner, argv[2], budgets[variant]); double elapsed = now() - start;
            require(emitted == inventory_count, "timed count"); printf("%s%.6f", round ? "," : "", elapsed * 1000);
        }
        printf("]");
    }
    printf("}}\n"); nv_root_close(owner); free(inventory); free(seen);
}
