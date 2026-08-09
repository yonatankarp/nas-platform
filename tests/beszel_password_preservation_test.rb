#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)
TASKS_PATH = ENV.fetch(
  "BESZEL_PASSWORD_TASKS_PATH",
  File.join(ROOT, "roles", "beszel", "tasks", "main.yml")
)

def check(failures, condition, message)
  failures << message unless condition
end

def normalized(value)
  value.to_s.split.join(" ")
end

tasks = YAML.safe_load_file(TASKS_PATH, aliases: false)
failures = []

exec_tasks = tasks.filter_map do |task|
  command = task["community.docker.docker_compose_v2_exec"]
  [task, command] if command.is_a?(Hash)
end
forbidden_superuser_commands = exec_tasks.filter_map do |task, command|
  argv = Array(command["argv"])
  task["name"] if argv.include?("superuser") && (argv & %w[upsert update]).any?
end
check(failures, forbidden_superuser_commands.empty?,
      "Beszel must never invoke superuser upsert/update: #{forbidden_superuser_commands.join(', ')}")

superuser_create = tasks.find { |task| task["name"] == "Create the superuser without updating an existing identity" }
create_command = superuser_create&.fetch("community.docker.docker_compose_v2_exec", nil)
create_argv = create_command.is_a?(Hash) ? Array(create_command["argv"]) : []
check(failures,
      create_argv == ["/beszel", "superuser", "create",
                      "{{ vault_beszel_superuser_email }}",
                      "{{ vault_beszel_superuser_password }}"],
      "Beszel superuser provisioning must use the exact atomic create-only command")
check(failures, superuser_create&.fetch("register", nil) == "beszel_superuser_create",
      "Beszel must capture the atomic superuser create result")
check(failures, superuser_create&.fetch("failed_when", nil) == false,
      "Beszel must defer create-result classification until exact authentication")
check(failures, superuser_create&.fetch("changed_when", nil).to_s.include?("beszel_superuser_create.rc") &&
                superuser_create&.fetch("changed_when", nil).to_s.match?(/==\s*0/),
      "Beszel must report superuser creation only when create exits successfully")

superuser_auth = tasks.find { |task| task["name"] == "Authenticate as the superuser" }
expected_superuser_auth = {
  "url" => "{{ beszel_api }}/api/collections/_superusers/auth-with-password",
  "method" => "POST",
  "body_format" => "json",
  "body" => {
    "identity" => "{{ vault_beszel_superuser_email }}",
    "password" => "{{ vault_beszel_superuser_password }}"
  },
  "status_code" => [200, 400, 403]
}
check(failures, superuser_auth&.fetch("ansible.builtin.uri", nil) == expected_superuser_auth,
      "Beszel must use the exact captured superuser authentication request")
check(failures, superuser_auth&.fetch("register", nil) == "beszel_auth" &&
                superuser_auth&.fetch("changed_when", nil) == false &&
                superuser_auth&.fetch("check_mode", nil) == false &&
                superuser_auth&.fetch("no_log", nil) == "{{ beszel_no_log | default(true) }}",
      "Beszel superuser authentication must preserve its exact result and redaction contract")

superuser_assert = tasks.find { |task| task["name"] == "Require created or preserved Beszel superuser credentials" }
superuser_conditions = Array(superuser_assert&.dig("ansible.builtin.assert", "that"))
classification = superuser_conditions.find { |condition| condition.include?("beszel_superuser_create.rc") }
expected_classification = <<~CONDITION
  beszel_superuser_create.rc | default(1) | int == 0
  or beszel_auth.status | int == 200
CONDITION
check(failures,
      normalized(classification) == normalized(expected_classification),
      "only successful creation or exact preserved-credential authentication may satisfy superuser provisioning")
check(failures, superuser_conditions.include?("beszel_auth.status | int == 200"),
      "superuser preservation assertion must independently require exact post-create authentication")
check(failures, superuser_conditions.length == 2,
      "superuser preservation assertion must contain exact classification and authentication conditions")
check(failures, !superuser_conditions.join(" ").match?(/std(out|err)/),
      "superuser create-result classification must not parse brittle command output")
check(failures, superuser_assert&.fetch("no_log", nil) == true,
      "the superuser preservation assertion must always redact credentials")

create_index = superuser_create && tasks.index(superuser_create)
auth_index = superuser_auth && tasks.index(superuser_auth)
assert_index = superuser_assert && tasks.index(superuser_assert)
check(failures,
      create_index && auth_index && assert_index && create_index < auth_index && auth_index < assert_index,
      "Beszel must authenticate and classify the result immediately after atomic superuser creation")

app_auth = tasks.find do |task|
  task["name"] == "Check whether the managed application user accepts vault credentials"
end
expected_app_auth = {
  "url" => "{{ beszel_api }}/api/collections/users/auth-with-password",
  "method" => "POST",
  "body_format" => "json",
  "body" => {
    "identity" => "{{ vault_beszel_app_user_email }}",
    "password" => "{{ vault_beszel_app_user_password }}"
  },
  "status_code" => [200, 400, 403]
}
check(failures, app_auth&.fetch("ansible.builtin.uri", nil) == expected_app_auth,
      "Beszel must use the exact captured application-user authentication request")
check(failures, app_auth&.fetch("register", nil) == "beszel_app_user_auth" &&
                app_auth&.fetch("changed_when", nil) == false &&
                app_auth&.fetch("check_mode", nil) == false &&
                app_auth&.fetch("no_log", nil) == "{{ beszel_no_log | default(true) }}" &&
                app_auth&.fetch("when", nil) == "beszel_user_id | length > 0",
      "Beszel application-user authentication must preserve its exact result, redaction, and presence contract")

