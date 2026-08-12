#!/bin/sh
set -eu
set +x

repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)}
compose=$repo_dir/services/jellyfin/compose.yml
role=$repo_dir/roles/jellyfin/tasks/main.yml
defaults=$repo_dir/roles/jellyfin/defaults/main.yml
avatar=$repo_dir/roles/jellyfin/files/yonatan-avatar.jpeg

fail_contract() {
  printf 'Jellyfin contract failed: %s\n' "$1" >&2
  exit 1
}

usage() {
  printf '%s\n' 'usage: jellyfin.sh [--platform mac|nas|integration] [MODE]' >&2
  exit 2
}

# The platform decides which capability contract applies. It defaults to the
# contract environment ABI so the integration lane needs no extra argument.
platform=${PLATFORM_KIND:-nas}
mode=
while [ "$#" -gt 0 ]; do
  case $1 in
    --platform)
      [ "$#" -ge 2 ] || usage
      platform=$2
      shift 2
      ;;
    --) shift; break ;;
    -*) usage ;;
    *) mode=$1; shift; break ;;
  esac
done
: "${mode:=run}"
case $platform in
  mac|nas|integration) ;;
  *) fail_contract "unknown platform: $platform" ;;
esac

[ -f "$role" ] || fail_contract 'roles/jellyfin/tasks/main.yml is absent'
[ -f "$defaults" ] || fail_contract 'roles/jellyfin/defaults/main.yml is absent'
[ -f "$compose" ] || fail_contract 'services/jellyfin/compose.yml is absent'
[ -f "$avatar" ] || fail_contract 'approved administrator avatar is absent'

ruby -ryaml -rdigest - "$repo_dir" "$platform" <<'RUBY'
root, platform = ARGV
compose_path = File.join(root, "services", "jellyfin", "compose.yml")
compose = YAML.safe_load_file(compose_path, aliases: true)
service = compose.fetch("services").fetch("jellyfin")

def refuse(message)
  abort "Jellyfin contract failed: #{message}"
end

expected_image = "docker.io/jellyfin/jellyfin:10.11.11@" \
                 "sha256:aefb67e6a7ff1debdd154a78a7bbb780fd0c873d8639210a7f6a2016ad2b35db"
refuse("legacy image pin differs") unless service.fetch("image") == expected_image
avatar = File.join(root, "roles", "jellyfin", "files", "yonatan-avatar.jpeg")
refuse("approved administrator avatar hash differs") unless
  Digest::SHA256.file(avatar).hexdigest ==
    "bf12ac53a05f1db64f3d00440315a6626e7c2dd12dd41867c93c9ac7aeccc792"
refuse("NAS UID/GID differs") unless service.fetch("user") == "1000:100"
refuse("NAS port differs") unless service.fetch("ports") == ["8096:8096/tcp"]
refuse("storage contract differs") unless service.fetch("volumes") == [
  "${JELLYFIN_CONFIG_PATH:?}:/config",
  "${JELLYFIN_CACHE_PATH:?}:/cache",
  "${JELLYFIN_MEDIA_PATH:?}:/media:ro"
]
refuse("restart policy differs") unless service.fetch("restart") == "unless-stopped"
refuse("logging policy differs") unless service.fetch("logging") == {
  "driver" => "json-file", "options" => { "max-size" => "10m", "max-file" => "3" }
}

# The NAS-only capability contract. These three keys are the production
# definition and must never be weakened to make another platform work.
refuse("NAS render device mapping is absent") unless
  service.fetch("devices") == ["/dev/dri/renderD128:/dev/dri/renderD128"]
refuse("NAS render device group access is absent") unless service.fetch("group_add") == ["0"]
refuse("NAS stop grace period differs") unless service.fetch("stop_grace_period") == "1m"
refuse("health check is absent") unless service.fetch("healthcheck").fetch("test").is_a?(Array)

# Every platform that lacks /dev/dri must remove the device and the root group
# explicitly. Compose appends sequences, so a bare empty list would silently
# keep the NAS device: the !override tag is what actually replaces it.
override_path = File.join(root, "services", "jellyfin", "compose.#{platform}.yml")
if platform == "nas"
  refuse("the NAS runs the production definition unmodified") if File.exist?(override_path)
