#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd -P)
integration=$repo_dir/tests/integration.sh
fake_bin=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-suite-test.XXXXXX")
fake_bin=$(CDPATH= cd -P "$fake_bin" && pwd -P)
docker_log=$fake_bin/docker.log
prepull_bin=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-prepull-test.XXXXXX")
pull_log=$prepull_bin/pull.log

cleanup() {
  for case_root in "$fake_bin/contract-cases" "$fake_bin/boundary-cases" \
      "$fake_bin/hostile-repository" "$fake_bin/playbook-sandbox" \
      "$fake_bin/check-mode-sandbox"; do
    if [ -d "$case_root" ] && [ ! -L "$case_root" ]; then
      find "$case_root" -depth -mindepth 1 -delete 2>/dev/null || true
      rmdir "$case_root" 2>/dev/null || true
    fi
  done
  rm -f "$fake_bin/contract-docker/tinymediamanager/data/retirement-contract.txt" \
    "$fake_bin/contract-docker/tinymediamanager/data/.nas-platform-retirement-sentinel" \
    "$fake_bin/contract-docker/tinymediamanager/data/data/tmm.json" \
    "$fake_bin/contract-report/tinymediamanager-retirement.sha256" \
    "$fake_bin/contract-report/tinymediamanager-retirement.env"
  rmdir "$fake_bin/contract-docker/tinymediamanager/data/data" \
    "$fake_bin/contract-docker/tinymediamanager/data" \
    "$fake_bin/contract-docker/tinymediamanager" "$fake_bin/contract-docker" \
    "$fake_bin/contract-media/Media/Movies" "$fake_bin/contract-media/Media/Series" \
    "$fake_bin/contract-media/Media" "$fake_bin/contract-media" \
    "$fake_bin/contract-report" 2>/dev/null || true
  rm -f "$fake_bin/docker" "$fake_bin/mktemp" "$docker_log"
  rm -f "$fake_bin/hostile-validator-ran"
  rmdir "$fake_bin"
  rm -f "$prepull_bin/docker" "$pull_log"
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
  printf '%s\n' converge success assert-retired
}

assert_lifecycle_consumer_rejected 'success followed by producer failure' \
  produce_success_then_fail
assert_lifecycle_consumer_rejected 'success before converge' \
  produce_success_before_converge
