#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Behaviour of the Komga service contract's two Ruby programs and its wrapper,
# tests/contracts/komga.sh. Run with --self-test to plant a regression in each.

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "shellwords"
require "tmpdir"
require "yaml"

require_relative "case_pool_support"
require_relative "http_fixture_support"
require_relative "policy_support"
require_relative "contract_test_support"

include HttpFixtureSupport
include TestScaffold
include ContractTestSupport

ROOT = File.expand_path("..", __dir__)
# Matching the fragment alone accepted a backtrace or an echoed argument as a refusal.
DIAGNOSTIC_PREFIX = "Komga contract failed: "
CONTRACT = File.join(ROOT, "tests", "contracts", "komga.sh")
STATIC_PROGRAM = File.join(ROOT, "tests", "contracts", "komga-static.rb")
RUNTIME_PROGRAM = File.join(ROOT, "tests", "contracts", "komga-runtime.rb")

# Exactly what the static program reads. The inventory is here because the
# migration flag is declared at two layers and group_vars/all outranks defaults (#343).
FIXTURE_FILES = %w[
  services/komga/compose.yml
  services/komga/compose.mac.yml
  roles/komga/tasks/main.yml
  roles/komga/defaults/main.yml
  roles/komga/meta/argument_specs.yml
  roles/komga/templates/env.j2
  inventory/group_vars/all/service_komga.yml
  tests/policy_support.rb
].freeze

STATIC_SUCCESS = "Komga static contract passed"
RUN_SUCCESS = "Komga login and library contract passed"

LIBRARY_NAME = "Comics"
COMICS_ROOT = "/data/Comics"
EBOOKS_ROOT = "/data/Ebooks"
LEGACY_LIBRARY_ROOT = "/data"
LEGACY_LIBRARY_NAME = "Books"
UNRELATED_LIBRARY_NAME = "Komga Contract Reference"
ADMIN_EMAIL = "komga-admin@example.invalid"
ADMIN_PASSWORD = "komga-contract-password"
FIXTURE_LIBRARY_URL = "/data/Comics/task-10-contract-comic/Task 10 Contract Comic.cbz"
FIXTURE_RELATIVE = "Comics/task-10-contract-comic/Task 10 Contract Comic.cbz"

# Taken from the role's own defaults so a fixture cannot drift from the platform.
OWNED_SETTINGS = YAML.safe_load_file(File.join(ROOT, "roles/komga/defaults/main.yml"))
                     .fetch("komga_library_settings")
MANAGED_SETTINGS = %w[
  scanInterval scanDirectoryExclusions scanOnStartup scanCbx scanPdf scanEpub
  repairExtensions convertToCbz emptyTrashAfterScan hashFiles hashPages
  hashKoreader analyzeDimensions
].to_h { |key| [key, OWNED_SETTINGS.fetch(key)] }.freeze


def build_fixture_repository(root)
  FIXTURE_FILES.each do |relative|
    destination = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(destination))
    FileUtils.cp(File.join(ROOT, relative), destination)
  end
end

# States its expected match count: a plant that matched nothing would report a pass.
def mutate_text(root, relative, pattern, replacement, occurrences: 1)
  path = File.join(root, relative)
  body = File.read(path)
  found = body.scan(pattern).length
  raise "#{relative}: expected #{occurrences} match(es) of #{pattern.inspect}, " \
        "found #{found}" unless found == occurrences

  File.write(path, occurrences == 1 ? body.sub(pattern, replacement) : body.gsub(pattern, replacement))
end

# ---------------------------------------------------------------------------
# Static layer
# ---------------------------------------------------------------------------

