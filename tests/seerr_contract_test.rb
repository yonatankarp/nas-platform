#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Behaviour of the Seerr service contract's two Ruby programs.
#
# Until #147 both lived in `<<'RUBY'` heredocs inside tests/contracts/seerr.sh.
# `sh -n` reads a quoted heredoc as opaque text, so the static half was only
# ever executed by `tests/contracts/seerr.sh static` and the runtime half only
# by an integration lane with Docker, a converged Seerr and a real vault.
# tests/contracts/seerr-static.rb and tests/contracts/seerr-runtime.rb are files
# now, so both are reachable here.
#
# Three layers, because the contract has three kinds of property:
#
#   Static -- build a fixture repository from the files the program reads, break
#   exactly one thing in it, and require the program to name that thing. The
#   assertion text is the interface: a guard that fails for the wrong reason has
#   stopped guarding what it names, so every row pins the exact diagnostic.
#
#   Runtime -- serve the Seerr API from an HTTP fixture and put `docker` and
#   `ansible-vault` stubs on PATH, so each access, permission, sign-in policy
#   and persistence outcome can be moved one at a time. This half had no test at
#   all, and it is 164 lines of exactly the assertions a deployment depends on.
#
#   Wrapper -- tests/contracts/seerr.sh is what turns a mode into an invocation.
#   Its rows prove the mode guard, the run-mode environment contract, that both
#   programs are reached, that they come from the checkout while the tree the
#   static half inspects does not, and that neither can eat the caller's stdin.
#
# Run with --self-test to plant a regression in each program and in the wrapper.
# It accumulates its mismatches rather than aborting on the first, and every
# plant is built before the worker pool: `abort` inside a worker raises
# SystemExit there, and the pool would report a KeyError in place of the message.

require "etc"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "shellwords"
require "tmpdir"
require "yaml"

require_relative "http_fixture_support"

ROOT = File.expand_path("..", __dir__)
CONTRACT = File.join(ROOT, "tests", "contracts", "seerr.sh")
STATIC_PROGRAM = File.join(ROOT, "tests", "contracts", "seerr-static.rb")
RUNTIME_PROGRAM = File.join(ROOT, "tests", "contracts", "seerr-runtime.rb")

SUCCESS_LINE = "seerr static contract: bootstrapped request front end ownership holds"
MODE_REFUSAL = "seerr contract accepts only static or run"
RUNTIME_SUCCESS = "seerr contract: bootstrapped owner, permission split, sign-in policy, " \
                  "and persisted state hold"

# Exactly what the static program reads, plus the shared flatten_tasks it
# requires through PLATFORM_CONTRACT_REPO_DIR. Unlike tranche 1's pair, this
# list is exactly the program's own `required` list -- it reads no file its
# existence sweep does not check, which the "an intact repository" row proves by
# passing against a fixture holding only these.
FIXTURE_FILES = %w[
  roles/seerr/defaults/main.yml
  roles/seerr/meta/argument_specs.yml
  roles/seerr/tasks/main.yml
  roles/seerr/tasks/bootstrap.yml
  roles/seerr/tasks/reconcile_settings.yml
  roles/seerr/tasks/reconcile_arrs.yml
  roles/seerr/tasks/reconcile_users.yml
  roles/seerr/templates/env.j2
  services/seerr/compose.yml
  services/seerr/compose.mac.yml
  services/seerr/compose.integration.yml
  tests/policy_support.rb
].freeze

# Never more workers than cores. tests/validate-policy.sh already runs its
# checks concurrently, so oversubscribing a four-core CI runner trades wall time
# for contention. Each case owns its own mktmpdir fixture and shares nothing but
# the failure list, and failures are concatenated in row order so the report is
# deterministic.
CASE_WORKER_LIMIT = Integer(ENV.fetch("SEERR_CONTRACT_CASE_WORKERS") { [Etc.nprocessors, 8].min.to_s })

def in_parallel_cases(failures, items)
  items = items.to_a
  workers = [CASE_WORKER_LIMIT, items.length].min
  return items.each { |item| yield item, failures } if workers <= 1

  pending = Queue.new
  items.each_with_index { |item, index| pending << [index, item] }
  collected = {}
  lock = Mutex.new
  Array.new(workers) do
    Thread.new do
      loop do
        index, item = begin
                        pending.pop(true)
                      rescue ThreadError
                        break
                      end
        local = []
        yield item, local
        lock.synchronize { collected[index] = local }
      end
    end
  end.each(&:join)
  collected.keys.sort.each { |index| failures.concat(collected.fetch(index)) }
end

def build_fixture_repository(root)
  FIXTURE_FILES.each do |relative|
    destination = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(destination))
    FileUtils.cp(File.join(ROOT, relative), destination)
  end
end

# Every substitution states how many matches it expects. A replacement that
# still contains its own pattern plants nothing, and a bare `sub` cannot tell
# that from a plant that worked: the row then reports a pass, or a failure with
# the wrong diagnostic.
def mutate_text(root, relative, pattern, replacement, occurrences: 1)
  path = File.join(root, relative)
  body = File.read(path)
  found = body.scan(pattern).length
  raise "#{relative}: expected #{occurrences} match(es) of #{pattern.inspect}, found #{found}" unless
    found == occurrences

  File.write(path, occurrences == 1 ? body.sub(pattern, replacement) : body.gsub(pattern, replacement))
end

