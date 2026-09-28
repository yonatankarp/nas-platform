#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd -P)
integration=$repo_dir/tests/integration.sh
# Launchers live in their own file so these assertions read plain shell.
controller_library=$repo_dir/tests/integration_controller_lib.sh
[ -r "$controller_library" ] || {
  printf '%s\n' 'integration controller library is missing' >&2
  exit 1
}
# Controller behaviour is proved by tests/integration_controller_execution_test.sh;
# this file reads the controller only for properties execution cannot reach.
controller_program=$repo_dir/tests/integration_controller.sh
[ -r "$controller_program" ] || {
  printf '%s\n' 'integration controller program is missing' >&2
  exit 1
}
grep -qF -- '-e PLATFORM_INTEGRATION_SANDBOX="$sandbox"' "$integration" &&
  grep -qF -- \
    '-e PLATFORM_INTEGRATION_PROJECT_NAMESPACE="$integration_project_namespace"' \
    "$integration" || {
  printf '%s\n' 'integration controller library is not given the sandbox it deploys into' >&2
  exit 1
}
fake_bin=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-suite-test.XXXXXX")
fake_bin=$(CDPATH= cd -P "$fake_bin" && pwd -P)
docker_log=$fake_bin/docker.log
prepull_bin=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-prepull-test.XXXXXX")
pull_log=$prepull_bin/pull.log
sleep_log=$prepull_bin/sleep.log
prepull_output=$prepull_bin/prepull.output
interrupt_tmp=$prepull_bin/interrupt-tmp
concurrency_dir=$prepull_bin/concurrency
concurrency_log=$prepull_bin/concurrency.log
truncated_repo=$prepull_bin/truncated-repo
truncated_tmp=$prepull_bin/truncated-tmp
immich_order_mutant=$fake_bin/immich-order-mutant.sh
acquisition_runtime_mutant=$fake_bin/acquisition-runtime-mutant.sh
idempotence_helper=$fake_bin/enabled-idempotence-helper.sh
idempotence_recap=$fake_bin/enabled-idempotence-recap.txt
namespace_helper=$fake_bin/integration-namespace-helper.sh

cleanup() {
  for case_root in "$fake_bin/contract-cases" "$fake_bin/boundary-cases" \
      "$fake_bin/hostile-repository" "$fake_bin/playbook-sandbox" \
      "$fake_bin/check-mode-sandbox"; do
    if [ -d "$case_root" ] && [ ! -L "$case_root" ]; then
      find "$case_root" -depth -mindepth 1 -delete 2>/dev/null || true
      rmdir "$case_root" 2>/dev/null || true
    fi
  done
  rm -f "$fake_bin/docker" "$fake_bin/mktemp" "$docker_log"
  rm -f "$immich_order_mutant"
  rm -f "$acquisition_runtime_mutant"
  rm -f "$idempotence_helper" "$idempotence_recap"
  rm -f "$namespace_helper"
  rm -f "$fake_bin/hostile-validator-ran"
  rmdir "$fake_bin"
  rm -f "$prepull_bin/docker" "$prepull_bin/sleep" "$prepull_bin/od" \
    "$pull_log" "$sleep_log" "$prepull_output" "$concurrency_log"
  if [ -d "$concurrency_dir" ] && [ ! -L "$concurrency_dir" ]; then
    find "$concurrency_dir" -depth -mindepth 1 -delete 2>/dev/null || true
    rmdir "$concurrency_dir" 2>/dev/null || true
  fi
  for prepull_root in "$interrupt_tmp" "$truncated_repo" "$truncated_tmp"; do
    if [ -d "$prepull_root" ] && [ ! -L "$prepull_root" ]; then
      find "$prepull_root" -depth -mindepth 1 -delete 2>/dev/null || true
      rmdir "$prepull_root" 2>/dev/null || true
    fi
  done
  rmdir "$prepull_bin"
}
trap cleanup EXIT HUP INT TERM

cat > "$fake_bin/docker" <<'EOF'
#!/bin/sh
printf 'docker invoked: %s\n' "$*" >> "$DOCKER_LOG"
if [ "${FAKE_DOCKER_ASSERT_ABSENT:-false}" = true ]; then
  case $1:$2 in
    info:--format) exit 0 ;;
    container:inspect)
      printf 'Error: No such container: %s\n' "$3" >&2
      exit 1
      ;;
  esac
fi
exit 99
EOF
chmod +x "$fake_bin/docker"

cat > "$fake_bin/mktemp" <<'EOF'
#!/bin/sh
printf 'mktemp invoked: %s\n' "$*" >> "$DOCKER_LOG"
exit 98
EOF
chmod +x "$fake_bin/mktemp"

run_integration() {
  PATH="$fake_bin:$PATH" DOCKER_LOG=$docker_log "$integration" "$@"
}

lifecycle_consumer=$repo_dir/tests/integration_lifecycle.sh
[ -f "$lifecycle_consumer" ] || {
  printf '%s\n' 'integration lifecycle consumer seam is absent' >&2
  exit 1
}
. "$lifecycle_consumer"

assert_lifecycle_consumer_rejected() {
  case_name=$1
  producer=$2
  consumer_status=0
  consumer_output=$(consume_integration_lifecycle_plan "$producer" 2>&1) ||
    consumer_status=$?
  [ "$consumer_status" -ne 0 ] || {
    printf 'lifecycle consumer accepted %s:\n%s\n' \
      "$case_name" "$consumer_output" >&2
    exit 1
  }
}

produce_success_then_fail() {
  printf '%s\n' success
  return 23
}

produce_success_before_converge() {
  printf '%s\n' success converge
}

produce_duplicate_success() {
  printf '%s\n' converge success success
}

produce_event_after_success() {
  printf '%s\n' converge success converge
}

produce_retired_lifecycle() {
  printf '%s\n' seed-retirement-fixture start-retirement-fixture converge assert-retired success
}

assert_lifecycle_consumer_rejected 'success followed by producer failure' \
  produce_success_then_fail
assert_lifecycle_consumer_rejected 'success before converge' \
  produce_success_before_converge
