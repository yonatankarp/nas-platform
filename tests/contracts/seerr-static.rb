#!/usr/bin/env ruby
# Static half of the Seerr contract, decided from the repository alone.
# usage: seerr-static.rb REPOSITORY
require "yaml"

root = ARGV.fetch(0)
failures = []
required = %w[
  roles/seerr/defaults/main.yml
  roles/seerr/meta/argument_specs.yml
  roles/seerr/tasks/main.yml
  roles/seerr/tasks/bootstrap.yml
  roles/seerr/tasks/reconcile_settings.yml
  roles/seerr/tasks/reconcile_arrs.yml
  roles/seerr/tasks/reconcile_users.yml
  roles/seerr/templates/env.j2
  services/seerr/compose.yml
  services/seerr/compose.mac.yml
  services/seerr/compose.integration.yml
]
required.each do |relative|
  failures << "missing #{relative}" unless File.file?(File.join(root, relative))
end

require File.join(ENV.fetch("PLATFORM_CONTRACT_REPO_DIR"), "tests", "policy_support")
include PolicySupport

def environment_assignments(path)
  File.readlines(path, chomp: true).filter_map do |line|
    stripped = line.strip
    next unless stripped.match?(/\A[A-Z][A-Z0-9_]*=/)

    name, _separator, value = stripped.partition("=")
    [name, value]
  end
end

