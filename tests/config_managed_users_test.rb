#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)
DOZZLE_TASKS = File.join(ROOT, "roles", "dozzle", "tasks", "managed_users.yml")
DOZZLE_MAIN = File.join(ROOT, "roles", "dozzle", "tasks", "main.yml")
DOZZLE_TEMPLATE = File.join(ROOT, "roles", "dozzle", "templates", "users.yml.j2")
NTFY_TASKS = File.join(ROOT, "roles", "ntfy", "tasks", "managed_users.yml")
NTFY_MAIN = File.join(ROOT, "roles", "ntfy", "tasks", "main.yml")
VALIDATE_POLICY = File.join(ROOT, "tests", "validate-policy.sh")

BCRYPT_A = "$2b$12$aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
BCRYPT_B = "$2b$12$bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
TOKEN_A = "tk_aaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
TOKEN_B = "tk_bbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

def check(failures, condition, message)
  failures << message unless condition
end

def read(path)
  File.read(path)
rescue Errno::ENOENT
  ""
end

def command_available?(name)
  ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
    File.executable?(File.join(directory, name))
  end
end

def source_fragment_failures(sources)
  required = {
    "Dozzle safe load" => ["dozzle_tasks", "from_yaml"],
    "Dozzle hash refusal" => ["dozzle_tasks", "will not replace"],
    "Dozzle unmanaged preservation" => ["dozzle_tasks", "dozzle_unmanaged_users"],
    "Dozzle rendered loop" => ["dozzle_template", "{% for"],
    "Dozzle managed authentication" => ["dozzle_main", "vault_managed_dozzle_users"],
    "ntfy user provisioning" => ["ntfy_tasks", "ntfy_auth_users"],
    "ntfy token ownership" => ["ntfy_tasks", "Refuse duplicate ntfy token ownership"],
    "ntfy Basic authentication" => ["ntfy_tasks", "force_basic_auth: true"],
    "ntfy declared access verification" => ["ntfy_tasks", "Verify managed ntfy declared write access"],
    "policy registration" => ["validate_policy", "config_managed_users_test.rb --self-test"]
  }
  required.filter_map do |label, (source_name, fragment)|
    label unless sources.fetch(source_name).include?(fragment)
  end
end

def run_playbook(source, extra_vars = {})
  Dir.mktmpdir("nas-platform-config-managed-users-") do |directory|
    playbook = File.join(directory, "playbook.yml")
    File.write(playbook, source, mode: "w", perm: 0o600)
    stdout, stderr, status = Open3.capture3(
      { "ANSIBLE_NOCOLOR" => "1" },
      "ansible-playbook", "-i", "localhost,", "-c", "local", playbook,
      "-e", JSON.generate(extra_vars), chdir: ROOT
    )
    yield directory, stdout + stderr, status
  end
end

def dozzle_playbook(users_path, output_path)
  <<~YAML
    ---
    - hosts: localhost
      gather_facts: false
      vars:
        dozzle_users_path: #{users_path.to_json}
        vault_dozzle_admin_username: admin
        vault_dozzle_admin_password_hash: #{BCRYPT_A.to_json}
        vault_managed_dozzle_users:
          - username: reader
            password: managed-plaintext
            password_hash: #{BCRYPT_B.to_json}
            email: reader@example.invalid
            name: Managed Reader
            filter: status=running
            roles: user
        dozzle_managed_users_phase: reconcile
      tasks:
        - ansible.builtin.include_tasks: #{DOZZLE_TASKS.to_json}
        - ansible.builtin.template:
            src: #{DOZZLE_TEMPLATE.to_json}
            dest: #{output_path.to_json}
            mode: "0600"
  YAML
end

def run_dozzle_fixture(source)
  result = nil
  Dir.mktmpdir("nas-platform-dozzle-users-") do |directory|
    users_path = File.join(directory, "users.yml")
    output_path = File.join(directory, "rendered.yml")
    File.write(users_path, source, mode: "w", perm: 0o600)
    run_playbook(dozzle_playbook(users_path, output_path)) do |_tmp, output, status|
      rendered = if status.success? && File.file?(output_path)
                   YAML.safe_load_file(output_path, aliases: false)
                 end
      result = [rendered, output, status]
    end
  end
  result
end

