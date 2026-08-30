#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "optparse"
require "ipaddr"
require "rbconfig"
require "tempfile"
require "tmpdir"
require "time"
require "yaml"

FORBIDDEN_KEY = /password|secret|token|authorization|private_key|hash/i
FRESH_PHASES = %w[
  preflight deploy seed verify idempotence drift reconcile recreate persistence
  report cleanup
].freeze
PHASES = FRESH_PHASES.dup.freeze
STATUSES = %w[running passed failed].freeze
REDACTION = "[REDACTED]"
SAFE_DIAGNOSTIC = /\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/
ROOT_KEYS = %w[
  schema lane proof_platform platform_kind platform_compose_kind callback_host sandbox_id project_name beszel_port ntfy_port dozzle_port audiobookshelf_port komga_port
  jellyfin_port immich_port paperless_port radarr_port sonarr_port prowlarr_port bazarr_port sabnzbd_port
  pinchflat_port kapowarr_port bindery_port
  git_revision vault_checksum diagnostic_locations phases
].freeze
IDENTITY_KEYS = %w[git_sha platform_kind platform_compose_kind].freeze

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

def exact_keys?(value, required, optional = [])
  value.keys.sort == (required + optional.select { |key| value.key?(key) }).sort
end

def validate_deployment_manifest(manifest)
  return if manifest.nil?
  raise "deployment_manifest must be an object or null" unless manifest.is_a?(Hash)
  raise "deployment_manifest fields are invalid" unless exact_keys?(manifest, %w[identity services])
  identity = manifest["identity"]
  raise "deployment_manifest identity must be an object" unless identity.is_a?(Hash)
  raise "deployment_manifest identity fields are invalid" unless exact_keys?(identity, IDENTITY_KEYS)
  raise "deployment_manifest identity values must be strings" unless identity.values.all? { |value| value.is_a?(String) }
  services = manifest["services"]
  raise "deployment_manifest services must be an array" unless services.is_a?(Array)
  services.each do |service|
    raise "deployment_manifest services must be objects" unless service.is_a?(Hash)
    raise "deployment_manifest service fields are invalid" unless exact_keys?(service, %w[name images])
    raise "deployment_manifest service name must be a string" unless service["name"].is_a?(String)
    images = service["images"]
    raise "deployment_manifest images must be objects" unless images.is_a?(Hash)
    raise "deployment_manifest image entries must be strings" unless images.all? do |name, image|
      name.is_a?(String) && image.is_a?(String)
    end
  end
end

