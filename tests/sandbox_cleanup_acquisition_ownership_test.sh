#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$repo_dir/tests/sandbox_cleanup.sh"
real_docker=$(command -v docker) || {
  printf '%s\n' 'docker is required for the acquisition cleanup fixture' >&2
  exit 1
}
case $real_docker in
  /*) ;;
  *)
    printf 'docker did not resolve to an absolute executable: %s\n' "$real_docker" >&2
    exit 1
    ;;
esac
[ -x "$real_docker" ] || {
  printf 'docker executable is unavailable: %s\n' "$real_docker" >&2
  exit 1
}

printf '%s' "$cleanup_sandbox_image" | ruby -e '
  image = STDIN.read
  abort "cleanup_sandbox_image must remain digest-pinned" unless
    image.match?(/\A[^[:space:]@]+@sha256:[0-9a-f]{64}\z/)
'

fixture_parent=${TMPDIR:-/tmp}
fixture_parent=$(CDPATH= cd -P "$fixture_parent" && pwd -P)
created_container_records=
created_network_records=
active_sandbox=
preflight_mode=live
preflight_seen_containers=
preflight_seen_networks=
docker_backend_mode=live

cleanup_fixture_on_signal() {
  trap - HUP INT TERM
  exit "$1"
}

cleanup_fixture() {
  cleanup_status=$?
  trap - EXIT HUP INT TERM

  for cleanup_fixture_record in $created_container_records; do
    cleanup_fixture_id=${cleanup_fixture_record%%:*}
    cleanup_fixture_name=${cleanup_fixture_record#*:}
    cleanup_fixture_actual=$("$real_docker" container inspect "$cleanup_fixture_id" \
      --format '{{.Name}}' 2>/dev/null) || continue
    cleanup_fixture_actual=${cleanup_fixture_actual#/}
    [ "$cleanup_fixture_actual" = "$cleanup_fixture_name" ] || continue
    "$real_docker" rm -f "$cleanup_fixture_id" >/dev/null 2>&1 || true
  done
  for cleanup_fixture_record in $created_network_records; do
    cleanup_fixture_id=${cleanup_fixture_record%%:*}
    cleanup_fixture_name=${cleanup_fixture_record#*:}
    cleanup_fixture_actual=$("$real_docker" network inspect "$cleanup_fixture_id" \
      --format '{{.Name}}' 2>/dev/null) || continue
    [ "$cleanup_fixture_actual" = "$cleanup_fixture_name" ] || continue
    "$real_docker" network rm "$cleanup_fixture_id" >/dev/null 2>&1 || true
  done

  if [ -n "$active_sandbox" ]; then
    cleanup_fixture_parent=${active_sandbox%/*}
    cleanup_fixture_name=${active_sandbox##*/}
    case $cleanup_fixture_name in
      nas-platform-integration.??????) ;;
      *) cleanup_fixture_parent= ;;
    esac
    if [ "$cleanup_fixture_parent" = "$fixture_parent" ] &&
       [ -d "$active_sandbox" ] && [ ! -L "$active_sandbox" ]; then
      rmdir "$active_sandbox" >/dev/null 2>&1 || true
    fi
  fi

  if [ "${ACQUISITION_CLEANUP_SIGNAL_PROBE:-}" = 1 ]; then
    printf 'cleanup fixture exit status=%s\n' "$cleanup_status"
  fi
  exit "$cleanup_status"
}
trap cleanup_fixture EXIT
trap 'cleanup_fixture_on_signal 129' HUP
trap 'cleanup_fixture_on_signal 130' INT
trap 'cleanup_fixture_on_signal 143' TERM

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

record_contains() {
  record_list=$1
  record_id=$2
  record_name=$3
  for recorded_resource in $record_list; do
    [ "$recorded_resource" = "$record_id:$record_name" ] && return 0
  done
  return 1
}

