#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Behaviour of the Kapowarr service contract's two Ruby programs.
#
# Until #147 both lived in `<<'RUBY'` heredocs inside tests/contracts/kapowarr.sh.
# `sh -n` reads a quoted heredoc as opaque text, so the static half was only ever
# executed by `tests/contracts/kapowarr.sh static` and the runtime half only by
# an integration lane with Docker, a converged Kapowarr and a real vault.
# tests/contracts/kapowarr-static.rb and tests/contracts/kapowarr-runtime.rb are
# files now, so both are reachable here.
#
# Three layers, because the contract has three kinds of property:
#
#   Static -- build a fixture repository from the files the program reads, break
#   exactly one thing in it, and require the program to name that thing. The
#   assertion text is the interface: a guard that fails for the wrong reason has
#   stopped guarding what it names, so every row pins the exact diagnostic. The
#   volume folder confinement properties are the reason this layer is worth its
#   length: the migration is the only mutation in this repository that moves a
#   directory inside a media library.
#
#   Runtime -- serve the Kapowarr API from an HTTP fixture and put `docker` and
#   `ansible-vault` stubs on PATH, so each access, ownership, settings and
#   persistence outcome can be moved one at a time. This half had no test at all.
#
#   Wrapper -- tests/contracts/kapowarr.sh is what turns a mode into an
#   invocation. Its rows prove the mode guard, the run-mode environment contract,
#   that both programs are reached, that they come from the checkout while the
#   tree they inspect does not, and that neither can eat the caller's stdin.
#
# BOTH halves read the inspected tree through PLATFORM_CONTRACT_REPO_DIR -- the
# static half requires its flatten_tasks out of tests/policy_support.rb, and the
# runtime half reads roles/kapowarr/defaults/main.yml to compare the deployed
# settings against the declared ones. So the two-roots layer has a runtime
# direction as well as a static one, which no other contract in this series has.
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
DIAGNOSTIC_PREFIX = "Kapowarr contract failed: "
CONTRACT = File.join(ROOT, "tests", "contracts", "kapowarr.sh")
STATIC_PROGRAM = File.join(ROOT, "tests", "contracts", "kapowarr-static.rb")
RUNTIME_PROGRAM = File.join(ROOT, "tests", "contracts", "kapowarr-runtime.rb")

SUCCESS_LINE = "kapowarr static contract: authenticated comics writer ownership holds"
MODE_REFUSAL = "kapowarr contract accepts only static or run"

# Exactly what the static program reads: its own `required` list plus the shared
# flatten_tasks it requires through PLATFORM_CONTRACT_REPO_DIR.
FIXTURE_FILES = %w[
  roles/kapowarr/defaults/main.yml
  roles/kapowarr/meta/argument_specs.yml
  roles/kapowarr/tasks/main.yml
  roles/kapowarr/templates/env.j2
  services/kapowarr/compose.yml
  services/kapowarr/compose.mac.yml
  services/kapowarr/compose.integration.yml
  inventory/group_vars/all/main.yml
  tests/policy_support.rb
].freeze

