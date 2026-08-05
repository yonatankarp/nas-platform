#!/usr/bin/env ruby
# Focused mutation checks for the migration manifest policy.

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"
require_relative "policy_support"

include PolicySupport

ROOT = File.expand_path("..", __dir__)
failures = []
BASE_FIXTURE_PATHS = %w[
  .github/workflows/ci.yml
  ansible.cfg
  inventory/group_vars/all/main.yml
  inventory/group_vars/all/vault.yml.example
  requirements.yml
  site.yml
  roles/host_prep/meta/argument_specs.yml
  roles/host_prep/tasks/main.yml
  roles/deployment_bundle/defaults/main.yml
  roles/deployment_bundle/meta/argument_specs.yml
  roles/deployment_bundle/tasks/controller.yml
  roles/deployment_bundle/tasks/main.yml
  roles/deployment_bundle/tasks/target.yml
  roles/deployment_bundle/templates/manifest.yml.j2
  roles/preflight/meta/argument_specs.yml
  roles/preflight/tasks/main.yml
  services/manifest.yml
  templates/vault-plain.yml.j2
  tests/contracts/registry.yml
  tests/integration.sh
  tests/policy_test.rb
  tests/policy_support.rb
  tests/run_contracts.rb
  tests/verify_deployment_manifest.rb
  tests/validate-policy.sh
].freeze
EXPECTED_FIXTURE_ROLES = {
  "audiobookshelf" => "audiobookshelf", "beszel" => "beszel", "dozzle" => "dozzle",
  "immich" => "immich", "jellyfin" => "jellyfin", "komga" => "komga", "ntfy" => "ntfy",
  "paperless-ngx" => "paperless_ngx", "tinymediamanager" => "tinymediamanager"
}.freeze

def fixture_paths(root = ROOT)
  paths = BASE_FIXTURE_PATHS.dup
  manifest_path = File.join(root, "services", "manifest.yml")
  registry_path = File.join(root, "tests", "contracts", "registry.yml")
  raise "duplicate manifest fixture key" unless duplicate_yaml_keys(Psych.parse_stream(File.read(manifest_path))).empty?
  raise "duplicate registry fixture key" unless duplicate_yaml_keys(Psych.parse_stream(File.read(registry_path))).empty?

  manifest = YAML.safe_load_file(manifest_path)
  manifest.fetch("services").each do |entry|
    next unless %w[implemented accepted].include?(entry.fetch("status"))

    name = entry.fetch("name")
    role = entry.fetch("role")
    raise "unsafe manifest fixture identity" unless EXPECTED_FIXTURE_ROLES[name] == role

    paths << File.join("services", name, "compose.yml")
    role_root = File.join("roles", role)
    paths << File.join(role_root, "meta", "argument_specs.yml")
    paths << File.join(role_root, "tasks", "main.yml")
    env_template = File.join(role_root, "templates", "env.j2")
    paths << env_template if File.file?(File.join(root, env_template))
  end

  statuses = manifest.fetch("services").to_h { |entry| [entry.fetch("name"), entry.fetch("status")] }
  registry = YAML.safe_load_file(registry_path)
  registry.fetch("contracts").each do |entry|
    raise "invalid registry fixture entry" unless entry.is_a?(Hash) && entry.keys.sort == %w[path service]

    service_name = entry.fetch("service")
    basename = contract_basename(service_name)
    expected_path = "tests/contracts/#{basename}.sh"
    raise "unsafe registry fixture path" unless %w[implemented accepted].include?(statuses[service_name]) &&
                                                entry.fetch("path") == expected_path

    paths << expected_path
  end
  paths.uniq
end

