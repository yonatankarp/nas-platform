#!/usr/bin/env ruby
# The static half of the AdGuard Home service contract: what a gated resolver
# owes this platform, decided from the repository alone with nothing deployed.
#
# usage: adguard-static.rb REPOSITORY
#
# PLATFORM_CONTRACT_REPO_DIR names the same repository and is read below for
# tests/policy_support.rb, so this program carries no copy of flatten_tasks.
#
# THE FOUR CLAIMS THIS FILE EXISTS FOR, none of which any other check makes:
#
#   1. The administrator hash is STORED, never computed. bcrypt salts randomly,
#      so a `password_hash('bcrypt')` anywhere in this role would rewrite
#      AdGuardHome.yaml on every converge -- a broken idempotence that reports
#      itself as an ordinary change and would survive every review that reads the
#      diff rather than two consecutive runs.
#
#   2. The rendered configuration declares a NONEMPTY `users:` block. AdGuard
#      reads `users: []` as "authentication disabled", which hands the ability to
#      rewrite any DNS answer on the network to whoever can reach the port. That
#      is a one-character edit away from correct and looks like an empty list.
#
#   3. The role does not touch host DNS and does not serve DHCP. Both are
#      decisions, both are recorded in roles/adguard/defaults/main.yml, and both
#      are the obvious next step for a future reader -- so a task that reached
#      for either has to fail here rather than be noticed.
#
#   4. Its two disposable-lane overrides move the publications. Production takes
#      the privileged 53, which is available on the NAS and on nothing else: a
#      CI runner already resolves through systemd-resolved's stub listener on
#      127.0.0.53:53, and a laptop has its own resolver too.
#
# Structure is read from parsed YAML rather than from source text wherever the
# claim is structural, for the reason the Nextcloud contract records: this
# role's comments spell out `resolv.conf` and `password_hash` at length while
# explaining why no task uses either, so a source-text assertion for "this must
# not name resolv.conf" fails against the correct role.
require "yaml"

root = ARGV.fetch(0)
failures = []
required = %w[
  roles/adguard/defaults/main.yml
  roles/adguard/meta/argument_specs.yml
  roles/adguard/tasks/main.yml
  roles/adguard/tasks/deploy.yml
  roles/adguard/tasks/report.yml
  roles/adguard/tasks/verify.yml
  roles/adguard/templates/env.j2
  roles/adguard/templates/AdGuardHome.yaml.j2
  services/adguard/compose.yml
  services/adguard/compose.mac.yml
  services/adguard/compose.integration.yml
  tests/expected/adguard.yml
  tests/contracts/adguard.sh
  tests/integration_controller_lib.sh
  tests/integration_controller.sh
  inventory/group_vars/all/main.yml
]
required.each do |relative|
  failures << "missing #{relative}" unless File.file?(File.join(root, relative))
end

require File.join(ENV.fetch("PLATFORM_CONTRACT_REPO_DIR"), "tests", "policy_support")
include PolicySupport

ROLE_TASK_FILES = %w[main deploy report verify].freeze
VAULT_CREDENTIALS = %w[
  vault_adguard_admin_password
  vault_adguard_admin_password_hash
  vault_adguard_admin_username
].freeze
GATE = "adguard_deployment_enabled | bool"
# repo:tag@sha256:<64 hex>. Both halves, because the tag is what a human and
# Renovate read and the digest is what makes the deployment reproducible.
IMAGE_PIN = %r{\A[a-z0-9][a-z0-9._/-]*:[A-Za-z0-9_][A-Za-z0-9_.-]*@sha256:[0-9a-f]{64}\z}
# Highest port a process needs privilege to bind. The sandbox's publications have
# to sit above it, and that is a measurement rather than a preference: Docker on
# Linux cannot bind 0.0.0.0:53 while systemd-resolved holds 127.0.0.53:53, in
# either protocol and whatever either socket asks of SO_REUSEADDR.
PRIVILEGED_PORT_CEILING = 1024

def load_yaml(root, relative)
  YAML.safe_load_file(File.join(root, relative), aliases: true)