def validate_input(input)
  raise "input must be a JSON object" unless input.is_a?(Hash)
  input = input.dup
  identity_keys = %w[proof_platform platform_kind platform_compose_kind]
  if (input.keys & identity_keys).empty?
    input.merge!(
      "proof_platform" => "mac", "platform_kind" => "mac", "platform_compose_kind" => "mac"
    )
  end
  input["callback_host"] = "host.docker.internal" if
    !input.key?("callback_host") && input["proof_platform"] == "mac"
  raise "input contains unknown or missing root fields" unless exact_keys?(input, ROOT_KEYS, ["deployment_manifest"])
  raise "input schema must be 1" unless input["schema"] == 1
  raise "input lane must be fresh" unless input["lane"] == "fresh"
  raise "input proof_platform must be mac or integration" unless
    %w[mac integration].include?(input["proof_platform"])
  raise "input platform_kind must be mac" unless input["platform_kind"] == "mac"
  raise "input platform_compose_kind differs from proof platform" unless
    input["platform_compose_kind"] == input["proof_platform"]
  if input["proof_platform"] == "mac"
    raise "input callback_host differs from Mac proof" unless
      input["callback_host"] == "host.docker.internal"
  else
    begin
      callback = IPAddr.new(input["callback_host"])
    rescue IPAddr::InvalidAddressError, TypeError
      raise "input callback_host must be canonical IPv4"
    end
    raise "input callback_host must be canonical IPv4" unless
      callback.ipv4? && callback.to_s == input["callback_host"] &&
        input["callback_host"] != "0.0.0.0" && !callback.loopback? &&
        !IPAddr.new("224.0.0.0/4").include?(callback)
  end
  %w[sandbox_id project_name git_revision vault_checksum].each do |field|
    raise "input #{field} must be a non-empty string" unless input[field].is_a?(String) && !input[field].empty?
  end
  raise "input project_name is unsafe" unless input["project_name"].match?(/\Anas-platform-mac-[a-z0-9.-]+\z/)
  service_port_fields = %w[
    beszel_port ntfy_port dozzle_port audiobookshelf_port komga_port
    jellyfin_port immich_port paperless_port radarr_port sonarr_port prowlarr_port bazarr_port sabnzbd_port
    pinchflat_port kapowarr_port bindery_port
  ]
  service_port_fields.each do |field|
    port = input[field]
    raise "input #{field} must be an unprivileged TCP port" unless port.is_a?(Integer) && port.between?(1024, 65_535)
  end
  raise "input service ports must be distinct" unless input.values_at(*service_port_fields).uniq.length == service_port_fields.length
  diagnostics = input["diagnostic_locations"]
  raise "diagnostic_locations must be an array" unless diagnostics.is_a?(Array)
  raise "diagnostic_locations must contain safe basenames" unless diagnostics.all? do |location|
    location.is_a?(String) && location.match?(SAFE_DIAGNOSTIC)
  end
  phases = input["phases"]
  raise "input phases must be an array" unless phases.is_a?(Array)
  raise "input phase entries must be JSON objects" unless phases.all?(Hash)
  phases.each do |phase|
    raise "input phase fields are invalid" unless exact_keys?(phase, %w[name status], %w[started_at finished_at])
    lane_phases = input["lane"] == "fresh" ? FRESH_PHASES : ADOPTION_PHASES
    raise "input contains an unknown phase" unless lane_phases.include?(phase["name"])
    raise "input contains an unknown phase status" unless STATUSES.include?(phase["status"])
    %w[started_at finished_at].each do |field|
      raise "input phase timestamps must be strings" if phase.key?(field) && !phase[field].is_a?(String)
    end
    if phase["status"] == "running"
      raise "running phase must have only a start time" unless phase.key?("started_at") && !phase.key?("finished_at")
    else
      raise "completed phase must have a finish time" unless phase.key?("finished_at")
    end
  end
  raise "input contains duplicate phases" unless phases.map { |phase| phase["name"] }.uniq.length == phases.length
  validate_deployment_manifest(input["deployment_manifest"]) if input.key?("deployment_manifest")
  input
end

def validate_report(report)
  report_keys = ROOT_KEYS + %w[deployment_manifest generated_at redacted_field_count]
  raise "report contains unknown or missing root fields" unless exact_keys?(report, report_keys)
  validate_input(report.reject { |key, _value| %w[generated_at redacted_field_count].include?(key) })
  raise "report generated_at must be a string" unless report["generated_at"].is_a?(String)
  redacted_count = report["redacted_field_count"]
  raise "report redacted_field_count must be a non-negative integer" unless redacted_count.is_a?(Integer) && redacted_count >= 0

  report
end

def read_input(path)
  raise "input must be a regular file" unless File.file?(path) && !File.symlink?(path)

  validate_input(JSON.parse(File.read(path)))
rescue JSON::ParserError
  raise "input must contain valid JSON"
end

def prepare_atomic_write(path, content)
  parent = File.dirname(File.expand_path(path))
  raise "output parent must be a directory" unless File.directory?(parent) && !File.symlink?(parent)
  raise "refusing symlink output" if File.symlink?(path)
  raise "output must be a regular file or absent" if File.exist?(path) && !File.file?(path)

  file = Tempfile.new([".#{File.basename(path)}.", ".tmp"], parent)
  begin
    file.chmod(0o600)
    file.write(content)
    file.flush
    file.fsync
    file.close
    file
  rescue StandardError
    file.close!
    raise
  end
end

def atomic_write(path, content)
  file = prepare_atomic_write(path, content)
  File.rename(file.path, path)
ensure
  file&.close!
end

def atomic_json(path, content)
  atomic_write(path, JSON.pretty_generate(content) + "\n")
end

def require_distinct_paths(*paths)
  expanded = paths.map { |path| File.expand_path(path) }
  canonical = expanded.map do |path|
    [File.realpath(File.dirname(path)), File.basename(path)]
  end
  raise "input and report paths must be distinct" unless canonical.uniq.length == canonical.length
  case_folded = canonical.map { |parent, basename| [parent, basename.downcase] }
  raise "input and report paths must be distinct" unless case_folded.uniq.length == case_folded.length
  existing = expanded.select { |path| File.exist?(path) }
  existing.combination(2) do |left, right|
    raise "input and report paths must be distinct" if File.identical?(left, right)
  end
end

