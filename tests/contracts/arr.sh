#!/bin/sh
set -eu
set +x

mode=${1:-static}
[ "$mode" = static ] || {
  printf '%s\n' 'arr contract accepts only static' >&2
  exit 2
}

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

# Task files are flattened so a task on a block's rescue or always path is still
# a task the role executes.
require File.join(ENV.fetch("PLATFORM_CONTRACT_REPO_DIR"), "tests", "policy_support")
include PolicySupport

# Assertions about what the role does read the parsed structure rather than the
# file's bytes: a module named in a comment is not a module the role runs, and a
# literal found anywhere in the file does not belong to the task the assertion
# names. role_strings collects the strings one at a time rather than joining
# them, because a pattern matched against a joined blob spans two unrelated
# tasks — or, when two files were concatenated, two unrelated files — and reports
# a violation neither of them contains.
def role_strings(node)
  case node
  when Hash then node.flat_map { |key, value| [key.to_s] + role_strings(value) }
  when Array then node.flat_map { |value| role_strings(value) }
  when String then [node]
  else []
  end
end

def role_tasks(root, relative)
  flatten_tasks(YAML.safe_load_file(File.join(root, relative), aliases: true))
end

# A folded scalar carries its line breaks into the parsed value, so a URL written
# across two lines is compared in its collapsed form.
def request_urls(tasks)
  tasks.filter_map do |task|
    uri = task["ansible.builtin.uri"]
    uri["url"].to_s.gsub(/[[:space:]]+/, "") if uri.is_a?(Hash) && uri["url"]
  end
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

  main_tasks = role_tasks(root, "roles/arr/tasks/main.yml")
  compose_activations = main_tasks.select do |task|
    task.dig("community.docker.docker_compose_v2", "state") == "present"
  end
  activation_task = compose_activations.first
  failures << "Arr role must deploy through docker_compose_v2" unless
    compose_activations.length == 1
  failures << "Arr role must gate activation on media_usenet_enabled" unless
    activation_task && Array(activation_task["when"]).any? do |condition|
      condition.to_s.include?("media_usenet_enabled | bool")
    end
  failures << "Arr role must verify the complete project CPU policy once" unless
    main_tasks.count { |task| task.dig("vars", "container_cpu_service_name") == "arr" } == 1

  # force: false is what preserves an operator's existing file, and it has to be
  # on the task that writes that file. The pair of substring checks this replaced
  # could not tell the two seed tasks apart: either task's force satisfied both,
  # and the Bazarr half never asked about force at all.
  bootstrap_tasks = role_tasks(root, "roles/arr/tasks/bootstrap.yml")
  servarr_seed = bootstrap_tasks.find do |task|
    task.dig("ansible.builtin.template", "src") == "config.xml.j2"
  end
  failures << "Servarr bootstrap must preserve existing config.xml" unless
    servarr_seed && servarr_seed.dig("ansible.builtin.template", "force") == false &&
      servarr_seed.dig("ansible.builtin.template", "dest").to_s.end_with?("/config.xml")
  bazarr_seed = bootstrap_tasks.find do |task|
    task.dig("ansible.builtin.template", "src") == "bazarr-config.yml.j2"
  end
  failures << "Bazarr bootstrap must preserve existing config" unless
    bazarr_seed && bazarr_seed.dig("ansible.builtin.template", "force") == false &&
      bazarr_seed.dig("ansible.builtin.template", "dest").to_s.end_with?("/config/config.yaml")

  # The bootstrap config is an XML template, so it is read as the elements it
  # declares. A substring check cannot tell <AuthenticationMethod>Forms</...>
  # from the word Forms appearing in a comment or in some other element.
  config_elements = File.readlines(
    File.join(root, "roles/arr/templates/config.xml.j2"), chomp: true
  ).filter_map do |line|
    match = line.strip.match(%r{\A<([A-Za-z][A-Za-z0-9]*)>(.*)</\1>\z})
    [match[1], match[2]] if match
  end.to_h
  failures << "Servarr bootstrap must use deterministic vault API keys" unless
    config_elements["ApiKey"] == "{{ arr_bootstrap_api_key }}"
  failures << "Servarr authentication must be enabled before first start" unless
    config_elements["AuthenticationMethod"] == "Forms" &&
      config_elements["AuthenticationRequired"] == "Enabled"

  # The environment file has its own grammar, so it is read as the assignments it
  # declares. A commented-out sample of the right assignment satisfies a
  # substring check while the live line exports something else, and a key found
  # anywhere in the file says nothing about which variable it is bound to.
  env_assignments = File.readlines(
    File.join(root, "roles/arr/templates/env.j2"), chomp: true
  ).filter_map do |line|
    name, _separator, value = line.strip.partition("=")
    [name, value] if line.strip.match?(/\A[A-Z][A-Z0-9_]*=/)
  end
  failures << "Arr env must render CPU set exactly once" unless
    env_assignments.select { |name, _value| name == "PLATFORM_CONTAINER_CPUSET" } ==
      [["PLATFORM_CONTAINER_CPUSET", "{{ platform_effective_container_cpuset }}"]]
  failures << "Arr env must carry all deterministic API keys" unless
    %w[radarr sonarr prowlarr bazarr].all? do |name|
      env_assignments.include?(["#{name.upcase}_API_KEY", "{{ vault_arr_#{name}_api_key }}"])
    end

  servarr_categories = Array(defaults["arr_servarr_instances"]).each_with_object({}) do |entry, mapped|
    mapped[entry["name"]] = entry["category"] if entry.is_a?(Hash)
  end
  servarr_tasks = role_tasks(root, "roles/arr/tasks/reconcile_servarr.yml") +
    role_tasks(root, "roles/arr/tasks/reconcile_servarr_download_client.yml")
  servarr_scalars = role_strings(servarr_tasks)
  servarr_urls = request_urls(servarr_tasks)
  # The download-client body is built by the Servarr relationship filter, and the
  # Bazarr settings POST by the Bazarr one, rather than being spelled out in the
  # task files; these read where each body actually lives. Python is not YAML, so
  # a filter is read as source text; the task files beside it are read as tasks.
  servarr_filter = File.read(File.join(root, "filter_plugins/acquisition_servarr.py"))
  bazarr_filter = File.read(File.join(root, "filter_plugins/acquisition_bazarr.py"))
  failures << "Servarr reconciliation must own only the SABnzbd clients" unless
    (servarr_scalars.any? { |value| value.include?("Sabnzbd") } ||
      servarr_filter.include?("Sabnzbd")) &&
      servarr_categories["radarr"] == "movies" &&
      servarr_categories["sonarr"] == "series"
  # A root folder is created by a request to the rootfolder endpoint, and an
  # import or search is a request to the command endpoint. Reading the URLs the
  # tasks actually call says that; the substring pair it replaced was satisfied
  # by the word rootfolder anywhere in either file, and its negative half only
  # matched an import or search named on the same source line as the word
  # command, which a JSON body on its own line never is.
  failures << "Servarr reconciliation must create root folders without import commands" unless
    servarr_urls.any? { |url| url.end_with?("/rootfolder") } &&
      servarr_urls.none? { |url| url.match?(%r{/command(/|\z)}i) } &&
      servarr_scalars.none? { |value| value.match?(/command.*(import|search)/i) }
  host_reconciliation = servarr_tasks.find do |task|
    uri = task["ansible.builtin.uri"]
    uri.is_a?(Hash) && uri["method"] == "PUT" &&
      uri["url"].to_s.gsub(/[[:space:]]+/, "").include?("/config/host")
  end
  failures << "Servarr reconciliation must preserve unowned host fields" unless
    host_reconciliation &&
      host_reconciliation.dig("ansible.builtin.uri", "body").to_s.include?("combine(")

  naming_scalars = servarr_scalars +
    role_strings(role_tasks(root, "roles/arr/tasks/configarr.yml")) +
    role_strings(role_tasks(root, "roles/arr/tasks/verify.yml"))
  failures << "Servarr rename policy must use the naming configuration API" unless
    naming_scalars.any? { |value| value.include?("config/naming") } &&
      naming_scalars.none? { |value| value.include?("config/mediamanagement") }

  prowlarr_scalars = role_strings(
    role_tasks(root, "roles/arr/tasks/reconcile_prowlarr.yml") +
      role_tasks(root, "roles/arr/tasks/reconcile_prowlarr_application.yml")
  ) + role_strings(defaults)
  failures << "Prowlarr must own Radarr and Sonarr applications" unless
    %w[Radarr Sonarr fullSync].all? do |token|
      prowlarr_scalars.any? { |value| value.include?(token) }
    end
  failures << "Prowlarr must not receive a download client" if
    prowlarr_scalars.any? { |value| value.match?(%r{/downloadclient|download client}i) }

  bazarr_scalars = role_strings(
    role_tasks(root, "roles/arr/tasks/reconcile_bazarr.yml") +
      role_tasks(root, "roles/arr/tasks/reconciliation_fingerprints.yml")
  ) + [bazarr_filter]
  failures << "Bazarr must connect to both Arr services" unless
    %w[settings-general-use_radarr settings-general-use_sonarr settings-radarr-apikey settings-sonarr-apikey].all? do |token|
      bazarr_scalars.any? { |value| value.include?(token) }
    end
  failures << "Bazarr must retain identical paths without remote mappings" unless
    bazarr_scalars.any? { |value| value.include?("path_mappings") } &&
      bazarr_scalars.any? { |value| value.include?("path_mappings_movie") }

  # Redaction is a property of each request, not of the file it lives in. One
  # no_log anywhere satisfied the substring check while every other request in
  # the same file logged its payload.
  failures << "all Arr API reconciliation must redact secret-bearing payloads" unless
    %w[
      roles/arr/tasks/reconcile_servarr.yml
      roles/arr/tasks/reconcile_prowlarr.yml
      roles/arr/tasks/reconcile_bazarr.yml
    ].all? do |relative|
      requests = role_tasks(root, relative).select { |task| task.key?("ansible.builtin.uri") }
      !requests.empty? && requests.all? { |task| task["no_log"] == true }
    end
end

if failures.empty?
  puts "arr contract: Phase 1 API ownership holds"
else
  warn failures.join("\n")
  exit 1
end
RUBY
