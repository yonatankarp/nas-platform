#!/bin/sh
set -eu
set +x
umask 077

mode=${1:-verify}
case $mode in
  static|verify|drift|drift-verify|notify|\
  duplicate-dispatcher-create|duplicate-dispatcher-verify|\
  duplicate-dispatcher-assert-output|duplicate-dispatcher-cleanup|\
  duplicate-rule-create|duplicate-rule-verify|duplicate-rule-assert-output|\
  duplicate-rule-cleanup|surplus-create|surplus-verify|surplus-removed|\
  surplus-cleanup|check-mixed-create|check-mixed-unchanged|\
  check-mixed-cleanup|check-mixed-recover|check-missing-create|\
  check-missing-unchanged|check-missing-cleanup|assert-check-mixed-output|\
  assert-check-missing-output) ;;
  *) exit 2 ;;
esac
[ "$#" -eq 0 ] || shift

repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)}
compose=$repo_dir/services/dozzle/compose.yml
role=$repo_dir/roles/dozzle/tasks/main.yml
defaults=$repo_dir/roles/dozzle/defaults/main.yml
integration=$repo_dir/tests/integration.sh
mac_drift=$repo_dir/tests/mac/hooks/drift/20-dozzle.sh

fail_contract() {
  printf 'Dozzle contract failed: %s\n' "$1" >&2
  exit 1
}

[ -f "$compose" ] || fail_contract 'services/dozzle/compose.yml is absent'
[ -f "$role" ] || fail_contract 'roles/dozzle/tasks/main.yml is absent'

ruby -ryaml - "$compose" <<'RUBY'
compose = YAML.safe_load_file(ARGV.fetch(0), aliases: true)
services = compose.fetch("services")
abort "Dozzle contract failed: stack must define exactly dozzle and socket-proxy" unless
  services.keys.sort == %w[dozzle socket-proxy]

dozzle = services.fetch("dozzle")
proxy = services.fetch("socket-proxy")
expected_environment = {
  "DOZZLE_AUTH_PROVIDER" => "simple",
  "DOZZLE_ENABLE_ACTIONS" => "false",
  "DOZZLE_ENABLE_MCP" => "false",
  "DOZZLE_ENABLE_SHELL" => "false",
  "DOZZLE_NO_ANALYTICS" => "true",
  "DOZZLE_REMOTE_HOST" => "tcp://socket-proxy:2375",
  "TZ" => "${TZ:?}"
}
abort "Dozzle contract failed: security environment differs" unless
  dozzle.fetch("environment") == expected_environment
abort "Dozzle contract failed: Docker socket is mounted outside socket-proxy" if
  dozzle.fetch("volumes").any? { |volume| volume.to_s.include?("docker.sock") }
abort "Dozzle contract failed: proxy Docker socket must be read-only" unless
  proxy.fetch("volumes") == ["/var/run/docker.sock:/var/run/docker.sock:ro"]
abort "Dozzle contract failed: proxy permissions differ" unless
  proxy.fetch("environment").slice("CONTAINERS", "EVENTS", "INFO", "POST") == {
    "CONTAINERS" => "1", "EVENTS" => "1", "INFO" => "1", "POST" => "0"
  }
RUBY

ruby -ryaml - "$defaults" "$role" "$integration" "$mac_drift" "$mode" <<'RUBY'
defaults_path = ARGV.fetch(0)
defaults = YAML.safe_load_file(defaults_path)
role = File.read(ARGV.fetch(1))
integration = File.read(ARGV.fetch(2))
mac_drift = File.read(ARGV.fetch(3))
expected = {
  "OOM" => ['name == "oom"', 300],
  "Unexpected exit" => ['name == "die" && !(attributes["exitCode"] in ["0", "130", "143", "137"])', 300],
  "Unhealthy" => ['name == "health_status" && attributes["healthStatus"] == "unhealthy"', 0],
  "Recovery" => ['name == "health_status" && attributes["healthStatus"] == "healthy"', 0]
}
alerts = defaults.fetch("dozzle_alerts")
actual = alerts.to_h { |alert| [alert.fetch("name"), [alert.fetch("eventExpression"), alert.fetch("cooldown")]] }
abort "Dozzle contract failed: exact alert definitions differ" unless actual == expected
abort "Dozzle contract failed: alerts must be enabled event-only rules over all containers" unless
  alerts.all? { |alert| alert.fetch("enabled") == true && alert.fetch("containerExpression") == "true" && alert.fetch("logExpression") == "" }
abort "Dozzle contract failed: role does not wire the write-only ntfy token" unless
  File.read(defaults_path).include?("vault_ntfy_dozzle_token")
abort "Dozzle contract failed: role does not reconcile enabled state through PATCH" unless
  role.include?("method: PATCH")
