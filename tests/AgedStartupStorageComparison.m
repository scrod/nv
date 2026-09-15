/* Synthetic clean-exit locality experiment. Reuse real NV note/search codecs and
 * the existing measured VFS. Actual proposal DDL, but NOT a history validator or
 * the still-unimplemented canonical current-cell/authoring-context codec.
 */
#define NV_STARTUP_EMBED
#include "StartupStorageComparison.m"
#include <zlib.h>
#ifdef NV_PROBE_ZSTD
#include <zstd.h>
#include "ZstdDictionaryExperiment.h"
static ZSTD_DCtx *zstdDecoder;
static ZSTD_CCtx *zstdEncoder;
static void inflateZstd(void *output, size_t outputLength, const void *input, size_t inputLength, BOOL reuse, const unsigned char *dictionaryHash) {
    size_t frame=ZSTD_findFrameCompressedSize(input,inputLength);
    assert(!ZSTD_isError(frame) && frame==inputLength);
    assert(ZSTD_getFrameContentSize(input,inputLength)==outputLength);
    if ((reuse || dictionaryHash) && !zstdDecoder) { zstdDecoder=ZSTD_createDCtx(); assert(zstdDecoder); }
    size_t n;
    if (dictionaryHash) {
        ProbeDictionary *dict=findDictionary(dictionaryHash,input,inputLength);
        n=ZSTD_decompress_usingDDict(zstdDecoder,output,outputLength,input,inputLength,dict->decoder);
        if (ZSTD_isError(n)) dictionaryFailure("dictionary frame decompression failed");
        dictionaryCellCount++;
    } else n=reuse?ZSTD_decompressDCtx(zstdDecoder,output,outputLength,input,inputLength):
        ZSTD_decompress(output,outputLength,input,inputLength);
    assert(!ZSTD_isError(n) && n==outputLength);
}
static NSData *encodeZstd(NSData *record, BOOL cell) {
    assert([record length]<UINT32_C(0x40000000));
    size_t capacity=ZSTD_compressBound([record length]);
    BOOL withDictionary=cell && encodingDictionary>=0;
    size_t prefix=cell?(withDictionary?36:4):0;
    NSMutableData *data=[NSMutableData dataWithLength:capacity+prefix];
    if (!zstdEncoder) { zstdEncoder=ZSTD_createCCtx(); assert(zstdEncoder); }
    int level=cell?atoi(getenv("NV_PROBE_ZSTD_LEVEL")?:"3"):3;
    int minMatch=cell?atoi(getenv("NV_PROBE_ZSTD_MIN_MATCH")?:"0"):0;
    const char *strategy=cell?(getenv("NV_PROBE_ZSTD_STRATEGY")?:"default"):"default";
    assert(!ZSTD_isError(ZSTD_CCtx_reset(zstdEncoder,ZSTD_reset_session_and_parameters)));
    assert(!ZSTD_isError(ZSTD_CCtx_setParameter(zstdEncoder,ZSTD_c_compressionLevel,level)));
    if (minMatch) assert(!ZSTD_isError(ZSTD_CCtx_setParameter(zstdEncoder,ZSTD_c_minMatch,minMatch)));
    if (!strcmp(strategy,"dfast")) assert(!ZSTD_isError(ZSTD_CCtx_setParameter(zstdEncoder,ZSTD_c_strategy,ZSTD_dfast)));
    else assert(!strcmp(strategy,"default"));
    size_t n;
    if (withDictionary) {
        ProbeDictionary *dict=&dictionaries[encodingDictionary]; assert(dict->encoder);
        n=ZSTD_compress_usingCDict(zstdEncoder,(unsigned char *)[data mutableBytes]+prefix,capacity,[record bytes],[record length],dict->encoder);
        memcpy((unsigned char *)[data mutableBytes]+4,dict->hash,32);
    } else n=ZSTD_compress2(zstdEncoder,(unsigned char *)[data mutableBytes]+prefix,capacity,[record bytes],[record length]);
    assert(!ZSTD_isError(n));
    uint32_t length=(uint32_t)[record length]|UINT32_C(0x80000000)|(withDictionary?UINT32_C(0x40000000):0);
    if (cell && n+prefix>=4+[record length]) { length=0; [data setLength:4]; [data appendData:record]; }
    else [data setLength:n+prefix];
    if (cell) { length=CFSwapInt32HostToLittle(length); memcpy([data mutableBytes],&length,4); }
    return data;
}
#endif

// Experiment-only per-cell wrapper. One scratch cell, never a collection cache.
static BOOL cellCompression;
static NSData *encodeCellAtLevel(NSData *record, int level) {
    if (!cellCompression) return record;
    uLongf capacity=compressBound([record length]);
    NSMutableData *encoded=[NSMutableData dataWithLength:4+capacity];
    assert(compress2((Bytef *)[encoded mutableBytes]+4,&capacity,[record bytes],[record length],level)==Z_OK);
    uint32_t length=CFSwapInt32HostToLittle((uint32_t)[record length]);
    if (capacity >= [record length]) { length=0; [encoded setLength:4]; [encoded appendData:record]; }
    else [encoded setLength:4+capacity];
    memcpy([encoded mutableBytes],&length,4); return encoded;
}
static NSData *encodeCell(NSData *record) {
#ifdef NV_PROBE_ZSTD
    if (!strcmp(getenv("NV_PROBE_CELL_CODEC")?:"raw","zstd")) return encodeZstd(record,YES);
#endif
    return encodeCellAtLevel(record,Z_BEST_SPEED);
}
static NSData *decodeCell(const void *bytes, NSUInteger count) {
    assert(count>=4); uint32_t length; memcpy(&length,bytes,4); length=CFSwapInt32LittleToHost(length);
    if (!length) return [NSData dataWithBytes:(const unsigned char *)bytes+4 length:count-4];
    BOOL zstd=(length&UINT32_C(0x80000000))!=0, dict=(length&UINT32_C(0x40000000))!=0;
    length&=UINT32_C(0x3fffffff); NSUInteger prefix=dict?36:4; assert(count>=prefix && (!dict || zstd));
    assert(length<=32*1024*1024); // Fixture bound, not a production format limit.
    NSMutableData *record=[NSMutableData dataWithLength:length]; uLongf n=length; uLong input=count-4;
    if (zstd) {
#ifdef NV_PROBE_ZSTD
        inflateZstd([record mutableBytes],length,(const Bytef *)bytes+prefix,count-prefix,NO,dict?(const Bytef *)bytes+4:NULL); return record;
#else
        assert(!"compile with --zstd-prefix for zstd cells");
#endif
    }
    assert(uncompress2([record mutableBytes],&n,(const Bytef *)bytes+4,&input)==Z_OK && n==length && input==count-4);
    return record;
}
static unsigned char *cellScratch; static size_t cellCapacity;
static z_stream cellStream; static BOOL streamInitialized;
static const unsigned char *decodeCellBytes(const unsigned char *bytes, NSUInteger *count) {
    const char *mode=getenv("NV_PROBE_CELL_DECODER")?:"allocate";
    if (!strcmp(mode,"allocate")) { NSData *data=decodeCell(bytes,*count); *count=[data length]; return [data bytes]; }
    assert(!strcmp(mode,"scratch") || !strcmp(mode,"stream"));
    assert(*count>=4); uint32_t length; memcpy(&length,bytes,4); length=CFSwapInt32LittleToHost(length);
    NSUInteger inputLength=*count-4;
    if (!length) { *count=inputLength; return bytes+4; }
    BOOL zstd=(length&UINT32_C(0x80000000))!=0, dict=(length&UINT32_C(0x40000000))!=0;
    length&=UINT32_C(0x3fffffff); NSUInteger prefix=dict?36:4; assert(*count>=prefix && (!dict || zstd));
    inputLength=*count-prefix;
    assert(length<=32*1024*1024);
    if (cellCapacity<length) { cellScratch=realloc(cellScratch,length); assert(cellScratch); cellCapacity=length; }
    if (zstd) {
#ifdef NV_PROBE_ZSTD
        inflateZstd(cellScratch,length,bytes+prefix,inputLength,!strcmp(mode,"stream"),dict?bytes+4:NULL);
#else
        assert(!"compile with --zstd-prefix for zstd cells");
#endif
    } else if (!strcmp(mode,"scratch")) {
        uLongf n=length; uLong input=inputLength;
        assert(uncompress2(cellScratch,&n,bytes+4,&input)==Z_OK && n==length && input==inputLength);
    } else {
        if (!streamInitialized) { assert(inflateInit(&cellStream)==Z_OK); streamInitialized=YES; }
        else assert(inflateReset(&cellStream)==Z_OK);
        cellStream.next_in=(Bytef *)bytes+4; cellStream.avail_in=(uInt)inputLength;
        cellStream.next_out=cellScratch; cellStream.avail_out=length;
        assert(inflate(&cellStream,Z_FINISH)==Z_STREAM_END && cellStream.total_out==length && cellStream.avail_in==0);
    }
    *count=length; return cellScratch;
}

