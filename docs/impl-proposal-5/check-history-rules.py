#!/usr/bin/env python3
"""Executable proposal vectors, NOT the production merge/undo implementation.

Checks the exact scalar/LF-token bounding-interval rules against independently
constructed finite cases. Does not model causal-base selection, crash recovery,
action records, UI publication, rich text, or Foundation file operations.
"""
from itertools import product

CONFLICT = object()
NOT_APPLICABLE = object()


def scalar(base, left, right):
    if left == right:
        return left
    if left == base:
        return right
    if right == base:
        return left
    return CONFLICT


def lines(body):
    body.decode("utf-8", errors="strict")
    parts = body.split(b"\n")
    return tuple(p + b"\n" for p in parts[:-1]) + ((parts[-1],) if parts[-1] else ())


def interval(base, branch):
    prefix = 0
    while prefix < min(len(base), len(branch)) and base[prefix] == branch[prefix]:
        prefix += 1
    suffix = 0
    while (suffix < min(len(base), len(branch)) - prefix
           and base[len(base)-1-suffix] == branch[len(branch)-1-suffix]):
        suffix += 1
    return prefix, len(base)-suffix, branch[prefix:len(branch)-suffix]


def body_merge(base, left, right):
    simple = scalar(base, left, right)
    if simple is not CONFLICT:
        return simple
    b, l, r = lines(base), lines(left), lines(right)
    if max(len(b), len(l), len(r)) > 10000:
        return CONFLICT
    a, z = interval(b, l), interval(b, r)
    if a == z:
        return b"".join(b[:a[0]] + a[2] + b[a[1]:])
    if not (a[1] < z[0] or z[1] < a[0]):
        return CONFLICT
    result = b
    for start, end, replacement in sorted((a, z), key=lambda h: h[0], reverse=True):
        result = result[:start] + replacement + result[end:]
    return b"".join(result)


def compensate(before, after, current):
    """Single note, title/body only; no admission/stack or identity simulation."""
    result = dict(current)
    for field in before:
        if before[field] == after[field]:
            continue
        if current[field] == before[field]:
            return NOT_APPLICABLE
        merge = body_merge if field == "body" else scalar
        result[field] = merge(after[field], before[field], current[field])
        if result[field] is CONFLICT:
            return CONFLICT
    return NOT_APPLICABLE if result == current else result


def main():
    scalar_cases = 0
    for b, l, r in product(range(3), repeat=3):
        changed = {v for v in (l, r) if v != b}
        expected = b if not changed else next(iter(changed)) if len(changed) == 1 else CONFLICT
        assert scalar(b, l, r) == expected
        assert scalar(b, r, l) == expected
        scalar_cases += 1
    # All Boolean label-membership cases are included in the scalar matrix.
    b = (b"a\n", b"b\n", b"c\n", b"d\n", b"e\n")
    edits = [(i, j, replacement)
             for i in range(len(b)+1) for j in range(i, len(b)+1)
             for replacement in ((), (b"X\n",), (b"Y\n",))
             if i != j or replacement]
    body_cases = 0
    for a, z in product(edits, repeat=2):
        left = b[:a[0]] + a[2] + b[a[1]:]
        right = b[:z[0]] + z[2] + b[z[1]:]
        if left == right:
            expected = b"".join(left)
        else:
            first, second = sorted((a, z), key=lambda h: h[0])
            # Independent construction from the GENERATED edit coordinates,
            # not from the merge function's inferred interval or application loop.
            expected = (b"".join(b[:first[0]] + first[2] + b[first[1]:second[0]]
                                 + second[2] + b[second[1]:])
                        if first[1] < second[0] else CONFLICT)
        assert body_merge(b"".join(b), b"".join(left), b"".join(right)) == expected
        assert body_merge(b"".join(b), b"".join(right), b"".join(left)) == expected
        assert body_merge(b"".join(b), b"".join(b), b"".join(left)) == b"".join(left)
        body_cases += 1
    vectors = [
        (b"a\ngap\nz", b"A\ngap\nz", b"a\ngap\nZ", b"A\ngap\nZ"),
        (b"a\nb\n", b"A\nb\n", b"a\nB\n", CONFLICT),  # touching
        (b"ab", b"Ab", b"aB", CONFLICT),                  # same line
        (b"x\ny\n", b"p\nx\ny\n", b"q\nx\ny\n", CONFLICT),
        (b"a\r\ngap\r\nz\r\n", b"A\r\ngap\r\nz\r\n",
         b"a\r\ngap\r\nZ\r\n", b"A\r\ngap\r\nZ\r\n"),
        ("é\ngap\n🦄".encode(), "e\u0301\ngap\n🦄".encode(),
         "é\ngap\n🐈".encode(), "e\u0301\ngap\n🐈".encode()),
        (b"", b"", b"new", b"new"),
    ]
    for base, left, right, expected in vectors:
        assert body_merge(base, left, right) == expected
    large = b"a\n" * 10001
    assert body_merge(large, b"L\n" + large[2:], large[:-2] + b"R\n") is CONFLICT
    assert body_merge(large, large, b"L\n" + large[2:]) == b"L\n" + large[2:]
    before = dict(title="old", body=b"a\ngap\nz")
    after = dict(title="old", body=b"A\ngap\nz")
    current = dict(title="remote rename", body=b"A\ngap\nZ")
    undone = compensate(before, after, current)
    assert undone == dict(title="remote rename", body=b"a\ngap\nZ")
    # Redo reverses the actual compensation, not the original full note value.
    assert compensate(current, undone, undone) == current
    assert compensate(before, after, dict(title="old", body=b"other\ngap\nz")) is CONFLICT
    assert compensate(before, after, before) is NOT_APPLICABLE
    assert current == dict(title="remote rename", body=b"A\ngap\nZ")  # no input mutation
    # A saved span AB -> ABCD was partially undone natively to ABC. Reconstruct
    # its REMAINING effect, not its original after-value; leave remote title alone.
    span_before = dict(title="note", body=b"AB")
    remaining = dict(title="note", body=b"ABC")
    now = dict(title="remote title", body=b"ABC")
    partial_undo = compensate(span_before, remaining, now)
    assert partial_undo == dict(title="remote title", body=b"AB")
    assert compensate(now, partial_undo, partial_undo) == now  # never restore D
    assert compensate(span_before, dict(title="note", body=b"ABCD"), now) is CONFLICT
    # AppKit's range-corruption example is NOT eligible for automatic history
    # compensation under the adopted conservative LF kernel: same-line overlap.
    assert compensate(dict(body=b"cat"), dict(body=b"cat!"), dict(body=b"big cat!")) is CONFLICT
    print(f"PASS: {scalar_cases} scalar cases; {body_cases} generated edit pairs in both orders; "
          f"{len(vectors)} text vectors; limit, compensation/redo and remaining-span guards")


if __name__ == "__main__":
    main()