fake_docker() {
  fake_command=$*
  case $fake_command in
    *"container inspect $fake_fixed_old_id --format {{.Name}}"*)
      printf '/%s\n' "$fake_fixed_name"
      ;;
    *"network inspect $fake_label_old_id --format {{.Name}}"*)
      printf '%s\n' "$fake_label_network_name"
      ;;
    *"network inspect $fake_fixed_network_old_id --format {{.Name}}"*)
      printf '%s\n' "$fake_fixed_network_name"
      ;;
    *"container inspect $fake_fixed_name --format {{.Id}} {{.Name}}"*)
      printf '%s /%s\n' "$fake_fixed_replacement_id" "$fake_fixed_name"
      ;;
    *"network inspect $fake_label_network_name --format {{.Id}} {{.Name}}"*)
      printf '%s %s\n' "$fake_label_replacement_id" "$fake_label_network_name"
      ;;
    *"network inspect $fake_fixed_network_name --format {{.Id}} {{.Name}}"*)
      printf '%s %s\n' \
        "$fake_fixed_network_replacement_id" "$fake_fixed_network_name"
      ;;
    *"ps -aq --no-trunc --filter name=^${fake_fixed_name}$"*)
      printf '%s\n' "$fake_fixed_old_id"
      ;;
    *"network ls -q --no-trunc --filter name=^${fake_label_network_name}$"*)
      printf '%s\n' "$fake_label_old_id"
      ;;
    *"network ls -q --no-trunc --filter name=^${fake_fixed_network_name}$"*)
      printf '%s\n' "$fake_fixed_network_old_id"
      ;;
    *"network ls -q --no-trunc --filter label=com.docker.compose.project=$fixture_arr_project"*)
      printf '%s\n' "$fake_label_old_id"
      ;;
    "rm -f "* | "network rm "*)
      printf '%s\n' 'FAKE_DESTRUCTIVE_CALL'
      ;;
    *) ;;
  esac
}

docker_backend() {
  if [ "$docker_backend_mode" = fake ]; then
    fake_docker "$@"
  else
    "$real_docker" "$@"
  fi
}

guard_container_removal() {
  shift
  guard_ids=
  for guard_target in "$@"; do
    case $guard_target in
      -f | --force) continue ;;
      -*) fail "cleanup requested unsupported docker rm option: $guard_target" ;;
    esac
    guard_identity=$(docker_backend container inspect "$guard_target" \
      --format '{{.Id}} {{.Name}}') ||
      fail "cleanup container target disappeared before guarded removal: $guard_target"
    guard_id=${guard_identity%% *}
    guard_name=${guard_identity#* }
    guard_name=${guard_name#/}
    record_contains "$created_container_records" "$guard_id" "$guard_name" ||
      fail "refusing unrecorded cleanup container at execution time: $guard_name"
    guard_ids="$guard_ids $guard_id"
  done
  [ -n "$guard_ids" ] || fail "cleanup requested docker rm without a target"
  # shellcheck disable=SC2086 # IDs are whitespace-free Docker identifiers.
  docker_backend rm -f $guard_ids
}

guard_network_removal() {
  shift
  shift
  guard_ids=
  for guard_target in "$@"; do
    case $guard_target in
      -*) fail "cleanup requested unsupported docker network rm option: $guard_target" ;;
    esac
    guard_identity=$(docker_backend network inspect "$guard_target" \
      --format '{{.Id}} {{.Name}}') ||
      fail "cleanup network target disappeared before guarded removal: $guard_target"
    guard_id=${guard_identity%% *}
    guard_name=${guard_identity#* }
    record_contains "$created_network_records" "$guard_id" "$guard_name" ||
      fail "refusing unrecorded cleanup network at execution time: $guard_name"
    guard_ids="$guard_ids $guard_id"
  done
  [ -n "$guard_ids" ] || fail "cleanup requested docker network rm without a target"
  # shellcheck disable=SC2086 # IDs are whitespace-free Docker identifiers.
  docker_backend network rm $guard_ids
}

docker() {
  case ${1-}:${2-} in
    rm:*) guard_container_removal "$@" ;;
    network:rm) guard_network_removal "$@" ;;
    *) docker_backend "$@" ;;
  esac
}

preflight_fixed_cleanup_targets() {
  for preflight_name in $cleanup_sandbox_containers; do
    case $preflight_name in
      '' | *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-]*)
        fail "cleanup_sandbox_containers contains an unsafe name: $preflight_name"
        ;;
    esac
    preflight_seen_containers="$preflight_seen_containers $preflight_name"
    [ "$preflight_mode" = live ] || continue
    preflight_ids=$(docker_backend ps -aq --no-trunc --filter "name=^${preflight_name}$") ||
      fail "could not inspect cleanup target container: $preflight_name"
    for preflight_id in $preflight_ids; do
      record_contains "$created_container_records" "$preflight_id" "$preflight_name" ||
        fail "refusing to run: pre-existing cleanup target container $preflight_name"
    done
  done

  for preflight_name in $cleanup_sandbox_networks; do
    case $preflight_name in
      '' | *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-]*)
        fail "cleanup_sandbox_networks contains an unsafe name: $preflight_name"
        ;;
    esac
    preflight_seen_networks="$preflight_seen_networks $preflight_name"
    [ "$preflight_mode" = live ] || continue
    preflight_ids=$(docker_backend network ls -q --no-trunc \
      --filter "name=^${preflight_name}$") ||
      fail "could not inspect cleanup target network: $preflight_name"
    for preflight_id in $preflight_ids; do
      record_contains "$created_network_records" "$preflight_id" "$preflight_name" ||
        fail "refusing to run: pre-existing cleanup target network $preflight_name"
    done
  done
}

