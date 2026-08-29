#!/bin/sh

cleanup_sandbox_image=docker.io/library/python:3.14-alpine@sha256:05b2b8b732ecd268fee8727a369f936f022d1321b59befd13c30ede22769dcdc
# Every sandbox resource is namespace-derived, so nothing is deleted by a fixed
# production name: containers and networks are discovered through exact Compose
# ownership labels and then matched against the exact namespaced identity
# Compose gives them. A container that merely shares a production name is
# therefore never a cleanup target, and is left untouched.
cleanup_sandbox_projects='ntfy beszel dozzle audiobookshelf komga jellyfin immich paperless'
cleanup_sandbox_projects="$cleanup_sandbox_projects arr downloaders pinchflat"
cleanup_sandbox_ntfy_services='ntfy'
cleanup_sandbox_beszel_services='beszel beszel-agent-intel beszel-agent-portable beszel-socket-proxy'
cleanup_sandbox_dozzle_services='dozzle dozzle-alert-relay dozzle-socket-proxy'
cleanup_sandbox_audiobookshelf_services='audiobookshelf'
cleanup_sandbox_komga_services='komga'
cleanup_sandbox_jellyfin_services='jellyfin'
cleanup_sandbox_immich_services='immich-server immich-machine-learning immich-redis immich-postgres'
cleanup_sandbox_paperless_services='paperless-redis paperless-postgres paperless-webserver'
cleanup_sandbox_paperless_services="$cleanup_sandbox_paperless_services paperless-gotenberg paperless-tika"
cleanup_sandbox_arr_services='radarr sonarr prowlarr bazarr'
cleanup_sandbox_downloaders_services='sabnzbd unpackerr'
cleanup_sandbox_pinchflat_services='pinchflat'

cleanup_sandbox_program() {
  cat <<'PY'
import os
import re
import stat
import sys


name = sys.argv[1]
preserve = sys.argv[2]
supported_names = (
    r"nas-platform-integration\.[A-Za-z0-9]{6}",
    r"nas-platform-cleanup\.[A-Za-z0-9]{6}",
    r"nas-platform-mac\.[A-Za-z0-9]{6}",
    r"nas-platform-mac\.[A-Za-z0-9]{6}\.reports",
)
if not any(re.fullmatch(pattern, name) for pattern in supported_names):
    raise ValueError("invalid sandbox basename")
if preserve and not (
    (re.fullmatch(r"nas-platform-mac\.[A-Za-z0-9]{6}", name)
     and preserve == ".nas-platform-mac-owned")
    or (re.fullmatch(r"nas-platform-mac\.[A-Za-z0-9]{6}\.reports", name)
        and preserve == ".nas-platform-mac-report-owned")
):
    raise ValueError("invalid preserved marker")

open_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def clear_directory(directory_fd, preserved_entry=""):
    for entry in os.listdir(directory_fd):
        if entry == preserved_entry:
            continue
        entry_stat = os.stat(
            entry, dir_fd=directory_fd, follow_symlinks=False
        )
        if stat.S_ISDIR(entry_stat.st_mode):
            child_fd = os.open(entry, open_flags, dir_fd=directory_fd)
            try:
                clear_directory(child_fd)
            finally:
                os.close(child_fd)
            os.rmdir(entry, dir_fd=directory_fd)
        else:
            os.unlink(entry, dir_fd=directory_fd)


parent_fd = os.open("/sandbox-parent", open_flags)
try:
    sandbox_fd = os.open(name, open_flags, dir_fd=parent_fd)
    try:
        if preserve:
            marker_fd = os.open(preserve, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=sandbox_fd)
            try:
                marker_stat = os.fstat(marker_fd)
                if not stat.S_ISREG(marker_stat.st_mode):
                    raise ValueError("preserved marker is not regular")
                marker_data = os.read(marker_fd, 4097)
                if len(marker_data) > 4096:
                    raise ValueError("preserved marker is unexpectedly large")
            finally:
                os.close(marker_fd)

            clear_directory(sandbox_fd, preserve)
            os.unlink(preserve, dir_fd=sandbox_fd)
            try:
                os.rmdir(name, dir_fd=parent_fd)
            except OSError:
                recovery_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
                recovery_fd = os.open(
                    preserve,
                    recovery_flags,
                    stat.S_IMODE(marker_stat.st_mode),
                    dir_fd=sandbox_fd,
                )
                try:
                    os.write(recovery_fd, marker_data)
                    os.fchmod(recovery_fd, stat.S_IMODE(marker_stat.st_mode))
                    os.fchown(recovery_fd, marker_stat.st_uid, marker_stat.st_gid)
                finally:
                    os.close(recovery_fd)
                raise
        else:
            clear_directory(sandbox_fd)
    finally:
        os.close(sandbox_fd)
finally:
    os.close(parent_fd)
PY
}

