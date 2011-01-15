/*
 *  idea_ossl.c
 *
 */

#include "idea_ossl.h"

#define IDEA_BLOCK	8
#define IDEA_KEY_LENGTH	16

/* The new form of this macro (check if the a*b == 0) was suggested by 
* Colin Plumb <colin@nyx10.cs.du.edu> */
/* Removal of the inner if from from Wei Dai 24/4/96 */
#define idea_mul(r,a,b,ul) \
ul=(unsigned long)a*b; \
if (ul != 0) \
{ \
	r=(ul&0xffff)-(ul>>16); \
		r-=((r)>>16); \
} \
else \
r=(-(int)a-b+1); /* assuming a or b is 0 and in range */ \

#ifdef undef
#define idea_mul(r,a,b,ul,sl) \
if (a == 0) r=(0x10001-b)&0xffff; \
else if (b == 0) r=(0x10001-a)&0xffff; \
else	{ \
	ul=(unsigned long)a*b; \
		sl=(ul&0xffff)-(ul>>16); \
			if (sl <= 0) sl+=0x10001; \
				r=sl; \
} 
#endif

/*  7/12/95 - Many thanks to Rhys Weatherley <rweather@us.oracle.com>
* for pointing out that I was assuming little endian
* byte order for all quantities what idea
* actually used bigendian.  No where in the spec does it mention
* this, it is all in terms of 16 bit numbers and even the example
* does not use byte streams for the input example :-(.
													 * If you byte swap each pair of input, keys and iv, the functions
													 * would produce the output as the old version :-(.
																									  */

/* NOTE - c is not incremented as per n2l */
#define n2ln(c,l1,l2,n)	{ \
	c+=n; \
		l1=l2=0; \
			switch (n) { \
				case 8: l2 =((unsigned long)(*(--(c))))    ; \
				case 7: l2|=((unsigned long)(*(--(c))))<< 8; \
				case 6: l2|=((unsigned long)(*(--(c))))<<16; \
				case 5: l2|=((unsigned long)(*(--(c))))<<24; \
				case 4: l1 =((unsigned long)(*(--(c))))    ; \
				case 3: l1|=((unsigned long)(*(--(c))))<< 8; \
				case 2: l1|=((unsigned long)(*(--(c))))<<16; \
				case 1: l1|=((unsigned long)(*(--(c))))<<24; \
			} \
}

/* NOTE - c is not incremented as per l2n */
#define l2nn(l1,l2,c,n)	{ \
	c+=n; \
		switch (n) { \
			case 8: *(--(c))=(unsigned char)(((l2)    )&0xff); \
			case 7: *(--(c))=(unsigned char)(((l2)>> 8)&0xff); \
			case 6: *(--(c))=(unsigned char)(((l2)>>16)&0xff); \
			case 5: *(--(c))=(unsigned char)(((l2)>>24)&0xff); \
			case 4: *(--(c))=(unsigned char)(((l1)    )&0xff); \
			case 3: *(--(c))=(unsigned char)(((l1)>> 8)&0xff); \
			case 2: *(--(c))=(unsigned char)(((l1)>>16)&0xff); \
			case 1: *(--(c))=(unsigned char)(((l1)>>24)&0xff); \
		} \
}

#undef n2l
#define n2l(c,l)        (l =((unsigned long)(*((c)++)))<<24L, \
                         l|=((unsigned long)(*((c)++)))<<16L, \
                         l|=((unsigned long)(*((c)++)))<< 8L, \
                         l|=((unsigned long)(*((c)++))))

#undef l2n
#define l2n(l,c)        (*((c)++)=(unsigned char)(((l)>>24L)&0xff), \
                         *((c)++)=(unsigned char)(((l)>>16L)&0xff), \
                         *((c)++)=(unsigned char)(((l)>> 8L)&0xff), \
                         *((c)++)=(unsigned char)(((l)     )&0xff))

#undef s2n
#define s2n(l,c)	(*((c)++)=(unsigned char)(((l)     )&0xff), \
					 *((c)++)=(unsigned char)(((l)>> 8L)&0xff))

#undef n2s
#define n2s(c,l)	(l =((IDEA_INT)(*((c)++)))<< 8L, \
					 l|=((IDEA_INT)(*((c)++)))      )

