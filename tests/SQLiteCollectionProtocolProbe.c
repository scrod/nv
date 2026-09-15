/* Candidate SQLite transaction mapping, NOT production formats or Apple CAS.
 * Reuses the qualified fixture VFS. Each object is one complete synthetic
 * action; envelope decoding, full causal merging and UI admission are outside
 * this probe. No real NV/provider data.
 * current_view's three fixture bytes abstract one atomic current-row update,
 * not a packed startup format. Real row/schema tests live in the Python checks. */
#define main OriginalSQLiteProbeMain
#include "SQLiteLocalStoreProbe.c"
#undef main
#include <fcntl.h>
#include <sys/stat.h>

static const char *cut, *policy;
static int broken(const char *name) { return !strcmp(policy,name); }
static void at(const char *name) {
    if (!strcmp(cut,name)) { printf("READY %s\n",name); fflush(stdout); assert(getchar()=='\n'); }
}
static void execf(sqlite3 *db,const char *format,int a,int b) {
    char *s=sqlite3_mprintf(format,a,b); assert(s); sql(db,s); sqlite3_free(s);
}
/* Values 1=genesis, 2=early-arriving child, 3=late parent, 4=import,
 * 5=causally later Delete, 6=an erroneous duplicate import. */
static int parent(int id) { return id==1?0:id==2?3:id==5?4:1; }
static int exists(sqlite3 *db,const char *table,int id) {
    char *s=sqlite3_mprintf("SELECT count(*) FROM %w WHERE id=%d",table,id);
    int yes=(int)scalar(db,s); sqlite3_free(s); return yes;
}
static void object(sqlite3 *db,int id) {
    unsigned char bytes[4096]; payload((uint64_t)id,bytes,sizeof(bytes));
    if (exists(db,"objects",id)) {
        sqlite3_stmt *q=prepare(db,"SELECT bytes FROM objects WHERE id=?"); sqlite3_bind_int(q,1,id);
        assert(sqlite3_step(q)==SQLITE_ROW && sqlite3_column_bytes(q,0)==4096);
        assert(!memcmp(bytes,sqlite3_column_blob(q,0),4096)); sqlite3_finalize(q); return;
    }
    sqlite3_stmt *q=prepare(db,"INSERT INTO objects(id,parent,bytes) VALUES(?,?,?)");
    sqlite3_bind_int(q,1,id); sqlite3_bind_int(q,2,parent(id));
    sqlite3_bind_blob(q,3,bytes,sizeof(bytes),SQLITE_TRANSIENT); done(db,q); sqlite3_finalize(q);
    execf(db,"INSERT OR IGNORE INTO ready SELECT id FROM objects WHERE id=%d AND (parent=0 OR parent IN (SELECT id FROM applications))",id,0);
}
static void reduce(unsigned char state[3],int id) {
    if (id==1) state[2]=7;  /* unaffected note */
    if (id==3 || id==2) state[1]=(unsigned char)id;
    if (id==4) state[0]=4;
    if (id==5) state[0]=0;
    if (id==6) state[0]=6;
}
static void replay(sqlite3 *db,unsigned char state[3],int through) {
    sqlite3_stmt *q=prepare(db,"SELECT id FROM applications WHERE seq>? ORDER BY seq");
    sqlite3_bind_int(q,1,through); int rc;
    while ((rc=sqlite3_step(q))==SQLITE_ROW) reduce(state,sqlite3_column_int(q,0));
    assert(rc==SQLITE_DONE); sqlite3_finalize(q);
}
static void apply_object(sqlite3 *db,int id) {
    if (exists(db,"applications",id)) return;
    assert(exists(db,"objects",id) && (!parent(id) || exists(db,"applications",parent(id))));
    execf(db,"INSERT INTO actions VALUES(%d,%d)",id,id);
    execf(db,"INSERT INTO applications SELECT coalesce(max(seq),0)+1,%d FROM applications",id,0);
    execf(db,"DELETE FROM ready WHERE id=%d",id,0);
    if (!broken("no-ready")) execf(db,"INSERT OR IGNORE INTO ready SELECT id FROM objects WHERE parent=%d AND id NOT IN (SELECT id FROM applications)",id,0);
    sql(db,"UPDATE private_state SET through=(SELECT max(seq) FROM applications)");
}
static void current_view(sqlite3 *db) {
    unsigned char state[3]={0}; replay(db,state,0);
    int through=(int)scalar(db,"SELECT through FROM private_state");
    sqlite3_stmt *q=prepare(db,"INSERT OR REPLACE INTO current_view VALUES(1,'store-A',?,?)");
    sqlite3_bind_int(q,1,through); sqlite3_bind_blob(q,2,state,3,SQLITE_TRANSIENT); done(db,q); sqlite3_finalize(q);
}
static int same_stat(struct stat a,struct stat b) {
    return a.st_dev==b.st_dev && a.st_ino==b.st_ino && a.st_size==b.st_size &&
        a.st_mtimespec.tv_sec==b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec==b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec==b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec==b.st_ctimespec.tv_nsec;
}
static int source(const char *path,unsigned char bytes[4096],struct stat *st) {
    int fd=open(path,O_RDONLY|O_NOFOLLOW); if (fd<0) return 0;
    struct stat after,named; int ok=fstat(fd,st)==0 && S_ISREG(st->st_mode) && st->st_size==4096;
    ssize_t n=ok?pread(fd,bytes,4096,0):-1;
    ok=ok && n==4096 && fstat(fd,&after)==0 && same_stat(*st,after) && lstat(path,&named)==0 && same_stat(named,after);
    assert(close(fd)==0); return ok;
}
static int matches(sqlite3 *db,const char *path) {
    unsigned char bytes[4096]; struct stat st;
    if (!source(path,bytes,&st)) return 0;
    sqlite3_stmt *q=prepare(db,"SELECT bytes,device,inode,mtime,ctime FROM snapshots WHERE id=1");
    assert(sqlite3_step(q)==SQLITE_ROW);
    int ok=sqlite3_column_bytes(q,0)==4096 && !memcmp(bytes,sqlite3_column_blob(q,0),4096) &&
        sqlite3_column_int64(q,1)==(sqlite3_int64)st.st_dev && sqlite3_column_int64(q,2)==(sqlite3_int64)st.st_ino &&
        sqlite3_column_int64(q,3)==st.st_mtimespec.tv_sec*INT64_C(1000000000)+st.st_mtimespec.tv_nsec &&
        sqlite3_column_int64(q,4)==st.st_ctimespec.tv_sec*INT64_C(1000000000)+st.st_ctimespec.tv_nsec;
    sqlite3_finalize(q); return ok;
}
static void retain(sqlite3 *db,const char *path,int id) {
    unsigned char bytes[4096]; struct stat st; assert(source(path,bytes,&st));
    sqlite3_stmt *q=prepare(db,"INSERT INTO snapshots VALUES(?,?,?,?,?,?)");
    sqlite3_bind_int(q,1,id); sqlite3_bind_blob(q,2,bytes,4096,SQLITE_TRANSIENT);
    sqlite3_bind_int64(q,3,(sqlite3_int64)st.st_dev); sqlite3_bind_int64(q,4,(sqlite3_int64)st.st_ino);
    sqlite3_bind_int64(q,5,st.st_mtimespec.tv_sec*INT64_C(1000000000)+st.st_mtimespec.tv_nsec);
    sqlite3_bind_int64(q,6,st.st_ctimespec.tv_sec*INT64_C(1000000000)+st.st_ctimespec.tv_nsec);
    done(db,q); sqlite3_finalize(q);
}
static void init(const char *path,const char *mode,const char *file) {
    sqlite3 *db=open_db(path,1); assert(!strcmp(mode,"WAL") || !strcmp(mode,"DELETE"));
    sql(db,!strcmp(mode,"WAL")?"PRAGMA journal_mode=WAL":"PRAGMA journal_mode=DELETE");
    sql(db,"CREATE TABLE objects(row INTEGER PRIMARY KEY,id INTEGER UNIQUE,parent INTEGER NOT NULL,bytes BLOB NOT NULL);"
     "CREATE TABLE actions(id INTEGER PRIMARY KEY REFERENCES objects(id),operation INTEGER UNIQUE NOT NULL);"
     "CREATE TABLE applications(seq INTEGER PRIMARY KEY,id INTEGER UNIQUE NOT NULL REFERENCES actions(id));"
     "CREATE INDEX dependencies_by_parent ON objects(parent);"
     "CREATE TABLE ready(id INTEGER PRIMARY KEY REFERENCES objects(id));"
     "CREATE TABLE private_state(id INTEGER PRIMARY KEY,scope TEXT,through INTEGER,settings TEXT,root_generation INTEGER);"
     "CREATE TABLE current_view(id INTEGER PRIMARY KEY,scope TEXT,through INTEGER,bytes BLOB);"
     "CREATE TABLE snapshots(id INTEGER PRIMARY KEY,bytes BLOB,device INTEGER,inode INTEGER,mtime INTEGER,ctime INTEGER);"
     "CREATE TABLE pending(id INTEGER PRIMARY KEY,latest INTEGER REFERENCES snapshots(id),frozen INTEGER REFERENCES snapshots(id),operation INTEGER);"
     "CREATE TABLE receipts(id INTEGER PRIMARY KEY,operation INTEGER REFERENCES actions(id),associated INTEGER,root_generation INTEGER);"
     "CREATE TRIGGER immutable_update BEFORE UPDATE ON objects BEGIN SELECT RAISE(ABORT,'immutable'); END;"
     "CREATE TRIGGER immutable_delete BEFORE DELETE ON objects BEGIN SELECT RAISE(ABORT,'immutable'); END;"
     "BEGIN IMMEDIATE; INSERT INTO private_state VALUES(1,'store-A',0,'private-preference',0)");
    object(db,1); apply_object(db,1); object(db,2); /* child parked before first materialization */
    retain(db,file,1); sql(db,"INSERT INTO pending VALUES(1,1,NULL,NULL)"); current_view(db);
    sql(db,"COMMIT"); check(db,sqlite3_close(db)); puts("{\"initialized\":true}");
}
static void transaction(const char *path,const char *what,const char *file) {
    sqlite3 *db=open_db(path,0);
    sql(db,"PRAGMA wal_autocheckpoint=0; PRAGMA cache_size=8; BEGIN IMMEDIATE");
    if (!strcmp(cut,"vfs-write")) writeCut=1;
    if (!strcmp(cut,"vfs-sync")) syncCut=1;
    if (!strcmp(what,"reserve")) {
        assert(matches(db,file) && scalar(db,"SELECT root_generation FROM private_state")==0);
        sql(db,"UPDATE pending SET frozen=latest,operation=4 WHERE id=1 AND operation IS NULL");
    } else if (!strcmp(what,"preview")) {
        retain(db,file,2); at("after-payload");
        sql(db,"UPDATE pending SET latest=2 WHERE id=1");
    } else if (!strcmp(what,"import")) {
        assert(scalar(db,"SELECT operation FROM pending WHERE id=1")==4 && matches(db,file) &&
               scalar(db,"SELECT root_generation FROM private_state")==0);
        object(db,4);
        assert(scalar(db,"SELECT count(*) FROM objects o JOIN pending p ON p.operation=o.id JOIN snapshots s ON s.id=p.frozen WHERE o.bytes=s.bytes")==1);
        at("after-object"); apply_object(db,4); at("after-application");
        if (broken("forget-link")) sql(db,"UPDATE pending SET operation=NULL,frozen=NULL WHERE id=1");
        /* The reserved exact operation link plus actual history is sufficient;
         * no separately persisted "committed" flag is needed. */
    } else if (!strcmp(what,"parent")) { object(db,3); apply_object(db,3); }
    else if (!strcmp(what,"child")) apply_object(db,2);
    else if (!strcmp(what,"delete")) { object(db,5); apply_object(db,5); }
    else if (!strcmp(what,"current_view")) current_view(db);
    else if (!strcmp(what,"invalidate-view")) sql(db,"DELETE FROM current_view");
    else if (!strcmp(what,"foreign-view")) sql(db,"UPDATE current_view SET scope='foreign-store'");
    else if (!strcmp(what,"root")) sql(db,"UPDATE private_state SET root_generation=root_generation+1");
    else { fprintf(stderr,"bad transaction\n"); exit(2); }
    at("before-commit");
    if (!strcmp(cut,"write-full")) failWrite=1;
    int rc=sqlite3_exec(db,"COMMIT",NULL,NULL,NULL);
    if (!strcmp(cut,"write-full")) {
        assert(rc==SQLITE_FULL && failWrite==0);
        if (!sqlite3_get_autocommit(db)) sql(db,"ROLLBACK");
        puts("{\"full\":true}");
    } else { check(db,rc); at("after-commit"); puts("{\"committed\":true}"); }
    check(db,sqlite3_close(db));
}
static void settle(const char *path,const char *file) {
    sqlite3 *db=open_db(path,0);
    int root=(int)scalar(db,"SELECT root_generation FROM private_state");
    int verified=matches(db,file); at("after-verify");
    sql(db,"BEGIN IMMEDIATE");
    int history=exists(db,"applications",4), deleted=exists(db,"applications",5);
    /* 0 is this fixture's captured root incarnation, 1 a replacement. Taking
     * a fresh generation alone must not retarget the old operation. */
    int fresh=root==0 && matches(db,file) && root==scalar(db,"SELECT root_generation FROM private_state");
    if (history && !deleted && ((verified && fresh) || broken("stale-receipt"))) {
        execf(db,"INSERT OR REPLACE INTO receipts VALUES(1,4,1,%d)",root,0);
        at("after-receipt");
        /* Only the old observation is settled. A newer preview stays owned. */
        sql(db,"UPDATE pending SET frozen=NULL,operation=NULL,latest=CASE latest WHEN 1 THEN NULL ELSE latest END WHERE id=1");
    } else if (history && deleted) {
        sql(db,"INSERT OR REPLACE INTO receipts VALUES(1,4,0,NULL)");
        sql(db,"UPDATE pending SET frozen=NULL,operation=NULL,latest=CASE latest WHEN 1 THEN NULL ELSE latest END WHERE id=1");
    }
    at("before-commit");
    if (!strcmp(cut,"write-full")) failWrite=1;
    int rc=sqlite3_exec(db,"COMMIT",NULL,NULL,NULL);
    if (!strcmp(cut,"write-full")) {
        assert(rc==SQLITE_FULL && failWrite==0);
        if (!sqlite3_get_autocommit(db)) sql(db,"ROLLBACK");
    } else check(db,rc);
    at("after-commit");
    printf("{\"history\":%d,\"fresh\":%d,\"deleted\":%d}\n",history,fresh,deleted);
    check(db,sqlite3_close(db));
}
static void delayed_materialization(const char *path) {
    sqlite3 *db=open_db(path,0); if (!broken("split-read")) sql(db,"BEGIN");
    unsigned char values[3]={0}; replay(db,values,0);
    at("after-values");
    int through=(int)scalar(db,"SELECT through FROM private_state");
    if (!broken("split-read")) sql(db,"COMMIT");
    at("after-capture"); sql(db,"BEGIN IMMEDIATE");
    if (through<scalar(db,"SELECT coalesce(max(through),0) FROM current_view")) {
        sql(db,"COMMIT"); check(db,sqlite3_close(db)); puts("{\"materialized\":false}"); return;
    }
    sqlite3_stmt *q=prepare(db,"INSERT OR REPLACE INTO current_view VALUES(1,'store-A',?,?)");
    sqlite3_bind_int(q,1,broken("split-coverage")?(int)scalar(db,"SELECT through FROM private_state"):through);
    sqlite3_bind_blob(q,2,values,3,SQLITE_TRANSIENT); done(db,q); sqlite3_finalize(q);
    sql(db,"COMMIT"); check(db,sqlite3_close(db)); puts("{\"materialized\":true}");
}
static void recover(const char *path) {
    sqlite3 *db=open_db(path,0);
    /* Indexed durable work, not a scan/re-read of accepted object bodies.
     * Queue insertion is in the same transaction as parent acceptance. */
    if (!broken("skip-ready")) {
        while (scalar(db,"SELECT EXISTS(SELECT 1 FROM ready)")) {
            sql(db,"BEGIN IMMEDIATE");
            int id=(int)scalar(db,"SELECT min(id) FROM ready"); apply_object(db,id);
            at("recovery-after-apply"); sql(db,"COMMIT"); at("recovery-after-commit");
        }
    }
    sql(db,"BEGIN");
    unsigned char state[3]={0}; int through=0,materializationUsed=0;
    sqlite3_stmt *q=prepare(db,"SELECT through,bytes FROM current_view WHERE scope='store-A'");
    if (sqlite3_step(q)==SQLITE_ROW) {
        assert(sqlite3_column_bytes(q,1)==3); through=sqlite3_column_int(q,0);
        assert(through<=scalar(db,"SELECT through FROM private_state"));
        memcpy(state,sqlite3_column_blob(q,1),3); materializationUsed=1;
    }
    sqlite3_finalize(q);
    if (broken("insert-order") && materializationUsed) {
        q=prepare(db,"SELECT a.id FROM applications a JOIN objects o ON a.id=o.id WHERE o.row>? ORDER BY a.seq");
        sqlite3_bind_int(q,1,2); /* max stored row at the initial materialization, C included */
        while (sqlite3_step(q)==SQLITE_ROW) reduce(state,sqlite3_column_int(q,0)); sqlite3_finalize(q);
    } else replay(db,state,through);
    q=prepare(db,"INSERT OR REPLACE INTO current_view VALUES(1,'store-A',?,?)");
    sqlite3_bind_int(q,1,(int)scalar(db,"SELECT through FROM private_state"));
    sqlite3_bind_blob(q,2,state,3,SQLITE_TRANSIENT); done(db,q); sqlite3_finalize(q);
    int imported=exists(db,"applications",4), deleted=exists(db,"applications",5);
    int pending=(int)scalar(db,"SELECT count(*) FROM pending WHERE operation=4");
    int receipts=(int)scalar(db,"SELECT count(*) FROM receipts");
    int associated=(int)scalar(db,"SELECT coalesce(max(associated),0) FROM receipts");
    int latest=(int)scalar(db,"SELECT coalesce(latest,0) FROM pending");
    int frozen=(int)scalar(db,"SELECT coalesce(frozen,0) FROM pending");
    assert(scalar(db,"SELECT count(*) FROM pragma_foreign_key_check")==0);
    assert(scalar(db,"SELECT count(*) FROM applications")==scalar(db,"SELECT count(*) FROM actions"));
    assert(scalar(db,"SELECT count(*) FROM actions WHERE id!=operation")==0);
    assert(scalar(db,"SELECT through FROM private_state")==scalar(db,"SELECT max(seq) FROM applications"));
    assert(!imported || pending || receipts);
    assert(scalar(db,"SELECT count(*) FROM private_state WHERE scope='store-A' AND settings='private-preference'")==1);
    int status=imported?(receipts?2:1):0; /* undecided / resume settlement / settled */
    if (broken("replay-consent") && !imported && pending) status=1;
    if (broken("live-only") && deleted) status=0;
    printf("{\"imported\":%d,\"deleted\":%d,\"status\":%d,\"latest\":%d,\"frozen\":%d,\"receipts\":%d,\"associated\":%d,\"materialization_used\":%d,\"through\":%lld,\"values\":[%d,%d,%d]}\n",
        imported,deleted,status,latest,frozen,receipts,associated,materializationUsed,(long long)scalar(db,"SELECT through FROM private_state"),state[0],state[1],state[2]);
    sql(db,"COMMIT"); check(db,sqlite3_close(db));
}
int main(int argc,char **argv) {
    assert(argc>=3); setup_vfs(); cut=getenv("NV_PROTOCOL_CUT"); if (!cut) cut="none";
    policy=getenv("NV_PROTOCOL_POLICY"); if (!policy) policy="safe";
    if (argc==4 && !strcmp(argv[1],"source")) {
        unsigned char data[4096]; payload((uint64_t)atoi(argv[3]),data,4096);
        int fd=open(argv[2],O_WRONLY|O_CREAT|O_TRUNC|O_NOFOLLOW,0600); assert(fd>=0);
        assert(write(fd,data,4096)==4096 && fsync(fd)==0 && close(fd)==0); puts("{\"written\":true}");
    }
    else if (argc==5 && !strcmp(argv[1],"init")) init(argv[2],argv[3],argv[4]);
    else if (argc==5 && !strcmp(argv[1],"transaction")) transaction(argv[2],argv[3],argv[4]);
    else if (argc==4 && !strcmp(argv[1],"settle")) settle(argv[2],argv[3]);
    else if (argc==3 && !strcmp(argv[1],"delayed-materialization")) delayed_materialization(argv[2]);
    else if (argc==3 && !strcmp(argv[1],"recover")) recover(argv[2]);
    else return 2;
    return 0;
}
