#!/bin/sh

mac_die() {
  printf '%s\n' "$1" >&2
  return 1
}

mac_validate_lexical_path() {
  mac_path=$1
  mac_label=$2
  case $mac_path in
    /*) ;;
    *) mac_die "$mac_label must be absolute" ;;
  esac
  case $mac_path in
    /) ;;
    */|*//*|*/./*|*/../*|*/.|*/..) mac_die "$mac_label must be lexically normalized" ;;
  esac
}

mac_owner_id() {
  if [ "$(uname -s)" = Darwin ]; then
    stat -f '%u' "$1"
  else
    stat -c '%u' "$1"
  fi
}

mac_file_mode() {
  if [ "$(uname -s)" = Darwin ]; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

mac_canonical_directory() {
  mac_validate_lexical_path "$1" "$2" || return 1
  [ -d "$1" ] && [ ! -L "$1" ] || mac_die "$2 is unavailable or unsafe"
  CDPATH= cd -- "$1" 2>/dev/null && pwd -P
}

mac_temporary_parent() {
  mac_parent_input=${PLATFORM_MAC_TMPDIR:-${TMPDIR:-/tmp}}
  mac_parent_input=${mac_parent_input%/}
  [ -n "$mac_parent_input" ] || mac_parent_input=/
  mac_canonical_directory "$mac_parent_input" 'Mac temporary parent'
}

mac_validate_sandbox() {
  mac_requested=${1-}
  [ -n "$mac_requested" ] || mac_die 'refusing to remove unowned Mac sandbox: empty path'
  mac_validate_lexical_path "$mac_requested" 'Mac sandbox' || return 1
  [ "$mac_requested" != / ] || mac_die 'refusing to remove unowned Mac sandbox: /'
  [ -d "$mac_requested" ] && [ ! -L "$mac_requested" ] ||
    mac_die "refusing to remove unowned Mac sandbox: $mac_requested"

  mac_parent=$(mac_temporary_parent) || return 1
  mac_physical=$(CDPATH= cd -- "$mac_requested" 2>/dev/null && pwd -P) ||
    mac_die "refusing to remove unowned Mac sandbox: $mac_requested"
  [ "$mac_physical" = "$mac_requested" ] ||
    mac_die "refusing to remove unowned Mac sandbox: $mac_requested"
  [ "$(dirname -- "$mac_physical")" = "$mac_parent" ] ||
    mac_die "refusing to remove unowned Mac sandbox: $mac_requested"
  case $(basename -- "$mac_physical") in
    nas-platform-mac.??????) ;;
    *) mac_die "refusing to remove unowned Mac sandbox: $mac_requested" ;;
  esac
  mac_suffix=${mac_physical##*.}
  case $mac_suffix in
    *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789]*)
      mac_die "refusing to remove unowned Mac sandbox: $mac_requested"
      ;;
  esac
  [ "$(mac_owner_id "$mac_physical")" = "$(id -u)" ] &&
    [ "$(mac_file_mode "$mac_physical")" = 700 ] ||
    mac_die "refusing to remove unowned Mac sandbox: $mac_requested"

  mac_marker=$mac_physical/.nas-platform-mac-owned
  [ -f "$mac_marker" ] && [ ! -L "$mac_marker" ] &&
    [ "$(mac_owner_id "$mac_marker")" = "$(id -u)" ] &&
    [ "$(mac_file_mode "$mac_marker")" = 600 ] ||
    mac_die "refusing to remove unowned Mac sandbox: $mac_requested"
  grep -qx 'schema=1' "$mac_marker" ||
    mac_die "refusing to remove unowned Mac sandbox: $mac_requested"
  mac_project=$(sed -n 's/^project=//p' "$mac_marker")
  case $mac_project in
    nas-platform-mac-[abcdefghijklmnopqrstuvwxyz0123456789]*) ;;
    *) mac_die "refusing to remove unowned Mac sandbox: $mac_requested" ;;
  esac
  mac_project_suffix=$(printf '%s' "$mac_suffix" | tr '[:upper:]' '[:lower:]')
  [ "$mac_project" = "nas-platform-mac-$mac_project_suffix" ] ||
    mac_die "refusing to remove unowned Mac sandbox: $mac_requested"
  printf '%s\n' "$mac_physical"
}

mac_shell_quote() {
  case $1 in
    *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_./-]*)
      printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
      ;;
    *) printf '%s' "$1" ;;
  esac
}