def copy_fixture(source_root, sandbox)
  planned = fixture_paths(source_root).map do |relative_path|
    clean = Pathname.new(relative_path).cleanpath.to_s
    raise "unsafe fixture path" unless clean == relative_path && !Pathname.new(clean).absolute? &&
                                       !Pathname.new(clean).each_filename.include?("..")

    source = File.expand_path(clean, source_root)
    destination = File.expand_path(clean, sandbox)
    source_prefix = File.expand_path(source_root) + File::SEPARATOR
    sandbox_prefix = File.expand_path(sandbox) + File::SEPARATOR
    raise "unsafe fixture source" unless source.start_with?(source_prefix) && owned_file?(source, source_root)
    raise "unsafe fixture destination" unless destination.start_with?(sandbox_prefix)

    [source, destination]
  end

  planned.each do |source, destination|
    FileUtils.mkdir_p(File.dirname(destination))
    FileUtils.cp(source, destination)
  end
end

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
    copy_fixture(ROOT, sandbox)
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

def expect_fixture_identity_rejection(failures, label, service_entry)
  Dir.mktmpdir("nas-platform-fixture-source-") do |parent|
    source = File.join(parent, "source")
    sandbox = File.join(parent, "sandbox")
    FileUtils.mkdir_p(File.join(source, "services"))
    FileUtils.mkdir_p(File.join(source, "tests", "contracts"))
    File.write(File.join(source, "services", "manifest.yml"), YAML.dump("services" => [service_entry]))
    File.write(File.join(source, "tests", "contracts", "registry.yml"), YAML.dump("contracts" => []))
    source_sentinel = File.join(parent, "source-sentinel")
    sandbox_sentinel = File.join(parent, "sandbox-sentinel")
    File.write(source_sentinel, "SOURCE_SAFE")
    File.write(sandbox_sentinel, "SANDBOX_SAFE")

    error = begin
      copy_fixture(source, sandbox)
      nil
    rescue StandardError => e
      e
    end
    failures << "#{label}: fixture identity was not rejected clearly" unless error&.message&.include?("unsafe manifest fixture identity")
    failures << "#{label}: source sentinel changed" unless File.read(source_sentinel) == "SOURCE_SAFE"
    failures << "#{label}: sandbox sentinel changed" unless File.read(sandbox_sentinel) == "SANDBOX_SAFE"
  end
end

expect_fixture_identity_rejection(
  failures, "traversal service name",
  { "name" => "../../source-sentinel", "role" => "ntfy", "status" => "implemented" }
)
expect_fixture_identity_rejection(
  failures, "traversal role",
  { "name" => "ntfy", "role" => "../../sandbox-sentinel", "status" => "implemented" }
)

def write_contract(root, basename, body)
  contract = File.join(root, "tests", "contracts", "#{basename}.sh")
  FileUtils.mkdir_p(File.dirname(contract))
  File.write(contract, body)
  File.chmod(0o755, contract)
end

def register_contract(root, basename)
  registry = File.join(root, "tests", "contracts", "registry.yml")
  FileUtils.mkdir_p(File.dirname(registry))
  File.write(registry, YAML.dump(
    "contracts" => [{ "service" => basename == "paperless" ? "paperless-ngx" : basename,
                       "path" => "tests/contracts/#{basename}.sh" }]
  ))
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

expect_failure(failures, "CI bypasses policy entrypoint", "CI must run tests/validate-policy.sh") do |root|
  path = File.join(root, ".github", "workflows", "ci.yml")
  File.write(path, File.read(path).sub("tests/validate-policy.sh", "ruby tests/policy_test.rb"))
end

expect_failure(failures, "integration omits contract execution", "integration must execute registered contracts") do |root|
  path = File.join(root, "tests", "integration.sh")
  File.write(path, File.read(path).sub(/^\s*ruby \/repo\/tests\/run_contracts\.rb --execute\n/, ""))
end

