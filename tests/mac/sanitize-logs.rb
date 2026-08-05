#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "optparse"
require "tempfile"
require "tmpdir"
require "time"

REDACTION = "[REDACTED]"
CONTAINER_ID = /\A[a-f0-9]{12,64}\z/
CONTAINER_NAME = /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z/
TIMESTAMP = /\A(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z)(?:\s|\z)/

def sanitize_line(line)
  timestamp_prefix = line.byteslice(0, 40).to_s.encode(
    Encoding::UTF_8, invalid: :replace, undef: :replace, replace: ""
  )
  match = timestamp_prefix.match(TIMESTAMP)
  timestamp = begin
    Time.iso8601(match[1]) && match[1] if match
  rescue ArgumentError
    nil
  end
  { "timestamp" => timestamp, "message" => REDACTION }
end

def atomic_json(path, content)
  parent = File.dirname(File.expand_path(path))
  raise "output parent must be a real directory" unless File.directory?(parent) && !File.symlink?(parent)
  raise "refusing symlink output" if File.symlink?(path)

  Tempfile.create([".#{File.basename(path)}.", ".tmp"], parent) do |file|
    file.chmod(0o600)
    file.write(JSON.pretty_generate(content))
    file.write("\n")
    file.flush
    file.fsync
    File.rename(file.path, path)
  end
end

def validate_options(options)
  raise "invalid container id" unless options.fetch(:container_id).match?(CONTAINER_ID)
  raise "invalid container name" unless options.fetch(:container_name).match?(CONTAINER_NAME)
  tail = Integer(options.fetch(:tail, 200), 10)
  raise "tail must be between 1 and 500" unless tail.between?(1, 500)

  options.merge(tail: tail)
rescue ArgumentError
  raise "tail must be an integer"
end

def capture_logs(options, docker_command = "docker")
  options = validate_options(options)
  lines = []
  capture_status = "ok"

  begin
    Open3.popen3(
      docker_command, "logs", "--timestamps", "--tail", options.fetch(:tail).to_s,
      options.fetch(:container_id)
    ) do |stdin, stdout, stderr, wait_thread|
      stdin.close
      streams = [stdout, stderr].map do |stream|
        Thread.new do
          sanitized = []
          stream.each_line { |line| sanitized << sanitize_line(line) }
          sanitized
        end
      end
      streams.each { |thread| lines.concat(thread.value) }
      capture_status = "docker_error" unless wait_thread.value.success?
    end
  rescue SystemCallError
    capture_status = "docker_error"
  end

  evidence = {
    "schema" => 1,
    "source" => {
      "container_id" => options.fetch(:container_id),
      "container_name" => options.fetch(:container_name)
    },
    "capture_status" => capture_status,
    "line_count" => lines.length,
    "timestamp_count" => lines.count { |line| line["timestamp"] },
    "lines" => lines
  }
  atomic_json(options.fetch(:output), evidence)
end

def self_test
  Dir.mktmpdir("nas-platform-log-sanitizer.") do |directory|
    docker = File.join(directory, "docker")
    output = File.join(directory, "container-log-0123456789ab.json")
    File.write(docker, <<~'SH')
      #!/bin/sh
      printf '%s\n' \
        '2026-08-05T12:34:56.123456789Z password=hunter2' \
        'arbitrary plaintext must disappear' \
        '2026-99-99T99:99:99Z malformed timestamp secret'
      printf '%s\n' \
        '2026-08-05T12:35:00Z token=abc123' \
        '-----BEGIN PRIVATE KEY-----' >&2
      printf '\377binary-secret\n' >&2
      exit 7
    SH
    File.chmod(0o700, docker)

    capture_logs({
      container_id: "0123456789ab",
      container_name: "proof-service-1",
      output: output,
      tail: "20"
    }, docker)

    body = File.read(output)
    %w[hunter2 abc123 password token PRIVATE arbitrary plaintext malformed secret].each do |sentinel|
      raise "raw log sentinel reached sanitized evidence" if body.include?(sentinel)
    end
    evidence = JSON.parse(body)
    raise "Docker failure was not sanitized" unless evidence["capture_status"] == "docker_error"
    raise "log line count is incorrect" unless evidence["line_count"] == 6
    raise "timestamp count is incorrect" unless evidence["timestamp_count"] == 2
    expected_timestamps = ["2026-08-05T12:34:56.123456789Z", "2026-08-05T12:35:00Z"]
    retained = evidence.fetch("lines").filter_map { |line| line["timestamp"] }
    raise "validated timestamps were not retained" unless retained.sort == expected_timestamps.sort
    raise "message bodies were not redacted" unless evidence.fetch("lines").all? do |line|
      line["message"] == REDACTION
    end
  end
  puts "log sanitizer: all secrecy properties hold"
end

options = {}
parser = OptionParser.new do |opts|
  opts.on("--container-id ID") { |value| options[:container_id] = value }
  opts.on("--container-name NAME") { |value| options[:container_name] = value }
  opts.on("--output PATH") { |value| options[:output] = value }
  opts.on("--tail COUNT") { |value| options[:tail] = value }
  opts.on("--self-test") { options[:self_test] = true }
end

begin
  parser.parse!
  raise "unexpected arguments" unless ARGV.empty?
  options[:self_test] ? self_test : capture_logs(options)
rescue KeyError, RuntimeError, TypeError, SystemCallError, OptionParser::ParseError => error
  warn "log sanitizer error: #{error.message}"
  exit 1
end
