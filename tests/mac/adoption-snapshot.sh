#!/bin/sh
set -eu
set +x
umask 077

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$script_dir/lib.sh"

die() {
  printf 'adoption-snapshot-error: %s\n' "$1" >&2
  exit 1
}

[ "$#" -eq 7 ] || die 'expected ACTION --override-root PATH --baseline PATH --run-state PATH'
action=$1
shift
[ "$1" = --override-root ] || die 'expected --override-root'
override_root=$2
shift 2
[ "$1" = --baseline ] || die 'expected --baseline'
baseline=$2
shift 2
[ "$1" = --run-state ] || die 'expected --run-state'
run_state=$2
case $action in
  publish|verify|marker|marker-post-cutover|begin-cutover) ;;
  self-test-candidate-swap|self-test-post-publish-failure)
    [ "${PLATFORM_ADOPTION_SNAPSHOT_SELF_TEST:-}" = 1 ] || die 'self-test action is unavailable'
    ;;
  *) die 'unsupported action' ;;
esac

sandbox=$(mac_validate_sandbox "${PLATFORM_MAC_SANDBOX:?PLATFORM_MAC_SANDBOX is required}" 2>/dev/null) ||
  die 'owned sandbox is invalid'

target_mapping_root=$(CDPATH= cd -- "$script_dir/../../services" && pwd -P) ||
  die 'target adoption mapping root is unavailable'

if ! ruby - "$action" "$sandbox" "$override_root" "$baseline" "$run_state" \
    "$target_mapping_root" <<'RUBY'
require "digest"
require "fiddle/import"
require "json"
require "securerandom"

action, sandbox, override_root, baseline_path, run_state_path, target_mapping_root = ARGV
candidate_swap_self_test = action == "self-test-candidate-swap"
post_publish_self_test = action == "self-test-post-publish-failure"
EXPECTED_SERVICES = %w[
  audiobookshelf beszel dozzle immich jellyfin komga ntfy paperless-ngx tinymediamanager
].freeze
EXPECTED_BINDINGS = %w[
  audiobookshelf|legacy/audiobookshelf/config|/config
  audiobookshelf|legacy/audiobookshelf/metadata|/metadata
  audiobookshelf|legacy/audiobookshelf/media|/audiobooks
  beszel|legacy/beszel/hub|/beszel_data
  beszel|legacy/beszel/agent|/var/lib/beszel-agent
  beszel|legacy/beszel/volume1|/extra-filesystems/volume1
  beszel|legacy/beszel/volume2|/extra-filesystems/volume2
  dozzle|legacy/dozzle/data|/data
  immich|legacy/immich/data|/data
  immich|legacy/immich/thumbs|/data/thumbs
  immich|legacy/immich/encoded-video|/data/encoded-video
  immich|legacy/immich/profile|/data/profile
  immich|legacy/immich/backups|/data/backups
  immich|legacy/immich/model-cache|/cache
  immich|legacy/immich/postgres|/var/lib/postgresql/data
  jellyfin|legacy/jellyfin/config|/config
  jellyfin|legacy/jellyfin/cache|/cache
  jellyfin|legacy/jellyfin/media|/media
  komga|legacy/komga/config|/config
  komga|legacy/komga/library|/data
  ntfy|legacy/ntfy/cache|/var/cache/ntfy
  ntfy|legacy/ntfy/data|/var/lib/ntfy
  paperless-ngx|legacy/paperless-ngx/redis|/data
  paperless-ngx|legacy/paperless-ngx/postgres|/var/lib/postgresql
  paperless-ngx|legacy/paperless-ngx/data|/usr/src/paperless/data
  paperless-ngx|legacy/paperless-ngx/export|/usr/src/paperless/export
  paperless-ngx|legacy/paperless-ngx/tessdata/heb.traineddata|/usr/share/tesseract-ocr/5/tessdata/heb.traineddata
  paperless-ngx|legacy/paperless-ngx/media|/usr/src/paperless/media
  paperless-ngx|legacy/paperless-ngx/consume|/usr/src/paperless/consume
  tinymediamanager|legacy/tinymediamanager/data|/data
  tinymediamanager|legacy/tinymediamanager/movies|/media/Movies
  tinymediamanager|legacy/tinymediamanager/series|/media/Series
].map { |entry| entry.split("|", 3) }.freeze
BINDING_FIELDS = %w[
  schema lane sandbox_id project_name legacy_commit git_revision vault_checksum parity_vault_checksum
  baseline_sha256 inventory_sha256 overrides_sha256
].freeze
CUTOVER_FIELDS = %w[
  schema binding_sha256 lane sandbox_id project_name legacy_commit git_revision vault_checksum
  parity_vault_checksum
].freeze
AT_REMOVEDIR = 0x80

