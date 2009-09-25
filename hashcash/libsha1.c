/* -*- Mode: C; c-file-style: "stroustrup" -*- */

/*
 * Implementation of Federal Information Processing Standards Publication
 * FIPS 180-1 (17 Apr 1995) which supersedes FIPS 180 (11 May 1993)
 *
 * Speed hack version optimised for speed (see also reference version)
 * uses macros so you need to recompile, not just relink
 *
 * Adam Back <adam@cypherspace.org>
 *
 */

/* define VERBOSE to get output as in fip180-1.txt */
#if defined( VERBOSE )
    #include <stdio.h>
#endif
#include <string.h>
#include "sha1.h"

static int swap_endian32( void*, size_t );

/* A run time endian test.  

   little_endian is the broken one: 80x86s, VAXs
   big_endian is: most unix machines, RISC chips, 68000, etc

   The endianess is stored in macros:

         little_endian
   and   big_endian

   These boolean values can be checked in your code in C expressions.

   They should NOT be tested with conditional macro statements (#ifdef
   etc).
*/

static const int endian_test = 1;

#define little_endian ( *(char*)&endian_test == 1 )

#define big_endian ( ! little_endian )

#define make_big_endian32( data, len ) \
    ( little_endian ? swap_endian32( data, len ) : 0 )

#define make_little_endian32( data, len ) \
    ( little_endian ? 0 : swap_endian32( data, len ) )

#define make_local_endian32( data, len ) \
    ( little_endian ? swap_endian32( data, len ) : 0 )

#if defined( OPENSSL )

void SHA1_Xform( word32* iv, const byte* data ) {
    SHA1_ctx c;
    byte d[SHA1_INPUT_BYTES];

    c.h0=iv[0]; c.h1=iv[1]; c.h2=iv[2]; c.h3=iv[3]; c.h4=iv[4];

/* openSSL SHA1_Transform is in data order, trying to be helpful */
/* #undef SHA1_Transform */
/*    SHA1_Transform( &c, data ); */

    /* but they offer a host order version */
    /* but they don't export it :-( */
    /* sha1_block_asm_host_order( &c, data ); */

/* plan C, copy & convert the data on input */
#undef SHA1_Transform_HC
    if ( little_endian ) { 
	memcpy( d, data, SHA1_INPUT_BYTES );
	make_local_endian32( d, SHA1_INPUT_WORDS );
	SHA1_Transform_HC( &c, d );
    } else {			/* not necessary on big endian */
	SHA1_Transform_HC( &c, data ); 
    }
    iv[0]=c.h0; iv[1]=c.h1; iv[2]=c.h2; iv[3]=c.h3; iv[4]=c.h4;
}

#else

#define min( x, y ) ( ( x ) < ( y ) ? ( x ) : ( y ) )

/********************* function used for rounds 0..19 ***********/

/* #define F1( B, C, D ) ( ( (B) & (C) ) | ( ~(B) & (D) ) ) */

/* equivalent, one less operation: */
#define F1( B, C, D ) ( (D) ^ ( (B) & ( (C) ^ (D) ) ) )


/********************* function used for rounds 20..39 ***********/

#define F2( B, C, D ) ( (B) ^ (C) ^ (D) )

/********************* function used for rounds 40..59 ***********/

/* #define F3( B, C, D ) ( (B) & (C) ) | ( (C) & (D) ) | ( (C) & (D) ) */

/* equivalent, one less operation */

#define F3( B, C, D ) ( ( (B) & ( (C) | (D) )) | ( (C) & (D) ) )

/********************* function used for rounds 60..79 ***********/

#define F4( B, C, D ) ( (B) ^ (C) ^ (D) )

#define K1 0x5A827999  /* constant used for rounds 0..19 */
#define K2 0x6ED9EBA1  /* constant used for rounds 20..39 */
#define K3 0x8F1BBCDC  /* constant used for rounds 40..59 */
#define K4 0xCA62C1D6  /* constant used for rounds 60..79 */

/* magic constants */

#define H0 0x67452301
#define H1 0xEFCDAB89
#define H2 0x98BADCFE
#define H3 0x10325476
#define H4 0xC3D2E1F0

