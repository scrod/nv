/* Abrupt-process-exit and dependency tests for the synthetic SQLite mapping.
 * Not a power-loss proof, production migration, or accepted-history validator. */
static NSData *cellDictionaryHash(NSData *cell) {
    assert([cell length]>=4); uint32_t n; memcpy(&n,[cell bytes],4); n=CFSwapInt32LittleToHost(n);
    if (!(n&UINT32_C(0x40000000))) return nil;
    assert((n&UINT32_C(0x80000000)) && [cell length]>=36);
    return [NSData dataWithBytes:(const unsigned char *)[cell bytes]+4 length:32];
}
static NSMutableArray *capturedDictionaryRows(sqlite3 *db) {
    NSMutableArray *rows=[NSMutableArray array]; sqlite3_stmt *q=prepare(db,"SELECT birth,cell FROM current_notes ORDER BY rowid"); int rc;
    while ((rc=sqlite3_step(q))==SQLITE_ROW) {
        NSData *key=[NSData dataWithBytes:sqlite3_column_blob(q,0) length:16];
        NSData *cell=[NSData dataWithBytes:sqlite3_column_blob(q,1) length:(NSUInteger)sqlite3_column_bytes(q,1)];
        [rows addObject:@[key,cell]];
    }
    assert(rc==SQLITE_DONE); sqlite3_finalize(q); return rows;
}
static NSString *probeHashString(const unsigned char *digest) {
    NSMutableString *s=[NSMutableString string]; for (unsigned i=0;i<32;i++) [s appendFormat:@"%02x",digest[i]]; return s;
}
static NSDictionary *dictionaryState(sqlite3 *db) {
    loadDictionaries(db); NSMutableSet *referenced=[NSMutableSet set];
    CC_SHA256_CTX ctx; CC_SHA256_Init(&ctx); NSUInteger rows=0, cells=0;
    sqlite3_stmt *q=prepare(db,"SELECT cell FROM current_notes ORDER BY birth"); int rc;
    while ((rc=sqlite3_step(q))==SQLITE_ROW) { @autoreleasepool {
        NSData *cell=[NSData dataWithBytes:sqlite3_column_blob(q,0) length:(NSUInteger)sqlite3_column_bytes(q,0)];
        NSData *ref=cellDictionaryHash(cell); if (ref) { [referenced addObject:ref]; cells++; }
        NSData *plain=decodeCell([cell bytes],[cell length]);
        CC_SHA256_Update(&ctx,[plain bytes],(CC_LONG)[plain length]); rows++;
    } }
    assert(rc==SQLITE_DONE); sqlite3_finalize(q); unsigned char current[32]; CC_SHA256_Final(current,&ctx);
    CC_SHA256_Init(&ctx); q=prepare(db,"SELECT object_id,encoded FROM objects ORDER BY object_id");
    while ((rc=sqlite3_step(q))==SQLITE_ROW) for (int c=0;c<2;c++)
        CC_SHA256_Update(&ctx,sqlite3_column_blob(q,c),(CC_LONG)sqlite3_column_bytes(q,c));
    assert(rc==SQLITE_DONE); sqlite3_finalize(q); unsigned char history[32]; CC_SHA256_Final(history,&ctx);
    return @{@"notes":@(rows),@"dictionary_cells":@(cells),@"dictionary_count":@(dictionaryCount),
        @"referenced_count":@([referenced count]),@"current_hash":probeHashString(current),@"history_hash":probeHashString(history)};
}
static void dictionaryMaintenance(NSString *file, NSString *mode) {
    // Called only with a runner-created copy; never edits a source benchmark.
    sqlite3 *db=open_db([file fileSystemRepresentation],0);
    sql(db,"PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA wal_autocheckpoint=0");
    loadDictionaries(db); if (![mode isEqual:@"state"]) assert(dictionaryCount>=1);
    NSMutableArray *rows=capturedDictionaryRows(db); assert([rows count]>=2 && [rows count]<=1000);
    NSUInteger removed=0, changed=0;
    if ([mode hasPrefix:@"rotate"]) {
        NSData *next=trainProbeDictionary(getenv("NV_PROBE_DICTIONARY_PATTERN")?:"mixed",dictionaryCount,
                                         (NSUInteger)atoi(getenv("NV_PROBE_DICTIONARY_SIZE")?:"8192"));
        sql(db,"BEGIN"); encodingDictionary=(int)installDictionary(db,next);
        sqlite3_stmt *q=prepare(db,"UPDATE current_notes SET cell=? WHERE birth=?");
        for (NSUInteger i=0;i<[rows count];i++) if ([mode isEqual:@"rotate-all"] || i%2==0) { @autoreleasepool {
            NSArray *row=rows[i]; NSData *old=row[1], *plain=decodeCell([old bytes],[old length]), *cell=encodeZstd(plain,YES);
            assert(cellDictionaryHash(cell)); // The mixed-generation witness must actually use its dictionary.
            sqlite3_bind_blob(q,1,[cell bytes],(int)[cell length],SQLITE_TRANSIENT);
            sqlite3_bind_blob(q,2,[row[0] bytes],16,SQLITE_TRANSIENT); done(db,q); assert(sqlite3_changes(db)==1); changed++;
        } }
        sqlite3_finalize(q);
        if ([mode isEqual:@"rotate-before"]) _exit(77);
        sql(db,"COMMIT");
        if ([mode isEqual:@"rotate-after"]) _exit(78);
    } else if ([mode isEqual:@"prune"]) {
        NSMutableSet *references=[NSMutableSet set];
        for (NSArray *row in rows) { NSData *ref=cellDictionaryHash(row[1]); if (ref) [references addObject:ref]; }
        sql(db,"BEGIN"); sqlite3_stmt *q=prepare(db,"DELETE FROM benchmark_dictionaries WHERE digest=?");
        for (unsigned i=0;i<dictionaryCount;i++) {
            NSData *hash=[NSData dataWithBytes:dictionaries[i].hash length:32];
            if ([references containsObject:hash]) continue;
            sqlite3_bind_blob(q,1,[hash bytes],32,SQLITE_TRANSIENT); done(db,q); removed+=sqlite3_changes(db);
        }
        sqlite3_finalize(q); sql(db,"COMMIT");
    } else if ([mode isEqual:@"missing"] || [mode isEqual:@"corrupt"] || [mode isEqual:@"unknown-ref"] || [mode isEqual:@"wrong-frame-id"]) {
        NSArray *row=rows[0]; NSData *ref=cellDictionaryHash(row[1]); assert(ref);
        sql(db,"BEGIN"); sqlite3_stmt *q;
        if ([mode isEqual:@"missing"]) {
            q=prepare(db,"DELETE FROM benchmark_dictionaries WHERE digest=?");
            sqlite3_bind_blob(q,1,[ref bytes],32,SQLITE_TRANSIENT);
        } else if ([mode isEqual:@"corrupt"]) {
            ProbeDictionary *dict=findDictionary([ref bytes],(const unsigned char *)[row[1] bytes]+36,[row[1] length]-36);
            NSMutableData *bad=[NSMutableData dataWithData:dict->bytes]; ((unsigned char *)[bad mutableBytes])[[bad length]-1]^=1;
            assert(ZSTD_getDictID_fromDict([bad bytes],[bad length])==dict->id); // ID still matches, exact hash does not.
            q=prepare(db,"UPDATE benchmark_dictionaries SET bytes=? WHERE digest=?");
            sqlite3_bind_blob(q,1,[bad bytes],(int)[bad length],SQLITE_TRANSIENT);
            sqlite3_bind_blob(q,2,[ref bytes],32,SQLITE_TRANSIENT);
        } else {
            NSMutableData *bad=[NSMutableData dataWithData:row[1]];
            if ([mode isEqual:@"unknown-ref"]) ((unsigned char *)[bad mutableBytes])[4]^=1;
            else {
                // Replace the frame with one made using a different trained dictionary,
                // while keeping the original exact-hash reference in the cell wrapper.
                NSData *plain=decodeCell([bad bytes],[bad length]);
                NSData *other=trainProbeDictionary("mixed",3,8192);
                encodingDictionary=(int)installDictionary(db,other); NSData *replacement=encodeZstd(plain,YES);
                assert(cellDictionaryHash(replacement)); [bad setData:replacement];
                assert(ZSTD_getDictID_fromFrame((const unsigned char *)[bad bytes]+36,[bad length]-36)!=
                    ZSTD_getDictID_fromFrame((const unsigned char *)[row[1] bytes]+36,[row[1] length]-36));
                memcpy((unsigned char *)[bad mutableBytes]+4,[ref bytes],32);
            }
            q=prepare(db,"UPDATE current_notes SET cell=? WHERE birth=?");
            sqlite3_bind_blob(q,1,[bad bytes],(int)[bad length],SQLITE_TRANSIENT);
            sqlite3_bind_blob(q,2,[row[0] bytes],16,SQLITE_TRANSIENT);
        }
        done(db,q); assert(sqlite3_changes(db)==1); sqlite3_finalize(q); sql(db,"COMMIT");
        cleanClose(db,file); emit(@{@"fault":mode}); return;
    } else assert([mode isEqual:@"state"]);
    NSMutableDictionary *info=[NSMutableDictionary dictionaryWithDictionary:dictionaryState(db)];
    info[@"removed"]=@(removed); info[@"changed"]=@(changed); cleanClose(db,file); emit(info);
}
static void dictionaryAPIContracts(NSString *file) {
    sqlite3 *db=open_db([file fileSystemRepresentation],0); loadDictionaries(db); assert(dictionaryCount==1);
    NSArray *rows=capturedDictionaryRows(db); NSData *cell=rows[0][1], *ref=cellDictionaryHash(cell); assert(ref);
    NSData *plain=decodeCell([cell bytes],[cell length]);
    const unsigned char *frame=(const unsigned char *)[cell bytes]+36; size_t length=[cell length]-36;
    NSMutableData *out=[NSMutableData dataWithLength:[plain length]];
    assert(ZSTD_isError(ZSTD_decompress([out mutableBytes],[out length],frame,length)));
    NSData *other=trainProbeDictionary("mixed",3,8192); unsigned slot=registerDictionary(other,dictionaryDigest(other),YES);
    assert(dictionaries[slot].id!=ZSTD_getDictID_fromFrame(frame,length));
    ZSTD_DCtx *ctx=ZSTD_createDCtx(); assert(ctx);
    assert(ZSTD_isError(ZSTD_decompress_usingDDict(ctx,[out mutableBytes],[out length],frame,length,dictionaries[slot].decoder)));
    NSMutableDictionary *forward=[NSMutableDictionary dictionary];
    for (NSArray *row in rows) { NSData *encoded=row[1]; forward[row[0]]=decodeCell([encoded bytes],[encoded length]); }
    // Reusing a DDict cannot make frames depend on the previously decoded note.
    for (NSArray *row in [rows reverseObjectEnumerator]) {
        NSData *encoded=row[1], *value=decodeCell([encoded bytes],[encoded length]);
        assert([value isEqual:forward[row[0]]]);
    }
    encodingDictionary=(int)slot; unsigned char random[64]; uint64_t rng=881;
    for (unsigned i=0;i<sizeof(random);i++) random[i]=(unsigned char)(dictionaryRng(&rng)>>32);
    NSData *raw=[NSData dataWithBytes:random length:sizeof(random)], *encoded=encodeZstd(raw,YES);
    assert(!cellDictionaryHash(encoded) && [decodeCell([encoded bytes],[encoded length]) isEqual:raw]);
    encodingDictionary=-1; encoded=encodeZstd(plain,YES);
    assert(!cellDictionaryHash(encoded) && [decodeCell([encoded bytes],[encoded length]) isEqual:plain]);
    ZSTD_freeDCtx(ctx); cleanClose(db,file);
    emit(@{@"checks":@5,@"missing_rejected":@YES,@"wrong_rejected":@YES,@"reverse_order":@YES,@"raw_fallback":@YES,@"plain_frame":@YES});
}

