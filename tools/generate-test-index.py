#!/usr/bin/env python3
"""Catalogue project-owned validation sources and their documentary references.

The catalogue is produced by lexical and AST inspection. The small data evaluator
expands literal scenario matrices while filesystem, compiler and test operations
remain descriptions for a human to run through their real entry points.
"""
from __future__ import annotations

import argparse
import ast
from collections import Counter, defaultdict
import hashlib
import itertools
import json
from pathlib import Path
import re
import shlex
import sys
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "docs/test-index"
RETIRED = "docs/tla/retired/"
UNKNOWN = object()
EXCLUDED = {".git", ".deps", "__pycache__", "node_modules", "Vendor"}
CASE_NAMES = {"cases", "selected_cases", "scenarios", "schedules", "mutations", "issuers", "actor_cases", "valid", "probes", "checks", "variants", "experiments", "tests", "commands", "independent_jobs"}
PLAN = "docs/impl-proposal-5/plan/"
# Family-level authorities complement exact names and aggregate-runner mentions.
GOVERNING = [
    (r"GrowthHistory|growthHistory", ["shared-history-fixture-pilot.md", "swift-storage-conformance-testing-strategy.md"]),
    (r"test-storage-test-targets", ["test-target-build-performance.md", "qualification-build-reuse.md", "swift-storage-conformance-testing-strategy.md"]),
    (r"compiler[_-]probe|types\.py", ["compiler-probe-batching.md"]),
    (r"qualification[-_]reuse|integration-build-manifest|link-integration", ["qualification-build-reuse.md"]),
    (r"Bootstrap|bootstrap|SavedAction|Ordinary|RuntimeSchedule|Commit|commit|Acceptance|DatabaseBoundary|process\.py", ["first-save-reopen-contract.md", "phase2-local-runtime-validation.md"]),
    (r"CurrentBasis|current-basis|ConnectionReuse|connection-reuse", ["current-basis-validation.md", "phase5/private-connection-reuse.md"]),
    (r"Action|Connected|Compensation|Merge|Restoration|NoteHistory|NativeCoverage|phase3|merge|restoration|derived-state|connected-record", ["phase3-schedule-observation-matrix.md", "phase3-validation.md", "phase3-connected-record-contract.md"]),
    (r"BootstrapReconstruction|SharedBootstrap|bootstrap-reconstruction|MixedRecovery", ["phase4-bootstrap-reconstruction-plan.md", "phase4-bootstrap-reconstruction-validation.md", "phase4-data-safety-contracts.md"]),
    (r"Snapshot|snapshot", ["general-snapshot-record-contract.md", "phase4-snapshot-acceptance-recovery-plan.md", "phase4-startup-recovery-plan.md"]),
    (r"ReceivedSnapshot|received-snapshot|ReceiveSnapshotAssembly", ["phase4-received-snapshot-plan.md", "phase4-received-snapshot-validation.md"]),
    (r"Retention|retention", ["phase-4-improvements/snapshot-retention-coverage.md", "phase-4-improvements/snapshot-retention-coverage-validation.md"]),
    (r"Private|private-|Pending|Backup|Repair|Copy|Selection|disposal", ["private-record-contract.md", "phase4-private-state-repair-copy-plan.md", "phase4-private-state-repair-copy-validation.md"]),
    (r"PrivateStateTests|pending(?:Import|Failure|Competing|Changed)|ProjectionStamp|ProjectionDescriptor|ProjectionObservation|ProjectionFilename|ProjectionTextEncoding|projection-(?:stamp|descriptor|observation|filename|encoding)|p61-|ProjectionTransition|ProjectionRecoveryBridge|ExternalFileLifecycle|ExternalAssociation|ExternalRecoveryBridge|PendingReference|SeparateFileDeletion|CurrentVisibleReconciliation|P6-C", ["phase6-plaintext-reconciliation-plan.md", "swift-storage-conformance-testing-strategy.md"]),
    (r"ProjectionStamp|projection-stamp|p61-stamp", ["phase6/01-projection-record-contract.md", "phase6/01-projection-record-validation.md"]),
    (r"ProjectionDescriptor|projection-descriptor|p61-descriptor", ["phase6/02-projection-descriptor-contract.md", "phase6/02-projection-descriptor-validation.md"]),
    (r"ProjectionObservation|projection-observation|p61-(?:intent|observation|repair)|projection-(?:before|after|enospc|eio)", ["phase6/03-history-observation-contract.md", "phase6/03-history-observation-validation.md"]),
    (r"ProjectionFilename|projectionFilename|projectionIntentRetainsSelectedFilename|projection-filename|p61-filename", ["phase6/04-filename-preparation-contract.md", "phase6/04-filename-preparation-validation.md"]),
    (r"ProjectionTextEncoding|projection-encoding", ["phase6/05-text-encoding-investigation.md"]),
    (r"ProjectionHistory|projectionHistory|standaloneDerived|p61-inbound", ["phase6/07-inbound-history-contract.md", "phase6/07-inbound-history-validation.md"]),
    (r"ProjectionTransport|ProjectionSourceValidation|projectionTransport|projection-transport|p61-transport", ["phase6/08-portable-projection-contract.md", "phase6/08-portable-projection-validation.md"]),
    (r"ProjectionTextOutput|projectionText|projectionEncoded|projection-output|p61-output", ["phase6/09-exact-output-contract.md", "phase6/09-exact-output-validation.md"]),
    (r"projectionCompleteBinding|projectionDescriptions|projectionOutput|test-projection-output-process|p61-binding", ["phase6/10-complete-binding-query-contract.md", "phase6/10-complete-binding-query-validation.md"]),
    (r"ProjectionProducer|projectionProducer|projection-producer|p61-producer|p61-coverage", ["phase6/11-projection-producer-contract.md", "phase6/11-projection-producer-validation.md", "phase6/12-projection-retention-validation.md"]),
    (r"projectionFrozen|projectionFreeze|projectionByteRelease|projection-output-process|p61-frozen", ["phase6/13-frozen-output-contract.md", "phase6/13-frozen-output-validation.md"]),
    (r"SettlementRecord|PendingSettlement|pendingSettlement|projectionSettlement|p61-settlement|private-record-fixtures|private-process", ["phase6/14-settlement-record-contract.md", "phase6/14-settlement-record-validation.md"]),
    (r"ProjectionFileRead|ProjectionFileCreation|ProjectionFiles(?:Read|Create|Replace|Relocate|Source|Cleanup|Presenter|SyncFault)|ProjectionNativeFixtures|ProjectionReplacement|ProjectionRelocation|ProjectionDeletion|ProjectionSource|ProjectionReferenceRace|projectionFileRead|projectionCreation|projectionRelocation|projectionInstallationChecks|projectionDeletion|projectionSource|projection-files-c|projection-(?:read|create)-process|projection-relocation-volumes|p62-(?:read|create|replace|relocate|recovery|source|delete|cleanup|output)", ["phase6/15-rooted-mutable-files-contract.md", "phase6/15-rooted-mutable-files-validation.md"]),
    (r"CurrentRow|CurrentStartup|CurrentMaintenance|current-row|current-maintenance|Maintenance|maintenance|Zstd|zstd|current-fixtures", ["private-current-row-codec.md", "phase4-current-row-locality-maintenance-plan.md", "phase4-current-row-locality-maintenance-validation.md", "zstd-codec-validation.md"]),
    (r"HistoryReader|HistoryTraversal|Traversal|RecoveryWork|traversal|CoalescedRecovery", ["phase-4-improvements/at-most-once-envelope-decoding.md", "phase-4-improvements/recovery-graph-reuse.md", "phase-4-improvements/validation.md"]),
    (r"Verification|verification", ["phase-4-improvements/durable-verification-recovery.md"]),
    (r"ScopedHistory|OptionalStartup|scoped-platform|OptionalReadyStartup", ["phase-4-improvements/startup-and-scoped-queries.md", "phase-4-improvements/startup-and-scoped-queries-validation.md"]),
    (r"Resumption|resumption|Rejection|rejection|ReceiveIsolation|ReceiveRejection|ReceiveResumption", ["validation-resumption-plan.md", "validation-resumption-results.md", "phase2-hardening-validation.md", "receive-model-validation.md"]),
    (r"Phase5Connected|phase5-connected|phase5(?:Delayed|Collection|Driver|Publication)|p57-", ["phase5/07-connected-qualification.md", "phase5/07-connected-qualification-validation.md"]),
    (r"Repository|repository|CollectionStartup|CollectionBootstrap|CollectionWait|root-|immutable-|metadata-batch|discovery|directory-scan|apple-(?:peer|repair|stage|startup|transport)|coordinated-install|startup-process|startup-remote", ["phase5-provider-root-implementation-plan.md", "phase5-provider-root-testing-plan.md"]),
    (r"RepositoryRoot|root-(?:c|process|types|volumes)|RepositoryRootIO", ["phase5/01-root-ownership-and-execution.md", "phase5/01-root-ownership-validation.md"]),
    (r"RepositoryFiles|RepositoryListing|immutable-|RepositoryFilesIO", ["phase5/02-immutable-files-and-namespace.md", "phase5/02-immutable-files-validation.md"]),
    (r"RepositoryExchange|RepositoryPublication|repository-exchange|repository-cross-host", ["phase5/03-local-repository-exchange.md", "phase5/03-local-repository-exchange-validation.md"]),
    (r"RepositoryCoordination|RepositoryTransport|RepositoryDriver|RepositoryAvailability|RepositoryAccessor|apple-|coordinated-install", ["phase5/04-apple-coordination-and-discovery.md", "phase5/04-apple-coordination-and-discovery-validation.md"]),
    (r"CollectionStartup|CollectionBootstrap|CollectionWait|CollectionController|startup-(?:process|remote)|apple-startup|collection-startup", ["phase5/05-startup-and-root-reassociation.md", "phase5/05-startup-and-root-reassociation-validation.md"]),
    (r"RepositoryRepair|repositoryRepair|repairUnion|repair-union-|selectionResumption|activeRecoveryCopyPreservesSavedHistoryWithMissingRepository|private-repair-integrated|integrated-(?:private|repair|activated)|copy-unavailable-inventory|repair-(?:connected-settings|source-access-report|source-incomplete-candidate|source-cancelled-end|selection-barrier|preservation-busy|incomplete-prefix|newer-prefix|directory-binding|complement-locator|complement-report|occupied-request|late-collision|descriptor-kind|replacement-capability)", ["phase5/06-repair-replacement-and-copy.md", "phase5/06-repair-replacement-and-copy-validation.md"]),
    (r"RepositoryCopy|repositoryCopy|collectionCopySwitch|apple-repair|repository-(?:copy|repair)-process|switch-skip-accessor-settlement|copy-(?:direct-canonical-write|hidden-source-damage|late-prefix|unreserve-failed-history)", ["phase5/06-repair-replacement-and-copy.md", "phase5/06-repair-replacement-and-copy-validation.md"]),
    (r"RepositoryBatch|RepositoryDiscovery|RepositoryMetadata|metadata-batch|discovery-(?:work|variants)|directory-scan", ["phase5/bounded-discovery-batches-plan.md", "phase5/bounded-discovery-batches-validation.md", "phase5/directory-scan-performance.md", "phase5/discovery-work-analysis.md"]),
    (r"sqlcipher|SQLCipher", ["sqlcipher-validation.md", "swift64-platform-qualification.md"]),
    (r"types\.py|TypedBoundary|Phase3Boundary", ["swift-storage-library-proposal-v2.md", "typed-runtime-boundaries-validation.md"]),
]