word32 SHA1_IV[ 5 ] = { H0, H1, H2, H3, H4 };

/* rotate X n bits left   ( X <<< n ) */

#define S(n, X) ( ( (X) << (n) ) | ( (X) >> ( 32 - (n) ) ) )

#if defined( word64 )
    #define SHA1_zero_bitcount( ctx )		\
        (ctx)->bits = 0;
#else
    #define SHA1_zero_bitcount( ctx )		\
    (ctx)->lbits = 0;				\
    (ctx)->hbits = 0;
#endif

void SHA1_Init_HC( SHA1_ctx* ctx )
{
    SHA1_zero_bitcount( ctx );
    memcpy( ctx->H, SHA1_IV, SHA1_DIGEST_BYTES );
}

/* this is only used if you want to modify the IV */
/* ignore this function for purposes of the standard */

void SHA1_Init_With_IV( SHA1_ctx* ctx, 
			const byte user_IV[ SHA1_DIGEST_BYTES ] )
{
    SHA1_zero_bitcount( ctx );
    memcpy( ctx->H, user_IV, SHA1_DIGEST_BYTES );
    make_local_endian32( ctx->H, SHA1_DIGEST_WORDS );
}

void SHA1_Transform_HC(  word32 H[ SHA1_DIGEST_WORDS ], 
		      const byte M[ SHA1_INPUT_BYTES ] )
{
#ifdef	COMPACT
    int t = 0 ;
#endif
    word32 A = H[ 0 ];
    word32 B = H[ 1 ];
    word32 C = H[ 2 ];
    word32 D = H[ 3 ];
    word32 E = H[ 4 ];
#if !defined( COMPACT )
    word32 W[ 16 ] = {0};
#else
    word32 W[ 80 ] = {0};
#endif

    memcpy( W, M, SHA1_INPUT_BYTES );

/* Use method B from FIPS-180 (see fip-180.txt) where the use of
   temporary array W of 80 word32s is avoided by working in a circular
   buffer of size 16 word32s.

   (Chromatix:  this is unreasonably slow on x86 due to register
    pressure - going back to method A)
*/

/********************* define some macros *********************/

/* Wc = access W as 16 word circular buffer */

#if !defined( COMPACT )
#define Wc( t ) ( W[ (t) & 0x0F ] )
#else
#define Wc( t ) ( W[ (t) ] )
#endif

/* Calculate access to W array on the fly for entries 16 .. 79 */

#if !defined( COMPACT )
#define Wf( t ) \
    ( Wc( t ) = S( 1, Wc( t ) ^ Wc( t - 14 ) ^ Wc( t - 8 ) ^ Wc( t - 3 ) ) )
#else
#define Wf( t ) \
    ( Wc( t ) = S( 1, Wc( t - 16 ) ^ Wc( t - 14 ) ^ Wc( t - 8 ) ^ Wc( t - 3 ) ) )
#endif

/* Calculate access to W virtual array calculating access to W on the fly */

#if !defined( COMPACT )
#define Wfly( t ) ( (t) < 16 ? Wc( (t) ) : Wf( (t) ) )
#else
#define Wfly( t ) ( Wc( (t) ) )
#endif

#if defined( VERBOSE )
#define REPORT( t, A, B, C, D, E ) \
    fprintf( stderr, "t = %2d: %08X   %08X   %08X   %08X   %08X\n",\
	     t, A, B, C, D, E );
#else
#define REPORT( t, A, B, C, D, E )
#endif

#define ROUND( t, A, B, C, D, E, Func, K ) \
    E += S( 5, A ) + Func( B, C, D ) + Wfly( t ) + K;\
    B = S( 30, B ); REPORT( t, E, A, B, C, D )

/* Remove rotatation E' = D; D' = C; C' = B; B' = A; A' = E; by
   completely unrolling and rotating the arguments to the macro ROUND
   manually so the rotation is compiled in.
*/

#define ROUND5( t, Func, K ) \
    ROUND( t + 0, A, B, C, D, E, Func, K );\
    ROUND( t + 1, E, A, B, C, D, Func, K );\
    ROUND( t + 2, D, E, A, B, C, Func, K );\
    ROUND( t + 3, C, D, E, A, B, Func, K );\
    ROUND( t + 4, B, C, D, E, A, Func, K )

#define ROUND20( t, Func, K )\
    ROUND5( t +  0, Func, K );\
    ROUND5( t +  5, Func, K );\
    ROUND5( t + 10, Func, K );\
    ROUND5( t + 15, Func, K )

/********************* use the macros *********************/

#if defined( VERBOSE ) && !defined( COMPACT )
    for ( t = 0; t < 16; t++ ) {
	fprintf( stderr, "W[%2d] = %08x\n", t, W[ t ] );
    }
    fprintf( stderr, 
"            A           B           C           D           E\n\n" );
#endif

#if defined( COMPACT )
/* initialise W buffer */
    for ( t = 16; t < 80; t++ ) {
        Wf( t );
    }
#endif

/* rounds  0..19 */

    ROUND20(  0, F1, K1 );

/* rounds 21..39 */

    ROUND20( 20, F2, K2 );

/* rounds 40..59 */

    ROUND20( 40, F3, K3 );

/* rounds 60..79 */

    ROUND20( 60, F4, K4 );
    
    H[ 0 ] += A;
    H[ 1 ] += B;
    H[ 2 ] += C;
    H[ 3 ] += D;
    H[ 4 ] += E;
}