static void dictionaryMicrobenchmark(NSString *plainFile, NSString *dictionaryFile) {
    // Complement, not replace, cold full startup. Same process, no timed I/O or
    // NoteObject construction, alternate case order; exact equality before timing.
    assert(!strcmp(getenv("NV_PROBE_CELL_DECODER")?:"allocate","stream"));
    sqlite3 *db=open_db([plainFile fileSystemRepresentation],0); loadDictionaries(db); assert(dictionaryCount==0);
    NSArray *plainRows=[capturedDictionaryRows(db) retain]; check(db,sqlite3_close(db));
    db=open_db([dictionaryFile fileSystemRepresentation],0); loadDictionaries(db); assert(dictionaryCount>=1);
    NSArray *dictRows=capturedDictionaryRows(db); check(db,sqlite3_close(db)); assert([plainRows count]==[dictRows count]);
    for (NSUInteger i=0;i<[plainRows count];i++) { @autoreleasepool {
        NSData *a=plainRows[i][1], *b=dictRows[i][1]; assert([plainRows[i][0] isEqual:dictRows[i][0]]);
        assert([decodeCell([a bytes],[a length]) isEqual:decodeCell([b bytes],[b length])]);
    } }
    NSMutableArray *measurements=[NSMutableArray array]; volatile uint64_t sink=0;
    for (unsigned pass=0;pass<12;pass++) for (unsigned position=0;position<2;position++) {
        BOOL dict=((pass+position)%2)!=0; NSArray *rows=dict?dictRows:plainRows; double start=now();
        for (NSArray *row in rows) {
            NSData *cell=row[1]; NSUInteger n=[cell length];
            const unsigned char *decoded=decodeCellBytes([cell bytes],&n); sink^=n+decoded[0];
        }
        [measurements addObject:@{@"dictionary":@(dict),@"pass":@(pass),@"ms":@((now()-start)*1000)}];
    }
    [plainRows release]; emit(@{@"measurements":measurements,@"sink":@(sink),@"notes":@([dictRows count])});
}

