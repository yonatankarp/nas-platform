#!/usr/bin/env ruby
# Mac proof-harness policy: phases, Compose isolation, failure propagation, log
# redaction and cleanup. Split out of policy_test.rb.

require "open3"
require "rbconfig"
require "set"
require "yaml"
require_relative "policy_support"

include PolicySupport
include TestScaffold

failures = []

mac_harness_files = %w[
  lib.sh run.sh cleanup.sh fixtures.sh verify.sh drift.sh run-contract.sh report.rb
  sanitize-logs.rb manual-review.md manual-validation-handoff.rb
  pin-protected-input.rb
]
mac_harness_files.each do |name|
  check(failures, File.file?(File.join(ROOT, "tests", "mac", name)),
        "Mac proof harness must provide tests/mac/#{name}")
end

mac_run_path = File.join(ROOT, "tests", "mac", "run.sh")
mac_run = File.file?(mac_run_path) ? File.read(mac_run_path) : ""
mac_phases = %w[
  preflight deploy seed verify idempotence drift reconcile recreate persistence
  report cleanup
]
mac_phases.each do |phase|
  check(failures, mac_run.match?(/(?:^|[[:space:]])#{Regexp.escape(phase)}(?:$|[[:space:]])/),
        "Mac proof harness must support the #{phase} phase")
end
%w[--lane --vault-file --vault-password-file --keep-on-failure --manual-validation --phase].each do |option|
  check(failures, mac_run.include?(option), "Mac proof harness must accept #{option}")
end

manual_handoff_path = File.join(ROOT, "tests", "mac", "manual-validation-handoff.rb")
manual_handoff = File.file?(manual_handoff_path) ? File.read(manual_handoff_path) : ""
check(failures, manual_handoff.include?('YAML.safe_load($stdin.read, aliases: false)') &&
                manual_handoff.include?("read_deployed_manifest") &&
                manual_handoff.include?('File.join(deployment_root, "current", "manifest.yml")') &&
                manual_handoff.include?('File::RDONLY | File::NOFOLLOW') &&
                manual_handoff.include?('File.realpath(current) == release_root') &&
                manual_handoff.include?('services = service_entries.map') &&
                manual_handoff.include?('services.sort == PORT_FIELDS.keys.sort') &&
                manual_handoff.include?("Shellwords.shellescape") &&
                manual_handoff.include?("Passwords remain in the encrypted vault source."),
      "Mac manual-validation handoff must derive safe identities and services from the immutable deployment")
check(failures, mac_run.include?('if [ "$manual_validation" = true ] && [ "$phase" = verify ]') &&
                mac_run.include?('preserve_sandbox_on_exit=true') &&
                mac_run.include?("emit_manual_validation_handoff || exit $?") &&
                mac_run.include?('> "$manual_vault_plaintext" 2>/dev/null || vault_view_status=$?') &&
                mac_run.include?('< "$manual_vault_plaintext" || handoff_status=$?') &&
                mac_run.include?("remove_manual_vault_plaintext"),
      "Mac manual validation must stop through the preserved-sandbox EXIT trap after verify")

# The protected-input pin is the Mac proof's trust boundary (#147): run.sh must
# call the program and not carry it, and the program must hold the source through
# a directory descriptor, or the TOCTOU property is lost silently.
pin_path = File.join(ROOT, "tests", "mac", "pin-protected-input.rb")
pin_source = File.file?(pin_path) ? File.read(pin_path) : ""
check(failures, mac_run.include?('"$mac_script_dir/pin-protected-input.rb" "$pin_source"') &&
                mac_run.include?('"$pin_kind" "$pin_external" "$mac_repo_dir" "$protected_input_root" "$pin_reuse"'),
      "Mac lifecycle must pin its protected inputs through tests/mac/pin-protected-input.rb")
check(failures, !mac_run.include?("Fiddle::Handle::DEFAULT") && !mac_run.include?("fail_pin"),
      "Mac lifecycle must not re-embed the protected-input pin as a shell heredoc")
check(failures, File.executable?(pin_path) &&
                pin_source.include?('Fiddle::Handle::DEFAULT["fchdir"]') &&
                pin_source.include?("flags = File::RDONLY | File::NOFOLLOW | File::NONBLOCK") &&
                pin_source.scan(/in_directory\(parent_directory\)/).length >= 4,
      "Mac protected-input pin must hold its source through a directory descriptor")

# The rest of #315's batch, held to the same three properties. Each program is
# resolved from the script's own directory, never the tree it inspects (#147).
mac_ports_path = File.join(ROOT, "tests", "mac", "read-integration-ports.rb")
check(failures, mac_run.include?('"$mac_script_dir/read-integration-ports.rb" ' \
                                 '"$integration_ports_file" "$mac_repo_dir"') &&
                !mac_run.include?('raise "unsafe"'),
      "Mac lifecycle must read its integration ports through tests/mac/read-integration-ports.rb")
check(failures, File.executable?(mac_ports_path),
      "tests/mac/read-integration-ports.rb must be executable")

[
  ["snapshot-immich.sh",
   ['exec "$mac_script_dir/snapshot-immich.rb" "$mode" "$snapshot_dir" </dev/null',
    'exec "$mac_script_dir/snapshot-immich-test.rb" </dev/null'],
   ["def verify_manifest", "Digest::SHA256.file"],
   %w[snapshot-immich.rb snapshot-immich-test.rb]],
  ["config-isolation.sh",
   ['"$mac_test_dir/config-isolation.rb" "$temporary_dir" </dev/null'],
   ["def assert_dozzle_aliases_and_distinct_names", "project namespaces collide"],
   %w[config-isolation.rb]],
  ["media-acquisition-foundation-hook-test.sh",
   ['cp "$repo_dir/tests/mac/media-acquisition-foundation-hook-fake-docker.rb" ' \
    '"$fixture/bin/docker"'],
   ["unsupported fake docker command", "def formatted_network"],
   %w[media-acquisition-foundation-hook-fake-docker.rb]],
  ["media-acquisition-foundation-cleanup-test.sh",
   ['cp "$repo_dir/tests/mac/media-acquisition-foundation-cleanup-fake-docker.rb"'],
   ['ENV.fetch("FAKE_DOCKER_LOG")', 'state.delete("recreate_network")'],
   %w[media-acquisition-foundation-cleanup-fake-docker.rb]]
].each do |script_name, invocations, evicted, programs|
  script_path = File.join(ROOT, "tests", "mac", script_name)
  script = File.file?(script_path) ? File.read(script_path) : ""
  check(failures, invocations.all? { |invocation| script.include?(invocation) },
        "tests/mac/#{script_name} must run its Ruby through #{programs.join(' and ')}")
  check(failures, evicted.none? { |literal| script.include?(literal) },
        "tests/mac/#{script_name} must not re-embed that Ruby as a shell heredoc")
  programs.each do |program|
    check(failures, File.executable?(File.join(ROOT, "tests", "mac", program)),
          "tests/mac/#{program} must be executable")
  end
end

mac_cleanup_path = File.join(ROOT, "tests", "mac", "cleanup.sh")
mac_cleanup = File.file?(mac_cleanup_path) ? File.read(mac_cleanup_path) : ""
mac_lib_path = File.join(ROOT, "tests", "mac", "lib.sh")
mac_lib = File.file?(mac_lib_path) ? File.read(mac_lib_path) : ""
check(failures, (mac_cleanup + mac_lib).include?("refusing to remove unowned Mac sandbox"),
      "Mac cleanup must refuse a sandbox outside its validated prefix")

verify_play_path = File.join(ROOT, "verify.yml")
check(failures, File.file?(verify_play_path), "Mac proof harness must provide verify.yml")
verify_play_data = File.file?(verify_play_path) ? YAML.safe_load_file(verify_play_path).first : {}
verification_roles = Array(verify_play_data["roles"])
# Read off the play: the playbook's own header comment names converging roles.
verification_role_names = verification_roles.map do |role|
  role.is_a?(Hash) ? role["role"] || role["name"] : role
end
verify_play_strings = task_strings(verify_play_data)
mac_verify_path = File.join(ROOT, "tests", "mac", "verify.sh")
mac_verify = File.file?(mac_verify_path) ? File.read(mac_verify_path) : ""
check(failures, mac_verify.include?('"$mac_repo_dir/verify.yml"') &&
                !mac_verify.include?('"$mac_repo_dir/site.yml"') &&
                verify_play_strings.none? do |value|
                  value.include?("community.docker.docker_compose_v2")
                end &&
                !verification_role_names.include?("deployment_bundle") &&
                !verification_role_names.include?("host_prep"),
      "Mac verification must not deploy or converge services")
check(failures, verification_roles.any? && verification_roles.all? do |role|
                  role.is_a?(Hash) && Array(role["tags"]).include?("never")
                end,
      "verify.yml roles must be inert unless an explicit verification tag is selected")
execute_phase_offset = mac_run.index("execute_phase()")
execute_phase_source = execute_phase_offset ? mac_run[execute_phase_offset..] : ""
reconcile_phase = execute_phase_source[/reconcile\)(.*?);;/m, 1].to_s
reconcile_deployment = reconcile_phase.index("run_site")
reconcile_verification = reconcile_phase.index('"$mac_script_dir/verify.sh"')
check(failures, mac_run.scan('"$mac_script_dir/verify.sh"').length >= 2 &&
                [reconcile_deployment, reconcile_verification].all? &&
                reconcile_deployment < reconcile_verification,
      "Mac lifecycle must verify after seed, drift reconciliation, and recreation")
