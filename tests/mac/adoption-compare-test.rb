#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "digest"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"

COMPARATOR = File.join(__dir__, "adoption-compare.rb")
comparator_source = File.binread(COMPARATOR)
raise "adoption comparator uses unavailable Ruby directory descriptor APIs" if
  comparator_source.include?("Dir.for_fd") || comparator_source.include?("Dir.fchdir")
SERVICES = %w[
  audiobookshelf beszel dozzle immich jellyfin komga ntfy paperless-ngx tinymediamanager
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
  "audiobookshelf" => %w[items libraries users], "beszel" => %w[alerts systems users],
  "dozzle" => %w[dispatchers rules users], "immich" => %w[assets users],
  "jellyfin" => %w[items libraries users], "komga" => %w[books libraries series users],
  "ntfy" => %w[access_rules users], "paperless-ngx" => %w[documents mail_accounts users],
  "tinymediamanager" => %w[movies shows]
}.freeze
FIXTURE_FIELDS = {
  "audiobookshelf" => %w[audiobook], "beszel" => [], "dozzle" => [],
  "immich" => %w[photo video], "jellyfin" => %w[video], "komga" => %w[book],
  "ntfy" => [], "paperless-ngx" => %w[document], "tinymediamanager" => %w[episode movie]
}.freeze
SETTING_FIELDS = {
  "audiobookshelf" => %w[library_name media_type], "beszel" => %w[system_name],
  "dozzle" => %w[dispatcher_name dispatcher_semantics_sha256 rules_semantics_sha256],
  "immich" => %w[database_backup machine_learning new_version_check],
  "jellyfin" => %w[library_name], "komga" => %w[library_id library_name library_root], "ntfy" => %w[topic],
  "paperless-ngx" => %w[mail_account_name], "tinymediamanager" => %w[api_enabled]
}.freeze

def evidence(service)
  identity = { "name" => "#{service}-administrator", "role" => "administrator", "enabled" => true }
  identity["permissions"] = ["managed", "read"] if IDENTITY_FIELDS.fetch(service).include?("permissions")
  {
    "identities" => [identity],
    "record_counts" => COUNT_FIELDS.fetch(service).to_h { |field| [field, 1] },
    "fixture_sha256" => FIXTURE_FIELDS.fetch(service).to_h { |field| [field, "a" * 64] },
    "managed_settings" => SETTING_FIELDS.fetch(service).to_h do |field|
      [field, field.end_with?("enabled") ? true : (field.end_with?("_sha256") ? "9" * 64 : "managed")]
    end
  }.tap do |value|
    value["managed_settings"] = {
      "library_id" => "legacy-library", "library_name" => "Books", "library_root" => "/data"
    } if service == "komga"
  end
end

def write_probe(root, service)
  path = File.join(root, "#{service}.sh")
  evidence_command = if service == "audiobookshelf"
                       "ruby -e 'print ENV.fetch(\"PLATFORM_FAKE_AUDIOBOOKSHELF_EVIDENCE\")'"
                     else
                       "printf '%s\\n' \"$PLATFORM_FAKE_#{service.upcase.tr('-', '_')}_EVIDENCE\""
                     end
  File.write(path, <<~SH)
    #!/bin/sh
    set -eu
    if [ "${PLATFORM_FAKE_EXECUTE_DEPENDENCY:-}" = true ] && [ "#{service}" = audiobookshelf ]; then
      case ${PLATFORM_FAKE_DEPENDENCY_KIND:-baseline} in
        contract) "${PLATFORM_ADOPTION_CONTRACT_FILE:-$PLATFORM_ADOPTION_SCRIPT_DIR/../contracts/audiobookshelf.sh}" \
          assert-persistence ;;
        helper) . "${PLATFORM_LEGACY_FIXTURE_HELPER_FILE:-$PLATFORM_ADOPTION_SCRIPT_DIR/../contracts/legacy-fixture-paths.sh}" ;;
      esac
      exec ruby "${PLATFORM_ADOPTION_BASELINE_FILE:-$PLATFORM_ADOPTION_SCRIPT_DIR/adoption-baseline.rb}" \
        --emit-probe audiobookshelf
    fi
    #{evidence_command}
    : > "$PLATFORM_FAKE_PROBE_LOG/#{service}"
  SH
  File.chmod(0o700, path)