mac_integration_gateway() {
  mac_gateway=$(docker network inspect bridge \
    --format '{{ (index .IPAM.Config 0).Gateway }}') ||
    mac_die 'integration Docker host address is unavailable'
  mac_validate_integration_callback "$mac_gateway"
}

mac_validate_integration_callback() {
  mac_gateway=$1
  ruby -ripaddr -e '
    value = ARGV.fetch(0)
    address = IPAddr.new(value)
    abort unless address.ipv4? && value == address.to_s &&
      value != "0.0.0.0" && !address.loopback? &&
      !IPAddr.new("224.0.0.0/4").include?(address)
    puts value
  ' "$mac_gateway" 2>/dev/null || mac_die 'integration Docker host address is invalid'
}

mac_ansible_playbook() {
  case ${PLATFORM_PROOF_PLATFORM:-mac} in
    mac)
      case ${PLATFORM_CALLBACK_HOST:-host.docker.internal} in
        host.docker.internal) ;;
        *) mac_die 'Mac callback host is invalid'; return 1 ;;
      esac
      command ansible-playbook "$@"
      ;;
    integration)
      mac_callback_host=${PLATFORM_CALLBACK_HOST:-}
      [ -n "$mac_callback_host" ] || {
        mac_die 'integration callback host is unavailable'
        return 1
      }
      mac_callback_host=$(mac_validate_integration_callback "$mac_callback_host") || return 1
      command ansible-playbook "$@" \
        -e platform_kind=mac -e platform_compose_kind=integration \
        -e deployment_bundle_test_mode=true \
        -e platform_manage_linux_ownership=true \
        -e "platform_callback_host=$mac_callback_host"
      ;;
    *) mac_die 'proof platform is invalid' ;;
  esac
}

mac_compose_files() {
  mac_current=$1
  set -- -f "$mac_current/compose.yml"
  mac_compose_kind=${PLATFORM_COMPOSE_KIND:-mac}
  case $mac_compose_kind in mac|integration) ;; *) mac_die 'compose kind is invalid' ;; esac
  if [ -f "$mac_current/compose.$mac_compose_kind.yml" ] &&
     [ ! -L "$mac_current/compose.$mac_compose_kind.yml" ]; then
    set -- "$@" -f "$mac_current/compose.$mac_compose_kind.yml"
  fi
  printf '%s\n' "$@"
}

mac_target_container_names() {
  mac_project=$1
  case ${PLATFORM_PROOF_PLATFORM:-mac} in
    integration)
      printf '%s\n' ntfy beszel beszel_agent beszel_agent_portable beszel_socket_proxy \
        dozzle_alert_relay dozzle dozzle_socket_proxy audiobookshelf komga tinymediamanager jellyfin \
        immich_server immich_machine_learning immich_redis immich_postgres \
        paperless_redis paperless_postgres paperless_webserver paperless_gotenberg paperless_tika
      ;;
    mac)
      printf '%s\n' "$mac_project-beszel" "$mac_project-beszel-agent-intel" \
        "$mac_project-beszel-agent-portable" "$mac_project-beszel-socket-proxy" \
        "$mac_project-ntfy" "$mac_project-dozzle-alert-relay" \
        "$mac_project-dozzle" "$mac_project-dozzle-socket-proxy" \
        "$mac_project-audiobookshelf" "$mac_project-komga" \
        "$mac_project-tinymediamanager" "$mac_project-jellyfin" \
        "$mac_project-immich-server" "$mac_project-immich-machine-learning" \
        "$mac_project-immich-redis" "$mac_project-immich-postgres" \
        "$mac_project-paperless-redis" "$mac_project-paperless-postgres" \
        "$mac_project-paperless-webserver" "$mac_project-paperless-gotenberg" \
        "$mac_project-paperless-tika"
      ;;
    *) mac_die 'proof platform is invalid' ;;
  esac
}

mac_run_hooks() {
  mac_hook_group=$1
  shift
  mac_hook_root=$mac_script_dir/hooks/$mac_hook_group
  [ -d "$mac_hook_root" ] || mac_die "No Mac hooks registered for $mac_hook_group"
  mac_hook_count=0
  for mac_hook in "$mac_hook_root"/*.sh; do
    [ -f "$mac_hook" ] || continue
    [ ! -L "$mac_hook" ] && [ -x "$mac_hook" ] ||
      mac_die "unsafe or non-executable Mac hook: $mac_hook"
    mac_hook_count=$((mac_hook_count + 1))
    "$mac_hook" "$@" || return 1
  done
  [ "$mac_hook_count" -gt 0 ] || mac_die "No Mac hooks registered for $mac_hook_group"
}