check(failures, mac_run.include?("resume vault checksum does not match") &&
                mac_run.include?("resume Git revision does not match"),
      "Mac lifecycle must refuse mixed vault or Git evidence when resuming")
run_exit_handler = mac_run[/on_run_exit\(\) \{.*?^\}/m].to_s
check(failures, run_exit_handler.index("release_run_lock") &&
                run_exit_handler.index("Cleanup command:") &&
                run_exit_handler.index("release_run_lock") <
                  run_exit_handler.index("Cleanup command:"),
      "Mac lifecycle must include lock-release failures in cleanup-command reporting")
check(failures, mac_lib.include?("No Mac hooks registered for") &&
                !mac_lib.include?("No %s hooks are registered yet."),
      "Mac lifecycle must fail rather than pass a phase with no registered hooks")
check(failures, mac_run.include?('mktemp -d "$temporary_parent/nas-platform-mac.XXXXXX"') &&
                mac_run.include?('acquire_integration_lock "$temporary_parent"') &&
                mac_run.include?('report_root=$sandbox.reports') &&
                mac_run.include?(".nas-platform-mac-report-owned"),
      "Mac lifecycle must use a locked unique sandbox with reports outside service data")
check(failures, mac_run.include?('export PLATFORM_MEDIA_NETWORK=$project_name-media-control') &&
                mac_verify.include?("platform_verify_media_acquisition_foundation"),
      "Mac lifecycle must export and select the derived media acquisition network verifier")
