#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Behaviour of the Beszel service contract's three Ruby programs.
#
# Until #147 all three lived in `<<'RUBY'` heredocs inside
# tests/contracts/beszel.sh. `sh -n` reads a quoted heredoc as opaque text, so
# the only thing that ever executed the static half was
# `tests/contracts/beszel.sh static`; the only thing that ever executed the
# 314-line runtime half was the beszel integration lane or the Mac proof, both
# of which need Docker, a converged PocketBase hub, a disposable ntfy and a real
# vault; and the fixture half was reachable only through
# tests/beszel_telemetry_probe_test.rb. A contract that passes says nothing
# about which of its assertions still bite. All three are files now, so each
# assertion can be moved on its own.
#
# Seven layers, because the contract has seven kinds of property:
#
#   Static -- build a fixture repository from the twenty files the static
#   program reads, break exactly one thing in it, and require the program to
#   name that thing. The assertion text is the interface: a guard that fails for
#   the wrong reason has stopped guarding what it names, so every row pins the
#   exact diagnostic.
#
#   Fixtures -- the telemetry-fixtures program, driven with recorded
#   system/system_stats/container_stats triples. Its own semantics already have
#   tests/beszel_telemetry_probe_test.rb; what is new here is the program's
#   argument contract and the fact that it needs no vault environment at all.
#
#   Runtime -- Beszel's own PocketBase API and a disposable ntfy served from two
#   HTTP fixtures, with `ansible-vault` stubbed on PATH, driving every mode the
#   program dispatches. None of this had any test at all before the cut.
#
#   Wrapper -- tests/contracts/beszel.sh is what turns a mode into an
#   invocation. Its rows prove the mode guard, the three-argument requirement of
#   telemetry-fixtures, and the three ${VAR:?} requirements the runtime half
#   depends on.
#
#   Self-read -- the static half reads the wrapper's own text for one sentinel.
#   Its subject did NOT move (it is the export pair, which stayed in the
#   wrapper), so the guard is not repointed -- but it is planted, because
#   "unchanged" and "still biting" are different claims.
#
#   Stdin -- three probes, one per invocation, because two of the three are
#   reached through `exec` and no single row can cover them.
#
#   Two roots, and runtime program root -- beszel has THREE sites where the
#   inspected tree is read, one of them past an `exec` and one of them a `-r`
#   preload path, which is a site class no earlier extraction in #147 has had.
#   The runtime_program_root layer exists because #310 found that pointing the
#   inspected tree at the contract copy makes both roots one directory *inside
#   the test built to catch that hazard*, which reported a rerooted-program
#   plant as ACCEPTED.
#
# Run with --self-test to plant a regression in each program and in the wrapper
# and prove the rows above detect it. It accumulates its mismatches rather than
# aborting on the first.

require "etc"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "shellwords"
require "time"
require "tmpdir"
require "uri"
require "yaml"

require_relative "http_fixture_support"
require_relative "policy_support"

include HttpFixtureSupport
include TestScaffold

ROOT = File.expand_path("..", __dir__)
# The prefix every refusal this file judges has to carry. Matching the
# fragment alone accepted a backtrace or an echoed argument as a refusal.
DIAGNOSTIC_PREFIX = "Beszel contract failed: "
CONTRACT = File.join(ROOT, "tests", "contracts", "beszel.sh")
STATIC_PROGRAM = File.join(ROOT, "tests", "contracts", "beszel-static.rb")
FIXTURES_PROGRAM = File.join(ROOT, "tests", "contracts", "beszel-telemetry-fixtures.rb")
RUNTIME_PROGRAM = File.join(ROOT, "tests", "contracts", "beszel-runtime.rb")

STATIC_SUCCESS = "Beszel static contract passed"

# Exactly what the static program reads. tests/contracts/beszel.sh is on the
# list and has to be: the static half reads its own wrapper's text
# UNCONDITIONALLY, unlike library/beszel_telemetry_probe.py and
# module_utils/beszel_telemetry.py, which sit behind File.file? ternaries. So
# komga's "an inspected tree with no tests/contracts at all" row is impossible
# here, and the two-roots layer states the beszel-shaped version instead: a tree
# that has the wrapper but none of the three programs.
#
# The role's stage files are all listed because roles/beszel/tasks/main.yml is
# an index of static imports and PolicySupport.static_role_tasks splices them in
# where they stand.
FIXTURE_FILES = %w[
  roles/beszel/defaults/main.yml
  roles/beszel/vars/main.yml
  roles/beszel/tasks/main.yml
  roles/beszel/tasks/deploy.yml
  roles/beszel/tasks/superuser.yml
  roles/beszel/tasks/application_user.yml
  roles/beszel/tasks/managed_users.yml
  roles/beszel/tasks/configure.yml
  roles/beszel/tasks/alert.yml
  roles/beszel/meta/argument_specs.yml
  services/beszel/compose.yml
  inventory/group_vars/nas_hosts/main.yml
  inventory/group_vars/mac_hosts/main.yml
  tests/mac/hooks/verify/10-beszel.sh
  tests/mac/hooks/drift/10-beszel.sh
  library/beszel_telemetry_probe.py
  module_utils/beszel_telemetry.py
  tests/policy_support.rb
  tests/contracts/support/beszel_telemetry.rb
  tests/contracts/beszel.sh
].freeze

# Never more workers than cores. tests/validate-policy.sh already runs its
# checks concurrently, so oversubscribing a four-core CI runner trades wall time
# for contention. Each case owns its own mktmpdir fixture and its own loopback
# ports, and shares nothing but the failure list; failures are concatenated in
# row order so the report is deterministic.
CASE_WORKER_LIMIT = Integer(
  ENV.fetch("BESZEL_CONTRACT_CASE_WORKERS") { [Etc.nprocessors, 8].min.to_s }
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

def build_fixture_repository(root, omit: [])
  FIXTURE_FILES.each do |relative|
    next if omit.include?(relative)

    destination = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(destination))
    FileUtils.cp(File.join(ROOT, relative), destination)
  end
  root
end

# Every substitution states how many matches it expects. A replacement that
# still contains its own pattern plants nothing, and a bare `sub` cannot tell
# that from a plant that worked: the row then reports a pass, or a failure with
# the wrong diagnostic. Three of the counts below are not 1 and were wrong on
# the first guess.
def mutate_text(root, relative, pattern, replacement, occurrences: 1)
  path = File.join(root, relative)
  body = File.read(path)
  found = body.scan(pattern).length
  raise "#{relative}: expected #{occurrences} match(es) of #{pattern.inspect}, " \
        "found #{found}" unless found == occurrences

  File.write(path, occurrences == 1 ? body.sub(pattern, replacement) : body.gsub(pattern, replacement))
end

def mutate_yaml(root, relative)
  path = File.join(root, relative)
  document = YAML.safe_load_file(path, aliases: true)
  yield document
  File.write(path, YAML.dump(document))
end

# ---------------------------------------------------------------------------
# Static layer
# ---------------------------------------------------------------------------

