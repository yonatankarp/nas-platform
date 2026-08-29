#!/bin/sh
# Pinchflat's drift is its identity, because its identity is its whole owned
# configuration: one basic-authentication pair rendered into the deployed
# environment file. Rewriting the password there and recreating the container
# from the deployed bundle is exactly what a hand edit on the NAS would do.
#
# The lane then requires that verification alone refuses the drifted deployment,
# and leaves it drifted for the reconcile phase to repair by converging.
set -eu
set +x
umask 077

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_script_dir=$(CDPATH= cd -- "$mac_hook_dir/../.." && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_script_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"

: "${PLATFORM_PROJECT_NAME:?PLATFORM_PROJECT_NAME is required}"
: "${PLATFORM_DOCKER_ROOT:?PLATFORM_DOCKER_ROOT is required}"
: "${PLATFORM_REPORT_ROOT:?PLATFORM_REPORT_ROOT is required}"
: "${PLATFORM_MAC_VAULT_FILE:?PLATFORM_MAC_VAULT_FILE is required}"
: "${PLATFORM_MAC_VAULT_PASSWORD_FILE:?PLATFORM_MAC_VAULT_PASSWORD_FILE is required}"

expected_failure=$(mktemp "$PLATFORM_REPORT_ROOT/pinchflat-verify-drift.XXXXXX")
trap 'unlink "$expected_failure" >/dev/null 2>&1 || true' EXIT HUP INT TERM

current=$PLATFORM_DOCKER_ROOT/nas-platform/current/services/pinchflat
runtime=$PLATFORM_DOCKER_ROOT/nas-platform/runtime/services/pinchflat/.env
[ -f "$runtime" ] && [ ! -L "$runtime" ] ||
  mac_die 'the deployed Pinchflat environment is absent or unsafe'

# A value the vault cannot hold, so the drifted state can never coincide with
# the authored one however the vault was generated.
drifted_password='drifted-not-the-vault-password'
grep -q '^PINCHFLAT_BASIC_AUTH_PASSWORD=' "$runtime" ||
  mac_die 'the deployed Pinchflat environment carries no basic-auth password'
mac_drift_env=$(mktemp "$PLATFORM_REPORT_ROOT/pinchflat-env-drift.XXXXXX")
sed "s|^PINCHFLAT_BASIC_AUTH_PASSWORD=.*|PINCHFLAT_BASIC_AUTH_PASSWORD=$drifted_password|" \
  "$runtime" > "$mac_drift_env"
cat "$mac_drift_env" > "$runtime"
unlink "$mac_drift_env"

set -- docker compose --project-name "$PLATFORM_PROJECT_NAME-pinchflat" --env-file "$runtime"
mac_drift_compose_arguments=$(mac_compose_files "$current")
while IFS= read -r mac_drift_compose_argument; do
  set -- "$@" "$mac_drift_compose_argument"
done <<EOF
$mac_drift_compose_arguments
EOF
set -- "$@" up -d --force-recreate --wait pinchflat
"$@"

if mac_ansible_playbook -i "$mac_repo_dir/inventory/mac.yml" "$mac_repo_dir/verify.yml" \
    --vault-password-file "$PLATFORM_MAC_VAULT_PASSWORD_FILE" \
    -e @"$PLATFORM_MAC_VAULT_FILE" \
    -e "platform_vault_file=$PLATFORM_MAC_VAULT_FILE" \
    --tags platform_verify_pinchflat >"$expected_failure" 2>&1; then
  printf '%s\n' 'verification-only run accepted Pinchflat identity drift' >&2
  exit 1
fi
"$mac_repo_dir/tests/assert-no-vault-secrets.rb" \
  "$PLATFORM_MAC_VAULT_FILE" "$PLATFORM_MAC_VAULT_PASSWORD_FILE" "$expected_failure"
grep -qF 'no longer accepts exactly the vault-authored administrator' "$expected_failure" || {
  printf '%s\n' 'Pinchflat verification refused drift without its fixed diagnostic' >&2
  exit 1
}

printf '%s\n' 'Pinchflat drift: the deployed identity is rejected until the platform reconverges'
