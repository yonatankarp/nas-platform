#!/usr/bin/env ruby
# Deployment bundle policy.
#
# A release ID names committed controller content, target paths are hostile input
# until both their lexical form and their filesystem ancestry are checked, and the
# bundle's Compose selection must resolve before activation. Split out of
# policy_test.rb: these checks police roles/deployment_bundle and change with it.

require "fileutils"
require "open3"
require "tmpdir"
require "rbconfig"
require "set"
require "yaml"
require_relative "policy_support"

include PolicySupport
include TestScaffold

# The two roles whose target include legitimately passes
# deployment_target_require_current_release: false, because both run before the
# release exists rather than out of it. Every other role that includes
# deployment_bundle's target tasks deploys from `current` and must require one.
RELEASE_OPTIONAL_ROLES = %w[deployment_bundle host_prep].freeze

failures = []

harness = File.read(File.join(ROOT, "tests", "integration.sh"))
# The launcher is tests/integration.sh; the program it runs in the controller
# container is tests/integration_controller.sh. Every property below is read
# from whichever of the two holds the code it polices.
controller = File.read(File.join(ROOT, "tests", "integration_controller.sh"))
# A release ID names committed controller content. Production must reject any
# modified or untracked file in the controller checkout; only the disposable
# integration platform may opt into the deliberately dirty pre-commit tree.
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

# Target-side deployment paths are hostile inputs until both their lexical form
# and existing filesystem ancestry have been checked. Validation is read-only
# and runs once per distinct set of paths, ahead of the tasks that mutate them:
# before preflight for the play's own paths, and before each service role writes
# runtime configuration or consumes `current` for the extra paths it names. It is
# not repeated beside individual mutations, which the task file explains.
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
# Deliberately source text. The subject is the wording of a comment explaining
# why validation is not repeated beside each mutation, and YAML parsing erases
# comments, so there is no parsed structure to read this from.
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
# The leaves are read off the expression the validated task actually evaluates,
# not off the file's text. A path named in a comment, or in a var some other task
# owns, is not a path this command validates.
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
# The inputs the role actually validates are the ones named by the expression its
# controller_input.yml inclusions evaluate, not every path string that appears
# somewhere in the file. Read them off the parsed tasks: a path that survives only
# in a comment, or that is named by a task which no longer includes the validator,
# validates nothing.
#
# Batched since #333 -- one inclusion validating N inputs rather than N
# inclusions validating one each -- so this reads each inclusion's list
# expression, exactly the way the target validator's paths are read above, rather
# than one path per inclusion. The include filter stays first: a task carrying a
# deployment_controller_inputs var without handing it to the validator names
# paths nothing checks.
validated_input_batches = input_tasks.filter_map do |task|
  next unless task["ansible.builtin.include_tasks"] == "controller_input.yml"

  task.dig("vars", "deployment_controller_inputs").to_s
end
validated_inputs = validated_input_batches.join("\n")
# The second element of each pair is the allow_missing flag the validator has
# always taken, so pinning it beside the path is what asserts an input is
# required rather than optional. Only the platform overrides carry '1'.
check(failures, validated_inputs.include?("playbook_dir ~ '/services/manifest.yml', '0'") &&
                validated_inputs.include?("deployment_bundle_services") &&
                validated_inputs.include?("playbook_dir ~ '/services/'") &&
                validated_inputs.include?("'/compose.yml'") &&
                validated_inputs.include?("'/compose.' ~ platform_compose_kind ~ '.yml'"),
      "controller inputs must validate manifest, canonical Compose, and platform overrides")
