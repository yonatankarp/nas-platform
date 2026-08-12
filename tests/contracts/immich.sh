#!/bin/sh
set -eu
set +x

repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)}
compose=$repo_dir/services/immich/compose.yml
role=$repo_dir/roles/immich/tasks/main.yml
defaults=$repo_dir/roles/immich/defaults/main.yml

fail_contract() {
  printf 'Immich contract failed: %s\n' "$1" >&2
  exit 1
}

usage() {
  printf '%s\n' 'usage: immich.sh [--platform mac|nas|integration] [MODE]' >&2
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

[ -f "$role" ] || fail_contract 'roles/immich/tasks/main.yml is absent'
[ -f "$defaults" ] || fail_contract 'roles/immich/defaults/main.yml is absent'
[ -f "$compose" ] || fail_contract 'services/immich/compose.yml is absent'

ruby -ryaml - "$repo_dir" "$platform" <<'RUBY'
root, platform = ARGV
compose_path = File.join(root, "services", "immich", "compose.yml")
compose = YAML.safe_load_file(compose_path, aliases: true)
containers = compose.fetch("services")

def refuse(message)
  abort "Immich contract failed: #{message}"
end

# The complete pinned stack. Immich is one application spread across four
# containers, so a partial migration is a broken migration.
EXPECTED_IMAGES = {
  "immich-server" =>
    "ghcr.io/immich-app/immich-server:v3.1.0@" \
    "sha256:b434cb9287eea1471c9974845914d4dd328c9c2d652e446ed4930f99944f0ceb",
  "immich-machine-learning" =>
    "ghcr.io/immich-app/immich-machine-learning:v3.1.0@" \
    "sha256:5a0839dc5303cd7215bcd2180a26aed3af41675aefb3e75e5157e9f10ad16e6e",
  "redis" =>
    "docker.io/valkey/valkey:9@" \
    "sha256:3acc0687f2a2e1091fae6450d7842dd658c941338cf0a873ddd9e14b9e4ea4dd",
  "database" =>
    "ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0@" \
    "sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23"
}.freeze

refuse("stack composition differs: #{containers.keys.sort.join(', ')}") unless
  containers.keys.sort == EXPECTED_IMAGES.keys.sort
EXPECTED_IMAGES.each do |name, image|
  refuse("#{name} legacy image pin differs") unless containers.fetch(name).fetch("image") == image
end

containers.each do |name, spec|
  refuse("#{name} restart policy differs") unless spec.fetch("restart") == "unless-stopped"
  refuse("#{name} logging policy differs") unless spec.fetch("logging") == {
    "driver" => "json-file", "options" => { "max-size" => "10m", "max-file" => "3" }
  }
end

server = containers.fetch("immich-server")
refuse("NAS port differs") unless server.fetch("ports") == ["2283:2283"]

# Only the application is reachable. The database, the cache and the machine
# learning helper are reached over the Compose network and must never publish a
# host port, on any platform.
%w[immich-machine-learning redis database].each do |name|
  refuse("#{name} must not publish a host port") if containers.fetch(name).key?("ports")
end

# The nested bind layout of the source deployment. /data holds the originals on
# the media volume, while the regenerable and profile trees are redirected onto
# the Docker root. Both roots are parameterized so the storage inventory
# cross-check in tests/policy_test.rb applies to every Docker-root path.
refuse("storage contract differs") unless server.fetch("volumes") == [
  "${NAS_MEDIA_ROOT:?}/Immich:/data",
  "${NAS_DOCKER_ROOT:?}/immich/data/thumbs:/data/thumbs",
  "${NAS_DOCKER_ROOT:?}/immich/data/encoded-video:/data/encoded-video",
  "${NAS_DOCKER_ROOT:?}/immich/data/profile:/data/profile",
  "${NAS_MEDIA_ROOT:?}/Immich-backups/database:/data/backups"
]
refuse("model cache storage differs") unless
  containers.fetch("immich-machine-learning").fetch("volumes") ==
  ["${NAS_DOCKER_ROOT:?}/immich/data/model-cache:/cache"]
refuse("database storage differs") unless
  containers.fetch("database").fetch("volumes") ==
  ["${NAS_DOCKER_ROOT:?}/immich/postgres:/var/lib/postgresql/data"]

# The application must not start against an uninitialized database or cache;
# both are declared healthy-gated in the source definition.
refuse("startup ordering differs") unless server.fetch("depends_on") == {
  "redis" => { "condition" => "service_healthy" },
  "database" => { "condition" => "service_healthy" }
}
%w[immich-server immich-machine-learning database].each do |name|
  refuse("#{name} health check is disabled") if
    containers.fetch(name).fetch("healthcheck").fetch("disable", false)
end
refuse("cache health check is absent") unless
  containers.fetch("redis").fetch("healthcheck").key?("test")

database = containers.fetch("database")
refuse("database shared memory differs") unless database.fetch("shm_size") == "128mb"
refuse("database checksums are not requested") unless
  database.fetch("environment").fetch("POSTGRES_INITDB_ARGS") == "--data-checksums"

# The NAS-only capability contract. Hardware transcoding is the production
# capability and must never be weakened to make another platform work.
refuse("NAS render device mapping is absent") unless
  server.fetch("devices") == ["/dev/dri:/dev/dri"]

# Every platform that lacks /dev/dri must remove the device explicitly. Compose
# appends sequences, so a bare empty list would silently keep the NAS device:
# the !override tag is what actually replaces it.
override_path = File.join(root, "services", "immich", "compose.#{platform}.yml")
if platform == "nas"
  refuse("the NAS runs the production definition unmodified") if File.exist?(override_path)
else
  refuse("services/immich/compose.#{platform}.yml is absent") unless File.file?(override_path)
  override_text = File.read(override_path)
  override = YAML.safe_load_file(override_path, aliases: true)
  override_containers = override.fetch("services")
  surplus_services = override_containers.keys - EXPECTED_IMAGES.keys
  refuse("#{platform} override may not add services: #{surplus_services.join(', ')}") unless
    surplus_services.empty?
  override_server = override_containers.fetch("immich-server")
  refuse("#{platform} override must reset devices with an explicit tag") unless
    override_text.match?(/^\s+devices: !override(\s|$)/)
  refuse("#{platform} override must reset devices to empty") unless
    override_server.fetch("devices") == []
  override_containers.each do |name, spec|
    surplus = spec.keys - %w[container_name devices ports]
    refuse("#{platform} override may not redefine #{surplus.join(', ')} on #{name}") unless
      surplus.empty?
    refuse("#{platform} override must not redefine the #{name} image") if spec.key?("image")
    # Renaming a Compose service would break machineLearning.urls, which Immich
    # stores as http://immich-machine-learning:3003. Only container_name moves.
    refuse("#{platform} override must not publish a host port on #{name}") if
      spec.key?("ports") && name != "immich-server"
  end
  if override_server.key?("ports")
    refuse("#{platform} override must replace published ports with an explicit tag") unless
      override_text.match?(/^\s+ports: !override(\s|$)/)
  end
end

defaults = YAML.safe_load_file(File.join(root, "roles", "immich", "defaults", "main.yml"))
settings = defaults.fetch("immich_managed_settings")
refuse("managed settings must disable the outbound version check") unless
  settings.dig("newVersionCheck", "enabled") == false
refuse("managed settings must keep machine learning enabled") unless
  settings.dig("machineLearning", "enabled") == true
refuse("managed settings must keep the database backup enabled") unless
  settings.dig("backup", "database", "enabled") == true

expected_standard_preferences = {
  "albums" => { "defaultAssetOrder" => "desc" },
  "avatar" => { "color" => "primary" },
  "cast" => { "gCastEnabled" => false },
  "download" => { "archiveSize" => 4_294_967_296, "includeEmbeddedVideos" => false },
  "emailNotifications" => { "enabled" => true, "albumInvite" => true, "albumUpdate" => true },
  "folders" => { "enabled" => false, "sidebarWeb" => false },
  "memories" => { "enabled" => true, "duration" => 5 },
  "people" => { "enabled" => true, "sidebarWeb" => false, "minimumFaces" => 3 },
  "purchase" => {
    "showSupportBadge" => true, "hideBuyButtonUntil" => "2022-02-12T00:00:00.000Z"
  },
  "ratings" => { "enabled" => false },
  "recentlyAdded" => { "sidebarWeb" => false },
  "sharedLinks" => { "enabled" => true, "sidebarWeb" => false },
  "tags" => { "enabled" => false, "sidebarWeb" => false }
}.freeze
refuse("standard managed-user preference profile differs from pinned v3.1.0 policy") unless
  defaults.dig("immich_managed_user_preference_profiles", "standard") == expected_standard_preferences
refuse("production inventory must not select the test-only compact profile") unless
  defaults.fetch("immich_managed_user_preference_profile_by_email").empty? &&
  defaults.fetch("immich_managed_user_preference_overrides").empty? &&
  defaults.fetch("immich_managed_user_preference_profiles").keys == ["standard"]
contract_source = File.read(File.join(root, "tests", "contracts", "immich.sh"))
refuse("runtime contract permits a dormant supported preference sentinel") unless
  contract_source.include?(
    "designated partial profile has no supported unowned preference sentinel"
  ) && contract_source.include?("supported unowned managed preference")

managed_user_tasks = YAML.safe_load_file(
  File.join(root, "roles", "immich", "tasks", "managed_users.yml"), aliases: true
)
managed_task = lambda do |name|
  managed_user_tasks.find { |task| task["name"] == name }
end
preference_read = managed_task.call("Read Immich managed user preferences")
preference_repair = managed_task.call("Repair Immich managed user preferences")
preference_verify = managed_task.call("Verify exact Immich managed user preferences")
avatar_repair = managed_task.call("Repair Immich managed user avatar preference")
avatar_verify = managed_task.call("Verify exact Immich managed user avatar preference")
user_read = managed_task.call("Read Immich managed user avatar preferences")
preference_guard = managed_task.call("Require supported Immich managed user preference responses")
user_guard = managed_task.call("Require supported Immich managed user avatar responses")
nonadmin_guard = managed_task.call("Require non-administrator Immich managed preference targets")
refuse("managed user preference non-administrator guard is absent") unless
  nonadmin_guard&.dig("ansible.builtin.assert", "that").to_s.include?("isAdmin")
refuse("managed user preference read is absent") unless preference_read
refuse("managed user preference read does not address a target through the admin API") unless
  preference_read.dig("ansible.builtin.uri", "url").to_s.include?("/admin/users/") &&
  preference_read.dig("ansible.builtin.uri", "url").to_s.end_with?("/preferences")
refuse("managed user preference repair must use the pinned v3 PATCH") unless
  preference_repair&.dig("ansible.builtin.uri", "method") == "PATCH"
refuse("managed user preference repair does not send the desired owned leaves") unless
  preference_repair&.dig("ansible.builtin.uri", "body").to_s.include?(
    "immich_managed_user_desired_preferences"
  )
refuse("managed user preference repair must not send avatar") if
  preference_repair&.dig("ansible.builtin.uri", "body").to_s.match?(/avatar/i)
refuse("managed user preference authoritative verification is absent") unless preference_verify
refuse("avatar preference translation must use a separate pinned v3 PATCH") unless
  avatar_repair&.dig("ansible.builtin.uri", "method") == "PATCH" &&
  avatar_repair&.dig("ansible.builtin.uri", "body") == {
    "avatarColor" => "{{ immich_managed_user_desired_avatar_colors[item.item.email] }}"
  }
refuse("avatar repair must be conditional on effective avatar ownership") unless
  Array(avatar_repair["when"]).any? do |condition|
    condition.include?("item.item.email in immich_managed_user_desired_avatar_colors")
  end
refuse("avatar preference authoritative admin-user verification is absent") unless avatar_verify
refuse("authoritative admin-user pre-read must cover profiles without avatar ownership") if
  Array(user_read["when"]).to_s.include?("desired_avatar_colors")
task_positions = managed_user_tasks.each_with_index.to_h { |task, index| [task["name"], index] }
first_managed_mutation = task_positions.fetch("Repair Immich managed-user non-secret properties")
create_position = task_positions.fetch("Create absent Immich managed users")
[
  "Validate effective Immich managed user preference policies",
  "Read existing Immich managed user preferences before creation",
  "Read existing Immich managed users before creation",
  "Require supported existing Immich managed user preference responses",
  "Require non-administrator Immich managed preference targets"
].each do |name|
  refuse("#{name} must precede the batch creation boundary") unless
    task_positions.fetch(name) < create_position
end
{
  "preference read" => preference_read,
  "preference schema guard" => preference_guard,
  "administrator user read" => user_read,
  "administrator user schema guard" => user_guard
}.each do |label, task|
  refuse("#{label} must precede every managed-user PATCH") unless
    task && task_positions.fetch(task.fetch("name")) < first_managed_mutation
end
managed_user_tasks.select { |task| task.key?("ansible.builtin.uri") }.each do |task|
  refuse("secret-bearing managed-user API task is not redacted: #{task['name']}") unless
    task["no_log"] == true
end

role = File.read(File.join(root, "roles", "immich", "tasks", "main.yml"))
required_tasks = [
  "Read Immich initialization state",
  "Refuse a rotated Immich database credential",
  "Create the vault Immich administrator",
  "Authenticate the vault Immich administrator",
  "Require the vault Immich administrator",
  "Read the Immich system configuration",
  "Repair the Immich system configuration",
  "Complete Immich administrator onboarding",
  "Require the managed Immich settings"
]
required_tasks.each do |name|
  refuse("missing #{name}") unless role.include?("- name: #{name}")
end

role_tasks = YAML.safe_load_file(
  File.join(root, "roles", "immich", "tasks", "main.yml"),
  aliases: true
)
environment_render = role_tasks.find do |task|
  task["name"] == "Render the Immich environment"
end
refuse("Immich environment render is absent") unless environment_render
refuse("Immich environment render must remain redacted") unless
  environment_render["no_log"] == true

classifier = role_tasks.find do |task|
  task["name"] == "Classify the Immich database credential probe"
end
refuse("missing secret-safe database probe classifier") unless classifier
classifier_text = classifier.to_s
%w[execution-failed connection-rejected identity-mismatch verified].each do |status|
  refuse("database probe classifier omits #{status}") unless classifier_text.include?(status)
end
refuse("database probe classifier must remain redacted") unless classifier["no_log"] == true

assertion = role_tasks.find do |task|
  task["name"] == "Require the managed Immich database credential"
end
refuse("database credential assertion is absent") unless assertion
refuse("database credential assertion still censors its safe category") if assertion["no_log"] == true
assertion_text = assertion.to_s
refuse("database credential assertion omits the safe status") unless
  assertion_text.include?("immich_database_probe_status")
%w[vault_immich_db_password immich_database_identity stderr stdout].each do |secret_source|
  refuse("database credential assertion exposes #{secret_source}") if
    assertion_text.include?(secret_source)
end

probe = role_tasks.find do |task|
  task["name"] == "Refuse a rotated Immich database credential"
end
refuse("database credential probe is absent") unless probe
refuse("role must not use the Docker API exec module") if
  role.include?("community.docker.docker_container_exec")
compose_probe = probe["community.docker.docker_compose_v2_exec"]
refuse("database credential probe must use Compose exec") unless compose_probe
{
  "project_src" => "{{ platform_current_dir }}/services/immich",
  "project_name" => "{{ immich_compose_project_name }}",
  "files" => "{{ immich_compose_files }}",
  "env_files" => ["{{ platform_runtime_dir }}/services/immich/.env"],
  "service" => "database",
  "tty" => false
}.each do |field, expected|
  refuse("database credential Compose probe #{field} differs") unless
    compose_probe[field] == expected
end
refuse("database credential Compose probe must not supply host environment") if
  compose_probe.key?("env")
refuse("database credential Compose probe command differs") unless
  compose_probe["argv"] == [
    "sh",
    "-ec",
    "exec env PGPASSWORD=\"$POSTGRES_PASSWORD\" PGCONNECT_TIMEOUT=15 " \
      "psql --host=database --username=\"$1\" --dbname=\"$2\" " \
      "--no-align --tuples-only " \
      "--command=\"select current_user || '/' || current_database()\"",
    "immich-database-probe",
    "{{ vault_immich_db_username }}",
    "{{ vault_immich_db_name }}"
  ]
{
  "register" => "immich_database_identity",
  "when" => "not ansible_check_mode",
  "failed_when" => false,
  "changed_when" => false,
  "check_mode" => false,
  "no_log" => true
}.each do |field, expected|
  refuse("database credential Compose probe #{field} differs") unless
    probe[field] == expected
end
probe_text = probe.to_s
refuse("database credential Compose probe exposes the vault password") if
  probe_text.include?("vault_immich_db_password")
refuse("database credential Compose probe uses a host --env path") if
  probe_text.include?("--env")
refuse("database credential assertion must identify the Compose service") unless
  assertion_text.include?("Compose service database")
refuse("database credential assertion still identifies a container variable") if
  assertion_text.include?("immich_postgres_container")
refuse("role still references immich_postgres_container") if
  role.include?("immich_postgres_container")

# Immich owns its schema through its own migrations. A role that reaches into
# PostgreSQL to fix application state is editing an opaque database.
refuse("role must not mutate the application schema") if
  role.match?(/\b(?:INSERT|UPDATE|DELETE|ALTER|DROP)\s+(?:INTO|FROM|TABLE)?/i)
puts "Immich static contract passed (#{platform})"
RUBY

[ "$mode" = static ] && exit 0
. "${PLATFORM_LEGACY_FIXTURE_HELPER_FILE:-$repo_dir/tests/contracts/legacy-fixture-paths.sh}"
legacy_fixture_validate PLATFORM_IMMICH_UPLOAD_ROOT legacy/immich/data/upload ||
  fail_contract 'legacy upload root is unsafe'
legacy_fixture_validate PLATFORM_IMMICH_THUMBNAIL_ROOT legacy/immich/thumbs ||
  fail_contract 'legacy thumbnail root is unsafe'

: "${PLATFORM_CONTRACT_VAULT_FILE:=${PLATFORM_MAC_VAULT_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:=${PLATFORM_MAC_VAULT_PASSWORD_FILE:-}}"
: "${PLATFORM_MEDIA_ROOT:?}"
: "${PLATFORM_DOCKER_ROOT:?}"
: "${PLATFORM_REPORT_ROOT:?}"
: "${PLATFORM_IMMICH_PORT:=2283}"
: "${PLATFORM_IMMICH_SERVER_CONTAINER:=immich_server}"
: "${PLATFORM_IMMICH_MACHINE_LEARNING_CONTAINER:=immich_machine_learning}"
: "${PLATFORM_IMMICH_REDIS_CONTAINER:=immich_redis}"
: "${PLATFORM_IMMICH_POSTGRES_CONTAINER:=immich_postgres}"
PLATFORM_IMMICH_PLATFORM=$platform
PLATFORM_CONTRACT_REPO_DIR=$repo_dir
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
export PLATFORM_CONTRACT_REPO_DIR
export PLATFORM_MEDIA_ROOT PLATFORM_DOCKER_ROOT PLATFORM_REPORT_ROOT
export PLATFORM_IMMICH_PORT PLATFORM_IMMICH_PLATFORM
export PLATFORM_IMMICH_SERVER_CONTAINER PLATFORM_IMMICH_MACHINE_LEARNING_CONTAINER
export PLATFORM_IMMICH_REDIS_CONTAINER PLATFORM_IMMICH_POSTGRES_CONTAINER

exec ruby - "$mode" "$@" <<'RUBY'
require "json"
require "net/http"
require "open3"
require "pathname"
require "timeout"
require "uri"
require "yaml"

MODE = ARGV.fetch(0)
PLATFORM = ENV.fetch("PLATFORM_IMMICH_PLATFORM")
BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_IMMICH_PORT'), 10)}")
DOCKER_ROOT = Pathname.new(ENV.fetch("PLATFORM_DOCKER_ROOT")).expand_path
MEDIA_ROOT = Pathname.new(ENV.fetch("PLATFORM_MEDIA_ROOT")).expand_path
REPORT_ROOT = Pathname.new(ENV.fetch("PLATFORM_REPORT_ROOT")).expand_path
SERVER_CONTAINER = ENV.fetch("PLATFORM_IMMICH_SERVER_CONTAINER")
HELPER_CONTAINERS = [
  ENV.fetch("PLATFORM_IMMICH_MACHINE_LEARNING_CONTAINER"),
  ENV.fetch("PLATFORM_IMMICH_REDIS_CONTAINER"),
  ENV.fetch("PLATFORM_IMMICH_POSTGRES_CONTAINER")
].freeze
STATE_PATH = REPORT_ROOT.join("immich-persistence.json")
REPO_DIR = Pathname.new(ENV.fetch("PLATFORM_CONTRACT_REPO_DIR")).expand_path
MANAGED_SENTINEL = "nas-platform-unowned-sentinel"
SUPPORTED_UNOWNED_PREFERENCE_SENTINELS = [
  [%w[albums defaultAssetOrder], "asc"],
  [%w[folders enabled], true],
  [%w[ratings enabled], true],
  [%w[tags sidebarWeb], true]
].freeze

DEVICE_ID = "nas-platform-immich-contract"
MANAGED_SETTINGS = {
  ["newVersionCheck", "enabled"] => false,
  ["machineLearning", "enabled"] => true,
  ["backup", "database", "enabled"] => true
}.freeze

# Both fixtures are produced by the pinned server image's own ffmpeg with
# bitexact flags, so regenerating them yields these exact bytes. They are
# deliberately tiny: the contract proves that the pipeline ran, not that the
# encoder is fast. unpack1 rather than the base64 library, which is not a
# default gem on the Ruby 3.4 the integration lane runs.
PHOTO_FIXTURE = (
  "/9j/4AAQSkZJRgABAgAAAQABAAD/2wBDAAgICAkICQsLCwsLCw0MDQ0NDQ0NDQ0NDQ0ODg4REREO" \
  "Dg4NDQ4OEBARERITEhERERETExQUFBgYFxccHB0iIin/xABNAAEBAAAAAAAAAAAAAAAAAAAABgEB" \
  "AQEAAAAAAAAAAAAAAAAAAAYHEAEAAAAAAAAAAAAAAAAAAAAAEQEAAAAAAAAAAAAAAAAAAAAA/8AA" \
  "EQgAMABAAwEiAAIRAAMRAP/aAAwDAQACEQMRAD8AiwEo38AAAAAAAAAAAAAAAAAAAAAB/9k="
).unpack1("m0").freeze
VIDEO_FIXTURE = (
  "AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAANsbW9vdgAAAGxtdmhkAAAAAAAAAAAA" \
  "AAAAAAAD6AAAB9AAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAA" \
  "AABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAArt0cmFrAAAAXHRraGQAAAADAAAA" \
  "AAAAAAAAAAABAAAAAAAAB9AAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAA" \
  "AAAAAAAAAABAAAAAAEAAAAAwAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAfQAAAgAAABAAAA" \
  "AAIzbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAABAAAAAgABVxAAAAAAALWhkbHIAAAAAAAAAAHZp" \
  "ZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAAB3m1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAA" \
  "ACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAZ5zdGJsAAAAvnN0c2QAAAAAAAAA" \
  "AQAAAK5hdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAEAAMABIAAAASAAAAAAAAAABDExhdmMg" \
  "bGlieDI2NAAAAAAAAAAAAAAAAAAAAAAAAAAAGP//AAAANGF2Y0MBZAAK/+EAGGdkAAqs2UR7ARAA" \
  "AAMAEAAAAwCA8SJZYAEABWjvgZcs/fj4AAAAABBwYXNwAAAAAQAAAAEAAAAUYnRydAAAAAAAABC0" \
  "AAAAAAAAABhzdHRzAAAAAAAAAAEAAAAIAAAQAAAAABRzdHNzAAAAAAAAAAEAAAABAAAASGN0dHMA" \
  "AAAAAAAABwAAAAEAACAAAAAAAQAAUAAAAAABAAAgAAAAAAEAAAAAAAAAAQAAEAAAAAABAABAAAAA" \
  "AAIAABAAAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAAIAAAAAQAAADRzdHN6AAAAAAAAAAAAAAAIAAAD" \
  "dwAAAEUAAAALAAAACwAAAA4AAAAyAAAAEAAAAAsAAAAUc3RjbwAAAAAAAAABAAADnAAAAD11ZHRh" \
  "AAAANW1ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAG1kaXJhcHBsAAAAAAAAAAAAAAAACGlsc3QAAAAI" \
  "ZnJlZQAABDVtZGF0AAACrAYF//+o3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NCByMzEw" \
  "OCAzMWUxOWY5IC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyMyAt" \
  "IGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTEgcmVm" \
  "PTEgZGVibG9jaz0xOjA6MCBhbmFseXNlPTB4MzoweDExMyBtZT1oZXggc3VibWU9MiBwc3k9MSBw" \
  "c3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0wIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxs" \
  "aXM9MCA4eDhkY3Q9MSBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3Fw" \
  "X29mZnNldD0wIHRocmVhZHM9MSBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAg" \
  "bnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRf" \
  "aW50cmE9MCBiZnJhbWVzPTMgYl9weXJhbWlkPTIgYl9hZGFwdD0xIGJfYmlhcz0wIGRpcmVjdD0x" \
  "IHdlaWdodGI9MSBvcGVuX2dvcD0wIHdlaWdodHA9MSBrZXlpbnQ9MjUwIGtleWludF9taW49NCBz" \
  "Y2VuZWN1dD00MCBpbnRyYV9yZWZyZXNoPTAgcmNfbG9va2FoZWFkPTEwIHJjPWNyZiBtYnRyZWU9" \
  "MSBjcmY9NTEuMCBxY29tcD0wLjYwIHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89" \
  "MS40MCBhcT0xOjEuMDAAgAAAAMNliIQD/3pWed2t18PhusYM6x+bWCrbRWvvGc7zWFLUNP4P/jm9" \
  "kBxLrrbb562/M9iZACUP0oV330y8jPggUuS4+0xfLbnfM43H9ekXN+BE6YOsseYMK5DDGRjIIRl0" \
  "RYcwJadqcTpL89ot/gK/b8xYfs9BotEQPtUe+4FK9T/ppjvirrhFQ+u3DKTOvoS28+cNo2vmH1SA" \
  "uSEd1nJwn7pDeuzQXJhUv4Y0PATCN97EJhPQLwB4koN9mzDlOZckO6Wa5jUAAABBQZokGP+huC9W" \
  "FveGiokDD7lglt6vcViI/j5WXk/RdrP//sPAVs+79xaVLBaCf8ne+XXtlDuP/utSmGg+7E0q5UoA" \
  "AAAHQZ5CQ/+7gQAAAAcBnmFH/7uAAAAACgGeY0f/zv28EGEAAAAuQZpnNEx/oYCQbyVK3Uwaw77h" \
  "zTDiQJGbHHdUO7detW/5kya7IbaTm/NHZ8AtQQAAAAxBnoVFES//v/3RtEEAAAAHAZ6mR/+7gQ=="
).unpack1("m0").freeze

FIXTURES = [
  { name: "nas-platform-contract-photo.jpg", type: "image/jpeg",
    bytes: PHOTO_FIXTURE, kind: "IMAGE" },
  { name: "nas-platform-contract-video.mp4", type: "video/mp4",
    bytes: VIDEO_FIXTURE, kind: "VIDEO" }
].freeze

def fail_contract(message)
  warn "Immich contract failed: #{message}"
  exit 1
end

def request(method, path, token: nil, body: nil, expected: [200], raw: false,
            headers: {}, form: nil)
  uri = URI.join(BASE.to_s, path)
  request = Net::HTTP.const_get(method.capitalize).new(uri)
  request["Authorization"] = "Bearer #{token}" if token
  headers.each { |name, value| request[name] = value }
  if form
    boundary = "nasplatformimmichcontractboundary"
    request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
    request.body = multipart_body(form, boundary)
  elsif body
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body)
  end
  response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 180) do |http|
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

