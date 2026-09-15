#!/usr/bin/env python3
"""Challenge zstd acceptance guards in an isolated package, requiring exact assertion failures."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('mutation_helpers', ROOT/'tools/test-bootstrap-mutations.py')
helpers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helpers)
CODEC = 'Sources/NVStorageCore/ZstdFrameV1.swift'
ENVELOPE = 'Sources/NVStorageCore/ObjectEnvelopeV1.swift'
TEST = 'Tests/NVStorageCoreTests/ObjectEnvelopeTests.swift'
MUTATIONS = [
    ('accept-empty-second-frame', CODEC, 'frameSize == input.count', 'frameSize <= input.count',
     'authenticatedZstdProfileChecks', 'try ObjectEnvelopeV1.open(validAuthentication,'),
    ('accept-dictionary-id-field', CODEC, 'bytes[4] & 0x1b == 0', 'bytes[4] & 0x18 == 0',
     'zstdProviderProfileRejectsOtherFrames', '#expect(throws: CanonicalEncodingError.invalidPayload) { try ZstdFrameV1.expand(bytes, count: count) }'),
    ('accept-unknown-content-size', CODEC,
     'ZSTD_getFrameContentSize(input.baseAddress, input.count) == UInt64(count)', 'true',
     'authenticatedZstdProfileChecks', 'try ObjectEnvelopeV1.open(validAuthentication,'),
    ('accept-oversized-window', CODEC,
     '''            guard exponent <= 26 else { throw CanonicalEncodingError.invalidPayload }
            let base = UInt64(1) << exponent
            let window = base + (base >> 3) * UInt64(bytes[5] & 7)
            guard window <= ObjectLimitsV1.decodedPayloadBytes else { throw CanonicalEncodingError.invalidPayload }''',
     '''            guard exponent <= 27 else { throw CanonicalEncodingError.invalidPayload }
            let base = UInt64(1) << exponent
            let window = base + (base >> 3) * UInt64(bytes[5] & 7)
            guard window <= 2 * ObjectLimitsV1.decodedPayloadBytes else { throw CanonicalEncodingError.invalidPayload }''',
     'zstdProviderProfileRejectsOtherFrames', '#expect(throws: CanonicalEncodingError.invalidPayload) { try ZstdFrameV1.expand(bytes, count: count) }'),
    ('decompress-before-authentication', ENVELOPE,
     '        switch protection {\n        case .publicHash:\n            guard try cursor.fixedBytes(32)',
     '''        switch protection {
        case .publicHash:
            if compression == .zstd { _ = try ZstdFrameV1.expand(encoded, count: Int(plainLength)) }
            guard try cursor.fixedBytes(32)''',
     'authenticatedZstdProfileChecks', 'try ObjectEnvelopeV1.open(badAuthentication,')
]
REQUIRED = {'zstdProviderProfileRejectsOtherFrames', 'authenticatedZstdProfileChecks', 'independentEnvelopeFixtures'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--configuration', choices=['debug', 'release'], default='debug')
    args = parser.parse_args()
    artifacts = Path(tempfile.mkdtemp(prefix='nv-zstd-mutations-'))
    package = artifacts/'NVStorage'
    print('Artifacts:', artifacts, flush=True)
    shutil.copytree(ROOT/'NVStorage', package, ignore=shutil.ignore_patterns('.build*', '.deps', '.swiftpm'))
    for folder in ['checkouts', 'repositories']:
        shutil.copytree(ROOT/'NVStorage/.build'/folder, package/'.build'/folder)
    os.environ['PKG_CONFIG_PATH'] = str(ROOT/'NVStorage/.deps/sqlcipher/lib/pkgconfig') + os.pathsep + os.environ.get('PKG_CONFIG_PATH', '')
    command = ['swift','test','--build-system','native','--package-path',str(package),'-c',args.configuration,'--filter','|'.join(sorted(REQUIRED))]
    test = (package/TEST).read_text()
    results = []
    def run(name):
        with (artifacts/(name+'.log')).open('w') as out:
            result = subprocess.run(command, stdout=out, stderr=subprocess.STDOUT, timeout=600)
        log = (artifacts/(name+'.log')).read_text()
        assert 'Build complete!' in log and REQUIRED.issubset(helpers.discovered(log)), 'Build/discovery failure'
        return result.returncode, log
    code, _ = run('baseline')
    assert code == 0, 'Invalid baseline'
    for name, file, before, after, function, assertion in MUTATIONS:
        path = package/file; original = path.read_text()
        changed = helpers.replace_once(original, before, after)
        # The open call is the line after the #expect in these multiline assertions.
        line = helpers.assertion_line(test, function, assertion)
        if assertion.startswith('try ObjectEnvelope'): line -= 1
        path.write_text(changed)
        try: code, log = run(name)
        finally: path.write_text(original)
        passed = code != 0 and any(f'Test {function}(' in s and 'recorded an issue' in s and
            f' at ObjectEnvelopeTests.swift:{line}:' in s and 'Expectation failed:' in s for s in log.splitlines())
        results.append({'name':name,'targeted_failure':passed,'returncode':code,'assertion_line':line,
                        'file':file,'original':before,'replacement':after})
        (artifacts/'results.json').write_text(json.dumps({'command':command,'results':results},indent=2))
        print(name+': '+('targeted rejection failure' if passed else 'FAIL'),flush=True)
        assert passed, 'Mutation survived or failed for an unrelated reason'


if __name__ == '__main__':
    main()
