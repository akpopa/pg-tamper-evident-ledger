#!/usr/bin/env bash
# Copy one tenant to another database, possibly on another server, and prove
# the copy is complete before anything else changes.
#
#   scripts/move_tenant.sh <tenant> --to <database> [--layer NAME=DIR]...
#
# The source is the database from LEDGER_DB or the PG* variables; <database>
# is a database name or a connection string (see scripts/_db.sh). Pass the
# same --layer options you use for provisioning: the target gets the shared
# objects of every layer (including your registered types) before the copy.
#
# Steps:
#   1. Bring the target's shared objects up to date (core, then layers) and
#      create the tenant's roles there.
#   2. Copy the tenant's schema, data, grants and migration history with
#      pg_dump. If the source's chain head moved while the copy was taken,
#      stop: writes were still arriving.
#   3. Restore it on the target in one transaction (all or nothing), then
#      apply any pending tenant migrations.
#   4. Check that the target's chain verifies and ends at the same entry and
#      hash as the source.
#
# Stop the application's writes to this tenant before running it. The source
# is left untouched; after pointing the application at the target, remove it
# yourself (DROP SCHEMA <tenant> CASCADE on the source). The tenant keeps its
# name: the name is part of its chain's genesis hash.
#
# Versions: the target server must run the same PostgreSQL major version as
# the source or a newer one, and pg_dump must be at least the source's
# version and at most the target's (its output can use settings older servers
# reject). Checked before anything is written.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_layers.sh"
source "$(dirname "${BASH_SOURCE[0]}")/_db.sh"
source "$(dirname "${BASH_SOURCE[0]}")/_names.sh"

usage() { echo "usage: $0 <tenant> --to <database> [--layer NAME=DIR]..." >&2; exit 2; }
[[ $# -ge 3 ]] || usage
tenant="$1"; shift
[[ "$1" == --to && -n "$2" ]] || usage
to="$2"; shift 2
parse_layers "$@"
validate_tenant_name "$tenant" || exit 2
source_db="${LEDGER_DB:-}"

on_source() { LEDGER_DB="$source_db" "$@"; }
on_target() { LEDGER_DB="$to" "$@"; }
q() { ledger_psql -X -q -At -v ON_ERROR_STOP=1 "$@"; }
head_of() { q -c "SELECT last_seq || ':' || encode(last_hash, 'hex') FROM \"$tenant\".chain_head"; }

if [[ -z "$(on_source q -c "SELECT 1 FROM pg_namespace WHERE nspname = '$tenant'")" ]]; then
  echo "error: tenant $tenant does not exist in the source database" >&2; exit 1
fi
if [[ "$(on_target q -c "SELECT current_database() || '@' || coalesce(inet_server_addr()::text, 'local') || ':' || current_setting('port')")" \
   == "$(on_source q -c "SELECT current_database() || '@' || coalesce(inet_server_addr()::text, 'local') || ':' || current_setting('port')")" ]]; then
  echo "error: the source and target are the same database" >&2; exit 2
fi
if [[ -n "$(on_target q -c "SELECT 1 FROM pg_namespace WHERE nspname = '$tenant'")" ]]; then
  echo "error: tenant $tenant already exists in the target database" >&2; exit 1
fi

major() { q -c "SELECT current_setting('server_version_num')::int / 10000"; }
src_major="$(on_source major)"; dst_major="$(on_target major)"
dump_major="$(pg_dump --version | sed -E 's/^[^0-9]*([0-9]+).*/\1/')"
if (( dst_major < src_major )); then
  echo "error: the target runs PostgreSQL $dst_major, older than the source ($src_major); move to the same version or newer" >&2; exit 2
fi
if (( dump_major < src_major || dump_major > dst_major )); then
  echo "error: pg_dump is version $dump_major; it must be between the source's version ($src_major) and the target's ($dst_major). Put a matching pg_dump first on PATH." >&2; exit 2
fi

work="$(mktemp -d)"
trap 'rm -r -- "$work"' EXIT

# 1. Target: shared objects (core and layers) and the tenant's roles
on_target migrate_target shared
on_target q -c "SELECT ledger_shared.create_tenant_roles('$tenant')" >/dev/null

# 2. Copy, and make sure nothing was written meanwhile
before="$(on_source head_of)"
on_source ledger_pg_dump --schema="$tenant" --no-comments > "$work/tenant.sql"
{
  echo "COPY ledger_migrations.history (target, layer, version, description, script, checksum, installed_at, installed_by) FROM stdin;"
  on_source q -c "\\copy (SELECT target, layer, version, description, script, checksum, installed_at, installed_by FROM ledger_migrations.history WHERE target = '$tenant' ORDER BY layer, version) TO STDOUT"
  echo '\.'
} >> "$work/tenant.sql"
after="$(on_source head_of)"
if [[ "$before" != "$after" ]]; then
  echo "error: tenant $tenant received entries during the copy (chain head moved from #${before%%:*} to #${after%%:*}); stop writes to it and run again. Nothing was written to the target." >&2
  exit 1
fi

# 3. Restore in one transaction, then any pending tenant migrations
if ! on_target ledger_psql -X -q -v ON_ERROR_STOP=1 --single-transaction -f "$work/tenant.sql" >/dev/null; then
  echo "error: restoring $tenant on the target failed; nothing from it was applied. Check that every layer is passed with --layer, so the target has the same registered types." >&2
  exit 1
fi
on_target migrate_target "$tenant"

# 4. The copy must verify and end where the source ends
problems="$(on_target q -c "SELECT bad_seq || ' ' || problem FROM \"$tenant\".verify_chain()")"
moved="$(on_target head_of)"
if [[ -n "$problems" || "$moved" != "$before" ]]; then
  echo "error: the copy of $tenant does not match the source (${problems:-chain head differs}). Do not use it; drop it on the target and investigate." >&2
  exit 1
fi
echo "moved $tenant: chain verifies on the target through #${before%%:*} with the same head hash as the source"
echo "next: point the application at the target for $tenant, then drop the schema on the source (DROP SCHEMA $tenant CASCADE)"