# Never more workers than cores. tests/validate-policy.sh already runs its checks
# concurrently, so oversubscribing a four-core CI runner trades wall time for
# contention.
CASE_WORKER_LIMIT = Integer(
  ENV.fetch("KAPOWARR_CONTRACT_CASE_WORKERS") { [Etc.nprocessors, 8].min.to_s }
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
#
# FIVE of the counts below are against roles/kapowarr/tasks/main.yml's migration
# and verification region: `item.folder is match` (2), `item.target is match`
# (2), `kapowarr_verify_volume_folder_drift` (5),
# `kapowarr_verify_rename_plans.results` (2) and `kapowarr_verify_volume_list`
# (3). Issue #268 is open against exactly that region's volume folder layout, so
# a change there makes this raise rather than mis-plant -- which is the point,
# but it surfaces as a RuntimeError from a worker thread rather than as a named
# row failure. Whoever lands #268 updates the counts here; that is a one-line
# fix, and this comment is what turns a mystery stack trace into it.
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
  edit_yaml(root, "services/kapowarr/compose.yml") { |d| yield d.fetch("services").fetch("kapowarr"), d }
end

def role_defaults(root)
  edit_yaml(root, "roles/kapowarr/defaults/main.yml") { |document| yield document }
end

def role_tasks(root)
  edit_yaml(root, "roles/kapowarr/tasks/main.yml") { |document| yield document }
end

# The flattened task list the program itself computes, so a row can find the task
# it means to break the same way the assertion finds it.
def flatten_tasks(tasks)
  Array(tasks).flat_map do |task|
    next [] unless task.is_a?(Hash)

    [task] + flatten_tasks(task["block"]) + flatten_tasks(task["rescue"]) + flatten_tasks(task["always"])
  end
end

def find_task(document, &predicate)
  flatten_tasks(document).find(&predicate)
end

def find_tasks(document, &predicate)
  flatten_tasks(document).select(&predicate)
end

def settings_write(document)
  find_task(document) do |task|
    task.dig("ansible.builtin.uri", "method") == "PUT" &&
      task.dig("ansible.builtin.uri", "url").to_s.include?("/api/settings") &&
      task.dig("ansible.builtin.uri", "body").to_s.include?("kapowarr_settings_declared")
  end
end

def folder_migration(document)
  find_task(document) do |task|
    body = task.dig("ansible.builtin.uri", "body")
    task.dig("ansible.builtin.uri", "method") == "PUT" && body.is_a?(Hash) &&
      body.key?("volume_folder")
  end
end

STATIC_ROWS = [
  { name: "an intact repository", break: ->(_root) {}, expects: nil },
  {
    name: "a declared file that is gone",
    break: ->(root) { FileUtils.rm(File.join(root, "services/kapowarr/compose.mac.yml")) },
    expects: "missing services/kapowarr/compose.mac.yml"
  },
  {
    # Kapowarr is declared self-contained in this slice: no Prowlarr indexer and
    # no download client are configured for it, so a seat on the shared control
    # network would make it reachable by every acquisition project for no
    # purpose.
    name: "a seat on the shared control network it has no use for",
    break: lambda { |root|
      compose_service(root) { |service, _| service["networks"] = %w[default media-control] }
    },
    expects: "Kapowarr must not join the shared media control network"
  },
  {
    # The entrypoint has to start as root to remap its own account, so `user:`
    # would stop the remap the platform identity depends on.
    name: "a container user override the entrypoint cannot remap around",
    break: ->(root) { compose_service(root) { |service, _| service["user"] = "${NAS_UID:?}" } },
    expects: "Kapowarr must not override the container user"
  },
  {
    name: "a PUID that is not the platform identity",
    break: ->(root) { compose_service(root) { |service, _| service["environment"]["PUID"] = "1000" } },
    expects: "Kapowarr must take the platform identity as PUID"
  },
  {
    # The leaf-per-directory layout this replaced, and the defect it carried:
    # rename(2) refuses to cross a mount boundary even when both sides are the
    # same filesystem, so a library and its staging directory in separate mounts
    # made every import a full byte copy plus unlink.
    name: "a mount per directory rather than one parent of the library and its staging",
    break: lambda { |root|
      compose_service(root) do |service, _|
        service["volumes"] = [
          "${KAPOWARR_CONFIG_PATH:?}:/app/db",
          "${KAPOWARR_DOWNLOADS_PATH:?}:/app/temp_downloads",
          "${KAPOWARR_COMICS_PATH:?}:/comics"
        ]
      end
    },
    expects: "Kapowarr must mount its database and one parent of its library and staging"
  },
  {
    name: "a web UI port the platform does not publish",
    break: ->(root) { compose_service(root) { |service, _| service["ports"] = ["15656:5656"] } },
    expects: "Kapowarr must publish the catalog web UI port"
  },
  {
    name: "a Mac override republishing a port the harness does not choose",
    break: lambda { |root|
      edit_yaml(root, "services/kapowarr/compose.mac.yml") do |document|
        document["services"]["kapowarr"]["ports"] = ["5656:5656"]
      end
    },
    expects: "the Mac override must republish the web UI on the harness port"
  },
  {
    # The runtime image ships neither curl nor wget, so a health probe written
    # against either would report unhealthy forever.
    name: "a health probe using an interpreter the image does not ship",
    break: lambda { |root|
      compose_service(root) do |service, _|
        service["healthcheck"]["test"] = ["CMD-SHELL", "curl -fsS http://127.0.0.1:5656/api/public"]
      end
    },
    expects: "the Kapowarr health probe must use the interpreter the image ships"
  },
  {
    name: "a bind source that is not the share the library and its staging share",
    break: lambda { |root|
      role_defaults(root) { |d| d["kapowarr_books_host_path"] = "{{ nas_media_root }}/Books/Comics" }
    },
    expects: "Kapowarr must mount the one host share its library and staging share"
  },
  {
    name: "a comics library root somewhere other than the declared one",
    break: lambda { |root|
      role_defaults(root) { |d| d["kapowarr_comics_host_path"] = "{{ nas_media_root }}/Comics" }
    },
    expects: "Kapowarr must write the declared comics library root"
  },
  {
    name: "a database declared outside the docker root",
    break: lambda { |root|
      role_defaults(root) { |d| d["kapowarr_config_host_path"] = "{{ nas_media_root }}/Books/.kapowarr" }
    },
    expects: "Kapowarr must keep its database in the declared config root"
  },
  {
    # The library moved out of the bind mount while the staging root stayed
    # inside it, which is the two-mount defect restated in container paths.
    name: "a library root outside the one bind mount the pair share",
    break: ->(root) { role_defaults(root) { |d| d["kapowarr_library_root"] = "/comics" } },
    expects: "the comics library must sit at /Comics inside the bind mount"
  },
  {
    # rename(2) refuses to cross a mount boundary, so staging outside the mount
    # the library is in turns every import back into a byte copy.
    name: "downloads staged outside the bind mount they import into",
    break: lambda { |root|
      role_defaults(root) { |d| d["kapowarr_staging_root"] = "/app/temp_downloads" }
    },
    expects: "the download staging root must sit at /.acquisition/usenet/comics inside the bind mount"
  },
  {
    # The container offset is only a real path if host_prep creates what it
    # resolves to. Kapowarr answers a download folder that is not a directory
    # with FolderNotFound, so an undeclared staging directory fails the converge
    # in a redacted request rather than here.
    name: "a staging offset resolving to a directory nas_storage does not declare",
    break: lambda { |root|
      edit_yaml(root, "inventory/group_vars/all/main.yml") do |document|
        document["nas_storage"].reject! do |entry|
          entry["path"] == "{{ nas_media_root }}/Books/.acquisition/usenet/comics"
        end
      end
    },
    expects: "the download staging root resolves to " \
             "{{ nas_media_root }}/Books/.acquisition/usenet/comics, " \
             "which nas_storage does not declare"
  },
  {
    # Kapowarr's own default is /app/temp_downloads, a directory inside the image
    # that the mount this replaced used to cover.
    name: "a download folder left at the application default the mount no longer covers",
    break: lambda { |root|
      role_defaults(root) { |d| d["kapowarr_settings"].delete("download_folder") }
    },
    expects: "Kapowarr must declare the download folder the parent mount moved"
  },
  {
    # The application force-suffixes the stored value, so a declaration without
    # the trailing separator reports drift on every converge and never converges.
    name: "a download folder declared without the separator the application stores",
    break: lambda { |root|
      role_defaults(root) do |d|
        d["kapowarr_settings"]["download_folder"] = d["kapowarr_staging_root"]
      end
    },
    expects: "Kapowarr must declare the download folder the parent mount moved"
  },
  {
    # The defect that reached CI: Ansible renders the reference and the role
    # converges, while the runtime half of this contract reads the same mapping
    # with a YAML parser and compares template text to a path. Correct on the
    # target, unequal in the check that proves the target holds it.
    name: "a declared setting written as a template the runtime comparison cannot render",
    break: lambda { |root|
      role_defaults(root) do |d|
        d["kapowarr_settings"]["download_folder"] = "{{ kapowarr_staging_root }}/"
      end
    },
    expects: "the declared Kapowarr settings must name values, not templates: download_folder"
  },
  {
    name: "an environment still exporting a leaf path a reintroduced mount would resolve",
    break: lambda { |root|
      mutate_text(root, "roles/kapowarr/templates/env.j2",
                  "KAPOWARR_BOOKS_PATH={{ kapowarr_books_host_path }}",
                  "KAPOWARR_BOOKS_PATH={{ kapowarr_books_host_path }}\n" \
                  "KAPOWARR_COMICS_PATH={{ kapowarr_comics_host_path }}")
    },
    expects: "Kapowarr env must export the host share as the single media bind source"
  },
  {
    # Restores the substring search the line-oriented read replaced, which is the
    # form a second live assignment satisfies while only one may exist.
    name: "a CPU set rendered twice",
    break: lambda { |root|
      mutate_text(root, "roles/kapowarr/templates/env.j2",
                  "PLATFORM_CONTAINER_CPUSET={{ platform_effective_container_cpuset }}",
                  "PLATFORM_CONTAINER_CPUSET={{ platform_effective_container_cpuset }}\n" \
                  "PLATFORM_CONTAINER_CPUSET=0-3")
    },
    expects: "Kapowarr env must render the CPU set exactly once"
  },
  {
    # Kapowarr reads no credential from its environment: every one lives in its
    # own database, so a credential here is a copy nothing consumes.
    name: "a vault credential copied into an environment nothing reads it from",
    break: lambda { |root|
      mutate_text(root, "roles/kapowarr/templates/env.j2",
                  "PLATFORM_CONTAINER_CPUSET={{ platform_effective_container_cpuset }}",
                  "PLATFORM_CONTAINER_CPUSET={{ platform_effective_container_cpuset }}\n" \
                  "KAPOWARR_ADMIN_PASSWORD={{ vault_kapowarr_admin_password }}")
    },
    expects: "the Kapowarr environment must carry no vault credential"
  },
  {
    name: "a deployment that is not docker_compose_v2",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) { |candidate| candidate.key?("community.docker.docker_compose_v2") }
        task["community.docker.docker_compose_v2"]["state"] = "absent"
      end
    },
    expects: "Kapowarr must deploy through docker_compose_v2"
  },
  {
    name: "a CPU policy check naming another service",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) { |c| c.dig("vars", "container_cpu_service_name") == "kapowarr" }
        task["vars"]["container_cpu_service_name"] = "bindery"
      end
    },
    expects: "Kapowarr must verify its effective project CPU policy"
  },
  {
    # The pair is submitted as a request body, which a module result renders in
    # full.
    name: "an administrator-bearing task rendered in full",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          candidate.to_s.match?(/vault_kapowarr_admin_(?:username|password)/) &&
            candidate["no_log"] == true
        end
        task.delete("no_log")
      end
    },
    expects: "every Kapowarr task naming the administrator must use no_log"
  },
  {
    # Kapowarr validates a ComicVine key against comicvine.gamespot.com before it
    # will store one, so submitting it would make every converge depend on a
    # third party.
    name: "a request submitting the ComicVine credential to a third party",
    break: lambda { |root|
      role_tasks(root) do |document|
        document.push(
          "name" => "Submit the ComicVine credential",
          "ansible.builtin.uri" => {
            "url" => "{{ kapowarr_api }}/api/settings",
            "method" => "PUT",
            "body" => { "comicvine_api_key" => "{{ vault_kapowarr_comicvine_api_key }}" }
          },
          "no_log" => true
        )
      end
    },
    expects: "no Kapowarr request may submit the ComicVine credential"
  },
  {
    name: "an authored ComicVine credential nothing guards the shape of",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          candidate.key?("ansible.builtin.assert") &&
            candidate.to_s.include?("vault_kapowarr_comicvine_api_key")
        end
        document.delete(task)
      end
    },
    expects: "Kapowarr must still guard the shape of the authored ComicVine credential"
  },
  {
    name: "a world-readable environment render",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) { |c| c.dig("ansible.builtin.template", "src") == "env.j2" }
        task["ansible.builtin.template"]["mode"] = "0644"
      end
    },
    expects: "the Kapowarr environment render must be private"
  },
  {
    # The settings interface accepts anything, so an ungated identity write would
    # rewrite the login on every converge and never report a converged state.
    name: "an identity write that rewrites the login on every converge",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          candidate.dig("ansible.builtin.uri", "method") == "PUT" &&
            candidate.to_s.include?("auth_password")
        end
        task["when"] = ["not ansible_check_mode"]
      end
    },
    expects: "the Kapowarr identity write must be gated on the deployed identity"
  },
  {
    name: "a credential key list that does not name every masked credential",
    break: lambda { |root|
      role_defaults(root) { |d| d["kapowarr_settings_credential_keys"] = %w[api_key auth_username] }
    },
    expects: "the Kapowarr credential key list must name every masked credential"
  },
  {
    # Kapowarr masks every stored credential on read -- both halves of the
    # administrator identity answer as literal asterisks -- so a declaration
    # naming one could never match what comes back, and the write would run on
    # every converge.
    name: "a settings declaration naming a credential the service masks on read",
    break: lambda { |root|
      role_defaults(root) { |d| d["kapowarr_settings"]["api_key"] = "0" * 32 }
    },
    expects: "the declared Kapowarr settings must name no credential: api_key"
  },
  {
    # The application validates the order as a permutation of its own service
    # list, so it is declared as a partial ordering and merged over the deployed
    # order instead of being written into the settings declaration.
    name: "a settings declaration carrying the download service order",
    break: lambda { |root|
      role_defaults(root) { |d| d["kapowarr_settings"]["service_preference"] = %w[GetComics] }
    },
    expects: "the declared Kapowarr settings must not carry the service order"
  },
  {
    # Komga indexes the directory these name, so a change that drops them hands a
    # second service's view of the library back to the web interface.
    name: "a settings declaration that stops owning the library naming templates",
    break: ->(root) { role_defaults(root) { |d| d["kapowarr_settings"].delete("volume_folder_naming") } },
    expects: "the declared Kapowarr settings must own the library naming templates"
  },
  {
    name: "no declared download service order at all",
    break: ->(root) { role_defaults(root) { |d| d["kapowarr_service_preference"] = [] } },
    expects: "Kapowarr must declare its download service order"
  },
  {
    # The read carries the API key in its query string and is a read: it must be
    # redacted, must not claim a change, and must really run under --check, or
    # the write decides from nothing.
    name: "a settings read that does not really run under --check",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          candidate.dig("ansible.builtin.uri", "method") == "GET" &&
            candidate.dig("ansible.builtin.uri", "url").to_s.include?("/api/settings") &&
            !Array(candidate["tags"]).include?("platform_verify_kapowarr")
        end
        task.delete("check_mode")
      end
    },
    expects: "the Kapowarr settings read must be a redacted, real, changeless read"
  },
  {
    # The interface answers a no-op write and a real write identically, so the
    # write has to be gated on a difference computed before it.
    name: "a settings write that reports a change on every converge",
    break: lambda { |root|
      role_tasks(root) { |document| settings_write(document)["when"] = ["not ansible_check_mode"] }
    },
    expects: "the Kapowarr settings write must be gated on the resolved drift"
  },
  {
    name: "a settings write rendered in full",
    break: ->(root) { role_tasks(root) { |document| settings_write(document).delete("no_log") } },
    expects: "the Kapowarr settings write must stay redacted"
  },
  {
    # The volume folder migration is the only mutation in this repository that
    # moves a directory inside a media library, and the one the operator reviews
    # with --check --diff before it runs.
    name: "a volume folder migration pinned open",
    break: lambda { |root|
      role_defaults(root) { |d| d["kapowarr_volume_folder_migration_allowed"] = true }
    },
    expects: "the Kapowarr volume folder migration must be pinned closed"
  },
  {
    # And pinned closed at the layer that decides the run: group_vars/all
    # outranks the role defaults the row above breaks, so a true left behind
    # here would move directories on every converge (#343).
    name: "a volume folder migration pinned open in the inventory",
    break: lambda { |root|
      mutate_text(root, "inventory/group_vars/all/main.yml",
                  "kapowarr_volume_folder_migration_allowed: false",
                  "kapowarr_volume_folder_migration_allowed: true")
    },
    expects: "the Kapowarr volume folder migration must be pinned closed in the inventory"
  },
  {
    name: "a volume folder migration input that is not a declared bool",
    break: lambda { |root|
      edit_yaml(root, "roles/kapowarr/meta/argument_specs.yml") do |document|
        document["argument_specs"]["main"]["options"]["kapowarr_volume_folder_migration_allowed"]["type"] =
          "str"
      end
    },
    expects: "the Kapowarr volume folder migration input must be a declared bool"
  },
  {
    name: "a volume folder move an ordinary converge can reach",
    break: lambda { |root|
      role_tasks(root) { |document| folder_migration(document)["when"] = ["not ansible_check_mode"] }
    },
    expects: "the Kapowarr volume folder move must be gated on the one-convergence input"
  },
  {
    # A volume marked as carrying an operator-chosen folder is one Kapowarr stops
    # re-deriving, so the next template change would converge silently wrong.
    name: "a volume folder move that names the folder rather than deriving it",
    break: lambda { |root|
      role_tasks(root) do |document|
        folder_migration(document)["ansible.builtin.uri"]["body"]["volume_folder"] = "{{ item.target }}"
      end
    },
    expects: "the Kapowarr volume folder move must take the derived folder"
  },
  {
    # The plan is read from the application's own rename preview, and that read
    # must really run under --check, or the review reports nothing.
    name: "a rename plan read that does not really run under --check",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_tasks(document) do |candidate|
          candidate.dig("ansible.builtin.uri", "url").to_s.include?("/rename?api_key=")
        end.first
        task.delete("check_mode")
      end
    },
    expects: "must be a redacted, real, changeless read"
  },
  {
    # Naming the comics library among the paths the role touches is what runs
    # deployment_bundle's containment check against it -- a symlink between the
    # media root and the library would otherwise let a rename follow the link out
    # of the tree.
    name: "a comics library the role does not name among the paths it touches",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) { |c| c.dig("vars", "deployment_target_service") == "kapowarr" }
        task["vars"]["deployment_target_extra_paths"] =
          Array(task.dig("vars", "deployment_target_extra_paths")) -
          ["{{ kapowarr_comics_host_path }}"]
      end
    },
    expects: "Kapowarr must name the comics library among the paths it touches"
  },
  {
    # Two occurrences, both replaced: the migration plan's own `when` and the
    # negated copy in the unconfined-volume resolution. An unscoped `sub` would
    # have hit whichever came first and reported a pass either way, which is why
    # every substitution here states its count.
    name: "a migration plan that does not confine the folder it moves from",
    break: lambda { |root|
      mutate_text(root, "roles/kapowarr/tasks/main.yml", "item.folder is match",
                  "item.folder is defined", occurrences: 2)
    },
    expects: "the Kapowarr migration plan must confine the folder it moves from"
  },
  {
    name: "a migration plan that does not confine the folder it moves to",
    break: lambda { |root|
      mutate_text(root, "roles/kapowarr/tasks/main.yml", "item.target is match",
                  "item.target is defined", occurrences: 2)
    },
    expects: "the Kapowarr migration plan must confine the folder it moves to"
  },
  {
    # A silent exclusion is indistinguishable from a converged library.
    name: "unconfined volume folders dropped rather than named",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          candidate.key?("ansible.builtin.debug") &&
            candidate["loop"].to_s.include?("kapowarr_volume_folders_unconfined")
        end
        document.delete(task)
      end
    },
    expects: "Kapowarr must report each volume folder it refuses as unconfined"
  },
  {
    # The request names no path, so the folder it installs is the one Kapowarr
    # derives from the root folder that *volume* is attached to. That is the
    # declared root only while Kapowarr owns exactly the declared one.
    name: "a second library root that does not refuse the migration",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          candidate.key?("ansible.builtin.assert") &&
            Array(candidate.dig("ansible.builtin.assert", "that")).any? do |value|
              value.to_s.include?("kapowarr_root_folders") &&
                value.to_s.include?("kapowarr_library_root")
            end
        end
        document.delete(task)
      end
    },
    expects: "a second Kapowarr library root must refuse the volume folder migration"
  },
  {
    name: "a library root refusal that runs after the move",
    break: lambda { |root|
      role_tasks(root) do |document|
        refusal = find_task(document) do |candidate|
          candidate.key?("ansible.builtin.assert") &&
            Array(candidate.dig("ansible.builtin.assert", "that")).any? do |value|
              value.to_s.include?("kapowarr_root_folders") &&
                value.to_s.include?("kapowarr_library_root")
            end
        end
        document.delete(refusal)
        document.push(refusal)
      end
    },
    expects: "the Kapowarr library root refusal must precede the volume folder move"
  },
  {
    name: "a review that does not report the folder each volume would move to",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          candidate.key?("ansible.builtin.debug") &&
            candidate["loop"].to_s.include?("kapowarr_volume_folder_migrations")
        end
        task["ansible.builtin.debug"]["msg"] = ["only the folder it holds: {{ item.folder }}"]
      end
    },
    expects: "Kapowarr must report each volume folder it would move"
  },
  {
    # Kapowarr v1.3.1 can relabel no stored prefix whose files no longer resolve,
    # so a deployment holding the superseded one has to fail the run. Without the
    # plan there is nothing for the refusal to read.
    name: "no reading of the library roots the declared one supersedes",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          candidate.dig("ansible.builtin.set_fact")&.key?("kapowarr_library_root_migrations")
        end
        task["ansible.builtin.set_fact"].delete("kapowarr_library_root_migrations")
        task["ansible.builtin.set_fact"]["kapowarr_library_root_unused"] = "[]"
      end
    },
    expects: "Kapowarr must resolve the library roots the declared one supersedes"
  },
  {
    # The mutation the refusal exists to prevent: without it the role declares
    # the new root beside the superseded one and reports success over a library
    # no volume is attached to.
    name: "a superseded library root the run converges around",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          candidate.key?("ansible.builtin.assert") &&
            candidate.to_s.include?("kapowarr_library_root_migrations")
        end
        document.delete(task)
      end
    },
    expects: "a superseded Kapowarr library root must refuse the run"
  },
  {
    # A one-convergence input here would authorize a migration Kapowarr cannot
    # perform, and would end in a second root folder and a failed verification.
    name: "a superseded library root refusal a one-convergence input can open",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          candidate.key?("ansible.builtin.assert") &&
            candidate.to_s.include?("kapowarr_library_root_migrations")
        end
        task["ansible.builtin.assert"]["that"] <<
          "kapowarr_library_root_migration_allowed | bool"
      end
    },
    expects: "the superseded library root refusal must take no one-convergence input"
  },
  {
    # The empty library the web interface shows is the directory Kapowarr itself
    # created on read, so an operator not told the comics are intact reaches for
    # a restore.
    name: "a refusal that does not say the comics on the host are intact",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          candidate.key?("ansible.builtin.assert") &&
            candidate.to_s.include?("kapowarr_library_root_migrations")
        end
        task["ansible.builtin.assert"]["fail_msg"] =
          "Kapowarr holds a library root this platform does not declare."
      end
    },
    expects: "the superseded library root refusal must say the host library is intact"
  },
  {
    # Worthless after the fact: the create is the mutation it prevents.
    name: "a superseded library root refusal that runs after the root folder create",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          candidate.key?("ansible.builtin.assert") &&
            candidate.to_s.include?("kapowarr_library_root_migrations")
        end
        document.delete(task)
        create = find_task(document) do |candidate|
          candidate.dig("ansible.builtin.uri", "method") == "POST" &&
            candidate.dig("ansible.builtin.uri", "url").to_s.include?("/api/rootfolder")
        end
        document.insert(document.index(create) + 1, task)
      end
    },
    expects: "the superseded library root refusal must precede the root folder create"
  },
  {
    # Kapowarr records a credential-free auth POST as a failed login, so an
    # ungated probe writes a WARNING into the application's own security log on
    # every converge and buries a real attempt among its own.
    name: "an anonymous login probe not gated on the mode already read",
    break: lambda { |root|
      role_tasks(root) do |document|
        find_tasks(document) do |candidate|
          candidate.dig("ansible.builtin.uri", "url") == "{{ kapowarr_api }}/api/auth" &&
            candidate.dig("ansible.builtin.uri", "body") == {}
        end.each { |task| task["when"] = ["not ansible_check_mode"] }
      end
    },
    expects: "must be gated on the authentication mode already read"
  },
  {
    name: "verification that never reads the unauthenticated public endpoint",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          Array(candidate["tags"]).include?("platform_verify_kapowarr") &&
            candidate.dig("ansible.builtin.uri", "url") == "{{ kapowarr_api }}/api/public"
        end
        task["ansible.builtin.uri"]["url"] = "{{ kapowarr_api }}/api/health"
      end
    },
    expects: "Kapowarr verification must read its unauthenticated public endpoint"
  },
  {
    name: "verification that never authenticates as the vault administrator",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          Array(candidate["tags"]).include?("platform_verify_kapowarr") &&
            candidate.dig("ansible.builtin.uri", "body", "password") ==
              "{{ vault_kapowarr_admin_password }}"
        end
        task["ansible.builtin.uri"]["body"]["password"] = "{{ kapowarr_settings_api_key }}"
      end
    },
    expects: "Kapowarr verification must authenticate as the vault administrator"
  },
  {
    name: "verification that never reads the library roots it owns",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          Array(candidate["tags"]).include?("platform_verify_kapowarr") &&
            candidate.dig("ansible.builtin.uri", "url").to_s.include?("/api/rootfolder")
        end
        task["ansible.builtin.uri"]["url"] = "{{ kapowarr_api }}/api/public"
      end
    },
    expects: "Kapowarr verification must read the library roots it owns"
  },
  {
    name: "a probe that pins a status instead of deferring to the assertion",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          Array(candidate["tags"]).include?("platform_verify_kapowarr") &&
            candidate.dig("ansible.builtin.uri", "url").to_s.include?("/api/rootfolder")
        end
        task["ansible.builtin.uri"]["status_code"] = [200]
      end
    },
    expects: "must accept any status and defer to the assertion"
  },
  {
    name: "an outcome assertion that stops asserting the refused anonymous caller",
    break: lambda { |root|
      mutate_text(root, "roles/kapowarr/tasks/main.yml",
                  "kapowarr_verify_anonymous.status", "kapowarr_verify_anonymous.attempted")
    },
    expects: "Kapowarr verification must assert its exact access and ownership outcomes"
  },
  {
    name: "an outcome assertion redacted away",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          Array(candidate["tags"]).include?("platform_verify_kapowarr") &&
            candidate.key?("ansible.builtin.assert")
        end
        task["no_log"] = true
      end
    },
    expects: "the Kapowarr outcome assertion must stay readable"
  },
  {
    # A volume added while a hand-edited template was in force, or a folder
    # renamed in the web interface, puts a series back under a name Komga titles
    # wrongly, and nothing in Kapowarr reports it. The migration alone would fix
    # the library once and go quiet.
    name: "verification that never asserts every volume folder is the derived one",
    break: lambda { |root|
      mutate_text(root, "roles/kapowarr/tasks/main.yml",
                  "kapowarr_verify_volume_folder_drift", "kapowarr_verify_folder_drift",
                  occurrences: 5)
    },
    expects: "Kapowarr verification must assert every volume folder is the derived one"
  },
  {
    # The drift list is resolved from a loop over what the application reported,
    # so an empty list is a real verdict only when both reads answered for every
    # volume. Without that floor a 401 verifies a library of nothing.
    name: "a drift assertion with no floor under the reads it derives from",
    break: lambda { |root|
      mutate_text(root, "roles/kapowarr/tasks/main.yml",
                  "kapowarr_verify_rename_plans.results", "kapowarr_verify_rename_plans.attempted",
                  occurrences: 2)
    },
    expects: "the Kapowarr volume folder assertion must require both reads to have answered"
  },
  {
    # An unauthorized Kapowarr answers `result: {}` where the library was, and a
    # loop over that mapping dies with a type error instead of with the
    # assertion's diagnosis.
    name: "a per-volume verification read looping the raw response",
    break: lambda { |root|
      mutate_text(root, "roles/kapowarr/tasks/main.yml",
                  "kapowarr_verify_volume_list", "kapowarr_verify_volumes.json.result",
                  occurrences: 3)
    },
    expects: "the Kapowarr verification must loop a normalized volume list"
  },
  {
    name: "a verification read that claims a change",
    break: lambda { |root|
      role_tasks(root) do |document|
        task = find_task(document) do |candidate|
          Array(candidate["tags"]).include?("platform_verify_kapowarr") &&
            candidate.key?("ansible.builtin.uri")
        end
        task.delete("changed_when")
      end
    },
    expects: "Kapowarr verification reads must not claim a change"
  }
].freeze