else
  refuse("services/jellyfin/compose.#{platform}.yml is absent") unless File.file?(override_path)
  override_text = File.read(override_path)
  override = YAML.safe_load_file(override_path, aliases: true)
  override_service = override.fetch("services").fetch("jellyfin")
  %w[devices group_add].each do |key|
    refuse("#{platform} override must reset #{key} with an explicit tag") unless
      override_text.match?(/^\s+#{key}: !override(\s|$)/)
    refuse("#{platform} override must reset #{key} to empty") unless
      override_service.fetch(key) == []
  end
  allowed = %w[container_name devices group_add ports]
  surplus = override_service.keys - allowed
  refuse("#{platform} override may not redefine #{surplus.join(', ')}") unless surplus.empty?
  refuse("#{platform} override must not redefine the image") if override_service.key?("image")
  if override_service.key?("ports")
    refuse("#{platform} override must replace published ports with an explicit tag") unless
      override_text.match?(/^\s+ports: !override(\s|$)/)
  end
end

defaults = YAML.safe_load_file(File.join(root, "roles", "jellyfin", "defaults", "main.yml"))
refuse("primary administrator differs") unless defaults.fetch("jellyfin_admin_username") == "Yonatan"
refuse("server name differs") unless defaults.fetch("jellyfin_server_name") == "Yonflix 2.0"
refuse("administrator avatar hash differs") unless
  defaults.fetch("jellyfin_admin_avatar_sha256") ==
    "bf12ac53a05f1db64f3d00440315a6626e7c2dd12dd41867c93c9ac7aeccc792"
refuse("managed libraries differ") unless defaults.fetch("jellyfin_libraries") == [
  { "name" => "Movies", "collection_type" => "movies", "path" => "/media/Movies" },
  { "name" => "Shows", "collection_type" => "tvshows", "path" => "/media/Series" }
]
refuse("Collections must remain application-managed") if
  defaults.fetch("jellyfin_libraries").any? { |library| library.fetch("name") == "Collections" }
refuse("managed library must not write metadata into read-only media") unless
  defaults.fetch("jellyfin_library_options").fetch("SaveLocalMetadata") == false

identity_path = File.join(root, "roles", "jellyfin", "tasks", "primary_identity.yml")
identity = File.file?(identity_path) ? File.read(identity_path) : ""
role = File.read(File.join(root, "roles", "jellyfin", "tasks", "main.yml")) + identity
contract = File.read(File.join(root, "tests", "contracts", "jellyfin.sh"))
runtime_query = ["fields=Path,MediaSources", "RunTimeTicks"].join(",")
refuse("fixture query does not request its runtime field") unless contract.include?(runtime_query)
runtime_readiness = /ready = found\s*&&\s*found\["RunTimeTicks"\]\.is_a\?\(Integer\)\s*&&\s*Array\(found\["MediaSources"\]\)\.any\?/
refuse("fixture polling does not wait for probed media metadata") unless
  contract.match?(runtime_readiness)
required_tasks = [
  "Wait for the Jellyfin startup API",
  "Read Jellyfin startup state",
  "Materialize the Jellyfin first user",
  "Create the vault Jellyfin administrator",
  "Complete the Jellyfin startup wizard",
  "Report planned Jellyfin administrator image upload after startup",
  "Report planned Jellyfin managed library creation after startup",
  "Preflight Jellyfin managed users",
  "List Jellyfin users for primary administrator preflight",
  "Refuse ambiguous Jellyfin primary administrator identity",
  "Read Jellyfin server configuration for preflight",
  "List Jellyfin libraries for preflight",
  "Refuse unsafe Jellyfin managed library path representation",
  "Refuse ambiguous Jellyfin managed library ownership",
  "Reconcile the Jellyfin primary administrator name safely",
  "Recover the Jellyfin primary administrator name after rename failure",
  "Require recovered Jellyfin primary administrator identity",
  "Update the Jellyfin server name",
  "Upload the Jellyfin primary administrator image",
  "Rename adopted Jellyfin managed libraries",
  "Create absent Jellyfin managed libraries",
  "Remove extra paths from Jellyfin managed libraries",
  "Repair Jellyfin managed library options",
  "Require the vault Jellyfin administrator",
  "Verify exact Jellyfin owned state"
]
required_tasks.each do |name|
  refuse("missing #{name}") unless role.include?("- name: #{name}")
end
preflight_names = [
  "Preflight Jellyfin managed users",
  "List Jellyfin users for primary administrator preflight",
  "Refuse ambiguous Jellyfin primary administrator identity",
  "Read Jellyfin server configuration for preflight",
  "List Jellyfin libraries for preflight",
  "Refuse unsafe Jellyfin managed library path representation",
  "Refuse ambiguous Jellyfin managed library ownership"
]
mutation_names = [
  "Reconcile the Jellyfin primary administrator name safely",
  "Update the Jellyfin server name",
  "Upload the Jellyfin primary administrator image",
  "Rename adopted Jellyfin managed libraries",
  "Create absent Jellyfin managed libraries",
  "Remove extra paths from Jellyfin managed libraries",
  "Repair Jellyfin managed library options"
]
preflight = preflight_names.map { |name| role.index("- name: #{name}") }
mutations = mutation_names.map { |name| role.index("- name: #{name}") }
refuse("all identity/library preflight must precede mutation") unless
  preflight.none?(&:nil?) && mutations.none?(&:nil?) && preflight.max < mutations.min
refuse("current user update API is absent") unless role.include?("/Users?userId=")
refuse("current user image API is absent") unless role.include?("/UserImage?userId=")
refuse("current path removal API is absent") unless
  role.include?("/Library/VirtualFolders/Paths?name=") && role.include?("method: DELETE")
refuse("primary identity rename lacks recovery") unless identity.include?("rescue:")
refuse("temporary recovery name match is not byte-exact") unless
  role.include?("if item.Name == jellyfin_primary_temporary_name else")
refuse("recovery marker privacy is not checked before reading") unless
  role.index("stat.mode == '0600'") < role.index("Read Jellyfin primary administrator recovery marker") &&
    role.index("stat.pw_name == ansible_facts.user_id") <
      role.index("Read Jellyfin primary administrator recovery marker")
refuse("server configuration update does not preserve unrelated fields") unless
  role.include?("jellyfin_server_configuration_before.json | combine")
refuse("avatar upload is unconditional") unless
  role.include?("jellyfin_admin_avatar_upload_required")
refuse("role must not edit an opaque database") if
  role.match?(/sqlite|library\.db|jellyfin\.db/i)
puts "Jellyfin static contract passed (#{platform})"
RUBY

[ "$mode" = static ] && exit 0
. "${PLATFORM_LEGACY_FIXTURE_HELPER_FILE:-$repo_dir/tests/contracts/legacy-fixture-paths.sh}"
legacy_fixture_validate PLATFORM_JELLYFIN_MEDIA_ROOT legacy/jellyfin/media ||
  fail_contract 'legacy media root is unsafe'
legacy_fixture_validate PLATFORM_JELLYFIN_TRANSCODE_ROOT legacy/jellyfin/cache/transcodes ||
  fail_contract 'legacy transcode root is unsafe'

: "${PLATFORM_CONTRACT_VAULT_FILE:=${PLATFORM_MAC_VAULT_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:=${PLATFORM_MAC_VAULT_PASSWORD_FILE:-}}"
: "${PLATFORM_MEDIA_ROOT:?}"
: "${PLATFORM_DOCKER_ROOT:?}"
: "${PLATFORM_REPORT_ROOT:?}"
: "${PLATFORM_JELLYFIN_PORT:=8096}"
if [ -z "${PLATFORM_JELLYFIN_CONTAINER:-}" ]; then
  PLATFORM_JELLYFIN_CONTAINER=${PLATFORM_PROJECT_NAME:+$PLATFORM_PROJECT_NAME-}jellyfin
fi
PLATFORM_JELLYFIN_PLATFORM=$platform
PLATFORM_JELLYFIN_AVATAR_PATH=$avatar
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
export PLATFORM_MEDIA_ROOT PLATFORM_DOCKER_ROOT PLATFORM_REPORT_ROOT
export PLATFORM_JELLYFIN_PORT PLATFORM_JELLYFIN_CONTAINER PLATFORM_JELLYFIN_PLATFORM
export PLATFORM_JELLYFIN_AVATAR_PATH

exec ruby - "$mode" "$@" <<'RUBY'
require "json"
require "digest"
require "net/http"
require "open3"
require "pathname"
require "timeout"
require "uri"
require "yaml"

MODE = ARGV.fetch(0)
PLATFORM = ENV.fetch("PLATFORM_JELLYFIN_PLATFORM")
BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_JELLYFIN_PORT'), 10)}")
MEDIA_ROOT = Pathname.new(ENV.fetch("PLATFORM_MEDIA_ROOT")).expand_path
DOCKER_ROOT = Pathname.new(ENV.fetch("PLATFORM_DOCKER_ROOT")).expand_path
REPORT_ROOT = Pathname.new(ENV.fetch("PLATFORM_REPORT_ROOT")).expand_path
CONTAINER = ENV.fetch("PLATFORM_JELLYFIN_CONTAINER")
STATE_PATH = REPORT_ROOT.join("jellyfin-persistence.json")

ADMIN_NAME = "Yonatan"
SERVER_NAME = "Yonflix 2.0"
AVATAR_PATH = Pathname.new(ENV.fetch("PLATFORM_JELLYFIN_AVATAR_PATH")).expand_path
AVATAR_SHA256 = "bf12ac53a05f1db64f3d00440315a6626e7c2dd12dd41867c93c9ac7aeccc792"
LIBRARIES = [
  { "Name" => "Movies", "CollectionType" => "movies", "Path" => "/media/Movies" },
  { "Name" => "Shows", "CollectionType" => "tvshows", "Path" => "/media/Series" }
].freeze
UNMANAGED_LIBRARY = {
  "Name" => "Jellyfin Contract Sentinel",
  "CollectionType" => "books",
  "Path" => "/media/Unmanaged"
}.freeze
ADOPTION_SHOWS_SEED_NAME = "Legacy Series By Path"
ADOPTION_EXTRA_PATH = "/media/Legacy-Series-Extra"
DRIFT_EXTRA_PATH = "/media/Movies-Drift-Extra"
CONFIG_SENTINEL_KEY = "EnableMetrics"
CONFIG_SENTINEL_VALUE = true
MANAGED_OPTIONS = {
  "EnableRealtimeMonitor" => false,
  "EnableChapterImageExtraction" => false,
  "EnableTrickplayImageExtraction" => false,
  "SaveLocalMetadata" => false,
  "EnableInternetProviders" => false,
  "AutomaticRefreshIntervalDays" => 0,
  "PreferredMetadataLanguage" => "en",
  "MetadataCountryCode" => "DE"
}.freeze

# The fixture lives beside the tinyMediaManager movie fixtures because the NAS
# mounts one media tree and both services see it. Jellyfin only reads it.
JELLYFIN_MEDIA_ROOT = Pathname.new(
  ENV.fetch("PLATFORM_JELLYFIN_MEDIA_ROOT", MEDIA_ROOT.join("Media").to_s)
).expand_path
FIXTURE_DIRECTORY = JELLYFIN_MEDIA_ROOT.join("Movies", "Task 11 Contract Movie (2026)")
FIXTURE_PATH = FIXTURE_DIRECTORY.join("Task 11 Contract Movie (2026).mp4")
FIXTURE_LIBRARY_PATH = "/media/Movies/Task 11 Contract Movie (2026)/Task 11 Contract Movie (2026).mp4"
FIXTURE_RUNTIME_TICKS = 40_000_000
DRIFT_IMAGE = (
  "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////" \
  "2wBDAf//////////////////////////////////////////////////////////////////////////////////////wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAA" \
  "AAAAAAAAAAAAB//EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAMAwEAAhADEAAAAU//xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAE/" \
  "AH//xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAECAQE/AH//xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAEDAQE/AH//2Q=="
).unpack1("m0").freeze

# Four seconds of 64x48 H.264 produced by the pinned image's own ffmpeg with
# bitexact flags, so regenerating it yields these exact bytes. Small enough to
# transcode instantly and long enough to split into two HLS segments.
VIDEO_FIXTURE = (
  "AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAANLbW9vdgAAAGxtdmhkAAAAAAAAAAAA" \
  "AAAAAAAD6AAAD6AAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAA" \
  "AABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAApp0cmFrAAAAXHRraGQAAAADAAAA" \
  "AAAAAAAAAAABAAAAAAAAD6AAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAA" \
  "AAAAAAAAAABAAAAAAEAAAAAwAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAA+gAAAgAAABAAAA" \
  "AAISbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAABAAAABAABVxAAAAAAALWhkbHIAAAAAAAAAAHZp" \
  "ZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABvW1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAA" \
  "ACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAX1zdGJsAAAAwXN0c2QAAAAAAAAA" \
  "AQAAALFhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAEAAMABIAAAASAAAAAAAAAABDExhdmMg" \
  "bGlieDI2NAAAAAAAAAAAAAAAAAAAAAAAAAAAGP//AAAAN2F2Y0MBZAAK/+EAGWdkAAqsWERHsBEA" \
  "AAMAAQAAAwAEDxIlBGABAAdo6EOBlLIs/fj4AAAAABBwYXNwAAAAAQAAAAEAAAAUYnRydAAAAAAA" \
  "AAaaAAAAAAAAABhzdHRzAAAAAAAAAAEAAAAIAAAgAAAAACBzdHNzAAAAAAAAAAQAAAABAAAAAwAA" \
  "AAUAAAAHAAAAGGN0dHMAAAAAAAAAAQAAAAgAACAAAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAAIAAAA" \
  "AQAAADRzdHN6AAAAAAAAAAAAAAAIAAACyQAAAAwAAAAcAAAADAAAABwAAAAMAAAAHAAAAAwAAAAU" \
  "c3RjbwAAAAAAAAABAAADewAAAD11ZHRhAAAANW1ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAG1kaXJh" \
  "cHBsAAAAAAAAAAAAAAAACGlsc3QAAAAIZnJlZQAAA1VtZGF0AAACrAYF//+o3EXpvebZSLeWLNgg" \
  "2SPu73gyNjQgLSBjb3JlIDE2NCByMzEwOCAzMWUxOWY5IC0gSC4yNjQvTVBFRy00IEFWQyBjb2Rl" \
  "YyAtIENvcHlsZWZ0IDIwMDMtMjAyMyAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRt" \
  "bCAtIG9wdGlvbnM6IGNhYmFjPTEgcmVmPTE2IGRlYmxvY2s9MTowOjAgYW5hbHlzZT0weDM6MHgx" \
  "MzMgbWU9dW1oIHN1Ym1lPTEwIHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTEgbWVf" \
  "cmFuZ2U9MjQgY2hyb21hX21lPTEgdHJlbGxpcz0yIDh4OGRjdD0xIGNxbT0wIGRlYWR6b25lPTIx" \
  "LDExIGZhc3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zmc2V0PS0yIHRocmVhZHM9MSBsb29rYWhlYWRf" \
  "dGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBi" \
  "bHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTEgYl9weXJhbWlkPTAg" \
  "Yl9hZGFwdD0yIGJfYmlhcz0wIGRpcmVjdD0zIHdlaWdodGI9MSBvcGVuX2dvcD0wIHdlaWdodHA9" \
  "MiBrZXlpbnQ9MiBrZXlpbnRfbWluPTEgc2NlbmVjdXQ9NDAgaW50cmFfcmVmcmVzaD0wIHJjX2xv" \
  "b2thaGVhZD0yIHJjPWNyZiBtYnRyZWU9MSBjcmY9NTEuMCBxY29tcD0wLjYwIHFwbWluPTAgcXBt" \
  "YXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0xOjEuMDAAgAAAABVliIIAKf/9GlvAo7MR" \
  "imBLHABVtW0AAAAIQZoS2IJfGbAAAAAYZYiBAAt//RjvApNvTEcdMPOJ0hWoR9GBAAAACEGaEtiC" \
  "XxmwAAAAGGWIggAt//0Y7wKTb0xHHTDzidIVqEfRgQAAAAhBmhLYgl8ZsQAAABhliIEAC3/9GO8C" \
  "k29MRx0w84nSFahH0YEAAAAIQZoS2IJfGbE="
# unpack1 rather than the base64 library, which is not a default gem on the
# Ruby 3.4 the integration lane runs.
).unpack1("m0").freeze

CLIENT = 'MediaBrowser Client="nas-platform-contract", Device="contract", ' \
         'DeviceId="nas-platform-jellyfin-contract", Version="1.0.0"'

def fail_contract(message)
  warn "Jellyfin contract failed: #{message}"
  exit 1
end

def request(method, path, token: nil, body: nil, encoded_body: nil, expected: [200], headers: {}, raw: false)
  uri = URI.join(BASE.to_s, path)
  request = Net::HTTP.const_get(method.capitalize).new(uri)
  request["Authorization"] = token ? %(#{CLIENT}, Token="#{token}") : CLIENT
  headers.each { |name, value| request[name] = value }
  if body
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body)
  elsif encoded_body
    request.body = encoded_body
  end
  response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 120) do |http|
    http.request(request)
  end
  fail_contract("#{method.upcase} #{uri.path} returned HTTP #{response.code}") unless
    expected.include?(response.code.to_i)
  return response if raw

  parsed = response.body.to_s.empty? ? nil : JSON.parse(response.body)
  [response, parsed]
