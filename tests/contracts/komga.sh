#!/bin/sh
set -eu
set +x

mode=${1:-run}
repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)}
compose=$repo_dir/services/komga/compose.yml
mac_compose=$repo_dir/services/komga/compose.mac.yml
role=$repo_dir/roles/komga/tasks/main.yml
defaults=$repo_dir/roles/komga/defaults/main.yml
argument_specs=$repo_dir/roles/komga/meta/argument_specs.yml

fail_contract() {
  printf 'Komga contract failed: %s\n' "$1" >&2
  exit 1
}

[ -f "$role" ] || fail_contract 'roles/komga/tasks/main.yml is absent'
[ -f "$defaults" ] || fail_contract 'roles/komga/defaults/main.yml is absent'
[ -f "$argument_specs" ] || fail_contract 'roles/komga/meta/argument_specs.yml is absent'
[ -f "$compose" ] || fail_contract 'services/komga/compose.yml is absent'
[ -f "$mac_compose" ] || fail_contract 'services/komga/compose.mac.yml is absent'
grep -qx 'FIXTURE_SCAN_TIMEOUT_SECONDS = 240' "$0" ||
  fail_contract 'fixture scan timeout differs'

ruby -ryaml - "$compose" "$mac_compose" "$role" "$defaults" "$argument_specs" <<'RUBY'
compose_path, mac_path, role_path, defaults_path, argument_specs_path = ARGV
compose = YAML.safe_load_file(compose_path, aliases: true)
mac = YAML.safe_load_file(mac_path, aliases: true)

# block/rescue/always nest their tasks one level deeper, so the task list is
# flattened before anything looks a name up: an unflattened load would report a
# required task as missing the moment it moved inside a block.
def flatten_tasks(tasks)
  Array(tasks).flat_map do |task|
    [task] + %w[block rescue always].flat_map do |section|
      flatten_tasks(task.is_a?(Hash) ? task[section] : nil)
    end
  end
end

# Whole-file string harvest for the absence invariant at the end of this
# contract. It has to stay unscoped, since a forbidden primitive introduced by
# any task is a violation, but it no longer trips on a comment that merely
# names the primitive.
def deep_strings(node)
  case node
  when Hash then node.flat_map { |key, value| [key.to_s] + deep_strings(value) }
  when Array then node.flat_map { |value| deep_strings(value) }
  when String then [node]
  when nil then []
  else [node.to_s]
  end
end

role_tasks = flatten_tasks(YAML.safe_load_file(role_path, aliases: false))
role_names = role_tasks.filter_map { |task| task["name"] }
role_at = lambda { |name| role_tasks.index { |task| task["name"] == name } }
role_task = lambda { |name| role_tasks.find { |task| task["name"] == name } || {} }
defaults = YAML.safe_load_file(defaults_path)
argument_specs = YAML.safe_load_file(argument_specs_path)
service = compose.fetch("services").fetch("komga")
abort "Komga contract failed: NAS UID/GID differs" unless service.fetch("user") == "1000:100"
abort "Komga contract failed: NAS port differs" unless service.fetch("ports") == ["25600:25600"]
abort "Komga contract failed: storage contract differs" unless service.fetch("volumes") == [
  "${KOMGA_CONFIG_PATH:?}:/config",
  "${KOMGA_LIBRARY_PATH:?}:/data:ro"
]
abort "Komga contract failed: restart policy differs" unless service.fetch("restart") == "unless-stopped"
abort "Komga contract failed: logging policy differs" unless service.fetch("logging") == {
  "driver" => "json-file", "options" => { "max-size" => "10m", "max-file" => "3" }
}
expected_health_test = [
  "CMD-SHELL",
  "test \"$$(/usr/bin/curl --fail --silent --show-error " \
    "http://127.0.0.1:25600/actuator/health)\" = '{\"status\":\"UP\"}'"
]
abort "Komga contract failed: application healthcheck differs" unless
  service.fetch("healthcheck") == {
    "test" => expected_health_test,
    "interval" => "30s",
    "timeout" => "10s",
    "retries" => 5,
    "start_period" => "60s"
  }
