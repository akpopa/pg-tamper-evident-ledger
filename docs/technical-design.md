# Ledger Implementation: Technical Design

*Updated November 23, 2026 for v0.3.0. Companion to ADR-0001 (why a hash-chained ledger in PostgreSQL), ADR-0002 (general-purpose accounts, registered types, hash format `ledger-v2`), ADR-0003 (tenants in more than one database, per-tenant roles), the [integration guide](integration-guide.md), and the code in `db/`, `scripts/`, `tools/` and `tests/`.*

## Purpose and scope

This document describes how the ledger is implemented in PostgreSQL: the data model, the type registry, the write path, the hash chain, reversals, concurrency, access control, outside anchoring, verification, migrations and application layers, and testing. It is written for a reviewer who wants to check the design against the code. How to build an application on the ledger is in the integration guide.

In scope: the core migrations (`db/core/`), the migration and provisioning scripts, the export and outside verifier (`tools/`), and the test suite. Out of scope: anything an application builds on top (its users, its approval workflow, its API) and the job that copies digests to outside storage.

## Summary

The ledger is a double-entry, append-only record of money movements, stored in one PostgreSQL schema per tenant. The application registers the kinds of account and entry it uses. Accounts name their owner by type and ID (for example `customer` / `c-1042`); the people and organizations themselves live in the application's tables. All writes go through three functions: `open_account()`, `post_entry()` and `record_digest()`, which run as `ledger_owner`, a role with no administrator powers. `post_entry()` validates its input, locks the tenant's chain head, validates the entry (including reversals), rejects overdrafts, and links the entry into a SHA-256 hash chain whose text is unambiguous (every field length-prefixed) and covers each posting's account type and owner. Balances are always calculated. No role can write ledger tables directly, and triggers block edits even for administrators. A digest of the chain head can be copied to write-once storage, and `verify_chain()` checks the whole chain against it. An independent Python verifier (`tools/verify_chain.py`) checks an exported chain without PostgreSQL. Each tenant has its own roles, so a request routed to the wrong tenant is refused, and a tenant can live in any database and be moved between them (ADR-0003). 161 checks pass on PostgreSQL 16, and CI runs them on 14 to 17.

## Data model

### Schemas

| Schema | Objects | Purpose |
|---|---|---|
| `ledger_shared` | `account_types`, `entry_types`, `register_account_type()`, `register_entry_type()`, `ledger_field()`, `ledger_time_ok()`, `json_bigint()`, `create_tenant_roles()`, `forbid_change()` | The type registry and helpers shared by every tenant in the database. Each database that holds tenants has its own copy |
| one per tenant (for example `tenant_alpha`, `main`) | `accounts`, `journal_entries`, `postings`, `chain_head`, `ledger_digests`, `account_balances`; `open_account()`, `post_entry()`, `record_digest()`, `verify_chain()`, `entry_canonical()`, `posting_line()`, `entry_lines()` | One tenant's accounts, ledger and functions |
| `ledger_migrations` | `history` | Which migration files have been applied, with checksums |

A tenant is one ledger with its own chain: a customer organization in a multi-tenant product, or the only ledger in a single-tenant one. Tenant names are chosen by the application (see Tenant names).

### Type registry (shared)

**account_types**: append-only.

| Column | Notes |
|---|---|
| `code` | Primary key, lowercase identifier (for example `member_wallet`) |
| `owner_type` | Accounts of this type must be owned by this kind of owner (for example `member`). NULL: the application's own accounts (funding, clearing, fees), which have no owner |
| `allow_negative` | Whether accounts of this type may go below zero |
| `description`, `registered_at` | |

**entry_types**: append-only; `code`, `description`, `registered_at`. `reversal` is built in, because reversals have rules of their own.

`register_account_type()` and `register_entry_type()` are idempotent: registering a code again with the same rules does nothing, so the same calls can sit in a migration and a test seed. Registering an account type again with different rules is an error. Only the database owner can register types (EXECUTE is revoked from PUBLIC); this normally happens in the application's shared migration.

### Tenant tables

**accounts**: append-only.

| Column | Type | Notes |
|---|---|---|
| `account_id` | bigint identity | Primary key |
| `account_type` | text | References `ledger_shared.account_types` |
| `owner_type`, `owner_id` | text | Both set or both NULL. Must match the type's `owner_type` (checked by trigger). `owner_id` is 1 to 200 characters with no control characters |
| `opened_at` | timestamptz | |

