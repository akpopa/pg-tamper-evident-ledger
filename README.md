# Tamper-evident ledger for PostgreSQL

A double-entry, append-only ledger that lives in your PostgreSQL database. Every balance is derived from its postings, every entry is linked into a SHA-256 hash chain, and the chain can be anchored in write-once storage (such as Amazon S3 Object Lock), so tampering is detectable even by someone with full database access.

It is general-purpose: your application registers its own kinds of account and entry, keeps its own tables for the people and organizations that own accounts, and adds its own migrations on top without changing any file here. Each tenant (one ledger) is its own schema with its own chain.

**Start here:** [Integrating the ledger into your project](docs/integration-guide.md).

## Highlights

- **Double-entry, append-only.** Entries must balance to zero. Ledger rows, accounts and the type registry cannot be updated or deleted, even by administrators; corrections are reversing entries.
- **Your vocabulary.** Register account types (who owns them, whether they may go negative) and entry types in a migration. Accounts name their owner by type and ID; your tables hold the owners.
- **One write path.** `open_account()` and `post_entry()` validate everything, reject overdrafts, enforce exact-mirror reversals, and are safe to retry. Rejections have stable SQLSTATE codes.
- **Hash chain with an outside anchor.** Each entry's hash covers the previous hash, every field (length-prefixed, so nothing can shift between fields), and each posting's account type and owner. `verify_chain()` reports the first problem; checked against the latest outside digest, it also catches a chain rewritten end to end.
- **Independent verifier.** `tools/verify_chain.py` (Python standard library only) checks an exported chain without PostgreSQL, for outside auditors.
- **Correct under concurrency.** A per-tenant chain lock gives gapless entry numbers and race-free balance checks.
- **Least-privilege roles.** Separate roles for reading, posting, opening accounts, and recording digests; no role can write ledger tables directly. Ledger objects are owned by `ledger_owner`, a non-administrator role, so the write functions never run with administrator rights.
- **Tenants anywhere.** Each tenant has its own roles, so a request routed to the wrong tenant is refused. A tenant can live in its own database or server, one deploy upgrades them all, and `move_tenant.sh` moves a tenant with its chain verified at the destination.
- **Migration layers.** Core migrations here; your layer on top (see `examples/app-layer`). Tenant names are yours to choose, with an optional required prefix.
- **Self-checking tests.** 161 checks covering normal use, input validation, roles and per-tenant isolation, moving tenants between databases, types and owners, reversals, concurrency, tampering, migrations, and agreement with the outside verifier, run in CI on PostgreSQL 14 to 17.

## Repository layout

```
db/core/shared/              core migrations applied once per database
db/core/tenant/              core migrations applied to each tenant (${tenant} placeholder)
scripts/provision_tenant.sh  creates a tenant (core, then your layers)
scripts/upgrade.sh           deploy step: brings shared objects and every tenant up to date, in one or more databases
scripts/move_tenant.sh       copies one tenant to another database and verifies the copy
scripts/migrate.sh           applies pending migrations from one folder to one target
scripts/run_tests.sh         runs the test suite
tools/                       chain export and the independent verifier
tests/                       seed data, test helpers, and test scripts
examples/app-layer/          a working example application layer
docs/                        integration guide, ADRs, technical design
```

## Quick start

Requires PostgreSQL 14 or later (tested on 14 to 17), `psql`, and bash. Connection settings come from the standard `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD` and `PGDATABASE` variables.

```
createdb ledger_demo
export PGDATABASE=ledger_demo
scripts/provision_tenant.sh main
```

```sql
SET search_path = main, ledger_shared;

-- Describe your accounts and movements (normally in a migration)
SELECT ledger_shared.register_account_type('funding', NULL,     true,  'Where money comes from');
SELECT ledger_shared.register_account_type('wallet',  'person', false, 'A person''s balance');
SELECT ledger_shared.register_entry_type('deposit', 'Money added to a wallet');

-- Open accounts and post an entry
SELECT open_account('funding');                       -- 1
SELECT open_account('wallet', 'person', 'p-1');       -- 2
SELECT post_entry('deposit', 'DEP-1', 'First deposit', now(), 'sys',
  '[{"account_id":1,"amount_cents":-100000},{"account_id":2,"amount_cents":100000}]');

SELECT * FROM account_balances;
SELECT * FROM verify_chain();   -- no rows means the ledger is intact
```

## Running the tests

The tests need a superuser connection, because the tampering scenarios switch protections off on purpose, and Python 3 for the outside verifier.

```
scripts/run_tests.sh
```

Each test file runs against a fresh database with the test tenant `tenant_alpha` provisioned and seeded. The script prints PASS or FAIL for every check and exits with an error if any check fails. The same suite runs in GitHub Actions on every push.

## Documentation

- [Integration guide](docs/integration-guide.md): add the ledger to your project, register types, link your owners, call it from your code, anchor and verify, upgrade
- [ADR-0001: Tamper-evident double-entry ledger in PostgreSQL](docs/adr/0001-tamper-evident-ledger-in-postgres.md)
- [ADR-0002: General-purpose accounts, registered types, hash format v2](docs/adr/0002-general-purpose-accounts-and-hash-format-v2.md)
- [ADR-0003: Tenants in more than one database, and per-tenant roles](docs/adr/0003-tenants-across-databases-and-per-tenant-roles.md)
- [Technical design](docs/technical-design.md), including the hash format specification
- [Changelog](CHANGELOG.md)
- [Security policy](SECURITY.md)

## License

[MIT](LICENSE)
