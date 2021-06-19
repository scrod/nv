/*
 *  FSExchangeObjectsCompat.h
 *  Notation
 *
 */

#include <Carbon/Carbon.h>

OSErr FSExchangeObjectsEmulate(const FSRef *sourceRef, const FSRef *destRef, FSRef *newSourceRef, FSRef *newDestRef);
Boolean VolumeOfFSRefSupportsExchangeObjects(const FSRef *fsRef);
u_int32_t volumeCapabilities(const char *path);
