#!/usr/bin/env ruby
# The runtime half of the Beszel service contract: everything that needs a
# served PocketBase hub, an encrypted vault and the persisted telemetry the
# agents write.
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
require "socket"
require "uri"
require "yaml"
require "timeout"
require File.join(ENV.fetch("PLATFORM_CONTRACT_REPO_DIR"), "tests/contracts/support/beszel_telemetry")

MODE = ARGV.fetch(0)
HUB = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_BESZEL_PORT'), 10)}")
# The address the hub container reaches this program's notification recorder on
# is whatever the deployment was told to use,
# not the loopback address this contract connects to, and it is not a fixed name:
# only Docker Desktop supplies host.docker.internal, so a Linux daemon gets an
# address instead. Follow the precedence inventory/local.yml uses, and fall back
# to the name inventory/mac.yml hardcodes, which the Mac lane relies on because it
# exports neither variable.
CALLBACK_HOST = [ENV["PLATFORM_CALLBACK_HOST"], ENV["PLATFORM_NAS_ADDRESS"]]
                .compact.reject(&:empty?).first || "host.docker.internal"
# What roles/beszel converges, read out of the inspected tree rather than typed
# here. The hand-typed map this replaced drifted from beszel_alerts silently: a
# threshold moved or an alert deleted in the defaults passed the static gate, and
# only a live hub in the beszel lane could notice (#608).
# tests/beszel_contract_test.rb keeps the one literal copy left, as the fixture
# its hub serves, and holds that copy against the same defaults.
MANAGED_ALERTS = YAML.safe_load_file(File.join(ENV.fetch("PLATFORM_CONTRACT_REPO_DIR"), "roles/beszel/defaults/main.yml"))
                     .fetch("beszel_alerts")
                     .to_h { |alert| [alert.fetch("name"), [alert.fetch("value"), alert.fetch("min")]] }.freeze
DECOY_NAME = "00-contract-decoy"
WRONG_OWNER_EMAIL = "wrong-owner-fixture@example.invalid"
DUPLICATE_EVIDENCE = File.join(ENV.fetch("PLATFORM_REPORT_ROOT"), "beszel-duplicate-ids.txt")
# The two budgets this program can spend waiting, and the only two numbers in it
# a caller may need to lower. Both defaults are the deployment's: ninety seconds
# for a real agent to write a 1m telemetry sample, fifteen for the hub's test
# notification to reach the recorder the notify mode listens with. They are environment inputs for the reason
# tests/contracts/seerr-runtime.rb's READY_TIMEOUT_SECONDS is (#319): a caller
# that must reach the refusal these deadlines guard has to sit out the whole
# budget to get there, and tests/beszel_contract_test.rb has one such row per
# deadline. Ninety seconds of that was the floor of both beszel checks in
# tests/validate-policy.sh. Nothing in a deployment sets either name, so the
# beszel integration lane and the Mac proof read the defaults.
TELEMETRY_POLL_TIMEOUT_SECONDS =
  Integer(ENV.fetch("PLATFORM_BESZEL_TELEMETRY_POLL_TIMEOUT_SECONDS", "90"), 10)
NOTIFICATION_POLL_TIMEOUT_SECONDS =
  Integer(ENV.fetch("PLATFORM_BESZEL_NOTIFICATION_POLL_TIMEOUT_SECONDS", "15"), 10)

def fail_contract(message)
  warn "Beszel contract failed: #{message}"
  exit 1
end

# roles/beszel's beszel_notification_url, rendered. The port is read from the
# inspected tree's shared inventory, its one home. The token is encoded the way
# Jinja's urlencode does it: every byte but letters, digits, `_.-~` and `/`
# becomes %XX, so the space in "Bearer " is %20. That rule was measured through
# Ansible, not assumed.
RELAY_PORT = Integer(
  YAML.safe_load_file(File.join(ENV.fetch("PLATFORM_CONTRACT_REPO_DIR"),
                                "inventory/group_vars/all/service_dozzle.yml"))
      .fetch("dozzle_alert_relay_port")
)

def relay_webhook(token)
  header = "Bearer #{token}".b.gsub(%r{[^A-Za-z0-9_.~/-]}n) { |byte| format("%%%02X", byte.ord) }
  "generic://alert-relay:#{RELAY_PORT}/beszel?disabletls=yes&template=json&@Authorization=#{header}"
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

# Reads one request and answers it, for the notify mode's recorder. Copied from
# tests/contracts/dozzle-runtime.rb rather than shared, as every contract carries
# its own: shoutrrr's generic service sends one POST with a Content-Length and a
# text/plain body, and nothing here has to be a general HTTP implementation.
def read_recorded_request(socket)
  request_line = socket.gets
  return nil if request_line.nil?

  headers = {}
  while (line = socket.gets)
    break if line.strip.empty?

    name, value = line.split(":", 2)
    headers[name.to_s.strip.downcase] = value.to_s.strip
  end
  length = Integer(headers.fetch("content-length", "0"), 10)
  body = length.positive? ? socket.read(length).to_s : ""
  socket.write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
  { "method" => request_line.split(" ", 3)[0], "headers" => headers, "body" => body }
