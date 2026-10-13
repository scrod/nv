"""Campaign-scoped reuse of exact native builds and independent check evidence."""
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import stat
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CAMPAIGN_ENV = 'NV_STORAGE_QUALIFICATION_REUSE'
FORMAT = 1


def digest(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


def input_files(paths, work=None):
    """Bind file contents, names and complete directory membership to a job."""
    result = {}
    for original in paths:
        path = Path(original).absolute()
        files = sorted(p for p in path.rglob('*') if p.is_file()) if path.is_dir() else [path]
        # An empty or newly removed directory still changes the input inventory.
        result[normalize(str(path), work)] = 'directory' if path.is_dir() else 'file'
        for file in files:
            if '__pycache__' in file.parts:
                continue
            result[normalize(str(file), work)] = digest(file)
    return result


def normalize(value, work):
    return value.replace(str(Path(work).absolute()), '<work>') if work else value


def tool_context(tools):
    """Capture the actual executables, platform and selected SDK for this job."""
    context = {'platform': platform.platform(), 'machine': platform.machine(), 'tools': {}}
    for tool in sorted(set([sys.executable, *tools])):
        executable = shutil.which(tool)
        if executable is None:
            raise FileNotFoundError(tool)
        invocation = Path(os.path.abspath(executable))
        if (sys.platform == 'darwin' and Path('/usr/bin') in {invocation.parent, invocation.resolve().parent}
                and invocation.name in {'clang', 'clang++', 'swift', 'swiftc'}):
            executable = subprocess.check_output(['xcrun', '--find', invocation.name], text=True).strip()
        path = Path(executable).resolve()
        context['tools'][tool] = {'path': str(path), 'sha256': digest(path)}
    if sys.platform == 'darwin':
        sdk = Path(subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip())
        context['sdk'] = {'path': str(sdk), 'settings': input_files(
            [p for p in (sdk/'SDKSettings.json', sdk/'SDKSettings.plist') if p.is_file()])}
    environment = {k: v for k, v in os.environ.items() if k not in {CAMPAIGN_ENV, '_', 'SHLVL'}}
    context['environment_sha256'] = hashlib.sha256(encoded(environment)).hexdigest()
    return context


def fingerprint(command, inputs, tools, work=None):
    value = {'format': FORMAT, 'command': [normalize(str(x), work) for x in command],
             'inputs': input_files([Path(__file__), *inputs], work), 'context': tool_context(tools)}
    return hashlib.sha256(encoded(value)).hexdigest(), value


def atomic_write(path, contents):
    """Publish a complete cache record after its evidence is installed."""
    descriptor, temporary = tempfile.mkstemp(prefix=path.name+'.', dir=path.parent)
    with os.fdopen(descriptor, 'wb') as output:
        output.write(contents)
    os.replace(temporary, path)


class CampaignReuse:
    """Reuse successful evidence within an explicitly owned qualification campaign."""

    def __init__(self, directory=None):
        selected = directory or os.environ.get(CAMPAIGN_ENV)
        self.directory = Path(selected).resolve() if selected else None
        if self.directory:
            self.directory.mkdir(parents=True, exist_ok=True)

    @contextmanager
    def entry(self, kind, key):
        path = self.directory/kind/key
        path.mkdir(parents=True, exist_ok=True)
        with (path/'lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            yield path

    @staticmethod
    def available(path, key, kind):
        try:
            record = json.loads((path/'record.json').read_text())
            return (record['format'] == FORMAT and record['key'] == key and record['kind'] == kind
                    and record['returncode'] == 0 and record['sha256'] == digest(path/'payload')
                    and record['mode'] == stat.S_IMODE((path/'payload').stat().st_mode))
        except (OSError, ValueError, KeyError, TypeError):
            return False

    @staticmethod
    def save(path, key, kind, evidence, description):
        temporary = path/'payload.next'
        expected = digest(evidence)
        mode = stat.S_IMODE(Path(evidence).stat().st_mode)
        shutil.copy2(evidence, temporary)
        if digest(temporary) != expected or stat.S_IMODE(temporary.stat().st_mode) != mode:
            raise RuntimeError('Qualification evidence changed during publication')
        os.replace(temporary, path/'payload')
        atomic_write(path/'record.json', encoded({'format': FORMAT, 'key': key, 'kind': kind,
            'returncode': 0, 'sha256': expected, 'mode': mode, 'description': description}))

    @staticmethod
    def restore(path, output):
        """Check the installed copy against the exact producer's evidence."""
        record = json.loads((path/'record.json').read_text())
        shutil.copy2(path/'payload', output)
        if (digest(output) != record['sha256']
                or stat.S_IMODE(Path(output).stat().st_mode) != record['mode']):
            raise RuntimeError('Qualification evidence changed during installation')

    def check(self, command, inputs, tools, log, execute):
        """Replay a verified independent check log, or execute and record the check."""
        if self.directory is None:
            execute()
            return {'reused': False}
        key, description = fingerprint(command, inputs, tools)
        with self.entry('checks', key) as path:
            if self.available(path, key, 'check'):
                self.restore(path, log)
                if fingerprint(command, inputs, tools)[0] != key:
                    raise RuntimeError('Qualification inputs changed while reusing independent evidence')
                return {'reused': True, 'key': key, 'evidence': str(path/'record.json')}
            execute()
            if fingerprint(command, inputs, tools)[0] != key:
                raise RuntimeError('Qualification inputs changed during an independent check')
            self.save(path, key, 'check', log, description)
            return {'reused': False, 'key': key, 'evidence': str(path/'record.json')}

    def build(self, command, inputs, output, work, tools=('clang',)):
        """Install the exact compiled artifact while callers rerun their scenarios."""
        if self.directory is None:
            subprocess.run(command, check=True)
            return False
        key, description = fingerprint(command, inputs, tools, work)
        with self.entry('builds', key) as path:
            if self.available(path, key, 'build'):
                self.restore(path, output)
                if fingerprint(command, inputs, tools, work)[0] != key:
                    raise RuntimeError('Qualification inputs changed while reusing a native build')
                print('REUSE: native build', key[:12], flush=True)
                return True
            subprocess.run(command, check=True)
            if fingerprint(command, inputs, tools, work)[0] != key:
                raise RuntimeError('Qualification inputs changed during a native build')
            self.save(path, key, 'build', output, description)
            return False


def link_if_changed(command, manifest, output):
    """Relink an integration executable when its inputs or installed bytes change."""
    output = Path(output)
    inputs = [Path(manifest), ROOT/'tools/link-integration-test.py', *(Path(x) for x in command[1:]
                               if x != str(output) and Path(x).is_file())]
    key, description = fingerprint(command, inputs, [command[0]])
    record = output.with_name(output.name+'.link.json')
    try:
        previous = json.loads(record.read_text())
        if (previous['key'] == key and previous['sha256'] == digest(output)
                and previous['mode'] == stat.S_IMODE(output.stat().st_mode) and os.access(output, os.X_OK)):
            print('REUSE: integration executable', output.name, flush=True)
            return
    except (OSError, ValueError, KeyError, TypeError):
        pass
    subprocess.run(command, check=True)
    if fingerprint(command, inputs, [command[0]])[0] != key:
        raise RuntimeError('Integration link inputs changed during compilation')
    atomic_write(record, encoded({'key': key, 'sha256': digest(output),
                                 'mode': stat.S_IMODE(output.stat().st_mode), 'description': description}))


def compiler_cache_path(swiftc, modules, temporary):
    """Share compiler-managed module variants across isolated construction probes."""
    campaign = CampaignReuse()
    if campaign.directory is None:
        return str(temporary)
    modules = Path(modules).resolve()
    inputs = [modules, ROOT/'NVStorage/Sources', ROOT/'NVStorage/Vendor', ROOT/'NVStorage/Package.swift',
              ROOT/'NVStorage/.deps/sqlcipher/include', *sorted(modules.parent.glob('*.build/module.modulemap'))]
    # Compiler-managed variant keys separate each probe's additional options.
    key, description = fingerprint([swiftc, '-swift-version', '6', '-strict-concurrency=complete',
        '-strict-memory-safety', '-warnings-as-errors', '-I', str(modules)], inputs, [swiftc])
    path = campaign.directory/'compiler'/key
    path.mkdir(parents=True, exist_ok=True)
    atomic_write(path/'context.json', encoded(description))
    print('Compiler cache:', path, flush=True)
    return str(path)
