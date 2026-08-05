#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "tempfile"
require "tmpdir"
require "time"
require "yaml"

FORBIDDEN_KEY = /password|secret|token|authorization|private_key|hash/i
PHASES = %w[
  preflight deploy seed verify idempotence drift reconcile recreate persistence
  report cleanup
].freeze
STATUSES = %w[running passed failed].freeze
REDACTION = "[REDACTED]"

def sanitize(value, redacted = [])
  case value
  when Hash
    value.each_with_object({}) do |(key, child), safe|
      if key.to_s.match?(FORBIDDEN_KEY)
        safe[key] = REDACTION
        redacted << key.to_s
      else
        safe[key] = sanitize(child, redacted)
      end
    end
  when Array
    value.map { |child| sanitize(child, redacted) }
  else
    value
  end
end

def read_input(path)
  raise "input must be a regular file" unless File.file?(path) && !File.symlink?(path)

  input = JSON.parse(File.read(path))
  raise "input must be a JSON object" unless input.is_a?(Hash)
  phases = input.fetch("phases", [])
  raise "input phases must be an array" unless phases.is_a?(Array)
  raise "input phase entries must be JSON objects" unless phases.all?(Hash)
  raise "input contains an unknown phase" unless phases.all? { |phase| PHASES.include?(phase["name"]) }
  raise "input contains an unknown phase status" unless phases.all? { |phase| STATUSES.include?(phase["status"]) }
  raise "input contains duplicate phases" unless phases.map { |phase| phase["name"] }.uniq.length == phases.length

  input
rescue JSON::ParserError
  raise "input must contain valid JSON"
end

def atomic_write(path)
  parent = File.dirname(File.expand_path(path))
  raise "output parent must be a directory" unless File.directory?(parent) && !File.symlink?(parent)
  raise "refusing symlink output" if File.symlink?(path)

  Tempfile.create([".#{File.basename(path)}.", ".tmp"], parent) do |file|
    file.chmod(0o600)
    yield file
    file.flush
    file.fsync
    File.rename(file.path, path)
  end
end

def atomic_json(path, content)
  atomic_write(path) do |file|
    file.write(JSON.pretty_generate(content))
    file.write("\n")
  end
end

def markdown_cell(value)
  value.to_s.gsub("|", "\\|").gsub(/\r?\n/, " ")
end

def markdown_report(report)
  lines = ["# Mac platform proof report", ""]
  %w[lane sandbox_id git_revision vault_checksum generated_at].each do |key|
    lines << "- #{key.tr('_', ' ').capitalize}: #{markdown_cell(report[key])}" if report.key?(key)
  end
  manifest = report.fetch("deployment_manifest", {})
  identity = manifest.fetch("identity", {})
  lines << "- Deployment manifest: #{markdown_cell(manifest['status'])}"
  lines << "- Manifest Git SHA: #{markdown_cell(identity['git_sha'])}" if identity["git_sha"]
  images = Array(manifest["services"]).sum { |service| service.fetch("images", {}).length }
  lines << "- Recorded images: #{images}"
  lines.concat(["", "## Phases", "", "| Phase | Status | Started | Finished |", "| --- | --- | --- | --- |"])
  report.fetch("phases", []).each do |phase|
    lines << "| #{markdown_cell(phase['name'])} | #{markdown_cell(phase['status'])} | " \
             "#{markdown_cell(phase['started_at'])} | #{markdown_cell(phase['finished_at'])} |"
  end
  lines.concat(["", "## Diagnostics", ""])
  diagnostics = report.fetch("diagnostic_locations", [])
  if diagnostics.empty?
    lines << "No sanitized diagnostic artifacts were captured."
  else
    diagnostics.each { |location| lines << "- #{markdown_cell(location)}" }
  end
  lines.concat([
    "", "## Manual review", "",
    "Complete `tests/mac/manual-review.md` against this report and its deployment manifest.", "",
    "## NAS-only evidence", "",
    "Intel GPU, ADM/networking, native NAS mounts, Tailscale, production-scale data, real Gmail consumption, external Ollama, mobile push, and complete NAS outage detection remain unproved."
  ])
  lines.join("\n") + "\n"
