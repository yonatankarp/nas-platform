#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Media managed-user probes. Fixtures and helpers live in
# media_managed_users_support.rb.

require_relative "media_managed_users_support"
require_relative "media_probes_fail_closed"
require_relative "media_probes_jellyfin_identity"
require_relative "media_probes_jellyfin_settings"
require_relative "media_probes_services"

require_relative "case_pool_support"
require_relative "policy_support"

include TestScaffold

# The behavioural probes, in the order they are reported, each with the
# MEDIA_MANAGED_USERS_PROBES selectors that ask for it. They were a run of
# `exercise_x(failures) if selected_probes.intersect?(...)` statements; naming
# them as data is what lets the pool below place them, and it keeps the
# selectors readable next to each other rather than repeated down a column.
PROBES = [
  [%w[all audiobookshelf], method(:exercise_audiobookshelf)],
  [%w[all jellyfin], method(:exercise_jellyfin)],
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
  [%w[all jellyfin_libraries], method(:exercise_jellyfin_extra_path_recovery)],
  [%w[all jellyfin_libraries], method(:exercise_jellyfin_library_inventory_global_gate)],
  [%w[all jellyfin_libraries], method(:exercise_jellyfin_library_rename_identity_refresh)],
  [%w[all jellyfin_libraries], method(:exercise_jellyfin_library_shape_preflight)],
  [%w[all komga], method(:exercise_komga)],
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
    tasks = YAML.safe_load_file(managed_path, aliases: false)
    failures << "#{service} managed-user tasks must be a task list" unless tasks.is_a?(Array)
    failures.concat(contract_failures(service, tasks)) if tasks.is_a?(Array)
  rescue Psych::SyntaxError => error
    failures << "#{service} managed-user tasks are invalid YAML: #{error.message.lines.first.strip}"
  end

  # An include has to be declared by a task, not merely mentioned. The source-text
  # form accepted a commented-out include and a task file named in prose.
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
  SERVICES.each do |service|
    tasks = YAML.safe_load_file(
      File.join(ROOT, "roles", service, "tasks", "managed_users.yml"), aliases: false
    )
    repair = tasks.find { |task| task_name(task).match?(/Repair .* managed-user/) }
    mutant = Marshal.load(Marshal.dump(tasks))
    mutant_repair = mutant.find { |task| task_name(task) == task_name(repair) }
    mutant_repair.fetch("ansible.builtin.uri")["body"] = { "password" => "forbidden" }
    unless contract_failures(service, mutant).any? { |failure| failure.include?("secret fields") }
      failures << "#{service} password-update mutant survived"
    end

    if %w[audiobookshelf jellyfin].include?(service) &&
       !contract_failures(service, mutant).any? { |failure| failure.match?(/split|complete current policy/) }
      failures << "#{service} pinned merge/body mutant survived"
    end

    missing_verify = tasks.reject { |task| task_name(task) == REQUIRED_TASKS.fetch(service).last }
    unless contract_failures(service, missing_verify).any? { |failure| failure.include?("Verify exact") }
      failures << "#{service} final-verification mutant survived"
    end

    next unless service == "komga"

    KOMGA_AUTH_PASSWORD_EXPRESSIONS.each do |auth_name, expected_password|
      wrong_password = Marshal.load(Marshal.dump(tasks))
      wrong_password.find { |task| task_name(task) == auth_name }
                    .fetch("ansible.builtin.uri")["url_password"] = "{{ wrong_password }}"
      unless contract_failures(service, wrong_password).any? do |failure|
        failure.include?("vault password expression") && failure.include?(auth_name)
      end
        failures << "Komga #{auth_name} wrong-password mutant survived (expected #{expected_password})"
      end
    end
  end
end

if ARGV.empty?
  unless command_available?("ansible-playbook")
    failures << "ansible-playbook is required for media managed-user behavior fixtures"
  else
    selected_probes = ENV.fetch("MEDIA_MANAGED_USERS_PROBES", "all").split(",")
    selected = PROBES.select { |scopes, _probe| selected_probes.intersect?(scopes) }
    # Every probe stands up its own stub server on an OS-assigned port and runs
    # its own ansible-playbook in its own temporary directory, so they share
    # nothing but the failure list -- and almost all of their wall time is spent
    # waiting on that subprocess, which releases the GVL. Run one after another
    # this was the gate's slowest single check; run through the pool the probes
    # are placed alongside each other and their failures are still reported in
    # the order they are declared above.
    in_parallel_cases(failures, selected) do |(_scopes, probe), collected|
      probe.call(collected)
    end
  end
elsif ARGV != ["--self-test"] && !ARGV.empty?
  failures << "usage: media_managed_users_test.rb [--self-test]"
end

report(failures, "media managed users: lifecycle, mutation, and registration contracts passed",
       "media managed-user contract violation(s)")