module SnapshotFileSystem
  extend Fiddle::Importer
  dlload Fiddle.dlopen(nil)
  extern "int openat(int, const char *, int, int)"
  extern "int mkdirat(int, const char *, int)"
  extern "int renameat(int, const char *, int, const char *)"
  extern "int linkat(int, const char *, int, const char *, int)"
  extern "int unlinkat(int, const char *, int)"
  extern "int futimens(int, const void *)"
end

def refuse(message)
  warn "adoption-snapshot-error: #{message}"
  exit 1
end

def mode(stat)
  stat.mode & 0o7777
end

def secure_file_bytes_path(path, label, expected_mode: nil)
  absolute = File.expand_path(path)
  components = absolute.split(File::SEPARATOR).reject(&:empty?)
  parent = File.open(File::SEPARATOR, File::RDONLY | File::NOFOLLOW)
  bindings = []
  components[0...-1].each do |component|
    child = open_directory_at(parent, component)
    bindings << [parent, component, entry_signature(child.stat)]
    parent = child
  end
  file = open_at(parent, components.last, File::RDONLY | File::NOFOLLOW)
  stat = file.stat
  refuse("#{label} is unsafe") unless stat.file? && stat.uid == Process.uid &&
    (!expected_mode || mode(stat) == expected_mode)
  bytes = file.read
  refuse("#{label} changed") unless entry_signature(file.stat) == entry_signature(stat)
  bindings.each do |bound_parent, component, signature|
    rebound = open_directory_at(bound_parent, component)
    refuse("#{label} changed") unless entry_signature(rebound.stat) == signature
    rebound.close
  end
  bytes
rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP
  refuse("#{label} is unavailable")
ensure
  file&.close
  bindings&.each { |bound_parent,| bound_parent.close unless bound_parent.closed? }
  parent&.close unless parent&.closed?
end

def open_bound_directory(path, label)
  components = File.expand_path(path).split(File::SEPARATOR).reject(&:empty?)
  parent = File.open(File::SEPARATOR, File::RDONLY | File::NOFOLLOW)
  bindings = []
  components.each do |component|
    child = open_directory_at(parent, component)
    bindings << [parent, component, entry_signature(child.stat)]
    parent = child
  end
  bindings.each do |bound_parent, component, signature|
    rebound = open_directory_at(bound_parent, component)
    refuse("#{label} changed") unless entry_signature(rebound.stat) == signature
    rebound.close
  end
  result = parent.dup
  result
rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP
  refuse("#{label} is unavailable or unsafe")
ensure
  bindings&.each { |bound_parent,| bound_parent.close unless bound_parent.closed? }
  parent&.close unless parent&.closed?
end

def read_file_at(parent, name, label, expected_mode = nil)
  file = open_at(parent, name, File::RDONLY | File::NOFOLLOW)
  stat = file.stat
  refuse("#{label} is unsafe") unless stat.file? && stat.uid == Process.uid &&
    (!expected_mode || mode(stat) == expected_mode)
  bytes = file.read
  refuse("#{label} changed") unless entry_signature(file.stat) == entry_signature(stat)
  rebound = open_at(parent, name, File::RDONLY | File::NOFOLLOW)
  refuse("#{label} changed") unless entry_signature(rebound.stat) == entry_signature(stat)
  bytes
ensure
  rebound&.close
  file&.close
end

def write_bytes_at(parent, name, bytes, permissions)
  file = open_at(parent, name, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, permissions)
  file.write(bytes)
  file.flush
  file.chmod(permissions)
  file.fsync
ensure
  file&.close
end

