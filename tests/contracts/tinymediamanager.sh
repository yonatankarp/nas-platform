#!/bin/sh
set -eu
set +x

mode=${1:-run}
repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)}
compose=$repo_dir/services/tinymediamanager/compose.yml
mac_compose=$repo_dir/services/tinymediamanager/compose.mac.yml
integration_compose=$repo_dir/services/tinymediamanager/compose.integration.yml
role=$repo_dir/roles/tinymediamanager/tasks/main.yml
defaults=$repo_dir/roles/tinymediamanager/defaults/main.yml

fail_contract() {
  printf 'tinyMediaManager contract failed: %s\n' "$1" >&2
  exit 1
}

[ -f "$role" ] || fail_contract 'roles/tinymediamanager/tasks/main.yml is absent'
[ -f "$defaults" ] || fail_contract 'roles/tinymediamanager/defaults/main.yml is absent'
[ -f "$compose" ] || fail_contract 'services/tinymediamanager/compose.yml is absent'
[ -f "$mac_compose" ] || fail_contract 'services/tinymediamanager/compose.mac.yml is absent'
[ -f "$integration_compose" ] || fail_contract 'services/tinymediamanager/compose.integration.yml is absent'

ruby -ryaml - "$compose" "$mac_compose" "$integration_compose" "$role" "$defaults" <<'RUBY'
compose_path, mac_path, integration_path, role_path, defaults_path = ARGV
compose = YAML.safe_load_file(compose_path, aliases: true)
mac = YAML.safe_load_file(mac_path, aliases: true)
integration = YAML.safe_load_file(integration_path, aliases: true)
role = File.read(role_path)
role_tasks = YAML.safe_load_file(role_path, aliases: true)
defaults = YAML.safe_load_file(defaults_path)
service = compose.fetch("services").fetch("tinymediamanager")
expected_image = "docker.io/tinymediamanager/tinymediamanager:5.3.0@sha256:e33769b278eefbec646b659342a86a7831869c5a3fa3cca97e7c47f518da4d89"
expected_amd64_image = "docker.io/tinymediamanager/tinymediamanager:5.3.0@sha256:ef2b7c248ff2b6b8d30f509f5fa8aaae63508899403f2441da2fd6e2b0a216f6"
abort "tinyMediaManager contract failed: legacy image pin differs" unless service.fetch("image") == expected_image
abort "tinyMediaManager contract failed: NAS host networking differs" unless service.fetch("network_mode") == "host"
abort "tinyMediaManager contract failed: NAS storage contract differs" unless service.fetch("volumes") == [
  "${TINYMEDIAMANAGER_DATA_PATH:?}:/data",
  "${TINYMEDIAMANAGER_MOVIES_PATH:?}:/media/Movies",
  "${TINYMEDIAMANAGER_SERIES_PATH:?}:/media/Series"
]
environment = service.fetch("environment")
abort "tinyMediaManager contract failed: direct VNC must remain disabled" unless environment.fetch("ALLOW_DIRECT_VNC") == "false"
abort "tinyMediaManager contract failed: vault password is not passed to the container" unless
  environment.fetch("PASSWORD") == "${TINYMEDIAMANAGER_PASSWORD:?}"
abort "tinyMediaManager contract failed: restart policy differs" unless service.fetch("restart") == "unless-stopped"
abort "tinyMediaManager contract failed: logging policy differs" unless service.fetch("logging") == {
  "driver" => "json-file", "options" => { "max-size" => "10m", "max-file" => "3" }
}
mac_service = mac.fetch("services").fetch("tinymediamanager")
abort "tinyMediaManager contract failed: Mac override must replace host networking" unless
  mac_service.fetch("network_mode") == "bridge" &&
    mac_service.fetch("image") == expected_amd64_image &&
    mac_service.fetch("platform") == "linux/amd64" && mac_service.fetch("ports").sort == [
    "${TINYMEDIAMANAGER_API_HOST_PORT:?}:7878",
    "${TINYMEDIAMANAGER_WEB_HOST_PORT:?}:4000"
  ].sort
abort "tinyMediaManager contract failed: Mac override must not publish direct VNC" if
  mac_service.fetch("ports").any? { |port| port.end_with?(":5900") }