def markdown_cell(value)
  value.to_s.gsub("|", "\\|").gsub(/\r?\n/, " ")
end

def media_acquisition_foundation_report(report)
  verification_passed = report.fetch("phases", []).any? do |phase|
    phase["name"] == "verify" && phase["status"] == "passed"
  end
  return [] unless verification_passed

  [
    "MEDIA_ACQUISITION_FOUNDATION: network present, bridge driver, isolated project name, Jellyfin and Audiobookshelf attached to default and media-control",
    "MEDIA_ACQUISITION_STORAGE: 28 exact classified paths present",
    "MEDIA_ACQUISITION_TRANSPORTS: usenet=false torrent=false",
    "MEDIA_ACQUISITION_CONTAINERS: none declared or started"
  ]
end

def markdown_report(report)
  lines = ["# Mac platform proof report", ""]
  %w[
    lane proof_platform platform_kind platform_compose_kind callback_host sandbox_id project_name beszel_port ntfy_port dozzle_port audiobookshelf_port komga_port
    jellyfin_port immich_port paperless_port radarr_port sonarr_port prowlarr_port bazarr_port sabnzbd_port
    pinchflat_port kapowarr_port bindery_port
    git_revision vault_checksum generated_at
  ].each do |key|
    next unless report.key?(key)

    rendered_value = report[key].nil? ? "null" : markdown_cell(report[key])
    lines << "- #{key.tr('_', ' ').capitalize}: #{rendered_value}"
  end
  manifest = report["deployment_manifest"]
  identity = manifest ? manifest.fetch("identity") : {}
  lines << "- Deployment manifest: #{manifest ? 'recorded' : 'unavailable'}"
  lines << "- Manifest Git SHA: #{markdown_cell(identity['git_sha'])}" if identity["git_sha"]
  images = manifest ? manifest.fetch("services").sum { |service| service.fetch("images").length } : 0
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
    "", "## Media acquisition foundation", "",
    *media_acquisition_foundation_report(report),
    "", "## Manual review", "",
    "Complete `tests/mac/manual-review.md` against this report and its deployment manifest.", "",
    "## NAS-only evidence", "",
    "Intel GPU, ADM/networking, native NAS mounts, Tailscale, production-scale data, real Gmail consumption, external Ollama, mobile push, and complete NAS outage detection remain unproved."
  ])
  lines.join("\n") + "\n"
end

def deployment_evidence(manifest_path)
  return nil unless manifest_path
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
  require_distinct_paths(input_path, json_path, markdown_path)
  redacted = []
  input = read_input(input_path)
  if manifest_path
    input["deployment_manifest"] = deployment_evidence(manifest_path)
  else
    input["deployment_manifest"] = nil unless input.key?("deployment_manifest")
  end
  validate_input(input)
  atomic_json(input_path, input) if manifest_path
  report = sanitize(input, redacted)
  report["generated_at"] = Time.now.utc.iso8601
  report["redacted_field_count"] = redacted.length
  validate_report(report)
  json_body = JSON.pretty_generate(report) + "\n"
  markdown_body = markdown_report(report)
  original_json = File.file?(json_path) ? File.binread(json_path) : nil
  json_file = nil
  markdown_file = nil
  json_published = false
  begin
    json_file = prepare_atomic_write(json_path, json_body)
    markdown_file = prepare_atomic_write(markdown_path, markdown_body)
    File.rename(json_file.path, json_path)
    json_published = true
    File.rename(markdown_file.path, markdown_path)
  rescue StandardError
    if json_published
      original_json ? atomic_write(json_path, original_json) : File.unlink(json_path)
    end
    raise
  ensure
    json_file&.close!
    markdown_file&.close!
  end
end

