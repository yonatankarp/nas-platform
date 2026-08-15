#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"

ROOT = File.expand_path("..", __dir__)

def refuse(message)
  abort "Immich restore quality failed: #{message}"
end

def task(tasks, name)
  tasks.find { |candidate| candidate["name"] == name }
end

def flatten_tasks(tasks)
  tasks.flat_map do |candidate|
    [candidate] + %w[block rescue always].flat_map do |section|
      flatten_tasks(Array(candidate[section]))
    end
  end
end

def require_order(tasks, names)
  positions = names.map do |name|
    index = tasks.index { |candidate| candidate["name"] == name }
    refuse("missing task #{name}") unless index
    index
  end
  refuse("restore lifecycle is out of order") unless positions == positions.sort
end

def deep_copy(value)
  Marshal.load(Marshal.dump(value))
end

def ordered?(tasks, names)
  positions = names.map { |name| tasks.index { |candidate| candidate["name"] == name } }
  positions.none?(&:nil?) && positions == positions.sort
end

def classifier_failure_guarded?(tasks)
  conditions = task(tasks, "Require successful Immich storage classification")
               &.dig("ansible.builtin.assert", "that")
  Array(conditions).include?(
    "immich_restore_classification_command.rc | default(1) | int == 0"
  )
end

def existing_database_restore_blocked?(tasks)
  conditions = task(tasks, "Require exact Immich storage classification")
               &.dig("ansible.builtin.assert", "that")
  Array(conditions).include?(
    "not immich_restore_classification.restoreRequired or " \
    "immich_restore_classification.database == 'fresh'"
  )
end

def classifier_uses_effective_roots?(tasks)
  argv = task(tasks, "Classify Immich storage before startup")
         &.dig("ansible.builtin.command", "argv")
  expected = {
    "--postgres-dir" => "{{ immich_restore_database_root }}",
    "--originals-root" => "{{ immich_restore_originals_root }}",
    "--backup-dir" => "{{ immich_restore_backup_root }}",
    "--failure-marker" => "{{ immich_restore_effective_failure_marker }}"
  }
  argv.is_a?(Array) && expected.all? do |option, value|
    index = argv.index(option)
    index && argv.fetch(index + 1, nil) == value
  end
end

def classifier_uses_deployed_helper?(main_tasks, restore_tasks)
  expected = "{{ platform_current_dir }}/services/immich/classify_restore.py"
  invocations_valid = [
    task(main_tasks, "Classify Immich storage before startup"),
    task(restore_tasks, "Verify restored Immich source files")
  ].all? do |candidate|
    argv = candidate&.dig("ansible.builtin.command", "argv")
    argv.is_a?(Array) && argv.count(expected) == 1 &&
      argv.none? { |argument| argument.to_s.include?("roles/immich/files") }
  end
  target_paths = task(main_tasks, "Revalidate deployment paths before Immich runtime use")
                 &.dig("vars", "deployment_target_extra_paths")
  invocations_valid && Array(target_paths).count(expected) == 1
end

def classifier_release_packaged?(input_tasks, bundle_tasks, manifest, verifier)
  input = task(input_tasks, "Validate the tracked Immich restore classifier input")
  copy = task(bundle_tasks, "Copy the tracked Immich restore classifier from the controller")
  input&.dig("vars", "deployment_controller_input_path") ==
    "{{ playbook_dir }}/services/immich/classify_restore.py" &&
    input&.dig("vars", "deployment_controller_input_allow_missing") == false &&
    copy&.dig("ansible.builtin.copy", "src") ==
      "{{ playbook_dir }}/services/immich/classify_restore.py" &&
    copy&.dig("ansible.builtin.copy", "dest") ==
      "{{ deployment_bundle_staging_dir }}/services/immich/classify_restore.py" &&
    copy&.dig("ansible.builtin.copy", "mode") == "0644" &&
    manifest.include?("runtime_files:") &&
    manifest.include?("'immich': ['classify_restore.py']") &&
    manifest.include?("playbook_dir ~ '/services/' ~ service.name ~ '/' ~ runtime_file") &&
    manifest.include?("mode: \"0644\"") &&
    verifier.include?("RUNTIME_FILES") &&
    verifier.include?('"immich" => ["classify_restore.py"]')
end

