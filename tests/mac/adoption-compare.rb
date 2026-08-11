#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "yaml"
require_relative "adoption-baseline"

EXACT_COUNT_FIELDS = {
  "beszel" => %w[systems],
  "dozzle" => %w[dispatchers rules]
}.freeze

def compare_refuse(output, checks)
  begin
    publish_comparison(output, "schema" => 1, "status" => "failed", "checks" => checks)
  rescue StandardError
    nil
  end
  warn "adoption-compare-error: comparison refused"
  exit 1
end

def validate_baseline(document)
  exact_keys!(document, %w[schema legacy_commit legacy_images services], "baseline")
  raise "baseline schema differs" unless document.fetch("schema") == 1
  raise "baseline legacy commit differs" unless document.fetch("legacy_commit").is_a?(String) &&
                                                  document.fetch("legacy_commit").match?(/\A[0-9a-f]{40}\z/)
  images = document.fetch("legacy_images")
  services = document.fetch("services")
  raise "baseline service set differs" unless images.is_a?(Hash) && services.is_a?(Hash) &&
                                               images.keys.sort == SERVICES.sort && services.keys.sort == SERVICES.sort
  images.each_value do |entries|
    raise "baseline images differ" unless entries.is_a?(Array) && !entries.empty? &&
                                          entries.all? { |entry| entry.is_a?(String) && entry.bytesize.between?(1, 1024) }
  end
  services.each { |service, evidence| validate_evidence!(service, evidence) }
  document
end

def preserve_policy(capabilities)
  raise "capability matrix differs" unless capabilities.is_a?(Hash) && capabilities.keys.sort == %w[schema services] &&
                                             capabilities.fetch("schema") == 1
  entries = capabilities.fetch("services")
  raise "capability service set differs" unless entries.is_a?(Hash) && entries.keys.sort == SERVICES.sort
  entries.to_h do |service, policy|
    raise "capability policy differs" unless policy.is_a?(Hash)
    preserves = policy.fetch("preserves_unmanaged_users", false)
    raise "capability preserve policy differs" unless [true, false].include?(preserves)
    [service, preserves]
  end
end

def identity_index(evidence)
  evidence.fetch("identities").to_h do |identity|
    [canonical_identity_name(identity.fetch("name")), identity]
  end
end

def compare_identities!(baseline, target, preserves_unmanaged)
  expected = identity_index(baseline)
  actual = identity_index(target)
  raise "identity set differs" unless (expected.keys - actual.keys).empty?
  raise "identity set differs" unless preserves_unmanaged || expected.keys.sort == actual.keys.sort
  expected.each do |name, identity|
    raise "identity properties differ" unless actual.fetch(name) == identity
  end
end

def compare_counts!(service, baseline, target, preserves_unmanaged)
  baseline.fetch("record_counts").each do |field, expected|
    actual = target.fetch("record_counts").fetch(field)
    exact = EXACT_COUNT_FIELDS.fetch(service, []).include?(field) || (field == "users" && !preserves_unmanaged)
    raise "record count differs" if exact ? actual != expected : actual < expected
  end
end

def publish_comparison(path, document)
  expanded = File.expand_path(path)
  parent = File.dirname(expanded)
  basename = File.basename(expanded)
  raise "comparison output is unsafe" unless basename.match?(/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/)
  directory = open_bound_directory(parent)
  initial = publication_state_or_nil(directory, basename)
  encoded = JSON.pretty_generate(document) << "\n"
  staging_name, staging = create_publication_file(directory, ".adoption-comparison-", ".json")
  begin
    staging.write(encoded)
    staging.flush
    staging.fsync
    staged = publication_file_state_at(directory, staging_name, expected_mode: 0o600)
    raise "comparison staging changed" unless staged.last == Digest::SHA256.hexdigest(encoded)
    raise "comparison output changed" unless publication_state_or_nil(directory, basename) == initial
    raise "comparison parent changed" unless bound_directory_matches_path?(parent, directory)
    staging.close
    publish_baseline_at(staging_name, basename, directory, initial)
    staging_name = nil
  ensure
    staging&.close unless staging&.closed?
    if staging_name && publication_state_or_nil(directory, staging_name)
      native_at!(:unlink, directory, staging_name)
    end
    directory&.close
  end
end

options = {}
set_option = lambda do |key, value|
  raise OptionParser::InvalidOption, "duplicate option" if options.key?(key)
  options[key] = value
end
OptionParser.new do |parser|
  parser.on("--baseline PATH") { |value| set_option.call(:baseline, value) }
  parser.on("--output PATH") { |value| set_option.call(:output, value) }
  parser.on("--capabilities PATH") { |value| set_option.call(:capabilities, value) }
  parser.on("--probe-root PATH") { |value| set_option.call(:probe_root, value) }
