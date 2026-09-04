#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cleanup_sandbox_repo_dir=$repo_dir
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
active_sandbox_owned=0
active_sandbox_identity=
docker_backend_mode=live
creation_backend_mode=live

sandbox_path_identity() {
  ruby -e '
    path = ARGV.fetch(0)
    entry = File.lstat(path)
    abort "sandbox identity target is not a real directory" unless
      entry.directory? && !entry.symlink?
    print "#{entry.dev}:#{entry.ino}"
  ' "$1"
}

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

  if [ "$active_sandbox_owned" -eq 1 ] &&
     [ -n "$active_sandbox" ] && [ -n "$active_sandbox_identity" ]; then
    cleanup_fixture_parent=${active_sandbox%/*}
    cleanup_fixture_name=${active_sandbox##*/}
    case $cleanup_fixture_name in
      nas-platform-integration.??????) ;;
      *) cleanup_fixture_parent= ;;
    esac
    if [ "$cleanup_fixture_parent" = "$fixture_parent" ] &&
       [ -d "$active_sandbox" ] && [ ! -L "$active_sandbox" ]; then
      cleanup_fixture_identity=$(sandbox_path_identity "$active_sandbox" 2>/dev/null) ||
        cleanup_fixture_identity=
      if [ "$cleanup_fixture_identity" = "$active_sandbox_identity" ]; then
        rmdir "$active_sandbox" >/dev/null 2>&1 || true
      fi
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
    *"container inspect $fake_label_container_old_id --format {{.Name}}"*)
      printf '/%s\n' "$fake_label_container_name"
      ;;
    *"container inspect $fake_legacy_container_old_id --format {{.Name}}"*)
      printf '/%s\n' "$fake_legacy_container_name"
      ;;
    *"network inspect $fake_label_old_id --format {{.Name}}"*)
      printf '%s\n' "$fake_label_network_name"
      ;;
    *"network inspect $fake_media_network_old_id --format {{.Name}}"*)
      printf '%s\n' "$fixture_media_network"
      ;;
    *"container inspect $fake_label_container_name --format {{.Id}} {{.Name}}"*)
      printf '%s /%s\n' \
        "$fake_label_container_replacement_id" "$fake_label_container_name"
      ;;
    *"container inspect $fake_legacy_container_name --format {{.Id}} {{.Name}}"*)
      printf '%s /%s\n' \
        "$fake_legacy_container_replacement_id" "$fake_legacy_container_name"
      ;;
    *"network inspect $fake_label_network_name --format {{.Id}} {{.Name}}"*)
      printf '%s %s\n' "$fake_label_replacement_id" "$fake_label_network_name"
      ;;
    *"network inspect $fixture_media_network --format {{.Id}} {{.Name}}"*)
      printf '%s %s\n' \
        "$fake_media_network_replacement_id" "$fixture_media_network"
      ;;
    *"ps -aq --no-trunc --filter name=^${fake_label_container_name}$"*)
      printf '%s\n' "$fake_label_container_old_id"
      ;;
    *"ps -aq --no-trunc --filter name=^${fake_legacy_container_name}$"*)
      printf '%s\n' "$fake_legacy_container_old_id"
      ;;
    *"ps -aq --no-trunc --filter label=com.docker.compose.project=$fixture_arr_project"*)
      printf '%s\n' "$fake_label_container_old_id"
      ;;
    *"ps -aq --no-trunc --filter label=com.docker.compose.project=$fixture_immich_project"*)
      printf '%s\n' "$fake_legacy_container_old_id"
      ;;
    *"network ls -q --no-trunc --filter name=^${fake_label_network_name}$"*)
      printf '%s\n' "$fake_label_old_id"
      ;;
    *"network ls -q --no-trunc --filter name=^${fixture_media_network}$"*)
      printf '%s\n' "$fake_media_network_old_id"
      ;;
    *"network ls -q --no-trunc --filter label=com.docker.compose.project=$fixture_arr_project"*)
      printf '%s\n' "$fake_label_old_id"
      ;;
    *"network ls -q --no-trunc --filter label=nas.platform.purpose=media-control --filter label=nas.platform.project=$fixture_namespace")
      printf '%s\n' "$fake_media_network_old_id"
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

