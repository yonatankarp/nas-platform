#!/usr/bin/env ruby
# frozen_string_literal: true

# No task may read a registered name before the task that registers it.
#
# THE HOLE THIS CLOSES (#547). roles/vaultwarden/tasks/deploy.yml gated its
# DOMAIN assertion on `vaultwarden_runtime_env.stat.exists` while the stat that
# registers it sat thirty lines below. Ansible resolves a `when` when the task
# runs, so that was a forward reference -- and Ansible short-circuits a `when`
# list, which is the only reason anything was green: the first term was
# `vaultwarden_deployment_enabled | bool`, the stack landed dark, and the second
# term was therefore never evaluated by any check, lane or converge.
#
# WHAT IT COST IS THE POINT, because the defect is worth nothing and the shape is
# worth everything. Flipping the gate makes it fatal at the FIRST task of the
# enabled path, in every combination -- including a host whose .env is present,
# since the variable does not exist yet regardless of what it would have said.
# `A 'when' expression failed: 'vaultwarden_runtime_env' is undefined`. The
# production poller converges every five minutes, so that is a live NAS failing
# every five minutes with the repository as the only way in, arriving on the
# commit that flips a flag and touches nothing else.
#
# WHY A STATIC CHECK AND NOT A LANE. The defect lives on a path no test executes:
# every lane and every Mac hook runs this service dark, and a dark run is exactly
# the run that cannot see it. That is general rather than particular to
# Vaultwarden -- any role with a `when:` whose first term is false on the paths
# CI happens to exercise can hide one -- so the subject is every role, not the
# one that had the bug. The tree is clean today, which is what makes this
# affordable to land: measured at zero across every role before it was written.
#
# TWO THINGS THAT ARE NOT DEFECTS, and both had to be taught rather than assumed.
#
# A `| default(...)` makes a forward reference legal, and roles rely on that: a
# deployment report reads `x_deploy | default({}) is changed` precisely because
# the task registering it may have been skipped. Only UNGUARDED references are
# reported.
#
# A block wrapper is not its children. PolicySupport.flatten_tasks emits the
# block before the tasks inside it, so walking a block's own strings into its
# `block:`, `rescue:` and `always:` sections makes every "Deploy X, catching a
# container that runs but never serves" appear to read the `x_deploy` its child
# registers. That was this checker's own first defect and it reported 42 of them
# across 27 roles -- every one a false positive, and a checker that cried wolf 42
# times would have been deleted rather than believed. The nested sections are
# skipped here because those tasks are visited on their own turn.

require "yaml"

require_relative "policy_support"

include PolicySupport
include TestScaffold

ROOT = ENV.fetch("PLATFORM_FORWARD_REFERENCE_ROOT", File.expand_path("..", __dir__))

# The sections whose contents are tasks in their own right rather than part of
# the enclosing task's own arguments.
NESTED_SECTIONS = %w[block rescue always].freeze

# Every role with a task entry point. Derived, so a role added tomorrow is in
# scope without an edit -- and floored, because a glob that stops matching
# reports success having checked nothing.
ROLE_FLOOR = 25

def own_strings(node, collected = [], top: false)
  case node
  when String then collected << node
  when Hash
    node.each do |key, value|
      next if top && NESTED_SECTIONS.include?(key.to_s)

      collected << key.to_s
      own_strings(value, collected)
    end
  when Array then node.each { |element| own_strings(element, collected) }
  end
  collected
end

# True when every mention of +name+ in +text+ hands it to `default`. The chain
# after the name is consumed first so `x.stat.exists | default(false)` reads as
# guarded and `x.stat.exists` does not.
def guarded?(text, name)
  pattern = /#{Regexp.escape(name)}((?:\.[A-Za-z_][A-Za-z0-9_]*|\[[^\]]*\])*)\s*(\|\s*[a-z_]+)?/
  text.scan(pattern).all? { |_chain, filter| filter.to_s.include?("default") }
end