void SHA1_Update_HC( SHA1_ctx* ctx, const void* pdata, size_t data_len )
{
    const byte* data = (const byte*)pdata;
    unsigned use = 0 ;
    unsigned mlen = 0 ;
#if !defined( word64 )
    word32 low_bits = 0 ;
#endif

/* convert data_len to bits and add to the 64-bit bit count */

#if defined( word64 )
    mlen = (unsigned)( ( ctx->bits >> 3 ) % SHA1_INPUT_BYTES );
    ctx->bits += ( (word64) data_len ) << 3;
#else
    mlen = (unsigned)( ( ctx->lbits >> 3 ) % SHA1_INPUT_BYTES );
    ctx->hbits += data_len >> 29; /* simulate 64 bit addition */
    low_bits = data_len << 3;
    ctx->lbits += low_bits;
    if ( ctx->lbits < low_bits ) { ctx->hbits++; }
#endif

/* deal with first block */

    use = (unsigned)min( (size_t)(SHA1_INPUT_BYTES - mlen), data_len );
    memcpy( ctx->M + mlen, data, use );
    mlen += use;
    data_len -= use;
    data += use;

    while ( mlen == SHA1_INPUT_BYTES ) {
	make_big_endian32( (word32*)ctx->M, SHA1_INPUT_WORDS );
	SHA1_Transform_HC( ctx->H, ctx->M );
	use = (unsigned)min( SHA1_INPUT_BYTES, data_len );
	memcpy( ctx->M, data, use );
	mlen = use;
	data_len -= use;
        data += use;
    }
}

