#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "socket"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)
ROLE = File.join(ROOT, "roles/komga/tasks/main.yml")
COMPOSE = File.join(ROOT, "services/komga/compose.yml")
ARGUMENT_SPECS = File.join(ROOT, "roles/komga/meta/argument_specs.yml")
CONTRACT = File.join(ROOT, "tests/contracts/komga.sh")
# The Mac wrapper and the Mac seed hook are both shared across services now: one
# runner resolves every contract through tests/contracts/registry.yml, and one
# hook seeds every service from a table of phases. The properties asserted below
# are unchanged, they just live in the shared files.
MAC_CONTRACT_WRAPPER = File.join(ROOT, "tests/mac/run-contract.sh")
SEED_HOOK = File.join(ROOT, "tests/mac/hooks/fixtures-seed/00-services.sh")
INTEGRATION_HARNESS = File.join(ROOT, "tests/integration.sh")
DEFAULTS = YAML.safe_load_file(File.join(ROOT, "roles/komga/defaults/main.yml"), aliases: false)
START_TASK = "List Komga libraries for reconciliation"
END_TASK = "Require exact reconciled Komga library"

def task_name(task)
  task.fetch("name", "")
end

def deep_copy(value)
  Marshal.load(Marshal.dump(value))
end

def health_task(tasks)
  matches = tasks.each_with_index.select do |task, _index|
    task_name(task) == "Wait for Komga application health"
  end
  raise "application health readiness task must occur exactly once" unless matches.length == 1

  matches.first
end

def validate_health_gating!(compose, tasks, defaults, argument_specs)
  service = compose.fetch("services").fetch("komga")
  expected_test = [
    "CMD-SHELL",
    "test \"$$(/usr/bin/curl --fail --silent --show-error " \
      "http://127.0.0.1:25600/actuator/health)\" = '{\"status\":\"UP\"}'"
  ]
  raise "Komga application healthcheck is absent or weakened" unless
    service["healthcheck"] == {
      "test" => expected_test,
      "interval" => "30s",
      "timeout" => "10s",
      "retries" => 5,
      "start_period" => "60s"
    }

  raise "Komga application health timing defaults differ" unless
    defaults.values_at("komga_health_retries", "komga_health_delay") == [60, 3]
  options = argument_specs.dig("argument_specs", "main", "options")
  raise "Komga application health timing arguments are undeclared" unless
    options&.slice("komga_health_retries", "komga_health_delay") == {
      "komga_health_retries" => { "type" => "int", "required" => false },
      "komga_health_delay" => { "type" => "int", "required" => false }
    }

  readiness, readiness_index = health_task(tasks)
  deploy_index = tasks.index { |task| task_name(task) == "Deploy Komga" }
  claim_index = tasks.index { |task| task_name(task) == "Read Komga claim status" }
  raise "Komga readiness does not gate claim reconciliation" unless
    deploy_index && claim_index && deploy_index < readiness_index && readiness_index < claim_index
  raise "Komga readiness request differs" unless readiness["ansible.builtin.uri"] == {
    "url" => "{{ komga_api }}/actuator/health",
    "method" => "GET",
    "status_code" => [200],
    "return_content" => true
  }
  raise "Komga readiness status gate differs" unless
    readiness.values_at(
      "register", "until", "retries", "delay", "changed_when", "check_mode"
    ) == [
      "komga_health",
      [
        "komga_health.json | default(none) is mapping",
        "komga_health.json.status | default(none) == 'UP'"
      ],
      "{{ komga_health_retries }}",
      "{{ komga_health_delay }}",
      false,
      false
    ]
end

def health_mutation_rejected!(compose, tasks, defaults, argument_specs, label)
  validate_health_gating!(compose, tasks, defaults, argument_specs)
rescue KeyError, RuntimeError
  return
else
  raise "#{label} health mutation was not rejected"
end

