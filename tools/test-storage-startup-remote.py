#!/usr/bin/env python3
"""Run fresh-process startup checks remotely with the independent history decoder on this host."""
import argparse
import json
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True)
    parser.add_argument('--ssh-target', required=True)
    parser.add_argument('--ssh-key', type=Path, required=True)
    parser.add_argument('--probe-env', action='append', default=[])
    args = parser.parse_args()
    artifacts = Path(tempfile.mkdtemp(prefix='nv-startup-remote-'))
    print('Artifacts:', artifacts, flush=True)
    ssh = ['ssh', '-i', str(args.ssh_key), '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no',
           '-o', 'ConnectTimeout=10', args.ssh_target]
    remote = subprocess.run([*ssh, 'mktemp -d /tmp/nv-startup-process-runner.XXXXXX'],
                            capture_output=True, text=True, check=True, timeout=30).stdout.strip()
    assert remote.startswith('/tmp/nv-startup-process-runner.')
    script = remote+'/startup.py'
    subprocess.run(['scp', *ssh[1:-1], str(ROOT/'tools/test-storage-startup-process.py'),
                    args.ssh_target+':'+script], check=True, timeout=120, capture_output=True)
    command = ['python3', script, '--binary', args.binary, '--history-observer-stdio']
    for setting in args.probe_env:
        command += ['--probe-env', setting]
    observations, passes = 0, []
    with (artifacts/'remote.stderr').open('w') as errors, (artifacts/'remote.log').open('w') as log:
        process = subprocess.Popen([*ssh, shlex.join(command)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=errors, text=True)
        try:
            for line in process.stdout:
                if not line.startswith('{'):
                    print(line, end='', flush=True); log.write(line); log.flush()
                    if line.startswith('PASS:'): passes.append(line.strip())
                    continue
                request = json.loads(line)
                observations += 1
                assert set(request) == {'history_observer', 'report'} and request['history_observer'] == observations
                decoded = subprocess.run(['node', str(ROOT/'tools/inspect-storage-history.mjs')],
                    input=json.dumps(request['report']), capture_output=True, text=True, timeout=120)
                (artifacts/f'observer-{observations}.json').write_text(json.dumps(dict(
                    report=request['report'], code=decoded.returncode, stdout=decoded.stdout, stderr=decoded.stderr)))
                valid = decoded.returncode == 0 and bool(json.loads(decoded.stdout))
                process.stdin.write(json.dumps(dict(history_observer=observations, valid=valid))+'\n')
                process.stdin.flush()
                assert valid, (observations, decoded.stderr)
            assert process.wait(timeout=30) == 0, artifacts/'remote.stderr'
        finally:
            process.stdin.close()
            if process.poll() is None: process.terminate(); process.wait(timeout=30)
    assert observations >= 18 and len(passes) == 19 and passes[-1].startswith('PASS: 18 fresh-process'), passes
    (artifacts/'results.json').write_text(json.dumps(dict(host=args.ssh_target, binary=args.binary,
        observer_requests=observations, schedules=18, remote_runner=remote, probe_env=args.probe_env), indent=2))
    print('PASS: independent local decoder qualified all 18 remote fresh-process schedules', flush=True)


if __name__ == '__main__': main()