STATIC_ROWS = [
  { name: "an intact repository", break: ->(_root) {}, expects: nil },
  {
    name: "a container running as something other than the platform identity",
    break: lambda { |root|
      mutate_text(root, "services/komga/compose.yml",
                  %(user: "${NAS_UID:?}:${NAS_GID:?}"), %(user: "${NAS_UID:?}:0"))
    },
    expects: "platform identity differs"
  },
  {
    name: "a moved NAS port",
    break: lambda { |root|
      mutate_text(root, "services/komga/compose.yml", %(- "25600:25600"), %(- "25601:25600"))
    },
    expects: "NAS port differs"
  },
  {
    name: "a library mount that is not read-only",
    break: lambda { |root|
      mutate_text(root, "services/komga/compose.yml",
                  "${KOMGA_LIBRARY_PATH:?}:/data:ro", "${KOMGA_LIBRARY_PATH:?}:/data")
    },
    expects: "storage contract differs"
  },
  {
    # A config path under the media root can land inside the library mounted
    # /data:ro, putting Komga's database in a read-only tree.
    name: "config storage moved under the media root",
    break: lambda { |root|
      mutate_text(root, "roles/komga/templates/env.j2",
                  "KOMGA_CONFIG_PATH={{ nas_docker_root }}/komga/config",
                  "KOMGA_CONFIG_PATH={{ nas_media_root }}/Books/config")
    },
    expects: "config storage is not rooted outside the media tree"
  },
  {
    name: "a library moved out of the media root",
    break: lambda { |root|
      mutate_text(root, "roles/komga/templates/env.j2",
                  "KOMGA_LIBRARY_PATH={{ nas_media_root }}/Books",
                  "KOMGA_LIBRARY_PATH={{ nas_docker_root }}/komga/Books")
    },
    expects: "the library is not rooted in the media tree"
  },
  {
    name: "a config path the environment template no longer renders",
    break: lambda { |root|
      mutate_text(root, "roles/komga/templates/env.j2",
                  "KOMGA_CONFIG_PATH={{ nas_docker_root }}/komga/config\n", "")
    },
    expects: "KOMGA_CONFIG_PATH is not rendered exactly once"
  },
  {
    name: "a restart policy that is not unless-stopped",
    break: lambda { |root|
      mutate_text(root, "services/komga/compose.yml",
                  "restart: unless-stopped", "restart: always")
    },
    expects: "restart policy differs"
  },
  {
    name: "unbounded container logging",
    break: lambda { |root|
      mutate_text(root, "services/komga/compose.yml", "max-file: \"3\"", "max-file: \"9\"")
    },
    expects: "logging policy differs"
  },
  {
    name: "an application healthcheck that no longer requires an UP body",
    break: lambda { |root|
      mutate_text(root, "services/komga/compose.yml",
                  %(= '{"status":"UP"}'), %(!= ''))
    },
    expects: "application healthcheck differs"
  },
  {
    name: "a Mac override that widens beyond name and ports",
    break: lambda { |root|
      path = File.join(root, "services/komga/compose.mac.yml")
      document = YAML.safe_load_file(path, aliases: true)
      document.fetch("services").fetch("komga")["user"] = "0:0"
      File.write(path, YAML.dump(document))
    },
    expects: "Mac override may only replace container name and ports"
  },
  {
    name: "a managed library model that is no longer exactly Comics and Ebooks",
    break: lambda { |root|
      mutate_text(root, "roles/komga/defaults/main.yml", "root: /data/Ebooks", "root: /data/Ebook")
    },
    expects: "managed library model differs"
  },
  {
    name: "a retired singular library input that came back",
    break: lambda { |root|
      path = File.join(root, "roles/komga/defaults/main.yml")
      File.write(path, "#{File.read(path)}komga_library_name: Comics\n")
    },
    expects: "the retired singular library inputs survive"
  },
  {
    name: "a scan schedule that is no longer hourly",
    break: lambda { |root|
      mutate_text(root, "roles/komga/defaults/main.yml",
                  "scanInterval: HOURLY", "scanInterval: DAILY")
    },
    expects: "managed scan schedule differs"
  },
  {
    name: "a dropped .acquisition scan exclusion",
    break: lambda { |root|
      mutate_text(root, "roles/komga/defaults/main.yml",
                  "  scanDirectoryExclusions:\n    - .acquisition\n",
                  "  scanDirectoryExclusions: []\n")
    },
    expects: "managed scan exclusions differ"
  },
  {
    name: "a root migration input that defaults to true",
    break: lambda { |root|
      mutate_text(root, "roles/komga/defaults/main.yml",
                  "komga_library_root_migration_allowed: false",
                  "komga_library_root_migration_allowed: true")
    },
    expects: "the library root migration input is not one-convergence"
  },
  {
    name: "a root migration input left true in the inventory that outranks the defaults",
    break: lambda { |root|
      mutate_text(root, "inventory/group_vars/all/service_komga.yml",
                  "komga_library_root_migration_allowed: false",
                  "komga_library_root_migration_allowed: true")
    },
    expects: "the library root migration input is enabled in the inventory"
  },
  {
    name: "a plural library model that is undeclared in argument_specs",
    break: lambda { |root|
      mutate_text(root, "roles/komga/meta/argument_specs.yml",
                  "      komga_libraries:\n", "      komga_library_set:\n")
    },
    expects: "the plural library model is undeclared"
  },
  {
    name: "drifted application health timing defaults",
    break: lambda { |root|
      mutate_text(root, "roles/komga/defaults/main.yml",
                  "komga_health_retries: 60", "komga_health_retries: 61")
    },
    expects: "application health timing defaults differ"
  },
  {
    name: "application health timing arguments that are undeclared",
    break: lambda { |root|
      mutate_text(root, "roles/komga/meta/argument_specs.yml",
                  "      komga_health_delay:\n        type: int\n        required: false\n",
                  "      komga_health_delay:\n        type: str\n        required: false\n")
    },
    expects: "application health timing arguments are undeclared"
  },
  {
    name: "an application readiness task that occurs twice",
    break: lambda { |root|
      path = File.join(root, "roles/komga/tasks/main.yml")
      tasks = YAML.safe_load_file(path, aliases: false)
      index = tasks.index { |task| task["name"] == "Wait for Komga application health" }
      tasks.insert(index + 1, Marshal.load(Marshal.dump(tasks.fetch(index))))
      File.write(path, YAML.dump(tasks))
    },
    expects: "application health readiness task must occur exactly once"
  },
  {
    name: "readiness that no longer gates claim reconciliation",
    break: lambda { |root|
      path = File.join(root, "roles/komga/tasks/main.yml")
      tasks = YAML.safe_load_file(path, aliases: false)
      index = tasks.index { |task| task["name"] == "Wait for Komga application health" }
      readiness = tasks.delete_at(index)
      claim = tasks.index { |task| task["name"] == "Read Komga claim status" }
      tasks.insert(claim + 1, readiness)
      File.write(path, YAML.dump(tasks))
    },
    expects: "application readiness must gate claim reconciliation"
  },
  {
    name: "a readiness request against some other endpoint",
    break: lambda { |root|
      mutate_text(root, "roles/komga/tasks/main.yml",
                  "{{ komga_api }}/actuator/health", "{{ komga_api }}/api/v1/claim")
    },
    expects: "application readiness request differs"
  },
  {
    name: "a readiness gate that accepts any status body",
    break: lambda { |root|
      mutate_text(root, "roles/komga/tasks/main.yml",
                  "komga_health.json.status | default(none) == 'UP'",
                  "komga_health.json.status | default(none) != ''")
    },
    expects: "application readiness status gate differs"
  },
  {
    # Consumed by no earlier assertion, so this reaches the existence report.
    name: "a required task that survives only under a different name",
    break: lambda { |root|
      mutate_text(root, "roles/komga/tasks/main.yml",
                  "- name: Claim Komga with the vault administrator",
                  "- name: Claim Komga with the operator")
    },
    expects: "missing Claim Komga with the vault administrator"
  },
  {
    # The guard moves, not the creation: moving the creation trips the
    # repair-ordering sentence first.
    name: "a library preflight that no longer precedes every mutation",
    break: lambda { |root|
      path = File.join(root, "roles/komga/tasks/main.yml")
      tasks = YAML.safe_load_file(path, aliases: false)
      index = tasks.index { |task| task["name"] == "Refuse ambiguous Komga library candidates" }
      guard = tasks.delete_at(index)
      creation = tasks.index { |task| task["name"] == "Create the managed Komga library" }
      tasks.insert(creation + 1, guard)
      File.write(path, YAML.dump(tasks))
    },
    expects: "library preflight must precede every mutation"
  },
  {
    name: "a library creation ordered before the repair that frees its root",
    break: lambda { |root|
      path = File.join(root, "roles/komga/tasks/main.yml")
      tasks = YAML.safe_load_file(path, aliases: false)
      repair = tasks.index { |task| task["name"] == "Repair the managed Komga library" }
      create = tasks.index { |task| task["name"] == "Create the managed Komga library" }
      tasks[repair], tasks[create] = tasks[create], tasks[repair]
      File.write(path, YAML.dump(tasks))
    },
    expects: "library repairs must precede library creations"
  },
  {
    name: "managed root matching that dropped its trailing-slash filter",
    break: lambda { |root|
      mutate_text(root, "roles/komga/tasks/main.yml",
                  "regex_replace('/+$', '')", "regex_replace('/+#', '')", occurrences: 3)
    },
    expects: "managed root matching is not trailing-slash normalized"
  },
  {
    name: "a library repair that no longer targets the selected identifier",
    break: lambda { |root|
      mutate_text(root, "roles/komga/tasks/main.yml",
                  "item.id | urlencode", "item.name | urlencode")
    },
    expects: "library updates must preserve the selected identifier"
  },
  {
    # Read as the guard's own conditions: the input is named in three live places.
    name: "an ambiguity guard that lost its one-convergence clause",
    break: lambda { |root|
      mutate_text(root, "roles/komga/tasks/main.yml",
                  "        komga_library_root_migration_allowed | bool\n", "        true\n")
    },
    expects: "the library root move is not gated on the one-convergence input"
  },
  {
    name: "managed-user reconciliation ordered before the library preflight",
    break: lambda { |root|
      path = File.join(root, "roles/komga/tasks/main.yml")
      tasks = YAML.safe_load_file(path, aliases: false)
      index = tasks.index { |task| task["name"] == "Reconcile managed Komga users" }
      users = tasks.delete_at(index)
      guard = tasks.index { |task| task["name"] == "Refuse ambiguous Komga library candidates" }
      tasks.insert(guard, users)
      File.write(path, YAML.dump(tasks))
    },
    expects: "complete library preflight must precede managed-user mutation"
  },
  {
    name: "a task that reaches into Komga's own database",
    break: lambda { |root|
      path = File.join(root, "roles/komga/tasks/main.yml")
      tasks = YAML.safe_load_file(path, aliases: false)
      tasks << { "name" => "Repair the Komga index",
                 "ansible.builtin.command" => "sqlite3 /config/database.sqlite vacuum",
                 "changed_when" => false }
      File.write(path, YAML.dump(tasks))
    },
    expects: "role must not edit an opaque database"
  }
].freeze

def static_argv(root)
  %w[
    services/komga/compose.yml
    services/komga/compose.mac.yml
    roles/komga/tasks/main.yml
    roles/komga/defaults/main.yml
    roles/komga/meta/argument_specs.yml
    roles/komga/templates/env.j2
    inventory/group_vars/all/service_komga.yml
  ].map { |relative| File.join(root, relative) }
end

def static_failures(program = STATIC_PROGRAM, rows = STATIC_ROWS)
  failures = []
  in_parallel_cases(failures, rows) do |row, collected|
    Dir.mktmpdir("nas-platform-komga-static.") do |raw|
      root = File.realpath(raw)
      build_fixture_repository(root)
      row.fetch(:break).call(root)
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => root },
        RbConfig.ruby, "-ryaml", program, *static_argv(root)
      )
      collected.concat(judge("static: #{row.fetch(:name)}", row.fetch(:expects), stdout, stderr, status,
                             prefix: DIAGNOSTIC_PREFIX))
    end
  end
  failures
end

# ---------------------------------------------------------------------------
# Runtime layer
# ---------------------------------------------------------------------------

def managed_library(id:, name: LIBRARY_NAME, root: COMICS_ROOT, overrides: {})
  MANAGED_SETTINGS.merge("id" => id, "name" => name, "root" => root,
                         "unavailable" => false).merge(overrides)
end

def converged_libraries
  [managed_library(id: "comics"),
   managed_library(id: "ebooks", name: "Ebooks", root: EBOOKS_ROOT)]
end