class DefaultArguments(dict):
    """Source-declared CLI defaults used to describe an ordinary complete run."""


def project_files() -> list[Path]:
    result = []
    for base in ("NVStorage/Tests", "tests", "tools", "docs/tla"):
        for p in (ROOT / base).rglob("*"):
            if p.is_file() and not any(x in EXCLUDED or x.startswith(".build") for x in p.relative_to(ROOT).parts):
                if p.suffix in {".swift", ".c", ".m", ".h", ".py", ".sh", ".mjs", ".tla", ".cfg", ".json", ".base64", ".plist"} or p.name == "Makefile":
                    result.append(p)
    result.append(ROOT / "build.sh")
    return sorted(set(result))


def relative(p: Path) -> str:
    return p.relative_to(ROOT).as_posix()


def clean(value: Any, limit: int = 0) -> str:
    if value is UNKNOWN:
        return "<runtime input>"
    text = str(value).replace("\n", " ").replace("|", "\\|").replace("`", "'")
    text = re.sub(r"\s+", " ", text).strip()
    return text[:limit] + "…" if limit and len(text) > limit else text


def words(name: str) -> str:
    name = re.sub(r"^(test_|Test(?=[A-Z])|test(?=[A-Z]))", "", name)
    name = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", name)
    name = re.sub(r"([A-Z])([A-Z][a-z])", r"\1 \2", name)
    return " ".join(x if x.isupper() else x.lower() for x in name.replace("_", " ").replace("-", " ").split())


def phase(path: str, name: str = "") -> str:
    text = path + " " + name
    if RETIRED in path:
        return "retired proposal 4" if "impl-proposal-4/" in path else "retired exploration"
    if "docs/tla/" in path:
        return "formal / cross-phase"
    if re.search(r"ProjectionStamp|ProjectionDescriptor|ProjectionObservation|ProjectionFilename|ProjectionFileRead|ProjectionFileCreation|ProjectionFiles(?:Read|Create|Replace|Relocate|Source|Cleanup|Presenter|SyncFault)|ProjectionNativeFixtures|ProjectionReplacement|ProjectionRelocation|ProjectionDeletion|ProjectionSource|ProjectionReferenceRace|ProjectionTextEncoding|ProjectionHistory|projectionFileRead|projectionCreation|projectionRelocation|projectionInstallationChecks|projectionDeletion|projectionSource|projectionHistory|standaloneDerived|projection[- ]|p61-|p62-(?:read|create|replace|relocate|recovery|source|delete|cleanup|output)", text):
        return "6 (canonical records also qualify 1)"
    if "NVStorageCoreTests" in path:
        if re.search(r"Snapshot|PrivateRecord|Verification|CurrentCell", text):
            return "4 (canonical records also qualify 1)"
        if re.search(r"Action|Connected|Merge|Restoration|Derived", text):
            return "3 (canonical records also qualify 1)"
        return "1"
    if re.search(r"Phase5Connected|phase5-connected|phase5(?:Delayed|Collection|Driver)|p57-|Repository|CollectionStartup|CollectionWait|CollectionCopySwitch|collectionCopySwitch|repository|root-|immutable-|metadata-batch|apple-(?:peer|stage|startup|transport|repair)|coordinated-install|discovery|directory-scan|startup-process|startup-remote|repair-replacement-capability", text):
        return "5"
    if re.search(r"Snapshot|Reconstruction|MixedRecovery|Private|Backup|Repair|Selection|Maintenance|Verification|Traversal|CurrentRow|CurrentStartup|OptionalStartup|ScopedHistory|CurrentMaintenance|ReceivedSnapshot|snapshot|private-|repair|maintenance|locality|current-cell|general-snapshot|verification|recovery-artifact|disposal", text):
        return "4"
    if re.search(r"Merge|Restoration|Connected|Compensation|NativeCoverage|NoteHistory|Phase3|phase3|merge|restoration|derived-state|connected-record|history-process|review-process", text):
        return "3"
    if "NVStorageRuntimeTests" in path or "test-storage-" in path:
        return "2 / cross-phase"
    if re.search(r"fixture|zstd|swift-storage-types|envelope", text):
        return "1 / cross-phase"
    if re.search(r"ICloud|icloud|FSEvents|Undo|incarnation", text):
        return "API experiment / cross-phase"
    return "legacy / cross-phase"


