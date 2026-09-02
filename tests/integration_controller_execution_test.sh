#!/bin/sh
# What tests/integration_controller.sh *does*, proved by running it.
#
# Until this file existed the controller's dispatch was guarded by reading its
# source text: `grep -qF 'run_play --tags "$INTEGRATION_TAGS" "$@"'` and a dozen
# assertions like it in tests/integration_suite_test.sh. A grep that matched and
# an execution test that never exercised the path both pass on a healthy tree,
# and only one of them notices when the line stops being reached. So the
# controller is executed here against stubbed `ansible-playbook`, `docker`,
# contracts and helpers, and every property is asserted against the argv and
# environment those stubs observed.
#
# TWO ROOTS, AND THIS FILE OWNS BOTH OF THEM EXPLICITLY.
# The controller refuses to work out either root for itself: the checkout under
# test arrives as CONTROLLER_REPO_DIR and the disposable target tree as
# CONTROLLER_SANDBOX, and tests/policy_test.rb forbids any $0 / dirname /
# BASH_SOURCE resolution in it. In production the checkout is bind-mounted at
# /repo, and the controller's paths are literal /repo/... which is why running it
# outside the container needs the one transformation this file performs: a
# relocation of /repo onto a disposable checkout built here. The relocation is
# counted, not trusted -- see relocate_program -- because a substitution that
# silently matches nothing would leave a test that runs the wrong program and
# reports a pass.
#
# EVIDENCE IS PLANTED-DEFECT DETECTION, NOT A PASSING RUN.
# Every property below is paired with a plant: the controller line that produces
# it is deleted or corrupted in a throwaway copy, and the same assertions are
# required to fail. The plants run here, in the gate, rather than being reported
# in a pull request body, because "the guard still detects" is otherwise
# unverifiable by anyone but its author. Each plant asserts its own match count,
# so a plant that quietly substitutes nothing fails instead of reporting a pass
# that proves nothing.
#
# ONE KNOWN BUG IS PINNED AS IT IS, NOT AS IT SHOULD BE.
# `run_selected_play` reads `[ -n $INTEGRATION_TAGS ]`, unquoted: `[ -n ]` is a
# one-argument test on the non-empty string `-n`, so it is true on an empty
# value (SC2070). Extracting the controller from its `sh -c` argument is what
# made that visible, and the gate excludes SC2068/SC2070/SC2086 while it stands.
# The empty-tags lane below therefore asserts what the program does today -- a
# `--tags` with an empty value in phases 2 and 3, and no `--tags` at all in
# phase 1, whose `[ -z $INTEGRATION_TAGS ]` is accidentally right -- and says so.
# Asserting the sane behaviour instead would fail on a correct program.
set -eu

repo_dir=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-controller-exec.XXXXXX")
work=$(CDPATH= cd -P "$work" && pwd -P)
trap 'rm -rf "$work"' EXIT HUP INT TERM

# Deliberately not "$work/repo": the relocation rewrites every literal /repo in
# the program, and a destination containing that substring makes a residual
# occurrence unreadable in a diff.
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

# Read back rather than restated: Renovate bumps both of these in the launcher,
# and a copy of either here would turn the next bump into a red gate that says
# nothing about the controller. The two package pins below are this test's own
# fixture values, so they stay literals.
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
# The disposable checkout.
#
# Production mounts a *copy* of the caller's tree at /repo -- integration.sh
# builds it at $sandbox/repo -- so a checkout the controller writes its
# generated vault into is what it already expects. Only the files the controller
# and its launcher library actually reach are placed here; a file that turns out
# to be missing makes the controller die, which fails this test, so the fixture
# cannot drift silently the way an over-broad copy could rot.
# ---------------------------------------------------------------------------

install_stub() {
  stub_path=$1
  mkdir -p "$(dirname "$stub_path")"
  cat > "$stub_path"
  chmod 0755 "$stub_path"
}

