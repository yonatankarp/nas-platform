#!/usr/bin/env ruby
# frozen_string_literal: true

# No task may read a registered name before the task that registers it (#547):
# a `when` short-circuited by a false first term hides one on every dark run.
# A `| default(...)` makes a forward reference legal, and block wrappers are not
# walked into their children, which are visited on their own turn.

require "yaml"

require_relative "policy_support"

include PolicySupport
include TestScaffold

ROOT = ENV.fetch("PLATFORM_FORWARD_REFERENCE_ROOT", File.expand_path("..", __dir__))

NESTED_SECTIONS = %w[block rescue always].freeze

# Floored, because a glob that stops matching checks nothing.
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

# True when every mention of +name+ in +text+ is handed to `default`.
def guarded?(text, name)
  pattern = /#{Regexp.escape(name)}((?:\.[A-Za-z_][A-Za-z0-9_]*|\[[^\]]*\])*)\s*(\|\s*[a-z_]+)?/
  text.scan(pattern).all? { |_chain, filter| filter.to_s.include?("default") }
end

def role_problems(role_dir)
  main = File.join(role_dir, "tasks", "main.yml")
  return [] unless File.file?(main)

  role = File.basename(role_dir)
  tasks = flatten_tasks(static_role_tasks(main, aliases: true))
  registers = {}
  tasks.each_with_index do |task, index|
    name = task["register"]
    registers[name] = index if name.is_a?(String) && !registers.key?(name)
  end

  problems = []
  tasks.each_with_index do |task, index|
    strings = own_strings(task, [], top: true)
    registers.each do |name, registered_at|
      # `>` not `>=`: a task's own changed_when/failed_when read its own register.
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

# --- self-test: run every time, against the real #547 defect and a guarded reference ---
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