class DataReader:
    """Expand finite source-level data and retain the originating line numbers."""

    def __init__(self, tree: ast.Module):
        self.functions: dict[str, ast.FunctionDef] = {}
        self.env: dict[str, Any] = {}
        self.rows: list[tuple[str, Any, int]] = []
        self.yields: list[tuple[Any, int]] = []
        self.emissions: list[tuple[str, Any, int]] = []
        self.steps = 0
        self.defaults = DefaultArguments()
        for call in ast.walk(tree):
            if isinstance(call, ast.Call) and isinstance(call.func, ast.Attribute) and call.func.attr == "add_argument":
                switches = [x.value for x in call.args if isinstance(x, ast.Constant) and isinstance(x.value, str)]
                if not switches: continue
                options = {x.arg: x.value for x in call.keywords}
                action = options.get("action")
                default = options.get("default")
                value = UNKNOWN
                if default is not None:
                    try: value = ast.literal_eval(default)
                    except (ValueError, TypeError): pass
                elif isinstance(action, ast.Constant) and action.value == "store_true": value = False
                elif isinstance(action, ast.Constant) and action.value == "store_false": value = True
                elif isinstance(action, ast.Constant) and action.value == "append": value = None
                self.defaults[switches[-1].lstrip("-").replace("-", "_")] = value
        self.statements(tree.body, self.env)

    def assign(self, target: ast.AST, value: Any, env: dict[str, Any], line: int):
        if isinstance(target, ast.Name):
            env[target.id] = value
            if target.id.lower() in CASE_NAMES or target.id in {"CASES", "MUTATIONS"}:
                self.rows.append((target.id, value, line))
        elif isinstance(target, (ast.Tuple, ast.List)) and isinstance(value, (list, tuple)) and len(value) == len(target.elts):
            for item, child in zip(target.elts, value):
                self.assign(item, child, env, line)

    def expression(self, node: ast.AST | None, env: dict[str, Any]) -> Any:
        if node is None:
            return None
        if isinstance(node, ast.Constant):
            return node.value
        if isinstance(node, ast.Name):
            return env.get(node.id, UNKNOWN)
        if isinstance(node, ast.Attribute):
            value = self.expression(node.value, env)
            if isinstance(value, DefaultArguments): return value.get(node.attr, UNKNOWN)
            return UNKNOWN
        if isinstance(node, (ast.List, ast.Tuple, ast.Set)):
            values = [self.expression(x, env) for x in node.elts]
            return tuple(values) if isinstance(node, ast.Tuple) else values
        if isinstance(node, ast.Dict):
            values = [(self.expression(k, env), self.expression(v, env)) for k, v in zip(node.keys, node.values)]
            return {k: v for k, v in values if k is not UNKNOWN and isinstance(k, (str, int, bool, tuple))}
        if isinstance(node, ast.JoinedStr):
            values = [self.expression(x.value, env) if isinstance(x, ast.FormattedValue) else self.expression(x, env) for x in node.values]
            return UNKNOWN if any(x is UNKNOWN for x in values) else "".join(map(str, values))
        if isinstance(node, ast.IfExp):
            test = self.expression(node.test, env)
            return UNKNOWN if test is UNKNOWN else self.expression(node.body if test else node.orelse, env)
        if isinstance(node, ast.BinOp):
            a, b = self.expression(node.left, env), self.expression(node.right, env)
            if a is UNKNOWN or b is UNKNOWN:
                return UNKNOWN
            try:
                if isinstance(node.op, ast.Add): return a + b
                if isinstance(node.op, ast.Mult) and isinstance(b, int) and abs(b) < 5000: return a * b
                if isinstance(node.op, ast.Mod): return a % b
                if isinstance(node.op, ast.BitOr): return a | b
            except (TypeError, ValueError):
                pass
            return UNKNOWN
        if isinstance(node, ast.UnaryOp):
            x = self.expression(node.operand, env)
            if x is UNKNOWN: return UNKNOWN
            if isinstance(node.op, ast.Not): return not x
            if isinstance(node.op, ast.USub): return -x
        if isinstance(node, ast.Compare):
            a = self.expression(node.left, env)
            for op, child in zip(node.ops, node.comparators):
                b = self.expression(child, env)
                if a is UNKNOWN or b is UNKNOWN: return UNKNOWN
                try:
                    if isinstance(op, ast.Eq): ok = a == b
                    elif isinstance(op, ast.NotEq): ok = a != b
                    elif isinstance(op, ast.In): ok = a in b
                    elif isinstance(op, ast.NotIn): ok = a not in b
                    elif isinstance(op, ast.Is): ok = a is b
                    elif isinstance(op, ast.IsNot): ok = a is not b
                    elif isinstance(op, ast.Lt): ok = a < b
                    elif isinstance(op, ast.LtE): ok = a <= b
                    elif isinstance(op, ast.Gt): ok = a > b
                    elif isinstance(op, ast.GtE): ok = a >= b
                    else: return UNKNOWN
                except TypeError:
                    return UNKNOWN
                if not ok: return False
                a = b
            return True
        if isinstance(node, ast.BoolOp):
            values = [self.expression(x, env) for x in node.values]
            for value in values[:-1]:
                if value is UNKNOWN: return UNKNOWN
                if isinstance(node.op, ast.And) and not value: return value
                if isinstance(node.op, ast.Or) and value: return value
            return values[-1]
        if isinstance(node, ast.Subscript):
            value, key = self.expression(node.value, env), self.expression(node.slice, env)
            try:
                return value[key] if value is not UNKNOWN and key is not UNKNOWN else UNKNOWN
            except (IndexError, KeyError, TypeError):
                return UNKNOWN
        if isinstance(node, ast.Slice):
            values = [self.expression(x, env) for x in (node.lower, node.upper, node.step)]
            return UNKNOWN if any(x is UNKNOWN for x in values) else slice(*values)
        if isinstance(node, (ast.ListComp, ast.SetComp, ast.GeneratorExp)):
            result = []
            def visit(index: int, scope: dict[str, Any]):
                if index == len(node.generators):
                    result.append(self.expression(node.elt, scope)); return
                g = node.generators[index]
                data = self.expression(g.iter, scope)
                if not isinstance(data, (list, tuple, range, dict, set)): return
                for value in data:
                    child = dict(scope)
                    self.assign(g.target, value, child, node.lineno)
                    if all(self.expression(x, child) is True for x in g.ifs): visit(index + 1, child)
            visit(0, dict(env))
            return result
        if isinstance(node, ast.Call):
            args = [self.expression(x, env) for x in node.args]
            kwargs = {x.arg: self.expression(x.value, env) for x in node.keywords if x.arg}
            name = node.func.id if isinstance(node.func, ast.Name) else ""
            called = node.func.attr if isinstance(node.func, ast.Attribute) else name
            if called == "run_probes" and len(args) > 1 and isinstance(args[1], (list, tuple)):
                # Trace the shared runner's per-client observations using only
                # the caller's finite case data and mode label.
                label = kwargs.get("label", "")
                for row in args[1]:
                    if isinstance(row, (list, tuple)) and row and isinstance(row[0], str):
                        self.emissions.append(("check-label", ["PASS:", label, row[0]], node.lineno))
                return len(args[1])
            if name in {"run", "check", "probe", "case", "compile_probe", "record", "report"} and args:
                self.emissions.append((name, args, node.lineno))
            if name == "print" and args and isinstance(args[0], str) and "PASS" in args[0]:
                self.emissions.append(("check-label", args, node.lineno))
            if name in {"str", "int", "bool", "len", "list", "tuple", "set", "sorted", "enumerate", "zip", "range", "dict", "product", "permutations"} and not any(x is UNKNOWN for x in args + list(kwargs.values())):
                try:
                    fn = {"str": str, "int": int, "bool": bool, "len": len, "list": list, "tuple": tuple, "set": list, "sorted": sorted, "enumerate": lambda *a: list(enumerate(*a)), "zip": lambda *a: list(zip(*a)), "range": range, "dict": dict, "product": lambda *a: list(itertools.product(*a)), "permutations": lambda *a: list(itertools.permutations(*a))}[name]
                    result = fn(*args, **kwargs)
                    return UNKNOWN if isinstance(result, (list, tuple, range)) and len(result) > 20000 else result
                except (TypeError, ValueError):
                    return UNKNOWN
            if name in self.functions and name not in {"main", "run", "check", "probe"}:
                fn = self.functions[name]
                scope = dict(env)
                parameters = fn.args.args
                defaults = [UNKNOWN] * (len(parameters) - len(fn.args.defaults)) + [self.expression(x, env) for x in fn.args.defaults]
                for i, parameter in enumerate(parameters):
                    scope[parameter.arg] = args[i] if i < len(args) else kwargs.get(parameter.arg, defaults[i])
                # Matrix factory helpers contain returns and pure literal data.
                if name in {"cases", "experiments"}:
                    before = len(self.yields)
                    self.statements(fn.body, scope)
                    return [value for value, _ in self.yields[before:]]
                if len(fn.body) < 15 and not any(isinstance(x, (ast.With, ast.While, ast.Try)) for x in ast.walk(fn)):
                    return self.statements(fn.body, scope)
            if isinstance(node.func, ast.Attribute):
                value = self.expression(node.func.value, env)
                attr = node.func.attr
                if attr == "parse_args": return self.defaults
                if attr in {"product", "permutations"} and isinstance(node.func.value, ast.Name) and node.func.value.id == "itertools" and all(x is not UNKNOWN for x in args):
                    return list(getattr(itertools, attr)(*args))
                if attr in {"append", "extend"} and isinstance(value, list) and args and args[0] is not UNKNOWN:
                    value.append(args[0]) if attr == "append" else value.extend(args[0])
                    variable = node.func.value.id if isinstance(node.func.value, ast.Name) else ""
                    if variable.lower() in CASE_NAMES: self.rows.append((variable, list(value), node.lineno))
                    return None
                if attr in {"items", "keys", "values"} and isinstance(value, dict): return list(getattr(value, attr)())
                if isinstance(value, str) and attr in {"lower", "upper", "replace", "startswith", "endswith", "split", "strip", "join"} and all(x is not UNKNOWN for x in args):
                    try: return getattr(value, attr)(*args)
                    except (TypeError, ValueError): return UNKNOWN
            return UNKNOWN
        return UNKNOWN

    def statements(self, nodes: list[ast.stmt], env: dict[str, Any]) -> Any:
        for node in nodes:
            self.steps += 1
            if self.steps > 200000: raise ValueError("Data expansion exceeded its finite inspection budget")
            if isinstance(node, ast.FunctionDef): self.functions[node.name] = node
            elif isinstance(node, (ast.Assign, ast.AnnAssign)):
                value = self.expression(node.value, env)
                targets = node.targets if isinstance(node, ast.Assign) else [node.target]
                for target in targets: self.assign(target, value, env, node.lineno)
            elif isinstance(node, ast.AugAssign) and isinstance(node.target, ast.Name):
                value = self.expression(node.value, env)
                old = env.get(node.target.id, UNKNOWN)
                if isinstance(node.op, ast.Add) and old is not UNKNOWN and value is not UNKNOWN:
                    try: self.assign(node.target, old + value, env, node.lineno)
                    except TypeError: pass
            elif isinstance(node, ast.For):
                data = self.expression(node.iter, env)
                if isinstance(data, (list, tuple, range, dict, set)):
                    for value in list(data):
                        self.assign(node.target, value, env, node.lineno)
                        self.statements(node.body, env)
            elif isinstance(node, ast.If):
                test = self.expression(node.test, env)
                if test is UNKNOWN:
                    self.statements(node.body, dict(env)); self.statements(node.orelse, dict(env))
                else: self.statements(node.body if test else node.orelse, env)
            elif isinstance(node, (ast.With, ast.AsyncWith)):
                self.statements(node.body, env)
            elif isinstance(node, ast.Try):
                self.statements(node.body, env)
                for handler in node.handlers: self.statements(handler.body, dict(env))
                self.statements(node.orelse, env); self.statements(node.finalbody, env)
            elif isinstance(node, ast.Return): return self.expression(node.value, env)
            elif isinstance(node, ast.Expr):
                if isinstance(node.value, ast.Yield): self.yields.append((self.expression(node.value.value, env), node.lineno))
                elif isinstance(node.value, ast.YieldFrom):
                    values = self.expression(node.value.value, env)
                    if isinstance(values, (tuple, list)): self.yields.extend((x, node.lineno) for x in values)
                else: self.expression(node.value, env)
        return UNKNOWN


