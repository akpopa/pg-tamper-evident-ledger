#!/usr/bin/env bash
# Apply pending versioned migrations from one directory to one target.
#
#   scripts/migrate.sh <target> <layer> <dir>
#
#   target  "shared" for database-wide objects, or a tenant name (see
#           scripts/_names.sh; LEDGER_TENANT_PREFIX can require a prefix)
#   layer   name of the migration layer: "core" for this repository, or the
#           name of an extension layer (for example "product")
#   dir     directory of files named V<version>__<description>.sql
#
# Files run in numeric version order. Each file runs in its own transaction
# together with its history record, so a file that fails leaves nothing behind.
# Applied files are recorded in ledger_migrations.history with a SHA-256 checksum of
# the file. Editing a file after it was applied is an error: add a new version.
# In tenant migrations, every ${tenant} is replaced with the tenant name.
# The file naming and ${tenant} placeholder follow Flyway's conventions.
#
# Connection settings come from PGHOST, PGPORT, PGUSER, PGDATABASE, PGPASSWORD.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_db.sh"
source "$(dirname "${BASH_SOURCE[0]}")/_names.sh"

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <shared|tenant_name> <layer> <dir>" >&2
  exit 2
fi
target="$1"; layer="$2"; dir="$3"
if [[ "$target" != shared ]]; then
  validate_tenant_name "$target" || exit 2
  validate_tenant_identifier "$target" || exit 2
fi
if [[ ! "$layer" =~ ^[a-z][a-z0-9_]{0,30}$ ]]; then
  echo "error: invalid layer name '$layer'" >&2
  exit 2
fi
if [[ ! -d "$dir" ]]; then
  echo "error: no such directory: $dir" >&2
  exit 2
fi

q() { ledger_psql -X -q -At -v ON_ERROR_STOP=1 "$@"; }

q >/dev/null <<'SQL'
SET client_min_messages = warning;
CREATE SCHEMA IF NOT EXISTS ledger_migrations;
CREATE TABLE IF NOT EXISTS ledger_migrations.history (
  target        text        NOT NULL,   -- 'shared' or a tenant schema
  layer         text        NOT NULL,   -- 'core' or an extension layer
  version       integer     NOT NULL,
  description   text        NOT NULL,
  script        text        NOT NULL,
  checksum      text        NOT NULL,   -- SHA-256 of the file as written
  installed_at  timestamptz NOT NULL DEFAULT now(),
  installed_by  text        NOT NULL DEFAULT current_user,
  PRIMARY KEY (target, layer, version)
);
REVOKE ALL ON SCHEMA ledger_migrations FROM PUBLIC;
SQL

# Collect migration files as "version<TAB>path", sorted by version.
files=()
while IFS= read -r -d '' f; do files+=("$f"); done < <(find "$dir" -maxdepth 1 -type f -name 'V*__*.sql' -print0)
list=""
for f in "${files[@]+"${files[@]}"}"; do
  base="${f##*/}"; v="${base#V}"; v="${v%%__*}"
  if [[ ! "$v" =~ ^[0-9]+$ ]]; then echo "error: bad version in file name: $base" >&2; exit 2; fi
  list+="$((10#$v))"$'\t'"$f"$'\n'
done
dups="$(printf '%s' "$list" | cut -f1 | sort -n | uniq -d)"
if [[ -n "$dups" ]]; then echo "error: duplicate migration version(s) in $dir: $dups" >&2; exit 2; fi

declare -A applied=()
while IFS=' ' read -r v sum; do
  [[ -n "$v" ]] && applied[$v]="$sum"
done < <(q -c "SELECT version || ' ' || checksum FROM ledger_migrations.history WHERE target = '$target' AND layer = '$layer'")

count=0
while IFS=$'\t' read -r v f; do
  [[ -z "$v" ]] && continue
  base="${f##*/}"
  sum="$(sha256sum "$f" | cut -d' ' -f1)"
  if [[ -n "${applied[$v]:-}" ]]; then
    if [[ "${applied[$v]}" != "$sum" ]]; then
      echo "error: $target/$layer $base was changed after it was applied; add a new version instead" >&2
      exit 1
    fi
    continue
  fi

  body="$(<"$f")"
  if [[ "$target" == shared ]]; then
    if [[ "$body" == *'${tenant}'* ]]; then echo "error: $base uses \${tenant} but is a shared migration" >&2; exit 2; fi
  else
    body="${body//\$\{tenant\}/$target}"
  fi
  desc="${base#*__}"; desc="${desc%.sql}"; desc="${desc//_/ }"; desc="${desc//\'/\'\'}"

  tmp="$(mktemp)"
  {
    echo "SELECT pg_advisory_xact_lock(hashtext('migrations'), hashtext('$target/$layer'));"
    echo "DO \$m\$ BEGIN IF EXISTS (SELECT 1 FROM ledger_migrations.history WHERE target = '$target' AND layer = '$layer' AND version = $v)"
    echo "  THEN RAISE EXCEPTION 'version $v was applied by another session'; END IF; END \$m\$;"
    printf '%s\n' "$body"
    echo ";"
    echo "INSERT INTO ledger_migrations.history (target, layer, version, description, script, checksum)"
    echo "VALUES ('$target', '$layer', $v, '$desc', '${base//\'/\'\'}', '$sum');"
  } >"$tmp"
  if ! ledger_psql -X -q -v ON_ERROR_STOP=1 --single-transaction -f "$tmp" >/dev/null; then
    rm -f -- "$tmp"
    echo "error: $target/$layer $base failed; nothing from it was applied" >&2
    exit 1
  fi
  rm -f -- "$tmp"
  echo "applied $target/$layer V$v ($desc)"
  count=$((count + 1))
done < <(printf '%s' "$list" | sort -n -k1,1)

[[ $count -eq 0 ]] && echo "$target/$layer: up to date"
exit 0
