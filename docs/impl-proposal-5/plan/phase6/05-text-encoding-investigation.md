# P6.1 — Exact text-output encoding investigation

Status: **experiment; encoding-ID-only reconstruction rejected**. The
[exact-output implementation](09-exact-output-contract.md) now retains actual
non-UTF-8 bytes and preserves the canonical body's exact UTF-8 bytes. This experiment
tests what must hold before extending it to the existing application's requested
encoding and UTF-8 promotion behavior. It changes no production codec or policy.

## Contract and hypothesis

`NoteObject.m`'s `NVCreatePlainTextDataPromotingToUTF8` asks **NSString** to encode
without lossy conversion, promoting to UTF-8 if that fails. Apple's
[API contract](https://developer.apple.com/documentation/foundation/nsstring/data%28using%3Aallowlossyconversion%3A%29)
describes an external representation, including a BOM where needed, and failure
when the requested lossless conversion cannot be made. It does not specify a
cross-platform canonical byte format for every encoding/Unicode spelling.
Preserving displayed Unicode and preserving exact scalar or file bytes are
distinct requirements. The projection descriptor hashes the latter.

The hypothesis was: retained canonical body plus an encoding identifier suffices
to regenerate identical bytes on each supported host. Test the actual legacy API
as well as Swift's `String.data(using:allowLossyConversion:)`; substituting the
Swift overlay without checking it would be a porting error. No Apple contract
violation is claimed from these results.

## Reproducible experiment

`tests/ProjectionTextEncodingProbe.swift` records both API outputs, encoding IDs,
exact UTF-8 input and Swift-decoded output. Its **98 cases per host** cover 14
encodings × empty text, ASCII/CRLF, NFC é, NFD e + acute, Japanese, emoji and an
embedded NUL. `tools/check-projection-encoding-observations.py` requires the
complete distinct matrix, checks inputs and UTF-8 independently, and checks
precomposed Mac Roman é against Python's separate mapping. Selected comparisons
fail explicitly for either API or platform disagreement; there is no automatic
platform exemption.

```sh
swift tests/ProjectionTextEncodingProbe.swift > /tmp/nv-encoding-host.json
python3 tools/check-projection-encoding-observations.py /tmp/nv-encoding-host.json
# Compare the actual legacy API, independently of the Swift overlay hypothesis:
python3 tools/check-projection-encoding-observations.py /tmp/nv-encoding-host.json --api nsstring --compare /tmp/nv-encoding-other-host.json
```

The default `both` check intentionally fails on the tested modern macOS/Linux
API differences. Selecting `nsstring` tests the narrower production-legacy
hypothesis; it still fails the Linux/macOS cross-platform comparison below.
These are rejected experimental claims, not waived qualification checks.

## Observed results — 2026-10-15

| Comparison | Exact result |
| --- | --- |
| NSString, macOS 26.6.2 arm64 vs macOS 14.8.9 Intel | All 98 cases match |
| NSString, macOS 26.6.2 arm64 vs macOS 11.7.11 Intel | All 98 cases match |
| NSString, Linux arm64 Swift 6.4 vs the Macs | 96 match; NFD e + acute is unrepresentable in ISO Latin-2 and Mac Roman on this Linux build, while macOS produces `e9` and `8e` respectively |
| Swift vs NSString, macOS 26.6.2 | Five NonLossyASCII cases differ, including failure versus an escaped representation and literal versus escaped NUL |
| Swift vs NSString, Linux Swift 6.4 | Those five plus decomposed ISO Latin-1 and precomposed Mac Roman differ |
| Swift vs NSString, macOS 14.8.9 | All 98 match |
| Independent Mac Roman é | Expected `8e`; NSString returns it on all tested hosts. The tested Linux Swift overlay returns `bc`, which its own decoder round-trips; that round trip alone is an insufficient oracle |
| UTF-8, both paths/all tested hosts | Exact input bytes preserved, including CRLF, NFD and NUL |

The first exploratory script used only Swift's API. The follow-up's actual
NSString call removed the precomposed Mac Roman discrepancy and decomposed
Latin-1 difference from the legacy-path portability claim. The two remaining
NSString failures are retained as failures. Successful lossless conversion may
still compose Unicode; it cannot be used to prove exact canonical-body equality.

The Mini's installed Swift/SDK pair could not compile Foundation because of a
duplicate `SwiftBridging` module. The same probe was cross-built with the local
Swift 6.4 compiler, strict concurrency and warnings-as-errors, targeting
`x86_64-apple-macosx11.5`, and executed on both Intel hosts. Orbb also required
the existing supported back-deployed concurrency library supplied in a new
isolated `/tmp/nv-p61-encoding-runtime.QlrUXm` directory. No system library,
compiler check or deployment target was changed. This qualifies the tested
Foundation calls, not the full Intel NVStorage Runtime or distribution package.

Artifacts: `/tmp/nv-p61-encoding-followup-{macos,linux,intel,orbb}.json` and
`/tmp/nv-p61-encoding-nsstring-comparison.log`. Probe SHA-256:
`d3873aebdb090389e46aa2f0d4a4fb0fffa1ccadbaf9195652527886ffcf7f26`.

## Consequences for the implementation

Keep exact captured output and its resolved encoding together. General output
must either have a qualified deterministic reconstruction or retain its exact
bytes through the existing durable private-input mechanism. An encoder's own
decode/encode round trip is insufficient validation. Reopening/repair must detect
a digest mismatch rather than regenerate different bytes and call them the old
accepted output.

The implementation retains non-UTF-8 output in bounded private SQLite records,
preserving the requested-encoding/UTF-8-promotion policy and existing note limits.
Its [qualification](09-exact-output-validation.md) tests exact recovered bytes,
rather than waiving the failed same-encoding-ID hypothesis. Canonical note
contents and accepted-file encoding remain separate from captured output.
