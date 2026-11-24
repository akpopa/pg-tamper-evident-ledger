-- B. An administrator deletes entry #2 with protections switched off.
SET session_replication_role = replica;
DELETE FROM tenant_alpha.postings WHERE sequence_no = 2;
DELETE FROM tenant_alpha.journal_entries WHERE sequence_no = 2;
SET session_replication_role = origin;

SELECT testkit.ok('B deleting a middle entry is detected as a gap at #3',
  EXISTS (SELECT 1 FROM tenant_alpha.verify_chain()
          WHERE bad_seq = 3 AND problem LIKE 'gap in entry numbers%'));
