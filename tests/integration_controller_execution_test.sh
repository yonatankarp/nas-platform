#!/bin/sh
# What tests/integration_controller.sh does, proved by running it against stubbed
# ansible-playbook, docker, contracts and helpers and asserting the observed argv.
# Both roots are explicit (CONTROLLER_REPO_DIR, CONTROLLER_SANDBOX); /repo is
# relocated onto a disposable checkout, with the count asserted. Every property is
# paired with a planted defect that must make its case fail.
set -eu

repo_dir=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-controller-exec.XXXXXX")
work=$(CDPATH= cd -P "$work" && pwd -P)
trap 'rm -rf "$work"' EXIT HUP INT TERM

# Not "$work/repo": a residual /repo would be unreadable in a diff.
checkout=$work/checkout
sandbox=$work/sandbox
stub_bin=$work/stub-bin
stub_log=$work/stub.log
run_output=$work/run.output
namespace=nas-platform-integration-a1b2c3
pristine_program=$work/controller.pristine
pristine_library=$work/library.pristine
planted_program=$work/controller.planted
planted_library=$work/library.planted

# Read back from the launcher, which Renovate bumps; the package pins are fixtures.
ansible_core_version=$(sed -n 's/^ansible_core_version=//p' \
  "$repo_dir/tests/integration.sh")
requests_version=$(sed -n 's/^requests_version=//p' "$repo_dir/tests/integration.sh")
[ -n "$ansible_core_version" ] && [ -n "$requests_version" ] || {
  printf '%s\n' 'cannot read the controller toolchain pins from the launcher' >&2
  exit 1
}
ruby_package=ruby=3.2.9-r0
curl_package=curl=8.14.1-r2

failures=0
probe_failures=0
assert_mode=report
current_case=

fail() {
  if [ "$assert_mode" = probe ]; then
    probe_failures=$((probe_failures + 1))
    return 0
  fi
  printf 'FAIL [%s] %s\n' "$current_case" "$1" >&2
  failures=$((failures + 1))
}

# ---------------------------------------------------------------------------
# The disposable checkout: only the files the controller reaches, so a missing
# one fails the test rather than rotting.
# ---------------------------------------------------------------------------

install_stub() {
  stub_path=$1
  mkdir -p "$(dirname "$stub_path")"
  cat > "$stub_path"
  chmod 0755 "$stub_path"
}

# One line per invocation, so argv can be matched word by word.
stub_preamble() {
  cat <<'PREAMBLE'
#!/bin/sh
log_invocation() {
  invocation_name=$1
  shift
  {
    printf '%s argv=' "$invocation_name"
    for logged_argument in "$@"; do
      printf '[%s]' "$logged_argument"
    done
    printf '\n'
  } >> "${CONTROLLER_STUB_LOG:?}"
}
PREAMBLE
}

build_checkout() {
  rm -rf "$checkout"
  mkdir -p "$checkout/tests/ci" "$checkout/tests/contracts" "$checkout/tests/mac" \
    "$checkout/inventory/group_vars/all" "$checkout/services/beszel" \
    "$checkout/services/kapowarr"

  cp "$repo_dir/tests/integration.sh" "$checkout/tests/integration.sh"
  cp "$repo_dir/tests/integration_lifecycle.sh" \
    "$checkout/tests/integration_lifecycle.sh"
  cp "$repo_dir/tests/ci/suites.conf" "$checkout/tests/ci/suites.conf"
  chmod 0755 "$checkout/tests/integration.sh"
  cp "$repo_dir/services/beszel/compose.yml" "$checkout/services/beszel/compose.yml"
  # Read for real: the controller rewrites this exact pin line.
  cp "$repo_dir/services/kapowarr/compose.yml" "$checkout/services/kapowarr/compose.yml"
  # Present but never executed: integration.sh derives upgrade subjects from it.
  cp "$repo_dir/tests/contracts/kapowarr-upgrade.rb" \
    "$checkout/tests/contracts/kapowarr-upgrade.rb"
  cp "$repo_dir/inventory/group_vars/all/main.yml" \
    "$checkout/inventory/group_vars/all/main.yml"
  printf '%s\n' '---' > "$checkout/inventory/local.yml"
  printf '%s\n' '---' > "$checkout/requirements.yml"

  install_stub "$checkout/tests/generate-ephemeral-vault.sh" <<'STUB'
#!/bin/sh
set -eu
if [ "${1:-}" = --cleanup ]; then
  printf 'ephemeral-vault argv=[--cleanup][%s]\n' "$2" >> "${CONTROLLER_STUB_LOG:?}"
  rm -rf "$2"
  exit 0
fi
vault_output=
vault_password_output=
vault_undeclared=
while [ $# -gt 0 ]; do
  case $1 in
    --output) vault_output=$2; shift 2 ;;
    --password-file) vault_password_output=$2; shift 2 ;;
    # Which credential groups the lane asked to leave undeclared. Logged rather
    # than acted on: the stub writes no credentials, so the assertion a lane can
    # make here is that it requested the state it claims to converge.
    --undeclared) vault_undeclared=$2; shift 2 ;;
    *) printf 'unexpected ephemeral vault argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done
printf 'ephemeral-vault argv=[--undeclared][%s][--output][%s][--password-file][%s]\n' \
  "$vault_undeclared" "$vault_output" "$vault_password_output" \
  >> "${CONTROLLER_STUB_LOG:?}"
printf '%s\n' '$ANSIBLE_VAULT;1.1;AES256' > "${vault_output:?}"
printf '%s\n' 'ephemeral-vault-password' > "${vault_password_output:?}"
STUB

  install_stub "$checkout/tests/mac/generate-immich-fixture-vars.rb" <<'STUB'
