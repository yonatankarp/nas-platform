#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fiddle/import"
require "json"
require "open3"
require "securerandom"

module RollbackComposeFS
  extend Fiddle::Importer
  dlload Fiddle.dlopen(nil)
  extern "int openat(int, const char *, int, int)"
  extern "int linkat(int, const char *, int, const char *, int)"
  extern "int unlinkat(int, const char *, int)"
end

def openat(parent, name, flags, mode = 0)
  descriptor = RollbackComposeFS.openat(parent.fileno, name, flags, mode)
  raise SystemCallError.new("openat", Fiddle.last_error) if descriptor.negative?

  file = File.for_fd(descriptor, flags & File::WRONLY == File::WRONLY ? "w" : "r")
  return file unless block_given?

  begin
    yield file
  ensure
    file.close
  end
end

def linkat(parent, source, destination)
  result = RollbackComposeFS.linkat(parent.fileno, source, parent.fileno, destination, 0)
  raise SystemCallError.new("linkat", Fiddle.last_error) if result.negative?
end

def unlinkat(parent, name)
  result = RollbackComposeFS.unlinkat(parent.fileno, name, 0)
  raise SystemCallError.new("unlinkat", Fiddle.last_error) if result.negative?
end

def refuse
  warn "adoption-rollback-compose-error: operation refused"
  exit 1
end

def signature(stat)
  [stat.dev, stat.ino, stat.size, stat.mode, stat.uid, stat.gid, stat.mtime.to_r, stat.ctime.to_r]
end

def identity(stat)
  [stat.dev, stat.ino, stat.mode, stat.uid, stat.gid]
end

def open_input(path, executable: false)
  initial = File.lstat(path)
  raise unless initial.file? && !initial.symlink? && initial.uid == Process.uid &&
               (initial.mode & 0o022).zero? && (!executable || (initial.mode & 0o100).positive?)
  file = File.open(path, File::RDONLY | File::NOFOLLOW)
  raise unless signature(file.stat) == signature(initial)
  file.close_on_exec = false
  [file, initial]
end

def unchanged!(path, file, initial)
  raise unless signature(file.stat) == signature(initial) && signature(File.lstat(path)) == signature(initial)
end

def capture_compose(command, descriptors)
  stdout, _stderr, status = Open3.capture3(
    "docker", "compose", *command, { close_others: false }
  )
  raise unless status.success? && stdout.bytesize <= 16 * 1024 * 1024
  descriptors.each_value(&:rewind)
  stdout
end

def descriptor_digest(file)
  digest = Digest::SHA256.file("/dev/fd/#{file.fileno}").hexdigest
  file.rewind
  digest
end

def validate_resolved!(bytes, rollback_root)
  document = JSON.parse(bytes)
  raise unless document.is_a?(Hash) && document.fetch("services").is_a?(Hash) &&
               !document.fetch("services").empty?
  raise unless Array(document["configs"]).empty? && Array(document["secrets"]).empty?
  [document.fetch("networks", {}), document.fetch("volumes", {})].each do |resources|
    raise unless resources.is_a?(Hash) && resources.values.none? { |resource| resource.fetch("external", false) }
  end
  document.fetch("services").each do |service_name, service|
    raise unless service_name.match?(/\A[a-z0-9][a-z0-9_-]*\z/) &&
                 service.fetch("privileged", false) == false && Array(service["devices"]).empty? &&
                 service.fetch("network_mode", "") != "host" && !service.key?("build") &&
                 Array(service["configs"]).empty? && Array(service["secrets"]).empty?
    Array(service["volumes"]).each do |volume|
      raise unless volume.is_a?(Hash) && %w[bind volume tmpfs].include?(volume.fetch("type"))
      next unless volume.fetch("type") == "bind"

      source = volume.fetch("source")
      rollback_bind = source == rollback_root || source.start_with?("#{rollback_root}/")
      socket_proxy_bind = service_name == "socket-proxy" && source == "/var/run/docker.sock" &&
                          volume.fetch("target") == "/var/run/docker.sock" && volume.fetch("read_only") == true
      raise unless rollback_bind || socket_proxy_bind
    end
  end
  document
end

