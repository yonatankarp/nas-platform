#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd -P)
integration=$repo_dir/tests/integration.sh
fake_bin=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-suite-test.XXXXXX")
fake_bin=$(CDPATH= cd -P "$fake_bin" && pwd -P)
docker_log=$fake_bin/docker.log
prepull_bin=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-prepull-test.XXXXXX")
pull_log=$prepull_bin/pull.log
sleep_log=$prepull_bin/sleep.log
prepull_output=$prepull_bin/prepull.output
interrupt_tmp=$prepull_bin/interrupt-tmp
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
    "$pull_log" "$sleep_log" "$prepull_output"
  if [ -d "$interrupt_tmp" ]; then
    find "$interrupt_tmp" -depth -mindepth 1 -delete 2>/dev/null || true
    rmdir "$interrupt_tmp" 2>/dev/null || true
  fi
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
  'foundation arr downloaders bindery kapowarr pinchflat trailarr seerr smoke beszel dozzle audiobookshelf komga jellyfin immich paperless idempotence-check full' \
  --list-suites

for suite_name in foundation arr downloaders bindery kapowarr pinchflat trailarr seerr smoke beszel dozzle audiobookshelf komga jellyfin immich paperless idempotence-check full; do
  assert_lifecycle 'converge
success' "$suite_name"
done

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
  'suite=arr tags=host_prep,deployment_bundle,ntfy,arr playbook=site.yml scenarios=true' \
  --describe-suite arr
assert_output \
  'suite=downloaders tags=host_prep,deployment_bundle,ntfy,arr,downloaders playbook=site.yml scenarios=true' \
  --describe-suite downloaders
for project in bindery kapowarr pinchflat trailarr seerr; do
  assert_output \
    "suite=$project tags=host_prep,deployment_bundle,media_acquisition_foundation playbook=site.yml scenarios=true" \
    --describe-suite "$project"
done
grep -qF 'bindery|kapowarr|pinchflat|trailarr|seerr)' "$integration" || {
  printf '%s\n' 'integration runner has no closed acquisition foundation dispatch' >&2
  exit 1
}
grep -qF '/repo/tests/contracts/"\$INTEGRATION_SUITE"-foundation.sh static' "$integration" || {
  printf '%s\n' 'acquisition foundation suites do not run their matching static contract' >&2
  exit 1
}
acquisition_runtime_contract_holds() {
  source_path=$1
  reader_converge=$(sed -n '/converge_media_acquisition_reader_prerequisites() {/,/^    }$/p' "$source_path")
  foundation_verify=$(sed -n '/run_media_acquisition_foundation_verify() {/,/^    }$/p' "$source_path")
  acquisition_dispatch=$(sed -n '/bindery|kapowarr|pinchflat|trailarr|seerr)/,/;;/p' "$source_path" | tail -n 12)
  printf '%s\n' "$reader_converge" |
    grep -qF -- '--tags host_prep,deployment_bundle,ntfy,audiobookshelf,jellyfin' &&
    printf '%s\n' "$foundation_verify" | grep -qF '/repo/verify.yml' &&
    printf '%s\n' "$foundation_verify" |
      grep -qF -- '--tags platform_verify_media_acquisition_foundation' &&
    ! printf '%s\n' "$foundation_verify" |
      grep -Eq -- '-e (platform_media_control_network|media_usenet_enabled|media_torrent_enabled)=' &&
    printf '%s\n' "$acquisition_dispatch" |
      grep -qF 'converge_media_acquisition_reader_prerequisites' &&
    printf '%s\n' "$acquisition_dispatch" |
      grep -qF 'run_media_acquisition_foundation_verify'
}
acquisition_runtime_contract_holds "$integration" || {
  printf '%s\n' 'acquisition suites omit the shared inventory-derived Linux runtime verifier path' >&2
  exit 1
}
sed '/run_media_acquisition_foundation_verify$/d' "$integration" > "$acquisition_runtime_mutant"
if acquisition_runtime_contract_holds "$acquisition_runtime_mutant"; then
  printf '%s\n' 'acquisition runtime contract accepts removal of real verifier execution' >&2
  exit 1
