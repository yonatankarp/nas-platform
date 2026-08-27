#!/usr/bin/env ruby
# Integration harness policy.
#
# The plays must be exercised, not merely parsed: the two worst bugs so far, a
# Darwin-only fact and a command skipped under --check, both survived syntax
# checking and were caught by running. These checks police tests/integration.sh
# and its locking and sandboxing, and change with that harness.

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

# The plays must be exercised, not merely parsed: the two worst bugs so far, a
# Darwin-only fact and command being skipped under --check, both survived syntax
# checking and were caught by running.
harness = File.read(File.join(ROOT, "tests", "integration.sh"))
dozzle_contract = File.read(File.join(ROOT, "tests", "contracts", "dozzle.sh"))
check(failures, dozzle_contract.include?('exec ruby - "$mode" "$@"'),
      "Dozzle contract must pass its default verify mode to the dynamic probe")
integration_lock_path = File.join(ROOT, "tests", "integration_lock.sh")
integration_lock = File.file?(integration_lock_path) ? File.read(integration_lock_path) : ""
mac_path_fixture = File.read(File.join(ROOT, "tests", "mac_inventory_path_test.yml"))
check(failures, harness.include?("MAC_PATH_CANONICAL") &&
                harness.include?("MAC_PATH_LEXICAL_REFUSED") &&
                harness.include?("mac_inventory_path_test.yml") &&
                mac_path_fixture.include?("tasks_from: target") &&
                mac_path_fixture.include?("EXPECTED_PLATFORM_DOCKER_ROOT"),
      "integration must prove canonical Mac paths pass target validation")
["IDEMPOTENT", "CHECK MODE"].each do |property|
  check(failures, harness.include?(property), "integration harness must assert #{property}")
end
first_converge = harness.index("\n    run_play\n")
contract_execution = harness.index("ruby /repo/tests/run_contracts.rb --execute")
idempotence_phase = harness.index("=== phase 2: asserting idempotence ===")
check(failures, first_converge && contract_execution && idempotence_phase &&
                first_converge < contract_execution && contract_execution < idempotence_phase,
      "integration must execute registered contracts after converge and before idempotence")
contract_abi_names = %w[
  PLATFORM_KIND PLATFORM_CONTRACT_VAULT_FILE PLATFORM_DOCKER_ROOT
  PLATFORM_MEDIA_ROOT PLATFORM_FIXTURE_ROOT PLATFORM_REPORT_ROOT
]
contract_environment_start = contract_execution && harness.rindex("\n      env \\", contract_execution)
contract_environment = if contract_environment_start && contract_execution
                         harness[contract_environment_start..contract_execution]
                       else
                         ""
                       end
check(failures, contract_execution && contract_abi_names.all? do |name|
  contract_environment.include?("#{name}=")
end, "integration must set the contract environment ABI before execution")
run_play_body = harness[/^    run_play\(\) \{.*?^    \}/m].to_s
namespace_derivation = harness[/^derive_integration_project_namespace\(\) \{.*?^\}/m].to_s
namespace_call = harness.index('integration_project_namespace=$(derive_integration_project_namespace "$sandbox")')
controller_run = harness.index("docker run --rm")
check(failures,
      namespace_derivation.include?('integration_suffix=${integration_namespace_sandbox##*.}') &&
        namespace_derivation.include?("tr '[:upper:]' '[:lower:]'") &&
        namespace_derivation.include?('nas-platform-integration-[a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9]') &&
        namespace_call && controller_run && namespace_call < controller_run,
      "integration must derive and validate a lowercase six-character sandbox namespace before the controller starts")
scoped_project_variables = %w[arr_platform_project_name downloaders_platform_project_name]
check(failures,
      scoped_project_variables.all? do |variable|
        run_play_body.include?("-e #{variable}=\\\"$integration_project_namespace\\\"")
      end && !run_play_body.include?("-e platform_project_name="),
      "integration must scope the disposable namespace to Arr and downloaders")

arr_integration = YAML.safe_load(
  File.read(File.join(ROOT, "services", "arr", "compose.integration.yml"))
).fetch("services")
downloaders_integration = YAML.safe_load(
  File.read(File.join(ROOT, "services", "downloaders", "compose.integration.yml"))
).fetch("services")
expected_arr_names = %w[radarr sonarr prowlarr bazarr].to_h do |service|
  [service, "${PLATFORM_PROJECT_NAME:?}-#{service}"]
end
check(failures,
      expected_arr_names.all? do |service, name|
        arr_integration.fetch(service, {}).fetch("container_name", nil) == name
      end,
      "Arr integration containers must use the disposable platform namespace")
