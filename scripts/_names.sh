# shellcheck shell=bash
# Tenant name rules, shared by the scripts (sourced, not run).
#
# A tenant is a PostgreSQL schema. Its name must be a lowercase identifier:
# a letter, then letters, digits or underscores, 49 characters at most. The
# limit comes from the tenant's own roles: PostgreSQL role names are at most
# 63 characters, and the longest is ledger_<tenant>_reader (7 + 49 + 7).
# The ledger's own schemas and PostgreSQL's are reserved.
#
# Roles belong to the server, not the database, so a tenant name must be
# unique on its server, and should be unique across every database the
# application uses: the name identifies the tenant's chain and its roles.
#
# The application decides its naming convention. To require a prefix, set
#   LEDGER_TENANT_PREFIX=tenant_
# and every tenant name must start with it (and have something after it).

LEDGER_RESERVED_SCHEMAS=(ledger_shared ledger_migrations shared migrations public information_schema)

# validate_tenant_name <name>: prints the reason and returns 1 if invalid.
validate_tenant_name() {
  local name="$1" prefix="${LEDGER_TENANT_PREFIX:-}" r
  if [[ -n "$prefix" && ! "$prefix" =~ ^[a-z][a-z0-9_]{0,40}$ ]]; then
    echo "error: LEDGER_TENANT_PREFIX must be lowercase letters, digits or underscores, starting with a letter" >&2
    return 1
  fi
  if [[ ! "$name" =~ ^[a-z][a-z0-9_]*$ ]]; then
    echo "error: tenant name '$name' must be a lowercase letter, then lowercase letters, digits or underscores" >&2
    return 1
  fi
  if (( ${#name} > 49 )); then
    echo "error: tenant name '$name' is ${#name} characters; the limit is 49, so its role names (ledger_<tenant>_reader and so on) fit PostgreSQL's 63-character limit" >&2
    return 1
  fi
  for r in "${LEDGER_RESERVED_SCHEMAS[@]}"; do
    if [[ "$name" == "$r" ]]; then echo "error: '$name' is reserved and cannot be a tenant name" >&2; return 1; fi
  done
  if [[ "$name" == pg_* ]]; then
    echo "error: names starting with pg_ are reserved by PostgreSQL" >&2; return 1
  fi
  if [[ -n "$prefix" && ( "$name" != "$prefix"* || "$name" == "$prefix" ) ]]; then
    echo "error: tenant name '$name' must start with '$prefix' (LEDGER_TENANT_PREFIX) and have more after it" >&2
    return 1
  fi
  return 0
}

# validate_tenant_identifier <name>: the name must be usable unquoted in SQL,
# because migrations write ${tenant} without quotes. PostgreSQL decides: a
# name that quote_ident() would quote (a keyword such as "user" or "select")
# is refused. Needs a database connection.
validate_tenant_identifier() {
  local name="$1" plain
  plain="$(ledger_psql -X -q -At -v ON_ERROR_STOP=1 -v name="$name" <<<"SELECT quote_ident(:'name') = :'name'")" || return 1
  if [[ "$plain" != t ]]; then
    echo "error: '$name' is an SQL keyword and cannot be a tenant name" >&2
    return 1
  fi
}
