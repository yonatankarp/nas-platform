#!/usr/bin/env ruby
# frozen_string_literal: true
# Behaviour of the Bindery contract's static and runtime programs and its wrapper.
# Every row pins the exact diagnostic. --self-test plants a regression in each;
# plants are built before the pool, because `abort` in a worker becomes a KeyError.

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

include TestScaffold
include ContractTestSupport

ROOT = File.expand_path("..", __dir__)
# Matching the fragment alone accepted a backtrace or an echoed argument.
DIAGNOSTIC_PREFIX = "Bindery contract failed: "
CONTRACT = File.join(ROOT, "tests", "contracts", "bindery.sh")
STATIC_PROGRAM = File.join(ROOT, "tests", "contracts", "bindery-static.rb")
RUNTIME_PROGRAM = File.join(ROOT, "tests", "contracts", "bindery-runtime.rb")

SUCCESS_LINE = "bindery static contract: two-library acquisition ownership holds"
MODE_REFUSAL = "bindery contract accepts only static, run, seed or verify"

# Exactly the program's own `required` list. tests/policy_support.rb is absent on
# purpose: bindery-static.rb carries its own flatten_tasks.
FIXTURE_FILES = %w[
  roles/bindery/defaults/main.yml
  roles/bindery/meta/argument_specs.yml
  roles/bindery/tasks/main.yml
  roles/bindery/tasks/pre_upgrade_backup.yml
  roles/bindery/tasks/reconcile_authors.yml
  roles/bindery/tasks/reconcile_audiobookshelf.yml
  roles/bindery/tasks/reconcile_usenet.yml
  roles/bindery/tasks/resolve_api_key.yml
  roles/bindery/templates/env.j2
  roles/image_downgrade_guard/tasks/main.yml
  services/bindery/compose.yml
  services/bindery/compose.mac.yml
  services/bindery/compose.integration.yml
].freeze


def build_fixture_repository(root)
  FIXTURE_FILES.each do |relative|
    destination = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(destination))
    FileUtils.cp(File.join(ROOT, relative), destination)
  end
end

