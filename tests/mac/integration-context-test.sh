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

# The integration proof platform deploys the same namespaced Compose identities
# as the Mac lane, so its reserved roster is the project-prefixed one and the
# canonical production names must no longer appear.
integration_names=$(PLATFORM_PROOF_PLATFORM=integration mac_target_container_names proof)
mac_names=$(PLATFORM_PROOF_PLATFORM=mac mac_target_container_names proof)
for expected_name in ntfy beszel beszel-agent-intel beszel-agent-portable \
    beszel-socket-proxy dozzle-alert-relay dozzle dozzle-socket-proxy audiobookshelf \
    komga jellyfin immich-server immich-machine-learning immich-redis immich-postgres \
    paperless-redis paperless-postgres paperless-webserver paperless-gotenberg \
    paperless-tika pinchflat kapowarr bindery trailarr; do
  printf '%s\n' "$integration_names" | grep -qx "proof-$expected_name" || {
    printf 'integration-context-error: missing target identity: %s\n' "$expected_name" >&2
    exit 1
  }
done
[ "$(printf '%s\n' "$integration_names" | wc -l | tr -d ' ')" -eq 24 ] || {
  printf '%s\n' 'integration-context-error: integration target identity set differs' >&2
  exit 1
}
[ "$integration_names" = "$mac_names" ] || {
  printf '%s\n' 'integration-context-error: disposable lanes reserve different identities' >&2
  exit 1
}
if printf '%s\n' "$integration_names" | grep -q '_'; then
  printf '%s\n' 'integration-context-error: integration target identity kept a production name' >&2
  exit 1
fi
integration_identity=$(PLATFORM_PROOF_PLATFORM=integration PLATFORM_PROJECT_NAME=proof \
  mac_container_name immich-postgres)
[ "$integration_identity" = proof-immich-postgres ] || {
  printf '%s\n' 'integration-context-error: integration container identity is not namespaced' >&2
  exit 1
}

