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
LIBRARY_POLL = "Poll authoritative Audiobookshelf library scan state"
PENDING_TASK = "Record pending Audiobookshelf initial scan intent"
CLEAR_PENDING_TASK = "Clear completed Audiobookshelf initial scan intent"
REFUSE_STALE_TASK = "Refuse mismatched Audiobookshelf initial scan intent"
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

def nested_task_named(tasks, name)
  matches = []
  visit = lambda do |entries|
    entries.each do |task|
      matches << task if task["name"] == name
      %w[block rescue always].each { |section| visit.call(Array(task[section])) }
    end
  end
  visit.call(tasks)
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
  effective_paths, effective_paths_index = task_named(
    tasks, "Resolve the effective Audiobookshelf backup directory"
  )
  config_path = effective_paths.dig(
    "ansible.builtin.set_fact", "audiobookshelf_effective_config_host_path"
  ).to_s
  require_condition(
    config_path.include?("platform_adoption_root ~ '/legacy/audiobookshelf/config'") &&
      config_path.include?("nas_docker_root ~ '/audiobookshelf/config'"),
    "initial scan marker must follow normal and adoption config bindings"
  )
  timing, timing_index = task_named(tasks, "Require bounded Audiobookshelf initial scan timing")
  timing_assertions = Array(timing.dig("ansible.builtin.assert", "that")).join(" ")
  require_condition(
    effective_paths_index < timing_index && timing_assertions.include?("retries | int >= 1") &&
      timing_assertions.include?("delay | int >= 0"),
    "initial scan timing inputs must be bounded"
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
      scan_guard.include?("audiobookshelf_initial_scan_marker_matches") &&
      !scan_guard.include?("not audiobookshelf_initial_scan_marker_matches") &&
      scan_guard.match?(/audiobookshelf_library_create_required\s*\|\s*bool\s+or/) &&
      !scan_guard.include?("audiobookshelf_library_repair_required"),
    "initial scan must be limited to creation, folder repair, or matching pending intent"
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
  pending, pending_index = task_named(tasks, PENDING_TASK)
  require_condition(
    classification_index < scan_classification_index && scan_classification_index < plan_index &&
      repair_index < pending_index && pending_index < scan_index && scan_index < verify_index,
    "initial scan must follow create/repair classification and precede exact verification"
  )
  require_condition(
    current_id_gate_index == current_library_index + 1 && current_id_gate_index < repair_index &&
      current_id_gate_index < scan_index && current_id_gate_index < diagnostic_index,
    "current library ID validation must precede every API or diagnostic use"
  )

  task_poll, task_poll_index = task_named(tasks, TASK_POLL)
  library_poll, library_poll_index = task_named(tasks, LIBRARY_POLL)
  item_poll, item_poll_index = task_named(tasks, ITEM_POLL)
  require_condition(
    scan_index < task_poll_index && task_poll_index < library_poll_index &&
      library_poll_index < item_poll_index && item_poll_index < verify_index,
    "scan polling is ordered incorrectly"
  )
  [
    [task_poll, "/api/tasks"], [library_poll, "/api/libraries"],
    [item_poll, "/items?limit=1&minified=1"]
  ].each do |poll, suffix|
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
      task_until.include?("libraryId") && task_until.include?("audiobookshelf_current_library.id") &&
      task_until.include?("type_debug == 'list'"),
    "task polling must wait for the managed library scan to finish"
  )
  library_until = Array(library_poll["until"]).join(" ")
  require_condition(
    library_until.include?("lastScan") &&
      library_until.include?("audiobookshelf_initial_scan_last_scan_before") &&
      library_until.include?("type_debug == 'list'") && library_until.include?(">"),
    "authoritative library polling must require strict lastScan advancement"
  )
  item_until = Array(item_poll["until"]).join(" ")
  require_condition(
    item_until.include?("results") && item_until.include?("type_debug == 'list'") &&
      !item_until.match?(/length\s*>\s*0|length\s*>=\s*1/),
    "item polling must validate response shape without rejecting an empty source"
  )

  baseline, baseline_index = task_named(tasks, "Capture Audiobookshelf last scan before initial scan request")
  require_condition(
    baseline.dig("ansible.builtin.set_fact", "audiobookshelf_initial_scan_last_scan_before")
            .to_s.include?("audiobookshelf_current_library.lastScan") && baseline_index < scan_index,
    "lastScan baseline must be captured before the single scan POST"
  )
  marker_state, marker_state_index = task_named(
    tasks, "Resolve Audiobookshelf initial scan marker path and pending intent"
  )
  pending_state = marker_state.dig(
    "ansible.builtin.set_fact", "audiobookshelf_initial_scan_pending_state"
  )
  require_condition(
    pending_state.is_a?(Hash) && pending_state.keys.sort ==
      %w[folder_paths library_id schema state] && pending_state["schema"] == 1 &&
      pending_state["state"] == "pending" &&
      pending_state["library_id"].to_s.include?("audiobookshelf_current_library.id") &&
      pending_state["folder_paths"].to_s.include?("audiobookshelf_library_folders"),
    "pending scan intent must be keyed by safe library ID and canonical desired folders"
  )
  marker_schema = nested_task_named(tasks, "Require safe Audiobookshelf initial scan marker schema")
  marker_assertions = Array(marker_schema.dig("ansible.builtin.assert", "that")).join(" ")
  require_condition(
    marker_assertions.include?("['folder_paths', 'library_id', 'schema', 'state']") &&
      marker_assertions.include?(".state | type_debug == 'str'") &&
      marker_assertions.include?(".state == 'pending'"),
    "only a strict pending-intent marker schema may request a retry"
  )
  stale_gate, stale_gate_index = task_named(tasks, REFUSE_STALE_TASK)
  stale_assert = stale_gate.fetch("ansible.builtin.assert", {})
  require_condition(
    marker_state_index < stale_gate_index && stale_gate_index < scan_classification_index &&
      Array(stale_assert["that"]).join(" ").include?(
        "audiobookshelf_initial_scan_marker_state | length == 0 or"
      ) && Array(stale_assert["that"]).join(" ").include?(
        "audiobookshelf_initial_scan_marker_matches | bool"
      ) && stale_gate["no_log"] == true && !stale_assert.fetch("fail_msg", "").include?("{{"),
    "mismatched pending scan intents must fail closed without disclosing marker data"
  )
  pending_copy = pending.fetch("ansible.builtin.copy", {})
  require_condition(
    marker_state_index < pending_index && pending_index < scan_index &&
      pending_copy["content"].to_s.include?("audiobookshelf_initial_scan_pending_state") &&
      pending_copy["dest"] == "{{ audiobookshelf_initial_scan_marker_path }}" &&
      pending_copy["mode"] == "0600" && pending_copy["follow"] == false &&
      pending_copy["unsafe_writes"] == false && pending["no_log"] == true &&
      Array(pending["when"]) == [
        "not ansible_check_mode",
        "audiobookshelf_library_create_required | bool or audiobookshelf_library_folder_repair_required | bool"
      ],
    "pending scan intent must be written privately and atomically before the scan POST"
  )
  clear_pending, clear_pending_index = task_named(tasks, CLEAR_PENDING_TASK)
  clear_file = clear_pending.fetch("ansible.builtin.file", {})
  require_condition(
    clear_pending_index > item_poll_index &&
      clear_pending_index > task_named(tasks, "Require completed Audiobookshelf initial library scan").last &&
      clear_file == {
        "path" => "{{ audiobookshelf_initial_scan_marker_path }}", "state" => "absent"
      } && clear_pending["no_log"] == true && Array(clear_pending["when"]) == [
        "not ansible_check_mode", "audiobookshelf_initial_scan_required | bool"
      ],
    "pending scan intent must be cleared only after exact success validation"
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

missed_retry_scan = deep_copy(tasks)
retry_facts = task_named(
  missed_retry_scan, "Resolve Audiobookshelf initial scan requirement"
).first.fetch("ansible.builtin.set_fact")
retry_facts["audiobookshelf_initial_scan_required"] =
  "{{ audiobookshelf_library_create_required | bool or " \
  "audiobookshelf_library_folder_repair_required | bool }}"
mutation_rejected!(missed_retry_scan, defaults, "missing durable-state retry")

absence_triggered_scan = deep_copy(tasks)
absence_trigger_facts = task_named(
  absence_triggered_scan, "Resolve Audiobookshelf initial scan requirement"
).first.fetch("ansible.builtin.set_fact")
absence_trigger_facts["audiobookshelf_initial_scan_required"] =
  absence_trigger_facts.fetch("audiobookshelf_initial_scan_required")
                       .sub("audiobookshelf_initial_scan_marker_matches", "not audiobookshelf_initial_scan_marker_matches")
mutation_rejected!(absence_triggered_scan, defaults, "marker-absence scan")

wrong_order = deep_copy(tasks)
scan_index = task_named(wrong_order, SCAN_TASK).last
scan = wrong_order.delete_at(scan_index)
repair_index = task_named(wrong_order, REPAIR_TASK).last
wrong_order.insert(repair_index, scan)
mutation_rejected!(wrong_order, defaults, "wrong ordering")

unbounded_poll = deep_copy(tasks)
task_named(unbounded_poll, TASK_POLL).first.delete("retries")
mutation_rejected!(unbounded_poll, defaults, "unbounded polling")

missing_last_scan_proof = deep_copy(tasks)
missing_last_scan_proof.reject! { |task| task["name"] == LIBRARY_POLL }
mutation_rejected!(missing_last_scan_proof, defaults, "missing lastScan proof")

missing_durable_state = deep_copy(tasks)
missing_durable_state.reject! { |task| task["name"] == PENDING_TASK }
mutation_rejected!(missing_durable_state, defaults, "missing pending scan intent")

late_pending_state = deep_copy(tasks)
pending_index = task_named(late_pending_state, PENDING_TASK).last
pending_task = late_pending_state.delete_at(pending_index)
late_pending_state.insert(task_named(late_pending_state, SCAN_TASK).last + 1, pending_task)
mutation_rejected!(late_pending_state, defaults, "late pending scan intent")

missing_stale_gate = deep_copy(tasks)
missing_stale_gate.reject! { |task| task["name"] == REFUSE_STALE_TASK }
mutation_rejected!(missing_stale_gate, defaults, "missing stale-intent refusal")

completed_marker_accepted = deep_copy(tasks)
marker_conditions = nested_task_named(
  completed_marker_accepted, "Require safe Audiobookshelf initial scan marker schema"
).dig("ansible.builtin.assert", "that")
marker_conditions.map! { |condition| condition.to_s.sub(".state == 'pending'", ".state in ['pending', 'completed']") }
mutation_rejected!(completed_marker_accepted, defaults, "completed-marker retry")

missing_pending_clear = deep_copy(tasks)
missing_pending_clear.reject! { |task| task["name"] == CLEAR_PENDING_TASK }
mutation_rejected!(missing_pending_clear, defaults, "missing pending-intent clear")

loose_task_shape = deep_copy(tasks)
task_until = task_named(loose_task_shape, TASK_POLL).first.fetch("until")
task_until.map! { |condition| condition.to_s.sub("type_debug == 'list'", "is sequence") }
mutation_rejected!(loose_task_shape, defaults, "loose task shape")

loose_item_shape = deep_copy(tasks)
item_until = task_named(loose_item_shape, ITEM_POLL).first.fetch("until")
item_until.map! { |condition| condition.to_s.sub("type_debug == 'list'", "is sequence") }
mutation_rejected!(loose_item_shape, defaults, "loose item shape")

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
