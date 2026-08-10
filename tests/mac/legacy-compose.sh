#!/bin/sh
set -eu
set +x
umask 077

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_dir=$(CDPATH= cd -- "$script_dir/../.." && pwd -P)
. "$script_dir/lib.sh"

die() {
  printf 'legacy-compose-error: %s\n' "$1" >&2
  exit 1
}

[ "$#" -eq 2 ] || die 'expected SERVICE ACTION'
service=$1
action=$2
case $service in
  audiobookshelf|beszel|dozzle|immich|jellyfin|komga|ntfy|paperless-ngx|tinymediamanager) ;;
  *) die 'unsupported service' ;;
esac
case $action in
  config|up|stop|start|ps|down) ;;
  *) die 'unsupported action' ;;
esac

: "${PLATFORM_LEGACY_ROOT:?legacy-compose-error: PLATFORM_LEGACY_ROOT is required}"
: "${PLATFORM_MAC_SANDBOX:?legacy-compose-error: PLATFORM_MAC_SANDBOX is required}"
: "${PLATFORM_PROJECT_NAME:?legacy-compose-error: PLATFORM_PROJECT_NAME is required}"
PLATFORM_MAC_SANDBOX=$(mac_validate_sandbox "$PLATFORM_MAC_SANDBOX" 2>/dev/null) ||
  die 'owned sandbox is invalid'
owned_project=$(sed -n 's/^project=//p' "$PLATFORM_MAC_SANDBOX/.nas-platform-mac-owned")
[ "$PLATFORM_PROJECT_NAME" = "$owned_project" ] || die 'project name differs from owned sandbox'

legacy_path=$(ruby -ryaml - "$repo_dir/services/manifest.yml" "$service" <<'RUBY'
manifest, requested = ARGV
services = YAML.safe_load_file(manifest, aliases: false).fetch("services")
entry = services.find { |candidate| candidate.fetch("name") == requested }
abort unless entry
path = entry.fetch("legacy_path")
abort unless path.is_a?(String) && path.match?(/\A[A-Za-z0-9_.\/-]+\z/) &&
  !path.start_with?("/") && !path.split("/").include?("..")
print path
RUBY
) || die 'service manifest is invalid'

base_file=$PLATFORM_LEGACY_ROOT/$legacy_path
override_file=$script_dir/legacy-overrides/$service.yml
env_file=$PLATFORM_MAC_SANDBOX/legacy-env/$service.env
[ -f "$base_file" ] && [ ! -L "$base_file" ] || die 'trusted legacy base file is unavailable'
[ -f "$override_file" ] && [ ! -L "$override_file" ] || die 'reviewed legacy override is unavailable'
[ -f "$env_file" ] && [ ! -L "$env_file" ] || die 'rendered legacy environment is unavailable'

run_compose() {
  if ! docker compose --env-file "$env_file" \
      --project-name "$PLATFORM_PROJECT_NAME-legacy-$service" \
      -f "$base_file" -f "$override_file" "$@" >/dev/null 2>&1; then
    die 'Compose action failed'
  fi
}

case $action in
  config) run_compose config --quiet ;;
  up) run_compose up --detach --wait --wait-timeout 600 ;;
  stop) run_compose stop ;;
  start) run_compose start ;;
  ps)
    expected_services=$(docker compose --env-file "$env_file" \
      --project-name "$PLATFORM_PROJECT_NAME-legacy-$service" \
      -f "$base_file" -f "$override_file" config --services 2>/dev/null) ||
      die 'Compose action failed'
    running_services=$(docker compose --env-file "$env_file" \
      --project-name "$PLATFORM_PROJECT_NAME-legacy-$service" \
      -f "$base_file" -f "$override_file" ps --status running --services 2>/dev/null) ||
      die 'Compose action failed'
    [ -n "$expected_services" ] &&
      [ "$(printf '%s\n' "$running_services" | LC_ALL=C sort)" = \
        "$(printf '%s\n' "$expected_services" | LC_ALL=C sort)" ] ||
      die 'legacy service is not running'
    ;;
  down) run_compose down ;;
esac