# These stay literal exports in run.sh, so a literal grep is still the right
# assertion for them.
%w[
  PLATFORM_MAC_SANDBOX PLATFORM_DOCKER_ROOT PLATFORM_MEDIA_ROOT
  PLATFORM_FIXTURE_ROOT PLATFORM_REPORT_ROOT PLATFORM_PROOF_LANE
  PLATFORM_PROJECT_NAME COMPOSE_PROJECT_NAME
].each do |variable|
  check(failures, mac_run.include?("export #{variable}="),
        "Mac lifecycle must export #{variable}")
end

# Run the real port derivation over a seeded roster. The floor is the real count,
# because nothing else holds MAC_SERVICE_PORT_ORDER: some entries are containers,
# not manifest services (#512). Entries are port names, hence the underscore.
MAC_PORT_ROSTER_FLOOR = 20
mac_port_roster = mac_lib[/^MAC_SERVICE_PORT_ORDER='([^']*)'/m, 1].to_s.split
check(failures, mac_port_roster.length >= MAC_PORT_ROSTER_FLOOR &&
                mac_port_roster.uniq.length == mac_port_roster.length &&
                mac_port_roster.all? { |service| service.match?(/\A[a-z][a-z0-9_]*\z/) },
      "Mac lifecycle must declare a distinct-service port roster of at least " \
      "#{MAC_PORT_ROSTER_FLOOR} entries, found #{mac_port_roster.length}: " \
      "#{mac_port_roster.inspect}")
mac_port_probe = <<~PROBE
  set -eu
  . "$1"
  probe_index=0
  for probe_service in $MAC_SERVICE_PORT_ORDER; do
    probe_index=$((probe_index + 1))
    eval "${probe_service}_port=$((40000 + probe_index))"
  done
  mac_export_service_ports
  env | grep '^PLATFORM_[A-Z0-9_]*_PORT=' | LC_ALL=C sort
