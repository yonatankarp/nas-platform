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

require_relative "policy_support"

include TestScaffold

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
    exercise_audiobookshelf(failures) if selected_probes.intersect?(%w[all audiobookshelf])
    exercise_jellyfin(failures) if selected_probes.intersect?(%w[all jellyfin])
    exercise_jellyfin_settings(failures) if selected_probes.intersect?(%w[all jellyfin_settings])
    exercise_jellyfin_server_configuration_refresh(failures) if
      selected_probes.intersect?(%w[all jellyfin_settings])
    exercise_jellyfin_policy_preflight(failures) if
      selected_probes.intersect?(%w[all jellyfin_settings])
    exercise_jellyfin_plugin_versions(failures) if
      selected_probes.intersect?(%w[all jellyfin_settings])
    exercise_jellyfin_restart_decision(failures) if
      selected_probes.intersect?(%w[all jellyfin_settings])
    exercise_jellyfin_restart_readiness(failures) if
      selected_probes.intersect?(%w[all jellyfin_settings])
    exercise_jellyfin_qsv_probe(failures) if
      selected_probes.intersect?(%w[all jellyfin_settings])
    exercise_jellyfin_opensubtitles_ordering(failures) if
      selected_probes.intersect?(%w[all jellyfin_settings])
    exercise_jellyfin_primary_identity_recovery(failures) if
      selected_probes.intersect?(%w[all jellyfin_identity])
    exercise_jellyfin_primary_preflight(failures) if
      selected_probes.intersect?(%w[all jellyfin_identity])
    exercise_jellyfin_extra_path_recovery(failures) if
      selected_probes.intersect?(%w[all jellyfin_libraries])
    exercise_jellyfin_library_inventory_global_gate(failures) if
      selected_probes.intersect?(%w[all jellyfin_libraries])
    exercise_jellyfin_library_rename_identity_refresh(failures) if
      selected_probes.intersect?(%w[all jellyfin_libraries])
    exercise_jellyfin_library_shape_preflight(failures) if
      selected_probes.intersect?(%w[all jellyfin_libraries])
    exercise_komga(failures) if selected_probes.intersect?(%w[all komga])
    exercise_check_mode(failures) if selected_probes.intersect?(%w[all check_mode])
    exercise_jellyfin_fresh_check_mode(failures) if
      selected_probes.intersect?(%w[all check_mode])
    exercise_jellyfin_recovery_marker_safety(failures) if
      selected_probes.intersect?(%w[all jellyfin_identity])
    exercise_verify_tag_selection(failures) if selected_probes.intersect?(%w[all verify_tags])
    exercise_komga_fail_closed(failures) if selected_probes.intersect?(%w[all fail_closed])
    exercise_media_fail_closed(failures) if selected_probes.intersect?(%w[all fail_closed])
    exercise_media_listing_fail_closed(failures) if selected_probes.intersect?(%w[all fail_closed])
    exercise_post_create_credential_failures(failures) if selected_probes.intersect?(%w[all credentials])
    exercise_disabled_target_rejection(failures) if selected_probes.intersect?(%w[all disabled])
  end
elsif ARGV != ["--self-test"] && !ARGV.empty?
  failures << "usage: media_managed_users_test.rb [--self-test]"
end

report(failures, "media managed users: lifecycle, mutation, and registration contracts passed",
       "media managed-user contract violation(s)")
