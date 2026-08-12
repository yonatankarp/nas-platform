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
RUBY_STARTUP_ENVIRONMENT = %w[
  RUBYOPT RUBYLIB RUBYGEMS_GEMDEPS GEM_HOME GEM_PATH
  BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLE_PATH BUNDLE_APP_CONFIG BUNDLE_WITH BUNDLE_WITHOUT
].freeze
PROBE_CONTRACT_DEPENDENCIES = {
  "audiobookshelf" => "tests/contracts/audiobookshelf.sh",
  "beszel" => "tests/contracts/beszel.sh",
  "dozzle" => "tests/contracts/dozzle.sh",
  "immich" => "tests/contracts/immich.sh",
  "jellyfin" => "tests/contracts/jellyfin.sh",
  "komga" => "tests/contracts/komga.sh",
  "paperless-ngx" => "tests/contracts/paperless.sh",
  "tinymediamanager" => "tests/contracts/tinymediamanager.sh"
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

def inject_staged_probe_mutation(path, mode, payload)
  return unless %w[persistent transient].include?(mode)

  held = "#{path}.held"
  File.rename(path, held)
  File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o700) do |file|
    file.write(payload)
    file.flush
    file.fsync
  end
  return unless mode == "transient"

  File.unlink(path)
  File.rename(held, path)
end

def with_dependency_mutation(stage)
  return yield unless ENV["PLATFORM_ADOPTION_COMPARE_DEPENDENCY_MUTATION"] == "transient"

  relative = case ENV.fetch("PLATFORM_ADOPTION_COMPARE_DEPENDENCY_TARGET", "baseline")
             when "baseline" then "tests/mac/adoption-baseline.rb"
             when "contract" then "tests/contracts/audiobookshelf.sh"
             when "helper" then "tests/contracts/legacy-fixture-paths.sh"
             else raise "dependency mutation target differs"
             end
  target = File.join(stage.path, relative)
  held = "#{target}.held"
  File.rename(target, held)
  File.write(target, ENV.fetch("PLATFORM_ADOPTION_COMPARE_DEPENDENCY_PAYLOAD"))
  File.chmod(0o700, target) if relative.end_with?(".sh")
  result = yield
  File.unlink(target)
  File.rename(held, target)
  result
ensure
  if held && File.file?(held)
    File.unlink(target) if File.exist?(target)
    File.rename(held, target)
  end
end

def open_snapshot_descriptor(path, state, max_bytes: 64 * 1024)
  signature, digest = state
  descriptor = nil
  secure_file_handle(path, trusted_root: File.dirname(path)) do |file|
    bytes = file.read(max_bytes + 1)
    raise "staged dependency differs" if bytes.bytesize > max_bytes ||
                                                Digest::SHA256.hexdigest(bytes) != digest
    descriptor = file.dup
    descriptor.rewind
  end
  raise "staged dependency differs" unless file_signature(path) == signature

  descriptor
end

def capture_staged_probe(stage, environment, probe_bytes, descriptor_options, mutate:)
  previous = File.open(".", File::RDONLY)
  expected = stage.file.stat
  result = AdoptionFileSystem.fchdir(stage.file.fileno)
  raise SystemCallError.new("fchdir", Fiddle.last_error) if result.negative?
  current = File.stat(".")
  raise "staged dependency namespace differs" unless [current.dev, current.ino] == [expected.dev, expected.ino]

  run = -> { capture(environment, "/bin/sh", "-c", probe_bytes, spawn_options: descriptor_options) }
  mutate ? with_dependency_mutation(stage, &run) : run.call
ensure
  if previous
    restored = AdoptionFileSystem.fchdir(previous.fileno)
    previous.close
    raise SystemCallError.new("fchdir", Fiddle.last_error) if restored.negative?
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
  parser.on("--snapshot-binding JSON") { |value| set_option.call(:snapshot_binding, value) }
end.parse!

