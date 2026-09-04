#!/bin/sh
set -eu
set +x

mac_script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_script_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"
cleanup_sandbox_repo_dir=$mac_repo_dir
. "$mac_repo_dir/tests/sandbox_cleanup.sh"
. "$mac_repo_dir/tests/integration_lock.sh"

mac_owned_project_labels() {
  mac_label_project=$1
  for mac_label_suffix in \
    beszel ntfy dozzle audiobookshelf komga jellyfin immich paperless; do
    printf '%s-%s\n' "$mac_label_project" "$mac_label_suffix"
  done
  for mac_label_suffix in \
    audiobookshelf beszel dozzle immich jellyfin komga ntfy paperless-ngx; do
    printf '%s-legacy-%s\n' "$mac_label_project" "$mac_label_suffix"
  done
}

mac_projects_are_owned() {
  mac_observed_project=$1
  mac_known_projects=$(mac_owned_project_labels "$mac_observed_project") || return 1
  while IFS= read -r mac_observed_label; do
    [ -n "$mac_observed_label" ] || continue
    case $mac_observed_label in
      "$mac_observed_project"|"$mac_observed_project"-*)
        printf '%s\n' "$mac_known_projects" | grep -Fqx -- "$mac_observed_label" || return 1
        ;;
    esac
  done
}

validate_media_acquisition_network() {
  mac_project=$1
  [ -n "$mac_project" ] || return 1
  case $mac_project in
    [-_]*|*[!abcdefghijklmnopqrstuvwxyz0123456789_-]*) return 1 ;;
  esac
  media_acquisition_cleanup_network=$mac_project-media-control
  media_acquisition_cleanup_candidates=$(docker network ls \
    --filter label=nas.platform.purpose=media-control \
    --filter "label=nas.platform.project=$mac_project" \
    --format '{{.Name}}') || return 1
  case $media_acquisition_cleanup_candidates in
    ''|"$media_acquisition_cleanup_network") ;;
    *) return 1 ;;
  esac
  if ! docker network inspect "$media_acquisition_cleanup_network" >/dev/null 2>&1; then
    [ -z "$media_acquisition_cleanup_candidates" ]
    return
  fi
  media_acquisition_cleanup_record=$(docker network inspect "$media_acquisition_cleanup_network" --format \
    '{{.Name}}|{{.Driver}}|nas.platform.purpose={{index .Labels "nas.platform.purpose"}}|nas.platform.project={{index .Labels "nas.platform.project"}}') || return 1
  [ "$media_acquisition_cleanup_record" = "$media_acquisition_cleanup_network|bridge|nas.platform.purpose=media-control|nas.platform.project=$mac_project" ] || return 1
  media_acquisition_cleanup_labels=$(docker network inspect "$media_acquisition_cleanup_network" --format \
    '{{range $key, $value := .Labels}}{{$key}}={{$value}}|{{end}}' |
    tr '|' '\n' | sed '/^$/d' | LC_ALL=C sort) || return 1
  [ "$media_acquisition_cleanup_labels" = "$(printf '%s\n%s\n' \
    "nas.platform.project=$mac_project" 'nas.platform.purpose=media-control' | LC_ALL=C sort)" ] || return 1
}

remove_media_acquisition_network() {
  mac_project=$1
  validate_media_acquisition_network "$mac_project" || return 1
  media_acquisition_cleanup_network=$mac_project-media-control
  if ! docker network inspect "$media_acquisition_cleanup_network" >/dev/null 2>&1; then
    return 0
  fi
  docker network rm "$media_acquisition_cleanup_network" >/dev/null || return 1
  ! docker network inspect "$media_acquisition_cleanup_network" >/dev/null 2>&1
}

remaining_media_acquisition_network() {
  mac_project=$1
  validate_media_acquisition_network "$mac_project" || return 1
  media_acquisition_cleanup_network=$mac_project-media-control
  if docker network inspect "$media_acquisition_cleanup_network" >/dev/null 2>&1; then
    # The first inspect establishes presence; repeat the complete identity
    # validation before exposing this exact network as removable state.
    validate_media_acquisition_network "$mac_project" || return 1
    printf 'media-control-network:%s\n' "$media_acquisition_cleanup_network"
  fi
}