# A replacement that still contains its own pattern plants nothing, so every
# substitution states how many matches it expects.
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
    name: "no guard against a pin that goes back past a migration",
    break: lambda { |root|
      role_tasks(root) do |document|
        document.reject! do |task|
          task.dig("ansible.builtin.include_role", "name") == "image_downgrade_guard"
        end
      end
    },
    expects: "Bindery must refuse an image older than the store already on disk"
  },
  {
    name: "a downgrade guard that runs after the deployment",
    break: lambda { |root|
      role_tasks(root) do |document|
        guard = document.find do |task|
          task.dig("ansible.builtin.include_role", "name") == "image_downgrade_guard"
        end
        document.delete(guard)
        document.push(guard)
      end
    },
    expects: "the Bindery downgrade guard must run before the backup and the deployment"
  },
  {
    name: "a downgrade guard pointed at another Compose project",
    break: lambda { |root|
      role_tasks(root) do |document|
        guard = find_task(document) do |task|
          task.dig("ansible.builtin.include_role", "name") == "image_downgrade_guard"
        end
        guard["vars"]["image_downgrade_guard_project_name"] = "somebody-else"
      end
    },
    expects: "the Bindery downgrade guard must judge Bindery's own containers"
  },
  {
    name: "a downgrade guard whose reads claim a change",
    break: lambda { |root|
      role_tasks(root, "roles/image_downgrade_guard/tasks/main.yml") do |document|
        find_task(document) { |task| task.key?("ansible.builtin.command") }
          .delete("changed_when")
      end
    },
    expects: "the downgrade guard must read the daemon without claiming a change or deferring"
  },
  {
    name: "a downgrade guard that skips its reads under --check",
    break: lambda { |root|
      role_tasks(root, "roles/image_downgrade_guard/tasks/main.yml") do |document|
        find_task(document) { |task| task.key?("ansible.builtin.command") }["check_mode"] = true
      end
    },
    expects: "the downgrade guard must read the daemon without claiming a change or deferring"
  },
  {
    name: "a downgrade guard blind to containers that have exited",
    break: lambda { |root|
      role_tasks(root, "roles/image_downgrade_guard/tasks/main.yml") do |document|
        find_task(document) { |task| task.key?("ansible.builtin.command") }
          .dig("ansible.builtin.command", "argv").delete("--all")
      end
    },
    expects: "the downgrade guard must list stopped containers too"
  },
  {
    name: "a downgrade guard that reports instead of refusing",
    break: lambda { |root|
      role_tasks(root, "roles/image_downgrade_guard/tasks/main.yml") do |document|
        refusal = find_task(document) { |task| task.key?("ansible.builtin.assert") }
        document[document.index(refusal)] =
          { "name" => refusal["name"], "ansible.builtin.debug" => { "msg" => "would refuse" } }
      end
    },
    expects: "the downgrade guard must refuse rather than report"
  },
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
    # rename(2) refuses to cross a mount boundary even on one filesystem, so every
    # import becomes a byte copy.
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
    # A missing audiobook variable falls back to the ebook one.
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
    name: "a stop grace period inherited rather than declared",
    break: ->(root) { compose_service(root) { |service, _| service.delete("stop_grace_period") } },
    expects: "Bindery holds its SQLite store and must declare a stop grace period"
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
    # The distroless image has no shell; the only executable is /bindery.
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
    # Without the row, a manual disable in the web interface is permanent.
    name: "an auto-grab row left unpinned",
    break: lambda { |root|
      edit_yaml(root, "roles/bindery/defaults/main.yml") do |document|
        document["bindery_pinned_settings"].delete("autoGrab.enabled")
      end
    },
    expects: "Bindery must pin auto-grab on and telemetry off"
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
    # A substring search is satisfied by a second live assignment.
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
    # Bindery migrates its schema on startup.
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
    # POST /backup is VACUUM INTO: a plain copy of the WAL-mode database omits the WAL.
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
    # Under --check `current` is the release the run replaces (#858).
    name: "a pre-upgrade backup that reads current's pin under --check",
    break: lambda { |root|
      role_tasks(root, "roles/bindery/tasks/pre_upgrade_backup.yml") do |document|
        find_task(document) { |candidate| candidate.key?("ansible.builtin.slurp") }.delete("when")
        fact = find_task(document) { |candidate| candidate.dig("ansible.builtin.set_fact")&.key?("bindery_pinned_image") }
        fact["ansible.builtin.set_fact"]["bindery_pinned_image"] =
          "{{ (bindery_compose_source.content | b64decode | from_yaml).services.bindery.image }}"
      end
    },
    expects: "the Bindery pre-upgrade backup must read the candidate's pin under --check"
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
    # Restores the #425 state: authors with no destination root or profile.
    name: "author reconciliation dropped from the role",
    break: lambda { |root|
      role_tasks(root) do |document|
        document.reject! do |task|
          task["ansible.builtin.include_tasks"] == "reconcile_authors.yml"
        end
      end
    },
    expects: "Bindery must reconcile its author destinations"
  },
  {
    # A destination root is needed whatever the transport, including on a Mac.
    name: "author reconciliation gated on the transport flag",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          candidate["ansible.builtin.include_tasks"] == "reconcile_authors.yml"
        end
        task["when"] = ["media_usenet_enabled | bool"]
      end
    },
    expects: "the Bindery author reconciliation must not be gated on the transport flag"
  },
  {
    # Would report `changed` on every converge.
    name: "an author repair that writes every author",
    break: lambda { |root|
      role_tasks(root, "roles/bindery/tasks/reconcile_authors.yml") do |document|
        task = find_task(document) do |candidate|
          candidate.dig("ansible.builtin.uri", "method") == "PUT"
        end
        task["loop"] = "{{ bindery_authors.json['items'] }}"
      end
    },
    expects: "the Bindery author repair must write only the authors missing a value"
  },
  {
    # Fights a deliberate per-author choice on every converge.
    name: "an author repair that overwrites a chosen destination root",
    break: lambda { |root|
      mutate_text(root, "roles/bindery/tasks/reconcile_authors.yml",
                  "if item.rootFolderId is none else item.rootFolderId", "",
                  occurrences: 1)
    },
    expects: "the Bindery author repair must leave a set rootFolderId alone"
  },
  {
    # Following an author is the user's; this would re-follow on every tick.
    name: "an author repair that also owns the monitored state",
    break: lambda { |root|
      mutate_text(root, "roles/bindery/tasks/reconcile_authors.yml",
                  "'qualityProfileId':", "'monitored': true, 'qualityProfileId':",
                  occurrences: 1)
    },
    expects: "the Bindery author repair must not own the monitored state"
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
  # The Audiobookshelf handoff: each break leaves the converge green; the missed
  # scan is only logged at WARN inside Bindery.
  {
    name: "a declared Audiobookshelf reconciliation that is gone",
    break: ->(root) { FileUtils.rm(File.join(root, "roles/bindery/tasks/reconcile_audiobookshelf.yml")) },
    expects: "missing roles/bindery/tasks/reconcile_audiobookshelf.yml"
  },
  {
    name: "an Audiobookshelf integration gated behind a flag",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          candidate["ansible.builtin.include_tasks"] == "reconcile_audiobookshelf.yml"
        end
        task["when"] = ["media_usenet_enabled | bool"]
      end
    },
    expects: "Bindery must reconcile its Audiobookshelf integration unconditionally"
  },
  {
    # Neither side can read back the credential, so resending means re-minting.
    name: "an Audiobookshelf repair that rewrites the credential",
    break: lambda { |root|
      role_tasks(root, "roles/bindery/tasks/reconcile_audiobookshelf.yml") do |document|
        task = find_task(document) do |candidate|
          candidate.dig("ansible.builtin.uri", "url") == "{{ bindery_api }}/abs/config" &&
            candidate.dig("ansible.builtin.uri", "method") == "PUT" &&
            !candidate.dig("ansible.builtin.uri", "body").key?("apiKey")
        end
        task["ansible.builtin.uri"]["body"]["apiKey"] = ""
      end
    },
    expects: "the Bindery Audiobookshelf repair must not touch the credential"
  },
  {
    # Upstream keeps every omitted field, so a hand-set remap would survive.
    name: "an Audiobookshelf repair that leaves the path remap alone",
    break: lambda { |root|
      role_tasks(root, "roles/bindery/tasks/reconcile_audiobookshelf.yml") do |document|
        task = find_task(document) do |candidate|
          candidate.dig("ansible.builtin.uri", "url") == "{{ bindery_api }}/abs/config" &&
            candidate.dig("ansible.builtin.uri", "method") == "PUT" &&
            !candidate.dig("ansible.builtin.uri", "body").key?("apiKey")
        end
        task["ansible.builtin.uri"]["body"].delete("pathRemap")
      end
    },
    expects: "the Bindery Audiobookshelf repair must send every declared field"
  },
  {
    name: "an Audiobookshelf declaration written on every converge",
    break: lambda { |root|
      role_tasks(root, "roles/bindery/tasks/reconcile_audiobookshelf.yml") do |document|
        task = find_task(document) do |candidate|
          candidate.dig("ansible.builtin.uri", "url") == "{{ bindery_api }}/abs/config" &&
            candidate.dig("ansible.builtin.uri", "method") == "PUT" &&
            candidate.dig("ansible.builtin.uri", "body").key?("apiKey")
        end
        task["when"] = ["not ansible_check_mode"]
      end
    },
    expects: "the Bindery Audiobookshelf declaration must be gated on a mint"
  },
  {
    name: "an Audiobookshelf repair that runs beside the declaration",
    break: lambda { |root|
      role_tasks(root, "roles/bindery/tasks/reconcile_audiobookshelf.yml") do |document|
        task = find_task(document) do |candidate|
          candidate.dig("ansible.builtin.uri", "url") == "{{ bindery_api }}/abs/config" &&
            candidate.dig("ansible.builtin.uri", "method") == "PUT" &&
            !candidate.dig("ansible.builtin.uri", "body").key?("apiKey")
        end
        task["when"] = ["not ansible_check_mode", "bindery_abs_drifted | bool"]
      end
    },
    expects: "the Bindery Audiobookshelf repair must be gated on drift alone"
  },
  {
    # `create` stores `!!req.body.isActive`: an omitted flag mints a dead key.
    name: "an Audiobookshelf key minted inactive",
    break: lambda { |root|
      role_tasks(root, "roles/bindery/tasks/reconcile_audiobookshelf.yml") do |document|
        task = find_task(document) do |candidate|
          candidate.dig("ansible.builtin.uri", "url") ==
            "{{ bindery_audiobookshelf_api }}/api/api-keys" &&
            candidate.dig("ansible.builtin.uri", "method") == "POST"
        end
        task["ansible.builtin.uri"]["body"].delete("isActive")
      end
    },
    expects: "the Audiobookshelf key Bindery mints must be active and never expire"
  },
  {
    # An expiry deactivates the key on first use past it.
    name: "an Audiobookshelf key minted with an expiry",
    break: lambda { |root|
      role_tasks(root, "roles/bindery/tasks/reconcile_audiobookshelf.yml") do |document|
        task = find_task(document) do |candidate|
          candidate.dig("ansible.builtin.uri", "url") ==
            "{{ bindery_audiobookshelf_api }}/api/api-keys" &&
            candidate.dig("ansible.builtin.uri", "method") == "POST"
        end
        task["ansible.builtin.uri"]["body"]["expiresIn"] = 3600
      end
    },
    expects: "the Audiobookshelf key Bindery mints must be active and never expire"
  },
  {
    # The pre-#446 order: a failure after the revoke leaves Bindery holding a
    # dead key that both presence reads still call present.
    name: "an Audiobookshelf key revoked before its replacement exists",
    break: lambda { |root|
      role_tasks(root, "roles/bindery/tasks/reconcile_audiobookshelf.yml") do |document|
        retire = find_task(document) do |candidate|
          candidate.dig("ansible.builtin.uri", "method") == "DELETE" &&
            candidate.dig("ansible.builtin.uri", "url").to_s
                     .start_with?("{{ bindery_audiobookshelf_api }}/api/api-keys/")
        end
        mint = find_task(document) do |candidate|
          candidate.dig("ansible.builtin.uri", "url") ==
            "{{ bindery_audiobookshelf_api }}/api/api-keys" &&
            candidate.dig("ansible.builtin.uri", "method") == "POST"
        end
        document.delete(retire)
        document.insert(document.index(mint), retire)
      end
    },
    expects: "the superseded Audiobookshelf API key must be retired only after its " \
             "replacement is declared"
  },
  {
    # A list re-read after the mint holds the new row, which retirement then revokes.
    name: "an Audiobookshelf retirement that re-reads the key list after minting",
    break: lambda { |root|
      mutate_text(root, "roles/bindery/tasks/reconcile_audiobookshelf.yml",
                  'loop: "{{ bindery_audiobookshelf_key_matches }}"',
                  'loop: "{{ bindery_audiobookshelf_keys_after_mint }}"')
    },
    expects: "the Audiobookshelf retirement must loop over the keys read before the mint"
  },
  {
    # The dead row survives and the ambiguity refusal fails every later converge.
    name: "an Audiobookshelf retirement that is gone",
    break: lambda { |root|
      role_tasks(root, "roles/bindery/tasks/reconcile_audiobookshelf.yml") do |document|
        task = find_task(document) do |candidate|
          candidate.dig("ansible.builtin.uri", "method") == "DELETE"
        end
        document.delete(task)
      end
    },
    expects: "Bindery must retire the superseded Audiobookshelf API key"
  },
  {
    # Neither end reveals what it holds, so presence cannot prove a working pair.
    name: "a mint decision that trusts the two presence reads alone",
    break: lambda { |root|
      mutate_text(root, "roles/bindery/tasks/reconcile_audiobookshelf.yml",
                  "or bindery_abs_probe.status | default(0) | int != 200",
                  "or false")
    },
    expects: "the Bindery Audiobookshelf mint must answer the credential probe"
  },
  {
    name: "a credential probe that sends a key of its own",
    break: lambda { |root|
      role_tasks(root, "roles/bindery/tasks/reconcile_audiobookshelf.yml") do |document|
        task = find_task(document) do |candidate|
          candidate.dig("ansible.builtin.uri", "url") == "{{ bindery_api }}/abs/test"
        end
        task["ansible.builtin.uri"]["body"] = { "apiKey" => "{{ bindery_api_key }}" }
      end
    },
    expects: "Bindery must probe the credential it holds for Audiobookshelf"
  },
  {
    name: "an Audiobookshelf library resolved from whatever the name matched",
    break: lambda { |root|
      mutate_text(root, "roles/bindery/tasks/reconcile_audiobookshelf.yml",
                  "bindery_audiobookshelf_library_matches | length == 1",
                  "bindery_audiobookshelf_library_matches is defined")
    },
    expects: "Bindery must refuse an ambiguous Audiobookshelf library"
  },
  {
    name: "an ambiguous Audiobookshelf API key accepted rather than refused",
    break: lambda { |root|
      mutate_text(root, "roles/bindery/tasks/reconcile_audiobookshelf.yml",
                  "bindery_audiobookshelf_key_matches | length <= 1",
                  "bindery_audiobookshelf_key_matches is defined")
    },
    expects: "Bindery must refuse an ambiguous Audiobookshelf API key"
  },
  {
    name: "a verification that never asks whether the handoff credential works",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          candidate.dig("ansible.builtin.uri", "url") == "{{ bindery_api }}/abs/test"
        end
        document.delete(task)
      end
    },
    expects: "Bindery verification must read /abs/test"
  },
  {
    name: "a verification that reads the handoff credential and asserts nothing",
    break: lambda { |root|
      mutate_text(root, "roles/bindery/tasks/main.yml",
                  "      - bindery_verify_abs_probe.status | default(0) | int == 200\n",
                  "")
    },
    expects: "Bindery verification must assert the Audiobookshelf credential that still authenticates"
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
    # The login limiter (5 failures / 15 min / IP) then refuses the correct
    # password too, locking the platform out.
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
    # A redacted assert prints its fail_msg beside {"censored": ...}.
    name: "a recoverability guard redacted away",
    break: lambda { |root|
      role_tasks(root, "roles/bindery/tasks/resolve_api_key.yml") do |document|
        task = find_task(document) do |candidate|
          Array(candidate.dig("ansible.builtin.assert", "that")).any? do |condition|
            condition.to_s.include?("bindery_key_resolution")
          end
        end
        task["no_log"] = true
      end
    },
    expects: "the Bindery recoverability guard must stay readable"
  },
  {
    # #510: deleting the database destroys every author, book and setting.
    name: "a destructive remedy offered whatever the probes saw",
    break: lambda { |root|
      role_tasks(root, "roles/bindery/tasks/resolve_api_key.yml") do |document|
        task = find_task(document) { |candidate| candidate.dig("vars", "bindery_key_refusals") }
        task["vars"]["bindery_key_refusals"]["unreachable"] +=
          " Or remove the Bindery database before running again."
      end
    },
    expects: "only a refused Bindery identity may propose removing its database"
  },
  {
    # Without it a tripped login limiter looks like a foreign identity.
    name: "an API-key classification blind to the administrator login",
    break: lambda { |root|
      role_tasks(root, "roles/bindery/tasks/resolve_api_key.yml") do |document|
        task = find_task(document) { |candidate| candidate.dig("ansible.builtin.set_fact", "bindery_key_resolution") }
        task["ansible.builtin.set_fact"]["bindery_key_resolution"] =
          task["ansible.builtin.set_fact"]["bindery_key_resolution"]
              .gsub("bindery_identity_login.status", "bindery_key_probe.status")
      end
    },
    expects: "the Bindery API-key classification must read bindery_identity_login.status"
  },
  {
    name: "an API-key refusal that classifies nothing",
    break: lambda { |root|
      role_tasks(root, "roles/bindery/tasks/resolve_api_key.yml") do |document|
        task = find_task(document) { |candidate| candidate.dig("ansible.builtin.set_fact", "bindery_key_resolution") }
        document.delete(task)
      end
    },
    expects: "the Bindery API-key refusal must classify what its probes saw"
  },
  {
    # #509: a container stuck in `Restarting` reported changed=0 for three days.
    name: "a deployment nothing checks the container state after",
    break: lambda { |root|
      role_tasks(root) do |document|
        document.reject! { |task| task.is_a?(Hash) && task.dig("vars", "container_health_service_name") }
      end
    },
    expects: "Bindery must detect and then refuse a container that runs but never serves"
  },
  {
    # A `Restarting` container still appears in `docker container ls`.
    name: "a container health verdict that runs after the CPU verification",
    break: lambda { |root|
      role_tasks(root) do |document|
        verdict = document.select { |task| task.is_a?(Hash) && task.dig("vars", "container_health_service_name") }.last
        document.delete(verdict)
        cpu = document.index { |task| task.is_a?(Hash) && task.dig("vars", "container_cpu_service_name") }
        document.insert(cpu + 1, verdict)
      end
    },
    expects: "the Bindery container health passes must bracket the force-recreate"
  },
  {
    name: "a container health detection that refuses before the recreate can run",
    break: lambda { |root|
      role_tasks(root) do |document|
        detect = document.find { |task| task.is_a?(Hash) && task.dig("vars", "container_health_service_name") }
        detect["vars"]["container_health_refuse"] = true
      end
    },
    expects: "the Bindery container health detection must not refuse before the recreate"
  },
  {
    name: "a container health verdict that refuses nothing",
    break: lambda { |root|
      role_tasks(root) do |document|
        verdict = document.select { |task| task.is_a?(Hash) && task.dig("vars", "container_health_service_name") }.last
        verdict["vars"]["container_health_refuse"] = false
      end
    },
    expects: "the Bindery container health verdict must be the one that refuses"
  },
  {
    # Aimed at another project it inspects nothing and passes against any state.
    name: "a container health pass aimed at another Compose project",
    break: lambda { |root|
      role_tasks(root) do |document|
        verdict = document.select { |task| task.is_a?(Hash) && task.dig("vars", "container_health_service_name") }.last
        verdict["vars"]["container_health_project_name"] = "bindery"
      end
    },
    expects: "each Bindery container health pass must name the deployed Compose project"
  },
  {
    # Compose reports a crash loop as "container bindery is unhealthy"; dropping
    # the message makes a parse error look like one.
    name: "a deployment whose own failure message is thrown away",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          candidate.dig("ansible.builtin.set_fact", "bindery_deploy_failure_message")
        end
        task["ansible.builtin.set_fact"] = { "bindery_deploy_failed" => true }
      end
    },
    expects: "the Bindery deployment must catch its own failure"
  },
  {
    name: "a container health detection handed no deployment failure",
    break: lambda { |root|
      role_tasks(root) do |document|
        detect = document.find { |task| task.is_a?(Hash) && task.dig("vars", "container_health_service_name") }
        detect["vars"]["container_health_deploy_failure_message"] = ""
      end
    },
    expects: "the Bindery container health detection must be handed the deployment's own failure"
  },
  {
    name: "a recreate whose own failure message is thrown away",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          candidate.dig("ansible.builtin.set_fact", "bindery_recreate_failure_message")
        end
        task["ansible.builtin.set_fact"] = { "bindery_recreate_failed" => true }
      end
    },
    expects: "the Bindery force-recreate must catch its own failure"
  },
  {
    name: "a container health verdict handed no recreate failure",
    break: lambda { |root|
      role_tasks(root) do |document|
        verdict = document.select { |task| task.is_a?(Hash) && task.dig("vars", "container_health_service_name") }.last
        verdict["vars"]["container_health_deploy_failure_message"] = ""
      end
    },
    expects: "the Bindery container health verdict must be handed the recreate's own failure"
  },
  {
    name: "a verdict that never says the retry was spent",
    break: lambda { |root|
      role_tasks(root) do |document|
        verdict = document.select { |task| task.is_a?(Hash) && task.dig("vars", "container_health_service_name") }.last
        verdict["vars"].delete("container_health_retried")
      end
    },
    expects: "the Bindery container health verdict must say whether a recreate was spent"
  },
  {
    # Unconditional, this replaces the stack on every five-minute converge.
    name: "a force-recreate spent on every converge",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) { |candidate| candidate.dig("community.docker.docker_compose_v2", "recreate") }
        task.delete("when")
      end
    },
    expects: "the Bindery force-recreate must be conditional on a container actually being stuck"
  },
  {
    # --no-deps keeps a recovery from recreating a database beside the application.
    name: "a force-recreate that takes a stack's dependencies with it",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) { |candidate| candidate.dig("community.docker.docker_compose_v2", "recreate") }
        task["community.docker.docker_compose_v2"]["dependencies"] = true
      end
    },
    expects: "Bindery must force-recreate only the services Docker reports as stuck"
  },
  {
    name: "a second plain Bindery deployment",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          compose = candidate["community.docker.docker_compose_v2"]
          compose.is_a?(Hash) && compose["state"] == "present" && !compose.key?("recreate")
        end
        document.push(Marshal.load(Marshal.dump(task)))
      end
    },
    expects: "Bindery must deploy through docker_compose_v2"
  },
  {
    name: "a force-recreate spent twice in one converge",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) { |candidate| candidate.dig("community.docker.docker_compose_v2", "recreate") }
        document.push(Marshal.load(Marshal.dump(task)))
      end
    },
    expects: "Bindery must force-recreate a stuck container exactly once per converge"
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
    # Five failures per fifteen minutes per IP.
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
    # The contract tests with `include?`, so the break renames the fact rather
    # than appending to it (#293).
    name: "an outcome assertion that stops asserting the hardlinkable layout",
    break: lambda { |root|
      mutate_text(root, "roles/bindery/tasks/main.yml", "hardlinkable", "hard_linkable",
                  occurrences: 1)
    },
    expects: "Bindery verification must assert the hardlinkable staging layout"
  },
  {
    # #425: indexers come from Prowlarr's sync, so an empty sync empties every search.
    name: "an outcome assertion that stops asserting the synced indexers",
    break: lambda { |root|
      mutate_text(root, "roles/bindery/tasks/main.yml",
                  "selectattr('enabled')", "selectattr('excluded')", occurrences: 1)
    },
    expects: "Bindery verification must assert the synced indexers"
  },
  {
    # Sandboxes converge with an empty `media_arr_indexers` on purpose.
    name: "an indexer assertion gated on the transport rather than the declaration",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          candidate.dig("ansible.builtin.assert", "fail_msg").to_s
                   .include?("no enabled indexer")
        end
        task["when"] = ["media_usenet_enabled | bool"]
      end
    },
    expects: "the Bindery indexer assertion must be gated on the declared indexers"
  },
  {
    # Such an author's books read `wanted` but can never be grabbed.
    name: "an outcome assertion that stops asserting the author destinations",
    break: lambda { |root|
      mutate_text(root, "roles/bindery/tasks/main.yml",
                  "selectattr('rootFolderId', 'none')",
                  "selectattr('excluded', 'none')", occurrences: 1)
    },
    expects: "Bindery verification must assert the author destinations"
  },
  {
    name: "an outcome assertion that stops asserting the author quality profiles",
    break: lambda { |root|
      mutate_text(root, "roles/bindery/tasks/main.yml",
                  "selectattr('qualityProfileId', 'none')",
                  "selectattr('excluded', 'none')", occurrences: 1)
    },
    expects: "Bindery verification must assert the author quality profiles"
  },
  {
    # An author often has both an ebook and an audiobook edition.
    name: "an author default pinned to a profile that refuses one media type",
    break: lambda { |root|
      edit_yaml(root, "roles/bindery/defaults/main.yml") do |document|
        document["bindery_default_quality_profile_name"] = "E-Book"
      end
    },
    expects: "Bindery must default an author to the Any quality profile"
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
# The runtime half reads only its environment, so each row moves one env var,
# PATH stub or HTTP fixture answer.

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
  settings: { "autoGrab.enabled" => "true", "telemetry.enabled" => "false" },
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

# HttpFixtureSupport writes its third answer element into the Content-Type header
# line, so a response that also needs Set-Cookie states both headers there.
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
  # OMITTED rather than nil: the program's `fetch` default applies only when absent.
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
      # The same route is read anonymously (expecting a refusal) and with the key.
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
    # Distroless: the probe must be the binary's own subcommand.
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
    # local-only makes every private-network peer an administrator, who can read the key.
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
    # The seed is honoured only while the stored key is absent.
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
    # The distroless, unprivileged image cannot repair ownership.
    name: "a staging directory the container cannot write",
    given: { unwritable_dir: "download" },
    expects: "Bindery cannot write its download directory at /data/books/.acquisition/usenet/ebooks"
  },
  {
    # rename(2) and link(2) refuse to cross a mount boundary even on one filesystem,
    # so every import becomes a byte copy. The reason string is the diagnosis.
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
    # An absent row reads as enabled but is unowned, so a manual disable would stick.
    name: "an auto-grab row that is absent altogether",
    given: { settings: { "telemetry.enabled" => "false" } },
    expects: "Bindery does not pin autoGrab.enabled to true"
  },
  {
    name: "telemetry left on in the deployed settings",
    given: { settings: { "autoGrab.enabled" => "true", "telemetry.enabled" => "true" } },
    expects: "Bindery does not pin telemetry.enabled to false"
  },
  {
    # A repeated create answers 201 and adds a second row.
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
    # Credentials are write-only, so a key can be proved present, never correct.
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
# bindery.sh resolves both programs from its own checkout, so a copy of the three
# files is a working contract that can point at a broken fixture.

def with_contract_copy(static: File.read(STATIC_PROGRAM), runtime: File.read(RUNTIME_PROGRAM),
                       wrapper: File.read(CONTRACT), &block)
  with_contract_sandbox("bindery", wrapper, { "static" => static, "runtime" => runtime }, &block)
end

# Reports what each program saw on stdin and what the caller still has; neither
# program reads stdin today, so the redirect is only observable this way.
def stdin_failures(wrapper_source: File.read(CONTRACT))
  with_contract_copy(static: STDIN_PROBE, wrapper: wrapper_source) do |contract|
    stdin_probe_failures(contract, %w[static], { "PLATFORM_CONTRACT_REPO_DIR" => ROOT },
                         subject: "the static program")
  end
end

# The runtime half is reached by `exec`, after the static half succeeds.
def runtime_stdin_failures(wrapper_source: File.read(CONTRACT))
  with_contract_copy(runtime: STDIN_PROBE, wrapper: wrapper_source) do |contract, copy_root|
    environment = {
      "PLATFORM_CONTRACT_REPO_DIR" => copy_root,
      "PLATFORM_CONTRACT_VAULT_FILE" => File.join(copy_root, "vault.yml"),
      "PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" => File.join(copy_root, "vault-password"),
      "PLATFORM_DOCKER_ROOT" => File.join(copy_root, "docker")
    }
    # The shell's status is `cat`'s; the probe's marker proves the exec was reached,
    # and the static success line must not have printed.
    stdin_probe_failures(contract, %w[run], environment, prefix: "runtime stdin",
                         subject: "the runtime program", status: false) do |output|
      if output.include?(SUCCESS_LINE)
        "runtime stdin: run mode exited at the static gate instead of exec'ing: #{output.strip.inspect}"
      end
    end
  end
end

# Each name is refused with the wrapper's own message, never the shell's wording
# (bash and dash differ) or a line number.
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
      # Unparseable on purpose: bounds self-test plants that turn a `:?` guard into
      # `:=`, which would otherwise poll a closed port for 120 seconds.
      "PLATFORM_BINDERY_PORT" => "not-a-number"
    }
    REQUIRED_RUN_ENV.each do |name|
      # "" rather than deleted: ${VAR:?} refuses null too, and a developer may export it.
      stdout, stderr, status = Open3.capture3(full.merge(name => ""), contract, "run")
      output = stdout + stderr
      failures << "run env: #{name} unset was accepted" if status.success?
      failures << "run env: #{name} unset was not refused with the wrapper's own message: " \
                  "#{output.strip.inspect}" unless output.include?("#{name} is required")
    end

    # The Mac fallback branch: tests/mac/run.sh exports PLATFORM_MAC_VAULT_FILE.
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
    # `verify` became a mode in #773 and was replaced, not dropped, so the sweep
    # does not shrink; `upgrade` is a deliberate near-miss.
    %w[upgrade drift notify --platform].each do |mode|
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => ROOT }, contract, mode
      )
      failures << "wrapper: mode #{mode} was accepted" if status.success?
      failures << "wrapper: mode #{mode} was refused with exit #{status.exitstatus}, wanted 2" unless
        status.exitstatus == 2
      failures << "wrapper: mode #{mode} was refused without its diagnostic" unless
        (stdout + stderr).include?(MODE_REFUSAL)
    end

    # The upgrade lane's modes must pass the mode guard, failing instead on the
    # environment requirement rather than exit 2.
    %w[seed verify].each do |mode|
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => ROOT }, contract, mode
      )
      failures << "wrapper: upgrade mode #{mode} was accepted with no environment" if
        status.success?
      failures << "wrapper: upgrade mode #{mode} was refused by the mode guard" if
        (stdout + stderr).include?(MODE_REFUSAL)
      failures << "wrapper: upgrade mode #{mode} did not reach its environment requirements" unless
        (stdout + stderr).include?("PLATFORM_CONTRACT_VAULT_FILE is required")
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

  # The production path: PLATFORM_CONTRACT_REPO_DIR unset, one checkout for both.
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