fi
assert_output 'suite=beszel tags=host_prep,deployment_bundle,ntfy,beszel playbook=site.yml scenarios=true' \
  --describe-suite beszel
assert_output 'suite=dozzle tags=host_prep,deployment_bundle,ntfy,dozzle playbook=site.yml scenarios=true' \
  --describe-suite dozzle
assert_output 'suite=audiobookshelf tags=host_prep,deployment_bundle,ntfy,audiobookshelf playbook=site.yml scenarios=true' \
  --describe-suite audiobookshelf
assert_output 'suite=komga tags=host_prep,deployment_bundle,ntfy,komga playbook=site.yml scenarios=true' \
  --describe-suite komga
assert_output 'suite=jellyfin tags=host_prep,deployment_bundle,ntfy,jellyfin playbook=site.yml scenarios=true' \
  --describe-suite jellyfin
assert_output 'suite=immich tags=host_prep,deployment_bundle,ntfy,immich playbook=site.yml scenarios=true' \
  --describe-suite immich
assert_output 'suite=paperless tags=host_prep,deployment_bundle,ntfy,paperless playbook=site.yml scenarios=true' \
  --describe-suite paperless
assert_output 'suite=full tags= playbook=site.yml scenarios=true' --describe-suite full

assert_output 'suite=smoke tags=host_prep,deployment_bundle,ntfy,beszel playbook=custom.yml scenarios=true' \
  --describe-suite smoke --tags host_prep,deployment_bundle,ntfy,beszel custom.yml
assert_output 'suite=smoke tags= playbook=site.yml scenarios=true' \
  --describe-suite smoke --tags ''
assert_output 'suite=idempotence-check tags=host_prep,deployment_bundle,ntfy playbook=site.yml scenarios=true' \
  --describe-suite idempotence-check --tags host_prep,deployment_bundle,ntfy
assert_output 'suite=idempotence-check tags= playbook=site.yml scenarios=true' \
  --describe-suite idempotence-check

# The same parser identifies legacy playbook-first invocations as full without
# touching Docker. Extra Ansible arguments remain available to the runner.
actual=$(PATH="$fake_bin:$PATH" DOCKER_LOG=$docker_log \
  INTEGRATION_DESCRIBE_ONLY=1 "$integration")
[ "$actual" = 'suite=full tags= playbook=site.yml scenarios=true' ]
actual=$(PATH="$fake_bin:$PATH" DOCKER_LOG=$docker_log \
  INTEGRATION_DESCRIBE_ONLY=1 "$integration" custom.yml --check --diff)
[ "$actual" = 'suite=full tags= playbook=custom.yml scenarios=false' ]
actual=$(PATH="$fake_bin:$PATH" DOCKER_LOG=$docker_log \
  INTEGRATION_DESCRIBE_ONLY=1 "$integration" --suite dozzle)
[ "$actual" = 'suite=dozzle tags=host_prep,deployment_bundle,ntfy,dozzle playbook=site.yml scenarios=true' ]

# Dispatch crosses the Docker boundary as quoted argv/environment rather than
# being interpolated into the runner program.
grep -qF -- '-e INTEGRATION_SUITE="$suite"' "$integration"
grep -qF -- '-e INTEGRATION_TAGS="$suite_tags"' "$integration"
grep -qF 'chmod 0700 "$sandbox"' "$integration" || {
  printf '%s\n' 'integration sandbox is not owner-only' >&2
  exit 1
}
grep -qF -- '" integration-run "$playbook" "$@"' "$integration"
grep -qF -- '\"\$playbook\" \"\$@\"' "$integration"
grep -qF -- 'run_play --tags \"\$INTEGRATION_TAGS\" \"\$@\"' "$integration"
grep -qF -- 'run_play \"\$@\"' "$integration"

