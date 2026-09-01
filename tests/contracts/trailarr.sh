#!/bin/sh
set -eu
set +x

mode=${1:-run}
case $mode in
  static|run) ;;
  *)
    printf '%s\n' 'trailarr contract accepts only static or run' >&2
    exit 2
    ;;
esac

repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)}
# The embedded Ruby below reads tests/policy_support.rb from here instead of
# carrying its own copy of flatten_tasks.
PLATFORM_CONTRACT_REPO_DIR=$repo_dir
export PLATFORM_CONTRACT_REPO_DIR
ruby - "$repo_dir" <<'RUBY'
require "yaml"

root = ARGV.fetch(0)
failures = []
required = %w[
  roles/trailarr/defaults/main.yml
  roles/trailarr/meta/argument_specs.yml
  roles/trailarr/tasks/main.yml
  roles/trailarr/tasks/reconcile_env.yml
  roles/trailarr/tasks/reconcile_profiles.yml
  roles/trailarr/tasks/reconcile_connections.yml
  roles/trailarr/tasks/reconcile_monitoring.yml
  roles/trailarr/templates/env.j2
  services/trailarr/compose.yml
  services/trailarr/compose.mac.yml
  services/trailarr/compose.integration.yml
]
required.each do |relative|
  failures << "missing #{relative}" unless File.file?(File.join(root, relative))
end

require File.join(ENV.fetch("PLATFORM_CONTRACT_REPO_DIR"), "tests", "policy_support")
include PolicySupport

# The environment file is a line-oriented grammar, so it is read as the
# assignments it declares: a commented-out sample of the right assignment
# satisfies a substring search while the live line exports something else.
def environment_assignments(path)
  File.readlines(path, chomp: true).filter_map do |line|
    stripped = line.strip
    next unless stripped.match?(/\A[A-Z][A-Z0-9_]*=/)

    name, _separator, value = stripped.partition("=")
    [name, value]
  end
end