mac_service = mac.fetch("services").fetch("komga")
abort "Komga contract failed: Mac override may only replace container name and ports" unless
  mac_service.keys.sort == %w[container_name ports] && !mac_service.key?("image")
abort "Komga contract failed: managed library root differs" unless defaults.fetch("komga_library_root") == "/data"
abort "Komga contract failed: managed library name differs" unless defaults.fetch("komga_library_name") == "Comics"
abort "Komga contract failed: application health timing defaults differ" unless
  defaults.values_at("komga_health_retries", "komga_health_delay") == [60, 3]
health_options = argument_specs.dig("argument_specs", "main", "options")
abort "Komga contract failed: application health timing arguments are undeclared" unless
  health_options&.slice("komga_health_retries", "komga_health_delay") == {
    "komga_health_retries" => { "type" => "int", "required" => false },
    "komga_health_delay" => { "type" => "int", "required" => false }
  }

health_tasks = role_tasks.each_with_index.select do |task, _index|
  task["name"] == "Wait for Komga application health"
end
abort "Komga contract failed: application health readiness task must occur exactly once" unless
  health_tasks.length == 1
health_task, health_index = health_tasks.first
deploy_index = role_tasks.index { |task| task["name"] == "Deploy Komga" }
claim_index = role_tasks.index { |task| task["name"] == "Read Komga claim status" }
abort "Komga contract failed: application readiness must gate claim reconciliation" unless
  deploy_index && claim_index && deploy_index < health_index && health_index < claim_index
abort "Komga contract failed: application readiness request differs" unless
  health_task["ansible.builtin.uri"] == {
    "url" => "{{ komga_api }}/actuator/health",
    "method" => "GET",
    "status_code" => [200],
    "return_content" => true
  }
abort "Komga contract failed: application readiness status gate differs" unless
  health_task.values_at("register", "until", "retries", "delay", "changed_when", "check_mode") == [
    "komga_health",
    [
      "komga_health.json | default(none) is mapping",
      "komga_health.json.status | default(none) == 'UP'"
    ],
    "{{ komga_health_retries }}",
    "{{ komga_health_delay }}",
    false,
    false
  ]

required_tasks = [
  "Wait for Komga application health",
  "Read Komga claim status",
  "Claim Komga with the vault administrator",
  "Refuse ambiguous Komga library candidates",
  "Require valid Komga library candidate schemas",
  "Create the managed Komga library",
  "Repair the managed Komga library",
  "Read back Komga libraries after reconciliation",
  "Require exact reconciled Komga library",
  "Require the vault Komga administrator",
  "Require exactly the managed Komga library"
]
required_tasks.each do |name|
  abort "Komga contract failed: missing #{name}" unless role_names.include?(name)
end
preflight_names = [
  "List Komga libraries for reconciliation",
  "Refuse ambiguous Komga library candidates",
  "Require valid Komga library candidate schemas"
]
mutation_names = ["Create the managed Komga library", "Repair the managed Komga library"]
preflight = preflight_names.map(&role_at)
mutations = mutation_names.map(&role_at)
abort "Komga contract failed: library preflight must precede every mutation" unless
  preflight.none?(&:nil?) && mutations.none?(&:nil?) && preflight.max < mutations.min
abort "Komga contract failed: managed root matching is not trailing-slash normalized" unless
  role_task.call("Resolve normalized Komga library target")
    .dig("ansible.builtin.set_fact", "komga_library_normalized_root").to_s
    .include?("regex_replace('/+$', '')")
abort "Komga contract failed: library updates must preserve the selected identifier" unless
  role_task.call("Repair the managed Komga library").dig("ansible.builtin.uri", "url").to_s
    .include?("komga_existing_library.id | urlencode")
user_mutation = role_at.call("Reconcile managed Komga users")
abort "Komga contract failed: complete library preflight must precede managed-user mutation" unless
  user_mutation && preflight.none?(&:nil?) && preflight.max < user_mutation &&
    user_mutation < mutations.min