rescue StandardError
  nil
end

# What the Dozzle alert relay's /beszel route requires, and the double encoding
# that has to survive to reach it: template=json makes shoutrrr's generic service
# send exactly {"message","title"} as JSON, and the percent-encoded
# @Authorization query key becomes the header after Beszel has decoded and
# re-encoded the whole query to add $title (SendShoutrrrAlert). Proved against a
# real 0.19.0 hub, never read off the source alone.
def relay_envelope?(record)
  body = begin
    JSON.parse(record["body"])
  rescue JSON::ParserError
    nil
  end
  record["headers"]["authorization"] == "Bearer sentinel" &&
    record["headers"]["content-type"].to_s.start_with?("application/json") &&
    body.is_a?(Hash) && body.keys.sort == %w[message title] && body["title"] == "Test Alert"
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
    platform: platform, system: system, timeout_seconds: TELEMETRY_POLL_TIMEOUT_SECONDS,
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
  # Beszel pins the users authRule to verified=true (read against 0.18.7, a
  # dated record; services/beszel/compose.yml carries the pin). Keep the primary
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
  # NOT the URL the role converged, and that is the whole of what this mode can
  # still prove. Beszel's production webhook is Pushover, and no proof that ends
  # at a real Pushover account can run here: it would leave the platform's
  # notification budget at the mercy of a test loop and would need an account
  # this harness has no way to hold. So this mode hands the hub a shoutrrr
  # generic webhook pointing at a recorder in this process and asserts the POST
  # arrives, which demonstrates that the hub's shoutrrr dispatch works end to
  # end -- authentication, the test-notification route, delivery to a real
  # listener. It says nothing about whether the stored Pushover URL is
  # deliverable. The verify mode below is what compares the stored value against
  # the vault; nothing anywhere delivers through it.
  #
  # The recorder is the dozzle contract's, and reachable for the same reason:
  # the integration controller runs with --network host and the Mac lane runs
  # this program on the Mac, so a socket here is a socket on the Docker host.
  # Its port is chosen at runtime because the URL travels in the request body.
  # A fresh listener per run is also why no anti-replay baseline is needed any
  # more: it cannot hold a message from before it existed.
  #
  # The URL form is read from the pinned sources rather than guessed. Beszel
  # 0.19.0 vendors nicholas-fedor/shoutrrr v0.19.0, whose generic service POSTs
  # over https unless `disabletls` is set (generic_config.go: WebhookURL), and
  # returns an error for a dial failure or a status of 400 or more -- which the
  # hub reports as a string in `err` (internal/alerts/alerts_api.go:
  # SendTestNotification). The URL carries template=json and an @Authorization
  # header because that is the form PR-B points Beszel at the alert relay with:
  # the recorder requires the bearer header and the two-key JSON envelope, so
  # this mode proves the transport the relay depends on. The message is matched
  # on Beszel's test text rather than whole, because the hub appends its app URL.
  # A wrong host, port or scheme therefore fails at `err`, and a hub that says
  # it sent without sending fails at the recorder.
  begin
    recorder = TCPServer.new("0.0.0.0", 0)
  rescue SystemCallError => error
    fail_contract("notification recorder could not listen: #{error.class}")
  end
  recorded = Queue.new
  Thread.new do
    loop do
      socket = recorder.accept
      record = read_recorded_request(socket)
      recorded << record if record
      socket.close rescue nil
    end
  end
  notification_url = "generic://#{CALLBACK_HOST}:#{recorder.addr[1]}/beszel-contract?disabletls=yes&template=json&@Authorization=Bearer%20sentinel"
  notification = request("post", endpoint(HUB, "/api/beszel/test-notification"),
                         token: app_auth.fetch("token"), body: { url: notification_url })
  fail_contract("Beszel test notification reported delivery failure") unless notification["err"] == false

  received = []
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + NOTIFICATION_POLL_TIMEOUT_SECONDS
  loop do
    received << recorded.pop until recorded.empty?
    break if received.any? { |record| record["body"].include?("This is a notification from Beszel.") && relay_envelope?(record) }
    fail_contract("Beszel test notification did not reach the contract's recorder") if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
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
  # The shoutrrr URL roles/beszel converges, rebuilt here from the vault's relay
  # token and the relay port in shared inventory rather than read back from
  # anywhere -- the credential direction the whole platform holds to.
  expected_url = relay_webhook(vault.fetch("vault_dozzle_alert_relay_token"))
  notification_settings = settings.fetch("settings")
  notification_settings = JSON.parse(notification_settings) if notification_settings.is_a?(String)
  fail_contract("managed relay webhook differs") unless notification_settings["webhooks"] == [expected_url]

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
