#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"

ROOT = File.expand_path("..", __dir__)
WORKFLOW = File.join(ROOT, ".github/workflows/ci.yml")
SUCCESS = "CI workflow: required job and docs-only boundary hold"
CHECKOUT_ACTION = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
FULL_STEPS = [
  ["Validate shell syntax", "find tests -type f -name '*.sh' -exec sh -n {} +"],
  ["Check policy properties", "tests/validate-policy.sh"],
  ["Check integration sandbox cleanup", "tests/integration_cleanup_test.sh"],
  ["Install Ansible tooling", "ansible-core==2.21.2"],
  ["Check legacy role Compose compatibility", "tests/mac/legacy-role-compose-test.sh"],
  ["Check legacy parity rendering", "tests/mac/adoption-render-test.sh"],
  ["Check Immich probe status rendering", "tests/immich_probe_status_test.py"],
  ["Check generated credential redaction", "tests/generate-secrets-redaction-test.sh"],
  ["Check silent ephemeral vault generation", "tests/generate-ephemeral-vault.sh --self-test"],
  ["Lint Ansible", "ansible-lint --strict"],
  ["Check playbook syntax", "ansible-playbook -i inventory/local.yml site.yml --syntax-check"],
  ["Converge against a disposable sandbox", "tests/integration.sh site.yml"]
].freeze
CLASSIFIER_RUN = <<~'SH'.chomp
  case "$EVENT_NAME" in
    pull_request) base_sha=$PR_BASE_SHA ;;
    push) base_sha=$PUSH_BEFORE_SHA ;;
    *) base_sha= ;;
  esac
  if ! printf '%s' "$base_sha" | grep -Eq '^[0-9a-f]{40}$' ||
     printf '%s' "$base_sha" | grep -Eq '^0{40}$'; then
    printf 'docs_only=false\nchanged_count=0\n' >> "$GITHUB_OUTPUT"
  else
    git diff --name-only -z "$base_sha" "$GITHUB_SHA" |
      ruby tests/ci_change_scope.rb >> "$GITHUB_OUTPUT"
  fi
SH

def fail_contract(message)
  raise "workflow: #{message}"
end

def sanitize(value)
  value.to_s.gsub(/[[:cntrl:]]/, "?")
end

def mapping(value, label)
  fail_contract("#{label} must be a mapping") unless value.is_a?(Hash)

  value
end

def array(value, label)
  fail_contract("#{label} must be a list") unless value.is_a?(Array)

  value
end

def key?(mapping, key)
  mapping.key?(key) || mapping.key?(key.to_sym)
end

def value_for(mapping, key)
  mapping[key] || mapping[key.to_sym]
end

def workflow_triggers(document)
  document["on"] || document[true] || document[:on]
end

def contains_path_filter?(value)
  case value
  when Hash
    value.any? do |key, child|
      %w[paths paths-ignore].include?(key.to_s) || contains_path_filter?(child)
    end
  when Array
    value.any? { |child| contains_path_filter?(child) }
  else
    false
  end
end

def load_workflow(source)
  YAML.safe_load(source, aliases: true)
rescue Psych::Exception => error
  fail_contract("YAML is malformed (#{sanitize(error.message)})")
end

