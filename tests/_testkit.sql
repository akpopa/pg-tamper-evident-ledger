-- Test helpers, loaded by scripts/run_tests.sh after provisioning and seeding.
-- Each check prints a NOTICE starting with PASS or FAIL; the runner counts them.

CREATE SCHEMA testkit;

-- PASS when the condition is true (NULL counts as false).
CREATE FUNCTION testkit.ok(p_name text, p_cond boolean) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_cond IS TRUE THEN
    RAISE NOTICE 'PASS %', p_name;
  ELSE
    RAISE NOTICE 'FAIL %', p_name;
  END IF;
END $$;

-- PASS when the statement raises an error whose message matches the pattern
-- (case-insensitive regex). The statement runs as the current role.
CREATE FUNCTION testkit.fails(p_name text, p_sql text, p_pattern text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RAISE NOTICE 'FAIL % (no error was raised)', p_name;
EXCEPTION WHEN OTHERS THEN
  IF SQLERRM ~* p_pattern THEN
    RAISE NOTICE 'PASS %', p_name;
  ELSE
    RAISE NOTICE 'FAIL % (unexpected error: %)', p_name, SQLERRM;
  END IF;
END $$;

-- The SQLSTATE a statement fails with, or NULL if it succeeds.
CREATE FUNCTION testkit.sqlstate_of(p_sql text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RETURN SQLSTATE;
END $$;

GRANT USAGE ON SCHEMA testkit TO PUBLIC;