def safe_component(name)
  refuse("snapshot path component is unsafe") if name.empty? || [".", ".."].include?(name) ||
    name.include?(File::SEPARATOR) || name.include?("\0")
  name
end

def open_at(parent, name, flags, permissions = 0)
  descriptor = SnapshotFileSystem.openat(parent.fileno, safe_component(name), flags, permissions)
  raise SystemCallError.new("openat", Fiddle.last_error) if descriptor.negative?
  File.for_fd(descriptor, autoclose: true).tap { |file| file.close_on_exec = true }
end

def mkdir_at(parent, name, permissions)
  result = SnapshotFileSystem.mkdirat(parent.fileno, safe_component(name), permissions)
  raise SystemCallError.new("mkdirat", Fiddle.last_error) if result.negative?
end

def rename_at(parent, source, destination)
  result = SnapshotFileSystem.renameat(
    parent.fileno, safe_component(source), parent.fileno, safe_component(destination)
  )
  raise SystemCallError.new("renameat", Fiddle.last_error) if result.negative?
end

def link_at(parent, source, destination)
  result = SnapshotFileSystem.linkat(
    parent.fileno, safe_component(source), parent.fileno, safe_component(destination), 0
  )
  raise SystemCallError.new("linkat", Fiddle.last_error) if result.negative?
end

def unlink_at(parent, name, directory: false)
  flags = directory ? AT_REMOVEDIR : 0
  result = SnapshotFileSystem.unlinkat(parent.fileno, safe_component(name), flags)
  raise SystemCallError.new("unlinkat", Fiddle.last_error) if result.negative?
end

def descriptor_children(directory)
  duplicate = directory.dup
  duplicate.autoclose = false
  Dir.for_fd(duplicate.fileno).children.sort
ensure
  duplicate&.close if duplicate&.autoclose?
end

def remove_tree_at(parent, name)
  entry = open_at(parent, name, File::RDONLY | File::NOFOLLOW)
  if entry.stat.directory?
    entry.chmod(0o700)
    descriptor_children(entry).each { |child| remove_tree_at(entry, child) }
    entry.close
    unlink_at(parent, name, directory: true)
  else
    entry.close
    unlink_at(parent, name)
  end
rescue Errno::ELOOP
  unlink_at(parent, name)
ensure
  entry&.close unless entry&.closed?
end

def entry_signature(stat)
  [stat.dev, stat.ino, stat.size, stat.mode, stat.uid, stat.gid, stat.mtime.to_r, stat.ctime.to_r]
end

def identity_signature(stat)
  [stat.dev, stat.ino, stat.mode, stat.uid, stat.gid]
end

def set_descriptor_times(file, stat)
  values = [stat.atime, stat.mtime].flat_map { |time| [time.to_i, time.nsec] }
  buffer = values.pack("l!l!l!l!")
  result = SnapshotFileSystem.futimens(file.fileno, buffer)
  raise SystemCallError.new("futimens", Fiddle.last_error) if result.negative?
end

def metadata_entry(stat, relative, digest = nil)
  entry = {
    "path" => relative, "type" => stat.directory? ? "directory" : "file",
    "mode" => mode(stat), "uid" => stat.uid, "gid" => stat.gid,
    "size" => stat.size, "mtime_ns" => (stat.mtime.to_r * 1_000_000_000).to_i
  }
  entry["sha256"] = digest if digest
  entry
end

def digest_descriptor(file)
  file.rewind
  digest = Digest::SHA256.new
  digest.update(file.read(64 * 1024)) until file.eof?
  file.rewind
  digest.hexdigest
end

def inventory_entry_at(parent, name, relative, entries)
  source = open_at(parent, name, File::RDONLY | File::NOFOLLOW)
  before = source.stat
  refuse("state source is unsafe") unless before.directory? || before.file?
  digest = before.file? ? digest_descriptor(source) : nil
  entries << metadata_entry(before, relative, digest)
  if before.directory?
    descriptor_children(source).each do |child|
      inventory_entry_at(source, child, File.join(relative, child), entries)
    end
  end
  refuse("state source changed during inventory") unless entry_signature(source.stat) == entry_signature(before)
  rebound = open_at(parent, name, File::RDONLY | File::NOFOLLOW)
  refuse("state source changed during inventory") unless entry_signature(rebound.stat) == entry_signature(before)