PROBE
mac_port_exports, mac_port_probe_status =
  if mac_lib.empty?
    ["", nil]
  else
    Open3.capture2e({ "PATH" => ENV.fetch("PATH", "/usr/bin:/bin"), "LC_ALL" => "C" },
                    "/bin/sh", "-c", mac_port_probe, "sh", mac_lib_path,
                    unsetenv_others: true)
  end
expected_port_exports = mac_port_roster.each_with_index.map do |service, index|
  "PLATFORM_#{service.upcase}_PORT=#{40_001 + index}"
end.sort
check(failures, !mac_lib.empty? && mac_port_probe_status.success? &&
                mac_port_exports.split("\n") == expected_port_exports,
      "Mac lifecycle must export one PLATFORM_<SERVICE>_PORT per roster service")
check(failures, mac_run.match?(/^mac_export_service_ports$/),
      "Mac lifecycle must export the roster ports it derives")

# The roster and report.rb's validated port fields must name the same services.
mac_report_path = File.join(ROOT, "tests", "mac", "report.rb")
mac_report = File.file?(mac_report_path) ? File.read(mac_report_path) : ""
mac_report_port_fields = mac_report[/service_port_fields = %w\[(.*?)\]/m, 1].to_s.split
check(failures, !mac_report_port_fields.empty? &&
                mac_report_port_fields.sort ==
                  mac_port_roster.map { |service| "#{service}_port" }.sort,
      "Mac report input must validate exactly the roster's service ports")