# The controller and every acquisition resource share one strict namespace
# derived from the disposable directory. Exercise the production derivation so
# case normalization and exact-length rejection cannot drift from the harness.
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
run_play_namespace=$(sed -n '/^    run_play() {/,/^    }$/p' "$integration")
for scoped_project_variable in \
  arr_platform_project_name downloaders_platform_project_name; do
  printf '%s\n' "$run_play_namespace" |
    grep -qF -- \
      "-e $scoped_project_variable=\\\"\$integration_project_namespace\\\"" || {
    printf 'integration plays omit scoped namespace %s\n' \
      "$scoped_project_variable" >&2
    exit 1
  }
done
# Every pre-existing service derives its Compose project from the platform
# namespace, so the disposable lane must set it: a stack deployed under its
# production project is not owned by sandbox cleanup and survives the run.
printf '%s\n' "$run_play_namespace" |
  grep -qF -- '-e platform_project_name=\"$integration_project_namespace\"' || {
  printf '%s\n' 'integration plays do not deploy under the disposable namespace' >&2
  exit 1
}
if grep -n -- '-e platform_project_name=' "$integration" |
   grep -vF -- '-e platform_project_name=\"$integration_project_namespace\"' |
   grep -vF -- '-e platform_project_name=$integration_project_namespace-negative' \
     >/dev/null; then
  printf '%s\n' 'integration plays use a project name the sandbox does not derive' >&2
  exit 1
fi

# Enabled acquisition suites must prove idempotence with a second normal play,
# not infer it from check mode. Exercise the production recap parser directly so
# task output cannot satisfy the gate and malformed or partial recaps fail closed.
sed -n '/^    enabled_idempotence_recap_is_clean() {/,/^    }$/p' \
  "$integration" | ruby -e '
    # Reproduce what the controller receives, rather than merely unescaping.
    # The helper lives inside a double-quoted string, so the shell removes an
    # unescaped quote instead of passing it through: extracting with a plain
    # unescape rebuilt a correct function from broken source and hid an awk
    # syntax error that only appeared when a suite actually ran.
    source = STDIN.read
    out = +""
    index = 0
    while index < source.length
      character = source[index]
      if character == "\\" && index + 1 < source.length &&
         ["$", "`", "\"", "\\"].include?(source[index + 1])
        out << source[index + 1]
        index += 2
        next
      end
      if character == "\""
        index += 1
        next
      end
      out << character
      index += 1
    end
    print out
  ' > "$idempotence_helper"
[ -s "$idempotence_helper" ] || {
  printf '%s\n' 'integration runner has no enabled idempotence recap parser' >&2
  exit 1
}
. "$idempotence_helper"

enabled_idempotence_runner=$(sed -n \
  '/^    run_enabled_idempotence() {/,/^    }$/p' "$integration")
