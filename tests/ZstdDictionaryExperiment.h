/* Private, synthetic dictionary experiment. Included by the aged-startup probe,
 * not the app or Swift library. Limits and cell wrappers are NOT format policy. */
#include <zdict.h>
#include <CommonCrypto/CommonDigest.h>

static NSData *agedRecordForPattern(NSUInteger, NSUInteger, NSUInteger, NSUInteger,
                                   uint64_t, NSUInteger, const char *);
static NSData *decodeCell(const void *, NSUInteger);
typedef struct {
    NSData *bytes;
    unsigned char hash[32];
    unsigned id;
    ZSTD_CDict *encoder;
    ZSTD_DDict *decoder;
} ProbeDictionary;
static ProbeDictionary dictionaries[4];
static unsigned dictionaryCount;
static int encodingDictionary=-1;
static double dictionaryTrainingSeconds, dictionaryPreparationSeconds;
static uint64_t dictionaryBytes, dictionaryCellCount;
static uint64_t dictionarySampleBytes, dictionarySampleCount;
static const char *dictionaryTrainingStatus="not-requested";

static void dictionaryFailure(const char *why) {
    fprintf(stderr,"DICTIONARY_REJECTED: %s\n",why); exit(65);
}
static NSData *dictionaryDigest(NSData *bytes) {
    unsigned char digest[32]; assert([bytes length]<=UINT32_MAX);
    CC_SHA256([bytes bytes],(CC_LONG)[bytes length],digest);
    return [NSData dataWithBytes:digest length:32];
}
static void clearDictionaries(void) {
    for (unsigned i=0;i<dictionaryCount;i++) {
        [dictionaries[i].bytes release]; ZSTD_freeCDict(dictionaries[i].encoder);
        ZSTD_freeDDict(dictionaries[i].decoder);
    }
    memset(dictionaries,0,sizeof(dictionaries)); dictionaryCount=0; encodingDictionary=-1;
    dictionaryBytes=0;
}
static unsigned registerDictionary(NSData *bytes, NSData *hash, BOOL encode) {
    if ([hash length]!=32 || ![dictionaryDigest(bytes) isEqual:hash]) dictionaryFailure("dictionary hash mismatch");
    unsigned id=ZSTD_getDictID_fromDict([bytes bytes],[bytes length]);
    if (!id || [bytes length]>65536) dictionaryFailure("invalid trained dictionary");
    unsigned i;
    for (i=0;i<dictionaryCount;i++) if (!memcmp(dictionaries[i].hash,[hash bytes],32)) break;
    if (i==dictionaryCount) {
        if (dictionaryCount==4) dictionaryFailure("experiment dictionary-count limit");
        ProbeDictionary *d=&dictionaries[dictionaryCount++];
        d->bytes=[bytes copy]; memcpy(d->hash,[hash bytes],32); d->id=id;
        d->decoder=ZSTD_createDDict([bytes bytes],[bytes length]);
        if (!d->decoder) dictionaryFailure("cannot prepare dictionary");
        dictionaryBytes+=[bytes length];
    }
    ProbeDictionary *d=&dictionaries[i];
    if (encode && !d->encoder) {
        d->encoder=ZSTD_createCDict([bytes bytes],[bytes length],atoi(getenv("NV_PROBE_ZSTD_LEVEL")?:"3"));
        assert(d->encoder);
    }
    return i;
}
static void loadDictionaries(sqlite3 *db) {
    clearDictionaries();
    if (!scalar(db,"SELECT count(*) FROM sqlite_schema WHERE name='benchmark_dictionaries'")) return;
    sqlite3_stmt *q=prepare(db,"SELECT digest,bytes FROM benchmark_dictionaries"); int rc;
    while ((rc=sqlite3_step(q))==SQLITE_ROW) {
        NSData *hash=[NSData dataWithBytes:sqlite3_column_blob(q,0) length:(NSUInteger)sqlite3_column_bytes(q,0)];
        NSData *bytes=[NSData dataWithBytes:sqlite3_column_blob(q,1) length:(NSUInteger)sqlite3_column_bytes(q,1)];
        registerDictionary(bytes,hash,NO);
    }
    assert(rc==SQLITE_DONE); sqlite3_finalize(q);
}
static unsigned installDictionary(sqlite3 *db, NSData *bytes) {
    double start=now(); NSData *hash=dictionaryDigest(bytes);
    sql(db,"CREATE TABLE IF NOT EXISTS benchmark_dictionaries(digest BLOB PRIMARY KEY CHECK(length(digest)=32),bytes BLOB NOT NULL)");
    sqlite3_stmt *q=prepare(db,"INSERT OR IGNORE INTO benchmark_dictionaries VALUES(?,?)");
    sqlite3_bind_blob(q,1,[hash bytes],32,SQLITE_TRANSIENT);
    sqlite3_bind_blob(q,2,[bytes bytes],(int)[bytes length],SQLITE_TRANSIENT); done(db,q); sqlite3_finalize(q);
    unsigned result=registerDictionary(bytes,hash,YES); dictionaryPreparationSeconds+=now()-start; return result;
}
static ProbeDictionary *findDictionary(const unsigned char *hash, const void *frame, size_t size) {
    for (unsigned i=0;i<dictionaryCount;i++) if (!memcmp(dictionaries[i].hash,hash,32)) {
        if (ZSTD_getDictID_fromFrame(frame,size)!=dictionaries[i].id) dictionaryFailure("frame/dictionary ID mismatch");
        return &dictionaries[i];
    }
    dictionaryFailure("missing exact dictionary"); return NULL;
}
static NSData *trainDictionarySamples(NSData *samples, const size_t *sizes, unsigned count, NSUInteger capacity) {
    assert(capacity>=8192 && capacity<=65536);
    dictionarySampleBytes=[samples length]; dictionarySampleCount=count;
    if (count<8) { dictionaryTrainingStatus="too-few-samples"; return nil; }
    NSMutableData *dict=[NSMutableData dataWithLength:capacity]; double start=now();
    size_t length=ZDICT_trainFromBuffer([dict mutableBytes],capacity,[samples bytes],sizes,count);
    dictionaryTrainingSeconds+=now()-start;
    if (ZDICT_isError(length)) {
        fprintf(stderr,"optional dictionary training: %s\n",ZDICT_getErrorName(length));
        dictionaryTrainingStatus="trainer-declined"; return nil;
    }
    dictionaryTrainingStatus="trained";
    [dict setLength:length]; return dict;
}
static NSData *trainProbeDictionary(const char *pattern, unsigned generation, NSUInteger capacity) {
    assert(capacity>=8192 && capacity<=65536);
    // Entirely new records, disjoint IDs/random seeds from measured notes. The
    // words family remains deliberately favorable; mixed/random expose drift.
    enum { count=4096 }; size_t sizes[count]; NSMutableData *samples=[NSMutableData data];
    NSUInteger lengths[]={192,512,1024,4096,8192};
    for (unsigned i=0;i<count;i++) { @autoreleasepool {
        NSData *record=agedRecordForPattern(2000000+generation*100000+i,17,count,
            lengths[i%5],UINT64_C(900000000)+generation*100000+i,256,pattern);
        sizes[i]=[record length]; [samples appendData:record];
    } }
    return trainDictionarySamples(samples,sizes,count,capacity);
}
static NSData *trainCurrentDictionary(sqlite3 *db, NSUInteger capacity, BOOL all) {
    // Either evenly spaced complete cells under explicit note/byte caps, or every current
    // cell in a bounded fixture (128 MiB). Never silently sample the latter.
    unsigned count=0;
    uint64_t total=(uint64_t)scalar(db,"SELECT count(*) FROM current_notes"), index=0;
    uint64_t cap=(uint64_t)atoi(getenv("NV_PROBE_DICTIONARY_SAMPLE_LIMIT")?:"1024");
    uint64_t wanted=all?total:MIN(total,cap); assert(wanted<=100000);
    size_t *sizes=calloc((size_t)MAX(wanted,1),sizeof(*sizes)); assert(sizes);
    NSUInteger budget=all?128*1024*1024:(NSUInteger)strtoull(getenv("NV_PROBE_DICTIONARY_SAMPLE_BUDGET")?:"8388608",NULL,10);
    NSMutableData *samples=[NSMutableData data];
    sqlite3_stmt *q=prepare(db,"SELECT cell FROM current_notes ORDER BY rowid"); int rc;
    while ((rc=sqlite3_step(q))==SQLITE_ROW) { @autoreleasepool {
        BOOL selected=(index*wanted/total)!=((index+1)*wanted/total); index++;
        if (!selected) continue;
        NSData *record=decodeCell(sqlite3_column_blob(q,0),(NSUInteger)sqlite3_column_bytes(q,0));
        if ([record length]>budget-[samples length]) {
            if (all) dictionaryFailure("all-current training exceeds experiment memory bound");
            continue;
        }
        assert(count<wanted); sizes[count++]=[record length]; [samples appendData:record];
    } }
    assert(rc==SQLITE_DONE && index==total); sqlite3_finalize(q);
    assert(!all || count==total);
    NSData *dict=trainDictionarySamples(samples,sizes,count,capacity); free(sizes); return dict;
}

