#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Behaviour of the Seafile service contract's two Ruby programs and its wrapper.
#
# Three layers, because the contract has three kinds of property:
#
#   Static -- build a fixture repository from the files the program reads, break
#   exactly one thing in it, and require the program to name that thing. The
#   assertion text is the interface: a guard that fails for the wrong reason has
#   stopped guarding what it names, so every row pins the exact diagnostic.
#
#   Runtime -- serve Seafile's API from an HTTP fixture and put `docker` and
#   `ansible-vault` stubs on PATH, so every census, path, index, database, token
#   and cache outcome can be moved one at a time. Both runtime modes are covered
#   here: `run`, which a registry sweep reaches, and `restart-persistence`, which
#   only the seafile lane invokes.
#
#   Wrapper -- tests/contracts/seafile.sh is what turns a mode into an
#   invocation. Its rows prove the mode guard, that the mode reaches the runtime
#   half, the run-mode environment contract, that both programs come from the
#   checkout while the tree the static half inspects does not, and that neither
#   can eat the caller's stdin.
#
# Run with --self-test to plant a regression in each program and in the wrapper.
# It accumulates its mismatches rather than aborting on the first, and every
# plant is built before the worker pool: `abort` inside a worker raises
# SystemExit there, and the pool would report a KeyError in place of the message.
#
# On the cost of this file, which CLAUDE.md's `static` budget section is about:
# every invocation that must end in a refusal by the wrapper substitutes a stub
# for the runtime half, and every invocation that reaches the real runtime half
# carries each of its timeout budgets in its own environment. Nothing here is
# entitled to wait -- a row whose expected outcome is a refusal has no reason to
# sit out a readiness budget, and that shape is exactly what cost the seerr
# self-test 368 seconds before #331.

require "etc"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "shellwords"
require "tmpdir"
require "uri"
require "yaml"

require_relative "case_pool_support"
require_relative "http_fixture_support"
require_relative "policy_support"

include TestScaffold

ROOT = File.expand_path("..", __dir__)
# The prefix every refusal this file judges has to carry. Matching the fragment
# alone accepted a backtrace or an echoed argument as a refusal (#352).
DIAGNOSTIC_PREFIX = "Seafile contract failed: "
CONTRACT = File.join(ROOT, "tests", "contracts", "seafile.sh")
STATIC_PROGRAM = File.join(ROOT, "tests", "contracts", "seafile-static.rb")
RUNTIME_PROGRAM = File.join(ROOT, "tests", "contracts", "seafile-runtime.rb")

SUCCESS_LINE = "seafile static contract: gated three-container file store ownership holds"
# The rehearsal's own fixed names, spelled here rather than imported, because
# the point of pinning them is that a rename in the runtime program has to be a
# deliberate edit in two places rather than a silently passing test.
REHEARSAL_LIBRARY = "nas-platform-restore-rehearsal"
REHEARSAL_FILE = "restore-rehearsal.txt"
REHEARSAL_CONTENT = "nas-platform seafile restore rehearsal payload\n"
REHEARSAL_REPO = "fixture-repo-id"
MODE_REFUSAL = "seafile contract accepts only static, run, restart-persistence, "\
               "restore-rehearsal-seed or restore-rehearsal-assert"

# Exactly the static program's own `required` list plus the shared
# flatten_tasks it requires through PLATFORM_CONTRACT_REPO_DIR. tests/contracts/
# seafile.sh is in it because the static half reads the wrapper's default port
# out of the inspected tree and compares it with that tree's role default.
FIXTURE_FILES = %w[
  roles/seafile/defaults/main.yml
  roles/seafile/meta/argument_specs.yml
  roles/seafile/tasks/main.yml
  roles/seafile/tasks/storage.yml
  roles/seafile/tasks/deploy.yml
  roles/seafile/tasks/pre_upgrade_backup.yml
  roles/seafile/tasks/recover_wedged_boot.yml
  roles/seafile/tasks/reconcile_seafevents.yml
  roles/seafile/tasks/reconcile_quota.yml
  roles/seafile/tasks/report.yml
  roles/seafile/tasks/verify.yml
  roles/seafile/templates/env.j2
  roles/seafile/templates/backup_manifest.j2
  services/seafile/compose.yml
  services/seafile/compose.mac.yml
  services/seafile/compose.integration.yml
  tests/expected/seafile.yml
  tests/contracts/seafile.sh
  inventory/group_vars/all/main.yml
  tests/policy_support.rb
  roles/beszel/defaults/main.yml
].freeze

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

def edit_seafile_tasks(root, file)
  edit_yaml(root, "roles/seafile/tasks/#{file}.yml") { |document| yield document }
end

def compose_service(document, name)
  document.fetch("services").fetch(name)
end

# The role's deployment and its wedged-boot recovery live inside block/rescue,
# so a row that reaches for one of those tasks cannot use `document.find`: the
# task is not at the document's top level. This is the same descent
# tests/policy_support.rb's flatten_tasks performs, restated here because the
# rows mutate the parsed document in place and need the very objects
# YAML.dump will write back.
def nested_tasks(tasks, flattened = [])
  Array(tasks).each do |task|
    next unless task.is_a?(Hash)

    flattened << task
    %w[block rescue always].each { |section| nested_tasks(task[section], flattened) }
  end
  flattened
end