def safe_json(value: Any) -> Any:
    if value is UNKNOWN: return "<runtime input>"
    if isinstance(value, (tuple, list, range)): return [safe_json(x) for x in value]
    if isinstance(value, dict): return {str(k): safe_json(v) for k, v in value.items()}
    if isinstance(value, (str, int, float, bool)) or value is None: return value
    return str(value)


def arguments(tree: ast.Module) -> list[str]:
    result = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "add_argument":
            switches = [x.value for x in node.args if isinstance(x, ast.Constant) and isinstance(x.value, str)]
            details = {x.arg: ast.unparse(x.value) for x in node.keywords if x.arg in {"required", "default", "choices", "help", "action"}}
            result.append(", ".join(switches) + ("; " + "; ".join(f"{k}={v}" for k, v in details.items()) if details else ""))
    return result


def run_command(path: str, tree: ast.Module | None = None) -> str:
    if path.endswith(".mjs"):
        if path.endswith("check-zstd-frames.mjs"): return f"node {path} <NVStorageProbe>"
        if path.endswith("inspect-storage-history.mjs"): return f"node {path} < probe-inspection.json"
        return f"node {path}"
    if path.endswith(".sh"):
        first = (ROOT / path).read_text().splitlines()[0]
        return f"{'zsh' if 'zsh' in first else 'bash'} {path}"
    if path.endswith(".py"):
        cmd = f"python3 {path}"
        if path.endswith("check-projection-encoding-observations.py"):
            cmd += " <host-observations.json>"
        if tree is not None:
            for node in ast.walk(tree):
                if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "add_argument":
                    required = any(x.arg == "required" and isinstance(x.value, ast.Constant) and x.value.value is True for x in node.keywords)
                    switches = [x.value for x in node.args if isinstance(x, ast.Constant) and isinstance(x.value, str)]
                    if required and switches:
                        switch = switches[0]
                        value = {"--modules": "<built-Swift-modules-directory>", "--binary": "<NVStorageProbe>", "--java": '"$TLC_JAVA"', "--jar": '"$TLC_JAR"', "--local-binary": "<local-probe>", "--remote-binary": "<peer-probe>", "--identity": "<SSH-key>", "--host": "<authorized-test-host>"}.get(switch, "<" + switch.lstrip("-") + ">")
                        cmd += " " + switch + " " + value
        if path.endswith("link-integration-test.py"):
            cmd += " -- <clang-link-command>"
        return cmd
    return "Use the containing runner listed with this source."


def entry(path: str, name: str, kind: str, line: int, purpose: str, command: str, **extra) -> dict[str, Any]:
    result = dict(id=f"{kind}:{path}#{name}", source=path, name=name, kind=kind, line=line, purpose=purpose, command=command, phase=phase(path, name), status="retired" if RETIRED in path else "implemented source")
    result.update(extra)
    return result


def swift_tests(p: Path, text: str) -> list[dict[str, Any]]:
    result = []
    for match in re.finditer(r"(?m)^\s*@Test\b", text):
        func = re.search(r"\bfunc\s+(\w+)\s*\(", text[match.end():])
        if not func: raise ValueError(f"Missing function for @Test in {p}")
        start = match.end() + func.start()
        name = func.group(1)
        attribute = clean(text[match.start():start], 0)
        line = text[:start].count("\n") + 1
        command = f"make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='--no-parallel --filter {name}'"
        for variable, value in re.findall(r'environment\["(\w+)"\]\s*==\s*"([^"]+)"', attribute):
            command = f"env {variable}={shlex.quote(value)} " + command
        required_paths = {"NV_STORAGE_SCAN_BENCHMARK_NATIVE": "<DirectoryScanBenchmark>", "NV_STORAGE_COORDINATION_PEER": "<RepositoryCoordinationPeer>", "NV_STORAGE_DISCOVERY_VARIANTS": "<writable-benchmark-artifact-directory>", "NV_STORAGE_DISCOVERY_ANALYSIS": "<writable-benchmark-artifact-directory>"}
        for variable in re.findall(r'environment\["(\w+)"\]\s*!=\s*nil', attribute):
            command = f"env {variable}='{required_paths.get(variable, '<required-value>')}' " + command
        result.append(entry(relative(p), name, "swift", line, "Checks " + words(name) + ".", command, declaration=attribute, parameterized="arguments:" in attribute))
    return result


def python_entries(p: Path, text: str) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    path, tree = relative(p), ast.parse(text)
    if path in {"tools/qualification_reuse.py", "tools/compiler_probe_batches.py"}:
        # The shared module is exercised through its consumers and harness suite.
        return [], {"expanded_rows": 0, "arguments": [], "data_steps": 0}
    command = run_command(path, tree)
    description = (ast.get_docstring(tree) or "Project validation runner; see its scenario and argument declarations.").split("\n\n")[0]
    description = clean(description)
    item = entry(path, p.stem, "runner", 1, description, command, arguments=arguments(tree))
    result = [item]
    for cls in (x for x in tree.body if isinstance(x, ast.ClassDef)):
        for fn in cls.body:
            if isinstance(fn, ast.FunctionDef) and fn.name.startswith("test_"):
                result.append(entry(path, cls.name + "." + fn.name, "python-test", fn.lineno, clean(ast.get_docstring(fn) or "Checks " + words(fn.name) + "."), command + " " + cls.name + "." + fn.name))
    for fn in (x for x in tree.body if isinstance(x, ast.FunctionDef)):
        if fn.name not in {"main", "cases", "experiments"} and re.search(r"(?:lifecycle|qualify|self_test|contract|_checks|^test_|^check_)", fn.name):
            result.append(entry(path, fn.name, "runner-case", fn.lineno, clean(ast.get_docstring(fn) or "Checks " + words(fn.name) + " as a scenario/helper invoked by the containing runner."), command, group="named scenario/helper"))
    reader = DataReader(tree)
    if "cases" in reader.functions or "experiments" in reader.functions:
        fn = reader.functions.get("cases", reader.functions.get("experiments"))
        reader.statements(fn.body, dict(reader.env))
    if "main" in reader.functions:
        main_body = reader.functions["main"].body
        if "docs/tla/" in path and reader.yields:
            # Matrix declarations precede the runner's filesystem/TLC loop.
            for i, node in enumerate(main_body):
                if isinstance(node, ast.For) and (isinstance(node.iter, ast.Call) and isinstance(node.iter.func, ast.Name) and node.iter.func.id in {"cases", "experiments"} or isinstance(node.iter, ast.Name) and node.iter.id == "selected_cases"):
                    main_body = main_body[:i]; break
        reader.statements(main_body, dict(reader.env))
        if "full_temporal" in reader.defaults:
            reader.defaults["full_temporal"] = True
            reader.statements(main_body, dict(reader.env))
    elif "run" in reader.functions:
        reader.statements(reader.functions["run"].body, dict(reader.env))
    rows = []
    if "docs/tla/" in path:
        rows = [("generated", value, line) for value, line in reader.yields]
        rows += [(group, row, line) for group, values, line in reader.rows if group.lower() in {"cases", "selected_cases"} and isinstance(values, (list, tuple)) for row in values]
        if "check-migrated-models.py" in path:
            rows += [("baseline", (args[1], args[0], "static cfg", None), line) for label, args, line in reader.emissions if label == "run" and len(args) == 2 and all(isinstance(x, str) for x in args)]
    else:
        rows = [(group, row, line) for group, values, line in reader.rows if isinstance(values, (list, tuple)) for row in values]
        declared_names = {row[0] for _, row, _ in rows if isinstance(row, (tuple, list)) and row and isinstance(row[0], str)}
        for label, values, line in reader.emissions:
            if label == "check-label":
                known = [x for x in values if isinstance(x, (str, int, bool))]
                if known:
                    name = " ".join(map(str, known)).replace("PASS:", "").strip()
                    if name not in declared_names: rows.append(("check-label", (name,), line))
            elif values and isinstance(values[0], str):
                if values[0] not in declared_names: rows.append(("runner-step", (values[0],), line))
    seen = set()
    for group, row, line in rows:
        if isinstance(row, dict):
            name = row.get("name", UNKNOWN)
        elif isinstance(row, (list, tuple)) and row and isinstance(row[0], str):
            name = row[1] if "check-uuid-experiments" in path and len(row) > 1 else row[0]
        else: continue
        if not isinstance(name, str) or not name or len(name) > 180 or "\n" in name or "func " in name: continue
        value = safe_json(row)
        key = json.dumps([name, value] if "docs/tla/" in path else [group, name, value], sort_keys=True)
        if key in seen: continue
        seen.add(key)
        if "docs/tla/" in path:
            kind = "tlc-case"
            purpose = "Checks the configured finite behavior and exact named property set; expected outcome is encoded in this row."
        elif "mutations" in path:
            kind = "mutation"
            purpose = "Challenges " + words(name) + " against the named companion/test and designated failure."
        elif "types" in path:
            kind = "compiler-case"
            purpose = "Checks " + words(name) + " at the compiler/diagnostic boundary."
        else:
            kind = "runner-case"
            purpose = "Checks " + words(name) + " through this runner's assertions."
        cmd = command
        if "docs/tla/" in path and any(x.startswith("--only") for x in item["arguments"]):
            cmd += " --only " + shlex.quote(name)
            if name == "merge-converges-third": cmd += " --full-temporal"
        elif kind == "mutation" and any(x.startswith("--only") for x in item["arguments"]):
            cmd += " --only " + shlex.quote(name)
        if kind in {"compiler-case", "mutation"} and isinstance(value, list):
            value = [x if not isinstance(x, str) or "\n" not in x else "<source snippet: see linked declaration>" for x in value]
        added = entry(path, name, kind, line, purpose, cmd, group=group, matrix=value)
        if kind == "tlc-case":
            model_names = {q.stem for q in (ROOT / "docs/tla").rglob("*.tla")}
            declared = row.get("model") if isinstance(row, dict) else next((x for x in row if isinstance(x, str) and x in model_names), None)
            if declared is None:
                literals = {x.value.removesuffix(".tla") for x in ast.walk(tree) if isinstance(x, ast.Constant) and isinstance(x.value, str) and (x.value in model_names or x.value.removesuffix(".tla") in model_names)}
                if len(literals) == 1: declared = next(iter(literals))
            if declared: added["model"] = declared
            if "check-uuid-experiments" in path: added["status"] = "policy experiment / see adoption boundaries in TLA guide"
        result.append(added)
    details = {"expanded_rows": len(seen), "arguments": arguments(tree), "data_steps": reader.steps}
    return result, details


