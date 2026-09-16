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
# tests/contracts/bindery-static.rb holds them for Bindery. Some subjects cannot
# be reached that way at all: **vaultwarden and karakeep have no contract
# program** -- no row in tests/contracts/registry.yml -- and
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
#     its deployment report. tests/policy_test.rb sweeps that over every
#     role with a `state: present` task, so the force-recreate is caught there --
#     a successful self-repair reports `changed` and the report cannot tell it from an
#     ordinary changed deploy, which is forced rather than chosen. Since #646 the
#     shared force-recreate is registered in a file no service role owns, so that
#     sweep asks the CALLER's report to name container_health_wedged_recreate
#     instead; the property is the same one and it is still not asserted here.
#   - that the deploying role is the one that resolves its own service name and
#     renders its own .env. tests/policy_deployment_test.rb owns that.
#
#     This bullet used to end "and it is the reason the force-recreate lives in
#     the service role rather than in roles/container_health", which
#     roles/container_health/tasks/main.yml said too. It was false, and #646
#     measured it: that check's `deploys_release` predicate asks only whether SOME
#     `docker_compose_v2` task in the role addresses the release directory, both
#     Compose files and the rendered .env, and the PLAIN DEPLOY satisfies all
#     three on its own. Moving the force-recreate out left it green. What the
#     check does forbid is moving the plain deploy, which is why that stays in the
#     calling role and why the shared file takes those four values as parameters
#     rather than deriving them.
#
# ONE THING THIS SEQUENCE RELIES ON THAT NOTHING STATES ELSEWHERE, and it is the
# likeliest future bug here. roles/container_health publishes
# container_health_stuck_services with set_fact, so it is a play-scope fact that
# SURVIVES INTO THE NEXT ROLE rather than a value scoped to the include. What
# makes that safe is that every consumer re-runs inspect.yml immediately before
# reading it, so each pass reads a list its own probe just wrote. Two places lean
# on that and neither says so at its own site: a gated-off arr or downloaders
# skips its detect entirely, and the list it would have read belongs to whichever
# role ran last -- harmless only because its recreate carries the same gate and is
# skipped too; and under --check the fact is never set at all, which is exactly
# what the `| default([])` on every recreate's `when` is carrying. A role that
# ever reads that list without a detect pass of its own would be repairing
# another project's diagnosis.
require "fileutils"
require "tmpdir"
require "yaml"

require_relative "policy_support"

include TestScaffold

# The subjects, pinned in both directions rather than only counted. A derived
# subject list that quietly empties passes every property vacuously, and a floor
# alone cannot tell "Komga was removed" from "Komga stopped matching the
# selector".
EXPECTED_SUBJECTS = %w[
  arr audiobookshelf bindery downloaders dozzle jellyfin karakeep
  kapowarr komga pinchflat seerr trailarr vaultwarden
].freeze
# the eleven of #537's twelve single-`up` roles still deployed, plus vaultwarden
# (#547) and karakeep (#551); adguard was the fourteenth until #577 removed the
# service, and #558 removed the twelfth of #537's
SUBJECT_FLOOR = 13

# WHICH SHAPE EACH SUBJECT TAKES, pinned in both directions for the reason the
# subject list above is. #537 wired thirteen roles by writing the sequence out in
# each of them, and six of those copies were byte-identical over 114 lines --
# task text, rationale comments and all -- with nothing holding them in
# agreement. #646 moved that one copy to roles/container_health/tasks/recover.yml
# and left the other seven, because each of them diverges in a way that is a
# judgement rather than a rename. What the pair below buys is that the EIGHTH
# copy cannot land quietly: a subject is in exactly one of these two lists, so a
# new role either takes the shared path or arrives with its divergence written
# down where it can be read.
SHARED_RECOVERY_ROLES = %w[dozzle kapowarr komga pinchflat seerr trailarr].freeze
SHARED_RECOVERY_FILE = File.join("roles", "container_health", "tasks", "recover.yml")
# Measured rather than asserted: each entry is what a normalised diff against the
# shared file actually shows, on 847cbe1's tree. Two of them are one edit away and
# say so -- that is the follow-up #646 names, not a claim that they cannot
# convert.
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
#
# The predicate is `plain_deploy?` rather than `state == "present"`, which is what
# it said until #646 -- and the two stopped meaning the same thing when the shared
# force-recreate moved into roles/container_health. That task names a `services:`
# list and passes `dependencies: false`, so it is by construction NOT a
# whole-project `up`, and a selector that collected it would make this sweep
# demand of its own shared file the very sequence that file IS. Narrowing the
# predicate to what the sentence above always claimed is not a weakening: nothing
# that was a subject stops being one, which the pinned list either side of this
# is what proves.
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