def initialize_input(path, options)
  input = {
    "schema" => 1,
    "lane" => options.fetch(:lane),
    "proof_platform" => options.fetch(:proof_platform, "mac"),
    "platform_kind" => "mac",
    "platform_compose_kind" => options.fetch(:proof_platform, "mac"),
    "callback_host" => options.fetch(:callback_host, "host.docker.internal"),
    "sandbox_id" => options.fetch(:sandbox_id),
    "project_name" => options.fetch(:project_name),
    "beszel_port" => options.fetch(:beszel_port),
    "ntfy_port" => options.fetch(:ntfy_port),
    "dozzle_port" => options.fetch(:dozzle_port),
    "audiobookshelf_port" => options.fetch(:audiobookshelf_port),
    "komga_port" => options.fetch(:komga_port),
    "jellyfin_port" => options.fetch(:jellyfin_port),
    "immich_port" => options.fetch(:immich_port),
    "paperless_port" => options.fetch(:paperless_port),
    "radarr_port" => options.fetch(:radarr_port),
    "sonarr_port" => options.fetch(:sonarr_port),
    "prowlarr_port" => options.fetch(:prowlarr_port),
    "bazarr_port" => options.fetch(:bazarr_port),
    "sabnzbd_port" => options.fetch(:sabnzbd_port),
    "pinchflat_port" => options.fetch(:pinchflat_port),
    "kapowarr_port" => options.fetch(:kapowarr_port),
    "bindery_port" => options.fetch(:bindery_port),
    "git_revision" => options.fetch(:git_revision),
    "vault_checksum" => options.fetch(:vault_checksum),
    "diagnostic_locations" => [],
    "phases" => []
  }
  atomic_json(path, validate_input(input))
end