assert_lifecycle_consumer_rejected 'duplicate success' produce_duplicate_success
assert_lifecycle_consumer_rejected 'known event after success' produce_event_after_success
assert_lifecycle_consumer_rejected 'retired lifecycle' produce_retired_lifecycle
[ "$(consume_integration_lifecycle_plan printf '%s\n' converge success)" = \
  'converge
success' ]
consumed_controller_plan=$(INTEGRATION_RUN_SERVICE_SCENARIOS=false \
  run_integration --consume-lifecycle --suite full)
[ "$consumed_controller_plan" = 'converge
success' ] || {
  printf 'controller did not consume the validated lifecycle plan:\n%s\n' \
    "$consumed_controller_plan" >&2
  exit 1
}

assert_output() {
  expected=$1
  shift
  actual=$(run_integration "$@")
  [ "$actual" = "$expected" ] || {
    printf 'expected: %s\nactual:   %s\n' "$expected" "$actual" >&2
    exit 1
  }
}

assert_rejected() {
  expected=$1
  shift
  status=0
  output=$(run_integration "$@" 2>&1) || status=$?
  [ "$status" -eq 2 ] || {
    printf 'expected exit 2, got %s: %s\n' "$status" "$output" >&2
    exit 1
  }
  printf '%s\n' "$output" | grep -qF "$expected" || {
    printf 'missing rejection %s in: %s\n' "$expected" "$output" >&2
    exit 1
  }
  [ ! -e "$docker_log" ] || {
    printf 'rejected invocation reached Docker: %s\n' "$(cat "$docker_log")" >&2
    exit 1
  }
}

assert_lifecycle_mode_rejected() {
  expected=$1
  shift
  rm -f "$docker_log"
  rejected_status=0
  rejected_output=$(run_integration "$@" 2>&1) || rejected_status=$?
  [ "$rejected_status" -eq 2 ] || {
    printf 'lifecycle conflict exited %s instead of 2: %s\n' \
      "$rejected_status" "$rejected_output" >&2
    exit 1
  }
  printf '%s\n' "$rejected_output" | grep -qF "$expected" || {
    printf 'lifecycle conflict did not report %s: %s\n' \
      "$expected" "$rejected_output" >&2
    exit 1
  }
  [ ! -e "$docker_log" ] || {
    printf 'lifecycle conflict caused a side effect: %s\n' \
      "$(cat "$docker_log")" >&2
    exit 1
  }
}

assert_lifecycle_mode_rejected 'integration lifecycle mode conflicts with describe-only' \
  --consume-lifecycle --describe-suite full
assert_lifecycle_mode_rejected 'integration lifecycle mode conflicts with describe-only' \
  --observe-lifecycle --describe-suite full
assert_lifecycle_mode_rejected 'integration lifecycle mode conflicts with describe-only' \
  --describe-suite full --consume-lifecycle
assert_lifecycle_mode_rejected 'integration lifecycle mode conflicts with describe-only' \
  --describe-suite full --observe-lifecycle
assert_lifecycle_mode_rejected 'integration lifecycle mode conflicts with suite listing' \
  --consume-lifecycle --list-suites
assert_lifecycle_mode_rejected 'integration lifecycle mode conflicts with suite listing' \
  --observe-lifecycle --list-suites
assert_lifecycle_mode_rejected 'integration lifecycle modes conflict' \
  --consume-lifecycle --observe-lifecycle --suite full
assert_lifecycle_mode_rejected 'integration lifecycle modes conflict' \
  --observe-lifecycle --consume-lifecycle --suite full
assert_lifecycle_mode_rejected 'integration lifecycle mode must be the first argument' \
  site.yml --observe-lifecycle
assert_lifecycle_mode_rejected 'integration lifecycle mode must be the first argument' \
  site.yml --consume-lifecycle
assert_lifecycle_mode_rejected 'integration lifecycle mode must be the first argument' \
  site.yml --check --observe-lifecycle
assert_lifecycle_mode_rejected 'integration lifecycle mode must be the first argument' \
  site.yml --check --consume-lifecycle
assert_lifecycle_mode_rejected 'integration lifecycle mode conflicts with suite listing' \
  --list-suites --consume-lifecycle
assert_lifecycle_mode_rejected 'integration lifecycle mode conflicts with suite listing' \
  --list-suites --observe-lifecycle

describe_conflict_status=0
describe_conflict_output=$(INTEGRATION_DESCRIBE_ONLY=1 \
  run_integration --consume-lifecycle --suite full 2>&1) ||
  describe_conflict_status=$?
[ "$describe_conflict_status" -eq 2 ] &&
  printf '%s\n' "$describe_conflict_output" |
    grep -qF 'integration lifecycle mode conflicts with describe-only' || {
      printf 'environment describe-only bypassed lifecycle mode: %s\n' \
        "$describe_conflict_output" >&2
      exit 1
    }
describe_conflict_status=0
describe_conflict_output=$(INTEGRATION_DESCRIBE_ONLY=1 \
  run_integration --observe-lifecycle --suite full 2>&1) ||
  describe_conflict_status=$?
[ "$describe_conflict_status" -eq 2 ] &&
  printf '%s\n' "$describe_conflict_output" |
    grep -qF 'integration lifecycle mode conflicts with describe-only' || {
      printf 'environment describe-only bypassed lifecycle observation: %s\n' \
        "$describe_conflict_output" >&2
      exit 1
    }

assert_lifecycle() {
  expected=$1
  suite_name=$2
  rm -f "$docker_log"
  actual=$(run_integration --observe-lifecycle --suite "$suite_name")
  [ "$actual" = "$expected" ] || {
    printf 'expected lifecycle for %s:\n%s\nactual lifecycle:\n%s\n' \
      "$suite_name" "$expected" "$actual" >&2
    exit 1
  }
  [ "$(printf '%s\n' "$actual" | tail -n 1)" = success ] || {
    printf 'lifecycle for %s did not terminate in success\n' "$suite_name" >&2
    exit 1
  }
  if printf '%s\n' "$actual" | grep -Eq \
      '^(seed|run|assert-persistence|api-readiness|metadata-readiness)$'; then
    printf 'lifecycle for %s retained active-service behavior\n' "$suite_name" >&2
    exit 1
  fi
  [ ! -e "$docker_log" ] || {
    printf 'lifecycle observation caused a side effect: %s\n' "$(cat "$docker_log")" >&2
    exit 1
  }
}

assert_output \
  'foundation arr downloaders bindery kapowarr pinchflat trailarr seerr smoke beszel dozzle audiobookshelf komga jellyfin immich paperless nextcloud vaultwarden karakeep upgrade idempotence-check idempotence-1 idempotence-2 idempotence-3 idempotence-4 idempotence-5 idempotence-6 full' \
  --list-suites

for suite_name in foundation arr downloaders bindery kapowarr pinchflat trailarr seerr smoke beszel dozzle audiobookshelf komga jellyfin immich paperless nextcloud vaultwarden karakeep idempotence-check idempotence-1 idempotence-2 idempotence-3 idempotence-4 idempotence-5 idempotence-6 full; do
  assert_lifecycle 'converge
success' "$suite_name"
done

# The upgrade lane's plan is a `seed`, which assert_lifecycle's guard refuses, so
# it is asserted in full here.
rm -f "$docker_log"
upgrade_plan=$(run_integration --observe-lifecycle --suite upgrade)
[ "$upgrade_plan" = 'converge
seed
repin
converge
verify
stop
success' ] || {
  printf 'unexpected upgrade lifecycle plan:\n%s\n' "$upgrade_plan" >&2
  exit 1
}
[ ! -e "$docker_log" ] || {
  printf 'upgrade lifecycle observation caused a side effect: %s\n' \
    "$(cat "$docker_log")" >&2
  exit 1
}

# The consumer must accept what the runner emits.
upgrade_validated=$(run_integration --consume-lifecycle --suite upgrade) || {
  printf '%s\n' 'the lifecycle table refused the upgrade plan' >&2
  exit 1
}
[ "$upgrade_validated" = "$upgrade_plan" ] || {
  printf 'lifecycle table rewrote the upgrade plan:\n%s\n' "$upgrade_validated" >&2
  exit 1
}

status=0
invalid_controller_plan=$(INTEGRATION_RUN_SERVICE_SCENARIOS=invalid \
  run_integration --observe-lifecycle --suite full 2>&1) || status=$?
[ "$status" -eq 2 ] || {
  printf 'invalid controller lifecycle decision exited %s instead of 2: %s\n' \
    "$status" "$invalid_controller_plan" >&2
  exit 1
}
printf '%s\n' "$invalid_controller_plan" |
  grep -qF 'invalid integration service-scenario decision: invalid' || {
    printf 'invalid controller lifecycle decision did not fail closed: %s\n' \
      "$invalid_controller_plan" >&2
    exit 1
  }

host_plan=$(run_integration --observe-lifecycle site.yml --check --diff)
controller_plan=$(INTEGRATION_RUN_SERVICE_SCENARIOS=false \
  run_integration --observe-lifecycle --suite full)
[ "$controller_plan" = "$host_plan" ] || {
  printf 'controller lifecycle differs from host-derived lifecycle:\n' >&2
  printf 'host:\n%s\ncontroller:\n%s\n' "$host_plan" "$controller_plan" >&2
  exit 1
}
[ "$host_plan" = 'converge
success' ] || {
  printf 'check/diff lifecycle unexpectedly includes service scenarios:\n%s\n' \
    "$host_plan" >&2
  exit 1
}
explicit_host_plan=$(run_integration --observe-lifecycle --suite full)
explicit_controller_plan=$(INTEGRATION_RUN_SERVICE_SCENARIOS=true \
  run_integration --observe-lifecycle --suite full)
[ "$explicit_controller_plan" = "$explicit_host_plan" ] || {
  printf 'explicit controller lifecycle differs from host-derived lifecycle:\n' >&2
  printf 'host:\n%s\ncontroller:\n%s\n' \
    "$explicit_host_plan" "$explicit_controller_plan" >&2
  exit 1
}

assert_output 'suite=foundation tags=deployment_bundle playbook=site.yml scenarios=true' \
  --describe-suite foundation
assert_output \
  'suite=arr tags=host_prep,deployment_bundle,arr playbook=site.yml scenarios=true' \
  --describe-suite arr
assert_output \
  'suite=downloaders tags=host_prep,deployment_bundle,arr,downloaders playbook=site.yml scenarios=true' \
  --describe-suite downloaders
assert_output \
  'suite=bindery tags=host_prep,deployment_bundle,arr,downloaders,audiobookshelf,bindery playbook=site.yml scenarios=true' \
  --describe-suite bindery
assert_output \
  'suite=kapowarr tags=host_prep,deployment_bundle,kapowarr playbook=site.yml scenarios=true' \
  --describe-suite kapowarr
assert_output \
  'suite=pinchflat tags=host_prep,deployment_bundle,pinchflat playbook=site.yml scenarios=true' \
  --describe-suite pinchflat
assert_output \
  'suite=trailarr tags=host_prep,deployment_bundle,arr,trailarr playbook=site.yml scenarios=true' \
  --describe-suite trailarr
assert_output \
  'suite=seerr tags=host_prep,deployment_bundle,arr,jellyfin,seerr playbook=site.yml scenarios=true' \
  --describe-suite seerr
# The foundation's runtime proof runs in the last acquisition lane; its dispatch is
# executed by tests/integration_controller_execution_test.sh (case_seerr).
acquisition_runtime_contract_holds() {
  source_path=$1
  library_path=$2
  reader_converge=$(sed -n '/converge_media_acquisition_reader_prerequisites() {/,/^}$/p' "$library_path")
  foundation_verify=$(sed -n '/run_media_acquisition_foundation_verify() {/,/^}$/p' "$library_path")
  # The foundation tag must not be named by the launcher, or the lane asserts a
  # truth it supplied itself.
  verification_launcher=$(sed -n '/^run_verification() {/,/^}$/p' "$library_path")
  forced_fact_arm=$(printf '%s\n' "$verification_launcher" |
    grep -B 1 -F -- '-e media_usenet_enabled=true' | head -n 1 | tr -d ' ')
  acquisition_dispatch=$(sed -n '/^      seerr)/,/;;/p' "$source_path" | tail -n 12)
  printf '%s\n' "$reader_converge" |
    grep -qE -- '--tags audiobookshelf$' &&
    printf '%s\n' "$foundation_verify" |
      grep -qF 'run_verification media_acquisition_foundation' &&
    printf '%s\n' "$verification_launcher" | grep -qF '/repo/verify.yml' &&
    printf '%s\n' "$verification_launcher" |
      grep -qF -- '--tags "platform_verify_$verification_tag"' &&
    [ "$forced_fact_arm" = 'arr|downloaders)' ] &&
    ! printf '%s\n' "$verification_launcher" |
      grep -Eq -- '-e (platform_media_control_network|media_torrent_enabled)=' &&
    printf '%s\n' "$acquisition_dispatch" |
      grep -qF 'converge_media_acquisition_reader_prerequisites' &&
    printf '%s\n' "$acquisition_dispatch" |
      grep -qF 'run_media_acquisition_foundation_verify'
}
acquisition_runtime_contract_holds "$controller_program" "$controller_library" || {
  printf '%s\n' 'acquisition suites omit the shared inventory-derived Linux runtime verifier path' >&2
  exit 1
}
sed '/run_media_acquisition_foundation_verify$/d' "$controller_program" \
  > "$acquisition_runtime_mutant"
if acquisition_runtime_contract_holds "$acquisition_runtime_mutant" \
    "$controller_library"; then
  printf '%s\n' 'acquisition runtime contract accepts removal of real verifier execution' >&2
  exit 1
fi
assert_output 'suite=beszel tags=host_prep,deployment_bundle,beszel playbook=site.yml scenarios=true' \
  --describe-suite beszel
assert_output 'suite=dozzle tags=host_prep,deployment_bundle,beszel,dozzle playbook=site.yml scenarios=true' \
  --describe-suite dozzle
assert_output 'suite=audiobookshelf tags=host_prep,deployment_bundle,audiobookshelf playbook=site.yml scenarios=true' \
  --describe-suite audiobookshelf
assert_output 'suite=komga tags=host_prep,deployment_bundle,komga playbook=site.yml scenarios=true' \
  --describe-suite komga
assert_output 'suite=jellyfin tags=host_prep,deployment_bundle,jellyfin playbook=site.yml scenarios=true' \
  --describe-suite jellyfin
assert_output 'suite=immich tags=host_prep,deployment_bundle,immich playbook=site.yml scenarios=true' \
  --describe-suite immich
assert_output 'suite=paperless tags=host_prep,deployment_bundle,paperless playbook=site.yml scenarios=true' \
  --describe-suite paperless
assert_output 'suite=nextcloud tags=host_prep,deployment_bundle,nextcloud playbook=site.yml scenarios=true' \
  --describe-suite nextcloud
assert_output 'suite=vaultwarden tags=host_prep,deployment_bundle,vaultwarden playbook=site.yml scenarios=true' \
  --describe-suite vaultwarden
assert_output 'suite=karakeep tags=host_prep,deployment_bundle,karakeep playbook=site.yml scenarios=true' \
  --describe-suite karakeep
assert_output 'suite=full tags= playbook=site.yml scenarios=true' --describe-suite full

assert_output 'suite=smoke tags=host_prep,deployment_bundle,beszel playbook=custom.yml scenarios=true' \
  --describe-suite smoke --tags host_prep,deployment_bundle,beszel custom.yml
assert_output 'suite=smoke tags= playbook=site.yml scenarios=true' \
  --describe-suite smoke --tags ''
assert_output 'suite=idempotence-check tags=host_prep,deployment_bundle playbook=site.yml scenarios=true' \
  --describe-suite idempotence-check --tags host_prep,deployment_bundle
assert_output 'suite=idempotence-check tags= playbook=site.yml scenarios=true' \
  --describe-suite idempotence-check

actual=$(PATH="$fake_bin:$PATH" DOCKER_LOG=$docker_log \
  INTEGRATION_DESCRIBE_ONLY=1 "$integration")
[ "$actual" = 'suite=full tags= playbook=site.yml scenarios=true' ]
actual=$(PATH="$fake_bin:$PATH" DOCKER_LOG=$docker_log \
  INTEGRATION_DESCRIBE_ONLY=1 "$integration" custom.yml --check --diff)
[ "$actual" = 'suite=full tags= playbook=custom.yml scenarios=false' ]
actual=$(PATH="$fake_bin:$PATH" DOCKER_LOG=$docker_log \
  INTEGRATION_DESCRIBE_ONLY=1 "$integration" --suite dozzle)
[ "$actual" = 'suite=dozzle tags=host_prep,deployment_bundle,beszel,dozzle playbook=site.yml scenarios=true' ]

grep -qF -- '-e INTEGRATION_SUITE="$suite"' "$integration"
grep -qF -- '-e INTEGRATION_TAGS="$suite_tags"' "$integration"
grep -qF 'chmod 0700 "$sandbox"' "$integration" || {
  printf '%s\n' 'integration sandbox is not owner-only' >&2
  exit 1
}
grep -qF -- 'sh /repo/tests/integration_controller.sh "$playbook" "$@"' \
  "$integration"
grep -qF -- '"$playbook" "$@"' "$controller_library"
# Every branch of run_selected_play is executed in
# tests/integration_controller_execution_test.sh, not read here.

# Exercise the production namespace derivation so it cannot drift from the harness.
sed -n '/^derive_integration_project_namespace() {/,/^}$/p' \
  "$integration" > "$namespace_helper"
[ -s "$namespace_helper" ] || {
  printf '%s\n' 'integration runner has no project namespace derivation' >&2
  exit 1
}
. "$namespace_helper"
[ "$(derive_integration_project_namespace \
  /tmp/nas-platform-integration.A1B2C3)" = \
  nas-platform-integration-a1b2c3 ] || {
  printf '%s\n' 'integration namespace does not lowercase its sandbox suffix' >&2
  exit 1
}
for invalid_sandbox in \
  /tmp/nas-platform-integration.a1b2c \
  /tmp/nas-platform-integration.a1b2c34 \
  /tmp/nas-platform-integration.a1b-2c \
  /tmp/nas-platform-integration.a1b2_c; do
  invalid_namespace_status=0
  derive_integration_project_namespace "$invalid_sandbox" \
    >/dev/null 2>&1 || invalid_namespace_status=$?
  [ "$invalid_namespace_status" -eq 2 ] || {
    printf 'integration namespace accepted invalid sandbox: %s\n' \
      "$invalid_sandbox" >&2
    exit 1
  }
done
namespace_call_line=$(grep -nF \
  'integration_project_namespace=$(derive_integration_project_namespace "$sandbox")' \
  "$integration" | cut -d: -f1)
controller_run_line=$(grep -nF 'docker run --rm' "$integration" |
  head -1 | cut -d: -f1)
[ -n "$namespace_call_line" ] && [ -n "$controller_run_line" ] &&
  [ "$namespace_call_line" -lt "$controller_run_line" ] || {
  printf '%s\n' 'invalid integration namespaces are not refused before the play' >&2
  exit 1
}
run_play_namespace=$(sed -n '/^run_play() {/,/^}$/p' "$controller_library")
for scoped_project_variable in \
  arr_platform_project_name downloaders_platform_project_name; do
  printf '%s\n' "$run_play_namespace" |
    grep -qF -- \
      "-e $scoped_project_variable=\"\$integration_project_namespace\"" || {
    printf 'integration plays omit scoped namespace %s\n' \
      "$scoped_project_variable" >&2
    exit 1
  }
done
# A stack under its production project is not owned by sandbox cleanup.
printf '%s\n' "$run_play_namespace" |
  grep -qF -- '-e platform_project_name="$integration_project_namespace"' || {
  printf '%s\n' 'integration plays do not deploy under the disposable namespace' >&2
  exit 1
}
if grep -n -- '-e platform_project_name=' \
     "$integration" "$controller_program" "$controller_library" |
   grep -vF -- '-e platform_project_name="$integration_project_namespace"' |
   grep -vF -- '-e platform_project_name="$integration_project_namespace-negative"' \
     >/dev/null; then
  printf '%s\n' 'integration plays use a project name the sandbox does not derive' >&2
  exit 1
fi

# Idempotence needs a real second play, not check mode; source the production
# recap parser so malformed recaps fail closed.
sed -n '/^enabled_idempotence_recap_is_clean() {/,/^}$/p' \
  "$controller_library" > "$idempotence_helper"
[ -s "$idempotence_helper" ] || {
  printf '%s\n' 'integration runner has no enabled idempotence recap parser' >&2
  exit 1
}
. "$idempotence_helper"

enabled_idempotence_runner=$(sed -n \
  '/^run_enabled_idempotence() {/,/^}$/p' "$controller_library")
printf '%s\n' "$enabled_idempotence_runner" |
  grep -qF 'run_play --tags "$idempotence_tags"' || {
    printf '%s\n' 'enabled idempotence gate does not run a tagged play' >&2
    exit 1
  }
if printf '%s\n' "$enabled_idempotence_runner" | grep -qF -- '--check'; then
  printf '%s\n' 'enabled idempotence gate substitutes check mode for convergence' >&2
  exit 1
fi

assert_idempotence_recap_accepted() {
  case_name=$1
  shift
  printf '%b' "$*" > "$idempotence_recap"
  enabled_idempotence_recap_is_clean "$idempotence_recap" || {
    printf 'enabled idempotence parser rejected %s\n' "$case_name" >&2
    exit 1
  }
}

assert_idempotence_recap_rejected() {
  case_name=$1
  shift
  printf '%b' "$*" > "$idempotence_recap"
  if enabled_idempotence_recap_is_clean "$idempotence_recap"; then
    printf 'enabled idempotence parser accepted %s\n' "$case_name" >&2
    exit 1
  fi
}

assert_idempotence_recap_accepted 'clean target recap' \
  'PLAY RECAP *********************************************************************\nnas : ok=37 changed=0 unreachable=0 failed=0 skipped=2 rescued=0 ignored=0\n'
assert_idempotence_recap_accepted 'ANSI-colored clean target recap' \
  '\033[0;36mPLAY RECAP *********************************************************************\033[0m\n\033[0;32mnas : ok=5 changed=0 unreachable=0 failed=0 skipped=0 rescued=0 ignored=0\033[0m\n'
assert_idempotence_recap_rejected 'changed target recap' \
  'PLAY RECAP *********************************************************************\nnas : ok=37 changed=1 unreachable=0 failed=0 skipped=2 rescued=0 ignored=0\n'
assert_idempotence_recap_rejected 'unreachable target recap' \
  'PLAY RECAP *********************************************************************\nnas : ok=3 changed=0 unreachable=1 failed=0 skipped=0 rescued=0 ignored=0\n'
assert_idempotence_recap_rejected 'failed target recap' \
  'PLAY RECAP *********************************************************************\nnas : ok=3 changed=0 unreachable=0 failed=1 skipped=0 rescued=0 ignored=0\n'
assert_idempotence_recap_rejected 'missing recap marker' \
  'nas : ok=37 changed=0 unreachable=0 failed=0 skipped=2 rescued=0 ignored=0\n'
assert_idempotence_recap_rejected 'missing target recap' \
  'PLAY RECAP *********************************************************************\nlocalhost : ok=3 changed=0 unreachable=0 failed=0 skipped=0 rescued=0 ignored=0\n'
assert_idempotence_recap_rejected 'malformed target recap' \
  'PLAY RECAP *********************************************************************\nnas : ok=3 changed=zero unreachable=0 failed=0 skipped=0 rescued=0 ignored=0\n'
assert_idempotence_recap_rejected 'duplicate target recap' \
  'PLAY RECAP *********************************************************************\nnas : ok=3 changed=0 unreachable=0 failed=0 skipped=0 rescued=0 ignored=0\nnas : ok=3 changed=0 unreachable=0 failed=0 skipped=0 rescued=0 ignored=0\n'
assert_idempotence_recap_rejected 'task-output false match before failed recap' \
  'TASK [debug] ********************************************************************\nok: [nas] => {"msg":"changed=0 unreachable=0 failed=0"}\nPLAY RECAP *********************************************************************\nnas : ok=3 changed=1 unreachable=0 failed=0 skipped=0 rescued=0 ignored=0\n'

# Idempotence/check ordering is planted in tests/integration_controller_execution_test.sh.
# The pin must stay in the form Renovate's custom manager can bump: this is its
# `matchStrings` regex, anchored (#652).
grep -qE '^requests_version=[0-9]+\.[0-9]+\.[0-9]+$' "$integration" || {
  printf '%s\n' 'integration controller does not pin docker_container_info runtime support' >&2
  exit 1
}

# Nested bind-mount sources must exist on the daemon host before the sandbox mount.
paperless_preseed_line=$(grep -nF '"$repo_dir/tests/contracts/paperless.sh" seed-fixture-only' \
  "$integration" | cut -d: -f1)
controller_line=$(grep -nF 'docker run --rm' "$integration" | head -1 | cut -d: -f1)
[ -n "$paperless_preseed_line" ] && [ "$paperless_preseed_line" -lt "$controller_line" ] || {
  printf '%s\n' 'Paperless integration fixture is not prepared before the controller mount' >&2
  exit 1
}
grep -qF 'paperless:true|full:true)' "$integration"
grep -qF -- '-e PLATFORM_PAPERLESS_FIXTURE_PRESEEDED="$paperless_fixture_preseeded"' "$integration"
for contract in komga jellyfin; do
  preseed_line=$(grep -nF \
    '"$repo_dir/tests/contracts/'"$contract"'.sh" seed-fixture-only' \
    "$integration" | cut -d: -f1)
  [ -n "$preseed_line" ] && [ "$preseed_line" -lt "$controller_line" ] || {
    printf '%s\n' "$contract integration fixture is not prepared before the controller mount" >&2
    exit 1
  }
done
grep -qF 'komga:true|full:true)' "$integration"
grep -qF 'jellyfin:true|arr:true|downloaders:true' "$integration"
grep -qF 'audiobookshelf:true|arr:true|downloaders:true' "$integration"
grep -qF 'trailarr:true|seerr:true|full:true)' "$integration"
grep -qF -- '-e PLATFORM_KOMGA_FIXTURE_PRESEEDED="$komga_fixture_preseeded"' "$integration"
grep -qF -- '-e PLATFORM_JELLYFIN_FIXTURE_PRESEEDED="$jellyfin_fixture_preseeded"' \
  "$integration"

immich_negative_order_holds() {
  source_path=$1
  function_body=$(sed -n '/run_immich_restore_negative_matrix() {/,/^}$/p' "$source_path")
  host_prep_line=$(printf '%s\n' "$function_body" |
    grep -nF -- '--tags host_prep,deployment_bundle' | head -1 | cut -d: -f1)
  scenario_loop_line=$(printf '%s\n' "$function_body" |
    grep -nF 'for scenario in no-backup corrupt-newest ambiguous-newest unsafe-permissions prior-marker' |
    head -1 | cut -d: -f1)
  [ -n "$host_prep_line" ] && [ -n "$scenario_loop_line" ] &&
    [ "$host_prep_line" -lt "$scenario_loop_line" ]
}
immich_negative_order_holds "$controller_library" || {
  printf '%s\n' 'Immich isolated-root host preparation does not precede the negative matrix' >&2
  exit 1
}
ruby -e '
  source = File.readlines(ARGV.fetch(0))
  function_start = source.index { |line| line.include?("run_immich_restore_negative_matrix()") }
  host_start = (function_start...source.length).find do |index|
    source[index].include?("run_play \\") && source[index + 1]&.include?("scenario_root/docker")
  end
  host_end = (host_start...source.length).find do |index|
    source[index].include?("--tags host_prep,deployment_bundle")
  end
  abort "cannot extract isolated-root host preparation" unless host_start && host_end
  block = source.slice!(host_start..host_end)
  loop_index = source.index do |line|
    line.include?("for scenario in no-backup corrupt-newest ambiguous-newest unsafe-permissions prior-marker")
  end
  abort "cannot extract negative matrix loop" unless loop_index
  source.insert(loop_index + 1, *block)
  File.write(ARGV.fetch(1), source.join)
' "$controller_library" "$immich_order_mutant"
if immich_negative_order_holds "$immich_order_mutant"; then
  printf '%s\n' 'Immich negative-matrix order guard accepts the loop-before-host-prep mutant' >&2
  exit 1
fi

# Komga/Jellyfin dispatch is executed in tests/integration_controller_execution_test.sh;
# Immich's arm stays text because it needs a real Docker daemon.
grep -qF 'suite_is immich' "$controller_program" || {
  printf '%s\n' 'immich has no independent scenario dispatch' >&2
  exit 1
}
# The committed vault is unreadable in CI: each suite swaps in an ephemeral vault in
# an isolated controller copy (the controller half is executed, not read).
grep -qF -- 'controller_mount=$sandbox/repo' "$integration"
grep -qF -- '-e @"$fixture_vars_file"' "$controller_library" || {
  printf '%s\n' 'integration deployment does not consume the protected Immich fixture policy' >&2
  exit 1
}
if grep -qF -- 'controller_mount=$repo_dir' "$integration"; then
  printf '%s\n' 'integration may mount the committed deployment vault directly' >&2
  exit 1
fi

assert_rejected 'unknown integration suite: unknown' --suite unknown
assert_rejected 'unknown integration suite: media' --suite media
assert_rejected 'unknown integration suite: <missing>' --suite
assert_rejected 'unknown integration suite: <missing>' --suite --tags beszel
assert_rejected 'unknown integration suite: <missing>' --describe-suite
assert_rejected 'missing value for --tags' --suite smoke --tags
assert_rejected 'invalid integration tags: Bad' --suite smoke --tags Bad
assert_rejected 'invalid integration tags: komga,,beszel' \
  --suite smoke --tags komga,,beszel
for suite in foundation arr downloaders bindery kapowarr pinchflat trailarr seerr beszel dozzle audiobookshelf komga jellyfin immich paperless nextcloud vaultwarden karakeep full; do
  assert_rejected "integration suite $suite does not accept --tags" \
    --suite "$suite" --tags beszel
done
assert_rejected 'integration suite foundation does not accept --tags' \
  --suite foundation custom.yml --tags beszel
assert_rejected 'integration suite options must precede the playbook' \
  --suite smoke custom.yml --tags 'Bad;touch'
assert_rejected 'integration suite options must precede the playbook' \
  --suite smoke custom.yml --tags=beszel
assert_rejected 'unexpected integration suite argument: --check' \
  --suite smoke custom.yml --check

# Refused, not clamped: the value reaches docker pull and a compose.yml substitution.
assert_rejected \
  'the upgrade suite requires INTEGRATION_UPGRADE_SERVICE and INTEGRATION_UPGRADE_BASE_IMAGE' \
  --suite upgrade --tags host_prep,deployment_bundle,kapowarr site.yml
upgrade_valid_image='docker.io/mrcas/kapowarr:v1.3.1@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
for bad_image in \
  'docker.io/mrcas/kapowarr:v1.3.1' \
  'docker.io/mrcas/kapowarr@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' \
  'docker.io/mrcas/kapowarr:v1.3.1@sha256:0123456789abcdef' \
  'docker.io/mrcas/kapowarr:v1.3.1@sha256:0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef' \
  'docker.io/mrcas/kapowarr:v1.3.1@sha512:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' \
  'docker.io/mrcas/kapo warr:v1.3.1@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' \
  'docker.io/mrcas/kapowarr;touch x:v1.3.1@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
do
  INTEGRATION_UPGRADE_SERVICE=kapowarr INTEGRATION_UPGRADE_BASE_IMAGE=$bad_image \
    assert_rejected "invalid integration upgrade base image: $bad_image" \
      --suite upgrade --tags host_prep,deployment_bundle,kapowarr site.yml
done
INTEGRATION_UPGRADE_SERVICE=Kapowarr INTEGRATION_UPGRADE_BASE_IMAGE=$upgrade_valid_image \
  assert_rejected 'invalid integration upgrade service: Kapowarr' \
    --suite upgrade --tags host_prep,deployment_bundle,kapowarr site.yml
INTEGRATION_UPGRADE_SERVICE=nosuchservice INTEGRATION_UPGRADE_BASE_IMAGE=$upgrade_valid_image \
  assert_rejected 'unknown integration upgrade service: nosuchservice' \
    --suite upgrade --tags host_prep,deployment_bundle,kapowarr site.yml
# A subject with no seed-and-verify program is refused rather than run.
INTEGRATION_UPGRADE_SERVICE=komga INTEGRATION_UPGRADE_BASE_IMAGE=$upgrade_valid_image \
  assert_rejected 'integration upgrade service komga has no seed-and-verify program' \
    --suite upgrade --tags host_prep,deployment_bundle,komga site.yml
# Prefix assignments on a function call persist in POSIX sh; unset them or every
# later case is refused.
unset INTEGRATION_UPGRADE_SERVICE INTEGRATION_UPGRADE_BASE_IMAGE

[ ! -e "$docker_log" ] || {
  printf 'dispatch inspection reached Docker: %s\n' "$(cat "$docker_log")" >&2
  exit 1
}

# Image pre-pull and its retry, driven against a stub docker whose registry refuses
# a chosen number of times per image (#84).

prepull_fail() {
  printf 'prepull: %s\n' "$1" >&2
  exit 1
}

cat > "$prepull_bin/docker" <<'EOF'
#!/bin/sh
set -eu
# The controller image is resolved before anything is pulled: absent locally,
# and -- unless the case says otherwise -- available from the registry.
#
# The formatted probe is the collision fixture asking for a registry digest. An
# image this run pulled has one; an image built locally, which STUB_NO_REPO_DIGEST
# stands in for, has none, and the fixture has to notice.
if [ "${1:-}" = image ] && [ "${2:-}" = inspect ]; then
  if [ "${3:-}" = --format ]; then
    if [ "${STUB_NO_REPO_DIGEST:-false}" != true ] &&
       grep -Fxq -- "${5:-}" "${STUB_PULL_LOG:?}" 2>/dev/null; then
      printf '%s@sha256:%064d\n' "${5%%:*}" 0
    fi
    exit 0
  fi
  exit 1
fi
if [ "${1:-}" = version ]; then
  printf '%s\n' "${STUB_DAEMON_ARCH:-amd64}"
  exit 0
fi
if [ "${1:-}" = pull ]; then
  printf '%s\n' "$2" >> "${STUB_PULL_LOG:?}"
  # A rendezvous rather than a clock: each pull announces itself, waits for the
  # width the case expects to be in flight beside it, and records how many
  # actually were. A serial pre-pull waits alone, spins its bound out and records
  # 1, so the two width cases below separate concurrency from timing rather than
  # from how fast the machine happens to be.
  if [ -n "${STUB_CONCURRENCY_DIR:-}" ]; then
    : > "$STUB_CONCURRENCY_DIR/$$"
    concurrency_spin=0
    while [ "$(find "$STUB_CONCURRENCY_DIR" -type f | wc -l)" \
            -lt "${STUB_CONCURRENCY_EXPECT:-1}" ]; do
      concurrency_spin=$((concurrency_spin + 1))
      [ "$concurrency_spin" -lt 400 ] || break
    done
    printf '%s\n' "$(find "$STUB_CONCURRENCY_DIR" -type f | wc -l | tr -d ' ')" \
      >> "${STUB_CONCURRENCY_LOG:?}"
    rm -f "$STUB_CONCURRENCY_DIR/$$"
  fi
  # A registry that answers "denied" rather than "toomanyrequests" is the
  # ordinary missing-package case, not pressure, and must not be retried.
  if [ -n "${STUB_DENY_PREFIX:-}" ]; then
    case $2 in
      "$STUB_DENY_PREFIX"*)
        printf 'denied: denied\n' >&2
        exit 1
        ;;
    esac
  fi
  attempt=$(grep -Fxc -- "$2" "$STUB_PULL_LOG" || true)
  # A refusal can be aimed at a prefix rather than at every image. The controller
  # image is resolved serially before the loop, so a case that refuses everything
  # never reaches the concurrent path at all; aiming lets one refuse inside it.
  refuse_this=true
  if [ -n "${STUB_REFUSE_PREFIX:-}" ]; then
    case $2 in
      "$STUB_REFUSE_PREFIX"*) ;;
      *) refuse_this=false ;;
    esac
  fi
  if [ "$refuse_this" = true ] && [ "$attempt" -le "${STUB_PULL_REFUSALS:-0}" ]; then
    if [ -n "${STUB_RETRY_AFTER_LINE:-}" ]; then
      printf 'toomanyrequests: %s, allowed: 44000/minute\n' \
        "$STUB_RETRY_AFTER_LINE" >&2
    else
      printf 'toomanyrequests: retry-after: %s, allowed: 44000/minute\n' \
        "${STUB_RETRY_AFTER:-218.093us}" >&2
    fi
    exit 1
  fi
  exit 0
