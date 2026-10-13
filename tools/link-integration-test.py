#!/usr/bin/env python3
"""Run the requested integration link with content-based freshness checks."""
import argparse
from qualification_reuse import link_if_changed

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--manifest', required=True)
parser.add_argument('--output', required=True)
parser.add_argument('command', nargs=argparse.REMAINDER)
args = parser.parse_args()
assert args.command[0] == '--' and len(args.command) > 1
link_if_changed(args.command[1:], args.manifest, args.output)
