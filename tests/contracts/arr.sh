#!/bin/sh
set -eu
set +x

mode=${1:-static}
[ "$mode" = static ] || {
  printf '%s\n' 'arr contract accepts only static' >&2
  exit 2
}

repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)}
ruby - "$repo_dir" <<'RUBY'
require "yaml"

root = ARGV.fetch(0)
failures = []
required = %w[
  roles/arr/defaults/main.yml
  roles/arr/tasks/main.yml
  roles/arr/tasks/bootstrap.yml
  roles/arr/tasks/reconcile_servarr.yml
  roles/arr/tasks/reconcile_servarr_download_client.yml
  roles/arr/tasks/reconcile_prowlarr.yml
  roles/arr/tasks/reconcile_bazarr.yml
  roles/arr/tasks/verify.yml
  roles/arr/templates/env.j2
  roles/arr/templates/config.xml.j2
  roles/arr/templates/bazarr-config.yml.j2
]
required.each do |relative|
  failures << "missing #{relative}" unless File.file?(File.join(root, relative))
end

if failures.empty?
  defaults = YAML.safe_load_file(File.join(root, "roles/arr/defaults/main.yml"))
  failures << "Radarr root must be exact" unless
    defaults["arr_radarr_root_folder"] == "/data/media/Movies"
  failures << "Sonarr root must be exact" unless
    defaults["arr_sonarr_root_folder"] == "/data/media/Series"
  failures << "automatic monitoring must stay disabled" unless
    defaults["media_arr_automatic_monitoring_enabled"] == false
  failures << "automatic rename must stay disabled" unless
    defaults["media_arr_automatic_rename_enabled"] == false
  failures << "Prowlarr applications must use full sync" unless
    defaults["arr_prowlarr_application_sync_level"] == "fullSync"

  main_source = File.read(File.join(root, "roles/arr/tasks/main.yml"))
  failures << "Arr role must deploy through docker_compose_v2" unless
    main_source.include?("community.docker.docker_compose_v2")
  failures << "Arr role must gate activation on media_usenet_enabled" unless
    main_source.include?("media_usenet_enabled | bool")
  failures << "Arr role must verify the complete project CPU policy once" unless
    main_source.scan("container_cpu_service_name: arr").length == 1

  bootstrap = File.read(File.join(root, "roles/arr/tasks/bootstrap.yml"))
  failures << "Servarr bootstrap must preserve existing config.xml" unless
    bootstrap.include?("force: false") && bootstrap.include?("config.xml.j2")
  failures << "Bazarr bootstrap must preserve existing config" unless
    bootstrap.include?("bazarr-config.yml.j2") && bootstrap.include?("config/config.yaml")

  config_xml = File.read(File.join(root, "roles/arr/templates/config.xml.j2"))
  failures << "Servarr bootstrap must use deterministic vault API keys" unless
    config_xml.include?("arr_bootstrap_api_key")
  failures << "Servarr authentication must be enabled before first start" unless
    config_xml.include?("<AuthenticationMethod>Forms</AuthenticationMethod>") &&
      config_xml.include?("<AuthenticationRequired>Enabled</AuthenticationRequired>")

  env = File.read(File.join(root, "roles/arr/templates/env.j2"))
  failures << "Arr env must render CPU set exactly once" unless
    env.lines.map(&:strip).count("PLATFORM_CONTAINER_CPUSET={{ platform_effective_container_cpuset }}") == 1
  failures << "Arr env must carry all deterministic API keys" unless
    %w[radarr sonarr prowlarr bazarr].all? { |name| env.include?("vault_arr_#{name}_api_key") }

  defaults_source = File.read(File.join(root, "roles/arr/defaults/main.yml"))
  servarr = File.read(File.join(root, "roles/arr/tasks/reconcile_servarr.yml")) +
    File.read(File.join(root, "roles/arr/tasks/reconcile_servarr_download_client.yml"))
  failures << "Servarr reconciliation must own only the SABnzbd clients" unless
    servarr.include?("Sabnzbd") && defaults_source.include?("category: movies") &&
      defaults_source.include?("category: series")
  failures << "Servarr reconciliation must create root folders without import commands" unless
    servarr.include?("rootfolder") && !servarr.match?(/command.*(import|search)/i)
  failures << "Servarr reconciliation must preserve unowned host fields" unless
    servarr.include?("combine(") && servarr.include?("config/host")
  naming_sources = servarr +
    File.read(File.join(root, "roles/arr/tasks/configarr.yml")) +
    File.read(File.join(root, "roles/arr/tasks/verify.yml"))
  failures << "Servarr rename policy must use the naming configuration API" unless
    naming_sources.include?("config/naming") && !naming_sources.include?("config/mediamanagement")

  prowlarr = File.read(File.join(root, "roles/arr/tasks/reconcile_prowlarr.yml")) +
    File.read(File.join(root, "roles/arr/tasks/reconcile_prowlarr_application.yml")) +
    defaults_source
  failures << "Prowlarr must own Radarr and Sonarr applications" unless
    %w[Radarr Sonarr fullSync].all? { |token| prowlarr.include?(token) }
  failures << "Prowlarr must not receive a download client" if
    prowlarr.match?(%r{/downloadclient|download client}i)

  bazarr = File.read(File.join(root, "roles/arr/tasks/reconcile_bazarr.yml"))
  failures << "Bazarr must connect to both Arr services" unless
    %w[settings-general-use_radarr settings-general-use_sonarr settings-radarr-apikey settings-sonarr-apikey].all? do |token|
      bazarr.include?(token)
    end
  failures << "Bazarr must retain identical paths without remote mappings" unless
    bazarr.include?("path_mappings") && bazarr.include?("path_mappings_movie")

  secret_sources = %w[
    roles/arr/tasks/reconcile_servarr.yml
    roles/arr/tasks/reconcile_prowlarr.yml
    roles/arr/tasks/reconcile_bazarr.yml
  ].map { |path| File.read(File.join(root, path)) }
  failures << "all Arr API reconciliation must redact secret-bearing payloads" unless
    secret_sources.all? { |source| source.include?("no_log: true") }
end

if failures.empty?
  puts "arr contract: Phase 1 API ownership holds"
else
  warn failures.join("\n")
  exit 1
end
RUBY