check(failures, validated_inputs.include?("playbook_dir ~ '/services/dozzle/alert_relay.py', '0'") &&
                validated_inputs.include?(
                  "playbook_dir ~ '/services/immich/classify_restore.py', '0'"
                ),
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
# One containment validation covers every path this role mutates, so the role
# body must run it exactly once and must run it before the first mutation. The
# guard is what keeps a full converge from repeating the play's own pre_task
# validation; without it the single include silently becomes a second run.
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

# The manifest is the authority for which service directory a role deploys, and
# it is read defensively: policy_test.rb owns the malformed-manifest diagnostic,
# and a parse error raised here would replace that diagnostic with a stack trace.
# Without a parsed manifest there is nothing to check a service name against, so
# the checks that consult it stand down rather than fail over its absence.
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

# Parsed rather than byte-offset: a task name or a variable reference occurring inside a
# comment or a when: expression is not evidence of task ordering. The validating task's own
# deployment_target_extra_paths necessarily name the runtime roots, so it is excluded from
# the first-use search rather than compared against itself.
%w[ntfy beszel dozzle audiobookshelf komga jellyfin immich
   paperless_ngx].each do |service_name|
  # Read through static_role_tasks, not main.yml. A role that is one stage per file
  # keeps only an index in main.yml, and both halves of this check then read false:
  # target_validation is nil because the deployment_bundle re-include moved into
  # deploy.yml, runtime_use is nil because no import entry mentions a runtime path,
  # and `!runtime_use` reports the property holding before `next unless
  # target_validation` skips every check below. Measured on roles/audiobookshelf
  # and roles/jellyfin, which were both passing vacuously here.
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

  # Both Compose files are derived by target.yml from the named service rather
  # than spelled out here, so what a role can still get wrong is the name. The
  # manifest is the authority for it: roles/paperless_ngx deploys
  # services/paperless-ngx, and a name taken from the role would guard nothing
  # a selective run reads.
  named_service = (service_tasks.fetch(target_validation)["vars"] || {})["deployment_target_service"]
  check(failures, !manifest_known || named_service == manifest_service_directories[service_name],
        "#{service_name} must name the manifest service whose Compose files a selective run deploys")
end

# Two runtime failures nothing else catches, because every integration suite includes
# deployment_bundle in its tags and so never exercises a lone --tags <service> run.
# Resolving before activation makes a full run read the previous release's overrides;
# losing the always tag leaves the fact undefined on a selective converge.
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

# beszel_agent_enabled reads preflight_gpu_available on every host whose agent
# kind is not portable, and verify.yml does not run preflight. Without this the
# fact is undefined and verification fails on the NAS while passing on the Mac,
# where the portable branch short-circuits the expression.
verify_gpu = Array(verify_play["pre_tasks"]).find do |task|
  task.dig("ansible.builtin.include_role", "tasks_from") == "gpu"
end
check(failures,
      !verify_gpu.nil? &&
        Array(verify_gpu["tags"]).include?("always") &&
        Array(verify_gpu.dig("ansible.builtin.include_role", "apply", "tags"))
          .include?("always"),
      "verify.yml must resolve hardware acceleration before any verified role reads it")

# Deliberately source text. manifest.yml.j2 is a Jinja template, not a YAML
# document: its `{% for %}` and `{% set %}` lines are not parseable as YAML, and
# what these checks are about is the expression the template will evaluate, which
# only exists in the source. Rendering it needs a real Ansible run against a
# staged bundle, which tests/verify_deployment_manifest.rb does on the rendered
# output during the integration lanes.
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
                deployment_manifest_template.include?("mode: \"0644\"") &&
                deployment_manifest_template.include?("runtime_file") &&
                deployment_manifest_template.include?("hash('sha256')"),
      "deployment manifest must bind runtime helper paths, modes, and checksums")
# Top-level key position, read off whole lines rather than byte offsets. The
# offsets matched "services:" wherever it appeared first, including inside a
# comment or nested under another key; a top-level mapping key is a line of its
# own, so the line index is the ordering the rendered manifest will have.
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
  SYMLINK_PREFLIGHT_PROBE_REFUSED SYMLINK_NTFY_COMPOSE_REFUSED
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
        manifest_verifier.include?('"path" => "config/media-acquisition.yml"') &&
        manifest_verifier.include?('"mode" => "0644"') &&
        manifest_verifier.include?("Digest::SHA256.file") &&
        manifest_verifier.include?("File.dirname(manifest_path)"),
      "deployment manifest verifier must require the exact catalog digest and detect staged-byte mutation")

immich_classifier = File.join(ROOT, "services", "immich", "classify_restore.py")
check(failures, owned_file?(immich_classifier, File.join(ROOT, "services", "immich")) &&
                (File.stat(immich_classifier).mode & 0o777) == 0o644,
      "Immich classifier must have one canonical mode-0644 service source")
check(failures, !File.exist?(File.join(ROOT, "roles", "immich", "files", "classify_restore.py")),
      "Immich classifier must not retain a divergent role-local source")


# Every entry point this role is re-included through is a declared contract.
# include_role applies the argument spec named by tasks_from, so a renamed or
# forgotten parameter fails the run instead of degrading a guard: without the
# declaration, target.yml read deployment_target_require_current_release through
# a default and a typo in any caller silently downgraded release containment to
# "not required" while the run still reported success, and a typo in
# deployment_target_extra_paths silently dropped the paths that caller declared
# it was about to touch. Both are required rather than defaulted, so the callers
# that genuinely have no extra paths write an empty list rather than omit one.
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

