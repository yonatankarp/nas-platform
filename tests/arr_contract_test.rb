#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Behaviour of the Arr service contract's Ruby program.
#
# Until #147 the whole program lived in a `<<'RUBY'` heredoc inside
# tests/contracts/arr.sh. `sh -n` reads a quoted heredoc as opaque text, so the
# only thing that ever executed it was `tests/contracts/arr.sh static` -- and a
# contract that passes says nothing about which of its twenty-six assertions
# still bite. tests/contracts/arr-static.rb is a file now, so each one can be
# moved on its own.
#
# Two layers, because the contract has two kinds of property:
#
#   Static -- build a fixture repository from the files the program reads, break
#   exactly one thing in it, and require the program to name that thing. The
#   assertion text is the interface: a guard that fails for the wrong reason has
#   stopped guarding what it names, so every row pins the exact diagnostic.
#
#   Wrapper -- tests/contracts/arr.sh is what turns a mode into an invocation.
#   Its rows prove the mode guard, that the program is actually reached, that the
#   program comes from the checkout while the tree it inspects does not, and that
#   it cannot consume the caller's stdin.
#
# Run with --self-test to plant a regression in the program and in the wrapper
# and prove the rows above detect each one. It accumulates its mismatches rather
# than aborting on the first: at two files and forty-odd plants, learning them
# one at a time is the expensive habit.

require "etc"
require "fileutils"
require "open3"
require "rbconfig"
require "shellwords"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)
CONTRACT = File.join(ROOT, "tests", "contracts", "arr.sh")
STATIC_PROGRAM = File.join(ROOT, "tests", "contracts", "arr-static.rb")

# Exactly what the program reads, plus the shared flatten_tasks it requires
# through PLATFORM_CONTRACT_REPO_DIR. A fixture holding only these is the proof
# that the list the program *declares* is narrower than the list it actually
# needs: `required` names eleven paths, and the program then goes on to read
# five more -- configarr.yml, reconcile_prowlarr_application.yml,
# reconciliation_fingerprints.yml and both acquisition filters. Those five are
# absent from the existence sweep, so removing one of them is a crash rather
# than a diagnostic. Recorded here rather than fixed: this change moves code.
FIXTURE_FILES = %w[
  roles/arr/defaults/main.yml
  roles/arr/tasks/main.yml
  roles/arr/tasks/bootstrap.yml
  roles/arr/tasks/configarr.yml
  roles/arr/tasks/reconcile_servarr.yml
  roles/arr/tasks/reconcile_servarr_download_client.yml
  roles/arr/tasks/reconcile_prowlarr.yml
  roles/arr/tasks/reconcile_prowlarr_application.yml
  roles/arr/tasks/reconcile_prowlarr_download_client.yml
  roles/arr/tasks/reconcile_bazarr.yml
  roles/arr/tasks/reconciliation_fingerprints.yml
  roles/arr/tasks/verify.yml
  roles/arr/templates/env.j2
  roles/arr/templates/config.xml.j2
  roles/arr/templates/bazarr-config.yml.j2
  filter_plugins/acquisition_servarr.py
  filter_plugins/acquisition_bazarr.py
  tests/policy_support.rb
].freeze

SUCCESS_LINE = "arr contract: Phase 1 API ownership holds"
MODE_REFUSAL = "arr contract accepts only static"

# Never more workers than cores. tests/validate-policy.sh already runs its
# checks concurrently, so oversubscribing a four-core CI runner trades wall time
# for contention. Each case owns its own mktmpdir fixture and shares nothing but
# the failure list, and failures are concatenated in row order so the report is
# deterministic.
CASE_WORKER_LIMIT = Integer(ENV.fetch("ARR_CONTRACT_CASE_WORKERS") { [Etc.nprocessors, 8].min.to_s })

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

