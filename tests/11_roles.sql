-- K. Ledger roles: each role can do exactly its job. Test logins are created
-- here (roles are cluster-wide).
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'k_reader') THEN CREATE ROLE k_reader LOGIN; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'k_poster') THEN CREATE ROLE k_poster LOGIN; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'k_opener') THEN CREATE ROLE k_opener LOGIN; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'k_digest') THEN CREATE ROLE k_digest LOGIN; END IF;
END $$;
GRANT ledger_reader TO k_reader;
GRANT ledger_poster TO k_poster;
GRANT ledger_account_opener TO k_opener;
GRANT ledger_digest_writer TO k_digest;
SET search_path = tenant_alpha, ledger_shared;

SET ROLE k_reader;
SELECT testkit.ok('K1 ledger_reader can read balances and verify the chain',
  (SELECT count(*) FROM account_balances) = 3 AND (SELECT count(*) FROM verify_chain()) = 0);
SELECT testkit.ok('K2 ledger_reader can read the type registry',
  (SELECT count(*) FROM ledger_shared.account_types) = 4 AND (SELECT count(*) FROM ledger_shared.entry_types) = 3);
SELECT testkit.fails('K3 ledger_reader cannot post entries',
  $q$SELECT post_entry('payment','K3','x','2026-11-23','u1',
       '[{"account_id":2,"amount_cents":-100},{"account_id":3,"amount_cents":100}]')$q$, 'permission denied');
SELECT testkit.fails('K4 ledger_reader cannot record digests',
  $q$SELECT record_digest(4, 'k', 'v')$q$, 'permission denied');
SELECT testkit.fails('K5 ledger_reader cannot open accounts',
  $q$SELECT open_account('holder_funds', 'holder', 'h-k5')$q$, 'permission denied');
RESET ROLE;

SET ROLE k_poster;
SELECT testkit.ok('K6 ledger_poster can post entries',
  post_entry('payment','K6','x','2026-11-23','u1',
    '[{"account_id":2,"amount_cents":-100},{"account_id":3,"amount_cents":100}]') = 5);
SELECT testkit.fails('K7 ledger_poster cannot read ledger tables',
  $q$SELECT count(*) FROM journal_entries$q$, 'permission denied');
SELECT testkit.fails('K8 ledger_poster cannot record digests',
  $q$SELECT record_digest(4, 'k', 'v')$q$, 'permission denied');
SELECT testkit.fails('K9 ledger_poster cannot open accounts',
  $q$SELECT open_account('holder_funds', 'holder', 'h-k9')$q$, 'permission denied');
RESET ROLE;

SET ROLE k_opener;
SELECT testkit.ok('K10 ledger_account_opener can open accounts',
  open_account('holder_funds', 'holder', 'h-k10') = 4);
SELECT testkit.fails('K11 ledger_account_opener cannot post entries',
  $q$SELECT post_entry('payment','K11','x','2026-11-23','u1',
       '[{"account_id":2,"amount_cents":-100},{"account_id":3,"amount_cents":100}]')$q$, 'permission denied');
SELECT testkit.fails('K12 ledger_account_opener cannot read ledger tables',
  $q$SELECT count(*) FROM accounts$q$, 'permission denied');
RESET ROLE;

SET ROLE k_digest;
SELECT testkit.ok('K13 ledger_digest_writer can record a digest',
  record_digest(4, 's3://ledger-anchors/tenant_alpha/digest-000004.json', 'v-k13') IS NOT NULL);
SELECT testkit.fails('K14 ledger_digest_writer cannot post entries',
  $q$SELECT post_entry('payment','K14','x','2026-11-23','u1',
       '[{"account_id":2,"amount_cents":-100},{"account_id":3,"amount_cents":100}]')$q$, 'permission denied');
RESET ROLE;

SELECT testkit.ok('K15 no ledger role can write ledger tables or the type registry directly',
  NOT EXISTS (
    SELECT 1 FROM information_schema.role_table_grants
    WHERE table_schema IN ('tenant_alpha', 'ledger_shared')
      AND grantee IN ('ledger_reader','ledger_poster','ledger_account_opener','ledger_digest_writer','PUBLIC')
      AND privilege_type IN ('INSERT','UPDATE','DELETE','TRUNCATE')));
SELECT testkit.ok('K16 only the database owner can register types',
  NOT has_function_privilege('ledger_reader', 'ledger_shared.register_account_type(text, text, boolean, text)', 'EXECUTE')
  AND NOT has_function_privilege('ledger_poster', 'ledger_shared.register_entry_type(text, text)', 'EXECUTE')
  AND NOT has_function_privilege('ledger_account_opener', 'ledger_shared.register_account_type(text, text, boolean, text)', 'EXECUTE'));
SELECT testkit.ok('K17 ledger_reader can read exactly the ledger tables and view',
  (SELECT string_agg(table_name::text, ',' ORDER BY table_name) FROM information_schema.role_table_grants
   WHERE table_schema = 'tenant_alpha' AND grantee = 'ledger_reader' AND privilege_type = 'SELECT')
  = 'account_balances,accounts,chain_head,journal_entries,ledger_digests,postings');
SELECT testkit.ok('K18 the chain verifies after the role tests',
  (SELECT count(*) FROM verify_chain()) = 0);

-- The owner role: SECURITY DEFINER functions run with limited rights
SELECT testkit.ok('K19 every ledger table, view and function is owned by ledger_owner',
  NOT EXISTS (SELECT 1 FROM pg_class c
               WHERE c.relnamespace IN ('tenant_alpha'::regnamespace, 'ledger_shared'::regnamespace)
                 AND c.relkind IN ('r', 'v') AND c.relname NOT IN ('s3_copy')
                 AND pg_get_userbyid(c.relowner) <> 'ledger_owner')
  AND NOT EXISTS (SELECT 1 FROM pg_proc p
                   WHERE p.pronamespace IN ('tenant_alpha'::regnamespace, 'ledger_shared'::regnamespace)
                     AND pg_get_userbyid(p.proowner) <> 'ledger_owner'));
SELECT testkit.ok('K20 ledger_owner cannot log in and has no administrator powers',
  EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ledger_owner'
            AND NOT (rolsuper OR rolcanlogin OR rolcreaterole OR rolcreatedb OR rolreplication OR rolbypassrls)));
SELECT testkit.ok('K21 no SECURITY DEFINER function in the ledger is owned by a superuser',
  NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner
               WHERE p.pronamespace IN ('tenant_alpha'::regnamespace, 'ledger_shared'::regnamespace)
                 AND p.prosecdef AND r.rolsuper));
SELECT testkit.ok('K22 no ledger role is a member of ledger_owner',
  NOT EXISTS (SELECT 1 FROM pg_auth_members m
               WHERE m.roleid = 'ledger_owner'::regrole
                 AND m.member IN ('ledger_reader'::regrole, 'ledger_poster'::regrole,
                                  'ledger_account_opener'::regrole, 'ledger_digest_writer'::regrole,
                                  'ledger_test_app'::regrole)));
SET ROLE ledger_test_app;
SELECT testkit.ok('K23 post_entry() still works when called through a ledger role',
  post_entry('payment', 'K23', 'x', '2026-11-23', 'u1',
    '[{"account_id":2,"amount_cents":-100},{"account_id":3,"amount_cents":100}]') > 0);
RESET ROLE;
