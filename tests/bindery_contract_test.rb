#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Behaviour of the Bindery service contract's two Ruby programs.
#
# Until #147 both lived in `<<'RUBY'` heredocs inside tests/contracts/bindery.sh.
# `sh -n` reads a quoted heredoc as opaque text, so the static half was only ever
# executed by `tests/contracts/bindery.sh static` and the runtime half only by an
# integration lane with Docker, a converged Bindery and a real vault.
# tests/contracts/bindery-static.rb and tests/contracts/bindery-runtime.rb are
# files now, so both are reachable here.
#
# Three layers, because the contract has three kinds of property:
#
#   Static -- build a fixture repository from the files the program reads, break
#   exactly one thing in it, and require the program to name that thing. The
#   assertion text is the interface: a guard that fails for the wrong reason has
#   stopped guarding what it names, so every row pins the exact diagnostic.
#
#   Runtime -- serve the Bindery API from an HTTP fixture and put `docker` and
#   `ansible-vault` stubs on PATH, so each access, ownership, storage and
#   persistence outcome can be moved one at a time. This half had no test at all,
#   and 195 lines of it are exactly what a deployment depends on. Both states of
#   PLATFORM_BINDERY_USENET are covered: the `if USENET` block is twenty
#   assertions that no local signal reaches with the flag left at its default.
#
#   Wrapper -- tests/contracts/bindery.sh is what turns a mode into an
#   invocation. Its rows prove the mode guard, the run-mode environment contract,
#   that both programs are reached, that they come from the checkout while the
#   tree the static half inspects does not, and that neither can eat the caller's
#   stdin.
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
require_relative "policy_support"

include TestScaffold

ROOT = File.expand_path("..", __dir__)
# The prefix every refusal this file judges has to carry. Matching the
# fragment alone accepted a backtrace or an echoed argument as a refusal.
DIAGNOSTIC_PREFIX = "Bindery contract failed: "
CONTRACT = File.join(ROOT, "tests", "contracts", "bindery.sh")
STATIC_PROGRAM = File.join(ROOT, "tests", "contracts", "bindery-static.rb")
RUNTIME_PROGRAM = File.join(ROOT, "tests", "contracts", "bindery-runtime.rb")

SUCCESS_LINE = "bindery static contract: two-library acquisition ownership holds"
MODE_REFUSAL = "bindery contract accepts only static or run"

# Exactly what the static program reads, and it is exactly the program's own
# `required` list -- unlike tranche 1's pair it reads no file its existence
# sweep does not check, which the "an intact repository" row proves by passing
# against a fixture holding only these. tests/policy_support.rb is deliberately
# absent: bindery-static.rb carries its own flatten_tasks, which is why
# tests/contracts/bindery.sh exports no PLATFORM_CONTRACT_REPO_DIR.
FIXTURE_FILES = %w[
  roles/bindery/defaults/main.yml
  roles/bindery/meta/argument_specs.yml
  roles/bindery/tasks/main.yml
  roles/bindery/tasks/pre_upgrade_backup.yml
  roles/bindery/tasks/reconcile_usenet.yml
  roles/bindery/tasks/resolve_api_key.yml
  roles/bindery/templates/env.j2
  services/bindery/compose.yml
  services/bindery/compose.mac.yml
  services/bindery/compose.integration.yml
].freeze

