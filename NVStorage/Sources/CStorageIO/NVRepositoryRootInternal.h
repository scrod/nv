#ifndef NV_REPOSITORY_ROOT_INTERNAL_H
#define NV_REPOSITORY_ROOT_INTERNAL_H
#include <sys/types.h>
/* The root executor owns this retained descriptor and its loss-event subscription. */
struct NVRootOwner { int directory; int events; int invalidated; int repair_namespace; dev_t device; ino_t inode; };
#endif
