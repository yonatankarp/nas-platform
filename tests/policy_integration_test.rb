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
check(failures,
      run_play_body.include?('-e platform_project_name=\\"$integration_project_namespace\\"'),
      "every integration play must receive the validated disposable project namespace")

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
