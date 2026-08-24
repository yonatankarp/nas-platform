#!/bin/sh
set -eu
set +x
umask 077

: "${PLATFORM_PROJECT_NAME:?PLATFORM_PROJECT_NAME is required}"
: "${PLATFORM_MEDIA_ROOT:?PLATFORM_MEDIA_ROOT is required}"

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_hook_dir/../../../.." && pwd -P)

case $PLATFORM_PROJECT_NAME in
  ''|[-_]*|*[!abcdefghijklmnopqrstuvwxyz0123456789_-]*)
    printf '%s\n' 'media acquisition drift: invalid project namespace' >&2
    exit 1
    ;;
esac

network=$PLATFORM_PROJECT_NAME-media-control
audiobookshelf=$PLATFORM_PROJECT_NAME-audiobookshelf
jellyfin=$PLATFORM_PROJECT_NAME-jellyfin
audiobookshelf_project=$PLATFORM_PROJECT_NAME-audiobookshelf
jellyfin_project=$PLATFORM_PROJECT_NAME-jellyfin
leaf=$PLATFORM_MEDIA_ROOT/Media/.acquisition/usenet/movies
original_uid=$(id -u)

audiobook_disconnect_started=false
jellyfin_disconnect_started=false
network_removal_started=false
leaf_removal_started=false
media_acquisition_signal=
media_acquisition_recovery_failed=false

network_record() {
  docker network inspect "$network" --format \
    '{{.Name}}|{{.Driver}}|{{index .Labels "nas.platform.purpose"}}|{{index .Labels "nas.platform.project"}}'
}

require_network() {
  [ "$(network_record)" = "$network|bridge|media-control|$PLATFORM_PROJECT_NAME" ] &&
    [ "$(docker network inspect "$network" --format '{{range $key, $value := .Labels}}{{$key}}={{$value}}|{{end}}' |
      tr '|' '\n' | sed '/^$/d' | LC_ALL=C sort)" = "$(printf '%s\n%s\n' \
      "nas.platform.project=$PLATFORM_PROJECT_NAME" 'nas.platform.purpose=media-control' | LC_ALL=C sort)" ]
}

container_record() {
  docker inspect "$1" --format \
    '{{.Name}}|com.docker.compose.service={{index .Config.Labels "com.docker.compose.service"}}|com.docker.compose.project={{index .Config.Labels "com.docker.compose.project"}}'
}

network_endpoints() {
  docker network inspect "$network" --format '{{range .Containers}}{{.Name}}|{{end}}' |
    tr '|' '\n' | sed '/^$/d' | LC_ALL=C sort
}

network_endpoint_ids() {
  docker network inspect "$network" --format '{{range $id, $_ := .Containers}}{{$id}}|{{end}}' |
    tr '|' '\n' | sed '/^$/d' | LC_ALL=C sort
}

network_keys() {
  docker inspect "$1" --format '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}}|{{end}}' |
    tr '|' '\n' | sed '/^$/d' | LC_ALL=C sort
}

require_exact_endpoints() {
  [ "$(network_endpoints)" = "$(printf '%s\n%s\n' "$audiobookshelf" "$jellyfin" | LC_ALL=C sort)" ] &&
    [ "$(network_endpoint_ids)" = "$(printf '%s\n%s\n' \
      "$(docker inspect "$audiobookshelf" --format '{{.Id}}')" \
      "$(docker inspect "$jellyfin" --format '{{.Id}}')" | LC_ALL=C sort)" ]
}

