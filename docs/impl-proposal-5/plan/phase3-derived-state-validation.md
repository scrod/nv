# Phase 3: equal/merge state-reference qualification

The [derived-state contract](derived-state-reference-contract.md) is the first
encoding/validation increment for the [M1–M3/A1 matrix](phase3-schedule-observation-matrix.md#41-editable-multi-head-state-and-action-capture).
It implements the exact represented-state records that editable merge/equal
Current uses. This report records the initial component increment; the later
[connected report](phase3-validation.md) covers current cells, action capture,
writer-history admission and fresh editable reopen through the production runtime.

## Evidence and independent expectations

`DerivedStateTests.swift` contains five test functions, two parameterized for equal
and merged variants. They check:

- Independent 119-byte equal and 194-byte merge fixtures. Python constructs the
  exact operation IDs, result digests, merge identity and transport bytes; Swift
  compares literals and independently specified expected values. Re-encoding and
  multiple history-array orders are supplementary checks.
- Every truncation of both fixtures, trailing data, unsupported tags/policies,
  bad counts, reversed/duplicate inputs, and encoder/reconstructor rejection of
  changed local-prefix bindings, including a swap that preserves the complete
  expanded ID set but changes reference order. A remapped dependency index changes transport
  bytes while preserving the expanded claim.
- Exact locator/index/ID resolution; missing source or graph membership; wrong
  birth, merge collection, digest, merge identity and base. Valid companions
  reconstruct the expected contents before each defect family is challenged.
- A late third head, a replacing descendant, an omitted equal head and multiple
  best bases. The original writer-basis claim remains reconstructible even when
  the receiver separately learns later history.
- An equal Current class alongside an incompatible alternative. The checked
  result preserves the complete head set and only the selected class's represented
  inputs. A later edit's knowledge of the alternative leaves it unconsumed.

Review exposed a reference-rebinding defect: comparing expanded sets alone can
miss a swap of two local inputs. Encoding must also preserve each reference's
canonical position under its supplied prefix. The regression covers derived
inputs, ordinary operation parents and action scope parents, with valid unchanged
prefix companions. Each ordinary parent vector is challenged while the other
vector's external addresses stay fixed. This enforces the existing canonical-encoding contract rather
than changing bytes or assigning new semantics to history.

These are supplied-graph component fixtures. The containing envelope's validation
must establish complete writer-history membership, scope maxima, ownership and
generation context. In particular, a caller-supplied collection plus equal-state
claim does not authenticate a collection: that remains the envelope/owner boundary.
The merge identity additionally binds the collection cryptographically.

`ReconstructedDerivedStateV1` carries the exact graph result through a file-private
initializer. Positive ordinary clients can decode and reconstruct; ordinary-client
and same-module probes challenge direct construction and passing a raw claim to a
checked-result consumer. External lookup is asynchronous for the existing actor
history-read path; final publication fencing remains integration work.

Six isolated mutations remove result-digest, represented-input, merge-identity,
base, exact-occurrence or rebound-reference-order checks. Each must compile and fail its designated Swift
assertion after an unmodified companion passes. The normal qualification driver
requires nonzero discovery of all five functions and the independent fixture.

## Run the increment

```sh
python3 tools/test-storage-phase2.py --configuration debug
python3 tools/test-storage-phase2.py --configuration release
python3 tools/test-storage-runtime-mutations.py --only derived-state-wrong-result --only derived-state-omitted-input --only derived-state-wrong-identity --only derived-state-wrong-base --only derived-state-wrong-occurrence --only derived-state-rebound-order
```

## Model correspondence and remaining gates

The existing `SegmentMergeSafety` distinction between causal knowledge and note
replacement still applies, as do complete equal inputs, unique merge base and
context-bound deterministic identity. The new code implements nested bytes and
reconstruction; it changes no modeled transition or policy. TLC is therefore not
rerun for this increment. Component tests cannot qualify the matrix's receipt
races, post-merge saved edits, SQL current-row installation or fresh editable
reopening; those require the actual runtime consumers next.

No persistent table, sidecar, long-lived validation cache, provider behavior or
application interaction is added. Additional platform execution, physical power
loss and final provider/AppKit integration remain separate qualification scopes.

## Results — 2026-09-18

- macOS arm64, Swift 6.4: both debug and optimized qualification drivers passed
  all 23 stages and discovered 121 active Swift test functions (122 runner entries
  including the disabled benchmark). These include the existing two-profile
  process-recovery, generated delivery/fault, history/Restore/merge-preview,
  rejection, schema, independent-fixture and strict C checks.
- All six isolated derived-state mutations compiled and failed their designated
  assertions. Their unmodified companion suites passed; mutation-classifier
  self-checks also passed. The reference-order review additionally reproduced
  both existing operation/action encoder failures before correction and passed
  their unchanged-prefix/rebound-prefix companions afterward.
- All 31 Core and 42 Runtime construction/consumer probes passed, along with
  their diagnostic-classifier self-checks. The new public asynchronous lookup
  API type-checks from both an ordinary client and a separate same-module file.
- Complete debug and optimized Swift suites were rerun after the final
  parent-order fixes; both passed all 122 runner entries. A build interrupted
  by a test-source edit is excluded from qualification.
- The application build passed with the existing
  `__DIAGNOSE_INVALID_DEPLOYMENT_TARGET_AS_ERROR=NO` override. The normal
  `build.sh` invocation reports Xcode 27's deployment-target error for 11.5;
  the override preserves that target and emits its warning. UI source is unchanged.
- Ubuntu was reachable, but its existing test volume had approximately 65 MiB
  free. This increment's Linux execution was left unqualified; no remote files
  were deleted. Intel macOS execution and physical power loss remain unqualified.

Driver artifacts under the host temporary directory:
`nv-storage-phase2-usqfacex` (debug), `nv-storage-phase2-ay291ej1` (optimized).
Mutation artifacts: `nv-runtime-mutations-vn23x9pc` (five semantic controls),
`nv-runtime-mutations-o13npwzl` (reference-order control). Final Swift rerun logs
are `/tmp/nv-derived-state-qualified-{debug,release}-swift.log`; the deliberate
pre-fix failures are `/tmp/nv-derived-state-parent-order-red.log`.

The broader drivers ran while the increment was being completed; the final Swift
reruns cover the subsequent parent-order regressions and corrections. None of
these existing fresh-process passes qualifies editable equal/merged Current:
that connection remains the next M1–M3/A1 implementation gate.