# Hand-built because no multipart encoder is a Ruby default gem.
def multipart_body(fields, boundary)
  body = +""
  fields.each do |field|
    body << "--#{boundary}\r\n"
    if field.key?(:filename)
      body << %(Content-Disposition: form-data; name="#{field.fetch(:name)}"; ) <<
              %(filename="#{field.fetch(:filename)}"\r\n)
      body << "Content-Type: #{field.fetch(:content_type)}\r\n\r\n"
      body << field.fetch(:value).dup.force_encoding(Encoding::BINARY)
    else
      body << %(Content-Disposition: form-data; name="#{field.fetch(:name)}"\r\n\r\n)
      body << field.fetch(:value)
    end
    body << "\r\n"
  end
  body << "--#{boundary}--\r\n"
  body.force_encoding(Encoding::BINARY)
end

# /api/server/ping answers before the container health check reports healthy, so
# readiness here is the application answering for its own initialization state.
def wait_for_application
  deadline = Time.now + 300
  loop do
    uri = URI.join(BASE.to_s, "/api/server/config")
    response = Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 15) do |http|
      http.request(Net::HTTP::Get.new(uri))
    end
    payload = JSON.parse(response.body)
    return if response.code.to_i == 200 && payload["isInitialized"] == true
  rescue JSON::ParserError, SystemCallError, Timeout::Error, EOFError
    nil
  ensure
    fail_contract("Immich never reported an initialized server") if Time.now >= deadline
    sleep 2
  end