STATIC_ROWS = [
  {
    name: "an intact repository",
    break: ->(_root) {},
    expects: nil
  },
  {
    name: "a declared file that is gone",
    break: ->(root) { FileUtils.rm(File.join(root, "roles/arr/templates/config.xml.j2")) },
    expects: "missing roles/arr/templates/config.xml.j2"
  },
  {
    name: "a drifted Radarr root folder",
    break: lambda { |root|
      mutate_text(root, "roles/arr/defaults/main.yml", "/data/media/Movies", "/data/media/Films")
    },
    expects: "Radarr root must be exact"
  },
  {
    name: "a drifted Sonarr root folder",
    break: lambda { |root|
      mutate_text(root, "roles/arr/defaults/main.yml", "/data/media/Series", "/data/media/Shows")
    },
    expects: "Sonarr root must be exact"
  },
  {
    name: "automatic monitoring switched on",
    break: lambda { |root|
      mutate_text(root, "roles/arr/defaults/main.yml",
                  "media_arr_automatic_monitoring_enabled: false",
                  "media_arr_automatic_monitoring_enabled: true")
    },
    expects: "automatic monitoring must stay disabled"
  },
  {
    name: "automatic rename switched on",
    break: lambda { |root|
      mutate_text(root, "roles/arr/defaults/main.yml",
                  "media_arr_automatic_rename_enabled: false",
                  "media_arr_automatic_rename_enabled: true")
    },
    expects: "automatic rename must stay disabled"
  },
  {
    name: "a Prowlarr sync level below full",
    break: lambda { |root|
      mutate_text(root, "roles/arr/defaults/main.yml",
                  "arr_prowlarr_application_sync_level: fullSync",
                  "arr_prowlarr_application_sync_level: addOnly")
    },
    expects: "Prowlarr applications must use full sync"
  },
  {
    # A *second* activation rather than none, so this row moves only the
    # exactly-one assertion. Turning both activations into something else would
    # also empty `activation_task` and produce the gate diagnostic below, and a
    # row whose output carries two sentences no longer says which one it pins.
    # The stop task's own `when` still mentions the gate as a substring, so the
    # gate assertion stays satisfied.
    name: "a project activated twice",
    break: lambda { |root|
      mutate_text(root, "roles/arr/tasks/main.yml",
                  "    state: absent\n    remove_orphans: true",
                  "    state: present\n    remove_orphans: true")
    },
    expects: "Arr role must deploy through docker_compose_v2"
  },
  {
    name: "an activation no longer gated on the Usenet switch",
    break: lambda { |root|
      mutate_text(root, "roles/arr/tasks/main.yml",
                  "    wait_timeout: \"{{ arr_compose_wait_timeout }}\"\n" \
                  "  when: media_usenet_enabled | bool\n  register: arr_deploy",
                  "    wait_timeout: \"{{ arr_compose_wait_timeout }}\"\n  register: arr_deploy")
    },
    expects: "Arr role must gate activation on media_usenet_enabled"
  },
  {
    name: "a project CPU policy that is never verified",
    break: lambda { |root|
      mutate_text(root, "roles/arr/tasks/main.yml",
                  "container_cpu_service_name: arr", "container_cpu_service_name: not_arr")
    },
    expects: "Arr role must verify the complete project CPU policy once"
  },
  {
    name: "a Servarr bootstrap that overwrites an operator's config.xml",
    break: lambda { |root|
      mutate_text(root, "roles/arr/tasks/bootstrap.yml",
                  "    src: config.xml.j2\n    dest: \"{{ item.path }}/config.xml\"",
                  "    src: config.xml.j2\n    dest: \"{{ item.path }}/config.xml.new\"")
    },
    expects: "Servarr bootstrap must preserve existing config.xml"
  },
  {
    name: "a Bazarr bootstrap that overwrites an operator's config",
    break: lambda { |root|
      mutate_text(root, "roles/arr/tasks/bootstrap.yml",
                  "    dest: \"{{ arr_bazarr_config_host_path }}/config/config.yaml\"",
                  "    dest: \"{{ arr_bazarr_config_host_path }}/config/config.yml\"")
    },
    expects: "Bazarr bootstrap must preserve existing config"
  },
  {
    name: "a bootstrap API key that is not the vault's",
    break: lambda { |root|
      mutate_text(root, "roles/arr/templates/config.xml.j2",
                  "<ApiKey>{{ arr_bootstrap_api_key }}</ApiKey>",
                  "<ApiKey>{{ lookup('password', '/dev/null length=32') }}</ApiKey>")
    },
    expects: "Servarr bootstrap must use deterministic vault API keys"
  },
  {
    name: "authentication that is not on before first start",
    break: lambda { |root|
      mutate_text(root, "roles/arr/templates/config.xml.j2",
                  "<AuthenticationRequired>Enabled</AuthenticationRequired>",
                  "<AuthenticationRequired>DisabledForLocalAddresses</AuthenticationRequired>")
    },
    expects: "Servarr authentication must be enabled before first start"
  },
  {
    name: "a CPU set rendered twice",
    break: lambda { |root|
      mutate_text(root, "roles/arr/templates/env.j2",
                  "PLATFORM_CONTAINER_CPUSET={{ platform_effective_container_cpuset }}",
                  "PLATFORM_CONTAINER_CPUSET={{ platform_effective_container_cpuset }}\n" \
                  "PLATFORM_CONTAINER_CPUSET=0-3")
    },
    expects: "Arr env must render CPU set exactly once"
  },
  {
    name: "an API key surviving only in a comment",
    break: lambda { |root|
      mutate_text(root, "roles/arr/templates/env.j2",
                  "BAZARR_API_KEY={{ vault_arr_bazarr_api_key }}",
                  "# BAZARR_API_KEY={{ vault_arr_bazarr_api_key }}")
    },
    expects: "Arr env must carry all deterministic API keys"
  },
  {
    name: "a Servarr download category that drifted",
    # The indentation is the anchor: `category: movies` alone also matches
    # `arr_prowlarr_client_category`, which is a different relationship's
    # fallback and is covered by its own row. Two matches make mutate_text
    # refuse rather than plant in whichever came first.
    break: lambda { |root|
      mutate_text(root, "roles/arr/defaults/main.yml",
                  "    category: movies", "    category: films")
    },
    expects: "Servarr reconciliation must own only the SABnzbd clients"
  },
  {
    # Two rows, not one, because this diagnostic covers three clauses and a
    # single break that moved two of them could not say which one was doing the
    # work. Renaming the endpoint moves only the positive clause; the row below
    # adds a /command request and moves only the negative one.
    name: "root folders that are never created",
    break: lambda { |root|
      mutate_text(root, "roles/arr/tasks/reconcile_servarr.yml",
                  '{{ arr_servarr_instance.api }}/rootfolder"',
                  '{{ arr_servarr_instance.api }}/rootfolders"', occurrences: 2)
    },
    expects: "Servarr reconciliation must create root folders without import commands"
  },
  {
    name: "a request to the Servarr command endpoint",
    break: lambda { |root|
      mutate_text(root, "roles/arr/tasks/reconcile_servarr.yml",
                  "---\n- name: Read Servarr host configuration",
                  "---\n- name: Trigger a Servarr command\n  ansible.builtin.uri:\n" \
                  "    url: \"{{ arr_servarr_instance.api }}/command\"\n    method: POST\n" \
                  "    status_code: [201]\n  no_log: true\n\n" \
                  "- name: Read Servarr host configuration")
    },
    expects: "Servarr reconciliation must create root folders without import commands"
  },
  {
    name: "a host reconciliation that replaces rather than merges",
    break: lambda { |root|
      mutate_text(root, "roles/arr/tasks/reconcile_servarr.yml",
                  "{{ arr_servarr_host_before.json | combine({", "{{ ({")
    },
    expects: "Servarr reconciliation must preserve unowned host fields"
  },
  {
    name: "a rename policy moved to the media-management API",
    break: lambda { |root|
      mutate_text(root, "roles/arr/tasks/reconcile_servarr.yml",
                  "config/naming", "config/mediamanagement", occurrences: 2)
    },
    expects: "Servarr rename policy must use the naming configuration API"
  },
  {
    name: "a Prowlarr application that no longer names Sonarr",
    break: lambda { |root|
      %w[
        roles/arr/tasks/reconcile_prowlarr.yml
        roles/arr/tasks/reconcile_prowlarr_application.yml
        roles/arr/defaults/main.yml
      ].each do |relative|
        body = File.read(File.join(root, relative))
        File.write(File.join(root, relative), body.gsub("Sonarr", "Seriearr"))
      end
    },
    expects: "Prowlarr must own Radarr and Sonarr applications"
  },
  {
    # The inverse of the row this replaces. Phase 1 asserted that Prowlarr
    # received no download client; it now must hold one, because without it a
    # manual grab is refused with "Usenet Download client isn't configured yet".
    # Breaking the request is what proves the rule reads the reconciliation
    # rather than the file's existence.
    name: "a Prowlarr download client that is no longer written",
    break: lambda { |root|
      mutate_text(root, "roles/arr/tasks/reconcile_prowlarr_download_client.yml",
                  "{{ arr_prowlarr_api }}/downloadclient",
                  "{{ arr_prowlarr_api }}/indexer", occurrences: 2)
    },
    expects: "Prowlarr must own its SABnzbd download client"
  },
  {
    name: "a Bazarr link to one Arr service only",
    # All four tokens live only in filter_plugins/acquisition_bazarr.py -- the
    # task files spell none of them, which is why the program reads that filter
    # as source text beside the task files it reads as tasks.
    break: lambda { |root|
      mutate_text(root, "filter_plugins/acquisition_bazarr.py",
                  '"settings-general-use_sonarr": "true"',
                  '"settings-general-use_series": "true"')
    },
    expects: "Bazarr must connect to both Arr services"
  },
  {
    name: "a Jellyfin integration left unwritten rather than pinned off",
    break: lambda { |root|
      mutate_text(root, "filter_plugins/acquisition_bazarr.py",
                  '"settings-general-use_jellyfin": "false"',
                  '"settings-general-use_plex": "false"')
    },
    expects: "Bazarr must pin its Jellyfin integration off rather than ignore it"
  },
  {
    name: "a Bazarr path mapping that is no longer identical",
    break: lambda { |root|
      mutate_text(root, "roles/arr/tasks/reconciliation_fingerprints.yml",
                  "path_mappings_movie", "remote_paths_movie")
      mutate_text(root, "filter_plugins/acquisition_bazarr.py",
                  "path_mappings_movie", "remote_paths_movie", occurrences: 5)
    },
    expects: "Bazarr must retain identical paths without remote mappings"
  },
  {
    name: "one reconciliation request that logs its payload",
    break: lambda { |root|
      mutate_text(root, "roles/arr/tasks/reconcile_bazarr.yml",
                  "  no_log: true", "  no_log: false", occurrences: 8)
    },
    expects: "all Arr API reconciliation must redact secret-bearing payloads"
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
    Dir.mktmpdir("nas-platform-arr-static.") do |raw|
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

# --- wrapper layer ---------------------------------------------------------
#
# tests/contracts/arr.sh resolves its program from its own checkout rather than
# from the tree it is inspecting, so a copy of the two files into a throwaway
# tests/contracts/ is a whole working contract. That is what lets a row point
# PLATFORM_CONTRACT_REPO_DIR at a broken fixture and still exercise the real
# wrapper. The copy is laid into a fixture repository so it is also a valid tree
# to inspect, which is what the unset-variable row needs.

def with_contract_copy(static: File.read(STATIC_PROGRAM), wrapper: File.read(CONTRACT))
  Dir.mktmpdir("nas-platform-arr-wrapper.") do |raw|
    root = File.realpath(raw)
    build_fixture_repository(root)
    contracts = File.join(root, "tests", "contracts")
    FileUtils.mkdir_p(contracts)
    wrapper_path = File.join(contracts, "arr.sh")
    File.write(wrapper_path, wrapper)
    File.chmod(0o755, wrapper_path)
    File.write(File.join(contracts, "arr-static.rb"), static)
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
    Dir.mktmpdir("nas-platform-arr-broken.") do |raw|
      broken = File.realpath(raw)
      build_fixture_repository(broken)
      FileUtils.rm(File.join(broken, "roles/arr/templates/config.xml.j2"))
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => broken }, contract, "static"
      )
      failures << "wrapper: static mode passed against a broken repository" if status.success?
      failures << "wrapper: static mode did not report the broken repository" unless
        (stdout + stderr).include?("missing roles/arr/templates/config.xml.j2")
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
    FileUtils.rm(File.join(copy_root, "roles/arr/templates/config.xml.j2"))
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => nil }, contract, "static"
    )
    failures << "wrapper: with no repository named, static mode inspected some other tree" if
      status.success?
    failures << "wrapper: with no repository named, static mode did not report the broken tree" unless
      (stdout + stderr).include?("missing roles/arr/templates/config.xml.j2")
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
    Dir.mktmpdir("nas-platform-arr-tworoots.") do |raw|
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
    Dir.mktmpdir("nas-platform-arr-support.") do |raw|
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
    # crashes on the first YAML load. The row still refuses, and now says why in
    # a stack trace instead of a sentence, which is the regression.
    detects: "refused for the wrong reason"
  },
  {
    label: "the Radarr root folder check",
    from: 'defaults["arr_radarr_root_folder"] == "/data/media/Movies"',
    to: "true",
    rows: ["a drifted Radarr root folder"]
  },
  {
    label: "the Sonarr root folder check",
    from: 'defaults["arr_sonarr_root_folder"] == "/data/media/Series"',
    to: "true",
    rows: ["a drifted Sonarr root folder"]
  },
  {
    label: "the automatic monitoring check",
    from: 'defaults["media_arr_automatic_monitoring_enabled"] == false',
    to: "true",
    rows: ["automatic monitoring switched on"]
  },
  {
    label: "the automatic rename check",
    from: 'defaults["media_arr_automatic_rename_enabled"] == false',
    to: "true",
    rows: ["automatic rename switched on"]
  },
  {
    label: "the Prowlarr sync level check",
    from: 'defaults["arr_prowlarr_application_sync_level"] == "fullSync"',
    to: "true",
    rows: ["a Prowlarr sync level below full"]
  },
  {
    label: "the docker_compose_v2 deployment check",
    from: "compose_activations.length == 1",
    to: "true",
    rows: ["a project activated twice"]
  },
  {
    # The whole condition, not the predicate inside the block: with the `when`
    # removed the block never runs, `any?` on an empty array is already false,
    # and a plant inside the block changes nothing. Measured, not reasoned --
    # the self-test reported this one as "was accepted" first time round.
    label: "the Usenet activation gate",
    from: 'activation_task && Array(activation_task["when"]).any? do |condition|
      condition.to_s.include?("media_usenet_enabled | bool")
    end',
    to: "true",
    rows: ["an activation no longer gated on the Usenet switch"]
  },
  {
    label: "the project CPU policy check",
    from: 'main_tasks.count { |task| task.dig("vars", "container_cpu_service_name") == "arr" } == 1',
    to: "true",
    rows: ["a project CPU policy that is never verified"]
  },
  {
    label: "the Servarr config.xml preservation check",
    from: 'servarr_seed && servarr_seed.dig("ansible.builtin.template", "force") == false &&',
    to: "true ||",
    rows: ["a Servarr bootstrap that overwrites an operator's config.xml"]
  },
  {
    label: "the Bazarr config preservation check",
    from: 'bazarr_seed && bazarr_seed.dig("ansible.builtin.template", "force") == false &&',
    to: "true ||",
    rows: ["a Bazarr bootstrap that overwrites an operator's config"]
  },
  {
    label: "the deterministic bootstrap API key check",
    from: 'config_elements["ApiKey"] == "{{ arr_bootstrap_api_key }}"',
    to: "true",
    rows: ["a bootstrap API key that is not the vault's"]
  },
  {
    label: "the pre-start authentication check",
    from: 'config_elements["AuthenticationRequired"] == "Enabled"',
    to: "true",
    rows: ["authentication that is not on before first start"]
  },
  {
    # Restores the substring search the line-oriented read replaced, which is
    # the form a second live assignment satisfies while only one may exist.
    label: "the exactly-once CPU set read",
    from: 'env_assignments.select { |name, _value| name == "PLATFORM_CONTAINER_CPUSET" } ==
      [["PLATFORM_CONTAINER_CPUSET", "{{ platform_effective_container_cpuset }}"]]',
    to: 'File.read(File.join(root, "roles/arr/templates/env.j2"))
      .include?("PLATFORM_CONTAINER_CPUSET={{ platform_effective_container_cpuset }}")',
    rows: ["a CPU set rendered twice"]
  },
  {
    # And the form a commented-out sample satisfies while the live line is gone.
    label: "the line-oriented API key read",
    from: 'env_assignments.include?(["#{name.upcase}_API_KEY", "{{ vault_arr_#{name}_api_key }}"])',
    to: 'File.read(File.join(root, "roles/arr/templates/env.j2"))
        .include?("#{name.upcase}_API_KEY={{ vault_arr_#{name}_api_key }}")',
    rows: ["an API key surviving only in a comment"]
  },
  {
    label: "the SABnzbd category ownership check",
    from: 'servarr_categories["radarr"] == "movies" &&',
    to: "true &&",
    rows: ["a Servarr download category that drifted"]
  },
  {
    label: "the root-folder endpoint check",
    from: 'servarr_urls.any? { |url| url.end_with?("/rootfolder") } &&',
    to: "true &&",
    rows: ["root folders that are never created"]
  },
  {
    label: "the import-command refusal",
    from: 'servarr_urls.none? { |url| url.match?(%r{/command(/|\z)}i) } &&',
    to: "true &&",
    rows: ["a request to the Servarr command endpoint"]
  },
  {
    label: "the unowned host field merge check",
    from: 'host_reconciliation.dig("ansible.builtin.uri", "body").to_s.include?("combine(")',
    to: "true",
    rows: ["a host reconciliation that replaces rather than merges"]
  },
  {
    label: "the naming API check",
    from: 'naming_scalars.none? { |value| value.include?("config/mediamanagement") }',
    to: "true",
    rows: ["a rename policy moved to the media-management API"]
  },
  {
    label: "the Prowlarr application ownership check",
    from: "prowlarr_scalars.any? { |value| value.include?(token) }",
    to: "true",
    rows: ["a Prowlarr application that no longer names Sonarr"]
  },
  {
    label: "the Prowlarr download client ownership check",
    from: 'prowlarr_client_scalars.any? { |value| value.include?("/downloadclient") } &&',
    to: "true &&",
    rows: ["a Prowlarr download client that is no longer written"]
  },
  {
    label: "the Bazarr dual-Arr link check",
    from: "bazarr_scalars.any? { |value| value.include?(token) }",
    to: "true",
    rows: ["a Bazarr link to one Arr service only"]
  },
  {
    label: "the pinned-off Jellyfin integration check",
    from: 'value.include?(%("settings-general-use_jellyfin": "false"))',
    to: "true",
    rows: ["a Jellyfin integration left unwritten rather than pinned off"]
  },
  {
    label: "the identical path mapping check",
    from: 'bazarr_scalars.any? { |value| value.include?("path_mappings_movie") }',
    to: "true",
    rows: ["a Bazarr path mapping that is no longer identical"]
  },
  {
    label: "the per-request redaction check",
    from: '!requests.empty? && requests.all? { |task| task["no_log"] == true }',
    to: "true",
    rows: ["one reconciliation request that logs its payload"]
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
    from: "static_program=$contract_repo_dir/tests/contracts/arr-static.rb",
    to: "static_program=$repo_dir/tests/contracts/arr-static.rb",
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
    Dir.mktmpdir("nas-platform-arr-mutant.") do |directory|
      path = File.join(directory, "arr-static.rb")
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

  puts "arr contract: self-test detects #{planted} planted regressions"
  exit
end

failures = static_failures(STATIC_PROGRAM) + wrapper_failures + stdin_failures + two_roots_failures
unless failures.empty?
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} Arr contract violation(s)"
end

puts "arr contract: #{STATIC_ROWS.length} static properties hold, and the wrapper reaches its " \
     "program from its own checkout, against the inspected tree, with an empty stdin"