def classifier_integrity_bound?(main_tasks, restore_tasks, integrity_tasks)
  source_stat = task(integrity_tasks, "Inspect the trusted Immich restore classifier source")
  source_guard = task(integrity_tasks, "Require the trusted Immich restore classifier source")
  deployed_stat = task(integrity_tasks, "Inspect the deployed Immich restore classifier")
  deployed_guard = task(integrity_tasks, "Require the deployed Immich restore classifier")
  source_conditions = Array(source_guard&.dig("ansible.builtin.assert", "that")).join(" ")
  deployed_conditions = Array(deployed_guard&.dig("ansible.builtin.assert", "that")).join(" ")
  includes = [
    [main_tasks, "Verify Immich restore classifier before storage classification",
     "Classify Immich storage before startup"],
    [restore_tasks, "Verify Immich restore classifier before asset verification",
     "Verify restored Immich source files"]
  ]
  includes_valid = includes.all? do |tasks, include_name, command_name|
    include_index = tasks.index { |candidate| candidate["name"] == include_name }
    command_index = tasks.index { |candidate| candidate["name"] == command_name }
    include_task = task(tasks, include_name)
    include_index && command_index && include_index + 1 == command_index &&
      include_task&.fetch("ansible.builtin.include_tasks", nil) == "verify_classifier.yml"
  end

  includes_valid &&
    source_stat&.dig("ansible.builtin.stat", "path") ==
      "{{ playbook_dir }}/services/immich/classify_restore.py" &&
    source_stat&.dig("ansible.builtin.stat", "follow") == false &&
    source_stat&.dig("ansible.builtin.stat", "checksum_algorithm") == "sha256" &&
    source_stat&.fetch("delegate_to", nil) == "localhost" &&
    source_conditions.include?("isreg") && source_conditions.include?("islnk") &&
    source_conditions.include?("stat.mode | default('') == '0644'") &&
    deployed_stat&.dig("ansible.builtin.stat", "path") ==
      "{{ platform_current_dir }}/services/immich/classify_restore.py" &&
    deployed_stat&.dig("ansible.builtin.stat", "follow") == false &&
    deployed_stat&.dig("ansible.builtin.stat", "checksum_algorithm") == "sha256" &&
    deployed_conditions.include?("isreg") && deployed_conditions.include?("islnk") &&
    deployed_conditions.include?("stat.mode | default('') == '0644'") &&
    deployed_conditions.include?("immich_restore_classifier_source_stat.stat.checksum")
end

def lifecycle_ordered?(tasks)
  ordered?(
    tasks,
    [
      "Classify Immich storage before startup",
      "Require successful Immich storage classification",
      "Stop Immich application services before database restore",
      "Protect an in-progress Immich database restore",
      "Deploy the Immich data services",
      "Restore and verify the Immich database",
      "Deploy Immich",
      "Require initialized Immich after database restore",
      "Remove successful Immich restore provenance",
      "Create the vault Immich administrator"
    ]
  )
end

def require_mutation_rejected(label)
  refuse("#{label} mutation was not detected") if yield
end

classifier_path = File.join(ROOT, "services", "immich", "classify_restore.py")
restore_path = File.join(ROOT, "roles", "immich", "tasks", "restore.yml")
integrity_path = File.join(ROOT, "roles", "immich", "tasks", "verify_classifier.yml")
refuse("classifier is absent") unless File.file?(classifier_path)
refuse("divergent role-local classifier remains") if
  File.exist?(File.join(ROOT, "roles", "immich", "files", "classify_restore.py"))
refuse("restore task file is absent") unless File.file?(restore_path)
refuse("classifier integrity task file is absent") unless File.file?(integrity_path)

defaults = YAML.safe_load_file(File.join(ROOT, "roles", "immich", "defaults", "main.yml"))
expected_defaults = {
  "immich_restore_failure_marker" =>
    "{{ (platform_adoption_root ~ '/legacy/immich/.restore-failed') if " \
    "platform_adoption_enabled | default(false) | bool else " \
    "(nas_docker_root ~ '/immich/.restore-failed') }}",
  "immich_restore_backup_container_path" => "/immich-backups",
  "immich_restore_backup_uid" => 0,
  "immich_restore_backup_gid" => 0,
  "immich_restore_verify_limit" => 25,
  "immich_restore_database_wait_timeout" => 300
}
expected_defaults.each do |key, value|
  actual = defaults[key]
  actual = actual.split.join(" ") if key == "immich_restore_failure_marker"
  refuse("#{key} default differs") unless actual == value
