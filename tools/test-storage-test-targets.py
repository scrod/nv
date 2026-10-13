#!/usr/bin/env python3
"""Check complete, disjoint Swift test membership and shared-fixture boundaries."""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
GROUPS = {"NVStorageRuntimeTests", "NVStorageRecoveryTests", "NVStorageRepositoryTests"}


def declared_groups(source):
    """Read the manifest's literal membership table, rejecting unfamiliar syntax."""
    table = re.search(r"let runtimeTestGroups: \[\(name: String, sources: \[String\]\)\] = \[\n(.*?)\n\]\n", source, re.S)
    if table is None:
        raise ValueError("Missing literal Runtime test table")
    groups = {}
    entry = re.compile(r'\("(\w+)", \[(.*?)\]\),', re.S)
    body = table[1]
    for match in entry.finditer(body):
        name, items = match.groups()
        names = re.findall(r'"([A-Za-z0-9_/]+\.swift)",', items)
        if re.sub(r'"[A-Za-z0-9_/]+\.swift",', '', items).strip():
            raise ValueError("Unrecognized source declaration")
        if name in groups or not names:
            raise ValueError("Duplicate or empty test group")
        groups[name] = names
    if entry.sub('', body).strip():
        raise ValueError("Unrecognized test group declaration")
    if set(groups) != GROUPS:
        raise ValueError("Required test groups differ")
    return groups


def check_inventory(groups, files):
    """Require every existing Swift test file to compile in exactly one target."""
    selected = Counter(name for names in groups.values() for name in names)
    expected = Counter(files)
    if selected != expected:
        raise ValueError(f"Test membership differs: missing={expected - selected}, extra={selected - expected}")


def listed_methods(output):
    """Read complete SwiftPM list output captured separately from diagnostics."""
    methods = []
    for line in output.splitlines():
        if not line.strip():
            continue
        match = re.fullmatch(r'(NVStorage\w*Tests)\.([\w/]+\([\w:]*\))', line)
        if match is None:
            raise ValueError(f"Malformed test-list entry: {line}")
        module, method = match.groups()
        if module in GROUPS:
            module = 'NVStorageRuntimeTests'
        methods.append(module + '.' + method)
    if not methods or len(set(methods)) != len(methods):
        raise ValueError("Test listing must contain distinct, nonempty logical identities")
    return Counter(methods)


def compare_listings(before, after):
    """Require exact test identities and argument labels across target partitioning."""
    previous, current = listed_methods(before), listed_methods(after)
    if previous != current:
        raise ValueError(f"Test discovery differs: missing={previous-current}, extra={current-previous}")
    return sum(current.values())


def check_description(groups, description, package, support_sources=('Fixtures.swift',)):
    """Compare the lightweight inventory with SwiftPM's actual resolved targets."""
    targets = {target['name']: target for target in description['targets']}
    for name, sources in groups.items():
        target = targets[name]
        if target['type'] != 'test' or Counter(target['sources']) != Counter(sources):
            raise ValueError(f"Resolved test target differs: {name}")
        if (package / target['path']).resolve() != (package / 'Tests/NVStorageRuntimeTests').resolve():
            raise ValueError(f"Test source directory differs: {name}")
        if 'NVStorageTestSupport' not in target['target_dependencies']:
            raise ValueError(f"Missing shared fixture dependency: {name}")
    support = targets['NVStorageTestSupport']
    if support['type'] != 'test' or Counter(support['sources']) != Counter(support_sources):
        raise ValueError("Shared fixtures must have their own complete source inventory")
    for product in description['products']:
        pending = list(product['targets'])
        visited = set()
        while pending:
            name = pending.pop()
            if name == 'NVStorageTestSupport' or name in groups:
                raise ValueError("A production product depends on test support")
            if name not in visited:
                visited.add(name)
                pending.extend(targets.get(name, {}).get('target_dependencies', []))