# Every stub logs one line per invocation in the same shape, so an assertion can
# name argv word by word: a value that lost its quoting arrives as two words and
# the fixed-string match fails.
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
    "$checkout/inventory/group_vars/all" "$checkout/services/ntfy"

  # Read for real: the controller runs the lifecycle producer/consumer out of the
  # checkout, and both the suite roster and the consumer's refusals are theirs.
  cp "$repo_dir/tests/integration.sh" "$checkout/tests/integration.sh"
  cp "$repo_dir/tests/integration_lifecycle.sh" \
    "$checkout/tests/integration_lifecycle.sh"
  cp "$repo_dir/tests/ci/suites.conf" "$checkout/tests/ci/suites.conf"
  chmod 0755 "$checkout/tests/integration.sh"
  cp "$repo_dir/services/ntfy/compose.yml" "$checkout/services/ntfy/compose.yml"
  cp "$repo_dir/inventory/group_vars/all/main.yml" \
    "$checkout/inventory/group_vars/all/main.yml"
  printf '%s\n' '---' > "$checkout/inventory/local.yml"
  # A regular non-symlink file the controller is required to overwrite with the
  # ephemeral vault it generated. Its bytes are the assertion for that property.
  printf '%s\n' 'committed-operator-vault' \
    > "$checkout/inventory/group_vars/all/vault.yml"
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
while [ $# -gt 0 ]; do
  case $1 in
    --output) vault_output=$2; shift 2 ;;
    --password-file) vault_password_output=$2; shift 2 ;;
    *) printf 'unexpected ephemeral vault argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done
printf 'ephemeral-vault argv=[--output][%s][--password-file][%s]\n' \
  "$vault_output" "$vault_password_output" >> "${CONTROLLER_STUB_LOG:?}"
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

  # One stub per contract the lanes below reach. run_contract prepends the
  # environment ABI, so the contract records the two variables whose derivation
  # from the disposable namespace is the property under test.
  #
  # jellyfin-foundation and komga-foundation exist for a lane that must never
  # reach them. The acquisition foundation dispatch is a *closed* case arm, and
  # a closedness assertion that only holds because the stub is absent would be
  # detecting a missing fixture rather than an opened arm -- so the fixture is
  # present and the absence of the invocation is what is asserted.
  for contract_name in arr downloaders bindery trailarr seerr seerr-foundation \
      kapowarr pinchflat jellyfin jellyfin-foundation komga komga-foundation; do
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

# The one transformation, and the reason it is safe to make. Every /repo in the
# program becomes the disposable checkout, including the launcher's own
# `[ "$CONTROLLER_REPO_DIR" = /repo ]` guard, so the two roots stay exactly as
# explicit as they are in production. The count is asserted in both directions:
# the destination path contains no /repo substring, so a residual occurrence
# means the substitution missed a line, and a low replacement count means the
# source no longer says what this file thinks it says.
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

  # The recap is what the controller and the launcher library parse: phase 2
  # requires changed=0 and failed=0, and run_enabled_idempotence requires
  # exactly one recap naming the target host.
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

  for stub_name in ansible-galaxy apk pip docker sha256sum stat; do
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
    "$sandbox/volume1/Docker/nas-platform/current/services/ntfy" \
    "$sandbox/volume1/Docker/nas-platform/runtime/services"
  # The controller compares the target's ntfy compose against the checkout's
  # byte for byte. Nothing here converges, so the target copy is seeded.
  cp "$checkout/services/ntfy/compose.yml" \
    "$sandbox/volume1/Docker/nas-platform/current/services/ntfy/compose.yml"
  # Restored per run, not once: the controller overwrites it with the ephemeral
  # vault it generated, and a copy left over from the previous run would make a
  # planted defect that skips that install look like a pass.
  printf '%s\n' 'committed-operator-vault' \
    > "$checkout/inventory/group_vars/all/vault.yml"
  chmod 0644 "$checkout/inventory/group_vars/all/vault.yml"
}

# ---------------------------------------------------------------------------
# Running the program.
# ---------------------------------------------------------------------------

# Every CONTROLLER_* input the program requires, spelled once. Absent ones are
# refused by `${VAR:?}` at the top of the controller, which is a property a case
# below exercises by status alone: `bash` and `dash` word that refusal
# differently, so pinning its text would pin which shell the machine has.
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

