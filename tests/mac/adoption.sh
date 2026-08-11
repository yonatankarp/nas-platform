#!/bin/sh
set -eu
set +x
umask 077

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_dir=$(CDPATH= cd -- "$script_dir/../.." && pwd -P)
. "$script_dir/lib.sh"

die() {
  printf 'adoption-input-error: %s\n' "$1" >&2
  exit 1
}

[ "$#" -eq 1 ] || die 'expected one subcommand'
subcommand=$1
case $subcommand in
  --self-test) exec "$script_dir/adoption-self-test.sh" ;;
  preflight|render|legacy-deploy|legacy-seed|capture-baseline|snapshot|cutover) ;;
  *) die 'unsupported subcommand' ;;
esac

manifest=$repo_dir/services/manifest.yml
manifest_fields=$(ruby -ryaml - "$manifest" <<'RUBY'
document = YAML.safe_load_file(ARGV.fetch(0), aliases: false)
source = document.fetch("legacy_source")
repository = source.fetch("repository")
commit = source.fetch("commit")
services = document.fetch("services")
expected_services = %w[
  audiobookshelf beszel dozzle immich jellyfin komga ntfy paperless-ngx tinymediamanager
]
raise "repository" unless repository.is_a?(String) && repository.match?(/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/)
raise "commit" unless commit.is_a?(String) && commit.match?(/\A[0-9a-f]{40}\z/)
raise "services" unless services.is_a?(Array) &&
                        services.map { |service| service.fetch("name") }.sort == expected_services
puts repository
puts commit
services.each do |service|
  name = service.fetch("name")
  path = service.fetch("legacy_path")
  raise "service" unless name.is_a?(String) && path.is_a?(String) &&
                         path.match?(/\A[A-Za-z0-9_.\/-]+\z/) && !path.start_with?("/") &&
                         !path.split("/").include?("..")
  puts "#{name}\t#{path}"
end
RUBY
) || die 'service manifest is invalid'
expected_repository=$(printf '%s\n' "$manifest_fields" | sed -n '1p')
expected_commit=$(printf '%s\n' "$manifest_fields" | sed -n '2p')
service_paths=$(printf '%s\n' "$manifest_fields" | sed '1,2d')

preflight() {
  [ -n "${NAS_INFRASTRUCTURE_DIR:-}" ] || die 'NAS_INFRASTRUCTURE_DIR is required'
  [ ! -L "$NAS_INFRASTRUCTURE_DIR" ] || die 'legacy checkout must not be a symlink'
  [ -d "$NAS_INFRASTRUCTURE_DIR" ] || die 'legacy checkout is unavailable'
  legacy_root=$(CDPATH= cd -- "$NAS_INFRASTRUCTURE_DIR" 2>/dev/null && pwd -P) ||
    die 'legacy checkout is unavailable'

  origin=$(git -C "$legacy_root" remote get-url origin 2>/dev/null) ||
    die 'legacy checkout origin is unavailable'
  case $origin in
    "https://github.com/$expected_repository"|"https://github.com/$expected_repository.git"|\
    "git@github.com:$expected_repository"|"git@github.com:$expected_repository.git"|\
    "ssh://git@github.com/$expected_repository"|"ssh://git@github.com/$expected_repository.git") ;;
    *) die 'legacy checkout origin differs from manifest' ;;
  esac
  checkout_root=$(git -C "$legacy_root" rev-parse --show-toplevel 2>/dev/null) ||
    die 'legacy checkout root is unavailable'
  [ "$checkout_root" = "$legacy_root" ] || die 'NAS_INFRASTRUCTURE_DIR is not the repository root'
  checkout_commit=$(git -C "$legacy_root" rev-parse HEAD 2>/dev/null) ||
    die 'legacy checkout commit is unavailable'
  [ "$checkout_commit" = "$expected_commit" ] || die 'legacy checkout commit differs from manifest'
  checkout_status=$(git -C "$legacy_root" status --porcelain=v1 --untracked-files=all 2>/dev/null) ||
    die 'legacy checkout status is unavailable'
  [ -z "$checkout_status" ] || die 'legacy checkout must be clean'

  tab=$(printf '\t')
  printf '%s\n' "$service_paths" | while IFS="$tab" read -r service path; do
    [ -n "$service" ] && [ -n "$path" ] || die 'service manifest is invalid'
    candidate=$legacy_root/$path
    [ -f "$candidate" ] && [ ! -L "$candidate" ] || die 'legacy compose file is unavailable'
    git -C "$legacy_root" ls-files --error-unmatch -- "$path" >/dev/null 2>&1 ||
      die 'legacy compose file is not tracked'
    index_entry=$(git -C "$legacy_root" ls-files -v -- "$path" 2>/dev/null) ||
      die 'legacy compose index state is unavailable'
    [ "$index_entry" = "H $path" ] || die 'legacy compose file has unsafe index flags'
    git -C "$legacy_root" cat-file blob "HEAD:$path" 2>/dev/null |
      cmp -s - "$candidate" || die 'legacy compose file differs from HEAD'
    head_entry=$(git -C "$legacy_root" ls-tree HEAD -- "$path" 2>/dev/null) ||
      die 'legacy compose mode is unavailable'
    head_mode=${head_entry%% *}
    case $head_mode in
      100644) [ ! -x "$candidate" ] || die 'legacy compose mode differs from HEAD' ;;
      100755) [ -x "$candidate" ] || die 'legacy compose mode differs from HEAD' ;;
      *) die 'legacy compose mode differs from HEAD' ;;
    esac
  done
  docker version >/dev/null 2>&1 || die 'Docker is unavailable'
  export PLATFORM_LEGACY_ROOT=$legacy_root
}