expect_failure(failures, "integration omits contract ABI", "integration must set the contract environment ABI") do |root|
  path = File.join(root, "tests", "integration.sh")
  File.write(path, File.read(path).sub(/^\s*PLATFORM_REPORT_ROOT=.*\n/, ""))
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
  "tagged uri body mention" => <<~YAML,
    ---
    - name: Verify an unrelated endpoint with service text
      tags: [platform_verify_ntfy]
      ansible.builtin.uri:
        url: http://127.0.0.1/unrelated/
        body: ntfy
        status_code: [200]
  YAML
  "tagged literal assertion" => <<~YAML,
    ---
    - name: Verify a literal
      tags: [platform_verify_ntfy]
      ansible.builtin.assert:
        that: [true]
  YAML
  "tagged constant service assertion" => <<~YAML,
    ---
    - name: Verify a constant expression
      tags: [platform_verify_ntfy]
      ansible.builtin.assert:
        that: ["'ntfy' == 'ntfy'"]
  YAML
  "tagged undefined service assertion" => <<~YAML,
    ---
    - name: Verify an undefined result
      tags: [platform_verify_ntfy]
      ansible.builtin.assert:
        that: ["ntfy_missing_result.status == 200"]
  YAML
  "tagged true command" => <<~YAML,
    ---
    - name: Verify a no-op command
      tags: [platform_verify_ntfy]
      ansible.builtin.command: /bin/true
  YAML
  "tagged service command" => <<~YAML,
    ---
    - name: Verify command output
      tags: [platform_verify_ntfy]
      ansible.builtin.command: echo ntfy
  YAML
  "assert from command register" => <<~YAML,
    ---
    - name: Produce a fake result
      ansible.builtin.command: echo ntfy
      register: ntfy_result
    - name: Verify fake result
      tags: [platform_verify_ntfy]
      ansible.builtin.assert:
        that: ["ntfy_result.stdout == 'ntfy'"]
  YAML
  "assert self comparison" => <<~YAML
    ---
    - name: Probe ntfy
      ansible.builtin.uri:
        url: http://127.0.0.1/{{ ntfy_port }}/health
        status_code: [200]
      register: ntfy_result
    - name: Verify a tautology
      tags: [platform_verify_ntfy]
      ansible.builtin.assert:
        that: ["ntfy_result.status == ntfy_result.status"]
  YAML
}.each do |label, tasks|
  expect_failure(failures, label, "ntfy: implemented service has no automated verification") do |root|
    File.write(File.join(root, "roles", "ntfy", "tasks", "main.yml"), tasks)
  end
end

expect_success(failures, "assert from registered URI result") do |root|
  File.write(File.join(root, "roles", "ntfy", "tasks", "main.yml"), <<~YAML)
    ---
    - name: Probe ntfy
      ansible.builtin.uri:
        url: http://127.0.0.1/{{ ntfy_port }}/health
        status_code: [200]
      register: ntfy_result
    - name: Verify the observed status
      tags: [platform_verify_ntfy]
      ansible.builtin.assert:
        that: ["ntfy_result.status == 200"]
  YAML
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
            status_code: [200]
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

{
  "assignment registration spoof" => ["tests/integration.sh", "contract=tests/contracts/ntfy.sh\n"],
  "echo registration spoof" => ["tests/integration.sh", "echo tests/contracts/ntfy.sh\n"],
  "YAML name registration spoof" => [".github/workflows/ci.yml", "\nname: tests/contracts/ntfy.sh\n"]
}.each do |label, (relative_harness, registration)|
  expect_failure(failures, label, "ntfy: implemented service has no automated verification") do |root|
    File.write(File.join(root, "roles", "ntfy", "tasks", "main.yml"), provisioning_task)
    write_contract(root, "ntfy", "#!/bin/sh\ntrue\n")
    harness = File.join(root, relative_harness)
    File.open(harness, "a") { |file| file.write(registration) }
  end
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

expect_failure(failures, "dirty controller enabled by default",
               "deployment bundle must refuse dirty controller sources by default") do |root|
  path = File.join(root, "roles", "deployment_bundle", "defaults", "main.yml")
  defaults = YAML.safe_load_file(path)
  defaults["deployment_bundle_allow_dirty_controller"] = true
  File.write(path, YAML.dump(defaults))
end

expect_failure(failures, "untracked controller inspection removed",
               "deployment bundle must inspect the whole tracked and untracked controller checkout") do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "controller.yml")
  tasks = File.read(path).sub("      - --untracked-files=all\n", "")
  File.write(path, tasks)