# Never more workers than cores. tests/validate-policy.sh already runs its checks
# concurrently, so oversubscribing a four-core CI runner trades wall time for
# contention. Each case owns its own mktmpdir fixture and shares nothing but the
# failure list, and failures are concatenated in row order so the report is
# deterministic.
CASE_WORKER_LIMIT = Integer(
  ENV.fetch("BINDERY_CONTRACT_CASE_WORKERS") { [Etc.nprocessors, 8].min.to_s }
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

# Every substitution states how many matches it expects. A replacement that still
# contains its own pattern plants nothing, and a bare `sub` cannot tell that from
# a plant that worked: the row then reports a pass, or a failure with the wrong
# diagnostic.
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

def compose_service(root)
  edit_yaml(root, "services/bindery/compose.yml") { |d| yield d.fetch("services").fetch("bindery"), d }
end

def role_tasks(root, relative = "roles/bindery/tasks/main.yml")
  edit_yaml(root, relative) { |document| yield document }
end

# The flattened task list the program itself computes, so a row can find the task
# it means to break the same way the assertion finds it.
def find_task(document, &predicate)
  flatten = lambda do |tasks|
    Array(tasks).flat_map do |task|
      next [] unless task.is_a?(Hash)

      [task] + flatten.call(task["block"]) + flatten.call(task["rescue"]) + flatten.call(task["always"])
    end
  end
  flatten.call(document).find(&predicate)
end

STATIC_ROWS = [
  { name: "an intact repository", break: ->(_root) {}, expects: nil },
  {
    name: "a declared file that is gone",
    break: ->(root) { FileUtils.rm(File.join(root, "services/bindery/compose.mac.yml")) },
    expects: "missing services/bindery/compose.mac.yml"
  },
  {
    name: "a seat off the shared control network",
    break: ->(root) { compose_service(root) { |service, _| service.delete("networks") } },
    expects: "Bindery must join the shared media control network"
  },
  {
    name: "a control network the platform declares itself",
    break: lambda { |root|
      compose_service(root) do |_service, document|
        document["networks"]["media-control"] = { "driver" => "bridge" }
      end
    },
    expects: "the shared media control network must be the external one"
  },
  {
    name: "a container that is not the platform identity",
    break: ->(root) { compose_service(root) { |service, _| service["user"] = "1000:1000" } },
    expects: "Bindery must take the platform identity as the container user"
  },
  {
    name: "a boot-time identity assertion that disagrees with the container user",
    break: lambda { |root|
      compose_service(root) { |service, _| service["environment"]["BINDERY_PUID"] = "1000" }
    },
    expects: "Bindery must assert the platform identity as BINDERY_PUID"
  },
  {
    # One mount per leaf rather than per host share. rename(2) refuses to cross a
    # mount boundary even when both sides are one filesystem, so this is the
    # break that makes every import a byte copy while every other reading of the
    # four paths stays identical.
    name: "one bind mount per library leaf instead of per host share",
    break: lambda { |root|
      compose_service(root) do |service, _|
        service["volumes"] = [
          "${BINDERY_CONFIG_PATH:?}:/config",
          "${BINDERY_BOOKS_PATH:?}/Ebooks:/data/books/Ebooks",
          "${BINDERY_MEDIA_PATH:?}/Audiobooks:/data/media/Audiobooks"
        ]
      end
    },
    expects: "Bindery must mount its database and each library's whole host share"
  },
  {
    # Omitting either audiobook variable silently falls back to its ebook
    # equivalent and collapses the two libraries into one.
    name: "an audiobook staging root collapsed onto the ebook one",
    break: lambda { |root|
      compose_service(root) do |service, _|
        service["environment"]["BINDERY_AUDIOBOOK_DOWNLOAD_DIR"] =
          "/data/books/.acquisition/usenet/ebooks"
      end
    },
    expects: "Bindery must keep BINDERY_AUDIOBOOK_DOWNLOAD_DIR separate from its ebook equivalent"
  },
  {
    name: "telemetry left enabled in the environment",
    break: lambda { |root|
      compose_service(root) { |service, _| service["environment"]["BINDERY_TELEMETRY_DISABLED"] = "false" }
    },
    expects: "Bindery must disable telemetry in the environment"
  },
  {
    # An over-broad trusted-proxy entry disables the per-IP login rate limiter.
    name: "a trusted proxy entry that disables the login rate limiter",
    break: lambda { |root|
      compose_service(root) { |service, _| service["environment"]["BINDERY_TRUSTED_PROXY"] = "0.0.0.0/0" }
    },
    expects: "Bindery must leave BINDERY_TRUSTED_PROXY unset"
  },
  {
    name: "a web UI port the platform does not publish",
    break: ->(root) { compose_service(root) { |service, _| service["ports"] = ["18787:8787"] } },
    expects: "Bindery must publish the acquisition web UI port"
  },
  {
    name: "a Mac override republishing a port the harness does not choose",
    break: lambda { |root|
      edit_yaml(root, "services/bindery/compose.mac.yml") do |document|
        document["services"]["bindery"]["ports"] = ["8787:8787"]
      end
    },
    expects: "the Mac override must republish the web UI on the harness port"
  },
  {
    # /bin, /sbin, /usr/bin and /usr/sbin all exist in the image and are all
    # empty; the only executable is /bindery, so a CMD-SHELL probe cannot run at
    # all and the failure surfaces as a deployment timeout saying nothing.
    name: "a shell-form health probe the distroless image cannot run",
    break: lambda { |root|
      compose_service(root) do |service, _|
        service["healthcheck"]["test"] = ["CMD-SHELL", "curl -fsS http://127.0.0.1:8787/api/v1/health"]
      end
    },
    expects: "the Bindery health probe must be the binary's own exec-form subcommand"
  },
  {
    name: "a config root declared somewhere other than the docker root",
    break: lambda { |root|
      edit_yaml(root, "roles/bindery/defaults/main.yml") do |document|
        document["bindery_config_host_path"] = "{{ nas_media_root }}/Books/.bindery"
      end
    },
    expects: "Bindery must declare bindery_config_host_path as {{ nas_docker_root }}/bindery/config"
  },
  {
    name: "one destination root instead of two",
    break: lambda { |root|
      edit_yaml(root, "roles/bindery/defaults/main.yml") do |document|
        document["bindery_library_roots"] = ["{{ bindery_ebooks_root }}"]
      end
    },
    expects: "Bindery must declare exactly the two destination roots"
  },
  {
    # The auto-grab kill switch fails open: a missing row, a read error and an
    # unattached repository all read as enabled, so silence means grabbing.
    name: "an auto-grab kill switch left unpinned",
    break: lambda { |root|
      edit_yaml(root, "roles/bindery/defaults/main.yml") do |document|
        document["bindery_pinned_settings"].delete("autoGrab.enabled")
      end
    },
    expects: "Bindery must pin the auto-grab kill switch and telemetry off"
  },
  {
    name: "Prowlarr addressed by address rather than by control-network alias",
    break: lambda { |root|
      edit_yaml(root, "roles/bindery/defaults/main.yml") do |document|
        document["bindery_prowlarr_internal_url"] = "http://10.0.0.5:9696"
      end
    },
    expects: "Bindery must address Prowlarr and SABnzbd by their control-network alias"
  },
  {
    name: "collapsed ebook and audiobook download categories",
    break: lambda { |root|
      edit_yaml(root, "roles/bindery/defaults/main.yml") do |document|
        document["bindery_sabnzbd_audiobook_category"] = "ebooks"
      end
    },
    expects: "Bindery must keep the ebook and audiobook download categories distinct"
  },
  {
    name: "the Usenet transport enabled by default",
    break: lambda { |root|
      edit_yaml(root, "roles/bindery/defaults/main.yml") { |document| document["media_usenet_enabled"] = true }
    },
    expects: "Bindery must leave the Usenet integrations disabled by default"
  },
  {
    # Restores the substring search the line-oriented read replaced, which is the
    # form a second live assignment satisfies while only one may exist.
    name: "a CPU set rendered twice",
    break: lambda { |root|
      mutate_text(root, "roles/bindery/templates/env.j2",
                  "PLATFORM_CONTAINER_CPUSET={{ platform_effective_container_cpuset }}",
                  "PLATFORM_CONTAINER_CPUSET={{ platform_effective_container_cpuset }}\n" \
                  "PLATFORM_CONTAINER_CPUSET=0-3")
    },
    expects: "Bindery env must render the CPU set exactly once"
  },
  {
    name: "a second vault credential copied into the environment",
    break: lambda { |root|
      mutate_text(root, "roles/bindery/templates/env.j2",
                  "BINDERY_API_KEY={{ vault_bindery_api_key }}",
                  "BINDERY_API_KEY={{ vault_bindery_api_key }}\n" \
                  "BINDERY_ADMIN_PASSWORD={{ vault_bindery_admin_password }}")
    },
    expects: "the Bindery environment must carry exactly the API-key seed"
  },
  {
    name: "a deployment that is not docker_compose_v2",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) { |candidate| candidate.key?("community.docker.docker_compose_v2") }
        task["community.docker.docker_compose_v2"]["state"] = "absent"
      end
    },
    expects: "Bindery must deploy through docker_compose_v2"
  },
  {
    name: "a CPU policy check naming another service",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          candidate.dig("vars", "container_cpu_service_name") == "bindery"
        end
        task["vars"]["container_cpu_service_name"] = "kapowarr"
      end
    },
    expects: "Bindery must verify its effective project CPU policy"
  },
  {
    # Bindery applies its schema migrations on startup, so by the time the new
    # image answers the old schema is already gone.
    name: "a pre-upgrade state guard that runs after the deployment",
    break: lambda { |root|
      role_tasks(root) do |document|
        guard = document.find { |task| task["ansible.builtin.include_tasks"] == "pre_upgrade_backup.yml" }
        document.delete(guard)
        document.push(guard)
      end
    },
    expects: "the Bindery pre-upgrade state guard must run before the deployment"
  },
  {
    # POST /backup is VACUUM INTO: the database runs in WAL mode, so a plain file
    # copy silently omits what is still in the WAL, and a request that tolerates
    # anything but 201 lets the play proceed with no backup.
    name: "a pre-upgrade backup that tolerates a failed VACUUM INTO",
    break: lambda { |root|
      role_tasks(root, "roles/bindery/tasks/pre_upgrade_backup.yml") do |document|
        task = find_task(document) do |candidate|
          candidate.dig("ansible.builtin.uri", "url").to_s.end_with?("/backup")
        end
        task["ansible.builtin.uri"]["status_code"] = [200, 201, 202]
      end
    },
    expects: "the Bindery pre-upgrade backup must accept only a created backup"
  },
  {
    name: "a pre-upgrade backup taken on every converge",
    break: lambda { |root|
      role_tasks(root, "roles/bindery/tasks/pre_upgrade_backup.yml") do |document|
        task = find_task(document) do |candidate|
          candidate.dig("ansible.builtin.uri", "url").to_s.end_with?("/backup")
        end
        task["when"] = ["true"]
      end
    },
    expects: "the Bindery pre-upgrade backup must be gated on an actual image change"
  },
  {
    # Nothing in Bindery is create-if-absent: a duplicate user is a 500.
    name: "an administrator write that is not read-then-decide",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          candidate.dig("ansible.builtin.uri", "url") == "{{ bindery_api }}/auth/users" &&
            candidate.dig("ansible.builtin.uri", "method") == "POST"
        end
        task["when"] = ["not ansible_check_mode"]
      end
    },
    expects: "the Bindery administrator write must be gated on the deployed users"
  },
  {
    name: "an administrator declared as a plain user",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          candidate.dig("ansible.builtin.uri", "url") == "{{ bindery_api }}/auth/users" &&
            candidate.dig("ansible.builtin.uri", "method") == "POST"
        end
        task["ansible.builtin.uri"]["body"]["role"] = "user"
      end
    },
    expects: "the Bindery administrator must be declared as an administrator"
  },
  {
    name: "destination roots created rather than reconciled",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          candidate.dig("ansible.builtin.uri", "url") == "{{ bindery_api }}/rootfolder" &&
            candidate.dig("ansible.builtin.uri", "method") == "POST"
        end
        task["loop"] = "{{ bindery_library_roots }}"
      end
    },
    expects: "the Bindery destination roots must be created only where missing"
  },
  {
    name: "Usenet reconciliation reached on a host with no transport",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          candidate["ansible.builtin.include_tasks"] == "reconcile_usenet.yml"
        end
        task["when"] = ["not ansible_check_mode"]
      end
    },
    expects: "the Bindery Usenet integrations must be gated on the transport flag"
  },
  {
    # A repeated create answers 201 and adds a second row rather than failing.
    name: "a Prowlarr row created unconditionally",
    break: lambda { |root|
      role_tasks(root, "roles/bindery/tasks/reconcile_usenet.yml") do |document|
        task = find_task(document) do |candidate|
          candidate.dig("ansible.builtin.uri", "url") == "{{ bindery_api }}/prowlarr" &&
            candidate.dig("ansible.builtin.uri", "method") == "POST"
        end
        task["when"] = ["not ansible_check_mode"]
      end
    },
    expects: "the Bindery prowlarr row must be created only when absent"
  },
  {
    name: "a download client duplicated rather than repaired",
    break: lambda { |root|
      role_tasks(root, "roles/bindery/tasks/reconcile_usenet.yml") do |document|
        task = find_task(document) do |candidate|
          candidate.dig("ansible.builtin.uri", "method") == "PUT" &&
            candidate.dig("ansible.builtin.uri", "url").to_s.include?("/downloadclient/")
        end
        task["when"] = ["not ansible_check_mode"]
      end
    },
    expects: "the Bindery downloadclient row must be repaired rather than duplicated"
  },
  {
    name: "an ambiguous Prowlarr match accepted rather than refused",
    break: lambda { |root|
      mutate_text(root, "roles/bindery/tasks/reconcile_usenet.yml",
                  "bindery_prowlarr_matches | length <= 1",
                  "bindery_prowlarr_matches is defined")
    },
    expects: "Bindery must refuse an ambiguous prowlarr match"
  },
  {
    # The login limiter records five failures per fifteen minutes per IP and then
    # answers 429 to the correct password too, so a deliberately wrong password
    # anywhere in this role locks the platform out of its own service.
    name: "a probe submitting a password the platform expects to be refused",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          candidate.dig("ansible.builtin.uri", "url") == "{{ bindery_api }}/auth/login"
        end
        document.push("name" => "Probe a deliberately wrong Bindery password",
                      "ansible.builtin.uri" => {
                        "url" => task.dig("ansible.builtin.uri", "url"),
                        "method" => "POST",
                        "body" => { "username" => "nasadmin", "password" => "deliberately-wrong" }
                      })
      end
    },
    expects: "no Bindery request may submit a password the platform expects to be wrong"
  },
  {
    name: "a credential-bearing request rendered in full",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          candidate.dig("ansible.builtin.uri", "url") == "{{ bindery_api }}/auth/users" &&
            candidate.dig("ansible.builtin.uri", "method") == "POST"
        end
        task.delete("no_log")
      end
    },
    expects: "every Bindery request naming a credential must use no_log"
  },
  {
    name: "a credential shape guard that prints the values it compares",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          candidate.key?("ansible.builtin.assert") && candidate.to_s.include?("vault_bindery_api_key")
        end
        task.delete("no_log")
      end
    },
    expects: "the Bindery credential shape guard must use no_log"
  },
  {
    # The recoverability guard measures only the resolved key's length, and its
    # whole purpose is the diagnostic it prints when Bindery is holding an
    # identity this platform did not author.
    name: "a recoverability guard redacted away",
    break: lambda { |root|
      role_tasks(root, "roles/bindery/tasks/resolve_api_key.yml") do |document|
        task = find_task(document) do |candidate|
          candidate.key?("ansible.builtin.assert") && candidate.to_s.include?("bindery_api_key | length")
        end
        task["no_log"] = true
      end
    },
    expects: "the Bindery recoverability guard must stay readable"
  },
  {
    name: "a world-readable environment render",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) { |candidate| candidate.dig("ansible.builtin.template", "src") == "env.j2" }
        task["ansible.builtin.template"]["mode"] = "0644"
      end
    },
    expects: "the Bindery environment render must be private"
  },
  {
    name: "verification that never reads the configured storage",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          Array(candidate["tags"]).include?("platform_verify_bindery") &&
            candidate.dig("ansible.builtin.uri", "url").to_s.include?("/system/storage")
        end
        task["ansible.builtin.uri"]["url"] = "{{ bindery_api }}/health"
      end
    },
    expects: "Bindery verification must read /system/storage"
  },
  {
    # The refusal probe is a credential-free read of a protected route, never a
    # deliberately wrong password.
    name: "an anonymous refusal probe that carries a credential after all",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          Array(candidate["tags"]).include?("platform_verify_bindery") &&
            candidate.dig("ansible.builtin.uri", "url") == "{{ bindery_api }}/rootfolder" &&
            !candidate.fetch("ansible.builtin.uri").key?("headers")
        end
        task["ansible.builtin.uri"]["headers"] = { "X-Api-Key" => "{{ bindery_api_key }}" }
      end
    },
    expects: "Bindery verification must probe a protected route with no credential"
  },
  {
    name: "an anonymous refusal probe redacted away",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          Array(candidate["tags"]).include?("platform_verify_bindery") &&
            candidate.dig("ansible.builtin.uri", "url") == "{{ bindery_api }}/rootfolder" &&
            !candidate.fetch("ansible.builtin.uri").key?("headers")
        end
        task["no_log"] = true
      end
    },
    expects: "the Bindery anonymous refusal probe must stay readable"
  },
  {
    # Five failures per fifteen minutes per IP, so a second login attempt in the
    # verification path is a fifth of the platform's own budget.
    name: "verification spending a second login attempt",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          Array(candidate["tags"]).include?("platform_verify_bindery") &&
            candidate.dig("ansible.builtin.uri", "url") == "{{ bindery_api }}/auth/login"
        end
        document.push(task.dup)
      end
    },
    expects: "Bindery verification must spend exactly one login attempt"
  },
  {
    name: "a probe that pins a status instead of deferring to the assertion",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          Array(candidate["tags"]).include?("platform_verify_bindery") &&
            candidate["failed_when"] == false &&
            candidate.dig("ansible.builtin.uri", "url") == "{{ bindery_api }}/rootfolder" &&
            !candidate.fetch("ansible.builtin.uri").key?("headers")
        end
        task["ansible.builtin.uri"]["status_code"] = [401]
      end
    },
    expects: "must accept any status and defer to the assertion"
  },
  {
    # The service's own EXDEV probe, and the only reading that tells one bind
    # mount per host share from one per directory.
    # The break renames the fact to `hard_linkable` rather than to
    # `hardlinkable_probe`: the contract's condition test is `include?`, so a
    # superstring still satisfies it and a plant that appends plants nothing.
    # That is #293's substring class, met in a break rather than in a guard.
    name: "an outcome assertion that stops asserting the hardlinkable layout",
    break: lambda { |root|
      mutate_text(root, "roles/bindery/tasks/main.yml", "hardlinkable", "hard_linkable",
                  occurrences: 1)
    },
    expects: "Bindery verification must assert the hardlinkable staging layout"
  },
  {
    name: "an outcome assertion redacted away",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          Array(candidate["tags"]).include?("platform_verify_bindery") &&
            candidate.key?("ansible.builtin.assert")
        end
        task["no_log"] = true
      end
    },
    expects: "the Bindery outcome assertion must stay readable"
  },
  {
    name: "a verification read that claims a change",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          Array(candidate["tags"]).include?("platform_verify_bindery") &&
            candidate.key?("ansible.builtin.uri")
        end
        task.delete("changed_when")
      end
    },
    expects: "Bindery verification reads must not claim a change"
  }
].freeze

