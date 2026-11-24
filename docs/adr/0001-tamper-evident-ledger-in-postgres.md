# ADR-0001: Tamper-evident double-entry ledger in PostgreSQL

## Status

Accepted (2026-11-20). Amended 2026-11-22: account type and owner added to the hashed entry text, accounts made append-only, reversals validated, the schema restructured into versioned migration layers so a product can extend it without changing core files, and the test suite made self-checking. Amended 2026-11-23 by [ADR-0002](0002-general-purpose-accounts-and-hash-format-v2.md) (v0.3.0): the ledger no longer has participant or vendor tables (accounts name their owner by type and ID), account and entry types are registered by the application, accounts are opened through `open_account()`, and the hash text uses the length-prefixed format `ledger-v2`. Amended 2026-11-23 by [ADR-0003](0003-tenants-across-databases-and-per-tenant-roles.md): tenants may live in any database and have their own roles. Where this record describes the original data model, hash text or roles, ADR-0002, ADR-0003 and the technical design take precedence.

## Context

The ledger was first built for a multi-tenant application that holds money on behalf of organizations: an organization loads funds into accounts it controls, the account holders spend those funds, and auditors review the activity. Each organization is a tenant with its own Postgres schema. (Since v0.3.0 the ledger is general-purpose; this context describes the kind of application it was first built for.)

The system of record for money has to:

- **Prove every balance.** A balance must be explainable as the sum of the movements behind it, not a number someone can overwrite.
- **Keep complete history.** Nothing is edited or deleted. Mistakes are corrected with new entries.
- **Make tampering detectable.** An auditor must be able to confirm that past records have not been changed, including by someone with full database access.
- **Stay correct under concurrency.** Two payments at the same moment must not overdraw an account or corrupt the record.
- **Tolerate retries.** A request that is sent twice (timeouts, double clicks) must not move money twice.
- **Cost little and be simple to operate.** The team is small and the application must run on a tight hosting budget.

Expected volume is modest: thousands to tens of thousands of entries per tenant per month, not millions per day.

Amazon QLDB, AWS's purpose-built ledger database, reached end of support on July 31, 2025. AWS recommends Amazon Aurora PostgreSQL as the replacement.

## Decision drivers

