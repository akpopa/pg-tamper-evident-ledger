-- F. An administrator points the chain head at the wrong entry.
SET session_replication_role = replica;
UPDATE tenant_alpha.chain_head SET last_seq = 7;
SET session_replication_role = origin;

SELECT testkit.ok('F a misplaced chain head is detected',
  EXISTS (SELECT 1 FROM tenant_alpha.verify_chain()
          WHERE bad_seq = 7 AND problem LIKE 'chain head (#7) does not match the last entry (#4)%'));
