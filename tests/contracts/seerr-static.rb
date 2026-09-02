#!/usr/bin/env ruby
# The static half of the Seerr service contract: bootstrapped request front end
# ownership, decided from the repository alone with nothing deployed.
#
# usage: seerr-static.rb REPOSITORY
#
# PLATFORM_CONTRACT_REPO_DIR names the same repository and is read below for
# tests/policy_support.rb, so this program carries no copy of flatten_tasks.
#
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

  # Seerr reads Jellyfin's users and writes Radarr's and Sonarr's connection
  # rows, addressing all three by Compose service alias, so unlike Kapowarr and
  # Pinchflat it is not self-contained and has to join the shared control
  # network.
  failures << "Seerr must join the shared media control network" unless
    Array(service["networks"]).include?("media-control") &&
    compose.dig("networks", "media-control", "external") == true

  # The image sets User: node:node with gid 1000, which is not this platform's
  # gid, and its entrypoint neither starts as root nor re-executes, so the only
  # way the platform identity reaches the process is a Compose `user:`. Neither
  # gosu nor su-exec is in the image, so PUID/PGID would be dead configuration.
  failures << "Seerr must run as the shared platform identity" unless
    service["user"] == "${NAS_UID:?}:${NAS_GID:?}"
  # npm start forks; without an init the container accumulates zombies.
  failures << "Seerr must reap what npm start forks" unless service["init"] == true

  # The whole of Seerr's authentication, and the one thing that makes it fit
  # this platform: the application reads API_KEY on every start and overwrites
  # a drifted stored value with it, so the credential never has to be read back.
  failures << "Seerr must require its API key from the rendered environment" unless
    service.dig("environment", "API_KEY") == "${SEERR_API_KEY:?}"

  failures << "Seerr must mount exactly its configuration root" unless
    Array(service["volumes"]) == ["${SEERR_CONFIG_PATH:?}:/app/config"]
  failures << "Seerr must publish the catalog web UI port" unless
    Array(service["ports"]) == ["5055:5055"]
  mac = YAML.safe_load_file(File.join(root, "services/seerr/compose.mac.yml"))
  failures << "the Mac override must republish the web UI on the harness port" unless
    mac.dig("services", "seerr", "ports") == ["${SEERR_HOST_PORT:?}:5055"]

  # The image ships no HEALTHCHECK, so docker_compose_v2 with wait: true would
  # return as soon as the container is running and the next task would race a
  # server that takes several seconds more to answer. curl is absent from the
  # image and wget is the BusyBox applet, so the probe has to be spelled this
  # way, and it has to read a route that answers 200 before the bootstrap as
  # well as after it.
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
  # The design's two identities. ADMIN short-circuits every check, so the owner
  # needs the single bit; 160 is REQUEST plus AUTO_APPROVE and deliberately
  # excludes every 4K bit and every MANAGE_* bit.
  failures << "the Seerr owner must hold exactly ADMIN" unless
    defaults["seerr_owner_permissions"] == 2
  failures << "the Seerr household identity must hold exactly REQUEST and AUTO_APPROVE" unless
    defaults["seerr_household_permissions"] == 160
  # defaultPermissions ships 32 and newPlexLogin ships true, and together they
  # give every Jellyfin user who signs in a standing request permission the
  # design never granted. mediaServerLogin is deliberately absent: it is not the
  # auto-create switch but the one that enables Jellyfin sign-in at all, and
  # false there locks out the two imported identities as well.
  declared = defaults["seerr_main_settings"]
  failures << "Seerr must pin the sign-in policy the design requires" unless
    declared.is_a?(Hash) && declared["defaultPermissions"] == 0 &&
    declared["newPlexLogin"] == false && declared["localLogin"] == false
  failures << "Seerr must not disable Jellyfin sign-in for its own identities" if
    declared.is_a?(Hash) && declared.key?("mediaServerLogin")
  # MediaServerType.JELLYFIN. Without it the bootstrap answers 500
  # NO_ADMIN_USER, which reads as a Jellyfin permission problem and is not.
  failures << "the Seerr bootstrap must declare the Jellyfin media server type" unless
    defaults["seerr_media_server_type"] == 2
  # Radarr's and Sonarr's own keys, consumed rather than minted again.
  failures << "Seerr must consume the arrs' own API keys" unless
    defaults.dig("seerr_radarr_server", "apiKey") == "{{ vault_arr_radarr_api_key }}" &&
    defaults.dig("seerr_sonarr_server", "apiKey") == "{{ vault_arr_sonarr_api_key }}"
  # ntfy runs deny-all, so an agent without a token publishes nothing and fails
  # silently. Seerr holds its own identity rather than the deploy account's.
  failures << "Seerr's ntfy agent must authenticate with its own bearer token" unless
    defaults.dig("seerr_ntfy_declaration", "options", "authMethodToken") == true &&
    defaults.dig("seerr_ntfy_declaration", "options", "token") == "{{ vault_ntfy_seerr_token }}"

  env_assignments = environment_assignments(File.join(root, "roles/seerr/templates/env.j2"))
  failures << "Seerr env must render the CPU set exactly once" unless
    env_assignments.select { |name, _value| name == "PLATFORM_CONTAINER_CPUSET" } ==
      [["PLATFORM_CONTAINER_CPUSET", "{{ platform_effective_container_cpuset }}"]]
  failures << "Seerr env must carry the vault-authored API key" unless
    env_assignments.include?(["SEERR_API_KEY", "{{ vault_seerr_api_key }}"])
  # Seerr has no administrator password of its own and must not grow one: its
  # owner row is created with a Jellyfin user type and no local password.
  failures << "Seerr must not invent an administrator credential of its own" if
    env_assignments.any? { |name, _value| name.match?(/SEERR_(?:ADMIN|PASSWORD|WEBUI)/) }

  tasks = %w[main bootstrap reconcile_settings reconcile_arrs reconcile_users].flat_map do |file|
    flatten_tasks(
      YAML.safe_load_file(File.join(root, "roles/seerr/tasks/#{file}.yml"), aliases: true)
    )
  end
  failures << "Seerr must deploy through docker_compose_v2" unless
    tasks.count { |task| task.dig("community.docker.docker_compose_v2", "state") == "present" } == 1
  failures << "Seerr must verify its effective project CPU policy" unless
    tasks.count { |task| task.dig("vars", "container_cpu_service_name") == "seerr" } == 1

  # The bootstrap is the one task that closes the anonymous takeover window on
  # POST /api/v1/auth/jellyfin, and it has to be guarded so a reconverge does
  # not mint a second Jellyfin device session and report a change forever.
  bootstrap = tasks.find do |task|
    task.dig("ansible.builtin.uri", "url").to_s.end_with?("/auth/jellyfin")
  end
  failures << "Seerr must bootstrap its owner from the vault Jellyfin administrator" unless
    bootstrap && bootstrap.dig("ansible.builtin.uri", "method") == "POST" &&
    bootstrap.dig("ansible.builtin.uri", "body", "password") ==
      "{{ vault_jellyfin_admin_password }}" &&
    bootstrap["no_log"] == true &&
    Array(bootstrap["when"]).include?("seerr_needs_bootstrap | bool")

  # Nothing here is create-if-absent: the arr create routes append blindly, and
  # the permission write is unconditional. Every write is guarded, and every
  # write is skipped under --check with a debug naming the planned change.
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
    # The user row with id 1 is the only thing that closes the takeover window,
    # so its absence has to be a verification failure rather than a 403 nobody
    # reads.
    conditions.any? { |value| value.include?("selectattr('id', 'equalto', 1)") } &&
    conditions.any? { |value| value.include?("newPlexLogin") } &&
    conditions.any? { |value| value.include?("mediaServerLogin") }
  failures << "the Seerr outcome assertion must stay readable" if
    outcome_assertion && outcome_assertion["no_log"]
end

unless failures.empty?
  warn failures.join("\n")
  exit 1
end
