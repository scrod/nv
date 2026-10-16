/* Checks rename/update preservation through the production rooted and Foundation adapters. */
#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <errno.h>
#include <dirent.h>
#include "../NVStorage/Sources/CStorageIO/NVRepositoryRoot.c"
#include "../NVStorage/Sources/CStorageIO/NVRepositoryFiles.c"

enum { NORMAL, EMPTY, EQUAL_BODY, CASE_ONLY, CASE_ONLY_COLLISION, FORMAT_CHANGE, DESTINATION_OCCUPIED,
    BACKUP_OCCUPIED, SOURCE_CHANGED, SOURCE_METADATA, LATE_SOURCE_CHANGE,
    LATE_DESTINATION, RETURNED_SOURCE, RESTORE_COLLISION, STAGE_CHANGED, STAGE_CHANGED_CAPTURED,
    FINAL_DESTINATION, FINAL_METADATA, FINAL_BACKUP, ROOT_MOVED, ROOT_LOST,
    WRONG_STAGE, WRONG_EXPECTED, WRONG_STAGE_GRANT, BEFORE_INSTALL_ERROR,
    LOST_INSTALL_RETURN, CANCELLED, NORMALIZED_GRANTS, FOREIGN_SOURCE,
    FOREIGN_DESTINATION, STAGE_REFUSED, POST_ACCESSOR_ERROR, UNICODE_COMPOSED, UNICODE_DECOMPOSED,
    UNICODE_WRONG_LEAF, CASE_COUNT };
static int scenario, root_fd, installed, source_moves, staged_body;
static char root_path[2048], moved_path[2048];
static const char *destination, *crash_boundary;
#define Require(v) do { if (!(v)) { fprintf(stderr,"relocation %d line %d: %s (errno %d)\n",scenario,__LINE__,#v,errno); abort(); } } while (0)

static void Create(const char *name, const char *body) {
    int fd=openat(root_fd,name,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0640); Require(fd>=0);
    Require(fchmod(fd,0640)==0 && write(fd,body,strlen(body))==(ssize_t)strlen(body));
    Require(fsetxattr(fd,"org.notationalvelocity.test-unrelated","keep",4,0,0)==0);
    Require(close(fd)==0);
}
static void Body(const char *name,const char *body) {
    int fd=openat(root_fd,name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC); Require(fd>=0);
    char bytes[64]; ssize_t count=pread(fd,bytes,sizeof(bytes),0);
    Require(count==(ssize_t)strlen(body) && !memcmp(bytes,body,(size_t)count)); Require(close(fd)==0);
}
static int Present(const char *name) {
    struct stat st;
    if (!fstatat(root_fd,name,&st,AT_SYMLINK_NOFOLLOW)) return 1;
    Require(errno==ENOENT); return 0;
}
static void Event(const char *name,int fd) {
    if (crash_boundary && !strcmp(name,crash_boundary)) _exit(71);
    if (!strcmp(name,"source-before-quarantine") && scenario==LATE_SOURCE_CHANGE) {
        Require(renameat(root_fd,"Note.txt",root_fd,"saved-source")==0); Create("Note.txt","concurrent");
    }
    if (!strcmp(name,"relocation-captured")) {
        if (scenario==STAGE_CHANGED_CAPTURED) Require(pwrite(staged_body,"bad",3,0)==3);
        if (scenario==LATE_DESTINATION || scenario==RESTORE_COLLISION) Create(destination,"foreign");
        if (scenario==RETURNED_SOURCE || scenario==RESTORE_COLLISION || scenario==CASE_ONLY_COLLISION) Create("Note.txt","returned");
        if (scenario==ROOT_MOVED) {
            Require(rename(root_path,moved_path)==0 && mkdir(root_path,0700)==0);
            int held=root_fd; root_fd=open(root_path,O_RDONLY|O_DIRECTORY|O_CLOEXEC); Require(root_fd>=0);
            Create("Note.txt","foreign-root"); Require(close(root_fd)==0); root_fd=held;
        }
    }
    if (!strcmp(name,"projection-installed")) installed=1;
    if (!strcmp(name,"relocation-final")) {
        if (scenario==FINAL_DESTINATION) {
            Require(renameat(root_fd,destination,root_fd,"saved-output")==0); Create(destination,"concurrent");
        }
        if (scenario==FINAL_METADATA) {
            int target=openat(root_fd,destination,O_RDWR|O_NOFOLLOW|O_CLOEXEC); Require(target>=0);
            Require(fsetxattr(target,"com.apple.metadata:kMDItemOMUserTags","changed",7,0,0)==0); Require(close(target)==0);
        }
        if (scenario==FINAL_BACKUP) {
            Require(renameat(root_fd,"backup",root_fd,"saved-backup")==0); Create("backup","foreign");
        }
    }
    (void)fd;
}
static int Rename(int from,const char *name,int to,const char *target,unsigned flags);
#define renameatx_np Rename
#define NV_PROJECTION_EVENT(name,fd) Event(name,fd)
#ifndef NV_PROJECTION_SOURCE
#define NV_PROJECTION_SOURCE "../NVStorage/Sources/CStorageIO/NVProjectionFiles.c"
#endif
#include NV_PROJECTION_SOURCE
#undef renameatx_np
static int Rename(int from,const char *name,int to,const char *target,unsigned flags) {
    if (!strcmp(name,"Note.txt")) source_moves++;
    if (!strcmp(name,"prepared") && scenario==BEFORE_INSTALL_ERROR) { errno=EIO; return -1; }
    int result=renameatx_np(from,name,to,target,flags);
    if (!result && !strcmp(name,"prepared") && scenario==LOST_INSTALL_RETURN) { errno=EIO; return -1; }
    return result;
}