end

def docker_capture(*argv)
  stdout, stderr, status = Open3.capture3("docker", *argv)
  fail_contract("docker #{argv.first} failed: #{argv.join(' ')}") unless status.success?
  stderr.replace("\0" * stderr.bytesize)
  stdout
end

def safe_id(value)
  fail_contract("Immich returned an unsafe API identifier") unless
    value.is_a?(String) && value.match?(/\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/)
  value
end

def inspect_container(name)
  JSON.parse(docker_capture("inspect", name)).fetch(0)
end

# The plan's containment requirement: only the application is reachable from the
# host. A published database or cache port is a LAN-facing database.
def assert_container_capabilities
  server = inspect_container(SERVER_CONTAINER)
  bindings = server.dig("HostConfig", "PortBindings") || {}
  published = bindings.reject { |_port, hosts| hosts.nil? || hosts.empty? }
  fail_contract("the application must publish exactly its own port, got #{published.keys.inspect}") unless
    published.keys == ["2283/tcp"]

  devices = server.dig("HostConfig", "Devices") || []
  if PLATFORM == "nas"
    fail_contract("the NAS render device is not mapped") unless
      devices.any? { |device| device["PathInContainer"].to_s.start_with?("/dev/dri") }
  else
    fail_contract("#{PLATFORM} must expose no host device: #{devices.inspect}") unless devices.empty?
  end

  HELPER_CONTAINERS.each do |name|
    helper = inspect_container(name)
    helper_bindings = helper.dig("HostConfig", "PortBindings") || {}
    exposed = helper_bindings.reject { |_port, hosts| hosts.nil? || hosts.empty? }
    fail_contract("#{name} publishes host ports #{exposed.keys.inspect}") unless exposed.empty?
  end