STATIC_ROWS = [
  { name: "an intact repository", break: ->(_root) {}, expects: nil },
  # The resolved-root sentinel is NOT a row here. It reads the wrapper's own
  # text, so it belongs to the self-read layer below, where the plant is made in
  # the wrapper and the judge is the static program -- the only arrangement that
  # can tell "the guard still bites" from "the wrapper still happens to satisfy
  # it".
  {
    name: "defaults that infer platform telemetry instead of requiring it",
    break: lambda { |root|
      mutate_text(root, "roles/beszel/defaults/main.yml",
                  "beszel_require_gpu_telemetry: false",
                  "beszel_require_gpu_telemetry: true")
    },
    expects: "defaults must not silently infer platform telemetry"
  },
  {
    name: "default categories that are no longer closed",
    break: lambda { |root|
      mutate_text(root, "roles/beszel/defaults/main.yml",
                  "beszel_required_telemetry_categories: []",
                  "beszel_required_telemetry_categories: [core]")
    },
    expects: "defaults must not silently infer platform telemetry"
  },
  {
    name: "a freshness window that is not three one-minute samples",
    break: lambda { |root|
      mutate_text(root, "roles/beszel/defaults/main.yml",
                  "beszel_telemetry_freshness_seconds: 180",
                  "beszel_telemetry_freshness_seconds: 240")
    },
    expects: "freshness must cover exactly three one-minute samples"
  },
  {
    name: "a drifted telemetry polling timeout",
    break: lambda { |root|
      mutate_text(root, "roles/beszel/defaults/main.yml",
                  "beszel_telemetry_poll_timeout_seconds: 90",
                  "beszel_telemetry_poll_timeout_seconds: 91")
    },
    expects: "telemetry polling timeout differs"
  },
  {
    # Scoped to the one variable rather than to the whole file, which is what
    # the program's own comment says it is doing: the inference is planted with
    # different spacing from the retired original, so a literal-expression
    # comparison would miss it.
    name: "effective categories inferred from the GPU input again",
    break: lambda { |root|
      mutate_text(root, "roles/beszel/vars/main.yml",
                  "beszel_effective_required_telemetry_categories: >-\n" \
                  "  {{ ['core', 'disk', 'containers']\n",
                  "beszel_effective_required_telemetry_categories: >-\n" \
                  "  {{ (['gpu'] if beszel_require_gpu_telemetry|bool else []) +\n" \
                  "     ['core', 'disk', 'containers']\n")
    },
    expects: "effective categories must use explicit inventory policy"
  },
  {
    name: "effective categories that are not derived at all",
    break: lambda { |root|
      mutate_text(root, "roles/beszel/vars/main.yml",
                  "beszel_effective_required_telemetry_categories: >-",
                  "beszel_effective_required_telemetry_category_set: >-")
    },
    expects: "effective categories must use explicit inventory policy"
  },
  {
    name: "derived retry arithmetic reintroduced beside the deadline",
    break: lambda { |root|
      path = File.join(root, "roles/beszel/vars/main.yml")
      File.write(path, "#{File.read(path)}beszel_telemetry_poll_retries: >-\n" \
                       "  {{ (beszel_telemetry_poll_timeout_seconds | int) // 3 }}\n")
    },
    expects: "telemetry polling must not use derived retry arithmetic"
  },
  {
    name: "retry arithmetic hidden inside another derived value",
    break: lambda { |root|
      path = File.join(root, "roles/beszel/vars/main.yml")
      File.write(path, "#{File.read(path)}beszel_poll_budget: >-\n" \
                       "  {{ beszel_telemetry_poll_retries | default(3) }}\n")
    },
    expects: "telemetry polling must not use derived retry arithmetic"
  }
].concat(
  # Every one of the five typed telemetry inputs, because the loop that checks
  # them names each by its own variable and a single row would leave four
  # unproven.
  {
    "beszel_required_telemetry_categories" => %w[list str],
    "beszel_require_gpu_telemetry" => %w[bool str],
    "beszel_telemetry_freshness_seconds" => %w[int str],
    "beszel_telemetry_poll_timeout_seconds" => %w[int str],
    "beszel_telemetry_request_timeout_seconds" => %w[int str]
  }.map do |name, (from, to)|
    {
      name: "#{name} declared as #{to} rather than #{from}",
      break: lambda { |root|
        mutate_text(root, "roles/beszel/meta/argument_specs.yml",
                    "      #{name}:\n        type: #{from}\n",
                    "      #{name}:\n        type: #{to}\n")
      },
      expects: "#{name} argument validation is absent"
    }
  end
).concat(
  # The five required task names, each planted by renaming the task rather than
  # deleting it: a name that survives only in a comment is exactly the case the
  # program's own comment says the parsed read exists to catch.
  {
    "Require the selected Beszel telemetry capability" => "roles/beszel/tasks/deploy.yml",
    "Poll persisted Beszel telemetry collections" => "roles/beszel/tasks/configure.yml",
    "Require exactly one managed Beszel system for telemetry" => "roles/beszel/tasks/configure.yml",
    "Resolve persisted Beszel telemetry evidence" => "roles/beszel/tasks/configure.yml",
    "Verify persisted Beszel telemetry categories" => "roles/beszel/tasks/configure.yml"
  }.map do |task, file|
    {
      name: "the #{task.downcase} task surviving only under another name",
      break: ->(root) { mutate_text(root, file, "name: #{task}", "name: #{task} (retired)") },
      expects: "missing #{task}"
    }
  end
).concat([
  {
    name: "a telemetry poll that no longer suppresses authenticated results",
    break: lambda { |root|
      mutate_text(root, "roles/beszel/tasks/configure.yml",
                  "      register: beszel_telemetry_probe_result\n" \
                  "      check_mode: false\n      no_log: true\n",
                  "      register: beszel_telemetry_probe_result\n" \
                  "      check_mode: false\n      no_log: false\n")
    },
    expects: "persisted telemetry poll must suppress authenticated results"
  },
  {
    name: "a telemetry poll that is not one deadline-aware probe",
    break: lambda { |root|
      mutate_yaml(root, "roles/beszel/tasks/configure.yml") do |document|
        task = find_task(document, "Poll persisted Beszel telemetry collections")
        task["ansible.builtin.uri"] = task.delete("beszel_telemetry_probe")
      end
    },
    expects: "persisted telemetry poll must use one deadline-aware probe"
  },
  {
    name: "a telemetry probe invoked without authentication",
    break: lambda { |root|
      mutate_yaml(root, "roles/beszel/tasks/configure.yml") do |document|
        find_task(document, "Poll persisted Beszel telemetry collections")
          .fetch("beszel_telemetry_probe").delete("auth_token")
      end
    },
    expects: "persisted telemetry probe is not authenticated"
  },
  {
    name: "a telemetry probe that no longer receives the total deadline",
    break: lambda { |root|
      mutate_yaml(root, "roles/beszel/tasks/configure.yml") do |document|
        find_task(document, "Poll persisted Beszel telemetry collections")
          .fetch("beszel_telemetry_probe").delete("delay_seconds")
      end
    },
    expects: "persisted telemetry probe does not receive the total deadline"
  },
  {
    name: "a probe implementation without its polling entry point",
    break: lambda { |root|
      mutate_text(root, "library/beszel_telemetry_probe.py",
                  "poll_telemetry", "poll_platform_telemetry", occurrences: 3)
    },
    expects: "deadline probe implementation is absent"
  },
  {
    name: "a probe support module that no longer fetches container stats",
    break: lambda { |root|
      mutate_text(root, "module_utils/beszel_telemetry.py",
                  'fetcher("container_stats"', 'fetcher("container_statistics"')
    },
    expects: "deadline probe implementation is absent"
  },
  {
    name: "a role that treats live health as persisted telemetry",
    break: lambda { |root|
      mutate_text(root, "roles/beszel/tasks/configure.yml",
                  "      register: beszel_telemetry_probe_result\n",
                  "      register: beszel_live_health_result\n")
    },
    expects: "role treats live health as persisted telemetry"
  },
  {
    # The other half of that guard: the probe still registers its result, but
    # nothing consumes the evidence. Naming the variable somewhere in the file
    # proved nothing about whether a later task read it.
    name: "probe evidence that no task consumes",
    break: lambda { |root|
      mutate_text(root, "roles/beszel/tasks/configure.yml",
                  "beszel_telemetry_probe_result.evidence.", "beszel_unread_evidence.",
                  occurrences: 4)
    },
    expects: "role treats live health as persisted telemetry"
  },
  {
    name: "a NAS Intel agent from some other publisher",
    break: lambda { |root|
      mutate_text(root, "services/beszel/compose.yml",
                  "ghcr.io/henrygd/beszel/beszel-agent-intel:",
                  "docker.io/henrygd/beszel-agent-intel:")
    },
    expects: "NAS Intel agent image differs"
  },
  {
    # A device that is present but not the platform's, rather than an absent
    # one. Deleting the key raises Errno-free but diagnostic-free: the program's
    # `intel.fetch("devices")` has no default, so an agent with no devices at
    # all arrives as a bare KeyError instead of the sentence. That is
    # pre-existing and stays unpinned -- there is no sentence to assert -- and
    # this row proves the comparison itself.
    name: "an Intel agent bound to some other render device",
    break: lambda { |root|
      mutate_yaml(root, "services/beszel/compose.yml") do |document|
        document.fetch("services").fetch("agent-intel")["devices"] =
          ["${NAS_RENDER_DEVICE:?}:/dev/dri/card0"]
      end
    },
    expects: "NAS Intel render device differs"
  },
  {
    name: "an inventory render device path the compose definition cannot use",
    break: lambda { |root|
      mutate_text(root, "inventory/group_vars/nas_hosts/main.yml",
                  "platform_render_device_path: /dev/dri/renderD128",
                  "platform_render_device_path: /dev/dri/renderD129")
    },
    expects: "NAS Intel render device differs"
  },
  {
    name: "a portable agent that lost a capacity mount",
    break: lambda { |root|
      mutate_yaml(root, "services/beszel/compose.yml") do |document|
        document.fetch("services").fetch("agent-portable").fetch("volumes")
                .reject! { |mount| mount.include?("/extra-filesystems/volume2") }
      end
    },
    expects: "agent capacity mounts differ"
  },
  {
    name: "an Intel agent that lost a capacity mount",
    break: lambda { |root|
      mutate_yaml(root, "services/beszel/compose.yml") do |document|
        document.fetch("services").fetch("agent-intel").fetch("volumes")
                .reject! { |mount| mount.include?("/extra-filesystems/volume1") }
      end
    },
    expects: "agent capacity mounts differ"
  },
  {
    name: "a socket proxy with a writable Docker socket",
    break: lambda { |root|
      mutate_text(root, "services/beszel/compose.yml",
                  "/var/run/docker.sock:/var/run/docker.sock:ro",
                  "/var/run/docker.sock:/var/run/docker.sock")
    },
    expects: "socket proxy is absent"
  },
  {
    name: "a Mac host declaring the Intel agent",
    break: lambda { |root|
      mutate_text(root, "inventory/group_vars/mac_hosts/main.yml",
                  "platform_beszel_agent_kind: portable",
                  "platform_beszel_agent_kind: intel")
    },
    expects: "Mac must use portable telemetry without a render device"
  },
  {
    name: "a Mac host that claims GPU telemetry",
    break: lambda { |root|
      mutate_text(root, "inventory/group_vars/mac_hosts/main.yml",
                  "beszel_require_gpu_telemetry: false",
                  "beszel_require_gpu_telemetry: true")
    },
    expects: "Mac must use portable telemetry without a render device"
  },
  {
    name: "a NAS host that stopped requiring GPU telemetry",
    break: lambda { |root|
      mutate_text(root, "inventory/group_vars/nas_hosts/main.yml",
                  "beszel_require_gpu_telemetry: true",
                  "beszel_require_gpu_telemetry: false")
    },
    expects: "NAS telemetry policy must explicitly require GPU"
  },
  {
    name: "a NAS category list that no longer names gpu",
    break: lambda { |root|
      mutate_text(root, "inventory/group_vars/nas_hosts/main.yml",
                  "  - containers\n  - gpu\n", "  - containers\n")
    },
    expects: "NAS telemetry policy must explicitly require GPU"
  },
  {
    name: "a Mac verify hook that skips the persisted telemetry proof",
    break: lambda { |root|
      mutate_text(root, "tests/mac/hooks/verify/10-beszel.sh",
                  '"$mac_hook_dir/../../run-beszel-contract.sh" verify',
                  '"$mac_hook_dir/../../run-beszel-contract.sh" notify')
    },
    expects: "Mac verification does not execute persisted telemetry proof"
  },
  {
    name: "a Mac drift hook that skips category rejection semantics",
    break: lambda { |root|
      mutate_text(root, "tests/mac/hooks/drift/10-beszel.sh",
                  'ruby "$mac_script_dir/../beszel_telemetry_probe_test.rb"', "true")
    },
    expects: "Mac drift hook does not execute category rejection semantics"
  }
]).freeze

def find_task(document, name)
  found = nil
  walk = lambda do |node|
    case node
    when Hash
      found ||= node if node["name"] == name
      node.each_value { |value| walk.call(value) }
    when Array then node.each { |value| walk.call(value) }
    end
  end
  walk.call(document)
  raise "the fixture has no task named #{name.inspect}" unless found

  found
end

def static_failures(program = STATIC_PROGRAM, rows = STATIC_ROWS)
  failures = []
  in_parallel_cases(failures, rows) do |row, collected|
    Dir.mktmpdir("nas-platform-beszel-static.") do |raw|
      root = File.realpath(raw)
      build_fixture_repository(root)
      row.fetch(:break).call(root)
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => root },
        RbConfig.ruby, "-ryaml", program, root, in: "/dev/null"
      )
      collected.concat(judge("static: #{row.fetch(:name)}", row.fetch(:expects), stdout, stderr, status,
                             prefix: DIAGNOSTIC_PREFIX))
    end
  end
  failures
end

# The existence sweep is not a sweep: the static program reads its twenty files
# with no [ -f ] preflight and no File.file? guard on eighteen of them, so a
# missing file arrives as an Errno::ENOENT or a LoadError rather than as a named
# diagnostic. That is pre-existing and stays unpinned -- there is no sentence to
# assert -- but which files are load-bearing at all is worth asserting, so this
# layer states only that removing each of them is noticed.
#
# The five that are NOT noticed are named rather than hidden: four role stage
# files whose absence static_role_tasks tolerates (superuser, application_user,
# managed_users, alert) and tests/contracts/support/beszel_telemetry.rb, which
# the static half never reads. Measured, not reasoned about.
UNREAD_BY_STATIC = %w[
  roles/beszel/tasks/superuser.yml
  roles/beszel/tasks/application_user.yml
  roles/beszel/tasks/managed_users.yml
  roles/beszel/tasks/alert.yml
  tests/contracts/support/beszel_telemetry.rb
].freeze

def missing_file_failures(program = STATIC_PROGRAM)
  failures = []
  in_parallel_cases(failures, FIXTURE_FILES) do |relative, collected|
    Dir.mktmpdir("nas-platform-beszel-missing.") do |raw|
      root = File.realpath(raw)
      build_fixture_repository(root, omit: [relative])
      _out, _err, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => root },
        RbConfig.ruby, "-ryaml", program, root, in: "/dev/null"
      )
      expected_success = UNREAD_BY_STATIC.include?(relative)
      if status.success? != expected_success
        collected << "missing-file: removing #{relative} " \
                     "#{status.success? ? 'was accepted' : 'was refused'}, " \
                     "wanted the opposite"
      end
    end
  end
  failures
end

# ---------------------------------------------------------------------------
# Fixtures layer (telemetry-fixtures)
# ---------------------------------------------------------------------------

NOW = Time.utc(2026, 8, 12, 12, 0, 0)

def telemetry_fixture
  {
    "now" => NOW.iso8601(3),
    "system" => { "id" => "system-safe-id", "status" => "up" },
    "system_stats" => {
      "id" => "system-stats-safe-id", "system" => "system-safe-id", "type" => "1m",
      "created" => (NOW - 60).iso8601(3),
      "stats" => { "cpu" => 0.0, "m" => 8.0, "mu" => 2.0, "mp" => 25.0,
                   "d" => 100.0, "du" => 40.0, "dp" => 40.0,
                   "g" => { "0" => { "n" => "Intel", "u" => 0.0 } } }
    },
    "container_stats" => {
      "id" => "container-stats-safe-id", "system" => "system-safe-id", "type" => "1m",
      "created" => (NOW - 60).iso8601(3),
      "stats" => [{ "n" => "beszel", "c" => 0.0, "m" => 0.1 }]
    }
  }
end

# The fixture program is its own diagnostic family: it aborts under "Beszel
# telemetry fixture failed: ", not under the contract's prefix, so its rows are
# judged against that rather than against DIAGNOSTIC_PREFIX.
FIXTURES_DIAGNOSTIC_PREFIX = "Beszel telemetry fixture failed: "

FIXTURES_ROWS = [
  { name: "a complete Mac triple", platform: "mac", mutate: ->(_data) {},
    expects: nil, wants: "Beszel telemetry fixture passed (mac)" },
  { name: "a complete NAS triple", platform: "nas", mutate: ->(_data) {},
    expects: nil, wants: "Beszel telemetry fixture passed (nas)" },
  { name: "a platform the contract does not support", platform: "linux",
    mutate: ->(_data) {}, expects: "unknown platform" },
  { name: "the empty platform", platform: "", mutate: ->(_data) {},
    expects: "unknown platform" },
  { name: "a NAS triple with no GPU sample", platform: "nas",
    mutate: ->(data) { data.fetch("system_stats").fetch("stats").delete("g") },
    expects: "categories=gpu" },
  { name: "a sample older than the freshness window", platform: "mac",
    mutate: ->(data) { data.fetch("system_stats")["created"] = (NOW - 181).iso8601(3) },
    expects: "categories=core,disk" },
  { name: "a sample belonging to another system", platform: "mac",
    mutate: ->(data) { data.fetch("system_stats")["system"] = "another-system" },
    expects: "record IDs=system_stats:system-stats-safe-id" },
  { name: "an empty container sample", platform: "mac",
    mutate: ->(data) { data.fetch("container_stats")["stats"] = [] },
    expects: "categories=containers" },
  {
    # The health-only row also proves the fixture half never echoes the payload:
    # the token planted here must not reach the diagnostic.
    name: "a healthy system with no persisted records at all", platform: "mac",
    mutate: lambda { |data|
      data.delete("system_stats")
      data.delete("container_stats")
      data["token"] = "beszel-contract-sensitive-token"
    },
    expects: "categories=core,disk,containers",
    refuses_to_leak: "beszel-contract-sensitive-token"
  },
  # The one refusal the fixture program does not author: a missing clock reaches
  # Hash#fetch and raises. It is asked for as a crash rather than as a
  # diagnostic, because a diagnostic prefix is exactly what it does not carry.
  { name: "a fixture with no recorded clock", platform: "mac",
    mutate: ->(data) { data.delete("now") },
    expects: nil, expects_crash: 'key not found: "now"' }
].freeze