ensure
  rebound&.close
  source&.close
end

def inventory_roots_at(root, roots)
  entries = []
  roots.each do |relative|
    components = relative.split("/")
    parent = root.dup
    components[0...-1].each do |component|
      child = open_directory_at(parent, component)
      parent.close
      parent = child
    end
    inventory_entry_at(parent, components.last, relative, entries)
  ensure
    parent&.close
  end
  entries
end

def inventories_match?(left, right)
  normalize = lambda do |entries|
    entries.map do |entry|
      copy = entry.dup
      copy.delete("size") if copy["type"] == "directory"
      copy
    end
  end
  normalize.call(left) == normalize.call(right)
end

def open_directory_at(parent, name)
  directory = open_at(parent, name, File::RDONLY | File::NOFOLLOW)
  refuse("state source is unsafe") unless directory.stat.directory?
  directory
end

def ensure_directory_at(parent, name)
  begin
    directory = open_directory_at(parent, name)
  rescue Errno::ENOENT
    mkdir_at(parent, name, 0o700)
    directory = open_directory_at(parent, name)
  end
  refuse("snapshot destination is unsafe") unless directory.stat.uid == Process.uid
  directory
end

def copy_entry_at(source_parent, source_name, destination_parent, destination_name, relative, entries)
  source = open_at(source_parent, source_name, File::RDONLY | File::NOFOLLOW)
  before = source.stat
  if before.directory?
    entries << metadata_entry(before, relative)
    mkdir_at(destination_parent, destination_name, 0o700)
    destination = open_directory_at(destination_parent, destination_name)
    descriptor_children(source).each do |child|
      copy_entry_at(source, child, destination, child, File.join(relative, child), entries)
    end
    begin
      destination.chown(before.uid, before.gid)
    rescue SystemCallError
      refuse("snapshot cannot preserve state ownership")
    end
    destination.chmod(mode(before))
    set_descriptor_times(destination, before)
    destination.fsync
  elsif before.file?
    flags = File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW
    destination = open_at(destination_parent, destination_name, flags, mode(before))
    digest = Digest::SHA256.new
    until source.eof?
      chunk = source.read(64 * 1024)
      digest.update(chunk)
      destination.write(chunk)
    end
    destination.flush
    begin
      destination.chown(before.uid, before.gid)
    rescue SystemCallError
      refuse("snapshot cannot preserve state ownership")
    end
    destination.chmod(mode(before))
    set_descriptor_times(destination, before)
    destination.fsync
    source.rewind
    second_digest = Digest::SHA256.new
    second_digest.update(source.read(64 * 1024)) until source.eof?
    refuse("state source changed during copy") unless second_digest.hexdigest == digest.hexdigest
    entries << metadata_entry(before, relative, digest.hexdigest)
  else
    refuse("state source is unsafe")
  end
  refuse("state source changed during copy") unless entry_signature(source.stat) == entry_signature(before)
  rebound = open_at(source_parent, source_name, File::RDONLY | File::NOFOLLOW)
  refuse("state source changed during copy") unless entry_signature(rebound.stat) == entry_signature(before)
rescue Errno::ELOOP
  refuse("state source is unsafe")
rescue Errno::ENOENT, Errno::ENOTDIR
  refuse("state source is unavailable")
ensure
  rebound&.close
  destination&.close
  source&.close
end

def copy_relative_root(sandbox_directory, state_directory, relative, entries)
  components = relative.split("/")
  source_parent = sandbox_directory.dup
  destination_parent = state_directory.dup
  components[0...-1].each do |component|
    next_source = open_directory_at(source_parent, component)
    source_parent.close
    source_parent = next_source
    next_destination = ensure_directory_at(destination_parent, component)
    destination_parent.close
    destination_parent = next_destination
  end
  copy_entry_at(
    source_parent, components.last, destination_parent, components.last,
    relative, entries
  )
rescue Errno::ELOOP
  refuse("state source is unsafe")
rescue Errno::ENOENT, Errno::ENOTDIR
  refuse("state source is unavailable")