def ntfy_playbook(output_path)
  <<~YAML
    ---
    - hosts: localhost
      gather_facts: false
      vars:
        ntfy_topic: nas-critical
        vault_ntfy_admin_user: admin
        vault_ntfy_admin_password_hash: #{BCRYPT_A.to_json}
        ntfy_publishers:
          - name: dozzle
            password_hash: #{BCRYPT_A.to_json}
            token: #{TOKEN_A}
        vault_managed_ntfy_users:
          - username: reader
            password: managed-plaintext
            password_hash: #{BCRYPT_B.to_json}
            role: user
            access:
              - topic: nas-critical
                permission: read-only
              - topic: private
                permission: deny
            tokens: [#{TOKEN_B}]
        ntfy_managed_users_phase: provision
      tasks:
        - ansible.builtin.include_tasks: #{NTFY_TASKS.to_json}
        - ansible.builtin.copy:
            dest: #{output_path.to_json}
            mode: "0600"
            content: >-
              {{ {'users': ntfy_auth_users, 'access': ntfy_auth_access,
                  'tokens': ntfy_auth_tokens} | to_json }}
  YAML
end

def run_ntfy_fixture(extra_vars = {})
  result = nil
  Dir.mktmpdir("nas-platform-ntfy-users-") do |directory|
    output_path = File.join(directory, "provisioning.json")
    run_playbook(ntfy_playbook(output_path), extra_vars) do |_tmp, output, status|
      rendered = JSON.parse(File.read(output_path)) if status.success? && File.file?(output_path)
      result = [rendered, output, status]
    end
  end
  result
end

failures = []
dozzle_tasks = read(DOZZLE_TASKS)
dozzle_main = read(DOZZLE_MAIN)
dozzle_template = read(DOZZLE_TEMPLATE)
ntfy_tasks = read(NTFY_TASKS)
ntfy_main = read(NTFY_MAIN)

check(failures, !dozzle_tasks.empty?, "Dozzle managed-user tasks are missing")
check(failures, dozzle_main.include?("managed_users.yml"), "Dozzle main tasks do not include managed-user reconciliation")
check(failures, dozzle_tasks.include?("from_yaml"), "Dozzle does not safe-load the existing users file")
check(failures, dozzle_tasks.include?("stat.isreg") && dozzle_tasks.include?("stat.islnk"),
      "Dozzle does not require an existing regular, non-symlink users file")
check(failures, dozzle_tasks.include?("rescue:"), "Dozzle does not reject malformed YAML explicitly")
check(failures, dozzle_tasks.include?("dozzle_existing_normalized_names") &&
                dozzle_tasks.include?("unique | length"),
      "Dozzle does not reject duplicate normalized existing names")
check(failures, dozzle_tasks.include?("password") && dozzle_tasks.include?("password_hash") &&
                dozzle_tasks.include?("will not replace"),
      "Dozzle does not refuse stored hash replacement")
check(failures, dozzle_tasks.include?("dozzle_unmanaged_users") &&
                dozzle_tasks.include?("dozzle_reconciled_users"),
      "Dozzle does not preserve and merge unmanaged users")
check(failures, dozzle_template.include?("{% for") && dozzle_template.include?("to_json"),
      "Dozzle users template does not safely loop over reconciled users")
check(failures, dozzle_main.include?("when: dozzle_users_file.changed"),
      "Dozzle restart is not conditional on users file change")
check(failures, dozzle_main.include?("{{ dozzle_api }}/token") &&
                dozzle_main.include?("vault_managed_dozzle_users"),
      "Dozzle does not authenticate every managed plaintext password at api/token")

if command_available?("ansible-playbook") && !dozzle_tasks.empty?
  existing = {
    "users" => {
      "admin" => { "email" => "old", "name" => "Wrong", "password" => BCRYPT_A,
                     "filter" => "old", "roles" => "admin" },
      "reader" => { "email" => "old", "name" => "Wrong", "password" => BCRYPT_B,
                      "filter" => "old", "roles" => "none", "stale" => true },
      "unmanaged" => { "password" => "opaque", "custom" => { "nested" => [1, "two"] } }
    },
    "outside" => { "preserved" => true }
  }
  rendered, output, status = run_dozzle_fixture(YAML.dump(existing))
  check(failures, status.success?, "Dozzle merge fixture failed: #{output.lines.last&.strip}")
  if rendered
    check(failures, rendered["outside"] == existing["outside"], "Dozzle did not preserve root keys outside users")
    check(failures, rendered.dig("users", "unmanaged") == existing.dig("users", "unmanaged"),
          "Dozzle did not preserve an unmanaged user verbatim")
    check(failures, rendered.dig("users", "reader") == {
            "email" => "reader@example.invalid", "name" => "Managed Reader",
            "password" => BCRYPT_B, "filter" => "status=running", "roles" => "user"
          }, "Dozzle did not render the exact managed non-secret fields")
  end

  _rendered, _output, status = run_dozzle_fixture("users: [malformed mapping]\n")
  check(failures, !status.success?, "Dozzle accepted a malformed users document")
  hash_change = Marshal.load(Marshal.dump(existing))
  hash_change["users"]["reader"]["password"] = BCRYPT_A
  _rendered, output, status = run_dozzle_fixture(YAML.dump(hash_change))
  check(failures, !status.success? && output.include?("will not replace"),
        "Dozzle accepted a hash change for an existing allowlisted identity")
  duplicate_names = Marshal.load(Marshal.dump(existing))
  duplicate_names["users"][" Reader "] = duplicate_names["users"]["reader"]
  _rendered, _output, status = run_dozzle_fixture(YAML.dump(duplicate_names))
  check(failures, !status.success?, "Dozzle accepted duplicate normalized existing identities")
end

check(failures, !ntfy_tasks.empty?, "ntfy managed-user tasks are missing")
check(failures, ntfy_main.include?("managed_users.yml"), "ntfy main tasks do not include managed-user provisioning")
check(failures, ntfy_tasks.include?("ntfy_auth_users") && ntfy_tasks.include?("ntfy_auth_access") &&
                ntfy_tasks.include?("ntfy_auth_tokens"),
      "ntfy does not derive all three declarative provisioning values")
check(failures, ntfy_tasks.include?("Refuse duplicate ntfy identities") &&
                ntfy_tasks.include?("Refuse duplicate ntfy token ownership"),
      "ntfy does not refuse identity and token collisions")
check(failures, ntfy_tasks.include?("vault_ntfy_admin_user") && ntfy_tasks.include?("ntfy_publishers"),
      "ntfy does not separate the administrator and publishers")
check(failures, ntfy_tasks.include?("url_username") && ntfy_tasks.include?("force_basic_auth: true") &&
                ntfy_tasks.include?("vault_managed_ntfy_users"),
      "ntfy does not Basic-authenticate every managed user")
check(failures, ntfy_tasks.include?("Verify managed ntfy declared read access") &&
                ntfy_tasks.include?("Verify managed ntfy declared write access"),
      "ntfy does not verify each declared topic permission")

if command_available?("ansible-playbook") && !ntfy_tasks.empty?
  provisioned, output, status = run_ntfy_fixture
  check(failures, status.success?, "ntfy provisioning fixture failed: #{output.lines.last&.strip}")
  if provisioned
    check(failures, provisioned["users"].split(",") == [
            "admin:#{BCRYPT_A}:admin", "dozzle:#{BCRYPT_A}:user", "reader:#{BCRYPT_B}:user"
          ], "ntfy user provisioning entries differ")
    check(failures, provisioned["access"].split(",") == [
            "dozzle:nas-critical:write-only", "reader:nas-critical:read-only", "reader:private:deny"
          ], "ntfy access provisioning entries differ")
    check(failures, provisioned["tokens"].split(",") == ["dozzle:#{TOKEN_A}", "reader:#{TOKEN_B}"],
          "ntfy token ownership entries differ")
  end

  _provisioned, _output, status = run_ntfy_fixture("vault_ntfy_admin_user" => "reader")
  check(failures, !status.success?, "ntfy accepted an administrator/managed-user collision")
  _provisioned, _output, status = run_ntfy_fixture(
    "ntfy_publishers" => [
      { "name" => "dozzle", "password_hash" => BCRYPT_A, "token" => TOKEN_A },
      { "name" => "beszel", "password_hash" => BCRYPT_A, "token" => TOKEN_A }
    ]
  )
  check(failures, !status.success?, "ntfy accepted duplicate token ownership")
end

validate_policy = read(VALIDATE_POLICY)
check(failures, validate_policy.lines.include?("ruby tests/config_managed_users_test.rb --self-test\n"),
      "policy validation does not run the config managed-user self-test")

unless [[], ["--self-test"]].include?(ARGV)
  abort "usage: config_managed_users_test.rb [--self-test]"
end

if ARGV == ["--self-test"] && failures.empty?
  sources = {
    "dozzle_tasks" => dozzle_tasks,
    "dozzle_main" => dozzle_main,
    "dozzle_template" => dozzle_template,
    "ntfy_tasks" => ntfy_tasks,
    "validate_policy" => validate_policy
  }
  source_fragment_failures(sources).each do |label|
    failures << "self-test baseline rejected #{label}"
  end
  sources.each_key do |source_name|
    relevant = {
      "dozzle_tasks" => "from_yaml",
      "dozzle_main" => "vault_managed_dozzle_users",
      "dozzle_template" => "{% for",
      "ntfy_tasks" => "ntfy_auth_users",
      "validate_policy" => "config_managed_users_test.rb --self-test"
    }.fetch(source_name)
    mutated = sources.merge(source_name => sources.fetch(source_name).sub(relevant, "removed-by-self-test"))
    check(failures, !source_fragment_failures(mutated).empty?,
          "self-test did not reject a #{source_name} contract mutation")
  end
end

if failures.empty?
  puts "Config managed users: Dozzle preservation and ntfy provisioning contracts hold"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} config managed-user violation(s)"
end