integration_service = integration.fetch("services").fetch("tinymediamanager")
abort "tinyMediaManager contract failed: integration must select the canonical amd64 child" unless
  integration_service.fetch("image") == expected_amd64_image &&
    integration_service.fetch("platform") == "linux/amd64"
# The application binds the container side of the published mapping. If the role
# instead wrote the host port into httpServerPort, the mapping would forward to a
# port nothing listens on and every API call would be reset.
mac_api_container_port = mac_service.fetch("ports")
  .find { |port| port.start_with?("${TINYMEDIAMANAGER_API_HOST_PORT:?}:") }.to_s.split(":").last
abort "tinyMediaManager contract failed: bound API port must be the published container port" unless
  defaults.fetch("tinymediamanager_api_container_port").to_s == mac_api_container_port
abort "tinyMediaManager contract failed: movie source differs" unless
  defaults.fetch("tinymediamanager_movie_source") == "/media/Movies"
abort "tinyMediaManager contract failed: series source differs" unless
  defaults.fetch("tinymediamanager_series_source") == "/media/Series"
video_file_types = defaults.fetch("tinymediamanager_video_file_types")
abort "tinyMediaManager contract failed: first-run video types omit MP4 or MKV" unless
  %w[.mp4 .mkv].all? { |extension| video_file_types.include?(extension) }

required_tasks = [
  "Provision stable tinyMediaManager first-run settings",
  "Require the installed tinyMediaManager VNC password",
  "Require tinyMediaManager movie and series data sources",
  "Require tinyMediaManager metadata writing settings"
]
required_tasks.each do |name|
  abort "tinyMediaManager contract failed: missing #{name}" unless role.include?("- name: #{name}")
end
settings_task = role_tasks.find do |task|
  task["name"] == "Provision stable tinyMediaManager first-run settings"
end
semantic_guard = "tinymediamanager_existing_settings.get(item.key, {}) != item.value"
abort "tinyMediaManager contract failed: semantically stable settings must not be rewritten" unless
  Array(settings_task&.fetch("when", nil)).include?(semantic_guard)
abort "tinyMediaManager contract failed: role must not edit an opaque database" if
  role.match?(/execute.*sql|sqlite3|\.db\b|mviedb|tvshowdb/i)
RUBY

[ "$mode" = static ] && { printf '%s\n' 'tinyMediaManager static contract passed'; exit 0; }
. "${PLATFORM_LEGACY_FIXTURE_HELPER_FILE:-$repo_dir/tests/contracts/legacy-fixture-paths.sh}"
legacy_fixture_validate PLATFORM_TINYMEDIAMANAGER_MOVIES_ROOT legacy/tinymediamanager/movies ||
  fail_contract 'legacy movies root is unsafe'
legacy_fixture_validate PLATFORM_TINYMEDIAMANAGER_SERIES_ROOT legacy/tinymediamanager/series ||
  fail_contract 'legacy series root is unsafe'
legacy_fixture_validate PLATFORM_TINYMEDIAMANAGER_SETTINGS_ROOT legacy/tinymediamanager/data/data ||
  fail_contract 'legacy settings root is unsafe'

: "${PLATFORM_CONTRACT_VAULT_FILE:=${PLATFORM_MAC_VAULT_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:=${PLATFORM_MAC_VAULT_PASSWORD_FILE:-}}"
: "${PLATFORM_MEDIA_ROOT:?}"
: "${PLATFORM_REPORT_ROOT:?}"
: "${PLATFORM_DOCKER_ROOT:?}"
: "${PLATFORM_TINYMEDIAMANAGER_API_PORT:=7878}"
if [ -z "${PLATFORM_TINYMEDIAMANAGER_CONTAINER:-}" ]; then
  PLATFORM_TINYMEDIAMANAGER_CONTAINER=${PLATFORM_PROJECT_NAME:+$PLATFORM_PROJECT_NAME-}tinymediamanager
fi
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
export PLATFORM_MEDIA_ROOT PLATFORM_REPORT_ROOT PLATFORM_DOCKER_ROOT
export PLATFORM_TINYMEDIAMANAGER_API_PORT PLATFORM_TINYMEDIAMANAGER_CONTAINER

