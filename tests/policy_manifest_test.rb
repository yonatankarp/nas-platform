#!/usr/bin/env ruby
# Focused mutation checks for the migration manifest policy.

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)
failures = []

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
    FileUtils.cp_r("#{ROOT}/.", sandbox)
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

provisioning_task = <<~YAML
  ---
  - name: Provision an endpoint
    ansible.builtin.uri:
      url: http://127.0.0.1/
YAML

expect_failure(failures, "arbitrary provisioning uri", "ntfy: implemented service has no automated verification") do |root|
  File.write(File.join(root, "roles", "ntfy", "tasks", "main.yml"), provisioning_task)
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

expect_success(failures, "nested verification task") do |root|
  File.write(File.join(root, "roles", "ntfy", "tasks", "main.yml"), <<~YAML)
    ---
    - name: Verify through a nested block
      block:
        - name: Verify the application endpoint
          ansible.builtin.uri:
            url: http://127.0.0.1/
  YAML
end

expect_success(failures, "executable assertion contract") do |root|
  File.write(File.join(root, "roles", "ntfy", "tasks", "main.yml"), provisioning_task)
  contract = File.join(root, "tests", "contracts", "ntfy.sh")
  FileUtils.mkdir_p(File.dirname(contract))
  File.write(contract, "#!/bin/sh\nset -eu\ncurl --fail http://127.0.0.1/health\n")
  File.chmod(0o755, contract)
end

if failures.empty?
  puts "policy manifest: all mutation checks hold"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} policy manifest regression(s)"
end
