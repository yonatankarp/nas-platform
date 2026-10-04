#!/bin/sh

cleanup_sandbox_image=docker.io/library/python:3.14-alpine@sha256:f6a589d43c42b9e7f7dc67a12d37132491f362859a5d750607710cc56da3bc72
# Nothing is deleted by a fixed production name: resources are found by exact
# Compose ownership labels and matched against their exact namespaced identity.
cleanup_sandbox_projects='beszel dozzle audiobookshelf komga jellyfin immich paperless'
cleanup_sandbox_projects="$cleanup_sandbox_projects arr downloaders bindery kapowarr pinchflat trailarr"
cleanup_sandbox_projects="$cleanup_sandbox_projects seerr nextcloud vaultwarden karakeep"
cleanup_sandbox_beszel_services='beszel beszel-agent-intel beszel-agent-portable beszel-socket-proxy'
cleanup_sandbox_dozzle_services='dozzle dozzle-alert-relay dozzle-socket-proxy'
cleanup_sandbox_audiobookshelf_services='audiobookshelf'
cleanup_sandbox_komga_services='komga'
cleanup_sandbox_jellyfin_services='jellyfin'
cleanup_sandbox_immich_services='immich-server immich-machine-learning immich-redis immich-postgres'
cleanup_sandbox_paperless_services='paperless-redis paperless-postgres paperless-webserver'
cleanup_sandbox_paperless_services="$cleanup_sandbox_paperless_services paperless-gotenberg paperless-tika"
cleanup_sandbox_arr_services='radarr sonarr prowlarr bazarr'
cleanup_sandbox_downloaders_services='sabnzbd unpackerr clamav'
cleanup_sandbox_bindery_services='bindery'
cleanup_sandbox_kapowarr_services='kapowarr'
cleanup_sandbox_pinchflat_services='pinchflat'
cleanup_sandbox_trailarr_services='trailarr'
cleanup_sandbox_seerr_services='seerr'
cleanup_sandbox_nextcloud_services='nextcloud nextcloud-cron nextcloud-db nextcloud-cache'
cleanup_sandbox_vaultwarden_services='vaultwarden'
cleanup_sandbox_karakeep_services='karakeep karakeep-chrome karakeep-meilisearch'

# The program is tests/sandbox_cleanup_contents.py, read by the container on stdin.
# A sourced file cannot find itself, so every source site sets
# cleanup_sandbox_repo_dir (policy_integration_test holds it); the fallback is
# only for the one caller that runs this file.
: "${cleanup_sandbox_repo_dir:=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)}"
cleanup_sandbox_program_path=$cleanup_sandbox_repo_dir/tests/sandbox_cleanup_contents.py

cleanup_sandbox_contents() {
  cleanup_contents_parent=$1
  cleanup_contents_name=$2
  cleanup_contents_preserve=${3-}

  [ -f "$cleanup_sandbox_program_path" ] && [ ! -L "$cleanup_sandbox_program_path" ] || {
    printf 'sandbox cleanup program is absent: %s\n' "$cleanup_sandbox_program_path" >&2
    return 1
  }
  docker run --rm -i \
    -v "$cleanup_contents_parent:/sandbox-parent" "$cleanup_sandbox_image" \
    python - "$cleanup_contents_name" "$cleanup_contents_preserve" \
    < "$cleanup_sandbox_program_path"
}

cleanup_sandbox_project_services() {
  case $1 in
    beszel) cleanup_project_services=$cleanup_sandbox_beszel_services ;;
    dozzle) cleanup_project_services=$cleanup_sandbox_dozzle_services ;;
    audiobookshelf) cleanup_project_services=$cleanup_sandbox_audiobookshelf_services ;;
    komga) cleanup_project_services=$cleanup_sandbox_komga_services ;;
    jellyfin) cleanup_project_services=$cleanup_sandbox_jellyfin_services ;;
    immich) cleanup_project_services=$cleanup_sandbox_immich_services ;;
    paperless) cleanup_project_services=$cleanup_sandbox_paperless_services ;;
    arr) cleanup_project_services=$cleanup_sandbox_arr_services ;;
    downloaders) cleanup_project_services=$cleanup_sandbox_downloaders_services ;;
    bindery) cleanup_project_services=$cleanup_sandbox_bindery_services ;;
    kapowarr) cleanup_project_services=$cleanup_sandbox_kapowarr_services ;;
    pinchflat) cleanup_project_services=$cleanup_sandbox_pinchflat_services ;;
    trailarr) cleanup_project_services=$cleanup_sandbox_trailarr_services ;;
    seerr) cleanup_project_services=$cleanup_sandbox_seerr_services ;;
    nextcloud) cleanup_project_services=$cleanup_sandbox_nextcloud_services ;;
    vaultwarden) cleanup_project_services=$cleanup_sandbox_vaultwarden_services ;;
    karakeep) cleanup_project_services=$cleanup_sandbox_karakeep_services ;;
    *)
      printf 'unknown sandbox cleanup project kind: %s\n' "$1" >&2
      return 1
      ;;
  esac
}