def validate_runtime_health_paths!(sources)
  contract, wrapper, seed_hook, integration = sources
  base_policy = [
    "  base)",
    "    PLATFORM_KOMGA_CONTAINER=komga",
    "    PLATFORM_KOMGA_DOCKER_HEALTH_REQUIRED=true"
  ].join("\n")
  mac_policy = [
    "  mac-managed)",
    '    : "${PLATFORM_PROJECT_NAME:?PLATFORM_PROJECT_NAME is required for managed Mac Komga}"',
    '    PLATFORM_KOMGA_CONTAINER=$PLATFORM_PROJECT_NAME-komga',
    "    PLATFORM_KOMGA_DOCKER_HEALTH_REQUIRED=true"
  ].join("\n")
  raise "Komga runtime contexts do not derive exact container health policies" unless
    contract.include?(base_policy) && contract.include?(mac_policy) &&
      contract.scan(/PLATFORM_KOMGA_CONTAINER=/).length == 2 &&
      !contract.include?('[ -z "${PLATFORM_KOMGA_CONTAINER:-}" ]') &&
      contract.include?('DOCKER_HEALTH_REQUIRED = { "true" => true, "false" => false }.fetch(')
  raise "integration Komga contexts do not allow only base" unless
    contract.include?(': "${PLATFORM_KOMGA_RUNTIME_CONTEXT:=base}"') &&
      contract.include?('base) ;;') &&
      contract.include?("*) fail_contract 'integration Komga runtime context differs' ;;")

  managed_health = <<~'RUBY'.strip
    if DOCKER_HEALTH_REQUIRED
      wait_for_container_health
    else
      require_absent_container_healthcheck
    end
    wait_for_api
  RUBY
  raise "Komga health gates are not selected before actuator readiness" unless
    contract.include?(managed_health)
  raise "managed Komga runtime no longer requires Docker healthy" unless
    contract.include?('"{{.State.Health.Status}}", KOMGA_CONTAINER') &&
      contract.include?('status.success? && stdout.strip == "healthy"')
  raise "Komga runtime cannot prove an absent Docker healthcheck" unless
    contract.include?('"{{if .State.Health}}present{{else}}absent{{end}}", KOMGA_CONTAINER') &&
      contract.include?('status.success? && stdout.strip == "absent"')
  raise "actuator readiness no longer requires an exact UP mapping" unless
    contract.include?('payload.is_a?(Hash) && payload["status"] == "UP"')

  auth_index = contract.index('request("get", "/api/v2/users/me"')
  gate_index = contract.index(managed_health)
  raise "Komga health gates no longer precede authenticated assertions" unless
    gate_index && auth_index && gate_index < auth_index
  raise "Komga invoking harnesses do not bind exact runtime contexts" unless
    integration.include?('PLATFORM_KOMGA_RUNTIME_CONTEXT=base') &&
      wrapper.include?('if [ "${PLATFORM_KIND:-}" = integration ]; then') &&
      wrapper.include?('PLATFORM_KOMGA_RUNTIME_CONTEXT=base') &&
      wrapper.include?('PLATFORM_KOMGA_RUNTIME_CONTEXT=mac-managed') &&
      wrapper.include?('mac_contract_path=$(mac_registry_contract_path "$mac_service")') &&
      wrapper.include?('exec "$mac_repo_dir/$mac_contract_path" "$@"') &&
      seed_hook.scan(" komga:seed ").length == 1
end

def runtime_health_mutation_rejected!(sources, label)
  validate_runtime_health_paths!(sources)
rescue RuntimeError
  return
else
  raise "#{label} runtime-health mutation was not rejected"
end

def library_tasks
  tasks = YAML.safe_load_file(ROLE, aliases: false)
  first = tasks.index { |task| task_name(task) == START_TASK }
  last = tasks.index { |task| task_name(task) == END_TASK }
  raise "Komga library task slice is unavailable" unless first && last && first <= last

  tasks[first..last].each do |task|
    task["ansible.builtin.include_tasks"] = File.join(
      ROOT, "roles/komga/tasks/managed_users.yml"
    ) if task["ansible.builtin.include_tasks"] == "managed_users.yml"
  end
end

