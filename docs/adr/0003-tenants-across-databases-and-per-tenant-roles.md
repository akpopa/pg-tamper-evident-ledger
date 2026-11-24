# ADR-0003: Tenants in more than one database, and per-tenant roles

## Status

Accepted (2026-11-23). Extends ADR-0001 (one schema per tenant) and ADR-0002.

## Context

Each tenant is a schema with its own chain, and until now every tenant of an application was assumed to share one database. Two needs break that assumption:

- **Isolation required by a tenant.** Some tenants (for example public bodies with data-residency or procurement rules) may refuse to share a database, or a server, with other tenants.
- **Size.** One tenant may be large enough to need its own capacity.

Moving a tenant later is far cheaper if the ledger and the applications built on it assume from the start that tenants can live anywhere.

A related gap: the group roles (`ledger_poster` and the others) are server-wide, so a login granted `ledger_poster` can post to every tenant in every database on the server. The only thing keeping one tenant's entries out of another's ledger was the application choosing the right schema. The hash chain records whatever is posted, so a request routed to the wrong tenant would be a permanent, valid-looking entry in the wrong ledger.

## Decision drivers

- A tenant must work the same in a shared database, its own database, or its own server.
- Moving a tenant must preserve its chain exactly, and prove it at the destination.
- Wrong-tenant writes caused by application bugs should fail in the database.
- No extra infrastructure cost; work with connection pools.
- Stay general-purpose: no assumptions about what tenants are.

## Options considered

### Isolation between tenants

| Option | Notes | Verdict |
|---|---|---|
| Group roles only; the application picks the tenant | Nothing to build; a routing bug writes to another tenant's ledger | Rejected as the only option; kept for single-tenant use |
| **Per-tenant roles; the service login is NOINHERIT and switches role per transaction** | A wrong-tenant call fails with "permission denied". One pool per service. No cost. Does not stop a stolen login that may switch into every tenant's role | **Chosen** |
| A separate login per tenant | Also limits a stolen login, but needs a connection pool per tenant, which grows with the number of tenants and can force larger database instances | Not built into the ledger; the natural choice for a tenant in its own database, and possible with per-tenant roles |

### Where tenants live

| Option | Notes | Verdict |
|---|---|---|
| All tenants in one database | Simplest; cannot meet a tenant's isolation or capacity needs | Rejected as a permanent assumption |
| A database per tenant for every tenant | Strong isolation; many databases to operate and upgrade from day one | Rejected as the default |
| **Any tenant in any database; pooled by default, moved when needed** | Pay for isolation only where a tenant needs it | **Chosen** |

## Decision

1. **Per-tenant roles.** Each tenant gets `ledger_<tenant>_reader`, `ledger_<tenant>_poster`, `ledger_<tenant>_opener` and `ledger_<tenant>_digest`, created by `ledger_shared.create_tenant_roles()` from the tenant migration, NOLOGIN with no administrator powers, with the group roles' rights on that tenant only. The group roles stay for single-tenant applications and cross-tenant tools.
2. **Tenant names at most 49 characters.** PostgreSQL role names are at most 63 characters; `ledger_<tenant>_reader` needs 14 more than the tenant name. Names must be unique on a server (roles are server-wide) and applications should keep them unique across all their databases, because the name is part of the chain's genesis hash and identifies the tenant wherever it lives.
3. **Any database.** Nothing in the ledger crosses tenants or assumes tenants share a database. Each database has its own `ledger_shared` objects and type registry; applications register the same types in every database through their shared migration.
4. **One deploy for many databases.** `scripts/upgrade.sh --database DB ...` upgrades each listed database (a name or a connection string) in turn and stops at the first failure. All scripts accept `LEDGER_DB` for a connection string, since `PGDATABASE` accepts only a name.
5. **A tested move.** `scripts/move_tenant.sh <tenant> --to <database>` brings the target's shared objects and the application's layers up to date, creates the tenant's roles there, copies the schema, data, grants and migration history with `pg_dump` in one transaction, refuses if the chain head moved during the copy, and checks that the copy verifies and ends at the same entry and hash. It never deletes the source; the operator does that after switching over.
6. **Guidance for applications.** Keep a tenant directory (tenant to database) and look it up per request; never join across tenants in SQL; run anything that spans tenants as one query per tenant, combined in application code.

## Consequences

- A request routed to the wrong tenant fails instead of writing to another ledger, provided the service login is NOINHERIT and switches role per transaction. A login that may switch into every tenant's role is still a single point of compromise; tenants that need more get their own database and login.
- Four roles per tenant. They are server-wide and are not in a `pg_dump` of a database: restoring onto a new server needs `pg_dumpall --roles-only` first, or `move_tenant.sh`, which creates them. Removing a tenant (not designed yet) will need to remove its roles.
- Tenant names longer than 49 characters are refused (was 63).
- Moving a tenant requires stopping its writes for the length of the copy. Online moves (logical replication) are possible later.
- The target must run the same PostgreSQL major version as the source or newer, and `pg_dump` must be between the source's and the target's versions (a newer `pg_dump` writes settings older servers reject). `move_tenant.sh` checks this first.
- Data in an application's own shared tables is the application's to copy when a tenant moves.

## Validation

`tests/15_tenant_roles.sh` (10 checks): per-tenant roles exist and cannot log in; a NOINHERIT login cannot post without switching role, can post in its tenant's role, and is refused on another tenant, for writes and reads; the switch ends with the transaction; an application role combining poster and opener works; the 49-character limit is enforced with its reason.

`tests/16_multiple_databases.sh` (12 checks): one upgrade applies a layer to tenants in two databases, by name and by connection string, without printing passwords, and stops at a database with no ledger; a moved tenant verifies with the source's chain head and balances, an outside anchor recorded before the move still verifies it, its history, owner and grants are intact, posting continues on the target and the source is untouched; moves onto an existing tenant, into a database without the application's types, or onto the source itself are refused, leaving nothing behind.

161 checks pass on PostgreSQL 16 (2026-11-23).
