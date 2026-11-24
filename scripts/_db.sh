# shellcheck shell=bash
# Database connection for the scripts (sourced, not run).
#
# Connection settings come from the standard PGHOST, PGPORT, PGUSER,
# PGPASSWORD and PGDATABASE variables. To point a script at another database,
# possibly on another server, set LEDGER_DB to a database name or a full
# connection string, for example
#   LEDGER_DB=postgresql://deploy@db-2.internal:5432/ledger
# (PGDATABASE accepts only a plain name). LEDGER_DB wins over PGDATABASE.

ledger_psql() {
  if [[ -n "${LEDGER_DB:-}" ]]; then psql -d "$LEDGER_DB" "$@"; else psql "$@"; fi
}

ledger_pg_dump() {
  if [[ -n "${LEDGER_DB:-}" ]]; then pg_dump -d "$LEDGER_DB" "$@"; else pg_dump "$@"; fi
}