static uint64_t dictionaryRng(uint64_t *s) {
    *s=*s*UINT64_C(6364136223846793005)+UINT64_C(1442695040888963407); return *s;
}
static NSString *mixedProbeBody(uint64_t seed, NSUInteger length) {
    // Six synthetic note genres, variable sentences, identifiers and Unicode.
    // Not scraped prose or user notes, and not a claim of a representative corpus.
    NSArray *templates=@[@"## Project review\n%@: %@ by %@. Ticket %08llx; follow up in %u days.\n",
      @"Shopping / recipe\n%@, %@, %@ — %u grams; batch %08llx.\n",
      @"Journal\nToday %@ met %@ about %@. café 日本語 résumé — reference %08llx.\n",
      @"func %@_%08llx() { // %@\n  return \"%@\";\n}\n",
      @"Research: %@\nQuestion: does %@ improve %@? https://example.invalid/%08llx\n",
      @"Contact %@\n%@ / %@\nAccount %08llx; meeting notes and open questions.\n"];
    NSArray *words=@[@"amber",@"testing",@"garden",@"latency",@"budget",@"river",@"coffee",@"Orion",@"Monday",@"invoice",@"review",@"travel",@"archive",@"family",@"design",@"library",@"network",@"olive",@"winter",@"bicycle",@"survey",@"violet",@"draft",@"recipe"];
    NSMutableString *body=[NSMutableString string]; uint64_t rng=seed^UINT64_C(0x46180732);
    NSUInteger genre=(NSUInteger)((dictionaryRng(&rng)>>32)%[templates count]);
    while ([body length]<length) {
        NSString *a=words[(dictionaryRng(&rng)>>32)%[words count]];
        NSString *b=words[(dictionaryRng(&rng)>>32)%[words count]];
        NSString *c=words[(dictionaryRng(&rng)>>32)%[words count]];
        unsigned long long token=dictionaryRng(&rng)>>16; unsigned amount=(unsigned)((dictionaryRng(&rng)>>32)%300)+1;
        NSString *line;
        // Match each format's argument order explicitly (never varargs guessing).
        if (genre==1) line=[NSString stringWithFormat:templates[genre],a,b,c,amount,token];
        else if (genre==3) line=[NSString stringWithFormat:templates[genre],a,token,b,c];
        else if (genre==0) line=[NSString stringWithFormat:templates[genre],a,b,c,token,amount];
        else line=[NSString stringWithFormat:templates[genre],a,b,c,token];
        [body appendString:line];
    }
    return [body substringToIndex:length];
}
