/*
 *  hmacsha1.h
 *  Notation
 *
 */

#include <stdint.h>
#include <sys/types.h>

extern void hmac_sha1 (const void *key, size_t keylen, const void *in, size_t inlen, void *resbuf);

typedef struct _sha1_ctx {
	uint32_t A;
	uint32_t B;
	uint32_t C;
	uint32_t D;
	uint32_t E;
	
	uint32_t total[2];
	uint32_t buflen;
	char buffer[128] __attribute__ ((__aligned__ (__alignof__ (uint32_t))));
} sha1_ctx_nv;


void sha1_process_bytes (const void *buffer, size_t len, sha1_ctx_nv *ctx);
void *sha1_finish_ctx (sha1_ctx_nv *ctx, void *resbuf);
void sha1_init_ctx (sha1_ctx_nv *ctx);
