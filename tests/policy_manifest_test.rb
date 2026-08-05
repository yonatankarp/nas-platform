#!/usr/bin/env ruby
# Focused mutation checks for the migration manifest policy.

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)
failures = []
FIXTURE_PATHS = %w[
  .github/workflows/ci.yml
  ansible.cfg
  inventory/group_vars/all/main.yml
  inventory/group_vars/all/vault.yml.example
  requirements.yml
  roles/beszel/meta/argument_specs.yml
  roles/beszel/tasks/main.yml
  roles/beszel/templates/env.j2
  roles/host_prep/meta/argument_specs.yml
  roles/host_prep/tasks/main.yml
  roles/ntfy/meta/argument_specs.yml
  roles/ntfy/tasks/main.yml
  roles/ntfy/templates/env.j2
  roles/preflight/meta/argument_specs.yml
  roles/preflight/tasks/main.yml
  services/beszel/compose.yml
  services/manifest.yml
  services/ntfy/compose.yml
  templates/vault-plain.yml.j2
  tests/integration.sh
  tests/policy_test.rb
].freeze

def mutate_manifest(root)
  path = File.join(root, "services", "manifest.yml")
  manifest = YAML.safe_load_file(path)
  yield manifest
  File.write(path, YAML.dump(manifest))
end

def service(manifest, name)
  manifest.fetch("services").find { |entry| entry["name"] == name }
end

def run_policy
  Dir.mktmpdir("nas-platform-policy-") do |sandbox|
    FIXTURE_PATHS.each do |relative_path|
      source = File.join(ROOT, relative_path)
      destination = File.join(sandbox, relative_path)
      FileUtils.mkdir_p(File.dirname(destination))
      FileUtils.cp(source, destination)
    end
    yield sandbox
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "tests/policy_test.rb", chdir: sandbox
    )
    [stdout + stderr, status]
  end
end

def expect_failure(failures, label, message)
  output, status = run_policy { |root| yield root }
  failures << "#{label}: policy unexpectedly passed" if status.success?
  failures << "#{label}: missing failure message #{message.inspect}" unless output.include?(message)
  failures << "#{label}: emitted a Ruby stack trace" if output.match?(/policy_test\.rb:\d+:in/)
end

def expect_success(failures, label)
  output, status = run_policy { |root| yield root }
  failures << "#{label}: #{output.lines.first&.strip || 'policy failed'}" unless status.success?
end

def write_contract(root, basename, body)
  contract = File.join(root, "tests", "contracts", "#{basename}.sh")
  FileUtils.mkdir_p(File.dirname(contract))
  File.write(contract, body)
  File.chmod(0o755, contract)
end

def register_contract(root, basename)
  harness = File.join(root, "tests", "integration.sh")
  File.open(harness, "a") { |file| file.puts "tests/contracts/#{basename}.sh" }
end

def implement_paperless(root)
  mutate_manifest(root) { |manifest| service(manifest, "paperless-ngx")["status"] = "implemented" }
  compose_dir = File.join(root, "services", "paperless-ngx")
  FileUtils.mkdir_p(compose_dir)
  File.write(File.join(compose_dir, "compose.yml"), <<~YAML)
    ---
    services:
      paperless:
        image: ghcr.io/paperless-ngx/paperless-ngx:2.0@sha256:#{'0' * 64}
        restart: unless-stopped
        logging:
          driver: json-file
          options:
            max-size: 10m
            max-file: "3"
  YAML

  role_dir = File.join(root, "roles", "paperless_ngx")
  FileUtils.mkdir_p(File.join(role_dir, "meta"))
  FileUtils.mkdir_p(File.join(role_dir, "tasks"))
  File.write(File.join(role_dir, "meta", "argument_specs.yml"), <<~YAML)
    ---
    argument_specs:
      main:
        options: {}
  YAML
  File.write(File.join(role_dir, "tasks", "main.yml"), <<~YAML)
    ---
    - name: Provision Paperless
      ansible.builtin.uri:
        url: http://127.0.0.1/paperless/
  YAML

  storage_path = File.join(root, "inventory", "group_vars", "all", "main.yml")
  storage = YAML.safe_load_file(storage_path)
  storage.fetch("nas_storage") << {
    "path" => "{{ nas_docker_root }}/paperless-ngx/data",
    "mode" => "0755",
    "recovery" => "critical"
  }
  File.write(storage_path, YAML.dump(storage))
end

