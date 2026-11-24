-- A. Normal operation and input validation.
-- Starting state (00_seed.sql): entries #1-#4, digest at #3.
-- Balances: funding -$1,000, holder $700, payee $300.
SET search_path = tenant_alpha, ledger_shared;
SET ROLE ledger_test_app;

SELECT testkit.ok('A1 clean ledger verifies without the S3 anchor',
  (SELECT count(*) FROM verify_chain()) = 0);
SELECT testkit.ok('A2 clean ledger verifies with the S3 anchor',
  (SELECT count(*) FROM verify_chain((SELECT seq FROM public.s3_copy), (SELECT hash FROM public.s3_copy))) = 0);
SELECT testkit.ok('A3 balances are derived from postings',
  (SELECT array_agg(balance_cents ORDER BY account_id) FROM account_balances) = ARRAY[-100000, 70000, 30000]::numeric[]);

SELECT testkit.ok('A4 a true retry returns the original entry',
  post_entry('payment','PAY-1','Item A','2026-11-19','u1',
             '[{"account_id":2,"amount_cents":-10000},{"account_id":3,"amount_cents":10000}]') = 2);
SELECT testkit.fails('A5 reusing a reference with different contents is rejected',
  $q$SELECT post_entry('payment','PAY-1','Item A','2026-11-19','u1',
       '[{"account_id":2,"amount_cents":-50000},{"account_id":3,"amount_cents":50000}]')$q$,
  'already used for a different entry');
SELECT testkit.fails('A6 an unbalanced entry is rejected',
  $q$SELECT post_entry('payment','PAY-A6','x','2026-11-19','u1',
       '[{"account_id":2,"amount_cents":-10000},{"account_id":3,"amount_cents":9000}]')$q$,
  'does not balance');
SELECT testkit.fails('A7 a single-line entry is rejected',
  $q$SELECT post_entry('payment','PAY-A7','x','2026-11-19','u1',
       '[{"account_id":2,"amount_cents":-10000}]')$q$,
  'at least two lines');
SELECT testkit.fails('A8 an overdraft is rejected',
  $q$SELECT post_entry('payment','PAY-A8','x','2026-11-19','u1',
       '[{"account_id":2,"amount_cents":-80000},{"account_id":3,"amount_cents":80000}]')$q$,
  'insufficient funds');
SELECT testkit.fails('A9 a line with an unknown account is rejected',
  $q$SELECT post_entry('payment','PAY-A9','x','2026-11-19','u1',
       '[{"account_id":2,"amount_cents":-100},{"account_id":99,"amount_cents":100}]')$q$,
  'existing account_id');
SELECT testkit.fails('A10 only a reversal may reference another entry',
  $q$SELECT post_entry('payment','PAY-A10','x','2026-11-19','u1',
       '[{"account_id":2,"amount_cents":-100},{"account_id":3,"amount_cents":100}]', 1)$q$,
  'only a reversal');
SELECT testkit.fails('A11 a digest for a missing entry is rejected',
  $q$SELECT record_digest(99, 'x', 'y')$q$, 'does not exist');

SELECT testkit.fails('A12 the app cannot insert into journal_entries directly',
  $q$INSERT INTO journal_entries VALUES (5,'payment','X',NULL,'x',now(),now(),'u1','\x00','\x00')$q$,
  'permission denied');
SELECT testkit.fails('A13 the app cannot write ledger_digests directly',
  $q$INSERT INTO ledger_digests VALUES (4, '\x00', 'x', 'y')$q$, 'permission denied');
SELECT testkit.fails('A14 the app cannot change accounts',
  $q$UPDATE accounts SET owner_id = 'h-2' WHERE account_id = 2$q$, 'permission denied');

RESET ROLE;   -- an administrator, with protections left on
SELECT testkit.fails('A15 an administrator cannot update a journal entry',
  $q$UPDATE journal_entries SET description = 'edited' WHERE sequence_no = 2$q$, 'append-only');
SELECT testkit.fails('A16 an administrator cannot delete postings',
  $q$DELETE FROM postings WHERE sequence_no = 2$q$, 'append-only');
SELECT testkit.fails('A17 an administrator cannot truncate the ledger',
  $q$TRUNCATE postings, journal_entries CASCADE$q$, 'append-only');
SELECT testkit.fails('A18 an administrator cannot reassign an account',
  $q$UPDATE accounts SET owner_id = 'h-2' WHERE account_id = 2$q$, 'append-only');

SELECT testkit.ok('A19 rejected attempts left no trace (4 entries, chain intact)',
  (SELECT count(*) FROM journal_entries) = 4
  AND (SELECT last_seq FROM chain_head) = 4
  AND (SELECT count(*) FROM verify_chain()) = 0);