assert_lifecycle_consumer_rejected 'duplicate success' produce_duplicate_success
assert_lifecycle_consumer_rejected 'known event after success' produce_event_after_success
[ "$(consume_integration_lifecycle_plan printf '%s\n' converge success)" = \
  'converge
success' ]
[ "$(consume_integration_lifecycle_plan printf '%s\n' \
  seed-retirement-fixture start-retirement-fixture converge assert-retired success)" = \
  'seed-retirement-fixture
start-retirement-fixture
converge
assert-retired
success' ]
consumed_controller_plan=$(INTEGRATION_RUN_SERVICE_SCENARIOS=false \
  run_integration --consume-lifecycle --suite full)
[ "$consumed_controller_plan" = 'seed-retirement-fixture
converge
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
  'foundation smoke beszel dozzle audiobookshelf komga tinymediamanager jellyfin immich paperless idempotence-check full' \
  --list-suites

retirement_lifecycle='seed-retirement-fixture
start-retirement-fixture
converge
assert-retired
success'
assert_lifecycle "$retirement_lifecycle" tinymediamanager
assert_lifecycle "$retirement_lifecycle" full
assert_lifecycle 'converge
success' foundation
for preservation_suite in smoke beszel jellyfin; do
  assert_lifecycle 'seed-retirement-fixture
converge
success' "$preservation_suite"
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
[ "$host_plan" = 'seed-retirement-fixture
converge
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

contract_docker_root=$fake_bin/contract-docker
contract_media_root=$fake_bin/contract-media
contract_report_root=$fake_bin/contract-report
mkdir -p "$contract_docker_root" "$contract_media_root/Media/Movies" \
  "$contract_media_root/Media/Series" "$contract_report_root"

assert_retirement_seed_refused() {
  boundary_name=$1
  boundary_kind=$2
  boundary_sandbox=$3
  boundary_docker=$4
  boundary_media=$5
  boundary_report=$6
  boundary_owner_uid=${7:-$(id -u)}
  boundary_status=0
  (
    if [ "$boundary_kind" = __unset__ ]; then
      unset PLATFORM_KIND
    else
      export PLATFORM_KIND=$boundary_kind
    fi
    if [ "$boundary_sandbox" = __unset__ ]; then
      unset PLATFORM_CONTRACT_SANDBOX_ROOT
    else
      export PLATFORM_CONTRACT_SANDBOX_ROOT=$boundary_sandbox
    fi
    export PLATFORM_CONTRACT_REPO_DIR=$repo_dir
    export PLATFORM_CONTRACT_SANDBOX_OWNER_UID=$boundary_owner_uid
    export PLATFORM_DOCKER_ROOT=$boundary_docker
    export PLATFORM_MEDIA_ROOT=$boundary_media
    export PLATFORM_REPORT_ROOT=$boundary_report
    export PLATFORM_COMPOSE_KIND=integration PLATFORM_PROJECT_NAME=integration
    export PLATFORM_TINYMEDIAMANAGER_WEB_PORT=4000
    export PLATFORM_TINYMEDIAMANAGER_API_PORT=7878
    exec "$repo_dir/tests/contracts/tinymediamanager.sh" seed-retirement-fixture
  ) >/dev/null 2>&1 || boundary_status=$?
  [ "$boundary_status" -ne 0 ] || {
    printf 'retirement fixture boundary accepted %s\n' "$boundary_name" >&2
    exit 1
  }
  [ ! -e "$boundary_docker/tinymediamanager" ] &&
    [ -z "$(find "$boundary_report" -mindepth 1 -print -quit)" ] || {
      printf 'retirement fixture boundary mutated %s before refusal\n' \
        "$boundary_name" >&2
      exit 1
    }
}

boundary_cases=$fake_bin/boundary-cases
mkdir -p "$boundary_cases"
for boundary_name in nas-kind absent-kind unknown-kind missing-sandbox; do
  boundary_root=$boundary_cases/$boundary_name
  mkdir -p "$boundary_root/docker" "$boundary_root/media" "$boundary_root/report"
  chmod 0700 "$boundary_root"
  case $boundary_name in
    nas-kind) boundary_kind=nas; boundary_sandbox=$boundary_root ;;
    absent-kind) boundary_kind=__unset__; boundary_sandbox=$boundary_root ;;
    unknown-kind) boundary_kind=operator; boundary_sandbox=$boundary_root ;;
    missing-sandbox) boundary_kind=test; boundary_sandbox=__unset__ ;;
  esac
  assert_retirement_seed_refused "$boundary_name" "$boundary_kind" \
    "$boundary_sandbox" "$boundary_root/docker" "$boundary_root/media" \
    "$boundary_root/report"
done

outside_case=$boundary_cases/outside-root
outside_target=$boundary_cases/outside-target
mkdir -p "$outside_case/media" "$outside_case/report" "$outside_target/docker"
chmod 0700 "$outside_case"
assert_retirement_seed_refused out-of-sandbox-root test "$outside_case" \
  "$outside_target/docker" "$outside_case/media" "$outside_case/report"

symlink_case=$boundary_cases/symlink-component
symlink_target=$boundary_cases/symlink-target
mkdir -p "$symlink_case/media" "$symlink_case/report" "$symlink_target/docker"
chmod 0700 "$symlink_case"
ln -s "$symlink_target" "$symlink_case/linked"
assert_retirement_seed_refused symlinked-component integration "$symlink_case" \
  "$symlink_case/linked/docker" "$symlink_case/media" "$symlink_case/report"

mismatch_case=$boundary_cases/mismatched-roots
mismatch_other=$boundary_cases/mismatched-other
mkdir -p "$mismatch_case/docker" "$mismatch_case/report" "$mismatch_other/media"
chmod 0700 "$mismatch_case"
assert_retirement_seed_refused mismatched-roots mac "$mismatch_case" \
  "$mismatch_case/docker" "$mismatch_other/media" "$mismatch_case/report"

wrong_mode_case=$boundary_cases/wrong-mode-sandbox
mkdir -p "$wrong_mode_case/docker" "$wrong_mode_case/media" "$wrong_mode_case/report"
chmod 0777 "$wrong_mode_case"
assert_retirement_seed_refused wrong-sandbox-mode test "$wrong_mode_case" \
  "$wrong_mode_case/docker" "$wrong_mode_case/media" "$wrong_mode_case/report"