expect_failure(failures, "legacy commit", "legacy_source commit must equal") do |root|
  mutate_manifest(root) { |manifest| manifest.fetch("legacy_source")["commit"] = "deadbeef" }
end

{
  "role" => "wrong_role",
  "legacy_path" => "compose/wrong/compose.yml",
  "tranche" => 99
}.each do |field, value|
  expect_failure(failures, "wrong #{field}", "beszel: #{field} must equal") do |root|
    mutate_manifest(root) { |manifest| service(manifest, "beszel")[field] = value }
  end
end

expect_failure(failures, "ntfy downgrade", "ntfy: status must be implemented or accepted") do |root|
  mutate_manifest(root) { |manifest| service(manifest, "ntfy")["status"] = "planned" }
end

expect_failure(failures, "non-string name", "service name must be a string") do |root|
  mutate_manifest(root) { |manifest| manifest.fetch("services").first["name"] = 7 }
end

expect_failure(failures, "heterogeneous services", "each service manifest entry must be a mapping") do |root|
  mutate_manifest(root) { |manifest| manifest.fetch("services")[0] = "audiobookshelf" }
end

expect_failure(failures, "malformed YAML", "service manifest is malformed") do |root|
  File.write(File.join(root, "services", "manifest.yml"), "services: [unterminated")
end

{
  "duplicate top-level key" => ["\nservices: []\n", "services"],
  "duplicate legacy key" => ["  commit: duplicate\n", "commit"],
  "duplicate service key" => ["    role: duplicate\n", "role"]
}.each do |label, (insertion, key)|
  expect_failure(failures, label, "service manifest contains duplicate mapping key #{key}") do |root|
    path = File.join(root, "services", "manifest.yml")
    body = File.read(path)
    body = case label
           when "duplicate top-level key"
             body + insertion
           when "duplicate legacy key"
             body.sub(/(  commit:.*\n)/, "\\1#{insertion}")
           else
             body.sub(/(    role: audiobookshelf\n)/, "\\1#{insertion}")
           end
    File.write(path, body)
  end
end

expect_failure(failures, "CI omits manifest mutations", "CI must run tests/policy_manifest_test.rb") do |root|
  path = File.join(root, ".github", "workflows", "ci.yml")
  File.write(path, File.read(path).sub(/^\s*ruby tests\/policy_manifest_test\.rb\n/, ""))
end

provisioning_task = <<~YAML
  ---
  - name: Provision an endpoint
    ansible.builtin.uri:
      url: http://127.0.0.1/
YAML

expect_failure(failures, "arbitrary provisioning uri", "ntfy: implemented service has no automated verification") do |root|
  File.write(File.join(root, "roles", "ntfy", "tasks", "main.yml"), provisioning_task)
end

{
  "tagged unrelated uri" => <<~YAML,
    ---
    - name: Verify an unrelated endpoint
      tags: [platform_verify_ntfy]
      ansible.builtin.uri:
        url: http://127.0.0.1/unrelated/
  YAML
  "tagged literal assertion" => <<~YAML,
    ---
    - name: Verify a literal
      tags: [platform_verify_ntfy]
      ansible.builtin.assert:
        that: [true]
  YAML
  "tagged true command" => <<~YAML
    ---
    - name: Verify a no-op command
      tags: [platform_verify_ntfy]
      ansible.builtin.command: /bin/true
  YAML
}.each do |label, tasks|
  expect_failure(failures, label, "ntfy: implemented service has no automated verification") do |root|
    File.write(File.join(root, "roles", "ntfy", "tasks", "main.yml"), tasks)
  end
end

expect_failure(failures, "wrong contract path", "ntfy: implemented service has no automated verification") do |root|
  File.write(File.join(root, "roles", "ntfy", "tasks", "main.yml"), provisioning_task)
  contract = File.join(root, "services", "ntfy", "contract.yml")
  File.write(contract, "#!/bin/sh\nexit 1\n")
  File.chmod(0o755, contract)
end

expect_failure(failures, "empty contract", "ntfy: implemented service has no automated verification") do |root|
  File.write(File.join(root, "roles", "ntfy", "tasks", "main.yml"), provisioning_task)
  contract = File.join(root, "tests", "contracts", "ntfy.sh")
  FileUtils.mkdir_p(File.dirname(contract))
  File.write(contract, "")
  File.chmod(0o755, contract)
end

