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
PRE_REPAIR_DRAIN = "Drain active Audiobookshelf library scan before folder repair"
PRE_REPAIR_DRAIN_ASSERT = "Require drained Audiobookshelf library scan before folder repair"
FINAL_DRAIN = "Drain active Audiobookshelf library scan before initial scan request"
FINAL_DRAIN_ASSERT = "Require drained Audiobookshelf library scan before initial scan request"
BASELINE_REFETCH = "Refetch authoritative Audiobookshelf library before initial scan"
BASELINE_OUTER_ASSERT = "Require strict authoritative Audiobookshelf library baseline response"
BASELINE_RESOLVE = "Resolve authoritative Audiobookshelf library baseline"
BASELINE_ASSERT = "Require safe authoritative Audiobookshelf last scan baseline"
PRECREATE_PENDING_TASK = "Record pre-create Audiobookshelf initial scan intent"
BIND_PENDING_TASK = "Bind Audiobookshelf initial scan intent to current library"
CLEAR_PENDING_TASK = "Clear completed Audiobookshelf initial scan intent"
REFUSE_STALE_TASK = "Refuse mismatched Audiobookshelf initial scan intent"
CREATE_TASK = "Create the managed Audiobookshelf library"
REPAIR_TASK = "Repair the managed Audiobookshelf library"
VERIFY_TASK = "Authenticate to Audiobookshelf for exact verification"
CURRENT_LIBRARY_TASK = "Resolve the current managed Audiobookshelf library"
CURRENT_LIBRARY_ID_TASK = "Require safe current managed Audiobookshelf library ID"
SAFE_ID_PATTERN = "^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$"
LINUX_OWNERSHIP_GUARD =
  "platform_kind == 'nas' or (platform_manage_linux_ownership | bool)"

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

