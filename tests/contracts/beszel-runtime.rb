#!/usr/bin/env ruby
# The runtime half of the Beszel service contract: everything that needs a
# served PocketBase hub, a disposable ntfy, an encrypted vault and the
# persisted telemetry the agents write.
#
# usage: beszel-runtime.rb MODE
#
# Every input arrives in the environment tests/contracts/beszel.sh exports,
# PLATFORM_CONTRACT_REPO_DIR included, which is read below to require the
# shared telemetry evaluator out of the INSPECTED tree rather than out of this
# checkout. Run it through that wrapper rather than directly.
require "json"
require "net/http"
require "open3"
require "uri"
require "yaml"
require "timeout"
require File.join(ENV.fetch("PLATFORM_CONTRACT_REPO_DIR"), "tests/contracts/support/beszel_telemetry")

MODE = ARGV.fetch(0)
HUB = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_BESZEL_PORT'), 10)}")
NTFY = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_NTFY_PORT'), 10)}")
# The address Beszel reaches ntfy on is whatever the deployment was told to use,
# not the loopback address this contract connects to, and it is not a fixed name:
# only Docker Desktop supplies host.docker.internal, so a Linux daemon gets an
# address instead. Follow the precedence inventory/local.yml uses, and fall back
# to the name inventory/mac.yml hardcodes, which the Mac lane relies on because it
# exports neither variable.
CALLBACK_HOST = [ENV["PLATFORM_CALLBACK_HOST"], ENV["PLATFORM_NAS_ADDRESS"]]
                .compact.reject(&:empty?).first || "host.docker.internal"
MANAGED_ALERTS = {
  "Status" => [0, 0],
  "CPU" => [90, 10],
  "Memory" => [90, 10],
  "Disk" => [85, 10]
}.freeze
DECOY_NAME = "00-contract-decoy"
WRONG_OWNER_EMAIL = "wrong-owner-fixture@example.invalid"
DUPLICATE_EVIDENCE = File.join(ENV.fetch("PLATFORM_REPORT_ROOT"), "beszel-duplicate-ids.txt")

def fail_contract(message)
  warn "Beszel contract failed: #{message}"
  exit 1
end

vault_yaml, vault_error, status = Open3.capture3(
  "ansible-vault", "view", "--vault-password-file",
  ENV.fetch("PLATFORM_CONTRACT_VAULT_PASSWORD_FILE"),
  ENV.fetch("PLATFORM_CONTRACT_VAULT_FILE")
)
fail_contract("encrypted vault could not be read") unless status.success?
vault = YAML.safe_load(vault_yaml)
vault_yaml.replace("\0" * vault_yaml.bytesize)
vault_error.replace("\0" * vault_error.bytesize)

def request(method, uri, token: nil, basic: nil, body: nil, expected: [200], timeout: nil)
  request = Net::HTTP.const_get(method.capitalize).new(uri)
  request["Authorization"] = "#{token}" if token
  request.basic_auth(*basic) if basic
  if body
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body)
  end
  request_timeout = timeout || 15
  response = Timeout.timeout(request_timeout) do
    Net::HTTP.start(uri.host, uri.port, open_timeout: [request_timeout, 1].min,
                    read_timeout: request_timeout) { |http| http.request(request) }
  end
  fail_contract("#{method.upcase} #{uri.path} returned HTTP #{response.code}") unless expected.include?(response.code.to_i)
  response.body.to_s.empty? ? {} : JSON.parse(response.body)
rescue JSON::ParserError
  fail_contract("#{method.upcase} #{uri.path} returned malformed JSON")
rescue SystemCallError, Timeout::Error => error
  fail_contract("#{method.upcase} #{uri.path} failed: #{error.class}")
end

def request_text(method, uri, basic: nil, expected: [200])
  request = Net::HTTP.const_get(method.capitalize).new(uri)
  request.basic_auth(*basic) if basic
  response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 15) do |http|
    http.request(request)
  end
  fail_contract("#{method.upcase} #{uri.path} returned HTTP #{response.code}") unless expected.include?(response.code.to_i)
  response.body