def native_entries(p: Path, text: str) -> list[dict[str, Any]]:
    path = relative(p)
    result = []
    if p.name == "NVIntegrationTest.m":
        pattern = r'\[scenario isEqualToString:@"([^"]+)"\][^\n]*\n?\s*([^\n]+)'
        for m in re.finditer(pattern, text):
            name = m.group(1)
            result.append(entry(path, name, "native-case", text[:m.start()].count("\n") + 1, "Checks " + words(name) + ". Dispatch: " + clean(m.group(2), 200), f"make -C tests /tmp/notation-integration-tests/NVIntegrationTest && /tmp/notation-integration-tests/NVIntegrationTest {name}"))
    # Individual functions also expose subchecks used by the dispatch or a probe.
    for m in re.finditer(r'(?m)^(?:static\s+)?(?:void|int|BOOL|bool|[A-Za-z_][\w *]+)\s+((?:(?:Test|Run|test_|check_|probe_|run_test|benchmark)[A-Za-z0-9_]*|[a-zA-Z0-9]+_(?:checks|contracts)))\s*\([^;]*?\)\s*\{', text):
        name = m.group(1)
        result.append(entry(path, name, "native-function", text[:m.start()].count("\n") + 1, "Checks " + words(name) + " within the containing native executable.", f"Run the containing executable/runner for {p.name}; this function is an internal check."))
    if p.name in {"ICloudAPIContractTest.m", "ICloudMetadataProbe.h", "ICloudRootLockProbe.h"}:
        for m in re.finditer(r'\[mode isEqualToString:@"([^"]+)"\]', text):
            name = m.group(1)
            result.append(entry(path, name, "native-case", text[:m.start()].count("\n") + 1, "Drives " + words(name) + " through the signed Apple API contract executable. Supply the mode-specific arguments from its dispatch and the API ledger.", f"make -C tests /tmp/notation-integration-tests/ICloudAPIContractTest.app && /tmp/notation-integration-tests/ICloudAPIContractTest.app/Contents/MacOS/ICloudAPIContractTest {name} <authorized-synthetic-root> <mode-specific-arguments>"))
        for m in re.finditer(r'\bReport(?:Error)?\((.*?)\);', text, re.S):
            for label in re.findall(r'@"((?:AV-|REMOTE-)[^"\n]+)"', m.group(1)):
                result.append(entry(path, label, "native-observation", text[:m.start()].count("\n") + 1, "Reports " + words(label) + "; the source distinguishes PASS/FAIL assertions from OBSERVE/READY primitive observations. Required capability and stimulus rules are in the Apple API ledger.", "Run its containing ICloudAPIContractTest mode or Makefile target from the API ledger; this observation has no independent CLI mode."))
    for m in re.finditer(r'\bstrcmp\(\s*(?:mode|argv\[\d+\])\s*,\s*"([^"]+)"\s*\)', text):
        name = m.group(1)
        result.append(entry(path, name, "native-case", text[:m.start()].count("\n") + 1, "Exercises the " + words(name) + " native stimulus/mode within this probe.", "Use this probe's linked parent runner; it supplies the complete CLI, fault stimulus and independent assertions."))
    if not result and p.suffix in {".c", ".m"} and re.search(r"\bmain\s*\(", text):
        result.append(entry(path, p.stem, "native-probe", text[:text.index("main")].count("\n") + 1, "Exercises the " + words(p.stem) + " native contracts through its command-line driver.", "Use the Makefile or Python runner linked to this source in the source inventory."))
    return result


def formal_entries(p: Path, text: str) -> list[dict[str, Any]]:
    path = relative(p)
    if p.suffix == ".tla":
        intro = re.search(r"\(\*(.*?)\*\)", text, re.S)
        purpose = clean(intro.group(1), 1200) if intro else "Models " + words(p.stem) + "; consult its configured invariants and properties below."
        return [entry(path, p.stem, "model", 1, purpose, "Use the static configuration or generated runner cases listed for this module.")]
    sections = defaultdict(list)
    active = ""
    keywords = {"SPECIFICATION", "INIT", "NEXT", "CONSTANTS", "CONSTANT", "INVARIANT", "INVARIANTS", "PROPERTY", "PROPERTIES", "CONSTRAINT", "CONSTRAINTS", "ACTION_CONSTRAINT", "ACTION_CONSTRAINTS", "CHECK_DEADLOCK", "SYMMETRY", "VIEW", "ALIAS", "POSTCONDITION"}
    for line in text.splitlines():
        line = line.split("\\*")[0].strip()
        if not line: continue
        parts = line.split(None, 1)
        if parts[0] in keywords:
            active = parts[0]
            if len(parts) > 1: sections[active].append(parts[1])
        elif active: sections[active].append(line)
    module = p.stem
    if not p.with_suffix(".tla").exists():
        possible = sorted(x.stem for x in p.parent.glob("*.tla") if p.stem.startswith(x.stem.removesuffix("Safety")))
        module = max(possible, key=len) if possible else "<module-from-TLA-README>"
    cmd = f'cd {p.parent.relative_to(ROOT)} && "$TLC_JAVA" -jar "$TLC_JAR" -config {p.name} {module}.tla'
    return [entry(path, p.stem, "tlc-config", 1, "Checks " + words(p.stem) + " with this exact finite configuration.", cmd, configuration=dict(sections), module=module)]


def doc_sources() -> list[Path]:
    result = [p for p in (ROOT / "docs").rglob("*.md") if "test-index" not in p.parts and p.name not in {"Test-and-Validation-Index.md", "Test-and-Validation-Index-Archived.md"}]
    result += [ROOT / name for name in ("AGENTS.md", "CONTEXT.md", "README.md") if (ROOT / name).exists()]
    result += list((ROOT / "NVStorage").glob("*.md"))
    return sorted(set(result))