def static_failures(program, rows = STATIC_ROWS)
  failures = []
  in_parallel_cases(failures, rows) do |row, collected|
    Dir.mktmpdir("nas-platform-kapowarr-static.") do |raw|
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
# The runtime half takes NO arguments: every input arrives in the environment,
# and one of those inputs is the INSPECTED tree, from which it reads
# roles/kapowarr/defaults/main.yml. So the sandbox is a fixture repository as
# well as an HTTP fixture and two PATH stubs.
#
# One pre-existing weakness, deliberately NOT pinned: the runtime half reads that
# defaults file with YAML.safe_load_file and no existence check of its own. The
# static half's `required` list covers it on any invocation that goes through the
# wrapper, but the program run bare against a tree lacking the file dies with
# Errno::ENOENT rather than with a diagnostic. A row expecting that stack trace
# would freeze it, and this change moves code. Where the row would go: beside "a
# declaration the INSPECTED tree makes and the deployment does not hold".

ADMIN = "nasadmin"
PASSWORD = "kapowarr-contract-admin-password"
API_KEY = "a1b2c3d4e5f60718293a4b5c6d7e8f90"
LIBRARY_ROOT = "/data/books/Comics"

DECLARED_SETTINGS = YAML.safe_load_file(
  File.join(ROOT, "roles", "kapowarr", "defaults", "main.yml")
).fetch("kapowarr_settings").freeze
DECLARED_ORDER = YAML.safe_load_file(
  File.join(ROOT, "roles", "kapowarr", "defaults", "main.yml")
).fetch("kapowarr_service_preference").freeze