def static_failures(program, rows = STATIC_ROWS)
  failures = []
  in_parallel_cases(failures, rows) do |row, collected|
    Dir.mktmpdir("nas-platform-bindery-static.") do |raw|
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
# The runtime half takes NO arguments and reads no repository file: every input
# arrives in the environment. So the sandbox is entirely environment plus PATH
# stubs plus one HTTP fixture, and each row moves exactly one of them.

ADMIN = "nasadmin"
PASSWORD = "bindery-contract-admin-password"
API_KEY = "b" * 32
SESSION = "bindery_session=contract-session-token"
EBOOKS_ROOT = "/data/books/Ebooks"
AUDIOBOOKS_ROOT = "/data/media/Audiobooks"
STORAGE_DIRS = {
  "library" => EBOOKS_ROOT,
  "audiobook" => AUDIOBOOKS_ROOT,
  "download" => "/data/books/.acquisition/usenet/ebooks",
  "audiobook-download" => "/data/media/.acquisition/usenet/audiobooks"
}.freeze

RUNTIME_DEFAULTS = {
  health_body: '{"status":"ok"}',
  inspect_ok: true,
  health: "healthy",
  setup_code: 409,
  auth_mode: "enabled",
  setup_required: false,
  anonymous_root_code: 401,
  opds_code: 401,
  vault_ok: true,
  login_code: 200,
  cookie: true,
  config_api_key: API_KEY,
  users: nil,
  roots_code: 200,
  root_paths: [EBOOKS_ROOT, AUDIOBOOKS_ROOT],
  missing_dir: nil,
  unwritable_dir: nil,
  hardlinkable: true,
  hardlink_reason: "cross-device link at /data/books/Ebooks",
  settings: { "autoGrab.enabled" => "false", "telemetry.enabled" => "false" },
  usenet: false,
  prowlarr_rows: nil,
  client_rows: nil,
  database: true
}.freeze