fi
# Pull-only mode must reach the registry and nothing else; anything else here
# would mean the mode had started building a sandbox.
printf 'unexpected docker invocation: %s\n' "$*" >&2
exit 97
EOF
chmod +x "$prepull_bin/docker"

cat > "$prepull_bin/sleep" <<'EOF'
#!/bin/sh
set -eu
if [ "${STUB_SLEEP_INTERRUPT:-0}" = 1 ]; then
  kill -TERM "$PPID"
  exit 0
fi
printf '%s\n' "${1:?}" >> "${STUB_SLEEP_LOG:?}"
EOF

cat > "$prepull_bin/od" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "${STUB_RANDOM_VALUE:-0}"
EOF

chmod +x "$prepull_bin/docker" "$prepull_bin/sleep" "$prepull_bin/od"

# Read back rather than restated: Renovate bumps every one of these digests.
runner_image=$(sed -n 's/^runner_image=//p' "$integration")
[ -n "$runner_image" ] || prepull_fail 'could not read the controller image pin'

collision_test=$repo_dir/tests/media_control_network_collision_test.sh
grep -qxF 'tests/media_control_network_collision_test.sh static' \
  "$repo_dir/tests/validate-policy.sh" ||
  prepull_fail 'static policy does not select the registry-free collision contract'
