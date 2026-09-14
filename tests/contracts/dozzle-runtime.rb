#!/usr/bin/env ruby
# The live half of the Dozzle service contract: it talks to the deployed Dozzle
# notification API, to the private alert relay through it, and to the Pushover
# recorder the relay publishes at in a lane, and it owns every fixture mode the
# integration lane and the Mac drift hooks dispatch through.
#
# Reads the encrypted vault itself and overwrites the plaintext in place, so
# nothing it holds reaches a diagnostic, an artifact or the environment. The
# artifacts it does write under PLATFORM_REPORT_ROOT are opaque API identifiers
# at mode 0600, filtered through SAFE_ID first.
require "json"
require "net/http"
require "open3"
require "securerandom"
require "socket"
require "timeout"
require "uri"
require "yaml"

MODE = ARGV.fetch(0)
DOZZLE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_DOZZLE_PORT'), 10)}")
# The address Dozzle dispatches to is whatever the deployment was told to use,
# not the loopback address this contract connects to, and it is not a fixed name:
# only Docker Desktop supplies host.docker.internal. Follow the precedence
# inventory/local.yml uses, and fall back to the name inventory/mac.yml hardcodes,
# which the Mac lane relies on because it exports neither variable.
CALLBACK_HOST = [ENV["PLATFORM_CALLBACK_HOST"], ENV["PLATFORM_NAS_ADDRESS"]]
                .compact.reject(&:empty?).first || "host.docker.internal"
REPORT_ROOT = ENV.fetch("PLATFORM_REPORT_ROOT")
# The dispatcher URL Dozzle reports back is the rendered form of the role
# default, so build the expectation from the one place the listener port is
# declared instead of repeating the number in this contract.
RELAY_ALERTS_URL = "http://alert-relay:#{Integer(
  YAML.safe_load_file(ENV.fetch('PLATFORM_CONTRACT_DOZZLE_DEFAULTS'))
      .fetch('dozzle_alert_relay_port')
)}/alerts".freeze
SAFE_ID = /\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/
ALERTS = {
  "OOM" => ['name == "oom"', 300],
  "Unexpected exit" => ['name == "die" && !(attributes["exitCode"] in ["0", "130", "143"])', 300],
  "Unhealthy" => ['name == "health_status" && attributes["healthStatus"] == "unhealthy"', 0],
  "Recovery" => ['name == "health_status" && attributes["healthStatus"] == "healthy"', 0]
}.freeze

def fail_contract(message)
  warn "Dozzle contract failed: #{message}"
  exit 1
end

# The throwaway fixtures below run `/bin/sh` under the alert relay's Alpine
# Python image, chosen only because a lane that converged Dozzle has already
# pulled it. Restating the pin here would make that false the moment the relay's
# image is bumped -- and Renovate does not read this tree, so nothing would say
# so. Read the one pin the deployment declares instead. The prefix is the one
# tests/contracts/dozzle-stack.rb requires of the relay, so the match cannot
# land on the Dozzle or socket-proxy image in the same file.
def deployed_fixture_image
  path = ENV.fetch("PLATFORM_CONTRACT_DOZZLE_COMPOSE")
  fail_contract("services/dozzle/compose.yml is unavailable") unless File.file?(path)
  pin = File.read(path)[%r{^\s*image:\s*(docker\.io/library/python:\S+@sha256:[0-9a-f]{64})\s*$}, 1]
  fail_contract("services/dozzle/compose.yml declares no pinned alert relay image") unless pin
  pin
end

def safe_id(value)
  id = value.to_s
  fail_contract("API returned an unsafe identifier") unless id.match?(SAFE_ID)
  id
end

def artifact_path(name)
  fail_contract("contract report root is unavailable") unless
    File.directory?(REPORT_ROOT) && !File.symlink?(REPORT_ROOT)
  File.join(REPORT_ROOT, "dozzle-#{name}.txt")
end

def write_artifact(name, values)
  path = artifact_path(name)
  fail_contract("refusing to replace contract artifact") if File.exist?(path) || File.symlink?(path)
  body = Array(values).map { |value| safe_id(value) }.join("\n") + "\n"
  File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(body) }
end

def read_artifact(name)
  path = artifact_path(name)
  fail_contract("contract artifact is unavailable") unless File.file?(path) && !File.symlink?(path)
  values = File.readlines(path, chomp: true)
  fail_contract("contract artifact is empty") if values.empty?
  values.map { |value| safe_id(value) }
end

def remove_artifact(name)
  path = artifact_path(name)
  fail_contract("contract artifact is unavailable") unless File.file?(path) && !File.symlink?(path)
  File.unlink(path)
end

def artifact_available?(name)
  path = artifact_path(name)
  File.file?(path) && !File.symlink?(path)
end

def canonicalize(value)
  case value
  when Hash
    value.keys.sort.to_h { |key| [key, canonicalize(value.fetch(key))] }
  when Array
    value.map { |entry| canonicalize(entry) }
  else
    value
  end
