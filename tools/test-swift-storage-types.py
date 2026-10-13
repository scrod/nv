#!/usr/bin/env python3
"""Check ordinary and sibling-client boundaries against the actual NVStorageCore.

Example: python3 tools/test-swift-storage-types.py --modules /path/to/debug/Modules
Clients exercise production declarations through their normal access controls.
"""
import argparse
from contextlib import contextmanager
import os
from pathlib import Path
import re
import tempfile
from qualification_reuse import compiler_cache_path
from compiler_probe_batches import batch_size, run_probes


@contextmanager
def temporary_artifacts(prefix):
    if os.environ.get("NV_STORAGE_KEEP_ARTIFACTS") == "1":
        directory = tempfile.mkdtemp(prefix=prefix)
        print("Artifacts:", directory, flush=True)
        yield directory
    else:
        with tempfile.TemporaryDirectory(prefix=prefix) as directory:
            yield directory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--modules", required=True, type=Path)
    parser.add_argument("--swiftc", default="swiftc")
    parser.add_argument("--batch-size", type=batch_size, default=8,
                        help="Maximum compatible negative clients per compile; 1 preserves isolated checking.")
    args = parser.parse_args()
    cases = [
        ("ordinary client", """
func client(_ op: IdentifiedOperation, _ record: OperationRecordV1,
            _ table: DependencyLocatorTable, _ earlier: [IdentifiedOperation]) throws {
    let id: OperationID = op.id
    let _: CausalParentSet = try CausalParentSet([id])
    let _: NotePredecessorSet = try NotePredecessorSet([id])
    let bytes = try record.encodedV1(dependencies: table, earlierOperations: earlier)
    let _ = try OperationRecordV1.decodeV1(bytes, dependencies: table, earlierOperations: earlier)
}
func actionClient(_ payload: ChangesPayloadV1) throws {
    let _: ChangesPayloadV1 = try ChangesPayloadV1.decodeV1(payload.encodedV1())
    let _: [ActionV1] = payload.actions.map { $0.action }
}
func currentClient(_ cell: CurrentNoteCellV1, _ provenance: CurrentNoteProvenanceV1) throws -> CurrentNoteCellV1 {
    try CurrentNoteCellV1(birth: cell.birth, value: cell.value, represented: cell.represented,
        heads: cell.heads, provenance: provenance, scopeFrontier: cell.scopeFrontier, identity: cell.identity)
}
func derivedClient(_ bytes: [UInt8], _ table: DependencyLocatorTable, _ history: [IdentifiedOperation],
                   _ collection: CollectionID, _ birth: NoteBirth, _ enclosing: SegmentLocator,
                   _ resolve: (SegmentLocator) async throws -> ChangesPayloadV1?) async throws {
    let reference = try DerivedStateReferenceV1.decodeV1(bytes, dependencies: table, earlierOperations: [])
    let _: ReconstructedDerivedStateV1 = try await reference.reconstruct(collection: collection, birth: birth,
        history: history, earlierOperations: [], at: enclosing, resolve: resolve)
}
func bootstrapClient(_ descriptor: BootstrapDescriptorV1, _ collection: CollectionID,
                     _ protection: ObjectProtectionV1, _ locator: SegmentLocator,
                     _ read: (SegmentLocator) throws -> [UInt8]?) throws {
    let checked = try InitialBootstrapValidationV1.validate(descriptor: descriptor,
        expectedCollection: collection, protection: protection, snapshot: locator, read: read)
    let _: InitialImportScopeFrontierV1? = checked.scopeFrontiers[.collection]
    if let bytes = try read(locator) {
        let _: OpenedObjectV1 = try ObjectEnvelopeV1.open(bytes, collection: collection,
            protection: protection, expectedLocator: locator)
    }
}
func snapshotClient(_ locator: SegmentLocator, _ collection: CollectionID, _ protection: ObjectProtectionV1,
                    _ read: @escaping @Sendable (SegmentLocator) async throws -> [UInt8]?) async throws {
    let preview = try await GeneralSnapshotPreviewV1.read(snapshot: locator, collection: collection, protection: protection, read: read)
    try preview.checkProtection(collection: collection, protection: protection)
    let _: [GeneralSnapshotRecordV1] = preview.records
}
""", None),
        ("origin is not action", """
func take(_ id: ActionID) {}
func wrong(_ id: ActionOriginID) { take(id) } // expected-error
""", "cannot convert value of type 'ActionOriginID' to expected argument type 'ActionID'"),
        ("action index is not operation index", """
func take(_ index: OperationIndex) {}
func wrong(_ index: ActionIndex) { take(index) } // expected-error
""", "cannot convert value of type 'ActionIndex' to expected argument type 'OperationIndex'"),
        ("action is not operation", """
func take(_ id: OperationID) {}
func wrong(_ id: ActionID) { take(id) } // expected-error
""", "cannot convert value of type 'ActionID' to expected argument type 'OperationID'"),
        ("segment is not operation", """
func take(_ id: OperationID) {}
func wrong(_ id: SegmentID) { take(id) } // expected-error
""", "cannot convert value of type 'SegmentID' to expected argument type 'OperationID'"),
        ("knowledge is not supersession", """
func take(_ predecessors: NotePredecessorSet) {}
func wrong(_ parents: CausalParentSet) { take(parents) } // expected-error
""", "cannot convert value of type 'CausalParentSet' to expected argument type 'NotePredecessorSet'"),
        ("identity is immutable", """
func wrong(_ original: IdentifiedOperation, _ id: OperationID) {
    var operation = original
    operation.id = id // expected-error
}
""", "cannot assign to property: 'id' is a 'let' constant"),
        ("no claimed-ID constructor", """
func wrong(_ id: OperationID, _ nonce: OperationNonce, _ effect: OperationEffectV1,
           _ parents: CausalParentSet, _ predecessors: NotePredecessorSet) throws {
    let _ = try IdentifiedOperation(id: id, nonce: nonce, effect: effect, // expected-error
        causalParents: parents, notePredecessors: predecessors)
}
""", "extra argument 'id' in call"),
        ("raw set is not checked frontier", """
func take(_ frontier: InitialImportScopeFrontierV1) {}
func wrong(_ ids: Set<ActionID>) { take(ids) } // expected-error
""", "cannot convert value of type 'Set<ActionID>' to expected argument type 'InitialImportScopeFrontierV1'"),
        ("checked history cannot be decoded", """
func take<T: Decodable>(_ type: T.Type) {}
func wrong() { take(InitialBootstrapValidationV1.self) } // expected-error
""", "requires that 'InitialBootstrapValidationV1' conform to 'Decodable'"),
    ]
    issuers = [
        ("current provenance has one variant", """
func wrong(_ derived: DerivedStateReferenceV1, _ automatic: AutomaticSourceReferenceV1) {
    let _: CurrentNoteProvenanceV1 = .derived(derived, automatic) // expected-error
}
""", "extra argument in call"),
        ("current provenance is immutable", """
func wrong(_ source: CurrentNoteCellV1) {
    var cell = source
    cell.provenance = .revision // expected-error
}
""", "cannot assign to property: 'provenance' is a 'let' constant"),
        ("snapshot preview issuer", """
func wrong(_ p: GeneralSnapshotPreviewV1, _ bytes: [UInt8]) {
    let _ = GeneralSnapshotPreviewV1(collection: p.collection, snapshot: p.snapshot, root: p.root, records: p.records, pages: p.pages, rootBytes: bytes) // expected-error
}
""", "'GeneralSnapshotPreviewV1' initializer is inaccessible due to 'private' protection level"),
        ("snapshot preview decoding boundary", """
func take<T: Decodable>(_ type: T.Type) {}
func wrong() { take(GeneralSnapshotPreviewV1.self) } // expected-error
""", "requires that 'GeneralSnapshotPreviewV1' conform to 'Decodable'"),
        ("derived reconstruction issuer", """
func wrong(_ r: DerivedStateReferenceV1, _ c: CollectionID, _ b: NoteBirth,
           _ reduction: NoteReductionV1, _ v: ReducedNoteValueV1) {
    let _ = ReconstructedDerivedStateV1(reference: r, collection: c, birth: b, reduction: reduction, value: v) // expected-error
}
""", "'ReconstructedDerivedStateV1' initializer is inaccessible due to 'fileprivate' protection level"),
        ("derived claim requires reconstruction", """
func take(_ value: ReconstructedDerivedStateV1) {}
func wrong(_ value: DerivedStateReferenceV1) { take(value) } // expected-error
""", "cannot convert value of type 'DerivedStateReferenceV1' to expected argument type 'ReconstructedDerivedStateV1'"),
        ("merge descriptor issuer", """
func wrong(_ c: CollectionID, _ b: NoteBirth, _ ids: [OperationID], _ base: OperationID, _ v: PlaintextNoteValue) throws {
    let _ = try DerivedMergeV1(collection: c, birth: b, inputs: ids, base: base, value: v) // expected-error
}
""", "'DerivedMergeV1' initializer is inaccessible due to 'fileprivate' protection level"),
        ("represented value issuer", """
func wrong(_ v: PlaintextNoteValue, _ ids: [OperationID]) {
    let _ = ReducedNoteValueV1(value: v, represented: ids) // expected-error
}
""", "'ReducedNoteValueV1' initializer is inaccessible due to 'fileprivate' protection level"),
        ("merge identity is not operation", """
func take(_ id: OperationID) {}
func wrong(_ id: MergeIDV1) { take(id) } // expected-error
""", "cannot convert value of type 'MergeIDV1' to expected argument type 'OperationID'"),
        ("no fixed nonce sealer", """
func wrong(_ c: CollectionID, _ w: WriterEpoch, _ p: ObjectProtectionV1) throws {
    let _ = try ObjectEnvelopeV1.seal(payload: [], kind: .changes, collection: c, writer: w, sequence: 0, protection: p, testNonce: nil) // expected-error
}
""", "extra argument 'testNonce' in call"),
        ("fixed nonce descriptor helper is private", """
import Crypto
func wrong(_ c: CollectionID, _ id: CollectionKeyID, _ g: SegmentLocator, _ key: SymmetricKey, _ nonce: AES.GCM.Nonce) throws {
    let _ = try BootstrapDescriptorV1.wrap(collection: c, keyID: id, genesis: g, collectionKey: key, wrappingKey: key, salt: [], nonce: nonce) // expected-error
}
""", "extra arguments at positions #5, #6, #7 in call"),
        ("envelope issuer only", """
func wrong(_ kind: ProviderObjectKind, _ locator: SegmentLocator, _ payload: [UInt8]) {
    let _ = OpenedObjectV1(kind: kind, locator: locator, payload: payload) // expected-error
}
""", "'OpenedObjectV1' initializer is inaccessible due to 'fileprivate' protection level"),
        ("bootstrap issuer only", """
func wrong(_ c: InitialBootstrapValidationV1) {
    let _ = InitialBootstrapValidationV1(collection: c.collection, descriptor: c.descriptor, // expected-error
        snapshot: c.snapshot, importID: c.importID, completion: c.completion, rows: c.rows,
        actions: c.actions, scopeFrontiers: c.scopeFrontiers, requiredObjects: c.requiredObjects)
}
""", "'InitialBootstrapValidationV1' initializer is inaccessible due to 'private' protection level"),
        ("frontier issuer only", """
func wrong(_ f: InitialImportScopeFrontierV1) {
    let _ = InitialImportScopeFrontierV1(collection: f.collection, snapshot: f.snapshot, // expected-error
        completion: f.completion, scope: f.scope, actionIDs: f.actionIDs)
}
""", "'InitialImportScopeFrontierV1' initializer is inaccessible due to 'fileprivate' protection level"),
    ]
    with temporary_artifacts(prefix="nv-storage-typecheck-") as cache:
        command = [args.swiftc, "-swift-version", "6", "-strict-concurrency=complete", "-strict-memory-safety",
                   "-warnings-as-errors", "-typecheck", "-I", str(args.modules),
                   "-module-cache-path", compiler_cache_path(args.swiftc, args.modules, cache)]
        root = Path(__file__).resolve().parents[1]
        for module_map in [args.modules.parent / "CArgon2.build/module.modulemap",
                           args.modules.parent / "CZstd.build/module.modulemap"]:
            if not module_map.is_file():
                raise RuntimeError(f"Build the package first: missing {module_map}")
            command.extend(["-Xcc", f"-fmodule-map-file={module_map}"])
        core = sorted((root / "NVStorage/Sources/NVStorageCore").glob("*.swift"))
        # Sibling clients keep their own source files beside the actual Core
        # sources, challenging accidental internal constructors.
        for same_module, selected in [(False, cases + issuers), (True, [cases[0]] + issuers)]:
            clients = [(name, ("" if same_module else "import NVStorageCore\n") + source, expected)
                       for name, source, expected in selected]
            cmd = command + (["-whole-module-optimization", "-package-name", "nvstorage", "-module-name", "NVStorageCore"] + [str(p) for p in core] if same_module else [])
            completed = run_probes(cmd, clients, Path(cache)/('same' if same_module else 'ordinary'),
                                  label='same module:' if same_module else '', timeout=60, maximum=args.batch_size)
            assert completed == len(selected)
        # Reject setup failures and diagnostics from an unintended source line.
        path = Path(cache) / "Client.swift"
        example = "take(bad) // expected-error\n"
        assert not matches_contract(1, "compiler unavailable", path, example, "cannot convert")
        assert not matches_contract(1, f"{path}:2:1: error: cannot convert", path, example, "cannot convert")
        assert not matches_contract(0, f"{path}:1:1: error: cannot convert", path, example, "cannot convert")
        assert matches_contract(1, f"{path}:1:1: error: cannot convert", path, example, "cannot convert")
        print("PASS: diagnostic classifier self-checks")
    return 0


def matches_contract(returncode, diagnostic, path, source, expected_error):
    if expected_error is None:
        return returncode == 0
    lines = [n for n, line in enumerate(source.splitlines(), 1) if "// expected-error" in line]
    if len(lines) != 1:
        raise ValueError("A negative client needs exactly one expected source location")
    pattern = rf"{re.escape(str(path))}:{lines[0]}:\d+: error: [^\n]*{re.escape(expected_error)}"
    return returncode != 0 and re.search(pattern, diagnostic) is not None


if __name__ == "__main__":
    raise SystemExit(main())
