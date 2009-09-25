
#ifndef MD5_H
#define MD5_H

typedef unsigned char	byte;		// 1 byte = 8 bits  (unsigned)
typedef unsigned short	word16;		// 2 byte = 16 bits (unsigned)
typedef unsigned int	word32;		// 4 byte = 32 bits (unsigned)
typedef int		s_word32;	// 4 byte = 32 bits (signed)

struct BrokenMD5Context {
	word32 buf[4];
	word32 bits[2];
	unsigned char in[64];
};

void BrokenMD5Init(struct BrokenMD5Context *context);
void BrokenMD5Update(struct BrokenMD5Context *context, unsigned char const *buf,
	       unsigned len);
void BrokenMD5Final(byte digest[16], struct BrokenMD5Context *context);
void BrokenMD5Transform(word32 buf[4], word32 const in[16]);

/*
 * This is needed to make RSAREF happy on some MS-DOS compilers.
 */
typedef struct BrokenMD5Context BrokenMD5_CTX;

#endif /* !MD5_H */
