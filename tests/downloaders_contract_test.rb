#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Behaviour of the downloaders service contract's Ruby program.
#
# Until #147 the whole program lived in a `<<'RUBY'` heredoc inside
# tests/contracts/downloaders.sh. `sh -n` reads a quoted heredoc as opaque text,
# so the only thing that ever executed it was `tests/contracts/downloaders.sh
# static` -- and a contract that passes says nothing about which of its
# assertions still bite. tests/contracts/downloaders-static.rb is a file now, so
# each one can be moved on its own.
#
# Two layers, because the contract has two kinds of property:
#
#   Static -- build a fixture repository from the files the program reads, break
#   exactly one thing in it, and require the program to name that thing. The
#   assertion text is the interface: a guard that fails for the wrong reason has
#   stopped guarding what it names, so every row pins the exact diagnostic.
#
#   Wrapper -- tests/contracts/downloaders.sh is what turns a mode into an
#   invocation. Its rows prove the mode guard, that the program is actually
#   reached, that the program comes from the checkout while the tree it inspects
#   does not, and that it cannot consume the caller's stdin.
#
# Run with --self-test to plant a regression in the program and in the wrapper
# and prove the rows above detect each one. It accumulates its mismatches rather
# than aborting on the first.

require "etc"
require "fileutils"
require "open3"
require "rbconfig"
require "shellwords"
require "tmpdir"
require "yaml"

require_relative "policy_support"

include TestScaffold

ROOT = File.expand_path("..", __dir__)
# The prefix every refusal this file judges has to carry. Matching the
# fragment alone accepted a backtrace or an echoed argument as a refusal.
DIAGNOSTIC_PREFIX = "Downloaders contract failed: "
CONTRACT = File.join(ROOT, "tests", "contracts", "downloaders.sh")
STATIC_PROGRAM = File.join(ROOT, "tests", "contracts", "downloaders-static.rb")

# Exactly what the program reads, plus the shared flatten_tasks it requires
# through PLATFORM_CONTRACT_REPO_DIR. Its `required` list names six paths and it
# then reads a seventh, services/downloaders/compose.yml, which the existence
# sweep never checks -- so removing that one is a crash rather than a
# diagnostic. Recorded here rather than fixed: this change moves code.
FIXTURE_FILES = %w[
  roles/downloaders/defaults/main.yml
  roles/downloaders/tasks/main.yml
  roles/downloaders/tasks/reconcile_sabnzbd.yml
  roles/downloaders/tasks/verify.yml
  roles/downloaders/templates/env.j2
  roles/downloaders/templates/sabnzbd.ini.j2
  services/downloaders/compose.yml
  tests/policy_support.rb
].freeze

SUCCESS_LINE = "downloaders contract: Phase 1 Usenet ownership holds"
MODE_REFUSAL = "downloaders contract accepts only static"