end.parse!

output = options[:output]
checks = []
begin
  raise "arguments differ" unless ARGV.empty? && %i[baseline output capabilities].all? { |key| options[key] }
  self_test = ENV["PLATFORM_ADOPTION_COMPARE_SELF_TEST"] == "1"
  raise "probe root override is forbidden" if options[:probe_root] && !self_test
  source_root = File.expand_path("../..", __dir__)
  expected_probe_root = File.join(__dir__, "adoption-probes")
  requested_probe_root = options[:probe_root] || expected_probe_root
  raise "probe root differs" unless self_test || File.realpath(requested_probe_root) == File.realpath(expected_probe_root)
  baseline = validate_baseline(parse_strict_json(
    secure_file_bytes(options.fetch(:baseline), max_bytes: 16 * 1024 * 1024, private: true)
  ))
  capability_bytes = secure_file_bytes(options.fetch(:capabilities), max_bytes: 1024 * 1024)
  reject_duplicate_json_keys!(Psych.parse(capability_bytes))
  capabilities = YAML.safe_load(capability_bytes, aliases: false)
  preserves = preserve_policy(capabilities)
  output_parent_path = File.dirname(File.expand_path(output))
  output_parent = open_bound_directory(output_parent_path)
  private_root = create_staging_directory(output_parent, output_parent_path, ".adoption-compare-private-")
  dependency_stage = nil
  if self_test
    dependency_root = nil
    dependency_source_states = {}
    dependency_snapshot_states = {}
  else
    dependency_root, dependency_source_states, dependency_snapshot_states, dependency_stage =
      snapshot_probe_dependencies(source_root, private_root)
  end
  probe_stage = create_staging_directory(private_root.file, private_root.path, "probes-")
  probe_states = {}
  SERVICES.each do |service|
    source = File.join(requested_probe_root, "#{service}.sh")
    probe, digest = snapshot_input(source, probe_stage, "#{service}.sh", executable: true)
    probe_states[source] = [file_signature(source), digest]
  end
  raise "probe dependencies changed" unless snapshots_unchanged?(dependency_source_states) &&
                                              snapshots_unchanged?(dependency_snapshot_states) &&
                                              snapshots_unchanged?(probe_states)

  target = SERVICES.to_h do |service|
    environment = { "PLATFORM_ADOPTION_PROBE_TARGET" => "true" }
    environment["PLATFORM_ADOPTION_SCRIPT_DIR"] = File.join(dependency_root, "tests/mac") if dependency_root
    stdout, stderr = capture(environment, File.join(probe_stage.path, "#{service}.sh"))
    raise "probe diagnostic differs" unless stderr.empty?
    evidence = parse_strict_json(stdout)
    reject_forbidden_keys!(evidence)
    [service, validate_evidence!(service, evidence)]
  end
  raise "probe dependencies changed" unless snapshots_unchanged?(dependency_source_states) &&
                                              snapshots_unchanged?(dependency_snapshot_states) &&
                                              snapshots_unchanged?(probe_states)

  SERVICES.each do |service|
    expected = baseline.fetch("services").fetch(service)
    actual = target.fetch(service)
    compare_identities!(expected, actual, preserves.fetch(service))
    checks << { "service" => service, "capability" => "identities", "passed" => true }
    compare_counts!(service, expected, actual, preserves.fetch(service))
    checks << { "service" => service, "capability" => "record-counts", "passed" => true }
    raise "fixture checksums differ" unless actual.fetch("fixture_sha256") == expected.fetch("fixture_sha256")
    checks << { "service" => service, "capability" => "fixture-checksums", "passed" => true }
    raise "managed settings differ" unless actual.fetch("managed_settings") == expected.fetch("managed_settings")
    checks << { "service" => service, "capability" => "managed-settings", "passed" => true }
  end
  destroy_staging_directory(probe_stage)
  probe_stage = nil
  destroy_staging_directory(dependency_stage)
  dependency_stage = nil
  destroy_staging_directory(private_root)
  private_root = nil
  output_parent.close
  output_parent = nil
  publish_comparison(output, "schema" => 1, "status" => "passed", "checks" => checks)
  checks.each do |check|
    puts "adoption-compare: #{check.fetch('service')}/#{check.fetch('capability')}/pass"
  end
rescue StandardError, OptionParser::ParseError, Psych::Exception, JSON::ParserError
  compare_refuse(output, checks) if output
  warn "adoption-compare-error: comparison refused"
  exit 1
ensure
  begin
    destroy_staging_directory(probe_stage)
    destroy_staging_directory(dependency_stage)
    destroy_staging_directory(private_root)
  rescue StandardError
    nil
  end
  output_parent&.close
end