# The third list (#548): run.sh builds report.rb's flags from the roster, respelling
# `_` as `-`, and OptionParser rejects an undeclared flag only in a full Mac run.
mac_report_flags = mac_report.scan(/opts\.on\("(--[a-z0-9-]+-port) PORT"/).flatten
missing_report_flags = mac_port_roster.map { |service| "--#{service.tr('_', '-')}-port" } -
                       mac_report_flags
check(failures, missing_report_flags.empty?,
      "Mac report must declare one option per roster service port, missing " \
      "#{missing_report_flags.inspect}: run.sh derives these flags from the roster, so one the " \
      "parser does not know aborts the lane at its first report call")
check(failures, mac_cleanup.include?('. "$mac_repo_dir/tests/sandbox_cleanup.sh"') &&
                mac_cleanup.include?('. "$mac_repo_dir/tests/integration_lock.sh"') &&
                mac_cleanup.include?('acquire_integration_lock "$mac_cleanup_parent"') &&
                mac_cleanup.include?("release_integration_lock") &&
                mac_cleanup.include?("cleanup_sandbox_contents") &&
                (mac_cleanup + mac_lib).include?(".nas-platform-mac-owned") &&
                !(mac_cleanup + mac_lib).match?(/rm\s+-rf/),
      "Mac cleanup must reuse descriptor-safe cleanup with an owned marker")
integration_cleanup = File.read(File.join(ROOT, "tests", "sandbox_cleanup.sh"))
# The disposable lanes name every container after their project namespace, so
# the cleanup registry holds namespaced service identities and no production
# container name it could delete unconditionally.
check(failures,
      integration_cleanup.include?("cleanup_sandbox_beszel_services=") &&
        integration_cleanup.include?("beszel-agent-portable"),
      "integration cleanup must remove the portable Beszel agent")
check(failures,
      integration_cleanup.include?(%q(cleanup_sandbox_audiobookshelf_services='audiobookshelf')),
      "integration cleanup must remove Audiobookshelf")
check(failures,
      !integration_cleanup.include?("cleanup_sandbox_containers") &&
        !integration_cleanup.include?("cleanup_sandbox_networks") &&
        !integration_cleanup.match?(/beszel_agent|immich_server|paperless_webserver/),
      "integration cleanup must not register fixed production names")
check(failures, mac_run.include?('cleanup) release_run_lock && "$mac_script_dir/cleanup.sh" "$sandbox"') &&
                mac_run.scan("Cleanup command:").length == 1,
      "Mac runner must transfer the shared lock and emit cleanup commands once")
check(failures, mac_cleanup.include?('cleanup_sandbox_contents "$(dirname -- "$mac_cleanup_target")"') &&
                mac_cleanup.include?('".nas-platform-mac-owned"') &&
                !mac_cleanup.include?('rmdir -- "$mac_cleanup_target"'),
      "Mac cleanup must preserve its marker through descriptor-safe final removal")
check(failures, mac_run.include?('diagnostic_temporary=$(mktemp') &&
                mac_run.include?('mv -f -- "$diagnostic_temporary" "$report_root/$diagnostic_name" || {') &&
                mac_run.include?('unlink "$diagnostic_temporary" >/dev/null 2>&1 || true'),
      "Mac diagnostics must replace prior evidence only after successful capture")
mac_log_sanitizer_path = File.join(ROOT, "tests", "mac", "sanitize-logs.rb")
mac_log_sanitizer = if File.file?(mac_log_sanitizer_path)
                      File.read(mac_log_sanitizer_path)
                    else
                      ""
                    end
check(failures, mac_run.include?('"$mac_script_dir/sanitize-logs.rb"') &&
                mac_log_sanitizer.include?("[REDACTED]") &&
                mac_log_sanitizer.include?("--timestamps") &&
                mac_log_sanitizer.include?("docker_error"),
      "Mac failure diagnostics must capture only structurally redacted container logs")
mac_sanitizer_result = if File.file?(mac_log_sanitizer_path)
                         Open3.capture3(RbConfig.ruby, mac_log_sanitizer_path, "--self-test")
                       end
check(failures, mac_sanitizer_result && mac_sanitizer_result[2].success? &&
                mac_sanitizer_result[0] == "log sanitizer: all secrecy properties hold\n" &&
                mac_sanitizer_result[1].empty?,
      "Mac log sanitizer self-test must pass without raw values")
check(failures, mac_run.include?('IFS= read -r vault_header < "$vault_file"') &&
                !mac_run.include?("grep -q '^\\$ANSIBLE_VAULT;'"),
      "Mac lifecycle must require the Ansible Vault header on the first line")

mac_report_path = File.join(ROOT, "tests", "mac", "report.rb")
mac_report = File.file?(mac_report_path) ? File.read(mac_report_path) : ""
%w[password secret token authorization private_key hash].each do |forbidden_key|
  check(failures, mac_report.downcase.include?(forbidden_key),
        "Mac report must redact #{forbidden_key} keys")
end
check(failures, mac_report.include?("when Hash") && mac_report.include?("when Array") &&
                mac_report.include?("JSON.pretty_generate") &&
                mac_report.include?("markdown_report") &&
                mac_report.include?("deployment_manifest") &&
                mac_report.include?("diagnostic_locations"),
      "Mac reporter must recursively sanitize structured input into JSON and Markdown")
media_report_fields = mac_report.scan(/MEDIA_ACQUISITION_[A-Z]+:/)
check(failures, media_report_fields.length == 4 && media_report_fields.uniq.length == 4,
      "Mac report must contain exactly four bounded media acquisition fields")

%w[drift verify].each do |group|
  path = File.join(ROOT, "tests", "mac", "hooks", group, "15-media-acquisition-foundation.sh")
  check(failures, File.file?(path) && File.executable?(path),
        "Mac #{group} must register an executable media acquisition foundation hook")
end

# Registry-driven hooks can lose a service quietly: mac_run_hooks refuses only an
# empty group. These checks police the guards that replaced the missing-file signal.
mac_runner_path = File.join(ROOT, "tests", "mac", "run-contract.sh")
mac_runner = File.file?(mac_runner_path) ? File.read(mac_runner_path) : ""
check(failures, mac_runner.include?('mac_contract_path=$(mac_registry_contract_path "$mac_service")') &&
                mac_runner.include?('exec "$mac_repo_dir/$mac_contract_path" "$@"') &&
                !mac_runner.match?(%r{tests/contracts/\w+\.sh}),
      "Mac contract runner must resolve every contract through the registry")
check(failures, mac_runner.include?("usage: run-contract.sh SERVICE PHASE") &&
                mac_runner.include?('mac_die "Mac contract phase is invalid: $mac_phase"') &&
                mac_runner.include?(
                  'mac_die "registered service has no Mac contract environment: $mac_service"'
                ),
      "Mac contract runner must refuse an unknown service or phase rather than dispatch nothing")

# The per-service table is held to the registry statically, both ways (#500), so a
# missing arm is not first found hours into a Mac run. Arms are parsed from the
# script, and each direction guards the other's parse, so no floor is needed.
mac_contract_table = mac_runner[/^case \$mac_service in$(.*?)^esac$/m, 1].to_s
mac_contract_arms = mac_contract_table.scan(/^ {2}([a-z0-9][a-z0-9-]*)\)$/).flatten

