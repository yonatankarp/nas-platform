#!/bin/sh
set -eu
set +x
umask 077

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_dir=$(CDPATH= cd -- "$script_dir/../.." && pwd -P)
. "$script_dir/lib.sh"

die() {
  printf 'adoption-rollback-error: %s\n' "$1" >&2
  exit 1
}

[ "$#" -eq 0 ] || die 'unexpected arguments'
rollback_self_test=${PLATFORM_ADOPTION_ROLLBACK_SELF_TEST:-0}
case $rollback_self_test in 0|1) ;; *) die 'self-test control differs' ;; esac
if [ "$rollback_self_test" = 0 ]; then
  [ -z "${PLATFORM_ADOPTION_ROLLBACK_FAULT+x}" ] &&
    [ -z "${PLATFORM_ADOPTION_ROLLBACK_SNAPSHOT_COMMAND+x}" ] &&
    [ -z "${PLATFORM_ADOPTION_ROLLBACK_BASELINE_COMMAND+x}" ] &&
    [ -z "${PLATFORM_ADOPTION_ROLLBACK_RENDER_COMMAND+x}" ] ||
    die 'self-test controls are forbidden'
fi
case ${PLATFORM_ADOPTION_ROLLBACK_FAULT:-} in
  ''|before-restore|after-restore) ;;
  *) die 'self-test fault differs' ;;
esac

snapshot_command=${PLATFORM_ADOPTION_ROLLBACK_SNAPSHOT_COMMAND:-$script_dir/adoption-snapshot.sh}
baseline_command=${PLATFORM_ADOPTION_ROLLBACK_BASELINE_COMMAND:-$script_dir/adoption-baseline.rb}
render_command=${PLATFORM_ADOPTION_ROLLBACK_RENDER_COMMAND:-$script_dir/adoption.sh}
services='audiobookshelf beszel dozzle immich jellyfin komga ntfy paperless-ngx tinymediamanager'

source_sandbox=$(mac_validate_sandbox "${PLATFORM_MAC_SANDBOX:?PLATFORM_MAC_SANDBOX is required}" 2>/dev/null) ||
  die 'owned cutover sandbox is invalid'
source_project=${PLATFORM_PROJECT_NAME:?PLATFORM_PROJECT_NAME is required}
[ "$source_project" = "$(sed -n 's/^project=//p' "$source_sandbox/.nas-platform-mac-owned")" ] ||
  die 'cutover project differs from owned sandbox'
[ "${PLATFORM_ADOPTION_ENABLED:-false}" = true ] &&
  [ "${PLATFORM_ADOPTION_ROOT:-}" = "$source_sandbox" ] || die 'adoption mapping is unavailable'
report_root=${PLATFORM_REPORT_ROOT:?PLATFORM_REPORT_ROOT is required}
source_marker=${PLATFORM_ADOPTION_MARKER:?PLATFORM_ADOPTION_MARKER is required}

baseline_binding() {
  "$snapshot_command" baseline-binding \
    --override-root "$script_dir/legacy-overrides" --baseline "$source_sandbox/baseline.json" \
    --run-state "$report_root/phase-input.json"
}

