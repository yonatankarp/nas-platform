#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Behaviour of the Immich service contract's two Ruby programs.
#
# Until #147 both lived in `<<'RUBY'` heredocs inside tests/contracts/immich.sh --
# 1,786 of that file's 1,863 lines, the largest pair in the repository. `sh -n`
# reads a quoted heredoc as opaque text, so the only thing that ever executed
# either one was an integration lane with Docker, a converged four-container
# Immich and a real vault. tests/contracts/immich-static.rb and
# tests/contracts/immich-runtime.rb are files now, so both are reachable here.
#
# Three layers, because the contract has three kinds of property:
#
#   Static -- build a fixture repository from the files the contract reads, break
#   exactly one thing in it, and require the program to name that thing. The
#   assertion text is the interface: a guard that fails for the wrong reason has
#   stopped guarding what it names, so every row pins the exact diagnostic. The
#   rows run through in_parallel_cases because there are enough of them to matter
#   to the gate.
#
#   Runtime -- serve the Immich interface from an HTTP fixture and put `docker`
#   and `ansible-vault` stubs on PATH, so the health, login, containment and
#   settings outcomes can each be moved one at a time. This layer deliberately
#   stops where it stops: it covers the whole prefix of the program up to and
#   including assert_managed_settings, which `MODE=run` exits at when the vault
#   declares no managed users. Reaching past that means fixturing managed-user
#   preference reconciliation, asset upload, thumbnailing and CPU machine
#   learning -- a large and flaky lift, and tests/immich_smart_search_retry_test.rb
#   already evals the machine-learning retry slice out of this same file.
#
#   Wrapper -- tests/contracts/immich.sh is what turns a platform and a mode into
#   two invocations. Its rows prove the platform guard, that both programs are
#   actually reached, that each is resolved from the script's own checkout while
#   the tree to inspect is passed in, and that neither can consume the caller's
#   stdin.
#
# Run with --self-test to plant a regression in each program and prove the rows
# above detect it.

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
DIAGNOSTIC_PREFIX = "Immich contract failed: "
CONTRACT = File.join(ROOT, "tests", "contracts", "immich.sh")
STATIC_PROGRAM = File.join(ROOT, "tests", "contracts", "immich-static.rb")
RUNTIME_PROGRAM = File.join(ROOT, "tests", "contracts", "immich-runtime.rb")

# The `-ryaml` preload tests/contracts/immich.sh carries, because the static
# program does not require yaml itself. Every invocation of it here must carry
# the same preload or every row fails identically on an uninitialized constant,
# which would read as the extraction having broken everything.
STATIC_COMMAND = [RbConfig.ruby, "-ryaml"].freeze

# Exactly what the static half reads. A fixture holding only these is the proof
# that the list is the list the program actually needs -- immich-runtime.rb
# included, because the static half reads the runtime half's source out of the
# tree it is inspecting to require the unowned-sentinel logic to be live.
FIXTURE_FILES = %w[
  roles/immich/tasks/main.yml
  roles/immich/tasks/user_onboarding.yml
  roles/immich/tasks/configured_password.yml
  roles/immich/tasks/managed_users.yml
  roles/immich/defaults/main.yml
  services/immich/compose.yml
  services/immich/compose.mac.yml
  services/immich/compose.integration.yml
  tests/contracts/immich.sh
  tests/contracts/immich-static.rb
  tests/contracts/immich-runtime.rb
].freeze

# Runs independent cases through a worker pool, capped at the core count. The
# same shape and the same reasoning as in_parallel_cases in
# tests/media_acquisition_reconciliation_support.rb: a check that spawns a
# subprocess per case, serially, becomes the floor for the whole policy gate, and
# oversubscribing a four-core CI runner trades wall time for contention. Never
# more workers than cores.
CASE_WORKER_LIMIT = Integer(ENV.fetch("IMMICH_CONTRACT_CASE_WORKERS") { [Etc.nprocessors, 8].min.to_s }, 10)

def in_parallel_cases(items)
  items = items.to_a
  workers = [CASE_WORKER_LIMIT, items.length].min
  return items.flat_map { |item| yield item } if workers <= 1

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
        # A row whose fixture edit raises is a broken row, not a crashed suite:
        # without this the worker thread dies and the pool reports nothing about
        # the other rows it was carrying.
        local = begin
          yield item
        rescue StandardError => error
          ["#{item.is_a?(Hash) ? item.fetch(:name, item) : item}: fixture raised " \
           "#{error.class}: #{error.message}"]
        end
        lock.synchronize { collected[index] = local }
      end
    end
  end.each(&:join)
  collected.keys.sort.flat_map { |index| collected.fetch(index) }
end

def build_fixture_repository(root)
  FIXTURE_FILES.each do |relative|
    destination = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(destination))
    FileUtils.cp(File.join(ROOT, relative), destination)
    File.chmod(0o755, destination) if relative.end_with?(".sh")
  end
end

def edit_yaml(root, relative)
  path = File.join(root, relative)
  document = YAML.safe_load_file(path, aliases: true)
  yield document
  File.write(path, YAML.dump(document))
end

def edit_text(root, relative)
  path = File.join(root, relative)
  File.write(path, yield(File.read(path)))
end

# Renames a task in place, which is how a "required task survives only as a
# comment" regression looks to a program that reads parsed tasks rather than
# text.
def rename_task(root, relative, from, to = "Renamed task")
  edit_yaml(root, relative) do |document|
    target = document.find { |task| task.is_a?(Hash) && task["name"] == from }
    raise "fixture has no task named #{from.inspect} in #{relative}" unless target

    target["name"] = to
  end
end

def compose_service(root, name)
  edit_yaml(root, "services/immich/compose.yml") do |document|
    yield document.fetch("services").fetch(name)
  end
end

# --- static layer ----------------------------------------------------------
#
# One row per assertion family rather than one per refuse() site. The static half
# has 116 of those; covering each individually would put this file on the policy
# gate's critical path for no additional signal, because a family shares its
# read, its parse and its shape. Each row below breaks a different one of those.

