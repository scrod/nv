/*
 *  pbkdf2.h
 *
 */

#include <stdint.h>
#include <sys/types.h>

extern int pbkdf2_sha1(const char *password, size_t Plen, const char *salt, size_t Slen, 
					   unsigned int c, char *derivedKey, size_t dkLen);
