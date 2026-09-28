#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Media managed-user probes; fixtures and helpers in media_managed_users_support.rb.

require_relative "media_managed_users_support"
require_relative "media_probes_fail_closed"
require_relative "media_probes_jellyfin_identity"
require_relative "media_probes_jellyfin_settings"
require_relative "media_probes_services"

require_relative "case_pool_support"
require_relative "policy_support"

include TestScaffold

# The behavioural probes, in report order, each with the
# MEDIA_MANAGED_USERS_PROBES selectors that ask for it.
PROBES = [
  [%w[all audiobookshelf], method(:exercise_audiobookshelf)],
  [%w[all audiobookshelf], method(:exercise_audiobookshelf_converged)],
  [%w[all jellyfin], method(:exercise_jellyfin)],
  [%w[all jellyfin], method(:exercise_jellyfin_converged)],
  [%w[all jellyfin_settings], method(:exercise_jellyfin_settings)],
  [%w[all jellyfin_settings], method(:exercise_jellyfin_server_configuration_refresh)],
  [%w[all jellyfin_settings], method(:exercise_jellyfin_policy_preflight)],
  [%w[all jellyfin_settings], method(:exercise_jellyfin_plugin_versions)],
  [%w[all jellyfin_settings], method(:exercise_jellyfin_restart_decision)],
  [%w[all jellyfin_settings], method(:exercise_jellyfin_restart_readiness)],
  [%w[all jellyfin_settings], method(:exercise_jellyfin_qsv_probe)],
  [%w[all jellyfin_settings], method(:exercise_jellyfin_opensubtitles_ordering)],
  [%w[all jellyfin_identity], method(:exercise_jellyfin_primary_identity_recovery)],
  [%w[all jellyfin_identity], method(:exercise_jellyfin_primary_preflight)],
  [%w[all jellyfin_identity], method(:exercise_jellyfin_server_name_repair)],
  [%w[all jellyfin_libraries], method(:exercise_jellyfin_extra_path_recovery)],
  [%w[all jellyfin_libraries], method(:exercise_jellyfin_library_inventory_global_gate)],
  [%w[all jellyfin_libraries], method(:exercise_jellyfin_library_rename_identity_refresh)],
  [%w[all jellyfin_libraries], method(:exercise_jellyfin_library_shape_preflight)],
  [%w[all komga], method(:exercise_komga)],
  [%w[all komga], method(:exercise_komga_converged)],
  [%w[all komga], method(:exercise_komga_capability_register)],
  [%w[all komga], method(:exercise_komga_verification)],
  [%w[all komga], method(:exercise_komga_parameter_contract)],
  [%w[all komga], method(:exercise_komga_review_plan)],
  [%w[all check_mode], method(:exercise_check_mode)],
  [%w[all check_mode], method(:exercise_jellyfin_fresh_check_mode)],
  [%w[all jellyfin_identity], method(:exercise_jellyfin_recovery_marker_safety)],
  [%w[all verify_tags], method(:exercise_verify_tag_selection)],
  [%w[all fail_closed], method(:exercise_komga_fail_closed)],
  [%w[all fail_closed], method(:exercise_media_fail_closed)],
  [%w[all fail_closed], method(:exercise_media_listing_fail_closed)],
  [%w[all credentials], method(:exercise_post_create_credential_failures)],
  [%w[all disabled], method(:exercise_disabled_target_rejection)]
].freeze

failures = []
failures.concat(jellyfin_identity_contract_failures)

