/* -*- Mode: C; c-file-style: "stroustrup" -*- */

#if !defined( _sha1_h )
#define _sha1_h

/* for size_t */
#include <string.h>
#include <limits.h>

#define word unsigned

#define byte unsigned char 

#define bool byte
#define true 1
#define false 0

#define word8 unsigned char
#define int8 signed char

#define int16 signed short
#define word16 unsigned short

#if ( ULONG_MAX > 0xFFFFFFFFUL )
    #define int32 signed int
    #define word32 unsigned int
    #define int64 signed long
    #define word64 unsigned long
#elif ( UINT_MAX == 0xFFFFFFFFUL )
    #define int32 signed int
    #define word32 unsigned int
#else 
    #define int32 signed long
    #define word32 unsigned long
#endif

#if defined( __GNUC__ ) && !defined( word32 )
    #define int64 signed long long
    #define word64 unsigned long long
#endif


#if defined( __cplusplus )
extern "C" {
#endif

#define SHA1_INPUT_BYTES 64	/* 512 bits */
#define SHA1_INPUT_WORDS ( SHA1_INPUT_BYTES >> 2 )
#define SHA1_DIGEST_WORDS 5	/* 160 bits */
#define SHA1_DIGEST_BYTES ( SHA1_DIGEST_WORDS * 4 )


typedef struct {
    word32 H[ SHA1_DIGEST_WORDS ];
#if defined( word64 )
    word64 bits;		/* we want a 64 bit word */
#else
    word32 hbits, lbits;	/* if we don't have one we simulate it */
#endif
    byte M[ SHA1_INPUT_BYTES ];
} SHA1_ctx;

typedef unsigned int uint32;

typedef struct {
	uint32 a;
	uint32 b;
	uint32 c;
	uint32 d;
	uint32 e;
} SHADGST;

#define SHA_BLKSZ (64) /* Internal block size of the algorithm */

void SHA1_Init_HC  ( SHA1_ctx* );
void SHA1_Update_HC( SHA1_ctx*, const void*, size_t );
void SHA1_Final_HC ( SHA1_ctx*, byte[ SHA1_DIGEST_BYTES ] );

/* these provide extra access to internals of SHA1 for MDC and MACs */

void SHA1_Init_With_IV( SHA1_ctx*, const byte[ SHA1_DIGEST_BYTES ] );


void SHA1_Xform( word32[ SHA1_DIGEST_WORDS ], 
		 const byte[ SHA1_INPUT_BYTES ] );

void SHA1_HMAC(const void *key, size_t key_len, const void *text, size_t text_len, void *digest);

#if defined( __cplusplus )
}
#endif

#endif