cleanup_sandbox_contents() {
  cleanup_contents_parent=$1
  cleanup_contents_name=$2
  cleanup_contents_preserve=${3-}

  cleanup_sandbox_program | docker run --rm -i \
    -v "$cleanup_contents_parent:/sandbox-parent" "$cleanup_sandbox_image" \
    python - "$cleanup_contents_name" "$cleanup_contents_preserve"
}

cleanup_sandbox_project_services() {
  case $1 in
    ntfy) cleanup_project_services=$cleanup_sandbox_ntfy_services ;;
    beszel) cleanup_project_services=$cleanup_sandbox_beszel_services ;;
    dozzle) cleanup_project_services=$cleanup_sandbox_dozzle_services ;;
    audiobookshelf) cleanup_project_services=$cleanup_sandbox_audiobookshelf_services ;;
    komga) cleanup_project_services=$cleanup_sandbox_komga_services ;;
    jellyfin) cleanup_project_services=$cleanup_sandbox_jellyfin_services ;;
    immich) cleanup_project_services=$cleanup_sandbox_immich_services ;;
    paperless) cleanup_project_services=$cleanup_sandbox_paperless_services ;;
    arr) cleanup_project_services=$cleanup_sandbox_arr_services ;;
    downloaders) cleanup_project_services=$cleanup_sandbox_downloaders_services ;;
    pinchflat) cleanup_project_services=$cleanup_sandbox_pinchflat_services ;;
    *)
      printf 'unknown sandbox cleanup project kind: %s\n' "$1" >&2
      return 1
      ;;
  esac
}

cleanup_refuse_ownership() {
  printf 'Refusing cleanup ownership for %s %s\n' "$1" "$2" >&2
}

