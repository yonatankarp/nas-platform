#!/bin/sh
# Full legacy-adoption proof using only disposable Linux CI state.
set -eu
set +x
umask 077

die() {
  printf '%s\n' "synthetic-adoption-error: $1" >&2
  exit 1
}

diagnostics_operation() {
  ruby - "$@" <<'RUBY'
require "fiddle"
operation, parent_path, name, expected = ARGV
raise "unsafe" unless name == "nas-platform-adoption-diagnostics"
flags = File::RDONLY
flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
flags |= File::NONBLOCK if File.const_defined?(:NONBLOCK)
identity = ->(stat) { [stat.dev, stat.ino, stat.uid, stat.mode & 0o777].join(":") }
fchdir = Fiddle::Function.new(
  Fiddle::Handle::DEFAULT["fchdir"],
  [Fiddle::TYPE_INT],
  Fiddle::TYPE_INT
)
descriptor_chdir = lambda do |file, &block|
  previous = File.open(".", flags)
  raise "unsafe" unless fchdir.call(file.fileno).zero?
  begin
    block.call
  ensure
    restored = fchdir.call(previous.fileno).zero?
    previous.close
    raise "unsafe" unless restored
  end
end
parent = File.open(parent_path, flags)
parent_stat = parent.stat
raise "unsafe" unless parent_stat.directory? && parent_stat.uid == Process.uid &&
  (parent_stat.mode & 0o022).zero? && File.realpath(parent_path) == parent_path

if operation == "create"
  descriptor_chdir.call(parent) { Dir.mkdir(name, 0o700) }
end
directory = descriptor_chdir.call(parent) { File.open(name, flags) }
directory_stat = directory.stat
raise "unsafe" unless directory_stat.directory? && directory_stat.uid == Process.uid &&
  (directory_stat.mode & 0o777) == 0o700
signature = "#{identity.call(parent_stat)}|#{identity.call(directory_stat)}"
raise "unsafe" unless expected.empty? || signature == expected

case operation
when "create"
  puts signature
when "publish"
  output_flags = File::WRONLY | File::CREAT | File::EXCL
  output_flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
  output = descriptor_chdir.call(directory) do
    File.open("sanitized.txt", output_flags, 0o600)
  end
  begin
    output.write("synthetic legacy adoption failed; diagnostics are redacted\n")
    output.chmod(0o600)
    output.flush
    output.fsync
    directory.fsync
    current_parent = File.lstat(parent_path)
    current_directory = descriptor_chdir.call(parent) { File.lstat(name) }
    raise "unsafe" unless identity.call(current_parent) == identity.call(parent_stat) &&
      identity.call(current_directory) == identity.call(directory_stat)
  rescue Exception
    descriptor_chdir.call(directory) { File.unlink("sanitized.txt") rescue nil }
    raise
  ensure
    output.close
  end
when "remove"
  raise "unsafe" unless descriptor_chdir.call(directory) { Dir.children(".").empty? }
  current_parent = File.lstat(parent_path)
  current_directory = descriptor_chdir.call(parent) { File.lstat(name) }
  raise "unsafe" unless identity.call(current_parent) == identity.call(parent_stat) &&
    identity.call(current_directory) == identity.call(directory_stat)
  directory.close
  descriptor_chdir.call(parent) { Dir.rmdir(name) }
else
  raise "unsafe"
end
RUBY
}

