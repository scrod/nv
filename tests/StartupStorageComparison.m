/* Synthetic, read-only comparison. Uses real FrozenNotation/NoteObject code.
 * Flat values below are a BENCHMARK codec, not StartupCacheV1 or its verifier.
 * No real collection, controller, window, provider, or keychain is opened.
 */
#import <Cocoa/Cocoa.h>
#import "../FrozenNotation.h"
#import "../NoteObject.h"
#import "../NotationPrefs.h"
#import "../GlobalPrefs.h"
#import "../NSData_transformations.h"
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/resource.h>
#include <sys/mman.h>
#include <libproc.h>
#include <errno.h>
#include <pthread.h>

/* Reuse the previous experiment's SQLite/VFS plumbing, not another framework. */
#define main NVSQLiteProbeMain
#include "SQLiteLocalStoreProbe.c"
#undef main

static int inputFD = -1, uncached;
static uint64_t requestedBytes, systemReadBytes, systemReads;
static uint64_t directEncodedBytes;
static double ioSeconds;
static void *bounce;
static size_t bounceSize;
static sqlite3_io_methods readMethods;
static void (*readObserver)(off_t, size_t);
static pthread_mutex_t measurementLock=PTHREAD_MUTEX_INITIALIZER;

static ssize_t measuredRead(int fd, void *buffer, size_t length, off_t offset) {
    double start = now(); ssize_t n;
    do { n = pread(fd, buffer, length, offset); } while (n < 0 && errno == EINTR);
    double elapsed=now()-start;
    pthread_mutex_lock(&measurementLock);
    ioSeconds += elapsed; systemReads++;
    if (readObserver && n > 0) readObserver(offset, (size_t)n);
    if (n > 0) systemReadBytes += (uint64_t)n;
    pthread_mutex_unlock(&measurementLock);
    return n;
}
static int sqliteRead(sqlite3_file *file, void *buffer, int length, sqlite3_int64 offset) {
    (void)file; assert(inputFD >= 0 && length > 0 && offset >= 0);
    requestedBytes += (uint64_t)length;
    /* Same pread implementation in both modes. NOCACHE gets an aligned bounce
     * buffer so unaligned SQLite headers/overflow reads do not defeat bypass.
     * This is an experiment, not a proposed production VFS. */
    size_t skip = uncached ? (size_t)offset % 4096 : 0;
    size_t amount = uncached ? (skip+(size_t)length+4095)/4096*4096 : (size_t)length;
    void *target = buffer;
    if (uncached) {
        if (bounceSize < amount) {
            free(bounce); assert(posix_memalign(&bounce, (size_t)getpagesize(), amount)==0);
            bounceSize = amount;
        }
        target = bounce;
    }
    ssize_t got = measuredRead(inputFD, target, amount, (off_t)offset-(off_t)skip);
    if (got < 0) return SQLITE_IOERR_READ;
    size_t usable = (size_t)got > skip ? (size_t)got-skip : 0;
    if (usable > (size_t)length) usable = (size_t)length;
    if (uncached && usable) memcpy(buffer, (unsigned char *)target+skip, usable);
    if (usable < (size_t)length) {
        memset((unsigned char *)buffer+usable, 0, (size_t)length-usable);
        return SQLITE_IOERR_SHORT_READ;
    }
    return SQLITE_OK;
}
static int comparisonOpen(sqlite3_vfs *v, const char *name, sqlite3_file *f, int flags, int *outFlags) {
    int rc = vOpen(v,name,f,flags,outFlags);
    if (rc == SQLITE_OK && (flags & SQLITE_OPEN_MAIN_DB)) {
        /* Immutable, closed fixtures ONLY. Normal SQLite owns metadata/locking;
         * its content reads use our independently opened read-only descriptor. */
        f->pMethods = &readMethods;
    }
    return rc;
}
static uint64_t diskReadCount(void) {
    struct rusage_info_v2 info;
    assert(proc_pid_rusage(getpid(), RUSAGE_INFO_V2, (rusage_info_t *)&info)==0);
    return info.ri_diskio_bytesread;
}
static void emit(NSDictionary *value) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:value options:0 error:NULL];
    assert(json); fwrite([json bytes],1,[json length],stdout); putchar('\n'); fflush(stdout);
}
static NSString *path(NSString *root, NSString *leaf) { return [root stringByAppendingPathComponent:leaf]; }
static void evictFile(NSString *file) {
    int fd=open([file fileSystemRepresentation],O_RDONLY); assert(fd>=0);
    struct stat st; assert(fstat(fd,&st)==0 && S_ISREG(st.st_mode) && st.st_size>0);
    size_t size=(size_t)st.st_size, pages=(size+(size_t)getpagesize()-1)/(size_t)getpagesize();
    void *mapping=mmap(NULL,size,PROT_READ,MAP_SHARED,fd,0); assert(mapping!=MAP_FAILED);
    char *residency=calloc(pages,1); assert(residency);
    assert(mincore(mapping,size,residency)==0); size_t before=0,after=0;
    for (size_t i=0;i<pages;i++) before+=(residency[i]&MINCORE_INCORE)!=0;
    assert(msync(mapping,size,MS_SYNC|MS_INVALIDATE)==0);
    assert(mincore(mapping,size,residency)==0);
    for (size_t i=0;i<pages;i++) after+=(residency[i]&MINCORE_INCORE)!=0;
    assert(munmap(mapping,size)==0 && close(fd)==0); free(residency);
    emit(@{@"kind":@"evict",@"file":[file lastPathComponent],@"pages":@(pages),@"resident_before":@(before),@"resident_after":@(after)});
}
static NSData *readFile(NSString *file, int noCache) {
    int fd = open([file fileSystemRepresentation], O_RDONLY); assert(fd >= 0);
    assert(fcntl(fd,F_NOCACHE,noCache)==0);
    struct stat st; assert(fstat(fd,&st)==0 && S_ISREG(st.st_mode) && st.st_size > 0);
    size_t size = (size_t)st.st_size; void *bytes;
    assert(posix_memalign(&bytes,(size_t)getpagesize(),(size+4095)/4096*4096)==0);
    size_t at = 0;
    while (at < size) {
        size_t wanted = MIN(size-at,(size_t)1048576);
        ssize_t got = measuredRead(fd,(unsigned char *)bytes+at,wanted,(off_t)at);
        assert(got > 0); at += (size_t)got;
    }
    requestedBytes += size; assert(close(fd)==0);
    return [NSData dataWithBytesNoCopy:bytes length:size freeWhenDone:YES];
}
static void writeFile(NSData *bytes, NSString *file) {
    int fd = open([file fileSystemRepresentation],O_WRONLY|O_CREAT|O_EXCL,0600); assert(fd>=0);
    assert(fcntl(fd,F_NOCACHE,1)==0);
    size_t at=0;
    while (at < [bytes length]) {
        ssize_t n=write(fd,(const char *)[bytes bytes]+at,[bytes length]-at);
        if (n<0 && errno==EINTR) continue;
        assert(n>0); at+=(size_t)n;
    }
    assert(fsync(fd)==0 && close(fd)==0);
}
static void appendString(NSMutableData *data, NSString *s) {
    NSData *bytes=[s dataUsingEncoding:NSUTF8StringEncoding]; assert([bytes length]<=UINT32_MAX);
    uint32_t n=CFSwapInt32HostToLittle((uint32_t)[bytes length]);
    [data appendBytes:&n length:4]; [data appendData:bytes];
}
static NSData *encodeNote(NoteObject *note) {
    NSMutableData *data=[NSMutableData data];
    [data appendBytes:[note uniqueNoteIDBytes] length:16];
    double dates[]={createdDateOfNote(note),modifiedDateOfNote(note)};
    [data appendBytes:dates length:sizeof(dates)];
    appendString(data,titleOfNote(note)); appendString(data,labelsOfNote(note));
    appendString(data,[[note contentString] string]); return data;
}
static NSString *takeString(const unsigned char **cursor, const unsigned char *end) {
    assert(end-*cursor>=4); uint32_t n; memcpy(&n,*cursor,4); *cursor+=4;
    n=CFSwapInt32LittleToHost(n); assert((size_t)(end-*cursor)>=n);
    NSString *s=[[[NSString alloc] initWithBytes:*cursor length:n encoding:NSUTF8StringEncoding] autorelease];
    assert(s); *cursor+=n; return s;
}
static NoteObject *decodeNote(const unsigned char **cursor, const unsigned char *end) {
        const unsigned char *p=*cursor;
        assert(end-p>=32); CFUUIDBytes uuid; double dates[2];
        memcpy(&uuid,p,16); memcpy(dates,p+16,16); p+=32;
        NSString *title=takeString(&p,end), *labels=takeString(&p,end), *body=takeString(&p,end);
        NoteObject *note=[[[NoteObject alloc] initWithNoteBody:[[[NSAttributedString alloc]
            initWithString:body] autorelease] title:title format:SingleDatabaseFormat labels:labels] autorelease];
        assert(note); memcpy([note uniqueNoteIDBytes],&uuid,16);
        [note setDateAdded:dates[0]]; [note setDateModified:dates[1]];
        *cursor=p; return note;
}
static NSMutableArray *decodeFlat(NSData *data) {
    const unsigned char *p=[data bytes], *end=p+[data length]; assert(end-p>=8);
    uint64_t count; memcpy(&count,p,8); p+=8; count=CFSwapInt64LittleToHost(count);
    assert(count<=1000000);
    NSMutableArray *notes=[NSMutableArray arrayWithCapacity:(NSUInteger)count];
    for (uint64_t i=0;i<count;i++) [notes addObject:decodeNote(&p,end)];
    assert(p==end); return notes;
}
static NSMutableArray *decodeFrozen(NSData *data) {
    NSError *err=nil;
    NSKeyedUnarchiver *u=[[[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&err] autorelease];
    [u setRequiresSecureCoding:NO];
    FrozenNotation *f=[u decodeTopLevelObjectForKey:NSKeyedArchiveRootObjectKey error:&err];
    [u finishDecoding]; assert(f && !err);
    OSStatus status=noErr; NSMutableArray *notes=[f unpackedNotesReturningError:&status];
    assert(notes && status==noErr); return notes;
}
static NoteObject *newNote(NSUInteger id, NSUInteger length) {
    static NSArray *words;
    if (!words) words=[[@"note history coffee keyboard project update review garden idea meeting context title labels design quiet music example cache durable words apple text Friday parent version test observation question answer draft library café 東京 résumé Δοκιμή 🍎"
        componentsSeparatedByString:@" "] retain];
    uint64_t rng=id+17; NSMutableString *body=[NSMutableString string];
    while ([body length]<length) {
        rng=rng*UINT64_C(6364136223846793005)+1;
        [body appendFormat:@"%@%@",[words objectAtIndex:(rng>>32)%[words count]],rng%19==0?@"\n":@" "];
        if (rng%13==0) [body appendFormat:@"%llu ",(unsigned long long)(rng%100000)];
    }
    NoteObject *note=[[[NoteObject alloc] initWithNoteBody:[[[NSAttributedString alloc] initWithString:body] autorelease]
        title:[NSString stringWithFormat:@"Research %06lu café",(unsigned long)id] format:SingleDatabaseFormat
        labels:[NSString stringWithFormat:@"topic%lu tag%lu",(unsigned long)(id%31),(unsigned long)(id%7)]] autorelease];
    unsigned char key[32]; identity(id+1,key); memcpy([note uniqueNoteIDBytes],key,16);
    [note setDateAdded:700000000.0+id]; [note setDateModified:700000100.0+id]; return note;
}
static void seedComparison(NSString *root, NSUInteger count, NSUInteger length, int64_t history, int pageSize) {
    NSMutableArray *notes=[NSMutableArray arrayWithCapacity:count];
    NSMutableData *flat=[NSMutableData data]; uint64_t n=CFSwapInt64HostToLittle(count); [flat appendBytes:&n length:8];
    NSMutableArray *records=[NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i=0;i<count;i++) {
        NoteObject *note=newNote(i,length); [notes addObject:note];
        NSData *record=encodeNote(note); [records addObject:record]; [flat appendData:record];
    }
    NotationPrefs *prefs=[[[NotationPrefs alloc] init] autorelease];
    NSData *frozen=[FrozenNotation frozenDataWithExistingNotes:notes deletedNotes:[NSMutableSet set] prefs:prefs]; assert(frozen);
    NSData *compressed=[flat compressedData]; assert(compressed);
    writeFile(frozen,path(root,@"frozen.dat")); writeFile(flat,path(root,@"flat.dat"));
    sqlite3 *db=open_db([path(root,@"store.sqlite") fileSystemRepresentation],1);
    assert(pageSize==4096 || pageSize==16384);
    sql(db,pageSize==4096?"PRAGMA page_size=4096":"PRAGMA page_size=16384");
    sql(db,"PRAGMA journal_mode=DELETE; CREATE TABLE objects(id INTEGER PRIMARY KEY, envelope BLOB NOT NULL);"
           "CREATE TABLE cache(name TEXT PRIMARY KEY, value BLOB NOT NULL);"
           "CREATE TABLE current(id INTEGER PRIMARY KEY, value BLOB NOT NULL); BEGIN;");
    sqlite3_stmt *q=prepare(db,"INSERT INTO objects VALUES(?,?)"); unsigned char bytes[4096];
    for (int64_t i=1;i<=history;i++) {
        payload((uint64_t)i,bytes,sizeof(bytes)); sqlite3_bind_int64(q,1,i);
        sqlite3_bind_blob(q,2,bytes,sizeof(bytes),SQLITE_TRANSIENT); done(db,q);
        if (i%2048==0) sql(db,"COMMIT; BEGIN");
    }
    sqlite3_finalize(q); q=prepare(db,"INSERT INTO cache VALUES(?,?)");
    NSDictionary *caches=@{@"frozen":frozen,@"flat":flat,@"compressed":compressed};
    for (NSString *key in caches) {
        NSData *data=[caches objectForKey:key]; sqlite3_bind_text(q,1,[key UTF8String],-1,SQLITE_TRANSIENT);
        sqlite3_bind_blob(q,2,[data bytes],(int)[data length],SQLITE_TRANSIENT); done(db,q);
    }
    sqlite3_finalize(q); q=prepare(db,"INSERT INTO current VALUES(?,?)");
    for (NSUInteger i=0;i<count;i++) {
        NSData *record=[records objectAtIndex:i]; sqlite3_bind_int64(q,1,(sqlite3_int64)i);
        sqlite3_bind_blob(q,2,[record bytes],(int)[record length],SQLITE_TRANSIENT); done(db,q);
    }
    sqlite3_finalize(q); sql(db,"COMMIT"); int64_t dbSize=scalar(db,"PRAGMA page_count")*scalar(db,"PRAGMA page_size");
    check(db,sqlite3_close(db));
    emit(@{@"kind":@"seed",@"notes":@(count),@"body_characters_target":@(length),@"history":@(history),
        @"frozen_bytes":@([frozen length]),@"flat_bytes":@([flat length]),@"compressed_bytes":@([compressed length]),
        @"db_bytes":@(dbSize),@"page_size":@(pageSize),@"expected_digest":[NSString stringWithFormat:@"%016llx",(unsigned long long)touch([flat bytes],(int)[flat length])]});
}
static NSData *readSQLite(NSString *root, NSString *kind, NSUInteger count, NSMutableArray *directNotes) {
    NSString *file=path(root,@"store.sqlite"); inputFD=open([file fileSystemRepresentation],O_RDONLY); assert(inputFD>=0);
    assert(fcntl(inputFD,F_NOCACHE,uncached)==0);
    readMethods=methods; readMethods.xRead=sqliteRead; counting.xOpen=comparisonOpen;
    sqlite3 *db=NULL; check(db,sqlite3_open_v2([file fileSystemRepresentation],&db,SQLITE_OPEN_READONLY,counting.zName));
    key_db(db);
    sql(db,"PRAGMA mmap_size=0; PRAGMA cache_size=-4096; PRAGMA temp_store=MEMORY; BEGIN");
    NSMutableData *result=[NSMutableData data]; sqlite3_stmt *q;
    if (directNotes) {
        directEncodedBytes=8;
        q=prepare(db,"SELECT value FROM current ORDER BY id"); int rc;
        while ((rc=sqlite3_step(q))==SQLITE_ROW) {
            const unsigned char *p=sqlite3_column_blob(q,0), *end=p+sqlite3_column_bytes(q,0);
            directEncodedBytes+=(uint64_t)sqlite3_column_bytes(q,0);
            [directNotes addObject:decodeNote(&p,end)]; assert(p==end);
        }
        assert(rc==SQLITE_DONE && [directNotes count]==count);
    } else if ([kind isEqualToString:@"rows"]) {
        uint64_t n=CFSwapInt64HostToLittle(count); [result appendBytes:&n length:8];
        q=prepare(db,"SELECT value FROM current ORDER BY id"); int rc; NSUInteger rows=0;
        while ((rc=sqlite3_step(q))==SQLITE_ROW) { [result appendBytes:sqlite3_column_blob(q,0) length:(NSUInteger)sqlite3_column_bytes(q,0)]; rows++; }
        assert(rc==SQLITE_DONE && rows==count);
    } else {
        q=prepare(db,"SELECT value FROM cache WHERE name=?"); sqlite3_bind_text(q,1,[kind UTF8String],-1,SQLITE_TRANSIENT);
        assert(sqlite3_step(q)==SQLITE_ROW); [result appendBytes:sqlite3_column_blob(q,0) length:(NSUInteger)sqlite3_column_bytes(q,0)];
        assert(sqlite3_step(q)==SQLITE_DONE);
    }
    sqlite3_finalize(q); sql(db,"COMMIT"); check(db,sqlite3_close(db)); assert(close(inputFD)==0); inputFD=-1;
    return result;
}
static void measureComparison(NSString *root, NSString *kind, int noCache, NSUInteger count) {
    uncached=noCache; ioSeconds=0; requestedBytes=systemReadBytes=systemReads=0;
    NSMutableArray *direct=[kind isEqual:@"rows-direct"] ? [NSMutableArray arrayWithCapacity:count] : nil;
    uint64_t before=diskReadCount(); double begin=now(); NSData *data;
    if ([kind hasSuffix:@"-file"]) data=readFile(path(root,[kind hasPrefix:@"frozen"]?@"frozen.dat":@"flat.dat"),noCache);
    else data=readSQLite(root,kind,count,direct);
    double loaded=now(); uint64_t afterRead=diskReadCount();
    NSArray *notes;
    if (direct) notes=direct;
    else if ([kind hasPrefix:@"frozen"]) notes=decodeFrozen(data);
    else notes=decodeFlat([kind isEqualToString:@"compressed"]?[data uncompressedData]:data);
    double decoded=now(); assert([notes count]==count);
    // Exercise the real initialized search strings equally; no asynchronous search.
    uint64_t searchHits=0; double searchStart=now();
    for (NoteObject *note in notes) {
        [note updateContentCacheCStringIfNecessary];
        assert(note->cContents && note->cTitle && note->cLabels);
        searchHits += strstr(note->cContents,"coffee")!=NULL;
        searchHits += strstr(note->cTitle,"research")!=NULL;
        searchHits += strstr(note->cLabels,"topic")!=NULL;
    }
    double searched=now();
    uint64_t afterDecode=diskReadCount(); struct rusage usage; assert(getrusage(RUSAGE_SELF,&usage)==0);
    /* Exact normalized common-field comparison, outside the timing interval. */
    NSMutableData *actual=[NSMutableData data]; uint64_t n=CFSwapInt64HostToLittle(count); [actual appendBytes:&n length:8];
    for (NoteObject *note in notes) [actual appendData:encodeNote(note)];
    NSData *expectedBytes=[NSData dataWithContentsOfFile:path(root,@"flat.dat")];
    assert(expectedBytes && [actual isEqualToData:expectedBytes]);
    emit(@{@"kind":kind,@"nocache":@(noCache),@"notes":@(count),@"load_ms":@((loaded-begin)*1000),
        @"decode_ms":@((decoded-loaded)*1000),@"total_ms":@((searched-begin)*1000),@"pread_ms":@(ioSeconds*1000),
        @"search_ms":@((searched-searchStart)*1000),@"search_hits":@(searchHits),@"direct_row_decode":@(direct!=nil),
        @"pread_calls":@(systemReads),@"requested_bytes":@(requestedBytes),@"pread_bytes":@(systemReadBytes),
        @"kernel_read_bytes":@(afterRead-before),@"decode_kernel_read_bytes":@(afterDecode-afterRead),
        @"rss_high_water_bytes":@(usage.ru_maxrss),@"encoded_bytes":@(direct?directEncodedBytes:[data length]),
        @"digest":[NSString stringWithFormat:@"%016llx",(unsigned long long)touch([actual bytes],(int)[actual length])]});
}
#ifdef NV_STARTUP_EMBED
#define main NVLegacyStartupComparisonMain
#endif
int main(int argc, char **argv) {
    @autoreleasepool {
        setup_vfs();
        /* Initialize shared Foundation/AppKit codec machinery identically, before
         * timing fixture reads. No window or actual note controller is created. */
        NoteObject *warm=newNote(0,80); NotationPrefs *p=[[[NotationPrefs alloc] init] autorelease];
        NSData *w=[FrozenNotation frozenDataWithExistingNotes:[NSMutableArray arrayWithObject:warm] deletedNotes:[NSMutableSet set] prefs:p];
        assert([decodeFrozen(w) count]==1);
        if ((argc==6 || argc==7) && !strcmp(argv[1],"seed"))
            seedComparison(@(argv[2]),(NSUInteger)atoll(argv[3]),(NSUInteger)atoll(argv[4]),atoll(argv[5]),argc==7?atoi(argv[6]):4096);
        else if (argc==6 && !strcmp(argv[1],"read"))
            measureComparison(@(argv[2]),@(argv[3]),atoi(argv[4]),(NSUInteger)atoll(argv[5]));
        else if (argc==3 && !strcmp(argv[1],"evict")) evictFile(@(argv[2]));
        else { fprintf(stderr,"seed DIR NOTES BODY_CHARS HISTORY [PAGE_SIZE] | read DIR KIND NOCACHE NOTES | evict FILE\n"); return 2; }
    }
    return 0;
}
#ifdef NV_STARTUP_EMBED
#undef main
#endif
