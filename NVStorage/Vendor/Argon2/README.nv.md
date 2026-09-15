# Pinned Argon2 reference implementation

Upstream: https://github.com/P-H-C/phc-winner-argon2
Revision: `f57e61e19229e23c4445b85494dbf7c07de721cb`.
The included sources/headers and LICENSE are unmodified upstream bytes, extracted
with `git archive` at that revision. Dual CC0-1.0 / Apache-2.0; see LICENSE.
`include/NVWipe.h` is the sole NV-added bridge declaration, not an upstream file.

SwiftPM builds only the portable reference core (`ref.c`, not CPU-specific
`opt.c`) with `ARGON2_NO_THREADS`. The fixed profile still has **four lanes**;
serial execution does not change its output or reduce its 64-MiB memory cost.
The owning Runtime schedules at most one password KDF at a time. Do not import
the command-line tools, benchmarks, assembly or a runtime-selected weak profile.

Reproduce upstream checks in a disposable checkout at that revision:
`make test OPTTARGET=none NO_THREADS=1`.
The package additionally checks its fixed 65,536-KiB/3-pass/4-lane raw output and
password normalization against independent fixtures.