def edit_yaml(root, relative)
  path = File.join(root, relative)
  document = YAML.safe_load_file(path, aliases: true)
  yield document
  File.write(path, YAML.dump(document))
end

STATIC_ROWS = [
  { name: "an intact repository", break: ->(_root) {}, expects: nil },
  {
    name: "a declared file that is gone",
    break: ->(root) { FileUtils.rm(File.join(root, "services/seerr/compose.mac.yml")) },
    expects: "missing services/seerr/compose.mac.yml"
  },
  {
    name: "a seat off the shared control network",
    break: lambda { |root|
      edit_yaml(root, "services/seerr/compose.yml") { |d| d["services"]["seerr"].delete("networks") }
    },
    expects: "Seerr must join the shared media control network"
  },
  {
    name: "a container that is not the platform identity",
    break: lambda { |root|
      edit_yaml(root, "services/seerr/compose.yml") { |d| d["services"]["seerr"]["user"] = "1000:1000" }
    },
    expects: "Seerr must run as the shared platform identity"
  },
  {
    name: "a container that reaps nothing npm start forks",
    break: lambda { |root|
      edit_yaml(root, "services/seerr/compose.yml") { |d| d["services"]["seerr"]["init"] = false }
    },
    expects: "Seerr must reap what npm start forks"
  },
  {
    name: "a stop grace period the request database cannot survive",
    break: lambda { |root|
      edit_yaml(root, "services/seerr/compose.yml") do |d|
        d["services"]["seerr"].delete("stop_grace_period")
      end
    },
    expects: "Seerr holds the request database and must declare a stop grace period"
  },
  {
    name: "a CPU set rendered twice",
    break: lambda { |root|
      mutate_text(root, "roles/seerr/templates/env.j2",
                  "PLATFORM_CONTAINER_CPUSET={{ platform_effective_container_cpuset }}",
                  "PLATFORM_CONTAINER_CPUSET={{ platform_effective_container_cpuset }}\n" \
                  "PLATFORM_CONTAINER_CPUSET=0-3")
    },
    expects: "Seerr env must render the CPU set exactly once"
  }
].freeze

def judge(failures, label, expects, stdout, stderr, status)
  output = stdout + stderr
  if expects.nil?
    return if status.success?

    failures << "#{label}: refused an intact repository: #{output.strip}"
    return
  end

  if status.success?
    failures << "#{label}: accepted what it must refuse"
  elsif !output.include?(expects)
    failures << "#{label}: refused for the wrong reason, wanted #{expects.inspect}, " \
                "got #{output.strip.inspect}"
  end
end

def static_failures(program, rows = STATIC_ROWS)
  failures = []
  in_parallel_cases(failures, rows) do |row, collected|
    Dir.mktmpdir("nas-platform-seerr-static.") do |raw|
      root = File.realpath(raw)
      build_fixture_repository(root)
      row.fetch(:break).call(root)
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => root }, RbConfig.ruby, program, root
      )
      judge(collected, "static: #{row.fetch(:name)}", row.fetch(:expects), stdout, stderr, status)
    end
  end
  failures
end

# --- runtime layer ---------------------------------------------------------
#
# The runtime half takes NO arguments: every input arrives in the environment.
# So the sandbox is entirely environment plus PATH stubs plus one HTTP fixture,
# and each row moves exactly one of them.

API_KEY = "seerr-contract-api-key-0000000000"
RADARR_KEY = "radarr-contract-api-key-000000000"
SONARR_KEY = "sonarr-contract-api-key-000000000"
NTFY_TOKEN = "tk_seerr_contract_token"
HOUSEHOLD = %w[viewer].freeze
OWNER_ID = 1
MEMBER_ID = 7

RUNTIME_DEFAULTS = {
  health: "healthy",
  inspect_ok: true,
  vault_ok: true,
  version: "2.1.0",
  anonymous_user_code: 401,
  wrong_key_code: 403,
  owner_permissions: 2,
  member_permissions: 160,
  member_quota: nil,
  impersonated_permissions: 160,
  initialized: true,
  local_login: false,
  new_plex_login: false,
  media_server_login: true,
  media_server_type: 2,
  main_api_key: API_KEY,
  default_permissions: 0,
  jellyfin_ip: "jellyfin",
  jellyfin_port: 8096,
  takeover_code: 500,
  takeover_body: '{"message":"Jellyfin server already configured"}',
  arrs: false,
  arr_rows: nil,
  ntfy_enabled: true,
  ntfy_auth_token: true,
  ntfy_token: NTFY_TOKEN,
  database: true
}.freeze

def vault_document
  {
    "vault_seerr_api_key" => API_KEY,
    "vault_arr_radarr_api_key" => RADARR_KEY,
    "vault_arr_sonarr_api_key" => SONARR_KEY,
    "vault_ntfy_seerr_token" => NTFY_TOKEN,
    "vault_managed_users" => { "jellyfin" => HOUSEHOLD.map { |name| { "username" => name } } }
  }
end

