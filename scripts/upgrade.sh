#!/usr/bin/env bash
# Bring existing databases up to date: apply pending migrations to the shared
# objects and then to every tenant, core layer first and then any extension
# layers, in the order given. Safe to run repeatedly; this is the deploy step.
#
#   scripts/upgrade.sh [--database DB]... [--layer NAME=DIR]...
#
# DB is a database name or a connection string (see scripts/_db.sh), so one
# deploy can cover tenants spread over several databases and servers. The
# databases are upgraded one after another; the first failure stops the run
# and names the database. With no --database, the database comes from
# LEDGER_DB or the PG* variables.
#
# A tenant created before an extension layer existed receives that layer's
# migrations here. Connection settings come from PGHOST, PGPORT, PGUSER,
# PGDATABASE, PGPASSWORD.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_layers.sh"
source "$(dirname "${BASH_SOURCE[0]}")/_db.sh"

databases=(); rest=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --database)
      [[ $# -ge 2 && -n "$2" ]] || { echo "error: --database needs a name or connection string" >&2; exit 2; }
      databases+=("$2"); shift 2 ;;
    *) rest+=("$1"); shift ;;
  esac
done
parse_layers "${rest[@]+"${rest[@]}"}"

upgrade_one() {
  local tenants t
  tenants="$(ledger_psql -X -q -At -v ON_ERROR_STOP=1 -c "
    SELECT DISTINCT target FROM ledger_migrations.history
    WHERE layer = 'core' AND target <> 'shared' ORDER BY 1" 2>/dev/null)" \
    || { echo "error: no migration history found; provision a tenant first" >&2; return 1; }
  migrate_target shared
  for t in $tenants; do
    migrate_target "$t"
  done
}

if [[ ${#databases[@]} -eq 0 ]]; then
  upgrade_one
else
  for db in "${databases[@]}"; do
    export LEDGER_DB="$db"
    # Print the database without any password in a connection string
    label="$(sed -E 's#(://[^:/@]+):[^@]*@#\1:***@#; s#password=[^ ]*#password=***#' <<<"$db")"
    echo "== $label"
    upgrade_one || { echo "error: upgrade stopped at $label; databases listed after it were not upgraded" >&2; exit 1; }
  done
fi
