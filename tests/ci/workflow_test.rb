#!/usr/bin/env ruby

require "yaml"

WORKFLOW_PATH = File.expand_path("../../.github/workflows/ci.yml", __dir__)
POLICY_PATH = File.expand_path("../validate-policy.sh", __dir__)
ANSIBLE_LINT_PATH = File.expand_path("../../.ansible-lint", __dir__)
CHECKOUT_ACTION = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
UPLOAD_ARTIFACT_ACTION = "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"
SELECTABLE_JOBS = %w[
  static foundation smoke beszel dozzle audiobookshelf media paperless idempotence_check
].freeze
INTEGRATION_SUITES = {
  "foundation" => "foundation",
  "smoke" => "smoke",
  "beszel" => "beszel",
  "dozzle" => "dozzle",
  "audiobookshelf" => "audiobookshelf",
  "media" => "media",
  "paperless" => "paperless",
  "idempotence_check" => "idempotence-check"
}.freeze
CLASSIFIER_OUTPUTS = %w[
  run_ci static foundation smoke beszel dozzle audiobookshelf media paperless
  idempotence_check selected_tags
].freeze

failures = []

def check(failures, condition, message)
  failures << message unless condition
end

ansible_lint = YAML.safe_load_file(ANSIBLE_LINT_PATH)
ansible_lint_excludes = Array(ansible_lint["exclude_paths"])
check(failures,
      %w[services/ tests/mac/legacy-overrides/].all? { |path| ansible_lint_excludes.include?(path) },
      "ansible-lint must exclude Docker Compose definitions with custom loader tags")

def expression(value)
  value.to_s.gsub(/\s+/, " ").strip
end

def run_steps(job)
  Array(job["steps"]).filter_map { |step| step["run"] }.join("\n")
end

def normalize_shell(source)
  source.to_s.lines.map(&:strip).reject(&:empty?).join("\n")
end

def integration_commands(source)
  normalize_shell(source).lines(chomp: true).grep(%r{\Atests/integration\.sh(?:\s|\z)})
end

def registers_command_once?(source, command)
  normalize_shell(source).lines(chomp: true).count(command) == 1
end

def exact_fixed_integration_command?(source, suite)
  expected = "tests/integration.sh --suite #{suite} site.yml"
  normalize_shell(source) == expected && integration_commands(source) == [expected]
end