printf '%s\n' "$enabled_idempotence_runner" |
  grep -qF 'run_play --tags "\$idempotence_tags"' || {
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

arr_enabled_block=$(sed -n '/if \[ "\\\$INTEGRATION_SUITE" = arr \]; then/,/^    fi$/p' \
  "$integration")
downloaders_enabled_block=$(sed -n \
  '/if \[ "\\\$INTEGRATION_SUITE" = downloaders \]; then/,/^    fi$/p' \
  "$integration")
printf '%s\n' "$arr_enabled_block" | grep -qF 'run_enabled_idempotence arr'
printf '%s\n' "$downloaders_enabled_block" |
  grep -qF 'run_enabled_idempotence arr,downloaders'
arr_idempotence_line=$(printf '%s\n' "$arr_enabled_block" |
  grep -nF 'run_enabled_idempotence arr' | cut -d: -f1)
arr_check_line=$(printf '%s\n' "$arr_enabled_block" |
  grep -nF 'run_play --tags arr --check --diff' | cut -d: -f1)
downloaders_idempotence_line=$(printf '%s\n' "$downloaders_enabled_block" |
  grep -nF 'run_enabled_idempotence arr,downloaders' | cut -d: -f1)
downloaders_check_line=$(printf '%s\n' "$downloaders_enabled_block" |
  grep -nF 'run_play --tags arr,downloaders --check --diff' | cut -d: -f1)
[ "$arr_idempotence_line" -lt "$arr_check_line" ] || {
  printf '%s\n' 'Arr enabled idempotence play does not precede check mode' >&2
  exit 1
}
[ "$downloaders_idempotence_line" -lt "$downloaders_check_line" ] || {
  printf '%s\n' 'downloaders enabled idempotence play does not precede check mode' >&2
  exit 1
}
grep -qF 'requests_version=2.34.2' "$integration" || {
  printf '%s\n' 'integration controller does not pin docker_container_info runtime support' >&2
  exit 1
}
grep -qF "'requests==\$requests_version'" "$integration" || {
  printf '%s\n' 'integration controller does not install docker_container_info runtime support' >&2
  exit 1
}

# Service fixtures consumed through nested Docker bind mounts must exist on the
# daemon host before the controller container establishes its sandbox mount.
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
grep -qF 'pinchflat:true|trailarr:true|seerr:true|full:true)' "$integration"
grep -qF -- '-e PLATFORM_KOMGA_FIXTURE_PRESEEDED="$komga_fixture_preseeded"' "$integration"
grep -qF -- '-e PLATFORM_JELLYFIN_FIXTURE_PRESEEDED="$jellyfin_fixture_preseeded"' \
  "$integration"

immich_negative_order_holds() {
  source_path=$1
  function_body=$(sed -n '/run_immich_restore_negative_matrix() {/,/^    }$/p' "$source_path")
  host_prep_line=$(printf '%s\n' "$function_body" |
    grep -nF -- '--tags host_prep,deployment_bundle' | head -1 | cut -d: -f1)
  scenario_loop_line=$(printf '%s\n' "$function_body" |
    grep -nF 'for scenario in no-backup corrupt-newest ambiguous-newest unsafe-permissions prior-marker' |
    head -1 | cut -d: -f1)
  [ -n "$host_prep_line" ] && [ -n "$scenario_loop_line" ] &&
    [ "$host_prep_line" -lt "$scenario_loop_line" ]
}
immich_negative_order_holds "$integration" || {
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
' "$integration" "$immich_order_mutant"
if immich_negative_order_holds "$immich_order_mutant"; then
  printf '%s\n' 'Immich negative-matrix order guard accepts the loop-before-host-prep mutant' >&2
  exit 1
fi

for suite in komga jellyfin immich; do
  grep -qF "suite_is $suite" "$integration" || {
    printf '%s\n' "$suite has no independent scenario dispatch" >&2
    exit 1
  }
done
jellyfin_scenarios=$(sed -n '/suite_is jellyfin/,/^    fi$/p' "$integration")
printf '%s\n' "$jellyfin_scenarios" | grep -qF 'run_jellyfin_contract seed'
printf '%s\n' "$jellyfin_scenarios" | grep -qF 'run_jellyfin_contract run'
# The committed deployment vault is intentionally encrypted with an operator
# password unavailable to CI. Every suite must use an isolated controller copy,
# replace only that copy with its generated ephemeral vault, and export the
# matching password before any Ansible invocation.
grep -qF -- 'controller_mount=$sandbox/repo' "$integration"
grep -qF -- 'install -m 0600 \"\$vault_file\" /repo/inventory/group_vars/all/vault.yml' "$integration"
grep -qF -- 'export ANSIBLE_VAULT_PASSWORD_FILE=\"\$vault_password_file\"' "$integration"
grep -qF -- '-e @\"\$fixture_vars_file\"' "$integration" || {
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
assert_rejected 'unknown integration suite: <missing>' --suite --tags ntfy
assert_rejected 'unknown integration suite: <missing>' --describe-suite
assert_rejected 'missing value for --tags' --suite smoke --tags
assert_rejected 'invalid integration tags: Bad' --suite smoke --tags Bad
assert_rejected 'invalid integration tags: ntfy,,beszel' \
  --suite smoke --tags ntfy,,beszel
for suite in foundation arr downloaders bindery kapowarr pinchflat trailarr seerr beszel dozzle audiobookshelf komga jellyfin immich paperless full; do
  assert_rejected "integration suite $suite does not accept --tags" \
    --suite "$suite" --tags ntfy
done
assert_rejected 'integration suite foundation does not accept --tags' \
  --suite foundation custom.yml --tags ntfy
assert_rejected 'integration suite options must precede the playbook' \
  --suite smoke custom.yml --tags 'Bad;touch'
assert_rejected 'integration suite options must precede the playbook' \
  --suite smoke custom.yml --tags=ntfy
assert_rejected 'unexpected integration suite argument: --check' \
  --suite smoke custom.yml --check

[ ! -e "$docker_log" ] || {
  printf 'dispatch inspection reached Docker: %s\n' "$(cat "$docker_log")" >&2
  exit 1
}

# Image pre-pull and its retry.
#
# The plays pull digest-pinned images through community.docker.docker_compose_v2,
# which reports a registry refusal as a module failure that aborts the converge:
# PR #84's smoke and idempotence-check legs died that way on
# "toomanyrequests: retry-after: 218.093us, allowed: 44000/minute" and passed on a
# re-run of the same commits. The harness therefore pulls the images itself first,
# with a bounded retry, and once a digest-pinned layer set is local the play's own
# `docker compose up` reaches no registry at all.
#
# That retry is proven here by driving the real script against a stub docker whose
# registry refuses a chosen number of times per image. Pull-only mode needs no
# sandbox, so each case costs about a second.

prepull_fail() {
  printf 'prepull: %s\n' "$1" >&2
  exit 1
}

cat > "$prepull_bin/docker" <<'EOF'
#!/bin/sh
set -eu
if [ "${1:-}" = pull ]; then
  printf '%s\n' "$2" >> "${STUB_PULL_LOG:?}"
  attempt=$(grep -Fxc -- "$2" "$STUB_PULL_LOG" || true)
  if [ "$attempt" -le "${STUB_PULL_REFUSALS:-0}" ]; then
    printf 'toomanyrequests: retry-after: %s, allowed: 44000/minute\n' \
      "${STUB_RETRY_AFTER:-218.093us}" >&2
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
grep -qF 'MEDIA_CONTROL_COLLISION_IMAGE="$runner_image"' "$integration" ||
  prepull_fail 'the owning integration lane does not pass its pre-pulled controller image'
grep -qF '/repo/tests/media_control_network_collision_test.sh live' "$integration" ||
  prepull_fail 'the owning integration lane does not execute the live collision test'

compose_images() {
  sed -n 's/^[[:space:]]*image:[[:space:]]*//p' "$repo_dir/services/$1/compose.yml"
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
    STUB_RANDOM_VALUE=${PREPULL_RANDOM_VALUE:-0} \
    INTEGRATION_PREPULL_ONLY=1 \
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

assert_retry_after_sleep() {
  retry_after_case=$1
  expected_sleep=$2
  PREPULL_RETRY_AFTER=$retry_after_case PREPULL_RANDOM_VALUE=0 PREPULL_DELAY=1 \
    run_prepull 1 2 --suite foundation
  [ "$prepull_status" -eq 0 ] ||
    prepull_fail "retry-after $retry_after_case failed the pre-pull ($prepull_status)"
  assert_sleep_log "$expected_sleep"
}

# A suite pulls the controller image plus the images of the services its tags
# converge, and nothing else. Pulling the whole tree for a one-service suite would
# cost gigabytes of runner disk for images the run never starts.
run_prepull 0 4 --suite beszel
[ "$prepull_status" -eq 0 ] || prepull_fail "an answering registry failed the pre-pull ($prepull_status)"
assert_pull_set "$({ printf '%s\n' "$runner_image"; compose_images ntfy; compose_images beszel; } | sort -u)"
if grep -q 'immich' "$pull_log"; then
  prepull_fail 'the beszel suite pulled images it never converges'
fi

# The paperless suite is the one whose tag and service directory differ, so it is
# the case that proves the map rather than the naming coincidence.
run_prepull 0 4 --suite paperless
[ "$prepull_status" -eq 0 ] || prepull_fail "the paperless pre-pull failed ($prepull_status)"
assert_pull_set \
  "$({ printf '%s\n' "$runner_image"; compose_images ntfy; compose_images paperless-ngx; } | sort -u)"

# An untagged smoke run converges everything, so every service directory in the
# tree must be reachable from the harness map. A directory the map forgot shows up
# here as a missing pull.
run_prepull 0 4 --suite smoke
[ "$prepull_status" -eq 0 ] || prepull_fail "the untagged smoke pre-pull failed ($prepull_status)"
all_service_images=$(printf '%s\n' "$runner_image"
                     for compose in "$repo_dir"/services/*/compose.yml; do
                       sed -n 's/^[[:space:]]*image:[[:space:]]*//p' "$compose"
                     done)
assert_pull_set "$(printf '%s\n' "$all_service_images" | sort -u)"

# CI narrows smoke to the changed service, and the pre-pull has to narrow with it.
run_prepull 0 4 --suite smoke --tags host_prep,deployment_bundle,ntfy,immich
[ "$prepull_status" -eq 0 ] || prepull_fail "the tagged smoke pre-pull failed ($prepull_status)"
assert_pull_set "$({ printf '%s\n' "$runner_image"; compose_images ntfy; compose_images immich; } | sort -u)"

# A registry that refuses twice and then answers must still produce a successful
# pre-pull, with the pull retried rather than the suite failed. foundation
# converges no service, so this costs one image and two backoffs.
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
assert_retry_after_sleep 1.5m 91
assert_retry_after_sleep 45 46
assert_retry_after_sleep invalid 2
assert_retry_after_sleep 999999999999999999999999999999999999s 301

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

for project in bindery kapowarr pinchflat trailarr seerr; do
  run_prepull 0 4 --suite "$project"
  [ "$prepull_status" -eq 0 ] || prepull_fail "$project foundation pre-pull failed ($prepull_status)"
  assert_pull_set \
    "$({ printf '%s\n' "$runner_image"; compose_images ntfy; compose_images audiobookshelf; compose_images jellyfin; } | sort -u)"
done

run_prepull 0 4 --suite arr
[ "$prepull_status" -eq 0 ] || prepull_fail "arr pre-pull failed ($prepull_status)"
assert_pull_set \
  "$({ printf '%s\n' "$runner_image"; compose_images ntfy; compose_images arr; } | sort -u)"

run_prepull 0 4 --suite downloaders
[ "$prepull_status" -eq 0 ] || prepull_fail "downloaders pre-pull failed ($prepull_status)"
assert_pull_set \
  "$({ printf '%s\n' "$runner_image"; compose_images ntfy; compose_images arr; compose_images downloaders; } | sort -u)"

# A registry that refuses more times than the budget allows must fail, and must
# not go on pulling the rest: under a rate limit the remaining pulls would only
# extend the outage, and the diagnosis belongs at the first refusal.
#
# Three refusals against a two-attempt budget rather than a registry that never
# answers, deliberately: a retry that lost its bound would answer on the fourth
# attempt and fail this assertion, where against a permanent refusal it would
# instead spin until the job timeout and prove nothing.
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

# The retry cannot be configured away: a zero budget is floored, so one refusal is
# still survived.
run_prepull 1 0 --suite foundation
[ "$prepull_status" -eq 0 ] ||
  prepull_fail "a zero attempt budget removed the retry instead of being floored ($prepull_status)"
assert_pull_count "$runner_image" 2

# Counterexample: the stub must be able to fail a pre-pull at all, otherwise every
# assertion above is vacuous.
run_prepull 3 2 --suite foundation
[ "$prepull_status" -ne 0 ] || prepull_fail 'the stub registry cannot refuse'

printf 'integration suite dispatch and image pre-pull tests passed\n'
