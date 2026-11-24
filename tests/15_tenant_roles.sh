#!/usr/bin/env bash
# P. Per-tenant roles: a login created NOINHERIT and granted several tenants'
# roles can reach a tenant only after switching into that tenant's role, so a
# request routed to the wrong tenant is refused.
#
# Run by scripts/run_tests.sh against a freshly seeded database (PGDATABASE set).
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
q() { psql -X -q -At -v ON_ERROR_STOP=1 "$@"; }
check() { if [[ "$2" == "$3" ]]; then echo "PASS $1"; else echo "FAIL $1 (expected '$3', got '$2')"; fi; }
# Runs SQL as the test application login; prints the result, or ERROR and the message
# (SQL is read from standard input, so every statement's result is printed on
# all psql versions; psql 14 prints only the last result of a multi-statement -c.)
as_app() { PGUSER=p_app PGPASSWORD=p_app_pw psql -X -q -At -v ON_ERROR_STOP=1 <<<"$1" 2>&1 | sed -E 's/^(psql:[^E]*)?ERROR: +/ERROR: /'; }

"$root/scripts/provision_tenant.sh" tenant_beta >/dev/null
q -c "SET ROLE ledger_test_app" -c "SELECT tenant_beta.open_account('funding'), tenant_beta.open_account('holder_funds', 'holder', 'h-1')" >/dev/null
q -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'p_app') THEN CREATE ROLE p_app LOGIN NOINHERIT PASSWORD 'p_app_pw'; END IF; END \$\$" \
  -c "GRANT ledger_tenant_alpha_poster, ledger_tenant_alpha_reader, ledger_tenant_beta_poster, ledger_tenant_beta_reader TO p_app" >/dev/null

check "P1 each tenant has its four roles, which cannot log in" \
  "$(q -c "SELECT count(*) FROM pg_roles WHERE rolname ~ '^ledger_tenant_(alpha|beta)_(reader|poster|opener|digest)$' AND NOT rolcanlogin AND NOT rolsuper")" 8

post_alpha="SELECT tenant_alpha.post_entry('load', 'P-' || md5(random()::text), 'x', '2026-11-23', 'u', '[{\"account_id\":1,\"amount_cents\":-100},{\"account_id\":2,\"amount_cents\":100}]')"
post_beta="SELECT tenant_beta.post_entry('load', 'P-' || md5(random()::text), 'x', '2026-11-23', 'u', '[{\"account_id\":1,\"amount_cents\":-100},{\"account_id\":2,\"amount_cents\":100}]')"

check "P2 without switching roles, the login cannot post to any tenant" \
  "$(as_app "$post_alpha" | grep -c 'permission denied')" 1
check "P3 after SET LOCAL ROLE to tenant_alpha's poster, it can post to tenant_alpha" \
  "$(as_app "BEGIN; SET LOCAL ROLE ledger_tenant_alpha_poster; $post_alpha; COMMIT;")" 5
check "P4 in tenant_alpha's role, posting to tenant_beta is refused" \
  "$(as_app "BEGIN; SET LOCAL ROLE ledger_tenant_alpha_poster; $post_beta; COMMIT;" | grep -c 'permission denied')" 1
check "P5 in tenant_alpha's reader role, tenant_beta's balances cannot be read" \
  "$(as_app "BEGIN; SET LOCAL ROLE ledger_tenant_alpha_reader; SELECT count(*) FROM tenant_alpha.account_balances; SELECT count(*) FROM tenant_beta.account_balances; COMMIT;" | tr '\n' ' ' | grep -cE '^3 ERROR: permission denied')" 1
check "P6 the role switch ends with the transaction" \
  "$(as_app "BEGIN; SET LOCAL ROLE ledger_tenant_alpha_poster; COMMIT; SELECT current_user;")" p_app

# An application's own per-tenant role combining poster and opener, for
# requests that open an account and post in one transaction.
q -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'p_app_tenant_alpha') THEN CREATE ROLE p_app_tenant_alpha NOLOGIN; END IF; END \$\$" \
  -c "GRANT ledger_tenant_alpha_poster, ledger_tenant_alpha_opener TO p_app_tenant_alpha" -c "GRANT p_app_tenant_alpha TO p_app" >/dev/null
check "P7 an application role combining a tenant's poster and opener can open an account and post in one transaction" \
  "$(as_app "BEGIN; SET LOCAL ROLE p_app_tenant_alpha;
       SELECT tenant_alpha.open_account('holder_funds', 'holder', 'h-p7');
       SELECT tenant_alpha.post_entry('load', 'P7', 'x', '2026-11-23', 'u', '[{\"account_id\":1,\"amount_cents\":-100},{\"account_id\":4,\"amount_cents\":100}]');
       COMMIT;" | tr '\n' ' ')" "4 6 "

long="t$(printf 'a%.0s' {1..49})"
out="$("$root/scripts/provision_tenant.sh" "$long" 2>&1)"; rc=$?
check "P8 a tenant name over 49 characters is refused, with the reason" "$rc:$(grep -c 'the limit is 49' <<<"$out")" "2:1"
ok49="t$(printf 'b%.0s' {1..48})"
"$root/scripts/provision_tenant.sh" "$ok49" >/dev/null 2>&1; rc=$?
check "P9 a 49-character tenant name is accepted and gets its roles" \
  "$rc:$(q -c "SELECT count(*) FROM pg_roles WHERE rolname LIKE 'ledger_${ok49}_%'")" "0:4"

check "P10 both tenants still verify" \
  "$(q -c "SELECT (SELECT count(*) FROM tenant_alpha.verify_chain()) + (SELECT count(*) FROM tenant_beta.verify_chain())")" 0
