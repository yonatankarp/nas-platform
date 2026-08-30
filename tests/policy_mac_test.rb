#!/usr/bin/env ruby
# Mac proof-harness policy.
#
# The Mac lane is an orchestration contract: each service plugs its fixture, drift
# and verification behaviour into stable phases, and the runner must isolate every
# Compose project, propagate failures, redact its logs and clean up after itself.
# Split out of policy_test.rb: these checks police tests/mac/ and change with it.

require "open3"
require "rbconfig"
require "set"
require "yaml"
require_relative "policy_support"

include PolicySupport
include TestScaffold

failures = []

# The Mac proof harness is an orchestration contract: each service plugs its
# fixture, drift, and verification behavior into these stable phases.
mac_harness_files = %w[
  lib.sh run.sh cleanup.sh fixtures.sh verify.sh drift.sh run-contract.sh report.rb
  sanitize-logs.rb manual-review.md manual-validation-handoff.rb
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
# What verify.yml runs, read off the play. The three negatives used to be matched
# against the file's text, where a comment naming a converging role — the header
# of this very playbook names them — is indistinguishable from running one.
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

# The service ports are no longer literal exports: run.sh derives them from
# MAC_SERVICE_PORT_ORDER through mac_export_service_ports. Grepping for eleven
# literal `export PLATFORM_<SERVICE>_PORT=` strings is not available any more,
# and it was never the stronger check: it pinned ten of the fifteen services --
# Komga, Jellyfin, Immich, Pinchflat and Kapowarr were never named -- and it
# proved only that the text existed, never that a port reached the variable.
# Running the real derivation over a seeded roster proves both, for all fifteen.
mac_port_roster = mac_lib[/^MAC_SERVICE_PORT_ORDER='([^']*)'/m, 1].to_s.split
check(failures, mac_port_roster.length >= 15 &&
                mac_port_roster.uniq.length == mac_port_roster.length &&
                mac_port_roster.all? { |service| service.match?(/\A[a-z][a-z0-9]*\z/) },
      "Mac lifecycle must declare a distinct-service port roster")
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
  Open3.capture2e({}, "/bin/sh", "-c", mac_port_probe, "sh", mac_lib_path, unsetenv_others: true)
expected_port_exports = mac_port_roster.each_with_index.map do |service, index|
  "PLATFORM_#{service.upcase}_PORT=#{40_001 + index}"
end.sort
check(failures, mac_port_probe_status.success? &&
                mac_port_exports.split("\n") == expected_port_exports,
      "Mac lifecycle must export one PLATFORM_<SERVICE>_PORT per roster service")
check(failures, mac_run.match?(/^mac_export_service_ports$/),
      "Mac lifecycle must export the roster ports it derives")

# The roster and report.rb's validated port fields are two lists that must name
# the same services. Nothing else notices a service added to one and not the
# other until a full Mac run fails on an unrecognised option.
mac_report_path = File.join(ROOT, "tests", "mac", "report.rb")
mac_report = File.file?(mac_report_path) ? File.read(mac_report_path) : ""
mac_report_port_fields = mac_report[/service_port_fields = %w\[(.*?)\]/m, 1].to_s.split
check(failures, !mac_report_port_fields.empty? &&
                mac_report_port_fields.sort ==
                  mac_port_roster.map { |service| "#{service}_port" }.sort,
      "Mac report input must validate exactly the roster's service ports")
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

# The Mac contract wrapper and four of the five hook groups were one file per
# service until they were driven from tests/contracts/registry.yml. What that
# collapse can lose is a whole suite, quietly: mac_run_hooks refuses a group with
# no hook files at all, not a group whose single hook forgot a service. These
# checks police the guards that replaced the missing-file signal.
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
check(failures, mac_lib.include?("mac_assert_service_coverage()") &&
                mac_lib.include?("mac_registry_services()") &&
                mac_lib.include?("MAC_UNREGISTERED_SERVICES='ntfy'"),
      "Mac lifecycle must be able to hold a hook group to the contract registry")
{
  "fixtures-seed" => "00-services.sh",
  "fixtures-persistence" => "00-services.sh",
  "fixtures-recreate" => "00-services.sh",
  "verify" => "30-services.sh"
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
# The Paperless restore recovery path used to start redis and flush the valkey
# queue in one breath, which raced the socket and failed a clean restore about
# once in eight CI runs. The wait that fixes it is only provable behaviourally,
# so the proof has to stay wired in: a race that is no longer exercised is a
# race that comes back without any check going red.
check(failures,
      mac_policy_runner.lines.map(&:strip).include?("tests/mac/snapshot-paperless-recovery-test.sh"),
      "validate-policy.sh must run tests/mac/snapshot-paperless-recovery-test.sh")
# The Paperless rollback drill used to log in on every pass of the poll that waits
# for its deletion to settle, which is about sixty logins against an endpoint
# Paperless throttles, and it failed the suite on a 429 rather than on anything
# about the restore. Whether the throttle is reached depends on what the run
# before it spent, so the same code passes cold and fails warm; only a stub with a
# fixed login allowance turns that into something a check can see.
check(failures,
      mac_policy_runner.lines.map(&:strip)
        .include?("tests/mac/snapshot-paperless-drill-throttle-test.sh"),
      "validate-policy.sh must run tests/mac/snapshot-paperless-drill-throttle-test.sh")

# The manual review is where a human exercises the credentials nothing automated
# can hold: a sign-in with the deployed identity, and the refusal of anything
# else. Both lists were maintained by hand, and both silently fell behind the
# roster -- Pinchflat and Kapowarr deployed, got sandbox ports and were verified
# for two phases with no review entry at all, and the omission was invisible
# because nothing compared the lists to the manifest. Compare them here, the way
# tests/mac/hooks/verify/30-services.sh compares its dispatch table, so a
# promotion that forgets the review is a red check rather than a gap discovered
# later.
MAC_REVIEW_EXEMPTIONS = {
  "arr" => "its Phase 1 runtime is default-disabled in the Mac lane and " \
           "proved by its Docker integration suite",
  "downloaders" => "its Phase 1 runtime is default-disabled in the Mac lane and " \
                   "proved by its Docker integration suite"
}.freeze

# One bullet may cover several services -- "Audiobookshelf, Jellyfin, and Komga"
# is one check with one procedure -- so the subject is the label before the first
# colon, split on the separators a reader already reads as a list.
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

# Read the roster through the shared reader rather than parsing the manifest a
# second time: a second copy is a copy no test says must agree with the first,
# and it would miss "accepted", which counts as deployed. The reader is fail-soft
# by design -- policy_test.rb owns the diagnosis of a missing, malformed or
# heterogeneous manifest, and raising here would replace its named failure with a
# stack trace from this script, which tests/policy_manifest_test.rb refuses.
mac_implemented_services = implemented_services(ROOT)
# A stale exemption is the same defect one step later: a service removed from the
# roster must not leave behind a standing excuse for the next one to inherit.
# Skipped when the roster did not load, so an unreadable manifest is reported
# once, by the check that owns it, rather than echoed here as a second cause.
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