preflight
stop_legacy_projects() {
  tab=$(printf '\t')
  printf '%s\n' "$service_paths" | while IFS="$tab" read -r service path; do
    [ -n "$service" ] && [ -n "$path" ] || die 'service manifest is invalid'
    "$script_dir/legacy-compose.sh" "$service" stop
  done
}

require_legacy_projects_stopped() {
  running_projects=$(docker ps --format '{{.Label "com.docker.compose.project"}}') || return 1
  tab=$(printf '\t')
  printf '%s\n' "$service_paths" | while IFS="$tab" read -r service path; do
    [ -n "$service" ] && [ -n "$path" ] || return 1
    project=$PLATFORM_PROJECT_NAME-legacy-$service
    [ "$(printf '%s\n' "$running_projects" | grep -Fxc -- "$project")" -eq 0 ] || return 1
  done
}

[ "$subcommand" = snapshot ] && {
  sandbox=$(mac_validate_sandbox "${PLATFORM_MAC_SANDBOX:?PLATFORM_MAC_SANDBOX is required}" 2>/dev/null) ||
    die 'owned sandbox is invalid'
  stop_legacy_projects || die 'legacy project stop failed'
  require_legacy_projects_stopped || die 'legacy projects restarted before snapshot copy'
  "$script_dir/adoption-snapshot.sh" publish \
    --override-root "$script_dir/legacy-overrides" \
    --baseline "$sandbox/baseline.json" \
    --run-state "${PLATFORM_REPORT_ROOT:?PLATFORM_REPORT_ROOT is required}/phase-input.json" ||
    die 'pre-cutover snapshot failed'
  printf '%s\n' 'Legacy adoption snapshot: stopped state published atomically'
  exit 0
}
[ "$subcommand" = cutover ] && {
  sandbox=$(mac_validate_sandbox "${PLATFORM_MAC_SANDBOX:?PLATFORM_MAC_SANDBOX is required}" 2>/dev/null) ||
    die 'owned sandbox is invalid'
  "$script_dir/adoption-snapshot.sh" begin-cutover \
    --override-root "$script_dir/legacy-overrides" \
    --baseline "$sandbox/baseline.json" \
    --run-state "${PLATFORM_REPORT_ROOT:?PLATFORM_REPORT_ROOT is required}/phase-input.json" ||
    die 'pre-cutover snapshot validation failed'
  printf '%s\n' 'Legacy adoption cutover: immutable snapshot revalidated'
  exit 0
}
[ "$subcommand" = legacy-deploy ] && {
  "$script_dir/adoption.sh" render
  sandbox=$(mac_validate_sandbox "$PLATFORM_MAC_SANDBOX" 2>/dev/null) ||
    die 'owned sandbox is invalid'
  if ! ruby - "$sandbox" >/dev/null 2>&1 <<'RUBY'
sandbox = File.realpath(ARGV.fetch(0))
directories = %w[
  legacy/audiobookshelf/config legacy/audiobookshelf/metadata legacy/audiobookshelf/media
  legacy/beszel/hub legacy/beszel/agent legacy/beszel/volume1 legacy/beszel/volume2
  legacy/dozzle/data
  legacy/immich/data legacy/immich/thumbs legacy/immich/encoded-video legacy/immich/profile
  legacy/immich/backups legacy/immich/model-cache legacy/immich/postgres
  legacy/jellyfin/config legacy/jellyfin/cache legacy/jellyfin/media
  legacy/komga/config legacy/komga/library
  legacy/ntfy/cache legacy/ntfy/data
  legacy/paperless-ngx/redis legacy/paperless-ngx/postgres legacy/paperless-ngx/data
  legacy/paperless-ngx/export legacy/paperless-ngx/tessdata legacy/paperless-ngx/media
  legacy/paperless-ngx/consume
  legacy/tinymediamanager/data legacy/tinymediamanager/movies legacy/tinymediamanager/series
]
directories.each do |relative|
  current = sandbox
  relative.split("/").each do |component|
    current = File.join(current, component)
    begin
      stat = File.lstat(current)
      raise "unsafe" unless stat.directory? && !stat.symlink? && stat.uid == Process.uid
    rescue Errno::ENOENT
      Dir.mkdir(current, 0o700)
    end
    File.chmod(0o700, current)
  end
end
model = File.join(sandbox, "legacy/paperless-ngx/tessdata/heb.traineddata")
begin
  stat = File.lstat(model)
  raise "unsafe" unless stat.file? && !stat.symlink? && stat.uid == Process.uid
rescue Errno::ENOENT
  flags = File::WRONLY | File::CREAT | File::EXCL
  flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
  File.open(model, flags, 0o600) { |file| file.flush; file.fsync }
end
RUBY
  then
    die 'legacy bind preparation failed'
  fi
  tab=$(printf '\t')
  printf '%s\n' "$service_paths" | while IFS="$tab" read -r service path; do
    [ -n "$service" ] && [ -n "$path" ] || die 'service manifest is invalid'
    "$script_dir/legacy-compose.sh" "$service" config
  done
  [ -f "${PLATFORM_MAC_VAULT_FILE:?deployment vault path is required}" ] &&
    [ ! -L "$PLATFORM_MAC_VAULT_FILE" ] || die 'deployment vault path is unsafe'
  [ -f "${PLATFORM_MAC_VAULT_PASSWORD_FILE:?deployment password path is required}" ] &&
    [ ! -L "$PLATFORM_MAC_VAULT_PASSWORD_FILE" ] || die 'deployment password path is unsafe'
  if ! ansible-playbook -i localhost, -c local "$script_dir/legacy-beszel-key.yml" \
      --vault-password-file "$PLATFORM_MAC_VAULT_PASSWORD_FILE" \
      -e @"$PLATFORM_MAC_VAULT_FILE" \
      -e "beszel_legacy_hub_root=$sandbox/legacy/beszel/hub" >/dev/null 2>&1; then
    die 'legacy Beszel identity preparation failed'
  fi
  printf '%s\n' "$service_paths" | while IFS="$tab" read -r service path; do
    [ -n "$service" ] && [ -n "$path" ] || die 'service manifest is invalid'
    "$script_dir/legacy-compose.sh" "$service" up
  done
  printf '%s\n' "$service_paths" | while IFS="$tab" read -r service path; do
    [ -n "$service" ] && [ -n "$path" ] || die 'service manifest is invalid'
    "$script_dir/legacy-compose.sh" "$service" ps
  done
  printf '%s\n' 'Legacy adoption deploy: nine isolated projects healthy'
  exit 0
}
[ "$subcommand" = legacy-seed ] && {
  tab=$(printf '\t')
  printf '%s\n' "$service_paths" | while IFS="$tab" read -r service path; do
    [ -n "$service" ] && [ -n "$path" ] || die 'service manifest is invalid'
    "$script_dir/legacy-compose.sh" "$service" ps
  done
  "$script_dir/legacy-seed.sh"
  printf '%s\n' 'Legacy adoption seed: supported capabilities ready'
  exit 0
}
[ "$subcommand" = capture-baseline ] && {
  sandbox=$(mac_validate_sandbox "${PLATFORM_MAC_SANDBOX:?PLATFORM_MAC_SANDBOX is required}" 2>/dev/null) ||
    die 'owned sandbox is invalid'
  tab=$(printf '\t')
  printf '%s\n' "$service_paths" | while IFS="$tab" read -r service path; do
    [ -n "$service" ] && [ -n "$path" ] || die 'service manifest is invalid'
    "$script_dir/legacy-compose.sh" "$service" ps
  done
  if ! "$script_dir/adoption-baseline.rb" \
      --output "$sandbox/baseline.json" \
      --legacy-commit "$expected_commit" \
      --manifest "$manifest" \
      --legacy-root "$PLATFORM_LEGACY_ROOT" \
      --override-root "$script_dir/legacy-overrides" \
      --env-root "$sandbox/legacy-env" \
      --probe-root "$script_dir/adoption-probes"; then
    die 'legacy baseline capture failed'
  fi
  printf '%s\n' 'Legacy adoption baseline: strict non-secret evidence ready'
  exit 0
}
[ "$subcommand" = render ] || {
  printf '%s\n' 'Legacy adoption preflight: pinned checkout holds'
  exit 0
}

