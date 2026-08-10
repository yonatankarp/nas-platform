#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "digest"
require "fiddle/import"
require "fileutils"
require "net/http"
require "open3"
require "optparse"
require "psych"
require "securerandom"
require "tempfile"
require "timeout"
require "uri"
require "yaml"

SERVICES = %w[
  audiobookshelf beszel dozzle immich jellyfin komga ntfy paperless-ngx tinymediamanager
].freeze
FORBIDDEN_KEY = /(password|secret|token|authorization|private|hash)/i
MAX_CAPTURE = 1024 * 1024
NTFY_PERMISSION_LINES = [
  /\A- read-write access to all topics \(admin role\)\z/,
  /\A- (?:read-write|read-only|write-only|no) access to topic [-_*A-Za-z0-9]{1,64}(?: \(server config\))?\z/,
  /\A- no topic-specific permissions\z/,
  /\A- (?:read-write|read-only|write-only) access to all \(other\) topics \(server config\)\z/,
  /\A- no access to any \(other\) topics \(server config\)\z/
].freeze
NTFY_ACCESS_ALIASES = {
  "r" => "read-only", "ro" => "read-only", "read-only" => "read-only",
  "w" => "write-only", "wo" => "write-only", "write-only" => "write-only",
  "rw" => "read-write", "read-write" => "read-write",
  "deny" => "no", "none" => "no", "no" => "no"
}.freeze
IDENTITY_FIELDS = {
  "audiobookshelf" => %w[name role permissions enabled],
  "beszel" => %w[name role enabled],
  "dozzle" => %w[name role permissions enabled],
  "immich" => %w[name role enabled],
  "jellyfin" => %w[name role permissions enabled],
  "komga" => %w[name role permissions enabled],
  "ntfy" => %w[name role permissions enabled],
  "paperless-ngx" => %w[name role enabled],
  "tinymediamanager" => %w[name role enabled]
}.freeze
COUNT_FIELDS = {
  "audiobookshelf" => %w[items libraries users],
  "beszel" => %w[alerts systems users],
  "dozzle" => %w[dispatchers rules users],
  "immich" => %w[assets users],
  "jellyfin" => %w[items libraries users],
  "komga" => %w[books libraries series users],
  "ntfy" => %w[access_rules users],
  "paperless-ngx" => %w[documents mail_accounts users],
  "tinymediamanager" => %w[movies shows]
}.freeze
FIXTURE_FIELDS = {
  "audiobookshelf" => %w[audiobook], "beszel" => [], "dozzle" => [],
  "immich" => %w[photo video], "jellyfin" => %w[video], "komga" => %w[book],
  "ntfy" => [], "paperless-ngx" => %w[document],
  "tinymediamanager" => %w[episode movie]
}.freeze
SETTING_FIELDS = {
  "audiobookshelf" => %w[library_name media_type], "beszel" => %w[system_name],
  "dozzle" => %w[dispatcher_name],
  "immich" => %w[database_backup machine_learning new_version_check],
  "jellyfin" => %w[library_name], "komga" => %w[library_name], "ntfy" => %w[topic],
  "paperless-ngx" => %w[mail_account_name], "tinymediamanager" => %w[api_enabled]
}.freeze

class StrictObject < Hash
  def []=(key, value)
    raise JSON::ParserError, "duplicate object member" if key?(key)

    super
  end
end

def refuse(message)
  warn "adoption-baseline-error: #{message}"
  exit 1
end

def exact_keys!(object, expected, label)
  raise "#{label} fields differ" unless object.is_a?(Hash) && object.keys.sort == expected.sort
end

def safe_string!(value, label)
  raise "#{label} is invalid" unless value.is_a?(String) && value.bytesize.between?(1, 512) &&
                                          value.valid_encoding? && !value.match?(/[\x00-\x1f\x7f]/)
end

def canonical_identity_name(value)
  value.encode(Encoding::UTF_8).unicode_normalize(:nfkc).strip.downcase(:fold)
end

def reject_forbidden_keys!(value)
  case value
  when Hash
    value.each do |key, child|
      raise "forbidden evidence field" unless key.is_a?(String) && !key.match?(FORBIDDEN_KEY)

      reject_forbidden_keys!(child)
    end
  when Array
    value.each { |child| reject_forbidden_keys!(child) }
  end
end

def reject_canaries!(bytes, canaries)
  raise "protected value in capture" if canaries.any? { |canary| bytes.include?(canary) }
end

def parse_strict_json(bytes)
  reject_duplicate_json_keys!(Psych.parse(bytes))
  parsed = JSON.parse(bytes, object_class: StrictObject, array_class: Array,
                             create_additions: false, allow_nan: false, max_nesting: 32)
  plain_json_value(parsed)
end

def reject_duplicate_json_keys!(node)
  if node.is_a?(Psych::Nodes::Mapping)
    keys = node.children.each_slice(2).map do |key, _value|
      raise JSON::ParserError, "non-scalar object member" unless key.is_a?(Psych::Nodes::Scalar)

      key.value
    end
    raise JSON::ParserError, "duplicate object member" unless keys.uniq.length == keys.length
  elsif node.is_a?(Psych::Nodes::Alias)
    raise JSON::ParserError, "JSON alias is not allowed"
  end
  Array(node.children).each { |child| reject_duplicate_json_keys!(child) } if node.respond_to?(:children)
end

def plain_json_value(value)
  case value
  when Hash
    value.to_h { |key, child| [key, plain_json_value(child)] }
  when Array
    value.map { |child| plain_json_value(child) }
  else
    value
  end
end

def validate_evidence!(service, evidence)
  exact_keys!(evidence, %w[identities record_counts fixture_sha256 managed_settings], service)

  identities = evidence.fetch("identities")
  raise "#{service} identities are invalid" unless identities.is_a?(Array) && !identities.empty?
  identities.each do |identity|
    exact_keys!(identity, IDENTITY_FIELDS.fetch(service), "#{service} identity")
    safe_string!(identity.fetch("name"), "#{service} identity name")
    safe_string!(identity.fetch("role"), "#{service} identity role")
    raise "#{service} enabled state is invalid" unless [true, false].include?(identity.fetch("enabled"))
    next unless identity.key?("permissions")

    permissions = identity.fetch("permissions")
    raise "#{service} permissions are invalid" unless permissions.is_a?(Array) &&
                                                       permissions.uniq.length == permissions.length
    permissions.each { |permission| safe_string!(permission, "#{service} permission") }
    identity["permissions"] = permissions.sort
  end
  normalized_names = identities.map { |entry| canonical_identity_name(entry.fetch("name")) }
  raise "#{service} identity name is invalid" if normalized_names.any?(&:empty?)
  raise "#{service} identity names are duplicated" unless normalized_names.uniq.length == normalized_names.length
  evidence["identities"] = identities.sort_by { |entry| [entry.fetch("name"), entry.fetch("role")] }

  counts = evidence.fetch("record_counts")
  exact_keys!(counts, COUNT_FIELDS.fetch(service), "#{service} record counts")
  counts.each_value { |value| raise "#{service} record count is invalid" unless value.is_a?(Integer) && value >= 0 }
  if counts.key?("users")
    raise "#{service} user count differs from identities" unless counts.fetch("users") == identities.length
  end
  evidence["record_counts"] = COUNT_FIELDS.fetch(service).to_h { |field| [field, counts.fetch(field)] }

  fixtures = evidence.fetch("fixture_sha256")
  exact_keys!(fixtures, FIXTURE_FIELDS.fetch(service), "#{service} fixture checksums")
  fixtures.each_value do |value|
    raise "#{service} fixture checksum is invalid" unless value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)
  end
  evidence["fixture_sha256"] = FIXTURE_FIELDS.fetch(service).to_h { |field| [field, fixtures.fetch(field)] }

  settings = evidence.fetch("managed_settings")
  exact_keys!(settings, SETTING_FIELDS.fetch(service), "#{service} managed settings")
  settings.each do |field, value|
    unless value == true || value == false
      safe_string!(value, "#{service} managed setting #{field}")
    end
  end
  evidence["managed_settings"] = SETTING_FIELDS.fetch(service).to_h { |field| [field, settings.fetch(field)] }
  evidence