end

def read_settings(token)
  _response, config = request("get", "/api/system-config", token: token)
  config
end

def managed_leaves(config)
  MANAGED_SETTINGS.keys.to_h { |path| [path.join("."), config.dig(*path)] }
end

def assert_managed_settings(config)
  MANAGED_SETTINGS.each do |path, value|
    fail_contract("managed setting #{path.join('.')} differs") unless config.dig(*path) == value
  end
end

def deep_merge(left, right)
  left.merge(right) do |_key, old_value, new_value|
    old_value.is_a?(Hash) && new_value.is_a?(Hash) ? deep_merge(old_value, new_value) : new_value
  end
end

def managed_user_policy
  base = YAML.safe_load_file(
    REPO_DIR.join("inventory", "group_vars", "all", "main.yml"), aliases: false
  )
  fixture_path = Pathname.new(ENV.fetch("PLATFORM_MAC_FIXTURE_VARS_FILE")).expand_path
  stat = fixture_path.lstat
  fail_contract("protected Immich fixture policy is unsafe") unless
    fixture_path.absolute? && stat.file? && !stat.symlink? && stat.uid == Process.uid &&
    (stat.mode & 0o777) == 0o600
  fixture = YAML.safe_load_file(fixture_path, aliases: false)
  deep_merge(base, fixture)