# Deliberate gaps. A mutation row registering a contract for an armless service
# needs it exempted here too, or this check fails an expect_success row.
MAC_CONTRACT_TABLE_EXEMPTIONS = {
  "arr" => "its Phase 1 runtime is default-disabled in the Mac lane and proved by its Docker " \
           "integration suite",
  "downloaders" => "its Phase 1 runtime is default-disabled in the Mac lane and proved by its " \
                   "Docker integration suite"
}.freeze

# Held to EXPECTED_SERVICES, not the registry, which the mutation harness rewrites:
# a service deleted from the platform must not leave its exemption behind.
mac_platform_services = PolicySupport::EXPECTED_SERVICES.map { |name| contract_basename(name) }

# Fail-soft: policy_test.rb and run_contracts.rb diagnose a bad registry by name,
# and a second detector here is drift --audit refuses. run-contract.sh is ours.
mac_registry_path = File.join(ROOT, "tests", "contracts", "registry.yml")
mac_registered_aliases = begin
  document = File.file?(mac_registry_path) ? YAML.safe_load_file(mac_registry_path, aliases: false) : nil
  entries = document.is_a?(Hash) ? document["contracts"] : nil
  services = entries.is_a?(Array) ? entries.filter_map { |entry| entry["service"] if entry.is_a?(Hash) } : []
  services.grep(String).map { |service| contract_basename(service) }
rescue StandardError
  []
end

check(failures, !mac_contract_arms.empty?,
      "Mac contract runner must keep a parseable per-service environment table")
unless mac_contract_arms.empty? || mac_registered_aliases.empty?
  (mac_registered_aliases - MAC_CONTRACT_TABLE_EXEMPTIONS.keys).each do |service|
    check(failures, mac_contract_arms.include?(service),
          "Mac contract runner must give the registered service #{service} a per-service " \
          "environment arm")
  end
  mac_contract_arms.each do |service|
    check(failures, mac_registered_aliases.include?(service),
          "Mac contract runner's per-service table names #{service}, which no contract registry " \
          "entry registers")
  end
  MAC_CONTRACT_TABLE_EXEMPTIONS.each do |service, reason|
    check(failures, mac_platform_services.include?(service),
          "Mac contract table exemptions name #{service}, which is not a platform service")
    check(failures, !mac_contract_arms.include?(service),
          "Mac contract runner gives #{service} an arm, which is exempt because #{reason}")
  end
end
check(failures, mac_lib.include?("mac_assert_service_coverage()") &&
                mac_lib.include?("mac_registry_services()") &&
                mac_lib.include?("MAC_UNREGISTERED_SERVICES='vaultwarden karakeep'"),
      "Mac lifecycle must be able to hold a hook group to the contract registry")
# Drift and pre-converge hooks pin their exact roster instead of running every
# service, so a hook deleted or added outside the roster fails either way.
{
  "fixtures-seed" => "00-services.sh",
  "fixtures-persistence" => "00-services.sh",
  "fixtures-recreate" => "00-services.sh",
  "verify" => "30-services.sh",
  "drift" => "00-coverage.sh",
  "pre-converge" => "00-coverage.sh"
}.each do |group, hook|
  hook_path = File.join(ROOT, "tests", "mac", "hooks", group, hook)
  hook_source = File.file?(hook_path) ? File.read(hook_path) : ""
  check(failures, hook_source.include?("mac_assert_service_coverage #{group} #{hook} "),
        "Mac #{group} hook must account for every registered service")
end
mac_policy_runner_path = File.join(ROOT, "tests", "validate-policy.sh")
mac_policy_runner = File.file?(mac_policy_runner_path) ? File.read(mac_policy_runner_path) : ""
check(failures, mac_policy_runner.lines.map(&:strip).include?("tests/mac/hook-coverage-test.sh"),
      "validate-policy.sh must run tests/mac/hook-coverage-test.sh")
[
  "ruby tests/media_acquisition_foundation_verifier_test.rb",
  "tests/mac/media-acquisition-foundation-hook-test.sh",
  "ruby tests/mac/media-acquisition-foundation-report-test.rb",
  "tests/mac/media-acquisition-foundation-cleanup-test.sh"
].each do |command|
  check(failures, mac_policy_runner.lines.map(&:strip).include?(command),
        "validate-policy.sh must run #{command}")