def komga_responder(state)
  lambda do |method, target, headers, body|
    libraries = state.fetch(:libraries)
    authorized = headers.fetch("authorization", "") ==
                 "Basic #{["#{ADMIN_EMAIL}:#{ADMIN_PASSWORD}"].pack('m0')}"
    path, query = target.split("?", 2)
    case [method, path]
    when %w[GET /actuator/health]
      [200, JSON.generate(state.fetch(:health, { "status" => "UP" }))]
    when %w[GET /api/v2/users/me]
      next [401, JSON.generate("error" => "unauthorized")] unless authorized

      [200, JSON.generate(state.fetch(:me,
                                      { "email" => ADMIN_EMAIL, "roles" => %w[ADMIN USER] }))]
    when %w[GET /api/v1/libraries]
      next [401, ""] unless authorized
      next [200, state.fetch(:malformed_libraries)] if state.key?(:malformed_libraries)

      [200, JSON.generate(libraries)]
    when %w[GET /api/v1/books]
      next [401, ""] unless authorized

      identifier = query.to_s[/library_id=([^&]*)/, 1].to_s
      books = state.fetch(:books, [{ "url" => FIXTURE_LIBRARY_URL, "libraryId" => identifier }])
      [200, JSON.generate("content" => books)]
    else
      next [401, ""] unless authorized

      if method == "POST" && path.match?(%r{\A/api/v1/libraries/[^/]+/scan\z})
        next [202, nil, nil]
      end
      if method == "POST" && path == "/api/v1/libraries"
        created = JSON.parse(body).merge("id" => "created-#{libraries.length}",
                                         "unavailable" => false)
        libraries << created
        next [200, JSON.generate(created)]
      end
      if path.match?(%r{\A/api/v1/libraries/[^/]+\z})
        identifier = path.split("/").last
        entry = libraries.find { |candidate| candidate["id"] == identifier }
        next [404, JSON.generate("error" => "no such library")] unless entry

        if method == "PATCH"
          entry.merge!(JSON.parse(body))
          next [204, nil, nil]
        end
        if method == "DELETE"
          libraries.delete(entry)
          next [204, nil, nil]
        end
      end
      [500, JSON.generate("error" => "unexpected #{method} #{target}")]
    end
  end
end

def write_stub(directory, name, body)
  path = File.join(directory, name)
  File.write(path, body)
  File.chmod(0o755, path)
  path
end

def with_runtime_sandbox(state)
  Dir.mktmpdir("nas-platform-komga-runtime.") do |raw|
    sandbox = File.realpath(raw)
    media = File.join(sandbox, "media")
    report = File.join(sandbox, "report")
    bin = File.join(sandbox, "bin")
    FileUtils.mkdir_p([media, report, bin, File.join(media, "Books")])
    answer = File.join(sandbox, "docker-answer")
    File.write(answer, "#{state.fetch(:docker_answer, 'healthy')}\n")
    write_stub(bin, "docker", <<~SH)
      #!/bin/sh
      exec cat #{answer.shellescape}
    SH
    vault = File.join(sandbox, "vault.yml")
    File.write(vault, YAML.dump("vault_komga_admin_email" => ADMIN_EMAIL,
                                "vault_komga_admin_password" => ADMIN_PASSWORD))
    File.write(File.join(sandbox, "password"), "unused-by-the-stub\n")
    write_stub(bin, "ansible-vault", if state.fetch(:vault_refuses, false)
                                       "#!/bin/sh\nprintf 'refused\\n' >&2\nexit 1\n"
                                     else
                                       "#!/bin/sh\nexec cat #{vault.shellescape}\n"
                                     end)
    yield(sandbox: sandbox, media: media, report: report, bin: bin, vault: vault)
  end
end

def run_runtime(program, mode, state, paths, port, extra_env: {})
  environment = {
    "PATH" => "#{paths.fetch(:bin)}:#{ENV.fetch('PATH')}",
    "PLATFORM_KOMGA_PORT" => port.to_s,
    "PLATFORM_KOMGA_CONTAINER" => "komga-contract-container",
    "PLATFORM_KOMGA_DOCKER_HEALTH_REQUIRED" =>
      state.fetch(:docker_health_required, "true"),
    "PLATFORM_MEDIA_ROOT" => paths.fetch(:media),
    "PLATFORM_REPORT_ROOT" => state.fetch(:report_root_override) { paths.fetch(:report) },
    "PLATFORM_KOMGA_FIXTURE_PRESEEDED" => state.fetch(:preseeded, "false"),
    "PLATFORM_KOMGA_LIBRARY_PATH" => File.join(paths.fetch(:media), "Books"),
    "PLATFORM_CONTRACT_VAULT_FILE" => paths.fetch(:vault),
    "PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" => File.join(paths.fetch(:sandbox), "password")
  }.merge(extra_env)
  Open3.capture3(environment, RbConfig.ruby, program, mode, in: "/dev/null")
end

