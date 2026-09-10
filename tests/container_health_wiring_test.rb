#!/usr/bin/env ruby
# Every whole-project Compose deployment brackets itself with the container
# health detect / repair-once / verdict sequence #509 built and #537 generalised.
#
# THE HOLE THIS CLOSES. `docker compose up` will not replace a container whose
# specification has not changed -- measured on Docker 29.7.2 and recorded in
# roles/container_health/tasks/main.yml -- so a stack wedged by anything other
# than an image bump stays wedged through every five-minute converge, reporting
# success the whole time. Bindery did exactly that for three days. #509 wired the
# repair into one role and left fifteen with the hole; this file is what keeps
# the other eleven wired once #537 closed them, and what makes a twelfth arrive
# wired rather than arrive silent.
#
# WHY A SWEEP RATHER THAN A HELPER THE CONTRACT PROGRAMS CALL. The obvious place
# for these properties is each service's own contract program, the way
# tests/contracts/bindery-static.rb holds them for Bindery. Two of the twelve
# subjects cannot be reached that way at all: **ntfy has no contract program**
# -- no row in tests/contracts/registry.yml, no tests/contracts/ntfy-*.rb, and
# tests/deployment_gate_coverage_test.rb records why it needs none -- and
# Dozzle's static half is tests/contracts/dozzle-stack.rb, which is not shaped
# like the *-static.rb family. A guard that eleven roles carry and the twelfth
# escapes is the exemption-list shape this repository keeps deleting. A sweep
# discovers its subjects from the tree instead, so a role that gains a Compose
# deployment is in scope the moment it does.
#
# Bindery is therefore covered twice, deliberately: tests/contracts/bindery-static.rb
# keeps its own copies of these properties and tests/bindery_contract_test.rb
# plants thirteen source mutations into exactly that text. Deleting them to avoid
# the duplication would delete thirteen proofs to make a gate faster, which is
# the trade this repository refuses.
#
# WHAT IS NOT ASSERTED HERE, because it is asserted elsewhere and a second copy
# is a second thing to keep true:
#
#   - that each role registers its Compose results and names every one of them in
#     its ntfy deployment report. tests/policy_test.rb sweeps that over every
#     role with a `state: present` task, so the force-recreate is caught there --
#     a successful self-repair reports `changed` and ntfy cannot tell it from an
#     ordinary changed deploy, which is forced rather than chosen.
#   - that the deploying role is the one that resolves its own service name and
#     renders its own .env. tests/policy_deployment_test.rb owns that, and it is
#     the reason the force-recreate lives in the service role rather than in
#     roles/container_health.
require "fileutils"
require "tmpdir"
require "yaml"

require_relative "policy_support"

include TestScaffold

# The twelve, pinned in both directions rather than only counted. A derived
# subject list that quietly empties passes every property vacuously, and a floor
# alone cannot tell "Komga was removed" from "Komga stopped matching the
# selector".
EXPECTED_SUBJECTS = %w[
  arr audiobookshelf bindery downloaders dozzle jellyfin
  kapowarr komga ntfy pinchflat seerr trailarr
].freeze
SUBJECT_FLOOR = 12 # the twelve single-`up` roles as of #537

# The roles that deploy Compose and are deliberately NOT subjects. Each answers
# "which services may be force-recreated with --no-deps, and at which phase?"
# differently, and roles/seafile/tasks/recover_wedged_boot.yml -- deleted with
# the service in #501 and recovered from history during #509 -- was explicit that
# its own recreate was safe ONLY because phase one had already waited on both
# dependencies. So each of these needs a decision recorded in its own role rather
# than the mechanical wiring, and until one is taken the exemption is stated here
# where it can be read.
#
# Held in both directions below: a name here that no longer deploys Compose fails,
# and a name here that has become single-phase fails too, so an exemption cannot
# outlive the shape that justified it.
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

