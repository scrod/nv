/* Exercises abrupt process exit at each native creation boundary and exact retry. */
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include "../NVStorage/Sources/CStorageIO/NVRepositoryRoot.c"
#include "../NVStorage/Sources/CStorageIO/NVRepositoryFiles.c"

static const char *interrupt_at;
static void interrupt_creation(const char *event) {
    if (interrupt_at && !strcmp(interrupt_at, event)) _exit(77);
}
#define NV_PROJECTION_EVENT(name, fd) interrupt_creation(name)
#include "../NVStorage/Sources/CStorageIO/NVProjectionFiles.c"

static void inspect_body(int directory, const char *name, const char *expected) {
    int fd = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW); assert(fd >= 0);
    char bytes[32] = {0};
    ssize_t count = read(fd, bytes, sizeof(bytes));
    assert(count == (ssize_t)strlen(expected) && !memcmp(bytes, expected, (size_t)count));
    assert(close(fd) == 0);
}

static void inspect_metadata(int directory) {
    int fd = openat(directory, "Note.txt", O_RDONLY | O_CLOEXEC | O_NOFOLLOW); assert(fd >= 0);
    struct stat info; assert(fstat(fd, &info) == 0);
    assert(S_ISREG(info.st_mode) && info.st_nlink == 1 && (info.st_mode & 0777) == 0600);
    char encoding[32];
#if defined(__APPLE__)
    ssize_t count = fgetxattr(fd, "com.apple.TextEncoding", encoding, sizeof(encoding), 0, 0);
    struct statfs filesystem; assert(fstatfs(fd, &filesystem) == 0);
    long nanoseconds = strcmp(filesystem.f_fstypename, "hfs") ? 234567890 : 0;
    assert(info.st_mtimespec.tv_sec == 1700000003 && info.st_mtimespec.tv_nsec == nanoseconds);
    assert(fgetxattr(fd, "com.apple.metadata:kMDItemOMUserTags", encoding, 0, 0, 0) == 0);
#else
    ssize_t count = fgetxattr(fd, "user.com.apple.TextEncoding", encoding, sizeof(encoding));
    assert(info.st_mtim.tv_sec == 1700000003 && info.st_mtim.tv_nsec == 234567890);
    assert(fgetxattr(fd, "user.com.apple.metadata:kMDItemOMUserTags", encoding, 0) == 0);
#endif
    assert(count == 15 && !memcmp(encoding, "UTF-8;134217984", 15));
    assert(close(fd) == 0);
}

int main(int argc, char **argv) {
    assert(argc == 2 && mkdir(argv[1], 0700) == 0);
    const char *events[] = {"stage-created", "stage-prepared", "projection-installed", "projection-final-check", NULL};
    const uint8_t encoding[] = "UTF-8;134217984", contents[] = "desired";
    const NVProjectionMetadata metadata = {
        .encoding = {encoding, sizeof(encoding) - 1, 1}, .tags = {NULL, 0, 1},
        .permissions = 0600, .modified_seconds = 1700000003, .modified_nanoseconds = 234567890
    };
    for (unsigned scenario = 0; scenario < sizeof(events) / sizeof(events[0]); scenario++) {
        char root[1024], private[1024];
        assert(snprintf(root, sizeof(root), "%s/root-%u", argv[1], scenario) > 0);
        assert(snprintf(private, sizeof(private), "%s/private-%u", argv[1], scenario) > 0);
        assert(mkdir(root, 0700) == 0 && mkdir(private, 0700) == 0);
        int completion[2]; assert(pipe(completion) == 0);
        pid_t child = fork(); assert(child >= 0);
        if (!child) {
            close(completion[0]); interrupt_at = events[scenario];
            NVRootOwner *owner = nv_root_open(root); assert(owner);
            int staging = open(private, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); assert(staging >= 0);
            NVProjectionEffect effect;
            NVProjectionStage *stage = nv_projection_prepare(owner, staging, "initial", contents, sizeof(contents) - 1, &metadata, &effect);
            assert(stage && effect.outcome == NV_PROJECTION_STAGED);
            nv_projection_create(owner, stage, "Note.txt", contents, sizeof(contents) - 1, &metadata, &effect);
            assert(effect.outcome == NV_PROJECTION_INSTALLED);
            assert(write(completion[1], "ack", 3) == 3);
            _exit(0);
        }
        close(completion[1]);
        int status; assert(waitpid(child, &status, 0) == child);
        assert(WIFEXITED(status) && WEXITSTATUS(status) == (events[scenario] ? 77 : 0));
        char acknowledgment[4] = {0};
        assert(read(completion[0], acknowledgment, sizeof(acknowledgment)) == (events[scenario] ? 0 : 3));
        close(completion[0]);

        // Fresh descriptors classify the surviving namespace before a separate retry.
        NVRootOwner *owner = nv_root_open(root); assert(owner);
        int staging = open(private, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); assert(staging >= 0);
        int installed = scenario >= 2;
        if (installed) {
            inspect_body(owner->directory, "Note.txt", "desired"); inspect_metadata(owner->directory);
            assert(faccessat(staging, "initial", F_OK, 0) < 0 && errno == ENOENT);
        } else {
            inspect_body(staging, "initial", scenario == 0 ? "" : "desired");
            assert(faccessat(owner->directory, "Note.txt", F_OK, 0) < 0 && errno == ENOENT);
        }
        NVProjectionEffect effect;
        NVProjectionStage *retry = nv_projection_prepare(owner, staging, "retry", contents, sizeof(contents) - 1, &metadata, &effect);
        assert(retry && effect.outcome == NV_PROJECTION_STAGED);
        nv_projection_create(owner, retry, "Note.txt", contents, sizeof(contents) - 1, &metadata, &effect);
        assert(effect.outcome == (installed ? NV_PROJECTION_STAGED : NV_PROJECTION_INSTALLED));
        assert(effect.error == (installed ? EEXIST : 0));
        inspect_body(owner->directory, "Note.txt", "desired"); inspect_metadata(owner->directory);
        if (installed) inspect_body(staging, "retry", "desired");
        else inspect_body(staging, "initial", scenario == 0 ? "" : "desired");
        nv_projection_stage_close(retry); close(staging); nv_root_close(owner);
    }
    puts("PASS: projection creation 4 abrupt exits and 1 acknowledged companion; exact retry preserves occupied names");
    return 0;
}