#!/usr/bin/env ruby
# frozen_string_literal: true
$stdin.read
File.write(ARGV.fetch(0), "immich_fixture: true\n")
File.open(ENV.fetch("CONTROLLER_STUB_LOG"), "a") do |log|
  log.puts("immich-fixture-vars argv=#{ARGV.map { |value| "[#{value}]" }.join}")
end
STUB

  install_stub "$checkout/tests/verify_deployment_manifest.rb" <<'STUB'
#!/usr/bin/env ruby
# frozen_string_literal: true
File.open(ENV.fetch("CONTROLLER_STUB_LOG"), "a") do |log|
  log.puts("verify-manifest argv=#{ARGV.map { |value| "[#{value}]" }.join}")
end
STUB

  {
    stub_preamble
    cat <<'STUB'
log_invocation collision "$@"
STUB
  } > "$checkout/tests/media_control_network_collision_test.sh"
  chmod 0755 "$checkout/tests/media_control_network_collision_test.sh"

  # One stub per contract the lanes below reach.
  for contract_name in arr downloaders bindery trailarr seerr \
      kapowarr pinchflat jellyfin komga; do
    {
      stub_preamble
      cat <<STUB
log_invocation 'contract $contract_name' "\$@"
printf 'contract $contract_name env=[PLATFORM_PROJECT_NAME=%s][PLATFORM_JELLYFIN_CONTAINER=%s][PLATFORM_KIND=%s]\n' \\
  "\${PLATFORM_PROJECT_NAME-<unset>}" \\
  "\${PLATFORM_JELLYFIN_CONTAINER-<unset>}" \\
  "\${PLATFORM_KIND-<unset>}" >> "\${CONTROLLER_STUB_LOG:?}"
STUB
    } > "$checkout/tests/contracts/$contract_name.sh"
    chmod 0755 "$checkout/tests/contracts/$contract_name.sh"
  done

  relocate_program "$pristine_program" "$checkout/tests/integration_controller.sh"
  relocate_program "$pristine_library" "$checkout/tests/integration_controller_lib.sh"
}

# Every /repo becomes the disposable checkout, including the launcher's own guard.
# Counted both ways: no residual /repo, and no fewer replacements than expected.
relocate_program() {
  relocate_source=$1
  relocate_destination=$2
  ruby -e '
    source_path, destination_path, root = ARGV
    body = File.read(source_path)
    expected = body.scan("/repo").length
    abort "relocation found no /repo occurrences in #{source_path}" if expected.zero?
    relocated = body.gsub("/repo", root)
    produced = relocated.scan(root).length
    abort "relocation replaced #{produced} of #{expected} occurrences" unless produced == expected
    residual = relocated.scan("/repo").length
    abort "relocation left #{residual} unrelocated /repo occurrences" unless residual.zero?
    File.write(destination_path, relocated)
  ' "$relocate_source" "$relocate_destination" "$checkout"
}

build_stub_bin() {
  rm -rf "$stub_bin"
  mkdir -p "$stub_bin"

  # Since #638 both parse via enabled_idempotence_recap_is_clean: one recap, one
  # host line, changed/unreachable/failed zero.
  {
    stub_preamble
    cat <<'STUB'
log_invocation ansible-playbook "$@"
printf 'ansible-playbook env=[ANSIBLE_VAULT_PASSWORD_FILE=%s]\n' \
  "${ANSIBLE_VAULT_PASSWORD_FILE-<unset>}" >> "${CONTROLLER_STUB_LOG:?}"
printf 'PLAY RECAP *********************************************************************\n'
printf 'nas : ok=9 changed=0 unreachable=0 failed=0 skipped=0 rescued=0 ignored=0\n'
STUB
  } > "$stub_bin/ansible-playbook"

  {
    stub_preamble
    cat <<'STUB'
log_invocation ansible-vault "$@"
printf '%s\n' 'decrypted_fixture_input: true'
STUB
  } > "$stub_bin/ansible-vault"

  # `docker` answers two reads for the upgrade stop event (#781): running
  # containers and their stopped state, both from the case's environment.
  {
    stub_preamble
    cat <<'STUB'
log_invocation docker "$@"
case ${1-} in
  ps) printf '%s' "${CONTROLLER_STUB_DOCKER_RUNNING-}" ;;
  inspect) printf '%s\n' "${CONTROLLER_STUB_DOCKER_STATE-exited:0}" ;;
esac
STUB
  } > "$stub_bin/docker"

  for stub_name in ansible-galaxy apk pip sha256sum stat; do
    {
      stub_preamble
      cat <<STUB
log_invocation $stub_name "\$@"
STUB
    } > "$stub_bin/$stub_name"
  done

  chmod 0755 "$stub_bin"/*
}

build_sandbox() {
  rm -rf "$sandbox"
  mkdir -p \
    "$sandbox/reports" \
    "$sandbox/fixtures" \
    "$sandbox/volume2" \
    "$sandbox/volume1/Docker/nas-platform/current/services/beszel" \
    "$sandbox/volume1/Docker/nas-platform/runtime/services"
  cp "$checkout/services/beszel/compose.yml" \
    "$sandbox/volume1/Docker/nas-platform/current/services/beszel/compose.yml"
  # Reset per run, so a plant that skips the vault install cannot pass.
  rm -f "$checkout/inventory/group_vars/all/vault.yml"
  case ${CASE_OPERATOR_VAULT-} in
    file)
      printf '%s\n' 'untracked-operator-vault' \
        > "$checkout/inventory/group_vars/all/vault.yml" ;;
    dangling-symlink)
      ln -s "$work/absent-vault-target" \
        "$checkout/inventory/group_vars/all/vault.yml" ;;
  esac
  printf '%s\n' 'committed-operator-vault' \
    > "$checkout/inventory/group_vars/all/vault_beszel.yml"
}

# ---------------------------------------------------------------------------
# Running the program.
# ---------------------------------------------------------------------------

# Every CONTROLLER_* input, spelled once. Missing ones are asserted by status
# only: bash and dash word the `:?` refusal differently.
export_controller_environment() {
  CONTROLLER_REPO_DIR=${CASE_REPO_DIR-$checkout}
  CONTROLLER_SANDBOX=$sandbox
  CONTROLLER_PROJECT_NAMESPACE=$namespace
  CONTROLLER_RUBY_PACKAGE=$ruby_package
  CONTROLLER_CURL_PACKAGE=$curl_package
  CONTROLLER_ANSIBLE_CORE_VERSION=$ansible_core_version
  CONTROLLER_REQUESTS_VERSION=$requests_version
  CONTROLLER_EXPECTED_RELEASE_ID=0000000000000000000000000000000000000abc
  CONTROLLER_ACTIVE_RELEASE_DIR=$sandbox/volume1/Docker/nas-platform/releases/0000000000000000000000000000000000000abc
  CONTROLLER_STALE_DOCKER_ROOT=$sandbox/stale/Docker
  CONTROLLER_STALE_DEPLOY_ROOT=$sandbox/stale/Docker/nas-platform
  CONTROLLER_STALE_RELEASE_DIR=$sandbox/stale/Docker/nas-platform/releases/0000000000000000000000000000000000000abc
  CONTROLLER_MANIFEST_CONTROLLER=$sandbox/controller-manifest
  CONTROLLER_MANIFEST_DOCKER_ROOT=$sandbox/manifest/Docker
  CONTROLLER_MANIFEST_MEDIA_ROOT=$sandbox/manifest/media
  CONTROLLER_MANIFEST_FIXTURE_SHA=0000000000000000000000000000000000000def
  CONTROLLER_TEST_DIR=$sandbox/controller-checkout
  CONTROLLER_TEST_PLAYBOOK=$sandbox/controller-checkout/controller-test.yml
  CONTROLLER_TEST_TARGET=$sandbox/controller-checkout/target
  CONTROLLER_TEST_SENTINEL=$sandbox/controller-checkout/sentinel
  export CONTROLLER_REPO_DIR CONTROLLER_SANDBOX CONTROLLER_PROJECT_NAMESPACE \
    CONTROLLER_RUBY_PACKAGE CONTROLLER_CURL_PACKAGE \
    CONTROLLER_ANSIBLE_CORE_VERSION CONTROLLER_REQUESTS_VERSION \
    CONTROLLER_EXPECTED_RELEASE_ID CONTROLLER_ACTIVE_RELEASE_DIR \
    CONTROLLER_STALE_DOCKER_ROOT CONTROLLER_STALE_DEPLOY_ROOT \
    CONTROLLER_STALE_RELEASE_DIR CONTROLLER_MANIFEST_CONTROLLER \
    CONTROLLER_MANIFEST_DOCKER_ROOT CONTROLLER_MANIFEST_MEDIA_ROOT \
    CONTROLLER_MANIFEST_FIXTURE_SHA CONTROLLER_TEST_DIR \
    CONTROLLER_TEST_PLAYBOOK CONTROLLER_TEST_TARGET CONTROLLER_TEST_SENTINEL
}

run_controller() {
  run_suite=$1
  run_tags=$2
  run_scenarios=$3
  run_toolchain=$4
  shift 4

  build_sandbox
  : > "$stub_log"
  # The controller writes phase 2 to a literal /tmp/second.txt; never trust a leftover.
  rm -f /tmp/second.txt /tmp/media-acquisition-idempotence.txt
  mkdir -p "$work/home"

  run_status=0
  # A subshell so nothing leaks to the next case; HOME redirected because the
  # controller runs `git config --global`.
  (
    export_controller_environment
    if [ -n "${CASE_UNSET_VARIABLE-}" ]; then
      unset "$CASE_UNSET_VARIABLE"
    fi
    PATH=$stub_bin:$PATH
    HOME=$work/home
    CONTROLLER_STUB_LOG=$stub_log
    PLATFORM_INTEGRATION_SANDBOX=$sandbox
    PLATFORM_INTEGRATION_PROJECT_NAMESPACE=$namespace
    INTEGRATION_SUITE=$run_suite
    INTEGRATION_TAGS=$run_tags
    INTEGRATION_RUN_SERVICE_SCENARIOS=$run_scenarios
    INTEGRATION_TOOLCHAIN_PREINSTALLED=$run_toolchain
    MEDIA_CONTROL_COLLISION_IMAGE=collision-fixture:latest
    PLATFORM_PAPERLESS_FIXTURE_PRESEEDED=false
    PLATFORM_KOMGA_FIXTURE_PRESEEDED=false
    PLATFORM_JELLYFIN_FIXTURE_PRESEEDED=false
    INTEGRATION_UPGRADE_SERVICE=${CASE_UPGRADE_SERVICE-}
    INTEGRATION_UPGRADE_BASE_IMAGE=${CASE_UPGRADE_BASE_IMAGE-}
    # Empty everywhere but the upgrade lane.
    CONTROLLER_STUB_DOCKER_RUNNING=${CASE_DOCKER_RUNNING-}
    CONTROLLER_STUB_DOCKER_STATE=${CASE_DOCKER_STATE-exited:0}
    export PATH HOME CONTROLLER_STUB_LOG PLATFORM_INTEGRATION_SANDBOX \
      PLATFORM_INTEGRATION_PROJECT_NAMESPACE INTEGRATION_SUITE INTEGRATION_TAGS \
      INTEGRATION_RUN_SERVICE_SCENARIOS INTEGRATION_TOOLCHAIN_PREINSTALLED \
      MEDIA_CONTROL_COLLISION_IMAGE PLATFORM_PAPERLESS_FIXTURE_PRESEEDED \
      PLATFORM_KOMGA_FIXTURE_PRESEEDED PLATFORM_JELLYFIN_FIXTURE_PRESEEDED \
      INTEGRATION_UPGRADE_SERVICE INTEGRATION_UPGRADE_BASE_IMAGE \
      CONTROLLER_STUB_DOCKER_RUNNING CONTROLLER_STUB_DOCKER_STATE
    cd "$checkout" || exit 1
    exec sh "$checkout/tests/integration_controller.sh" "$@"
  ) > "$run_output" 2>&1 || run_status=$?
}

# ---------------------------------------------------------------------------
# Assertions: the log is normalized to tokens so each expectation is a fixed string.
# ---------------------------------------------------------------------------

normalized_log() {
  sed -e "s|$checkout|{repo}|g" -e "s|$sandbox|{sandbox}|g" \
    -e "s|$namespace|{ns}|g" "$stub_log"
}

normalized_output() {
  sed -e "s|$checkout|{repo}|g" -e "s|$sandbox|{sandbox}|g" \
    -e "s|$namespace|{ns}|g" "$run_output"
}

expect_status() {
  [ "$run_status" -eq "$1" ] ||
    fail "controller exited $run_status, expected $1"
}

expect_nonzero_status() {
  [ "$run_status" -ne 0 ] || fail 'controller accepted an invalid invocation'
}

expect_log() {
  normalized_log | grep -qF -- "$1" || fail "stub log is missing: $1"
}

expect_no_log() {
  if normalized_log | grep -qF -- "$1"; then
    fail "stub log unexpectedly has: $1"
  fi
}

expect_log_count() {
  observed=$(normalized_log | grep -cF -- "$1" || true)
  [ "$observed" -eq "$2" ] ||
    fail "expected $2 occurrence(s) of $1, saw $observed"
}

expect_log_order() {
  first_line=$(normalized_log | grep -nF -- "$1" | head -1 | cut -d: -f1)
  second_line=$(normalized_log | grep -nF -- "$2" | tail -1 | cut -d: -f1)
  if [ -z "$first_line" ] || [ -z "$second_line" ]; then
    fail "cannot order missing entries: $1 before $2"
    return 0
  fi
  [ "$first_line" -lt "$second_line" ] || fail "$1 did not precede $2"
}

expect_output() {
  normalized_output | grep -qF -- "$1" || fail "controller output is missing: $1"
}

expect_no_output() {
  if normalized_output | grep -qF -- "$1"; then
    fail "controller output unexpectedly has: $1"
  fi
}

# Asserted over observed argv, so a name assembled at runtime cannot slip past.
expect_only_disposable_project_names() {
  unexpected=$(normalized_log | tr '[' '\n' |
    sed -n 's/^platform_project_name=\([^]]*\)\].*$/\1/p' |
    grep -v '^{ns}$' | grep -v '^{ns}-negative$' || true)
  [ -z "$unexpected" ] ||
    fail "plays deployed under project names the sandbox does not derive: $unexpected"
}

# ---------------------------------------------------------------------------
# The cases. Each runs once against the pristine program and once per plant.
# ---------------------------------------------------------------------------

# The thin path: vault handover, launcher library, lifecycle plan, converge,
# idempotence and --check --diff, with no service scenario.
case_idempotence_check() {
  run_controller idempotence-check host_prep,deployment_bundle true true \
    site.yml
  expect_status 0

  expect_log_count 'ansible-playbook argv=' 3
  expect_log_count '[--tags][host_prep,deployment_bundle]' 3
  expect_log_count '[--check][--diff]' 1
  expect_log 'ansible-playbook argv=[-i][inventory/local.yml][--vault-password-file][{sandbox}/nas-platform-vault.000000/password][-e][@{sandbox}/nas-platform-vault.000000/vault.yml]'
  expect_log '[site.yml][--tags][host_prep,deployment_bundle][--check][--diff]'
  expect_output '=== phase 2: asserting idempotence ==='
  expect_output '=== phase 3: asserting --check --diff works ==='
  expect_output 'IDEMPOTENT: second run changed nothing'
  expect_output 'CHECK MODE OK: dry run completed'
  expect_output 'FRESH_ROOT_OK: clean deployment root converged'

  expect_log_count 'ansible-playbook env=[ANSIBLE_VAULT_PASSWORD_FILE={sandbox}/nas-platform-vault.000000/password]' 3
  # Empty first brackets: only the downloaders lane asks for an undeclared set.
  expect_log 'ephemeral-vault argv=[--undeclared][][--output][{sandbox}/nas-platform-vault.000000/vault.yml][--password-file][{sandbox}/nas-platform-vault.000000/password]'
  expect_log 'ephemeral-vault argv=[--cleanup][{sandbox}/nas-platform-vault.000000]'
  if [ "$(cat "$checkout/inventory/group_vars/all/vault.yml" 2>/dev/null)" != \
       '$ANSIBLE_VAULT;1.1;AES256' ]; then
    fail 'the checkout vault was not replaced by the generated ephemeral vault'
  fi
  if [ -e "$checkout/inventory/group_vars/all/vault_beszel.yml" ]; then
    fail 'a committed per-service vault was left beside the ephemeral vault'
  fi
  expect_only_disposable_project_names

  expect_log 'verify-manifest argv=[{sandbox}/volume1/Docker/nas-platform/current/manifest.yml][{repo}][{repo}/services/manifest.yml][nas][integration][0000000000000000000000000000000000000abc]'
}

case_extra_arguments() {
  run_controller idempotence-check host_prep,deployment_bundle true true \
    site.yml --limit nas
  expect_status 0
  expect_log_count '[--limit][nas]' 3
  expect_log '[site.yml][--tags][host_prep,deployment_bundle][--limit][nas][--check][--diff]'
}

# The untagged shape (nightly, `--full`): no `--tags` may reach any of the three
# phases. This case reaches every branch of `run_selected_play`. The quoted
# `[ -z $INTEGRATION_TAGS ]` in perform_initial_converge cannot be planted: unquoted is also true.
case_empty_tags() {
  run_controller idempotence-check '' true true site.yml
  expect_status 0
  expect_log_count 'ansible-playbook argv=' 3
  expect_log_count '[--tags]' 0
  expect_log_count '[--check][--diff]' 1
  expect_log '[site.yml][--check][--diff]'
  expect_output 'IDEMPOTENT: second run changed nothing'
  expect_output 'CHECK MODE OK: dry run completed'
}

case_arr() {
  run_controller arr host_prep,deployment_bundle,arr true true site.yml
  expect_status 0
  expect_log 'collision argv=[live]'
  expect_log 'contract arr argv=[static]'
  expect_log '[{repo}/verify.yml][--tags][platform_verify_arr]'
  expect_log '[site.yml][--tags][arr]'
  expect_log '[site.yml][--tags][arr][--check][--diff]'
  expect_output 'ARR_PHASE1_RUNTIME_VERIFIED'
  # Four of the provider's six values are inventory, not vault, since #298.
  expect_log '[-e][media_usenet_enabled=true][-e][{"media_usenet_provider":{"host":"news.usenet.invalid","port":563,"connections":8,"ssl":true}}][-e][media_acquisition_adopt_existing_libraries=true]'
  expect_log_order 'collision argv=[live]' 'contract arr argv=[static]'
  expect_log_order '[site.yml][--tags][arr]' \
    '[site.yml][--tags][arr][--check][--diff]'
  expect_only_disposable_project_names
}

case_downloaders() {
  run_controller downloaders \
    host_prep,deployment_bundle,arr,downloaders true true site.yml
  expect_status 0
  expect_log 'contract arr argv=[static]'
  expect_log 'contract downloaders argv=[static]'
  expect_log '[{repo}/verify.yml][--tags][platform_verify_arr]'
  expect_log '[{repo}/verify.yml][--tags][platform_verify_downloaders]'
  expect_log '[site.yml][--tags][arr,downloaders]'
  expect_log '[site.yml][--tags][arr,downloaders][--check][--diff]'
  expect_log_order '[site.yml][--tags][arr,downloaders]' \
    '[site.yml][--tags][arr,downloaders][--check][--diff]'
  # This lane's vault declares no Usenet provider; asserted, not inferred (#274).
  expect_log 'ephemeral-vault argv=[--undeclared][usenet][--output]'
  # Both halves or neither: roles/downloaders refuses a half-declared provider.
  expect_log '[-e][{"media_usenet_provider":{"host":"","port":563,"connections":8,"ssl":true}}]'
  # The verification play is a separate invocation and must get the value too.
  expect_log '[-e][media_usenet_enabled=true][-e][{"media_usenet_provider":{"host":"","port":563,"connections":8,"ssl":true}}][{repo}/verify.yml][--tags][platform_verify_downloaders]'
  expect_output 'DOWNLOADERS_UNDECLARED_PROVIDER_RUNTIME_VERIFIED'
}

# The declared half of the pair; the two `--undeclared` assertions are each
# other's negation (#274).
case_bindery() {
  run_controller bindery \
    host_prep,deployment_bundle,arr,downloaders,audiobookshelf,bindery true true site.yml
  expect_status 0
  expect_log 'ephemeral-vault argv=[--undeclared][][--output]'
  expect_log 'contract arr argv=[static]'
  expect_log 'contract downloaders argv=[static]'
  expect_log 'contract bindery argv=[static]'
  expect_log 'contract bindery argv=[run]'
  expect_log '[{repo}/verify.yml][--tags][platform_verify_downloaders]'
  expect_log '[{repo}/verify.yml][--tags][platform_verify_bindery]'
  expect_log '[-e][media_usenet_enabled=true][-e][{"media_usenet_provider":{"host":"news.usenet.invalid","port":563,"connections":8,"ssl":true}}][{repo}/verify.yml][--tags][platform_verify_downloaders]'
  expect_log '[site.yml][--tags][arr,downloaders,audiobookshelf,bindery]'
  expect_log '[site.yml][--tags][arr,downloaders,audiobookshelf,bindery][--check][--diff]'
  expect_log_order '[site.yml][--tags][arr,downloaders,audiobookshelf,bindery]' \
    '[site.yml][--tags][arr,downloaders,audiobookshelf,bindery][--check][--diff]'
  expect_output 'BINDERY_PHASE2_RUNTIME_VERIFIED'
}

# Seerr's lane carries the shared foundation's runtime proof (#639).
case_seerr() {
  run_controller seerr host_prep,deployment_bundle,arr,jellyfin,seerr \
    true true site.yml
  expect_status 0
  expect_log '[site.yml][--tags][audiobookshelf]'
  expect_log '[{repo}/verify.yml][--tags][platform_verify_media_acquisition_foundation]'
  expect_output 'MEDIA_ACQUISITION_FOUNDATION_RUNTIME_VERIFIED'
  expect_log_order \
    '[site.yml][--tags][audiobookshelf]' \
    '[{repo}/verify.yml][--tags][platform_verify_media_acquisition_foundation]'
  # Verification must not supply the facts it asserts against.
  expect_no_log '[-e][platform_media_control_network='
  expect_no_log '[-e][media_torrent_enabled='
  expect_log 'contract seerr argv=[static]'
  expect_log 'contract seerr argv=[run]'
  expect_log '[site.yml][--tags][arr,jellyfin,seerr][--check][--diff]'
  expect_output 'SEERR_PHASE4_RUNTIME_VERIFIED'
}

case_jellyfin() {
  run_controller jellyfin host_prep,deployment_bundle,jellyfin true true \
    site.yml
  expect_status 0
  expect_log 'contract jellyfin argv=[seed]'
  expect_log 'contract jellyfin argv=[run]'
  expect_log_order 'contract jellyfin argv=[seed]' 'contract jellyfin argv=[run]'
  expect_log 'contract jellyfin env=[PLATFORM_PROJECT_NAME=<unset>][PLATFORM_JELLYFIN_CONTAINER={ns}-jellyfin][PLATFORM_KIND=integration]'
  # The foundation dispatch is a closed case arm; a `seerr)` grep also matched
  # the earlier arm, so it could not see that (#639).
  expect_no_log '[--tags][audiobookshelf]'
  expect_no_log '[--tags][platform_verify_media_acquisition_foundation]'
}

case_komga() {
  run_controller komga host_prep,deployment_bundle,komga true true site.yml
  expect_status 0
  expect_log 'contract komga argv=[seed]'
  expect_log 'contract komga argv=[run]'
  expect_log_order 'contract komga argv=[seed]' 'contract komga argv=[run]'
}

# The upgrade lane. The checkout is a git repository because the repin commits:
# deployment_bundle refuses to mutate an active release. Rebuilt per run, so a
# broken plant cannot leave the next case reading a head equal to its base.
upgrade_base_image=docker.io/mrcas/kapowarr:v0.0.1@sha256:0000000000000000000000000000000000000000000000000000000000000000

# No branch names: init.defaultBranch differs between a Mac and the runner.
build_upgrade_git_fixture() {
  rm -rf "$checkout/.git"
  cp "$repo_dir/services/kapowarr/compose.yml" \
    "$checkout/services/kapowarr/compose.yml"
  git -C "$checkout" init -q
  git -C "$checkout" add -A
  git -C "$checkout" -c user.email=ci@example.invalid -c user.name='CI Test' \
    commit -qm fixture
}

upgrade_compose_at() {
  git -C "$checkout" show "$1:services/kapowarr/compose.yml" 2>/dev/null |
    sed -n 's/^[[:space:]]*image:[[:space:]]*//p'
}

case_upgrade() {
  upgrade_head_image=$(sed -n 's/^[[:space:]]*image:[[:space:]]*//p' \
    "$repo_dir/services/kapowarr/compose.yml")
  build_upgrade_git_fixture
  CASE_UPGRADE_SERVICE=kapowarr
  CASE_UPGRADE_BASE_IMAGE=$upgrade_base_image
  CASE_DOCKER_RUNNING=$namespace-kapowarr
  export CASE_UPGRADE_SERVICE CASE_UPGRADE_BASE_IMAGE CASE_DOCKER_RUNNING
  run_controller upgrade host_prep,deployment_bundle,kapowarr true true site.yml
  unset CASE_UPGRADE_SERVICE CASE_UPGRADE_BASE_IMAGE CASE_DOCKER_RUNNING
  expect_status 0

  # Order is the property: seed before the repin, verify after the second converge.
  expect_log_count '[site.yml][--tags][host_prep,deployment_bundle,kapowarr]' 2
  expect_log 'contract kapowarr argv=[seed]'
  expect_log 'contract kapowarr argv=[verify]'
  expect_log_order 'contract kapowarr argv=[seed]' 'contract kapowarr argv=[verify]'
  expect_output 'UPGRADE_SEEDED'
  expect_output 'UPGRADE_CONVERGED'
  expect_output 'UPGRADE_VERIFIED'
  expect_output 'UPGRADE_STOPPED'
  expect_output 'UPGRADE_LANE_COMPLETE'
  # An action, not a reading: asserted on the argv, not on UPGRADE_STOPPED.
  expect_log 'docker argv=[stop][{ns}-kapowarr]'
  expect_log 'docker argv=[inspect][--format][{{.State.Status}}:{{.State.ExitCode}}][{ns}-kapowarr]'
  expect_log_order 'contract kapowarr argv=[verify]' 'docker argv=[stop][{ns}-kapowarr]'
  # The stop window is read per container, not narrated (#781).
  expect_log 'docker argv=[inspect][--format][{{.Config.StopTimeout}}][{ns}-kapowarr]'
  expect_output 'UPGRADE_STOPPED_CONTAINER: {ns}-kapowarr exited:0'
  # Only running containers: an exited one answers `docker stop` with 0.
  expect_log 'docker argv=[ps][--filter][label=com.docker.compose.project={ns}-kapowarr][--filter][status=running][--format][{{.Names}}]'
  expect_no_log '[site.yml][--tags][host_prep,deployment_bundle,kapowarr][--check][--diff]'

  # The property the lane rests on, read from the fixture's history: the first
  # converge pinned the base image, the second the head.
  observed_base=$(upgrade_compose_at 'HEAD~1')
  observed_head=$(upgrade_compose_at HEAD)
  [ "$observed_base" = "$upgrade_base_image" ] ||
    fail "the first converge's revision pinned $observed_base, not the base image"
  [ "$observed_head" = "$upgrade_head_image" ] ||
    fail "the second converge's revision pinned $observed_head, not the head image"
  upgrade_revisions=$(git -C "$checkout" rev-list --count HEAD)
  [ "$upgrade_revisions" -eq 3 ] ||
    fail "the upgrade lane left $upgrade_revisions revision(s), expected 3"
}

# 137 is 128+SIGKILL (#671): its own case, since the program is what is under test (#781).
case_upgrade_stop_sigkill() {
  build_upgrade_git_fixture
  CASE_UPGRADE_SERVICE=kapowarr
  CASE_UPGRADE_BASE_IMAGE=$upgrade_base_image
  CASE_DOCKER_RUNNING=$namespace-kapowarr
  CASE_DOCKER_STATE=exited:137
  export CASE_UPGRADE_SERVICE CASE_UPGRADE_BASE_IMAGE CASE_DOCKER_RUNNING \
    CASE_DOCKER_STATE
  run_controller upgrade host_prep,deployment_bundle,kapowarr true true site.yml
  unset CASE_UPGRADE_SERVICE CASE_UPGRADE_BASE_IMAGE CASE_DOCKER_RUNNING \
    CASE_DOCKER_STATE
  expect_nonzero_status
  expect_output 'did not stop cleanly: exited:137'
  # The refusal must come after a successful verify, not instead of it.
  expect_output 'UPGRADE_VERIFIED'
  expect_no_output 'UPGRADE_LANE_COMPLETE'
}

# Not running when the stop arrives: a crashed container must not read as a clean stop.
case_upgrade_stop_nothing_running() {
  build_upgrade_git_fixture
  CASE_UPGRADE_SERVICE=kapowarr
  CASE_UPGRADE_BASE_IMAGE=$upgrade_base_image
  export CASE_UPGRADE_SERVICE CASE_UPGRADE_BASE_IMAGE
  run_controller upgrade host_prep,deployment_bundle,kapowarr true true site.yml
  unset CASE_UPGRADE_SERVICE CASE_UPGRADE_BASE_IMAGE
  expect_nonzero_status
  expect_output 'no running container in the upgrade subject project {ns}-kapowarr to stop'
  expect_no_output 'UPGRADE_LANE_COMPLETE'
}

# The three refusals in front of the lane; base equal to head converges one
# version twice and proves nothing.
case_upgrade_refusals() {
  upgrade_head_image=$(sed -n 's/^[[:space:]]*image:[[:space:]]*//p' \
    "$repo_dir/services/kapowarr/compose.yml")

  run_upgrade_refusal() {
    refusal_service=$1
    refusal_base=$2
    refusal_expected=$3
    build_upgrade_git_fixture
    CASE_UPGRADE_SERVICE=$refusal_service
    CASE_UPGRADE_BASE_IMAGE=$refusal_base
    export CASE_UPGRADE_SERVICE CASE_UPGRADE_BASE_IMAGE
    run_controller upgrade host_prep,deployment_bundle,kapowarr true true site.yml
    unset CASE_UPGRADE_SERVICE CASE_UPGRADE_BASE_IMAGE
    expect_nonzero_status
    expect_output "$refusal_expected"
    expect_no_log '[site.yml][--tags][host_prep,deployment_bundle,kapowarr]'
  }

  run_upgrade_refusal kapowarr "$upgrade_head_image" \
    'the upgrade base and head pins of kapowarr are identical'
  # beszel has four images, so the ambiguity is the repository's own.
  run_upgrade_refusal beszel "$upgrade_base_image" \
    'the upgrade subject beszel does not pin exactly one image'
}

case_upgrade_missing_compose() {
  build_upgrade_git_fixture
  CASE_UPGRADE_SERVICE=nosuchservice
  CASE_UPGRADE_BASE_IMAGE=$upgrade_base_image
  export CASE_UPGRADE_SERVICE CASE_UPGRADE_BASE_IMAGE
  run_controller upgrade host_prep,deployment_bundle,kapowarr true true site.yml
  unset CASE_UPGRADE_SERVICE CASE_UPGRADE_BASE_IMAGE
  expect_nonzero_status
  expect_output 'no compose definition for the upgrade subject nosuchservice'
  expect_no_log '[site.yml][--tags][host_prep,deployment_bundle,kapowarr]'
}

case_toolchain_install() {
  run_controller smoke host_prep,deployment_bundle,beszel true false \
    site.yml
  expect_status 0
  expect_log "apk argv=[add][--no-cache][--quiet][docker-cli][docker-cli-compose][git][tar][openssl][apache2-utils][openssh-client][$ruby_package][$curl_package]"
  expect_log "pip argv=[install][--quiet][--no-input][ansible-core==$ansible_core_version][requests==$requests_version]"
  # --no-cache: an interrupted install leaves a blank Galaxy cache entry.
  expect_log 'ansible-galaxy argv=[collection][install][--no-cache][-r][{repo}/requirements.yml]'
  expect_log_count 'ansible-playbook argv=' 1
  expect_no_log '[--check][--diff]'
}

# Asserted by status only: bash and dash word the refusal differently.
case_refuses_missing_roots() {
  CASE_UNSET_VARIABLE=CONTROLLER_SANDBOX
  export CASE_UNSET_VARIABLE
  run_controller idempotence-check host_prep,deployment_bundle true true \
    site.yml
  unset CASE_UNSET_VARIABLE
  expect_nonzero_status
  expect_log_count 'ansible-playbook argv=' 0

  CASE_REPO_DIR=$checkout/elsewhere
  export CASE_REPO_DIR
  run_controller idempotence-check host_prep,deployment_bundle true true \
    site.yml
  unset CASE_REPO_DIR
  expect_nonzero_status
  expect_log_count 'ansible-playbook argv=' 0
}

# An operator's untracked vault.yml is overwritten in the clone; a symlink
# (even dangling) is refused because `install` would follow it.
case_vault_install_path() {
  CASE_OPERATOR_VAULT=file
  export CASE_OPERATOR_VAULT
  run_controller idempotence-check host_prep,deployment_bundle true true \
    site.yml
  unset CASE_OPERATOR_VAULT
  expect_status 0
  if [ "$(cat "$checkout/inventory/group_vars/all/vault.yml" 2>/dev/null)" != \
       '$ANSIBLE_VAULT;1.1;AES256' ]; then
    fail 'an untracked vault.yml at the install path was not replaced by the ephemeral vault'
  fi

  CASE_OPERATOR_VAULT=dangling-symlink
  export CASE_OPERATOR_VAULT
  run_controller idempotence-check host_prep,deployment_bundle true true \
    site.yml
  unset CASE_OPERATOR_VAULT
  expect_nonzero_status
  expect_log_count 'ansible-playbook argv=' 0
  rm -f "$checkout/inventory/group_vars/all/vault.yml"
}

# ---------------------------------------------------------------------------
# Planted defects. Each plant asserts its expected occurrence count.
# ---------------------------------------------------------------------------

# A count mismatch means the anchor moved (a stale plant, not a detection).
# $6 and $7 name the plant and the repository file it anchors in.
apply_plant() {
  ruby -e '
    path, pattern, replacement, expected, mode, label, source = ARGV
    body = File.read(path)
    needle = mode == "regexp" ? Regexp.new(pattern) : pattern
    count = body.scan(needle).length
    unless count == Integer(expected)
      abort <<~MESSAGE
        STALE PLANT ANCHOR [plant] #{label}: #{source}
          pattern (#{mode}): #{pattern.inspect}
          matched #{count} occurrence(s), expected #{expected}
        The plant could not be applied because its ANCHOR moved: #{source} no
        longer contains that text the expected number of times. This abort is
        about the plant, not the property -- whether the property still holds is
        what any FAIL lines printed above this one report. Re-anchor the plant on
        the line of #{source} that now produces the property; never delete it,
        because a deleted plant leaves its property proved by nothing.
      MESSAGE
    end
    File.write(path, body.gsub(needle, replacement.gsub("\\n", "\n")))
  ' "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}

# label, the case that must fail, program|library, pattern, replacement,
# occurrences, literal|regexp
plant() {
  plant_label=$1
  plant_case=$2
  plant_file=$3
  current_case="plant $plant_label"

  cp "$pristine_program" "$planted_program"
  cp "$pristine_library" "$planted_library"
  case $plant_file in
    program) apply_plant "$planted_program" "$4" "$5" "$6" "${7:-literal}" \
      "$plant_label" tests/integration_controller.sh ;;
    library) apply_plant "$planted_library" "$4" "$5" "$6" "${7:-literal}" \
      "$plant_label" tests/integration_controller_lib.sh ;;
    *) printf 'unknown plant target: %s\n' "$plant_file" >&2; exit 1 ;;
  esac
  relocate_program "$planted_program" \
    "$checkout/tests/integration_controller.sh"
  relocate_program "$planted_library" \
    "$checkout/tests/integration_controller_lib.sh"

  assert_mode=probe
  probe_failures=0
  "case_$plant_case"
  assert_mode=report
  if [ "$probe_failures" -eq 0 ]; then
    printf 'FAIL [plant] %s: case_%s still passed with the defect planted\n' \
      "$plant_label" "$plant_case" >&2
    failures=$((failures + 1))
  else
    printf 'plant detected by case_%s (%s assertion(s) failed): %s\n' \
      "$plant_case" "$probe_failures" "$plant_label"
  fi
}