end

def notification_state(dispatchers, rules)
  [dispatchers, rules].flatten.each { |entry| safe_id(entry.fetch("id")) }
  JSON.generate(canonicalize({
    "dispatchers" => dispatchers.sort_by { |entry| safe_id(entry.fetch("id")) },
    "rules" => rules.sort_by { |entry| safe_id(entry.fetch("id")) }
  }))
end

def write_state_artifact(name, dispatchers, rules)
  path = artifact_path(name)
  fail_contract("refusing to replace contract artifact") if File.exist?(path) || File.symlink?(path)
  state = notification_state(dispatchers, rules)
  File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(state) }
end

def assert_state_artifact(name, dispatchers, rules)
  path = artifact_path(name)
  fail_contract("contract state artifact is unavailable") unless File.file?(path) && !File.symlink?(path)
  fail_contract("check mode mutated API state bytes") unless
    File.binread(path) == notification_state(dispatchers, rules)
end

def require_desired_fixture_state(dispatchers, rules)
  fail_contract("check-mode fixture requires exact managed identities") unless
    dispatchers.length == 1 && dispatchers.fetch(0).fetch("name") == "ntfy nas-critical" &&
    rules.map { |entry| entry.fetch("name") }.sort == ALERTS.keys.sort
end

def assert_output_ids(artifact, output_path, diagnostic_prefix)
  fail_contract("expected-failure output path is absent") unless output_path
  fail_contract("expected-failure output is unsafe") unless
    File.file?(output_path) && !File.symlink?(output_path)
  output = File.read(output_path)
  expected = "#{diagnostic_prefix}: #{read_artifact(artifact).join(', ')}"
  fail_contract("expected-failure output omitted the safe-ID diagnostic") unless output.include?(expected)
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

def endpoint(base, path)
  URI.join(base.to_s, path)
end

def request(method, uri, cookie: nil, basic: nil, bearer: nil, body: nil, form: nil, expected: [200])
  request = Net::HTTP.const_get(method.capitalize).new(uri)
  request["Cookie"] = cookie if cookie
  request.basic_auth(*basic) if basic
  request["Authorization"] = "Bearer #{bearer}" if bearer
  if body
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body)
  elsif form
    request.set_form_data(form)
  end
  response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 15) do |http|
    http.request(request)
  end
  fail_contract("#{method.upcase} #{uri.path} returned HTTP #{response.code}") unless expected.include?(response.code.to_i)
  parsed = if response.body.to_s.empty? || !response["Content-Type"].to_s.start_with?("application/json")
             nil
           else
             JSON.parse(response.body)
           end
  [response, parsed]
rescue JSON::ParserError
  fail_contract("#{method.upcase} #{uri.path} returned malformed JSON")
rescue SystemCallError, Timeout::Error => error
  fail_contract("#{method.upcase} #{uri.path} failed: #{error.class}")
end

# --- the Pushover stand-in -----------------------------------------------
#
# The relay publishes to Pushover since #558, and no proof that ends at a real
# Pushover account can run in a lane: the messages reach somebody's phone and
# the API has nothing to read them back from. So the lane redirects
# dozzle_pushover_api_url at this recorder and the notify mode asserts the form
# the relay POSTed -- which keeps every property the earlier readback was proving
# (the exact presentation, exactly one recovery, no false recovery on a
# startup-healthy container, and no event envelope leaking into message text)
# rather than trading them for a transport change.
#
# A listener in this process rather than a container, and that works because
# both lanes put this program on the Docker daemon's own network. The
# integration harness runs its controller with --network host, and the Mac lane
# runs this program on the Mac itself, so in both a socket opened here is a
# socket on the host and a service container reaches it at CALLBACK_HOST -- the
# same path the relay used to reach its earlier disposable server.
PUSHOVER_RECORDER_PORT = Integer(ENV.fetch("PLATFORM_DOZZLE_PUSHOVER_PORT"), 10)
PUSHOVER_RECORDER_URL =
  "http://#{CALLBACK_HOST}:#{PUSHOVER_RECORDER_PORT}/1/messages.json".freeze

# Reads one request and answers it. Deliberately minimal rather than a server
# library: the relay sends a POST with a Content-Length and a urlencoded body,
# and nothing here has to be a general HTTP implementation.
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
  {
    "method" => request_line.split(" ", 3)[0],
    "path" => request_line.split(" ", 3)[1],
    "content_type" => headers["content-type"],
    "authorization" => headers["authorization"],
    "form" => URI.decode_www_form(body).to_h
  }
rescue StandardError
  nil
end

# Every captured form carries the Pushover application token and user key, which
# are the household's real credentials on the NAS. They are dropped at the point
# of capture rather than at the point of printing, so no later diagnostic can
# reach them: what the assertions need is that they were present and correct,
# and that is recorded as a verdict rather than as the value.
def redact_credentials(captured, token, user_key)
  form = captured.fetch("form")
  captured.merge(
    "credentials_ok" => form["token"] == token && form["user"] == user_key,
    "form" => form.reject { |name, _value| %w[token user].include?(name) }
  )
