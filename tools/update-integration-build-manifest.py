#!/usr/bin/env python3
"""Advance the integration link prerequisite when its actual inputs change."""
import argparse
import os
from pathlib import Path
import shlex
from qualification_reuse import ROOT, atomic_write, encoded, input_files, tool_context


def project_headers():
    """Include nested project headers while pruning generated build trees."""
    headers = []
    for base, directories, files in os.walk(ROOT):
        directories[:] = sorted(name for name in directories if name not in
            {'.git', '.deps', 'DerivedData', 'node_modules', '__pycache__'} and not name.startswith('.build'))
        headers.extend(Path(base)/name for name in sorted(files) if name.endswith(('.h', '.hpp')))
    return headers


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--objects', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--compiler', required=True)
    parser.add_argument('--context', required=True)
    args = parser.parse_args()
    objects = sorted(p for p in args.objects.glob('*.o')
                     if p.name != 'main.o' and not p.name.endswith('_vers.o'))
    if not objects:
        raise RuntimeError('The successful application build must supply integration object files')
    inputs = [*objects, *project_headers(),
              ROOT/'tests/Makefile', ROOT/'Info.plist', Path(__file__)]
    framework = ROOT/'Sparkle.framework'
    if framework.is_dir():
        inputs.append(framework)
    value = encoded({'inputs': input_files(inputs), 'context': args.context,
                     'toolchain': tool_context([shlex.split(args.compiler)[0]])})
    if args.output.is_file() and args.output.read_bytes() == value:
        print('Integration link inputs unchanged', flush=True)
    else:
        atomic_write(args.output, value)
        print('Integration link inputs updated', flush=True)


if __name__ == '__main__':
    main()