def documentation_contracts(p: Path, text: str) -> list[dict[str, Any]]:
    result = []
    seen = set()
    if re.search(r"validat|experiment|audit|review|integrationtests|conformance-testing", p.name, re.I):
        heading = next((line.lstrip("# ") for line in text.splitlines() if line.startswith("#")), p.stem)
        result.append(entry(relative(p), "Validation document: " + heading, "validation-document", 1, "Defines or records " + heading + ". Consult its status, revision, platform limits, command blocks and independent observations.", "Use this document's recorded commands and prerequisite artifacts. Historical /tmp-only experiments may require recreating their fixture/tool; the report is retained evidence rather than a new reproducible pass.", status="validation plan / experiment / recorded report; see document status", phase="cross-phase validation document"))
    # Named test contracts and scenario-matrix rows are first-class catalogue entries.
    pattern = r"^(?:#{2,6}\s+|\|\s*)(`?(?:TC-[A-Z]+-\d+|AV-\d+(?:[a-z])?|P5[0-9]?-\d+|P5-[A-Z]+(?:-\d+)?|(?:PC|RP|CP|RS|B|R|T)\d{2}|L[1-4](?:\.\d+)?|S[1-6])`?)(?:\s*[—:–-]\s*|\s*(?:/[^|]*\|\s*|\|\s*))(.*)"
    for line_no, line in enumerate(text.splitlines(), 1):
        m = re.match(pattern, line)
        if not m: continue
        name = m.group(1).strip("`")
        if name in seen: continue
        seen.add(name)
        cells = [x.strip().strip("`") for x in m.group(2).strip().strip("|").split("|")]
        purpose = " — ".join(x for x in cells if x)
        result.append(entry(relative(p), name, "contract", line_no, purpose, "Run the linked implementation witnesses; this document defines the contract/scenario, rather than a standalone executable.", status="specified contract / scenario", phase="cross-phase contract"))
    if not any(x in relative(p) for x in ("impl-proposal-5", "docs/tla/", "Apple-API-Contract-Validation", "Foundation-Safe-Replacement-Migration", "IntegrationTests")): return result
    lines = text.splitlines()
    occupied = {x["line"] for x in result}
    headings: list[tuple[int, str]] = []
    for i, line in enumerate(lines):
        heading = re.match(r"^(#{1,6})\s+(.*)", line)
        if heading:
            level = len(heading.group(1))
            headings = [(n, title) for n, title in headings if n < level] + [(level, heading.group(2))]
            if re.search(r"test|validat|qualif|acceptance checks|negative controls|mutation", heading.group(2), re.I) and i + 1 not in occupied:
                paragraph = []
                for child in lines[i + 1:]:
                    if child.startswith("#"): break
                    if child.strip(): paragraph.append(child)
                    if len(paragraph) >= 5: break
                result.append(entry(relative(p), "Section: " + heading.group(2), "planned-check", i + 1, " ".join(paragraph) or heading.group(2), "Follow this section's exact commands and scenario matrix; completion evidence is in its linked validation ledger.", status="documented validation section", phase="cross-phase documentation"))
        if line.startswith("|") and i + 1 < len(lines) and re.match(r"\|[\s:|-]+\|", lines[i + 1]):
            header = line.lower()
            if not re.search(r"scenario|schedule|test|independent|assertion|observation|challenge|evidence|qualification", header): continue
            for j in range(i + 2, len(lines)):
                if not lines[j].startswith("|"): break
                if j + 1 in occupied: continue
                cells = [x.strip() for x in lines[j].strip().strip("|").split("|")]
                if not cells or not cells[0] or cells[0] in {"P0", "P1", "P2"}: continue
                name = " / ".join([headings[-1][1] if headings else p.stem, cells[0]])
                result.append(entry(relative(p), name, "planned-check", j + 1, " — ".join(cells), "Use the commands/implementation witnesses named in this section. A matrix row is a specified check; qualification is established only by its linked result ledger.", status="document-defined matrix check", phase="specified cross-phase scenario"))
                occupied.add(j + 1)
        test_section = any(re.search(r"(?:test|validat|qualif|acceptance|exit gate|negative control|mutations)", title, re.I) for _, title in headings)
        bold_section = i > 0 and any(re.match(r"\*\*(?:Tests|Tests / exit)\*\*", x) for x in lines[max(0, i - 12):i])
        if (test_section or bold_section) and re.match(r"^[-*]\s+", line) and i + 1 not in occupied:
            body = line[2:]
            if not re.search(r"test|check|assert|expect|verify|requir|preserv|crash|fail|bound|reject|companion|probe|mutat|witness|reopen|read|startup|scope|evidence|compile|fixture|bench|retai|loss|input|import|receip", body, re.I): continue
            name = " / ".join([headings[-1][1] if headings else p.stem, clean(body, 100)])
            result.append(entry(relative(p), name, "planned-check", i + 1, body, "Use this section's named runner/contract. This bullet records required validation; follow its linked implementation/qualification status.", status="document-defined validation requirement", phase="specified cross-phase scenario"))
    return result


def refs_for(entries: list[dict[str, Any]], documents: dict[str, str], files: dict[str, str]):
    token_docs: dict[str, set[str]] = defaultdict(set)
    keys = set()
    for item in entries:
        keys.update([item["source"], Path(item["source"]).name, Path(item["source"]).stem, item["name"]])
    keys = {x for x in keys if len(x) > 4 and x not in {"Makefile", "README", "SchemaV1", "main", "cases"}}
    # Fixed substrings preserve the documents' actual spellings and scoped filters.
    for key in keys:
        for doc, text in documents.items():
            if key in text: token_docs[key].add(doc)
    # Follow explicit source-to-runner edges; these label suite-level references.
    source_consumers: dict[str, set[str]] = defaultdict(set)
    for path in files:
        basename = Path(path).name
        if len(basename) < 6: continue
        for consumer, content in files.items():
            if path != consumer and (basename in content or path in content): source_consumers[path].add(consumer)
    global_refs = {"docs/impl-proposal-5/plan/swift-storage-implementation-plan.md", "docs/impl-proposal-5/plan/swift-storage-conformance-testing-strategy.md", "docs/impl-proposal-5/plan/swift-storage-library-proposal-v2.md"}
    for item in entries:
        path = item["source"]
        exact = token_docs[item["name"]] | token_docs[path] | token_docs[Path(path).name] | token_docs[Path(path).stem]
        if item["kind"] in {"contract", "planned-check", "validation-document"}: exact.add(path)
        via = set()
        pending, visited = [path], set()
        while pending:
            current = pending.pop()
            if current in visited: continue
            visited.add(current)
            for consumer in source_consumers[current]:
                if consumer.endswith("Makefile") or consumer == "tools/generate-test-index.py": continue
                via |= token_docs[consumer] | token_docs[Path(consumer).name] | token_docs[Path(consumer).stem]
                pending.append(consumer)
        # SwiftPM's aggregate includes every declared Swift Testing case.
        if item["kind"] == "swift":
            via |= token_docs["test-storage-phase2"] | token_docs["test-storage-phase2.py"]
            via |= {doc for doc, text in documents.items() if "run-swift-storage" in text}
            for doc, text in documents.items():
                for match in re.finditer(r"--filter\s+['\"]?([^\n'\"`]+)", text):
                    try:
                        if re.search(match.group(1).strip(), item["name"]): exact.add(doc)
                    except re.error: pass
        if path.startswith("NVStorage/") or "storage" in Path(path).name:
            via |= global_refs & documents.keys()
        item["references"] = sorted(exact)
        item["suite_references"] = sorted(via - exact)
        governing = set()
        for pattern, names in GOVERNING:
            if re.search(pattern, path + " " + item["name"]): governing.update(PLAN + x for x in names)
        if item["kind"] in {"native-case", "native-function", "native-probe", "native-observation"}: governing.add("docs/IntegrationTests.md")
        if "ICloud" in path or "FSEventsHistory" in path: governing.add("docs/Apple-API-Contract-Validation.md")
        if "docs/tla/" in path and RETIRED not in path: governing.update({"docs/tla/README.md", "docs/tla/Proposal5-Coverage.md"})
        item["governing_references"] = sorted((governing & documents.keys()) - exact - via) if RETIRED not in path else []
        item["consumers"] = sorted(visited - {path})


def link(path: str, from_path: str, line: int = 0, label: str = "") -> str:
    import os
    target = os.path.relpath(path, str(Path(from_path).parent))
    display = (label or Path(path).name).replace("[", r"\[").replace("]", r"\]")
    return f"[{display}]({target}" + (f"#L{line}" if line else "") + ")"


def rebase_links(text: str, source: str, destination: str) -> str:
    """Keep document-defined check descriptions linked to their original targets."""
    import os
    def replace(match: re.Match[str]) -> str:
        target = match.group(2)
        if re.match(r"[a-zA-Z][a-zA-Z0-9+.-]*:", target) or target.startswith("/"): return match.group(0)
        filename, separator, fragment = target.partition("#")
        original = os.path.normpath(str(Path(source).parent / filename)) if filename else source
        moved = os.path.relpath(original, str(Path(destination).parent))
        return f"[{match.group(1)}]({moved}" + ("#" + fragment if separator else "") + ")"
    return re.sub(r"\[([^\]\n]+)\]\(([^)\s]+)\)", replace, text)


