#!/bin/sh
set -eu
set +x

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_dir=$(CDPATH= cd -- "$script_dir/../.." && pwd -P)
service=${1-}
mode=${2-}
[ "$#" -eq 2 ] || exit 2

export PLATFORM_CONTRACT_VAULT_FILE=${PLATFORM_MAC_VAULT_FILE:?}
export PLATFORM_CONTRACT_VAULT_PASSWORD_FILE=${PLATFORM_MAC_VAULT_PASSWORD_FILE:?}
case $service:$mode in
  audiobookshelf:seed-progress) exec "$repo_dir/tests/contracts/audiobookshelf.sh" seed-progress ;;
  komga:seed) exec "$repo_dir/tests/contracts/komga.sh" seed ;;
  tinymediamanager:seed) exec "$repo_dir/tests/contracts/tinymediamanager.sh" seed ;;
  jellyfin:seed) exec "$repo_dir/tests/contracts/jellyfin.sh" --platform mac seed ;;
  immich:seed) exec "$repo_dir/tests/contracts/immich.sh" --platform mac seed ;;
  paperless-ngx:seed) exec "$repo_dir/tests/contracts/paperless.sh" seed ;;
  *) exit 2 ;;
esac
