#!/usr/bin/env bash
# V. The chain verifies outside PostgreSQL with tools/verify_chain.py, an
# independent implementation of the documented hash format, and the outside
# verifier catches the same tampering as verify_chain().
#
# Run by scripts/run_tests.sh against a freshly seeded database (PGDATABASE set).
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -r -- "$work"' EXIT
q() { psql -X -q -At -v ON_ERROR_STOP=1 "$@"; }
export_chain() { q -v tenant=tenant_alpha -f "$root/tools/export_chain.sql" > "$work/chain.jsonl"; }
verify() { python3 "$root/tools/verify_chain.py" "$work/chain.jsonl" "$@"; }
check() { if [[ "$2" == "$3" ]]; then echo "PASS $1"; else echo "FAIL $1 (expected '$3', got '$2')"; fi; }

anchor_seq="$(q -c "SELECT seq FROM public.s3_copy")"
anchor_hash="$(q -c "SELECT encode(hash, 'hex') FROM public.s3_copy")"

export_chain
out="$(verify --anchor-seq "$anchor_seq" --anchor-hash "$anchor_hash")"; rc=$?
check "V1 the seeded chain verifies outside PostgreSQL, with the outside anchor" "$rc:$out" \
  "0:OK: tenant_alpha chain intact through #4, anchored at #3"

check "V2 the outside verifier computes the same genesis hash as the database" \
  "$(python3 -c "import sys; sys.path.insert(0, '$root/tools'); import verify_chain as v; print(v.genesis('tenant_alpha').hex())")" \
  "$(q -c "SELECT encode(prev_hash, 'hex') FROM tenant_alpha.journal_entries WHERE sequence_no = 1")"

# An owner ID, reference, description and actor with separators, quotes and
# accents, and a reversal, hash the same in both places.
q -c "SET ROLE ledger_test_app" \
  -c "SELECT tenant_alpha.open_account('holder_funds', 'holder', 'h:2,|é')" \
  -c "SELECT tenant_alpha.post_entry('load', 'LOAD-V3', 'Funds', '2026-11-23', 'sys',
        '[{\"account_id\":1,\"amount_cents\":-2500},{\"account_id\":4,\"amount_cents\":2500}]')" \
  -c "SELECT tenant_alpha.post_entry('payment', 'PAY-V3|x', 'Café, \"quoted\" | 3:abc,', '2026-11-23T10:15:00-05:00', 'u|2',
        '[{\"account_id\":4,\"amount_cents\":-2500},{\"account_id\":3,\"amount_cents\":2500}]')" \
  -c "SELECT tenant_alpha.post_entry('reversal', 'REV-V3', 'Undo', '2026-11-23', 'u2',
        '[{\"account_id\":3,\"amount_cents\":-2500},{\"account_id\":4,\"amount_cents\":2500}]', 6)" >/dev/null
export_chain
out="$(verify)"; rc=$?
check "V3 entries with separators, quotes, accents and a reversal verify outside PostgreSQL" "$rc:$out" \
  "0:OK: tenant_alpha chain intact through #7"

# An edit made with protections off is caught outside as well.
q -c "SET session_replication_role = replica" \
  -c "UPDATE tenant_alpha.journal_entries SET description = 'Item A (edited)' WHERE sequence_no = 2" >/dev/null
export_chain
out="$(verify)"; rc=$?
check "V4 an edited entry is caught by the outside verifier" "$rc:$out" "1:FAILED at #2: entry contents changed"
check "V5 and by verify_chain() at the same entry" \
  "$(q -c "SET ROLE ledger_test_app" -c "SELECT bad_seq || ' ' || problem FROM tenant_alpha.verify_chain()")" \
  "2 entry contents changed"

out="$(verify --anchor-seq 3 --anchor-hash "$(printf '0%.0s' {1..64})")"; rc=$?
check "V6 a wrong outside anchor is reported" "$rc" 1

# A timestamp the hash cannot represent is reported as a chain problem (exit 1)
# rather than crashing the verifier.
q -c "SET session_replication_role = replica" \
  -c "UPDATE tenant_alpha.journal_entries SET description = 'Item A' WHERE sequence_no = 2" \
  -c "ALTER TABLE tenant_alpha.journal_entries DROP CONSTRAINT journal_entries_effective_at_check" \
  -c "UPDATE tenant_alpha.journal_entries SET effective_at = 'infinity' WHERE sequence_no = 3" >/dev/null
export_chain
out="$(verify 2>&1)"; rc=$?
check "V7 an infinite timestamp is reported by the outside verifier, not a crash" "$rc:$out" \
  "1:FAILED at #3: timestamp outside years 1-9999 (not covered by the hash): infinity"

# A malformed export is bad input (exit 2), never mistaken for tampering.
head -n 1 "$work/chain.jsonl" > "$work/bad.jsonl"; echo '{"seq": 1}' >> "$work/bad.jsonl"
out="$(python3 "$root/tools/verify_chain.py" "$work/bad.jsonl" 2>&1)"; rc=$?
check "V8 a malformed export exits with status 2" "$rc:$(grep -c 'malformed export' <<<"$out")" "2:1"
