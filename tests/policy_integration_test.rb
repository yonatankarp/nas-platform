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
include TestScaffold

failures = []

# The plays must be exercised, not merely parsed: the two worst bugs so far, a
# Darwin-only fact and command being skipped under --check, both survived syntax
# checking and were caught by running.
harness = File.read(File.join(ROOT, "tests", "integration.sh"))

# The controller script is one double-quoted argument to `sh -eu -c`, built by
# a shell that is still parsing. An unescaped quote inside it closes the
# argument, and the next shell metacharacter then terminates the whole
# `docker run` — silently truncating the script and starting the container with
# no operands. That is invisible to `sh -n` and to every static read of the
# file, and it broke every suite once before, so walk the quoting the way the
# shell does and require that nothing escapes the argument.
controller_regions = []
controller_state = "DQ"
controller_offset = harness.index('sh -eu -c "')
check(failures, !controller_offset.nil?,
      "tests/integration.sh must invoke the controller through sh -eu -c")
if controller_offset
  controller_offset += 'sh -eu -c "'.length
  controller_line = harness[0, controller_offset].count("\n") + 1
  controller_region = nil
  while controller_offset < harness.length
    character = harness[controller_offset]
    if controller_state != "SQ" && character == "\\"
      controller_line += 1 if harness[controller_offset + 1] == "\n"
      controller_offset += 2
      next
    end
    case [controller_state, character]
    in ["DQ", '"'] then controller_state = "OUT"
                        controller_region = [controller_line, +""]
    in ["OUT", '"'] then controller_state = "DQ"
                         controller_regions << controller_region if controller_region
                         controller_region = nil
    in ["OUT", "'"] then controller_state = "SQ"
    in ["SQ", "'"] then controller_state = "OUT"
    else
      controller_region[1] << character if controller_state != "DQ" && controller_region
    end
    controller_line += 1 if character == "\n"
    controller_offset += 1
  end
  # Only the final line may leave the quoted argument: that is where the
  # operands `integration-run "$playbook" "$@"` are appended.
  final_line = harness.count("\n") + (harness.end_with?("\n") ? 0 : 1)
  escaped = controller_regions.reject { |line, _text| line >= final_line }
                              .select { |_line, text| text.match?(/[\s;&|()<>]/) }
  check(failures, escaped.empty?,
        "controller script escapes its quoted argument at " \
        "#{escaped.map { |line, text| "line #{line}: #{text.inspect}" }.join(', ')}; " \
        "escape the inner quotes so the whole script stays one argument")
  check(failures, controller_state == "OUT",
        "controller script argument is never closed")
end
dozzle_contract = File.read(File.join(ROOT, "tests", "contracts", "dozzle.sh"))
check(failures, dozzle_contract.include?('exec ruby - "$mode" "$@"'),
      "Dozzle contract must pass its default verify mode to the dynamic probe")
integration_lock_path = File.join(ROOT, "tests", "integration_lock.sh")
integration_lock = File.file?(integration_lock_path) ? File.read(integration_lock_path) : ""
mac_path_fixture_tasks = flatten_tasks(
  YAML.safe_load_file(File.join(ROOT, "tests", "mac_inventory_path_test.yml"), aliases: true)
    .flat_map { |play| Array(play["tasks"]) }
)
mac_path_fixture_strings = task_strings(mac_path_fixture_tasks)
check(failures, harness.include?("MAC_PATH_CANONICAL") &&
                harness.include?("MAC_PATH_LEXICAL_REFUSED") &&
                harness.include?("mac_inventory_path_test.yml") &&
                mac_path_fixture_tasks.any? do |task|
                  task.dig("ansible.builtin.include_role", "tasks_from") == "target"
                end &&
                mac_path_fixture_strings.any? do |value|
                  value.include?("EXPECTED_PLATFORM_DOCKER_ROOT")
                end,
      "integration must prove canonical Mac paths pass target validation")
["IDEMPOTENT", "CHECK MODE"].each do |property|
  check(failures, harness.include?(property), "integration harness must assert #{property}")
end
# `producer | tee log` reports tee's status, and every script here is #!/bin/sh
# with no pipefail available, so a play that died reached its recap grep looking
# merely quiet. Redirect and read the producer's own status instead.
check(failures,
      !harness.match?(/\|\s*tee\b/) &&
        harness.include?('run_selected_play "\$@" >/tmp/second.txt 2>&1 || idempotence_status=\$?') &&
        harness.include?('run_play --tags immich >/tmp/immich-clean-restore-second.txt 2>&1 ||'),
      "integration must read a play's own status rather than a pipeline's")