end

def run_compare(root, baseline:, capabilities:, output:, evidence_by_service:, extra_env: {}, binding: nil,
                late_startup_env: {})
  binding ||= {
    "binding_sha256" => "b" * 64,
    "baseline_sha256" => Digest::SHA256.hexdigest(File.binread(baseline))
  }
  environment = {
    "PLATFORM_FAKE_PROBE_LOG" => File.join(root, "probe-log"),
    "PLATFORM_ADOPTION_COMPARE_SELF_TEST" => "1",
    "PLATFORM_ADOPTION_MARKER" => binding.fetch("binding_sha256"),
    "PLATFORM_PROJECT_NAME" => "comparison-test",
    "PLATFORM_DOCKER_ROOT" => root
  }.merge(extra_env)
  evidence_by_service.each do |service, value|
    environment["PLATFORM_FAKE_#{service.upcase.tr('-', '_')}_EVIDENCE"] = JSON.generate(value)
  end
  command = if late_startup_env.empty?
              [RbConfig.ruby, COMPARATOR]
            else
              environment["PLATFORM_FAKE_LATE_STARTUP_ENV"] = JSON.generate(late_startup_env)
              wrapper = <<~'RUBY'
                require "json"
                JSON.parse(ENV.delete("PLATFORM_FAKE_LATE_STARTUP_ENV")).each { |key, value| ENV[key] = value }
                load ARGV.shift
              RUBY
              [RbConfig.ruby, "-e", wrapper, COMPARATOR]
            end
  Open3.capture3(
    environment, *command,
    "--baseline", baseline, "--output", output,
    "--capabilities", capabilities, "--probe-root", File.join(root, "probes"),
    "--snapshot-binding", JSON.generate(binding)
  )
end

failures = []
abort "adoption comparator is absent" unless File.file?(COMPARATOR)
adoption_source = File.read(File.join(__dir__, "adoption.sh"))
runner_source = File.read(File.join(__dir__, "run.sh"))
failures << "adoption verify does not run semantic comparison" unless
  adoption_source.include?('"$script_dir/adoption-compare.rb"') &&
  adoption_source.include?("--location adoption-comparison.json")
failures << "adoption verify compares against a live replaceable baseline" unless
  adoption_source.include?('"$sandbox/snapshot/pre-cutover/baseline.json"') &&
  adoption_source.include?("baseline-binding")
failures << "adoption verify does not bind the owned report root and project" unless
  adoption_source.include?('[ "$PLATFORM_REPORT_ROOT" = "$sandbox.reports" ]') &&
  adoption_source.include?("owned report project is invalid")
failures << "verify phase does not combine exact and semantic verification" unless
  runner_source.match?(/verify\) verify_target_state ;;/)
failures << "recreate phase does not repeat semantic verification" unless
  runner_source.match?(/recreate\).*verify_target_state/)
failures << "persistence phase does not repeat semantic comparison" unless
  runner_source.match?(/run_persistence\(\).*adoption\.sh" verify/m) &&
  runner_source.match?(/persistence\) run_persistence ;;/)