rescue JSON::ParserError
  fail_contract("#{method.upcase} #{uri.path} returned malformed JSON")
rescue SystemCallError, Timeout::Error, EOFError => error
  fail_contract("#{method.upcase} #{uri.path} failed: #{error.class}")
end

# The image serves /health long before the application can answer for its own
# users and libraries, so readiness is the completed wizard, not the port.
def wait_for_application
  deadline = Time.now + 240
  loop do
    uri = URI.join(BASE.to_s, "/System/Info/Public")
    response = Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 10) do |http|
      http.request(Net::HTTP::Get.new(uri))
    end
    payload = JSON.parse(response.body)
    return if response.code.to_i == 200 && payload["StartupWizardCompleted"] == true
  rescue JSON::ParserError, SystemCallError, Timeout::Error, EOFError
    nil
  ensure
    fail_contract("Jellyfin did not complete its startup wizard") if Time.now >= deadline
    sleep 2
  end
end

def docker_capture(*argv)
  stdout, stderr, status = Open3.capture3("docker", *argv)
  fail_contract("docker #{argv.first} failed for #{CONTAINER}") unless status.success?
  stderr.replace("\0" * stderr.bytesize)
  stdout
end

def safe_id(value)
  fail_contract("Jellyfin returned an unsafe API identifier") unless
    value.is_a?(String) && value.match?(/\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/)
  value