RUNTIME_DEFAULTS = {
  public_body: nil,
  authentication_method: 2,
  inspect_ok: true,
  health: "healthy",
  vault_ok: true,
  anonymous_code: 401,
  wrong_password_code: 401,
  login_code: 200,
  api_key: API_KEY,
  roots_code: 200,
  root_folders: [LIBRARY_ROOT],
  settings_code: 200,
  settings_overrides: {},
  service_preference: nil,
  database: true,
  # The inspected tree's own declaration, which is what the program must read.
  # A row that changes this and leaves the served settings alone is the only
  # signal that separates the two roots at the `exec` site.
  declared_overrides: {}
}.freeze

def vault_document
  { "vault_kapowarr_admin_username" => ADMIN, "vault_kapowarr_admin_password" => PASSWORD }
end

def build_runtime_sandbox(root, options)
  bin = File.join(root, "bin")
  FileUtils.mkdir_p(bin)
  docker_root = File.join(root, "docker")
  database = File.join(docker_root, "kapowarr", "config", "Kapowarr.db")
  FileUtils.mkdir_p(File.dirname(database))
  File.write(database, "sqlite-fixture-bytes") if options.fetch(:database)

  build_fixture_repository(root)
  unless options.fetch(:declared_overrides).empty?
    role_defaults(root) { |d| d["kapowarr_settings"].merge!(options.fetch(:declared_overrides)) }
  end

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

