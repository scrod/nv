/* sha1.c - Functions to compute SHA1 message digest of files or
 memory blocks according to the NIST specification FIPS-180-1.
 
 Copyright (C) 2000, 2001, 2003, 2004, 2005, 2006 Free Software
 Foundation, Inc.
 
 This program is free software; you can redistribute it and/or modify it
 under the terms of the GNU General Public License as published by the
 Free Software Foundation; either version 2, or (at your option) any
 later version.
 
 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.
 
 You should have received a copy of the GNU General Public License
 along with this program; if not, write to the Free Software Foundation,
 Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.  */

/* Written by Scott G. Miller
 Credits:
 Robert Klep <robert@ilse.nl>  -- Expansion function fix
 */

#include "hmacsha1.h"

#include <stddef.h>
#include <string.h>

/* SWAP does an endian swap on architectures that are little-endian,
as SHA1 needs some data in a big-endian form.  */

#if __BIG_ENDIAN__
# define SWAP(n) (n)
#else
# define SWAP(n) \
(((n) << 24) | (((n) & 0xff00) << 8) | (((n) >> 8) & 0xff00) | ((n) >> 24))
//#define SWAP(n) CFSwapInt32(n)
#endif

#define BLOCKSIZE 4096
#if BLOCKSIZE % 64 != 0
# error "invalid BLOCKSIZE"
#endif

/* This array contains the bytes used to pad the buffer to the next
64-byte boundary.  (RFC 1321, 3.1: Step 1)  */
static const unsigned char fillbuf[64] = { 0x80, 0 /* , 0, 0, ...  */ };

static void sha1_process_block (const void *buffer, size_t len, sha1_ctx_nv *ctx);
void sha1_process_bytes (const void *buffer, size_t len, sha1_ctx_nv *ctx);
static void *sha1_read_ctx (const sha1_ctx_nv *ctx, void *resbuf);
void *sha1_finish_ctx (sha1_ctx_nv *ctx, void *resbuf);
void sha1_init_ctx (sha1_ctx_nv *ctx);
static void *memxor(void */*restrict*/ dest, const void */*restrict*/ src, size_t n);


static void *memxor(void */*restrict*/ dest, const void */*restrict*/ src, size_t n) {
	char const *s = src;
	char *d = dest;
	
	for (; n > 0; n--)
		*d++ ^= *s++;
	
	return dest;
}

/*
 Takes a pointer to a 160 bit block of data (five 32 bit ints) and
 intializes it to the start constants of the SHA1 algorithm.  This
 must be called before using hash in the call to sha1_hash.
 */
void sha1_init_ctx (sha1_ctx_nv *ctx) {
	ctx->A = 0x67452301;
	ctx->B = 0xefcdab89;
	ctx->C = 0x98badcfe;
	ctx->D = 0x10325476;
	ctx->E = 0xc3d2e1f0;
	
	ctx->total[0] = ctx->total[1] = 0;
	ctx->buflen = 0;
}

/* Put result from CTX in first 20 bytes following RESBUF.  The result
must be in little endian byte order.

IMPORTANT: On some systems it is required that RESBUF is correctly
aligned for a 32 bits value.  */
static void * sha1_read_ctx (const sha1_ctx_nv *ctx, void *resbuf) {
	((uint32_t *) resbuf)[0] = SWAP (ctx->A);
	((uint32_t *) resbuf)[1] = SWAP (ctx->B);
	((uint32_t *) resbuf)[2] = SWAP (ctx->C);
	((uint32_t *) resbuf)[3] = SWAP (ctx->D);
	((uint32_t *) resbuf)[4] = SWAP (ctx->E);
	
	return resbuf;
}

