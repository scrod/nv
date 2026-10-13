"""Compile independent boundary clients together and account for each diagnostic."""
from dataclasses import dataclass
from pathlib import Path
import re
import subprocess
import time


@dataclass(frozen=True)
class Probe:
    name: str
    source: str
    expected: str | tuple[str, ...] | None

    def marked_line(self):
        alternatives = (self.expected,) if isinstance(self.expected, str) else self.expected
        if not isinstance(alternatives, tuple) or not alternatives or any(not isinstance(x, str) or not x for x in alternatives):
            raise ValueError(f'{self.name}: a negative probe requires nonempty diagnostic alternatives')
        lines = [n for n, line in enumerate(self.source.splitlines(), 1)
                 if '// expected-error' in line]
        if len(lines) != 1:
            raise ValueError(f'{self.name}: a negative probe requires one marked line')
        return lines[0]


class ProbeFailure(AssertionError):
    """A client failed its exact source-location and diagnostic contract."""


def batch_size(value):
    size = int(value)
    if not 1 <= size <= 16:
        raise ValueError('Compiler probe batch size must be between 1 and 16')
    return size


def renamed_helpers(source, prefix):
    """Give simple top-level test functions distinct names within a shared module."""
    # Richer declaration contexts keep their original isolated compilation.
    if re.search(r'\b(?:extension|struct|class|actor|enum|protocol|typealias)\b|#|`|"""|/\*|\\\(', source):
        return None
    names = set(re.findall(r'^func ([A-Za-z_]\w*)\b', source, re.MULTILINE))
    if not names:
        return None
    tokens = list(re.finditer(r'"(?:\\.|[^"\\])*"|//[^\n]*|[A-Za-z_]\w*|[^\s]', source))
    significant = [t for t in tokens if not t[0].startswith(('"', '//'))]
    replacements = []
    depth = 0
    for i, token in enumerate(significant):
        if depth == 0 and token[0] in ('let', 'var'):
            return None
        if token[0] == '{':
            depth += 1
        elif token[0] == '}':
            depth -= 1
        if token[0] not in names:
            continue
        previous = significant[i - 1][0] if i else None
        following = significant[i + 1][0] if i + 1 < len(significant) else None
        if previous == '.':
            continue
        if previous != 'func' and following not in ('(', '<'):
            return None
        replacements.append((token.start(), token.end(), prefix + token[0]))
    result = source
    for start, end, replacement in reversed(replacements):
        result = result[:start] + replacement + result[end:]
    return result


DIAGNOSTIC = re.compile(r'^(.*?):(\d+):(\d+): (error|warning): ([^\n]*)$', re.MULTILINE)


def satisfies(result, selected):
    """Require an individual expected error for every selected negative client."""
    if result.returncode < 0:
        return False
    text = result.stdout + result.stderr
    diagnostics = list(DIAGNOSTIC.finditer(text))
    located = {d[0] for d in diagnostics}
    # Driver/setup failures have their own unlocated diagnostics.
    for line in text.splitlines():
        if re.search(r'^(?:[^\n]*: )?(?:error|warning|fatal error): ', line) and line not in located:
            return False
    if all(probe.expected is None for probe, _ in selected):
        return result.returncode == 0 and not diagnostics
    if result.returncode == 0:
        return False
    expected_locations = {(str(path), probe.marked_line()): probe for probe, path in selected}
    matched = set()
    for diagnostic in diagnostics:
        path, line, _, severity, message = diagnostic.groups()
        location = (path, int(line))
        probe = expected_locations.get(location)
        if probe is None or severity != 'error':
            return False
        alternatives = probe.expected if isinstance(probe.expected, tuple) else (probe.expected,)
        if any(expected in message for expected in alternatives):
            matched.add(location)
    return matched == set(expected_locations)


def run_probes(command, cases, directory, *, label, timeout, maximum=8):
    """Preserve each client's file and lexical scope while sharing type-checking work."""
    maximum = batch_size(maximum)
    probes = [Probe(*case) for case in cases]
    if not probes or any(not isinstance(p.name, str) or not p.name for p in probes) or len({p.name for p in probes}) != len(probes):
        raise ValueError('A probe family requires distinct, nonempty case names')
    for probe in probes:
        if probe.expected is not None:
            probe.marked_line()
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    started = time.perf_counter()
    calls = fallbacks = 0

    def compile_selected(selected, shared):
        nonlocal calls
        files = []
        for index, probe in selected:
            path = directory / f'Probe{index:04d}.swift'
            source = renamed_helpers(probe.source, f'__nv_probe_{index}_') if shared else probe.source
            assert source is not None
            path.write_text(source)
            files.append((probe, path))
        # Whole-module type checking visits every file in one frontend job.
        # Language, safety, module/package and SDK settings retain their values.
        invocation = command + (['-whole-module-optimization'] if shared and '-whole-module-optimization' not in command else [])
        calls += 1
        result = subprocess.run(invocation + [str(path) for _, path in files],
                                text=True, capture_output=True, timeout=timeout)
        return result, files

    def finish(selected):
        nonlocal fallbacks
        shared = len(selected) > 1
        result, files = compile_selected(selected, shared)
        if not satisfies(result, files):
            if not shared:
                raise ProbeFailure(f'{selected[0][1].name}\n{result.stdout}{result.stderr}')
            fallbacks += 1
            print(f'Compiler batch fallback: {label}, {len(selected)} isolated clients', flush=True)
            # Recheck original sources so suppressed errors and interactions
            # receive the same individual contract as an unbatched campaign.
            for entry in selected:
                single, one_file = compile_selected([entry], False)
                if not satisfies(single, one_file):
                    raise ProbeFailure(f'{entry[1].name}\n{single.stdout}{single.stderr}')
        for _, probe in selected:
            print(f'PASS: {label + " " if label else ""}{probe.name}', flush=True)

    pending = []
    for index, probe in enumerate(probes):
        compatible = (probe.expected is not None and maximum > 1 and
                      renamed_helpers(probe.source, f'__nv_probe_{index}_') is not None)
        if not compatible:
            if pending:
                finish(pending)
                pending = []
            finish([(index, probe)])
        else:
            pending.append((index, probe))
            if len(pending) == maximum:
                finish(pending)
                pending = []
    if pending:
        finish(pending)
    elapsed = time.perf_counter() - started
    print(f'Compiler probes: {label.rstrip(":") or "ordinary"}: {len(probes)} checks, {calls} invocations, '
          f'{fallbacks} fallback batches, {elapsed:.3f}s', flush=True)
    return len(probes)
