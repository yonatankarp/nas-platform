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

# Task files are flattened so a task on a block's rescue or always path is still
# a task the role executes.
def flatten_tasks(tasks)
  Array(tasks).flat_map do |task|
    next [] unless task.is_a?(Hash)

    [task] + flatten_tasks(task["block"]) + flatten_tasks(task["rescue"]) +
      flatten_tasks(task["always"])
  end
end

# Assertions about what the role does read the parsed structure rather than the
# file's bytes: a Jinja test that survives only inside a comment is not a test
# the role runs, and a literal found anywhere in a file does not belong to the
# task the assertion names.
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

def included_file(task)
  include_tasks = task["ansible.builtin.include_tasks"]
  include_tasks.is_a?(Hash) ? include_tasks["file"] : include_tasks
end

# Line-oriented grammars — the environment file and the SABnzbd INI — are read as
# the assignments they declare. A commented-out sample of the right assignment
# satisfies a substring check while the live line writes something else, and a
# key found anywhere in the file says nothing about which section owns it.
def environment_assignments(path)
  File.readlines(path, chomp: true).filter_map do |line|
    name, _separator, value = line.strip.partition("=")
    [name, value] if line.strip.match?(/\A[A-Z][A-Z0-9_]*=/)
  end
end

def ini_settings(path)
  top = nil
  section = nil
  File.readlines(path, chomp: true).each_with_object({}) do |line, settings|
    stripped = line.strip
    next if stripped.empty? || stripped.start_with?("{%", "{#")

    if (header = stripped.match(/\A\[\[(.+)\]\]\z/))
      section = "#{top}/#{header[1]}"
      settings[section] ||= {}
      next
    elsif (header = stripped.match(/\A\[([^\[\]]+)\]\z/))
      top = header[1]
      section = top
      settings[section] ||= {}
      next
    end
    name, separator, value = stripped.partition(" = ")
    next if separator.empty? || section.nil?

    settings[section][name] = value
  end
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

  # Order is task position, not byte offset. A task named in a comment sorts
  # ahead of the task it names, and a byte offset cannot tell the two apart.
  main = role_tasks(root, "roles/downloaders/tasks/main.yml")
  guard_index = main.index { |task| included_file(task) == "state_guard.yml" }
  activation_index = main.index do |task|
    task.dig("community.docker.docker_compose_v2", "state") == "present"
  end
  activation = activation_index && main[activation_index]
  failures << "downloaders role must deploy through docker_compose_v2" unless
    main.any? { |task| task["community.docker.docker_compose_v2"].is_a?(Hash) }
  failures << "downloaders role must include the state guard before deployment" unless
    guard_index && activation_index && guard_index < activation_index
  failures << "downloaders role must verify its effective project CPU policy" unless
    main.count { |task| task.dig("vars", "container_cpu_service_name") == "downloaders" } == 1
  failures << "downloaders role must gate activation on media_usenet_enabled" unless
    activation && Array(activation["when"]).any? do |condition|
      condition.to_s.include?("media_usenet_enabled | bool")
    end
  sabnzbd_index = main.index { |task| included_file(task) == "reconcile_sabnzbd.yml" }
  clients_index = main.index do |task|
    task.dig("ansible.builtin.include_role", "tasks_from") == "reconcile_download_clients"
  end
  failures << "downloaders must reconcile Arr clients only after SABnzbd" unless
    sabnzbd_index && clients_index && sabnzbd_index < clients_index

  env_assignments = environment_assignments(
    File.join(root, "roles/downloaders/templates/env.j2")
  )
  failures << "downloaders env must render CPU set exactly once" unless
    env_assignments.select { |name, _value| name == "PLATFORM_CONTAINER_CPUSET" } ==
      [["PLATFORM_CONTAINER_CPUSET", "{{ platform_effective_container_cpuset }}"]]
  failures << "downloaders env must carry only declared API keys" unless
    [
      ["SABNZBD_API_KEY", "{{ vault_downloaders_sabnzbd_api_key }}"],
      ["RADARR_API_KEY", "{{ vault_arr_radarr_api_key }}"],
      ["SONARR_API_KEY", "{{ vault_arr_sonarr_api_key }}"]
    ].all? { |assignment| env_assignments.include?(assignment) }

  reconcile = role_tasks(root, "roles/downloaders/tasks/reconcile_sabnzbd.yml")
  secret_tasks = reconcile.select do |task|
    task.dig("ansible.builtin.uri", "url").to_s.include?("vault_downloaders_sabnzbd_api_key")
  end
  failures << "every SABnzbd credential-bearing API task must use no_log" unless
    !secret_tasks.empty? && secret_tasks.all? { |task| task["no_log"] == true }
  category_schema_scalars = [
    role_strings(reconcile),
    role_strings(role_tasks(root, "roles/downloaders/tasks/verify.yml"))
  ]
  failures << "SABnzbd categories must be reconciled from the API list schema" unless
    category_schema_scalars.all? do |scalars|
      scalars.any? { |value| value.include?("config.categories is sequence") } &&
        scalars.any? { |value| value.include?("selectattr('name'") }
    end
  failures << "SABnzbd categories must not be treated as a mapping" if
    category_schema_scalars.any? do |scalars|
      scalars.any? { |value| value.include?("config.categories is mapping") }
    end

  template_path = File.join(root, "roles/downloaders/templates/sabnzbd.ini.j2")
  settings = ini_settings(template_path)
  failures << "bootstrap must bind SABnzbd on all container interfaces" unless
    settings.dig("misc", "host") == "0.0.0.0" && settings.dig("misc", "port") == "8080"
  failures << "bootstrap must not invent a Usenet provider" if settings.key?("servers")
  # The loop header is Jinja control flow, so it stays a literal — but a whole
  # line of it, which a commented-out copy is not. What the loop writes is read
  # as the section and keys it declares.
  template_lines = File.readlines(template_path, chomp: true).map(&:strip)
  failures << "bootstrap must render every declared category and destination" unless
    template_lines.include?(
      "{% for category, directory in downloaders_sabnzbd_categories.items() %}"
    ) && settings.dig("categories/{{ category }}", "dir") == "{{ directory }}"

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