end

def with_pushover_recorder(token, user_key)
  begin
    server = TCPServer.new("0.0.0.0", PUSHOVER_RECORDER_PORT)
  rescue SystemCallError => error
    fail_contract("Pushover recorder could not listen on #{PUSHOVER_RECORDER_PORT}: #{error.class}")
  end
  captured = []
  guard = Mutex.new
  running = true
  worker = Thread.new do
    while running
      begin
        socket = server.accept
      rescue IOError, Errno::EBADF
        break
      end
      record = read_recorded_request(socket)
      guard.synchronize { captured << redact_credentials(record, token, user_key) } if record
      socket.close rescue nil
    end
  end
  begin
    yield(-> { guard.synchronize { captured.dup } })
  ensure
    running = false
    server.close rescue nil
    worker.join(5)
  end
end

def wait_for_pushover(reader, diagnostic, timeout: 40)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  loop do
    messages = reader.call
    match = yield messages
    return [match, messages] if match
    fail_contract(diagnostic) if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 2
  end
end

request("get", endpoint(DOZZLE, "/api/notifications/rules"), expected: [401])
login, = request(
  "post", endpoint(DOZZLE, "/api/token"),
  form: { username: vault.fetch("vault_dozzle_admin_username"),
          password: vault.fetch("vault_dozzle_admin_password") }
)
cookie = login.get_fields("set-cookie")&.map { |value| value.split(";", 2).first }&.join("; ")
fail_contract("vault credential did not receive an authentication cookie") if cookie.to_s.empty?
request(
  "post", endpoint(DOZZLE, "/api/token"),
  form: { username: vault.fetch("vault_dozzle_admin_username"), password: "contract-wrong-password" },
  expected: [401]
)

dispatchers = request("get", endpoint(DOZZLE, "/api/notifications/dispatchers"), cookie: cookie).last
rules = request("get", endpoint(DOZZLE, "/api/notifications/rules"), cookie: cookie).last

case MODE
when "duplicate-dispatcher-create"
  managed = dispatchers.select { |entry| entry["name"] == "ntfy nas-critical" }
  fail_contract("dispatcher duplicate fixture requires one managed identity") unless managed.length == 1
  _response, created = request(
    "post", endpoint(DOZZLE, "/api/notifications/dispatchers"), cookie: cookie,
    body: { name: "ntfy nas-critical", type: "webhook",
            url: "https://example.invalid/dozzle-duplicate", template: "{}", headers: {} },
    expected: [201]
  )
  created_id = safe_id(created.fetch("id"))
  current = request("get", endpoint(DOZZLE, "/api/notifications/dispatchers"), cookie: cookie).last
  matching_ids = current.select { |entry| entry["name"] == "ntfy nas-critical" }
                        .map { |entry| safe_id(entry.fetch("id")) }.sort
  fail_contract("dispatcher duplicate fixture was not created") unless matching_ids.length == 2 &&
    matching_ids.include?(created_id)
  write_artifact("duplicate-dispatcher-created-id", created_id)
  write_artifact("duplicate-dispatcher-matching-ids", matching_ids)
  exit 0
when "duplicate-dispatcher-verify"
  matching_ids = dispatchers.select { |entry| entry["name"] == "ntfy nas-critical" }
                            .map { |entry| safe_id(entry.fetch("id")) }.sort
  fail_contract("dispatcher duplicate fixture changed") unless
    matching_ids == read_artifact("duplicate-dispatcher-matching-ids").sort
  exit 0
when "duplicate-dispatcher-assert-output"
  assert_output_ids(
    "duplicate-dispatcher-matching-ids", ARGV[1],
    "Managed Dozzle dispatcher identity is duplicated at safe IDs"
  )
  exit 0
when "duplicate-dispatcher-cleanup"
  created_id = read_artifact("duplicate-dispatcher-created-id").fetch(0)
  request(
    "delete", endpoint(DOZZLE, "/api/notifications/dispatchers/#{created_id}"),
    cookie: cookie, expected: [204]
  )
  current = request("get", endpoint(DOZZLE, "/api/notifications/dispatchers"), cookie: cookie).last
  remaining_ids = current.select { |entry| entry["name"] == "ntfy nas-critical" }
                         .map { |entry| safe_id(entry.fetch("id")) }
  fail_contract("dispatcher duplicate cleanup did not preserve exactly the managed original") unless
    remaining_ids.length == 1 && !remaining_ids.include?(created_id)
  remove_artifact("duplicate-dispatcher-created-id")
  remove_artifact("duplicate-dispatcher-matching-ids")
  exit 0
