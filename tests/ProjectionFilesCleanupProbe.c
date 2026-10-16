/* Checks the production owned-artifact cleanup after a real source quarantine. */
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <sys/wait.h>
#include <unistd.h>
#if defined(__linux__)
#include <sys/syscall.h>
#else
#include <membership.h>
#endif
#include "../NVStorage/Sources/CStorageIO/NVRepositoryRoot.c"
#include "../NVStorage/Sources/CStorageIO/NVRepositoryFiles.c"

enum { NORMAL, EMPTY, CHANGED_BODY, CHANGED_TAGS, CHANGED_MODE, ABSENT, DIRECTORY,
    SYMLINK, HARDLINK, FOREIGN_DESCRIPTOR, INVALID_DESCRIPTOR, LAST_NAME,
    ERROR_BEFORE, ERROR_AFTER, NO_SPACE, NEW_ARTIFACT, OBSERVATION_ERROR,
    SYNC_ERROR, ROOT_MOVED, ROOT_LOST, ROOT_LOST_LATE, NEW_SOURCE,
#if defined(NV_PROJECTION_COORDINATED) && defined(__APPLE__)
    COORD_REDIRECT, COORD_FAIL_BEFORE, COORD_FAIL_AFTER, COORD_DEST_REDIRECT,
#endif
    LAST_UNLINK_REPLACEMENT, CAPTURE_REPLACEMENT_OCCUPIED, PRIVATE_COLLISION, PRIVATE_SYMLINK,
    CAPTURE_EDIT, PUBLIC_REAPPEARS_AT_UNLINK, SYNC_BEFORE_CAPTURE, SYNC_AFTER_CAPTURE, PRIVATE_DIRECTORY_REPLACED,
    ROOT_LOST_AFTER_UNLINK, NEW_PRIVATE_ARTIFACT,
    CASE_COUNT };