[ -n "${PLATFORM_MAC_SANDBOX:-}" ] || die 'PLATFORM_MAC_SANDBOX is required'
sandbox=$(mac_validate_sandbox "$PLATFORM_MAC_SANDBOX" 2>/dev/null) || die 'owned sandbox is invalid'
[ -n "${PLATFORM_MAC_PARITY_VAULT_FILE:-}" ] || die 'parity vault path is required'
[ -n "${PLATFORM_MAC_PARITY_VAULT_PASSWORD_FILE:-}" ] || die 'parity password path is required'
[ -f "$PLATFORM_MAC_PARITY_VAULT_FILE" ] && [ ! -L "$PLATFORM_MAC_PARITY_VAULT_FILE" ] ||
  die 'parity vault path is unsafe'
[ "$(sed -n '1p' "$PLATFORM_MAC_PARITY_VAULT_FILE")" = '$ANSIBLE_VAULT;1.1;AES256' ] ||
  die 'parity vault must be encrypted'
[ -f "$PLATFORM_MAC_PARITY_VAULT_PASSWORD_FILE" ] &&
  [ ! -L "$PLATFORM_MAC_PARITY_VAULT_PASSWORD_FILE" ] || die 'parity password path is unsafe'

published_env_root=$sandbox/legacy-env
if [ -e "$published_env_root" ]; then
  [ -d "$published_env_root" ] && [ ! -L "$published_env_root" ] &&
    [ "$(mac_owner_id "$published_env_root")" = "$(id -u)" ] &&
    [ "$(mac_file_mode "$published_env_root")" = 700 ] ||
    die 'legacy environment directory is unsafe'