# A role's Compose deployment, told apart from its own bounded repair by
# `recreate` rather than by position, because position is what the ordering
# property is for. `state` is read rather than presence of the module key: arr and
# downloaders each stop a disabled project with `state: absent` BEFORE the deploy,
# and Dozzle stops two services with `state: stopped` before its own, so "the
# first docker_compose_v2 task" is not the deployment in three of the twelve.
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

# Every role directory holding at least one whole-project `up`, discovered rather
# than listed.
def deploying_roles(root)
  Dir[File.join(root, "roles", "*")].select { |path| File.directory?(path) }.sort.filter_map do |path|
    role = File.basename(path)
    tasks = role_task_files(root, role).flat_map { |file| PolicySupport.flatten_tasks(parse_tasks(file)) }
    next nil if tasks.none? { |task| task.dig("community.docker.docker_compose_v2", "state") == "present" }

    role
  end
end

# Ansible applies a block's `when` to every task inside it, so the gate a task
# actually runs under is the union of its own conditions and those of the
# top-level element carrying it. arr and downloaders gate their whole deployment
# on media_usenet_enabled, and a health include that does not carry that gate
# runs where the deploy did not.
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

  # The other direction: an exemption survives only while the shape that earned
  # it does. A multi-phase role has more than one whole-project `up`, and
  # beszel's single one names a `services:` list it computes at run time; a role
  # that became an ordinary single-`up` deployment has to be wired or re-argued
  # rather than left behind an exemption written for a shape it no longer has.
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

  subjects.each { |role| failures.concat(role_failures(root, role)) }
  failures
end

def role_failures(root, role) # rubocop:disable Metrics/AbcSize
  failures = []
  files = role_task_files(root, role)
  deploy_file = files.find { |file| PolicySupport.flatten_tasks(parse_tasks(file)).any? { |task| plain_deploy?(task) } }
  unless deploy_file
    return ["role #{role}: no task file holds a whole-project Compose deployment"]
  end

  top_level = parse_tasks(deploy_file)
  tasks = PolicySupport.flatten_tasks(top_level)
  relative = deploy_file.sub("#{root}/", "")

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

  # The service name each pass reports under is required to be the one the CPU
  # verification already uses, which is the manifest service directory. Deriving
  # it rather than restating it is what keeps a hyphenated service (paperless-ngx
  # against paperless_ngx) from needing a special case here.
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
    # THE idempotence property, and the reason a converged host reports changed=0.
    # container_health publishes an empty list on a healthy project and never runs
    # at all under --check, so `| default([])` leaves this task skipped on every
    # converge with nothing to repair.
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

  failures.concat(bracketing_failures(role, relative, tasks, health_indexes, recreate, cpu_index, service_name))
  failures.concat(rescue_failures(role, relative, top_level, recreate))
  failures.concat(gate_failures(role, relative, top_level, health_indexes.length == 2))
  failures
end

def bracketing_failures(role, relative, tasks, health_indexes, recreate, cpu_index, service_name) # rubocop:disable Metrics/ParameterLists
  return [] unless health_indexes.length == 2

  failures = []
  detect_index, verdict_index = health_indexes
  detect = tasks[detect_index]
  verdict = tasks[verdict_index]
  deploy_index = tasks.index { |task| plain_deploy?(task) }
  recreate_index = recreate ? tasks.index(recreate) : nil

  # A container in `Restarting` still appears in `docker container ls --quiet`,
  # so the CPU verification sails straight past one and the readiness probe below
  # it then fails on a timeout that names nothing (#510). Everything that trusts
  # the deployment has to sit after the verdict.
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
  # Compose fails a crash-looping container with "container X is unhealthy", which
  # says nothing about why, and an operation that failed for some OTHER reason has
  # to leave with the message that says so. Each pass carries the message of the
  # operation before it; roles/container_health re-raises what no stuck container
  # explains.
  check(failures, detect["vars"]["container_health_deploy_failure_message"]
        .to_s.include?("#{role}_deploy_failure_message"),
        "role #{role}: the container health detection must be handed the deployment's own " \
        "failure message, or a Compose file that does not parse is reported as a healthy project")
  check(failures, verdict["vars"]["container_health_deploy_failure_message"]
        .to_s.include?("#{role}_recreate_failure_message"),
        "role #{role}: the container health verdict must be handed the force-recreate's own " \
        "failure message")
  # A refusal that does not say the retry was already spent reads as a service
  # needing one more converge, which is the dishonesty the bound exists against.
  check(failures, verdict["vars"]["container_health_retried"].to_s.include?("#{role}_recreate_spent"),
        "role #{role}: the container health verdict must say whether a force-recreate was " \
        "already spent, or its refusal reads as a service that needs one more converge")
  failures