def publish_resolved(parent_path, service, bytes)
  digest = Digest::SHA256.hexdigest(bytes)
  final_name = "#{service}.#{digest}.json"
  parent = File.open(parent_path, File::RDONLY | File::NOFOLLOW)
  parent_stat = parent.stat
  raise unless parent_stat.directory? && parent_stat.uid == Process.uid && (parent_stat.mode & 0o777) == 0o700
  temporary_name = ".#{service}.#{SecureRandom.hex(16)}.json"
  temporary_created = false
  openat(parent, temporary_name, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o400) do |file|
    temporary_created = true
    file.write(bytes)
    file.flush
    file.fsync
    file.chmod(0o400)
  end
  raise unless File.realpath(parent_path) == parent_path && identity(File.stat(parent_path)) == identity(parent_stat)
  linkat(parent, temporary_name, final_name)
  unlinkat(parent, temporary_name)
  temporary_created = false
  parent.fsync
  puts final_name
ensure
  unlinkat(parent, temporary_name) if parent && temporary_created
  parent&.close
end

def run_bound(config_path, digest, project, action)
  parent_path = File.dirname(config_path)
  parent = File.open(parent_path, File::RDONLY | File::NOFOLLOW)
  parent_stat = parent.stat
  raise unless parent_stat.directory? && parent_stat.uid == Process.uid && (parent_stat.mode & 0o777) == 0o500
  config, initial = open_input(config_path)
  bytes = config.read
  raise unless Digest::SHA256.hexdigest(bytes) == digest
  config.rewind
  arguments = ["--project-directory", parent_path, "--project-name", project, "-f", "/dev/fd/#{config.fileno}"]
  arguments.concat(case action
                   when "images" then ["config", "--images"]
                   when "up" then ["up", "--detach", "--wait", "--wait-timeout", "600"]
                   when "stop" then ["stop"]
                   else raise
                   end)
  stdout, _stderr, status = Open3.capture3(
    { "PLATFORM_MAC_SANDBOX" => File.dirname(parent_path) },
    "docker", "compose", *arguments, close_others: false
  )
  raise unless status.success? && stdout.bytesize <= 1024 * 1024
  unchanged!(config_path, config, initial)
  raise unless File.realpath(parent_path) == parent_path && identity(File.stat(parent_path)) == identity(parent_stat)
  print stdout if action == "images"
ensure
  config&.close
  parent&.close
end

begin
  action = ARGV.shift
  case action
  when "resolve"
    raise unless ARGV.length == 11
    base_path, override_path, env_path, parent_path, service, project, project_directory, rollback_root,
      base_digest, override_digest, environment_digest = ARGV
    raise unless service.match?(/\A[a-z0-9][a-z0-9-]*\z/) && project.match?(/\A[a-z0-9][a-z0-9_-]*\z/)
    base, base_stat = open_input(base_path)
    override, override_stat = open_input(override_path)
    environment, environment_stat = open_input(env_path)
    raise unless [base_digest, override_digest, environment_digest].all? { |digest| digest.match?(/\A[0-9a-f]{64}\z/) }
    raise unless descriptor_digest(base) == base_digest && descriptor_digest(override) == override_digest &&
                 descriptor_digest(environment) == environment_digest
    command = [
      "--project-directory", project_directory, "--env-file", "/dev/fd/#{environment.fileno}",
      "--project-name", project, "-f", "/dev/fd/#{base.fileno}",
      "-f", "/dev/fd/#{override.fileno}", "config", "--format", "json"
    ]
    bytes = capture_compose(command, base: base, override: override, environment: environment)
    unchanged!(base_path, base, base_stat)
    unchanged!(override_path, override, override_stat)
    unchanged!(env_path, environment, environment_stat)
    document = validate_resolved!(bytes, rollback_root)
    document["x-nas-platform-adoption-binding"] = {
      "schema" => 1, "service" => service, "base_sha256" => base_digest,
      "override_sha256" => override_digest, "environment_sha256" => environment_digest,
      "compose_services" => document.fetch("services").keys.sort
    }
    bytes = "#{JSON.generate(document)}\n"
    publish_resolved(parent_path, service, bytes)
  when "images", "up", "stop"
    raise unless ARGV.length == 3
    config_path, digest, project = ARGV
    raise unless digest.match?(/\A[0-9a-f]{64}\z/) && project.match?(/\A[a-z0-9][a-z0-9_-]*\z/)
    run_bound(config_path, digest, project, action)
  else
    raise
  end
rescue StandardError => error
  warn error.full_message if ENV["PLATFORM_ADOPTION_ROLLBACK_SELF_TEST"] == "1"
  refuse
ensure
  base&.close
  override&.close
  environment&.close
end