# ---------------------------------------------------------------------------
# Driver.
# ---------------------------------------------------------------------------

cp "$repo_dir/tests/integration_controller.sh" "$pristine_program"
cp "$repo_dir/tests/integration_controller_lib.sh" "$pristine_library"
build_stub_bin
build_checkout

for healthy_case in idempotence_check extra_arguments empty_tags arr \
    downloaders bindery seerr jellyfin komga upgrade upgrade_stop_sigkill \
    upgrade_stop_nothing_running upgrade_refusals \
    upgrade_missing_compose toolchain_install \
    refuses_missing_roots vault_install_path; do
  current_case=$healthy_case
  "case_$healthy_case"
done

plant 'launcher library not sourced' idempotence_check program \
  '. /repo/tests/integration_controller_lib.sh' ':' 1
plant 'suite tags dropped from the selected play' idempotence_check program \
  'run_play --tags "$INTEGRATION_TAGS" "$@"' 'run_play "$@"' 1
# The empty-tags fix reverted: phases 2 and 3 then get `--tags ""` (SC2070).
plant 'empty tags select only the always tasks' empty_tags program \
  'if [ -n "$INTEGRATION_TAGS" ]; then' 'if [ -n $INTEGRATION_TAGS ]; then' 1
plant 'check mode dropped from phase 3' idempotence_check program \
  'if run_selected_play "$@" --check --diff; then' \
  'if run_selected_play "$@"; then' 1
