#!/usr/bin/env ruby
# Beszel and host preparation policy.
#
# Identity reads must be server-filtered and retain totals so the role can refuse a
# result that exceeds one response page, PocketBase relation writes need their
# connection pool refreshed exactly once, and verification-only runs must still
# carry the tasks their assertions depend on. Split out of policy_test.rb.

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

# Re-derived rather than shared: these are file reads, so each script that needs
# them opens the file itself instead of threading state between scripts.
beszel_contract_path = File.join(ROOT, "tests", "contracts", "beszel.sh")
beszel_contract = File.file?(beszel_contract_path) ? File.read(beszel_contract_path) : ""
harness = File.read(File.join(ROOT, "tests", "integration.sh"))

# Identity reads must be server-filtered and retain totals so the role can refuse
# an identity result that exceeds the complete 500-record response page.
beszel_tasks = flatten_tasks(
  YAML.safe_load_file(File.join(ROOT, "roles", "beszel", "tasks", "main.yml"))
)

host_prep_tasks = YAML.safe_load_file(File.join(ROOT, "roles", "host_prep", "tasks", "main.yml"))
host_prep_create = host_prep_tasks.find do |task|
  task["name"] == "Create service state directories"
end
host_prep_file = host_prep_create&.fetch("ansible.builtin.file", {})
check(failures, host_prep_file["owner"].to_s.include?("platform_kind == 'nas'") &&
                host_prep_file["owner"].to_s.include?("platform_manage_linux_ownership | bool") &&
                host_prep_file["group"].to_s.include?("platform_kind == 'nas'") &&
                host_prep_file["group"].to_s.include?("platform_manage_linux_ownership | bool") &&
                host_prep_file["owner"].to_s.include?("else omit") &&
                host_prep_file["group"].to_s.include?("else omit"),
      "host preparation must restrict Linux ownership to the explicit integration capability")
host_prep_marker_index = host_prep_tasks.index do |task|
  task["name"] == "Validate preservation-only storage declarations"
end
host_prep_inspect_index = host_prep_tasks.index do |task|
  task["name"] == "Inspect preservation-only service state directories"
end
host_prep_require_index = host_prep_tasks.index do |task|
  task["name"] == "Require safe preservation-only service state directories"
end
host_prep_create_index = host_prep_tasks.index do |task|
  task["name"] == "Create service state directories"
end
check(failures,
      host_prep_marker_index && host_prep_inspect_index && host_prep_require_index &&
        host_prep_create_index && host_prep_marker_index < host_prep_inspect_index &&
        host_prep_inspect_index < host_prep_require_index &&
        host_prep_require_index < host_prep_create_index,
      "host preparation must validate preservation-only storage before ordinary creation")
host_prep_marker_conditions = Array(
  host_prep_marker_index &&
    host_prep_tasks.fetch(host_prep_marker_index).dig("ansible.builtin.assert", "that")
).join(" ")
check(failures,
      host_prep_marker_conditions.include?("item.preserve_only is not defined") &&
        host_prep_marker_conditions.include?("item.preserve_only"),
      "host preparation must reject false preservation-only declarations")
host_prep_preservation_inspect =
  host_prep_inspect_index && host_prep_tasks.fetch(host_prep_inspect_index)
check(failures,
      host_prep_preservation_inspect&.dig("ansible.builtin.stat", "path") == "{{ item.path }}" &&
        host_prep_preservation_inspect&.dig("ansible.builtin.stat", "follow") == false &&
        host_prep_preservation_inspect&.fetch("loop", "").include?(
          "selectattr('preserve_only', 'defined')"
        ),
      "host preparation must inspect preservation-only storage without following symlinks")
host_prep_preservation_register = host_prep_preservation_inspect&.fetch("register", nil)
host_prep_preservation_require =
  host_prep_require_index && host_prep_tasks.fetch(host_prep_require_index)
host_prep_preservation_conditions = Array(
  host_prep_preservation_require&.dig("ansible.builtin.assert", "that")
).join(" ")
check(failures,
      %w[item.stat.exists item.stat.isdir not\ item.stat.islnk].all? do |condition|
        host_prep_preservation_conditions.include?(condition)
      end &&
        host_prep_preservation_require&.fetch("loop", "").include?(
          "#{host_prep_preservation_register}.results"
        ),
      "host preparation must refuse missing, non-directory, or symlink preservation-only storage")
check(failures,
      host_prep_create&.fetch("loop", "").include?(
        "rejectattr('preserve_only', 'defined')"
      ),
      "ordinary storage creation must include unmarked entries and exclude preservation-only storage")
