-- Core layer, shared objects (v0.3.0): created once per database, before any
-- tenant. Applied by scripts/migrate.sh (via provision_tenant.sh or upgrade.sh).
--
--   ledger_shared.account_types     the kinds of account the application uses
--   ledger_shared.entry_types       the kinds of journal entry it posts
--   register_account_type()  idempotent registration, for migrations
--   register_entry_type()
--   ledger_shared.ledger_field()    the hash encoding of one field (ADR-0002)
--   ledger_shared.ledger_time_ok()  timestamps the hash can represent (years 1-9999)
--   ledger_shared.json_bigint()     strict JSON integer, for validating posting lines
--   group roles              ledger_reader, ledger_poster,
--                            ledger_account_opener, ledger_digest_writer
--   owner role               ledger_owner owns every ledger object
--   create_tenant_roles()    one tenant's own roles (ledger_<tenant>_reader, ...)
--
-- The ledger has no tables for the people or organizations that own
-- accounts. An account names its owner by type and ID (for example
-- 'customer' / 'c-1042'), and the application keeps its own tables for them.
-- See docs/integration-guide.md.
CREATE SCHEMA ledger_shared;

-- Errors raised by the ledger carry their own SQLSTATE codes (class LD), so
-- applications can handle them without matching message text:
--   LD001 unknown entry type          LD006 invalid reversal
--   LD002 invalid lines               LD007 account type or owner rule
--   LD003 entry does not balance      LD008 digest for a missing entry
--   LD004 insufficient funds          LD009 append-only table changed
--   LD005 external_ref reused         LD010 type registered with other rules
--   with different contents           LD011 digest already recorded for that
--                                           entry with a different anchor
--                                     LD012 invalid entry field (effective_at,
--                                           external_ref, description, recorded_by)

-- One guard function used by every append-only table
CREATE FUNCTION ledger_shared.forbid_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION USING ERRCODE = 'LD009',
    MESSAGE = format('ledger is append-only: %s on %s.%s is not allowed', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME);
END $$;

------------------------------------------------------------------------------
-- Type registry
------------------------------------------------------------------------------
-- Codes are lowercase identifiers. Types are append-only: a type's rules
-- cannot change once accounts or entries may depend on them. To retire a type,
-- stop using it in the application.

CREATE TABLE ledger_shared.account_types (
  code            text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]{0,62}$'),
  -- Accounts of this type must be owned by this kind of owner (for example
  -- 'customer'). NULL: the type is for the application's own accounts
  -- (funding, clearing, fees), which have no owner.
  owner_type      text CHECK (owner_type ~ '^[a-z][a-z0-9_]{0,62}$'),
  -- Whether accounts of this type may go below zero. Owned accounts usually
  -- may not; funding and clearing accounts usually may.
  allow_negative  boolean NOT NULL,
  description     text NOT NULL,
  registered_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE ledger_shared.entry_types (
  code            text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]{0,62}$'),
  description     text NOT NULL,
  registered_at   timestamptz NOT NULL DEFAULT now()
);
-- Built in: reversals have rules of their own in post_entry().
INSERT INTO ledger_shared.entry_types (code, description)
  VALUES ('reversal', 'Cancels an earlier entry with the same lines, amounts negated');

CREATE TRIGGER at_no_change   BEFORE UPDATE OR DELETE ON ledger_shared.account_types FOR EACH ROW       EXECUTE FUNCTION ledger_shared.forbid_change();
CREATE TRIGGER at_no_truncate BEFORE TRUNCATE         ON ledger_shared.account_types FOR EACH STATEMENT EXECUTE FUNCTION ledger_shared.forbid_change();
CREATE TRIGGER et_no_change   BEFORE UPDATE OR DELETE ON ledger_shared.entry_types   FOR EACH ROW       EXECUTE FUNCTION ledger_shared.forbid_change();
CREATE TRIGGER et_no_truncate BEFORE TRUNCATE         ON ledger_shared.entry_types   FOR EACH STATEMENT EXECUTE FUNCTION ledger_shared.forbid_change();

