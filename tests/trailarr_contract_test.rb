#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Behaviour of the Trailarr service contract's two Ruby programs.
#
# Until #147 both lived in `<<'RUBY'` heredocs inside tests/contracts/trailarr.sh.
# `sh -n` reads a quoted heredoc as opaque text, so the static half was only
# ever executed by `tests/contracts/trailarr.sh static` and the runtime half only
# by an integration lane with Docker, a converged Trailarr and a real vault.
# tests/contracts/trailarr-static.rb and tests/contracts/trailarr-runtime.rb are
# files now, so both are reachable here.
#
# Three layers -- static, runtime and wrapper -- for the same reasons
# tests/seerr_contract_test.rb states, and structured the same way. The
# duplication between the two files is deliberate for the length of #147: a
# shared helper is named by no wrapper, so policy_mutation_support.rb's
# derivation cannot reach it and it would need an explicit BASE_FIXTURE_PATHS
# entry -- a change to the mutation harness's contract that does not belong
# inside a contract extraction. It also cannot be derived honestly from two
# examples when the remaining contracts are known to diverge. The consolidation
# lands as its own PR after the last contract.
#
# Run with --self-test to plant a regression in each program and in the wrapper.

require "etc"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "shellwords"
require "tmpdir"
require "yaml"

require_relative "http_fixture_support"
require_relative "policy_support"

include TestScaffold

ROOT = File.expand_path("..", __dir__)
# The prefix every refusal this file judges has to carry. Matching the
# fragment alone accepted a backtrace or an echoed argument as a refusal.
DIAGNOSTIC_PREFIX = "Trailarr contract failed: "
CONTRACT = File.join(ROOT, "tests", "contracts", "trailarr.sh")
STATIC_PROGRAM = File.join(ROOT, "tests", "contracts", "trailarr-static.rb")
RUNTIME_PROGRAM = File.join(ROOT, "tests", "contracts", "trailarr-runtime.rb")

SUCCESS_LINE = "trailarr static contract: declared trailer writer ownership holds"
MODE_REFUSAL = "trailarr contract accepts only static or run"

# Exactly what the static program reads, plus the shared flatten_tasks it
# requires through PLATFORM_CONTRACT_REPO_DIR. Two things about this list are
# findings rather than bookkeeping:
#
#   * roles/arr/defaults/main.yml is a CROSS-ROLE read (trailarr-static.rb:133)
#     that the program's own `required` list never checks, so an absent Arr
#     defaults file is a crash rather than a diagnostic. Found empirically --
#     the fixture without it failed every row with a Psych sysopen trace, not by
#     reading the program. Recorded, not fixed: this change moves code.
#   * trailarr-static.rb:207 reads the role's task files through a glob
#     (`Dir[roles/trailarr/tasks/*.yml]`) rather than a stated list, so a task
#     file added to the role enters scope without an edit. That is the good
#     shape, and it happens to hold exactly the five files `required` names
#     today -- checked, so the fixture is not quietly narrower than production.
FIXTURE_FILES = %w[
  roles/trailarr/defaults/main.yml
  roles/trailarr/meta/argument_specs.yml
  roles/trailarr/tasks/main.yml
  roles/trailarr/tasks/reconcile_env.yml
  roles/trailarr/tasks/reconcile_profiles.yml
  roles/trailarr/tasks/reconcile_connections.yml
  roles/trailarr/tasks/reconcile_monitoring.yml
  roles/trailarr/templates/env.j2
  roles/arr/defaults/main.yml
  services/trailarr/compose.yml
  services/trailarr/compose.mac.yml
  services/trailarr/compose.integration.yml
  tests/policy_support.rb
].freeze