wrong_owner_case=$boundary_cases/wrong-owner-sandbox
mkdir -p "$wrong_owner_case/docker" "$wrong_owner_case/media" "$wrong_owner_case/report"
chmod 0700 "$wrong_owner_case"
wrong_owner_uid=$(($(id -u) + 1))
assert_retirement_seed_refused wrong-sandbox-owner test "$wrong_owner_case" \
  "$wrong_owner_case/docker" "$wrong_owner_case/media" "$wrong_owner_case/report" \
  "$wrong_owner_uid"

env \
  PLATFORM_CONTRACT_REPO_DIR="$repo_dir" \
  PLATFORM_KIND=test \
  PLATFORM_CONTRACT_SANDBOX_ROOT="$fake_bin" \
  PLATFORM_CONTRACT_SANDBOX_OWNER_UID="$(id -u)" \
  PLATFORM_DOCKER_ROOT="$contract_docker_root" \
  PLATFORM_MEDIA_ROOT="$contract_media_root" \
  PLATFORM_REPORT_ROOT="$contract_report_root" \
  PLATFORM_COMPOSE_KIND=integration \
  PLATFORM_PROJECT_NAME=integration \
  PLATFORM_TINYMEDIAMANAGER_WEB_PORT=4000 \
  PLATFORM_TINYMEDIAMANAGER_API_PORT=7878 \
  "$repo_dir/tests/contracts/tinymediamanager.sh" seed-retirement-fixture >/dev/null

sentinel=$contract_docker_root/tinymediamanager/data/retirement-contract.txt
digest=$contract_report_root/tinymediamanager-retirement.sha256
retirement_env=$contract_report_root/tinymediamanager-retirement.env
fixture_settings=$contract_docker_root/tinymediamanager/data/data/tmm.json
[ "$(cat "$sentinel")" = 'tinyMediaManager retirement state preserved' ]
[ "$(cat "$digest")" = "$(printf '%s\n' \
  'tinyMediaManager retirement state preserved' | shasum -a 256 | awk '{print $1}')" ]
expected_retirement_env="TZ=UTC
PLATFORM_CONTAINER_CPUSET=0
USER_ID=1000
GROUP_ID=100
TINYMEDIAMANAGER_PASSWORD=retirement-fixture-only
TINYMEDIAMANAGER_DATA_PATH=$contract_docker_root/tinymediamanager/data
TINYMEDIAMANAGER_MOVIES_PATH=$contract_media_root/Media/Movies
TINYMEDIAMANAGER_SERIES_PATH=$contract_media_root/Media/Series
TINYMEDIAMANAGER_WEB_HOST_PORT=4000
TINYMEDIAMANAGER_API_HOST_PORT=7878
PLATFORM_PROJECT_NAME=integration"
[ "$(cat "$retirement_env")" = "$expected_retirement_env" ]
[ "$(cat "$fixture_settings")" = \
  '{"enableHttpServer":true,"httpServerPort":7878,"httpApiKey":"retirement-fixture-only"}' ]
for protected_file in "$sentinel" "$digest" "$retirement_env" "$fixture_settings"; do
  case $(uname -s) in
    Darwin) protected_mode=$(stat -f '%Lp' "$protected_file") ;;
    *) protected_mode=$(stat -c '%a' "$protected_file") ;;
  esac
  [ "$protected_mode" = 600 ] || {
    printf 'retirement fixture file mode differs: %s is %s\n' \
      "$protected_file" "$protected_mode" >&2
    exit 1
  }
done
env \
  PLATFORM_CONTRACT_REPO_DIR="$repo_dir" \
  PLATFORM_KIND=test \
  PLATFORM_CONTRACT_SANDBOX_ROOT="$fake_bin" \
  PLATFORM_CONTRACT_SANDBOX_OWNER_UID="$(id -u)" \
  PLATFORM_DOCKER_ROOT="$contract_docker_root" \
  PLATFORM_MEDIA_ROOT="$contract_media_root" \
  PLATFORM_REPORT_ROOT="$contract_report_root" \
  PLATFORM_COMPOSE_KIND=integration \
  PLATFORM_PROJECT_NAME=integration \
  PLATFORM_TINYMEDIAMANAGER_WEB_PORT=4000 \
  PLATFORM_TINYMEDIAMANAGER_API_PORT=7878 \
  "$repo_dir/tests/contracts/tinymediamanager.sh" seed-retirement-fixture >/dev/null
