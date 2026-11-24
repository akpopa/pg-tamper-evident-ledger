# Integrating the ledger into your project

This guide is for developers who want to use this ledger as the system of record for money in their own application: a wallet, a marketplace, a benefits or grants platform, an internal chargeback system, anything where balances must be provable and history must not change.

It covers adding the ledger to your repository, describing your accounts, keeping your own tables alongside it, calling it from your code, anchoring it outside the database, and upgrading. The working example in [`examples/app-layer`](../examples/app-layer) follows every step here, and the test suite runs it.

Background: [ADR-0001](adr/0001-tamper-evident-ledger-in-postgres.md) (why), [ADR-0002](adr/0002-general-purpose-accounts-and-hash-format-v2.md) (the general-purpose model), [technical design](technical-design.md) (how it works, including the hash format).

## 1. What you get, and what you build

**The ledger gives you:**

- Double-entry, append-only accounts and entries in PostgreSQL, one schema (tenant) per ledger.
- One write path: `open_account()` and `post_entry()`, with validation, overdraft protection, safe retries and exact reversals.
- A SHA-256 hash chain over every entry, `verify_chain()`, and digests you can anchor in write-once storage so tampering is detectable even by a database administrator.
- An independent verifier (`tools/verify_chain.py`) for auditors.
- Versioned migrations with layers, so your schema lives next to the ledger without editing it.
- Least-privilege database roles, including roles per tenant so a request routed to the wrong tenant is refused.
- Support for tenants in more than one database: one deploy step for all of them, and a verified move of a tenant to its own database or server.

**You build:**

- Your own tables for the people and organizations that own accounts, and for your business records (orders, invoices, requests, approvals).
- The logic that decides *whether* money should move (approvals, limits, fraud checks). The ledger decides only whether an entry is valid.
- A small scheduled job that copies digests to outside storage and runs verification.
- A tenant directory (which database each tenant lives in), if you have more than one tenant (section 12).

## 2. Concepts in five minutes

| Concept | What it means |
|---|---|
| **Tenant** | One ledger: a PostgreSQL schema with its own accounts and hash chain. Use one per customer organization in a multi-tenant product, or a single one (`main`) otherwise. One currency per tenant |
| **Account type** | A kind of account you register, for example `member_wallet`. It says who owns such accounts (`member`) or that nobody does (your own funding or clearing accounts), and whether the balance may go below zero |
| **Owner** | Who an account belongs to, as an owner type and ID, for example `member` / `5b1c…`. The owner itself lives in *your* tables; the ledger only records the reference |
| **Entry type** | A kind of movement you register, for example `topup` or `purchase`. `reversal` is built in |
| **Journal entry** | One movement: two or more lines that sum to zero. Amounts are integers in the currency's smallest unit (cents) |
| **External reference** | Your unique ID for the movement (for example `ORDER-8812`). It makes retries safe and links the entry back to your records |
| **Digest (anchor)** | A copy of the chain head written to storage nobody can change (for example S3 Object Lock). Verification against it detects even a fully recomputed chain |

## 3. Requirements

- PostgreSQL 14 or later (tested on 16). It uses only standard features (PL/pgSQL, the built-in `sha256()`, roles), so managed services such as Amazon RDS and Aurora PostgreSQL should work; the migrations need a user that can create roles (on RDS, the master user). Not yet tested there.
- `pg_dump` (same major version as the target server) if you will move tenants between databases.
- `psql` and bash for the migration scripts (or port the scripts to your migration tool; see section 11).
- Python 3 only if you use the outside verifier.

## 4. Add the ledger to your repository

The recommended setup is a git submodule pinned to a release tag:

```
git submodule add https://github.com/<owner>/<ledger-repo> vendor/ledger
cd vendor/ledger && git checkout v0.3.0 && cd ../..
git commit -m "Add ledger v0.3.0"
```

Never edit files under `vendor/ledger`. If you need a change in the ledger, propose it upstream, and move your pin when it is released.

Your repository then looks like this:

```
your-app/
  vendor/ledger/          the ledger, pinned to a tag
  db/app/shared/          your database-wide migrations
  db/app/tenant/          your per-tenant migrations (${tenant} placeholder)
```

## 5. Create your application layer

### 5.1 Register your types (shared migration)