end

def authenticate(username, password)
  _response, payload = request(
    "post", "/Users/AuthenticateByName", body: { "Username" => username, "Pw" => password }
  )
  payload
end

def libraries(token)
  _response, folders = request("get", "/Library/VirtualFolders", token: token)
  fail_contract("library response is not complete") unless folders.is_a?(Array)
  folders
end

def normalize_path(path)
  path.sub(%r{/+\z}, "")
end

def library_by_path(folders, definition)
  matches = folders.select do |folder|
    Array(folder["Locations"]).map { |path| normalize_path(path) }.include?(definition.fetch("Path"))
  end
  fail_contract("library path #{definition.fetch('Path')} is absent or duplicated") unless matches.length == 1
  matches.fetch(0)
end

def assert_managed_library(folder, definition)
  fail_contract("managed library name differs") unless folder.fetch("Name") == definition.fetch("Name")
  fail_contract("managed library collection type differs") unless
    folder.fetch("CollectionType") == definition.fetch("CollectionType")
  fail_contract("managed library locations differ") unless
    folder.fetch("Locations") == [definition.fetch("Path")]
  options = folder.fetch("LibraryOptions")
  fail_contract("managed library paths differ") unless
    options.fetch("PathInfos").map { |info| info.fetch("Path") } == [definition.fetch("Path")]
  MANAGED_OPTIONS.each do |key, value|
    fail_contract("managed library option #{key} differs") unless options[key] == value
  end