if grep -qF 'ruby:3.2-alpine' "$collision_test"; then
  prepull_fail 'collision runtime still uses a mutable Docker Hub fixture image'
fi
[ "$(grep -Fc -- '--pull=never' "$collision_test")" -eq 2 ] ||
  prepull_fail 'both collision endpoints must explicitly refuse implicit pulls'
grep -qF 'MEDIA_CONTROL_COLLISION_IMAGE="$collision_image"' "$integration" ||
  prepull_fail 'the owning integration lane does not pass its pre-pulled fixture image'
# That the owning lane runs the live collision test is executed in case_arr.

compose_images() {
  sed -n 's/^[[:space:]]*image:[[:space:]]*//p' "$repo_dir/services/$1/compose.yml"
}

toolchain_prefix=$(sed -n \
  's/^toolchain_repository=${INTEGRATION_TOOLCHAIN_REPOSITORY:-\(.*\)}$/\1/p' \
  "$integration")
[ -n "$toolchain_prefix" ] ||
  prepull_fail 'could not read the controller toolchain repository'

# The toolchain tag is a digest over the harness's pins, so match it by shape.
assert_toolchain_pull_set() {
  toolchain_expected_services=$1
  toolchain_actual=$(sort -u "$pull_log")
  toolchain_seen=$(printf '%s\n' "$toolchain_actual" | grep "^$toolchain_prefix:" || true)
  [ "$(printf '%s\n' "$toolchain_seen" | grep -c .)" -eq 1 ] ||
    prepull_fail "expected exactly one controller toolchain pull, saw [$toolchain_seen]"
  toolchain_tag=${toolchain_seen#"$toolchain_prefix":}
  case $toolchain_tag in
    amd64-*|arm64-*|unknown-*) ;;
    *) prepull_fail "the controller toolchain tag names no daemon architecture: $toolchain_tag" ;;
  esac
  toolchain_tag_digest=${toolchain_tag#*-}
  case $toolchain_tag_digest in
    *[!0123456789abcdef]*|"")
      prepull_fail "the controller toolchain tag is not content-addressed: $toolchain_tag"
      ;;
  esac
  [ "${#toolchain_tag_digest}" -eq 32 ] ||
    prepull_fail "the controller toolchain digest is the wrong width: $toolchain_tag"
  toolchain_remaining=$(printf '%s\n' "$toolchain_actual" |
    grep -v "^$toolchain_prefix:" || true)
  [ "$toolchain_expected_services" = "$toolchain_remaining" ] || {
    printf 'expected service pulls:\n%s\nactual service pulls:\n%s\n' \
      "$toolchain_expected_services" "$toolchain_remaining" >&2
    exit 1
  }
}