end

argument_specs = YAML.safe_load_file(
  File.join(ROOT, "roles", "immich", "meta", "argument_specs.yml")
).dig("argument_specs", "main", "options")
{
  "immich_restore_failure_marker" => "str",
  "immich_restore_backup_container_path" => "str",
  "immich_restore_backup_uid" => "int",
  "immich_restore_backup_gid" => "int",
  "immich_restore_verify_limit" => "int",
  "immich_restore_database_wait_timeout" => "int"
}.each do |name, type|
  refuse("#{name} argument is not public") unless argument_specs.dig(name, "type") == type
end

compose = YAML.safe_load_file(File.join(ROOT, "services", "immich", "compose.yml"), aliases: true)
database_volumes = compose.dig("services", "database", "volumes")
backup_mount = "${NAS_MEDIA_ROOT:?}/Immich-backups/database:/immich-backups:ro"
refuse("database backup mount must be present exactly once") unless
  database_volumes.count(backup_mount) == 1
refuse("database backup mount is not read-only") unless
  database_volumes.grep(%r{:/immich-backups(?::|$)}).all? { |mount| mount.end_with?(":ro") }
server_volumes = compose.dig("services", "immich-server", "volumes")
refuse("server database-backup volume was not preserved") unless
  server_volumes.include?("${NAS_MEDIA_ROOT:?}/Immich-backups/database:/data/backups")

adoption = YAML.safe_load_file(
  File.join(ROOT, "services", "immich", "compose.adoption.yml"), aliases: true
)
adoption_database_volumes = adoption.dig("services", "database", "volumes")
adoption_backup_mount =
  "${PLATFORM_ADOPTION_ROOT:?}/legacy/immich/backups:/immich-backups:ro"
refuse("adoption database restore does not use the adopted backup tree") unless
  adoption_database_volumes == [
    "${PLATFORM_ADOPTION_ROOT:?}/legacy/immich/postgres:/var/lib/postgresql/data",
    adoption_backup_mount
  ]

main_path = File.join(ROOT, "roles", "immich", "tasks", "main.yml")
main_tasks = YAML.safe_load_file(main_path, aliases: true)
require_order(
  main_tasks,
  [
    "Resolve the Immich storage mode",
    "Derive the effective Immich storage roots",
    "Require exact Immich effective storage roots",
    "Classify Immich storage before startup",
    "Require successful Immich storage classification",
    "Parse the Immich storage classification",
    "Require exact Immich storage classification",
    "Stop Immich application services before database restore",
    "Protect an in-progress Immich database restore",
    "Deploy the Immich data services",
    "Restore and verify the Immich database",
    "Refuse a rotated Immich database credential",
    "Deploy Immich",
    "Require initialized Immich after database restore",
    "Remove successful Immich restore provenance",
    "Create the vault Immich administrator"
  ]
)

effective_roots = task(main_tasks, "Derive the effective Immich storage roots")
expected_root_facts = {
  "immich_restore_database_root" => [
    "platform_adoption_root ~ '/legacy/immich/postgres'",
    "nas_docker_root ~ '/immich/postgres'"
  ],
  "immich_restore_originals_root" => [
    "platform_adoption_root ~ '/legacy/immich/data'",
    "nas_media_root ~ '/Immich'"
  ],
  "immich_restore_backup_root" => [
    "platform_adoption_root ~ '/legacy/immich/backups'",
    "nas_media_root ~ '/Immich-backups/database'"
  ],
  "immich_restore_effective_failure_marker" => [
    "platform_adoption_root ~ '/legacy/immich/.restore-failed'",
    "nas_docker_root ~ '/immich/.restore-failed'"
  ]
}
root_facts = effective_roots&.fetch("ansible.builtin.set_fact", nil)
expected_root_facts.each do |name, alternatives|
  expression = root_facts&.fetch(name, "").to_s
  refuse("#{name} is not derived from the active Compose mode") unless
    alternatives.all? { |alternative| expression.include?(alternative) }
end
root_guard = task(main_tasks, "Require exact Immich effective storage roots")
root_conditions = root_guard&.dig("ansible.builtin.assert", "that").to_s
expected_root_facts.each_key do |name|
  refuse("effective root guard does not constrain #{name}") unless
    root_conditions.include?(name)
end

classifier = task(main_tasks, "Classify Immich storage before startup")
refuse("check mode writes a classifier copy") if
  task(main_tasks, "Install the Immich restore classifier")
