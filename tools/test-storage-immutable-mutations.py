#!/usr/bin/env python3
"""Require isolated installer mutations to fail their designated independent predicate."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('immutable', ROOT/'tools/test-storage-immutable-files.py')
immutable = importlib.util.module_from_spec(spec); spec.loader.exec_module(immutable)
FILES = ['tests/RepositoryFilesIOProbe.c', 'NVStorage/Sources/CStorageIO/NVRepositoryRoot.c',
         'NVStorage/Sources/CStorageIO/NVRepositoryRootInternal.h', 'NVStorage/Sources/CStorageIO/NVRepositoryFiles.c',
         'NVStorage/Sources/CStorageIO/include/NVRepositoryRoot.h']


def main():
    artifacts = Path(tempfile.mkdtemp(prefix='nv-immutable-mutations-'))
    print('Artifacts:', artifacts, flush=True)
    baseline = artifacts/'baseline'; baseline.mkdir()
    binary = baseline/'installer'; immutable.compile_probe(binary)
    immutable.qualify(binary, baseline, cuts=False)
    source = (ROOT/'NVStorage/Sources/CStorageIO/NVRepositoryFiles.c').read_text()
    native = ('return renameatx_np(source, stage, destination, leaf, RENAME_EXCL);' if sys.platform == 'darwin'
              else 'return renameat2(source, stage, destination, leaf, RENAME_NOREPLACE);')
    partial = '''static int exclusive_rename(int source, const char *stage, int destination, const char *leaf) {
#if defined(__APPLE__)
    (void)renameatx_np;
#else
    (void)renameat2;
#endif
    int input = openat(source, stage, O_RDONLY | O_CLOEXEC);
    int output = openat(destination, leaf, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (input < 0 || output < 0) return -1;
    uint8_t bytes[4096]; ssize_t count;
    while ((count = pread(input, bytes, sizeof(bytes), 0)) > 0) {
        if (write(output, bytes, (size_t)count) != count) return -1;
        NV_REPOSITORY_EVENT("weak-partial-final", output);
        break;
    }
    close(input); close(output); return 0;
}

'''
    start = source.index('static int exclusive_rename(')
    end = source.index('/* Cleanup', start)
    cases = [
        ('staged-file-barrier', 'if (file_barrier(stagefd) || path_check(owner, &path)) goto failed;',
         'if (path_check(owner, &path)) goto failed;', 'Final visibility requires a completed staged-file barrier'),
        ('directory-barriers', 'do { barrier = fsync(path.fd[i-1]); } while (barrier && errno == EINTR);',
         'barrier = 0;', 'Installation evidence preceded required namespace/file barriers'),
        ('premature-evidence', 'finalfd = openat(path.fd[path.count-1], path.leaf, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);',
         'result->outcome = NV_ROOT_INSTALL_VERIFIED; goto done;', 'Installation evidence preceded required namespace/file barriers'),
        ('equal-final-shortcut', 'result->existing = 1;',
         'result->existing = 1; result->outcome = NV_ROOT_INSTALL_VERIFIED; goto done;', 'Equal-object shortcut omitted durability work'),
        ('mutable-overwrite', native, native.replace('RENAME_EXCL', '0').replace('RENAME_NOREPLACE', '0'),
         'Immutable retry must preserve an existing final'),
        ('visible-final-copy', source[start:end], partial, 'Independent final visibility observed partial bytes'),
        ('filename-cleanup',
         'if (!S_ISREG(named.st_mode) || named.st_dev != held->st_dev || named.st_ino != held->st_ino || named.st_nlink != 1) { errno = ESTALE; return -1; }',
         '(void)held;', 'Cleanup must preserve displaced foreign stage'),
    ]
    results = []
    for name, before, after, assertion in cases:
        assert source.count(before) == 1, (name, 'mutation source drift')
        package = artifacts/name
        for relative in FILES:
            target = package/relative; target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT/relative, target)
        (package/'NVStorage/Sources/CStorageIO/NVRepositoryFiles.c').write_text(source.replace(before, after, 1))
        binary = package/'installer'; immutable.compile_probe(binary, source=package)
        with (package/'result.log').open('w') as log:
            result = subprocess.run([sys.executable, str(ROOT/'tools/test-storage-immutable-files.py'),
                '--binary', str(binary), '--without-cuts', '--artifacts-parent', str(package)],
                stdout=log, stderr=subprocess.STDOUT, timeout=120)
        log = (package/'result.log').read_text()
        assert result.returncode != 0 and 'AssertionError' in log and assertion in log, (name, log)
        results.append({'mutation': name, 'classification': 'targeted independent predicate failure', 'assertion': assertion})
        print('PASS:', name, '→', assertion, flush=True)
    assert len(results) == 7
    (artifacts/'results.json').write_text(json.dumps(results, indent=2) + '\n')


if __name__ == '__main__': main()
