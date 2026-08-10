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
env | grep -E '^PLATFORM_(LEGACY_FIXTURE_|AUDIOBOOKSHELF_MEDIA_LIBRARY|KOMGA_LIBRARY_PATH|TINYMEDIAMANAGER_.*_ROOT|JELLYFIN_.*_ROOT|IMMICH_.*_ROOT|PAPERLESS_.*_ROOT)=' && exit 91
exit 0
SH
chmod 0700 "$fake_bin/ruby"
common_env="PATH=$fake_bin:$PATH PLATFORM_MAC_VAULT_FILE=x PLATFORM_MAC_VAULT_PASSWORD_FILE=x PLATFORM_MEDIA_ROOT=/outside PLATFORM_DOCKER_ROOT=/outside PLATFORM_REPORT_ROOT=/outside PLATFORM_PROJECT_NAME=fresh PLATFORM_AUDIOBOOKSHELF_PORT=1 PLATFORM_KOMGA_PORT=1 PLATFORM_TINYMEDIAMANAGER_API_PORT=1 PLATFORM_JELLYFIN_PORT=1 PLATFORM_IMMICH_PORT=1 PLATFORM_PAPERLESS_PORT=1 PLATFORM_LEGACY_FIXTURE_MODE=nas-platform-owned-legacy-v1 PLATFORM_LEGACY_FIXTURE_SANDBOX=$sandbox PLATFORM_KOMGA_LIBRARY_PATH=$outside"
for wrapper in audiobookshelf komga tinymediamanager jellyfin immich paperless; do
  # The fake Ruby process observes the wrapper's final environment without executing fixtures.
  env $common_env "$test_dir/run-$wrapper-contract.sh" static >/dev/null 2>&1 ||
    fail "fresh $wrapper wrapper preserved ambient legacy fixture controls"
done

printf '%s\n' 'Legacy fixture paths: controlled owned roots resist ambient and symlink injection'