STATIC_ROWS = [
  { name: "an intact repository", break: ->(_root) {}, expects: nil },
  {
    name: "a container missing from the stack",
    break: ->(root) { edit_yaml(root, "services/immich/compose.yml") { |d| d.fetch("services").delete("redis") } },
    expects: "stack composition differs: database, immich-machine-learning, immich-server"
  },
  {
    name: "the server and machine learning versions drifting apart",
    break: lambda { |root|
      compose_service(root, "immich-machine-learning") do |spec|
        spec["image"] = spec.fetch("image").sub(/:([^:@\/]+)@sha256:/, ':v0.0.0-drifted@sha256:')
      end
    },
    expects: "Immich server and machine learning versions differ"
  },
  {
    name: "a restart policy that is not unless-stopped",
    break: ->(root) { compose_service(root, "redis") { |spec| spec["restart"] = "always" } },
    expects: "redis restart policy differs"
  },
  {
    # compose.yml declares one logging block and aliases it into every
    # container, so editing any of them edits all of them and the first one
    # checked is the one reported.
    name: "a logging policy without a rotation bound",
    break: ->(root) { compose_service(root, "database") { |spec| spec["logging"]["options"].delete("max-file") } },
    expects: "immich-server logging policy differs"
  },
  {
    name: "the application port renumbered",
    break: ->(root) { compose_service(root, "immich-server") { |spec| spec["ports"] = ["3283:2283"] } },
    expects: "NAS port differs"
  },
  {
    name: "a database publishing a host port",
    break: ->(root) { compose_service(root, "database") { |spec| spec["ports"] = ["5432:5432"] } },
    expects: "database must not publish a host port"
  },
  {
    name: "the model cache storage moved",
    break: lambda { |root|
      compose_service(root, "immich-machine-learning") { |spec| spec["volumes"] = ["${NAS_DOCKER_ROOT:?}/immich/elsewhere:/cache"] }
    },
    expects: "model cache storage differs"
  },
  {
    name: "startup ordering dropped",
    break: lambda { |root|
      compose_service(root, "immich-server") do |spec|
        spec["depends_on"] = { "redis" => { "condition" => "service_started" },
                               "database" => { "condition" => "service_healthy" } }
      end
    },
    expects: "startup ordering differs"
  },
  {
    name: "a health check disabled",
    break: ->(root) { compose_service(root, "immich-server") { |spec| spec["healthcheck"] = { "disable" => true } } },
    expects: "immich-server health check is disabled"
  },
  {
    name: "the database shared memory shrunk",
    break: ->(root) { compose_service(root, "database") { |spec| spec["shm_size"] = "64mb" } },
    expects: "database shared memory differs"
  },
  {
    name: "the NAS render device unmapped",
    break: ->(root) { compose_service(root, "immich-server") { |spec| spec["devices"] = [] } },
    expects: "NAS render device mapping is absent"
  },
  {
    name: "the outbound version check re-enabled",
    break: lambda { |root|
      edit_yaml(root, "roles/immich/defaults/main.yml") do |document|
        document.fetch("immich_managed_settings").fetch("newVersionCheck")["enabled"] = true
      end
    },
    expects: "managed settings must disable the outbound version check"
  },
  {
    name: "machine learning disabled in the managed settings",
    break: lambda { |root|
      edit_yaml(root, "roles/immich/defaults/main.yml") do |document|
        document.fetch("immich_managed_settings").fetch("machineLearning")["enabled"] = false
      end
    },
    expects: "managed settings must keep machine learning enabled"
  },
  {
    name: "the database backup disabled",
    break: lambda { |root|
      edit_yaml(root, "roles/immich/defaults/main.yml") do |document|
        document.fetch("immich_managed_settings").fetch("backup").fetch("database")["enabled"] = false
      end
    },
    expects: "managed settings must keep the database backup enabled"
  },
  {
    name: "the pinned standard preference profile edited",
    break: lambda { |root|
      edit_yaml(root, "roles/immich/defaults/main.yml") do |document|
        document.fetch("immich_managed_user_preference_profiles").fetch("standard").fetch("ratings")["enabled"] = true
      end
    },
    expects: "standard managed-user preference profile differs from pinned v3.1.0 policy"
  },
  {
    name: "a test-only compact profile selected in production",
    break: lambda { |root|
      edit_yaml(root, "roles/immich/defaults/main.yml") do |document|
        document["immich_managed_user_preference_overrides"] = { "someone@example.invalid" => { "ratings" => { "enabled" => true } } }
      end
    },
    expects: "production inventory must not select the test-only compact profile"
  },
  # The assertion the extraction repointed. It reads the runtime half's source
  # out of the tree under inspection and requires the sentinel logic to be live
  # in it. Two rows, because the interesting failure is not only "the sentinel is
  # gone" but "the file it is read from is the wrong one".
  {
    name: "a dormant supported-unowned-preference sentinel",
    break: lambda { |root|
      edit_text(root, "tests/contracts/immich-runtime.rb") do |source|
        source.gsub("supported unowned managed preference", "retired sentinel wording")
      end
    },
    expects: "runtime contract permits a dormant supported preference sentinel"
  },
  {
    name: "the runtime half absent from the tree under inspection",
    break: ->(root) { FileUtils.rm(File.join(root, "tests/contracts/immich-runtime.rb")) },
    expects: nil,
    # Honestly a crash rather than a diagnostic: the sentinel read has no
    # existence guard in front of it, so the file's absence surfaces as Errno.
    # Both halves are required so the row cannot pass on the filename alone.
    expects_crash: ["immich-runtime.rb", "No such file or directory"]
  },
  {
    # The mac override is edited as text throughout. safe_load erases the
    # `!override` tag and YAML.dump never restores it, so a round-trip through
    # the parser trips "must reset devices with an explicit tag" before the row
    # can reach the assertion it is actually about.
    name: "the mac override adding a service",
    platform: "mac",
    break: lambda { |root|
      edit_text(root, "services/immich/compose.mac.yml") do |source|
        "#{source}\n  surplus:\n    container_name: surplus\n"
      end
    },
    expects: "mac override may not add services: surplus"
  },
  {
    name: "the mac override publishing a helper port",
    platform: "mac",
    break: lambda { |root|
      edit_text(root, "services/immich/compose.mac.yml") do |source|
        source.sub(/^(  database:\n    container_name: [^\n]*\n)/,
                   "\\1    ports:\n      - \"5432:5432\"\n")
      end
    },
    expects: "mac override must not publish a host port on database"
  },
  {
    # The surplus-key sweep runs before the image guard and reports first; both
    # are the same property stated twice, and this pins the one that fires.
    name: "the mac override redefining an image",
    platform: "mac",
    break: lambda { |root|
      edit_text(root, "services/immich/compose.mac.yml") do |source|
        source.sub(/^(  redis:\n    container_name: [^\n]*\n)/,
                   "\\1    image: example:1.0.0\n")
      end
    },
    expects: "mac override may not redefine image on redis"
  },
  {
    name: "a device reset that lost its explicit override tag",
    platform: "mac",
    break: lambda { |root|
      edit_text(root, "services/immich/compose.mac.yml") do |source|
        source.sub("devices: !override []", "devices: []")
      end
    },
    expects: "mac override must reset devices with an explicit tag"
  },
  {
    name: "a production override file that should not exist",
    break: ->(root) { FileUtils.cp(File.join(root, "services/immich/compose.mac.yml"), File.join(root, "services/immich/compose.nas.yml")) },
    expects: "the NAS runs the production definition unmodified"
  },
  {
    name: "a required onboarding task renamed",
    break: ->(root) { rename_task(root, "roles/immich/tasks/user_onboarding.yml", "Complete configured Immich user onboarding") },
    expects: "configured Immich user onboarding lifecycle is incomplete"
  },
  {
    name: "an onboarding task that shells into the database",
    break: lambda { |root|
      edit_yaml(root, "roles/immich/tasks/user_onboarding.yml") do |document|
        document.unshift("name" => "Patch the Immich onboarding rows",
                         "ansible.builtin.command" => { "argv" => %w[psql --command] + ["INSERT INTO users"] },
                         "changed_when" => false)
      end
    },
    expects: "Immich user onboarding role contains a database write path"
  },
  {
    name: "a required main-role task renamed",
    break: ->(root) { rename_task(root, "roles/immich/tasks/main.yml", "Read Immich initialization state") },
    expects: "missing Read Immich initialization state"
  },
  {
    name: "the managed-user preference read gone",
    break: ->(root) { rename_task(root, "roles/immich/tasks/managed_users.yml", "Read Immich managed user preferences") },
    expects: "managed user preference read is absent"
  },
  {
    name: "a managed-user preference read that stops addressing a target",
    break: lambda { |root|
      edit_yaml(root, "roles/immich/tasks/managed_users.yml") do |document|
        target = document.find { |task| task.is_a?(Hash) && task["name"] == "Read Immich managed user preferences" }
        raise "fixture has no managed preference read" unless target

        target.fetch("ansible.builtin.uri")["url"] = "{{ immich_api }}/users/me/preferences"
      end
    },
    expects: "managed user preference read does not address a target through the admin API"
  },
  {
    name: "a managed-user preference repair that is no longer a PATCH",
    break: lambda { |root|
      edit_yaml(root, "roles/immich/tasks/managed_users.yml") do |document|
        target = document.find { |task| task.is_a?(Hash) && task["name"] == "Repair Immich managed user preferences" }
        raise "fixture has no managed preference repair" unless target

        target.fetch("ansible.builtin.uri")["method"] = "PUT"
      end
    },
    expects: "managed user preference repair must use the pinned v3 PATCH"
  },
  {
    name: "a managed-user preference repair that sends the avatar too",
    break: lambda { |root|
      edit_yaml(root, "roles/immich/tasks/managed_users.yml") do |document|
        target = document.find { |task| task.is_a?(Hash) && task["name"] == "Repair Immich managed user preferences" }
        raise "fixture has no managed preference repair" unless target

        target.fetch("ansible.builtin.uri")["body"] =
          "{{ immich_managed_user_desired_preferences[item.item.email] | combine({'avatarColor': 'primary'}) }}"
      end
    },
    expects: "managed user preference repair must not send avatar"
  },
  {
    name: "the non-administrator guard on preference targets gone",
    break: ->(root) { rename_task(root, "roles/immich/tasks/managed_users.yml", "Require non-administrator Immich managed preference targets") },
    expects: "managed user preference non-administrator guard is absent"
  },
  {
    name: "a configured-password task renamed",
    break: ->(root) { rename_task(root, "roles/immich/tasks/configured_password.yml", "Require unique desired configured Immich identities") },
    expects: "configured-password"
  },
  {
    name: "a declared file that is gone",
    break: ->(root) { FileUtils.rm(File.join(root, "services/immich/compose.integration.yml")) },
    platform: "integration",
    expects: "services/immich/compose.integration.yml is absent"
  }
].freeze