planned_tasks = [
  "Report planned managed Dozzle dispatcher creation",
  "Report planned managed Dozzle dispatcher repair",
  "Report planned managed Dozzle alert rule creation",
  "Report planned managed Dozzle alert rule repair",
  "Report planned managed Dozzle alert rule enabled-state repair",
  "Report planned unmanaged Dozzle alert rule removal",
  "Report planned unmanaged Dozzle dispatcher removal"
]
markers = %w[
  DOZZLE_DUPLICATE_DISPATCHER_REFUSED_WITH_SAFE_IDS
  DOZZLE_DUPLICATE_RULE_REFUSED_WITH_SAFE_IDS
  DOZZLE_SURPLUS_STATE_REMOVED
  DOZZLE_CHECK_MIXED_PLANNED_IMMUTABLE_AND_REPAIRED
  DOZZLE_CHECK_MISSING_PLANNED_IMMUTABLE_AND_REPAIRED
]
if ARGV.fetch(4) == "static"
  planned_tasks.each do |name|
    abort "Dozzle contract failed: missing #{name}" unless role.include?("- name: #{name}")
  end
  markers.each do |marker|
    abort "Dozzle contract failed: integration is missing #{marker}" unless integration.include?(marker)
  end
  %w[check-mixed-create check-mixed-unchanged --check --diff].each do |proof|
    abort "Dozzle contract failed: Mac drift proof is missing #{proof}" unless mac_drift.include?(proof)
  end
end
RUBY

[ "$mode" = static ] && { printf '%s\n' 'Dozzle static contract passed'; exit 0; }

case $mode in
  assert-check-mixed-output|assert-check-missing-output)
    exec ruby - "$mode" "$@" <<'RUBY'
mode, output_path = ARGV
abort "Dozzle contract failed: planned-change output path is absent" unless output_path
abort "Dozzle contract failed: planned-change output is unsafe" unless
  File.file?(output_path) && !File.symlink?(output_path)

expected_counts = {
  "DOZZLE_PLAN_DISPATCHER_CREATE" => [0, 1],
  "DOZZLE_PLAN_DISPATCHER_REPAIR" => [1, 0],
  "DOZZLE_PLAN_RULE_CREATE" => [1, 4],
  "DOZZLE_PLAN_RULE_REPAIR" => [1, 0],
  "DOZZLE_PLAN_RULE_ENABLE_REPAIR" => [1, 0],
  "DOZZLE_PLAN_RULE_REMOVE" => [1, 0],
  "DOZZLE_PLAN_DISPATCHER_REMOVE" => [1, 0]
}
scenario_index = mode == "assert-check-mixed-output" ? 0 : 1
output = File.read(output_path)
expected_counts.each do |marker, counts|
  expected = counts.fetch(scenario_index)
  actual = output.scan(/\b#{Regexp.escape(marker)}\b/).length
  abort "Dozzle contract failed: planned-change marker count differs for #{marker}" unless actual == expected
end
puts "Dozzle planned-change output contract passed"
RUBY
    ;;
esac

: "${PLATFORM_CONTRACT_VAULT_FILE:?}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:?}"
: "${PLATFORM_REPORT_ROOT:?}"
: "${PLATFORM_DOZZLE_PORT:=8080}"
: "${PLATFORM_NTFY_PORT:=2586}"
export PLATFORM_DOZZLE_PORT PLATFORM_NTFY_PORT

exec ruby - "$mode" "$@" <<'RUBY'
require "json"
require "net/http"
require "open3"
require "securerandom"
require "timeout"
require "uri"
require "yaml"

MODE = ARGV.fetch(0)
DOZZLE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_DOZZLE_PORT'), 10)}")
NTFY = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_NTFY_PORT'), 10)}")
# The address Dozzle dispatches to is whatever the deployment was told to use,
# not the loopback address this contract connects to, and it is not a fixed name:
# only Docker Desktop supplies host.docker.internal. Follow the precedence
# inventory/local.yml uses, and fall back to the name inventory/mac.yml hardcodes,
# which the Mac lane relies on because it exports neither variable.
CALLBACK_HOST = [ENV["PLATFORM_CALLBACK_HOST"], ENV["PLATFORM_NAS_ADDRESS"]]
                .compact.reject(&:empty?).first || "host.docker.internal"
REPORT_ROOT = ENV.fetch("PLATFORM_REPORT_ROOT")
SAFE_ID = /\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/
ALERTS = {
  "OOM" => ['name == "oom"', 300],
  "Unexpected exit" => ['name == "die" && !(attributes["exitCode"] in ["0", "130", "143", "137"])', 300],
  "Unhealthy" => ['name == "health_status" && attributes["healthStatus"] == "unhealthy"', 0],
  "Recovery" => ['name == "health_status" && attributes["healthStatus"] == "healthy"', 0]
}.freeze

def fail_contract(message)
  warn "Dozzle contract failed: #{message}"
  exit 1
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

def request_text(uri, basic:, expected: [200])
  request = Net::HTTP::Get.new(uri)
  request.basic_auth(*basic)
  response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 15) do |http|
    http.request(request)
  end
  fail_contract("GET #{uri.path} returned HTTP #{response.code}") unless expected.include?(response.code.to_i)
  response.body.to_s