def vault_document
  {
    "vault_bindery_admin_username" => ADMIN,
    "vault_bindery_admin_password" => PASSWORD,
    "vault_bindery_api_key" => API_KEY
  }
end

def prowlarr_row
  { "url" => "http://prowlarr:9696", "apiKeyConfigured" => true, "enabled" => true }
end

def client_row
  { "type" => "sabnzbd", "host" => "sabnzbd", "port" => 8080, "apiKeyConfigured" => true,
    "category" => "ebooks", "categoryAudiobook" => "audiobooks", "enabled" => true }
end

def build_runtime_sandbox(root, options)
  bin = File.join(root, "bin")
  FileUtils.mkdir_p(bin)
  docker_root = File.join(root, "docker")
  database = File.join(docker_root, "bindery", "config", "bindery.db")
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
    #{YAML.dump(vault_document).lines.join.chomp}
    YAML
  SH
  %w[docker ansible-vault].each { |name| File.chmod(0o755, File.join(bin, name)) }
  File.write(File.join(root, "vault.yml"), "encrypted\n")
  File.write(File.join(root, "vault-password"), "fixture\n")
  [bin, docker_root]
end

# HttpFixtureSupport writes its third answer element straight into the
# Content-Type header line, so a response that must also carry Set-Cookie --
# Bindery's login is the only one in this contract -- states both headers there.
# That is a deliberate use of the seam rather than a second copy of the fixture
# server: the alternative is the thirty-five lines of TCPServer the helper exists
# to prevent.
def with_headers(*headers)
  headers.join("\r\n")
end

def storage_document(options)
  dirs = STORAGE_DIRS.filter_map do |name, path|
    next if options.fetch(:missing_dir) == name

    { "name" => name, "path" => path, "exists" => true,
      "writable" => options.fetch(:unwritable_dir) != name }
  end
  document = { "dirs" => dirs, "hardlinkable" => options.fetch(:hardlinkable) }
  # The key is OMITTED rather than set to nil when there is no reason: the
  # program reads it with `fetch(..., "no reason reported")`, and a present-but-
  # null key returns nil, which is a different outcome from an absent one.
  reason = options.fetch(:hardlink_reason)
  document["hardlinkReason"] = reason if !options.fetch(:hardlinkable) && reason
  document