end

def capture(*command)
  stdout = +""
  stderr = +""
  status = nil
  Open3.popen3(*command, pgroup: true) do |stdin, output, error, wait_thread|
    stdin.close
    stdout_reader = Thread.new { output.read(MAX_CAPTURE + 1) }
    stderr_reader = Thread.new { error.read(MAX_CAPTURE + 1) }
    stdout_reader.report_on_exception = false
    stderr_reader.report_on_exception = false
    begin
      status = Timeout.timeout(30) { wait_thread.value }
    rescue Timeout::Error
      Process.kill("TERM", -wait_thread.pid)
      unless wait_thread.join(1)
        Process.kill("KILL", -wait_thread.pid)
        wait_thread.join
      end
      output.close unless output.closed?
      error.close unless error.closed?
      [stdout_reader, stderr_reader].each do |reader|
        reader.kill unless reader.join(1)
        reader.join
      end
      raise "command timed out"
    rescue Errno::ESRCH
      output.close unless output.closed?
      error.close unless error.closed?
      [stdout_reader, stderr_reader].each do |reader|
        reader.kill unless reader.join(1)
        reader.join
      end
      raise "command timed out"
    end
    stdout = stdout_reader.value || ""
    stderr = stderr_reader.value || ""
    output.close unless output.closed?
    error.close unless error.closed?
  end
  raise "command failed" unless status.success?
  raise "command output is too large" if stdout.bytesize > MAX_CAPTURE || stderr.bytesize > MAX_CAPTURE

  [stdout, stderr]
end

def collect_secret_values(value, secrets = [], protected = false)
  case value
  when Hash
    value.each do |key, child|
      collect_secret_values(child, secrets, protected || key.to_s.match?(FORBIDDEN_KEY))
    end
  when Array
    value.each { |child| collect_secret_values(child, secrets, protected) }
  when String
    secrets << value if protected && !value.empty?
  end
  secrets
end

def vault_canaries(vault_path = ENV["PLATFORM_MAC_VAULT_FILE"],
                   password_path = ENV["PLATFORM_MAC_VAULT_PASSWORD_FILE"])
  return [] unless vault_path && password_path

  bytes, diagnostics = with_private_input_snapshots([vault_path, password_path]) do |snapshots|
    capture(
      "ansible-vault", "view", "--vault-password-file", snapshots.fetch(1), snapshots.fetch(0)
    )
  end
  document = YAML.safe_load(bytes, aliases: false)
  collect_secret_values(document).uniq
ensure
  bytes.replace("\0" * bytes.bytesize) if bytes && !bytes.frozen?
  diagnostics.replace("\0" * diagnostics.bytesize) if diagnostics && !diagnostics.frozen?
end

def fixture_digest(path)
  Digest::SHA256.hexdigest(secure_file_bytes(path, max_bytes: 1024 * 1024 * 1024))
end

def file_signature(path)
  secure_file_handle(path, trusted_root: File.dirname(File.expand_path(path))) do |_file, bindings|
    bindings.map { |binding| binding.fetch(2) }
  end
end

module AdoptionFileSystem
  extend Fiddle::Importer
  dlload Fiddle.dlopen(nil)
  extern "int openat(int, const char *, int, int)"
end

def open_component(parent, name)
  unsafe = name.empty? || %w[. ..].include?(name) || name.include?(File::SEPARATOR) || name.include?("\0")
  raise "capture input is unsafe" if unsafe
  flags = File::RDONLY | File::NOFOLLOW
  descriptor = AdoptionFileSystem.openat(parent.fileno, name, flags, 0)
  raise SystemCallError.new("openat", Fiddle.last_error) if descriptor.negative?

  IO.for_fd(descriptor, autoclose: true)
end

def component_binding(stat, exact:)
  return file_signature_from_stat(stat) if exact

  [stat.dev, stat.ino, stat.mode, stat.uid]
end

def safe_capture_directory?(stat, trusted:)
  return false unless stat.directory?
  return stat.uid == Process.uid && (stat.mode & 0o022).zero? if trusted

  non_writable = [0, Process.uid].include?(stat.uid) && (stat.mode & 0o022).zero?
  root_sticky_tmp = stat.uid.zero? && (stat.mode & 0o7777) == 0o1777
  non_writable || root_sticky_tmp
end

def secure_file_handle(path, trusted_root:)
  absolute = File.expand_path(path)
  root = File.expand_path(trusted_root)
  raise "capture input is unsafe" unless absolute.start_with?("#{root}/")

  components = absolute.split(File::SEPARATOR).reject(&:empty?)
  root_components = root.split(File::SEPARATOR).reject(&:empty?)
  current = File.open(File::SEPARATOR, File::RDONLY | File::NOFOLLOW)
  opened = [current]
  bindings = []
  components[0...-1].each_with_index do |component, index|
    child = open_component(current, component)
    stat = child.stat
    exact = index + 1 >= root_components.length
    raise "capture input parent is unsafe" unless safe_capture_directory?(stat, trusted: exact)
    bindings << [current, component, component_binding(stat, exact: exact), exact]
    opened << child
    current = child
  end
  leaf = components.fetch(-1)
  file = open_component(current, leaf)
  bindings << [current, leaf, component_binding(file.stat, exact: true), true]
  opened << file
  yield file, bindings.drop(root_components.length - 1)
ensure
  if bindings
    bindings.each do |parent, component, signature, exact|
      reopened = open_component(parent, component)
      raise "capture input changed" unless component_binding(reopened.stat, exact: exact) == signature
    ensure
      reopened&.close
    end
  end
  opened&.reverse_each { |entry| entry.close unless entry.closed? }
end

def secure_file_bytes(path, max_bytes:, executable: false, private: false)
  trusted_root = File.dirname(File.expand_path(path))
  secure_file_handle(path, trusted_root: trusted_root) do |file|
    opened = file.stat
    raise "capture input is unsafe" unless opened.file? && opened.uid == Process.uid &&
                                           (opened.mode & 0o022).zero? &&
                                           (!executable || (opened.mode & 0o100).positive?) &&
                                           (!private || (opened.mode & 0o077).zero?)
    raise "capture input is too large" if opened.size > max_bytes
    value = file.read(max_bytes + 1)
    raise "capture input is too large" if value.bytesize > max_bytes
    after = file.stat
    raise "capture input changed" unless file_signature_from_stat(after) == file_signature_from_stat(opened)
    value
  end
end

def file_signature_from_stat(stat)
  [stat.dev, stat.ino, stat.size, stat.mode, stat.uid, stat.mtime.to_r, stat.ctime.to_r]
end