rescue SystemCallError, Timeout::Error => error
  fail_contract("GET #{uri.path} failed: #{error.class}")
end

def parse_json_lines(text)
  text.lines.filter_map do |line|
    next if line.strip.empty?

    JSON.parse(line)
  rescue JSON::ParserError
    fail_contract("ntfy returned malformed JSONL")
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
expected_url = "http://#{CALLBACK_HOST}:#{NTFY.port}"
expected_template = JSON.generate(
  topic: "nas-critical", title: "{{ .Container.Name }}", message: "{{ .Detail }}"
)
fail_contract("managed dispatcher name differs") unless dispatcher["name"] == "ntfy nas-critical"
fail_contract("managed dispatcher type differs") unless dispatcher["type"] == "webhook"
fail_contract("managed dispatcher URL differs") unless dispatcher["url"] == expected_url
fail_contract("managed dispatcher template differs") unless dispatcher["template"] == expected_template
fail_contract("managed dispatcher headers differ") unless
  dispatcher["headers"] == { "Authorization" => "Bearer #{vault.fetch('vault_ntfy_dozzle_token')}" }
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

publisher = vault.fetch("vault_ntfy_dozzle_token")
request("get", endpoint(NTFY, "/nas-critical/json?poll=1"), bearer: publisher, expected: [403])

if MODE == "notify"
  admin = [vault.fetch("vault_ntfy_admin_user"), vault.fetch("vault_ntfy_admin_password")]
  baseline_message = "dozzle-contract-baseline-#{SecureRandom.hex(6)}"
  _response, baseline = request(
    "post", endpoint(NTFY, "/nas-critical"), bearer: publisher,
    body: { message: baseline_message }
  )
  baseline_id = baseline&.fetch("id", nil)
  fail_contract("disposable ntfy baseline publish returned no anti-replay id") unless baseline_id

  _response, webhook_test = request(
    "post", endpoint(DOZZLE, "/api/notifications/test-webhook"), cookie: cookie,
    body: { url: dispatcher.fetch("url"), template: dispatcher.fetch("template"),
            headers: dispatcher.fetch("headers") }
  )
  fail_contract("managed webhook test reported failure") unless webhook_test["success"] == true
  webhook_message = nil
  webhook_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
  until webhook_message
    query = URI.encode_www_form(poll: 1, since: baseline_id)
    webhook_messages = parse_json_lines(request_text(endpoint(NTFY, "/nas-critical/json?#{query}"), basic: admin))
    webhook_message = webhook_messages.reverse.find { |message| message["title"] == "test-container" }
    fail_contract("managed webhook test did not reach disposable ntfy") if
      !webhook_message && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= webhook_deadline
    sleep 3 unless webhook_message
  end
  baseline_id = webhook_message.fetch("id")
  initial_exit_count = rules.find { |rule| rule["name"] == "Unexpected exit" }.fetch("triggerCount")

  fixture_name = "dozzle-contract-exit-#{SecureRandom.hex(6)}"
  image = "docker.io/binwiederhier/ntfy:v2.27.0@sha256:f2419f405127afa868f10985c1a41449e673477cee1eb19994339a5ae8b592e7"
  _out, _error, run_status = Open3.capture3(
    "docker", "run", "--name", fixture_name, "--entrypoint", "/bin/sh", image, "-c", "exit 1"
  )
  fail_contract("disposable exit fixture did not exit with the expected status") unless run_status.exitstatus == 1
  begin
    delivered = false
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
    loop do
      query = URI.encode_www_form(poll: 1, since: baseline_id)
      messages = parse_json_lines(request_text(endpoint(NTFY, "/nas-critical/json?#{query}"), basic: admin))
      if messages.any? { |message| message["id"] != baseline_id && message["title"] == fixture_name }
        delivered = true
        break
      end
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        fail_contract("exit-code-1 event did not reach disposable ntfy")
      end
      sleep 3
    end
  ensure
    system("docker", "rm", "-f", fixture_name, out: File::NULL, err: File::NULL)
  end
  current_rules = request("get", endpoint(DOZZLE, "/api/notifications/rules"), cookie: cookie).last
  current_exit_count = current_rules.find { |rule| rule["name"] == "Unexpected exit" }.fetch("triggerCount")
  fail_contract("unique exit event was delivered without incrementing its managed rule") unless
    delivered && current_exit_count > initial_exit_count
end

puts "Dozzle contract passed"
RUBY
