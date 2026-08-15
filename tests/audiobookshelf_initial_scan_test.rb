#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"

ROOT = File.expand_path("..", __dir__)
ROLE_PATH = File.join(ROOT, "roles", "audiobookshelf", "tasks", "main.yml")
DEFAULTS_PATH = File.join(ROOT, "roles", "audiobookshelf", "defaults", "main.yml")
CONTRACT_PATH = File.join(ROOT, "tests", "contracts", "audiobookshelf.sh")
INTEGRATION_PATH = File.join(ROOT, "tests", "integration.sh")

SCAN_TASK = "Request Audiobookshelf initial library scan"
PLAN_TASK = "Report planned Audiobookshelf initial scan"
TASK_POLL = "Poll Audiobookshelf initial library scan tasks"
ITEM_POLL = "Poll Audiobookshelf managed library items after initial scan"
REPAIR_TASK = "Repair the managed Audiobookshelf library"
VERIFY_TASK = "Authenticate to Audiobookshelf for exact verification"
CURRENT_LIBRARY_TASK = "Resolve the current managed Audiobookshelf library"
CURRENT_LIBRARY_ID_TASK = "Require safe current managed Audiobookshelf library ID"
SAFE_ID_PATTERN = "^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$"

def task_named(tasks, name)
  matches = tasks.each_with_index.select { |task, _index| task["name"] == name }
  raise "#{name} must occur exactly once" unless matches.length == 1

  matches.first
end

def require_condition(condition, message)
  raise message unless condition
end