DOCKER_LOG=$docker_log FAKE_DOCKER_ASSERT_ABSENT=true PATH="$fake_bin:$PATH" \
  PLATFORM_CONTRACT_REPO_DIR="$repo_dir" \
  PLATFORM_DOCKER_ROOT="$contract_docker_root" \
  PLATFORM_REPORT_ROOT="$contract_report_root" \
  PLATFORM_TINYMEDIAMANAGER_CONTAINER=tinymediamanager \
  "$repo_dir/tests/contracts/tinymediamanager.sh" assert-retired >/dev/null
rm -f "$docker_log"

contract_cases=$fake_bin/contract-cases
safe_case=$contract_cases/safe
mkdir -p "$safe_case/docker/tinymediamanager/data/data" \
  "$safe_case/media/Media/Movies" "$safe_case/media/Media/Series" "$safe_case/reports"
chmod 0700 "$safe_case"
printf '%s\n' 'opaque-existing-state-that-must-not-be-parsed' \
  > "$safe_case/docker/tinymediamanager/data/data/tmm.json"
chmod 0600 "$safe_case/docker/tinymediamanager/data/data/tmm.json"
safe_settings_before=$(shasum -a 256 \
  "$safe_case/docker/tinymediamanager/data/data/tmm.json" | awk '{print $1}')
env PLATFORM_CONTRACT_REPO_DIR="$repo_dir" \
  PLATFORM_KIND=test PLATFORM_CONTRACT_SANDBOX_ROOT="$safe_case" \
  PLATFORM_CONTRACT_SANDBOX_OWNER_UID="$(id -u)" \
  PLATFORM_DOCKER_ROOT="$safe_case/docker" PLATFORM_MEDIA_ROOT="$safe_case/media" \
  PLATFORM_REPORT_ROOT="$safe_case/reports" PLATFORM_COMPOSE_KIND=integration \
  PLATFORM_PROJECT_NAME=integration PLATFORM_TINYMEDIAMANAGER_WEB_PORT=4000 \
  PLATFORM_TINYMEDIAMANAGER_API_PORT=7878 \
  "$repo_dir/tests/contracts/tinymediamanager.sh" seed-retirement-fixture >/dev/null
safe_settings_after=$(shasum -a 256 \
  "$safe_case/docker/tinymediamanager/data/data/tmm.json" | awk '{print $1}')
[ "$safe_settings_after" = "$safe_settings_before" ] || {
  printf '%s\n' 'retirement fixture replaced existing tinyMediaManager settings' >&2
  exit 1
}

for unsafe_kind in symlink directory wrong-mode; do
  unsafe_case=$contract_cases/$unsafe_kind
  unsafe_settings=$unsafe_case/docker/tinymediamanager/data/data/tmm.json
  mkdir -p "$(dirname "$unsafe_settings")" "$unsafe_case/media/Media/Movies" \
    "$unsafe_case/media/Media/Series" "$unsafe_case/reports"
  chmod 0700 "$unsafe_case"
  case $unsafe_kind in
    symlink)
      printf '%s\n' outside > "$unsafe_case/outside-settings"
      chmod 0600 "$unsafe_case/outside-settings"
      ln -s "$unsafe_case/outside-settings" "$unsafe_settings"
      ;;
    directory) mkdir "$unsafe_settings" ;;
    wrong-mode)
      printf '%s\n' unsafe > "$unsafe_settings"
      chmod 0644 "$unsafe_settings"
      ;;
  esac
  unsafe_status=0
  env PLATFORM_CONTRACT_REPO_DIR="$repo_dir" \
    PLATFORM_KIND=test PLATFORM_CONTRACT_SANDBOX_ROOT="$unsafe_case" \
    PLATFORM_CONTRACT_SANDBOX_OWNER_UID="$(id -u)" \
    PLATFORM_DOCKER_ROOT="$unsafe_case/docker" PLATFORM_MEDIA_ROOT="$unsafe_case/media" \
    PLATFORM_REPORT_ROOT="$unsafe_case/reports" PLATFORM_COMPOSE_KIND=integration \
    PLATFORM_PROJECT_NAME=integration PLATFORM_TINYMEDIAMANAGER_WEB_PORT=4000 \
    PLATFORM_TINYMEDIAMANAGER_API_PORT=7878 \
    "$repo_dir/tests/contracts/tinymediamanager.sh" seed-retirement-fixture \
    >/dev/null 2>&1 || unsafe_status=$?
  [ "$unsafe_status" -ne 0 ] || {
    printf 'unsafe existing tinyMediaManager settings accepted: %s\n' "$unsafe_kind" >&2
    exit 1
  }
  [ ! -e "$unsafe_case/docker/tinymediamanager/data/retirement-contract.txt" ] && \
    [ ! -e "$unsafe_case/reports/tinymediamanager-retirement.sha256" ] && \
    [ ! -e "$unsafe_case/reports/tinymediamanager-retirement.env" ] || {
      printf 'unsafe tinyMediaManager settings caused partial seed: %s\n' "$unsafe_kind" >&2
      exit 1
    }
