#!/usr/bin/env ruby
# Deployment bundle policy: release IDs, target-path containment and Compose
# selection for roles/deployment_bundle. Split out of policy_test.rb.

require "fileutils"
require "open3"
require "tmpdir"
require "rbconfig"
require "set"
require "yaml"
require_relative "policy_support"

include PolicySupport
include TestScaffold

# Roles that run before the release exists and so pass
# deployment_target_require_current_release: false. Every other role must pass true.
RELEASE_OPTIONAL_ROLES = %w[deployment_bundle host_prep].freeze

# Playbook target includes that legitimately pass `false`, each with its reason (#398).
# The lock harness has no `current` symlink, so `true` would pass there by accident;
# the value states whether the caller needs an active release, not what happens to run.
RELEASE_OPTIONAL_PLAYBOOKS = {
  "site.yml" =>
    "validates containment in pre_tasks, before deployment_bundle installs the release this " \
    "run activates; on a host that has deployed before, `current` still names the previous one",
  "tests/mac_inventory_path_test.yml" =>
    "asserts the Mac inventory's storage roots against a disposable tree it converges nothing " \
    "into and installs no release in",
  "tests/deployment_lock_refusal_test.yml" =>
    "proves the concurrency refusal fires before containment validation, against a disposable " \
    "deployment tree the harness never installs a release in"
}.freeze

failures = []

harness = File.read(File.join(ROOT, "tests", "integration.sh"))
controller = File.read(File.join(ROOT, "tests", "integration_controller.sh"))
# Production must reject a dirty controller checkout; only the disposable
# integration platform may opt into it.
deployment_defaults_path = File.join(ROOT, "roles", "deployment_bundle", "defaults", "main.yml")
deployment_defaults = File.file?(deployment_defaults_path) ? YAML.safe_load_file(deployment_defaults_path) : {}
check(failures, deployment_defaults["deployment_bundle_allow_dirty_controller"] == false,
      "deployment bundle must refuse dirty controller sources by default")

deployment_spec = YAML.safe_load_file(
  File.join(ROOT, "roles", "deployment_bundle", "meta", "argument_specs.yml")
)
dirty_option = deployment_spec.dig(
  "argument_specs", "main", "options", "deployment_bundle_allow_dirty_controller"
)
check(failures, dirty_option.is_a?(Hash) && dirty_option["type"] == "bool" &&
                dirty_option["default"] == false,
      "deployment bundle dirty-source bypass must be an explicit false boolean option")
test_mode_option = deployment_spec.dig(
  "argument_specs", "main", "options", "deployment_bundle_test_mode"
)
check(failures, test_mode_option.is_a?(Hash) && test_mode_option["type"] == "bool" &&
                test_mode_option["default"] == false,
      "deployment bundle test mode must be an explicit false boolean option")
platform_kind_option = deployment_spec.dig("argument_specs", "main", "options", "platform_kind")
check(failures, platform_kind_option.is_a?(Hash) && platform_kind_option["choices"] == %w[nas mac],
      "deployment bundle platform_kind must allow only nas or mac")
compose_kind_option = deployment_spec.dig(
  "argument_specs", "main", "options", "platform_compose_kind"
)
check(failures, compose_kind_option.is_a?(Hash) && compose_kind_option["type"] == "str" &&
                compose_kind_option["required"] == true,
      "deployment bundle must require a separate platform_compose_kind")

deployment_tasks = flatten_tasks(YAML.safe_load_file(
  File.join(ROOT, "roles", "deployment_bundle", "tasks", "controller.yml")
))
dirty_guard = deployment_tasks.find { |task| task["name"] == "Restrict dirty controller bypass to integration" }
compose_override_guard = deployment_tasks.find do |task|
  task["name"] == "Restrict Compose override selection to explicit test mode"
end
cleanliness_check = deployment_tasks.find { |task| task["name"] == "Inspect controller bundle source cleanliness" }
cleanliness_assert = deployment_tasks.find { |task| task["name"] == "Require committed controller bundle sources" }
dirty_guard_conditions = dirty_guard&.dig("ansible.builtin.assert", "that").to_s
compose_override_conditions = compose_override_guard&.dig("ansible.builtin.assert", "that").to_s
check(failures, compose_override_conditions.include?("platform_kind in ['nas', 'mac']") &&
                compose_override_conditions.include?("platform_compose_kind == platform_kind") &&
                compose_override_conditions.include?("deployment_bundle_test_mode"),
      "Compose override selection must require explicit test mode")
check(failures, dirty_guard_conditions.include?("platform_compose_kind == 'integration'") &&
                dirty_guard_conditions.include?("deployment_bundle_test_mode"),
      "dirty controller bypass must require explicit integration Compose test mode")
cleanliness_argv = cleanliness_check&.dig("ansible.builtin.command", "argv")
expected_cleanliness_argv = [
  "git", "-C", "{{ playbook_dir }}", "status", "--porcelain=v1", "--untracked-files=all"
]
check(failures, cleanliness_argv == expected_cleanliness_argv,
      "deployment bundle must inspect the whole tracked and untracked controller checkout")
check(failures, cleanliness_assert&.dig("ansible.builtin.assert", "that").to_s
                .include?("deployment_bundle_allow_dirty_controller"),
      "deployment bundle must refuse dirty sources unless the guarded bypass is enabled")
check(failures, cleanliness_assert && !cleanliness_assert.key?("run_once"),
      "dirty controller refusal must be evaluated independently for every target host")
check(failures, !harness.include?("-e platform_kind=integration") &&
                !controller.include?("-e platform_kind=integration") &&
                controller.include?("-e platform_compose_kind=integration") &&
                controller.include?("-e deployment_bundle_test_mode=true") &&
                controller.include?("-e deployment_bundle_allow_dirty_controller=true"),
      "integration must preserve platform_kind and explicitly enable its Compose test override")
%w[
  DIRTY_TRACKED_REFUSED DIRTY_UNTRACKED_REFUSED
  DIRTY_MANIFEST_TEMPLATE_REFUSED DIRTY_ARBITRARY_CONTROLLER_FILE_REFUSED
  DIRTY_PRODUCTION_BYPASS_REFUSED DIRTY_INTEGRATION_ACCEPTED
  DIRTY_REFUSAL_TARGET_UNCHANGED
].each do |evidence|
  check(failures, controller.include?(evidence),
        "integration must execute and report #{evidence.downcase.tr('_', ' ')}")
end
site_play = YAML.safe_load_file(File.join(ROOT, "site.yml")).first
controller_preflight = Array(site_play["pre_tasks"]).find do |task|
  include_role = task["ansible.builtin.include_role"]
  include_role.is_a?(Hash) && include_role["name"] == "deployment_bundle" &&
    include_role["tasks_from"] == "controller" &&
    Array(include_role.dig("apply", "tags")).include?("always")