def validate_initial_scan!(tasks, defaults)
  require_condition(
    defaults.values_at("audiobookshelf_initial_scan_retries", "audiobookshelf_initial_scan_delay") == [60, 2],
    "initial scan defaults must be retries=60 and delay=2"
  )

  path_resolution, path_resolution_index = task_named(
    tasks, "Resolve existing Audiobookshelf library folder paths"
  )
  path_facts = path_resolution.fetch("ansible.builtin.set_fact", {})
  require_condition(
    path_facts.key?("audiobookshelf_existing_library_paths"),
    "existing library paths must be resolved before repair classification"
  )
  classification, classification_index = task_named(
    tasks, "Resolve Audiobookshelf library repair requirement"
  )
  facts = classification.fetch("ansible.builtin.set_fact", {})
  folder_guard = facts.fetch("audiobookshelf_library_folder_repair_required", "").to_s
  require_condition(
    path_resolution_index < classification_index &&
      folder_guard.match?(/audiobookshelf_existing_library\s*\|\s*length\s*>\s*0\s+and/) &&
      folder_guard.include?("audiobookshelf_existing_library_paths !=") &&
      folder_guard.include?("audiobookshelf_library_folders"),
    "folder-binding repairs must be classified separately"
  )
  scan_classification, scan_classification_index = task_named(
    tasks, "Resolve Audiobookshelf initial scan requirement"
  )
  scan_guard = scan_classification.fetch("ansible.builtin.set_fact", {})
                                  .fetch("audiobookshelf_initial_scan_required", "").to_s
  require_condition(
    scan_guard.include?("audiobookshelf_library_create_required") &&
      scan_guard.include?("audiobookshelf_library_folder_repair_required") &&
      scan_guard.match?(/audiobookshelf_library_create_required\s*\|\s*bool\s+or/) &&
      !scan_guard.include?("audiobookshelf_library_repair_required"),
    "initial scan must be limited to creation or folder-binding repair"
  )

  plan, plan_index = task_named(tasks, PLAN_TASK)
  require_condition(plan.dig("ansible.builtin.debug", "msg") == "AUDIOBOOKSHELF_PLAN_INITIAL_SCAN",
                    "check mode must emit AUDIOBOOKSHELF_PLAN_INITIAL_SCAN")
  require_condition(
    Array(plan["when"]) == ["ansible_check_mode", "audiobookshelf_initial_scan_required | bool"] &&
      plan["changed_when"] == true,
    "initial scan plan guard differs"
  )

  scan, scan_index = task_named(tasks, SCAN_TASK)
  scan_uri = scan.fetch("ansible.builtin.uri", {})
  require_condition(
    scan_uri["url"] ==
      "{{ audiobookshelf_api }}/api/libraries/{{ audiobookshelf_current_library.id }}/scan" &&
      scan_uri["method"] == "POST" && scan_uri["status_code"] == [200],
    "managed library scan must POST exactly once with status 200"
  )
  require_condition(
    scan_uri.dig("headers", "Authorization") == "Bearer {{ audiobookshelf_reconcile_token }}" &&
      scan["no_log"] == true,
    "managed library scan must protect the reconcile bearer"
  )
  require_condition(
    Array(scan["when"]) == [
      "not ansible_check_mode", "audiobookshelf_initial_scan_required | bool"
    ],
    "managed library scan is unconditional"
  )
  scan_posts = tasks.count do |task|
    uri = task["ansible.builtin.uri"]
    uri.is_a?(Hash) && uri["method"] == "POST" && uri["url"].to_s.end_with?("/scan")
  end
  require_condition(scan_posts == 1, "role must contain exactly one library scan POST")

  current_library_index = task_named(tasks, CURRENT_LIBRARY_TASK).last
  current_id_gate, current_id_gate_index = task_named(tasks, CURRENT_LIBRARY_ID_TASK)
  current_id_assert = current_id_gate.fetch("ansible.builtin.assert", {})
  require_condition(
    Array(current_id_assert["that"]) == [
      "audiobookshelf_current_library.id | string is match('#{SAFE_ID_PATTERN}')"
    ] && Array(current_id_gate["when"]) == ["audiobookshelf_current_library | length > 0"],
    "current library ID must be validated against the safe API pattern"
  )
  require_condition(
    current_id_gate["no_log"] == true &&
      !current_id_assert.fetch("fail_msg", "").to_s.include?("{{"),
    "unsafe current library IDs must not be disclosed"
  )

  repair_index = task_named(tasks, REPAIR_TASK).last
  verify_index = task_named(tasks, VERIFY_TASK).last
  diagnostic_index = task_named(tasks, "Resolve sanitized Audiobookshelf initial scan observation").last
  require_condition(
    classification_index < scan_classification_index && scan_classification_index < plan_index &&
      repair_index < scan_index && scan_index < verify_index,
    "initial scan must follow create/repair classification and precede exact verification"
  )
  require_condition(
    current_id_gate_index == current_library_index + 1 && current_id_gate_index < repair_index &&
      current_id_gate_index < scan_index && current_id_gate_index < diagnostic_index,
    "current library ID validation must precede every API or diagnostic use"
  )

  task_poll, task_poll_index = task_named(tasks, TASK_POLL)
  item_poll, item_poll_index = task_named(tasks, ITEM_POLL)
  require_condition(
    scan_index < task_poll_index && task_poll_index < item_poll_index && item_poll_index < verify_index,
    "scan polling is ordered incorrectly"
  )
  [[task_poll, "/api/tasks"], [item_poll, "/items?limit=1&minified=1"]].each do |poll, suffix|
    uri = poll.fetch("ansible.builtin.uri", {})
    require_condition(uri["url"].to_s.end_with?(suffix), "scan polling uses an unsupported API")
    require_condition(
      poll["retries"] == "{{ audiobookshelf_initial_scan_retries }}" &&
        poll["delay"] == "{{ audiobookshelf_initial_scan_delay }}" &&
        !Array(poll["until"]).empty?,
      "scan polling must have finite configured retries and delay"
    )
    require_condition(
      Array(poll["when"]) == [
        "not ansible_check_mode", "audiobookshelf_initial_scan_required | bool"
      ] && poll["no_log"] == true,
      "scan polling guard or disclosure protection differs"
    )
  end
  task_until = Array(task_poll["until"]).join(" ")
  require_condition(
    task_until.include?("library-scan") && task_until.include?("isFinished") &&
      task_until.include?("libraryId") && task_until.include?("audiobookshelf_current_library.id"),
    "task polling must wait for the managed library scan to finish"
  )
  item_until = Array(item_poll["until"]).join(" ")
  require_condition(
    item_until.include?("results") && item_until.include?("sequence") &&
      !item_until.match?(/length\s*>\s*0|length\s*>=\s*1/),
    "item polling must validate response shape without rejecting an empty source"
  )

  diagnostic, = task_named(tasks, "Require completed Audiobookshelf initial library scan")
  failure_message = diagnostic.dig("ansible.builtin.assert", "fail_msg").to_s
  require_condition(
    %w[library_id scan_active item_count retry_observation].all? do |field|
      failure_message.include?(field)
    end,
    "scan timeout diagnostic is missing a safe observation"
  )
  require_condition(
    !failure_message.match?(/token|password|username|title|metadata|results|tasks/i),
    "scan timeout diagnostic may disclose credentials or media metadata"
  )