rescue SystemCallError, Timeout::Error => error
  fail_contract("#{method.upcase} #{uri.path} failed: #{error.class}")
end

def endpoint(base, path)
  URI.join(base.to_s, path)
end

auth = request(
  "post",
  endpoint(HUB, "/api/collections/_superusers/auth-with-password"),
  body: {
    identity: vault.fetch("vault_beszel_superuser_email"),
    password: vault.fetch("vault_beszel_superuser_password")
  }
)
admin_token = auth.fetch("token")

def equality(field, value)
  "#{field} = #{JSON.generate(value)}"
end

def records(collection, token, filter)
  query = URI.encode_www_form(perPage: 500, filter: filter)
  response = request("get", endpoint(HUB, "/api/collections/#{collection}/records?#{query}"), token: token)
  fail_contract("#{collection} filtered identity exceeds one complete page") if response.fetch("totalPages", 0).to_i > 1
  response.fetch("items")
end

def latest_telemetry_record(collection, token, system_id, timeout)
  BeszelTelemetry.fetch_latest_record(
    base_uri: HUB, collection: collection, token: token, system_id: system_id,
    timeout_seconds: timeout
  )
end

def persisted_telemetry(platform, system, token)
  evidence = BeszelTelemetry.poll(
    platform: platform, system: system, timeout_seconds: 90,
    request_timeout_seconds: 3, delay_seconds: 3,
    fetcher: lambda do |collection, timeout|
      latest_telemetry_record(collection, token, system.fetch("id"), timeout)
    end
  )
  unless evidence.ready?
    fail_contract(evidence.safe_failure)
  end
rescue BeszelTelemetry::NonRetryableFetchError => error
  fail_contract(error.message)
end

def exact_record(records, description)
  fail_contract("#{description} is absent") if records.empty?
  if records.length > 1
    fail_contract("duplicate #{description} IDs: #{records.map { |record| record.fetch('id') }.join(',')}")
  end
  records.first
end

users = records("users", admin_token, equality("email", vault.fetch("vault_beszel_app_user_email")))
user = exact_record(users, "managed application user")
user_id = user.fetch("id")
systems = records("systems", admin_token, equality("name", "ASUSTOR-AS6704T"))
managed_systems = systems.select { |record| Array(record["users"]).include?(user_id) }
wrong_owner_systems = systems.reject { |record| Array(record["users"]).include?(user_id) }
unless wrong_owner_systems.empty? || MODE == "remove-duplicate"
  fail_contract("same-name wrong-owner system IDs: #{wrong_owner_systems.map { |record| record.fetch('id') }.join(',')}")
end

case MODE
when "drift"
  managed_system = exact_record(managed_systems, "managed system")
  # Beszel 0.18.7 pins the users authRule to verified=true. Keep the primary
  # identity authentication-compatible so convergence can prove its preserved
  # password before repairing the independently mutable role.
  request("patch", endpoint(HUB, "/api/collections/users/records/#{user_id}"), token: admin_token,
          body: { role: "user" })

  token = exact_record(records("universal_tokens", admin_token, equality("user", user_id)),
                       "managed universal token")
  request("patch", endpoint(HUB, "/api/collections/universal_tokens/records/#{token.fetch('id')}"),
          token: admin_token, body: { token: "11111111-1111-4111-a111-111111111111" })

  settings = exact_record(records("user_settings", admin_token, equality("user", user_id)),
                          "managed user settings")
  request("patch", endpoint(HUB, "/api/collections/user_settings/records/#{settings.fetch('id')}"),
          token: admin_token,
          body: { settings: { webhooks: ["https://sentinel-user:sentinel-password@example.invalid/hook?api_key=sentinel-query-key"] } })

  cpu_filter = [equality("user", user_id), equality("system", managed_system.fetch("id")),
                equality("name", "CPU")].join(" && ")
  cpu = exact_record(records("alerts", admin_token, cpu_filter), "managed CPU alert")
  request("patch", endpoint(HUB, "/api/collections/alerts/records/#{cpu.fetch('id')}"),
          token: admin_token, body: { value: 1, min: 1 })

  decoy_systems = records("systems", admin_token, equality("name", DECOY_NAME))
  unless decoy_systems.any?
    request("post", endpoint(HUB, "/api/collections/systems/records"), token: admin_token,
            body: { name: DECOY_NAME, host: "127.0.0.1", port: 45876, status: "paused", users: [user_id] })
  end