# suite, tags, service scenarios, toolchain, then the playbook and any extra
# Ansible arguments -- the same argv the launcher hands across the boundary.
run_controller() {
  run_suite=$1
  run_tags=$2
  run_scenarios=$3
  run_toolchain=$4
  shift 4

  build_sandbox
  : > "$stub_log"
  # The controller writes phase 2's output to a literal /tmp/second.txt. A file
  # left by an earlier case would let a planted defect that removes the second
  # play go undetected, so it is removed rather than trusted.
  rm -f /tmp/second.txt /tmp/media-acquisition-idempotence.txt
  mkdir -p "$work/home"

  run_status=0
  # A subshell rather than `env`, so no value has to survive word splitting, and
  # so nothing exported here reaches the next case. HOME is redirected because
  # the controller runs `git config --global` and must not reach the caller's
  # configuration. The working directory is the checkout, which is what -w /repo
  # gives the program in production and what its `-i inventory/local.yml`
  # resolves against.
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
    export PATH HOME CONTROLLER_STUB_LOG PLATFORM_INTEGRATION_SANDBOX \
      PLATFORM_INTEGRATION_PROJECT_NAMESPACE INTEGRATION_SUITE INTEGRATION_TAGS \
      INTEGRATION_RUN_SERVICE_SCENARIOS INTEGRATION_TOOLCHAIN_PREINSTALLED \
      MEDIA_CONTROL_COLLISION_IMAGE PLATFORM_PAPERLESS_FIXTURE_PRESEEDED \
      PLATFORM_KOMGA_FIXTURE_PRESEEDED PLATFORM_JELLYFIN_FIXTURE_PRESEEDED
    cd "$checkout" || exit 1
    exec sh "$checkout/tests/integration_controller.sh" "$@"
  ) > "$run_output" 2>&1 || run_status=$?
}

# ---------------------------------------------------------------------------
# Assertions.
#
# The log is read with the run's own paths and namespace replaced by tokens, so
# each expectation is a fixed string a reader can check against the controller.
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

# Order is a property in its own right: an idempotence play that ran after the
# check-mode play would prove nothing about the converge it is meant to follow.
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

# Nothing may deploy under a project name the disposable sandbox does not own: a
# stack started under its production project survives sandbox cleanup. Asserted
# over observed argv rather than over the source text, so a name assembled at
# runtime cannot slip past a fixed-string read of the file.
expect_only_disposable_project_names() {
  unexpected=$(normalized_log | tr '[' '\n' |
    sed -n 's/^platform_project_name=\([^]]*\)\].*$/\1/p' |
    grep -v '^{ns}$' | grep -v '^{ns}-negative$' || true)
  [ -z "$unexpected" ] ||
    fail "plays deployed under project names the sandbox does not derive: $unexpected"
}

# ---------------------------------------------------------------------------
# The cases. Each is a lane the controller can be driven through end to end
# against stubs, and each asserts the properties that lane is the cheapest place
# to observe. `case_<name>` is called twice: once against the pristine program,
# and once per planted defect, where the same assertions must fail.
# ---------------------------------------------------------------------------

# The idempotence-check lane is the thin path. It reaches the vault handover,
# the launcher library, the lifecycle plan, the initial converge and both of the
# harness's other two promises -- a second run that changes nothing and a
# working --check --diff -- without entering a single service scenario.
case_idempotence_check() {
  run_controller idempotence-check host_prep,deployment_bundle,ntfy true true \
    site.yml
  expect_status 0

  # The three plays the harness exists to run, in order, each carrying the tags
  # the launcher chose as one argv word.
  expect_log_count 'ansible-playbook argv=' 3
  expect_log_count '[--tags][host_prep,deployment_bundle,ntfy]' 3
  expect_log_count '[--check][--diff]' 1
  expect_log 'ansible-playbook argv=[-i][inventory/local.yml][--vault-password-file][{sandbox}/nas-platform-vault.000000/password][-e][@{sandbox}/nas-platform-vault.000000/vault.yml]'
  expect_log '[site.yml][--tags][host_prep,deployment_bundle,ntfy][--check][--diff]'
  expect_output '=== phase 2: asserting idempotence ==='
  expect_output '=== phase 3: asserting --check --diff works ==='
  expect_output 'IDEMPOTENT: second run changed nothing'
  expect_output 'CHECK MODE OK: dry run completed'
  expect_output 'FRESH_ROOT_OK: clean deployment root converged'

  # The vault the controller generated is the vault every play reads, both as
  # the checkout's own encrypted file and as the exported password file. Nothing
  # is read back out of a running service, so this is the whole credential path.
  expect_log_count 'ansible-playbook env=[ANSIBLE_VAULT_PASSWORD_FILE={sandbox}/nas-platform-vault.000000/password]' 3
  expect_log 'ephemeral-vault argv=[--output][{sandbox}/nas-platform-vault.000000/vault.yml][--password-file][{sandbox}/nas-platform-vault.000000/password]'
  expect_log 'ephemeral-vault argv=[--cleanup][{sandbox}/nas-platform-vault.000000]'
  if [ "$(cat "$checkout/inventory/group_vars/all/vault.yml")" != \
       '$ANSIBLE_VAULT;1.1;AES256' ]; then
    fail 'the checkout vault was not replaced by the generated ephemeral vault'
  fi
  expect_only_disposable_project_names

  # The bundle the target carries must be the controller's own, checked against
  # the checkout rather than reported by the play that installed it.
  expect_log 'verify-manifest argv=[{sandbox}/volume1/Docker/nas-platform/current/manifest.yml][{repo}][{repo}/services/manifest.yml][nas][integration][0000000000000000000000000000000000000abc]'
}

