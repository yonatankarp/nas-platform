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
  publish|verify|marker|marker-post-cutover|begin-cutover|attestations|live-namespace|baseline-binding|rollback-binding|restore) ;;
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
].map { |entry| entry.split("|", 3) }
READ_ONLY_BINDINGS = %w[
  audiobookshelf|legacy/audiobookshelf/media
  beszel|legacy/beszel/volume1
  beszel|legacy/beszel/volume2
  jellyfin|legacy/jellyfin/media
  komga|legacy/komga/library
  paperless-ngx|legacy/paperless-ngx/tessdata/heb.traineddata
].freeze
EXPECTED_BINDINGS.each do |binding|
  binding << (READ_ONLY_BINDINGS.include?(binding.first(2).join("|")) ? "ro" : "rw")
end
EXPECTED_BINDINGS.freeze
BINDING_FIELDS = %w[
  schema lane sandbox_id project_name legacy_commit git_revision vault_checksum parity_vault_checksum
  baseline_sha256 inventory_sha256 overrides_sha256
  attestations_sha256
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
  extern "int fcopyfile(int, int, void *, unsigned int)" if RUBY_PLATFORM.include?("darwin")
  if RUBY_PLATFORM.include?("darwin")
    extern "long flistxattr(int, void *, unsigned long, int)"
    extern "long fgetxattr(int, const char *, void *, unsigned long, unsigned int, int)"
    extern "void * acl_get_fd_np(int, int)"
    extern "int acl_free(void *)"
    extern "int fstat(int, void *)"
  end
end

COPYFILE_METADATA = 0x7
COPYFILE_ALL = 0xf
COPYFILE_DATA_SPARSE = 1 << 27

module SnapshotDurability
  module_function

  def sync(descriptor, _label)
    descriptor.fsync
  end
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

def mkdir_synced_at(parent, name, permissions, label)
  mkdir_at(parent, name, permissions)
  directory = open_directory_at(parent, name)
  SnapshotDurability.sync(directory, label)
  SnapshotDurability.sync(parent, "#{label}-parent")
ensure
  directory&.close
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

def xattr_digest(file)
  return nil unless RUBY_PLATFORM.include?("darwin")

  size = SnapshotFileSystem.flistxattr(file.fileno, nil, 0, 0)
  raise SystemCallError.new("flistxattr", Fiddle.last_error) if size.negative?
  names = if size.zero?
            []
          else
            buffer = Fiddle::Pointer.malloc(size)
            result = SnapshotFileSystem.flistxattr(file.fileno, buffer, size, 0)
            raise SystemCallError.new("flistxattr", Fiddle.last_error) if result.negative?
            buffer[0, result].split("\0").reject(&:empty?).sort
          end
  digest = Digest::SHA256.new
  names.each do |name|
    value_size = SnapshotFileSystem.fgetxattr(file.fileno, name, nil, 0, 0, 0)
    raise SystemCallError.new("fgetxattr", Fiddle.last_error) if value_size.negative?
    value = value_size.zero? ? "" : Fiddle::Pointer.malloc(value_size).tap do |value_buffer|
      SnapshotFileSystem.fgetxattr(file.fileno, name, value_buffer, value_size, 0, 0)
    end[0, value_size]
    digest.update(name).update("\0").update(value).update("\0")
  end
  digest.hexdigest
end

def metadata_entry(stat, relative, descriptor, digest = nil)
  entry = {
    "path" => relative, "type" => stat.directory? ? "directory" : "file",
    "mode" => mode(stat), "uid" => stat.uid, "gid" => stat.gid,
    "size" => stat.size, "mtime_ns" => (stat.mtime.to_r * 1_000_000_000).to_i,
    "xattrs_sha256" => xattr_digest(descriptor)
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

def sparse_file?(stat)
  stat.size.positive? && stat.blocks * 512 < stat.size
end

def refuse_unverifiable_archive_metadata(file)
  return unless RUBY_PLATFORM.include?("darwin")

  xattr_size = SnapshotFileSystem.flistxattr(file.fileno, nil, 0, 0)
  raise SystemCallError.new("flistxattr", Fiddle.last_error) if xattr_size.negative?
  acl = SnapshotFileSystem.acl_get_fd_np(file.fileno, 0x100)
  unless acl.to_i.zero?
    SnapshotFileSystem.acl_free(acl)
    refuse("access control lists are outside the accepted archive class")
  end

  stat_buffer = Fiddle::Pointer.malloc(144)
  result = SnapshotFileSystem.fstat(file.fileno, stat_buffer)
  raise SystemCallError.new("fstat", Fiddle.last_error) if result.negative?
  flags = stat_buffer[116, 4].unpack1("L")
  refuse("file flags are outside the accepted archive class") unless flags.zero?
end

def copy_file_archive(source, destination, stat)
  unless RUBY_PLATFORM.include?("darwin")
    refuse("special state metadata requires macOS archive support") if sparse_file?(stat)
    until source.eof?
      destination.write(source.read(64 * 1024))
    end
    return
  end

  flags = sparse_file?(stat) ? COPYFILE_METADATA | COPYFILE_DATA_SPARSE : COPYFILE_ALL
  result = SnapshotFileSystem.fcopyfile(source.fileno, destination.fileno, nil, flags)
  refuse("state archive metadata could not be preserved") if result.negative?
end

def copy_directory_metadata(source, destination)
  return unless RUBY_PLATFORM.include?("darwin")

  result = SnapshotFileSystem.fcopyfile(
    source.fileno, destination.fileno, nil, COPYFILE_METADATA
  )
  refuse("state archive metadata could not be preserved") if result.negative?
end

def inventory_entry_at(parent, name, relative, entries)
  source = open_at(parent, name, File::RDONLY | File::NOFOLLOW)
  before = source.stat
  refuse("state source is unsafe") unless before.directory? || before.file?
  refuse("hardlinked state is outside the accepted archive class") if before.file? && before.nlink > 1
  refuse_unverifiable_archive_metadata(source)
  digest = before.file? ? digest_descriptor(source) : nil
  entries << metadata_entry(before, relative, source, digest)
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
    mkdir_synced_at(parent, name, 0o700, "snapshot-nested-directory-entry")
    directory = open_directory_at(parent, name)
  end
  refuse("snapshot destination is unsafe") unless directory.stat.uid == Process.uid
  directory
end

def copy_entry_at(source_parent, source_name, destination_parent, destination_name, relative, entries)
  source = open_at(source_parent, source_name, File::RDONLY | File::NOFOLLOW)
  before = source.stat
  refuse_unverifiable_archive_metadata(source)
  if before.directory?
    entries << metadata_entry(before, relative, source)
    mkdir_synced_at(
      destination_parent, destination_name, 0o700, "snapshot-nested-directory-entry"
    )
    destination = open_directory_at(destination_parent, destination_name)
    descriptor_children(source).each do |child|
      copy_entry_at(source, child, destination, child, File.join(relative, child), entries)
    end
    copy_directory_metadata(source, destination)
    begin
      destination.chown(before.uid, before.gid)
    rescue SystemCallError
      refuse("snapshot cannot preserve state ownership")
    end
    destination.chmod(mode(before))
    set_descriptor_times(destination, before)
    destination.fsync
  elsif before.file?
    refuse("hardlinked state is outside the accepted archive class") if before.nlink > 1
    flags = File::RDWR | File::CREAT | File::EXCL | File::NOFOLLOW
    destination = open_at(destination_parent, destination_name, flags, mode(before))
    source_digest = digest_descriptor(source)
    copy_file_archive(source, destination, before)
    destination.flush
    begin
      destination.chown(before.uid, before.gid)
    rescue SystemCallError
      refuse("snapshot cannot preserve state ownership")
    end
    destination.chmod(mode(before))
    set_descriptor_times(destination, before)
    destination.fsync
    refuse("state source changed during copy") unless digest_descriptor(source) == source_digest
    refuse("snapshot archive content differs") unless digest_descriptor(destination) == source_digest
    if sparse_file?(before)
      refuse("snapshot archive expanded sparse state") unless destination.stat.blocks <= before.blocks
    end
    entries << metadata_entry(before, relative, source, source_digest)
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
    manifest_service = service_name || name.delete_suffix(".yml")
    bytes = read_file_at(directory, name, label)
    digest.update(label).update("\0").update(manifest_service).update("\0")
      .update(name).update("\0").update(bytes).update("\0")
    compose_service = nil
    in_services = false
    in_volumes = false
    bytes.lines(chomp: true).filter_map do |line|
      if line.match?(/^services:\s*$/)
        in_services = true
        compose_service = nil
        in_volumes = false
        next
      elsif line.match?(/^[^\s#]/)
        in_services = false
        compose_service = nil
        in_volumes = false
      elsif in_services && (service_match = line.match(/^  ([a-z0-9][a-z0-9-]*):\s*$/))
        compose_service = service_match[1]
        in_volumes = false
        next
      elsif in_services && compose_service && line.match?(/^    volumes:\s*!override\s*$/)
        in_volumes = true
        next
      elsif in_services && compose_service && line.match?(/^    [^\s#]/)
        in_volumes = false
      end
      match = in_volumes && line.match(
        %r{^\s*-\s+\$\{#{Regexp.escape(variable)}:\?\}/(legacy/[^:]+):(/[^:]+?)(?::(ro|rw))?\s*$}
      )
      if line.include?("${#{variable}") && !match
        refuse("#{label} bind mapping is unsafe")
      end
      next unless match

      relative, target, access = match.captures
      components = relative.split("/")
      refuse("#{label} bind mapping is unsafe") unless components.first == "legacy" &&
        components.all? { |part| part.match?(/\A[-.A-Za-z0-9]+\z/) && ![".", ".."].include?(part) }
      refuse("#{label} service association is unavailable") unless compose_service
      [manifest_service, compose_service, relative, target, access || "rw"]
    end
  end
end

def expected_compose_service(manifest_service, source, target: false)
  service = case manifest_service
            when "beszel" then source == "legacy/beszel/hub" ? "hub" : "agent"
            when "immich"
              return "immich-machine-learning" if source.end_with?("model-cache")
              return "database" if source.end_with?("postgres")
              "immich-server"
            when "paperless-ngx"
              return "broker" if source.end_with?("redis")
              return "db" if source.end_with?("postgres")
              "webserver"
            else manifest_service
            end
  target && manifest_service == "beszel" && service == "agent" ? "agent-portable" : service
end

def expected_policy_bindings(target: false)
  EXPECTED_BINDINGS.map do |manifest_service, source, destination, access|
    [manifest_service, expected_compose_service(manifest_service, source, target: target),
     source, destination, access]
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
    legacy_bindings.sort == expected_policy_bindings.sort

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
    target_bindings.sort == expected_policy_bindings(target: true).sort
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

def relative_parent_at(root, relative)
  components = relative.split("/")
  parent = root.dup
  components[0...-1].each do |component|
    child = open_directory_at(parent, component)
    parent.close
    parent = child
  end
  [parent, components.last]
end

def install_mount_attestations(sandbox, bindings, run_identity, baseline_digest)
  created = []
  records = bindings.map do |service, source, target, access|
    parent, name = relative_parent_at(sandbox, source)
    entry = open_at(parent, name, File::RDONLY | File::NOFOLLOW)
    tuple = [run_identity, baseline_digest, service, source, target, access]
    expected = "#{Digest::SHA256.hexdigest(JSON.generate(tuple))}\n"
    if entry.stat.directory?
      sentinel_name = ".nas-platform-adoption-root-sentinel"
      begin
        existing = read_file_at(entry, sentinel_name, "adoption mount sentinel", 0o444)
        refuse("adoption mount sentinel differs") unless existing == expected
      rescue Errno::ENOENT
        write_bytes_at(entry, sentinel_name, expected, 0o444)
        SnapshotDurability.sync(entry, "adoption-sentinel-directory-entry")
        created << {
          "source" => source, "directory_signature" => identity_signature(entry.stat),
          "bytes" => expected
        }
      end
      kind = "sentinel"
      container_path = File.join(target, sentinel_name)
      expected_sha256 = Digest::SHA256.hexdigest(expected)
      expected_size = expected.bytesize
    elsif entry.stat.file?
      kind = "file"
      container_path = target
      expected_sha256 = digest_descriptor(entry)
      expected_size = entry.stat.size
      refuse("file mount attestation exceeds the accepted size") if expected_size > 64 * 1024 * 1024
    else
      refuse("adoption attestation source is unsafe")
    end
    if kind == "sentinel"
      sentinel = open_at(entry, ".nas-platform-adoption-root-sentinel", File::RDONLY | File::NOFOLLOW)
      refuse("hardlinked adoption sentinel is unsafe") unless sentinel.stat.nlink == 1
    else
      refuse("hardlinked adoption source is unsafe") unless entry.stat.nlink == 1
    end
    {
      "service" => service,
      "legacy_compose_service" => expected_compose_service(service, source),
      "target_compose_service" => expected_compose_service(service, source, target: true),
      "project_suffix" => (service == "paperless-ngx" ? "paperless" : service),
      "source" => source, "target" => target, "access" => access,
      "kind" => kind, "container_path" => container_path,
      "size" => expected_size, "sha256" => expected_sha256,
      "live_dev" => entry.stat.dev, "live_ino" => entry.stat.ino
    }
  ensure
    sentinel&.close
    entry&.close
    parent&.close
  end
  [records, created]
rescue Errno::ELOOP, Errno::ENOTDIR
  remove_mount_sentinels(sandbox, created)
  refuse("state source is unsafe")
rescue Errno::ENOENT
  remove_mount_sentinels(sandbox, created)
  refuse("state source is unavailable")
rescue Exception # rubocop:disable Lint/RescueException
  remove_mount_sentinels(sandbox, created)
  raise
end

def remove_mount_sentinels(sandbox, records)
  records.each do |record|
    parent, name = relative_parent_at(sandbox, record.fetch("source"))
    directory = open_directory_at(parent, name)
    unless identity_signature(directory.stat) == record.fetch("directory_signature") &&
        read_file_at(directory, ".nas-platform-adoption-root-sentinel", "adoption mount sentinel", 0o444) ==
          record.fetch("bytes")
      warn "adoption-snapshot-error: created sentinel changed; retaining it"
      next
    end
    unlink_at(directory, ".nas-platform-adoption-root-sentinel")
    SnapshotDurability.sync(directory, "adoption-sentinel-rollback")
  ensure
    directory&.close
    parent&.close
  end
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
  attestations_bytes = read_file_at(
    snapshot_directory, "attestations.json", "snapshot attestations", 0o400
  )
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
  refuse("snapshot attestations changed") unless
    binding["attestations_sha256"] == Digest::SHA256.hexdigest(attestations_bytes)
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

if %w[verify marker marker-post-cutover begin-cutover attestations live-namespace baseline-binding rollback-binding restore].include?(action)
  transition_mode = case action
                    when "marker-post-cutover", "attestations", "live-namespace", "baseline-binding", "rollback-binding", "restore" then :required
                    when "begin-cutover" then :begin
                    else :none
                    end
  marker = verify_snapshot(
    sandbox_directory, roots, overrides_digest, baseline_path, run_state_path,
    compare_source: !%w[marker-post-cutover attestations live-namespace baseline-binding rollback-binding restore].include?(action),
    transition_mode: transition_mode
  )
  puts marker if action.start_with?("marker") || action == "begin-cutover"
  if action == "attestations"
    parent = open_directory_at(sandbox_directory, "snapshot")
    publication = open_directory_at(parent, "pre-cutover")
    parent_signature = identity_signature(parent.stat)
    publication_signature = identity_signature(publication.stat)
    bytes = read_file_at(publication, "attestations.json", "snapshot attestations", 0o400)
    reopened_binding = read_file_at(publication, "binding.json", "snapshot binding", 0o400)
    refuse("snapshot binding changed before attestation emit") unless
      Digest::SHA256.hexdigest(reopened_binding) == marker
    binding = load_binding_bytes(reopened_binding)
    refuse("snapshot attestations changed") unless
      binding["attestations_sha256"] == Digest::SHA256.hexdigest(bytes)
    rebound_publication = open_directory_at(parent, "pre-cutover")
    rebound_parent = open_directory_at(sandbox_directory, "snapshot")
    refuse("snapshot namespace changed before attestation emit") unless
      identity_signature(rebound_publication.stat) == publication_signature &&
      identity_signature(rebound_parent.stat) == parent_signature
    print bytes
    rebound_publication.close
    rebound_parent.close
    publication.close
    parent.close
  elsif %w[baseline-binding rollback-binding].include?(action)
    parent = open_directory_at(sandbox_directory, "snapshot")
    publication = open_directory_at(parent, "pre-cutover")
    parent_signature = identity_signature(parent.stat)
    publication_signature = identity_signature(publication.stat)
    binding_bytes = read_file_at(publication, "binding.json", "snapshot binding", 0o400)
    baseline_bytes = read_file_at(publication, "baseline.json", "snapshot baseline", 0o400)
    binding = load_binding_bytes(binding_bytes)
    refuse("snapshot binding changed before baseline emit") unless
      Digest::SHA256.hexdigest(binding_bytes) == marker
    refuse("snapshot baseline changed before baseline emit") unless
      binding["baseline_sha256"] == Digest::SHA256.hexdigest(baseline_bytes)
    rebound_publication = open_directory_at(parent, "pre-cutover")
    rebound_parent = open_directory_at(sandbox_directory, "snapshot")
    refuse("snapshot namespace changed before baseline emit") unless
      identity_signature(rebound_publication.stat) == publication_signature &&
      identity_signature(rebound_parent.stat) == parent_signature
    output = {
      "binding_sha256" => marker, "baseline_sha256" => binding.fetch("baseline_sha256")
    }
    if action == "rollback-binding"
      output["legacy_commit"] = binding.fetch("legacy_commit")
      output["git_revision"] = binding.fetch("git_revision")
    end
    puts JSON.generate(output)
    rebound_publication.close
    rebound_parent.close
    publication.close
    parent.close
  elsif action == "restore"
    rollback_path = ENV.fetch("PLATFORM_ADOPTION_ROLLBACK_ROOT")
    rollback_project = ENV.fetch("PLATFORM_ADOPTION_ROLLBACK_PROJECT")
    rollback = File.realpath(rollback_path)
    refuse("rollback sandbox changed") unless rollback == rollback_path && rollback != sandbox &&
      File.dirname(rollback) == File.dirname(sandbox)
    rollback_directory = open_bound_directory(rollback, "owned rollback sandbox")
    refuse("rollback sandbox is unsafe") unless rollback_directory.stat.uid == Process.uid &&
      mode(rollback_directory.stat) == 0o700
    marker_bytes = read_file_at(
      rollback_directory, ".nas-platform-mac-owned", "rollback ownership marker", 0o600
    )
    rollback_suffix = File.basename(rollback).delete_prefix("nas-platform-mac.")
    refuse("rollback sandbox name differs") unless File.basename(rollback).match?(/\Anas-platform-mac\.[A-Za-z0-9]{6}\z/)
    expected_project = "nas-platform-mac-#{rollback_suffix.downcase}"
    expected_marker = [
      "schema=1", "project=#{expected_project}", "namespace=rollback",
      "source_project=#{ENV.fetch('PLATFORM_PROJECT_NAME')}", "snapshot_binding=#{marker}"
    ].join("\n") << "\n"
    refuse("rollback ownership marker differs") unless rollback_project == expected_project &&
      marker_bytes == expected_marker && descriptor_children(rollback_directory) == [".nas-platform-mac-owned"]
    snapshot_parent_directory = open_directory_at(sandbox_directory, "snapshot")
    snapshot_directory = open_directory_at(snapshot_parent_directory, "pre-cutover")
    state_directory = open_directory_at(snapshot_directory, "state")
    snapshot_parent_identity = identity_signature(snapshot_parent_directory.stat)
    snapshot_identity = identity_signature(snapshot_directory.stat)
    state_identity = identity_signature(state_directory.stat)
    binding_bytes = read_file_at(snapshot_directory, "binding.json", "snapshot binding", 0o400)
    refuse("snapshot binding changed before restore") unless Digest::SHA256.hexdigest(binding_bytes) == marker
    inventory_bytes = read_file_at(snapshot_directory, "inventory.json", "snapshot inventory", 0o400)
    inventory_document = JSON.parse(inventory_bytes, create_additions: false)
    refuse("snapshot inventory differs before restore") unless
      inventory_document.is_a?(Hash) && inventory_document.fetch("entries").is_a?(Array)
    restored_baseline = read_file_at(snapshot_directory, "baseline.json", "snapshot baseline", 0o400)
    binding_document = load_binding_bytes(binding_bytes)
    refuse("snapshot baseline differs") unless
      Digest::SHA256.hexdigest(restored_baseline) == binding_document.fetch("baseline_sha256")
    write_bytes_at(rollback_directory, "pre-cutover-baseline.json", restored_baseline, 0o400)
    restored_entries = []
    roots.each do |relative|
      copy_relative_root(state_directory, rollback_directory, relative, restored_entries)
    end
    rollback_directory.fsync
    snapshot_entries = inventory_roots_at(state_directory, roots)
    restored_inventory = inventory_roots_at(rollback_directory, roots)
    refuse("rollback restore differs from snapshot") unless
      inventories_match?(inventory_document.fetch("entries"), snapshot_entries) &&
      inventories_match?(snapshot_entries, restored_entries) &&
      inventories_match?(snapshot_entries, restored_inventory)
    rebound_snapshot_parent = open_directory_at(sandbox_directory, "snapshot")
    rebound_snapshot = open_directory_at(rebound_snapshot_parent, "pre-cutover")
    rebound_state = open_directory_at(rebound_snapshot, "state")
    refuse("snapshot namespace changed during restore") unless
      identity_signature(rebound_snapshot_parent.stat) == snapshot_parent_identity &&
      identity_signature(rebound_snapshot.stat) == snapshot_identity &&
      identity_signature(rebound_state.stat) == state_identity &&
      read_file_at(rebound_snapshot, "binding.json", "snapshot binding", 0o400) == binding_bytes &&
      read_file_at(rebound_snapshot, "inventory.json", "snapshot inventory", 0o400) == inventory_bytes
    rebound_rollback = open_bound_directory(rollback, "owned rollback sandbox")
    refuse("rollback sandbox changed during restore") unless
      identity_signature(rebound_rollback.stat) == identity_signature(rollback_directory.stat) &&
      read_file_at(rebound_rollback, ".nas-platform-mac-owned", "rollback ownership marker", 0o600) ==
        marker_bytes && descriptor_children(rebound_rollback) ==
          [".nas-platform-mac-owned", "legacy", "pre-cutover-baseline.json"]
    puts marker
    rebound_rollback.close
    rebound_state.close
    rebound_snapshot.close
    rebound_snapshot_parent.close
    state_directory.close
    snapshot_directory.close
    snapshot_parent_directory.close
    rollback_directory.close
  elsif action == "live-namespace"
    signatures = roots.to_h do |relative|
      parent, name = relative_parent_at(sandbox_directory, relative)
      entry = open_at(parent, name, File::RDONLY | File::NOFOLLOW)
      [relative, identity_signature(entry.stat).first(2)]
    ensure
      entry&.close
      parent&.close
    end
    puts JSON.generate(signatures)
  end
  exit 0
end

baseline_bytes = secure_file_bytes_path(baseline_path, "baseline", expected_mode: 0o600)
run_identity = load_run_state(run_state_path)
baseline_digest = Digest::SHA256.hexdigest(baseline_bytes)
attestations, created_sentinels = install_mount_attestations(
  sandbox_directory, EXPECTED_BINDINGS, run_identity, baseline_digest
)
sentinels_committed = false
sentinel_cleanup_directory = sandbox_directory.dup
at_exit do
  remove_mount_sentinels(sentinel_cleanup_directory, created_sentinels) unless sentinels_committed
  sentinel_cleanup_directory.close
end
begin
  snapshot_parent_directory = open_directory_at(sandbox_directory, "snapshot")
rescue Errno::ENOENT
  begin
    mkdir_synced_at(sandbox_directory, "snapshot", 0o700, "snapshot-parent-entry")
  rescue Exception # rubocop:disable Lint/RescueException
    begin
      remove_tree_at(sandbox_directory, "snapshot")
      SnapshotDurability.sync(sandbox_directory, "snapshot-parent-rollback")
    rescue Errno::ENOENT
      nil
    end
    raise
  end
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
  mkdir_synced_at(
    snapshot_parent_directory, candidate_name, 0o700, "snapshot-candidate-directory-entry"
  )
  candidate_created = true
  candidate_directory = open_directory_at(snapshot_parent_directory, candidate_name)
  state_copy = File.join(candidate_path, "state")
  mkdir_synced_at(candidate_directory, "state", 0o700, "snapshot-state-directory-entry")
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
  write_json_at(candidate_directory, "attestations.json", attestations, 0o400)
  inventory_digest = Digest::SHA256.hexdigest(
    read_file_at(candidate_directory, "inventory.json", "snapshot inventory", 0o400)
  )
  binding = { "schema" => 1 }.merge(run_identity).merge(
    "baseline_sha256" => baseline_digest, "inventory_sha256" => inventory_digest,
    "overrides_sha256" => overrides_digest,
    "attestations_sha256" => Digest::SHA256.hexdigest(
      read_file_at(candidate_directory, "attestations.json", "snapshot attestations", 0o400)
    )
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
  sentinels_committed = true
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
