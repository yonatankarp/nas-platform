#!/usr/bin/env ruby
# frozen_string_literal: true

# roles/dozzle renames its dispatcher in place, proved by running the shipped
# dispatcher tasks against a fixture Dozzle API. The lane only ever starts
# empty, so it creates the dispatcher under its current name and never meets
# one under a former name; this is the only place that path runs before merge.
#
# What matters is the id: every rule points at the dispatcher by id, and the
# hub pushes both to Golem's agent. A rename that created a second dispatcher
# and deleted the first would move every rule, and the unmanaged-dispatcher
# sweep reads a listing taken before the rename, so it must key on the id too.

require "json"
require "yaml"

require_relative "http_fixture_support"
require_relative "policy_support"

include TestScaffold

ROOT = File.expand_path("..", __dir__)
DEFAULTS = YAML.safe_load_file(File.join(ROOT, "roles", "dozzle", "defaults", "main.yml"))
TASK_NAMES = [
  "List Dozzle dispatchers for reconciliation",
  "Resolve safe managed Dozzle dispatcher IDs",
  "Require safe managed Dozzle dispatcher IDs",
  "Refuse duplicate managed Dozzle dispatchers",
  "Resolve managed Dozzle dispatcher reconciliation state",
  "Resolve managed Dozzle dispatcher repair requirement",
  "Report planned managed Dozzle dispatcher creation",
  "Create the managed Dozzle dispatcher",
  "Resolve the managed Dozzle dispatcher",
  "Report planned managed Dozzle dispatcher repair",
  "Repair managed Dozzle dispatcher drift",
  "Report planned unmanaged Dozzle dispatcher removal",
  "Remove unmanaged Dozzle dispatchers"
].freeze

failures = []
all_tasks = YAML.safe_load_file(File.join(ROOT, "roles", "dozzle", "tasks", "main.yml"))
tasks = TASK_NAMES.map { |name| all_tasks.find { |task| task["name"] == name } }
missing = TASK_NAMES.zip(tasks).select { |_name, task| task.nil? }.map(&:first)
abort "Dozzle dispatcher tasks are absent: #{missing.join(', ')}" unless missing.empty?
# no_log hides the refusal a failing row needs to show.
tasks = tasks.map { |task| task.reject { |key, _| key == "no_log" } }

current = DEFAULTS.fetch("dozzle_dispatcher").fetch("name")
former = DEFAULTS.fetch("dozzle_dispatcher_former_names")
check(failures, !former.empty? && !former.include?(current),
      "the defaults must name the dispatcher's former names apart from its current one")

def stored(id, name)
  { "id" => id, "name" => name, "type" => "webhook", "url" => "http://stale.invalid/", "template" => "{}",
    "headers" => {} }
end

# [label, dispatchers on the fixture, check mode, requests wanted beyond the listing]
[
  ["former name", [stored(7, former.first), stored(9, "unmanaged")], false,
   ["PUT /api/notifications/dispatchers/7 #{current}", "DELETE /api/notifications/dispatchers/9"]],
  ["former name under --check", [stored(7, former.first)], true, []],
  ["current name", [stored(7, current)], false, ["PUT /api/notifications/dispatchers/7 #{current}"]],
  ["absent", [], false, ["POST /api/notifications/dispatchers #{current}"]]
].each do |label, dispatchers, check_mode, wanted|
  requests = []
  output = nil
  success = nil
  HttpFixtureSupport.with_http_fixture(lambda do |port|
    variables = DEFAULTS.slice("dozzle_api", "dozzle_dispatcher", "dozzle_dispatcher_former_names").merge(
      "dozzle_port" => port, "dozzle_alert_relay_port" => 8081,
      "vault_dozzle_alert_relay_token" => "fixture-token",
      "dozzle_reconcile_auth" => { "cookies_string" => "jwt=fixture" }
    )
    stdout, stderr, status = HttpFixtureSupport.run_playbook(tasks, variables, *(check_mode ? ["--check"] : []))
    output = stdout + stderr
    success = status.success?
  end) do |method, target, _headers, body|
    next [200, JSON.generate(dispatchers)] if method == "GET"

    name = body.empty? ? "" : " #{JSON.parse(body).fetch('name')}"
    requests << "#{method} #{target}#{name}"
    case method
    when "POST" then [201, JSON.generate(stored(11, current))]
    when "PUT" then [200, body]
    else 204
    end
  end
  check(failures, success, "#{label}: the run failed: #{failure_tail(output)}")
  check(failures, requests == wanted, "#{label}: sent #{requests.inspect}, wanted #{wanted.inspect}")
  check(failures, !check_mode || output.include?("DOZZLE_PLAN_DISPATCHER_REPAIR"),
        "#{label}: check mode did not report the planned rename")
end

report(failures, "Dozzle dispatcher rename policy passed", "Dozzle dispatcher rename failures")
