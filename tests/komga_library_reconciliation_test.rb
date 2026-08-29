#!/usr/bin/env ruby
# frozen_string_literal: true

# Behavior and shape proof for the exactly reconciled Komga library model.
#
# The model is plural: komga_libraries declares Comics at /data/Comics and
# Ebooks at /data/Ebooks, each carrying its own settings over the shared
# komga_library_settings baseline. The interesting case is the migration from
# the single Comics library at /data, which the ambiguity guard refuses unless
# komga_library_root_migration_allowed is set for that one convergence.
#
# Run with --self-test to prove this file detects a planted regression.

require "json"
require "open3"
require "socket"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)
ROLE = File.join(ROOT, "roles/komga/tasks/main.yml")
COMPOSE = File.join(ROOT, "services/komga/compose.yml")
ARGUMENT_SPECS = File.join(ROOT, "roles/komga/meta/argument_specs.yml")
DEFAULTS_PATH = File.join(ROOT, "roles/komga/defaults/main.yml")
CONTRACT = File.join(ROOT, "tests/contracts/komga.sh")
# The Mac wrapper and the Mac seed hook are both shared across services now: one
# runner resolves every contract through tests/contracts/registry.yml, and one
# hook seeds every service from a table of phases. The properties asserted below
# are unchanged, they just live in the shared files.
MAC_CONTRACT_WRAPPER = File.join(ROOT, "tests/mac/run-contract.sh")
SEED_HOOK = File.join(ROOT, "tests/mac/hooks/fixtures-seed/00-services.sh")
DRIFT_HOOK = File.join(ROOT, "tests/mac/hooks/drift/40-komga.sh")
INTEGRATION_HARNESS = File.join(ROOT, "tests/integration.sh")
ROLE_SOURCE = File.read(ROLE)
DEFAULTS_SOURCE = File.read(DEFAULTS_PATH)
DEFAULTS = YAML.safe_load(DEFAULTS_SOURCE, aliases: false)
START_TASK = "List Komga libraries for reconciliation"
END_TASK = "Require exact reconciled Komga library"
COMICS_ROOT = "/data/Comics"
EBOOKS_ROOT = "/data/Ebooks"
MIGRATION_INPUT = "komga_library_root_migration_allowed"
# A module that writes to the target. Anything that renders the migration input
# into a file on the host turns a one-convergence argument into a setting.
PERSISTING_MODULES = /\.(copy|template|lineinfile|blockinfile|ini_file)\z/

def task_name(task)
  task.fetch("name", "")
end

def named_task(tasks, name)
  tasks.find { |task| task.is_a?(Hash) && task_name(task) == name }
end

# Every string a parsed task carries, keys included. A comment is not one of
# them, which is the whole point of reading the tasks instead of the file.
def task_strings(node)
  case node
  when Hash then node.flat_map { |key, value| [key.to_s] + task_strings(value) }
  when Array then node.flat_map { |value| task_strings(value) }
  when String then [node]
  else []
  end
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
    "    PLATFORM_KOMGA_CONTAINER=${PLATFORM_PROJECT_NAME:+$PLATFORM_PROJECT_NAME-}komga",
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

# ---------------------------------------------------------------------------
# The two-library model, as declared rather than as reconciled.
# ---------------------------------------------------------------------------