check(failures,
      harness.include?('suite_pull_images > "$prepull_list" || prepull_enumeration_status=$?') &&
        harness.include?('for pull_candidate in $prepull_targets; do') &&
        harness.include?('"$repo_dir/services/$service_dir/compose.yml" || exit 1'),
      "integration must fail the pre-pull when enumerating its images fails")
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
# Every service, not only the acquisition stacks, is deployed under the
# disposable namespace: sandbox cleanup deletes by exact Compose ownership, so a
# stack left in its production project would survive the run and collide with
# the next one. The role-scoped names stay, because they are the override
# interface the two acquisition roles expose.
check(failures,
      scoped_project_variables.all? do |variable|
        run_play_body.include?("-e #{variable}=\\\"$integration_project_namespace\\\"")
      end && run_play_body.include?("-e platform_project_name=\\\"$integration_project_namespace\\\""),
      "integration must deploy every service under the disposable namespace")
# One launcher runs every per-service verification, so the namespace, the vault
# quoting and the play itself are written once. Assert the property on that
# launcher, and require every wrapper to be nothing but a delegation to it: a
# hand-rolled verification that spelled any of those differently — as five of
# the seven copies once spelled the vault paths unquoted — is now rejected
# outright rather than checked copy by copy.
verification_launcher = harness[/^    run_verification\(\) \{.*?^    \}/m].to_s
check(failures,
      verification_launcher.include?(
        "-e platform_project_name=\\\"$integration_project_namespace\\\""
      ) &&
        verification_launcher.include?("--tags \\\"platform_verify_\\$verification_tag\\\""),
      "integration verification must read the disposable namespace it deployed")
verify_only_bodies = harness.scan(/^    (run_[a-z_]*verif[a-z_]*)\(\) \{\n(.*?)^    \}/m)
                            .reject { |name, _body| name == "run_verification" }
check(failures, verify_only_bodies.length >= 6 &&
                verify_only_bodies.all? do |_name, body|
                  body.match?(/\A      run_verification [a-z_]+\n\z/)
                end,
      "every integration verification wrapper must delegate to the shared launcher")
negative_project_names = harness.scan(/-e platform_project_name=([^\s\\]+)/)
                                .flatten.uniq.reject do |value|
  value == "\\\"$integration_project_namespace\\\""
end
check(failures,
      negative_project_names == ["$integration_project_namespace-negative"],
      "integration scenario projects must derive from the sandbox namespace: " \
      "#{negative_project_names.inspect}")

# A contract that runs a play of its own is a second entry point into the same
# sandbox, and namespacing tests/integration.sh alone left it behind: the
# Audiobookshelf refusal suite converged Audiobookshelf into its production
# project, where the integration override's ${PLATFORM_PROJECT_NAME:?} refused
# the deployment before the refusal under test could be reached. Require both
# halves of the propagation — the harness exports the namespace to every such
# contract, and the contract derives its play's project from that export rather
# than naming a project of its own.
playing_contracts = Dir[File.join(ROOT, "tests", "contracts", "*.sh")].sort.select do |path|
  File.read(path).include?("ansible-playbook")
end
check(failures, !playing_contracts.empty?,
      "no contract runs a play of its own, so this namespace check polices nothing")