if failures.empty?
  compose = YAML.safe_load_file(File.join(root, "services/trailarr/compose.yml"), aliases: true)
  service = compose.fetch("services").fetch("trailarr")

  # Trailarr reads Radarr and Sonarr over their own APIs by Compose service
  # name, and every connection it declares is validated with a live call at
  # write time, so it has to sit on the shared control network. The two Phase 2
  # self-contained contracts assert the *absence* of a networks key; neither of
  # those assertions may be copied here.
  failures << "Trailarr must join the shared media control network" unless
    Array(service["networks"]) == %w[default media-control]
  failures << "the shared media control network must be the external one" unless
    compose.dig("networks", "media-control") ==
      { "external" => true, "name" => "${PLATFORM_MEDIA_NETWORK:?}" }

  # The entrypoint runs as root, reuses the existing account for the supplied
  # pair, chowns the data directory and re-executes through gosu. A `user:` key
  # would start it as non-root and break that whole sequence, so the identity
  # can only arrive under PUID/PGID.
  failures << "Trailarr must not override the container user" if service.key?("user")
  {
    "PUID" => "${NAS_UID:?}",
    "PGID" => "${NAS_GID:?}"
  }.each do |name, expected|
    failures << "Trailarr must take the platform identity as #{name}" unless
      service.dig("environment", name) == expected
  end
  # UMASK appears nowhere in the application or its start scripts, so declaring
  # it would be a no-op a reader mistakes for a control.
  failures << "Trailarr must not declare an unsupported UMASK" if
    service.fetch("environment", {}).key?("UMASK")

  # Movies and Series are mounted separately, at exactly the container paths
  # Radarr and Sonarr use for the same host directories. That equality is what
  # lets every connection carry an empty path_mappings list, because Trailarr
  # appends a trailing slash to a mapping on write and a declared identity
  # mapping therefore reads back different from what was sent.
  failures << "Trailarr must mount exactly its config and the two arr libraries" unless
    Array(service["volumes"]) == [
      "${TRAILARR_CONFIG_PATH:?}:/config",
      "${TRAILARR_MOVIES_PATH:?}:/data/media/Movies",
      "${TRAILARR_SERIES_PATH:?}:/data/media/Series"
    ]

  # The identity halves. The `:?` suffix is what turns an unset credential into
  # a refused deployment rather than a published default administrator holding a
  # full write session over the Movies and Series trees.
  {
    "API_KEY" => "${TRAILARR_API_KEY:?}",
    "WEBUI_USERNAME" => "${TRAILARR_WEBUI_USERNAME:?}",
    "WEBUI_PASSWORD" => "${TRAILARR_WEBUI_PASSWORD_HASH:?}"
  }.each do |name, expected|
    failures << "Trailarr must require #{name} from the rendered environment" unless
      service.dig("environment", name) == expected
  end

  # WEBUI_DISABLE_AUTH mints a session for any caller when true. The others keep
  # Trailarr from becoming a creator of library directories or a deleter of
  # media, and stop the container installing yt-dlp from the network at start,
  # which is what a digest-pinned platform exists to prevent.
  {
    "WEBUI_DISABLE_AUTH" => "False",
    "CREATE_MISSING_FOLDERS" => "False",
    "DELETE_TRAILER_CONNECTION" => "False",
    "DELETE_TRAILER_MEDIA" => "False",
    "UPDATE_YTDLP" => "False",
    "YTDLP_NIGHTLY" => "False"
  }.each do |name, expected|
    failures << "Trailarr must pin #{name} off in the environment" unless
      service.dig("environment", name) == expected
  end

  failures << "Trailarr must publish the catalog web UI port" unless
    Array(service["ports"]) == ["7889:7889"]
  mac = YAML.safe_load_file(File.join(root, "services/trailarr/compose.mac.yml"))
  failures << "the Mac override must republish the web UI on the harness port" unless
    mac.dig("services", "trailarr", "ports") == ["${TRAILARR_HOST_PORT:?}:7889"]

  # The image ships curl but neither wget nor busybox, so a wget probe would
  # report unhealthy forever.
  failures << "Trailarr must probe its unauthenticated status route with curl" unless
    Array(service.dig("healthcheck", "test")).join(" ").include?(
      "curl --fail --silent --show-error http://127.0.0.1:7889/status"
    )

  defaults = YAML.safe_load_file(File.join(root, "roles/trailarr/defaults/main.yml"))
  arr_defaults = YAML.safe_load_file(File.join(root, "roles/arr/defaults/main.yml"))
  failures << "Trailarr must keep its state in the declared config root" unless
    defaults["trailarr_config_host_path"] == "{{ nas_docker_root }}/trailarr/config"
  {
    "trailarr_movies_host_path" => "{{ nas_media_root }}/Media/Movies",
    "trailarr_series_host_path" => "{{ nas_media_root }}/Media/Series"
  }.each do |name, expected|
    failures << "Trailarr must write the declared #{name.split('_')[1]} library" unless
      defaults[name] == expected
  end
  # The one comparison nothing else in the repository makes: a container path
  # that stopped matching the arr's own root folder would need a path mapping,
  # and a path mapping reads back with a trailing slash and reports drift
  # forever.
  {
    "trailarr_movies_root" => "arr_radarr_root_folder",
    "trailarr_series_root" => "arr_sonarr_root_folder"
  }.each do |trailarr_key, arr_key|
    failures << "#{trailarr_key} must equal #{arr_key}, or every import needs a path mapping" unless
      defaults[trailarr_key] == arr_defaults[arr_key]
  end
  failures << "Trailarr must address both arrs by their Compose service alias" unless
    Array(defaults["trailarr_connections"]).map { |entry| entry["url"] } ==
      ["http://radarr:7878", "http://sonarr:8989"]
  # Permission to fetch stays off by default, so a disposable lane never makes an
  # outbound request to YouTube. Only a host may open it.
  failures << "Trailarr monitoring must default to off" unless
    defaults["trailarr_monitoring_enabled"] == false
  # Intent is the other half and defaults on, which is what makes the reconcile
  # reachable in a lane that keeps the gate shut. The two must stay separate
  # variables: collapsing them would mean a lane can only execute the reconcile
  # by also permitting the download.
  failures << "Trailarr must intend a trailer for every item by default" unless
    defaults["trailarr_monitor_all_media"] == true
  # Both seeded profiles ship mkv/vp9/opus and the Movie one ships the trailer
  # beside the movie file. Both are reconciled to a directly playable container
  # in a Trailers/ subdirectory of the item's own folder.
  failures << "Trailarr must reconcile both seeded trailer profiles" unless
    Array(defaults["trailarr_trailer_profiles"]).map { |entry| entry["id"] } == [1, 2]
  failures << "Trailarr must declare a directly playable trailer in the item's own folder" unless
    defaults["trailarr_trailer_profile_settings"] == {
      "folder_enabled" => true, "folder_name" => "Trailers",
      "custom_folder" => "{media_folder}", "file_format" => "mp4",
      "video_format" => "h264", "audio_format" => "aac"
    }
  # Present is the drift; a converge removes the line rather than writing one.
  failures << "Trailarr must require every hand-written application key absent" unless
    Array(defaults["trailarr_config_env_absent_keys"]).sort == %w[
      CREATE_MISSING_FOLDERS DELETE_TRAILER_CONNECTION DELETE_TRAILER_MEDIA
      DOWNLOADS_ENABLED MONITOR_ENABLED URL_BASE WEBUI_DISABLE_AUTH
      WEBUI_PASSWORD WEBUI_USERNAME
    ]

  env_assignments = environment_assignments(
    File.join(root, "roles/trailarr/templates/env.j2")
  )
  failures << "Trailarr env must render the CPU set exactly once" unless
    env_assignments.select { |name, _value| name == "PLATFORM_CONTAINER_CPUSET" } ==
      [["PLATFORM_CONTAINER_CPUSET", "{{ platform_effective_container_cpuset }}"]]
  # Two files, two rules, opposite directions. Compose interpolates $ in an env
  # file and silently truncates an unescaped bcrypt hash to the empty string, so
  # here every $ is doubled; /config/.env is sourced by bash instead and takes
  # the same hash single-quoted and not doubled.
  failures << "Trailarr env must double every $ in the administrator hash for Compose" unless
    env_assignments.include?(
      ["TRAILARR_WEBUI_PASSWORD_HASH",
       "{{ vault_trailarr_admin_password_hash | replace('$', '$$') }}"]
    )
  failures << "Trailarr env must carry the vault-authored identity" unless
    [
      ["TRAILARR_API_KEY", "{{ vault_trailarr_api_key }}"],
      ["TRAILARR_WEBUI_USERNAME", "{{ vault_trailarr_admin_username }}"]
    ].all? { |assignment| env_assignments.include?(assignment) }

  role_tasks = Dir[File.join(root, "roles/trailarr/tasks/*.yml")].sort
  tasks = role_tasks.flat_map { |path| flatten_tasks(YAML.safe_load_file(path, aliases: true)) }
  failures << "Trailarr must deploy through docker_compose_v2" unless
    tasks.count { |task| task.dig("community.docker.docker_compose_v2", "state") == "present" } == 1
  failures << "Trailarr must verify its effective project CPU policy" unless
    tasks.count { |task| task.dig("vars", "container_cpu_service_name") == "trailarr" } == 1

  # /config/.env is under a bind mount rather than in the Compose spec, so
  # docker_compose_v2 will not recreate the container when it changes and the
  # running process keeps the values it read at start. The repair only takes
  # effect because the role restarts the service when it changed something.
  restart = tasks.find do |task|
    task.dig("community.docker.docker_compose_v2", "state") == "restarted"
  end
  failures << "Trailarr must restart itself onto a repaired application environment" unless
    restart && restart["when"].to_s.include?("trailarr_config_env_repair is changed")

  # PUT /api/v1/settings/update reports failure with HTTP 200 and prose in the
  # body, so a task asserting status_code 200 passes on every failure -- and
  # every call writes to /config/.env, which is the drift mechanism itself.
  failures << "Trailarr must never reconcile through the settings update route" if
    tasks.any? { |task| task.to_s.include?("settings/update") }

  # batch_update's action is typed as a bare string with no enum, its four
  # accepted values live only in the endpoint description, and it answered a
  # successful monitor with a literal null body. A status code therefore proves
  # nothing here, exactly as it proves nothing for settings/update above, so the
  # reconcile has to read the library back and assert on what it finds.
  # Splitting permission from intent is only worth anything if the include
  # respects both. Dropping either clause is a silent change of meaning that no
  # other check would notice, so the condition is pinned here by name.
  monitoring_include = tasks.find do |task|
    task["ansible.builtin.include_tasks"].to_s.include?("reconcile_monitoring.yml")
  end
  failures << "Trailarr must gate the monitoring reconcile on usenet and on intent" unless
    monitoring_include &&
      %w[media_usenet_enabled trailarr_monitor_all_media].all? { |name|
        Array(monitoring_include["when"]).any? { |clause| clause.to_s.include?(name) }
      }

  monitoring = flatten_tasks(
    YAML.safe_load_file(
      File.join(root, "roles/trailarr/tasks/reconcile_monitoring.yml"), aliases: true
    )
  )
  failures << "Trailarr must monitor through one batch request, not a loop" unless
    monitoring.count { |task|
      task.dig("ansible.builtin.uri", "url").to_s.include?("media/batch_update")
    } == 1 &&
      monitoring.none? { |task|
        task["loop"] && task.dig("ansible.builtin.uri", "url").to_s.include?("media/")
      }
  failures << "Trailarr must prove the batch update by re-reading the library" unless
    monitoring.any? { |task| task["ansible.builtin.assert"] } &&
      monitoring.count { |task|
        task.dig("ansible.builtin.uri", "url").to_s.end_with?("media/all")
      } == 2
  # An item Trailarr already counts satisfied must be excluded by set membership.
  # downloaded_at reads null even on a satisfied item, so keying off it would
  # re-monitor every finished title forever.
  failures << "Trailarr must exclude satisfied media by set membership" unless
    monitoring.any? { |task|
      task.dig("ansible.builtin.uri", "url").to_s.end_with?("media/downloaded")
    } && monitoring.to_s.include?("difference") &&
      !monitoring.to_s.include?("downloaded_at")
  # Every task carrying the API key is redacted, so the count is reported by a
  # separate debug built from ids and lengths alone.
  failures << "Trailarr monitoring must redact every task carrying the API key" unless
    monitoring.select { |task| task.to_s.include?("vault_trailarr_api_key") }
              .all? { |task| task["no_log"] == true }
  failures << "Trailarr monitoring must report its plan from non-credential facts" unless
    monitoring.any? { |task|
      task["ansible.builtin.debug"] && task["no_log"].nil?
    }
  # A converged library must write nothing, or the role reports changed forever.
  failures << "Trailarr must skip the batch update when nothing is unmonitored" unless
    monitoring.any? { |task|
      task.dig("ansible.builtin.uri", "url").to_s.include?("media/batch_update") &&
        Array(task["when"]).any? { |clause|
          clause.to_s.include?("trailarr_media_to_monitor | length > 0")
        }
    }
  # A read that does not run under --check leaves the selection empty and makes
  # the prediction a lie.
  failures << "Trailarr monitoring reads must run under check mode" unless
    monitoring.select { |task| task["ansible.builtin.uri"] &&
                               task.dig("ansible.builtin.uri", "method") == "GET" }
              .all? { |task| task["changed_when"] == false && task["check_mode"] == false }

  # The reconcile is a hand-rolled parse and compare rather than a template,
  # because the entrypoint rewrites the GPU block and the yt-dlp version line on
  # every start and a whole-file template would report changed forever.
  reconcile_env = File.read(File.join(root, "roles/trailarr/tasks/reconcile_env.yml"))
  failures << "the Trailarr application environment must not be templated whole" if
    reconcile_env.include?("ansible.builtin.template")
  %w[API_KEY LOG_LEVEL WAIT_FOR_MEDIA YT_COOKIES_PATH].each do |name|
    failures << "Trailarr must rewrite the persisted #{name} line on a mismatch" unless
      reconcile_env.include?("^#{name}=.*$")
  end
  failures << "Trailarr must leave the entrypoint's own keys alone" if
    reconcile_env.include?("YTDLP_VERSION") || reconcile_env.include?("GPU_AVAILABLE")
  # A YAML block scalar keeps a backslash as an ordinary character and Jinja's
  # string literal does not unescape it back, so joining on a written-out
  # backslash-n collapses the whole file onto one line. The application sources
  # that as a single comment and keeps nothing, and the repair reports changed
  # forever because what it wrote never matches what it reads back. The
  # separator must come from a scalar YAML resolves to a real newline first.
  # Read without the commentary, so the rule can be explained in the file it
  # governs without the explanation tripping it.
  reconcile_env_code = reconcile_env.lines.reject { |line| line.strip.start_with?("#") }.join
  failures << "the Trailarr application environment must be joined on a real newline" if
    reconcile_env_code.include?(%q{join('\n')}) || reconcile_env_code.include?(%q{~ '\n'})

  credential_tasks = tasks.select do |task|
    task.to_s.match?(/vault_trailarr_(?:api_key|admin_(?:username|password))/)
  end
  failures << "every Trailarr task naming a credential must use no_log" unless
    credential_tasks.length >= 4 &&
    credential_tasks.all? { |task| task["no_log"] == true || task.key?("ansible.builtin.assert") }
  environment_render = tasks.find do |task|
    task.dig("ansible.builtin.template", "src") == "env.j2"
  end
  failures << "the Trailarr environment render must be redacted and private" unless
    environment_render && environment_render["no_log"] == true &&
      environment_render.dig("ansible.builtin.template", "mode") == "0600"

  verification = tasks.select { |task| Array(task["tags"]).include?("platform_verify_trailarr") }
  verification_urls = verification.filter_map { |task| task.dig("ansible.builtin.uri", "url") }
  failures << "Trailarr verification must read its unauthenticated status route" unless
    verification_urls.include?("{{ trailarr_status_url }}")
  authenticated = verification.find do |task|
    task.dig("ansible.builtin.uri", "headers", "X-API-KEY") == "{{ vault_trailarr_api_key }}"
  end
  failures << "Trailarr verification must read as the vault-authored API key" if authenticated.nil?
  anonymous = verification.find do |task|
    uri = task["ansible.builtin.uri"]
    uri.is_a?(Hash) && uri["url"] == "{{ trailarr_api }}/settings/" && !uri.key?("headers")
  end
  failures << "Trailarr verification must probe a protected route anonymously" if anonymous.nil?
  # The application ships admin / trailarr and the hash of that password is a
  # literal in its own settings module, so the account is refused rather than
  # merely overwritten.
  published_default = verification.find do |task|
    task.dig("ansible.builtin.uri", "body", "password") == "trailarr"
  end
  failures << "Trailarr verification must prove the published default administrator is refused" unless
    published_default &&
    published_default.dig("ansible.builtin.uri", "url") == "{{ trailarr_api }}/auth/login"

  [authenticated, anonymous, published_default].compact.each do |task|
    label = task.fetch("name")
    failures << "#{label} must accept any status and defer to the assertion" unless
      task.dig("ansible.builtin.uri", "status_code") == "{{ range(100, 600) | list }}" &&
      task["failed_when"] == false
  end
  outcome_assertion = verification.find { |task| task.key?("ansible.builtin.assert") }
  conditions = Array(outcome_assertion&.dig("ansible.builtin.assert", "that")).join(" ")
  failures << "Trailarr verification must assert its exact health and access outcomes" unless
    conditions.include?("trailarr_verify_status.json.status == 'healthy'") &&
    conditions.include?("trailarr_verify_authenticated.status") &&
    conditions.include?("trailarr_verify_anonymous.status") &&
    conditions.include?("trailarr_verify_default_identity.status")
  # The diagnosis is the point of deferring, so it must not be redacted away.
  failures << "the Trailarr outcome assertion must stay readable" if
    outcome_assertion && outcome_assertion["no_log"]

  failures << "Trailarr verification reads must not claim a change" unless
    verification.all? do |task|
      !task.key?("ansible.builtin.uri") ||
        (task["changed_when"] == false && task["check_mode"] == false)
    end
