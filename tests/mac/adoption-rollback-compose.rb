#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fiddle/import"
require "json"
require "open3"
require "rbconfig"
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

def capture_compose(command, descriptors, child_environment = {})
  stdout, _stderr, status = Open3.capture3(
    child_environment, "docker", "compose", *command, { close_others: false }
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

def digest_file(file)
  file.rewind
  digest = Digest::SHA256.new
  digest.update(file.read(64 * 1024)) until file.eof?
  file.rewind
  digest.hexdigest
end

def safe_component!(component)
  raise unless component.match?(/\A[-._A-Za-z0-9]+\z/) && !%w[. ..].include?(component)
end

def bind_identity(stat)
  {
    "dev" => stat.dev, "ino" => stat.ino, "mode" => stat.mode,
    "uid" => stat.uid, "gid" => stat.gid
  }
end

def walk_bind_source(rollback_root, source, kind, expected_size, expected_digest)
  relative = source.delete_prefix("#{rollback_root}/")
  raise if relative == source || relative.empty?
  root = File.open(rollback_root, File::RDONLY | File::NOFOLLOW)
  raise unless root.stat.directory? && root.stat.uid == Process.uid
  current = root
  components = [[".", bind_identity(root.stat)]]
  relative.split("/").each_with_index do |component, index|
    safe_component!(component)
    child = openat(current, component, File::RDONLY | File::NOFOLLOW)
    raise unless index == relative.split("/").length - 1 || child.stat.directory?
    components << [relative.split("/")[0..index].join("/"), bind_identity(child.stat)]
    current.close unless current.equal?(root)
    current = child
  end
  challenged = if kind == "sentinel"
                 raise unless current.stat.directory?
                 openat(current, ".nas-platform-adoption-root-sentinel", File::RDONLY | File::NOFOLLOW)
               elsif kind == "file"
                 raise unless current.stat.file?
                 current
               else
                 raise
               end
  raise unless challenged.stat.file? && challenged.stat.uid == Process.uid && challenged.stat.nlink == 1 &&
               challenged.stat.size == expected_size && digest_file(challenged) == expected_digest
  components
ensure
  challenged&.close unless challenged&.equal?(current)
  current&.close
  root&.close unless root&.closed?
end

def expected_bindings(attestations_bytes, rollback_root, adoption_service)
  records = JSON.parse(attestations_bytes)
  required = %w[service legacy_compose_service source target access kind container_path size sha256]
  raise unless records.is_a?(Array) && records.length == 32 &&
               records.all? { |record| record.is_a?(Hash) && required.all? { |key| record.key?(key) } } &&
               records.map { |record| record.fetch("source") }.uniq.length == 32
  selected = records.select { |record| record.fetch("service") == adoption_service }
  raise if selected.empty?
  selected.map do |record|
    raise unless %w[ro rw].include?(record.fetch("access")) && %w[sentinel file].include?(record.fetch("kind")) &&
                 record.fetch("size").is_a?(Integer) && record.fetch("size").between?(0, 64 * 1024 * 1024) &&
                 record.fetch("sha256").match?(/\A[0-9a-f]{64}\z/) && record.fetch("source").start_with?("legacy/")
    raise if record.fetch("kind") == "sentinel" && record.fetch("size") > 256
    source = File.join(rollback_root, record.fetch("source"))
    record.slice(*required).merge(
      "absolute_source" => source,
      "components" => walk_bind_source(
        rollback_root, source, record.fetch("kind"), record.fetch("size"), record.fetch("sha256")
      )
    )
  end
end

def validate_resolved!(bytes, rollback_root, expected_binds)
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
  actual_binds = document.fetch("services").flat_map do |service_name, service|
    Array(service["volumes"]).filter_map do |volume|
      next unless volume.fetch("type") == "bind"
      next if service_name == "socket-proxy" && volume.fetch("source") == "/var/run/docker.sock"

      [service_name, volume.fetch("source"), volume.fetch("target"), volume.fetch("read_only", false) ? "ro" : "rw"]
    end
  end
  expected_tuples = expected_binds.map do |record|
    [record.fetch("legacy_compose_service"), record.fetch("absolute_source"),
     record.fetch("target"), record.fetch("access")]
  end
  raise unless actual_binds.sort == expected_tuples.sort
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

def verify_bind_records!(document, rollback_root)
  binding = document.fetch("x-nas-platform-adoption-binding")
  records = binding.fetch("binds")
  raise unless records.is_a?(Array) && !records.empty?
  records.each do |record|
    current = walk_bind_source(
      rollback_root, record.fetch("absolute_source"), record.fetch("kind"),
      record.fetch("size"), record.fetch("sha256")
    )
    raise unless current == record.fetch("components")
  end
  records
end

def capture_external(environment, *command, limit: 1024 * 1024, inherit_descriptors: false,
                     file_size_limit: nil)
  options = { close_others: !inherit_descriptors }
  options[:rlimit_fsize] = file_size_limit if file_size_limit
  stdout, stderr, status = Open3.capture3(
    environment, *command, options
  )
  raise "external command failed: #{command.first(2).join(' ')} status=#{status.exitstatus.inspect} #{stderr.byteslice(0, 512)}" unless
    status.success? && stdout.bytesize <= limit
  stdout
end

def entry_exists_at?(parent, name)
  entry = openat(parent, name, File::RDONLY | File::NOFOLLOW)
  true
rescue Errno::ENOENT
  false
ensure
  entry&.close
end

def recovery_attestations(records)
  records.map do |record|
    final_identity = record.fetch("components").last.fetch(1)
    {
      "source" => record.fetch("source"), "kind" => record.fetch("kind"),
      "sha256" => record.fetch("sha256"), "live_dev" => final_identity.fetch("dev"),
      "live_ino" => final_identity.fetch("ino")
    }
  end
end

def recover_challenge!(challenge, rollback_root, records, journal)
  capture_external(
    {}, RbConfig.ruby, challenge, "recover", rollback_root, "-", "-", "-", journal,
    JSON.generate(recovery_attestations(records))
  )
end

def recover_pending_challenge!(records, rollback_root)
  challenge = File.join(__dir__, "adoption-mount-challenge.rb")
  journal = File.join(rollback_root, ".rollback-mount-challenge.json")
  root = File.open(rollback_root, File::RDONLY | File::NOFOLLOW)
  raise unless root.stat.directory? && root.stat.uid == Process.uid && (root.stat.mode & 0o777) == 0o700
  if entry_exists_at?(root, ".rollback-mount-challenge.json")
    recover_challenge!(challenge, rollback_root, records, journal)
  end
  raise if entry_exists_at?(root, ".rollback-mount-challenge.json")
ensure
  root&.close
end

def restore_challenge!(challenge, rollback_root, record, journal)
  raise "forced challenge restoration failure" if
    ENV["PLATFORM_ADOPTION_ROLLBACK_CHALLENGE_FAULT"] == "restore-failure"
  capture_external(
    {}, RbConfig.ruby, challenge, "restore", rollback_root, record.fetch("source"),
    record.fetch("kind"), record.fetch("sha256"), journal, "-"
  )
end

def attest_mounts!(config, compose_arguments, records, rollback_root)
  challenge = File.join(__dir__, "adoption-mount-challenge.rb")
  environment = { "PLATFORM_MAC_SANDBOX" => rollback_root }
  root = File.open(rollback_root, File::RDONLY | File::NOFOLLOW)
  raise unless root.stat.directory? && root.stat.uid == Process.uid && (root.stat.mode & 0o777) == 0o700
  journal = File.join(rollback_root, ".rollback-mount-challenge.json")
  if entry_exists_at?(root, ".rollback-mount-challenge.json")
    recover_challenge!(challenge, rollback_root, records, journal)
    raise if entry_exists_at?(root, ".rollback-mount-challenge.json")
  end
  containers = {}
  records.each do |record|
    compose_service = record.fetch("legacy_compose_service")
    containers[compose_service] ||= begin
      config.rewind
      ids = capture_external(
        environment, "docker", "compose", *compose_arguments, "ps", "-q", compose_service,
        inherit_descriptors: true
      ).lines(chomp: true).reject(&:empty?)
      raise unless ids.length == 1
      ids.fetch(0)
    end
    container = containers.fetch(compose_service)
    mounts = JSON.parse(capture_external(
      environment, "docker", "inspect", "--format", "{{json .Mounts}}", container
    ))
    selected = mounts.select { |mount| mount.fetch("Destination") == record.fetch("target") }
    unless selected.length == 1 && selected.fetch(0).fetch("Source") == record.fetch("absolute_source") &&
        selected.fetch(0).fetch("RW") == (record.fetch("access") == "rw")
      raise "mount tuple differs for #{container}: #{mounts.inspect}"
    end

    temporary_name = ".rollback-mount-readback.#{SecureRandom.hex(16)}"
    temporary_path = File.join(rollback_root, temporary_name)
    prepare_attempted = false
    begin
      prepare_attempted = true
      handoff = capture_external(
        {}, RbConfig.ruby, challenge, "prepare", rollback_root, record.fetch("source"),
        record.fetch("kind"), record.fetch("sha256"), journal, "-"
      ).strip
      handoff = "malformed" if
        ENV["PLATFORM_ADOPTION_ROLLBACK_CHALLENGE_FAULT"] == "malformed-handoff"
      challenge_ns = Integer(handoff, 10)
      capture_external(
        environment, "docker", "cp", "#{container}:#{record.fetch('container_path')}", temporary_path,
        file_size_limit: record.fetch("kind") == "sentinel" ? 256 : 64 * 1024 * 1024
      )
      readback = openat(root, temporary_name, File::RDONLY | File::NOFOLLOW)
      stat = readback.stat
      raise unless stat.file? && stat.uid == Process.uid && stat.nlink == 1 &&
                   stat.size == record.fetch("size") && digest_file(readback) == record.fetch("sha256") &&
                   (stat.mtime.to_r * 1_000_000_000).to_i == challenge_ns
    ensure
      readback&.close
      restoration_error = nil
      if prepare_attempted && entry_exists_at?(root, ".rollback-mount-challenge.json")
        begin
          restore_challenge!(challenge, rollback_root, record, journal)
        rescue StandardError => error
          restoration_error = error
        end
      end
      begin
        unlinkat(root, temporary_name)
      rescue Errno::ENOENT
        nil
      end
      raise restoration_error if restoration_error
    end
  end
ensure
  root&.close
end

def run_bound(config_path, digest, project, action)
  parent_path = File.dirname(config_path)
  parent = File.open(parent_path, File::RDONLY | File::NOFOLLOW)
  parent_stat = parent.stat
  raise unless parent_stat.directory? && parent_stat.uid == Process.uid && (parent_stat.mode & 0o777) == 0o500
  config, initial = open_input(config_path)
  bytes = config.read
  raise unless Digest::SHA256.hexdigest(bytes) == digest
  document = JSON.parse(bytes)
  rollback_root = File.dirname(parent_path)
  config.rewind
  arguments = ["--project-directory", parent_path, "--project-name", project, "-f", "/dev/fd/#{config.fileno}"]
  arguments.concat(case action
                   when "images" then ["config", "--images"]
                   when "up" then ["up", "--detach", "--wait", "--wait-timeout", "600"]
                   when "stop" then ["stop"]
                   else raise
                   end)
  records = verify_bind_records!(document, rollback_root) if action == "up"
  recover_pending_challenge!(records, rollback_root) if action == "up"
  stdout, _stderr, status = Open3.capture3(
    { "PLATFORM_MAC_SANDBOX" => rollback_root },
    "docker", "compose", *arguments, close_others: false
  )
  raise unless status.success? && stdout.bytesize <= 1024 * 1024
  if action == "up"
    attest_mounts!(config, arguments.first(6), records, rollback_root)
    verify_bind_records!(document, rollback_root)
  end
  unchanged!(config_path, config, initial)
  raise unless File.realpath(parent_path) == parent_path && identity(File.stat(parent_path)) == identity(parent_stat)
  print stdout if action == "images"
ensure
  config&.close
  parent&.close
end

begin
  action = ARGV.shift
  challenge_fault = ENV.fetch("PLATFORM_ADOPTION_ROLLBACK_CHALLENGE_FAULT", "")
  raise unless challenge_fault.empty? ||
               (ENV["PLATFORM_ADOPTION_ROLLBACK_SELF_TEST"] == "1" &&
                %w[malformed-handoff restore-failure].include?(challenge_fault))
  case action
  when "publish-attestations"
    raise unless ARGV.length == 2
    rollback_root, digest = ARGV
    raise unless digest.match?(/\A[0-9a-f]{64}\z/)
    bytes = STDIN.read(1024 * 1024 + 1)
    raise unless bytes.bytesize <= 1024 * 1024 && Digest::SHA256.hexdigest(bytes) == digest
    root = File.open(rollback_root, File::RDONLY | File::NOFOLLOW)
    stat = root.stat
    raise unless stat.directory? && stat.uid == Process.uid && (stat.mode & 0o777) == 0o700
    openat(
      root, "rollback-attestations.json",
      File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o400
    ) do |file|
      file.write(bytes)
      file.flush
      file.chmod(0o400)
      file.fsync
    end
    root.fsync
    puts File.join(rollback_root, "rollback-attestations.json")
  when "resolve"
    raise unless ARGV.length == 13
    base_path, override_path, env_path, parent_path, service, project, project_directory, rollback_root,
      base_digest, override_digest, environment_digest, attestations_path, attestations_digest = ARGV
    raise unless service.match?(/\A[a-z0-9][a-z0-9-]*\z/) && project.match?(/\A[a-z0-9][a-z0-9_-]*\z/)
    base, base_stat = open_input(base_path)
    override, override_stat = open_input(override_path)
    environment, environment_stat = open_input(env_path)
    attestations, attestations_stat = open_input(attestations_path)
    raise unless [base_digest, override_digest, environment_digest, attestations_digest].all? {
      |digest| digest.match?(/\A[0-9a-f]{64}\z/)
    }
    raise unless descriptor_digest(base) == base_digest && descriptor_digest(override) == override_digest &&
                 descriptor_digest(environment) == environment_digest &&
                 descriptor_digest(attestations) == attestations_digest
    attestation_bytes = attestations.read
    attestations.rewind
    bind_records = expected_bindings(attestation_bytes, rollback_root, service)
    command = [
      "--project-directory", project_directory, "--env-file", "/dev/fd/#{environment.fileno}",
      "--project-name", project, "-f", "/dev/fd/#{base.fileno}",
      "-f", "/dev/fd/#{override.fileno}", "config", "--format", "json"
    ]
    bytes = capture_compose(
      command, { base: base, override: override, environment: environment },
      "PLATFORM_MAC_SANDBOX" => rollback_root
    )
    unchanged!(base_path, base, base_stat)
    unchanged!(override_path, override, override_stat)
    unchanged!(env_path, environment, environment_stat)
    unchanged!(attestations_path, attestations, attestations_stat)
    document = validate_resolved!(bytes, rollback_root, bind_records)
    document["x-nas-platform-adoption-binding"] = {
      "schema" => 1, "service" => service, "base_sha256" => base_digest,
      "override_sha256" => override_digest, "environment_sha256" => environment_digest,
      "attestations_sha256" => attestations_digest,
      "compose_services" => document.fetch("services").keys.sort, "binds" => bind_records
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
  attestations&.close
  root&.close
end