RUNTIME_ROWS = [
  { name: "a converged platform in run mode", mode: "run", expects: nil,
    wants: RUN_SUCCESS },
  { name: "a vault that cannot be decrypted", mode: "run",
    state: { vault_refuses: true }, expects: "encrypted vault could not be read" },
  { name: "an administrator whose identity is not the vault's", mode: "run",
    state: { me: { "email" => "someone@example.invalid", "roles" => %w[ADMIN] } },
    expects: "vault administrator identity or role differs" },
  { name: "an administrator without the ADMIN role", mode: "run",
    state: { me: { "email" => ADMIN_EMAIL, "roles" => %w[USER] } },
    expects: "vault administrator identity or role differs" },
  { name: "a library listing that is not a list", mode: "run",
    state: { malformed_libraries: '{"libraries":[]}' },
    expects: "library listing schema differs" },
  { name: "a library listing that is not JSON", mode: "run",
    state: { malformed_libraries: "not json at all" },
    expects: "returned malformed JSON" },
  # This fixture also fails the name-binding check, so the schema plant is
  # proven through the opaque-identifier row instead.
  { name: "a managed library candidate with no name", mode: "run",
    libraries: lambda {
      [{ "id" => "comics", "root" => COMICS_ROOT },
       managed_library(id: "ebooks", name: "Ebooks", root: EBOOKS_ROOT)]
    },
    expects: "managed library candidate schema differs" },
  { name: "a managed library candidate with an opaque identifier", mode: "run",
    libraries: lambda {
      [managed_library(id: "not a safe id"),
       managed_library(id: "ebooks", name: "Ebooks", root: EBOOKS_ROOT)]
    },
    expects: "managed library candidate schema differs" },
  { name: "two libraries claiming the managed root", mode: "run",
    libraries: lambda {
      converged_libraries + [managed_library(id: "duplicate", name: "Manga",
                                             root: "#{COMICS_ROOT}/")]
    },
    expects: "managed library root is absent or duplicated" },
  { name: "the managed name bound to some other library", mode: "run",
    libraries: lambda {
      [managed_library(id: "comics", name: "Manga"),
       managed_library(id: "elsewhere", name: LIBRARY_NAME, root: "/data/Elsewhere"),
       managed_library(id: "ebooks", name: "Ebooks", root: EBOOKS_ROOT)]
    },
    expects: "managed library name is absent, duplicated, or bound elsewhere" },
  { name: "a drifted owned setting on the managed library", mode: "run",
    libraries: lambda {
      [managed_library(id: "comics", overrides: { "scanInterval" => "DAILY" }),
       managed_library(id: "ebooks", name: "Ebooks", root: EBOOKS_ROOT)]
    },
    expects: "managed library setting scanInterval differs on Comics" },
  { name: "a drifted owned setting on the second managed library", mode: "run",
    libraries: lambda {
      [managed_library(id: "comics"),
       managed_library(id: "ebooks", name: "Ebooks", root: EBOOKS_ROOT,
                       overrides: { "scanOnStartup" => true })]
    },
    expects: "managed library setting scanOnStartup differs on Ebooks" },
  { name: "a container that declares a Docker healthcheck where none is allowed",
    mode: "run",
    state: { docker_health_required: "false", docker_answer: "present" },
    expects: "unexpectedly defines a Docker healthcheck" },
  { name: "a container with no Docker healthcheck where none is required",
    mode: "run",
    state: { docker_health_required: "false", docker_answer: "absent" },
    expects: nil, wants: RUN_SUCCESS },
  { name: "a mode the program does not dispatch", mode: "totally-unknown",
    expects: "unknown mode: totally-unknown" },
  { name: "the pre-deployment fixture seed", mode: "seed-fixture-only",
    expects: nil, wants: "Komga comic fixture prepared before deployment" },
  { name: "a fixture seed repeated over its own bytes", mode: "seed-fixture-only",
    before: ->(paths, program) { seed_the_fixture(paths, program) },
    expects: nil, wants: "Komga comic fixture prepared before deployment" },
  { name: "a comic fixture whose bytes drifted", mode: "seed-fixture-only",
    before: lambda { |paths|
      target = File.join(paths.fetch(:media), "Books", FIXTURE_RELATIVE)
      FileUtils.mkdir_p(File.dirname(target))
      File.binwrite(target, "not the fixture")
    },
    expects: "comic fixture bytes drifted" },
  { name: "the seed mode against a converged platform", mode: "seed",
    expects: nil, wants: "Komga fixture, library identity, and settings seeded",
    after: lambda { |paths, collected|
      artifact = File.join(paths.fetch(:report), "komga-persistence.json")
      collected << "runtime: seed wrote no persistence artifact" unless File.file?(artifact)
      expected = 0o600 & ~File.umask
      actual = File.stat(artifact).mode & 0o777
      collected << "runtime: seed wrote the persistence artifact #{format('%<m>04o', m: actual)}, " \
                   "wanted #{format('%<m>04o', m: expected)}" unless actual == expected
    } },
  { name: "a seed that would replace an existing persistence artifact", mode: "seed",
    before: lambda { |paths|
      File.write(File.join(paths.fetch(:report), "komga-persistence.json"), "{}")
    },
    expects: "refusing to replace Komga persistence artifact" },
  { name: "a seed whose report root is a symlink", mode: "seed",
    before: lambda { |paths|
      link = File.join(paths.fetch(:sandbox), "report-link")
      File.symlink(paths.fetch(:report), link)
    },
    state: { report_root_link: true },
    expects: "report root is unavailable or unsafe" },
  { name: "persistence asserted with no artifact present", mode: "assert-persistence",
    expects: "Komga persistence artifact is unavailable or unsafe" },
  { name: "persistence asserted against the artifact it wrote",
    mode: "assert-persistence", seed_first: true,
    expects: nil,
    wants: "Komga library ID, settings, unrelated state, and scanned comic persisted" },
  { name: "a managed library identifier that changed across recreation",
    mode: "assert-persistence", seed_first: true,
    mutate_after_seed: ->(state) { state.fetch(:libraries).first["id"] = "recreated" },
    expects: "Komga managed library identifiers changed across recreation" },
  {
    # An *unowned* setting: the owned set is compared earlier and would refuse first.
    name: "a managed library setting that changed across recreation",
    mode: "assert-persistence", seed_first: true,
    libraries: lambda {
      [managed_library(id: "comics", overrides: { "seriesCover" => "FIRST" }),
       managed_library(id: "ebooks", name: "Ebooks", root: EBOOKS_ROOT)]
    },
    mutate_after_seed: ->(state) { state.fetch(:libraries).first["seriesCover"] = "LAST" },
    expects: "Komga managed library names, roots or settings changed across recreation" },
  { name: "an unrelated library that did not survive recreation",
    mode: "assert-persistence", seed_first: true,
    libraries: lambda {
      converged_libraries + [managed_library(id: "unrelated", name: UNRELATED_LIBRARY_NAME,
                                             root: "/data/Reference")]
    },
    mutate_after_seed: lambda { |state|
      state.fetch(:libraries).reject! { |entry| entry["name"] == UNRELATED_LIBRARY_NAME }
    },
    expects: "unrelated Komga library did not survive recreation" },
  { name: "the drift fixture install", mode: "drift",
    expects: nil, wants: "Komga library drift installed",
    after: lambda { |_paths, collected, state|
      comics = state.fetch(:libraries).find { |entry| entry["id"] == "comics" }
      collected << "runtime: drift did not rename the managed library" unless
        comics.fetch("name") == LEGACY_LIBRARY_NAME
      collected << "runtime: drift did not switch scanOnStartup on" unless
        comics.fetch("scanOnStartup") == true
    } },
  { name: "drift verified against an installed drift", mode: "drift-verify",
    libraries: lambda {
      [managed_library(id: "comics", name: LEGACY_LIBRARY_NAME,
                       overrides: { "scanOnStartup" => true }),
       managed_library(id: "ebooks", name: "Ebooks", root: EBOOKS_ROOT)]
    },
    expects: nil, wants: "Komga library drift is present" },
  { name: "drift verified against a converged platform", mode: "drift-verify",
    expects: "managed library name is absent, duplicated, or bound elsewhere" },
  { name: "a half-installed drift whose scan-on-startup never moved",
    mode: "drift-verify",
    libraries: lambda {
      [managed_library(id: "comics", name: LEGACY_LIBRARY_NAME),
       managed_library(id: "ebooks", name: "Ebooks", root: EBOOKS_ROOT)]
    },
    expects: "Komga drift fixture was not installed" },
  { name: "the pre-migration collapse", mode: "migration-legacy",
    expects: nil, wants: "Komga pre-migration single-library state installed",
    after: lambda { |paths, collected, state|
      collected << "runtime: the collapse did not remove the Ebooks library" if
        state.fetch(:libraries).any? { |entry| entry["name"] == "Ebooks" }
      comics = state.fetch(:libraries).find { |entry| entry["id"] == "comics" }
      collected << "runtime: the collapse did not repoint Comics at the legacy root" unless
        comics.fetch("root") == LEGACY_LIBRARY_ROOT
      recorded = File.join(paths.fetch(:report), "komga-migration-legacy-id")
      collected << "runtime: the collapse did not record the library identifier" unless
        File.file?(recorded) && File.read(recorded) == "comics"
    } },
  { name: "the pre-migration state verified", mode: "migration-legacy-verify",
    libraries: lambda {
      [managed_library(id: "comics", root: LEGACY_LIBRARY_ROOT,
                       overrides: { "scanInterval" => "DISABLED",
                                    "scanDirectoryExclusions" => [] })]
    },
    expects: nil, wants: "Komga pre-migration single-library state is present" },
  { name: "a pre-migration state whose scan schedule was never disabled",
    mode: "migration-legacy-verify",
    libraries: lambda { [managed_library(id: "comics", root: LEGACY_LIBRARY_ROOT)] },
    expects: "the pre-migration library was not installed" },
  { name: "a pre-migration collapse the Ebooks library survived",
    mode: "migration-legacy-verify",
    libraries: lambda {
      [managed_library(id: "comics", root: LEGACY_LIBRARY_ROOT,
                       overrides: { "scanInterval" => "DISABLED",
                                    "scanDirectoryExclusions" => [] }),
       managed_library(id: "ebooks", name: "Ebooks", root: EBOOKS_ROOT)]
    },
    expects: "the Ebooks library survived the pre-migration collapse" },
  { name: "a migration verified as completed in place", mode: "migration-verify",
    before: lambda { |paths|
      File.write(File.join(paths.fetch(:report), "komga-migration-legacy-id"), "comics")
    },
    expects: nil, wants: "Komga library root migration completed in place",
    after: lambda { |paths, collected, _state|
      collected << "runtime: migration-verify did not consume the recorded identifier" if
        File.exist?(File.join(paths.fetch(:report), "komga-migration-legacy-id"))
    } },
  { name: "a migration verified with no recorded identifier", mode: "migration-verify",
    expects: "the pre-migration library identifier was not recorded" },
  { name: "a migration that replaced the library instead of repointing it",
    mode: "migration-verify",
    before: lambda { |paths|
      File.write(File.join(paths.fetch(:report), "komga-migration-legacy-id"), "some-other-id")
    },
    expects: "the migration replaced the Comics library instead of repointing it" }
].freeze

# Uses the program under test so a future plant in seed_fixture cannot pass vacuously.
def seed_the_fixture(paths, program)
  _out, _err, status = run_runtime(program, "seed-fixture-only", {}, paths, 1)
  raise "arranging the comic fixture failed" unless status.success?