when "drift-verify"
  managed_system = exact_record(managed_systems, "managed system")
  fail_contract("managed application user drift changed") unless user["role"] == "user" && user["verified"] == true
  token = exact_record(records("universal_tokens", admin_token, equality("user", user_id)),
                       "managed universal token")
  fail_contract("managed universal token drift changed") unless token["token"] == "11111111-1111-4111-a111-111111111111"
  settings = exact_record(records("user_settings", admin_token, equality("user", user_id)),
                          "managed user settings")
  drift_settings = settings.fetch("settings")
  drift_settings = JSON.parse(drift_settings) if drift_settings.is_a?(String)
  expected_drift_webhook = "https://sentinel-user:sentinel-password@example.invalid/hook?api_key=sentinel-query-key"
  fail_contract("managed webhook drift changed") unless drift_settings["webhooks"] == [expected_drift_webhook]
  cpu_filter = [equality("user", user_id), equality("system", managed_system.fetch("id")),
                equality("name", "CPU")].join(" && ")
  cpu = exact_record(records("alerts", admin_token, cpu_filter), "managed CPU alert")
  fail_contract("managed CPU alert drift changed") unless cpu["value"] == 1 && cpu["min"] == 1
  fail_contract("decoy system drift changed") unless records("systems", admin_token, equality("name", DECOY_NAME)).length == 1
when "duplicate"
  managed_system = exact_record(managed_systems, "managed system")
  duplicate = request("post", endpoint(HUB, "/api/collections/systems/records"), token: admin_token,
                      body: { name: managed_system.fetch("name"), host: "127.0.0.1", port: 45877,
                              status: "paused", users: [user_id] })
  File.write(
    DUPLICATE_EVIDENCE,
    [managed_system.fetch("id"), duplicate.fetch("id")].join("\n") + "\n",
    mode: "w",
    perm: 0o600
  )
when "wrong-owner"
  managed_system = exact_record(managed_systems, "managed system")
  wrong_owner_users = records("users", admin_token, equality("email", WRONG_OWNER_EMAIL))
  wrong_owner_user = if wrong_owner_users.empty?
                       request("post", endpoint(HUB, "/api/collections/users/records"), token: admin_token,
                               body: { email: WRONG_OWNER_EMAIL,
                                       password: "Wrong-owner-fixture-password-123!",
                                       passwordConfirm: "Wrong-owner-fixture-password-123!",
                                       verified: true, role: "user" })
                     else
                       exact_record(wrong_owner_users, "wrong-owner fixture user")
                     end
  wrong_owner = request("post", endpoint(HUB, "/api/collections/systems/records"), token: admin_token,
                        body: { name: managed_system.fetch("name"), host: "127.0.0.1", port: 45878,
                                status: "paused", users: [wrong_owner_user.fetch("id")] })
  File.write(
    DUPLICATE_EVIDENCE,
    [managed_system.fetch("id"), wrong_owner.fetch("id")].join("\n") + "\n",
    mode: "w",
    perm: 0o600
  )
when "remove-duplicate"
  if File.file?(DUPLICATE_EVIDENCE)
    ids = File.readlines(DUPLICATE_EVIDENCE, chomp: true)
    keep_id = ids.first
    systems.reject { |record| record.fetch("id") == keep_id }.each do |record|
      request("delete", endpoint(HUB, "/api/collections/systems/records/#{record.fetch('id')}"),
              token: admin_token, expected: [204])
    end
    records("users", admin_token, equality("email", WRONG_OWNER_EMAIL)).each do |record|
      request("delete", endpoint(HUB, "/api/collections/users/records/#{record.fetch('id')}"),
              token: admin_token, expected: [204])
    end
    File.unlink(DUPLICATE_EVIDENCE)
  end