end
check(failures, !controller_preflight.nil?,
      "controller bundle cleanliness must be validated before target-mutating roles")

# Target paths are hostile until their lexical form and filesystem ancestry are
# checked, once per distinct path set, ahead of the tasks that mutate them.
target_tasks_path = File.join(ROOT, "roles", "deployment_bundle", "tasks", "target.yml")
target_tasks_body = File.file?(target_tasks_path) ? File.read(target_tasks_path) : ""
target_validator_path = File.join(ROOT, "roles", "deployment_bundle", "files", "validate_target.py")
target_validator_body = File.file?(target_validator_path) ? File.read(target_validator_path) : ""
target_tasks = File.file?(target_tasks_path) ? YAML.safe_load_file(target_tasks_path) : []
target_validation_tasks = Array(target_tasks).select do |task|
  task["name"] == "Validate target path ancestry and canonical containment"
end
target_validation = target_validation_tasks.one? ? target_validation_tasks.first : {}
target_validation_argv = Array(target_validation.dig("ansible.builtin.command", "argv"))
validator_lookup = "{{ lookup('ansible.builtin.file', role_path ~ '/files/validate_target.py') }}"
check(failures, target_validation_tasks.one? &&
                target_validation_argv[1] == "-c" &&
                target_validation_argv[2] == validator_lookup &&
                target_validation_argv.count(validator_lookup) == 1,
      "target containment task must execute the exact extracted validator source")
check(failures, target_validation_argv.length == 10 &&
                target_validation_argv[3] == "{{ nas_docker_root }}" &&
                target_validation_argv[4] == "{{ nas_media_root }}" &&
                target_validation_argv[9].include?("deployment_target_candidate_paths") &&
                target_validation_argv[9].include?("to_json"),
      "target containment task must pass exactly one JSON target batch")
check(failures, !target_validation.key?("loop") && !target_validation.key?("loop_control"),
      "target containment task must validate the batch without an Ansible loop")
%w[os.lstat os.path.realpath os.path.commonpath os.path.lexists].each do |primitive|
  check(failures, target_validator_body.include?(primitive),
        "target validator must use #{primitive} for symlink-safe canonical containment")
end
# Source text on purpose: the subject is a comment, which YAML parsing erases.
check(failures, target_tasks_body.include?("concurrent privileged filesystem mutation"),
      "target validator must document the race its containment check cannot close")
target_record = Array(target_tasks).find do |task|
  task.dig("ansible.builtin.set_fact", "deployment_bundle_target_validated") == true
end
check(failures, !target_record.nil?,
      "target validation must record that the play has already validated containment")
check(failures, target_validator_body.include?("os.path.abspath(os.sep)") &&
                target_validator_body.include?("root_relative_parts"),
      "target validator must lstat every existing ancestor from filesystem root to nas_docker_root")
# Leaves come from the expression the task evaluates, not from the file's text.
target_path_expression = target_validation.dig("vars", "deployment_target_paths").to_s
check(failures, target_path_expression.include?("nas_docker_root ~ '/.nas-platform-preflight-probe'") ||
                target_path_expression.include?("{{ nas_docker_root }}/.nas-platform-preflight-probe"),
      "target validator must guard the exact preflight probe leaf")
check(failures, target_path_expression.include?("deployment_bundle_services") &&
                target_path_expression.include?("platform_runtime_dir ~ '/services/'"),
      "target validator must guard every implemented runtime service leaf")

controller_input_path = File.join(ROOT, "roles", "deployment_bundle", "tasks", "controller_input.yml")
controller_input_tasks = File.file?(controller_input_path) ? YAML.safe_load_file(controller_input_path) : []
controller_input_validation = Array(controller_input_tasks).select do |task|
  task["name"] == "Validate controller bundle input identity"
end
controller_input_argv = controller_input_validation.one? ?
  Array(controller_input_validation.first.dig("ansible.builtin.command", "argv")) : []
controller_input_lookup =
  "{{ lookup('ansible.builtin.file', role_path ~ '/files/validate_controller_input.py') }}"
check(failures, controller_input_validation.one? &&
                controller_input_argv[1] == "-c" &&
                controller_input_argv[2] == controller_input_lookup &&
                controller_input_argv.count(controller_input_lookup) == 1 &&
                controller_input_argv[3] == "--batch" &&
                controller_input_argv.include?("{{ deployment_controller_inputs | to_json }}"),
      "controller input task must execute the exact extracted validator source")
controller_input_validator_path = File.join(ROOT, "roles", "deployment_bundle", "files",
                                            "validate_controller_input.py")
controller_input_body = File.file?(controller_input_validator_path) ?
  File.read(controller_input_validator_path) : ""
%w[os.lstat os.path.realpath os.path.commonpath stat.S_ISREG].each do |primitive|
  check(failures, controller_input_body.include?(primitive),
        "controller input validator must use #{primitive}")
end
inputs_path = File.join(ROOT, "roles", "deployment_bundle", "tasks", "inputs.yml")
inputs_body = File.file?(inputs_path) ? File.read(inputs_path) : ""
input_tasks = flatten_tasks(YAML.safe_load(inputs_body))
# The validated inputs are those named by the controller_input.yml inclusions'
# list expressions (batched since #333), not every path string in the file.
validated_input_batches = input_tasks.filter_map do |task|
  next unless task["ansible.builtin.include_tasks"] == "controller_input.yml"

  task.dig("vars", "deployment_controller_inputs").to_s
end
validated_inputs = validated_input_batches.join("\n")
# The second element is allow_missing; only the platform overrides carry '1'.
check(failures, validated_inputs.include?("playbook_dir ~ '/services/manifest.yml', '0'") &&
                validated_inputs.include?("deployment_bundle_services") &&
                validated_inputs.include?("playbook_dir ~ '/services/'") &&
                validated_inputs.include?("'/compose.yml'") &&
                validated_inputs.include?("'/compose.' ~ platform_compose_kind ~ '.yml'"),
      "controller inputs must validate manifest, canonical Compose, and platform overrides")
check(failures, validated_inputs.include?("playbook_dir ~ '/services/dozzle/alert_relay.py', '0'") &&
                validated_inputs.include?(
                  "playbook_dir ~ '/services/immich/classify_restore.py', '0'"
                ) &&
                validated_inputs.include?("playbook_dir ~ '/services/kapowarr/tasks.py', '0'"),
      "controller inputs must validate every tracked runtime helper")
catalog_validation_index = input_tasks.index do |task|
  task["ansible.builtin.include_tasks"] == "controller_input.yml" &&
    task.dig("vars", "deployment_controller_inputs").to_s
        .include?("playbook_dir ~ '/config/media-acquisition.yml', '0'")