def model_failures(defaults_source, argument_specs, role_source, contract, drift_hook)
  failures = []
  defaults = begin
    YAML.safe_load(defaults_source, aliases: false)
  rescue Psych::Exception => error
    return ["role defaults are malformed: #{error.message.lines.first.to_s.strip}"]
  end

  %w[komga_library_name komga_library_root].each do |retired|
    failures << "#{retired} survives the plural library model" if defaults.key?(retired)
  end

  libraries = defaults["komga_libraries"]
  failures << "komga_libraries does not declare exactly Comics and Ebooks at their own roots" unless
    libraries == [
      { "name" => "Comics", "root" => COMICS_ROOT, "settings" => {} },
      { "name" => "Ebooks", "root" => EBOOKS_ROOT, "settings" => {} }
    ]

  settings = defaults["komga_library_settings"]
  failures << "the shared library settings are not a mapping" unless settings.is_a?(Hash)
  if settings.is_a?(Hash)
    failures << "the six-hour scan schedule is not declared (scanInterval)" unless
      settings["scanInterval"] == "EVERY_6H"
    failures << "the .acquisition scan exclusion is not declared" unless
      settings["scanDirectoryExclusions"] == [".acquisition"]
    failures << "scanOnStartup is no longer owned as false" unless settings["scanOnStartup"] == false
  end

  failures << "#{MIGRATION_INPUT} does not default to false" unless
    defaults[MIGRATION_INPUT] == false

  options = argument_specs.dig("argument_specs", "main", "options") || {}
  failures << "the plural library model is undeclared in argument_specs" unless
    options.dig("komga_libraries", "type") == "list" &&
    options.dig("komga_libraries", "elements") == "dict" &&
    options.dig("komga_libraries", "options", "name", "required") == true &&
    options.dig("komga_libraries", "options", "root", "required") == true &&
    options.dig("komga_libraries", "options").key?("settings")
  failures << "the shared library settings are undeclared in argument_specs" unless
    options.dig("komga_library_settings", "type") == "dict"
  failures << "#{MIGRATION_INPUT} is undeclared in argument_specs" unless
    options.dig(MIGRATION_INPUT, "type") == "bool" &&
    options.dig(MIGRATION_INPUT, "required") == false
  %w[komga_library_name komga_library_root].each do |retired|
    failures << "argument_specs still types the retired #{retired}" if options.key?(retired)
  end

  role_tasks = begin
    Array(YAML.safe_load(role_source, aliases: false))
  rescue Psych::Exception => error
    return failures + ["role tasks are malformed: #{error.message.lines.first.to_s.strip}"]
  end

  # A one-convergence input that any task writes to the target is no longer one.
  # Persistence is a property of one task -- a writing module whose own arguments
  # name the input -- so the module and the mention have to be found in the same
  # parsed task rather than anywhere in the file.
  persisting = role_tasks.select do |task|
    task.is_a?(Hash) && task.keys.any? { |key| key.to_s.match?(PERSISTING_MODULES) } &&
      task_strings(task).any? { |value| value.include?(MIGRATION_INPUT) }
  end
  failures << "the role persists the one-convergence migration input" unless persisting.empty?

  # Read off the guard's own conditions. The input is named in three live places
  # -- this guard, the plan that consults the name match, and the report's when --
  # so asking whether the file mentions it answered for whichever of the three
  # happened to survive, and the guard could lose its clause unnoticed.
  guard = named_task(role_tasks, "Refuse ambiguous Komga library candidates")
  failures << "the ambiguity guard no longer gates the root move on the migration input" unless
    Array(guard&.dig("ansible.builtin.assert", "that")).any? do |condition|
      condition.to_s.include?("#{MIGRATION_INPUT} | bool")
    end

  # Likewise the report: a banner that survives only in a comment reports nothing.
  report = named_task(role_tasks, "Report the one-convergence Komga library root migration input")
  failures << "the role never reports that the migration input is one-convergence only" unless
    report&.dig("ansible.builtin.debug", "msg").to_s.include?("KOMGA_ROOT_MIGRATION_ALLOWED") &&
    report["when"].to_s.include?("#{MIGRATION_INPUT} | bool")

  # The four below stay source text. tests/contracts/komga.sh and the Mac drift
  # hook are shell scripts carrying embedded Ruby, so they have no parsed
  # structure to read; what the values they pin should be is asserted against the
  # parsed defaults above, and this only asks that the contract and the lane still
  # pin them.
  failures << "the contract does not pin the two-library model" unless
    contract.include?('LIBRARY_MODEL = [') &&
      contract.include?("\"Comics\", \"root\" => \"#{COMICS_ROOT}\"") &&
      contract.include?("\"Ebooks\", \"root\" => \"#{EBOOKS_ROOT}\"")
  failures << "the contract does not pin the six-hour scan schedule" unless
    contract.include?('"scanInterval" => "EVERY_6H"')
  failures << "the contract does not pin the .acquisition scan exclusion" unless
    contract.include?('"scanDirectoryExclusions" => [".acquisition"]')

  failures << "the Mac drift lane does not prove the refused root migration" unless
    drift_hook.include?("#{MIGRATION_INPUT}=true") &&
      drift_hook.include?("migration-legacy") &&
      drift_hook.include?("refused the Komga library root migration")

  failures