end

def runtime_failures(program = RUNTIME_PROGRAM, rows = RUNTIME_ROWS)
  failures = []
  in_parallel_cases(failures, rows) do |row, collected|
    label = "runtime: #{row.fetch(:name)}"
    state = { libraries: (row[:libraries] || method(:converged_libraries)).call }
             .merge(row.fetch(:state, {}))
    with_runtime_sandbox(state) do |paths|
      # The symlink row repoints PLATFORM_REPORT_ROOT at the link :before created.
      before = row[:before]
      before&.arity == 2 ? before.call(paths, program) : before&.call(paths)
      if state.fetch(:report_root_link, false)
        state = state.merge(report_root_override: File.join(paths.fetch(:sandbox), "report-link"))
      end
      with_http_fixture(lambda { |port|
        if row.fetch(:seed_first, false)
          _out, err, seeded = run_runtime(program, "seed", state, paths, port)
          collected << "#{label}: the seed this row builds on failed: #{err.strip}" unless
            seeded.success?
          row[:mutate_after_seed]&.call(state)
        end
        stdout, stderr, status = run_runtime(program, row.fetch(:mode), state, paths, port)
        collected.concat(judge(label, row.fetch(:expects), stdout, stderr, status,
                               prefix: DIAGNOSTIC_PREFIX))
        if row[:wants] && !(stdout + stderr).include?(row.fetch(:wants))
          collected << "#{label}: did not report #{row.fetch(:wants).inspect}, " \
                       "got #{(stdout + stderr).strip.inspect}"
        end
        after = row[:after]
        after&.arity == 2 ? after.call(paths, collected) : after&.call(paths, collected, state)
      }, &komga_responder(state))
    end
  end
  failures
end

# ---------------------------------------------------------------------------
# Wrapper layer
# ---------------------------------------------------------------------------
#
# The wrapper resolves both programs from its own checkout, so a copy into a
# throwaway tests/contracts/ can point at a broken fixture and still run for real.

def with_contract_copy(static: File.read(STATIC_PROGRAM), runtime: File.read(RUNTIME_PROGRAM),
                       wrapper: File.read(CONTRACT), &block)
  with_contract_sandbox("komga", wrapper, { "static" => static, "runtime" => runtime }, &block)
end

REQUIRED_RUN_ENV = %w[
  PLATFORM_MEDIA_ROOT
  PLATFORM_REPORT_ROOT
].freeze

def wrapper_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  with_contract_copy(wrapper: wrapper_source) do |contract, copy_root|
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => copy_root }, contract, "static"
    )
    failures << "wrapper: static mode failed against its own fixture: #{(stdout + stderr).strip}" unless
      status.success?
    failures << "wrapper: static mode did not report the property it proved" unless
      stdout.include?(STATIC_SUCCESS)

    Dir.mktmpdir("nas-platform-komga-broken.") do |raw|
      broken = File.realpath(raw)
      build_fixture_repository(broken)
      FileUtils.rm(File.join(broken, "roles/komga/meta/argument_specs.yml"))
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => broken }, contract, "static"
      )
      failures << "wrapper: static mode passed against a broken repository" if status.success?
      failures << "wrapper: static mode did not report the broken repository" unless
        (stdout + stderr).include?("roles/komga/meta/argument_specs.yml is absent")
    end

    # `run` is the default mode, so a bare invocation must reach the runtime
    # half's environment requirements.
    [[], %w[run], %w[totally-unknown]].each do |argv|
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => copy_root, "PLATFORM_MEDIA_ROOT" => nil,
          "PLATFORM_REPORT_ROOT" => nil }, contract, *argv
      )
      output = stdout + stderr
      failures << "wrapper: #{argv.inspect} was accepted with no runtime environment" if
        status.success?
      failures << "wrapper: #{argv.inspect} did not name the unset root: #{output.strip.inspect}" unless
        output.include?("PLATFORM_MEDIA_ROOT is required")
      failures << "wrapper: #{argv.inspect} reached the runtime program with no media root" if
        output.include?("Komga comic fixture prepared") || output.include?(RUN_SUCCESS)
      failures << "wrapper: #{argv.inspect} printed the static success line in run mode" if
        stdout.include?(STATIC_SUCCESS)
    end

    roots = { "PLATFORM_MEDIA_ROOT" => copy_root, "PLATFORM_REPORT_ROOT" => copy_root }
    {
      "an invalid runtime context" =>
        [{ "PLATFORM_KOMGA_RUNTIME_CONTEXT" => "not-a-context" },
         "Komga runtime context is invalid"],
      "a Mac context under the integration platform" =>
        [{ "PLATFORM_KIND" => "integration",
           "PLATFORM_KOMGA_RUNTIME_CONTEXT" => "mac-managed" },
         "integration Komga runtime context differs"],
      "a managed Mac context with no project name" =>
        [{ "PLATFORM_KOMGA_RUNTIME_CONTEXT" => "mac-managed" },
         "PLATFORM_PROJECT_NAME is required for managed Mac Komga"]
    }.each do |name, (environment, expects)|
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => copy_root }.merge(roots).merge(environment),
        contract, "run"
      )
      failures << "wrapper: #{name} was accepted" if status.success?
      failures << "wrapper: #{name} was refused without its diagnostic: " \
                  "#{(stdout + stderr).strip.inspect}" unless (stdout + stderr).include?(expects)
    end

    # Each root set to "" on its own ("" because ${VAR:?} refuses null too). The
    # port is unparseable so a guard planted as `:=` fails fast.
    full = { "PLATFORM_CONTRACT_REPO_DIR" => copy_root, "PLATFORM_KOMGA_PORT" => "not-a-number" }
           .merge(roots)
    REQUIRED_RUN_ENV.each do |name|
      stdout, stderr, status = Open3.capture3(full.merge(name => ""), contract, "run", chdir: copy_root)
      output = stdout + stderr
      failures << "run env: #{name} unset was accepted" if status.success?
      failures << "run env: #{name} unset was not refused with the wrapper's own message: " \
                  "#{output.strip.inspect}" unless output.include?("#{name} is required")
    end
  end

  # The branch every deployment takes: nothing sets PLATFORM_CONTRACT_REPO_DIR.
  with_contract_copy(wrapper: wrapper_source) do |contract, copy_root|
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => nil }, contract, "static"
    )
    failures << "wrapper: static mode failed with no repository named: " \
                "#{(stdout + stderr).strip}" unless status.success?
    failures << "wrapper: static mode did not report the property it proved" unless
      stdout.include?(STATIC_SUCCESS)

    FileUtils.rm(File.join(copy_root, "roles/komga/meta/argument_specs.yml"))
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => nil }, contract, "static"
    )
    failures << "wrapper: with no repository named, static mode inspected some other tree" if
      status.success?
    failures << "wrapper: with no repository named, static mode did not report the broken tree" unless
      (stdout + stderr).include?("roles/komga/meta/argument_specs.yml is absent")
  end
  failures
end

# --- the three self-read greps ---------------------------------------------

SELF_READ_ROWS = [
  {
    name: "a fixture scan timeout that no longer matches the wrapper's guard",
    file: :runtime,
    from: "FIXTURE_SCAN_TIMEOUT_SECONDS = 240",
    to: "FIXTURE_SCAN_TIMEOUT_SECONDS = 241",
    expects: "fixture scan timeout differs"
  },
  {
    name: "an unrelated-library fixture root that could collide with /data",
    file: :runtime,
    from: 'UNRELATED_LIBRARY_ROOT = "/config/.nas-platform-unmanaged"',
    to: 'UNRELATED_LIBRARY_ROOT = "/data/.nas-platform-unmanaged"',
    expects: "unrelated library fixture API root can collide with /data"
  },
  {
    # The negated guard: left reading the wrapper it would be trivially true.
    name: "an unsafe media-root fallback for the fixture config path",
    file: :runtime,
    from: %(LEGACY_LIBRARY_ROOT = "/data"\n),
    to: %(LEGACY_LIBRARY_ROOT = "/data"\n) +
        %(CONFIG_PROBE = ENV.fetch("PLATFORM_KOMGA_CONFIG_PATH", MEDIA_ROOT.join("x").to_s)\n),
    expects: "Komga fixture config path has an unsafe media-root fallback"
  }
].freeze