def build_runtime_sandbox(root, options)
  bin = File.join(root, "bin")
  FileUtils.mkdir_p(bin)
  docker_root = File.join(root, "docker")
  database = File.join(docker_root, "seerr", "config", "db", "db.sqlite3")
  FileUtils.mkdir_p(File.dirname(database))
  File.write(database, "sqlite-fixture-bytes") if options.fetch(:database)

  File.write(File.join(bin, "docker"), <<~SH)
    #!/bin/sh
    #{options.fetch(:inspect_ok) ? '' : 'exit 1'}
    printf '%s\\n' '#{options.fetch(:health)}'
  SH
  File.write(File.join(bin, "ansible-vault"), <<~SH)
    #!/bin/sh
    #{options.fetch(:vault_ok) ? '' : 'echo "decryption failed" >&2; exit 1'}
    cat <<'YAML'
    #{YAML.dump(vault_document).lines.map { |line| line }.join.chomp}
    YAML
  SH
  %w[docker ansible-vault].each { |name| File.chmod(0o755, File.join(bin, name)) }
  File.write(File.join(root, "vault.yml"), "encrypted\n")
  File.write(File.join(root, "vault-password"), "fixture\n")
  [bin, docker_root]
end

# Keyed BY KIND, deliberately. An override that answered the same rows for both
# radarr and sonarr made the sonarr iteration produce the *other* clause's
# diagnostic once a plant removed the first, so two rows reported "refused for
# the wrong reason" rather than the sentence they pin. Overriding one kind and
# leaving the other correct is what keeps each row to one sentence.
def arr_rows(kind, options)
  override = options.fetch(:arr_rows)
  return override.fetch(kind) if override.is_a?(Hash) && override.key?(kind)
  return [] unless options.fetch(:arrs)

  key = kind == "radarr" ? RADARR_KEY : SONARR_KEY
  [{ "apiKey" => key, "hostname" => kind }]
end

def runtime_responder(options)
  lambda do |method, target, headers, _body|
    key = headers["x-api-key"]
    user = headers["x-api-user"]
    path = target.split("?").first
    return [options.fetch(:takeover_code), options.fetch(:takeover_body)] if
      method == "POST" && path == "/api/v1/auth/jellyfin"

    case path
    when "/api/v1/status"
      [200, JSON.generate("version" => options.fetch(:version))]
    when "/api/v1/user"
      next [options.fetch(:anonymous_user_code), "{}"] if key.nil?
      next [options.fetch(:wrong_key_code), "{}"] unless key == API_KEY

      rows = [
        { "id" => OWNER_ID, "permissions" => options.fetch(:owner_permissions),
          "jellyfinUsername" => "nasadmin" },
        { "id" => MEMBER_ID, "permissions" => options.fetch(:member_permissions),
          "jellyfinUsername" => HOUSEHOLD.first,
          "movieQuotaLimit" => options.fetch(:member_quota),
          "tvQuotaLimit" => options.fetch(:member_quota) }
      ]
      [200, JSON.generate("results" => rows)]
    when "/api/v1/auth/me"
      [200, JSON.generate("id" => Integer(user, 10),
                          "permissions" => options.fetch(:impersonated_permissions))]
    when "/api/v1/settings/public"
      [200, JSON.generate(
        "initialized" => options.fetch(:initialized),
        "localLogin" => options.fetch(:local_login),
        "newPlexLogin" => options.fetch(:new_plex_login),
        "mediaServerLogin" => options.fetch(:media_server_login),
        "mediaServerType" => options.fetch(:media_server_type)
      )]
    when "/api/v1/settings/main"
      [200, JSON.generate("apiKey" => options.fetch(:main_api_key),
                          "defaultPermissions" => options.fetch(:default_permissions))]
    when "/api/v1/settings/jellyfin"
      [200, JSON.generate("ip" => options.fetch(:jellyfin_ip),
                          "port" => options.fetch(:jellyfin_port))]
    when "/api/v1/settings/radarr" then [200, JSON.generate(arr_rows("radarr", options))]
    when "/api/v1/settings/sonarr" then [200, JSON.generate(arr_rows("sonarr", options))]
    when "/api/v1/settings/notifications/ntfy"
      [200, JSON.generate(
        "enabled" => options.fetch(:ntfy_enabled),
        "options" => { "authMethodToken" => options.fetch(:ntfy_auth_token),
                       "token" => options.fetch(:ntfy_token) }
      )]
    else [404, "{}"]
    end
  end
end

