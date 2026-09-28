#!/usr/bin/env ruby
# Every whole-project Compose deployment brackets itself with the container
# health detect / repair-once / verdict sequence (#509, #537, #646). A sweep
# discovers subjects from the tree, so a new Compose role arrives wired or fails.
# Trap: container_health_stuck_services is a play-scope fact that survives into
# the next role; every consumer must run its own detect pass before reading it.
require "fileutils"
require "tmpdir"
require "yaml"

require_relative "policy_support"

include TestScaffold

# Pinned both ways: a derived subject list that empties passes vacuously.
EXPECTED_SUBJECTS = %w[
  arr audiobookshelf bindery downloaders dozzle jellyfin karakeep
  kapowarr komga pinchflat seerr trailarr vaultwarden
].freeze
# the roles #537 wired plus vaultwarden (#547) and karakeep (#551)
SUBJECT_FLOOR = 13

# Each subject takes the shared recovery or records why it keeps its own copy,
# so an eighth copy cannot land quietly (#646).
SHARED_RECOVERY_ROLES = %w[dozzle kapowarr komga pinchflat seerr trailarr].freeze
SHARED_RECOVERY_FILE = File.join("roles", "container_health", "tasks", "recover.yml")
# Each reason is what a normalised diff against the shared file shows.
INLINE_RECOVERY_ROLES = {
  "arr" => "gated on media_usenet_enabled throughout and waits on its own " \
           "arr_compose_wait_timeout rather than the platform default",
  "audiobookshelf" => "differs from the shared file only in the indefinite article of four " \
                      "task names; convertible, and left to the follow-up rather than widening " \
                      "#646's blast radius",
  "bindery" => "carries the long form of the whole argument, which #509 wrote and the other " \
               "twelve cite; it is also the only subject whose properties a contract program " \
               "plants thirteen source mutations into",
  "downloaders" => "gated on media_usenet_enabled and reports under \"downloader\" rather than " \
                   "the role name",
  "jellyfin" => "differs from the shared file only in waiting on its own " \
                "jellyfin_compose_wait_timeout; convertible once that is a parameter",
  "karakeep" => "gated on karakeep_deployment_enabled AND on a stat of its rendered .env, so " \
                "the whole sequence carries a two-condition gate",
  "vaultwarden" => "gated on vaultwarden_deployment_enabled AND on a stat of its rendered .env"
}.freeze

# Compose roles deliberately NOT subjects: multi-phase or computed deployments
# need a per-role decision on which services a --no-deps recreate may touch.
# Held both ways, so an exemption cannot outlive the shape that justified it.
EXEMPT_ROLES = {
  "immich" => "two `up` phases: `database,redis` first, then the whole project. " \
              "Force-recreating a phase-two service with --no-deps while phase one " \
              "is itself wedged repairs the wrong thing",
  "nextcloud" => "two `up` phases: `db,cache` first, then the whole project, and " \
                 "both are additionally gated on nextcloud_deployment_enabled",
  "paperless_ngx" => "two `up` phases: `broker,db` first, then the whole project",
  "beszel" => "one `up` over a service list the role computes at run time, so " \
              "\"recreate exactly the stuck ones\" has to be reconciled against a " \
              "set that is not literal"
}.freeze

# Told apart from the repair by `recreate`, not position; `state` is read because
# arr, downloaders and dozzle stop services before their deploy.
def plain_deploy?(task)
  compose = task["community.docker.docker_compose_v2"]
  compose.is_a?(Hash) && compose["state"] == "present" && !compose.key?("recreate")
end

def force_recreate?(task)
  compose = task["community.docker.docker_compose_v2"]
  compose.is_a?(Hash) && compose["state"] == "present" && compose["recreate"] == "always"
end

def role_task_files(root, role)
  Dir[File.join(root, "roles", role, "tasks", "**", "*.yml")].sort
end

def parse_tasks(path)
  document = YAML.safe_load_file(path, aliases: true)
  document.is_a?(Array) ? document : []
rescue Psych::Exception, Errno::ENOENT
  []
end

# Every role directory holding at least one whole-project `up`. The shared
# force-recreate names `services:`, so plain_deploy? keeps it out (#646).
def deploying_roles(root)
  Dir[File.join(root, "roles", "*")].select { |path| File.directory?(path) }.sort.filter_map do |path|
    role = File.basename(path)
    tasks = role_task_files(root, role).flat_map { |file| PolicySupport.flatten_tasks(parse_tasks(file)) }
    next nil if tasks.none? { |task| plain_deploy?(task) }

    role
  end
