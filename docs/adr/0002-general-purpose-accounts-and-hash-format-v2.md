# ADR-0002: General-purpose accounts, registered types, hash format v2, and a fresh start at v0.3.0

## Status

Accepted (2026-11-23). Amends ADR-0001 (data model and hash format). Extended by [ADR-0003](0003-tenants-across-databases-and-per-tenant-roles.md) (tenants in more than one database, per-tenant roles). Before v0.3.0 was tagged, the shared schema was renamed from `shared` to `ledger_shared`, and timestamps were limited to years 1 to 9999 without changing the hash format (see the changelog); this record uses the new names.

## Context

The ledger was built inside one application, and up to v0.2.0 that application's domain leaked into it:

- **Owner tables in the ledger.** The core migrations created `participants` and `shared.vendors`, and `accounts` had a foreign key to each. Application tables then hung off ledger tables, and any other application would have had to pretend its customers were "participants".
- **Fixed vocabularies.** Account types (`program_funding`, `participant_funds`, `vendor_payable`, …) and entry types (`fund_load`, `purchase`, `refund`, …) were CHECK constraints in the core.
- **A fixed tenant prefix.** Tenant names had to start with `tenant_`.
- **An ambiguous hash text.** The canonical entry text joined fields with `|`, posting lines with `:` and `,`. A description or reference can contain those characters, so characters could be moved between neighbouring fields (for example `ref "a|b", description "c"` and `ref "a", description "b|c"`) without changing the hashed text. Exploiting it needs database access and only shuffles text between fields, but a tamper-evidence design should not have the gap.
- **Two roles left over from v0.1** (`app_rw`, `auditor_ro`) and no function for opening accounts, so accounts were created outside the controlled write path.

The repository is meant to be public and usable by projects unrelated to that application. Nothing has been deployed with real data, so this is the cheapest time to correct the model.

## Decision drivers

1. The ledger knows nothing about any one application's domain
2. Tamper evidence stays at least as strong, and the hash format is unambiguous and documented well enough to reimplement
3. Applications keep referential integrity for their own owners
4. Every write goes through a controlled function
5. Simple to adopt: a working example and a step-by-step guide

## Options considered

| Option | Summary | Outcome |
|---|---|---|
| Keep the owner tables, rename them generically (`holders`, `payees`) | Small change | Rejected. Still forces an application's model into two fixed shapes |
| Owner as a foreign key to an application table | Strong integrity | Rejected. The core would depend on tables it does not own; an application layer cannot add foreign keys to core tables without editing them |
| **Owner as (owner type, owner ID) on the account; the application keeps a link table with foreign keys** | The core stores only what it hashes; the application keeps integrity on its side | **Chosen** |
| Account and entry types as free text | No registry | Rejected. Typos would create new types silently, and overdraft rules need a home |
| **A shared, append-only type registry the application writes in its migrations** | Types and their rules (owner type, may go negative) declared once | **Chosen** |
| Hash text as JSON | Unambiguous | Rejected. JSON output formatting (spacing, escaping, key order) differs between libraries, which makes outside verifiers fragile |
| **Length-prefixed fields (`<bytes>:<value>,`), versioned format name** | Unambiguous, trivial to reimplement in any language | **Chosen** |
| Upgrade path from v0.2 (new migrations, two hash formats verified side by side) | Keeps old chains | Rejected for now. No real data exists; a versioned format name leaves room to do this for any later change |
| **Fresh start: new V1 migrations, released as v0.3.0** | Clean history for the first public release | **Chosen** |

## Decision

1. **No owner tables in the ledger.** `accounts` has `owner_type` and `owner_id` (both or neither). The people and organizations that own accounts live in the application's tables. Applications that want foreign keys keep a link table on their side (for example `member_accounts (member_id → members, account_id → accounts)`).
2. **Type registry.** `ledger_shared.account_types` (code, owner type or none, whether negative balances are allowed) and `ledger_shared.entry_types` (code), both append-only, registered with idempotent `register_account_type()` / `register_entry_type()` in the application's shared migration. `reversal` is a built-in entry type. Overdraft rules come from the account's type; the per-account `allow_negative` column is gone.
3. **Account identity and opening.** An account is identified by its type and owner (one per pair; one per type for unowned accounts). `open_account()` is the only way to open one; it is idempotent, and a trigger enforces the type's owner rule.
4. **Hash format `ledger-v2`.** Every field is length-prefixed; each posting line covers line number, account ID, account type, owner type, owner ID and amount; the format name is the first field of every entry and of the genesis text. The full specification and a worked example are in the technical design.
5. **Outside verifier.** `tools/export_chain.sql` and `tools/verify_chain.py` (Python standard library only) verify an exported chain without PostgreSQL. The tests check that the database and the Python verifier agree.
6. **Roles.** `ledger_reader`, `ledger_poster`, `ledger_account_opener` (new), `ledger_digest_writer`. `app_rw` and `auditor_ro` are no longer created; auditors use `ledger_reader`.
7. **Stable error codes.** Every rejection raises its own SQLSTATE (`LD001`-`LD012`), so applications branch on codes rather than message text.
8. **Neutral naming.** `ledger_digests` stores `anchor_uri` and `anchor_version` (any write-once store, not only S3). `recorded_by` is the application's actor ID.
9. **Tenant names.** Any lowercase schema name that is not reserved or an SQL keyword. Applications that want a prefix set `LEDGER_TENANT_PREFIX`.
10. **Fresh start.** The core migrations restart at V1 (`db/core/shared/V1__ledger_shared.sql`, `db/core/tenant/V1__ledger.sql`). Databases built with v0.1.x or v0.2.x cannot be upgraded; the migration runner rejects the changed files by checksum. This breaks the rule "never edit a released migration" once, before any real deployment, and is recorded in the changelog. From v0.3.0 on, the rule holds, and any change to the hash format gets a new format name and a verified upgrade path.

## Consequences

### Positive

- Any application can use the ledger with its own vocabulary and its own owner model.
- The hash text is unambiguous; a field's contents can no longer be moved into its neighbour undetected.
- The format can be checked by an independent implementation, which helps outside auditors.
- Every write to the ledger, including opening accounts, goes through a SECURITY DEFINER function with its own role.
- The example application layer and the integration guide show the whole pattern, and the tests run the example.

### Negative

- The core cannot check that an owner exists; that integrity moves to the application's link table.
- Existing v0.1/v0.2 databases must be rebuilt (acceptable: demo data only).
- One account per (type, owner): an application that needs several similar accounts per owner registers several types.
- Applications must register types before opening accounts or posting, which is one more step to learn (covered in the guide).

## Validation

161 checks on PostgreSQL 16 (2026-11-23), including the new files `12_types_and_accounts.sql` (registry, owners, `open_account()`, encoding) and `13_outside_verifier.sh` (Python verifier agrees with the database, including separators, quotes, accents and reversals, and catches the same tampering). Removing the owner type from the hashed line on purpose made both the database check and the outside verifier fail.