Dir.mktmpdir("adoption-compare-test-") do |root|
  root = File.realpath(root)
  File.chmod(0o700, root)
  probes = File.join(root, "probes")
  FileUtils.mkdir_p(probes, mode: 0o700)
  FileUtils.mkdir_p(File.join(root, "probe-log"), mode: 0o700)
  SERVICES.each { |service| write_probe(probes, service) }

  baseline_path = File.join(root, "baseline.json")
  output = File.join(root, "comparison.json")
  capabilities_path = File.join(root, "capabilities.yml")
  baseline_services = SERVICES.to_h { |service| [service, evidence(service)] }
  target_services = Marshal.load(Marshal.dump(baseline_services))
  target_services.fetch("komga").fetch("managed_settings")["library_name"] = "Comics"
  File.write(baseline_path, JSON.generate(
    "schema" => 1, "legacy_commit" => "b" * 40,
    "legacy_images" => SERVICES.to_h { |service| [service, ["example/#{service}@sha256:#{'c' * 64}"]] },
    "services" => baseline_services
  ))
  File.chmod(0o600, baseline_path)
  File.write(capabilities_path, YAML.dump(
    "schema" => 1,
    "services" => SERVICES.to_h do |service|
      [service, service == "tinymediamanager" ? { "mode" => "single_shared_login" } :
        { "preserves_unmanaged_users" => true, "mode" => "api" }]
    end
  ))
  File.chmod(0o600, capabilities_path)

  stdout, stderr, status = run_compare(
    root, baseline: baseline_path, capabilities: capabilities_path,
    output: output, evidence_by_service: target_services
  )
  failures << "matching evidence failed: #{stderr}" unless status.success?
  expected_labels = SERVICES.flat_map do |service|
    %w[identities record-counts fixture-checksums managed-settings].map do |capability|
      "adoption-compare: #{service}/#{capability}/pass"
    end
  end
  failures << "comparison labels differ" unless stdout.lines.map(&:chomp) == expected_labels
  failures << "not every real probe path ran" unless
    Dir.children(File.join(root, "probe-log")).sort == SERVICES.sort
  if File.file?(output)
    comparison = JSON.parse(File.read(output))
    failures << "comparison schema differs" unless comparison.keys.sort == %w[checks schema status]
    failures << "comparison status differs" unless comparison["status"] == "passed"
    failures << "comparison output contains raw evidence" if
      JSON.generate(comparison).include?("audiobookshelf-administrator")
    failures << "comparison output mode differs" unless (File.stat(output).mode & 0o777) == 0o600
  else
    failures << "comparison output was not published"
  end

  cases = {
    "missing identity" => ["audiobookshelf", ->(value) { value["identities"] = [] }],
    "duplicate identity" => ["immich", ->(value) { value["identities"] << value["identities"].first.dup }],
    "privilege drift" => ["jellyfin", ->(value) { value["identities"].first["role"] = "user" }],
    "count regression" => ["komga", ->(value) { value["record_counts"]["books"] = 0 }],
    "fixture checksum drift" => ["paperless-ngx", ->(value) { value["fixture_sha256"]["document"] = "d" * 64 }],
    "Beszel duplicate system" => ["beszel", ->(value) { value["record_counts"]["systems"] = 2 }],
    "ntfy ACL drift" => ["ntfy", ->(value) { value["identities"].first["permissions"] = ["write"] }],
    "Dozzle destination drift" => ["dozzle", ->(value) { value["managed_settings"]["dispatcher_semantics_sha256"] = "e" * 64 }],
    "Dozzle rule drift" => ["dozzle", ->(value) { value["managed_settings"]["rules_semantics_sha256"] = "f" * 64 }],
    "unknown evidence" => ["beszel", ->(value) { value["unexpected"] = "sensitive-canary" }]
  }
  cases.each do |label, (service, mutation)|
    target = Marshal.load(Marshal.dump(target_services))
    mutation.call(target.fetch(service))
    stdout, stderr, status = run_compare(
      root, baseline: baseline_path, capabilities: capabilities_path,
      output: output, evidence_by_service: target
    )
    failures << "#{label} was accepted" if status.success?
    failures << "#{label} emitted raw output" unless stdout.empty?
    failures << "#{label} diagnostic differs" unless stderr == "adoption-compare-error: comparison refused\n"
    output_bytes = File.file?(output) ? File.binread(output) : ""
    failures << "#{label} leaked evidence" if (stdout + stderr + output_bytes).include?("sensitive-canary")
    if File.file?(output)
      failed_report = JSON.parse(File.read(output))
      failures << "#{label} did not record sanitized failure" unless failed_report["status"] == "failed"
    else
      failures << "#{label} did not publish sanitized failure"
    end
  end

  target = Marshal.load(Marshal.dump(target_services))
  unmanaged = target.fetch("audiobookshelf").fetch("identities").first.merge("name" => "unmanaged-user")
  target.fetch("audiobookshelf").fetch("identities") << unmanaged
  target.fetch("audiobookshelf").fetch("record_counts")["users"] += 1
  _stdout, stderr, status = run_compare(
    root, baseline: baseline_path, capabilities: capabilities_path,
    output: output, evidence_by_service: target
  )
  failures << "allowed unmanaged identity failed: #{stderr}" unless status.success?

  target = Marshal.load(Marshal.dump(target_services))
  target.fetch("tinymediamanager").fetch("identities") <<
    target.fetch("tinymediamanager").fetch("identities").first.merge("name" => "second-login")
  _stdout, _stderr, status = run_compare(
    root, baseline: baseline_path, capabilities: capabilities_path,
    output: output, evidence_by_service: target
  )
  failures << "unmanaged identity without preserve policy was accepted" if status.success?

  target = Marshal.load(Marshal.dump(target_services))
  target.fetch("immich").fetch("record_counts")["assets"] = 2
  _stdout, stderr, status = run_compare(
    root, baseline: baseline_path, capabilities: capabilities_path,
    output: output, evidence_by_service: target
  )
  failures << "additional preserved records failed: #{stderr}" unless status.success?

  target = Marshal.load(Marshal.dump(target_services))
  target.fetch("komga").fetch("identities") <<
    target.fetch("komga").fetch("identities").first.merge("name" => "ＫＯＭＧＡ-ADMINISTRATOR")
  _stdout, _stderr, status = run_compare(
    root, baseline: baseline_path, capabilities: capabilities_path,
    output: output, evidence_by_service: target
  )
  failures << "NFKC/case-folded duplicate identity was accepted" if status.success?

  {
    "Komga identifier replacement" => ["library_id", "replacement-library"],
    "Komga root replacement" => ["library_root", "/elsewhere"],
    "Komga rename omission" => ["library_name", "Books"]
  }.each do |label, (field, value)|
    target = Marshal.load(Marshal.dump(target_services))
    target.fetch("komga").fetch("managed_settings")[field] = value
    _stdout, _stderr, status = run_compare(
      root, baseline: baseline_path, capabilities: capabilities_path,
      output: output, evidence_by_service: target
    )
    failures << "#{label} was accepted" if status.success?
  end

  malformed_baselines = {
    "missing service" => JSON.parse(File.read(baseline_path)).tap { |value| value["services"].delete("ntfy") },
    "missing evidence field" => JSON.parse(File.read(baseline_path)).tap do |value|
      value["services"]["ntfy"].delete("managed_settings")
    end,
    "extra service" => JSON.parse(File.read(baseline_path)).tap { |value| value["services"]["unknown"] = evidence("ntfy") }
  }
  malformed_baselines.each do |label, malformed|
    malformed_path = File.join(root, "#{label.tr(' ', '-')}.json")
    File.write(malformed_path, JSON.generate(malformed))
    File.chmod(0o600, malformed_path)
    _stdout, _stderr, status = run_compare(
      root, baseline: malformed_path, capabilities: capabilities_path,
      output: output, evidence_by_service: target_services
    )
    failures << "#{label} baseline was accepted" if status.success?
  end

  original_probe = File.binread(File.join(probes, "ntfy.sh"))
  File.write(File.join(probes, "ntfy.sh"), original_probe.sub("set -eu\n", "set -eu\nprintf '%s\\n' 'probe-secret-canary' >&2\n"))
  File.chmod(0o700, File.join(probes, "ntfy.sh"))
  stdout, stderr, status = run_compare(
    root, baseline: baseline_path, capabilities: capabilities_path,
    output: output, evidence_by_service: target_services
  )
  failures << "probe stderr was accepted" if status.success?
  comparison_bytes = File.file?(output) ? File.binread(output) : ""
  failures << "probe stderr leaked" if (stdout + stderr + comparison_bytes).include?("probe-secret-canary")
  File.write(File.join(probes, "ntfy.sh"), original_probe)
  File.chmod(0o700, File.join(probes, "ntfy.sh"))

  symlink_output = File.join(root, "comparison-link.json")
  protected_output = File.join(root, "protected.json")
  File.write(protected_output, "protected\n")
  File.symlink(protected_output, symlink_output)
  _stdout, _stderr, status = run_compare(
    root, baseline: baseline_path, capabilities: capabilities_path,
    output: symlink_output, evidence_by_service: target_services
  )
  failures << "symlink comparison output was accepted" if status.success?
  failures << "symlink comparison output changed target" unless File.binread(protected_output) == "protected\n"

  mismatched_binding = {
    "binding_sha256" => "b" * 64, "baseline_sha256" => "0" * 64
  }
  _stdout, _stderr, status = run_compare(
    root, baseline: baseline_path, capabilities: capabilities_path,
    output: output, evidence_by_service: target_services, binding: mismatched_binding
  )
  failures << "baseline digest outside the snapshot binding was accepted" if status.success?

  startup_marker = File.join(root, "ruby-startup-injection-executed")
  startup_shim = File.join(root, "ruby-startup-injection.rb")
  File.write(startup_shim, "File.write(#{startup_marker.dump}, 'executed')\n")
  File.chmod(0o600, startup_shim)
  hostile_rubyopt = "-r#{startup_shim}"
  _stdout, _stderr, status = Open3.capture3({ "RUBYOPT" => hostile_rubyopt }, RbConfig.ruby, "-e", "")
  failures << "Ruby startup-injection fixture is ineffective" unless status.success? && File.file?(startup_marker)
  File.unlink(startup_marker) if File.file?(startup_marker)
  _stdout, stderr, status = run_compare(
    root, baseline: baseline_path, capabilities: capabilities_path,
    output: output, evidence_by_service: target_services,
    late_startup_env: { "RUBYOPT" => hostile_rubyopt }
  )
  failures << "scrubbed Ruby startup environment broke comparison: #{stderr}" unless status.success?
  failures << "probe subprocess executed hostile Ruby startup loader" if File.exist?(startup_marker)

  %w[baseline contract helper].each do |dependency_kind|
    dependency_marker = File.join(root, "hostile-#{dependency_kind}-executed")
    dependency_payload = if dependency_kind == "baseline"
                           <<~RUBY
                             File.write(#{dependency_marker.dump}, "executed")
                             puts ENV.fetch("PLATFORM_FAKE_AUDIOBOOKSHELF_EVIDENCE")
                           RUBY
                         else
                           "#!/bin/sh\nprintf executed > #{dependency_marker.dump}\nexit 0\n"
                         end
    _stdout, _stderr, status = run_compare(
      root, baseline: baseline_path, capabilities: capabilities_path,
      output: output, evidence_by_service: target_services,
      extra_env: {
        "PLATFORM_FAKE_EXECUTE_DEPENDENCY" => "true",
        "PLATFORM_FAKE_DEPENDENCY_KIND" => dependency_kind,
        "PLATFORM_ADOPTION_COMPARE_DEPENDENCY_MUTATION" => "transient",
        "PLATFORM_ADOPTION_COMPARE_DEPENDENCY_TARGET" => dependency_kind,
        "PLATFORM_ADOPTION_COMPARE_DEPENDENCY_PAYLOAD" => dependency_payload
      }
    )
    failures << "transient #{dependency_kind} replacement was accepted" if status.success?
    failures << "transient #{dependency_kind} replacement executed" if File.exist?(dependency_marker)
  end

  hostile_marker = File.join(root, "hostile-probe-executed")
  hostile_script = "printf hostile > '#{hostile_marker}'\n"
  %w[persistent transient].each do |mutation|
    _stdout, stderr, status = run_compare(
      root, baseline: baseline_path, capabilities: capabilities_path,
      output: output, evidence_by_service: target_services,
      extra_env: {
        "PLATFORM_ADOPTION_COMPARE_STAGE_MUTATION" => mutation,
        "PLATFORM_ADOPTION_COMPARE_STAGE_PAYLOAD" => hostile_script
      }
    )
    failures << "#{mutation} staged probe replacement was accepted" if status.success?
    failures << "#{mutation} staged probe diagnostic differs" unless
      stderr == "adoption-compare-error: comparison refused\n"
    failures << "#{mutation} staged replacement executed" if File.exist?(hostile_marker)
  end
end

abort failures.join("\n") unless failures.empty?
puts "adoption comparison tests: passed"