rescue Errno::ENOENT, Psych::Exception
  nil
end

def role_tasks(root, file)
  document = load_yaml(root, "roles/adguard/tasks/#{file}.yml")
  document.is_a?(Array) ? flatten_tasks(document) : []
end

def conditions(task)
  Array(task.is_a?(Hash) ? task["when"] : nil).map { |condition| condition.to_s.strip }
end

# Every task paired with the conditions it actually runs under. Ansible applies
# a block's `when` to every task inside it, so a deployment wrapped in a gated
# block is gated even though its own `when` says nothing -- which is the shape
# roles/adguard/tasks/deploy.yml uses for its bounded force-recreate.
def tasks_with_gates(nodes, inherited = [])
  Array(nodes).flat_map do |task|
    next [] unless task.is_a?(Hash)

    gates = inherited + conditions(task)
    nested = %w[block rescue always].flat_map { |key| tasks_with_gates(task[key], gates) }
    nested.empty? ? [[task, gates]] : nested
  end
end

# Every string anywhere inside a task's values, so a claim about what the role
# computes reads the role rather than the prose beside it.
def task_strings(node)
  case node
  when Hash then node.flat_map { |key, value| [key.to_s] + task_strings(value) }
  when Array then node.flat_map { |element| task_strings(element) }
  when String then [node]
  else []
  end
end