STATIC_ROWS = [
  { name: "an intact repository", break: ->(_root) {}, expects: nil },
  {
    name: "a declared file that is gone",
    break: ->(root) { FileUtils.rm(File.join(root, "services/seafile/compose.mac.yml")) },
    expects: "missing services/seafile/compose.mac.yml"
  },
  {
    name: "an image pinned by tag alone",
    break: lambda { |root|
      edit_yaml(root, "services/seafile/compose.yml") do |document|
        compose_service(document, "db")["image"] = "docker.io/library/mariadb:10.11.19"
      end
    },
    expects: "the Seafile db image must pin docker.io/library/mariadb by tag and manifest digest"
  },
  {
    name: "a CPU ceiling that drifted from the expected file",
    break: lambda { |root|
      edit_yaml(root, "services/seafile/compose.yml") do |document|
        compose_service(document, "cache")["cpus"] = 1.5
      end
    },
    expects: "each Seafile container must take the CPU ceiling tests/expected/seafile.yml declares"
  },
  {
    name: "a renamed production container",
    break: lambda { |root|
      edit_yaml(root, "services/seafile/compose.yml") do |document|
        compose_service(document, "cache")["container_name"] = "seafile-valkey"
      end
    },
    expects: "each Seafile container must carry its production name"
  },
  {
    name: "two overrides that disagree about a sandbox container",
    break: lambda { |root|
      edit_yaml(root, "services/seafile/compose.mac.yml") do |document|
        compose_service(document, "cache")["container_name"] = "${PLATFORM_PROJECT_NAME:?}-seafile-valkey"
      end
    },
    expects: "both disposable Seafile overrides must name the same three sandbox containers"
  },
  {
    name: "a database published on the network",
    break: lambda { |root|
      edit_yaml(root, "services/seafile/compose.yml") do |document|
        compose_service(document, "db")["ports"] = ["3306:3306"]
      end
    },
    expects: "only the Seafile server may publish a port"
  },
  {
    name: "a volume bound to a literal host path",
    break: lambda { |root|
      edit_yaml(root, "services/seafile/compose.yml") do |document|
        compose_service(document, "seafile")["volumes"] = ["/volume1/Docker/seafile/data:/shared"]
      end
    },
    expects: "every Seafile volume source must be a required environment reference"
  },
  {
    name: "a container Dozzle cannot group",
    break: lambda { |root|
      edit_yaml(root, "services/seafile/compose.yml") do |document|
        compose_service(document, "cache")["labels"].delete("dev.dozzle.group")
      end
    },
    expects: "every Seafile container must carry its Dozzle group and name"
  },
  {
    name: "a database probe that goes green mid-upgrade",
    break: lambda { |root|
      edit_yaml(root, "services/seafile/compose.yml") do |document|
        compose_service(document, "db")["healthcheck"]["test"] =
          ["CMD", "/usr/local/bin/healthcheck.sh", "--connect", "--innodb_initialized"]
      end
    },
    expects: "the Seafile database probe must stay red through an in-place upgrade"
  },
  {
    name: "a server started against a database that is merely up",
    break: lambda { |root|
      edit_yaml(root, "services/seafile/compose.yml") do |document|
        compose_service(document, "seafile")["depends_on"]["db"]["condition"] = "service_started"
      end
    },
    expects: "the Seafile server must wait for a healthy database and cache"
  },
  {
    name: "a cache provider that is not the Redis protocol",
    break: lambda { |root|
      edit_yaml(root, "services/seafile/compose.yml") do |document|
        compose_service(document, "seafile")["environment"]["CACHE_PROVIDER"] = "memcached"
      end
    },
    expects: "Seafile must take its cache from the Redis protocol provider"
  },
  {
    name: "a server logging into its own volume",
    break: lambda { |root|
      edit_yaml(root, "services/seafile/compose.yml") do |document|
        compose_service(document, "seafile")["environment"]["SEAFILE_LOG_TO_STDOUT"] = "false"
      end
    },
    expects: "Seafile must log to stdout where Dozzle can read it"
  },
  {
    name: "a server that cannot chown its own bind mount",
    break: lambda { |root|
      edit_yaml(root, "services/seafile/compose.yml") do |document|
        compose_service(document, "seafile")["environment"]["NON_ROOT"] = "true"
      end
    },
    expects: "Seafile must keep the root-then-drop entrypoint its bind mount needs"
  },
  {
    name: "a second owner declared for the Seafile schemas",
    break: lambda { |root|
      edit_yaml(root, "services/seafile/compose.yml") do |document|
        compose_service(document, "db")["environment"]["MYSQL_DATABASE"] = "seafile_db"
      end
    },
    expects: "the Seafile database must not declare a second owner of its schemas"
  },
  {
    name: "a role that no longer imports every stage",
    break: lambda { |root|
      edit_seafile_tasks(root, "main") do |document|
        document.reject! { |task| task["ansible.builtin.import_tasks"] == "storage.yml" }
      end
    },
    expects: "the Seafile role must import every stage it owns"
  },
  {
    name: "a reconciliation that runs before the deployment writes the file",
    break: lambda { |root|
      edit_seafile_tasks(root, "main") do |document|
        reconcile = document.find { |task| task["ansible.builtin.import_tasks"] == "reconcile_seafevents.yml" }
        document.delete(reconcile)
        document.insert(0, reconcile)
      end
    },
    expects: "both Seafile reconciliations must run after the deployment, quota before events"
  },
  {
    name: "a teardown that leaves the containers a revision no longer declares",
    break: lambda { |root|
      edit_seafile_tasks(root, "deploy") do |document|
        task = document.find { |candidate| candidate.dig("community.docker.docker_compose_v2", "state") == "absent" }
        task["community.docker.docker_compose_v2"].delete("remove_orphans")
      end
    },
    expects: "the disabled Seafile project must be torn down rather than left running"
  },
  {
    name: "a deployment that ignores the operator switch",
    break: lambda { |root|
      edit_seafile_tasks(root, "deploy") do |document|
        task = nested_tasks(document).find do |candidate|
          candidate.dig("community.docker.docker_compose_v2", "state") == "present" &&
            candidate["name"] == "Deploy Seafile"
        end
        task["when"] = "not ansible_check_mode"
      end
    },
    expects: "every Seafile deployment task must be gated on the operator switch"
  },
  {
    name: "a database probe over the container's own socket",
    break: lambda { |root|
      mutate_text(root, "roles/seafile/tasks/deploy.yml",
                  "exec env MYSQL_PWD=\"$MYSQL_ROOT_PASSWORD\" mariadb --protocol=tcp",
                  "exec env MYSQL_PWD=\"$MYSQL_ROOT_PASSWORD\" mariadb --protocol=socket")
    },
    expects: "the Seafile database probe must authenticate over TCP as root"
  },
  {
    name: "an event repair applied line by line",
    break: lambda { |root|
      edit_seafile_tasks(root, "reconcile_seafevents") do |document|
        task = document.find { |candidate| candidate.dig("vars", "seafile_seafevents_assignment") }
        task["vars"]["seafile_seafevents_assignment"] = '(?ms)^({{ item.key }}\s*=\s*)[^\r\n]*'
      end
    },
    expects: "the Seafile event repair must be bounded to the section of the setting it repairs"
  },
  {
    name: "an event report that reads the first matching key in the file",
    break: lambda { |root|
      edit_seafile_tasks(root, "reconcile_seafevents") do |document|
        task = document.find { |candidate| candidate.dig("vars", "seafile_seafevents_capture") }
        task["vars"]["seafile_seafevents_capture"] = '(?ms)^{{ item.key }}\s*=\s*([^\r\n]*)'
      end
    },
    expects: "the Seafile event report must read the section of the setting it reports"
  },
  {
    name: "a repair that owns one hardcoded setting rather than the declared list",
    break: lambda { |root|
      edit_seafile_tasks(root, "reconcile_seafevents") do |document|
        task = document.find { |candidate| candidate.dig("vars", "seafile_seafevents_assignment") }
        task.delete("loop")
        task.delete("loop_control")
      end
    },
    expects: "the Seafile event reconciliation must loop over its declared settings"
  },
  {
    name: "an audit log left to whatever the image happens to default to",
    break: lambda { |root|
      edit_yaml(root, "roles/seafile/defaults/main.yml") do |document|
        document["seafile_seafevents_managed_settings"] =
          document["seafile_seafevents_managed_settings"].reject { |setting| setting["section"] == "AUDIT" }
      end
    },
    expects: "this platform must own [INDEX FILES] enabled and [AUDIT] enabled"
  },
  {
    name: "an owned event setting that names no value",
    break: lambda { |root|
      edit_yaml(root, "roles/seafile/defaults/main.yml") do |document|
        document["seafile_seafevents_managed_settings"].first.delete("value")
      end
    },
    expects: "every owned Seafile event setting must name its section, key and value"
  },
  {
    name: "an audit log switched off",
    break: lambda { |root|
      edit_yaml(root, "roles/seafile/defaults/main.yml") do |document|
        document["seafile_audit_log_enabled"] = false
      end
    },
    expects: "this platform must own the Seafile audit log as switched on"
  },
  {
    name: "a quota spelled the way a human writes it rather than the way seaf-server parses it",
    break: lambda { |root|
      edit_yaml(root, "roles/seafile/defaults/main.yml") do |document|
        document["seafile_default_user_quota"] = "20 gigabytes"
      end
    },
    expects: "the Seafile quota must be spelled the way seaf-server parses it"
  },
  {
    name: "a quota written without the refusal that would have caught a bad one",
    break: lambda { |root|
      edit_seafile_tasks(root, "reconcile_quota") do |document|
        document.reject! { |task| task.key?("ansible.builtin.assert") }
      end
    },
    expects: "the Seafile quota must be refused before it is written"
  },
  {
    name: "a quota in a block nothing marks as this platform's",
    break: lambda { |root|
      edit_seafile_tasks(root, "reconcile_quota") do |document|
        task = document.find { |candidate| candidate.key?("ansible.builtin.blockinfile") }
        task["ansible.builtin.blockinfile"]["marker"] = "# {mark} ANSIBLE MANAGED BLOCK"
      end
    },
    expects: "the Seafile quota must be written as one owned block"
  },
  {
    name: "a quota that declares the mode of a file it did not read",
    break: lambda { |root|
      edit_seafile_tasks(root, "reconcile_quota") do |document|
        task = document.find { |candidate| candidate.key?("ansible.builtin.blockinfile") }
        task["ansible.builtin.blockinfile"]["mode"] = "0644"
      end
    },
    expects: "the Seafile quota must not claim a literal mode"
  },
  {
    name: "a quota repair that renders the database password into the transcript",
    break: lambda { |root|
      edit_seafile_tasks(root, "reconcile_quota") do |document|
        task = document.find { |candidate| candidate.key?("ansible.builtin.blockinfile") }
        task["no_log"] = false
      end
    },
    expects: "the Seafile server configuration carries a database password and must be redacted"
  },
  {
    name: "a quota repair nothing reloads",
    break: lambda { |root|
      edit_seafile_tasks(root, "reconcile_seafevents") do |document|
        task = document.find { |candidate| candidate.dig("community.docker.docker_compose_v2", "state") == "restarted" }
        task["when"] = task["when"].map do |value|
          value.to_s.include?("seafile_server_config_repair") ? "seafile_seafevents_repair is changed" : value
        end
      end
    },
    expects: "the restart must also carry the repaired Seafile quota policy"
  },
  {
    name: "a quota reconciliation ordered after the restart it depends on",
    break: lambda { |root|
      edit_seafile_tasks(root, "main") do |document|
        quota = document.find { |task| task["ansible.builtin.import_tasks"] == "reconcile_quota.yml" }
        events = document.find { |task| task["ansible.builtin.import_tasks"] == "reconcile_seafevents.yml" }
        document.delete(quota)
        document.insert(document.index(events) + 1, quota)
      end
    },
    expects: "both Seafile reconciliations must run after the deployment, quota before events"
  },
  {
    name: "an unbounded file store with no disk alert behind it",
    break: lambda { |root|
      edit_yaml(root, "roles/beszel/defaults/main.yml") do |document|
        document["beszel_alerts"] = document["beszel_alerts"].reject { |alert| alert["name"] == "Disk" }
      end
    },
    expects: "Seafile's unbounded growth must leave a managed Beszel disk alert behind it"
  },
  {
    name: "a restart that bounces the database with the server",
    break: lambda { |root|
      edit_seafile_tasks(root, "reconcile_seafevents") do |document|
        task = document.find { |candidate| candidate.dig("community.docker.docker_compose_v2", "state") == "restarted" }
        task["community.docker.docker_compose_v2"]["dependencies"] = true
      end
    },
    expects: "the repaired Seafile event configuration must be restarted into the running server"
  },
  {
    name: "a restart deferred to a handler",
    break: lambda { |root|
      FileUtils.mkdir_p(File.join(root, "roles/seafile/handlers"))
      File.write(File.join(root, "roles/seafile/handlers/main.yml"), "---\n[]\n")
    },
    expects: "the Seafile restart must be a task rather than a deferred handler"
  },
  {
    name: "a wedged-boot recreate that bounces the database with the server",
    break: lambda { |root|
      edit_seafile_tasks(root, "recover_wedged_boot") do |document|
        task = nested_tasks(document).find do |candidate|
          candidate.dig("community.docker.docker_compose_v2", "recreate") == "always"
        end
        task["community.docker.docker_compose_v2"]["dependencies"] = true
      end
    },
    expects: "the wedged Seafile boot must be recovered by force-recreating the server alone"
  },
  {
    name: "a recreate budget that keeps spending after the server recovered",
    break: lambda { |root|
      edit_seafile_tasks(root, "recover_wedged_boot") do |document|
        block = nested_tasks(document).find do |candidate|
          Array(candidate["block"]).any? do |inner|
            inner.dig("community.docker.docker_compose_v2", "recreate") == "always"
          end
        end
        block.delete("when")
      end
    },
    expects: "the wedged Seafile boot must be recovered by force-recreating the server alone"
  },
  {
    name: "a health verdict read after the container it describes is replaced",
    break: lambda { |root|
      edit_seafile_tasks(root, "deploy") do |document|
        recovery = nested_tasks(document).find { |candidate| candidate.key?("rescue") }.fetch("rescue")
        capture = recovery.find do |candidate|
          Array(candidate.dig("ansible.builtin.command", "argv"))
            .any? { |value| value.to_s.include?("{{json .State.Health}}") }
        end
        recovery.delete(capture)
        recovery.push(capture)
      end
    },
    expects: "the wedged Seafile server's health verdict must be captured before it is recreated"
  },
  {
    name: "an inspection wide enough to print the rendered environment",
    break: lambda { |root|
      edit_seafile_tasks(root, "deploy") do |document|
        recovery = nested_tasks(document).find { |candidate| candidate.key?("rescue") }.fetch("rescue")
        recovery.push(
          "name" => "Inspect the wedged Seafile server",
          "ansible.builtin.command" => { "argv" => %w[docker container inspect seafile] },
          "changed_when" => false
        )
      end
    },
    expects: "Seafile diagnostics must narrow every inspection rather than print the container environment"
  },
  {
    name: "a recreate budget the rescue cannot count with",
    break: lambda { |root|
      edit_yaml(root, "roles/seafile/meta/argument_specs.yml") do |document|
        document["argument_specs"]["main"]["options"]["seafile_wedged_boot_recreate_limit"]["type"] = "str"
      end
    },
    expects: "the Seafile wedged-boot recreate budget must be one declared integer recreate"
  },
  {
    name: "a verification that authenticates as somebody else",
    break: lambda { |root|
      edit_seafile_tasks(root, "verify") do |document|
        task = document.find { |candidate| candidate.dig("ansible.builtin.uri", "method") == "POST" }
        task["ansible.builtin.uri"]["body"]["password"] = "{{ seafile_admin_password }}"
      end
    },
    expects: "Seafile verification must exchange the vault administrator for a token"
  },
  {
    name: "a verification that settles for a constant",
    break: lambda { |root|
      edit_seafile_tasks(root, "verify") do |document|
        task = document.find { |candidate| candidate.key?("ansible.builtin.debug") }
        task["ansible.builtin.debug"]["msg"] = "A live run would read {{ seafile_api }}/ping/ instead."
      end
    },
    expects: "Seafile verification must not settle for an endpoint its databases cannot fail"
  },
  {
    name: "a task naming a credential without redaction",
    break: lambda { |root|
      edit_seafile_tasks(root, "verify") do |document|
        task = document.find { |candidate| candidate.dig("ansible.builtin.uri", "method") == "POST" }
        task.delete("no_log")
      end
    },
    expects: "every Seafile task naming a vault credential must be redacted"
  },
  {
    name: "an event configuration written back in the clear",
    break: lambda { |root|
      edit_seafile_tasks(root, "reconcile_seafevents") do |document|
        task = document.find { |candidate| candidate.key?("ansible.builtin.copy") }
        task.delete("no_log")
      end
    },
    expects: "the Seafile event configuration carries a database password and must be redacted"
  },
  {
    name: "a data root outside the Docker root",
    break: lambda { |root|
      edit_yaml(root, "roles/seafile/defaults/main.yml") do |document|
        document["seafile_data_host_path"] = "{{ nas_media_root }}/seafile/data"
      end
    },
    expects: "Seafile must keep its data and database roots under the Docker root"
  },
  {
    name: "an event configuration path the server does not write",
    break: lambda { |root|
      edit_yaml(root, "roles/seafile/defaults/main.yml") do |document|
        document["seafile_seafevents_config_path"] = "{{ seafile_data_host_path }}/conf/seafevents.conf"
      end
    },
    expects: "the Seafile event configuration must be the file the server writes inside the volume"
  },
  {
    name: "file indexing left switched on",
    break: lambda { |root|
      edit_yaml(root, "roles/seafile/defaults/main.yml") { |document| document["seafile_index_files_enabled"] = true }
    },
    expects: "this platform must own file indexing as switched off"
  },
  {
    name: "a contract default port that drifted from the role",
    break: lambda { |root|
      mutate_text(root, "tests/contracts/seafile.sh",
                  ': "${PLATFORM_SEAFILE_PORT:=8083}"', ': "${PLATFORM_SEAFILE_PORT:=9083}"')
    },
    expects: "the Seafile contract's default port must be the port the role publishes"
  },
  {
    name: "a vault credential the role no longer requires",
    break: lambda { |root|
      edit_yaml(root, "roles/seafile/meta/argument_specs.yml") do |document|
        document["argument_specs"]["main"]["options"]["vault_seafile_jwt_private_key"]["required"] = false
      end
    },
    expects: "every Seafile vault credential must be a required role argument"
  },
  {
    name: "an operator switch declared as a string",
    break: lambda { |root|
      edit_yaml(root, "roles/seafile/meta/argument_specs.yml") do |document|
        document["argument_specs"]["main"]["options"]["seafile_deployment_enabled"]["type"] = "str"
      end
    },
    expects: "the Seafile operator switch must be a required declared boolean"
  },
  {
    name: "a credential Compose would truncate at its first dollar",
    break: lambda { |root|
      mutate_text(root, "roles/seafile/templates/env.j2",
                  "SEAFILE_DB_PASSWORD={{ vault_seafile_db_password | replace('$', '$$') }}",
                  "SEAFILE_DB_PASSWORD={{ vault_seafile_db_password }}")
    },
    expects: "every Seafile credential must survive Compose's own interpolation"
  },
  {
    name: "a Seafile root that disaster recovery would skip",
    break: lambda { |root|
      edit_yaml(root, "inventory/group_vars/all/main.yml") do |document|
        entry = document["nas_storage"].find { |candidate| candidate["path"].to_s.end_with?("/seafile/db") }
        entry["recovery"] = "user"
      end
    },
    expects: "every Seafile storage root must be declared unrecoverable without the others"
  },
  # --- the pre-upgrade backup ------------------------------------------------
  #
  # Nine rows, and every one of them is a way the backup could still be present
  # and no longer be a guard. A backup that runs after Compose, that cannot fail
  # the run, that dumps three schemas one after another against a live server,
  # or that copies the volume before the dump is a backup in the sense that
  # something gets written -- and each of those restores something that never
  # existed.
  {
    name: "a backup root anybody on the host can read",
    break: lambda { |root|
      edit_yaml(root, "inventory/group_vars/all/main.yml") do |document|
        entry = document["nas_storage"].find do |candidate|
          candidate["path"].to_s.end_with?("/seafile/backups")
        end
        entry["mode"] = "0755"
      end
    },
    expects: "the Seafile backup root must be declared private"
  },
  {
    name: "a backup taken after Compose has already started the stack",
    break: lambda { |root|
      edit_seafile_tasks(root, "deploy") do |document|
        include_index = document.index do |task|
          task["ansible.builtin.include_tasks"] == "pre_upgrade_backup.yml"
        end
        document.push(document.delete_at(include_index))
      end
    },
    expects: "the Seafile pre-upgrade backup must run before Compose touches the stack"
  },
  {
    name: "a backup that runs with the service switched off",
    break: lambda { |root|
      edit_seafile_tasks(root, "deploy") do |document|
        task = document.find { |candidate| candidate["ansible.builtin.include_tasks"] == "pre_upgrade_backup.yml" }
        task.delete("when")
      end
    },
    expects: "the Seafile pre-upgrade backup must be gated on the operator switch"
  },
  {
    # Three schemas dumped one after another against a server that is still
    # writing restore as rows that never coexisted -- and the failure appears
    # at the restore, months later, as a library with files nothing can open.
    name: "three databases dumped without one consistent snapshot",
    break: lambda { |root|
      mutate_text(root, "roles/seafile/tasks/pre_upgrade_backup.yml",
                  "--single-transaction --quick", "--quick")
    },
    expects: "the Seafile pre-upgrade dump must be one consistent snapshot of all three databases"
  },
  {
    name: "a dump the run is allowed to survive",
    break: lambda { |root|
      edit_seafile_tasks(root, "pre_upgrade_backup") do |document|
        task = document.find { |candidate| candidate.key?("community.docker.docker_compose_v2_exec") }
        task["failed_when"] = false
      end
    },
    expects: "the Seafile pre-upgrade dump must be allowed to fail the run"
  },
  {
    name: "a dump proved by its exit status rather than by its file",
    break: lambda { |root|
      edit_seafile_tasks(root, "pre_upgrade_backup") do |document|
        task = document.find do |candidate|
          Array(candidate.dig("ansible.builtin.assert", "that")).any? do |condition|
            condition.to_s.include?("seafile_database_dump_file.stat")
          end
        end
        task["ansible.builtin.assert"]["that"] =
          ["seafile_database_dump_file.stat.exists"]
      end
    },
    expects: "the Seafile upgrade must be refused unless the dump landed and is not empty"
  },
  {
    # The ordering claim, and the plant leaves both tasks in place: what changes
    # is only which of them writes into the backup first, which is exactly the
    # defect a grep for either task cannot see.
    name: "the volume copied before the database that names it",
    break: lambda { |root|
      edit_seafile_tasks(root, "pre_upgrade_backup") do |document|
        copy_index = document.index { |task| task.key?("ansible.builtin.copy") }
        dump_index = document.index { |task| task.key?("community.docker.docker_compose_v2_exec") }
        document.insert(dump_index, document.delete_at(copy_index))
      end
    },
    expects: "the Seafile database dump must be taken before anything is copied out of the volume"
  },
  {
    name: "a configuration backup that preserves the plaintext administrator handoff",
    break: lambda { |root|
      edit_seafile_tasks(root, "pre_upgrade_backup") do |document|
        task = document.find { |candidate| candidate.key?("ansible.builtin.find") }
        task["ansible.builtin.find"]["excludes"] = []
      end
    },
    expects: "the Seafile configuration backup must exclude the plaintext administrator handoff"
  },
  {
    name: "a configuration copy that renders the database password in its diff",
    break: lambda { |root|
      edit_seafile_tasks(root, "pre_upgrade_backup") do |document|
        task = document.find { |candidate| candidate.key?("ansible.builtin.copy") }
        task.delete("no_log")
      end
    },
    expects: "the Seafile configuration copy carries a database password and must be redacted"
  },
  {
    # !override replaces a volume list rather than extending it, so the Mac lane
    # is the one place where forgetting the mount leaves a dump with nowhere to
    # land and a refusal naming a path that exists on the host and not in the
    # container.
    name: "a Mac override whose database container has nowhere to dump",
    break: lambda { |root|
      mutate_text(root, "services/seafile/compose.mac.yml",
                  "\n      - ${SEAFILE_BACKUP_PATH:?}:/backups", "")
    },
    expects: "the Mac Seafile override must keep the backup mount its !override replaces"
  },
  # --- #492, the defect that reached CI --------------------------------------
  #
  # The plant is the argv this role actually shipped, restored byte for byte. It
  # is worth reading beside the row below it: a reviewer looking at that YAML sees
  # a `{% raw %}` wrapper around a Go template and a list being built, and every
  # part of it is individually correct. What is wrong is only that the tag is
  # inside the expression, where Jinja lexes a string literal rather than a tag,
  # so the wrapper survives into docker's --format and every census line comes
  # back prefixed. The role then reported `stack-not-running` against a stack
  # that was serving its API, on all three of the lane's converges, with a clean
  # PLAY RECAP.
  {
    name: "an image census whose Go template Jinja will not process",
    # Planted against the parsed document rather than the source text, so the
    # row states the SHAPE that is wrong -- one templated string in place of a
    # list of literals -- rather than an indentation the next edit would break.
    # The string is what the shipped folded scalar parsed to.
    break: lambda { |root|
      edit_seafile_tasks(root, "pre_upgrade_backup") do |document|
        task = document.find do |candidate|
          Array(candidate.dig("ansible.builtin.command", "argv")).include?("inspect")
        end
        task["ansible.builtin.command"]["argv"] =
          "{{ ['docker', 'container', 'inspect', '--format', " \
          "'{% raw %}{{index .Config.Labels \"com.docker.compose.service\"}}={{.Config.Image}}{% endraw %}'] " \
          "+ seafile_stack_containers.stdout_lines }}"
        task.delete("loop")
        task.delete("loop_control")
      end
    },
    expects: "no Seafile Jinja expression may contain a raw tag, which Jinja will not process"
  },
  {
    # The general lesson rather than the specific bug: whatever stops the census
    # parsing, a classifier that answers `stopped` to `unreadable` turns this
    # whole file into a no-op that reports success.
    name: "a stack census that parsed nothing reported as a stopped stack",
    break: lambda { |root|
      edit_seafile_tasks(root, "pre_upgrade_backup") do |document|
        document.reject! do |task|
          Array(task.dig("ansible.builtin.assert", "that")).any? do |condition|
            condition.to_s.include?("seafile_stack_containers.stdout_lines") &&
              condition.to_s.include?("seafile_stateful_deployed")
          end
        end
      end
    },
    expects: "a Seafile stack census that parsed nothing must fail rather than read as stopped"
  },
  {
    name: "a forced backup with no stack to dump reported away",
    break: lambda { |root|
      edit_seafile_tasks(root, "pre_upgrade_backup") do |document|
        document.reject! do |task|
          Array(task["when"]).any? { |value| value.to_s.include?("seafile_pre_upgrade_backup_force") } &&
            task.key?("ansible.builtin.assert")
        end
      end
    },
    expects: "a forced Seafile backup with no stack to dump must fail rather than report itself away"
  }
].freeze