CASE_WORKER_LIMIT = Integer(
  ENV.fetch("TRAILARR_CONTRACT_CASE_WORKERS") { [Etc.nprocessors, 8].min.to_s }
)

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
    break: ->(root) { FileUtils.rm(File.join(root, "services/trailarr/compose.mac.yml")) },
    expects: "missing services/trailarr/compose.mac.yml"
  },
  {
    name: "a seat off the shared control network",
    break: lambda { |root|
      edit_yaml(root, "services/trailarr/compose.yml") do |d|
        d["services"]["trailarr"]["networks"] = ["default"]
      end
    },
    expects: "Trailarr must join the shared media control network"
  },
  {
    name: "a control network that is not the external one",
    break: lambda { |root|
      edit_yaml(root, "services/trailarr/compose.yml") do |d|
        d["networks"]["media-control"] = { "external" => true }
      end
    },
    expects: "the shared media control network must be the external one"
  },
  {
    name: "a container user overriding the image's own",
    break: lambda { |root|
      edit_yaml(root, "services/trailarr/compose.yml") do |d|
        d["services"]["trailarr"]["user"] = "1000:100"
      end
    },
    expects: "Trailarr must not override the container user"
  },
  {
    name: "an identity not taken as PUID",
    break: lambda { |root|
      edit_yaml(root, "services/trailarr/compose.yml") do |d|
        d["services"]["trailarr"]["environment"]["PUID"] = "1000"
      end
    },
    expects: "Trailarr must take the platform identity as PUID"
  },
  {
    name: "an unsupported UMASK declared anyway",
    break: lambda { |root|
      edit_yaml(root, "services/trailarr/compose.yml") do |d|
        d["services"]["trailarr"]["environment"]["UMASK"] = "0002"
      end
    },
    expects: "Trailarr must not declare an unsupported UMASK"
  },
  {
    name: "a published web UI port that drifted",
    break: lambda { |root|
      edit_yaml(root, "services/trailarr/compose.yml") do |d|
        d["services"]["trailarr"]["ports"] = ["7890:7889"]
      end
    },
    expects: "Trailarr must publish the catalog web UI port"
  },
  {
    name: "a health probe using a tool the image does not ship",
    break: lambda { |root|
      mutate_text(root, "services/trailarr/compose.yml",
                  "curl --fail --silent --show-error", "wget -q -O -")
    },
    expects: "Trailarr must probe its unauthenticated status route with curl"
  },
  {
    # The relation the contract exists to hold, planted on the arr's side so
    # only the mount-to-root-folder comparison can see it: the Compose mount
    # still reads as declared, and Radarr's root folder has moved out from
    # under it.
    name: "an arr root folder the Trailarr mount no longer matches",
    break: lambda { |root|
      mutate_text(root, "roles/arr/defaults/main.yml",
                  "arr_radarr_root_folder: /data/media/Movies",
                  "arr_radarr_root_folder: /data/media/Films")
    },
    expects: "must be mounted at arr_radarr_root_folder"
  },
  {
    name: "a CPU set rendered twice",
    break: lambda { |root|
      mutate_text(root, "roles/trailarr/templates/env.j2",
                  "PLATFORM_CONTAINER_CPUSET={{ platform_effective_container_cpuset }}",
                  "PLATFORM_CONTAINER_CPUSET={{ platform_effective_container_cpuset }}\n" \
                  "PLATFORM_CONTAINER_CPUSET=0-3")
    },
    expects: "CPU set"
  }
].freeze

def static_failures(program, rows = STATIC_ROWS)
  failures = []
  in_parallel_cases(failures, rows) do |row, collected|
    Dir.mktmpdir("nas-platform-trailarr-static.") do |raw|
      root = File.realpath(raw)
      build_fixture_repository(root)
      row.fetch(:break).call(root)
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => root }, RbConfig.ruby, program, root
      )
      collected.concat(judge("static: #{row.fetch(:name)}", row.fetch(:expects), stdout, stderr, status,
                             prefix: DIAGNOSTIC_PREFIX))
    end
  end
  failures
end