def fixtures_failures(program = FIXTURES_PROGRAM, rows = FIXTURES_ROWS)
  failures = []
  in_parallel_cases(failures, rows) do |row, collected|
    label = "fixtures: #{row.fetch(:name)}"
    Dir.mktmpdir("nas-platform-beszel-fixtures.") do |raw|
      sandbox = File.realpath(raw)
      payload = telemetry_fixture
      row.fetch(:mutate).call(payload)
      path = File.join(sandbox, "fixture.json")
      File.write(path, JSON.generate(payload), mode: "w", perm: 0o600)
      # No vault environment, deliberately: tests/contracts/beszel.sh reaches
      # this program before its three ${VAR:?} requirements, and the whole of
      # tests/beszel_telemetry_probe_test.rb depends on that staying true.
      stdout, stderr, status = Open3.capture3(
        { "PATH" => ENV.fetch("PATH") },
        RbConfig.ruby, "-rjson",
        "-r#{File.join(ROOT, 'tests/contracts/support/beszel_telemetry')}",
        program, row.fetch(:platform), path, in: "/dev/null", unsetenv_others: true
      )
      collected.concat(judge(label, row.fetch(:expects), stdout, stderr, status,
                             prefix: FIXTURES_DIAGNOSTIC_PREFIX,
                             expects_crash: row[:expects_crash]))
      output = stdout + stderr
      if row[:wants] && !output.include?(row.fetch(:wants))
        collected << "#{label}: did not report #{row.fetch(:wants).inspect}, " \
                     "got #{output.strip.inspect}"
      end
      if row[:refuses_to_leak] && output.include?(row.fetch(:refuses_to_leak))
        collected << "#{label}: the diagnostic echoed the fixture payload"
      end
    end
  end
  failures
end

# ---------------------------------------------------------------------------
# Runtime layer
# ---------------------------------------------------------------------------
#
# Beszel's own PocketBase API and a disposable ntfy, modelled closely enough
# that every mode the runtime program dispatches reaches its own sentence. Two
# HTTP fixtures, nested, because the program talks to two services on two ports
# and the ntfy port is part of the webhook URL it compares against.

SUPER_EMAIL = "beszel-super@example.invalid"
SUPER_PASSWORD = "beszel-contract-superuser-password"
APP_EMAIL = "beszel-app@example.invalid"
APP_PASSWORD = "beszel-contract-app-password"
UNIVERSAL_TOKEN = "33333333-3333-4333-a333-333333333333"
NTFY_TOKEN = "beszel-contract-ntfy-token"
NTFY_ADMIN = %w[ntfy-admin ntfy-contract-admin-password].freeze
ADMIN_TOKEN = "beszel-contract-admin-token"
APP_TOKEN = "beszel-contract-app-session-token"
SYSTEM_NAME = "ASUSTOR-AS6704T"
DECOY_NAME = "00-contract-decoy"
WRONG_OWNER_EMAIL = "wrong-owner-fixture@example.invalid"
CALLBACK_HOST = "beszel-callback.example.invalid"
DRIFT_TOKEN = "11111111-1111-4111-a111-111111111111"
DRIFT_WEBHOOK =
  "https://sentinel-user:sentinel-password@example.invalid/hook?api_key=sentinel-query-key"
MANAGED_ALERTS = { "Status" => [0, 0], "CPU" => [90, 10],
                   "Memory" => [90, 10], "Disk" => [85, 10] }.freeze
DELIVERED_MESSAGE = "This is a notification from Beszel."

VAULT = {
  "vault_beszel_superuser_email" => SUPER_EMAIL,
  "vault_beszel_superuser_password" => SUPER_PASSWORD,
  "vault_beszel_app_user_email" => APP_EMAIL,
  "vault_beszel_app_user_password" => APP_PASSWORD,
  "vault_beszel_universal_token" => UNIVERSAL_TOKEN,
  "vault_ntfy_beszel_token" => NTFY_TOKEN,
  "vault_ntfy_admin_user" => NTFY_ADMIN.fetch(0),
  "vault_ntfy_admin_password" => NTFY_ADMIN.fetch(1)
}.freeze

def expected_webhook(state)
  "ntfy://:#{NTFY_TOKEN}@#{CALLBACK_HOST}:#{state.fetch(:ntfy_port)}/nas-critical?scheme=http"
end

def converged_state
  {
    users: [{ "id" => "app-user", "email" => APP_EMAIL, "verified" => true,
              "role" => "admin" }],
    systems: [{ "id" => "managed-system", "name" => SYSTEM_NAME, "users" => ["app-user"] }],
    universal_tokens: [{ "id" => "token-record", "user" => "app-user",
                         "token" => UNIVERSAL_TOKEN }],
    user_settings: [{ "id" => "settings-record", "user" => "app-user" }],
    alerts: MANAGED_ALERTS.map.with_index do |(name, (value, duration)), index|
      { "id" => "alert-#{index}", "user" => "app-user", "system" => "managed-system",
        "name" => name, "value" => value, "min" => duration }
    end,
    ntfy: [],
    ntfy_sequence: 0
  }
end

def telemetry_records(state, collection)
  return state.fetch(collection) if state.key?(collection)

  created = (Time.now.utc - 60).iso8601(3)
  case collection
  when :system_stats
    [{ "id" => "system-stats-record", "system" => "managed-system", "type" => "1m",
       "created" => created,
       "stats" => { "cpu" => 1.0, "m" => 8.0, "mu" => 2.0, "mp" => 25.0,
                    "d" => 100.0, "du" => 40.0, "dp" => 40.0,
                    "g" => { "0" => { "n" => "Intel", "u" => 3.0 } } } }]
  else
    [{ "id" => "container-stats-record", "system" => "managed-system", "type" => "1m",
       "created" => created,
       "stats" => [{ "n" => "hub", "c" => 0.5, "m" => 0.2 }] }]
  end
end

# The filter language PocketBase is handed here is exactly what the runtime
# program builds: `field = <json>` clauses joined with " && ". Evaluated rather
# than pattern-matched, so a row cannot pass by accident on a filter the program
# never sent.
def matches_filter?(record, filter)
  return true if filter.nil? || filter.empty?

  filter.split(" && ").all? do |clause|
    field, raw = clause.split(" = ", 2)
    return false if raw.nil?

    record[field.strip] == JSON.parse("[#{raw}]").fetch(0)
  end
end

def hub_responder(state)
  lambda do |method, target, headers, body|
    path, query = target.split("?", 2)
    params = query ? URI.decode_www_form(query).to_h : {}
    authorized = headers.fetch("authorization", "") == ADMIN_TOKEN ||
                 headers.fetch("authorization", "") == APP_TOKEN
    payload = body.to_s.empty? ? {} : (JSON.parse(body) rescue {})

    if method == "POST" && path == "/api/collections/_superusers/auth-with-password"
      next [400, JSON.generate("message" => "failed")] unless
        payload["identity"] == SUPER_EMAIL && payload["password"] == SUPER_PASSWORD

      next [200, JSON.generate("token" => ADMIN_TOKEN)]
    end
    if method == "POST" && path == "/api/collections/users/auth-with-password"
      next [400, JSON.generate("message" => "failed")] unless
        payload["identity"] == APP_EMAIL && payload["password"] == APP_PASSWORD

      next [200, JSON.generate("token" => APP_TOKEN)]
    end
    if method == "POST" && path == "/api/beszel/test-notification"
      next [401, JSON.generate("message" => "unauthorized")] unless authorized
      next [200, state.fetch(:notification_body)] if state.key?(:notification_body)

      state[:notification_url] = payload["url"]
      unless state.fetch(:notification_never_delivers, false)
        publish(state, "nas-critical", DELIVERED_MESSAGE)
      end
      next [200, JSON.generate("err" => state.fetch(:notification_err, false))]
    end

    next [401, JSON.generate("message" => "unauthorized")] unless authorized

    if method == "GET" && (collection = path[%r{\A/api/collections/([a-z_]+)/records\z}, 1])
      next [200, state.fetch(:malformed_records)] if state.key?(:malformed_records)
      next [state.fetch(:records_status), JSON.generate("items" => [])] if
        state.key?(:records_status)

      key = collection.to_sym
      if %i[system_stats container_stats].include?(key) && state.key?(:telemetry_status)
        next [state.fetch(:telemetry_status), JSON.generate("items" => [])]
      end

      records = %i[system_stats container_stats].include?(key) ?
        telemetry_records(state, key) : state.fetch(key, [])
      items = records.select { |record| matches_filter?(record, params["filter"]) }
      next [200, JSON.generate("items" => items,
                               "totalItems" => items.length,
                               "totalPages" => state.fetch(:total_pages, 1))]
    end
    if method == "POST" && (collection = path[%r{\A/api/collections/([a-z_]+)/records\z}, 1])
      key = collection.to_sym
      created = payload.merge("id" => "created-#{key}-#{state.fetch(key, []).length}")
      (state[key] ||= []) << created
      next [200, JSON.generate(created)]
    end
    if (match = path.match(%r{\A/api/collections/([a-z_]+)/records/([^/]+)\z}))
      key = match[1].to_sym
      records = state.fetch(key, [])
      entry = records.find { |record| record["id"] == match[2] }
      next [404, JSON.generate("message" => "no such record")] unless entry

      if method == "PATCH"
        entry.merge!(payload)
        next [200, JSON.generate(entry)]
      end
      if method == "DELETE"
        records.delete(entry)
        next [204, nil, nil]
      end
    end
    [500, JSON.generate("message" => "unexpected #{method} #{target}")]
  end
end

def publish(state, topic, message)
  state[:ntfy_sequence] = state.fetch(:ntfy_sequence) + 1
  state.fetch(:ntfy) << { "id" => "message-#{state.fetch(:ntfy_sequence)}",
                          "event" => "message", "topic" => topic, "message" => message }
end

def ntfy_responder(state)
  lambda do |method, target, headers, body|
    expected = "Basic #{[NTFY_ADMIN.join(':')].pack('m0')}"
    next [401, "unauthorized"] unless headers.fetch("authorization", "") == expected

    path, query = target.split("?", 2)
    params = query ? URI.decode_www_form(query).to_h : {}
    if method == "POST" && path == "/"
      payload = JSON.parse(body)
      publish(state, payload.fetch("topic"), payload.fetch("message"))
      next [200, JSON.generate("id" => "published")]
    end
    if method == "GET" && path == "/nas-critical/json"
      # The text helper's own status guard is only reachable through this read:
      # the publish above it goes through the JSON helper.
      next [state.fetch(:ntfy_read_status), "boom"] if state.key?(:ntfy_read_status)
      next [200, state.fetch(:ntfy_body)] if state.key?(:ntfy_body)

      messages = state.fetch(:ntfy).select { |entry| entry.fetch("topic") == "nas-critical" }
      since = params["since"]
      selected = if since == "latest"
                   messages.last(1)
                 elsif since
                   index = messages.index { |entry| entry.fetch("id") == since }
                   index ? messages[(index + 1)..] : messages
                 else
                   messages
                 end
      next [200, "#{selected.map { |entry| JSON.generate(entry) }.join("\n")}\n"]
    end
    [500, "unexpected #{method} #{target}"]
  end
end

def write_stub(directory, name, body)
  path = File.join(directory, name)
  File.write(path, body)
  File.chmod(0o755, path)
  path
end

def with_runtime_sandbox(state)
  Dir.mktmpdir("nas-platform-beszel-runtime.") do |raw|
    sandbox = File.realpath(raw)
    bin = File.join(sandbox, "bin")
    report = File.join(sandbox, "report")
    FileUtils.mkdir_p([bin, report])
    vault = File.join(sandbox, "vault.yml")
    File.write(vault, YAML.dump(state.fetch(:vault, VAULT)), mode: "w", perm: 0o600)
    File.write(File.join(sandbox, "password"), "unused-by-the-stub\n")
    write_stub(bin, "ansible-vault", if state.fetch(:vault_refuses, false)
                                       "#!/bin/sh\nprintf 'refused\\n' >&2\nexit 1\n"
                                     else
                                       "#!/bin/sh\nexec cat #{vault.shellescape}\n"
                                     end)
    yield(sandbox: sandbox, bin: bin, report: report, vault: vault,
          password: File.join(sandbox, "password"))
  end