ensure_cleanup_image() {
  if ! "$real_docker" image inspect "$cleanup_sandbox_image" >/dev/null 2>&1; then
    "$real_docker" pull "$cleanup_sandbox_image" >/dev/null ||
      fail "could not pull the exact pinned cleanup image: $cleanup_sandbox_image"
  fi
  cleanup_image_id=$("$real_docker" image inspect "$cleanup_sandbox_image" \
    --format '{{.Id}}') ||
    fail "could not inspect the exact pinned cleanup image"
  printf '%s' "$cleanup_image_id" | ruby -e '
    abort "pinned cleanup image has an invalid image ID" unless
      STDIN.read.match?(/\Asha256:[0-9a-f]{64}\z/)
  ' || fail "pinned cleanup image has an invalid image ID: $cleanup_image_id"
  cleanup_image_digest=${cleanup_sandbox_image##*@}
  cleanup_image_repo_digests=$("$real_docker" image inspect "$cleanup_sandbox_image" \
    --format '{{json .RepoDigests}}') || fail "could not inspect cleanup image digests"
  case $cleanup_image_repo_digests in
    *"@$cleanup_image_digest"*) ;;
    *) fail "available cleanup image does not report the exact pinned digest" ;;
  esac
}

revalidate_recorded_resources() {
  for preflight_record in $created_container_records; do
    preflight_id=${preflight_record%%:*}
    preflight_name=${preflight_record#*:}
    preflight_actual=$(docker_backend container inspect "$preflight_id" \
      --format '{{.Name}}' 2>/dev/null) || continue
    preflight_actual=${preflight_actual#/}
    [ "$preflight_actual" = "$preflight_name" ] ||
      fail "recorded container ID changed name before cleanup: $preflight_id"
  done
  for preflight_record in $created_network_records; do
    preflight_id=${preflight_record%%:*}
    preflight_name=${preflight_record#*:}
    preflight_actual=$(docker_backend network inspect "$preflight_id" \
      --format '{{.Name}}' 2>/dev/null) || continue
    [ "$preflight_actual" = "$preflight_name" ] ||
      fail "recorded network ID changed name before cleanup: $preflight_id"
  done
}

preflight_project_cleanup_targets() {
  [ -n "$active_sandbox" ] || return 0

  preflight_expected_containers=
  for preflight_service in radarr sonarr prowlarr bazarr sabnzbd unpackerr; do
    preflight_expected_containers="$preflight_expected_containers $fixture_namespace-$preflight_service"
  done
  for preflight_name in $preflight_expected_containers; do
    preflight_ids=$(docker_backend ps -aq --no-trunc \
      --filter "name=^${preflight_name}$") ||
      fail "could not inspect namespace container: $preflight_name"
    for preflight_id in $preflight_ids; do
      record_contains "$created_container_records" "$preflight_id" "$preflight_name" ||
        fail "refusing to collide with namespace container: $preflight_name"
    done
  done

  for preflight_project in "$fixture_arr_project" "$fixture_downloaders_project"; do
    preflight_ids=$(docker_backend ps -aq --no-trunc \
      --filter "label=com.docker.compose.project=$preflight_project") ||
      fail "could not inspect project containers: $preflight_project"
    for preflight_id in $preflight_ids; do
      preflight_name=$(docker_backend container inspect "$preflight_id" \
        --format '{{.Name}}') ||
        fail "could not inspect project container ID: $preflight_id"
      preflight_name=${preflight_name#/}
      record_contains "$created_container_records" "$preflight_id" "$preflight_name" ||
        fail "refusing to collide with project container: $preflight_name"
    done

    preflight_network_name=${preflight_project}_default
    preflight_ids=$(docker_backend network ls -q --no-trunc \
      --filter "name=^${preflight_network_name}$") ||
      fail "could not inspect namespace network: $preflight_network_name"
    for preflight_id in $preflight_ids; do
      record_contains "$created_network_records" "$preflight_id" "$preflight_network_name" ||
        fail "refusing to collide with namespace network: $preflight_network_name"
    done
    preflight_ids=$(docker_backend network ls -q --no-trunc \
      --filter "label=com.docker.compose.project=$preflight_project") ||
      fail "could not inspect project networks: $preflight_project"
    for preflight_id in $preflight_ids; do
      preflight_name=$(docker_backend network inspect "$preflight_id" \
        --format '{{.Name}}') ||
        fail "could not inspect project network ID: $preflight_id"
      record_contains "$created_network_records" "$preflight_id" "$preflight_name" ||
        fail "refusing to collide with project network: $preflight_name"
    done
  done
}

preflight_cleanup_call() {
  revalidate_recorded_resources
  preflight_fixed_cleanup_targets
  preflight_project_cleanup_targets
}

run_cleanup() {
  preflight_cleanup_call
  cleanup_sandbox "$active_sandbox"
}

new_sandbox() {
  [ -z "$active_sandbox" ] || fail "fixture sandbox was not released: $active_sandbox"
  active_sandbox=$(mktemp -d "$fixture_parent/nas-platform-integration.XXXXXX")
  fixture_suffix=${active_sandbox##*.}
  case $fixture_suffix in
    ??????) ;;
    *) fail "mktemp returned an invalid integration suffix" ;;
  esac
  case $fixture_suffix in
    *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789]*)
      fail "mktemp returned a non-alphanumeric integration suffix"
      ;;
  esac
  fixture_suffix=$(printf '%s' "$fixture_suffix" | tr '[:upper:]' '[:lower:]')
  fixture_namespace=nas-platform-integration-$fixture_suffix
  fixture_arr_project=$fixture_namespace-arr
  fixture_downloaders_project=$fixture_namespace-downloaders
  preflight_cleanup_call
}

release_sandbox_after_cleanup() {
  [ ! -e "$active_sandbox" ] || fail "cleanup left the integration sandbox behind"
  active_sandbox=
}

require_container_name_available() {
  cleanup_name=$1
  if "$real_docker" container inspect "$cleanup_name" >/dev/null 2>&1; then
    fail "refusing to collide with existing container: $cleanup_name"
  fi
}

require_network_name_available() {
  cleanup_name=$1
  if "$real_docker" network inspect "$cleanup_name" >/dev/null 2>&1; then
    fail "refusing to collide with existing network: $cleanup_name"
  fi
}

create_container() {
  create_name=$1
  shift
  preflight_cleanup_call
  require_container_name_available "$create_name"
  created_container_id=$("$real_docker" create --pull=never --name "$create_name" "$@" \
    "$cleanup_sandbox_image" sleep 300)
  created_container_records="$created_container_records $created_container_id:$create_name"
}

create_network() {
  create_name=$1
  shift
  preflight_cleanup_call
  require_network_name_available "$create_name"
  created_network_id=$("$real_docker" network create --driver bridge "$@" "$create_name")
  created_network_records="$created_network_records $created_network_id:$create_name"
}

require_container_unchanged() {
  expected_id=$1
  description=$2
  actual_id=$("$real_docker" container inspect "$expected_id" \
    --format '{{.Id}}' 2>/dev/null) ||
    fail "cleanup deleted unrelated $description container"
  [ "$actual_id" = "$expected_id" ] || fail "cleanup replaced unrelated $description container"
}

require_network_unchanged() {
  expected_id=$1
  description=$2
  actual_id=$("$real_docker" network inspect "$expected_id" \
    --format '{{.Id}}' 2>/dev/null) ||
    fail "cleanup deleted unrelated $description network"
  [ "$actual_id" = "$expected_id" ] || fail "cleanup replaced unrelated $description network"
}

require_container_absent() {
  removed_id=$1
  description=$2
  if "$real_docker" container inspect "$removed_id" >/dev/null 2>&1; then
    fail "cleanup retained owned $description container"
  fi
}

require_network_absent() {
  removed_id=$1
  description=$2
  if "$real_docker" network inspect "$removed_id" >/dev/null 2>&1; then
    fail "cleanup retained owned $description network"
  fi
}

select_negative_project() {
  case $1 in
    arr)
      negative_project=$fixture_arr_project
      negative_service=radarr
      peer_project=$fixture_downloaders_project
      peer_service=sabnzbd
      ;;
    downloaders)
      negative_project=$fixture_downloaders_project
      negative_service=sabnzbd
      peer_project=$fixture_arr_project
      peer_service=radarr
      ;;
    *) fail "unknown negative ownership project: $1" ;;
  esac
}

