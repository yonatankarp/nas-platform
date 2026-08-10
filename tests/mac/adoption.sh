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
  preflight|render) ;;
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
  done
  docker version >/dev/null 2>&1 || die 'Docker is unavailable'
  export PLATFORM_LEGACY_ROOT=$legacy_root
}

preflight
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

legacy_env_root=$sandbox/legacy-env
if [ ! -e "$legacy_env_root" ]; then
  mkdir -m 0700 "$legacy_env_root"
fi
[ -d "$legacy_env_root" ] && [ ! -L "$legacy_env_root" ] &&
  [ "$(mac_owner_id "$legacy_env_root")" = "$(id -u)" ] &&
  [ "$(mac_file_mode "$legacy_env_root")" = 700 ] || die 'legacy environment directory is unsafe'

if ! ansible-playbook -i localhost, -c local "$script_dir/legacy-render.yml" \
  --vault-password-file "$PLATFORM_MAC_PARITY_VAULT_PASSWORD_FILE" \
  -e @"$PLATFORM_MAC_PARITY_VAULT_FILE" \
  -e legacy_env_root="$legacy_env_root" -e legacy_expected_commit="$expected_commit" \
  >/dev/null 2>&1; then
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
printf '%s\n' 'Legacy adoption render: nine protected environments ready'