rescue SystemCallError, KeyError, Psych::Exception
  fail_contract("protected Immich fixture policy is unavailable")
end

def desired_managed_user_profile(policy, email)
  normalized = email.strip.downcase
  profile_by_email = policy.fetch("immich_managed_user_preference_profile_by_email").to_h do |key, value|
    [key.strip.downcase, value]
  end
  overrides = policy.fetch("immich_managed_user_preference_overrides").to_h do |key, value|
    [key.strip.downcase, value]
  end
  profile_name = profile_by_email.fetch(
    normalized, policy.fetch("immich_managed_user_preference_profile_default")
  )
  profile = policy.fetch("immich_managed_user_preference_profiles").fetch(profile_name)
  deep_merge(profile, overrides.fetch(normalized, {}))
end

def supported_unowned_preference_sentinel(profile)
  preferences = profile.reject { |key, _value| key == "avatar" }
  SUPPORTED_UNOWNED_PREFERENCE_SENTINELS.find do |path, _value|
    !preferences.fetch(path.fetch(0), {}).key?(path.fetch(1))
  end
end

def nested_preference_patch(path, value)
  { path.fetch(0) => { path.fetch(1) => value } }
end

def designated_partial_profile_email(policy)
  designated = policy.fetch("immich_contract_partial_profile_email").strip.downcase
  selected = policy.fetch("immich_managed_user_preference_profile_by_email").filter_map do |email, name|
    email.strip.downcase if name == "compact"
  end
  fail_contract("test-only compact profile must select exactly the designated managed account") unless
    selected == [designated]
  designated