refuse("classifier must use command argv") unless
  classifier&.dig("ansible.builtin.command", "argv").is_a?(Array)
refuse("classifier output is not redacted") unless classifier["no_log"] == true
refuse("classifier may be skipped in check mode") unless classifier["check_mode"] == false
refuse("classifier can mutate state") unless classifier["changed_when"] == false
classifier_argv = classifier.dig("ansible.builtin.command", "argv")
{
  "--postgres-dir" => "{{ immich_restore_database_root }}",
  "--originals-root" => "{{ immich_restore_originals_root }}",
  "--backup-dir" => "{{ immich_restore_backup_root }}",
  "--failure-marker" => "{{ immich_restore_effective_failure_marker }}"
}.each do |option, value|
  option_index = classifier_argv.index(option)
  refuse("classifier does not consume effective #{option}") unless
    option_index && classifier_argv.fetch(option_index + 1, nil) == value
end
refuse("classifier can bypass effective roots") if classifier_argv.include?("--media-root")

refuse("classification failure is ignored or reversed") unless
  classifier_failure_guarded?(main_tasks)
schema_guard = task(main_tasks, "Require exact Immich storage classification")
schema_conditions = schema_guard&.dig("ansible.builtin.assert", "that").to_s
%w[database originalsPresent restoreRequired backupFilename].each do |key|
  refuse("classification schema does not constrain #{key}") unless schema_conditions.include?(key)
end
refuse("split-brain classification can bypass restore") unless
  schema_conditions.include?("database == 'fresh'") &&
  schema_conditions.include?("== immich_restore_classification.restoreRequired") &&
  existing_database_restore_blocked?(main_tasks)

plan_task = task(main_tasks, "Report planned Immich database restore")
refuse("check mode restore plan is absent") unless
  plan_task&.dig("ansible.builtin.debug", "msg") == "IMMICH_PLAN_DATABASE_RESTORE" &&
  Array(plan_task["when"]).include?("ansible_check_mode")
marker = task(main_tasks, "Protect an in-progress Immich database restore")
refuse("marker must be atomic mode 0600") unless
  marker&.dig("ansible.builtin.copy", "mode") == "0600" &&
  marker.dig("ansible.builtin.copy", "unsafe_writes") != true
refuse("marker ownership differs") unless
  marker.dig("ansible.builtin.copy", "owner") == "{{ nas_uid }}" &&
  marker.dig("ansible.builtin.copy", "group") == "{{ nas_gid }}"
refuse("marker can be created outside restore path") unless
  Array(marker["when"]).include?("immich_restore_required | bool") &&
  marker.dig("ansible.builtin.copy", "dest") ==
    "{{ immich_restore_effective_failure_marker }}"

restore_include = task(main_tasks, "Restore and verify the Immich database")
refuse("restore include differs") unless
  restore_include&.fetch("ansible.builtin.include_tasks", nil) == "restore.yml" &&
  Array(restore_include["when"]).include?("immich_restore_required | bool")
initialized_guard = task(main_tasks, "Require initialized Immich after database restore")
refuse("restored path can create a new administrator") unless
  initialized_guard&.dig("ansible.builtin.assert", "that").to_s.include?("immich_initialized")

restore_text = File.read(restore_path)
restore_tasks = flatten_tasks(YAML.safe_load_file(restore_path, aliases: true))
integrity_tasks = flatten_tasks(YAML.safe_load_file(integrity_path, aliases: true))
refuse("classifier is not executed from the immutable release") unless
  classifier_uses_deployed_helper?(main_tasks, restore_tasks)
refuse("classifier is not integrity-checked before every execution") unless
  classifier_integrity_bound?(main_tasks, restore_tasks, integrity_tasks)

input_tasks = flatten_tasks(YAML.safe_load_file(
  File.join(ROOT, "roles", "deployment_bundle", "tasks", "inputs.yml"), aliases: true
))
bundle_tasks = flatten_tasks(YAML.safe_load_file(
  File.join(ROOT, "roles", "deployment_bundle", "tasks", "main.yml"), aliases: true
))
manifest_template = File.read(
  File.join(ROOT, "roles", "deployment_bundle", "templates", "manifest.yml.j2")
)
manifest_verifier = File.read(File.join(ROOT, "tests", "verify_deployment_manifest.rb"))
refuse("classifier is not integrity-bound into immutable releases") unless
  classifier_release_packaged?(input_tasks, bundle_tasks, manifest_template, manifest_verifier)