end

# ---------------------------------------------------------------------------
# Behavior fixtures.
# ---------------------------------------------------------------------------

def library_tasks(role_source)
  tasks = YAML.safe_load(role_source, aliases: false)
  first = tasks.index { |task| task_name(task) == START_TASK }
  last = tasks.index { |task| task_name(task) == END_TASK }
  raise "Komga library task slice is unavailable" unless first && last && first <= last

  tasks[first..last].each do |task|
    task["ansible.builtin.include_tasks"] = File.join(
      ROOT, "roles/komga/tasks/managed_users.yml"
    ) if task["ansible.builtin.include_tasks"] == "managed_users.yml"
  end
end

def owned_settings
  DEFAULTS.fetch("komga_library_settings")
end

def managed_library(id:, name: "Comics", root: COMICS_ROOT, settings: {})
  owned_settings.merge(
    "id" => id, "name" => name, "root" => root, "unavailable" => false
  ).merge(settings)
end

def converged_libraries
  [managed_library(id: "comics"), managed_library(id: "ebooks", name: "Ebooks", root: EBOOKS_ROOT)]
end

def with_http_service(libraries, users: [], fail_after_apply: false)
  server = TCPServer.new("127.0.0.1", 0)
  requests = []
  stopped = false
  error = nil
  failed_patch = false
  created = 0
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
        created += 1
        status = 200
        libraries << request.fetch("json").merge(
          "id" => "created-library-#{created}", "unavailable" => false
        )
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