done

ruby - "$repo_dir/tests/contracts/tinymediamanager.sh" <<'RUBY'
contract = File.read(ARGV.fetch(0))
abort "retirement fixture requires Ruby 4 Dir.fchdir" if contract.include?("Dir.fchdir")
abort "retirement fixture lacks descriptor-safe portable fchdir" unless
  contract.include?('Fiddle::Handle::DEFAULT["fchdir"]')
exclusive_create = contract[/def create_exclusive.*?^end$/m]
abort "retirement fixture creation is not exclusive and no-follow" unless
  exclusive_create&.include?("File::EXCL | NOFOLLOW")
existing_inspection = contract[/def require_safe_existing_file.*?^end$/m]
abort "existing tinyMediaManager settings are read or hashed" if
  !existing_inspection || existing_inspection.match?(/\.read|Digest/)
RUBY

ruby -ryaml - "$repo_dir/tests/tinymediamanager_retirement_fixture.yml" <<'RUBY'
fixture_path = ARGV.fetch(0)
fixture = YAML.safe_load_file(fixture_path, aliases: true).fetch(0)
abort "retirement fixture play differs" unless fixture.slice(
  "name", "hosts", "connection", "gather_facts"
) == {
  "name" => "Start a legacy tinyMediaManager fixture for retirement proof",
  "hosts" => "localhost",
  "connection" => "local",
  "gather_facts" => false
}
identity = fixture.fetch("tasks").fetch(0)
identity_command = identity.fetch("ansible.builtin.command").fetch("argv")
abort "retirement fixture does not bind the retained repository identity" unless
  identity_command.first == "{{ ansible_playbook_python }}" &&
    identity_command.last == "{{ playbook_dir }}/.." &&
    identity.fetch("changed_when") == false && identity.fetch("check_mode") == false
validation = fixture.fetch("tasks").fetch(1)
validation_command = validation.fetch("ansible.builtin.command").fetch("argv")
abort "retirement fixture does not validate its disposable context" unless
  validation_command == [
    "{{ playbook_dir }}/contracts/tinymediamanager.sh",
    "validate-retirement-fixture"
  ] && validation.fetch("environment") == {
    "PLATFORM_CONTRACT_REPO_DIR" => "{{ playbook_dir }}/.."
  } &&
    validation.fetch("changed_when") == false && validation.fetch("check_mode") == false
task = fixture.fetch("tasks").fetch(2)
compose = task.fetch("community.docker.docker_compose_v2")
abort "retirement fixture project source differs" unless
  compose.fetch("project_src") ==
    "{{ playbook_dir }}/../services/tinymediamanager"
abort "retirement fixture project identity differs" unless
  compose.fetch("project_name") ==
    "{{ lookup('env', 'PLATFORM_PROJECT_NAME') }}-tinymediamanager"
abort "retirement fixture Compose files differ" unless compose.fetch("files").include?(
  "'compose.' ~ lookup('env', 'PLATFORM_COMPOSE_KIND') ~ '.yml'"
)
abort "retirement fixture environment differs" unless compose.fetch("env_files") == [
  "{{ lookup('env', 'PLATFORM_REPORT_ROOT') }}/tinymediamanager-retirement.env"
]
abort "retirement fixture does not wait for startup" unless
  compose.fetch("state") == "present" && compose.fetch("wait") == true &&
    compose.fetch("wait_timeout") == 240