when "duplicate-rule-create"
  managed_dispatchers = dispatchers.select { |entry| entry["name"] == "ntfy nas-critical" }
  managed_rules = rules.select { |entry| entry["name"] == "OOM" }
  fail_contract("rule duplicate fixture requires exact managed identities") unless
    managed_dispatchers.length == 1 && managed_rules.length == 1
  dispatcher_id = managed_dispatchers.fetch(0).fetch("id")
  safe_id(dispatcher_id)
  _response, created = request(
    "post", endpoint(DOZZLE, "/api/notifications/rules"), cookie: cookie,
    body: { name: "OOM", enabled: true, dispatcherId: dispatcher_id,
            containerExpression: "true", logExpression: "",
            eventExpression: 'name == "oom"', cooldown: 300 },
    expected: [201]
  )
  created_id = safe_id(created.fetch("id"))
  current = request("get", endpoint(DOZZLE, "/api/notifications/rules"), cookie: cookie).last
  matching_ids = current.select { |entry| entry["name"] == "OOM" }
                        .map { |entry| safe_id(entry.fetch("id")) }.sort
  fail_contract("rule duplicate fixture was not created") unless matching_ids.length == 2 &&
    matching_ids.include?(created_id)
  write_artifact("duplicate-rule-created-id", created_id)
  write_artifact("duplicate-rule-matching-ids", matching_ids)
  exit 0
when "duplicate-rule-verify"
  matching_ids = rules.select { |entry| entry["name"] == "OOM" }
                      .map { |entry| safe_id(entry.fetch("id")) }.sort
  fail_contract("rule duplicate fixture changed") unless
    matching_ids == read_artifact("duplicate-rule-matching-ids").sort
  exit 0
when "duplicate-rule-assert-output"
  assert_output_ids(
    "duplicate-rule-matching-ids", ARGV[1],
    "Managed Dozzle alert rule identity OOM is duplicated at safe IDs"
  )
  exit 0
when "duplicate-rule-cleanup"
  created_id = read_artifact("duplicate-rule-created-id").fetch(0)
  request(
    "delete", endpoint(DOZZLE, "/api/notifications/rules/#{created_id}"),
    cookie: cookie, expected: [204]
  )
  current = request("get", endpoint(DOZZLE, "/api/notifications/rules"), cookie: cookie).last
  remaining_ids = current.select { |entry| entry["name"] == "OOM" }
                         .map { |entry| safe_id(entry.fetch("id")) }
  fail_contract("rule duplicate cleanup did not preserve exactly the managed original") unless
    remaining_ids.length == 1 && !remaining_ids.include?(created_id)
  remove_artifact("duplicate-rule-created-id")
  remove_artifact("duplicate-rule-matching-ids")
  exit 0
when "surplus-create"
  fail_contract("surplus fixture requires exact managed state") unless
    dispatchers.length == 1 && dispatchers.fetch(0).fetch("name") == "ntfy nas-critical" &&
    rules.map { |entry| entry.fetch("name") }.sort == ALERTS.keys.sort
  _response, created_dispatcher = request(
    "post", endpoint(DOZZLE, "/api/notifications/dispatchers"), cookie: cookie,
    body: { name: "Contract surplus dispatcher", type: "webhook",
            url: "https://example.invalid/dozzle-surplus", template: "{}", headers: {} },
    expected: [201]
  )
  dispatcher_id = created_dispatcher.fetch("id")
  write_artifact("surplus-dispatcher-id", safe_id(dispatcher_id))
  _response, created_rule = request(
    "post", endpoint(DOZZLE, "/api/notifications/rules"), cookie: cookie,
    body: { name: "Contract surplus rule", enabled: true, dispatcherId: dispatcher_id,
            containerExpression: "true", logExpression: "",
            eventExpression: 'name == "oom"', cooldown: 0 },
    expected: [201]
  )
  write_artifact("surplus-rule-id", safe_id(created_rule.fetch("id")))
  exit 0
when "surplus-verify"
  dispatcher_id = read_artifact("surplus-dispatcher-id").fetch(0)
  rule_id = read_artifact("surplus-rule-id").fetch(0)
  fail_contract("surplus dispatcher fixture is absent") unless
    dispatchers.any? { |entry| safe_id(entry.fetch("id")) == dispatcher_id }
  fail_contract("surplus rule fixture is absent") unless
    rules.any? { |entry| safe_id(entry.fetch("id")) == rule_id }
  exit 0
when "surplus-removed"
  dispatcher_id = read_artifact("surplus-dispatcher-id").fetch(0)
  rule_id = read_artifact("surplus-rule-id").fetch(0)
  fail_contract("surplus dispatcher was not removed") if
    dispatchers.any? { |entry| safe_id(entry.fetch("id")) == dispatcher_id }
  fail_contract("surplus rule was not removed") if
    rules.any? { |entry| safe_id(entry.fetch("id")) == rule_id }
  remove_artifact("surplus-rule-id")
  remove_artifact("surplus-dispatcher-id")
  exit 0