abort "Komga contract failed: role must not edit an opaque database" if
  deep_strings(role_tasks).any? { |value| value.match?(/sqlite|database\.sqlite|tasks\.sqlite/i) }
RUBY

grep -q '^UNRELATED_LIBRARY_ROOT = "/config/\.nas-platform-unmanaged"$' "$0" ||
  fail_contract 'unrelated library fixture API root can collide with /data'
grep -F 'ENV.fetch("PLATFORM_KOMGA_CONFIG_PATH")' "$0" >/dev/null ||
  fail_contract 'Komga fixture config path must be explicit'
if grep -E 'ENV\.fetch\("PLATFORM_KOMGA_CONFIG_PATH",[[:space:]]*MEDIA_ROOT' "$0" >/dev/null; then
  fail_contract 'Komga fixture config path has an unsafe media-root fallback'
fi

[ "$mode" = static ] && { printf '%s\n' 'Komga static contract passed'; exit 0; }

: "${PLATFORM_CONTRACT_VAULT_FILE:=${PLATFORM_MAC_VAULT_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:=${PLATFORM_MAC_VAULT_PASSWORD_FILE:-}}"
: "${PLATFORM_MEDIA_ROOT:?}"
: "${PLATFORM_REPORT_ROOT:?}"
: "${PLATFORM_KOMGA_PORT:=25600}"
: "${PLATFORM_KOMGA_FIXTURE_PRESEEDED:=false}"
if [ "${PLATFORM_KIND:-}" = integration ]; then
  : "${PLATFORM_KOMGA_RUNTIME_CONTEXT:=base}"
  case $PLATFORM_KOMGA_RUNTIME_CONTEXT in
    base) ;;
    *) fail_contract 'integration Komga runtime context differs' ;;
  esac
elif [ -z "${PLATFORM_KOMGA_RUNTIME_CONTEXT:-}" ]; then
  PLATFORM_KOMGA_RUNTIME_CONTEXT=base
fi
# Disposable lanes deploy Komga under a project namespace and name the container
# after it; production leaves the namespace empty and keeps the canonical Compose
# name.
case $PLATFORM_KOMGA_RUNTIME_CONTEXT in
  base)
    PLATFORM_KOMGA_CONTAINER=${PLATFORM_PROJECT_NAME:+$PLATFORM_PROJECT_NAME-}komga
    PLATFORM_KOMGA_DOCKER_HEALTH_REQUIRED=true
    ;;
  mac-managed)
    : "${PLATFORM_PROJECT_NAME:?PLATFORM_PROJECT_NAME is required for managed Mac Komga}"
    PLATFORM_KOMGA_CONTAINER=$PLATFORM_PROJECT_NAME-komga
    PLATFORM_KOMGA_DOCKER_HEALTH_REQUIRED=true
    ;;
  *) fail_contract 'Komga runtime context is invalid' ;;
esac
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
export PLATFORM_MEDIA_ROOT PLATFORM_REPORT_ROOT PLATFORM_KOMGA_PORT
export PLATFORM_KOMGA_FIXTURE_PRESEEDED PLATFORM_KOMGA_CONTAINER
export PLATFORM_KOMGA_DOCKER_HEALTH_REQUIRED

shift || true
exec ruby - "$mode" "$@" <<'RUBY'
require "json"
require "fileutils"
require "net/http"
require "open3"
require "pathname"
require "timeout"
require "uri"
require "yaml"
require "zlib"

