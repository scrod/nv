# Phase 3: conservative merge engine qualification

The [merge contract](conservative-merge-contract.md) connects the pinned plaintext
algorithm to a complete per-birth note graph and an owned, detached history preview.
This records the initial merge-engine increment. The later [connected report](phase3-validation.md)
qualifies editable multi-head Current, authoring and fresh reopening; the
initial preview-only results below retain their original scope.

## Evidence and independent expectations

- **3,249 generated edit pairs, both orders**: expected bodies are assembled from
  the original edit coordinates, independently of production interval inference.
- **27 scalar and eight membership combinations**; exact label spelling and
  date behavior; CRLF, NUL, composed/decomposed Unicode, repeated lines, empty and
  unterminated text, touching inserts, multi-hunk bounding intervals; 10,000/10,001
  tokens with equality/one-sided exceptions; combined-value size limit.
- **315 rooted five-node DAGs**: a separate all-pairs reachability calculation
  checks heads and unique/multiple best bases. Named fixtures cover a late third
  head, a dominating descendant, equal-value represented IDs, crisscross bases,
  a knowledge-only alternative, Delete, missing predecessors and wrong births.
- Literal value, operation and merge-identity bytes are independently generated
  by Python and checked against Swift. Collection binding and exact result-value
  hashing participate in the identity.
- Independent stores exchange actual public/encrypted envelopes, with child-first
  parking/restart and reversed acceptance order. They produce the independently
  expected merged body, head IDs and identical descriptor while retaining the
  inputs. Repeated preview creates no history record or acceptance batch.
- Damaged retained envelopes and contradictory membership each have a valid
  companion and block subsequent editing through the existing damage gate.
- Six process schedules distinguish normal receipt, termination after input
  retention, and termination after acceptance. The first requires recovered ready
  work; the second already has complete accepted evidence despite callback loss.
  Fresh processes read real accepted envelopes from the surviving SQLCipher store
  and recompute exact merge evidence. This test-only inspection bypasses the
  still-unsupported editable multi-head opener; it is not a claim that ordinary
  current-row reopen supports merges yet.

Swift Testing guidance informed isolated stores and parameterized cases. Mutation
controls require designated assertion failures for accepting touching intervals,
using causal knowledge as supersession, dropping a represented head and omitting
collection binding. Compiler probes cover descriptor/represented-value issuers,
merge/operation identity separation and the store-issued preview boundary.

## Model correspondence

The implementation follows `SegmentMergeSafety`'s distinct knowledge/note graphs,
complete heads, unique best base, equal-value representation and absence of
automatic operations. The model abstracts fields and explicitly excludes the LF
kernel; the generated concrete cases supply that evidence. Static correspondence
was checked against the model, configuration and documented runner. No model or
policy changed, so TLC was not rerun. Publication, edits of derived results and
deletion/compensation are still future implementation gates, not new proof claims.

## Qualification

```sh
python3 tools/test-storage-phase2.py --configuration debug
python3 tools/test-storage-phase2.py --configuration release
python3 tools/test-storage-runtime-mutations.py --only merge-touching-intervals --only merge-knowledge-supersedes --only merge-dropped-represented-input --only merge-omitted-collection-domain
```

### Results — 2026-09-17

- macOS arm64, Swift 6.4: debug and optimized qualification each passed all
  22 stages and discovered 116 active Swift test functions (117 runner entries
  including the disabled benchmark). Each includes six fresh-process merge schedules, both
  profiles, independent fixtures, 27 Core and 42 Runtime compiler probes plus
  their diagnostic-classifier self-checks, schema checks and strict C diagnostics.
- The four isolated merge mutations each compiled and failed their designated
  assertion. The unmodified companion suite passed. Mutation test execution is
  serialized so concurrent diagnostic output cannot corrupt exact source-line
  classification; concurrency exercised inside tests remains intact.
- Ubuntu arm64, Swift 6.1.3: all ten new merge test functions passed in an optimized
  build, as did all six fresh-process schedules and the independent byte fixture.
  The same literal identity and exact UTF-8 expectations were checked on both
  platforms. All 27 Core and 42 Runtime compiler probes and their diagnostic
  self-checks passed against that build, preserving the same access-control and
  actor-isolation boundaries under Swift 6.1.
- The macOS application built successfully with the existing
  `__DIAGNOSE_INVALID_DEPLOYMENT_TARGET_AS_ERROR=NO` override; Xcode 27 retains its
  deployment-target warning. Application/UI source was unchanged.

Local debug artifacts: `nv-storage-phase2-5ob_srms`; optimized artifacts:
`nv-storage-phase2-_h7emqyn`; mutation artifacts:
`nv-runtime-mutations-nok_98wn`, under the host's temporary directory. Ubuntu
artifacts are retained under `/tmp/nv-storage-disk`, including
`nv-merge-linux.log`, `nv-merge-linux-process.log` and `nv-merge-process-ebx079ut`.

Intel macOS execution, physical power loss, provider behavior, AppKit integration
and full-history preview resource limits remain separate qualification gates.