void SHA1_Final_HC( SHA1_ctx* ctx, byte digest[ SHA1_DIGEST_BYTES ] )
{
    unsigned mlen = 0 ;
    unsigned padding = 0 ;
#if defined( word64 )
    word64 temp = 0 ;
#endif

#if defined( word64 )
    mlen = (unsigned)(( ctx->bits >> 3 ) % SHA1_INPUT_BYTES);
#else
    mlen = (unsigned)(( ctx->lbits >> 3 ) % SHA1_INPUT_BYTES);
#endif

    ctx->M[ mlen ] = 0x80; mlen++; /* append a 1 bit */
    padding = SHA1_INPUT_BYTES - mlen;

#define BIT_COUNT_WORDS 2
#define BIT_COUNT_BYTES ( BIT_COUNT_WORDS * sizeof( word32 ) )

    if ( (unsigned)padding >= BIT_COUNT_BYTES ) {
	memset( ctx->M + mlen, 0x00, padding - BIT_COUNT_BYTES );
	make_big_endian32( ctx->M, SHA1_INPUT_WORDS - BIT_COUNT_WORDS );
    } else {
	memset( ctx->M + mlen, 0x00, SHA1_INPUT_BYTES - mlen );
	make_big_endian32( ctx->M, SHA1_INPUT_WORDS );
	SHA1_Transform_HC( ctx->H, ctx->M );
	memset( ctx->M, 0x00, SHA1_INPUT_BYTES - BIT_COUNT_BYTES );
    }
    
#if defined( word64 )
    if ( little_endian ) {
	temp = ( ctx->bits << 32 | ctx->bits >> 32 );
    } else {
	temp = ctx->bits;
    }
    memcpy( ctx->M + SHA1_INPUT_BYTES - BIT_COUNT_BYTES, &temp, 
	    BIT_COUNT_BYTES );
#else
    memcpy( ctx->M + SHA1_INPUT_BYTES - BIT_COUNT_BYTES, &(ctx->hbits), 
	    BIT_COUNT_BYTES );
#endif
    SHA1_Transform_HC( ctx->H, ctx->M );

    memcpy( digest, ctx->H, SHA1_DIGEST_BYTES );
    make_big_endian32( digest, SHA1_DIGEST_WORDS );
}

#endif

static int swap_endian32( void* data, size_t len )
{
    word32 tmp32 = 0 ;
    byte* tmp32_as_bytes = (byte*) &tmp32;
    word32* data_as_word32s = (word32*) data;
    byte* data_as_bytes = NULL ;
    size_t i = 0 ;
    
    for ( i = 0; i < len; i++ ) {
	tmp32 = data_as_word32s[ i ];
	data_as_bytes = (byte*) &( data_as_word32s[ i ] );
	
	data_as_bytes[ 0 ] = tmp32_as_bytes[ 3 ];
	data_as_bytes[ 1 ] = tmp32_as_bytes[ 2 ];
	data_as_bytes[ 2 ] = tmp32_as_bytes[ 1 ];
	data_as_bytes[ 3 ] = tmp32_as_bytes[ 0 ];
    }
    return 1;
}


#define PAD 64
#define TK  20

void SHA1_HMAC(const void *key, size_t key_len, const void *text, size_t text_len, void *digest)
// text;   /* pointer to data stream */
// key;    /* pointer to authentication key */
// digest; /* caller digest to be filled in */
{
	SHA1_ctx ctx;
	unsigned char k_ipad[PAD+1]; /* inner padding - key XORd with ipad */
	unsigned char k_opad[PAD+1]; /* outer padding - key XORd with opad */
	unsigned char tk[TK];
	
	int i;
	
	if (key_len > PAD) {
		SHA1_ctx tctx;
		SHA1_Init_HC(&tctx);
		SHA1_Update_HC(&tctx, key, key_len);
		SHA1_Final_HC(&tctx, tk);
		key = tk;
		key_len = TK;
	}
	
	/* start out by storing key in pads */
	bzero(k_ipad, PAD);
	memcpy(k_ipad, key, key_len);
	bzero(k_opad, PAD);
	memcpy(k_opad, key, key_len);
	
	/* XOR key with ipad and opad values */
	for (i=0; i<PAD; i++) {
		k_ipad[i] ^= 0x36;
		k_opad[i] ^= 0x5c;
	}
	
	/* perform inner SHA1 */
	SHA1_Init_HC(&ctx);                   /* init ctx for 1st pass */
	SHA1_Update_HC(&ctx, k_ipad, PAD);    /* start with inner pad */
	SHA1_Update_HC(&ctx, text, text_len); /* then text of datagram */
	SHA1_Final_HC(&ctx, digest);          /* finish up 1st pass */
	
	/* perform outer SHA1 */
	SHA1_Init_HC(&ctx);                   /* init ctx for 2nd pass */
	SHA1_Update_HC(&ctx, k_opad, PAD);    /* start with outer pad */
	SHA1_Update_HC(&ctx, digest, TK);     /* then results of 1st hash */
	SHA1_Final_HC(&ctx, digest);          /* finish up 2nd pass */
}
#undef PAD
#undef TK
