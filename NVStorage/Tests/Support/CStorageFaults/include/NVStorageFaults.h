#ifndef NV_STORAGE_FAULTS_H
#define NV_STORAGE_FAULTS_H
#include <stdint.h>
/* Process-probe controls for SQLCipher transactions and VFS failure schedules. */
enum { NV_FAULT_WRITE=1, NV_FAULT_SYNC=2, NV_FAULT_LOCK=3,
       NV_FAULT_COMMIT_BEGIN=4, NV_FAULT_COMMIT_END=5, NV_FAULT_VIEW_UPDATE=6,
       NV_FAULT_CURRENT_INSERT=7, NV_FAULT_SYNC_AFTER=8,
       NV_FAULT_REJECTION_BEGIN=9, NV_FAULT_REJECTION_CLEANUP=10,
       NV_FAULT_PARK_BEGIN=11 };
int nv_faults_install(void);
void nv_faults_arm(int event, int ordinal, int result);
void nv_faults_arm_on_rejection(int event, int ordinal, int result);
void nv_faults_arm_on_association(int event, int ordinal, int result);
/* Arms an I/O failure at the real required-history diagnosis transaction. */
void nv_faults_arm_on_damage(int event, int ordinal, int result);
/* Arms an exact-request settlement fault after successful history inspection. */
void nv_faults_arm_on_verification_settlement(int event, int ordinal, int result);
/* Arms a fault inside the transaction installing complete current rows and context. */
void nv_faults_arm_on_materialization(int event, int ordinal, int result);
/* Arms a cut when the real waiting transaction records an exact prerequisite. */
void nv_faults_arm_on_parking(int event, int ordinal, int result);
/* Arms acceptance faults at its writer lock, membership writes or commit. */
void nv_faults_arm_on_history_acceptance(int event, int ordinal, int result);
/* Arms a pending-observation settlement fault after its represented-history checks. */
void nv_faults_arm_on_pending_settlement(int event, int ordinal, int result);
/* Arms a cut inside the replacement's complete private-reference installation transaction. */
void nv_faults_arm_on_repair_private_installation(int event, int ordinal, int result);
int nv_faults_hits(void);
int64_t nv_faults_steps(void);
void nv_faults_reset_steps(void);
void nv_faults_hold(int event, int ordinal);
void nv_faults_wait_until_held(void);
void nv_faults_release(void);
/* Portable exact metadata fixtures for the production rooted-copy path. */
int nv_fixture_set_attribute(const char *path, const char *name, const uint8_t *bytes, uint64_t count);
int64_t nv_fixture_get_attribute(const char *path, const char *name, uint8_t *bytes, uint64_t count);
#endif
