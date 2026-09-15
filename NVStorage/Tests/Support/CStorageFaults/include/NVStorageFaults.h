#ifndef NV_STORAGE_FAULTS_H
#define NV_STORAGE_FAULTS_H
#include <stdint.h>
/* Private to the process probe. Production library targets do not depend on this module. */
enum { NV_FAULT_WRITE=1, NV_FAULT_SYNC=2, NV_FAULT_LOCK=3,
       NV_FAULT_COMMIT_BEGIN=4, NV_FAULT_COMMIT_END=5, NV_FAULT_VIEW_UPDATE=6,
       NV_FAULT_CURRENT_INSERT=7, NV_FAULT_SYNC_AFTER=8,
       NV_FAULT_REJECTION_BEGIN=9, NV_FAULT_REJECTION_CLEANUP=10 };
int nv_faults_install(void);
void nv_faults_arm(int event, int ordinal, int result);
void nv_faults_arm_on_rejection(int event, int ordinal, int result);
int nv_faults_hits(void);
int64_t nv_faults_steps(void);
void nv_faults_reset_steps(void);
void nv_faults_hold(int event, int ordinal);
void nv_faults_wait_until_held(void);
void nv_faults_release(void);
#endif