if failures.empty?
  compose = load_yaml(root, "services/adguard/compose.yml")
  services = compose.is_a?(Hash) ? compose["services"] : nil
  failures << "services/adguard/compose.yml must declare exactly the adguard service" unless
    services.is_a?(Hash) && services.keys == %w[adguard]
  spec = services.is_a?(Hash) ? services["adguard"] : nil
  spec = {} unless spec.is_a?(Hash)

  failures << "the AdGuard image must carry both a version tag and a manifest digest" unless
    spec["image"].to_s.match?(IMAGE_PIN)
  failures << "AdGuard must run as the shared platform identity rather than as root, " \
              "or every file the daemon rewrites becomes unreplaceable by the next converge" unless
    spec["user"] == "${NAS_UID:?}:${NAS_GID:?}"
  failures << "AdGuard must refuse privilege escalation" unless
    Array(spec["security_opt"]).include?("no-new-privileges:true")
  failures << "AdGuard must not be privileged" if spec["privileged"]

  # The publications, in both directions. The container side of the DNS pair is
  # the whole reason the container can run unprivileged, so it is asserted as a
  # value rather than merely as "some port".
  published = Array(spec["ports"]).map(&:to_s)
  failures << "AdGuard must publish its web interface on the host port the role declares" unless
    published.include?("8083:3000")
  %w[tcp udp].each do |protocol|
    failures << "AdGuard must publish host 53/#{protocol} to the unprivileged in-container " \
                "listener; binding 53 inside the container would need root" unless
      published.include?("53:5353/#{protocol}")
  end
  failures << "AdGuard must publish DNS on exactly the web port and the two 53 entries" unless
    published.length == 3

  # Both disposable lanes move both publications. `!override` rather than a
  # second list, because Compose concatenates `ports` across files: an override
  # that merely adds entries leaves the sandbox still trying to bind 53.
  mac_source = File.read(File.join(root, "services/adguard/compose.mac.yml"))
  integration_source = File.read(File.join(root, "services/adguard/compose.integration.yml"))
  [["mac", mac_source], ["integration", integration_source]].each do |kind, source|
    failures << "services/adguard/compose.#{kind}.yml must REPLACE the production publications " \
                "with `ports: !override`; Compose concatenates ports across files, so an " \
                "override that adds entries still binds the privileged 53" unless
      source.include?("ports: !override")
    failures << "services/adguard/compose.#{kind}.yml must give the container the sandbox's " \
                "namespaced name, or its containers survive the run and collide with the next" unless
      source.include?("${PLATFORM_PROJECT_NAME:?}-adguard")
  end

  # Read here and asserted further down, where the whole listen-address chain is
  # held together in one place.
  env_source = File.read(File.join(root, "roles/adguard/templates/env.j2"))

  # ---------------------------------------------------------------------------
  # The rendered configuration.
  template = File.read(File.join(root, "roles/adguard/templates/AdGuardHome.yaml.j2"))

  failures << "AdGuardHome.yaml.j2 must declare a nonempty users list carrying the vault " \
              "administrator; `users: []` disables authentication completely and hands the " \
              "ability to rewrite any DNS answer on the network to anyone who reaches the port" unless
    template.match?(/^users:\n  - name: \{\{ vault_adguard_admin_username \}\}\n/)
  failures << "AdGuardHome.yaml.j2 must render the STORED bcrypt hash" unless
    template.include?("password: {{ vault_adguard_admin_password_hash }}")
  failures << "AdGuardHome.yaml.j2 must not carry the clear administrator password: AdGuard " \
              "stores a hash, and the clear value exists only so something can log in" if
    template.include?("vault_adguard_admin_password }}")

  failures << "AdGuardHome.yaml.j2 must declare protection and filtering on, or the resolver " \
              "answers every question and blocks nothing" unless
    template.include?("protection_enabled: true") && template.include?("filtering_enabled: true")
  failures << "AdGuardHome.yaml.j2 must leave AdGuard's DHCP server off: the router owns DHCP, " \
              "and a NAS serving leases means a NAS outage stops devices joining the network " \
              "at all rather than merely leaving them unfiltered" unless
    template.match?(/^dhcp:\n  enabled: false\n/)
  failures << "AdGuardHome.yaml.j2 must take its listening port from the role, so the value " \
              "that keeps the container unprivileged is declared in one place" unless
    template.include?("port: {{ adguard_dns_container_port }}")
  failures << "AdGuardHome.yaml.j2 must render the declared upstreams and bootstrap resolvers " \
              "rather than naming any of them here" unless
    template.include?("{% for adguard_upstream in adguard_upstream_dns %}") &&
    template.include?("{% for adguard_bootstrap in adguard_bootstrap_dns %}")
  failures << "AdGuardHome.yaml.j2 must render the declared filter lists" unless
    template.include?("{% for adguard_filter in adguard_filters %}")

  # THE DOCUMENT IS THE DAEMON'S OWN EXPANDED FORM, and the length is the only
  # cheap proxy for that. AdGuard rewrites its configuration at start, expanding
  # every default it was not given: measured against v0.107.79, a 26-line
  # minimal document came back as 186 lines. A template that has been trimmed
  # back towards the minimal form is rewritten on first start and then reports a
  # change on every converge afterwards. The floor is well below the real size
  # rather than at it, because a schema migration may legitimately move it.
  #
  # THE COMMENTS ARE NOT PART OF THE DOCUMENT, and counting them made this a
  # proxy for how much prose the file carries. It was `template.lines.length`,
  # and a Jinja comment explaining one of the values -- the rate limit, #548's
  # flip -- added enough lines to hold the count above the floor while the
  # document underneath it was trimmed to nothing. The planted regression in
  # tests/adguard_contract_test.rb caught it, which is the only reason it is not
  # still true. So the count is over the rendered body: Jinja comments removed,
  # and blank lines with them, because a document padded with either is exactly
  # the state this floor exists to refuse.
  document_lines = template.gsub(/\{#.*?#\}/m, "").lines.reject { |line| line.strip.empty? }
  failures << "AdGuardHome.yaml.j2 has been trimmed towards a minimal document. AdGuard expands " \
              "every default it was not given and writes the result back, so a short template " \
              "breaks idempotence on the first converge after deployment" unless
    document_lines.length > 150

  # ---------------------------------------------------------------------------
  # The role.
  defaults = load_yaml(root, "roles/adguard/defaults/main.yml") || {}
  failures << "roles/adguard/defaults/main.yml must ship the deployment gate off, so a caller " \
              "with no inventory does not put a resolver on the household network" unless
    defaults["adguard_deployment_enabled"] == false
  failures << "every declared upstream must be DNS-over-TLS, or the queries this platform " \
              "forwards are readable by whoever carries them" unless
    Array(defaults["adguard_upstream_dns"]).any? &&
    Array(defaults["adguard_upstream_dns"]).all? { |upstream| upstream.to_s.start_with?("tls://") }
  failures << "the bootstrap resolvers must be plain addresses: they are what resolves the " \
              "DNS-over-TLS hostnames above, so a name here cannot be resolved" unless
    Array(defaults["adguard_bootstrap_dns"]).any? &&
    Array(defaults["adguard_bootstrap_dns"]).none? { |address| address.to_s.include?("://") }
  failures << "at least one filter list must be declared, or protection is on and blocks nothing" if
    Array(defaults["adguard_filters"]).empty?

  specs = load_yaml(root, "roles/adguard/meta/argument_specs.yml") || {}
  options = specs.dig("argument_specs", "main", "options") || {}
  VAULT_CREDENTIALS.each do |key|
    failures << "roles/adguard must require #{key} in its argument spec" unless
      options.dig(key, "required") == true && options.dig(key, "type") == "str"
  end
  failures << "adguard_deployment_enabled must be a required bool in the role's argument spec, " \
              "so a run with no gate fails before the first task rather than midway" unless
    options.dig("adguard_deployment_enabled", "type") == "bool" &&
    options.dig("adguard_deployment_enabled", "required") == true

  everything = ROLE_TASK_FILES.flat_map { |file| role_tasks(root, file) }
  failures << "roles/adguard declares no tasks" if everything.empty?

  # WHERE THE SERVICE LISTENS, HELD ACROSS ALL FOUR FILES THAT DECIDE IT.
  #
  # This is the property that broke the adguard integration lane. The override
  # republished the web interface on 18083 as a literal, roles/adguard went on
  # addressing `adguard_port` -- still 8083 -- and nothing read both sides. The
  # readiness wait polled a port the sandbox had never published, spent all
  # twenty attempts on `Connection refused`, and failed; tasks/verify.yml and
  # every other reader would have failed the same way behind it.
  #
  # The chain is one value with four links, and each is asserted below:
  #
  #   roles/adguard/defaults      adguard_url derives from adguard_port, and no
  #                               task addresses the service any other way
  #   roles/adguard/templates     env.j2 renders ADGUARD_HOST_PORT from
  #                               adguard_port, and the DNS pair likewise
  #   services/adguard/compose.*  both disposable overrides publish those two
  #                               names and no literal host port
  #   tests/integration_*_lib.sh  the lane overrides adguard_port for the
  #                               converge AND hands the contract
  #                               PLATFORM_ADGUARD_PORT from the same shell
  #                               variable, so the two cannot disagree
  #
  # A literal anywhere in that chain is a second authority on where the service
  # listens that the role cannot see, which is exactly what this is here to
  # refuse.
  role_ports = {
    "ADGUARD_HOST_PORT" => "adguard_port",
    "ADGUARD_DNS_HOST_PORT" => "adguard_dns_port"
  }.freeze

  failures << "adguard_url must derive from adguard_port, or the lane cannot move where the " \
              "role looks by overriding one variable" unless
    defaults["adguard_url"].to_s.include?("{{ adguard_port }}")

  # Every reader, not just the one that happened to fail first. A literal host
  # and port anywhere in the role is a reader the lane cannot redirect.
  literal_addresses = everything.flat_map { |task| task_strings(task) }
                                .grep(%r{https?://(127\.0\.0\.1|localhost):\d})
  failures << "roles/adguard addresses the service at a literal port in " \
              "#{literal_addresses.uniq.inspect}: every reader has to go through adguard_url, " \
              "because a disposable lane publishes it somewhere else" unless
    literal_addresses.empty?

  role_ports.each do |name, variable|
    failures << "roles/adguard/templates/env.j2 must render #{name} from #{variable}, which is " \
                "the value the role itself addresses" unless
      env_source.include?("#{name}={{ #{variable} }}")
  end

  # Both disposable overrides, held to the same shape. The Mac lane has taken its
  # host ports from the environment since this service landed; the integration
  # lane carried literals until they desynchronised from the role.
  {
    "mac" => mac_source,
    "integration" => integration_source
  }.each do |kind, source|
    role_ports.each_key do |name|
      failures << "services/adguard/compose.#{kind}.yml must publish ${#{name}:?} rather than a " \
                  "number: a literal here is a second authority on where the service listens, " \
                  "and roles/adguard cannot see it" unless source.include?("${#{name}:?}")
    end
    literal_publications = source.scan(/^\s*- "(\d+):\d+/).flatten
    failures << "services/adguard/compose.#{kind}.yml publishes literal host port(s) " \
                "#{literal_publications.uniq.inspect}; the host side comes from the rendered " \
                "environment in a disposable lane" unless literal_publications.empty?
  end

  # The lane, read from the file that actually runs it.
  lane_source = File.read(File.join(root, "tests/integration_controller_lib.sh"))
  role_ports.each_value do |variable|
    lane_variable = "integration_#{variable}"
    declared = lane_source[/^#{lane_variable}=(\d+)$/, 1]&.to_i
    failures << "tests/integration_controller_lib.sh must declare #{lane_variable}, which is the " \
                "one place the sandbox decides where AdGuard listens" if declared.nil?
    next if declared.nil?

    failures << "#{lane_variable} is #{declared}, at or below #{PRIVILEGED_PORT_CEILING}. A runner " \
                "already holds 127.0.0.53:53 through systemd-resolved and Docker cannot bind " \
                "0.0.0.0:53 beside it -- measured, and recorded in " \
                "services/adguard/compose.integration.yml" unless
      declared > PRIVILEGED_PORT_CEILING
    failures << "the adguard lane must converge with -e #{variable}=\"$#{lane_variable}\", or the " \
                "role addresses the production port while the sandbox publishes another" unless
      lane_source.include?("-e #{variable}=\"$#{lane_variable}\"")
  end

  role_ports.each_key do |name|
    platform_name = name.sub("ADGUARD_", "PLATFORM_ADGUARD_").sub("_HOST_PORT", "_PORT")
    lane_variable = "integration_#{role_ports.fetch(name)}"
    failures << "the adguard lane must hand the contract #{platform_name}=\"$#{lane_variable}\", " \
                "the same variable it converged with. A literal here -- which is what this had " \
                "before -- lets the contract probe a port the deployment was never told to use" unless
      lane_source.include?("#{platform_name}=\"$#{lane_variable}\"")
  end

  # CLAIM 1. The hash is stored, never computed.
  #
  # Read from parsed task values and from the template with its Jinja comments
  # removed, not from the two files' source text. That distinction is not
  # theoretical: roles/adguard/tasks/deploy.yml explains this very rule in a
  # comment that spells `password_hash('bcrypt')` out, so a source-text scan
  # fails against the correct role -- which is exactly what it did the first time
  # this check ran.
  hashing_expressions = everything.flat_map { |task| task_strings(task) }
  template_body = template.gsub(/\{#.*?#\}/m, "")
  failures << "roles/adguard must not hash the administrator password at converge time: bcrypt " \
              "salts randomly, so the rendered configuration would differ on every run and " \
              "idempotence would break outright" if
    hashing_expressions.any? { |value| value.include?("password_hash(") } ||
    template_body.include?("password_hash(")

  # CLAIM 3. No host DNS, no DHCP. Read from task structure rather than from the
  # source text, because the role's comments discuss both at length.
  writing_modules = %w[
    ansible.builtin.template ansible.builtin.copy ansible.builtin.lineinfile
    ansible.builtin.blockinfile ansible.builtin.file
  ].freeze
  writes = everything.flat_map do |task|
    writing_modules.filter_map do |module_name|
      destination = task.dig(module_name, "dest") || task.dig(module_name, "path")
      destination&.to_s
    end
  end
  failures << "roles/adguard must not write outside the paths it declares; it must never touch " \
              "the host resolver. Pointing the NAS at AdGuard makes an AdGuard outage stop the " \
              "deployment poller resolving GitHub, which is the #327 shape: the recovery path " \
              "depending on the thing that is down" if
    writes.any? { |destination| destination.include?("resolv.conf") || destination.start_with?("/etc") }

  # CLAIM 4's other half, and the property the whole gate rests on: every
  # deployment carries the gate, and the teardown carries its negation.
  gated = ROLE_TASK_FILES.flat_map do |file|
    tasks_with_gates(load_yaml(root, "roles/adguard/tasks/#{file}.yml"))
  end
  deployments = gated.select do |task, _gates|
    task.dig("community.docker.docker_compose_v2", "state") == "present"
  end
  failures << "roles/adguard must deploy at least one Compose project" if deployments.empty?
  failures << "every AdGuard Compose deployment must carry #{GATE.inspect}, or a host that never " \
              "asked for a resolver gets one" unless
    deployments.all? { |_task, gates| gates.include?(GATE) }

  teardown = gated.select do |task, _gates|
    task.dig("community.docker.docker_compose_v2", "state") == "absent"
  end
  failures << "roles/adguard must converge a disabled deployment to `state: absent` rather than " \
              "skipping it, so the gate is a deployment decision in both directions" unless
    teardown.length == 1 &&
    teardown.first.last.include?("not adguard_deployment_enabled | bool")

  # The verification the issue names as its floor, held to its tag and to the
  # reading it must make.
  verify = role_tasks(root, "verify")
  status_reads = verify.select do |task|
    task.dig("ansible.builtin.uri", "url").to_s.include?("/control/status")
  end
  failures << "roles/adguard/tasks/verify.yml must read /control/status, which is where AdGuard " \
              "reports `running` and `protection_enabled`" if status_reads.empty?
  failures << "every AdGuard verification task must carry the platform_verify_adguard tag, or " \
              "verify.yml cannot select it" unless
    verify.all? { |task| Array(task["tags"]).include?("platform_verify_adguard") }
  assertions = verify.filter_map { |task| task["ansible.builtin.assert"] }
  conditions_text = assertions.flat_map { |assertion| Array(assertion["that"]) }.join(" ")
  %w[running protection_enabled].each do |reading|
    failures << "the AdGuard verification must assert #{reading}, not merely fetch the status " \
                "page: an HTTP 200 from a resolver that is not protecting is a passing check " \
                "on a broken deployment" unless conditions_text.include?(reading)
  end
  failures << "the AdGuard verification must prove filtering behaviourally -- a name the " \
              "declared list blocks and a name it does not -- rather than only reading a status" unless
    conditions_text.include?("FilteredBlackList") && conditions_text.include?("NotFiltered")

  # THE NAS'S OWN VERIFICATION MUST PUT A QUESTION ON THE WIRE, and this is the
  # check that would have caught the state the role shipped in. Every reading
  # above is HTTP to the control API, and /control/filtering/check_host is the
  # rule engine's verdict on a name: it resolves nothing, reaches no upstream and
  # never touches the DNS publication. Measured on v0.107.79 with the bootstrap
  # resolver blackholed, all four control-API readings were indistinguishable
  # from a healthy host -- running, protecting, filtering, rules_count 2,
  # FilteredBlackList and NotFilteredNotFound -- while the resolver answered
  # nothing at all. The contract in tests/contracts/adguard-runtime.rb makes the
  # behavioural claim, and it is never run against the NAS: verify.yml lists only
  # the role, and docs/getting-started-nas.md drives it by tag.
  #
  # Both halves are required, because either alone is satisfiable by a
  # deployment that cannot resolve. The blocked name comes out of local rules, so
  # a probe that asked only about it would pass with every upstream dead.
  resolution_probes = verify.select { |task| task.key?("adguard_dns_probe") }
  failures << "roles/adguard/tasks/verify.yml must ask the deployed resolver a real DNS question " \
              "through adguard_dns_probe. Every other reading here is the control API answering " \
              "for itself, and a resolver with no reachable upstream answers all of them exactly " \
              "as a healthy one does while handing every device on the network SERVFAIL" if
    resolution_probes.empty?
  probe_names = resolution_probes.flat_map { |task| Array(task.dig("adguard_dns_probe", "names")) }
                                 .map(&:to_s).join(" ")
  unless resolution_probes.empty?
    failures << "the AdGuard resolution probe must ask about both adguard_blocked_probe_domain " \
                "and adguard_allowed_probe_domain: the blocked one is answered out of local " \
                "rules, so a probe that asks only about it passes with every upstream dead" unless
      probe_names.include?("adguard_blocked_probe_domain") &&
      probe_names.include?("adguard_allowed_probe_domain")
    failures << "the AdGuard resolution probe must take its port from adguard_dns_port, so it " \
                "asks the port this host actually published rather than production's" unless
      resolution_probes.all? { |task| task.dig("adguard_dns_probe", "port").to_s.include?("adguard_dns_port") }
  end
  # The assertion over it, and specifically the half a dead upstream fails. An
  # unblocked name must come back NOERROR with an address; asserting only the
  # blocked half would restate what check_host already said.
  failures << "the AdGuard verification must assert that the unblocked name RESOLVES -- a " \
              "response code and at least one address -- or the resolution probe is a read whose " \
              "answer nothing checks" unless
    conditions_text.include?("adguard_verify_resolution") &&
    conditions_text.include?("rcode") &&
    conditions_text.include?("addresses")

  # THE FILTER-DOWNLOAD RACE, and the wedge behind it. Measured on v0.107.79: a
  # filter source answering HTTP 500 was asked exactly once, five seconds after
  # start, and never again in 353 seconds -- past the deployment poller's own
  # five-minute tick -- because filters_update_interval is 24 hours. On the same
  # instance, with rules_count at 0, AdGuard resolved doubleclick.net to a real
  # address: a deployment that has not loaded its lists is a live unfiltered
  # resolver rather than one that is starting up. POST /control/filtering/refresh
  # re-downloads immediately and is what makes the next converge able to heal it,
  # so without it one failed download at first start fails every tick until
  # somebody touches the host by hand -- and AdGuard is the last role in
  # site.yml, so that also stops the poller reaching its own install play.
  deploy_tasks = role_tasks(root, "deploy")
  refreshes = deploy_tasks.select do |task|
    task.dig("ansible.builtin.uri", "url").to_s.include?("/control/filtering/refresh")
  end
  failures << "roles/adguard/tasks/deploy.yml must force a filter refresh when the declared lists " \
              "have not loaded. AdGuard retries a failed download only after " \
              "filters_update_interval, which this platform renders as 24 hours, so one failed " \
              "fetch at first start otherwise fails every five-minute poller tick until a human " \
              "intervenes on the host" if refreshes.empty?
  failures << "the forced AdGuard filter refresh must be a POST" unless
    refreshes.empty? || refreshes.all? { |task| task.dig("ansible.builtin.uri", "method") == "POST" }
  deploy_conditions = deploy_tasks.filter_map { |task| task["ansible.builtin.assert"] }
                                  .flat_map { |assertion| Array(assertion["that"]) }.join(" ")
  failures << "roles/adguard/tasks/deploy.yml must refuse a deployment whose declared filter " \
              "lists never downloaded, or the run reports success over a resolver that is " \
              "answering every name on the network unfiltered" unless
    deploy_conditions.include?("adguard_filters_loaded")

  # THE ROLLBACK HAS TO BE RUN BY SOMETHING. `adguard_deployment_enabled: false`
  # is the documented emergency exit for a resolver answering for a whole
  # household, and inventory/group_vars/all/main.yml calls it one line. It was
  # exercised by accident while the lane gate was per-suite -- smoke and
  # idempotence-check converged the `state: absent` branch on every run -- and
  # making that request unconditional, so that CI converges what production
  # converges, took the proof away with it. The teardown assertion above is
  # structural: it says the role HAS an absent branch, not that anything ever
  # takes it.
  controller_source = File.read(File.join(root, "tests/integration_controller.sh"))
  failures << "the adguard integration lane must converge with adguard_deployment_enabled=false " \
              "and prove the container is gone. Nothing else runs that branch now that the lane " \
              "gate is unconditional, and a rollback nothing exercises is not an exit" unless
    controller_source.include?("run_play --tags adguard -e adguard_deployment_enabled=false") &&
    controller_source.include?("ADGUARD_TEARDOWN_VERIFIED")

  # ---------------------------------------------------------------------------
  # The three files this program requires and used to do nothing with, which is a
  # requirement that reads as a guard and is not one. Each now carries an
  # assertion that no other check makes.

  # The expectation file, against the role's own argument spec. tests/policy_support.rb
  # pins that this file exists and is well formed; what it cannot say is that its
  # vault_keys are the keys the role actually demands, because it never opens the
  # role. A key added to one and not the other leaves the vault contract and the
  # roster disagreeing about what this service costs.
  expectations = load_yaml(root, "tests/expected/adguard.yml") || {}
  failures << "tests/expected/adguard.yml must pin exactly the vault keys roles/adguard requires " \
              "(#{VAULT_CREDENTIALS.join(', ')}), and pins " \
              "#{Array(expectations['vault_keys']).sort.inspect}" unless
    Array(expectations["vault_keys"]).sort == VAULT_CREDENTIALS.sort
  failures << "tests/expected/adguard.yml must name the adguard role" unless
    expectations["role"] == "adguard"

  # The wrapper's production defaults, against the role's declared ports. The
  # wrapper hardcodes both so that a production run needs no environment at all;
  # that convenience is also how the contract would end up probing whatever now
  # answers on a port this platform moved away from, and finding it healthy.
  wrapper_source = File.read(File.join(root, "tests/contracts/adguard.sh"))
  {
    "PLATFORM_ADGUARD_PORT" => "adguard_port",
    "PLATFORM_ADGUARD_DNS_PORT" => "adguard_dns_port"
  }.each do |name, variable|
    fallback = wrapper_source[/#{name}:=(\d+)/, 1]&.to_i
    failures << "tests/contracts/adguard.sh must default #{name} to #{variable} " \
                "(#{defaults[variable].inspect}), and defaults it to #{fallback.inspect}" unless
      fallback == defaults[variable]
  end

  # The inventory, which is where the operator decision lives and where the two
  # directories are created. 0700 on the working directory is not a preference:
  # AdGuard's permcheck chmods it there at every start, so anything wider has
  # host_prep and the daemon reverting each other on every five-minute converge.
  inventory = load_yaml(root, "inventory/group_vars/all/main.yml") || {}
  failures << "inventory/group_vars/all/main.yml must carry the operator's adguard_deployment_enabled " \
              "decision, or the role's own default is the only thing deciding it" unless
    inventory.key?("adguard_deployment_enabled")
  storage = Array(inventory["nas_storage"]).select do |entry|
    entry.is_a?(Hash) && entry["path"].to_s.include?("/adguard/")
  end
  {
    "conf" => "0755",
    "work" => "0700"
  }.each do |leaf, mode|
    entry = storage.find { |candidate| candidate["path"].to_s.end_with?("/adguard/#{leaf}") }
    failures << "nas_storage must declare the AdGuard #{leaf} directory, which is where " \
                "host_prep creates it" if entry.nil?
    next if entry.nil?

    failures << "the AdGuard #{leaf} directory must be declared mode #{mode}: AdGuard's permcheck " \
                "chmods its working directory to 0700 at every start, so a wider declaration has " \
                "host_prep and the daemon reverting each other on every converge" unless
      entry["mode"] == mode
    failures << "the AdGuard #{leaf} directory must be recovery: cache -- this role renders the " \
                "whole configuration and the working directory holds only the query log and the " \
                "statistics" unless entry["recovery"] == "cache"
  end
end

unless failures.empty?
  # Every violation, one per line, each line naming the contract that authored
  # it. The prefix is not decoration: tests/adguard_contract_test.rb requires a
  # row that says "this must be refused" to see it, so a Ruby backtrace or a
  # shell diagnostic can no longer stand in for a refusal (#352).
  warn failures.map { |failure| "AdGuard contract failed: #{failure}" }.join("\n")
  exit 1
end
