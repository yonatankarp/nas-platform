#!/bin/sh
set -eu
set +x

mac_hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_hook_dir/../../../.." && pwd -P)
. "$mac_repo_dir/tests/mac/lib.sh"

: "${PLATFORM_PROJECT_NAME:?PLATFORM_PROJECT_NAME is required}"
: "${PLATFORM_MAC_VAULT_FILE:?PLATFORM_MAC_VAULT_FILE is required}"
: "${PLATFORM_MAC_VAULT_PASSWORD_FILE:?PLATFORM_MAC_VAULT_PASSWORD_FILE is required}"
: "${PLATFORM_MAC_FIXTURE_VARS_FILE:?PLATFORM_MAC_FIXTURE_VARS_FILE is required}"

network=$PLATFORM_PROJECT_NAME-media-control

mac_ansible_playbook -i "$mac_repo_dir/inventory/mac.yml" "$mac_repo_dir/verify.yml" \
  --vault-password-file "$PLATFORM_MAC_VAULT_PASSWORD_FILE" \
  -e @"$PLATFORM_MAC_VAULT_FILE" \
  -e @"$PLATFORM_MAC_FIXTURE_VARS_FILE" \
  -e "platform_vault_file=$PLATFORM_MAC_VAULT_FILE" \
  -e "platform_media_control_network=$network" \
  -e media_usenet_enabled=false -e media_torrent_enabled=false \
  --tags platform_verify_media_acquisition_foundation

for reader in audiobookshelf jellyfin; do
  container=$PLATFORM_PROJECT_NAME-$reader
  expected=$(printf '%s\n%s\n' "$PLATFORM_PROJECT_NAME-${reader}_default" "$network" | LC_ALL=C sort)
  actual=$(docker inspect "$container" --format \
    '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}}|{{end}}' |
    tr '|' '\n' | sed '/^$/d' | LC_ALL=C sort)
  [ "$actual" = "$expected" ]
done

for catalog in radarr sonarr prowlarr bazarr configarr sabnzbd unpackerr gluetun qbittorrent bindery kapowarr trailarr seerr; do
  [ -z "$(docker ps -aq --filter "name=^/$catalog$")" ]
  [ -z "$(docker ps -aq --filter "name=^/$PLATFORM_PROJECT_NAME-$catalog$")" ]
done

# The standalone verifier proves all 28 media_acquisition_foundation entries by
# stat without listing any directory contents.
printf '%s\n' 'media acquisition verify: exact storage, transports, network, and readers hold'
