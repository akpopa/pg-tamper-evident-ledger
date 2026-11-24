# shellcheck shell=bash
# Shared helpers for provision_tenant.sh and upgrade.sh (sourced, not run).
#
# Extension layers are passed as --layer NAME=DIR. DIR may contain a shared/
# folder (database-wide migrations) and a tenant/ folder (per-tenant
# migrations). Layers are applied after the core layer, in the order given.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
migrate="$root/scripts/migrate.sh"
layer_names=(); layer_dirs=()

parse_layers() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --layer)
        [[ $# -ge 2 && "$2" == *=* ]] || { echo "error: --layer needs NAME=DIR" >&2; exit 2; }
        local name="${2%%=*}" dir="${2#*=}"
        [[ "$name" =~ ^[a-z][a-z0-9_]{0,30}$ && "$name" != core ]] \
          || { echo "error: invalid layer name '$name' (lowercase, not 'core')" >&2; exit 2; }
        [[ -d "$dir" ]] || { echo "error: no such directory: $dir" >&2; exit 2; }
        layer_names+=("$name"); layer_dirs+=("$(cd "$dir" && pwd)")
        shift 2 ;;
      *) echo "error: unexpected argument '$1'" >&2; exit 2 ;;
    esac
  done
}

# migrate_target <shared|tenant_name>: core first, then each extension layer
migrate_target() {
  local target="$1" sub i
  [[ "$target" == shared ]] && sub=shared || sub=tenant
  "$migrate" "$target" core "$root/db/core/$sub"
  for i in "${!layer_names[@]}"; do
    if [[ -d "${layer_dirs[$i]}/$sub" ]]; then
      "$migrate" "$target" "${layer_names[$i]}" "${layer_dirs[$i]}/$sub"
    fi
  done
}