mutated = deep_copy(main_tasks)
mutated_classifier = task(mutated, "Classify Immich storage before startup")
mutated_argv = mutated_classifier.dig("ansible.builtin.command", "argv")
mutated_argv[mutated_argv.index("{{ platform_current_dir }}/services/immich/classify_restore.py")] =
  "{{ platform_current_dir }}/roles/immich/files/classify_restore.py"
require_mutation_rejected("source-checkout classifier path") do
  classifier_uses_deployed_helper?(mutated, restore_tasks)
end

mutated = deep_copy(main_tasks)
target_paths = task(mutated, "Revalidate deployment paths before Immich runtime use")
               .fetch("vars").fetch("deployment_target_extra_paths")
target_paths.delete("{{ platform_current_dir }}/services/immich/classify_restore.py")
require_mutation_rejected("classifier target containment bypass") do
  classifier_uses_deployed_helper?(mutated, restore_tasks)
end

mutated_inputs = deep_copy(input_tasks)
task(mutated_inputs, "Validate the tracked Immich restore classifier input")
  .fetch("vars")["deployment_controller_input_allow_missing"] = true
require_mutation_rejected("optional classifier controller input") do
  classifier_release_packaged?(
    mutated_inputs, bundle_tasks, manifest_template, manifest_verifier
  )
end

mutated_bundle = deep_copy(bundle_tasks)
task(mutated_bundle, "Copy the tracked Immich restore classifier from the controller")
  .fetch("ansible.builtin.copy")["mode"] = "0755"
require_mutation_rejected("classifier release mode drift") do
  classifier_release_packaged?(
    input_tasks, mutated_bundle, manifest_template, manifest_verifier
  )
end

mutated_integrity = deep_copy(integrity_tasks)
task(mutated_integrity, "Inspect the trusted Immich restore classifier source")
  .fetch("ansible.builtin.stat")["path"] = "services/immich/classify_restore.py"
require_mutation_rejected("ambient classifier trust path") do
  classifier_integrity_bound?(main_tasks, restore_tasks, mutated_integrity)
end

mutated_integrity = deep_copy(integrity_tasks)
task(mutated_integrity, "Inspect the deployed Immich restore classifier")
  .fetch("ansible.builtin.stat")["follow"] = true
require_mutation_rejected("deployed classifier symlink following") do
  classifier_integrity_bound?(main_tasks, restore_tasks, mutated_integrity)
end

mutated_integrity = deep_copy(integrity_tasks)
task(mutated_integrity, "Require the deployed Immich restore classifier")
  .dig("ansible.builtin.assert", "that").reject! do |condition|
    condition.include?("source_stat.stat.checksum")
  end
require_mutation_rejected("deployed classifier checksum bypass") do
  classifier_integrity_bound?(main_tasks, restore_tasks, mutated_integrity)
end

mutated_main = deep_copy(main_tasks)
mutated_main.reject! do |candidate|
  candidate["name"] == "Verify Immich restore classifier before storage classification"
end
require_mutation_rejected("pre-classification integrity bypass") do
  classifier_integrity_bound?(mutated_main, restore_tasks, integrity_tasks)
end

mutated_restore = deep_copy(restore_tasks)
mutated_restore.reject! do |candidate|
  candidate["name"] == "Verify Immich restore classifier before asset verification"
end
require_mutation_rejected("pre-verification integrity bypass") do
  classifier_integrity_bound?(main_tasks, mutated_restore, integrity_tasks)
end

restore = task(restore_tasks, "Restore the selected Immich database backup")
argv = restore&.dig("community.docker.docker_compose_v2_exec", "argv")
refuse("restore must use a redacted argv execution") unless argv.is_a?(Array) && restore["no_log"] == true
shell_source = argv.find { |value| value.to_s.include?("gzip -dc") }.to_s
refuse("restore does not enable pipeline failure detection") unless argv.include?("pipefail")
refuse("restore is not transactional and fail-fast") unless
  shell_source.include?("--single-transaction") && shell_source.include?("ON_ERROR_STOP=on")
refuse("restore filename is interpolated into shell source") if
  shell_source.include?("backupFilename") || shell_source.include?("immich_restore_backup_filename")
