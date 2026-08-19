#!/usr/bin/env ruby

require "fileutils"
require "open3"
require "tmpdir"
require "yaml"
require_relative "classify_changes"

WORKFLOW_PATH = File.expand_path("../../.github/workflows/ci.yml", __dir__)
POLICY_PATH = File.expand_path("../validate-policy.sh", __dir__)
ANSIBLE_LINT_PATH = File.expand_path("../../.ansible-lint", __dir__)
CHECKOUT_ACTION = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
UPLOAD_ARTIFACT_ACTION = "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"
EXPECTED_JOBS = %w[changes static suites validate].freeze
# The suites the matrix dispatches, in the order a full run enumerates them.
INTEGRATION_SUITES = %w[
  foundation smoke beszel dozzle audiobookshelf media paperless idempotence-check
].freeze
TAGGED_SUITES = %w[smoke idempotence-check].freeze
CLASSIFIER_OUTPUTS = %w[static suites selected_tags].freeze
SAMPLE_TAGS = "host_prep,deployment_bundle,ntfy,beszel"
STATIC_STEP_NAMES = [
  "Check out repository",
  "Validate shell syntax",
  "Install Ansible tooling",
  "Check policy properties",
  "Check integration sandbox cleanup",
  "Check Immich probe status rendering",
  "Check generated credential redaction",
  "Check silent ephemeral vault generation",
  "Lint Ansible",
  "Check playbook syntax"
].freeze
RETIRED_MIGRATION_MARKERS = %w[
  nas-infrastructure
  tests/adoption-integration.sh
  adoption-render-test.sh
  legacy-seed-test.sh
  portainer
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

def contains_path_filter?(value)
  case value
  when Hash
    value.any? { |key, child| %w[paths paths-ignore].include?(key.to_s) || contains_path_filter?(child) }
  when Array
    value.any? { |child| contains_path_filter?(child) }
  else
    false
  end
end

def declared_content(jobs)
  jobs.flat_map do |job_id, job|
    [job_id, job["name"], expression(job["if"]),
     *Array(job["steps"]).flat_map { |step| [step["name"], step["uses"], step["run"]] }]
  end.join("\n").downcase
end

def registers_command_once?(source, command)
  normalize_shell(source).lines(chomp: true).count(command) == 1
end

# Runs the matrix step's own shell against a stub harness that echoes its
# arguments, so the tags contract is proven by the argv a suite would receive
# rather than by the step's source text.
def integration_argv(script, suite, selected_tags)
  Dir.mktmpdir("ci-suite-matrix-") do |root|
    harness = File.join(root, "tests", "integration.sh")
    FileUtils.mkdir_p(File.dirname(harness))
    File.write(harness, %(#!/bin/sh\nprintf '%s\\n' "$@"\n))
    File.chmod(0o755, harness)
    stdout, stderr, status = Open3.capture3(
      { "SUITE" => suite, "SELECTED_TAGS" => selected_tags },
      "sh", "-c", script, chdir: root
    )
    return [status.success? && stderr.empty?, stdout.lines(chomp: true)]
  end
end

workflow = YAML.safe_load_file(WORKFLOW_PATH, aliases: false)
# Psych follows YAML 1.1 here and may deserialize the plain `on` key as true.
triggers = workflow["on"] || workflow[true]
jobs = workflow.fetch("jobs", {})

# Every job must bound its own runtime. GitHub's default is six hours, and on
# 2026-08-19 an apt-get update stalled mid-download in `static`, producing no output
# for 161 minutes before it was cancelled by hand. A missing timeout is what turns a
# transient mirror failure into an all-day one.
jobs.each do |job_name, job|
  budget = job["timeout-minutes"]
  check(failures, budget.is_a?(Integer) && budget.positive? && budget <= 90,
        "job #{job_name} must declare timeout-minutes between 1 and 90, found #{budget.inspect}")
end

check(failures, triggers.is_a?(Hash), "workflow triggers are missing")
if triggers.is_a?(Hash)
  pull_request = triggers["pull_request"]
  check(failures,
        triggers.key?("pull_request") &&
          (pull_request.nil? || (pull_request.is_a?(Hash) && pull_request.empty?)),
        "pull_request trigger must be unfiltered")
  check(failures, !contains_path_filter?(triggers),
        "triggers must not filter events by path: classification belongs to the changes job")
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

check(failures, jobs.keys.sort == EXPECTED_JOBS.sort,
      "workflow jobs differ: got #{jobs.keys.sort.inspect}, expected #{EXPECTED_JOBS.sort.inspect}")

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

check(failures, jobs.dig("static", "needs") == "changes", "static must depend only on changes")
check(failures, expression(jobs.dig("static", "if")) == "${{ needs.changes.outputs.static == 'true' }}",
      "static condition must match its classifier output")

suites_job = jobs.fetch("suites", {})
check(failures, suites_job["needs"] == "changes", "suites must depend only on changes")
check(failures, expression(suites_job["if"]) == "${{ needs.changes.outputs.suites != '[]' }}",
      "suites must skip entirely when the classifier selects no suite")
check(failures, expression(suites_job["name"]) == "${{ matrix.suite }}",
      "each matrix leg must report its own suite name as the check name")
check(failures, suites_job.dig("strategy", "fail-fast") == false,
      "one failing suite must not cancel the others")
check(failures,
      expression(suites_job.dig("strategy", "matrix", "suite")) ==
        "${{ fromJSON(needs.changes.outputs.suites) }}",
      "the suite matrix must come from the classifier's JSON array")
check(failures, suites_job.dig("strategy", "matrix").keys == ["suite"],
      "the suite matrix must have exactly one dimension")

# The classifier owns the lane-to-suite mapping, including the one hyphen that
# separates the idempotence_check lane from the idempotence-check suite.
check(failures,
      ClassifyChanges.suites(ClassifyChanges.classify([], full: true)) == INTEGRATION_SUITES,
      "a full run must dispatch every suite in canonical order: " \
      "#{ClassifyChanges.suites(ClassifyChanges.classify([], full: true)).inspect}")
check(failures, ClassifyChanges.suites(ClassifyChanges.classify(["README.md"])) == [],
      "an inert change must dispatch no suite")

suites_checkout = Array(suites_job["steps"]).find { |step| step["uses"]&.start_with?("actions/checkout@") }
check(failures, suites_checkout&.fetch("uses", nil) == CHECKOUT_ACTION,
      "suites must check out the repository with the pinned action")
integration_steps = Array(suites_job["steps"]).select { |step| step["run"]&.include?("tests/integration.sh") }
check(failures, integration_steps.length == 1, "suites must have exactly one integration harness step")
integration_step = integration_steps.first || {}
check(failures, integration_step.dig("env", "SUITE") == "${{ matrix.suite }}",
      "the matrix suite must reach the harness through env, not through shell interpolation")
check(failures, integration_step.dig("env", "SELECTED_TAGS") == "${{ needs.changes.outputs.selected_tags }}",
      "suites must pass selected tags through the environment")
integration_run = integration_step["run"].to_s
check(failures, !integration_run.match?(/\beval\b/), "suites must not use eval")

# integration.sh exits 2 when --tags reaches a suite that does not accept it, so
# the guarantee is checked as argv rather than as step text.
INTEGRATION_SUITES.each do |suite|
  untagged = ["--suite", suite, "site.yml"]
  tagged = TAGGED_SUITES.include?(suite) ? ["--suite", suite, "--tags", SAMPLE_TAGS, "site.yml"] : untagged
  ok, argv = integration_argv(integration_run, suite, SAMPLE_TAGS)
  check(failures, ok && argv == tagged,
        "#{suite} with selected tags must invoke #{tagged.inspect}, got #{argv.inspect}")
  ok, argv = integration_argv(integration_run, suite, "")
  check(failures, ok && argv == untagged,
        "#{suite} without selected tags must invoke #{untagged.inspect}, got #{argv.inspect}")
end

# Counterexample: the argv harness must be able to see --tags leaking into the
# empty-tags path, otherwise the loop above proves nothing.
_, leaked_argv = integration_argv(integration_run.sub('[ -n "$SELECTED_TAGS" ]', "true"), "smoke", "")
check(failures, leaked_argv == ["--suite", "smoke", "--tags", "", "site.yml"],
      "argv harness must observe --tags reaching the untagged path: #{leaked_argv.inspect}")

static = jobs.fetch("static", {})
static_steps = Array(static["steps"])
check(failures, static_steps.all?(Hash), "static steps must all be mappings")
check(failures, static_steps.map { |step| step["name"] } == STATIC_STEP_NAMES,
      "static steps differ: got #{static_steps.map { |step| step['name'] }.inspect}, " \
      "expected #{STATIC_STEP_NAMES.inspect}")
check(failures, static_steps.none? { |step| step.key?("if") },
      "static steps must be unconditional: the changes job is the only classifier")

static_commands = run_steps(static)
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
# Assert each package is installed rather than the exact apt invocation, so adding
# flags (retries, timeouts) to a fetch that has stalled in CI does not fail this.
%w[apache2-utils openssh-client openssl].each do |package|
  check(failures,
        static_commands.match?(/apt-get[^\n]*install[^\n]*#{Regexp.escape(package)}/),
        "static checks must install #{package}")
end
check(failures, static_commands.include?('python3 -m venv "$RUNNER_TEMP/ansible"'),
      "static checks must create an isolated Ansible environment")
check(failures, static_commands.include?(
        '"$RUNNER_TEMP/ansible/bin/pip" install \'ansible-core==2.21.3\' \'ansible-lint==26.6.0\''
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
expected_needs = %w[changes static suites]
check(failures, Array(validate["needs"]) == expected_needs,
      "validate must need changes, static and the suite matrix in canonical order")
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
declared = declared_content(jobs)
RETIRED_MIGRATION_MARKERS.each do |marker|
  check(failures, !declared.include?(marker),
        "retired Portainer migration reference reappeared: #{marker}")
end
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