end

unless failures.empty?
  warn failures.join("\n")
  exit 1
end
RUBY

[ "$mode" = static ] && {
  printf '%s\n' 'trailarr static contract: declared trailer writer ownership holds'
  exit 0
}

# The runtime half. Both disposable lanes deploy Trailarr under a project
# namespace and name the container after it; production leaves the namespace
# empty and keeps the canonical Compose name.
: "${PLATFORM_CONTRACT_VAULT_FILE:=${PLATFORM_MAC_VAULT_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:=${PLATFORM_MAC_VAULT_PASSWORD_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_FILE:?PLATFORM_CONTRACT_VAULT_FILE is required}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:?PLATFORM_CONTRACT_VAULT_PASSWORD_FILE is required}"
: "${PLATFORM_DOCKER_ROOT:?PLATFORM_DOCKER_ROOT is required}"
: "${PLATFORM_TRAILARR_PORT:=7889}"
: "${PLATFORM_TRAILARR_ARRS:=false}"
PLATFORM_TRAILARR_CONTAINER=${PLATFORM_PROJECT_NAME:+$PLATFORM_PROJECT_NAME-}trailarr
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
export PLATFORM_DOCKER_ROOT PLATFORM_TRAILARR_PORT PLATFORM_TRAILARR_CONTAINER
export PLATFORM_TRAILARR_ARRS

