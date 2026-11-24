#!/usr/bin/env bash
# M. Migration layers: an application layer applies on top of the core,
# existing tenants pick up new versions on upgrade, applied files cannot be
# edited, and a failed migration leaves nothing behind.
#
# Run by scripts/run_tests.sh against a database where tenant_alpha was
# provisioned with the core layer only and seeded (PGDATABASE set).
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ex="$root/examples/app-layer"
work="$(mktemp -d)"
trap 'rm -r -- "$work"' EXIT
q() { psql -X -q -At -v ON_ERROR_STOP=1 -c "$1"; }
check() { if [[ "$2" == "$3" ]]; then echo "PASS $1"; else echo "FAIL $1 (expected '$3', got '$2')"; fi; }

# M1. A new tenant can be provisioned with the extension layer.
"$root/scripts/provision_tenant.sh" tenant_beta --layer example="$ex" >/dev/null
check "M1 provisioning with an application layer creates its shared and tenant tables" \
  "$(q "SELECT to_regclass('example_app.merchants') IS NOT NULL AND to_regclass('tenant_beta.member_accounts') IS NOT NULL")" t

# M2. An existing tenant created before the layer existed receives it on upgrade.
"$root/scripts/upgrade.sh" --layer example="$ex" >/dev/null
check "M2 upgrade adds the application layer to an existing tenant (both versions)" \
  "$(q "SELECT count(*) FROM ledger_migrations.history WHERE target = 'tenant_alpha' AND layer = 'example'")" 2

# M3. Upgrading again changes nothing.
out="$("$root/scripts/upgrade.sh" --layer example="$ex")"
check "M3 a second upgrade applies nothing" "$(grep -c '^applied' <<<"$out")" 0

# M4. A new version in the layer is applied to every tenant.
cp -r "$ex" "$work/layer"
printf '%s\n' 'ALTER TABLE ${tenant}.members ADD COLUMN notes text;' > "$work/layer/tenant/V3__add_notes.sql"
"$root/scripts/upgrade.sh" --layer example="$work/layer" >/dev/null
check "M4 a new version is applied to every tenant" \
  "$(q "SELECT count(*) FROM information_schema.columns WHERE table_name = 'members' AND column_name = 'notes'")" 2

# M5. Editing an applied file is rejected.
echo "-- edited later" >> "$work/layer/tenant/V1__members.sql"
out="$("$root/scripts/upgrade.sh" --layer example="$work/layer" 2>&1)"; rc=$?
check "M5 editing an already-applied migration is rejected" \
  "$rc:$(grep -c 'was changed after it was applied' <<<"$out")" "1:1"
cp "$ex/tenant/V1__members.sql" "$work/layer/tenant/"

# M6. A failing migration leaves nothing behind.
printf '%s\n' 'CREATE TABLE ${tenant}.half_done (id int);' 'SELECT 1/0;' > "$work/layer/tenant/V4__broken.sql"
"$root/scripts/upgrade.sh" --layer example="$work/layer" >/dev/null 2>&1; rc=$?
check "M6 a failing migration is rolled back: no table, no history row" \
  "$rc:$(q "SELECT to_regclass('tenant_alpha.half_done') IS NULL AND NOT EXISTS (SELECT 1 FROM ledger_migrations.history WHERE version = 4)")" "1:t"
rm "$work/layer/tenant/V4__broken.sql"

# M7. Provisioning an existing tenant is rejected.
"$root/scripts/provision_tenant.sh" tenant_alpha >/dev/null 2>&1; rc=$?
check "M7 provisioning a tenant that already exists is rejected" "$rc" 1

# M8. The core ledger is untouched by the application layer.
check "M8 both tenants' ledgers still verify" \
  "$(q "SET ROLE ledger_test_app; SELECT (SELECT count(*) FROM tenant_alpha.verify_chain()) + (SELECT count(*) FROM tenant_beta.verify_chain())")" 0
check "M9 core history: shared and both tenants at the latest core version (1)" \
  "$(q "SELECT string_agg(target || ':' || v, ',' ORDER BY target) FROM (SELECT target, max(version) AS v FROM ledger_migrations.history WHERE layer = 'core' GROUP BY target) h")" \
  "shared:1,tenant_alpha:1,tenant_beta:1"

# M10. The example's pattern works: a member gets a wallet account owned by
# them, linked with foreign keys on the application side.
member="$(q "SELECT tenant_beta.add_member('Ada')")"
check "M10 add_member() opens a wallet owned by the member and links it" \
  "$(q "SELECT count(*) FROM tenant_beta.member_accounts l
          JOIN tenant_beta.accounts a USING (account_id)
         WHERE l.member_id = '$member' AND a.account_type = 'member_wallet'
           AND a.owner_type = 'member' AND a.owner_id = '$member'")" 1

# M11. Tenant names are the application's choice; a prefix can be required.
"$root/scripts/provision_tenant.sh" main >/dev/null 2>&1; rc=$?
check "M11 any lowercase schema name can be a tenant (here: main)" \
  "$rc:$(q "SELECT (SELECT count(*) FROM main.verify_chain())::text || ':' || (SELECT last_seq FROM main.chain_head)")" "0:0:0"
LEDGER_TENANT_PREFIX=tenant_ "$root/scripts/provision_tenant.sh" other >/dev/null 2>&1; rc=$?
check "M12 LEDGER_TENANT_PREFIX rejects names without the prefix" "$rc:$(q "SELECT to_regnamespace('other') IS NULL")" "2:t"
"$root/scripts/provision_tenant.sh" user >/dev/null 2>&1; rc=$?
check "M13 SQL keywords and reserved schema names are rejected" \
  "$rc:$("$root/scripts/provision_tenant.sh" shared >/dev/null 2>&1; echo $?)" "2:2"
