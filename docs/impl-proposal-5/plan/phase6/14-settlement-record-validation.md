# P6.1 — Settlement records and final platform qualification

Contract: [complete settlement mapping](14-settlement-record-contract.md).
This closes P6.1's passive-record and consumed-input consumer gates. Physical
projection receipt issuance, root checks and transactional owner advancement
remain P6.2/P6.4; codec tests do not qualify those effects.

## Checks and independent observations

| Check | Required observation |
| --- | --- |
| `pendingSettlementIndependentLayouts` | Python-authored consumed/neutral/projection fixtures; exact identifiers, scope, subsequent work and tagged outcome; strict truncated-prefix, trailing-byte, version and profile checks |
| `projectionSettlementTransfersExactFrozenOwners` | B replaces accepted A while C stays intended with B as its source; latest B clears; repeated B, missing frozen owner, different scope and inconsistent source reject |
| `projectionSettlementRejectsIncompleteSourceAccounting` | Exact frozen/accepted output equality, positive bounded relationship generation, required source accounting and valid source-free companion |
| `pendingSettlementRecordIsAtomicAndRetainsDecision` | Two failed writes retain the reservation, old payload, newer preview and prior generation; success stores the complete decision/index digest, releases only the settled payload, and survives reopen and complete private validation; a fresh-store private copy preserves the old captured scope, complete settlement, newer preview and exact history bytes |
| `pendingSettlementChecksIndexedIdentityAndScope` | Every indexed identity/digest, unsupported codec, malformed record and foreign captured scope reject at the actual reader; restoring each correct value passes; exceptional validation also rejects the foreign scope |
| Existing pending/backup companions | Lost receipt followed by Delete/new preview, neutral and changed association, repair preparation fencing and private-copy preservation retain their prior outcomes |
| Fresh-process settlement schedules | Before/after-commit termination, ENOSPC and EIO across both profiles; a second interrupted attempt; exact import survives later Delete; newer preview remains; parent independently decodes full settlement SQL bytes and inspects six operations/four actions |

The child receives the surviving store and normal selection/unlock inputs, not
the parent's expected-note oracle or acknowledgment log. The independent parser
checks magic/version, captured scope, item, snapshot, complete reservation, nonce/
action-containing reservation digest, operation/birth, consumed outcome framing
and the exact subsequent snapshot ID. Recovery decides ambiguous completion from
durable state, not callback success. Termination and injected I/O outcomes remain
distinct from physical power-loss qualification.

The runtime `PendingSettlement` constructor is fileprivate. All ordinary and
sibling-module probes pass: **40 ordinary + 46 same-module = 86 checks**. Passive
Core records remain publicly constructible, while existing typed preparation and
private capture boundaries prevent using them as live installation authority.

Three isolated production-source mutations remove the decision-digest check,
captured-scope check, or subsequent-input link. All fail at their designated
assertions under debug and optimized builds, with passing unchanged baselines,
nonzero discovery and the existing mutation cross-product preserved.

## Recorded results

| Platform/configuration | Result |
| --- | --- |
| macOS arm64, Swift 6.4 debug | 20 focused functions pass (464.252 s, including an existing repair-growth companion selected by the broad filter); all 86 construction probes; three targeted mutations; eight settlement process schedules |
| macOS arm64, Swift 6.4 optimized | 13 focused functions pass (9.282 s); all 86 construction probes; same three mutations; eight settlement process schedules |
| Ubuntu arm64, Swift 6.4 debug/optimized | Same ten core settlement and pending-recovery functions pass (4.731/0.841 s); all 86 probes in each configuration; eight process schedules per configuration; final ELF PIE/W^X/NX-stack/RELRO checks plus RWX negative control pass |
| Intel macOS 14.8.9 | Eight settlement schedules, 16 output-owner/freeze schedules, five locally produced descriptor schedules and five independently authored inbound descriptor schedules pass |
| Intel macOS 11.7.11 | The same 34 process schedules pass with the documented compiler/backdeployment-runtime variant |
| Application build | `build.sh` passes with the existing deployment diagnostic override; app/editor source is unchanged |
| Independent fixtures/setup | Private and projection Python fixture checks, mutation setup checks and test-target inventory pass |

Elapsed times include concurrent qualification and are not performance claims.
The final test-only extension adds the fresh-store copy assertions to the first
production witness. It passed separately on Mac/Linux in both configurations
(Mac debug/optimized 1.771/1.190 s; Linux 2.726/0.171 s);
production bytes, construction probes and previously exercised mutation targets
are unchanged. This reuses their completed qualification rather than repeating
unrelated suites or native process campaigns.
Its logs are `/tmp/nv-p61-settlement-copy-{debug,release}.log` and
`/tmp/nv-p61-settlement-copy-linux-{debug,release}.log`.
The 238 package/source/test/fixture SHA-256 entries match between the Mac and
Ubuntu. Earlier P6.1 fixture, source-variant, race, work-bound and mutation results
remain applicable within [their recorded scopes](06-completion-ledger.md). They
were not replaced by these shorter focused runs.

