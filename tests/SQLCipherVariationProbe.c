/* Isolated SQLCipher mechanics, not an NV adapter or key-management format.
 * Only public synthetic keys/data. Includes the existing fault-counting VFS. */
#define main OriginalSQLiteProbeMain
#include "SQLiteLocalStoreProbe.c"
#undef main
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <libproc.h>

static const char *newKey = "x'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'";
static const char *oldKey = "x'000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'";
static uint64_t disk_bytes(void) {
    struct rusage_info_v2 r;
    assert(proc_pid_rusage(getpid(), RUSAGE_INFO_V2, (rusage_info_t *)&r)==0);
    return r.ri_diskio_bytesread;
}
static void text_pragma(sqlite3 *db, const char *query, char *out, int size) {
    sqlite3_stmt *q=prepare(db,query); assert(sqlite3_step(q)==SQLITE_ROW);
    snprintf(out,(size_t)size,"%s",sqlite3_column_text(q,0)); sqlite3_finalize(q);
}
static void info(void) {
    sqlite3 *db=open_db(":memory:",1); char v[128],p[128];
    text_pragma(db,"PRAGMA cipher_version",v,sizeof(v));
    text_pragma(db,"PRAGMA cipher_provider",p,sizeof(p));
    assert(sqlite3_compileoption_used("TEMP_STORE=3"));
    printf("{\"cipher\":\"%s\",\"sqlite\":\"%s\",\"provider\":\"%s\",\"temp_store_compile\":3,\"memory_security\":%lld}\n",v,sqlite3_libversion(),p,(long long)scalar(db,"PRAGMA cipher_memory_security"));
    check(db,sqlite3_close(db));
}
static void add_rows(sqlite3 *db, int64_t first, int64_t last) {
    sqlite3_stmt *q=prepare(db,"INSERT INTO history VALUES(?,?)");
    unsigned char data[4096]; sql(db,"BEGIN IMMEDIATE");
    for (int64_t i=first;i<=last;i++) {
        payload((uint64_t)i,data,sizeof(data)); sqlite3_bind_int64(q,1,i);
        sqlite3_bind_blob(q,2,data,sizeof(data),SQLITE_TRANSIENT); done(db,q);
        if (i%128==0) sql(db,"COMMIT; BEGIN IMMEDIATE");
    }
    sql(db,"COMMIT"); sqlite3_finalize(q);
}
static void fixture(const char *file, const char *mode, int64_t n) {
    sqlite3 *db=open_db(file,1);
    assert(!strcmp(mode,"WAL") || !strcmp(mode,"DELETE"));
    sql(db,!strcmp(mode,"WAL")?"PRAGMA journal_mode=WAL":"PRAGMA journal_mode=DELETE");
    sql(db,"CREATE TABLE cache(id INTEGER PRIMARY KEY, data BLOB NOT NULL); CREATE TABLE history(id INTEGER PRIMARY KEY, data BLOB NOT NULL)");
    unsigned char *data=malloc(1048576); assert(data); payload(1,data,1048576);
    sqlite3_stmt *q=prepare(db,"INSERT INTO cache VALUES(1,?)");
    sqlite3_bind_blob(q,1,data,1048576,SQLITE_TRANSIENT); done(db,q); sqlite3_finalize(q); free(data);
    add_rows(db,1,n); check(db,sqlite3_close(db)); puts("{\"seeded\":true}");
}
static void append(const char *file, int64_t n, int hold) {
    sqlite3 *db=open_db(file,0), *reader=NULL;
    sql(db,"PRAGMA wal_autocheckpoint=0");
    int64_t before=scalar(db,"SELECT coalesce(max(id),0) FROM history");
    if (hold) { reader=open_db(file,0); sql(reader,"BEGIN"); assert(scalar(reader,"SELECT max(id) FROM history")==before); }
    add_rows(db,before+1,before+n);
    if (!hold) stop_for_kill("wal-backlog");
    int frames=-1,checkpointed=-1;
    int rc=sqlite3_wal_checkpoint_v2(db,NULL,SQLITE_CHECKPOINT_PASSIVE,&frames,&checkpointed);
    assert(rc==SQLITE_OK && frames>checkpointed);
    int oldFrames=frames, oldCheckpointed=checkpointed;
    sql(reader,"COMMIT"); check(reader,sqlite3_close(reader));
    check(db,sqlite3_wal_checkpoint_v2(db,NULL,SQLITE_CHECKPOINT_TRUNCATE,&frames,&checkpointed));
    printf("{\"held_frames\":%d,\"held_checkpointed\":%d,\"released_frames\":%d,\"released_checkpointed\":%d}\n",oldFrames,oldCheckpointed,frames,checkpointed);
    check(db,sqlite3_close(db));
}
static void read_startup(const char *file, int64_t expected) {
    uint64_t disk=disk_bytes(); double begin=now(); sqlite3 *db=open_db(file,0);
    assert(scalar(db,"SELECT count(*) FROM sqlite_schema WHERE type='table'")==2);
    double opened=now();
    sqlite3_stmt *q=prepare(db,"SELECT data FROM cache WHERE id=1");
    assert(sqlite3_step(q)==SQLITE_ROW && sqlite3_column_bytes(q,0)==1048576);
    unsigned char *copy=malloc(1048576); assert(copy); memcpy(copy,sqlite3_column_blob(q,0),1048576); sqlite3_finalize(q);
    assert(scalar(db,"SELECT coalesce(max(id),0) FROM history")==expected);
    unsigned char last[4096]={0};
    if (expected) {
        q=prepare(db,"SELECT data FROM history WHERE id=?"); sqlite3_bind_int64(q,1,expected);
        assert(sqlite3_step(q)==SQLITE_ROW && sqlite3_column_bytes(q,0)==4096);
        memcpy(last,sqlite3_column_blob(q,0),sizeof(last)); sqlite3_finalize(q);
    }
    double ended=now(); uint64_t bytes=disk_bytes()-disk;
    unsigned char *want=malloc(1048576); assert(want); payload(1,want,1048576); assert(!memcmp(want,copy,1048576));
    if (expected) { payload((uint64_t)expected,want,4096); assert(!memcmp(want,last,4096)); }
    free(want); free(copy);
    printf("{\"open_schema_ms\":%.3f,\"startup_ms\":%.3f,\"kernel_read_bytes\":%" PRIu64 ",\"vfs_read_bytes\":%" PRIu64 ",\"wal_reads\":%" PRIu64 ",\"rows\":%lld}\n",(opened-begin)*1000,(ended-begin)*1000,bytes,readBytes,walReads,(long long)expected);
    check(db,sqlite3_close(db));
}
static void verify_key(const char *file, const char *kind) {
    sqlite3 *db=NULL; check(db,sqlite3_open_v2(file,&db,SQLITE_OPEN_READWRITE,counting.zName));
    const char *key=!strcmp(kind,"old")?oldKey:!strcmp(kind,"new")?newKey:"wrong synthetic password";
    int keyed=SQLITE_OK;
    if (!strcmp(kind,"bytes")) { unsigned char raw[32]; for (int i=0;i<32;i++) raw[i]=(unsigned char)i; keyed=sqlite3_key(db,raw,32); }
    else if (strcmp(kind,"none")) keyed=sqlite3_key(db,key,(int)strlen(key));
    int rc=sqlite3_exec(db,"SELECT count(*) FROM sqlite_schema",NULL,NULL,NULL);
    int dataRC=rc, count=0;
    if (rc==SQLITE_OK) {
        sqlite3_stmt *cache=prepare(db,"SELECT data FROM cache WHERE id=1");
        unsigned char *wantCache=malloc(1048576); assert(wantCache); payload(1,wantCache,1048576);
        assert(sqlite3_step(cache)==SQLITE_ROW && sqlite3_column_bytes(cache,0)==1048576);
        assert(!memcmp(wantCache,sqlite3_column_blob(cache,0),1048576));
        free(wantCache); sqlite3_finalize(cache);
        sqlite3_stmt *q=NULL; dataRC=sqlite3_prepare_v2(db,"SELECT id,data FROM history ORDER BY id",-1,&q,NULL);
        if (dataRC==SQLITE_OK) {
            while ((dataRC=sqlite3_step(q))==SQLITE_ROW) {
                assert(sqlite3_column_int64(q,0)==count+1);
                unsigned char want[4096]; payload((uint64_t)sqlite3_column_int64(q,0),want,sizeof(want));
                assert(sqlite3_column_bytes(q,1)==4096 && !memcmp(want,sqlite3_column_blob(q,1),4096)); count++;
            }
        }
        sqlite3_finalize(q);
    }
    printf("{\"key_return\":%d,\"read_return\":%d,\"data_return\":%d,\"verified_history_rows\":%d}\n",keyed,rc,dataRC,count); check(db,sqlite3_close(db));
}
static void rekey(const char *file, const char *cut) {
    sqlite3 *db=open_db(file,0); assert(scalar(db,"SELECT count(*) FROM sqlite_schema WHERE type='table'")==2);
    writes=writtenBytes=syncs=walHighWater=journalHighWater=0;
    if (!strcmp(cut,"write")) writeCut=3;
    if (!strcmp(cut,"sync")) syncCut=1;
    if (!strcmp(cut,"full")) failWrite=3;
    if (!strncmp(cut,"full-at-",8)) failWrite=atoi(cut+8);
    if (!strncmp(cut,"sync-error-",11)) failSync=atoi(cut+11);
    double begin=now(); int rc=sqlite3_rekey(db,newKey,(int)strlen(newKey)); double ended=now();
    printf("{\"rekey_return\":%d,\"connection_error\":%d,\"ms\":%.3f,\"write_calls\":%" PRIu64 ",\"write_bytes\":%" PRIu64 ",\"syncs\":%" PRIu64 ",\"wal_high_water\":%" PRIu64 ",\"journal_high_water\":%" PRIu64 ",\"fail_write_remaining\":%d,\"fail_sync_remaining\":%d}\n",rc,sqlite3_extended_errcode(db),(ended-begin)*1000,writes,writtenBytes,syncs,walHighWater,journalHighWater,failWrite,failSync);
    check(db,sqlite3_close(db));
}
static void cold(const char *file) {
    int fd=open(file,O_RDONLY); assert(fd>=0); struct stat st; assert(fstat(fd,&st)==0 && st.st_size>0);
    size_t n=(size_t)st.st_size,pages=(n+(size_t)getpagesize()-1)/(size_t)getpagesize();
    void *p=mmap(NULL,n,PROT_READ,MAP_SHARED,fd,0); assert(p!=MAP_FAILED); char *v=calloc(pages,1); assert(v);
    assert(msync(p,n,MS_SYNC|MS_INVALIDATE)==0 && mincore(p,n,v)==0);
    for (size_t i=0;i<pages;i++) assert(!(v[i]&MINCORE_INCORE));
    free(v); assert(munmap(p,n)==0 && close(fd)==0); puts("{\"resident_after\":0}");
}
static void corruption(const char *file, const char *kind) {
    sqlite3 *db=open_db(file,0);
    if (!strcmp(kind,"locate")) {
        int64_t pg=scalar(db,"SELECT pageno FROM dbstat WHERE name='history' AND pagetype='overflow' ORDER BY pageno LIMIT 1");
        printf("{\"page\":%lld,\"page_size\":%lld}\n",(long long)pg,(long long)scalar(db,"PRAGMA page_size"));
    } else {
        sqlite3_stmt *q=NULL; int rc=sqlite3_prepare_v2(db,"SELECT data FROM history ORDER BY id",-1,&q,NULL),count=0;
        if (rc==SQLITE_OK) { while ((rc=sqlite3_step(q))==SQLITE_ROW) { assert(sqlite3_column_bytes(q,0)==4096); count++; } }
        sqlite3_finalize(q);
        q=prepare(db,"PRAGMA cipher_integrity_check"); int errors=0,step;
        while ((step=sqlite3_step(q))==SQLITE_ROW) errors++;
        assert(step==SQLITE_DONE); sqlite3_finalize(q);
        printf("{\"read_return\":%d,\"rows_before_error\":%d,\"cipher_integrity_errors\":%d}\n",rc,count,errors);
    }
    check(db,sqlite3_close(db));
}
int main(int argc,char **argv) {
    setup_vfs();
    if (argc==2 && !strcmp(argv[1],"info")) info();
    else if (argc==5 && !strcmp(argv[1],"seed")) fixture(argv[2],argv[3],atoll(argv[4]));
    else if (argc==5 && !strcmp(argv[1],"append")) append(argv[2],atoll(argv[3]),atoi(argv[4]));
    else if (argc==4 && !strcmp(argv[1],"read")) read_startup(argv[2],atoll(argv[3]));
    else if (argc==4 && !strcmp(argv[1],"key")) verify_key(argv[2],argv[3]);
    else if (argc==4 && !strcmp(argv[1],"rekey")) rekey(argv[2],argv[3]);
    else if (argc==3 && !strcmp(argv[1],"cold")) cold(argv[2]);
    else if (argc==4 && !strcmp(argv[1],"corrupt")) corruption(argv[2],argv[3]);
    else { fprintf(stderr,"invalid SQLCipher probe command\n"); return 2; }
    return 0;
}