check(failures, arr_integration.fetch("configarr", nil) == {},
      "Configarr integration must keep its project-derived one-off name")
expected_downloader_names = %w[sabnzbd unpackerr].to_h do |service|
  [service, "${PLATFORM_PROJECT_NAME:?}-#{service}"]
end
check(failures,
      expected_downloader_names.all? do |service, name|
        downloaders_integration.fetch(service, {}).fetch("container_name", nil) == name
      end,
      "downloader integration containers must use the disposable platform namespace")

# Sandbox cleanup deletes acquisition resources only when they carry the
# disposable namespace, so a base service left with its fixed production name
# is not cleaned up at all: it survives the run and collides with the next one.
# Derive the requirement from the base Compose rather than a second hand-kept
# list, so adding a service to a stack cannot skip its override.
{
  "arr" => arr_integration,
  "downloaders" => downloaders_integration
}.each do |stack, override|
  base = YAML.safe_load_file(
    File.join(ROOT, "services", stack, "compose.yml"), aliases: true
  ).fetch("services")
  production_named = base.select do |_service, definition|
    definition.is_a?(Hash) && definition["container_name"].is_a?(String) &&
      !definition.fetch("container_name").include?("${")
  end.keys
  check(failures, !production_named.empty?,
        "#{stack} base Compose declares no fixed container name to override")
  unnamespaced = production_named.reject do |service|
    definition = override.fetch(service, nil)
    definition.is_a?(Hash) &&
      definition.fetch("container_name", nil) == "${PLATFORM_PROJECT_NAME:?}-#{service}"
  end
  check(failures, unnamespaced.empty?,
        "#{stack} integration override leaves production container names " \
        "#{unnamespaced.sort.inspect}, which sandbox cleanup cannot remove")
end

arr_defaults = YAML.safe_load_file(File.join(ROOT, "roles", "arr", "defaults", "main.yml"))
downloaders_defaults = YAML.safe_load_file(
  File.join(ROOT, "roles", "downloaders", "defaults", "main.yml")
)
arr_argument_options = YAML.safe_load_file(
  File.join(ROOT, "roles", "arr", "meta", "argument_specs.yml")
).dig("argument_specs", "main", "options")
downloaders_argument_options = YAML.safe_load_file(
  File.join(ROOT, "roles", "downloaders", "meta", "argument_specs.yml")
).dig("argument_specs", "main", "options")
arr_environment = File.read(File.join(ROOT, "roles", "arr", "templates", "env.j2"))
downloaders_environment = File.read(
  File.join(ROOT, "roles", "downloaders", "templates", "env.j2")
)
check(failures,
      arr_defaults.fetch("arr_platform_project_name", "").include?("platform_project_name | default('')") &&
        arr_defaults.fetch("arr_compose_project_name", "").include?("arr_platform_project_name ~ '-arr'") &&
        arr_argument_options.fetch("arr_platform_project_name", nil) == {
          "type" => "str", "required" => false
        } &&
        arr_environment.include?("PLATFORM_PROJECT_NAME={{ arr_platform_project_name }}"),
      "Arr must derive its Compose project and container prefix through its role-scoped namespace")
check(failures,
      downloaders_defaults.fetch("downloaders_platform_project_name", "")
                           .include?("platform_project_name | default('')") &&
        downloaders_defaults.fetch("downloaders_compose_project_name", "")
                            .include?("downloaders_platform_project_name ~ '-downloaders'") &&
        downloaders_argument_options.fetch("downloaders_platform_project_name", nil) == {
          "type" => "str", "required" => false
        } &&
        downloaders_environment.include?(
          "PLATFORM_PROJECT_NAME={{ downloaders_platform_project_name }}"
        ),
      "downloaders must derive their Compose project and container prefix through their role-scoped namespace")

inventory_defaults = File.read(File.join(ROOT, "inventory", "group_vars", "all", "main.yml"))
host_prep = File.read(File.join(ROOT, "roles", "host_prep", "tasks", "main.yml"))
legacy_defaults = File.read(
  File.join(ROOT, "roles", "audiobookshelf", "defaults", "main.yml")
)
legacy_project_sources = inventory_defaults + host_prep + legacy_defaults
check(failures,
      inventory_defaults.include?("platform_project_name ~ '-media-control'") &&
        host_prep.include?("platform_project_name | default('nas-platform', true)") &&
        legacy_defaults.include?("platform_project_name ~ '-audiobookshelf'") &&
        scoped_project_variables.none? do |variable|
          legacy_project_sources.include?(variable)
        end,
      "acquisition namespacing must not alter the media-control or legacy project defaults")
