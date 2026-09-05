#!/usr/bin/env ruby
# The static half of the downloaders service contract, and the whole of it:
# Phase 1 Usenet ownership is decided from the repository alone, with nothing
# deployed.
#
# usage: downloaders-static.rb REPOSITORY
#
# PLATFORM_CONTRACT_REPO_DIR names the same repository and is read below for
# tests/policy_support.rb, so this program carries no copy of flatten_tasks.
#
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
require File.join(ENV.fetch("PLATFORM_CONTRACT_REPO_DIR"), "tests", "policy_support")
include PolicySupport

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
  # 3 is Repair/Unpack/Delete. Anything lower leaves par2 repair to nothing --
  # Unpackerr does not do par2 and holds no archive password -- so a damaged or
  # encrypted release parks in the acquisition tree with no component able to
  # finish it. This asserts the level rather than merely that the key exists,
  # because 0 is what shipped and 0 is what the failure looked like.
  failures << "SABnzbd must repair and unpack its own downloads" unless
    defaults["downloaders_sabnzbd_category_post_processing"] == 3
  # 3 is ConfigServer's Strict: the only ssl_verify value that checks the
  # provider's certificate chain and hostname. The other three leave a TLS
  # connection that authenticates nothing, and nothing else would notice.
  failures << "SABnzbd must verify the provider's TLS certificate" unless
    defaults.dig("downloaders_sabnzbd_owned_server", "ssl_verify") == 3 &&
      defaults.dig("downloaders_sabnzbd_owned_server", "enable") == 1

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
  # A credential-bearing task is selected from the whole request, not from its
  # URL. This selector used to read only `uri.url`, and moving the provider push
  # to a form-urlencoded body dropped that one task out of the selection while
  # the check stayed green, because the other credential-bearing tasks still
  # matched and kept the set non-empty.
  secret_tasks = reconcile.select do |task|
    request = task["ansible.builtin.uri"]
    request.is_a?(Hash) && role_strings(request).any? do |value|
      value.include?("vault_downloaders_sabnzbd_api_key") ||
        value.include?("vault_downloaders_sabnzbd_server_password")
    end
  end
  # The floor is the point, and it is why this is not `!secret_tasks.empty?`.
  # A dynamically assembled subject list fails by going quiet: when a subject
  # moves out of reach of the selector, the rule keeps passing over whatever is
  # left. Non-empty is exactly the assertion a *partially* blinded selector still
  # satisfies, so the count has to be an assertion too. Four tasks carry a
  # credential today; the floor sits below that deliberately, so that deleting a
  # task is a decision rather than an accident, while blinding the selector to
  # most of them is still caught. Raise it when tasks are added.
  failures << "every SABnzbd credential-bearing API task must use no_log" unless
    secret_tasks.length >= 2 && secret_tasks.all? { |task| task["no_log"] == true }
  # A floor cannot say *which* task must stay in reach, and the provider push is
  # the one that matters: it is the only task here sending a third-party secret,
  # and the only one whose credential does not appear in a URL. Name it directly
  # rather than inferring it from a count.
  provider_pushes = secret_tasks.select do |task|
    role_strings(task["ansible.builtin.uri"]).any? do |value|
      value.include?("vault_downloaders_sabnzbd_server_password")
    end
  end
  failures << "the Usenet provider push must stay inside the credential guard" unless
    provider_pushes.length == 1
  # SABnzbd keeps no access log in this deployment, but a URL is the part of a
  # request every future proxy, log and history records, and the provider
  # password is the one credential here whose exposure reaches outside the
  # platform. It travels in a body or not at all.
  failures << "the Usenet provider password must never travel in a URL" if
    reconcile.any? do |task|
      task.dig("ansible.builtin.uri", "url").to_s
          .include?("vault_downloaders_sabnzbd_server_password")
    end
  # An undeclared Usenet provider is a valid state, and the owned-server
  # verification is therefore a *pair* of assertions rather than one gated
  # assertion. That distinction is the whole guard. A single assertion carrying
  # `when: downloaders_usenet_provider_declared` would skip on the undeclared
  # target and assert nothing at all, which is the silence issue #269 closed:
  # SABnzbd ran with zero servers for as long as the stack existed and nothing
  # failed. So both branches must exist, and their conditions must be each
  # other's negation -- two conditions that could both be false is the same
  # silence wearing a second task.
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
  # A branch is only worth having if it claims something about the server list,
  # and the two claims are inverses: exactly one owned server when a provider is
  # declared, none when one is not. Read the counts rather than trusting the
  # conditions, so a branch reduced to a shape check alone fails here.
  branch_claims = owned_server_branches.to_h do |task|
    [Array(task["when"]).map(&:to_s).first,
     role_strings(task.dig("ansible.builtin.assert", "that")).grep(
       /downloaders_verify_sabnzbd_server_matches \| length ==/
     )]
  end
  failures << "each owned Usenet server branch must claim its own server count" unless
    branch_claims[owned_server_gate].to_a.any? { |claim| claim.include?("length == 1") } &&
      branch_claims["not #{owned_server_gate}"].to_a.any? { |claim| claim.include?("length == 0") }

  # The credential guard and the `section=servers` reconciliation are gated on
  # the same derived fact, and on nothing else. A second spelling of "is a
  # provider declared" is how the four gates drift out of agreement.
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
  # The loop header is Jinja control flow, so it stays a literal — but a whole
  # line of it, which a commented-out copy is not. What the loop writes is read
  # as the section and keys it declares.
  template_lines = File.readlines(template_path, chomp: true).map(&:strip)
  failures << "bootstrap must render every declared category and destination" unless
    template_lines.include?(
      "{% for category, directory in downloaders_sabnzbd_categories.items() %}"
    ) && settings.dig("categories/{{ category }}", "dir") == "{{ directory }}"
  # The bootstrap template and the reconciliation must write the same
  # post-processing level, and both must read it from the declaration. A literal
  # in either place is how the level became unreconcilable in the first place:
  # the API request carried a hardcoded pp and its `when` compared only the
  # destination, so an existing host kept whatever it was created with.
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
  # Unset is not the same as unlimited here: unset means 20GB for Sonarr and
  # 75GB for Radarr, and the refusal that produces is silent from the library's
  # side. Both are asserted as the explicit "0" so removing either restores a
  # cap rather than removing one.
  failures << "Unpackerr must not cap an extraction by archive size" unless
    unpackerr.dig("environment", "UN_SONARR_0_MAX_BYTES") == "0" &&
      unpackerr.dig("environment", "UN_RADARR_0_MAX_BYTES") == "0"
  # The platform rule says a probe must reach a service; this says it must reach
  # *this* one. Unpackerr has no liveness signal until its web server is turned
  # on, so the switch and the address the probe fetches are one decision and
  # drift apart silently: a probe aimed at a port nothing is listening on fails
  # forever, and a listener nothing probes is surface for no reason. Reading the
  # address out of the environment rather than repeating it keeps the two equal
  # by construction.
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
  warn failures.join("\n")
  exit 1
end