plant 'second converge dropped from phase 2' idempotence_check program \
  'run_selected_play "$@" >/tmp/second.txt 2>&1 || idempotence_status=$?' \
  'idempotence_status=0' 1
plant 'initial converge dropped' idempotence_check program \
  'perform_initial_converge "$@"' ':' 1
plant 'generated vault not installed into the checkout' idempotence_check \
  program 'install -m 0600 "$vault_file" /repo/inventory/group_vars/all/vault.yml' \
  ':' 1
plant 'dangling vault.yml symlink followed instead of refused' \
  vault_install_path program \
  'test ! -L /repo/inventory/group_vars/all/vault.yml' ':' 1
plant 'committed per-service vaults left beside the ephemeral vault' \
  idempotence_check program \
  'rm -f /repo/inventory/group_vars/all/vault_*.yml' ':' 1
plant 'vault password file not exported' idempotence_check program \
  'export ANSIBLE_VAULT_PASSWORD_FILE="$vault_password_file"' ':' 1
plant 'deployed manifest verified against the wrong path' idempotence_check \
  program '"$sandbox/volume1/Docker/nas-platform/current/manifest.yml"' \
  '"$sandbox/elsewhere/manifest.yml"' 1
plant 'play vault password binding removed' idempotence_check library \
  '--vault-password-file "$vault_password_file"' \
  '--vault-password-file /dev/null' 2