# Extra Ansible arguments must survive the two hops from the caller's command
# line, through the launcher, into every play the controller runs.
case_extra_arguments() {
  run_controller idempotence-check host_prep,deployment_bundle,ntfy true true \
    site.yml --limit nas
  expect_status 0
  expect_log_count '[--limit][nas]' 3
  expect_log '[site.yml][--tags][host_prep,deployment_bundle,ntfy][--limit][nas][--check][--diff]'
}

# The empty-tags shape, pinned as the program behaves rather than as it should.
# `perform_initial_converge` reads `[ -z $INTEGRATION_TAGS ]` and takes the
# untagged branch, while `run_selected_play` reads `[ -n $INTEGRATION_TAGS ]`
# -- `[ -n ]`, a one-argument test on a non-empty string, so true either way --
# and passes an empty --tags in phases 2 and 3. Both spellings are unquoted
# expansions the extraction exposed (SC2070) and the pinned shellcheck exclusion
# tolerates; fixing them is a change of its own, and this case is what would
# have to be updated when it lands.
case_empty_tags() {
  run_controller idempotence-check '' true true site.yml
  expect_status 0
  expect_log_count 'ansible-playbook argv=' 3
  expect_log_count '[site.yml][--tags][]' 2
  expect_log_count '[--check][--diff]' 1
}

# The acquisition lane's own five-step proof: the registry-free collision
# contract, the static contract, a verification-only play, a real second
# converge for idempotence, and only then check mode.
case_arr() {
  run_controller arr host_prep,deployment_bundle,ntfy,arr true true site.yml
  expect_status 0
  expect_log 'collision argv=[live]'
  expect_log 'contract arr argv=[static]'
  expect_log '[{repo}/verify.yml][--tags][platform_verify_arr]'
  expect_log '[site.yml][--tags][arr]'
  expect_log '[site.yml][--tags][arr][--check][--diff]'
  expect_output 'ARR_PHASE1_RUNTIME_VERIFIED'
  # The enabled lane converges with the transport on, which is what makes the
  # verification assert against real reader state rather than a skipped role.
  expect_log '[-e][media_usenet_enabled=true][-e][media_acquisition_adopt_existing_libraries=true]'
  expect_log_order 'collision argv=[live]' 'contract arr argv=[static]'
  # Idempotence is proved by a real play, and it must precede check mode: a
  # check-mode run cannot stand in for the converge it is meant to follow.
  expect_log_order '[site.yml][--tags][arr]' \
    '[site.yml][--tags][arr][--check][--diff]'
  expect_only_disposable_project_names
}

case_downloaders() {
  run_controller downloaders \
    host_prep,deployment_bundle,ntfy,arr,downloaders true true site.yml
  expect_status 0
  expect_log 'contract arr argv=[static]'
  expect_log 'contract downloaders argv=[static]'
  expect_log '[{repo}/verify.yml][--tags][platform_verify_arr]'
  expect_log '[{repo}/verify.yml][--tags][platform_verify_downloaders]'
  expect_log '[site.yml][--tags][arr,downloaders]'
  expect_log '[site.yml][--tags][arr,downloaders][--check][--diff]'
  expect_log_order '[site.yml][--tags][arr,downloaders]' \
    '[site.yml][--tags][arr,downloaders][--check][--diff]'
  expect_output 'DOWNLOADERS_PHASE1_RUNTIME_VERIFIED'
}