class TargetInventoryTests(unittest.TestCase):
    def setUp(self):
        self.groups = {name: [name + '.swift'] for name in sorted(GROUPS)}
        self.files = [file for files in self.groups.values() for file in files]
        entries = ''.join(f'    ("{name}", ["{files[0]}",]),\n' for name, files in self.groups.items())
        self.source = 'let runtimeTestGroups: [(name: String, sources: [String])] = [\n' + entries + '\n]\n'

    def test_complete_partition(self):
        self.assertEqual(declared_groups(self.source), self.groups)
        check_inventory(self.groups, self.files)

    def test_new_unlisted_file(self):
        with self.assertRaises(ValueError):
            check_inventory(self.groups, self.files + ['NewTests.swift'])

    def test_removed_file(self):
        with self.assertRaises(ValueError):
            check_inventory(self.groups, self.files[:-1])

    def test_duplicate_membership(self):
        self.groups['NVStorageRuntimeTests'].append(self.files[0])
        with self.assertRaises(ValueError):
            check_inventory(self.groups, self.files)

    def test_duplicate_group(self):
        entry = '    ("NVStorageRuntimeTests", ["Repeated.swift",]),\n'
        with self.assertRaises(ValueError):
            declared_groups(self.source.replace('\n]\n', entry + '\n]\n'))

    def test_missing_group(self):
        with self.assertRaises(ValueError):
            declared_groups(self.source.replace('NVStorageRuntimeTests', 'OtherTests'))

    def test_empty_group(self):
        with self.assertRaises(ValueError):
            declared_groups(self.source.replace('"NVStorageRuntimeTests.swift",', ''))

    def test_computed_source(self):
        with self.assertRaises(ValueError):
            declared_groups(self.source.replace('"NVStorageRuntimeTests.swift",', 'computedSources,'))

    def test_computed_group(self):
        with self.assertRaises(ValueError):
            declared_groups(self.source.replace('\n]\n', '\n    makeGroup(),\n]\n'))

    def description(self):
        targets = [dict(name=name, type='test', sources=files,
                        path='/fixture/Tests/NVStorageRuntimeTests',
                        target_dependencies=['NVStorageTestSupport']) for name, files in self.groups.items()]
        targets += [dict(name='NVStorageTestSupport', type='test', sources=['Fixtures.swift']),
                    dict(name='Production', target_dependencies=[])]
        return dict(targets=targets, products=[dict(targets=['Production'])])

    def test_resolved_membership(self):
        check_description(self.groups, self.description(), Path('/fixture'))

    def test_resolved_relative_directory(self):
        description = self.description()
        description['targets'][0]['path'] = 'Tests/NVStorageRuntimeTests'
        check_description(self.groups, description, Path('/fixture'))

    def test_resolved_omission(self):
        description = self.description()
        description['targets'][0]['sources'] = []
        with self.assertRaises(ValueError):
            check_description(self.groups, description, Path('/fixture'))

    def test_resolved_foreign_directory(self):
        description = self.description()
        description['targets'][0]['path'] = '/foreign'
        with self.assertRaises(ValueError):
            check_description(self.groups, description, Path('/fixture'))

    def test_resolved_missing_fixtures(self):
        description = self.description()
        description['targets'][0]['target_dependencies'] = []
        with self.assertRaises(ValueError):
            check_description(self.groups, description, Path('/fixture'))

    def test_resolved_support_omission(self):
        with self.assertRaises(ValueError):
            check_description(self.groups, self.description(), Path('/fixture'), ['Fixtures.swift', 'GrowthHistory.swift'])

    def test_resolved_support_inventory(self):
        description = self.description()
        description['targets'][-2]['sources'].append('GrowthHistory.swift')
        check_description(self.groups, description, Path('/fixture'), ['Fixtures.swift', 'GrowthHistory.swift'])

    def test_direct_production_dependency(self):
        description = self.description()
        description['targets'][-1]['target_dependencies'] = ['NVStorageTestSupport']
        with self.assertRaises(ValueError):
            check_description(self.groups, description, Path('/fixture'))

    def test_transitive_production_dependency(self):
        description = self.description()
        description['targets'][-1]['target_dependencies'] = ['Adapter']
        description['targets'].append(dict(name='Adapter', target_dependencies=['NVStorageTestSupport']))
        with self.assertRaises(ValueError):
            check_description(self.groups, description, Path('/fixture'))

    def test_listed_identity_preserves_scope_and_parameters(self):
        before = 'NVStorageCoreTests.example()\nNVStorageRuntimeTests.Suite/example(encrypted:)\n'
        after = 'NVStorageRepositoryTests.Suite/example(encrypted:)\nNVStorageCoreTests.example()\n'
        self.assertEqual(compare_listings(before, after), 2)

    def test_listed_missing_method(self):
        before = 'NVStorageRuntimeTests.first()\nNVStorageRuntimeTests.second()\n'
        with self.assertRaises(ValueError):
            compare_listings(before, 'NVStorageRuntimeTests.first()\n')

    def test_listed_changed_parameters(self):
        with self.assertRaises(ValueError):
            compare_listings('NVStorageRuntimeTests.first(encrypted:)\n',
                             'NVStorageRecoveryTests.first()\n')

    def test_listed_interleaved_diagnostic(self):
        with self.assertRaises(ValueError):
            listed_methods("NVStorageRuntimeTests.first(encrwarning: deprecated\nypted:)\n")

    def test_listed_duplicate_after_split(self):
        with self.assertRaises(ValueError):
            listed_methods('NVStorageRuntimeTests.first()\nNVStorageRecoveryTests.first()\n')

    def test_listed_empty_discovery(self):
        with self.assertRaises(ValueError):
            compare_listings('', '')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', type=Path, default=ROOT / 'NVStorage')
    parser.add_argument('--describe', action='store_true', help='Also verify SwiftPM-resolved membership and production dependency closure.')
    parser.add_argument('--self-test-only', action='store_true')
    parser.add_argument('--compare-inventory', type=Path, nargs=2, metavar=('BEFORE', 'AFTER'),
                        help='Compare complete SwiftPM stdout listings; capture diagnostics separately.')
    parser.add_argument('tests', nargs='*', help='Select individual unittest cases for focused harness checks.')
    args = parser.parse_args()
    loader = unittest.defaultTestLoader
    suite = (loader.loadTestsFromNames(args.tests, module=sys.modules[__name__]) if args.tests
             else loader.loadTestsFromTestCase(TargetInventoryTests))
    result = unittest.TextTestRunner(verbosity=1).run(suite)
    if not result.wasSuccessful() or result.testsRun < 1 or (not args.tests and result.testsRun != 24):
        raise SystemExit(1)
    if args.self_test_only or args.tests:
        return
    if args.compare_inventory:
        before, after = args.compare_inventory
        count = compare_listings(before.read_text(), after.read_text())
        print(f'PASS: identical {count} logical test identities and argument signatures')
    package = args.package.resolve()
    groups = declared_groups((package / 'Package.swift').read_text())
    root = package / 'Tests/NVStorageRuntimeTests'
    files = [file.relative_to(root).as_posix() for file in root.rglob('*.swift')]
    check_inventory(groups, files)
    support_root = package / 'Tests/Support/NVStorageTestSupport'
    support_files = sorted(support_root.rglob('*.swift'))
    for file in support_files:
        support = file.read_text()
        if '@Test' in support or '@testable' in support:
            raise ValueError("Shared fixtures use public storage APIs and keep test declarations in test targets")
    if args.describe:
        command = ['swift', 'package', '--package-path', str(package), 'describe', '--type', 'json']
        description = json.loads(subprocess.check_output(command, text=True, timeout=60))
        check_description(groups, description, package, [file.relative_to(support_root).as_posix() for file in support_files])
    print(f'PASS: all {len(files)} Runtime test source files occur exactly once across {len(groups)} targets')


if __name__ == '__main__':
    main()