def snapshot_input(source, directory, name, executable: false, private: false)
  bytes = secure_file_bytes(
    source, max_bytes: 16 * 1024 * 1024, executable: executable, private: private
  )
  temporary = File.join(directory, ".#{name}.tmp")
  destination = File.join(directory, name)
  mode = executable ? 0o700 : 0o600
  File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, mode) do |file|
    file.write(bytes)
    file.flush
    file.fsync
  end
  File.rename(temporary, destination)
  File.open(directory, File::RDONLY) { |dir| dir.fsync }
  [destination, Digest::SHA256.hexdigest(bytes)]
end

def snapshot_unchanged?(path, signature, digest)
  file_signature(path) == signature &&
    Digest::SHA256.hexdigest(secure_file_bytes(path, max_bytes: 16 * 1024 * 1024)) == digest
end

def snapshots_unchanged?(states)
  states.all? do |path, (signature, digest)|
    snapshot_unchanged?(path, signature, digest)
  end
end

def with_private_input_snapshots(paths)
  Dir.mktmpdir("adoption-private-") do |directory|
    directory = File.realpath(directory)
    File.chmod(0o700, directory)
    snapshots = paths.each_with_index.map do |path, index|
      snapshot_input(path, directory, "input-#{index}", private: true).first
    end
    yield snapshots
  ensure
    snapshots&.each do |path|
      next unless File.file?(path) && !File.symlink?(path)
      File.open(path, File::WRONLY) do |file|
        file.write("\0" * file.stat.size)
        file.flush
        file.fsync
      end
    rescue SystemCallError
      nil
    end
  end
end

def destroy_private_directory(directory)
  return unless directory
  stat = File.lstat(directory)
  raise "private capture directory is unsafe" unless stat.directory? && !stat.symlink? &&
                                                       stat.uid == Process.uid
  Dir.children(directory).each do |name|
    path = File.join(directory, name)
    next unless File.file?(path) && !File.symlink?(path)
    File.open(path, File::WRONLY) do |file|
      file.write("\0" * file.stat.size)
      file.flush
      file.fsync
    end
  end
  FileUtils.remove_entry_secure(directory)
rescue Errno::ENOENT
  nil
end

def pinned_images(bytes, canaries)
  reject_canaries!(bytes, canaries)
  images = bytes.lines(chomp: true)
  raise "legacy images are invalid" if images.empty? || images.any?(&:empty?)
  images.each do |image|
    safe_string!(image, "legacy image")
    raise "legacy image is not digest pinned" unless image.match?(/\A\S+@sha256:[0-9a-f]{64}\z/)
  end
  images.sort
end

def publication_file_state(path, expected_mode:)
  path_stat = File.lstat(path)
  flags = File::RDONLY
  flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
  File.open(path, flags) do |file|
    stat = file.stat
    raise "publication path is unsafe" unless stat.file? && !path_stat.symlink? &&
                                                  stat.uid == Process.uid &&
                                                  (stat.mode & 0o777) == expected_mode &&
                                                  [stat.dev, stat.ino] == [path_stat.dev, path_stat.ino]
    digest = Digest::SHA256.new
    digest << file.read(64 * 1024) until file.eof?
    after = file.stat
    final = File.lstat(path)
    raise "publication path changed" unless file_signature_from_stat(after) == file_signature_from_stat(stat) &&
                                            file_signature_from_stat(final) == file_signature_from_stat(stat)
    [file_signature_from_stat(stat), digest.hexdigest]
  end
end

def sync_publication_directory(parent)
  before = File.lstat(parent)
  flags = File::RDONLY | File::NOFOLLOW
  File.open(parent, flags) do |directory|
    opened = directory.stat
    raise "publication directory is unsafe" unless opened.directory? && opened.uid == Process.uid &&
                                                   (opened.mode & 0o777) == 0o700 &&
                                                   file_signature_from_stat(opened) == file_signature_from_stat(before)
    directory.fsync
    after = directory.stat
    final = File.lstat(parent)
    raise "publication directory changed" unless file_signature_from_stat(after) == file_signature_from_stat(opened) &&
                                                 file_signature_from_stat(final) == file_signature_from_stat(opened)
  end
end

def recovery_copy(backup, output, parent)
  recovery = File.join(parent, ".adoption-recovery-#{SecureRandom.hex(16)}")
  recovery_complete = false
  File.open(recovery, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
    backup.rewind
    IO.copy_stream(backup, file)
    file.flush
    file.fsync
    file.chmod(0o600)
  end
  recovery_complete = true
  File.rename(recovery, output)
  sync_publication_directory(parent)
ensure
  if recovery && !recovery_complete && File.exist?(recovery) && !File.symlink?(recovery)
    File.unlink(recovery)
  end
end

def rollback_publication(output, parent, initial, backup_path, backup_file)
  if initial
    if backup_path && File.exist?(backup_path) && !File.symlink?(backup_path)
      File.rename(backup_path, output)
      sync_publication_directory(parent)
    elsif backup_file
      recovery_copy(backup_file, output, parent)
    else
      raise "publication rollback is unavailable"
    end
  else
    File.unlink(output) if File.exist?(output) && !File.symlink?(output)
    sync_publication_directory(parent)
  end
end

def publish_baseline(staging_path, output, parent, initial)
  backup_path = nil
  backup_file = nil
  backup_owned = false
  backup_valid = false
  backup_cleanup_safe = false
  begin
    if initial
      backup_path = File.join(parent, ".adoption-backup-#{SecureRandom.hex(16)}")
      File.link(output, backup_path)
      backup_owned = true
      backup_state = publication_file_state(backup_path, expected_mode: 0o600)
      output_state = publication_file_state(output, expected_mode: 0o600)
      raise "baseline backup changed" unless backup_state == output_state && backup_state.last == initial.last
      backup_valid = true
      backup_file = File.open(backup_path, File::RDONLY | File::NOFOLLOW)
      sync_publication_directory(parent)
    end
    File.rename(staging_path, output)
    sync_publication_directory(parent)
    if backup_path
      File.unlink(backup_path)
      sync_publication_directory(parent)
    end
    backup_cleanup_safe = true
  rescue StandardError => publication_error
    begin
      rollback_publication(output, parent, initial, backup_valid ? backup_path : nil, backup_file)
      backup_cleanup_safe = true
    rescue StandardError
      # Rollback restores the namespace before syncing it. If that second sync fails,
      # the old bytes are visible but crash durability is unknowable. An earlier
      # rollback failure retains any complete recovery entry instead of deleting it.
    end
    raise publication_error
  ensure
    backup_file&.close
    safe_to_remove = backup_owned && (backup_cleanup_safe || !backup_valid)
    if safe_to_remove && File.exist?(backup_path) && !File.symlink?(backup_path)
      File.unlink(backup_path)
    end
  end
end

def checkout_snapshot(legacy_root, repository, commit, service_entries, canaries)
  origin, origin_diagnostic = capture("git", "-C", legacy_root, "remote", "get-url", "origin")
  reject_canaries!(origin_diagnostic, canaries)
  allowed_origins = [
    "https://github.com/#{repository}", "https://github.com/#{repository}.git",
    "git@github.com:#{repository}", "git@github.com:#{repository}.git",
    "ssh://git@github.com/#{repository}", "ssh://git@github.com/#{repository}.git"
  ]
  raise "legacy checkout origin differs" unless allowed_origins.include?(origin.strip)

  root_output, root_diagnostic = capture("git", "-C", legacy_root, "rev-parse", "--show-toplevel")
  reject_canaries!(root_diagnostic, canaries)
  raise "legacy checkout root differs" unless root_output.strip == legacy_root

  head_output, head_diagnostic = capture("git", "-C", legacy_root, "rev-parse", "HEAD")
  reject_canaries!(head_diagnostic, canaries)
  raise "legacy checkout commit differs" unless head_output.strip == commit

  status_output, status_diagnostic = capture(
    "git", "-C", legacy_root, "status", "--porcelain=v1", "--untracked-files=all"
  )
  reject_canaries!(status_diagnostic, canaries)
  raise "legacy checkout is dirty" unless status_output.empty?

  sources = service_entries.sort.to_h do |service, relative|
    source = File.join(legacy_root, relative)
    blob, blob_diagnostic = capture("git", "-C", legacy_root, "cat-file", "blob", "#{commit}:#{relative}")
    reject_canaries!(blob_diagnostic, canaries)
    source_bytes = secure_file_bytes(source, max_bytes: 16 * 1024 * 1024)
    raise "legacy compose file differs from pinned commit" unless source_bytes == blob
    [service, {
      "path" => relative, "signature" => file_signature(source),
      "blob_sha256" => Digest::SHA256.hexdigest(blob),
      "source_sha256" => Digest::SHA256.hexdigest(source_bytes)
    }]
  end
  {
    "origin" => origin.strip, "root" => root_output.strip, "head" => head_output.strip,
    "status" => status_output, "sources" => sources
  }
end

def first_fixture(root, pattern)
  matches = Dir.glob(File.join(root, "**", pattern)).sort.select { |path| File.file?(path) && !File.symlink?(path) }
  raise "fixture is unavailable" unless matches.length == 1

  matches.first
end

def probe_identity(name, role, enabled = true, permissions = nil)
  identity = { "name" => name, "role" => role }
  identity["permissions"] = Array(permissions).map(&:to_s).sort if permissions
  identity["enabled"] = enabled
  identity
end

def bounded_http_request(uri, request, max_bytes: MAX_CAPTURE)
  response = nil
  bytes = +""
  Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 30) do |http|
    http.request(request) do |received|
      response = received
      received.read_body do |chunk|
        bytes << chunk
        raise "probe response is too large" if bytes.bytesize > max_bytes
      end
    end
  end
  response.instance_variable_set(:@body, bytes)
  response.instance_variable_set(:@read, true)
  response