when "surplus-cleanup"
  if artifact_available?("surplus-rule-id")
    rule_id = read_artifact("surplus-rule-id").fetch(0)
    if rules.any? { |entry| safe_id(entry.fetch("id")) == rule_id }
      request("delete", endpoint(DOZZLE, "/api/notifications/rules/#{rule_id}"),
              cookie: cookie, expected: [204])
    end
    remove_artifact("surplus-rule-id")
  end
  if artifact_available?("surplus-dispatcher-id")
    dispatcher_id = read_artifact("surplus-dispatcher-id").fetch(0)
    current = request("get", endpoint(DOZZLE, "/api/notifications/dispatchers"), cookie: cookie).last
    if current.any? { |entry| safe_id(entry.fetch("id")) == dispatcher_id }
      request("delete", endpoint(DOZZLE, "/api/notifications/dispatchers/#{dispatcher_id}"),
              cookie: cookie, expected: [204])
    end
    remove_artifact("surplus-dispatcher-id")
  end
  exit 0
when "check-mixed-create"
  require_desired_fixture_state(dispatchers, rules)
  dispatcher = dispatchers.fetch(0)
  request(
    "put", endpoint(DOZZLE, "/api/notifications/dispatchers/#{dispatcher.fetch('id')}"), cookie: cookie,
    body: { name: dispatcher.fetch("name"), type: "webhook",
            url: "https://example.invalid/check-mixed", template: "{}", headers: {} }
  )
  oom = rules.find { |rule| rule["name"] == "OOM" }
  request(
    "put", endpoint(DOZZLE, "/api/notifications/rules/#{oom.fetch('id')}"), cookie: cookie,
    body: { name: "OOM", enabled: false, dispatcherId: dispatcher.fetch("id"),
            containerExpression: "false", logExpression: "",
            eventExpression: 'name == "start"', cooldown: 1 }
  )
  request(
    "patch", endpoint(DOZZLE, "/api/notifications/rules/#{oom.fetch('id')}"), cookie: cookie,
    body: { enabled: false }
  )
  recovery = rules.find { |rule| rule["name"] == "Recovery" }
  request("delete", endpoint(DOZZLE, "/api/notifications/rules/#{recovery.fetch('id')}"),
          cookie: cookie, expected: [204])
  _response, surplus_dispatcher = request(
    "post", endpoint(DOZZLE, "/api/notifications/dispatchers"), cookie: cookie,
    body: { name: "Contract check-mixed dispatcher", type: "webhook",
            url: "https://example.invalid/check-mixed-surplus", template: "{}", headers: {} },
    expected: [201]
  )
  surplus_dispatcher_id = surplus_dispatcher.fetch("id")
  write_artifact("check-mixed-surplus-dispatcher-id", safe_id(surplus_dispatcher_id))
  _response, surplus_rule = request(
    "post", endpoint(DOZZLE, "/api/notifications/rules"), cookie: cookie,
    body: { name: "Contract check-mixed rule", enabled: true,
            dispatcherId: surplus_dispatcher_id, containerExpression: "true",
            logExpression: "", eventExpression: 'name == "oom"', cooldown: 0 },
    expected: [201]
  )
  write_artifact("check-mixed-surplus-rule-id", safe_id(surplus_rule.fetch("id")))
  current_dispatchers = request("get", endpoint(DOZZLE, "/api/notifications/dispatchers"), cookie: cookie).last
  current_rules = request("get", endpoint(DOZZLE, "/api/notifications/rules"), cookie: cookie).last
  write_state_artifact("check-mixed-state", current_dispatchers, current_rules)
  exit 0
when "check-mixed-unchanged"
  assert_state_artifact("check-mixed-state", dispatchers, rules)
  exit 0
when "check-mixed-cleanup"
  surplus_dispatcher_id = read_artifact("check-mixed-surplus-dispatcher-id").fetch(0)
  surplus_rule_id = read_artifact("check-mixed-surplus-rule-id").fetch(0)
  fail_contract("check-mixed surplus dispatcher remains") if
    dispatchers.any? { |entry| safe_id(entry.fetch("id")) == surplus_dispatcher_id }
  fail_contract("check-mixed surplus rule remains") if
    rules.any? { |entry| safe_id(entry.fetch("id")) == surplus_rule_id }
  remove_artifact("check-mixed-state")
  remove_artifact("check-mixed-surplus-rule-id")
  remove_artifact("check-mixed-surplus-dispatcher-id")
  exit 0
when "check-mixed-recover"
  if artifact_available?("check-mixed-surplus-rule-id")
    rule_id = read_artifact("check-mixed-surplus-rule-id").fetch(0)
    if rules.any? { |entry| safe_id(entry.fetch("id")) == rule_id }
      request("delete", endpoint(DOZZLE, "/api/notifications/rules/#{rule_id}"),
              cookie: cookie, expected: [204])
    end
    remove_artifact("check-mixed-surplus-rule-id")
  end
  if artifact_available?("check-mixed-surplus-dispatcher-id")
    dispatcher_id = read_artifact("check-mixed-surplus-dispatcher-id").fetch(0)
    current = request("get", endpoint(DOZZLE, "/api/notifications/dispatchers"), cookie: cookie).last
    if current.any? { |entry| safe_id(entry.fetch("id")) == dispatcher_id }
      request("delete", endpoint(DOZZLE, "/api/notifications/dispatchers/#{dispatcher_id}"),
              cookie: cookie, expected: [204])
    end
    remove_artifact("check-mixed-surplus-dispatcher-id")
  end
  remove_artifact("check-mixed-state") if artifact_available?("check-mixed-state")
  exit 0
