#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$repo_dir/tests/sandbox_cleanup.sh"

printf '%s' "$cleanup_sandbox_image" | ruby -e '
  image = STDIN.read
  abort "cleanup_sandbox_image must remain digest-pinned" unless
    image.match?(/\A[^[:space:]@]+@sha256:[0-9a-f]{64}\z/)
'

fixture_parent=${TMPDIR:-/tmp}
fixture_parent=$(CDPATH= cd -P "$fixture_parent" && pwd -P)
created_container_ids=
created_network_ids=
active_sandbox=

cleanup_fixture() {
  cleanup_status=$?
  trap - EXIT HUP INT TERM

  for cleanup_fixture_id in $created_container_ids; do
    docker rm -f "$cleanup_fixture_id" >/dev/null 2>&1 || true
  done
  for cleanup_fixture_id in $created_network_ids; do
    docker network rm "$cleanup_fixture_id" >/dev/null 2>&1 || true
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

  exit "$cleanup_status"
}
trap cleanup_fixture EXIT HUP INT TERM

fail() {
  printf '%s\n' "$*" >&2
  exit 1
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
}

release_sandbox_after_cleanup() {
  [ ! -e "$active_sandbox" ] || fail "cleanup left the integration sandbox behind"
  active_sandbox=
}

require_container_name_available() {
  cleanup_name=$1
  if docker container inspect "$cleanup_name" >/dev/null 2>&1; then
    fail "refusing to collide with existing container: $cleanup_name"
  fi
}

require_network_name_available() {
  cleanup_name=$1
  if docker network inspect "$cleanup_name" >/dev/null 2>&1; then
    fail "refusing to collide with existing network: $cleanup_name"
  fi
}

create_container() {
  create_name=$1
  shift
  require_container_name_available "$create_name"
  created_container_id=$(docker create --pull=never --name "$create_name" "$@" \
    "$cleanup_sandbox_image" sleep 300)
  created_container_ids="$created_container_ids $created_container_id"
}

create_network() {
  create_name=$1
  shift
  require_network_name_available "$create_name"
  created_network_id=$(docker network create --driver bridge "$@" "$create_name")
  created_network_ids="$created_network_ids $created_network_id"
}

require_container_unchanged() {
  expected_id=$1
  description=$2
  actual_id=$(docker container inspect "$expected_id" --format '{{.Id}}' 2>/dev/null) ||
    fail "cleanup deleted unrelated $description container"
  [ "$actual_id" = "$expected_id" ] || fail "cleanup replaced unrelated $description container"
}

require_network_unchanged() {
  expected_id=$1
  description=$2
  actual_id=$(docker network inspect "$expected_id" --format '{{.Id}}' 2>/dev/null) ||
    fail "cleanup deleted unrelated $description network"
  [ "$actual_id" = "$expected_id" ] || fail "cleanup replaced unrelated $description network"
}

require_container_absent() {
  removed_id=$1
  description=$2
  if docker container inspect "$removed_id" >/dev/null 2>&1; then
    fail "cleanup retained owned $description container"
  fi
}

require_network_absent() {
  removed_id=$1
  description=$2
  if docker network inspect "$removed_id" >/dev/null 2>&1; then
    fail "cleanup retained owned $description network"
  fi
}

expect_cleanup_refusal() {
  refusal_description=$1
  if cleanup_sandbox "$active_sandbox" >/dev/null 2>&1; then
    fail "cleanup accepted $refusal_description ownership mismatch"
  fi
  [ -d "$active_sandbox" ] && [ ! -L "$active_sandbox" ] ||
    fail "cleanup mutated the sandbox before refusing $refusal_description"
}

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

cleanup_sandbox "$active_sandbox"
release_sandbox_after_cleanup
require_container_unchanged "$unrelated_radarr_id" radarr
require_container_unchanged "$unrelated_sabnzbd_id" sabnzbd
require_network_unchanged "$unrelated_arr_network_id" arr_default
require_network_unchanged "$unrelated_downloaders_network_id" downloaders_default

docker rm -f "$unrelated_radarr_id" "$unrelated_sabnzbd_id" >/dev/null
docker network rm "$unrelated_arr_network_id" "$unrelated_downloaders_network_id" >/dev/null

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