end
# The Paperless restore's redis wait fixed a socket race (about 1 in 8 runs) that
# is only provable behaviourally, so the proof must stay wired in.
check(failures,
      mac_policy_runner.lines.map(&:strip).include?("tests/mac/snapshot-paperless-recovery-test.sh"),
      "validate-policy.sh must run tests/mac/snapshot-paperless-recovery-test.sh")
# The Paperless rollback drill's login throttle (429) depends on the prior run, so
# only a stub with a fixed login allowance makes it checkable.
check(failures,
      mac_policy_runner.lines.map(&:strip)
        .include?("tests/mac/snapshot-paperless-drill-throttle-test.sh"),
      "validate-policy.sh must run tests/mac/snapshot-paperless-drill-throttle-test.sh")
# The rest of the Mac gate, required here so a manifest prune cannot drop them
# with every gate still green (#315).
[
  "tests/mac/config-isolation.sh",
  "tests/mac/run-phase-status-test.sh",
  "tests/mac/dozzle-drift-hook-test.sh",
  # The only drift hook reading a diagnostic out of a no_log task (#428).
  "tests/mac/immich-drift-hook-test.sh",
  "tests/mac/integration-context-test.sh",
  "tests/mac/snapshot-paperless-context-test.sh",
  "tests/mac/snapshot-paperless.sh --self-test"
].each do |command|
  check(failures, mac_policy_runner.lines.map(&:strip).include?(command),
        "validate-policy.sh must run #{command}")
end

# The manual review lists are compared to the roster so a promotion that
# forgets the review is a red check.
MAC_REVIEW_EXEMPTIONS = {
  "arr" => "its Phase 1 runtime is default-disabled in the Mac lane and " \
           "proved by its Docker integration suite",
  "downloaders" => "its Phase 1 runtime is default-disabled in the Mac lane and " \
                   "proved by its Docker integration suite"
}.freeze

# One bullet may cover several services; the subject is the label before the
# first colon, split on list separators.
def mac_review_subjects(text, marker)
  found = marker.match(text)
  return unless found

  bullets = []
  started = false
  text[found.end(0)..].to_s.lines.each do |line|
    if line.strip.empty?
      break if started

      next
    end
    break unless line.start_with?("- ") || (started && line.match?(/\A[ \t]+\S/))

    bullets << line if line.start_with?("- ")
    started = true
  end
  bullets.filter_map do |line|
    label = line.delete_prefix("- ").sub(/\A\[[ xX]\][ \t]*/, "")
    next unless label.include?(":")

    label.split(":", 2).first
  end.flat_map { |label| label.split(/,|\band\b/) }
     .map { |name| name.strip.downcase }
     .reject(&:empty?)
end

# The shared reader counts "accepted" as deployed and is fail-soft: policy_test.rb
# owns diagnosing a bad manifest.
mac_implemented_services = implemented_services(ROOT)
# A removed service must not leave a stale exemption; skipped when the roster
# did not load, so that failure is reported once.
check(failures, (MAC_REVIEW_EXEMPTIONS.keys - mac_implemented_services).empty?,
      "Mac review exemptions must name implemented services") unless mac_implemented_services.empty?
{
  "tests/mac/manual-review.md" =>
    /^## Application checks$/,
  # Whitespace-agnostic: the sentence is wrapped prose, and a reflow must not be
  # the thing that decides whether the roster is checked.
  "docs/getting-started-mac.md" =>
    /Credential\s+continuity\s+requires\s+a\s+private\s+check\s+for\s+every\s+active\s+service:/
}.each do |relative_path, marker|
  document_path = File.join(ROOT, relative_path)
  # An absent file is reported as a missing checklist, not as a stack trace: the
  # existence of both documents is somebody else's named check.
  document = File.file?(document_path) ? File.read(document_path) : ""
  subjects = mac_review_subjects(document, marker)
  if subjects.nil?
    check(failures, false, "#{relative_path} must keep its Mac review checklist")
    next
  end
  mac_implemented_services.each do |service|
    next if MAC_REVIEW_EXEMPTIONS.key?(service)

    check(failures, subjects.include?(service),
          "#{relative_path} must give #{service} a Mac review check")
  end
  MAC_REVIEW_EXEMPTIONS.each do |service, reason|
    check(failures, !subjects.include?(service),
          "#{relative_path} lists #{service}, which is exempt because #{reason}")
  end
end

report(failures, "mac policy: all properties hold", "mac policy violation(s)")