end
manifest_parse_index = input_tasks.index do |task|
  task["name"] == "Resolve implemented services from the validated controller manifest"
end
check(failures,
      !catalog_validation_index.nil? &&
        !manifest_parse_index.nil? && catalog_validation_index < manifest_parse_index,
      "controller inputs must validate the required acquisition catalog before parsing inputs")
# The second platform input (#647); roles/managed_users reads it from the deployed release.
check(failures,
      validated_inputs.include?(
        "playbook_dir ~ '/config/managed-user-capabilities.yml', '0'"
      ),
      "controller inputs must validate the required managed-user capability register")

target_preflight_index = Array(site_play["pre_tasks"]).index do |task|
  include_role = task["ansible.builtin.include_role"]
  include_role.is_a?(Hash) && include_role["name"] == "deployment_bundle" &&
    include_role["tasks_from"] == "target" &&
    Array(include_role.dig("apply", "tags")).include?("always")
end
check(failures, !target_preflight_index.nil?,
      "target containment must be validated before preflight can mutate the target")


deployment_body = File.read(File.join(ROOT, "roles", "deployment_bundle", "tasks", "main.yml"))
deployment_tasks = flatten_tasks(YAML.safe_load(deployment_body))
manifest_path_validation = input_tasks.find do |task|
  task["name"] == "Validate manifest service path components before interpolation"
end
manifest_path_conditions = Array(
  manifest_path_validation&.dig("ansible.builtin.assert", "that")
).join(" ")
check(failures, manifest_path_conditions.include?("item.name is match") &&
                manifest_path_conditions.include?("item.role is match"),
      "deployment bundle must validate manifest service path components")
canonical_requirement = deployment_tasks.find do |task|
  task["name"] == "Require canonical Compose for each implemented service"
end
canonical_conditions = Array(canonical_requirement&.dig("ansible.builtin.assert", "that")).join(" ")
check(failures, canonical_conditions.include?("not item.stat.islnk"),
      "canonical Compose validation must explicitly reject symlinks")
immich_helper_copy = deployment_tasks.find do |task|
  task["name"] == "Copy the tracked Immich restore classifier from the controller"
end
check(failures,
      immich_helper_copy&.dig("ansible.builtin.copy", "src") ==
        "{{ playbook_dir }}/services/immich/classify_restore.py" &&
        immich_helper_copy&.dig("ansible.builtin.copy", "dest") ==
          "{{ deployment_bundle_staging_dir }}/services/immich/classify_restore.py" &&
        immich_helper_copy&.dig("ansible.builtin.copy", "mode") == "0644",
      "deployment bundle must package the exact Immich classifier with mode 0644")
kapowarr_patch_copy = deployment_tasks.find do |task|
  task["name"] == "Copy the carried Kapowarr task handler patch from the controller"
end
check(failures,
      kapowarr_patch_copy&.dig("ansible.builtin.copy", "src") ==
        "{{ playbook_dir }}/services/kapowarr/tasks.py" &&
        kapowarr_patch_copy&.dig("ansible.builtin.copy", "dest") ==
          "{{ deployment_bundle_staging_dir }}/services/kapowarr/tasks.py" &&
        kapowarr_patch_copy&.dig("ansible.builtin.copy", "mode") == "0644",
      "deployment bundle must package the carried Kapowarr patch with mode 0644")
staging_directory_task = deployment_tasks.find do |task|
  task["name"] == "Create the clean staging release"
end
staging_directories = Array(staging_directory_task&.dig("loop"))
check(failures,
      staging_directories.include?("{{ deployment_bundle_staging_dir }}/config") &&
        staging_directory_task&.dig("ansible.builtin.file", "mode") == "0755",
      "deployment bundle must create the acquisition catalog staging directory with mode 0755")
catalog_copy = deployment_tasks.find do |task|
  task["name"] == "Copy the media acquisition catalog from the controller"
end
check(failures,
      catalog_copy&.dig("ansible.builtin.copy", "src") ==
        "{{ playbook_dir }}/config/media-acquisition.yml" &&
        catalog_copy&.dig("ansible.builtin.copy", "dest") ==
          "{{ deployment_bundle_staging_dir }}/config/media-acquisition.yml" &&
        catalog_copy&.dig("ansible.builtin.copy", "mode") == "0644" &&
        catalog_copy&.dig("changed_when") == false &&
        catalog_copy&.dig("when") == "not ansible_check_mode",
      "deployment bundle must stage the exact acquisition catalog bytes with mode 0644")
register_copy = deployment_tasks.find do |task|
  task["name"] == "Copy the managed-user capability register from the controller"
end
check(failures,
      register_copy&.dig("ansible.builtin.copy", "src") ==
        "{{ playbook_dir }}/config/managed-user-capabilities.yml" &&
        register_copy&.dig("ansible.builtin.copy", "dest") ==
          "{{ deployment_bundle_staging_dir }}/config/managed-user-capabilities.yml" &&
        register_copy&.dig("ansible.builtin.copy", "mode") == "0644" &&
        register_copy&.dig("changed_when") == false &&
        register_copy&.dig("when") == "not ansible_check_mode",
      "deployment bundle must stage the exact managed-user capability register with mode 0644")
# One containment validation, run once and before the first mutation; its guard
# stops a full converge repeating the play's pre_task validation.
bundle_target_indexes = deployment_tasks.each_index.select do |index|
  deployment_tasks[index]["ansible.builtin.include_tasks"] == "target.yml"
end
bundle_target_index = bundle_target_indexes.one? ? bundle_target_indexes.first : nil
bundle_target = bundle_target_index && deployment_tasks[bundle_target_index]
first_target_mutation = deployment_tasks.index do |task|
  %w[ansible.builtin.file ansible.builtin.copy ansible.builtin.template].any? do |module_name|
    task.key?(module_name)
  end
end
check(failures, bundle_target_indexes.one?,
      "deployment bundle must validate target containment exactly once, not beside each mutation")
check(failures,
      !bundle_target.nil? && !first_target_mutation.nil? &&
        bundle_target_index < first_target_mutation,
      "deployment bundle must validate target containment before its first target mutation")
check(failures,
      Array(bundle_target && bundle_target["when"]).join(" ")
        .include?("deployment_bundle_target_validated"),
      "deployment bundle target validation must be skipped when the play already validated")
check(failures,
      bundle_target&.dig("vars", "deployment_target_require_current_release") == false,
      "deployment bundle must not require an active current release before it installs one")
release_compare_path = File.join(ROOT, "roles", "deployment_bundle", "files",
                                 "compare_release_trees.py")
release_compare_source = File.exist?(release_compare_path) ? File.read(release_compare_path) : ""
release_compare_tasks = deployment_tasks.select do |task|
  task["name"] == "Compare the staged and immutable releases"