output = options[:output]
checks = []
begin
  raise "arguments differ" unless ARGV.empty? &&
    %i[baseline output capabilities snapshot_binding].all? { |key| options[key] }
  self_test = ENV["PLATFORM_ADOPTION_COMPARE_SELF_TEST"] == "1"
  raise "probe root override is forbidden" if options[:probe_root] && !self_test
  source_root = File.expand_path("../..", __dir__)
  expected_probe_root = File.join(__dir__, "adoption-probes")
  requested_probe_root = options[:probe_root] || expected_probe_root
  raise "probe root differs" unless self_test || File.realpath(requested_probe_root) == File.realpath(expected_probe_root)
  snapshot_binding = parse_strict_json(options.fetch(:snapshot_binding))
  exact_keys!(snapshot_binding, %w[binding_sha256 baseline_sha256], "snapshot binding")
  snapshot_binding.each_value do |digest|
    raise "snapshot binding differs" unless digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/)
  end
  raise "snapshot marker differs" unless
    ENV.fetch("PLATFORM_ADOPTION_MARKER") == snapshot_binding.fetch("binding_sha256")
  baseline_bytes = secure_file_bytes(options.fetch(:baseline), max_bytes: 16 * 1024 * 1024, private: true)
  raise "snapshot baseline differs" unless
    Digest::SHA256.hexdigest(baseline_bytes) == snapshot_binding.fetch("baseline_sha256")
  baseline = validate_baseline(parse_strict_json(baseline_bytes))
  capability_bytes = secure_file_bytes(options.fetch(:capabilities), max_bytes: 1024 * 1024)
  reject_duplicate_json_keys!(Psych.parse(capability_bytes))
  capabilities = YAML.safe_load(capability_bytes, aliases: false)
  preserves = preserve_policy(capabilities)
  output_parent_path = File.dirname(File.expand_path(output))
  output_parent = open_bound_directory(output_parent_path)
  private_root = create_staging_directory(output_parent, output_parent_path, ".adoption-compare-private-")
  dependency_stage = nil
  _dependency_root, dependency_source_states, dependency_snapshot_states, dependency_stage =
    snapshot_probe_dependencies(source_root, private_root)
  baseline_path = File.join(dependency_stage.path, "tests/mac/adoption-baseline.rb")
  baseline_descriptor = open_snapshot_descriptor(
    baseline_path, dependency_snapshot_states.fetch(baseline_path), max_bytes: 16 * 1024 * 1024
  )
  contract_descriptors = PROBE_CONTRACT_DEPENDENCIES.to_h do |service, relative|
    path = File.join(dependency_stage.path, relative)
    [service, open_snapshot_descriptor(
      path, dependency_snapshot_states.fetch(path), max_bytes: 16 * 1024 * 1024
    )]
  end
  helper_path = File.join(dependency_stage.path, "tests/contracts/legacy-fixture-paths.sh")
  fixture_helper_descriptor = open_snapshot_descriptor(
    helper_path, dependency_snapshot_states.fetch(helper_path), max_bytes: 16 * 1024 * 1024
  )
  template_variables = {
    "PLATFORM_ADOPTION_TMM_MOVIE_TEMPLATE_CONF" =>
      "tests/mac/adoption-probes/tinymediamanager-templates/movie/template.conf",
    "PLATFORM_ADOPTION_TMM_MOVIE_LIST_JMTE" =>
      "tests/mac/adoption-probes/tinymediamanager-templates/movie/list.jmte",
    "PLATFORM_ADOPTION_TMM_TVSHOW_TEMPLATE_CONF" =>
      "tests/mac/adoption-probes/tinymediamanager-templates/tvshow/template.conf",
    "PLATFORM_ADOPTION_TMM_TVSHOW_LIST_JMTE" =>
      "tests/mac/adoption-probes/tinymediamanager-templates/tvshow/list.jmte"
  }
  template_descriptors = template_variables.to_h do |variable, relative|
    path = File.join(dependency_stage.path, relative)
    [variable, open_snapshot_descriptor(path, dependency_snapshot_states.fetch(path))]
  end
  probe_stage = create_staging_directory(private_root.file, private_root.path, "probes-")
  probe_source_digests = {}
  staged_probe_digests = {}
  SERVICES.each do |service|
    source = File.join(requested_probe_root, "#{service}.sh")
    probe, digest = snapshot_input(source, probe_stage, "#{service}.sh", executable: true)
    probe_source_digests[source] = digest
    staged_probe_digests[probe] = digest
  end
  probe_source_states = probe_source_digests.to_h do |path, digest|
    [path, [file_signature(path), digest]]
  end
  staged_probe_states = staged_probe_digests.to_h do |path, digest|
    [path, [file_signature(path), digest]]
  end
  raise "probe dependencies changed" unless snapshots_unchanged?(dependency_source_states) &&
                                              snapshots_unchanged?(dependency_snapshot_states) &&
                                              snapshots_unchanged?(probe_source_states) &&
                                              snapshots_unchanged?(staged_probe_states)

  target = SERVICES.to_h do |service|
    environment = RUBY_STARTUP_ENVIRONMENT.to_h { |name| [name, nil] }
    environment["PLATFORM_ADOPTION_PROBE_TARGET"] = "true"
    environment["PLATFORM_ADOPTION_SCRIPT_DIR"] = "tests/mac"
    environment["PLATFORM_ADOPTION_BASELINE_FILE"] = "/dev/fd/#{baseline_descriptor.fileno}"
    environment["PLATFORM_CONTRACT_REPO_DIR"] = "."
    environment["PLATFORM_LEGACY_FIXTURE_HELPER_FILE"] = "/dev/fd/#{fixture_helper_descriptor.fileno}"
    environment["PLATFORM_ADOPTION_NTFY_CONTAINER"] =
      ENV.fetch("PLATFORM_PROOF_PLATFORM", "mac") == "integration" ?
        "ntfy" : "#{ENV.fetch('PLATFORM_PROJECT_NAME')}-ntfy"
    environment["PLATFORM_ADOPTION_NTFY_ENV_FILE"] = File.join(
      ENV.fetch("PLATFORM_DOCKER_ROOT"), "nas-platform/runtime/services/ntfy/.env"
    )
    descriptor_options = template_descriptors.each_with_object({}) do |(variable, descriptor), options|
      environment[variable] = "/dev/fd/#{descriptor.fileno}"
      options[descriptor.fileno] = descriptor.fileno
    end
    descriptor_options[baseline_descriptor.fileno] = baseline_descriptor.fileno
    descriptor_options[fixture_helper_descriptor.fileno] = fixture_helper_descriptor.fileno
    if (contract_descriptor = contract_descriptors[service])
      environment["PLATFORM_ADOPTION_CONTRACT_FILE"] = "/dev/fd/#{contract_descriptor.fileno}"
      descriptor_options[contract_descriptor.fileno] = contract_descriptor.fileno
    end
    probe = File.join(probe_stage.path, "#{service}.sh")
    stage_signature = file_signature_from_stat(probe_stage.file.stat)
    probe_bytes = secure_file_bytes(probe, max_bytes: 16 * 1024 * 1024, executable: true)
    raise "staged probe differs" unless
      Digest::SHA256.hexdigest(probe_bytes) == staged_probe_states.fetch(probe).last &&
      probe_bytes.start_with?("#!/bin/sh\n") && !probe_bytes.include?("\0")
    if self_test && service == SERVICES.first
      inject_staged_probe_mutation(
        probe, ENV["PLATFORM_ADOPTION_COMPARE_STAGE_MUTATION"],
        ENV.fetch("PLATFORM_ADOPTION_COMPARE_STAGE_PAYLOAD", "#!/bin/sh\nexit 99\n")
      )
    end
    stdout, stderr = capture_staged_probe(
      dependency_stage, environment, probe_bytes, descriptor_options,
      mutate: self_test && service == SERVICES.first
    )
    raise "probe diagnostic differs" unless stderr.empty?
    raise "staged probe namespace changed" unless
      file_signature_from_stat(probe_stage.file.stat) == stage_signature &&
      snapshots_unchanged?(staged_probe_states)
    evidence = parse_strict_json(stdout)
    reject_forbidden_keys!(evidence)
    [service, validate_evidence!(service, evidence)]
  end
  raise "probe dependencies changed" unless snapshots_unchanged?(dependency_source_states) &&
                                              snapshots_unchanged?(dependency_snapshot_states) &&
                                              snapshots_unchanged?(probe_source_states) &&
                                              snapshots_unchanged?(staged_probe_states)

  SERVICES.each do |service|
    expected = baseline.fetch("services").fetch(service)
    actual = target.fetch(service)
    compare_identities!(expected, actual, preserves.fetch(service))
    checks << { "service" => service, "capability" => "identities", "passed" => true }
    compare_counts!(service, expected, actual, preserves.fetch(service))
    checks << { "service" => service, "capability" => "record-counts", "passed" => true }
    raise "fixture checksums differ" unless actual.fetch("fixture_sha256") == expected.fetch("fixture_sha256")
    checks << { "service" => service, "capability" => "fixture-checksums", "passed" => true }
    expected_settings = expected.fetch("managed_settings")
    if service == "komga"
      raise "managed settings differ" unless
        expected_settings.fetch("library_name") == "Books" &&
        expected_settings.fetch("library_root") == "/data"
      expected_settings = expected_settings.merge("library_name" => "Comics")
    end
    raise "managed settings differ" unless actual.fetch("managed_settings") == expected_settings
    checks << { "service" => service, "capability" => "managed-settings", "passed" => true }
  end
  destroy_staging_directory(probe_stage)
  probe_stage = nil
  baseline_descriptor.close
  baseline_descriptor = nil
  contract_descriptors.each_value(&:close)
  contract_descriptors = nil
  fixture_helper_descriptor.close
  fixture_helper_descriptor = nil
  template_descriptors.each_value(&:close)
  template_descriptors = nil
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
  baseline_descriptor&.close unless baseline_descriptor&.closed?
  contract_descriptors&.each_value { |descriptor| descriptor.close unless descriptor.closed? }
  fixture_helper_descriptor&.close unless fixture_helper_descriptor&.closed?
  template_descriptors&.each_value { |descriptor| descriptor.close unless descriptor.closed? }
end