# --- runtime layer ---------------------------------------------------------
#
# The runtime half takes NO arguments: every input arrives in the environment.
# So the sandbox is environment plus PATH stubs plus one HTTP fixture plus the
# application's own /config/.env, and each row moves exactly one of them.

API_KEY = "trailarr-contract-api-key-0000000"
USERNAME = "nasadmin"
PASSWORD = "trailarr-contract-password"
DEFAULT_SETTINGS = {
  "webui_disable_auth" => false, "create_missing_folders" => false,
  "delete_trailer_connection" => false, "delete_trailer_media" => false,
  "update_ytdlp" => false, "ytdlp_nightly" => false,
  "monitor_enabled" => false, "downloads_enabled" => false
}.freeze
PROFILE_FIELDS = {
  "folder_enabled" => true, "folder_name" => "Trailers",
  "custom_folder" => "{media_folder}", "file_format" => "mp4",
  "video_format" => "h264", "audio_format" => "aac"
}.freeze

RUNTIME_DEFAULTS = {
  health: "healthy",
  inspect_ok: true,
  vault_ok: true,
  status_body: '{"status":"healthy"}',
  anonymous_settings_code: 401,
  default_admin_code: 401,
  vault_admin_code: 200,
  settings_username: USERNAME,
  settings_overrides: {},
  application_env: nil,
  hand_written: nil,
  profile_ids: [1, 2],
  profile_overrides: {},
  arrs: false,
  connections: nil,
  database: true
}.freeze

def vault_document
  {
    "vault_trailarr_api_key" => API_KEY,
    "vault_trailarr_admin_username" => USERNAME,
    "vault_trailarr_admin_password" => PASSWORD
  }
end

def build_runtime_sandbox(root, options)
  bin = File.join(root, "bin")
  FileUtils.mkdir_p(bin)
  docker_root = File.join(root, "docker")
  config = File.join(docker_root, "trailarr", "config")
  FileUtils.mkdir_p(config)
  File.write(File.join(config, "trailarr.db"), "sqlite-fixture") if options.fetch(:database)

  lines = options.fetch(:application_env) || ["API_KEY='#{API_KEY}'", "APP_DATA_DIR='/config'"]
  lines += Array(options.fetch(:hand_written)) if options.fetch(:hand_written)
  File.write(File.join(config, ".env"), "#{lines.join("\n")}\n") unless lines.empty?

  File.write(File.join(bin, "docker"), <<~SH)
    #!/bin/sh
    #{options.fetch(:inspect_ok) ? '' : 'exit 1'}
    printf '%s\\n' '#{options.fetch(:health)}'
  SH
  File.write(File.join(bin, "ansible-vault"), <<~SH)
    #!/bin/sh
    #{options.fetch(:vault_ok) ? '' : 'echo "decryption failed" >&2; exit 1'}
    cat <<'YAML'
    #{YAML.dump(vault_document).chomp}
    YAML
  SH
  %w[docker ansible-vault].each { |name| File.chmod(0o755, File.join(bin, name)) }
  File.write(File.join(root, "vault.yml"), "encrypted\n")
  File.write(File.join(root, "vault-password"), "fixture\n")
  [bin, docker_root]
end

def connection_rows(options)
  return options.fetch(:connections) if options.fetch(:connections)
  return [] unless options.fetch(:arrs)

  [{ "name" => "Radarr", "url" => "http://radarr:7878", "path_mappings" => [],
     "monitor_new_media" => false },
   { "name" => "Sonarr", "url" => "http://sonarr:8989", "path_mappings" => [],
     "monitor_new_media" => false }]
end