end

def server_configuration(token)
  _response, configuration = request("get", "/System/Configuration", token: token)
  fail_contract("server configuration response is incomplete") unless configuration.is_a?(Hash)
  configuration
end

def user_image(token, user)
  tag = URI.encode_www_form_component(user.fetch("PrimaryImageTag"))
  id = safe_id(user.fetch("Id"))
  request("get", "/UserImage?userId=#{id}&tag=#{tag}&format=original", token: token, raw: true).body
end

def upload_user_image(token, user_id, bytes)
  request(
    "post", "/UserImage?userId=#{safe_id(user_id)}", token: token,
    encoded_body: [bytes].pack("m0"), headers: { "Content-Type" => "image/jpeg" },
    expected: [204], raw: true
  )
end

def rename_user(token, user, new_name)
  id = safe_id(user.fetch("Id"))
  request(
    "post", "/Users?userId=#{id}", token: token,
    body: user.merge("Name" => new_name), expected: [204]
  )
end

def rename_library(token, old_name, new_name)
  query = URI.encode_www_form("name" => old_name, "newName" => new_name, "refreshLibrary" => false)
  request("post", "/Library/VirtualFolders/Name?#{query}", token: token, expected: [204])
end

def add_library_path(token, name, path)
  request(
    "post", "/Library/VirtualFolders/Paths", token: token,
    body: { "Name" => name, "PathInfo" => { "Path" => path } }, expected: [204]
  )