/* Process the remaining bytes in the internal buffer and the usual
prolog according to the standard and write the result to RESBUF.

IMPORTANT: On some systems it is required that RESBUF is correctly
aligned for a 32 bits value.  */
void *sha1_finish_ctx(sha1_ctx_nv *ctx, void *resbuf) {
	/* Take yet unprocessed bytes into account.  */
	uint32_t bytes = ctx->buflen;
	size_t pad;
	
	/* Now count remaining bytes.  */
	ctx->total[0] += bytes;
	if (ctx->total[0] < bytes)
		++ctx->total[1];
	
	pad = bytes >= 56 ? 64 + 56 - bytes : 56 - bytes;
	memcpy (&ctx->buffer[bytes], fillbuf, pad);
	
	/* Put the 64-bit file length in *bits* at the end of the buffer.  */
	*(uint32_t *) &ctx->buffer[bytes + pad + 4] = SWAP (ctx->total[0] << 3);
	*(uint32_t *) &ctx->buffer[bytes + pad] = SWAP ((ctx->total[1] << 3) |
													(ctx->total[0] >> 29));
	
	/* Process last bytes.  */
	sha1_process_block (ctx->buffer, bytes + pad + 8, ctx);
	
	return sha1_read_ctx (ctx, resbuf);
}


void sha1_process_bytes (const void *buffer, size_t len, sha1_ctx_nv *ctx) {
	/* When we already have some bits in our internal buffer concatenate
	both inputs first.  */
	if (ctx->buflen != 0)
    {
		size_t left_over = ctx->buflen;
		size_t add = 128 - left_over > len ? len : 128 - left_over;
		
		memcpy (&ctx->buffer[left_over], buffer, add);
		ctx->buflen += add;
		
		if (ctx->buflen > 64)
		{
			sha1_process_block (ctx->buffer, ctx->buflen & ~63, ctx);
			
			ctx->buflen &= 63;
			/* The regions in the following copy operation cannot overlap.  */
			memcpy (ctx->buffer, &ctx->buffer[(left_over + add) & ~63],
					ctx->buflen);
		}
		
		buffer = (const char *) buffer + add;
		len -= add;
    }
	
	/* Process available complete blocks.  */
	if (len >= 64)
    {
#if !_STRING_ARCH_unaligned
# define alignof(type) offsetof (struct { char c; type x; }, x)
# define UNALIGNED_P(p) (((size_t) p) % alignof (uint32_t) != 0)
		if (UNALIGNED_P (buffer))
			while (len > 64)
			{
				sha1_process_block (memcpy (ctx->buffer, buffer, 64), 64, ctx);
				buffer = (const char *) buffer + 64;
				len -= 64;
			}
				else
#endif
				{
					sha1_process_block (buffer, len & ~63, ctx);
					buffer = (const char *) buffer + (len & ~63);
					len &= 63;
				}
    }
		
		/* Move remaining bytes in internal buffer.  */
		if (len > 0)
		{
			size_t left_over = ctx->buflen;
			
			memcpy (&ctx->buffer[left_over], buffer, len);
			left_over += len;
			if (left_over >= 64)
			{
				sha1_process_block (ctx->buffer, 64, ctx);
				left_over -= 64;
				memcpy (ctx->buffer, &ctx->buffer[64], left_over);
			}
			ctx->buflen = left_over;
		}
}

/* --- Code below is the primary difference between md5.c and sha1.c --- */

/* SHA1 round constants */
#define K1 0x5a827999L
#define K2 0x6ed9eba1L
#define K3 0x8f1bbcdcL
#define K4 0xca62c1d6L

/* Round functions.  Note that F2 is the same as F4.  */
#define F1(B,C,D) ( D ^ ( B & ( C ^ D ) ) )
#define F2(B,C,D) (B ^ C ^ D)
#define F3(B,C,D) ( ( B & C ) | ( D & ( B | C ) ) )
#define F4(B,C,D) (B ^ C ^ D)

/* Process LEN bytes of BUFFER, accumulating context into CTX.
It is assumed that LEN % 64 == 0.
Most of this code comes from GnuPG's cipher/sha1.c.  */