`db/app/shared/V1__types.sql`:

```sql
-- Who can own accounts, and whether balances may go negative.
SELECT ledger_shared.register_account_type('topup_funding',    NULL,       true,  'Money received from card top-ups');
SELECT ledger_shared.register_account_type('member_wallet',    'member',   false, 'A member''s stored balance');
SELECT ledger_shared.register_account_type('merchant_payable', 'merchant', false, 'What we owe a merchant');

SELECT ledger_shared.register_entry_type('topup',    'A member adds money');
SELECT ledger_shared.register_entry_type('purchase', 'A member pays a merchant');
```

- Codes are lowercase identifiers. Types are permanent: you cannot change a type's rules later, only add new types. Choose `allow_negative` carefully: `true` for your own source and clearing accounts, `false` for anything that holds someone's money.
- Registration is idempotent, so the same calls can go in your test seed.
- Put your own database-wide tables in **your own schema** (for example `app`), not in the ledger's `ledger_shared` schema.

### 5.2 Keep your owners, linked with foreign keys (tenant migration)

The ledger cannot reference your tables, so keep a link table on your side. It gives you foreign keys in both directions and a fast way from your record to its account:

```sql
-- db/app/tenant/V1__members.sql
CREATE TABLE ${tenant}.members (
  member_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  display_name  text NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE ${tenant}.member_accounts (
  member_id   uuid   PRIMARY KEY REFERENCES ${tenant}.members,
  account_id  bigint NOT NULL UNIQUE REFERENCES ${tenant}.accounts
);
```

Rules for your layer:

- **Do not alter ledger tables or functions** (no extra columns, triggers or indexes on `accounts`, `journal_entries`, `postings`, `chain_head`, `ledger_digests`). Put your fields in your own tables keyed by the ledger's IDs (`account_id`, `sequence_no`) or link through `external_ref`.
- Don't use `GRANT ... ON ALL TABLES IN SCHEMA` on a tenant schema: it would also grant on the ledger's tables. Grant on your own tables by name.
- Never edit a migration once applied; add the next version.

## 6. Choose tenant names

A tenant name is a PostgreSQL schema name: a lowercase letter, then lowercase letters, digits or underscores, **49 characters at most**. The limit comes from the tenant's own roles (section 8): PostgreSQL role names are at most 63 characters, and the longest is `ledger_<tenant>_reader` (7 + 49 + 7). A longer name is refused with that explanation. `ledger_shared`, `ledger_migrations` (and the older names `shared` and `migrations`), `public`, `information_schema`, names starting with `pg_`, and SQL keywords are refused. Provisioning also refuses a schema that already exists, so a tenant can never take over one of your schemas.

To enforce your own convention, set a prefix when you run the scripts:

```
export LEDGER_TENANT_PREFIX=org_      # every tenant must be org_<something>
```

Store the tenant name with your organization record, and take it from the signed-in user's verified token or session, never from request input.

**Keep tenant names unique across all your databases.** Roles belong to the server, so two databases on one server cannot both have a tenant called `main` without sharing its roles. And the name is part of the tenant's chain (its genesis hash), so it moves with the tenant (section 12) and can never change.

## 7. Provision and deploy

Connection settings come from the standard `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD` and `PGDATABASE` variables. To point a script at a database on another server, set `LEDGER_DB` to a full connection string (for example `postgresql://deploy@db-2.internal:5432/ledger`); `PGDATABASE` accepts only a plain name. Run migrations as the database owner (on RDS, the master user or a migration role), not as a service login.

```
# Create a tenant: shared objects, the ledger, then your layer
vendor/ledger/scripts/provision_tenant.sh org_acme --layer app=db/app

# Deploy: apply anything new to the shared objects and every tenant
vendor/ledger/scripts/upgrade.sh --layer app=db/app
```

`upgrade.sh` is safe to run on every deploy; it applies only what is pending and records a checksum of each file.

If your tenants live in more than one database, list them all; each can be a name or a connection string, and the first failure stops the run and names the database:

```
vendor/ledger/scripts/upgrade.sh --layer app=db/app \
  --database ledger_pooled \
  --database "postgresql://deploy@db-large-tenant.internal/ledger"
```

Keep that list in your deploy configuration, generated from the same tenant directory your application uses (section 12).

