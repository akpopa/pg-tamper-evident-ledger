-- E. Input validation, retries and timestamps: every rejection carries a
-- ledger SQLSTATE, a retry must match the original, and timestamps the hash
-- cannot represent are refused on input and reported by verify_chain().
-- Starting state (00_seed.sql): accounts 1-3, entries #1-#4, digest at #3.
SET search_path = tenant_alpha, ledger_shared;
SET ROLE ledger_test_app;

-- Entry fields (LD012)
SELECT testkit.ok('E1 effective_at of infinity is rejected (LD012)',
  testkit.sqlstate_of($q$SELECT post_entry('load', 'H1', 'x', 'infinity', 'u',
    '[{"account_id":1,"amount_cents":-1},{"account_id":2,"amount_cents":1}]')$q$) = 'LD012');
SELECT testkit.ok('E2 effective_at of -infinity is rejected (LD012)',
  testkit.sqlstate_of($q$SELECT post_entry('load', 'H2', 'x', '-infinity', 'u',
    '[{"account_id":1,"amount_cents":-1},{"account_id":2,"amount_cents":1}]')$q$) = 'LD012');
SELECT testkit.ok('E3 a BC effective_at is rejected (LD012)',
  testkit.sqlstate_of($q$SELECT post_entry('load', 'H3', 'x', '0044-03-15 00:00:00+00 BC', 'u',
    '[{"account_id":1,"amount_cents":-1},{"account_id":2,"amount_cents":1}]')$q$) = 'LD012');
SELECT testkit.ok('E4 an effective_at after year 9999 is rejected (LD012)',
  testkit.sqlstate_of($q$SELECT post_entry('load', 'H4', 'x', '10000-01-01', 'u',
    '[{"account_id":1,"amount_cents":-1},{"account_id":2,"amount_cents":1}]')$q$) = 'LD012');
SELECT testkit.ok('E5 NULL effective_at, description or recorded_by, and an empty external_ref, are rejected (LD012)',
  testkit.sqlstate_of($q$SELECT post_entry('load', 'H5a', 'x', NULL, 'u',
    '[{"account_id":1,"amount_cents":-1},{"account_id":2,"amount_cents":1}]')$q$) = 'LD012'
  AND testkit.sqlstate_of($q$SELECT post_entry('load', 'H5b', NULL, now(), 'u',
    '[{"account_id":1,"amount_cents":-1},{"account_id":2,"amount_cents":1}]')$q$) = 'LD012'
  AND testkit.sqlstate_of($q$SELECT post_entry('load', 'H5c', 'x', now(), NULL,
    '[{"account_id":1,"amount_cents":-1},{"account_id":2,"amount_cents":1}]')$q$) = 'LD012'
  AND testkit.sqlstate_of($q$SELECT post_entry('load', '', 'x', now(), 'u',
    '[{"account_id":1,"amount_cents":-1},{"account_id":2,"amount_cents":1}]')$q$) = 'LD012');
SELECT testkit.ok('E6 the first and last supported years are accepted',
  post_entry('load', 'H6a', 'x', '0001-01-01 00:00:00+00', 'u',
    '[{"account_id":1,"amount_cents":-1},{"account_id":2,"amount_cents":1}]') = 5
  AND post_entry('load', 'H6b', 'x', '9999-12-31 23:59:59.999999+00', 'u',
    '[{"account_id":1,"amount_cents":-1},{"account_id":2,"amount_cents":1}]') = 6);

-- Malformed lines (LD002, never a cast error)
SELECT testkit.ok('E7 a fractional amount is rejected (LD002)',
  testkit.sqlstate_of($q$SELECT post_entry('load', 'H7', 'x', now(), 'u',
    '[{"account_id":1,"amount_cents":-1.5},{"account_id":2,"amount_cents":1.5}]')$q$) = 'LD002');
SELECT testkit.ok('E8 an amount given as a string is rejected (LD002)',
  testkit.sqlstate_of($q$SELECT post_entry('load', 'H8', 'x', now(), 'u',
    '[{"account_id":1,"amount_cents":"-1"},{"account_id":2,"amount_cents":"1"}]')$q$) = 'LD002');
SELECT testkit.ok('E9 an amount beyond the bigint range is rejected (LD002)',
  testkit.sqlstate_of($q$SELECT post_entry('load', 'H9', 'x', now(), 'u',
    '[{"account_id":1,"amount_cents":-99999999999999999999},{"account_id":2,"amount_cents":99999999999999999999}]')$q$) = 'LD002');