when "notify"
  app_auth = request(
    "post", endpoint(HUB, "/api/collections/users/auth-with-password"),
    body: { identity: vault.fetch("vault_beszel_app_user_email"),
            password: vault.fetch("vault_beszel_app_user_password") }
  )
  expected_url = "ntfy://:#{vault.fetch('vault_ntfy_beszel_token')}@#{CALLBACK_HOST}:#{NTFY.port}/nas-critical?scheme=http"
  ntfy_auth = [vault.fetch("vault_ntfy_admin_user"), vault.fetch("vault_ntfy_admin_password")]
  # The anti-replay poll below anchors on an existing message. It used to get one by
  # accident: the ntfy role publisher verification left "provisioning verified for
  # beszel" in this topic history. That publish now refuses caching so a healthy
  # converge leaves nas-critical empty, which left this contract with no anchor. The
  # baseline is established here instead of depending on another role side effect.
  request("post", endpoint(NTFY, "/"), basic: ntfy_auth,
          body: { topic: "nas-critical", message: "beszel contract anti-replay baseline" })
  latest = request_text("get", endpoint(NTFY, "/nas-critical/json?poll=1&since=latest"), basic: ntfy_auth)
  latest_messages = latest.lines.filter_map do |line|
    JSON.parse(line)
  rescue JSON::ParserError
    nil
  end
  baseline_id = latest_messages.reverse.find { |message| message["event"] == "message" }&.fetch("id", nil)
  fail_contract("disposable ntfy has no baseline message for anti-replay polling") unless baseline_id

  notification = request("post", endpoint(HUB, "/api/beszel/test-notification"),
                         token: app_auth.fetch("token"), body: { url: expected_url })
  fail_contract("Beszel test notification reported delivery failure") unless notification["err"] == false

  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
  loop do
    query = URI.encode_www_form(poll: 1, since: baseline_id)
    response = request_text("get", endpoint(NTFY, "/nas-critical/json?#{query}"),
                            basic: ntfy_auth)
    messages = response.lines.filter_map do |line|
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end
    break if messages.any? do |message|
      message["id"] != baseline_id && message["message"] == "This is a notification from Beszel."
    end
    fail_contract("Beszel test notification did not reach disposable ntfy") if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 1
  end
else
  request(
    "post", endpoint(HUB, "/api/collections/users/auth-with-password"),
    body: { identity: vault.fetch("vault_beszel_app_user_email"),
            password: vault.fetch("vault_beszel_app_user_password") }
  )
  fail_contract("managed user is not verified admin") unless user["verified"] == true && user["role"] == "admin"
  token = exact_record(records("universal_tokens", admin_token, equality("user", user_id)),
                       "managed universal token")
  fail_contract("managed universal token differs from encrypted vault") unless token["token"] == vault.fetch("vault_beszel_universal_token")

  settings = exact_record(records("user_settings", admin_token, equality("user", user_id)),
                          "managed user settings")
  expected_url = "ntfy://:#{vault.fetch('vault_ntfy_beszel_token')}@#{CALLBACK_HOST}:#{NTFY.port}/nas-critical?scheme=http"
  notification_settings = settings.fetch("settings")
  notification_settings = JSON.parse(notification_settings) if notification_settings.is_a?(String)
  fail_contract("managed ntfy webhook differs") unless notification_settings["webhooks"] == [expected_url]

  managed_system = exact_record(managed_systems, "managed system")
  persisted_telemetry(ENV.fetch("PLATFORM_KIND"), managed_system, admin_token)
  MANAGED_ALERTS.each do |name, (value, duration)|
    alert_filter = [equality("user", user_id), equality("system", managed_system.fetch("id")),
                    equality("name", name)].join(" && ")
    alert = exact_record(records("alerts", admin_token, alert_filter), "managed #{name} alert")
    fail_contract("managed #{name} alert differs") unless alert["value"] == value && alert["min"] == duration
  end
  records("systems", admin_token, equality("name", DECOY_NAME)).each do |decoy|
    MANAGED_ALERTS.each_key do |name|
      decoy_filter = [equality("user", user_id), equality("system", decoy.fetch("id")),
                      equality("name", name)].join(" && ")
      fail_contract("managed alerts were attached to the decoy system") unless records("alerts", admin_token, decoy_filter).empty?
    end
  end
end