def render(catalog: dict[str, Any]) -> dict[str, str]:
    outputs = {}
    entries = catalog["entries"]
    refsets = sorted({tuple(x[k]) for x in entries for k in ("references", "suite_references", "governing_references")})
    refids = {r: f"R{i:03}" for i, r in enumerate(refsets, 1)}
    groups = {
        "swift-core.md": ("Swift Core tests", lambda x: x["kind"] == "swift" and "CoreTests" in x["source"]),
        "swift-runtime.md": ("Swift Runtime tests", lambda x: x["kind"] == "swift" and "RuntimeTests" in x["source"]),
        "runners-and-experiments.md": ("Executable runners, fixtures and experiments", lambda x: x["kind"] in {"runner", "python-test", "runner-case", "script", "javascript-check", "make-target", "probe-mode", "probe-request"} and RETIRED not in x["source"]),
        "compiler-and-mutations.md": ("Compiler probes and mutation challenges", lambda x: x["kind"] in {"compiler-case", "mutation"} and RETIRED not in x["source"]),
        "native-and-legacy.md": ("Native and legacy integration checks", lambda x: x["kind"] in {"native-case", "native-function", "native-probe", "native-observation"}),
        "formal-models.md": ("Active and exploratory formal models", lambda x: x["kind"] in {"model", "tlc-config", "tlc-case"} and RETIRED not in x["source"]),
        "specified-contracts.md": ("Cross-phase contracts and planned scenarios", lambda x: x["kind"] in {"contract", "planned-check", "validation-document"} and RETIRED not in x["source"]),
    }
    for filename, (title, predicate) in groups.items():
        path = "docs/test-index/" + filename
        selected = [x for x in entries if predicate(x)]
        lines = [f"# {title}", "", "Generated by `python3 tools/generate-test-index.py --write`. See the [main index](../Test-and-Validation-Index.md) for prerequisites, interpretation and coverage boundaries.", "", f"{len(selected)} catalogue entries. Source and document references describe definitions, not a new qualification run.", ""]
        for source, items in itertools.groupby(selected, lambda x: x["source"]):
            items = list(items)
            lines += ["## " + source, "", "Source: " + link(source, path) + ". Phase: " + clean(items[0]["phase"]) + ".", ""]
            lines += ["| Check | Purpose and declared scope | How to run | References |", "| --- | --- | --- | --- |"]
            for item in items:
                purpose = rebase_links(item["purpose"], source, path) if source.endswith(".md") else item["purpose"]
                if item["status"] not in {"implemented source", "retired"}: purpose += " Status: " + item["status"] + "."
                if item.get("declaration"): purpose += " Declaration: '" + item["declaration"] + "'."
                if item.get("matrix") is not None:
                    value = item["matrix"]
                    # Compiler/mutation source snippets remain in source; record keys and expectations stay visible.
                    if item["kind"] in {"compiler-case", "mutation"} and isinstance(value, list):
                        value = [x if not isinstance(x, str) or "\n" not in x else "<source snippet: see linked declaration>" for x in value]
                    purpose += " Matrix row: '" + clean(json.dumps(value, ensure_ascii=False)) + "'."
                if item.get("configuration"): purpose += " Effective cfg: '" + clean(json.dumps(item["configuration"], ensure_ascii=False)) + "'."
                references = refids[tuple(item["references"])]
                suite = refids[tuple(item["suite_references"])]
                governing = refids[tuple(item["governing_references"])]
                lines.append(f"| {link(source, path, item['line'], item['name'])} | {clean(purpose)} | `{clean(item['command'])}` | [direct {references}](document-references.md#{references.lower()}); [suite {suite}](document-references.md#{suite.lower()}); [governing {governing}](document-references.md#{governing.lower()}) |")
            lines.append("")
            if items[0].get("arguments"):
                lines += ["Runner arguments (from source):", ""] + ["- `" + clean(x) + "`" for x in items[0]["arguments"]] + [""]
        outputs[path] = "\n".join(lines) + "\n"
    # Retired details stay beside the retired models, outside the active catalogue.
    path = RETIRED + "impl-proposal-4/Test-and-Validation-Index-Archived.md"
    retired = [x for x in entries if RETIRED + "impl-proposal-4/" in x["source"]]
    lines = ["# Retired proposal-4 validation inventory", "", "Generated inventory of archived checkpoint/WAL models. These checks describe the retired design; the [active index](../../../Test-and-Validation-Index.md) covers proposal 5 and the still-supported epoch-4 app path. Use the [archive guide](README.md) for historical interpretation.", "", "| Check | Purpose/configuration | Historical command | References |", "| --- | --- | --- | --- |"]
    for item in retired:
        detail = item.get("configuration", item.get("matrix", ""))
        lines.append(f"| {link(item['source'], path, item['line'], item['name'])} | {clean(item['purpose'])} {clean(json.dumps(detail))} | `{clean(item['command'])}` | " + ", ".join(link(x, path) for x in item["references"] + item["suite_references"]) + " |")
    outputs[path] = "\n".join(lines) + "\n"
    path = "docs/test-index/document-references.md"
    lines = ["# Documentary cross-reference", "", "Each reference set expands three labels. Direct means the document names the check, source, module or runner (or a matching Swift filter). Suite means an explicit source/runner dependency or the documented Swift aggregate includes it. Governing supplies the curated family-level plan/contract when the document describes the feature without naming that implementation symbol. These are usage/authority references, not assertions that every document specifies every internal assertion. A document can be both a plan and a qualification ledger.", ""]
    for refs, identifier in refids.items():
        lines += [f"## {identifier}", ""]
        lines += ["- " + link(x, path, label=x) for x in refs] if refs else ["No explicit documentary mention found; use the source and containing runner. This is recorded rather than inventing a plan reference."]
        lines.append("")
    lines += ["## Reverse document lookup", "", "The JSON catalogue provides complete check IDs; these counts distinguish reference kinds.", "", "| Document | Direct entries | Suite entries | Governing entries |", "| --- | ---: | ---: | ---: |"]
    for doc in catalog["documents"]:
        direct = sum(doc in x["references"] for x in entries)
        via = sum(doc in x["suite_references"] for x in entries)
        governing = sum(doc in x["governing_references"] for x in entries)
        lines.append(f"| {link(doc, path, label=doc)} | {direct} | {via} | {governing} |")
    outputs[path] = "\n".join(lines) + "\n"
    path = "docs/test-index/source-inventory.md"
    lines = ["# Source and support-file coverage", "", "Every project-owned validation file under the inventoried roots appears here. Helpers, fixtures, fault hooks and process drivers support executable checks; they are not individually counted as test declarations. Vendored upstream suites and generated build products are outside this project-owned index.", "", "| Source | Role | Catalogue entries | Referencing runners/sources |", "| --- | --- | ---: | --- |"]
    for source in catalog["sources"]:
        if RETIRED in source["path"]: continue
        consumers = sorted({c for x in entries if x["source"] == source["path"] for c in x.get("consumers", [])})
        lines.append(f"| {link(source['path'], path, label=source['path'])} | {source['role']} | {source['entries']} | " + ", ".join(link(x, path) for x in consumers) + " |")
    outputs[path] = "\n".join(lines) + "\n"
    compact = {**catalog, "reference_sets": {refids[r]: list(r) for r in refsets}, "entries": []}
    compact["source_counts_including_archive"] = compact.pop("counts")
    compact["sources"] = [x for x in catalog["sources"] if RETIRED not in x["path"]]
    compact["documents"] = [x for x in catalog["documents"] if RETIRED not in x]
    compact["document_sha256"] = {x: catalog["document_sha256"][x] for x in compact["documents"]}
    for item in entries:
        if RETIRED in item["source"]: continue
        row = {k: v for k, v in item.items() if k not in {"references", "suite_references", "governing_references", "consumers"}}
        row["references"] = refids[tuple(item["references"])]
        row["suite_references"] = refids[tuple(item["suite_references"])]
        row["governing_references"] = refids[tuple(item["governing_references"])]
        compact["entries"].append(row)
    compact["counts"] = dict(sorted(Counter(x["kind"] for x in compact["entries"]).items()))
    outputs["docs/test-index/catalog.json"] = json.dumps(compact, indent=2, ensure_ascii=False) + "\n"
    return outputs


def build() -> dict[str, Any]:
    sources = project_files()
    files = {relative(p): p.read_text(errors="replace") for p in sources}
    documents = {relative(p): p.read_text() for p in doc_sources()}
    entries, inspections = [], {}
    for p in sources:
        path, text = relative(p), files[relative(p)]
        if p.suffix == ".swift":
            entries += swift_tests(p, text)
            if "Tests/Support/NVStorageProbe" in path:
                # Probe command modes are exercised by the process runners; body helpers remain support.
                for m in re.finditer(r'(?:command\s*==\s*|args\[0\]\s*==\s*)"([a-z][a-z0-9-]+)"', text):
                    name = m.group(1)
                    entries.append(entry(path, name, "probe-mode", text[:m.start()].count("\n") + 1, "Drives the " + words(name) + " fresh-process scenario; the Python parent independently checks results.", "Use the linked process runner with --binary <NVStorageProbe>; its invocation supplies the exact required mode arguments."))
                for m in re.finditer(r'\[([^\n\]]+)\]\.contains\((?:command|args\[0\])\)', text):
                    for name in re.findall(r'"([a-z][a-z0-9-]+)"', m.group(1)):
                        entries.append(entry(path, name, "probe-mode", text[:m.start()].count("\n") + 1, "Drives " + words(name) + " through the fresh-process probe's declared command family.", "Use the linked process runner with --binary <NVStorageProbe>; its schedule supplies the required inputs."))
                for switch in re.finditer(r"(?m)^([ \t]*)switch (command|args\[0\]|request\.command)\s*\{\s*$", text):
                    indent = switch.group(1)
                    end = re.search(r"(?m)^" + indent + r"\}", text[switch.end():])
                    block = text[switch.end():switch.end() + end.start()] if end else text[switch.end():]
                    for case in re.finditer(r"(?m)^" + indent + r"case ([^\n:]+):", block):
                        for name in re.findall(r'"([a-z][a-z0-9-]+)"', case.group(1)):
                            request = switch.group(2) == "request.command"
                            entries.append(entry(path, name, "probe-request" if request else "probe-mode", text[:switch.end() + case.start()].count("\n") + 1, "Drives " + words(name) + (" as a JSON request to the owned long-lived probe." if request else " through the production-backed fresh-process probe."), "Use the linked process runner; it supplies selection/unlock inputs, complete CLI/request stimulus and independent expected results."))
        elif p.suffix == ".py":
            found, details = python_entries(p, text)
            entries += found; inspections[path] = details
        elif p.suffix in {".m", ".c", ".h"}:
            entries += native_entries(p, text)
        elif p.suffix in {".tla", ".cfg"}:
            entries += formal_entries(p, text)
        elif p.name == "Makefile":
            for m in re.finditer(r"(?m)^([\w-]+):[^=\n]*$", text):
                name = m.group(1)
                if name.startswith(("run", "stress", "leak", "filesystem-image", "app-objects")):
                    entries.append(entry(path, name, "make-target", text[:m.start()].count("\n") + 1, "Runs " + words(name) + " through the native/Swift build configuration and declared prerequisites.", f"make -C tests {name}"))
        elif p.suffix in {".sh", ".mjs"} and p.name.startswith(("test-", "run_", "check-", "inspect-", "build")):
            entries.append(entry(path, p.stem, "script", 1, "Runs " + words(p.stem) + "; see the linked script for exact validation assertions and required inputs.", run_command(path)))
            if p.name == "check-envelope-fixtures.mjs":
                for mode, extra in (("envelopes", ""), ("descriptors", " --descriptors")):
                    entries.append(entry(path, mode, "javascript-check", 1, "Independently reconstructs the frozen " + mode + " byte vectors using Node cryptography and checks exact fixture equality.", run_command(path) + extra))
            if p.name == "run_filesystem_image_tests.sh":
                for m in re.finditer(r"(?m)^\s*(run_test|run_observation)\s+[^\n]+\s([a-z][a-z0-9-]+)\s*$", text):
                    entries.append(entry(path, m.group(2), "runner-case", text[:m.start()].count("\n") + 1, "Runs " + words(m.group(2)) + " across the script's declared filesystem/capability matrix. Observation-only cases retain their own classification.", run_command(path)))
    for path, text in documents.items(): entries += documentation_contracts(ROOT / path, text)
    # Repeated declarations share one ID, while distinct parameter rows retain separate IDs.
    unique = {}
    for item in entries:
        key = item["id"]
        if key in unique and unique[key].get("matrix") != item.get("matrix"):
            suffix = hashlib.sha256(json.dumps(item.get("matrix"), sort_keys=True).encode()).hexdigest()[:10]
            key += ":" + suffix
            item["id"] = key
        unique.setdefault(key, item)
    entries = sorted(unique.values(), key=lambda x: (x["source"], x["line"], x["name"], x["id"]))
    configured = {x.get("model") for x in entries if x["kind"] in {"tlc-case", "tlc-config"}}
    experiment_models = {x.get("model") for x in entries if x["kind"] == "tlc-case" and x["source"].endswith("check-uuid-experiments.py")}
    for item in entries:
        if item["kind"] == "model" and RETIRED not in item["source"]:
            if item["name"] in experiment_models:
                item["status"] = "policy experiment; adoption and assumptions are recorded in the TLA guide"
            elif item["name"] not in configured:
                item["status"] = "specification component; use importing/configured parent models rather than claiming a standalone run"
    refs_for(entries, documents, files)
    counts = Counter(x["source"] for x in entries)
    source_rows = []
    for path, text in files.items():
        role = "executable definitions" if counts[path] else "fixture / support / build prerequisite"
        if RETIRED in path: role = "retired source"
        source_rows.append(dict(path=path, role=role, entries=counts[path], sha256=hashlib.sha256(text.encode()).hexdigest()))
    swift_count = sum(len(re.findall(r"(?m)^\s*@Test\b", t)) for p, t in files.items() if p.endswith(".swift"))
    assert sum(x["kind"] == "swift" for x in entries) == swift_count, "Every @Test must have one catalogue entry"
    assert sum(x["kind"] == "model" for x in entries) == sum(p.endswith(".tla") for p in files)
    assert sum(x["kind"] == "tlc-config" for x in entries) == sum(p.endswith(".cfg") for p in files)
    return dict(format_version=1, scope="project-owned source definitions; execution/qualification stays in linked ledgers", counts=dict(sorted(Counter(x["kind"] for x in entries).items())), sources=source_rows, documents=sorted(documents), document_sha256={p: hashlib.sha256(t.encode()).hexdigest() for p, t in documents.items()}, inspections=inspections, entries=entries)