end

# Whether a top-level element is the include of the shared recovery.
def shared_recovery_include?(task)
  include_role = task.is_a?(Hash) ? task["ansible.builtin.include_role"] : nil
  include_role.is_a?(Hash) && include_role["name"] == "container_health" &&
    include_role["tasks_from"] == "recover"
end

# One-level variable resolution; only names the include passed are substituted,
# which leaves the shared file's own outputs alone.
def substitute(node, vars)
  case node
  when Hash then node.to_h { |key, value| [key, substitute(value, vars)] }
  when Array then node.map { |value| substitute(value, vars) }
  when String
    name = node.strip[/\A\{\{\s*([a-z_0-9]+)\s*\}\}\z/, 1]
    return vars.fetch(name) if name && vars.key?(name)

    vars.reduce(node) do |text, (key, value)|
      value.is_a?(String) ? text.gsub("{{ #{key} }}", value) : text
    end
  else node
  end
end

# Splice the shared recovery in place of its include, vars resolved and its gate
# carried onto every element, so every property reads one task list.
def resolve_shared_recovery(root, top_level)
  shared = parse_tasks(File.join(root, SHARED_RECOVERY_FILE))
  top_level.flat_map do |task|
    next [task] unless shared_recovery_include?(task)

    outer = task["vars"] || {}
    gate = conditions(task)
    shared.map do |inner|
      resolved = substitute(inner, outer)
      # Only the two health passes get the caller's vars: that name identifies a pass,
      # and merging it into all six would report one include as six.
      if resolved.dig("ansible.builtin.include_role", "name") == "container_health"
        resolved["vars"] = outer.merge(resolved["vars"] || {})
      end
      resolved["when"] = (gate + conditions(inner)).uniq unless gate.empty?
      resolved
    end
  end
end

# A task's effective gate: its own conditions plus its top-level element's.
def conditions(task)
  Array(task.is_a?(Hash) ? task["when"] : nil).map { |condition| condition.to_s.strip }
end

def wiring_failures(root)
  failures = []
  deploying = deploying_roles(root)

  stale_exemptions = EXEMPT_ROLES.keys - deploying
  check(failures, stale_exemptions.empty?,
        "container health wiring exempts #{stale_exemptions.inspect}, which no longer deploys a " \
        "Compose project at all; an exemption that outlives its subject exempts nothing and hides " \
        "the next role that takes the name")

  # An exemption survives only while its multi-phase or computed shape does.
  (EXEMPT_ROLES.keys & deploying).each do |role|
    deploys = role_task_files(root, role)
                .flat_map { |file| PolicySupport.flatten_tasks(parse_tasks(file)) }
                .select { |task| plain_deploy?(task) }
    check(failures, deploys.length > 1 || deploys.any? { |task| task["community.docker.docker_compose_v2"].key?("services") },
          "container health wiring exempts #{role} as multi-phase or computed, but it now holds " \
          "#{deploys.length} whole-project `up`(s) over no named service list -- the same shape as " \
          "the twelve wired roles, so the exemption no longer describes it")
  end

  subjects = deploying - EXEMPT_ROLES.keys
  check_floor(failures, subjects.length, SUBJECT_FLOOR,
              "roles whose whole-project Compose deployment must bracket itself with container health")
  missing = EXPECTED_SUBJECTS - subjects
  check(failures, missing.empty?,
        "container health wiring found no whole-project Compose deployment in #{missing.inspect}, " \
        "which #537 wired; either the deployment moved somewhere this sweep does not read or the " \
        "role stopped deploying, and both make its properties below pass vacuously")
  unexpected = subjects - EXPECTED_SUBJECTS
  check(failures, unexpected.empty?,
        "#{unexpected.inspect} deploys a whole Compose project and is neither in this sweep's " \
        "pinned subject list nor in EXEMPT_ROLES with a reason. A new service is wired like " \
        "roles/bindery or it is exempted in writing; it is not silently neither")

  failures.concat(shape_failures(root, subjects))
  subjects.each { |role| failures.concat(role_failures(root, role)) }
  failures
end

