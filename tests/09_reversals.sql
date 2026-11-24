-- R. Reversals must mirror the original exactly, once.
-- Starting state: #1 load $1,000; #2-#4 payments of $100 (holder account 2
-- to payee account 3). Holder balance $700.
SET search_path = tenant_alpha, ledger_shared;
SET ROLE ledger_test_app;

SELECT testkit.ok('R1 a mirrored reversal of #4 is accepted',
  post_entry('reversal','REV-1','Reverse PAY-3','2026-11-20','u1',
             '[{"account_id":3,"amount_cents":-10000},{"account_id":2,"amount_cents":10000}]', 4) = 5);
SELECT testkit.ok('R2 the reversal restores the holder balance',
  (SELECT balance_cents FROM account_balances WHERE account_id = 2) = 80000);
SELECT testkit.ok('R3 retrying the same reversal returns the original entry',
  post_entry('reversal','REV-1','Reverse PAY-3','2026-11-20','u1',
             '[{"account_id":3,"amount_cents":-10000},{"account_id":2,"amount_cents":10000}]', 4) = 5);
SELECT testkit.fails('R4 a second reversal of the same entry is rejected',
  $q$SELECT post_entry('reversal','REV-2','again','2026-11-20','u1',
       '[{"account_id":3,"amount_cents":-10000},{"account_id":2,"amount_cents":10000}]', 4)$q$,
  'already reversed');
SELECT testkit.fails('R5 a reversal with a different amount is rejected',
  $q$SELECT post_entry('reversal','REV-3','x','2026-11-20','u1',
       '[{"account_id":3,"amount_cents":-5000},{"account_id":2,"amount_cents":5000}]', 3)$q$,
  'amounts negated');
SELECT testkit.fails('R6 a reversal to a different account is rejected',
  $q$SELECT post_entry('reversal','REV-4','x','2026-11-20','u1',
       '[{"account_id":3,"amount_cents":-10000},{"account_id":1,"amount_cents":10000}]', 3)$q$,
  'amounts negated');
SELECT testkit.fails('R7 a reversal with the same signs as the original is rejected',
  $q$SELECT post_entry('reversal','REV-5','x','2026-11-20','u1',
       '[{"account_id":2,"amount_cents":-10000},{"account_id":3,"amount_cents":10000}]', 3)$q$,
  'amounts negated');
SELECT testkit.fails('R8 reversing a reversal is rejected',
  $q$SELECT post_entry('reversal','REV-6','x','2026-11-20','u1',
       '[{"account_id":2,"amount_cents":-10000},{"account_id":3,"amount_cents":10000}]', 5)$q$,
  'itself a reversal');
SELECT testkit.fails('R9 reversing a missing entry is rejected',
  $q$SELECT post_entry('reversal','REV-7','x','2026-11-20','u1',
       '[{"account_id":2,"amount_cents":-10000},{"account_id":3,"amount_cents":10000}]', 99)$q$,
  'does not exist');
SELECT testkit.fails('R10 a reversal that names no entry is rejected',
  $q$SELECT post_entry('reversal','REV-8','x','2026-11-20','u1',
       '[{"account_id":2,"amount_cents":-10000},{"account_id":3,"amount_cents":10000}]')$q$,
  'does not exist');
SELECT testkit.ok('R11 line order does not matter for a valid reversal of #3',
  post_entry('reversal','REV-9','Reverse PAY-2','2026-11-20','u1',
             '[{"account_id":2,"amount_cents":10000},{"account_id":3,"amount_cents":-10000}]', 3) = 6);
SELECT testkit.fails('R12 a reversal that would overdraw an account is rejected',
  $q$SELECT post_entry('reversal','REV-10','Reverse load','2026-11-20','u1',
       '[{"account_id":1,"amount_cents":100000},{"account_id":2,"amount_cents":-100000}]', 1)$q$,
  'insufficient funds');
SELECT testkit.ok('R13 the chain verifies after the reversals',
  (SELECT count(*) FROM verify_chain((SELECT seq FROM public.s3_copy), (SELECT hash FROM public.s3_copy))) = 0
  AND (SELECT last_seq FROM chain_head) = 6);