exec ruby - <<'RUBY'
require "json"
require "net/http"
require "open3"
require "uri"
require "yaml"

READY_TIMEOUT_SECONDS = 120
BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_TRAILARR_PORT'), 10)}")
CONTAINER = ENV.fetch("PLATFORM_TRAILARR_CONTAINER")
ARRS_EXPECTED = ENV.fetch("PLATFORM_TRAILARR_ARRS") == "true"
# The application's own environment file, which is not the Compose one. It is
# sourced with `set -o allexport` over the container environment at every start,
# so what it holds is what the application actually runs with.
APPLICATION_ENV = File.join(ENV.fetch("PLATFORM_DOCKER_ROOT"), "trailarr", "config", ".env")
DATABASE = File.join(ENV.fetch("PLATFORM_DOCKER_ROOT"), "trailarr", "config", "trailarr.db")
# Persisted on every boot by the configuration object's constructor, so the
# platform owns their values; everything else it writes is a hand edit.
HAND_WRITTEN_KEYS = %w[
  WEBUI_USERNAME WEBUI_PASSWORD WEBUI_DISABLE_AUTH MONITOR_ENABLED
  DOWNLOADS_ENABLED CREATE_MISSING_FOLDERS DELETE_TRAILER_CONNECTION
  DELETE_TRAILER_MEDIA URL_BASE
].freeze