## 8. Database logins and roles

The ledger creates four group roles. Give each of your services its own login, and grant only what it needs:

| Role | Allows |
|---|---|
| `ledger_reader` | Read accounts, entries, postings, balances, digests and the type registry; run `verify_chain()` |
| `ledger_poster` | Run `post_entry()` |
| `ledger_account_opener` | Run `open_account()` |
| `ledger_digest_writer` | Run `record_digest()` |

```sql
CREATE ROLE svc_payments LOGIN;                       -- password or IAM auth, as you prefer
GRANT ledger_reader, ledger_poster TO svc_payments;
CREATE ROLE svc_onboarding LOGIN;
GRANT ledger_account_opener TO svc_onboarding;
GRANT SELECT, INSERT ON org_acme.members, org_acme.member_accounts TO svc_onboarding;  -- your tables, your grants
```

No role can write ledger tables directly; the functions are the only way in. Roles are cluster-wide, so grant them once per server, and grant your own table privileges in your tenant migrations so every tenant gets them.

### 8.1 Per-tenant roles

The group roles above reach **every tenant on the server**. Each tenant also gets four roles of its own, with the same rights on that tenant only:

| Role | Allows, on this tenant only |
|---|---|
| `ledger_<tenant>_reader` | Same as `ledger_reader` |
| `ledger_<tenant>_poster` | Same as `ledger_poster` |
| `ledger_<tenant>_opener` | Same as `ledger_account_opener` |
| `ledger_<tenant>_digest` | Same as `ledger_digest_writer` |

Use them in a multi-tenant application so that a request routed to the wrong tenant fails instead of writing to another tenant's ledger. Create the service login **NOINHERIT**, so membership alone gives it no rights, and switch into the tenant's role at the start of each transaction:

```sql
CREATE ROLE svc_payments LOGIN NOINHERIT;
GRANT ledger_org_acme_poster, ledger_org_acme_reader TO svc_payments;   -- in each tenant's migration
```

```sql
BEGIN;
SET LOCAL ROLE ledger_org_acme_poster;      -- the tenant from the verified session
SELECT org_acme.post_entry(...);            -- org_beta.post_entry(...) would be refused here
COMMIT;                                     -- the role switch ends with the transaction
```

`SET LOCAL ROLE` takes one role. When a request needs several (open an account and post), create your own per-tenant role in your tenant migration that includes them, and switch into that:

```sql
CREATE ROLE app_${tenant} NOLOGIN;
GRANT ledger_${tenant}_poster, ledger_${tenant}_opener TO app_${tenant};
GRANT app_${tenant} TO svc_payments;
```

This guards against bugs, not a stolen login: a login that can switch into every tenant's role can still reach every tenant. If a tenant needs isolation from a compromised login too, give it its own database and a login used for nothing else (section 12). A single-tenant application can keep using the group roles.

Role names are limited to 63 characters, which is why tenant names are limited to 49 (section 6). Roles belong to the server and are not included in a `pg_dump` of a database; when you restore onto a new server, restore the roles first (`pg_dumpall --roles-only`), or let `scripts/move_tenant.sh` create them.

### 8.2 The owner role

Every ledger table, view and function is owned by `ledger_owner`, a role the migrations create that cannot log in and has no administrator powers. The write functions run with its rights, not those of the administrator who ran the migrations. Run the migrations as an administrator as usual; ownership is handed over automatically. **Never grant `ledger_owner` to an application login, and never let anything log in as it:** an owner can switch off its tables' triggers.

## 9. Using the ledger from your code

Set the tenant once per transaction, then call the functions. The examples use SQL; any PostgreSQL driver works the same way.

```sql
BEGIN;
SET LOCAL ROLE app_org_acme;                                -- the tenant's role (section 8.1)
SET LOCAL search_path = org_acme, ledger_shared, pg_temp;   -- the tenant from the verified session
-- ... calls below ...
COMMIT;
```

With the group roles (a single-tenant application) leave out `SET LOCAL ROLE`.

### 9.1 Open an account

```sql
SELECT open_account('member_wallet', 'member', '5b1c2f0e-0c3e-4f5e-9a51-0c8f2e4b9d10');  -- returns account_id
SELECT open_account('topup_funding');                                                    -- your own account, no owner
```

