#!/bin/sh
set -eu
set +x
umask 077

test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
temporary_input=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-legacy-fixture-path.XXXXXX")
temporary_root=$(CDPATH= cd -- "$temporary_input" && pwd -P)
cleanup() {
  fixture_test_status=$?
  trap - EXIT HUP INT TERM
  /usr/bin/find "$temporary_root" -depth -delete
  exit "$fixture_test_status"
}
trap cleanup EXIT HUP INT TERM

fail() { printf '%s\n' "$1" >&2; exit 1; }
tab=$(printf '\t')

sandbox=$temporary_root/nas-platform-mac.Abc123
mkdir -m 0700 "$sandbox" "$sandbox/legacy" "$sandbox/legacy/komga" \
  "$sandbox/legacy/komga/library"
printf 'schema=1\nproject=nas-platform-mac-abc123\n' > "$sandbox/.nas-platform-mac-owned"
chmod 0600 "$sandbox/.nas-platform-mac-owned"

# shellcheck source=../contracts/legacy-fixture-paths.sh
[ -f "$test_dir/../contracts/legacy-fixture-paths.sh" ] || fail 'legacy fixture path validator is absent'
. "$test_dir/../contracts/legacy-fixture-paths.sh"
export PLATFORM_MAC_TMPDIR=$temporary_root
export PLATFORM_LEGACY_FIXTURE_MODE=nas-platform-owned-legacy-v1
export PLATFORM_LEGACY_FIXTURE_SANDBOX=$sandbox
export PLATFORM_KOMGA_LIBRARY_PATH=$sandbox/legacy/komga/library
legacy_fixture_validate PLATFORM_KOMGA_LIBRARY_PATH legacy/komga/library ||
  fail 'exact owned legacy fixture path was rejected'

default_parent=$temporary_root/default-tmp
default_sandbox=$default_parent/nas-platform-mac.Def456
mkdir -m 0700 "$default_parent" "$default_sandbox"
printf 'schema=1\nproject=nas-platform-mac-def456\n' > "$default_sandbox/.nas-platform-mac-owned"
chmod 0600 "$default_sandbox/.nas-platform-mac-owned"
default_driver=$default_sandbox/default-driver.sh
cat > "$default_driver" <<'SH'
#!/bin/sh
[ "${PLATFORM_MAC_TMPDIR:?}" = "${TMPDIR:?}" ] || exit 71
[ "$PLATFORM_LEGACY_FIXTURE_SANDBOX" = "${TMPDIR}/nas-platform-mac.Def456" ] || exit 72
[ "$PLATFORM_LEGACY_FIXTURE_MODE" = nas-platform-owned-legacy-v1 ] || exit 73
case $1:$2 in
  audiobookshelf:seed-progress|komga:seed|tinymediamanager:seed|jellyfin:seed|immich:seed|paperless-ngx:seed) ;;
  *) exit 74 ;;
esac
printf '%s\n' "$1:$2" >> "${DEFAULT_DRIVER_LOG:?}"
SH
chmod 0700 "$default_driver"
default_driver_log=$temporary_root/default-driver.log
(
  unset PLATFORM_MAC_TMPDIR
  TMPDIR=$default_parent DEFAULT_DRIVER_LOG=$default_driver_log \
    PLATFORM_MAC_SANDBOX=$default_sandbox PLATFORM_PROJECT_NAME=nas-platform-mac-def456 \
    PLATFORM_LEGACY_FIXTURE_DRIVER=$default_driver \
    "$test_dir/legacy-fixtures.sh" seed
) || fail 'legacy fixtures require undocumented PLATFORM_MAC_TMPDIR input'
[ "$(wc -l < "$default_driver_log" | tr -d ' ')" -eq 6 ] ||
  fail 'default temporary parent legacy fixture flow was incomplete'

outside=$temporary_root/outside
mkdir -m 0700 "$outside"
PLATFORM_KOMGA_LIBRARY_PATH=$outside
export PLATFORM_KOMGA_LIBRARY_PATH
if legacy_fixture_validate PLATFORM_KOMGA_LIBRARY_PATH legacy/komga/library >/dev/null 2>&1; then
  fail 'outside legacy fixture path was accepted'
fi
[ -z "$(find "$outside" -mindepth 1 -print -quit)" ] || fail 'outside path was mutated'

rmdir "$sandbox/legacy/komga/library"
ln -s "$outside" "$sandbox/legacy/komga/library"
PLATFORM_KOMGA_LIBRARY_PATH=$sandbox/legacy/komga/library
export PLATFORM_KOMGA_LIBRARY_PATH
if legacy_fixture_validate PLATFORM_KOMGA_LIBRARY_PATH legacy/komga/library >/dev/null 2>&1; then
  fail 'symlinked legacy fixture path was accepted'
fi
[ -z "$(find "$outside" -mindepth 1 -print -quit)" ] || fail 'symlink target was mutated'

