-- T. Account and entry types, account owners, and open_account().
-- Starting state (00_seed.sql): types funding, holder_funds, payee_payable,
-- clearing; entry types load, payment (+ built-in reversal); accounts 1-3.
SET search_path = tenant_alpha, ledger_shared;

-- Registration (run by the database owner, as in a migration)
SELECT ledger_shared.register_account_type('holder_funds', 'holder', false, 'Same rules, other wording');
SELECT testkit.ok('T1 registering an account type again with the same rules changes nothing',
  (SELECT count(*) FROM account_types) = 4
  AND (SELECT description FROM account_types WHERE code = 'holder_funds') = 'Funds held for a holder');
SELECT testkit.fails('T2 registering an account type again with different rules is rejected',
  $q$SELECT ledger_shared.register_account_type('holder_funds', 'holder', true, 'x')$q$, 'already registered with different rules');
SELECT testkit.fails('T3 type codes must be lowercase identifiers',
  $q$SELECT ledger_shared.register_account_type('Holder Funds', NULL, false, 'x')$q$, 'check constraint');
SELECT testkit.fails('T4 account types are append-only',
  $q$UPDATE account_types SET allow_negative = true WHERE code = 'holder_funds'$q$, 'append-only');
SELECT testkit.fails('T5 entry types are append-only',
  $q$DELETE FROM entry_types WHERE code = 'payment'$q$, 'append-only');
SELECT testkit.ok('T6 reversal is a built-in entry type',
  EXISTS (SELECT 1 FROM entry_types WHERE code = 'reversal'));

SET ROLE ledger_test_app;

-- open_account()
SELECT testkit.ok('T7 opening an existing account returns it (idempotent)',
  open_account('holder_funds', 'holder', 'h-1') = 2 AND open_account('funding') = 1);
SELECT testkit.ok('T8 a new owner gets a new account',
  open_account('holder_funds', 'holder', 'h-2') = 4);
SELECT testkit.fails('T9 an unregistered account type is rejected',
  $q$SELECT open_account('savings', 'holder', 'h-1')$q$, 'unknown account type|foreign key');
SELECT testkit.fails('T10 an owned type needs an owner',
  $q$SELECT open_account('holder_funds')$q$, 'must be owned by a holder');
SELECT testkit.fails('T11 the owner must be of the type''s owner type',
  $q$SELECT open_account('holder_funds', 'payee', 'p-1')$q$, 'must be owned by a holder');
SELECT testkit.fails('T12 a type with no owner refuses one',
  $q$SELECT open_account('funding', 'holder', 'h-1')$q$, 'have no owner');
SELECT testkit.fails('T13 owner type and owner ID come together',
  $q$SELECT open_account('holder_funds', 'holder', NULL)$q$, 'must be owned by a holder|check constraint');
SELECT testkit.fails('T14 owner IDs cannot contain control characters',
  format('SELECT open_account(%L, %L, %L)', 'holder_funds', 'holder', E'h\n1'), 'check constraint');

-- Entry types and overdraft rules come from the registry
SELECT testkit.fails('T15 an unregistered entry type is rejected',
  $q$SELECT post_entry('transfer','T15','x','2026-11-23','u1',
       '[{"account_id":2,"amount_cents":-100},{"account_id":4,"amount_cents":100}]')$q$, 'unknown entry type');
SELECT post_entry('load','T16','More funds','2026-11-23','sys',
  '[{"account_id":1,"amount_cents":-5000},{"account_id":4,"amount_cents":5000}]');
SELECT testkit.ok('T16 an account type that allows negative balances can go below zero',
  (SELECT balance_cents FROM account_balances WHERE account_id = 1) = -105000);
SELECT testkit.fails('T17 an account type that does not allow negative balances cannot overdraw',
  $q$SELECT post_entry('payment','T17','x','2026-11-23','u1',
       '[{"account_id":4,"amount_cents":-5001},{"account_id":3,"amount_cents":5001}]')$q$, 'insufficient funds');
