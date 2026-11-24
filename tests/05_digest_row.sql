-- E. An administrator edits only the recorded digest row.
SET session_replication_role = replica;
UPDATE tenant_alpha.ledger_digests SET entry_hash = sha256('\x01');
SET session_replication_role = origin;

SELECT testkit.ok('E an edited digest row is detected',
  EXISTS (SELECT 1 FROM tenant_alpha.verify_chain()
          WHERE bad_seq = 3 AND problem = 'entry no longer matches its recorded digest'));