# Which shape each subject takes, held both ways; a role in both lists fails too.
def shape_failures(root, subjects)
  failures = []
  overlap = SHARED_RECOVERY_ROLES & INLINE_RECOVERY_ROLES.keys
  check(failures, overlap.empty?,
        "#{overlap.inspect} is listed as both taking the shared container-health recovery and " \
        "carrying its own copy; a role does one or the other")
  unclassified = subjects - SHARED_RECOVERY_ROLES - INLINE_RECOVERY_ROLES.keys
  check(failures, unclassified.empty?,
        "#{unclassified.inspect} brackets a Compose deployment with container health but is " \
        "neither listed as taking roles/container_health/tasks/recover.yml nor recorded in " \
        "INLINE_RECOVERY_ROLES with what makes its own copy a judgement. Six roles held that " \
        "sequence byte-identically before #646; an eighth copy arrives through this gap or not " \
        "at all")
  departed = (SHARED_RECOVERY_ROLES + INLINE_RECOVERY_ROLES.keys) - subjects
  check(failures, departed.empty?,
        "#{departed.inspect} is classified here but no longer brackets a Compose deployment with " \
        "container health; a classification that outlives its subject classifies nothing")
  check_floor(failures, SHARED_RECOVERY_ROLES.length, 4,
              "roles taking the shared container-health recovery")

  (SHARED_RECOVERY_ROLES & subjects).each do |role|
    files = role_task_files(root, role)
    includes = files.sum do |file|
      parse_tasks(file).count { |task| shared_recovery_include?(task) }
    end
    check(failures, includes == 1,
          "role #{role}: takes the shared container-health recovery but includes " \
          "#{SHARED_RECOVERY_FILE} #{includes} time(s), not once")
    own = files.sum do |file|
      PolicySupport.flatten_tasks(parse_tasks(file)).count { |task| force_recreate?(task) }
    end
    check(failures, own.zero?,
          "role #{role}: takes the shared container-health recovery and still holds #{own} " \
          "force-recreate(s) of its own, so the bound #646 hoisted is stated twice again")
  end

  # The recreate failure message is one play-scope fact shared by six callers and
  # written only in a rescue, so the shared file must clear it first or one
  # service's failure is refused under the next one's name.
  if SHARED_RECOVERY_ROLES.intersect?(subjects)
    shared_tasks = parse_tasks(File.join(root, SHARED_RECOVERY_FILE))
    reset = shared_tasks.first
    check(failures,
          reset.is_a?(Hash) && !reset.key?("when") &&
            reset.dig("ansible.builtin.set_fact", "container_health_recreate_failure_message").to_s.empty? &&
            reset.fetch("ansible.builtin.set_fact", {}).key?("container_health_recreate_failure_message"),
          "#{SHARED_RECOVERY_FILE} must clear container_health_recreate_failure_message " \
          "unconditionally as its first task; it is written only in a rescue and survives into " \
          "the next role, so without this one service's recreate failure is read as the next " \
          "service's and refused under its name")
  end

  (INLINE_RECOVERY_ROLES.keys & subjects).each do |role|
    includes = role_task_files(root, role).sum do |file|
      parse_tasks(file).count { |task| shared_recovery_include?(task) }
    end
    check(failures, includes.zero?,
          "role #{role}: is recorded as carrying its own container-health recovery because " \
          "#{INLINE_RECOVERY_ROLES.fetch(role)}, but now includes #{SHARED_RECOVERY_FILE}; move " \
          "it to SHARED_RECOVERY_ROLES so the reason stops being read as still true")
  end
  failures
end