def fail_contract(message)
  warn "Trailarr contract failed: #{message}"
  exit 1
end

def request(message)
  Net::HTTP.start(BASE.host, BASE.port, read_timeout: 15) { |http| http.request(message) }
end

def get(path, key: nil)
  message = Net::HTTP::Get.new(URI.join(BASE, path))
  message["X-API-KEY"] = key if key
  request(message)
end

def wait_for_health
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + READY_TIMEOUT_SECONDS
  loop do
    begin
      response = get("/status")
      return response if response.code == "200"
    rescue StandardError
      nil
    end
    # A 404 here is the hourly nvidia probe failing rather than a missing route,
    # and a container that is up with nothing listening is a failed alembic
    # migration sleeping forever after restoring its own backup.
    fail_contract("Trailarr never answered its status route") if
      Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    sleep 2
  end
end

health = wait_for_health
begin
  document = JSON.parse(health.body)
rescue JSON::ParserError
  fail_contract("Trailarr status route did not answer JSON")
end
fail_contract("Trailarr did not report a healthy status") unless
  document == { "status" => "healthy" }

state, _error, status = Open3.capture3(
  "docker", "inspect", CONTAINER, "--format", "{{.State.Health.Status}}"
)
fail_contract("the Trailarr container could not be inspected") unless status.success?
fail_contract("the Trailarr container is not healthy") unless state.strip == "healthy"