expect_cleanup_refusal() {
  refusal_description=$1
  if run_cleanup >/dev/null 2>&1; then
    fail "cleanup accepted $refusal_description ownership mismatch"
  fi
  [ -d "$active_sandbox" ] && [ ! -L "$active_sandbox" ] ||
    fail "cleanup mutated the sandbox before refusing $refusal_description"
}

verify_fake_guard_refusal() {
  guard_description=$1
  guard_expected=$2
  guard_status=0
  guard_output=$( (run_cleanup) 2>&1) || guard_status=$?
  [ "$guard_status" -ne 0 ] || fail "fake guard accepted $guard_description replacement"
  printf '%s\n' "$guard_output" | grep -qF "$guard_expected" ||
    fail "fake guard omitted $guard_description execution-time refusal"
  case $guard_output in
    *FAKE_DESTRUCTIVE_CALL*)
      fail "fake guard issued a destructive call for $guard_description"
      ;;
  esac
}

verify_execution_guard() {
  docker_backend_mode=fake
  fake_fixed_name=fixture_future_cleanup_container
  fake_fixed_old_id=fake-fixed-container-old-id
  fake_fixed_replacement_id=fake-fixed-container-replacement-id
  fake_fixed_network_name=fixture_future_cleanup_network
  fake_fixed_network_old_id=fake-fixed-network-old-id
  fake_fixed_network_replacement_id=fake-fixed-network-replacement-id
  fixture_namespace=nas-platform-integration-a1b2c3
  fixture_arr_project=$fixture_namespace-arr
  fixture_downloaders_project=$fixture_namespace-downloaders
  fake_label_network_name=${fixture_arr_project}_default
  fake_label_old_id=fake-label-network-old-id
  fake_label_replacement_id=fake-label-network-replacement-id
  active_sandbox=$fixture_parent/nas-platform-integration.a1b2c3
  cleanup_sandbox_containers="$cleanup_sandbox_containers $fake_fixed_name"
  cleanup_sandbox_networks="$cleanup_sandbox_networks $fake_fixed_network_name"
  created_container_records=" $fake_fixed_old_id:$fake_fixed_name"
  created_network_records=" $fake_fixed_network_old_id:$fake_fixed_network_name"
  created_network_records="$created_network_records $fake_label_old_id:$fake_label_network_name"

  preflight_seen_containers=
  preflight_seen_networks=
  preflight_cleanup_call
  case $preflight_seen_containers in
    *" $fake_fixed_name"*) ;;
    *) fail "fake guard preflight did not consume a future sourced container target" ;;
  esac
  case $preflight_seen_networks in
    *" $fake_fixed_network_name"*) ;;
    *) fail "fake guard preflight did not consume a future sourced network target" ;;
  esac

  cleanup_sandbox() {
    docker rm "$fake_fixed_name"
  }
  verify_fake_guard_refusal fixed-container \
    "refusing unrecorded cleanup container at execution time: $fake_fixed_name"

  cleanup_sandbox() {
    docker network rm "$fake_fixed_network_name"
  }
  verify_fake_guard_refusal fixed-network \
    "refusing unrecorded cleanup network at execution time: $fake_fixed_network_name"

  cleanup_sandbox() {
    docker network rm "$fake_label_network_name"
  }
  verify_fake_guard_refusal label-owned-network \
    "refusing unrecorded cleanup network at execution time: $fake_label_network_name"
}

