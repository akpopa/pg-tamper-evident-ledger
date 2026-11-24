#!/usr/bin/env bash
# H. Concurrency: 40 payments of $100 start at the same moment against a
# $3,000 balance. Exactly 30 must succeed and 10 must fail with
# "insufficient funds", with gapless entry numbers and an intact chain.
#
# Run by scripts/run_tests.sh against a freshly seeded database (PGDATABASE set).
# A controller session holds an advisory lock; all 40 workers queue on it, and
# the controller releases it only once every worker is waiting, so the
# payments really do arrive together.
set -uo pipefail
workers=40
lock_key=4242
tmp="$(mktemp -d)"
trap 'kill "${ctl_pid:-0}" 2>/dev/null; rm -r -- "$tmp"' EXIT
q() { psql -X -q -At -v ON_ERROR_STOP=1 "$@"; }

# Top the holder up from $700 (after the seed) to $3,000.
q -c "SET ROLE ledger_test_app" -c "SELECT tenant_alpha.post_entry('load','LOAD-2','Top-up','2026-11-20','sys',
  '[{\"account_id\":1,\"amount_cents\":-230000},{\"account_id\":2,\"amount_cents\":230000}]')" >/dev/null

# Controller: take the lock, wait until every worker is queued (max ~30 s), then exit (releasing it).
q -c "DO \$\$
BEGIN
  PERFORM pg_advisory_lock($lock_key);
  FOR i IN 1..600 LOOP
    EXIT WHEN (SELECT count(*) FROM pg_locks
               WHERE locktype = 'advisory' AND objid = $lock_key AND NOT granted) >= $workers;
    PERFORM pg_sleep(0.05);
  END LOOP;
END \$\$" &
ctl_pid=$!

# Wait for the controller to hold the lock before starting workers.
for _ in $(seq 1 100); do
  held=$(q -c "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND objid=$lock_key AND granted")
  [[ "$held" == "1" ]] && break
  sleep 0.05
done

for i in $(seq 1 "$workers"); do
  psql -X -q -At \
    -c "SELECT pg_advisory_lock_shared($lock_key)" \
    -c "SET ROLE ledger_test_app" \
    -c "SELECT tenant_alpha.post_entry('payment','CONC-$i','Item','2026-11-20','u$i',
          '[{\"account_id\":2,\"amount_cents\":-10000},{\"account_id\":3,\"amount_cents\":10000}]')" \
    >"$tmp/w$i.out" 2>&1 &
done
wait

ok=0; rejected=0; other=0
for i in $(seq 1 "$workers"); do
  if   grep -q 'insufficient funds' "$tmp/w$i.out"; then rejected=$((rejected+1))
  elif grep -q 'ERROR' "$tmp/w$i.out";             then other=$((other+1)); sed 's/^/    /' "$tmp/w$i.out"
  else ok=$((ok+1)); fi
done

check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fi; }
check "H1 30 of 40 concurrent payments succeeded (got $ok)"               '[[ $ok -eq 30 ]]'
check "H2 10 were rejected for insufficient funds (got $rejected)"        '[[ $rejected -eq 10 ]]'
check "H3 no other errors occurred (got $other)"                          '[[ $other -eq 0 ]]'

q -f - <<'SQL' 2>&1 | grep -oE '(PASS|FAIL).*'
SET search_path = tenant_alpha, ledger_shared;
SELECT testkit.ok('H4 the holder balance is exactly zero',
  (SELECT balance_cents FROM account_balances WHERE account_id = 2) = 0);
SELECT testkit.ok('H5 entry numbers are gapless (35 entries: 4 seed, 1 top-up, 30 payments)',
  (SELECT count(*) = 35 AND min(sequence_no) = 1 AND max(sequence_no) = 35 FROM journal_entries));
SELECT testkit.ok('H6 the chain verifies, including the S3 anchor',
  (SELECT count(*) FROM verify_chain((SELECT seq FROM public.s3_copy), (SELECT hash FROM public.s3_copy))) = 0);
SQL
