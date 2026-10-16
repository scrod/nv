#!/usr/bin/env python3
"""Independent title/extension/collision examples for captured filename preparation."""
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]


def expected():
    # Each expected name is an independently specified result, not generator output.
    cases = [
        ('slash', 'Folder/Title', ['txt'], None, [], [], 'Folder:Title.txt'),
        ('hidden', '.Hidden', ['txt'], None, [], [], '_Hidden.txt'),
        ('extension-case', 'Note', ['txt', 'md'], 'Old.MD', [], ['Old.MD'], 'Note.MD'),
        ('extension-change', 'Note', ['txt'], 'Old.rtf', [], ['Old.rtf'], 'Note.txt'),
        ('other-format', 'Note', ['txt'], None, ['Note.rtf'], [], 'Note.1.txt'),
        ('disk-only', 'Note', ['txt'], None, [], ['note.txt'], 'Note.1.txt'),
        ('series', 'Note', ['txt'], None, ['Note.rtf', 'Note.1.md'], ['NOTE.2.TXT'], 'Note.3.txt'),
        ('title-extension', 'Report.draft', ['txt'], None, [], ['Report.draft.txt'], 'Report.1.txt'),
        ('case-rename', 'case', ['txt'], 'Case.txt', [], ['Case.txt'], 'case.txt'),
        ('nfd', 'Cafe\u0301', ['txt'], None, [], [], 'Cafe\u0301.txt'),
        ('alias', 'Cafe\u0301', ['txt'], None, [], ['Caf\u00e9.txt'], 'Cafe\u0301.1.txt'),
        ('extensionless', 'Note', [''], None, [], [], 'Note'),
        ('reserved', 'NV Data', [''], None, [], [], 'NV Data.1'),
        ('trailing-dot', 'Note.', ['txt'], None, [], [], 'Note..txt'),
    ]
    return [dict(name=n, title=t, extensions=e, current=c, otherNotes=o, occupied=d, expected=r)
            for n, t, e, c, o, d, r in cases]


if __name__ == '__main__':
    fixture = ROOT / 'NVStorage/Tests/NVStorageCoreTests/Fixtures/projection-filename.json'
    if '--write' in sys.argv:
        fixture.write_text(json.dumps(expected(), indent=2, ensure_ascii=True) + '\n')
    assert json.loads(fixture.read_text()) == expected()
    print('PASS: independent legacy filename, extension, collision and reserved-name examples')