# Enumerated rather than listed: a service role added without both parameters is
# the mistake this is here to catch, and site.yml and the deployment bundle's own
# body reach the same task file through include_tasks, which never validates.
target_include_sites = []
playbook_paths = [
  File.join(ROOT, "site.yml"),
  File.join(ROOT, "verify.yml"),
  File.join(ROOT, "tests", "mac_inventory_path_test.yml")
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
# Which role deploys which service out of the installed release, collected from
# the same sweep. This is the subject the absence check below needs: a role that
# starts a stack from {{ platform_current_dir }} is a role that touches the five
# paths target.yml derives, whether or not it ever said so.
release_deploying_services = Hash.new { |roles, role| roles[role] = Set.new }
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
    release_deploying_services[owning_role] << deployed if deployed
  end
end
# Anchored on the two call sites no service role owns rather than on a count:
# the mutation harness replaces individual role task files, so a total would
# report a deliberately reduced fixture as a broken enumeration.
enumerated_callers = target_include_sites.map(&:first).uniq
check(failures,
      enumerated_callers.include?("site.yml") &&
        enumerated_callers.include?("roles/deployment_bundle/tasks/main.yml"),
      "target containment call-site enumeration found #{target_include_sites.length} sites in " \
      "#{enumerated_callers.join(', ')}; the callers that must declare what they touch are no " \
      "longer being inspected")

# The half the enumeration above cannot see. It validates every call site that
# exists, so a role that simply never includes target.yml is green: containment
# is checked for the fifteen roles that ask for it and for nobody else, and a
# sixteenth would deploy a stack having declared nothing. The subject is derived
# from what a role does rather than from the manifest roster deliberately -- the
# mutation harness stubs role task files, and a roster-driven requirement would
# report a deliberately reduced fixture as a missing include, which is the same
# objection the enumeration's own comment records against a count. A stub
# deploys nothing, so it owes nothing here.
declared_services_by_role = Hash.new { |roles, role| roles[role] = Set.new }
target_include_sites.each do |relative_path, task|
  owning_role = relative_path[%r{\Aroles/([^/]+)/tasks/}, 1]
  next if owning_role.nil?

  declared = (task["vars"] || {})["deployment_target_service"]
  declared_services_by_role[owning_role] << declared if declared.is_a?(String) && !declared.empty?
end
check_floor(failures, release_deploying_services.length, 14,
            "roles deploying a stack out of the installed release")
release_deploying_services.each do |role, deployed_services|
  missing = deployed_services - declared_services_by_role[role]
  check(failures, missing.empty?,
        "role #{role} starts #{missing.sort.join(', ')} out of the installed release but no " \
        "task in it includes deployment_bundle tasks_from: target naming that service, so the " \
        "five paths it is about to touch are never contained")
end
target_include_sites.each do |relative_path, task|
  task_vars = task["vars"] || {}
  label = "#{relative_path}: \"#{task['name']}\""
  check(failures, [true, false].include?(task_vars["deployment_target_require_current_release"]),
        "#{label} must state whether target validation requires an active current release")

  # Stating a value is not the rule. CLAUDE.md requires a service role to pass
  # `true` -- it deploys out of the release the bundle installed, so a run that
  # reached it with no active `current` is converging a target that does not
  # exist yet. Only two callers legitimately pass `false`, and both run before
  # there is a release to require: deployment_bundle's own body, which is what
  # installs it, and host_prep, which prepares the directories it lands in. The
  # playbook-level sites are the same case a play earlier: site.yml validates
  # containment in pre_tasks, and the two test playbooks converge nothing.
  # Without this, a service role passing `false` was green.
  caller_role = relative_path[%r{\Aroles/([^/]+)/tasks/}, 1]
  unless caller_role.nil? || RELEASE_OPTIONAL_ROLES.include?(caller_role)
    check(failures, task_vars["deployment_target_require_current_release"] == true,
          "#{label} is a service role's target include and must require an active current " \
          "release; only #{RELEASE_OPTIONAL_ROLES.sort.join(' and ')} run before one exists")
  end
  declared_extra_paths = task_vars["deployment_target_extra_paths"]
  check(failures, declared_extra_paths.is_a?(Array) ||
                  declared_extra_paths.to_s.match?(/\A\{\{.*\}\}\z/m),
        "#{label} must declare the extra paths it is about to touch, even when there are none")

  # Naming a service makes target.yml derive five more paths on the caller's
  # behalf, so the name is now part of what the caller declares it touches. A
  # widened declaration is the failure no other check can see: the containment
  # validator accepts a path nobody writes to, and the run still passes. So the
  # name must resolve through services/manifest.yml to the role that owns this
  # file, and that role must be seen to use all five - the .env it renders, the
  # release directory it deploys from, and the Compose selection keyed by the
  # same manifest name. Anything else is a path this caller does not touch.
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


# Activating a release is a command task, which check mode skips, so `current`
# still names the previous release while target validation runs for real under
# --check. Requiring the new release there made every --check fail on any host
# that had ever deployed -- which no lane could see, because a fresh sandbox has
# no stale pointer to trip over. Both directions are asserted: check mode accepts
# a stale pointer, and a real run still refuses one.
def probe_stale_current_pointer(check_mode)
  old_release = "b" * 40
  new_release = "c" * 40
  Dir.mktmpdir("nas-platform-deployment-target-") do |raw_directory|
    # The validator refuses a storage-root ancestor that is a symlink, and on
    # macOS mktmpdir hands back a path under /var, which is one.
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
# Asserted by its message, not merely by failing: the fixture can fail for
# reasons that have nothing to do with release containment, and a negative test
# that passes for the wrong reason stops guarding anything.
check(failures, real_output.include?("does not resolve to"),
      "the real-run refusal must name the release the current pointer failed to reach")

# CLAUDE.md: "site.yml must never depend on anything
# install-production-auto-deploy.yml installs." The poller runs validate-vault,
# site.yml and verify.yml against the *previously* installed poller and only then
# reinstalls itself, so a play that needs something this revision's poller ships
# deadlocks the upgrade on itself -- #327, which failed every five-minute tick
# identically until a fix reached main. Ten tests name both playbooks and all of
# them assert play order or CI wiring; this is the direction none of them assert.
#
# It is checked in two halves, because the rule has two halves.
#
# First, the paths. The distinctive literal fragments of what the poller and the
# prune install are derived from their own defaults rather than restated, so a
# renamed share root moves the subject with it. Every file a site.yml run can
# reach is then swept for them, and the result is pinned: a new reference is a new
# coupling and has to be justified by editing this list, not by editing a role.
POLLER_INSTALLED_FRAGMENTS = %w[production_auto_deploy image_prune].flat_map do |role|
  defaults_path = File.join(ROOT, "roles", role, "defaults", "main.yml")
  next [] unless File.file?(defaults_path)

  YAML.safe_load_file(defaults_path).filter_map do |key, value|
    next unless key.end_with?("_root", "_path") && value.is_a?(String)

    value.gsub(/\{\{.*?\}\}/m, " ").scan(%r{[A-Za-z0-9/._-]+})
         .select { |fragment| fragment.include?("nas-platform") }
         .map { |fragment| fragment.sub(%r{\A/}, "").sub(%r{/\z}, "") }
  end.flatten
end.uniq.sort.freeze
check_floor(failures, POLLER_INSTALLED_FRAGMENTS.length, 3,
            "distinctive path fragments install-production-auto-deploy.yml creates")

# Every file the two poller roles do not own. The poller playbook runs only those
# two roles plus vault_contract, which site.yml runs as well and is therefore
# swept here; everything else under roles/ is reachable from site.yml or from
# nothing at all, and both are fine to hold to this rule.
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
# Both floors are sized against the mutation sandbox rather than the working tree,
# which carries 183 swept files and three fragments: BASE_FIXTURE_PATHS names 24
# non-poller role files plus site.yml, verify.yml and the fifteen fixture roles'
# statically imported stage files, and it omits roles/image_prune entirely, so
# every fragment there is derived from the poller role alone. A tree-sized floor
# would fail every mutation for a reason unrelated to the mutation.
check_floor(failures, site_reachable_files.length, 30, "files a site.yml run can reach")
# Intersected with what is present for the same reason: the recorded set is there
# to make a *new* coupling fail, and a sandbox that carries fewer files than the
# repository has not gained one. Fixture containment is policed elsewhere.
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

# Second, the behaviour, which is what #327 actually crossed: the guard demanded a
# record only the poller shipping in the same commit writes. What keeps it the
# right way round is the one tolerated held lock -- a holder that recorded no
# identity -- so the refusal must keep reading it. Both the definition and the use
# are asserted, because hoisting the condition somewhere else would leave the
# `that:` list looking unchanged while it stopped meaning this.
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