def self_read_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  # A floor rather than non-emptiness: an empty set would report "all 0 bite".
  failures << "self-read: the guard set has shrunk to #{SELF_READ_ROWS.length} row(s); " \
              "a guard was deleted without its property moving somewhere that can fail" if
    SELF_READ_ROWS.length < 3
  in_parallel_cases(failures, SELF_READ_ROWS) do |row, collected|
    program = File.read(row.fetch(:file) == :runtime ? RUNTIME_PROGRAM : STATIC_PROGRAM)
    found = program.scan(row.fetch(:from)).length
    if found != 1
      collected << "self-read: #{row.fetch(:name)}: expected 1 match of " \
                   "#{row.fetch(:from).inspect} in the program, found #{found}"
      next
    end
    planted = program.sub(row.fetch(:from), row.fetch(:to))
    with_contract_copy(runtime: planted, wrapper: wrapper_source) do |contract, copy_root|
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => copy_root }, contract, "static"
      )
      collected.concat(judge("self-read: #{row.fetch(:name)}", row.fetch(:expects), stdout, stderr, status,
                             prefix: DIAGNOSTIC_PREFIX))
    end
  end
  failures
end

# --- stdin -----------------------------------------------------------------
#
# Neither program reads stdin, so only a probe makes the redirect observable. The
# runtime one is reached through `exec` and gets its own probe.

# Must satisfy the wrapper's three self-read greps or the wrapper refuses first.
RUNTIME_STDIN_PROBE = <<~'PROBE'
  FIXTURE_SCAN_TIMEOUT_SECONDS = 240
  UNRELATED_LIBRARY_ROOT = "/config/.nas-platform-unmanaged"
  warn "probe read #{$stdin.read.inspect}"
  exit 1
PROBE

def stdin_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  [[:static, "static", { static: STDIN_PROBE }],
   [:runtime, "run", { runtime: RUNTIME_STDIN_PROBE }]].each do |layer, mode, replacement|
    with_contract_copy(wrapper: wrapper_source, **replacement) do |contract, copy_root|
      environment = { "PLATFORM_CONTRACT_REPO_DIR" => copy_root,
                      "PLATFORM_MEDIA_ROOT" => copy_root, "PLATFORM_REPORT_ROOT" => copy_root }
      failures.concat(stdin_probe_failures(contract, [mode], environment, prefix: "stdin (#{layer})"))
    end
  end
  failures
end

# --- two roots -------------------------------------------------------------
#
# A tree with no tests/contracts must pass; tests/policy_support.rb must still
# come from the inspected tree.

def two_roots_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  with_contract_copy(wrapper: wrapper_source) do |contract|
    Dir.mktmpdir("nas-platform-komga-tworoots.") do |raw|
      inspected = File.realpath(raw)
      build_fixture_repository(inspected)
      FileUtils.rm_rf(File.join(inspected, "tests", "contracts"))
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => inspected }, contract, "static"
      )
      failures << "two roots: an inspected tree with no tests/contracts was refused, so a " \
                  "program is being resolved from it: #{(stdout + stderr).strip}" unless
        status.success?
      failures << "two roots: the contract did not report the property it proved" unless
        stdout.include?(STATIC_SUCCESS)
    end

    Dir.mktmpdir("nas-platform-komga-support.") do |raw|
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

# ---------------------------------------------------------------------------
# Planted regressions
# ---------------------------------------------------------------------------

STATIC_MUTATIONS = [
  {
    label: "the platform identity check",
    from: 'service.fetch("user") == "${NAS_UID:?}:${NAS_GID:?}"',
    to: "true",
    rows: ["a container running as something other than the platform identity"]
  },
  {
    label: "the NAS port check",
    from: 'service.fetch("ports") == ["25600:25600"]',
    to: "true",
    rows: ["a moved NAS port"]
  },
  {
    label: "the storage contract check",
    from: 'abort "Komga contract failed: storage contract differs" unless service.fetch("volumes") == [',
    to: 'abort "Komga contract failed: storage contract differs" unless true || service.fetch("volumes") == [',
    rows: ["a library mount that is not read-only"]
  },
  {
    label: "the config storage root check",
    from: '  rooted_at.call(env_value.call("KOMGA_CONFIG_PATH"), "nas_docker_root")',
    to: '  true || rooted_at.call(env_value.call("KOMGA_CONFIG_PATH"), "nas_docker_root")',
    rows: ["config storage moved under the media root"]
  },
  {
    label: "the library storage root check",
    from: '  rooted_at.call(env_value.call("KOMGA_LIBRARY_PATH"), "nas_media_root")',
    to: '  true || rooted_at.call(env_value.call("KOMGA_LIBRARY_PATH"), "nas_media_root")',
    rows: ["a library moved out of the media root"]
  },
  {
    # Removing this still refuses, via NoMethodError; `detects` pins the difference.
    label: "the exactly-once render check",
    from: '  abort "Komga contract failed: #{name} is not rendered exactly once" unless values.length == 1',
    to: "  nil",
    rows: ["a config path the environment template no longer renders"],
    detects: "refused for the wrong reason"
  },
  {
    label: "the restart policy check",
    from: 'service.fetch("restart") == "unless-stopped"',
    to: "true",
    rows: ["a restart policy that is not unless-stopped"]
  },
  {
    label: "the logging policy check",
    from: 'abort "Komga contract failed: logging policy differs" unless service.fetch("logging") == {',
    to: 'abort "Komga contract failed: logging policy differs" unless true || service.fetch("logging") == {',
    rows: ["unbounded container logging"]
  },
  {
    label: "the application healthcheck check",
    from: "  service.fetch(\"healthcheck\") == {\n",
    to: "  true || service.fetch(\"healthcheck\") == {\n",
    rows: ["an application healthcheck that no longer requires an UP body"]
  },
  {
    label: "the Mac override narrowness check",
    from: 'mac_service.keys.sort == %w[container_name ports] && !mac_service.key?("image")',
    to: "true",
    rows: ["a Mac override that widens beyond name and ports"]
  },
  {
    label: "the managed library model check",
    from: 'defaults.fetch("komga_libraries") == expected_libraries',
    to: "true",
    rows: ["a managed library model that is no longer exactly Comics and Ebooks"]
  },
  {
    label: "the retired singular input check",
    from: 'defaults.key?("komga_library_name") || defaults.key?("komga_library_root")',
    to: "false",
    rows: ["a retired singular library input that came back"]
  },
  {
    label: "the managed scan schedule check",
    from: 'defaults.fetch("komga_library_settings").fetch("scanInterval") == "HOURLY"',
    to: "true",
    rows: ["a scan schedule that is no longer hourly"]
  },
  {
    label: "the managed scan exclusion check",
    from: 'defaults.fetch("komga_library_settings").fetch("scanDirectoryExclusions") == [".acquisition"]',
    to: "true",
    rows: ["a dropped .acquisition scan exclusion"]
  },
  {
    label: "the one-convergence migration input check",
    from: 'defaults.fetch("komga_library_root_migration_allowed") == false',
    to: "true",
    rows: ["a root migration input that defaults to true"]
  },
  {
    label: "the one-convergence migration inventory check",
    from: '  inventory.fetch("komga_library_root_migration_allowed", false) == false',
    to: "  true",
    rows: ["a root migration input left true in the inventory that outranks the defaults"]
  },
  {
    label: "the plural library model declaration check",
    from: '  library_options.dig("komga_libraries", "type") == "list" &&',
    to: "  true ||",
    rows: ["a plural library model that is undeclared in argument_specs"]
  },
  {
    label: "the health timing defaults check",
    from: 'defaults.values_at("komga_health_retries", "komga_health_delay") == [60, 3]',
    to: "true",
    rows: ["drifted application health timing defaults"]
  },
  {
    label: "the health timing declaration check",
    from: '  health_options&.slice("komga_health_retries", "komga_health_delay") == {',
    to: "  true || health_options&.slice(\"komga_health_retries\", \"komga_health_delay\") == {",
    rows: ["application health timing arguments that are undeclared"]
  },
  {
    label: "the exactly-once readiness check",
    from: "  health_tasks.length == 1",
    to: "  health_tasks.length >= 1",
    rows: ["an application readiness task that occurs twice"]
  },
  {
    label: "the readiness ordering check",
    from: "  deploy_index && claim_index && deploy_index < health_index && health_index < claim_index",
    to: "  deploy_index && claim_index",
    rows: ["readiness that no longer gates claim reconciliation"]
  },
  {
    label: "the readiness request check",
    from: '  health_task["ansible.builtin.uri"] == {',
    to: '  true || health_task["ansible.builtin.uri"] == {',
    rows: ["a readiness request against some other endpoint"]
  },
  {
    label: "the readiness status gate check",
    from: '  health_task.values_at("register", "until", "retries", "delay", "changed_when", "check_mode") == [',
    to: '  true || health_task.values_at("register", "until", "retries", "delay", "changed_when", "check_mode") == [',
    rows: ["a readiness gate that accepts any status body"]
  },
  {
    label: "the required task existence sweep",
    from: '  abort "Komga contract failed: missing #{name}" unless role_names.include?(name)',
    to: "  next if name",
    rows: ["a required task that survives only under a different name"]
  },
  {
    label: "the global preflight ordering check",
    from: "  preflight.none?(&:nil?) && mutations.none?(&:nil?) && preflight.max < mutations.min",
    to: "  preflight.none?(&:nil?) && mutations.none?(&:nil?)",
    rows: ["a library preflight that no longer precedes every mutation"],
    # Cascade: the managed-user ordering check shares the `preflight` array and
    # refuses instead.
    detects: "refused for the wrong reason"
  },
  {
    label: "the repair-before-creation ordering check",
    from: '  role_at.call("Repair the managed Komga library") <
    role_at.call("Create the managed Komga library")',
    to: "  true",
    rows: ["a library creation ordered before the repair that frees its root"]
  },
  {
    label: "the trailing-slash normalization check",
    from: '    .include?("regex_replace(\'/+$\', \'\')")',
    to: "    .then { true }",
    rows: ["managed root matching that dropped its trailing-slash filter"]
  },
  {
    label: "the selected-identifier check",
    from: '    .include?("item.id | urlencode")',
    to: "    .then { true }",
    rows: ["a library repair that no longer targets the selected identifier"]
  },
  {
    # The whole condition: with `that` gone, `any?` on [] is already false.
    label: "the one-convergence gating check",
    from: '  Array(role_task.call("Refuse ambiguous Komga library candidates")
    .dig("ansible.builtin.assert", "that")).any? do |condition|
    condition.to_s.include?("komga_library_root_migration_allowed | bool")
  end',
    to: "  true",
    rows: ["an ambiguity guard that lost its one-convergence clause"]
  },
  {
    label: "the managed-user preflight ordering check",
    from: "  user_mutation && preflight.none?(&:nil?) && preflight.max < user_mutation &&\n    user_mutation < mutations.min",
    to: "  user_mutation && preflight.none?(&:nil?)",
    rows: ["managed-user reconciliation ordered before the library preflight"]
  },
  {
    label: "the opaque-database absence check",
    from: "  deep_strings(role_tasks).any? { |value| value.match?(/sqlite|database\\.sqlite|tasks\\.sqlite/i) }",
    to: "  false",
    rows: ["a task that reaches into Komga's own database"]
  }
].freeze

