# Security policy

This ledger is meant to make tampering detectable, so reports of ways around that are especially welcome: an edit that `verify_chain()` or `tools/verify_chain.py` does not catch, a write path that bypasses `post_entry()`, `open_account()` or `record_digest()`, a role that can do more than documented, or a way for one tenant's role to reach another tenant.

## Security model in brief

- **Writes** go only through `open_account()`, `post_entry()` and `record_digest()`. No role has INSERT, UPDATE or DELETE on ledger tables, and triggers block edits.
- **The write functions** are SECURITY DEFINER and owned by `ledger_owner`, which cannot log in and has no administrator powers, so they never run with administrator rights.
- **Tenants** each have their own roles (`ledger_<tenant>_reader`, `_poster`, `_opener`, `_digest`); a NOINHERIT service login reaches a tenant only after switching into its role. Tenants may also live in separate databases or servers (ADR-0003).
- **Tampering** by anyone with full database access is detected, not prevented: every entry is in a SHA-256 hash chain, and digests anchored in write-once storage catch a chain rewritten end to end. `tools/verify_chain.py` checks a chain without trusting the database.

The full description is in [docs/technical-design.md](docs/technical-design.md) (Access control, Hash chain, Verification).

## Reporting a vulnerability

Please report privately through GitHub: on this repository's **Security** tab, choose **Report a vulnerability**. Do not open a public issue for a security problem.

Include the PostgreSQL version, the ledger version or commit, and the smallest set of SQL statements that shows the problem. You should get an acknowledgement within a week.

## Supported versions

Only the latest tagged release receives fixes. Before 1.0, a fix may require moving your pin to a new release.

## Scope

Known limitations are listed in [docs/technical-design.md](docs/technical-design.md#known-limitations) and are not vulnerabilities in themselves. For example:

- A superuser can change data; the design detects it, it does not prevent it.
- Entries newer than the latest outside digest are protected only by the chain.
- A service login that may switch into every tenant's role can reach every tenant; per-tenant roles guard against routing bugs, not a stolen login.
- The group roles (`ledger_reader` and the others) reach every tenant on the server by design.
- Anyone granted `ledger_owner` can disable the ledger's triggers; it must never be granted to an application login.