end

def deep_copy(value)
  Marshal.load(Marshal.dump(value))
end

def mutation_rejected!(tasks, defaults, label)
  begin
    validate_initial_scan!(tasks, defaults)
  rescue RuntimeError
    return
  end

  raise "#{label} mutation was not rejected"
end

tasks = YAML.safe_load_file(ROLE_PATH, aliases: false)
defaults = YAML.safe_load_file(DEFAULTS_PATH, aliases: false)
validate_initial_scan!(tasks, defaults)

missing_scan = deep_copy(tasks)
missing_scan.reject! { |task| task["name"] == SCAN_TASK }
mutation_rejected!(missing_scan, defaults, "missing scan")

unconditional_scan = deep_copy(tasks)
task_named(unconditional_scan, SCAN_TASK).first["when"] = ["not ansible_check_mode"]
mutation_rejected!(unconditional_scan, defaults, "unconditional scan")

unsafe_create_response = deep_copy(tasks)
unsafe_id_assert = task_named(
  unsafe_create_response, CURRENT_LIBRARY_ID_TASK
).first.fetch("ansible.builtin.assert")
unsafe_id_assert["that"] = ["audiobookshelf_current_library.id | string is match('.*')"]
mutation_rejected!(unsafe_create_response, defaults, "unsafe create-response ID")

disclosed_create_response = deep_copy(tasks)
task_named(disclosed_create_response, CURRENT_LIBRARY_ID_TASK).first["no_log"] = false
mutation_rejected!(disclosed_create_response, defaults, "disclosed create-response ID")

inverted_folder_guard = deep_copy(tasks)
folder_facts = task_named(
  inverted_folder_guard, "Resolve Audiobookshelf library repair requirement"
).first.fetch("ansible.builtin.set_fact")
folder_facts["audiobookshelf_library_folder_repair_required"] =
  folder_facts.fetch("audiobookshelf_library_folder_repair_required").sub("!=", "==")
mutation_rejected!(inverted_folder_guard, defaults, "inverted folder guard")

missed_folder_scan = deep_copy(tasks)
scan_facts = task_named(
  missed_folder_scan, "Resolve Audiobookshelf initial scan requirement"
).first.fetch("ansible.builtin.set_fact")
scan_facts["audiobookshelf_initial_scan_required"] =
  scan_facts.fetch("audiobookshelf_initial_scan_required").sub("bool or", "bool and")
mutation_rejected!(missed_folder_scan, defaults, "missed folder scan")

wrong_order = deep_copy(tasks)
scan_index = task_named(wrong_order, SCAN_TASK).last
scan = wrong_order.delete_at(scan_index)
repair_index = task_named(wrong_order, REPAIR_TASK).last
wrong_order.insert(repair_index, scan)
mutation_rejected!(wrong_order, defaults, "wrong ordering")

unbounded_poll = deep_copy(tasks)
task_named(unbounded_poll, TASK_POLL).first.delete("retries")
mutation_rejected!(unbounded_poll, defaults, "unbounded polling")

contract = File.read(CONTRACT_PATH)
require_condition(
  !contract.match?(%r{request\(\s*["']post["'],\s*["']/api/libraries/.+?/scan}),
  "runtime contract must not trigger or retrigger a library scan"
)

integration = File.read(INTEGRATION_PATH)
fixture_seed = integration.index('"$repo_dir/tests/contracts/audiobookshelf.sh" seed-fixture-only')
controller_start = integration.index("docker run --rm")
require_condition(
  fixture_seed && controller_start && fixture_seed < controller_start,
  "Audiobookshelf fixture must exist before role deployment"
)

puts "Audiobookshelf initial scan tests passed"