def role_failures(root, role) # rubocop:disable Metrics/AbcSize
  failures = []
  files = role_task_files(root, role)
  deploy_file = files.find { |file| PolicySupport.flatten_tasks(parse_tasks(file)).any? { |task| plain_deploy?(task) } }
  unless deploy_file
    return ["role #{role}: no task file holds a whole-project Compose deployment"]
  end

  # Resolved first so shared and inline roles meet one set of properties; only the
  # fact prefix differs.
  top_level = resolve_shared_recovery(root, parse_tasks(deploy_file))
  tasks = PolicySupport.flatten_tasks(top_level)
  shared = SHARED_RECOVERY_ROLES.include?(role)
  fact_prefix = shared ? "container_health" : role
  relative = shared ? "#{deploy_file.sub("#{root}/", '')} through #{SHARED_RECOVERY_FILE}" : deploy_file.sub("#{root}/", "")

  # Counted separately rather than as a total, so a second plain deployment is
  # still refused and a second force-recreate is still refused.
  check(failures, tasks.count { |task| plain_deploy?(task) } == 1,
        "role #{role}: #{relative} holds " \
        "#{tasks.count { |task| plain_deploy?(task) }} plain Compose deployments, not one")
  check(failures, tasks.count { |task| force_recreate?(task) } == 1,
        "role #{role}: #{relative} must force-recreate a stuck container exactly once per " \
        "converge; it holds #{tasks.count { |task| force_recreate?(task) }} such tasks. " \
        "`up` against an unchanged specification recreates nothing, so without one a wedged " \
        "container survives every five-minute converge")

  # The service name is derived from the CPU verification (the manifest directory),
  # so hyphenated services need no special case.
  cpu_index = tasks.index { |task| task.dig("vars", "container_cpu_service_name") }
  service_name = cpu_index ? tasks[cpu_index].dig("vars", "container_cpu_service_name") : nil
  check(failures, service_name,
        "role #{role}: #{relative} verifies no effective container CPU policy, so this sweep " \
        "cannot resolve the manifest service name the health passes must report under")

  health_indexes = tasks.each_index.select { |index| tasks[index].dig("vars", "container_health_service_name") }
  check(failures, health_indexes.length == 2,
        "role #{role}: #{relative} includes roles/container_health " \
        "#{health_indexes.length} time(s), not twice. The sequence is detect without refusing, " \
        "one bounded force-recreate, then the verdict; one pass alone can only refuse or only " \
        "repair, and a converge that can only refuse cannot heal the host")

  recreate = tasks.find { |task| force_recreate?(task) }
  deploy = tasks.find { |task| plain_deploy?(task) }
  deploy_options = deploy["community.docker.docker_compose_v2"]
  if recreate
    options = recreate["community.docker.docker_compose_v2"]
    check(failures, options["dependencies"] == false &&
                    options["services"] == "{{ container_health_stuck_services }}",
          "role #{role}: the force-recreate must name only the services Docker reports as stuck " \
          "and pass `dependencies: false`, which renders as --no-deps; anything wider takes a " \
          "stack's healthy dependencies down with the container being repaired")
    # The idempotence property: skipped on every converge with nothing stuck.
    check(failures, recreate["when"].to_s.include?("container_health_stuck_services"),
          "role #{role}: the force-recreate is not conditional on a container actually being " \
          "stuck, so it would replace this stack on every five-minute converge")
    check(failures, options["wait"] == true &&
                    options["wait_timeout"] == deploy_options["wait_timeout"],
          "role #{role}: the force-recreate must wait on the replacement with the same timeout " \
          "the deployment uses (#{deploy_options['wait_timeout'].inspect}); a recreate that does " \
          "not wait hands the verdict a container that has not finished starting")
    check(failures, %w[project_src project_name files env_files].all? do |key|
            options[key] == deploy_options[key]
          end,
          "role #{role}: the force-recreate must address the same release, project, Compose " \
          "files and environment file as the deployment it repairs")
  end

  failures.concat(bracketing_failures(role, fact_prefix, relative, tasks,
                                      health_indexes, recreate, cpu_index, service_name))
  failures.concat(rescue_failures(role, fact_prefix, relative, top_level, recreate))
  failures.concat(gate_failures(role, relative, top_level, health_indexes.length == 2))
  failures
end