fake_creation_docker() {
  case ${1-}:${2-} in
    container:inspect | network:inspect)
      printf '%s\n' 'FAKE_CREATION_PROBE' >&2
      return 1
      ;;
    create:*) printf '%s\n' fake-created-container-id ;;
    network:create) printf '%s\n' fake-created-network-id ;;
    *) fail "unexpected fake creation Docker command: $*" ;;
  esac
}

fixture_docker() {
  if [ "$creation_backend_mode" = fake ]; then
    fake_creation_docker "$@"
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

# Refuse to run against a daemon that already holds any resource this fixture
# would create or cleanup would collect, across every registered project of both
# namespaces the sandbox owns. The probes are batched exactly as cleanup batches
# them, so the fixture observes the same daemon state the code under test does.
preflight_project_cleanup_targets() {
  [ -n "$active_sandbox" ] || return 0

  for preflight_namespace in $(cleanup_sandbox_namespaces "$fixture_namespace"); do
    preflight_container_filters=
    preflight_network_filters=
    for preflight_kind in $cleanup_sandbox_projects; do
      cleanup_sandbox_project_services "$preflight_kind" ||
        fail "unregistered cleanup project kind: $preflight_kind"
      for preflight_service in $cleanup_project_services; do
        preflight_container_filters="$preflight_container_filters --filter name=^$preflight_namespace-$preflight_service\$"
      done
      preflight_network_filters="$preflight_network_filters --filter name=^$preflight_namespace-${preflight_kind}_default\$"
    done
    preflight_network_filters="$preflight_network_filters --filter name=^$preflight_namespace-media-control\$"

    # shellcheck disable=SC2086 # The filters are whitespace-free by construction.
    preflight_ids=$(docker_backend ps -aq --no-trunc $preflight_container_filters) ||
      fail "could not inspect namespace containers: $preflight_namespace"
    for preflight_id in $preflight_ids; do
      preflight_name=$(docker_backend container inspect "$preflight_id" \
        --format '{{.Name}}') ||
        fail "could not inspect namespace container ID: $preflight_id"
      preflight_name=${preflight_name#/}
      record_contains "$created_container_records" "$preflight_id" "$preflight_name" ||
        fail "refusing to collide with namespace container: $preflight_name"
    done

    # shellcheck disable=SC2086 # The filters are whitespace-free by construction.
    preflight_ids=$(docker_backend network ls -q --no-trunc $preflight_network_filters) ||
      fail "could not inspect namespace networks: $preflight_namespace"
    for preflight_id in $preflight_ids; do
      preflight_name=$(docker_backend network inspect "$preflight_id" \
        --format '{{.Name}}') ||
        fail "could not inspect namespace network ID: $preflight_id"
      record_contains "$created_network_records" "$preflight_id" "$preflight_name" ||
        fail "refusing to collide with namespace network: $preflight_name"
    done

    for preflight_kind in $cleanup_sandbox_projects; do
      preflight_project=$preflight_namespace-$preflight_kind
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

    preflight_ids=$(docker_backend network ls -q --no-trunc \
      --filter label=nas.platform.purpose=media-control \
      --filter "label=nas.platform.project=$preflight_namespace") ||
      fail "could not inspect labelled media-control networks: $preflight_namespace"
    for preflight_id in $preflight_ids; do
      preflight_name=$(docker_backend network inspect "$preflight_id" \
        --format '{{.Name}}') ||
        fail "could not inspect media-control network ID: $preflight_id"
      record_contains "$created_network_records" "$preflight_id" "$preflight_name" ||
        fail "refusing to collide with media-control network: $preflight_name"
    done
  done
}

preflight_cleanup_call() {
  revalidate_recorded_resources
  preflight_project_cleanup_targets
}

run_cleanup() {
  preflight_cleanup_call
  cleanup_sandbox "$active_sandbox"
}

new_sandbox() {
  [ -z "$active_sandbox" ] || fail "fixture sandbox was not released: $active_sandbox"
  active_sandbox=$(mktemp -d "$fixture_parent/nas-platform-integration.XXXXXX")
  active_sandbox_owned=1
  active_sandbox_identity=$(sandbox_path_identity "$active_sandbox") ||
    fail "could not record the integration sandbox identity"
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
  fixture_immich_project=$fixture_namespace-immich
  fixture_media_network=$fixture_namespace-media-control
  preflight_cleanup_call
}

release_sandbox_after_cleanup() {
  [ ! -e "$active_sandbox" ] || fail "cleanup left the integration sandbox behind"
  active_sandbox=
  active_sandbox_owned=0
  active_sandbox_identity=
}

clear_active_records() {
  created_container_records=
  created_network_records=
}

release_owned_refused_sandbox() {
  [ "$active_sandbox_owned" -eq 1 ] || fail "refused sandbox is not fixture-owned"
  current_sandbox_identity=$(sandbox_path_identity "$active_sandbox") ||
    fail "could not revalidate the refused sandbox identity"
  [ "$current_sandbox_identity" = "$active_sandbox_identity" ] ||
    fail "refused sandbox identity changed before release"
  rmdir "$active_sandbox" || fail "could not release the refused sandbox"
  active_sandbox=
  active_sandbox_owned=0
  active_sandbox_identity=
  clear_active_records
}

require_container_name_available() {
  cleanup_name=$1
  if [ "$creation_backend_mode" = fake ]; then
    fixture_collision=0
    fixture_docker container inspect "$cleanup_name" >/dev/null || fixture_collision=$?
  elif "$real_docker" container inspect "$cleanup_name" >/dev/null 2>&1; then
    fixture_collision=0
  else
    fixture_collision=$?
  fi
  if [ "$fixture_collision" -eq 0 ]; then
    fail "refusing to collide with existing container: $cleanup_name"
  fi
}

require_network_name_available() {
  cleanup_name=$1
  if [ "$creation_backend_mode" = fake ]; then
    fixture_collision=0
    fixture_docker network inspect "$cleanup_name" >/dev/null || fixture_collision=$?
  elif "$real_docker" network inspect "$cleanup_name" >/dev/null 2>&1; then
    fixture_collision=0
  else
    fixture_collision=$?
  fi
  if [ "$fixture_collision" -eq 0 ]; then
    fail "refusing to collide with existing network: $cleanup_name"
  fi
}

create_container() {
  create_name=$1
  shift
  require_container_name_available "$create_name"
  created_container_id=$(fixture_docker create --pull=never --name "$create_name" "$@" \
    "$cleanup_sandbox_image" sleep 300)
  created_container_records="$created_container_records $created_container_id:$create_name"
}

create_network() {
  create_name=$1
  shift
  require_network_name_available "$create_name"
  created_network_id=$(fixture_docker network create --driver bridge "$@" "$create_name")
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

# A production-named resource is unrelated whether this fixture created it or an
# earlier run left it behind. One that already exists is borrowed rather than
# recreated: it is never recorded, so the execution guard refuses any attempt to
# remove it, and the fixture never deletes it either.
borrow_or_create_container() {
  borrow_name=$1
  borrow_id=$("$real_docker" container inspect "$borrow_name" \
    --format '{{.Id}}' 2>/dev/null) || borrow_id=
  if [ -n "$borrow_id" ]; then
    borrowed_container_ids="$borrowed_container_ids $borrow_id"
    return 0
  fi
  create_container "$borrow_name"
  unrelated_container_ids="$unrelated_container_ids $created_container_id"
}

borrow_or_create_network() {
  borrow_name=$1
  shift
  borrow_id=$("$real_docker" network inspect "$borrow_name" \
    --format '{{.Id}}' 2>/dev/null) || borrow_id=
  if [ -n "$borrow_id" ]; then
    borrowed_network_ids="$borrowed_network_ids $borrow_id"
    return 0
  fi
  create_network "$borrow_name" "$@"
  unrelated_network_ids="$unrelated_network_ids $created_network_id"
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
    immich)
      negative_project=$fixture_immich_project
      negative_service=immich-postgres
      peer_project=$fixture_arr_project
      peer_service=radarr
      ;;
    *) fail "unknown negative ownership project: $1" ;;
  esac
}

expect_cleanup_refusal() {
  refusal_description=$1
  refusal_target=$2
  refusal_kind=$3
  case $refusal_kind in
    container | network) ;;
    *) fail "unknown cleanup refusal resource kind: $refusal_kind" ;;
  esac
  refusal_status=0
  refusal_output=$(run_cleanup 2>&1) || refusal_status=$?
  if [ "$refusal_status" -eq 0 ]; then
    fail "cleanup accepted $refusal_description ownership mismatch"
  fi
  expected_refusal="Refusing cleanup ownership for $refusal_kind $refusal_target"
  refusal_line_count=$(printf '%s\n' "$refusal_output" |
    grep -Fxc "$expected_refusal" || true)
  [ "$refusal_line_count" -eq 1 ] || {
    printf '%s\n' "$refusal_output" >&2
    fail "cleanup omitted the exact $refusal_kind ownership refusal for $refusal_target"
  }
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
  fixture_namespace=nas-platform-integration-a1b2c3
  fixture_arr_project=$fixture_namespace-arr
  fixture_downloaders_project=$fixture_namespace-downloaders
  fixture_immich_project=$fixture_namespace-immich
  fixture_media_network=$fixture_namespace-media-control
  fake_label_container_name=$fixture_namespace-radarr
  fake_label_container_old_id=fake-label-container-old-id
  fake_label_container_replacement_id=fake-label-container-replacement-id
  fake_legacy_container_name=$fixture_namespace-immich-postgres
  fake_legacy_container_old_id=fake-legacy-container-old-id
  fake_legacy_container_replacement_id=fake-legacy-container-replacement-id
  fake_label_network_name=${fixture_arr_project}_default
  fake_label_old_id=fake-label-network-old-id
  fake_label_replacement_id=fake-label-network-replacement-id
  fake_media_network_old_id=fake-media-network-old-id
  fake_media_network_replacement_id=fake-media-network-replacement-id
  active_sandbox=$fixture_parent/nas-platform-integration.a1b2c3
  created_container_records=" $fake_label_container_old_id:$fake_label_container_name"
  created_container_records="$created_container_records \
    $fake_legacy_container_old_id:$fake_legacy_container_name"
  created_network_records=" $fake_label_old_id:$fake_label_network_name"
  created_network_records="$created_network_records $fake_media_network_old_id:$fixture_media_network"

  preflight_cleanup_call

  cleanup_sandbox() {
    docker network rm "$fake_label_network_name"
  }
  verify_fake_guard_refusal label-owned-network \
    "refusing unrecorded cleanup network at execution time: $fake_label_network_name"

  cleanup_sandbox() {
    docker network rm "$fixture_media_network"
  }
  verify_fake_guard_refusal media-control-network \
    "refusing unrecorded cleanup network at execution time: $fixture_media_network"

  cleanup_sandbox() {
    docker rm "$fake_label_container_name"
  }
  verify_fake_guard_refusal label-owned-container \
    "refusing unrecorded cleanup container at execution time: $fake_label_container_name"

  cleanup_sandbox() {
    docker rm "$fake_legacy_container_name"
  }
  verify_fake_guard_refusal legacy-label-owned-container \
    "refusing unrecorded cleanup container at execution time: $fake_legacy_container_name"

  active_sandbox=
  active_sandbox_owned=0
  active_sandbox_identity=
  clear_active_records
}

