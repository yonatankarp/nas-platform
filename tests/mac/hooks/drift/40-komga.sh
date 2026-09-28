#!/bin/sh
# First the library-root migration (refused without its input, completed with it,
# idempotent after), then drift left in place for the reconcile phase.
set -eu
set +x
umask 077

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_script_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"
expected_failure=$(mktemp "$PLATFORM_REPORT_ROOT/komga-verify-drift.XXXXXX")
migration_output=$(mktemp "$PLATFORM_REPORT_ROOT/komga-migration.XXXXXX")
trap 'unlink "$expected_failure" >/dev/null 2>&1 || true
      unlink "$migration_output" >/dev/null 2>&1 || true' EXIT HUP INT TERM

komga_converge() {
  mac_ansible_playbook -i "$mac_repo_dir/inventory/mac.yml" "$mac_repo_dir/site.yml" \
    --vault-password-file "$PLATFORM_MAC_VAULT_PASSWORD_FILE" \
    -e @"$PLATFORM_MAC_VAULT_FILE" \
    -e "platform_vault_file=$PLATFORM_MAC_VAULT_FILE" \
    --tags komga "$@"
}

assert_no_secrets() {
  "$mac_repo_dir/tests/assert-no-vault-secrets.rb" \
    "$PLATFORM_MAC_VAULT_FILE" "$PLATFORM_MAC_VAULT_PASSWORD_FILE" "$1"
}

# The pre-migration state: one Comics library rooted at /data, no Ebooks library.
"$mac_script_dir/run-komga-contract.sh" migration-legacy
"$mac_script_dir/run-komga-contract.sh" migration-legacy-verify

if komga_converge >"$migration_output" 2>&1; then
  assert_no_secrets "$migration_output"
  printf '%s\n' 'converge accepted an unreviewed Komga library root migration' >&2
  exit 1
fi
assert_no_secrets "$migration_output"
grep -qF 'komga_library_root_migration_allowed=true' "$migration_output" || {
  printf '%s\n' 'converge refused the Komga library root migration without naming its input' >&2
  exit 1
}
"$mac_script_dir/run-komga-contract.sh" migration-legacy-verify

if ! komga_converge -e komga_library_root_migration_allowed=true \
    >"$migration_output" 2>&1; then
  assert_no_secrets "$migration_output"
  cat "$migration_output" >&2
  printf '%s\n' 'the reviewed Komga library root migration did not converge' >&2
  exit 1
fi
assert_no_secrets "$migration_output"
grep -qF 'KOMGA_ROOT_MIGRATION_ALLOWED' "$migration_output" || {
  printf '%s\n' 'the migration run did not report its one-convergence input' >&2
  exit 1
}

# The input is for that one convergence: the next run must need nothing.
if ! komga_converge >"$migration_output" 2>&1; then
  assert_no_secrets "$migration_output"
  cat "$migration_output" >&2
  printf '%s\n' 'the migrated Komga platform does not converge without the migration input' >&2
  exit 1
fi
assert_no_secrets "$migration_output"
grep -qE 'changed=0 .*failed=0 ' "$migration_output" || {
  printf '%s\n' 'the migrated Komga platform is not idempotent' >&2
  exit 1
}
"$mac_script_dir/run-komga-contract.sh" migration-verify

"$mac_script_dir/run-komga-contract.sh" drift
"$mac_script_dir/run-komga-contract.sh" drift-verify
if mac_ansible_playbook -i "$mac_repo_dir/inventory/mac.yml" "$mac_repo_dir/verify.yml" \
    --vault-password-file "$PLATFORM_MAC_VAULT_PASSWORD_FILE" \
    -e @"$PLATFORM_MAC_VAULT_FILE" \
    -e "platform_vault_file=$PLATFORM_MAC_VAULT_FILE" \
    --tags platform_verify_komga >"$expected_failure" 2>&1; then
  printf '%s\n' 'verification-only run accepted Komga drift' >&2
  exit 1
fi
assert_no_secrets "$expected_failure"
grep -qF 'The managed Komga library is absent, duplicated at its root, conflicted, or drifted.' \
  "$expected_failure"