def bracketing_failures(role, fact_prefix, relative, tasks, health_indexes, recreate, cpu_index, service_name) # rubocop:disable Metrics/ParameterLists,Layout/LineLength
  return [] unless health_indexes.length == 2

  failures = []
  detect_index, verdict_index = health_indexes
  detect = tasks[detect_index]
  verdict = tasks[verdict_index]
  deploy_index = tasks.index { |task| plain_deploy?(task) }
  recreate_index = recreate ? tasks.index(recreate) : nil

  # A `Restarting` container passes the CPU check, so everything that trusts the
  # deployment must sit after the verdict (#510).
  check(failures, cpu_index && deploy_index && recreate_index &&
                  deploy_index < detect_index && detect_index < recreate_index &&
                  recreate_index < verdict_index && verdict_index < cpu_index,
        "role #{role}: #{relative} must run the deployment, then the detection, then the " \
        "force-recreate, then the verdict, and all of them before the CPU verification and " \
        "everything after it that trusts the deployment")
  check(failures, detect["vars"]["container_health_refuse"] == false,
        "role #{role}: the first container health pass must detect without refusing, or the " \
        "force-recreate after it is unreachable and the converge can only fail")
  check(failures, verdict["vars"].fetch("container_health_refuse", true) == true,
        "role #{role}: the second container health pass must be the one that refuses, or a " \
        "container that came back stuck is walked straight past")
  check(failures, [detect, verdict].all? do |pass|
          pass["vars"]["container_health_project_name"] == "{{ #{role}_compose_project_name }}"
        end,
        "role #{role}: each container health pass must name {{ #{role}_compose_project_name }}; " \
        "a pass aimed at another project reads a stack this role did not deploy")
  check(failures, [detect, verdict].all? do |pass|
          pass["vars"]["container_health_service_name"] == service_name
        end,
        "role #{role}: each container health pass must report under the manifest service name " \
        "#{service_name.inspect}, which is what an operator reading the refusal matches against " \
        "services/manifest.yml")
  # Each pass carries the previous operation's failure message; container_health
  # re-raises what no stuck container explains.
  check(failures, detect["vars"]["container_health_deploy_failure_message"]
        .to_s.include?("#{role}_deploy_failure_message"),
        "role #{role}: the container health detection must be handed the deployment's own " \
        "failure message, or a Compose file that does not parse is reported as a healthy project")
  check(failures, verdict["vars"]["container_health_deploy_failure_message"]
        .to_s.include?("#{fact_prefix}_recreate_failure_message"),
        "role #{role}: the container health verdict must be handed the force-recreate's own " \
        "failure message")
  # A refusal that does not say the retry was already spent reads as a service
  # needing one more converge, which is the dishonesty the bound exists against.
  check(failures, verdict["vars"]["container_health_retried"].to_s.include?("#{fact_prefix}_recreate_spent"),
        "role #{role}: the container health verdict must say whether a force-recreate was " \
        "already spent, or its refusal reads as a service that needs one more converge")
  failures
end

def rescue_failures(role, fact_prefix, relative, top_level, recreate)
  failures = []
  blocks = PolicySupport.flatten_tasks(top_level).select { |task| task["block"].is_a?(Array) }
  deploy_block = blocks.find do |task|
    PolicySupport.flatten_tasks(task["block"]).any? { |inner| plain_deploy?(inner) }
  end
  check(failures, deploy_block && PolicySupport.flatten_tasks(deploy_block["rescue"]).any? do |task|
          task.dig("ansible.builtin.set_fact", "#{role}_deploy_failure_message")
        end,
        "role #{role}: #{relative} must wrap its deployment in a block whose rescue records " \
        "#{role}_deploy_failure_message, or the message Compose failed with is thrown away " \
        "before roles/container_health can explain it or re-raise it")
  return failures unless recreate

  recreate_block = blocks.find do |task|
    PolicySupport.flatten_tasks(task["block"]).any? { |inner| force_recreate?(inner) }
  end
  check(failures, recreate_block && PolicySupport.flatten_tasks(recreate_block["rescue"]).any? do |task|
          task.dig("ansible.builtin.set_fact", "#{fact_prefix}_recreate_failure_message")
        end,
        "role #{role}: #{relative} must wrap its force-recreate in a block whose rescue records " \
        "#{fact_prefix}_recreate_failure_message; `--wait` fails a replacement that came back unhealthy, " \
        "and the verdict diagnoses that far better than Compose can")
  failures
end

# The health sequence must carry the deployment's gate, or it runs against a
# project this converge did not start.
def gate_failures(role, relative, top_level, health_wired)
  return [] unless health_wired

  deploy_element = top_level.index do |task|
    PolicySupport.flatten_tasks([task]).any? { |inner| plain_deploy?(inner) }
  end
  verdict_element = top_level.rindex { |task| task.dig("vars", "container_health_service_name") }
  return [] unless deploy_element && verdict_element && verdict_element > deploy_element

  gate = conditions(top_level[deploy_element])
  return [] if gate.empty?

  failures = []
  ((deploy_element + 1)..verdict_element).each do |index|
    task = top_level[index]
    ungated = gate - conditions(task)
    check(failures, ungated.empty?,
          "role #{role}: #{relative} gates its deployment on #{gate.inspect} but " \
          "\"#{task['name'] || 'an unnamed task'}\" between the deployment and the container " \
          "health verdict does not carry #{ungated.inspect}, so it runs on a host the deployment " \
          "skipped")
  end
  failures
end