def record_diagnostic(path, location)
  raise "diagnostic location must be a safe report basename" unless location.match?(SAFE_DIAGNOSTIC)

  input = read_input(path)
  locations = input.fetch("diagnostic_locations", [])
  raise "diagnostic_locations must be an array" unless locations.is_a?(Array)

  locations << location unless locations.include?(location)
  input["diagnostic_locations"] = locations
  atomic_json(path, validate_input(input))
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
  atomic_json(path, validate_input(input))
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
    redacted = []
    sanitized = sanitize(forbidden, redacted)
    raise "forbidden keys were not redacted" unless sanitized["password"] == REDACTION
    raise "redaction count is incomplete" unless redacted.length == 6
    sanitized_body = JSON.generate(sanitized)
    %w[value-password value-secret value-token value-auth value-private value-hash].each do |value|
      raise "forbidden value reached sanitized data" if sanitized_body.include?(value)
    end

    valid_input = {
      "schema" => 1,
      "lane" => "fresh",
      "proof_platform" => "mac",
      "platform_kind" => "mac",
      "platform_compose_kind" => "mac",
      "callback_host" => "host.docker.internal",
      "sandbox_id" => "nas-platform-mac.Abc123",
      "project_name" => "nas-platform-mac-abc123",
      "beszel_port" => 38_090,
      "ntfy_port" => 32_586,
      "dozzle_port" => 38_080,
      "audiobookshelf_port" => 33_378,
      "komga_port" => 35_600,
      "jellyfin_port" => 38_096,
      "immich_port" => 32_283,
      "paperless_port" => 38_000,
      "radarr_port" => 37_878,
      "sonarr_port" => 38_989,
      "prowlarr_port" => 36_969,
      "bazarr_port" => 36_767,
      "sabnzbd_port" => 38_082,
      "pinchflat_port" => 38_945,
      "kapowarr_port" => 35_656,
      "bindery_port" => 38_787,
      "git_revision" => "abc123",
      "vault_checksum" => "0" * 64,
      "diagnostic_locations" => [],
      "phases" => []
    }
    File.write(input, JSON.generate(valid_input))
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
    parsed = JSON.parse(File.read(json))
    raise "manifest identity is missing" unless parsed.dig("deployment_manifest", "identity", "git_sha") == "abc123"
    raise "image evidence is missing" unless parsed.dig("deployment_manifest", "services", 0, "images", "app")

    File.unlink(manifest)
    write_report(input, json, markdown)
    retained = JSON.parse(File.read(json))
    unless retained.dig("deployment_manifest", "identity", "git_sha") == "abc123"
      raise "manifest evidence was lost after service-data cleanup"
    end

    nil_input = File.join(directory, "nil-input.json")
    nil_json = File.join(directory, "nil-report.json")
    nil_markdown = File.join(directory, "nil-report.md")
    File.write(nil_input, JSON.generate(valid_input.merge("deployment_manifest" => nil)))
    write_report(nil_input, nil_json, nil_markdown)
    nil_report = JSON.parse(File.read(nil_json))
    expected_report_keys = (ROOT_KEYS + %w[deployment_manifest generated_at redacted_field_count]).sort
    raise "final report root schema is not exact" unless nil_report.keys.sort == expected_report_keys
    raise "missing deployment evidence was not persisted as null" unless nil_report["deployment_manifest"].nil?
    raise "generated_at has the wrong type" unless nil_report["generated_at"].is_a?(String)
    raise "redacted_field_count has the wrong type" unless nil_report["redacted_field_count"].is_a?(Integer)
    record_phase(input, "preflight", "failed")
    record_phase(input, "preflight", "running")
    restarted = read_input(input).fetch("phases").find { |phase| phase["name"] == "preflight" }
    raise "restarted phase retained a stale finish time" if restarted.key?("finished_at")

    malformed_input = File.join(directory, "malformed.json")
    File.write(malformed_input, JSON.generate(valid_input.merge("phases" => ["not-an-object"])))
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

    original_json = "ORIGINAL JSON\n"
    original_markdown = "ORIGINAL MARKDOWN\n"
    recorded_manifest = {
      "identity" => {
        "git_sha" => "abc123",
        "platform_kind" => "mac",
        "platform_compose_kind" => "mac"
      },
      "services" => [{ "name" => "example", "images" => { "app" => "example.invalid/app@sha256:1234" } }]
    }
    malformed_inputs = {
      "diagnostic_locations string" => valid_input.merge("diagnostic_locations" => "container-state.jsonl"),
      "diagnostic_locations object" => valid_input.merge("diagnostic_locations" => [{}]),
      "diagnostic_locations path" => valid_input.merge("diagnostic_locations" => ["../raw.log"]),
      "deployment_manifest string" => valid_input.merge("deployment_manifest" => "recorded"),
      "deployment_manifest identity" => valid_input.merge("deployment_manifest" => recorded_manifest.merge("identity" => "mac")),
      "deployment_manifest services" => valid_input.merge(
        "deployment_manifest" => recorded_manifest.merge("services" => "not-an-array")
      ),
      "deployment_manifest service" => valid_input.merge(
        "deployment_manifest" => recorded_manifest.merge("services" => ["not-an-object"])
      ),
      "deployment_manifest images" => valid_input.merge(
        "deployment_manifest" => recorded_manifest.merge(
          "services" => [{ "name" => "example", "images" => "not-an-object" }]
        )
      ),
      "deployment_manifest image entry" => valid_input.merge(
        "deployment_manifest" => recorded_manifest.merge(
          "services" => [{ "name" => "example", "images" => { "app" => 123 } }]
        )
      ),
      "malformed root" => [],
      "unknown root field" => valid_input.merge("unexpected" => true),
      "root field type" => valid_input.merge("vault_checksum" => []),
      "partial proof platform identity" => valid_input.reject { |key, _value| key == "proof_platform" },
      "proof platform invalid" => valid_input.merge("proof_platform" => "linux"),
      "platform kind invalid" => valid_input.merge("platform_kind" => "nas"),
      "compose kind mismatch" => valid_input.merge("platform_compose_kind" => "integration"),
      "callback host mismatch" => valid_input.merge("callback_host" => "192.0.2.1"),
      "lane invalid" => valid_input.merge("lane" => "adoption"),
      "retired parity identity" => valid_input.merge("parity_vault_checksum" => "1" * 64),
      "retired legacy identity" => valid_input.merge("legacy_commit" => "a" * 40),
      "retired adoption phase" => valid_input.merge(
        "phases" => [{ "name" => "legacy-deploy", "status" => "failed", "finished_at" => Time.now.utc.iso8601 }]
      ),
      "phase status" => valid_input.merge("phases" => [{ "name" => "preflight", "status" => "unknown" }]),
      "phase timestamp" => valid_input.merge(
        "phases" => [{ "name" => "preflight", "status" => "failed", "finished_at" => 123 }]
      )
    }
    malformed_inputs.each do |label, malformed|
      File.write(input, JSON.generate(malformed))
      File.write(json, original_json)
      File.write(markdown, original_markdown)
      _stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, File.expand_path(__FILE__), "--input", input,
        "--json", json, "--markdown", markdown
      )
      raise "#{label} was accepted" if status.success?
      raise "#{label} emitted an uncontrolled error" unless stderr.match?(/\Areport error: [^\n]+\n\z/) &&
                                                           !stderr.match?(/\.rb:\d+:in [`']/)
      raise "#{label} replaced the existing JSON report" unless File.binread(json) == original_json
      raise "#{label} replaced the existing Markdown report" unless File.binread(markdown) == original_markdown
    end

    shared_output = File.join(directory, "shared-report")
    File.write(input, JSON.generate(valid_input))
    File.write(shared_output, original_json)
    _stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, File.expand_path(__FILE__), "--input", input,
      "--json", shared_output, "--markdown", File.join(directory, ".", "shared-report")
    )
    raise "aliased report destinations were accepted" if status.success?
    raise "aliased report destinations emitted an uncontrolled error" unless stderr.match?(/\Areport error: [^\n]+\n\z/)
    raise "aliased report destinations replaced the existing output" unless File.binread(shared_output) == original_json

    real_output_root = File.join(directory, "real-output")
    nested_output_root = File.join(real_output_root, "nested")
    aliased_output_root = File.join(directory, "aliased-output")
    Dir.mkdir(real_output_root)
    Dir.mkdir(nested_output_root)
    File.symlink(real_output_root, aliased_output_root)
    nested_json = File.join(nested_output_root, "report")
    nested_markdown = File.join(aliased_output_root, "nested", "report")
    _stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, File.expand_path(__FILE__), "--input", input,
      "--json", nested_json, "--markdown", nested_markdown
    )
    raise "nested ancestor aliases were accepted" if status.success?
    raise "nested ancestor aliases emitted an uncontrolled error" unless stderr.match?(/\Areport error: [^\n]+\n\z/)
    raise "nested ancestor aliases created an output" if File.exist?(nested_json)

    case_json = File.join(directory, "case-report")
    case_markdown = File.join(directory, "CASE-REPORT")
    _stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, File.expand_path(__FILE__), "--input", input,
      "--json", case_json, "--markdown", case_markdown
    )
    raise "case-folded report destinations were accepted" if status.success?
    raise "case-folded report destinations emitted an uncontrolled error" unless stderr.match?(/\Areport error: [^\n]+\n\z/)
    raise "case-folded report destinations created an output" if File.exist?(case_json) || File.exist?(case_markdown)

    File.write(input, JSON.generate(valid_input))
    File.write(json, original_json)
    File.write(markdown, original_markdown)
    original_rename = File.method(:rename)
    rename_count = 0
    forced_second_rename = false
    File.define_singleton_method(:rename) do |source, destination|
      rename_count += 1
      if rename_count == 2
        forced_second_rename = true
        raise Errno::EACCES, destination
      end

      original_rename.call(source, destination)
    end
    begin
      write_report(input, json, markdown)
      raise "second publication failure was accepted"
    rescue Errno::EACCES
      nil
    ensure
      File.define_singleton_method(:rename) do |source, destination|
        original_rename.call(source, destination)
      end
    end
    raise "second publication failure did not reach the second rename" unless forced_second_rename
    raise "second publication failure replaced the existing JSON report" unless File.binread(json) == original_json
    raise "second publication failure replaced the existing Markdown report" unless File.binread(markdown) == original_markdown
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
  opts.on("--proof-platform PLATFORM") { |value| options[:proof_platform] = value }
  opts.on("--callback-host HOST") { |value| options[:callback_host] = value }
  opts.on("--sandbox-id ID") { |value| options[:sandbox_id] = value }
  opts.on("--project-name NAME") { |value| options[:project_name] = value }
  opts.on("--beszel-port PORT", Integer) { |value| options[:beszel_port] = value }
  opts.on("--ntfy-port PORT", Integer) { |value| options[:ntfy_port] = value }
  opts.on("--dozzle-port PORT", Integer) { |value| options[:dozzle_port] = value }
  opts.on("--audiobookshelf-port PORT", Integer) { |value| options[:audiobookshelf_port] = value }
  opts.on("--komga-port PORT", Integer) { |value| options[:komga_port] = value }
  opts.on("--jellyfin-port PORT", Integer) { |value| options[:jellyfin_port] = value }
  opts.on("--immich-port PORT", Integer) { |value| options[:immich_port] = value }
  opts.on("--paperless-port PORT", Integer) { |value| options[:paperless_port] = value }
  opts.on("--radarr-port PORT", Integer) { |value| options[:radarr_port] = value }
  opts.on("--sonarr-port PORT", Integer) { |value| options[:sonarr_port] = value }
  opts.on("--prowlarr-port PORT", Integer) { |value| options[:prowlarr_port] = value }
  opts.on("--bazarr-port PORT", Integer) { |value| options[:bazarr_port] = value }
  opts.on("--sabnzbd-port PORT", Integer) { |value| options[:sabnzbd_port] = value }
  opts.on("--pinchflat-port PORT", Integer) { |value| options[:pinchflat_port] = value }
  opts.on("--kapowarr-port PORT", Integer) { |value| options[:kapowarr_port] = value }
  opts.on("--bindery-port PORT", Integer) { |value| options[:bindery_port] = value }
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
