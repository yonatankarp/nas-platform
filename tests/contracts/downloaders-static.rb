#!/usr/bin/env ruby
# Static half of the downloaders contract, and the whole of it: decided from
# the repository alone. usage: downloaders-static.rb REPOSITORY
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

# Flattened so rescue/always tasks count too.
require File.join(ENV.fetch("PLATFORM_CONTRACT_REPO_DIR"), "tests", "policy_support")
include PolicySupport

# Parsed structure, not file bytes: a commented-out test is not one the role runs.
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

# Line grammars (env file, SABnzbd INI) are read as the assignments they declare.
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
  # Jellyfin's "date added" is the file's mtime; an archive's stored date hides
  # a new episode from Recently Added.
  failures << "SABnzbd must date unpacked files by unpack time" unless
    defaults.dig("downloaders_sabnzbd_owned_misc", "ignore_unrar_dates") == 1
  # 3 is Repair/Unpack/Delete; Unpackerr does no par2, so anything lower strands
  # damaged releases. 0 is what shipped.
  failures << "SABnzbd must repair and unpack its own downloads" unless
    defaults["downloaders_sabnzbd_category_post_processing"] == 3
  # 3 (Strict) is the only ssl_verify value that checks chain and hostname.
  failures << "SABnzbd must verify the provider's TLS certificate" unless
    defaults.dig("downloaders_sabnzbd_owned_server", "ssl_verify") == 3 &&
      defaults.dig("downloaders_sabnzbd_owned_server", "enable") == 1

  # Order is task position, not byte offset.
  main = role_tasks(root, "roles/downloaders/tasks/main.yml")
  guard_index = main.index { |task| included_file(task) == "state_guard.yml" }
  # The deployment is the `up` without `recreate` (#537).
  activation_index = main.index do |task|
    compose = task["community.docker.docker_compose_v2"]
    compose.is_a?(Hash) && compose["state"] == "present" && !compose.key?("recreate")
  end
  activation = activation_index && main[activation_index]
  failures << "downloaders role must deploy through docker_compose_v2" unless
    main.any? { |task| task["community.docker.docker_compose_v2"].is_a?(Hash) }
  failures << "downloaders role must repair a wedged container exactly once per converge" unless
    main.count do |task|
      task.dig("community.docker.docker_compose_v2", "recreate") == "always"
    end == 1
  failures << "downloaders role must include the state guard before deployment" unless
    guard_index && activation_index && guard_index < activation_index
  failures << "downloaders role must verify its effective project CPU policy" unless
    main.count { |task| task.dig("vars", "container_cpu_service_name") == "downloaders" } == 1
  # The gate may sit on the enclosing block (#537), whose `when` applies inside it.
  activation_gate = main.find do |task|
    task["block"].is_a?(Array) &&
      flatten_tasks(task["block"]).any? { |inner| inner.equal?(activation) }
  end || activation
  failures << "downloaders role must gate activation on media_usenet_enabled" unless
    activation_gate && Array(activation_gate["when"]).any? do |condition|
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

  # A changed label recreates the container where a changed bind source does not,
  # so the gate's sha256 must be read before the env that carries it is rendered.
  failures << "downloaders env must export the release gate's sha256 exactly once" unless
    env_assignments.select { |name, _value| name == "SABNZBD_CLAMAV_GATE_SHA256" } ==
      [["SABNZBD_CLAMAV_GATE_SHA256", "{{ downloaders_clamav_gate_sha256 }}"]]
  gate_stat_index = main.index do |task|
    stat = task["ansible.builtin.stat"]
    task["register"] == "downloaders_clamav_gate" && stat.is_a?(Hash) &&
      stat["path"] == "{{ platform_current_dir }}/services/downloaders/clamav_gate.py" &&
      stat["follow"] == false && stat["get_checksum"] == true &&
      stat["checksum_algorithm"] == "sha256"
  end
  env_render_index = main.index { |task| task.dig("ansible.builtin.template", "src") == "env.j2" }
  failures << "downloaders must checksum the release's gate before rendering its environment" unless
    gate_stat_index && env_render_index && gate_stat_index < env_render_index

  reconcile = role_tasks(root, "roles/downloaders/tasks/reconcile_sabnzbd.yml")
  # Selected from the whole request, not the URL: a body-borne credential once
  # dropped out of the selection unnoticed.
  secret_tasks = reconcile.select do |task|
    request = task["ansible.builtin.uri"]
    request.is_a?(Hash) && role_strings(request).any? do |value|
      value.include?("vault_downloaders_sabnzbd_api_key") ||
        value.include?("vault_downloaders_sabnzbd_server_password")
    end
  end
  # A floor, not non-emptiness: a partially blinded selector still finds some.
  # Raise it when tasks are added.
  failures << "every SABnzbd credential-bearing API task must use no_log" unless
    secret_tasks.length >= 2 && secret_tasks.all? { |task| task["no_log"] == true }
  # The provider push is named directly: the only third-party secret, sent in a body.
  provider_pushes = secret_tasks.select do |task|
    role_strings(task["ansible.builtin.uri"]).any? do |value|
      value.include?("vault_downloaders_sabnzbd_server_password")
    end
  end
  failures << "the Usenet provider push must stay inside the credential guard" unless
    provider_pushes.length == 1
  # The provider password travels in a body or not at all.
  failures << "the Usenet provider password must never travel in a URL" if
    reconcile.any? do |task|
      task.dig("ansible.builtin.uri", "url").to_s
          .include?("vault_downloaders_sabnzbd_server_password")
    end
  # The owned-server verification is a pair of mutually negated assertions: one
  # gated assertion would skip silently when no provider is declared (#269).
  verify = role_tasks(root, "roles/downloaders/tasks/verify.yml")
  owned_server_gate = "downloaders_usenet_provider_declared | bool"
  owned_server_branches = verify.select do |task|
    task["ansible.builtin.assert"].is_a?(Hash) &&
      Array(task["when"]).any? { |condition| condition.to_s.include?(owned_server_gate) } &&
      role_strings(task["vars"]).any? do |value|
        value.include?("selectattr('name', 'equalto', downloaders_sabnzbd_server_name)")
      end
  end
  branch_conditions = owned_server_branches.map { |task| Array(task["when"]).map(&:to_s) }
  failures << "the owned Usenet server must be verified in both provider states" unless
    branch_conditions.sort == [[owned_server_gate], ["not #{owned_server_gate}"]].sort
  # Exactly one owned server when declared, none when not.
  branch_claims = owned_server_branches.to_h do |task|
    [Array(task["when"]).map(&:to_s).first,
     role_strings(task.dig("ansible.builtin.assert", "that")).grep(
       /downloaders_verify_sabnzbd_server_matches \| length ==/
     )]
  end
  failures << "each owned Usenet server branch must claim its own server count" unless
    branch_claims[owned_server_gate].to_a.any? { |claim| claim.include?("length == 1") } &&
      branch_claims["not #{owned_server_gate}"].to_a.any? { |claim| claim.include?("length == 0") }

  # All provider gates read the same derived fact.
  main_provider_gates = main.select do |task|
    role_strings(task).any? { |value| value.include?("vault_downloaders_sabnzbd_server_password") }
  end
  failures << "the provider credential guard must be gated on the declared fact" unless
    main_provider_gates.length == 1 &&
      Array(main_provider_gates.first["when"]) == [owned_server_gate]
  server_block = reconcile.find do |task|
    task["block"].is_a?(Array) &&
      role_strings(task["block"]).any? do |value|
        value.include?("vault_downloaders_sabnzbd_server_password")
      end
  end
  failures << "the Usenet server reconciliation must be gated on the declared fact" unless
    server_block && Array(server_block["when"]) == [owned_server_gate]

  category_schema_scalars = [
    role_strings(reconcile),
    role_strings(verify)
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
  # The loop header must be a whole template line, not a commented-out copy.
  template_lines = File.readlines(template_path, chomp: true).map(&:strip)
  failures << "bootstrap must render every declared category and destination" unless
    template_lines.include?(
      "{% for category, directory in downloaders_sabnzbd_categories.items() %}"
    ) && settings.dig("categories/{{ category }}", "dir") == "{{ directory }}"
  # Both must read the declared level; a literal made it unreconcilable before.
  failures << "bootstrap must render the declared post-processing level" unless
    settings.dig("categories/{{ category }}", "pp") ==
      "{{ downloaders_sabnzbd_category_post_processing }}"
  reconcile = File.read(File.join(root, "roles/downloaders/tasks/reconcile_sabnzbd.yml"))
  failures << "category reconciliation must set the declared post-processing level" unless
    reconcile.include?("pp={{") &&
      reconcile.include?("downloaders_sabnzbd_category_post_processing | string | urlencode")
  failures << "category reconciliation must notice a post-processing drift" unless
    reconcile.include?("map(attribute='pp')")

  compose = YAML.safe_load_file(File.join(root, "services/downloaders/compose.yml"), aliases: true)
  unpackerr = compose.dig("services", "unpackerr")
  failures << "Unpackerr must integrate both Arr services over Usenet" unless
    unpackerr.dig("environment", "UN_RADARR_0_PROTOCOLS") == "usenet" &&
      unpackerr.dig("environment", "UN_SONARR_0_PROTOCOLS") == "usenet"
  failures << "Unpackerr file and directory modes drifted" unless
    unpackerr.dig("environment", "UN_FILE_MODE") == "0644" &&
      unpackerr.dig("environment", "UN_DIR_MODE") == "0755"
  # Unset means 20GB/75GB caps, so both are asserted as explicit "0".
  failures << "Unpackerr must not cap an extraction by archive size" unless
    unpackerr.dig("environment", "UN_SONARR_0_MAX_BYTES") == "0" &&
      unpackerr.dig("environment", "UN_RADARR_0_MAX_BYTES") == "0"
  # The probe address is read from UN_WEBSERVER_LISTEN_ADDR, so the listener and
  # the probe cannot drift apart.
  listen_addr = unpackerr.dig("environment", "UN_WEBSERVER_LISTEN_ADDR").to_s
  probe = Array(unpackerr.dig("healthcheck", "test")).join(" ")
  failures << "Unpackerr's health probe must fetch the web server it enables, on loopback" unless
    unpackerr.dig("environment", "UN_WEBSERVER_METRICS") == "true" &&
      listen_addr.match?(/\A127\.0\.0\.1:\d+\z/) &&
      probe.include?("http://#{listen_addr}/")
end

if failures.empty?
  puts "downloaders contract: Phase 1 Usenet ownership holds"
else
  # One line per violation with the contract's prefix, which contract tests
  # match on (#352).
  warn failures.map { |failure| "Downloaders contract failed: #{failure}" }.join("\n")
  exit 1
end
