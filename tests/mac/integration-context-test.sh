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
  export PLATFORM_PROOF_PLATFORM=integration PLATFORM_PROOF_LANE=fresh
  export PLATFORM_CALLBACK_HOST=172.17.0.1
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
  unset PLATFORM_CALLBACK_HOST
  mac_ansible_playbook site.yml
) >/dev/null 2>&1; then
  printf '%s\n' 'integration-context-error: absent callback host accepted' >&2
  exit 1
fi

for hostile_callback in 127.0.0.1 0.0.0.0 224.0.0.1 '172.17.0.1 -e hostile=true'; do
  if mac_validate_integration_callback "$hostile_callback" >/dev/null 2>&1; then
    printf 'integration-context-error: hostile callback accepted: %s\n' "$hostile_callback" >&2
    exit 1
  fi
done
if (
  export PATH="$fixture/bin:$PATH" CONTEXT_LOG="$log"
  export PLATFORM_PROOF_PLATFORM=mac PLATFORM_CALLBACK_HOST=192.0.2.1
  mac_ansible_playbook site.yml
) >/dev/null 2>&1; then
  printf '%s\n' 'integration-context-error: hostile Mac callback was accepted' >&2
  exit 1
fi

integration_names=$(PLATFORM_PROOF_PLATFORM=integration mac_target_container_names proof)
for expected_name in ntfy beszel beszel_agent beszel_agent_portable beszel_socket_proxy \
    dozzle_alert_relay dozzle dozzle_socket_proxy audiobookshelf komga tinymediamanager jellyfin \
    immich_server immich_machine_learning immich_redis immich_postgres \
    paperless_redis paperless_postgres paperless_webserver paperless_gotenberg paperless_tika; do
  printf '%s\n' "$integration_names" | grep -qx "$expected_name" || {
    printf 'integration-context-error: missing target identity: %s\n' "$expected_name" >&2
    exit 1
  }
done
[ "$(printf '%s\n' "$integration_names" | wc -l | tr -d ' ')" -eq 21 ] || {
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

tinymediamanager_runner=$script_dir/run-tinymediamanager-contract.sh
grep -qF 'seed-retirement-fixture|assert-retired)' "$tinymediamanager_runner" || {
  printf '%s\n' 'integration-context-error: retirement runner accepts the wrong modes' >&2
  exit 1
}
if grep -Eq '(^|[[:space:]|])(seed|run|assert-persistence)([[:space:]|)])' \
    "$tinymediamanager_runner"; then
  printf '%s\n' 'integration-context-error: retirement runner retains an active mode' >&2
  exit 1
fi

tinymediamanager_preconverge=$script_dir/hooks/pre-converge/50-tinymediamanager.sh
tinymediamanager_seed=$script_dir/hooks/fixtures-seed/50-tinymediamanager.sh
tinymediamanager_persistence=$script_dir/hooks/fixtures-persistence/50-tinymediamanager.sh
tinymediamanager_recreate=$script_dir/hooks/fixtures-recreate/50-tinymediamanager.sh
tinymediamanager_drift=$script_dir/hooks/drift/50-tinymediamanager.sh
tinymediamanager_verify=$script_dir/hooks/verify/50-tinymediamanager.sh
grep -qF 'seed-retirement-fixture' "$tinymediamanager_preconverge"
grep -qF 'tinymediamanager_retirement_fixture.yml' "$tinymediamanager_preconverge"
if [ -e "$tinymediamanager_seed" ] || [ -L "$tinymediamanager_seed" ]; then
  printf '%s\n' 'integration-context-error: retirement fixture remains in post-deploy seeding' >&2
  exit 1
fi
grep -qF 'assert-retired' "$tinymediamanager_persistence"
grep -qF 'assert-retired' "$tinymediamanager_recreate"
if grep -Eq 'up[[:space:]].*force-recreate|[[:space:]]run([[:space:]]|$)' \
    "$tinymediamanager_recreate"; then
  printf '%s\n' 'integration-context-error: recreate hook restarts tinyMediaManager' >&2
  exit 1
fi
grep -qF 'tinymediamanager_retirement_fixture.yml' "$tinymediamanager_drift"
grep -qF 'TINYMEDIAMANAGER_RETIREMENT_DRIFT_INSTALLED' "$tinymediamanager_drift"
grep -qF 'verify.yml' "$tinymediamanager_verify"
grep -qF 'platform_verify_tinymediamanager' "$tinymediamanager_verify"
grep -qF 'assert-retired' "$tinymediamanager_verify"

ruby - "$script_dir/run.sh" <<'RUBY'
runner = File.read(ARGV.fetch(0))
preconverge = runner.index('mac_run_hooks pre-converge')
converge = runner.index('run_site', preconverge || 0)
ordinary_seed = runner.index('seed) ensure_immich_fixture_vars && "$mac_script_dir/fixtures.sh" seed')
abort "integration-context-error: retirement fixture is not dispatched before convergence" unless
  preconverge && converge && preconverge < converge
abort "integration-context-error: ordinary fixtures no longer seed after deploy" unless
  ordinary_seed && converge < ordinary_seed
RUBY

printf '%s\n' 'integration context: centralized Ansible capability holds'
