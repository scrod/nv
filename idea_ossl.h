/*
 *  idea_ossl.h
 *
 */


#define IDEA_ENCRYPT	1
#define IDEA_DECRYPT	0
#define IDEA_INT unsigned int

typedef struct idea_key_st
{
	IDEA_INT data[9][6];
} IDEA_KEY_SCHEDULE;

void idea_set_encrypt_key(const unsigned char *key, IDEA_KEY_SCHEDULE *ks);
void idea_set_decrypt_key(IDEA_KEY_SCHEDULE *ek, IDEA_KEY_SCHEDULE *dk);
void idea_cfb64_encrypt(const unsigned char *in, unsigned char *out,
						long length, IDEA_KEY_SCHEDULE *ks, unsigned char *iv,
						int *num,int enc);