end

def run_runtime(program, mode, state, paths, extra_env: {})
  environment = {
    "PATH" => "#{paths.fetch(:bin)}:#{ENV.fetch('PATH')}",
    "PLATFORM_CONTRACT_REPO_DIR" => state.fetch(:inspected_root, ROOT),
    "PLATFORM_CONTRACT_VAULT_FILE" => paths.fetch(:vault),
    "PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" => paths.fetch(:password),
    "PLATFORM_REPORT_ROOT" => paths.fetch(:report),
    "PLATFORM_BESZEL_PORT" => state.fetch(:hub_port).to_s,
    "PLATFORM_NTFY_PORT" => state.fetch(:ntfy_port).to_s,
    "PLATFORM_KIND" => state.fetch(:platform_kind, "nas"),
    "PLATFORM_CALLBACK_HOST" => CALLBACK_HOST
  }.merge(extra_env)
  Open3.capture3(environment, RbConfig.ruby, program, mode, in: "/dev/null")
end

RUNTIME_ROWS = [
  { name: "a converged platform in verify mode", mode: "verify", expects: nil },
  { name: "a vault that cannot be decrypted", mode: "verify",
    state: { vault_refuses: true }, expects: "encrypted vault could not be read" },
  { name: "a superuser identity the vault does not hold", mode: "verify",
    state: { vault: VAULT.merge("vault_beszel_superuser_password" => "wrong") },
    expects: "POST /api/collections/_superusers/auth-with-password returned HTTP 400" },
  { name: "an identity read that exceeds one complete page", mode: "verify",
    state: { total_pages: 2 },
    expects: "users filtered identity exceeds one complete page" },
  { name: "an identity read that is not JSON", mode: "verify",
    state: { malformed_records: "not json at all" },
    expects: "returned malformed JSON" },
  { name: "an identity read the hub refuses", mode: "verify",
    state: { records_status: 503 },
    expects: "returned HTTP 503" },
  { name: "no managed application user at all", mode: "verify",
    state: { users: [] }, expects: "managed application user is absent" },
  { name: "two application users with the managed identity", mode: "verify",
    state: { users: [{ "id" => "app-user", "email" => APP_EMAIL, "verified" => true,
                       "role" => "admin" },
                     { "id" => "app-user-2", "email" => APP_EMAIL, "verified" => true,
                       "role" => "admin" }] },
    expects: "duplicate managed application user IDs: app-user,app-user-2" },
  {
    # The top-level ownership refusal, which every mode except
    # remove-duplicate is subject to.
    name: "a same-name system outside the managed user relation", mode: "verify",
    state: { systems: [{ "id" => "managed-system", "name" => SYSTEM_NAME,
                         "users" => ["app-user"] },
                       { "id" => "squatter", "name" => SYSTEM_NAME,
                         "users" => ["someone-else"] }] },
    expects: "same-name wrong-owner system IDs: squatter"
  },
  { name: "an application user that is not a verified admin", mode: "verify",
    state: { users: [{ "id" => "app-user", "email" => APP_EMAIL, "verified" => true,
                       "role" => "user" }] },
    expects: "managed user is not verified admin" },
  { name: "an unverified application user", mode: "verify",
    state: { users: [{ "id" => "app-user", "email" => APP_EMAIL, "verified" => false,
                       "role" => "admin" }] },
    expects: "managed user is not verified admin" },
  { name: "a universal token that is not the vault's", mode: "verify",
    state: { universal_tokens: [{ "id" => "token-record", "user" => "app-user",
                                  "token" => "44444444-4444-4444-a444-444444444444" }] },
    expects: "managed universal token differs from encrypted vault" },
  { name: "no universal token for the managed user", mode: "verify",
    state: { universal_tokens: [] },
    expects: "managed universal token is absent" },
  { name: "a webhook pointing somewhere other than the managed ntfy topic",
    mode: "verify", state: { webhooks: ["ntfy://:token@elsewhere.invalid/nas-critical"] },
    expects: "managed ntfy webhook differs" },
  {
    # PocketBase returns a relation's JSON column as a string on some routes and
    # as an object on others. The program handles both; this row is the string
    # branch, and the default rows are the object branch.
    name: "settings served as a JSON string rather than an object", mode: "verify",
    settings_as_string: true, expects: nil
  },
  { name: "a drifted managed alert threshold", mode: "verify",
    alerts: lambda {
      converged_state.fetch(:alerts).map do |alert|
        alert.fetch("name") == "Disk" ? alert.merge("value" => 95) : alert
      end
    },
    expects: "managed Disk alert differs" },
  { name: "a managed alert that is absent", mode: "verify",
    alerts: -> { converged_state.fetch(:alerts).reject { |a| a.fetch("name") == "Memory" } },
    expects: "managed Memory alert is absent" },
  { name: "managed alerts attached to the decoy system", mode: "verify",
    state: { systems: [{ "id" => "managed-system", "name" => SYSTEM_NAME,
                         "users" => ["app-user"] },
                       { "id" => "decoy", "name" => DECOY_NAME, "users" => ["app-user"] }] },
    alerts: lambda {
      converged_state.fetch(:alerts) +
        [{ "id" => "decoy-alert", "user" => "app-user", "system" => "decoy",
           "name" => "CPU", "value" => 90, "min" => 10 }]
    },
    expects: "managed alerts were attached to the decoy system" },
  { name: "a telemetry read the hub will not authorize", mode: "verify",
    state: { telemetry_status: 403 },
    expects: "telemetry request was not authorized" },
  { name: "a telemetry read the hub answers with 404", mode: "verify",
    state: { telemetry_status: 404 },
    expects: "telemetry request returned HTTP 404" },
  {
    # The one deliberately slow row in this file, and the only place the
    # persisted-telemetry deadline itself is asserted from the runtime half.
    # timeout_seconds is 90 and delay_seconds is 3, both hardcoded in the
    # program, so an unready fixture costs ninety seconds of wall time. Making
    # it cheaper means changing the program's own numbers, which is the opposite
    # of what this file is for. The formatting of the same sentence is asserted
    # cheaply, thirty times over, in the fixtures layer above.
    name: "persisted telemetry that never becomes ready", mode: "verify",
    state: { system_stats: [] , slow: true },
    expects: "persisted telemetry unavailable or stale for system ID managed-system"
  },
  { name: "a converged Mac platform, whose policy requires no GPU sample",
    mode: "verify", state: { platform_kind: "mac" }, expects: nil },
  # --- drift -------------------------------------------------------------
  { name: "the drift fixture install", mode: "drift", expects: nil,
    after: lambda { |_paths, collected, state|
      user = state.fetch(:users).fetch(0)
      collected << "runtime: drift did not demote the managed user" unless
        user.fetch("role") == "user"
      collected << "runtime: drift did not clear the verified prerequisite" unless
        user.fetch("verified") == true
      collected << "runtime: drift did not replace the universal token" unless
        state.fetch(:universal_tokens).fetch(0).fetch("token") == DRIFT_TOKEN
      settings = state.fetch(:user_settings).fetch(0).fetch("settings")
      collected << "runtime: drift did not install the sentinel webhook" unless
        settings.is_a?(Hash) && settings.fetch("webhooks") == [DRIFT_WEBHOOK]
      cpu = state.fetch(:alerts).find { |alert| alert.fetch("name") == "CPU" }
      collected << "runtime: drift did not lower the CPU alert" unless
        cpu.fetch("value") == 1 && cpu.fetch("min") == 1
      collected << "runtime: drift did not create the decoy system" unless
        state.fetch(:systems).any? { |system| system.fetch("name") == DECOY_NAME }
    } },
  { name: "a repeated drift install over its own decoy", mode: "drift",
    state: { systems: [{ "id" => "managed-system", "name" => SYSTEM_NAME,
                         "users" => ["app-user"] },
                       { "id" => "decoy", "name" => DECOY_NAME, "users" => ["app-user"] }] },
    expects: nil,
    after: lambda { |_paths, collected, state|
      decoys = state.fetch(:systems).count { |system| system.fetch("name") == DECOY_NAME }
      collected << "runtime: drift created a second decoy system" unless decoys == 1
    } },
  { name: "drift against a platform with no managed system", mode: "drift",
    state: { systems: [] }, expects: "managed system is absent" },
  { name: "drift against a platform with two managed settings records", mode: "drift",
    state: { user_settings: [{ "id" => "settings-a", "user" => "app-user" },
                             { "id" => "settings-b", "user" => "app-user" }] },
    expects: "duplicate managed user settings IDs: settings-a,settings-b" },
  # --- drift-verify ------------------------------------------------------
  { name: "drift verified against an installed drift", mode: "drift-verify",
    drift_first: true, expects: nil },
  { name: "drift verified against a converged platform", mode: "drift-verify",
    expects: "managed application user drift changed" },
  { name: "a drift whose universal token was repaired", mode: "drift-verify",
    drift_first: true,
    mutate_after_drift: lambda { |state|
      state.fetch(:universal_tokens).fetch(0)["token"] = UNIVERSAL_TOKEN
    },
    expects: "managed universal token drift changed" },
  { name: "a drift whose webhook was repaired", mode: "drift-verify",
    drift_first: true,
    mutate_after_drift: lambda { |state|
      state.fetch(:user_settings).fetch(0)["settings"] = { "webhooks" => [] }
    },
    expects: "managed webhook drift changed" },
  { name: "a drift whose CPU alert was repaired", mode: "drift-verify",
    drift_first: true,
    mutate_after_drift: lambda { |state|
      state.fetch(:alerts).find { |a| a.fetch("name") == "CPU" }.merge!("value" => 90,
                                                                        "min" => 10)
    },
    expects: "managed CPU alert drift changed" },
  { name: "a drift whose decoy system was removed", mode: "drift-verify",
    drift_first: true,
    mutate_after_drift: lambda { |state|
      state.fetch(:systems).reject! { |system| system.fetch("name") == DECOY_NAME }
    },
    expects: "decoy system drift changed" },
  # --- duplicate / wrong-owner / remove-duplicate ------------------------
  { name: "the duplicate-system fixture install", mode: "duplicate", expects: nil,
    after: lambda { |paths, collected, state|
      artifact = File.join(paths.fetch(:report), "beszel-duplicate-ids.txt")
      unless File.file?(artifact)
        collected << "runtime: duplicate wrote no evidence artifact"
        next
      end
      expected_mode = 0o600 & ~File.umask
      actual = File.stat(artifact).mode & 0o777
      collected << "runtime: duplicate wrote the evidence artifact " \
                   "#{format('%<m>04o', m: actual)}, wanted " \
                   "#{format('%<m>04o', m: expected_mode)}" unless actual == expected_mode
      ids = File.readlines(artifact, chomp: true)
      collected << "runtime: the evidence artifact does not keep the managed ID first" unless
        ids.first == "managed-system" && ids.length == 2
      collected << "runtime: duplicate did not create a same-name system" unless
        state.fetch(:systems).count { |s| s.fetch("name") == SYSTEM_NAME } == 2
    } },
  { name: "the wrong-owner fixture install", mode: "wrong-owner", expects: nil,
    after: lambda { |paths, collected, state|
      artifact = File.join(paths.fetch(:report), "beszel-duplicate-ids.txt")
      collected << "runtime: wrong-owner wrote no evidence artifact" unless File.file?(artifact)
      collected << "runtime: wrong-owner created no fixture user" unless
        state.fetch(:users).any? { |user| user.fetch("email") == WRONG_OWNER_EMAIL }
      squatters = state.fetch(:systems).reject do |system|
        Array(system["users"]).include?("app-user")
      end
      collected << "runtime: wrong-owner created no unowned same-name system" if squatters.empty?
    } },
  { name: "a wrong-owner install repeated over its own fixture user",
    mode: "wrong-owner",
    state: { users: [{ "id" => "app-user", "email" => APP_EMAIL, "verified" => true,
                       "role" => "admin" },
                     { "id" => "wrong-owner", "email" => WRONG_OWNER_EMAIL,
                       "verified" => true, "role" => "user" }] },
    expects: nil,
    after: lambda { |_paths, collected, state|
      count = state.fetch(:users).count { |user| user.fetch("email") == WRONG_OWNER_EMAIL }
      collected << "runtime: wrong-owner created a second fixture user" unless count == 1
    } },
  {
    # remove-duplicate is the one mode exempt from the top-level wrong-owner
    # refusal, which is what lets it clean up after the wrong-owner mode.
    name: "the removal of a wrong-owner fixture", mode: "remove-duplicate",
    wrong_owner_first: true, expects: nil,
    after: lambda { |paths, collected, state|
      collected << "runtime: removal left the evidence artifact behind" if
        File.exist?(File.join(paths.fetch(:report), "beszel-duplicate-ids.txt"))
      collected << "runtime: removal left more than the managed system" unless
        state.fetch(:systems).map { |s| s.fetch("id") } == ["managed-system"]
      collected << "runtime: removal left the wrong-owner fixture user" if
        state.fetch(:users).any? { |user| user.fetch("email") == WRONG_OWNER_EMAIL }
    } },
  { name: "a removal with no evidence artifact to act on", mode: "remove-duplicate",
    expects: nil,
    after: lambda { |_paths, collected, state|
      collected << "runtime: a removal with no evidence deleted a system" unless
        state.fetch(:systems).length == 1
    } },
  # --- notify ------------------------------------------------------------
  { name: "the notification proof against a delivering hub", mode: "notify",
    expects: nil,
    after: lambda { |_paths, collected, state|
      collected << "runtime: notify did not send the vault-derived webhook URL" unless
        state[:notification_url] == expected_webhook(state)
    } },
  { name: "an application identity the vault does not hold", mode: "notify",
    state: { vault: VAULT.merge("vault_beszel_app_user_password" => "wrong") },
    expects: "POST /api/collections/users/auth-with-password returned HTTP 400" },
  { name: "a disposable ntfy that keeps no message history", mode: "notify",
    state: { ntfy_body: "\n" },
    expects: "disposable ntfy has no baseline message for anti-replay polling" },
  { name: "a disposable ntfy whose history read fails", mode: "notify",
    state: { ntfy_read_status: 500 },
    expects: "GET /nas-critical/json returned HTTP 500" },
  { name: "a hub that reports the notification failed", mode: "notify",
    state: { notification_err: true },
    expects: "Beszel test notification reported delivery failure" },
  { name: "a hub whose notification answer is not JSON", mode: "notify",
    state: { notification_body: "not json at all" },
    expects: "returned malformed JSON" },
  {
    # The anti-replay poll itself: the hub reports success but nothing arrives.
    # Fifteen seconds, which is the program's own deadline.
    name: "a notification that never reaches the disposable ntfy", mode: "notify",
    state: { notification_never_delivers: true, slow: true },
    expects: "Beszel test notification did not reach disposable ntfy"
  }
].freeze