plant 'plays deploy under a production project name' idempotence_check library \
  '-e platform_project_name="$integration_project_namespace"' \
  '-e platform_project_name=nas-platform' 2
plant 'live collision contract dropped' arr program \
  '/repo/tests/media_control_network_collision_test.sh live' ':' 1
plant 'static acquisition contract dropped' arr program \
  '/repo/tests/contracts/arr.sh static' ':' 5
plant 'acquisition verification-only play dropped' arr program \
  'run_arr_verify_only' ':' 2
plant 'enabled idempotence converge dropped' arr program \
  'run_enabled_idempotence arr\n' ':\n' 1 regexp
plant 'acquisition check mode dropped' arr program \
  'run_play --tags arr --check --diff' 'run_play --tags arr' 1
plant 'check mode runs before the idempotence converge' arr program \
  'run_enabled_idempotence arr\n      run_play --tags arr --check --diff\n' \
  'run_play --tags arr --check --diff\n      run_enabled_idempotence arr\n' \
  1 regexp
plant 'downloaders check mode runs before its idempotence converge' \
  downloaders program \
  'run_enabled_idempotence arr,downloaders\n      run_play --tags arr,downloaders --check --diff\n' \
  'run_play --tags arr,downloaders --check --diff\n      run_enabled_idempotence arr,downloaders\n' \
  1 regexp
