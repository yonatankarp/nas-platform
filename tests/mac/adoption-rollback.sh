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
    [ -z "${PLATFORM_ADOPTION_ROLLBACK_RENDER_COMMAND+x}" ] &&
    [ -z "${PLATFORM_ADOPTION_ROLLBACK_OVERRIDE_ROOT+x}" ] ||
    die 'self-test controls are forbidden'
fi
case ${PLATFORM_ADOPTION_ROLLBACK_FAULT:-} in
  ''|before-restore|after-restore) ;;
  *) die 'self-test fault differs' ;;
esac

snapshot_command=${PLATFORM_ADOPTION_ROLLBACK_SNAPSHOT_COMMAND:-$script_dir/adoption-snapshot.sh}
baseline_command=${PLATFORM_ADOPTION_ROLLBACK_BASELINE_COMMAND:-$script_dir/adoption-baseline.rb}
render_command=${PLATFORM_ADOPTION_ROLLBACK_RENDER_COMMAND:-$script_dir/adoption.sh}
compose_helper=$script_dir/adoption-rollback-compose.rb
override_root=${PLATFORM_ADOPTION_ROLLBACK_OVERRIDE_ROOT:-$script_dir/legacy-overrides}
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
  "$snapshot_command" rollback-binding \
    --override-root "$script_dir/legacy-overrides" --baseline "$source_sandbox/baseline.json" \
    --run-state "$report_root/phase-input.json"
}