An account is identified by its type and owner: a unique index allows one account per (type, owner), and one per type for accounts with no owner. Applications that need several accounts of the same kind per owner register several types.

**journal_entries**: one row per money movement, and one link in the hash chain.

| Column | Type | Notes |
|---|---|---|
| `sequence_no` | bigint | Primary key. Gapless, assigned under the chain lock |
| `entry_type` | text | References `ledger_shared.entry_types` |
| `external_ref` | text, unique | Idempotency key chosen by the application (1 to 200 characters) |
| `reverses_seq` | bigint | The entry being reversed; required for `reversal` and only allowed there; each entry can be reversed once |
| `description` | text | Hashed and permanent (see limitations) |
| `effective_at` | timestamptz | Business date; years 1 to 9999 (CHECK, see Timestamps) |
| `recorded_at` | timestamptz | Time written, from `clock_timestamp()`, truncated to microseconds; years 1 to 9999 (CHECK) |
| `recorded_by` | text | The application's user or process ID (1 to 200 characters) |
| `prev_hash`, `entry_hash` | bytea (32 bytes) | Hash chain links; `entry_hash` is unique |

**postings**: `sequence_no`, `line_no`, `account_id`, `amount_cents` (non-zero bigint, positive into the account, negative out). Primary key (`sequence_no`, `line_no`); indexed by account with the amount included, so balances and the overdraft check read only the index.

**chain_head**: exactly one row with `last_seq` and `last_hash`, locked by every writer. It starts at 0 with the tenant's genesis hash.

