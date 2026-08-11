#!/bin/sh
set -eu
set +x
umask 077

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/paperless-context.XXXXXX")
fixture=$(CDPATH= cd -- "$fixture" && pwd -P)
cleanup() {
  find "$fixture" -depth -mindepth 1 -delete 2>/dev/null || true
  rmdir "$fixture" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

sandbox=$fixture/nas-platform-mac.AbC123
project=nas-platform-mac-abc123
mkdir -m 0700 -p "$sandbox/service-data/docker" "$sandbox/service-data/media" \
  "$fixture/snapshot" "$fixture/bin"
printf 'schema=1\nproject=%s\n' "$project" > "$sandbox/.nas-platform-mac-owned"
chmod 0600 "$sandbox/.nas-platform-mac-owned"
cat > "$fixture/bin/ruby" <<'SH'
#!/bin/sh
[ "$1" = - ] && [ "$2" = drill ] || exit 81
[ "$PLATFORM_PAPERLESS_WEBSERVER_CONTAINER" = paperless_webserver ] || exit 82
[ "$PLATFORM_PAPERLESS_POSTGRES_CONTAINER" = paperless_postgres ] || exit 83
[ "$PLATFORM_PAPERLESS_REDIS_CONTAINER" = paperless_redis ] || exit 84
exit 0
SH
chmod 0700 "$fixture/bin/ruby"

run_context() {
  env PATH="$fixture/bin:$PATH" PLATFORM_PROOF_PLATFORM=integration \
    PLATFORM_PROOF_LANE=adoption PLATFORM_KIND=integration \
    PLATFORM_PROJECT_NAME="${TEST_PROJECT:-$project}" \
    PLATFORM_MAC_SANDBOX="${TEST_SANDBOX:-$sandbox}" \
    PLATFORM_DOCKER_ROOT="${TEST_DOCKER_ROOT:-$sandbox/service-data/docker}" \
    PLATFORM_MEDIA_ROOT="$sandbox/service-data/media" \
    PLATFORM_CONTRACT_VAULT_FILE="$fixture/vault" \
    PLATFORM_CONTRACT_VAULT_PASSWORD_FILE="$fixture/password" \
    "$script_dir/snapshot-paperless.sh" drill "$fixture/snapshot"
}

run_context || { printf '%s\n' 'paperless context: exact integration adoption context failed' >&2; exit 1; }
if TEST_PROJECT=nas-platform-mac-hostile run_context >/dev/null 2>&1; then
  printf '%s\n' 'paperless context: hostile project was accepted' >&2
  exit 1
fi
if TEST_DOCKER_ROOT="$fixture/escape" run_context >/dev/null 2>&1; then
  printf '%s\n' 'paperless context: hostile storage root was accepted' >&2
  exit 1
fi
chmod 0644 "$sandbox/.nas-platform-mac-owned"
if run_context >/dev/null 2>&1; then
  printf '%s\n' 'paperless context: unsafe marker mode was accepted' >&2
  exit 1
fi
chmod 0600 "$sandbox/.nas-platform-mac-owned"
if TEST_SANDBOX="$fixture" run_context >/dev/null 2>&1; then
  printf '%s\n' 'paperless context: unowned sandbox was accepted' >&2
  exit 1
fi

printf '%s\n' 'Paperless context: integration adoption ownership and containers hold'
