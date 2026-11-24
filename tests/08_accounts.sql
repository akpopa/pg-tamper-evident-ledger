-- G. Account ownership is protected and covered by the hash chain.
SET search_path = tenant_alpha, ledger_shared;

-- G1. With protections on, an administrator cannot reassign an account.
SELECT testkit.fails('G1 reassigning an account to another owner is blocked',
  $q$UPDATE accounts SET owner_id = 'h-2' WHERE account_id = 2$q$, 'append-only');

-- G2. With protections off, the reassignment succeeds but breaks the chain:
--     entry #1 (the first one touching account 2) no longer matches its hash.
SET session_replication_role = replica;
UPDATE accounts SET owner_id = 'h-2' WHERE account_id = 2;
SET session_replication_role = origin;
SELECT testkit.ok('G2 an account reassigned with protections off is detected',
  EXISTS (SELECT 1 FROM verify_chain() WHERE bad_seq = 1 AND problem = 'entry contents changed'));

-- G3. Changing an account's type (and dropping its owner) is detected the same way.
SET session_replication_role = replica;
UPDATE accounts SET owner_id = 'h-1' WHERE account_id = 2;  -- undo G2
UPDATE accounts SET account_type = 'clearing', owner_type = NULL, owner_id = NULL WHERE account_id = 3;
SET session_replication_role = origin;
SELECT testkit.ok('G3 a changed account type is detected',
  EXISTS (SELECT 1 FROM verify_chain() WHERE bad_seq = 2 AND problem = 'entry contents changed'));

-- G4. Changing only the owner type is detected too.
SET session_replication_role = replica;
UPDATE accounts SET account_type = 'payee_payable', owner_type = 'payee', owner_id = 'p-1' WHERE account_id = 3;  -- undo G3
UPDATE accounts SET owner_type = 'payee' WHERE account_id = 2;
SET session_replication_role = origin;
SELECT testkit.ok('G4 a changed owner type is detected',
  EXISTS (SELECT 1 FROM verify_chain() WHERE bad_seq = 1 AND problem = 'entry contents changed'));