RUNTIME_MUTATIONS = [
  {
    label: "the vault decryption check",
    from: 'fail_contract("encrypted vault could not be read") unless vault_status.success?',
    to: "nil unless vault_status.success?",
    rows: ["a vault that cannot be decrypted"],
    # Without the refusal the next fetch raises a stack trace instead.
    detects: "refused for the wrong reason"
  },
  {
    label: "the administrator identity check",
    from: '  me.fetch("email") == credentials.first && Array(me.fetch("roles")).include?("ADMIN")',
    to: "  true",
    rows: ["an administrator whose identity is not the vault's",
           "an administrator without the ADMIN role"]
  },
  {
    label: "the library listing schema check",
    from: 'fail_contract("library listing schema differs") unless libraries.is_a?(Array)',
    to: "return nil unless libraries.is_a?(Array)",
    rows: ["a library listing that is not a list"],
    detects: "refused for the wrong reason"
  },
  {
    label: "the managed candidate schema check",
    from: '  fail_contract("managed library candidate schema differs") unless candidates.all? do |entry|',
    to: "  [] .each do |entry|",
    rows: ["a managed library candidate with an opaque identifier"]
  },
  {
    label: "the single managed root check",
    from: '  fail_contract("managed library root is absent or duplicated") unless root_matches.length == 1',
    to: "  nil unless root_matches.length == 1",
    rows: ["two libraries claiming the managed root"]
  },
  {
    label: "the managed name binding check",
    from: '    name_matches.length == 1 && name_matches.fetch(0).fetch("id") == root_matches.fetch(0).fetch("id")',
    to: "    true",
    rows: ["the managed name bound to some other library"],
    # Cascade: `not at its declared root` refuses instead. It is unreachable while
    # the binding check holds, so it gets no row of its own.
    detects: "refused for the wrong reason"
  },
  {
    label: "the owned settings comparison",
    from: '      actual.fetch(key) == value',
    to: "      true",
    rows: ["a drifted owned setting on the managed library",
           "a drifted owned setting on the second managed library"]
  },
  {
    label: "the absent-Docker-healthcheck check",
    from: '  fail_contract("#{KOMGA_CONTAINER} unexpectedly defines a Docker healthcheck") unless',
    to: "  nil unless",
    rows: ["a container that declares a Docker healthcheck where none is allowed"]
  },
  {
    label: "the unknown mode refusal",
    from: 'fail_contract("unknown mode: #{MODE}") unless %w[seed assert-persistence].include?(MODE)',
    to: "nil unless %w[seed assert-persistence].include?(MODE)",
    rows: ["a mode the program does not dispatch"]
  },
  {
    label: "the comic fixture byte comparison",
    from: '    fail_contract("comic fixture bytes drifted") unless FIXTURE_PATH.file? && FIXTURE_PATH.binread == bytes',
    to: "    nil unless FIXTURE_PATH.file? && FIXTURE_PATH.binread == bytes",
    rows: ["a comic fixture whose bytes drifted"]
  },
  {
    label: "the persistence artifact replacement refusal",
    from: '  fail_contract("refusing to replace Komga persistence artifact") if STATE_PATH.exist? || STATE_PATH.symlink?',
    to: "  nil if STATE_PATH.exist? || STATE_PATH.symlink?",
    rows: ["a seed that would replace an existing persistence artifact"],
    detects: "refused for the wrong reason"
  },
  {
    label: "the report root safety check",
    from: '  fail_contract("report root is unavailable or unsafe") unless REPORT_ROOT.directory? && !REPORT_ROOT.symlink?',
    to: "  nil unless REPORT_ROOT.directory? && !REPORT_ROOT.symlink?",
    rows: ["a seed whose report root is a symlink"]
  },
  {
    label: "the persistence artifact safety check",
    from: '  fail_contract("Komga persistence artifact is unavailable or unsafe") unless STATE_PATH.file? && !STATE_PATH.symlink?',
    to: "  nil unless STATE_PATH.file? && !STATE_PATH.symlink?",
    rows: ["persistence asserted with no artifact present"],
    detects: "refused for the wrong reason"
  },
  {
    label: "the persisted identifier comparison",
    from: '    snapshot.fetch("libraries").map { |entry| entry.fetch("id") } ==
      library_state.fetch("libraries").map { |entry| entry.fetch("id") }',
    to: "    true",
    rows: ["a managed library identifier that changed across recreation"],
    # Cascade: the whole-snapshot comparison subsumes the identifier one.
    detects: "refused for the wrong reason"
  },
  {
    label: "the persisted settings comparison",
    from: '    snapshot.fetch("libraries") == library_state.fetch("libraries")',
    to: "    true",
    rows: ["a managed library setting that changed across recreation"]
  },
  {
    label: "the unrelated library survival check",
    from: '      libraries.any? do |entry|
        entry.is_a?(Hash) && entry.values_at("id", "name", "root") ==
          expected.values_at("id", "name", "root")
      end',
    to: "      true",
    rows: ["an unrelated library that did not survive recreation"]
  },
  {
    label: "the installed pre-migration state check",
    from: '    legacy.fetch("scanInterval") == "DISABLED"',
    to: "    true",
    rows: ["a pre-migration state whose scan schedule was never disabled"]
  },
  {
    label: "the collapsed Ebooks library check",
    from: '    libraries.any? { |entry| entry.is_a?(Hash) && entry["name"] == "Ebooks" }',
    to: "    false",
    rows: ["a pre-migration collapse the Ebooks library survived"]
  },
  {
    label: "the drift fixture check",
    from: '    library.fetch("name") == LEGACY_LIBRARY_NAME && library.fetch("scanOnStartup") == true',
    to: "    true",
    # The refusing row: the accepting one stays green without the check.
    rows: ["a half-installed drift whose scan-on-startup never moved"]
  },
  {
    label: "the recorded pre-migration identifier check",
    from: '    legacy_id_path.file? && !legacy_id_path.symlink?',
    to: "    true",
    rows: ["a migration verified with no recorded identifier"],
    detects: "refused for the wrong reason"
  },
  {
    label: "the in-place migration check",
    from: '    library.fetch("id") == legacy_id_path.read.strip',
    to: "    true",
    rows: ["a migration that replaced the library instead of repointing it"]
  }
].freeze

