-- Example application layer, per-tenant objects. ${tenant} is replaced with
-- the tenant schema name by scripts/migrate.sh.
--
-- The application owns its people. The ledger only knows each account's
-- owner type and ID; a link table on the application side gives foreign keys
-- in both directions.
CREATE TABLE ${tenant}.members (
  member_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  display_name  text NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE ${tenant}.member_accounts (
  member_id   uuid   PRIMARY KEY REFERENCES ${tenant}.members,
  account_id  bigint NOT NULL UNIQUE REFERENCES ${tenant}.accounts
);

-- Adds a member and opens their wallet in one transaction. open_account() is
-- idempotent, so a retry after a lost connection is safe.
CREATE FUNCTION ${tenant}.add_member(p_display_name text) RETURNS uuid
LANGUAGE plpgsql SET search_path = ${tenant}, ledger_shared, pg_temp AS $$
DECLARE v_member uuid; v_account bigint;
BEGIN
  INSERT INTO members (display_name) VALUES (p_display_name) RETURNING member_id INTO v_member;
  v_account := open_account('member_wallet', 'member', v_member::text);
  INSERT INTO member_accounts (member_id, account_id) VALUES (v_member, v_account);
  RETURN v_member;
END $$;
REVOKE EXECUTE ON FUNCTION ${tenant}.add_member(text) FROM PUBLIC;