verify_linear_creation_probes() {
  creation_backend_mode=fake
  creation_count=24
  creation_status=0
  creation_output=$(
    (
      created_container_records=
      created_network_records=
      creation_index=0
      while [ "$creation_index" -lt "$creation_count" ]; do
        creation_index=$((creation_index + 1))
        create_container "linear-container-$creation_index"
        create_network "linear-network-$creation_index"
      done
    ) 2>&1
  ) || creation_status=$?
  creation_backend_mode=live
  [ "$creation_status" -eq 0 ] || {
    printf '%s\n' "$creation_output" >&2
    fail "fake linear creation probe failed"
  }
  creation_probe_count=$(printf '%s\n' "$creation_output" |
    grep -c '^FAKE_CREATION_PROBE$' || true)
  creation_probe_limit=$((creation_count * 2))
  [ "$creation_probe_count" -eq "$creation_probe_limit" ] ||
    fail "creation used $creation_probe_count probes for $creation_probe_limit resources"
}

verify_refusal_diagnostic_gate() {
  unrelated_status=0
  unrelated_output=$(
    (
      run_cleanup() {
        printf '%s\n' 'daemon connection refused' fixture-target
        return 1
      }
      expect_cleanup_refusal unrelated-failure fixture-target container
    ) 2>&1
  ) || unrelated_status=$?
  [ "$unrelated_status" -ne 0 ] ||
    fail "refusal diagnostic gate accepted an unrelated cleanup error"
  printf '%s\n' "$unrelated_output" | grep -qF \
    'cleanup omitted the exact container ownership refusal' ||
    fail "refusal diagnostic gate omitted the unrelated-error diagnostic"

  (
    active_sandbox=$fixture_parent
    run_cleanup() {
      printf '%s\n' 'Refusing cleanup ownership for container fixture-target'
      return 1
    }
    expect_cleanup_refusal expected-refusal fixture-target container
  ) || fail "refusal diagnostic gate rejected an explicit target refusal"
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

verify_unowned_sandbox_preservation() {
  (
    probe_parent=$(mktemp -d "$fixture_parent/acquisition-cleanup-self-test.XXXXXX")
    probe_unowned=$probe_parent/nas-platform-integration.a1b2c3
    mkdir "$probe_unowned"
    probe_identity=$(sandbox_path_identity "$probe_unowned")
    cleanup_probe() {
      trap - EXIT HUP INT TERM
      if [ -d "$probe_unowned" ] && [ ! -L "$probe_unowned" ]; then
        current_probe_identity=$(sandbox_path_identity "$probe_unowned" 2>/dev/null) ||
          current_probe_identity=
        if [ "$current_probe_identity" = "$probe_identity" ]; then
          rmdir "$probe_unowned" >/dev/null 2>&1 || true
        fi
      fi
      rmdir "$probe_parent" >/dev/null 2>&1 || true
    }
    trap cleanup_probe EXIT HUP INT TERM

    guard_status=0
    guard_output=$(TMPDIR="$probe_parent" \
      "$repo_dir/tests/sandbox_cleanup_acquisition_ownership_test.sh" \
      --guard-self-test 2>&1) || guard_status=$?
    [ "$guard_status" -eq 0 ] || {
      printf '%s\n' "$guard_output" >&2
      exit 1
    }
    [ -d "$probe_unowned" ] && [ ! -L "$probe_unowned" ] || {
      printf '%s\n' 'guard self-test deleted an unowned predictable sandbox path' >&2
      exit 1
    }
    [ "$(sandbox_path_identity "$probe_unowned")" = "$probe_identity" ] || {
      printf '%s\n' 'guard self-test replaced an unowned predictable sandbox path' >&2
      exit 1
    }
  ) || fail "unowned predictable sandbox preservation regression failed"
}

case ${1-} in
  '')
    "$repo_dir/tests/sandbox_cleanup_acquisition_ownership_test.sh" \
      --self-test >/dev/null || fail "cleanup execution guard self-test failed"
    ;;
  --self-test)
    verify_unowned_sandbox_preservation
    printf '%s\n' 'acquisition cleanup fixture: unowned sandbox preservation holds'
    exit 0
    ;;
  --guard-self-test)
    verify_cleanup_uses_guarded_docker
    verify_linear_creation_probes
    verify_refusal_diagnostic_gate
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
ensure_cleanup_image