def static_failures(program, rows = STATIC_ROWS)
  failures = []
  in_parallel_cases(failures, rows) do |row, collected|
    Dir.mktmpdir("nas-platform-seafile-static.") do |raw|
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
# The runtime half takes a mode and reads everything else from the environment,
# so the sandbox is environment plus PATH stubs plus one HTTP fixture, and each
# row moves exactly one of them. Both modes are driven from here: a row states
# its mode, and `run` is never assumed -- a row that forgot to would silently
# exercise a different half of the program than the one it names.

ADMIN_EMAIL = "seafile-contract@example.invalid"
ADMIN_PASSWORD = "seafile-contract-admin-password"
API_TOKEN = "0123456789abcdef0123456789abcdef01234567"
SERVER_CONTAINER = "fixture-seafile"
DATABASE_CONTAINER = "fixture-seafile-db"
CACHE_CONTAINER = "fixture-seafile-cache"

# What the server's own generator writes, as far as this contract is concerned:
# a [DATABASE] section carrying a credential, the key this platform owns, and
# the two other `enabled` keys that make a per-line rewrite the wrong transform.
def seafevents_document(index_enabled: "false", index_section: true,
                        audit_enabled: "true", audit_section: true)
  sections = ["[DATABASE]\ntype = mysql\nhost = db\nusername = seafile\npassword = fixture\n"]
  sections << "[AUDIT]\nenabled = #{audit_enabled}\n" if audit_section
  sections << "[INDEX FILES]\nenabled = #{index_enabled}\ninterval = 10m\n" if index_section
  sections << "[SEAHUB EMAIL]\nenabled = true\ninterval = 30m\n"
  sections.join("\n")
