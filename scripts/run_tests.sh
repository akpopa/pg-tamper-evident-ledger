#!/usr/bin/env bash
# Run the test suite. Each test file gets a fresh database with the demo
# tenant (tenant_alpha) provisioned and seeded, because the tamper tests
# damage the database on purpose.
#
# Needs a PostgreSQL superuser connection (the tamper tests switch triggers
# off). Connection settings come from PGHOST, PGPORT, PGUSER, PGPASSWORD.
# Exits 0 only if every check passes and every script runs to the end.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
db="ledger_test"
admin() { psql -X -q -v ON_ERROR_STOP=1 -d postgres "$@"; }

pass=0; fail=0; broken=0
for t in "$here"/tests/[0-9][0-9]_*; do
  name="$(basename "$t")"
  [[ "$name" == 00_seed.sql ]] && continue
  echo "== $name"

  admin -c "DROP DATABASE IF EXISTS $db" -c "CREATE DATABASE $db" >/dev/null 2>&1 \
    || { echo "   could not create test database"; exit 2; }
  export PGDATABASE="$db"
  if ! { "$here/scripts/provision_tenant.sh" tenant_alpha >/dev/null &&
         psql -X -q -v ON_ERROR_STOP=1 -f "$here/tests/00_seed.sql" >/dev/null &&
         psql -X -q -v ON_ERROR_STOP=1 -f "$here/tests/_testkit.sql" >/dev/null; }; then
    echo "   setup failed"; broken=$((broken+1)); unset PGDATABASE; continue
  fi

  case "$name" in
    *.sql) out="$(psql -X -q -v ON_ERROR_STOP=1 -o /dev/null -f "$t" 2>&1)"; rc=$? ;;
    *.sh)  out="$(bash "$t" 2>&1)"; rc=$? ;;
  esac
  unset PGDATABASE

  results="$(grep -oE '(PASS|FAIL) .*' <<<"$out")"
  [[ -n "$results" ]] && sed 's/^/   /' <<<"$results"
  p=$(grep -c '^PASS' <<<"$results"); f=$(grep -c '^FAIL' <<<"$results")
  pass=$((pass+p)); fail=$((fail+f))
  if [[ $rc -ne 0 || $p -eq 0 ]]; then
    echo "   script did not complete:"; grep -vE '(PASS|FAIL) ' <<<"$out" | sed 's/^/     /'
    broken=$((broken+1))
  fi
done
admin -c "DROP DATABASE IF EXISTS $db" >/dev/null 2>&1

echo
echo "$pass passed, $fail failed, $broken scripts with errors"
[[ $fail -eq 0 && $broken -eq 0 ]]