def runtime_responder(options)
  lambda do |method, target, _headers, body|
    path = target.split("?").first
    case [method, path]
    when %w[GET /api/public]
      next [200, options.fetch(:public_body)] if options.fetch(:public_body)

      [200, JSON.generate("result" => { "authentication_method" =>
                                          options.fetch(:authentication_method) })]
    when %w[POST /api/auth]
      payload = begin
        JSON.parse(body.to_s)
      rescue JSON::ParserError
        {}
      end
      next [options.fetch(:anonymous_code), "{}"] if payload.empty?
      next [options.fetch(:wrong_password_code), "{}"] unless payload["password"] == PASSWORD
      next [options.fetch(:login_code), "{}"] unless options.fetch(:login_code) == 200

      [200, JSON.generate("result" => { "api_key" => options.fetch(:api_key) })]
    when %w[GET /api/rootfolder]
      next [options.fetch(:roots_code), "{}"] unless options.fetch(:roots_code) == 200

      [200, JSON.generate("result" => options.fetch(:root_folders).map { |f| { "folder" => f } })]
    when %w[GET /api/settings]
      next [options.fetch(:settings_code), "{}"] unless options.fetch(:settings_code) == 200

      document = DECLARED_SETTINGS.merge(options.fetch(:settings_overrides))
      document = document.merge(
        "service_preference" => options.fetch(:service_preference) || DECLARED_ORDER
      )
      [200, JSON.generate("result" => document)]
    else [404, "{}"]
    end
  end
