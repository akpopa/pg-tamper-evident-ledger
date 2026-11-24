# CLAUDE.md

## What this repo is

A general-purpose, tamper-evident double-entry ledger for PostgreSQL: schema, functions, migration scripts, tools, and tests. It will be public and is meant to be used by unrelated projects, so keep it generic. No application domain (no customers, programs, vendors, purchases or similar wording in the core), no secrets.

Applications typically pull this repo in as a git submodule (for example at `vendor/ledger`), pinned to a tag. Application tables, owners (people and organizations), users, audit trails and APIs belong in the application, never here. Docs, ADRs and code must not name or describe any particular application that uses the ledger.

## Working on this repository

- **Before creating a branch or a pull request, check for open (unmerged) pull requests.** If one already covers the area, build on it (push to its branch or stack on it) instead of starting a parallel change from `main`.

## Model (v0.3.0, ADR-0002)

- Tenants are schemas; names are chosen by the application (optional `LEDGER_TENANT_PREFIX`), at most 49 characters so per-tenant role names fit. A tenant may live in any database (ADR-0003); nothing in the ledger may cross tenants or assume they share a database.
- Applications register account types (owner type or none, may go negative) and entry types in `ledger_shared`; `reversal` is built in.
- Accounts name their owner by `owner_type` / `owner_id`; there are no owner tables in the ledger.
- Writes go only through `open_account()`, `post_entry()` and `record_digest()`; no role has INSERT, UPDATE or DELETE on ledger tables.
- Errors carry SQLSTATE codes `LD001`-`LD012`. Keep codes stable; add new ones rather than reusing.

## Layout

- `db/core/shared/V<n>__*.sql`: objects shared by all tenants (schema `ledger_shared`, type registry, roles).
- `db/core/tenant/V<n>__*.sql`: per-tenant ledger, written with the `${tenant}` placeholder.
- `scripts/`: `migrate.sh`, `provision_tenant.sh`, `upgrade.sh` (one or more databases), `move_tenant.sh`, `run_tests.sh`, `_names.sh` (tenant name rules, 49 characters at most) and `_db.sh` (`LEDGER_DB` connection).
- `tools/`: `export_chain.sql` and `verify_chain.py`, an independent implementation of the hash format.
- `examples/app-layer/`: a working application layer (members, link table, `add_member()`).
- `docs/`: integration guide, ADR-0001, ADR-0002, ADR-0003, technical design.

## Rules

- Never edit a migration that has been released (tagged). Add a new `V<n+1>` file; `migrate.sh` rejects edited files by checksum. (v0.3.0 was a one-time fresh start; see ADR-0002.)
- Anything that changes the hashed text breaks existing chains. It needs an ADR, a new format name (currently `ledger-v2`), matching changes in `tools/verify_chain.py`, and an upgrade path that verifies old entries under the old format.
- Breaking changes go in `CHANGELOG.md` and get a new tag; applications then move their pin.
- Amounts are integers in the smallest currency unit (`bigint`), one currency per tenant.
- Every new ledger table, view or function must be owned by `ledger_owner` and granted to both the group roles and the tenant's own roles (`ledger_<tenant>_...`); `tests/11_roles.sql` (K19) fails if the owner is wrong; add grant checks for new objects. Never grant `ledger_owner` to anything.
- Timestamps stored in ledger tables must stay within years 1 to 9999 (`ledger_shared.ledger_time_ok()`): the hashed form has no era or infinity.
- Keep `docs/integration-guide.md` correct when behaviour changes; it is the main entry point for users.

## Running the tests

Needs PostgreSQL 14+ (tested on 16), `psql`, `pg_dump` of the same major version, bash, and Python 3. Set the usual `PG*` variables (superuser), then:

```
scripts/run_tests.sh
```

Each test file gets a fresh database with `tenant_alpha` provisioned and seeded. The script exits non-zero if any check fails. CI runs the same script on PostgreSQL 14, 15, 16 and 17, and runs `shellcheck` on the scripts.

When adding a check, use `testkit.ok(name, condition)`, `testkit.fails(name, sql, pattern)` or `testkit.sqlstate_of(sql)`, and update the counts in `README.md`, `docs/technical-design.md` (summary, test table and total), ADR-0002 and ADR-0003. Check IDs are unique across all test files (for example `K19`, `E3`, `N5`). Note that a check reading data in the same statement as the call that writes it sees the old snapshot; use two statements.
