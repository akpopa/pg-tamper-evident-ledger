#!/usr/bin/env bash
# N. Tenants in several databases: one upgrade covers them all, and a tenant
# moves to another database with its chain, anchor, history and roles intact.
#
# Run by scripts/run_tests.sh against a freshly seeded database (PGDATABASE set).
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ex="$root/examples/app-layer"
src="$PGDATABASE"
dbs=(ledger_test_b ledger_test_c ledger_test_d)
work="$(mktemp -d)"
admin() { psql -X -q -v ON_ERROR_STOP=1 -d postgres "$@"; }
cleanup() { for d in "${dbs[@]}"; do admin -c "DROP DATABASE IF EXISTS $d" >/dev/null 2>&1; done; rm -r -- "$work"; }
trap cleanup EXIT
for d in "${dbs[@]}"; do admin -c "DROP DATABASE IF EXISTS $d" -c "CREATE DATABASE $d" >/dev/null; done
q() { psql -X -q -At -v ON_ERROR_STOP=1 "$@"; }
check() { if [[ "$2" == "$3" ]]; then echo "PASS $1"; else echo "FAIL $1 (expected '$3', got '$2')"; fi; }
url="postgresql://${PGUSER}:${PGPASSWORD}@${PGHOST:-localhost}:${PGPORT:-5432}/ledger_test_b"

# The application's shared layer registers the same types as the test seed,
# so a moved tenant finds them in the target database.
mkdir -p "$work/types/shared"
grep -E "register_(account|entry)_type" "$root/tests/00_seed.sql" > "$work/types/shared/V1__types.sql"

# Upgrading several databases in one run
LEDGER_DB=ledger_test_b "$root/scripts/provision_tenant.sh" tenant_gamma >/dev/null
"$root/scripts/upgrade.sh" --database "$src" --database ledger_test_b --layer example="$ex" >/dev/null
check "N1 one upgrade applies a layer to tenants in two databases" \
  "$(q -d "$src" -c "SELECT count(*) FROM ledger_migrations.history WHERE target = 'tenant_alpha' AND layer = 'example'"):$(q -d ledger_test_b -c "SELECT count(*) FROM ledger_migrations.history WHERE target = 'tenant_gamma' AND layer = 'example'")" "2:2"
out="$("$root/scripts/upgrade.sh" --database "$src" --database "$url" --layer example="$ex")"
check "N2 a second run applies nothing, and accepts a connection string" "$(grep -c '^applied' <<<"$out")" 0
check "N3 a password in a connection string is not printed" "$(grep -c "$PGPASSWORD@" <<<"$out")" 0
out="$("$root/scripts/upgrade.sh" --database ledger_test_d --database "$src" 2>&1)"; rc=$?
check "N4 a database with no ledger stops the run and is named" "$rc:$(grep -c 'upgrade stopped at ledger_test_d' <<<"$out")" "1:1"

# Moving tenant_alpha (seeded: entries #1-#4, digest at #3) to ledger_test_c
before="$(q -d "$src" -c "SELECT last_seq || ':' || encode(last_hash, 'hex') FROM tenant_alpha.chain_head")"
out="$(LEDGER_DB="$src" "$root/scripts/move_tenant.sh" tenant_alpha --to ledger_test_c --layer types="$work/types" --layer example="$ex" 2>&1)"; rc=$?
check "N5 moving a tenant succeeds and reports the verified head" "$rc:$(grep -c '^moved tenant_alpha: chain verifies on the target through #4' <<<"$out")" "0:1"
check "N6 the copy verifies, with the same chain head and balances" \
  "$(q -d ledger_test_c -c "SELECT (SELECT count(*) FROM tenant_alpha.verify_chain()) || ' ' || last_seq || ':' || encode(last_hash, 'hex') FROM tenant_alpha.chain_head"):$(q -d ledger_test_c -c "SELECT string_agg(account_id || '=' || balance_cents, ',' ORDER BY account_id) FROM tenant_alpha.account_balances")" \
  "0 $before:$(q -d "$src" -c "SELECT string_agg(account_id || '=' || balance_cents, ',' ORDER BY account_id) FROM tenant_alpha.account_balances")"
check "N7 the outside anchor recorded before the move still verifies the copy" \
  "$(q -d ledger_test_c -c "SELECT count(*) FROM tenant_alpha.verify_chain(3, decode('$(q -d "$src" -c "SELECT encode(hash, 'hex') FROM public.s3_copy")', 'hex'))")" 0
check "N8 the copy keeps its migration history, owner and per-tenant grants" \
  "$(q -d ledger_test_c -c "SELECT string_agg(layer || ':' || version, ',' ORDER BY layer, version) FROM ledger_migrations.history WHERE target = 'tenant_alpha'") $(q -d ledger_test_c -c "SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid = 'tenant_alpha.post_entry'::regproc") $(q -d ledger_test_c -c "SELECT has_function_privilege('ledger_tenant_alpha_poster', 'tenant_alpha.post_entry(text,text,text,timestamptz,text,jsonb,bigint)', 'EXECUTE')")" \
  "core:1,example:1,example:2 ledger_owner t"
check "N9 posting continues on the target, and the source is left untouched" \
  "$(q -d ledger_test_c -c "SET ROLE ledger_test_app" -c "SELECT tenant_alpha.post_entry('payment', 'PAY-D9', 'x', '2026-11-23', 'u1', '[{\"account_id\":2,\"amount_cents\":-100},{\"account_id\":3,\"amount_cents\":100}]')") $(q -d "$src" -c "SELECT last_seq FROM tenant_alpha.chain_head")" "5 4"
out="$(LEDGER_DB="$src" "$root/scripts/move_tenant.sh" tenant_alpha --to ledger_test_c --layer types="$work/types" 2>&1)"; rc=$?
check "N10 moving onto a database that already has the tenant is refused" "$rc:$(grep -c 'already exists in the target' <<<"$out")" "1:1"
out="$(LEDGER_DB="$src" "$root/scripts/move_tenant.sh" tenant_alpha --to ledger_test_d 2>&1)"; rc=$?
check "N11 without the application's types the move fails and leaves nothing behind" \
  "$rc:$(grep -c 'nothing from it was applied' <<<"$out"):$(q -d ledger_test_d -c "SELECT count(*) FROM pg_namespace WHERE nspname = 'tenant_alpha'")" "1:1:0"
out="$(LEDGER_DB="$src" "$root/scripts/move_tenant.sh" tenant_alpha --to "$src" 2>&1)"; rc=$?
check "N12 moving a tenant onto its own database is refused" "$rc" 2