def static_failures(program = STATIC_PROGRAM, rows = STATIC_ROWS)
  in_parallel_cases(rows) do |row|
    Dir.mktmpdir("nas-platform-immich-static.") do |raw|
      root = File.realpath(raw)
      build_fixture_repository(root)
      row.fetch(:break).call(root)
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => root },
        *STATIC_COMMAND, program, root, row.fetch(:platform, "nas")
      )
      judge("static: #{row.fetch(:name)}", row.fetch(:expects), stdout, stderr, status,
            prefix: DIAGNOSTIC_PREFIX, expects_crash: row[:expects_crash])
    end
  end
end

# --- runtime layer ---------------------------------------------------------
#
# The runtime half needs a deployed Immich. What it actually needs is an HTTP
# interface, a `docker inspect`, an `ansible-vault view` and a policy file, and
# all four can be fixtured. The vault declares no managed users, which is what
# lets `MODE=run` reach its own success line: with an empty list the
# managed-user profile reconciliation has nothing to walk, so the covered prefix
# ends at assert_managed_settings and every row below moves one thing inside it.

ADMIN_EMAIL = "immich-admin@example.invalid"
ADMIN_PASSWORD = "contract-fixture-password"
ADMIN_ID = "immich-contract-admin-id"
DESIGNATED_EMAIL = "managed@example.invalid"

RUNTIME_DEFAULTS = {
  initialized: true,
  wrong_password_status: 401,
  login_status: 201,
  session: nil,
  admin_record: nil,
  onboarding: { "isOnboarded" => true },
  admin_sign_up_status: 400,
  system_config: nil,
  user_listing: [],
  server_ports: { "2283/tcp" => [{ "HostPort" => "2283" }] },
  server_devices: [{ "PathInContainer" => "/dev/dri" }],
  helper_ports: {},
  vault_exit: 0,
  policy_mode: 0o600,
  designated_email: DESIGNATED_EMAIL,
  mode: "run"
}.freeze