SERVICES.each do |service|
  managed_path = File.join(ROOT, "roles", service, "tasks", "managed_users.yml")
  main_path = File.join(ROOT, "roles", service, "tasks", "main.yml")

  failures << "#{service} managed-user tasks are absent" unless File.file?(managed_path)
  next unless File.file?(managed_path)

  begin
    tasks = contract_source_tasks(service)
    failures << "#{service} managed-user tasks must be a task list" unless tasks.is_a?(Array)
    failures.concat(contract_failures(service, tasks)) if tasks.is_a?(Array)
  rescue Psych::SyntaxError => error
    failures << "#{service} managed-user tasks are invalid YAML: #{error.message.lines.first.strip}"
  end

  # The shim's own obligations, for a service on the shared role.
  if SHARED_MANAGED_USER_TITLES.key?(service)
    failures.concat(shim_failures(
                      service,
                      YAML.safe_load_file(managed_path, aliases: false),
                      YAML.safe_load_file(File.join(ROOT, "roles", service, "defaults", "main.yml"),
                                          aliases: false)
                    ))
  end

  # An include must be declared by a task; text matching accepted commented-out ones.
  included_files = nested_tasks(YAML.safe_load_file(main_path, aliases: false)).filter_map do |task|
    include = task["ansible.builtin.include_tasks"]
    include.is_a?(Hash) ? include["file"] : include
  end
  failures << "#{service} main tasks omit managed-user reconciliation" unless
    included_files.include?("managed_users.yml")
end

policy = File.read(VALIDATE_POLICY)
failures << "media managed-user normal test is not registered" unless
  policy.lines.include?("ruby tests/media_managed_users_test.rb\n")
failures << "media managed-user mutation self-test is not registered" unless
  policy.lines.include?("ruby tests/media_managed_users_test.rb --self-test\n")