run_prepull() {
  prepull_refusals=$1
  prepull_attempts=$2
  shift 2
  : > "$pull_log"
  : > "$sleep_log"
  : > "$prepull_output"
  prepull_status=0
  PATH="$prepull_bin:$PATH" \
    STUB_PULL_LOG=$pull_log \
    STUB_SLEEP_LOG=$sleep_log \
    STUB_PULL_REFUSALS=$prepull_refusals \
    STUB_RETRY_AFTER=${PREPULL_RETRY_AFTER:-218.093us} \
    STUB_RETRY_AFTER_LINE=${PREPULL_RETRY_AFTER_LINE:-} \
    STUB_RANDOM_VALUE=${PREPULL_RANDOM_VALUE:-0} \
    INTEGRATION_PREPULL_ONLY=1 \
    INTEGRATION_TOOLCHAIN=${PREPULL_TOOLCHAIN:-auto} \
    STUB_DENY_PREFIX=${PREPULL_DENY_PREFIX:-} \
    STUB_REFUSE_PREFIX=${PREPULL_REFUSE_PREFIX:-} \
    STUB_CONCURRENCY_DIR=${PREPULL_CONCURRENCY_DIR:-} \
    STUB_CONCURRENCY_EXPECT=${PREPULL_CONCURRENCY_EXPECT:-1} \
    STUB_CONCURRENCY_LOG=${PREPULL_CONCURRENCY_LOG:-} \
    INTEGRATION_IMAGE_PULL_WIDTH=${PREPULL_WIDTH:-4} \
    STUB_NO_REPO_DIGEST=${PREPULL_NO_REPO_DIGEST:-false} \
    INTEGRATION_IMAGE_PULL_ATTEMPTS=$prepull_attempts \
    INTEGRATION_IMAGE_PULL_DELAY=${PREPULL_DELAY:-1} \
    INTEGRATION_IMAGE_PULL_MAX_DELAY=${PREPULL_MAX_DELAY:-60} \
    "$integration" "$@" >"$prepull_output" 2>&1 || prepull_status=$?
}

