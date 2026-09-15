#!/usr/bin/env python3
"""Complete the independent envelope checks for a preserved remote process run."""
import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('artifacts', type=Path)
parser.add_argument('--expected-checks', type=int, default=72)
args = parser.parse_args()
results = json.loads((args.artifacts / 'results.json').read_text())
reports = [r for r in results if 'inspection' in r]
assert len(results) == args.expected_checks and len(reports) == 46, 'incomplete process run or report discovery'
for row in reports:
    report = args.artifacts / row['inspection']
    checked = subprocess.run(['node', str(ROOT / 'tools/inspect-storage-history.mjs')],
                             input=report.read_text(), text=True, capture_output=True, timeout=45)
    assert checked.returncode == 0, (report, checked.stderr)
    row['independent'] = json.loads(checked.stdout)
(args.artifacts / 'independently-checked-results.json').write_text(json.dumps(results, indent=2))
print(f'PASS: {len(reports)} independent SQL/envelope inspections for {len(results)} process checks')