def prepare_state(row)
  state = converged_state
  state.merge!(row.fetch(:state, {}))
  state[:alerts] = row.fetch(:alerts).call if row[:alerts]
  state[:row] = row
  state
end

# Fills in everything that cannot be known until the two loopback ports are
# bound: the managed webhook URL, and the telemetry status override the
# responder reads.
def finalize_state(state)
  row = state.fetch(:row)
  webhooks = state.fetch(:webhooks, nil) || [expected_webhook(state)]
  settings = { "webhooks" => webhooks }
  state.fetch(:user_settings).each do |record|
    record["settings"] = row.fetch(:settings_as_string, false) ? JSON.generate(settings) : settings
  end
  state
end

def runtime_failures(program = RUNTIME_PROGRAM, rows = RUNTIME_ROWS)
  failures = []
  in_parallel_cases(failures, rows) do |row, collected|
    label = "runtime: #{row.fetch(:name)}"
    state = prepare_state(row)
    with_runtime_sandbox(state) do |paths|
      with_http_fixture(lambda { |hub_port|
        state[:hub_port] = hub_port
        with_http_fixture(lambda { |ntfy_port|
          state[:ntfy_port] = ntfy_port
          finalize_state(state)
          if row.fetch(:drift_first, false)
            _out, err, drifted = run_runtime(program, "drift", state, paths)
            collected << "#{label}: the drift this row builds on failed: #{err.strip}" unless
              drifted.success?
            row[:mutate_after_drift]&.call(state)
          end
          if row.fetch(:wrong_owner_first, false)
            _out, err, seeded = run_runtime(program, "wrong-owner", state, paths)
            collected << "#{label}: the wrong-owner install this row builds on failed: " \
                         "#{err.strip}" unless seeded.success?
          end
          stdout, stderr, status = run_runtime(program, row.fetch(:mode), state, paths)
          collected.concat(judge(label, row.fetch(:expects), stdout, stderr, status,
                                 prefix: DIAGNOSTIC_PREFIX))
          # Every credential this fixture holds, checked against every byte the
          # program printed. Beszel's data directory is secret-bearing and the
          # program decrypts a vault in memory; a diagnostic that echoed one
          # would be a leak, and the program's own scrub of the decrypted YAML
          # is what keeps that from happening.
          output = stdout + stderr
          [SUPER_PASSWORD, APP_PASSWORD, UNIVERSAL_TOKEN, NTFY_TOKEN,
           NTFY_ADMIN.fetch(1)].each do |secret|
            collected << "#{label}: the diagnostic echoed a credential" if output.include?(secret)
          end
          after = row[:after]
          after&.call(paths, collected, state)
        }, &ntfy_responder(state))
      }, &hub_responder(state))
    end
  end
  failures
end

# ---------------------------------------------------------------------------
# Wrapper layer
# ---------------------------------------------------------------------------
#
# tests/contracts/beszel.sh resolves all three programs from its own checkout
# rather than from the tree it inspects, so a copy of the four files into a
# throwaway tests/contracts/ is a whole working contract.

def with_contract_copy(static: File.read(STATIC_PROGRAM),
                       fixtures: File.read(FIXTURES_PROGRAM),
                       runtime: File.read(RUNTIME_PROGRAM),
                       wrapper: File.read(CONTRACT))
  Dir.mktmpdir("nas-platform-beszel-wrapper.") do |raw|
    root = File.realpath(raw)
    build_fixture_repository(root)
    contracts = File.join(root, "tests", "contracts")
    FileUtils.mkdir_p(contracts)
    path = File.join(contracts, "beszel.sh")
    File.write(path, wrapper)
    File.chmod(0o755, path)
    File.write(File.join(contracts, "beszel-static.rb"), static)
    File.write(File.join(contracts, "beszel-telemetry-fixtures.rb"), fixtures)
    File.write(File.join(contracts, "beszel-runtime.rb"), runtime)
    yield path, root
  end
end

def wrapper_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  with_contract_copy(wrapper: wrapper_source) do |contract, copy_root|
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => copy_root }, contract, "static"
    )
    failures << "wrapper: static mode failed against its own fixture: " \
                "#{(stdout + stderr).strip}" unless status.success?
    failures << "wrapper: static mode did not report the property it proved" unless
      stdout.include?(STATIC_SUCCESS)

    # The tree under inspection is broken, the wrapper's own checkout is not:
    # the row that proves the wrapper still runs the static program at all.
    Dir.mktmpdir("nas-platform-beszel-broken.") do |raw|
      broken = File.realpath(raw)
      build_fixture_repository(broken)
      FileUtils.rm(File.join(broken, "roles/beszel/meta/argument_specs.yml"))
      _out, _err, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => broken }, contract, "static"
      )
      failures << "wrapper: static mode passed against a broken repository" if status.success?
    end

    # Every mode the guard rejects, and every mode it accepts. `verify` is the
    # default, so a bare invocation is a run-mode invocation and must reach the
    # runtime half's environment requirements rather than the static success
    # line.
    #
    # The two halves are told apart by EFFECT, not by exit code, and that is a
    # correction rather than a preference. The mode guard's `exit 2` belongs to
    # the script, but a ${VAR:?} refusal's status belongs to the shell: bash
    # exits 1 and **dash exits 2**. An exit-code test therefore reports all
    # seven dispatched modes as guard-rejected the moment beszel.sh runs under
    # /bin/dash -- which is exactly what happened the first time this file was
    # run that way, seven rows red against a wrapper that was fine. The guard is
    # recognised by its silence instead, and reaching the runtime half by the
    # variable name in the shell's own refusal, whose wording is never asserted.
    %w[bogus --help static-x telemetry_fixtures].each do |mode|
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => copy_root }, contract, mode
      )
      output = stdout + stderr
      failures << "wrapper: the mode guard accepted #{mode.inspect}" if status.success?
      failures << "wrapper: #{mode.inspect} produced a diagnostic, so it reached past the " \
                  "mode guard: #{output.strip.inspect}" unless output.strip.empty?
    end
    %w[verify drift drift-verify duplicate wrong-owner remove-duplicate notify].each do |mode|
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => copy_root }, contract, mode
      )
      output = stdout + stderr
      failures << "wrapper: #{mode.inspect} was accepted with no runtime environment" if
        status.success?
      failures << "wrapper: the mode guard refused #{mode.inspect}, which it dispatches: " \
                  "#{output.strip.inspect}" unless
        output.include?("PLATFORM_CONTRACT_VAULT_FILE: parameter")
    end

    # telemetry-fixtures takes exactly two arguments after the mode. Its guard
    # is `[ "$#" -eq 3 ] || exit 2`, and that 2 is the SCRIPT's own status, not
    # a shell's, so it is safe to assert -- unlike the ${VAR:?} statuses above.
    # Silence is asserted alongside it, because a nonzero exit that printed
    # something reached the program.
    [[], %w[mac], %w[mac a b]].each do |extra|
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => copy_root },
        contract, "telemetry-fixtures", *extra
      )
      failures << "wrapper: telemetry-fixtures accepted #{extra.length} argument(s)" unless
        status.exitstatus == 2
      failures << "wrapper: telemetry-fixtures with #{extra.length} argument(s) reached the " \
                  "program: #{(stdout + stderr).strip.inspect}" unless
        (stdout + stderr).strip.empty?
    end

    # The three run-mode environment names. The wording of a ${VAR:?} refusal
    # belongs to the shell -- bash says "parameter null or not set", dash says
    # "parameter not set or null" -- so only the portable prefix is asserted.
    complete = {
      "PLATFORM_CONTRACT_VAULT_FILE" => File.join(copy_root, "vault.yml"),
      "PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" => File.join(copy_root, "password"),
      "PLATFORM_REPORT_ROOT" => copy_root
    }
    complete.each_key do |name|
      [nil, ""].each do |value|
        stdout, stderr, status = Open3.capture3(
          { "PLATFORM_CONTRACT_REPO_DIR" => copy_root }.merge(complete).merge(name => value),
          contract, "verify"
        )
        output = stdout + stderr
        failures << "wrapper: verify was accepted with #{name} #{value.inspect}" if
          status.success?
        failures << "wrapper: #{name} #{value.inspect} did not name the unset variable: " \
                    "#{output.strip.inspect}" unless output.include?("#{name}: parameter")
        failures << "wrapper: #{name} #{value.inspect} printed the static success line" if
          stdout.include?(STATIC_SUCCESS)
      end
    end

    # Static mode must not reach the runtime environment contract at all: it
    # exits 0 before line 46, which is why the Mac verify hook can run it with
    # no vault.
    stdout, _err, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => copy_root,
        "PLATFORM_CONTRACT_VAULT_FILE" => nil, "PLATFORM_REPORT_ROOT" => nil },
      contract, "static"
    )
    failures << "wrapper: static mode required the runtime environment" unless
      status.success? && stdout.include?(STATIC_SUCCESS)

    # telemetry-fixtures end to end THROUGH the wrapper, and the only place the
    # fixtures invocation's own shape is exercised: both -r preloads, "$2" "$3"
    # rather than "$@", and the `exec` sitting ahead of the three ${VAR:?}
    # guards. The fixtures layer above builds its own invocation, so it is blind
    # to a wrapper that dropped a preload -- which is how a load-bearing
    # -ryaml sat unplanted until the wrapper was measured rather than read.
    # Every vault name is explicitly unset here: reaching this mode with none of
    # them is the property tests/beszel_telemetry_probe_test.rb's sixty-odd
    # cases rest on.
    fixture_path = File.join(copy_root, "beszel-contract-fixture.json")
    File.write(fixture_path, JSON.generate(telemetry_fixture), mode: "w", perm: 0o600)
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => copy_root,
        "PLATFORM_CONTRACT_VAULT_FILE" => nil,
        "PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" => nil,
        "PLATFORM_REPORT_ROOT" => nil },
      contract, "telemetry-fixtures", "mac", fixture_path
    )
    failures << "wrapper: telemetry-fixtures failed with no vault environment: " \
                "#{(stdout + stderr).strip}" unless status.success?
    failures << "wrapper: telemetry-fixtures did not report the property it proved" unless
      stdout.include?("Beszel telemetry fixture passed (mac)")
  end

  # The branch every deployment actually takes. Neither tests/integration.sh nor
  # run_contracts.rb --execute sets PLATFORM_CONTRACT_REPO_DIR, so the default
  # is the only path in production -- and it is the one where resolving all
  # three programs from the script's own checkout is load-bearing rather than
  # shadowed.
  with_contract_copy(wrapper: wrapper_source) do |contract, copy_root|
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => nil }, contract, "static"
    )
    failures << "wrapper: static mode failed with no repository named: " \
                "#{(stdout + stderr).strip}" unless status.success?
    failures << "wrapper: static mode did not report the property it proved" unless
      stdout.include?(STATIC_SUCCESS)

    FileUtils.rm(File.join(copy_root, "roles/beszel/meta/argument_specs.yml"))
    _out, _err, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => nil }, contract, "static"
    )
    failures << "wrapper: with no repository named, static mode inspected some other tree" if
      status.success?
  end
  failures