RUNTIME_ROWS = [
  { name: "a converged Seerr", given: {}, expects: nil },
  {
    name: "a status endpoint that reports no version",
    given: { version: "" },
    expects: "Seerr did not report a version"
  },
  {
    name: "a container Docker cannot inspect",
    given: { inspect_ok: false },
    expects: "the Seerr container could not be inspected"
  },
  {
    name: "a container Docker calls unhealthy",
    given: { health: "unhealthy" },
    expects: "the Seerr container is not healthy"
  },
  {
    name: "a vault that cannot be read",
    given: { vault_ok: false },
    expects: "encrypted vault could not be read"
  },
  {
    name: "a protected route served anonymously",
    given: { anonymous_user_code: 200 },
    expects: "Seerr served a protected route to an anonymous request"
  },
  {
    name: "a key the platform never authored being accepted",
    given: { wrong_key_code: 200 },
    expects: "Seerr accepted a key the platform never authored"
  },
  {
    name: "an owner holding more than ADMIN",
    given: { owner_permissions: 6 },
    expects: "the Seerr owner does not hold exactly ADMIN"
  },
  {
    name: "a household identity holding the wrong permissions",
    given: { member_permissions: 2 },
    expects: "does not hold exactly REQUEST and AUTO_APPROVE"
  },
  {
    name: "a household identity carrying a request quota",
    given: { member_quota: 5 },
    expects: "carries a request quota the design does not grant"
  },
  {
    name: "an impersonated identity Seerr does not agree with",
    given: { impersonated_permissions: 2 },
    expects: "sees a different identity than Seerr stored"
  },
  {
    name: "a visitor still sent to the setup wizard",
    given: { initialized: false },
    expects: "Seerr still redirects visitors to its setup wizard"
  },
  {
    name: "a local password login path left open",
    given: { local_login: true },
    expects: "Seerr left a local password login path open"
  },
  {
    name: "a policy that would create any Jellyfin user who signs in",
    given: { new_plex_login: true },
    expects: "Seerr would silently create any Jellyfin user who signs in"
  },
  {
    name: "Jellyfin sign-in disabled for its own identities",
    given: { media_server_login: false },
    expects: "Seerr disabled Jellyfin sign-in for its own identities"
  },
  {
    name: "a media server that is not Jellyfin",
    given: { media_server_type: 1 },
    expects: "Seerr is not pointed at a Jellyfin media server"
  },
  {
    name: "a served API key that is not the vault's",
    given: { main_api_key: "0" * 32 },
    expects: "Seerr is not serving the vault-authored API key"
  },
  {
    name: "a newly discovered user inheriting request permissions",
    given: { default_permissions: 32 },
    expects: "a newly discovered Seerr user would inherit request permissions"
  },
  {
    name: "a Jellyfin server the platform does not name",
    given: { jellyfin_ip: "media.invalid" },
    expects: "Seerr does not name the platform's Jellyfin server"
  },
  {
    name: "a foreign Jellyfin server accepted after bootstrap",
    given: { takeover_code: 200, takeover_body: '{"id":1}' },
    expects: "Seerr accepted a foreign Jellyfin server after bootstrap"
  },
  {
    name: "an arr declared on a host with no transport",
    given: { arrs: false, arr_rows: { "radarr" => [{ "apiKey" => RADARR_KEY, "hostname" => "radarr" }] } },
    expects: "declared a radarr server on a host with no transport"
  },
  {
    name: "an arr server that does not carry that arr's own key",
    given: { arrs: true, arr_rows: { "radarr" => [{ "apiKey" => "0" * 32, "hostname" => "radarr" }] } },
    expects: "does not carry that arr's own API key"
  },
  {
    name: "an arr server not addressed by service alias",
    given: { arrs: true, arr_rows: { "radarr" => [{ "apiKey" => RADARR_KEY, "hostname" => "10.0.0.5" }] } },
    expects: "is not addressed by service alias"
  },
  {
    name: "an ntfy agent that is disabled",
    given: { ntfy_enabled: false },
    expects: "Seerr's ntfy agent is disabled"
  },
  {
    name: "an ntfy agent publishing without authenticating",
    given: { ntfy_auth_token: false },
    expects: "Seerr's ntfy agent publishes without authenticating"
  },
  {
    name: "state that did not land in the declared config root",
    given: { database: false },
    expects: "Seerr did not persist its database in the declared config root"
  }
].freeze

def runtime_failures(program, rows = RUNTIME_ROWS)
  failures = []
  in_parallel_cases(failures, rows) do |row, collected|
    options = RUNTIME_DEFAULTS.merge(row.fetch(:given))
    Dir.mktmpdir("nas-platform-seerr-runtime.") do |raw|
      root = File.realpath(raw)
      bin, docker_root = build_runtime_sandbox(root, options)
      HttpFixtureSupport.with_http_fixture(
        lambda do |port|
          stdout, stderr, status = Open3.capture3(
            {
              "PATH" => "#{bin}:#{ENV.fetch('PATH')}",
              "PLATFORM_SEERR_PORT" => port.to_s,
              "PLATFORM_SEERR_CONTAINER" => "fixture-seerr",
              "PLATFORM_SEERR_ARRS" => options.fetch(:arrs).to_s,
              "PLATFORM_DOCKER_ROOT" => docker_root,
              "PLATFORM_CONTRACT_VAULT_FILE" => File.join(root, "vault.yml"),
              "PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" => File.join(root, "vault-password")
            },
            RbConfig.ruby, program
          )
          judge(collected, "runtime: #{row.fetch(:name)}", row.fetch(:expects), stdout, stderr, status)
        end,
        &runtime_responder(options)
      )
    end
  end
  failures
end

# --- wrapper layer ---------------------------------------------------------
#
# tests/contracts/seerr.sh resolves both programs from its own checkout rather
# than from the tree it inspects, so a copy of the three files into a throwaway
# tests/contracts/ is a whole working contract. That is what lets a row point
# PLATFORM_CONTRACT_REPO_DIR at a broken fixture and still exercise the real
# wrapper.

def with_contract_copy(static: File.read(STATIC_PROGRAM), runtime: File.read(RUNTIME_PROGRAM),
                       wrapper: File.read(CONTRACT))
  Dir.mktmpdir("nas-platform-seerr-wrapper.") do |raw|
    root = File.realpath(raw)
    build_fixture_repository(root)
    contracts = File.join(root, "tests", "contracts")
    FileUtils.mkdir_p(contracts)
    wrapper_path = File.join(contracts, "seerr.sh")
    File.write(wrapper_path, wrapper)
    File.chmod(0o755, wrapper_path)
    File.write(File.join(contracts, "seerr-static.rb"), static)
    File.write(File.join(contracts, "seerr-runtime.rb"), runtime)
    yield wrapper_path, root
  end