verify_cleanup_uses_guarded_docker() {
  ruby -e '
    source = File.read(ARGV.fetch(0))
    destructive = source.lines.select do |line|
      line.match?(/\bdocker\s+(?:network\s+)?rm(?:\s|$)/)
    end
    abort "cleanup source has no destructive Docker calls to guard" if destructive.empty?
    unless destructive.all? { |line| line.match?(/^\s*docker\s+(?:network\s+)?rm(?:\s|$)/) }
      abort "cleanup source bypasses the fixture Docker function"
    end
    if source.match?(/\bcommand\s+docker\b/) ||
       source.match?(%r{(?:^|\s)/(?:[^\s]*/)*docker\s+(?:network\s+)?rm\b})
      abort "cleanup source bypasses the fixture Docker function"
    end
  ' "$repo_dir/tests/sandbox_cleanup.sh" ||
    fail "cleanup source cannot be protected by the execution-time Docker guard"
}

verify_signal_statuses() {
  for signal_expectation in HUP:129 INT:130 TERM:143; do
    signal_name=${signal_expectation%%:*}
    expected_status=${signal_expectation#*:}
    signal_status=0
    signal_output=$(ACQUISITION_CLEANUP_SIGNAL_PROBE=1 \
      "$repo_dir/tests/sandbox_cleanup_acquisition_ownership_test.sh" \
      --signal-self-test "$signal_name" 2>&1) || signal_status=$?
    [ "$signal_status" -eq "$expected_status" ] ||
      fail "$signal_name handler exited $signal_status instead of $expected_status"
    printf '%s\n' "$signal_output" | grep -qF \
      "cleanup fixture exit status=$expected_status" ||
      fail "$signal_name did not reach the EXIT cleanup trap"
  done
}

case ${1-} in
  '')
    "$repo_dir/tests/sandbox_cleanup_acquisition_ownership_test.sh" \
      --self-test >/dev/null || fail "cleanup execution guard self-test failed"
    ;;
  --self-test)
    verify_cleanup_uses_guarded_docker
    verify_execution_guard
    verify_signal_statuses
    printf '%s\n' 'acquisition cleanup fixture: execution guard and signal handling hold'
    exit 0
    ;;
  --signal-self-test)
    case ${2-} in
      HUP | INT | TERM) kill -"$2" "$$" ;;
      *) fail "unknown acquisition cleanup fixture signal: ${2-}" ;;
    esac
    fail "signal handler returned unexpectedly: $2"
    ;;
  *) fail "unknown acquisition cleanup fixture mode: ${1-}" ;;