fi

render_work=$(mktemp -d "$sandbox/.legacy-render.XXXXXX") || die 'legacy render staging failed'
chmod 0700 "$render_work" || die 'legacy render staging failed'
cleanup_render() {
  render_status=$?
  trap - EXIT HUP INT TERM
  if [ -n "${previous_env_root:-}" ] && [ -d "$previous_env_root" ] &&
     [ ! -e "$published_env_root" ]; then
    mv "$previous_env_root" "$published_env_root" || render_status=1
  fi
  if [ -d "$render_work/encrypted" ] && [ ! -L "$render_work/encrypted" ]; then
    chmod 0700 "$render_work/encrypted" || render_status=1
  fi
  if [ -d "$render_work" ] && [ ! -L "$render_work" ]; then
    /usr/bin/find "$render_work" -depth -delete
  fi
  exit "$render_status"
}
trap cleanup_render EXIT HUP INT TERM

snapshot_root=$render_work/encrypted
mkdir -m 0700 "$snapshot_root" || die 'legacy parity snapshot failed'
encrypted_parity=$snapshot_root/parity.vault
if ! ruby - "$PLATFORM_MAC_PARITY_VAULT_FILE" "$encrypted_parity" \
    >/dev/null 2>&1 <<'RUBY'
source_path, destination_path = ARGV
maximum_size = 16 * 1024 * 1024