def runtime_responder(options)
  lambda do |method, target, headers, body|
    key = headers["x-api-key"]
    path = target.split("?").first
    if method == "POST" && path == "/api/v1/auth/login"
      parsed = begin
        JSON.parse(body)
      rescue JSON::ParserError
        {}
      end
      code = if parsed["username"] == USERNAME && parsed["password"] == PASSWORD
               options.fetch(:vault_admin_code)
             else
               options.fetch(:default_admin_code)
             end
      next [code, "{}"]
    end

    case path
    when "/status" then [200, options.fetch(:status_body)]
    when "/api/v1/settings/"
      next [options.fetch(:anonymous_settings_code), "{}"] if key.nil?
      next [403, "{}"] unless key == API_KEY

      [200, JSON.generate(DEFAULT_SETTINGS
        .merge("webui_username" => options.fetch(:settings_username))
        .merge(options.fetch(:settings_overrides)))]
    when "/api/v1/trailerprofiles/"
      rows = options.fetch(:profile_ids).map do |id|
        PROFILE_FIELDS.merge("id" => id).merge(options.fetch(:profile_overrides))
      end
      [200, JSON.generate(rows)]
    when "/api/v1/connections/" then [200, JSON.generate(connection_rows(options))]
    else [404, "{}"]
    end
  end
end

RUNTIME_ROWS = [
  { name: "a converged Trailarr", given: {}, expects: nil },
  {
    name: "a status route that does not answer JSON",
    given: { status_body: "not json" },
    expects: "Trailarr status route did not answer JSON"
  },
  {
    name: "a status route reporting an unhealthy application",
    given: { status_body: '{"status":"degraded"}' },
    expects: "Trailarr did not report a healthy status"
  },
  {
    name: "a container Docker cannot inspect",
    given: { inspect_ok: false },
    expects: "the Trailarr container could not be inspected"
  },
  {
    name: "a container Docker calls unhealthy",
    given: { health: "unhealthy" },
    expects: "the Trailarr container is not healthy"
  },
  {
    name: "a vault that cannot be read",
    given: { vault_ok: false },
    expects: "encrypted vault could not be read"
  },
  {
    name: "a protected route served anonymously",
    given: { anonymous_settings_code: 200 },
    expects: "Trailarr served a protected route to an anonymous request"
  },
  {
    name: "the published default administrator still accepted",
    given: { default_admin_code: 200 },
    expects: "Trailarr accepted the published default administrator"
  },
  {
    name: "the vault-authored administrator refused",
    given: { vault_admin_code: 401 },
    expects: "Trailarr refused the vault-authored administrator"
  },
  {
    name: "a served administrator name that is not the vault's",
    given: { settings_username: "admin" },
    expects: "Trailarr does not serve the vault-authored administrator name"
  },
  {
    name: "authentication disabled in the served settings",
    given: { settings_overrides: { "webui_disable_auth" => true } },
    expects: "Trailarr does not report webui_disable_auth as the platform declares it"
  },
  {
    name: "monitoring switched on in the served settings",
    given: { settings_overrides: { "monitor_enabled" => true } },
    expects: "Trailarr does not report monitor_enabled as the platform declares it"
  },
  {
    name: "no application environment written at all",
    given: { application_env: [] },
    expects: "Trailarr did not write its own application environment"
  },
  {
    name: "an application API key that is not the vault's",
    given: { application_env: ["API_KEY='0000'"] },
    expects: "Trailarr does not carry the vault-authored API key in its own environment"
  },
  {
    name: "an unquoted application API key",
    given: { application_env: ["API_KEY=#{API_KEY}"] },
    expects: "Trailarr does not carry the vault-authored API key in its own environment"
  },
  {
    name: "a hand-written WEBUI_PASSWORD in the application environment",
    given: { hand_written: ["WEBUI_PASSWORD='typed-by-hand'"] },
    expects: "Trailarr's application environment carries a hand-written WEBUI_PASSWORD"
  },
  {
    name: "a hand-written MONITOR_ENABLED in the application environment",
    given: { hand_written: ["MONITOR_ENABLED='True'"] },
    expects: "Trailarr's application environment carries a hand-written MONITOR_ENABLED"
  },
  {
    name: "only one seeded trailer profile",
    given: { profile_ids: [1] },
    expects: "Trailarr does not hold both seeded trailer profiles"
  },
  {
    name: "a trailer profile that writes the wrong container",
    given: { profile_overrides: { "file_format" => "mkv" } },
    expects: "does not declare file_format"
  },
  {
    name: "a trailer profile that does not write beside the media",
    given: { profile_overrides: { "custom_folder" => "/trailers" } },
    expects: "does not declare custom_folder"
  },
  {
    name: "an arr connection declared with no transport enabled",
    given: { arrs: false, connections: [{ "name" => "Radarr", "url" => "http://radarr:7878" }] },
    expects: "Trailarr declared an arr connection with no transport enabled"
  },
  {
    name: "a duplicated arr connection",
    given: { arrs: true, connections: [
      { "name" => "Radarr", "url" => "http://radarr:7878", "path_mappings" => [],
        "monitor_new_media" => false },
      { "name" => "Radarr", "url" => "http://radarr:7878", "path_mappings" => [],
        "monitor_new_media" => false },
      { "name" => "Sonarr", "url" => "http://sonarr:8989", "path_mappings" => [],
        "monitor_new_media" => false }
    ] },
    expects: "Trailarr does not hold exactly one Radarr connection"
  },
  {
    name: "an arr connection not addressed by service alias",
    given: { arrs: true, connections: [
      { "name" => "Radarr", "url" => "http://10.0.0.5:7878", "path_mappings" => [],
        "monitor_new_media" => false },
      { "name" => "Sonarr", "url" => "http://sonarr:8989", "path_mappings" => [],
        "monitor_new_media" => false }
    ] },
    expects: "the Trailarr Radarr connection is not addressed by service alias"
  },
  {
    name: "an arr connection declaring a path mapping",
    given: { arrs: true, connections: [
      { "name" => "Radarr", "url" => "http://radarr:7878",
        "path_mappings" => [{ "from" => "/data", "to" => "/media" }],
        "monitor_new_media" => false },
      { "name" => "Sonarr", "url" => "http://sonarr:8989", "path_mappings" => [],
        "monitor_new_media" => false }
    ] },
    expects: "the Trailarr Radarr connection declares a path mapping"
  },
  {
    name: "an arr connection monitoring new media before acceptance",
    given: { arrs: true, connections: [
      { "name" => "Radarr", "url" => "http://radarr:7878", "path_mappings" => [],
        "monitor_new_media" => true },
      { "name" => "Sonarr", "url" => "http://sonarr:8989", "path_mappings" => [],
        "monitor_new_media" => false }
    ] },
    expects: "the Trailarr Radarr connection monitors new media before acceptance"
  },
  {
    name: "state that did not land in the declared config root",
    given: { database: false },
    expects: "Trailarr did not persist its database in the declared config root"
  }
].freeze