static void sha1_process_block (const void *buffer, size_t len, sha1_ctx_nv *ctx) {
	const uint32_t *words = buffer;
	size_t nwords = len / sizeof (uint32_t);
	const uint32_t *endp = words + nwords;
	uint32_t x[16];
	uint32_t a = ctx->A;
	uint32_t b = ctx->B;
	uint32_t c = ctx->C;
	uint32_t d = ctx->D;
	uint32_t e = ctx->E;
	
	/* First increment the byte count.  RFC 1321 specifies the possible
		length of the file up to 2^64 bits.  Here we only compute the
		number of bytes.  Do a double word increment.  */
	ctx->total[0] += len;
	if (ctx->total[0] < len)
		++ctx->total[1];
	
#define rol(x, n) (((x) << (n)) | ((x) >> (32 - (n))))
	
#define M(I) ( tm =   x[I&0x0f] ^ x[(I-14)&0x0f] \
			   ^ x[(I-8)&0x0f] ^ x[(I-3)&0x0f] \
			   , (x[I&0x0f] = rol(tm, 1)) )
				   
#define R(A,B,C,D,E,F,K,M)  do { E += rol( A, 5 )     \
	+ F( B, C, D )  \
	+ K	      \
	+ M;	      \
		B = rol( B, 30 );    \
} while(0)

while (words < endp)
{
	uint32_t tm;
	int t;
	for (t = 0; t < 16; t++)
	{
		x[t] = SWAP (*words);
		words++;
	}
	
	R( a, b, c, d, e, F1, K1, x[ 0] );
	R( e, a, b, c, d, F1, K1, x[ 1] );
	R( d, e, a, b, c, F1, K1, x[ 2] );
	R( c, d, e, a, b, F1, K1, x[ 3] );
	R( b, c, d, e, a, F1, K1, x[ 4] );
	R( a, b, c, d, e, F1, K1, x[ 5] );
	R( e, a, b, c, d, F1, K1, x[ 6] );
	R( d, e, a, b, c, F1, K1, x[ 7] );
	R( c, d, e, a, b, F1, K1, x[ 8] );
	R( b, c, d, e, a, F1, K1, x[ 9] );
	R( a, b, c, d, e, F1, K1, x[10] );
	R( e, a, b, c, d, F1, K1, x[11] );
	R( d, e, a, b, c, F1, K1, x[12] );
	R( c, d, e, a, b, F1, K1, x[13] );
	R( b, c, d, e, a, F1, K1, x[14] );
	R( a, b, c, d, e, F1, K1, x[15] );
	R( e, a, b, c, d, F1, K1, M(16) );
	R( d, e, a, b, c, F1, K1, M(17) );
	R( c, d, e, a, b, F1, K1, M(18) );
	R( b, c, d, e, a, F1, K1, M(19) );
	R( a, b, c, d, e, F2, K2, M(20) );
	R( e, a, b, c, d, F2, K2, M(21) );
	R( d, e, a, b, c, F2, K2, M(22) );
	R( c, d, e, a, b, F2, K2, M(23) );
	R( b, c, d, e, a, F2, K2, M(24) );
	R( a, b, c, d, e, F2, K2, M(25) );
	R( e, a, b, c, d, F2, K2, M(26) );
	R( d, e, a, b, c, F2, K2, M(27) );
	R( c, d, e, a, b, F2, K2, M(28) );
	R( b, c, d, e, a, F2, K2, M(29) );
	R( a, b, c, d, e, F2, K2, M(30) );
	R( e, a, b, c, d, F2, K2, M(31) );
	R( d, e, a, b, c, F2, K2, M(32) );
	R( c, d, e, a, b, F2, K2, M(33) );
	R( b, c, d, e, a, F2, K2, M(34) );
	R( a, b, c, d, e, F2, K2, M(35) );
	R( e, a, b, c, d, F2, K2, M(36) );
	R( d, e, a, b, c, F2, K2, M(37) );
	R( c, d, e, a, b, F2, K2, M(38) );
	R( b, c, d, e, a, F2, K2, M(39) );
	R( a, b, c, d, e, F3, K3, M(40) );
	R( e, a, b, c, d, F3, K3, M(41) );
	R( d, e, a, b, c, F3, K3, M(42) );
	R( c, d, e, a, b, F3, K3, M(43) );
	R( b, c, d, e, a, F3, K3, M(44) );
	R( a, b, c, d, e, F3, K3, M(45) );
	R( e, a, b, c, d, F3, K3, M(46) );
	R( d, e, a, b, c, F3, K3, M(47) );
	R( c, d, e, a, b, F3, K3, M(48) );
	R( b, c, d, e, a, F3, K3, M(49) );
	R( a, b, c, d, e, F3, K3, M(50) );
	R( e, a, b, c, d, F3, K3, M(51) );
	R( d, e, a, b, c, F3, K3, M(52) );
	R( c, d, e, a, b, F3, K3, M(53) );
	R( b, c, d, e, a, F3, K3, M(54) );
	R( a, b, c, d, e, F3, K3, M(55) );
	R( e, a, b, c, d, F3, K3, M(56) );
	R( d, e, a, b, c, F3, K3, M(57) );
	R( c, d, e, a, b, F3, K3, M(58) );
	R( b, c, d, e, a, F3, K3, M(59) );
	R( a, b, c, d, e, F4, K4, M(60) );
	R( e, a, b, c, d, F4, K4, M(61) );
	R( d, e, a, b, c, F4, K4, M(62) );
	R( c, d, e, a, b, F4, K4, M(63) );
	R( b, c, d, e, a, F4, K4, M(64) );
	R( a, b, c, d, e, F4, K4, M(65) );
	R( e, a, b, c, d, F4, K4, M(66) );
	R( d, e, a, b, c, F4, K4, M(67) );
	R( c, d, e, a, b, F4, K4, M(68) );
	R( b, c, d, e, a, F4, K4, M(69) );
	R( a, b, c, d, e, F4, K4, M(70) );
	R( e, a, b, c, d, F4, K4, M(71) );
	R( d, e, a, b, c, F4, K4, M(72) );
	R( c, d, e, a, b, F4, K4, M(73) );
	R( b, c, d, e, a, F4, K4, M(74) );
	R( a, b, c, d, e, F4, K4, M(75) );
	R( e, a, b, c, d, F4, K4, M(76) );
	R( d, e, a, b, c, F4, K4, M(77) );
	R( c, d, e, a, b, F4, K4, M(78) );
	R( b, c, d, e, a, F4, K4, M(79) );
	
	a = ctx->A += a;
	b = ctx->B += b;
	c = ctx->C += c;
	d = ctx->D += d;
	e = ctx->E += e;
}
}