end

def list_managed_user_records(token, managed_users)
  _response, users = request("get", "/api/admin/users?withDeleted=true", token: token)
  fail_contract("Immich returned an unsupported administrator user listing") unless users.is_a?(Array)
  managed_users.to_h do |managed|
    normalized = managed.fetch("email").strip.downcase
    matches = users.select { |user| user.fetch("email", "").strip.downcase == normalized }
    fail_contract("managed Immich identity does not resolve uniquely") unless matches.length == 1
    user = matches.first
    fail_contract("managed Immich preference target is not an active non-administrator") unless
      user["status"] == "active" && user["isAdmin"] == false
    [normalized, user]
  end
end

def seed_managed_user_state(token, managed_users, policy)
  _response, users = request("get", "/api/admin/users?withDeleted=true", token: token)
  designated = designated_partial_profile_email(policy)
  managed_users.each do |managed|
    normalized = managed.fetch("email").strip.downcase
    matches = users.select { |user| user.fetch("email", "").strip.downcase == normalized }
    fail_contract("managed Immich seed identity is ambiguous") if matches.length > 1
    if matches.empty?
      _response, created = request(
        "post", "/api/admin/users", token: token, expected: [201],
        body: managed.slice("email", "password", "name")
      )
      users << created
      target = created
    else
      target = matches.first
    end
    fail_contract("refusing to seed an administrator as a managed user") unless target["isAdmin"] == false
    id = safe_id(target.fetch("id"))
    profile = desired_managed_user_profile(policy, managed.fetch("email"))
    user_patch = {
      "name" => managed.fetch("name"), "quotaSizeInBytes" => managed.fetch("quota_size"),
      "storageLabel" => MANAGED_SENTINEL
    }
    user_patch["avatarColor"] = profile.dig("avatar", "color") if
      profile.fetch("avatar", {}).key?("color")
    request(
      "patch", "/api/admin/users/#{id}", token: token,
      body: user_patch
    )
    request(
      "patch", "/api/admin/users/#{id}/preferences", token: token,
      body: profile.reject { |key, _value| key == "avatar" }
    )
    sentinel = supported_unowned_preference_sentinel(profile)
    if normalized == designated
      fail_contract("designated partial profile has no supported unowned preference sentinel") unless
        sentinel
      path, value = sentinel
      request(
        "patch", "/api/admin/users/#{id}/preferences", token: token,
        body: nested_preference_patch(path, value)
      )
    end
  end
end