ensure
  source_parent&.close
  destination_parent&.close
end

def mapping_bindings(directory, names, variable, label, digest, service_name: nil)
  names.flat_map do |name|
    service = service_name || name.delete_suffix(".yml")
    bytes = read_file_at(directory, name, label)
    digest.update(label).update("\0").update(service).update("\0")
      .update(name).update("\0").update(bytes).update("\0")
    bytes.lines(chomp: true).filter_map do |line|
      match = line.match(
        %r{^\s*-\s+\$\{#{Regexp.escape(variable)}:\?\}/(legacy/[^:]+):(/[^:]+)(?::(?:ro|rw))?\s*$}
      )
      if line.include?("${#{variable}") && !match
        refuse("#{label} bind mapping is unsafe")
      end
      next unless match

      relative, target = match.captures
      components = relative.split("/")
      refuse("#{label} bind mapping is unsafe") unless components.first == "legacy" &&
        components.all? { |part| part.match?(/\A[-.A-Za-z0-9]+\z/) && ![".", ".."].include?(part) }
      [service, relative, target]
    end
  end
end

def binding_sources(override_root, target_mapping_root)
  directory = open_bound_directory(File.expand_path(override_root), "reviewed override root")
  files = descriptor_children(directory)
  expected = EXPECTED_SERVICES.map { |service| "#{service}.yml" }
  refuse("reviewed override service set differs") unless files == expected
  mappings_digest = Digest::SHA256.new
  legacy_bindings = mapping_bindings(
    directory, files, "PLATFORM_MAC_SANDBOX", "reviewed legacy mapping", mappings_digest
  )
  refuse("legacy adoption mapping differs from committed policy") unless
    legacy_bindings.sort == EXPECTED_BINDINGS.sort

  target_directory = open_bound_directory(File.expand_path(target_mapping_root), "target mapping root")
  target_bindings = EXPECTED_SERVICES.flat_map do |service|
    service_directory = open_directory_at(target_directory, service)
    mapping_bindings(
      service_directory, ["compose.adoption.yml"], "PLATFORM_ADOPTION_ROOT",
      "target adoption mapping", mappings_digest, service_name: service
    )
  ensure
    service_directory&.close
  end
  refuse("target adoption mapping differs from committed policy") unless
    target_bindings.sort == EXPECTED_BINDINGS.sort
  roots = EXPECTED_BINDINGS.map { |_, source,| source }.sort
  refuse("committed adoption sources are duplicated") unless roots.uniq.length == roots.length
  [roots, mappings_digest.hexdigest]
rescue Errno::ENOENT, Errno::ENOTDIR
  refuse("adoption mapping input is unavailable")
ensure
  directory&.close
  target_directory&.close
end

def write_json_at(parent, name, value, permissions)
  write_bytes_at(parent, name, "#{JSON.generate(value)}\n", permissions)
end

def load_run_state(path)
  state = JSON.parse(secure_file_bytes_path(path, "run state"), create_additions: false)
  fields = %w[lane sandbox_id project_name legacy_commit git_revision vault_checksum parity_vault_checksum]
  values = fields.to_h { |field| [field, state.fetch(field)] }
  refuse("run state identity is invalid") unless values.values.all? { |value| value.is_a?(String) && !value.empty? }
  refuse("run state identity is invalid") unless values["lane"] == "adoption"
  values
rescue JSON::ParserError, KeyError
  refuse("run state identity is invalid")
end

def load_binding_bytes(bytes)
  binding = JSON.parse(bytes, create_additions: false)
  refuse("snapshot binding fields differ") unless binding.is_a?(Hash) && binding.keys.sort == BINDING_FIELDS.sort
  binding
rescue JSON::ParserError
  refuse("snapshot binding is invalid")
end

def cutover_value(binding, binding_bytes)
  {
    "schema" => 1,
    "binding_sha256" => Digest::SHA256.hexdigest(binding_bytes)
  }.merge(binding.slice(
    "lane", "sandbox_id", "project_name", "legacy_commit", "git_revision",
    "vault_checksum", "parity_vault_checksum"
  ))
end

def validate_cutover_bytes(bytes, binding, binding_bytes)
  transition = JSON.parse(bytes, create_additions: false)
  refuse("cutover transition fields differ") unless
    transition.is_a?(Hash) && transition.keys.sort == CUTOVER_FIELDS.sort
  refuse("cutover transition binding differs") unless transition == cutover_value(binding, binding_bytes)
  transition
rescue JSON::ParserError
  refuse("cutover transition is invalid")
end

def publish_cutover_transition(parent, snapshot, binding, binding_bytes,
                                parent_signature, snapshot_signature)
  candidate = ".cutover-started-#{SecureRandom.hex(16)}"
  published = false
  begin
    write_json_at(parent, candidate, cutover_value(binding, binding_bytes), 0o400)
    rebound_snapshot = open_directory_at(parent, "pre-cutover")
    refuse("published snapshot changed before cutover transition") unless
      identity_signature(parent.stat) == parent_signature &&
      identity_signature(snapshot.stat) == snapshot_signature &&
      identity_signature(rebound_snapshot.stat) == snapshot_signature
    link_at(parent, candidate, "cutover-started.json")
    published = true
    unlink_at(parent, candidate)
    candidate = nil
    parent.fsync
    bytes = read_file_at(parent, "cutover-started.json", "cutover transition", 0o400)
    validate_cutover_bytes(bytes, binding, binding_bytes)
    published = false
  rescue Errno::EEXIST
    refuse("cutover transition changed concurrently")
  rescue Exception # rubocop:disable Lint/RescueException
    if published
      unlink_at(parent, "cutover-started.json")
      parent.fsync
    end
    raise
  ensure
    rebound_snapshot&.close
    begin
      unlink_at(parent, candidate) if candidate
    rescue Errno::ENOENT
      nil
    end
  end
end

def verify_snapshot(sandbox_directory, roots, overrides_digest, baseline_path, run_state_path,
                    compare_source: true, transition_mode: :none)
  sandbox_directory = sandbox_directory.dup
  snapshot_parent_directory = open_directory_at(sandbox_directory, "snapshot")
  snapshot_directory = open_directory_at(snapshot_parent_directory, "pre-cutover")
  snapshot_parent_binding = identity_signature(snapshot_parent_directory.stat)
  snapshot_binding = identity_signature(snapshot_directory.stat)
  snapshot_stat = snapshot_directory.stat
  refuse("published snapshot is unsafe") unless snapshot_stat.directory? && !snapshot_stat.symlink? &&
    snapshot_stat.uid == Process.uid && mode(snapshot_stat) == 0o500
  baseline_copy_bytes = read_file_at(snapshot_directory, "baseline.json", "snapshot baseline", 0o400)
  inventory_bytes = read_file_at(snapshot_directory, "inventory.json", "snapshot inventory", 0o400)
  binding_bytes = read_file_at(snapshot_directory, "binding.json", "snapshot binding", 0o400)
  binding = load_binding_bytes(binding_bytes)
  begin
    cutover_bytes = read_file_at(
      snapshot_parent_directory, "cutover-started.json", "cutover transition", 0o400
    )
  rescue Errno::ENOENT
    cutover_bytes = nil
  end
  if cutover_bytes
    validate_cutover_bytes(cutover_bytes, binding, binding_bytes)
  elsif transition_mode == :required
    refuse("cutover transition is unavailable")
  end
  compare_source = false if transition_mode == :begin && cutover_bytes
  refuse("reviewed overrides changed") unless binding["overrides_sha256"] == overrides_digest
  current_state = load_run_state(run_state_path)
  refuse("snapshot run identity changed") unless current_state.all? { |key, value| binding[key] == value }
  baseline_bytes = secure_file_bytes_path(baseline_path, "baseline", expected_mode: 0o600)
  baseline_digest = Digest::SHA256.hexdigest(baseline_bytes)
  refuse("snapshot baseline changed") unless binding["baseline_sha256"] == baseline_digest &&
    Digest::SHA256.hexdigest(baseline_copy_bytes) == baseline_digest
  refuse("snapshot inventory changed") unless
    binding["inventory_sha256"] == Digest::SHA256.hexdigest(inventory_bytes)
  inventory = JSON.parse(inventory_bytes, create_additions: false)
  refuse("snapshot inventory roots differ") unless inventory.is_a?(Hash) && inventory["schema"] == 1 &&
    inventory["verified"] == true && inventory["roots"].is_a?(Array) &&
    inventory["roots"].map { |entry| entry["path"] } == roots
  recorded_entries = inventory.fetch("entries")
  state_directory = open_directory_at(snapshot_directory, "state")
  state_binding = identity_signature(state_directory.stat)
  copied_entries = inventory_roots_at(state_directory, roots)
  refuse("snapshot copy inventory differs") unless inventories_match?(copied_entries, recorded_entries)
  if compare_source
    source_entries = inventory_roots_at(sandbox_directory, roots)
    refuse("adopted state changed after snapshot") unless source_entries == recorded_entries
  end
  refuse("snapshot binding changed during validation") unless
    load_binding_bytes(read_file_at(snapshot_directory, "binding.json", "snapshot binding", 0o400)) == binding
  if cutover_bytes
    refuse("cutover transition changed during validation") unless
      read_file_at(snapshot_parent_directory, "cutover-started.json", "cutover transition", 0o400) ==
        cutover_bytes
  end
  rebound_state = open_directory_at(snapshot_directory, "state")
  rebound_snapshot = open_directory_at(snapshot_parent_directory, "pre-cutover")
  rebound_parent = open_directory_at(sandbox_directory, "snapshot")
  refuse("published snapshot changed during validation") unless
    identity_signature(rebound_state.stat) == state_binding &&
    identity_signature(rebound_snapshot.stat) == snapshot_binding &&
    identity_signature(rebound_parent.stat) == snapshot_parent_binding
  if transition_mode == :begin && !cutover_bytes
    publish_cutover_transition(
      snapshot_parent_directory, snapshot_directory, binding, binding_bytes,
      snapshot_parent_binding, snapshot_binding
    )
  end
  Digest::SHA256.hexdigest(binding_bytes)
rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP, JSON::ParserError, KeyError
  refuse("published snapshot is incomplete")
ensure
  state_directory&.close
  rebound_state&.close
  rebound_snapshot&.close
  rebound_parent&.close
  snapshot_directory&.close
  snapshot_parent_directory&.close
  sandbox_directory&.close
end

requested_sandbox = sandbox
sandbox = File.realpath(requested_sandbox)
refuse("owned sandbox changed") unless sandbox == requested_sandbox
sandbox_directory = open_bound_directory(sandbox, "owned sandbox")
begin
  snapshot_lock = open_at(
    sandbox_directory, ".adoption-snapshot.lock",
    File::RDWR | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600
  )
  snapshot_lock.chmod(0o600)
  snapshot_lock.fsync
rescue Errno::EEXIST
  snapshot_lock = open_at(sandbox_directory, ".adoption-snapshot.lock", File::RDWR | File::NOFOLLOW)
end
lock_stat = snapshot_lock.stat
refuse("snapshot lock is unsafe") unless lock_stat.file? && lock_stat.uid == Process.uid &&
  mode(lock_stat) == 0o600
refuse("snapshot lock is held") unless snapshot_lock.flock(File::LOCK_EX | File::LOCK_NB)
roots, overrides_digest = binding_sources(override_root, target_mapping_root)
snapshot_parent = File.join(sandbox, "snapshot")

if %w[verify marker marker-post-cutover begin-cutover].include?(action)
  transition_mode = case action
                    when "marker-post-cutover" then :required
                    when "begin-cutover" then :begin
                    else :none
                    end
  marker = verify_snapshot(
    sandbox_directory, roots, overrides_digest, baseline_path, run_state_path,
    compare_source: action != "marker-post-cutover", transition_mode: transition_mode
  )
  puts marker if action.start_with?("marker") || action == "begin-cutover"
  exit 0
end

baseline_bytes = secure_file_bytes_path(baseline_path, "baseline", expected_mode: 0o600)
run_identity = load_run_state(run_state_path)
baseline_digest = Digest::SHA256.hexdigest(baseline_bytes)
begin
  snapshot_parent_directory = open_directory_at(sandbox_directory, "snapshot")
rescue Errno::ENOENT
  mkdir_at(sandbox_directory, "snapshot", 0o700)
  snapshot_parent_directory = open_directory_at(sandbox_directory, "snapshot")
end
refuse("snapshot directory is unsafe") unless snapshot_parent_directory.stat.uid == Process.uid &&
  mode(snapshot_parent_directory.stat) == 0o700
begin
  existing_publication = open_directory_at(snapshot_parent_directory, "pre-cutover")
rescue Errno::ENOENT
  existing_publication = nil
end
if existing_publication
  existing_publication.close
  verify_snapshot(sandbox_directory, roots, overrides_digest, baseline_path, run_state_path)
  exit 0
end

candidate_name = ".candidate-#{SecureRandom.hex(16)}"
candidate_path = File.join(snapshot_parent, candidate_name)
published_by_call = false
candidate_created = false
begin
  mkdir_at(snapshot_parent_directory, candidate_name, 0o700)
  candidate_created = true
  candidate_directory = open_directory_at(snapshot_parent_directory, candidate_name)
  state_copy = File.join(candidate_path, "state")
  mkdir_at(candidate_directory, "state", 0o700)
  state_directory = open_directory_at(candidate_directory, "state")
  state_binding = identity_signature(state_directory.stat)
  if candidate_swap_self_test
    File.rename(state_copy, File.join(candidate_path, "state-held"))
    File.symlink(ENV.fetch("PLATFORM_SNAPSHOT_ESCAPE"), state_copy)
  end
  source_entries = []
  roots.each do |relative|
    copy_relative_root(sandbox_directory, state_directory, relative, source_entries)
  end
  state_directory.fsync
  copied_entries = inventory_roots_at(state_directory, roots)
  refuse("snapshot copy inventory differs") unless inventories_match?(copied_entries, source_entries)
  write_bytes_at(candidate_directory, "baseline.json", baseline_bytes, 0o400)
  refuse("snapshot baseline changed") unless
    Digest::SHA256.hexdigest(secure_file_bytes_path(baseline_path, "baseline", expected_mode: 0o600)) ==
      baseline_digest
  inventory = {
    "schema" => 1, "verified" => true,
    "roots" => roots.map { |path| { "path" => path } }, "entries" => source_entries
  }
  write_json_at(candidate_directory, "inventory.json", inventory, 0o400)
  inventory_digest = Digest::SHA256.hexdigest(
    read_file_at(candidate_directory, "inventory.json", "snapshot inventory", 0o400)
  )
  binding = { "schema" => 1 }.merge(run_identity).merge(
    "baseline_sha256" => baseline_digest, "inventory_sha256" => inventory_digest,
    "overrides_sha256" => overrides_digest
  )
  write_json_at(candidate_directory, "binding.json", binding, 0o400)
  refuse("adopted state changed before publication") unless
    inventory_roots_at(sandbox_directory, roots) == source_entries
  begin
    rebound_state = open_directory_at(candidate_directory, "state")
  rescue Errno::ELOOP, Errno::ENOENT, Errno::ENOTDIR
    refuse("candidate namespace changed")
  end
  refuse("candidate namespace changed") unless identity_signature(rebound_state.stat) == state_binding
  rebound_state.close
  candidate_directory.chmod(0o500)
  candidate_directory.fsync
  rename_at(snapshot_parent_directory, candidate_name, "pre-cutover")
  candidate_created = false
  published_by_call = true
  refuse("forced post-publication failure") if post_publish_self_test
  snapshot_parent_directory.fsync
  verify_snapshot(sandbox_directory, roots, overrides_digest, baseline_path, run_state_path)
  published_by_call = false
# Refusals use SystemExit after emitting their stable diagnostic. Catch all
# exceptions here so a post-rename refusal still rolls publication back.
rescue Exception # rubocop:disable Lint/RescueException
  if published_by_call
    remove_tree_at(snapshot_parent_directory, "pre-cutover")
    snapshot_parent_directory.fsync
  end
  raise
ensure
  state_directory&.close
  candidate_directory&.close
  remove_tree_at(snapshot_parent_directory, candidate_name) if candidate_created
  snapshot_parent_directory&.close
  sandbox_directory&.close
end
RUBY
then
  exit 1
fi