if ARGV == ["--self-test"] && failures.empty?
  # Tally the plants that bit, so a --self-test output differs from a plain run.
  detected = []
  plant = lambda do |label, found|
    found ? detected << label : failures << "#{label} mutant survived"
  end

  SERVICES.each do |service|
    tasks = contract_source_tasks(service)
    repair = tasks.find { |task| task_name(task).match?(/Repair .* managed-user/) }
    mutant = Marshal.load(Marshal.dump(tasks))
    mutant_repair = mutant.find { |task| task_name(task) == task_name(repair) }
    mutant_repair.fetch("ansible.builtin.uri")["body"] = { "password" => "forbidden" }
    plant.call("#{service} password-update",
               contract_failures(service, mutant).any? { |failure| failure.include?("secret fields") })

    missing_verify = tasks.reject { |task| task_name(task) == REQUIRED_TASKS.fetch(service).last }
    plant.call("#{service} final-verification",
               contract_failures(service, missing_verify).any? do |failure|
                 failure.include?("Verify exact")
               end)

    next unless SHARED_MANAGED_USER_TITLES.key?(service)

    title = SHARED_MANAGED_USER_TITLES.fetch(service)
    shim = YAML.safe_load_file(File.join(ROOT, "roles", service, "tasks", "managed_users.yml"),
                               aliases: false)
    defaults = YAML.safe_load_file(File.join(ROOT, "roles", service, "defaults", "main.yml"),
                                   aliases: false)
    rebound = Marshal.load(Marshal.dump(shim))
    rebound.find { |task| task.key?("ansible.builtin.include_role") }
           .fetch("vars")["managed_users_declared"] = "{{ #{service}_unmanaged_users }}"
    plant.call("#{title} shim declared-set",
               shim_failures(service, rebound, defaults).any? do |failure|
                 failure.include?("managed_users_declared")
               end)

    detached = Marshal.load(Marshal.dump(shim))
    detached.find { |task| task.key?("ansible.builtin.include_role") }
            .fetch("ansible.builtin.include_role")["name"] = service
    plant.call("#{title} shim shared-role",
               shim_failures(service, detached, defaults).any? do |failure|
                 failure.include?("does not include the shared managed-user role")
               end)

    credentialed = Marshal.load(Marshal.dump(defaults))
    if service == "jellyfin"
      credentialed["jellyfin_managed_users_repair_body"] =
        credentialed["jellyfin_managed_users_repair_body"].sub(" }}", " | combine({'Password': item.password}) }}")
    else
      credentialed["#{service}_managed_users_repair_body"]["password"] = "{{ item.password }}"
    end
    plant.call("#{title} declared repair-body password",
               shim_failures(service, shim, credentialed).any? do |failure|
                 failure.include?("secret fields")
               end)

    if service == "jellyfin"
      unmerged = Marshal.load(Marshal.dump(defaults))
      unmerged["jellyfin_managed_users_repair_body"] = "{{ item.policy }}"
      plant.call("Jellyfin declared complete-policy merge",
                 shim_failures(service, shim, unmerged).any? do |failure|
                   failure.include?("complete current policy")
                 end)
      unhooked = Marshal.load(Marshal.dump(defaults))
      unhooked["jellyfin_managed_users_before_create_tasks"] = ""
      plant.call("Jellyfin before-create hook path",
                 shim_failures(service, shim, unhooked).any? do |failure|
                   failure.include?("jellyfin_managed_users_before_create_tasks does not name")
                 end)
      Dir.mktmpdir("jellyfin-hook-plant-") do |directory|
        JELLYFIN_HOOK_TASKS.each_value do |file, _names|
          FileUtils.cp(File.join(JELLYFIN_TASKS, file), directory)
        end
        planted = File.join(directory, "managed_users_refreshed_policies.yml")
        stripped = YAML.safe_load_file(planted, aliases: false).reject do |task|
          task_name(task) == "Require complete safe refreshed Jellyfin managed-user policies"
        end
        File.write(planted, YAML.dump(stripped))
        plant.call("Jellyfin refreshed-policy refusal removed from its hook",
                   jellyfin_hook_failures(defaults, directory).any? do |failure|
                     failure.include?("omits Require complete safe refreshed Jellyfin")
                   end)
      end
      next
    end

    if service == "audiobookshelf"
      unsplit = Marshal.load(Marshal.dump(defaults))
      unsplit["audiobookshelf_managed_users_repair_body"].delete("itemTagsSelected")
      plant.call("Audiobookshelf declared pinned repair body",
                 shim_failures(service, shim, unsplit).any? do |failure|
                   failure.include?("split the pinned permission fields")
                 end)
      next
    end

    KOMGA_AUTH_PASSWORD_EXPRESSIONS.each do |auth_name, expected_password|
      wrong_password = Marshal.load(Marshal.dump(tasks))
      wrong_password.find { |task| task_name(task) == auth_name }
                    .fetch("ansible.builtin.uri")["url_password"] = "{{ wrong_password }}"
      plant.call("#{auth_name.inspect} wrong-password (expected #{expected_password})",
                 contract_failures(service, wrong_password).any? do |failure|
                   failure.include?("vault password expression") && failure.include?(auth_name)
                 end)
    end
  end

  detected.each { |label| puts "self-test detected: #{label}" }
  # A stated count rather than non-emptiness, so a service the loop stopped
  # reaching is caught.
  failures << "media managed-user self-test planted #{detected.length} defects, expected 21" unless
    detected.length == 21
end

if ARGV.empty?
  unless command_available?("ansible-playbook")
    failures << "ansible-playbook is required for media managed-user behavior fixtures"
  else
    selected_probes = ENV.fetch("MEDIA_MANAGED_USERS_PROBES", "all").split(",")
    selected = PROBES.select { |scopes, _probe| selected_probes.intersect?(scopes) }
    # Probes share nothing but the failure list and mostly wait on a subprocess, so
    # they pool; failures still report in declared order.
    in_parallel_cases(failures, selected) do |(_scopes, probe), collected|
      probe.call(collected)
    end
  end
elsif ARGV != ["--self-test"] && !ARGV.empty?
  failures << "usage: media_managed_users_test.rb [--self-test]"
end

report(failures, "media managed users: lifecycle, mutation, and registration contracts passed",
       "media managed-user contract violation(s)")
