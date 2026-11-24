-- Core layer, per-tenant ledger (v0.3.0). Each tenant is its own schema with
-- its own hash chain. scripts/migrate.sh replaces ${tenant} with the tenant
-- name (already validated as a lowercase schema name). The name also seeds
-- the chain's genesis hash.
--
-- Amounts are integers in the currency's smallest unit (cents for USD). One
-- tenant holds one currency.

CREATE SCHEMA ${tenant};
SET search_path = ${tenant}, ledger_shared;

------------------------------------------------------------------------------
-- Tables
------------------------------------------------------------------------------

-- An account is identified by its type and its owner. Owners live in the
-- application's own tables; the ledger records only their type and ID. An
-- application that wants foreign keys to its owners keeps a link table on its
-- side (docs/integration-guide.md).
CREATE TABLE accounts (
  account_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  account_type  text NOT NULL REFERENCES ledger_shared.account_types,
  owner_type    text,
  owner_id      text CHECK (length(owner_id) BETWEEN 1 AND 200 AND owner_id !~ '[[:cntrl:]]'),
  opened_at     timestamptz NOT NULL DEFAULT now(),
  CHECK ((owner_type IS NULL) = (owner_id IS NULL))
);
-- At most one account per type and owner (and one per type for accounts with
-- no owner). open_account() relies on this to be idempotent.
CREATE UNIQUE INDEX accounts_identity
  ON accounts (account_type, (coalesce(owner_type, '')), (coalesce(owner_id, '')));
CREATE INDEX accounts_by_owner ON accounts (owner_type, owner_id);

-- The owner must match the account type's rule.
CREATE FUNCTION accounts_check_owner() RETURNS trigger
LANGUAGE plpgsql SET search_path = ${tenant}, ledger_shared, pg_temp AS $$
DECLARE v_owner_type text;
BEGIN
  SELECT owner_type INTO v_owner_type FROM ledger_shared.account_types WHERE code = NEW.account_type;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'LD007', MESSAGE = format('unknown account type %s', NEW.account_type);
  END IF;
  IF v_owner_type IS NULL AND NEW.owner_type IS NOT NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'LD007', MESSAGE = format('accounts of type %s have no owner', NEW.account_type);
  END IF;
  IF v_owner_type IS NOT NULL AND (NEW.owner_type IS DISTINCT FROM v_owner_type OR NEW.owner_id IS NULL) THEN
    RAISE EXCEPTION USING ERRCODE = 'LD007', MESSAGE = format('accounts of type %s must be owned by a %s', NEW.account_type, v_owner_type);
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER acct_check_owner BEFORE INSERT ON accounts FOR EACH ROW EXECUTE FUNCTION accounts_check_owner();

-- Accounts are never edited or deleted: reassigning an account's owner would
-- silently move its history. Type and owner are also part of the hashed entry
-- text (see posting_line), so a change made with triggers off is still detected.
CREATE TRIGGER acct_no_update   BEFORE UPDATE OR DELETE ON accounts FOR EACH ROW       EXECUTE FUNCTION ledger_shared.forbid_change();
CREATE TRIGGER acct_no_truncate BEFORE TRUNCATE         ON accounts FOR EACH STATEMENT EXECUTE FUNCTION ledger_shared.forbid_change();

