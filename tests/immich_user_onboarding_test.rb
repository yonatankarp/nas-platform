#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

require_relative "http_fixture_support"

include HttpFixtureSupport

ROOT = File.expand_path("..", __dir__)
TASK_FILE = File.join(ROOT, "roles", "immich", "tasks", "user_onboarding.yml")

def failure_tail(output)
  output.lines.map(&:strip).reject(&:empty?).last(8).join(" | ")
end

def run_onboarding(port, phases)
  variables = {
    "immich_api" => "http://127.0.0.1:#{port}/api",
    "vault_immich_admin_email" => "admin@example.invalid",
    "vault_immich_admin_password" => "admin-password",
    "vault_managed_immich_users" => [
      { "email" => "reader@example.invalid", "password" => "reader-password" }
    ]
  }
  tasks = phases.map do |phase|
    {
      "name" => "Exercise Immich user onboarding #{phase}",
      "ansible.builtin.include_tasks" => TASK_FILE,
      "vars" => { "immich_user_onboarding_phase" => phase }
    }
  end
  run_playbook(tasks, variables, prefix: "nas-platform-immich-onboarding-")
end

def with_immich(accounts, malformed_email: nil, rejected_email: nil, &block)
  requests = []
  with_http_fixture(->(port) { block.call(port, requests) },
                    reason: "Fixture") do |method, target, headers, body|
    parsed = body.empty? ? nil : JSON.parse(body)
    requests << { "method" => method, "target" => target, "headers" => headers, "json" => parsed }

    account = accounts.values.find do |entry|
      headers["authorization"] == "Bearer #{entry.fetch(:token)}"
    end
    status, response = case [method, target]
                       when ["POST", "/api/auth/login"]
                         email = parsed.fetch("email")
                         if email == rejected_email
                           [401, { "message" => "Unauthorized" }]
                         else
                           entry = accounts.fetch(email)
                           [201, {
                             "accessToken" => entry.fetch(:token),
                             "userEmail" => email,
                             "isAdmin" => entry.fetch(:admin),
                             "isOnboarded" => entry.fetch(:onboarded)
                           }]
                         end
                       when ["GET", "/api/users/me/onboarding"]
                         if account.fetch(:email) == malformed_email
                           [200, { "isOnboarded" => false, "unexpected" => true }]
                         else
                           [200, { "isOnboarded" => account.fetch(:onboarded) }]
                         end
                       when ["PUT", "/api/users/me/onboarding"]
                         raise "unexpected onboarding body" unless parsed == { "isOnboarded" => true }

                         account[:onboarded] = true
                         [200, { "isOnboarded" => true }]
                       else
                         [404, { "message" => "not found" }]
                       end
    [status, JSON.generate(response)]
  end
end

def account_fixture(admin_onboarded: false, reader_onboarded: false)
  {
    "admin@example.invalid" => {
      email: "admin@example.invalid", token: "admin-token", admin: true,
      onboarded: admin_onboarded
    },
    "reader@example.invalid" => {
      email: "reader@example.invalid", token: "reader-token", admin: false,
      onboarded: reader_onboarded
    }
  }
end

failures = []

accounts = account_fixture
with_immich(accounts) do |port, requests|
  stdout, stderr, status = run_onboarding(port, %w[reconcile verify])
  failures << "reconcile/verify failed: #{failure_tail(stdout + stderr)}" unless status.success?
  puts = requests.select { |request| request["method"] == "PUT" }
  failures << "false users were not updated exactly once each" unless puts.length == 2
  failures << "configured users did not finish onboarding" unless
    accounts.values.all? { |account| account.fetch(:onboarded) }
end

accounts = account_fixture
with_immich(accounts, malformed_email: "reader@example.invalid") do |port, requests|
  _stdout, _stderr, status = run_onboarding(port, ["reconcile"])
  failures << "malformed global preflight unexpectedly succeeded" if status.success?
  failures << "malformed global preflight reached mutation" if
    requests.any? { |request| request["method"] == "PUT" }
end

accounts = account_fixture
with_immich(accounts, rejected_email: "reader@example.invalid") do |port, requests|
  _stdout, _stderr, status = run_onboarding(port, ["reconcile"])
  failures << "rejected account preflight unexpectedly succeeded" if status.success?
  failures << "rejected account preflight reached mutation" if
    requests.any? { |request| request["method"] == "PUT" }
end

accounts = account_fixture(admin_onboarded: true, reader_onboarded: false)
with_immich(accounts) do |port, requests|
  _stdout, _stderr, status = run_onboarding(port, ["verify"])
  failures << "incomplete read-only verification unexpectedly succeeded" if status.success?
  failures << "read-only verification mutated onboarding" if
    requests.any? { |request| request["method"] == "PUT" }
end

unless failures.empty?
  warn failures.map { |failure| "Immich onboarding test failed: #{failure}" }.join("\n")
  exit 1
end

puts "Immich per-user onboarding reconciliation fixtures passed"