def run_tasks(port, arguments = [], managed_users: [], migration_allowed: false,
              role_source: ROLE_SOURCE)
  Dir.mktmpdir("komga-library-reconciliation-") do |directory|
    playbook = File.join(directory, "playbook.yml")
    variables = DEFAULTS.merge(
      "komga_api" => "http://127.0.0.1:#{port}",
      "vault_komga_admin_email" => "admin@example.invalid",
      "vault_komga_admin_password" => "admin-secret",
      "komga_claim_status" => { "json" => { "isClaimed" => true } },
      "vault_managed_komga_users" => managed_users,
      MIGRATION_INPUT => migration_allowed
    )
    File.write(
      playbook,
      YAML.dump([{ "hosts" => "localhost", "gather_facts" => false,
                   "vars" => variables, "tasks" => library_tasks(role_source) }]),
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

def legacy_single_library
  [managed_library(id: "legacy-library", name: "Comics", root: "/data").merge(
    "legacySentinel" => "preserve-me",
    "scanInterval" => "DISABLED",
    "scanDirectoryExclusions" => []
  )]
end

# The refusal half of the migration: without the one-convergence input, the
# single /data library must stop the run with nothing mutated.
def migration_refusal_failures(role_source)
  failures = []
  libraries = legacy_single_library
  with_http_service(libraries) do |port, requests|
    stdout, stderr, status = run_tasks(port, role_source: role_source)
    failures << "the root migration was not refused without the one-convergence input" if
      status.success?
    failures << "a refused root migration still mutated a library" unless mutations(requests).empty?
    failures << "the refusal does not name the one-convergence input" unless
      (stdout + stderr).include?("#{MIGRATION_INPUT}=true")
  end
  failures
end

# The completion half: with the input set, the named library is repointed in
# place and the second library is created beside it.
def migration_completion_failures(role_source)
  failures = []
  libraries = legacy_single_library
  with_http_service(libraries) do |port, requests|
    _stdout, stderr, status = run_tasks(port, migration_allowed: true, role_source: role_source)
    failures << "the allowed root migration failed: #{stderr.lines.last(12).join}" unless
      status.success?
    patch = mutations(requests).find { |request| request.fetch("method") == "PATCH" }
    create = mutations(requests).find { |request| request.fetch("method") == "POST" }
    failures << "the migration did not repoint the named library in place" unless
      patch&.fetch("target") == "/api/v1/libraries/legacy-library" &&
      patch&.fetch("json") == {
        "root" => COMICS_ROOT,
        "scanInterval" => "EVERY_6H",
        "scanDirectoryExclusions" => [".acquisition"]
      }
    failures << "the migration did not create the Ebooks library" unless
      create&.fetch("target") == "/api/v1/libraries" &&
      create&.fetch("json") == owned_settings.merge("name" => "Ebooks", "root" => EBOOKS_ROOT)
    failures << "the migration used more than one repair and one creation" unless
      mutations(requests).length == 2
    failures << "the migration changed the Comics library identifier" unless
      libraries.first["id"] == "legacy-library"
    failures << "the migration overwrote an unowned library setting" unless
      libraries.first["legacySentinel"] == "preserve-me"

    requests.clear
    _stdout, rerun_stderr, rerun = run_tasks(port, role_source: role_source)
    failures << "the migrated platform does not converge without the input: " \
                "#{rerun_stderr.lines.last(8).join}" unless rerun.success?
    failures << "the migrated platform is not idempotent" unless mutations(requests).empty?
  end
  failures
end

failures = []
self_test = ARGV.include?("--self-test")

main_tasks = YAML.safe_load(ROLE_SOURCE, aliases: false)
compose = YAML.safe_load_file(COMPOSE, aliases: true)
argument_specs = YAML.safe_load_file(ARGUMENT_SPECS, aliases: false)
validate_health_gating!(compose, main_tasks, DEFAULTS, argument_specs)

contract = File.read(CONTRACT)
drift_hook = File.read(DRIFT_HOOK)
mac_contract_wrapper = File.read(MAC_CONTRACT_WRAPPER)
seed_hook = File.read(SEED_HOOK)
runtime_sources = [
  contract,
  mac_contract_wrapper,
  seed_hook,
  File.read(INTEGRATION_HARNESS)
]
validate_runtime_health_paths!(runtime_sources)

unless ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
         File.executable?(File.join(directory, "ansible-playbook"))
       end
  abort "ansible-playbook is required for Komga library behavior fixtures"
end

if self_test
  planted = [
    ["a disabled scan interval",
     lambda do
       source = DEFAULTS_SOURCE.sub("scanInterval: EVERY_6H", "scanInterval: DISABLED")
       abort "self-test could not plant a disabled scan interval" if source == DEFAULTS_SOURCE
       model_failures(source, argument_specs, ROLE_SOURCE, contract, drift_hook)
     end,
     "scanInterval"],
    ["a dropped .acquisition exclusion",
     lambda do
       source = DEFAULTS_SOURCE.sub("  scanDirectoryExclusions:\n    - .acquisition\n",
                                    "  scanDirectoryExclusions: []\n")
       abort "self-test could not plant an empty exclusion list" if source == DEFAULTS_SOURCE
       model_failures(source, argument_specs, ROLE_SOURCE, contract, drift_hook)
     end,
     ".acquisition"],
    ["a migration input that defaults to true",
     lambda do
       source = DEFAULTS_SOURCE.sub("#{MIGRATION_INPUT}: false", "#{MIGRATION_INPUT}: true")
       abort "self-test could not plant a persistent migration input" if source == DEFAULTS_SOURCE
       model_failures(source, argument_specs, ROLE_SOURCE, contract, drift_hook)
     end,
     MIGRATION_INPUT]
  ]
  planted.each do |label, collect, diagnostic|
    detected = collect.call
    abort "self-test failed: #{label} was accepted" unless
      detected.any? { |failure| failure.include?(diagnostic) }
  end

  # The two rows below are why the guard and report checks read parsed tasks
  # rather than the role's text. The input is named in three live places and the
  # banner appears exactly once, so a whole-file substring answered for whichever
  # copy happened to survive: an ungated guard still mentions the input twice
  # elsewhere, and a banner demoted to a comment is still in the file. Each plant
  # is asserted to pass the source-text form before it is required to fail the
  # structural one.
  ungated = ROLE_SOURCE.sub("        #{MIGRATION_INPUT} | bool\n", "        true\n")
  abort "self-test could not plant an ungated root migration" if ungated == ROLE_SOURCE
  abort "self-test failed: an ungated guard no longer names the input in the file" unless
    ungated.include?("#{MIGRATION_INPUT} | bool")
  abort "self-test failed: an ungated root migration was accepted" unless
    model_failures(DEFAULTS_SOURCE, argument_specs, ungated, contract, drift_hook)
      .any? { |failure| failure.include?("gates the root move") }

  commented_banner = ROLE_SOURCE.sub(
    "  ansible.builtin.debug:\n" \
    "    msg: >-\n" \
    "      KOMGA_ROOT_MIGRATION_ALLOWED: pending library root moves\n",
    "  # KOMGA_ROOT_MIGRATION_ALLOWED\n" \
    "  ansible.builtin.debug:\n" \
    "    msg: >-\n" \
    "      pending library root moves\n"
  )
  abort "self-test could not plant a commented migration banner" if commented_banner == ROLE_SOURCE
  abort "self-test failed: a commented banner no longer appears in the file" unless
    commented_banner.include?("KOMGA_ROOT_MIGRATION_ALLOWED")
  abort "self-test failed: a banner that survives only as a comment was accepted" unless
    model_failures(DEFAULTS_SOURCE, argument_specs, commented_banner, contract, drift_hook)
      .any? { |failure| failure.include?("one-convergence only") }

  # And the behavioural half: an ungated guard also lets the refusal fixture through.
  abort "self-test failed: an ungated root migration reconciled" if
    migration_refusal_failures(ungated).empty?

  # And with the name match never consulted, the allowed migration cannot complete.
  unreachable = ROLE_SOURCE.sub(
    "             (item.name_matches | first | default({}))\n" \
    "             if komga_library_root_migration_allowed | bool else {})\n",
    "             {})\n"
  )
  abort "self-test could not plant an unreachable root repair" if unreachable == ROLE_SOURCE
  abort "self-test failed: an unreachable root repair was accepted" if
    migration_completion_failures(unreachable).empty?

  puts "Komga library reconciliation: self-test detects model, guard and repair regressions"
  exit
end

failures.concat(model_failures(DEFAULTS_SOURCE, argument_specs, ROLE_SOURCE, contract, drift_hook))

# The disposable lanes deploy Komga under a project namespace and name the
# container after it, so a base context pinned to the canonical Compose name
# would verify a container the lane never created.
production_base = runtime_sources.dup
production_base[0] = contract.sub(
  "PLATFORM_KOMGA_CONTAINER=${PLATFORM_PROJECT_NAME:+$PLATFORM_PROJECT_NAME-}komga",
  "PLATFORM_KOMGA_CONTAINER=komga"
)
runtime_health_mutation_rejected!(production_base, "production base container")

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

failures.concat(migration_refusal_failures(ROLE_SOURCE))
failures.concat(migration_completion_failures(ROLE_SOURCE))

# Fresh installation: both libraries are created, in declaration order, with the
# complete owned setting set and nothing else.
unrelated = managed_library(id: "unrelated", name: "Reference", root: "/reference")
libraries = [unrelated.dup]
with_http_service(libraries) do |port, requests|
  _stdout, stderr, status = run_tasks(port)
  failures << "fresh creation failed: #{stderr.lines.last(8).join}" unless status.success?
  creates = mutations(requests)
  failures << "fresh creation did not POST exactly the two managed libraries" unless
    creates.length == 2 && creates.all? { |request| request.fetch("method") == "POST" } &&
      creates.map { |request| request.fetch("json") } == [
        owned_settings.merge("name" => "Comics", "root" => COMICS_ROOT),
        owned_settings.merge("name" => "Ebooks", "root" => EBOOKS_ROOT)
      ]
  failures << "fresh creation did not preserve an unrelated library" unless libraries.first == unrelated

  requests.clear
  _stdout, _stderr, rerun = run_tasks(port)
  failures << "fresh creation rerun failed" unless rerun.success?
  failures << "fresh creation is not idempotent" unless mutations(requests).empty?
end

# A converged platform is untouched, and each library is repaired on its own.
libraries = converged_libraries
with_http_service(libraries) do |port, requests|
  _stdout, stderr, status = run_tasks(port)
  failures << "converged model failed: #{stderr.lines.last(8).join}" unless status.success?
  failures << "converged model mutated a library" unless mutations(requests).empty?

  # A stale migration input must be inert rather than a source of churn: the
  # root match still wins, so there is nothing for the name match to repoint.
  requests.clear
  stdout, stderr, allowed = run_tasks(port, migration_allowed: true)
  failures << "converged model with the migration input failed: #{stderr.lines.last(8).join}" unless
    allowed.success?
  failures << "a stale migration input mutated a converged library" unless
    mutations(requests).empty?
  failures << "a stale migration input is not reported as stale" unless
    stdout.include?("KOMGA_ROOT_MIGRATION_ALLOWED")
end

libraries = [
  managed_library(id: "rename-only", name: "Books").merge("legacySentinel" => "preserve-me"),
  managed_library(id: "ebooks", name: "Ebooks", root: EBOOKS_ROOT)
]
with_http_service(libraries) do |port, requests|
  _stdout, stderr, status = run_tasks(port)
  patch = mutations(requests).fetch(0, nil)
  failures << "exact-root rename failed: #{stderr.lines.last(8).join}" unless status.success?
  failures << "exact-root rename PATCH was not name-only" unless
    mutations(requests).length == 1 && patch&.fetch("json") == { "name" => "Comics" }
  failures << "exact-root rename lost the unowned sentinel" unless
    libraries.first["legacySentinel"] == "preserve-me"
end

libraries = [
  managed_library(id: "comics"),
  managed_library(id: "settings-only", name: "Ebooks", root: EBOOKS_ROOT,
                  settings: { "scanOnStartup" => true }).merge("legacySentinel" => "preserve-me")
]
with_http_service(libraries) do |port, requests|
  _stdout, stderr, status = run_tasks(port)
  patch = mutations(requests).fetch(0, nil)
  failures << "owned-setting repair failed: #{stderr.lines.last(8).join}" unless status.success?
  failures << "owned-setting PATCH did not target only the drifted library" unless
    mutations(requests).length == 1 &&
      patch&.fetch("target") == "/api/v1/libraries/settings-only" &&
      patch&.fetch("json") == { "scanOnStartup" => false }
  failures << "owned-setting repair lost the unowned sentinel" unless
    libraries.last["legacySentinel"] == "preserve-me"
end

# The scan-schedule half of the acquisition design: an already correctly rooted
# pair still has its interval and exclusions brought to the owned values.
libraries = converged_libraries.map do |library|
  library.merge("scanInterval" => "DISABLED", "scanDirectoryExclusions" => [])
end
with_http_service(libraries) do |port, requests|
  _stdout, stderr, status = run_tasks(port)
  failures << "scan schedule repair failed: #{stderr.lines.last(8).join}" unless status.success?
  failures << "scan schedule repair did not converge both libraries" unless
    mutations(requests).length == 2 &&
      mutations(requests).map { |request| request.fetch("json") }.uniq == [{
        "scanInterval" => "EVERY_6H", "scanDirectoryExclusions" => [".acquisition"]
      }]
end

conflicts = {
  "duplicate root" => [[managed_library(id: "one", name: "Books"),
                        managed_library(id: "two", name: "Manga", root: "#{COMICS_ROOT}/")], false],
  "duplicate desired name" => [[managed_library(id: "one", name: "Comics", root: "/elsewhere"),
                                managed_library(id: "two", name: "Comics", root: "/other")], true],
  "root candidate missing name" => [[{ "id" => "candidate", "root" => COMICS_ROOT }], false],
  "name candidate malformed root" =>
    [[{ "id" => "candidate", "name" => "Comics", "root" => [COMICS_ROOT] }], false],
  "one library claimed by two managed names" =>
    [[managed_library(id: "shared", name: "Comics", root: EBOOKS_ROOT)], true]
}
conflicts.each do |label, (state, migration_allowed)|
  with_http_service(state) do |port, requests|
    _stdout, _stderr, status = run_tasks(port, migration_allowed: migration_allowed)
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
  "duplicate root" => [managed_library(id: "one", name: "Books"),
                       managed_library(id: "two", name: "Manga", root: "#{COMICS_ROOT}/")],
  "duplicate desired name" => [managed_library(id: "managed", name: "Books"),
                               managed_library(id: "one", name: "Comics", root: "/one"),
                               managed_library(id: "two", name: "Comics", root: "/two")],
  "malformed managed candidate" => [{ "id" => "candidate", "root" => COMICS_ROOT }],
  "unreviewed root migration" => legacy_single_library
}
multi_conflicts.each do |label, state|
  with_http_service(state, users: users.map(&:dup)) do |port, requests|
    _stdout, _stderr, status = run_tasks(port, [], managed_users: managed_users)
    failures << "#{label} with drifted/missing users unexpectedly reconciled" if status.success?
    failures << "#{label} allowed a managed-user or library mutation" unless mutations(requests).empty?
  end