# Seerr is the last acquisition project, so the shared inert foundation's own
# runtime proof lives in its lane: the static foundation contract, the reader
# prerequisites converge, and a verification play whose only fact is the tag.
case_seerr() {
  run_controller seerr host_prep,deployment_bundle,ntfy,arr,jellyfin,seerr \
    true true site.yml
  expect_status 0
  expect_log 'contract seerr-foundation argv=[static]'
  expect_log '[site.yml][--tags][host_prep,deployment_bundle,ntfy,audiobookshelf,jellyfin]'
  expect_log '[{repo}/verify.yml][--tags][platform_verify_media_acquisition_foundation]'
  expect_output 'MEDIA_ACQUISITION_FOUNDATION_RUNTIME_VERIFIED'
  expect_log_order 'contract seerr-foundation argv=[static]' \
    '[site.yml][--tags][host_prep,deployment_bundle,ntfy,audiobookshelf,jellyfin]'
  expect_log_order \
    '[site.yml][--tags][host_prep,deployment_bundle,ntfy,audiobookshelf,jellyfin]' \
    '[{repo}/verify.yml][--tags][platform_verify_media_acquisition_foundation]'
  # The foundation verification must not supply the facts it is meant to assert
  # against: a lane that forced the transport or the control network would be
  # asserting against a truth it wrote itself rather than the inventory's.
  expect_no_log '[-e][platform_media_control_network='
  expect_no_log '[-e][media_torrent_enabled='
  # ... and then falls through to Seerr's own arm rather than exiting there.
  expect_log 'contract seerr argv=[static]'
  expect_log 'contract seerr argv=[run]'
  expect_log '[site.yml][--tags][arr,jellyfin,seerr][--check][--diff]'
  expect_output 'SEERR_PHASE4_RUNTIME_VERIFIED'
}

# Komga and Jellyfin each dispatch their scenarios independently of the suite
# that converges them: a seed for every lane that reaches the service, and the
# full contract only for the lane that owns it.
case_jellyfin() {
  run_controller jellyfin host_prep,deployment_bundle,ntfy,jellyfin true true \
    site.yml
  expect_status 0
  expect_log 'contract jellyfin argv=[seed]'
  expect_log 'contract jellyfin argv=[run]'
  expect_log_order 'contract jellyfin argv=[seed]' 'contract jellyfin argv=[run]'
  expect_log 'contract jellyfin env=[PLATFORM_PROJECT_NAME=<unset>][PLATFORM_JELLYFIN_CONTAINER={ns}-jellyfin][PLATFORM_KIND=integration]'
  # The acquisition foundation dispatch is a closed case arm: no lane but the
  # last acquisition project's runs the shared foundation's static contract, its
  # reader prerequisites or its verification. The text assertion this replaces
  # -- `grep -qF 'seerr)'` -- could not see that, because the same string also
  # appears in the `arr|downloaders|bindery|trailarr|seerr)` arm forty lines
  # earlier, so it would have passed with the dispatch arm deleted outright.
  expect_no_log 'contract jellyfin-foundation'
  expect_no_log '[--tags][host_prep,deployment_bundle,ntfy,audiobookshelf,jellyfin]'
  expect_no_log '[--tags][platform_verify_media_acquisition_foundation]'
}

case_komga() {
  run_controller komga host_prep,deployment_bundle,ntfy,komga true true site.yml
  expect_status 0
  expect_log 'contract komga argv=[seed]'
  expect_log 'contract komga argv=[run]'
  expect_log_order 'contract komga argv=[seed]' 'contract komga argv=[run]'
}

# The smoke lane stops after the converge, and is the cheapest place to observe
# the toolchain the controller installs when it is not running from an image
# that already has it -- the path a developer's first run and a fork's CI take.
case_toolchain_install() {
  run_controller smoke host_prep,deployment_bundle,ntfy,beszel true false \
    site.yml
  expect_status 0
  expect_log "apk argv=[add][--no-cache][--quiet][docker-cli][docker-cli-compose][git][tar][openssl][apache2-utils][openssh-client][$ruby_package][$curl_package]"
  expect_log "pip argv=[install][--quiet][--no-input][ansible-core==$ansible_core_version][requests==$requests_version]"
  expect_log 'ansible-galaxy argv=[collection][install][-r][{repo}/requirements.yml]'
  expect_log_count 'ansible-playbook argv=' 1
  expect_no_log '[--check][--diff]'
}