esac
preflight_fixed_cleanup_targets
ensure_cleanup_image

# Production-looking names without Compose ownership are unrelated resources and
# must survive cleanup unchanged.
new_sandbox
create_container radarr
unrelated_radarr_id=$created_container_id
create_container sabnzbd
unrelated_sabnzbd_id=$created_container_id
create_network arr_default
unrelated_arr_network_id=$created_network_id
create_network downloaders_default
unrelated_downloaders_network_id=$created_network_id

run_cleanup
release_sandbox_after_cleanup
require_container_unchanged "$unrelated_radarr_id" radarr
require_container_unchanged "$unrelated_sabnzbd_id" sabnzbd
require_network_unchanged "$unrelated_arr_network_id" arr_default
require_network_unchanged "$unrelated_downloaders_network_id" downloaders_default

"$real_docker" rm -f "$unrelated_radarr_id" "$unrelated_sabnzbd_id" >/dev/null
"$real_docker" network rm \
  "$unrelated_arr_network_id" "$unrelated_downloaders_network_id" >/dev/null

# Exact namespace-derived permanent resources and a strict Configarr one-shot
# are owned by this disposable Compose namespace and must be removed.
new_sandbox
for service in radarr sonarr prowlarr bazarr; do
  create_container "$fixture_namespace-$service" \
    --label "com.docker.compose.project=$fixture_arr_project" \
    --label "com.docker.compose.service=$service"
  eval "owned_${service}_id=\$created_container_id"
done
for service in sabnzbd unpackerr; do
  create_container "$fixture_namespace-$service" \
    --label "com.docker.compose.project=$fixture_downloaders_project" \
    --label "com.docker.compose.service=$service"
  eval "owned_${service}_id=\$created_container_id"
done
create_container "$fixture_namespace-arr-configarr-run-a1b2c3" \
  --label "com.docker.compose.project=$fixture_arr_project" \
  --label com.docker.compose.service=configarr \
  --label com.docker.compose.oneoff=True
owned_configarr_id=$created_container_id
create_network "${fixture_arr_project}_default" \
  --label "com.docker.compose.project=$fixture_arr_project" \
  --label com.docker.compose.network=default
owned_arr_network_id=$created_network_id
create_network "${fixture_downloaders_project}_default" \
  --label "com.docker.compose.project=$fixture_downloaders_project" \
  --label com.docker.compose.network=default
owned_downloaders_network_id=$created_network_id

run_cleanup
release_sandbox_after_cleanup
for service in radarr sonarr prowlarr bazarr sabnzbd unpackerr; do
  eval "owned_service_id=\$owned_${service}_id"
  require_container_absent "$owned_service_id" "$service"
done
require_container_absent "$owned_configarr_id" configarr
require_network_absent "$owned_arr_network_id" arr-default
require_network_absent "$owned_downloaders_network_id" downloaders-default