# Production-looking names without sandbox ownership are unrelated resources and
# must survive cleanup unchanged. The roster covers a container and a Compose
# network of an acquisition stack and of the pre-existing stacks, plus the
# production media-control bridge, which carries the platform purpose label under
# another project.
unrelated_container_names='radarr sabnzbd ntfy dozzle_socket_proxy immich_postgres paperless_webserver'
unrelated_network_names='arr_default downloaders_default immich_default ntfy_default'
new_sandbox
unrelated_container_ids=
unrelated_network_ids=
borrowed_container_ids=
borrowed_network_ids=
for unrelated_name in $unrelated_container_names; do
  borrow_or_create_container "$unrelated_name"
done
for unrelated_name in $unrelated_network_names; do
  borrow_or_create_network "$unrelated_name"
done
borrow_or_create_network media-control \
  --label nas.platform.purpose=media-control \
  --label nas.platform.project=nas-platform

run_cleanup
release_sandbox_after_cleanup
for unrelated_id in $unrelated_container_ids $borrowed_container_ids; do
  require_container_unchanged "$unrelated_id" production-named
done
for unrelated_id in $unrelated_network_ids $borrowed_network_ids; do
  require_network_unchanged "$unrelated_id" production-named
done

# Only what this fixture created is removed; a borrowed resource stays exactly
# as it was found.
for unrelated_id in $unrelated_container_ids; do
  "$real_docker" rm -f "$unrelated_id" >/dev/null
