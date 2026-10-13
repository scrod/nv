/* Independent zstd dictionary fixture producer and complete-frame reader. */
#include <zstd.h>
#include <zdict.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned char *hex(const char *s, size_t *length) {
    size_t n = strlen(s); if (n % 2 || n > 200000) exit(2);
    unsigned char *b = malloc(n / 2 + 1); if (!b) exit(2);
    for (size_t i = 0; i < n / 2; ++i) { unsigned x; if (sscanf(s + i * 2, "%2x", &x) != 1) exit(2); b[i] = (unsigned char)x; }
    *length = n / 2; return b;
}
static void printhex(const unsigned char *b, size_t n) { for (size_t i = 0; i < n; ++i) printf("%02x", b[i]); }
int main(int argc, char **argv) {
    if (argc != 2 && argc != 4) return 2;
    size_t n; unsigned char *cell = hex(argv[1], &n);
    if (argc == 4) {
        size_t dn, fn; unsigned char *dict = hex(argv[2], &dn), *frame = hex(argv[3], &fn), *out = malloc(n + 1);
        ZSTD_DCtx *ctx = ZSTD_createDCtx(); if (!ctx || !out) return 2;
        size_t size = ZSTD_decompress_usingDict(ctx, out, n, frame, fn, dict, dn);
        int result = ZSTD_isError(size) || size != n || memcmp(out, cell, n) || ZSTD_findFrameCompressedSize(frame, fn) != fn;
        ZSTD_freeDCtx(ctx); free(out); free(dict); free(frame); free(cell); return result;
    }
    if (n < 26 || n > 10000) return 2;
    unsigned char *samples = malloc(n * 256), dict[8192]; size_t sizes[256]; if (!samples) return 2;
    for (size_t i = 0; i < 256; ++i) { memcpy(samples + n * i, cell, n); samples[n * i + 10] = (unsigned char)i; sizes[i] = n; }
    size_t dn = ZDICT_trainFromBuffer(dict, sizeof(dict), samples, sizes, 256); if (ZDICT_isError(dn)) return 2;
    size_t cap = ZSTD_compressBound(n); unsigned char *frame = malloc(cap); ZSTD_CCtx *ctx = ZSTD_createCCtx(); if (!frame || !ctx) return 2;
    size_t fn = ZSTD_compress_usingDict(ctx, frame, cap, cell, n, dict, dn, 3); if (ZSTD_isError(fn)) return 2;
    printf("{\"dictionary\":\""); printhex(dict, dn); printf("\",\"payload\":\""); printhex(frame, fn); puts("\"}");
    ZSTD_freeCCtx(ctx); free(frame); free(samples); free(cell); return 0;
}