if failures.empty?
  compose = YAML.safe_load_file(File.join(root, "services/seerr/compose.yml"), aliases: true)
  service = compose.fetch("services").fetch("seerr")

  # Addresses Jellyfin and the arrs by service alias, so it joins the control network.
  failures << "Seerr must join the shared media control network" unless
    Array(service["networks"]).include?("media-control") &&
    compose.dig("networks", "media-control", "external") == true

  # The image runs as node (gid 1000) with no gosu/su-exec, so only `user:` works.
  failures << "Seerr must run as the shared platform identity" unless
    service["user"] == "${NAS_UID:?}:${NAS_GID:?}"
  # npm start forks; without an init the container accumulates zombies.
  failures << "Seerr must reap what npm start forks" unless service["init"] == true

  # API_KEY overwrites a drifted stored value on every start; nothing is read back.
  failures << "Seerr must require its API key from the rendered environment" unless
    service.dig("environment", "API_KEY") == "${SEERR_API_KEY:?}"

  failures << "Seerr must mount exactly its configuration root" unless
    Array(service["volumes"]) == ["${SEERR_CONFIG_PATH:?}:/app/config"]
  failures << "Seerr must publish the catalog web UI port" unless
    Array(service["ports"]) == ["5055:5055"]
  mac = YAML.safe_load_file(File.join(root, "services/seerr/compose.mac.yml"))
  failures << "the Mac override must republish the web UI on the harness port" unless
    mac.dig("services", "seerr", "ports") == ["${SEERR_HOST_PORT:?}:5055"]

  # No image HEALTHCHECK, no curl (wget is BusyBox), and the route must answer 200
  # before and after the bootstrap.
  probe = Array(service.dig("healthcheck", "test")).join(" ")
  failures << "Seerr must probe a route that answers before it is configured" unless
    probe.include?("/api/v1/settings/public")
  failures << "the Seerr probe must use BusyBox wget against 127.0.0.1" unless
    probe.include?("wget --no-verbose --tries=1 --spider") &&
    probe.include?("http://127.0.0.1:5055") && !probe.include?("localhost")
  failures << "Seerr holds the request database and must declare a stop grace period" unless
    service["stop_grace_period"] == "30s"

  defaults = YAML.safe_load_file(File.join(root, "roles/seerr/defaults/main.yml"))
  failures << "Seerr must keep its state in the declared config root" unless
    defaults["seerr_config_host_path"] == "{{ nas_docker_root }}/seerr/config"
  # ADMIN short-circuits every check; 160 is REQUEST + AUTO_APPROVE, no 4K or MANAGE_*.
  failures << "the Seerr owner must hold exactly ADMIN" unless
    defaults["seerr_owner_permissions"] == 2
  failures << "the Seerr household identity must hold exactly REQUEST and AUTO_APPROVE" unless
    defaults["seerr_household_permissions"] == 160
  # Shipped defaults grant every Jellyfin sign-in a request permission. mediaServerLogin
  # is absent deliberately: false would disable Jellyfin sign-in entirely.
  declared = defaults["seerr_main_settings"]
  failures << "Seerr must pin the sign-in policy the design requires" unless
    declared.is_a?(Hash) && declared["defaultPermissions"] == 0 &&
    declared["newPlexLogin"] == false && declared["localLogin"] == false
  failures << "Seerr must not disable Jellyfin sign-in for its own identities" if
    declared.is_a?(Hash) && declared.key?("mediaServerLogin")
  # Without it the bootstrap answers a misleading 500 NO_ADMIN_USER.
  failures << "the Seerr bootstrap must declare the Jellyfin media server type" unless
    defaults["seerr_media_server_type"] == 2
  failures << "Seerr must consume the arrs' own API keys" unless
    defaults.dig("seerr_radarr_server", "apiKey") == "{{ vault_arr_radarr_api_key }}" &&
    defaults.dig("seerr_sonarr_server", "apiKey") == "{{ vault_arr_sonarr_api_key }}"
  # The agent fails silently when disabled or missing a credential.
  pushover = defaults["seerr_pushover_declaration"]
  failures << "Seerr's Pushover agent must send with the Media application token and the vault's user key" unless
    pushover.is_a?(Hash) && pushover["enabled"] == true &&
    pushover.dig("options", "accessToken") == "{{ seerr_pushover_access_token }}" &&
    pushover.dig("options", "userToken") == "{{ seerr_pushover_user_key }}" &&
    defaults["seerr_pushover_access_token"] == "{{ vault_pushover_media_token }}" &&
    defaults["seerr_pushover_user_key"] == "{{ vault_pushover_user_key }}"
  # An ntfy agent left on would publish every request twice (#558).
  failures << "Seerr's ntfy agent must be declared off" unless
    defaults.dig("seerr_ntfy_declaration", "enabled") == false

  env_assignments = environment_assignments(File.join(root, "roles/seerr/templates/env.j2"))
  failures << "Seerr env must render the CPU set exactly once" unless
    env_assignments.select { |name, _value| name == "PLATFORM_CONTAINER_CPUSET" } ==
      [["PLATFORM_CONTAINER_CPUSET", "{{ platform_effective_container_cpuset }}"]]
  failures << "Seerr env must carry the vault-authored API key" unless
    env_assignments.include?(["SEERR_API_KEY", "{{ vault_seerr_api_key }}"])
  # The owner is a Jellyfin user with no local password.
  failures << "Seerr must not invent an administrator credential of its own" if
    env_assignments.any? { |name, _value| name.match?(/SEERR_(?:ADMIN|PASSWORD|WEBUI)/) }

  tasks = %w[main bootstrap reconcile_settings reconcile_arrs reconcile_users].flat_map do |file|
    flatten_tasks(
      YAML.safe_load_file(File.join(root, "roles/seerr/tasks/#{file}.yml"), aliases: true)
    )
  end
  # One deployment `up`; recovery lives in roles/container_health/tasks/recover.yml
  # (#646) and is counted as its include.
  compose_ups = tasks.select { |task| task.dig("community.docker.docker_compose_v2", "state") == "present" }
  failures << "Seerr must deploy through docker_compose_v2" unless
    compose_ups.count { |task| !task["community.docker.docker_compose_v2"].key?("recreate") } == 1
  failures << "Seerr must force-recreate a stuck container exactly once per converge" unless
    tasks.count { |task|
      task.dig("ansible.builtin.include_role", "name") == "container_health" &&
        task.dig("ansible.builtin.include_role", "tasks_from") == "recover"
    } == 1
  failures << "Seerr must verify its effective project CPU policy" unless
    tasks.count { |task| task.dig("vars", "container_cpu_service_name") == "seerr" } == 1

  # Guarded, so a reconverge does not mint another Jellyfin device session.
  bootstrap = tasks.find do |task|
    task.dig("ansible.builtin.uri", "url").to_s.end_with?("/auth/jellyfin")
  end
  failures << "Seerr must bootstrap its owner from the vault Jellyfin administrator" unless
    bootstrap && bootstrap.dig("ansible.builtin.uri", "method") == "POST" &&
    bootstrap.dig("ansible.builtin.uri", "body", "password") ==
      "{{ vault_jellyfin_admin_password }}" &&
    bootstrap["no_log"] == true &&
    Array(bootstrap["when"]).include?("seerr_needs_bootstrap | bool")

  # Nothing is create-if-absent, so every write is guarded and skipped under --check.
  writes = tasks.select do |task|
    uri = task["ansible.builtin.uri"]
    uri.is_a?(Hash) && %w[POST PUT].include?(uri["method"])
  end
  failures << "every Seerr write must be skipped under check mode" unless
    !writes.empty? && writes.all? { |task| Array(task["when"]).include?("not ansible_check_mode") }
  failures << "every Seerr write must be redacted" unless
    writes.all? { |task| task["no_log"] == true }
  planned = tasks.select do |task|
    task.key?("ansible.builtin.debug") && Array(task["when"]).include?("ansible_check_mode")
  end
  failures << "Seerr must report its planned mutations under check mode" unless
    planned.length >= 4

  reads = tasks.select do |task|
    uri = task["ansible.builtin.uri"]
    uri.is_a?(Hash) && (uri["method"].nil? || uri["method"] == "GET")
  end
  failures << "every Seerr read must be a read that really runs under check mode" unless
    reads.all? { |task| task["changed_when"] == false && task["check_mode"] == false }

  verification = tasks.select { |task| Array(task["tags"]).include?("platform_verify_seerr") }
  verification_urls = verification.filter_map { |task| task.dig("ansible.builtin.uri", "url") }
  failures << "Seerr verification must read its unauthenticated status endpoint" unless
    verification_urls.include?("{{ seerr_status_url }}")
  failures << "Seerr verification must read the anonymous public settings" unless
    verification_urls.include?("{{ seerr_public_settings_url }}")
  anonymous = verification.find do |task|
    uri = task["ansible.builtin.uri"]
    uri.is_a?(Hash) && uri["url"] == "{{ seerr_api }}/user" && !uri.key?("headers")
  end
  failures << "Seerr verification must probe a protected route anonymously" if anonymous.nil?
  outcome_assertion = verification.find { |task| task.key?("ansible.builtin.assert") }
  conditions = Array(outcome_assertion&.dig("ansible.builtin.assert", "that"))
  failures << "Seerr verification must assert its exact access and policy outcomes" unless
    conditions.any? { |value| value.include?("seerr_verify_anonymous.status") && value.include?("401") } &&
    conditions.any? { |value| value.include?("seerr_verify_authenticated.status") && value.include?("200") } &&
    # User row 1 closes the takeover window; its absence must fail verification.
    conditions.any? { |value| value.include?("selectattr('id', 'equalto', 1)") } &&
    conditions.any? { |value| value.include?("newPlexLogin") } &&
    conditions.any? { |value| value.include?("mediaServerLogin") }
  failures << "the Seerr outcome assertion must stay readable" if
    outcome_assertion && outcome_assertion["no_log"]
end

unless failures.empty?
  # One line per violation with the contract's prefix, which contract tests
  # match on (#352).
  warn failures.map { |failure| "Seerr contract failed: #{failure}" }.join("\n")
  exit 1
end