vault_yaml, vault_error, vault_status = Open3.capture3(
  "ansible-vault", "view", "--vault-password-file",
  ENV.fetch("PLATFORM_CONTRACT_VAULT_PASSWORD_FILE"),
  ENV.fetch("PLATFORM_CONTRACT_VAULT_FILE")
)
fail_contract("encrypted vault could not be read") unless vault_status.success?
vault = YAML.safe_load(vault_yaml)
vault_yaml.replace("\0" * vault_yaml.bytesize)
vault_error.replace("\0" * vault_error.bytesize)
api_key = vault.fetch("vault_trailarr_api_key")
username = vault.fetch("vault_trailarr_admin_username")
password = vault.fetch("vault_trailarr_admin_password")

# Three outcomes over the same protected route and the same login: refused with
# no credential, refused as the published default administrator the image ships,
# accepted as exactly the vault's.
fail_contract("Trailarr served a protected route to an anonymous request") unless
  get("/api/v1/settings/").code == "401"

def login(username, password)
  message = Net::HTTP::Post.new(URI.join(BASE, "/api/v1/auth/login"))
  message["Content-Type"] = "application/json"
  message.body = JSON.dump("username" => username, "password" => password)
  request(message)
end

fail_contract("Trailarr accepted the published default administrator") unless
  login("admin", "trailarr").code == "401"
fail_contract("Trailarr refused the vault-authored administrator") unless
  login(username, password).code == "200"