end
release_compare_argv = release_compare_tasks.one? ?
  Array(release_compare_tasks.first.dig("ansible.builtin.command", "argv")) : []
release_compare_lookup =
  "{{ lookup('ansible.builtin.file', role_path ~ '/files/compare_release_trees.py') }}"
check(failures, release_compare_tasks.one? &&
                release_compare_argv[1] == "-c" &&
                release_compare_argv[2] == release_compare_lookup &&
                release_compare_argv.count(release_compare_lookup) == 1,
      "deployment bundle must compare releases with the tracked comparison script")
%w[stat.S_IMODE st.st_uid st.st_gid os.lstat].each do |metadata|
  check(failures, release_compare_source.include?(metadata),
        "immutable release comparison must include #{metadata}")
end

# Read defensively: policy_test.rb owns the malformed-manifest diagnostic, so the
# checks that need the manifest stand down without it.
manifest_entries = begin
  manifest_document = YAML.safe_load_file(File.join(ROOT, "services", "manifest.yml"))
  manifest_document.is_a?(Hash) ? Array(manifest_document["services"]) : []
rescue Psych::SyntaxError
  []
end
manifest_entries = manifest_entries.select { |entry| entry.is_a?(Hash) }
manifest_known = !manifest_entries.empty?
manifest_service_directories = manifest_entries.to_h do |entry|
  [entry["role"], entry["name"]]
end

# Parsed, not byte offsets. The validating task names the runtime roots itself, so it
# is excluded from the first-use search.
%w[beszel dozzle audiobookshelf komga jellyfin immich
   paperless_ngx].each do |service_name|
  # Through static_role_tasks, not main.yml: a one-stage-per-file role's main.yml is an
  # index, and reading it made this check pass vacuously.
  service_tasks = PolicySupport.static_role_tasks(
    File.join(ROOT, "roles", service_name, "tasks", "main.yml"), aliases: true
  )
  target_validation = service_tasks.index do |task|
    include_role = task["ansible.builtin.include_role"]
    include_role.is_a?(Hash) && include_role["name"] == "deployment_bundle" &&
      include_role["tasks_from"] == "target"
  end
  runtime_use = service_tasks.each_with_index.find do |task, index|
    index != target_validation &&
      YAML.dump(task).match?(/platform_runtime_dir|platform_current_dir/)
  end&.last
  check(failures, !runtime_use || (target_validation && target_validation < runtime_use),
        "#{service_name} must revalidate target paths before runtime/current use")
  next unless target_validation

  # target.yml derives both Compose files from the service name, which must come from
  # the manifest (paperless_ngx deploys services/paperless-ngx).
  named_service = (service_tasks.fetch(target_validation)["vars"] || {})["deployment_target_service"]
  check(failures, !manifest_known || named_service == manifest_service_directories[service_name],
        "#{service_name} must name the manifest service whose Compose files a selective run deploys")
end

# Integration suites always tag deployment_bundle, so a lone --tags <service> run is
# never exercised: resolve before activation, and keep the always tag.
compose_bundle_tasks = YAML.safe_load_file(
  File.join(ROOT, "roles", "deployment_bundle", "tasks", "main.yml"), aliases: true
)
selection_index = compose_bundle_tasks.index do |task|
  include_tasks = task["ansible.builtin.include_tasks"]
  include_tasks.is_a?(Hash) && include_tasks["file"] == "compose_files.yml"
end
activation_index = compose_bundle_tasks.index do |task|
  task["name"] == "Atomically activate the controller release"
end
bundle_selection = selection_index && compose_bundle_tasks[selection_index]
check(failures,
      !bundle_selection.nil? && !activation_index.nil? &&
        selection_index > activation_index &&
        Array(bundle_selection["tags"]).include?("always") &&
        Array(bundle_selection.dig("ansible.builtin.include_tasks", "apply", "tags"))
          .include?("always"),
      "deployment_bundle must resolve Compose selection after activation, under every tag")

verify_play = YAML.safe_load_file(File.join(ROOT, "verify.yml"), aliases: true).first
verify_selection = Array(verify_play["pre_tasks"]).find do |task|
  task.dig("ansible.builtin.include_role", "tasks_from") == "compose_files"
end
check(failures,
      !verify_selection.nil? &&
        Array(verify_selection["tags"]).include?("always") &&
        Array(verify_selection.dig("ansible.builtin.include_role", "apply", "tags"))
          .include?("always"),
      "verify.yml must resolve Compose selection before any verified role reads it")

# verify.yml skips preflight, but beszel_agent_enabled reads preflight_gpu_available
# on non-portable hosts, so the fact must be available there.
verify_gpu = Array(verify_play["pre_tasks"]).find do |task|
  task.dig("ansible.builtin.include_role", "tasks_from") == "gpu"
end
check(failures,
      !verify_gpu.nil? &&
        Array(verify_gpu["tags"]).include?("always") &&
        Array(verify_gpu.dig("ansible.builtin.include_role", "apply", "tags"))
          .include?("always"),
      "verify.yml must resolve hardware acceleration before any verified role reads it")

# Source text on purpose: manifest.yml.j2 is a Jinja template, not YAML. The rendered
# output is checked by tests/verify_deployment_manifest.rb in the integration lanes.
deployment_manifest_template = File.read(
  File.join(ROOT, "roles", "deployment_bundle", "templates", "manifest.yml.j2")
)
check(failures, deployment_manifest_template.include?("platform_release_id | to_json"),
      "deployment manifest must quote git_sha as a YAML string")
check(failures, deployment_manifest_template.include?("platform_compose") &&
                deployment_manifest_template.include?("canonical_compose") &&
                deployment_manifest_template.include?("compose_service_name"),
      "deployment manifest images must merge canonical and platform Compose services")
check(failures, deployment_manifest_template.include?("runtime_files:") &&
                deployment_manifest_template.include?("'immich': ['classify_restore.py']") &&
                deployment_manifest_template.include?("'kapowarr': ['tasks.py']") &&
                deployment_manifest_template.include?("mode: \"0644\"") &&
                deployment_manifest_template.include?("runtime_file") &&
                deployment_manifest_template.include?("hash('sha256')"),
      "deployment manifest must bind runtime helper paths, modes, and checksums")
# Top-level key order read off whole lines, since the rendered manifest keeps it.
manifest_template_lines = deployment_manifest_template.lines.map(&:chomp)
platform_inputs_index = manifest_template_lines.index("platform_inputs:")
services_index = manifest_template_lines.index("services:")
check(failures,
      !platform_inputs_index.nil? && !services_index.nil? && platform_inputs_index < services_index &&
        deployment_manifest_template.include?("- path: config/media-acquisition.yml") &&
        deployment_manifest_template.include?("mode: \"0644\"") &&
        deployment_manifest_template.include?(
          "lookup('file', playbook_dir ~ '/config/media-acquisition.yml', rstrip=false)"
        ) && deployment_manifest_template.include?("hash('sha256')") &&
        deployment_manifest_template.include?("| to_json"),
      "deployment manifest must bind the exact acquisition catalog path, mode, and checksum")