`open_account()` returns the existing account if one with the same type and owner exists, so it is safe to call again. Do it in the same transaction that creates your owner, and insert the link row:

```sql
INSERT INTO members (display_name) VALUES ('Ada') RETURNING member_id;          -- your table
SELECT open_account('member_wallet', 'member', $member_id);
INSERT INTO member_accounts (member_id, account_id) VALUES ($member_id, $account_id);
```

### 9.2 Post an entry

```sql
SELECT post_entry(
  'purchase',                       -- registered entry type
  'ORDER-8812',                     -- your unique reference: idempotency key and link back to your record
  'Order 8812',                     -- short label; permanent, no personal data
  '2026-11-23T15:00:00Z',           -- effective (business) time
  'user:5b1c2f0e',                  -- who or what posted it, as your own ID
  '[{"account_id": 12, "amount_cents": -2500},
    {"account_id": 31, "amount_cents":  2500}]'::jsonb
);                                  -- returns the entry's sequence number
```

- Lines must sum to zero. Negative takes money out of an account, positive puts it in.
- **Retries are safe.** Sending the same reference, type, description, effective time and lines again returns the original entry number, even if `recorded_by` differs (a retry may come from another worker). Reusing a reference with any of those different is an error (`LD005`), which usually means a bug.
- **Amounts and account IDs must be JSON integers** (`2500`, not `"2500"` or `25.00`). Send them as numbers from your code.
- **Effective times must fall in years 1-9999.** `infinity` and BC dates are refused (`LD012`), because the hash cannot represent them unambiguously.
- **Use your own record's ID as the reference**, and update your record in the same transaction, so the business record and the money movement commit together:

```sql
BEGIN;
SET LOCAL search_path = org_acme, ledger_shared, pg_temp;
SELECT post_entry('purchase', 'ORDER-' || $order_id, 'Order ' || $order_id, now(), $actor, $lines);
UPDATE orders SET status = 'paid', ledger_seq = $seq WHERE order_id = $order_id;   -- your table
COMMIT;
```

- **Keep the transaction short.** `post_entry()` locks the tenant's chain head until your transaction ends, so other postings in that tenant wait. Do slow work (calls to payment providers, emails) before or after, not inside.

Example in Node.js with `pg`:

```js
async function postPurchase(pool, tenant, order, actorId) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query("SELECT set_config('role', format('app_%s', $1::text), true)", [tenant]);   // per-tenant role (section 8.1)
    await client.query("SELECT set_config('search_path', format('%I, ledger_shared, pg_temp', $1::text), true)", [tenant]);
    const { rows } = await client.query(
      'SELECT post_entry($1, $2, $3, $4, $5, $6::jsonb) AS seq',
      ['purchase', `ORDER-${order.id}`, `Order ${order.id}`, order.placedAt, actorId,
       JSON.stringify([
         { account_id: order.walletAccountId,   amount_cents: -order.totalCents },
         { account_id: order.merchantAccountId, amount_cents:  order.totalCents },
       ])],
    );
    await client.query('UPDATE orders SET status = $1, ledger_seq = $2 WHERE order_id = $3',
                       ['paid', rows[0].seq, order.id]);
    await client.query('COMMIT');
    return rows[0].seq;
  } catch (err) {
    await client.query('ROLLBACK');
    if (err.code === 'LD004') throw new InsufficientFundsError();   // see the error table below
    throw err;
  } finally {
    client.release();
  }
}
```

`bigint` columns arrive as strings in `pg` by default; parse them (they fit in a JavaScript number up to 2^53) or use `BigInt`.

### 9.3 Read balances and statements

```sql
SELECT balance_cents FROM account_balances WHERE account_id = $1;

-- A statement with a running balance
SELECT e.sequence_no, e.effective_at, e.entry_type, e.description, p.amount_cents,
       sum(p.amount_cents) OVER (ORDER BY e.sequence_no, p.line_no) AS running_balance_cents
FROM postings p JOIN journal_entries e USING (sequence_no)
WHERE p.account_id = $1
ORDER BY e.sequence_no, p.line_no;
```

Balances are always calculated from postings; there is no stored balance to drift.

### 9.4 Reverse an entry