settings = get("/api/v1/settings/", key: api_key)
fail_contract("Trailarr refused the vault-authored API key") unless settings.code == "200"
declared = JSON.parse(settings.body)
fail_contract("Trailarr does not serve the vault-authored administrator name") unless
  declared["webui_username"] == username
{
  "webui_disable_auth" => false, "create_missing_folders" => false,
  "delete_trailer_connection" => false, "delete_trailer_media" => false,
  "update_ytdlp" => false, "ytdlp_nightly" => false,
  "monitor_enabled" => false, "downloads_enabled" => false
}.each do |field, expected|
  fail_contract("Trailarr does not report #{field} as the platform declares it") unless
    declared[field] == expected
end

# The finding this whole role exists for. /config/.env is sourced with
# `set -o allexport` after the container environment is already in place, so
# every key it holds overwrites the Compose-supplied value permanently. The
# platform's four keys must be present and correct, and every key only a hand
# edit writes must be absent -- removing one *is* the repair.
fail_contract("Trailarr did not write its own application environment") unless
  File.file?(APPLICATION_ENV)
application_env = File.readlines(APPLICATION_ENV, chomp: true).filter_map do |line|
  stripped = line.strip
  next unless stripped.match?(/\A[A-Z][A-Z0-9_]*=/)

  name, _separator, value = stripped.partition("=")
  [name, value]
end.to_h
# python-dotenv writes KEY='value' with quote_mode="always", and the application
# defensively strips stray quotes out of WEBUI_PASSWORD -- which is only
# necessary because that form has bitten people. The deployed line is pinned to
# the quoted form, with the hash NOT $-doubled: this file is sourced by bash,
# where the Compose escaping would be a literal.
fail_contract("Trailarr does not carry the vault-authored API key in its own environment") unless
  application_env["API_KEY"] == "'#{api_key}'"
# WEBUI_PASSWORD in particular is never written by a converged deployment: the
# constructor only persists it when the supplied value is empty, so a line
# here is a login changed by hand, and it would beat the vault's on the next
# start. Its presence is the drift, and removing it is the repair.
HAND_WRITTEN_KEYS.each do |key|
  fail_contract("Trailarr's application environment carries a hand-written #{key}") if
    application_env.key?(key)
end

# Both profiles ship mkv/vp9/opus and the Movie one ships the trailer beside the
# movie file, so both are reconciled or the very first download lands wrong.
profiles = get("/api/v1/trailerprofiles/", key: api_key)
fail_contract("the Trailarr trailer profiles could not be read") unless profiles.code == "200"
seeded = JSON.parse(profiles.body).select { |profile| [1, 2].include?(profile["id"]) }
fail_contract("Trailarr does not hold both seeded trailer profiles") unless seeded.length == 2
seeded.each do |profile|
  {
    "folder_enabled" => true, "folder_name" => "Trailers",
    "custom_folder" => "{media_folder}", "file_format" => "mp4",
    "video_format" => "h264", "audio_format" => "aac"
  }.each do |field, expected|
    fail_contract("Trailarr trailer profile #{profile['id']} does not declare #{field}") unless
      profile[field] == expected
  end
end

connections = get("/api/v1/connections/", key: api_key)
fail_contract("the Trailarr connections could not be read") unless connections.code == "200"
declared_connections = JSON.parse(connections.body)
if ARRS_EXPECTED
  %w[Radarr Sonarr].each do |name|
    matches = declared_connections.select { |entry| entry["name"] == name }
    # The create route has no duplicate check: three identical creates produced
    # ids 1, 2 and 3, so a second row is what a create-if-absent reconciler
    # leaves behind.
    fail_contract("Trailarr does not hold exactly one #{name} connection") unless
      matches.length == 1
    connection = matches.first
    fail_contract("the Trailarr #{name} connection is not addressed by service alias") unless
      connection["url"] == "http://#{name.downcase}:#{name == 'Radarr' ? 7878 : 8989}"
    # A declared mapping reads back with a trailing slash and reports drift
    # forever; the Compose mounts are what make one unnecessary.
    fail_contract("the Trailarr #{name} connection declares a path mapping") unless
      Array(connection["path_mappings"]).empty?
    fail_contract("the Trailarr #{name} connection monitors new media before acceptance") if
      connection["monitor_new_media"]
  end
else
  fail_contract("Trailarr declared an arr connection with no transport enabled") unless
    declared_connections.empty?
end

fail_contract("Trailarr did not persist its database in the declared config root") unless
  File.file?(DATABASE) && File.size?(DATABASE)

puts "trailarr contract: health, exclusive identity, owned application environment, " \
     "declared profiles and connections, and persisted state hold"
RUBY