def exact_selectable_integration_branches?(source, suite)
  tagged = %(tests/integration.sh --suite #{suite} --tags "$SELECTED_TAGS" site.yml)
  untagged = "tests/integration.sh --suite #{suite} site.yml"
  expected = <<~SHELL
    if [ -n "$SELECTED_TAGS" ]; then
      #{tagged}
    else
      #{untagged}
    fi
  SHELL
  normalize_shell(source) == normalize_shell(expected) &&
    integration_commands(source) == [tagged, untagged]
end

workflow = YAML.safe_load_file(WORKFLOW_PATH, aliases: false)
# Psych follows YAML 1.1 here and may deserialize the plain `on` key as true.
triggers = workflow["on"] || workflow[true]
jobs = workflow.fetch("jobs", {})

check(failures, triggers.is_a?(Hash), "workflow triggers are missing")
if triggers.is_a?(Hash)
  check(failures, triggers.key?("pull_request"), "pull_request trigger is missing")
  check(failures, triggers.dig("push", "branches") == ["main"], "push must target only main")
  check(failures, triggers.dig("schedule", 0, "cron") == "23 3 * * *", "nightly schedule is incorrect")
  check(failures, triggers.key?("workflow_dispatch"), "workflow_dispatch trigger is missing")
end

concurrency = workflow.fetch("concurrency", {})
check(
  failures,
  expression(concurrency["group"]) ==
    'ci-${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}',
  "concurrency group must use PR number with a ref fallback"
)
check(failures, concurrency["cancel-in-progress"] == true, "concurrency cancellation must be enabled")
check(failures, workflow.dig("permissions", "contents") == "read", "contents permission must be read-only")

expected_jobs = ["changes", *SELECTABLE_JOBS, "validate"]
check(failures, jobs.keys.sort == expected_jobs.sort,
      "workflow jobs differ: got #{jobs.keys.sort.inspect}, expected #{expected_jobs.sort.inspect}")

changes = jobs.fetch("changes", {})
check(failures, changes["runs-on"] == "ubuntu-latest", "changes must run on ubuntu-latest")
check(failures, changes.fetch("outputs", {}).keys.sort == CLASSIFIER_OUTPUTS.sort,
      "changes must expose every classifier output")
CLASSIFIER_OUTPUTS.each do |output|
  check(failures,
        expression(changes.dig("outputs", output)) == "${{ steps.classify.outputs.#{output} }}",
        "changes output #{output} must come from the classify step")
end

changes_steps = Array(changes["steps"])
changes_checkout = changes_steps.find { |step| step["uses"]&.start_with?("actions/checkout@") }
check(failures, changes_checkout&.fetch("uses", nil) == CHECKOUT_ACTION,
      "changes checkout must use the repository's pinned action")
check(failures, changes_checkout&.dig("with", "fetch-depth") == 0,
      "changes checkout must fetch full history")
classify = changes_steps.find { |step| step["id"] == "classify" } || {}
check(failures, classify.dig("env", "EVENT_NAME") == "${{ github.event_name }}",
      "classifier must receive the event name through env")
check(failures, classify.dig("env", "PR_BASE") == "${{ github.event.pull_request.base.sha }}",
      "classifier must receive the PR base SHA through env")
check(failures, classify.dig("env", "PR_HEAD") == "${{ github.event.pull_request.head.sha }}",
      "classifier must receive the PR head SHA through env")
classifier_run = classify["run"].to_s
check(failures, classifier_run.include?('[ "$EVENT_NAME" = pull_request ]'),
      "classifier must branch only for pull_request")
check(failures, classifier_run.include?('BASE=$PR_BASE') && classifier_run.include?('HEAD=$PR_HEAD'),
      "classifier must set BASE and HEAD only inside the pull_request branch")
check(failures,
      classifier_run.include?('ruby tests/ci/classify_changes.rb --diff "$BASE" "$HEAD" --github-output "$GITHUB_OUTPUT"'),
      "pull requests must classify the base/head diff safely")
check(failures,
      classifier_run.include?('ruby tests/ci/classify_changes.rb --full --github-output "$GITHUB_OUTPUT"'),
      "non-PR events must request a full run")
check(failures, !classifier_run.include?("github.event.pull_request"),
      "event payload expressions must not be interpolated into shell source")

SELECTABLE_JOBS.each do |job_id|
  job = jobs.fetch(job_id, {})
  check(failures, job["needs"] == "changes", "#{job_id} must depend only on changes")
  expected_if = "${{ needs.changes.outputs.#{job_id} == 'true' }}"
  check(failures, expression(job["if"]) == expected_if,
        "#{job_id} condition must match its classifier output")
end

INTEGRATION_SUITES.each do |job_id, suite|
  job = jobs.fetch(job_id, {})
  checkout = Array(job["steps"]).find { |step| step["uses"]&.start_with?("actions/checkout@") }
  check(failures, checkout&.fetch("uses", nil) == CHECKOUT_ACTION,
        "#{job_id} must check out the repository with the pinned action")
  integration_steps = Array(job["steps"]).select do |step|
    step["run"]&.include?("tests/integration.sh")
  end
  check(failures, integration_steps.length == 1,
        "#{job_id} must have exactly one integration harness step")
  next if %w[smoke idempotence_check].include?(job_id)

  check(failures, exact_fixed_integration_command?(integration_steps.first&.fetch("run", nil), suite),
        "#{job_id} must invoke exactly tests/integration.sh --suite #{suite} site.yml")
end

%w[smoke idempotence_check].each do |job_id|
  job = jobs.fetch(job_id, {})
  integration_step = Array(job["steps"]).find { |step| step["run"]&.include?("tests/integration.sh") } || {}
  check(failures, integration_step.dig("env", "SELECTED_TAGS") ==
                  "${{ needs.changes.outputs.selected_tags }}",
        "#{job_id} must pass selected tags through the environment")
  suite = INTEGRATION_SUITES.fetch(job_id)
  check(failures, exact_selectable_integration_branches?(integration_step["run"], suite),
        "#{job_id} must use exact tagged and untagged integration branches")
  check(failures, !integration_step["run"].to_s.match?(/\beval\b/), "#{job_id} must not use eval")
end

# Mutation counterexamples keep the exact-match helpers from regressing to
# fragment checks that accept additional invocations or tags in the empty path.
check(failures,
      !exact_fixed_integration_command?(<<~SHELL, "foundation"),
        tests/integration.sh --suite foundation site.yml
        tests/integration.sh --suite smoke site.yml
      SHELL
      "fixed-suite matcher must reject an extra integration invocation")
check(failures,
      !exact_fixed_integration_command?("tests/integration.sh --suite smoke site.yml", "foundation"),
      "fixed-suite matcher must reject the wrong suite")
check(failures,
      !exact_selectable_integration_branches?(<<~SHELL, "smoke"),
        if [ -n "$SELECTED_TAGS" ]; then
          tests/integration.sh --suite smoke --tags "$SELECTED_TAGS" site.yml
        else
          tests/integration.sh --suite smoke --tags "$SELECTED_TAGS" site.yml
        fi
      SHELL
      "selectable-suite matcher must reject --tags in the empty branch")

static_commands = run_steps(jobs.fetch("static", {}))
[
  "find tests -type f -name '*.sh' -exec sh -n {} +",
  "tests/validate-policy.sh",
  "tests/integration_cleanup_test.sh",
  "tests/immich_probe_status_test.py",
  "tests/generate-secrets-redaction-test.sh",
  "tests/generate-ephemeral-vault.sh --self-test",
  "ansible-lint --strict",
  "ansible-playbook -i inventory/local.yml site.yml --syntax-check",
  "ansible-playbook generate-secrets.yml --syntax-check"
].each do |command|
  check(failures, static_commands.include?(command), "static checks must retain #{command.inspect}")
end
check(failures, static_commands.include?("apt-get install"), "static checks must install system tools")
check(failures, static_commands.include?('python3 -m venv "$RUNNER_TEMP/ansible"'),
      "static checks must create an isolated Ansible environment")
check(failures, static_commands.include?(
        '"$RUNNER_TEMP/ansible/bin/pip" install \'ansible-core==2.21.2\' \'ansible-lint==26.6.0\''
      ), "static checks must install exact Ansible pins in the isolated environment")
check(failures, static_commands.include?('echo "$RUNNER_TEMP/ansible/bin" >> "$GITHUB_PATH"'),
      "static checks must expose only the isolated pinned Ansible tools")
check(failures, static_commands.include?(
        '"$RUNNER_TEMP/ansible/bin/ansible-galaxy" collection install -r requirements.yml'
      ), "static checks must install collections with the isolated pinned Ansible tools")
check(failures, !static_commands.include?("python3 tests/deployment_target_validator_test.py"),
      "static must not duplicate the deployment validator already run by validate-policy.sh")

policy_source = File.read(POLICY_PATH)
%w[
  ruby\ tests/beszel_telemetry_probe_test.rb
  ruby\ tests/beszel_telemetry_timeout_test.rb
  ruby\ tests/beszel_telemetry_ansible_test.rb
  python3\ tests/beszel_telemetry_module_test.py
  tests/mac/beszel-telemetry-hook-test.sh
  ruby\ tests/paperless_mail_reconciliation_test.rb
].each do |command|
  normalized = command.gsub("\\ ", " ")
  check(failures, registers_command_once?(policy_source, normalized),
        "policy validation must invoke exactly once #{normalized.inspect}")
end
validator_command = "python3 tests/deployment_target_validator_test.py"
policy_source = File.read(POLICY_PATH)
check(failures, registers_command_once?(policy_source, validator_command),
      "validate-policy.sh must register the deployment validator exactly once")
check(failures, !registers_command_once?("#{validator_command}\n#{validator_command}\n", validator_command),
      "policy registration matcher must reject duplicate validator commands")
check(failures, !registers_command_once?("ruby tests/policy_test.rb\n", validator_command),
      "policy registration matcher must reject a missing validator command")
paperless_mail_command = "ruby tests/paperless_mail_reconciliation_test.rb"
check(failures, registers_command_once?(policy_source, paperless_mail_command),
      "validate-policy.sh must register the Paperless mail reconciliation fixture exactly once")
check(failures,
      !registers_command_once?("#{paperless_mail_command}\n#{paperless_mail_command}\n", paperless_mail_command),
      "policy registration matcher must reject duplicate Paperless mail fixture commands")

validate = jobs.fetch("validate", {})
check(failures, validate["name"] == "validate", "aggregate check name must remain validate")
check(failures, expression(validate["if"]) == "${{ always() }}", "validate must always run")
expected_needs = ["changes", *SELECTABLE_JOBS]
check(failures, Array(validate["needs"]) == expected_needs,
      "validate must need changes and every selectable job in canonical order")
validate_checkout = Array(validate["steps"]).find { |step| step["uses"]&.start_with?("actions/checkout@") }
check(failures, validate_checkout&.fetch("uses", nil) == CHECKOUT_ACTION,
      "validate must check out the repository with the pinned action")
validate_commands = run_steps(validate)
expected_needs.each do |job_id|
  check(failures,
        validate_commands.include?(%(#{job_id}="${{ needs.#{job_id}.result }}")),
        "validate must pass the #{job_id} result to validate_results.rb")
end
check(failures, validate_commands.include?("ruby tests/ci/validate_results.rb"),
      "validate must invoke the aggregate result validator")

workflow_source = File.read(WORKFLOW_PATH)
check(failures, !workflow_source.match?(/dorny\/paths-filter|paths-filter@/i),
      "workflow must not use a third-party path filter action")
all_uses = jobs.values.flat_map do |job|
  Array(job["steps"]).filter_map { |step| step["uses"] }
end
allowed_actions = [CHECKOUT_ACTION, UPLOAD_ARTIFACT_ACTION]
check(failures, all_uses.all? { |uses| allowed_actions.include?(uses) },
      "every action use must be an approved pinned action: #{all_uses.inspect}")

unless failures.empty?
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} workflow contract failure(s)"
end

puts "CI workflow contract: all checks passed"