end

# --- the one self-read guard -----------------------------------------------
#
# beszel's static half reads tests/contracts/beszel.sh for one sentinel: the
# resolved-root export. Unlike komga's three and jellyfin's, its subject did NOT
# move -- the export pair stayed in the wrapper, so the guard needed no repoint.
# It still gets a plant, because "not repointed" and "still biting" are
# different claims, and because the literal occurs TWICE (the second export pair
# is redundant and transcribed verbatim), which is exactly the shape an unscoped
# substitution mis-plants.
SELF_READ_ROWS = [
  {
    name: "a wrapper that stopped exporting its resolved repository root",
    from: "PLATFORM_CONTRACT_REPO_DIR=$repo_dir\nexport PLATFORM_CONTRACT_REPO_DIR\n",
    to: "",
    occurrences: 2,
    expects: "runtime contract does not export its resolved repository root"
  },
  {
    # The half a whole-pair deletion cannot reach: one pair survives, so the
    # variable is still exported and the program still runs -- but the adjacent
    # literal the sentinel matches is broken. This is the row that says the
    # guard matches an assignment IMMEDIATELY followed by its export rather than
    # the two tokens anywhere in the file.
    name: "an export separated from the assignment it exports",
    from: "PLATFORM_CONTRACT_REPO_DIR=$repo_dir\nexport PLATFORM_CONTRACT_REPO_DIR\n" \
          "PLATFORM_CONTRACT_REPO_DIR=$repo_dir\nexport PLATFORM_CONTRACT_REPO_DIR\n",
    to: "PLATFORM_CONTRACT_REPO_DIR=$repo_dir\n: interposed\n" \
        "export PLATFORM_CONTRACT_REPO_DIR\n",
    occurrences: 1,
    expects: "runtime contract does not export its resolved repository root"
  }
].freeze

def self_read_failures(wrapper_source: File.read(CONTRACT),
                       static_source: File.read(STATIC_PROGRAM))
  failures = []
  # A floor rather than non-emptiness. The summary line derives its count from
  # this list, so a list that shrank to nothing would report "all 0 self-read
  # guards bite" and pass.
  failures << "self-read: the guard set has shrunk to #{SELF_READ_ROWS.length} row(s); " \
              "a guard was deleted without its property moving somewhere that can fail" if
    SELF_READ_ROWS.length < 2
  in_parallel_cases(failures, SELF_READ_ROWS) do |row, collected|
    occurrences = row.fetch(:occurrences)
    found = wrapper_source.scan(row.fetch(:from)).length
    if found != occurrences
      collected << "self-read: #{row.fetch(:name)}: expected #{occurrences} match(es) of " \
                   "#{row.fetch(:from).inspect} in the wrapper, found #{found}"
      next
    end
    planted = occurrences == 1 ? wrapper_source.sub(row.fetch(:from), row.fetch(:to))
                               : wrapper_source.gsub(row.fetch(:from), row.fetch(:to))
    with_contract_copy(wrapper: planted, static: static_source) do |contract, copy_root|
      # PLATFORM_CONTRACT_REPO_DIR is set in the environment here, so the
      # program still resolves the inspected tree even when the wrapper no
      # longer exports it: the row measures the sentinel, not the export's
      # side effect.
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
# Reports what the program saw on stdin and what the caller still has, which is
# the only way the redirect is observable: no program reads stdin, so the
# redirect is what keeps that true rather than something that changes an outcome
# today. Three probes, because two of the three invocations are reached through
# `exec` and no single row can cover them.

STDIN_PROBE = <<~'PROBE'
  warn "probe read #{$stdin.read.inspect}"
  exit 1
PROBE

# The static probe must satisfy the wrapper's one self-read grep, or the
# substituted program never runs -- except that the grep lives in the program
# itself here, so a probe that replaces the program removes the grep with it.
# Stated rather than assumed: this probe needs nothing.
def stdin_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  [[:static, %w[static], { static: STDIN_PROBE }],
   [:fixtures, %w[telemetry-fixtures mac /nonexistent.json],
    { fixtures: STDIN_PROBE }],
   [:runtime, %w[verify], { runtime: STDIN_PROBE }]].each do |layer, argv, replacement|
    with_contract_copy(wrapper: wrapper_source, **replacement) do |contract, copy_root|
      command = "#{contract.shellescape} #{argv.map(&:shellescape).join(' ')}; " \
                "printf 'left:'; cat"
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => copy_root,
          "PLATFORM_CONTRACT_VAULT_FILE" => File.join(copy_root, "vault.yml"),
          "PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" => File.join(copy_root, "password"),
          "PLATFORM_REPORT_ROOT" => copy_root },
        "/bin/sh", "-c", command, stdin_data: "caller-payload\n"
      )
      output = stdout + stderr
      failures << "stdin (#{layer}): the probing shell itself failed: #{output.strip}" unless
        status.success?
      failures << "stdin (#{layer}): the program was handed the caller's input: " \
                  "#{output.strip.inspect}" unless output.include?('probe read ""')
      failures << "stdin (#{layer}): the caller's input did not survive the contract: " \
                  "#{output.strip.inspect}" unless output.include?("left:caller-payload")
    end
  end
  failures
end

# --- two roots -------------------------------------------------------------
#
# Stated as outcomes rather than as the wrapper's text. Beszel has three sites
# where the INSPECTED tree is read and one where the checkout must be:
#
#   1. all three program paths       -> the checkout
#   2. beszel-static.rb's require of tests/policy_support.rb -> inspected tree
#   3. the telemetry-fixtures -r preload path                -> inspected tree
#   4. beszel-runtime.rb's require, past the exec             -> inspected tree
#
# Site 3 is a class no earlier extraction in #147 has had, and site 4 is the one
# #310 found on kapowarr. Both rows are promoted from the before/after capture,
# where they sit among the byte-identical scenarios and are therefore invisible
# in a diff.

def two_roots_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  with_contract_copy(wrapper: wrapper_source) do |contract|
    # Site 1, in the shape beszel can state it. komga's version -- an inspected
    # tree with no tests/contracts at all -- is impossible here, because the
    # static half reads its own wrapper's text unconditionally. So the tree keeps
    # the wrapper and loses the three programs.
    Dir.mktmpdir("nas-platform-beszel-tworoots.") do |raw|
      inspected = File.realpath(raw)
      build_fixture_repository(inspected)
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => inspected }, contract, "static"
      )
      failures << "two roots: an inspected tree with no sibling programs was refused, so a " \
                  "program is being resolved from it: #{(stdout + stderr).strip}" unless
        status.success?
      failures << "two roots: the contract did not report the property it proved" unless
        stdout.include?(STATIC_SUCCESS)
    end

    # Site 2.
    Dir.mktmpdir("nas-platform-beszel-support.") do |raw|
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

    # Site 3: the -r preload path. The only site of its kind in #147 so far.
    Dir.mktmpdir("nas-platform-beszel-preload.") do |raw|
      inspected = File.realpath(raw)
      build_fixture_repository(inspected)
      File.write(File.join(inspected, "tests/contracts/support/beszel_telemetry.rb"),
                 %(raise "inspected tree telemetry preload reached"\n))
      fixture = File.join(inspected, "fixture.json")
      File.write(fixture, JSON.generate(telemetry_fixture))
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => inspected },
        contract, "telemetry-fixtures", "mac", fixture
      )
      failures << "two roots: the telemetry preload was not taken from the inspected tree" if
        status.success?
      failures << "two roots: the telemetry preload came from somewhere else: " \
                  "#{(stdout + stderr).strip.inspect}" unless
        (stdout + stderr).include?("inspected tree telemetry preload reached")
    end
  end
  failures
end

# --- runtime program root --------------------------------------------------
#
# Site 4, and the layer #310 had to invent. Its harness pointed
# PLATFORM_CONTRACT_REPO_DIR at the contract copy, so both roots were one
# directory *inside the test built to catch the two-roots hazard*, and a
# rerooted-program plant was reported ACCEPTED. Here the inspected tree is a
# separate fixture that keeps the wrapper but has no sibling programs at all,
# so a rerooted program path cannot resolve and the plant fires.
#
# It asserts both directions at once: beszel-runtime.rb must require the shared
# telemetry evaluator out of the inspected tree (which the raising copy proves),
# and it must itself have come from the checkout (which the tree's lack of
# programs proves).

def runtime_program_root_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  with_contract_copy(wrapper: wrapper_source) do |contract|
    Dir.mktmpdir("nas-platform-beszel-runtimeroot.") do |raw|
      inspected = File.realpath(raw)
      build_fixture_repository(inspected)
      File.write(File.join(inspected, "tests/contracts/support/beszel_telemetry.rb"),
                 %(raise "inspected tree runtime require reached"\n))
      with_runtime_sandbox({}) do |paths|
        stdout, stderr, status = Open3.capture3(
          { "PATH" => "#{paths.fetch(:bin)}:#{ENV.fetch('PATH')}",
            "PLATFORM_CONTRACT_REPO_DIR" => inspected,
            "PLATFORM_CONTRACT_VAULT_FILE" => paths.fetch(:vault),
            "PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" => paths.fetch(:password),
            "PLATFORM_REPORT_ROOT" => paths.fetch(:report) },
          contract, "verify"
        )
        output = stdout + stderr
        failures << "runtime program root: the runtime half was accepted against an " \
                    "inspected tree whose telemetry evaluator raises" if status.success?
        failures << "runtime program root: the runtime half did not require the evaluator " \
                    "out of the inspected tree: #{output.strip.inspect}" unless
          output.include?("inspected tree runtime require reached")
        failures << "runtime program root: the runtime program was resolved from the " \
                    "inspected tree, which holds no sibling programs" if
          output.include?("beszel-runtime.rb (LoadError)") ||
          output.include?("No such file or directory")
      end
    end
  end
  failures
end

# ---------------------------------------------------------------------------
# Planted regressions
# ---------------------------------------------------------------------------

# The self-read guard's own plant. It lives apart from STATIC_MUTATIONS because
# its judge is self_read_failures, not static_failures: the plant is in the
# static program, the fixture's break is in the wrapper, and only that pairing
# distinguishes "the guard bites" from "the wrapper happens to satisfy it".
SELF_READ_MUTATIONS = [
  { label: "the resolved-root export sentinel",
    from: 'refuse("runtime contract does not export its resolved repository root") unless',
    to: "nil unless",
    rows: SELF_READ_ROWS.map { |row| row.fetch(:name) } }
].freeze

