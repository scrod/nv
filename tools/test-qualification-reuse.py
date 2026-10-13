#!/usr/bin/env python3
"""Challenge campaign evidence, native artifact reuse and actual Make dependencies."""
import json
from concurrent.futures import ThreadPoolExecutor
import fcntl
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
import qualification_reuse as reuse
REAL_TOOL_CONTEXT = reuse.tool_context


class ReuseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='nv-qualification-tests-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.campaign = reuse.CampaignReuse(self.root/'campaign')
        self.source = self.root/'input'; self.source.write_bytes(b'input')
        self.log = self.root/'job.log'
        self.calls = 0
        self.context = {'compiler': 'qualified', 'sdk': 'test', 'architecture': 'test'}
        self.context_patch = patch.object(reuse, 'tool_context', side_effect=lambda tools: dict(self.context))
        self.context_patch.start(); self.addCleanup(self.context_patch.stop)

    def execute(self):
        self.calls += 1
        self.log.write_text('PASS: independently checked exact inputs\n')

    def check(self, command=('independent',), inputs=None, execute=None):
        return self.campaign.check(command, inputs or [self.source], [], self.log, execute or self.execute)

    def test_exact_success_reuses_verified_log(self):
        first = self.check()
        second = self.check()
        self.assertFalse(first['reused']); self.assertTrue(second['reused'])
        self.assertEqual(self.calls, 1)
        self.assertEqual(first['key'], second['key'])
        self.assertIn('independently checked', self.log.read_text())

    def test_changed_bytes_with_preserved_timestamps_are_rechecked(self):
        self.check(); original = self.source.stat()
        self.source.write_bytes(b'other')
        os.utime(self.source, ns=(original.st_atime_ns, original.st_mtime_ns))
        self.assertFalse(self.check()['reused']); self.assertEqual(self.calls, 2)

    def test_directory_membership_and_transitive_inputs_are_bound(self):
        directory = self.root/'headers'; directory.mkdir()
        self.check(inputs=[directory]); self.check(inputs=[directory])
        header = directory/'nested.h'; header.write_text('first')
        self.assertFalse(self.check(inputs=[directory])['reused'])
        header.write_text('second')
        self.assertFalse(self.check(inputs=[directory])['reused'])
        self.assertEqual(self.calls, 3)

    def test_command_toolchain_and_profile_variants_are_separate(self):
        self.check(); self.check(command=('independent', '--sanitize=address'))
        for field in ('compiler', 'sdk', 'architecture'):
            self.context[field] += '-changed'
            self.assertFalse(self.check()['reused'])
        self.assertEqual(self.calls, 5)
        compiler, sdk = self.root/'selected-clang', self.root/'sdk'
        compiler.write_bytes(b'compiler A'); sdk.mkdir()
        (sdk/'SDKSettings.json').write_text('{}')
        which = shutil.which
        check_output = reuse.subprocess.check_output
        shim = '/usr/bin/clang'
        def find_tool(tool):
            return shim if tool == 'clang' else which(tool)
        def xcrun(command, **options):
            if command[0] == 'xcrun':
                return str(compiler if command[1] == '--find' else sdk)+'\n'
            return check_output(command, **options)
        with patch.object(reuse.sys, 'platform', 'darwin'), patch.object(reuse.shutil, 'which', side_effect=find_tool), \
                patch.object(reuse.subprocess, 'check_output', side_effect=xcrun):
            first = REAL_TOOL_CONTEXT(['clang'])
            self.assertEqual(first['tools']['clang']['path'], str(compiler.resolve()))
            compiler.write_bytes(b'compiler B')
            self.assertNotEqual(first['tools']['clang']['sha256'], REAL_TOOL_CONTEXT(['clang'])['tools']['clang']['sha256'])
            shim = '/usr/bin/../bin/clang'
            self.assertEqual(REAL_TOOL_CONTEXT(['clang'])['tools']['clang']['path'], str(compiler.resolve()))

    def test_failed_or_interrupted_checks_leave_no_success_receipt(self):
        def fail():
            self.calls += 1; self.log.write_text('failed')
            raise RuntimeError('precise failing check')
        for _ in range(2):
            with self.assertRaisesRegex(RuntimeError, 'precise failing check'):
                self.check(execute=fail)
        self.assertEqual(list(self.campaign.directory.rglob('record.json')), [])
        self.assertFalse(self.check()['reused']); self.assertEqual(self.calls, 3)

    def test_corrupt_log_and_incomplete_receipt_force_real_check(self):
        result = self.check(); record = Path(result['evidence'])
        (record.parent/'payload').write_text('forged success')
        self.assertFalse(self.check()['reused'])
        record.write_text('{')
        self.assertFalse(self.check()['reused'])
        record.write_text(json.dumps({'format': 1, 'returncode': 0}))
        self.assertFalse(self.check()['reused']); self.assertEqual(self.calls, 4)

    def test_source_change_during_check_cannot_issue_evidence(self):
        def changed():
            self.execute(); self.source.write_bytes(b'changed during execution')
        with self.assertRaisesRegex(RuntimeError, 'inputs changed'):
            self.check(execute=changed)
        self.assertEqual(list(self.campaign.directory.rglob('record.json')), [])
        self.assertFalse(self.check()['reused'])

    def test_failure_publishing_evidence_requires_a_new_check(self):
        with patch.object(reuse, 'atomic_write', side_effect=OSError('ENOSPC')):
            with self.assertRaisesRegex(OSError, 'ENOSPC'):
                self.check()
        self.assertEqual(list(self.campaign.directory.rglob('record.json')), [])
        self.assertFalse(self.check()['reused']); self.assertEqual(self.calls, 2)
        copy = shutil.copy2
        def damaged_copy(origin, destination):
            result = copy(origin, destination)
            Path(destination).write_bytes(b'wrong published evidence')
            return result
        with patch.object(reuse.shutil, 'copy2', side_effect=damaged_copy):
            with self.assertRaisesRegex(RuntimeError, 'evidence changed during publication'):
                self.check(command=('different-check',))
        self.assertEqual(len(list(self.campaign.directory.rglob('record.json'))), 1)
        self.assertTrue(self.check()['reused']); self.assertEqual(self.calls, 3)

    def test_cache_hit_rechecks_inputs_before_issuing_success(self):
        self.check()
        copy = shutil.copy2
        def changed(source, target):
            result = copy(source, target)
            self.source.write_bytes(b'changed while reading evidence')
            return result
        with patch.object(reuse.shutil, 'copy2', side_effect=changed):
            with self.assertRaisesRegex(RuntimeError, 'inputs changed while reusing'):
                self.check()
        self.assertFalse(self.check()['reused'])

    def test_concurrent_producers_share_one_complete_success(self):
        entered, release = threading.Event(), threading.Event()
        def held():
            self.execute(); entered.set()
            if not release.wait(10):
                raise RuntimeError('The producer was never released')
        with ThreadPoolExecutor(max_workers=2) as workers:
            first = workers.submit(self.check, execute=held)
            try:
                self.assertTrue(entered.wait(10))
                lock = next(self.campaign.directory.glob('checks/*/lock'))
                with lock.open('a') as competing:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(competing, fcntl.LOCK_EX | fcntl.LOCK_NB)
                second = workers.submit(self.check)
            finally:
                release.set()
            self.assertFalse(first.result(timeout=10)['reused'])
            self.assertTrue(second.result(timeout=10)['reused'])
        self.assertEqual(self.calls, 1)

    def test_native_artifact_reused_but_scenarios_execute_fresh(self):
        producer = 'import pathlib,sys; pathlib.Path(sys.argv[2]).write_bytes(pathlib.Path(sys.argv[1]).read_bytes())'
        observed = []
        for index in range(2):
            work = self.root/str(index); work.mkdir()
            source, output = work/'generated.c', work/'binary'
            source.write_bytes(b'exact compiled artifact')
            command = [sys.executable, '-c', producer, str(source), str(output)]
            hit = self.campaign.build(command, [source], output, work, tools=[sys.executable])
            self.assertEqual(hit, index == 1)
            observed.append(output.read_bytes())
        self.assertEqual(observed, [b'exact compiled artifact']*2)
        payload = next((self.campaign.directory/'builds').glob('*/payload'))
        payload.write_bytes(b'corrupt compiled artifact')
        self.assertFalse(self.campaign.build(command, [source], output, work, tools=[sys.executable]))
        self.assertEqual(output.read_bytes(), b'exact compiled artifact')
        payload.chmod(0o600)
        self.assertFalse(self.campaign.build(command, [source], output, work, tools=[sys.executable]))
        copy = shutil.copy2
        def damaged_copy(origin, destination):
            result = copy(origin, destination)
            Path(destination).write_bytes(b'wrong installed artifact')
            return result
        with patch.object(reuse.shutil, 'copy2', side_effect=damaged_copy):
            with self.assertRaisesRegex(RuntimeError, 'evidence changed during installation'):
                self.campaign.build(command, [source], output, work, tools=[sys.executable])

    def test_compiler_cache_shares_modules_with_isolated_probe_sources(self):
        project = self.root/'project'
        for directory in ('NVStorage/Sources', 'NVStorage/Vendor', 'NVStorage/.deps/sqlcipher/include',
                          'CStorageIO.build', 'modules', 'first', 'second'):
            (project/directory).mkdir(parents=True)
        (project/'NVStorage/Package.swift').write_text('package')
        (project/'modules/Runtime.swiftmodule').write_bytes(b'checked module')
        with patch.object(reuse, 'ROOT', project), patch.dict(os.environ, {reuse.CAMPAIGN_ENV: str(self.campaign.directory)}):
            first = reuse.compiler_cache_path('swiftc', project/'modules', project/'first')
            second = reuse.compiler_cache_path('swiftc', project/'modules', project/'second')
            self.assertEqual(first, second)
            (project/'modules/Runtime.swiftmodule').write_bytes(b'new module')
            self.assertNotEqual(first, reuse.compiler_cache_path('swiftc', project/'modules', project/'first'))
            self.context['compiler'] = 'different compiler'
            self.assertNotEqual(first, reuse.compiler_cache_path('swiftc', project/'modules', project/'first'))
            current = reuse.compiler_cache_path('swiftc', project/'modules', project/'first')
            (project/'NVStorage/Vendor/interface.h').write_text('new transitive header')
            self.assertNotEqual(current, reuse.compiler_cache_path('swiftc', project/'modules', project/'first'))
            current = reuse.compiler_cache_path('swiftc', project/'modules', project/'first')
            (project/'CStorageIO.build/module.modulemap').write_text('changed generated map')
            self.assertNotEqual(current, reuse.compiler_cache_path('swiftc', project/'modules', project/'first'))