shift || true
exec ruby - "$mode" "$@" <<'RUBY'
require "digest"
require "json"
require "net/http"
require "open3"
require "pathname"
require "timeout"
require "uri"
require "yaml"

MODE = ARGV.fetch(0)
MEDIA_ROOT = Pathname.new(ENV.fetch("PLATFORM_MEDIA_ROOT")).expand_path
REPORT_ROOT = Pathname.new(ENV.fetch("PLATFORM_REPORT_ROOT")).expand_path
CONTAINER = ENV.fetch("PLATFORM_TINYMEDIAMANAGER_CONTAINER")
MOVIES_ROOT = Pathname.new(
  ENV.fetch("PLATFORM_TINYMEDIAMANAGER_MOVIES_ROOT", MEDIA_ROOT.join("Media", "Movies").to_s)
).expand_path
SERIES_ROOT = Pathname.new(
  ENV.fetch("PLATFORM_TINYMEDIAMANAGER_SERIES_ROOT", MEDIA_ROOT.join("Media", "Series").to_s)
).expand_path
MOVIE_DIRECTORY = MOVIES_ROOT.join("Task 10 Contract Movie (2024)")
MOVIE_FILE = MOVIE_DIRECTORY.join("Task 10 Contract Movie (2024).mp4")
SERIES_DIRECTORY = SERIES_ROOT.join("Task 10 Contract Series", "Season 01")
SERIES_FILE = SERIES_DIRECTORY.join("Task 10 Contract Series - S01E01.mp4")
STATE_PATH = REPORT_ROOT.join("tinymediamanager-persistence.sha256")
SETTINGS_ROOT = Pathname.new(
  ENV.fetch(
    "PLATFORM_TINYMEDIAMANAGER_SETTINGS_ROOT",
    Pathname.new(ENV.fetch("PLATFORM_DOCKER_ROOT")).expand_path.join("tinymediamanager", "data", "data").to_s
  )
).expand_path
API = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_TINYMEDIAMANAGER_API_PORT'), 10)}")
VIDEO_FIXTURE = (
  "AAAAJGZ0eXBpc29tAAACAGlzb21pc282aXNvMmF2YzFtcDQxAAAC7W1vb3YAAABsbXZoZAAAAAAA" \
  "AAAAAAAAAAAAA+gAAAAAAAEAAAEAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAA" \
  "AAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAAAHvdHJhawAAAFx0a2hkAAAA" \
  "AwAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAA" \
  "AAAAAAAAAAAAAAAAQAAAAAAQAAAAEAAAAAABi21kaWEAAAAgbWRoZAAAAAAAAAAAAAAAAAAAMgAAAAAA" \
  "VcQAAAAAAC1oZGxyAAAAAAAAAAB2aWRlAAAAAAAAAAAAAAAAVmlkZW9IYW5kbGVyAAAAATZtaW5m" \
  "AAAAFHZtaGQAAAABAAAAAAAAAAAAAAAkZGluZgAAABxkcmVmAAAAAAAAAAEAAAAMdXJsIAAAAAEA" \
  "AAD2c3RibAAAAKpzdHNkAAAAAAAAAAEAAACaYXZjMQAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAQ" \
  "ABAASAAAAEgAAAAAAAAAARVMYXZjNjIuMjguMTAyIGxpYngyNjQAAAAAAAAAAAAAABj//wAAADRh" \
  "dmNDAWQACv/hABdnZAAKrNlewEQAAAMABAAAAwDIPEiWWAEABmjr48siwP34+AAAAAAQcGFzcAAA" \
  "AAEAAAABAAAAEHN0dHMAAAAAAAAAAAAAABBzdHNjAAAAAAAAAAAAAAAUc3RzegAAAAAAAAAAAAAA" \
  "AAAAABBzdGNvAAAAAAAAAAAAAAAobXZleAAAACB0cmV4AAAAAAAAAAEAAAABAAAAAAAAAAAAAAAA" \
  "AAAAYnVkdGEAAABabWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAt" \
  "aWxzdAAAACWpdG9vAAAAHWRhdGEAAAABAAAAAExhdmY2Mi4xMi4xMDIAAABwbW9vZgAAABBtZmhk" \
  "AAAAAAAAAAEAAABYdHJhZgAAACR0ZmhkAAAAOQAAAAEAAAAAAAADEQAAAgAAAALFAQEAAAAAABR0" \
  "ZmR0AQAAAAAAAAAAAAAAAAAAGHRydW4AAAAFAAAAAQAAAHgCAAAAAAACzW1kYXQAAAKuBgX//6rc" \
  "Rem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY1IHIzMjIyIGIzNTYwNWEgLSBILjI2NC9NUEVH" \
  "LTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0cDovL3d3dy52aWRlb2xhbi5v" \
  "cmcveDI2NC5odG1sIC0gb3B0aW9uczogY2FiYWM9MSByZWY9MyBkZWJsb2NrPTE6MDowIGFuYWx5" \
  "c2U9MHgzOjB4MTEzIG1lPWhleCBzdWJtZT03IHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRf" \
  "cmVmPTEgbWVfcmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0xIDh4OGRjdD0xIGNxbT0wIGRl" \
  "YWR6b25lPTIxLDExIGZhc3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zmc2V0PS0yIHRocmVhZHM9MSBs" \
  "b29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVy" \
  "bGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTMgYl9w" \
  "eXJhbWlkPTIgYl9hZGFwdD0xIGJfYmlhcz0wIGRpcmVjdD0xIHdlaWdodGI9MSBvcGVuX2dvcD0w" \
  "IHdlaWdodHA9MiBrZXlpbnQ9MjUwIGtleWludF9taW49MjUgc2NlbmVjdXQ9NDAgaW50cmFfcmVm" \
  "cmVzaD0wIHJjX2xvb2thaGVhZD00MCByYz1jcmYgbWJ0cmVlPTEgY3JmPTIzLjAgcWNvbXA9MC42" \
  "MCBxcG1pbj0wIHFwbWF4PTY5IHFwc3RlcD00IGlwX3JhdGlvPTEuNDAgYXE9MToxLjAwAIAAAAAP" \
  "ZYiEACv//vZzfAprbbGBAAAAQ21mcmEAAAArdGZyYQEAAAAAAAABAAAAAAAAAAEAAAAAAAAAAAAA" \
  "AAAAAAMRAQEBAAAAEG1mcm8AAAAAAAAAQw=="
).unpack1("m0").freeze