related_rollback_sandboxes() {
  mac_source_sandbox=$1
  mac_source_project=$2
  mac_source_parent=$(dirname -- "$mac_source_sandbox")
  for mac_rollback_candidate in "$mac_source_parent"/nas-platform-mac.??????; do
    [ -d "$mac_rollback_candidate" ] && [ ! -L "$mac_rollback_candidate" ] || continue
    [ "$mac_rollback_candidate" != "$mac_source_sandbox" ] || continue
    mac_rollback_validated=$(mac_validate_sandbox "$mac_rollback_candidate" 2>/dev/null) || continue
    mac_rollback_marker=$mac_rollback_validated/.nas-platform-mac-owned
    [ "$(sed -n 's/^namespace=//p' "$mac_rollback_marker")" = rollback ] || continue
    [ "$(sed -n 's/^source_project=//p' "$mac_rollback_marker")" = "$mac_source_project" ] || continue
    mac_rollback_binding=$(sed -n 's/^snapshot_binding=//p' "$mac_rollback_marker")
    case $mac_rollback_binding in ''|*[!0123456789abcdef]*) return 1 ;; esac
    [ "${#mac_rollback_binding}" -eq 64 ] || return 1
    [ "$(wc -l < "$mac_rollback_marker" | tr -d ' ')" -eq 5 ] || return 1
    printf '%s\n' "$mac_rollback_validated"
  done
}

preflight_mac_resources() {
  mac_preflight_target=$(mac_validate_sandbox "$1") || return 1
  mac_preflight_project=$(sed -n 's/^project=//p' "$mac_preflight_target/.nas-platform-mac-owned")
  mac_observed_containers=$(docker ps -a --format '{{.Label "com.docker.compose.project"}}') || return 1
  printf '%s\n' "$mac_observed_containers" | mac_projects_are_owned "$mac_preflight_project" || return 1
  mac_observed_networks=$(docker network ls --format '{{.Label "com.docker.compose.project"}}') || return 1
  printf '%s\n' "$mac_observed_networks" | mac_projects_are_owned "$mac_preflight_project" || return 1
  mac_observed_volumes=$(docker volume ls --format '{{.Label "com.docker.compose.project"}}') || return 1
  printf '%s\n' "$mac_observed_volumes" | mac_projects_are_owned "$mac_preflight_project" || return 1
}

