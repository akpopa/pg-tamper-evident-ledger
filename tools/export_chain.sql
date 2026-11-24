-- Exports one tenant's chain as JSON lines, for tools/verify_chain.py.
--
--   psql -X -q -At -v tenant=tenant_alpha -f tools/export_chain.sql > chain.jsonl
--
-- Needs ledger_reader. The first line describes the tenant and its chain
-- head; each following line is one entry with its posting lines and the
-- type and owner of each line's account (both are part of the hash).
SELECT json_build_object(
  'tenant', :'tenant',
  'format', 'ledger-v2',
  'head_seq', last_seq,
  'head_hash', encode(last_hash, 'hex'))
FROM :"tenant".chain_head;

SELECT json_build_object(
  'seq',          e.sequence_no,
  'entry_type',   e.entry_type,
  'external_ref', e.external_ref,
  'reverses_seq', e.reverses_seq,
  'description',  e.description,
  -- Outside years 1-9999 the hashed form is ambiguous, so such a timestamp is
  -- exported in PostgreSQL's own text form (for example 'infinity' or a BC
  -- date) and the verifier reports it.
  'effective_at', CASE WHEN ledger_shared.ledger_time_ok(e.effective_at)
                       THEN to_char(e.effective_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
                       ELSE e.effective_at::text END,
  'recorded_at',  CASE WHEN ledger_shared.ledger_time_ok(e.recorded_at)
                       THEN to_char(e.recorded_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
                       ELSE e.recorded_at::text END,
  'recorded_by',  e.recorded_by,
  'prev_hash',    encode(e.prev_hash, 'hex'),
  'entry_hash',   encode(e.entry_hash, 'hex'),
  'lines', (SELECT json_agg(json_build_object(
                     'line_no', p.line_no, 'account_id', p.account_id,
                     'account_type', a.account_type, 'owner_type', a.owner_type, 'owner_id', a.owner_id,
                     'amount_cents', p.amount_cents) ORDER BY p.line_no)
              FROM :"tenant".postings p JOIN :"tenant".accounts a USING (account_id)
             WHERE p.sequence_no = e.sequence_no))
FROM :"tenant".journal_entries e
ORDER BY e.sequence_no;