end

def http_json(method, url, bearer: nil, basic: nil, cookie: nil, body: nil, form: nil,
              authorization: nil, headers: {}, expected: [200])
  uri = URI(url)
  request = Net::HTTP.const_get(method.capitalize).new(uri)
  request["Authorization"] = "Bearer #{bearer}" if bearer
  request["Authorization"] = authorization if authorization
  request["Cookie"] = cookie if cookie
  headers.each { |name, value| request[name] = value }
  request.basic_auth(*basic) if basic
  if body
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body)
  elsif form
    request.set_form_data(form)
  end
  response = bounded_http_request(uri, request)
  raise "probe request failed" unless expected.include?(response.code.to_i)
  json_response = response["Content-Type"].to_s.downcase.include?("json")
  payload = response.body.to_s.empty? || !json_response ? nil : parse_strict_json(response.body)
  [response, payload]
end

def response_records(payload)
  payload.is_a?(Array) ? payload : payload.fetch("results")
end

def read_private_yaml(path)
  YAML.safe_load(secure_file_bytes(path, max_bytes: 16 * 1024 * 1024, private: true), aliases: false)
end

def read_private_env(path)
  values = {}
  secure_file_bytes(path, max_bytes: 1024 * 1024, private: true).each_line(chomp: true) do |line|
    next if line.empty? || line.start_with?("#")
    key, value = line.split("=", 2)
    raise "probe environment is malformed" unless key&.match?(/\A[A-Z][A-Z0-9_]*\z/) && value && !values.key?(key)
    values[key] = value
  end
  values
end

def ntfy_live_users(bytes)
  records = []
  current = nil
  bytes.each_line(chomp: true) do |line|
    if line.start_with?("user ")
      match = line.match(/\Auser (?<name>\*|[-_.+@A-Za-z0-9]+) \(role: (?<role>anonymous|user|admin), tier: .+\)\z/)
      raise "ntfy user listing is malformed" unless match
      if current
        raise "ntfy user listing is malformed" if current.fetch("permissions").empty?
        records << current
      end
      current = { "name" => match[:name], "role" => match[:role], "permissions" => [] }
    elsif line.start_with?("- ")
      supported = NTFY_PERMISSION_LINES.any? { |pattern| pattern.match?(line) }
      raise "ntfy user listing is malformed" unless current && supported
      current.fetch("permissions") << line.delete_prefix("- ")
    else
      raise "ntfy user listing is malformed"
    end
  end
  raise "ntfy user listing is incomplete" unless current
  raise "ntfy user listing is malformed" if current.fetch("permissions").empty?
  records << current
  raise "ntfy user listing is incomplete" if records.none? { |entry| entry["name"] == "*" }
  normalized = records.map { |entry| canonical_identity_name(entry.fetch("name")) }
  raise "ntfy user listing contains duplicate identities" unless normalized.uniq.length == normalized.length
  records.reject { |entry| entry["name"] == "*" }
end

def ntfy_declared_access(value)
  entries = value.split(",").reject(&:empty?).map do |record|
    name, topic, permission, extra = record.split(":", 4)
    normalized_name = canonical_identity_name(name.to_s)
    normalized_permission = NTFY_ACCESS_ALIASES[permission]
    raise "ntfy access entry is malformed" unless extra.nil? && !normalized_name.empty? &&
                                                  topic&.match?(/\A[-_*A-Za-z0-9]{1,64}\z/) &&
                                                  normalized_permission
    [normalized_name, topic, normalized_permission]
  end
  raise "ntfy access entries are duplicated" unless entries.uniq.length == entries.length
  entries.sort
end

def ntfy_live_access(users)
  users.flat_map do |user|
    name = canonical_identity_name(user.fetch("name"))
    user.fetch("permissions").filter_map do |permission|
      match = permission.match(/\A(read-write|read-only|write-only|no) access to topic ([-_*A-Za-z0-9]{1,64})(?: \(server config\))?\z/)
      [name, match[2], match[1]] if match
    end
  end.sort
end