done
for unrelated_id in $unrelated_network_ids; do
  "$real_docker" network rm "$unrelated_id" >/dev/null
done
clear_active_records

# Exact namespace-derived permanent resources, the media-control bridge, and a
# strict Configarr one-shot are owned by this disposable namespace and must be
# removed. The roster is taken from the cleanup registry itself, so every
# registered service of every registered project is proven, not just the two
# acquisition stacks.
new_sandbox
owned_container_ids=
owned_network_ids=
for kind in $cleanup_sandbox_projects; do
  cleanup_sandbox_project_services "$kind" ||
    fail "unregistered cleanup project kind: $kind"
  for service in $cleanup_project_services; do
    create_container "$fixture_namespace-$service" \
      --label "com.docker.compose.project=$fixture_namespace-$kind" \
      --label "com.docker.compose.service=$service"
    owned_container_ids="$owned_container_ids $created_container_id"
  done
  create_network "$fixture_namespace-${kind}_default" \
    --label "com.docker.compose.project=$fixture_namespace-$kind" \
    --label com.docker.compose.network=default
  owned_network_ids="$owned_network_ids $created_network_id"
done
create_container "$fixture_namespace-arr-configarr-run-a1b2c3" \
  --label "com.docker.compose.project=$fixture_arr_project" \
  --label com.docker.compose.service=configarr \
  --label com.docker.compose.oneoff=True