-- Registers an account type. Running it again with the same definition does
-- nothing, so application migrations and seeds can call it freely; a
-- different definition for an existing code is an error.
CREATE FUNCTION ledger_shared.register_account_type(
  p_code text, p_owner_type text, p_allow_negative boolean, p_description text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE t ledger_shared.account_types%ROWTYPE;
BEGIN
  SELECT * INTO t FROM ledger_shared.account_types WHERE code = p_code;
  IF FOUND THEN
    IF t.owner_type IS DISTINCT FROM p_owner_type OR t.allow_negative <> p_allow_negative THEN
      RAISE EXCEPTION USING ERRCODE = 'LD010', MESSAGE = format(
        'account type %s is already registered with different rules (owner_type %s, allow_negative %s)',
        p_code, coalesce(t.owner_type, 'none'), t.allow_negative);
    END IF;
    RETURN;
  END IF;
  INSERT INTO ledger_shared.account_types (code, owner_type, allow_negative, description)
    VALUES (p_code, p_owner_type, p_allow_negative, p_description);
END $$;

CREATE FUNCTION ledger_shared.register_entry_type(p_code text, p_description text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO ledger_shared.entry_types (code, description) VALUES (p_code, p_description)
    ON CONFLICT (code) DO NOTHING;
END $$;

-- Registration is for migrations (run by the database owner), not services.
REVOKE EXECUTE ON FUNCTION ledger_shared.register_account_type(text, text, boolean, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION ledger_shared.register_entry_type(text, text) FROM PUBLIC;

------------------------------------------------------------------------------
-- Hash encoding (ADR-0002)
------------------------------------------------------------------------------
-- One field of hashed text: "<length in bytes>:<value>,". Because each field
-- carries its length, no value can be shifted into its neighbour without
-- changing the hash, whatever characters it contains. NULL is encoded as "-",
-- which no length-prefixed field can equal.
CREATE FUNCTION ledger_shared.ledger_field(p_value text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE WHEN p_value IS NULL THEN '-'
              ELSE octet_length(p_value) || ':' || p_value || ',' END
$$;

-- Timestamps the hash can represent exactly. The hashed text writes a
-- timestamp as 'YYYY-MM-DDTHH:MI:SS.USZ', which has no era and cannot show
-- infinity: 44 BC and 44 AD encode the same, and both infinities encode as
-- NULL. Entries are therefore limited to years 1-9999 (CHECK constraints), and
-- verify_chain() reports any stored timestamp outside that range, because the
-- hash cannot detect a change into or within it.
CREATE FUNCTION ledger_shared.ledger_time_ok(p_value timestamptz) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT p_value >= '0001-01-01 00:00:00+00' AND p_value < '10000-01-01 00:00:00+00'
$$;

-- A JSON value as bigint, or NULL unless it is a JSON integer (no fraction,
-- no exponent, no quotes) within the bigint range. post_entry() uses it so a
-- malformed line is rejected with LD002 instead of a cast error.
CREATE FUNCTION ledger_shared.json_bigint(p_value jsonb) RETURNS bigint
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE WHEN jsonb_typeof(p_value) = 'number'
               AND p_value::text ~ '^-?[0-9]{1,19}$'
               AND p_value::text::numeric BETWEEN -9223372036854775808 AND 9223372036854775807
         THEN p_value::text::bigint END
$$;

------------------------------------------------------------------------------
-- Roles
------------------------------------------------------------------------------
-- Group roles (NOLOGIN). Roles are cluster-wide, so they are created only if
-- missing. Applications connect with their own logins and are granted only
-- the groups they need, for example:
--   GRANT ledger_reader, ledger_poster TO svc_payments;
--
--   ledger_reader          read accounts, entries, balances, digests; verify
--   ledger_poster          post entries (post_entry)
--   ledger_account_opener  open accounts (open_account)
--   ledger_digest_writer   record an outside anchor (record_digest)
--
-- No role can INSERT, UPDATE or DELETE ledger tables.
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['ledger_reader', 'ledger_poster', 'ledger_account_opener', 'ledger_digest_writer'] LOOP
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('CREATE ROLE %I NOLOGIN', r);
    END IF;
  END LOOP;
END $$;

GRANT USAGE ON SCHEMA ledger_shared TO ledger_reader, ledger_poster, ledger_account_opener, ledger_digest_writer;
GRANT SELECT ON ledger_shared.account_types, ledger_shared.entry_types TO ledger_reader;

------------------------------------------------------------------------------
-- Owner role
------------------------------------------------------------------------------
-- post_entry(), open_account() and record_digest() are SECURITY DEFINER: they
-- run with their owner's rights. If the owner were the administrator who ran
-- the migrations, every call would briefly run with rights over the whole
-- server. Instead, every ledger object is owned by ledger_owner: it cannot log
-- in, is not a superuser, and has rights only on the ledger's own objects.
--
-- An owner can switch off its tables' triggers, so never let an application
-- log in as ledger_owner or be granted membership in it.
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'ledger_owner') THEN
    CREATE ROLE ledger_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
  ELSIF EXISTS (SELECT FROM pg_roles WHERE rolname = 'ledger_owner'
                  AND (rolsuper OR rolcanlogin OR rolcreaterole OR rolcreatedb OR rolreplication OR rolbypassrls)) THEN
    RAISE EXCEPTION 'role ledger_owner exists with extra powers (login, superuser, createrole, createdb, replication or bypassrls); remove them first';
  END IF;
END $$;

ALTER SCHEMA ledger_shared OWNER TO ledger_owner;
ALTER TABLE ledger_shared.account_types OWNER TO ledger_owner;
ALTER TABLE ledger_shared.entry_types OWNER TO ledger_owner;
ALTER FUNCTION ledger_shared.forbid_change() OWNER TO ledger_owner;
ALTER FUNCTION ledger_shared.register_account_type(text, text, boolean, text) OWNER TO ledger_owner;
ALTER FUNCTION ledger_shared.register_entry_type(text, text) OWNER TO ledger_owner;
ALTER FUNCTION ledger_shared.ledger_field(text) OWNER TO ledger_owner;
ALTER FUNCTION ledger_shared.ledger_time_ok(timestamptz) OWNER TO ledger_owner;
ALTER FUNCTION ledger_shared.json_bigint(jsonb) OWNER TO ledger_owner;

------------------------------------------------------------------------------
-- Per-tenant roles
------------------------------------------------------------------------------
-- The group roles above reach every tenant on the server. Each tenant also
-- gets its own roles, with the same rights on that tenant only:
--   ledger_<tenant>_reader   ledger_<tenant>_poster
--   ledger_<tenant>_opener   ledger_<tenant>_digest
-- An application login created NOINHERIT and granted these roles has no
-- ledger rights until it runs SET LOCAL ROLE ledger_<tenant>_poster (or a
-- role of its own that includes it), so a request routed to the wrong tenant
-- fails with "permission denied" instead of writing to another ledger.
--
-- Role names are limited to 63 characters, so tenant names are limited to 49
-- (ledger_ + 49 + _reader). Roles belong to the server: a tenant name must be
-- unique on its server.
--
-- Called by the tenant migration, and by scripts/move_tenant.sh before a
-- tenant is copied to another server. Creates the roles only if missing;
-- refuses existing ones that can log in or have administrator powers.
CREATE FUNCTION ledger_shared.create_tenant_roles(p_tenant text) RETURNS void
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE r text;
BEGIN
  IF p_tenant !~ '^[a-z][a-z0-9_]*$' OR length(p_tenant) > 49 THEN
    RAISE EXCEPTION 'tenant name % is not a lowercase identifier of at most 49 characters', p_tenant;
  END IF;
  FOREACH r IN ARRAY ARRAY['reader', 'poster', 'opener', 'digest'] LOOP
    r := format('ledger_%s_%s', p_tenant, r);
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('CREATE ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS', r);
    ELSIF EXISTS (SELECT FROM pg_roles WHERE rolname = r
                    AND (rolsuper OR rolcanlogin OR rolcreaterole OR rolcreatedb OR rolreplication OR rolbypassrls)) THEN
      RAISE EXCEPTION 'role % exists with extra powers (login, superuser, createrole, createdb, replication or bypassrls); remove them first', r;
    END IF;
    EXECUTE format('GRANT USAGE ON SCHEMA ledger_shared TO %I', r);
  END LOOP;
  EXECUTE format('GRANT SELECT ON ledger_shared.account_types, ledger_shared.entry_types TO %I', 'ledger_' || p_tenant || '_reader');
END $$;
REVOKE EXECUTE ON FUNCTION ledger_shared.create_tenant_roles(text) FROM PUBLIC;
ALTER FUNCTION ledger_shared.create_tenant_roles(text) OWNER TO ledger_owner;