SELECT testkit.fails('T18 lines must be a JSON array',
  $q$SELECT post_entry('payment','T18','x','2026-11-23','u1','{"account_id":2}')$q$, 'JSON array');
SELECT testkit.ok('T19 balances show each account''s type and owner',
  (SELECT string_agg(account_type || '/' || coalesce(owner_type, '-') || '/' || coalesce(owner_id, '-'), ',' ORDER BY account_id)
     FROM account_balances)
  = 'funding/-/-,holder_funds/holder/h-1,payee_payable/payee/p-1,holder_funds/holder/h-2');
RESET ROLE;

-- Hash encoding: fields cannot be shifted into each other
SELECT testkit.ok('T20 moving characters between neighbouring fields changes the hashed text',
  entry_canonical(1, 'payment', 'a|b', NULL, 'c', '2026-11-23', '2026-11-23', 'u1', '')
  <> entry_canonical(1, 'payment', 'a', NULL, 'b|c', '2026-11-23', '2026-11-23', 'u1', '')
  AND entry_canonical(1, 'payment', '3:abc,', NULL, '', '2026-11-23', '2026-11-23', 'u1', '')
  <> entry_canonical(1, 'payment', '', NULL, '3:abc,', '2026-11-23', '2026-11-23', 'u1', ''));
SELECT testkit.ok('T21 an empty field and a missing one hash differently',
  ledger_shared.ledger_field('') = '0:,' AND ledger_shared.ledger_field(NULL) = '-');
SELECT testkit.ok('T22 the chain verifies after the type and account tests',
  (SELECT count(*) FROM verify_chain((SELECT seq FROM public.s3_copy), (SELECT hash FROM public.s3_copy))) = 0);

-- Error codes applications can rely on
SET ROLE ledger_test_app;
SELECT testkit.ok('T23 each kind of rejection has its own SQLSTATE',
  testkit.sqlstate_of($q$SELECT post_entry('transfer','T23a','x','2026-11-23','u1','[{"account_id":2,"amount_cents":-1},{"account_id":3,"amount_cents":1}]')$q$) = 'LD001'
  AND testkit.sqlstate_of($q$SELECT post_entry('payment','T23b','x','2026-11-23','u1','[{"account_id":2,"amount_cents":-1}]')$q$) = 'LD002'
  AND testkit.sqlstate_of($q$SELECT post_entry('payment','T23c','x','2026-11-23','u1','[{"account_id":2,"amount_cents":-1},{"account_id":3,"amount_cents":2}]')$q$) = 'LD003'
  AND testkit.sqlstate_of($q$SELECT post_entry('payment','T23d','x','2026-11-23','u1','[{"account_id":2,"amount_cents":-9999999},{"account_id":3,"amount_cents":9999999}]')$q$) = 'LD004'
  AND testkit.sqlstate_of($q$SELECT post_entry('payment','PAY-1','x','2026-11-23','u1','[{"account_id":2,"amount_cents":-1},{"account_id":3,"amount_cents":1}]')$q$) = 'LD005'
  AND testkit.sqlstate_of($q$SELECT post_entry('reversal','T23f','x','2026-11-23','u1','[{"account_id":2,"amount_cents":-1},{"account_id":3,"amount_cents":1}]', 99)$q$) = 'LD006'
  AND testkit.sqlstate_of($q$SELECT open_account('holder_funds')$q$) = 'LD007'
  AND testkit.sqlstate_of($q$SELECT record_digest(99, 'x', 'y')$q$) = 'LD008');
RESET ROLE;
SELECT testkit.ok('T24 changing an append-only table and re-registering a type with other rules have their own SQLSTATEs',
  testkit.sqlstate_of($q$DELETE FROM postings WHERE sequence_no = 2$q$) = 'LD009'
  AND testkit.sqlstate_of($q$SELECT ledger_shared.register_account_type('funding', NULL, false, 'x')$q$) = 'LD010');