#ifdef undef
/* NOTE - c is not incremented as per c2l */
#define c2ln(c,l1,l2,n)	{ \
	c+=n; \
		l1=l2=0; \
			switch (n) { \
				case 8: l2 =((unsigned long)(*(--(c))))<<24; \
				case 7: l2|=((unsigned long)(*(--(c))))<<16; \
				case 6: l2|=((unsigned long)(*(--(c))))<< 8; \
				case 5: l2|=((unsigned long)(*(--(c))));     \
				case 4: l1 =((unsigned long)(*(--(c))))<<24; \
				case 3: l1|=((unsigned long)(*(--(c))))<<16; \
				case 2: l1|=((unsigned long)(*(--(c))))<< 8; \
				case 1: l1|=((unsigned long)(*(--(c))));     \
			} \
}

/* NOTE - c is not incremented as per l2c */
#define l2cn(l1,l2,c,n)	{ \
	c+=n; \
		switch (n) { \
			case 8: *(--(c))=(unsigned char)(((l2)>>24)&0xff); \
			case 7: *(--(c))=(unsigned char)(((l2)>>16)&0xff); \
			case 6: *(--(c))=(unsigned char)(((l2)>> 8)&0xff); \
			case 5: *(--(c))=(unsigned char)(((l2)    )&0xff); \
			case 4: *(--(c))=(unsigned char)(((l1)>>24)&0xff); \
			case 3: *(--(c))=(unsigned char)(((l1)>>16)&0xff); \
			case 2: *(--(c))=(unsigned char)(((l1)>> 8)&0xff); \
			case 1: *(--(c))=(unsigned char)(((l1)    )&0xff); \
		} \
}

#undef c2s
#define c2s(c,l)	(l =((unsigned long)(*((c)++)))    , \
					 l|=((unsigned long)(*((c)++)))<< 8L)

#undef s2c
#define s2c(l,c)	(*((c)++)=(unsigned char)(((l)     )&0xff), \
					 *((c)++)=(unsigned char)(((l)>> 8L)&0xff))

#undef c2l
#define c2l(c,l)	(l =((unsigned long)(*((c)++)))     , \
					 l|=((unsigned long)(*((c)++)))<< 8L, \
					 l|=((unsigned long)(*((c)++)))<<16L, \
					 l|=((unsigned long)(*((c)++)))<<24L)

#undef l2c
#define l2c(l,c)	(*((c)++)=(unsigned char)(((l)     )&0xff), \
					 *((c)++)=(unsigned char)(((l)>> 8L)&0xff), \
					 *((c)++)=(unsigned char)(((l)>>16L)&0xff), \
					 *((c)++)=(unsigned char)(((l)>>24L)&0xff))
#endif

#define E_IDEA(num) \
x1&=0xffff; \
idea_mul(x1,x1,*p,ul); p++; \
x2+= *(p++); \
x3+= *(p++); \
x4&=0xffff; \
idea_mul(x4,x4,*p,ul); p++; \
t0=(x1^x3)&0xffff; \
idea_mul(t0,t0,*p,ul); p++; \
t1=(t0+(x2^x4))&0xffff; \
idea_mul(t1,t1,*p,ul); p++; \
t0+=t1; \
x1^=t1; \
x4^=t0; \
ul=x2^t0; /* do the swap to x3 */ \
x2=x3^t1; \
x3=ul;

//typedef unsigned char	byte;		// 1 byte = 8 bits  (unsigned)
//typedef unsigned short	word16;		// 2 byte = 16 bits (unsigned)
//typedef unsigned int	word32;		// 4 byte = 32 bits (unsigned)
//typedef int		s_word32;	// 4 byte = 32 bits (signed)


static IDEA_INT inverse(unsigned int xin);
void idea_set_encrypt_key(const unsigned char *key, IDEA_KEY_SCHEDULE *ks)
{
	int i;
	register IDEA_INT *kt,*kf,r0,r1,r2;
	
	kt= &(ks->data[0][0]);
	n2s(key,kt[0]); n2s(key,kt[1]); n2s(key,kt[2]); n2s(key,kt[3]);
	n2s(key,kt[4]); n2s(key,kt[5]); n2s(key,kt[6]); n2s(key,kt[7]);
	
	kf=kt;
	kt+=8;
	for (i=0; i<6; i++)
	{
		r2= kf[1];
		r1= kf[2];
		*(kt++)= ((r2<<9) | (r1>>7))&0xffff;
		r0= kf[3];
		*(kt++)= ((r1<<9) | (r0>>7))&0xffff;
		r1= kf[4];
		*(kt++)= ((r0<<9) | (r1>>7))&0xffff;
		r0= kf[5];
		*(kt++)= ((r1<<9) | (r0>>7))&0xffff;
		r1= kf[6];
		*(kt++)= ((r0<<9) | (r1>>7))&0xffff;
		r0= kf[7];
		*(kt++)= ((r1<<9) | (r0>>7))&0xffff;
		r1= kf[0];
		if (i >= 5) break;
		*(kt++)= ((r0<<9) | (r1>>7))&0xffff;
		*(kt++)= ((r1<<9) | (r2>>7))&0xffff;
		kf+=8;
	}
}