def default_session
  { "accessToken" => "contract-token", "userId" => ADMIN_ID, "userEmail" => ADMIN_EMAIL,
    "isAdmin" => true, "shouldChangePassword" => false }
end

def default_admin_record
  { "id" => ADMIN_ID, "email" => ADMIN_EMAIL, "isAdmin" => true,
    "shouldChangePassword" => false, "status" => "active" }
end

def default_system_config
  { "newVersionCheck" => { "enabled" => false },
    "machineLearning" => { "enabled" => true },
    "backup" => { "database" => { "enabled" => true } } }
end

RUNTIME_ROWS = [
  { name: "a deployed Immich that holds", given: {}, expects: nil },
  {
    name: "an interface that accepts a wrong password",
    given: { wrong_password_status: 201 },
    expects: "POST /api/auth/login returned HTTP 201"
  },
  {
    name: "an interface that refuses the vault administrator",
    given: { login_status: 401 },
    expects: "POST /api/auth/login returned HTTP 401"
  },
  {
    name: "a login answering a different identity",
    given: { session: -> { default_session.merge("userEmail" => "someone@example.invalid") } },
    expects: "the vault administrator identity or role differs"
  },
  {
    name: "a login answering a non-administrator",
    given: { session: -> { default_session.merge("isAdmin" => false) } },
    expects: "the vault administrator identity or role differs"
  },
  {
    name: "a login that omits the password state",
    given: { session: -> { default_session.tap { |s| s.delete("shouldChangePassword") } } },
    expects: "the vault administrator login omitted shouldChangePassword"
  },
  {
    name: "a login that still requires a password change",
    given: { session: -> { default_session.merge("shouldChangePassword" => true) } },
    expects: "the vault administrator login still requires a password change"
  },
  {
    name: "a login answering an unsafe identifier",
    given: { session: -> { default_session.merge("userId" => "../../etc/passwd") } },
    expects: "Immich returned an unsafe API identifier"
  },
  {
    name: "an authoritative record with an unsupported schema",
    given: { admin_record: -> { default_admin_record.merge("isAdmin" => "yes") } },
    expects: "the authoritative vault administrator response has unsupported schema"
  },
  {
    name: "an authoritative record naming a different account",
    given: { admin_record: -> { default_admin_record.merge("email" => "someone@example.invalid") } },
    expects: "the authoritative vault administrator identity or role differs"
  },
  {
    name: "an authoritative record that still requires a password change",
    given: { admin_record: -> { default_admin_record.merge("shouldChangePassword" => true) } },
    expects: "the authoritative vault administrator still requires a password change"
  },
  {
    name: "an account whose onboarding never completed",
    given: { onboarding: { "isOnboarded" => false } },
    expects: "configured Immich user onboarding is incomplete"
  },
  {
    name: "an interface that admits a second administrator",
    given: { admin_sign_up_status: 201 },
    expects: "POST /api/auth/admin-sign-up returned HTTP 201"
  },
  {
    name: "an application publishing more than its own port",
    given: { server_ports: { "2283/tcp" => [{ "HostPort" => "2283" }], "5432/tcp" => [{ "HostPort" => "5432" }] } },
    expects: "the application must publish exactly its own port"
  },
  {
    name: "a NAS deployment with no render device mapped",
    given: { server_devices: [] },
    expects: "the NAS render device is not mapped"
  },
  {
    name: "a helper container publishing a host port",
    given: { helper_ports: { "6379/tcp" => [{ "HostPort" => "6379" }] } },
    # The helpers are walked in the order the wrapper exports them, so the
    # machine-learning worker is the one reported first.
    expects: "immich_machine_learning publishes host ports [\"6379/tcp\"]"
  },
  {
    name: "a managed setting the deployment does not hold",
    given: { system_config: -> { default_system_config.merge("newVersionCheck" => { "enabled" => true }) } },
    expects: "managed setting newVersionCheck.enabled differs"
  },
  {
    name: "an unreadable encrypted vault",
    given: { vault_exit: 1 },
    expects: "encrypted vault could not be read"
  },
  {
    name: "a world-readable protected fixture policy",
    given: { policy_mode: 0o644 },
    expects: "protected Immich fixture policy is unsafe"
  },
  {
    name: "a compact profile that selects an account other than the designated one",
    given: { designated_email: "someone-else@example.invalid" },
    expects: "test-only compact profile must select exactly the designated managed account"
  },
  {
    name: "a mode the program does not implement",
    given: { mode: "bogus" },
    expects: "unknown mode: bogus"
  }
].freeze

def write_stub(path, body)
  File.write(path, body)
  File.chmod(0o755, path)
end

# The policy the runtime half merges out of the repository and the protected Mac
# fixture file. Only the preference keys matter here; the fixture file is what
# names the designated compact account, and its 0600 mode is itself asserted.
def build_runtime_policy(root, options)
  inventory = File.join(root, "repo", "inventory", "group_vars", "all")
  FileUtils.mkdir_p(inventory)
  File.write(File.join(inventory, "main.yml"), YAML.dump(
                                                 "immich_managed_user_preference_profile_default" => "standard",
                                                 "immich_managed_user_preference_profile_by_email" => {},
                                                 "immich_managed_user_preference_overrides" => {},
                                                 "immich_managed_user_preference_profiles" => {
                                                   "standard" => { "ratings" => { "enabled" => false } }
                                                 }
                                               ))
  fixture = File.join(root, "fixture-vars.yml")
  File.write(fixture, YAML.dump(
                        "immich_contract_partial_profile_email" => DESIGNATED_EMAIL,
                        "immich_managed_user_preference_profile_by_email" => {
                          options.fetch(:designated_email) => "compact"
                        },
                        "immich_managed_user_preference_profiles" => {
                          "standard" => { "ratings" => { "enabled" => false } },
                          "compact" => { "ratings" => { "enabled" => false } }
                        }
                      ))
  File.chmod(options.fetch(:policy_mode), fixture)
  fixture
end

