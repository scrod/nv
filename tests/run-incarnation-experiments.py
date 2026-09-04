#!/usr/bin/env python3
"""Two-Mac synthetic identity experiment; no production NV state is touched.

Each observer is a fresh process. Sync polls compare actual bytes/attribute
digests, never just a marker or upload status. Results are observations, not
an assertion of a portable Apple identity contract. Fixtures are retained.
"""
import argparse
import json
from pathlib import Path
import shlex
import subprocess
import tempfile
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="/tmp/notation-integration-tests/ICloudAPIContractTest")
    parser.add_argument("--remote-binary")
    parser.add_argument("--local", action="store_true", help="Use fresh local processes for both observers; NOT a cross-Mac test")
    parser.add_argument("--host", default="scrod@scrodmini.local")
    parser.add_argument("--key", default="/tmp/scrodmini_ed25519")
    parser.add_argument("--root", default="/Users/scrod/Library/Mobile Documents/com~apple~CloudDocs/API_Contract_Testing")
    parser.add_argument("--handshake", action="store_true", help="Run clean and explicitly relayed nonce exchanges instead of the lifecycle")
    parser.add_argument("--session", help="Start a handshake in an unused prepared fixture; not a partial-run resume")
    args = parser.parse_args()
    if not args.local and not args.remote_binary:
        parser.error("--remote-binary is required unless --local is selected")
    output = Path(tempfile.mkdtemp(prefix="nv-binding-results-"))
    results = []
    print(f"Results: {output}; observers={'same Mac' if args.local else 'two Macs'}", flush=True)

    def run(host, *arguments):
        binary = args.binary if host == "A" or args.local else args.remote_binary
        command = ["env", "NV_ICLOUD_API_TEST_TIMEOUT=20", binary, *arguments]
        if host == "B" and not args.local:
            command = ["ssh", "-i", args.key, "-o", "StrictHostKeyChecking=no",
                       "-o", "ConnectTimeout=10", args.host, shlex.join(command)]
        completed = subprocess.run(command, text=True, capture_output=True, timeout=55)
        with (output / "calls.jsonl").open("a") as log:
            log.write(json.dumps(dict(host=host, arguments=arguments, code=completed.returncode,
                                      stdout=completed.stdout, stderr=completed.stderr)) + "\n")
        if completed.returncode:
            raise RuntimeError(f"{host} {arguments}: {completed.stdout} {completed.stderr}")
        return completed.stdout

    if args.session:
        path = Path(args.session)
        if not args.handshake or path.parent != Path(args.root) or not path.name.startswith("nv-api-binding-"):
            parser.error("--session requires --handshake and a generated fixture directly below --root")
        try:
            uuid.UUID(path.name.removeprefix("nv-api-binding-"))
        except ValueError:
            parser.error("--session must have a generated UUID name")
        session = str(path)
    else:
        prepared = run("A", "binding", args.root, "prepare")
        session = next(line.split(" ", 2)[2] for line in prepared.splitlines()
                       if line.startswith("READY AV-BIND-session "))
    print(f"Fixture: {session}", flush=True)

    def observe(host, leaf="note.bin", metadata_only=False):
        text = run(host, "binding", session, "metadata" if metadata_only else "observe", leaf)
        return next(json.loads(line.split(" ", 2)[2]) for line in text.splitlines()
                    if line.startswith("OBSERVE AV-METADATA-binding "))

    def signature(value):
        return value["bodyHash"], value["attributes"]["sync"]

    def match_peer(host, leaf, expected):
        deadline = time.monotonic() + 60
        while True:
            try:
                actual = observe(host, leaf)
                if signature(actual) == signature(expected):
                    return actual
            except (RuntimeError, subprocess.TimeoutExpired) as error:
                actual = {"error": str(error)}
            if time.monotonic() >= deadline:
                raise RuntimeError(f"No observed convergence: {host} {leaf}: {actual}")
            time.sleep(1)

    def record(label, actor="A", leaf="note.bin", action=None, source=None):
        if action:
            run(actor, "binding", session, action, source or leaf)
        local = observe(actor, leaf)
        peer = match_peer("B" if actor == "A" else "A", leaf, local)
        entry = dict(label=label, actor=actor, leaf=leaf, local=local, peer=peer,
                     sameProviderItem=bool(local.get("providerItemHash")) and
                         local.get("providerItemHash") == peer.get("providerItemHash"),
                     sameProviderDomain=bool(local.get("providerDomainHash")) and
                         local.get("providerDomainHash") == peer.get("providerDomainHash"))
        results.append(entry)
        (output / "results.json").write_text(json.dumps(dict(session=session, localOnly=args.local, steps=results), indent=2) + "\n")
        print(f"OBSERVED {label}: observer item equal={entry['sameProviderItem']}; "
              f"domain equal={entry['sameProviderDomain']}", flush=True)
        return entry

    initial = record("initial")
    if args.handshake:
        record("clean-challenge", action="challenge")
        record("clean-reply", actor="B", action="reply")
        record("clean-ack", action="ack")
        copied = record("independent-copy", leaf="copy.bin", action="copy", source="note.bin")
        for side in ("local", "peer"):
            assert initial[side].get("providerItemHash") and copied[side].get("providerItemHash")
            assert copied[side]["providerItemHash"] != initial[side]["providerItemHash"]
        record("fresh-challenge", action="challenge")
        # Copyable transcripts are not portable endpoint identity certificates.
        # Explicitly ferry three metadata messages; do not blame provider routing.
        record("relay-challenge", leaf="copy.bin", action="relay", source="note.bin")
        record("reply-on-copy", actor="B", leaf="copy.bin", action="reply")
        record("relay-reply", actor="B", action="relay", source="copy.bin")
        original = record("ack-on-original", action="ack")
        assert original["local"]["providerItemHash"] == initial["local"]["providerItemHash"]
        assert original["peer"]["providerItemHash"] == initial["peer"]["providerItemHash"]
        final_copy = record("relay-ack", leaf="copy.bin", action="relay", source="note.bin")
        assert final_copy["local"]["providerItemHash"] == copied["local"]["providerItemHash"]
        assert final_copy["peer"]["providerItemHash"] == copied["peer"]["providerItemHash"]
        print(f"Completed {len(results)} handshake stages; copies remain distinct. Fixture retained: {session}", flush=True)
        return
    record("fresh-process")
    record("rename", leaf="renamed.bin", action="rename", source="note.bin")
    record("rename-back", actor="B", action="unrename", source="renamed.bin")
    record("safe-A", action="safe")
    record("safe-B", actor="B", action="safe")
    record("copy", leaf="copy.bin", action="copy", source="note.bin")
    eviction = run("B", "binding", session, "evict", "note.bin")
    (output / "eviction.txt").write_text(eviction)
    record("rematerialize", actor="B", action="materialize")
    record("intent-before-move", leaf="intent.plist", action="intent", source="note.bin")
    record("trash-move", leaf="Trash/note.bin", action="trash", source="note.bin")
    record("source-absent", actor="A")
    record("external-untrash", actor="B", action="untrash", source="Trash/note.bin")
    record("external-delete-after-untrash", actor="B", action="delete")
    record("restore-with-old-tag", action="restore-copy")
    record("fresh-birth", action="fresh-birth")
    record("unlink", action="delete")
    restored = record("restore-identical-backup", actor="B", action="restore-copy")
    # Exact old bytes/claims are reintroduced, not silently replaced with a new birth.
    assert signature(restored["local"]) == signature(initial["local"])
    record("external-atomic", action="atomic")
    # A separate controlled absence-first transport schedule. The old intent
    # is removed before this episode; the retained original is the exact
    # source snapshot used to prepare the later synthetic intent.
    record("remove-old-intent", leaf="intent.plist", action="delete")
    record("atomic-unlink", action="delete")
    record("restore-for-absence-first", action="restore-copy")
    record("absence-before-intent", action="delete")
    record("late-intent", leaf="intent.plist", action="intent", source="original.bin")
    print(f"Completed {len(results)} stages. Synthetic fixture retained: {session}", flush=True)


if __name__ == "__main__":
    main()
