# Example application layer

A small, made-up application (members with wallets, paying merchants) that shows how a project builds on the ledger without changing any ledger file. [docs/integration-guide.md](../../docs/integration-guide.md) walks through the same pattern step by step.

- `shared/V1__app_types_and_merchants.sql`: registers the application's account and entry types, and creates its database-wide tables in its own schema (`example_app`).
- `tenant/V1__members.sql`: per-tenant `members`, a `member_accounts` link table with foreign keys to both the member and the ledger account, and `add_member()`, which adds a member and opens their wallet in one transaction.
- `tenant/V2__member_status.sql`: a later change, applied to existing tenants on upgrade.

Apply it when creating a tenant, or to every existing tenant during a deploy:

```
scripts/provision_tenant.sh tenant_alpha --layer example=examples/app-layer
scripts/upgrade.sh --layer example=examples/app-layer
```

`tests/10_migrations.sh` runs exactly this, and `tests/16_multiple_databases.sh` applies it across two databases and moves a tenant with it, so the example is checked on every push.