end

RUNTIME_ROWS = [
  { name: "a converged Kapowarr", given: {}, expects: nil },
  {
    # A service the deployed version knows and the declaration does not is free
    # to sit anywhere: filtering both lists by the other is what makes this a
    # statement about order rather than about membership.
    name: "a deployed order carrying a service the declaration does not name",
    given: { service_preference: ["Mega", "MediaFire", "Torbox", "WeTransfer", "Pixeldrain",
                                 "GetComics", "GetComics (torrent)"] },
    expects: nil
  },
  {
    name: "a public endpoint that does not answer JSON",
    given: { public_body: "not json" },
    expects: "Kapowarr public endpoint did not answer JSON"
  },
  {
    # 1 accepts any username against the password and 0 is no login at all, so
    # anything below 2 is an open writer.
    name: "an authentication mode that accepts any username",
    given: { authentication_method: 1 },
    expects: "Kapowarr does not enforce the username and password pair"
  },
  {
    name: "an authentication mode with no login at all",
    given: { authentication_method: 0 },
    expects: "Kapowarr does not enforce the username and password pair"
  },
  {
    name: "a container Docker cannot inspect",
    given: { inspect_ok: false },
    expects: "the Kapowarr container could not be inspected"
  },
  {
    name: "a container Docker calls unhealthy",
    given: { health: "starting" },
    expects: "the Kapowarr container is not healthy"
  },
  {
    name: "a vault that cannot be read",
    given: { vault_ok: false },
    expects: "encrypted vault could not be read"
  },
  {
    # A successful login is what hands out the API key that authorizes every
    # route that renames or deletes comics.
    name: "a login accepted with no credential at all",
    given: { anonymous_code: 200 },
    expects: "Kapowarr logged in a caller with no credential"
  },
  {
    name: "a login accepted with a wrong password",
    given: { wrong_password_code: 200 },
    expects: "Kapowarr logged in a caller with a wrong password"
  },
  {
    name: "an administrator the deployment refuses",
    given: { login_code: 403 },
    expects: "Kapowarr refused the vault-authored administrator"
  },
  {
    name: "a login that hands back no API key",
    given: { api_key: nil },
    expects: "Kapowarr returned no API key to the vault administrator"
  },
  {
    name: "an API key that is not the shape Kapowarr issues",
    given: { api_key: "not-a-32-hex-key" },
    expects: "Kapowarr returned no API key to the vault administrator"
  },
  {
    name: "library roots the service refuses to list",
    given: { roots_code: 401 },
    expects: "Kapowarr refused to list its library roots"
  },
  {
    # The migration installs the folder Kapowarr derives from the root folder the
    # volume is attached to, so a second root makes that derivation ambiguous.
    name: "a second library root beside the declared one",
    given: { root_folders: [LIBRARY_ROOT, "/data/books/Comics-archive"] },
    expects: "Kapowarr does not own exactly the declared comics library root"
  },
  {
    name: "a library root with a trailing slash",
    given: { root_folders: ["#{LIBRARY_ROOT}/"] },
    expects: nil
  },
  {
    name: "state that did not land in the declared config root",
    given: { database: false },
    expects: "Kapowarr did not persist its database in the declared config root"
  },
  {
    name: "settings the service refuses to report",
    given: { settings_code: 401 },
    expects: "Kapowarr refused to report its settings"
  },
  {
    # Komga indexes the directory this names, so a template the application does
    # not hold hands a second service's view of the library back to whoever
    # edited it in the web interface.
    name: "a naming template the application does not hold",
    given: { settings_overrides: { "volume_folder_naming" => "{series_name}/Volume {volume_number}" } },
    expects: "Kapowarr does not hold the declared application settings: volume_folder_naming"
  },
  {
    name: "a download service order the application reordered",
    given: { service_preference: DECLARED_ORDER.reverse },
    expects: "Kapowarr does not hold the declared download service order"
  },
  {
    # The runtime half's own two-roots row, and the only signal that separates
    # the two roots at the `exec` site: the INSPECTED tree declares a template
    # the served settings do not hold. Reading the checkout's declaration instead
    # would make this row pass, silently.
    name: "a declaration the INSPECTED tree makes and the deployment does not hold",
    given: { declared_overrides: { "volume_folder_naming" => "{series_name} INSPECTED-TREE" } },
    expects: "Kapowarr does not hold the declared application settings: volume_folder_naming"
  }
].freeze