unnamespaced_contracts = playing_contracts.reject do |path|
  body = File.read(path)
  namespace_variable = body[/(\w+)\s*=\s*ENV\.fetch\("PLATFORM_PROJECT_NAME"/, 1]
  namespace_variable && body.include?("\"platform_project_name=\#{#{namespace_variable}}\"")
end
check(failures, unnamespaced_contracts.empty?,
      "contracts that run their own play must converge under the exported sandbox " \
      "namespace: #{unnamespaced_contracts.map { |path| File.basename(path) }.join(', ')}")
contract_launcher = harness[/^    run_contract\(\) \{.*?^    \}/m].to_s
unexported_namespace = playing_contracts.reject do |path|
  service = File.basename(path, ".sh")
  # The per-service extras now live in a case arm of the single launcher, so
  # read the arm that names this contract rather than a wrapper of its own.
  contract_launcher[
    /^\s*[a-z|]*\b#{Regexp.escape(service)}\b[a-z|]*\)\n(.*?)^\s*;;$/m, 1
  ].to_s.include?("PLATFORM_PROJECT_NAME=$integration_project_namespace")
end
check(failures, unexported_namespace.empty?,
      "integration must export the sandbox namespace to every contract that runs a " \
      "play: #{unexported_namespace.map { |path| File.basename(path) }.join(', ')}")

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

# Sandbox cleanup deletes a resource only when it carries the disposable
# namespace, so a service left with its fixed production name is not cleaned up
# at all: it survives the run and collides with the next one. Derive the
# requirement from the base and Mac Compose rather than a second hand-kept list,
# so adding a service to a stack cannot skip its override, and so the two
# disposable lanes cannot drift into naming the same container differently.
namespaced_container_names = {}
named_stacks = 0
Dir.children(File.join(ROOT, "services")).sort.each do |stack|
  base_path = File.join(ROOT, "services", stack, "compose.yml")
  next unless File.file?(base_path)

  override_path = File.join(ROOT, "services", stack, "compose.integration.yml")
  mac_path = File.join(ROOT, "services", stack, "compose.mac.yml")
  base = YAML.safe_load_file(base_path, aliases: true).fetch("services")
  production_named = base.select do |_service, definition|
    definition.is_a?(Hash) && definition["container_name"].is_a?(String) &&
      !definition.fetch("container_name").include?("${")
  end.keys
  # A service that declares no container name is already named after its project
  # by Compose, so it needs no override to be owned by the sandbox.
  unless production_named.empty?
    named_stacks += 1
    if File.file?(override_path) && File.file?(mac_path)
      override = YAML.safe_load_file(override_path).fetch("services")
      mac = YAML.safe_load_file(mac_path).fetch("services")
      unnamespaced = production_named.reject do |service|
        definition = override.fetch(service, nil)
        name = definition.is_a?(Hash) ? definition.fetch("container_name", nil) : nil
        name.is_a?(String) && name.start_with?("${PLATFORM_PROJECT_NAME:?}-") &&
          name == mac.fetch(service, {}).fetch("container_name", nil)
      end
      check(failures, unnamespaced.empty?,
            "#{stack} integration override leaves production container names " \
            "#{unnamespaced.sort.inspect}, which sandbox cleanup cannot remove")
    else
      check(failures, false, "#{stack} names containers without an integration " \
                             "and Mac Compose override")
    end
  end

  next unless File.file?(override_path)

  YAML.safe_load_file(override_path).fetch("services").each do |service, definition|
    name = definition.is_a?(Hash) ? definition["container_name"] : nil
    next unless name.is_a?(String)

    namespaced_container_names[name.delete_prefix("${PLATFORM_PROJECT_NAME:?}-")] =
      "#{stack}/#{service}"
  end
end
check(failures, named_stacks.positive?,
      "no service Compose declares a fixed container name to override")

# The cleanup registry is the only place that says which namespaced identity
# belongs to which project. It is checked against the overrides that create
# those containers, so a renamed or added service cannot leave cleanup looking
# for a container that is never created, or ignoring one that is.
cleanup_source = File.read(File.join(ROOT, "tests", "sandbox_cleanup.sh"))
registered_services = cleanup_source.scan(
  /^cleanup_sandbox_([a-z]+)_services='([^']*)'/
).to_h { |kind, services| [kind, services.split] }
cleanup_source.scan(
  /^cleanup_sandbox_([a-z]+)_services="\$cleanup_sandbox_\1_services ([^"]*)"/
).each { |kind, services| registered_services[kind].concat(services.split) }
registered_identities = registered_services.values.flatten.sort
check(failures,
      registered_identities == namespaced_container_names.keys.sort,
      "sandbox cleanup registers #{registered_identities.inspect}, but the " \
      "integration overrides create " \
      "#{namespaced_container_names.keys.sort.inspect}")

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
arr_environment = environment_assignments(
  File.join(ROOT, "roles", "arr", "templates", "env.j2")
)
downloaders_environment = environment_assignments(
  File.join(ROOT, "roles", "downloaders", "templates", "env.j2")
)
check(failures,
      arr_defaults.fetch("arr_platform_project_name", "").include?("platform_project_name | default('')") &&
        arr_defaults.fetch("arr_compose_project_name", "").include?("arr_platform_project_name ~ '-arr'") &&
        arr_argument_options.fetch("arr_platform_project_name", nil) == {
          "type" => "str", "required" => false
        } &&
        arr_environment.include?(["PLATFORM_PROJECT_NAME", "{{ arr_platform_project_name }}"]),
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
          ["PLATFORM_PROJECT_NAME", "{{ downloaders_platform_project_name }}"]
        ),
      "downloaders must derive their Compose project and container prefix through their role-scoped namespace")