class IntegrationLinkTests(unittest.TestCase):
    def test_actual_makefile_relinks_only_changed_inputs_and_propagates_failure(self):
        with tempfile.TemporaryDirectory(prefix='nv-integration-build-tests-') as temporary:
            root = Path(temporary)
            for folder in ('tools', 'tests', 'objects'):
                (root/folder).mkdir()
            for file in ('qualification_reuse.py', 'update-integration-build-manifest.py', 'link-integration-test.py'):
                shutil.copy2(reuse.ROOT/'tools'/file, root/'tools'/file)
            shutil.copy2(reuse.ROOT/'tests/Makefile', root/'tests/Makefile')
            for file in ('GlobalPrefsArchiveMigrationTest.m', 'AppearanceColorTest.m', 'ICloudAPIContractTest.m',
                         'ICloudRootLockProbe.h', 'ICloudMetadataProbe.h', 'ModernStickiesImportTest.m',
                         'WebArchiveImportIntegrationTest.m', 'NVIntegrationTest.m', 'NVRootedDirectoryTestHooks.m',
                         'NVRootedDirectoryTestHooks.h'):
                (root/'tests'/file).write_text('fixture')
            for file in ('Info.plist', 'NVRootedDirectory.m', 'NVRootedDirectory.h', 'NVRootedDirectory_Private.h'):
                (root/file).write_text('fixture')
            obj = root/'objects/NoteObject.o'; obj.write_bytes(b'first object')
            compiler, xcode, events = root/'compiler', root/'xcode', root/'events'
            compiler.write_text('#!'+sys.executable+'\nimport pathlib,sys\n'
                +f'with pathlib.Path({str(events)!r}).open("a") as log: log.write("link\\n")\n'
                +'output = pathlib.Path(sys.argv[sys.argv.index("-o")+1])\n'
                +'output.write_bytes(b"executable"); output.chmod(0o755)\n')
            xcode.write_text('#!'+sys.executable+'\nimport os,pathlib,sys\n'
                +f'with pathlib.Path({str(events)!r}).open("a") as log: log.write("xcode\\n")\n'
                +'sys.exit(int(os.environ.get("NV_TEST_BUILD_FAILURE", "0")))\n')
            compiler.chmod(0o755); xcode.chmod(0o755)
            command = ['make', '-j4', '-C', str(root/'tests'), 'all', 'BUILD_DIR='+str(root/'built'),
                'APP_OBJECT_DIR='+str(root/'objects'), 'CLANG='+str(compiler), 'XCODEBUILD='+str(xcode)]

            def run(extra=(), failure=False):
                before = events.read_text().splitlines() if events.exists() else []
                result = subprocess.run([*command, *extra], capture_output=True, text=True,
                    env=dict(os.environ, NV_TEST_BUILD_FAILURE='1' if failure else '0'), timeout=30)
                after = events.read_text().splitlines()[len(before):]
                self.assertEqual(result.returncode != 0, failure, result.stdout+result.stderr)
                self.assertEqual(after.count('xcode'), 1, after)
                return after.count('link')

            self.assertEqual(run(), 6)
            self.assertEqual(run(), 0)
            original = obj.stat()
            obj.write_bytes(b'changed object')
            os.utime(obj, ns=(original.st_atime_ns, original.st_mtime_ns))
            self.assertEqual(run(), 5)
            (root/'objects/AddedObject.o').write_bytes(b'added object')
            self.assertEqual(run(), 5)
            (root/'objects/AddedObject.o').rename(root/'ArchivedObject.o')
            self.assertEqual(run(), 5)
            (root/'NVRootedDirectory.h').write_text('changed header')
            self.assertEqual(run(), 5)
            nested = root/'ExternalEditingSession'; nested.mkdir()
            header = nested/'ExternalEditingSession.h'; header.write_text('nested header')
            self.assertEqual(run(), 5)
            original = header.stat(); header.write_text('changed nested header')
            os.utime(header, ns=(original.st_atime_ns, original.st_mtime_ns))
            self.assertEqual(run(), 5)
            self.assertEqual(run(extra=('CFLAGS=-DNEW_LINK_CONTEXT',)), 5)
            self.assertEqual(run(extra=('CFLAGS=-DNEW_LINK_CONTEXT',)), 0)
            (root/'built/NVIntegrationTest').write_bytes(b'damaged executable')
            self.assertEqual(run(extra=('CFLAGS=-DNEW_LINK_CONTEXT',)), 1)
            (root/'built/NVIntegrationTest').chmod(0o644)
            self.assertEqual(run(extra=('CFLAGS=-DNEW_LINK_CONTEXT',)), 1)
            self.assertEqual(run(extra=('CFLAGS=-DNEW_LINK_CONTEXT',), failure=True), 0)


if __name__ == '__main__':
    if len(sys.argv) == 1:
        count = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__]).countTestCases()
        if count != 13:
            raise RuntimeError(f'The complete reuse campaign requires 13 witnesses; discovered {count}')
    unittest.main()