SELECT testkit.ok('E10 an account_id that is not an integer is rejected (LD002)',
  testkit.sqlstate_of($q$SELECT post_entry('load', 'H10', 'x', now(), 'u',
    '[{"account_id":"one","amount_cents":-1},{"account_id":2,"amount_cents":1}]')$q$) = 'LD002');
SELECT testkit.ok('E11 a line that is not an object is rejected (LD002)',
  testkit.sqlstate_of($q$SELECT post_entry('load', 'H11', 'x', now(), 'u',
    '[[1,-1],{"account_id":2,"amount_cents":1}]')$q$) = 'LD002');
SELECT testkit.ok('E12 more than 32767 lines is rejected (LD002)',
  testkit.sqlstate_of(format('SELECT post_entry(%L, %L, %L, now(), %L, %L)', 'load', 'H12', 'x', 'u',
    (SELECT jsonb_agg(jsonb_build_object('account_id', 1, 'amount_cents', 1)) FROM generate_series(1, 32768)))) = 'LD002');

-- Retries (LD005)
SELECT testkit.ok('E13 a retry with a different description is rejected (LD005)',
  testkit.sqlstate_of($q$SELECT post_entry('load', 'LOAD-1', 'Different', '2026-11-19', 'sys',
    '[{"account_id":1,"amount_cents":-100000},{"account_id":2,"amount_cents":100000}]')$q$) = 'LD005');
SELECT testkit.ok('E14 a retry with a different effective_at is rejected (LD005)',
  testkit.sqlstate_of($q$SELECT post_entry('load', 'LOAD-1', 'Initial funds', '2026-11-20', 'sys',
    '[{"account_id":1,"amount_cents":-100000},{"account_id":2,"amount_cents":100000}]')$q$) = 'LD005');
SELECT testkit.ok('E15 a retry from another worker (different recorded_by) returns the original entry',
  post_entry('load', 'LOAD-1', 'Initial funds', '2026-11-19', 'worker-2',
    '[{"account_id":1,"amount_cents":-100000},{"account_id":2,"amount_cents":100000}]') = 1);
SELECT testkit.ok('E16 a retry with an extra malformed line is rejected, not matched to the original (LD002)',
  testkit.sqlstate_of($q$SELECT post_entry('load', 'LOAD-1', 'Initial funds', '2026-11-19', 'sys',
    '[{"account_id":1,"amount_cents":-100000},{"account_id":2,"amount_cents":100000},{"account_id":"x"}]')$q$) = 'LD002');

-- Digests (LD011)
SELECT testkit.ok('E17 recording the same digest again returns its hash',
  record_digest(3, 's3://ledger-anchors/tenant_alpha/digest-000003.json', 'v-abc')
    = (SELECT entry_hash FROM journal_entries WHERE sequence_no = 3));
SELECT testkit.ok('E18 a different anchor for an entry that already has a digest is rejected (LD011)',
  testkit.sqlstate_of($q$SELECT record_digest(3, 's3://elsewhere/digest.json', 'v-xyz')$q$) = 'LD011');

SELECT testkit.ok('E19 nothing rejected above left a trace; the chain verifies',
  (SELECT count(*) FROM journal_entries) = 6 AND NOT EXISTS (SELECT 1 FROM verify_chain()));
RESET ROLE;

-- Tampering that the hash cannot see is still reported. The hashed text has no
-- era and no infinity, so these edits leave every hash valid.
ALTER TABLE journal_entries DROP CONSTRAINT journal_entries_effective_at_check;
SET session_replication_role = replica;
UPDATE journal_entries SET effective_at = '2026-11-19 00:00:00+00 BC' WHERE sequence_no = 2;
SET session_replication_role = origin;
SELECT testkit.ok('E20 an AD date moved to the same date BC is reported by verify_chain()',
  (SELECT bad_seq || ' ' || problem FROM verify_chain()) = '2 timestamp outside years 1-9999 (not covered by the hash)');
SET session_replication_role = replica;
UPDATE journal_entries SET effective_at = '2026-11-19' WHERE sequence_no = 2;
UPDATE journal_entries SET effective_at = '-infinity' WHERE sequence_no = 3;
SET session_replication_role = origin;
SELECT testkit.ok('E21 an infinite effective_at is reported by verify_chain()',
  (SELECT bad_seq || ' ' || problem FROM verify_chain()) = '3 timestamp outside years 1-9999 (not covered by the hash)');