# --- self-test --------------------------------------------------------------
# Each row breaks one thing in a copy of roles/ and requires this sweep to name it.
MUTATIONS = [
  {
    label: "the container health detection",
    role: "komga",
    shared: true,
    expects: "includes roles/container_health 1 time(s)",
    plant: lambda do |tasks|
      tasks.reject! { |task| task.dig("vars", "container_health_refuse") == false }
    end
  },
  {
    label: "the deferred detection",
    role: "komga",
    shared: true,
    expects: "must detect without refusing",
    plant: lambda do |tasks|
      tasks.find { |task| task.dig("vars", "container_health_refuse") == false }["vars"]["container_health_refuse"] = true
    end
  },
  {
    label: "the refusing verdict",
    role: "seerr",
    shared: true,
    expects: "must be the one that refuses",
    # Anchored on the include: in the shared file the passes do not restate the name.
    plant: lambda do |tasks|
      health_passes(tasks).last["vars"]["container_health_refuse"] = false
    end
  },
  {
    label: "the conditional force-recreate",
    role: "vaultwarden",
    expects: "not conditional on a container actually being stuck",
    plant: lambda do |tasks|
      recreate_task(tasks).delete("when")
    end
  },
  {
    label: "the narrow force-recreate",
    role: "kapowarr",
    shared: true,
    expects: "must name only the services Docker reports as stuck",
    plant: lambda do |tasks|
      recreate_task(tasks)["community.docker.docker_compose_v2"]["dependencies"] = true
    end
  },
  {
    label: "the force-recreate itself",
    role: "trailarr",
    shared: true,
    expects: "must force-recreate a stuck container exactly once per converge",
    plant: lambda do |tasks|
      tasks.delete(recreate_block(tasks))
    end
  },
  {
    label: "the caught deployment failure",
    role: "pinchflat",
    expects: "must wrap its deployment in a block whose rescue records",
    plant: lambda do |tasks|
      tasks.find { |task| task["block"].is_a?(Array) && deploy_inner(task) }.delete("rescue")
    end
  },
  {
    label: "the caught recreate failure",
    role: "dozzle",
    shared: true,
    expects: "must wrap its force-recreate in a block whose rescue records",
    plant: lambda do |tasks|
      recreate_block(tasks).delete("rescue")
    end
  },
  {
    label: "the handed-on deployment failure",
    role: "jellyfin",
    expects: "must be handed the deployment's own failure message",
    plant: lambda do |tasks|
      tasks.find { |task| task.dig("vars", "container_health_refuse") == false }["vars"]["container_health_deploy_failure_message"] = ""
    end
  },
  {
    label: "the spent-retry disclosure",
    role: "audiobookshelf",
    expects: "must say whether a force-recreate was already spent",
    plant: lambda do |tasks|
      tasks.select { |task| task.dig("vars", "container_health_service_name") }
           .last["vars"].delete("container_health_retried")
    end
  },
  {
    label: "the verdict's place before everything that trusts the deployment",
    role: "komga",
    expects: "must run the deployment, then the detection",
    plant: lambda do |tasks|
      verdict = tasks.select { |task| task.dig("vars", "container_health_service_name") }.last
      cpu = tasks.find { |task| task.dig("vars", "container_cpu_service_name") }
      tasks[tasks.index(verdict)], tasks[tasks.index(cpu)] = cpu, verdict
    end
  },
  {
    # The one defect this change could introduce that no inline copy could have.
    label: "the shared recovery's reset of the carried failure message",
    role: "komga",
    shared: true,
    expects: "must clear container_health_recreate_failure_message",
    plant: lambda do |tasks|
      tasks.reject! do |task|
        task.dig("ansible.builtin.set_fact", "container_health_recreate_failure_message") == ""
      end
    end
  },
  {
    # The eighth copy, arriving beside the shared path rather than instead of it.
    label: "a second force-recreate kept beside the shared recovery",
    role: "komga",
    expects: "still holds 1 force-recreate(s) of its own",
    plant: lambda do |tasks|
      tasks << {
        "name" => "Force-recreate the stuck komga services again",
        "community.docker.docker_compose_v2" => {
          "project_src" => "{{ platform_current_dir }}/services/komga",
          "project_name" => "{{ komga_compose_project_name }}",
          "services" => "{{ container_health_stuck_services }}",
          "dependencies" => false,
          "recreate" => "always",
          "state" => "present"
        },
        "when" => "container_health_stuck_services | default([]) | length > 0",
        "register" => "komga_second_recreate"
      }
    end
  },
  {
    # A role classified as taking the shared path that quietly stops taking it.
    label: "a shared-recovery role's include of the shared file",
    role: "seerr",
    expects: "roles/container_health/tasks/recover.yml 0 time(s), not once",
    plant: lambda do |tasks|
      tasks.reject! { |task| shared_recovery_include?(task) }
    end
  },
  {
    # And the other direction: an inline role converted without being moved
    # across, so its recorded divergence goes on being read as still true.
    label: "the classification of a role that converted to the shared path",
    role: "bindery",
    expects: "move it to SHARED_RECOVERY_ROLES",
    plant: lambda do |tasks|
      tasks << {
        "name" => "Recover Bindery from a container that runs but never serves",
        "ansible.builtin.include_role" => { "name" => "container_health", "tasks_from" => "recover" },
        "vars" => { "container_health_service_name" => "bindery" }
      }
    end
  },
  {
    label: "the health sequence's own deployment gate",
    role: "arr",
    expects: "does not carry",
    plant: lambda do |tasks|
      tasks.select { |task| task.dig("vars", "container_health_service_name") }
           .last.delete("when")
    end
  }
].freeze