fake_bin=$temporary_root/bin
mkdir -m 0700 "$fake_bin"
cat > "$fake_bin/ruby" <<'SH'
#!/bin/sh
env | grep -E '^PLATFORM_(LEGACY_FIXTURE_|FIXTURE_COMPOSE_|AUDIOBOOKSHELF_MEDIA_LIBRARY|KOMGA_LIBRARY_PATH|TINYMEDIAMANAGER_.*_ROOT|JELLYFIN_.*_ROOT|IMMICH_.*_ROOT|PAPERLESS_.*_ROOT)=' && exit 91
for variable in PLATFORM_TINYMEDIAMANAGER_CONTAINER PLATFORM_JELLYFIN_CONTAINER \
    PLATFORM_IMMICH_SERVER_CONTAINER PLATFORM_IMMICH_MACHINE_LEARNING_CONTAINER \
    PLATFORM_IMMICH_REDIS_CONTAINER PLATFORM_IMMICH_POSTGRES_CONTAINER \
    PLATFORM_PAPERLESS_WEBSERVER_CONTAINER; do
  container=$(printenv "$variable" 2>/dev/null || true)
  [ -z "$container" ] || docker inspect "$container"
done
exit 0
SH
cat > "$fake_bin/docker" <<'SH'
#!/bin/sh
printf 'docker' >> "${FAKE_DOCKER_LOG:?}"
for argument in "$@"; do printf '\t%s' "$argument" >> "$FAKE_DOCKER_LOG"; done
printf '\n' >> "$FAKE_DOCKER_LOG"
SH
chmod 0700 "$fake_bin/ruby" "$fake_bin/docker"
docker_log=$temporary_root/docker.log
run_fresh_wrapper() {
  env PATH="$fake_bin:$PATH" FAKE_DOCKER_LOG="$docker_log" \
    PLATFORM_MAC_VAULT_FILE=x PLATFORM_MAC_VAULT_PASSWORD_FILE=x \
    PLATFORM_MEDIA_ROOT=/outside PLATFORM_DOCKER_ROOT=/outside \
    PLATFORM_REPORT_ROOT=/outside PLATFORM_PROJECT_NAME=fresh \
    PLATFORM_AUDIOBOOKSHELF_PORT=1 PLATFORM_KOMGA_PORT=1 \
    PLATFORM_TINYMEDIAMANAGER_API_PORT=1 PLATFORM_JELLYFIN_PORT=1 \
    PLATFORM_IMMICH_PORT=1 PLATFORM_PAPERLESS_PORT=1 \
    PLATFORM_LEGACY_FIXTURE_MODE=nas-platform-owned-legacy-v1 \
    PLATFORM_LEGACY_FIXTURE_SANDBOX="$sandbox" \
    PLATFORM_FIXTURE_COMPOSE_PROJECT=hostile-project \
    PLATFORM_FIXTURE_COMPOSE_SERVICE=hostile-service \
    PLATFORM_KOMGA_LIBRARY_PATH="$outside" \
    PLATFORM_TINYMEDIAMANAGER_CONTAINER=hostile-tmm \
    PLATFORM_JELLYFIN_CONTAINER=hostile-jellyfin \
    PLATFORM_IMMICH_SERVER_CONTAINER=hostile-immich-server \
    PLATFORM_IMMICH_MACHINE_LEARNING_CONTAINER=hostile-immich-ml \
    PLATFORM_IMMICH_REDIS_CONTAINER=hostile-immich-redis \
    PLATFORM_IMMICH_POSTGRES_CONTAINER=hostile-immich-postgres \
    PLATFORM_PAPERLESS_WEBSERVER_CONTAINER=hostile-paperless "$@"
}
for wrapper_mode in 'audiobookshelf seed-progress' 'komga seed' 'tinymediamanager seed' \
    'jellyfin seed' 'immich seed' 'paperless seed'; do
  set -- $wrapper_mode
  wrapper=$1
  fixture_mode=$2
  # The fake Ruby process observes the wrapper's final environment without executing fixtures.
  : > "$docker_log"
  run_fresh_wrapper "$test_dir/run-$wrapper-contract.sh" "$fixture_mode" >/dev/null 2>&1 ||
    fail "fresh $wrapper wrapper preserved ambient legacy fixture controls"
  grep -F 'hostile-' "$docker_log" >/dev/null 2>&1 &&
    fail "fresh $wrapper wrapper used a hostile container identifier"
  case $wrapper in
    tinymediamanager) expected='fresh-tinymediamanager' ;;
    jellyfin) expected='fresh-jellyfin' ;;
    immich) expected='fresh-immich-server fresh-immich-machine-learning fresh-immich-redis fresh-immich-postgres' ;;
    paperless) expected='fresh-paperless-webserver' ;;
    *) expected= ;;
  esac
  for container in $expected; do
    grep -q "^docker${tab}inspect${tab}$container$" "$docker_log" ||
      fail "fresh $wrapper wrapper omitted canonical container $container"
  done
done

printf '%s\n' 'Legacy fixture paths: controlled owned roots resist ambient and symlink injection'