end

malformed_unrelated = { "id" => ["opaque"], "name" => 7, "root" => { "path" => "/other" } }
libraries = converged_libraries + [malformed_unrelated]
with_http_service(libraries) do |port, requests|
  _stdout, stderr, status = run_tasks(port)
  failures << "unrelated malformed library was unnecessarily rejected: #{stderr.lines.last(8).join}" unless
    status.success?
  failures << "unrelated malformed library was mutated" unless mutations(requests).empty? &&
    libraries.last == malformed_unrelated
end

libraries = [
  managed_library(id: "managed", name: "Books", settings: { "scanOnStartup" => true }),
  managed_library(id: "ebooks", name: "Ebooks", root: EBOOKS_ROOT)
]
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

# Check mode reviews the whole migration without performing any of it.
libraries = legacy_single_library
with_http_service(libraries) do |port, requests|
  stdout, stderr, status = run_tasks(port, ["--check"], migration_allowed: true)
  failures << "check-mode migration failed: #{stderr.lines.last(8).join}" unless status.success?
  failures << "check-mode migration omitted its repair plan" unless
    stdout.include?("KOMGA_PLAN_LIBRARY_REPAIR")
  failures << "check-mode migration omitted its creation plan" unless
    stdout.include?("KOMGA_PLAN_LIBRARY_CREATE")
  failures << "check mode mutated a library" unless mutations(requests).empty?
end

if failures.empty?
  puts "Komga two-library reconciliation and root migration behavior passed"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} Komga library reconciliation violation(s)"
end