abort "retirement fixture contaminates converge accounting" unless
  task.fetch("changed_when") == false
RUBY

hostile_repo=$fake_bin/hostile-repository
hostile_marker=$fake_bin/hostile-validator-ran
mkdir -p "$hostile_repo/tests/contracts" "$hostile_repo/services/tinymediamanager"
cat > "$hostile_repo/tests/contracts/tinymediamanager.sh" <<'SH'
#!/bin/sh
: > "${HOSTILE_VALIDATOR_MARKER:?}"
exit 0
SH
chmod 0700 "$hostile_repo/tests/contracts/tinymediamanager.sh"
cat > "$hostile_repo/services/tinymediamanager/compose.yml" <<'YAML'
services:
  hostile:
    image: hostile.invalid/arbitrary:latest
YAML
cp "$hostile_repo/services/tinymediamanager/compose.yml" \
  "$hostile_repo/services/tinymediamanager/compose.integration.yml"
playbook_sandbox=$fake_bin/playbook-sandbox
mkdir -p "$playbook_sandbox/docker" "$playbook_sandbox/media" \
  "$playbook_sandbox/report"
chmod 0700 "$playbook_sandbox"
rm -f "$docker_log" "$hostile_marker"
hostile_playbook_status=0
env \
  PATH="$fake_bin:$PATH" DOCKER_LOG="$docker_log" \
  HOSTILE_VALIDATOR_MARKER="$hostile_marker" \
  ANSIBLE_CONFIG="$repo_dir/ansible.cfg" \
  PLATFORM_CONTRACT_REPO_DIR="$hostile_repo" \
  PLATFORM_KIND=test \
  PLATFORM_CONTRACT_SANDBOX_ROOT="$playbook_sandbox" \
  PLATFORM_CONTRACT_SANDBOX_OWNER_UID="$(id -u)" \
  PLATFORM_DOCKER_ROOT="$playbook_sandbox/docker" \
  PLATFORM_MEDIA_ROOT="$playbook_sandbox/media" \
  PLATFORM_REPORT_ROOT="$playbook_sandbox/report" \
  PLATFORM_COMPOSE_KIND=integration PLATFORM_PROJECT_NAME=integration \
  PLATFORM_TINYMEDIAMANAGER_WEB_PORT=4000 \
  PLATFORM_TINYMEDIAMANAGER_API_PORT=7878 \
  "$repo_dir/.venv/bin/ansible-playbook" -i localhost, \
    "$repo_dir/tests/tinymediamanager_retirement_fixture.yml" \
    >/dev/null 2>&1 || hostile_playbook_status=$?
[ "$hostile_playbook_status" -ne 0 ] || {
  printf '%s\n' 'hostile retirement fixture repository was accepted' >&2
  exit 1
}
[ ! -e "$hostile_marker" ] || {
  printf '%s\n' 'hostile retirement fixture validator executed' >&2
  exit 1
}
[ ! -e "$docker_log" ] || {
  printf 'hostile retirement fixture reached Docker: %s\n' \
    "$(cat "$docker_log")" >&2
  exit 1
}

check_sandbox=$fake_bin/check-mode-sandbox
mkdir -p "$check_sandbox/docker" "$check_sandbox/media/Media/Movies" \
  "$check_sandbox/media/Media/Series" "$check_sandbox/report"