1. Correctness of balances and history
2. Tamper evidence that holds up to an outside auditor
3. Low cost and low operational overhead
4. Fit with the rest of the data model (tenants, account holders and business records are relational)
5. Portability (no lock-in to a single vendor's ledger product)

## Options considered

| Option | Summary | Outcome |
|---|---|---|
| Balance column updated in place | Store a balance per account and update it on each transaction | Rejected. No history, no audit trail, and vulnerable to lost updates under concurrency |
| Mutable transactions table | Log each movement in a normal table | Rejected. History exists but can be silently edited by anyone with database access |
| Amazon QLDB | AWS's managed ledger database with built-in cryptographic verification | Rejected. Retired July 31, 2025 |
| Blockchain (public chain or Hyperledger Fabric) | Distributed ledger shared by parties that don't trust each other | Rejected. There is a single operator, so the distributed trust model adds cost and complexity without benefit, and is a hard sell to public-sector buyers |
| immudb | Open-source immutable database with cryptographic proofs | Rejected. Strong tamper evidence, but adds a second database to run; relational data would still need Postgres |
| TigerBeetle | Open-source, very high-throughput double-entry accounting database | Rejected. Built for volumes far beyond what is expected here; adds a second system that only does accounting |
| Ledger as a service (e.g., Formance Cloud, Modern Treasury, Fragment) | A vendor hosts the ledger behind an API | Rejected. Ongoing fees, vendor lock-in, and core financial records held by a third party, which public-sector contracts may question |
| Event store (e.g., KurrentDB) | Append-only event database | Rejected. Same "second system" cost, weaker tooling for auditors |
| **Hash-chained double-entry ledger in PostgreSQL, with digests in S3 Object Lock** | Ledger tables in the existing Postgres database; tamper evidence anchored outside the database | **Chosen** |

## Decision

We will build the ledger in PostgreSQL, inside each tenant's schema, with these properties:

1. **Double-entry.** Each transaction is a `journal_entries` row with two or more `postings` lines. Lines must sum to zero. Amounts are whole cents in `bigint`; no floating point.
2. **Balances are derived.** Balances are always calculated from postings (the `account_balances` view), never stored as editable values.
3. **Append-only.** No application role has INSERT, UPDATE, or DELETE privilege on ledger tables or accounts. Triggers reject UPDATE, DELETE, and TRUNCATE on `journal_entries`, `postings`, `ledger_digests`, and `accounts` as a second layer, including for administrators. Corrections are reversing entries. An account opened by mistake is left unused rather than edited.
4. **Single write path.** `post_entry()` (SECURITY DEFINER) is the only way to write. It checks that every line names an existing account, enforces the zero-sum rule, validates reversals (below), rejects overdrafts on accounts that must not go negative, and writes the entry, postings, and hash in one transaction.
5. **Validated reversals.** A reversal must name an existing entry that is not itself a reversal and has not already been reversed, and its lines must mirror the original exactly: the same accounts with the amounts negated. A unique index on `reverses_seq` backs up the one-reversal rule. Only reversals may reference another entry.
6. **Serialized writes per tenant.** `post_entry()` locks a one-row `chain_head` table first. This gives gapless entry numbers, a chain that cannot fork, and a race-free overdraft check. Each tenant has its own chain, so tenants never wait on each other.
7. **Hash chain.** Each entry stores `prev_hash` and `entry_hash = SHA-256(prev_hash || canonical entry text)`. The canonical text covers the entry number, type, reference, reversal link, description, effective and recorded timestamps (UTC, microseconds), recording user, and every posting line in order. Each posting line includes the account's type and owner, so an account reassigned after the fact breaks the chain even if its triggers were switched off. One function (`entry_canonical`, with `posting_line` and `entry_lines` for the lines) produces this text for both writing and verification. Each tenant's chain starts from a genesis hash derived from the schema name, so entries cannot be moved between tenants undetected.
8. **Idempotency.** Every entry carries a unique `external_ref` (the originating request's ID). A true retry returns the original entry. Reusing a reference with different contents is rejected.
9. **External anchor.** A scheduled job periodically writes the latest chain hash to Amazon S3 with Object Lock in compliance mode, then calls `record_digest()`, which records the digest using the hash from the ledger itself, never from the caller.
10. **Verification.** `verify_chain()` walks the chain from genesis and reports the first problem: a gap in entry numbers, a broken link, changed contents (including a changed account), a chain head that doesn't match the last entry, or a recorded digest that no longer matches. When given the latest digest read back from S3, it also detects a chain that was rewritten end to end.
11. **Versioned migrations in layers.** The schema is a series of numbered migration files (`V<version>__<description>.sql`), split into shared (once per database) and tenant (once per tenant) folders. This repository supplies the core layer (`db/core/`). A product adds its own layer on top, in its own repository, without editing core files: companion tables keyed by core IDs, never changes to the ledger tables or functions. `scripts/migrate.sh` applies pending files in order, each in its own transaction, records them with a checksum in `ledger_migrations.history`, rejects edits to applied files, and replaces `${tenant}` with the tenant name. `scripts/provision_tenant.sh` creates a tenant (core, then any extension layers) and `scripts/upgrade.sh` brings the shared objects and every tenant up to date during a deploy. File naming and the placeholder follow Flyway's conventions, so the project can switch to Flyway later. Functions run with a fixed `search_path` of the tenant schema, `ledger_shared`, and `pg_temp` last.

## Consequences

### Positive

- One database for all data, so one system to run, back up, secure, and monitor.
- A purchase approval and its ledger entry commit in the same transaction; they cannot get out of step.
- The database enforces the money rules, including reversal rules, even if application code has a bug.
- Tampering by anyone, including a database administrator, is detectable once the affected entries are covered by an S3 digest. This includes reassigning an account to a different participant or vendor.
- Auditors can use plain SQL for balances, statements, and reconciliation.
- Low cost: the S3 anchor costs well under a cent per tenant per month at hourly digests.
- Portable across RDS, Aurora, other hosts, and local Docker.
- A new tenant is one command, every tenant is built from the same tested migrations, and existing tenants are upgraded by the same step.
- A product can add tables and fields in its own layer and pick up core releases without merge conflicts, because it never edits core files.

### Negative

- **Tamper-evident, not tamper-proof.** A superuser can still change data; the design detects it rather than preventing it.
- **Unanchored window.** Entries written after the most recent S3 digest are protected only by the hash chain. Someone with full access could delete the newest entries undetected until the next digest. Mitigation: export digests frequently (hourly or every N entries) and alert on gaps between digests.
- **Write throughput per tenant is limited** by the chain-head lock. This is far above expected volume; if it ever matters, chains can be split further (for example, one chain per group of accounts within a tenant).
- **We build and test this ourselves.** A ledger service would provide it ready-made. Correctness depends on thorough tests.
- **Full verification is linear in chain length.** Acceptable at this volume; can later verify incrementally from the last trusted digest, with periodic full runs.
- **Accounts cannot be corrected or closed in place.** Account ownership is permanent once created. A mistake means opening a new account, and closing an account needs a separate mechanism that has not been designed yet.
- **A reversal cannot be undone by another reversal.** To restore a reversed movement, post a new entry.
- **We maintain a small migration runner.** It covers what this project needs (ordering, history, checksums, the tenant placeholder, locking). If more is needed later, such as repair, dry runs or baselining, the files are already laid out for Flyway.

### Follow-up work

- Digest export job (S3 Object Lock, compliance mode, retention matched to records-retention rules) and scheduled verification with alerting.
- In the application: confirm that the approved business record behind a movement exists and matches before calling `post_entry()`, and mark it posted in the same transaction.
- Separate database logins per service (for example requests, approvals, ledger posting).
- A controlled way to open and close accounts through a function, instead of direct inserts by an administrator.
- Optional incremental verification from the latest trusted digest.

## Validation

Run with `scripts/run_tests.sh` on PostgreSQL 16 (2026-11-23). Each test file runs against a fresh database with the demo tenant `tenant_alpha` provisioned and seeded, and the script exits with an error if any check fails. All 73 checks passed at v0.2.0; at v0.3.0 the suite has 161 checks (see ADR-0002 and ADR-0003).

- **Normal operation:** balanced entries accepted; unbalanced, single-line, overdrawing, and unknown-account entries rejected; true retries return the original entry; conflicting reuse of a reference rejected.
- **Access control:** application roles cannot write to ledger tables, digests, or accounts directly, and each ledger role (`ledger_reader`, `ledger_poster`, `ledger_digest_writer`) can do only its own job; with triggers on, administrators cannot update, delete, or truncate ledger rows or reassign accounts.
- **Reversals:** a mirrored reversal is accepted in any line order and restores balances; second reversals, mismatched amounts or accounts, same-sign lines, reversals of reversals, missing originals, and overdrawing reversals are rejected.
- **Concurrency:** 40 payments of $100 released at the same instant against a $3,000 balance: exactly 30 accepted and 10 rejected, final balance $0, entry numbers gapless, chain verified against the S3 anchor.
- **Tampering with protections switched off:** a deleted middle entry, an edited digest row, a misplaced chain head, a reassigned account, and a changed account type were caught by internal checks. Deleting the newest entries (with the chain head and digest row adjusted) and a full end-to-end rewrite of the chain both passed internal checks but were caught when verified against the S3 digest. Deleting an entry newer than the last digest is not detectable, as described under Negative consequences; a test documents this.
- **Provisioning:** two tenants in one database have separate chains with different genesis hashes; an entry copied from one tenant into the other is detected; invalid tenant names and duplicate tenants are rejected before anything is created.
- **Migration layers:** an example application layer (`examples/app-layer`, `examples/extension` before v0.3.0) applies to a new tenant at provisioning and to an existing tenant on upgrade; a second upgrade applies nothing; a new version reaches every tenant; editing an applied file is rejected; a failing migration leaves no table and no history row; the core ledgers still verify afterwards.
- **The tests can fail:** removing the chain lock, the reversal mirror check, or the account owner from the hashed text each caused the expected checks to fail.

## References

- `db/core/shared/` and `db/core/tenant/` (core migrations: schema, functions, permissions)
- `scripts/migrate.sh`, `scripts/provision_tenant.sh`, `scripts/upgrade.sh` (migration runner, tenant creation, deploy upgrades)
- `examples/app-layer/` (how an application layers its own schema on top; `examples/extension/` before v0.3.0)
- `scripts/run_tests.sh` and `tests/` (seed data, test helpers, and test scripts 01 to 10)
- `docs/technical-design.md` (implementation details)
- AWS: Amazon QLDB end of support, July 31, 2025; migration guidance to Amazon Aurora PostgreSQL
- Michael Nygard, "Documenting Architecture Decisions" (2011)