assert_pull_set() {
  expected=$1
  actual=$(sort -u "$pull_log")
  [ "$expected" = "$actual" ] || {
    printf 'expected pulls:\n%s\nactual pulls:\n%s\n' "$expected" "$actual" >&2
    exit 1
  }
}

assert_pull_count() {
  observed=$(grep -Fxc -- "$1" "$pull_log" || true)
  [ "$observed" -eq "$2" ] ||
    prepull_fail "expected $2 attempt(s) at $1, saw $observed"
}

assert_sleep_log() {
  expected=$1
  actual=$(cat "$sleep_log")
  [ "$expected" = "$actual" ] ||
    prepull_fail "expected sleeps [$expected], saw [$actual]"
}

# Prefix assignments persist in POSIX sh; unset so later cases don't inherit them.
assert_retry_after_sleep() {
  retry_after_case=$1
  expected_sleep=$2
  PREPULL_RETRY_AFTER=$retry_after_case PREPULL_RANDOM_VALUE=0 PREPULL_DELAY=1 \
    run_prepull 1 2 --suite foundation
  [ "$prepull_status" -eq 0 ] ||
    prepull_fail "retry-after $retry_after_case failed the pre-pull ($prepull_status)"
  assert_sleep_log "$expected_sleep"
  unset PREPULL_RETRY_AFTER PREPULL_RANDOM_VALUE PREPULL_DELAY
}

run_prepull 0 4 --suite beszel
[ "$prepull_status" -eq 0 ] || prepull_fail "an answering registry failed the pre-pull ($prepull_status)"
assert_toolchain_pull_set "$({ compose_images beszel; } | sort -u)"
if grep -qxF "$runner_image" "$pull_log"; then
  prepull_fail 'the beszel suite still spent a Docker Hub pull on the controller'
fi
if grep -q 'immich' "$pull_log"; then
  prepull_fail 'the beszel suite pulled images it never converges'
fi

# The upgrade base image is in no compose.yml, so it must be pre-pulled explicitly
# or its pull happens un-retried inside the first converge.
upgrade_base_fixture='docker.io/mrcas/kapowarr:v1.3.1@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
INTEGRATION_UPGRADE_SERVICE=kapowarr \
  INTEGRATION_UPGRADE_BASE_IMAGE=$upgrade_base_fixture \
  run_prepull 0 4 --suite upgrade --tags host_prep,deployment_bundle,kapowarr site.yml
unset INTEGRATION_UPGRADE_SERVICE INTEGRATION_UPGRADE_BASE_IMAGE
[ "$prepull_status" -eq 0 ] ||
  prepull_fail "the upgrade suite's pre-pull failed ($prepull_status)"
assert_toolchain_pull_set "$({ compose_images kapowarr
                               printf '%s\n' "$upgrade_base_fixture"; } | sort -u)"

# ... and no other lane pulls it, even though the inputs sit on every matrix leg.
INTEGRATION_UPGRADE_SERVICE=kapowarr \
  INTEGRATION_UPGRADE_BASE_IMAGE=$upgrade_base_fixture \
  run_prepull 0 4 --suite beszel
unset INTEGRATION_UPGRADE_SERVICE INTEGRATION_UPGRADE_BASE_IMAGE
[ "$prepull_status" -eq 0 ] ||
  prepull_fail "the beszel pre-pull failed with the upgrade inputs present ($prepull_status)"
if grep -qxF "$upgrade_base_fixture" "$pull_log"; then
  prepull_fail 'a non-upgrade lane pulled the upgrade base image'
fi
assert_toolchain_pull_set "$({ compose_images beszel; } | sort -u)"

# Both directions: a peak of four proves nothing unless a width of one is observed
# as one. Five paperless images at width four leave one straggler.
run_prepull_concurrency() {
  rm -rf "$concurrency_dir"
  mkdir -p "$concurrency_dir"
  : > "$concurrency_log"
  PREPULL_WIDTH=$1 \
    PREPULL_CONCURRENCY_DIR=$concurrency_dir \
    PREPULL_CONCURRENCY_EXPECT=$2 \
    PREPULL_CONCURRENCY_LOG=$concurrency_log \
    run_prepull 0 4 --suite paperless
  [ "$prepull_status" -eq 0 ] ||
    prepull_fail "the width $1 pre-pull failed ($prepull_status)"
  concurrency_peak=$(sort -rn "$concurrency_log" | head -1)
  unset PREPULL_WIDTH PREPULL_CONCURRENCY_DIR PREPULL_CONCURRENCY_EXPECT \
    PREPULL_CONCURRENCY_LOG
}

run_prepull_concurrency 4 4
[ "$concurrency_peak" -eq 4 ] ||
  prepull_fail "the pre-pull held $concurrency_peak image(s) in flight at width 4"
assert_toolchain_pull_set "$({ compose_images paperless-ngx; } | sort -u)"

run_prepull_concurrency 1 2
[ "$concurrency_peak" -eq 1 ] ||
  prepull_fail "a width of 1 still held $concurrency_peak image(s) in flight"
assert_toolchain_pull_set "$({ compose_images paperless-ngx; } | sort -u)"

PREPULL_WIDTH=999999999999999999999999999999999999 \
  PREPULL_CONCURRENCY_DIR=$concurrency_dir \
  PREPULL_CONCURRENCY_EXPECT=8 \
  PREPULL_CONCURRENCY_LOG=$concurrency_log \
  run_prepull 0 4 --suite smoke
[ "$prepull_status" -eq 0 ] ||
  prepull_fail "an oversized width failed the pre-pull ($prepull_status)"
[ "$(sort -rn "$concurrency_log" | head -1)" -eq 8 ] ||
  prepull_fail "an oversized width escaped its ceiling: $(sort -rn "$concurrency_log" | head -1)"
unset PREPULL_WIDTH PREPULL_CONCURRENCY_DIR PREPULL_CONCURRENCY_EXPECT \
  PREPULL_CONCURRENCY_LOG

# Refusals inside the concurrent loop; aimed at a prefix so the controller image
# still resolves.
beszel_refuse_prefix=ghcr.io/henrygd/beszel/
compose_images beszel | grep -q "^$beszel_refuse_prefix" ||
  prepull_fail "no beszel image starts with $beszel_refuse_prefix any more"
# Paperless images sort tika first, so tika lands in batch one and paperless-ngx
# is the straggler.
paperless_refuse_prefix=docker.io/apache/tika:
compose_images paperless-ngx | grep -q "^$paperless_refuse_prefix" ||
  prepull_fail "no paperless image starts with $paperless_refuse_prefix any more"

PREPULL_REFUSE_PREFIX=$paperless_refuse_prefix run_prepull 9 2 --suite paperless
[ "$prepull_status" -ne 0 ] ||
  prepull_fail 'a refused service image produced a successful pre-pull'
grep -qF 'toomanyrequests: retry-after:' "$prepull_output" ||
  prepull_fail "the concurrent pre-pull swallowed its child's diagnostic"
grep -qF 'could not pull docker.io/apache/tika:' "$prepull_output" ||
  prepull_fail "the concurrent pre-pull did not name the image it gave up on"
# Bounded overshoot: the refusing batch finishes, no later batch launches.
if grep -q 'paperless-ngx/paperless-ngx' "$pull_log"; then
  prepull_fail 'the pre-pull launched a batch after one carrying a refusal'
fi
unset PREPULL_REFUSE_PREFIX

# A child killed mid-backoff records no status (a refusal) and must remove its own
# diagnostic file; the parent's trap cannot.
mkdir -p "$interrupt_tmp"
: > "$pull_log"
: > "$sleep_log"
: > "$prepull_output"
prepull_status=0
TMPDIR=$interrupt_tmp \
  PATH="$prepull_bin:$PATH" \
  STUB_PULL_LOG=$pull_log \
  STUB_SLEEP_LOG=$sleep_log \
  STUB_PULL_REFUSALS=1 \
  STUB_REFUSE_PREFIX=$beszel_refuse_prefix \
  STUB_RETRY_AFTER=1s \
  STUB_RANDOM_VALUE=0 \
  STUB_SLEEP_INTERRUPT=1 \
  INTEGRATION_PREPULL_ONLY=1 \
  INTEGRATION_IMAGE_PULL_ATTEMPTS=2 \
  INTEGRATION_IMAGE_PULL_DELAY=1 \
  INTEGRATION_IMAGE_PULL_MAX_DELAY=60 \
  "$integration" --suite beszel >"$prepull_output" 2>&1 || prepull_status=$?
[ "$prepull_status" -ne 0 ] ||
  prepull_fail 'an interrupted pre-pull child produced a successful pre-pull'
if find "$interrupt_tmp" -name 'nas-platform-pull-error.*' -print | grep -q .; then
  prepull_fail 'an interrupted pre-pull child leaked its pull diagnostic file'
fi
if find "$interrupt_tmp" -name 'nas-platform-prepull-results.*' -print | grep -q .; then
  prepull_fail 'the interrupted pre-pull leaked its result directory'