binding=$(baseline_binding) || die 'pre-cutover snapshot validation failed'
binding_sha256=$(printf '%s\n' "$binding" | ruby -rjson -e '
  value = JSON.parse(STDIN.read)
  abort unless value.keys.sort == %w[baseline_sha256 binding_sha256 git_revision legacy_commit]
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
repo_revision=$(printf '%s\n' "$binding" | ruby -rjson -e '
  value = JSON.parse(STDIN.read)
  revision = value.fetch("git_revision")
  abort unless revision.match?(/\A[0-9a-f]{40}\z/)
  print revision
') || die 'snapshot repository binding differs'
snapshot_legacy_commit=$(printf '%s\n' "$binding" | ruby -rjson -e '
  value = JSON.parse(STDIN.read)
  commit = value.fetch("legacy_commit")
  abort unless commit.match?(/\A[0-9a-f]{40}\z/)
  print commit
') || die 'snapshot legacy binding differs'
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

attestations_json=$(PLATFORM_ADOPTION_ROLLBACK_ROOT=$rollback_root \
  "$snapshot_command" attestations \
  --override-root "$script_dir/legacy-overrides" --baseline "$source_sandbox/baseline.json" \
  --run-state "$report_root/phase-input.json") || die 'rollback mount attestations are unavailable'
attestations_sha256=$(printf '%s\n' "$attestations_json" | shasum -a 256 | awk '{print $1}') ||
  die 'rollback mount attestations are unavailable'
attestations_file=$(printf '%s\n' "$attestations_json" |
  "$compose_helper" publish-attestations "$rollback_root" "$attestations_sha256") ||
  die 'rollback mount attestation publication failed'

for coordinated_path in \
  legacy/immich/data legacy/immich/thumbs legacy/immich/encoded-video \
  legacy/immich/profile legacy/immich/backups legacy/immich/model-cache legacy/immich/postgres \
  legacy/paperless-ngx/redis legacy/paperless-ngx/postgres legacy/paperless-ngx/data \
  legacy/paperless-ngx/export legacy/paperless-ngx/tessdata/heb.traineddata \
  legacy/paperless-ngx/media legacy/paperless-ngx/consume; do
  [ -e "$rollback_root/$coordinated_path" ] && [ ! -L "$rollback_root/$coordinated_path" ] ||
    die 'coordinated state restore is incomplete'
done

render_output=$(PLATFORM_MAC_SANDBOX=$rollback_root PLATFORM_PROJECT_NAME=$rollback_project \
  "$render_command" render) || die 'rollback parity rendering failed'
render_binding_sha=$(printf '%s\n' "$render_output" |
  sed -n 's/^Legacy adoption render binding: \([0-9a-f][0-9a-f]*\)$/\1/p')
case $render_binding_sha in
  *[!0123456789abcdef]*|'') die 'rollback parity rendering binding differs' ;;
esac
[ "${#render_binding_sha}" -eq 64 ] || die 'rollback parity rendering binding differs'

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

original_baseline=$rollback_root/pre-cutover-baseline.json
[ -f "$original_baseline" ] && [ ! -L "$original_baseline" ] &&
  [ "$(mac_file_mode "$original_baseline")" = 400 ] || die 'restored baseline is unsafe'
git_blob_digest() {
  digest_repository=$1
  digest_object=$2
  ruby -rdigest -ropen3 - "$digest_repository" "$digest_object" <<'RUBY'
repository, object = ARGV
bytes, _stderr, status = Open3.capture3("git", "-C", repository, "cat-file", "blob", object)
raise unless status.success? && bytes.bytesize <= 16 * 1024 * 1024
print Digest::SHA256.hexdigest(bytes)
RUBY
}

manifest_fields=$(ruby -rdigest -rjson -ropen3 -ryaml - \
  "$original_baseline" "$baseline_sha256" "$repo_dir" "$repo_revision" <<'RUBY'
baseline_path, expected_baseline_digest, repository, revision = ARGV

def signature(stat)
  [stat.dev, stat.ino, stat.size, stat.mode, stat.uid, stat.gid, stat.mtime.to_r, stat.ctime.to_r]
end

before = File.lstat(baseline_path)
raise unless before.file? && !before.symlink? && before.uid == Process.uid && (before.mode & 0o777) == 0o400
baseline_file = File.open(baseline_path, File::RDONLY | File::NOFOLLOW)
begin
  raise unless signature(baseline_file.stat) == signature(before)
  baseline_bytes = baseline_file.read
  raise unless Digest::SHA256.hexdigest(baseline_bytes) == expected_baseline_digest
  raise unless signature(baseline_file.stat) == signature(before) && signature(File.lstat(baseline_path)) == signature(before)
ensure
  baseline_file.close
end
manifest_bytes, _stderr, status = Open3.capture3(
  "git", "-C", repository, "cat-file", "blob", "#{revision}:services/manifest.yml"
)
raise unless status.success? && manifest_bytes.bytesize <= 1024 * 1024
baseline = JSON.parse(baseline_bytes)
manifest = YAML.safe_load(manifest_bytes, aliases: false)
commit = baseline.fetch("legacy_commit")
expected_services = %w[audiobookshelf beszel dozzle immich jellyfin komga ntfy paperless-ngx tinymediamanager]
services = manifest.fetch("services")
raise unless commit.is_a?(String) && commit.match?(/\A[0-9a-f]{40}\z/) &&
             manifest.fetch("legacy_source").fetch("commit") == commit &&
             services.map { |entry| entry.fetch("name") }.sort == expected_services
puts commit
services.each do |entry|
  name = entry.fetch("name")
  path = entry.fetch("legacy_path")
  raise unless path.match?(/\A[A-Za-z0-9_.\/-]+\z/) && !path.start_with?("/") && !path.split("/").include?("..")
  puts "#{name}\t#{path}"
end
RUBY
) || die 'legacy manifest binding differs'
legacy_commit=$(printf '%s\n' "$manifest_fields" | sed -n '1p')
[ "$legacy_commit" = "$snapshot_legacy_commit" ] || die 'snapshot legacy binding differs'
service_paths=$(printf '%s\n' "$manifest_fields" | sed '1d')

compose_root=$rollback_root/compose-inputs
mkdir -m 0700 "$compose_root" || die 'rollback Compose staging failed'
for service in $services; do
  tab=$(printf '\t')
  legacy_path=$(printf '%s\n' "$service_paths" |
    while IFS="$tab" read -r manifest_service manifest_path; do
      [ "$manifest_service" != "$service" ] || printf '%s\n' "$manifest_path"
    done)
  [ -n "$legacy_path" ] || die 'service manifest differs'
  base_file=$PLATFORM_LEGACY_ROOT/$legacy_path
  base_digest=$(git_blob_digest "$PLATFORM_LEGACY_ROOT" "$legacy_commit:$legacy_path") ||
    die 'pinned legacy Compose input is unavailable'
  override_digest=$(git_blob_digest "$repo_dir" "$repo_revision:tests/mac/legacy-overrides/$service.yml") ||
    die 'reviewed legacy override is unavailable'
  environment_digest=$(ruby -rdigest -rjson - "$rollback_root/legacy-env/.binding.json" \
    "$render_binding_sha" "$service" <<'RUBY'
path, expected_digest, service = ARGV
before = File.lstat(path)
raise unless before.file? && !before.symlink? && before.uid == Process.uid && (before.mode & 0o777) == 0o400
File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
  bytes = file.read
  raise unless Digest::SHA256.hexdigest(bytes) == expected_digest
  document = JSON.parse(bytes)
  expected_services = %w[audiobookshelf beszel dozzle immich jellyfin komga ntfy paperless-ngx tinymediamanager]
  raise unless document.keys.sort == %w[schema services] && document.fetch("schema") == 1 &&
               document.fetch("services").keys.sort == expected_services
  digest = document.fetch("services").fetch(service)
  raise unless digest.match?(/\A[0-9a-f]{64}\z/)
  raise unless file.stat.dev == before.dev && file.stat.ino == before.ino && File.lstat(path).ino == before.ino
  print digest
end
RUBY
  ) || die 'rendered rollback environment is unavailable'
  "$compose_helper" resolve "$base_file" "$override_root/$service.yml" \
    "$rollback_root/legacy-env/$service.env" "$compose_root" "$service" \
    "$rollback_project-legacy-$service" "$(dirname -- "$base_file")" "$rollback_root" \
    "$base_digest" "$override_digest" "$environment_digest" \
    "$attestations_file" "$attestations_sha256" >/dev/null ||
    die 'rollback Compose resolution failed'
done
chmod 0500 "$compose_root" || die 'rollback Compose staging failed'

rollback_compose() {
  bound_service=$1
  bound_action=$2
  set -- "$compose_root/$bound_service".*.json
  [ "$#" -eq 1 ] && [ -f "$1" ] && [ ! -L "$1" ] || return 1
  bound_name=$(basename -- "$1")
  bound_digest=${bound_name#"$bound_service".}
  bound_digest=${bound_digest%.json}
  "$compose_helper" "$bound_action" "$1" "$bound_digest" \
    "$rollback_project-legacy-$bound_service"
}

started_services=
stop_rollback() {
  stop_status=0
  for service in $started_services; do
    rollback_compose "$service" stop || stop_status=1
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

for service in $services; do
  if ! images=$(rollback_compose "$service" images 2>/dev/null); then
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
  raise unless actual.sort == expected.sort
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
  started_services="$service $started_services"
  rollback_compose "$service" up || die 'rollback project start failed'
done

rollback_baseline=$rollback_root/rollback-baseline.json
PLATFORM_MAC_SANDBOX=$rollback_root PLATFORM_PROJECT_NAME=$rollback_project \
  "$baseline_command" --output "$rollback_baseline" \
    --legacy-commit "$legacy_commit" \
    --manifest "$repo_dir/services/manifest.yml" --legacy-root "$PLATFORM_LEGACY_ROOT" \
    --override-root "$override_root" --env-root "$rollback_root/legacy-env" \
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