owned_root_operation() {
  ruby - "$@" <<'RUBY'
require "fiddle"
operation, path, expected = ARGV
name = File.basename(path)
raise "unsafe" unless name.match?(/\Anas-platform-integration\.[A-Za-z0-9]{6}\z/)
flags = File::RDONLY
flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
flags |= File::NONBLOCK if File.const_defined?(:NONBLOCK)
identity = ->(stat) { [stat.dev, stat.ino, stat.uid, stat.mode & 0o777].join(":") }
fchdir = Fiddle::Function.new(
  Fiddle::Handle::DEFAULT["fchdir"],
  [Fiddle::TYPE_INT],
  Fiddle::TYPE_INT
)
descriptor_chdir = lambda do |file, &block|
  previous = File.open(".", flags)
  raise "unsafe" unless fchdir.call(file.fileno).zero?
  begin
    block.call
  ensure
    restored = fchdir.call(previous.fileno).zero?
    previous.close
    raise "unsafe" unless restored
  end
end
parent_path = File.dirname(path)
parent = File.open(parent_path, flags)
root = descriptor_chdir.call(parent) { File.open(name, flags) }
root_stat = root.stat
raise "unsafe" unless root_stat.directory? && (root_stat.mode & 0o777) == 0o700
root_signature = identity.call(root_stat)
marker_name = ".nas-platform-integration-owned"
if operation == "create"
  raise "unsafe" unless expected.empty? && root_stat.uid == Process.uid
  marker_flags = File::WRONLY | File::CREAT | File::EXCL
  marker_flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
  marker = descriptor_chdir.call(root) { File.open(marker_name, marker_flags, 0o600) }
  marker.write("schema=1\n")
  marker.chmod(0o600)
  marker.flush
  marker.fsync
  marker.close
  root.fsync
  marker_stat = descriptor_chdir.call(root) { File.lstat(marker_name) }
  marker_signature = identity.call(marker_stat)
  puts "#{identity.call(parent.stat)}|#{root_signature}|#{marker_signature}"
  puts "#{root_signature}|#{marker_signature}"
elsif operation == "verify"
  raise "unsafe" unless descriptor_chdir.call(root) { Dir.children(".") } == [marker_name]
  marker = descriptor_chdir.call(root) { File.open(marker_name, flags) }
  marker_stat = marker.stat
  raise "unsafe" unless marker_stat.file? && marker_stat.uid == root_stat.uid &&
    (marker_stat.mode & 0o777) == 0o600 && marker.read(4097) == "schema=1\n"
  signature = "#{root_signature}|#{identity.call(marker_stat)}"
  raise "unsafe" unless signature == expected
  puts signature
elsif operation == "remove"
  signature_prefix = "#{identity.call(parent.stat)}|#{root_signature}|"
  raise "unsafe" unless descriptor_chdir.call(root) { Dir.children(".") } == [marker_name]
  marker = descriptor_chdir.call(root) { File.open(marker_name, flags) }
  marker_stat = marker.stat
  raise "unsafe" unless marker_stat.file? && marker_stat.uid == Process.uid &&
    (marker_stat.mode & 0o777) == 0o600 && marker.read(4097) == "schema=1\n"
  raise "unsafe" unless root_stat.uid == Process.uid &&
    "#{signature_prefix}#{identity.call(marker_stat)}" == expected
  marker.close
  current_root = descriptor_chdir.call(parent) { File.lstat(name) }
  raise "unsafe" unless identity.call(current_root) == identity.call(root_stat)
  descriptor_chdir.call(root) { File.unlink(marker_name) }
  root.fsync
  root.close
  descriptor_chdir.call(parent) { Dir.rmdir(name) }
  parent.fsync
else
  raise "unsafe"
end
RUBY
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) || die 'repository is unavailable'
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd -P) || die 'repository is unavailable'
. "$script_dir/sandbox_cleanup.sh"

inner_mode=false
requested_owned_root=
requested_owned_identity=
case $#:${1-} in
  0:) ;;
  3:--inner)
    inner_mode=true
    requested_owned_root=$2
    requested_owned_identity=$3
    ;;
  *) die 'unsupported argument' ;;
esac
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

