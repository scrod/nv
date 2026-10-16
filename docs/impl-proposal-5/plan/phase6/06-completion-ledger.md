# P6.1 completion ledger

P6.1 is **complete for its record/history-consumer scope**. This checklist maps its original exit requirements
to production consumers and independent evidence. A standalone codec or passive
record is qualified only for its stated role.

| Requirement | Implemented evidence | Boundary / subsequent work |
| --- | --- | --- |
| Exact leaf, reserved names, Unicode aliases, real filename/collision policy | [Descriptor](02-projection-descriptor-validation.md), [captured naming](04-filename-preparation-validation.md), public intent/reopen witness | Physical occupancy/volume checks are P6.2/P6.3, not naming evidence |
| Descriptor fields, profile presence and hash separation | [Descriptor contract](02-projection-descriptor-contract.md); [portable placement](08-portable-projection-contract.md) adds contextual decoding, exact dependency/source validation and metadata-only acceptance; [complete queries](10-complete-binding-query-contract.md) select exact accepted descriptions; [qualified local producer](11-projection-producer-validation.md) adds reserved addresses and exact-byte retry on Mac/Linux; [retention coverage](12-projection-retention-validation.md) bounds sequential-description startup/acceptance work and preserves concurrent tips; [final Intel qualification](14-settlement-record-validation.md) covers production output/producer/inbound/recovery paths | Descriptor receipt alone cannot establish installation |
| Stamp framing and complete source variants | [Stamp ledger](01-projection-record-validation.md); bounded parse, complete oversize omission, strict dependencies; [standalone source qualification](07-inbound-history-validation.md) covers exact accepted occurrences, note ancestry, foreign/invalid/waiting/blocked claims and changed-context consumers; [qualified complete queries](10-complete-binding-query-validation.md) share these checks beyond 4 KiB | Physical byte, copied-file, root and unique-applicability gates remain P6.2/P6.3 |
| Binding to accepted history | [Private preparation](03-history-observation-validation.md) checks actual ordinary/equal/merge/automatic occurrences and checked Current; [inbound history](07-inbound-history-validation.md) independently reconstructs exact selected ancestry; [portable acceptance](08-portable-projection-contract.md) retains metadata independently of note actions; [qualified complete consumer evidence](10-complete-binding-query-validation.md) fences source contents and whole-output reads | Physical consumers retain their distinct authority in P6.2/P6.3 |
| Raw metadata and accepted/intended source obligations | [Private observation codecs and writer](03-history-observation-contract.md); [qualified settlement mapping](14-settlement-record-validation.md) retains full decisions and distinguishes consumed inputs from completed projections | Physical receipt issuance and atomic projection settlement effects require P6.2/P6.4 |
| Exact encoded output and resolved encoding | [Requested encoding/captured output](09-exact-output-contract.md) preserves the legacy fallback policy, exact non-UTF-8 bytes, canonical note spelling and private atomicity; [qualification](09-exact-output-validation.md) includes codec, process and actual Mac-to-Linux recovery; [whole-output reader](10-complete-binding-query-contract.md) reconstructs owned UTF-8 from history; [frozen ownership](13-frozen-output-contract.md) preserves unfinished outputs and releases superseded unowned chunks in the intent transaction; [qualified settlement transfer](14-settlement-record-validation.md) calculates B accepted while retaining newer C | Physical publication and release retain the P6.4 gates |
| Compiler-enforced boundaries | Ordinary and same-module probes plus wrong-context consumers for stamp, leaf, descriptor, prepared intent, private capture, complete queries and local producer; description receipts are distinct from saved-action receipts; [settlement qualification](14-settlement-record-validation.md) brings private probes to 86 on Mac/Linux debug/optimized | Fresh physical evidence types and their consumers remain P6.2/P6.4 |
| Portable byte/behavior qualification | macOS arm64 and Linux arm64 debug/optimized, fixtures, affected mutations; native encoding probes on both Intel OS targets; [34 process schedules per Intel host](14-settlement-record-validation.md) for the finished record set | The macOS 11 compiler/runtime variant is qualified separately from default distribution metadata; physical power loss remains unqualified |

After those record/consumer gates, P6.2 implements actual rooted mutable-file
read/create/replace/rename/remove/finalize. P6.3 owns coherent catalogs and the
decision classifier. P6.4 owns receipt-driven transition/settlement integration.
Their safety conditions already constrain P6.1's records, but they must not be
represented as completed merely by seeding passive observations in a test.

The next dependency-ordered work is P6.2's rooted mutable-file adapter and API
capability qualification. A discovered API capability/policy conflict is reported
before weakening a contract. Existing model outcomes remain reusable only while
their transitions and assumptions remain unchanged.