def fail_contract(message)
  warn "tinyMediaManager contract failed: #{message}"
  exit 1
end

def docker_exec(*arguments)
  stdout, stderr, status = Open3.capture3("docker", "exec", CONTAINER, *arguments)
  fail_contract("tinyMediaManager command failed") unless status.success?
  [stdout, stderr]
end

def seed_file(path, contents)
  path.dirname.mkpath
  # tinyMediaManager writes its metadata next to the media, as an unprivileged
  # user. On the NAS that is permitted by the NAS's own permission controls: the
  # play is explicitly forbidden from declaring ownership under the media root,
  # so nothing in the deployment grants it. A sandbox created by whoever ran the
  # harness has no such controls and the directory ends up unwritable, which
  # Docker Desktop hides by remapping bind-mount ownership. Grant it here, where
  # the fixture is made, rather than teaching the play to claim media it does not
  # own.
  path.dirname.chmod(0o777)
  if path.exist?
    fail_contract("fixture file drifted: #{path.basename}") unless path.file? && path.binread == contents
  else
    path.open(File::WRONLY | File::CREAT | File::EXCL, 0o644) { |file| file.write(contents) }
  end
end

def post_api(path, password, body, expected: [200], allow_closed_connection: false)
  uri = URI.join(API.to_s, path)
  request = Net::HTTP::Post.new(uri)
  request["api-key"] = password
  request["Content-Type"] = "application/json"
  request.body = JSON.generate(body)
  response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 30) do |http|
    http.request(request)
  end
  fail_contract("tinyMediaManager API #{path} returned HTTP #{response.code}") unless
    expected.include?(response.code.to_i)
  response
rescue EOFError
  fail_contract("tinyMediaManager API #{path} closed the connection") unless allow_closed_connection
  nil
rescue SystemCallError, Timeout::Error => error
  fail_contract("tinyMediaManager API #{path} failed: #{error.class}")
