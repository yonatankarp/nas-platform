#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Behaviour of the Nextcloud service contract's two Ruby programs and its
# wrapper.
#
# Three layers, because the contract has three kinds of property:
#
#   Static -- build a fixture repository from the files the program reads, break
#   exactly one thing in it, and require the program to name that thing. The
#   assertion text is the interface: a guard that fails for the wrong reason has
#   stopped guarding what it names, so every row pins the exact diagnostic.
#
#   Runtime -- serve Nextcloud's status endpoint and OCS from an HTTP fixture and
#   put `docker` and `ansible-vault` stubs on PATH, so every census, occ read,
#   status field and credential outcome can be moved one at a time. There is one
#   runtime mode here rather than Seafile's four, and tests/contracts/nextcloud.sh
#   records why.
#
#   Wrapper -- tests/contracts/nextcloud.sh is what turns a mode into an
#   invocation. Its rows prove the mode guard, that the mode reaches the runtime
#   half, the run-mode environment contract, that both programs come from the
#   checkout while the tree the static half inspects does not, and that neither
#   can eat the caller's stdin.
#
# Run with --self-test to plant a regression in each program and in the wrapper.
# It accumulates its mismatches rather than aborting on the first, and every
# plant is built before the worker pool: `abort` inside a worker raises
# SystemExit there, which in_parallel_cases deliberately does not rescue, so the
# run ends on it with nothing reported rather than naming the plant that failed.
#
# On the cost of this file, which CLAUDE.md's `static` budget section is about:
# every invocation that must end in a refusal by the wrapper substitutes a stub
# for the runtime half, and every invocation that reaches the real runtime half
# carries each of its timeout budgets in its own environment. Nothing here is
# entitled to wait -- a row whose expected outcome is a refusal has no reason to
# sit out a readiness budget, and that shape is exactly what cost the seerr
# self-test 368 seconds before #331. RUNTIME_BUDGETS is the shared set, and a row
# may override any of them through `environment:`; exactly one does, because it
# is the only row whose expected refusal IS a deadline expiring, and it says so
# where it stands.

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
DIAGNOSTIC_PREFIX = "Nextcloud contract failed: "
CONTRACT = File.join(ROOT, "tests", "contracts", "nextcloud.sh")
STATIC_PROGRAM = File.join(ROOT, "tests", "contracts", "nextcloud-static.rb")
RUNTIME_PROGRAM = File.join(ROOT, "tests", "contracts", "nextcloud-runtime.rb")

SUCCESS_LINE = "nextcloud static contract: gated four-container document store ownership holds"
MODE_REFUSAL = "nextcloud contract accepts only static or run"