CREATE TABLE journal_entries (
  sequence_no   bigint PRIMARY KEY,                  -- gapless, assigned under the chain lock
  entry_type    text NOT NULL REFERENCES ledger_shared.entry_types,
  external_ref  text NOT NULL UNIQUE                 -- idempotency key chosen by the application
                  CHECK (length(external_ref) BETWEEN 1 AND 200),
  reverses_seq  bigint REFERENCES journal_entries,
  description   text NOT NULL,
  effective_at  timestamptz NOT NULL,                -- business date
  recorded_at   timestamptz NOT NULL,                -- when it was written
  recorded_by   text NOT NULL CHECK (length(recorded_by) BETWEEN 1 AND 200),  -- the application's user or process ID
  prev_hash     bytea NOT NULL CHECK (length(prev_hash) = 32),
  entry_hash    bytea NOT NULL UNIQUE CHECK (length(entry_hash) = 32),
  CHECK ((entry_type = 'reversal') = (reverses_seq IS NOT NULL)),
  -- The hashed text cannot tell BC from AD or one infinity from the other
  -- (see ledger_shared.ledger_time_ok); verify_chain() also checks this range.
  CHECK (ledger_shared.ledger_time_ok(effective_at)),
  CHECK (ledger_shared.ledger_time_ok(recorded_at))
);
CREATE UNIQUE INDEX one_reversal_per_entry ON journal_entries (reverses_seq) WHERE reverses_seq IS NOT NULL;

CREATE TABLE postings (
  sequence_no   bigint   NOT NULL REFERENCES journal_entries,
  line_no       smallint NOT NULL,
  account_id    bigint   NOT NULL REFERENCES accounts,
  amount_cents  bigint   NOT NULL CHECK (amount_cents <> 0),  -- + money in, - money out (smallest currency unit)
  PRIMARY KEY (sequence_no, line_no)
);
-- Covers the overdraft check in post_entry(), which sums an account's postings:
-- the amounts come from the index without visiting the table.
CREATE INDEX postings_by_account ON postings (account_id) INCLUDE (amount_cents);

CREATE TABLE chain_head (             -- exactly one row; locked by every writer
  singleton  boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  last_seq   bigint NOT NULL,
  last_hash  bytea  NOT NULL
);
-- Genesis hash: hash format version, then the tenant name (ADR-0002).
INSERT INTO chain_head VALUES (true, 0,
  sha256(convert_to(ledger_shared.ledger_field('ledger-v2') || ledger_shared.ledger_field('genesis') || ledger_shared.ledger_field('${tenant}'), 'UTF8')));

