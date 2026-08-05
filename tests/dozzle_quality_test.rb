#!/usr/bin/env ruby
# Focused regression checks for predicate-sensitive Dozzle proof output.

require "open3"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
CONTRACT = File.join(ROOT, "tests", "contracts", "dozzle.sh")
ROLE = File.join(ROOT, "roles", "dozzle", "tasks", "main.yml")
failures = []

MARKERS = {
  "DOZZLE_PLAN_DISPATCHER_CREATE" => [0, 1],
  "DOZZLE_PLAN_DISPATCHER_REPAIR" => [1, 0],
  "DOZZLE_PLAN_RULE_CREATE" => [1, 4],
  "DOZZLE_PLAN_RULE_REPAIR" => [1, 0],
  "DOZZLE_PLAN_RULE_ENABLE_REPAIR" => [1, 0],
  "DOZZLE_PLAN_RULE_REMOVE" => [1, 0],
  "DOZZLE_PLAN_DISPATCHER_REMOVE" => [1, 0]
}.freeze

TASKS = [
  "Report planned managed Dozzle dispatcher creation",
  "Report planned managed Dozzle dispatcher repair",
  "Report planned managed Dozzle alert rule creation",
  "Report planned managed Dozzle alert rule repair",
  "Report planned managed Dozzle alert rule enabled-state repair",
  "Report planned unmanaged Dozzle alert rule removal",
  "Report planned unmanaged Dozzle dispatcher removal"
].freeze

def check(failures, condition, message)
  failures << message unless condition
end

def output_for(index)
  headers = TASKS.map { |task| "TASK [dozzle : #{task}]" }
  markers = MARKERS.flat_map { |marker, counts| [marker] * counts.fetch(index) }
  (headers + markers + ["nas : ok=1 changed=6 unreachable=0 failed=0 skipped=6 rescued=0 ignored=0"]).join("\n") + "\n"
end

def run_assertion(mode, output)
  Dir.mktmpdir("nas-platform-dozzle-quality-") do |directory|
    path = File.join(directory, "ansible-output.txt")
    File.write(path, output, mode: "w", perm: 0o600)
    Open3.capture3(CONTRACT, mode, path)
  end
end

%w[assert-check-mixed-output assert-check-missing-output].each_with_index do |mode, index|
  output = output_for(index)
  _stdout, stderr, status = run_assertion(mode, output)
  check(failures, status.success?, "#{mode} rejected exact marker counts: #{stderr.lines.first&.strip}")

  required_marker = MARKERS.find { |_marker, counts| counts.fetch(index).positive? }.fetch(0)
  missing_marker_output = output.sub(/^#{Regexp.escape(required_marker)}\n/, "")
  _stdout, _stderr, missing_status = run_assertion(mode, missing_marker_output)
  check(failures, !missing_status.success?,
        "#{mode} accepted a skipped predicate because its task header and global changed recap remained")

  duplicated_marker_output = output.sub(
    /^#{Regexp.escape(required_marker)}\n/,
    "#{required_marker}\n#{required_marker}\n"
  )
  _stdout, _stderr, duplicate_status = run_assertion(mode, duplicated_marker_output)
  check(failures, !duplicate_status.success?, "#{mode} accepted an incorrect per-category occurrence count")
end

contract = File.read(CONTRACT)
fixed_diagnostics = [
  "OOM drift fixture differs",
  "managed dispatcher template differs",
  "managed webhook test reported failure",
  "managed webhook test did not reach disposable ntfy",
  "disposable exit fixture did not exit with the expected status",
  "exit-code-1 event did not reach disposable ntfy"
]
fixed_diagnostics.each do |diagnostic|
  check(failures, contract.include?(diagnostic), "Dozzle contract is missing fixed diagnostic: #{diagnostic}")
end
unsafe_diagnostic_fragments = [
  "template differs: expected #{'#'}{expected_template.inspect}",
  "webhook test failed: #{'#'}{webhook_test.inspect}",
  "observed #{'#'}{observed_webhooks.inspect}",
  "#{'#'}{error.lines.first}",
  "trigger counters #{'#'}{counters.inspect}"
]
unsafe_diagnostic_fragments.each do |fragment|
  check(failures, !contract.include?(fragment), "Dozzle contract retains unsafe diagnostic interpolation: #{fragment}")
end
check(failures,
      contract.include?('rule.dig("dispatcher", "id").to_s == dispatcher["id"].to_s'),
      "Dozzle contract does not normalize opaque dispatcher IDs as strings")

role = File.read(ROLE)
check(failures, !role.include?("dispatcher.id | int"),
      "Dozzle verification coerces opaque dispatcher IDs to integers")

if failures.empty?
  puts "Dozzle quality regressions: marker counts and safe diagnostics hold"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} Dozzle quality regression(s)"
end