# nas_media_root is an env-derived temp path on Mac hosts and reliably contains a
# dot, so feeding it to a regex test unescaped makes it match sibling directories.
media_ownership_conditions = Array(
  host_prep_tasks.find do |task|
    task["name"] == "Refuse to claim ownership of NAS-managed user files"
  end&.dig("ansible.builtin.assert", "that")
).join(" ")
check(failures, media_ownership_conditions.include?("nas_media_root | regex_escape"),
      "NAS-managed ownership refusal must escape nas_media_root before matching it as a regex")

preflight_tasks = YAML.safe_load_file(File.join(ROOT, "roles", "preflight", "tasks", "main.yml"))
ownership_guard = preflight_tasks.find do |task|
  task["name"] == "Restrict synthetic Linux ownership correction"
end&.dig("ansible.builtin.assert", "that")&.join(" ").to_s
%w[platform_manage_linux_ownership platform_compose_kind deployment_bundle_test_mode
   ansible_facts.system nas_docker_root nas_media_root].each do |token|
  check(failures, ownership_guard.include?(token),
        "integration Linux ownership guard must bind #{token}")
end

beszel_user_lists = beszel_tasks.select do |task|
  task["name"].to_s.start_with?("List application users") &&
    task["ansible.builtin.uri"].is_a?(Hash)
end
check(failures, beszel_user_lists.length == 2,
      "Beszel role must contain both application-user list operations")
beszel_user_lists.each do |task|
  url = task.dig("ansible.builtin.uri", "url")
  check(failures, url.is_a?(String) && url.include?("filter={{") && url.include?("urlencode") &&
                  !url.include?("skipTotal=1"),
        "#{task['name']}: must use a complete URL-encoded server identity filter")
end
check(failures,
      beszel_contract.include?('body: { role: "user" })') &&
        beszel_contract.include?('user["role"] == "user" && user["verified"] == true') &&
        !beszel_contract.include?('body: { role: "user", verified: false }'),
      "Beszel drift fixture must preserve the verified authentication prerequisite while drifting role")

beszel_complete_user_read = beszel_tasks.find do |task|
  task["name"] == "Read the complete PocketBase users collection for managed users"
end
check(failures,
      beszel_complete_user_read&.dig("ansible.builtin.uri", "url") ==
        "{{ beszel_api }}/api/collections/users/records?perPage=500",
      "Beszel managed users must reuse one explicitly bounded complete users collection")
beszel_complete_user_assert = beszel_tasks.find do |task|
  task["name"] == "Require a complete PocketBase users collection"
end
complete_user_conditions = Array(
  beszel_complete_user_assert&.dig("ansible.builtin.assert", "that")
).join(" ")
check(failures, complete_user_conditions.include?("totalPages") &&
                complete_user_conditions.include?("totalItems"),
      "Beszel complete users collection must prove pagination and item-count completeness")

beszel_alert_tasks = flatten_tasks(
  YAML.safe_load_file(File.join(ROOT, "roles", "beszel", "tasks", "alert.yml"))
)
identity_reads = (beszel_tasks + beszel_alert_tasks).select do |task|
  uri = task["ansible.builtin.uri"]
  uri.is_a?(Hash) && uri["method"].nil? && uri["url"].to_s.match?(%r{/collections/(users|universal_tokens|user_settings|systems|alerts)/records\?})
end
check(failures, identity_reads.length >= 11,
      "Beszel reconciliation must retain all filtered collection readbacks")
identity_reads.each do |task|
  next if task["name"] == "Read the complete PocketBase users collection for managed users"

  url = task.dig("ansible.builtin.uri", "url").to_s
  check(failures, url.include?("filter={{") && url.include?("urlencode") && !url.include?("skipTotal=1"),
        "#{task['name']}: collection readback must use a URL-encoded identity filter with totals")
end

beszel_create_user = beszel_tasks.find { |task| task["name"] == "Create the application user" }
beszel_plan_user = beszel_tasks.find { |task| task["name"] == "Report planned application user creation" }
check(failures, beszel_create_user && beszel_create_user["changed_when"] == true &&
                beszel_plan_user && beszel_plan_user["changed_when"] == true &&
                Array(beszel_plan_user["when"]).include?("ansible_check_mode"),
      "Beszel user creation must report real and check-mode predicted changes")

webhook_assert = beszel_tasks.find { |task| task["name"] == "Verify the managed ntfy webhook" }
webhook_failure = webhook_assert&.dig("ansible.builtin.assert", "fail_msg").to_s
webhook_summary = beszel_tasks.find do |task|
  task["name"] == "Summarize the managed ntfy webhook without URL bodies"