def normalized_expression(value)
  value.to_s.gsub(/\s+/, " ")
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
    config_path.include?("nas_docker_root }}/audiobookshelf/config"),
    "initial scan marker must follow the canonical config binding"
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
      scan_guard.include?("audiobookshelf_initial_scan_precreate_marker_matches") &&
      scan_guard.include?("audiobookshelf_initial_scan_bound_marker_matches") &&
      !scan_guard.include?("not audiobookshelf_initial_scan_") &&
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
  # `assert` renders the source text of the failing condition and the rendered
  # fail_msg, never the values, so an untemplated message is the whole property
  # here; `no_log` would only hide which condition failed.
  require_condition(
    !current_id_assert.fetch("fail_msg", "").to_s.include?("{{"),
    "unsafe current library IDs must not be disclosed"
  )

  repair_index = task_named(tasks, REPAIR_TASK).last
  create_index = task_named(tasks, CREATE_TASK).last
  verify_index = task_named(tasks, VERIFY_TASK).last
  diagnostic_index = task_named(tasks, "Resolve sanitized Audiobookshelf initial scan observation").last
  precreate_pending, precreate_pending_index = task_named(tasks, PRECREATE_PENDING_TASK)
  bound_pending, bound_pending_index = task_named(tasks, BIND_PENDING_TASK)
  require_condition(
    classification_index < precreate_pending_index && precreate_pending_index < create_index &&
      create_index < bound_pending_index && bound_pending_index < repair_index &&
      repair_index < scan_index && scan_index < verify_index,
    "pending intent must durably precede create and folder-repair mutations"
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

  pre_repair_drain, pre_repair_drain_index = task_named(tasks, PRE_REPAIR_DRAIN)
  pre_repair_drain_assert, pre_repair_drain_assert_index = task_named(
    tasks, PRE_REPAIR_DRAIN_ASSERT
  )
  final_drain, final_drain_index = task_named(tasks, FINAL_DRAIN)
  final_drain_assert, final_drain_assert_index = task_named(tasks, FINAL_DRAIN_ASSERT)
  [
    [pre_repair_drain, "audiobookshelf_library_folder_repair_required | bool"],
    [final_drain, "audiobookshelf_initial_scan_required | bool"]
  ].each do |drain, guard|
    drain_uri = drain.fetch("ansible.builtin.uri", {})
    drain_until = Array(drain["until"]).join(" ")
    require_condition(
      drain_uri["url"].to_s.end_with?("/api/tasks") &&
        drain["retries"] == "{{ audiobookshelf_initial_scan_retries }}" &&
        drain["delay"] == "{{ audiobookshelf_initial_scan_delay }}" &&
        Array(drain["when"]) == ["not ansible_check_mode", guard] && drain["no_log"] == true &&
        drain_until.include?("type_debug == 'list'") && drain_until.include?("library-scan") &&
        drain_until.include?("audiobookshelf_current_library.id") &&
        drain_until.include?("isFinished"),
      "scan drains must strictly and finitely wait for the managed library only"
    )
  end
  require_condition(
    bound_pending_index < pre_repair_drain_index &&
      pre_repair_drain_index < pre_repair_drain_assert_index &&
      pre_repair_drain_assert_index < repair_index && repair_index < final_drain_index &&
      final_drain_index < final_drain_assert_index,
    "active scans must drain both before folder PATCH and again after mutation"
  )
  [
    [pre_repair_drain_assert, "audiobookshelf_library_folder_repair_required | bool"],
    [final_drain_assert, "audiobookshelf_initial_scan_required | bool"]
  ].each do |drain_assert, guard|
    assertions = Array(drain_assert.dig("ansible.builtin.assert", "that")).join(" ")
    require_condition(
      assertions.include?("type_debug == 'list'") && assertions.include?("library-scan") &&
        assertions.include?("audiobookshelf_current_library.id") &&
        !drain_assert.dig("ansible.builtin.assert", "fail_msg").to_s.include?("{{") &&
        Array(drain_assert["when"]) == ["not ansible_check_mode", guard],
      "scan drain completion must be strictly asserted without disclosure"
    )
  end

  baseline_refetch, baseline_refetch_index = task_named(tasks, BASELINE_REFETCH)
  baseline_outer, baseline_outer_index = task_named(tasks, BASELINE_OUTER_ASSERT)
  baseline_resolve, baseline_resolve_index = task_named(tasks, BASELINE_RESOLVE)
  baseline_assert, baseline_assert_index = task_named(tasks, BASELINE_ASSERT)
  baseline, baseline_index = task_named(tasks, "Capture Audiobookshelf last scan before initial scan request")
  baseline_outer_assertions = Array(
    baseline_outer.dig("ansible.builtin.assert", "that")
  ).join(" ")
  baseline_assertions = Array(baseline_assert.dig("ansible.builtin.assert", "that")).join(" ")
  require_condition(
    baseline_refetch.dig("ansible.builtin.uri", "url").to_s.end_with?("/api/libraries") &&
      baseline_refetch["no_log"] == true &&
      Array(baseline_refetch["when"]) == [
        "not ansible_check_mode", "audiobookshelf_initial_scan_required | bool"
      ] && baseline_outer_assertions.include?("type_debug == 'list'") &&
      baseline_resolve.dig(
        "ansible.builtin.set_fact", "audiobookshelf_initial_scan_library_before"
      ).to_s.include?("audiobookshelf_initial_scan_baseline_libraries") &&
      baseline_assertions.include?("audiobookshelf_initial_scan_library_before[0].lastScan") &&
      baseline_assertions.include?("type_debug == 'int'") &&
      baseline.dig("ansible.builtin.set_fact", "audiobookshelf_initial_scan_last_scan_before")
              .to_s.include?("audiobookshelf_initial_scan_library_before[0].lastScan") &&
      final_drain_assert_index < baseline_refetch_index &&
      baseline_refetch_index < baseline_outer_index && baseline_outer_index < baseline_resolve_index &&
      baseline_resolve_index < baseline_assert_index && baseline_assert_index < baseline_index &&
      baseline_index + 1 == scan_index,
    "a strict authoritative lastScan baseline must be freshly captured immediately before POST"
  )
  marker_state, marker_state_index = task_named(
    tasks, "Resolve Audiobookshelf initial scan marker path and expected intents"
  )
  precreate_state = marker_state.dig(
    "ansible.builtin.set_fact", "audiobookshelf_initial_scan_precreate_state"
  )
  require_condition(
    precreate_state.is_a?(Hash) && precreate_state.keys.sort ==
      %w[folder_paths library_id library_name schema state] && precreate_state["schema"] == 1 &&
      precreate_state["state"] == "pending" && precreate_state["library_id"].nil? &&
      precreate_state["library_name"].to_s.include?("audiobookshelf_library_name") &&
      precreate_state["folder_paths"].to_s.include?("audiobookshelf_library_folders"),
    "pre-create intent must use managed identity, canonical folders, and a null library ID"
  )
  marker_schema = nested_task_named(tasks, "Require safe Audiobookshelf initial scan marker schema")
  marker_assertions = Array(marker_schema.dig("ansible.builtin.assert", "that")).join(" ")
  require_condition(
    marker_assertions.include?(
      "['folder_paths', 'library_id', 'library_name', 'schema', 'state']"
    ) && marker_assertions.include?("not audiobookshelf_initial_scan_marker_present or") &&
      marker_assertions.include?(".library_id is none or") &&
      marker_assertions.include?(".state | type_debug == 'str'") &&
      marker_assertions.include?(".state == 'pending'"),
    "only a strict pending-intent marker schema may request a retry"
  )
  marker_load, marker_load_index = task_named(tasks, "Safely load Audiobookshelf initial scan marker")
  marker_parse = nested_task_named(tasks, "Parse Audiobookshelf initial scan marker")
  marker_parse_facts = marker_parse.fetch("ansible.builtin.set_fact", {})
  marker_matches, marker_matches_index = task_named(
    tasks, "Resolve Audiobookshelf initial scan marker matches"
  )
  marker_match_facts = marker_matches.fetch("ansible.builtin.set_fact", {})
  marker_acceptance, marker_acceptance_index = task_named(
    tasks, "Resolve Audiobookshelf initial scan marker acceptance"
  )
  marker_acceptance_fact = marker_acceptance.dig(
    "ansible.builtin.set_fact", "audiobookshelf_initial_scan_marker_accepted"
  ).to_s
  require_condition(
    !marker_load.key?("when") && marker_state_index < marker_load_index &&
      marker_load_index < marker_matches_index && marker_matches_index < marker_acceptance_index &&
      marker_parse_facts.fetch("audiobookshelf_initial_scan_marker_present", "")
                        .to_s.include?("audiobookshelf_initial_scan_marker_source.exists") &&
      marker_match_facts.fetch("audiobookshelf_initial_scan_precreate_marker_matches", "")
                        .to_s.include?("audiobookshelf_initial_scan_precreate_state") &&
      marker_match_facts.fetch("audiobookshelf_initial_scan_bound_marker_matches", "")
                        .to_s.include?("audiobookshelf_initial_scan_existing_bound_state") &&
      marker_acceptance_fact.include?("not audiobookshelf_initial_scan_marker_present") &&
      !marker_acceptance_fact.include?("audiobookshelf_initial_scan_marker_state | length == 0") &&
      marker_acceptance_fact.include?("audiobookshelf_initial_scan_bound_marker_matches") &&
      marker_acceptance_fact.include?("audiobookshelf_initial_scan_precreate_marker_matches") &&
      marker_acceptance_fact.include?("audiobookshelf_existing_library | length == 0") &&
      marker_acceptance_fact.include?("not audiobookshelf_library_repair_required"),
    "marker classification must accept only absence or exact resumable pre-create/ID-bound intent"
  )
  stale_gate, stale_gate_index = task_named(tasks, REFUSE_STALE_TASK)
  stale_assert = stale_gate.fetch("ansible.builtin.assert", {})
  require_condition(
    marker_state_index < stale_gate_index && stale_gate_index < precreate_pending_index &&
      stale_gate_index < create_index && stale_gate_index < repair_index &&
      Array(stale_assert["that"]) == ["audiobookshelf_initial_scan_marker_accepted | bool"] &&
      !stale_assert.fetch("fail_msg", "").include?("{{"),
    "mismatched pending intents must fail closed before every library API mutation"
  )
  precreate_copy = precreate_pending.fetch("ansible.builtin.copy", {})
  require_condition(
    precreate_copy["content"].to_s.include?("audiobookshelf_initial_scan_precreate_state") &&
      precreate_copy["dest"] == "{{ audiobookshelf_initial_scan_marker_path }}" &&
      normalized_expression(precreate_copy["owner"]) ==
        "{{ nas_uid if #{LINUX_OWNERSHIP_GUARD} else omit }}" &&
      normalized_expression(precreate_copy["group"]) ==
        "{{ nas_gid if #{LINUX_OWNERSHIP_GUARD} else omit }}" &&
      precreate_copy["mode"] == "0600" && precreate_copy["follow"] == false &&
      precreate_copy["unsafe_writes"] == false && precreate_pending["no_log"] == true &&
      Array(precreate_pending["when"]) == [
        "not ansible_check_mode", "audiobookshelf_library_create_required | bool",
        "not audiobookshelf_initial_scan_marker_present | bool"
      ],
    "pre-create intent must be private, atomic, and written before library creation"
  )
  current_intent, current_intent_index = task_named(
    tasks, "Resolve current Audiobookshelf initial scan intent"
  )
  bound_state = current_intent.dig(
    "ansible.builtin.set_fact", "audiobookshelf_initial_scan_bound_state"
  )
  bound_copy = bound_pending.fetch("ansible.builtin.copy", {})
  require_condition(
    current_id_gate_index < current_intent_index && current_intent_index < bound_pending_index &&
      current_intent_index < scan_classification_index && scan_classification_index < plan_index &&
      scan_classification_index < bound_pending_index &&
      bound_state.is_a?(Hash) && bound_state.keys.sort ==
        %w[folder_paths library_id library_name schema state] &&
      bound_state["library_id"].to_s.include?("audiobookshelf_current_library.id") &&
      bound_copy["content"].to_s.include?("audiobookshelf_initial_scan_bound_state") &&
      bound_copy["dest"] == "{{ audiobookshelf_initial_scan_marker_path }}" &&
      normalized_expression(bound_copy["owner"]) ==
        "{{ nas_uid if #{LINUX_OWNERSHIP_GUARD} else omit }}" &&
      normalized_expression(bound_copy["group"]) ==
        "{{ nas_gid if #{LINUX_OWNERSHIP_GUARD} else omit }}" &&
      bound_copy["mode"] == "0600" && bound_copy["follow"] == false &&
      bound_copy["unsafe_writes"] == false && bound_pending["no_log"] == true &&
      Array(bound_pending["when"]).join(" ").include?("audiobookshelf_initial_scan_required") &&
      Array(bound_pending["when"]).join(" ").include?("!= audiobookshelf_initial_scan_bound_state"),
    "validated current ID must be durably bound before folder repair or scan"
  )
  marker_file_gate = nested_task_named(
    tasks, "Require private regular Audiobookshelf initial scan marker"
  )
  marker_file_assertions = Array(
    marker_file_gate.dig("ansible.builtin.assert", "that")
  ).join(" ")
  require_condition(
    marker_file_assertions.scan(LINUX_OWNERSHIP_GUARD).length == 2 &&
      marker_file_assertions.include?("audiobookshelf_initial_scan_marker_stat.stat.uid") &&
      marker_file_assertions.include?("audiobookshelf_initial_scan_marker_stat.stat.gid"),
    "native Mac marker validation must preserve host ownership while NAS and integration enforce Linux IDs"
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
task_named(
  disclosed_create_response, CURRENT_LIBRARY_ID_TASK
).first.fetch("ansible.builtin.assert")["fail_msg"] =
  "Unsafe library ID {{ audiobookshelf_current_library.id }}."
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
                       .sub(
                         "audiobookshelf_initial_scan_precreate_marker_matches",
                         "not audiobookshelf_initial_scan_precreate_marker_matches"
                       )
mutation_rejected!(absence_triggered_scan, defaults, "marker-absence scan")

wrong_order = deep_copy(tasks)
scan_index = task_named(wrong_order, SCAN_TASK).last
scan = wrong_order.delete_at(scan_index)
repair_index = task_named(wrong_order, REPAIR_TASK).last
wrong_order.insert(repair_index, scan)
mutation_rejected!(wrong_order, defaults, "wrong ordering")

missing_pre_repair_drain = deep_copy(tasks)
missing_pre_repair_drain.reject! { |task| task["name"] == PRE_REPAIR_DRAIN }
mutation_rejected!(missing_pre_repair_drain, defaults, "missing pre-repair scan drain")

missing_final_drain = deep_copy(tasks)
missing_final_drain.reject! { |task| task["name"] == FINAL_DRAIN }
mutation_rejected!(missing_final_drain, defaults, "missing final scan drain")

late_final_drain = deep_copy(tasks)
final_drain_index = task_named(late_final_drain, FINAL_DRAIN).last
final_drain_task = late_final_drain.delete_at(final_drain_index)
late_final_drain.insert(task_named(late_final_drain, SCAN_TASK).last + 1, final_drain_task)
mutation_rejected!(late_final_drain, defaults, "late final scan drain")

stale_scan_baseline = deep_copy(tasks)
baseline_facts = task_named(
  stale_scan_baseline, "Capture Audiobookshelf last scan before initial scan request"
).first.fetch("ansible.builtin.set_fact")
baseline_facts["audiobookshelf_initial_scan_last_scan_before"] =
  "{{ audiobookshelf_current_library.lastScan | default(none) }}"
mutation_rejected!(stale_scan_baseline, defaults, "stale lastScan baseline")

loose_baseline_libraries = deep_copy(tasks)
baseline_conditions = task_named(
  loose_baseline_libraries, BASELINE_OUTER_ASSERT
).first.dig("ansible.builtin.assert", "that")
baseline_conditions.map! { |condition| condition.to_s.sub("type_debug == 'list'", "is sequence") }
mutation_rejected!(loose_baseline_libraries, defaults, "loose baseline libraries shape")

unbounded_poll = deep_copy(tasks)
task_named(unbounded_poll, TASK_POLL).first.delete("retries")
mutation_rejected!(unbounded_poll, defaults, "unbounded polling")

missing_last_scan_proof = deep_copy(tasks)
missing_last_scan_proof.reject! { |task| task["name"] == LIBRARY_POLL }
mutation_rejected!(missing_last_scan_proof, defaults, "missing lastScan proof")

missing_durable_state = deep_copy(tasks)
missing_durable_state.reject! { |task| task["name"] == PRECREATE_PENDING_TASK }
mutation_rejected!(missing_durable_state, defaults, "missing pre-create scan intent")

late_pending_state = deep_copy(tasks)
pending_index = task_named(late_pending_state, PRECREATE_PENDING_TASK).last
pending_task = late_pending_state.delete_at(pending_index)
late_pending_state.insert(task_named(late_pending_state, CREATE_TASK).last + 1, pending_task)
mutation_rejected!(late_pending_state, defaults, "late pre-create scan intent")

missing_bound_state = deep_copy(tasks)
missing_bound_state.reject! { |task| task["name"] == BIND_PENDING_TASK }
mutation_rejected!(missing_bound_state, defaults, "missing ID-bound scan intent")

late_bound_state = deep_copy(tasks)
bound_index = task_named(late_bound_state, BIND_PENDING_TASK).last
bound_task = late_bound_state.delete_at(bound_index)
late_bound_state.insert(task_named(late_bound_state, REPAIR_TASK).last + 1, bound_task)
mutation_rejected!(late_bound_state, defaults, "late ID-bound scan intent")

missing_stale_gate = deep_copy(tasks)
missing_stale_gate.reject! { |task| task["name"] == REFUSE_STALE_TASK }
mutation_rejected!(missing_stale_gate, defaults, "missing stale-intent refusal")

late_stale_gate = deep_copy(tasks)
stale_index = task_named(late_stale_gate, REFUSE_STALE_TASK).last
stale_task = late_stale_gate.delete_at(stale_index)
late_stale_gate.insert(task_named(late_stale_gate, REPAIR_TASK).last + 1, stale_task)
mutation_rejected!(late_stale_gate, defaults, "late stale-intent refusal")

completed_marker_accepted = deep_copy(tasks)
marker_conditions = nested_task_named(
  completed_marker_accepted, "Require safe Audiobookshelf initial scan marker schema"
).dig("ansible.builtin.assert", "that")
marker_conditions.map! { |condition| condition.to_s.sub(".state == 'pending'", ".state in ['pending', 'completed']") }
mutation_rejected!(completed_marker_accepted, defaults, "completed-marker retry")

arbitrary_marker_accepted = deep_copy(tasks)
acceptance_facts = task_named(
  arbitrary_marker_accepted, "Resolve Audiobookshelf initial scan marker acceptance"
).first.fetch("ansible.builtin.set_fact")
acceptance_facts["audiobookshelf_initial_scan_marker_accepted"] = true
mutation_rejected!(arbitrary_marker_accepted, defaults, "arbitrary marker acceptance")

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