cleanup_sandbox "$active_sandbox"
release_sandbox_after_cleanup
for service in radarr sonarr prowlarr bazarr sabnzbd unpackerr; do
  eval "owned_service_id=\$owned_${service}_id"
  require_container_absent "$owned_service_id" "$service"
done
require_container_absent "$owned_configarr_id" configarr
require_network_absent "$owned_arr_network_id" arr-default
require_network_absent "$owned_downloaders_network_id" downloaders-default

# An exact permanent name with a missing or wrong project label must refuse
# before deleting a second, correctly owned resource.
for project_mismatch in missing wrong; do
  new_sandbox
  if [ "$project_mismatch" = missing ]; then
    create_container "$fixture_namespace-radarr" \
      --label com.docker.compose.service=radarr
  else
    create_container "$fixture_namespace-radarr" \
      --label com.docker.compose.project=somebody-else \
      --label com.docker.compose.service=radarr
  fi
  mismatched_id=$created_container_id
  create_container "$fixture_namespace-sonarr" \
    --label "com.docker.compose.project=$fixture_arr_project" \
    --label com.docker.compose.service=sonarr
  atomic_peer_id=$created_container_id

  expect_cleanup_refusal "$project_mismatch project-label"
  require_container_unchanged "$mismatched_id" "$project_mismatch-label radarr"
  require_container_unchanged "$atomic_peer_id" atomic-peer-sonarr
  docker rm -f "$mismatched_id" "$atomic_peer_id" >/dev/null
  rmdir "$active_sandbox"
  active_sandbox=
done

# A project label on an unexpected permanent name is likewise an atomic refusal.
new_sandbox
create_container "$fixture_namespace-arr-impostor" \
  --label "com.docker.compose.project=$fixture_arr_project" \
  --label com.docker.compose.service=radarr
unexpected_name_id=$created_container_id
create_container "$fixture_namespace-radarr" \
  --label "com.docker.compose.project=$fixture_arr_project" \
  --label com.docker.compose.service=radarr
atomic_peer_id=$created_container_id
expect_cleanup_refusal unexpected-name
require_container_unchanged "$unexpected_name_id" unexpected-name
require_container_unchanged "$atomic_peer_id" atomic-peer-radarr
docker rm -f "$unexpected_name_id" "$atomic_peer_id" >/dev/null
rmdir "$active_sandbox"
active_sandbox=

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

  cleanup_sandbox "$active_sandbox"
  release_sandbox_after_cleanup
  require_container_unchanged \
    "$unrelated_configarr_id" "Configarr $configarr_project_mismatch-project"
  docker rm -f "$unrelated_configarr_id" >/dev/null
done

# Configarr ownership requires the generated name, service label, and one-off
# label together. Each individual mismatch must refuse before any deletion.
for configarr_mismatch in name service oneoff; do
  new_sandbox
  configarr_name=$fixture_namespace-arr-configarr-run-a1b2c3
  configarr_service=configarr
  configarr_oneoff=True
  case $configarr_mismatch in
    name) configarr_name=$fixture_namespace-arr-configarr-task-a1b2c3 ;;
    service) configarr_service=radarr ;;
    oneoff) configarr_oneoff=False ;;
  esac
  create_container "$configarr_name" \
    --label "com.docker.compose.project=$fixture_arr_project" \
    --label "com.docker.compose.service=$configarr_service" \
    --label "com.docker.compose.oneoff=$configarr_oneoff"
  mismatched_id=$created_container_id
  create_container "$fixture_namespace-radarr" \
    --label "com.docker.compose.project=$fixture_arr_project" \
    --label com.docker.compose.service=radarr
  atomic_peer_id=$created_container_id

  expect_cleanup_refusal "Configarr $configarr_mismatch"
  require_container_unchanged "$mismatched_id" "Configarr $configarr_mismatch"
  require_container_unchanged "$atomic_peer_id" atomic-peer-radarr
  docker rm -f "$mismatched_id" "$atomic_peer_id" >/dev/null
  rmdir "$active_sandbox"
  active_sandbox=
done

printf '%s\n' 'acquisition cleanup: exact Compose ownership controls deletion'