plant 'undeclared provider request dropped' downloaders program \
  '--undeclared usenet' '' 1
# Planted both ways: each half-declared state is invisible to the lane already in it.
plant 'declared provider policy host dropped' arr program \
  'integration_media_usenet_host=news.usenet.invalid' \
  'integration_media_usenet_host=' 1
plant 'undeclared provider policy branch dropped' downloaders program \
  'downloaders) integration_media_usenet_host=' \
  'never) integration_media_usenet_host=' 1
plant 'verification provider policy dropped' bindery library \
  '-e "$integration_media_usenet_provider" "$@"' '"$@"' 1
plant 'declared downloader verification-only play dropped' bindery program \
  'run_downloaders_verify_only' ':' 2
plant 'acquisition reader prerequisites dropped' seerr program \
  'converge_media_acquisition_reader_prerequisites' ':' 1
plant 'acquisition foundation verification dropped' seerr program \
  'run_media_acquisition_foundation_verify' ':' 1
plant 'verification supplies the transport fact it asserts against' seerr \
  library 'set -- /repo/verify.yml --tags "platform_verify_$verification_tag"' \
  'set -- -e platform_media_control_network=nas-media /repo/verify.yml --tags "platform_verify_$verification_tag"' \
  1
plant 'acquisition foundation dispatch opened to every suite' jellyfin program \
  '\n      seerr\)\n' '\n      *)\n' 1 regexp