owned_container_ids="$owned_container_ids $created_container_id"
create_network "$fixture_media_network" \
  --label nas.platform.purpose=media-control \
  --label "nas.platform.project=$fixture_namespace"
owned_network_ids="$owned_network_ids $created_network_id"

run_cleanup
release_sandbox_after_cleanup
for owned_id in $owned_container_ids; do
  require_container_absent "$owned_id" registered-service
done
for owned_id in $owned_network_ids; do
  require_network_absent "$owned_id" registered-network
done
clear_active_records

# Exact names with missing/wrong project labels and project labels on unexpected
# names must refuse atomically for both acquisition Compose projects.
for negative_kind in arr downloaders immich; do
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

    expect_cleanup_refusal "$negative_kind $project_mismatch project-label" \
      "$fixture_namespace-$negative_service" container
    require_container_unchanged \
      "$mismatched_id" "$negative_kind $project_mismatch-label service"
    require_container_unchanged "$atomic_peer_id" "$negative_kind atomic-peer service"
    "$real_docker" rm -f "$mismatched_id" "$atomic_peer_id" >/dev/null
    release_owned_refused_sandbox
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
  expect_cleanup_refusal "$negative_kind unexpected-name" \
    "$fixture_namespace-$negative_kind-impostor" container
  require_container_unchanged "$unexpected_name_id" "$negative_kind unexpected-name"
  require_container_unchanged "$atomic_peer_id" "$negative_kind atomic-peer service"
  "$real_docker" rm -f "$unexpected_name_id" "$atomic_peer_id" >/dev/null
  release_owned_refused_sandbox
done

