-- Seed for every test file: account and entry types, three accounts, a
-- $1,000 load, then three $100 payments (entries #1-#4); digest recorded at #3.
--
-- The types are a neutral example, like an application would register:
--   funding        the application's own source of funds (no owner, may go negative)
--   holder_funds   money held for a holder (owner type 'holder')
--   payee_payable  money owed to a payee (owner type 'payee')
--   clearing       a settlement account (no owner, may go negative)
SET search_path = tenant_alpha, ledger_shared;
SET client_min_messages = warning;
SELECT ledger_shared.register_account_type('funding',       NULL,     true,  'Source of funds');
SELECT ledger_shared.register_account_type('holder_funds',  'holder', false, 'Funds held for a holder');
SELECT ledger_shared.register_account_type('payee_payable', 'payee',  false, 'Amounts owed to a payee');
SELECT ledger_shared.register_account_type('clearing',      NULL,     true,  'Settlement clearing');
SELECT ledger_shared.register_entry_type('load',    'Funds added for a holder');
SELECT ledger_shared.register_entry_type('payment', 'A holder pays a payee');

-- A test application login holding every ledger role (roles are cluster-wide).
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'ledger_test_app') THEN
    CREATE ROLE ledger_test_app LOGIN;
  END IF;
END $$;
GRANT ledger_reader, ledger_poster, ledger_account_opener, ledger_digest_writer TO ledger_test_app;
SET ROLE ledger_test_app;
SELECT open_account('funding');                          -- account 1
SELECT open_account('holder_funds', 'holder', 'h-1');    -- account 2
SELECT open_account('payee_payable', 'payee', 'p-1');    -- account 3
SELECT post_entry('load','LOAD-1','Initial funds','2026-11-19','sys','[{"account_id":1,"amount_cents":-100000},{"account_id":2,"amount_cents":100000}]');
SELECT post_entry('payment','PAY-1','Item A','2026-11-19','u1','[{"account_id":2,"amount_cents":-10000},{"account_id":3,"amount_cents":10000}]');
SELECT post_entry('payment','PAY-2','Item B','2026-11-19','u1','[{"account_id":2,"amount_cents":-10000},{"account_id":3,"amount_cents":10000}]');
SELECT record_digest(3, 's3://ledger-anchors/tenant_alpha/digest-000003.json', 'v-abc');
SELECT post_entry('payment','PAY-3','Item C','2026-11-19','u1','[{"account_id":2,"amount_cents":-10000},{"account_id":3,"amount_cents":10000}]');
RESET ROLE;
-- Simulates the outside copy: the hash of entry #3 saved where nobody can change it
CREATE TABLE public.s3_copy AS SELECT up_to_seq AS seq, entry_hash AS hash FROM tenant_alpha.ledger_digests;
GRANT SELECT ON public.s3_copy TO ledger_test_app;
