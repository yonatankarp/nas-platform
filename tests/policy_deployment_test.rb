#!/usr/bin/env ruby
# Deployment bundle policy.
#
# A release ID names committed controller content, target paths are hostile input
# until both their lexical form and their filesystem ancestry are checked, and the
# bundle's Compose selection must resolve before activation. Split out of
# policy_test.rb: these checks police roles/deployment_bundle and change with it.

require "open3"
require "rbconfig"
require "set"
require "yaml"
require_relative "policy_support"

include PolicySupport

ROOT = File.expand_path("..", __dir__)
failures = []

def check(failures, condition, message)
  failures << message unless condition
end

harness = File.read(File.join(ROOT, "tests", "integration.sh"))
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
                harness.include?("-e platform_compose_kind=integration") &&
                harness.include?("-e deployment_bundle_test_mode=true") &&
                harness.include?("-e deployment_bundle_allow_dirty_controller=true"),
      "integration must preserve platform_kind and explicitly enable its Compose test override")
%w[
  DIRTY_TRACKED_REFUSED DIRTY_UNTRACKED_REFUSED
  DIRTY_MANIFEST_TEMPLATE_REFUSED DIRTY_ARBITRARY_CONTROLLER_FILE_REFUSED
  DIRTY_PRODUCTION_BYPASS_REFUSED DIRTY_INTEGRATION_ACCEPTED
  DIRTY_REFUSAL_TARGET_UNCHANGED
].each do |evidence|
  check(failures, harness.include?(evidence),
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
check(failures, target_tasks_body.include?("nas_docker_root ~ '/.nas-platform-preflight-probe'") ||
                target_tasks_body.include?("{{ nas_docker_root }}/.nas-platform-preflight-probe"),
      "target validator must guard the exact preflight probe leaf")
check(failures, target_tasks_body.include?("deployment_bundle_services") &&
                target_tasks_body.include?("platform_runtime_dir ~ '/services/'"),
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
                controller_input_argv.count(controller_input_lookup) == 1,
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
check(failures, inputs_body.include?("services/manifest.yml") &&
                inputs_body.include?("compose.yml") &&
                inputs_body.include?("compose.{{ platform_compose_kind }}.yml"),
      "controller inputs must validate manifest, canonical Compose, and platform overrides")
check(failures, inputs_body.include?("services/dozzle/alert_relay.py") &&
                inputs_body.include?("services/immich/classify_restore.py"),
      "controller inputs must validate every tracked runtime helper")
input_tasks = flatten_tasks(YAML.safe_load(inputs_body))
catalog_validation_index = input_tasks.index do |task|
  task.dig("vars", "deployment_controller_input_path") ==
    "{{ playbook_dir }}/config/media-acquisition.yml"
end
manifest_parse_index = input_tasks.index do |task|
  task["name"] == "Resolve implemented services from the validated controller manifest"
end
catalog_validation = catalog_validation_index && input_tasks[catalog_validation_index]
check(failures,
      !catalog_validation.nil? &&
        catalog_validation["ansible.builtin.include_tasks"] == "controller_input.yml" &&
        catalog_validation.dig("vars", "deployment_controller_input_allow_missing") == false &&
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

# Parsed rather than byte-offset: a task name or a variable reference occurring inside a
# comment or a when: expression is not evidence of task ordering. The validating task's own
# deployment_target_extra_paths necessarily name the runtime roots, so it is excluded from
# the first-use search rather than compared against itself.
%w[ntfy beszel dozzle audiobookshelf komga jellyfin immich
   paperless_ngx].each do |service_name|
  service_tasks = YAML.safe_load_file(
    File.join(ROOT, "roles", service_name, "tasks", "main.yml"), aliases: true
  ) || []
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

  guarded = (service_tasks.fetch(target_validation)["vars"] || {})
            .fetch("deployment_target_extra_paths", [])
  check(failures,
        guarded.any? { |path| path.to_s.end_with?("/compose.yml") } &&
          guarded.any? { |path| path.to_s.end_with?("/compose.{{ platform_compose_kind }}.yml") },
        "#{service_name} must guard every Compose file consumed by selective runs")
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
platform_inputs_index = deployment_manifest_template.index("platform_inputs:")
services_index = deployment_manifest_template.index("services:")
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
compose_metadata_behavior = File.read(
  File.join(ROOT, "tests", "compose_metadata_filter_test.yml")
)
check(failures, deployment_manifest_template.include?("| platform_compose_metadata") &&
                !deployment_manifest_template.match?(/regex_replace\(['\"]!override|regex_replace\(['\"]!reset/),
      "deployment manifest must parse Compose tags without rewriting source text")
check(failures, compose_metadata_filter.include?("yaml.SafeLoader") &&
                compose_metadata_filter.include?("(\"!override\", \"!reset\")") &&
                compose_metadata_filter.include?("except yaml.YAMLError") &&
                compose_metadata_filter.include?("unsupported YAML") &&
                !compose_metadata_filter.include?("add_multi_constructor"),
      "Compose metadata loader must allow only exact known tags and fail closed")
check(failures, compose_metadata_behavior.include?("quoted, block, and commented literal markers") &&
                compose_metadata_behavior.include?("Require unknown YAML tags to fail closed") &&
                File.read(File.join(ROOT, "tests", "validate-policy.sh"))
                    .include?("tests/compose_metadata_filter_test.yml"),
      "policy validation must execute Compose metadata parser behavior tests")

site_source = File.read(File.join(ROOT, "site.yml"))
check(failures, !site_source.include?("nothing is delegated to the controller"),
      "site documentation must acknowledge explicit controller delegation")

integration_evidence = harness + File.read(File.join(ROOT, "tests", "verify_deployment_manifest.rb"))
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
                harness.include?("test ! -e '$sandbox/volume1/Docker/nas-platform'"),
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


if failures.empty?
  puts "deployment policy: all properties hold"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} deployment policy violation(s)"
end
