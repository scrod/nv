# P6.1 — Local producer qualification

Contract: [local portable-description producer](11-projection-producer-contract.md).
This increment qualifies metadata production and acceptance. The
[completion ledger](06-completion-ledger.md) retains separate settlement/byte-owner
and Intel qualification gates.
The subsequent [retention qualification](12-projection-retention-validation.md)
supplies the current repeated-description work bound and expanded producer suite.
The counts/results below record this increment's original narrower campaign.

## Required observations

- UTF-8 and captured UTF-16 output use their exact encoded-byte digest and complete
  historical binding. Acceptance preserves current notes, authoring context,
  operation/action tables and private observations. A second store accepts the
  actual envelope without acquiring a local file observation.
- A frozen description still names its original value after a newer edit,
  filename intention or Delete. Its completion preserves the newer private
  generation. Wrong-store and reopened-session handle consumers fail.
- Repeated candidate-retention failure, acceptance failure and cancellation-shaped
  lost-retention callbacks return the same handle. Retry preserves object identity,
  exact retained bytes and one acceptance sequence.
- Concurrent preparations reserve distinct writer addresses. Concurrent receive
  ownership yields busy with the original handle; close waits for entered history
  work. A suspended preparation rejects changed private/history inputs or close.
- Actual task cancellation and an exception after committed acceptance preserve
  retained input. Reopening completes/retrieves the same object without the handle.
- The process driver independently checks envelope hashes, source locator/index/ID,
  descriptor bytes, dependency closure, frontier, notes/actions and private rows
  for success, exit-before-commit, exit-after-commit, ENOSPC and EIO. Recovery children
  receive only ordinary selection/unlock inputs. Process exit, I/O failure and
  physical power loss remain different fault classes.
  The original observer compared the entire private table across a killed
  verification and correctly failed on its durable replay reminder. The corrected
  oracle preserves every prior row exactly, permits only the exact store/prefix
  reminder, requires it at both termination cuts, and requires its removal after
  ordinary reopening.
- Compiler probes retain existing checks and add restricted handle/receipt
  construction, immutable locator, private bytes and rejection of a description
  receipt in place of a saved-action receipt: 78 checks in total.
- Four isolated mutations omit final private/view checks, omit the session consumer
  fence, or acknowledge an already accepted prerequisite as the new description.
  Each must fail its designated assertion; valid companions must pass.

## Commands

```sh
make -C tests run-swift-storage \
  'SWIFT_STORAGE_TEST_FLAGS=-c debug --no-parallel --filter projectionProducer'
# Repeat with -c release; use --jobs 1 on the Linux qualification VM.
python3 tools/test-storage-private-types.py --modules NVStorage/.build/debug/Modules
# Repeat for optimized modules and Linux's actual target-triple module directories.
python3 tools/test-storage-runtime-mutations.py --configuration debug \
  --only p61-producer-stale-private --only p61-producer-stale-view \
  --only p61-producer-owner --only p61-producer-early-receipt
# Repeat with --configuration release; preserve the existing cross-product.
```

Finish tests before the explicit standalone product build using the
[existing strict commands](08-portable-projection-validation.md#commands).
Require product completion, then run:

```sh
python3 tools/test-projection-producer-process.py --binary NVStorage/.build/debug/NVStorageProbe
# Repeat for optimized and Linux products.
# Current bounded-growth gate; earlier diagnostic results are retained below:
python3 tools/test-projection-producer-process.py --binary NVStorage/.build/release/NVStorageProbe --retention-growth
```

The phase-2 driver requires every producer function and the process driver;
report 12 expands the original seven functions to eleven. Existing independent transport fixtures, source-binding queries, encoded
output tests, API experiments and model results remain reusable within their
recorded scope: this addition changes neither codecs nor those shared consumers.

## Results

On macOS arm64 / Swift 6.4, all seven functions (14 parameterized/single cases)
passed in debug (9.278 s) and optimized (4.003 s). All 78 compiler probes passed
in both configurations: 36 ordinary clients and 42 sibling-module checks.
Both standalone product builds completed explicitly, and all five independent
process schedules passed for both configurations.

All four selected mutations reached their intended runtime assertions in debug
and optimized builds, with passing companions. Reports are in the macOS temporary
directory under `nv-runtime-mutations-pw37cezf/results.json` and
`nv-runtime-mutations-8_ukoke4/results.json`. The existing mutation cross-product
is unchanged.

Linux arm64 / Swift 6.4 passed all seven functions in debug (1.258 s) and
optimized (0.360 s); both configurations passed all 78 compiler probes. Both
standalone products completed explicitly and passed all five process schedules
and ELF hardening checks, including the RWX negative control. SHA-256 inventories match for all 235 package,
source and test/fixture files between hosts, excluding only Finder metadata.
The legacy application build passed with the previously approved deployment
target override. Independent transport fixtures and index completeness passed.

An optimized build rejected an overlapping test-file edit and is excluded. Final
qualification uses frozen source/test inputs. No compiler or runtime check was
weakened to accommodate that interruption.

The repeated-description gate is covered by the subsequent retention report.
Subsequent [frozen ownership](13-frozen-output-validation.md) and
[settlement/platform qualification](14-settlement-record-validation.md) close
the other P6.1 record gates.
This report does not qualify automatic filesystem output, rooted receipt effects,
physical power-loss durability or bounded startup cost for repeated descriptions.

### Retention-growth diagnostic

With fixed two-note history, the optimized macOS producer left 2, 9 and 65 retained
startup leaves after 1, 8 and 64 descriptions. Independent inspections preserved
the exact action/operation tables and private observations. Three warm whole-child
opens at each size had medians of 13.75, 12.85 and 14.04 ms respectively, including
process startup. These small timings do not establish a regression at everyday
sizes, but the growing required-envelope count is an actual unbounded-work issue.
This earlier experiment records the pre-coverage limitation, not a bounded-work
qualification. Artifacts: `nv-projection-producer-ojm967mj/growth.json` under the
macOS temporary directory. Report 12 records the replacement production gate,
which preserves complete bytes/dependencies and measures acceptance separately.
