#if defined(__linux__) && !defined(_XOPEN_SOURCE)
#define _XOPEN_SOURCE 700
#endif

#include "NVStorageIO.h"
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

struct NVStorageOwner { int directory, file; char *path, *database; };
int nv_storage_owner_validate(NVStorageOwner *o) {
    struct stat directory, named, file, namedFile;
    if (fstat(o->directory, &directory) || lstat(o->path, &named) ||
        fstat(o->file, &file) || fstatat(o->directory, "Collection.sqlite", &namedFile, AT_SYMLINK_NOFOLLOW)) return -1;
    if (!S_ISDIR(named.st_mode) || !S_ISREG(namedFile.st_mode) ||
        directory.st_dev != named.st_dev || directory.st_ino != named.st_ino ||
        file.st_dev != namedFile.st_dev || file.st_ino != namedFile.st_ino || namedFile.st_nlink != 1) {
        errno = ESTALE; return -1;
    }
    return 0;
}
NVStorageOwner *nv_storage_owner_open(const char *path, int create) {
    if (create && mkdir(path, 0700)) return NULL;
    NVStorageOwner *o = calloc(1, sizeof(*o));
    if (!o) return NULL;
    o->directory = -1; o->file = -1;
    o->path = realpath(path, NULL);
    struct stat named;
    if (!o->path || lstat(path, &named) || !S_ISDIR(named.st_mode)) { errno = EINVAL; goto fail; }
    o->directory = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (o->directory < 0 || flock(o->directory, LOCK_EX | LOCK_NB)) goto fail;
    o->file = openat(o->directory, "Collection.sqlite", O_RDWR | O_NOFOLLOW | O_CLOEXEC |
        (create ? O_CREAT | O_EXCL : 0), 0600);
    if (o->file < 0) goto fail;
    size_t n = strlen(o->path) + sizeof("/Collection.sqlite");
    o->database = malloc(n);
    if (!o->database) goto fail;
    strcpy(o->database, o->path); strcat(o->database, "/Collection.sqlite");
    if (nv_storage_owner_validate(o)) goto fail;
    if (create) {
        int parent = openat(o->directory, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        if (parent < 0) goto fail;
        int result = fsync(o->file) || fsync(o->directory) || fsync(parent);
        int saved = errno; close(parent); errno = saved;
        if (result) goto fail;
    }
    return o;
fail:;
    int saved = errno; nv_storage_owner_close(o); errno = saved; return NULL;
}
const char *nv_storage_owner_database(NVStorageOwner *o) { return o->database; }
void nv_storage_owner_close(NVStorageOwner *o) {
    if (!o) return;
    if (o->file >= 0) close(o->file);
    if (o->directory >= 0) close(o->directory);
    free(o->path); free(o->database); free(o);
}