# Network project, name, and default-network-label mismatches are independently
# table-driven across Arr and downloader ownership, with collected peers intact.
for negative_kind in arr downloaders immich; do
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
      "$negative_kind $network_project_mismatch network project-label" \
      "${negative_project}_default" network
    require_network_unchanged "$mismatched_network_id" \
      "$negative_kind $network_project_mismatch-project default"
    require_network_unchanged \
      "$atomic_peer_network_id" "$negative_kind atomic-peer default"
    require_container_unchanged \
      "$atomic_peer_container_id" "$negative_kind atomic-peer service"
    "$real_docker" rm -f "$atomic_peer_container_id" >/dev/null
    "$real_docker" network rm \
      "$mismatched_network_id" "$atomic_peer_network_id" >/dev/null
    release_owned_refused_sandbox
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
  expect_cleanup_refusal "$negative_kind unexpected-network-name" \
    "${negative_project}_unexpected" network
  require_network_unchanged \
    "$unexpected_network_id" "$negative_kind unexpected-network-name"
  require_network_unchanged \
    "$atomic_peer_network_id" "$negative_kind atomic-peer default"
  require_container_unchanged \
    "$atomic_peer_container_id" "$negative_kind atomic-peer service"
  "$real_docker" rm -f "$atomic_peer_container_id" >/dev/null
  "$real_docker" network rm \
    "$unexpected_network_id" "$atomic_peer_network_id" >/dev/null
  release_owned_refused_sandbox

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

    expect_cleanup_refusal "$negative_kind $network_label_mismatch network label" \
      "${negative_project}_default" network
    require_network_unchanged "$mismatched_network_id" \
      "$negative_kind $network_label_mismatch-label default"
    require_network_unchanged \
      "$atomic_peer_network_id" "$negative_kind atomic-peer default"
    require_container_unchanged \
      "$atomic_peer_container_id" "$negative_kind atomic-peer service"
    "$real_docker" rm -f "$atomic_peer_container_id" >/dev/null
    "$real_docker" network rm \
      "$mismatched_network_id" "$atomic_peer_network_id" >/dev/null
    release_owned_refused_sandbox
  done
done

# The media-control bridge is not a Compose resource: it is owned only when its
# namespace-derived name, bridge driver, and exactly two platform labels all
# match. A wrong project, an extra label, and a labelled network under another
# name each refuse before anything is deleted.
for media_mismatch in project extra-label unexpected-name; do
  new_sandbox
  case $media_mismatch in
    project)
      media_refusal_target=$fixture_media_network
      create_network "$fixture_media_network" \
        --label nas.platform.purpose=media-control \
        --label nas.platform.project=somebody-else
      ;;
    extra-label)
      media_refusal_target=$fixture_media_network
      create_network "$fixture_media_network" \
        --label nas.platform.purpose=media-control \
        --label "nas.platform.project=$fixture_namespace" \
        --label nas.platform.extra=unexpected
      ;;
    unexpected-name)
      media_refusal_target=$fixture_media_network
      create_network "$fixture_media_network-copy" \
        --label nas.platform.purpose=media-control \
        --label "nas.platform.project=$fixture_namespace"
      ;;
  esac
  mismatched_network_id=$created_network_id
  create_container "$fixture_namespace-radarr" \
    --label "com.docker.compose.project=$fixture_arr_project" \
    --label com.docker.compose.service=radarr
  atomic_peer_container_id=$created_container_id

  expect_cleanup_refusal "media-control $media_mismatch" \
    "$media_refusal_target" network
  require_network_unchanged "$mismatched_network_id" "media-control $media_mismatch"
  require_container_unchanged \
    "$atomic_peer_container_id" "media-control atomic-peer service"
  "$real_docker" rm -f "$atomic_peer_container_id" >/dev/null
  "$real_docker" network rm "$mismatched_network_id" >/dev/null
  release_owned_refused_sandbox
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
  clear_active_records
done

# Configarr ownership requires the generated name, service label, and one-off
# label together. Missing and wrong labels independently refuse before deletion.
for configarr_mismatch in name service-missing service-wrong oneoff-missing oneoff-wrong; do
  new_sandbox
  configarr_name=$fixture_namespace-arr-configarr-run-a1b2c3
  configarr_refusal_target=$configarr_name
  case $configarr_mismatch in
    name)
      configarr_refusal_target=$fixture_namespace-arr-configarr-task-a1b2c3
      create_container "$configarr_refusal_target" \
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

  expect_cleanup_refusal \
    "Configarr $configarr_mismatch" "$configarr_refusal_target" container
  require_container_unchanged "$mismatched_id" "Configarr $configarr_mismatch"
  require_container_unchanged "$atomic_peer_id" atomic-peer-radarr
  "$real_docker" rm -f "$mismatched_id" "$atomic_peer_id" >/dev/null
  release_owned_refused_sandbox
done

printf '%s\n' 'acquisition cleanup: exact Compose ownership controls deletion'