# Never more workers than cores. tests/validate-policy.sh already runs its
# checks concurrently, so oversubscribing a four-core CI runner trades wall time
# for contention. Each case owns its own mktmpdir fixture and shares nothing but
# the failure list, and failures are concatenated in row order so the report is
# deterministic.
CASE_WORKER_LIMIT = Integer(
  ENV.fetch("DOWNLOADERS_CONTRACT_CASE_WORKERS") { [Etc.nprocessors, 8].min.to_s }
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

# `downloaders role must deploy through docker_compose_v2` has deliberately no
# row. It asserts that some task carries a docker_compose_v2 mapping, and the
# activation-order assertion two lines below it already requires a
# docker_compose_v2 mapping whose `state` is `present` -- so the weaker claim
# cannot be broken without also breaking the stronger one, and any break
# produces three diagnostics rather than the one a row would pin. A row
# expecting a three-sentence output would freeze that redundancy and make
# removing it look like a regression. Reported, not pinned.
STATIC_ROWS = [
  {
    name: "an intact repository",
    break: ->(_root) {},
    expects: nil
  },
  {
    name: "a declared file that is gone",
    break: ->(root) { FileUtils.rm(File.join(root, "roles/downloaders/templates/sabnzbd.ini.j2")) },
    expects: "missing roles/downloaders/templates/sabnzbd.ini.j2"
  },
  {
    name: "a drifted SABnzbd category destination",
    break: lambda { |root|
      mutate_text(root, "roles/downloaders/defaults/main.yml",
                  "movies: /data/media/.acquisition/usenet/movies",
                  "movies: /data/media/.acquisition/usenet/films")
    },
    expects: "SABnzbd category contract drifted"
  },
  {
    name: "an unbounded article cache",
    break: lambda { |root|
      mutate_text(root, "roles/downloaders/defaults/main.yml",
                  "cache_limit: 256M", "cache_limit: 0")
    },
    expects: "SABnzbd article cache must be explicitly bounded"
  },
  {
    name: "unbounded concurrent unpack work",
    break: lambda { |root|
      mutate_text(root, "roles/downloaders/defaults/main.yml",
                  "direct_unpack_threads: 1", "direct_unpack_threads: 4")
    },
    expects: "SABnzbd concurrent unpack work must be explicitly bounded"
  },
  {
    name: "a TLS mode that authenticates nothing",
    break: lambda { |root|
      mutate_text(root, "roles/downloaders/defaults/main.yml", "ssl_verify: 3", "ssl_verify: 1")
    },
    expects: "SABnzbd must verify the provider's TLS certificate"
  },
  {
    name: "a state guard that never runs before deployment",
    break: lambda { |root|
      mutate_text(root, "roles/downloaders/tasks/main.yml",
                  "ansible.builtin.include_tasks: state_guard.yml",
                  "ansible.builtin.include_tasks: noop_guard.yml")
    },
    expects: "downloaders role must include the state guard before deployment"
  },
  {
    name: "a project CPU policy that is never verified",
    break: lambda { |root|
      mutate_text(root, "roles/downloaders/tasks/main.yml",
                  "container_cpu_service_name: downloaders",
                  "container_cpu_service_name: not_downloaders")
    },
    expects: "downloaders role must verify its effective project CPU policy"
  },
  {
    name: "an activation no longer gated on the Usenet switch",
    break: lambda { |root|
      mutate_text(root, "roles/downloaders/tasks/main.yml",
                  "    wait_timeout: \"{{ platform_compose_wait_timeout }}\"\n" \
                  "  when: media_usenet_enabled | bool\n  register: downloaders_deploy",
                  "    wait_timeout: \"{{ platform_compose_wait_timeout }}\"\n" \
                  "  register: downloaders_deploy")
    },
    expects: "downloaders role must gate activation on media_usenet_enabled"
  },
  {
    name: "Arr clients reconciled before SABnzbd",
    break: lambda { |root|
      mutate_text(root, "roles/downloaders/tasks/main.yml",
                  "ansible.builtin.include_tasks: reconcile_sabnzbd.yml",
                  "ansible.builtin.include_tasks: reconcile_sab.yml")
    },
    expects: "downloaders must reconcile Arr clients only after SABnzbd"
  },
  {
    name: "a CPU set rendered twice",
    break: lambda { |root|
      mutate_text(root, "roles/downloaders/templates/env.j2",
                  "PLATFORM_CONTAINER_CPUSET={{ platform_effective_container_cpuset }}",
                  "PLATFORM_CONTAINER_CPUSET={{ platform_effective_container_cpuset }}\n" \
                  "PLATFORM_CONTAINER_CPUSET=0-3")
    },
    expects: "downloaders env must render CPU set exactly once"
  },
  {
    name: "an API key surviving only in a comment",
    break: lambda { |root|
      mutate_text(root, "roles/downloaders/templates/env.j2",
                  "SABNZBD_API_KEY={{ vault_downloaders_sabnzbd_api_key }}",
                  "# SABNZBD_API_KEY={{ vault_downloaders_sabnzbd_api_key }}")
    },
    expects: "downloaders env must carry only declared API keys"
  },
  {
    name: "a credential-bearing request that logs its payload",
    break: lambda { |root|
      path = File.join(root, "roles/downloaders/tasks/reconcile_sabnzbd.yml")
      body = File.read(path)
      File.write(path, body.gsub(/^(\s*)no_log: true$/, '\1no_log: false'))
    },
    expects: "every SABnzbd credential-bearing API task must use no_log"
  },
  {
    name: "a provider push that has fallen out of the credential selector",
    break: lambda { |root|
      mutate_text(root, "roles/downloaders/tasks/reconcile_sabnzbd.yml",
                  'password: "{{ vault_downloaders_sabnzbd_server_password }}"',
                  'password: "{{ vault_downloaders_sabnzbd_server_pass }}"')
    },
    expects: "the Usenet provider push must stay inside the credential guard"
  },
  {
    name: "a provider password travelling in a URL",
    break: lambda { |root|
      mutate_text(root, "roles/downloaders/tasks/reconcile_sabnzbd.yml",
                  "        url: \"{{ downloaders_sabnzbd_api }}\"\n" \
                  "        method: POST\n        body_format: form-urlencoded",
                  "        url: \"{{ downloaders_sabnzbd_api }}" \
                  "?password={{ vault_downloaders_sabnzbd_server_password }}\"\n" \
                  "        method: POST\n        body_format: form-urlencoded")
    },
    expects: "the Usenet provider password must never travel in a URL"
  },
  {
    # A second condition on the undeclared branch, not a different one. Two
    # conditions are no longer each other's negation, so the pair assertion
    # fires -- while the branch's own key in branch_claims is still its first
    # condition, so the per-branch count assertion below stays satisfied and
    # this row pins one diagnostic rather than two.
    name: "a provider-state branch that is no longer the other's negation",
    break: lambda { |root|
      mutate_text(root, "roles/downloaders/tasks/verify.yml",
                  "  when: not downloaders_usenet_provider_declared | bool",
                  "  when:\n    - not downloaders_usenet_provider_declared | bool\n" \
                  "    - downloaders_sabnzbd_verify_servers_enabled | default(true) | bool")
    },
    expects: "the owned Usenet server must be verified in both provider states"
  },
  {
    name: "a provider-state branch that claims no server count",
    break: lambda { |root|
      mutate_text(root, "roles/downloaders/tasks/verify.yml",
                  "      - downloaders_verify_sabnzbd_server_matches | length == 0",
                  "      - downloaders_verify_sabnzbd_server_matches is defined")
    },
    expects: "each owned Usenet server branch must claim its own server count"
  },
  {
    name: "a credential guard gated on a second spelling",
    break: lambda { |root|
      mutate_text(root, "roles/downloaders/tasks/main.yml",
                  "when: downloaders_usenet_provider_declared | bool",
                  "when: vault_downloaders_sabnzbd_server_password | default('') | length > 0")
    },
    expects: "the provider credential guard must be gated on the declared fact"
  },
  {
    name: "a server reconciliation gated on a second spelling",
    break: lambda { |root|
      mutate_text(root, "roles/downloaders/tasks/reconcile_sabnzbd.yml",
                  "  when: downloaders_usenet_provider_declared | bool",
                  "  when: downloaders_sabnzbd_server_name | default('') | length > 0")
    },
    expects: "the Usenet server reconciliation must be gated on the declared fact"
  },
  {
    # An added mapping test rather than a rewritten sequence one, so the
    # positive "reconciled from the API list schema" assertion is untouched and
    # only the refusal below it fires.
    name: "categories also read as a mapping",
    break: lambda { |root|
      mutate_text(root, "roles/downloaders/tasks/reconcile_sabnzbd.yml",
                  "---\n- name: Read SABnzbd owned configuration before reconciliation",
                  "---\n- name: Branch on the mapping shape as well\n" \
                  "  ansible.builtin.debug:\n" \
                  "    msg: config.categories is mapping\n\n" \
                  "- name: Read SABnzbd owned configuration before reconciliation")
    },
    expects: "SABnzbd categories must not be treated as a mapping"
  },
  {
    name: "a SABnzbd bootstrap bound to loopback only",
    break: lambda { |root|
      mutate_text(root, "roles/downloaders/templates/sabnzbd.ini.j2",
                  "host = 0.0.0.0", "host = 127.0.0.1")
    },
    expects: "bootstrap must bind SABnzbd on all container interfaces"
  },
  {
    name: "a bootstrap that invents a Usenet provider",
    break: lambda { |root|
      path = File.join(root, "roles/downloaders/templates/sabnzbd.ini.j2")
      File.write(path, "#{File.read(path)}\n[servers]\n[[news.invalid]]\nhost = news.invalid\n")
    },
    expects: "bootstrap must not invent a Usenet provider"
  },
  {
    name: "a category loop surviving only in a comment",
    break: lambda { |root|
      mutate_text(root, "roles/downloaders/templates/sabnzbd.ini.j2",
                  "{% for category, directory in downloaders_sabnzbd_categories.items() %}",
                  "{# {% for category, directory in downloaders_sabnzbd_categories.items() %} #}")
    },
    expects: "bootstrap must render every declared category and destination"
  },
  {
    name: "Unpackerr watching a protocol it does not own",
    break: lambda { |root|
      mutate_text(root, "services/downloaders/compose.yml",
                  "UN_SONARR_0_PROTOCOLS: usenet", "UN_SONARR_0_PROTOCOLS: torrent")
    },
    expects: "Unpackerr must integrate both Arr services over Usenet"
  },
  {
    name: "drifted Unpackerr file and directory modes",
    break: lambda { |root|
      mutate_text(root, "services/downloaders/compose.yml",
                  'UN_FILE_MODE: "0644"', 'UN_FILE_MODE: "0666"')
    },
    expects: "Unpackerr file and directory modes drifted"
  },
  {
    name: "an Unpackerr probe aimed past its own listener",
    break: lambda { |root|
      mutate_text(root, "services/downloaders/compose.yml",
                  "UN_WEBSERVER_LISTEN_ADDR: 127.0.0.1:5656",
                  "UN_WEBSERVER_LISTEN_ADDR: 127.0.0.1:5657")
    },
    expects: "Unpackerr's health probe must fetch the web server it enables, on loopback"
  },
  {
    name: "an Unpackerr listener switched off under a probe that needs it",
    break: lambda { |root|
      mutate_text(root, "services/downloaders/compose.yml",
                  'UN_WEBSERVER_METRICS: "true"', 'UN_WEBSERVER_METRICS: "false"')
    },
    expects: "Unpackerr's health probe must fetch the web server it enables, on loopback"
  }
].freeze

def static_failures(program, rows = STATIC_ROWS)
  failures = []
  in_parallel_cases(failures, rows) do |row, collected|
    Dir.mktmpdir("nas-platform-downloaders-static.") do |raw|
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

# --- wrapper layer ---------------------------------------------------------
#
# tests/contracts/downloaders.sh resolves its program from its own checkout
# rather than from the tree it is inspecting, so a copy of the two files into a
# throwaway tests/contracts/ is a whole working contract. That is what lets a
# row point PLATFORM_CONTRACT_REPO_DIR at a broken fixture and still exercise
# the real wrapper. The copy is laid into a fixture repository so it is also a
# valid tree to inspect, which is what the unset-variable row needs.

def with_contract_copy(static: File.read(STATIC_PROGRAM), wrapper: File.read(CONTRACT))
  Dir.mktmpdir("nas-platform-downloaders-wrapper.") do |raw|
    root = File.realpath(raw)
    build_fixture_repository(root)
    contracts = File.join(root, "tests", "contracts")
    FileUtils.mkdir_p(contracts)
    wrapper_path = File.join(contracts, "downloaders.sh")
    File.write(wrapper_path, wrapper)
    File.chmod(0o755, wrapper_path)
    File.write(File.join(contracts, "downloaders-static.rb"), static)
    yield wrapper_path, root
  end
end

# Reports what the program saw on stdin and what the caller still has, which is
# the only way the redirect is observable: the real program never reads stdin,
# so the redirect is what keeps that true rather than something that changes an
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
    failures << "stdin: the program was handed the caller's input: #{output.strip.inspect}" unless
      output.include?('probe read ""')
    failures << "stdin: the caller's input did not survive the contract: #{output.strip.inspect}" unless
      output.include?("left:caller-payload")
  end
  failures
end

def wrapper_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  with_contract_copy(wrapper: wrapper_source) do |contract|
    %w[verify drift runtime --platform].each do |mode|
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => ROOT }, contract, mode
      )
      failures << "wrapper: mode #{mode} was accepted" if status.success?
      failures << "wrapper: mode #{mode} was refused with exit #{status.exitstatus}, wanted 2" unless
        status.exitstatus == 2
      failures << "wrapper: mode #{mode} was refused without its diagnostic" unless
        (stdout + stderr).include?(MODE_REFUSAL)
    end

    # No argument at all is the shape run_contracts.rb --execute uses.
    [[], ["static"]].each do |argv|
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => ROOT }, contract, *argv
      )
      failures << "wrapper: #{argv.inspect} failed against this repository: #{(stdout + stderr).strip}" unless
        status.success?
      failures << "wrapper: #{argv.inspect} did not report the property it proved" unless
        stdout.include?(SUCCESS_LINE)
    end

    # The row that proves the wrapper still runs the program at all: the tree
    # under inspection is broken, the wrapper's own checkout is not.
    Dir.mktmpdir("nas-platform-downloaders-broken.") do |raw|
      broken = File.realpath(raw)
      build_fixture_repository(broken)
      FileUtils.rm(File.join(broken, "roles/downloaders/templates/sabnzbd.ini.j2"))
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => broken }, contract, "static"
      )
      failures << "wrapper: static mode passed against a broken repository" if status.success?
      failures << "wrapper: static mode did not report the broken repository" unless
        (stdout + stderr).include?("missing roles/downloaders/templates/sabnzbd.ini.j2")
    end
  end

  # The branch every deployment actually takes. Neither tests/integration.sh nor
  # run_contracts.rb --execute sets PLATFORM_CONTRACT_REPO_DIR, so the default is
  # the only path in production -- and it is the one where resolving the program
  # from the script's own checkout is load-bearing rather than shadowed.
  with_contract_copy do |contract, copy_root|
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => nil }, contract, "static"
    )
    failures << "wrapper: static mode failed with no repository named: #{(stdout + stderr).strip}" unless
      status.success?
    failures << "wrapper: static mode did not report the property it proved" unless
      stdout.include?(SUCCESS_LINE)

    # ... and it read that checkout rather than some other tree: break the copy
    # and the same unset invocation must now refuse.
    FileUtils.rm(File.join(copy_root, "roles/downloaders/templates/sabnzbd.ini.j2"))
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => nil }, contract, "static"
    )
    failures << "wrapper: with no repository named, static mode inspected some other tree" if
      status.success?
    failures << "wrapper: with no repository named, static mode did not report the broken tree" unless
      (stdout + stderr).include?("missing roles/downloaders/templates/sabnzbd.ini.j2")
  end
  failures
