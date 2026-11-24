-- D. An administrator changes #2 to $50 and recomputes every later hash,
--    the chain head and the digest row, so the chain is internally consistent.
SET session_replication_role = replica;
SET search_path = tenant_alpha, ledger_shared;
UPDATE postings SET amount_cents = -5000 WHERE sequence_no = 2 AND line_no = 1;
UPDATE postings SET amount_cents =  5000 WHERE sequence_no = 2 AND line_no = 2;
DO $$
DECLARE e record; v_prev bytea; v_new bytea;
BEGIN
  SELECT entry_hash INTO v_prev FROM journal_entries WHERE sequence_no = 1;
  FOR e IN SELECT * FROM journal_entries WHERE sequence_no >= 2 ORDER BY sequence_no LOOP
    v_new := sha256(v_prev || convert_to(entry_canonical(e.sequence_no, e.entry_type, e.external_ref,
               e.reverses_seq, e.description, e.effective_at, e.recorded_at, e.recorded_by,
               entry_lines(e.sequence_no)), 'UTF8'));
    UPDATE journal_entries SET prev_hash = v_prev, entry_hash = v_new WHERE sequence_no = e.sequence_no;
    v_prev := v_new;
  END LOOP;
  UPDATE chain_head SET last_hash = v_prev;
  UPDATE ledger_digests SET entry_hash = (SELECT entry_hash FROM journal_entries WHERE sequence_no = 3);
END $$;
SET session_replication_role = origin;

SELECT testkit.ok('D1 without the S3 anchor the rewritten chain passes internal checks',
  (SELECT count(*) FROM verify_chain()) = 0);
SELECT testkit.ok('D2 with the S3 anchor the rewrite is detected',
  EXISTS (SELECT 1 FROM verify_chain((SELECT seq FROM public.s3_copy), (SELECT hash FROM public.s3_copy))
          WHERE bad_seq = 3 AND problem LIKE '%chain was rewritten%'));