# The Compose network keys each project may create; a network is owned only under
# a key declared here, so an undeclared key makes cleanup refuse (#829).
cleanup_sandbox_project_networks() {
  case $1 in
    karakeep) cleanup_project_networks='default browser search' ;;
    beszel) cleanup_project_networks='default docker-api docker-api-publish' ;;
    dozzle) cleanup_project_networks='default docker-api' ;;
    audiobookshelf | komga | jellyfin | immich | paperless | \
      arr | downloaders | bindery | kapowarr | pinchflat | trailarr | seerr | \
      nextcloud | vaultwarden)
      cleanup_project_networks=default
      ;;
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

# host_prep creates this bridge, so it carries platform labels; an extra label
# means it is not the network this run created.
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
    cleanup_sandbox_project_networks "$cleanup_named_kind" || return 1
    for cleanup_named_network in $cleanup_project_networks; do
      [ "$1" = "$cleanup_owner_namespace-${cleanup_named_kind}_$cleanup_named_network" ] ||
        continue
      return 0
    done
  done
  return 1
}

# A Compose network under a project label is owned only when its name is that
# project's name for a declared key and its network label is that same key.
cleanup_owns_compose_network() {
  cleanup_sandbox_project_networks "$cleanup_owner_kind" || return 1
  for cleanup_owned_key in $cleanup_project_networks; do
    [ "$cleanup_identity_name" = "${cleanup_owner_project}_$cleanup_owned_key" ] ||
      continue
    [ "$cleanup_identity_network" = "$cleanup_owned_key" ] || return 1
    return 0
  done
  return 1
}

# A Configarr one-shot: name matched by prefix and alphabet (the run suffix is
# generated), plus its service and one-off labels.
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

# Refuses the whole sandbox unless every project-labelled resource also carries
# its creator's exact name and labels. Nothing is deleted here.
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
    cleanup_sandbox_project_networks "$cleanup_owner_kind" || return 1
    for cleanup_owner_network in $cleanup_project_networks; do
      set -- "$@" --filter \
        "name=^$cleanup_owner_namespace-${cleanup_owner_kind}_$cleanup_owner_network\$"
    done
  done
  cleanup_owner_ids=$(docker network ls -q --no-trunc "$@") || return 1
  for cleanup_owner_id in $cleanup_owner_ids; do
    cleanup_read_network_identity "$cleanup_owner_id" || return 1
    if ! cleanup_named_network_kind "$cleanup_identity_name" ||
       [ "$cleanup_identity_project" != \
         "$cleanup_owner_namespace-$cleanup_named_kind" ] ||
       [ "$cleanup_identity_network" != "$cleanup_named_network" ]; then
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
      # A second observation of daemon state, so the label check is repeated.
      if ! cleanup_owns_compose_network; then
        cleanup_refuse_ownership network "$cleanup_identity_name"
        return 1
      fi
      cleanup_owned_networks="$cleanup_owned_networks $cleanup_owner_id"
    done
  done

  # host_prep-created bridges: name and platform labels must agree on one
  # network with a complete identity match, or nothing is deleted.
  for cleanup_owner_purpose in media-control alert-relay; do
    cleanup_owner_media_network=$cleanup_owner_namespace-$cleanup_owner_purpose
    cleanup_owner_ids=$(docker network ls -q --no-trunc \
      --filter "name=^${cleanup_owner_media_network}$") || return 1
    cleanup_owner_label_ids=$(docker network ls -q --no-trunc \
      --filter label=nas.platform.purpose=$cleanup_owner_purpose \
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
         [ "$cleanup_identity_purpose" != "$cleanup_owner_purpose" ] ||
         [ "$cleanup_identity_project" != "$cleanup_owner_namespace" ] ||
         [ "$cleanup_identity_label_count" != 2 ]; then
        cleanup_refuse_ownership network "$cleanup_owner_media_network"
        return 1
      fi
      cleanup_owned_networks="$cleanup_owned_networks $cleanup_owner_id"
    done
  done
}

# Two namespaces per run: the sandbox, and the Immich negative restore matrix's.
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