def role_problems(role_dir)
  main = File.join(role_dir, "tasks", "main.yml")
  return [] unless File.file?(main)

  role = File.basename(role_dir)
  tasks = flatten_tasks(static_role_tasks(main, aliases: true))
  # First registration wins: a name registered twice is available from the
  # earlier of the two, which is the conservative reading.
  registers = {}
  tasks.each_with_index do |task, index|
    name = task["register"]
    registers[name] = index if name.is_a?(String) && !registers.key?(name)
  end

  problems = []
  tasks.each_with_index do |task, index|
    strings = own_strings(task, [], top: true)
    registers.each do |name, registered_at|
      # `>` and not `>=`: a task's own changed_when and failed_when are evaluated
      # after it runs and legitimately read its own register.
      next unless registered_at > index
      next unless strings.any? do |text|
        text.match?(/(?<![A-Za-z0-9_])#{Regexp.escape(name)}(?![A-Za-z0-9_])/) &&
          !guarded?(text, name)
      end

      problems << "roles/#{role}: #{(task['name'] || '<unnamed task>').inspect} reads " \
                  "#{name} before " \
                  "#{(tasks[registered_at]['name'] || '<unnamed task>').inspect} registers it. " \
                  "Ansible resolves this when the task runs, so it fails with " \
                  "\"'#{name}' is undefined\" on every path that reaches it -- and a `when:` " \
                  "list short-circuits, so a term after a false one is never evaluated and the " \
                  "defect stays invisible until the earlier term becomes true. Move the read " \
                  "after the registration, or guard it with `| default(...)` if it is genuinely " \
                  "optional"
    end
  end
  problems
end

def sweep(root = ROOT)
  Dir[File.join(root, "roles", "*")].sort.flat_map { |role_dir| role_problems(role_dir) }
end

# --- self-test ---------------------------------------------------------------
#
# Folded into every run rather than a separate --self-test invocation, because
# the sweep costs under a second and a guard that proves itself on every run is
# one fewer manifest line to keep true. CLAUDE.md records what trusting an
# unproven static checker cost: this one is shown the real #547 defect, and a
# guarded reference it must leave alone, before its clean report means anything.
PLANT_ROLE = "vaultwarden"
PLANT_FILE = File.join("roles", PLANT_ROLE, "tasks", "deploy.yml")
PLANTS = [
  { "name" => "the #547 defect itself: a when: term read before its stat registers it",
    "from" => "  when: vaultwarden_deployment_enabled | bool\n\n- name: Render the Vaultwarden environment",
    "to" => "  when:\n    - vaultwarden_deployment_enabled | bool\n" \
            "    - vaultwarden_runtime_env.stat.exists\n\n- name: Render the Vaultwarden environment",
    "detected" => true },
  { "name" => "the same read, guarded by default(), which is legal and must not be reported",
    "from" => "  when: vaultwarden_deployment_enabled | bool\n\n- name: Render the Vaultwarden environment",
    "to" => "  when:\n    - vaultwarden_deployment_enabled | bool\n" \
            "    - vaultwarden_runtime_env.stat.exists | default(false)\n" \
            "\n- name: Render the Vaultwarden environment",
    "detected" => false }
].freeze

def self_test_problems
  require "fileutils"
  require "tmpdir"
  problems = []
  source_path = File.join(ROOT, PLANT_FILE)
  source = File.read(source_path)
  PLANTS.each do |plant|
    unless source.include?(plant.fetch("from"))
      problems << "the plant #{plant.fetch('name').inspect} no longer matches #{PLANT_FILE}; " \
                  "re-anchor it rather than deleting it"
      next
    end
    Dir.mktmpdir("nas-platform-forward-reference-") do |directory|
      FileUtils.cp_r(File.join(ROOT, "roles"), directory)
      File.write(File.join(directory, PLANT_FILE),
                 source.sub(plant.fetch("from"), plant.fetch("to")), mode: "w", perm: 0o600)
      detected = sweep(directory).any? { |problem| problem.include?("vaultwarden_runtime_env") }
      next if detected == plant.fetch("detected")

      problems << (plant.fetch("detected") ?
        "planting #{plant.fetch('name').inspect} was NOT detected, so this checker reports a " \
        "clean tree without being able to find the defect it was written for" :
        "planting #{plant.fetch('name').inspect} WAS reported, so this checker refuses the " \
        "guarded reads that roles legitimately rely on")
    end
  end
  problems
end

failures = []
roles = Dir[File.join(ROOT, "roles", "*")].select { |path| File.file?(File.join(path, "tasks", "main.yml")) }
check_floor(failures, roles.length, ROLE_FLOOR, "roles with a tasks/main.yml to sweep")
sweep.each { |problem| check(failures, false, problem) }
self_test_problems.each { |problem| failures << problem }

report(failures,
       "role forward references: no task in #{roles.length} roles reads a registered name before " \
       "the task that registers it, and #{PLANTS.length} planted cases are judged correctly",
       "role forward reference violation(s)")