fi
find "$interrupt_tmp" -depth -mindepth 1 -delete 2>/dev/null || true
rmdir "$interrupt_tmp"

# A truncated enumeration must fail the pre-pull (#!/bin/sh has no pipefail, so
# `$(... | sort -u)` hid it). trailarr's compose.yml is removed to observe it.
mkdir -p "$truncated_repo/tests/ci" "$truncated_tmp"
cp "$integration" "$truncated_repo/tests/integration.sh"
# Copy the suite table, or the run refuses before reaching the enumeration.
cp "$repo_dir/tests/ci/suites.conf" "$truncated_repo/tests/ci/suites.conf"
cp "$repo_dir/tests/integration.Dockerfile" "$truncated_repo/tests/integration.Dockerfile"
cp "$repo_dir/requirements.yml" "$truncated_repo/requirements.yml"
cp -R "$repo_dir/services" "$truncated_repo/services"
rm "$truncated_repo/services/trailarr/compose.yml"
: > "$pull_log"
: > "$sleep_log"
: > "$prepull_output"
prepull_status=0
TMPDIR=$truncated_tmp \
  PATH="$prepull_bin:$PATH" \
  STUB_PULL_LOG=$pull_log \
  STUB_SLEEP_LOG=$sleep_log \
  STUB_PULL_REFUSALS=0 \
  STUB_RANDOM_VALUE=0 \
  INTEGRATION_PREPULL_ONLY=1 \
  INTEGRATION_IMAGE_PULL_ATTEMPTS=4 \
  INTEGRATION_IMAGE_PULL_DELAY=1 \
  INTEGRATION_IMAGE_PULL_MAX_DELAY=60 \
  "$truncated_repo/tests/integration.sh" --suite trailarr \
  >"$prepull_output" 2>&1 || prepull_status=$?
[ "$prepull_status" -ne 0 ] ||
  prepull_fail 'a truncated image enumeration produced a successful pre-pull'
grep -qF 'could not enumerate the images the trailarr suite needs' \
  "$prepull_output" ||
  prepull_fail "truncated enumeration reported no diagnostic: $(cat "$prepull_output")"
if grep -qF "$(compose_images arr)" "$pull_log"; then
  prepull_fail 'a truncated enumeration still pre-pulled from a partial list'
fi
if find "$truncated_tmp" -name 'nas-platform-prepull.*' -print | grep -q .; then
  prepull_fail 'the refused pre-pull leaked its image enumeration file'
fi

# Paperless's tag and service directory differ, so it proves the map.
run_prepull 0 4 --suite paperless
[ "$prepull_status" -eq 0 ] || prepull_fail "the paperless pre-pull failed ($prepull_status)"
assert_toolchain_pull_set \
  "$({ compose_images paperless-ngx; } | sort -u)"

# Three, not four: the app and its cron sidecar share one image.
run_prepull 0 4 --suite nextcloud
[ "$prepull_status" -eq 0 ] || prepull_fail "the nextcloud pre-pull failed ($prepull_status)"
assert_toolchain_pull_set "$({ compose_images nextcloud; } | sort -u)"

run_prepull 0 4 --suite vaultwarden
[ "$prepull_status" -eq 0 ] || prepull_fail "the vaultwarden pre-pull failed ($prepull_status)"
assert_toolchain_pull_set "$({ compose_images vaultwarden; } | sort -u)"

run_prepull 0 4 --suite karakeep
[ "$prepull_status" -eq 0 ] || prepull_fail "the karakeep pre-pull failed ($prepull_status)"
assert_toolchain_pull_set "$({ compose_images karakeep; } | sort -u)"

# Untagged smoke converges everything, so every service directory must be mapped.
run_prepull 0 4 --suite smoke
[ "$prepull_status" -eq 0 ] || prepull_fail "the untagged smoke pre-pull failed ($prepull_status)"
all_service_images=$(for compose in "$repo_dir"/services/*/compose.yml; do
                       sed -n 's/^[[:space:]]*image:[[:space:]]*//p' "$compose"
                     done)
assert_toolchain_pull_set "$(printf '%s\n' "$all_service_images" | sort -u)"
# Dozzle's alert relay runs on the base python image, so its lanes still pull it.
grep -qxF "$runner_image" "$pull_log" ||
  prepull_fail "the untagged smoke pre-pull skipped the alert relay image"

run_prepull 0 4 --suite smoke --tags host_prep,deployment_bundle,immich
[ "$prepull_status" -eq 0 ] || prepull_fail "the tagged smoke pre-pull failed ($prepull_status)"
assert_toolchain_pull_set "$({ compose_images immich; } | sort -u)"

# From here on the cases test the retry ladder itself, against the base image the
# fallback path pulls.
PREPULL_TOOLCHAIN=off

# The default budget must outlast a real ghcr.io refusal window (#762); an empty
# attempts argument exercises the script's own default.
immich_server_prefix=ghcr.io/immich-app/immich-server:
compose_images immich | grep -q "^$immich_server_prefix" ||
  prepull_fail "no immich image starts with $immich_server_prefix any more"
immich_server_image=$(compose_images immich | grep "^$immich_server_prefix")
PREPULL_REFUSE_PREFIX=$immich_server_prefix PREPULL_RETRY_AFTER=333.368µs \
  run_prepull 6 '' --suite immich
[ "$prepull_status" -eq 0 ] ||
  prepull_fail "the default budget gave up on the six refusals observed in #762 ($prepull_status): $(grep 'could not pull' "$prepull_output")"
grep -qF 'toomanyrequests: retry-after: 333.368µs, allowed: 44000/minute' "$prepull_output" ||
  prepull_fail 'the #762 case never drove the observed refusal'
assert_pull_count "$immich_server_image" 7
PREPULL_REFUSE_PREFIX=$immich_server_prefix PREPULL_RETRY_AFTER=333.368µs \
  run_prepull 99 '' --suite immich
[ "$prepull_status" -ne 0 ] || prepull_fail 'the default budget never gives up'
grep -qF "could not pull $immich_server_image in 10 attempt(s)" "$prepull_output" ||
  prepull_fail "the default budget is not ten attempts: $(grep 'could not pull' "$prepull_output")"
unset PREPULL_REFUSE_PREFIX PREPULL_RETRY_AFTER

run_prepull 2 4 --suite foundation
[ "$prepull_status" -eq 0 ] || prepull_fail "two refusals failed the pre-pull ($prepull_status)"
assert_pull_count "$runner_image" 3
[ "$(wc -l < "$pull_log" | tr -d " ")" -eq 3 ] ||
  prepull_fail "foundation pulled service images it never converges: $(sort -u "$pull_log")"

run_prepull 0 6 --suite foundation
[ "$prepull_status" -eq 0 ] || prepull_fail "an answering registry failed"
assert_sleep_log ""

grep -qF 'LC_ALL=C awk' "$integration" ||
  prepull_fail 'retry-after parser does not pin its numeric locale'
assert_retry_after_sleep 500ns 2
assert_retry_after_sleep 500us 2
assert_retry_after_sleep 500µs 2
assert_retry_after_sleep 500ms 2
assert_retry_after_sleep 1.5s 3
assert_retry_after_sleep 45 46
assert_retry_after_sleep invalid 2

# A retry-after hint is honoured only up to the local ceiling.
assert_retry_after_sleep 1.5m 61
assert_retry_after_sleep 5m 61
assert_retry_after_sleep 999999999999999999999999999999999999s 61

PREPULL_RETRY_AFTER=5m PREPULL_RANDOM_VALUE=0 PREPULL_DELAY=1 \
  PREPULL_MAX_DELAY=120 run_prepull 1 2 --suite foundation
[ "$prepull_status" -eq 0 ] || prepull_fail "raised ceiling failed ($prepull_status)"
assert_sleep_log 121
unset PREPULL_RETRY_AFTER PREPULL_RANDOM_VALUE PREPULL_DELAY PREPULL_MAX_DELAY

# A stricter match would leave the retry-after path dead without failing anything.
assert_retry_after_sleep_line() {
  PREPULL_RETRY_AFTER_LINE=$1 PREPULL_RANDOM_VALUE=0 PREPULL_DELAY=1 \
    run_prepull 1 2 --suite foundation
  [ "$prepull_status" -eq 0 ] ||
    prepull_fail "diagnostic [$1] failed the pre-pull ($prepull_status)"
  assert_sleep_log "$2"
  unset PREPULL_RETRY_AFTER_LINE PREPULL_RANDOM_VALUE PREPULL_DELAY
}
assert_retry_after_sleep_line 'Retry-After: 30' 31
assert_retry_after_sleep_line 'retry-after : 30' 31
assert_retry_after_sleep_line 'no hint here at all' 2

PREPULL_RETRY_AFTER=584.244µs PREPULL_RANDOM_VALUE=0 PREPULL_DELAY=5 \
  run_prepull 2 6 --suite foundation
[ "$prepull_status" -eq 0 ] || prepull_fail "microsecond retry hint failed"
assert_sleep_log "6
11"
unset PREPULL_RETRY_AFTER PREPULL_RANDOM_VALUE PREPULL_DELAY

PREPULL_RETRY_AFTER=45s PREPULL_RANDOM_VALUE=3 PREPULL_DELAY=5 \
  run_prepull 1 6 --suite foundation
[ "$prepull_status" -eq 0 ] || prepull_fail "long retry hint failed"
assert_sleep_log "49"
unset PREPULL_RETRY_AFTER PREPULL_RANDOM_VALUE PREPULL_DELAY

PREPULL_RETRY_AFTER=invalid PREPULL_RANDOM_VALUE=0 PREPULL_DELAY=10 \
  PREPULL_MAX_DELAY=40 run_prepull 5 6 --suite foundation
