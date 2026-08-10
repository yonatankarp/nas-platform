#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "digest"
require "net/http"
require "open3"
require "optparse"
require "psych"
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
  value.unicode_normalize(:nfkc).strip.downcase
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
  stdout = stderr = ""
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

def vault_canaries
  vault_path = ENV["PLATFORM_MAC_VAULT_FILE"]
  password_path = ENV["PLATFORM_MAC_VAULT_PASSWORD_FILE"]
  return [] unless vault_path && password_path

  bytes, diagnostics = capture(
    "ansible-vault", "view", "--vault-password-file", password_path, vault_path
  )
  document = YAML.safe_load(bytes, aliases: false)
  collect_secret_values(document).uniq
ensure
  bytes&.replace("\0" * bytes.bytesize)
  diagnostics&.replace("\0" * diagnostics.bytesize)
end

def fixture_digest(path)
  stat = File.lstat(path)
  raise "fixture is unsafe" unless stat.file? && !stat.symlink?

  Digest::SHA256.file(path).hexdigest
end

def file_signature(path)
  stat = File.lstat(path)
  [stat.dev, stat.ino, stat.size, stat.mode, stat.uid, stat.mtime.to_r, stat.ctime.to_r]
end

def publication_file_state(path, expected_mode:)
  stat = File.lstat(path)
  raise "publication path is unsafe" unless stat.file? && !stat.symlink? &&
                                                stat.uid == Process.uid &&
                                                (stat.mode & 0o777) == expected_mode

  [file_signature(path), Digest::SHA256.file(path).hexdigest]
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
    source_bytes = File.binread(source)
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
  response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 30) do |http|
    http.request(request)
  end
  raise "probe request failed" unless expected.include?(response.code.to_i)
  json_response = response["Content-Type"].to_s.downcase.include?("json")
  payload = response.body.to_s.empty? || !json_response ? nil : parse_strict_json(response.body)
  [response, payload]
end

def response_records(payload)
  payload.is_a?(Array) ? payload : payload.fetch("results")
end

def read_private_yaml(path)
  stat = File.lstat(path)
  raise "probe state is unsafe" unless stat.file? && !stat.symlink? && stat.uid == Process.uid

  YAML.safe_load_file(path, aliases: false)
end

def read_private_env(path)
  stat = File.lstat(path)
  raise "probe environment is unsafe" unless stat.file? && !stat.symlink? && stat.uid == Process.uid
  values = {}
  File.foreach(path, chomp: true) do |line|
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
      raise "ntfy user listing is malformed" unless match && current.nil?
      current = { "name" => match[:name], "role" => match[:role], "permissions" => [] }
    elsif line.start_with?("- ")
      supported = NTFY_PERMISSION_LINES.any? { |pattern| pattern.match?(line) }
      raise "ntfy user listing is malformed" unless current && supported
      current.fetch("permissions") << line.delete_prefix("- ")
      records << current
      current = nil
    else
      raise "ntfy user listing is malformed"
    end
  end
  raise "ntfy user listing is incomplete" if current || records.none? { |entry| entry["name"] == "*" }
  normalized = records.map { |entry| canonical_identity_name(entry.fetch("name")) }
  raise "ntfy user listing contains duplicate identities" unless normalized.uniq.length == normalized.length
  records.reject { |entry| entry["name"] == "*" }
end