MODE = ARGV.fetch(0)
FIXTURE_SCAN_TIMEOUT_SECONDS = 240
BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_KOMGA_PORT'), 10)}")
KOMGA_CONTAINER = ENV.fetch("PLATFORM_KOMGA_CONTAINER")
DOCKER_HEALTH_REQUIRED = { "true" => true, "false" => false }.fetch(
  ENV.fetch("PLATFORM_KOMGA_DOCKER_HEALTH_REQUIRED")
)
MEDIA_ROOT = Pathname.new(ENV.fetch("PLATFORM_MEDIA_ROOT")).expand_path
REPORT_ROOT = Pathname.new(ENV.fetch("PLATFORM_REPORT_ROOT")).expand_path
LIBRARY_NAME = "Comics"
LIBRARY_ROOT = "/data"
LEGACY_LIBRARY_NAME = "Books"
UNRELATED_LIBRARY_NAME = "Komga Contract Reference"
UNRELATED_LIBRARY_ROOT = "/config/.nas-platform-unmanaged"
LIBRARY_FILESYSTEM_ROOT = Pathname.new(
  ENV.fetch("PLATFORM_KOMGA_LIBRARY_PATH", MEDIA_ROOT.join("Books").to_s)
).expand_path
FIXTURE_RELATIVE = Pathname.new("task-10-contract-comic/Task 10 Contract Comic.cbz")
FIXTURE_PATH = LIBRARY_FILESYSTEM_ROOT.join(FIXTURE_RELATIVE)
FIXTURE_LIBRARY_URL = "/data/task-10-contract-comic/Task 10 Contract Comic.cbz"
STATE_PATH = REPORT_ROOT.join("komga-persistence.json")
MANAGED_SETTINGS = {
  "scanInterval" => "DISABLED",
  "scanOnStartup" => false,
  "scanCbx" => true,
  "scanPdf" => true,
  "scanEpub" => true,
  "repairExtensions" => false,
  "convertToCbz" => false,
  "emptyTrashAfterScan" => false,
  "hashFiles" => true,
  "hashPages" => false,
  "hashKoreader" => false,
  "analyzeDimensions" => true
}.freeze

def fail_contract(message)
  warn "Komga contract failed: #{message}"
  exit 1
end

def normalized_library_root(value)
  return nil unless value.is_a?(String)

  value.sub(%r{/+\z}, "")
end

def safe_library_id?(value)
  value.is_a?(String) && value.match?(/\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/)
end

def resolve_library(libraries, expected_name)
  fail_contract("library listing schema differs") unless libraries.is_a?(Array)
  root_matches = libraries.select do |entry|
    entry.is_a?(Hash) && normalized_library_root(entry["root"]) == LIBRARY_ROOT
  end
  name_matches = libraries.select do |entry|
    entry.is_a?(Hash) && entry["name"].is_a?(String) && entry["name"] == expected_name
  end
  candidates = root_matches + name_matches
  fail_contract("managed library candidate schema differs") unless candidates.all? do |entry|
    entry["name"].is_a?(String) && !entry.fetch("name").empty? &&
      entry["root"].is_a?(String) && !entry.fetch("root").empty? && safe_library_id?(entry["id"])
  end
  fail_contract("managed library root is absent or duplicated") unless root_matches.length == 1
  fail_contract("managed library name is absent, duplicated, or bound elsewhere") unless
    name_matches.length == 1 && name_matches.fetch(0).fetch("id") == root_matches.fetch(0).fetch("id")
  root_matches.fetch(0)
end

def endpoint(path)
  URI.join(BASE.to_s, path)
end

def request(method, path, basic: nil, body: nil, expected: [200])
  uri = endpoint(path)
  request = Net::HTTP.const_get(method.capitalize).new(uri)
  request.basic_auth(*basic) if basic
  if body
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body)
  end
  response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 30) do |http|
    http.request(request)
  end
  fail_contract("#{method.upcase} #{uri.path} returned HTTP #{response.code}") unless
    expected.include?(response.code.to_i)
  parsed = response.body.to_s.empty? ? nil : JSON.parse(response.body)
  [response, parsed]
rescue JSON::ParserError
  fail_contract("#{method.upcase} #{uri.path} returned malformed JSON")
rescue SystemCallError, Timeout::Error => error
  fail_contract("#{method.upcase} #{uri.path} failed: #{error.class}")
end

