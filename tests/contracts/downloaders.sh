#!/bin/sh
set -eu
set +x

mode=${1:-static}
[ "$mode" = static ] || {
  printf '%s\n' 'downloaders contract accepts only static' >&2
  exit 2
}

repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)}
ruby - "$repo_dir" <<'RUBY'
require "yaml"

root = ARGV.fetch(0)
failures = []
required = %w[
  roles/downloaders/defaults/main.yml
  roles/downloaders/tasks/main.yml
  roles/downloaders/tasks/reconcile_sabnzbd.yml
  roles/downloaders/tasks/verify.yml
  roles/downloaders/templates/env.j2
  roles/downloaders/templates/sabnzbd.ini.j2
]
required.each do |relative|
  failures << "missing #{relative}" unless File.file?(File.join(root, relative))
end

if failures.empty?
  defaults = YAML.safe_load_file(File.join(root, "roles/downloaders/defaults/main.yml"))
  expected_categories = {
    "movies" => "/data/media/.acquisition/usenet/movies",
    "series" => "/data/media/.acquisition/usenet/series",
    "ebooks" => "/data/books/.acquisition/usenet/ebooks",
    "audiobooks" => "/data/media/.acquisition/usenet/audiobooks",
    "comics" => "/data/books/.acquisition/usenet/comics"
  }
  failures << "SABnzbd category contract drifted" unless
    defaults["downloaders_sabnzbd_categories"] == expected_categories
  failures << "SABnzbd article cache must be explicitly bounded" unless
    defaults["downloaders_sabnzbd_owned_misc"].is_a?(Hash) &&
      defaults["downloaders_sabnzbd_owned_misc"]["cache_limit"] == "256M"
  failures << "SABnzbd concurrent unpack work must be explicitly bounded" unless
    defaults.dig("downloaders_sabnzbd_owned_misc", "direct_unpack_threads") == 1

  main = YAML.safe_load_file(File.join(root, "roles/downloaders/tasks/main.yml"))
  main_source = File.read(File.join(root, "roles/downloaders/tasks/main.yml"))
  failures << "downloaders role must deploy through docker_compose_v2" unless
    main.any? { |task| task["community.docker.docker_compose_v2"].is_a?(Hash) }
  failures << "downloaders role must include the state guard before deployment" unless
    main_source.index("state_guard.yml") && main_source.index("state_guard.yml") <
      main_source.index("community.docker.docker_compose_v2")
  failures << "downloaders role must verify its effective project CPU policy" unless
    main_source.scan("container_cpu_service_name: downloaders").length == 1
  failures << "downloaders role must gate activation on media_usenet_enabled" unless
    main_source.include?("media_usenet_enabled | bool")

  env = File.read(File.join(root, "roles/downloaders/templates/env.j2"))
  failures << "downloaders env must render CPU set exactly once" unless
    env.lines.map(&:strip).count("PLATFORM_CONTAINER_CPUSET={{ platform_effective_container_cpuset }}") == 1
  failures << "downloaders env must carry only declared API keys" unless
    %w[vault_downloaders_sabnzbd_api_key vault_arr_radarr_api_key vault_arr_sonarr_api_key].all? do |name|
      env.include?(name)
    end

  reconcile = YAML.safe_load_file(File.join(root, "roles/downloaders/tasks/reconcile_sabnzbd.yml"))
  secret_tasks = reconcile.select do |task|
    task.dig("ansible.builtin.uri", "url").to_s.include?("vault_downloaders_sabnzbd_api_key")
  end
  failures << "every SABnzbd credential-bearing API task must use no_log" unless
    !secret_tasks.empty? && secret_tasks.all? { |task| task["no_log"] == true }

  template = File.read(File.join(root, "roles/downloaders/templates/sabnzbd.ini.j2"))
  failures << "bootstrap must bind SABnzbd on all container interfaces" unless
    template.include?("host = 0.0.0.0") && template.include?("port = 8080")
  failures << "bootstrap must not invent a Usenet provider" if template.include?("[servers]")
  failures << "bootstrap must render every declared category and destination" unless
    template.include?("{% for category, directory in downloaders_sabnzbd_categories.items() %}") &&
      template.include?("[[{{ category }}]]") && template.include?("dir = {{ directory }}")

  compose = YAML.safe_load_file(File.join(root, "services/downloaders/compose.yml"), aliases: true)
  unpackerr = compose.dig("services", "unpackerr")
  failures << "Unpackerr must integrate both Arr services over Usenet" unless
    unpackerr.dig("environment", "UN_RADARR_0_PROTOCOLS") == "usenet" &&
      unpackerr.dig("environment", "UN_SONARR_0_PROTOCOLS") == "usenet"
  failures << "Unpackerr file and directory modes drifted" unless
    unpackerr.dig("environment", "UN_FILE_MODE") == "0644" &&
      unpackerr.dig("environment", "UN_DIR_MODE") == "0755"
end

if failures.empty?
  puts "downloaders contract: Phase 1 Usenet ownership holds"
else
  warn failures.join("\n")
  exit 1
end
RUBY