def tmm_indexed_count(base, password, module_name, data_root, template_source)
  data_stat = File.lstat(data_root)
  raise "tinyMediaManager data root is unsafe" unless data_stat.directory? && !data_stat.symlink? &&
                                                    data_stat.uid == Process.uid &&
                                                    (data_stat.mode & 0o022).zero?
  templates_root = File.join(data_root, "templates")
  templates_stat = File.lstat(templates_root)
  raise "tinyMediaManager templates root is unsafe" unless templates_stat.directory? &&
                                                         !templates_stat.symlink? &&
                                                         templates_stat.uid == Process.uid &&
                                                         (templates_stat.mode & 0o022).zero?
  template_dir = Dir.mktmpdir("nas-adoption-#{module_name}-", templates_root)
  output_dir = Dir.mktmpdir(".nas-adoption-#{module_name}-", data_root)
  File.chmod(0o700, template_dir)
  File.chmod(0o700, output_dir)
  %w[template.conf list.jmte].each do |name|
    bytes = secure_file_bytes(File.join(template_source, name), max_bytes: 64 * 1024)
    File.open(File.join(template_dir, name), File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(bytes)
      file.flush
      file.fsync
    end
  end
  File.open(template_dir, File::RDONLY) { |directory| directory.fsync }
  command = {
    "action" => "export", "scope" => { "name" => "all" },
    "args" => {
      "template" => File.basename(template_dir),
      "exportPath" => "/data/#{File.basename(output_dir)}"
    }
  }
  http_json(
    "post", "#{base}/api/#{module_name}", headers: { "api-key" => password },
    body: command, expected: [200, 201, 204]
  )
  index = File.join(output_dir, "index.html")
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
  until File.exist?(index)
    raise "tinyMediaManager export timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.05
  end
  raise "tinyMediaManager export contains unexpected files" unless Dir.children(output_dir) == ["index.html"]
  bytes = secure_file_bytes(index, max_bytes: MAX_CAPTURE)
  raise "tinyMediaManager export is malformed" unless bytes.empty? || bytes.match?(/\A(?:record\n)+\z/)
  bytes.lines.length
ensure
  FileUtils.remove_entry_secure(output_dir) if output_dir && File.directory?(output_dir) && !File.symlink?(output_dir)
  FileUtils.remove_entry_secure(template_dir) if template_dir && File.directory?(template_dir) && !File.symlink?(template_dir)
end

def emit_probe(service)
  raise "unknown probe" unless SERVICES.include?(service)
  vault_path = ENV.fetch("PLATFORM_MAC_VAULT_FILE")
  password_path = ENV.fetch("PLATFORM_MAC_VAULT_PASSWORD_FILE")
  vault_yaml, vault_error, status = with_private_input_snapshots([vault_path, password_path]) do |snapshots|
    Open3.capture3(
      "ansible-vault", "view", "--vault-password-file", snapshots.fetch(1), snapshots.fetch(0)
    )
  end
  raise "vault read failed" unless status.success? && vault_yaml.bytesize <= 16 * 1024 * 1024 &&
                                               vault_error.bytesize <= MAX_CAPTURE
  vault = YAML.safe_load(vault_yaml, aliases: false)
  vault_yaml.replace("\0" * vault_yaml.bytesize)
  vault_error.replace("\0" * vault_error.bytesize)
  sandbox = File.realpath(ENV.fetch("PLATFORM_MAC_SANDBOX"))

  evidence = case service
             when "audiobookshelf"
               base = "http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_AUDIOBOOKSHELF_PORT'), 10)}"
               _login_response, login = http_json(
                 "post", "#{base}/login",
                 body: { "username" => vault.fetch("vault_audiobookshelf_admin_username"),
                         "password" => vault.fetch("vault_audiobookshelf_admin_password") }
               )
               token = login.fetch("user").fetch("accessToken")
               _users_response, users_payload = http_json("get", "#{base}/api/users", bearer: token)
               users = users_payload.fetch("users")
               identities = users.map do |entry|
                 permission_document = entry.fetch("permissions", {})
                 permissions = if entry.fetch("type") == "root"
                                 ["all"]
                               else
                                 permission_document.fetch("flags", permission_document)
                                                    .select { |_name, enabled| enabled == true }.keys
                               end
                 probe_identity(entry.fetch("username"), entry.fetch("type"),
                                entry.fetch("isActive"), permissions)
               end
               _libraries_response, libraries_payload = http_json("get", "#{base}/api/libraries", bearer: token)
               libraries = libraries_payload.is_a?(Array) ? libraries_payload : libraries_payload.fetch("libraries")
               item_count = libraries.sum do |library|
                 _response, payload = http_json(
                   "get", "#{base}/api/libraries/#{library.fetch('id')}/items?limit=10000&minified=1", bearer: token
                 )
                 next payload.length if payload.is_a?(Array)

                 results = payload.fetch("results")
                 total = payload.fetch("total", results.length)
                 raise "incomplete Audiobookshelf item listing" unless total == results.length
                 results.length
               end
               managed_library = libraries.find { |entry| entry["name"] == "Audiobooks" }
               raise "managed library is unavailable" unless managed_library
               fixture = File.join(sandbox, "legacy/audiobookshelf/media/task-9-contract-book/task-9-contract-book.wav")
               { "identities" => identities,
                 "record_counts" => { "items" => item_count, "libraries" => libraries.length, "users" => users.length },
                 "fixture_sha256" => { "audiobook" => fixture_digest(fixture) },
                 "managed_settings" => { "library_name" => managed_library.fetch("name"),
                                           "media_type" => managed_library.fetch("mediaType") } }
             when "beszel"
               base = "http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_BESZEL_PORT'), 10)}"
               _response, login = http_json(
                 "post", "#{base}/api/collections/_superusers/auth-with-password",
                 body: { "identity" => vault.fetch("vault_beszel_superuser_email"),
                         "password" => vault.fetch("vault_beszel_superuser_password") }
               )
               token = login.fetch("token")
               collections = %w[_superusers users systems alerts].to_h do |collection|
                 _response, payload = http_json(
                   "get", "#{base}/api/collections/#{collection}/records?perPage=500", bearer: token
                 )
                 raise "incomplete Beszel listing" if payload.fetch("totalPages") > 1
                 [collection, payload.fetch("items")]
               end
               identities = collections.fetch("_superusers").map do |entry|
                 probe_identity(entry.fetch("email"), "superuser", entry.fetch("verified", true))
               end
               identities += collections.fetch("users").map do |entry|
                 probe_identity(entry.fetch("email"), entry.fetch("role"), entry.fetch("verified"))
               end
               managed_system = collections.fetch("systems").find { |entry| entry["name"] == "ASUSTOR-AS6704T" }
               raise "managed system is unavailable" unless managed_system
               { "identities" => identities,
                 "record_counts" => { "alerts" => collections.fetch("alerts").length,
                                      "systems" => collections.fetch("systems").length,
                                      "users" => identities.length },
                 "fixture_sha256" => {},
                 "managed_settings" => { "system_name" => managed_system.fetch("name") } }
             when "dozzle"
               base = "http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_DOZZLE_PORT'), 10)}"
               login_response, = http_json(
                 "post", "#{base}/api/token",
                 form: { "username" => vault.fetch("vault_dozzle_admin_username"),
                         "password" => vault.fetch("vault_dozzle_admin_password") }
               )
               cookie = login_response.get_fields("set-cookie")&.map { |value| value.split(";", 2).first }&.join("; ")
               raise "Dozzle authentication failed" if cookie.to_s.empty?
               _response, dispatchers = http_json("get", "#{base}/api/notifications/dispatchers", cookie: cookie)
               _response, rules = http_json("get", "#{base}/api/notifications/rules", cookie: cookie)
               users_document = read_private_yaml(File.join(sandbox, "legacy/dozzle/data/users.yml"))
               users = users_document.fetch("users")
               identities = users.map do |name, entry|
                 roles = entry.fetch("roles")
                 probe_identity(name, name == vault.fetch("vault_dozzle_admin_username") ? "admin" : "user",
                                true, roles.is_a?(Array) ? roles : [roles])
               end
               managed_dispatcher = dispatchers.find { |entry| entry["name"] == "ntfy nas-critical" }
               raise "managed dispatcher is unavailable" unless managed_dispatcher
               { "identities" => identities,
                 "record_counts" => { "dispatchers" => dispatchers.length, "rules" => rules.length,
                                      "users" => users.length },
                 "fixture_sha256" => {},
                 "managed_settings" => { "dispatcher_name" => managed_dispatcher.fetch("name") } }
             when "immich"
               base = "http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_IMMICH_PORT'), 10)}/api"
               _response, login = http_json(
                 "post", "#{base}/auth/login", expected: [201],
                 body: { "email" => vault.fetch("vault_immich_admin_email"),
                         "password" => vault.fetch("vault_immich_admin_password") }
               )
               token = login.fetch("accessToken")
               _response, users = http_json("get", "#{base}/admin/users?withDeleted=true", bearer: token)
               identities = users.map do |entry|
                 probe_identity(entry.fetch("email"), entry.fetch("isAdmin") ? "admin" : "user",
                                entry["deletedAt"].nil?)
               end
               _response, search = http_json(
                 "post", "#{base}/search/metadata", bearer: token,
                 body: { "page" => 1, "size" => 1000 }
               )
               assets = search.fetch("assets")
               asset_items = assets.fetch("items")
               asset_count = assets.fetch("total", asset_items.length)
               raise "incomplete Immich asset listing" unless asset_count == asset_items.length
               _response, settings = http_json("get", "#{base}/system-config", bearer: token)
               upload = File.join(sandbox, "legacy/immich/data/upload")
               photo = first_fixture(upload, "nas-platform-contract-photo.jpg")
               video = first_fixture(upload, "nas-platform-contract-video.mp4")
               { "identities" => identities,
                 "record_counts" => { "assets" => asset_count, "users" => users.length },
                 "fixture_sha256" => { "photo" => fixture_digest(photo), "video" => fixture_digest(video) },
                 "managed_settings" => {
                   "database_backup" => settings.dig("backup", "database", "enabled"),
                   "machine_learning" => settings.dig("machineLearning", "enabled"),
                   "new_version_check" => settings.dig("newVersionCheck", "enabled")
                 } }
             when "jellyfin"
               base = "http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_JELLYFIN_PORT'), 10)}"
               jellyfin_client = 'MediaBrowser Client="nas-platform-baseline", Device="adoption", ' \
                                 'DeviceId="nas-platform-adoption-baseline", Version="1.0.0"'
               _response, login = http_json(
                 "post", "#{base}/Users/AuthenticateByName",
                 authorization: jellyfin_client,
                 body: { "Username" => vault.fetch("vault_jellyfin_admin_username"),
                         "Pw" => vault.fetch("vault_jellyfin_admin_password") }
               )
               token = login.fetch("AccessToken")
               jellyfin_auth = %(#{jellyfin_client}, Token="#{token}")
               _response, users = http_json("get", "#{base}/Users", authorization: jellyfin_auth)
               identities = users.map do |entry|
                 role = entry.dig("Policy", "IsAdministrator") ? "administrator" : "user"
                 permissions = entry.fetch("Policy").select { |_name, enabled| enabled == true }.keys
                 probe_identity(entry.fetch("Name"), role, !entry.dig("Policy", "IsDisabled"), permissions)
               end
               _response, libraries = http_json(
                 "get", "#{base}/Library/VirtualFolders", authorization: jellyfin_auth
               )
               _response, items = http_json(
                 "get", "#{base}/Items?recursive=true&limit=10000&userId=#{login.fetch('User').fetch('Id')}",
                 authorization: jellyfin_auth
               )
               managed_library = libraries.find { |entry| entry["Name"] == "Movies" }
               raise "managed library is unavailable" unless managed_library
               raise "incomplete Jellyfin item listing" unless items.fetch("Items").length ==
                                                                  items.fetch("TotalRecordCount")
               fixture = File.join(sandbox, "legacy/jellyfin/media/Movies/Task 11 Contract Movie (2026)/Task 11 Contract Movie (2026).mp4")
               { "identities" => identities,
                 "record_counts" => { "items" => items.fetch("TotalRecordCount"),
                                      "libraries" => libraries.length, "users" => users.length },
                 "fixture_sha256" => { "video" => fixture_digest(fixture) },
                 "managed_settings" => { "library_name" => managed_library.fetch("Name") } }
             when "komga"
               base = "http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_KOMGA_PORT'), 10)}"
               credentials = [vault.fetch("vault_komga_admin_email"), vault.fetch("vault_komga_admin_password")]
               _response, users = http_json("get", "#{base}/api/v2/users", basic: credentials)
               identities = users.map do |entry|
                 roles = Array(entry.fetch("roles"))
                 probe_identity(entry.fetch("email"), roles.include?("ADMIN") ? "admin" : "user",
                                true, roles)
               end
               _response, libraries = http_json("get", "#{base}/api/v1/libraries", basic: credentials)
               books = libraries.sum do |library|
                 _response, payload = http_json(
                   "get", "#{base}/api/v1/books?unpaged=true&library_id=#{URI.encode_www_form_component(library.fetch('id'))}",
                   basic: credentials
                 )
                 payload.fetch("content").length
               end
               series = libraries.sum do |library|
                 _response, payload = http_json(
                   "get", "#{base}/api/v1/series?unpaged=true&library_id=#{URI.encode_www_form_component(library.fetch('id'))}",
                   basic: credentials
                 )
                 payload.fetch("content").length
               end
               managed_library = libraries.find { |entry| entry["name"] == "Books" }
               raise "managed library is unavailable" unless managed_library
               fixture = File.join(sandbox, "legacy/komga/library/task-10-contract-comic/Task 10 Contract Comic.cbz")
               { "identities" => identities,
                 "record_counts" => { "books" => books, "libraries" => libraries.length,
                                      "series" => series, "users" => users.length },
                 "fixture_sha256" => { "book" => fixture_digest(fixture) },
                 "managed_settings" => { "library_name" => managed_library.fetch("name") } }
             when "ntfy"
               ntfy_uri = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_NTFY_PORT'), 10)}/v1/account")
               ntfy_request = Net::HTTP::Get.new(ntfy_uri)
               ntfy_request.basic_auth(vault.fetch("vault_ntfy_admin_user"), vault.fetch("vault_ntfy_admin_password"))
               ntfy_response = bounded_http_request(ntfy_uri, ntfy_request)
               raise "ntfy authentication failed" unless ntfy_response.code.to_i == 200
               environment_path = ENV.fetch(
                 "PLATFORM_ADOPTION_NTFY_ENV_FILE", File.join(sandbox, "legacy-env/ntfy.env")
               )
               environment = read_private_env(environment_path)
               declared_entries = environment.fetch("NTFY_AUTH_USERS").split(",").map do |record|
                 name, _credential_digest, role = record.split(":", 3)
                 raise "ntfy user is malformed" unless name && role
                 [canonical_identity_name(name), role]
               end
               declared_names = declared_entries.map(&:first)
               raise "ntfy environment contains duplicate identities" unless declared_names.uniq.length == declared_names.length
               declared_users = declared_entries.to_h
               container = "#{ENV.fetch('PLATFORM_PROJECT_NAME')}-legacy-ntfy-ntfy-1"
               live_output, = capture(
                 "docker", "exec", container, "ntfy", "user",
                 "--auth-file=/var/lib/ntfy/auth.db", "--auth-default-access=deny-all", "list"
               )
               live_users = ntfy_live_users(live_output)
               live_names = live_users.map { |entry| canonical_identity_name(entry.fetch("name")) }
               raise "ntfy user listing contains duplicate identities" unless live_names.uniq.length == live_names.length
               live_by_name = live_users.to_h do |entry|
                 [canonical_identity_name(entry.fetch("name")), entry]
               end
               declared_users.each do |name, role|
                 raise "declared ntfy user differs from live state" unless live_by_name.dig(name, "role") == role
               end
               declared_access = ntfy_declared_access(environment.fetch("NTFY_AUTH_ACCESS"))
               live_access = ntfy_live_access(live_users)
               declared_names = declared_users.keys
               raise "ntfy access references an undeclared identity" unless
                 declared_access.all? { |name, _topic, _permission| declared_names.include?(name) }
               live_declared_access = live_access.select do |name, _topic, _permission|
                 declared_names.include?(name)
               end
               raise "declared ntfy access differs from live state" unless
                 declared_access == live_declared_access
               identities = live_users.map do |entry|
                 probe_identity(entry.fetch("name"), entry.fetch("role"), true,
                                entry.fetch("permissions"))
               end
               managed_topic = live_users.flat_map { |entry| entry.fetch("permissions") }
                                         .filter_map { |permission| permission[/\btopic ([-_*A-Za-z0-9]{1,64})\b/, 1] }
                                         .find { |topic| topic == "nas-critical" }
               raise "managed ntfy topic is unavailable" unless managed_topic
               { "identities" => identities,
                 "record_counts" => {
                   "access_rules" => live_users.sum do |entry|
                     entry.fetch("permissions").count { |permission| permission.include?(" topic ") }
                   end,
                                      "users" => identities.length },
                 "fixture_sha256" => {}, "managed_settings" => { "topic" => managed_topic } }
             when "paperless-ngx"
               base = "http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_PAPERLESS_PORT'), 10)}/api"
               _response, login = http_json(
                 "post", "#{base}/token/",
                 body: { "username" => vault.fetch("vault_paperless_admin_username"),
                         "password" => vault.fetch("vault_paperless_admin_password") }
               )
               token = login.fetch("token")
               responses = %w[users documents mail_accounts].to_h do |collection|
                 _response, payload = http_json(
                   "get", "#{base}/#{collection}/?page_size=1000", authorization: "Token #{token}"
                 )
                 raise "incomplete Paperless listing" if payload["next"]
                 [collection, response_records(payload)]
               end
               identities = responses.fetch("users").map do |entry|
                 role = entry.fetch("is_superuser") ? "administrator" : (entry.fetch("is_staff") ? "staff" : "user")
                 probe_identity(entry.fetch("username"), role, entry.fetch("is_active"))
               end
               managed_account = responses.fetch("mail_accounts").find do |entry|
                 entry["name"] == vault.fetch("vault_paperless_mail_account_name")
               end
               raise "managed mail account is unavailable" unless managed_account
               state_path = File.join(ENV.fetch("PLATFORM_REPORT_ROOT"), "paperless-persistence.json")
               document_checksum = parse_strict_json(
                 secure_file_bytes(state_path, max_bytes: 1024 * 1024, private: true)
               ).fetch("pdf_checksum")
               { "identities" => identities,
                 "record_counts" => { "documents" => responses.fetch("documents").length,
                                      "mail_accounts" => responses.fetch("mail_accounts").length,
                                      "users" => responses.fetch("users").length },
                 "fixture_sha256" => { "document" => document_checksum },
                 "managed_settings" => { "mail_account_name" => managed_account.fetch("name") } }
             when "tinymediamanager"
               movie = File.join(sandbox, "legacy/tinymediamanager/movies/Task 10 Contract Movie (2024)/Task 10 Contract Movie (2024).mp4")
               episode = File.join(sandbox, "legacy/tinymediamanager/series/Task 10 Contract Series/Season 01/Task 10 Contract Series - S01E01.mp4")
               data_root = File.join(sandbox, "legacy/tinymediamanager/data")
               template_root = File.join(__dir__, "adoption-probes/tinymediamanager-templates")
               base = "http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_TINYMEDIAMANAGER_API_PORT'), 10)}"
               password = vault.fetch("vault_tinymediamanager_password")
               movie_count = tmm_indexed_count(base, password, "movie", data_root,
                                               File.join(template_root, "movie"))
               show_count = tmm_indexed_count(base, password, "tvshow", data_root,
                                              File.join(template_root, "tvshow"))
               raise "tinyMediaManager fixture is not indexed" unless movie_count.positive? && show_count.positive?
               { "identities" => [probe_identity("shared-login", "administrator")],
                 "record_counts" => { "movies" => movie_count, "shows" => show_count },
                 "fixture_sha256" => { "episode" => fixture_digest(episode), "movie" => fixture_digest(movie) },
                 "managed_settings" => { "api_enabled" => true } }
             end
  reject_forbidden_keys!(evidence)
  validate_evidence!(service, evidence)
  puts JSON.generate(evidence)
ensure
  vault_yaml.replace("\0" * vault_yaml.bytesize) if vault_yaml && !vault_yaml.frozen?
  vault_error.replace("\0" * vault_error.bytesize) if vault_error && !vault_error.frozen?
end

if ARGV.first == "--emit-probe"
  begin
    raise "probe arguments are invalid" unless ARGV.length == 2
    emit_probe(ARGV.fetch(1))
  rescue StandardError
    warn "adoption-probe-error: evidence unavailable"
    exit 1
  end
  exit 0
end

options = {}
set_option = lambda do |key, value|
  raise OptionParser::InvalidOption, "duplicate --#{key.to_s.tr('_', '-')}" if options.key?(key)
  options[key] = value
end
OptionParser.new do |parser|
  parser.on("--output PATH") { |value| set_option.call(:output, value) }
  parser.on("--legacy-commit SHA") { |value| set_option.call(:commit, value) }
  parser.on("--manifest PATH") { |value| set_option.call(:manifest, value) }
  parser.on("--legacy-root PATH") { |value| set_option.call(:legacy_root, value) }
  parser.on("--override-root PATH") { |value| set_option.call(:override_root, value) }
  parser.on("--env-root PATH") { |value| set_option.call(:env_root, value) }
  parser.on("--probe-root PATH") { |value| set_option.call(:probe_root, value) }
end.parse!
refuse("invalid arguments") unless ARGV.empty? && %i[output commit manifest legacy_root override_root env_root probe_root].all? { |key| options[key] }

begin
  raise "legacy commit is invalid" unless options[:commit].match?(/\A[0-9a-f]{40}\z/)
  canaries = ENV.fetch("PLATFORM_ADOPTION_BASELINE_CANARIES", "").split("\n").reject(&:empty?)

  output = File.expand_path(options[:output])
  parent = File.dirname(output)
  parent_stat = File.lstat(parent)
  raise "baseline parent is unsafe" unless parent_stat.directory? && !parent_stat.symlink? &&
                                             parent_stat.uid == Process.uid &&
                                             (parent_stat.mode & 0o777) == 0o700
  raise "baseline path is unsafe" unless File.realpath(parent) == parent
  basename = File.basename(output)
  raise "baseline path is unsafe" unless basename.match?(/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/)
  lock_path = File.join(parent, ".#{basename}.lock")
  lock_flags = File::RDWR | File::CREAT
  lock_flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
  lock_file = File.open(lock_path, lock_flags, 0o600)
  lock_stat = lock_file.stat
  lock_path_stat = File.lstat(lock_path)
  raise "baseline lock is unsafe" unless lock_stat.file? && lock_stat.uid == Process.uid &&
                                          (lock_stat.mode & 0o777) == 0o600 &&
                                          [lock_stat.dev, lock_stat.ino] == [lock_path_stat.dev, lock_path_stat.ino] &&
                                          !lock_path_stat.symlink?
  raise "baseline lock failed" unless lock_file.flock(File::LOCK_EX)
  initial = begin
    publication_file_state(output, expected_mode: 0o600)
  rescue Errno::ENOENT
    nil
  end
  private_root = Dir.mktmpdir(".adoption-private-", parent)
  File.chmod(0o700, private_root)
  vault_path = ENV["PLATFORM_MAC_VAULT_FILE"]
  vault_password_path = ENV["PLATFORM_MAC_VAULT_PASSWORD_FILE"]
  raise "vault inputs differ" unless [vault_path.nil?, vault_password_path.nil?].uniq.length == 1
  probe_vault_environment = {}
  protected_input_states = {}
  if vault_path
    vault_snapshot, vault_digest = snapshot_input(vault_path, private_root, "vault.yml", private: true)
    password_snapshot, password_digest = snapshot_input(
      vault_password_path, private_root, "vault-password", private: true
    )
    protected_input_states = {
      vault_snapshot => [file_signature(vault_snapshot), vault_digest],
      password_snapshot => [file_signature(password_snapshot), password_digest]
    }
    canaries = (canaries + vault_canaries(vault_snapshot, password_snapshot)).uniq
    raise "protected capture input changed" unless snapshots_unchanged?(protected_input_states)
    probe_vault_environment = {
      "PLATFORM_MAC_VAULT_FILE" => vault_snapshot,
      "PLATFORM_MAC_VAULT_PASSWORD_FILE" => password_snapshot
    }
  end

  manifest = YAML.safe_load(
    secure_file_bytes(options[:manifest], max_bytes: 16 * 1024 * 1024), aliases: false
  )
  legacy_source = manifest.fetch("legacy_source")
  manifest_commit = legacy_source.fetch("commit")
  raise "legacy commit differs from manifest" unless manifest_commit == options[:commit]
  repository = legacy_source.fetch("repository")
  raise "legacy repository is invalid" unless repository.is_a?(String) &&
                                              repository.match?(/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/)
  entries = manifest.fetch("services")
  raise "manifest service set differs" unless entries.is_a?(Array) && entries.map { |entry| entry.fetch("name") }.sort == SERVICES

  service_entries = entries.to_h do |entry|
    name = entry.fetch("name")
    path = entry.fetch("legacy_path")
    raise "legacy path is unsafe" unless path.is_a?(String) && path.match?(/\A[A-Za-z0-9_.\/-]+\z/) &&
                                               !path.start_with?("/") && !path.split("/").include?("..")
    [name, path]
  end

  legacy_root = File.realpath(options[:legacy_root])
  pinned_checkout = checkout_snapshot(
    legacy_root, repository, options[:commit], service_entries, canaries
  )

  project_name = ENV.fetch("PLATFORM_PROJECT_NAME")
  raise "project name is invalid" unless project_name.match?(/\A[a-z0-9][a-z0-9_-]{0,62}\z/)
  legacy_images = {}
  services = {}
  Dir.mktmpdir(".adoption-inputs-", parent) do |input_root|
    File.chmod(0o700, input_root)
    SERVICES.each do |service|
      legacy_path = service_entries.fetch(service)
      source_base = File.join(legacy_root, legacy_path)
      source_override = File.join(options[:override_root], "#{service}.yml")
      source_environment = File.join(options[:env_root], "#{service}.env")
      source_probe = File.join(options[:probe_root], "#{service}.sh")
      snapshots = [
        snapshot_input(source_base, input_root, "#{service}-base.yml"),
        snapshot_input(source_override, input_root, "#{service}-override.yml"),
        snapshot_input(source_environment, input_root, "#{service}.env"),
        snapshot_input(source_probe, input_root, "#{service}.sh", executable: true)
      ]
      base, override, environment, probe = snapshots.map(&:first)
      input_states = protected_input_states.merge(snapshots.to_h do |path, digest|
        [path, [file_signature(path), digest]]
      end)
      committed_base, committed_base_diagnostic = capture(
        "git", "-C", legacy_root, "cat-file", "blob", "#{options[:commit]}:#{legacy_path}"
      )
      reject_canaries!(committed_base_diagnostic, canaries)
      raise "legacy compose file differs from pinned commit" unless
        committed_base == secure_file_bytes(base, max_bytes: 16 * 1024 * 1024)

      base_image_stdout, base_image_stderr = capture(
        "docker", "compose", "--env-file", environment, "--project-name",
        "#{project_name}-legacy-#{service}", "-f", base, "config", "--images"
      )
      reject_canaries!(base_image_stderr, canaries)
      expected_images = pinned_images(base_image_stdout, canaries)
      image_stdout, image_stderr = capture(
        "docker", "compose", "--env-file", environment, "--project-name",
        "#{project_name}-legacy-#{service}", "-f", base, "-f", override, "config", "--images"
      )
      reject_canaries!(image_stdout, canaries)
      reject_canaries!(image_stderr, canaries)
      raise "capture input changed" unless snapshots_unchanged?(input_states)
      raise "legacy compose file differs from pinned commit" unless
        secure_file_bytes(base, max_bytes: 16 * 1024 * 1024) == committed_base
      images = pinned_images(image_stdout, canaries)
      raise "legacy image override differs from pinned base" unless images == expected_images
      legacy_images[service] = images

      probe_environment = {
        "PLATFORM_ADOPTION_SCRIPT_DIR" => File.expand_path(__dir__)
      }.merge(probe_vault_environment)
      probe_environment["PLATFORM_ADOPTION_NTFY_ENV_FILE"] = environment if service == "ntfy"
      probe_stdout, probe_stderr = capture(probe_environment, probe)
      reject_canaries!(probe_stdout, canaries)
      reject_canaries!(probe_stderr, canaries)
      raise "capture input changed" unless snapshots_unchanged?(input_states)
      evidence = parse_strict_json(probe_stdout)
      reject_forbidden_keys!(evidence)
      services[service] = validate_evidence!(service, evidence)
    end
  end

  document = {
    "schema" => 1, "legacy_commit" => options[:commit],
    "legacy_images" => legacy_images, "services" => services
  }
  encoded = JSON.pretty_generate(document) << "\n"
  reject_canaries!(encoded, canaries)
  raise "protected capture input changed" unless snapshots_unchanged?(protected_input_states)
  raise "legacy checkout changed during capture" unless checkout_snapshot(
    legacy_root, repository, options[:commit], service_entries, canaries
  ) == pinned_checkout

  Tempfile.create([".adoption-baseline-", ".json"], parent, mode: File::RDWR, perm: 0o600) do |staging|
    staging.write(encoded)
    staging.flush
    staging.fsync
    staged = publication_file_state(staging.path, expected_mode: 0o600)
    raise "baseline staging changed" unless staged.last == Digest::SHA256.hexdigest(encoded)
    current = begin
      publication_file_state(output, expected_mode: 0o600)
    rescue Errno::ENOENT
      nil
    end
    raise "baseline path changed" unless current == initial
    raise "protected capture input changed" unless snapshots_unchanged?(protected_input_states)
    raise "legacy checkout changed before publication" unless checkout_snapshot(
      legacy_root, repository, options[:commit], service_entries, canaries
    ) == pinned_checkout
    current = begin
      publication_file_state(output, expected_mode: 0o600)
    rescue Errno::ENOENT
      nil
    end
    raise "baseline path changed" unless current == initial
    raise "protected capture input changed" unless snapshots_unchanged?(protected_input_states)
    raise "baseline staging changed" unless
      publication_file_state(staging.path, expected_mode: 0o600) == staged
    publish_baseline(staging.path, output, parent, initial)
  end
  puts "Legacy adoption baseline: captured"
rescue StandardError
  refuse("capture refused")
ensure
  destroy_private_directory(private_root)
  lock_file&.close
end