end

# What roles/seafile leaves in the other generated file: the server's own
# configuration, which opens with the database credential this fixture spells out
# so a row can prove the contract never renders it, plus the marked block the
# platform owns. `section` writes the block with a header other than [quota],
# which is the shape a section-blind repair produces and the one a reader most
# easily mistakes for correct.
def seafile_conf_document(quota: "20g", block: true, marker: true, section: "quota")
  body = +"[database]\ntype = mysql\nhost = db\nuser = seafile\npassword = fixture\n\n"
  return body unless block

  body << "# BEGIN nas-platform seafile quota\n" if marker
  body << "[#{section}]\n"
  body << "default = #{quota}\n" if quota
  body << "# END nas-platform seafile quota\n" if marker
  body
end

RUNTIME_DEFAULTS = {
  mode: "run",
  inspect_ok: true,
  states: {
    SERVER_CONTAINER => "running healthy",
    DATABASE_CONTAINER => "running healthy",
    CACHE_CONTAINER => "running healthy"
  }.freeze,
  vault_ok: true,
  host_conf: nil,
  host_conf_present: true,
  host_server_conf: nil,
  host_server_conf_present: true,
  restart_server_conf: nil,
  container_conf: nil,
  container_conf_ok: true,
  tcp_ok: true,
  tcp_identity: "root",
  wrong_tcp_ok: false,
  socket_ok: false,
  cache_ok: true,
  cache_before: { "ping" => 12, "get" => 30, "setex" => 4 }.freeze,
  cache_after: { "ping" => 14, "get" => 44, "setex" => 9 }.freeze,
  ping_code: 200,
  token_code: 200,
  token_body: { "token" => API_TOKEN }.freeze,
  wrong_token_code: 400,
  wrong_token_body: { "non_field_errors" => ["Unable to login with provided credentials."] }.freeze,
  restart_ok: true,
  restart_states: nil,
  restart_conf: nil,
  stop_ok: true,
  start_ok: true,
  drop_ok: true,
  restore_ok: true,
  grant_ok: true,
  # The library is already there by default, so the assert rows exercise the
  # path the lane actually takes and one seed row turns it off to exercise the
  # creation the seed does on a fresh sandbox.
  library_exists: true,
  restored_library: true,
  create_code: 200,
  upload_code: 200,
  token_after_drop: false,
  seeded_content: REHEARSAL_CONTENT,
  restored_content: REHEARSAL_CONTENT,
  backup_present: true,
  backup_manifest: true,
  backup_admin_txt: false,
  backup_dump: "-- MariaDB dump fixture\nCREATE DATABASE ccnet_db;\n"
}.freeze

# Every budget the runtime half reads, set low because no row here is entitled
# to wait: the fixture answers immediately and a row whose outcome is a refusal
# has nothing to wait for. CACHE_SETTLE is zero rather than ten because it is a
# sleep rather than a deadline -- ten there would be ten seconds off every row's
# wall time, which is the shape CLAUDE.md's budget section keeps recording.
#
# The three deadlines below are 30 rather than the 10 they shipped at, and the
# distinction is what makes raising them free. A budget a passing row waits out
# costs that budget on every run; these are ceilings on how long the docker STUB
# may take to answer, and the stub answers immediately, so a larger ceiling costs
# nothing when nothing is slow. That 10 was too small was measured rather than
# guessed: run alone this check passes, and run inside the gate's own
# twelve-worker pool on a twelve-core Mac its stub invocations exceeded 10
# seconds of wall time and up to eight rows failed with "did not finish within
# 10s" -- process-spawn latency wearing a refusal's clothes, which reports the
# wrong row as broken. The row that genuinely tests a deadline sets its own (1)
# and is unaffected.
RUNTIME_BUDGETS = {
  "PLATFORM_SEAFILE_READY_TIMEOUT_SECONDS" => "30",
  "PLATFORM_SEAFILE_RESTART_TIMEOUT_SECONDS" => "30",
  "PLATFORM_SEAFILE_DOCKER_TIMEOUT_SECONDS" => "30",
  "PLATFORM_SEAFILE_HTTP_OPEN_TIMEOUT_SECONDS" => "5",
  "PLATFORM_SEAFILE_HTTP_READ_TIMEOUT_SECONDS" => "5",
  "PLATFORM_SEAFILE_CACHE_SETTLE_SECONDS" => "0",
  "PLATFORM_SEAFILE_POLL_INTERVAL_SECONDS" => "1"
}.freeze

def vault_document
  {
    "vault_seafile_admin_email" => ADMIN_EMAIL,
    "vault_seafile_admin_password" => ADMIN_PASSWORD,
    "vault_seafile_db_root_password" => "fixture-root-password",
    # The database pair the restore rehearsal's account recreation needs. Read
    # by every mode, because a vault missing a key must fail at the top naming
    # the vault rather than halfway through a restore.
    "vault_seafile_db_username" => "fixture-db-user",
    "vault_seafile_db_password" => "fixture-db-password"
  }
end