[ "$prepull_status" -eq 0 ] || prepull_fail "widened retry budget failed"
assert_sleep_log "11
21
41
41
41"
unset PREPULL_RETRY_AFTER PREPULL_RANDOM_VALUE PREPULL_DELAY PREPULL_MAX_DELAY

PREPULL_RETRY_AFTER=20s PREPULL_RANDOM_VALUE=not-a-number PREPULL_DELAY=1 \
  run_prepull 1 2 --suite foundation
[ "$prepull_status" -eq 0 ] || prepull_fail "malformed entropy failed ($prepull_status)"
fallback_sleep=$(cat "$sleep_log")
[ "$fallback_sleep" -ge 21 ] && [ "$fallback_sleep" -le 25 ] ||
  prepull_fail "entropy fallback sleep escaped its jitter range: $fallback_sleep"
unset PREPULL_RETRY_AFTER PREPULL_RANDOM_VALUE PREPULL_DELAY

PREPULL_RETRY_AFTER=invalid PREPULL_RANDOM_VALUE=0 PREPULL_DELAY=08 \
  run_prepull 1 2 --suite foundation
[ "$prepull_status" -eq 0 ] || prepull_fail "leading-zero delay failed ($prepull_status)"
assert_sleep_log 9
unset PREPULL_RETRY_AFTER PREPULL_RANDOM_VALUE PREPULL_DELAY

PREPULL_RETRY_AFTER=invalid PREPULL_RANDOM_VALUE=74 \
  PREPULL_DELAY=999999999999999999999999999999999999 \
  run_prepull 1 2 --suite foundation
[ "$prepull_status" -eq 0 ] || prepull_fail "oversized delay failed ($prepull_status)"
assert_sleep_log 375
unset PREPULL_RETRY_AFTER PREPULL_RANDOM_VALUE PREPULL_DELAY

run_prepull 7 08 --suite foundation
[ "$prepull_status" -eq 0 ] || prepull_fail "leading-zero attempt budget failed ($prepull_status)"
assert_pull_count "$runner_image" 8

run_prepull 10 999999999999999999999999999999999999 --suite foundation
[ "$prepull_status" -ne 0 ] || prepull_fail 'oversized attempt budget escaped its ceiling'
assert_pull_count "$runner_image" 10

run_prepull 5 malformed --suite foundation
[ "$prepull_status" -eq 0 ] || prepull_fail "malformed attempt budget removed the safe default"
assert_pull_count "$runner_image" 6

unset PREPULL_TOOLCHAIN

# Bindery's role reconciles a scan handoff against a running Audiobookshelf.
run_prepull 0 4 --suite bindery
[ "$prepull_status" -eq 0 ] || prepull_fail "bindery pre-pull failed ($prepull_status)"
assert_toolchain_pull_set \
  "$({ compose_images arr; compose_images downloaders;
       compose_images audiobookshelf; compose_images bindery; } | sort -u)"

run_prepull 0 4 --suite trailarr
[ "$prepull_status" -eq 0 ] || prepull_fail "trailarr pre-pull failed ($prepull_status)"
assert_toolchain_pull_set \
  "$({ compose_images arr; compose_images trailarr; } | sort -u)"

# Audiobookshelf is the foundation's second verified reader.
run_prepull 0 4 --suite seerr
[ "$prepull_status" -eq 0 ] || prepull_fail "seerr pre-pull failed ($prepull_status)"
assert_toolchain_pull_set \
  "$({ compose_images arr; compose_images audiobookshelf; compose_images jellyfin; compose_images seerr; } | sort -u)"

run_prepull 0 4 --suite kapowarr
[ "$prepull_status" -eq 0 ] || prepull_fail "kapowarr pre-pull failed ($prepull_status)"
assert_toolchain_pull_set \
  "$({ compose_images kapowarr; } | sort -u)"

run_prepull 0 4 --suite pinchflat
[ "$prepull_status" -eq 0 ] || prepull_fail "pinchflat pre-pull failed ($prepull_status)"
assert_toolchain_pull_set \
  "$({ compose_images pinchflat; } | sort -u)"

run_prepull 0 4 --suite arr
[ "$prepull_status" -eq 0 ] || prepull_fail "arr pre-pull failed ($prepull_status)"
assert_toolchain_pull_set \
  "$({ compose_images arr; } | sort -u)"

run_prepull 0 4 --suite downloaders
[ "$prepull_status" -eq 0 ] || prepull_fail "downloaders pre-pull failed ($prepull_status)"
assert_toolchain_pull_set \
  "$({ compose_images arr; compose_images downloaders; } | sort -u)"

# Over-budget refusals fail and stop further pulls. Three refusals against two
# attempts, so a retry that lost its bound would answer on the fourth and fail.
PREPULL_TOOLCHAIN=off
run_prepull 3 2 --suite beszel
[ "$prepull_status" -ne 0 ] || prepull_fail 'refusals past the budget produced a successful pre-pull'
assert_pull_count "$runner_image" 2
[ "$(wc -l < "$pull_log" | tr -d " ")" -eq 2 ] ||
  prepull_fail "the pre-pull continued past an exhausted budget: $(cat "$pull_log")"
grep -qF 'toomanyrequests: retry-after:' "$prepull_output" ||
  prepull_fail 'exhausted pre-pull did not replay the registry diagnostic'

mkdir "$interrupt_tmp"
: > "$pull_log"
: > "$sleep_log"
: > "$prepull_output"
prepull_status=0
TMPDIR=$interrupt_tmp \
  PATH="$prepull_bin:$PATH" \
  STUB_PULL_LOG=$pull_log \
  STUB_SLEEP_LOG=$sleep_log \
  STUB_PULL_REFUSALS=1 \
  STUB_RETRY_AFTER=1s \
  STUB_RANDOM_VALUE=0 \
  STUB_SLEEP_INTERRUPT=1 \
  INTEGRATION_PREPULL_ONLY=1 \
  INTEGRATION_TOOLCHAIN=off \
  INTEGRATION_IMAGE_PULL_ATTEMPTS=2 \
  INTEGRATION_IMAGE_PULL_DELAY=1 \
  INTEGRATION_IMAGE_PULL_MAX_DELAY=60 \
  "$integration" --suite foundation >"$prepull_output" 2>&1 || prepull_status=$?
[ "$prepull_status" -ne 0 ] ||
  prepull_fail 'interrupted pre-pull unexpectedly completed'
if find "$interrupt_tmp" -name 'nas-platform-pull-error.*' -print | grep -q .; then
  prepull_fail 'interrupted pre-pull leaked a pull diagnostic file'
fi
rmdir "$interrupt_tmp"

run_prepull 1 0 --suite foundation
[ "$prepull_status" -eq 0 ] ||
  prepull_fail "a zero attempt budget removed the retry instead of being floored ($prepull_status)"
assert_pull_count "$runner_image" 2

unset PREPULL_TOOLCHAIN

# The toolchain image is never a precondition: a transient refusal gets the ladder.
PREPULL_DENY_PREFIX= run_prepull 2 4 --suite foundation
[ "$prepull_status" -eq 0 ] ||
  prepull_fail "a rate-limited toolchain pull was not retried ($prepull_status)"
assert_toolchain_pull_set ""
if grep -qxF "$runner_image" "$pull_log"; then
  prepull_fail 'a retried toolchain pull still fell back to the base image'
fi
[ "$(wc -l < "$pull_log" | tr -d " ")" -eq 3 ] ||
  prepull_fail "the toolchain pull was not retried to its budget: $(cat "$pull_log")"

# A not-found is not transient: fall back to the base image at the first refusal.
PREPULL_DENY_PREFIX=$toolchain_prefix run_prepull 0 4 --suite foundation
[ "$prepull_status" -eq 0 ] ||
  prepull_fail "an unpublished toolchain failed the pre-pull ($prepull_status)"
grep -qxF "$runner_image" "$pull_log" ||
  prepull_fail 'an unpublished toolchain did not fall back to the base image'
assert_pull_count "$runner_image" 1
[ "$(grep -c "^$toolchain_prefix:" "$pull_log")" -eq 1 ] ||
  prepull_fail "a plain denial was retried: $(cat "$pull_log")"
assert_sleep_log ""
grep -qF 'no controller toolchain at' "$prepull_output" ||
  prepull_fail "the fallback to the base image was not reported: $(cat "$prepull_output")"

unset PREPULL_DENY_PREFIX

# A locally built toolchain has no repo digest, so fall back to the digest-pinned
# base image.
PREPULL_NO_REPO_DIGEST=true run_prepull 0 4 --suite foundation
[ "$prepull_status" -eq 0 ] ||
  prepull_fail "a locally built toolchain failed the pre-pull ($prepull_status)"
grep -qxF "$runner_image" "$pull_log" ||
  prepull_fail 'a toolchain without a registry digest left the collision fixture unpinned'
unset PREPULL_NO_REPO_DIGEST

# INTEGRATION_TOOLCHAIN=off must reproduce the pre-toolchain behaviour exactly.
PREPULL_TOOLCHAIN=off run_prepull 0 4 --suite beszel
[ "$prepull_status" -eq 0 ] ||
  prepull_fail "the disabled toolchain failed the pre-pull ($prepull_status)"
assert_pull_set \
  "$({ printf '%s\n' "$runner_image"; compose_images beszel; } | sort -u)"

# Counterexample: the stub must be able to fail a pre-pull, or the above is vacuous.
run_prepull 3 2 --suite foundation
[ "$prepull_status" -ne 0 ] || prepull_fail 'the stub registry cannot refuse'
unset PREPULL_TOOLCHAIN

printf 'integration suite dispatch and image pre-pull tests passed\n'