end

def runtime_responder(options)
  lambda do |method, target, headers, _body|
    key = headers["x-api-key"]
    cookie = headers["cookie"]
    path = target.split("?").first
    case [method, path]
    when %w[GET /api/v1/health] then [200, options.fetch(:health_body)]
    when %w[POST /api/v1/auth/setup] then [options.fetch(:setup_code), '{"error":"conflict"}']
    when %w[GET /api/v1/auth/status]
      [200, JSON.generate("mode" => options.fetch(:auth_mode),
                          "setupRequired" => options.fetch(:setup_required))]
    when %w[GET /opds/] then [options.fetch(:opds_code), "{}"]
    when %w[POST /api/v1/auth/login]
      next [options.fetch(:login_code), "{}"] unless options.fetch(:login_code) == 200

      [200, '{"ok":true}',
       options.fetch(:cookie) ? with_headers("application/json", "Set-Cookie: #{SESSION}") : "application/json"]
    when %w[GET /api/v1/auth/config]
      next [401, "{}"] if cookie.nil? || cookie.empty?

      [200, JSON.generate("apiKey" => options.fetch(:config_api_key))]
    when %w[GET /api/v1/auth/users]
      next [401, "{}"] unless key == API_KEY

      rows = options.fetch(:users) || [{ "username" => ADMIN, "role" => "admin" }]
      [200, JSON.generate(rows)]
    when %w[GET /api/v1/rootfolder]
      # The anonymous read and the keyed read are the same route: the contract
      # reads it once with no credential, expecting a refusal, and once with the
      # key. Splitting on the header is what keeps those two rows independent.
      next [options.fetch(:anonymous_root_code), "[]"] if key.nil?
      next [options.fetch(:roots_code), "{}"] unless options.fetch(:roots_code) == 200

      [200, JSON.generate(options.fetch(:root_paths).map { |path| { "path" => path } })]
    when %w[GET /api/v1/system/storage] then [200, JSON.generate(storage_document(options))]
    when %w[GET /api/v1/setting]
      [200, JSON.generate(options.fetch(:settings).map { |k, v| { "key" => k, "value" => v } })]
    when %w[GET /api/v1/prowlarr]
      rows = options.fetch(:prowlarr_rows) || (options.fetch(:usenet) ? [prowlarr_row] : [])
      [200, JSON.generate(rows)]
    when %w[GET /api/v1/downloadclient]
      rows = options.fetch(:client_rows) || (options.fetch(:usenet) ? [client_row] : [])
      [200, JSON.generate(rows)]
    else [404, "{}"]
    end
  end
end

RUNTIME_ROWS = [
  { name: "a converged Bindery with no transport", given: {}, expects: nil },
  { name: "a converged Bindery with the Usenet transport", given: { usenet: true }, expects: nil },
  {
    name: "a health endpoint that does not answer JSON",
    given: { health_body: "not json" },
    expects: "Bindery did not answer JSON for health"
  },
  {
    name: "a service that does not report itself healthy",
    given: { health_body: '{"status":"degraded"}' },
    expects: "Bindery did not report itself healthy"
  },
  {
    name: "a container Docker cannot inspect",
    given: { inspect_ok: false },
    expects: "the Bindery container could not be inspected"
  },
  {
    # The image is distroless and has no shell, so this is also the proof that
    # the probe is the binary's own subcommand rather than a CMD-SHELL.
    name: "a container Docker calls unhealthy",
    given: { health: "unhealthy" },
    expects: "the Bindery container is not healthy"
  },
  {
    name: "a first-run setup route still open to whoever reaches the port",
    given: { setup_code: 200 },
    expects: "Bindery left its first-run setup open"
  },
  {
    # local-only grants administrator to every private-network peer with no
    # credential, and an administrator may read the API key in clear.
    name: "authentication left at local-only",
    given: { auth_mode: "local-only" },
    expects: "Bindery does not enforce authentication"
  },
  {
    name: "a service still reporting first-run setup as required",
    given: { setup_required: true },
    expects: "Bindery still reports first-run setup as required"
  },
  {
    name: "a protected route served to an unauthenticated caller",
    given: { anonymous_root_code: 200 },
    expects: "Bindery served a protected route to an unauthenticated caller"
  },
  {
    name: "an OPDS catalogue served to an unauthenticated caller",
    given: { opds_code: 200 },
    expects: "Bindery served its OPDS catalogue to an unauthenticated caller"
  },
  {
    name: "a vault that cannot be read",
    given: { vault_ok: false },
    expects: "encrypted vault could not be read"
  },
  {
    name: "an administrator the deployment does not recognise",
    given: { login_code: 401 },
    expects: "Bindery refused the vault-authored administrator"
  },
  {
    name: "a login that hands back no session",
    given: { cookie: false },
    expects: "Bindery issued no session to the vault administrator"
  },
  {
    # The seed is honoured only while the stored key is absent, so a deployment
    # that converged is holding exactly the key the vault authored.
    name: "an API key the vault did not author",
    given: { config_api_key: "0" * 32 },
    expects: "Bindery is not holding the vault-authored API key"
  },
  {
    name: "a second account holding the vault administrator's name",
    given: { users: [{ "username" => ADMIN, "role" => "admin" },
                     { "username" => ADMIN, "role" => "admin" }] },
    expects: "Bindery does not hold exactly one vault-authored administrator"
  },
  {
    name: "an administrator demoted to a plain user",
    given: { users: [{ "username" => ADMIN, "role" => "user" }] },
    expects: "Bindery does not hold exactly one vault-authored administrator"
  },
  {
    name: "destination roots the service refuses to list",
    given: { roots_code: 403 },
    expects: "Bindery refused to list its destination roots"
  },
  {
    # An audiobook root that fell back to the ebook root is the single-library
    # collapse the design forbids, and it looks identical everywhere else.
    name: "an audiobook root collapsed onto the ebook root",
    given: { root_paths: [EBOOKS_ROOT, EBOOKS_ROOT] },
    expects: "Bindery does not own exactly the declared ebook and audiobook roots"
  },
  {
    name: "a storage report with no audiobook directory",
    given: { missing_dir: "audiobook" },
    expects: "Bindery reports no audiobook directory"
  },
  {
    # The image is distroless, starts as no one privileged and has no shell, so
    # it cannot repair a wrongly owned directory.
    name: "a staging directory the container cannot write",
    given: { unwritable_dir: "download" },
    expects: "Bindery cannot write its download directory at /data/books/.acquisition/usenet/ebooks"
  },
  {
    # rename(2) and link(2) refuse to cross a mount boundary even when both sides
    # are one filesystem, so mounting a library and its staging directory
    # separately makes every import a full byte copy while every other reading
    # stays identical. The reason string is the diagnosis.
    name: "a staging layout that cannot hardlink into its libraries",
    given: { hardlinkable: false },
    expects: "Bindery cannot hardlink from its staging roots into its libraries: " \
             "cross-device link at /data/books/Ebooks"
  },
  {
    name: "a staging layout that cannot hardlink and says nothing about why",
    given: { hardlinkable: false, hardlink_reason: nil },
    expects: "no reason reported"
  },
  {
    # The auto-grab kill switch fails open, so an absent row means unattended
    # grabbing is on.
    name: "an auto-grab kill switch row that is absent altogether",
    given: { settings: { "telemetry.enabled" => "false" } },
    expects: "Bindery does not pin autoGrab.enabled to false"
  },
  {
    name: "telemetry left on in the deployed settings",
    given: { settings: { "autoGrab.enabled" => "false", "telemetry.enabled" => "true" } },
    expects: "Bindery does not pin telemetry.enabled to false"
  },
  {
    # A repeated create answers 201 and adds a second row rather than failing, so
    # the count is the property a converged reconciliation has to hold.
    name: "duplicate Prowlarr instances",
    given: { usenet: true, prowlarr_rows: [prowlarr_row, prowlarr_row] },
    expects: "Bindery holds duplicate Prowlarr instances"
  },
  {
    name: "duplicate download clients",
    given: { usenet: true, client_rows: [client_row, client_row] },
    expects: "Bindery holds duplicate download clients"
  },
  {
    name: "a Prowlarr instance declared on a host with no transport",
    given: { usenet: false, prowlarr_rows: [prowlarr_row] },
    expects: "Bindery declared a Prowlarr instance with the transport disabled"
  },
  {
    name: "a download client declared on a host with no transport",
    given: { usenet: false, client_rows: [client_row] },
    expects: "Bindery declared a download client with the transport disabled"
  },
  {
    name: "no Prowlarr instance where the transport is enabled",
    given: { usenet: true, prowlarr_rows: [] },
    expects: "Bindery declared no Prowlarr instance"
  },
  {
    name: "a Prowlarr instance not addressed by its control-network alias",
    given: { usenet: true, prowlarr_rows: [prowlarr_row.merge("url" => "http://10.0.0.5:9696")] },
    expects: "Bindery does not reach Prowlarr by its control-network alias"
  },
  {
    # Credentials are write-only in every response, so a stored key can be proved
    # present and never proved correct.
    name: "a Prowlarr instance holding no credential",
    given: { usenet: true, prowlarr_rows: [prowlarr_row.merge("apiKeyConfigured" => false)] },
    expects: "Bindery stored no Prowlarr credential"
  },
  {
    name: "a disabled Prowlarr instance",
    given: { usenet: true, prowlarr_rows: [prowlarr_row.merge("enabled" => false)] },
    expects: "Bindery disabled its Prowlarr instance"
  },
  {
    name: "no download client where the transport is enabled",
    given: { usenet: true, client_rows: [] },
    expects: "Bindery declared no download client"
  },
  {
    name: "a download client not addressed by its control-network alias",
    given: { usenet: true, client_rows: [client_row.merge("host" => "10.0.0.6")] },
    expects: "Bindery does not reach SABnzbd by its control-network alias"
  },
  {
    name: "a download client holding no credential",
    given: { usenet: true, client_rows: [client_row.merge("apiKeyConfigured" => false)] },
    expects: "Bindery stored no SABnzbd credential"
  },
  {
    # One client serves both libraries only because the two categories differ.
    name: "a download client whose two categories have collapsed",
    given: { usenet: true, client_rows: [client_row.merge("categoryAudiobook" => "ebooks")] },
    expects: "Bindery collapsed its ebook and audiobook download categories"
  },
  {
    name: "a disabled download client",
    given: { usenet: true, client_rows: [client_row.merge("enabled" => false)] },
    expects: "Bindery disabled its download client"
  },
  {
    name: "state that did not land in the declared config root",
    given: { database: false },
    expects: "Bindery did not persist its database in the declared config root"
  }
].freeze

