#!/usr/bin/env python3
"""Challenge batched diagnostics, original-source fallback and Swift access boundaries."""
from contextlib import redirect_stdout
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import compiler_probe_batches as batches


def negative(name, body='let _ = denied()'):
    return name, f'func wrong() {{ {body} }} // expected-error\n', 'restriction holds'


class BatchTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='nv-probe-batch-tests-')
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.calls = []

    def compiler(self, command, **options):
        self.assertEqual(options, dict(text=True, capture_output=True, timeout=60))
        files = [(Path(p), Path(p).read_text()) for p in command if p.endswith('.swift')]
        self.calls.append((command, files))
        diagnostics = []
        for path, source in files:
            for line, text in enumerate(source.splitlines(), 1):
                if '// expected-error' in text:
                    diagnostics.append(f'{path}:{line}:1: error: restriction holds\n')
        return subprocess.CompletedProcess(command, 1 if diagnostics else 0, '', ''.join(diagnostics))

    def run_cases(self, cases, *, compiler=None, maximum=8):
        with patch.object(batches.subprocess, 'run', side_effect=compiler or self.compiler), redirect_stdout(io.StringIO()):
            return batches.run_probes(['swiftc', '-swift-version', '6', '-strict-memory-safety', '-typecheck'],
                                     cases, self.directory, label='test', timeout=60, maximum=maximum)

    def test_compatible_probes_share_work_and_keep_distinct_files(self):
        self.assertEqual(self.run_cases([negative(str(i)) for i in range(10)], maximum=4), 10)
        self.assertEqual([len(files) for _, files in self.calls], [4, 4, 2])
        for command, files in self.calls:
            self.assertIn('-whole-module-optimization', command)
            self.assertIn('-strict-memory-safety', command)
            self.assertEqual(len({p for p, _ in files}), len(files))
            self.assertEqual(len({s for _, s in files}), len(files))

    def test_positive_companions_compile_separately(self):
        cases = [negative('a'), ('positive', 'func use() {}\n', None), negative('b'), negative('c')]
        self.assertEqual(self.run_cases(cases), 4)
        self.assertEqual([len(files) for _, files in self.calls], [1, 1, 2])
        self.assertNotIn('-whole-module-optimization', self.calls[1][0])

    def test_single_mode_uses_original_source_and_flags(self):
        cases = [negative('a'), negative('b')]
        self.run_cases(cases, maximum=1)
        self.assertEqual([files[0][1] for _, files in self.calls], [case[1] for case in cases])
        self.assertTrue(all('-whole-module-optimization' not in command for command, _ in self.calls))

    def test_suppressed_diagnostic_rechecks_every_original_client(self):
        def suppressed(command, **options):
            result = self.compiler(command, **options)
            if len(self.calls[-1][1]) > 1:
                result.stderr = result.stderr.splitlines(keepends=True)[0]
            return result
        cases = [negative('a'), negative('b')]
        self.assertEqual(self.run_cases(cases, compiler=suppressed), 2)
        self.assertEqual([len(files) for _, files in self.calls], [2, 1, 1])
        self.assertEqual([self.calls[i][1][0][1] for i in (1, 2)], [case[1] for case in cases])

    def test_another_error_cannot_hide_a_client_that_compiles(self):
        def weakened(command, **options):
            result = self.compiler(command, **options)
            result.stderr = ''.join(line for line in result.stderr.splitlines(keepends=True)
                                    if 'Probe0001.swift:' not in line)
            result.returncode = 1 if result.stderr else 0
            return result
        with self.assertRaisesRegex(batches.ProbeFailure, 'weakened'):
            self.run_cases([negative('intact'), negative('weakened')], compiler=weakened)

    def test_unrelated_or_wrong_location_failures_are_rejected(self):
        for defect in ('wrong file', 'wrong line', 'wrong category', 'warning', 'driver', 'signal', 'extra error'):
            with self.subTest(defect=defect):
                def invalid(command, **options):
                    result = self.compiler(command, **options)
                    if defect == 'wrong file':
                        result.stderr = result.stderr.replace('Probe0000.swift', 'Other.swift')
                    elif defect == 'wrong line':
                        result.stderr = result.stderr.replace(':1:1:', ':2:1:')
                    elif defect == 'wrong category':
                        result.stderr = result.stderr.replace('restriction holds', 'unknown type')
                    elif defect == 'warning':
                        result.stderr = result.stderr.replace('error:', 'warning:')
                    elif defect == 'driver':
                        result.stderr += 'error: compiler unavailable\n'
                    elif defect == 'signal':
                        result.returncode = -9
                    else:
                        result.stderr += str(self.directory/'Production.swift') + ':1:1: error: broken production\n'
                    return result
                with self.assertRaises(batches.ProbeFailure):
                    self.run_cases([negative('required')], compiler=invalid)

    def test_alternative_diagnostics_retain_exact_locations(self):
        name, source, _ = negative('alternatives')
        self.assertEqual(self.run_cases([(name, source, ('old spelling', 'restriction holds'))]), 1)

    def test_successful_exit_with_an_error_string_fails(self):
        def contradictory(command, **options):
            result = self.compiler(command, **options)
            result.returncode = 0
            return result
        with self.assertRaises(batches.ProbeFailure):
            self.run_cases([negative('required')], compiler=contradictory)

    def test_warning_or_nonzero_positive_result_fails(self):
        def failed(command, **options):
            return subprocess.CompletedProcess(command, 1, '', 'error: missing module\n')
        with self.assertRaises(batches.ProbeFailure):
            self.run_cases([('companion', 'func use() {}', None)], compiler=failed)

    def test_timeouts_keep_the_existing_watchdog(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            self.run_cases([negative('a'), negative('b')], compiler=lambda command, **options:
                           (_ for _ in ()).throw(subprocess.TimeoutExpired(command, options['timeout'])))

    def test_missing_markers_empty_families_and_duplicates_fail_discovery(self):
        for cases in ([], [('a', 'func wrong() {}', 'restriction')],
                      [negative('')], [('empty category', 'func wrong() {} // expected-error', '')],
                      [('empty alternatives', 'func wrong() {} // expected-error', ())],
                      [negative('same'), negative('same')],
                      [('twice', '// expected-error\n// expected-error', 'restriction')]):
            with self.subTest(cases=cases), self.assertRaises(ValueError):
                self.run_cases(cases)
        self.assertEqual(self.calls, [])

    def test_special_declaration_contexts_remain_isolated(self):
        special = negative('extension', 'let _ = denied()')
        special = special[0], 'extension Client {\n' + special[1] + '}\n', special[2]
        self.run_cases([negative('a'), special, negative('b')])
        self.assertEqual([len(files) for _, files in self.calls], [1, 1, 1])
        self.assertEqual(self.calls[1][1][0][1], special[1])

    def test_helper_hygiene_preserves_members_literals_comments_and_line_numbers(self):
        source = '''import Foundation
func take(_ value: Int) {}
func wrong(_ object: Object) {
    take(object.take()) // take is a helper; object.take is a member
    let string = "take(1)"; take(1) // expected-error
}
'''
        changed = batches.renamed_helpers(source, '__unique_')
        self.assertIn('func __unique_take', changed)
        self.assertIn('__unique_take(object.take())', changed)
        self.assertIn('"take(1)"; __unique_take(1)', changed)
        self.assertIn('// take is a helper', changed)
        self.assertEqual(source.count('\n'), changed.count('\n'))
        self.assertIsNone(batches.renamed_helpers('func take() {}\nlet value = take\n', '__unique_'))
        self.assertIsNone(batches.renamed_helpers('let state = 1\nfunc wrong() {}\n', '__unique_'))
        self.assertIsNone(batches.renamed_helpers('func take() {}\nfunc use() { _ = "\\(take())" }\n', '__unique_'))

    def test_batch_size_is_bounded(self):
        for size in (0, 17, -1):
            with self.assertRaises(ValueError):
                self.run_cases([negative('a')], maximum=size)


class SwiftBoundaryTests(unittest.TestCase):
    def test_real_swift_keeps_sibling_files_outside_both_issuer_boundaries(self):
        with tempfile.TemporaryDirectory(prefix='nv-probe-swift-') as temporary, redirect_stdout(io.StringIO()):
            root = Path(temporary)
            owner = root/'Owner.swift'
            owner.write_text('''public struct PrivatePermit {
    private init() {}
    public static func issue() -> Self { Self() }
}
public struct FilePermit {
    fileprivate init() {}
    public static func issue() -> Self { Self() }
}
''')
            flags = ['swiftc', '-swift-version', '6', '-strict-concurrency=complete',
                     '-strict-memory-safety', '-warnings-as-errors', '-module-cache-path', str(root/'cache')]
            emitted = subprocess.run(flags + ['-emit-module', '-module-name', 'BoundaryFixture',
                                     '-emit-module-path', str(root/'BoundaryFixture.swiftmodule'), str(owner)],
                                     capture_output=True, text=True, timeout=60)
            self.assertEqual(emitted.returncode, 0, emitted.stderr)
            for sibling in (False, True):
                command = flags + ['-typecheck', '-I', str(root)]
                if sibling:
                    command += ['-module-name', 'BoundaryFixture', str(owner)]
                prefix = '' if sibling else 'import BoundaryFixture\n'
                cases = [('positive', prefix + 'func use() { _ = PrivatePermit.issue(); _ = FilePermit.issue() }\n', None)]
                for name, access in [('PrivatePermit', 'private'), ('FilePermit', 'fileprivate')]:
                    cases.append((name, prefix + f'func wrong() {{ _ = {name}() }} // expected-error\n',
                                  f"'{name}' initializer is inaccessible due to '{access}' protection level"))
                self.assertEqual(batches.run_probes(command, cases, root/str(sibling), label='real', timeout=60), 3)
                # Weakening one actual issuer must fail even while the other
                # selected client's restriction continues to produce an error.
                if sibling:
                    owner.write_text(owner.read_text().replace('private init()', 'internal init()', 1))
                    with self.assertRaisesRegex(batches.ProbeFailure, 'PrivatePermit'):
                        batches.run_probes(command, cases, root/'weakened', label='real', timeout=60)


if __name__ == '__main__':
    available = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__]).countTestCases()
    if available != 15:
        raise SystemExit('Expected discovery of all 15 compiler-batch harness tests')
    program = unittest.main(exit=False)
    if program.result.testsRun < 1:
        raise SystemExit('A compiler-batch harness run must discover its selected tests')
    raise SystemExit(0 if program.result.wasSuccessful() else 1)