# The two health passes of a sequence, in either shape. `tasks_from` tells a pass
# apart from the include of the shared sequence that holds both of them.
def health_passes(tasks)
  tasks.select do |task|
    task.dig("ansible.builtin.include_role", "name") == "container_health" &&
      task.dig("ansible.builtin.include_role", "tasks_from").nil?
  end
end

def deploy_inner(task)
  PolicySupport.flatten_tasks([task]).find { |inner| plain_deploy?(inner) }
end

# The top-level element holding the force-recreate (for block rows), and the task.
def recreate_block(tasks)
  tasks.find do |task|
    PolicySupport.flatten_tasks([task]).any? { |inner| force_recreate?(inner) }
  end
end

def recreate_task(tasks)
  PolicySupport.flatten_tasks(tasks).find { |task| force_recreate?(task) }
end

def self_test_failures
  mismatches = []
  MUTATIONS.each do |mutation|
    Dir.mktmpdir("nas-platform-container-health.") do |directory|
      FileUtils.cp_r(File.join(ROOT, "roles"), File.join(directory, "roles"))
      role = mutation.fetch(:role)
      # Rows for shared-recovery roles plant into the shared file, which is what the
      # checker reads for them.
      file = if mutation[:shared]
               File.join(directory, SHARED_RECOVERY_FILE)
             else
               role_task_files(directory, role).find do |candidate|
                 PolicySupport.flatten_tasks(parse_tasks(candidate)).any? { |task| plain_deploy?(task) }
               end
             end
      tasks = parse_tasks(file)
      mutation.fetch(:plant).call(tasks)
      File.write(file, tasks.to_yaml)

      caught = wiring_failures(directory)
      if caught.empty?
        mismatches << "removing #{mutation.fetch(:label)} from #{role} was accepted"
      elsif caught.none? { |failure| failure.include?(mutation.fetch(:expects)) }
        mismatches << "removing #{mutation.fetch(:label)} from #{role} was caught by the wrong " \
                      "assertion: #{caught.join(' | ')}"
      end
    end
  end
  mismatches
end

if ARGV.include?("--self-test")
  mismatches = self_test_failures
  unless mismatches.empty?
    mismatches.each { |mismatch| warn "FAIL self-test: #{mismatch}" }
    abort "#{mismatches.length} self-test mismatch(es) of #{MUTATIONS.length} planted regressions"
  end

  puts "container health wiring: self-test detects #{MUTATIONS.length} planted regressions"
  exit
end

failures = wiring_failures(ROOT)
subjects = deploying_roles(ROOT) - EXEMPT_ROLES.keys
report(failures,
       "container health wiring: #{subjects.length} whole-project Compose deployments bracket " \
       "themselves with detect, one bounded force-recreate and a verdict -- " \
       "#{(SHARED_RECOVERY_ROLES & subjects).length} through #{SHARED_RECOVERY_FILE} and " \
       "#{(INLINE_RECOVERY_ROLES.keys & subjects).length} from their own copy, each with its " \
       "divergence recorded " \
       "(#{EXEMPT_ROLES.length} multi-phase or computed deployments exempted in writing)",
       "container health wiring violation(s)")