def wait_for_api
  deadline = Time.now + 120
  loop do
    uri = endpoint("/actuator/health")
    response = Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 5) do |http|
      http.request(Net::HTTP::Get.new(uri))
    end
    payload = JSON.parse(response.body)
    return if response.code.to_i == 200 && payload.is_a?(Hash) && payload["status"] == "UP"
  rescue JSON::ParserError, SystemCallError, Timeout::Error
    fail_contract("Komga API did not become ready") if Time.now >= deadline
    sleep 1
  else
    fail_contract("Komga API did not become ready") if Time.now >= deadline
    sleep 1
  end
end

def wait_for_container_health
  deadline = Time.now + 180
  loop do
    stdout, _stderr, status = Open3.capture3(
      "docker", "inspect", "--format", "{{.State.Health.Status}}", KOMGA_CONTAINER
    )
    return if status.success? && stdout.strip == "healthy"
    fail_contract("#{KOMGA_CONTAINER} did not become healthy") if Time.now >= deadline
    sleep 2
  end
end

def require_absent_container_healthcheck
  stdout, _stderr, status = Open3.capture3(
    "docker", "inspect", "--format",
    "{{if .State.Health}}present{{else}}absent{{end}}", KOMGA_CONTAINER
  )
  fail_contract("#{KOMGA_CONTAINER} unexpectedly defines a Docker healthcheck") unless
    status.success? && stdout.strip == "absent"
end

def png_bytes
  signature = "\x89PNG\r\n\x1a\n".b
  chunk = lambda do |kind, data|
    [data.bytesize].pack("N") + kind + data + [Zlib.crc32(kind + data)].pack("N")
  end
  raw = "\x00".b + [255, 255, 255, 255].pack("C4")
  signature + chunk.call("IHDR", [1, 1, 8, 6, 0, 0, 0].pack("NNCCCCC")) +
    chunk.call("IDAT", Zlib.deflate(raw)) + chunk.call("IEND", "".b)
end

def zip_single_file(name, contents)
  crc = Zlib.crc32(contents)
  local = [0x04034b50, 20, 0, 0, 0, 0, crc, contents.bytesize, contents.bytesize,
           name.bytesize, 0].pack("VvvvvvVVVvv") + name + contents
  central = [0x02014b50, 20, 20, 0, 0, 0, 0, crc, contents.bytesize, contents.bytesize,
             name.bytesize, 0, 0, 0, 0, 0, 0].pack("VvvvvvvVVVvvvvvVV") + name
  local + central + [0x06054b50, 0, 0, 1, 1, central.bytesize, local.bytesize, 0].pack("VvvvvVVv")
end

def seed_fixture
  directory = FIXTURE_PATH.dirname
  directory.mkpath
  bytes = zip_single_file("001.png", png_bytes)
  if FIXTURE_PATH.exist?
    fail_contract("comic fixture bytes drifted") unless FIXTURE_PATH.file? && FIXTURE_PATH.binread == bytes
  else
    FIXTURE_PATH.open(File::WRONLY | File::CREAT | File::EXCL, 0o644) { |file| file.write(bytes) }
  end
end

if MODE == "seed-fixture-only"
  seed_fixture
  puts "Komga comic fixture prepared before deployment"
  exit 0
end

vault_yaml, vault_error, vault_status = Open3.capture3(
  "ansible-vault", "view", "--vault-password-file",
  ENV.fetch("PLATFORM_CONTRACT_VAULT_PASSWORD_FILE"),
  ENV.fetch("PLATFORM_CONTRACT_VAULT_FILE")
)
fail_contract("encrypted vault could not be read") unless vault_status.success?
vault = YAML.safe_load(vault_yaml)
vault_yaml.replace("\0" * vault_yaml.bytesize)
vault_error.replace("\0" * vault_error.bytesize)
credentials = [vault.fetch("vault_komga_admin_email"), vault.fetch("vault_komga_admin_password")]

if DOCKER_HEALTH_REQUIRED
  wait_for_container_health
else
  require_absent_container_healthcheck
