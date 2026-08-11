#!/bin/sh
set -eu
set +x

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$script_dir/lib.sh"

[ "${PLATFORM_ADOPTION_ENABLED:-}" = true ] || {
  printf '%s\n' 'adoption-stop-error: adoption context is invalid' >&2
  exit 1
}
sandbox=$(mac_validate_sandbox "${PLATFORM_ADOPTION_ROOT:-}" 2>/dev/null) || {
  printf '%s\n' 'adoption-stop-error: adoption context is invalid' >&2
  exit 1
}
sandbox_suffix=${sandbox##*.}
owned_project=nas-platform-mac-$(printf '%s' "$sandbox_suffix" | tr '[:upper:]' '[:lower:]')
case ${PLATFORM_PROJECT_NAME:-} in
  nas-platform-mac-*)
    project_suffix=${PLATFORM_PROJECT_NAME#nas-platform-mac-}
    case $project_suffix in
      ''|*[!a-z0-9]*) printf '%s\n' 'adoption-stop-error: project name is invalid' >&2; exit 1 ;;
    esac
    ;;
  *) printf '%s\n' 'adoption-stop-error: project name is invalid' >&2; exit 1 ;;
esac
[ "$PLATFORM_PROJECT_NAME" = "$owned_project" ] || {
  printf '%s\n' 'adoption-stop-error: project name differs from owned sandbox' >&2
  exit 1
}

status=0
for suffix in audiobookshelf beszel dozzle immich jellyfin komga ntfy paperless tinymediamanager; do
  ids=$(docker ps -q --filter "label=com.docker.compose.project=$PLATFORM_PROJECT_NAME-$suffix") || {
    status=1
    continue
  }
  [ -z "$ids" ] || docker stop $ids >/dev/null 2>&1 || status=1
done
exit "$status"