end

def assert_container_capabilities
  inspection = JSON.parse(docker_capture("inspect", CONTAINER)).fetch(0)
  mounts = inspection.fetch("Mounts")
  media = mounts.find { |mount| mount["Destination"] == "/media" }
  fail_contract("the media mount is absent") if media.nil?
  fail_contract("media is not mounted read-only") if media["RW"]
  devices = inspection.dig("HostConfig", "Devices") || []
  if PLATFORM == "nas"
    fail_contract("the NAS render device is not mapped") unless
      devices.any? { |device| device["PathInContainer"] == "/dev/dri/renderD128" }
  else
    fail_contract("#{PLATFORM} must expose no host device: #{devices.inspect}") unless devices.empty?
    fail_contract("#{PLATFORM} must add no supplementary group") unless
      (inspection.dig("HostConfig", "GroupAdd") || []).empty?
  end
end

def seed_fixture
  FIXTURE_DIRECTORY.mkpath
  fail_contract("fixture path is a symlink") if FIXTURE_PATH.symlink?
  if FIXTURE_PATH.exist?
    fail_contract("video fixture bytes drifted") unless
      FIXTURE_PATH.file? && FIXTURE_PATH.binread == VIDEO_FIXTURE
  else
    FIXTURE_PATH.open(File::WRONLY | File::CREAT | File::EXCL, 0o644) do |file|
      file.write(VIDEO_FIXTURE)
    end
  end
end

def find_fixture_item(token, user_id, timeout:)
  deadline = Time.now + timeout
  query = "userId=#{user_id}&recursive=true&includeItemTypes=Movie&" \
          "fields=Path,MediaSources,RunTimeTicks"
  loop do
    _response, payload = request("get", "/Items?#{query}", token: token)
    items = payload.fetch("Items")
    found = items.find { |item| item["Path"] == FIXTURE_LIBRARY_PATH }
    ready = found &&
            found["RunTimeTicks"].is_a?(Integer) &&
            Array(found["MediaSources"]).any? { |source| source["Id"] }
    return found if ready

    if Time.now >= deadline
      fail_contract("the video fixture was not scanned within #{timeout}s; " \
                    "the library holds #{items.length} movie(s)")
    end
    sleep 3
  end
end

def assert_direct_play(token, item_id, source_id)
  path = "/Videos/#{item_id}/stream?static=true&mediaSourceId=#{source_id}"
  response = request("get", path, token: token, raw: true)
  fail_contract("direct play returned HTTP #{response.code}") unless response.code.to_i == 200
  fail_contract("direct play did not return the exact source bytes") unless
    response.body == VIDEO_FIXTURE
  ranged = request(
    "get", path, token: token, raw: true, expected: [206],
    headers: { "Range" => "bytes=0-127" }
  )
  fail_contract("direct play ignored the byte range") unless
    ranged.code.to_i == 206 &&
    ranged["content-range"] == "bytes 0-127/#{VIDEO_FIXTURE.bytesize}" &&
    ranged.body == VIDEO_FIXTURE.byteslice(0, 128)
end

# Forcing a smaller frame size makes the source unusable as-is, so the server
# must decode and re-encode rather than remux. A tiny source keeps that honest
# and fast on every platform.
def assert_cpu_transcode(token, item_id, source_id)
  query = "deviceId=nas-platform-jellyfin-contract&mediaSourceId=#{source_id}" \
          "&videoCodec=h264&audioCodec=aac&static=false&maxWidth=32&videoBitRate=8000" \
          "&segmentContainer=ts&minSegments=1&breakOnNonKeyFrames=false"
  master = request("get", "/Videos/#{item_id}/master.m3u8?#{query}", token: token, raw: true)
  fail_contract("the transcode playlist returned HTTP #{master.code}") unless
    master.code.to_i == 200
  variant = master.body.lines.map(&:strip).find { |line| line.start_with?("main.m3u8") }
  fail_contract("the transcode playlist names no variant") if variant.nil?

  main = request("get", "/Videos/#{item_id}/#{variant}", token: token, raw: true)
  fail_contract("the transcode variant returned HTTP #{main.code}") unless main.code.to_i == 200
  segment_path = main.body.lines.map(&:strip).find { |line| line.include?("hls1/") }
  fail_contract("the transcode variant names no segment") if segment_path.nil?

  segment = request("get", "/Videos/#{item_id}/#{segment_path}", token: token, raw: true)
  fail_contract("the transcoded segment returned HTTP #{segment.code}") unless
    segment.code.to_i == 200
  fail_contract("the transcoded segment is empty") if segment.body.to_s.empty?
  fail_contract("the transcoded segment is not MPEG-TS") unless segment.body.getbyte(0) == 0x47

  deadline = Time.now + 60
  transcode = nil
  loop do
    _response, sessions = request("get", "/Sessions", token: token)
    transcode = sessions.filter_map { |session| session["TranscodingInfo"] }.first
    break if transcode

    fail_contract("no active transcode session was reported") if Time.now >= deadline
    sleep 2
  end
  fail_contract("the server direct-played instead of transcoding") if transcode["IsVideoDirect"]
  fail_contract("the transcode did not honor the requested frame size") unless
    transcode["Width"] == 32
  unless PLATFORM == "nas"
    fail_contract("#{PLATFORM} must transcode on the CPU, not " \
                  "#{transcode['HardwareAccelerationType'].inspect}") unless
      transcode["HardwareAccelerationType"].to_s.casecmp?("none")
  end

  # Durable evidence that re-encoded output really reached the cache volume,
  # independent of how long the session stays visible.
  transcode_root = Pathname.new(
    ENV.fetch("PLATFORM_JELLYFIN_TRANSCODE_ROOT", DOCKER_ROOT.join("jellyfin", "cache", "transcodes").to_s)
  ).expand_path
  fail_contract("the transcode cache is unavailable or unsafe") unless
    transcode_root.directory? && !transcode_root.symlink?
  fail_contract("no transcoded segment reached the cache volume") if
    Dir.glob(transcode_root.join("*.ts").to_s).empty?
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
username = vault.fetch("vault_jellyfin_admin_username")
password = vault.fetch("vault_jellyfin_admin_password")
fail_contract("vault primary administrator must be exact Yonatan") unless username == ADMIN_NAME
fail_contract("approved administrator avatar bytes drifted") unless
  AVATAR_PATH.file? && Digest::SHA256.file(AVATAR_PATH).hexdigest == AVATAR_SHA256