# Both roots are non-defaultable, and the refusals are asserted by status only:
# `bash` says "parameter null or not set" and `dash` says "parameter not set or
# null", so a case pinning either would be pinning which shell ran it.
case_refuses_missing_roots() {
  CASE_UNSET_VARIABLE=CONTROLLER_SANDBOX
  export CASE_UNSET_VARIABLE
  run_controller idempotence-check host_prep,deployment_bundle,ntfy true true \
    site.yml
  unset CASE_UNSET_VARIABLE
  expect_nonzero_status
  expect_log_count 'ansible-playbook argv=' 0

  CASE_REPO_DIR=$checkout/elsewhere
  export CASE_REPO_DIR
  run_controller idempotence-check host_prep,deployment_bundle,ntfy true true \
    site.yml
  unset CASE_REPO_DIR
  expect_nonzero_status
  expect_log_count 'ansible-playbook argv=' 0
}

# ---------------------------------------------------------------------------
# Planted defects.
#
# A case that passes on a healthy tree proves nothing on its own -- that was
# true of the greps this file replaces and it is true of execution. So every
# property above is paired with a defect planted in the line that produces it,
# and the same case is required to fail. The substitution declares how many
# occurrences it expects and refuses to apply otherwise: three mutation rows in
# this repository have silently planted nothing and reported a pass that proved
# nothing, and an unchecked count is exactly how.
# ---------------------------------------------------------------------------

apply_plant() {
  ruby -e '
    path, pattern, replacement, expected, mode = ARGV
    body = File.read(path)
    needle = mode == "regexp" ? Regexp.new(pattern) : pattern
    count = body.scan(needle).length
    unless count == Integer(expected)
      abort "plant matched #{count} occurrence(s) of #{pattern.inspect}, expected #{expected}"
    end
    File.write(path, body.gsub(needle, replacement.gsub("\\n", "\n")))
  ' "$1" "$2" "$3" "$4" "$5"
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
    program) apply_plant "$planted_program" "$4" "$5" "$6" "${7:-literal}" ;;
    library) apply_plant "$planted_library" "$4" "$5" "$6" "${7:-literal}" ;;
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
    downloaders seerr jellyfin komga toolchain_install refuses_missing_roots; do
  current_case=$healthy_case
  "case_$healthy_case"
done

plant 'launcher library not sourced' idempotence_check program \
  '. /repo/tests/integration_controller_lib.sh' ':' 1
plant 'suite tags dropped from the selected play' idempotence_check program \
  'run_play --tags "$INTEGRATION_TAGS" "$@"' 'run_play "$@"' 1
plant 'check mode dropped from phase 3' idempotence_check program \
  'if run_selected_play $@ --check --diff; then' \
  'if run_selected_play $@; then' 1
plant 'second converge dropped from phase 2' idempotence_check program \
  'run_selected_play $@ >/tmp/second.txt 2>&1 || idempotence_status=$?' \
  'idempotence_status=0' 1
plant 'initial converge dropped' idempotence_check program \
  'perform_initial_converge $@' ':' 1
plant 'generated vault not installed into the checkout' idempotence_check \
  program 'install -m 0600 "$vault_file" /repo/inventory/group_vars/all/vault.yml' \
  ':' 1
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
plant 'acquisition foundation contract dropped' seerr program \
  '/repo/tests/contracts/$INTEGRATION_SUITE-foundation.sh static' ':' 1
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
  '[ $INTEGRATION_SUITE = full ] || [ $INTEGRATION_SUITE = $1 ]' \
  '[ $INTEGRATION_SUITE = full ]' 1
plant 'Jellyfin fixture seed dropped' jellyfin program \
  'run_jellyfin_contract seed' ':' 1
plant 'Jellyfin owning contract dropped' jellyfin program \
  'run_jellyfin_contract run' ':' 1
plant 'Komga fixture seed dropped' komga program \
  'run_komga_contract seed' ':' 1
plant 'docker_container_info runtime support not installed' toolchain_install \
  program '"requests==$requests_version"' '"requests-not-installed"' 1

if [ "$failures" -ne 0 ]; then
  printf '%s controller execution failure(s)\n' "$failures" >&2
  exit 1
fi
printf 'integration controller execution: every property held and every plant was detected\n'