STATIC_MUTATIONS = [
  { label: "the closed-telemetry defaults check",
    from: 'refuse("defaults must not silently infer platform telemetry") unless',
    to: "nil unless",
    rows: ["defaults that infer platform telemetry instead of requiring it",
           "default categories that are no longer closed"] },
  { label: "the freshness window check",
    from: 'refuse("freshness must cover exactly three one-minute samples") unless',
    to: "nil unless",
    rows: ["a freshness window that is not three one-minute samples"] },
  { label: "the polling timeout check",
    from: 'refuse("telemetry polling timeout differs") unless',
    to: "nil unless",
    rows: ["a drifted telemetry polling timeout"] },
  { label: "the explicit-inventory-policy check",
    from: 'refuse("effective categories must use explicit inventory policy") unless',
    to: "nil unless",
    rows: ["effective categories inferred from the GPU input again",
           "effective categories that are not derived at all"] },
  { label: "the derived retry arithmetic refusal",
    from: 'refuse("telemetry polling must not use derived retry arithmetic") if',
    to: "nil if",
    rows: ["derived retry arithmetic reintroduced beside the deadline",
           "retry arithmetic hidden inside another derived value"] },
  { label: "the argument validation loop",
    from: 'refuse("#{name} argument validation is absent") unless options.dig(name, "type") == type',
    to: "nil unless options.dig(name, \"type\") == type",
    rows: ["beszel_required_telemetry_categories declared as str rather than list",
           "beszel_require_gpu_telemetry declared as str rather than bool",
           "beszel_telemetry_freshness_seconds declared as str rather than int",
           "beszel_telemetry_poll_timeout_seconds declared as str rather than int",
           "beszel_telemetry_request_timeout_seconds declared as str rather than int"] },
  { label: "the required task existence loop",
    from: 'refuse("missing #{name}") unless role_task_names.include?(name)',
    to: "nil unless role_task_names.include?(name)",
    rows: ["the require the selected beszel telemetry capability task surviving only under another name",
           "the require exactly one managed beszel system for telemetry task surviving only under another name",
           "the resolve persisted beszel telemetry evidence task surviving only under another name",
           "the verify persisted beszel telemetry categories task surviving only under another name"] },
  { label: "the no_log requirement on the telemetry poll",
    from: 'refuse("persisted telemetry poll must suppress authenticated results") unless',
    to: "nil unless",
    rows: ["a telemetry poll that no longer suppresses authenticated results"] },
  { label: "the one-deadline-aware-probe check",
    from: 'refuse("persisted telemetry poll must use one deadline-aware probe") unless probe_args.is_a?(Hash)',
    to: "nil unless probe_args.is_a?(Hash)",
    rows: ["a telemetry poll that is not one deadline-aware probe"],
    # Cascade, recorded rather than tolerated: with the shape check gone the
    # next two lines call probe_args&.key? on nil, so the authentication
    # sentence refuses instead. Both sentences name a real property; this note
    # is what records that the narrower one fires first today.
    detects: "refused for the wrong reason" },
  { label: "the probe authentication check",
    from: 'refuse("persisted telemetry probe is not authenticated") unless probe_args&.key?("auth_token")',
    to: 'nil unless probe_args&.key?("auth_token")',
    rows: ["a telemetry probe invoked without authentication"] },
  { label: "the total-deadline check",
    from: 'refuse("persisted telemetry probe does not receive the total deadline") unless',
    to: "nil unless",
    rows: ["a telemetry probe that no longer receives the total deadline"] },
  { label: "the probe implementation check",
    from: 'refuse("deadline probe implementation is absent") unless',
    to: "nil unless",
    rows: ["a probe implementation without its polling entry point",
           "a probe support module that no longer fetches container stats"] },
  { label: "the persisted-evidence provenance check",
    from: 'refuse("role treats live health as persisted telemetry") unless',
    to: "nil unless",
    rows: ["a role that treats live health as persisted telemetry",
           "probe evidence that no task consumes"] },
  { label: "the Intel agent image check",
    from: 'refuse("NAS Intel agent image differs") unless',
    to: "nil unless",
    rows: ["a NAS Intel agent from some other publisher"] },
  { label: "the render device check",
    from: 'refuse("NAS Intel render device differs") unless',
    to: "nil unless",
    rows: ["an Intel agent bound to some other render device",
           "an inventory render device path the compose definition cannot use"] },
  { label: "the agent capacity mount check",
    from: 'refuse("agent capacity mounts differ") unless expected_mounts.all?',
    to: "nil unless expected_mounts.all?",
    rows: ["a portable agent that lost a capacity mount",
           "an Intel agent that lost a capacity mount"] },
  { label: "the read-only socket proxy check",
    from: 'refuse("socket proxy is absent") unless',
    to: "nil unless",
    rows: ["a socket proxy with a writable Docker socket"] },
  { label: "the Mac capability check",
    from: 'refuse("Mac must use portable telemetry without a render device") unless',
    to: "nil unless",
    rows: ["a Mac host declaring the Intel agent", "a Mac host that claims GPU telemetry"] },
  { label: "the NAS GPU policy check",
    from: 'refuse("NAS telemetry policy must explicitly require GPU") unless',
    to: "nil unless",
    rows: ["a NAS host that stopped requiring GPU telemetry",
           "a NAS category list that no longer names gpu"] },
  { label: "the Mac verify hook check",
    from: 'refuse("Mac verification does not execute persisted telemetry proof") unless',
    to: "nil unless",
    rows: ["a Mac verify hook that skips the persisted telemetry proof"] },
  { label: "the Mac drift hook check",
    from: 'refuse("Mac drift hook does not execute category rejection semantics") unless',
    to: "nil unless",
    rows: ["a Mac drift hook that skips category rejection semantics"] },
  {
    # Not a refusal but the read that makes every parsed assertion meaningful.
    # A bare read of the role index selects none of the imported stages, so the
    # five required-task rows would report a role the program never looked at.
    label: "the static import splice",
    from: "role_tasks = flatten_tasks(PolicySupport.static_role_tasks(role_path))",
    to: "role_tasks = flatten_tasks(YAML.safe_load_file(role_path))",
    rows: ["an intact repository"],
    detects: "expected success"
  }
].freeze

FIXTURES_MUTATIONS = [
  { label: "the supported platform guard",
    from: 'abort "Beszel telemetry fixture failed: unknown platform" unless %w[mac nas].include?(platform)',
    to: "nil unless %w[mac nas].include?(platform)",
    rows: ["a platform the contract does not support", "the empty platform"],
    # Cascade: with the guard gone an unknown platform still fails, because
    # required_categories("linux") is the base three and the fixture satisfies
    # them -- so it PASSES for "linux" and the row catches it as accepted. The
    # empty platform behaves the same way.
    detects: "accepted what it must refuse" },
  { label: "the readiness refusal",
    from: 'abort "Beszel telemetry fixture failed: #{evidence.safe_failure}" unless evidence.ready?',
    to: "nil unless evidence.ready?",
    rows: ["a NAS triple with no GPU sample", "a sample older than the freshness window",
           "a sample belonging to another system", "an empty container sample",
           "a healthy system with no persisted records at all"] },
  { label: "the recorded clock requirement",
    from: 'now: Time.parse(fixture.fetch("now")).utc',
    to: 'now: Time.parse(fixture["now"] || "2026-08-12T12:00:00.000Z").utc',
    rows: ["a fixture with no recorded clock"],
    detects: "accepted what it must refuse" }
].freeze

RUNTIME_MUTATIONS = [
  { label: "the vault read status check",
    from: 'fail_contract("encrypted vault could not be read") unless status.success?',
    to: "nil unless status.success?",
    rows: ["a vault that cannot be decrypted"],
    detects: "refused for the wrong reason" },
  { label: "the complete-page requirement",
    from: 'fail_contract("#{collection} filtered identity exceeds one complete page") if response.fetch("totalPages", 0).to_i > 1',
    to: 'nil if response.fetch("totalPages", 0).to_i > 1',
    rows: ["an identity read that exceeds one complete page"],
    detects: "accepted what it must refuse" },
  { label: "the malformed JSON rescue",
    from: 'fail_contract("#{method.upcase} #{uri.path} returned malformed JSON")',
    to: "raise",
    rows: ["an identity read that is not JSON"],
    detects: "refused for the wrong reason" },
  {
    # Two live copies of the same sentence, one in the JSON helper and one in
    # the text helper, so each is scoped by the line below it rather than
    # planted twice. An unscoped sub would have hit whichever came first and
    # left the other guard in place, and the rows would still have gone red --
    # for the wrong reason. Reported by --self-test's own count assertion.
    label: "the expected status check in the JSON helper",
    from: "fail_contract(\"\#{method.upcase} \#{uri.path} returned HTTP \#{response.code}\") unless expected.include?(response.code.to_i)\n" \
          "  response.body.to_s.empty?",
    to: "nil unless expected.include?(response.code.to_i)\n  response.body.to_s.empty?",
    rows: ["an identity read the hub refuses",
           "a superuser identity the vault does not hold",
           "an application identity the vault does not hold"],
    detects: "refused for the wrong reason"
  },
  { label: "the expected status check in the text helper",
    from: "fail_contract(\"\#{method.upcase} \#{uri.path} returned HTTP \#{response.code}\") unless expected.include?(response.code.to_i)\n" \
          "  response.body\n",
    to: "nil unless expected.include?(response.code.to_i)\n  response.body\n",
    rows: ["a disposable ntfy whose history read fails"],
    detects: "refused for the wrong reason" },
  { label: "the exact-record absence check",
    from: 'fail_contract("#{description} is absent") if records.empty?',
    to: "nil if records.empty?",
    rows: ["no managed application user at all", "no universal token for the managed user",
           "drift against a platform with no managed system", "a managed alert that is absent"],
    detects: "refused for the wrong reason" },
  { label: "the exact-record duplicate check",
    from: "  if records.length > 1\n",
    to: "  if false\n",
    rows: ["two application users with the managed identity",
           "drift against a platform with two managed settings records"] },
  { label: "the same-name ownership refusal",
    from: 'unless wrong_owner_systems.empty? || MODE == "remove-duplicate"',
    to: "if false",
    rows: ["a same-name system outside the managed user relation"] },
  { label: "the verified-admin check",
    from: 'fail_contract("managed user is not verified admin") unless',
    to: "nil unless",
    rows: ["an application user that is not a verified admin",
           "an unverified application user"] },
  { label: "the universal token comparison",
    from: 'fail_contract("managed universal token differs from encrypted vault") unless',
    to: "nil unless",
    rows: ["a universal token that is not the vault's"] },
  { label: "the managed webhook comparison",
    from: 'fail_contract("managed ntfy webhook differs") unless',
    to: "nil unless",
    rows: ["a webhook pointing somewhere other than the managed ntfy topic"] },
  { label: "the managed alert comparison",
    from: 'fail_contract("managed #{name} alert differs") unless',
    to: "nil unless",
    rows: ["a drifted managed alert threshold"] },
  { label: "the decoy alert refusal",
    from: 'fail_contract("managed alerts were attached to the decoy system") unless',
    to: "nil unless",
    rows: ["managed alerts attached to the decoy system"] },
  { label: "the non-retryable telemetry rescue",
    from: "rescue BeszelTelemetry::NonRetryableFetchError => error\n  fail_contract(error.message)",
    to: "rescue BeszelTelemetry::NonRetryableFetchError => error\n  nil",
    rows: ["a telemetry read the hub will not authorize",
           "a telemetry read the hub answers with 404"],
    detects: "accepted what it must refuse" },
  { label: "the persisted telemetry readiness refusal",
    from: "  unless evidence.ready?\n    fail_contract(evidence.safe_failure)\n  end",
    to: "  nil unless evidence.ready?",
    rows: ["persisted telemetry that never becomes ready"],
    detects: "accepted what it must refuse" },
  { label: "the drift role patch",
    from: 'body: { role: "user" })',
    to: "body: {})",
    rows: ["the drift fixture install"],
    detects: "drift did not demote the managed user" },
  { label: "the drift universal token patch",
    from: 'body: { token: "11111111-1111-4111-a111-111111111111" })',
    to: "body: {})",
    rows: ["the drift fixture install"],
    detects: "drift did not replace the universal token" },
  { label: "the drift decoy creation",
    from: "  decoy_systems = records(\"systems\", admin_token, equality(\"name\", DECOY_NAME))\n  unless decoy_systems.any?",
    to: "  decoy_systems = records(\"systems\", admin_token, equality(\"name\", DECOY_NAME))\n  if false",
    rows: ["the drift fixture install"],
    detects: "drift did not create the decoy system" },
  { label: "the drift user readback",
    from: 'fail_contract("managed application user drift changed") unless',
    to: "nil unless",
    rows: ["drift verified against a converged platform"],
    detects: "refused for the wrong reason" },
  { label: "the drift token readback",
    from: 'fail_contract("managed universal token drift changed") unless',
    to: "nil unless",
    rows: ["a drift whose universal token was repaired"] },
  { label: "the drift webhook readback",
    from: 'fail_contract("managed webhook drift changed") unless',
    to: "nil unless",
    rows: ["a drift whose webhook was repaired"] },
  { label: "the drift alert readback",
    from: 'fail_contract("managed CPU alert drift changed") unless',
    to: "nil unless",
    rows: ["a drift whose CPU alert was repaired"] },
  { label: "the drift decoy readback",
    from: 'fail_contract("decoy system drift changed") unless',
    to: "nil unless",
    rows: ["a drift whose decoy system was removed"] },
  { label: "the duplicate evidence write",
    from: "    mode: \"w\",\n    perm: 0o600\n  )\nwhen \"wrong-owner\"",
    to: "    mode: \"w\"\n  )\nwhen \"wrong-owner\"",
    rows: ["the duplicate-system fixture install"],
    detects: "wrote the evidence artifact" },
  { label: "the wrong-owner fixture user reuse",
    from: "  wrong_owner_user = if wrong_owner_users.empty?",
    to: "  wrong_owner_user = if true",
    rows: ["a wrong-owner install repeated over its own fixture user"],
    detects: "created a second fixture user" },
  { label: "the removal's kept identifier",
    from: "    keep_id = ids.first",
    to: "    keep_id = ids.last",
    rows: ["the removal of a wrong-owner fixture"],
    detects: "removal left more than the managed system" },
  { label: "the removal's evidence cleanup",
    from: "    File.unlink(DUPLICATE_EVIDENCE)",
    to: "    nil",
    rows: ["the removal of a wrong-owner fixture"],
    detects: "removal left the evidence artifact behind" },
  { label: "the anti-replay baseline requirement",
    from: 'fail_contract("disposable ntfy has no baseline message for anti-replay polling") unless baseline_id',
    to: "nil unless baseline_id",
    rows: ["a disposable ntfy that keeps no message history"],
    detects: "refused for the wrong reason" },
  { label: "the delivery failure check",
    from: 'fail_contract("Beszel test notification reported delivery failure") unless notification["err"] == false',
    to: 'nil unless notification["err"] == false',
    rows: ["a hub that reports the notification failed"],
    detects: "accepted what it must refuse" },
  { label: "the anti-replay poll deadline",
    from: 'fail_contract("Beszel test notification did not reach disposable ntfy") if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline',
    to: "nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline",
    rows: [],
    # Deliberately unplanted. Removing the deadline turns the anti-replay loop
    # into an unbounded poll, so the row would hang rather than report -- which
    # is #310's ${VAR:?}-to-:= lesson in a different shape. The deadline is
    # asserted by the row above it instead, which reaches this sentence.
    skip: "removing the deadline makes the row hang rather than fail"
  },
  { label: "the notification URL the proof sends",
    from: 'body: { url: expected_url })',
    to: 'body: { url: "ntfy://elsewhere.invalid" })',
    rows: ["the notification proof against a delivering hub"],
    detects: "runtime: notify did not send the vault-derived webhook URL" }
].freeze