static uint64_t rngNext(uint64_t *s) {
    *s = *s * UINT64_C(6364136223846793005) + UINT64_C(1442695040888963407); return *s;
}
static NSString *textScalar(sqlite3 *db, const char *query) {
    sqlite3_stmt *q=prepare(db,query); assert(sqlite3_step(q)==SQLITE_ROW);
    NSString *s=[NSString stringWithUTF8String:(const char *)sqlite3_column_text(q,0)];
    assert(sqlite3_step(q)==SQLITE_DONE); sqlite3_finalize(q); return s;
}
static void assertClean(NSString *file) {
    struct stat st;
    if (stat([[file stringByAppendingString:@"-wal"] fileSystemRepresentation],&st)==0) assert(st.st_size==0);
}
static double cleanClose(sqlite3 *db, NSString *file) {
    double start=now(); int frames=-1, copied=-1;
    check(db,sqlite3_wal_checkpoint_v2(db,NULL,SQLITE_CHECKPOINT_TRUNCATE,&frames,&copied));
    assert(frames==0 && copied==0); check(db,sqlite3_close(db)); assertClean(file);
    return (now()-start)*1000;
}
static NSData *agedRecordForPattern(NSUInteger slot, NSUInteger round, NSUInteger count, NSUInteger length,
                         uint64_t birth, NSUInteger contextBytes, const char *pattern) {
    NoteObject *note=newNote(slot+round*count,length); unsigned char key[32]; identity(birth,key);
    memcpy([note uniqueNoteIDBytes],key,16);
    NSMutableData *data=[NSMutableData dataWithData:encodeNote(note)];
    if (!strcmp(pattern,"random") || !strcmp(pattern,"mixed")) {
        // Printable random ASCII, same UTF-8 byte length as the word fixture.
        // Deliberately harder to compress; not a claim of typical note content.
        const unsigned char *begin=[data bytes], *p=begin+32, *end=begin+[data length];
        (void)takeString(&p,end); (void)takeString(&p,end); NSUInteger prefix=p-begin;
        uint32_t bytes; memcpy(&bytes,p,4); bytes=CFSwapInt32LittleToHost(bytes);
        NSMutableData *random=[NSMutableData dataWithLength:bytes]; uint64_t rng=birth+round*count+71;
        for (NSUInteger i=0;i<bytes;i++) ((unsigned char *)[random mutableBytes])[i]=(unsigned char)(33+((rngNext(&rng)>>32)%94));
        NSString *bodyString=[[[NSString alloc] initWithData:random encoding:NSUTF8StringEncoding] autorelease]; assert(bodyString);
#ifdef NV_PROBE_ZSTD
        if (!strcmp(pattern,"mixed")) bodyString=mixedProbeBody(birth+round*count+slot*71,length);
#endif
        [data setLength:prefix]; appendString(data,bodyString);
    }
    // Synthetic fixed-width references: measure reading/allocation, not causal validation.
    uint32_t n=CFSwapInt32HostToLittle((uint32_t)contextBytes); [data appendBytes:&n length:4];
    for (NSUInteger i=0;i<contextBytes;i+=32) {
        identity(birth+round+i,key); [data appendBytes:key length:MIN((NSUInteger)32,contextBytes-i)];
    }
    return data;
}
static NSData *agedRecord(NSUInteger slot, NSUInteger round, NSUInteger count, NSUInteger length,
                         uint64_t birth, NSUInteger contextBytes) {
    return agedRecordForPattern(slot,round,count,length,birth,contextBytes,getenv("NV_PROBE_BODY_PATTERN")?:"words");
}
static void storeCurrent(sqlite3 *db, sqlite3_stmt *q, NSData *record) {
    check(db,sqlite3_bind_blob(q,1,[record bytes],16,SQLITE_TRANSIENT));
    NSData *cell=encodeCell(record);
    check(db,sqlite3_bind_blob(q,2,[cell bytes],(int)[cell length],SQLITE_TRANSIENT)); done(db,q);
}
static void storeHistory(sqlite3 *db, sqlite3_stmt *q, uint64_t number, NSData *record) {
    unsigned char id[32], epoch[32], bytes[4096]; identity(number,id); identity(991,epoch);
    uint64_t seq=CFSwapInt64HostToBig(number);
    sqlite3_bind_blob(q,1,id,32,SQLITE_TRANSIENT); sqlite3_bind_blob(q,2,epoch,16,SQLITE_TRANSIENT);
    sqlite3_bind_blob(q,3,&seq,8,SQLITE_TRANSIENT);
    if (record) sqlite3_bind_blob(q,4,[record bytes],(int)[record length],SQLITE_TRANSIENT);
    else { payload(number,bytes,sizeof(bytes)); sqlite3_bind_blob(q,4,bytes,sizeof(bytes),SQLITE_TRANSIENT); }
    done(db,q);
}
static void seedAged(NSString *root, NSString *ddl, NSUInteger count, NSUInteger body,
                     NSUInteger history, NSUInteger rounds, NSUInteger contextBytes, NSUInteger holeInterval) {
    NSString *file=path(root,@"store.sqlite"); sqlite3 *db=open_db([file fileSystemRepresentation],1);
    sql(db,"PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA wal_autocheckpoint=1000;");
    NSString *schemaText=[NSString stringWithContentsOfFile:ddl encoding:NSUTF8StringEncoding error:NULL]; assert(schemaText);
    sql(db,[schemaText UTF8String]);
    sqlite3_stmt *hist=prepare(db,"INSERT INTO objects(object_id,kind,writer_epoch,sequence,encoded) VALUES(?,1,?,?,?)");
    sqlite3_stmt *upsert=prepare(db,"INSERT INTO current_notes VALUES(?,?) ON CONFLICT(birth) DO UPDATE SET cell=excluded.cell");
    sqlite3_stmt *del=prepare(db,"DELETE FROM current_notes WHERE birth=?");
    sqlite3_stmt *scratch=prepare(db,"INSERT INTO private_groups VALUES(?,1,1,zeroblob(16384))");
    uint64_t object=0, nextBirth=count+1, rng=7821; NSUInteger deletions=0;
    uint64_t *births=calloc(count,sizeof(*births)); NSUInteger *order=calloc(count,sizeof(*order)); assert(births && order);
    NSMutableArray *expected=[NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i=0;i<count;i++) { births[i]=i+1; order[i]=i; [expected addObject:[NSNull null]]; }
    double start=now(); sql(db,"BEGIN");
    for (NSUInteger i=0;i<history;i++) {
        storeHistory(db,hist,++object,nil); if (i%256==255) sql(db,"COMMIT; BEGIN");
    }
    sql(db,"COMMIT");
    for (NSUInteger round=0;round<=rounds;round++) {
        for (NSUInteger i=count-1;i>0;i--) { NSUInteger j=(NSUInteger)(rngNext(&rng)%(i+1)), t=order[i]; order[i]=order[j]; order[j]=t; }
        sql(db,"BEGIN");
        for (NSUInteger step=0;step<count;step++) {
            @autoreleasepool {
                NSUInteger slot=order[step];
                if (round && rngNext(&rng)%10==0) {
                    unsigned char id[32]; identity(births[slot],id); sqlite3_bind_blob(del,1,id,16,SQLITE_TRANSIENT); done(db,del);
                    assert(sqlite3_changes(db)==1); births[slot]=nextBirth++; deletions++;
                }
                NSUInteger sizeClass=(NSUInteger)((rngNext(&rng)>>32)%10);
                NSUInteger length=MAX((NSUInteger)80,sizeClass<4?body/4:sizeClass<7?body:sizeClass<9?body*2:body*4);
                NSData *record=agedRecord(slot,round,count,length,births[slot],contextBytes);
                storeHistory(db,hist,++object,record); storeCurrent(db,upsert,record);
                if (holeInterval && (round*count+step)%holeInterval==0) {
                    unsigned char id[32]; identity(object,id); sqlite3_bind_blob(scratch,1,id,16,SQLITE_TRANSIENT); done(db,scratch);
                }
                [expected replaceObjectAtIndex:slot withObject:record];
            }
            if (step%256==255) sql(db,"COMMIT; BEGIN");
        }
        sql(db,"COMMIT");
    }
    sqlite3_finalize(hist); sqlite3_finalize(upsert); sqlite3_finalize(del); sqlite3_finalize(scratch); free(births); free(order);
    // The oracle comes from the generated workload, NOT from decoding database rows.
    NSArray *sorted=[expected sortedArrayUsingComparator:^NSComparisonResult(NSData *a, NSData *b) {
        int c=memcmp([a bytes],[b bytes],16); return c<0?NSOrderedAscending:c>0?NSOrderedDescending:NSOrderedSame;
    }];
    NSMutableData *flat=[NSMutableData data]; uint64_t n=CFSwapInt64HostToLittle(count); [flat appendBytes:&n length:8];
    for (NSData *record in sorted) [flat appendData:record];
    writeFile(flat,path(root,@"expected.dat"));
    // Retained solely as an experimental baseline; not an adopted cache format.
    sql(db,"CREATE TABLE benchmark_packed(name TEXT PRIMARY KEY, value BLOB NOT NULL); BEGIN");
    sqlite3_stmt *q=prepare(db,"INSERT INTO benchmark_packed VALUES(?,?)");
    for (NSString *name in @[@"flat",@"compressed"]) {
        NSData *data=[name isEqual:@"flat"]?flat:[flat compressedData];
        sqlite3_bind_text(q,1,[name UTF8String],-1,SQLITE_TRANSIENT);
        sqlite3_bind_blob(q,2,[data bytes],(int)[data length],SQLITE_TRANSIENT); done(db,q);
    }
#ifdef NV_PROBE_ZSTD
    // Same mature-placement advantage as the existing packed control. Build it
    // before releasing private buffers, never silently compare a scattered copy.
    NSData *zstdPacked=encodeZstd(flat,NO);
    sqlite3_bind_text(q,1,"zstd",-1,SQLITE_STATIC);
    sqlite3_bind_blob(q,2,[zstdPacked bytes],(int)[zstdPacked length],SQLITE_TRANSIENT); done(db,q);
#endif
    sqlite3_finalize(q); sql(db,"COMMIT");
    // Optional stress: settled private payloads leave holes among history pages.
    // Release AFTER making the comparison BLOB, so it cannot consume these holes.
    if (holeInterval) sql(db,"DELETE FROM private_groups");
    int64_t freePages=scalar(db,"PRAGMA freelist_count");
    double quit=cleanClose(db,file);
    emit(@{@"kind":@"aged-seed",@"notes":@(count),@"rounds":@(rounds),@"updates":@(count*(rounds+1)),
        @"delete_recreate":@(deletions),@"history_objects":@(object),@"context_bytes_per_note":@(contextBytes),
        @"hole_interval":@(holeInterval),@"free_pages_after_private_release":@(freePages),
        @"encoded_bytes":@([flat length]),@"seed_ms":@((now()-start)*1000),@"clean_close_ms":@(quit)});
}
static void layoutAged(NSString *file, NSString *layout) {
    assertClean(file); sqlite3 *db=open_db([file fileSystemRepresentation],0); double start=now();
    int rewriteCache=atoi(getenv("NV_PROBE_REWRITE_CACHE_KIB")?:"0");
    if (rewriteCache) sql(db,[[NSString stringWithFormat:@"PRAGMA cache_size=-%d",rewriteCache] UTF8String]);
    if (!strcmp(getenv("NV_PROBE_REWRITE_SPILL")?:"default","off")) sql(db,"PRAGMA cache_spill=OFF");
    if (!strcmp(getenv("NV_PROBE_REWRITE_SECURE_DELETE")?:"default","off")) sql(db,"PRAGMA secure_delete=OFF");
    int chunk=atoi(getenv("NV_PROBE_REWRITE_CHUNK_MIB")?:"0")*1024*1024;
    if (chunk) check(db,sqlite3_file_control(db,"main",SQLITE_FCNTL_CHUNK_SIZE,&chunk));
    // Repeated experiments invalidate/rebuild only this disposable I/O hint.
    sql(db,"DROP TABLE IF EXISTS benchmark_read_hint");
    BOOL hinted=[layout isEqual:@"hinted"] || [layout hasSuffix:@"-hinted"];
    NSString *base=[layout hasSuffix:@"-hinted"]?[layout substringToIndex:[layout length]-7]:layout;
    double rewriteSeconds=0, hintSeconds=0, recodeSeconds=0, encodeSeconds=0; uint64_t reservationBytes=0; NSUInteger rowCellOpcodes=0;
    int64_t freeBefore=scalar(db,"PRAGMA freelist_count");
#ifdef NV_PROBE_ZSTD
    NSData *trained=nil; NSUInteger dictSize=(NSUInteger)atoi(getenv("NV_PROBE_DICTIONARY_SIZE")?:"0");
    loadDictionaries(db);
    if (dictSize) {
        assert([base hasPrefix:@"recompressed"]);
        const char *training=getenv("NV_PROBE_DICTIONARY_TRAINING")?:"held-out";
        trained=strcmp(training,"held-out")?
            trainCurrentDictionary(db,dictSize,!strcmp(training,"all-current")):
            trainProbeDictionary(getenv("NV_PROBE_DICTIONARY_PATTERN")?:"words",0,dictSize);
    }
    double dictionarySetupSeconds=now()-start; start=now();
#endif
    if ([base isEqual:@"rebuilt"] || [base isEqual:@"birth-order"] || [base isEqual:@"deferred-index"] || [base isEqual:@"bounded-reserved"] ||
        [base isEqual:@"deferred-birth"] || [base isEqual:@"recycled"] || [base hasPrefix:@"reserved"] || [base isEqual:@"contiguous-pool"] || [base isEqual:@"transfer"] || [base isEqual:@"reverse-rowid"]) {
        BOOL bounded=[base isEqual:@"bounded-reserved"];
        BOOL reserve=[base hasPrefix:@"reserved"] || [base isEqual:@"contiguous-pool"] || bounded;
        BOOL deferred=[base hasPrefix:@"deferred"] || [base isEqual:@"reserved"] || [base isEqual:@"contiguous-pool"] || bounded;
        BOOL recycled=[base isEqual:@"recycled"];
        NSString *order=([base isEqual:@"birth-order"] || [base isEqual:@"deferred-birth"])?@"birth":@"rowid";
        // Same column/constraint definitions, retained in the original DDL.
        NSString *definition=textScalar(db,"SELECT sql FROM sqlite_schema WHERE name='current_notes'");
        NSRange fields=[definition rangeOfString:@"("]; assert(fields.location!=NSNotFound);
        definition=[@"CREATE TABLE rebuilt_current " stringByAppendingString:[definition substringFromIndex:fields.location]];
        // Exact NOT NULL/CHECK constraints retained; restore uniqueness before COMMIT.
        if (deferred) {
            assert(scalar(db,"SELECT count(*) FROM pragma_index_list('current_notes') WHERE [unique]=1")==1);
            definition=[definition stringByReplacingOccurrencesOfString:@"NOT NULL UNIQUE" withString:@"NOT NULL"];
        }
        sql(db,"PRAGMA temp_store=MEMORY; BEGIN");
        if (recycled) sql(db,"CREATE TEMP TABLE source_current AS SELECT rowid AS original_rowid,birth,cell FROM current_notes; DROP TABLE current_notes");
        if (reserve) {
            // Diagnostic only: O(freelist) writes, NOT a proposed quit requirement.
            sql(db,"CREATE TABLE benchmark_reservation(bytes BLOB)");
            sqlite3_stmt *q=prepare(db,"INSERT INTO benchmark_reservation VALUES(zeroblob(?))");
            int64_t freePages, pageSize=scalar(db,"PRAGMA page_size"); NSUInteger attempts=0;
            uint64_t budget=(uint64_t)atoi(getenv("NV_PROBE_RESERVE_BUDGET_MIB")?:"16")*1024*1024;
            while ((freePages=scalar(db,"PRAGMA freelist_count"))>0 && (!bounded || reservationBytes<budget)) {
                assert(attempts++<(NSUInteger)freeBefore+1); int amount=(int)(MIN(freePages,64)*pageSize);
                if (bounded) amount=(int)MIN((uint64_t)amount,budget-reservationBytes);
                sqlite3_bind_int(q,1,amount); done(db,q); reservationBytes+=amount;
            }
            sqlite3_finalize(q);
            if ([base isEqual:@"contiguous-pool"]) {
                // Leave a contiguous free extent rather than a zero-length freelist.
                int64_t amount=2*scalar(db,"SELECT sum(pgsize) FROM dbstat WHERE name='current_notes'");
                sql(db,"CREATE TABLE benchmark_extent(bytes BLOB)");
                q=prepare(db,"INSERT INTO benchmark_extent VALUES(zeroblob(?))");
                sqlite3_bind_int64(q,1,amount); done(db,q); sqlite3_finalize(q);
                reservationBytes+=amount; sql(db,"DROP TABLE benchmark_extent");
            }
        }
        sql(db,[definition UTF8String]);
        NSString *copy=recycled?@"INSERT INTO rebuilt_current SELECT birth,cell FROM source_current ORDER BY original_rowid":
            [base isEqual:@"transfer"]?@"INSERT INTO rebuilt_current SELECT * FROM current_notes":
            [base isEqual:@"reverse-rowid"]?@"INSERT INTO rebuilt_current(rowid,birth,cell) SELECT rowid,birth,cell FROM current_notes ORDER BY rowid DESC":
            [NSString stringWithFormat:@"INSERT INTO rebuilt_current SELECT birth,cell FROM current_notes ORDER BY %@",order];
        sqlite3_stmt *explain=prepare(db,[[ @"EXPLAIN " stringByAppendingString:copy] UTF8String]); int explainRC;
        while ((explainRC=sqlite3_step(explain))==SQLITE_ROW) rowCellOpcodes+=!strcmp((const char *)sqlite3_column_text(explain,1),"RowCell");
        assert(explainRC==SQLITE_DONE); sqlite3_finalize(explain);
        sql(db,[copy UTF8String]);
        if (deferred) {
            int64_t root=scalar(db,"SELECT rootpage FROM sqlite_schema WHERE name='rebuilt_current'");
            sql(db,[[NSString stringWithFormat:@"CREATE UNIQUE INDEX rebuilt_birth_%lld ON rebuilt_current(birth)",(long long)root] UTF8String]);
        }
        if (!recycled) sql(db,"DROP TABLE current_notes");
        else sql(db,"DROP TABLE source_current");
        sql(db,"ALTER TABLE rebuilt_current RENAME TO current_notes");
        if (reserve) sql(db,"DROP TABLE benchmark_reservation");
        sql(db,"COMMIT");
    } else if ([base isEqual:@"level6-compacted"] || [base hasPrefix:@"recompressed"]) {
        assert(cellCompression);
        NSString *definition=textScalar(db,"SELECT sql FROM sqlite_schema WHERE name='current_notes'");
        NSRange fields=[definition rangeOfString:@"("]; assert(fields.location!=NSNotFound);
        definition=[@"CREATE TABLE six_current " stringByAppendingString:[definition substringFromIndex:fields.location]];
        sql(db,"BEGIN"); sql(db,[definition UTF8String]);
#ifdef NV_PROBE_ZSTD
        if (trained) encodingDictionary=(int)installDictionary(db,trained);
#endif
        sqlite3_stmt *source=prepare(db,"SELECT birth,cell FROM current_notes ORDER BY rowid");
        sqlite3_stmt *destination=prepare(db,"INSERT INTO six_current VALUES(?,?)"); int rc;
        while ((rc=sqlite3_step(source))==SQLITE_ROW) { @autoreleasepool {
            NSData *decoded=decodeCell(sqlite3_column_blob(source,1),(NSUInteger)sqlite3_column_bytes(source,1));
            double encoding=now();
            NSData *encoded=[base isEqual:@"level6-compacted"]?encodeCellAtLevel(decoded,Z_DEFAULT_COMPRESSION):encodeCell(decoded);
            encodeSeconds+=now()-encoding;
            sqlite3_bind_blob(destination,1,sqlite3_column_blob(source,0),16,SQLITE_TRANSIENT);
            sqlite3_bind_blob(destination,2,[encoded bytes],(int)[encoded length],SQLITE_TRANSIENT); done(db,destination);
        } }
        assert(rc==SQLITE_DONE); sqlite3_finalize(source); sqlite3_finalize(destination);
        sql(db,"DROP TABLE current_notes; ALTER TABLE six_current RENAME TO current_notes; COMMIT");
        recodeSeconds=now()-start;
        if ([base hasSuffix:@"compacted"]) sql(db,"VACUUM");
    } else if ([base isEqual:@"compacted"]) sql(db,"VACUUM");
    else assert([base isEqual:@"aged"] || [base isEqual:@"hinted"]);
    rewriteSeconds=now()-start;
    if (hinted) {
        double hintStart=now();
        assert(sqlite3_compileoption_used("ENABLE_DBSTAT_VTAB"));
        // A physical read-order hint, never data or evidence of current values.
        // No all-database DBSTAT traversal: constrain the one current B-tree.
        sql(db,"BEGIN; CREATE TABLE benchmark_read_hint(pages BLOB NOT NULL)");
        sqlite3_stmt *q=prepare(db,"SELECT pageno FROM dbstat WHERE name='current_notes' ORDER BY pageno");
        NSMutableData *pages=[NSMutableData data]; int rc;
        while ((rc=sqlite3_step(q))==SQLITE_ROW) {
            uint64_t p=CFSwapInt64HostToLittle((uint64_t)sqlite3_column_int64(q,0)); [pages appendBytes:&p length:8];
        }
        assert(rc==SQLITE_DONE); sqlite3_finalize(q);
        q=prepare(db,"INSERT INTO benchmark_read_hint VALUES(?)");
        sqlite3_bind_blob(q,1,[pages bytes],(int)[pages length],SQLITE_TRANSIENT); done(db,q); sqlite3_finalize(q);
        sql(db,"COMMIT"); hintSeconds=now()-hintStart;
    }
    double maintenance=(now()-start)*1000;
    int spills=0, ignored=0; check(db,sqlite3_db_status(db,SQLITE_DBSTATUS_CACHE_SPILL,&spills,&ignored,0));
    NSMutableDictionary *info=[NSMutableDictionary dictionaryWithDictionary:@{@"kind":@"layout",@"layout":layout,
        @"page_size":@(scalar(db,"PRAGMA page_size")),@"pages":@(scalar(db,"PRAGMA page_count")),
        @"free_pages":@(scalar(db,"PRAGMA freelist_count")),@"maintenance_ms":@(maintenance),
        @"free_before":@(freeBefore),@"rewrite_ms":@(rewriteSeconds*1000),@"hint_build_ms":@(hintSeconds*1000),@"reservation_bytes":@(reservationBytes),
        @"rowcell_opcodes":@(rowCellOpcodes),
        @"rewrite_cache_kib":@(rewriteCache),@"rewrite_cache_setting":@(scalar(db,"PRAGMA cache_size")),
        @"rewrite_cache_spill":@(spills),@"rewrite_chunk_bytes":@(chunk),
        @"secure_delete":@(scalar(db,"PRAGMA secure_delete")),
        @"recode_ms":@(recodeSeconds*1000),
        @"encode_ms":@(encodeSeconds*1000),@"zstd_level":@(atoi(getenv("NV_PROBE_ZSTD_LEVEL")?:"3")),
        @"zstd_min_match":@(atoi(getenv("NV_PROBE_ZSTD_MIN_MATCH")?:"0")),@"zstd_strategy":@(getenv("NV_PROBE_ZSTD_STRATEGY")?:"default"),
        @"sqlite":@(sqlite3_libversion())}];
#ifdef NV_PROBE_ZSTD
    [info addEntriesFromDictionary:@{@"dictionary_size":@(dictSize),@"dictionary_bytes":@(dictionaryBytes),
        @"dictionary_pattern":@(getenv("NV_PROBE_DICTIONARY_PATTERN")?:"words"),
        @"dictionary_training":@(getenv("NV_PROBE_DICTIONARY_TRAINING")?:"held-out"),
        @"dictionary_sample_limit":@(atoi(getenv("NV_PROBE_DICTIONARY_SAMPLE_LIMIT")?:"1024")),
        @"dictionary_sample_budget":@((unsigned long long)strtoull(getenv("NV_PROBE_DICTIONARY_SAMPLE_BUDGET")?:"8388608",NULL,10)),
        @"dictionary_sample_bytes":@(dictionarySampleBytes),@"dictionary_sample_count":@(dictionarySampleCount),
        @"dictionary_training_status":@(dictionaryTrainingStatus),
        @"dictionary_train_ms":@(dictionaryTrainingSeconds*1000),@"dictionary_setup_ms":@(dictionarySetupSeconds*1000),
        @"dictionary_prepare_ms":@(dictionaryPreparationSeconds*1000)}];
#endif
    for (NSString *order in @[@"rowid",@"birth"]) {
        sqlite3_stmt *q=prepare(db,[[NSString stringWithFormat:@"EXPLAIN QUERY PLAN SELECT birth,cell FROM current_notes ORDER BY %@",order] UTF8String]);
        NSMutableArray *plan=[NSMutableArray array]; int rc;
        while ((rc=sqlite3_step(q))==SQLITE_ROW) [plan addObject:@((const char *)sqlite3_column_text(q,3))];
        assert(rc==SQLITE_DONE); sqlite3_finalize(q); [info setObject:plan forKey:[order stringByAppendingString:@"_plan"]];
    }
    if (sqlite3_compileoption_used("ENABLE_DBSTAT_VTAB")) {
        sqlite3_stmt *q=prepare(db,"SELECT count(*),sum(pgsize),sum(payload),sum(unused),sum(pagetype='overflow') FROM dbstat WHERE name='current_notes'");
        assert(sqlite3_step(q)==SQLITE_ROW);
        NSArray *keys=@[@"current_pages",@"current_page_bytes",@"current_payload_bytes",@"current_unused_bytes",@"overflow_pages"];
        for (int i=0;i<5;i++) [info setObject:@(sqlite3_column_int64(q,i)) forKey:keys[i]];
        sqlite3_finalize(q);
        // File offsets, not SSD physical extents. Inspect placement OUTSIDE startup.
        for (NSString *order in @[@"pageno",@"path"]) {
            q=prepare(db,[[NSString stringWithFormat:@"SELECT pageno FROM dbstat WHERE name='current_notes' ORDER BY %@",order] UTF8String]);
            int rc; int64_t previous=0, first=0, last=0, runs=0, longest=0, run=0;
            while ((rc=sqlite3_step(q))==SQLITE_ROW) {
                int64_t page=sqlite3_column_int64(q,0);
                if (!first) first=page;
                if (page!=previous+1) { runs++; run=0; } run++; longest=MAX(longest,run);
                previous=last=page;
            }
            assert(rc==SQLITE_DONE); sqlite3_finalize(q);
            [info setObject:@(runs) forKey:[order stringByAppendingString:@"_runs"]];
            [info setObject:@(longest) forKey:[order stringByAppendingString:@"_longest_run"]];
            if ([order isEqual:@"pageno"]) [info setObject:@(last-first+1) forKey:@"current_span_pages"];
        }
    }
    [info setObject:@(cleanClose(db,file)) forKey:@"clean_close_ms"];
    [info setObject:@(writtenBytes) forKey:@"vfs_written_bytes"]; emit(info);
}
static uint8_t *pageSeen; static size_t trackedPages, trackedPageSize;
static uint64_t distinctPages, seekReads; static off_t readEnd;
static void observeAgedRead(off_t offset, size_t n) {
    if (readEnd>=0 && readEnd!=offset) seekReads++; readEnd=offset+(off_t)n;
    for (size_t p=(size_t)offset/trackedPageSize;p<=((size_t)offset+n-1)/trackedPageSize;p++) {
        assert(p<trackedPages); if (!pageSeen[p]) { pageSeen[p]=1; distinctPages++; }
    }
}
static NSData *takeContext(const unsigned char **p, const unsigned char *end, uint64_t *digest) {
    assert(end-*p>=4); uint32_t n; memcpy(&n,*p,4); *p+=4; n=CFSwapInt32LittleToHost(n);
    assert(n<=65536 && (size_t)(end-*p)>=n); *digest ^= touch(*p,(int)n);
    NSData *data=[NSData dataWithBytes:*p length:n]; *p+=n; return data;
}
static uint64_t prefetchedBytes; static BOOL hintUsed;
static void prefetchCurrent(sqlite3 *db, off_t fileSize) {
    sqlite3_stmt *q=prepare(db,"SELECT pages FROM benchmark_read_hint"); assert(sqlite3_step(q)==SQLITE_ROW);
    NSUInteger length=(NSUInteger)sqlite3_column_bytes(q,0);
    const unsigned char *pages=sqlite3_column_blob(q,0);
    const char *fault=getenv("NV_PROBE_HINT_FAULT")?:"none";
    if (!strcmp(fault,"empty")) length=0;
    if (!strcmp(fault,"malformed") && length) length--;
    if (length%8 || length>8*1024*1024) { sqlite3_finalize(q); return; }
    NSUInteger count=length/8;
    NSMutableData *wrong=nil;
    if (!strcmp(fault,"wrong-pages")) {
        // Valid but unrelated offsets: must never supply note values/coverage.
        wrong=[NSMutableData dataWithLength:length];
        for (NSUInteger i=0;i<count;i++) { uint64_t p=CFSwapInt64HostToLittle(i+1); memcpy((unsigned char *)[wrong mutableBytes]+8*i,&p,8); }
        pages=[wrong bytes];
    }
    uint64_t checked=0;
    for (NSUInteger i=0;i<count;i++) {
        uint64_t p; memcpy(&p,pages+8*i,8); p=CFSwapInt64LittleToHost(p);
        if (p<=checked || p>(uint64_t)fileSize/trackedPageSize) { sqlite3_finalize(q); return; }
        checked=p;
    }
    // Bounded ciphertext scratch. No SQLite-page interpretation or replacement.
    NSMutableData *ranges=[NSMutableData data];
    size_t amplification=(size_t)atoi(getenv("NV_PROBE_PREFETCH_AMPLIFICATION")?:"1"); assert(amplification>=1 && amplification<=4);
    uint64_t previous=0;
    for (NSUInteger i=0;i<count;) {
        uint64_t first; memcpy(&first,pages+8*i,8); first=CFSwapInt64LittleToHost(first);
        assert(first>previous && first<=(uint64_t)fileSize/trackedPageSize); uint64_t last=first, represented=1; i++;
        while (i<count) {
            uint64_t next; memcpy(&next,pages+8*i,8); next=CFSwapInt64LittleToHost(next);
            assert(next>last);
            if (next-first+1>amplification*(represented+1) || (next-first+1)*trackedPageSize>256*1024) break;
            last=next; represented++; i++;
        }
        assert(last<=(uint64_t)fileSize/trackedPageSize);
        uint64_t range[]={first,last}; [ranges appendBytes:range length:sizeof(range)];
        prefetchedBytes+=(last-first+1)*trackedPageSize;
        previous=last;
    }
    assert(sqlite3_step(q)==SQLITE_DONE); sqlite3_finalize(q);
    assert(prefetchedBytes<=amplification*count*trackedPageSize); hintUsed=count>0;
    const uint64_t *bounds=[ranges bytes]; size_t rangeCount=[ranges length]/16;
    size_t workers=(size_t)atoi(getenv("NV_PROBE_PREFETCH_WORKERS")?:"1"); assert(workers>=1 && workers<=16);
    dispatch_apply(workers,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^(size_t worker) {
        unsigned char *scratch=malloc(256*1024); assert(scratch);
        for (size_t i=worker;i<rangeCount;i+=workers) {
            uint64_t first=bounds[2*i],last=bounds[2*i+1]; size_t amount=(size_t)(last-first+1)*trackedPageSize;
            assert(measuredRead(inputFD,scratch,amount,(off_t)(first-1)*trackedPageSize)==(ssize_t)amount);
        }
        free(scratch);
    });
}
static void readAged(NSString *root, NSString *kind, int cacheKiB, int poolBatch, BOOL decode) {
    NSString *file=path(root,@"store.sqlite"); assertClean(file); inputFD=open([file fileSystemRepresentation],O_RDONLY); assert(inputFD>=0);
    const char *readAhead=getenv("NV_PROBE_READ_AHEAD");
    if (readAhead && !strcmp(readAhead,"off")) assert(fcntl(inputFD,F_RDAHEAD,0)==0);
    struct stat st; assert(fstat(inputFD,&st)==0);
    trackedPageSize=(size_t)atoi(getenv("NV_PROBE_CIPHER_PAGE_SIZE")?:"4096");
    trackedPages=((size_t)st.st_size+trackedPageSize-1)/trackedPageSize; pageSeen=calloc(trackedPages,1); assert(pageSeen);
    readObserver=observeAgedRead; readEnd=-1; uncached=0;
    readMethods=methods; readMethods.xRead=sqliteRead; counting.xOpen=comparisonOpen;
    NSMutableArray *notes=[NSMutableArray array], *contexts=[NSMutableArray array];
    uint64_t before=diskReadCount(), contextDigest=0, encodedBytes=8; double start=now(), decodeSeconds=0, inflateSeconds=0, constructSeconds=0;
    sqlite3 *db=NULL; check(db,sqlite3_open_v2([file fileSystemRepresentation],&db,SQLITE_OPEN_READONLY,counting.zName)); key_db(db);
    sql(db,[[NSString stringWithFormat:@"PRAGMA mmap_size=0; PRAGMA cache_size=-%d; PRAGMA temp_store=MEMORY; BEGIN",cacheKiB] UTF8String]);
    double opened=now(); sqlite3_stmt *q; NSUInteger rowCount=0; int rc;
    BOOL rows=[kind isEqual:@"table"] || [kind isEqual:@"uuid"] || [kind isEqual:@"table-prefetch"];
    double dictionaryLoadSeconds=0;
#ifdef NV_PROBE_ZSTD
    double dictionaryStart=now(); if (rows) loadDictionaries(db); dictionaryLoadSeconds=now()-dictionaryStart;
#endif
    const char *query=[kind isEqual:@"uuid"]?"SELECT birth,cell FROM current_notes ORDER BY birth":"SELECT birth,cell FROM current_notes ORDER BY rowid";
    double prefetchStart=now();
    if ([kind isEqual:@"table-prefetch"]) prefetchCurrent(db,st.st_size);
    double prefetchSeconds=now()-prefetchStart;
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
    NSData *packed=nil;
    if (rows) {
        q=prepare(db,query);
        while ((rc=sqlite3_step(q))==SQLITE_ROW) {
            const unsigned char *p=sqlite3_column_blob(q,1), *end=p+sqlite3_column_bytes(q,1);
            encodedBytes+=(uint64_t)(end-p); double t=now();
            if (cellCompression) { NSUInteger length=(NSUInteger)(end-p); p=decodeCellBytes(p,&length); end=p+length; }
            double inflated=now(); inflateSeconds+=inflated-t;
            assert(sqlite3_column_bytes(q,0)==16 && end-p>=16 && !memcmp(sqlite3_column_blob(q,0),p,16));
            if (decode) { [notes addObject:decodeNote(&p,end)]; [contexts addObject:takeContext(&p,end,&contextDigest)]; assert(p==end); }
            else contextDigest ^= touch(p,(int)(end-p));
            double decoded=now(); constructSeconds+=decoded-inflated; decodeSeconds+=decoded-t; rowCount++;
            if (poolBatch && rowCount%(NSUInteger)poolBatch==0) { [pool drain]; pool=[[NSAutoreleasePool alloc] init]; }
        }
        assert(rc==SQLITE_DONE);
    } else {
        assert([kind isEqual:@"flat"] || [kind isEqual:@"compressed"] || [kind isEqual:@"zstd"]);
        q=prepare(db,"SELECT value FROM benchmark_packed WHERE name=?"); sqlite3_bind_text(q,1,[kind UTF8String],-1,SQLITE_TRANSIENT);
        assert(sqlite3_step(q)==SQLITE_ROW); encodedBytes=(uint64_t)sqlite3_column_bytes(q,0);
        packed=[[NSData alloc] initWithBytes:sqlite3_column_blob(q,0) length:(NSUInteger)encodedBytes];
        assert(sqlite3_step(q)==SQLITE_DONE);
    }
    int misses=0, hits=0, high=0; sqlite3_db_status(db,SQLITE_DBSTATUS_CACHE_MISS,&misses,&high,0); sqlite3_db_status(db,SQLITE_DBSTATUS_CACHE_HIT,&hits,&high,0);
    int sorts=sqlite3_stmt_status(q,SQLITE_STMTSTATUS_SORT,0);
    sqlite3_finalize(q); sql(db,"COMMIT"); check(db,sqlite3_close(db)); close(inputFD); inputFD=-1;
    double captured=now(); uint64_t diskBytes=diskReadCount()-before;
    if (!rows) {
        double t=now(); NSData *flat=nil;
        if ([kind isEqual:@"zstd"]) {
#ifdef NV_PROBE_ZSTD
            unsigned long long length=ZSTD_getFrameContentSize([packed bytes],[packed length]); assert(length>0 && length<=512*1024*1024);
            NSMutableData *decoded=[[NSMutableData alloc] initWithLength:(NSUInteger)length];
            inflateZstd([decoded mutableBytes],(size_t)length,[packed bytes],[packed length],YES,NULL); flat=decoded;
#else
            assert(!"compile with --zstd-prefix for packed zstd");
#endif
        } else flat=[[kind isEqual:@"compressed"]?[packed uncompressedData]:packed retain];
        double inflated=now(); inflateSeconds+=inflated-t;
        const unsigned char *p=[flat bytes], *end=p+[flat length]; assert(end-p>=8); uint64_t n; memcpy(&n,p,8); p+=8;
        n=CFSwapInt64LittleToHost(n); assert(n<=100000);
        if (decode) for (uint64_t i=0;i<n;i++) {
            [notes addObject:decodeNote(&p,end)]; [contexts addObject:takeContext(&p,end,&contextDigest)];
            if (poolBatch && (i+1)%(NSUInteger)poolBatch==0) { [pool drain]; pool=[[NSAutoreleasePool alloc] init]; }
        }
        else { contextDigest=touch(p,(int)(end-p)); p=end; }
        assert(p==end); rowCount=(NSUInteger)n; [flat release]; double decoded=now();
        constructSeconds+=decoded-inflated; decodeSeconds+=decoded-t;
    }
    free(cellScratch); if (streamInitialized) assert(inflateEnd(&cellStream)==Z_OK);
#ifdef NV_PROBE_ZSTD
    ZSTD_freeDCtx(zstdDecoder); zstdDecoder=NULL;
    uint64_t loadedDictionaryBytes=dictionaryBytes, loadedDictionaryCount=dictionaryCount; clearDictionaries();
#endif
    [pool drain]; [packed release]; double searchStart=now(); uint64_t hitsCount=0;
    for (NoteObject *note in notes) {
        [note updateContentCacheCStringIfNecessary]; assert(note->cContents && note->cTitle && note->cLabels);
        hitsCount += strstr(note->cContents,"coffee")!=NULL;
        hitsCount += strstr(note->cTitle,"research")!=NULL; hitsCount += strstr(note->cLabels,"topic")!=NULL;
    }
    double finish=now(); struct rusage usage; assert(getrusage(RUSAGE_SELF,&usage)==0);
    // Exact, order-independent oracle check AFTER timing and RSS sampling.
    if (decode) {
        NSMutableDictionary *actual=[NSMutableDictionary dictionaryWithCapacity:rowCount];
        for (NSUInteger i=0;i<rowCount;i++) {
            NoteObject *note=[notes objectAtIndex:i]; NSMutableData *record=[NSMutableData dataWithData:encodeNote(note)];
            NSData *ctx=[contexts objectAtIndex:i]; uint32_t n=CFSwapInt32HostToLittle((uint32_t)[ctx length]);
            [record appendBytes:&n length:4]; [record appendData:ctx];
            NSData *key=[NSData dataWithBytes:[note uniqueNoteIDBytes] length:16]; assert(![actual objectForKey:key]); [actual setObject:record forKey:key];
        }
        NSData *expected=[NSData dataWithContentsOfFile:path(root,@"expected.dat")];
        const unsigned char *p=[expected bytes], *end=p+[expected length]; uint64_t n; assert(end-p>=8); memcpy(&n,p,8); p+=8;
        assert(CFSwapInt64LittleToHost(n)==rowCount);
        for (NSUInteger i=0;i<rowCount;i++) { @autoreleasepool {
            const unsigned char *begin=p; (void)decodeNote(&p,end); uint64_t ignored=0; (void)takeContext(&p,end,&ignored);
            NSData *key=[NSData dataWithBytes:begin length:16], *record=[NSData dataWithBytes:begin length:(NSUInteger)(p-begin)];
            assert([[actual objectForKey:key] isEqual:record]);
        } }
        assert(p==end);
    }
    assert(walReads==0); free(pageSeen);
    emit(@{@"kind":kind,@"notes":@(rowCount),@"decode":@(decode),@"cache_kib":@(cacheKiB),@"pool_batch":@(poolBatch),
        @"dictionary_load_ms":@(dictionaryLoadSeconds*1000),
#ifdef NV_PROBE_ZSTD
        @"dictionary_bytes":@(loadedDictionaryBytes),@"dictionary_count":@(loadedDictionaryCount),@"dictionary_cells":@(dictionaryCellCount),
#endif
        @"total_ms":@((finish-start)*1000),@"open_ms":@((opened-start)*1000),@"capture_ms":@((captured-opened)*1000),
        @"prefetch_ms":@(prefetchSeconds*1000),
        @"prefetch_bytes":@(prefetchedBytes),@"hint_used":@(hintUsed),
        @"decode_ms":@(decodeSeconds*1000),@"search_ms":@((finish-searchStart)*1000),@"pread_ms":@(ioSeconds*1000),
        @"inflate_ms":@(inflateSeconds*1000),@"construct_ms":@(constructSeconds*1000),@"cell_decoder":@(getenv("NV_PROBE_CELL_DECODER")?:"allocate"),
#ifdef NV_PROBE_ZSTD
        @"zstd_version":@(ZSTD_versionString()),
#endif
        @"pread_calls":@(systemReads),@"pread_bytes":@(systemReadBytes),@"kernel_read_bytes":@(diskBytes),
        @"unique_pages":@(distinctPages),@"nonadjacent_reads":@(seekReads),@"cache_misses":@(misses),@"cache_hits":@(hits),
        @"sorts":@(sorts),@"wal_reads":@(walReads),@"rss_high_water_bytes":@(usage.ru_maxrss),
        @"encoded_bytes":@(encodedBytes),@"search_hits":@(hitsCount),@"context_digest":@(contextDigest)});
}
#ifdef NV_PROBE_ZSTD
#include "ZstdDictionaryContracts.h"
#endif
int main(int argc, char **argv) {
    @autoreleasepool {
        setup_vfs(); (void)newNote(0,80); (void)[[[NotationPrefs alloc] init] autorelease];
        cellCompression=strcmp(getenv("NV_PROBE_CELL_CODEC")?:"raw","raw")!=0;
        if (argc==10 && !strcmp(argv[1],"aged-seed")) seedAged(@(argv[2]),@(argv[3]),atoll(argv[4]),atoll(argv[5]),atoll(argv[6]),atoll(argv[7]),atoll(argv[8]),atoll(argv[9]));
        else if (argc==4 && !strcmp(argv[1],"layout")) layoutAged(@(argv[2]),@(argv[3]));
        else if (argc==7 && !strcmp(argv[1],"aged-read")) readAged(@(argv[2]),@(argv[3]),atoi(argv[4]),atoi(argv[5]),atoi(argv[6]));
        else if (argc==3 && !strcmp(argv[1],"evict")) evictFile(@(argv[2]));
#ifdef NV_PROBE_ZSTD
        else if (argc==4 && !strcmp(argv[1],"dict-maintain")) dictionaryMaintenance(@(argv[2]),@(argv[3]));
        else if (argc==3 && !strcmp(argv[1],"dict-api")) dictionaryAPIContracts(@(argv[2]));
        else if (argc==4 && !strcmp(argv[1],"dict-micro")) dictionaryMicrobenchmark(@(argv[2]),@(argv[3]));
        else if (argc==3 && !strcmp(argv[1],"dict-example")) dictionaryExampleComparison(@(argv[2]));
#endif
        else { fprintf(stderr,"aged-seed DIR DDL NOTES BODY HISTORY ROUNDS CONTEXT HOLE_INTERVAL | layout FILE LAYOUT | aged-read DIR KIND CACHE_KIB POOL_BATCH DECODE | evict FILE\n"); return 2; }
    }
    return 0;
}
