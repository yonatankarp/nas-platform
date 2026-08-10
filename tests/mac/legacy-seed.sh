#!/bin/sh
set -eu
set +x
umask 077

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_dir=$(CDPATH= cd -- "$script_dir/../.." && pwd -P)
. "$script_dir/lib.sh"

die() {
  printf 'legacy-seed-error: %s\n' "$1" >&2
  exit 1
}

[ "$#" -eq 0 ] || die 'unsupported argument'

: "${PLATFORM_LEGACY_ROOT:?legacy-seed-error: PLATFORM_LEGACY_ROOT is required}"
: "${PLATFORM_MAC_SANDBOX:?legacy-seed-error: PLATFORM_MAC_SANDBOX is required}"
: "${PLATFORM_PROJECT_NAME:?legacy-seed-error: PLATFORM_PROJECT_NAME is required}"
: "${PLATFORM_MAC_VAULT_FILE:?legacy-seed-error: PLATFORM_MAC_VAULT_FILE is required}"
: "${PLATFORM_MAC_VAULT_PASSWORD_FILE:?legacy-seed-error: PLATFORM_MAC_VAULT_PASSWORD_FILE is required}"
PLATFORM_MAC_SANDBOX=$(mac_validate_sandbox "$PLATFORM_MAC_SANDBOX" 2>/dev/null) ||
  die 'owned sandbox is invalid'
owned_project=$(sed -n 's/^project=//p' "$PLATFORM_MAC_SANDBOX/.nas-platform-mac-owned")
[ "$PLATFORM_PROJECT_NAME" = "$owned_project" ] || die 'project name differs from owned sandbox'
[ -f "$PLATFORM_MAC_VAULT_FILE" ] && [ ! -L "$PLATFORM_MAC_VAULT_FILE" ] ||
  die 'deployment vault is unsafe'
[ -f "$PLATFORM_MAC_VAULT_PASSWORD_FILE" ] && \
  [ ! -L "$PLATFORM_MAC_VAULT_PASSWORD_FILE" ] || die 'deployment password is unsafe'

seed_root=$PLATFORM_MAC_SANDBOX/legacy-seed-runtime
if ! ruby - "$PLATFORM_MAC_SANDBOX" >/dev/null 2>&1 <<'RUBY'
sandbox = File.realpath(ARGV.fetch(0))
services = %w[audiobookshelf beszel dozzle immich jellyfin komga ntfy paperless_ngx tinymediamanager]
directories = ["legacy-seed-runtime/current/services", "legacy-seed-runtime/runtime/services"]
directories += services.flat_map do |service|
  ["legacy-seed-runtime/current/services/#{service}",
   "legacy-seed-runtime/runtime/services/#{service}"]
end
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
RUBY
then
  die 'legacy seed runtime is unsafe'
fi
if ! ruby - "$PLATFORM_MAC_SANDBOX/legacy-env/ntfy.env" \
    "$seed_root/runtime/services/ntfy/.env" >/dev/null 2>&1 <<'RUBY'
source_path, destination_path = ARGV
source_stat = File.lstat(source_path)
raise "unsafe" unless source_stat.file? && !source_stat.symlink? && source_stat.uid == Process.uid
begin
  destination_stat = File.lstat(destination_path)
  raise "unsafe" unless destination_stat.file? && !destination_stat.symlink? &&
    destination_stat.uid == Process.uid && (destination_stat.mode & 0o777) == 0o600
rescue Errno::ENOENT
  input_flags = File::RDONLY
  input_flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
  output_flags = File::WRONLY | File::CREAT | File::EXCL
  output_flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
  File.open(source_path, input_flags) do |source|
    raise "unsafe" unless source.stat.size <= 1024 * 1024
    File.open(destination_path, output_flags, 0o600) do |destination|
      IO.copy_stream(source, destination)
      destination.flush
      destination.fsync
    end
  end
end
RUBY
then
  die 'ntfy ownership environment is unsafe'
fi

legacy_files() {
  legacy_service=$1
  ruby -ryaml -rjson - "$repo_dir/services/manifest.yml" "$legacy_service" \
    "$PLATFORM_LEGACY_ROOT" "$script_dir/legacy-overrides/$legacy_service.yml" <<'RUBY'
manifest, requested, legacy_root, override = ARGV
entry = YAML.safe_load_file(manifest, aliases: false).fetch("services").find do |service|
  service.fetch("name") == requested
end
abort unless entry
path = entry.fetch("legacy_path")
abort unless path.is_a?(String) && path.match?(/\A[A-Za-z0-9_.\/-]+\z/) &&
  !path.start_with?("/") && !path.split("/").include?("..")
print JSON.generate([File.join(legacy_root, path), override])
RUBY
}

