#!/usr/bin/env ruby
# Static half of the Trailarr contract, decided from the repository alone.
# usage: trailarr-static.rb REPOSITORY
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

# Read as assignments: a commented-out sample would satisfy a substring search.
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

  # Trailarr validates connections with live calls by service name, so it joins
  # the control network (unlike the self-contained contracts).
  failures << "Trailarr must join the shared media control network" unless
    Array(service["networks"]) == %w[default media-control]
  failures << "the shared media control network must be the external one" unless
    compose.dig("networks", "media-control") ==
      { "external" => true, "name" => "${PLATFORM_MEDIA_NETWORK:?}" }

  # The root entrypoint chowns and drops through gosu; `user:` would break it.
  failures << "Trailarr must not override the container user" if service.key?("user")
  {
    "PUID" => "${NAS_UID:?}",
    "PGID" => "${NAS_GID:?}"
  }.each do |name, expected|
    failures << "Trailarr must take the platform identity as #{name}" unless
      service.dig("environment", name) == expected
  end
  # UMASK is read nowhere, so declaring it would be a no-op mistaken for a control.
  failures << "Trailarr must not declare an unsupported UMASK" if
    service.fetch("environment", {}).key?("UMASK")

  # Container paths equal Radarr's and Sonarr's, so no path mapping is needed (a
  # mapping reads back with a trailing slash and reports drift).
  failures << "Trailarr must mount exactly its config and the two arr libraries" unless
    Array(service["volumes"]) == [
      "${TRAILARR_CONFIG_PATH:?}:/config",
      "${TRAILARR_MOVIES_PATH:?}:/data/media/Movies",
      "${TRAILARR_SERIES_PATH:?}:/data/media/Series"
    ]

  # `:?` refuses an unset credential rather than publishing a default admin.
  {
    "API_KEY" => "${TRAILARR_API_KEY:?}",
    "WEBUI_USERNAME" => "${TRAILARR_WEBUI_USERNAME:?}",
    "WEBUI_PASSWORD" => "${TRAILARR_WEBUI_PASSWORD_HASH:?}"
  }.each do |name, expected|
    failures << "Trailarr must require #{name} from the rendered environment" unless
      service.dig("environment", name) == expected
  end

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

  # curl ships in the image; wget and busybox do not.
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
  # Read from the Compose mount, which decides the container path (#358).
  library_mounts = Array(service["volumes"]).map(&:to_s)
  {
    "${TRAILARR_MOVIES_PATH:?}" => "arr_radarr_root_folder",
    "${TRAILARR_SERIES_PATH:?}" => "arr_sonarr_root_folder"
  }.each do |mount_source, arr_key|
    failures << "#{mount_source} must be mounted at #{arr_key}, or every import needs a path mapping" unless
      library_mounts.include?("#{mount_source}:#{arr_defaults[arr_key]}")
  end
  failures << "Trailarr must address both arrs by their Compose service alias" unless
    Array(defaults["trailarr_connections"]).map { |entry| entry["url"] } ==
      ["http://radarr:7878", "http://sonarr:8989"]
  # Fetching stays off by default, so a lane never calls YouTube.
  failures << "Trailarr monitoring must default to off" unless
    defaults["trailarr_monitoring_enabled"] == false
  # Intent is separate from permission, so a lane can reconcile without downloading.
  failures << "Trailarr must intend a trailer for every item by default" unless
    defaults["trailarr_monitor_all_media"] == true
  failures << "Trailarr must reconcile both seeded trailer profiles" unless
    Array(defaults["trailarr_trailer_profiles"]).map { |entry| entry["id"] } == [1, 2]
  failures << "Trailarr must declare a directly playable trailer in the item's own folder" unless
    defaults["trailarr_trailer_profile_settings"] == {
      "folder_enabled" => true, "folder_name" => "Trailers",
      "custom_folder" => "{media_folder}", "file_format" => "mp4",
      "video_format" => "h264", "audio_format" => "aac"
    }
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
  # Compose truncates an unescaped $ in an env file, so every $ is doubled there;
  # /config/.env is sourced by bash and takes the hash single-quoted instead.
  failures << "Trailarr env must double every $ in the administrator hash for Compose" unless
    env_assignments.include?(
      ["TRAILARR_WEBUI_PASSWORD_HASH",
       "{{ vault_trailarr_admin_password_hash | replace('$', '$$') }}"]
    )
  failures << "Trailarr env must carry the vault-authored identity" unless
    [
      ["TRAILARR_API_KEY", "{{ vault_trailarr_api_key }}"],
      ["TRAILARR_WEBUI_USERNAME",
       "{{ vault_trailarr_admin_username | replace('$', '$$') }}"]
    ].all? { |assignment| env_assignments.include?(assignment) }

  role_tasks = Dir[File.join(root, "roles/trailarr/tasks/*.yml")].sort
  tasks = role_tasks.flat_map { |path| flatten_tasks(YAML.safe_load_file(path, aliases: true)) }
  # One deployment `up`; recovery lives in roles/container_health/tasks/recover.yml
  # (#646) and is counted as its include.
  compose_ups = tasks.select { |task| task.dig("community.docker.docker_compose_v2", "state") == "present" }
  failures << "Trailarr must deploy through docker_compose_v2" unless
    compose_ups.count { |task| !task["community.docker.docker_compose_v2"].key?("recreate") } == 1
  failures << "Trailarr must force-recreate a stuck container exactly once per converge" unless
    tasks.count { |task|
      task.dig("ansible.builtin.include_role", "name") == "container_health" &&
        task.dig("ansible.builtin.include_role", "tasks_from") == "recover"
    } == 1
  failures << "Trailarr must verify its effective project CPU policy" unless
    tasks.count { |task| task.dig("vars", "container_cpu_service_name") == "trailarr" } == 1

  # /config/.env is not in the Compose spec, so only the role's restart applies it.
  restart = tasks.find do |task|
    task.dig("community.docker.docker_compose_v2", "state") == "restarted"
  end
  failures << "Trailarr must restart itself onto a repaired application environment" unless
    restart && restart["when"].to_s.include?("trailarr_config_env_repair is changed")

  # settings/update reports failure as HTTP 200 and rewrites /config/.env.
  failures << "Trailarr must never reconcile through the settings update route" if
    tasks.any? { |task| task.to_s.include?("settings/update") }

  # batch_update's status proves nothing, so the reconcile reads the library back.
  # Both permission and intent clauses are pinned by name.
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
  # downloaded_at is null even when satisfied, so exclude by set membership.
  failures << "Trailarr must exclude satisfied media by set membership" unless
    monitoring.any? { |task|
      task.dig("ansible.builtin.uri", "url").to_s.end_with?("media/downloaded")
    } && monitoring.to_s.include?("difference") &&
      !monitoring.to_s.include?("downloaded_at")
  failures << "Trailarr monitoring must redact every task carrying the API key" unless
    monitoring.select { |task| task.to_s.include?("vault_trailarr_api_key") }
              .all? { |task| task["no_log"] == true }
  failures << "Trailarr monitoring must report its plan from non-credential facts" unless
    monitoring.any? { |task|
      task["ansible.builtin.debug"] && task["no_log"].nil?
    }
  failures << "Trailarr must skip the batch update when nothing is unmonitored" unless
    monitoring.any? { |task|
      task.dig("ansible.builtin.uri", "url").to_s.include?("media/batch_update") &&
        Array(task["when"]).any? { |clause|
          clause.to_s.include?("trailarr_media_to_monitor | length > 0")
        }
    }
  failures << "Trailarr monitoring reads must run under check mode" unless
    monitoring.select { |task| task["ansible.builtin.uri"] &&
                               task.dig("ansible.builtin.uri", "method") == "GET" }
              .all? { |task| task["changed_when"] == false && task["check_mode"] == false }

  # Parsed, not templated: the entrypoint rewrites parts of the file on every start.
  reconcile_env = File.read(File.join(root, "roles/trailarr/tasks/reconcile_env.yml"))
  failures << "the Trailarr application environment must not be templated whole" if
    reconcile_env.include?("ansible.builtin.template")
  %w[API_KEY LOG_LEVEL WAIT_FOR_MEDIA YT_COOKIES_PATH].each do |name|
    failures << "Trailarr must rewrite the persisted #{name} line on a mismatch" unless
      reconcile_env.include?("^#{name}=.*$")
  end
  failures << "Trailarr must leave the entrypoint's own keys alone" if
    reconcile_env.include?("YTDLP_VERSION") || reconcile_env.include?("GPU_AVAILABLE")
  # The separator must be a real newline: a written-out \n in a block scalar joins
  # the file onto one line that the app reads as a comment. Comments are stripped
  # so this explanation cannot trip the rule.
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
  # The shipped admin/trailarr account is refused, not merely overwritten.
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
  failures << "the Trailarr outcome assertion must stay readable" if
    outcome_assertion && outcome_assertion["no_log"]

  failures << "Trailarr verification reads must not claim a change" unless
    verification.all? do |task|
      !task.key?("ansible.builtin.uri") ||
        (task["changed_when"] == false && task["check_mode"] == false)
    end
end

unless failures.empty?
  # One line per violation with the contract's prefix, which contract tests
  # match on (#352).
  warn failures.map { |failure| "Trailarr contract failed: #{failure}" }.join("\n")
  exit 1
end