static int scenario, root_fd, unlink_calls, final_error, cleanup, captured;
static const char *crash_at;
static char root_path[4096], moved_path[4096];
#define Require(v) do { if (!(v)) { fprintf(stderr,"cleanup case %d line %d: %s (errno %d)\n",scenario,__LINE__,#v,errno); abort(); } } while (0)
static void Create(const char *leaf, const char *body) {
    int fd = openat(root_fd, leaf, O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600); Require(fd>=0);
    size_t n=strlen(body); Require(write(fd,body,n)==(ssize_t)n && close(fd)==0);
}
static void Body(const char *leaf, const char *body) {
    int fd=openat(root_fd,leaf,O_RDONLY|O_NOFOLLOW|O_CLOEXEC); Require(fd>=0);
    char bytes[64]; ssize_t n=pread(fd,bytes,sizeof(bytes),0);
    Require(n==(ssize_t)strlen(body) && !memcmp(bytes,body,(size_t)n)); Require(close(fd)==0);
}
/* Reads named fixture files independently, including a future owned recovery directory. */
static int ContainsBody(int directory, const char *body, int depth) {
    int copy=dup(directory); Require(copy>=0);
    DIR *entries=fdopendir(copy); Require(entries);
    rewinddir(entries);
    int found=0; struct dirent *entry;
    while (!found && (entry=readdir(entries))) {
        if (!strcmp(entry->d_name,".") || !strcmp(entry->d_name,"..")) continue;
        int fd=openat(directory,entry->d_name,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);
        if (fd<0) continue;
        struct stat st; Require(fstat(fd,&st)==0);
        if (S_ISREG(st.st_mode)) {
            char bytes[64]; ssize_t count=pread(fd,bytes,sizeof(bytes),0);
            found=count==(ssize_t)strlen(body) && !memcmp(bytes,body,(size_t)count);
        } else if (S_ISDIR(st.st_mode) && depth>0) found=ContainsBody(fd,body,depth-1);
        Require(close(fd)==0);
    }
    Require(closedir(entries)==0); return found;
}
static void Tags(const char *value) {
    int fd=openat(root_fd,"recovery",O_RDONLY|O_CLOEXEC); Require(fd>=0);
#if defined(__APPLE__)
    Require(fsetxattr(fd,"com.apple.metadata:kMDItemOMUserTags",value,strlen(value),0,0)==0);
#else
    Require(fsetxattr(fd,"user.com.apple.metadata:kMDItemOMUserTags",value,strlen(value),0)==0);
#endif
    Require(close(fd)==0);
}
static NVRootOwner *current;
static void Event(const char *name, int fd) {
    (void)fd;
    if (crash_at && !strcmp(crash_at,name)) _exit(71);
    if (!strcmp(name,"source-cleanup-checked")) {
        if (scenario==LAST_NAME) { Require(renameat(root_fd,"recovery",root_fd,"preserved")==0); Create("recovery","concurrent"); }
        if (scenario==ROOT_LOST_LATE) current->invalidated=1;
        if (scenario==ROOT_MOVED) {
            Require(rename(root_path,moved_path)==0 && mkdir(root_path,0700)==0);
            int held=root_fd; root_fd=open(root_path,O_RDONLY|O_DIRECTORY|O_CLOEXEC); Require(root_fd>=0);
            Create("recovery","foreign"); Require(close(root_fd)==0); root_fd=held;
        }
    }
    if (!strcmp(name,"source-cleanup-unlinked") && scenario==NEW_ARTIFACT) Create("recovery","concurrent");
    if (!strcmp(name,"source-cleanup-unlinked") && scenario==ROOT_LOST_AFTER_UNLINK) current->invalidated=1;
    if (!strcmp(name,"source-cleanup-unlinked") && scenario==NEW_PRIVATE_ARTIFACT) Create("recovery.cleanup/item","new private");
    if (!strcmp(name,"source-cleanup-captured") && scenario==CAPTURE_REPLACEMENT_OCCUPIED) Create("recovery","new public");
    if (!strcmp(name,"source-cleanup-captured")) {
        captured=1;
        if (scenario==PRIVATE_DIRECTORY_REPLACED) {
            Require(renameat(root_fd,"recovery.cleanup",root_fd,"retained-directory")==0);
            Require(mkdirat(root_fd,"recovery.cleanup",0700)==0);
            Create("recovery.cleanup/foreign","foreign child");
        }
    }
    if (!strcmp(name,"source-cleanup-final") && scenario==OBSERVATION_ERROR) final_error=1;
}
/* The competing process replaces the public recovery leaf at its actual capture boundary. */
static void ReplacePublicArtifact(void) {
        pid_t child=fork(); Require(child>=0);
        if (!child) {
            if (renameat(root_fd,"recovery",root_fd,"last-original")) _exit(91);
            int fd=openat(root_fd,"recovery",O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0600);
            if (fd<0 || write(fd,"concurrent",10)!=10 || close(fd)) _exit(92);
            _exit(0);
        }
        int status=0; pid_t waited;
        do { waited=waitpid(child,&status,0); } while (waited<0 && errno==EINTR);
        Require(waited==child && WIFEXITED(status) && WEXITSTATUS(status)==0);
}
static int Capture(int from,const char *source,int to,const char *destination) {
    if (scenario==LAST_UNLINK_REPLACEMENT || scenario==CAPTURE_REPLACEMENT_OCCUPIED) ReplacePublicArtifact();
    if (scenario==CAPTURE_EDIT) {
        int fd=openat(root_fd,"recovery",O_WRONLY|O_CLOEXEC); Require(fd>=0);
        Require(pwrite(fd,"modified",8,0)==8 && close(fd)==0);
    }
#if defined(__APPLE__)
    return renameatx_np(from,source,to,destination,RENAME_EXCL);
#else
    return (int)syscall(SYS_renameat2,from,source,to,destination,1U);
#endif
}
static int Unlink(int directory,const char *leaf,int flags) {
    unlink_calls++;
    if (scenario==PUBLIC_REAPPEARS_AT_UNLINK) Create("recovery","concurrent");
    if (scenario==ERROR_BEFORE || scenario==NO_SPACE) { errno=scenario==NO_SPACE?ENOSPC:EIO; return -1; }
    int result=unlinkat(directory,leaf,flags);
    if (!result && scenario==ERROR_AFTER) { errno=EIO; return -1; }
    return result;
}
static int Observe(int directory,const char *leaf,struct stat *st,int flags) {
    if (final_error && !strcmp(leaf,"recovery")) { final_error=0; errno=EACCES; return -1; }
    return fstatat(directory,leaf,st,flags);
}
static int Synchronize(int fd) {
    if (cleanup && ((unlink_calls && scenario==SYNC_ERROR) || scenario==SYNC_BEFORE_CAPTURE ||
        (captured && scenario==SYNC_AFTER_CAPTURE))) { errno=EIO; return -1; }
    return fsync(fd);
}
#define NV_PROJECTION_EVENT(name,fd) Event(name,fd)
#define NV_PROJECTION_CLEANUP_UNLINK Unlink
#define NV_PROJECTION_CLEANUP_CAPTURE Capture
#define fstatat Observe
#define fsync Synchronize
#ifndef NV_PROJECTION_SOURCE
#define NV_PROJECTION_SOURCE "../NVStorage/Sources/CStorageIO/NVProjectionFiles.c"
#endif
#include NV_PROJECTION_SOURCE
#undef fstatat
#undef fsync