# The two-roots property as an outcome; a capture diff cannot show what must
# stay identical (#251).
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

    # Opposite to Kapowarr: bindery-static.rb carries its own flatten_tasks, so a
    # raising tests/policy_support.rb in the inspected tree must be ignored.
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

# The runtime program's own two-roots row: the inspected tree here has no
# tests/contracts, so a rerooted $runtime_program cannot be found.
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
    label: "the candidate-pin review check",
    program: :static,
    from: "must read the candidate's pin under --check\" unless",
    to: "must read the candidate's pin under --check\" if false &&",
    rows: ["a pre-upgrade backup that reads current's pin under --check"]
  },
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
    # A substring search is satisfied by a second live assignment.
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
      !authored_passwords.include?(body["password"].to_s)',
    to: "false",
    rows: ["a probe submitting a password the platform expects to be refused"]
  },
  {
    label: "the unconditional Audiobookshelf reconciliation check",
    program: :static,
    from: 'abs_include && !abs_include.key?("when")',
    to: "true",
    rows: ["an Audiobookshelf integration gated behind a flag"]
  },
  {
    label: "the untouched Audiobookshelf credential check",
    program: :static,
    from: 'abs_repair && !abs_repair.dig("ansible.builtin.uri", "body").key?("apiKey")',
    to: "true",
    rows: ["an Audiobookshelf repair that rewrites the credential"]
  },
  {
    label: "the complete Audiobookshelf repair check",
    program: :static,
    from: '(abs_repair.dig("ansible.builtin.uri", "body").keys - %w[apiKey]).sort == declared_fields.sort',
    to: "true",
    rows: ["an Audiobookshelf repair that leaves the path remap alone"]
  },
  {
    label: "the Audiobookshelf write gating checks",
    program: :static,
    from: 'abs_declare && Array(abs_declare["when"]).join(" ").include?("bindery_abs_mint")',
    to: "true",
    rows: ["an Audiobookshelf declaration written on every converge"]
  },
  {
    label: "the Audiobookshelf repair gating check",
    program: :static,
    from: 'abs_repair && repair_conditions.include?("bindery_abs_drifted") &&
    repair_conditions.include?("not bindery_abs_mint")',
    to: "true",
    rows: ["an Audiobookshelf repair that runs beside the declaration"]
  },
  {
    label: "the non-expiring active key check",
    program: :static,
    from: 'mint_body.is_a?(Hash) && mint_body["isActive"] == true && !mint_body.key?("expiresIn")',
    to: "true",
    rows: ["an Audiobookshelf key minted inactive", "an Audiobookshelf key minted with an expiry"]
  },
  {
    label: "the mint-before-retire ordering check",
    program: :static,
    from: "abs_mint_index && abs_declare_index &&
      abs_retire_index > abs_mint_index && abs_retire_index > abs_declare_index",
    to: "true",
    rows: ["an Audiobookshelf key revoked before its replacement exists"]
  },
  {
    label: "the pre-mint retirement loop check",
    program: :static,
    from: 'abs_retire["loop"] == "{{ bindery_audiobookshelf_key_matches }}"',
    to: "true",
    rows: ["an Audiobookshelf retirement that re-reads the key list after minting"]
  },
  {
    label: "the Audiobookshelf retirement existence check",
    program: :static,
    from: 'failures << "Bindery must retire the superseded Audiobookshelf API key"',
    to: 'failures << "" if false',
    rows: ["an Audiobookshelf retirement that is gone"]
  },
  {
    label: "the stored-credential probe check",
    program: :static,
    from: 'abs_probe && abs_probe.dig("ansible.builtin.uri", "body") == {} &&
    abs_probe["changed_when"] == false && abs_probe["check_mode"] == false',
    to: "true",
    rows: ["a credential probe that sends a key of its own"]
  },
  {
    label: "the probe-answered mint decision check",
    program: :static,
    from: 'task.dig("ansible.builtin.set_fact", "bindery_abs_mint").to_s.include?("bindery_abs_probe")',
    to: "true",
    rows: ["a mint decision that trusts the two presence reads alone"]
  },
  {
    label: "the single Audiobookshelf library check",
    program: :static,
    from: 'task.to_s.include?("bindery_audiobookshelf_library_matches | length == 1")',
    to: "true",
    rows: ["an Audiobookshelf library resolved from whatever the name matched"]
  },
  {
    label: "the unambiguous Audiobookshelf key check",
    program: :static,
    from: 'task.to_s.include?("bindery_audiobookshelf_key_matches | length <= 1")',
    to: "true",
    rows: ["an ambiguous Audiobookshelf API key accepted rather than refused"]
  },
  {
    label: "the credential redaction check",
    program: :static,
    from: "credential_tasks.length >= 16 && credential_tasks.all? { |task| task[\"no_log\"] == true }",
    to: "true",
    rows: ["a credential-bearing request rendered in full"]
  },
  {
    label: "the container health pass existence check",
    program: :static,
    from: 'failures << "Bindery must detect and then refuse a container that runs but never serves" unless
    health_indexes.length == 2',
    to: 'failures << "" if false',
    rows: ["a deployment nothing checks the container state after"]
  },
  {
    label: "the container health bracketing check",
    program: :static,
    from: "cpu_index && deploy_index && recreate_index &&
      deploy_index < detect_index && detect_index < recreate_index &&
      recreate_index < verdict_index && verdict_index < cpu_index",
    to: "true",
    rows: ["a container health verdict that runs after the CPU verification"]
  },
  {
    label: "the deferred detection check",
    program: :static,
    from: 'detect["vars"]["container_health_refuse"] == false',
    to: "true",
    rows: ["a container health detection that refuses before the recreate can run"]
  },
  {
    label: "the refusing verdict check",
    program: :static,
    from: 'verdict["vars"].fetch("container_health_refuse", true) == true',
    to: "true",
    rows: ["a container health verdict that refuses nothing"]
  },
  {
    label: "the container health project check",
    program: :static,
    from: '[detect, verdict].all? do |pass|
        pass["vars"]["container_health_project_name"] == "{{ bindery_compose_project_name }}"
      end',
    to: "true",
    rows: ["a container health pass aimed at another Compose project"]
  },
  {
    label: "the caught deployment failure check",
    program: :static,
    from: 'deploy_block && flatten_tasks(deploy_block["rescue"]).any? do |task|
      task.dig("ansible.builtin.set_fact", "bindery_deploy_failure_message")
    end',
    to: "true",
    rows: ["a deployment whose own failure message is thrown away"]
  },
  {
    label: "the handed-on deployment failure check",
    program: :static,
    from: 'detect["vars"]["container_health_deploy_failure_message"]
            .to_s.include?("bindery_deploy_failure_message")',
    to: "true",
    rows: ["a container health detection handed no deployment failure"]
  },
  {
    label: "the caught recreate failure check",
    program: :static,
    from: 'recreate_block && flatten_tasks(recreate_block["rescue"]).any? do |task|
      task.dig("ansible.builtin.set_fact", "bindery_recreate_failure_message")
    end',
    to: "true",
    rows: ["a recreate whose own failure message is thrown away"]
  },
  {
    label: "the handed-on recreate failure check",
    program: :static,
    from: 'verdict["vars"]["container_health_deploy_failure_message"]
             .to_s.include?("bindery_recreate_failure_message")',
    to: "true",
    rows: ["a container health verdict handed no recreate failure"]
  },
  {
    label: "the spent-retry disclosure check",
    program: :static,
    from: 'verdict["vars"]["container_health_retried"].to_s.include?("bindery_recreate_spent")',
    to: "true",
    rows: ["a verdict that never says the retry was spent"]
  },
  {
    label: "the conditional force-recreate check",
    program: :static,
    from: 'recreate && recreate["when"].to_s.include?("container_health_stuck_services")',
    to: "true",
    rows: ["a force-recreate spent on every converge"]
  },
  {
    label: "the narrow force-recreate check",
    program: :static,
    from: 'recreate_options["recreate"] == "always" &&
    recreate_options["dependencies"] == false &&
    recreate_options["services"] == "{{ container_health_stuck_services }}"',
    to: "true",
    rows: ["a force-recreate that takes a stack's dependencies with it"]
  },
  {
    label: "the single deployment check",
    program: :static,
    from: 'compose_ups.count { |task| !task["community.docker.docker_compose_v2"].key?("recreate") } == 1',
    to: "true",
    rows: ["a second plain Bindery deployment"]
  },
  {
    label: "the single force-recreate check",
    program: :static,
    from: 'compose_ups.count { |task| task["community.docker.docker_compose_v2"]["recreate"] == "always" } == 1',
    to: "true",
    rows: ["a force-recreate spent twice in one converge"]
  },
  {
    label: "the readable recoverability guard check",
    program: :static,
    from: 'recovery_guard && !recovery_guard["no_log"]',
    to: "true",
    rows: ["a recoverability guard redacted away"]
  },
  {
    label: "the API-key classification existence check",
    program: :static,
    from: 'failures << "the Bindery API-key refusal must classify what its probes saw" unless
    key_classification',
    to: 'failures << "" if false',
    rows: ["an API-key refusal that classifies nothing"]
  },
  {
    label: "the API-key classification probe check",
    program: :static,
    from: 'classification.include?("#{probe}.status")',
    to: "true",
    rows: ["an API-key classification blind to the administrator login"]
  },
  {
    label: "the confined destructive remedy check",
    program: :static,
    from: 'destructive.keys == ["rejected-identity"]',
    to: "true",
    rows: ["a destructive remedy offered whatever the probes saw"]
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
  # No plant for `cookie.empty?`: removing it is caught downstream by "not holding
  # the vault-authored API key", and a row pinning that would freeze the redundancy.
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
    label: "the author reconciliation include check",
    program: :static,
    from: "author_include.nil?",
    to: "false",
    rows: ["author reconciliation dropped from the role"]
  },
  {
    label: "the null-only author repair check",
    program: :static,
    from: 'author_write["loop"] == "{{ bindery_authors_to_repair }}"',
    to: "true",
    rows: ["an author repair that writes every author"]
  },
  {
    label: "the pinned settings check",
    program: :runtime,
    from: "settings[key] == value",
    to: "true",
    rows: ["an auto-grab row that is absent altogether",
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

# The wrapper's regressions: lines that change no outcome today.
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
    from: "  static|run|seed|verify) ;;",
    to: "  static|run|seed|verify|upgrade|drift|notify|--platform) ;;",
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

if ARGV.include?("--self-test")
  mismatches = []

  # Plants are prepared before the pool: `abort` in a worker raises SystemExit
  # there, and the pool reports a KeyError instead of the sentence.
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