cleanup_one_mac_sandbox() {
  mac_cleanup_target=$(mac_validate_sandbox "$1") || return 1
  mac_marker=$mac_cleanup_target/.nas-platform-mac-owned
  mac_project=$(sed -n 's/^project=//p' "$mac_marker")
  validate_media_acquisition_network "$mac_project" || return 1

  mac_container_ids=$(for mac_service_project in $(mac_owned_project_labels "$mac_project"); do
    docker ps -aq --filter "label=com.docker.compose.project=$mac_service_project" || exit 1
  done) || return 1
  mac_network_ids=$(for mac_service_project in $(mac_owned_project_labels "$mac_project"); do
    docker network ls -q --filter "label=com.docker.compose.project=$mac_service_project" || exit 1
  done) || return 1
  mac_volume_ids=$(for mac_service_project in $(mac_owned_project_labels "$mac_project"); do
    docker volume ls -q --filter "label=com.docker.compose.project=$mac_service_project" || exit 1
  done) || return 1

  # Discovery itself is a mutation boundary. Recheck every related label after
  # all IDs are known and before the first removal.
  preflight_mac_resources "$mac_cleanup_target" || return 1
  for mac_container_id in $mac_container_ids; do
    docker rm -f "$mac_container_id" >/dev/null || return 1
  done
  remove_media_acquisition_network "$mac_project" || return 1
  for mac_network_id in $mac_network_ids; do
    docker network rm "$mac_network_id" >/dev/null || return 1
  done
  for mac_volume_id in $mac_volume_ids; do
    docker volume rm "$mac_volume_id" >/dev/null || return 1
  done

  # Require two consecutive owned and empty observations. This is bounded so
  # a recreating resource fails closed and leaves the sandbox marker intact.
  mac_empty_rounds=0
  mac_stability_attempts=0
  while [ "$mac_empty_rounds" -lt 2 ] && [ "$mac_stability_attempts" -lt 4 ]; do
    mac_stability_attempts=$((mac_stability_attempts + 1))
    preflight_mac_resources "$mac_cleanup_target" || return 1
    mac_remaining=$(for mac_service_project in $(mac_owned_project_labels "$mac_project"); do
      mac_ids=$(docker ps -aq --filter "label=com.docker.compose.project=$mac_service_project") || exit 1
      [ -z "$mac_ids" ] || printf '%s\n' "$mac_ids" | sed 's/^/container:/'
      mac_ids=$(docker network ls -q --filter "label=com.docker.compose.project=$mac_service_project") || exit 1
      [ -z "$mac_ids" ] || printf '%s\n' "$mac_ids" | sed 's/^/network:/'
      mac_ids=$(docker volume ls -q --filter "label=com.docker.compose.project=$mac_service_project") || exit 1
      [ -z "$mac_ids" ] || printf '%s\n' "$mac_ids" | sed 's/^/volume:/'
    done
      remaining_media_acquisition_network "$mac_project") || return 1
    if [ -z "$mac_remaining" ]; then
      mac_empty_rounds=$((mac_empty_rounds + 1))
    else
      mac_empty_rounds=0
      preflight_mac_resources "$mac_cleanup_target" || return 1
      for mac_remaining_id in $mac_remaining; do
        case $mac_remaining_id in
          container:*) docker rm -f "${mac_remaining_id#container:}" >/dev/null || return 1 ;;
          network:*) docker network rm "${mac_remaining_id#network:}" >/dev/null || return 1 ;;
          media-control-network:*)
            [ "${mac_remaining_id#media-control-network:}" = "$mac_project-media-control" ] || return 1
            remove_media_acquisition_network "$mac_project" || return 1
            ;;
          volume:*) docker volume rm "${mac_remaining_id#volume:}" >/dev/null || return 1 ;;
          *) return 1 ;;
        esac
      done
    fi
  done
  [ "$mac_empty_rounds" -eq 2 ] || return 1

  preflight_mac_resources "$mac_cleanup_target" || return 1
  mac_final_remaining=$(for mac_service_project in $(mac_owned_project_labels "$mac_project"); do
    mac_ids=$(docker ps -aq --filter "label=com.docker.compose.project=$mac_service_project") || exit 1
    [ -z "$mac_ids" ] || printf '%s\n' "$mac_ids"
    mac_ids=$(docker network ls -q --filter "label=com.docker.compose.project=$mac_service_project") || exit 1
    [ -z "$mac_ids" ] || printf '%s\n' "$mac_ids"
    mac_ids=$(docker volume ls -q --filter "label=com.docker.compose.project=$mac_service_project") || exit 1
    [ -z "$mac_ids" ] || printf '%s\n' "$mac_ids"
  done
    remaining_media_acquisition_network "$mac_project") || return 1
  [ -z "$mac_final_remaining" ] || return 1

  # Revalidate immediately before the descriptor-relative removal. The shared
  # helper opens both parent and children with O_NOFOLLOW inside the pinned
  # cleanup image, so a concurrent symlink swap cannot redirect traversal.
  [ "$(mac_validate_sandbox "$mac_cleanup_target")" = "$mac_cleanup_target" ] || return 1
  preflight_mac_resources "$mac_cleanup_target" || return 1
  mac_final_media_network=$(remaining_media_acquisition_network "$mac_project") || return 1
  [ -z "$mac_final_media_network" ] || return 1
  cleanup_sandbox_contents "$(dirname -- "$mac_cleanup_target")" \
    "$(basename -- "$mac_cleanup_target")" ".nas-platform-mac-owned" || return 1
  [ ! -e "$mac_cleanup_target" ] && [ ! -L "$mac_cleanup_target" ]
}

cleanup_mac_sandbox() {
  mac_source_target=$(mac_validate_sandbox "$1") || return 1
  mac_source_project=$(sed -n 's/^project=//p' "$mac_source_target/.nas-platform-mac-owned")
  mac_related_targets=$(related_rollback_sandboxes "$mac_source_target" "$mac_source_project") || return 1

  preflight_mac_resources "$mac_source_target" || return 1
  for mac_related_target in $mac_related_targets; do
    preflight_mac_resources "$mac_related_target" || return 1
  done

  for mac_related_target in $mac_related_targets; do
    cleanup_one_mac_sandbox "$mac_related_target" || return 1
  done
  cleanup_one_mac_sandbox "$mac_source_target"
}

force_final_rmdir_failure() {
  mac_failure_parent=$1
  mac_failure_name=$2
  mac_failure_preserve=$3
  mac_failure_program=$(mktemp "$mac_failure_parent/mac-cleanup-program.XXXXXX") || return 1
  cleanup_sandbox_program > "$mac_failure_program"
  mac_failure_program_name=$(basename -- "$mac_failure_program")

  docker run --rm -i -v "$mac_failure_parent:/sandbox-parent" \
    "$cleanup_sandbox_image" python - "$mac_failure_name" \
    "$mac_failure_preserve" "$mac_failure_program_name" <<'PY'
import errno
import os
import sys


name = sys.argv[1]
preserve = sys.argv[2]
program = sys.argv[3]
real_rmdir = os.rmdir
forced = False


def fail_final_rmdir(path, *args, **kwargs):
    global forced
    if not forced and path == name and kwargs.get("dir_fd") is not None:
        forced = True
        raise OSError(errno.ENOTEMPTY, "forced final rmdir failure", path)
    return real_rmdir(path, *args, **kwargs)


os.rmdir = fail_final_rmdir
sys.argv = [program, name, preserve]
try:
    with open(f"/sandbox-parent/{program}", encoding="utf-8") as source:
        exec(compile(source.read(), program, "exec"))
except OSError as error:
    if not forced or error.errno != errno.ENOTEMPTY:
        raise
    sys.exit(42)
raise RuntimeError("forced final rmdir was not reached")
PY
  mac_failure_status=$?
  rm -f -- "$mac_failure_program"
  return "$mac_failure_status"
}