def emit_probe(service)
  raise "unknown probe" unless SERVICES.include?(service)
  vault_path = ENV.fetch("PLATFORM_MAC_VAULT_FILE")
  password_path = ENV.fetch("PLATFORM_MAC_VAULT_PASSWORD_FILE")
  vault_yaml, vault_error, status = Open3.capture3(
    "ansible-vault", "view", "--vault-password-file", password_path, vault_path
  )
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
               _response, users_payload = http_json(
                 "get", "#{base}/api/collections/users/records?perPage=500", bearer: token
               )
               raise "incomplete Beszel user listing" if users_payload.fetch("totalPages") > 1
               users = users_payload.fetch("items")
               identities = [probe_identity(vault.fetch("vault_beszel_superuser_email"), "superuser")]
               identities += users.map do |entry|
                 probe_identity(entry.fetch("email"), entry.fetch("role"), entry.fetch("verified"))
               end
               collections = %w[systems alerts].to_h do |collection|
                 _response, payload = http_json(
                   "get", "#{base}/api/collections/#{collection}/records?perPage=500", bearer: token
                 )
                 raise "incomplete Beszel listing" if payload.fetch("totalPages") > 1
                 [collection, payload.fetch("items")]
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
               asset_count = assets.fetch("total", assets.fetch("items").length)
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
               ntfy_response = Net::HTTP.start(ntfy_uri.host, ntfy_uri.port, open_timeout: 5, read_timeout: 15) do |http|
                 http.request(ntfy_request)
               end
               raise "ntfy authentication failed" unless ntfy_response.code.to_i == 200
               environment = read_private_env(File.join(sandbox, "legacy-env/ntfy.env"))
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
               state_stat = File.lstat(state_path)
               raise "paperless fixture state is unsafe" unless state_stat.file? && !state_stat.symlink? &&
                                                                state_stat.uid == Process.uid
               document_checksum = parse_strict_json(File.binread(state_path)).fetch("pdf_checksum")
               { "identities" => identities,
                 "record_counts" => { "documents" => responses.fetch("documents").length,
                                      "mail_accounts" => responses.fetch("mail_accounts").length,
                                      "users" => responses.fetch("users").length },
                 "fixture_sha256" => { "document" => document_checksum },
                 "managed_settings" => { "mail_account_name" => managed_account.fetch("name") } }
             when "tinymediamanager"
               movie = File.join(sandbox, "legacy/tinymediamanager/movies/Task 10 Contract Movie (2024)/Task 10 Contract Movie (2024).mp4")
               episode = File.join(sandbox, "legacy/tinymediamanager/series/Task 10 Contract Series/Season 01/Task 10 Contract Series - S01E01.mp4")
               movie_count = Dir.glob(File.join(sandbox, "legacy/tinymediamanager/movies/**/*.mp4")).count
               show_count = Dir.glob(File.join(sandbox, "legacy/tinymediamanager/series/**/*.mp4")).count
               { "identities" => [probe_identity("shared-login", "administrator")],
                 "record_counts" => { "movies" => movie_count, "shows" => show_count },
                 "fixture_sha256" => { "episode" => fixture_digest(episode), "movie" => fixture_digest(movie) },
                 "managed_settings" => { "api_enabled" => true } }
             end
  reject_forbidden_keys!(evidence)
  validate_evidence!(service, evidence)
  puts JSON.generate(evidence)
ensure
  vault_yaml&.replace("\0" * vault_yaml.bytesize)
  vault_error&.replace("\0" * vault_error.bytesize)
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
OptionParser.new do |parser|
  parser.on("--output PATH") { |value| options[:output] = value }
  parser.on("--legacy-commit SHA") { |value| options[:commit] = value }
  parser.on("--manifest PATH") { |value| options[:manifest] = value }
  parser.on("--legacy-root PATH") { |value| options[:legacy_root] = value }
  parser.on("--override-root PATH") { |value| options[:override_root] = value }
  parser.on("--env-root PATH") { |value| options[:env_root] = value }
  parser.on("--probe-root PATH") { |value| options[:probe_root] = value }
end.parse!
refuse("invalid arguments") unless ARGV.empty? && %i[output commit manifest legacy_root override_root env_root probe_root].all? { |key| options[key] }