end
check(failures, webhook_failure.include?("scheme=") && webhook_failure.include?("[REDACTED]") &&
                !webhook_failure.match?(/actual=|expected=|webhooks/) &&
                webhook_summary && webhook_summary["no_log"] == true &&
                Array(webhook_assert&.dig("ansible.builtin.assert", "that")).all? do |condition|
                  !condition.match?(/notification|webhook.*url|webhooks/)
                end,
      "Beszel webhook mismatch diagnostics must never include URL bodies")
wrong_owner_assert = beszel_tasks.find do |task|
  task["name"] == "Refuse same-name systems outside the managed user relation"
end
check(failures, wrong_owner_assert && wrong_owner_assert.dig("ansible.builtin.assert", "that").to_s.include?("beszel_wrong_owner_systems"),
      "Beszel must reject same-name systems outside the managed user relation")
check(failures, beszel_contract.include?("URI.encode_www_form") &&
                beszel_contract.include?("same-name wrong-owner system IDs") &&
                !beszel_contract.include?("skipTotal=1"),
      "Beszel contract must use complete encoded identity filters and enforce system ownership")
%w[sentinel-user sentinel-password sentinel-query-key].each do |sentinel|
  check(failures, harness.include?(sentinel),
        "integration must test redaction of arbitrary webhook sentinel #{sentinel}")
end

# PocketBase validates relations through a separate SQLite connection. Refresh
# that pool exactly once after the one-time user insert and before relation writes.
beszel_create_index = beszel_tasks.index do |task|
  task["name"] == "Create the application user"
end
beszel_refresh_indexes = beszel_tasks.each_index.select do |index|
  beszel_tasks[index]["name"] ==
    "Refresh Beszel database connections after creating the application user"
end
beszel_second_list_index = beszel_tasks.index do |task|
  task["name"] == "List application users again to resolve the id"
end
check(failures, beszel_refresh_indexes.length == 1,
      "Beszel must refresh database connections exactly once after creating its user")
unless beszel_refresh_indexes.empty?
  refresh_index = beszel_refresh_indexes.first
  refresh = beszel_tasks[refresh_index]
  compose = refresh["community.docker.docker_compose_v2"]
  check(failures, beszel_create_index && beszel_second_list_index &&
                  beszel_create_index < refresh_index && refresh_index < beszel_second_list_index,
        "Beszel database refresh must follow user creation and precede relation setup")
  check(failures, compose.is_a?(Hash) && compose["services"] == ["hub"] &&
                  compose["state"] == "restarted" && compose["wait"] == true,
        "Beszel database refresh must restart and wait for only the hub")
  check(failures, refresh["when"] == "beszel_matching_users | length == 0",
        "Beszel database refresh must run only when the application user is created")
end

readme = File.read(File.join(ROOT, "README.md"))
gitignore = File.read(File.join(ROOT, ".gitignore"))
check(failures, readme.include?("tests/mac/run.sh") &&
                readme.include?("--lane fresh") &&
                readme.include?("--keep-on-failure"),
      "README must document the Mac proof lane and failure preservation")
check(failures, gitignore.include?("mac-proof-reports"),
      "gitignore must exclude local Mac proof report copies")

beszel_verification_prerequisites = {
  "Select the Beszel mounted state root" => "ansible.builtin.set_fact",
  "Authenticate as the superuser" => "ansible.builtin.uri",
  "Read the public key the hub advertises" => "ansible.builtin.uri",
  "Verify the advertised key matches vault, proving no read-back is needed" =>
    "ansible.builtin.assert"
}
beszel_verification_prerequisites.each do |name, module_name|
  task = beszel_tasks.find { |candidate| candidate["name"] == name }
  check(failures, task && task.key?(module_name) &&
                  Array(task["tags"]).include?("platform_verify_beszel"),
        "Beszel verification-only run must include #{name.downcase}")
end

tinymediamanager_tasks = flatten_tasks(
  YAML.safe_load_file(File.join(ROOT, "roles", "tinymediamanager", "tasks", "main.yml"))
)
tinymediamanager_state_root = tinymediamanager_tasks.find do |task|
  task["name"] == "Select the tinyMediaManager preserved state root"
end
check(failures,
      tinymediamanager_state_root&.key?("ansible.builtin.set_fact") &&
        Array(tinymediamanager_state_root["tags"]).include?("platform_verify_tinymediamanager"),
      "tinyMediaManager verification-only run must derive its preserved state root")


if failures.empty?
  puts "beszel policy: all properties hold"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} beszel policy violation(s)"
end