@interface RelocationCoordinator : NSFileCoordinator
@property NSUInteger notices;
@end
@implementation RelocationCoordinator
- (void)coordinateWritingItemAtURL:(NSURL *)first options:(NSFileCoordinatorWritingOptions)a
    writingItemAtURL:(NSURL *)second options:(NSFileCoordinatorWritingOptions)b error:(NSError **)error
    byAccessor:(void (NS_NOESCAPE ^)(NSURL *,NSURL *))accessor {
    Require(a==NSFileCoordinatorWritingForMoving && b==0);
    [super coordinateWritingItemAtURL:first options:a writingItemAtURL:second options:b error:error byAccessor:^(NSURL *from,NSURL *to) {
        if (scenario==UNICODE_COMPOSED || scenario==UNICODE_DECOMPOSED) {
            NSString *wanted=[NSString stringWithUTF8String:destination];
            fprintf(stderr,"unicode requested=%s granted=%s literal=%d canonical=%d\n",destination,to.lastPathComponent.UTF8String,
                [to.lastPathComponent isEqualToString:wanted],
                [[to.lastPathComponent precomposedStringWithCanonicalMapping] isEqualToString:[wanted precomposedStringWithCanonicalMapping]]);
        }
        if (scenario==NORMALIZED_GRANTS) { from=[NSURL fileURLWithPath:from.path]; to=[NSURL fileURLWithPath:to.path]; }
        NSURL *foreign=[[NSURL fileURLWithPath:[NSString stringWithUTF8String:root_path]] URLByAppendingPathComponent:@"foreign"];
        if (scenario==FOREIGN_SOURCE) from=[foreign URLByAppendingPathComponent:from.lastPathComponent];
        if (scenario==FOREIGN_DESTINATION) to=[foreign URLByAppendingPathComponent:to.lastPathComponent];
        if (scenario==UNICODE_WRONG_LEAF) to=[[to URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"Resume.txt"];
        accessor(from,to);
    }];
    if (scenario==POST_ACCESSOR_ERROR && error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:nil];
}
- (void)coordinateWritingItemAtURL:(NSURL *)url options:(NSFileCoordinatorWritingOptions)options error:(NSError **)error
    byAccessor:(void (NS_NOESCAPE ^)(NSURL *))accessor {
    Require(options==NSFileCoordinatorWritingForMoving);
    if (scenario==STAGE_REFUSED) { if (error) *error=[NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil]; return; }
    [super coordinateWritingItemAtURL:url options:options error:error byAccessor:accessor];
}
- (void)itemAtURL:(NSURL *)oldURL didMoveToURL:(NSURL *)newURL {
    Require([oldURL.lastPathComponent isEqualToString:@"Note.txt"]);
    Require([[newURL.lastPathComponent precomposedStringWithCanonicalMapping]
        isEqualToString:[[NSString stringWithUTF8String:destination] precomposedStringWithCanonicalMapping]]);
    self.notices++; [super itemAtURL:oldURL didMoveToURL:newURL];
}
@end
#ifndef NV_APPLE_PROJECTION_SOURCE
#define NV_APPLE_PROJECTION_SOURCE "../NVStorage/Sources/CAppleFileAccess/NVAppleProjectionReplacement.m"
#endif
#include NV_APPLE_PROJECTION_SOURCE

int main(int argc,char **argv) {
    Require(argc==2 || argc==3); Require(mkdir(argv[1],0700)==0);
    crash_boundary=argc==3?argv[2]:NULL;
    @autoreleasepool {
        for (scenario=0;scenario<CASE_COUNT;scenario++) { @autoreleasepool {
            Require(snprintf(root_path,sizeof(root_path),"%s/root-%d",argv[1],scenario)>0);
            Require(snprintf(moved_path,sizeof(moved_path),"%s/moved-%d",argv[1],scenario)>0);
            Require(mkdir(root_path,0700)==0);
            NVRootOwner *owner=nv_root_open(root_path); Require(owner); root_fd=owner->directory;
            const char *old=scenario==EMPTY?"":"old", *output=scenario==EMPTY?"":scenario==EQUAL_BODY?"old":"new";
            destination=scenario==CASE_ONLY || scenario==CASE_ONLY_COLLISION?"note.txt":scenario==FORMAT_CHANGE?"Note.html":
                scenario==UNICODE_COMPOSED || scenario==UNICODE_WRONG_LEAF?"Résumé.txt":
                scenario==UNICODE_DECOMPOSED?"Re\xCC\x81sume\xCC\x81.txt":"Moved.txt";
            Create("Note.txt",old);
            uint64_t words[9]; NVProjectionRead *expected=NULL; int lease=-1;
            Require(!nv_root_snapshot(owner,"Note.txt",words));
            Require(!nv_projection_read_retaining(owner,"Note.txt",words,1024,&expected,&lease));
            struct stat alias;
            int destination_aliases_source=!fstatat(root_fd,destination,&alias,AT_SYMLINK_NOFOLLOW) &&
                (uint64_t)alias.st_dev==words[1] && (uint64_t)alias.st_ino==words[2] && alias.st_nlink==1;
            NSURL *root=[NSURL fileURLWithPath:[NSString stringWithUTF8String:root_path] isDirectory:YES].fileReferenceURL; Require(root);
            NSURL *directory=[[NSFileManager defaultManager] URLForDirectory:NSItemReplacementDirectory inDomain:NSUserDomainMask
                appropriateForURL:root create:YES error:NULL]; Require(directory);
            int stage_fd=open(directory.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC); Require(stage_fd>=0);
            const uint8_t encoding[]="UTF-8;134217984", tags[]={0,255,17};
            NVProjectionMetadata metadata={.encoding={encoding,sizeof(encoding)-1,1},.tags={tags,sizeof(tags),1},
                .permissions=0640,.modified_seconds=1700000003,.modified_nanoseconds=234567890};
            NVProjectionEffect preparation;
            NVProjectionStage *stage=scenario==WRONG_STAGE?
                nv_projection_prepare(owner,stage_fd,"prepared",(const uint8_t *)output,strlen(output),&metadata,&preparation):
                nv_projection_prepare_replacement(owner,stage_fd,"prepared","Note.txt",words,(const uint8_t *)old,strlen(old),
                    (const uint8_t *)output,strlen(output),&metadata,&preparation);
            Require(stage && preparation.outcome==NV_PROJECTION_STAGED);
            if (scenario==DESTINATION_OCCUPIED) Create(destination,"foreign");
            if (scenario==BACKUP_OCCUPIED) Create("backup","foreign");
            if (scenario==SOURCE_CHANGED) { Require(renameat(root_fd,"Note.txt",root_fd,"saved-source")==0); Create("Note.txt","concurrent"); }
            if (scenario==SOURCE_METADATA) {
                Require(fsetxattr(lease,"com.apple.metadata:kMDItemOMUserTags","changed",7,0,0)==0);
                Require(!nv_root_snapshot(owner,"Note.txt",expected->words));
                memcpy(stage->source_words,expected->words,sizeof(stage->source_words));
            }
            if (scenario==WRONG_EXPECTED) expected->words[2]++;
            if (scenario==ROOT_LOST) owner->invalidated=1;
            NSURL *staged=[directory URLByAppendingPathComponent:@"prepared"];
            if (scenario==WRONG_STAGE_GRANT) staged=[NSURL fileURLWithPath:[NSString stringWithUTF8String:root_path]].fileReferenceURL;
            if (scenario==STAGE_CHANGED) Require(pwrite(stage->descriptor,"bad",3,0)==3);
            RelocationCoordinator *coordinator=[[RelocationCoordinator alloc] initWithFilePresenter:nil];
            if (scenario==CANCELLED) [coordinator cancel];
            struct stat prepared_stat; Require(!fstatat(stage_fd,"prepared",&prepared_stat,AT_SYMLINK_NOFOLLOW));
            staged_body=openat(stage_fd,"prepared",O_RDWR|O_NOFOLLOW|O_CLOEXEC); Require(staged_body>=0);
            NVProjectionRelocationResult result; installed=0; source_moves=0;
            NVAppleRelocateProjection(coordinator,(__bridge CFURLRef)root,(__bridge CFURLRef)staged,owner,stage,
                "Note.txt",destination,"backup",expected,1024,lease,(const uint8_t *)output,strlen(output),&metadata,&result);
            int success=scenario==NORMAL || scenario==EMPTY || scenario==EQUAL_BODY || scenario==CASE_ONLY || scenario==FORMAT_CHANGE ||
                (scenario==CASE_ONLY_COLLISION && !destination_aliases_source) || scenario==RETURNED_SOURCE ||
                scenario==ROOT_MOVED || scenario==NORMALIZED_GRANTS || scenario==FINAL_BACKUP ||
                scenario==UNICODE_COMPOSED || scenario==UNICODE_DECOMPOSED;
            fprintf(stderr,"relocation %d: install=%d error=%d source=%d backup=%d notice=%lu\n",scenario,
                result.replacement.installation.outcome,result.replacement.installation.error,result.source.outcome,
                result.replacement.backup_comparison,(unsigned long)coordinator.notices);
            Require((result.replacement.installation.outcome==NV_PROJECTION_INSTALLED)==success);
            Require(coordinator.notices==(NSUInteger)(success || scenario==POST_ACCESSOR_ERROR));
            if (scenario==DESTINATION_OCCUPIED || scenario==SOURCE_METADATA) Require(source_moves==0);
            int expected_error=success?0:
                scenario==WRONG_STAGE || scenario==WRONG_EXPECTED?EINVAL:
                scenario==CANCELLED || scenario==STAGE_REFUSED?ECANCELED:
                scenario==BEFORE_INSTALL_ERROR || scenario==LOST_INSTALL_RETURN || scenario==POST_ACCESSOR_ERROR?EIO:
                scenario==DESTINATION_OCCUPIED || scenario==BACKUP_OCCUPIED || scenario==LATE_DESTINATION || scenario==RESTORE_COLLISION || scenario==CASE_ONLY_COLLISION?EEXIST:ESTALE;
            Require(result.replacement.installation.error==expected_error);
            int physical_output=success || scenario==FINAL_DESTINATION || scenario==FINAL_METADATA ||
                scenario==LOST_INSTALL_RETURN || scenario==POST_ACCESSOR_ERROR;
            Require(installed==(physical_output && scenario!=LOST_INSTALL_RETURN));
            if (physical_output) {
                Body(destination,scenario==FINAL_DESTINATION?"concurrent":output);
                Body(scenario==FINAL_BACKUP?"saved-backup":"backup",old);
                if (scenario==FINAL_BACKUP) { Body("backup","foreign"); Require(result.source.outcome==NV_PROJECTION_SOURCE_UNCERTAIN); }
                if (scenario==RETURNED_SOURCE || scenario==CASE_ONLY_COLLISION) Body("Note.txt","returned");
                if (success) {
                    int target=openat(root_fd,destination,O_RDONLY|O_NOFOLLOW|O_CLOEXEC); Require(target>=0);
                    struct stat st; Require(!fstat(target,&st) && (st.st_mode&0777)==0640);
                    Require(st.st_birthtimespec.tv_sec==prepared_stat.st_birthtimespec.tv_sec && st.st_birthtimespec.tv_nsec==prepared_stat.st_birthtimespec.tv_nsec);
                    Require(result.replacement.installation.installed_has_birth &&
                        result.replacement.installation.installed_birth_seconds==st.st_birthtimespec.tv_sec &&
                        result.replacement.installation.installed_birth_nanoseconds==(uint32_t)st.st_birthtimespec.tv_nsec);
                    Require(st.st_mtimespec.tv_sec==prepared_stat.st_mtimespec.tv_sec && st.st_mtimespec.tv_nsec==prepared_stat.st_mtimespec.tv_nsec);
                    char value[32]; Require(fgetxattr(target,"org.notationalvelocity.test-unrelated",value,sizeof(value),0,0)==4 && !memcmp(value,"keep",4));
                    Require(fgetxattr(target,"com.apple.TextEncoding",value,sizeof(value),0,0)==sizeof(encoding)-1 && !memcmp(value,encoding,sizeof(encoding)-1));
                    Require(fgetxattr(target,"com.apple.metadata:kMDItemOMUserTags",value,sizeof(value),0,0)==sizeof(tags) && !memcmp(value,tags,sizeof(tags)));
                    Require(close(target)==0);
                }
                if (scenario==CASE_ONLY) {
                    DIR *catalog=fdopendir(dup(root_fd)); Require(catalog);
                    struct dirent *entry; int exact=0;
                    while ((entry=readdir(catalog))) {
                        Require(strcmp(entry->d_name,"Note.txt"));
                        if (!strcmp(entry->d_name,"note.txt")) exact++;
                    }
                    Require(exact==1 && closedir(catalog)==0);
                }
            } else if (scenario==BEFORE_INSTALL_ERROR) {
                Require(result.replacement.installation.outcome==NV_PROJECTION_UNCERTAIN);
                Require(!Present("Note.txt") && !Present(destination)); Body("backup",old);
                int held=root_fd; root_fd=stage_fd; Body("prepared",output); root_fd=held;
            } else {
                Body("Note.txt",scenario==SOURCE_CHANGED || scenario==LATE_SOURCE_CHANGE?"concurrent":
                    scenario==RESTORE_COLLISION || scenario==CASE_ONLY_COLLISION?"returned":old);
                if (scenario==LATE_SOURCE_CHANGE || scenario==SOURCE_CHANGED) Body("saved-source",old);
                if (scenario==RESTORE_COLLISION || scenario==CASE_ONLY_COLLISION) Body("backup",old);
                if (scenario==CASE_ONLY_COLLISION) { Body(destination,"returned"); Require(result.source.outcome==NV_PROJECTION_SOURCE_RETAINED); }
                if (scenario==DESTINATION_OCCUPIED || scenario==LATE_DESTINATION || scenario==RESTORE_COLLISION) Body(destination,"foreign");
                if (scenario==BACKUP_OCCUPIED) Body("backup","foreign");
                if (scenario==LATE_DESTINATION) Require(!Present("backup"));
            }
            if (scenario==ROOT_MOVED) {
                int held=root_fd; root_fd=open(root_path,O_RDONLY|O_DIRECTORY|O_CLOEXEC); Require(root_fd>=0);
                Body("Note.txt","foreign-root"); Require(close(root_fd)==0); root_fd=held;
            }
            Require(fcntl(lease,F_GETFD)>=0); nv_projection_read_close(expected); Require(close(lease)==0);
            Require(close(staged_body)==0); nv_projection_stage_close(stage); Require(close(stage_fd)==0); nv_root_close(owner);
        }}
    }
    puts("PASS: projection relocation 35 native/Foundation scenarios"); return 0;
}