end
wait_for_api
request("get", "/api/v2/users/me", basic: [credentials.first, "contract-wrong-password"], expected: [401])
_me_response, me = request("get", "/api/v2/users/me", basic: credentials)
fail_contract("vault administrator identity or role differs") unless
  me.fetch("email") == credentials.first && Array(me.fetch("roles")).include?("ADMIN")

_libraries_response, libraries = request("get", "/api/v1/libraries", basic: credentials)
expected_library_name = MODE == "drift-verify" ? LEGACY_LIBRARY_NAME : LIBRARY_NAME
library = resolve_library(libraries, expected_library_name)
if MODE == "drift-verify"
  fail_contract("Komga drift fixture was not installed") unless
    library.fetch("name") == LEGACY_LIBRARY_NAME && library.fetch("scanOnStartup") == true
  puts "Komga library drift is present"
  exit
else
  MANAGED_SETTINGS.each do |key, value|
    fail_contract("managed library setting #{key} differs") unless library.fetch(key) == value
  end
end

if MODE == "drift"
  request(
    "patch", "/api/v1/libraries/#{library.fetch('id')}", basic: credentials,
    body: { "name" => LEGACY_LIBRARY_NAME, "scanOnStartup" => true }, expected: [204]
  )
  puts "Komga library drift installed"
  exit
end

if MODE == "run"
  puts "Komga login and library contract passed"
  exit
end
fail_contract("unknown mode: #{MODE}") unless %w[seed assert-persistence].include?(MODE)

if MODE == "seed"
  seed_fixture unless ENV.fetch("PLATFORM_KOMGA_FIXTURE_PRESEEDED") == "true"
  request("post", "/api/v1/libraries/#{library.fetch('id')}/scan", basic: credentials, expected: [202])
end

deadline = Time.now + FIXTURE_SCAN_TIMEOUT_SECONDS
books = nil
loop do
  _books_response, payload = request(
    "get", "/api/v1/books?unpaged=true&library_id=#{URI.encode_www_form_component(library.fetch('id'))}",
    basic: credentials
  )
  books = payload.fetch("content")
  break if books.any? { |book| book.fetch("url", "") == FIXTURE_LIBRARY_URL }
  fail_contract("comic fixture was not scanned") if Time.now >= deadline
  sleep 2
end

library_state = {
  "id" => library.fetch("id"),
  "root" => normalized_library_root(library.fetch("root")),
  "settings" => library.reject { |key, _value| %w[id name root unavailable].include?(key) }.sort.to_h,
  "unrelated" => libraries.filter_map do |entry|
    next unless entry.is_a?(Hash) && entry["name"] == UNRELATED_LIBRARY_NAME

    { "id" => entry.fetch("id"), "name" => entry.fetch("name"), "root" => entry.fetch("root") }
  end
}
case MODE
when "seed"
  fail_contract("report root is unavailable or unsafe") unless REPORT_ROOT.directory? && !REPORT_ROOT.symlink?
  fail_contract("refusing to replace Komga persistence artifact") if STATE_PATH.exist? || STATE_PATH.symlink?
  STATE_PATH.open(File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
    file.write(JSON.generate(library_state))
  end
  puts "Komga fixture, library identity, and settings seeded"
when "assert-persistence"
  fail_contract("Komga persistence artifact is unavailable or unsafe") unless STATE_PATH.file? && !STATE_PATH.symlink?
  snapshot = JSON.parse(STATE_PATH.binread)
  fail_contract("Komga managed library identifier changed across recreation") unless
    snapshot.fetch("id") == library_state.fetch("id")
  fail_contract("Komga managed library root or settings changed across recreation") unless
    snapshot.values_at("root", "settings") == library_state.values_at("root", "settings")
  snapshot.fetch("unrelated").each do |expected|
    fail_contract("unrelated Komga library did not survive recreation") unless
      libraries.any? do |entry|
        entry.is_a?(Hash) && entry.values_at("id", "name", "root") ==
          expected.values_at("id", "name", "root")
      end
  end
  puts "Komga library ID, settings, unrelated state, and scanned comic persisted"
end
RUBY