def build_runtime_sandbox(root, options)
  bin = File.join(root, "bin")
  FileUtils.mkdir_p(bin)

  containers = File.join(root, "containers")
  FileUtils.mkdir_p(containers)
  File.write(File.join(containers, "immich_server.json"), JSON.generate(
                                                            [{ "HostConfig" => { "PortBindings" => options.fetch(:server_ports),
                                                                                 "Devices" => options.fetch(:server_devices) } }]
                                                          ))
  %w[immich_machine_learning immich_redis immich_postgres].each do |name|
    File.write(File.join(containers, "#{name}.json"), JSON.generate(
                                                        [{ "HostConfig" => { "PortBindings" => options.fetch(:helper_ports) } }]
                                                      ))
  end
  write_stub(File.join(bin, "docker"), <<~SH)
    #!/bin/sh
    # Only `docker inspect NAME` is reached by the runtime half.
    [ "$1" = inspect ] || exit 64
    cat "#{containers}/$2.json"
  SH

  File.write(File.join(root, "vault-plain.yml"), YAML.dump(
                                                   "vault_immich_admin_email" => ADMIN_EMAIL,
                                                   "vault_immich_admin_password" => ADMIN_PASSWORD,
                                                   "vault_managed_users" => { "immich" => [] }
                                                 ))
  write_stub(File.join(bin, "ansible-vault"), <<~SH)
    #!/bin/sh
    cat '#{File.join(root, 'vault-plain.yml')}'
    exit #{options.fetch(:vault_exit)}
  SH
  File.write(File.join(root, "vault.yml"), "$ANSIBLE_VAULT;1.1;AES256\n0000\n")
  File.write(File.join(root, "vault-password"), "fixture\n")
  %w[media docker report].each { |name| FileUtils.mkdir_p(File.join(root, name)) }
  [bin, build_runtime_policy(root, options)]
end

# Answers exactly the endpoints the covered prefix reaches, so a row can move one
# of them without disturbing the others.
def runtime_responder(options)
  lambda do |method, target, _headers, body|
    path = target.split("?").first
    case [method.to_s.downcase, path]
    when %w[get /api/server/config]
      [200, JSON.generate("isInitialized" => options.fetch(:initialized))]
    when %w[post /api/auth/login]
      parsed = begin
        JSON.parse(body.to_s)
      rescue JSON::ParserError
        {}
      end
      if parsed["password"] == ADMIN_PASSWORD
        session = options.fetch(:session)
        [options.fetch(:login_status), JSON.generate(session ? session.call : default_session)]
      else
        [options.fetch(:wrong_password_status), JSON.generate(default_session)]
      end
    when %w[post /api/auth/admin-sign-up]
      [options.fetch(:admin_sign_up_status), JSON.generate({})]
    when %w[get /api/users/me/onboarding]
      [200, JSON.generate(options.fetch(:onboarding))]
    when %w[get /api/system-config]
      config = options.fetch(:system_config)
      [200, JSON.generate(config ? config.call : default_system_config)]
    when %w[get /api/admin/users]
      [200, JSON.generate(options.fetch(:user_listing))]
    else
      if method.to_s.casecmp("get").zero? && path.start_with?("/api/admin/users/")
        record = options.fetch(:admin_record)
        next [200, JSON.generate(record ? record.call : default_admin_record)]
      end
      [404, JSON.generate("error" => "unfixtured #{method} #{path}")]
    end
  end
end

def runtime_failures(program = RUNTIME_PROGRAM, rows = RUNTIME_ROWS)
  in_parallel_cases(rows) do |row|
    options = RUNTIME_DEFAULTS.merge(row.fetch(:given))
    collected = []
    Dir.mktmpdir("nas-platform-immich-runtime.") do |raw|
      root = File.realpath(raw)
      bin, fixture = build_runtime_sandbox(root, options)
      HttpFixtureSupport.with_http_fixture(
        lambda do |port|
          stdout, stderr, status = Open3.capture3(
            {
              "PATH" => "#{bin}:#{ENV.fetch('PATH')}",
              "PLATFORM_IMMICH_PORT" => port.to_s,
              "PLATFORM_IMMICH_PLATFORM" => "nas",
              "PLATFORM_IMMICH_SERVER_CONTAINER" => "immich_server",
              "PLATFORM_IMMICH_MACHINE_LEARNING_CONTAINER" => "immich_machine_learning",
              "PLATFORM_IMMICH_REDIS_CONTAINER" => "immich_redis",
              "PLATFORM_IMMICH_POSTGRES_CONTAINER" => "immich_postgres",
              "PLATFORM_MEDIA_ROOT" => File.join(root, "media"),
              "PLATFORM_DOCKER_ROOT" => File.join(root, "docker"),
              "PLATFORM_REPORT_ROOT" => File.join(root, "report"),
              "PLATFORM_CONTRACT_REPO_DIR" => File.join(root, "repo"),
              "PLATFORM_MAC_FIXTURE_VARS_FILE" => fixture,
              "PLATFORM_CONTRACT_VAULT_FILE" => File.join(root, "vault.yml"),
              "PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" => File.join(root, "vault-password")
            },
            RbConfig.ruby, program, options.fetch(:mode)
          )
          collected.concat(
            judge("runtime: #{row.fetch(:name)}", row.fetch(:expects), stdout, stderr, status,
                  prefix: DIAGNOSTIC_PREFIX)
          )
        end,
        &runtime_responder(options)
      )
    end
    collected
  end
end

# --- wrapper layer ---------------------------------------------------------
#
# tests/contracts/immich.sh resolves both programs from its own checkout rather
# than from the tree it is inspecting, so a copy of the three files into a
# throwaway tests/contracts/ is a whole working contract. That is what lets a row
# point PLATFORM_CONTRACT_REPO_DIR at a broken fixture and still exercise the
# real wrapper. The copy is laid into a fixture repository so it is also a valid
# tree to inspect, which is what the unset-variable rows need.

def with_contract_copy(static: File.read(STATIC_PROGRAM), runtime: File.read(RUNTIME_PROGRAM),
                       wrapper: File.read(CONTRACT))
  Dir.mktmpdir("nas-platform-immich-wrapper.") do |raw|
    root = File.realpath(raw)
    build_fixture_repository(root)
    contracts = File.join(root, "tests", "contracts")
    FileUtils.mkdir_p(contracts)
    {
      "immich.sh" => wrapper,
      "immich-static.rb" => static,
      "immich-runtime.rb" => runtime
    }.each do |name, content|
      destination = File.join(contracts, name)
      File.write(destination, content)
      File.chmod(name.end_with?(".sh") ? 0o755 : 0o644, destination)
    end
    yield File.join(contracts, "immich.sh"), root
  end