# Exact names with missing/wrong project labels and project labels on unexpected
# names must refuse atomically for both acquisition Compose projects.
for negative_kind in arr downloaders; do
  for project_mismatch in missing wrong; do
    new_sandbox
    select_negative_project "$negative_kind"
    if [ "$project_mismatch" = missing ]; then
      create_container "$fixture_namespace-$negative_service" \
        --label "com.docker.compose.service=$negative_service"
    else
      create_container "$fixture_namespace-$negative_service" \
        --label com.docker.compose.project=somebody-else \
        --label "com.docker.compose.service=$negative_service"
    fi
    mismatched_id=$created_container_id
    create_container "$fixture_namespace-$peer_service" \
      --label "com.docker.compose.project=$peer_project" \
      --label "com.docker.compose.service=$peer_service"
    atomic_peer_id=$created_container_id

    expect_cleanup_refusal "$negative_kind $project_mismatch project-label"
    require_container_unchanged \
      "$mismatched_id" "$negative_kind $project_mismatch-label service"
    require_container_unchanged "$atomic_peer_id" "$negative_kind atomic-peer service"
    "$real_docker" rm -f "$mismatched_id" "$atomic_peer_id" >/dev/null
    rmdir "$active_sandbox"
    active_sandbox=
  done

  new_sandbox
  select_negative_project "$negative_kind"
  create_container "$fixture_namespace-$negative_kind-impostor" \
    --label "com.docker.compose.project=$negative_project" \
    --label "com.docker.compose.service=$negative_service"
  unexpected_name_id=$created_container_id
  create_container "$fixture_namespace-$negative_service" \
    --label "com.docker.compose.project=$negative_project" \
    --label "com.docker.compose.service=$negative_service"
  atomic_peer_id=$created_container_id
  expect_cleanup_refusal "$negative_kind unexpected-name"
  require_container_unchanged "$unexpected_name_id" "$negative_kind unexpected-name"
  require_container_unchanged "$atomic_peer_id" "$negative_kind atomic-peer service"
  "$real_docker" rm -f "$unexpected_name_id" "$atomic_peer_id" >/dev/null
  rmdir "$active_sandbox"
  active_sandbox=
done

# Network project, name, and default-network-label mismatches are independently
# table-driven across Arr and downloader ownership, with collected peers intact.
for negative_kind in arr downloaders; do
  for network_project_mismatch in missing wrong; do
    new_sandbox
    select_negative_project "$negative_kind"
    if [ "$network_project_mismatch" = missing ]; then
      create_network "${negative_project}_default" \
        --label com.docker.compose.network=default
    else
      create_network "${negative_project}_default" \
        --label com.docker.compose.project=somebody-else \
        --label com.docker.compose.network=default
    fi
    mismatched_network_id=$created_network_id
    create_network "${peer_project}_default" \
      --label "com.docker.compose.project=$peer_project" \
      --label com.docker.compose.network=default
    atomic_peer_network_id=$created_network_id
    create_container "$fixture_namespace-$peer_service" \
      --label "com.docker.compose.project=$peer_project" \
      --label "com.docker.compose.service=$peer_service"
    atomic_peer_container_id=$created_container_id

    expect_cleanup_refusal \
      "$negative_kind $network_project_mismatch network project-label"
    require_network_unchanged "$mismatched_network_id" \
      "$negative_kind $network_project_mismatch-project default"
    require_network_unchanged \
      "$atomic_peer_network_id" "$negative_kind atomic-peer default"
    require_container_unchanged \
      "$atomic_peer_container_id" "$negative_kind atomic-peer service"
    "$real_docker" rm -f "$atomic_peer_container_id" >/dev/null
    "$real_docker" network rm \
      "$mismatched_network_id" "$atomic_peer_network_id" >/dev/null
    rmdir "$active_sandbox"
    active_sandbox=
  done

  new_sandbox
  select_negative_project "$negative_kind"
  create_network "${negative_project}_unexpected" \
    --label "com.docker.compose.project=$negative_project" \
    --label com.docker.compose.network=default
  unexpected_network_id=$created_network_id
  create_network "${negative_project}_default" \
    --label "com.docker.compose.project=$negative_project" \
    --label com.docker.compose.network=default
  atomic_peer_network_id=$created_network_id
  create_container "$fixture_namespace-$negative_service" \
    --label "com.docker.compose.project=$negative_project" \
    --label "com.docker.compose.service=$negative_service"
  atomic_peer_container_id=$created_container_id
  expect_cleanup_refusal "$negative_kind unexpected-network-name"
  require_network_unchanged \
    "$unexpected_network_id" "$negative_kind unexpected-network-name"
  require_network_unchanged \
    "$atomic_peer_network_id" "$negative_kind atomic-peer default"
  require_container_unchanged \
    "$atomic_peer_container_id" "$negative_kind atomic-peer service"
  "$real_docker" rm -f "$atomic_peer_container_id" >/dev/null
  "$real_docker" network rm \
    "$unexpected_network_id" "$atomic_peer_network_id" >/dev/null
  rmdir "$active_sandbox"
  active_sandbox=

  for network_label_mismatch in missing wrong; do
    new_sandbox
    select_negative_project "$negative_kind"
    if [ "$network_label_mismatch" = missing ]; then
      create_network "${negative_project}_default" \
        --label "com.docker.compose.project=$negative_project"
    else
      create_network "${negative_project}_default" \
        --label "com.docker.compose.project=$negative_project" \
        --label com.docker.compose.network=wrong
    fi
    mismatched_network_id=$created_network_id
    create_network "${peer_project}_default" \
      --label "com.docker.compose.project=$peer_project" \
      --label com.docker.compose.network=default
    atomic_peer_network_id=$created_network_id
    create_container "$fixture_namespace-$peer_service" \
      --label "com.docker.compose.project=$peer_project" \
      --label "com.docker.compose.service=$peer_service"
    atomic_peer_container_id=$created_container_id

    expect_cleanup_refusal "$negative_kind $network_label_mismatch network label"
    require_network_unchanged "$mismatched_network_id" \
      "$negative_kind $network_label_mismatch-label default"
    require_network_unchanged \
      "$atomic_peer_network_id" "$negative_kind atomic-peer default"
    require_container_unchanged \
      "$atomic_peer_container_id" "$negative_kind atomic-peer service"
    "$real_docker" rm -f "$atomic_peer_container_id" >/dev/null
    "$real_docker" network rm \
      "$mismatched_network_id" "$atomic_peer_network_id" >/dev/null
    rmdir "$active_sandbox"
    active_sandbox=
  done