def runtime_failures(program, rows = RUNTIME_ROWS)
  failures = []
  in_parallel_cases(failures, rows) do |row, collected|
    options = RUNTIME_DEFAULTS.merge(row.fetch(:given))
    Dir.mktmpdir("nas-platform-trailarr-runtime.") do |raw|
      root = File.realpath(raw)
      bin, docker_root = build_runtime_sandbox(root, options)
      HttpFixtureSupport.with_http_fixture(
        lambda do |port|
          stdout, stderr, status = Open3.capture3(
            {
              "PATH" => "#{bin}:#{ENV.fetch('PATH')}",
              "PLATFORM_TRAILARR_PORT" => port.to_s,
              "PLATFORM_TRAILARR_CONTAINER" => "fixture-trailarr",
              "PLATFORM_TRAILARR_ARRS" => options.fetch(:arrs).to_s,
              "PLATFORM_DOCKER_ROOT" => docker_root,
              "PLATFORM_CONTRACT_VAULT_FILE" => File.join(root, "vault.yml"),
              "PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" => File.join(root, "vault-password")
            },
            RbConfig.ruby, program
          )
          collected.concat(judge("runtime: #{row.fetch(:name)}", row.fetch(:expects), stdout, stderr, status,
                                 prefix: DIAGNOSTIC_PREFIX))
        end,
        &runtime_responder(options)
      )
    end
  end
  failures
