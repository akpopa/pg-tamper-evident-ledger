#!/usr/bin/env bash
# Create a new tenant.
#
#   scripts/provision_tenant.sh <tenant_name> [--layer NAME=DIR]...
#
# Brings the database-wide (shared) objects up to date, then creates the
# tenant by applying the core tenant migrations followed by any extension
# layers, in the order given. Fails if the tenant already exists.
#
#   scripts/provision_tenant.sh tenant_alpha
#   scripts/provision_tenant.sh tenant_beta --layer product=../product/db
#
# Tenant names: see scripts/_names.sh (LEDGER_TENANT_PREFIX can require a
# prefix). Connection settings come from PGHOST, PGPORT, PGUSER, PGDATABASE,
# PGPASSWORD.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_layers.sh"
source "$(dirname "${BASH_SOURCE[0]}")/_db.sh"
source "$(dirname "${BASH_SOURCE[0]}")/_names.sh"

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <tenant_name> [--layer NAME=DIR]...   (e.g. $0 tenant_alpha)" >&2
  exit 2
fi
tenant="$1"; shift
validate_tenant_name "$tenant" || exit 2
validate_tenant_identifier "$tenant" || exit 2
parse_layers "$@"

exists="$(ledger_psql -X -q -At -v ON_ERROR_STOP=1 -c "SELECT 1 FROM pg_namespace WHERE nspname = '$tenant'")"
if [[ -n "$exists" ]]; then
  echo "error: tenant $tenant already exists" >&2
  exit 1
fi

migrate_target shared
migrate_target "$tenant"
echo "provisioned $tenant"