for hook in "$script_dir"/hooks/drift/*.sh; do
  [ -f "$hook" ] || continue
  if grep -n 'ansible-playbook' "$hook" | grep -v 'mac_ansible_playbook' >/dev/null; then
    printf 'integration-context-error: direct Ansible invocation remains: %s\n' "$hook" >&2
    exit 1
  fi
done

jellyfin_fixture=$fixture/jellyfin-hook
jellyfin_repo=$jellyfin_fixture/repo
jellyfin_hook=$jellyfin_repo/tests/mac/hooks/drift/60-jellyfin.sh
jellyfin_bin=$jellyfin_fixture/bin
mkdir -p "$jellyfin_repo/tests/mac/hooks/drift" "$jellyfin_repo/tests/mac" \
  "$jellyfin_repo/tests" "$jellyfin_repo/inventory" "$jellyfin_bin"
cp "$script_dir/hooks/drift/60-jellyfin.sh" "$jellyfin_hook"
cp "$script_dir/lib.sh" "$jellyfin_repo/tests/mac/lib.sh"
chmod 0755 "$jellyfin_hook"
: > "$jellyfin_repo/verify.yml"
: > "$jellyfin_repo/inventory/mac.yml"

cat > "$jellyfin_repo/tests/mac/run-jellyfin-contract.sh" <<'STUB'
#!/bin/sh
case ${1-} in
  drift|drift-verify) exit 0 ;;
  *) exit 4 ;;
esac
STUB
chmod 0755 "$jellyfin_repo/tests/mac/run-jellyfin-contract.sh"

cat > "$jellyfin_repo/tests/assert-no-vault-secrets.rb" <<'STUB'
#!/bin/sh
# Let the synthetic sentinel reach the hook fallback so this fixture can prove
# that the fallback never replays its private verification transcript.
exit 0
STUB
chmod 0755 "$jellyfin_repo/tests/assert-no-vault-secrets.rb"

cat > "$jellyfin_bin/ansible-playbook" <<'STUB'
#!/bin/sh
case " $* " in
  *"/verify.yml "*" --tags platform_verify_jellyfin "*) ;;
  *) exit 4 ;;
esac
printf '%s\n' "${JELLYFIN_HOOK_TRANSCRIPT:?}" >&2
exit 2
STUB
chmod 0755 "$jellyfin_bin/ansible-playbook"

verify_jellyfin_hook_contract() {
  hook_under_test=$1
  case_root=$jellyfin_fixture/case
  find "$case_root" -depth -mindepth 1 -delete 2>/dev/null || true
  rmdir "$case_root" 2>/dev/null || true
  mkdir -p "$case_root/reports"
  : > "$case_root/vault.yml"
  : > "$case_root/password"

  for accepted_diagnostic in \
      'The Jellyfin platform encoding policy is drifted.' \
      'The Jellyfin plugin or Open Subtitles state is drifted.' \
      'A managed Jellyfin plugin repository is absent, duplicated, renamed, or disabled.' \
      'The Jellyfin primary administrator is absent, drifted, or has no image.' \
      'The Jellyfin primary identity, branding, image, or managed library is drifted.'; do
    : > "$case_root/stdout"
    : > "$case_root/stderr"
    hook_status=0
    PLATFORM_REPORT_ROOT="$case_root/reports" \
      PLATFORM_MAC_VAULT_FILE="$case_root/vault.yml" \
      PLATFORM_MAC_VAULT_PASSWORD_FILE="$case_root/password" \
      JELLYFIN_HOOK_TRANSCRIPT="$accepted_diagnostic" \
      PATH="$jellyfin_bin:$PATH" \
      "$hook_under_test" >"$case_root/stdout" 2>"$case_root/stderr" || hook_status=$?
    [ "$hook_status" -eq 0 ] && [ ! -s "$case_root/stdout" ] && \
      [ ! -s "$case_root/stderr" ] || return 1
  done

  secret_sentinel='synthetic-secret-must-not-escape'
  : > "$case_root/stdout"
  : > "$case_root/stderr"
  hook_status=0
  PLATFORM_REPORT_ROOT="$case_root/reports" \
    PLATFORM_MAC_VAULT_FILE="$case_root/vault.yml" \
    PLATFORM_MAC_VAULT_PASSWORD_FILE="$case_root/password" \
    JELLYFIN_HOOK_TRANSCRIPT="unrelated failure: $secret_sentinel" \
    PATH="$jellyfin_bin:$PATH" \
    "$hook_under_test" >"$case_root/stdout" 2>"$case_root/stderr" || hook_status=$?
  [ "$hook_status" -eq 1 ] && [ ! -s "$case_root/stdout" ] &&
    [ "$(cat "$case_root/stderr")" = \
      'Jellyfin verification refused drift without its fixed diagnostic' ] &&
    ! grep -qF "$secret_sentinel" "$case_root/stdout" "$case_root/stderr" &&
    [ -z "$(find "$case_root/reports" -mindepth 1 -maxdepth 1 -print -quit)" ]
}

verify_jellyfin_hook_contract "$jellyfin_hook" || {
  printf '%s\n' 'integration-context-error: Jellyfin drift hook behavior differs' >&2
  exit 1
}

for jellyfin_mutation in comment-guard detach-guard remove-exit remove-admin-diagnostic; do
  cp "$script_dir/hooks/drift/60-jellyfin.sh" "$jellyfin_hook"
  ruby - "$jellyfin_hook" "$jellyfin_mutation" <<'RUBY'
path, mutation = ARGV
source = File.read(path)
changed = case mutation
          when "comment-guard"
            source.sub!('  "$expected_failure" || {', '  "$expected_failure" # || {')
          when "detach-guard"
            source.sub!('  "$expected_failure" || {', "  \"$expected_failure\"\n{")
          when "remove-exit"
            source.sub!("  exit 1\n}", "  true\n}")
          when "remove-admin-diagnostic"
            source.sub!("The Jellyfin primary administrator is absent, drifted, or has no image\\.|", "")
          end
abort "fixture mutation did not apply: #{mutation}" unless changed
File.write(path, source)
RUBY
  if verify_jellyfin_hook_contract "$jellyfin_hook" >/dev/null 2>&1; then
    printf 'integration-context-error: Jellyfin drift hook survived mutation: %s\n' \
      "$jellyfin_mutation" >&2
    exit 1
  fi
done
cp "$script_dir/hooks/drift/60-jellyfin.sh" "$jellyfin_hook"

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