end

def deployment_evidence(manifest_path)
  return { "status" => "unavailable" } unless manifest_path
  raise "deployment manifest must be a regular file" unless File.file?(manifest_path) && !File.symlink?(manifest_path)

  manifest = YAML.safe_load_file(manifest_path)
  raise "deployment manifest must be a YAML object" unless manifest.is_a?(Hash)
  services = manifest.fetch("services", [])
  raise "deployment manifest services must be an array" unless services.is_a?(Array)
  raise "deployment manifest services must be objects" unless services.all?(Hash)
  raise "deployment manifest images must be objects" unless services.all? do |service|
    service.fetch("images", {}).is_a?(Hash)
  end

  {
    "status" => "recorded",
    "identity" => {
      "git_sha" => manifest["git_sha"],
      "platform_kind" => manifest["platform_kind"],
      "platform_compose_kind" => manifest["platform_compose_kind"]
    },
    "services" => services.map do |service|
      { "name" => service["name"], "images" => service.fetch("images", {}) }
    end
  }
end

def write_report(input_path, json_path, markdown_path, manifest_path = nil)
  redacted = []
  input = read_input(input_path)
  if manifest_path
    input["deployment_manifest"] = deployment_evidence(manifest_path)
    atomic_json(input_path, input)
  else
    input["deployment_manifest"] ||= deployment_evidence(nil)
  end
  report = sanitize(input, redacted)
  report["generated_at"] = Time.now.utc.iso8601
  report["redacted_field_count"] = redacted.length
  atomic_json(json_path, report)
  atomic_write(markdown_path) do |file|
    file.write(markdown_report(report))
  end
end

def initialize_input(path, options)
  atomic_json(path, {
    "schema" => 1,
    "lane" => options.fetch(:lane),
    "sandbox_id" => options.fetch(:sandbox_id),
    "git_revision" => options.fetch(:git_revision),
    "vault_checksum" => options.fetch(:vault_checksum),
    "diagnostic_locations" => [],
    "phases" => []
  })
end

def record_diagnostic(path, location)
  raise "diagnostic location must be a safe report basename" unless location.match?(/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/)

  input = read_input(path)
  locations = input.fetch("diagnostic_locations", [])
  raise "diagnostic_locations must be an array" unless locations.is_a?(Array)

  locations << location unless locations.include?(location)
  input["diagnostic_locations"] = locations
  atomic_json(path, input)
end

def record_phase(path, phase, status)
  raise "unknown phase" unless PHASES.include?(phase)
  raise "unknown phase status" unless STATUSES.include?(status)

  input = read_input(path)
  phases = input.fetch("phases")
  entry = phases.find { |candidate| candidate["name"] == phase }
  unless entry
    entry = { "name" => phase }
    phases << entry
  end
  now = Time.now.utc.iso8601
  entry["status"] = status
  if status == "running"
    entry["started_at"] = now
    entry.delete("finished_at")
  else
    entry["finished_at"] = now
  end
  atomic_json(path, input)
end