refuse("restore does not pass filename as a positional argv value") unless
  argv.include?("{{ immich_restore_backup_filename }}") && shell_source.include?('$1')
refuse("restore target differs from database") unless
  restore.dig("community.docker.docker_compose_v2_exec", "service") == "database"

require_order(
  restore_tasks,
  [
    "Restore the selected Immich database backup",
    "Read restored Immich database evidence",
    "Require restored Immich database evidence",
    "Verify restored Immich source files"
  ]
)
refuse("restore verification mutates an application table") if
  restore_text.match?(/\b(?:insert|update|delete|truncate)\b/i)
refuse("restore removes provenance before server initialization") if
  restore_text.include?("Remove the Immich restore failure marker")
refuse("restore does not verify the pinned v3 migration marker") unless
  restore_text.include?("public.kysely_migrations")
refuse("restore failures do not preserve a sanitized marker stage") unless
  restore_text.include?("Record sanitized Immich restore failure stage") &&
  restore_text.include?("immich_restore_stage")

# Mutation sentinels prove each high-risk safety boundary is actively checked.
mutated = deep_copy(main_tasks)
task(mutated, "Require successful Immich storage classification")
  .dig("ansible.builtin.assert", "that")[0] =
    "immich_restore_classification_command.rc | default(1) | int != 0"
require_mutation_rejected("reversed classifier failure guard") do
  classifier_failure_guarded?(mutated)
end

mutated = deep_copy(main_tasks)
task(mutated, "Require successful Immich storage classification")
  .dig("ansible.builtin.assert", "that").clear
require_mutation_rejected("ignored classifier failure") do
  classifier_failure_guarded?(mutated)
end

mutated = deep_copy(main_tasks)
schema = task(mutated, "Require exact Immich storage classification")
         .dig("ansible.builtin.assert", "that")
schema.delete(
  "not immich_restore_classification.restoreRequired or " \
  "immich_restore_classification.database == 'fresh'"
)
require_mutation_rejected("existing database restore enabled") do
  existing_database_restore_blocked?(mutated)
end

mutated = deep_copy(main_tasks)
argv = task(mutated, "Classify Immich storage before startup")
       .dig("ansible.builtin.command", "argv")
argv[argv.index("--postgres-dir") + 1] = "{{ nas_docker_root }}/immich/postgres"
require_mutation_rejected("effective adoption database path bypass") do
  classifier_uses_effective_roots?(mutated)
end

{
  "application startup before verification" => [
    "Deploy Immich", "Restore and verify the Immich database"
  ],
  "marker cleared before initialization" => [
    "Remove successful Immich restore provenance",
    "Require initialized Immich after database restore"
  ],
  "server stop after restore marker" => [
    "Protect an in-progress Immich database restore",
    "Stop Immich application services before database restore"
  ]
}.each do |label, (first, second)|
  mutated = deep_copy(main_tasks)
  first_index = mutated.index { |candidate| candidate["name"] == first }
  second_index = mutated.index { |candidate| candidate["name"] == second }
  mutated[first_index], mutated[second_index] = mutated[second_index], mutated[first_index]
  require_mutation_rejected(label) { lifecycle_ordered?(mutated) }
end

mutated_shell = shell_source.sub('$1', "{{ immich_restore_backup_filename }}")
refuse("filename-injection mutation was not detected") unless
  mutated_shell.include?("immich_restore_backup_filename")

contract_text = File.read(File.join(ROOT, "tests", "contracts", "immich.sh"))
integration_text = File.read(File.join(ROOT, "tests", "integration.sh"))
%w[clean-restore-seed clean-restore-assert].each do |mode|
  refuse("Immich contract omits #{mode}") unless contract_text.include?(mode)
end
[
  "run_immich_contract clean-restore-seed",
  "docker compose --project-name immich",
  "run_play --tags immich",
  "run_immich_contract clean-restore-assert",
  "IMMICH_CLEAN_RESTORE_IDEMPOTENT",
  "run_immich_restore_negative_matrix",
  "missing-safe-backup",
  "unsafe-newest-backup",
  "ambiguous-newest-backup",
  "previous-failed-restore",
  "IMMICH_EXISTING_DATABASE_BACKUP_IGNORED",
  "IMMICH_NEGATIVE_RESTORE_MATRIX_OK"
].each do |sentinel|
  refuse("media integration omits #{sentinel}") unless integration_text.include?(sentinel)
end

puts "Immich restore quality contract passed"