-- Copies of the chain head written outside the database, where they cannot be
-- changed (for example Amazon S3 with Object Lock). verify_chain() checks the
-- chain against the latest one.
CREATE TABLE ledger_digests (
  up_to_seq       bigint PRIMARY KEY REFERENCES journal_entries,
  entry_hash      bytea NOT NULL,
  anchor_uri      text NOT NULL,                     -- where the copy was written (for example s3://bucket/key)
  anchor_version  text NOT NULL,                     -- the store's version ID for that copy
  exported_at     timestamptz NOT NULL DEFAULT now()
);

-- Append-only guards (backstop; no role has write grants on these anyway)
CREATE TRIGGER je_no_update   BEFORE UPDATE OR DELETE ON journal_entries FOR EACH ROW       EXECUTE FUNCTION ledger_shared.forbid_change();
CREATE TRIGGER je_no_truncate BEFORE TRUNCATE         ON journal_entries FOR EACH STATEMENT EXECUTE FUNCTION ledger_shared.forbid_change();
CREATE TRIGGER p_no_update    BEFORE UPDATE OR DELETE ON postings        FOR EACH ROW       EXECUTE FUNCTION ledger_shared.forbid_change();
CREATE TRIGGER p_no_truncate  BEFORE TRUNCATE         ON postings        FOR EACH STATEMENT EXECUTE FUNCTION ledger_shared.forbid_change();
CREATE TRIGGER d_no_update    BEFORE UPDATE OR DELETE ON ledger_digests  FOR EACH ROW       EXECUTE FUNCTION ledger_shared.forbid_change();
CREATE TRIGGER d_no_truncate  BEFORE TRUNCATE         ON ledger_digests  FOR EACH STATEMENT EXECUTE FUNCTION ledger_shared.forbid_change();

------------------------------------------------------------------------------
-- Hashed text (format "ledger-v2", ADR-0002)
------------------------------------------------------------------------------
-- Every field is length-prefixed with ledger_shared.ledger_field(), so the text is
-- unambiguous whatever the fields contain. post_entry and verify_chain both
-- build it here, so they can never disagree about the format.

-- One posting line: line number, account ID, account type, owner type, owner
-- ID and amount. Including the account's type and owner means an account
-- reassigned after the fact breaks the chain. NULL if the account does not exist.
CREATE FUNCTION posting_line(p_line_no bigint, p_account_id bigint, p_amount_cents bigint)
RETURNS text
LANGUAGE sql STABLE SET search_path = ${tenant}, ledger_shared, pg_temp AS $$
  SELECT ledger_shared.ledger_field(
           ledger_shared.ledger_field(p_line_no::text) || ledger_shared.ledger_field(a.account_id::text)
           || ledger_shared.ledger_field(a.account_type) || ledger_shared.ledger_field(a.owner_type)
           || ledger_shared.ledger_field(a.owner_id) || ledger_shared.ledger_field(p_amount_cents::text))
  FROM accounts a
  WHERE a.account_id = p_account_id AND p_line_no IS NOT NULL AND p_amount_cents IS NOT NULL
$$;

-- All posting lines of a stored entry, in line order.
CREATE FUNCTION entry_lines(p_seq bigint)
RETURNS text
LANGUAGE sql STABLE SET search_path = ${tenant}, ledger_shared, pg_temp AS $$
  SELECT string_agg(posting_line(p.line_no, p.account_id, p.amount_cents), '' ORDER BY p.line_no)
  FROM postings p WHERE p.sequence_no = p_seq
$$;

CREATE FUNCTION entry_canonical(
  p_seq bigint, p_type text, p_ref text, p_reverses bigint, p_descr text,
  p_effective timestamptz, p_recorded timestamptz, p_by text,
  p_lines text                    -- from entry_lines(): the encoded posting lines, in line order
) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = ledger_shared, pg_temp AS $$
  SELECT ledger_field('ledger-v2') || ledger_field(p_seq::text) || ledger_field(p_type)
      || ledger_field(p_ref) || ledger_field(p_reverses::text) || ledger_field(p_descr)
      || ledger_field(to_char(p_effective AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'))
      || ledger_field(to_char(p_recorded  AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'))
      || ledger_field(p_by) || ledger_field(p_lines)
$$;

------------------------------------------------------------------------------
-- Write path
------------------------------------------------------------------------------

-- Opens an account, or returns the existing one with the same type and owner.
CREATE FUNCTION open_account(p_account_type text, p_owner_type text DEFAULT NULL, p_owner_id text DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ${tenant}, ledger_shared, pg_temp AS $$
DECLARE v_id bigint;
BEGIN
  -- Look first, so repeat calls don't use up identity values; the insert
  -- below handles two sessions opening the same account at once.
  SELECT account_id INTO v_id FROM accounts
   WHERE account_type = p_account_type
     AND coalesce(owner_type, '') = coalesce(p_owner_type, '')
     AND coalesce(owner_id, '') = coalesce(p_owner_id, '');
  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;
  INSERT INTO accounts (account_type, owner_type, owner_id)
    VALUES (p_account_type, p_owner_type, p_owner_id)
    ON CONFLICT (account_type, (coalesce(owner_type, '')), (coalesce(owner_id, ''))) DO NOTHING
    RETURNING account_id INTO v_id;
  IF v_id IS NULL THEN
    SELECT account_id INTO v_id FROM accounts
     WHERE account_type = p_account_type
       AND coalesce(owner_type, '') = coalesce(p_owner_type, '')
       AND coalesce(owner_id, '') = coalesce(p_owner_id, '');
  END IF;
  RETURN v_id;
END $$;

-- The ONLY way to write entries.
CREATE FUNCTION post_entry(
  p_entry_type   text,
  p_external_ref text,
  p_description  text,
  p_effective_at timestamptz,
  p_recorded_by  text,
  p_lines        jsonb,          -- [{"account_id":12,"amount_cents":-20000}, ...]
  p_reverses_seq bigint DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ${tenant}, ledger_shared, pg_temp AS $$
DECLARE
  v_head      chain_head%ROWTYPE;
  v_seq       bigint;
  v_recorded  timestamptz := date_trunc('microseconds', clock_timestamp());
  v_lines     text;
  v_hash      bytea;
  v_old       journal_entries%ROWTYPE;
  v_orig      journal_entries%ROWTYPE;
  v_bad_line  boolean;
  v_count     integer;
BEGIN
  -- 1. Validate everything that does not depend on other entries (no lock yet).
  --    Entry fields first, so NULLs and out-of-range values get a ledger code.
  IF NOT EXISTS (SELECT 1 FROM ledger_shared.entry_types WHERE code = p_entry_type) THEN
    RAISE EXCEPTION USING ERRCODE = 'LD001', MESSAGE = format('unknown entry type %s; register it with ledger_shared.register_entry_type()', p_entry_type);
  END IF;
  IF p_external_ref IS NULL OR length(p_external_ref) NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION USING ERRCODE = 'LD012', MESSAGE = 'external_ref must be 1 to 200 characters';
  END IF;
  IF p_description IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'LD012', MESSAGE = 'description must not be NULL';
  END IF;
  IF p_recorded_by IS NULL OR length(p_recorded_by) NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION USING ERRCODE = 'LD012', MESSAGE = 'recorded_by must be 1 to 200 characters';
  END IF;
  IF ledger_shared.ledger_time_ok(p_effective_at) IS NOT TRUE THEN
    RAISE EXCEPTION USING ERRCODE = 'LD012', MESSAGE = format('effective_at must be a date in years 1-9999, not %s', coalesce(p_effective_at::text, 'NULL'));
  END IF;

  IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION USING ERRCODE = 'LD002', MESSAGE = 'lines must be a JSON array';
  END IF;
  v_count := jsonb_array_length(p_lines);
  IF v_count < 2 THEN
    RAISE EXCEPTION USING ERRCODE = 'LD002', MESSAGE = 'an entry needs at least two lines';
  END IF;
  IF v_count > 32767 THEN
    RAISE EXCEPTION USING ERRCODE = 'LD002', MESSAGE = 'an entry can have at most 32767 lines';
  END IF;

  -- Lines in hashed form (see posting_line). A NULL line means a line that is
  -- not an object, an account_id or amount_cents that is missing or not a JSON
  -- integer, or an account that does not exist.
  SELECT string_agg(x.line, '' ORDER BY x.ord), bool_or(x.line IS NULL)
    INTO v_lines, v_bad_line
    FROM (SELECT t.ord,
                 CASE WHEN jsonb_typeof(t.l) = 'object' THEN
                   posting_line(t.ord, ledger_shared.json_bigint(t.l->'account_id'),
                                ledger_shared.json_bigint(t.l->'amount_cents')) END AS line
            FROM jsonb_array_elements(p_lines) WITH ORDINALITY AS t(l, ord)) x;
  IF v_bad_line THEN
    RAISE EXCEPTION USING ERRCODE = 'LD002', MESSAGE = 'every line must be an object with an existing account_id and an integer amount_cents';
  END IF;
  -- Safe to cast from here on: every line was checked above
  IF (SELECT sum((l->>'amount_cents')::bigint) FROM jsonb_array_elements(p_lines) l) <> 0 THEN
    RAISE EXCEPTION USING ERRCODE = 'LD003', MESSAGE = 'entry does not balance';
  END IF;

  -- 2. One writer at a time per tenant: lock the head of the chain
  SELECT * INTO v_head FROM chain_head FOR UPDATE;

  -- 3. Idempotency: a true retry returns the original entry; the same
  --    reference with different contents is an error, not a silent no-op.
  --    recorded_by is not compared: a retry may come from another worker.
  SELECT * INTO v_old FROM journal_entries WHERE external_ref = p_external_ref;
  IF FOUND THEN
    IF v_old.entry_type <> p_entry_type
       OR v_old.reverses_seq IS DISTINCT FROM p_reverses_seq
       OR v_old.description <> p_description
       OR v_old.effective_at <> p_effective_at
       OR entry_lines(v_old.sequence_no) IS DISTINCT FROM v_lines THEN
      RAISE EXCEPTION USING ERRCODE = 'LD005', MESSAGE = format('external_ref %s was already used for a different entry (#%s)',
        p_external_ref, v_old.sequence_no);
    END IF;
    RETURN v_old.sequence_no;
  END IF;

  -- 4. Reversals: the original must exist, must not be a reversal itself,
  --     must not already be reversed, and the lines must mirror it exactly
  --     (same accounts, opposite amounts)
  IF p_entry_type = 'reversal' THEN
    SELECT * INTO v_orig FROM journal_entries WHERE sequence_no = p_reverses_seq;
    IF NOT FOUND THEN
      RAISE EXCEPTION USING ERRCODE = 'LD006', MESSAGE = format('cannot reverse entry #%s: it does not exist', p_reverses_seq);
    END IF;
    IF v_orig.entry_type = 'reversal' THEN
      RAISE EXCEPTION USING ERRCODE = 'LD006', MESSAGE = format('cannot reverse entry #%s: it is itself a reversal; post a new entry instead', p_reverses_seq);
    END IF;
    IF EXISTS (SELECT 1 FROM journal_entries WHERE reverses_seq = p_reverses_seq) THEN
      RAISE EXCEPTION USING ERRCODE = 'LD006', MESSAGE = format('cannot reverse entry #%s: it was already reversed', p_reverses_seq);
    END IF;
    IF (SELECT string_agg(p.account_id || ':' || -p.amount_cents, ',' ORDER BY p.account_id, -p.amount_cents)
          FROM postings p WHERE p.sequence_no = p_reverses_seq)
       IS DISTINCT FROM
       (SELECT string_agg((l->>'account_id')::bigint || ':' || (l->>'amount_cents')::bigint, ','
                          ORDER BY (l->>'account_id')::bigint, (l->>'amount_cents')::bigint)
          FROM jsonb_array_elements(p_lines) l) THEN
      RAISE EXCEPTION USING ERRCODE = 'LD006', MESSAGE = format('a reversal of entry #%s must have the same lines with the amounts negated', p_reverses_seq);
    END IF;
  ELSIF p_reverses_seq IS NOT NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'LD006', MESSAGE = 'only a reversal can reference another entry';
  END IF;

  -- 5. Hash = SHA-256(previous hash || canonical entry text)
  v_seq := v_head.last_seq + 1;
  v_hash := sha256(v_head.last_hash || convert_to(
              entry_canonical(v_seq, p_entry_type, p_external_ref, p_reverses_seq, p_description,
                              p_effective_at, v_recorded, p_recorded_by, v_lines), 'UTF8'));

  -- 6. Write the entry and its lines
  INSERT INTO journal_entries (sequence_no, entry_type, external_ref, reverses_seq, description,
                               effective_at, recorded_at, recorded_by, prev_hash, entry_hash)
  VALUES (v_seq, p_entry_type, p_external_ref, p_reverses_seq, p_description,
          p_effective_at, v_recorded, p_recorded_by, v_head.last_hash, v_hash);

  INSERT INTO postings (sequence_no, line_no, account_id, amount_cents)
  SELECT v_seq, t.ord, (t.l->>'account_id')::bigint, (t.l->>'amount_cents')::bigint
  FROM jsonb_array_elements(p_lines) WITH ORDINALITY AS t(l, ord);

  -- 7. No overdrafts on account types that don't allow them. Race-free
  --    because we still hold the chain lock.
  IF EXISTS (
    SELECT 1 FROM accounts a
      JOIN ledger_shared.account_types t ON t.code = a.account_type
      JOIN postings p USING (account_id)
    WHERE NOT t.allow_negative
      AND a.account_id IN (SELECT account_id FROM postings WHERE sequence_no = v_seq)
    GROUP BY a.account_id HAVING sum(p.amount_cents) < 0) THEN
    RAISE EXCEPTION USING ERRCODE = 'LD004', MESSAGE = 'insufficient funds';
  END IF;

  UPDATE chain_head SET last_seq = v_seq, last_hash = v_hash;
  RETURN v_seq;
END $$;

-- Record that the chain up to p_up_to_seq was copied outside the database.
-- The hash is taken from the ledger itself, never from the caller.
CREATE FUNCTION record_digest(p_up_to_seq bigint, p_anchor_uri text, p_anchor_version text)
RETURNS bytea
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ${tenant}, ledger_shared, pg_temp AS $$
DECLARE
  v_hash bytea;
  v_old  ledger_digests%ROWTYPE;
BEGIN
  SELECT entry_hash INTO v_hash FROM journal_entries WHERE sequence_no = p_up_to_seq;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'LD008', MESSAGE = format('entry %s does not exist', p_up_to_seq);
  END IF;
  -- A retry with the same anchor returns the hash; a different anchor for an
  -- entry that already has one is an error (the first copy is the record).
  SELECT * INTO v_old FROM ledger_digests WHERE up_to_seq = p_up_to_seq;
  IF FOUND THEN
    IF v_old.anchor_uri IS DISTINCT FROM p_anchor_uri OR v_old.anchor_version IS DISTINCT FROM p_anchor_version THEN
      RAISE EXCEPTION USING ERRCODE = 'LD011', MESSAGE = format(
        'a digest for entry %s was already recorded at %s (version %s)', p_up_to_seq, v_old.anchor_uri, v_old.anchor_version);
    END IF;
    RETURN v_old.entry_hash;
  END IF;
  INSERT INTO ledger_digests (up_to_seq, entry_hash, anchor_uri, anchor_version)
  VALUES (p_up_to_seq, v_hash, p_anchor_uri, p_anchor_version);
  RETURN v_hash;
END $$;

------------------------------------------------------------------------------
-- Read path
------------------------------------------------------------------------------

-- Walk the chain from the start; returns the first problem found (no rows = intact).
-- Pass the latest digest read back from outside storage (p_anchor_seq,
-- p_anchor_hash) to also catch a chain rewritten end to end by someone with
-- full database access.
CREATE FUNCTION verify_chain(p_anchor_seq bigint DEFAULT NULL, p_anchor_hash bytea DEFAULT NULL)
RETURNS TABLE (bad_seq bigint, problem text)
LANGUAGE plpgsql STABLE SET search_path = ${tenant}, ledger_shared, pg_temp AS $$
DECLARE
  -- current_schema() is this tenant (set by the function's search_path)
  v_prev      bytea  := sha256(convert_to(ledger_shared.ledger_field('ledger-v2') || ledger_shared.ledger_field('genesis')
                                          || ledger_shared.ledger_field(current_schema()), 'UTF8'));
  v_expected  bigint := 1;
  v_calc      bytea;
  v_head      chain_head%ROWTYPE;
  e           record;
  d           record;
BEGIN
  IF (p_anchor_seq IS NULL) <> (p_anchor_hash IS NULL) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'pass both p_anchor_seq and p_anchor_hash, or neither';
  END IF;

  -- 1. Walk every entry in order
  FOR e IN SELECT * FROM journal_entries ORDER BY sequence_no LOOP
    IF e.sequence_no <> v_expected THEN
      RETURN QUERY SELECT e.sequence_no,
        format('gap in entry numbers: expected #%s, found #%s', v_expected, e.sequence_no); RETURN;
    END IF;
    IF e.prev_hash <> v_prev THEN
      RETURN QUERY SELECT e.sequence_no, 'prev_hash does not match previous entry'; RETURN;
    END IF;
    -- Outside years 1-9999 the hash cannot detect changes (no era, no infinity)
    IF ledger_shared.ledger_time_ok(e.effective_at) IS NOT TRUE OR ledger_shared.ledger_time_ok(e.recorded_at) IS NOT TRUE THEN
      RETURN QUERY SELECT e.sequence_no, 'timestamp outside years 1-9999 (not covered by the hash)'; RETURN;
    END IF;
    v_calc := sha256(v_prev || convert_to(entry_canonical(
                e.sequence_no, e.entry_type, e.external_ref, e.reverses_seq, e.description,
                e.effective_at, e.recorded_at, e.recorded_by, entry_lines(e.sequence_no)), 'UTF8'));
    IF v_calc IS DISTINCT FROM e.entry_hash THEN
      RETURN QUERY SELECT e.sequence_no, 'entry contents changed'; RETURN;
    END IF;
    v_prev := e.entry_hash;
    v_expected := v_expected + 1;
  END LOOP;

  -- 2. The chain head must point at the last entry (catches entries removed from the end)
  SELECT * INTO v_head FROM chain_head;
  IF v_head.last_seq <> v_expected - 1 OR v_head.last_hash <> v_prev THEN
    RETURN QUERY SELECT v_head.last_seq,
      format('chain head (#%s) does not match the last entry (#%s)', v_head.last_seq, v_expected - 1); RETURN;
  END IF;

  -- 3. Every recorded digest must still match its entry
  FOR d IN SELECT g.up_to_seq, g.entry_hash, j.entry_hash AS current_hash
           FROM ledger_digests g LEFT JOIN journal_entries j ON j.sequence_no = g.up_to_seq
           ORDER BY g.up_to_seq LOOP
    IF d.current_hash IS NULL OR d.current_hash <> d.entry_hash THEN
      RETURN QUERY SELECT d.up_to_seq, 'entry no longer matches its recorded digest'; RETURN;
    END IF;
  END LOOP;

  -- 4. The outside anchor (the check a database administrator can't fake)
  IF p_anchor_seq IS NOT NULL THEN
    SELECT entry_hash INTO v_calc FROM journal_entries WHERE sequence_no = p_anchor_seq;
    IF NOT FOUND THEN
      RETURN QUERY SELECT p_anchor_seq, 'entry covered by the outside digest is missing'; RETURN;
    END IF;
    IF v_calc <> p_anchor_hash THEN
      RETURN QUERY SELECT p_anchor_seq, 'entry does not match the outside digest (chain was rewritten)'; RETURN;
    END IF;
  END IF;
END $$;

-- Balances are always calculated, never stored
CREATE VIEW account_balances AS
SELECT a.account_id, a.account_type, a.owner_type, a.owner_id,
       coalesce(sum(p.amount_cents), 0) AS balance_cents
FROM accounts a LEFT JOIN postings p USING (account_id)
GROUP BY a.account_id;

------------------------------------------------------------------------------
-- Permissions (roles are created by the shared migration)
------------------------------------------------------------------------------
-- Ledger objects are named one by one: on an existing database, application
-- layers' tables also live in this schema and must not be exposed.
REVOKE ALL ON accounts, journal_entries, postings, chain_head, ledger_digests, account_balances FROM PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA ${tenant} FROM PUBLIC;  -- Postgres grants EXECUTE to everyone by default

GRANT USAGE ON SCHEMA ${tenant} TO ledger_reader, ledger_poster, ledger_account_opener, ledger_digest_writer;

GRANT SELECT ON accounts, journal_entries, postings, chain_head, ledger_digests, account_balances TO ledger_reader;
GRANT EXECUTE ON FUNCTION verify_chain(bigint, bytea) TO ledger_reader;
GRANT EXECUTE ON FUNCTION entry_canonical(bigint, text, text, bigint, text, timestamptz, timestamptz, text, text) TO ledger_reader;
GRANT EXECUTE ON FUNCTION posting_line(bigint, bigint, bigint) TO ledger_reader;
GRANT EXECUTE ON FUNCTION entry_lines(bigint) TO ledger_reader;

GRANT EXECUTE ON FUNCTION post_entry(text, text, text, timestamptz, text, jsonb, bigint) TO ledger_poster;
GRANT EXECUTE ON FUNCTION open_account(text, text, text) TO ledger_account_opener;
GRANT EXECUTE ON FUNCTION record_digest(bigint, text, text) TO ledger_digest_writer;

-- This tenant's own roles: the same rights, on this tenant only (see
-- ledger_shared.create_tenant_roles).
SELECT ledger_shared.create_tenant_roles('${tenant}');
GRANT USAGE ON SCHEMA ${tenant} TO ledger_${tenant}_reader, ledger_${tenant}_poster, ledger_${tenant}_opener, ledger_${tenant}_digest;
GRANT SELECT ON accounts, journal_entries, postings, chain_head, ledger_digests, account_balances TO ledger_${tenant}_reader;
GRANT EXECUTE ON FUNCTION verify_chain(bigint, bytea) TO ledger_${tenant}_reader;
GRANT EXECUTE ON FUNCTION entry_canonical(bigint, text, text, bigint, text, timestamptz, timestamptz, text, text) TO ledger_${tenant}_reader;
GRANT EXECUTE ON FUNCTION posting_line(bigint, bigint, bigint) TO ledger_${tenant}_reader;
GRANT EXECUTE ON FUNCTION entry_lines(bigint) TO ledger_${tenant}_reader;
GRANT EXECUTE ON FUNCTION post_entry(text, text, text, timestamptz, text, jsonb, bigint) TO ledger_${tenant}_poster;
GRANT EXECUTE ON FUNCTION open_account(text, text, text) TO ledger_${tenant}_opener;
GRANT EXECUTE ON FUNCTION record_digest(bigint, text, text) TO ledger_${tenant}_digest;
-- No role gets INSERT, UPDATE or DELETE on any ledger table.

------------------------------------------------------------------------------
-- Ownership (see the owner role in the shared migration)
------------------------------------------------------------------------------
-- The SECURITY DEFINER functions run as ledger_owner, which owns only ledger
-- objects. The schema itself stays with whoever runs the migrations, because
-- application layers add their own tables to it.
GRANT USAGE, CREATE ON SCHEMA ${tenant} TO ledger_owner;
ALTER TABLE accounts OWNER TO ledger_owner;
ALTER TABLE journal_entries OWNER TO ledger_owner;
ALTER TABLE postings OWNER TO ledger_owner;
ALTER TABLE chain_head OWNER TO ledger_owner;
ALTER TABLE ledger_digests OWNER TO ledger_owner;
ALTER VIEW account_balances OWNER TO ledger_owner;
ALTER FUNCTION accounts_check_owner() OWNER TO ledger_owner;
ALTER FUNCTION posting_line(bigint, bigint, bigint) OWNER TO ledger_owner;
ALTER FUNCTION entry_lines(bigint) OWNER TO ledger_owner;
ALTER FUNCTION entry_canonical(bigint, text, text, bigint, text, timestamptz, timestamptz, text, text) OWNER TO ledger_owner;
ALTER FUNCTION open_account(text, text, text) OWNER TO ledger_owner;
ALTER FUNCTION post_entry(text, text, text, timestamptz, text, jsonb, bigint) OWNER TO ledger_owner;
ALTER FUNCTION record_digest(bigint, text, text) OWNER TO ledger_owner;
ALTER FUNCTION verify_chain(bigint, bytea) OWNER TO ledger_owner;