plant 'suite_is matches only the full lane' jellyfin program \
  '[ "$INTEGRATION_SUITE" = full ] || [ "$INTEGRATION_SUITE" = "$1" ]' \
  '[ $INTEGRATION_SUITE = full ]' 1
plant 'Jellyfin fixture seed dropped' jellyfin program \
  'run_jellyfin_contract seed' ':' 1
plant 'Jellyfin owning contract dropped' jellyfin program \
  'run_jellyfin_contract run' ':' 1
plant 'Komga fixture seed dropped' komga program \
  'run_komga_contract seed' ':' 1
# The upgrade lane's plants (#773): seed and verify, then the pin surgery.
plant 'upgrade seed dropped' upgrade program \
  'run_contract "$upgrade_service" seed' ':' 1
plant 'upgrade verify dropped' upgrade program \
  'run_contract "$upgrade_service" verify' ':' 1
plant 'upgrade base pin never committed' upgrade program \
  'commit_subject_image "integration: $upgrade_service at its base pin"' ':' 1
plant 'upgrade repin never committed' upgrade program \
  'commit_subject_image "integration: $upgrade_service at its head pin"' ':' 1
plant 'upgrade converge dropped' upgrade program \
  'run_selected_play "$@" || upgrade_converge_status=$?' \
  'upgrade_converge_status=0' 1
