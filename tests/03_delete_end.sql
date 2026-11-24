-- C. An administrator deletes the newest entries and covers the tracks.
-- C1. Delete #4 (never covered by a digest) and move the chain head back.
SET session_replication_role = replica;
DELETE FROM tenant_alpha.postings WHERE sequence_no = 4;
DELETE FROM tenant_alpha.journal_entries WHERE sequence_no = 4;
UPDATE tenant_alpha.chain_head SET last_seq = 3,
  last_hash = (SELECT entry_hash FROM tenant_alpha.journal_entries WHERE sequence_no = 3);
SET session_replication_role = origin;

-- Known limitation (the "unanchored window" in ADR-0001): nothing can prove
-- #4 existed, so this check confirms the ledger does NOT report it.
SELECT testkit.ok('C1 deleting an entry newer than the last digest is not detectable (documented limitation)',
  (SELECT count(*) FROM tenant_alpha.verify_chain()) = 0);

-- C2. Also delete #3, its digest row, and move the head to #2.
SET session_replication_role = replica;
DELETE FROM tenant_alpha.ledger_digests WHERE up_to_seq = 3;
DELETE FROM tenant_alpha.postings WHERE sequence_no = 3;
DELETE FROM tenant_alpha.journal_entries WHERE sequence_no = 3;
UPDATE tenant_alpha.chain_head SET last_seq = 2,
  last_hash = (SELECT entry_hash FROM tenant_alpha.journal_entries WHERE sequence_no = 2);
SET session_replication_role = origin;

SELECT testkit.ok('C2 without the S3 anchor the deletion passes internal checks',
  (SELECT count(*) FROM tenant_alpha.verify_chain()) = 0);
SELECT testkit.ok('C3 with the S3 anchor the deleted entry is detected',
  EXISTS (SELECT 1 FROM tenant_alpha.verify_chain((SELECT seq FROM public.s3_copy), (SELECT hash FROM public.s3_copy))
          WHERE bad_seq = 3 AND problem = 'entry covered by the outside digest is missing'));