def self_test
  Dir.mktmpdir("nas-platform-report.") do |directory|
    input = File.join(directory, "input.json")
    json = File.join(directory, "report.json")
    markdown = File.join(directory, "report.md")
    manifest = File.join(directory, "manifest.yml")
    forbidden = {
      "password" => "value-password",
      "SecretThing" => "value-secret",
      "nested" => [{ "TOKEN" => "value-token" }, { "authorization" => "value-auth" }],
      "private_key_data" => "value-private",
      "passwordHash" => "value-hash"
    }
    File.write(input, JSON.generate({ "lane" => "fresh", "phases" => [], "details" => forbidden }))
    File.write(manifest, <<~YAML)
      ---
      git_sha: abc123
      platform_kind: mac
      platform_compose_kind: mac
      services:
        - name: example
          images:
            app: example.invalid/app@sha256:1234
    YAML
    write_report(input, json, markdown, manifest)
    outputs = File.read(json) + File.read(markdown)
    forbidden.values.grep(String).each do |value|
      raise "forbidden value reached report" if outputs.include?(value)
    end
    %w[value-token value-auth].each do |value|
      raise "nested forbidden value reached report" if outputs.include?(value)
    end
    parsed = JSON.parse(File.read(json))
    raise "forbidden keys were not redacted" unless parsed.dig("details", "password") == REDACTION
    raise "redaction count is incomplete" unless parsed.fetch("redacted_field_count") == 6
    raise "manifest identity is missing" unless parsed.dig("deployment_manifest", "identity", "git_sha") == "abc123"
    raise "image evidence is missing" unless parsed.dig("deployment_manifest", "services", 0, "images", "app")

    File.unlink(manifest)
    write_report(input, json, markdown)
    retained = JSON.parse(File.read(json))
    unless retained.dig("deployment_manifest", "identity", "git_sha") == "abc123"
      raise "manifest evidence was lost after service-data cleanup"
    end

    record_phase(input, "preflight", "failed")
    record_phase(input, "preflight", "running")
    restarted = read_input(input).fetch("phases").find { |phase| phase["name"] == "preflight" }
    raise "restarted phase retained a stale finish time" if restarted.key?("finished_at")

    malformed_input = File.join(directory, "malformed.json")
    File.write(malformed_input, JSON.generate({ "phases" => ["not-an-object"] }))
    begin
      read_input(malformed_input)
      raise "malformed phase entry was accepted"
    rescue RuntimeError => error
      raise unless error.message == "input phase entries must be JSON objects"
    end

    malformed_manifest = File.join(directory, "malformed-manifest.yml")
    File.write(malformed_manifest, "---\nservices:\n  - invalid\n")
    begin
      deployment_evidence(malformed_manifest)
      raise "malformed manifest service was accepted"
    rescue RuntimeError => error
      raise unless error.message == "deployment manifest services must be objects"
    end
  end
  puts "report: all redaction properties hold"
end

options = {}
parser = OptionParser.new do |opts|
  opts.on("--input PATH") { |value| options[:input] = value }
  opts.on("--json PATH") { |value| options[:json] = value }
  opts.on("--markdown PATH") { |value| options[:markdown] = value }
  opts.on("--init PATH") { |value| options[:init] = value }
  opts.on("--record PATH") { |value| options[:record] = value }
  opts.on("--diagnostic PATH") { |value| options[:diagnostic] = value }
  opts.on("--location BASENAME") { |value| options[:location] = value }
  opts.on("--manifest PATH") { |value| options[:manifest] = value }
  opts.on("--lane LANE") { |value| options[:lane] = value }
  opts.on("--sandbox-id ID") { |value| options[:sandbox_id] = value }
  opts.on("--git-revision SHA") { |value| options[:git_revision] = value }
  opts.on("--vault-checksum SHA256") { |value| options[:vault_checksum] = value }
  opts.on("--phase NAME") { |value| options[:phase] = value }
  opts.on("--status STATUS") { |value| options[:status] = value }
  opts.on("--self-test") { options[:self_test] = true }
end

begin
  parser.parse!
  raise "unexpected arguments" unless ARGV.empty?
  if options[:self_test]
    self_test
  elsif options[:init]
    initialize_input(options.fetch(:init), options)
  elsif options[:record]
    record_phase(options.fetch(:record), options.fetch(:phase), options.fetch(:status))
  elsif options[:diagnostic]
    record_diagnostic(options.fetch(:diagnostic), options.fetch(:location))
  else
    write_report(options.fetch(:input), options.fetch(:json), options.fetch(:markdown), options[:manifest])
  end
rescue KeyError, RuntimeError, TypeError, SystemCallError, Psych::Exception,
       OptionParser::ParseError => error
  warn "report error: #{error.message}"
  exit 1
end