# The stop (#781): one plant per decision.
plant 'upgraded container never actually stopped' upgrade program \
  'docker stop "$upgrade_container" >/dev/null || {' \
  ': stop "$upgrade_container" >/dev/null || {' 1
plant 'a SIGKILLed stop tolerated' upgrade_stop_sigkill program \
  'exited:0|exited:143) ;;' 'exited:*) ;;' 1
plant 'a stack that is not running tolerated' upgrade_stop_nothing_running \
  program '[ -n "$upgrade_running" ] || {' '[ -z "" ] || {' 1
plant 'identical base and head pins tolerated' upgrade_refusals program \
  '[ "$upgrade_head_image" != "$upgrade_base_image" ] || {' \
  'if false; then' 1
plant 'an ambiguous multi-image subject tolerated' upgrade_refusals program \
  'the upgrade subject %s does not pin exactly one image' \
  'the upgrade subject %s was read' 1
plant 'a missing compose definition tolerated' upgrade_missing_compose program \
  '[ -f "$upgrade_compose" ] || {' 'if false; then' 1
plant 'docker_container_info runtime support not installed' toolchain_install \
  program '"requests==$requests_version"' '"requests-not-installed"' 1

if [ "$failures" -ne 0 ]; then
  printf '%s controller execution failure(s)\n' "$failures" >&2
  exit 1
fi
printf 'integration controller execution: every property held and every plant was detected\n'
