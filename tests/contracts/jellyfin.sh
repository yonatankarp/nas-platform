#!/bin/sh
set -eu
set +x

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
compose=$repo_dir/services/jellyfin/compose.yml
role=$repo_dir/roles/jellyfin/tasks/main.yml
defaults=$repo_dir/roles/jellyfin/defaults/main.yml

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

ruby -ryaml - "$repo_dir" "$platform" <<'RUBY'
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
refuse("managed library root differs") unless
  defaults.fetch("jellyfin_library_path_infos") == [{ "Path" => "/media/Movies" }]
refuse("managed library collection type differs") unless
  defaults.fetch("jellyfin_library_collection_type") == "movies"
refuse("managed library must not write metadata into read-only media") unless
  defaults.fetch("jellyfin_library_options").fetch("SaveLocalMetadata") == false

role = File.read(File.join(root, "roles", "jellyfin", "tasks", "main.yml"))
required_tasks = [
  "Wait for the Jellyfin startup API",
  "Read Jellyfin startup state",
  "Materialize the Jellyfin first user",
  "Create the vault Jellyfin administrator",
  "Complete the Jellyfin startup wizard",
  "Refuse duplicate managed Jellyfin libraries",
  "Create the managed Jellyfin library",
  "Repair the managed Jellyfin library",
  "Require the vault Jellyfin administrator",
  "Require exactly the managed Jellyfin library"
]
required_tasks.each do |name|
  refuse("missing #{name}") unless role.include?("- name: #{name}")
end
refuse("role must not edit an opaque database") if
  role.match?(/sqlite|library\.db|jellyfin\.db/i)
puts "Jellyfin static contract passed (#{platform})"
RUBY

[ "$mode" = static ] && exit 0

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
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
export PLATFORM_MEDIA_ROOT PLATFORM_DOCKER_ROOT PLATFORM_REPORT_ROOT
export PLATFORM_JELLYFIN_PORT PLATFORM_JELLYFIN_CONTAINER PLATFORM_JELLYFIN_PLATFORM

exec ruby - "$mode" "$@" <<'RUBY'
require "base64"
require "json"
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

LIBRARY_NAME = "Movies"
LIBRARY_COLLECTION_TYPE = "movies"
LIBRARY_PATH = "/media/Movies"
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
FIXTURE_DIRECTORY = MEDIA_ROOT.join("Media", "Movies", "Task 11 Contract Movie (2026)")
FIXTURE_PATH = FIXTURE_DIRECTORY.join("Task 11 Contract Movie (2026).mp4")
FIXTURE_LIBRARY_PATH = "#{LIBRARY_PATH}/Task 11 Contract Movie (2026)/Task 11 Contract Movie (2026).mp4"
FIXTURE_RUNTIME_TICKS = 40_000_000

# Four seconds of 64x48 H.264 produced by the pinned image's own ffmpeg with
# bitexact flags, so regenerating it yields these exact bytes. Small enough to
# transcode instantly and long enough to split into two HLS segments.
VIDEO_FIXTURE = Base64.decode64(
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
).freeze

CLIENT = 'MediaBrowser Client="nas-platform-contract", Device="contract", ' \
         'DeviceId="nas-platform-jellyfin-contract", Version="1.0.0"'

def fail_contract(message)
  warn "Jellyfin contract failed: #{message}"
  exit 1
end

def request(method, path, token: nil, body: nil, expected: [200], headers: {}, raw: false)
  uri = URI.join(BASE.to_s, path)
  request = Net::HTTP.const_get(method.capitalize).new(uri)
  request["Authorization"] = token ? %(#{CLIENT}, Token="#{token}") : CLIENT
  headers.each { |name, value| request[name] = value }
  if body
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body)
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

def managed_library(token)
  _response, folders = request("get", "/Library/VirtualFolders", token: token)
  managed = folders.select { |folder| folder["Name"] == LIBRARY_NAME }
  fail_contract("managed library is absent or duplicated") unless managed.length == 1
  managed.fetch(0)
end

def canonical_library(folder)
  options = folder.fetch("LibraryOptions")
  JSON.generate(
    "Name" => folder.fetch("Name"),
    "CollectionType" => folder.fetch("CollectionType"),
    "Locations" => folder.fetch("Locations").sort,
    "PathInfos" => options.fetch("PathInfos").map { |info| info.fetch("Path") }.sort,
    "Options" => MANAGED_OPTIONS.keys.sort.to_h { |key| [key, options[key]] }
  )
end

def assert_managed_library(folder)
  fail_contract("managed library collection type differs") unless
    folder.fetch("CollectionType") == LIBRARY_COLLECTION_TYPE
  fail_contract("managed library locations differ") unless
    folder.fetch("Locations") == [LIBRARY_PATH]
  options = folder.fetch("LibraryOptions")
  fail_contract("managed library paths differ") unless
    options.fetch("PathInfos").map { |info| info.fetch("Path") } == [LIBRARY_PATH]
  MANAGED_OPTIONS.each do |key, value|
    fail_contract("managed library option #{key} differs") unless options[key] == value
  end
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
  query = "userId=#{user_id}&recursive=true&includeItemTypes=Movie&fields=Path,MediaSources"
  loop do
    _response, payload = request("get", "/Items?#{query}", token: token)
    items = payload.fetch("Items")
    found = items.find { |item| item["Path"] == FIXTURE_LIBRARY_PATH }
    return found if found

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
    "get", path, token: token, raw: true, headers: { "Range" => "bytes=0-127" }
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
  transcode_root = DOCKER_ROOT.join("jellyfin", "cache", "transcodes")
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

wait_for_application
request(
  "post", "/Users/AuthenticateByName",
  body: { "Username" => username, "Pw" => "contract-wrong-password" }, expected: [401]
)
session = authenticate(username, password)
token = session.fetch("AccessToken")
user = session.fetch("User")
user_id = safe_id(user.fetch("Id"))
fail_contract("the vault administrator identity or role differs") unless
  user.fetch("Name") == username && user.dig("Policy", "IsAdministrator") == true

assert_container_capabilities
folder = managed_library(token)
safe_id(folder.fetch("ItemId"))

if MODE == "drift-verify"
  fail_contract("the Jellyfin drift fixture was not installed") unless
    folder.fetch("LibraryOptions").fetch("EnableRealtimeMonitor") == true
  puts "Jellyfin library drift is present"
  exit
end

assert_managed_library(folder)

if MODE == "drift"
  options = folder.fetch("LibraryOptions").merge("EnableRealtimeMonitor" => true)
  request(
    "post", "/Library/VirtualFolders/LibraryOptions", token: token,
    body: { "Id" => folder.fetch("ItemId"), "LibraryOptions" => options }, expected: [204]
  )
  puts "Jellyfin library drift installed"
  exit
end

if MODE == "run"
  puts "Jellyfin login, capability, and library contract passed"
  exit
end
fail_contract("unknown mode: #{MODE}") unless %w[seed assert-persistence].include?(MODE)

if MODE == "seed"
  seed_fixture
  request("post", "/Library/Refresh", token: token, expected: [204])
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
  "library" => canonical_library(folder)
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