# Exactly the static program's own `required` list plus the shared flatten_tasks
# it requires through PLATFORM_CONTRACT_REPO_DIR. tests/contracts/nextcloud.sh is
# in it because the static half reads the wrapper's default port out of the
# inspected tree and compares it with that tree's role default.
FIXTURE_FILES = %w[
  roles/nextcloud/defaults/main.yml
  roles/nextcloud/meta/argument_specs.yml
  roles/nextcloud/tasks/main.yml
  roles/nextcloud/tasks/storage.yml
  roles/nextcloud/tasks/deploy.yml
  roles/nextcloud/tasks/reconcile_trusted_domains.yml
  roles/nextcloud/tasks/reconcile_admin.yml
  roles/nextcloud/tasks/reconcile_apps.yml
  roles/nextcloud/tasks/report.yml
  roles/nextcloud/tasks/verify.yml
  roles/nextcloud/templates/env.j2
  services/nextcloud/compose.yml
  services/nextcloud/compose.mac.yml
  services/nextcloud/compose.integration.yml
  tests/expected/nextcloud.yml
  tests/contracts/nextcloud.sh
  inventory/group_vars/all/main.yml
  tests/policy_support.rb
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

def edit_nextcloud_tasks(root, file)
  edit_yaml(root, "roles/nextcloud/tasks/#{file}.yml") { |document| yield document }
end

def compose_service(document, name)
  document.fetch("services").fetch(name)
end

# --- static layer ----------------------------------------------------------

COMPOSE_STATIC_ROWS = [
  { name: "an intact repository", break: ->(_root) {}, expects: nil },
  {
    name: "a declared file that is gone",
    break: ->(root) { FileUtils.rm(File.join(root, "services/nextcloud/compose.mac.yml")) },
    expects: "missing services/nextcloud/compose.mac.yml"
  },
  {
    name: "an image pinned by tag alone",
    break: lambda { |root|
      edit_yaml(root, "services/nextcloud/compose.yml") do |document|
        compose_service(document, "db")["image"] = "docker.io/library/postgres:18.6-alpine"
      end
    },
    expects: "the Nextcloud db image must pin docker.io/library/postgres by tag and manifest digest"
  },
  {
    # The split Renovate bump, which is the way this one actually happens: two
    # containers on one image, one of them updated.
    name: "a cron sidecar left on the previous image",
    break: lambda { |root|
      edit_yaml(root, "services/nextcloud/compose.yml") do |document|
        compose_service(document, "cron")["image"] =
          "docker.io/library/nextcloud:33.0.8-apache@sha256:" + ("9" * 64)
      end
    },
    expects: "the Nextcloud application and its cron sidecar must pin one identical image"
  },
  {
    name: "a CPU ceiling that drifted from the expected file",
    break: lambda { |root|
      edit_yaml(root, "services/nextcloud/compose.yml") do |document|
        compose_service(document, "cache")["cpus"] = 1.5
      end
    },
    expects: "each Nextcloud container must take the CPU ceiling tests/expected/nextcloud.yml declares"
  },
  {
    name: "a renamed production container",
    break: lambda { |root|
      edit_yaml(root, "services/nextcloud/compose.yml") do |document|
        compose_service(document, "cache")["container_name"] = "nextcloud-valkey"
      end
    },
    expects: "each Nextcloud container must carry its production name"
  },
  {
    name: "two overrides that disagree about a sandbox container",
    break: lambda { |root|
      edit_yaml(root, "services/nextcloud/compose.mac.yml") do |document|
        compose_service(document, "cron")["container_name"] = "${PLATFORM_PROJECT_NAME:?}-nextcloud-jobs"
      end
    },
    expects: "both disposable Nextcloud overrides must name the same four sandbox containers"
  },
  {
    name: "a cluster published on the network",
    break: lambda { |root|
      edit_yaml(root, "services/nextcloud/compose.yml") do |document|
        compose_service(document, "db")["ports"] = ["5432:5432"]
      end
    },
    expects: "only the Nextcloud application may publish a port"
  },
  {
    name: "a volume bound to a literal host path",
    break: lambda { |root|
      edit_yaml(root, "services/nextcloud/compose.yml") do |document|
        compose_service(document, "db")["volumes"] = ["/volume1/Docker/nextcloud/postgres:/var/lib/postgresql"]
      end
    },
    expects: "every Nextcloud volume source must be a required environment reference"
  },
  {
    name: "a container Dozzle cannot group",
    break: lambda { |root|
      edit_yaml(root, "services/nextcloud/compose.yml") do |document|
        compose_service(document, "cron")["labels"].delete("dev.dozzle.group")
      end
    },
    expects: "every Nextcloud container must carry its Dozzle group and name"
  },
  {
    # A cron sidecar with a volume of its own runs background jobs against a
    # tree nothing upgrades, and nothing about the container's own state says so.
    name: "a cron sidecar with an installation of its own",
    break: lambda { |root|
      edit_yaml(root, "services/nextcloud/compose.yml") do |document|
        compose_service(document, "cron")["volumes"] = ["${NEXTCLOUD_CRON_PATH:?}:/var/www/html"]
      end
    },
    expects: "the Nextcloud cron sidecar must mount the application's own installation"
  },
  {
    name: "a cron sidecar started through the installing entrypoint",
    break: lambda { |root|
      edit_yaml(root, "services/nextcloud/compose.yml") do |document|
        compose_service(document, "cron").delete("entrypoint")
      end
    },
    expects: "the Nextcloud cron sidecar must bypass the installing entrypoint"
  },
  {
    # Correct for postgres 17 and earlier, and it is what services/immich still
    # does on its pinned 14 -- which is exactly why copying the wrong sibling is
    # the plausible mistake rather than an implausible one.
    name: "a cluster bound one level below where postgres 18 puts it",
    break: lambda { |root|
      edit_yaml(root, "services/nextcloud/compose.yml") do |document|
        compose_service(document, "db")["volumes"] = ["${NEXTCLOUD_POSTGRES_PATH:?}:/var/lib/postgresql/data"]
      end
    },
    expects: "the Nextcloud cluster must be bound where postgres:18 puts it"
  },
  {
    name: "an application started against a cluster that is merely up",
    break: lambda { |root|
      edit_yaml(root, "services/nextcloud/compose.yml") do |document|
        compose_service(document, "nextcloud")["depends_on"]["db"]["condition"] = "service_started"
      end
    },
    expects: "the Nextcloud application must wait for a healthy database and cache"
  },
  {
    name: "a cron sidecar racing the installation",
    break: lambda { |root|
      edit_yaml(root, "services/nextcloud/compose.yml") do |document|
        compose_service(document, "cron")["depends_on"]["nextcloud"]["condition"] = "service_started"
      end
    },
    expects: "the Nextcloud cron sidecar must wait for an installed application"
  },
  {
    # THE ROW THIS CONTRACT EXISTS FOR. Removing this variable is not a
    # misconfiguration that a later converge repairs: the installer mints
    # `oc_admin` on the first converge and the install branch never runs again.
    name: "an installer left free to mint its own database account",
    break: lambda { |root|
      edit_yaml(root, "services/nextcloud/compose.yml") do |document|
        compose_service(document, "nextcloud")["environment"].delete("NC_setup_create_db_user")
      end
    },
    expects: "Nextcloud must refuse to mint a database account the vault does not know"
  },
  {
    name: "a database password config.php outranks",
    break: lambda { |root|
      edit_yaml(root, "services/nextcloud/compose.yml") do |document|
        compose_service(document, "nextcloud")["environment"].delete("NC_dbpassword")
      end
    },
    expects: "Nextcloud must push NC_dbpassword so the vault outranks config.php"
  },
  {
    # Measured rather than reasoned: an NC_ override of an array-valued setting
    # makes trusted_domains a scalar, and every request then answers 400 --
    # /status.php included, for Host: 127.0.0.1 as much as for anything else.
    name: "an array-valued system setting pushed through the environment",
    break: lambda { |root|
      edit_yaml(root, "services/nextcloud/compose.yml") do |document|
        compose_service(document, "nextcloud")["environment"]["NC_trusted_domains"] = "127.0.0.1 localhost"
      end
    },
    expects: "Nextcloud must not push an array-valued system setting through NC_"
  },
  {
    # The installer landmine's second half. Suppressing setup_create_db_user keeps
    # the installer on the account it was handed; this is what makes that account
    # the vault's own rather than whatever the postgres image would otherwise
    # initialise. A cluster created as `postgres`@`postgres` is a stack holding a
    # credential this vault never authored, unrotatable for the same reason the
    # minted `oc_admin` is -- so both halves have to be asserted, not one.
    name: "a cluster initialised with an account the vault never authored",
    break: lambda { |root|
      edit_yaml(root, "services/nextcloud/compose.yml") do |document|
        environment = compose_service(document, "db")["environment"]
        environment["POSTGRES_DB"] = "nextcloud"
        environment["POSTGRES_USER"] = "postgres"
      end
    },
    expects: "the Nextcloud cluster must declare the vault's own database and owner"
  },
  {
    name: "a cluster probe asking about the image defaults",
    break: lambda { |root|
      edit_yaml(root, "services/nextcloud/compose.yml") do |document|
        compose_service(document, "db")["healthcheck"]["test"] = ["CMD-SHELL", "pg_isready"]
      end
    },
    expects: "the Nextcloud database probe must name the role and database the stack uses"
  },
  {
    name: "a deployment wait shorter than the probe it waits on",
    break: lambda { |root|
      edit_yaml(root, "roles/nextcloud/defaults/main.yml") do |document|
        document["nextcloud_compose_wait_timeout"] = 120
      end
    },
    expects: "nextcloud_compose_wait_timeout must outlast the nextcloud probe's own worst-case verdict"
  }
].freeze

# The role's own half. Split from the compose rows above only so the two lists
# stay readable; they are concatenated into one STATIC_ROWS below and the runner
# does not distinguish them.
ROLE_STATIC_ROWS = [
  {
    name: "a stage the role stopped importing",
    break: lambda { |root|
      edit_nextcloud_tasks(root, "main") do |document|
        document.reject! { |task| task["ansible.builtin.import_tasks"] == "report.yml" }
      end
    },
    expects: "the Nextcloud role must import every stage it owns"
  },
  {
    # A dynamic include puts the task file outside what
    # tests/policy_mutation_support.rb copies into a sandbox and outside what
    # verify.yml's `tags: [never]` can reach, and neither failure names itself.
    #
    # ADDED rather than substituted, and the self-test is what forced that:
    # converting an existing import into an include also removes that stage from
    # the imported list, so "the role must import every stage it owns" fired
    # first and this row proved that assertion instead of the one it names.
    name: "a stage reached by a dynamic include",
    break: lambda { |root|
      edit_nextcloud_tasks(root, "main") do |document|
        document << {
          "name" => "Reconcile something later",
          "ansible.builtin.include_tasks" => "reconcile_apps.yml"
        }
      end
    },
    expects: "every Nextcloud stage must be statically imported"
  },
  {
    name: "a reconciliation that runs before the stack it reconciles",
    break: lambda { |root|
      edit_nextcloud_tasks(root, "main") do |document|
        stage = document.find do |task|
          task["ansible.builtin.import_tasks"] == "reconcile_trusted_domains.yml"
        end
        document.delete(stage)
        document.unshift(stage)
      end
    },
    expects: "both Nextcloud reconciliations must run after the deployment"
  },
  {
    # The ordering whose violation is silent. The administrator probe is an HTTP
    # request, and a Host header the server does not trust answers 400, which the
    # classifier reads as `unavailable` rather than as `rotated` -- so the repair
    # declines to run on exactly the stack that needed it.
    name: "an administrator probed before the domains that let it answer",
    break: lambda { |root|
      edit_nextcloud_tasks(root, "main") do |document|
        admin = document.find { |task| task["ansible.builtin.import_tasks"] == "reconcile_admin.yml" }
        trusted = document.find do |task|
          task["ansible.builtin.import_tasks"] == "reconcile_trusted_domains.yml"
        end
        document[document.index(admin)], document[document.index(trusted)] = trusted, admin
      end
    },
    expects: "the Nextcloud trusted domains must be repaired before the administrator is probed"
  },
  {
    name: "a disabled project left running rather than torn down",
    break: lambda { |root|
      edit_nextcloud_tasks(root, "deploy") do |document|
        document.reject! do |task|
          task.dig("community.docker.docker_compose_v2", "state") == "absent"
        end
      end
    },
    expects: "the disabled Nextcloud project must be torn down rather than left running"
  },
  {
    name: "a deployment that ignores the operator switch",
    break: lambda { |root|
      edit_nextcloud_tasks(root, "deploy") do |document|
        document.each do |task|
          next unless task.dig("community.docker.docker_compose_v2", "state") == "present"

          task["when"] = Array(task["when"]).reject do |value|
            value.to_s.include?("nextcloud_deployment_enabled")
          end
        end
      end
    },
    expects: "every Nextcloud deployment task must be gated on the operator switch"
  },
  {
    # THE ROW CI WROTE. The verify assert shipped without this gate and reported
    # an absent Nextcloud as a broken one, in the smoke and idempotence-check
    # lanes, on a stack that was correctly switched off.
    name: "a task that reads a stack this run never started",
    break: lambda { |root|
      edit_nextcloud_tasks(root, "verify") do |document|
        task = document.find { |candidate| candidate.key?("ansible.builtin.uri") }
        task["when"] = ["not ansible_check_mode"]
      end
    },
    expects: "every Nextcloud task touching the running stack must be gated on the switch and check mode"
  },
  {
    name: "an occ invocation that writes root-owned files into the installation",
    break: lambda { |root|
      edit_nextcloud_tasks(root, "reconcile_trusted_domains") do |document|
        document.each do |task|
          next unless task.key?("community.docker.docker_compose_v2_exec")

          task["community.docker.docker_compose_v2_exec"]["user"] = "root"
        end
      end
    },
    expects: "every Nextcloud occ invocation must run as the account that owns the installation"
  },
  {
    # `occ config:system:set trusted_domains N` REPLACES index N, so a constant
    # there overwrites an entry the server already trusts -- and the first one it
    # would overwrite is the entry the installer put at 0.
    name: "a trusted domain repair that overwrites index zero",
    break: lambda { |root|
      edit_nextcloud_tasks(root, "reconcile_trusted_domains") do |document|
        task = document.find do |candidate|
          Array(candidate.dig("community.docker.docker_compose_v2_exec", "argv"))
            .map(&:to_s).include?("config:system:set")
        end
        argv = task["community.docker.docker_compose_v2_exec"]["argv"]
        argv[argv.index { |value| value.to_s.include?("length + index") }] = "0"
      end
    },
    expects: "the Nextcloud trusted domain repair must append rather than overwrite"
  },
  {
    name: "a trusted domain list without the host this platform polls",
    break: lambda { |root|
      edit_yaml(root, "roles/nextcloud/defaults/main.yml") do |document|
        document["nextcloud_trusted_domains"] = "{{ ['localhost'] }}"
      end
    },
    expects: "the Nextcloud trusted domains must carry the two hosts this platform itself requests"
  },
  {
    # --password-from-env is the only spelling that keeps the value off the
    # process table, where `ps` on the NAS would print it for anyone logged in.
    name: "an administrator password passed on the command line",
    break: lambda { |root|
      edit_nextcloud_tasks(root, "reconcile_admin") do |document|
        task = document.find do |candidate|
          Array(candidate.dig("community.docker.docker_compose_v2_exec", "argv"))
            .map(&:to_s).any? { |value| value.include?("user:resetpassword") }
        end
        argv = task["community.docker.docker_compose_v2_exec"]["argv"]
        argv[argv.length - 1] = argv.last.to_s.sub("--password-from-env", "--password=hunter2")
      end
    },
    expects: "the rotated Nextcloud administrator must be reset through the environment"
  },
  {
    # occ user:resetpassword always succeeds and always re-hashes, which
    # invalidates every session the account holds. Unconditional, that logs every
    # client out on every five-minute poller tick.
    name: "an administrator reset on every converge rather than on a refusal",
    break: lambda { |root|
      edit_nextcloud_tasks(root, "reconcile_admin") do |document|
        task = document.find do |candidate|
          Array(candidate.dig("community.docker.docker_compose_v2_exec", "argv"))
            .map(&:to_s).any? { |value| value.include?("user:resetpassword") }
        end
        task["when"] = Array(task["when"]).reject { |value| value.to_s.include?("rotated") }
      end
    },
    expects: "the Nextcloud administrator must be repaired only when the server refuses the vault"
  },
  {
    # The redaction rule beside it cannot see this task: it selects on tasks that
    # spell a `vault_nextcloud_` name, and this one reads the password out of the
    # rendered container environment instead. So the guard is separate and this
    # row is what proves it still runs -- an unredacted failure of that exec
    # prints the whole container environment into the play's output, and from
    # there into whatever CI or the poller kept.
    name: "an administrator repair that would print the container environment",
    break: lambda { |root|
      edit_nextcloud_tasks(root, "reconcile_admin") do |document|
        task = document.find do |candidate|
          Array(candidate.dig("community.docker.docker_compose_v2_exec", "argv"))
            .map(&:to_s).any? { |value| value.include?("user:resetpassword") }
        end
        task.delete("no_log")
      end
    },
    expects: "the Nextcloud administrator repair carries a credential and must be redacted"
  },
  {
    # A port check passes here and this does not, which is the whole point:
    # status.php boots the server and the boot queries oc_appconfig.
    name: "verification that settles for an endpoint the database cannot fail",
    break: lambda { |root|
      edit_nextcloud_tasks(root, "verify") do |document|
        task = document.find { |candidate| candidate.key?("ansible.builtin.uri") }
        task["ansible.builtin.uri"]["url"] = "{{ nextcloud_url }}/robots.txt"
      end
    },
    expects: "Nextcloud verification must read the endpoint that boots the server"
  },
  {
    name: "verification blind to an unfinished upgrade",
    break: lambda { |root|
      edit_nextcloud_tasks(root, "verify") do |document|
        task = document.find { |candidate| candidate.key?("ansible.builtin.assert") }
        task["ansible.builtin.assert"]["that"] =
          Array(task["ansible.builtin.assert"]["that"]).reject do |value|
            value.to_s.include?("needsDbUpgrade")
          end
      end
    },
    expects: "Nextcloud verification must prove an installed, serving, migrated instance"
  },
  {
    name: "a credential task that prints what it carries",
    break: lambda { |root|
      edit_nextcloud_tasks(root, "deploy") do |document|
        document.each { |task| task.delete("no_log") }
      end
    },
    expects: "every Nextcloud task naming a vault credential must be redacted"
  },
  {
    name: "a storage root outside the Docker root",
    break: lambda { |root|
      edit_yaml(root, "roles/nextcloud/defaults/main.yml") do |document|
        document["nextcloud_postgres_host_path"] = "/var/lib/nextcloud/postgres"
      end
    },
    expects: "Nextcloud must keep its installation and cluster roots under the Docker root"
  },
  {
    name: "a vault credential the role does not require",
    break: lambda { |root|
      edit_yaml(root, "roles/nextcloud/meta/argument_specs.yml") do |document|
        document["argument_specs"]["main"]["options"]["vault_nextcloud_db_password"]["required"] = false
      end
    },
    expects: "every Nextcloud vault credential must be a required role argument"
  },
  {
    # The string "false" is true in Jinja, and this one value selects between the
    # teardown branch and the deploy branch.
    name: "an operator switch left to a truthy string",
    break: lambda { |root|
      edit_yaml(root, "roles/nextcloud/meta/argument_specs.yml") do |document|
        document["argument_specs"]["main"]["options"]["nextcloud_deployment_enabled"]["type"] = "str"
      end
    },
    expects: "the Nextcloud operator switch must be a required declared boolean"
  },
  {
    name: "a contract default port that drifted from the role",
    break: lambda { |root|
      mutate_text(root, "tests/contracts/nextcloud.sh",
                  "PLATFORM_NEXTCLOUD_PORT:=8084", "PLATFORM_NEXTCLOUD_PORT:=8085")
    },
    expects: "the Nextcloud contract's default port must be the port the role publishes"
  },
  {
    # Compose interpolates $ in an env file and silently truncates what follows.
    name: "a credential Compose will truncate at its first dollar",
    break: lambda { |root|
      mutate_text(root, "roles/nextcloud/templates/env.j2",
                  "vault_nextcloud_db_password | replace('$', '$$')", "vault_nextcloud_db_password")
    },
    expects: "every Nextcloud credential must survive Compose's own interpolation"
  },
  {
    name: "a storage root declared replaceable",
    break: lambda { |root|
      edit_yaml(root, "inventory/group_vars/all/main.yml") do |document|
        document["nas_storage"].each do |entry|
          entry["recovery"] = "cache" if entry["path"].to_s.include?("/nextcloud/")
        end
      end
    },
    expects: "every Nextcloud storage root must be declared irreplaceable"
  },
  {
    name: "a restart deferred to a handler",
    break: ->(root) { FileUtils.mkdir_p(File.join(root, "roles/nextcloud/handlers")) },
    expects: "the Nextcloud restart must be a task rather than a deferred handler"
  },
  {
    # #492's defect class, planted rather than assumed. This role writes no Go
    # template today, so this row is the only thing that demonstrates the scanner
    # can still see one -- which is why the guard is carried despite having no
    # subject in the shipped tree.
    name: "a raw tag inside a Jinja expression",
    break: lambda { |root|
      edit_nextcloud_tasks(root, "report") do |document|
        document.first["name"] = "{{ '{% raw %}nextcloud={{.Name}}{% endraw %}' }}"
      end
    },
    expects: "no Nextcloud Jinja expression may contain a raw tag, which Jinja will not process"
  },
  {
    # A bare `docker inspect` prints .Config.Env, which for this stack is three
    # passwords in full. Vacuous against the shipped role, which inspects
    # nothing, and this row is what proves it stops being vacuous.
    name: "an inspection wide enough to print the container environment",
    break: lambda { |root|
      edit_nextcloud_tasks(root, "report") do |document|
        document << {
          "name" => "Census the Nextcloud stack",
          "ansible.builtin.command" => { "argv" => %w[docker container inspect nextcloud] }
        }
      end
    },
    expects: "Nextcloud diagnostics must narrow every inspection rather than print the container environment"
  },
  {
    # The one entry of the app policy #500 derives rather than chooses. Immich is
    # this platform's photo service.
    name: "an app policy that stopped disabling the photo app Immich replaces",
    break: lambda { |root|
      edit_yaml(root, "roles/nextcloud/defaults/main.yml") do |document|
        document["nextcloud_disabled_apps"] =
          document.fetch("nextcloud_disabled_apps").reject { |app| app == "photos" }
      end
    },
    expects: "must disable the photo app Immich already serves"
  },
  {
    # The off-set's other direction. `text` is collaborative editing, which #500
    # names as one of the three features this platform adopted Nextcloud for, so
    # it is the entry a later prune would most plausibly reach for.
    name: "an app policy that disabled the collaborative editor it was adopted for",
    break: lambda { |root|
      edit_yaml(root, "roles/nextcloud/defaults/main.yml") do |document|
        document["nextcloud_disabled_apps"] = document.fetch("nextcloud_disabled_apps") + ["text"]
      end
    },
    expects: "must not disable the collaborative editor it was adopted for"
  },
  {
    name: "an app policy that runs before the administrator it perturbs is probed",
    break: lambda { |root|
      edit_nextcloud_tasks(root, "main") do |document|
        stage = document.find { |task| task["ansible.builtin.import_tasks"] == "reconcile_apps.yml" }
        document.delete(stage)
        document.unshift(stage)
      end
    },
    expects: "must run after the administrator probe and before the report"
  },
  {
    # docker_compose_v2_exec sets check_rc only for `detach`, so a census that
    # failed would otherwise read as an empty app set and report a converged
    # deployment on a container it never reached.
    name: "an application census that reads a failed exit as an empty app set",
    break: lambda { |root|
      edit_nextcloud_tasks(root, "reconcile_apps") do |document|
        document.each { |task| task.delete("failed_when") if task["register"] == "nextcloud_app_census" }
      end
    },
    expects: "census must refuse a nonzero exit"
  },
  {
    # Without it, a name that can never be disabled -- one of the fourteen in
    # core/shipped.json's alwaysEnabled -- exits 2 on every five-minute poller
    # tick behind a clean recap.
    name: "an application disable that reports success on any exit code",
    break: lambda { |root|
      edit_nextcloud_tasks(root, "reconcile_apps") do |document|
        document.each { |task| task.delete("failed_when") if task["register"] == "nextcloud_app_repair" }
      end
    },
    expects: "disable must refuse a nonzero exit"
  },
  {
    # Looping the declared list rather than the intersection makes every converge
    # report changed, which is what the platform's idempotence check catches.
    name: "an application disable that loops over the declared list rather than what is enabled",
    break: lambda { |root|
      edit_nextcloud_tasks(root, "reconcile_apps") do |document|
        task = document.find { |entry| entry["register"] == "nextcloud_app_repair" }
        task["loop"] = "{{ nextcloud_disabled_apps_effective }}"
      end
    },
    expects: "must loop over what is still enabled"
  },
  {
    # The stage's silent no-op. The loop reads the name with `| default([])`, so
    # a reconciliation that binds it nowhere runs zero times for ever and every
    # app this platform disables stays enabled behind a clean recap.
    name: "an application policy that binds nothing for its own loop to read",
    break: lambda { |root|
      edit_nextcloud_tasks(root, "reconcile_apps") do |document|
        document.reject! { |task| task.key?("ansible.builtin.set_fact") }
      end
    },
    expects: "must bind the set its disable loop reads"
  },
  {
    # The same shape one step in: the name is bound, from the declared list
    # rather than the effective one, which orphans nextcloud_additional_disabled_apps
    # while the defaults, the argument_specs and the check-mode debug all still
    # describe that escape hatch as live.
    name: "an application policy that resolves the declared list rather than the effective one",
    break: lambda { |root|
      edit_nextcloud_tasks(root, "reconcile_apps") do |document|
        task = document.find { |entry| entry["ansible.builtin.set_fact"].is_a?(Hash) }
        expression = task.fetch("ansible.builtin.set_fact").fetch("nextcloud_apps_still_enabled")
        task["ansible.builtin.set_fact"]["nextcloud_apps_still_enabled"] =
          expression.sub("nextcloud_disabled_apps_effective", "nextcloud_disabled_apps")
      end
    },
    expects: "must be the effective list intersected with the live census"
  },
  {
    # `occ app:disable` exits 0 on an app that is already off, so without the
    # discriminator every such run reports changed and the idempotence lane is
    # what notices rather than this contract.
    name: "an application disable that reports a change on an app that was already off",
    break: lambda { |root|
      edit_nextcloud_tasks(root, "reconcile_apps") do |document|
        document.each { |task| task.delete("changed_when") if task["register"] == "nextcloud_app_repair" }
      end
    },
    expects: "must not report a change on an app that was already off"
  },
  {
    # The other half of the placement, and it moves the stage PAST the report
    # rather than to the front: the conjunct above still has to hold, or this row
    # is caught by that one instead of by its own. An app switched back off is a
    # change the deployment report has to carry.
    name: "an app policy that runs after the report that has to carry its change",
    break: lambda { |root|
      edit_nextcloud_tasks(root, "main") do |document|
        stage = document.find { |task| task["ansible.builtin.import_tasks"] == "reconcile_apps.yml" }
        document.delete(stage)
        report = document.find { |task| task["ansible.builtin.import_tasks"] == "report.yml" }
        document.insert(document.index(report) + 1, stage)
      end
    },
    expects: "must run after the administrator probe and before the report"
  },
  {
    # The report's changed-expression, which until now was asserted by nothing:
    # any one of its six terms could be deleted and every property in the static
    # program still held. The term this row removes is one of the two that had
    # been unguarded since they were written.
    name: "a deployment report that drops a result which can report a change",
    break: lambda { |root|
      mutate_text(root, "roles/nextcloud/tasks/report.yml",
                  "         ((nextcloud_admin_repair | default({})) is changed) or\n", "")
    },
    expects: "must name every result that can report a change"
  },
  {
    # The other direction, which is what a hand-written list rots into rather
    # than what a careless edit produces: a term naming a register the role
    # stopped writing is not an error, it is `(gone | default({})) is changed`
    # evaluating to false for ever.
    name: "a deployment report that names a result the role no longer registers",
    break: lambda { |root|
      mutate_text(root, "roles/nextcloud/tasks/report.yml",
                  "((nextcloud_app_repair | default({})) is changed) }}",
                  "((nextcloud_app_repair | default({})) is changed) or\n" \
                  "         ((nextcloud_app_reinstall | default({})) is changed) }}")
    },
    expects: "must not name a result this role no longer registers"
  },
  {
    # The two entries defaults/main.yml calls principle rather than taste. Both
    # could be dropped with a green gate while that file said the taxonomy
    # existed so a later reader "should not have to re-derive" them.
    name: "an application policy that stops disabling the two apps that phone home",
    break: lambda { |root|
      edit_yaml(root, "roles/nextcloud/defaults/main.yml") do |document|
        document["nextcloud_disabled_apps"] -= %w[updatenotification survey_client]
      end
    },
    expects: "must disable the two applications that phone home"
  }
].freeze

STATIC_ROWS = (COMPOSE_STATIC_ROWS + ROLE_STATIC_ROWS).freeze

def static_failures(program, rows = STATIC_ROWS)
  failures = []
  in_parallel_cases(failures, rows) do |row, collected|
    Dir.mktmpdir("nas-platform-nextcloud-static.") do |raw|
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
# row moves exactly one of them.

ADMIN_USERNAME = "nextcloud-contract-admin"
ADMIN_PASSWORD = "nextcloud-contract-admin-password"
DB_NAME = "fixture-nextcloud-db"
DB_USERNAME = "fixture-nextcloud-db-user"
APPLICATION_CONTAINER = "fixture-nextcloud"
CRON_CONTAINER = "fixture-nextcloud-cron"
DATABASE_CONTAINER = "fixture-nextcloud-db"
CACHE_CONTAINER = "fixture-nextcloud-cache"

# What /status.php answers on a healthy installation, field for field. The
# contract reads four of these and a row moves one at a time.
def status_document(installed: true, maintenance: false, needs_db_upgrade: false)
  {
    "installed" => installed,
    "maintenance" => maintenance,
    "needsDbUpgrade" => needs_db_upgrade,
    "version" => "34.0.3.2",
    "versionstring" => "34.0.3",
    "edition" => "",
    "productname" => "Nextcloud",
    "extendedSupport" => false
  }
end

RUNTIME_DEFAULTS = {
  mode: "run",
  inspect_ok: true,
  states: {
    APPLICATION_CONTAINER => "running healthy",
    CRON_CONTAINER => "running healthy",
    DATABASE_CONTAINER => "running healthy",
    CACHE_CONTAINER => "running healthy"
  }.freeze,
  vault_ok: true,
  vault_document: nil,
  occ_ok: true,
  # The account Nextcloud reports connecting as. `oc_admin` is the installer
  # having minted its own, which is the landmine this whole stack is shaped
  # around, and it is a row rather than a hypothetical.
  live_dbuser: DB_USERNAME,
  live_dbname: DB_NAME,
  trusted_domains: "127.0.0.1\nlocalhost\n",
  # `cron` is the settled state; nil is the one a fresh install is really in,
  # because oc_appconfig holds no `core|backgroundjobs_mode` row until cron.php
  # writes one. The stub models nil as GetConfig.php does -- exit 1 with nothing
  # on either stream unless --default-value was passed.
  backgroundjobs_mode: "cron",
  # An age rather than a timestamp, because a frozen timestamp in a fixture ages
  # with the file. nil is an installation that records no core|installedat.
  installed_age_seconds: 5,
  crontab_ok: true,
  crontab: "*/5 * * * * php -f /var/www/html/cron.php\n",
  # What a failed `docker exec` says, and where. The default is the shape the
  # first CI run of this lane actually met: exit 1 and silence.
  occ_error_text: "",
  occ_error_stream: "stderr",
  app_list: { "enabled" => { "files" => "2.0.0", "dav" => "1.32.0" }, "disabled" => {} }.freeze,
  # When non-nil the stub prints this verbatim in place of the JSON document,
  # which is the only way to model an occ that exited 0 having written something
  # that is not a census -- a deprecation notice on its own, a PHP warning.
  app_list_text: nil,
  status_code: 200,
  status_body: nil,
  admin_code: 200,
  wrong_admin_code: 401
}.freeze

# Every budget the runtime half reads, set low because no row here is entitled
# to wait: the fixture answers immediately and a row whose outcome is a refusal
# has nothing to wait for.
#
# The deadlines are 30 rather than 10 for the reason the Seafile suite measured:
# these are ceilings on how long the docker STUB may take to answer, and the stub
# answers immediately, so a larger ceiling costs nothing when nothing is slow --
# while a ceiling of 10 turns process-spawn latency inside the gate's own worker
# pool into "did not finish within 10s", which reports the wrong row as broken.
RUNTIME_BUDGETS = {
  "PLATFORM_NEXTCLOUD_READY_TIMEOUT_SECONDS" => "30",
  "PLATFORM_NEXTCLOUD_DOCKER_TIMEOUT_SECONDS" => "30",
  "PLATFORM_NEXTCLOUD_OCC_TIMEOUT_SECONDS" => "30",
  "PLATFORM_NEXTCLOUD_HTTP_OPEN_TIMEOUT_SECONDS" => "5",
  "PLATFORM_NEXTCLOUD_HTTP_READ_TIMEOUT_SECONDS" => "5",
  "PLATFORM_NEXTCLOUD_POLL_INTERVAL_SECONDS" => "1",
  # Not a timeout and nothing waits on it: it is the age at which a missing
  # background job mode stops being excused. Pinned here rather than left at the
  # deployment's own 900 so that the two rows either side of it -- an
  # installation minutes old and one that has had its chance -- state their own
  # verdict, and raising the shipped default can never silently flip one.
  "PLATFORM_NEXTCLOUD_CRON_GRACE_SECONDS" => "60"
}.freeze

def vault_document
  {
    "vault_nextcloud_admin_username" => ADMIN_USERNAME,
    "vault_nextcloud_admin_password" => ADMIN_PASSWORD,
    "vault_nextcloud_db_name" => DB_NAME,
    "vault_nextcloud_db_username" => DB_USERNAME
  }
end

# One stub for `docker`, dispatching on argv the way the real command does. It
# reads a JSON fixture rather than being regenerated per case, so a row states
# its outcome as data.
def docker_stub_source(options_path)
  <<~RUBY
    #!#{RbConfig.ruby}
    require "json"
    options = JSON.parse(File.read(#{options_path.inspect}))
    argv = ARGV
    joined = argv.join(" ")
    case argv.first
    when "inspect"
      exit 1 unless options.fetch("inspect_ok")
      puts options.fetch("states").fetch(argv.last, "running healthy")
    when "exec"
      # The crontab read is an exec but not an occ, so it is dispatched before
      # the occ gate: an occ that cannot run says nothing about whether the
      # sidecar's crontab can be read.
      if joined.include?("/var/spool/cron/crontabs/")
        unless options.fetch("crontab_ok")
          warn "Error response from daemon: No such container: \#{argv[1]}"
          exit 1
        end
        print options.fetch("crontab")
        exit 0
      end
      unless options.fetch("occ_ok")
        text = options.fetch("occ_error_text").to_s
        unless text.empty?
          options.fetch("occ_error_stream") == "stdout" ? puts(text) : warn(text)
        end
        exit 1
      end
      if joined.include?("config:system:get dbuser")
        puts options.fetch("live_dbuser")
      elsif joined.include?("config:system:get dbname")
        puts options.fetch("live_dbname")
      elsif joined.include?("config:system:get trusted_domains")
        print options.fetch("trusted_domains")
      elsif (match = joined.match(/config:app:get core (\\S+)/))
        # GetConfig.php, faithfully: a key that has never been written raises
        # AppConfigUnknownKeyException, and the command returns 1 -- printing
        # nothing at all on either stream -- unless --default-value was passed,
        # in which case it prints that value and returns 0. Modelling this as an
        # ordinary `puts` is what let the shipped defect look tested.
        age = options.fetch("installed_age_seconds")
        value = case match[1]
                when "backgroundjobs_mode" then options.fetch("backgroundjobs_mode")
                when "installedat" then age.nil? ? nil : (Time.now.to_f - age).to_s
                end
        default = argv.find { |argument| argument.start_with?("--default-value=") }
        if !value.nil?
          puts value
        elsif default.nil?
          exit 1
        else
          puts default.split("=", 2).last
        end
      elsif joined.include?("app:list")
        text = options.fetch("app_list_text")
        if text.nil?
          puts JSON.generate(options.fetch("app_list"))
        else
          puts text
        end
      else
        warn "docker stub reached an exec it does not know: \#{joined}"
        exit 127
      end
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
  FileUtils.mkdir_p(docker_root)

  options_path = File.join(root, "docker-stub.json")
  File.write(options_path, JSON.generate(
    "inspect_ok" => options.fetch(:inspect_ok),
    "states" => options.fetch(:states),
    "occ_ok" => options.fetch(:occ_ok),
    "live_dbuser" => options.fetch(:live_dbuser),
    "live_dbname" => options.fetch(:live_dbname),
    "trusted_domains" => options.fetch(:trusted_domains),
    "backgroundjobs_mode" => options.fetch(:backgroundjobs_mode),
    "installed_age_seconds" => options.fetch(:installed_age_seconds),
    "crontab_ok" => options.fetch(:crontab_ok),
    "crontab" => options.fetch(:crontab),
    "occ_error_text" => options.fetch(:occ_error_text),
    "occ_error_stream" => options.fetch(:occ_error_stream),
    "app_list" => options.fetch(:app_list),
    "app_list_text" => options.fetch(:app_list_text)
  ))

  File.write(File.join(bin, "docker"), docker_stub_source(options_path))
  document = options.fetch(:vault_document) || vault_document
  File.write(File.join(bin, "ansible-vault"), <<~SH)
    #!/bin/sh
    #{options.fetch(:vault_ok) ? '' : 'echo "decryption failed" >&2; exit 1'}
    cat <<'YAML'
    #{YAML.dump(document).lines.join.chomp}
    YAML
  SH
  %w[docker ansible-vault].each { |name| File.chmod(0o755, File.join(bin, name)) }
  File.write(File.join(root, "vault.yml"), "encrypted\n")
  File.write(File.join(root, "vault-password"), "fixture\n")
  [bin, docker_root]
end

def runtime_responder(options)
  lambda do |method, target, headers, _body|
    path = target.split("?").first
    if method == "GET" && path == "/status.php"
      code = options.fetch(:status_code)
      body = options.fetch(:status_body) || JSON.generate(status_document)
      # A 500 with a zero-byte body is what a real Nextcloud answers when the
      # cluster is gone: status.php boots the server and the boot queries
      # oc_appconfig, so the failure is an uncaught exception rather than a
      # rendered error.
      [code, code == 200 ? body : ""]
    elsif method == "GET" && path == "/ocs/v2.php/cloud/user"
      authorization = headers.to_h.transform_keys(&:downcase)["authorization"].to_s
      expected = "Basic #{["#{ADMIN_USERNAME}:#{ADMIN_PASSWORD}"].pack('m0')}"
      code = authorization == expected ? options.fetch(:admin_code) : options.fetch(:wrong_admin_code)
      [code, JSON.generate("ocs" => { "data" => { "id" => ADMIN_USERNAME } })]
    else
      [404, "{}"]
    end
  end
end

RUNTIME_ROWS = [
  { name: "a converged Nextcloud stack", given: {}, expects: nil },
  {
    name: "a container Docker cannot inspect",
    given: { inspect_ok: false },
    expects: "could not be inspected"
  },
  {
    # `exited healthy` rather than `exited unhealthy`, because Docker keeps the
    # last health verdict after a stop and only this state isolates the running
    # check: with an unhealthy fixture the health assertion below catches the row
    # too, and the self-test then cannot tell the two apart.
    name: "an application that is not running",
    given: { states: { APPLICATION_CONTAINER => "exited healthy" } },
    expects: "is exited, not running"
  },
  {
    name: "a cache Docker calls unhealthy",
    given: { states: { CACHE_CONTAINER => "running unhealthy" } },
    expects: "is unhealthy, not healthy"
  },
  {
    # The fourth container, which Seafile's three-container census has no
    # counterpart for. Its health check proves the shared volume and the database
    # link at once, so it is the container that fails first if either breaks.
    name: "a cron sidecar Docker calls unhealthy",
    given: { states: { CRON_CONTAINER => "running unhealthy" } },
    expects: "is unhealthy, not healthy"
  },
  {
    name: "a vault that will not decrypt",
    given: { vault_ok: false },
    expects: "the encrypted vault could not be read"
  },
  {
    name: "a vault missing a credential the contract needs",
    given: { vault_document: { "vault_nextcloud_admin_username" => ADMIN_USERNAME } },
    expects: "the encrypted vault carries no vault_nextcloud_admin_password"
  },
  {
    # A port check passes in this state and this does not, which is the property
    # #500 asked for in so many words.
    #
    # The one row that overrides a budget, and the only one entitled to: its
    # expected outcome IS the readiness deadline expiring, so the deployment's
    # own 30 seconds buy nothing here except 30 seconds of sleep. Every other row
    # reaches its verdict on the first request and does not wait at all. Left at
    # the shared budget this single row was 30.9s of the check's 36.3s and took
    # its CPU-to-elapsed ratio to 33% -- a check that waits becomes the floor for
    # its whole shard, which is what CLAUDE.md's `static` budget section is about
    # and what #331 cost the seerr self-test 368 seconds to learn.
    name: "a status endpoint answering 500 with an empty body",
    given: { status_code: 500 },
    environment: { "PLATFORM_NEXTCLOUD_READY_TIMEOUT_SECONDS" => "3" },
    expects: "never served its status endpoint"
  },
  {
    name: "a status endpoint answering something that is not JSON",
    given: { status_body: "<html>installed</html>" },
    expects: "answered 200 with a body that is not JSON"
  },
  {
    name: "an installation that never finished",
    given: { status_body: JSON.generate(status_document(installed: false)) },
    expects: "Nextcloud reports itself not installed"
  },
  {
    name: "an instance left in maintenance mode",
    given: { status_body: JSON.generate(status_document(maintenance: true)) },
    expects: "Nextcloud is in maintenance mode"
  },
  {
    name: "an upgrade that ran and did not finish",
    given: { status_body: JSON.generate(status_document(needs_db_upgrade: true)) },
    expects: "reports a database upgrade it has not finished"
  },
  {
    # THE LANDMINE, and this is the only place it can be settled. The environment
    # variable being present in the compose file is not the installer having
    # honoured it, and the install branch runs once and never again.
    name: "an installer that minted its own database account",
    given: { live_dbuser: "oc_admin" },
    expects: "not as the vault's own account"
  },
  {
    name: "an installation connected to a database the vault does not name",
    given: { live_dbname: "nextcloud" },
    expects: "not the vault's own"
  },
  {
    name: "a server that trusts nothing this platform can name",
    given: { trusted_domains: "\n" },
    expects: "trusts no domain this platform can name"
  },
  {
    name: "a server that does not trust the host verification polls",
    given: { trusted_domains: "localhost\nnas.example\n" },
    expects: "does not trust 127.0.0.1"
  },
  {
    name: "an administrator the server does not hold",
    given: { admin_code: 401 },
    expects: "did not accept the vault administrator"
  },
  {
    # The negative control. Without it the positive half passes against a server
    # that authorises anything at all.
    name: "a server that authorises a password nobody authored",
    given: { wrong_admin_code: 200 },
    expects: "authorised a password the vault never authored"
  },
  {
    # A recorded mode that is not `cron` is somebody having chosen a runner that
    # is not the sidecar -- nothing writes `ajax` by accident, it is the value in
    # code that applies while the row is absent -- so this stays a refusal.
    name: "a cron sidecar that has never executed cron.php",
    given: { backgroundjobs_mode: "ajax" },
    expects: 'still runs background jobs in "ajax" mode'
  },
  {
    # THE STATE THE LANE IS ACTUALLY IN, and the reason this contract failed its
    # first CI run. oc_appconfig holds no background job mode until cron.php
    # runs, the sidecar runs it on a */5 schedule, and the lane reaches this
    # contract about a minute after the install finished. It has to pass, and
    # what keeps it from being a hole is the row below it and the crontab row
    # after that.
    name: "an installation whose cron schedule has not fired yet",
    given: { backgroundjobs_mode: nil },
    expects: nil
  },
  {
    # The other side of the grace. Past it the schedule has had its chance, so
    # the absence is the failure the fourth container exists to prevent -- which
    # is the state the NAS would be in, where an installation is days old.
    name: "an installation old enough that its cron sidecar must have fired",
    given: { backgroundjobs_mode: nil, installed_age_seconds: 600 },
    expects: "has never executed cron.php"
  },
  {
    # What makes the tolerated branch an assertion rather than a shrug: crond
    # takes no argument naming a job, so a sidecar whose crontab schedules
    # nothing is up, healthy, and will never run a background job.
    name: "a cron sidecar whose crontab schedules nothing",
    given: { backgroundjobs_mode: nil, crontab: "# nothing here\n" },
    expects: "schedules no cron.php"
  },
  {
    # A docker exec that fails with the daemon's own sentence, which is what a
    # container name this contract derived wrongly would produce.
    name: "a cron sidecar container docker cannot exec into",
    given: { backgroundjobs_mode: nil, crontab_ok: false },
    expects: "No such container: #{CRON_CONTAINER}"
  },
  {
    # Without core|installedat there is no age, so there is nothing to excuse the
    # missing mode with. It fails closed rather than tolerating both absences.
    name: "an installation that records no install time",
    given: { backgroundjobs_mode: nil, installed_age_seconds: nil },
    expects: "records no core|installedat"
  },
  {
    # THE SHIPPED DEFECT, pinned as a whole sentence. `occ config:app:get` exits
    # 1 with both streams empty for a key that has never been written, and the
    # message that reached CI was "the background job mode census failed: " --
    # everything after the colon was the empty stderr. A row matching the
    # fragment before the colon accepts that sentence, which is why this one
    # names the clause the diagnosis has to add.
    name: "an occ that cannot run at all",
    given: { occ_ok: false },
    expects: "the database account census failed (exit 1, no output on stdout or stderr)"
  },
  {
    # A command that puts its complaint on stdout and exits non-zero. Reading
    # stderr alone reports this as silence, which is a diagnosis of the wrong
    # failure rather than no diagnosis at all.
    name: "an occ that complains on the wrong stream",
    given: { occ_ok: false, occ_error_text: "PHP Fatal error: allowed memory size exhausted",
             occ_error_stream: "stdout" },
    expects: "nothing on stderr, stdout: PHP Fatal error"
  },
  {
    name: "an occ that fails with the daemon's own sentence",
    given: { occ_ok: false,
             occ_error_text: "Error response from daemon: No such container: #{APPLICATION_CONTAINER}" },
    expects: "stderr: Error response from daemon: No such container: #{APPLICATION_CONTAINER}"
  },
  {
    # The one application policy this contract can assert without a variable
    # context: Immich is this platform's photo service, so Nextcloud serving
    # photos too is the overlap #500's scope rules out.
    name: "a server that still enables the photo app Immich replaces",
    given: { app_list: { "enabled" => { "files" => "2.0.0", "photos" => "7.0.0" },
                         "disabled" => {} } },
    expects: "still enables photos"
  },
  {
    # A census reporting nothing enabled is a census that failed. No
    # installation can be in that state: core/shipped.json's alwaysEnabled holds
    # fourteen apps that cannot be turned off, so an empty `enabled` is occ
    # having gone wrong rather than a policy having gone right.
    name: "an application census that reports nothing enabled",
    given: { app_list: { "enabled" => {}, "disabled" => {} } },
    expects: "no enabled application at all"
  },
  {
    # occ exiting 0 having written something that is not a document. Rescued to
    # an empty list this reads as "no photos enabled" and passes, which is the
    # vacuity this row exists to keep closed.
    name: "an application census that is not JSON",
    given: { app_list_text: "PHP Deprecated: Implicit conversion in Installer.php" },
    expects: "not JSON"
  }
].freeze

def runtime_failures(program, rows = RUNTIME_ROWS)
  failures = []
  in_parallel_cases(failures, rows) do |row, collected|
    given = row.fetch(:given)
    options = RUNTIME_DEFAULTS.merge(given)
    options = options.merge(states: RUNTIME_DEFAULTS.fetch(:states).merge(given.fetch(:states))) if
      given.key?(:states)
    Dir.mktmpdir("nas-platform-nextcloud-runtime.") do |raw|
      root = File.realpath(raw)
      bin, docker_root = build_runtime_sandbox(root, options)
      HttpFixtureSupport.with_http_fixture(
        lambda do |port|
          stdout, stderr, status = Open3.capture3(
            RUNTIME_BUDGETS.merge(row.fetch(:environment, {})).merge(
              "PATH" => "#{bin}:#{ENV.fetch('PATH')}",
              "PLATFORM_NEXTCLOUD_PORT" => port.to_s,
              "PLATFORM_NEXTCLOUD_CONTAINER" => APPLICATION_CONTAINER,
              "PLATFORM_NEXTCLOUD_CRON_CONTAINER" => CRON_CONTAINER,
              "PLATFORM_NEXTCLOUD_DB_CONTAINER" => DATABASE_CONTAINER,
              "PLATFORM_NEXTCLOUD_CACHE_CONTAINER" => CACHE_CONTAINER,
              "PLATFORM_DOCKER_ROOT" => docker_root,
              "PLATFORM_CONTRACT_VAULT_FILE" => File.join(root, "vault.yml"),
              "PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" => File.join(root, "vault-password")
            ),
            RbConfig.ruby, program, options.fetch(:mode)
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
# tests/contracts/nextcloud.sh resolves both programs from its own checkout
# rather than from the tree it inspects, so a copy of the three files into a
# throwaway tests/contracts/ is a whole working contract. That is what lets a row
# point PLATFORM_CONTRACT_REPO_DIR at a broken fixture and still exercise the
# real wrapper.

def with_contract_copy(static: File.read(STATIC_PROGRAM), runtime: File.read(RUNTIME_PROGRAM),
                       wrapper: File.read(CONTRACT))
  Dir.mktmpdir("nas-platform-nextcloud-wrapper.") do |raw|
    root = File.realpath(raw)
    build_fixture_repository(root)
    contracts = File.join(root, "tests", "contracts")
    FileUtils.mkdir_p(contracts)
    wrapper_path = File.join(contracts, "nextcloud.sh")
    File.write(wrapper_path, wrapper)
    File.chmod(0o755, wrapper_path)
    File.write(File.join(contracts, "nextcloud-static.rb"), static)
    File.write(File.join(contracts, "nextcloud-runtime.rb"), runtime)
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

RUNTIME_REFUSAL_STUB = <<~'STUB'
  warn "runtime stub reached: the wrapper did not refuse this environment"
  exit 0
STUB

# Echoes what the wrapper handed the runtime half. The mode has to arrive: the
# runtime program dispatches on it and defaults to `run`, so a wrapper that
# stopped passing it would be exercising a default rather than a request.
MODE_ECHO_STUB = <<~'STUB'
  warn "runtime stub argv: #{ARGV.inspect}"
  exit 0
STUB

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
# or null"), and never the line number, which any edit to that file moves.
REQUIRED_RUN_ENV = %w[
  PLATFORM_CONTRACT_VAULT_FILE
  PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
  PLATFORM_DOCKER_ROOT
].freeze

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
    stdout, stderr, status = Open3.capture3(environment, contract, "run")
    output = stdout + stderr
    failures << "mode: run did not reach the runtime half: #{output.strip.inspect}" unless
      status.success?
    failures << "mode: the runtime half was not told it was run: #{output.strip.inspect}" unless
      output.include?('runtime stub argv: ["run"]')

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
    # restart-persistence is in this list on purpose: it is a mode the Seafile
    # contract has and this one deliberately does not, so a reader reaching for
    # it must be refused rather than silently given `run`.
    %w[verify drift restart-persistence --platform notify].each do |mode|
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
    FileUtils.rm(File.join(copy_root, "services/nextcloud/compose.mac.yml"))
    stdout, stderr, status = Open3.capture3(
      { "PLATFORM_CONTRACT_REPO_DIR" => copy_root,
        "PLATFORM_CONTRACT_VAULT_FILE" => File.join(copy_root, "vault.yml"),
        "PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" => File.join(copy_root, "vault-password"),
        "PLATFORM_DOCKER_ROOT" => File.join(copy_root, "docker") },
      contract, "run"
    )
    output = stdout + stderr
    failures << "wrapper: run mode was accepted against a broken repository" if status.success?
    failures << "wrapper: run mode did not run the static half first: #{output.strip.inspect}" unless
      output.include?("missing services/nextcloud/compose.mac.yml")
  end
  failures
end

# The two-roots rule, which is the property that keeps this contract from reading
# its own assertions out of the tree it judges: the PROGRAMS come from the
# checkout, the inspected tree comes from PLATFORM_CONTRACT_REPO_DIR. The sibling
# programs are deleted from the inspected tree rather than the whole
# tests/contracts directory, because the wrapper itself is read out of that tree
# on purpose -- the static half compares that tree's contract default port with
# that tree's role default.
def two_roots_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  with_contract_copy(wrapper: wrapper_source) do |contract|
    Dir.mktmpdir("nas-platform-nextcloud-tworoots.") do |raw|
      inspected = File.realpath(raw)
      build_fixture_repository(inspected)
      %w[nextcloud-static.rb nextcloud-runtime.rb].each do |program|
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
    Dir.mktmpdir("nas-platform-nextcloud-support.") do |raw|
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
    label: "the requirement that the app policy disables the photo app Immich replaces",
    program: :static,
    from: 'Array(defaults["nextcloud_disabled_apps"]).include?("photos")',
    to: "true",
    rows: ["an app policy that stopped disabling the photo app Immich replaces"]
  },
  {
    label: "the protection of the collaborative editor the platform adopted Nextcloud for",
    program: :static,
    from: 'Array(defaults["nextcloud_disabled_apps"]).include?("text")',
    to: "false",
    rows: ["an app policy that disabled the collaborative editor it was adopted for"]
  },
  {
    label: "the placement of the app policy after the administrator probe",
    program: :static,
    from: 'imports.index("reconcile_apps.yml").to_i > imports.index("reconcile_admin.yml").to_i &&',
    to: "true ||",
    rows: ["an app policy that runs before the administrator it perturbs is probed"]
  },
  {
    label: "the requirement that the application census refuses a nonzero exit",
    program: :static,
    from: 'census && census["failed_when"].to_s.include?("rc")',
    to: "true",
    rows: ["an application census that reads a failed exit as an empty app set"]
  },
  {
    label: "the requirement that the application disable refuses a nonzero exit",
    program: :static,
    from: 'disable && disable["failed_when"].to_s.include?("rc")',
    to: "true",
    rows: ["an application disable that reports success on any exit code"]
  },
  {
    label: "the requirement that the disable loop reads the live census",
    program: :static,
    from: 'disable && disable["loop"].to_s.include?("nextcloud_apps_still_enabled")',
    to: "true",
    rows: ["an application disable that loops over the declared list rather than what is enabled"]
  },
  {
    # Removing this one restores the state the review found: the whole set_fact
    # can be deleted and every other property still holds.
    label: "the requirement that the app policy binds the set its loop reads",
    program: :static,
    from: "unless binder",
    to: "unless true",
    rows: ["an application policy that binds nothing for its own loop to read"]
  },
  {
    label: "the requirement that the bound set is the effective list intersected with the census",
    program: :static,
    from: "unless intersected",
    to: "unless true",
    rows: ["an application policy that resolves the declared list rather than the effective one"]
  },
  {
    label: "the requirement that the disable does not claim a change on an already-disabled app",
    program: :static,
    from: 'disable && disable["changed_when"].to_s.include?("No such app enabled")',
    to: "true",
    rows: ["an application disable that reports a change on an app that was already off"]
  },
  {
    # The second conjunct of the placement, which had no row and no mutation of
    # its own: deleting it left the whole contract green.
    label: "the placement of the app policy before the report that carries its change",
    program: :static,
    from: 'imports.index("reconcile_apps.yml").to_i < imports.index("report.yml").to_i',
    to: "true",
    rows: ["an app policy that runs after the report that has to carry its change"]
  },
  {
    # Both halves of the report's derivation, planted separately, because they
    # are two defects and a single set comparison would report whichever fired
    # first. Removing either restores the state the review found: the whole
    # expression was pinned by nothing.
    label: "the requirement that the report names every result that can move",
    program: :static,
    from: "(movers - named).empty?",
    to: "true",
    rows: ["a deployment report that drops a result which can report a change"]
  },
  {
    label: "the requirement that the report names no result the role stopped registering",
    program: :static,
    from: "(named - movers).empty?",
    to: "true",
    rows: ["a deployment report that names a result the role no longer registers"]
  },
  {
    label: "the requirement that the two phone-home applications stay disabled",
    program: :static,
    from: '(phoning_home - Array(defaults["nextcloud_disabled_apps"])).empty?',
    to: "true",
    rows: ["an application policy that stops disabling the two apps that phone home"]
  },
  {
    label: "the image pin check",
    program: :static,
    from: "image.match?(IMAGE_PIN) && image.split(\":\").first == repository",
    to: "true",
    rows: ["an image pinned by tag alone"]
  },
  {
    label: "the one-image rule for the application and its cron sidecar",
    program: :static,
    from: 'application["image"].to_s == cron["image"].to_s && !application["image"].to_s.empty?',
    to: "true",
    rows: ["a cron sidecar left on the previous image"]
  },
  {
    label: "the sandbox container name agreement",
    program: :static,
    from: "overrides.values.all? { |names| names == namespaced }",
    to: "true",
    rows: ["two overrides that disagree about a sandbox container"]
  },
  {
    label: "the cluster mount point check",
    program: :static,
    from: 'database_targets == ["/var/lib/postgresql"]',
    to: "true",
    rows: ["a cluster bound one level below where postgres 18 puts it"]
  },
  {
    # The one that cannot be repaired by a later converge, so the guard that
    # refuses it is the only thing standing between this platform and an
    # unrotatable stack.
    label: "the refusal to let the installer mint its own database account",
    program: :static,
    from: 'application_environment["NC_setup_create_db_user"].to_s == "false"',
    to: "true",
    rows: ["an installer left free to mint its own database account"]
  },
  {
    # This mutation and "the redaction of the administrator repair" below both
    # leave `:detects` at its default, which is deliberate. `:detects` names
    # which of `judge`'s two verdicts the mutant must produce, not which
    # assertion caught the break, and only one of those two is the strict
    # reading: "accepted what it must refuse" holds when removing the assertion
    # left the fixture break unrefused by anything at all, which is the question
    # a mutation is asking. Naming the assertion's own message instead selects
    # the OTHER verdict, because the wrong-reason line is the one that quotes
    # `:expects` -- it would pass exactly when a sibling fired first and fail
    # when the guard was the sole detector. Both rows were confirmed against the
    # default.
    label: "the cluster's own database and owner",
    program: :static,
    from: 'database_environment["POSTGRES_DB"].to_s.include?("NEXTCLOUD_DB_NAME") &&',
    to: "true ||",
    rows: ["a cluster initialised with an account the vault never authored"]
  },
  {
    label: "the refusal of an array-valued setting pushed through NC_",
    program: :static,
    from: 'application_environment.key?("NC_trusted_domains")',
    to: "false",
    rows: ["an array-valued system setting pushed through the environment"]
  },
  {
    label: "the health budget arithmetic",
    program: :static,
    from: "defaults[budget_name].to_i > worst",
    to: "true",
    rows: ["a deployment wait shorter than the probe it waits on"]
  },
  {
    label: "the static-import rule",
    program: :static,
    from: 'role_tasks(root, "main").all? { |task| task.key?("ansible.builtin.import_tasks") }',
    to: "true",
    rows: ["a stage reached by a dynamic include"]
  },
  {
    # The gate CI wrote. Removing it puts the role back in the state that failed
    # the smoke and idempotence-check lanes on a correctly switched-off stack.
    label: "the switch-and-check-mode gate on every task touching the stack",
    program: :static,
    from: "ungated.empty?",
    to: "true",
    rows: ["a task that reads a stack this run never started"]
  },
  {
    label: "the append-rather-than-overwrite rule for trusted domains",
    program: :static,
    from: '.include?("nextcloud_trusted_domains_live | length + index") &&',
    to: '.then { true } &&',
    rows: ["a trusted domain repair that overwrites index zero"]
  },
  {
    label: "the conditional administrator repair",
    program: :static,
    from: %(reset && Array(reset["when"]).any? { |value| value.to_s.include?("== 'rotated'") }),
    to: "true",
    rows: ["an administrator reset on every converge rather than on a refusal"]
  },
  {
    # The credential guard, and the one with no second line of defence: the
    # `vault_nextcloud_` sweep beside it cannot see this task, so removing this
    # is removing the only thing that keeps a failed exec from printing the
    # rendered container environment.
    label: "the redaction of the administrator repair",
    program: :static,
    from: 'reset && reset["no_log"] == true',
    to: "true",
    rows: ["an administrator repair that would print the container environment"]
  },
  {
    label: "the database-backed verification endpoint",
    program: :static,
    from: 'failures << "Nextcloud verification must read the endpoint that boots the server" unless status',
    to: "status = status",
    rows: ["verification that settles for an endpoint the database cannot fail"]
  },
  {
    label: "the Jinja raw-tag scanner",
    program: :static,
    from: "raw_inside_expression.empty?",
    to: "true",
    rows: ["a raw tag inside a Jinja expression"]
  },
  {
    label: "the narrowed-inspection rule",
    program: :static,
    from: "unformatted_inspects.empty?",
    to: "true",
    rows: ["an inspection wide enough to print the container environment"]
  },
  {
    label: "the container census",
    program: :runtime,
    from: 'state == "running"',
    to: "true",
    rows: ["an application that is not running"]
  },
  {
    label: "the container health census",
    program: :runtime,
    from: 'health == "healthy"',
    to: "true",
    rows: ["a cache Docker calls unhealthy", "a cron sidecar Docker calls unhealthy"]
  },
  {
    # The runtime half of the landmine. Static analysis can prove the variable is
    # present; only this proves the installer honoured it.
    label: "the database account the installation actually connects as",
    program: :runtime,
    from: 'unless live_user == credentials.fetch("db_username")',
    to: "unless true",
    rows: ["an installer that minted its own database account"]
  },
  {
    label: "the maintenance-mode check",
    program: :runtime,
    from: 'fail_contract("Nextcloud is in maintenance mode") if document["maintenance"] == true',
    to: "nil if false",
    rows: ["an instance left in maintenance mode"]
  },
  {
    label: "the unfinished-upgrade check",
    program: :runtime,
    from: 'document["needsDbUpgrade"] == true',
    to: "false",
    rows: ["an upgrade that ran and did not finish"]
  },
  {
    label: "the trusted domain the platform's own verification polls",
    program: :runtime,
    from: 'unless live.include?("127.0.0.1")',
    to: "unless true",
    rows: ["a server that does not trust the host verification polls"]
  },
  {
    # Without this the positive half passes against a server that authorises
    # anything at all, which is the vacuous shape this repository keeps closing.
    label: "the negative control on the administrator exchange",
    program: :runtime,
    from: 'fail_contract("Nextcloud authorised a password the vault never authored") if refusal.code == "200"',
    to: "nil if false",
    rows: ["a server that authorises a password nobody authored"]
  },
  {
    label: "the refusal of a background job runner that is not the sidecar",
    program: :runtime,
    from: ") unless mode.nil?",
    to: ") if false",
    rows: ["a cron sidecar that has never executed cron.php"]
  },
  {
    # The grace, in the direction that matters on the NAS: an installation that
    # has had every chance to run cron.php and has not. This mutation and the one
    # after it plant the same comparison in opposite directions, and `plant`
    # counts each `from` separately: both strings must stay unique in the
    # program, so a second `age > CRON_GRACE_SECONDS` anywhere would abort the
    # whole self-test on the main thread rather than fail one row.
    label: "the age past which a missing background job mode is a failure",
    program: :runtime,
    from: ") if age > CRON_GRACE_SECONDS",
    to: ") if false",
    rows: ["an installation old enough that its cron sidecar must have fired"]
  },
  {
    # The same line inverted, and it is what stops the tolerated branch from
    # being decoration: with every installation past the grace, the row that must
    # pass on a fresh converge stops passing. `detects` says so, because judge
    # reports a success row that refused as "expected success" and not as the
    # refusal wording.
    label: "the grace a fresh installation is entitled to",
    program: :runtime,
    from: "age > CRON_GRACE_SECONDS",
    to: "true",
    rows: ["an installation whose cron schedule has not fired yet"],
    detects: "expected success"
  },
  {
    label: "the refusal of an application this platform already serves elsewhere",
    program: :runtime,
    from: ") unless overlapping.empty?",
    to: ") if false",
    rows: ["a server that still enables the photo app Immich replaces"]
  },
  {
    # What stops the row above being decoration. An assertion that refused every
    # app set would satisfy it; this one only survives if the converged fixture
    # is still accepted, so the two together pin both directions.
    label: "the tolerance of an app set this platform does not object to",
    program: :runtime,
    from: "overlapping.empty?",
    to: "false",
    rows: ["a converged Nextcloud stack"],
    detects: "expected success"
  },
  {
    label: "the refusal of an application census that enumerated nothing",
    program: :runtime,
    from: ") if enabled.empty?",
    to: ") if false",
    rows: ["an application census that reports nothing enabled"]
  },
  {
    # Caught as a wrong reason rather than as an acceptance: with the rescue put
    # back to an empty list the program still refuses, it just refuses with the
    # empty-census sentence instead of the one naming the real fault. That is the
    # #352 shape -- a diagnosis of the wrong failure is not a diagnosis.
    label: "reading an unparseable application census as JSON rather than as an empty list",
    program: :runtime,
    from: "fail_contract(UNPARSEABLE_CENSUS)",
    to: "{}",
    rows: ["an application census that is not JSON"],
    detects: "refused for the wrong reason"
  },
  {
    label: "the requirement that the sidecar's crontab schedules cron.php",
    program: :runtime,
    from: ") if schedule.nil?",
    to: ") if false",
    rows: ["a cron sidecar whose crontab schedules nothing"]
  },
  {
    # Removing this refusal does not make the program accept the fixture -- it
    # makes Float(nil) raise, and the rescue below then names the wrong thing. A
    # backtrace or a misdirected sentence is the #352 shape, so the row catches
    # it as a wrong reason rather than as an acceptance.
    label: "the refusal of an installation that records no install time",
    program: :runtime,
    from: ") if recorded.nil?",
    to: ") if false",
    rows: ["an installation that records no install time"],
    detects: "refused for the wrong reason"
  },
  {
    # THE FIX ITSELF. Without --default-value, a key that has never been written
    # and a broken occ are the same exit code with the same empty output, and the
    # state every fresh converge is in becomes a refusal -- which is exactly what
    # the first CI run of this lane did.
    label: "reading an app config key through a default rather than an exit code",
    program: :runtime,
    from: 'occ("config:app:get", "core", key, "--default-value=#{UNSET_APP_CONFIG}", label: label)',
    to: 'occ("config:app:get", "core", key, label: label)',
    rows: ["an installation whose cron schedule has not fired yet"],
    detects: "expected success"
  },
  {
    # The three clauses of the diagnosis, each proved by the row that pins the
    # one it adds. All three are caught as a wrong reason rather than as an
    # acceptance, because the program still refuses -- it just goes back to
    # refusing without saying why, which is the defect being fixed. The most
    # travelled clause is this first one, and leaving it unplanted would have
    # left the branch every ordinary docker failure takes unproven.
    label: "reading the complaint a command left on stderr",
    program: :runtime,
    from: "if (line = first_line(stderr))",
    to: "if false",
    rows: ["an occ that fails with the daemon's own sentence"],
    detects: "refused for the wrong reason"
  },
  {
    label: "saying that a failed command said nothing at all",
    program: :runtime,
    from: '"#{code}, no output on stdout or stderr"',
    to: '"#{code}"',
    rows: ["an occ that cannot run at all"],
    detects: "refused for the wrong reason"
  },
  {
    label: "reading a complaint the command put on stdout",
    program: :runtime,
    from: "elsif (line = first_line(stdout))",
    to: "elsif false",
    rows: ["an occ that complains on the wrong stream"],
    detects: "refused for the wrong reason"
  }
].freeze

WRAPPER_MUTATIONS = [
  {
    label: "the mode guard",
    from: "  static|run) ;;",
    to: "  static|run|verify|drift|restart-persistence|--platform|notify) ;;",
    layer: :wrapper
  },
  {
    label: "the static half's stdin redirect",
    from: 'ruby "$static_program" "$repo_dir" </dev/null',
    to: 'ruby "$static_program" "$repo_dir"',
    layer: :stdin
  },
  {
    label: "the runtime half's stdin redirect",
    from: 'exec ruby "$runtime_program" "$mode" </dev/null',
    to: 'exec ruby "$runtime_program" "$mode"',
    layer: :runtime_stdin
  },
  {
    label: "resolving the static program from the checkout",
    from: "static_program=$contract_repo_dir/tests/contracts/nextcloud-static.rb",
    to: "static_program=$repo_dir/tests/contracts/nextcloud-static.rb",
    layer: :two_roots
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
  # abort inside a worker raises SystemExit there: `run_pool_case` rescues only
  # StandardError, so `Thread#join` re-raises it and the process exits with that
  # sentence on stderr and no report assembled. A case that raises anything else
  # is recorded as that case's own failure and the other cases still report --
  # #514 -- so the reason plants belong before the pool is that an abort is the
  # check saying it cannot continue, not that the pool mangles the message.
  program_cases = PROGRAM_MUTATIONS.map do |mutation|
    canonical = mutation.fetch(:program) == :static ? STATIC_PROGRAM : RUNTIME_PROGRAM
    rows = mutation.fetch(:program) == :static ? STATIC_ROWS : RUNTIME_ROWS
    [mutation, plant(File.read(canonical), mutation), rows_named(rows, mutation.fetch(:rows))]
  end
  wrapper_cases = WRAPPER_MUTATIONS.map { |mutation| [mutation, plant(File.read(CONTRACT), mutation)] }

  in_parallel_cases(mismatches, program_cases) do |(mutation, source, rows), collected|
    Dir.mktmpdir("nas-platform-nextcloud-mutant.") do |directory|
      name = mutation.fetch(:program) == :static ? "nextcloud-static.rb" : "nextcloud-runtime.rb"
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

  puts "nextcloud contract: self-test detects #{planted} planted regressions"
  exit
end

failures = static_failures(STATIC_PROGRAM) + runtime_failures(RUNTIME_PROGRAM) +
           wrapper_failures + run_env_failures + mode_passthrough_failures +
           stdin_failures + runtime_stdin_failures + two_roots_failures
unless failures.empty?
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} Nextcloud contract violation(s)"
end

puts "nextcloud contract: #{STATIC_ROWS.length} static and #{RUNTIME_ROWS.length} runtime properties " \
     "hold, the run-mode environment contract refuses each name with the wrapper's own message, and " \
     "both programs come from the checkout with an empty stdin"
