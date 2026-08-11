#!/bin/sh
set -eu
set +x
umask 077

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$script_dir/lib.sh"

fixture=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-integration-context.XXXXXX")
cleanup() {
  find "$fixture" -type f -exec unlink {} \; 2>/dev/null || true
  find "$fixture" -depth -type d -exec rmdir {} \; 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
mkdir -m 0700 "$fixture/bin"
log=$fixture/ansible.log
cat > "$fixture/bin/ansible-playbook" <<'SH'
#!/bin/sh
printf '%s\n' "$@" > "${CONTEXT_LOG:?}"
SH
chmod 0700 "$fixture/bin/ansible-playbook"

(
  export PATH="$fixture/bin:$PATH" CONTEXT_LOG="$log"
  export PLATFORM_PROOF_PLATFORM=integration PLATFORM_PROOF_LANE=adoption
  export PLATFORM_PROOF_CALLBACK_HOST=172.17.0.1
  mac_ansible_playbook -i inventory/mac.yml site.yml --tags dozzle
)
for expected in platform_kind=mac platform_compose_kind=integration \
    deployment_bundle_test_mode=true platform_manage_linux_ownership=true \
    platform_callback_host=172.17.0.1; do
  grep -qx "$expected" "$log" || {
    printf 'integration-context-error: missing Ansible context: %s\n' "$expected" >&2
    exit 1
  }
done

if (
  export PATH="$fixture/bin:$PATH" CONTEXT_LOG="$log"
  export PLATFORM_PROOF_PLATFORM=integration PLATFORM_PROOF_LANE=fresh
  export PLATFORM_PROOF_CALLBACK_HOST=172.17.0.1
  mac_ansible_playbook site.yml
) >/dev/null 2>&1; then
  printf '%s\n' 'integration-context-error: fresh lane accepted integration context' >&2
  exit 1
fi

integration_names=$(PLATFORM_PROOF_PLATFORM=integration mac_target_container_names proof)
for expected_name in ntfy beszel beszel_agent beszel_agent_portable beszel_socket_proxy \
    dozzle dozzle_socket_proxy audiobookshelf komga tinymediamanager jellyfin \
    immich_server immich_machine_learning immich_redis immich_postgres \
    paperless_redis paperless_postgres paperless_webserver paperless_gotenberg paperless_tika; do
  printf '%s\n' "$integration_names" | grep -qx "$expected_name" || {
    printf 'integration-context-error: missing target identity: %s\n' "$expected_name" >&2
    exit 1
  }
done
[ "$(printf '%s\n' "$integration_names" | wc -l | tr -d ' ')" -eq 20 ] || {
  printf '%s\n' 'integration-context-error: integration target identity set differs' >&2
  exit 1
}
printf '%s\n' "$integration_names" | grep '^proof-' >/dev/null && {
  printf '%s\n' 'integration-context-error: integration target identity retained Mac prefix' >&2
  exit 1
}

for hook in "$script_dir"/hooks/drift/*.sh; do
  [ -f "$hook" ] || continue
  if grep -n 'ansible-playbook' "$hook" | grep -v 'mac_ansible_playbook' >/dev/null; then
    printf 'integration-context-error: direct Ansible invocation remains: %s\n' "$hook" >&2
    exit 1
  fi
done

printf '%s\n' 'integration context: centralized Ansible capability holds'