begin
  raise "legacy commit is invalid" unless options[:commit].match?(/\A[0-9a-f]{40}\z/)
  canaries = ENV.fetch("PLATFORM_ADOPTION_BASELINE_CANARIES", "").split("\n").reject(&:empty?)
  canaries = (canaries + vault_canaries).uniq

  manifest_stat = File.lstat(options[:manifest])
  raise "manifest is unsafe" unless manifest_stat.file? && !manifest_stat.symlink? &&
                                      manifest_stat.uid == Process.uid &&
                                      (manifest_stat.mode & 0o022).zero?
  manifest = YAML.safe_load_file(options[:manifest], aliases: false)
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
  SERVICES.each do |service|
    legacy_path = service_entries.fetch(service)
    base = File.join(legacy_root, legacy_path)
    override = File.join(options[:override_root], "#{service}.yml")
    environment = File.join(options[:env_root], "#{service}.env")
    probe = File.join(options[:probe_root], "#{service}.sh")
    [base, override, environment, probe].each do |path|
      stat = File.lstat(path)
      raise "capture input is unsafe" unless stat.file? && !stat.symlink? &&
                                               stat.uid == Process.uid &&
                                               (stat.mode & 0o022).zero? &&
                                               File.realpath(path) == File.expand_path(path)
    end
    input_signatures = [base, override, environment, probe].to_h do |path|
      [path, file_signature(path)]
    end
    raise "probe is not executable" unless File.executable?(probe)
    committed_base, committed_base_diagnostic = capture(
      "git", "-C", legacy_root, "cat-file", "blob", "#{options[:commit]}:#{legacy_path}"
    )
    reject_canaries!(committed_base_diagnostic, canaries)
    raise "legacy compose file differs from pinned commit" unless committed_base == File.binread(base)

    image_stdout, image_stderr = capture(
      "docker", "compose", "--env-file", environment, "--project-name",
      "#{project_name}-legacy-#{service}", "-f", base, "-f", override, "config", "--images"
    )
    reject_canaries!(image_stdout, canaries)
    reject_canaries!(image_stderr, canaries)
    raise "capture input changed" unless input_signatures.all? do |path, signature|
      file_signature(path) == signature
    end
    raise "legacy compose file differs from pinned commit" unless File.binread(base) == committed_base
    images = image_stdout.lines(chomp: true)
    raise "legacy images are invalid" if images.empty? || images.any?(&:empty?)
    images.each do |image|
      safe_string!(image, "legacy image")
      raise "legacy image is invalid" unless image.match?(/\A\S+\z/)
    end
    legacy_images[service] = images.sort

    probe_stdout, probe_stderr = capture(probe)
    reject_canaries!(probe_stdout, canaries)
    reject_canaries!(probe_stderr, canaries)
    raise "capture input changed" unless input_signatures.all? do |path, signature|
      file_signature(path) == signature
    end
    evidence = parse_strict_json(probe_stdout)
    reject_forbidden_keys!(evidence)
    services[service] = validate_evidence!(service, evidence)
  end

  document = {
    "schema" => 1, "legacy_commit" => options[:commit],
    "legacy_images" => legacy_images, "services" => services
  }
  encoded = JSON.pretty_generate(document) << "\n"
  reject_canaries!(encoded, canaries)
  raise "legacy checkout changed during capture" unless checkout_snapshot(
    legacy_root, repository, options[:commit], service_entries, canaries
  ) == pinned_checkout

  output = File.expand_path(options[:output])
  parent = File.dirname(output)
  parent_stat = File.lstat(parent)
  raise "baseline parent is unsafe" unless parent_stat.directory? && !parent_stat.symlink? &&
                                             parent_stat.uid == Process.uid &&
                                             (parent_stat.mode & 0o777) == 0o700
  raise "baseline path is unsafe" unless File.realpath(parent) == parent
  initial = begin
    publication_file_state(output, expected_mode: 0o600)
  rescue Errno::ENOENT
    nil
  end

  Tempfile.create([".adoption-baseline-", ".json"], parent, mode: File::RDWR, perm: 0o600) do |staging|
    staging.write(encoded)
    staging.flush
    staging.fsync
    staged = publication_file_state(staging.path, expected_mode: 0o600)
    current = begin
      publication_file_state(output, expected_mode: 0o600)
    rescue Errno::ENOENT
      nil
    end
    raise "baseline path changed" unless current == initial
    raise "legacy checkout changed before publication" unless checkout_snapshot(
      legacy_root, repository, options[:commit], service_entries, canaries
    ) == pinned_checkout
    current = begin
      publication_file_state(output, expected_mode: 0o600)
    rescue Errno::ENOENT
      nil
    end
    raise "baseline path changed" unless current == initial
    raise "baseline staging changed" unless publication_file_state(
      staging.path, expected_mode: 0o600
    ) == staged && File.binread(staging.path) == encoded
    File.rename(staging.path, output)
    begin
      File.open(parent, File::RDONLY) { |directory| directory.fsync }
    rescue SystemCallError
      nil
    end
  end
  puts "Legacy adoption baseline: captured"
rescue StandardError
  refuse("capture refused")
end