require_leaf_parent() {
  [ -d "$PLATFORM_MEDIA_ROOT" ] && [ ! -L "$PLATFORM_MEDIA_ROOT" ] || return 1
  canonical_media_root=$(CDPATH= cd -- "$PLATFORM_MEDIA_ROOT" && pwd -P) || return 1
  [ "$canonical_media_root" = "$PLATFORM_MEDIA_ROOT" ] || return 1
  leaf_parent=${leaf%/*}
  [ -d "$leaf_parent" ] && [ ! -L "$leaf_parent" ] || return 1
  canonical_leaf_parent=$(CDPATH= cd -- "$leaf_parent" && pwd -P) || return 1
  [ "$canonical_leaf_parent" = "$leaf_parent" ] || return 1
  case $canonical_leaf_parent/ in "$canonical_media_root"/*) ;; *) return 1 ;; esac
}

require_leaf() {
  require_leaf_parent || return 1
  [ -d "$leaf" ] && [ ! -L "$leaf" ] || return 1
  [ "$(find "$leaf" -mindepth 1 -maxdepth 1 -print -quit)" = '' ] || return 1
  case $(uname -s) in
    Darwin) leaf_mode=$(stat -f '%Lp' "$leaf"); leaf_uid=$(stat -f '%u' "$leaf") ;;
    *) leaf_mode=$(stat -c '%a' "$leaf"); leaf_uid=$(stat -c '%u' "$leaf") ;;
  esac
  [ "$leaf_mode" = 755 ] && [ "$leaf_uid" = "$original_uid" ]
}

recreate_network() {
  docker network create --driver bridge \
    --label nas.platform.purpose=media-control \
    --label "nas.platform.project=$PLATFORM_PROJECT_NAME" \
    "$network" >/dev/null
}

reader_on_network() {
  network_keys "$1" | grep -Fqx -- "$network"
}

media_acquisition_recover() {
  media_acquisition_status=$?
  trap - EXIT HUP INT TERM
  if [ "$network_removal_started" = true ] || ! docker network inspect "$network" >/dev/null 2>&1; then
    docker network inspect "$network" >/dev/null 2>&1 || recreate_network || media_acquisition_recovery_failed=true
  fi
  require_network || media_acquisition_recovery_failed=true
  if [ "$audiobook_disconnect_started" = true ] && ! reader_on_network "$audiobookshelf"; then
    docker network connect "$network" "$audiobookshelf" >/dev/null || media_acquisition_recovery_failed=true
  fi
  if [ "$jellyfin_disconnect_started" = true ] && ! reader_on_network "$jellyfin"; then
    docker network connect "$network" "$jellyfin" >/dev/null || media_acquisition_recovery_failed=true
  fi
  require_exact_endpoints || media_acquisition_recovery_failed=true
  [ "$(network_keys "$audiobookshelf")" = "$audiobookshelf_default_networks" ] || media_acquisition_recovery_failed=true
  [ "$(network_keys "$jellyfin")" = "$jellyfin_default_networks" ] || media_acquisition_recovery_failed=true
  if [ "$leaf_removal_started" = true ] || [ ! -d "$leaf" ]; then
    require_leaf_parent || media_acquisition_recovery_failed=true
    if [ "$media_acquisition_recovery_failed" = false ]; then
      mkdir "$leaf" && chmod 0755 "$leaf" || media_acquisition_recovery_failed=true
    fi
  fi
  require_leaf || media_acquisition_recovery_failed=true
  [ "$media_acquisition_recovery_failed" = false ] || [ "$media_acquisition_status" -ne 0 ] || media_acquisition_status=1
  if [ -n "$media_acquisition_signal" ]; then
    kill -s "$media_acquisition_signal" "$$"
  fi
  exit "$media_acquisition_status"
}

media_acquisition_handle_hup() { media_acquisition_signal=HUP; exit 129; }
media_acquisition_handle_int() { media_acquisition_signal=INT; exit 130; }
media_acquisition_handle_term() { media_acquisition_signal=TERM; exit 143; }

require_network
[ "$(container_record "$audiobookshelf")" = "/$audiobookshelf|com.docker.compose.service=audiobookshelf|com.docker.compose.project=$audiobookshelf_project" ]
[ "$(container_record "$jellyfin")" = "/$jellyfin|com.docker.compose.service=jellyfin|com.docker.compose.project=$jellyfin_project" ]
require_exact_endpoints
audiobookshelf_default_networks=$(network_keys "$audiobookshelf")
jellyfin_default_networks=$(network_keys "$jellyfin")
[ "$audiobookshelf_default_networks" = "$(printf '%s\n%s\n' "$PLATFORM_PROJECT_NAME-audiobookshelf_default" "$network" | LC_ALL=C sort)" ]
[ "$jellyfin_default_networks" = "$(printf '%s\n%s\n' "$PLATFORM_PROJECT_NAME-jellyfin_default" "$network" | LC_ALL=C sort)" ]
require_leaf
ruby -ryaml -e '
  inventory = YAML.safe_load_file(ARGV.fetch(0))
  entry = inventory.fetch("nas_storage").find do |item|
    item["path"] == "{{ nas_media_root }}/Media/.acquisition/usenet/movies"
  end
  abort unless entry && !entry.key?("owner") && !entry.key?("group")
' "$mac_repo_dir/inventory/group_vars/all/main.yml"

trap media_acquisition_recover EXIT
trap media_acquisition_handle_hup HUP
trap media_acquisition_handle_int INT
trap media_acquisition_handle_term TERM

audiobook_disconnect_started=true
docker network disconnect "$network" "$audiobookshelf"
jellyfin_disconnect_started=true
docker network disconnect "$network" "$jellyfin"
network_removal_started=true
docker network rm "$network"
leaf_removal_started=true
rmdir -- "$leaf"

trap - EXIT HUP INT TERM
printf '%s\n' 'media acquisition drift: exact isolated network and empty cache leaf removed'