end

# Reports what each program saw on stdin and what the caller still has, which is
# the only way the redirect is observable: neither real program reads stdin, so
# the redirect is what keeps that true rather than something that changes an
# outcome today.
STDIN_PROBE = <<~'PROBE'
  warn "probe read #{$stdin.read.inspect}"
  exit 1
PROBE

def stdin_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  with_contract_copy(static: STDIN_PROBE, wrapper: wrapper_source) do |contract|
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => ROOT },
      "/bin/sh", "-c", "#{contract.shellescape} static; printf 'left:'; cat",
      stdin_data: "caller-payload\n"
    )
    output = stdout + stderr
    failures << "stdin: the probing shell itself failed: #{output.strip}" unless status.success?
    failures << "stdin: the static program was handed the caller's input: #{output.strip.inspect}" unless
      output.include?('probe read ""')
    failures << "stdin: the caller's input did not survive the contract: #{output.strip.inspect}" unless
      output.include?("left:caller-payload")
  end
  failures
end

# The runtime half is reached by `exec`, so its redirect needs its own probe:
# the static half must succeed first for the exec to happen at all.
def runtime_stdin_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  with_contract_copy(runtime: STDIN_PROBE, wrapper: wrapper_source) do |contract, copy_root|
    stdout, stderr, status = Open3.capture3(
      {
        "PLATFORM_CONTRACT_REPO_DIR" => copy_root,
        "PLATFORM_CONTRACT_VAULT_FILE" => File.join(copy_root, "vault.yml"),
        "PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" => File.join(copy_root, "vault-password"),
        "PLATFORM_DOCKER_ROOT" => File.join(copy_root, "docker")
      },
      "/bin/sh", "-c", "#{contract.shellescape} run; printf 'left:'; cat",
      stdin_data: "caller-payload\n"
    )
    output = stdout + stderr
    # The probing shell's own status is `cat`'s, not the probe's, so it says
    # nothing here. The probe's marker appearing IS the proof that the exec was
    # reached; and run mode must not have printed the static success line, which
    # is what exiting at the mode gate would look like.
    failures << "runtime stdin: the runtime program was handed the caller's input: " \
                "#{output.strip.inspect}" unless output.include?('probe read ""')
    failures << "runtime stdin: the caller's input did not survive the contract: " \
                "#{output.strip.inspect}" unless output.include?("left:caller-payload")
    failures << "runtime stdin: run mode exited at the static gate instead of exec'ing: " \
                "#{output.strip.inspect}" if output.include?(SUCCESS_LINE)
  end
  failures
end

# The run-mode environment contract. Each name is refused with the WRAPPER'S OWN
# message, and that is what is asserted -- never the shell's own wording, which
# differs between bash ("parameter null or not set") and dash ("parameter not
# set or null"), and never the line number, which any edit to this file moves.
REQUIRED_RUN_ENV = %w[
  PLATFORM_CONTRACT_VAULT_FILE
  PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
  PLATFORM_DOCKER_ROOT
].freeze

def run_env_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  with_contract_copy(wrapper: wrapper_source) do |contract, copy_root|
    full = {
      "PLATFORM_CONTRACT_REPO_DIR" => copy_root,
      "PLATFORM_CONTRACT_VAULT_FILE" => File.join(copy_root, "vault.yml"),
      "PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" => File.join(copy_root, "vault-password"),
      "PLATFORM_DOCKER_ROOT" => File.join(copy_root, "docker"),
      "PLATFORM_MAC_VAULT_FILE" => nil,
      "PLATFORM_MAC_VAULT_PASSWORD_FILE" => nil
    }
    REQUIRED_RUN_ENV.each do |name|
      # Set to "" rather than deleted: ${VAR:?} refuses null as well as unset,
      # and a deleted key would pass silently for a developer who exports it.
      stdout, stderr, status = Open3.capture3(full.merge(name => ""), contract, "run")
      output = stdout + stderr
      failures << "run env: #{name} unset was accepted" if status.success?
      failures << "run env: #{name} unset was not refused with the wrapper's own message: " \
                  "#{output.strip.inspect}" unless output.include?("#{name} is required")
    end

    # The Mac fallback branch, which nothing else in the suite reaches:
    # tests/mac/run.sh exports PLATFORM_MAC_VAULT_FILE, and the `:=` pair above
    # the `:?` pair is what lets it stand in for the contract names.
    stdout, stderr, status = Open3.capture3(
      full.merge("PLATFORM_CONTRACT_VAULT_FILE" => nil,
                 "PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" => nil,
                 "PLATFORM_MAC_VAULT_FILE" => File.join(copy_root, "vault.yml"),
                 "PLATFORM_MAC_VAULT_PASSWORD_FILE" => File.join(copy_root, "vault-password"),
                 "PLATFORM_DOCKER_ROOT" => ""),
      contract, "run"
    )
    output = stdout + stderr
    failures << "run env: the Mac vault fallback did not satisfy the contract names: " \
                "#{output.strip.inspect}" unless output.include?("PLATFORM_DOCKER_ROOT is required")
    failures << "run env: the Mac fallback run was accepted" if status.success?
  end
  failures
end