def runtime_failures(program, rows = RUNTIME_ROWS)
  failures = []
  in_parallel_cases(failures, rows) do |row, collected|
    options = RUNTIME_DEFAULTS.merge(row.fetch(:given))
    Dir.mktmpdir("nas-platform-kapowarr-runtime.") do |raw|
      root = File.realpath(raw)
      bin, docker_root = build_runtime_sandbox(root, options)
      HttpFixtureSupport.with_http_fixture(
        lambda do |port|
          stdout, stderr, status = Open3.capture3(
            {
              "PATH" => "#{bin}:#{ENV.fetch('PATH')}",
              "PLATFORM_KAPOWARR_PORT" => port.to_s,
              "PLATFORM_KAPOWARR_CONTAINER" => "fixture-kapowarr",
              "PLATFORM_DOCKER_ROOT" => docker_root,
              "PLATFORM_CONTRACT_REPO_DIR" => root,
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
  Dir.mktmpdir("nas-platform-kapowarr-wrapper.") do |raw|
    root = File.realpath(raw)
    build_fixture_repository(root)
    contracts = File.join(root, "tests", "contracts")
    FileUtils.mkdir_p(contracts)
    wrapper_path = File.join(contracts, "kapowarr.sh")
    File.write(wrapper_path, wrapper)
    File.chmod(0o755, wrapper_path)
    File.write(File.join(contracts, "kapowarr-static.rb"), static)
    File.write(File.join(contracts, "kapowarr-runtime.rb"), runtime)
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
      # polls a closed port for 120 seconds.
      "PLATFORM_KAPOWARR_PORT" => "not-a-number"
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
    FileUtils.rm(File.join(copy_root, "services/kapowarr/compose.mac.yml"))
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
      (stdout + stderr).include?("missing services/kapowarr/compose.mac.yml")
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

    FileUtils.rm(File.join(copy_root, "services/kapowarr/compose.mac.yml"))
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => nil }, contract, "static"
    )
    failures << "wrapper: with no repository named, static mode inspected some other tree" if
      status.success?
    failures << "wrapper: with no repository named, static mode did not report the broken tree" unless
      (stdout + stderr).include?("missing services/kapowarr/compose.mac.yml")
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
    Dir.mktmpdir("nas-platform-kapowarr-tworoots.") do |raw|
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
    Dir.mktmpdir("nas-platform-kapowarr-support.") do |raw|
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

# The runtime PROGRAM's own root, which needs a layer of its own.
# runtime_stdin_failures points PLATFORM_CONTRACT_REPO_DIR at the contract copy,
# so the checkout and the inspected tree ARE the same directory there and a
# rerooted $runtime_program resolves to the same file. Here the inspected tree is
# a separate fixture with no tests/contracts at all, so a reroot cannot find the
# program at all.
def runtime_program_root_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  with_contract_copy(runtime: STDIN_PROBE, wrapper: wrapper_source) do |contract|
    Dir.mktmpdir("nas-platform-kapowarr-program-root.") do |raw|
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
      failures << "runtime program root: the runtime program was not reached out of the " \
                  "checkout: #{output.strip.inspect}" unless output.include?('probe read ""')
    end
  end
  failures
end

# The runtime half's own two-roots direction, which no other contract in this
# series has: kapowarr-runtime.rb reads roles/kapowarr/defaults/main.yml through
# the SAME export, past the `exec`. The inspected tree declares a naming template
# the served settings do not hold, and the deployment must be refused for naming
# exactly that template. Rerooting the export to the checkout would make this row
# pass, and no local signal but this one would notice.
def runtime_two_roots_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  options = RUNTIME_DEFAULTS.merge(
    declared_overrides: { "volume_folder_naming" => "{series_name} INSPECTED-TREE" }
  )
  with_contract_copy(wrapper: wrapper_source) do |contract|
    Dir.mktmpdir("nas-platform-kapowarr-runtime-roots.") do |raw|
      inspected = File.realpath(raw)
      bin, docker_root = build_runtime_sandbox(inspected, options)
      HttpFixtureSupport.with_http_fixture(
        lambda do |port|
          stdout, stderr, status = Open3.capture3(
            {
              "PATH" => "#{bin}:#{ENV.fetch('PATH')}",
              "PLATFORM_CONTRACT_REPO_DIR" => inspected,
              "PLATFORM_KAPOWARR_PORT" => port.to_s,
              "PLATFORM_DOCKER_ROOT" => docker_root,
              "PLATFORM_CONTRACT_VAULT_FILE" => File.join(inspected, "vault.yml"),
              "PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" => File.join(inspected, "vault-password")
            },
            contract, "run"
          )
          output = stdout + stderr
          failures << "runtime two roots: the deployment was accepted, so the runtime program " \
                      "read some other tree's declaration: #{output.strip.inspect}" if status.success?
          failures << "runtime two roots: the declaration did not come from the inspected tree: " \
                      "#{output.strip.inspect}" unless
            output.include?("does not hold the declared application settings: volume_folder_naming")
        end,
        &runtime_responder(options)
      )
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
    label: "the control-network abstention check",
    program: :static,
    from: 'compose.key?("networks") || service.key?("networks")',
    to: "false",
    rows: ["a seat on the shared control network it has no use for"]
  },
  {
    label: "the container-user abstention check",
    program: :static,
    from: 'service.key?("user")',
    to: "false",
    rows: ["a container user override the entrypoint cannot remap around"]
  },
  {
    label: "the exact mount set check",
    program: :static,
    from: 'Array(service["volumes"]) == [
      "${KAPOWARR_CONFIG_PATH:?}:/app/db",
      "${KAPOWARR_BOOKS_PATH:?}:/data/books"
    ]',
    to: "true",
    rows: ["a mount per directory rather than one parent of the library and its staging"]
  },
  {
    label: "the shipped-interpreter health probe check",
    program: :static,
    from: 'health.include?("python3") && health.include?("/api/public")',
    to: "true",
    rows: ["a health probe using an interpreter the image does not ship"]
  },
  {
    label: "the exactly-once CPU set read",
    program: :static,
    # Restores the substring search the line-oriented read replaced, which is the
    # form a second live assignment satisfies while only one may exist.
    from: 'env_assignments.select { |name, _value| name == "PLATFORM_CONTAINER_CPUSET" } ==
      [["PLATFORM_CONTAINER_CPUSET", "{{ platform_effective_container_cpuset }}"]]',
    to: 'File.read(File.join(root, "roles/kapowarr/templates/env.j2"))
      .include?("PLATFORM_CONTAINER_CPUSET={{ platform_effective_container_cpuset }}")',
    rows: ["a CPU set rendered twice"]
  },
  {
    label: "the no-credential environment check",
    program: :static,
    from: 'env_assignments.any? { |_name, value| value.include?("vault_") }',
    to: "false",
    rows: ["a vault credential copied into an environment nothing reads it from"]
  },
  {
    label: "the ComicVine submission refusal",
    program: :static,
    from: "comicvine_requests.empty?",
    to: "true",
    rows: ["a request submitting the ComicVine credential to a third party"]
  },
  {
    label: "the credential-naming settings refusal",
    program: :static,
    from: "named_credentials.empty?",
    to: "true",
    rows: ["a settings declaration naming a credential the service masks on read"]
  },
  {
    label: "the service-order exclusion check",
    program: :static,
    from: 'declared_settings.key?("service_preference")',
    to: "false",
    rows: ["a settings declaration carrying the download service order"]
  },
  {
    label: "the naming template ownership check",
    program: :static,
    from: '(%w[volume_folder_naming file_naming] - declared_settings.keys).empty?',
    to: "true",
    rows: ["a settings declaration that stops owning the library naming templates"]
  },
  {
    label: "the drift-gated settings write check",
    program: :static,
    from: 'settings_write && settings_conditions.include?("kapowarr_settings_drift_keys") &&
    settings_conditions.include?("ansible_check_mode")',
    to: "true",
    rows: ["a settings write that reports a change on every converge"]
  },
  {
    label: "the pinned-closed migration check",
    program: :static,
    from: 'defaults.fetch("kapowarr_volume_folder_migration_allowed", nil) == false',
    to: "true",
    rows: ["a volume folder migration pinned open"]
  },
  {
    label: "the pinned-closed migration inventory check",
    program: :static,
    from: '    YAML.safe_load_file(File.join(root, "inventory/group_vars/all/main.yml"))
        .fetch("kapowarr_volume_folder_migration_allowed", false) == false',
    to: "    true",
    rows: ["a volume folder migration pinned open in the inventory"]
  },
  {
    label: "the declared-bool migration input check",
    program: :static,
    from: 'migration_option.is_a?(Hash) && migration_option["type"] == "bool"',
    to: "true",
    rows: ["a volume folder migration input that is not a declared bool"]
  },
  {
    label: "the one-convergence migration gate",
    program: :static,
    from: 'folder_migration &&
    migration_conditions.include?("kapowarr_volume_folder_migration_allowed") &&
    migration_conditions.include?("ansible_check_mode")',
    to: "true",
    rows: ["a volume folder move an ordinary converge can reach"]
  },
  {
    label: "the derived-folder check",
    program: :static,
    from: 'migration_body["volume_folder"].nil? && migration_body["custom_folder"] == false',
    to: "true",
    rows: ["a volume folder move that names the folder rather than deriving it"]
  },
  {
    label: "the named comics library check",
    program: :static,
    from: 'Array(target_paths).include?("{{ kapowarr_comics_host_path }}")',
    to: "true",
    rows: ["a comics library the role does not name among the paths it touches"]
  },
  {
    label: "the source-folder confinement check",
    program: :static,
    from: 'value.to_s.include?("item.folder is match") &&
        value.to_s.include?("kapowarr_library_root | regex_escape")',
    to: "true",
    rows: ["a migration plan that does not confine the folder it moves from"]
  },
  {
    label: "the target-folder confinement check",
    program: :static,
    from: 'value.to_s.include?("item.target is match") &&
        value.to_s.include?("kapowarr_library_root | regex_escape")',
    to: "true",
    rows: ["a migration plan that does not confine the folder it moves to"]
  },
  {
    label: "the unconfined-volume report check",
    program: :static,
    from: "unconfined_report.nil?",
    to: "false",
    rows: ["unconfined volume folders dropped rather than named"]
  },
  {
    label: "the second-root refusal check",
    program: :static,
    from: 'root_refusal &&
    Array(root_refusal["when"]).join(" ").include?("kapowarr_volume_folder_migrations")',
    to: "true",
    rows: ["a second library root that does not refuse the migration"]
  },
  {
    label: "the refusal-before-move ordering check",
    program: :static,
    from: "tasks.index(root_refusal) < tasks.index(folder_migration)",
    to: "true",
    rows: ["a library root refusal that runs after the move"]
  },
  {
    label: "the anonymous-probe gate check",
    program: :static,
    from: 'probe_conditions.include?("authentication_method") && probe_conditions.include?("2")',
    to: "true",
    rows: ["an anonymous login probe not gated on the mode already read"]
  },
  # No plant for the drift-assertion PRESENCE check, deliberately. It cannot be
  # broken alone: the floor check two lines below it is written
  # `folder_assertion && folder_conditions.include?(...)`, so an absent assertion
  # fails that one too. Removing `folder_assertion.nil?` therefore leaves the
  # break caught by "the Kapowarr volume folder assertion must require both reads
  # to have answered" rather than by its own sentence -- which is also why the
  # row above reports two diagnostics rather than one. The redundancy is the
  # program's, not this test's, and a row expecting the floor sentence would
  # freeze it. Reported in the PR, not fixed: this change moves code.
  {
    label: "the answered-reads floor check",
    program: :static,
    from: 'folder_assertion && folder_conditions.include?("kapowarr_verify_volumes.status") &&
    folder_conditions.include?("kapowarr_verify_rename_plans.results")',
    to: "true",
    rows: ["a drift assertion with no floor under the reads it derives from"]
  },
  {
    label: "the normalized volume list check",
    program: :static,
    from: 'task["loop"].to_s.include?("kapowarr_verify_volume_list")',
    to: "true",
    rows: ["a per-volume verification read looping the raw response"]
  },
  {
    label: "the changeless verification read check",
    program: :static,
    from: '(task["changed_when"] == false && task["check_mode"] == false)',
    to: "true",
    rows: ["a verification read that claims a change"]
  },
  {
    label: "the username-and-password mode check",
    program: :runtime,
    from: 'document.dig("result", "authentication_method") == 2',
    to: "true",
    rows: ["an authentication mode that accepts any username",
           "an authentication mode with no login at all"]
  },
  {
    label: "the healthy-container check",
    program: :runtime,
    from: 'state.strip == "healthy"',
    to: "true",
    rows: ["a container Docker calls unhealthy"]
  },
  {
    label: "the credential-free login refusal",
    program: :runtime,
    from: 'post("/api/auth", {}).code == "401"',
    to: "true",
    rows: ["a login accepted with no credential at all"]
  },
  {
    label: "the wrong-password login refusal",
    program: :runtime,
    from: 'post("/api/auth", "username" => username, "password" => "contract-wrong-password").code == "401"',
    to: "true",
    rows: ["a login accepted with a wrong password"]
  },
  {
    label: "the issued API key shape check",
    program: :runtime,
    from: 'api_key.is_a?(String) && api_key.match?(/\A[0-9a-f]{32}\z/)',
    to: "true",
    rows: ["a login that hands back no API key",
           "an API key that is not the shape Kapowarr issues"]
  },
  {
    label: "the exactly-one-library-root check",
    program: :runtime,
    from: "declared == [LIBRARY_ROOT]",
    to: "true",
    rows: ["a second library root beside the declared one"]
  },
  {
    label: "the persisted database check",
    program: :runtime,
    from: "File.file?(DATABASE) && File.size?(DATABASE)",
    to: "true",
    rows: ["state that did not land in the declared config root"]
  },
  {
    label: "the declared settings comparison",
    program: :runtime,
    from: "deployed_settings[key] == value",
    to: "true",
    rows: ["a naming template the application does not hold",
           "a declaration the INSPECTED tree makes and the deployment does not hold"]
  },
  {
    label: "the partial download service order check",
    program: :runtime,
    from: 'deployed_order.select { |service| declared_order.include?(service) } ==
    declared_order.select { |service| deployed_order.include?(service) }',
    to: "true",
    rows: ["a download service order the application reordered"]
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
    from: "static_program=$contract_repo_dir/tests/contracts/kapowarr-static.rb",
    to: "static_program=$repo_dir/tests/contracts/kapowarr-static.rb",
    layer: :two_roots
  },
  {
    label: "the runtime program resolved from the inspected tree",
    from: "runtime_program=$contract_repo_dir/tests/contracts/kapowarr-runtime.rb",
    to: "runtime_program=$repo_dir/tests/contracts/kapowarr-runtime.rb",
    layer: :runtime_program_root
  },
  {
    # BOTH assignments, because both are live: the first is what the static half
    # reads and the second is a verbatim repeat the pre-cut wrapper carried. A
    # plant on only one leaves the other in force, which is exactly the
    # unscoped-substitution failure hazard 9 names.
    label: "the inspected-tree export rerooted to the checkout",
    from: "PLATFORM_CONTRACT_REPO_DIR=$repo_dir",
    to: "PLATFORM_CONTRACT_REPO_DIR=$contract_repo_dir",
    occurrences: 2,
    layer: :two_roots
  },
  {
    label: "the inspected-tree export rerooted for the runtime half only",
    from: "PLATFORM_KAPOWARR_CONTAINER=${PLATFORM_PROJECT_NAME:+$PLATFORM_PROJECT_NAME-}kapowarr\nPLATFORM_CONTRACT_REPO_DIR=$repo_dir",
    to: "PLATFORM_KAPOWARR_CONTAINER=${PLATFORM_PROJECT_NAME:+$PLATFORM_PROJECT_NAME-}kapowarr\nPLATFORM_CONTRACT_REPO_DIR=$contract_repo_dir",
    layer: :runtime_two_roots
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

def plant(source, mutation)
  from = mutation.fetch(:from)
  occurrences = mutation.fetch(:occurrences, 1)
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
    Dir.mktmpdir("nas-platform-kapowarr-mutant.") do |directory|
      name = mutation.fetch(:program) == :static ? "kapowarr-static.rb" : "kapowarr-runtime.rb"
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
             when :runtime_two_roots then runtime_two_roots_failures(wrapper_source: source)
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

  puts "kapowarr contract: self-test detects #{planted} planted regressions"
  exit
end

failures = static_failures(STATIC_PROGRAM) + runtime_failures(RUNTIME_PROGRAM) +
           wrapper_failures + run_env_failures + stdin_failures + runtime_stdin_failures +
           two_roots_failures + runtime_program_root_failures + runtime_two_roots_failures
unless failures.empty?
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} Kapowarr contract violation(s)"
end

puts "kapowarr contract: #{STATIC_ROWS.length} static and #{RUNTIME_ROWS.length} runtime properties " \
     "hold, both halves read the inspected tree while both programs come from the checkout, and " \
     "the run-mode environment contract refuses each name with the wrapper's own message"