end

def wrapper_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  with_contract_copy(wrapper: wrapper_source) do |contract, copy_root|
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => ROOT }, contract, "--platform", "solaris", "static"
    )
    failures << "wrapper: an unknown platform was accepted" if status.success?
    failures << "wrapper: an unknown platform was refused without its diagnostic" unless
      (stdout + stderr).include?("Immich contract failed: unknown platform: solaris")

    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => ROOT }, contract, "--nonsense"
    )
    failures << "wrapper: an unknown flag was accepted" if status.success?
    failures << "wrapper: an unknown flag was refused with exit #{status.exitstatus}, wanted 2" unless
      status.exitstatus == 2
    failures << "wrapper: an unknown flag was refused without usage" unless
      (stdout + stderr).include?("usage: immich.sh")

    # Every platform's static mode, against this repository, through the real
    # wrapper.
    %w[mac nas integration].each do |platform|
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => ROOT }, contract, "--platform", platform, "static"
      )
      failures << "wrapper: static mode failed for #{platform}: #{(stdout + stderr).strip}" unless
        status.success?
      failures << "wrapper: static mode did not report the property it proved for #{platform}" unless
        stdout.include?("Immich static contract passed (#{platform})")
    end

    # The row that proves the wrapper still runs the static program at all: the
    # tree under inspection is broken, the wrapper's own checkout is not.
    Dir.mktmpdir("nas-platform-immich-broken.") do |broken_raw|
      broken = File.realpath(broken_raw)
      build_fixture_repository(broken)
      edit_yaml(broken, "services/immich/compose.yml") { |d| d.fetch("services").delete("redis") }
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => broken }, contract, "--platform", "nas", "static"
      )
      failures << "wrapper: static mode passed against a broken repository" if status.success?
      failures << "wrapper: static mode did not report the broken repository" unless
        (stdout + stderr).include?("stack composition differs")
    end

    # ... and that it is the *inspected* tree that is read, not the checkout the
    # programs came from. Breaking the copy's own compose.yml while pointing the
    # variable at this repository must change nothing.
    edit_yaml(copy_root, "services/immich/compose.yml") { |d| d.fetch("services").delete("redis") }
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => ROOT }, contract, "--platform", "nas", "static"
    )
    failures << "wrapper: a broken checkout was read instead of the named tree: " \
                "#{(stdout + stderr).strip}" unless status.success?
  end

  # The branch every deployment actually takes. Neither tests/integration.sh nor
  # run_contracts.rb --execute sets PLATFORM_CONTRACT_REPO_DIR, so the default is
  # the only path in production -- and it is the one where resolving the programs
  # from the script's own checkout is load-bearing rather than shadowed.
  with_contract_copy(wrapper: wrapper_source) do |contract, copy_root|
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => nil }, contract, "--platform", "nas", "static"
    )
    failures << "wrapper: static mode failed with no repository named: #{(stdout + stderr).strip}" unless
      status.success?
    failures << "wrapper: static mode did not report the property it proved" unless
      stdout.include?("Immich static contract passed (nas)")

    # ... and it read that checkout rather than some other tree: break the copy
    # and the same unset invocation must now refuse.
    edit_yaml(copy_root, "services/immich/compose.yml") { |d| d.fetch("services").delete("redis") }
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => nil }, contract, "--platform", "nas", "static"
    )
    failures << "wrapper: with no repository named, static mode inspected some other tree" if
      status.success?
    failures << "wrapper: with no repository named, static mode did not report the broken tree" unless
      (stdout + stderr).include?("stack composition differs")
  end

  # The runtime half's own root. PLATFORM_CONTRACT_REPO_DIR must reach it bound
  # to the inspected tree, not to the checkout the program was loaded from --
  # the second site of the same two-roots defect, one line over from the first.
  with_contract_copy(wrapper: wrapper_source) do |contract, copy_root|
    # A refusing `ansible-vault` prepended to the real PATH rather than a
    # replaced PATH: replacing it picks up whichever system Ruby happens to be
    # in /usr/bin, and the static half would then die in the interpreter instead
    # of the runtime half running at all.
    stub_bin = File.join(copy_root, "stub-bin")
    FileUtils.mkdir_p(stub_bin)
    write_stub(File.join(stub_bin, "ansible-vault"), "#!/bin/sh\nexit 1\n")
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => copy_root,
        "PLATFORM_MEDIA_ROOT" => copy_root, "PLATFORM_DOCKER_ROOT" => copy_root,
        "PLATFORM_REPORT_ROOT" => copy_root,
        "PLATFORM_CONTRACT_VAULT_FILE" => File.join(copy_root, "absent-vault.yml"),
        "PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" => File.join(copy_root, "absent-password"),
        "PATH" => "#{stub_bin}:#{ENV.fetch('PATH')}" },
      contract, "--platform", "nas", "run"
    )
    output = stdout + stderr
    failures << "wrapper: the runtime half was not reached: #{output.strip}" if status.success?
    # With a refusing ansible-vault the runtime half fails in its own first
    # statement, which is proof it ran and that its environment arrived.
    failures << "wrapper: the runtime half did not report its own first failure: " \
                "#{output.strip.inspect}" unless output.include?("encrypted vault could not be read")
  end
  failures
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
  # The static invocation, which runs for every mode.
  with_contract_copy(static: STDIN_PROBE, wrapper: wrapper_source) do |contract|
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => ROOT },
      "/bin/sh", "-c", "#{contract.shellescape} --platform nas static; printf 'left:'; cat",
      stdin_data: "caller-payload\n"
    )
    output = stdout + stderr
    failures << "stdin: the probing shell itself failed: #{output.strip}" unless status.success?
    failures << "stdin: the static program was handed the caller's input: #{output.strip.inspect}" unless
      output.include?('probe read ""')
    failures << "stdin: the caller's input did not survive the contract: #{output.strip.inspect}" unless
      output.include?("left:caller-payload")
  end

  # The runtime invocation, which is `exec`ed and so is the last thing the script
  # does -- its redirect needs its own row because the static one cannot cover it.
  with_contract_copy(runtime: STDIN_PROBE, wrapper: wrapper_source) do |contract, copy_root|
    stdout, stderr, _status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => ROOT,
        "PLATFORM_MEDIA_ROOT" => copy_root, "PLATFORM_DOCKER_ROOT" => copy_root,
        "PLATFORM_REPORT_ROOT" => copy_root },
      "/bin/sh", "-c", "#{contract.shellescape} --platform nas run; printf 'left:'; cat",
      stdin_data: "caller-payload\n"
    )
    output = stdout + stderr
    failures << "stdin: the runtime program was handed the caller's input: #{output.strip.inspect}" unless
      output.include?('probe read ""')
  end
  failures