end

# The two-roots property, stated as an outcome rather than as the wrapper's text.
# An inspected tree with no tests/contracts at all must still pass, because the
# program comes from the checkout; and the program must still require
# tests/policy_support.rb out of the inspected tree, because that is the tree
# whose task files it is flattening.
def two_roots_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  with_contract_copy(wrapper: wrapper_source) do |contract|
    Dir.mktmpdir("nas-platform-downloaders-tworoots.") do |raw|
      inspected = File.realpath(raw)
      build_fixture_repository(inspected)
      FileUtils.rm_rf(File.join(inspected, "tests", "contracts"))
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => inspected }, contract, "static"
      )
      failures << "two roots: an inspected tree with no tests/contracts was refused, so the " \
                  "program is being resolved from it: #{(stdout + stderr).strip}" unless status.success?
      failures << "two roots: the program did not report the property it proved" unless
        stdout.include?(SUCCESS_LINE)
    end

    # The other direction. The inspected tree's own flatten_tasks is what the
    # program must use, so a tree whose policy_support.rb refuses to load has to
    # take the contract down with it. Reading the checkout's copy instead would
    # pass here, silently.
    Dir.mktmpdir("nas-platform-downloaders-support.") do |raw|
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
    from: 'failures << "missing #{relative}" unless File.file?(File.join(root, relative))',
    to: "failures << relative if false",
    rows: ["a declared file that is gone"],
    # The existence sweep is also what keeps the reads below it from meeting an
    # absent file, so removing it does not merely accept the repository: it
    # crashes on the first read. The row still refuses, and now says why in a
    # stack trace instead of a sentence, which is the regression.
    detects: "refused for the wrong reason"
  },
  {
    label: "the SABnzbd category contract",
    from: 'defaults["downloaders_sabnzbd_categories"] == expected_categories',
    to: "true",
    rows: ["a drifted SABnzbd category destination"]
  },
  {
    label: "the bounded article cache check",
    from: 'defaults["downloaders_sabnzbd_owned_misc"]["cache_limit"] == "256M"',
    to: "true",
    rows: ["an unbounded article cache"]
  },
  {
    label: "the bounded unpack concurrency check",
    from: 'defaults.dig("downloaders_sabnzbd_owned_misc", "direct_unpack_threads") == 1',
    to: "true",
    rows: ["unbounded concurrent unpack work"]
  },
  {
    label: "the strict TLS verification check",
    from: 'defaults.dig("downloaders_sabnzbd_owned_server", "ssl_verify") == 3 &&',
    to: "true &&",
    rows: ["a TLS mode that authenticates nothing"]
  },
  {
    label: "the state guard ordering check",
    from: "guard_index && activation_index && guard_index < activation_index",
    to: "true",
    rows: ["a state guard that never runs before deployment"]
  },
  {
    label: "the project CPU policy check",
    from: 'main.count { |task| task.dig("vars", "container_cpu_service_name") == "downloaders" } == 1',
    to: "true",
    rows: ["a project CPU policy that is never verified"]
  },
  {
    # The whole condition, not the predicate inside the block: with the `when`
    # removed the block never runs and `any?` on an empty array is already
    # false, so a plant inside the block would change nothing.
    label: "the Usenet activation gate",
    from: 'activation && Array(activation["when"]).any? do |condition|
      condition.to_s.include?("media_usenet_enabled | bool")
    end',
    to: "true",
    rows: ["an activation no longer gated on the Usenet switch"]
  },
  {
    label: "the SABnzbd-before-clients ordering check",
    from: "sabnzbd_index && clients_index && sabnzbd_index < clients_index",
    to: "true",
    rows: ["Arr clients reconciled before SABnzbd"]
  },
  {
    label: "the exactly-once CPU set read",
    from: 'env_assignments.select { |name, _value| name == "PLATFORM_CONTAINER_CPUSET" } ==
      [["PLATFORM_CONTAINER_CPUSET", "{{ platform_effective_container_cpuset }}"]]',
    to: 'File.read(File.join(root, "roles/downloaders/templates/env.j2"))
      .include?("PLATFORM_CONTAINER_CPUSET={{ platform_effective_container_cpuset }}")',
    rows: ["a CPU set rendered twice"]
  },
  {
    # Restores the substring search the line-oriented read replaced, which is
    # the form a commented-out sample satisfies while the live line is gone.
    label: "the line-oriented API key read",
    from: "].all? { |assignment| env_assignments.include?(assignment) }",
    to: '].all? { |name, value| File.read(File.join(root, "roles/downloaders/templates/env.j2"))
      .include?("#{name}=#{value}") }',
    rows: ["an API key surviving only in a comment"]
  },
  {
    label: "the per-request redaction floor",
    from: 'secret_tasks.length >= 2 && secret_tasks.all? { |task| task["no_log"] == true }',
    to: "true",
    rows: ["a credential-bearing request that logs its payload"]
  },
  {
    label: "the named provider push check",
    from: "provider_pushes.length == 1",
    to: "true",
    rows: ["a provider push that has fallen out of the credential selector"]
  },
  {
    label: "the password-in-URL refusal",
    from: 'task.dig("ansible.builtin.uri", "url").to_s
          .include?("vault_downloaders_sabnzbd_server_password")',
    to: "false",
    rows: ["a provider password travelling in a URL"]
  },
  {
    label: "the both-provider-states branch check",
    from: 'branch_conditions.sort == [[owned_server_gate], ["not #{owned_server_gate}"]].sort',
    to: "true",
    rows: ["a provider-state branch that is no longer the other's negation"]
  },
  {
    label: "the per-branch server count claim",
    from: 'branch_claims["not #{owned_server_gate}"].to_a.any? { |claim| claim.include?("length == 0") }',
    to: "true",
    rows: ["a provider-state branch that claims no server count"]
  },
  {
    label: "the single-spelling credential guard check",
    from: 'main_provider_gates.length == 1 &&
      Array(main_provider_gates.first["when"]) == [owned_server_gate]',
    to: "true",
    rows: ["a credential guard gated on a second spelling"]
  },
  {
    label: "the single-spelling server reconciliation check",
    from: 'server_block && Array(server_block["when"]) == [owned_server_gate]',
    to: "true",
    rows: ["a server reconciliation gated on a second spelling"]
  },
  {
    label: "the categories-as-mapping refusal",
    from: 'scalars.any? { |value| value.include?("config.categories is mapping") }',
    to: "false",
    rows: ["categories also read as a mapping"]
  },
  {
    label: "the container interface binding check",
    from: 'settings.dig("misc", "host") == "0.0.0.0" && settings.dig("misc", "port") == "8080"',
    to: "true",
    rows: ["a SABnzbd bootstrap bound to loopback only"]
  },
  {
    label: "the invented-provider refusal",
    from: 'settings.key?("servers")',
    to: "false",
    rows: ["a bootstrap that invents a Usenet provider"]
  },
  {
    label: "the whole-line category loop read",
    from: 'template_lines.include?(
      "{% for category, directory in downloaders_sabnzbd_categories.items() %}"
    )',
    to: "true",
    rows: ["a category loop surviving only in a comment"]
  },
  {
    label: "the Unpackerr Usenet protocol check",
    from: 'unpackerr.dig("environment", "UN_SONARR_0_PROTOCOLS") == "usenet"',
    to: "true",
    rows: ["Unpackerr watching a protocol it does not own"]
  },
  {
    label: "the Unpackerr file and directory mode check",
    from: 'unpackerr.dig("environment", "UN_FILE_MODE") == "0644" &&',
    to: "true &&",
    rows: ["drifted Unpackerr file and directory modes"]
  },
  {
    label: "the Unpackerr probe-reaches-its-listener check",
    from: 'unpackerr.dig("environment", "UN_WEBSERVER_METRICS") == "true" &&',
    to: "true &&",
    rows: ["an Unpackerr listener switched off under a probe that needs it"]
  },
  {
    label: "the Unpackerr probe address read",
    from: 'probe.include?("http://#{listen_addr}/")',
    to: "probe.include?(\"http://\")",
    rows: ["an Unpackerr probe aimed past its own listener"]
  }
].freeze

