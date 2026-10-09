#!/usr/bin/env ruby

require "fileutils"
require "json"
require "open3"
require "shellwords"
require "tmpdir"
require "yaml"
require_relative "classify_changes"
require_relative "validate_results"

require_relative "../policy_support"

include TestScaffold

WORKFLOW_PATH = File.expand_path("../../.github/workflows/ci.yml", __dir__)
CONTROLLER_REQUIREMENTS_PATH = File.expand_path("../../controller-requirements.txt", __dir__)
CONTROLLER_REQUIREMENTS_SOURCE_PATH = File.expand_path("../../controller-requirements.in", __dir__)
PYTHON_VERSION_PATH = File.expand_path("../../.python-version", __dir__)
POLICY_PATH = File.expand_path("../validate-policy.sh", __dir__)
ANSIBLE_LINT_PATH = File.expand_path("../../.ansible-lint", __dir__)
CONFIGARR_APPLICATION_YAML = "roles/arr/files/configarr/config.yml"
BROAD_ARR_LINT_EXCLUSIONS = %w[
  roles/arr/
  roles/arr/files/
  roles/arr/files/configarr/
].freeze
ARR_LINT_EXCLUSION_MUTATIONS = (BROAD_ARR_LINT_EXCLUSIONS + %w[
  roles/arr
  ./roles/arr/
  roles/arr/**
]).uniq.freeze
# Approved by name; SHA pinning is asserted below, and Renovate owns which commit.
ALLOWED_ACTION_NAMES = %w[
  actions/checkout actions/setup-python actions/upload-artifact docker/login-action
].freeze
CHECKOUT_ACTION_NAME = "actions/checkout"
LOGIN_ACTION_NAME = "docker/login-action"
# Pulls authenticate with GITHUB_TOKEN. lscr.io fronts ghcr.io, but Docker keys
# credentials by host, so it needs its own login.
GITHUB_BACKED_REGISTRIES = %w[ghcr.io lscr.io].freeze
# Docker Hub takes no GitHub credential; a stored account's 200 pulls/6h beats the
# anonymous 100 shared with every job on the runner's IP.
DOCKER_HUB_REGISTRY = "docker.io"
DOCKER_HUB_USERNAME_SECRET = "DOCKERHUB_USERNAME"
DOCKER_HUB_TOKEN_SECRET = "DOCKERHUB_TOKEN"
# A run step, not the action: it must skip without an `if:` (static refuses one) and
# retry a flaky auth.docker.io. Held byte-identical in every job that pulls.
DOCKER_HUB_LOGIN_STEP = "Authenticate to Docker Hub"
DOCKER_HUB_LOGIN_JOBS = %w[static suites].freeze
STATIC_PREPULL_STEP = "Pre-pull the cleanup sandbox image"
DOCKER_RETRY_SLEEPS = %w[15 30 45].freeze
# A registry outside this list is one nobody decided about.
CREDENTIALED_REGISTRIES = (GITHUB_BACKED_REGISTRIES + [DOCKER_HUB_REGISTRY]).freeze
EXPECTED_JOBS =
  %w[changes static lint docs vault mutation reconciliation toolchain suites validate].freeze
# One reconciliation file per matrix leg, in the order a full run enumerates them.
RECONCILIATION_PARTS = %w[core bazarr configarr].freeze
RECONCILIATION_SUPPORT_PATH =
  File.expand_path("../media_acquisition_reconciliation_support.rb", __dir__)
# The role directories the support file's ARR_TASKS/DOWNLOADER_TASKS resolve to.
RECONCILIATION_TASK_ROOTS = {
  "ARR_TASKS" => "roles/arr/tasks",
  "DOWNLOADER_TASKS" => "roles/downloaders/tasks"
}.freeze
# Contract inputs the support file does not list in a parseable form.
RECONCILIATION_EXTRA_INPUTS = %w[
  roles/arr/files/configarr/config.yml
  roles/arr/files/configarr/quality-definition-movie.json
  roles/arr/files/configarr/quality-definition-series.json
  roles/arr/defaults/main.yml
  roles/downloaders/defaults/main.yml
  inventory/group_vars/all/main.yml
  site.yml
].freeze
# The suites the matrix dispatches, in the order a full run enumerates them.
FULL_RUN_SUITES = %w[
  foundation arr downloaders bindery kapowarr pinchflat trailarr seerr beszel
  dozzle audiobookshelf komga jellyfin immich paperless nextcloud vaultwarden karakeep
  idempotence-check
].freeze
# --full never dispatches upgrade (no base revision), so the argv sweep names it.
UPGRADE_SUITES = %w[upgrade].freeze
# --full keeps the unsharded pass, so the shards are named for the argv sweep too.
IDEMPOTENCE_SHARD_SUITES = %w[
  idempotence-1 idempotence-2 idempotence-3 idempotence-4 idempotence-5 idempotence-6
].freeze
# Every suite the matrix can dispatch by any route.
INTEGRATION_SUITES = (FULL_RUN_SUITES + UPGRADE_SUITES + IDEMPOTENCE_SHARD_SUITES).freeze
# The suites that receive the run's own selected_tags. The upgrade lane is NOT
# one of them: its tags are its subject's, on their own output, because
# selected_tags is the union of every tagged lane and a fall-open empties it.
TAGGED_SUITES = %w[idempotence-check].freeze
CLASSIFIER_OUTPUTS =
  %w[static docs vault reconciliation suites selected_tags
     upgrade_service upgrade_base_image upgrade_tags].freeze
SAMPLE_TAGS = "host_prep,deployment_bundle,beszel"
UPGRADE_SAMPLE_TAGS = "host_prep,deployment_bundle,kapowarr"
STATIC_STEP_NAMES = [
  "Check out repository",
  "Validate shell syntax",
  "Install ShellCheck",
  "Set up Python",
  "Install Ansible tooling",
  "Authenticate to Docker Hub",
  "Pre-pull the cleanup sandbox image",
  "Check policy properties"
].freeze
# Shard-independent steps moved out of `static` (#653): the ones that cannot be a
# manifest line (third-party programs, and the vault self-test).
LINT_STEP_NAMES = [
  "Check out repository",
  "Set up Python",
  "Install Ansible tooling",
  "Check silent ephemeral vault generation",
  "Lint Ansible",
  "Check playbook syntax",
  "Validate the Renovate configuration"
].freeze
# Each must still run somewhere after moving out of `static`.
LINT_CHECK_COMMANDS = [
  "tests/generate-ephemeral-vault.sh --self-test",
  # --offline stops ansible-lint's own galaxy install, which carries the retry
  # defect (#719); the bare form is a prefix and would pin nothing.
  "ansible-lint --strict --offline",
  "ansible-playbook -i inventory/local.yml site.yml --syntax-check",
  "ansible-playbook generate-secrets.yml --syntax-check",
  "ansible-playbook -i inventory/local.yml install-production-auto-deploy.yml --syntax-check"
].freeze
# Moved into the gate's manifest (#653); asserted absent from `static` too.
GATE_ADOPTED_CHECKS = [
  "tests/integration_cleanup_test.sh",
  'PYTHONDONTWRITEBYTECODE=1 "$ansible_python" tests/immich_probe_status_test.py',
  "tests/generate-secrets-redaction-test.sh"
].freeze
# Docs checks read only Markdown and the tree, so the job needs no Ansible toolchain.
DOCS_STEP_NAMES = [
  "Check out repository",
  "Check documentation links",
  "Check the secrets guide against the vault contract"
].freeze
DOCS_CHECK_COMMANDS = [
  "ruby tests/docs_links_test.rb",
  "ruby tests/docs_links_test.rb --self-test",
  "ruby tests/secrets_docs_test.rb"
].freeze
# The vault job (#561): its expected argv is derived from the poller, not restated.
VAULT_STEP_NAMES = [
  "Check out repository",
  "Set up Python",
  "Install Ansible tooling",
  "Validate the encrypted vault"
].freeze
VAULT_PASSWORD_SECRET = "ANSIBLE_VAULT_PASSWORD"
VAULT_PASSWORD_ENV = "VAULT_PASSWORD"
# The one argument that legitimately differs from the poller's.
VAULT_PASSWORD_FILE = "$RUNNER_TEMP/vault-password"
VAULT_PLAYBOOK = "validate-vault.yml"
POLLER_SCRIPT_PATH = File.expand_path("../../scripts/production_auto_deploy.py", __dir__)
RETIRED_MIGRATION_MARKERS = %w[
  nas-infrastructure
  tests/adoption-integration.sh
  adoption-render-test.sh
  legacy-seed-test.sh
  portainer
].freeze

failures = []

def broad_arr_lint_exclusion?(path)
  normalized = path.to_s.sub(%r{\A\./}, "").sub(%r{/+\z}, "")
  normalized == "roles/arr" ||
    (normalized.start_with?("roles/arr/") && normalized != CONFIGARR_APPLICATION_YAML)
end

ARR_LINT_EXCLUSION_MUTATIONS.each do |path|
  check(failures, broad_arr_lint_exclusion?(path),
        "Arr lint exclusion policy must reject #{path.inspect}")
end

ansible_lint = YAML.safe_load_file(ANSIBLE_LINT_PATH)
ansible_lint_excludes = Array(ansible_lint["exclude_paths"])
check(failures, ansible_lint_excludes.include?("services/"),
      "ansible-lint must exclude Docker Compose definitions with custom loader tags")
check(failures, ansible_lint_excludes.include?(CONFIGARR_APPLICATION_YAML),
      "ansible-lint must exclude only the Configarr application YAML with !secret tags")
check(failures, ansible_lint_excludes.none? { |path| broad_arr_lint_exclusion?(path) },
      "ansible-lint must not exclude an Arr directory: #{ansible_lint_excludes.inspect}")

def expression(value)
  value.to_s.gsub(/\s+/, " ").strip
end

def run_steps(job)
  Array(job["steps"]).filter_map { |step| step["run"] }.join("\n")
end

def normalize_shell(source)
  source.to_s.lines.map(&:strip).reject(&:empty?).join("\n")
end

# One command out of a `run:` block as argv, so an inserted flag (--list-tasks exits
# 0 having parsed nothing) changes the answer.
def shell_invocation(source, program)
  lines = normalize_shell(source).lines(chomp: true)
  start = lines.index { |line| line == program || line.start_with?("#{program} ") }
  return nil unless start

  command = +""
  lines[start..].each do |line|
    command << line.delete_suffix("\\")
    break unless line.end_with?("\\")

    command << " "
  end
  Shellwords.split(command)
end

# Asks the poller what it runs; the stub answers any attribute _deploy_invocations reads.
def poller_vault_invocation
  program = <<~PYTHON
    import importlib.util, json, sys

    class Stub:
        def __init__(self, **known):
            self.__dict__.update(known)

        def __getattr__(self, name):
            return "<unset %s>" % name

    spec = importlib.util.spec_from_file_location("poller", sys.argv[1])
    poller = importlib.util.module_from_spec(spec)
    # Registered before it is executed: @dataclass resolves a field's annotation
    # through sys.modules[cls.__module__], so Config dies on import without this.
    sys.modules[spec.name] = poller
    spec.loader.exec_module(poller)
    config = Stub(vault_password_file=sys.argv[2])
    json.dump({
        "vault_arguments": list(poller._vault_arguments(config)),
        "invocations": [list(argv) for argv in poller._deploy_invocations(config)],
    }, sys.stdout)
  PYTHON
  stdout, stderr, status = Open3.capture3(
    "python3", "-c", program, POLLER_SCRIPT_PATH, VAULT_PASSWORD_FILE
  )
  return [nil, stderr.lines.last.to_s.strip] unless status.success?

  [JSON.parse(stdout), nil]
rescue JSON::ParserError => error
  [nil, error.message]
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
def integration_argv(script, suite, selected_tags, upgrade_tags = UPGRADE_SAMPLE_TAGS)
  Dir.mktmpdir("ci-suite-matrix-") do |root|
    harness = File.join(root, "tests", "integration.sh")
    FileUtils.mkdir_p(File.dirname(harness))
    File.write(harness, %(#!/bin/sh\nprintf '%s\\n' "$@"\n))
    File.chmod(0o755, harness)
    stdout, stderr, status = Open3.capture3(
      { "SUITE" => suite, "SELECTED_TAGS" => selected_tags, "UPGRADE_TAGS" => upgrade_tags },
      "sh", "-c", script, chdir: root
    )
    return [status.success? && stderr.empty?, stdout.lines(chomp: true)]
  end
end

# Runs the mutation step's own shell against a stub `ruby` that echoes its
# arguments, so which harness form each event reaches is proven by argv rather
# than by the step's source text.
def mutation_argv(script, event_name)
  Dir.mktmpdir("ci-mutation-form-") do |root|
    stub = File.join(root, "bin", "ruby")
    FileUtils.mkdir_p(File.dirname(stub))
    File.write(stub, %(#!/bin/sh\nprintf '%s\\n' "$@"\n))
    File.chmod(0o755, stub)
    stdout, _stderr, status = Open3.capture3(
      { "EVENT_NAME" => event_name, "PATH" => "#{File.dirname(stub)}:#{ENV.fetch('PATH')}" },
      "sh", "-c", script, chdir: root
    )
    return [status.success?, stdout.lines(chomp: true)]
  end
end

workflow = YAML.safe_load_file(WORKFLOW_PATH, aliases: false)
# Psych follows YAML 1.1 here and may deserialize the plain `on` key as true.
triggers = workflow["on"] || workflow[true]
jobs = workflow.fetch("jobs", {})

# Every job bounds its runtime; GitHub's default is six hours.
jobs.each do |job_name, job|
  budget = job["timeout-minutes"]
  check(failures, budget.is_a?(Integer) && budget.positive? && budget <= 90,
        "job #{job_name} must declare timeout-minutes between 1 and 90, found #{budget.inspect}")
end

# One pinned runner image for every job: one leg stands for the rest (#395), and a
# floating -latest would change toolchains under an unchanged tree (#843).
def runner_label_violations(jobs)
  violations = []
  jobs.each do |job_name, job|
    label = job["runs-on"]
    if !label.is_a?(String) || !label.match?(/\Aubuntu-\d+\.\d+\z/)
      violations << "job #{job_name} must run on a pinned ubuntu-<version> label, found #{label.inspect}"
    end
  end
  labels = jobs.values.map { |job| job["runs-on"] }.uniq
  violations << "every job must run on the same runner label, found #{labels.inspect}" if labels.length > 1
  violations
end

runner_label_violations(jobs).each { |violation| check(failures, false, violation) }
RUNNER_LABEL = jobs.dig("changes", "runs-on")

# Each plant trips exactly one clause, so each clause is shown to bite alone.
{
  "every job on a floating -latest label" =>
    jobs.transform_values { |job| job.merge("runs-on" => "ubuntu-latest") },
  "one job on a different pinned label" =>
    jobs.merge("lint" => jobs.fetch("lint", {}).merge("runs-on" => "ubuntu-22.04")),
  "a runs-on that is not a single label" =>
    jobs.transform_values { |job| job.merge("runs-on" => [RUNNER_LABEL]) }
}.each do |defect, planted|
  check(failures, !runner_label_violations(planted).empty?,
        "the runner label checker must refuse #{defect}")
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
  # Pinned: GitHub delays scheduled runs by hours; 17:47 keeps the nightly out of
  # the merge window.
  check(failures, triggers.dig("schedule", 0, "cron") == "47 17 * * *", "nightly schedule is incorrect")
  check(failures, triggers.key?("workflow_dispatch"), "workflow_dispatch trigger is missing")
end

concurrency = workflow.fetch("concurrency", {})
# The event name stops the nightly cancelling push runs; the per-commit fallback
# keeps merges out of one group, where GitHub evicts pending runs.
check(
  failures,
  expression(concurrency["group"]) ==
    'ci-${{ github.workflow }}-${{ github.event_name }}-' \
    '${{ github.event.pull_request.number || github.sha }}',
  "concurrency group must separate events and fall back to the commit, not the " \
  "ref: a shared push group evicts pending merges: " \
  "#{expression(concurrency['group']).inspect}"
)
# Only a pull request supersedes itself; a push is the only run that sees its tree.
check(failures, expression(concurrency["cancel-in-progress"]) == "${{ github.event_name == 'pull_request' }}",
      "only pull requests may cancel their own superseded runs")
check(failures, workflow.dig("permissions", "contents") == "read", "contents permission must be read-only")
# Registry scopes are granted per job, never workflow-wide.
check(failures, workflow.fetch("permissions", {}).keys == ["contents"],
      "workflow-level permissions must grant nothing beyond contents: " \
      "#{workflow.fetch('permissions', {}).keys.inspect}")

check(failures, jobs.keys.sort == EXPECTED_JOBS.sort,
      "workflow jobs differ: got #{jobs.keys.sort.inspect}, expected #{EXPECTED_JOBS.sort.inspect}")

changes = jobs.fetch("changes", {})
check(failures, changes["runs-on"] == RUNNER_LABEL, "changes must run on the shared runner label")
check(failures, changes.fetch("outputs", {}).keys.sort == CLASSIFIER_OUTPUTS.sort,
      "changes must expose every classifier output")
CLASSIFIER_OUTPUTS.each do |output|
  check(failures,
        expression(changes.dig("outputs", output)) == "${{ steps.classify.outputs.#{output} }}",
        "changes output #{output} must come from the classify step")
end

changes_steps = Array(changes["steps"])
changes_checkout = changes_steps.find { |step| step["uses"]&.start_with?("actions/checkout@") }
check(failures, changes_checkout&.fetch("uses", nil).to_s.split("@").first == CHECKOUT_ACTION_NAME,
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
check(failures, classify.dig("env", "PUSH_BEFORE") == "${{ github.event.before }}",
      "classifier must receive the ref a push replaced through env")
classifier_run = classify["run"].to_s
check(failures, classifier_run.include?('[ "$EVENT_NAME" = pull_request ]'),
      "classifier must recognise the pull_request event by name")
check(failures, classifier_run.include?('BASE=$PR_BASE') && classifier_run.include?('HEAD=$PR_HEAD'),
      "classifier must set BASE and HEAD only inside the pull_request branch")
check(failures,
      classifier_run.include?('ruby tests/ci/classify_changes.rb --diff "$BASE" "$HEAD" --github-output "$GITHUB_OUTPUT"'),
      "pull requests must classify the base/head diff safely")
# A push classifies the merge it landed; --full is only the push fallback and the
# schedule/workflow_dispatch branch.
check(failures, classifier_run.include?('[ "$EVENT_NAME" = push ]'),
      "classifier must recognise the push event by name")
check(failures,
      classifier_run.include?('ruby tests/ci/classify_changes.rb --diff "$PUSH_BASE" HEAD --github-output "$GITHUB_OUTPUT"'),
      "a push must classify the diff it landed rather than sweeping the repository")
check(failures, classifier_run.include?('"$PUSH_BEFORE"') && classifier_run.include?('"HEAD^"'),
      "a push must prefer the ref it replaced and fall back to the first parent")
full_requests =
  classifier_run.scan('ruby tests/ci/classify_changes.rb --full --github-output "$GITHUB_OUTPUT"').length
check(failures, full_requests == 2,
      "--full must be reachable exactly twice -- the push fallback and schedule/dispatch -- " \
      "found #{full_requests}")
check(failures, !classifier_run.include?("github.event.pull_request"),
      "event payload expressions must not be interpolated into shell source")

check(failures, jobs.dig("static", "needs") == "changes", "static must depend only on changes")
# The matrix must name exactly the gate's shards (#469): a dropped shard's checks run
# nowhere while every other guard stays green. Derived, not a literal count.
GATE_SHARD_IDS = PolicySupport.gate_shard_ids(POLICY_PATH)
check_floor(failures, GATE_SHARD_IDS.length, 2,
            "the shards tests/validate-policy.sh declares")
check(failures, jobs.dig("static", "strategy", "matrix", "shard") == GATE_SHARD_IDS,
      "the static matrix must name every shard tests/validate-policy.sh declares " \
      "(#{GATE_SHARD_IDS.inspect}), found " \
      "#{jobs.dig('static', 'strategy', 'matrix', 'shard').inspect}: a shard missing from the " \
      "matrix runs on no runner while every other guard still reports the gate whole")
check(failures, GATE_SHARD_IDS == PolicySupport.gate_shards(POLICY_PATH).keys,
      "tests/validate-policy.sh dispatches shards #{GATE_SHARD_IDS.inspect} and holds heredocs " \
      "for #{PolicySupport.gate_shards(POLICY_PATH).keys.inspect}")
# `to_h` (here and at two matrices below): a deleted job arrives as nil, and a crash
# would discard the diagnostics naming the deletion (#480).
check(failures, jobs.dig("static", "strategy", "matrix").to_h.keys == ["shard"],
      "the static matrix must have exactly one dimension")
check(failures, jobs.dig("static", "strategy", "fail-fast") == false,
      "a failing shard must not cancel the other shards: the gate gave up stopping at its " \
      "first failure so that one broken check cannot hide the state of the rest, and " \
      "fail-fast would reinstate that a level up")
check(failures, expression(jobs.dig("static", "name")) == "static (${{ matrix.shard }})",
      "each static leg must report its own shard as the check name, found " \
      "#{expression(jobs.dig('static', 'name')).inspect}")
# One runner per reconciliation file; a literal list so dropping one shows in the diff.
check(failures, jobs.dig("reconciliation", "needs") == "changes",
      "reconciliation must depend only on changes")
check(failures, jobs.dig("reconciliation", "strategy", "matrix", "part") == RECONCILIATION_PARTS,
      "the reconciliation matrix must name every media acquisition reconciliation file " \
      "in canonical order, found #{jobs.dig('reconciliation', 'strategy', 'matrix', 'part').inspect}")
# `to_h`: see the static matrix above.
check(failures, jobs.dig("reconciliation", "strategy", "matrix").to_h.keys == ["part"],
      "the reconciliation matrix must have exactly one dimension")
check(failures, jobs.dig("reconciliation", "strategy", "fail-fast") == false,
      "one failing reconciliation file must not cancel the others")
check(failures, expression(jobs.dig("reconciliation", "name")) == "reconciliation (${{ matrix.part }})",
      "each reconciliation leg must report which file it ran as the check name")
reconciliation_step = Array(jobs.dig("reconciliation", "steps")).find do |step|
  step["run"].to_s.include?("media_acquisition_reconciliation_")
end
check(failures,
      reconciliation_step.to_h.dig("env", "PART") == "${{ matrix.part }}",
      "the reconciliation leg must reach its file through an environment variable, " \
      "not by interpolating the matrix value into shell source")
check(failures,
      reconciliation_step.to_h["run"].to_s.strip ==
        'ruby "tests/media_acquisition_reconciliation_${PART}_test.rb"',
      "the reconciliation leg must run exactly its own file, " \
      "found #{reconciliation_step.to_h['run'].inspect}")
RECONCILIATION_PARTS.each do |part|
  check(failures, File.file?(File.expand_path("../media_acquisition_reconciliation_#{part}_test.rb", __dir__)),
        "the reconciliation matrix names a file that does not exist: #{part}")
end

# Routed on its own output; routing that fails closed silently stops the contract,
# so every input is asserted to select it.
check(failures,
      expression(jobs.dig("reconciliation", "if")) ==
        "${{ needs.changes.outputs.reconciliation == 'true' }}",
      "reconciliation must be gated on its own classifier output, found " \
      "#{expression(jobs.dig('reconciliation', 'if')).inspect}")

# Taken out of the support file rather than restated, so a task file added to the
# contract is checked for routing by the same edit that adds it.
support_source = File.read(RECONCILIATION_SUPPORT_PATH)
secret_task_block = support_source[/^SECRET_TASK_FILES = \[\n(.*?)^\]\.freeze$/m, 1].to_s
reconciliation_task_files = secret_task_block.scan(/\[(\w+), "([^"]+)"\]/).map do |root, file|
  root_path = RECONCILIATION_TASK_ROOTS[root]
  check(failures, !root_path.nil?,
        "the reconciliation contract reads task files from an unmapped root: #{root}")
  "#{root_path}/#{file}"
end
check(failures, reconciliation_task_files.length >= RECONCILIATION_TASK_ROOTS.length,
      "SECRET_TASK_FILES could not be read out of the support file: " \
      "#{secret_task_block.inspect}")

reconciliation_inputs = (
  reconciliation_task_files + RECONCILIATION_EXTRA_INPUTS +
  ClassifyChanges::RECONCILIATION_OWNED_PATHS
).uniq
reconciliation_inputs.each do |path|
  check(failures, File.file?(File.expand_path("../../#{path}", __dir__)),
        "the reconciliation contract names an input that does not exist: #{path}")
  check(failures, ClassifyChanges.classify([path]).fetch("reconciliation"),
        "#{path} is an input to the reconciliation contract but does not select it")
end
# The saving is the point: a change that the contract cannot read must not run it.
%w[
  roles/dozzle/tasks/managed_users.yml
  services/beszel/compose.yml
  docs/secrets.md
].each do |path|
  check(failures, !ClassifyChanges.classify([path]).fetch("reconciliation"),
        "#{path} cannot reach the reconciliation contract but still selects it")
end

check(failures, expression(jobs.dig("static", "if")) == "${{ needs.changes.outputs.static == 'true' }}",
      "static condition must match its classifier output")

# The mutation harness runs beside the gate on the same output: a mutation plants
# into a copy of the whole repository.
check(failures, jobs.dig("mutation", "needs") == "changes",
      "mutation must depend only on changes")
check(failures,
      expression(jobs.dig("mutation", "if")) == "${{ needs.changes.outputs.static == 'true' }}",
      "the mutation harness must run whenever the policy gate does, found " \
      "#{expression(jobs.dig('mutation', 'if')).inspect}")
check(failures, jobs.dig("mutation", "strategy").nil?,
      "the mutation harness is one file and must not declare a matrix")
mutation_commands = normalize_shell(run_steps(jobs.fetch("mutation", {}))).lines.map(&:chomp)
check(failures, mutation_commands.include?("ruby tests/policy_manifest_test.rb"),
      "the mutation job must run tests/policy_manifest_test.rb")
# Nightly and workflow_dispatch run --audit, everything else the narrow form (#727);
# an unknown event must fail rather than pick one.
mutation_step = Array(jobs.dig("mutation", "steps")).find { |step| step["name"] == "Check policy mutation coverage" } || {}
check(failures, mutation_step.dig("env", "EVENT_NAME") == "${{ github.event_name }}",
      "the mutation step must receive the event name through env")
check(failures, !mutation_step["run"].to_s.include?("${{"),
      "the mutation step must not interpolate expressions into shell source")
{
  "schedule" => ["tests/policy_manifest_test.rb", "--audit"],
  "workflow_dispatch" => ["tests/policy_manifest_test.rb", "--audit"],
  "pull_request" => ["tests/policy_manifest_test.rb"],
  "push" => ["tests/policy_manifest_test.rb"]
}.each do |event_name, expected|
  ok, argv = mutation_argv(mutation_step["run"].to_s, event_name)
  check(failures, ok && argv == expected,
        "the mutation step on #{event_name} must run ruby #{expected.join(' ')}, found #{argv.inspect}")
end
ok, argv = mutation_argv(mutation_step["run"].to_s, "merge_group")
check(failures, !ok && argv.empty?,
      "the mutation step must refuse an event it declares no harness form for, found #{argv.inspect}")
check(failures, jobs.dig("mutation", "timeout-minutes").to_i >= 60,
      "the mutation job runs --audit on the nightly, measured at up to 34.5 minutes on a " \
      "runner (#727); its timeout must stay at 60 or above")
# The harness needs the gate's Ansible toolchain.
check(failures,
      mutation_commands.any? do |command|
        command.include?("pip") && command.include?("-r controller-requirements.txt")
      end,
      "the mutation job must install the pinned Ansible toolchain")

# Every toolchain install step is byte-identical and installs from the lock.
INSTALL_TOOLCHAIN_STEP = "Install Ansible tooling"
toolchain_installs = jobs.each_with_object({}) do |(name, job), collected|
  step = Array(job["steps"]).find do |candidate|
    candidate.is_a?(Hash) && candidate["name"] == INSTALL_TOOLCHAIN_STEP
  end
  collected[name] = step["run"].to_s if step
end
check(failures, toolchain_installs.length >= 4,
      "at least four jobs install the Ansible toolchain; found #{toolchain_installs.keys.inspect}, " \
      "which means this comparison is proving less than it reads as")
check(failures, toolchain_installs.values.uniq.length == 1,
      "every #{INSTALL_TOOLCHAIN_STEP.inspect} step must be byte-identical, " \
      "#{toolchain_installs.keys.inspect} carry #{toolchain_installs.values.uniq.length} versions")
toolchain_installs.each do |name, body|
  check(failures, body.include?('"$RUNNER_TEMP/ansible/bin/pip" install --require-hashes -r controller-requirements.txt'),
        "the #{name} job must install the hash-locked controller toolchain from " \
        "controller-requirements.txt with --require-hashes")
  check(failures, !body.match?(/ansible-(?:core|lint)==/),
        "the #{name} job must not restate a pin controller-requirements.txt already authors")
end

# Galaxy installs sit inside a retry loop (#747); the loop itself is run against a
# stubbed ansible-galaxy under `bash -e`, with `sleep` recording the backoff.
GALAXY_INSTALL_LOOP = /^for attempt in 1 2 3; do\n.*?^done$/m
galaxy_retry_loops = []
jobs.each do |name, job|
  Array(job["steps"]).each do |step|
    body = step.is_a?(Hash) ? step["run"].to_s : ""
    loops = body.to_enum(:scan, GALAXY_INSTALL_LOOP).map { Regexp.last_match }
    galaxy_retry_loops.concat(loops.map { |match| match[0] })
    body.to_enum(:scan, /^.*ansible-galaxy collection install.*$/).each do
      offset = Regexp.last_match.begin(0)
      check(failures, loops.any? { |match| match.begin(0) <= offset && offset < match.end(0) },
            "the #{name} job's #{step['name'].inspect} step runs `ansible-galaxy collection install` " \
            "outside the retry loop; a transient Galaxy reset would red it (#747)")
    end
  end
end
check(failures, galaxy_retry_loops.length >= 4,
      "found #{galaxy_retry_loops.length} Galaxy retry loops where at least four jobs install " \
      "collections; this check is proving less than it reads as")

def run_galaxy_retry(loop_source, succeed_on)
  Dir.mktmpdir("ci-galaxy-retry-") do |root|
    stub = File.join(root, "ansible", "bin", "ansible-galaxy")
    FileUtils.mkdir_p(File.dirname(stub))
    File.write(stub, <<~SH)
      #!/bin/sh
      count=$(( $(cat "$RUNNER_TEMP/calls" 2>/dev/null || echo 0) + 1 ))
      echo "$count" >"$RUNNER_TEMP/calls"
      [ "$count" -ge #{succeed_on} ] && exit 0
      echo "stub galaxy: Connection reset by peer (call $count)" >&2
      exit 1
    SH
    File.chmod(0o755, stub)
    script = %(sleep() { printf '%s\\n' "$1" >>"$RUNNER_TEMP/sleeps"; }\n#{loop_source}\necho reached-end\n)
    stdout, stderr, status = Open3.capture3(
      { "RUNNER_TEMP" => root }, "bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", script,
      chdir: root
    )
    read = ->(file) { File.file?(File.join(root, file)) ? File.read(File.join(root, file)).split : [] }
    { success: status.success?, stdout: stdout, stderr: stderr,
      calls: read.call("calls").last.to_i, sleeps: read.call("sleeps") }
  end
end

if (galaxy_loop = galaxy_retry_loops.first)
  first = run_galaxy_retry(galaxy_loop, 1)
  check(failures, first[:success] && first[:calls] == 1 && first[:sleeps].empty? &&
                  first[:stdout].include?("reached-end"),
        "a Galaxy install that succeeds at once must run once and not wait, got #{first.inspect}")
  third = run_galaxy_retry(galaxy_loop, 3)
  check(failures, third[:success] && third[:calls] == 3 && third[:sleeps] == %w[10 20] &&
                  third[:stdout].include?("reached-end"),
        "a Galaxy install that fails twice then succeeds must pass on the third attempt after " \
        "backing off 10s then 20s, got #{third.inspect}")
  never = run_galaxy_retry(galaxy_loop, 99)
  check(failures, !never[:success] && never[:calls] == 3 && !never[:stdout].include?("reached-end") &&
                  never[:stderr].include?("Connection reset by peer (call 3)") &&
                  never[:stderr].include?("::error::"),
        "a Galaxy install that always fails must red the step after exactly three attempts with " \
        "the last error visible, got #{never.inspect}")
end

# setup-python precedes every toolchain install, byte-identical, and reads
# .python-version rather than naming a version (#655).
PYTHON_SETUP_STEP = "Set up Python"
PYTHON_VERSION_FILE = ".python-version"
python_setups = jobs.each_with_object({}) do |(name, job), collected|
  steps = Array(job["steps"])
  next unless steps.any? { |step| step.is_a?(Hash) && step["name"] == INSTALL_TOOLCHAIN_STEP }

  collected[name] = steps
end
python_setups.each do |name, steps|
  setup_index = steps.index { |step| step.is_a?(Hash) && step["name"] == PYTHON_SETUP_STEP }
  install_index = steps.index { |step| step.is_a?(Hash) && step["name"] == INSTALL_TOOLCHAIN_STEP }
  check(failures, setup_index && setup_index < install_index,
        "the #{name} job must run #{PYTHON_SETUP_STEP.inspect} before " \
        "#{INSTALL_TOOLCHAIN_STEP.inspect}: a setup after the venv is built " \
        "configures an interpreter the venv did not use")
  next unless setup_index

  step = steps[setup_index]
  check(failures, step["uses"].to_s.start_with?("actions/setup-python@"),
        "the #{name} job's #{PYTHON_SETUP_STEP.inspect} must use actions/setup-python, " \
        "found #{step['uses'].inspect}")
  check(failures, step.dig("with", "python-version-file") == PYTHON_VERSION_FILE,
        "the #{name} job's #{PYTHON_SETUP_STEP.inspect} must read #{PYTHON_VERSION_FILE}, " \
        "not name a version of its own: found #{step.dig('with', 'python-version-file').inspect}")
  check(failures, !step.fetch("with", {}).key?("python-version"),
        "the #{name} job's #{PYTHON_SETUP_STEP.inspect} must not restate the version " \
        "#{PYTHON_VERSION_FILE} already authors")
end
python_setup_bodies = python_setups.filter_map do |_name, steps|
  steps.find { |step| step.is_a?(Hash) && step["name"] == PYTHON_SETUP_STEP }
end
check(failures, python_setup_bodies.length == python_setups.length &&
                python_setup_bodies.uniq.length == 1,
      "every #{PYTHON_SETUP_STEP.inspect} step must be byte-identical across the " \
      "#{python_setups.keys.inspect} jobs, found #{python_setup_bodies.uniq.length} versions")
declared_python = File.read(File.join(ROOT, PYTHON_VERSION_FILE)).strip
check(failures, declared_python.match?(/\A\d+\.\d+\z/),
      "#{PYTHON_VERSION_FILE} must name a major.minor series, found #{declared_python.inspect}")

# Published once per run. Suites need it without the success gate: the harness
# builds the image itself, so a failed publish costs time, not coverage.
toolchain_job = jobs.fetch("toolchain", {})
# Needs nothing: every lane waits for this job, so an edge delays them all.
check(failures, toolchain_job["needs"].nil?,
      "toolchain must depend on nothing: the suites matrix waits for this job, so " \
      "an edge here delays every lane by whatever this job waits for, " \
      "found #{toolchain_job['needs'].inspect}")
check(failures,
      expression(toolchain_job["if"]) ==
        "${{ github.event.pull_request.head.repo.fork != true }}",
      "toolchain must publish for every run but a fork's, whose GITHUB_TOKEN " \
      "cannot write packages, found #{expression(toolchain_job['if']).inspect}")
check(failures,
      toolchain_job.fetch("permissions", {}) == { "contents" => "read", "packages" => "write" },
      "the toolchain job must hold exactly the scopes it publishes with")
toolchain_steps = Array(toolchain_job["steps"]).select { |step| step.is_a?(Hash) }
toolchain_login = toolchain_steps.find { |step| step["uses"].to_s.start_with?("docker/login-action@") }
check(failures, toolchain_login&.dig("with", "registry") == "ghcr.io",
      "the toolchain job must authenticate to ghcr.io before publishing")
check(failures, toolchain_login&.dig("with", "password") == "${{ secrets.GITHUB_TOKEN }}",
      "the toolchain publish must use the job's own GITHUB_TOKEN")
toolchain_publish = toolchain_steps.find { |step| step["run"].to_s.include?("tests/integration.sh") }
check(failures, !toolchain_publish.nil?,
      "the toolchain job must publish through the harness that consumes the image")
# Tag and build arguments live only in tests/integration.sh.
check(failures, toolchain_publish&.dig("env", "INTEGRATION_TOOLCHAIN_PUBLISH") == "1",
      "the toolchain job must select the harness's publish mode through env")
check(failures, toolchain_publish&.fetch("run", "").to_s.strip == "tests/integration.sh",
      "the toolchain job must not restate the harness's build arguments: " \
      "#{toolchain_publish&.fetch('run', nil).inspect}")

suites_job = jobs.fetch("suites", {})
check(failures, Array(suites_job["needs"]) == %w[changes toolchain],
      "suites must depend on the classifier and on the toolchain publish")
check(failures,
      expression(suites_job["if"]) ==
        "${{ !cancelled() && needs.changes.result == 'success' && " \
        "needs.changes.outputs.suites != '[]' }}",
      "suites must skip when the classifier selects no suite, and must still run " \
      "when the toolchain publish did not, found #{expression(suites_job['if']).inspect}")
check(failures, expression(suites_job["name"]) == "${{ matrix.suite }}",
      "each matrix leg must report its own suite name as the check name")
check(failures, suites_job.dig("strategy", "fail-fast") == false,
      "one failing suite must not cancel the others")
check(failures,
      expression(suites_job.dig("strategy", "matrix", "suite")) ==
        "${{ fromJSON(needs.changes.outputs.suites) }}",
      "the suite matrix must come from the classifier's JSON array")
# `to_h`: see the static matrix above.
check(failures, suites_job.dig("strategy", "matrix").to_h.keys == ["suite"],
      "the suite matrix must have exactly one dimension")
# A floor: the #395 route runs only cheap suites, so a lowered budget would cancel a
# slow lane unseen. 90 covers the untagged idempotence re-converge plus pull retries.
suites_budget = suites_job["timeout-minutes"]
check(failures, suites_budget.is_a?(Integer) && suites_budget >= 90,
      "suites must keep a timeout of at least 90 minutes, found #{suites_budget.inspect}: the " \
      "narrowed workflow route runs the cheapest legs and cannot observe a budget the slowest " \
      "one needs")

# The classifier owns the lane-to-suite mapping, including the one hyphen that
# separates the idempotence_check lane from the idempotence-check suite.
check(failures,
      ClassifyChanges.suites(ClassifyChanges.classify([], full: true)) == FULL_RUN_SUITES,
      "a full run must dispatch every suite in canonical order: " \
      "#{ClassifyChanges.suites(ClassifyChanges.classify([], full: true)).inspect}")
# An unmapped path shards the idempotence lane instead; neither route drops a lane.
fall_open_suites = ClassifyChanges.suites(ClassifyChanges.classify(["unexpected/new-runtime-file"]))
check(failures,
      fall_open_suites == FULL_RUN_SUITES - ["idempotence-check"] + IDEMPOTENCE_SHARD_SUITES,
      "an unmapped path must dispatch every suite with the idempotence lane sharded: " \
      "#{fall_open_suites.inspect}")
check(failures, ClassifyChanges.suites(ClassifyChanges.classify(["README.md"])) == [],
      "an inert change must dispatch no suite")

# Floor under UPGRADE_SUITES: emptying it would leave its sweeps running over nothing.
check(failures, UPGRADE_SUITES == %w[upgrade],
      "UPGRADE_SUITES must name exactly the upgrade lane, found #{UPGRADE_SUITES.inspect}: an " \
      "emptied list stops the argv sweep below covering the one suite it was added for")
check(failures, (UPGRADE_SUITES - ClassifyChanges::SUITES.values).empty?,
      "UPGRADE_SUITES names a suite tests/ci/suites.conf does not: " \
      "#{(UPGRADE_SUITES - ClassifyChanges::SUITES.values).inspect}")

suites_checkout = Array(suites_job["steps"]).find { |step| step["uses"]&.start_with?("actions/checkout@") }
check(failures, suites_checkout&.fetch("uses", nil).to_s.split("@").first == CHECKOUT_ACTION_NAME,
      "suites must check out the repository with the pinned action")

# Logins keep pulls off the shared anonymous allowance (PR #84's toomanyrequests).
# Job permissions replace the workflow's, so both keys are asserted.
check(failures, suites_job.fetch("permissions", {}) == { "contents" => "read", "packages" => "read" },
      "suites must grant exactly contents: read and packages: read, " \
      "found #{suites_job.fetch('permissions', {}).inspect}")
# Registries needing a login are derived from the Compose files.
compose_image_lines = Dir[File.expand_path("../../services/*/compose.yml", __dir__)]
                      .flat_map { |path| File.readlines(path) }
                      .grep(/^\s*image:\s*\S/)
compose_hosts = compose_image_lines.filter_map { |line| line[/^\s*image:\s*([^\s\/]+)\//, 1] }
check(failures, !compose_hosts.empty?, "no service image names a registry host")
# An image written without a host defaults to Docker Hub silently, which would
# take it out of the classification below rather than into it.
check(failures, compose_hosts.length == compose_image_lines.length,
      "every service image must name its registry host, " \
      "#{compose_image_lines.length - compose_hosts.length} do not")
compose_registries = compose_hosts.uniq.sort
unclassified = compose_registries - CREDENTIALED_REGISTRIES
check(failures, unclassified.empty?,
      "registry #{unclassified.inspect} is used by a service image but classified nowhere: " \
      "decide whether the job can authenticate to it before pulling from it")
expected_logins = (compose_registries & CREDENTIALED_REGISTRIES).sort
suites_steps = Array(suites_job["steps"])
login_steps = suites_steps.select { |step| step["uses"]&.start_with?("#{LOGIN_ACTION_NAME}@") }
suites_docker_hub_login = suites_steps.find { |step| step["name"] == DOCKER_HUB_LOGIN_STEP }
suites_logins = login_steps.map { |step| step.dig("with", "registry") }.compact
suites_logins << DOCKER_HUB_REGISTRY if suites_docker_hub_login
check(failures, suites_logins.sort == expected_logins,
      "suites must authenticate to exactly #{expected_logins.inspect}, found #{suites_logins.inspect}")
harness_index = suites_steps.index { |step| step["run"]&.include?("tests/integration.sh") }
login_steps.each do |step|
  registry = step.dig("with", "registry")
  if registry == DOCKER_HUB_REGISTRY
    check(failures, false,
          "the #{registry} login must be the retried #{DOCKER_HUB_LOGIN_STEP.inspect} run step, " \
          "not #{LOGIN_ACTION_NAME}: the action cannot retry a flaky auth.docker.io")
  else
    check(failures, step.dig("with", "username") == "${{ github.actor }}",
          "the #{registry} login must authenticate as the acting account")
    check(failures, step.dig("with", "password") == "${{ secrets.GITHUB_TOKEN }}",
          "the #{registry} login must use the job's own GITHUB_TOKEN, not a stored credential")
  end
  # Order matters: a login after the harness has already run buys nothing.
  login_index = suites_steps.index(step)
  check(failures, !login_index.nil? && !harness_index.nil? && login_index < harness_index,
        "the #{registry} login must precede the integration harness: " \
        "#{suites_steps.map { |item| item['name'] }.inspect}")
end
# Only the job that pulls images and the job that publishes one may hold a
# registry scope, and only the publisher may hold a writing one.
jobs.each do |job_name, job|
  scope = job.fetch("permissions", {})["packages"]
  case job_name
  when "suites"
    check(failures, scope == "read", "suites must read the registry and no more")
  when "toolchain"
    check(failures, scope == "write", "toolchain must hold the scope it publishes with")
  else
    check(failures, scope.nil?,
          "job #{job_name} must not request the registry scope: it pulls no images")
  end
end

integration_steps = Array(suites_job["steps"]).select { |step| step["run"]&.include?("tests/integration.sh") }
check(failures, integration_steps.length == 1, "suites must have exactly one integration harness step")
integration_step = integration_steps.first || {}

# Every step in this job must be read by a check above (#395): a route dispatching
# three legs cannot see a step only a heavy suite trips over.
examined_steps = ([suites_checkout, suites_docker_hub_login] + login_steps + integration_steps).compact
unexamined = suites_steps - examined_steps
check(failures, unexamined.empty?,
      "the suites job has #{unexamined.length} step(s) no check reads: " \
      "#{unexamined.map { |step| step['name'] || step['run'] }.inspect}. A change to a suite leg " \
      "dispatches three legs of seventeen, so a step asserted nowhere is a leg's behaviour " \
      "changing under a green gate")
# The same property for the job's environment, which reaches every step in it:
# the Docker Hub secrets stay in the one step that reads them.
check(failures, suites_job.fetch("env", {}).empty?,
      "suites must expose no job-level env, found #{suites_job.fetch('env', {}).keys.inspect}")
check(failures, integration_step.dig("env", "SUITE") == "${{ matrix.suite }}",
      "the matrix suite must reach the harness through env, not through shell interpolation")
check(failures, integration_step.dig("env", "SELECTED_TAGS") == "${{ needs.changes.outputs.selected_tags }}",
      "suites must pass selected tags through the environment")
# Upgrade inputs come from `changes` (fetch-depth 0); this job's shallow checkout
# cannot read a base revision.
{ "INTEGRATION_UPGRADE_SERVICE" => "upgrade_service",
  "INTEGRATION_UPGRADE_BASE_IMAGE" => "upgrade_base_image",
  "UPGRADE_TAGS" => "upgrade_tags" }.each do |name, output|
  check(failures,
        integration_step.dig("env", name) == "${{ needs.changes.outputs.#{output} }}",
        "suites must pass #{name} from the classifier's #{output} output")
end
integration_run = integration_step["run"].to_s
check(failures, !integration_run.match?(/\beval\b/), "suites must not use eval")

# integration.sh exits 2 when --tags reaches a suite that does not accept it, so
# the guarantee is checked as argv rather than as step text.
INTEGRATION_SUITES.each do |suite|
  # The upgrade lane reads neither branch below: its tags come from its own
  # output, so it is asserted on its own terms afterwards.
  next if UPGRADE_SUITES.include?(suite)

  untagged = ["--suite", suite, "site.yml"]
  tagged = TAGGED_SUITES.include?(suite) ? ["--suite", suite, "--tags", SAMPLE_TAGS, "site.yml"] : untagged
  ok, argv = integration_argv(integration_run, suite, SAMPLE_TAGS)
  check(failures, ok && argv == tagged,
        "#{suite} with selected tags must invoke #{tagged.inspect}, got #{argv.inspect}")
  ok, argv = integration_argv(integration_run, suite, "")
  check(failures, ok && argv == untagged,
        "#{suite} without selected tags must invoke #{untagged.inspect}, got #{argv.inspect}")
end

# The upgrade lane takes its subject's tags: a fall-open empties selected_tags and
# would converge the whole site twice.
UPGRADE_SUITES.each do |suite|
  expected = ["--suite", suite, "--tags", UPGRADE_SAMPLE_TAGS, "site.yml"]
  ["", SAMPLE_TAGS].each do |run_tags|
    ok, argv = integration_argv(integration_run, suite, run_tags)
    check(failures, ok && argv == expected,
          "#{suite} must invoke #{expected.inspect} whatever the run's own tags are " \
          "(selected_tags=#{run_tags.inspect}), got #{argv.inspect}")
  end
  # And it refuses rather than degrading to the untagged branch, because that
  # failure would read as the lane being slow rather than as an empty subject.
  ok, argv = integration_argv(integration_run, suite, SAMPLE_TAGS, "")
  check(failures, !ok && argv.empty?,
        "#{suite} with no subject tags must refuse rather than converge the whole site, " \
        "got #{argv.inspect}")
end

# Counterexample: the argv harness must be able to see --tags leaking into the
# empty-tags path, otherwise the loop above proves nothing.
_, leaked_argv = integration_argv(integration_run.sub('[ -n "$SELECTED_TAGS" ]', "true"), "idempotence-check", "")
check(failures, leaked_argv == ["--suite", "idempotence-check", "--tags", "", "site.yml"],
      "argv harness must observe --tags reaching the untagged path: #{leaked_argv.inspect}")

static = jobs.fetch("static", {})
static_steps = Array(static["steps"])
check(failures, static_steps.all?(Hash), "static steps must all be mappings")
check(failures, static_steps.map { |step| step["name"] } == STATIC_STEP_NAMES,
      "static steps differ: got #{static_steps.map { |step| step['name'] }.inspect}, " \
      "expected #{STATIC_STEP_NAMES.inspect}")
check(failures, static_steps.none? { |step| step.key?("if") },
      "static steps must be unconditional: the changes job is the only classifier, and a step " \
      "conditioned on the shard is a check that runs on one leg of three")

# The shard reaches the gate through env, never interpolated.
gate_steps = static_steps.select { |step| step["run"].to_s.include?("tests/validate-policy.sh") }
check(failures, gate_steps.length == 1, "static must have exactly one policy gate step")
gate_step = gate_steps.first || {}
check(failures, gate_step.dig("env", "POLICY_SHARD") == "${{ matrix.shard }}",
      "the matrix shard must reach the gate through env, not through shell interpolation")
check(failures, gate_step["run"].to_s.strip == 'tests/validate-policy.sh "$POLICY_SHARD"',
      "the gate step must pass the shard as the gate's one argument, found " \
      "#{gate_step['run'].to_s.strip.inspect}")
check(failures, !gate_step["run"].to_s.include?("${{ matrix"),
      "the gate step must not interpolate a matrix value into shell source")

# `sh -n` parses only its first argument, so the batched form checked one file of
# 98 (#634): assert a per-script loop, a shebang-chosen parser and a surviving status.
syntax_steps = static_steps.select { |step| step["run"].to_s.include?("-name '*.sh'") }
check(failures, syntax_steps.length == 1,
      "static must have exactly one shell syntax sweep, found #{syntax_steps.length}")
# Comments stripped: the step's own comment names the batched form.
syntax_sweep = (syntax_steps.first || {})["run"].to_s
                                             .lines.reject { |line| line.strip.start_with?("#") }.join
check(failures, !syntax_sweep.include?("-exec sh -n"),
      "the shell syntax sweep must not batch scripts into one `sh -n`: it parses only its " \
      "first argument, so a batched sweep checks one file and passes over the rest")
check(failures, syntax_sweep.match?(/while\s+IFS=\s*read\s+-r/),
      "the shell syntax sweep must loop over the scripts one at a time")
check(failures, syntax_sweep.include?("head -n 1"),
      "the shell syntax sweep must choose the parser from each script's shebang")
check(failures,
      syntax_sweep.include?('bash -n "$script"') && syntax_sweep.include?('sh -n "$script"'),
      "the shell syntax sweep must invoke a parser on one named script at a time")
check(failures, syntax_sweep.match?(/exit\s+"\$status"/),
      "the shell syntax sweep must report a parse failure: find and a bare loop both exit 0 " \
      "regardless of what the parser said")

static_commands = run_steps(static)
check(failures, static_commands.include?("tests/validate-policy.sh"),
      "static checks must retain \"tests/validate-policy.sh\"")
# Assert each package is installed rather than the exact apt invocation, so adding
# flags (retries, timeouts) to a fetch that has stalled in CI does not fail this.
%w[apache2-utils openssh-client openssl].each do |package|
  check(failures,
        static_commands.match?(/apt-get[^\n]*install[^\n]*#{Regexp.escape(package)}/),
        "static checks must install #{package}")
end
check(failures, static_commands.include?('python3 -m venv "$RUNNER_TEMP/ansible"'),
      "static checks must create an isolated Ansible environment")
# Installs from the lock rather than naming versions.
check(failures,
      static_commands.include?('"$RUNNER_TEMP/ansible/bin/pip" install --require-hashes -r controller-requirements.txt'),
      "static checks must install the controller pins in the isolated environment")
check(failures, static_commands.include?('echo "$RUNNER_TEMP/ansible/bin" >> "$GITHUB_PATH"'),
      "static checks must expose only the isolated pinned Ansible tools")
# --no-cache: a Galaxy cache entry left blank by a dead run is refused for a day.
check(failures, static_commands.include?(
        '"$RUNNER_TEMP/ansible/bin/ansible-galaxy" collection install --no-cache -r requirements.yml'
      ), "static checks must install collections with the isolated pinned Ansible tools")
check(failures, !static_commands.include?("python3 tests/deployment_target_validator_test.py"),
      "static must not duplicate the deployment validator already run by validate-policy.sh")

policy_source = File.read(POLICY_PATH)

# #653's moved checks: registered once in the gate, absent from `static`.
GATE_ADOPTED_CHECKS.each do |command|
  check(failures, registers_command_once?(policy_source, command),
        "tests/validate-policy.sh must register #{command.inspect} exactly once: it left " \
        "the static job so that it runs once rather than once per shard, and the manifest " \
        "is now the only thing that runs it")
  # Whole-line compare: the basename could match a comment in joined run text.
  check(failures, static_commands.lines.map(&:strip).none? { |line| line == command },
        "static must not also run #{command.inspect}: the gate runs it once, and a step here " \
        "restores the per-shard triplication")
end

# The lint job (#653): pinned steps, none conditional, moved checks still invoked.
lint_job = jobs.fetch("lint", {})
lint_steps = Array(lint_job["steps"])
check(failures, lint_job["needs"] == "changes", "lint must depend only on changes")
# Same output as the gate: lint and syntax checks read every play and role.
check(failures, expression(lint_job["if"]) == "${{ needs.changes.outputs.static == 'true' }}",
      "lint must run whenever the policy gate does, found #{expression(lint_job['if']).inspect}")
check(failures, lint_job["strategy"].nil?,
      "the lint job holds the steps that do not vary by shard and must not declare a matrix: " \
      "a matrix here would reinstate exactly what moving them out of `static` removed")
check(failures, lint_steps.all?(Hash), "lint steps must all be mappings")
check(failures, lint_steps.map { |step| step["name"] } == LINT_STEP_NAMES,
      "lint steps differ: got #{lint_steps.map { |step| step['name'] }.inspect}, " \
      "expected #{LINT_STEP_NAMES.inspect}")
check(failures, lint_steps.none? { |step| step.key?("if") },
      "lint steps must be unconditional: the changes job is the only classifier, and a step " \
      "gated on anything else is a check that stopped running without the job reporting it")
lint_commands = run_steps(lint_job)
# Matched by shape: the version is Renovate-bumped, but it must stay pinned.
check(failures, lint_commands.match?(/renovate_pin=renovate@\d+\.\d+\.\d+/),
      "the lint job must pin the renovate-config-validator version")
check(failures, lint_commands.include?('npx --yes --package "$renovate_pin" renovate-config-validator --strict'),
      "the lint job must validate renovate.json against Renovate's own validator: parsing the " \
      "file and asserting hand-written properties both passed on the config that stopped " \
      "Renovate repository-wide (#775)")
# --strict: deprecations are warnings that exit zero (#842).
check(failures,
      lint_commands.lines.grep(/renovate-config-validator/).count { |line| line.include?("--strict") } == 1,
      "exactly one renovate-config-validator invocation must be --strict: the real check, " \
      "not the #775 plant, which must stay non-strict to prove the refusal is an error")
LINT_CHECK_COMMANDS.each do |command|
  check(failures, lint_commands.include?(command),
        "the lint job must retain #{command.inspect}")
  check(failures, !static_commands.include?(command),
        "static must no longer run #{command.inspect}: it moved to the lint job so that it " \
        "runs once rather than once per shard")
end
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
production_auto_deploy_commands = [
  'PYTHONDONTWRITEBYTECODE=1 "$ansible_python" -m unittest -v tests.production_auto_deploy_test',
  "ruby tests/production_auto_deploy_role_test.rb"
]
production_auto_deploy_commands.each do |command|
  check(failures, registers_command_once?(policy_source, command),
        "validate-policy.sh must register exactly once #{command.inspect}")
end

# The docs job must stay cheap: no Ansible toolchain or container.
docs_job = jobs.fetch("docs", {})
docs_steps = Array(docs_job["steps"])
check(failures, docs_job["needs"] == "changes", "docs must depend only on changes")
check(failures, expression(docs_job["if"]) == "${{ needs.changes.outputs.docs == 'true' }}",
      "docs must be gated on its own classifier output, found " \
      "#{expression(docs_job['if']).inspect}")
check(failures, docs_job["strategy"].nil?, "the docs job is one runner and must not declare a matrix")
check(failures, docs_steps.all?(Hash), "docs steps must all be mappings")
check(failures, docs_steps.map { |step| step["name"] } == DOCS_STEP_NAMES,
      "docs steps differ: got #{docs_steps.map { |step| step['name'] }.inspect}, " \
      "expected #{DOCS_STEP_NAMES.inspect}")
check(failures, docs_steps.none? { |step| step.key?("if") },
      "docs steps must be unconditional: the changes job is the only classifier")
docs_commands = normalize_shell(run_steps(docs_job)).lines(chomp: true)
check(failures, docs_commands == DOCS_CHECK_COMMANDS,
      "the docs job must run exactly the documentation checks, found #{docs_commands.inspect}")
check(failures, docs_commands.none? { |command| command.match?(/ansible|apt-get|docker/) },
      "the docs job must stay a checkout and Ruby: #{docs_commands.inspect}")
check(failures, Array(docs_job["steps"]).count { |step| step["uses"] } == 1,
      "the docs job must use only the pinned checkout action")
# Docs checks also stay in the gate: a renamed role file breaks links without
# selecting `docs`.
DOCS_CHECK_COMMANDS.each do |command|
  check(failures, registers_command_once?(policy_source, command),
        "validate-policy.sh must still register #{command.inspect}: the docs job runs it " \
        "for a documentation change, the gate runs it for everything else")
end

# The vault job holds the only secret that opens the repository's credentials.
vault_job = jobs.fetch("vault", {})
vault_steps = Array(vault_job["steps"])
check(failures, vault_job["needs"] == "changes", "vault must depend only on changes")
check(failures, expression(vault_job["if"]) == "${{ needs.changes.outputs.vault == 'true' }}",
      "vault must be gated on its own classifier output, found " \
      "#{expression(vault_job['if']).inspect}")
check(failures, vault_job["strategy"].nil?, "the vault job is one runner and must not declare a matrix")
check(failures, vault_steps.map { |step| step["name"] } == VAULT_STEP_NAMES,
      "vault steps differ: got #{vault_steps.map { |step| step['name'] }.inspect}, " \
      "expected #{VAULT_STEP_NAMES.inspect}")
check(failures,
      vault_steps.none? { |step| %w[if continue-on-error].any? { |key| step.key?(key) } },
      "vault steps must be unconditional and must fail the job: `secrets` is not in scope for a " \
      "job-level or step-level condition anyway, a skipped step here is a green run that " \
      "decrypted nothing, and `continue-on-error` on the play is the same green run with the " \
      "decryption attempted and its verdict thrown away")
check(failures, !vault_job.key?("continue-on-error"),
      "the vault job must not tolerate its own failure: this is the only job that opens the " \
      "vault, so a tolerated failure is a merge of a vault the NAS cannot parse")
vault_play_steps = vault_steps.select { |step| step["run"].to_s.include?(VAULT_PLAYBOOK) }
check(failures, vault_play_steps.length == 1,
      "vault must run #{VAULT_PLAYBOOK} from exactly one step")
vault_play = vault_play_steps.first || {}
# The poller's own first invocation, derived rather than restated. A failure to
# derive it is a failure here: an empty expectation would pin nothing and pass.
poller, poller_error = poller_vault_invocation
check(failures, poller_error.nil?,
      "this check must be able to read the poller's own argv out of " \
      "#{POLLER_SCRIPT_PATH.inspect}; deriving it failed with #{poller_error.inspect}, which " \
      "leaves the vault job's argv pinned against nothing")
expected_vault_argv = Array(poller && poller["invocations"]).first
check(failures, Array(expected_vault_argv).first == "ansible-playbook" &&
                Array(expected_vault_argv).last == VAULT_PLAYBOOK,
      "the poller's first play must still be ansible-playbook ... #{VAULT_PLAYBOOK}; " \
      "_deploy_invocations builds #{expected_vault_argv.inspect} first, so either the play order " \
      "moved or there is nothing here for the vault job to mirror")
check(failures,
      expected_vault_argv == ["ansible-playbook", *Array(poller && poller["vault_arguments"]),
                              VAULT_PLAYBOOK],
      "the poller's first play must carry _vault_arguments and nothing else; it builds " \
      "#{expected_vault_argv.inspect} from #{Array(poller && poller['vault_arguments']).inspect}")
# Exact argv, not fragments: --list-* or --syntax-check exit 0 without parsing the
# vault. --check does decrypt, but is refused because the poller does not run it.
check(failures, shell_invocation(vault_play["run"], "ansible-playbook") == expected_vault_argv,
      "the vault play must invoke exactly the poller's own argv. The poller builds " \
      "#{expected_vault_argv.inspect}; the workflow runs " \
      "#{shell_invocation(vault_play['run'], 'ansible-playbook').inspect}. Any difference is a " \
      "job that proves something other than what the host does -- a different inventory binds " \
      "different group_vars, and an inserted --syntax-check or --list-tasks exits 0 without " \
      "parsing the vault at all")
check(failures, vault_play.dig("env", VAULT_PASSWORD_ENV) == "${{ secrets.#{VAULT_PASSWORD_SECRET} }}",
      "the vault play must take the password from secrets.#{VAULT_PASSWORD_SECRET} through env")
check(failures, vault_play["run"].to_s.include?(%(if [ -z "$#{VAULT_PASSWORD_ENV}" ])) &&
                vault_play["run"].to_s.include?("exit 1"),
      "the vault play must fail loudly on an absent or empty secret rather than skipping: " \
      "`secrets` is not readable from a job-level `if:`, so the guard has to be a step")
check(failures, vault_play["run"].to_s.include?(VAULT_PASSWORD_SECRET),
      "the refusal must name #{VAULT_PASSWORD_SECRET}, which is the one thing an operator has to set")
check(failures, vault_play["run"].to_s.include?("umask 077"),
      "the vault password file must be created under a restrictive umask, not chmodded afterwards")
check(failures, vault_play["run"].to_s.include?('> "$RUNNER_TEMP/vault-password"'),
      "the vault password file must be written under $RUNNER_TEMP, never into the checkout: a " \
      "relative target puts the repository's own credentials inside the tree the job checked out")
# pull_request_target would hand this secret to any pull request author.
check(failures, !triggers.to_h.key?("pull_request_target"),
      "the workflow must not use pull_request_target while a job holds the vault password")

validate = jobs.fetch("validate", {})
check(failures, validate["name"] == "validate", "aggregate check name must remain validate")
check(failures, expression(validate["if"]) == "${{ always() }}", "validate must always run")
expected_needs = %w[changes static lint docs vault mutation reconciliation toolchain suites]
check(failures, Array(validate["needs"]) == expected_needs,
      "validate must need changes, static, lint, docs, the vault validation, mutation, " \
      "reconciliation, the toolchain publish and the suite matrix " \
      "in canonical order")
validate_checkout = Array(validate["steps"]).find { |step| step["uses"]&.start_with?("actions/checkout@") }
check(failures, validate_checkout&.fetch("uses", nil).to_s.split("@").first == CHECKOUT_ACTION_NAME,
      "validate must check out the repository with the pinned action")
validate_commands = run_steps(validate)
expected_needs.each do |job_id|
  check(failures,
        validate_commands.include?(%(#{job_id}="${{ needs.#{job_id}.result }}")),
        "validate must pass the #{job_id} result to validate_results.rb")
end
check(failures, validate_commands.include?("ruby tests/ci/validate_results.rb"),
      "validate must invoke the aggregate result validator")

# Run from `validate` (always()) as well as the gate, because every attack on
# `static` also stops the gate running this file (#480). Keep both copies.
workflow_guard_command = "ruby tests/ci/workflow_test.rb"
check(failures, validate_commands.include?(workflow_guard_command),
      "validate must invoke the workflow-shape guard directly: run only from the policy gate, " \
      "#{workflow_guard_command.inspect} is a check inside the job it pins, so disabling " \
      "`static` removes its own objection")
check(failures, registers_command_once?(policy_source, workflow_guard_command),
      "validate-policy.sh must still register #{workflow_guard_command.inspect} exactly once: " \
      "the validate job runs it for the workflow's shape, the gate runs it for every other " \
      "change, and moving it out of the gate is not the same fix as running it in both places")
check(failures,
      Array(validate["steps"]).none? do |step|
        step.is_a?(Hash) && %w[if continue-on-error].any? { |key| step.key?(key) }
      end,
      "validate steps must be unconditional and must fail the job: this is the route that " \
      "cannot be skipped, and a step gated on another job's result -- or one whose failure is " \
      "tolerated -- restores exactly the hole this job's copy of the guard closes")
# `needs.<job>.result` for a matrix is the aggregate of its legs, so one entry covers
# every shard; a short matrix is caught by the shard assertion above instead.
check(failures, !ValidateResults::NON_BLOCKING_JOBS.include?("static"),
      "static must stay blocking: it is the aggregate of every policy shard, and tolerating " \
      "its result would let a failed shard reach main green")

# Non-blocking jobs are derived from the suites condition (#360), so the validator
# and the workflow cannot disagree.
suites_condition = expression(suites_job["if"]).to_s
derived_non_blocking = Array(suites_job["needs"]).reject do |job|
  suites_condition.include?("needs.#{job}.result == 'success'")
end
# Without !cancelled() every `needs` entry gates on success regardless.
check(failures, derived_non_blocking.empty? || suites_condition.include?("!cancelled()"),
      "a job the suites matrix needs is non-blocking only while the condition drops " \
      "the implicit success gate with !cancelled(), found #{suites_condition.inspect}")
check(failures, derived_non_blocking == ValidateResults::NON_BLOCKING_JOBS,
      "tests/ci/validate_results.rb must tolerate exactly the jobs the suites matrix " \
      "depends on without requiring their success: the workflow declares " \
      "#{derived_non_blocking.inspect} non-blocking, the validator tolerates " \
      "#{ValidateResults::NON_BLOCKING_JOBS.inspect}")
# A tolerated job nothing reports is a tolerance that can never be exercised.
check(failures, (ValidateResults::NON_BLOCKING_JOBS - expected_needs).empty?,
      "every non-blocking job must be one validate passes to the validator, " \
      "#{(ValidateResults::NON_BLOCKING_JOBS - expected_needs).inspect} is not")

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
all_uses.each do |uses|
  name, commit = uses.split("@", 2)
  check(failures, ALLOWED_ACTION_NAMES.include?(name),
        "every action use must be an approved action: #{uses.inspect}")
  check(failures, commit.to_s.match?(/\A[0-9a-f]{40}\z/),
        "every action use must be pinned to a full commit SHA, not a tag: #{uses.inspect}")
end
# One action must not be pinned to two different commits across jobs.
all_uses.group_by { |uses| uses.split("@", 2).first }.each do |name, uses|
  check(failures, uses.uniq.length == 1,
        "#{name} must be pinned to one commit across every job: #{uses.uniq.inspect}")
end

# controller-requirements.in is the one place versions are authored (#827); the
# ansible-core mirrors below must agree. Fails loudly if the anchor is unreadable.
controller_source = File.file?(CONTROLLER_REQUIREMENTS_SOURCE_PATH) ? File.read(CONTROLLER_REQUIREMENTS_SOURCE_PATH) : ""
expected_core = controller_source[/^ansible-core==(\d+\.\d+\.\d+)$/, 1]
expected_lint = controller_source[/^ansible-lint==(\d+\.\d+\.\d+)$/, 1]
check(failures, !expected_core.nil?,
      "controller-requirements.in must pin ansible-core exactly, as ansible-core==X.Y.Z")
# Nothing mirrors the lint pin, but every job installs it, so an unpinned
# ansible-lint would float the gate's lint results release by release.
check(failures, !expected_lint.nil?,
      "controller-requirements.in must pin ansible-lint exactly, as ansible-lint==X.Y.Z")
# Every source line is an exact pin, and there must be some.
source_lines = controller_source.lines.map(&:strip).reject { |line| line.empty? || line.start_with?("#") }
check(failures, source_lines.length >= 3,
      "controller-requirements.in must list the controller requirements, found #{source_lines.length}")
source_pins = {}
source_lines.each do |line|
  match = line.match(/\A(?<name>[A-Za-z0-9][A-Za-z0-9._-]*)==(?<version>\d+(\.\d+)*)\z/)
  check(failures, !match.nil?,
        "controller-requirements.in must pin every requirement exactly: #{line.inspect}")
  source_pins[match[:name].downcase.tr("_.", "--")] = match[:version] if match
end

# The lock (#827): exact pins, a --hash on every entry (one unhashed line fails every
# install), every .in pin present, and a --python-version floor equal to .python-version.
CONTROLLER_LOCK_ENTRY = /\A(?<name>[A-Za-z0-9][A-Za-z0-9._-]*)==(?<version>[0-9][A-Za-z0-9.+!-]*)(?: *; *[^\\]+?)?(?<hashes>(?: +--hash=sha256:[0-9a-f]{64})*)\z/
def controller_lock_violations(lock, source_pins, python_floor)
  violations = []
  header = lock[/^#\s+uv pip compile (.*)$/, 1]
  violations << "the lock must carry the uv pip compile header Renovate regenerates it from" unless header
  if header
    violations << "the lock header must pass --generate-hashes" unless header.split.include?("--generate-hashes")
    violations << "the lock header must pass --universal" unless header.split.include?("--universal")
    violations << "the lock header must compile controller-requirements.in" unless header.split.include?("controller-requirements.in")
    floor = header[/--python-version=(\S+)/, 1]
    violations << "the lock header's --python-version=#{floor.inspect} must equal .python-version #{python_floor.inspect}" unless floor == python_floor
  end
  entries = lock.gsub(/\\\n/, " ").lines.map { |line| line.sub(/#.*/, "").strip }.reject(&:empty?)
  violations << "the lock must list the resolved controller toolchain, found #{entries.length} entries" if entries.length < 20
  locked = {}
  entries.each do |entry|
    match = entry.match(CONTROLLER_LOCK_ENTRY)
    if match.nil?
      violations << "every lock entry must be an exact == pin: #{entry[0, 80].inspect}"
    elsif match[:hashes].strip.empty?
      violations << "every lock entry must carry a --hash: #{match[:name]}"
    else
      locked[match[:name].downcase.tr("_.", "--")] = match[:version]
    end
  end
  source_pins.each do |name, version|
    next if locked[name] == version

    violations << "controller-requirements.in pins #{name}==#{version} but the lock holds " \
                  "#{locked[name].inspect}; recompile the lock"
  end
  violations
end

controller_lock = File.read(CONTROLLER_REQUIREMENTS_PATH)
python_floor = File.read(PYTHON_VERSION_PATH).strip
# The lock floor must not exceed the poller role's minimum, or the NAS refuses it.
nas_floor = File.read(File.expand_path("../../roles/production_auto_deploy/tasks/main.yml", __dir__))[
  /python_version is version\('(\d+\.\d+)', '>='\)/, 1
]
check(failures, !nas_floor.nil?,
      "roles/production_auto_deploy/tasks/main.yml must assert the NAS's minimum Python version")
lock_floor = controller_lock[/--python-version=(\d+\.\d+)/, 1]
check(failures, nas_floor && lock_floor && Gem::Version.new(lock_floor) <= Gem::Version.new(nas_floor),
      "controller-requirements.txt is compiled for Python #{lock_floor.inspect} and up, above the " \
      "#{nas_floor.inspect} the NAS poller accepts; a host on that floor would refuse the lock")
controller_lock_violations(controller_lock, source_pins, python_floor).each do |violation|
  check(failures, false, "controller-requirements.txt: #{violation}")
end

# The checker is shown each defect it exists for before its silence on the real
# lock is trusted, each plant a one-line edit of the real file.
first_hash = controller_lock[/ \\\n\s+--hash=sha256:\h{64}/]
core_line = controller_lock[/^ansible-core==\S+/]
{
  "an entry that lost its hashes" =>
    controller_lock.sub(/^(pyyaml==\S+)(?: \\\n\s+--hash=sha256:\h{64})+/, '\\1'),
  "an entry that is a range rather than a pin" => controller_lock.sub(/^pyyaml==/, "pyyaml>="),
  "a top-level pin the lock was never recompiled for" =>
    controller_lock.sub(core_line.to_s, "ansible-core==0.0.1"),
  "a header whose floor is not .python-version" =>
    controller_lock.sub("--python-version=#{python_floor}", "--python-version=3.99"),
  "an unhashed entry appended by hand" => "#{controller_lock}\nsomething==1.0\n"
}.each do |defect, planted|
  check(failures, !first_hash.nil? && planted != controller_lock &&
                  !controller_lock_violations(planted, source_pins, python_floor).empty?,
        "the controller lock checker must refuse #{defect}")
end

if expected_core
  {
    "tests/integration.sh" => /^ansible_core_version=(\d+\.\d+\.\d+)$/,
    "tests/beszel_telemetry_ansible_test.rb" => /^REQUIRED_ANSIBLE_CORE = "(\d+\.\d+\.\d+)"/
  }.each do |relative, pattern|
    mirrored = File.read(File.expand_path("../../#{relative}", __dir__))[pattern, 1]
    check(failures, mirrored == expected_core,
          "#{relative} must pin ansible-core #{expected_core} to match " \
          "controller-requirements.in, got #{mirrored.inspect}")
  end
end


# Docker Hub: the same retried login before every job's first pull, and a retried
# pre-pull of the image the static shards' cleanup tests run. Both loops are run
# against a stubbed docker under `bash -e`, `sleep` and `timeout` recording.
docker_hub_logins = DOCKER_HUB_LOGIN_JOBS.to_h do |name|
  [name, Array(jobs.dig(name, "steps")).find { |step| step.is_a?(Hash) && step["name"] == DOCKER_HUB_LOGIN_STEP }]
end
docker_hub_logins.each do |name, step|
  check(failures, !step.nil?, "the #{name} job must run #{DOCKER_HUB_LOGIN_STEP.inspect}")
  next unless step

  check(failures, step.dig("env") == {
    DOCKER_HUB_USERNAME_SECRET => "${{ secrets.#{DOCKER_HUB_USERNAME_SECRET} }}",
    DOCKER_HUB_TOKEN_SECRET => "${{ secrets.#{DOCKER_HUB_TOKEN_SECRET} }}"
  }, "the #{name} job's Docker Hub login must read exactly the stored account and token, " \
     "found #{step['env'].inspect}")
  check(failures, !step.key?("if") && !step.key?("uses"),
        "the #{name} job's Docker Hub login must be an unconditional run step that skips itself")
  steps = Array(jobs.dig(name, "steps"))
  first_pull = steps.index do |item|
    item.is_a?(Hash) && item["run"].to_s.match?(%r{tests/(?:validate-policy|integration)\.sh})
  end
  check(failures, first_pull && steps.index(step) < first_pull,
        "the #{name} job's Docker Hub login must precede the step that pulls images")
end
check(failures, docker_hub_logins.values.compact.map { |step| step["run"] }.uniq.length == 1,
      "#{DOCKER_HUB_LOGIN_STEP.inspect} must be byte-identical across #{DOCKER_HUB_LOGIN_JOBS.inspect}")

def run_docker_retry(script, succeed_on, env = {})
  Dir.mktmpdir("ci-docker-retry-") do |root|
    stub = File.join(root, "bin", "docker")
    FileUtils.mkdir_p(File.dirname(stub))
    File.write(stub, <<~SH)
      #!/bin/sh
      count=$(( $(cat "$STUB_ROOT/calls" 2>/dev/null || echo 0) + 1 ))
      echo "$count" >"$STUB_ROOT/calls"
      printf '%s\\n' "$*" >>"$STUB_ROOT/argv"
      cat >>"$STUB_ROOT/stdin"
      [ "$count" -ge #{succeed_on} ] && exit 0
      echo "stub docker: auth.docker.io 500 (call $count)" >&2
      exit 1
    SH
    File.chmod(0o755, stub)
    prelude = %(sleep() { printf '%s\\n' "$1" >>"$STUB_ROOT/sleeps"; }\n) +
              %(timeout() { printf '%s\\n' "$1" >>"$STUB_ROOT/bounds"; shift; "$@"; }\n)
    stdout, stderr, status = Open3.capture3(
      { "STUB_ROOT" => root, "PATH" => "#{File.dirname(stub)}:#{ENV.fetch('PATH')}" }.merge(env),
      "bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", "#{prelude}#{script}\necho reached-end\n",
      chdir: ROOT, stdin_data: ""
    )
    read = ->(file) { File.file?(File.join(root, file)) ? File.read(File.join(root, file)) : "" }
    { success: status.success?, stdout: stdout, stderr: stderr, calls: read.call("calls").to_i,
      argv: read.call("argv").lines.map(&:chomp), stdin: read.call("stdin"),
      sleeps: read.call("sleeps").split, bounds: read.call("bounds").split }
  end
end

if (login_script = docker_hub_logins.values.compact.first&.fetch("run", nil))
  account = { DOCKER_HUB_USERNAME_SECRET => "ci-account", DOCKER_HUB_TOKEN_SECRET => "stub-token" }
  skipped = run_docker_retry(login_script, 1, DOCKER_HUB_USERNAME_SECRET => "", DOCKER_HUB_TOKEN_SECRET => "")
  check(failures, skipped[:success] && skipped[:calls].zero? && skipped[:stdout].include?("::notice::"),
        "a Docker Hub login without the secret (a fork) must skip with a notice and call docker " \
        "not at all, got #{skipped.inspect}")
  first = run_docker_retry(login_script, 1, account)
  check(failures, first[:success] && first[:calls] == 1 && first[:sleeps].empty? &&
                  first[:stdout].include?("reached-end") && first[:stdin] == "stub-token" &&
                  first[:argv] == ["login docker.io --username ci-account --password-stdin"] &&
                  first[:bounds] == %w[60],
        "a Docker Hub login that succeeds at once must run once, bounded, with the token on " \
        "stdin and never in argv, got #{first.inspect}")
  last = run_docker_retry(login_script, 4, account)
  check(failures, last[:success] && last[:calls] == 4 && last[:sleeps] == DOCKER_RETRY_SLEEPS &&
                  last[:stdout].include?("reached-end"),
        "a Docker Hub login that fails three times must pass on the fourth attempt after backing " \
        "off #{DOCKER_RETRY_SLEEPS.inspect}, got #{last.inspect}")
  never = run_docker_retry(login_script, 99, account)
  check(failures, !never[:success] && never[:calls] == 4 && !never[:stdout].include?("reached-end") &&
                  never[:stderr].include?("(call 4)") && never[:stderr].include?("::error::"),
        "a Docker Hub login that always fails must red the step after exactly four attempts with " \
        "the last error visible, got #{never.inspect}")
end

static_steps_by_name = static_steps.select { |step| step.is_a?(Hash) }.to_h { |step| [step["name"], step] }
prepull = static_steps_by_name.fetch(STATIC_PREPULL_STEP, {})
check(failures, !prepull.key?("if") && !prepull.key?("env"),
      "#{STATIC_PREPULL_STEP.inspect} must be unconditional and read no secret")
# The refs the cleanup tests run, read the way the step reads them.
cleanup_refs = {
  "tests/sandbox_cleanup.sh" => "cleanup_sandbox_image", "tests/integration_cleanup_test.sh" => "runner_image"
}.flat_map do |file, variable|
  File.readlines(File.join(ROOT, file)).filter_map { |line| line[/^#{variable}=(\S+)$/, 1] }
end.uniq.sort
check(failures, cleanup_refs.length >= 1 && cleanup_refs.all? { |ref| ref.match?(/@sha256:\h{64}\z/) },
      "the cleanup sandbox image refs must be digest-pinned and readable, found #{cleanup_refs.inspect}")
if (prepull_script = prepull["run"])
  pulled = run_docker_retry(prepull_script, 2)
  check(failures, pulled[:success] && pulled[:sleeps] == DOCKER_RETRY_SLEEPS.first(1) &&
                  pulled[:argv].uniq == cleanup_refs.map { |ref| "pull #{ref}" } &&
                  pulled[:bounds].uniq == %w[300],
        "the pre-pull must pull exactly #{cleanup_refs.inspect}, bounded, retrying a failure, " \
        "got #{pulled.inspect}")
  never = run_docker_retry(prepull_script, 99)
  check(failures, !never[:success] && never[:calls] == 4 && never[:stderr].include?("::error::") &&
                  !never[:stdout].include?("reached-end"),
        "a pre-pull that always fails must red the step after exactly four attempts, got #{never.inspect}")
end

report(failures, "CI workflow contract: all checks passed",
       "workflow contract failure(s)")