end

# --- planted regressions ---------------------------------------------------
#
# Each entry removes one guard from one program and names the rows that must
# catch it. A row that survives its own guard being deleted is proving nothing,
# and at this file's size that is the failure mode worth spending a self-test on.
#
# Deliberately absent: any mutation of the two sentinel literals in
# immich-runtime.rb. immich-static.rb reads that file's source and requires both
# to be live, so planting there would make the *static* rows refuse for a reason
# that has nothing to do with the guard under test.

PROGRAM_MUTATIONS = [
  {
    label: "the stack composition check",
    program: :static,
    from: "containers.keys.sort == EXPECTED_CONTAINERS.sort",
    to: "true",
    rows: ["a container missing from the stack"],
    # The composition sweep is also what keeps every read below it from meeting
    # an absent container, so removing it does not accept the repository: it
    # crashes on the first fetch. The row still refuses, and now says why in a
    # stack trace instead of a sentence, which is the regression.
    detects: "refused for the wrong reason"
  },
  {
    label: "the coupled version check",
    program: :static,
    from: "coupled_tags.compact.uniq.length == 1",
    to: "true",
    rows: ["the server and machine learning versions drifting apart"]
  },
  {
    label: "the restart policy check",
    program: :static,
    from: 'spec.fetch("restart") == "unless-stopped"',
    to: "true",
    rows: ["a restart policy that is not unless-stopped"]
  },
  {
    label: "the published-port containment check",
    program: :static,
    from: 'refuse("#{name} must not publish a host port") if containers.fetch(name).key?("ports")',
    to: "nil if false",
    rows: ["a database publishing a host port"]
  },
  {
    label: "the NAS render device check",
    program: :static,
    from: 'server.fetch("devices") == ["/dev/dri:/dev/dri"]',
    to: "true",
    rows: ["the NAS render device unmapped"]
  },
  {
    label: "the override presence check",
    program: :static,
    from: 'refuse("services/immich/compose.#{platform}.yml is absent") unless File.file?(override_path)',
    to: "nil unless true",
    rows: ["a declared file that is gone"],
    # The presence check is what the reads below it rely on, so removing it does
    # not accept the repository: the next line reads an absent file.
    detects: "refused for the wrong reason"
  },
  {
    label: "the explicit override tag check",
    program: :static,
    from: 'override_text.match?(/^\s+devices: !override(\s|$)/)',
    to: "true",
    rows: ["a device reset that lost its explicit override tag"]
  },
  {
    label: "the managed settings check",
    program: :static,
    from: 'settings.dig("newVersionCheck", "enabled") == false',
    to: "true",
    rows: ["the outbound version check re-enabled"]
  },
  {
    label: "the pinned preference profile check",
    program: :static,
    from: 'defaults.dig("immich_managed_user_preference_profiles", "standard") == expected_standard_preferences',
    to: "true",
    rows: ["the pinned standard preference profile edited"]
  },
  {
    # The assertion #147 repointed. Restoring the old path is the exact
    # regression the repoint exists to prevent: the file it names no longer
    # holds the sentinel, so it would refuse every repository forever.
    label: "the sentinel read pointed back at the wrapper",
    program: :static,
    from: 'File.join(root, "tests", "contracts", "immich-runtime.rb")',
    to: 'File.join(root, "tests", "contracts", "immich.sh")',
    rows: ["an intact repository"],
    detects: "expected success"
  },
  {
    label: "the onboarding lifecycle check",
    program: :static,
    from: 'required_onboarding_names.all? { |name| onboarding_names.include?(name) }',
    to: "true",
    rows: ["a required onboarding task renamed"],
    # Same shape: the completeness check is what the ordering check below it
    # relies on, so the run dies indexing a name that is not there.
    detects: "refused for the wrong reason"
  },
  {
    label: "the onboarding database-path check",
    program: :static,
    from: 'value.match?(/\bpsql\b|\buser_metadata\b|community\.postgresql|docker_compose_v2_exec/i)',
    to: "false",
    rows: ["an onboarding task that shells into the database"]
  },
  {
    label: "the managed preference admin-API check",
    program: :static,
    from: 'preference_read.dig("ansible.builtin.uri", "url").to_s.include?("/admin/users/")',
    to: "true",
    rows: ["a managed-user preference read that stops addressing a target"]
  },
  {
    label: "the avatar-free preference repair check",
    program: :static,
    from: 'preference_repair&.dig("ansible.builtin.uri", "body").to_s.match?(/avatar/i)',
    to: "false",
    rows: ["a managed-user preference repair that sends the avatar too"]
  },
  {
    label: "the wrong-password refusal",
    program: :runtime,
    from: 'request(
  "post", "/api/auth/login", expected: [401],',
    to: 'request(
  "post", "/api/auth/login", expected: [401, 201],',
    rows: ["an interface that accepts a wrong password"]
  },
  {
    label: "the administrator identity check",
    program: :runtime,
    from: 'session.fetch("userEmail") == email && session.fetch("isAdmin") == true',
    to: "true",
    # Only the non-administrator row, which the session check is the sole guard
    # for. The wrong-email row is guarded twice -- the authoritative admin record
    # is compared against the same address a few lines on -- so deleting this
    # check moves that refusal rather than removing it, and a row cannot pin two
    # different outcomes of one mutation.
    rows: ["a login answering a non-administrator"]
  },
  {
    label: "the administrator password-state check",
    program: :runtime,
    from: "administrator_session_password_state.equal?(false)",
    to: "true",
    rows: ["a login that still requires a password change"]
  },
  {
    label: "the safe identifier check",
    program: :runtime,
    from: 'value.is_a?(String) && value.match?(/\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/)',
    to: "true",
    rows: ["a login answering an unsafe identifier"],
    # Without the guard the unsafe value is interpolated straight into the next
    # request path, which the interface then answers 404. That the traversal
    # reaches the wire at all is exactly what the guard exists to stop.
    detects: "refused for the wrong reason"
  },
  {
    label: "the authoritative administrator schema check",
    program: :runtime,
    from: "[true, false].include?(administrator_record_admin) &&
  [true, false].include?(administrator_record_password_state)",
    to: "true",
    rows: ["an authoritative record with an unsupported schema"],
    # The identity comparison below rejects the same record, so the refusal
    # survives with a sentence that no longer names the schema.
    detects: "refused for the wrong reason"
  },
  {
    label: "the onboarding completion check",
    program: :runtime,
    from: 'onboarding == { "isOnboarded" => true }',
    to: "true",
    rows: ["an account whose onboarding never completed"]
  },
  {
    label: "the second-administrator refusal",
    program: :runtime,
    from: '"post", "/api/auth/admin-sign-up", expected: [400],',
    to: '"post", "/api/auth/admin-sign-up", expected: [400, 201],',
    rows: ["an interface that admits a second administrator"]
  },
  {
    label: "the application port containment check",
    program: :runtime,
    from: 'published.keys == ["2283/tcp"]',
    to: "true",
    rows: ["an application publishing more than its own port"]
  },
  {
    label: "the mapped render device check",
    program: :runtime,
    from: 'devices.any? { |device| device["PathInContainer"].to_s.start_with?("/dev/dri") }',
    to: "true",
    rows: ["a NAS deployment with no render device mapped"]
  },
  {
    label: "the helper containment check",
    program: :runtime,
    from: 'fail_contract("#{name} publishes host ports #{exposed.keys.inspect}") unless exposed.empty?',
    to: "nil unless true",
    rows: ["a helper container publishing a host port"]
  },
  {
    label: "the managed settings comparison",
    program: :runtime,
    from: "config.dig(*path) == value",
    to: "true",
    rows: ["a managed setting the deployment does not hold"]
  },
  {
    label: "the vault read status check",
    program: :runtime,
    from: 'fail_contract("encrypted vault could not be read") unless vault_status.success?',
    to: "nil unless true",
    rows: ["an unreadable encrypted vault"]
  },
  {
    label: "the protected fixture policy mode check",
    program: :runtime,
    from: "(stat.mode & 0o777) == 0o600",
    to: "true",
    rows: ["a world-readable protected fixture policy"]
  },
  {
    label: "the designated compact account check",
    program: :runtime,
    from: "selected == [designated]",
    to: "true",
    rows: ["a compact profile that selects an account other than the designated one"]
  },
  {
    label: "the unknown mode guard",
    program: :runtime,
    from: 'fail_contract("unknown mode: #{MODE}") unless %w[seed assert-persistence].include?(MODE)',
    to: "nil unless true",
    rows: ["a mode the program does not implement"],
    # Past the guard the program walks straight into the asset upload the
    # fixture does not serve, so it still refuses -- with the wrong sentence,
    # which is the regression.
    detects: "refused for the wrong reason"
  }
].freeze