end

def deep_sorted(value)
  case value
  when Hash then value.keys.sort.to_h { |key| [key, deep_sorted(value.fetch(key))] }
  when Array then value.map { |element| deep_sorted(element) }
  else value
  end
end

def metadata_paths
  # Pinned 5.3.0 reloadMediaInfo writes NFOs for entities that own video files,
  # and its HTTP API exposes no action that writes a series-root tvshow.nfo.
  [
    MOVIE_FILE.sub_ext(".nfo"),
    SERIES_DIRECTORY.join("Task 10 Contract Series - S01E01.nfo")
  ]
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
password = vault.fetch("vault_tinymediamanager_password")

installed_password, installed_error, installed_status = Open3.capture3(
  "docker", "exec", CONTAINER, "cat", "/app/.vnc/passwd"
)
expected_password, expected_error, expected_status = Open3.capture3(
  "docker", "exec", "-i", CONTAINER, "tigervncpasswd", "-f",
  stdin_data: "#{password}\n"
)
wrong_password, wrong_error, wrong_status = Open3.capture3(
  "docker", "exec", "-i", CONTAINER, "tigervncpasswd", "-f",
  stdin_data: "contract-wrong-password\n"
)
fail_contract("installed VNC password could not be inspected") unless installed_status.success?
fail_contract("vault VNC password could not be encoded") unless expected_status.success?
fail_contract("wrong VNC password could not be encoded") unless wrong_status.success?
fail_contract("vault password was not installed for VNC") unless
  installed_password == expected_password && installed_password != wrong_password
[installed_password, installed_error, expected_password, expected_error, wrong_password, wrong_error].each do |value|
  value.replace("\0" * value.bytesize)
end

inspect_json, inspect_error, inspect_status = Open3.capture3("docker", "inspect", CONTAINER)
fail_contract("container network state could not be inspected") unless inspect_status.success?
inspect = JSON.parse(inspect_json).fetch(0)
inspect_json.replace("\0" * inspect_json.bytesize)
inspect_error.replace("\0" * inspect_error.bytesize)
ports = inspect.dig("NetworkSettings", "Ports") || {}
fail_contract("direct VNC was published") if ports.fetch("5900/tcp", []).to_a.any?
processes, process_error, process_status = Open3.capture3("docker", "exec", CONTAINER, "ps", "ww", "-eo", "args")
fail_contract("VNC process state could not be inspected") unless process_status.success?
fail_contract("direct VNC is not restricted to localhost") unless
  processes.lines.any? { |line| line.include?("Xtigervnc") && line.include?("-localhost") }
processes.replace("\0" * processes.bytesize)
process_error.replace("\0" * process_error.bytesize)

tmm_settings = JSON.parse(SETTINGS_ROOT.join("tmm.json").binread)
fail_contract("MP4 or MKV scanning is disabled") unless
  %w[.mp4 .mkv].all? { |extension| tmm_settings.fetch("videoFileType").include?(extension) }

if MODE == "drift" || MODE == "drift-verify"
  movies_path = SETTINGS_ROOT.join("movies.json")
  fail_contract("stable movie settings are unavailable or unsafe") unless movies_path.file? && !movies_path.symlink?
  movies = JSON.parse(movies_path.binread)
  if MODE == "drift"
    fail_contract("movie source was already drifted") unless movies.fetch("movieDataSource") == ["/media/Movies"]
    movies["movieDataSource"] = ["/media/Drifted"]
    movies_path.open(File::WRONLY | File::TRUNC) { |file| file.write(JSON.pretty_generate(movies) + "\n") }
    puts "tinyMediaManager source drift installed"
  else
    fail_contract("tinyMediaManager drift fixture was not installed") unless
      movies.fetch("movieDataSource") == ["/media/Drifted"]
    puts "tinyMediaManager source drift is present"
  end
  exit
end

if MODE == "run"
  puts "tinyMediaManager vault password, sources, and metadata settings contract passed"
  exit
end
fail_contract("unknown mode: #{MODE}") unless %w[seed assert-persistence].include?(MODE)