#if defined(NV_PROJECTION_COORDINATED) && defined(__APPLE__)
#ifndef NV_PROJECTION_APPLE_SOURCE
#define NV_PROJECTION_APPLE_SOURCE "../NVStorage/Sources/CAppleFileAccess/NVAppleProjectionReplacement.m"
#endif
#import NV_PROJECTION_APPLE_SOURCE
@interface CleanupCoordinator : NSFileCoordinator
@end
@implementation CleanupCoordinator
- (void)coordinateWritingItemAtURL:(NSURL *)url options:(NSFileCoordinatorWritingOptions)options
    writingItemAtURL:(NSURL *)to options:(NSFileCoordinatorWritingOptions)toOptions error:(NSError **)error
    byAccessor:(void (NS_NOESCAPE ^)(NSURL *,NSURL *))writer {
    Require(options==NSFileCoordinatorWritingForDeleting && toOptions==0);
    Require([url.lastPathComponent isEqualToString:@"recovery"]);
    Require([to.lastPathComponent isEqualToString:@"item"] && [to.URLByDeletingLastPathComponent.lastPathComponent isEqualToString:@"recovery.cleanup"]);
    if (scenario==COORD_REDIRECT || scenario==COORD_DEST_REDIRECT) {
        [super coordinateWritingItemAtURL:url options:options writingItemAtURL:to options:toOptions error:error
            byAccessor:^(NSURL *actual,NSURL *destination) {
                writer(scenario==COORD_REDIRECT ? [actual.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"redirected"] : actual,
                       scenario==COORD_DEST_REDIRECT ? [destination.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"redirected"] : destination);
            }];
        return;
    }
    if (scenario==COORD_FAIL_BEFORE) { *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EACCES userInfo:nil]; return; }
    [super coordinateWritingItemAtURL:url options:options writingItemAtURL:to options:toOptions error:error byAccessor:writer];
    if (*error) fprintf(stderr,"cleanup coordination: %s\n",(*error).description.UTF8String);
    if (scenario==COORD_FAIL_AFTER) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:nil];
}
@end
static void Cleanup(NVRootOwner *owner,const NVProjectionRead *read,int descriptor,NVProjectionCleanupResult *result) {
    @autoreleasepool {
        NSURL *base=[[NSURL fileURLWithPath:[NSString stringWithUTF8String:root_path] isDirectory:YES] fileReferenceURL]; Require(base);
        NVAppleRemoveProjectionSource([[CleanupCoordinator alloc] initWithFilePresenter:nil],(__bridge CFURLRef)base,
            owner,"recovery","recovery",read,1024,descriptor,result);
    }
}
#else
static void Cleanup(NVRootOwner *owner,const NVProjectionRead *read,int descriptor,NVProjectionCleanupResult *result) {
    nv_projection_remove_source(owner,"recovery","recovery",read,1024,descriptor,result);
}
#endif

