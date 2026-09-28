#!/usr/bin/env ruby
# frozen_string_literal: true

# Runs the role's own system-configuration tasks, lifted by name out of
# roles/immich/tasks/main.yml, against a fixture /api/system-config. The managed
# settings come from the real role defaults through include_vars, never through
# a re-serialized copy: the storage template is Handlebars, which Ansible would
# template as Jinja unless the defaults file marks it !unsafe, and only a load
# of that file keeps the tag (#907).

require "json"
require "yaml"

require_relative "policy_support"
require_relative "http_fixture_support"

include HttpFixtureSupport
include TestScaffold

ROLE_TASKS = File.join(ROOT, "roles", "immich", "tasks", "main.yml")
DEFAULTS = File.join(ROOT, "roles", "immich", "defaults", "main.yml")
TEMPLATE = "{{y}}/{{y}}-{{MM}}-{{dd}}/{{filename}}"
PLAN_MARKER = "IMMICH_PLAN_SETTINGS_REPAIR"

RECONCILE_TASKS = [
  "Read the Immich system configuration",
  "Resolve the desired Immich system configuration",
  "Resolve Immich settings repair requirement",
  "Report planned Immich settings repair",
  "Repair the Immich system configuration"
].freeze
VERIFY_TASKS = [
  "Read the exact Immich system configuration",
  "Require the managed Immich settings"
].freeze

def role_tasks(names)
  tasks = YAML.safe_load_file(ROLE_TASKS, aliases: true)
  names.map do |name|
    tasks.find { |task| task["name"] == name } or abort("#{ROLE_TASKS} has no task named #{name}")
  end
end

# The pinned server's default (server/src/dtos/config.dto.ts), plus an unmanaged
# secret the whole-document PUT must carry back untouched.
def server_default
  {
    "newVersionCheck" => { "enabled" => true },
    "machineLearning" => { "enabled" => true },
    "backup" => { "database" => { "enabled" => false } },
    "notifications" => { "smtp" => { "transport" => { "password" => "fixture-smtp-secret" } } },
    "storageTemplate" => { "enabled" => false, "hashVerificationEnabled" => true, "template" => TEMPLATE }
  }
end

def converged
  server_default.merge(
    "newVersionCheck" => { "enabled" => false },
    "backup" => { "database" => { "enabled" => true } },
    "storageTemplate" => { "enabled" => true, "hashVerificationEnabled" => true, "template" => TEMPLATE }
  )
end

def run_settings(port, names, *arguments)
  # Namespaced, because include_vars outranks play vars and the defaults file
  # also declares immich_api.
  tasks = [{ "name" => "Load the real Immich role defaults",
             "ansible.builtin.include_vars" => { "file" => DEFAULTS, "name" => "immich_role_defaults" } }] +
          role_tasks(names)
  run_playbook(tasks, { "immich_managed_settings" => "{{ immich_role_defaults.immich_managed_settings }}",
                        "immich_api" => "http://127.0.0.1:#{port}/api",
                        "immich_initialized" => true,
                        "immich_reconcile_token" => "fixture-token",
                        "immich_verification_token" => "fixture-token" },
               *arguments, prefix: "nas-platform-immich-system-config-")
end

def with_immich(initial)
  state = { config: JSON.parse(JSON.generate(initial)), puts: [] }
  with_http_fixture(->(port) { yield port, state }, reason: "OK") do |method, target, _headers, body|
    case [method, target]
    when ["GET", "/api/system-config"] then [200, JSON.generate(state.fetch(:config))]
    when ["PUT", "/api/system-config"]
      state[:puts] << body
      state[:config] = JSON.parse(body)
      [200, body]
    else [404, JSON.generate("message" => "not found")]
    end
  end
end

failures = []

with_immich(server_default) do |port, state|
  stdout, stderr, status = run_settings(port, RECONCILE_TASKS + VERIFY_TASKS)
  check(failures, status.success?, "reconcile from the server default failed: #{failure_tail(stdout + stderr)}")
  check(failures, state[:puts].length == 1, "reconcile sent #{state[:puts].length} PUTs, not exactly one")
  sent = state[:puts].first.to_s
  # Byte-exact on the wire, not only after a parse: the template must reach
  # Immich as the literal Handlebars string, never as Jinja's rendering of it.
  check(failures, sent.include?(JSON.generate(TEMPLATE)), "the PUT body does not carry the literal template: #{sent}")
  check(failures, state[:config]["storageTemplate"] ==
                  { "enabled" => true, "hashVerificationEnabled" => true, "template" => TEMPLATE },
        "the storage template converged to #{state[:config]['storageTemplate'].inspect}")
  check(failures, state[:config] == converged, "the converged document differs: #{state[:config].inspect}")
end

with_immich(converged) do |port, state|
  stdout, stderr, status = run_settings(port, RECONCILE_TASKS + VERIFY_TASKS)
  check(failures, status.success?, "reconcile of a converged server failed: #{failure_tail(stdout + stderr)}")
  check(failures, state[:puts].empty?, "a converged server was sent #{state[:puts].length} PUTs")
end

[
  ["disabled", { "enabled" => false }],
  ["retemplated in the UI", { "template" => "{{y}}/{{album}}/{{filename}}" }],
  ["hash verification off", { "hashVerificationEnabled" => false }]
].each do |label, drift|
  drifted = converged.merge("storageTemplate" => converged.fetch("storageTemplate").merge(drift))

  with_immich(drifted) do |port, state|
    stdout, stderr, status = run_settings(port, VERIFY_TASKS)
    check(failures, !status.success?, "verify accepted a storage template #{label}")
    check(failures, (stdout + stderr).include?("The managed Immich settings are absent or drifted"),
          "verify refused a storage template #{label} for the wrong reason: #{failure_tail(stdout + stderr)}")
    check(failures, state[:puts].empty?, "verify mutated a storage template #{label}")
  end

  with_immich(drifted) do |port, state|
    stdout, stderr, status = run_settings(port, RECONCILE_TASKS, "--check")
    check(failures, status.success?, "check mode failed on a storage template #{label}: #{failure_tail(stdout + stderr)}")
    check(failures, stdout.include?(PLAN_MARKER), "check mode did not report the repair of a storage template #{label}")
    check(failures, state[:puts].empty?, "check mode sent a PUT for a storage template #{label}")
  end

  with_immich(drifted) do |port, state|
    stdout, stderr, status = run_settings(port, RECONCILE_TASKS + VERIFY_TASKS)
    check(failures, status.success?, "reconcile of a storage template #{label} failed: #{failure_tail(stdout + stderr)}")
    check(failures, state[:puts].length == 1, "a storage template #{label} was sent #{state[:puts].length} PUTs")
    check(failures, state[:config] == converged, "a storage template #{label} was not reverted: #{state[:config].inspect}")
  end
end

report(failures, "Immich managed system configuration fixtures passed", "Immich system configuration failures")