if MODE == "seed"
  seed_file(MOVIE_FILE, VIDEO_FIXTURE)
  seed_file(SERIES_FILE, VIDEO_FIXTURE)
  authentication_deadline = Time.now + 120
  authentication_response = nil
  until authentication_response
    authentication_response = post_api(
      "/api/movie", "contract-wrong-password", { "action" => "update" },
      expected: [403], allow_closed_connection: true
    )
    fail_contract("tinyMediaManager API contexts did not become ready") if
      !authentication_response && Time.now >= authentication_deadline
    sleep 2 unless authentication_response
  end
  commands = [
    { "action" => "update", "scope" => { "name" => "all" } },
    { "action" => "reloadMediaInfo", "scope" => { "name" => "all" } }
  ]
  post_api("/api/movie", password, commands)
  post_api("/api/tvshow", password, commands)
end

# How long the scan takes is a property of the machine, not of the deployment, so
# allow generous time and make it tunable. Both documents are written at the end of
# the scan, so their absence alone cannot separate a slow scan from one that never
# saw the fixtures. On timeout, report what the application actually sees: whether
# the media is readable to the user it runs as, and whether the scan produced any
# entities at all. Diagnostics must never fail the run themselves.
metadata_timeout = Integer(ENV.fetch("PLATFORM_TINYMEDIAMANAGER_METADATA_TIMEOUT", "600"), 10)

def scan_diagnostics
  report, = Open3.capture3(
    "docker", "exec", CONTAINER, "sh", "-c",
    "echo '# application processes'; ps -eo user,args | grep -i '[t]inyMediaManager' | head -3; " \
    "echo '# mount ownership and modes'; ls -lnd /media /media/Movies /media/Series; " \
    "echo '# fixtures the container can see'; find /media -maxdepth 5 -type f -exec ls -ln {} + 2>&1 | head"
  )
  warn "tinyMediaManager scan diagnostics:\n#{report.gsub(/^/, '  ')}"
rescue StandardError => error
  warn "tinyMediaManager scan diagnostics unavailable: #{error.class}"
end

deadline = Time.now + metadata_timeout
until metadata_paths.all? { |path| path.file? && path.size.positive? }
  if Time.now >= deadline
    missing = metadata_paths.reject { |path| path.file? && path.size.positive? }
    scan_diagnostics
    fail_contract("tinyMediaManager did not write all fixture metadata within " \
                  "#{metadata_timeout}s; still missing: #{missing.map(&:basename).join(', ')}")
  end
  sleep 2
end
metadata = metadata_paths.map { |path| [path.to_s, Digest::SHA256.file(path).hexdigest] }
# Metadata stays byte-exact because only the application writes it. Settings do
# not: the application writes them in its own format, and the role rewrites them
# with to_nice_json when it repairs drift, so between seeding and this assertion
# the same values legitimately change indentation. Compare the parsed documents
# instead, which still fails if a value is lost across recreation. Array order is
# preserved because it carries meaning for the data sources and video types.
settings_paths = docker_exec(
  "sh", "-c", "find /data -maxdepth 2 -type f -name '*.json' -print"
).first.split("\n").reject(&:empty?).sort
fail_contract("stable tinyMediaManager settings were not found") if settings_paths.empty?
settings = settings_paths.map do |path|
  document = JSON.parse(docker_exec("cat", path).first)
  [path, JSON.generate(deep_sorted(document))]
end
fingerprint = Digest::SHA256.hexdigest(Marshal.dump([metadata, settings]))

case MODE
when "seed"
  fail_contract("report root is unavailable or unsafe") unless REPORT_ROOT.directory? && !REPORT_ROOT.symlink?
  fail_contract("refusing to replace tinyMediaManager persistence artifact") if STATE_PATH.exist? || STATE_PATH.symlink?
  STATE_PATH.open(File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(fingerprint) }
  puts "tinyMediaManager Movies and Series fixtures scanned and metadata written"
when "assert-persistence"
  fail_contract("tinyMediaManager persistence artifact is unavailable or unsafe") unless STATE_PATH.file? && !STATE_PATH.symlink?
  fail_contract("tinyMediaManager settings or metadata changed across recreation") unless STATE_PATH.binread == fingerprint
  puts "tinyMediaManager settings and written metadata persisted"
end
RUBY