def plant(source, mutation)
  from = mutation.fetch(:from)
  abort "self-test could not plant #{mutation.fetch(:label)}: #{from.inspect} is absent" unless
    source.include?(from)

  source.sub(from, mutation.fetch(:to))
end

def with_mutant(mutation)
  canonical = mutation.fetch(:program) == :static ? STATIC_PROGRAM : RUNTIME_PROGRAM
  Dir.mktmpdir("nas-platform-immich-mutant.") do |directory|
    path = File.join(directory, File.basename(canonical))
    File.write(path, plant(File.read(canonical), mutation))
    yield path
  end
end

def rows_named(rows, names)
  selected = rows.select { |row| names.include?(row.fetch(:name)) }
  abort "self-test names a row that does not exist: #{names.inspect}" unless
    selected.length == names.length

  selected
end

if ARGV.include?("--self-test")
  in_parallel_cases(PROGRAM_MUTATIONS) do |mutation|
    with_mutant(mutation) do |mutant|
      caught = if mutation.fetch(:program) == :static
                 static_failures(mutant, rows_named(STATIC_ROWS, mutation.fetch(:rows)))
               else
                 runtime_failures(mutant, rows_named(RUNTIME_ROWS, mutation.fetch(:rows)))
               end
      abort "self-test failed: removing #{mutation.fetch(:label)} was accepted" if caught.empty?
      detects = mutation.fetch(:detects, "accepted what it must refuse")
      unless caught.all? { |failure| failure.include?(detects) }
        abort "self-test failed: removing #{mutation.fetch(:label)} was caught by the wrong " \
              "assertion: #{caught.join(' | ')}"
      end
    end
    []
  end

  # The redirects' own regression, one per invocation. Neither real program reads
  # stdin, so dropping `</dev/null` changes no outcome today -- which is exactly
  # why it needs a program that does read, and why the rule cannot be proven by
  # the contract passing.
  planted_redirects = 0
  [
    ['ruby -ryaml "$contract_repo_dir/tests/contracts/immich-static.rb" \\
  "$repo_dir" "$platform" </dev/null',
     'ruby -ryaml "$contract_repo_dir/tests/contracts/immich-static.rb" \\
  "$repo_dir" "$platform"'],
    ['exec ruby "$contract_repo_dir/tests/contracts/immich-runtime.rb" "$mode" "$@" </dev/null',
     'exec ruby "$contract_repo_dir/tests/contracts/immich-runtime.rb" "$mode" "$@"']
  ].each do |from, to|
    unredirected = File.read(CONTRACT).sub(from, to)
    abort "self-test could not plant a dropped stdin redirect: #{from.inspect}" if
      unredirected == File.read(CONTRACT)

    leaked = stdin_failures(wrapper_source: unredirected)
    abort "self-test failed: a dropped stdin redirect was accepted" if leaked.empty?
    planted_redirects += 1
  end

  puts "immich contract: self-test detects #{PROGRAM_MUTATIONS.length + planted_redirects} " \
       "planted regressions"
  exit
end

failures = static_failures + runtime_failures + wrapper_failures + stdin_failures
unless failures.empty?
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} Immich contract violation(s)"
end

puts "immich contract: #{STATIC_ROWS.length} static and #{RUNTIME_ROWS.length} runtime " \
     "properties hold, and the wrapper reaches both programs with an empty stdin"