def self_test():
    source = '''CASES = [("one", 1)]
def cases():
    for mode in ("edit", "delete"):
        for crash in range(2):
            yield (f"{mode}-{crash}", mode, crash, "Exact", crash == 1)
def main():
    issuers = [("valid client", "source", None)]
    for name in ("Receipt", "Permission"):
        issuers.append((name + " issuer", f"func wrong() {{ {name}() }}", "private"))
    independent_jobs = [("schema", ["make", "run-sqlite-schema"])]
    independent_jobs += [(name, ["python3", name]) for name in ("first-fixture", "second-fixture")]
    independent_jobs.append(("strict-c", ["clang", "-Werror"]))
    dangerous = __import__("os").system("must never execute")
'''
    r = DataReader(ast.parse(source))
    r.statements(r.functions["cases"].body, dict(r.env))
    assert [x[0][0] for x in r.yields] == ["edit-0", "edit-1", "delete-0", "delete-1"]
    r.statements(r.functions["main"].body, dict(r.env))
    assert any(len(x[1]) == 3 for x in r.rows if x[0] == "issuers")
    assert any([row[0] for row in values] == ["schema", "first-fixture", "second-fixture", "strict-c"]
               for name, values, _ in r.rows if name == "independent_jobs")
    assert r.env.get("dangerous", UNKNOWN) is UNKNOWN
    tests = swift_tests(ROOT / "NVStorage/Tests/Example.swift", "@Test(.timeLimit(.minutes(1)), arguments: [1, 2])\nfunc exact() {}\n@Test func companion() {}")
    assert [x["name"] for x in tests] == ["exact", "companion"]
    assert tests[0]["parameterized"]
    r = DataReader(ast.parse("models = ('A', 'B')\nselected = None or models\n"))
    assert r.env["selected"] == ("A", "B")
    assert python_entries(ROOT / "tools/qualification_reuse.py", "def support(): pass\n")[0] == []
    assert python_entries(ROOT / "tools/compiler_probe_batches.py", "def support(): pass\n")[0] == []
    assert phase("tools/test-storage-apple-repair.py") == "5"
    assert phase("NVStorage/Tests/NVStorageRuntimeTests/CollectionCopySwitchTests.swift") == "5"
    assert phase("tools/test-storage-private-process.py") == "4"
    assert phase("NVStorage/Tests/NVStorageCoreTests/ProjectionStampTests.swift", "projectionStampRetainsDerivedReconstruction") == "6 (canonical records also qualify 1)"
    assert phase("tools/test-storage-runtime-mutations.py", "p61-stamp-overflow") == "6 (canonical records also qualify 1)"
    assert phase("NVStorage/Tests/NVStorageCoreTests/ProjectionDescriptorTests.swift", "projectionLeafRejectsUnsafeNames") == "6 (canonical records also qualify 1)"
    assert phase("NVStorage/Tests/NVStorageCoreTests/ProjectionFilenameTests.swift") == "6 (canonical records also qualify 1)"
    assert phase("tests/ProjectionTextEncodingProbe.swift") == "6 (canonical records also qualify 1)"
    assert phase("tests/ProjectionFilesCreateProbe.c") == "6 (canonical records also qualify 1)"
    assert phase("tests/ProjectionFilesCreateProcessProbe.c") == "6 (canonical records also qualify 1)"
    assert phase("tests/ProjectionFilesReplaceProbe.m") == "6 (canonical records also qualify 1)"
    assert phase("tests/ProjectionFilesPresenterProbe.m") == "6 (canonical records also qualify 1)"
    assert phase("tests/ProjectionFilesCleanupProbe.c") == "6 (canonical records also qualify 1)"
    assert phase("tests/ProjectionFilesRelocateProbe.m") == "6 (canonical records also qualify 1)"
    assert phase("NVStorage/Tests/Support/NVStorageTestSupport/Resources/ProjectionFilesSyncFault.c") == "6 (canonical records also qualify 1)"
    assert phase("NVStorage/Tests/Support/NVStorageTestSupport/ProjectionNativeFixtures.swift") == "6 (canonical records also qualify 1)"
    assert phase("tools/test-storage-runtime-mutations.py", "p62-cleanup-final-owner") == "6 (canonical records also qualify 1)"
    assert phase("NVStorage/Tests/NVStorageRuntimeTests/ProjectionFileCreationTests.swift") == "6 (canonical records also qualify 1)"
    assert phase("tools/test-projection-create-process.py") == "6 (canonical records also qualify 1)"
    assert run_command("tools/check-projection-encoding-observations.py") == "python3 tools/check-projection-encoding-observations.py <host-observations.json>"
    r = DataReader(ast.parse('''def main():
    cases = [("restricted", "source", "private"), ("companion", "source", None)]
    count = 0
    for same in (False, True):
        label = "same-module" if same else "ordinary"
        count += checker.run_probes(command, cases, directory, label=label, timeout=60)
'''))
    scope = dict(r.env)
    r.statements(r.functions["main"].body, scope)
    assert scope["count"] == 4
    assert [x[1][1:] for x in r.emissions] == [["ordinary", "restricted"], ["ordinary", "companion"],
                                            ["same-module", "restricted"], ["same-module", "companion"]]
    assert rebase_links("[contract](../Protocol.md#input)", "docs/impl-proposal-5/plan/check.md", "docs/test-index/checks.md") == "[contract](../impl-proposal-5/Protocol.md#input)"
    print("PASS: data-only matrix expansion, compiler-batch modes, blocked operations, multiline Swift declarations, phase classification, default selection and rebased document links")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="Regenerate the detailed Markdown and JSON catalogues")
    parser.add_argument("--check", action="store_true", help="Compare committed catalogues with current source definitions")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test: self_test()
    if not (args.write or args.check):
        if not args.self_test: parser.error("Choose --write, --check or --self-test")
        return
    catalog = build()
    outputs = render(catalog)
    different = []
    for name, body in outputs.items():
        p = ROOT / name
        if args.write:
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(body)
        elif not p.exists() or p.read_text() != body:
            different.append(name)
    print(json.dumps({"counts": catalog["counts"], "source_files": len(catalog["sources"]), "document_files": len(catalog["documents"]), "different": different}, indent=2))
    if different: sys.exit(1)


if __name__ == "__main__":
    main()
