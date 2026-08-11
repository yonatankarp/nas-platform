#!/bin/sh
# Full legacy-adoption proof using only disposable Linux CI state.
set -eu
set +x
umask 077

die() {
  printf '%s\n' "synthetic-adoption-error: $1" >&2
  exit 1
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) || die 'repository is unavailable'
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd -P) || die 'repository is unavailable'
. "$script_dir/sandbox_cleanup.sh"

[ "$#" -eq 0 ] || die 'unsupported argument'
[ "$(uname -s)" = Linux ] || die 'integration platform requires Linux'

temporary_parent_input=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
case $temporary_parent_input in /*) ;; *) die 'temporary parent must be absolute' ;; esac
[ -d "$temporary_parent_input" ] && [ ! -L "$temporary_parent_input" ] ||
  die 'temporary parent is unsafe'
temporary_parent=$(CDPATH= cd -- "$temporary_parent_input" && pwd -P) ||
  die 'temporary parent is unavailable'

legacy_input=${NAS_INFRASTRUCTURE_DIR:-}
[ -n "$legacy_input" ] && [ -d "$legacy_input" ] && [ ! -L "$legacy_input" ] ||
  die 'pinned legacy checkout is unavailable'
legacy_root=$(CDPATH= cd -- "$legacy_input" && pwd -P) || die 'pinned legacy checkout is unavailable'
[ "$(dirname -- "$legacy_root")" = "$(dirname -- "$repo_dir")" ] &&
  [ "$(basename -- "$legacy_root")" = nas-infrastructure ] ||
  die 'pinned legacy checkout must be a non-repository sibling'

legacy_revision=$(ruby -ropen3 -ryaml - "$repo_dir" <<'RUBY'
repository = ARGV.fetch(0)
manifest_path = File.join(repository, "services/manifest.yml")
stat = File.lstat(manifest_path)
raise "unsafe" unless stat.file? && !stat.symlink?
head, _error, head_status = Open3.capture3("git", "-C", repository, "rev-parse", "HEAD")
head = head.strip
raise "unsafe" unless head_status.success? && head.match?(/\A[0-9a-f]{40}\z/)
blob, _blob_error, blob_status = Open3.capture3(
  "git", "-C", repository, "cat-file", "blob", "#{head}:services/manifest.yml"
)
raise "unsafe" unless blob_status.success? && File.binread(manifest_path) == blob
head_after, _after_error, after_status = Open3.capture3("git", "-C", repository, "rev-parse", "HEAD")
raise "unsafe" unless after_status.success? && head_after.strip == head
source = YAML.safe_load(blob, aliases: false).fetch("legacy_source")
print source.fetch("commit")
RUBY
) || die 'legacy manifest is invalid or differs from the controller revision'
[ "${#legacy_revision}" -eq 40 ] || die 'legacy manifest revision is invalid'
case $legacy_revision in *[!0123456789abcdef]*) die 'legacy manifest revision is invalid' ;; esac
[ "$(git -C "$legacy_root" rev-parse HEAD 2>/dev/null)" = "$legacy_revision" ] ||
  die 'legacy checkout revision differs from the manifest'
[ "$(git -C "$legacy_root" remote get-url origin 2>/dev/null)" = \
  'https://github.com/yonatankarp/nas-infrastructure.git' ] ||
  die 'legacy checkout origin differs from the manifest'
[ -z "$(git -C "$legacy_root" status --porcelain=v1 --untracked-files=all 2>/dev/null)" ] ||
  die 'legacy checkout must be clean'

owned_root=
sandbox=
deployment_vault_root=
parity_vault_root=
diagnostics_root=

cleanup() {
  cleanup_status=$?
  trap - EXIT HUP INT TERM
  cleanup_failed=false

  if [ -n "$sandbox" ] && [ -d "$sandbox" ] && [ ! -L "$sandbox" ]; then
    PLATFORM_MAC_TMPDIR="$owned_root" "$repo_dir/tests/mac/cleanup.sh" "$sandbox" \
      >/dev/null 2>&1 || cleanup_failed=true
  fi
  if [ -n "$deployment_vault_root" ] && [ -d "$deployment_vault_root" ] &&
     [ ! -L "$deployment_vault_root" ]; then
    TMPDIR="$owned_root" "$repo_dir/tests/generate-ephemeral-vault.sh" \
      --cleanup "$deployment_vault_root" >/dev/null 2>&1 || cleanup_failed=true
  fi
  if [ -n "$parity_vault_root" ] && [ -d "$parity_vault_root" ] &&
     [ ! -L "$parity_vault_root" ]; then
    TMPDIR="$owned_root" "$repo_dir/tests/generate-ephemeral-vault.sh" \
      --cleanup "$parity_vault_root" >/dev/null 2>&1 || cleanup_failed=true
  fi
  if [ "$cleanup_failed" = false ] && [ -n "$owned_root" ] &&
     [ -d "$owned_root" ] && [ ! -L "$owned_root" ]; then
    TMPDIR="$temporary_parent" cleanup_sandbox "$owned_root" >/dev/null 2>&1 ||
      cleanup_failed=true
  fi
  [ "$cleanup_failed" = false ] || [ "$cleanup_status" -ne 0 ] || cleanup_status=1
  if [ "$cleanup_status" -ne 0 ] && [ -n "$diagnostics_root" ] &&
     [ -d "$diagnostics_root" ] && [ ! -L "$diagnostics_root" ]; then
    printf '%s\n' 'synthetic legacy adoption failed; diagnostics are redacted' \
      > "$diagnostics_root/sanitized.txt" || cleanup_failed=true
    chmod 0600 "$diagnostics_root/sanitized.txt" 2>/dev/null || cleanup_failed=true
  elif [ "$cleanup_status" -eq 0 ] && [ -n "$diagnostics_root" ] &&
       [ -d "$diagnostics_root" ] && [ ! -L "$diagnostics_root" ]; then
    rmdir -- "$diagnostics_root" 2>/dev/null || {
      cleanup_failed=true
      cleanup_status=1
      printf '%s\n' 'synthetic legacy adoption failed; diagnostics are redacted' \
        > "$diagnostics_root/sanitized.txt" 2>/dev/null || true
      chmod 0600 "$diagnostics_root/sanitized.txt" 2>/dev/null || true
    }
  fi
  [ "$cleanup_failed" = false ] || [ "$cleanup_status" -ne 0 ] || cleanup_status=1
  exit "$cleanup_status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

owned_root=$(mktemp -d "$temporary_parent/nas-platform-integration.XXXXXX") ||
  die 'could not create owned integration root'
chmod 0700 "$owned_root"
printf '%s\n' 'schema=1' > "$owned_root/.nas-platform-integration-owned"
chmod 0600 "$owned_root/.nas-platform-integration-owned"

diagnostics_input=${ADOPTION_DIAGNOSTICS_DIR:-$temporary_parent/nas-platform-adoption-diagnostics}
case $diagnostics_input in /*) ;; *) die 'diagnostics path is outside the temporary parent' ;; esac
diagnostics_parent=$(CDPATH= cd -- "$(dirname -- "$diagnostics_input")" 2>/dev/null && pwd -P) ||
  die 'diagnostics parent is unavailable'
[ "$diagnostics_parent" = "$temporary_parent" ] &&
  [ "$(basename -- "$diagnostics_input")" = nas-platform-adoption-diagnostics ] ||
  die 'diagnostics path is outside the temporary parent'
[ "$diagnostics_input" = "$diagnostics_parent/nas-platform-adoption-diagnostics" ] ||
  diagnostics_input=$diagnostics_parent/nas-platform-adoption-diagnostics
[ ! -e "$diagnostics_input" ] && [ ! -L "$diagnostics_input" ] ||
  die 'diagnostics path already exists'
mkdir -m 0700 "$diagnostics_input"
diagnostics_root=$diagnostics_input

deployment_vault_root=$(mktemp -d "$owned_root/nas-platform-vault.XXXXXX")
parity_vault_root=$(mktemp -d "$owned_root/nas-platform-vault.XXXXXX")
chmod 0700 "$deployment_vault_root" "$parity_vault_root"
deployment_vault=$deployment_vault_root/vault.yml
deployment_password=$deployment_vault_root/password
parity_vault=$parity_vault_root/vault.yml
parity_password=$parity_vault_root/password
TMPDIR="$owned_root" "$repo_dir/tests/generate-ephemeral-vault.sh" \
  --output "$deployment_vault" --password-file "$deployment_password" >/dev/null
openssl rand -base64 32 > "$parity_password" 2>/dev/null
chmod 0600 "$parity_password"

ports_file=$owned_root/integration-ports.json
ruby -rsocket -rjson - "$ports_file" <<'RUBY'
path = ARGV.fetch(0)
names = %w[
  audiobookshelf_port beszel_port dozzle_port immich_port jellyfin_port komga_port
  ntfy_port paperless_port tinymediamanager_api_port tinymediamanager_web_port
]
sockets = names.map { TCPServer.new("127.0.0.1", 0) }
document = {"schema" => 1}
names.zip(sockets) { |name, socket| document[name] = socket.addr[1] }
File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |output|
  output.write(JSON.generate(document) << "\n")
  output.flush
  output.fsync
end
sockets.each(&:close)
RUBY
chmod 0600 "$ports_file"

exports_root=$owned_root/portainer-exports
mkdir -m 0700 "$exports_root"
ruby -ropen3 -ryaml -rjson - "$repo_dir/config/portainer-parity.yml" \
  "$repo_dir/inventory/group_vars/all/main.yml" "$repo_dir/roles/beszel/defaults/main.yml" \
  "$repo_dir/roles/paperless_ngx/defaults/main.yml" \
  "$deployment_vault" "$deployment_password" "$ports_file" "$exports_root" <<'RUBY'
mapping_path, inventory_path, beszel_path, paperless_path,
  vault_path, password_path, ports_path, output_root = ARGV
stdout, _stderr, status = Open3.capture3(
  "ansible-vault", "view", "--vault-password-file", password_path, vault_path
)
raise "vault view failed" unless status.success?
vault = YAML.safe_load(stdout, aliases: false)
mapping = YAML.safe_load_file(mapping_path, aliases: false)
ports = JSON.parse(File.binread(ports_path))
inventory = YAML.safe_load_file(inventory_path, aliases: false)
beszel = YAML.safe_load_file(beszel_path, aliases: false)
paperless = YAML.safe_load_file(paperless_path, aliases: false)
fixed = {
  "nas_timezone" => inventory.fetch("nas_timezone"),
  "nas_uid" => inventory.fetch("nas_uid"), "nas_gid" => inventory.fetch("nas_gid"),
  "beszel_app_url" => "http://127.0.0.1:#{ports.fetch('beszel_port')}",
  "beszel_system_name" => beszel.fetch("beszel_system_name"),
  "ntfy_base_url" => "http://127.0.0.1:#{ports.fetch('ntfy_port')}",
  "paperless_ai_enabled" => inventory.fetch("paperless_ai_enabled"),
  "paperless_ai_llm_endpoint" => inventory.fetch("paperless_ai_llm_endpoint"),
  "paperless_ai_llm_model" => inventory.fetch("paperless_ai_llm_model"),
  "paperless_task_workers" => paperless.fetch("paperless_task_workers"),
  "paperless_threads_per_worker" => paperless.fetch("paperless_threads_per_worker")
}
mapping.fetch("stacks").each do |service, rules|
  lines = rules.sort.map do |name, rule|
    target = rule.fetch("target")
    value = rule.fetch("classification") == "vault" ? vault.fetch(target) : fixed.fetch(target)
    raise "unsafe synthetic value" if value.to_s.match?(/[\r\n\0]/)
    "#{name}=#{value}"
  end
  path = File.join(output_root, "#{service}.env")
  File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |output|
    output.write(lines.join("\n") << "\n")
  end
end
RUBY
"$repo_dir/scripts/import-portainer-parity.sh" --input-dir "$exports_root" \
  --output "$parity_vault" --vault-password-file "$parity_password" >/dev/null

sandbox=$(mktemp -d "$owned_root/nas-platform-mac.XXXXXX")
chmod 0700 "$sandbox"
sandbox_suffix=$(printf '%s' "${sandbox##*.}" | tr '[:upper:]' '[:lower:]')
printf 'schema=1\nproject=nas-platform-mac-%s\n' "$sandbox_suffix" \
  > "$sandbox/.nas-platform-mac-owned"
chmod 0600 "$sandbox/.nas-platform-mac-owned"
mkdir -p "$sandbox/service-data/docker" "$sandbox/service-data/media" "$sandbox/fixtures"

NAS_INFRASTRUCTURE_DIR="$legacy_root" PLATFORM_MAC_TMPDIR="$owned_root" \
  "$repo_dir/tests/mac/run.sh" --lane adoption --platform integration \
  --integration-ports-file "$ports_file" \
  --vault-file "$deployment_vault" --vault-password-file "$deployment_password" \
  --parity-vault-file "$parity_vault" --parity-vault-password-file "$parity_password" \
  --sandbox "$sandbox"