# One stub for `docker`, dispatching on argv the way the real command does. It
# reads a JSON fixture rather than being regenerated per case, so a row states
# its outcome as data; and it keeps its own counter and restart marker inside the
# sandbox, which is what lets a row say "the cache had served this before the
# token exchange and that after it" or "the server rewrote the file on start".
def docker_stub_source(options_path)
  <<~RUBY
    #!#{RbConfig.ruby}
    require "json"
    options = JSON.parse(File.read(#{options_path.inspect}))
    argv = ARGV
    joined = argv.join(" ")
    marker = options.fetch("restart_marker")
    case argv.first
    when "inspect"
      exit 1 unless options.fetch("inspect_ok")
      container = argv.last
      states = File.exist?(marker) && options["restart_states"] ? options.fetch("restart_states") : options.fetch("states")
      puts states.fetch(container, "running healthy")
    when "exec"
      # The rehearsal branches come first because both of their commands also
      # carry --protocol=tcp and MYSQL_ROOT_PASSWORD, so the credential branch
      # below would answer for them and the drop would silently never happen.
      if joined.include?("drop database")
        exit 1 unless options.fetch("drop_ok")
        File.write(options.fetch("dropped_marker"), "dropped")
      elsif argv.include?("-i")
        # Both statements the rehearsal feeds through stdin arrive here, and
        # they are told apart by what they say rather than by which call it is:
        # the restore is the dump, the recreation is the documented CREATE USER.
        payload = $stdin.read
        if payload.include?("CREATE USER")
          exit(options.fetch("grant_ok") ? 0 : 1)
        end
        unless options.fetch("restore_ok")
          warn "ERROR 1064 (42000): the fixture refused this dump"
          exit 1
        end
        File.write(options.fetch("restored_marker"), "restored")
      elsif joined.include?("seafevents.conf")
        # The bytes are printed before the status is decided, which is what
        # makes the path row's plant surgical: a `docker exec cat` that writes
        # output and still fails is a coherent fixture, and it leaves nothing
        # downstream able to refuse in place of the path assertion.
        print File.read(options.fetch("container_conf_path"))
        exit 1 unless options.fetch("container_conf_ok")
      elsif joined.include?("--protocol=tcp") && joined.include?("MYSQL_ROOT_PASSWORD")
        exit 1 unless options.fetch("tcp_ok")
        puts options.fetch("tcp_identity")
      elsif joined.include?("--protocol=tcp")
        exit(options.fetch("wrong_tcp_ok") ? 0 : 1)
      elsif joined.include?("--protocol=socket")
        exit(options.fetch("socket_ok") ? 0 : 1)
      elsif joined.include?("INFO commandstats")
        exit 1 unless options.fetch("cache_ok")
        counter = options.fetch("cache_counter")
        seen = File.exist?(counter) ? File.read(counter).to_i : 0
        File.write(counter, (seen + 1).to_s)
        families = seen.zero? ? options.fetch("cache_before") : options.fetch("cache_after")
        puts "# Commandstats"
        families.each { |name, calls| puts "cmdstat_\#{name}:calls=\#{calls},usec=10,usec_per_call=1.00" }
      else
        warn "docker stub reached an exec it does not know: \#{joined}"
        exit 127
      end
    when "stop"
      exit(options.fetch("stop_ok") ? 0 : 1)
    when "start"
      exit 1 unless options.fetch("start_ok")
      # The same marker `restart` writes, so restart_states describes the state
      # after a start exactly as it describes the state after a restart.
      File.write(marker, "restarted")
    when "restart"
      exit 1 unless options.fetch("restart_ok")
      File.write(marker, "restarted")
      File.write(options.fetch("host_conf_path"), options.fetch("restart_conf")) if options["restart_conf"]
      File.write(options.fetch("host_server_conf_path"), options.fetch("restart_server_conf")) if
        options["restart_server_conf"]
    else
      warn "docker stub reached a subcommand it does not know: \#{joined}"
      exit 127
    end
  RUBY
end

def build_runtime_sandbox(root, options)
  bin = File.join(root, "bin")
  FileUtils.mkdir_p(bin)
  docker_root = File.join(root, "docker")
  host_conf = File.join(docker_root, "seafile", "data", "seafile", "conf", "seafevents.conf")
  FileUtils.mkdir_p(File.dirname(host_conf))
  host_body = options.fetch(:host_conf) || seafevents_document
  File.write(host_conf, host_body) if options.fetch(:host_conf_present)
  container_conf = File.join(root, "container-seafevents.conf")
  File.write(container_conf, options.fetch(:container_conf) || host_body)
  host_server_conf = File.join(docker_root, "seafile", "data", "seafile", "conf", "seafile.conf")
  File.write(host_server_conf, options.fetch(:host_server_conf) || seafile_conf_document) if
    options.fetch(:host_server_conf_present)

  # The backup roles/seafile would have taken, laid out on disk the way it lays
  # one out. The rehearsal never creates this -- the whole point is that it
  # restores the platform's own backup -- so a row that removes or empties it is
  # describing a platform that did not back up rather than a contract that did
  # not look.
  backup_root = File.join(docker_root, "seafile", "backups")
  if options.fetch(:backup_present)
    backup = File.join(backup_root, "20260101T000000")
    FileUtils.mkdir_p(File.join(backup, "conf"))
    File.write(File.join(backup, "databases.sql"), options.fetch(:backup_dump))
    File.write(File.join(backup, "MANIFEST.txt"), "fixture manifest\n") if
      options.fetch(:backup_manifest)
    File.write(File.join(backup, "conf", "seafile.conf"), "[database]\n")
    File.write(File.join(backup, "conf", "admin.txt"), "leaked\n") if
      options.fetch(:backup_admin_txt)
  end

  options_path = File.join(root, "docker-stub.json")
  File.write(options_path, JSON.generate(
    "dropped_marker" => File.join(root, "dropped-marker"),
    "restored_marker" => File.join(root, "restored-marker"),
    "drop_ok" => options.fetch(:drop_ok),
    "restore_ok" => options.fetch(:restore_ok),
    "grant_ok" => options.fetch(:grant_ok),
    "stop_ok" => options.fetch(:stop_ok),
    "start_ok" => options.fetch(:start_ok),
    "inspect_ok" => options.fetch(:inspect_ok),
    "states" => options.fetch(:states),
    "restart_states" => options.fetch(:restart_states),
    "container_conf_ok" => options.fetch(:container_conf_ok),
    "container_conf_path" => container_conf,
    "host_conf_path" => host_conf,
    "host_server_conf_path" => host_server_conf,
    "tcp_ok" => options.fetch(:tcp_ok),
    "tcp_identity" => options.fetch(:tcp_identity),
    "wrong_tcp_ok" => options.fetch(:wrong_tcp_ok),
    "socket_ok" => options.fetch(:socket_ok),
    "cache_ok" => options.fetch(:cache_ok),
    "cache_before" => options.fetch(:cache_before),
    "cache_after" => options.fetch(:cache_after),
    "cache_counter" => File.join(root, "cache-counter"),
    "restart_marker" => File.join(root, "restart-marker"),
    "restart_ok" => options.fetch(:restart_ok),
    "restart_conf" => options.fetch(:restart_conf),
    "restart_server_conf" => options.fetch(:restart_server_conf)
  ))

  File.write(File.join(bin, "docker"), docker_stub_source(options_path))
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

# Which of the three phases of a restore rehearsal the fixture is in, read from
# the markers the docker stub writes rather than from a counter here: the
# program decides when to drop and when to restore, and a responder counting
# requests would agree with it only by accident.
def rehearsal_phase(options)
  sandbox = options[:sandbox]
  return :initial if sandbox.nil?
  return :restored if File.exist?(File.join(sandbox, "restored-marker"))
  return :dropped if File.exist?(File.join(sandbox, "dropped-marker"))

  :initial
end

# Every link Seafile hands a client is built from SEAFILE_SERVER_HOSTNAME, so
# the fixture answers with a host the contract cannot reach on purpose: if the
# program stopped rewriting the coordinate, these rows would fail by timing out
# against seafile.example rather than by passing.
def rehearsal_link(path)
  JSON.generate("http://seafile.example:8083#{path}")
end

def runtime_responder(options)
  lambda do |method, target, _headers, body|
    path = target.split("?").first
    phase = rehearsal_phase(options)
    if method == "GET" && path == "/api2/ping/"
      [options.fetch(:ping_code), '"pong"']
    elsif method == "POST" && path == "/api2/auth-token/"
      form = URI.decode_www_form(body.to_s).to_h
      if form["username"] != ADMIN_EMAIL || form["password"] != ADMIN_PASSWORD
        [options.fetch(:wrong_token_code), JSON.generate(options.fetch(:wrong_token_body))]
      elsif phase == :dropped && !options.fetch(:token_after_drop)
        # What a real seahub does with its databases gone. A row can turn this
        # off, and the contract has to refuse that fixture rather than report a
        # successful restore of a server nothing ever broke.
        [500, JSON.generate("detail" => "no such table")]
      else
        [options.fetch(:token_code), JSON.generate(options.fetch(:token_body))]
      end
    elsif method == "GET" && path == "/api2/repos/"
      present = case phase
                when :dropped then false
                when :restored then options.fetch(:restored_library)
                else options.fetch(:library_exists)
                end
      [200, JSON.generate(present ? [{ "id" => REHEARSAL_REPO, "name" => REHEARSAL_LIBRARY }] : [])]
    elsif method == "POST" && path == "/api2/repos/"
      [options.fetch(:create_code), JSON.generate("repo_id" => REHEARSAL_REPO)]
    elsif method == "GET" && path.end_with?("/upload-link/")
      [200, rehearsal_link("/seafhttp/upload-api/fixture-token")]
    elsif method == "POST" && path == "/seafhttp/upload-api/fixture-token"
      [options.fetch(:upload_code), '"fixture-file-id"']
    elsif method == "GET" && path.end_with?("/file/")
      [200, rehearsal_link("/seafhttp/files/fixture/#{REHEARSAL_FILE}")]
    elsif method == "GET" && path.start_with?("/seafhttp/files/")
      [200, phase == :restored ? options.fetch(:restored_content) : options.fetch(:seeded_content)]
    else
      [404, "{}"]
    end
  end
end

RUNTIME_ROWS = [
  { name: "a converged Seafile stack", given: {}, expects: nil },
  {
    name: "a container Docker cannot inspect",
    given: { inspect_ok: false },
    expects: "could not be inspected"
  },
  {
    name: "a server that is not running",
    given: { states: { SERVER_CONTAINER => "exited unhealthy" } },
    expects: "is exited, not running"
  },
  {
    name: "a cache Docker calls unhealthy",
    given: { states: { CACHE_CONTAINER => "running unhealthy" } },
    expects: "is unhealthy, not healthy"
  },
  {
    name: "a vault that cannot be read",
    given: { vault_ok: false },
    expects: "the encrypted vault could not be read"
  },
  {
    name: "a server that keeps its event configuration somewhere else",
    given: { container_conf_ok: false },
    expects: "Seafile does not keep its event configuration at /shared/seafile/conf/seafevents.conf"
  },
  {
    name: "an event configuration that never reached the host",
    given: { host_conf_present: false },
    expects: "did not land on the host at"
  },
  {
    name: "a host copy that is not the container's file",
    given: { container_conf: "[INDEX FILES]\nenabled = false\n" },
    expects: "the container and host copies of seafevents.conf are not the same file"
  },
  {
    name: "an event configuration with no [INDEX FILES] key",
    given: { host_conf: seafevents_document(index_section: false) },
    expects: "carries no [INDEX FILES] enabled key"
  },
  {
    name: "an event configuration with no [AUDIT] key",
    given: { host_conf: seafevents_document(audit_section: false) },
    expects: "carries no [AUDIT] enabled key"
  },
  # The exact shape a per-line repair produces: the key this platform asked for
  # reads what it asked for, and the identically named key in the next section
  # was switched off in the same pass. A contract that read only [INDEX FILES]
  # would call this converged.
  {
    name: "an audit log switched off by a repair that hit every enabled key",
    given: { host_conf: seafevents_document(audit_enabled: "false") },
    expects: "the Seafile audit log is false in the deployed seafevents.conf"
  },
  {
    name: "a server configuration that never reached the host",
    given: { host_server_conf_present: false },
    expects: "the Seafile server configuration did not land on the host at"
  },
  # A quota present but no marker: a value somebody typed into the file by hand,
  # which is exactly what a platform-owned block is supposed to be
  # distinguishable from. The next converge would append its own block anyway,
  # so a deployment in this state has never been reconciled.
  {
    name: "a storage quota no marker identifies as this platform's",
    given: { host_server_conf: seafile_conf_document(marker: false) },
    expects: "carries no nas-platform seafile quota block"
  },
  {
    name: "a quota seaf-server parses as no quota",
    given: { host_server_conf: seafile_conf_document(quota: "20 gigs") },
    expects: "declares no [quota] default that seaf-server would parse"
  },
  # The section-blind failure, in the file where it is easiest to miss: the key
  # is spelled exactly right and sits under the wrong header, and seaf-server
  # reads only the one under [quota].
  {
    name: "a default quota declared under a section seaf-server does not read",
    given: { host_server_conf: seafile_conf_document(section: "general") },
    expects: "declares no [quota] default that seaf-server would parse"
  },
  {
    name: "file indexing left running against an absent Elasticsearch",
    given: { host_conf: seafevents_document(index_enabled: "true") },
    expects: "Seafile file indexing is true"
  },
  {
    name: "a database that refuses the platform's own root credential",
    given: { tcp_ok: false },
    expects: "refused over TCP the root credential this platform authored"
  },
  {
    name: "a database answering as somebody other than root",
    given: { tcp_identity: "seafile" },
    expects: "answered as \"seafile\" rather than root"
  },
  {
    name: "a database accepting a password nothing wrote",
    given: { wrong_tcp_ok: true },
    expects: "accepted over TCP a root password nothing ever wrote"
  },
  # Deliberately expects success. The socket outcome is an observation, and a row
  # that proves it cannot fail the lane is the only way to keep it one: the day
  # somebody promotes it to an assertion, this row goes red and says so.
  {
    name: "a socket that authenticates root without the password",
    given: { socket_ok: true },
    expects: nil
  },
  {
    name: "a cache that will not answer INFO commandstats",
    given: { cache_ok: false },
    expects: "the Seafile cache did not answer INFO commandstats"
  },
  {
    name: "a cache serving nothing but its own health check",
    # client|setinfo is in this fixture on purpose: valkey-cli sends CLIENT
    # SETINFO on connect, so a real cache-less deployment shows it beside ping
    # and the contract has to see through the subcommand form to reject both.
    given: {
      cache_before: { "ping" => 8, "client|setinfo" => 1 },
      cache_after: { "ping" => 10, "client|setinfo" => 2 }
    },
    expects: "Seafile is not using the Valkey cache"
  },
  {
    name: "a server that will not issue an administrator token",
    given: { token_code: 400, token_body: { "non_field_errors" => ["nope"] } },
    expects: "did not issue an API token for the vault administrator"
  },
  {
    name: "a 200 carrying no token at all",
    given: { token_body: {} },
    expects: "did not issue an API token for the vault administrator"
  },
  {
    name: "a server issuing a token for a password the vault never authored",
    given: { wrong_token_code: 200, wrong_token_body: { "token" => API_TOKEN } },
    expects: "issued an API token for a password the vault never authored"
  },
  {
    name: "a mode the contract does not implement",
    given: { mode: "drift" },
    expects: "unknown mode: drift"
  },
  { name: "a restart that preserves the platform setting", given: { mode: "restart-persistence" }, expects: nil },
  {
    name: "a restart probe run before the reconciliation",
    # The restart puts the platform's own value back, so nothing downstream of
    # the precondition can refuse this fixture: with the precondition removed
    # the mode passes, which is what makes the plant against it detectable as
    # an acceptance rather than as some later assertion's diagnostic.
    given: {
      mode: "restart-persistence",
      host_conf: seafevents_document(index_enabled: "true"),
      restart_conf: seafevents_document(index_enabled: "false")
    },
    expects: "before the restart, so the reconciliation this mode exists to test has not run"
  },
  {
    name: "a server that cannot be restarted",
    given: { mode: "restart-persistence", restart_ok: false },
    expects: "could not be restarted"
  },
  # The precondition, and it is worth a row of its own: without it a deployment
  # whose quota was never written fails saying the restart dropped a block that
  # was never there, which is a confident diagnosis of the wrong failure.
  {
    name: "a restart probe run before the quota reconciliation",
    # The restart puts the block back, for the reason the indexing precondition
    # row carries: with the precondition removed the mode has to PASS, or the
    # plant against it proves nothing about which assertion refused.
    given: {
      mode: "restart-persistence",
      host_server_conf: seafile_conf_document(block: false),
      restart_server_conf: seafile_conf_document
    },
    expects: "carries no nas-platform seafile quota block before the restart"
  },
  {
    # The other first-run-only claim, and a different writer: bootstrap.py appends
    # to seafile.conf on the run that creates it, so "the server does not rewrite
    # it later" is its own statement rather than a corollary of the seafevents
    # one.
    name: "a start that regenerates the server configuration over the owned block",
    given: {
      mode: "restart-persistence",
      restart_server_conf: seafile_conf_document(block: false)
    },
    expects: "Seafile rewrote seafile.conf on start and dropped the"
  },
  {
    name: "a server that never becomes healthy again",
    given: { mode: "restart-persistence", restart_states: { SERVER_CONTAINER => "running starting" } },
    environment: { "PLATFORM_SEAFILE_RESTART_TIMEOUT_SECONDS" => "1" },
    expects: "did not become healthy again within"
  },
  # The highest-stakes row in this file. If Seafile rewrites the key on every
  # start, the role's repair-then-restart never converges and idempotence is
  # broken by construction, so the contract has to be able to say exactly that.
  {
    name: "a server that rewrites the platform-owned key on start",
    given: {
      mode: "restart-persistence",
      restart_conf: seafevents_document(index_enabled: "true")
    },
    expects: "Seafile rewrote [INDEX FILES] enabled to true on start"
  },
  {
    name: "a restarted server that never serves again",
    given: { mode: "restart-persistence", ping_code: 503 },
    environment: { "PLATFORM_SEAFILE_READY_TIMEOUT_SECONDS" => "1" },
    expects: "Seafile never served its API after the restart"
  },
  {
    name: "a restarted server that comes back without its databases",
    given: { mode: "restart-persistence", token_code: 500, token_body: { "detail" => "server error" } },
    expects: "did not issue an API token for the vault administrator"
  },
  # --- the restore rehearsal -------------------------------------------------
  #
  # The two modes the seafile lane runs a converge between. Everything the
  # rehearsal can get wrong is a way of reporting a successful restore of
  # something that was never broken, or of a backup nothing wrote, so most of
  # these rows are about the rehearsal refusing to flatter itself.
  {
    name: "a seeded rehearsal library that already exists",
    given: { mode: "restore-rehearsal-seed" },
    expects: nil
  },
  {
    name: "a seeded rehearsal library created from nothing",
    given: { mode: "restore-rehearsal-seed", library_exists: false },
    expects: nil
  },
  {
    name: "a library the server will not create",
    given: { mode: "restore-rehearsal-seed", library_exists: false, create_code: 500 },
    expects: "Seafile answered the library creation with HTTP 500"
  },
  {
    # An upload that answers 200 and stores nothing would leave the assert mode
    # failing against a backup that was never wrong, which is the wrong place
    # for that failure to appear.
    name: "an upload the server answered and did not store",
    given: { mode: "restore-rehearsal-seed", seeded_content: "not what was uploaded\n" },
    expects: "the rehearsal file did not read back as uploaded"
  },
  {
    name: "a rehearsed restore of the platform's own backup",
    given: { mode: "restore-rehearsal-assert" },
    expects: nil
  },
  {
    name: "a platform that took no backup at all",
    given: { mode: "restore-rehearsal-assert", backup_present: false },
    expects: "took no Seafile backup under"
  },
  {
    name: "a backup whose dump is an empty file",
    given: { mode: "restore-rehearsal-assert", backup_dump: "" },
    expects: "carries an empty databases.sql"
  },
  {
    name: "a backup with no manifest beside its dump",
    given: { mode: "restore-rehearsal-assert", backup_manifest: false },
    expects: "carries no manifest"
  },
  {
    # The security requirement, proved against a real backup directory rather
    # than against the role that claims to exclude it.
    name: "a backup that kept the plaintext administrator handoff",
    given: { mode: "restore-rehearsal-assert", backup_admin_txt: true },
    expects: "preserved the plaintext administrator handoff"
  },
  {
    name: "a rehearsal whose seed never ran",
    given: { mode: "restore-rehearsal-assert", library_exists: false },
    expects: "the seed mode has not run and there is nothing this rehearsal could prove"
  },
  {
    # THE VACUOUS PASS, and the row that matters most here. A server still
    # answering with its three databases dropped means the drop did nothing, so
    # every assertion after the restore is about a server that was working the
    # whole time.
    name: "a server still issuing tokens with its databases dropped",
    given: { mode: "restore-rehearsal-assert", token_after_drop: true },
    expects: "so this rehearsal is not testing what it claims to"
  },
  {
    name: "three databases that cannot be dropped",
    given: { mode: "restore-rehearsal-assert", drop_ok: false },
    expects: "the three Seafile databases could not be dropped"
  },
  {
    name: "a backup the database will not restore",
    given: { mode: "restore-rehearsal-assert", restore_ok: false },
    expects: "the Seafile backup would not restore"
  },
  {
    # Step 3 of the documented recovery, the case where the data directory
    # itself was lost. It is a no-op against a surviving datadir and it is
    # rehearsed anyway, so it has to be able to fail.
    name: "a documented account recreation the database refuses",
    given: { mode: "restore-rehearsal-assert", grant_ok: false },
    expects: "the documented Seafile account recreation would not run"
  },
  {
    name: "a library that did not come back from the restore",
    given: { mode: "restore-rehearsal-assert", restored_library: false },
    expects: "did not come back from the restored database"
  },
  {
    # The claim the whole rehearsal exists for. The blocks were never in the
    # backup; the database that names them was rebuilt from it. Bytes that come
    # back different are that coupling failing, and they are the one outcome no
    # amount of green containers would have shown.
    name: "a file that came back as bytes nobody uploaded",
    given: { mode: "restore-rehearsal-assert", restored_content: "wrong blocks\n" },
    expects: "do not match what was uploaded, so the restored database does not resolve its blocks"
  }
].freeze

def runtime_failures(program, rows = RUNTIME_ROWS)
  failures = []
  in_parallel_cases(failures, rows) do |row, collected|
    given = row.fetch(:given)
    options = RUNTIME_DEFAULTS.merge(given)
    options = options.merge(states: RUNTIME_DEFAULTS.fetch(:states).merge(given.fetch(:states))) if
      given.key?(:states)
    Dir.mktmpdir("nas-platform-seafile-runtime.") do |raw|
      root = File.realpath(raw)
      bin, docker_root = build_runtime_sandbox(root, options)
      HttpFixtureSupport.with_http_fixture(
        lambda do |port|
          stdout, stderr, status = Open3.capture3(
            RUNTIME_BUDGETS.merge(row.fetch(:environment, {})).merge(
              "PATH" => "#{bin}:#{ENV.fetch('PATH')}",
              "PLATFORM_SEAFILE_PORT" => port.to_s,
              "PLATFORM_SEAFILE_CONTAINER" => SERVER_CONTAINER,
              "PLATFORM_SEAFILE_DB_CONTAINER" => DATABASE_CONTAINER,
              "PLATFORM_SEAFILE_CACHE_CONTAINER" => CACHE_CONTAINER,
              "PLATFORM_DOCKER_ROOT" => docker_root,
              "PLATFORM_CONTRACT_VAULT_FILE" => File.join(root, "vault.yml"),
              "PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" => File.join(root, "vault-password")
            ),
            RbConfig.ruby, program, options.fetch(:mode)
          )
          collected.concat(judge("runtime: #{row.fetch(:name)}", row.fetch(:expects), stdout, stderr, status,
                                 prefix: DIAGNOSTIC_PREFIX))
        end,
        &runtime_responder(options.merge(sandbox: root))
      )
    end
  end
  failures
end

# --- wrapper layer ---------------------------------------------------------
#
# tests/contracts/seafile.sh resolves both programs from its own checkout rather
# than from the tree it inspects, so a copy of the three files into a throwaway
# tests/contracts/ is a whole working contract. That is what lets a row point
# PLATFORM_CONTRACT_REPO_DIR at a broken fixture and still exercise the real
# wrapper.

def with_contract_copy(static: File.read(STATIC_PROGRAM), runtime: File.read(RUNTIME_PROGRAM),
                       wrapper: File.read(CONTRACT))
  Dir.mktmpdir("nas-platform-seafile-wrapper.") do |raw|
    root = File.realpath(raw)
    build_fixture_repository(root)
    contracts = File.join(root, "tests", "contracts")
    FileUtils.mkdir_p(contracts)
    wrapper_path = File.join(contracts, "seafile.sh")
    File.write(wrapper_path, wrapper)
    File.chmod(0o755, wrapper_path)
    File.write(File.join(contracts, "seafile-static.rb"), static)
    File.write(File.join(contracts, "seafile-runtime.rb"), runtime)
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
    stdout, stderr, _status = Open3.capture3(
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
# set or null"), and never the line number, which any edit to that file moves.
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
# A planted regression that drops one of those `:?` requirements is what makes
# the exec reachable, and against the shipped runtime program that would mean a
# wait -- nothing is listening on the port, so it would spend its whole readiness
# budget proving what the row already knew. That is the shape that cost the seerr
# self-test 368 seconds and the trailarr one 247; the stub deletes the wait
# rather than shortening it, because reaching the runtime half at all is already
# the regression.
#
# It exits 0 deliberately, so a mutant that reaches it trips BOTH assertions
# below -- the wrapper accepted an environment it must refuse, and it did so
# without its own message -- and warns first, so the failure text says which
# happened rather than showing an empty capture.
RUNTIME_REFUSAL_STUB = <<~'STUB'
  warn "runtime stub reached: the wrapper did not refuse this environment"
  exit 0
STUB

# Echoes what the wrapper handed the runtime half. The mode has to arrive: the
# runtime program dispatches on it and defaults to `run`, so a wrapper that
# stopped passing it would silently run the cheap mode where the seafile lane
# asked for the restart probe -- a contract that passes and proves nothing.
MODE_ECHO_STUB = <<~'STUB'
  warn "runtime stub argv: #{ARGV.inspect}"
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

def mode_passthrough_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  with_contract_copy(runtime: MODE_ECHO_STUB, wrapper: wrapper_source) do |contract, copy_root|
    environment = {
      "PLATFORM_CONTRACT_REPO_DIR" => copy_root,
      "PLATFORM_CONTRACT_VAULT_FILE" => File.join(copy_root, "vault.yml"),
      "PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" => File.join(copy_root, "vault-password"),
      "PLATFORM_DOCKER_ROOT" => File.join(copy_root, "docker")
    }
    %w[run restart-persistence].each do |mode|
      stdout, stderr, status = Open3.capture3(environment, contract, mode)
      output = stdout + stderr
      failures << "mode: #{mode} did not reach the runtime half: #{output.strip.inspect}" unless
        status.success?
      failures << "mode: the runtime half was not told it was #{mode}: #{output.strip.inspect}" unless
        output.include?(%(runtime stub argv: ["#{mode}"]))
    end
    # The default a registry sweep takes: tests/run_contracts.rb spawns this
    # wrapper with no argument at all.
    stdout, stderr, _status = Open3.capture3(environment, contract)
    output = stdout + stderr
    failures << "mode: an argumentless sweep did not select run: #{output.strip.inspect}" unless
      output.include?('runtime stub argv: ["run"]')
  end
  failures
end

def wrapper_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  with_contract_copy(wrapper: wrapper_source) do |contract, copy_root|
    %w[verify drift notify --platform restart].each do |mode|
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
    FileUtils.rm(File.join(copy_root, "services/seafile/compose.mac.yml"))
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
      (stdout + stderr).include?("missing services/seafile/compose.mac.yml")
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

    FileUtils.rm(File.join(copy_root, "services/seafile/compose.mac.yml"))
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => nil }, contract, "static"
    )
    failures << "wrapper: with no repository named, static mode inspected some other tree" if
      status.success?
    failures << "wrapper: with no repository named, static mode did not report the broken tree" unless
      (stdout + stderr).include?("missing services/seafile/compose.mac.yml")
  end
  failures
end

# The two-roots property, stated as an OUTCOME rather than as the wrapper's
# text. These are the invariant rows: a before/after capture diff can only show
# differences, so the property that must stay identical is invisible in it.
#
# The inspected tree loses the two sibling PROGRAMS rather than the whole
# tests/contracts directory, which is where this differs from the seerr rows it
# otherwise copies. The property being proven is that the programs are resolved
# from the checkout, and the static half reads the inspected tree's own wrapper
# to compare its default port with that tree's role default -- so deleting the
# wrapper as well would only delete one of the assertions under test.
def two_roots_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  with_contract_copy(wrapper: wrapper_source) do |contract|
    Dir.mktmpdir("nas-platform-seafile-tworoots.") do |raw|
      inspected = File.realpath(raw)
      build_fixture_repository(inspected)
      %w[seafile-static.rb seafile-runtime.rb].each do |program|
        FileUtils.rm_f(File.join(inspected, "tests", "contracts", program))
      end
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => inspected }, contract, "static"
      )
      failures << "two roots: an inspected tree with no sibling programs was refused, so a " \
                  "program is being resolved from it: #{(stdout + stderr).strip}" unless status.success?
      failures << "two roots: the program did not report the property it proved" unless
        stdout.include?(SUCCESS_LINE)
    end

    # The other direction. The inspected tree's own flatten_tasks is what the
    # static program must use, so a tree whose policy_support.rb refuses to load
    # has to take the contract down with it. Reading the checkout's copy instead
    # would pass here, silently.
    Dir.mktmpdir("nas-platform-seafile-support.") do |raw|
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
    label: "the image pin check",
    program: :static,
    from: "image.match?(IMAGE_PIN) && image.split(\":\").first == repository",
    to: "true",
    rows: ["an image pinned by tag alone"]
  },
  {
    label: "the sandbox container name agreement",
    program: :static,
    from: "overrides.values.all? { |names| names == namespaced }",
    to: "true",
    rows: ["two overrides that disagree about a sandbox container"]
  },
  {
    label: "the single published port check",
    program: :static,
    from: 'services.select { |_name, service| service.key?("ports") }.keys == ["seafile"]',
    to: "true",
    rows: ["a database published on the network"]
  },
  {
    label: "the required-reference volume check",
    program: :static,
    from: "!volume_sources.empty? &&\n    volume_sources.all? { |source| source.match?(/\\A\\$\\{[A-Z][A-Z0-9_]*:\\?\\}\\z/) }",
    to: "true",
    rows: ["a volume bound to a literal host path"]
  },
  {
    label: "the reconcile-after-deploy ordering",
    program: :static,
    from: <<~'RUBY'.chomp,
      imports.index("reconcile_quota.yml").to_i > imports.index("deploy.yml").to_i &&
          imports.index("reconcile_seafevents.yml").to_i > imports.index("reconcile_quota.yml").to_i
    RUBY
    to: "true",
    rows: [
      "a reconciliation that runs before the deployment writes the file",
      "a quota reconciliation ordered after the restart it depends on"
    ]
  },
  {
    label: "the deployment gate check",
    program: :static,
    from: "!deployments.empty? &&\n    deployments.all? { |task| Array(task[\"when\"]).include?(\"seafile_deployment_enabled | bool\") }",
    to: "true",
    rows: ["a deployment that ignores the operator switch"]
  },
  {
    label: "the TCP-only database probe check",
    program: :static,
    # The whole condition rather than one clause: --protocol=tcp alone is
    # satisfied by a probe that also names the socket, and the negative clauses
    # are what stop the assertion from being read out of a comment.
    from: 'probe_argv.include?("--protocol=tcp") && probe_argv.include?("--host=db") &&
    probe_argv.include?("--user=root") &&
    !probe_argv.include?("--socket") && !probe_argv.include?("localhost")',
    to: "true",
    rows: ["a database probe over the container's own socket"]
  },
  {
    label: "the section-bounded event repair check",
    program: :static,
    from: <<~'RUBY'.chomp,
      assignment.length == 1 &&
          assignment.first.include?('\[{{ item.section }}\]') && assignment.first.include?('[^\[]*?')
    RUBY
    to: "true",
    rows: ["an event repair applied line by line"]
  },
  {
    label: "the section-bounded event report check",
    program: :static,
    from: <<~'RUBY'.chomp,
      reported.length == 2 &&
          reported.all? { |pattern| pattern.include?('\[{{ item.section }}\]') && pattern.include?('[^\[]*?') }
    RUBY
    to: "true",
    rows: ["an event report that reads the first matching key in the file"]
  },
  {
    label: "the declared-settings loop check",
    program: :static,
    from: "looped.length == 2",
    to: "true",
    rows: ["a repair that owns one hardcoded setting rather than the declared list"]
  },
  {
    label: "the owned audit log check",
    program: :static,
    from: 'defaults["seafile_audit_log_enabled"] == true',
    to: "true",
    rows: ["an audit log switched off"]
  },
  {
    label: "the owned-setting shape check",
    program: :static,
    from: <<~'RUBY'.chomp,
      managed.any? &&
          managed.all? { |setting| %w[section key value].all? { |field| setting[field].to_s != "" } }
    RUBY
    to: "true",
    rows: ["an owned event setting that names no value"]
  },
  {
    label: "the owned sections check",
    program: :static,
    from: 'owned.include?(["INDEX FILES", "enabled"]) && owned.include?(["AUDIT", "enabled"])',
    to: "true",
    rows: ["an audit log left to whatever the image happens to default to"]
  },
  {
    label: "the parseable quota check",
    program: :static,
    from: 'defaults["seafile_default_user_quota"].to_s.match?(/\A[0-9]+([kmgt]b?)?\z/)',
    to: "true",
    rows: ["a quota spelled the way a human writes it rather than the way seaf-server parses it"]
  },
  {
    label: "the owned quota block check",
    program: :static,
    from: <<~'RUBY'.chomp,
      block.length == 1 &&
          block.first.dig("ansible.builtin.blockinfile", "marker").to_s.include?("nas-platform seafile") &&
          block.first.dig("ansible.builtin.blockinfile", "block").to_s.include?("[quota]")
    RUBY
    to: "true",
    rows: ["a quota in a block nothing marks as this platform's"]
  },
  {
    label: "the preserved quota-file mode check",
    program: :static,
    from: <<~'RUBY'.chomp,
      block.length == 1 &&
          block.first.dig("ansible.builtin.blockinfile", "mode").to_s
               .include?("seafile_server_config_stat.stat.mode")
    RUBY
    to: "true",
    rows: ["a quota that declares the mode of a file it did not read"]
  },
  {
    label: "the redacted web configuration check",
    program: :static,
    from: 'quota_io.length >= 1 && quota_io.all? { |task| task["no_log"] == true }',
    to: "true",
    rows: ["a quota repair that renders the database password into the transcript"]
  },
  {
    label: "the restart-carries-the-quota check",
    program: :static,
    from: <<~'RUBY'.chomp,
      restart.length == 1 &&
          Array(restart.first["when"]).any? { |value| value.to_s.include?("seafile_server_config_repair is changed") }
    RUBY
    to: "true",
    rows: ["a quota repair nothing reloads"]
  },
  {
    label: "the disk alert behind the file store check",
    program: :static,
    from: 'disk_alert && disk_alert["value"].to_i.positive? && disk_alert["value"].to_i <= 90',
    to: "true",
    rows: ["an unbounded file store with no disk alert behind it"]
  },
  {
    label: "the server-only force-recreate check",
    program: :static,
    # The whole condition rather than one clause, and two rows against it: the
    # recreate has to stay narrow AND has to stop once it worked, and a plant
    # that satisfied either half alone would prove neither.
    from: 'recreate.length == 1 &&
    recreate.first.dig("community.docker.docker_compose_v2", "state") == "present" &&
    recreate.first.dig("community.docker.docker_compose_v2", "services") == ["seafile"] &&
    recreate.first.dig("community.docker.docker_compose_v2", "dependencies") == false &&
    Array(recreate_block&.fetch("when", nil)).include?("not seafile_boot_recovered | bool")',
    to: "true",
    rows: ["a wedged-boot recreate that bounces the database with the server",
           "a recreate budget that keeps spending after the server recovered"]
  },
  {
    label: "the diagnostics-before-recreate ordering",
    program: :static,
    from: "health_capture && recovery_include && health_capture < recovery_include",
    to: "true",
    rows: ["a health verdict read after the container it describes is replaced"]
  },
  {
    label: "the narrowed-inspection check",
    program: :static,
    from: "unformatted_inspects.empty?",
    to: "true",
    rows: ["an inspection wide enough to print the rendered environment"]
  },
  {
    label: "the wedged-boot recreate budget check",
    program: :static,
    from: 'options.dig("seafile_wedged_boot_recreate_limit", "type") == "int" &&
    defaults["seafile_wedged_boot_recreate_limit"] == 1',
    to: "true",
    rows: ["a recreate budget the rescue cannot count with"]
  },
  {
    label: "the administrator token exchange check",
    program: :static,
    from: 'login &&
    login.dig("ansible.builtin.uri", "url").to_s.end_with?("/auth-token/") &&
    login.dig("ansible.builtin.uri", "body", "username") == "{{ vault_seafile_admin_email }}" &&
    login.dig("ansible.builtin.uri", "body", "password") == "{{ vault_seafile_admin_password }}"',
    to: "true",
    rows: ["a verification that authenticates as somebody else"]
  },
  {
    label: "the credential redaction check",
    program: :static,
    from: 'credential_tasks.length >= 2 && credential_tasks.all? { |task| task["no_log"] == true }',
    to: "true",
    rows: ["a task naming a credential without redaction"]
  },
  {
    label: "the contract port agreement",
    program: :static,
    from: <<~'RUBY'.chomp,
      wrapper_port && Integer(wrapper_port, 10) == defaults["seafile_port"] &&
          Array(server["ports"]) == ["#{defaults['seafile_port']}:80"]
    RUBY
    to: "true",
    rows: ["a contract default port that drifted from the role"]
  },
  {
    label: "the storage recovery classification check",
    program: :static,
    from: 'declarations.length == 3 && declarations.all? { |entry| entry["recovery"] == "critical" }',
    to: "true",
    rows: ["a Seafile root that disaster recovery would skip"]
  },
  {
    label: "the backup root privacy check",
    program: :static,
    from: 'backup_declaration && backup_declaration["mode"] == "0700"',
    to: "true",
    rows: ["a backup root anybody on the host can read"]
  },
  {
    label: "the backup-before-Compose ordering check",
    program: :static,
    from: "backup_include && first_deployment && backup_include < first_deployment",
    to: "true",
    rows: ["a backup taken after Compose has already started the stack"]
  },
  {
    label: "the consistent-snapshot check",
    program: :static,
    from: 'dump_argv.include?("--single-transaction") &&',
    to: "",
    rows: ["three databases dumped without one consistent snapshot"]
  },
  {
    label: "the check that the dump may fail the run",
    program: :static,
    from: 'dump.any? { |task| task.key?("failed_when") }',
    to: "false",
    rows: ["a dump the run is allowed to survive"]
  },
  {
    # The ordering is the claim the whole backup rests on, so its plant is the
    # one to read first if this file ever goes quiet: with the comparison gone
    # both tasks are still there and the backup still writes two things.
    label: "the dump-before-copy ordering check",
    program: :static,
    from: "dump_index && conf_copy && dump_index < conf_copy",
    to: "true",
    rows: ["the volume copied before the database that names it"]
  },
  {
    # The #492 guard, and the one plant in this file whose absence has already
    # cost a lane run: with it gone the contract passes and the role's census
    # comes back wearing a `{% raw %}` prefix that matches nothing.
    label: "the raw-tag-inside-an-expression check",
    program: :static,
    from: "raw_inside_expression.empty?",
    to: "true",
    rows: ["an image census whose Go template Jinja will not process"]
  },
  {
    label: "the unreadable-census guard",
    program: :static,
    from: "failures << \"a Seafile stack census that parsed nothing must fail rather than read as stopped\" unless\n    census_guard",
    to: "failures << \"\" if false",
    rows: ["a stack census that parsed nothing reported as a stopped stack"]
  },
  {
    label: "the forced-backup guard",
    program: :static,
    from: "failures << \"a forced Seafile backup with no stack to dump must fail rather than report itself away\" unless\n    force_guard",
    to: "failures << \"\" if false",
    rows: ["a forced backup with no stack to dump reported away"]
  },
  {
    label: "the admin.txt exclusion check",
    program: :static,
    from: 'conf_find && Array(conf_find.dig("ansible.builtin.find", "excludes")).include?("admin.txt")',
    to: "true",
    rows: ["a configuration backup that preserves the plaintext administrator handoff"]
  },
  {
    label: "the healthy-container census",
    program: :runtime,
    # The census clause specifically, not the identical comparison inside
    # wait_for_health: the two say the same thing about different moments, and a
    # plant that matched both would prove neither.
    from: <<~'RUBY'.chomp,
      fail_contract("the Seafile #{role} container #{container} is #{health}, not healthy") unless
            health == "healthy"
    RUBY
    to: "nil",
    rows: ["a cache Docker calls unhealthy"]
  },
  {
    label: "the container-side seafevents path check",
    program: :runtime,
    from: 'fail_contract("Seafile does not keep its event configuration at #{CONTAINER_SEAFEVENTS}") unless
    status.success?',
    to: "nil",
    rows: ["a server that keeps its event configuration somewhere else"]
  },
  {
    label: "the one-file check on the two seafevents copies",
    program: :runtime,
    from: "Digest::SHA256.hexdigest(inside) == Digest::SHA256.hexdigest(outside)",
    to: "true",
    rows: ["a host copy that is not the container's file"]
  },
  {
    label: "the file indexing setting check",
    program: :runtime,
    from: 'current == "false"',
    to: "true",
    rows: ["file indexing left running against an absent Elasticsearch"]
  },
  {
    label: "the audit log setting check",
    program: :runtime,
    from: 'audit == "true"',
    to: "true",
    rows: ["an audit log switched off by a repair that hit every enabled key"]
  },
  {
    label: "the declared quota block check",
    program: :runtime,
    from: "content.include?(QUOTA_MARKER)",
    to: "true",
    rows: ["a storage quota no marker identifies as this platform's"]
  },
  {
    label: "the parseable default quota check",
    program: :runtime,
    from: "content.match(DEFAULT_QUOTA)",
    to: "true",
    rows: [
      "a quota seaf-server parses as no quota",
      "a default quota declared under a section seaf-server does not read"
    ]
  },
  {
    label: "the quota restart precondition",
    program: :runtime,
    from: %q(quota_block_present?("before the restart")),
    to: "true",
    rows: ["a restart probe run before the quota reconciliation"]
  },
  {
    label: "the quota block restart-persistence check",
    program: :runtime,
    from: %q(quota_block_present?("after the restart")),
    to: "true",
    rows: ["a start that regenerates the server configuration over the owned block"]
  },
  {
    label: "the root identity check",
    program: :runtime,
    from: 'stdout.strip == "root"',
    to: "true",
    rows: ["a database answering as somebody other than root"]
  },
  {
    label: "the negative database control",
    program: :runtime,
    from: "wrong_tcp.success?",
    to: "false",
    rows: ["a database accepting a password nothing wrote"]
  },
  {
    label: "the Valkey-is-the-cache check",
    program: :runtime,
    from: "families.empty?",
    to: "false",
    rows: ["a cache serving nothing but its own health check"]
  },
  {
    label: "the administrator token check",
    program: :runtime,
    from: 'code == "200" && !token.empty?',
    to: "true",
    rows: ["a server that will not issue an administrator token", "a 200 carrying no token at all"]
  },
  {
    label: "the negative token control",
    program: :runtime,
    from: 'wrong_code == "200" && !wrong_token.empty?',
    to: "false",
    rows: ["a server issuing a token for a password the vault never authored"]
  },
  {
    label: "the pre-restart precondition",
    program: :runtime,
    from: 'before == "false"',
    to: "true",
    rows: ["a restart probe run before the reconciliation"]
  },
  {
    label: "the first-run-only rewrite check",
    program: :runtime,
    from: 'after == "false"',
    to: "true",
    rows: ["a server that rewrites the platform-owned key on start"]
  },
  {
    label: "the post-restart readiness wait",
    program: :runtime,
    from: 'wait_for_server("its API after the restart")',
    to: "nil",
    rows: ["a restarted server that never serves again"],
    # Without the wait the mode proceeds straight to the token exchange, which
    # the fixture still answers -- so what catches this is the row failing to be
    # refused at all, reported as the accepted case.
    detects: "accepted what it must refuse"
  },
  {
    label: "the mode guard",
    program: :runtime,
    from: 'fail_contract("unknown mode: #{MODE}") unless MODES.include?(MODE)',
    to: "nil",
    rows: ["a mode the contract does not implement"]
  },
  # --- the restore rehearsal -------------------------------------------------
  #
  # Five plants, and the first two are the ones that matter: a rehearsal that
  # stops checking whether it broke anything, and one that stops checking what
  # came back, both still run every step and both still report success.
  {
    label: "the dropped-database negative control",
    program: :runtime,
    from: ') if code == "200" && !issued.to_s.empty?',
    to: ") if false",
    rows: ["a server still issuing tokens with its databases dropped"]
  },
  {
    label: "the restored content comparison",
    program: :runtime,
    from: "  ) unless content == REHEARSAL_CONTENT",
    to: "  ) unless true",
    rows: ["a file that came back as bytes nobody uploaded"]
  },
  {
    label: "the seeded read-back",
    program: :runtime,
    from: 'download_rehearsal_file(token, library, "the seed download") == REHEARSAL_CONTENT',
    to: "true",
    rows: ["an upload the server answered and did not store"]
  },
  {
    label: "the backup admin.txt exclusion proof",
    program: :runtime,
    from: 'File.exist?(File.join(backup, "conf", "admin.txt"))',
    to: "false",
    rows: ["a backup that kept the plaintext administrator handoff"]
  },
  {
    label: "the empty-dump check",
    program: :runtime,
    from: "File.size(dump).positive?",
    to: "true",
    rows: ["a backup whose dump is an empty file"]
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
    from: 'exec ruby "$runtime_program" "$mode" </dev/null',
    to: 'exec ruby "$runtime_program" "$mode"',
    layer: :runtime_stdin
  },
  {
    label: "the static program resolved from the inspected tree",
    from: "static_program=$contract_repo_dir/tests/contracts/seafile-static.rb",
    to: "static_program=$repo_dir/tests/contracts/seafile-static.rb",
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
    from: "  static|run|restart-persistence|restore-rehearsal-seed|restore-rehearsal-assert) ;;",
    to: "  static|run|restart-persistence|verify|drift|notify|--platform|restart) ;;",
    layer: :wrapper
  },
  {
    label: "the mode handed to the runtime half",
    from: 'exec ruby "$runtime_program" "$mode" </dev/null',
    to: 'exec ruby "$runtime_program" </dev/null',
    layer: :mode
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
    Dir.mktmpdir("nas-platform-seafile-mutant.") do |directory|
      name = mutation.fetch(:program) == :static ? "seafile-static.rb" : "seafile-runtime.rb"
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
             when :mode then mode_passthrough_failures(wrapper_source: source)
             else wrapper_failures(wrapper_source: source)
             end
    collected << "removing #{mutation.fetch(:label)} was accepted" if caught.empty?
  end

  planted = PROGRAM_MUTATIONS.length + WRAPPER_MUTATIONS.length
  unless mismatches.empty?
    mismatches.each { |mismatch| warn "FAIL self-test: #{mismatch}" }
    abort "#{mismatches.length} self-test mismatch(es) of #{planted} planted regressions"
  end

  puts "seafile contract: self-test detects #{planted} planted regressions"
  exit
end

failures = static_failures(STATIC_PROGRAM) + runtime_failures(RUNTIME_PROGRAM) +
           wrapper_failures + run_env_failures + mode_passthrough_failures +
           stdin_failures + runtime_stdin_failures + two_roots_failures
unless failures.empty?
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} Seafile contract violation(s)"
end

puts "seafile contract: #{STATIC_ROWS.length} static and #{RUNTIME_ROWS.length} runtime properties " \
     "hold across all four runtime modes, the run-mode environment contract refuses each name with " \
     "the wrapper's own message, and both programs come from the checkout with an empty stdin"