def wrapper_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  with_contract_copy(wrapper: wrapper_source) do |contract, copy_root|
    %w[verify drift notify --platform].each do |mode|
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => ROOT }, contract, mode
      )
      failures << "wrapper: mode #{mode} was accepted" if status.success?
      failures << "wrapper: mode #{mode} was refused with exit #{status.exitstatus}, wanted 2" unless
        status.exitstatus == 2
      failures << "wrapper: mode #{mode} was refused without its diagnostic" unless
        (stdout + stderr).include?(MODE_REFUSAL)
    end

    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => ROOT }, contract, "static"
    )
    failures << "wrapper: static mode failed against this repository: #{(stdout + stderr).strip}" unless
      status.success?
    failures << "wrapper: static mode did not report the property it proved" unless
      stdout.include?(SUCCESS_LINE)

    # The static half runs unconditionally, so run mode must be refused by it
    # before the runtime half is reached at all.
    FileUtils.rm(File.join(copy_root, "services/seerr/compose.mac.yml"))
    stdout, stderr, status = Open3.capture3(
      {
        "PLATFORM_CONTRACT_REPO_DIR" => copy_root,
        "PLATFORM_CONTRACT_VAULT_FILE" => File.join(copy_root, "vault.yml"),
        "PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" => File.join(copy_root, "vault-password"),
        "PLATFORM_DOCKER_ROOT" => File.join(copy_root, "docker")
      },
      contract, "run"
    )
    failures << "wrapper: run mode passed against a broken repository" if status.success?
    failures << "wrapper: run mode did not run the static half first" unless
      (stdout + stderr).include?("missing services/seerr/compose.mac.yml")
  end

  # The branch every deployment actually takes: PLATFORM_CONTRACT_REPO_DIR unset,
  # so the programs and the inspected tree both come from the script's own
  # checkout. That is the only path in production.
  with_contract_copy do |contract, copy_root|
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => nil }, contract, "static"
    )
    failures << "wrapper: static mode failed with no repository named: #{(stdout + stderr).strip}" unless
      status.success?
    failures << "wrapper: static mode did not report the property it proved" unless
      stdout.include?(SUCCESS_LINE)

    FileUtils.rm(File.join(copy_root, "services/seerr/compose.mac.yml"))
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => nil }, contract, "static"
    )
    failures << "wrapper: with no repository named, static mode inspected some other tree" if
      status.success?
    failures << "wrapper: with no repository named, static mode did not report the broken tree" unless
      (stdout + stderr).include?("missing services/seerr/compose.mac.yml")
  end
  failures
end

# The two-roots property, stated as an OUTCOME rather than as the wrapper's
# text. These are the invariant rows: a before/after capture diff can only show
# differences, so the property that must stay identical is invisible in it. They
# are asserted here instead, and they are what would have caught #251's defect.
def two_roots_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  with_contract_copy(wrapper: wrapper_source) do |contract|
    Dir.mktmpdir("nas-platform-seerr-tworoots.") do |raw|
      inspected = File.realpath(raw)
      build_fixture_repository(inspected)
      FileUtils.rm_rf(File.join(inspected, "tests", "contracts"))
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => inspected }, contract, "static"
      )
      failures << "two roots: an inspected tree with no tests/contracts was refused, so a " \
                  "program is being resolved from it: #{(stdout + stderr).strip}" unless status.success?
      failures << "two roots: the program did not report the property it proved" unless
        stdout.include?(SUCCESS_LINE)
    end

    # The other direction. The inspected tree's own flatten_tasks is what the
    # static program must use, so a tree whose policy_support.rb refuses to load
    # has to take the contract down with it. Reading the checkout's copy instead
    # would pass here, silently.
    Dir.mktmpdir("nas-platform-seerr-support.") do |raw|
      inspected = File.realpath(raw)
      build_fixture_repository(inspected)
      File.write(File.join(inspected, "tests", "policy_support.rb"),
                 %(raise "inspected tree policy_support reached"\n))
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => inspected }, contract, "static"
      )
      failures << "two roots: policy_support was not required out of the inspected tree" if
        status.success?
      failures << "two roots: policy_support was required from somewhere else: " \
                  "#{(stdout + stderr).strip.inspect}" unless
        (stdout + stderr).include?("inspected tree policy_support reached")
    end
  end
  failures
end

# --- planted regressions ---------------------------------------------------

