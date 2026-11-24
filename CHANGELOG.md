# Changelog

## v0.3.0 (2026-11-23)

A fresh start as a general-purpose ledger (ADR-0002). **Not upgradable from v0.1.x or v0.2.x:** the core migrations restart at V1, and `migrate.sh` rejects the changed files on an existing database by checksum. Create a new database. No release before this one was used with real data.

### Hardening before the first v0.3.0 tag

v0.3.0 had not been tagged yet, so these changes are part of it and the V1 migrations were updated in place. A database built from an earlier commit of v0.3.0 must be rebuilt.

- **Schemas renamed** to avoid clashing with application schemas: `shared` is now `ledger_shared`, and the migration history moved from `migrations.history` to `ledger_migrations.history`. Call `ledger_shared.register_account_type()` and `ledger_shared.register_entry_type()`, and use `ledger_shared` in `search_path`.
- **Timestamps limited to years 1-9999.** The hashed form has no era and no infinity, so a date moved to BC or between `infinity` and `-infinity` left every hash valid. `post_entry()` now refuses such values (`LD012`), CHECK constraints back it up, and `verify_chain()`, `tools/export_chain.sql` and `tools/verify_chain.py` report any that appear. The hash format is unchanged.
- **Stricter retries.** A repeated `external_ref` must also match the description and effective time, or it is rejected with `LD005` instead of silently returning the original. `recorded_by` may differ.
- **Ledger codes for every input error.** Malformed lines (not objects, non-integer or out-of-range `account_id` / `amount_cents`, more than 32767 lines) now raise `LD002` instead of a PostgreSQL cast error. New `LD012` for invalid entry fields. Lines are validated before the chain lock is taken.
- **Idempotent `record_digest()`.** Recording the same anchor again returns the hash; a different anchor for the same entry raises the new `LD011` instead of a unique-violation error.
- **Outside verifier exit codes.** `tools/verify_chain.py` exits with 2 (not 1, which means tampering) and a clear message on a malformed export, and no longer crashes on an infinite timestamp.
- **Owner role `ledger_owner`.** Every ledger object is owned by this NOLOGIN, non-administrator role, so `post_entry()`, `open_account()` and `record_digest()` (SECURITY DEFINER) no longer run with the rights of the administrator who ran the migrations. Never grant it to an application login.
- **Per-tenant roles.** Each tenant gets `ledger_<tenant>_reader`, `_poster`, `_opener` and `_digest`, with the group roles' rights on that tenant only (ADR-0003). A NOINHERIT service login switches into one per transaction, so a request routed to the wrong tenant is refused.
- **Tenant names are limited to 49 characters** (was 63), so `ledger_<tenant>_reader` fits PostgreSQL's 63-character role names.
- **Tenants in more than one database** (ADR-0003). `upgrade.sh --database DB` (repeatable; names or connection strings) upgrades several databases in one run. New `scripts/move_tenant.sh` copies a tenant to another database and verifies the copy. Scripts accept `LEDGER_DB` (a name or connection string).
- **Covering index** `postings_by_account (account_id) INCLUDE (amount_cents)` for the overdraft check.
- **Repository:** MIT `LICENSE`, `SECURITY.md`, CI on PostgreSQL 14-17 with read-only permissions, and `shellcheck`.

### Breaking

- **No owner tables.** `participants` and `shared.vendors` are gone. Accounts have `owner_type` and `owner_id`; applications keep their own owner tables, with a link table for foreign keys (see `docs/integration-guide.md`).
- **Registered types.** Account and entry types are no longer fixed. Register them with `shared.register_account_type(code, owner_type, allow_negative, description)` and `shared.register_entry_type(code, description)` in your shared migration. `reversal` is built in. The per-account `allow_negative` column is replaced by the type's rule.
- **`open_account(account_type, owner_type, owner_id)`** is the only way to open accounts (role `ledger_account_opener`). It is idempotent on type and owner.
- **Hash format `ledger-v2`.** Every field is length-prefixed, posting lines include the owner type, and the format name is hashed. Chains from earlier versions do not verify under v0.3.0.
- **Roles.** `app_rw` and `auditor_ro` are no longer created; auditors use `ledger_reader`. New role `ledger_account_opener`.
- **Digests.** `ledger_digests.s3_key` / `s3_version_id` are now `anchor_uri` / `anchor_version`; `record_digest(up_to_seq, anchor_uri, anchor_version)`.
- **Tenant names.** Any lowercase schema name (not reserved, not an SQL keyword); the `tenant_` prefix is no longer required. Set `LEDGER_TENANT_PREFIX` to require a prefix of your own.
- **Error codes.** Ledger errors carry SQLSTATE codes `LD001`-`LD010`; messages changed slightly.

### Added

- `docs/integration-guide.md`, ADR-0002, and a rewritten technical design with the hash format specification and a worked example.
- `tools/export_chain.sql` and `tools/verify_chain.py`: verify a chain outside PostgreSQL.
- `examples/app-layer/` (replaces `examples/extension/`): members with wallets, a link table, and `add_member()`.
- Tests: `12_types_and_accounts.sql` (24 checks), `13_outside_verifier.sh` (6 checks), tenant-name checks in `10_migrations.sh`, roles rewritten. 111 checks in total.

## v0.2.0 (2026-11-23)

### Breaking

- **`app_rw` no longer has any privileges.** It is replaced by three narrower group roles:
  - `ledger_reader`: read ledger tables and balances, run `verify_chain()`
  - `ledger_poster`: run `post_entry()`
  - `ledger_digest_writer`: run `record_digest()`

  `auditor_ro` is unchanged. Applications must connect with their own logins and be granted only the roles they need, for example `GRANT ledger_reader, ledger_poster TO svc_posting;`. Any code that relied on `app_rw` will get "permission denied" after upgrading.

### Upgrading

Run `scripts/upgrade.sh`. It applies `db/core/shared/V2__ledger_roles.sql` once and `db/core/tenant/V2__ledger_roles.sql` in every tenant. Then grant the new roles to your application logins. `app_rw` remains as an empty role that cannot log in; drop it yourself once nothing references it.

Extension layers that granted to `app_rw` should grant to `ledger_reader` (or their own roles) instead.

### Added

- `tests/11_roles.sql`: 15 checks that each role can do its own job and nothing else. The suite now has 73 checks.

## v0.1.0 (2026-11-22)

First tagged release: double-entry, append-only ledger with a per-tenant hash chain, S3 Object Lock anchoring, reversal rules, versioned migration layers, and 58 checks.