```sql
SELECT post_entry('reversal', 'REFUND-ORDER-8812', 'Refund order 8812', now(), $actor,
  '[{"account_id": 31, "amount_cents": -2500},
    {"account_id": 12, "amount_cents":  2500}]'::jsonb,
  4711);                            -- the sequence number being reversed
```

A reversal must have exactly the original's lines with the amounts negated, and each entry can be reversed once. For a partial refund, post a new entry of your own type (for example `refund`) instead.

### 9.5 Error codes

Every rejection has its own SQLSTATE, so your code can branch on `err.code` instead of message text.

| Code | Meaning | Typical handling |
|---|---|---|
| `LD001` | Unknown entry type | Register it in a shared migration |
| `LD002` | Invalid lines: not an array, fewer than two or more than 32767, not an object, unknown account, missing field, or an `account_id` / `amount_cents` that is not a JSON integer in the `bigint` range | A bug in the caller |
| `LD003` | Lines do not sum to zero | A bug in the caller |
| `LD004` | Insufficient funds | Show the user; nothing was written |
| `LD005` | External reference already used for a different entry | A bug, or two records sharing an ID |
| `LD006` | Invalid reversal (missing, already reversed, a reversal itself, lines don't mirror) | Check the original entry |
| `LD007` | Unknown account type, or owner doesn't match the type's rule | A bug in the caller |
| `LD008` | Digest for an entry that doesn't exist | A bug in the digest job |
| `LD009` | Attempt to change an append-only table | Someone tried to edit history |
| `LD010` | Account type already registered with different rules | Register a new type instead |
| `LD011` | A digest for that entry was already recorded with a different anchor | A bug in the digest job; recording the same anchor again is fine |
| `LD012` | Invalid entry field: `external_ref` or `recorded_by` NULL or not 1-200 characters, NULL description, or `effective_at` outside years 1-9999 | A bug in the caller |
| `42501` | Permission denied | The login lacks the role (section 8) |

Any error rolls back the whole transaction; a rejected entry leaves no trace and no gap in entry numbers.

## 10. Anchor the chain and verify it

The hash chain detects edits, but someone with full database access could recompute the whole chain. Copies of the chain head kept in write-once storage close that gap. Run a small scheduled job (hourly, or every N entries) for each tenant:

1. Read the head: `SELECT last_seq, encode(last_hash, 'hex') FROM <tenant>.chain_head;` Skip if it hasn't moved since the latest row in `ledger_digests`.
2. Write a small JSON document (tenant, sequence number, hash, time) to write-once storage, for example `s3://your-anchors/<tenant>/digest-000000123.json` in an S3 bucket with **Object Lock in compliance mode** and a retention period that matches your records rules. Locally, MinIO supports the same API.
3. Record it: `SELECT <tenant>.record_digest(123, 's3://your-anchors/<tenant>/digest-000000123.json', '<version id>');` (role `ledger_digest_writer`). The function takes the hash from the ledger itself. Calling it again with the same anchor is safe and returns the same hash, so the job can retry.

Then verify on a schedule (role `ledger_reader`) against the latest anchor *read back from storage*, and alert on any row:

```sql
SELECT * FROM org_acme.verify_chain(123, decode('<hash from the stored document>', 'hex'));   -- no rows = intact
```

To verify without trusting the database's own functions, for example for an outside auditor:

```
psql -X -q -At -v tenant=org_acme -f vendor/ledger/tools/export_chain.sql > chain.jsonl
python3 vendor/ledger/tools/verify_chain.py chain.jsonl --anchor-seq 123 --anchor-hash <hash>
```

The verifier is an independent implementation of the documented hash format (technical design, "Hash chain"). It exits with status 0 when the chain is intact, 1 when it finds a problem in the chain (printed), and 2 when the export cannot be read or is malformed, so a broken export is never mistaken for tampering.

## 11. Upgrading the ledger

- Read `CHANGELOG.md` for the new tag. Breaking changes are listed with upgrade steps.
- Move the submodule to the new tag, run your tests, then deploy with `upgrade.sh` (with a `--database` option for each database that holds tenants).
- Releases never edit a migration that has shipped; they add new versions. (v0.3.0 was a one-time fresh start before the first public release; see ADR-0002.)
- **Using another migration tool.** The files follow Flyway naming with a `${tenant}` placeholder, so Flyway (one run per tenant schema) or a similar tool can apply them. Apply the ledger's `shared/` then `tenant/` folders before your own, and keep the files byte-for-byte unchanged.

## 12. Tenants in more than one database

A tenant can live in its own database, on its own server if needed: for data-residency rules that forbid sharing a database, or for a tenant large enough to need its own capacity. Each database has its own `ledger_shared` objects and type registry; nothing in the ledger ever crosses tenants, so a tenant works the same wherever it lives.

**Design your application for it from the start**, even while every tenant is in one database:

- **A tenant directory.** Keep a table in your application that maps each tenant to the database it lives in, and look it up for every request. Moving a tenant is then a change to one row.
- **No SQL across tenants.** Anything that spans tenants (a report over all of them, a party that deals with several) queries each tenant and combines the results in your code. A join across tenant schemas stops working the day one tenant moves.
- **The same types everywhere.** Your shared migration (section 5.1) runs in every database, so every tenant sees the same registered types.
- **One deploy step for all databases**, with `upgrade.sh --database ...` (section 7).

### 12.1 Moving a tenant

```
LEDGER_DB=ledger_pooled vendor/ledger/scripts/move_tenant.sh org_acme \
  --to "postgresql://deploy@db-acme.internal/ledger" --layer app=db/app
```

1. Stop your application's writes to the tenant (for example, a maintenance flag in the tenant directory).
2. Run `move_tenant.sh` with the same `--layer` options you use for provisioning. It brings the target's shared objects up to date (including your registered types), creates the tenant's roles there, copies the schema, data, grants and migration history in one transaction, and checks that the copy verifies and ends at the same entry and hash as the source. If entries arrived during the copy, it stops without writing anything.
3. Point the tenant directory at the new database and resume writes.
4. When you are satisfied, drop the old copy yourself: `DROP SCHEMA org_acme CASCADE` on the source. The script never deletes anything.

The tenant keeps its name (it is part of the chain), and digests recorded before the move still verify the moved chain. Data in your own shared tables (outside the tenant schema) is yours to copy. The target server must run the same PostgreSQL major version as the source or a newer one, and `pg_dump` must be at least the source's version and at most the target's (a newer `pg_dump` writes settings that older servers reject); the script checks this before writing anything.

## 13. Rules that keep you out of trouble

- **No personal data in hashed text.** Descriptions, references, owner IDs and `recorded_by` are permanent and covered by the hash, so they can never be erased. Use IDs and generic labels; keep names and contact details in your tables.
- **Amounts are integers** in the smallest currency unit. One currency per tenant.
- **History never changes.** Correct mistakes with a reversal or a new entry. Accounts are permanent too; open a new one if an account was opened by mistake.
- **The tenant comes from authentication**, never from user input. Switch into the tenant's role and set `search_path` (or schema-qualify every call) inside the transaction.
- **Never grant `ledger_owner` to anyone**, and create multi-tenant service logins NOINHERIT.
- **Short transactions around `post_entry()`**, because it holds the tenant's chain lock until commit.
- **Do not grant direct writes** on ledger tables to anyone, and do not add triggers or columns to them.
- **Anchor regularly.** Entries newer than the latest digest are protected only by the chain.

## 14. Checklist

- [ ] Ledger added as a submodule, pinned to a tag
- [ ] Account and entry types registered in a shared migration
- [ ] Owner tables and link tables in a tenant migration
- [ ] Tenant naming decided (`LEDGER_TENANT_PREFIX` if you want one)
- [ ] Provisioning and `upgrade.sh` wired into deploys, run as the database owner
- [ ] One login per service, each with only the ledger roles it needs; NOINHERIT with per-tenant roles if you have several tenants
- [ ] Tenant names of at most 49 characters, unique across all your databases
- [ ] A tenant directory, and no SQL that joins across tenants
- [ ] `upgrade.sh` lists every database that holds tenants
- [ ] Every movement has a unique external reference from your own records
- [ ] Business record and ledger entry committed in the same short transaction
- [ ] Error codes handled
- [ ] Digest job writing to write-once storage, and scheduled verification with alerts
- [ ] No personal data in descriptions, references, owner IDs or `recorded_by`