wait_for_application
# Rejected credentials come back as plain text, not JSON, so this asks for the
# raw response instead of a parsed body.
request(
  "post", "/Users/AuthenticateByName", raw: true,
  body: { "Username" => username, "Pw" => "contract-wrong-password" }, expected: [401]
)
session = authenticate(username, password)
token = session.fetch("AccessToken")
user = session.fetch("User")
user_id = safe_id(user.fetch("Id"))
fail_contract("the vault administrator role differs") unless user.dig("Policy", "IsAdministrator") == true

assert_container_capabilities
folders = libraries(token)
configuration = server_configuration(token)

if MODE == "seed"
  seed_fixture
  unless user.fetch("Name") == ADMIN_NAME
    temporary_name = "nas-platform-contract-seed-#{user_id[0, 8]}"
    rename_user(token, user, temporary_name)
    rename_user(token, user.merge("Name" => temporary_name), ADMIN_NAME)
  end
  unless configuration["ServerName"] == SERVER_NAME &&
         configuration[CONFIG_SENTINEL_KEY] == CONFIG_SENTINEL_VALUE
    configuration["ServerName"] = SERVER_NAME
    configuration[CONFIG_SENTINEL_KEY] = CONFIG_SENTINEL_VALUE
    request("post", "/System/Configuration", token: token, body: configuration, expected: [204])
  end
  current_image_matches = user["PrimaryImageTag"].to_s.length.positive? &&
                          Digest::SHA256.hexdigest(user_image(token, user)) == AVATAR_SHA256
  upload_user_image(token, user_id, AVATAR_PATH.binread) unless current_image_matches

  JELLYFIN_MEDIA_ROOT.join("Series").mkpath
  JELLYFIN_MEDIA_ROOT.join("Unmanaged").mkpath
  JELLYFIN_MEDIA_ROOT.join("Legacy-Series-Extra").mkpath
  (LIBRARIES + [UNMANAGED_LIBRARY]).each do |definition|
    path_matches = folders.select do |candidate|
      Array(candidate["Locations"]).map { |path| normalize_path(path) }.include?(definition.fetch("Path"))
    end
    fail_contract("seed library path #{definition.fetch('Path')} is duplicated") if path_matches.length > 1
    next unless path_matches.empty?

    seed_name = if ENV["PLATFORM_PROOF_LANE"] == "adoption" &&
                   definition.fetch("Name") == "Shows"
                  ADOPTION_SHOWS_SEED_NAME
                else
                  definition.fetch("Name")
                end
    query = URI.encode_www_form(
      "name" => seed_name,
      "collectionType" => definition.fetch("CollectionType"),
      "refreshLibrary" => false
    )
    seed_paths = [definition.fetch("Path")]
    seed_paths << ADOPTION_EXTRA_PATH if ENV["PLATFORM_PROOF_LANE"] == "adoption" &&
                                            definition.fetch("Name") == "Shows"
    request(
      "post", "/Library/VirtualFolders?#{query}", token: token,
      body: { "LibraryOptions" => MANAGED_OPTIONS.merge(
        "PathInfos" => seed_paths.map { |path| { "Path" => path } }
      ) }, expected: [204]
    )
  end
  request("post", "/Library/Refresh", token: token, expected: [204])
  session = authenticate(username, password)
  token = session.fetch("AccessToken")
  user = session.fetch("User")
  folders = libraries(token)
  configuration = server_configuration(token)
end

if MODE == "drift-verify"
  movies = library_by_path(folders, LIBRARIES.fetch(0))
  fail_contract("the Jellyfin identity drift fixture was not installed") unless user.fetch("Name") == "yonatan"
  fail_contract("the Jellyfin server drift fixture was not installed") unless
    configuration.fetch("ServerName") == "Yonflix Drifted"
  fail_contract("the Jellyfin image drift fixture was not installed") unless
    Digest::SHA256.hexdigest(user_image(token, user)) == Digest::SHA256.hexdigest(DRIFT_IMAGE)
  fail_contract("the Jellyfin library drift fixture was not installed") unless
    movies.fetch("Name") == "Movies Drifted" &&
      movies.fetch("LibraryOptions").fetch("EnableRealtimeMonitor") == true &&
      movies.fetch("Locations").include?(DRIFT_EXTRA_PATH)
  puts "Jellyfin identity, branding, image, and library drift is present"
  exit