app_create = tasks.find { |task| task["name"] == "Create the application user" }
app_create_uri = app_create&.fetch("ansible.builtin.uri", nil)
app_create_body = app_create&.dig("ansible.builtin.uri", "body")
check(failures,
      app_create_uri.is_a?(Hash) &&
        app_create_uri["url"] == "{{ beszel_api }}/api/collections/users/records" &&
        app_create_uri["method"] == "POST" && app_create_uri["body_format"] == "json" &&
        app_create_uri["status_code"] == [200],
      "Beszel must use the exact fail-closed application-user creation request")
check(failures, app_create_body.is_a?(Hash) &&
                app_create_body["email"] == "{{ vault_beszel_app_user_email }}" &&
                app_create_body["password"] == "{{ vault_beszel_app_user_password }}" &&
                app_create_body["passwordConfirm"] == "{{ vault_beszel_app_user_password }}",
      "Beszel must use the exact vault identity and credentials for absent application-user creation")
check(failures, app_create&.fetch("when", nil) == "beszel_matching_users | length == 0",
      "Beszel must create the primary application user only when it is absent")

app_assert = tasks.find do |task|
  task["name"] == "Require preserved Beszel application-user credentials"
end
expected_guidance = <<~TEXT
  Existing Beszel application user does not accept its preserved vault
  password. Run the reviewed credential-migration procedure; Ansible will
  not reset it automatically.
TEXT
check(failures,
      app_assert&.dig("ansible.builtin.assert", "that") ==
        ["beszel_app_user_auth.status | int == 200"],
      "existing Beszel application users must assert successful authentication")
check(failures,
      normalized(app_assert&.dig("ansible.builtin.assert", "fail_msg")) == normalized(expected_guidance),
      "failed application-user authentication must give exact credential-migration guidance")
check(failures, app_assert&.fetch("when", nil) == "beszel_user_id | length > 0",
      "the application-user preservation assertion must apply only to an existing identity")
check(failures, app_assert&.fetch("no_log", nil) == true,
      "the application-user preservation assertion must always redact credentials")

existing_user_patches = tasks.select do |task|
  uri = task["ansible.builtin.uri"]
  uri.is_a?(Hash) && uri["method"] == "PATCH" &&
    uri["url"].to_s.include?("/api/collections/users/records/")
end
check(failures, !existing_user_patches.empty?,
      "Beszel must retain non-secret application-user reconciliation")
existing_user_patches.each do |task|
  body = task.dig("ansible.builtin.uri", "body")
  check(failures, body.is_a?(Hash), "#{task['name']}: PATCH body must be a mapping")
  next unless body.is_a?(Hash)

  forbidden = body.keys & %w[password passwordConfirm]
  check(failures, forbidden.empty?,
        "#{task['name']}: existing-user PATCH must not contain #{forbidden.join(', ')}")
  check(failures, body.keys.sort == %w[role verified],
        "#{task['name']}: existing-user PATCH must contain only role and verified")
end

app_assert_index = app_assert && tasks.index(app_assert)
app_auth_index = app_auth && tasks.index(app_auth)
patch_indexes = existing_user_patches.map { |task| tasks.index(task) }
check(failures,
      app_auth_index && app_assert_index && app_auth_index < app_assert_index &&
        patch_indexes.all? { |index| app_assert_index < index },
      "Beszel must authenticate and assert preserved credentials before any existing-user PATCH")

if ARGV == ["--self-test"] && failures.empty?
  mutations = {
    "missing unconditional superuser authentication" => [
      "superuser preservation assertion must independently require exact post-create authentication",
      lambda do |fixture|
        assertion = fixture.find do |task|
          task["name"] == "Require created or preserved Beszel superuser credentials"
        end
        assertion.fetch("ansible.builtin.assert").fetch("that").delete("beszel_auth.status | int == 200")
      end
    ],
    "wrong superuser authentication endpoint" => [
      "Beszel must use the exact captured superuser authentication request",
      lambda do |fixture|
        auth = fixture.find { |task| task["name"] == "Authenticate as the superuser" }
        auth.fetch("ansible.builtin.uri")["url"] = "{{ beszel_api }}/api/collections/users/auth-with-password"
      end
    ],
    "wrong application-user authentication password" => [
      "Beszel must use the exact captured application-user authentication request",
      lambda do |fixture|
        auth = fixture.find do |task|
          task["name"] == "Check whether the managed application user accepts vault credentials"
        end
        auth.dig("ansible.builtin.uri", "body")["password"] = "wrong"
      end
    ],
    "wrong absent application-user confirmation" => [
      "Beszel must use the exact vault identity and credentials for absent application-user creation",
      lambda do |fixture|
        create = fixture.find { |task| task["name"] == "Create the application user" }
        create.dig("ansible.builtin.uri", "body")["passwordConfirm"] = "wrong"
      end
    ]
  }

  Dir.mktmpdir("beszel-password-preservation") do |directory|
    mutations.each do |label, (expected_failure, mutate)|
      fixture = Marshal.load(Marshal.dump(tasks))
      mutate.call(fixture)
      path = File.join(directory, "tasks.yml")
      File.write(path, YAML.dump(fixture))
      _stdout, stderr, status = Open3.capture3(
        { "BESZEL_PASSWORD_TASKS_PATH" => path },
        RbConfig.ruby, __FILE__
      )
      check(failures, !status.success? && stderr.include?(expected_failure),
            "self-test mutation was not rejected precisely: #{label}")
    end
  end
end

if failures.empty?
  message = if ARGV == ["--self-test"]
              "Beszel password preservation mutation self-test passed"
            else
              "Beszel password preservation contract passed"
            end
  puts message
  exit 0
end

warn failures.map { |failure| "FAIL: #{failure}" }.join("\n")
exit 1
