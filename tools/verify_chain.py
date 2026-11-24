#!/usr/bin/env python3
"""Verify a ledger chain outside PostgreSQL.

An independent implementation of the "ledger-v2" hash format (ADR-0002,
docs/technical-design.md). It shares no code with the database functions, so
an auditor can check a chain with nothing but this file, an export, and the
latest digest read back from outside storage.

    psql -X -q -At -v tenant=tenant_alpha -f tools/export_chain.sql > chain.jsonl
    python3 tools/verify_chain.py chain.jsonl --anchor-seq 3 --anchor-hash 9f86d0...

Exit status 0 when the chain is intact, 1 when a problem is found in the
chain (printed), 2 when the export cannot be read or is malformed. Standard
library only.
"""
import argparse
import hashlib
import json
import sys
from datetime import datetime, timezone

FORMAT = "ledger-v2"


def field(value):
    """One length-prefixed field: '<bytes>:<value>,', or '-' for NULL."""
    if value is None:
        return "-"
    text = str(value)
    return f"{len(text.encode('utf-8'))}:{text},"


class ChainProblem(Exception):
    """A problem with the chain's contents (exit status 1)."""


class BadExport(Exception):
    """An export that is not in the expected shape (exit status 2)."""


def timestamp(text):
    """Normalizes a timestamp to the hashed form: UTC, microseconds, 'Z'.

    Only years 1-9999 can be hashed unambiguously (the hashed form has no era
    and no infinity), so anything else is a problem with the chain.
    """
    if not isinstance(text, str):
        raise BadExport(f"timestamp is not a string: {text!r}")
    try:
        dt = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        raise ChainProblem(f"timestamp outside years 1-9999 (not covered by the hash): {text}")
    if dt.tzinfo is None:
        raise BadExport(f"timestamp without a time zone: {text}")
    dt = dt.astimezone(timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def genesis(tenant):
    return hashlib.sha256((field(FORMAT) + field("genesis") + field(tenant)).encode("utf-8")).digest()


def posting_line(line):
    inner = (field(line["line_no"]) + field(line["account_id"]) + field(line["account_type"])
             + field(line["owner_type"]) + field(line["owner_id"]) + field(line["amount_cents"]))
    return field(inner)


def canonical(entry):
    lines = "".join(posting_line(l) for l in sorted(entry["lines"] or [], key=lambda l: l["line_no"]))
    return (field(FORMAT) + field(entry["seq"]) + field(entry["entry_type"]) + field(entry["external_ref"])
            + field(entry["reverses_seq"]) + field(entry["description"])
            + field(timestamp(entry["effective_at"])) + field(timestamp(entry["recorded_at"]))
            + field(entry["recorded_by"]) + field(lines))


def verify(header, entries, anchor_seq=None, anchor_hash=None):
    """Returns (seq, problem) for the first problem found, or None."""
    if header.get("format") != FORMAT:
        return (None, f"unsupported format {header.get('format')!r}")
    prev = genesis(header["tenant"])
    expected = 1
    hashes = {}
    for e in entries:
        try:
            result = check_entry(e, prev, expected)
        except ChainProblem as exc:
            return (e.get("seq"), str(exc))
        if result is not None:
            return result
        hashes[e["seq"]] = prev = bytes.fromhex(e["entry_hash"])
        expected += 1
    if header["head_seq"] != expected - 1 or bytes.fromhex(header["head_hash"]) != prev:
        return (header["head_seq"], f"chain head (#{header['head_seq']}) does not match the last entry (#{expected - 1})")
    if anchor_seq is not None:
        if anchor_seq not in hashes:
            return (anchor_seq, "entry covered by the outside digest is missing")
        if hashes[anchor_seq] != bytes.fromhex(anchor_hash):
            return (anchor_seq, "entry does not match the outside digest (chain was rewritten)")
    return None


def check_entry(e, prev, expected):
    """Returns (seq, problem) if this entry breaks the chain, else None."""
    if e["seq"] != expected:
        return (e["seq"], f"gap in entry numbers: expected #{expected}, found #{e['seq']}")
    if bytes.fromhex(e["prev_hash"]) != prev:
        return (e["seq"], "prev_hash does not match previous entry")
    calc = hashlib.sha256(prev + canonical(e).encode("utf-8")).digest()
    if calc != bytes.fromhex(e["entry_hash"]):
        return (e["seq"], "entry contents changed")
    return None


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("export", help="JSON lines from tools/export_chain.sql ('-' for stdin)")
    ap.add_argument("--anchor-seq", type=int, help="sequence number in the latest outside digest")
    ap.add_argument("--anchor-hash", help="entry hash (hex) in the latest outside digest")
    args = ap.parse_args(argv)
    if (args.anchor_seq is None) != (args.anchor_hash is None):
        ap.error("pass both --anchor-seq and --anchor-hash, or neither")
    try:
        stream = sys.stdin if args.export == "-" else open(args.export, encoding="utf-8")
        rows = [json.loads(line) for line in stream if line.strip()]
        header, entries = rows[0], rows[1:]
    except (OSError, ValueError, IndexError) as exc:
        print(f"error: cannot read export: {exc}", file=sys.stderr)
        return 2
    try:
        if not isinstance(header, dict) or not all(isinstance(e, dict) for e in entries):
            raise BadExport("every line must be a JSON object")
        problem = verify(header, entries, args.anchor_seq, args.anchor_hash)
    except (BadExport, KeyError, TypeError, ValueError, AttributeError) as exc:
        detail = f"missing field {exc}" if isinstance(exc, KeyError) else str(exc)
        print(f"error: malformed export: {detail}", file=sys.stderr)
        return 2
    if problem:
        print(f"FAILED at #{problem[0]}: {problem[1]}")
        return 1
    anchored = f", anchored at #{args.anchor_seq}" if args.anchor_seq is not None else ""
    print(f"OK: {header['tenant']} chain intact through #{len(entries)}{anchored}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