if [ "$inner_mode" = false ]; then
  runner_image=docker.io/library/python:3.13-alpine@sha256:399babc8b49529dabfd9c922f2b5eea81d611e4512e3ed250d75bd2e7683f4b0
  owned_root=$(mktemp -d "$temporary_parent/nas-platform-integration.XXXXXX") ||
    die 'could not create owned integration root'
  chmod 0700 "$owned_root"
  owned_root_signatures=$(owned_root_operation create "$owned_root" '') ||
    die 'could not bind owned integration root'
  owned_root_identity=$(printf '%s\n' "$owned_root_signatures" | sed -n '1p')
  owned_bind_identity=$(printf '%s\n' "$owned_root_signatures" | sed -n '2p')
  [ -n "$owned_root_identity" ] && [ -n "$owned_bind_identity" ] ||
    die 'could not bind owned integration root'

  finish_outer_early() {
    outer_status=$?
    trap - EXIT HUP INT TERM
    owned_root_operation remove "$owned_root" "$owned_root_identity" >/dev/null 2>&1 ||
      outer_status=1
    exit "$outer_status"
  }
  trap finish_outer_early EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  diagnostics_input=${ADOPTION_DIAGNOSTICS_DIR:-$temporary_parent/nas-platform-adoption-diagnostics}
  case $diagnostics_input in /*) ;; *) die 'diagnostics path is outside the temporary parent' ;; esac
  diagnostics_parent=$(CDPATH= cd -- "$(dirname -- "$diagnostics_input")" 2>/dev/null && pwd -P) ||
    die 'diagnostics parent is unavailable'
  [ "$diagnostics_parent" = "$temporary_parent" ] &&
    [ "$(basename -- "$diagnostics_input")" = nas-platform-adoption-diagnostics ] ||
    die 'diagnostics path is outside the temporary parent'
  diagnostics_input=$diagnostics_parent/nas-platform-adoption-diagnostics
  diagnostics_name=nas-platform-adoption-diagnostics
  diagnostics_identity=$(diagnostics_operation create "$diagnostics_parent" \
    "$diagnostics_name" '') || die 'diagnostics path is unsafe'

  finish_outer() {
    outer_status=$?
    trap - EXIT HUP INT TERM
    owned_root_operation remove "$owned_root" "$owned_root_identity" >/dev/null 2>&1 ||
      outer_status=1
    if [ "$outer_status" -eq 0 ]; then
      diagnostics_operation remove "$diagnostics_parent" "$diagnostics_name" \
        "$diagnostics_identity" >/dev/null 2>&1 || outer_status=1
    fi
    if [ "$outer_status" -ne 0 ]; then
      diagnostics_operation publish "$diagnostics_parent" "$diagnostics_name" \
        "$diagnostics_identity" >/dev/null 2>&1 || true
    fi
    exit "$outer_status"
  }
  trap finish_outer EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  docker run --rm --network host \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$repo_dir:$repo_dir:ro" -v "$legacy_root:$legacy_root:ro" \
    -v "$owned_root:$owned_root" -w "$repo_dir" \
    -e "NAS_INFRASTRUCTURE_DIR=$legacy_root" -e "RUNNER_TEMP=$owned_root" \
    "$runner_image" \
    sh -eu -c '
      apk add --no-cache --quiet docker-cli docker-cli-compose git tar openssl \
        apache2-utils openssh-client perl-utils ruby=3.4.9-r0 curl=8.21.0-r0 >/dev/null
      command -v shasum >/dev/null
      [ "$(printf "" | shasum -a 256 | cut -c 1-64)" = \
        e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ]
      ruby "$1/tests/mac/adoption-bind-prep-test.rb"
      pip install --quiet --no-input ansible-core==2.21.2
      ansible-galaxy collection install -r "$1/requirements.yml" >/dev/null
      git config --global --add safe.directory "$1"
      git config --global --add safe.directory "$2"
      exec "$4" --inner "$3" "$5"
    ' sh "$repo_dir" "$legacy_root" "$owned_root" "$script_dir/adoption-integration.sh" \
      "$owned_bind_identity"
  exit 0
fi

[ "$(id -u)" -eq 0 ] || die 'integration inner mode requires root'
case $requested_owned_root in /*/nas-platform-integration.??????) ;; *) die 'integration inner root is invalid' ;; esac
[ -d "$requested_owned_root" ] && [ ! -L "$requested_owned_root" ] &&
  [ -f "$requested_owned_root/.nas-platform-integration-owned" ] &&
  [ ! -L "$requested_owned_root/.nas-platform-integration-owned" ] &&
  [ "$(cat "$requested_owned_root/.nas-platform-integration-owned")" = schema=1 ] ||
  die 'integration inner root is invalid'
owned_root=$(CDPATH= cd -- "$requested_owned_root" && pwd -P) ||
  die 'integration inner root is invalid'
[ "$owned_root" = "$requested_owned_root" ] || die 'integration inner root is invalid'
[ "$(owned_root_operation verify "$owned_root" "$requested_owned_identity" 2>/dev/null)" = \
  "$requested_owned_identity" ] || die 'integration inner root identity differs'

sandbox=
deployment_vault_root=
parity_vault_root=
ports_file=
exports_root=

cleanup() {
  cleanup_status=$?
  trap - EXIT HUP INT TERM
  cleanup_failed=false

  if [ -n "$sandbox" ] && [ -d "$sandbox" ] && [ ! -L "$sandbox" ]; then
    PLATFORM_MAC_TMPDIR="$owned_root" "$repo_dir/tests/mac/cleanup.sh" "$sandbox" \
      >/dev/null 2>&1 || cleanup_failed=true
  fi
  report_root=$sandbox.reports
  if [ -n "$sandbox" ] && [ -d "$report_root" ] && [ ! -L "$report_root" ]; then
    cleanup_sandbox_contents "$owned_root" "$(basename -- "$report_root")" \
      .nas-platform-mac-report-owned >/dev/null 2>&1 || cleanup_failed=true
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
  if [ -n "$exports_root" ] && [ -d "$exports_root" ] && [ ! -L "$exports_root" ]; then
    for export_file in "$exports_root"/*.env; do
      [ -f "$export_file" ] && [ ! -L "$export_file" ] || { cleanup_failed=true; continue; }
      unlink "$export_file" || cleanup_failed=true
    done
    rmdir -- "$exports_root" 2>/dev/null || cleanup_failed=true
  fi
  if [ -n "$ports_file" ] && [ -f "$ports_file" ] && [ ! -L "$ports_file" ]; then
    unlink "$ports_file" || cleanup_failed=true
  fi
  [ "$cleanup_failed" = false ] || [ "$cleanup_status" -ne 0 ] || cleanup_status=1
  exit "$cleanup_status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

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