# One-level variable resolution, so a value the caller passed reads here exactly
# as the inline roles write it. Only names the include actually passed are
# substituted, which is what leaves container_health_stuck_services and
# container_health_recreate_failure_message -- the shared file's own outputs --
# alone.
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

# Splice the shared recovery into the caller's element list in place of its
# include, with the include's own vars resolved and its gate carried onto every
# element -- which is what Ansible does with an include's `when`. Every property
# below then reads ONE task list whichever shape the role takes, so a defect
# planted in the shared file is caught by the same assertion that caught it while
# the six roles each held their own copy.
def resolve_shared_recovery(root, top_level)
  shared = parse_tasks(File.join(root, SHARED_RECOVERY_FILE))
  top_level.flat_map do |task|
    next [task] unless shared_recovery_include?(task)

    outer = task["vars"] || {}
    gate = conditions(task)
    shared.map do |inner|
      resolved = substitute(inner, outer)
      # Merged onto the two health passes only, not onto every spliced task. The
      # caller's vars are in scope for all of them, but `container_health_service_name`
      # in a task's `vars` is what identifies a pass here, and merging it into all
      # six would report one include as six.
      if resolved.dig("ansible.builtin.include_role", "name") == "container_health"
        resolved["vars"] = outer.merge(resolved["vars"] || {})
      end
      resolved["when"] = (gate + conditions(inner)).uniq unless gate.empty?
      resolved
    end
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

  failures.concat(shape_failures(root, subjects))
  subjects.each { |role| failures.concat(role_failures(root, role)) }
  failures
end

# Which of the two shapes each subject takes, held in both directions. This is
# the guard against the eighth copy: a subject in neither list fails, a
# shared-recovery role that stops including the shared file fails, and an inline
# role that starts including it fails until it is moved across. The lists cannot
# both be satisfied by the same role either, so "convert it and forget to delete
# the copy" is caught too.
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

  # THE ONE PROPERTY THE SHARED FILE HAS THAT NO INLINE COPY NEEDED, and the
  # likeliest bug in this change. set_fact writes a play-scope fact that survives
  # into the next role. While each of the six carried its own copy the recreate
  # failure message was named per role, so one service could not read another's;
  # one shared name can, because the message is written only in a rescue. Six
  # callers in one site.yml run makes it reachable: a recreate that fails in the
  # first would still be set when the fifth takes its verdict, and that verdict
  # would refuse naming another service's failure. Nothing static catches that and
  # no single-lane suite reaches it, so it is asserted here. The other two values
  # crossing the same boundary clear themselves -- the detect pass rewrites
  # container_health_stuck_services, and container_health_wedged_recreate
  # re-registers even when skipped.
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

  # Resolved before anything reads it, so the six roles taking the shared
  # recovery and the seven still carrying their own are held to one set of
  # properties. The only thing that has to know which shape a role took is the
  # prefix of the two facts the sequence hands itself: per-role while the copy is
  # the role's own, and container_health once it is the shared file's.
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
    # Anchored on the include itself rather than on `container_health_service_name`
    # in its vars: in the shared file that name is the CALLER's and the two passes
    # do not restate it, so the old selector matched nothing there and the row
    # crashed rather than planting.
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

# The top-level element holding the force-recreate, and the force-recreate task
# itself. A row that breaks the block -- its rescue, its presence -- wants the
# first; a row that breaks the `up` wants the second, and the two are not the
# same hash.
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
      # Where the row's subject actually lives. Six roles take the shared
      # recovery, so a row breaking the detection, the recreate or the verdict
      # for one of them has to plant into roles/container_health/tasks/recover.yml
      # -- planting into the role's own file would edit a shape the checker no
      # longer reads there and report a defect it never saw. `shared: true` is the
      # re-anchoring #646 owed those rows, not a new exemption: the role field
      # still names which subject the row breaks, and the assertion it expects is
      # unchanged.
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