end

# --- wrapper layer ---------------------------------------------------------

def with_contract_copy(static: File.read(STATIC_PROGRAM), runtime: File.read(RUNTIME_PROGRAM),
                       wrapper: File.read(CONTRACT))
  Dir.mktmpdir("nas-platform-trailarr-wrapper.") do |raw|
    root = File.realpath(raw)
    build_fixture_repository(root)
    contracts = File.join(root, "tests", "contracts")
    FileUtils.mkdir_p(contracts)
    wrapper_path = File.join(contracts, "trailarr.sh")
    File.write(wrapper_path, wrapper)
    File.chmod(0o755, wrapper_path)
    File.write(File.join(contracts, "trailarr-static.rb"), static)
    File.write(File.join(contracts, "trailarr-runtime.rb"), runtime)
    yield wrapper_path, root
  end
end

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

# The runtime half is reached by `exec`, so its redirect needs its own probe.
# The probing shell's own status is `cat`'s, not the probe's, so it says nothing
# here: the probe's marker appearing IS the proof the exec was reached, and the
# static success line must be absent or run mode exited at the mode gate.
def runtime_stdin_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  with_contract_copy(runtime: STDIN_PROBE, wrapper: wrapper_source) do |contract, copy_root|
    stdout, stderr, = Open3.capture3(
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
    failures << "runtime stdin: the runtime program was handed the caller's input: " \
                "#{output.strip.inspect}" unless output.include?('probe read ""')
    failures << "runtime stdin: the caller's input did not survive the contract: " \
                "#{output.strip.inspect}" unless output.include?("left:caller-payload")
    failures << "runtime stdin: run mode exited at the static gate instead of exec'ing: " \
                "#{output.strip.inspect}" if output.include?(SUCCESS_LINE)
  end
  failures
end

# Each name is refused with the WRAPPER'S OWN message, and that is what is
# asserted -- never the shell's own wording, which differs between bash
# ("parameter null or not set") and dash ("parameter not set or null"), and never
# the line number, which any edit to the wrapper moves.
REQUIRED_RUN_ENV = %w[
  PLATFORM_CONTRACT_VAULT_FILE
  PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
  PLATFORM_DOCKER_ROOT
].freeze

# Stands in for the runtime half throughout this helper, because every
# invocation here must end in a refusal by the wrapper *before* the exec that
# would reach it. Against an intact wrapper the stub is therefore never run, and
# substituting it changes nothing this helper observes: the wrapper's `:?` checks
# sit between the static program and the exec, so the real static half still runs
# unchanged on every row.
#
# A planted regression that drops one of the `:?` requirements is what makes the
# exec reachable, and against the shipped runtime program that meant a wait: no
# Trailarr is listening on the port, so it spent its whole readiness budget --
# 120 seconds, twice over -- proving what the row already knew. That was the
# entire floor of this file's self-test, 247s of it unmoved by widening the case
# pool, because concurrency overlaps waits without shortening them. #328 cut the
# budget to ten seconds for these rows; the stub deletes the wait instead, which
# is what the row is entitled to: reaching the runtime half at all is already the
# regression.
#
# It exits 0 deliberately, so a mutant that reaches it trips BOTH assertions
# below -- the wrapper accepted an environment it must refuse, and it did so
# without its own message -- and warns first, so the failure text says which
# happened rather than showing an empty capture.
RUNTIME_REFUSAL_STUB = <<~'STUB'
  warn "runtime stub reached: the wrapper did not refuse this environment"
  exit 0
STUB

def run_env_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  with_contract_copy(runtime: RUNTIME_REFUSAL_STUB, wrapper: wrapper_source) do |contract, copy_root|
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
    FileUtils.rm(File.join(copy_root, "services/trailarr/compose.mac.yml"))
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
      (stdout + stderr).include?("missing services/trailarr/compose.mac.yml")
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

    FileUtils.rm(File.join(copy_root, "services/trailarr/compose.mac.yml"))
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => nil }, contract, "static"
    )
    failures << "wrapper: with no repository named, static mode inspected some other tree" if
      status.success?
    failures << "wrapper: with no repository named, static mode did not report the broken tree" unless
      (stdout + stderr).include?("missing services/trailarr/compose.mac.yml")
  end
  failures