/* An inherited owner ACL makes privacy stripping observable independently of mode bits. */
static void InheritableACL(int directory) {
#if defined(__APPLE__)
    acl_t acl=acl_init(1); Require(acl);
    acl_entry_t entry; uuid_t identity;
    Require(mbr_uid_to_uuid(geteuid(),identity)==0 && acl_create_entry(&acl,&entry)==0);
    Require(acl_set_tag_type(entry,ACL_EXTENDED_ALLOW)==0 && acl_set_qualifier(entry,identity)==0);
    acl_permset_t permissions; acl_flagset_t flags;
    Require(acl_get_permset(entry,&permissions)==0 && acl_add_perm(permissions,ACL_READ_DATA)==0);
    Require(acl_get_flagset_np(entry,&flags)==0 && acl_add_flag_np(flags,ACL_ENTRY_DIRECTORY_INHERIT)==0);
    Require(acl_set_fd(directory,acl)==0 && acl_free(acl)==0);
#else
    (void)directory;
#endif
}
static void PrivateDirectory(int root) {
    int directory=openat(root,"recovery.cleanup",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC); Require(directory>=0);
    struct stat st; Require(fstat(directory,&st)==0 && (st.st_mode&0777)==0700 && st.st_uid==geteuid());
#if defined(__APPLE__)
    acl_t acl=acl_get_fd_np(directory,ACL_TYPE_EXTENDED); Require(acl || errno==ENOENT);
    if (acl) {
        acl_entry_t entry;
        Require(acl_get_entry(acl,ACL_FIRST_ENTRY,&entry)==-1 && errno==EINVAL);
        Require(acl_free(acl)==0);
    }
#endif
    Require(close(directory)==0);
}