def runtime_failures(program, rows = RUNTIME_ROWS)
  failures = []
  in_parallel_cases(failures, rows) do |row, collected|
    options = RUNTIME_DEFAULTS.merge(row.fetch(:given))
    Dir.mktmpdir("nas-platform-bindery-runtime.") do |raw|
      root = File.realpath(raw)
      bin, docker_root = build_runtime_sandbox(root, options)
      HttpFixtureSupport.with_http_fixture(
        lambda do |port|
          stdout, stderr, status = Open3.capture3(
            {
              "PATH" => "#{bin}:#{ENV.fetch('PATH')}",
              "PLATFORM_BINDERY_PORT" => port.to_s,
              "PLATFORM_BINDERY_CONTAINER" => "fixture-bindery",
              "PLATFORM_BINDERY_USENET" => options.fetch(:usenet).to_s,
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
#
# tests/contracts/bindery.sh resolves both programs from its own checkout rather
# than from the tree it inspects, so a copy of the three files into a throwaway
# tests/contracts/ is a whole working contract. That is what lets a row point
# PLATFORM_CONTRACT_REPO_DIR at a broken fixture and still exercise the real
# wrapper.

def with_contract_copy(static: File.read(STATIC_PROGRAM), runtime: File.read(RUNTIME_PROGRAM),
                       wrapper: File.read(CONTRACT))
  Dir.mktmpdir("nas-platform-bindery-wrapper.") do |raw|
    root = File.realpath(raw)
    build_fixture_repository(root)
    contracts = File.join(root, "tests", "contracts")
    FileUtils.mkdir_p(contracts)
    wrapper_path = File.join(contracts, "bindery.sh")
    File.write(wrapper_path, wrapper)
    File.chmod(0o755, wrapper_path)
    File.write(File.join(contracts, "bindery-static.rb"), static)
    File.write(File.join(contracts, "bindery-runtime.rb"), runtime)
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

# The runtime half is reached by `exec`, so its redirect needs its own probe: the
# static half must succeed first for the exec to happen at all.
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
    failures << "runtime stdin: the probing shell reported no status" if status.nil?
  end
  failures
end

# The run-mode environment contract. Each name is refused with the WRAPPER'S OWN
# message, and that is what is asserted -- never the shell's own wording, which
# differs between bash ("parameter null or not set") and dash ("parameter not set
# or null"), and never the line number, which any edit to this file moves.
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
      "PLATFORM_MAC_VAULT_PASSWORD_FILE" => nil,
      # Unparseable on purpose, and it changes no outcome in the unmutated rows
      # because the ${VAR:?} guard fires before the port is ever read. It bounds
      # the SELF-TEST rows: a plant that turns one of those guards into `:=`
      # lets the run reach the real runtime program, whose readiness loop then
      # polls a closed port for 120 seconds. Two such plants took the self-test
      # from forty seconds to four minutes before this line existed.
      "PLATFORM_BINDERY_PORT" => "not-a-number"
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
    FileUtils.rm(File.join(copy_root, "services/bindery/compose.mac.yml"))
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
      (stdout + stderr).include?("missing services/bindery/compose.mac.yml")
  end

  # The branch every deployment actually takes: PLATFORM_CONTRACT_REPO_DIR unset,
  # so the programs and the inspected tree both come from the script's own
  # checkout. That is the only path in production.
  with_contract_copy(wrapper: wrapper_source) do |contract, copy_root|
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => nil }, contract, "static"
    )
    failures << "wrapper: static mode failed with no repository named: #{(stdout + stderr).strip}" unless
      status.success?
    failures << "wrapper: static mode did not report the property it proved" unless
      stdout.include?(SUCCESS_LINE)

    FileUtils.rm(File.join(copy_root, "services/bindery/compose.mac.yml"))
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => nil }, contract, "static"
    )
    failures << "wrapper: with no repository named, static mode inspected some other tree" if
      status.success?
    failures << "wrapper: with no repository named, static mode did not report the broken tree" unless
      (stdout + stderr).include?("missing services/bindery/compose.mac.yml")
  end
  failures