cleanup_self_test() {
  mac_test_parent=$(mac_temporary_parent)
  mac_repo_root=$(CDPATH= cd -- "$mac_repo_dir" && pwd -P)
  mac_arbitrary=$(mktemp -d "$mac_test_parent/mac-cleanup-arbitrary.XXXXXX")
  chmod 0700 "$mac_arbitrary"
  mac_unmarked=$(mktemp -d "$mac_test_parent/nas-platform-mac.XXXXXX")
  chmod 0700 "$mac_unmarked"

  for mac_unsafe in '' / "$mac_repo_root" "$mac_arbitrary" "$mac_unmarked"; do
    if "$0" "$mac_unsafe" >/dev/null 2>&1; then
      printf 'cleanup self-test accepted unsafe path: %s\n' "$mac_unsafe" >&2
      exit 1
    fi
    [ -z "$mac_unsafe" ] || [ -e "$mac_unsafe" ] || {
      printf 'cleanup self-test mutated refused target: %s\n' "$mac_unsafe" >&2
      exit 1
    }
  done
  rmdir -- "$mac_unmarked"

  mac_owned=$(mktemp -d "$mac_test_parent/nas-platform-mac.XXXXXX")
  chmod 0700 "$mac_owned"
  mac_suffix=${mac_owned##*.}
  mac_project_suffix=$(printf '%s' "$mac_suffix" | tr '[:upper:]' '[:lower:]')
  printf 'schema=1\nproject=nas-platform-mac-%s\n' "$mac_project_suffix" \
    > "$mac_owned/.nas-platform-mac-owned"
  chmod 0600 "$mac_owned/.nas-platform-mac-owned"
  mac_alias="$mac_test_parent/nas-platform-mac.alias.$$"
  ln -s "$mac_owned" "$mac_alias"
  for mac_unsafe in "$mac_alias" "$mac_alias/" "$mac_owned/." \
    "$mac_test_parent//$(basename -- "$mac_owned")"; do
    if "$0" "$mac_unsafe" >/dev/null 2>&1; then
      printf 'cleanup self-test accepted alias: %s\n' "$mac_unsafe" >&2
      exit 1
    fi
    [ -d "$mac_owned" ] || {
      printf 'cleanup self-test did not preserve alias target\n' >&2
      exit 1
    }
  done
  chmod 0644 "$mac_owned/.nas-platform-mac-owned"
  if "$0" "$mac_owned" >/dev/null 2>&1; then
    printf 'cleanup self-test accepted an unsafe marker mode\n' >&2
    exit 1
  fi
  [ -d "$mac_owned" ] || {
    printf 'cleanup self-test did not preserve unsafe-marker target\n' >&2
    exit 1
  }
  chmod 0600 "$mac_owned/.nas-platform-mac-owned"
  mac_marker_copy=$(mktemp "$mac_test_parent/mac-cleanup-marker.XXXXXX")
  cp -p "$mac_owned/.nas-platform-mac-owned" "$mac_marker_copy"
  mac_marker_mode=$(mac_file_mode "$mac_owned/.nas-platform-mac-owned")
  mac_marker_uid=$(mac_owner_id "$mac_owned/.nas-platform-mac-owned")
  case $(uname -s) in
    Darwin) mac_marker_gid=$(stat -f '%g' "$mac_owned/.nas-platform-mac-owned") ;;
    *) mac_marker_gid=$(stat -c '%g' "$mac_owned/.nas-platform-mac-owned") ;;
  esac
  printf 'payload removed before final rmdir\n' > "$mac_owned/payload"
  # The forced-failure probe runs the sandbox program inside a container, and the
  # call below discards its output to keep the proof quiet. Without a reachable
  # daemon the probe cannot report its authentication status at all, which would
  # otherwise be indistinguishable from a genuinely broken rmdir contract.
  command -v docker >/dev/null 2>&1 || {
    printf 'cleanup self-test requires Docker to authenticate the final rmdir failure\n' >&2
    exit 1
  }
  docker info >/dev/null 2>&1 || {
    printf 'cleanup self-test requires a running Docker daemon to authenticate the final rmdir failure\n' >&2
    exit 1
  }
  if force_final_rmdir_failure "$mac_test_parent" "$(basename -- "$mac_owned")" \
      ".nas-platform-mac-owned" >/dev/null 2>&1; then
    mac_forced_status=0
  else
    mac_forced_status=$?
  fi
  [ "$mac_forced_status" -eq 42 ] || {
    printf 'cleanup self-test did not authenticate final rmdir failure\n' >&2
    exit 1
  }
  [ ! -e "$mac_owned/payload" ] && [ ! -L "$mac_owned/payload" ] || {
    printf 'cleanup self-test failed before clearing sandbox payload\n' >&2
    exit 1
  }
  [ -d "$mac_owned" ] && [ ! -L "$mac_owned" ] || {
    printf 'cleanup self-test did not preserve sandbox after final rmdir failure\n' >&2
    exit 1
  }
  cmp -s "$mac_marker_copy" "$mac_owned/.nas-platform-mac-owned" || {
    printf 'cleanup self-test did not restore exact marker bytes\n' >&2
    exit 1
  }
  [ "$(mac_file_mode "$mac_owned/.nas-platform-mac-owned")" = "$mac_marker_mode" ] &&
    [ "$(mac_owner_id "$mac_owned/.nas-platform-mac-owned")" = "$mac_marker_uid" ] || {
      printf 'cleanup self-test did not restore marker mode and uid\n' >&2
      exit 1
    }
  case $(uname -s) in
    Darwin) mac_restored_gid=$(stat -f '%g' "$mac_owned/.nas-platform-mac-owned") ;;
    *) mac_restored_gid=$(stat -c '%g' "$mac_owned/.nas-platform-mac-owned") ;;
  esac
  [ "$mac_restored_gid" = "$mac_marker_gid" ] || {
    printf 'cleanup self-test did not restore marker gid\n' >&2
    exit 1
  }
  "$0" "$mac_owned"
  [ ! -e "$mac_owned" ] && [ ! -L "$mac_owned" ] || {
    printf 'cleanup self-test could not clean recovered sandbox\n' >&2
    exit 1
  }
  rm -f -- "$mac_alias" "$mac_marker_copy"
  rmdir -- "$mac_arbitrary"
  printf 'cleanup: all safety properties hold\n'
}

