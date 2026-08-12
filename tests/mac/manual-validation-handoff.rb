#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "shellwords"
require "tempfile"
require "yaml"

FRESH_PHASES = %w[
  preflight deploy seed verify idempotence drift reconcile recreate persistence
  report cleanup
].freeze
HANDOFF_PHASES = FRESH_PHASES.first(4).freeze
PORT_FIELDS = {
  "audiobookshelf" => "audiobookshelf_port",
  "beszel" => "beszel_port",
  "dozzle" => "dozzle_port",
  "immich" => "immich_port",
  "jellyfin" => "jellyfin_port",
  "komga" => "komga_port",
  "ntfy" => "ntfy_port",
  "paperless-ngx" => "paperless_port",
  "tinymediamanager" => "tinymediamanager_web_port"
}.freeze
PRIMARY_IDENTITIES = {
  "audiobookshelf" => "vault_audiobookshelf_admin_username",
  "beszel" => "vault_beszel_superuser_email",
  "dozzle" => "vault_dozzle_admin_username",
  "immich" => "vault_immich_admin_email",
  "jellyfin" => "vault_jellyfin_admin_username",
  "komga" => "vault_komga_admin_email",
  "ntfy" => "vault_ntfy_admin_user",
  "paperless-ngx" => "vault_paperless_admin_username",
  "tinymediamanager" => nil
}.freeze
MANAGED_KEYS = {
  "paperless-ngx" => "paperless_ngx"
}.freeze
MARKER_KEYS = %w[
  schema lane sandbox report_root vault_file vault_password_file
].freeze

def fail_handoff(message)
  warn message
  exit 1
end

def read_json(path, label)
  fail_handoff("#{label} is unsafe") unless
    File.file?(path) && !File.symlink?(path) && File.stat(path).uid == Process.uid &&
      File.size(path) <= 1_048_576

  JSON.parse(File.read(path))
rescue JSON::ParserError, ArgumentError, SystemCallError
  fail_handoff("#{label} is invalid")
end

def safe_identity(value)
  fail_handoff("manual-validation username is invalid") unless
    value.is_a?(String) && !value.empty? && value.bytesize <= 512 &&
      value.valid_encoding? && value == value.strip &&
      !value.match?(/[\p{Cc}\p{Cf}]/)

  value
end

def file_signature(stat)
  [stat.dev, stat.ino, stat.size, stat.mode, stat.uid, stat.gid, stat.mtime.to_r, stat.ctime.to_r]
end

def entry_identity(stat)
  [stat.dev, stat.ino, stat.mode, stat.uid, stat.gid]
end

def read_deployed_manifest(path, deployment_root, git_revision)
  fail_handoff("manual-validation deployed manifest is unsafe") unless
    File.const_defined?(:NOFOLLOW) && deployment_root == File.expand_path(deployment_root) &&
      path == File.join(deployment_root, "current", "manifest.yml")

  releases_root = File.join(deployment_root, "releases")
  release_root = File.join(releases_root, git_revision)
  current = File.join(deployment_root, "current")
  root_before = File.lstat(deployment_root)
  releases_before = File.lstat(releases_root)
  release_before = File.lstat(release_root)
  current_before = File.lstat(current)
  manifest_before = File.lstat(path)
  fail_handoff("manual-validation deployed manifest is unsafe") unless
    root_before.directory? && !root_before.symlink? && File.realpath(deployment_root) == deployment_root &&
      releases_before.directory? && !releases_before.symlink? && File.realpath(releases_root) == releases_root &&
      release_before.directory? && !release_before.symlink? && File.realpath(release_root) == release_root &&
      current_before.symlink? && File.readlink(current) == release_root &&
      File.realpath(current) == release_root && manifest_before.file? && !manifest_before.symlink? &&
      manifest_before.uid == Process.uid && (manifest_before.mode & 0o777) == 0o644 &&
      manifest_before.size <= 4 * 1024 * 1024

  bytes = File.open(path, File::RDONLY | File::NOFOLLOW) do |input|
    held_before = input.stat
    fail_handoff("manual-validation deployed manifest changed while being read") unless
      file_signature(held_before) == file_signature(manifest_before)
    content = input.read(4 * 1024 * 1024 + 1)
    held_after = input.stat
    fail_handoff("manual-validation deployed manifest changed while being read") unless
      content.bytesize <= 4 * 1024 * 1024 &&
        file_signature(held_before) == file_signature(held_after)
    content
  end

  fail_handoff("manual-validation deployed manifest changed while being read") unless
    entry_identity(File.lstat(deployment_root)) == entry_identity(root_before) &&
      entry_identity(File.lstat(releases_root)) == entry_identity(releases_before) &&
      entry_identity(File.lstat(release_root)) == entry_identity(release_before) &&
      entry_identity(File.lstat(current)) == entry_identity(current_before) &&
      File.readlink(current) == release_root && File.realpath(current) == release_root &&
      file_signature(File.lstat(path)) == file_signature(manifest_before)
  bytes