when "check-missing-create"
  require_desired_fixture_state(dispatchers, rules)
  rules.each do |rule|
    request("delete", endpoint(DOZZLE, "/api/notifications/rules/#{rule.fetch('id')}"),
            cookie: cookie, expected: [204])
  end
  request("delete", endpoint(DOZZLE, "/api/notifications/dispatchers/#{dispatchers.fetch(0).fetch('id')}"),
          cookie: cookie, expected: [204])
  current_dispatchers = request("get", endpoint(DOZZLE, "/api/notifications/dispatchers"), cookie: cookie).last
  current_rules = request("get", endpoint(DOZZLE, "/api/notifications/rules"), cookie: cookie).last
  write_state_artifact("check-missing-state", current_dispatchers, current_rules)
  exit 0
when "check-missing-unchanged"
  assert_state_artifact("check-missing-state", dispatchers, rules)
  exit 0
when "check-missing-cleanup"
  remove_artifact("check-missing-state")
  exit 0
when "drift"
  dispatcher = dispatchers.fetch(0)
  request(
    "put", endpoint(DOZZLE, "/api/notifications/dispatchers/#{dispatcher.fetch('id')}"), cookie: cookie,
    body: { name: dispatcher.fetch("name"), type: "webhook",
            url: "https://example.invalid/contract-drift", template: "{}", headers: {} }
  )
  oom = rules.find { |rule| rule["name"] == "OOM" } || fail_contract("OOM rule is absent")
  request(
    "put", endpoint(DOZZLE, "/api/notifications/rules/#{oom.fetch('id')}"), cookie: cookie,
    body: { name: "OOM", enabled: false, dispatcherId: dispatcher.fetch("id"),
            containerExpression: "false", logExpression: "", eventExpression: "name == \"start\"", cooldown: 1 }
  )
  request(
    "patch", endpoint(DOZZLE, "/api/notifications/rules/#{oom.fetch('id')}"), cookie: cookie,
    body: { enabled: false }
  )
  exit 0
when "drift-verify"
  fail_contract("dispatcher drift changed") unless dispatchers.length == 1 &&
    dispatchers[0]["url"] == "https://example.invalid/contract-drift"
  oom = rules.find { |rule| rule["name"] == "OOM" }
  fail_contract("OOM drift fixture differs") unless oom && oom["enabled"] == false &&
    oom["containerExpression"] == "false" && oom["eventExpression"] == 'name == "start"' && oom["cooldown"] == 1
  exit 0
end

fail_contract("expected exactly one dispatcher") unless dispatchers.length == 1
dispatcher = dispatchers.first
expected_url = RELAY_ALERTS_URL
expected_template = JSON.generate(
  version: 1,
  rule: "{{ .Subscription.Name }}",
  containerId: "{{ .Container.ID }}",
  container: "{{ .Container.Name }}",
  host: "{{ .Container.HostName }}",
  event: "{{ .Event.Name }}",
  healthStatus: '{{ index .Event.Attributes `healthStatus` }}',
  exitCode: '{{ index .Event.Attributes `exitCode` }}',
  timestamp: '{{ .Event.Timestamp.Format `2006-01-02T15:04:05.999999999Z07:00` }}'
)
fail_contract("managed dispatcher name differs") unless dispatcher["name"] == "ntfy nas-critical"
fail_contract("managed dispatcher type differs") unless dispatcher["type"] == "webhook"
fail_contract("managed dispatcher URL differs") unless dispatcher["url"] == expected_url
fail_contract("managed dispatcher template differs") unless dispatcher["template"] == expected_template
# Read straight out of the vault rather than through the inventory layer,
# because the vault is the relay token's only home: it is authored there and
# required there, with nothing in inventory deriving it (#558). So the equality
# below is the operator's rotation path end to end -- the token in the vault
# reaching Dozzle's own dispatcher (#172). Both ends of the role read one bare
# variable (roles/dozzle/defaults/main.yml and roles/dozzle/templates/env.j2),
# and the `| default(...)` or hoisted fact that would put a second source
# between them fails the expression-text checks in
# tests/contracts/dozzle-alerts.rb and tests/contracts/dozzle-stack.rb.
fail_contract("managed dispatcher headers differ") unless
  dispatcher["headers"] == { "Authorization" => "Bearer #{vault.fetch('vault_dozzle_alert_relay_token')}" }