end

# The two-roots property, stated as an OUTCOME rather than as the wrapper's
# text. These are the invariant rows: a before/after capture diff can only show
# differences, so a property that must stay identical is invisible in it. They
# are asserted here instead, and they are what would have caught #251's defect.
def two_roots_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  with_contract_copy(wrapper: wrapper_source) do |contract|
    Dir.mktmpdir("nas-platform-trailarr-tworoots.") do |raw|
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

    Dir.mktmpdir("nas-platform-trailarr-support.") do |raw|
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
    label: "the shared control network membership check",
    program: :static,
    from: 'Array(service["networks"]) == %w[default media-control]',
    to: "true",
    rows: ["a seat off the shared control network"]
  },
  {
    label: "the external control network check",
    program: :static,
    from: 'compose.dig("networks", "media-control") ==
      { "external" => true, "name" => "${PLATFORM_MEDIA_NETWORK:?}" }',
    to: "true",
    rows: ["a control network that is not the external one"]
  },
  {
    label: "the container user refusal",
    program: :static,
    from: 'failures << "Trailarr must not override the container user" if service.key?("user")',
    to: 'failures << "Trailarr must not override the container user" if false',
    rows: ["a container user overriding the image's own"]
  },
  {
    # The whole statement, because `service.dig("environment", name) == expected`
    # appears three times in this program -- the identity pair, the required
    # credentials and the pinned-off switches all share that shape. The
    # occurrence count caught it; a bare `sub` would have planted in whichever
    # came first.
    label: "the platform identity environment check",
    program: :static,
    from: 'failures << "Trailarr must take the platform identity as #{name}" unless
      service.dig("environment", name) == expected',
    to: 'failures << "Trailarr must take the platform identity as #{name}" if false',
    rows: ["an identity not taken as PUID"]
  },
  {
    label: "the unsupported UMASK refusal",
    program: :static,
    from: 'service.fetch("environment", {}).key?("UMASK")',
    to: "false",
    rows: ["an unsupported UMASK declared anyway"]
  },
  {
    label: "the published web UI port check",
    program: :static,
    from: 'Array(service["ports"]) == ["7889:7889"]',
    to: "true",
    rows: ["a published web UI port that drifted"]
  },
  {
    label: "the arr root folder mount comparison",
    program: :static,
    from: 'library_mounts.include?("#{mount_source}:#{arr_defaults[arr_key]}")',
    to: "true",
    rows: ["an arr root folder the Trailarr mount no longer matches"]
  },
  {
    label: "the curl health probe check",
    program: :static,
    from: '"curl --fail --silent --show-error http://127.0.0.1:7889/status"',
    to: '""',
    rows: ["a health probe using a tool the image does not ship"]
  },
  {
    label: "the healthy-application check",
    program: :runtime,
    from: 'document == { "status" => "healthy" }',
    to: "true",
    rows: ["a status route reporting an unhealthy application"]
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
    from: 'get("/api/v1/settings/").code == "401"',
    to: "true",
    rows: ["a protected route served anonymously"]
  },
  {
    label: "the published default administrator refusal",
    program: :runtime,
    from: 'login("admin", "trailarr").code == "401"',
    to: "true",
    rows: ["the published default administrator still accepted"]
  },
  {
    label: "the vault administrator acceptance check",
    program: :runtime,
    from: 'login(username, password).code == "200"',
    to: "true",
    rows: ["the vault-authored administrator refused"]
  },
  {
    label: "the served administrator name check",
    program: :runtime,
    from: 'declared["webui_username"] == username',
    to: "true",
    rows: ["a served administrator name that is not the vault's"]
  },
  {
    label: "the declared settings field check",
    program: :runtime,
    from: "declared[field] == expected",
    to: "true",
    rows: ["authentication disabled in the served settings"]
  },
  {
    label: "the application environment existence check",
    program: :runtime,
    from: "File.file?(APPLICATION_ENV)",
    to: "true",
    rows: ["no application environment written at all"],
    # Without the file the read below it raises rather than reporting, so the
    # row still refuses and now says why in a stack trace. That is the
    # regression, and pinning the trace would freeze it.
    detects: "refused for the wrong reason"
  },
  {
    label: "the application API key check",
    program: :runtime,
    from: %(application_env["API_KEY"] == "'\#{api_key}'"),
    to: "true",
    rows: ["an application API key that is not the vault's", "an unquoted application API key"]
  },
  {
    label: "the hand-written key refusal",
    program: :runtime,
    from: "application_env.key?(key)",
    to: "false",
    rows: ["a hand-written WEBUI_PASSWORD in the application environment",
           "a hand-written MONITOR_ENABLED in the application environment"]
  },
  {
    label: "the both-seeded-profiles check",
    program: :runtime,
    from: "seeded.length == 2",
    to: "true",
    rows: ["only one seeded trailer profile"]
  },
  {
    label: "the trailer profile field check",
    program: :runtime,
    from: "profile[field] == expected",
    to: "true",
    rows: ["a trailer profile that writes the wrong container",
           "a trailer profile that does not write beside the media"]
  },
  {
    label: "the no-transport connection refusal",
    program: :runtime,
    from: "declared_connections.empty?",
    to: "true",
    rows: ["an arr connection declared with no transport enabled"]
  },
  {
    label: "the exactly-one-connection check",
    program: :runtime,
    from: "matches.length == 1",
    to: "true",
    rows: ["a duplicated arr connection"]
  },
  {
    label: "the service alias check",
    program: :runtime,
    from: %(connection["url"] == "http://\#{name.downcase}:\#{name == 'Radarr' ? 7878 : 8989}"),
    to: "true",
    rows: ["an arr connection not addressed by service alias"]
  },
  {
    label: "the path mapping refusal",
    program: :runtime,
    from: 'Array(connection["path_mappings"]).empty?',
    to: "true",
    rows: ["an arr connection declaring a path mapping"]
  },
  {
    label: "the monitor-new-media refusal",
    program: :runtime,
    from: 'connection["monitor_new_media"]',
    to: "false",
    rows: ["an arr connection monitoring new media before acceptance"]
  },
  {
    label: "the persisted database check",
    program: :runtime,
    from: "File.file?(DATABASE) && File.size?(DATABASE)",
    to: "true",
    rows: ["state that did not land in the declared config root"]
  }
].freeze

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
    from: "static_program=$contract_repo_dir/tests/contracts/trailarr-static.rb",
    to: "static_program=$repo_dir/tests/contracts/trailarr-static.rb",
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
    Dir.mktmpdir("nas-platform-trailarr-mutant.") do |directory|
      name = mutation.fetch(:program) == :static ? "trailarr-static.rb" : "trailarr-runtime.rb"
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

  puts "trailarr contract: self-test detects #{planted} planted regressions"
  exit
end

failures = static_failures(STATIC_PROGRAM) + runtime_failures(RUNTIME_PROGRAM) +
           wrapper_failures + run_env_failures + stdin_failures + runtime_stdin_failures +
           two_roots_failures
unless failures.empty?
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} Trailarr contract violation(s)"
end

puts "trailarr contract: #{STATIC_ROWS.length} static and #{RUNTIME_ROWS.length} runtime " \
     "properties hold, the run-mode environment contract refuses each name with the wrapper's " \
     "own message, and both programs come from the checkout with an empty stdin"