PROGRAM_MUTATIONS = [
  {
    label: "a declared file no longer having to exist",
    program: :static,
    from: 'failures << "missing #{relative}" unless File.file?(File.join(root, relative))',
    to: "failures << relative if false",
    rows: ["a declared file that is gone"],
    detects: "refused for the wrong reason"
  },
  {
    label: "the shared control network check",
    program: :static,
    # The whole condition, not one clause: the network is named `media-control`
    # with a hyphen and the assertion also requires the top-level network to be
    # declared external, so a plant on either half alone leaves the other live.
    from: 'Array(service["networks"]).include?("media-control") &&
    compose.dig("networks", "media-control", "external") == true',
    to: "true",
    rows: ["a seat off the shared control network"]
  },
  {
    label: "the platform identity check",
    program: :static,
    from: 'service["user"] == "${NAS_UID:?}:${NAS_GID:?}"',
    to: "true",
    rows: ["a container that is not the platform identity"]
  },
  {
    label: "the init reaper check",
    program: :static,
    from: 'service["init"] == true',
    to: "true",
    rows: ["a container that reaps nothing npm start forks"]
  },
  {
    label: "the exactly-once CPU set read",
    program: :static,
    # Restores the substring search the line-oriented read replaced, which is
    # the form a second live assignment satisfies while only one may exist.
    from: 'env_assignments.select { |name, _value| name == "PLATFORM_CONTAINER_CPUSET" } ==
      [["PLATFORM_CONTAINER_CPUSET", "{{ platform_effective_container_cpuset }}"]]',
    to: 'File.read(File.join(root, "roles/seerr/templates/env.j2"))
      .include?("PLATFORM_CONTAINER_CPUSET={{ platform_effective_container_cpuset }}")',
    rows: ["a CPU set rendered twice"]
  },
  {
    label: "the healthy-container check",
    program: :runtime,
    from: 'state.strip == "healthy"',
    to: "true",
    rows: ["a container Docker calls unhealthy"]
  },
  {
    label: "the anonymous refusal check",
    program: :runtime,
    from: 'request("/api/v1/user").code == "401"',
    to: "true",
    rows: ["a protected route served anonymously"]
  },
  {
    label: "the foreign-key refusal check",
    program: :runtime,
    from: 'request("/api/v1/user", key: "0" * 32).code == "403"',
    to: "true",
    rows: ["a key the platform never authored being accepted"]
  },
  {
    label: "the exact-ADMIN owner check",
    program: :runtime,
    from: 'owner["permissions"] == 2',
    to: "true",
    rows: ["an owner holding more than ADMIN"]
  },
  {
    label: "the household permission split check",
    program: :runtime,
    from: 'row["permissions"] == 160',
    to: "true",
    rows: ["a household identity holding the wrong permissions"]
  },
  {
    label: "the request quota check",
    program: :runtime,
    from: 'row["movieQuotaLimit"].nil? && row["tvQuotaLimit"].nil?',
    to: "true",
    rows: ["a household identity carrying a request quota"]
  },
  {
    label: "the impersonated identity check",
    program: :runtime,
    from: 'as_user["id"] == row.fetch("id") && as_user["permissions"] == 160',
    to: "true",
    rows: ["an impersonated identity Seerr does not agree with"]
  },
  {
    label: "the setup wizard check",
    program: :runtime,
    from: 'public_settings["initialized"] == true',
    to: "true",
    rows: ["a visitor still sent to the setup wizard"]
  },
  {
    label: "the local login refusal",
    program: :runtime,
    from: 'public_settings["localLogin"] == false',
    to: "true",
    rows: ["a local password login path left open"]
  },
  {
    label: "the silent-user-creation refusal",
    program: :runtime,
    from: 'public_settings["newPlexLogin"] == false',
    to: "true",
    rows: ["a policy that would create any Jellyfin user who signs in"]
  },
  {
    label: "the media server type check",
    program: :runtime,
    from: 'public_settings["mediaServerType"] == 2',
    to: "true",
    rows: ["a media server that is not Jellyfin"]
  },
  {
    label: "the served API key check",
    program: :runtime,
    from: 'main["apiKey"] == key',
    to: "true",
    rows: ["a served API key that is not the vault's"]
  },
  {
    label: "the default permissions check",
    program: :runtime,
    from: 'main["defaultPermissions"] == 0',
    to: "true",
    rows: ["a newly discovered user inheriting request permissions"]
  },
  {
    label: "the named Jellyfin server check",
    program: :runtime,
    from: 'jellyfin["ip"] == "jellyfin" && jellyfin["port"] == 8096',
    to: "true",
    rows: ["a Jellyfin server the platform does not name"]
  },
  {
    label: "the post-bootstrap takeover refusal",
    program: :runtime,
    from: 'refusal.code == "500" && refusal.body.include?("already configured")',
    to: "true",
    rows: ["a foreign Jellyfin server accepted after bootstrap"]
  },
  {
    label: "the no-transport arr refusal",
    program: :runtime,
    from: "rows.empty?",
    to: "true",
    rows: ["an arr declared on a host with no transport"]
  },
  {
    label: "the arr's own API key check",
    program: :runtime,
    from: 'row["apiKey"] == vault.fetch("vault_arr_#{kind}_api_key")',
    to: "true",
    rows: ["an arr server that does not carry that arr's own key"]
  },
  {
    label: "the service alias check",
    program: :runtime,
    from: 'row["hostname"] == kind',
    to: "true",
    rows: ["an arr server not addressed by service alias"]
  },
  {
    label: "the ntfy agent enabled check",
    program: :runtime,
    from: 'ntfy["enabled"] == true',
    to: "true",
    rows: ["an ntfy agent that is disabled"]
  },
  {
    label: "the ntfy authentication check",
    program: :runtime,
    from: 'ntfy.dig("options", "authMethodToken") == true &&',
    to: "true ||",
    rows: ["an ntfy agent publishing without authenticating"]
  },
  {
    label: "the persisted database check",
    program: :runtime,
    from: "File.file?(DATABASE) && File.size?(DATABASE)",
    to: "true",
    rows: ["state that did not land in the declared config root"]
  }
].freeze