int main(int argc,char **argv) {
    Require(argc==2 || argc==3); Require(mkdir(argv[1],0700)==0); crash_at=argc==3?argv[2]:NULL;
    int boundary=argc==3 && !strcmp(argv[2],"last-unlink-only"), companion=argc==3 && !strcmp(argv[2],"normal-only");
    int completed=0;
    for (scenario=boundary?LAST_UNLINK_REPLACEMENT:NORMAL;scenario<(companion?1:boundary?LAST_UNLINK_REPLACEMENT+1:CASE_COUNT);scenario++) {
        Require(snprintf(root_path,sizeof(root_path),"%s/case-%d",argv[1],scenario)>0);
        Require(snprintf(moved_path,sizeof(moved_path),"%s/moved-%d",argv[1],scenario)>0);
        Require(mkdir(root_path,0700)==0);
        NVRootOwner *owner=nv_root_open(root_path); Require(owner); current=owner; root_fd=owner->directory;
        if (scenario==NORMAL) InheritableACL(root_fd);
        cleanup=0; unlink_calls=0; final_error=0; captured=0;
        const char *body=scenario==EMPTY?"":"original"; Create("Note.txt",body);
        uint64_t words[9]; Require(nv_root_snapshot(owner,"Note.txt",words)==0);
        NVProjectionRead *original=NULL,*read=NULL; int descriptor=-1,foreign=-1;
        Require(nv_projection_read_retaining(owner,"Note.txt",words,1024,&original,&descriptor)==0);
        NVProjectionSourceResult moved;
        nv_projection_quarantine_source(owner,"Note.txt","recovery",original,1024,descriptor,NULL,NULL,&moved);
        Require(moved.outcome==NV_PROJECTION_SOURCE_CAPTURED);
        Require(nv_root_snapshot(owner,"recovery",words)==0 && nv_projection_read(owner,"recovery",words,1024,&read)==0);
        if (scenario==CHANGED_BODY) {
            int fd=openat(root_fd,"recovery",O_WRONLY|O_CLOEXEC); Require(fd>=0);
            Require(pwrite(fd,"modified",8,0)==8 && close(fd)==0);
        }
        if (scenario==CHANGED_TAGS) Tags("changed");
        if (scenario==CHANGED_MODE) { int fd=openat(root_fd,"recovery",O_RDONLY|O_CLOEXEC); Require(fd>=0 && fchmod(fd,0640)==0); close(fd); }
        if (scenario==CHANGED_BODY || scenario==CHANGED_TAGS || scenario==CHANGED_MODE) {
            /* Equal stat words isolate the complete captured-content/metadata comparison. */
            Require(nv_root_snapshot(owner,"recovery",read->words)==0);
        }
        if (scenario==ABSENT || scenario==DIRECTORY || scenario==SYMLINK) {
            Require(renameat(root_fd,"recovery",root_fd,"preserved")==0);
            if (scenario==DIRECTORY) Require(mkdirat(root_fd,"recovery",0700)==0);
            if (scenario==SYMLINK) Require(symlinkat("preserved",root_fd,"recovery")==0);
        }
        if (scenario==HARDLINK) Require(linkat(root_fd,"recovery",root_fd,"preserved",0)==0);
        if (scenario==FOREIGN_DESCRIPTOR) { Create("other","original"); foreign=openat(root_fd,"other",O_RDONLY|O_CLOEXEC); Require(foreign>=0); }
        if (scenario==NEW_SOURCE) Create("Note.txt","new source");
        if (scenario==PRIVATE_COLLISION) Require(mkdirat(root_fd,"recovery.cleanup",0700)==0);
        if (scenario==PRIVATE_SYMLINK) Require(symlinkat(".",root_fd,"recovery.cleanup")==0);
        if (scenario==ROOT_LOST) owner->invalidated=1;
        cleanup=1; NVProjectionCleanupResult result;
        Cleanup(owner,read,scenario==INVALID_DESCRIPTOR?-1:scenario==FOREIGN_DESCRIPTOR?foreign:descriptor,&result);
        Require(fcntl(descriptor,F_GETFD)>=0);
        if (scenario==LAST_UNLINK_REPLACEMENT || scenario==CAPTURE_REPLACEMENT_OCCUPIED) {
            int preserved=ContainsBody(root_fd,"concurrent",3);
            printf("OBSERVE: final-unlink replacement preserved=%d outcome=%d\n",preserved,result.outcome); fflush(stdout);
            Require(preserved);
            Body("last-original",body);
        }
        if (scenario==CAPTURE_EDIT) Require(ContainsBody(root_fd,"modified",3));
        int removed=scenario==NORMAL || scenario==EMPTY || scenario==SYNC_ERROR || scenario==ROOT_MOVED || scenario==NEW_SOURCE;
        int uncertain=scenario==ERROR_BEFORE || scenario==ERROR_AFTER || scenario==NO_SPACE || scenario==NEW_ARTIFACT || scenario==OBSERVATION_ERROR ||
            scenario==LAST_UNLINK_REPLACEMENT || scenario==CAPTURE_REPLACEMENT_OCCUPIED || scenario==CAPTURE_EDIT ||
            scenario==PUBLIC_REAPPEARS_AT_UNLINK || scenario==SYNC_AFTER_CAPTURE || scenario==PRIVATE_DIRECTORY_REPLACED ||
            scenario==ROOT_LOST_AFTER_UNLINK || scenario==NEW_PRIVATE_ARTIFACT;
#if defined(NV_PROJECTION_COORDINATED) && defined(__APPLE__)
        uncertain=uncertain || scenario==COORD_FAIL_AFTER;
#endif
        if ((result.outcome==NV_PROJECTION_CLEANUP_REMOVED)!=removed || (result.outcome==NV_PROJECTION_CLEANUP_UNCERTAIN)!=uncertain) {
            fprintf(stderr,"cleanup observed outcome=%d error=%d root=%d public=%d private=%d sync=%d\n",
                result.outcome,result.error,result.root_lost,result.artifact_state,result.captured_state,result.directory_sync_error);
        }
        Require((result.outcome==NV_PROJECTION_CLEANUP_REMOVED)==removed);
        Require((result.outcome==NV_PROJECTION_CLEANUP_UNCERTAIN)==uncertain);
        int attempted=removed || scenario==ERROR_BEFORE || scenario==ERROR_AFTER || scenario==NO_SPACE ||
            scenario==NEW_ARTIFACT || scenario==OBSERVATION_ERROR || scenario==PUBLIC_REAPPEARS_AT_UNLINK || scenario==ROOT_LOST_AFTER_UNLINK || scenario==NEW_PRIVATE_ARTIFACT;
#if defined(NV_PROJECTION_COORDINATED) && defined(__APPLE__)
        attempted=attempted || scenario==COORD_FAIL_AFTER;
#endif
        Require(unlink_calls==attempted);
        struct stat st;
        int private_present=fstatat(root_fd,"recovery.cleanup",&st,AT_SYMLINK_NOFOLLOW)==0;
        int owned_directory=private_present && scenario!=PRIVATE_COLLISION && scenario!=PRIVATE_SYMLINK;
        Require(result.directory_created==owned_directory);
        int gone=removed || scenario==ERROR_AFTER || scenario==OBSERVATION_ERROR || scenario==ROOT_LOST_AFTER_UNLINK || scenario==NEW_PRIVATE_ARTIFACT;
#if defined(NV_PROJECTION_COORDINATED) && defined(__APPLE__)
        gone=gone || scenario==COORD_FAIL_AFTER;
#endif
        if (gone) Require(fstatat(root_fd,"recovery",&st,AT_SYMLINK_NOFOLLOW)==-1 && errno==ENOENT);
        else if (scenario==ERROR_BEFORE || scenario==NO_SPACE || scenario==CAPTURE_REPLACEMENT_OCCUPIED || scenario==SYNC_AFTER_CAPTURE) {
            NVProjectionRead *retained=NULL;
            Require(nv_projection_read_cleanup(owner,"recovery",1024,&retained)==0);
            const char *value=scenario==CAPTURE_REPLACEMENT_OCCUPIED?"concurrent":body;
            Require(retained->count==strlen(value) && !memcmp(retained->bytes,value,(size_t)retained->count));
            nv_projection_read_close(retained);
            if (scenario==CAPTURE_REPLACEMENT_OCCUPIED) Body("recovery","new public");
        }
        else if (scenario==CAPTURE_EDIT) Body("recovery","modified");
        else if (scenario==PUBLIC_REAPPEARS_AT_UNLINK) Body("recovery","concurrent");
        else if (scenario==PRIVATE_DIRECTORY_REPLACED) {
            Body("retained-directory/item",body); Body("recovery.cleanup/foreign","foreign child");
        }
        else if (scenario==LAST_UNLINK_REPLACEMENT) Require(ContainsBody(root_fd,"concurrent",3));
        else if (scenario==LAST_NAME || scenario==NEW_ARTIFACT) Body("recovery","concurrent");
        else if (scenario==CHANGED_BODY) Body("recovery","modified");
        else if (scenario==ABSENT || scenario==DIRECTORY || scenario==SYMLINK) Body("preserved",body);
        else Body("recovery",body);
        if (scenario==LAST_NAME) Body("preserved",body);
        if (scenario==NEW_SOURCE) Body("Note.txt","new source");
        if (scenario==FOREIGN_DESCRIPTOR) Body("other","original");
        if (scenario==SYNC_ERROR) Require(result.directory_sync_error==EIO);
        if (scenario==OBSERVATION_ERROR) Require(result.artifact_state==NV_PROJECTION_NAME_UNAVAILABLE && result.error==EACCES);
        if (scenario==ROOT_LOST || scenario==ROOT_LOST_LATE || scenario==ROOT_LOST_AFTER_UNLINK) Require(result.root_lost);
        if (scenario==NORMAL) PrivateDirectory(root_fd);
        if (scenario==NEW_PRIVATE_ARTIFACT) Body("recovery.cleanup/item","new private");
        if (scenario==ROOT_MOVED) {
            int held=root_fd; root_fd=open(root_path,O_RDONLY|O_DIRECTORY|O_CLOEXEC); Require(root_fd>=0);
            Body("recovery","foreign"); close(root_fd); root_fd=held;
        }
        nv_projection_read_close(original); nv_projection_read_close(read);
        Require(close(descriptor)==0); if (foreign>=0) Require(close(foreign)==0); nv_root_close(owner);
        completed++;
    }
    printf("PASS: projection owned source cleanup %d native scenarios\n",completed); return 0;
}