rescue SystemCallError, ArgumentError
  fail_handoff("manual-validation deployed manifest is unsafe")
end

def validate_progress(state)
  fail_handoff("manual-validation resume status is invalid") unless
    state.is_a?(Hash) && state["lane"] == "fresh" && state["phases"].is_a?(Array)

  phases = state.fetch("phases")
  names = phases.map { |phase| phase["name"] if phase.is_a?(Hash) }
  fail_handoff("manual-validation resume status is invalid") unless
    names == FRESH_PHASES.first(names.length) && names.first(HANDOFF_PHASES.length) == HANDOFF_PHASES

  statuses = phases.map { |phase| phase["status"] }
  fail_handoff("manual-validation resume status is invalid") unless
    statuses.first(HANDOFF_PHASES.length) == Array.new(HANDOFF_PHASES.length, "passed")

  trailing = statuses.drop(HANDOFF_PHASES.length)
  incomplete = trailing.index { |status| status != "passed" }
  valid_trailing = if incomplete
                     %w[running failed].include?(trailing.fetch(incomplete)) &&
                       incomplete == trailing.length - 1
                   else
                     true
                   end
  fail_handoff("manual-validation resume status is invalid") unless valid_trailing
end

def validate_marker_file(path)
  fail_handoff("manual-validation resume marker is unsafe") unless File.file?(path) && !File.symlink?(path)

  marker_stat = File.stat(path)
  fail_handoff("manual-validation resume marker is unsafe") unless
    marker_stat.uid == Process.uid && (marker_stat.mode & 0o777) == 0o600 &&
      marker_stat.size <= 16_384
end

def write_marker(path, marker)
  parent = File.dirname(path)
  fail_handoff("manual-validation resume marker parent is unsafe") unless
    File.directory?(parent) && !File.symlink?(parent) && File.realpath(parent) == parent &&
      File.stat(parent).uid == Process.uid && (File.stat(parent).mode & 0o777) == 0o700
  fail_handoff("manual-validation resume marker is unsafe") if File.symlink?(path)

  temporary = Tempfile.new([".manual-validation-resume.", ".tmp"], parent)
  begin
    temporary.chmod(0o600)
    temporary.write(JSON.pretty_generate(marker) + "\n")
    temporary.flush
    temporary.fsync
    temporary.close
    File.rename(temporary.path, path)
    File.open(parent, File::RDONLY, &:fsync)
  ensure
    temporary.close!
  end
end

def marker_document(options)
  {
    "schema" => 1,
    "lane" => options.fetch(:lane),
    "sandbox" => options.fetch(:sandbox),
    "report_root" => options.fetch(:report_root),
    "vault_file" => options.fetch(:vault_file),
    "vault_password_file" => options.fetch(:vault_password_file)
  }
end

options = { mode: :handoff }
OptionParser.new do |parser|
  parser.on("--validate-resume") { options[:mode] = :validate_resume }
  parser.on("--state FILE") { |value| options[:state] = value }
  parser.on("--manifest FILE") { |value| options[:manifest] = value }
  parser.on("--deployment-root PATH") { |value| options[:deployment_root] = value }
  parser.on("--marker FILE") { |value| options[:marker] = value }
  parser.on("--lane NAME") { |value| options[:lane] = value }
  parser.on("--sandbox PATH") { |value| options[:sandbox] = value }
  parser.on("--report-root PATH") { |value| options[:report_root] = value }
  parser.on("--runner PATH") { |value| options[:runner] = value }
  parser.on("--vault-file FILE") { |value| options[:vault_file] = value }
  parser.on("--vault-password-file FILE") { |value| options[:vault_password_file] = value }
end.parse!
fail_handoff("manual-validation handoff received unexpected arguments") unless ARGV.empty?

required = %i[state marker lane sandbox report_root vault_file vault_password_file]
required.concat(%i[manifest deployment_root runner]) if options.fetch(:mode) == :handoff
fail_handoff("manual-validation handoff arguments are incomplete") unless
  required.all? { |key| options[key].is_a?(String) && !options[key].empty? }
fail_handoff("manual-validation handoff lane is invalid") unless options.fetch(:lane) == "fresh"