def managed_library(id:, name: "Comics", root: "/data", settings: {})
  DEFAULTS.fetch("komga_library_settings").merge(
    "id" => id, "name" => name, "root" => root, "unavailable" => false
  ).merge(settings)
end

def with_http_service(libraries, users: [], fail_after_apply: false)
  server = TCPServer.new("127.0.0.1", 0)
  requests = []
  stopped = false
  error = nil
  failed_patch = false
  thread = Thread.new do
    until stopped
      next unless IO.select([server], nil, nil, 0.05)

      client = server.accept
      method, target, = client.gets.to_s.strip.split(" ", 3)
      headers = {}
      while (line = client.gets)
        line = line.chomp
        break if line == "\r" || line.empty?

        key, value = line.split(":", 2)
        headers[key.downcase] = value.to_s.strip
      end
      body = client.read(headers.fetch("content-length", "0").to_i)
      request = { "method" => method, "target" => target,
                  "json" => body.empty? ? nil : JSON.parse(body) }
      requests << request
      status = 500
      response = { "error" => "unexpected request" }
      case [method, target]
      when ["GET", "/api/v1/libraries"]
        status = 200
        response = libraries
      when ["POST", "/api/v1/libraries"]
        status = 200
        libraries << request.fetch("json").merge("id" => "created-library", "unavailable" => false)
        response = libraries.last
      when ["GET", "/api/v2/users"]
        status = 200
        response = users
      when ["POST", "/api/v2/users"]
        status = 201
        users << request.fetch("json").merge("id" => "created-user", "roles" => ["USER", *request.fetch("json").fetch("roles")])
        response = users.last
      else
        if method == "PATCH" && target.match?(%r{\A/api/v1/libraries/[A-Za-z0-9_.%:-]+\z})
          id = target.split("/").last
          library = libraries.find { |entry| entry.is_a?(Hash) && entry["id"] == id }
          if library
            library.merge!(request.fetch("json"))
            if fail_after_apply && !failed_patch
              failed_patch = true
              status = 500
              response = { "error" => "response lost after commit" }
            else
              status = 204
              response = nil
            end
          end
        end
      end
      payload = response.nil? ? "" : JSON.generate(response)
      reason = { 200 => "OK", 204 => "No Content", 500 => "Error" }.fetch(status)
      client.write("HTTP/1.1 #{status} #{reason}\r\n")
      client.write("Content-Type: application/json\r\n") unless payload.empty?
      client.write("Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      client.close
    end
  rescue IOError, Errno::EBADF
    nil
  rescue StandardError => caught
    error = caught
  end
  yield server.addr.fetch(1), requests
ensure
  stopped = true
  server&.close
  thread&.join
  raise error if error
end

def run_tasks(port, arguments = [], managed_users: [])
  Dir.mktmpdir("komga-library-reconciliation-") do |directory|
    playbook = File.join(directory, "playbook.yml")
    variables = DEFAULTS.merge(
      "komga_api" => "http://127.0.0.1:#{port}",
      "vault_komga_admin_email" => "admin@example.invalid",
      "vault_komga_admin_password" => "admin-secret",
      "komga_claim_status" => { "json" => { "isClaimed" => true } },
      "vault_managed_komga_users" => managed_users
    )
    File.write(
      playbook,
      YAML.dump([{ "hosts" => "localhost", "gather_facts" => false,
                   "vars" => variables, "tasks" => library_tasks }]),
      mode: "w", perm: 0o600
    )
    Open3.capture3(
      { "ANSIBLE_NOCOLOR" => "1" }, "ansible-playbook", "-i", "localhost,", "-c", "local",
      playbook, *arguments, chdir: ROOT
    )
  end
end

def mutations(requests)
  requests.select { |request| %w[POST PATCH DELETE].include?(request.fetch("method")) }
end

failures = []

main_tasks = YAML.safe_load_file(ROLE, aliases: false)
compose = YAML.safe_load_file(COMPOSE, aliases: true)
argument_specs = YAML.safe_load_file(ARGUMENT_SPECS, aliases: false)
validate_health_gating!(compose, main_tasks, DEFAULTS, argument_specs)

contract = File.read(CONTRACT)
mac_contract_wrapper = File.read(MAC_CONTRACT_WRAPPER)
seed_hook = File.read(SEED_HOOK)
runtime_sources = [
  contract,
  mac_contract_wrapper,
  seed_hook,
  File.read(INTEGRATION_HARNESS)
]
validate_runtime_health_paths!(runtime_sources)

project_derived_base = runtime_sources.dup
project_derived_base[0] = contract.sub(
  "PLATFORM_KOMGA_CONTAINER=komga",
  "PLATFORM_KOMGA_CONTAINER=$PLATFORM_PROJECT_NAME-komga"
)
runtime_health_mutation_rejected!(project_derived_base, "project-derived base container")

managed_skips_health = runtime_sources.dup
managed_skips_health[0] = contract.sub(
  "PLATFORM_KOMGA_DOCKER_HEALTH_REQUIRED=true",
  "PLATFORM_KOMGA_DOCKER_HEALTH_REQUIRED=false"
)
runtime_health_mutation_rejected!(managed_skips_health, "managed Docker health bypass")

wrong_integration_context = runtime_sources.dup
wrong_integration_context[3] = runtime_sources.fetch(3).sub(
  "PLATFORM_KOMGA_RUNTIME_CONTEXT=base",
  "PLATFORM_KOMGA_RUNTIME_CONTEXT=mac-managed"
)
runtime_health_mutation_rejected!(wrong_integration_context, "integration context")

integration_accepts_mac = runtime_sources.dup
integration_accepts_mac[0] = contract.sub("base) ;;", "base|mac-managed) ;;")
runtime_health_mutation_rejected!(integration_accepts_mac, "integration Mac context")

integration_wrapper_uses_mac = runtime_sources.dup
integration_wrapper_base = [
  'if [ "${PLATFORM_KIND:-}" = integration ]; then',
  "      PLATFORM_KOMGA_RUNTIME_CONTEXT=base"
].join("\n")
integration_wrapper_uses_mac[1] = mac_contract_wrapper.sub(
  integration_wrapper_base,
  integration_wrapper_base.sub("=base", "=mac-managed")
)
runtime_health_mutation_rejected!(integration_wrapper_uses_mac, "integration wrapper context")

wrong_seed_invocation = seed_hook.sub(" komga:seed ", " komga:run ")
wrong_seed_invocation_sources = runtime_sources.dup
wrong_seed_invocation_sources[2] = wrong_seed_invocation
runtime_health_mutation_rejected!(wrong_seed_invocation_sources, "seed fixture invocation")

missing_healthcheck = deep_copy(compose)
missing_healthcheck.fetch("services").fetch("komga").delete("healthcheck")
health_mutation_rejected!(missing_healthcheck, main_tasks, DEFAULTS, argument_specs, "absent")

weakened_healthcheck = deep_copy(compose)
weakened_healthcheck.dig("services", "komga", "healthcheck")["test"] = [
  "CMD", "/usr/bin/curl", "--fail", "http://127.0.0.1:25600/actuator/health"
]
health_mutation_rejected!(weakened_healthcheck, main_tasks, DEFAULTS, argument_specs, "weakened")

wrong_endpoint = deep_copy(compose)
wrong_endpoint.dig("services", "komga", "healthcheck", "test")[1] =
  wrong_endpoint.dig("services", "komga", "healthcheck", "test", 1).sub(
    "/actuator/health", "/api/v1/claim"
  )
health_mutation_rejected!(wrong_endpoint, main_tasks, DEFAULTS, argument_specs, "wrong endpoint")

late_readiness = deep_copy(main_tasks)
readiness, readiness_index = health_task(late_readiness)
late_readiness.delete_at(readiness_index)
claim_index = late_readiness.index { |task| task_name(task) == "Read Komga claim status" }
late_readiness.insert(claim_index + 1, readiness)
health_mutation_rejected!(compose, late_readiness, DEFAULTS, argument_specs, "late readiness")

main_names = main_tasks.map { |task| task_name(task) }
preflight_index = main_names.index("Refuse ambiguous Komga library candidates")
user_index = main_names.index("Reconcile managed Komga users")
library_mutation_index = main_names.index("Create the managed Komga library")
failures << "complete library preflight does not precede all user/library mutation" unless
  preflight_index && user_index && library_mutation_index &&
    preflight_index < user_index && user_index < library_mutation_index

unless ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
         File.executable?(File.join(directory, "ansible-playbook"))
       end
  abort "ansible-playbook is required for Komga library behavior fixtures"
end

unrelated = managed_library(id: "unrelated", name: "Reference", root: "/reference")
libraries = [managed_library(id: "legacy-library", name: "Books", root: "/data/").merge(
  "legacySentinel" => "preserve-me"
), unrelated.dup]
with_http_service(libraries) do |port, requests|
  stdout, stderr, status = run_tasks(port)
  failures << "path adoption failed: #{(stdout + stderr).lines.last(12).join}" unless status.success?
  patch = mutations(requests).fetch(0, nil)
  failures << "path adoption did not use one in-place PATCH" unless
    mutations(requests).length == 1 && patch&.fetch("target") == "/api/v1/libraries/legacy-library"
  failures << "path adoption body is not limited to canonical name/root drift" unless
    patch&.fetch("json") == { "name" => "Comics", "root" => "/data" }
  failures << "path adoption overwrote an unowned library setting" unless
    libraries.first["legacySentinel"] == "preserve-me"
  failures << "path adoption changed the library identifier" unless libraries.first["id"] == "legacy-library"
  failures << "path adoption did not preserve the unrelated library" unless libraries.last == unrelated

  requests.clear
  _stdout, _stderr, rerun = run_tasks(port)
  failures << "path adoption rerun failed" unless rerun.success?
  failures << "path adoption is not idempotent" unless mutations(requests).empty?
end

libraries = [managed_library(id: "rename-only", name: "Books").merge(
  "legacySentinel" => "preserve-me"
)]
with_http_service(libraries) do |port, requests|
  _stdout, stderr, status = run_tasks(port)
  patch = mutations(requests).fetch(0, nil)
  failures << "exact-root rename failed: #{stderr.lines.last(8).join}" unless status.success?
  failures << "exact-root rename PATCH was not name-only" unless patch&.fetch("json") == { "name" => "Comics" }
  failures << "exact-root rename lost the unowned sentinel" unless libraries.first["legacySentinel"] == "preserve-me"
end

libraries = [managed_library(id: "settings-only", settings: { "scanOnStartup" => true }).merge(
  "legacySentinel" => "preserve-me"
)]
with_http_service(libraries) do |port, requests|
  _stdout, stderr, status = run_tasks(port)
  patch = mutations(requests).fetch(0, nil)
  failures << "owned-setting repair failed: #{stderr.lines.last(8).join}" unless status.success?
  failures << "owned-setting PATCH included unchanged fields" unless patch&.fetch("json") == { "scanOnStartup" => false }
  failures << "owned-setting repair lost the unowned sentinel" unless libraries.first["legacySentinel"] == "preserve-me"
end

libraries = [unrelated.dup]
with_http_service(libraries) do |port, requests|
  _stdout, stderr, status = run_tasks(port)
  failures << "fresh creation failed: #{stderr.lines.last(8).join}" unless status.success?
  create = mutations(requests).fetch(0, nil)
  failures << "fresh creation did not POST one exact Comics library" unless
    mutations(requests).length == 1 && create&.fetch("method") == "POST" &&
      create&.fetch("target") == "/api/v1/libraries" &&
      create&.fetch("json") == DEFAULTS.fetch("komga_library_settings").merge(
        "name" => "Comics", "root" => "/data"
      )
  failures << "fresh creation did not preserve an unrelated library" unless libraries.first == unrelated
end

conflicts = {
  "duplicate root" => [managed_library(id: "one", name: "Books", root: "/data"),
                         managed_library(id: "two", name: "Manga", root: "/data/")],
  "desired name on another root" => [managed_library(id: "managed", name: "Books", root: "/data"),
                                      managed_library(id: "conflict", name: "Comics", root: "/elsewhere")],
  "duplicate desired name" => [managed_library(id: "one", name: "Comics", root: "/elsewhere"),
                                managed_library(id: "two", name: "Comics", root: "/other")],
  "root candidate missing name" => [{ "id" => "candidate", "root" => "/data" }],
  "name candidate malformed root" => [{ "id" => "candidate", "name" => "Comics", "root" => ["/data"] }]
}
conflicts.each do |label, state|
  with_http_service(state) do |port, requests|
    _stdout, _stderr, status = run_tasks(port)
    failures << "#{label} unexpectedly reconciled" if status.success?
    failures << "#{label} reached a mutation before global preflight" unless mutations(requests).empty?
  end
end

users = [{ "id" => "reader", "email" => "reader@example.invalid", "roles" => ["USER"] }]
managed_users = [
  { "email" => "reader@example.invalid", "password" => "reader-secret", "roles" => ["PAGE_STREAMING"] },
  { "email" => "missing@example.invalid", "password" => "missing-secret", "roles" => ["PAGE_STREAMING"] }
]
multi_conflicts = {
  "duplicate root" => [managed_library(id: "one", name: "Books", root: "/data"),
                        managed_library(id: "two", name: "Manga", root: "/data/")],
  "duplicate desired name" => [managed_library(id: "managed", name: "Books", root: "/data"),
                               managed_library(id: "one", name: "Comics", root: "/one"),
                               managed_library(id: "two", name: "Comics", root: "/two")],
  "malformed managed candidate" => [{ "id" => "candidate", "root" => "/data" }]
}
multi_conflicts.each do |label, state|
  with_http_service(state, users: users.map(&:dup)) do |port, requests|
    _stdout, _stderr, status = run_tasks(port, [], managed_users: managed_users)
    failures << "#{label} with drifted/missing users unexpectedly reconciled" if status.success?
    failures << "#{label} allowed a managed-user or library mutation" unless mutations(requests).empty?
  end
end

malformed_unrelated = { "id" => ["opaque"], "name" => 7, "root" => { "path" => "/other" } }
libraries = [managed_library(id: "managed"), malformed_unrelated]
with_http_service(libraries) do |port, requests|
  _stdout, stderr, status = run_tasks(port)
  failures << "unrelated malformed library was unnecessarily rejected: #{stderr.lines.last(8).join}" unless
    status.success?
  failures << "unrelated malformed library was mutated" unless mutations(requests).empty? &&
    libraries.last == malformed_unrelated
end

libraries = [managed_library(id: "managed", name: "Books", settings: { "scanOnStartup" => true })]
with_http_service(libraries, fail_after_apply: true) do |port, requests|
  _stdout, _stderr, first = run_tasks(port)
  failures << "uncertain PATCH response unexpectedly succeeded" if first.success?
  failures << "uncertain PATCH did not apply the desired state before losing its response" unless
    libraries.first["name"] == "Comics" && libraries.first["scanOnStartup"] == false
  requests.clear
  _stdout, stderr, rerun = run_tasks(port)
  failures << "rerun after uncertain PATCH did not converge: #{stderr.lines.last(8).join}" unless rerun.success?
  failures << "rerun after applied PATCH repeated a mutation" unless mutations(requests).empty?
  failures << "rerun after uncertain PATCH changed the identifier" unless libraries.first["id"] == "managed"
end

libraries = [managed_library(id: "managed", name: "Books")]
with_http_service(libraries) do |port, requests|
  stdout, stderr, status = run_tasks(port, ["--check"])
  failures << "check-mode adoption failed: #{stderr.lines.last(8).join}" unless status.success?
  failures << "check-mode adoption omitted its repair plan" unless stdout.include?("KOMGA_PLAN_LIBRARY_REPAIR")
  failures << "check mode mutated a library" unless mutations(requests).empty?
end

if failures.empty?
  puts "Komga library reconciliation behavior passed"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} Komga library reconciliation violation(s)"
end