end

fail_contract("the primary administrator name differs") unless user.fetch("Name") == ADMIN_NAME
fail_contract("the Jellyfin server name differs") unless configuration.fetch("ServerName") == SERVER_NAME
fail_contract("the primary administrator image differs") unless
  user.fetch("PrimaryImageTag").to_s.length.positive? &&
    Digest::SHA256.hexdigest(user_image(token, user)) == AVATAR_SHA256
managed_folders = LIBRARIES.to_h do |definition|
  folder = library_by_path(folders, definition)
  safe_id(folder.fetch("ItemId"))
  if MODE == "seed" && ENV["PLATFORM_PROOF_LANE"] == "adoption" &&
     definition.fetch("Name") == "Shows"
    fail_contract("adoption Shows seed name differs") unless folder.fetch("Name") == ADOPTION_SHOWS_SEED_NAME
    fail_contract("adoption Shows seed paths differ") unless
      folder.fetch("Locations").sort == [definition.fetch("Path"), ADOPTION_EXTRA_PATH].sort
  else
    assert_managed_library(folder, definition)
  end
  [definition.fetch("Name"), folder]
end

if MODE == "drift"
  movies = managed_folders.fetch("Movies")
  temporary_name = "nas-platform-contract-admin-#{user_id[0, 8]}"
  rename_user(token, user, temporary_name)
  rename_user(token, user.merge("Name" => temporary_name), "yonatan")
  configuration["ServerName"] = "Yonflix Drifted"
  request("post", "/System/Configuration", token: token, body: configuration, expected: [204])
  upload_user_image(token, user_id, DRIFT_IMAGE)
  JELLYFIN_MEDIA_ROOT.join("Movies-Drift-Extra").mkpath
  add_library_path(token, movies.fetch("Name"), DRIFT_EXTRA_PATH)
  rename_library(token, movies.fetch("Name"), "Movies Drifted")
  options = movies.fetch("LibraryOptions").merge("EnableRealtimeMonitor" => true)
  request(
    "post", "/Library/VirtualFolders/LibraryOptions", token: token,
    body: { "Id" => movies.fetch("ItemId"), "LibraryOptions" => options }, expected: [204]
  )
  puts "Jellyfin identity, branding, image, and library drift installed"
  exit
end

if MODE == "run"
  unmanaged = library_by_path(folders, UNMANAGED_LIBRARY)
  fail_contract("unmanaged Jellyfin library was not preserved") unless
    unmanaged.fetch("Name") == UNMANAGED_LIBRARY.fetch("Name")
  fail_contract("Jellyfin configuration sentinel was not preserved") unless
    configuration.fetch(CONFIG_SENTINEL_KEY) == CONFIG_SENTINEL_VALUE
  puts "Jellyfin identity, branding, image, capability, and library contract passed"
  exit
end
fail_contract("unknown mode: #{MODE}") unless %w[seed assert-persistence].include?(MODE)

if MODE == "seed"
  fail_contract("seed configuration sentinel was not installed") unless
    configuration.fetch(CONFIG_SENTINEL_KEY) == CONFIG_SENTINEL_VALUE
end

item = find_fixture_item(token, user_id, timeout: MODE == "seed" ? 300 : 120)
item_id = safe_id(item.fetch("Id"))
source_id = safe_id(item.fetch("MediaSources").fetch(0).fetch("Id"))
fail_contract("the fixture runtime differs") unless
  item.fetch("RunTimeTicks") == FIXTURE_RUNTIME_TICKS

assert_direct_play(token, item_id, source_id)
assert_cpu_transcode(token, item_id, source_id) if MODE == "seed"

state = JSON.generate(
  "user_id" => user_id,
  "item_id" => item_id,
  "runtime_ticks" => item.fetch("RunTimeTicks"),
  "library_ids" => managed_folders.transform_values { |folder| safe_id(folder.fetch("ItemId")) },
  "unmanaged_library_id" => safe_id(library_by_path(libraries(token), UNMANAGED_LIBRARY).fetch("ItemId")),
  "config_sentinel" => server_configuration(token).fetch(CONFIG_SENTINEL_KEY)
)

case MODE
when "seed"
  fail_contract("report root is unavailable or unsafe") unless
    REPORT_ROOT.directory? && !REPORT_ROOT.symlink?
  fail_contract("refusing to replace the Jellyfin persistence artifact") if
    STATE_PATH.exist? || STATE_PATH.symlink?
  STATE_PATH.open(File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(state) }
  puts "Jellyfin fixture scanned, direct-played, and CPU transcoded"
when "assert-persistence"
  fail_contract("the Jellyfin persistence artifact is unavailable or unsafe") unless
    STATE_PATH.file? && !STATE_PATH.symlink?
  fail_contract("Jellyfin user, library, or scanned media changed across recreation") unless
    STATE_PATH.binread == state
  puts "Jellyfin user, library, and scanned media persisted"
end
RUBY