def assert_managed_user_profiles(token, managed_users, policy, require_sentinel: false)
  records = list_managed_user_records(token, managed_users)
  designated = designated_partial_profile_email(policy)
  managed_users.map do |managed|
    normalized = managed.fetch("email").strip.downcase
    user = records.fetch(normalized)
    id = safe_id(user.fetch("id"))
    _response, authoritative_user = request("get", "/api/admin/users/#{id}", token: token)
    fail_contract("managed Immich authoritative user read changed identity") unless
      authoritative_user.fetch("email").strip.downcase == normalized &&
      authoritative_user["status"] == "active" && authoritative_user["isAdmin"] == false
    profile = desired_managed_user_profile(policy, managed.fetch("email"))
    if profile.fetch("avatar", {}).key?("color")
      fail_contract("managed Immich avatar preference differs") unless
        authoritative_user["avatarColor"] == profile.dig("avatar", "color")
    end
    fail_contract("managed Immich unowned sentinel was not preserved") if
      require_sentinel && authoritative_user["storageLabel"] != MANAGED_SENTINEL
    _response, preferences = request(
      "get", "/api/admin/users/#{id}/preferences", token: token
    )
    profile.reject { |key, _value| key == "avatar" }.each do |scope, leaves|
      leaves.each do |leaf, expected|
        fail_contract("managed preference #{scope}.#{leaf} differs for #{id}") unless
          preferences.dig(scope, leaf) == expected
      end
    end
    sentinel = supported_unowned_preference_sentinel(profile)
    if normalized == designated
      fail_contract("designated partial profile has no supported unowned preference sentinel") unless
        sentinel
    end
    if normalized == designated && require_sentinel
      path, expected = sentinel
      fail_contract("supported unowned managed preference #{path.join('.')} was not preserved") unless
        preferences.dig(*path) == expected
    end
    _response, managed_session = request(
      "post", "/api/auth/login", expected: [201],
      body: { "email" => managed.fetch("email"), "password" => managed.fetch("password") }
    )
    fail_contract("managed Immich authentication resolved a different identity or role") unless
      managed_session["userId"] == id &&
      managed_session.fetch("userEmail").strip.downcase == normalized &&
      managed_session["isAdmin"] == false
    {
      "id" => id, "email" => normalized, "name" => authoritative_user["name"],
      "quotaSizeInBytes" => authoritative_user["quotaSizeInBytes"],
      "isAdmin" => authoritative_user["isAdmin"], "avatarColor" => authoritative_user["avatarColor"],
      "storageLabel" => authoritative_user["storageLabel"],
      "preferences" => profile.reject { |key, _value| key == "avatar" },
      "supportedUnownedPreference" => sentinel && { "path" => sentinel.first.join("."),
                                                      "value" => sentinel.last }
    }
  end.sort_by { |record| record.fetch("email") }
end

def upload_fixture(token, fixture)
  _response, payload = request(
    "post", "/api/assets", token: token, expected: [200, 201],
    form: [
      { name: "assetData", filename: fixture.fetch(:name),
        content_type: fixture.fetch(:type), value: fixture.fetch(:bytes) },
      { name: "deviceAssetId", value: "#{DEVICE_ID}-#{fixture.fetch(:name)}" },
      { name: "deviceId", value: DEVICE_ID },
      { name: "fileCreatedAt", value: "2026-01-01T00:00:00.000Z" },
      { name: "fileModifiedAt", value: "2026-01-01T00:00:00.000Z" }
    ]
  )
  # An identical re-upload answers 200 "duplicate" with the same identifier, so
  # seeding is naturally re-runnable and both answers are correct here.
  fail_contract("unexpected upload status #{payload['status'].inspect}") unless
    %w[created duplicate].include?(payload["status"])
  safe_id(payload.fetch("id"))
end

def wait_for_thumbnail(token, id, timeout:)
  deadline = Time.now + timeout
  loop do
    _response, asset = request("get", "/api/assets/#{id}", token: token)
    thumbnail = request(
      "get", "/api/assets/#{id}/thumbnail?size=preview", token: token,
      raw: true, expected: (100..599).to_a
    )
    if asset["thumbhash"] && thumbnail.code.to_i == 200 && !thumbnail.body.to_s.empty?
      return asset
    end

    fail_contract("no thumbnail was generated for #{id} within #{timeout}s") if Time.now >= deadline
    sleep 3
  end
end

# Smart search is the only assertion that proves the machine learning container
# actually ran an inference: the query text is embedded by CLIP on the CPU and
# matched against embeddings the same stack produced for the fixtures.
def assert_cpu_machine_learning(token, expected_ids)
  deadline = Time.now + 600
  loop do
    _response, payload = request(
      "post", "/api/search/smart", token: token, body: { "query" => "a photograph" }
    )
    found = payload.fetch("assets").fetch("items").map { |item| item["id"] }
    return if (expected_ids - found).empty?

    if Time.now >= deadline
      fail_contract("smart search never returned the fixtures; " \
                    "machine learning produced #{found.length} embedded asset(s)")
    end
    sleep 5
  end
end

def assert_originals_open(token, records)
  records.each do |record|
    fixture = FIXTURES.find { |candidate| candidate.fetch(:name) == record.fetch("name") }
    response = request(
      "get", "/api/assets/#{record.fetch('id')}/original", token: token, raw: true
    )
    fail_contract("the original for #{record.fetch('name')} returned HTTP #{response.code}") unless
      response.code.to_i == 200
    fail_contract("the original for #{record.fetch('name')} is not the uploaded bytes") unless
      response.body == fixture.fetch(:bytes)
  end
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
email = vault.fetch("vault_immich_admin_email")
password = vault.fetch("vault_immich_admin_password")
managed_users = vault.fetch("vault_managed_users").fetch("immich")
policy = managed_user_policy

wait_for_application
# A rejected login answers JSON here, unlike some other services in this
# platform, so the parsed body is safe to ask for.
request(
  "post", "/api/auth/login", expected: [401],
  body: { "email" => email, "password" => "contract-wrong-password" }
)
# A successful login answers 201, not 200.
_response, session = request(
  "post", "/api/auth/login", expected: [201],
  body: { "email" => email, "password" => password }
)
token = session.fetch("accessToken")
user_id = safe_id(session.fetch("userId"))
fail_contract("the vault administrator identity or role differs") unless
  session.fetch("userEmail") == email && session.fetch("isAdmin") == true