end

def rescue_failures(role, relative, top_level, recreate)
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
          task.dig("ansible.builtin.set_fact", "#{role}_recreate_failure_message")
        end,
        "role #{role}: #{relative} must wrap its force-recreate in a block whose rescue records " \
        "#{role}_recreate_failure_message; `--wait` fails a replacement that came back unhealthy, " \
        "and the verdict diagnoses that far better than Compose can")
  failures
end

# arr and downloaders deploy only when media_usenet_enabled, and the health
# sequence must carry the same gate: an ungated verdict runs against a project
# this converge deliberately did not start, and an ungated set_fact leaves
# <role>_recreate_spent undefined for the verdict that reads it.
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
#
# Each row breaks exactly one thing in a throwaway copy of roles/ and requires
# this sweep to name it. `roles/` alone is copied because this sweep reads
# nothing else, which is also what keeps a row under a second.
MUTATIONS = [
  {
    label: "the container health detection",
    role: "komga",
    expects: "includes roles/container_health 1 time(s)",
    plant: lambda do |tasks|
      tasks.reject! { |task| task.dig("vars", "container_health_refuse") == false }
    end
  },
  {
    label: "the deferred detection",
    role: "komga",
    expects: "must detect without refusing",
    plant: lambda do |tasks|
      tasks.find { |task| task.dig("vars", "container_health_refuse") == false }["vars"]["container_health_refuse"] = true
    end
  },
  {
    label: "the refusing verdict",
    role: "seerr",
    expects: "must be the one that refuses",
    plant: lambda do |tasks|
      tasks.select { |task| task.dig("vars", "container_health_service_name") }
           .last["vars"]["container_health_refuse"] = false
    end
  },
  {
    label: "the conditional force-recreate",
    role: "ntfy",
    expects: "not conditional on a container actually being stuck",
    plant: lambda do |tasks|
      recreate_block(tasks).delete("when")
    end
  },
  {
    label: "the narrow force-recreate",
    role: "kapowarr",
    expects: "must name only the services Docker reports as stuck",
    plant: lambda do |tasks|
      recreate_block(tasks)["community.docker.docker_compose_v2"]["dependencies"] = true
    end
  },
  {
    label: "the force-recreate itself",
    role: "trailarr",
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
    label: "the health sequence's own deployment gate",
    role: "arr",
    expects: "does not carry",
    plant: lambda do |tasks|
      tasks.select { |task| task.dig("vars", "container_health_service_name") }
           .last.delete("when")
    end
  }
].freeze

def deploy_inner(task)
  PolicySupport.flatten_tasks([task]).find { |inner| plain_deploy?(inner) }
end

# The top-level element holding the force-recreate.
def recreate_block(tasks)
  tasks.find do |task|
    PolicySupport.flatten_tasks([task]).any? { |inner| force_recreate?(inner) }
  end
end

def self_test_failures
  mismatches = []
  MUTATIONS.each do |mutation|
    Dir.mktmpdir("nas-platform-container-health.") do |directory|
      FileUtils.cp_r(File.join(ROOT, "roles"), File.join(directory, "roles"))
      role = mutation.fetch(:role)
      file = role_task_files(directory, role).find do |candidate|
        PolicySupport.flatten_tasks(parse_tasks(candidate)).any? { |task| plain_deploy?(task) }
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
       "themselves with detect, one bounded force-recreate and a verdict " \
       "(#{EXEMPT_ROLES.length} multi-phase or computed deployments exempted in writing)",
       "container health wiring violation(s)")