WRAPPER_MUTATIONS = [
  { label: "a dropped stdin redirect on the static invocation",
    from: %(  ruby -ryaml "$static_program" "$repo_dir" </dev/null\n),
    to: %(  ruby -ryaml "$static_program" "$repo_dir"\n),
    layer: :stdin },
  { label: "a dropped stdin redirect on the telemetry-fixtures invocation",
    from: %(    "$telemetry_fixtures_program" "$2" "$3" </dev/null\n),
    to: %(    "$telemetry_fixtures_program" "$2" "$3"\n),
    layer: :stdin },
  { label: "a dropped stdin redirect on the runtime invocation",
    from: %(exec ruby "$runtime_program" "$mode" </dev/null\n),
    to: %(exec ruby "$runtime_program" "$mode"\n),
    layer: :stdin },
  {
    # The static half's preload, carried verbatim from the heredoc and
    # load-bearing: beszel-static.rb calls YAML.safe_load_file on its first line
    # and requires tests/policy_support.rb -- which does require yaml -- eight
    # lines LATER, so dropping this is `uninitialized constant YAML (NameError)`.
    # Measured through the wrapper, not inferred from the program's requires.
    label: "the static invocation's -ryaml preload",
    from: %(  ruby -ryaml "$static_program" "$repo_dir" </dev/null\n),
    to: %(  ruby "$static_program" "$repo_dir" </dev/null\n),
    layer: :wrapper
  },
  {
    # And the one that is INERT, declared rather than planted. Dropping -rjson
    # alone leaves telemetry-fixtures passing, because the second preload --
    # the inspected tree's own beszel_telemetry.rb -- does `require "json"` on
    # its line 4, before the program body runs. Dropping BOTH is
    # `uninitialized constant JSON (NameError)`, which is how this was
    # established. So -rjson is #291's `-rpathname`: transcribed verbatim
    # because a quoted heredoc interpolates nothing and the invocation is the
    # thing being preserved, and left unplanted because there is no outcome to
    # assert. It is not removed: nothing guarantees the support library keeps
    # requiring json, and the day it stops, this preload is what holds.
    label: "the telemetry-fixtures -rjson preload",
    from: %(  exec ruby -rjson -r"$repo_dir/tests/contracts/support/beszel_telemetry" \\\n),
    to: %(  exec ruby -r"$repo_dir/tests/contracts/support/beszel_telemetry" \\\n),
    layer: :wrapper,
    skip: "inert -- the support preload already requires json, so dropping it changes no outcome"
  },
  { label: "the static program resolved from the inspected tree",
    from: "static_program=$contract_repo_dir/tests/contracts/beszel-static.rb",
    to: "static_program=$repo_dir/tests/contracts/beszel-static.rb",
    layer: :two_roots },
  { label: "the telemetry-fixtures program resolved from the inspected tree",
    from: "telemetry_fixtures_program=$contract_repo_dir/tests/contracts/beszel-telemetry-fixtures.rb",
    to: "telemetry_fixtures_program=$repo_dir/tests/contracts/beszel-telemetry-fixtures.rb",
    layer: :two_roots },
  { label: "the runtime program resolved from the inspected tree",
    from: "runtime_program=$contract_repo_dir/tests/contracts/beszel-runtime.rb",
    to: "runtime_program=$repo_dir/tests/contracts/beszel-runtime.rb",
    layer: :runtime_program_root },
  { label: "the telemetry preload rerooted to the checkout",
    from: %(  exec ruby -rjson -r"$repo_dir/tests/contracts/support/beszel_telemetry" \\\n),
    to: %(  exec ruby -rjson -r"$contract_repo_dir/tests/contracts/support/beszel_telemetry" \\\n),
    layer: :two_roots },
  {
    # The export both halves read, planted in the direction that breaks site 2
    # and site 4 at once. The literal occurs TWICE, so the count is stated:
    # an unscoped sub would reroot one pair and leave the other, which changes
    # nothing because the second assignment wins.
    label: "the inspected-tree export rerooted to the checkout",
    from: "PLATFORM_CONTRACT_REPO_DIR=$repo_dir\n",
    to: "PLATFORM_CONTRACT_REPO_DIR=$contract_repo_dir\n",
    occurrences: 2,
    layer: :two_roots
  },
  { label: "the mode guard",
    from: "case $mode in static|telemetry-fixtures|verify|drift|drift-verify|duplicate|wrong-owner|remove-duplicate|notify) ;; *) exit 2 ;; esac",
    to: "case $mode in *) ;; esac",
    layer: :wrapper },
  { label: "the static mode gate",
    from: %(if [ "$mode" = static ]; then\n),
    to: %(if [ "$mode" != static ]; then\n),
    layer: :wrapper },
  { label: "the telemetry-fixtures argument count guard",
    from: %(  [ "$#" -eq 3 ] || exit 2\n),
    to: %(  [ "$#" -ge 1 ] || exit 2\n),
    layer: :wrapper },
  { label: "the vault file requirement",
    from: %(: "${PLATFORM_CONTRACT_VAULT_FILE:?}"),
    to: %(: "${PLATFORM_CONTRACT_VAULT_FILE:=}"),
    layer: :wrapper },
  { label: "the vault password file requirement",
    from: %(: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:?}"),
    to: %(: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:=}"),
    layer: :wrapper },
  { label: "the report root requirement",
    from: %(: "${PLATFORM_REPORT_ROOT:?}"),
    to: %(: "${PLATFORM_REPORT_ROOT:=}"),
    layer: :wrapper }
].freeze

# Returns [planted_source, error]. It accumulates rather than aborting, and that
# is not a style choice: every count assertion here is a claim about a literal in
# a file this PR moved, and learning them one interpreter run at a time is the
# expensive habit this whole file exists to break. One run of --self-test now
# reports every wrong count at once. Two were wrong on the first attempt, both
# because the literal occurs twice.
def plant(source, mutation)
  occurrences = mutation.fetch(:occurrences, 1)
  from = mutation.fetch(:from)
  found = source.scan(from).length
  unless found == occurrences
    return [nil, "could not plant #{mutation.fetch(:label)}: expected #{occurrences} " \
                 "match(es) of #{from.inspect}, found #{found}"]
  end

  planted = occurrences == 1 ? source.sub(from, mutation.fetch(:to))
                             : source.gsub(from, mutation.fetch(:to))
  return [nil, "planted nothing for #{mutation.fetch(:label)}"] if planted == source

  [planted, nil]
end

def rows_named(rows, names)
  selected = rows.select { |row| names.include?(row.fetch(:name)) }
  unless selected.length == names.length
    missing = names - selected.map { |row| row.fetch(:name) }
    return [nil, "names a row that does not exist: #{missing.inspect}"]
  end

  [selected, nil]
end

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
  skipped = []

  # Every plant is prepared on the main thread, before the pool. `plant` and
  # `rows_named` abort with a sentence naming what they could not find, and an
  # abort inside a worker raises SystemExit there: the thread dies without
  # recording its result and the pool's own `collected.fetch` then reports a
  # KeyError instead of that sentence.
  preparation_errors = []
  prepare = lambda do |mutations, source_path, rows|
    mutations.reject { |mutation| mutation[:skip] }.filter_map do |mutation|
      source, plant_error = plant(File.read(source_path), mutation)
      selected, rows_error = rows_named(rows, mutation.fetch(:rows))
      [plant_error, rows_error].compact.each { |error| preparation_errors << error }
      next if plant_error || rows_error

      [mutation, source, selected]
    end
  end
  skipped.concat(
    (STATIC_MUTATIONS + SELF_READ_MUTATIONS + FIXTURES_MUTATIONS + RUNTIME_MUTATIONS +
     WRAPPER_MUTATIONS)
      .select { |mutation| mutation[:skip] }
      .map { |mutation| "#{mutation.fetch(:label)}: #{mutation.fetch(:skip)}" }
  )

  static_cases = prepare.call(STATIC_MUTATIONS, STATIC_PROGRAM, STATIC_ROWS)
  self_read_cases = prepare.call(SELF_READ_MUTATIONS, STATIC_PROGRAM, SELF_READ_ROWS)
  fixtures_cases = prepare.call(FIXTURES_MUTATIONS, FIXTURES_PROGRAM, FIXTURES_ROWS)
  runtime_cases = prepare.call(RUNTIME_MUTATIONS, RUNTIME_PROGRAM, RUNTIME_ROWS)
  wrapper_cases = WRAPPER_MUTATIONS.reject { |mutation| mutation[:skip] }
                                   .filter_map do |mutation|
    source, error = plant(File.read(CONTRACT), mutation)
    preparation_errors << error if error
    next if error

    [mutation, source]
  end
  unless preparation_errors.empty?
    preparation_errors.each { |error| warn "FAIL self-test: #{error}" }
    abort "#{preparation_errors.length} self-test plant(s) could not be prepared"
  end

  in_parallel_cases(mismatches, static_cases) do |(mutation, source, rows), collected|
    Dir.mktmpdir("nas-platform-beszel-mutant.") do |directory|
      path = File.join(directory, "beszel-static.rb")
      File.write(path, source)
      report_mutation(collected, mutation, static_failures(path, rows), rows)
    end
  end
  planted += static_cases.length

  in_parallel_cases(mismatches, self_read_cases) do |(mutation, source, rows), collected|
    report_mutation(collected, mutation, self_read_failures(static_source: source), rows)
  end
  planted += self_read_cases.length

  in_parallel_cases(mismatches, fixtures_cases) do |(mutation, source, rows), collected|
    Dir.mktmpdir("nas-platform-beszel-mutant.") do |directory|
      path = File.join(directory, "beszel-telemetry-fixtures.rb")
      File.write(path, source)
      report_mutation(collected, mutation, fixtures_failures(path, rows), rows)
    end
  end
  planted += fixtures_cases.length

  in_parallel_cases(mismatches, runtime_cases) do |(mutation, source, rows), collected|
    Dir.mktmpdir("nas-platform-beszel-mutant.") do |directory|
      path = File.join(directory, "beszel-runtime.rb")
      File.write(path, source)
      report_mutation(collected, mutation, runtime_failures(path, rows), rows)
    end
  end
  planted += runtime_cases.length

  in_parallel_cases(mismatches, wrapper_cases) do |(mutation, source), collected|
    caught = case mutation.fetch(:layer)
             when :stdin then stdin_failures(wrapper_source: source)
             when :two_roots then two_roots_failures(wrapper_source: source)
             when :runtime_program_root
               runtime_program_root_failures(wrapper_source: source)
             else wrapper_failures(wrapper_source: source)
             end
    collected << "removing #{mutation.fetch(:label)} was accepted" if caught.empty?
  end
  planted += wrapper_cases.length

  skipped.each { |note| warn "SKIP self-test plant: #{note}" }
  unless mismatches.empty?
    mismatches.each { |mismatch| warn "FAIL self-test: #{mismatch}" }
    abort "#{mismatches.length} self-test mismatch(es) of #{planted} planted regressions"
  end

  puts "beszel contract: self-test detects #{planted} planted regressions"
  exit
end

failures = static_failures + missing_file_failures + fixtures_failures + runtime_failures +
           wrapper_failures + self_read_failures + stdin_failures + two_roots_failures +
           runtime_program_root_failures
unless failures.empty?
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} Beszel contract violation(s)"
end

puts "beszel contract: #{STATIC_ROWS.length} static, #{FIXTURES_ROWS.length} fixture and " \
     "#{RUNTIME_ROWS.length} runtime properties hold, both self-read guards bite against a " \
     "sentinel that did not move, and the wrapper reaches all three programs from its own " \
     "checkout while all three of its inspected-tree reads stay bound to the tree"