done

# A generated Configarr name outside the exact project is not owned by this
# sandbox cleanup and must survive, whether the project label is absent or wrong.
for configarr_project_mismatch in missing wrong; do
  new_sandbox
  if [ "$configarr_project_mismatch" = missing ]; then
    create_container "$fixture_namespace-arr-configarr-run-a1b2c3" \
      --label com.docker.compose.service=configarr \
      --label com.docker.compose.oneoff=True
  else
    create_container "$fixture_namespace-arr-configarr-run-a1b2c3" \
      --label com.docker.compose.project=somebody-else \
      --label com.docker.compose.service=configarr \
      --label com.docker.compose.oneoff=True
  fi
  unrelated_configarr_id=$created_container_id

  run_cleanup
  release_sandbox_after_cleanup
  require_container_unchanged \
    "$unrelated_configarr_id" "Configarr $configarr_project_mismatch-project"
  "$real_docker" rm -f "$unrelated_configarr_id" >/dev/null
done

# Configarr ownership requires the generated name, service label, and one-off
# label together. Missing and wrong labels independently refuse before deletion.
for configarr_mismatch in name service-missing service-wrong oneoff-missing oneoff-wrong; do
  new_sandbox
  configarr_name=$fixture_namespace-arr-configarr-run-a1b2c3
  case $configarr_mismatch in
    name)
      create_container "$fixture_namespace-arr-configarr-task-a1b2c3" \
        --label "com.docker.compose.project=$fixture_arr_project" \
        --label com.docker.compose.service=configarr \
        --label com.docker.compose.oneoff=True
      ;;
    service-missing)
      create_container "$configarr_name" \
        --label "com.docker.compose.project=$fixture_arr_project" \
        --label com.docker.compose.oneoff=True
      ;;
    service-wrong)
      create_container "$configarr_name" \
        --label "com.docker.compose.project=$fixture_arr_project" \
        --label com.docker.compose.service=radarr \
        --label com.docker.compose.oneoff=True
      ;;
    oneoff-missing)
      create_container "$configarr_name" \
        --label "com.docker.compose.project=$fixture_arr_project" \
        --label com.docker.compose.service=configarr
      ;;
    oneoff-wrong)
      create_container "$configarr_name" \
        --label "com.docker.compose.project=$fixture_arr_project" \
        --label com.docker.compose.service=configarr \
        --label com.docker.compose.oneoff=False
      ;;
  esac
  mismatched_id=$created_container_id
  create_container "$fixture_namespace-radarr" \
    --label "com.docker.compose.project=$fixture_arr_project" \
    --label com.docker.compose.service=radarr
  atomic_peer_id=$created_container_id

  expect_cleanup_refusal "Configarr $configarr_mismatch"
  require_container_unchanged "$mismatched_id" "Configarr $configarr_mismatch"
  require_container_unchanged "$atomic_peer_id" atomic-peer-radarr
  "$real_docker" rm -f "$mismatched_id" "$atomic_peer_id" >/dev/null
  rmdir "$active_sandbox"
  active_sandbox=
done

printf '%s\n' 'acquisition cleanup: exact Compose ownership controls deletion'