chmod 0700 "$check_sandbox"
cat > "$check_sandbox/report/tinymediamanager-retirement.env" <<EOF
TZ=UTC
PLATFORM_CONTAINER_CPUSET=0
USER_ID=1000
GROUP_ID=100
TINYMEDIAMANAGER_PASSWORD=retirement-fixture-only
TINYMEDIAMANAGER_DATA_PATH=$check_sandbox/docker/tinymediamanager/data
TINYMEDIAMANAGER_MOVIES_PATH=$check_sandbox/media/Media/Movies
TINYMEDIAMANAGER_SERIES_PATH=$check_sandbox/media/Media/Series
TINYMEDIAMANAGER_WEB_HOST_PORT=4000
TINYMEDIAMANAGER_API_HOST_PORT=7878
PLATFORM_PROJECT_NAME=integration
EOF
chmod 0600 "$check_sandbox/report/tinymediamanager-retirement.env"
rm -f "$docker_log"
check_playbook_status=0
env \
  PATH="$fake_bin:$PATH" DOCKER_LOG="$docker_log" \
  ANSIBLE_CONFIG="$repo_dir/ansible.cfg" \
  PLATFORM_CONTRACT_REPO_DIR="$repo_dir" \
  PLATFORM_KIND=nas \
  PLATFORM_CONTRACT_SANDBOX_ROOT="$check_sandbox" \
  PLATFORM_CONTRACT_SANDBOX_OWNER_UID="$(id -u)" \
  PLATFORM_DOCKER_ROOT="$check_sandbox/docker" \
  PLATFORM_MEDIA_ROOT="$check_sandbox/media" \
  PLATFORM_REPORT_ROOT="$check_sandbox/report" \
  PLATFORM_COMPOSE_KIND=integration PLATFORM_PROJECT_NAME=integration \
  PLATFORM_TINYMEDIAMANAGER_WEB_PORT=4000 \
  PLATFORM_TINYMEDIAMANAGER_API_PORT=7878 \
  "$repo_dir/.venv/bin/ansible-playbook" -i localhost, \
    "$repo_dir/tests/tinymediamanager_retirement_fixture.yml" --check \
    >/dev/null 2>&1 || check_playbook_status=$?
[ "$check_playbook_status" -ne 0 ] || {
  printf '%s\n' 'NAS retirement fixture context passed check mode' >&2
  exit 1
}
[ ! -e "$docker_log" ] || {
  printf 'check mode skipped fixture validation and reached Docker: %s\n' \
    "$(cat "$docker_log")" >&2
  exit 1
}

assert_output 'suite=foundation tags=deployment_bundle playbook=site.yml scenarios=true' \
  --describe-suite foundation
assert_output 'suite=beszel tags=host_prep,deployment_bundle,ntfy,beszel playbook=site.yml scenarios=true' \
  --describe-suite beszel
assert_output 'suite=dozzle tags=host_prep,deployment_bundle,ntfy,dozzle playbook=site.yml scenarios=true' \
  --describe-suite dozzle
assert_output 'suite=audiobookshelf tags=host_prep,deployment_bundle,ntfy,audiobookshelf playbook=site.yml scenarios=true' \
  --describe-suite audiobookshelf
assert_output 'suite=komga tags=host_prep,deployment_bundle,ntfy,komga playbook=site.yml scenarios=true' \
  --describe-suite komga
assert_output 'suite=tinymediamanager tags=host_prep,deployment_bundle,ntfy,tinymediamanager playbook=site.yml scenarios=true' \
  --describe-suite tinymediamanager
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
grep -qF "PLATFORM_CONTRACT_SANDBOX_ROOT='\$sandbox'" "$integration" || {
  printf '%s\n' 'integration retirement fixture lacks its sandbox boundary' >&2
  exit 1
}
grep -qF 'chmod 0700 "$sandbox"' "$integration" || {
  printf '%s\n' 'integration sandbox is not owner-only' >&2
  exit 1
}
grep -qF "stat -c '%u' '\$sandbox'" "$integration" || {
  printf '%s\n' 'integration controller does not bind sandbox ownership' >&2
  exit 1
}
grep -qF -- '" integration-run "$playbook" "$@"' "$integration"
grep -qF -- '\"\$playbook\" \"\$@\"' "$integration"
grep -qF -- 'run_play --tags \"\$INTEGRATION_TAGS\" \"\$@\"' "$integration"
grep -qF -- 'run_play \"\$@\"' "$integration"
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
grep -qF 'jellyfin:true|full:true)' "$integration"
grep -qF -- '-e PLATFORM_KOMGA_FIXTURE_PRESEEDED="$komga_fixture_preseeded"' "$integration"
grep -qF -- '-e PLATFORM_JELLYFIN_FIXTURE_PRESEEDED="$jellyfin_fixture_preseeded"' \
  "$integration"

for suite in komga jellyfin immich; do
  grep -qF "suite_is $suite" "$integration" || {
    printf '%s\n' "$suite has no independent scenario dispatch" >&2
    exit 1
  }