# The wrapper's own regressions. Each is a line that changes no outcome today,
# which is exactly why it needs a plant rather than a passing contract.
WRAPPER_MUTATIONS = [
  {
    label: "a dropped stdin redirect on the static half",
    from: 'ruby "$static_program" "$repo_dir" </dev/null',
    to: 'ruby "$static_program" "$repo_dir"',
    layer: :stdin
  },
  {
    label: "a dropped stdin redirect on the runtime half",
    from: 'exec ruby "$runtime_program" </dev/null',
    to: 'exec ruby "$runtime_program"',
    layer: :runtime_stdin
  },
  {
    label: "the static program resolved from the inspected tree",
    from: "static_program=$contract_repo_dir/tests/contracts/seerr-static.rb",
    to: "static_program=$repo_dir/tests/contracts/seerr-static.rb",
    layer: :two_roots
  },
  {
    label: "the inspected-tree export rerooted to the checkout",
    from: "PLATFORM_CONTRACT_REPO_DIR=$repo_dir",
    to: "PLATFORM_CONTRACT_REPO_DIR=$contract_repo_dir",
    layer: :two_roots
  },
  {
    label: "the mode guard",
    from: "  static|run) ;;",
    to: "  static|run|verify|drift|notify|--platform) ;;",
    layer: :wrapper
  },
  {
    label: "the vault-file requirement",
    from: ': "${PLATFORM_CONTRACT_VAULT_FILE:?PLATFORM_CONTRACT_VAULT_FILE is required}"',
    to: ': "${PLATFORM_CONTRACT_VAULT_FILE:=}"',
    layer: :run_env
  },
  {
    label: "the docker-root requirement",
    from: ': "${PLATFORM_DOCKER_ROOT:?PLATFORM_DOCKER_ROOT is required}"',
    to: ': "${PLATFORM_DOCKER_ROOT:=}"',
    layer: :run_env
  }
].freeze

def plant(source, mutation, occurrences: 1)
  from = mutation.fetch(:from)
  found = source.scan(from).length
  abort "self-test could not plant #{mutation.fetch(:label)}: expected #{occurrences} " \
       "match(es) of #{from.inspect}, found #{found}" unless found == occurrences

  planted = occurrences == 1 ? source.sub(from, mutation.fetch(:to)) : source.gsub(from, mutation.fetch(:to))
  abort "self-test planted nothing for #{mutation.fetch(:label)}" if planted == source
  planted
end

def rows_named(rows, names)
  selected = rows.select { |row| names.include?(row.fetch(:name)) }
  abort "self-test names a row that does not exist: #{names.inspect}" unless
    selected.length == names.length

  selected
end

if ARGV.include?("--self-test")
  mismatches = []

  # Every plant is prepared on the main thread, before the pool. `plant` and
  # `rows_named` abort with a sentence naming what they could not find, and an
  # abort inside a worker raises SystemExit there: the thread dies without
  # recording its result and the pool's own `collected.fetch` then reports a
  # KeyError instead of that sentence.
  program_cases = PROGRAM_MUTATIONS.map do |mutation|
    canonical = mutation.fetch(:program) == :static ? STATIC_PROGRAM : RUNTIME_PROGRAM
    rows = mutation.fetch(:program) == :static ? STATIC_ROWS : RUNTIME_ROWS
    [mutation, plant(File.read(canonical), mutation), rows_named(rows, mutation.fetch(:rows))]
  end
  wrapper_cases = WRAPPER_MUTATIONS.map { |mutation| [mutation, plant(File.read(CONTRACT), mutation)] }

  in_parallel_cases(mismatches, program_cases) do |(mutation, source, rows), collected|
    Dir.mktmpdir("nas-platform-seerr-mutant.") do |directory|
      name = mutation.fetch(:program) == :static ? "seerr-static.rb" : "seerr-runtime.rb"
      path = File.join(directory, name)
      File.write(path, source)
      caught = if mutation.fetch(:program) == :static
                 static_failures(path, rows)
               else
                 runtime_failures(path, rows)
               end
      detects = mutation.fetch(:detects, "accepted what it must refuse")
      if caught.empty?
        collected << "removing #{mutation.fetch(:label)} was accepted"
      elsif !caught.all? { |failure| failure.include?(detects) }
        collected << "removing #{mutation.fetch(:label)} was caught by the wrong assertion: " \
                     "#{caught.join(' | ')}"
      end
    end
  end

  in_parallel_cases(mismatches, wrapper_cases) do |(mutation, source), collected|
    caught = case mutation.fetch(:layer)
             when :stdin then stdin_failures(wrapper_source: source)
             when :runtime_stdin then runtime_stdin_failures(wrapper_source: source)
             when :two_roots then two_roots_failures(wrapper_source: source)
             when :run_env then run_env_failures(wrapper_source: source)
             else wrapper_failures(wrapper_source: source)
             end
    collected << "removing #{mutation.fetch(:label)} was accepted" if caught.empty?
  end

  planted = PROGRAM_MUTATIONS.length + WRAPPER_MUTATIONS.length
  unless mismatches.empty?
    mismatches.each { |mismatch| warn "FAIL self-test: #{mismatch}" }
    abort "#{mismatches.length} self-test mismatch(es) of #{planted} planted regressions"
  end

  puts "seerr contract: self-test detects #{planted} planted regressions"
  exit
end

failures = static_failures(STATIC_PROGRAM) + runtime_failures(RUNTIME_PROGRAM) +
           wrapper_failures + run_env_failures + stdin_failures + runtime_stdin_failures +
           two_roots_failures
unless failures.empty?
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} Seerr contract violation(s)"
end

puts "seerr contract: #{STATIC_ROWS.length} static and #{RUNTIME_ROWS.length} runtime properties " \
     "hold, the run-mode environment contract refuses each name with the wrapper's own message, " \
     "and both programs come from the checkout with an empty stdin"
