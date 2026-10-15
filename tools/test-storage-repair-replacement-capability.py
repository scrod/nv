#!/usr/bin/env python3
"""Measure Foundation preservation separately from repair's no-write mismatch requirement."""
import json
from pathlib import Path
import platform
import subprocess
import tempfile


def main():
    if platform.system() != 'Darwin':
        raise SystemExit('This Foundation capability probe requires macOS; other platforms remain unqualified.')
    project = Path(__file__).resolve().parents[1]
    artifacts = Path(tempfile.mkdtemp(prefix='nv-repair-replacement-'))
    binary = artifacts/'probe'
    subprocess.run(['xcrun', 'clang', '-Wall', '-Wextra', '-Werror', '-fno-objc-arc', '-fblocks',
                    '-fsanitize=address,undefined', '-framework', 'Foundation',
                    str(project/'tests/RepositoryRepairReplacementProbe.m'), '-o', str(binary)], check=True)
    cases = [
        ('file-baseline', 'file', 'none'),
        ('file-concurrent-replacement', 'file', 'replace'),
        ('directory-baseline', 'directory', 'none'),
        ('directory-concurrent-replacement', 'directory', 'replace'),
        ('directory-concurrent-child-edit', 'directory', 'child'),
    ]
    rows = []
    for name, kind, race in cases:
        case = artifacts/name
        case.mkdir()
        run = subprocess.run([str(binary), str(case), kind, race], check=True, capture_output=True, text=True, timeout=30)
        assert not run.stderr, run.stderr
        result = json.loads(run.stdout)
        assert result['coordinated'] and result['checkedOld'], result
        assert result['apiSucceeded'] and result['current'] == 'replacement', result
        assert result['backup'] == ('old' if race == 'none' else 'concurrent'), result
        assert result['noWriteMismatch'] == (race == 'none'), result
        rows.append(result)
        print(json.dumps(result, sort_keys=True), flush=True)
    print('Observed limitation: preservation succeeds, but replacement cannot enforce an expected-generation condition against an uncoordinated writer.', flush=True)
    print('Artifacts:', artifacts, flush=True)
    assert len(rows) == 5


if __name__ == '__main__':
    main()