end

# The two-roots property, stated as an OUTCOME rather than as the wrapper's text.
# These are the invariant rows: a before/after capture diff can only show
# differences, so the property that must stay identical is invisible in it. They
# are asserted here instead, and they are what would have caught #251's defect.
def two_roots_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  with_contract_copy(wrapper: wrapper_source) do |contract|
    Dir.mktmpdir("nas-platform-bindery-tworoots.") do |raw|
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

    # The other direction, and it is the opposite polarity to the Kapowarr
    # contract's: bindery-static.rb carries its own flatten_tasks and takes the
    # inspected tree as an argument, so a tree whose tests/policy_support.rb
    # raises must be IGNORED. An export added here -- copying the Kapowarr
    # wrapper's shape without checking -- would make this row fail.
    Dir.mktmpdir("nas-platform-bindery-support.") do |raw|
      inspected = File.realpath(raw)
      build_fixture_repository(inspected)
      FileUtils.mkdir_p(File.join(inspected, "tests"))
      File.write(File.join(inspected, "tests", "policy_support.rb"),
                 %(raise "inspected tree policy_support reached"\n))
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => inspected }, contract, "static"
      )
      failures << "two roots: the static program read the inspected tree's policy_support, " \
                  "which it must not: #{(stdout + stderr).strip}" unless status.success?
      failures << "two roots: the program did not report the property it proved" unless
        stdout.include?(SUCCESS_LINE)
    end
  end
  failures
end