def signature(stat)
  [stat.dev, stat.ino, stat.size, stat.mode, stat.uid, stat.mtime.to_r, stat.ctime.to_r]
end

initial = File.lstat(source_path)
raise "unsafe source" unless initial.file? && !initial.symlink?
source_flags = File::RDONLY
source_flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
File.open(source_path, source_flags) do |source|
  opened = source.stat
  raise "source changed" unless signature(initial) == signature(opened)

  bytes = source.read(maximum_size + 1)
  raise "source too large" if bytes.bytesize > maximum_size
  raise "source changed" unless signature(opened) == signature(source.stat) &&
                                signature(initial) == signature(File.lstat(source_path))

  destination_flags = File::WRONLY | File::CREAT | File::EXCL
  destination_flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
  File.open(destination_path, destination_flags, 0o400) do |destination|
    destination.write(bytes)
    destination.flush
    destination.fsync
  end
end
RUBY
then
  die 'legacy parity snapshot failed'
fi
chmod 0400 "$encrypted_parity" || die 'legacy parity snapshot failed'
chmod 0500 "$snapshot_root" || die 'legacy parity snapshot failed'
[ "$(sed -n '1p' "$encrypted_parity")" = '$ANSIBLE_VAULT;1.1;AES256' ] ||
  die 'legacy parity snapshot failed'

decrypted_parity=$render_work/parity.yml
if ! ansible-vault view --vault-password-file "$PLATFORM_MAC_PARITY_VAULT_PASSWORD_FILE" \
    "$encrypted_parity" > "$decrypted_parity" 2>/dev/null; then
  die 'legacy parity rendering failed'
fi
chmod 0600 "$decrypted_parity" || die 'legacy parity rendering failed'
if ! ruby "$repo_dir/scripts/portainer-parity.rb" --validate-stdin \
    --mapping "$repo_dir/config/portainer-parity.yml" --legacy-commit "$expected_commit" \
    < "$decrypted_parity" >/dev/null 2>&1; then
  die 'legacy parity rendering failed'
fi

legacy_env_root=$render_work/legacy-env
mkdir -m 0700 "$legacy_env_root" || die 'legacy render staging failed'
if ! ansible-playbook -i localhost, -c local "$script_dir/legacy-render.yml" \
  --vault-password-file "$PLATFORM_MAC_PARITY_VAULT_PASSWORD_FILE" \
  -e @"$encrypted_parity" -e legacy_env_root="$legacy_env_root" \
  -e legacy_expected_commit="$expected_commit" >/dev/null 2>&1; then
  die 'legacy parity rendering failed'
fi

expected_services='audiobookshelf beszel dozzle immich jellyfin komga ntfy paperless-ngx tinymediamanager'
actual_services=$(/usr/bin/find "$legacy_env_root" -type f -name '*.env' -maxdepth 1 \
  -exec basename {} .env \; | sort | tr '\n' ' ')
[ "$actual_services" = "$expected_services " ] || die 'rendered legacy service set differs'
for service in $expected_services; do
  rendered=$legacy_env_root/$service.env
  [ -f "$rendered" ] && [ ! -L "$rendered" ] && [ "$(mac_owner_id "$rendered")" = "$(id -u)" ] &&
    [ "$(mac_file_mode "$rendered")" = 600 ] || die 'rendered legacy environment is unsafe'
done
previous_env_root=$render_work/previous-env
if [ -e "$published_env_root" ]; then
  mv "$published_env_root" "$previous_env_root" || die 'legacy environment publication failed'
fi
if ! mv "$legacy_env_root" "$published_env_root"; then
  if [ -d "$previous_env_root" ] && [ ! -e "$published_env_root" ]; then
    mv "$previous_env_root" "$published_env_root" || true
  fi
  die 'legacy environment publication failed'
fi
if [ -d "$previous_env_root" ] && [ ! -L "$previous_env_root" ]; then
  /usr/bin/find "$previous_env_root" -depth -delete
fi
printf '%s\n' 'Legacy adoption render: nine protected environments ready'
