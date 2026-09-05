#!/usr/bin/env python3
"""Check ordinary-client type boundaries against an already built NVStorageCore.

Example: python3 tools/test-swift-storage-types.py --modules /path/to/debug/Modules
No @testable import, test-only declarations, app launch or provider access.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile


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
""", None),
        ("action is not operation", """
func take(_ id: OperationID) {}
func wrong(_ id: ActionID) { take(id) }
""", "cannot convert value of type 'ActionID' to expected argument type 'OperationID'"),
        ("segment is not operation", """
func take(_ id: OperationID) {}
func wrong(_ id: SegmentID) { take(id) }
""", "cannot convert value of type 'SegmentID' to expected argument type 'OperationID'"),
        ("knowledge is not supersession", """
func take(_ predecessors: NotePredecessorSet) {}
func wrong(_ parents: CausalParentSet) { take(parents) }
""", "cannot convert value of type 'CausalParentSet' to expected argument type 'NotePredecessorSet'"),
        ("identity is immutable", """
func wrong(_ original: IdentifiedOperation, _ id: OperationID) {
    var operation = original
    operation.id = id
}
""", "cannot assign to property: 'id' is a 'let' constant"),
        ("no claimed-ID constructor", """
func wrong(_ id: OperationID, _ nonce: OperationNonce, _ effect: OperationEffectV1,
           _ parents: CausalParentSet, _ predecessors: NotePredecessorSet) throws {
    let _ = try IdentifiedOperation(id: id, nonce: nonce, effect: effect,
        causalParents: parents, notePredecessors: predecessors)
}
""", "extra argument 'id' in call"),
    ]
    with tempfile.TemporaryDirectory(prefix="nv-storage-typecheck-") as cache:
        command = [args.swiftc, "-swift-version", "6", "-typecheck", "-I", str(args.modules),
                   "-module-cache-path", cache, "-"]
        for name, source, expected_error in cases:
            run = subprocess.run(command, input="import NVStorageCore\n" + source,
                                 text=True, capture_output=True, timeout=60)
            if expected_error is None:
                passed = run.returncode == 0
            else:
                passed = run.returncode != 0 and expected_error in run.stderr
            print(f"{'PASS' if passed else 'FAIL'}: {name}")
            if not passed:
                print(run.stdout + run.stderr)
                return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