/* hmac-sha1.c -- hashed message authentication codes
 Copyright (C) 2005, 2006 Free Software Foundation, Inc.
 
 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation; either version 2, or (at your option)
 any later version.
 
 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.
 
 You should have received a copy of the GNU General Public License
 along with this program; if not, write to the Free Software Foundation,
 Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.  */

/* Written by Simon Josefsson.  */

#define IPAD 0x36
#define OPAD 0x5c

void hmac_sha1 (const void *key, size_t keylen, const void *in, size_t inlen, void *resbuf) {
	sha1_ctx_nv inner;
	sha1_ctx_nv outer;
	char optkeybuf[20];
	char block[64];
	char innerhash[20];
	
	/* Reduce the key's size, so that it becomes <= 64 bytes large.  */
	
	if (keylen > 64) {
		sha1_ctx_nv keyhash;
		
		sha1_init_ctx (&keyhash);
		sha1_process_bytes (key, keylen, &keyhash);
		sha1_finish_ctx (&keyhash, optkeybuf);
		
		key = optkeybuf;
		keylen = 20;
    }
	
	/* Compute INNERHASH from KEY and IN.  */
	
	sha1_init_ctx (&inner);
	
	memset(block, IPAD, sizeof (block));
	memxor(block, key, keylen);
	
	sha1_process_block (block, 64, &inner);
	sha1_process_bytes (in, inlen, &inner);
	
	sha1_finish_ctx (&inner, innerhash);
	
	/* Compute result from KEY and INNERHASH.  */
	
	sha1_init_ctx (&outer);
	
	memset (block, OPAD, sizeof (block));
	memxor (block, key, keylen);
	
	sha1_process_block (block, 64, &outer);
	sha1_process_bytes (innerhash, 20, &outer);
	
	sha1_finish_ctx (&outer, resbuf);
}