state = read_json(options.fetch(:state), "manual-validation phase status")
validate_progress(state)
expected_marker = marker_document(options)

if options.fetch(:mode) == :validate_resume
  validate_marker_file(options.fetch(:marker))
  marker = read_json(options.fetch(:marker), "manual-validation resume marker")
  fail_handoff("manual-validation resume marker is invalid") unless
    marker.is_a?(Hash) && marker.keys.sort == MARKER_KEYS.sort && marker["schema"] == 1
  fail_handoff("resume lane does not match the manual-validation handoff") unless
    marker["lane"] == expected_marker["lane"]
  fail_handoff("resume sandbox does not match the manual-validation handoff") unless
    marker["sandbox"] == expected_marker["sandbox"] &&
      marker["report_root"] == expected_marker["report_root"]
  fail_handoff("resume vault path does not match the manual-validation handoff") unless
    marker["vault_file"] == expected_marker["vault_file"]
  fail_handoff("resume vault password path does not match the manual-validation handoff") unless
    marker["vault_password_file"] == expected_marker["vault_password_file"]
  exit 0
end

begin
  manifest_bytes = read_deployed_manifest(
    options.fetch(:manifest), options.fetch(:deployment_root), state.fetch("git_revision")
  )
  manifest = YAML.safe_load(manifest_bytes, aliases: false)
  fail_handoff("manual-validation deployed manifest is invalid") unless
    manifest.is_a?(Hash) &&
      manifest.keys.sort == %w[git_sha platform_compose_kind platform_kind services].sort &&
      manifest["git_sha"] == state["git_revision"] &&
      manifest["platform_kind"] == state["platform_kind"] &&
      manifest["platform_compose_kind"] == state["platform_compose_kind"]
  service_entries = manifest.fetch("services")
  fail_handoff("manual-validation service manifest is invalid") unless
    service_entries.is_a?(Array) && service_entries.all? do |service|
      service.is_a?(Hash) && service.keys.sort == %w[compose_files images name].sort &&
        service["name"].is_a?(String) && service["compose_files"].is_a?(Array) &&
        service["images"].is_a?(Hash) &&
        service["images"].all? { |name, image| name.is_a?(String) && image.is_a?(String) }
    end
  services = service_entries.map { |service| service.fetch("name") }
  fail_handoff("manual-validation service manifest is invalid") unless
    services.uniq.length == services.length && services.sort == PORT_FIELDS.keys.sort

  vault = YAML.safe_load($stdin.read, aliases: false)
  fail_handoff("manual-validation vault is invalid") unless vault.is_a?(Hash)
  managed = vault.fetch("vault_managed_users")
  fail_handoff("manual-validation managed users are invalid") unless managed.is_a?(Hash)

  lines = [
    "Manual validation is ready.",
    "Sandbox root: #{options.fetch(:sandbox)}",
    "Report root: #{options.fetch(:report_root)}"
  ]
  services.each do |service|
    port = state.fetch(PORT_FIELDS.fetch(service))
    fail_handoff("manual-validation service port is invalid") unless
      port.is_a?(Integer) && port.between?(1024, 65_535)
    lines << "#{service} URL: http://127.0.0.1:#{port}"

    primary_key = PRIMARY_IDENTITIES.fetch(service)
    primary = if primary_key
                safe_identity(vault.fetch(primary_key))
              else
                "not applicable (password-only login)"
              end
    lines << "#{service} primary username: #{primary}"

    managed_key = MANAGED_KEYS.fetch(service, service)
    entries = managed.fetch(managed_key, [])
    fail_handoff("manual-validation managed users are invalid") unless entries.is_a?(Array)
    identities = entries.map do |entry|
      fail_handoff("manual-validation managed users are invalid") unless entry.is_a?(Hash)
      safe_identity(entry.fetch("username", entry["email"]))
    end
    if identities.empty?
      lines << "#{service} managed usernames: none configured"
    else
      identities.each { |identity| lines << "#{service} managed username: #{identity}" }
    end
  end
rescue KeyError, TypeError, Psych::Exception, SystemCallError
  fail_handoff("manual-validation handoff input is invalid")
end

lines << "Passwords remain in the encrypted vault source."
resume = [
  options.fetch(:runner), "--lane", "fresh", "--vault-file", options.fetch(:vault_file),
  "--vault-password-file", options.fetch(:vault_password_file), "--sandbox", options.fetch(:sandbox)
]
lines << "Resume command: #{resume.map { |value| Shellwords.shellescape(value) }.join(' ')}"
write_marker(options.fetch(:marker), expected_marker)
puts lines