binding=$(baseline_binding) || die 'pre-cutover snapshot validation failed'
binding_sha256=$(printf '%s\n' "$binding" | ruby -rjson -e '
  value = JSON.parse(STDIN.read)
  abort unless value.keys.sort == %w[baseline_sha256 binding_sha256]
  digest = value.fetch("binding_sha256")
  abort unless digest.match?(/\A[0-9a-f]{64}\z/)
  print digest
') || die 'snapshot binding differs'
baseline_sha256=$(printf '%s\n' "$binding" | ruby -rjson -e '
  value = JSON.parse(STDIN.read)
  digest = value.fetch("baseline_sha256")
  abort unless digest.match?(/\A[0-9a-f]{64}\z/)
  print digest
') || die 'snapshot baseline binding differs'
[ "$binding_sha256" = "$source_marker" ] || die 'snapshot binding differs'
[ "${PLATFORM_ADOPTION_ROLLBACK_FAULT:-}" != before-restore ] || die 'forced failure before restore'

rollback_parent=$(dirname -- "$source_sandbox")
rollback_root=$(mktemp -d "$rollback_parent/nas-platform-mac.XXXXXX") ||
  die 'rollback sandbox creation failed'
rollback_root=$(CDPATH= cd -- "$rollback_root" && pwd -P) || die 'rollback sandbox creation failed'
chmod 0700 "$rollback_root"
rollback_suffix=${rollback_root##*.}
rollback_project=nas-platform-mac-$(printf '%s' "$rollback_suffix" | tr '[:upper:]' '[:lower:]')
printf 'schema=1\nproject=%s\nnamespace=rollback\nsource_project=%s\nsnapshot_binding=%s\n' \
  "$rollback_project" "$source_project" "$binding_sha256" > "$rollback_root/.nas-platform-mac-owned"
chmod 0600 "$rollback_root/.nas-platform-mac-owned"
mac_validate_sandbox "$rollback_root" >/dev/null 2>&1 || die 'rollback sandbox ownership differs'

PLATFORM_ADOPTION_ROLLBACK_ROOT=$rollback_root \
PLATFORM_ADOPTION_ROLLBACK_PROJECT=$rollback_project \
  "$snapshot_command" restore \
    --override-root "$script_dir/legacy-overrides" --baseline "$source_sandbox/baseline.json" \
    --run-state "$report_root/phase-input.json" >/dev/null || die 'snapshot restore failed'
[ "${PLATFORM_ADOPTION_ROLLBACK_FAULT:-}" != after-restore ] || die 'forced failure after restore'

for coordinated_path in \
  legacy/immich/data legacy/immich/thumbs legacy/immich/encoded-video \
  legacy/immich/profile legacy/immich/backups legacy/immich/model-cache legacy/immich/postgres \
  legacy/paperless-ngx/redis legacy/paperless-ngx/postgres legacy/paperless-ngx/data \
  legacy/paperless-ngx/export legacy/paperless-ngx/tessdata/heb.traineddata \
  legacy/paperless-ngx/media legacy/paperless-ngx/consume; do
  [ -e "$rollback_root/$coordinated_path" ] && [ ! -L "$rollback_root/$coordinated_path" ] ||
    die 'coordinated state restore is incomplete'
done

PLATFORM_MAC_SANDBOX=$rollback_root PLATFORM_PROJECT_NAME=$rollback_project \
  "$render_command" render >/dev/null || die 'rollback parity rendering failed'

rollback_ports=$(ruby -rsocket -e '
  sockets = Array.new(10) { TCPServer.new("127.0.0.1", 0) }
  puts sockets.map { |socket| socket.local_address.ip_port }
') || die 'rollback port allocation failed'
set -- $rollback_ports
[ "$#" -eq 10 ] || die 'rollback port allocation failed'
export BESZEL_HOST_PORT=$1 PLATFORM_BESZEL_PORT=$1
export NTFY_HOST_PORT=$2 PLATFORM_NTFY_PORT=$2
export DOZZLE_HOST_PORT=$3 PLATFORM_DOZZLE_PORT=$3
export AUDIOBOOKSHELF_HOST_PORT=$4 PLATFORM_AUDIOBOOKSHELF_PORT=$4
export KOMGA_HOST_PORT=$5 PLATFORM_KOMGA_PORT=$5
export TINYMEDIAMANAGER_WEB_HOST_PORT=$6 PLATFORM_TINYMEDIAMANAGER_WEB_PORT=$6
export TINYMEDIAMANAGER_API_HOST_PORT=$7 PLATFORM_TINYMEDIAMANAGER_API_PORT=$7
export JELLYFIN_HOST_PORT=$8 PLATFORM_JELLYFIN_PORT=$8
export IMMICH_HOST_PORT=$9 PLATFORM_IMMICH_PORT=$9
shift 9
export PAPERLESS_HOST_PORT=$1 PLATFORM_PAPERLESS_PORT=$1

started_services=
stop_rollback() {
  stop_status=0
  for service in $started_services; do
    PLATFORM_MAC_SANDBOX=$rollback_root PLATFORM_PROJECT_NAME=$rollback_project \
      "$script_dir/legacy-compose.sh" "$service" stop || stop_status=1
  done
  return "$stop_status"
}
rollback_complete=false
rollback_exit() {
  exit_status=$?
  trap - EXIT HUP INT TERM
  if [ "$rollback_complete" != true ]; then
    stop_rollback >/dev/null 2>&1 || true
  fi
  exit "$exit_status"
}
trap rollback_exit EXIT HUP INT TERM

original_baseline=$rollback_root/pre-cutover-baseline.json
[ -f "$original_baseline" ] && [ ! -L "$original_baseline" ] &&
  [ "$(mac_file_mode "$original_baseline")" = 400 ] || die 'restored baseline is unsafe'
for service in $services; do
  PLATFORM_MAC_SANDBOX=$rollback_root PLATFORM_PROJECT_NAME=$rollback_project \
    "$script_dir/legacy-compose.sh" "$service" config >/dev/null 2>&1 ||
    die 'legacy Compose validation failed'
  if ! images=$(PLATFORM_MAC_SANDBOX=$rollback_root PLATFORM_PROJECT_NAME=$rollback_project \
      docker compose --env-file "$rollback_root/legacy-env/$service.env" \
        --project-name "$rollback_project-legacy-$service" \
        -f "$PLATFORM_LEGACY_ROOT/$(ruby -ryaml -e '
          entry = YAML.safe_load_file(ARGV[0], aliases: false).fetch("services").find { |item| item.fetch("name") == ARGV[1] }
          abort unless entry
          print entry.fetch("legacy_path")
        ' "$repo_dir/services/manifest.yml" "$service")" \
        -f "$script_dir/legacy-overrides/$service.yml" config --images 2>/dev/null); then
    die 'legacy image validation failed'
  fi
  if ! ROLLBACK_IMAGES=$images ruby -rdigest -rjson - "$original_baseline" "$baseline_sha256" "$service" <<'RUBY'
baseline_path, baseline_digest, service = ARGV
before = File.lstat(baseline_path)
raise unless before.file? && !before.symlink?
File.open(baseline_path, File::RDONLY | File::NOFOLLOW) do |file|
  bytes = file.read
  raise unless Digest::SHA256.hexdigest(bytes) == baseline_digest
  raise unless [file.stat.dev, file.stat.ino, file.stat.size, file.stat.mtime.to_r, file.stat.ctime.to_r] ==
    [before.dev, before.ino, before.size, before.mtime.to_r, before.ctime.to_r]
  expected = JSON.parse(bytes).fetch("legacy_images").fetch(service)
  actual = ENV.fetch("ROLLBACK_IMAGES").lines(chomp: true).reject(&:empty?)
  raise unless actual == expected
end
after = File.lstat(baseline_path)
raise unless [after.dev, after.ino, after.size, after.mtime.to_r, after.ctime.to_r] ==
  [before.dev, before.ino, before.size, before.mtime.to_r, before.ctime.to_r]
RUBY
  then
    die 'legacy images differ from baseline'
  fi
done

for service in $services; do
  PLATFORM_MAC_SANDBOX=$rollback_root PLATFORM_PROJECT_NAME=$rollback_project \
    "$script_dir/legacy-compose.sh" "$service" up || die 'rollback project start failed'
  started_services="$service $started_services"
done

rollback_baseline=$rollback_root/rollback-baseline.json
PLATFORM_MAC_SANDBOX=$rollback_root PLATFORM_PROJECT_NAME=$rollback_project \
  "$baseline_command" --output "$rollback_baseline" \
    --legacy-commit 400f03f276ae1bb69f5460c175b9fb923d620f1a \
    --manifest "$repo_dir/services/manifest.yml" --legacy-root "$PLATFORM_LEGACY_ROOT" \
    --override-root "$script_dir/legacy-overrides" --env-root "$rollback_root/legacy-env" \
    --probe-root "$script_dir/adoption-probes" \
    --expected-baseline "$original_baseline" \
    --expected-baseline-sha256 "$baseline_sha256" >/dev/null || die 'rollback evidence differs from baseline'
stop_rollback || die 'rollback project stop failed'
started_services=

final_binding=$(baseline_binding) || die 'snapshot changed during rollback'
[ "$final_binding" = "$binding" ] || die 'snapshot changed during rollback'
rollback_complete=true
trap - EXIT HUP INT TERM
printf 'Legacy adoption rollback: %s evidence matches baseline\n' "$rollback_project"
