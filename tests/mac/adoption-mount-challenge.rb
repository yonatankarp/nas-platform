#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fiddle/import"
require "json"
require "securerandom"

module ChallengeFS
  extend Fiddle::Importer
  dlload Fiddle.dlopen(nil)
  extern "int openat(int, const char *, int, int)"
  extern "int unlinkat(int, const char *, int)"
  extern "int futimens(int, const void *)"
end

def refuse(message)
  warn "adoption-attestation-error: #{message}"
  exit 1
end

def open_at(parent, name, flags = File::RDONLY, permissions = 0)
  refuse("challenge path is unsafe") unless name.match?(/\A[-._A-Za-z0-9]+\z/) && !%w[. ..].include?(name)
  descriptor = ChallengeFS.openat(parent.fileno, name, flags | File::NOFOLLOW, permissions)
  raise SystemCallError.new("openat", Fiddle.last_error) if descriptor.negative?
  File.for_fd(descriptor).tap { |file| file.close_on_exec = true }
end

def open_bound_directory(path)
  current = File.open(File::SEPARATOR, File::RDONLY | File::NOFOLLOW)
  path.split(File::SEPARATOR).reject(&:empty?).each do |component|
    child = open_at(current, component)
    refuse("challenge path is unsafe") unless child.stat.directory?
    current.close
    current = child
  end
  current
rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP
  refuse("challenge path is unsafe")
end

def unlink_at(parent, name)
  result = ChallengeFS.unlinkat(parent.fileno, name, 0)
  raise SystemCallError.new("unlinkat", Fiddle.last_error) if result.negative?
end

def signature(stat)
  [stat.dev, stat.ino, stat.mode, stat.uid, stat.gid]
end

def time_ns(time)
  (time.to_r * 1_000_000_000).to_i
end

def digest(file)
  file.rewind
  value = Digest::SHA256.new
  value.update(file.read(64 * 1024)) until file.eof?
  file.rewind
  value.hexdigest
end

def set_times(file, atime_ns, mtime_ns)
  values = [atime_ns, mtime_ns].flat_map { |value| [value / 1_000_000_000, value % 1_000_000_000] }
  result = ChallengeFS.futimens(file.fileno, values.pack("l!l!l!l!"))
  raise SystemCallError.new("futimens", Fiddle.last_error) if result.negative?
  file.fsync
end

def open_challenged_file(sandbox, source, kind)
  root = open_bound_directory(sandbox)
  parent = root
  source.split("/").each do |component|
    child = open_at(parent, component)
    parent.close unless parent.equal?(root)
    parent = child
  end
  if kind == "sentinel"
    refuse("challenge root is unsafe") unless parent.stat.directory?
    file = open_at(parent, ".nas-platform-adoption-root-sentinel")
  elsif kind == "file"
    file = parent
    parent = nil
  else
    refuse("challenge kind is invalid")
  end
  [root, parent, file]
rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP
  refuse("challenge path is unsafe")
end

def read_token(directory, name)
  journal = open_at(directory, name)
  stat = journal.stat
  refuse("challenge journal is unsafe") unless stat.file? && stat.uid == Process.uid &&
    (stat.mode & 0o7777) == 0o400 && stat.nlink == 1 && stat.size <= 4096
  bytes = journal.read(4097)
  refuse("challenge journal is unsafe") unless bytes.bytesize <= 4096
  token = JSON.parse(bytes, create_additions: false)
  expected_keys = %w[atime_ns challenge_ns kind mtime_ns sha256 signature source]
  refuse("challenge restoration token differs") unless token.is_a?(Hash) &&
    token.keys.sort == expected_keys && token.fetch("signature").is_a?(Array) &&
    token.fetch("signature").length == 5 &&
    token.fetch("signature").all? { |value| value.is_a?(Integer) } &&
    %w[atime_ns mtime_ns challenge_ns].all? { |key| token.fetch(key).is_a?(Integer) } &&
    token.fetch("source").start_with?("legacy/") && %w[sentinel file].include?(token.fetch("kind")) &&
    token.fetch("sha256").match?(/\A[0-9a-f]{64}\z/)
  token
ensure
  journal&.close
end