static void dictionaryExampleComparison(NSString *file) {
    sqlite3 *db=open_db([file fileSystemRepresentation],0); loadDictionaries(db); assert(dictionaryCount==1);
    NSArray *rows=capturedDictionaryRows(db); check(db,sqlite3_close(db));
    ProbeDictionary *dict=&dictionaries[0]; ZSTD_DCtx *direct=ZSTD_createDCtx(), *referenced=ZSTD_createDCtx();
    assert(direct && referenced); assert(!ZSTD_isError(ZSTD_DCtx_refDDict(referenced,dict->decoder)));
    NSUInteger capacity=0;
    for (NSArray *row in rows) { @autoreleasepool {
        NSData *cell=row[1]; assert(cellDictionaryHash(cell));
        NSData *decoded=decodeCell([cell bytes],[cell length]); capacity=MAX(capacity,[decoded length]);
    } }
    unsigned char *output=malloc(capacity); assert(output); NSMutableArray *measurements=[NSMutableArray array];
    NSArray *names=@[@"strict-wrapper",@"example-reused-context",@"refDDict-once",@"frame-check-only"];
    // Diagnostic controls run only on the already strictly validated corpus.
    // Their less restrictive framing is NOT a replacement production decoder.
    for (unsigned pass=0;pass<12;pass++) for (unsigned position=0;position<4;position++) {
        unsigned variant=(pass+position)%4; double start=now();
        for (NSArray *row in rows) {
            NSData *cell=row[1];
            const unsigned char *frame=(const unsigned char *)[cell bytes]+36; size_t size=[cell length]-36;
            if (variant==0) { NSUInteger n=[cell length]; (void)decodeCellBytes([cell bytes],&n); }
            else if (variant==3) assert(ZSTD_findFrameCompressedSize(frame,size)==size);
            else {
                size_t n=(size_t)ZSTD_getFrameContentSize(frame,size); assert(n<=capacity);
                assert(ZSTD_getDictID_fromFrame(frame,size)==ZSTD_getDictID_fromDDict(dict->decoder));
                size_t decoded=variant==1?ZSTD_decompress_usingDDict(direct,output,n,frame,size,dict->decoder):
                    ZSTD_decompressDCtx(referenced,output,n,frame,size);
                assert(!ZSTD_isError(decoded) && decoded==n);
            }
        }
        [measurements addObject:@{@"variant":names[variant],@"pass":@(pass),@"ms":@((now()-start)*1000)}];
    }
    // Exercise and compare the two API paths' complete output, not just success.
    for (NSArray *row in rows) { @autoreleasepool {
        NSData *cell=row[1], *expected=decodeCell([cell bytes],[cell length]);
        const unsigned char *frame=(const unsigned char *)[cell bytes]+36; size_t size=[cell length]-36;
        assert(ZSTD_decompress_usingDDict(direct,output,capacity,frame,size,dict->decoder)==[expected length]);
        assert(!memcmp(output,[expected bytes],[expected length]));
        assert(ZSTD_decompressDCtx(referenced,output,capacity,frame,size)==[expected length]);
        assert(!memcmp(output,[expected bytes],[expected length]));
    } }
    free(output); ZSTD_freeDCtx(direct); ZSTD_freeDCtx(referenced);
    emit(@{@"notes":@([rows count]),@"measurements":measurements});
}