done
jellyfin_scenarios=$(sed -n '/suite_is jellyfin/,/^    fi$/p' "$integration")
printf '%s\n' "$jellyfin_scenarios" | grep -qF 'run_jellyfin_contract seed'
printf '%s\n' "$jellyfin_scenarios" | grep -qF 'run_jellyfin_contract run'
if printf '%s\n' "$jellyfin_scenarios" | grep -qi tinymediamanager; then
  printf '%s\n' 'Jellyfin scenario dispatch depends on tinyMediaManager' >&2
  exit 1
fi

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

# The Immich restore failure matrix renders into a fresh, isolated Docker root.
# host_prep intentionally refuses to create preservation-only service state, so
# that root must contain a real tinyMediaManager state directory before the
# matrix runs host_prep. This fixture must remain passive: the negative matrix
# does not need a legacy tinyMediaManager container.
ruby - "$integration" <<'RUBY'
integration = File.read(ARGV.fetch(0))
matrix = integration[/run_immich_restore_negative_matrix\(\) \{(.*?)\n    \}/m, 1]
abort "Immich restore negative matrix is absent" unless matrix

parent_index = matrix.index(
  'mkdir -m 0755 \"\\$scenario_root/docker/tinymediamanager\"'
)
seed_index = matrix.index(
  '\"\\$scenario_root/docker/tinymediamanager/data\"'
)
host_prep_index = matrix.index(
  '-e nas_docker_root=\"\\$scenario_root/docker\"'
)
scenario_index = matrix.index('for scenario in no-backup corrupt-newest')
abort "Immich negative matrix does not seed preservation-only tinyMediaManager state" unless
  parent_index && seed_index && parent_index < seed_index
abort "Immich negative matrix seeds tinyMediaManager state after host_prep" unless
  host_prep_index && seed_index < host_prep_index
abort "Immich negative scenarios begin before their isolated root is prepared" unless
  scenario_index && host_prep_index < scenario_index

fixture_setup = matrix[0...host_prep_index]
if fixture_setup.include?('run_tinymediamanager_contract') ||
   fixture_setup.include?('tinymediamanager_retirement_fixture.yml') ||
   fixture_setup.match?(/docker(?: compose)? .*tinymediamanager/)
  abort "Immich negative matrix starts a legacy tinyMediaManager fixture"
end
RUBY

assert_rejected 'unknown integration suite: unknown' --suite unknown
assert_rejected 'unknown integration suite: media' --suite media
assert_rejected 'unknown integration suite: <missing>' --suite
assert_rejected 'unknown integration suite: <missing>' --suite --tags ntfy
assert_rejected 'unknown integration suite: <missing>' --describe-suite
assert_rejected 'missing value for --tags' --suite smoke --tags
assert_rejected 'invalid integration tags: Bad' --suite smoke --tags Bad
assert_rejected 'invalid integration tags: ntfy,,beszel' \
  --suite smoke --tags ntfy,,beszel
for suite in foundation beszel dozzle audiobookshelf komga tinymediamanager jellyfin immich paperless full; do
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

ruby "$repo_dir/tests/tinymediamanager_retirement_inspection_test.rb"

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
    printf 'toomanyrequests: retry-after: 218.093us, allowed: 44000/minute\n' >&2
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

# Read back rather than restated: Renovate bumps every one of these digests.
runner_image=$(sed -n 's/^runner_image=//p' "$integration")
[ -n "$runner_image" ] || prepull_fail 'could not read the controller image pin'

compose_images() {
  sed -n 's/^[[:space:]]*image:[[:space:]]*//p' "$repo_dir/services/$1/compose.yml"
}

run_prepull() {
  prepull_refusals=$1
  prepull_attempts=$2
  shift 2
  : > "$pull_log"
  prepull_status=0
  PATH="$prepull_bin:$PATH" \
    STUB_PULL_LOG=$pull_log \
    STUB_PULL_REFUSALS=$prepull_refusals \
    INTEGRATION_PREPULL_ONLY=1 \
    INTEGRATION_IMAGE_PULL_ATTEMPTS=$prepull_attempts \
    INTEGRATION_IMAGE_PULL_DELAY=1 \
    "$integration" "$@" >/dev/null 2>&1 || prepull_status=$?
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