check(failures,
      deployment_manifest_template.include?("- path: config/managed-user-capabilities.yml") &&
        deployment_manifest_template.include?(
          "lookup('file', playbook_dir ~ '/config/managed-user-capabilities.yml', rstrip=false)"
        ),
      "deployment manifest must bind the exact managed-user capability register path and checksum")
compose_metadata_filter = File.read(
  File.join(ROOT, "filter_plugins", "compose_metadata.py")
)
compose_metadata_behavior_tasks = flatten_tasks(
  YAML.safe_load_file(File.join(ROOT, "tests", "compose_metadata_filter_test.yml"), aliases: true)
    .flat_map { |play| Array(play["tasks"]) }
)
compose_metadata_behavior_names = compose_metadata_behavior_tasks.filter_map { |task| task["name"] }
check(failures, deployment_manifest_template.include?("| platform_compose_metadata") &&
                !deployment_manifest_template.match?(/regex_replace\(['\"]!override|regex_replace\(['\"]!reset/),
      "deployment manifest must parse Compose tags without rewriting source text")
check(failures, compose_metadata_filter.include?("yaml.SafeLoader") &&
                compose_metadata_filter.include?("(\"!override\", \"!reset\")") &&
                compose_metadata_filter.include?("except yaml.YAMLError") &&
                compose_metadata_filter.include?("unsupported YAML") &&
                !compose_metadata_filter.include?("add_multi_constructor"),
      "Compose metadata loader must allow only exact known tags and fail closed")
check(failures, compose_metadata_behavior_names
                  .include?("Parse quoted, block, and commented literal markers") &&
                compose_metadata_behavior_names
                  .include?("Require unknown YAML tags to fail closed") &&
                File.readlines(File.join(ROOT, "tests", "validate-policy.sh"), chomp: true)
                    .any? { |line| line.include?("tests/compose_metadata_filter_test.yml") },
      "policy validation must execute Compose metadata parser behavior tests")

site_source = File.read(File.join(ROOT, "site.yml"))
check(failures, !site_source.include?("nothing is delegated to the controller"),
      "site documentation must acknowledge explicit controller delegation")

integration_evidence = controller +
                       File.read(File.join(ROOT, "tests", "verify_deployment_manifest.rb"))
%w[
  STALE_ROOT_SEEDED STALE_BUNDLE_REPLACED STALE_BUNDLE_CLEAN STALE_MANIFEST_EXACT
  ISOLATED_IMAGE_MERGE_EXACT
  RUNTIME_SERVICE_SYMLINK_REFUSED RUNTIME_SERVICE_SYMLINK_PRESERVED
  CONTROLLER_MANIFEST_SYMLINK_REFUSED CONTROLLER_OVERRIDE_SYMLINK_REFUSED
  CONTROLLER_SYMLINK_TARGET_UNCHANGED SYMLINK_BESZEL_COMPOSE_REFUSED
  FRESH_ROOT_OK SYMLINK_DOCKER_ROOT_REFUSED SYMLINK_DEPLOY_ROOT_REFUSED SYMLINK_RELEASES_REFUSED
  SYMLINK_RUNTIME_REFUSED SYMLINK_ROOT_ANCESTOR_REFUSED
  SYMLINK_PREFLIGHT_PROBE_REFUSED
  EXISTING_PREFLIGHT_PROBE_REFUSED EXISTING_PREFLIGHT_PROBE_PRESERVED
  INTERRUPTED_PREFLIGHT_PROBE_RECLAIMED
  SYMLINK_ESCAPE_STATE_UNCHANGED
  ACTIVE_BYTE_DRIFT_REFUSED ACTIVE_MODE_DRIFT_REFUSED ACTIVE_OWNERSHIP_DRIFT_REFUSED
  ACTIVE_DRIFT_PRESERVED
  MANIFEST_EXACT MANIFEST_EFFECTIVE_IMAGES
].each do |evidence|
  check(failures, integration_evidence.include?(evidence),
        "integration must execute and report #{evidence.downcase.tr('_', ' ')}")
end
check(failures, harness.include?('stale_docker_root="$sandbox/stale-root/Docker"') &&
                controller.include?(%(test ! -e "$sandbox/volume1/Docker/nas-platform")),
      "integration must isolate stale replacement from the genuinely fresh service root")
# The gate must run tests/verify_deployment_manifest.rb --self-test (#657); nothing
# else does.
check(failures, File.readlines(File.join(ROOT, "tests", "validate-policy.sh"), chomp: true)
                    .include?("ruby tests/verify_deployment_manifest.rb --self-test"),
      "policy validation must run the deployment manifest verifier's own self-test")
manifest_verifier = File.read(File.join(ROOT, "tests", "verify_deployment_manifest.rb"))
check(failures, manifest_verifier.include?("require-image-merge") &&
                manifest_verifier.include?("if require_image_merge"),
      "effective-image replacement proof must be opt-in for an isolated fixture")
check(failures, manifest_verifier.include?("RUNTIME_FILES") &&
                manifest_verifier.include?('"immich" => ["classify_restore.py"]') &&
                manifest_verifier.include?('"mode" => "0644"'),
      "deployment manifest verifier must reproduce runtime helper integrity")
check(failures,
      manifest_verifier.include?('"platform_inputs"') &&
        manifest_verifier.include?('["config/media-acquisition.yml", "acquisition catalog"]') &&
        manifest_verifier.include?(
          '["config/managed-user-capabilities.yml", "managed-user capability register"]'
        ) &&
        manifest_verifier.include?('"mode" => "0644"') &&
        manifest_verifier.include?("Digest::SHA256.file") &&
        manifest_verifier.include?("File.dirname(manifest_path)"),
      "deployment manifest verifier must require the exact platform input digests and detect " \
      "staged-byte mutation")

immich_classifier = File.join(ROOT, "services", "immich", "classify_restore.py")
check(failures, owned_file?(immich_classifier, File.join(ROOT, "services", "immich")) &&
                (File.stat(immich_classifier).mode & 0o777) == 0o644,
      "Immich classifier must have one canonical mode-0644 service source")
check(failures, !File.exist?(File.join(ROOT, "roles", "immich", "files", "classify_restore.py")),
      "Immich classifier must not retain a divergent role-local source")


# Every re-include entry point declares an argument spec, so a mistyped parameter
# fails the run instead of silently downgrading containment. Both parameters are
# required; callers with no extra paths pass [].
%w[main controller inputs compose_files target].each do |entry_point|
  check(failures, deployment_spec.dig("argument_specs", entry_point).is_a?(Hash),
        "deployment bundle must declare an argument spec for its #{entry_point} entry point")
end
target_options = deployment_spec.dig("argument_specs", "target", "options") || {}
require_current_option = target_options["deployment_target_require_current_release"]
check(failures, require_current_option.is_a?(Hash) &&
                require_current_option["type"] == "bool" &&
                require_current_option["required"] == true,
      "the target entry point must require an explicit release-containment flag")
extra_paths_option = target_options["deployment_target_extra_paths"]
check(failures, extra_paths_option.is_a?(Hash) && extra_paths_option["type"] == "list" &&
                extra_paths_option["elements"] == "path" &&
                extra_paths_option["required"] == true,
      "the target entry point must require an explicit list of the paths its caller touches")
service_option = target_options["deployment_target_service"]
check(failures, service_option.is_a?(Hash) && service_option["type"] == "str" &&
                service_option["required"] == true,
      "the target entry point must require an explicit service name for its derived paths")
check(failures, deployment_defaults.keys.none? { |name| name.start_with?("deployment_target_") },
      "target containment parameters must not be silently defaulted in role defaults")
check(failures,
      !target_tasks_body.match?(/deployment_target_\w+\s*\|\s*default/) &&
        !File.read(File.join(ROOT, "roles", "deployment_bundle", "tasks", "controller_input.yml"))
             .match?(/deployment_controller_input\w*\s*\|\s*default/),
      "include-entry parameters must fail loudly rather than fall back to a default")

# Enumerated from every playbook and role reaching target.yml, since include_tasks never
# validates. policy_mutation_support.rb's fixture list must name each of these files.
target_include_sites = []
playbook_paths = [
  File.join(ROOT, "site.yml"),
  File.join(ROOT, "verify.yml"),
  File.join(ROOT, "tests", "mac_inventory_path_test.yml"),
  File.join(ROOT, "tests", "deployment_lock_refusal_test.yml")
]
playbook_paths.each do |path|
  Array(YAML.safe_load_file(path, aliases: true)).each do |play|
    next unless play.is_a?(Hash)

    %w[pre_tasks tasks post_tasks].each do |section|
      flatten_tasks(play[section]).each do |task|
        include_role = task["ansible.builtin.include_role"]
        next unless include_role.is_a?(Hash) && include_role["name"] == "deployment_bundle" &&
                    include_role["tasks_from"] == "target"

        target_include_sites << [path.delete_prefix("#{ROOT}/"), task]
      end
    end
  end
end
# Which role deploys which service from the release: a role starting a stack from
# {{ platform_current_dir }} touches target.yml's five paths.
release_deploying_services = Hash.new { |roles, role| roles[role] = Set.new }
parametric_release_deployers = Hash.new { |roles, role| roles[role] = Set.new }
Dir[File.join(ROOT, "roles", "*", "tasks", "*.yml")].sort.each do |path|
  relative_path = path.delete_prefix("#{ROOT}/")
  owning_role = relative_path[%r{\Aroles/([^/]+)/tasks/}, 1]
  flatten_tasks(YAML.safe_load_file(path, aliases: true)).each do |task|
    include_role = task["ansible.builtin.include_role"]
    included_tasks = task["ansible.builtin.include_tasks"]
    included_file = included_tasks.is_a?(Hash) ? included_tasks["file"] : included_tasks
    includes_target =
      (include_role.is_a?(Hash) && include_role["name"] == "deployment_bundle" &&
       include_role["tasks_from"] == "target") ||
      (included_file == "target.yml" && relative_path.start_with?("roles/deployment_bundle/"))
    target_include_sites << [relative_path, task] if includes_target

    compose = task["community.docker.docker_compose_v2"]
    next unless compose.is_a?(Hash)

    deployed = compose["project_src"].to_s[%r{\A\{\{ platform_current_dir \}\}/services/(.+)\z}, 1]
    next unless deployed

    # A shared role's stack is its caller's, so the caller's include must contain it (#836).
    parameter = deployed[/\A\{\{ ([a-z0-9_]+) \}\}\z/, 1]
    if parameter
      parametric_release_deployers[owning_role] << parameter
    else
      release_deploying_services[owning_role] << deployed
    end
  end
end
Dir[File.join(ROOT, "roles", "*", "tasks", "*.yml")].sort.each do |path|
  caller_role = path.delete_prefix("#{ROOT}/")[%r{\Aroles/([^/]+)/tasks/}, 1]
  flatten_tasks(YAML.safe_load_file(path, aliases: true)).each do |task|
    shared = task.dig("ansible.builtin.include_role", "name")
    next unless parametric_release_deployers.key?(shared)

    parametric_release_deployers[shared].each do |parameter|
      service = (task["vars"] || {})[parameter]
      release_deploying_services[caller_role] << (service.is_a?(String) ? service : "{{ #{parameter} }}")
    end
  end
end
# Anchored on the call sites no service role owns, not a count, because mutation
# fixtures reduce role files.
enumerated_callers = target_include_sites.map(&:first).uniq
check(failures,
      enumerated_callers.include?("site.yml") &&
        enumerated_callers.include?("roles/deployment_bundle/tasks/main.yml"),
      "target containment call-site enumeration found #{target_include_sites.length} sites in " \
      "#{enumerated_callers.join(', ')}; the callers that must declare what they touch are no " \
      "longer being inspected")

# A role that never includes target.yml escapes the enumeration above. The subject is
# derived from what roles do, not from the manifest, because the mutation harness
# stubs role files; a stub deploys nothing and owes nothing.
declared_services_by_role = Hash.new { |roles, role| roles[role] = Set.new }
target_include_sites.each do |relative_path, task|
  owning_role = relative_path[%r{\Aroles/([^/]+)/tasks/}, 1]
  next if owning_role.nil?

  declared = (task["vars"] || {})["deployment_target_service"]
  declared_services_by_role[owning_role] << declared if declared.is_a?(String) && !declared.empty?
end
# Sized against the mutation sandbox (#386), well under today's count so a
# legitimate service removal does not fail it.
check_floor(failures, release_deploying_services.length, 10,
            "roles deploying a stack out of the installed release")
release_deploying_services.each do |role, deployed_services|
  missing = deployed_services - declared_services_by_role[role]
  check(failures, missing.empty?,
        "role #{role} starts #{missing.sort.join(', ')} out of the installed release but no " \
        "task in it includes deployment_bundle tasks_from: target naming that service, so the " \
        "five paths it is about to touch are never contained")
end
exercised_playbook_exemptions = []
target_include_sites.each do |relative_path, task|
  task_vars = task["vars"] || {}
  label = "#{relative_path}: \"#{task['name']}\""
  requires_current_release = task_vars["deployment_target_require_current_release"]
  check(failures, [true, false].include?(requires_current_release),
        "#{label} must state whether target validation requires an active current release")

  # Service roles deploy out of the release and must pass `true`; only
  # deployment_bundle and host_prep pass `false`. A playbook may pass `false` only if
  # RELEASE_OPTIONAL_PLAYBOOKS names it with a reason.
  caller_role = relative_path[%r{\Aroles/([^/]+)/tasks/}, 1]
  if caller_role.nil?
    recorded_reason = RELEASE_OPTIONAL_PLAYBOOKS[relative_path]
    reason_recorded = recorded_reason.is_a?(String) && !recorded_reason.strip.empty?
    check(failures, requires_current_release == true || reason_recorded,
          "#{label} is a playbook's target include and passes false with no recorded reason; " \
          "either pass true or record #{relative_path} in RELEASE_OPTIONAL_PLAYBOOKS with the " \
          "reason it runs before a release exists")
    exercised_playbook_exemptions << relative_path if reason_recorded &&
                                                      requires_current_release == false
  elsif !RELEASE_OPTIONAL_ROLES.include?(caller_role)
    check(failures, requires_current_release == true,
          "#{label} is a service role's target include and must require an active current " \
          "release; only #{RELEASE_OPTIONAL_ROLES.sort.join(' and ')} run before one exists")
  end
  declared_extra_paths = task_vars["deployment_target_extra_paths"]
  check(failures, declared_extra_paths.is_a?(Array) ||
                  declared_extra_paths.to_s.match?(/\A\{\{.*\}\}\z/m),
        "#{label} must declare the extra paths it is about to touch, even when there are none")

  # A named service makes target.yml derive five paths, so the name must resolve via
  # services/manifest.yml to this role, and the role must use all five; otherwise the
  # declaration is widened and the validator accepts paths nobody writes.
  declared_service = task_vars["deployment_target_service"]
  check(failures, declared_service.is_a?(String),
        "#{label} must name the service whose standard deployment paths it touches, " \
        "or the empty string when it owns none")
  next unless manifest_known && declared_service.is_a?(String) && !declared_service.empty?

  owning_role = relative_path[%r{\Aroles/([^/]+)/tasks/}, 1]
  manifest_entry = manifest_entries.find { |entry| entry["name"] == declared_service }
  check(failures, !manifest_entry.nil? && manifest_entry["role"] == owning_role,
        "#{label} names service #{declared_service.inspect}, which is not the manifest service " \
        "directory deployed by role #{owning_role.inspect}")
  next unless manifest_entry && manifest_entry["role"] == owning_role

  role_tasks = Dir[File.join(ROOT, "roles", owning_role, "tasks", "*.yml")].sort.flat_map do |file|
    flatten_tasks(YAML.safe_load_file(file, aliases: true))
  end
  runtime_env = "{{ platform_runtime_dir }}/services/#{declared_service}/.env"
  release_dir = "{{ platform_current_dir }}/services/#{declared_service}"
  compose_selection = "{{ platform_service_compose_files['#{declared_service}'] }}"
  renders_env = role_tasks.any? do |role_task|
    %w[ansible.builtin.template ansible.builtin.copy].any? do |module_name|
      role_task[module_name].is_a?(Hash) && role_task[module_name]["dest"] == runtime_env
    end
  end
  deploys_release = role_tasks.any? do |role_task|
    compose = role_task["community.docker.docker_compose_v2"]
    compose.is_a?(Hash) && compose["project_src"] == release_dir &&
      compose["files"] == compose_selection &&
      Array(compose["env_files"]).include?(runtime_env)
  end
  check(failures, renders_env,
        "#{label} derives #{runtime_env} but role #{owning_role} never renders it")
  check(failures, deploys_release,
        "#{label} derives the #{declared_service} release directory and both its Compose files " \
        "but role #{owning_role} never deploys that project from them")
end
# A floor, not per-key liveness: a mutation row removes site.yml's pre_tasks include.
check_floor(failures, exercised_playbook_exemptions.length, 2,
            "recorded playbook release-containment exemptions still taken")


# Check mode skips release activation, so `current` still names the old release
# under --check. Check mode must accept a stale pointer; a real run must refuse it.
def probe_stale_current_pointer(check_mode)
  old_release = "b" * 40
  new_release = "c" * 40
  Dir.mktmpdir("nas-platform-deployment-target-") do |raw_directory|
    # The validator refuses a symlinked storage-root ancestor; macOS mktmpdir is under /var.
    directory = File.realpath(raw_directory)
    docker_root = File.join(directory, "dock")
    media_root = File.join(directory, "media")
    deploy_root = File.join(docker_root, "nas-platform")
    FileUtils.mkdir_p([File.join(deploy_root, "releases", old_release),
                       File.join(deploy_root, "releases", new_release),
                       File.join(deploy_root, "runtime"), media_root])
    File.symlink(File.join(deploy_root, "releases", old_release),
                 File.join(deploy_root, "current"))
    playbook = File.join(directory, "probe.yml")
    File.write(playbook, YAML.dump([{
      "name" => "Probe target containment against a stale current pointer",
      "hosts" => "localhost", "connection" => "local", "gather_facts" => true,
      "vars" => {
        "nas_docker_root" => docker_root, "nas_media_root" => media_root,
        "platform_release_id" => new_release, "platform_kind" => "nas",
        "platform_compose_kind" => "{{ platform_kind }}",
        "platform_deploy_root" => "{{ nas_docker_root }}/nas-platform",
        "platform_release_dir" => "{{ platform_deploy_root }}/releases/{{ platform_release_id }}",
        "platform_current_dir" => "{{ platform_deploy_root }}/current",
        "platform_runtime_dir" => "{{ platform_deploy_root }}/runtime"
      },
      "tasks" => [{
        "name" => "Validate target paths",
        "ansible.builtin.include_role" => { "name" => "deployment_bundle", "tasks_from" => "target" },
        "vars" => { "deployment_target_service" => "",
                    "deployment_target_require_current_release" => true,
                    "deployment_target_extra_paths" => [] }
      }]
    }]))
    command = ["ansible-playbook", "-i", "localhost,", playbook]
    command << "--check" if check_mode
    stdout, stderr, status = Open3.capture3(
      { "ANSIBLE_NOCOLOR" => "1", "ANSIBLE_CONFIG" => File.join(ROOT, "ansible.cfg"),
        "ANSIBLE_ROLES_PATH" => File.join(ROOT, "roles") },
      *command, chdir: directory
    )
    [status.success?, stdout + stderr]
  end
end

check_mode_passes, _check_output = probe_stale_current_pointer(true)
check(failures, check_mode_passes,
      "check mode must not require a current release it is structurally unable to activate")
real_run_passes, real_output = probe_stale_current_pointer(false)
check(failures, !real_run_passes,
      "a real run must still refuse a current pointer naming a different release")
# Asserted by message: the fixture can fail for unrelated reasons.
check(failures, real_output.include?("does not resolve to"),
      "the real-run refusal must name the release the current pointer failed to reach")

# CLAUDE.md: "site.yml must never depend on anything
# install-production-auto-deploy.yml installs" (#327). Checked in two halves.
# First, the paths: fragments derived from the poller and prune defaults are swept
# for across everything site.yml can reach, and every reference is pinned.
# An unreadable defaults file in a present role directory is a fault (#596); an absent
# role directory is not, because the mutation sandbox carries no roles/image_prune.
POLLER_ROLES = %w[production_auto_deploy image_prune].freeze
unusable_poller_defaults = []
poller_fragments_by_role = {}
POLLER_INSTALLED_FRAGMENTS = POLLER_ROLES.flat_map do |role|
  defaults_path = File.join(ROOT, "roles", role, "defaults", "main.yml")
  document = File.file?(defaults_path) ? YAML.safe_load_file(defaults_path) : nil
  unless document.is_a?(Hash)
    unusable_poller_defaults << defaults_path.delete_prefix("#{ROOT}/") if Dir.exist?(File.join(ROOT, "roles", role))
    next []
  end

  # Also recorded per role, for the per-role floor below.
  fragments = document.filter_map do |key, value|
    next unless key.end_with?("_root", "_path") && value.is_a?(String)

    value.gsub(/\{\{.*?\}\}/m, " ").scan(%r{[A-Za-z0-9/._-]+})
         .select { |fragment| fragment.include?("nas-platform") }
         .map { |fragment| fragment.sub(%r{\A/}, "").sub(%r{/\z}, "") }
  end.flatten.uniq
  poller_fragments_by_role[role] = fragments
  fragments
end.uniq.sort.freeze
check(failures, unusable_poller_defaults.empty?,
      "#{unusable_poller_defaults.inspect} is missing, empty or not a mapping, so the poller " \
      "paths that role installs were derived from nothing and the sweep below cannot find a " \
      "reference to any of them. A role that installs nothing and a role whose defaults could " \
      "not be read are different states, and only the first is a reason to assert nothing. The " \
      "floor beside this does not reach it: the other poller role supplies three fragments " \
      "alone, so the count stays satisfied while half the subject is gone")
# Counted per role (#597): `--- {}` or a renamed key empties a role's contribution
# without a read failure, and the union floor cannot see it because the roles share
# two fragments. Sized at exactly 3 with no slack, since the defect is losing one;
# lower it in the same commit as a legitimate drop. Keyed on roles that parsed.
POLLER_ROLE_FRAGMENT_FLOOR = 3
starved_poller_roles = poller_fragments_by_role
                       .select { |_role, fragments| fragments.length < POLLER_ROLE_FRAGMENT_FLOOR }
                       .transform_values(&:length)
check(failures, starved_poller_roles.empty?,
      "#{starved_poller_roles.inspect} derived fewer than #{POLLER_ROLE_FRAGMENT_FLOOR} " \
      "distinctive path fragments from defaults that parsed, so the sweep below cannot find a " \
      "reference to whichever of them went missing. A valid mapping with no keys and a key " \
      "whose suffix stopped matching both read as a role that installs nothing, and neither " \
      "poller role installs nothing")
# Kept beneath the per-role floors: narrowing POLLER_ROLES starves those, not this.
check_floor(failures, POLLER_INSTALLED_FRAGMENTS.length, 3,
            "distinctive path fragments install-production-auto-deploy.yml creates")

# Every file the two poller roles do not own (vault_contract runs in site.yml too).
POLLER_PATH_REFERENCE_REASONS = {
  "roles/deployment_bundle/defaults/main.yml" =>
    "derives the flock path independently and tolerates its absence -- a host with no " \
    "poller installed finds no file and is not guarded",
  "roles/deployment_bundle/tasks/target.yml" =>
    "names the launcher in a refusal message so the operator is told how to take the lock",
  "roles/deployment_bundle/meta/argument_specs.yml" =>
    "documents which program exports PLATFORM_DEPLOYMENT_LOCK_OWNER"
}.freeze
site_reachable_files = (Dir[File.join(ROOT, "roles", "**", "*")] +
                        [File.join(ROOT, "site.yml"), File.join(ROOT, "verify.yml")])
                       .select { |path| File.file?(path) }
                       .map { |path| path.delete_prefix("#{ROOT}/") }
                       .reject { |path| path.start_with?("roles/production_auto_deploy/", "roles/image_prune/") }
# Both floors are sized against the mutation sandbox, which omits roles/image_prune.
check_floor(failures, site_reachable_files.length, 30, "files a site.yml run can reach")
# Intersected with what is present: a smaller sandbox has not gained a coupling.
expected_references = (POLLER_PATH_REFERENCE_REASONS.keys & site_reachable_files).sort
referencing_files = site_reachable_files.select do |path|
  contents = File.read(path)
  POLLER_INSTALLED_FRAGMENTS.any? { |fragment| contents.include?(fragment) }
end.sort
check(failures, referencing_files == expected_references,
      "site.yml must not depend on what install-production-auto-deploy.yml installs; " \
      "#{referencing_files.join(', ')} name a poller-installed path, and the recorded set is " \
      "#{expected_references.join(', ')}. A new entry must tolerate the path's absence for one " \
      "deployment and say so here")

# Second, the behaviour #327 crossed: the refusal must keep tolerating a lock holder
# that recorded no identity. Both the definition and its use are asserted.
lock_block = YAML.safe_load_file(File.join(ROOT, "roles", "deployment_bundle", "tasks", "target.yml"))
                 .find do |task|
  task.is_a?(Hash) && task["block"].is_a?(Array) &&
    (task["vars"] || {}).key?("deployment_bundle_lock_identified")
end
check(failures, !lock_block.nil?,
      "roles/deployment_bundle/tasks/target.yml must define deployment_bundle_lock_identified " \
      "in the vars of the block that judges the deployment lock")
if lock_block
  refusal = lock_block["block"].find do |task|
    conditions = task.dig("ansible.builtin.assert", "that")
    conditions.is_a?(Array) &&
      conditions.join(" ").include?("deployment_bundle_lock_held_by_this_run")
  end
  check(failures, !refusal.nil?, "the deployment lock block must still refuse a foreign holder")
  check(failures, refusal && refusal.dig("ansible.builtin.assert", "that")
                                   .join(" ").include?("deployment_bundle_lock_identified"),
        "the deployment lock refusal must tolerate a holder that recorded no identity; " \
        "refusing one deadlocks the upgrade that installs the poller writing the record, " \
        "which is what #327 did to every five-minute tick")
end

report(failures, "deployment policy: all properties hold", "deployment policy violation(s)")