Both Intel hosts ran the same probe SHA-256:
`a6916eb34af35c7784305532fba55fb3fa55bb2d2a7837490a581f2980706f6e`.
It reuses the pinned Intel SQLCipher archive, requests
`x86_64-apple-macosx11.5`, and uses
`-Xswiftc -Xfrontend -Xswiftc -disable-concrete-type-metadata-mangled-name-accessors`.
Orbb additionally uses the isolated concurrency runtime at
`/tmp/nv-p61-encoding-runtime.QlrUXm`. As previously recorded, Xcode 27's emitted
minimum-OS metadata and default macOS 11 distribution packaging remain separate
qualification issues. These results qualify the actual tested executable variant.

The Intel output/producer/transport scripts ran unchanged through the temporary
SSH wrapper `/tmp/nv-p61-remote-probe.py`. It forwards normal commands, selection
files and generated test inputs to each isolated `/tmp` directory. Independent
Python/Node observations execute locally; neither host needs Node installed.
The wrapper coalesces SSH connections only. No production or test assertion was
relaxed for remote execution.

## Commands

```sh
make -C tests run-swift-storage \
  "SWIFT_STORAGE_TEST_FLAGS=-c debug --no-parallel --filter 'pendingSettlement|projectionSettlement|privateRecord|pendingImport|pendingFailure|pendingChanged|preservedRepair|privateCopyPreparation|privateBackupSourceFence'"
# Repeat release; Linux uses --jobs 1 and the documented hardened linker setup.
python3 tools/check-private-record-fixtures.py
python3 tools/check-projection-observation-fixtures.py
python3 tools/test-storage-private-types.py --modules NVStorage/.build/debug/Modules
python3 tools/test-storage-runtime-mutations.py --configuration debug \
  --only p61-settlement-decision --only p61-settlement-scope --only p61-settlement-latest
# Repeat probes/mutations optimized. Build the standalone product explicitly first:
python3 tools/test-storage-private-process.py --binary NVStorage/.build/debug/NVStorageProbe --only settlement
```

Use the existing process runner's `--ssh-target`, `--ssh-key`, and `--remote-env`
options for remote settlement cases. The other three unchanged process runners
are `test-projection-output-process.py`, `test-projection-producer-process.py`,
and `test-projection-transport-process.py`, each with `--binary`.

Artifacts remain under `/tmp/nv-p61-settlement-*` (build/test/type/process logs and
matching source manifests). Specific process artifacts:

- Local debug/release: `nv-private-process-zbir7z23`, `nv-private-process-nst9lu83`
  under the host temporary directory.
- Linux debug/release: `/tmp/nv-private-process-hda5wv5x`,
  `/tmp/nv-private-process-8rdjhe6z`.
- Mini settlement/output/producer/transport: `/tmp/nv-private-process-2rgjeh37`,
  `/tmp/nv-projection-output-13g4uees`, `/tmp/nv-projection-producer-ug24xgcc`,
  `/tmp/nv-projection-transport-qbakcwsp`.
- Orbb: `/tmp/nv-private-process-h1gz9pp3`, `/tmp/nv-projection-output-w5vj5cuk`,
  `/tmp/nv-projection-producer-mvppkpl_`, `/tmp/nv-projection-transport-qpwjw817`.
- Mutation manifests: host-temporary `nv-runtime-mutations-q9k42mk2/results.json`
  (debug) and `nv-runtime-mutations-8osw_iq2/results.json` (optimized).

## Model correspondence and remaining scope

The record calculation implements the existing `ProjectionTransitionSafety`
A→B→C ownership rule. Consumed-input atomicity and latest/frozen preservation
correspond to `PendingReferenceSafety`. Their existing safety conditions and
transitions are unchanged; completed finite checks are reused. These executable
tests add concrete codec/SQL/process evidence, not a refinement proof of rooted
file replacement. No TLA+ assertion was weakened or removed.

P6.2 must still establish exact mutable-file API capability. P6.4 must atomically
consume fresh root/file/relationship evidence and publish projection settlement,
pending-link transfer and eligible byte release. P6.5 connects actual external
decisions and provisional claims. None of these future effects is certified by
decoding a passive record or by the successful consumed-input writer here.