seed_role() {
  seed_service=$1
  seed_tag=$2
  seed_start=$3
  seed_port_variable=$4
  seed_port_value=$5
  seed_role_name=${6:-$seed_service}
  seed_project_variable=${7:-${seed_role_name}_compose_project_name}
  seed_files_variable=${8:-${seed_role_name}_compose_files}
  seed_vault_key=${9:-$seed_role_name}
  if [ "$seed_role_name" = tinymediamanager ]; then
    seed_managed_users_extra='{"vault_managed_tinymediamanager_users":[]}'
  else
    seed_managed_users_extra="vault_managed_${seed_role_name}_users={{ vault_managed_users.${seed_vault_key} }}"
  fi
  seed_compose_files=$(legacy_files "$seed_service")
  seed_files_extra=$(ruby -rjson - "$seed_files_variable" "$seed_compose_files" <<'RUBY'
name, files = ARGV
print JSON.generate(name => JSON.parse(files))
RUBY
) || die 'service Compose paths are invalid'
  if ! ansible-playbook -i "$repo_dir/inventory/mac.yml" "$repo_dir/site.yml" \
      --vault-password-file "$PLATFORM_MAC_VAULT_PASSWORD_FILE" \
      -e @"$PLATFORM_MAC_VAULT_FILE" -e "platform_vault_file=$PLATFORM_MAC_VAULT_FILE" \
      -e "platform_kind=mac" -e "platform_compose_kind=mac" \
      -e "nas_docker_root=$PLATFORM_MAC_SANDBOX/legacy" \
      -e "platform_current_dir=$seed_root/current" -e "platform_runtime_dir=$seed_root/runtime" \
      -e "$seed_port_variable=$seed_port_value" \
      -e "tinymediamanager_web_port=${PLATFORM_TINYMEDIAMANAGER_WEB_PORT:?}" \
      -e "$seed_project_variable=$PLATFORM_PROJECT_NAME-legacy-$seed_service" \
      -e "$seed_files_extra" \
      -e "$seed_managed_users_extra" \
      --tags "$seed_tag" --start-at-task "$seed_start" >/dev/null 2>&1; then
    die "$seed_service capability failed"
  fi
  if [ "$seed_role_name" = tinymediamanager ]; then
    printf 'legacy-seed: %s/administrator\n' "$seed_service"
    printf 'legacy-seed: %s/shared-login\n' "$seed_service"
  else
    printf 'legacy-seed: %s/administrator\n' "$seed_service"
    printf 'legacy-seed: %s/users\n' "$seed_service"
  fi
}

seed_role ntfy ntfy 'Inspect existing ntfy declarative ownership and users' \
  ntfy_port "${PLATFORM_NTFY_PORT:?}" ntfy ntfy_compose_project_name ntfy_compose_files ntfy
seed_role beszel beszel 'Wait for the hub to report healthy' \
  beszel_port "${PLATFORM_BESZEL_PORT:?}" beszel beszel_compose_project_name \
  beszel_compose_files beszel
seed_role dozzle dozzle 'Reconcile preserved and managed Dozzle users' \
  dozzle_port "${PLATFORM_DOZZLE_PORT:?}" dozzle dozzle_compose_project_name \
  dozzle_compose_files dozzle
seed_role audiobookshelf audiobookshelf 'Wait for Audiobookshelf to report healthy' \
  audiobookshelf_port "${PLATFORM_AUDIOBOOKSHELF_PORT:?}" audiobookshelf \
  audiobookshelf_compose_project_name audiobookshelf_compose_files audiobookshelf
seed_role komga komga 'Read Komga claim status' komga_port "${PLATFORM_KOMGA_PORT:?}" \
  komga komga_compose_project_name komga_compose_files komga
seed_role jellyfin jellyfin 'Wait for the Jellyfin startup API' \
  jellyfin_port "${PLATFORM_JELLYFIN_PORT:?}" jellyfin jellyfin_compose_project_name \
  jellyfin_compose_files jellyfin
seed_role immich immich 'Read Immich initialization state' immich_port \
  "${PLATFORM_IMMICH_PORT:?}" immich immich_compose_project_name immich_compose_files immich
seed_role paperless-ngx paperless 'Install the pinned Hebrew OCR model' \
  paperless_port "${PLATFORM_PAPERLESS_PORT:?}" paperless_ngx \
  paperless_compose_project_name paperless_compose_files paperless_ngx
seed_role tinymediamanager tinymediamanager 'Create the stable tinyMediaManager settings directory' \
  tinymediamanager_api_port "${PLATFORM_TINYMEDIAMANAGER_API_PORT:?}" tinymediamanager \
  tinymediamanager_compose_project_name tinymediamanager_compose_files tinymediamanager
printf '%s\n' 'legacy-seed: beszel/system-token-notification'
printf '%s\n' 'legacy-seed: dozzle/notification-state'
printf '%s\n' 'legacy-seed: paperless-ngx/mail-state'

fixtures_helper=${PLATFORM_FIXTURES_HELPER:-$script_dir/fixtures.sh}
[ -x "$fixtures_helper" ] && [ ! -L "$fixtures_helper" ] || die 'fixture helper is unavailable'
if [ "$fixtures_helper" != "$script_dir/fixtures.sh" ]; then
  mac_validate_lexical_path "$fixtures_helper" 'fixture helper' >/dev/null 2>&1 ||
    die 'fixture helper is unavailable'
  fixture_parent=$(CDPATH= cd -- "$(dirname -- "$fixtures_helper")" 2>/dev/null && pwd -P) ||
    die 'fixture helper is unavailable'
  [ "$fixture_parent/$(basename -- "$fixtures_helper")" = "$fixtures_helper" ] &&
    [ "$(mac_owner_id "$fixtures_helper")" = "$(id -u)" ] &&
    [ "$(mac_file_mode "$fixtures_helper")" = 700 ] || die 'fixture helper is unavailable'
  case $fixtures_helper in
    "$PLATFORM_MAC_SANDBOX"/*) ;;
    *) die 'fixture helper is unavailable' ;;
  esac
fi
printf '%s\n' 'legacy-seed: fixtures/media-books-photos-documents'
"$fixtures_helper" seed >/dev/null 2>&1 || die 'fixture capability failed'
