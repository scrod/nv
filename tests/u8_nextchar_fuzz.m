/* compile with:
clang -std=gnu11 -ObjC -O2 -fsanitize=address,undefined -I. tests/u8_nextchar_fuzz.m -framework Foundation -framework CoreFoundation -framework Carbon -o u8_nextchar_fuzz; ./u8_nextchar_fuzz */

#import <Foundation/Foundation.h>
#import "../Notation_Prefix.pch"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <assert.h>

#ifndef force_inline
#define force_inline __attribute__((always_inline))
#endif

// Pull in implementation so tests can access static u8_nextchar
#include "../BufferUtils.c"

static size_t encode_utf8(uint32_t cp, uint8_t out[4]) {
    if (cp <= 0x7F) { out[0] = (uint8_t)cp; return 1; }
    if (cp <= 0x7FF) { out[0] = 0xC0 | (cp >> 6); out[1] = 0x80 | (cp & 0x3F); return 2; }
    if (cp <= 0xFFFF) { out[0] = 0xE0 | (cp >> 12); out[1] = 0x80 | ((cp >> 6) & 0x3F); out[2] = 0x80 | (cp & 0x3F); return 3; }
    out[0] = 0xF0 | (cp >> 18); out[1] = 0x80 | ((cp >> 12) & 0x3F); out[2] = 0x80 | ((cp >> 6) & 0x3F); out[3] = 0x80 | (cp & 0x3F); return 4;
}

static void append_cp(uint8_t **buf, size_t *len, size_t *cap, uint32_t cp) {
    uint8_t enc[4];
    size_t n = encode_utf8(cp, enc);
    if (*len + n > *cap) { *cap = (*cap + n) * 2 + 16; *buf = (uint8_t*)realloc(*buf, *cap); }
    memcpy(*buf + *len, enc, n); *len += n;
}

static void run_valid_sequence_test(const uint32_t *cps, size_t count) {
    uint8_t *buf = NULL; size_t len = 0, cap = 0;
    for (size_t i = 0; i < count; i++) { append_cp(&buf, &len, &cap, cps[i]); if (i + 1 < count) append_cp(&buf, &len, &cap, 0x20); }
    size_t i = 0; size_t cp_idx = 0;
    while (i < len) { uint32_t ch = u8_nextchar((const char*)buf, &i, len); if (ch == 0x20) continue; assert(cp_idx < count); assert(ch == cps[cp_idx]); cp_idx++; }
    assert(i == len); assert(cp_idx == count); free(buf);
}

static void run_truncation_safety_test(const uint32_t *cps, size_t count) {
    uint8_t *buf = NULL; size_t len = 0, cap = 0; for (size_t i = 0; i < count; i++) append_cp(&buf, &len, &cap, cps[i]);
    for (size_t cut = 0; cut <= len; cut++) { size_t idx = 0, last_idx = 0, steps = 0; while (idx < cut && steps < cut + 8) { last_idx = idx; (void)u8_nextchar((const char*)buf, &idx, cut); assert(idx > last_idx || cut == 0); steps++; } assert(idx <= cut); }
    free(buf);
}

int main(void) {
    const uint32_t simple1[] = {'A','B','C',0x7F};
    run_valid_sequence_test(simple1, sizeof(simple1)/sizeof(simple1[0]));

    const uint32_t two_byte[] = {0x80, 0x7FF, 0xA9};
    run_valid_sequence_test(two_byte, sizeof(two_byte)/sizeof(two_byte[0]));

    const uint32_t three_byte[] = {0x800, 0x2028, 0x2029, 0x2764};
    run_valid_sequence_test(three_byte, sizeof(three_byte)/sizeof(three_byte[0]));

    const uint32_t four_byte[] = {0x1F525, 0x1F9E0};
    run_valid_sequence_test(four_byte, sizeof(four_byte)/sizeof(four_byte[0]));

    const uint32_t heart_fire[] = {0x2764, 0xFE0F, 0x200D, 0x1F525};
    run_valid_sequence_test(heart_fire, sizeof(heart_fire)/sizeof(heart_fire[0]));

    const uint32_t thumbs_tone[] = {0x1F44D, 0x1F3FB};
    run_valid_sequence_test(thumbs_tone, sizeof(thumbs_tone)/sizeof(thumbs_tone[0]));

    run_truncation_safety_test(heart_fire, sizeof(heart_fire)/sizeof(heart_fire[0]));
    run_truncation_safety_test(four_byte, sizeof(four_byte)/sizeof(four_byte[0]));

    printf("u8_nextchar tests passed.\n");
    return 0;
}

#ifdef BUILD_LIBFUZZER
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    size_t i = 0, last = 0, guard = 0; while (i < size && guard < size + 8) { last = i; (void)u8_nextchar((const char*)data, &i, size); if (i <= last && size > 0) break; guard++; }
    return 0;
}
#endif