# The runtime program's own two-roots row, and it needs a layer of its own.
# runtime_stdin_failures points PLATFORM_CONTRACT_REPO_DIR at the contract copy,
# so the checkout and the inspected tree ARE the same directory there and a
# rerooted $runtime_program resolves to the same file: the self-test reported
# that plant as "accepted" until this row existed, which is hazard 1 caught by
# the harness rather than argued about. Here the inspected tree is a separate
# fixture with no tests/contracts at all, so a reroot cannot find the program.
def runtime_program_root_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  with_contract_copy(runtime: STDIN_PROBE, wrapper: wrapper_source) do |contract|
    Dir.mktmpdir("nas-platform-bindery-runtime-roots.") do |raw|
      inspected = File.realpath(raw)
      build_fixture_repository(inspected)
      stdout, stderr, = Open3.capture3(
        {
          "PLATFORM_CONTRACT_REPO_DIR" => inspected,
          "PLATFORM_CONTRACT_VAULT_FILE" => File.join(inspected, "vault.yml"),
          "PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" => File.join(inspected, "vault-password"),
          "PLATFORM_DOCKER_ROOT" => File.join(inspected, "docker")
        },
        contract, "run"
      )
      output = stdout + stderr
      failures << "runtime two roots: the runtime program was not reached out of the checkout: " \
                  "#{output.strip.inspect}" unless output.include?('probe read ""')
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
    rows: ["a control network the platform declares itself"]
  },
  {
    label: "the platform identity check",
    program: :static,
    from: 'service["user"] == "${NAS_UID:?}:${NAS_GID:?}"',
    to: "true",
    rows: ["a container that is not the platform identity"]
  },
  {
    label: "the whole-host-share mount check",
    program: :static,
    from: 'Array(service["volumes"]) == [
      "${BINDERY_CONFIG_PATH:?}:/config",
      "${BINDERY_BOOKS_PATH:?}:/data/books",
      "${BINDERY_MEDIA_PATH:?}:/data/media"
    ]',
    to: "true",
    rows: ["one bind mount per library leaf instead of per host share"]
  },
  {
    label: "the exec-form health probe check",
    program: :static,
    from: "probe == %w[CMD /bindery healthcheck]",
    to: "true",
    rows: ["a shell-form health probe the distroless image cannot run"]
  },
  {
    label: "the exactly-once CPU set read",
    program: :static,
    # Restores the substring search the line-oriented read replaced, which is the
    # form a second live assignment satisfies while only one may exist.
    from: 'env_assignments.select { |name, _value| name == "PLATFORM_CONTAINER_CPUSET" } ==
      [["PLATFORM_CONTAINER_CPUSET", "{{ platform_effective_container_cpuset }}"]]',
    to: 'File.read(File.join(root, "roles/bindery/templates/env.j2"))
      .include?("PLATFORM_CONTAINER_CPUSET={{ platform_effective_container_cpuset }}")',
    rows: ["a CPU set rendered twice"]
  },
  {
    label: "the exactly-one-credential environment check",
    program: :static,
    from: 'env_assignments.select { |_name, value| value.include?("vault_") } ==
      [["BINDERY_API_KEY", "{{ vault_bindery_api_key }}"]]',
    to: "true",
    rows: ["a second vault credential copied into the environment"]
  },
  {
    label: "the state-guard ordering check",
    program: :static,
    from: "backup_include && deploy_index && backup_include < deploy_index",
    to: "true",
    rows: ["a pre-upgrade state guard that runs after the deployment"]
  },
  {
    label: "the created-backup-only check",
    program: :static,
    from: 'backup_request.dig("ansible.builtin.uri", "status_code") == [201]',
    to: "true",
    rows: ["a pre-upgrade backup that tolerates a failed VACUUM INTO"]
  },
  {
    label: "the wrong-password refusal",
    program: :static,
    from: 'body.is_a?(Hash) && body.key?("password") &&
      body["password"].to_s != "{{ vault_bindery_admin_password }}"',
    to: "false",
    rows: ["a probe submitting a password the platform expects to be refused"]
  },
  {
    label: "the credential redaction check",
    program: :static,
    from: "credential_tasks.length >= 10 && credential_tasks.all? { |task| task[\"no_log\"] == true }",
    to: "true",
    rows: ["a credential-bearing request rendered in full"]
  },
  {
    label: "the readable recoverability guard check",
    program: :static,
    from: 'recovery_guard && !recovery_guard["no_log"]',
    to: "true",
    rows: ["a recoverability guard redacted away"]
  },
  {
    label: "the one-login-attempt check",
    program: :static,
    from: "logins.length == 1",
    to: "true",
    rows: ["verification spending a second login attempt"]
  },
  {
    label: "the defer-to-the-assertion check",
    program: :static,
    from: 'task.dig("ansible.builtin.uri", "status_code") == "{{ range(100, 600) | list }}"',
    to: "true",
    rows: ["a probe that pins a status instead of deferring to the assertion"]
  },
  {
    label: "the changeless verification read check",
    program: :static,
    from: '(task["changed_when"] == false && task["check_mode"] == false)',
    to: "true",
    rows: ["a verification read that claims a change"]
  },
  {
    label: "the JSON answer check",
    program: :runtime,
    from: "JSON.parse(response.body)",
    to: 'JSON.parse(response.body) rescue {"status" => "ok"}',
    rows: ["a health endpoint that does not answer JSON"]
  },
  {
    label: "the healthy-service check",
    program: :runtime,
    from: 'health["status"] == "ok"',
    to: "true",
    rows: ["a service that does not report itself healthy"]
  },
  {
    label: "the healthy-container check",
    program: :runtime,
    from: 'state.strip == "healthy"',
    to: "true",
    rows: ["a container Docker calls unhealthy"]
  },
  {
    label: "the closed first-run setup check",
    program: :runtime,
    from: 'setup.code == "409"',
    to: "true",
    rows: ["a first-run setup route still open to whoever reaches the port"]
  },
  {
    label: "the enforced authentication check",
    program: :runtime,
    from: 'auth_status["mode"] == "enabled"',
    to: "true",
    rows: ["authentication left at local-only"]
  },
  {
    label: "the anonymous protected-route refusal",
    program: :runtime,
    from: 'get("/api/v1/rootfolder").code == "401"',
    to: "true",
    rows: ["a protected route served to an unauthenticated caller"]
  },
  {
    label: "the anonymous OPDS refusal",
    program: :runtime,
    from: 'get("/opds/").code == "401"',
    to: "true",
    rows: ["an OPDS catalogue served to an unauthenticated caller"]
  },
  # No plant for the issued-session check, deliberately. Removing `cookie.empty?`
  # cannot be isolated: the very next read sends the empty cookie to
  # /api/v1/auth/config, which cannot then return the vault-authored key, so the
  # break is caught by "Bindery is not holding the vault-authored API key"
  # instead of by its own sentence. That redundancy is the program's, not this
  # test's, and a row expecting the downstream sentence would freeze it. The
  # unmutated row above still pins the right diagnostic, which is what matters.
  {
    label: "the vault-authored API key check",
    program: :runtime,
    from: 'config["apiKey"] == seeded_key',
    to: "true",
    rows: ["an API key the vault did not author"]
  },
  {
    label: "the exactly-one-administrator check",
    program: :runtime,
    from: "administrators.length == 1",
    to: "true",
    rows: ["a second account holding the vault administrator's name",
           "an administrator demoted to a plain user"]
  },
  {
    label: "the two-root ownership check",
    program: :runtime,
    from: "declared.sort == LIBRARY_ROOTS.sort",
    to: "true",
    rows: ["an audiobook root collapsed onto the ebook root"]
  },
  {
    label: "the writable storage check",
    program: :runtime,
    from: 'entry["exists"] && entry["writable"]',
    to: "true",
    rows: ["a staging directory the container cannot write"]
  },
  {
    label: "the hardlinkable staging check",
    program: :runtime,
    from: 'storage["hardlinkable"] == true',
    to: "true",
    rows: ["a staging layout that cannot hardlink into its libraries",
           "a staging layout that cannot hardlink and says nothing about why"]
  },
  {
    label: "the pinned settings check",
    program: :runtime,
    from: "settings[key] == value",
    to: "true",
    rows: ["an auto-grab kill switch row that is absent altogether",
           "telemetry left on in the deployed settings"]
  },
  {
    label: "the duplicate Prowlarr check",
    program: :runtime,
    from: "instances.length > 1",
    to: "false",
    rows: ["duplicate Prowlarr instances"]
  },
  {
    label: "the duplicate download client check",
    program: :runtime,
    from: "clients.length > 1",
    to: "false",
    rows: ["duplicate download clients"]
  },
  {
    label: "the Prowlarr control-network alias check",
    program: :runtime,
    from: 'instance["url"] == "http://prowlarr:9696"',
    to: "true",
    rows: ["a Prowlarr instance not addressed by its control-network alias"]
  },
  {
    label: "the SABnzbd control-network alias check",
    program: :runtime,
    from: 'client["type"] == "sabnzbd" && client["host"] == "sabnzbd" && client["port"] == 8080',
    to: "true",
    rows: ["a download client not addressed by its control-network alias"]
  },
  {
    label: "the distinct download category check",
    program: :runtime,
    from: 'client["category"] == "ebooks" && client["categoryAudiobook"] == "audiobooks"',
    to: "true",
    rows: ["a download client whose two categories have collapsed"]
  },
  {
    label: "the no-transport Prowlarr refusal",
    program: :runtime,
    from: "instances.empty?",
    to: "true",
    rows: ["a Prowlarr instance declared on a host with no transport"]
  },
  {
    label: "the no-transport download client refusal",
    program: :runtime,
    from: "clients.empty?",
    to: "true",
    rows: ["a download client declared on a host with no transport"]
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
    from: "static_program=$contract_repo_dir/tests/contracts/bindery-static.rb",
    to: "static_program=$repo_dir/tests/contracts/bindery-static.rb",
    layer: :two_roots
  },
  {
    label: "the runtime program resolved from the inspected tree",
    from: "runtime_program=$contract_repo_dir/tests/contracts/bindery-runtime.rb",
    to: "runtime_program=$repo_dir/tests/contracts/bindery-runtime.rb",
    layer: :runtime_program_root
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
    Dir.mktmpdir("nas-platform-bindery-mutant.") do |directory|
      name = mutation.fetch(:program) == :static ? "bindery-static.rb" : "bindery-runtime.rb"
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
             when :runtime_program_root then runtime_program_root_failures(wrapper_source: source)
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

  puts "bindery contract: self-test detects #{planted} planted regressions"
  exit
end

failures = static_failures(STATIC_PROGRAM) + runtime_failures(RUNTIME_PROGRAM) +
           wrapper_failures + run_env_failures + stdin_failures + runtime_stdin_failures +
           two_roots_failures + runtime_program_root_failures
unless failures.empty?
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} Bindery contract violation(s)"
end

puts "bindery contract: #{STATIC_ROWS.length} static and #{RUNTIME_ROWS.length} runtime properties " \
     "hold, the run-mode environment contract refuses each name with the wrapper's own message, " \
     "and both programs come from the checkout with an empty stdin"