# The wrapper's own regressions. Each one is a line that today changes no
# outcome, which is exactly why it needs a plant rather than a passing contract.
WRAPPER_MUTATIONS = [
  {
    label: "a dropped stdin redirect",
    from: 'ruby "$static_program" "$repo_dir" </dev/null',
    to: 'ruby "$static_program" "$repo_dir"',
    layer: :stdin
  },
  {
    label: "the program resolved from the inspected tree",
    from: "static_program=$contract_repo_dir/tests/contracts/downloaders-static.rb",
    to: "static_program=$repo_dir/tests/contracts/downloaders-static.rb",
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
    from: '[ "$mode" = static ] || {',
    to: '[ "$mode" != nothing ] || {',
    layer: :wrapper
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
  planted = 0

  # Every plant is prepared on the main thread, before the pool. `plant` and
  # `rows_named` abort with a sentence naming what they could not find, and an
  # abort inside a worker raises SystemExit there: the thread dies without
  # recording its result and the pool's own `collected.fetch` then reports a
  # KeyError instead of that sentence. Nine copies of this helper are coming, so
  # the ordering is the fix rather than a rescue.
  program_cases = PROGRAM_MUTATIONS.map do |mutation|
    [mutation,
     plant(File.read(STATIC_PROGRAM), mutation, occurrences: mutation.fetch(:occurrences, 1)),
     rows_named(STATIC_ROWS, mutation.fetch(:rows))]
  end
  wrapper_cases = WRAPPER_MUTATIONS.map { |mutation| [mutation, plant(File.read(CONTRACT), mutation)] }

  in_parallel_cases(mismatches, program_cases) do |(mutation, source, rows), collected|
    Dir.mktmpdir("nas-platform-downloaders-mutant.") do |directory|
      path = File.join(directory, "downloaders-static.rb")
      File.write(path, source)
      caught = static_failures(path, rows)
      detects = mutation.fetch(:detects, "accepted what it must refuse")
      if caught.empty?
        collected << "removing #{mutation.fetch(:label)} was accepted"
      elsif !caught.all? { |failure| failure.include?(detects) }
        collected << "removing #{mutation.fetch(:label)} was caught by the wrong assertion: " \
                     "#{caught.join(' | ')}"
      end
    end
  end
  planted += PROGRAM_MUTATIONS.length

  in_parallel_cases(mismatches, wrapper_cases) do |(mutation, source), collected|
    caught = case mutation.fetch(:layer)
             when :stdin then stdin_failures(wrapper_source: source)
             when :two_roots then two_roots_failures(wrapper_source: source)
             else wrapper_failures(wrapper_source: source)
             end
    collected << "removing #{mutation.fetch(:label)} was accepted" if caught.empty?
  end
  planted += WRAPPER_MUTATIONS.length

  unless mismatches.empty?
    mismatches.each { |mismatch| warn "FAIL self-test: #{mismatch}" }
    abort "#{mismatches.length} self-test mismatch(es) of #{planted} planted regressions"
  end

  puts "downloaders contract: self-test detects #{planted} planted regressions"
  exit
end

failures = static_failures(STATIC_PROGRAM) + wrapper_failures + stdin_failures + two_roots_failures
unless failures.empty?
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} downloaders contract violation(s)"
end

puts "downloaders contract: #{STATIC_ROWS.length} static properties hold, and the wrapper " \
     "reaches its program from its own checkout, against the inspected tree, with an empty stdin"