# Docker renders an absent label as an empty field, which never equals an
# expected project, service or network value.
cleanup_read_container_identity() {
  cleanup_identity=$(docker container inspect "$1" --format \
    '{{.Name}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}|{{index .Config.Labels "com.docker.compose.oneoff"}}') ||
    return 1
  cleanup_identity_name=${cleanup_identity%%|*}
  cleanup_identity_name=${cleanup_identity_name#/}
  cleanup_identity_rest=${cleanup_identity#*|}
  cleanup_identity_project=${cleanup_identity_rest%%|*}
  cleanup_identity_rest=${cleanup_identity_rest#*|}
  cleanup_identity_service=${cleanup_identity_rest%%|*}
  cleanup_identity_oneoff=${cleanup_identity_rest#*|}
}

cleanup_read_network_identity() {
  cleanup_identity=$(docker network inspect "$1" --format \
    '{{.Name}}|{{index .Labels "com.docker.compose.project"}}|{{index .Labels "com.docker.compose.network"}}') ||
    return 1
  cleanup_identity_name=${cleanup_identity%%|*}
  cleanup_identity_rest=${cleanup_identity#*|}
  cleanup_identity_project=${cleanup_identity_rest%%|*}
  cleanup_identity_network=${cleanup_identity_rest#*|}
}

# The media-control bridge is created by host_prep rather than by Compose, so it
# carries the platform labels instead of the Compose ones. Its whole label set is
# read back: an extra label means the network is not the one this run created.
cleanup_read_media_control_identity() {
  cleanup_identity=$(docker network inspect "$1" --format \
    '{{.Name}}|{{.Driver}}|{{index .Labels "nas.platform.purpose"}}|{{index .Labels "nas.platform.project"}}|{{len .Labels}}') ||
    return 1
  cleanup_identity_name=${cleanup_identity%%|*}
  cleanup_identity_rest=${cleanup_identity#*|}
  cleanup_identity_driver=${cleanup_identity_rest%%|*}
  cleanup_identity_rest=${cleanup_identity_rest#*|}
  cleanup_identity_purpose=${cleanup_identity_rest%%|*}
  cleanup_identity_rest=${cleanup_identity_rest#*|}
  cleanup_identity_project=${cleanup_identity_rest%%|*}
  cleanup_identity_label_count=${cleanup_identity_rest#*|}
}

# Maps an observed namespaced identity back to the project that must own it. A
# name no registered project claims is never owned, so the caller refuses it.
cleanup_named_container_kind() {
  for cleanup_named_kind in $cleanup_sandbox_projects; do
    cleanup_sandbox_project_services "$cleanup_named_kind" || return 1
    for cleanup_named_service in $cleanup_project_services; do
      [ "$1" = "$cleanup_owner_namespace-$cleanup_named_service" ] || continue
      return 0
    done
  done
  return 1
}

cleanup_named_network_kind() {
  for cleanup_named_kind in $cleanup_sandbox_projects; do
    [ "$1" = "$cleanup_owner_namespace-${cleanup_named_kind}_default" ] || continue
    return 0
  done
  return 1
}

# A Configarr one-shot is owned only when its generated name, its service label
# and its one-off label all match. Its run suffix is generated, so the name is
# matched by prefix and alphabet rather than by an exact string.
cleanup_owns_configarr_container() {
  [ "$cleanup_identity_project" = "$cleanup_owner_namespace-arr" ] || return 1
  cleanup_configarr_prefix=$cleanup_owner_namespace-arr-configarr-run-
  case $cleanup_identity_name in
    "$cleanup_configarr_prefix"?*) ;;
    *) return 1 ;;
  esac
  cleanup_configarr_suffix=${cleanup_identity_name#"$cleanup_configarr_prefix"}
  case $cleanup_configarr_suffix in
    *[!abcdefghijklmnopqrstuvwxyz0123456789]*) return 1 ;;
  esac
  [ "$cleanup_identity_service" = configarr ] || return 1
  [ "$cleanup_identity_oneoff" = True ] || return 1
}

cleanup_owns_permanent_container() {
  cleanup_sandbox_project_services "$cleanup_owner_kind" || return 1
  for cleanup_permanent_service in $cleanup_project_services; do
    [ "$cleanup_identity_name" = "$cleanup_owner_namespace-$cleanup_permanent_service" ] ||
      continue
    [ "$cleanup_identity_project" = "$cleanup_owner_project" ] || return 1
    return 0
  done
  return 1
}

# Collects every resource carrying an exact project label for one namespace and
# refuses the whole sandbox unless each one also carries the exact name and
# supporting labels its creator gives it. Nothing is deleted here: an ownership
# mismatch must leave every collected resource in place.
cleanup_collect_namespace_ownership() {
  cleanup_owner_namespace=$1

  # Repeated Docker name filters are ORed, so every namespaced container name is
  # probed in one observation instead of one round trip per registered service.
  set --
  for cleanup_owner_kind in $cleanup_sandbox_projects; do
    cleanup_sandbox_project_services "$cleanup_owner_kind" || return 1
    for cleanup_owner_service in $cleanup_project_services; do
      set -- "$@" --filter "name=^$cleanup_owner_namespace-$cleanup_owner_service\$"
    done
  done
  cleanup_owner_ids=$(docker ps -aq --no-trunc "$@") || return 1
  for cleanup_owner_id in $cleanup_owner_ids; do
    cleanup_read_container_identity "$cleanup_owner_id" || return 1
    if ! cleanup_named_container_kind "$cleanup_identity_name" ||
       [ "$cleanup_identity_project" != \
         "$cleanup_owner_namespace-$cleanup_named_kind" ]; then
      cleanup_refuse_ownership container "$cleanup_identity_name"
      return 1
    fi
  done

  set --
  for cleanup_owner_kind in $cleanup_sandbox_projects; do
    set -- "$@" \
      --filter "name=^$cleanup_owner_namespace-${cleanup_owner_kind}_default\$"
  done
  cleanup_owner_ids=$(docker network ls -q --no-trunc "$@") || return 1
  for cleanup_owner_id in $cleanup_owner_ids; do
    cleanup_read_network_identity "$cleanup_owner_id" || return 1
    if ! cleanup_named_network_kind "$cleanup_identity_name" ||
       [ "$cleanup_identity_project" != \
         "$cleanup_owner_namespace-$cleanup_named_kind" ] ||
       [ "$cleanup_identity_network" != default ]; then
      cleanup_refuse_ownership network "$cleanup_identity_name"
      return 1
    fi
  done

  for cleanup_owner_kind in $cleanup_sandbox_projects; do
    cleanup_owner_project=$cleanup_owner_namespace-$cleanup_owner_kind
    cleanup_owner_ids=$(docker ps -aq --no-trunc \
      --filter "label=com.docker.compose.project=$cleanup_owner_project") || return 1
    for cleanup_owner_id in $cleanup_owner_ids; do
      cleanup_read_container_identity "$cleanup_owner_id" || return 1
      if ! cleanup_owns_permanent_container &&
         ! cleanup_owns_configarr_container; then
        cleanup_refuse_ownership container "$cleanup_identity_name"
        return 1
      fi
      cleanup_owned_containers="$cleanup_owned_containers $cleanup_owner_id"
    done
  done

  for cleanup_owner_kind in $cleanup_sandbox_projects; do
    cleanup_owner_project=$cleanup_owner_namespace-$cleanup_owner_kind
    cleanup_owner_ids=$(docker network ls -q --no-trunc \
      --filter "label=com.docker.compose.project=$cleanup_owner_project") || return 1
    for cleanup_owner_id in $cleanup_owner_ids; do
      cleanup_read_network_identity "$cleanup_owner_id" || return 1
      # The name probe above already rejected a mislabelled ${project}_default.
      # This is a second observation of daemon state, so it repeats the label
      # check rather than trusting the earlier round trip.
      if [ "$cleanup_identity_name" != "${cleanup_owner_project}_default" ] ||
         [ "$cleanup_identity_network" != default ]; then
        cleanup_refuse_ownership network "$cleanup_identity_name"
        return 1
      fi
      cleanup_owned_networks="$cleanup_owned_networks $cleanup_owner_id"
    done
  done

  # host_prep, not Compose, creates the media-control bridge, so it is found by
  # its namespace-derived name and by its platform labels. Both observations must
  # agree on one network, and its complete identity must match, or the sandbox is
  # refused with nothing deleted.
  cleanup_owner_media_network=$cleanup_owner_namespace-media-control
  cleanup_owner_ids=$(docker network ls -q --no-trunc \
    --filter "name=^${cleanup_owner_media_network}$") || return 1
  cleanup_owner_label_ids=$(docker network ls -q --no-trunc \
    --filter label=nas.platform.purpose=media-control \
    --filter "label=nas.platform.project=$cleanup_owner_namespace") || return 1
  for cleanup_owner_id in $cleanup_owner_label_ids; do
    case " $cleanup_owner_ids " in
      *" $cleanup_owner_id "*) ;;
      *)
        cleanup_refuse_ownership network "$cleanup_owner_media_network"
        return 1
        ;;
    esac
  done
  for cleanup_owner_id in $cleanup_owner_ids; do
    cleanup_read_media_control_identity "$cleanup_owner_id" || return 1
    if [ "$cleanup_identity_name" != "$cleanup_owner_media_network" ] ||
       [ "$cleanup_identity_driver" != bridge ] ||
       [ "$cleanup_identity_purpose" != media-control ] ||
       [ "$cleanup_identity_project" != "$cleanup_owner_namespace" ] ||
       [ "$cleanup_identity_label_count" != 2 ]; then
      cleanup_refuse_ownership network "$cleanup_owner_media_network"
      return 1
    fi
    cleanup_owned_networks="$cleanup_owned_networks $cleanup_owner_id"
  done
}

# One disposable run owns two project namespaces: the sandbox namespace every
# service is deployed under, and the scenario namespace the Immich negative
# restore matrix converges into.
cleanup_sandbox_namespaces() {
  printf '%s %s-negative' "$1" "$1"
}

cleanup_collect_sandbox_ownership() {
  cleanup_owned_containers=
  cleanup_owned_networks=
  for cleanup_collected_namespace in $(cleanup_sandbox_namespaces "$1"); do
    cleanup_collect_namespace_ownership "$cleanup_collected_namespace" || return 1
  done
}

cleanup_sandbox() {
  cleanup_sandbox_path=${1-}
  cleanup_temporary_parent=${TMPDIR:-/tmp}

  case "$cleanup_sandbox_path" in
    /*) ;;
    *)
      printf 'refusing to remove unexpected sandbox path: %s\n' "$cleanup_sandbox_path" >&2
      return 1
      ;;
  esac

  cleanup_sandbox_parent=${cleanup_sandbox_path%/*}
  cleanup_sandbox_name=${cleanup_sandbox_path##*/}

  cleanup_expected_parent=$(CDPATH= cd -P "$cleanup_temporary_parent" 2>/dev/null && pwd -P) || return 1
  cleanup_actual_parent=$(CDPATH= cd -P "$cleanup_sandbox_parent" 2>/dev/null && pwd -P) || cleanup_actual_parent=

  case "$cleanup_sandbox_name" in
    nas-platform-integration.??????|nas-platform-cleanup.??????) ;;
    *) cleanup_actual_parent= ;;
  esac
  cleanup_sandbox_suffix=${cleanup_sandbox_name##*.}
  case "$cleanup_sandbox_suffix" in
    *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789]*) cleanup_actual_parent= ;;
  esac

  cleanup_sandbox_target=$cleanup_expected_parent/$cleanup_sandbox_name

  if [ -z "$cleanup_sandbox_path" ] ||
     [ "$cleanup_actual_parent" != "$cleanup_expected_parent" ] ||
     [ ! -d "$cleanup_sandbox_target" ] ||
     [ -L "$cleanup_sandbox_target" ]; then
    printf 'refusing to remove unexpected sandbox path: %s\n' "$cleanup_sandbox_path" >&2
    return 1
  fi

  cleanup_namespace_suffix=$(printf '%s' "$cleanup_sandbox_suffix" |
    tr '[:upper:]' '[:lower:]') || return 1
  cleanup_sandbox_namespace=${cleanup_sandbox_name%.*}-$cleanup_namespace_suffix
  case "$cleanup_sandbox_namespace" in
    nas-platform-integration-[a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9]) ;;
    nas-platform-cleanup-[a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9]) ;;
    *)
      printf 'refusing to derive a cleanup namespace from: %s\n' "$cleanup_sandbox_name" >&2
      return 1
      ;;
  esac

  cleanup_collect_sandbox_ownership "$cleanup_sandbox_namespace" || return 1

  for cleanup_owned_container in $cleanup_owned_containers; do
    docker rm -f "$cleanup_owned_container" >/dev/null || return 1
  done

  for cleanup_owned_network in $cleanup_owned_networks; do
    docker network rm "$cleanup_owned_network" >/dev/null || return 1
  done

  if [ ! -d "$cleanup_sandbox_target" ] || [ -L "$cleanup_sandbox_target" ]; then
    printf 'refusing to remove unexpected sandbox path: %s\n' "$cleanup_sandbox_path" >&2
    return 1
  fi

  cleanup_sandbox_contents "$cleanup_expected_parent" "$cleanup_sandbox_name" || return 1
  rmdir "$cleanup_sandbox_target"
}

cleanup_sandbox_on_exit() {
  cleanup_exit_path=$1
  cleanup_exit_status=$2
  trap - EXIT HUP INT TERM
  if ! cleanup_sandbox "$cleanup_exit_path"; then
    [ "$cleanup_exit_status" -ne 0 ] || cleanup_exit_status=1
  fi
  exit "$cleanup_exit_status"
}