cleanup_lock_held=false
release_cleanup_lock_on_exit() {
  mac_cleanup_exit_status=$?
  trap - EXIT HUP INT TERM
  if [ "$cleanup_lock_held" = true ] && ! release_integration_lock; then
    [ "$mac_cleanup_exit_status" -ne 0 ] || mac_cleanup_exit_status=1
  fi
  exit "$mac_cleanup_exit_status"
}

cleanup_with_lock() {
  mac_cleanup_validated=$(mac_validate_sandbox "$1") || return 1
  mac_cleanup_parent=$(dirname -- "$mac_cleanup_validated")
  acquire_integration_lock "$mac_cleanup_parent" || return 1
  cleanup_lock_held=true
  trap release_cleanup_lock_on_exit EXIT
  trap 'exit 130' HUP INT TERM
  cleanup_mac_sandbox "$mac_cleanup_validated"
}

case ${1-} in
  --self-test-projects)
    [ "${PLATFORM_MAC_CLEANUP_PROJECT_SELF_TEST:-}" = 1 ] && [ "$#" -eq 2 ] ||
      mac_die 'usage: cleanup.sh --self-test | SANDBOX'
    mac_self_test_project=$2
    case $mac_self_test_project in
      nas-platform-mac-[abcdefghijklmnopqrstuvwxyz0123456789]*) ;;
      *) mac_die 'cleanup self-test project is invalid' ;;
    esac
    mac_projects_are_owned "$mac_self_test_project" || exit 1
    mac_owned_project_labels "$mac_self_test_project"
    ;;
  --self-test)
    [ "$#" -eq 1 ] || mac_die 'usage: cleanup.sh --self-test | SANDBOX'
    cleanup_self_test
    ;;
  '') mac_die 'usage: cleanup.sh --self-test | SANDBOX' ;;
  *)
    [ "$#" -eq 1 ] || mac_die 'usage: cleanup.sh --self-test | SANDBOX'
    cleanup_with_lock "$1"
    ;;
esac
