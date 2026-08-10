#!/bin/sh
set -eu
set +x

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
service=${1-}
mode=${2-}
[ "$#" -eq 2 ] || exit 2

case $service:$mode in
  audiobookshelf:seed-progress) exec "$script_dir/run-audiobookshelf-contract.sh" seed-progress ;;
  komga:seed) exec "$script_dir/run-komga-contract.sh" seed ;;
  tinymediamanager:seed) exec "$script_dir/run-tinymediamanager-contract.sh" seed ;;
  jellyfin:seed) exec "$script_dir/run-jellyfin-contract.sh" seed ;;
  immich:seed) exec "$script_dir/run-immich-contract.sh" seed ;;
  paperless-ngx:seed) exec "$script_dir/run-paperless-contract.sh" seed ;;
  *) exit 2 ;;
esac