end

expect_failure(failures, "controller inspection narrowed by pathspec",
               "deployment bundle must inspect the whole tracked and untracked controller checkout") do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "controller.yml")
  tasks = File.read(path).sub(
    "      - --untracked-files=all\n",
    "      - --untracked-files=all\n      - --\n      - services\n"
  )
  File.write(path, tasks)
end

expect_failure(failures, "dirty refusal made run once",
               "dirty controller refusal must be evaluated independently for every target host") do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "controller.yml")
  tasks = File.read(path).sub(
    "- name: Require committed controller bundle sources\n",
    "- name: Require committed controller bundle sources\n  run_once: true\n"
  )
  File.write(path, tasks)
end

expect_failure(failures, "fresh-root probe regressed to deployment root",
               "fresh-install preflight must probe the existing validated nas_docker_root") do |root|
  path = File.join(root, "roles", "preflight", "tasks", "main.yml")
  tasks = File.read(path).gsub(
    "{{ nas_docker_root }}/.nas-platform-preflight-probe",
    "{{ platform_deploy_root }}/.preflight-probe"
  )
  File.write(path, tasks)
end

expect_failure(failures, "release mode comparison removed",
               "immutable release comparison must include stat.S_IMODE") do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "main.yml")
  File.write(path, File.read(path).gsub("stat.S_IMODE", "stat.filemode"))
end

expect_failure(failures, "deployment sha unquoted",
               "deployment manifest must quote git_sha as a YAML string") do |root|
  path = File.join(root, "roles", "deployment_bundle", "templates", "manifest.yml.j2")
  File.write(path, File.read(path).gsub("platform_release_id | to_json", "platform_release_id"))
end

expect_failure(failures, "target lstat replaced by following stat",
               "target validator must use os.lstat for symlink-safe canonical containment") do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "target.yml")
  File.write(path, File.read(path).gsub("os.lstat", "os.stat"))
end

expect_failure(failures, "root ancestor walk removed",
               "target validator must lstat every existing ancestor from filesystem root to nas_docker_root") do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "target.yml")
  File.write(path, File.read(path).gsub("root_relative_parts", "unchecked_root_parts"))
end

expect_failure(failures, "preflight probe leaf unguarded",
               "target validator must guard the exact preflight probe leaf") do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "target.yml")
  body = File.read(path).gsub("      - \"{{ nas_docker_root }}/.nas-platform-preflight-probe\"\n", "")
  File.write(path, body)
end

expect_failure(failures, "preflight target validation removed",
               "target containment must be validated before preflight can mutate the target") do |root|
  path = File.join(root, "site.yml")
  site = YAML.safe_load_file(path)
  site.first["pre_tasks"].reject! do |task|
    task.dig("ansible.builtin.include_role", "tasks_from") == "target"
  end
  File.write(path, YAML.dump(site))
end

expect_failure(failures, "manifest component validation removed",
               "deployment bundle must validate manifest service path components") do |root|
  path = File.join(root, "roles", "deployment_bundle", "tasks", "main.yml")
  tasks = YAML.safe_load_file(path)
  tasks.reject! { |task| task["name"] == "Validate manifest service path components" }
  File.write(path, YAML.dump(tasks))
end

expect_failure(failures, "platform image merge removed",
               "deployment manifest images must merge canonical and platform Compose services") do |root|
  path = File.join(root, "roles", "deployment_bundle", "templates", "manifest.yml.j2")
  File.write(path, File.read(path).gsub("platform_compose", "override_compose"))
end

expect_failure(failures, "platform override redefines image",
               "platform overrides must not redefine image keys") do |root|
  path = File.join(root, "services", "beszel", "compose.integration.yml")
  File.write(path, <<~YAML)
    ---
    services:
      agent:
        image: example.invalid/beszel-agent:1@sha256:#{'0' * 64}
  YAML
end

if failures.empty?
  puts "policy manifest: all mutation checks hold"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} policy manifest regression(s)"
end
