#!/usr/bin/env python3
"""Check ordinary-client type boundaries against an already built NVStorageCore.

Example: python3 tools/test-swift-storage-types.py --modules /path/to/debug/Modules
No @testable import, test-only declarations, app launch or provider access.
"""
import argparse
from contextlib import contextmanager
import os
from pathlib import Path
import re
import subprocess
import tempfile


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
        command = [args.swiftc, "-swift-version", "6", "-typecheck", "-I", str(args.modules),
                   "-module-cache-path", cache]
        root = Path(__file__).resolve().parents[1]
        for module_map in [args.modules.parent / "CArgon2.build/module.modulemap",
                           args.modules.parent / "CZstd.build/module.modulemap"]:
            if not module_map.is_file():
                raise RuntimeError(f"Build the package first: missing {module_map}")
            command.extend(["-Xcc", f"-fmodule-map-file={module_map}"])
        core = sorted((root / "NVStorage/Sources/NVStorageCore").glob("*.swift"))
        # The same-module probes are compiled as a different source file against
        # the actual Core sources, catching accidental internal constructors.
        for same_module, selected in [(False, cases + issuers), (True, [cases[0]] + issuers)]:
            for name, source, expected_error in selected:
                path = Path(cache) / "Client.swift"
                text = ("" if same_module else "import NVStorageCore\n") + source
                path.write_text(text)
                # Typecheck all module sources once per probe, retaining each file's access boundaries.
                cmd = command + (["-whole-module-optimization", "-package-name", "nvstorage", "-module-name", "NVStorageCore"] + [str(p) for p in core] if same_module else [])
                run = subprocess.run(cmd + [str(path)], text=True, capture_output=True, timeout=60)
                passed = matches_contract(run.returncode, run.stderr, path, text, expected_error)
                print(f"{'PASS' if passed else 'FAIL'}: {'same module: ' if same_module else ''}{name}")
                if not passed:
                    print(run.stdout + run.stderr)
                    return 1
        # Reject setup failures and diagnostics from an unintended source line.
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