void idea_set_decrypt_key(IDEA_KEY_SCHEDULE *ek, IDEA_KEY_SCHEDULE *dk)
{
	int r;
	register IDEA_INT *fp,*tp,t;
	
	tp= &(dk->data[0][0]);
	fp= &(ek->data[8][0]);
	for (r=0; r<9; r++)
	{
		*(tp++)=inverse(fp[0]);
		*(tp++)=((int)(0x10000L-fp[2])&0xffff);
		*(tp++)=((int)(0x10000L-fp[1])&0xffff);
		*(tp++)=inverse(fp[3]);
		if (r == 8) break;
		fp-=6;
		*(tp++)=fp[4];
		*(tp++)=fp[5];
	}
	
	tp= &(dk->data[0][0]);
	t=tp[1];
	tp[1]=tp[2];
	tp[2]=t;
	
	t=tp[49];
	tp[49]=tp[50];
	tp[50]=t;
}

/* taken directly from the 'paper' I'll have a look at it later */
static IDEA_INT inverse(unsigned int xin)
{
	long n1,n2,q,r,b1,b2,t;
	
	if (xin == 0)
		b2=0;
	else
	{
		n1=0x10001;
		n2=xin;
		b2=1;
		b1=0;
		
		do	{
			r=(n1%n2);
			q=(n1-r)/n2;
			if (r == 0)
			{ if (b2 < 0) b2=0x10001+b2; }
			else
			{
				n1=n2;
				n2=r;
				t=b2;
				b2=b1-q*b2;
				b1=t;
			}
		} while (r != 0);
	}
	return((IDEA_INT)b2);
}

void idea_encrypt(unsigned long *d, IDEA_KEY_SCHEDULE *key)
{
	register IDEA_INT *p;
	register unsigned long x1,x2,x3,x4,t0,t1,ul;
	
	x2=d[0];
	x1=(x2>>16);
	x4=d[1];
	x3=(x4>>16);
	
	p= &(key->data[0][0]);
	
	E_IDEA(0);
	E_IDEA(1);
	E_IDEA(2);
	E_IDEA(3);
	E_IDEA(4);
	E_IDEA(5);
	E_IDEA(6);
	E_IDEA(7);
	
	x1&=0xffff;
	idea_mul(x1,x1,*p,ul); p++;
	
	t0= x3+ *(p++);
	t1= x2+ *(p++);
	
	x4&=0xffff;
	idea_mul(x4,x4,*p,ul);
	
	d[0]=(t0&0xffff)|((x1&0xffff)<<16);
	d[1]=(x4&0xffff)|((t1&0xffff)<<16);
}

void idea_cfb64_encrypt(const unsigned char *in, unsigned char *out,
						long length, IDEA_KEY_SCHEDULE *schedule,
						unsigned char *ivec, int *num, int encrypt)
{
	register unsigned long v0,v1,t;
	register int n= *num;
	register long l=length;
	unsigned long ti[2];
	unsigned char *iv,c,cc;
	
	iv=(unsigned char *)ivec;
	if (encrypt)
	{
		while (l--)
		{
			if (n == 0)
			{
				n2l(iv,v0); ti[0]=v0;
				n2l(iv,v1); ti[1]=v1;
				idea_encrypt((unsigned long *)ti,schedule);
				iv=(unsigned char *)ivec;
				t=ti[0]; l2n(t,iv);
				t=ti[1]; l2n(t,iv);
				iv=(unsigned char *)ivec;
			}
			c= *(in++)^iv[n];
			*(out++)=c;
			iv[n]=c;
			n=(n+1)&0x07;
		}
	}
	else
	{
		while (l--)
		{
			if (n == 0)
			{
				n2l(iv,v0); ti[0]=v0;
				n2l(iv,v1); ti[1]=v1;
				idea_encrypt((unsigned long *)ti,schedule);
				iv=(unsigned char *)ivec;
				t=ti[0]; l2n(t,iv);
				t=ti[1]; l2n(t,iv);
				iv=(unsigned char *)ivec;
			}
			cc= *(in++);
			c=iv[n];
			iv[n]=cc;
			*(out++)=c^cc;
			n=(n+1)&0x07;
		}
	}
	v0=v1=ti[0]=ti[1]=t=c=cc=0;
	*num=n;
}