# The defaults these three files declare, read as declarations. The
# concatenation this replaced could not say which file a match came from, and a
# scoped variable named in any comment counted as a leak into all three.
inventory_defaults = task_strings(
  YAML.safe_load_file(File.join(ROOT, "inventory", "group_vars", "all", "main.yml"))
)
host_prep = task_strings(
  flatten_tasks(YAML.safe_load_file(
    File.join(ROOT, "roles", "host_prep", "tasks", "main.yml"), aliases: true
  ))
)
legacy_defaults = task_strings(
  YAML.safe_load_file(File.join(ROOT, "roles", "audiobookshelf", "defaults", "main.yml"))
)
legacy_project_sources = inventory_defaults + host_prep + legacy_defaults
check(failures,
      inventory_defaults.any? { |value| value.include?("platform_project_name ~ '-media-control'") } &&
        host_prep.any? do |value|
          value.include?("platform_project_name | default('nas-platform', true)")
        end &&
        legacy_defaults.any? { |value| value.include?("platform_project_name ~ '-audiobookshelf'") } &&
        scoped_project_variables.none? do |variable|
          legacy_project_sources.any? { |value| value.include?(variable) }
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

# The disposable lane sets the platform namespace itself, and every pre-existing
# service derives its Compose project and the media-control bridge from it. This
# renders the same defaults the harness feeds Ansible, so a role that stops
# deriving its project is caught here rather than by a leaked sandbox container.
namespaced_projects, namespaced_error, namespaced_status = Open3.capture3(
  "ansible", "localhost", "-i", "localhost,", "-c", "local", "-m", "debug",
  "-a", "msg={{ platform_media_control_network }}|{{ ntfy_compose_project_name }}|" \
        "{{ beszel_compose_project_name }}|{{ dozzle_compose_project_name }}|" \
        "{{ audiobookshelf_compose_project_name }}|{{ komga_compose_project_name }}|" \
        "{{ jellyfin_compose_project_name }}|{{ immich_compose_project_name }}|" \
        "{{ paperless_compose_project_name }}|{{ arr_compose_project_name }}|" \
        "{{ downloaders_compose_project_name }}",
  "-e", "@inventory/group_vars/all/main.yml",
  "-e", "@roles/ntfy/defaults/main.yml",
  "-e", "@roles/beszel/vars/main.yml",
  "-e", "@roles/dozzle/defaults/main.yml",
  "-e", "@roles/audiobookshelf/defaults/main.yml",
  "-e", "@roles/komga/defaults/main.yml",
  "-e", "@roles/jellyfin/defaults/main.yml",
  "-e", "@roles/immich/defaults/main.yml",
  "-e", "@roles/paperless_ngx/defaults/main.yml",
  "-e", "@roles/arr/defaults/main.yml",
  "-e", "@roles/downloaders/defaults/main.yml",
  "-e", "platform_project_name=#{namespace}",
  chdir: ROOT
)
expected_namespaced = %w[
  media-control ntfy beszel dozzle audiobookshelf komga jellyfin immich paperless
  arr downloaders
].map { |suffix| "#{namespace}-#{suffix}" }.join("|")
check(failures,
      namespaced_status.success? &&
        namespaced_projects.include?(%Q{"msg": "#{expected_namespaced}"}),
      "effective namespaced project defaults differ: #{namespaced_error.strip}")
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
# Release happens only through an EXIT trap, so a lock that records nothing about
# its holder survives every hard termination -- and because the same lock gates
# tests/mac/cleanup.sh, the dead run's containers survive with it. Recovery has to
# stay a fact rather than a guess: serialized by a lock of its own, refused for a
# holder on another machine or another uid (where kill -0 answers EPERM, which is
# indistinguishable from "no such process"), and named in the refusal either way.
check(failures,
      integration_lock.include?('integration_lock_owner_identity > "$lock_candidate/owner"') &&
        integration_lock.include?('mkdir "$reclaim_guard" 2>/dev/null || return 1') &&
        integration_lock.include?('rmdir "$reclaim_target" 2>/dev/null') &&
        integration_lock.include?('! kill -0 "$reclaim_pid" 2>/dev/null') &&
        integration_lock.include?('[ "$reclaim_uid" = "$(id -u)" ]') &&
        integration_lock.include?('[ "$reclaim_host" = "$(uname -n)" ]') &&
        integration_lock.include?('  lock: %s'),
      "integration lock must record its holder and recover only a provably dead one")

report(failures, "integration policy: all properties hold", "integration policy violation(s)")