action, sandbox, source, kind, expected_digest, journal_path, attestations_json = ARGV
refuse("challenge arguments are invalid") unless %w[prepare restore recover].include?(action)
journal_parent = File.dirname(journal_path)
journal_name = File.basename(journal_path)
journal_directory = open_bound_directory(journal_parent)
journal_stat = journal_directory.stat
refuse("challenge journal is unsafe") unless journal_stat.directory? && journal_stat.uid == Process.uid &&
  (journal_stat.mode & 0o7777) == 0o700 && journal_name.match?(/\A[-._A-Za-z0-9]+\z/)
%w[HUP INT TERM].each { |signal| Signal.trap(signal) { raise Interrupt, "challenge interrupted" } }
prepare_attempted = false
handoff_complete = false
begin
  if action != "prepare"
    token = read_token(journal_directory, journal_name)
    if action == "recover"
      source = token.fetch("source")
      kind = token.fetch("kind")
      expected_digest = token.fetch("sha256")
      attestations = JSON.parse(attestations_json, create_additions: false)
      matches = attestations.select do |entry|
        entry.is_a?(Hash) && entry["source"] == source && entry["kind"] == kind &&
          entry["sha256"] == expected_digest
      end
      refuse("challenge recovery is not bound to the snapshot attestations") unless matches.length == 1
      recovery_attestation = matches.fetch(0)
    else
      refuse("challenge arguments are invalid") unless source.start_with?("legacy/") &&
        expected_digest.match?(/\A[0-9a-f]{64}\z/)
      refuse("challenge restoration token differs") unless token.fetch("source") == source &&
        token.fetch("kind") == kind && token.fetch("sha256") == expected_digest
    end
  else
    refuse("challenge arguments are invalid") unless source.start_with?("legacy/") &&
      expected_digest.match?(/\A[0-9a-f]{64}\z/)
  end
  root, parent, file = open_challenged_file(sandbox, source, kind)
  stat = file.stat
  refuse("challenge source is unsafe") unless stat.file? && stat.uid == Process.uid &&
    stat.nlink == 1 && digest(file) == expected_digest
  if action == "recover"
    live_root = kind == "sentinel" ? parent.stat : stat
    refuse("challenge recovery source identity differs") unless
      [live_root.dev, live_root.ino] == recovery_attestation.values_at("live_dev", "live_ino")
  end

  if action == "prepare"
    challenge_ns = (Time.now.to_i + 86_400 + SecureRandom.random_number(86_400)) * 1_000_000_000
    challenge_ns += 1_000_000_000 if challenge_ns == time_ns(stat.mtime)
    token = {
      "source" => source, "kind" => kind, "signature" => signature(stat),
      "atime_ns" => time_ns(stat.atime), "mtime_ns" => time_ns(stat.mtime),
      "challenge_ns" => challenge_ns, "sha256" => expected_digest
    }
    journal = open_at(
      journal_directory, journal_name, File::WRONLY | File::CREAT | File::EXCL, 0o400
    )
    journal.write(JSON.generate(token))
    journal.flush
    journal.chmod(0o400)
    journal.fsync
    journal.close
    journal_directory.fsync
    prepare_attempted = true
    set_times(file, token.fetch("atime_ns"), challenge_ns)
    refuse("challenge source changed") unless signature(file.stat) == token.fetch("signature") &&
      time_ns(file.stat.mtime) == challenge_ns
    puts challenge_ns
    $stdout.flush
    handoff_complete = true
  else
    refuse("challenge restoration token differs") unless token.fetch("signature") == signature(stat) &&
      token.fetch("challenge_ns") == time_ns(stat.mtime)
    set_times(file, token.fetch("atime_ns"), token.fetch("mtime_ns"))
    unlink_at(journal_directory, journal_name)
    journal_directory.fsync
  end
ensure
  if action == "prepare" && prepare_attempted && !handoff_complete
    begin
      set_times(file, token.fetch("atime_ns"), token.fetch("mtime_ns"))
      unlink_at(journal_directory, journal_name)
      journal_directory.fsync
    rescue StandardError => error
      warn "adoption-attestation-error: challenge rollback failed: #{error.class}"
    end
  end
  journal&.close
  file&.close
  parent&.close
  root&.close
  journal_directory&.close
end
