/*
 *  pbkdf2.c
 *
 */

#include "pbkdf2.h"
#include "hmacsha1.h"

#include <stdlib.h>
#include <string.h>

int pbkdf2_sha1(const char *password, size_t Plen, const char *salt, size_t Slen, 
				 unsigned int c, char *derivedKey, size_t dkLen) {
	unsigned int hLen = 20;
	char U[20], T[20];
	unsigned int u, l, r, i, k;
	char *tmp;
	
	size_t tmplen = Slen + 4;
	
	if (!c || !dkLen || dkLen > 4294967295U)
		return 0;
	
	l = (((int)dkLen - 1) / hLen) + 1;
	r = (int)dkLen - (l - 1) * hLen;
	
	if (!(tmp = (char*)malloc(tmplen)))
		return 0;
	
	memcpy(tmp, salt, Slen);
	
	for (i = 1; i <= l; i++) {
		memset (T, 0, hLen);
		
		for (u = 1; u <= c; u++) {
			if (u == 1) {
				tmp[Slen + 0] = (i & 0xff000000) >> 24;
				tmp[Slen + 1] = (i & 0x00ff0000) >> 16;
				tmp[Slen + 2] = (i & 0x0000ff00) >> 8;
				tmp[Slen + 3] = (i & 0x000000ff) >> 0;
				
				hmac_sha1 (password, Plen, tmp, tmplen, U);
			} else
				hmac_sha1 (password, Plen, U, hLen, U);
			
			for (k = 0; k < hLen; k++)
				T[k] ^= U[k];
		}
		
		memcpy(derivedKey + (i - 1) * hLen, T, i == l ? r : hLen);
    }
	
	free(tmp);
	
	return 1;
}