{
  "echo test" => "#!/bin/sh\necho test\n",
  "exit one" => "#!/bin/sh\nexit 1\n",
  "standalone false" => "#!/bin/sh\nfalse\n"
}.each do |label, body|
  expect_failure(failures, label, "ntfy: implemented service has no automated verification") do |root|
    File.write(File.join(root, "roles", "ntfy", "tasks", "main.yml"), provisioning_task)
    write_contract(root, "ntfy", body)
  end
end

expect_success(failures, "nested verification task") do |root|
  File.write(File.join(root, "roles", "ntfy", "tasks", "main.yml"), <<~YAML)
    ---
    - name: Group verification tasks
      block:
        - name: Verify the application endpoint
          tags: [platform_verify_ntfy]
          ansible.builtin.uri:
            url: http://127.0.0.1/{{ ntfy_port }}/v1/health
  YAML
end

expect_success(failures, "registered variable contract") do |root|
  File.write(File.join(root, "roles", "ntfy", "tasks", "main.yml"), provisioning_task)
  write_contract(root, "ntfy", <<~'SH')
    #!/bin/sh
    endpoint=http://127.0.0.1/ntfy/health
    probe() {
      curl --fail "$endpoint"
    }
    probe
  SH
  register_contract(root, "ntfy")
end

expect_failure(failures, "unregistered contract", "ntfy: implemented service has no automated verification") do |root|
  File.write(File.join(root, "roles", "ntfy", "tasks", "main.yml"), provisioning_task)
  write_contract(root, "ntfy", "#!/bin/sh\nendpoint=/ntfy/health\ncurl --fail \"$endpoint\"\n")
end

expect_failure(failures, "contract syntax error", "ntfy: implemented service has no automated verification") do |root|
  File.write(File.join(root, "roles", "ntfy", "tasks", "main.yml"), provisioning_task)
  write_contract(root, "ntfy", "#!/bin/sh\nif then\ncurl --fail http://127.0.0.1/ntfy\n")
  register_contract(root, "ntfy")
end

expect_failure(failures, "symlink contract", "ntfy: implemented service has no automated verification") do |root|
  File.write(File.join(root, "roles", "ntfy", "tasks", "main.yml"), provisioning_task)
  contracts = File.join(root, "tests", "contracts")
  FileUtils.mkdir_p(contracts)
  target = File.join(contracts, "shared.sh")
  File.write(target, "#!/bin/sh\ntrue\n")
  File.chmod(0o755, target)
  File.symlink("shared.sh", File.join(contracts, "ntfy.sh"))
  register_contract(root, "ntfy")
end

expect_success(failures, "paperless contract alias") do |root|
  implement_paperless(root)
  write_contract(root, "paperless", <<~'SH')
    #!/bin/sh
    response=$(curl --silent http://127.0.0.1/paperless/api/)
    test -n "$response"
  SH
  register_contract(root, "paperless")
end

expect_failure(failures, "paperless service-name contract", "paperless-ngx: implemented service has no automated verification") do |root|
  implement_paperless(root)
  write_contract(root, "paperless-ngx", <<~'SH')
    #!/bin/sh
    response=$(curl --silent http://127.0.0.1/paperless/api/)
    test -n "$response"
  SH
  register_contract(root, "paperless-ngx")
end

expect_failure(failures, "symlink compose", "ntfy: compose.yml must be a regular file within its service root") do |root|
  path = File.join(root, "services", "ntfy", "compose.yml")
  File.unlink(path)
  File.symlink("../beszel/compose.yml", path)
end

expect_failure(failures, "symlink role directory", "ntfy: role must be a real directory within roles") do |root|
  path = File.join(root, "roles", "ntfy")
  FileUtils.rm_r(path)
  File.symlink("beszel", path)
end

expect_failure(failures, "symlink role meta", "ntfy: argument_specs.yml must be a regular file within its role root") do |root|
  path = File.join(root, "roles", "ntfy", "meta", "argument_specs.yml")
  File.unlink(path)
  File.symlink("../../beszel/meta/argument_specs.yml", path)
end

expect_failure(failures, "symlink role tasks", "ntfy: tasks/main.yml must be a regular file within its role root") do |root|
  path = File.join(root, "roles", "ntfy", "tasks", "main.yml")
  File.unlink(path)
  File.symlink("../../beszel/tasks/main.yml", path)
end

if failures.empty?
  puts "policy manifest: all mutation checks hold"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} policy manifest regression(s)"
end