# Each is a line that changes no outcome today, so it needs a plant.
WRAPPER_MUTATIONS = [
  {
    label: "a dropped stdin redirect on the static invocation",
    from: %(  "$argument_specs" "$environment" "$inventory" </dev/null\n),
    to: %(  "$argument_specs" "$environment" "$inventory"\n),
    layer: :stdin
  },
  {
    label: "a dropped stdin redirect on the runtime invocation",
    from: %(exec ruby "$runtime_program" "$mode" "$@" </dev/null\n),
    to: %(exec ruby "$runtime_program" "$mode" "$@"\n),
    layer: :stdin
  },
  {
    label: "the static program resolved from the inspected tree",
    from: "static_program=$contract_repo_dir/tests/contracts/komga-static.rb",
    to: "static_program=$repo_dir/tests/contracts/komga-static.rb",
    layer: :two_roots
  },
  {
    label: "the runtime program resolved from the inspected tree",
    from: "runtime_program=$contract_repo_dir/tests/contracts/komga-runtime.rb",
    to: "runtime_program=$repo_dir/tests/contracts/komga-runtime.rb",
    layer: :two_roots
  },
  {
    label: "the inspected-tree export rerooted to the checkout",
    from: "PLATFORM_CONTRACT_REPO_DIR=$repo_dir\n",
    to: "PLATFORM_CONTRACT_REPO_DIR=$contract_repo_dir\n",
    layer: :two_roots
  },
  {
    label: "the mode guard",
    from: %([ "$mode" = static ] && { printf '%s\\n' 'Komga static contract passed'; exit 0; }),
    to: %([ "$mode" != static ] && { printf '%s\\n' 'Komga static contract passed'; exit 0; }),
    layer: :wrapper
  },
  {
    label: "the media root requirement",
    from: %(: "${PLATFORM_MEDIA_ROOT:?PLATFORM_MEDIA_ROOT is required}"),
    to: %(: "${PLATFORM_MEDIA_ROOT:=}"),
    layer: :wrapper
  },
  {
    label: "the report root requirement",
    from: %(: "${PLATFORM_REPORT_ROOT:?PLATFORM_REPORT_ROOT is required}"),
    to: %(: "${PLATFORM_REPORT_ROOT:=}"),
    layer: :wrapper
  },
  {
    label: "the invalid runtime context refusal",
    from: "  *) fail_contract 'Komga runtime context is invalid' ;;",
    to: "  *) PLATFORM_KOMGA_CONTAINER=komga ;;",
    layer: :wrapper
  },
  {
    label: "the integration runtime context refusal",
    from: "    *) fail_contract 'integration Komga runtime context differs' ;;",
    to: "    *) ;;",
    layer: :wrapper
  },
  {
    label: "the fixture scan timeout guard",
    from: %(grep -qx 'FIXTURE_SCAN_TIMEOUT_SECONDS = 240' "$runtime_program" ||\n),
    to: %(true ||\n),
    layer: :self_read
  },
  {
    label: "the unrelated library root guard",
    from: %(grep -q '^UNRELATED_LIBRARY_ROOT = "/config/\\.nas-platform-unmanaged"$' "$runtime_program" ||\n),
    to: %(true ||\n),
    layer: :self_read
  },
  {
    # Left reading "$0" the negated guard is trivially true against the wrapper.
    label: "the unsafe media-root fallback guard rerooted back to the wrapper",
    from: %(    "$runtime_program" >/dev/null; then\n),
    to: %(    "$0" >/dev/null; then\n),
    layer: :self_read
  }
].freeze

def report_mutation(collected, mutation, caught, rows)
  detects = mutation.fetch(:detects, "accepted what it must refuse")
  if caught.empty?
    collected << "removing #{mutation.fetch(:label)} was accepted by #{rows.length} row(s)"
  elsif !caught.all? { |failure| failure.include?(detects) }
    collected << "removing #{mutation.fetch(:label)} was caught by the wrong assertion: " \
                 "#{caught.join(' | ')}"
  end
end

if ARGV.include?("--self-test")
  mismatches = []
  planted = 0

  # Plants are prepared on the main thread: an abort inside a worker raises
  # SystemExit there and surfaces as a KeyError instead of its sentence.
  static_cases = STATIC_MUTATIONS.map do |mutation|
    [mutation,
     plant(File.read(STATIC_PROGRAM), mutation),
     rows_named(STATIC_ROWS, mutation.fetch(:rows))]
  end
  runtime_cases = RUNTIME_MUTATIONS.map do |mutation|
    [mutation,
     plant(File.read(RUNTIME_PROGRAM), mutation),
     rows_named(RUNTIME_ROWS, mutation.fetch(:rows))]
  end
  wrapper_cases = WRAPPER_MUTATIONS.map { |mutation| [mutation, plant(File.read(CONTRACT), mutation)] }

  in_parallel_cases(mismatches, static_cases) do |(mutation, source, rows), collected|
    Dir.mktmpdir("nas-platform-komga-mutant.") do |directory|
      path = File.join(directory, "komga-static.rb")
      File.write(path, source)
      report_mutation(collected, mutation, static_failures(path, rows), rows)
    end
  end
  planted += STATIC_MUTATIONS.length

  in_parallel_cases(mismatches, runtime_cases) do |(mutation, source, rows), collected|
    Dir.mktmpdir("nas-platform-komga-mutant.") do |directory|
      path = File.join(directory, "komga-runtime.rb")
      File.write(path, source)
      report_mutation(collected, mutation, runtime_failures(path, rows), rows)
    end
  end
  planted += RUNTIME_MUTATIONS.length

  in_parallel_cases(mismatches, wrapper_cases) do |(mutation, source), collected|
    caught = case mutation.fetch(:layer)
             when :stdin then stdin_failures(wrapper_source: source)
             when :two_roots then two_roots_failures(wrapper_source: source)
             when :self_read then self_read_failures(wrapper_source: source)
             else wrapper_failures(wrapper_source: source)
             end
    collected << "removing #{mutation.fetch(:label)} was accepted" if caught.empty?
  end
  planted += WRAPPER_MUTATIONS.length

  unless mismatches.empty?
    mismatches.each { |mismatch| warn "FAIL self-test: #{mismatch}" }
    abort "#{mismatches.length} self-test mismatch(es) of #{planted} planted regressions"
  end

  puts "komga contract: self-test detects #{planted} planted regressions"
  exit
end

failures = static_failures + runtime_failures + wrapper_failures +
           self_read_failures + stdin_failures + two_roots_failures
unless failures.empty?
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} Komga contract violation(s)"
end

puts "komga contract: #{STATIC_ROWS.length} static and #{RUNTIME_ROWS.length} runtime " \
     "properties hold, all #{SELF_READ_ROWS.length} self-read guards bite now that " \
     "02d60e2's tautology is gone, and the wrapper reaches both programs from its own " \
     "checkout, against the inspected tree, with an empty stdin"