namespace = "nas-platform-integration-a1b2c3"
effective_projects, effective_projects_error, effective_projects_status = Open3.capture3(
  "ansible", "localhost", "-i", "localhost,", "-c", "local", "-m", "debug",
  "-a", "msg={{ platform_media_control_network }}|{{ audiobookshelf_compose_project_name }}|" \
        "{{ arr_compose_project_name }}|{{ downloaders_compose_project_name }}",
  "-e", "@inventory/group_vars/all/main.yml",
  "-e", "@roles/audiobookshelf/defaults/main.yml",
  "-e", "@roles/arr/defaults/main.yml",
  "-e", "@roles/downloaders/defaults/main.yml",
  "-e", "arr_platform_project_name=#{namespace}",
  "-e", "downloaders_platform_project_name=#{namespace}",
  chdir: ROOT
)
check(failures,
      effective_projects_status.success? &&
        effective_projects.include?(
          %Q{"msg": "media-control|audiobookshelf|#{namespace}-arr|#{namespace}-downloaders"}
        ),
      "effective scoped project defaults differ: #{effective_projects_error.strip}")
check(failures, harness.match?(/^ruby_package='ruby~\d+\.\d+\.\d+'$/) &&
                harness.match?(/^curl_package='curl~\d+\.\d+\.\d+'$/),
      "integration must pin distro ruby and curl packages")
check(failures,
      harness.include?("/repo/tests/generate-ephemeral-vault.sh") &&
      harness.include?("--output \\\"\\$vault_file\\\"") &&
        harness.include?("--password-file") &&
        run_play_body.include?("--vault-password-file \\\"\\$vault_password_file\\\"") &&
        run_play_body.include?("-e @\\\"\\$vault_file\\\"") &&
        run_play_body.include?("-e platform_vault_file=\\\"\\$vault_file\\\"") &&
        harness.include?("TMPDIR='$sandbox' /repo/tests/generate-ephemeral-vault.sh --cleanup") &&
        contract_environment.include?("PLATFORM_CONTRACT_VAULT_FILE=\\\"\\$vault_file\\\"") &&
        !harness.include?("sandbox-vault.yml") &&
        !harness.include?("random_password()") &&
        !harness.include?("ntfy_token()"),
      "integration must consume the ephemeral encrypted vault without duplicate secret authoring")
check(failures,
      harness.include?('/repo/tests/mac/generate-immich-fixture-vars.rb') &&
        harness.include?('ANSIBLE_VAULT_PASSWORD_FILE=\"\$vault_password_file\" ansible-vault view') &&
        harness.include?('fixture_vars_file=\"\$fixture_input_directory/immich-fixture-vars.yml\"') &&
        harness.include?('PLATFORM_MAC_FIXTURE_VARS_FILE=\"\$fixture_vars_file\"') &&
        harness.include?('install -m 0600 /dev/null \"\$fixture_vars_file\"') &&
        harness.include?('chmod 0600 \"\$fixture_vars_file\"') &&
        harness.include?('rm -f \"\$fixture_vault_view\"') &&
        harness.include?('trap cleanup_fixture_vault_view EXIT'),
      "integration must generate and protect the Immich fixture policy")
check(failures,
      harness.include?('controller_mount=$sandbox/repo') &&
        harness.include?('git clone --quiet --no-local --no-checkout "$repo_dir" "$controller_mount"') &&
        harness.include?('git -C "$controller_mount" checkout -q --detach "$expected_release_id"') &&
        harness.include?('-v "$controller_mount":/repo') &&
        harness.include?('install -m 0600 \"\$vault_file\" /repo/inventory/group_vars/all/vault.yml') &&
        !harness.include?('controller_mount=$repo_dir'),
      "integration must isolate normal and linked-worktree controllers before installing its ephemeral vault")
lock_acquire_index = harness.index("acquire_integration_lock")
sandbox_create_index = harness.index('sandbox=$(mktemp -d')
check(failures,
      harness.include?('. "$repo_dir/tests/integration_lock.sh"') &&
        lock_acquire_index && sandbox_create_index && lock_acquire_index < sandbox_create_index &&
        harness.include?("cleanup_sandbox") && harness.include?("release_integration_lock") &&
        integration_lock.include?('mkdir "$lock_candidate"') &&
        integration_lock.include?('rmdir "$integration_lock_path"') &&
        !integration_lock.match?(/rm\s+-rf/),
      "integration must serialize fixed-name containers with an atomic empty-directory lock")

if failures.empty?
  puts "integration policy: all properties hold"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} integration policy violation(s)"
end