# The equality above is the whole of it, and deliberately so. A second check for
# 'and it is not some other publisher's token' could never fail once this one
# passed: an exact equality with the relay's own secret already excludes every
# other value, so such a check would pass without checking anything. What the
# header must not be is enforced where it can actually differ -- in the rendered
# environment file, by tests/contracts/dozzle-stack.rb.
fail_contract("expected exactly four alert rules") unless rules.length == 4

ALERTS.each do |name, (expression, cooldown)|
  matches = rules.select { |rule| rule["name"] == name }
  fail_contract("#{name} rule is absent or duplicated") unless matches.length == 1
  rule = matches.first
  fail_contract("#{name} rule differs") unless rule["enabled"] == true &&
    rule["containerExpression"] == "true" && rule["logExpression"] == "" &&
    rule["eventExpression"] == expression && rule.fetch("cooldown", 0) == cooldown &&
    rule.dig("dispatcher", "id").to_s == dispatcher["id"].to_s
end

if MODE == "notify"
  pushover_token = vault.fetch("vault_pushover_containers_token")
  pushover_user_key = vault.fetch("vault_pushover_user_key")
  image = deployed_fixture_image
  health_fixture = "dozzle_contract_health_#{SecureRandom.hex(6)}"
  startup_fixture = "dozzle_contract_startup_#{SecureRandom.hex(6)}"
  exit_fixture = "dozzle_contract_exit_#{SecureRandom.hex(6)}"
  initial_exit_count = rules.find { |rule| rule["name"] == "Unexpected exit" }.fetch("triggerCount")
  # The recorder starts before the first fixture container, and that ordering is
  # load-bearing rather than tidy: a POST to a closed port raises UpstreamError
  # in the relay, which answers Dozzle 502, and Dozzle does not retry. The alert
  # is simply lost and every assertion below would fail for the wrong reason.
  with_pushover_recorder(pushover_token, pushover_user_key) do |captured|
    begin
      health_out, _error, health_status = Open3.capture3(
        "docker", "run", "-d", "--name", health_fixture,
        "--health-cmd", "test -f /tmp/healthy", "--health-interval", "1s",
        "--health-timeout", "1s", "--health-retries", "1",
        "--entrypoint", "/bin/sh", image, "-c", "sleep 120"
      )
      fail_contract("disposable unhealthy fixture did not start") unless health_status.success?
      unhealthy, observed = wait_for_pushover(
        captured,
        "unhealthy event did not reach the private relay and the Pushover recorder"
      ) do |messages|
        messages.reverse.find do |message|
          message.fetch("form")["title"] == "\u{1F7E0} #{health_fixture} unhealthy"
        end
      end
      # The lead names the container with its state in amber, and the detail
      # labels follow in order; the host is whatever Docker reported, so it is
      # matched by label rather than by value.
      expected_unhealthy_lead =
        "<b>#{health_fixture}</b> is <font color=\"#f9a825\">unhealthy</font>\n\n" \
        "\u{1F5A5}\u{FE0F} <b>Host</b> "
      unhealthy_form = unhealthy.fetch("form")
      fail_contract("unhealthy notification presentation differs") unless
        unhealthy_form["message"].to_s.start_with?(expected_unhealthy_lead) &&
        unhealthy_form["message"].to_s.scan(%r{^\S+ <b>([^<]+)</b> }).flatten == %w[Host Container When] &&
        unhealthy_form["priority"] == "1" && unhealthy_form["html"] == "1"
      # The tap-through link opens this container's page in Dozzle, whose route
      # is keyed on the 12-character short id Docker printed for the fixture,
      # and the event time travels as Unix seconds.
      fail_contract("unhealthy notification does not link its container in Dozzle") unless
        unhealthy_form["url"].to_s.match?(%r{\Ahttps?://[^/?#@]+/container/#{Regexp.escape(health_out.strip[0, 12])}\z}) &&
        unhealthy_form["url_title"] == "Open in Dozzle" &&
        unhealthy_form["timestamp"].to_s.match?(/\A[1-9][0-9]{9}\z/)
      # Pushover authenticates by form field, so this is the one assertion that
      # says the deployed relay is holding the credentials the vault declares --
      # recorded as a verdict at capture time, never as the values.
      fail_contract("relay published without the managed Pushover credentials") unless
        unhealthy["credentials_ok"]
      fail_contract("relay published to an endpoint other than the messages API") unless
        unhealthy["path"] == "/1/messages.json" &&
        unhealthy["content_type"].to_s.start_with?("application/x-www-form-urlencoded")
      # A credential in a header is the earlier transport's shape carried across, and it would
      # put the application token somewhere nothing on the far end reads.
      fail_contract("relay sent a credential in an Authorization header") unless
        unhealthy["authorization"].nil?
      fail_contract("relay exposed its event envelope as Pushover message text") if
        observed.any? { |message| message.fetch("form")["message"].to_s.include?('"version":1') }

      _exec_out, _exec_error, exec_status = Open3.capture3(
        "docker", "exec", health_fixture, "/bin/sh", "-c", "touch /tmp/healthy"
      )
      fail_contract("disposable unhealthy fixture could not recover") unless exec_status.success?
      # A recovery is a record, not an emergency. Under the earlier transport that was a second
      # topic; Pushover says it on the message, so the assertion is the
      # priority rather than the routing.
      recovered, observed = wait_for_pushover(
        captured, "healthy transition did not produce one correlated recovery"
      ) do |messages|
        messages.reverse.find do |message|
          message.fetch("form")["title"] == "\u{1F7E2} #{health_fixture} recovered"
        end
      end
      expected_recovery_lead =
        "<b>#{health_fixture}</b> is <font color=\"#2e7d32\">healthy</font> again\n\n" \
        "\u{1F5A5}\u{FE0F} <b>Host</b> "
      recovered_form = recovered.fetch("form")
      fail_contract("recovery notification presentation differs") unless
        recovered_form["message"].to_s.start_with?(expected_recovery_lead) &&
        recovered_form["message"].to_s.scan(%r{^\S+ <b>([^<]+)</b> }).flatten == %w[Host Container When] &&
        recovered_form["priority"] == "-1" && recovered_form["html"] == "1" &&
        observed.count { |message|
          message.fetch("form")["title"] == "\u{1F7E2} #{health_fixture} recovered"
        } == 1
      recovery_rules = request(
        "get", endpoint(DOZZLE, "/api/notifications/rules"), cookie: cookie
      ).last
      recovery_count = recovery_rules.find { |rule| rule["name"] == "Recovery" }.fetch("triggerCount")

      _out, _error, startup_status = Open3.capture3(
        "docker", "run", "-d", "--name", startup_fixture,
        "--health-cmd", "exit 0", "--health-interval", "1s", "--health-timeout", "1s",
        "--health-retries", "1", "--entrypoint", "/bin/sh", image, "-c", "sleep 120"
      )
      fail_contract("disposable startup-healthy fixture did not start") unless startup_status.success?
      sleep 6
      startup_rules = request(
        "get", endpoint(DOZZLE, "/api/notifications/rules"), cookie: cookie
      ).last
      startup_recovery_count = startup_rules.find { |rule| rule["name"] == "Recovery" }.fetch("triggerCount")
      fail_contract("startup healthy fixture did not exercise the managed recovery rule") unless
        startup_recovery_count > recovery_count
      fail_contract("startup healthy event produced a false recovery") if
        captured.call.any? do |message|
          message.fetch("form")["title"] == "\u{1F7E2} #{startup_fixture} recovered"
        end

      _out, _error, run_status = Open3.capture3(
        "docker", "run", "--name", exit_fixture, "--entrypoint", "/bin/sh", image, "-c", "exit 1"
      )
      fail_contract("disposable exit fixture did not exit with the expected status") unless
        run_status.exitstatus == 1
      exited, observed = wait_for_pushover(
        captured,
        "exit-code-1 event did not reach the private relay and the Pushover recorder"
      ) do |messages|
        messages.reverse.find do |message|
          message.fetch("form")["title"] == "\u{1F6D1} #{exit_fixture} exited (1)"
        end
      end
      expected_exit_lead =
        "<b>#{exit_fixture}</b> <font color=\"#c62828\">stopped unexpectedly</font>\n\n" \
        "\u{1F5A5}\u{FE0F} <b>Host</b> "
      exited_form = exited.fetch("form")
      fail_contract("unexpected-exit notification presentation differs") unless
        exited_form["message"].to_s.start_with?(expected_exit_lead) &&
        exited_form["message"].to_s.scan(%r{^\S+ <b>([^<]+)</b> }).flatten ==
          ["Host", "Container", "Exit code", "When"] &&
        exited_form["message"].to_s.include?("<b>Exit code</b> <font color=\"#c62828\">1</font>\n") &&
        exited_form["priority"] == "1" && exited_form["html"] == "1"
      fail_contract("relay exposed its event envelope as Pushover message text") if
        observed.any? { |message| message.fetch("form")["message"].to_s.include?('"version":1') }
      # Nothing here should have tripped the ceiling, and a suppression notice
      # in this window would mean the relay had spent its allowance on the
      # lane's own container churn rather than on these three events.
      fail_contract("the daily ceiling suppressed the contract's own alerts") if
        captured.call.any? do |message|
          message.fetch("form")["title"].to_s.start_with?("\u{1F507} ")
        end
    ensure
      [health_fixture, startup_fixture, exit_fixture].each do |fixture|
        system("docker", "rm", "-f", fixture, out: File::NULL, err: File::NULL)
      end
    end
    current_rules = request("get", endpoint(DOZZLE, "/api/notifications/rules"), cookie: cookie).last
    current_exit_count = current_rules.find { |rule| rule["name"] == "Unexpected exit" }.fetch("triggerCount")
    fail_contract("unique exit event was delivered without incrementing its managed rule") unless
      exited && current_exit_count > initial_exit_count
  end
end

puts "Dozzle contract passed"