**ledger_digests**: one row per outside copy of the chain head, at most one per entry: `up_to_seq`, `entry_hash`, `anchor_uri` (where the copy was written, for example `s3://bucket/key`), `anchor_version` (that store's version ID), `exported_at`.

**account_balances** (view): each account with its type, owner, and the sum of its postings.

## Money and sign convention

Amounts are integers in the currency's smallest unit (cents for USD) in bigint, so there is no rounding. One tenant holds one currency. Each posting is signed; the lines of an entry must sum to zero. Account types that represent the application's own sources of money (funding, clearing) are registered with `allow_negative` and run negative by design.

| Event (example application) | Line 1 | Line 2 |
|---|---|---|
| Member tops up $50 | `topup_funding` −5000 | `member_wallet` +5000 |
| Member pays a merchant $20 | `member_wallet` −2000 | `merchant_payable` +2000 |
| Payment reversed | `merchant_payable` −2000 | `member_wallet` +2000 |

## Write path

### open_account(account_type, owner_type, owner_id)

SECURITY DEFINER with a fixed `search_path`. Returns the existing account with the same type and owner, or opens one. It looks first, so repeat calls do not use up identity values; an `INSERT … ON CONFLICT DO NOTHING` then handles two sessions opening the same account at once. The owner rule is enforced by a BEFORE INSERT trigger, so it also applies to accounts created by a migration.

### post_entry(...)

The only way to write entries. SECURITY DEFINER with a fixed `search_path` (tenant, `ledger_shared`, `pg_temp`), so callers need only EXECUTE and cannot redirect it.

Parameters: entry type, external reference, description, effective time, recorded-by ID, the lines as a JSON array of `account_id` and `amount_cents`, and an optional reversed entry number. Returns the entry's sequence number. Steps, in one transaction:

1. Reject an unregistered entry type (`LD001`), and invalid entry fields (`LD012`): an external reference or `recorded_by` that is NULL or not 1-200 characters, a NULL description, or an effective time outside years 1-9999 (see Timestamps).
2. Validate the lines without any lock (`LD002`, `LD003`): a JSON array of 2 to 32767 objects, each with an existing `account_id` and an `amount_cents` that are JSON integers within the `bigint` range (no fractions, exponents or strings), summing to zero. Each line's hashed form is built here with `posting_line()`.
3. Lock the chain head (`SELECT … FOR UPDATE`). Other writers in the same tenant wait here.
4. If the external reference exists with the same type, reversal link, description, effective time and lines, return the existing entry (a true retry). If it exists with different contents, raise `LD005`. `recorded_by` is not compared, because a retry may come from another worker.
5. If the entry is a reversal, validate it (see Reversals); otherwise it must not reference another entry.
6. Assign `last_seq + 1` and compute the hash from `last_hash` and the canonical text.
7. Insert the entry and its postings.
8. Reject the entry if any affected account whose type does not allow negative balances would end below zero. The sum reads amounts from the covering index `postings_by_account (account_id) INCLUDE (amount_cents)`, without visiting the table.
9. Move the chain head.

Any error rolls everything back, including the chain head, so a failed entry leaves no trace and no gap. Each kind of rejection has its own SQLSTATE (`LD001`-`LD012`, listed in the shared migration and the integration guide), so applications can handle errors without matching message text.

## Timestamps

The hashed text writes each timestamp as `YYYY-MM-DDTHH:MI:SS.USZ` in UTC. That form has no era and cannot express infinity: 44 BC and 44 AD encode the same, and `infinity` and `-infinity` both encode as NULL. A change between such values would leave every hash valid. So `effective_at` and `recorded_at` are limited to years 1-9999 (`ledger_shared.ledger_time_ok()`, enforced by CHECK constraints and by `post_entry()` with `LD012`), and `verify_chain()` and `tools/verify_chain.py` report any stored timestamp outside that range, which can only appear if someone removed the constraints. The hash format is unchanged.

## Reversals

`post_entry()` accepts a reversal only if the original exists, is not itself a reversal, has not been reversed already (also enforced by a unique index), and the reversal's lines mirror it exactly: the same accounts with the amounts negated, in any line order. The overdraft rule still applies. A retried reversal returns the original reversal.

## Hash chain (format `ledger-v2`)

### Encoding

Every field is length-prefixed by `ledger_shared.ledger_field()`:

```
field(value) = "<length of value in UTF-8 bytes>:<value>,"     NULL -> "-"
```

Because each field states its own length, no characters can move from one field into its neighbour without changing the text, whatever the fields contain. (The earlier `ledger-v1` format joined fields with `|`, `:` and `,`, which a description or reference could also contain; see ADR-0002.) An empty string encodes as `0:,`, which differs from NULL.

### Posting line

```
posting_line = field( field(line_no) field(account_id) field(account_type)
                      field(owner_type) field(owner_id) field(amount_cents) )
```

Numbers are written in plain decimal (`-100000`). The account's type and owner are part of the line, so the chain covers ownership: reassigning an account, or changing its type or owner type, breaks the hash of every entry that touches it.

### Entry text and hash

```
canonical  = field("ledger-v2") field(sequence_no) field(entry_type) field(external_ref)
             field(reverses_seq) field(description) field(effective_at) field(recorded_at)
             field(recorded_by) field(lines)
lines      = posting lines concatenated in line order
times      = UTC with microseconds: YYYY-MM-DDTHH:MI:SS.ffffffZ
entry_hash = sha256( prev_hash || UTF-8 bytes of canonical )
genesis    = sha256( UTF-8 bytes of field("ledger-v2") field("genesis") field(tenant name) )
```

Worked example, entry 1 of `tenant_alpha` (a $1,000 load from a funding account to holder `h-1`), recorded at 2026-11-23T21:37:49.764237Z:

```
posting line 1: 30:1:1,1:1,7:funding,--7:-100000,,
posting line 2: 48:1:2,1:2,12:holder_funds,6:holder,3:h-1,6:100000,,
canonical:      9:ledger-v2,1:1,4:load,6:LOAD-1,-13:Initial funds,27:2026-11-19T05:00:00.000000Z,27:2026-11-23T21:37:49.764237Z,3:sys,86:30:1:1,1:1,7:funding,--7:-100000,,48:1:2,1:2,12:holder_funds,6:holder,3:h-1,6:100000,,,
genesis:        1450af9d94b8a91c183561579863bdf264bd829fac3f05b6712510dba34179cf
entry_hash:     5403106031882732c68aa0ed1a5a9ae4433430ba9cd03251f2502390c464a3b4
```

The format name is the first field of every entry and of the genesis text, so a later format can be introduced alongside it.

Each tenant's genesis differs (it includes the tenant name), so an entry copied from one tenant's chain into another breaks verification. `post_entry()` and `verify_chain()` build the text with the same functions, and `tools/verify_chain.py` reimplements it independently; the tests check that all three agree, including fields that contain separators, quotes and accented characters.

## Concurrency and ordering

The chain head row is a per-tenant mutex: entries are numbered without gaps, the chain cannot fork, and the overdraft check sees every earlier committed entry. Tenants never block each other. Writes within one tenant are serialized; each holds the lock for a few milliseconds. `tests/07_concurrency.sh` releases 40 payments at the same instant against a balance that covers 30: exactly 30 succeed and 10 are rejected.

## Idempotency

`external_ref` is unique per tenant. A retried call with the same reference, entry type, reversal link, description, effective time and lines returns the original entry, so a timeout or a double submit never moves money twice; `recorded_by` may differ, because a retry can come from another worker. Reusing a reference with anything else different is an error (`LD005`). `open_account()` is idempotent on (type, owner), and `record_digest()` on (entry, anchor).

## Access control

| Role | Tables | Functions |
|---|---|---|
| `ledger_reader` | SELECT on ledger tables, the balances view, and the type registry | `verify_chain()`, `entry_canonical()`, `posting_line()`, `entry_lines()` |
| `ledger_poster` | None | `post_entry()` |
| `ledger_account_opener` | None | `open_account()` |
| `ledger_digest_writer` | None | `record_digest()` |
| PUBLIC | None | None (the default EXECUTE grant is revoked) |

These are group roles that cannot log in; each service connects with its own login and is granted only what it needs. No role has INSERT, UPDATE or DELETE on ledger tables or the registry. Roles are cluster-wide, so the shared migration creates them only if missing. Grants in the tenant migration name the ledger's objects one by one, so an application's own tables in the same schema are never exposed by accident.

Each tenant also has its own roles, `ledger_<tenant>_reader`, `_poster`, `_opener` and `_digest`, created by `ledger_shared.create_tenant_roles()` from the tenant migration, with the same rights as the group roles on that tenant only (ADR-0003). A service login created NOINHERIT and granted several tenants' roles has no ledger rights until it runs `SET LOCAL ROLE` for one tenant, so a request routed to the wrong tenant is refused.

Every ledger table, view and function, in `ledger_shared` and in each tenant, is owned by `ledger_owner`: NOLOGIN, not a superuser, no CREATEROLE, CREATEDB, REPLICATION or BYPASSRLS (the shared migration refuses to continue if an existing `ledger_owner` has any of these). The SECURITY DEFINER functions therefore run with rights over the ledger's own objects only, not with the rights of the administrator who ran the migrations. `ledger_shared` is owned by `ledger_owner`; each tenant schema stays with the migrating user, because application layers add their own tables to it, and `ledger_owner` gets USAGE and CREATE on it. An owner can disable its tables' triggers, so no application login may be granted `ledger_owner`.

BEFORE UPDATE/DELETE and BEFORE TRUNCATE triggers on `accounts`, `journal_entries`, `postings`, `ledger_digests` and both registry tables call `ledger_shared.forbid_change()`. A superuser can still disable triggers, which is why tamper detection does not rely on them.

## Outside anchoring

Hash checks inside the database cannot stop someone with full access from recomputing the whole chain. The outside anchor closes that gap:

1. A scheduled job reads the chain head.
2. It writes a small JSON document (tenant, entry number, hash, time) to write-once storage, for example Amazon S3 with Object Lock in compliance mode, or MinIO with Object Lock for local development.
3. It calls `record_digest(up_to_seq, anchor_uri, anchor_version)`. The function takes the hash from the ledger itself, so a caller cannot record a fake one. Recording the same anchor again returns the same hash (safe to retry); a different anchor for an entry that already has one is rejected with `LD011`.

The job itself belongs to the application (or a future companion package); the ledger only records and checks digests.

## Verification

`verify_chain(p_anchor_seq, p_anchor_hash)` returns the first problem as `(bad_seq, problem)`, or no rows. The anchor arguments are optional and go together.

| Check | Detects |
|---|---|
| Entry numbers run 1, 2, 3 with no gaps | Deleted middle entries |
| Each `prev_hash` matches the hash carried forward | Broken or reordered links; entries copied from another tenant |
| Each timestamp is within years 1 to 9999 | Edits the hash cannot see: a date moved to BC, or between `infinity` and `-infinity` (see Timestamps) |
| Each `entry_hash` matches a hash recomputed from current data | Changed amounts, accounts, times, text; an account reassigned or retyped |
| Chain head matches the last entry | Entries removed from the end; a misplaced head |
| Each recorded digest still matches its entry | Edited digest rows |
| Optional: the anchored entry exists with the anchored hash | A chain rewritten end to end, or covered entries deleted |

**Outside the database.** `tools/export_chain.sql` exports one tenant's chain as JSON lines (needs `ledger_reader`), and `tools/verify_chain.py` (Python 3, standard library only) runs the same checks from the export and an anchor. An auditor can verify a ledger without trusting the database's own functions.

## Tenant names

A tenant name is a PostgreSQL schema name: a lowercase letter, then lowercase letters, digits or underscores, 49 characters at most. The limit leaves room for the tenant's roles: PostgreSQL role names are at most 63 characters, and the longest is `ledger_<tenant>_reader` (7 + 49 + 7). Roles belong to the server, so tenant names must be unique on a server; applications should keep them unique across all their databases, since the name is also part of the chain's genesis hash. `ledger_shared`, `ledger_migrations` (and the older names `shared` and `migrations`), `public`, `information_schema`, names starting with `pg_`, and SQL keywords (anything PostgreSQL's `quote_ident()` would quote, such as `user`) are refused. Provisioning refuses an existing schema, so a tenant can never take over an application schema. An application can require its own prefix by setting `LEDGER_TENANT_PREFIX` (for example `tenant_`) when running the scripts.

## Migrations and application layers

Migration files are named `V<version>__<description>.sql` and applied once each, in version order. Each layer has a `shared/` folder (applied once per database) and a `tenant/` folder (applied to each tenant, with `${tenant}` replaced by the tenant name).

- `scripts/migrate.sh <shared|tenant> <layer> <dir>` applies pending files from one folder. Each file runs in one transaction with its history record; applied files are recorded with a SHA-256 checksum, and an edited file is rejected. An advisory lock prevents concurrent runs.
- `scripts/provision_tenant.sh <tenant> [--layer NAME=DIR]...` validates the name, refuses an existing schema, brings shared objects up to date, then applies the core tenant migrations and each application layer in order.
- `scripts/upgrade.sh [--database DB]... [--layer NAME=DIR]...` is the deploy step for every tenant; running it again changes nothing. With several `--database` options (names or connection strings) it upgrades each database in turn and stops at the first failure, naming it.
- `scripts/move_tenant.sh <tenant> --to <database> [--layer NAME=DIR]...` copies one tenant to another database (ADR-0003): it brings the target's shared objects up to date, creates the tenant's roles, copies the schema, data, grants and migration history with `pg_dump` in one transaction, refuses if the source's chain head moved during the copy, and checks that the copy verifies and ends at the source's head. It never deletes the source. The target must run the same PostgreSQL major version as the source or newer, and `pg_dump` must be between the two versions; the script checks before writing anything.
- All scripts take the database from `LEDGER_DB` (a name or a connection string) if set, otherwise from the `PG*` variables (`scripts/_db.sh`).

The core layer is `db/core/`. An application keeps its own layer in its own repository; `examples/app-layer/` is a working example used by the tests. Naming follows Flyway's conventions.

**Upgrading from v0.2.x.** v0.3.0 starts a new migration history (ADR-0002). Databases built with v0.1.x or v0.2.x cannot be upgraded in place: `migrate.sh` rejects the changed V1 files by checksum. Create a new database.

## Testing

`scripts/run_tests.sh` runs each test file against a fresh database with `tenant_alpha` provisioned and seeded (`tests/00_seed.sql`: four account types, two entry types, three accounts, a $1,000 load, three $100 payments, a digest at entry 3). Tamper scenarios switch protections off with `session_replication_role = replica`, so the suite needs a superuser connection. Checks print PASS or FAIL; the runner fails if any check fails or any script stops early.

| File | Checks | What it covers |
|---|---|---|
| `01_normal.sql` | 19 | Verification, balances, retries, conflicting references, unbalanced, single-line, overdrawing and unknown-account entries, references from non-reversals, missing digest targets, direct writes, administrator edits with triggers on, no trace from rejected attempts |
| `02_delete_middle.sql` | 1 | Deleted middle entry caught as a gap |
| `03_delete_end.sql` | 3 | Deleting an unanchored newest entry is not detectable (documented limitation); deleting anchored entries is caught with the anchor |
| `04_rewrite.sql` | 2 | A consistently rewritten chain passes internal checks and is caught with the anchor |
| `05_digest_row.sql` | 1 | Edited digest row caught |
| `06_chain_head.sql` | 1 | Misplaced chain head caught |
| `07_concurrency.sh` | 6 | 40 simultaneous payments against a balance for 30 |
| `08_accounts.sql` | 4 | Reassignment blocked with triggers on; reassignment, type change and owner-type change with triggers off caught by the chain |
| `09_reversals.sql` | 13 | Valid reversals, retries, and every rejected case |
| `10_migrations.sh` | 13 | The example application layer at provisioning and on upgrade; new versions; edited and failing migrations; duplicate tenants; core history; the link-table pattern; tenant names without a prefix, with `LEDGER_TENANT_PREFIX`, keywords and reserved names |
| `11_roles.sql` | 23 | Each role does its own job and nothing else; nobody can write tables or register types directly; every ledger object is owned by `ledger_owner`, which cannot log in, has no administrator powers and is not granted to any ledger role |
| `12_types_and_accounts.sql` | 24 | Registry rules, `open_account()` idempotency and owner rules, unregistered entry types, overdraft rules from the type, unambiguous encoding, SQLSTATE codes |
| `13_outside_verifier.sh` | 8 | The Python verifier agrees with the database on intact chains (including separators, quotes, accents and reversals), genesis, and tampering; reports an unhashable timestamp as a chain problem; exits with status 2 on a malformed export |
| `14_input_validation.sql` | 21 | Entry fields and malformed lines get ledger codes (`LD012`, `LD002`) instead of cast errors; retries must match description and effective time; idempotent digests and `LD011`; BC and infinite timestamps edited in with protections off are reported by `verify_chain()` |
| `15_tenant_roles.sh` | 10 | Per-tenant roles exist and cannot log in; a NOINHERIT login reaches a tenant only after switching into its role, and is refused on another tenant; an application role combining poster and opener; the 49-character tenant name limit |
| `16_multiple_databases.sh` | 12 | One upgrade across two databases, by name and connection string, without printing passwords, stopping at a failing database; moving a tenant keeps its chain head, balances, outside anchor, history, owner and grants, posting continues on the target, the source is untouched; refused moves leave nothing behind |

All 161 checks passed on PostgreSQL 16 (2026-11-23); CI also runs them on PostgreSQL 14, 15 and 17. To confirm the checks can fail, the owner type was removed from the hashed line on purpose: the database's own check (G4) and the outside verifier (V1, V3, V4) failed as expected.

## Known limitations

- **Tamper-evident, not tamper-proof.** A superuser can change data; the design detects it.
- **Unanchored window.** Entries newer than the latest digest are protected only by the chain. Frequent digests keep the window small.
- **Accounts are permanent.** A mistaken account cannot be fixed in place. Closing accounts is not designed yet.
- **Permanent text.** Descriptions, references, owner IDs and `recorded_by` are hashed and permanent. Never put personal data in them; use IDs and generic labels, and keep names in the application's tables.
- **One currency per tenant.** Multi-currency needs one tenant per currency, or a future design.
- **Serialized writes per tenant.** Fine for expected volumes; a busy tenant could be split, or moved to its own database (ADR-0003).
- **Per-tenant roles guard against bugs, not a stolen login.** A service login that may switch into every tenant's role can reach every tenant; tenants that need more get their own database and login.
- **Group roles span the server.** `ledger_reader`, `ledger_poster` and the others reach every tenant in every database on the server; multi-tenant applications should use the per-tenant roles.
- **Moving a tenant needs a pause.** `move_tenant.sh` requires writes to the tenant to stop during the copy. Removing a tenant (and its roles) is not designed yet.
- **Verification cost grows with the chain.** `verify_chain()` walks every entry. Incremental verification from the latest outside digest can be added, but only as a complement: an edit to an older entry is caught only by a full walk, so run one periodically.
- **Overdraft checks grow with an account's history.** Each entry sums the full history of the accounts it touches (from a covering index). Very long-lived, busy accounts may later need balance checkpoints.
- **Timestamps are limited to years 1-9999.** The hashed form has no era and no infinity, so wider values are refused on input and reported by both verifiers (see Timestamps).

## Glossary

- **Tenant**: one ledger with its own schema, chain and roles, in any database.
- **Account type / entry type**: kinds registered by the application in the shared registry.
- **Owner**: who an account belongs to, as an owner type and ID; the owner itself lives in the application.
- **Journal entry**: one money movement, made of two or more postings that sum to zero.
- **Posting**: one line of an entry.
- **Reversal**: an entry that exactly undoes one earlier entry.
- **Chain head**: the row holding a tenant's latest entry number and hash.
- **Genesis hash**: the starting hash of a tenant's chain.
- **Digest / anchor**: a copy of the chain head kept in write-once storage outside the database.
- **Application layer**: an application's own migrations, applied on top of the core.