seed_managed_user_state(token, managed_users, policy) if MODE == "seed"

# Creating a second administrator must be refused by the server itself, which is
# what makes the role's create-once behavior safe to rerun.
request(
  "post", "/api/auth/admin-sign-up", expected: [400],
  body: { "email" => "contract-intruder@example.invalid",
          "password" => "contract-wrong-password", "name" => "Contract Intruder" }
)

assert_container_capabilities
config = read_settings(token)

if MODE == "drift-verify"
  fail_contract("the Immich drift fixture was not installed") unless
    config.dig("newVersionCheck", "enabled") == true
  target = list_managed_user_records(token, managed_users).fetch(
    managed_users.first.fetch("email").strip.downcase
  )
  target_id = safe_id(target.fetch("id"))
  _response, drifted_user = request("get", "/api/admin/users/#{target_id}", token: token)
  _response, drifted_preferences = request(
    "get", "/api/admin/users/#{target_id}/preferences", token: token
  )
  desired = desired_managed_user_profile(policy, managed_users.first.fetch("email"))
  fail_contract("the Immich managed preference drift fixture was not installed") unless
    drifted_preferences.dig("folders", "enabled") != desired.dig("folders", "enabled") &&
    drifted_preferences.dig("people", "sidebarWeb") != desired.dig("people", "sidebarWeb") &&
    drifted_preferences.dig("people", "minimumFaces") != desired.dig("people", "minimumFaces") &&
    drifted_preferences.dig("albums", "defaultAssetOrder") == "asc"
  fail_contract("the Immich unowned sentinel did not survive drift installation") unless
    drifted_user["storageLabel"] == MANAGED_SENTINEL && drifted_user["isAdmin"] == false
  if STATE_PATH.file?
    seeded = JSON.parse(STATE_PATH.binread).fetch("managed_users").find do |record|
      record.fetch("email") == managed_users.first.fetch("email").strip.downcase
    end
    fail_contract("the Immich unowned avatar changed during drift installation") unless
      seeded && drifted_user["avatarColor"] == seeded["avatarColor"]
  end
  puts "Immich settings and managed-user preference drift are present"
  exit
end

assert_managed_settings(config)
managed_user_state = assert_managed_user_profiles(
  token, managed_users, policy, require_sentinel: STATE_PATH.file? || MODE == "seed"
)

if MODE == "drift"
  drifted = config.merge("newVersionCheck" => config.fetch("newVersionCheck").merge("enabled" => true))
  request("put", "/api/system-config", token: token, body: drifted)
  first_managed = managed_users.first
  target = list_managed_user_records(token, [first_managed]).fetch(
    first_managed.fetch("email").strip.downcase
  )
  target_id = safe_id(target.fetch("id"))
  desired = desired_managed_user_profile(policy, first_managed.fetch("email"))
  request(
    "patch", "/api/admin/users/#{target_id}/preferences", token: token,
    body: {
      "folders" => { "enabled" => !desired.dig("folders", "enabled") },
      "people" => {
        "sidebarWeb" => !desired.dig("people", "sidebarWeb"),
        "minimumFaces" => desired.dig("people", "minimumFaces") + 1
      }
    }
  )
  puts "Immich settings and managed-user preference drift installed"
  exit
end

if MODE == "run"
  puts "Immich login, containment, and settings contract passed"
  exit
end
fail_contract("unknown mode: #{MODE}") unless %w[seed assert-persistence].include?(MODE)

records = FIXTURES.map do |fixture|
  id = upload_fixture(token, fixture)
  asset = wait_for_thumbnail(token, id, timeout: MODE == "seed" ? 300 : 120)
  fail_contract("#{fixture.fetch(:name)} was stored as #{asset['type'].inspect}") unless
    asset.fetch("type") == fixture.fetch(:kind)
  { "name" => fixture.fetch(:name), "id" => id, "checksum" => asset.fetch("checksum") }
end

assert_originals_open(token, records)
assert_cpu_machine_learning(token, records.map { |record| record.fetch("id") }) if MODE == "seed"

# Generated derivatives must land on the redirected Docker-root volume rather
# than beside the originals, which is the whole point of the nested bind layout.
thumbnail_root = DOCKER_ROOT.join("immich", "data", "thumbs")
thumbnail_root = Pathname.new(ENV.fetch("PLATFORM_IMMICH_THUMBNAIL_ROOT", thumbnail_root.to_s)).expand_path
fail_contract("the generated asset volume is unavailable or unsafe") unless
  thumbnail_root.directory? && !thumbnail_root.symlink?
fail_contract("no generated thumbnail reached the Docker-root volume") if
  Dir.glob(thumbnail_root.join("**", "*_thumbnail.webp").to_s).empty?
originals_root = MEDIA_ROOT.join("Immich", "upload")
originals_root = Pathname.new(ENV.fetch("PLATFORM_IMMICH_UPLOAD_ROOT", originals_root.to_s)).expand_path
fail_contract("the originals volume is unavailable or unsafe") unless
  originals_root.directory? && !originals_root.symlink?

state = JSON.generate(
  "user_id" => user_id,
  "assets" => records.sort_by { |record| record.fetch("name") },
  "settings" => managed_leaves(config),
  "managed_users" => managed_user_state
)

case MODE
when "seed"
  fail_contract("report root is unavailable or unsafe") unless
    REPORT_ROOT.directory? && !REPORT_ROOT.symlink?
  fail_contract("refusing to replace the Immich persistence artifact") if
    STATE_PATH.exist? || STATE_PATH.symlink?
  STATE_PATH.open(File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(state) }
  puts "Immich fixtures uploaded, thumbnailed, and matched by CPU machine learning"
when "assert-persistence"
  fail_contract("the Immich persistence artifact is unavailable or unsafe") unless
    STATE_PATH.file? && !STATE_PATH.symlink?
  fail_contract("Immich user, assets, or settings changed across recreation") unless
    STATE_PATH.binread == state
  puts "Immich user, assets, and settings persisted"
end
RUBY