def assert_no_path_filters(source, document)
  fail_contract("contains forbidden path filter") if source.match?(/^\s*[\"']?paths(?:-ignore)?[\"']?\s*:/)
  fail_contract("contains forbidden path filter") if contains_path_filter?(workflow_triggers(document))
end

def assert_triggers(document)
  triggers = mapping(workflow_triggers(document), "workflow triggers")
  pull_request = value_for(triggers, "pull_request")
  unless key?(triggers, "pull_request") && (pull_request.nil? || (pull_request.is_a?(Hash) && pull_request.empty?))
    fail_contract("requires an unfiltered pull_request trigger")
  end

  push = value_for(triggers, "push")
  unless key?(triggers, "push") && push.is_a?(Hash) && push.keys.map(&:to_s) == ["branches"] && value_for(push, "branches") == ["main"]
    fail_contract("push must be restricted to main")
  end
end

def named_steps(steps, name)
  steps.select { |step| step.is_a?(Hash) && value_for(step, "name") == name }
end

def one_step(steps, name)
  matches = named_steps(steps, name)
  fail_contract("requires exactly one #{name.inspect} step") unless matches.length == 1

  matches.first
end

def assert_unconditional(step, name)
  fail_contract("#{name} must be unconditional") if key?(step, "if")
end

def assert_checkout(steps)
  checkout = one_step(steps, "Check out repository")
  assert_unconditional(checkout, "checkout")
  fail_contract("checkout action pin changed") unless value_for(checkout, "uses") == CHECKOUT_ACTION
  fail_contract("checkout action is duplicated") unless steps.count { |step| value_for(step, "uses") == CHECKOUT_ACTION } == 1
  options = mapping(value_for(checkout, "with"), "checkout options")
  fail_contract("checkout must fetch complete history") unless value_for(options, "fetch-depth") == 0

  checkout
end

def assert_classifier(steps)
  matches = steps.select { |step| step.is_a?(Hash) && value_for(step, "id") == "scope" }
  fail_contract("requires exactly one scope classifier") unless matches.length == 1

  classifier = matches.first
  assert_unconditional(classifier, "scope classifier")
  env = mapping(value_for(classifier, "env"), "scope classifier environment")
  expected_env = {
    "EVENT_NAME" => "${{ github.event_name }}",
    "PR_BASE_SHA" => "${{ github.event.pull_request.base.sha }}",
    "PUSH_BEFORE_SHA" => "${{ github.event.before }}"
  }
  fail_contract("scope classifier environment changed") unless env == expected_env
  run = value_for(classifier, "run")
  fail_contract("scope classifier must run a shell script") unless run.is_a?(String)
  normalized_run = run.end_with?("\n") ? run.delete_suffix("\n") : run
  fail_contract("scope classifier script changed") unless normalized_run == CLASSIFIER_RUN

  classifier
end

def assert_docs_step(steps)
  docs = one_step(steps, "Validate documentation")
  fail_contract("docs validation command changed") unless value_for(docs, "run") == "tests/validate-docs.sh"
  fail_contract("docs validation must use the docs-only guard") unless value_for(docs, "if") == "steps.scope.outputs.docs_only == 'true'"

  docs
end

def assert_full_steps(steps)
  positions = FULL_STEPS.map do |name, command|
    step = one_step(steps, name)
    fail_contract("#{name} must use the full-validation guard") unless value_for(step, "if") == "steps.scope.outputs.docs_only != 'true'"
    run = value_for(step, "run")
    fail_contract("#{name} command changed") unless run.is_a?(String) && run.include?(command)
    steps.index(step)
  end
  fail_contract("full validation steps are out of order") unless positions == positions.sort
  all_commands = steps.filter_map { |step| value_for(step, "run") if step.is_a?(Hash) }.join("\n")
  FULL_STEPS.each do |name, command|
    fail_contract("#{name} command is duplicated") unless all_commands.scan(Regexp.new(Regexp.escape(command))).length == 1
  end

  positions
end

def assert_boundary(steps, checkout, classifier, docs, full_positions)
  checkout_index = steps.index(checkout)
  classifier_index = steps.index(classifier)
  docs_index = steps.index(docs)
  fail_contract("checkout must be the first validation step") unless checkout_index.zero?
  fail_contract("scope classifier must immediately follow checkout") unless classifier_index == checkout_index + 1
  fail_contract("docs validation must immediately follow classification") unless docs_index == classifier_index + 1
  fail_contract("full validation must follow docs validation") unless full_positions.first == docs_index + 1

  executable = steps[(classifier_index + 1)..].select do |step|
    step.is_a?(Hash) && (key?(step, "run") || key?(step, "uses"))
  end
  allowed_names = ["Validate documentation", *FULL_STEPS.map(&:first)]
  fail_contract("contains an unexpected executable step after classification") unless executable.all? { |step| allowed_names.include?(value_for(step, "name")) }
end

def validate_workflow(source)
  document = mapping(load_workflow(source), "document")
  assert_no_path_filters(source, document)
  assert_triggers(document)
  jobs = mapping(value_for(document, "jobs"), "jobs")
  fail_contract("must contain only the validate job") unless jobs.keys.map(&:to_s) == ["validate"]
  job = mapping(value_for(jobs, "validate"), "validate job")
  fail_contract("validate job must not have a condition") if key?(job, "if")
  steps = array(value_for(job, "steps"), "validate steps")
  fail_contract("validate steps must contain only mappings") unless steps.all? { |step| step.is_a?(Hash) }
  checkout = assert_checkout(steps)
  classifier = assert_classifier(steps)
  docs = assert_docs_step(steps)
  full_positions = assert_full_steps(steps)
  assert_boundary(steps, checkout, classifier, docs, full_positions)
end

def assert_failure(label, source, message)
  begin
    validate_workflow(source)
  rescue RuntimeError => error
    raise "#{label}: expected #{message.inspect}, got #{error.message.inspect}" unless error.message.include?(message)
    return
  end
  raise "#{label}: expected validation to fail"
end

def replace_once(source, before, after)
  raise "fixture does not contain #{before.inspect}" unless source.include?(before)

  source.sub(before, after)
end

def self_test
  source = File.binread(WORKFLOW)
  triggers = "on:\n  pull_request:\n  push:\n    branches:\n      - main\n"
  render_step = <<~YAML.gsub(/^/, "      ")
    - name: Check legacy parity rendering
      if: steps.scope.outputs.docs_only != 'true'
      run: tests/mac/adoption-render-test.sh
  YAML
  validate_workflow(source)
  assert_failure("renamed job", replace_once(source, "  validate:\n", "  verify:\n"), "only the validate job")
  assert_failure("removed job", replace_once(source, "  validate:\n", "  inspect:\n"), "only the validate job")
  assert_failure("missing pull request", replace_once(source, "  pull_request:\n", "  schedule:\n"), "unfiltered pull_request")
  assert_failure("pull request branches", replace_once(source, "  pull_request:\n", "  pull_request:\n    branches:\n      - main\n"), "unfiltered pull_request")
  assert_failure("paths filter", replace_once(source, "  pull_request:\n", "  pull_request:\n    paths:\n      - docs/**\n"), "forbidden path filter")
  assert_failure("paths ignore filter", replace_once(source, "  pull_request:\n", "  pull_request:\n    paths-ignore:\n      - docs/**\n"), "forbidden path filter")
  assert_failure("missing push", replace_once(source, "  push:\n    branches:\n      - main\n", ""), "push must be restricted to main")
  assert_failure("push branch", replace_once(source, "      - main\n", "      - release\n"), "push must be restricted to main")
  assert_failure("fetch depth", replace_once(source, "fetch-depth: 0", "fetch-depth: 1"), "complete history")
  assert_failure("unconditional docs", replace_once(source, "        if: steps.scope.outputs.docs_only == 'true'\n", ""), "docs-only guard")
  assert_failure("unguarded full step", replace_once(source, "      - name: Validate shell syntax\n        if: steps.scope.outputs.docs_only != 'true'\n", "      - name: Validate shell syntax\n"), "full-validation guard")
  without_render = replace_once(source, render_step, "")
  assert_failure("missing legacy render", without_render, "Check legacy parity rendering")
  render_before_install = replace_once(
    without_render,
    "      - name: Install Ansible tooling\n",
    "#{render_step}\n      - name: Install Ansible tooling\n"
  )
  assert_failure("legacy render before Ansible", render_before_install, "out of order")
  assert_failure("extra job", replace_once(source, "jobs:\n", "jobs:\n  extra:\n    runs-on: ubuntu-latest\n    steps: []\n"), "only the validate job")
  assert_failure("malformed YAML", "jobs: [", "YAML is malformed")
  assert_failure("jobs shape", "#{triggers}jobs: []\n", "jobs must be a mapping")
  assert_failure("steps shape", "#{triggers}jobs:\n  validate:\n    steps: {}\n", "validate steps must be a list")
  assert_failure("scalar step", replace_once(source, "    steps:\n      - name: Check out repository", "    steps:\n      - 7\n      - name: Check out repository"), "validate steps must contain only mappings")
  assert_failure("classifier override", replace_once(source, "          fi\n\n      - name: Validate documentation", "          fi\n          printf 'docs_only=true\\n' >> \"$GITHUB_OUTPUT\"\n\n      - name: Validate documentation"), "scope classifier script changed")
end

if ARGV == ["--self-test"]
  self_test
  puts SUCCESS
  exit
end

abort "usage: ci_workflow_test.rb [--self-test]" unless ARGV.empty?

begin
  validate_workflow(File.binread(WORKFLOW))
  puts SUCCESS
rescue SystemCallError => error
  abort "CI workflow check: #{sanitize(error.message)}"
rescue RuntimeError => error
  abort "CI workflow check: #{sanitize(error.message)}"
end
