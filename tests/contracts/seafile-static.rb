#!/usr/bin/env ruby
# The static half of the Seafile service contract: what a gated three-container
# file store owes this platform, decided from the repository alone with nothing
# deployed.
#
# usage: seafile-static.rb REPOSITORY
#
# PLATFORM_CONTRACT_REPO_DIR names the same repository and is read below for
# tests/policy_support.rb, so this program carries no copy of flatten_tasks.
#
# Structure is read from parsed YAML rather than from source text throughout,
# and roles/seafile is the file that makes the difference visible: its comments
# spell out `localhost`, `unix_socket` and `/api2/ping/` while explaining why the
# tasks beside them use none of those. A source-text assertion for "the database
# probe must not name localhost" fails against the correct role.
#
require "yaml"

root = ARGV.fetch(0)
failures = []
required = %w[
  roles/seafile/defaults/main.yml
  roles/seafile/meta/argument_specs.yml
  roles/seafile/tasks/main.yml
  roles/seafile/tasks/storage.yml
  roles/seafile/tasks/deploy.yml
  roles/seafile/tasks/pre_upgrade_backup.yml
  roles/seafile/tasks/recover_wedged_boot.yml
  roles/seafile/tasks/reconcile_seafevents.yml
  roles/seafile/tasks/reconcile_quota.yml
  roles/seafile/tasks/report.yml
  roles/seafile/tasks/verify.yml
  roles/seafile/templates/env.j2
  roles/seafile/templates/backup_manifest.j2
  services/seafile/compose.yml
  services/seafile/compose.mac.yml
  services/seafile/compose.integration.yml
  tests/expected/seafile.yml
  tests/contracts/seafile.sh
  inventory/group_vars/all/main.yml
  roles/beszel/defaults/main.yml
]
required.each do |relative|
  failures << "missing #{relative}" unless File.file?(File.join(root, relative))
end

require File.join(ENV.fetch("PLATFORM_CONTRACT_REPO_DIR"), "tests", "policy_support")
include PolicySupport

ROLE_TASK_FILES = %w[
  main storage deploy pre_upgrade_backup recover_wedged_boot reconcile_seafevents
  reconcile_quota report verify
].freeze
VAULT_CREDENTIALS = %w[
  vault_seafile_admin_email
  vault_seafile_admin_password
  vault_seafile_cache_password
  vault_seafile_db_password
  vault_seafile_db_root_password
  vault_seafile_db_username
  vault_seafile_jwt_private_key
].freeze
# repo:tag@sha256:<64 hex>. Both halves, because the tag is what a human and
# Renovate read and the digest is what makes the deployment reproducible.
IMAGE_PIN = %r{\A[a-z0-9][a-z0-9._/-]*:[A-Za-z0-9_][A-Za-z0-9_.-]*@sha256:[0-9a-f]{64}\z}

def role_tasks(root, file)
  flatten_tasks(
    YAML.safe_load_file(File.join(root, "roles/seafile/tasks/#{file}.yml"), aliases: true)
  )
end

# Every `{{ ... }}` region of a string, as Jinja's own lexer would find them:
# `{{` opens a variable block and the FIRST `}}` closes it. That last part is the
# whole of #492 and it is why this is a scanner rather than a regexp over the
# source -- a Go template nested inside a Jinja expression closes that expression
# early, so what looks like one construct is two.
def jinja_expression_regions(value)
  regions = []
  index = 0
  while (opened = value.index("{{", index))
    closed = value.index("}}", opened + 2)
    break if closed.nil?

    regions << value[(opened + 2)...closed]
    index = closed + 2
  end
  regions
end

if failures.empty?
  compose = YAML.safe_load_file(File.join(root, "services/seafile/compose.yml"), aliases: true)
  services = compose.fetch("services")
  server = services.fetch("seafile")
  database = services.fetch("db")

  # --- the three containers -------------------------------------------------

  {
    "seafile" => "docker.io/seafileltd/seafile-pro-mc",
    "db" => "docker.io/library/mariadb",
    "cache" => "docker.io/valkey/valkey"
  }.each do |name, repository|
    image = services.fetch(name, {})["image"].to_s
    failures << "the Seafile #{name} image must pin #{repository} by tag and manifest digest" unless
      image.match?(IMAGE_PIN) && image.split(":").first == repository
  end

  expected = YAML.safe_load_file(File.join(root, "tests/expected/seafile.yml"))
  declared_cpus = expected.fetch("container_cpus")
  # Deliberately no assertion about what the three ceilings add up to. The
  # ceilings are a per-container limit on one shared cpuset rather than
  # reservations carved out of it, so they oversubscribe that set on purpose;
  # tests/policy_test.rb records that model at length and enforces the rule that
  # does mean something -- no single ceiling wider than the set -- against
  # platform_container_cpu_budget. A sum compared against the budget here would
  # be the mistake that check exists to forestall, and it would refuse this stack
  # (2.0 + 1.0 + 0.5) for a rule the repository does not hold.
  failures << "each Seafile container must take the CPU ceiling tests/expected/seafile.yml declares" unless
    services.transform_values { |service| service["cpus"] } == declared_cpus

  base_names = { "seafile" => "seafile", "db" => "seafile-db", "cache" => "seafile-cache" }
  failures << "each Seafile container must carry its production name" unless
    services.transform_values { |service| service["container_name"] } == base_names
  # Sandbox cleanup finds these containers by the namespaced prefix, so the two
  # disposable overrides have to spell all three names identically. A name in one
  # override and not the other leaves a container nothing tears down.
  namespaced = base_names.transform_values { |name| "${PLATFORM_PROJECT_NAME:?}-#{name}" }
  overrides = %w[mac integration].to_h do |kind|
    document = YAML.safe_load_file(File.join(root, "services/seafile/compose.#{kind}.yml"))
    [kind, document.fetch("services").transform_values { |service| service["container_name"] }]
  end
  failures << "both disposable Seafile overrides must name the same three sandbox containers" unless
    overrides.values.all? { |names| names == namespaced }

  # The bundled nginx multiplexes seahub, seafhttp and seafdav behind one port,
  # and the database and the cache join the stack's own network. A published port
  # on either of those two is an unauthenticated database or cache on the LAN.
  failures << "only the Seafile server may publish a port" unless
    services.select { |_name, service| service.key?("ports") }.keys == ["seafile"]

  volumes = services.values.flat_map { |service| Array(service["volumes"]) }
  volume_sources = volumes.map { |volume| volume.to_s.split(":/", 2).first }
  failures << "every Seafile volume source must be a required environment reference" unless
    !volume_sources.empty? &&
    volume_sources.all? { |source| source.match?(/\A\$\{[A-Z][A-Z0-9_]*:\?\}\z/) }

  failures << "every Seafile container must carry its Dozzle group and name" unless
    services.transform_values { |service| service["labels"] } == {
      "seafile" => { "dev.dozzle.group" => "seafile", "dev.dozzle.name" => "seafile" },
      "db" => { "dev.dozzle.group" => "seafile", "dev.dozzle.name" => "db" },
      "cache" => { "dev.dozzle.group" => "seafile", "dev.dozzle.name" => "cache" }
    }

  # --mariadbupgrade is what pairs with MARIADB_AUTO_UPGRADE: it holds the health
  # check red until an in-place upgrade finishes, so the server is never started
  # against a data directory mid-migration.
  failures << "the Seafile database probe must stay red through an in-place upgrade" unless
    Array(database.dig("healthcheck", "test")).join(" ").include?("--mariadbupgrade") &&
    database.dig("environment", "MARIADB_AUTO_UPGRADE").to_s == "1"

  failures << "the Seafile server must wait for a healthy database and cache" unless
    server.dig("depends_on", "db", "condition") == "service_healthy" &&
    server.dig("depends_on", "cache", "condition") == "service_healthy"

  server_environment = server.fetch("environment")
  failures << "Seafile must take its cache from the Redis protocol provider" unless
    server_environment["CACHE_PROVIDER"] == "redis" && server_environment["REDIS_HOST"] == "cache"
  failures << "Seafile must log to stdout where Dozzle can read it" unless
    server_environment["SEAFILE_LOG_TO_STDOUT"].to_s == "true"
  # true makes the container run as the seafile account throughout, which needs
  # the bind mount already owned by that uid; nas_storage claims no owner here,
  # so the entrypoint has to keep its root-then-drop form and chown for itself.
  failures << "Seafile must keep the root-then-drop entrypoint its bind mount needs" unless
    server_environment["NON_ROOT"].to_s == "false"

  # Seafile's own setup connects as root and creates the three databases and the
  # account that owns them. Declaring either here would create a second,
  # divergent owner of the same schemas.
  database_environment = database.fetch("environment")
  failures << "the Seafile database must not declare a second owner of its schemas" if
    database_environment.key?("MYSQL_DATABASE") || database_environment.key?("MYSQL_USER")

  # --- the role -------------------------------------------------------------

  imports = role_tasks(root, "main").filter_map { |task| task["ansible.builtin.import_tasks"] }
  expected_stages = %w[
    storage.yml deploy.yml reconcile_quota.yml reconcile_seafevents.yml report.yml verify.yml
  ]
  failures << "the Seafile role must import every stage it owns" unless
    expected_stages.all? { |stage| imports.include?(stage) }
  # The load-bearing ordering claim, and it is compared by index rather than
  # grepped: Seafile writes seafevents.conf during its own first start, so a
  # reconciliation placed before the deployment finds nothing on run 1 and
  # repairs on run 2 -- two runs disagreeing, which is what idempotence forbids.
  # One assertion for both reconciliation stages, because the two orderings it
  # states cannot be violated independently: any stage moved above the deployment
  # also moves above the other reconciliation. The second half is the one that is
  # not obvious -- the quota stage carries no restart of its own and depends on
  # the one at the end of the event stage, so a quota repair placed after it is a
  # repair nothing reloads until some later converge happens to change something
  # else.
  failures << "both Seafile reconciliations must run after the deployment, quota before events" unless
    imports.index("reconcile_quota.yml").to_i > imports.index("deploy.yml").to_i &&
    imports.index("reconcile_seafevents.yml").to_i > imports.index("reconcile_quota.yml").to_i

  deploy = role_tasks(root, "deploy")
  compose_tasks = deploy.select { |task| task.key?("community.docker.docker_compose_v2") }
  teardown = compose_tasks.select do |task|
    task.dig("community.docker.docker_compose_v2", "state") == "absent"
  end
  # Switched off means removed, not merely left alone: flipping the flag back has
  # to undo the deployment rather than leave three containers nothing claims.
  failures << "the disabled Seafile project must be torn down rather than left running" unless
    teardown.length == 1 &&
    teardown.first.dig("community.docker.docker_compose_v2", "remove_orphans") == true &&
    Array(teardown.first["when"]).include?("not seafile_deployment_enabled | bool")
  deployments = compose_tasks.select do |task|
    task.dig("community.docker.docker_compose_v2", "state") == "present"
  end
  failures << "every Seafile deployment task must be gated on the operator switch" unless
    !deployments.empty? &&
    deployments.all? { |task| Array(task["when"]).include?("seafile_deployment_enabled | bool") }

  # --- the wedged first boot ------------------------------------------------
  #
  # seafileltd/seafile-pro-mc's enterpoint.sh launches start.py once and then
  # idles for ever, so a start.py that raised inside init_seafile_server() or
  # that is still in one of utils.py's unbounded wait loops leaves a container
  # Docker reports running with an unhealthy health check. Nothing recovers it:
  # `restart: unless-stopped` acts on exit and a wedged container does not exit,
  # and `up -d` with unchanged configuration keeps the same container id. The
  # three checks below are what keeps the role's remediation bounded, honest and
  # narrow -- the recreate task's own gating is structural rather than asserted,
  # because it is reachable only from a rescue the operator switch already
  # guards.
  recovery = role_tasks(root, "recover_wedged_boot")
  recreate = recovery.select do |task|
    task.dig("community.docker.docker_compose_v2", "recreate") == "always"
  end
  # The guard that spends the budget once, and it is asserted on the block inside
  # the included file rather than on the include that loops it. A looped
  # include_tasks expands every iteration before any included task runs and
  # evaluates its own conditional there, so a fact the file sets cannot stop the
  # next iteration; a budget above one would recreate a server that had already
  # recovered.
  recreate_block = recovery.find do |task|
    Array(task["block"]).any? do |inner|
      inner.dig("community.docker.docker_compose_v2", "recreate") == "always"
    end
  end
  # --force-recreate is what replaces a container whose spec has not changed, and
  # `dependencies: false` is what keeps it from taking db and cache with it: the
  # flag applies to everything the `up` operates on, and bouncing the data
  # services is what the two-phase bring-up above exists to prevent.
  failures << "the wedged Seafile boot must be recovered by force-recreating the server alone" unless
    recreate.length == 1 &&
    recreate.first.dig("community.docker.docker_compose_v2", "state") == "present" &&
    recreate.first.dig("community.docker.docker_compose_v2", "services") == ["seafile"] &&
    recreate.first.dig("community.docker.docker_compose_v2", "dependencies") == false &&
    Array(recreate_block&.fetch("when", nil)).include?("not seafile_boot_recovered | bool")

  # The evidence dies with the container, so the ordering is the property. The
  # capture lives in deploy.yml and the recreate in the file deploy.yml includes,
  # so the claim is made where both are visible: the health read must sit at a
  # lower index than the include that spends the budget.
  health_capture = deploy.index do |task|
    task_strings(task["ansible.builtin.command"]).any? { |value| value.include?("{{json .State.Health}}") }
  end
  recovery_include = deploy.index do |task|
    task["ansible.builtin.include_tasks"] == "recover_wedged_boot.yml"
  end
  failures << "the wedged Seafile server's health verdict must be captured before it is recreated" unless
    health_capture && recovery_include && health_capture < recovery_include
  # A bare `docker inspect` prints .Config.Env, which for this stack is the
  # rendered environment file: the MariaDB root password, the Seafile
  # administrator password and the Valkey password in full. Every inspection this
  # role performs must therefore narrow its output with --format.
  # pre_upgrade_backup inspects containers too, and the reason this guard exists
  # applies to it unchanged, so it is read here rather than at its own section
  # further down.
  backup = role_tasks(root, "pre_upgrade_backup")
  unformatted_inspects = (deploy + recovery + backup).select do |task|
    argv = Array(task.dig("ansible.builtin.command", "argv")).map(&:to_s)
    argv.include?("inspect") && !argv.include?("--format")
  end
  failures << "Seafile diagnostics must narrow every inspection rather than print the container environment" unless
    unformatted_inspects.empty?

  # Addressing the service by name forces the connection through the network
  # stack, where only root@% can answer and only a matching password gets in. A
  # probe over the container's own socket answers as root@localhost instead,
  # which on a Debian/Ubuntu MariaDB the unix_socket plugin authorises by uid
  # whatever the credential says; tests/contracts/seafile-runtime.rb has since
  # measured that plugin absent from this image, and the root@% half is what
  # keeps this TCP regardless.
  probe = deploy.find { |task| task.key?("community.docker.docker_compose_v2_exec") }
  probe_argv = Array(probe&.dig("community.docker.docker_compose_v2_exec", "argv")).join(" ")
  failures << "the Seafile database probe must authenticate over TCP as root" unless
    probe_argv.include?("--protocol=tcp") && probe_argv.include?("--host=db") &&
    probe_argv.include?("--user=root") &&
    !probe_argv.include?("--socket") && !probe_argv.include?("localhost")

  reconcile = role_tasks(root, "reconcile_seafevents")
  # `enabled` is not a unique key in this INI document. pro.py's own first-run
  # template declares one under every one of its five sections -- [SEAHUB EMAIL],
  # [STATISTICS], [AUDIT], [INDEX FILES] and [FILE HISTORY] -- so a per-line
  # rewrite switches off four features to change one and reports itself
  # converged. Two properties make that unreachable rather than merely avoided:
  # the pattern is built from the section of the setting being repaired, and
  # [^\[]*? bounds the match to that section, a section header being the only
  # thing in this grammar that opens with a bracket.
  assignment = reconcile.filter_map { |task| task.dig("vars", "seafile_seafevents_assignment") }
  failures << "the Seafile event repair must be bounded to the section of the setting it repairs" unless
    assignment.length == 1 &&
    assignment.first.include?('\[{{ item.section }}\]') && assignment.first.include?('[^\[]*?')
  # The same for the pattern the report reads with, because a report that named
  # the wrong section would tell an operator a key is undeclared while the repair
  # beside it rewrites that key perfectly well.
  reported = reconcile.flat_map do |task|
    %w[seafile_seafevents_key seafile_seafevents_capture].filter_map { |name| task.dig("vars", name) }
  end
  failures << "the Seafile event report must read the section of the setting it reports" unless
    reported.length == 2 &&
    reported.all? { |pattern| pattern.include?('\[{{ item.section }}\]') && pattern.include?('[^\[]*?') }
  # Every task that repairs or reports must be driven by the declared list, so a
  # setting added to that list is owned by construction rather than by a second
  # edit somebody has to remember.
  looped = reconcile.select { |task| task["loop"] == "{{ seafile_seafevents_managed_settings }}" }
  failures << "the Seafile event reconciliation must loop over its declared settings" unless
    looped.length == 2

  restart = reconcile.select do |task|
    task.dig("community.docker.docker_compose_v2", "state") == "restarted"
  end
  # seafevents reads its configuration once, at start, and the file lives in a
  # bind mount rather than in the Compose spec, so nothing recreates the
  # container when it changes. Not a handler: the verification one stage later
  # authenticates against the running server, and a deferred restart would leave
  # that server holding the configuration the repair just replaced.
  failures << "the repaired Seafile event configuration must be restarted into the running server" unless
    restart.length == 1 &&
    restart.first.dig("community.docker.docker_compose_v2", "services") == ["seafile"] &&
    restart.first.dig("community.docker.docker_compose_v2", "dependencies") == false &&
    Array(restart.first["when"]).any? { |value| value.to_s.include?("seafile_seafevents_repair is changed") }
  # The one restart in this role is the one both reconciliations depend on. A
  # quota written into seafile.conf that nothing reloads is a converge reporting
  # a change the running server has not seen, and seaf-server reads that file
  # once, at start.
  failures << "the restart must also carry the repaired Seafile quota policy" unless
    restart.length == 1 &&
    Array(restart.first["when"]).any? { |value| value.to_s.include?("seafile_server_config_repair is changed") }
  failures << "the Seafile restart must be a task rather than a deferred handler" if
    Dir.exist?(File.join(root, "roles/seafile/handlers"))

  verify = role_tasks(root, "verify")
  verification = verify.select { |task| Array(task["tags"]).include?("platform_verify_seafile") }
  login = verification.find { |task| task.dig("ansible.builtin.uri", "method") == "POST" }
  # POST /api2/auth-token/ is the one endpoint on the unauthenticated surface
  # that cannot answer without the databases: it authenticates against ccnet_db
  # and seahub_db and then get-or-creates the token row in seahub_db.
  failures << "Seafile verification must exchange the vault administrator for a token" unless
    login &&
    login.dig("ansible.builtin.uri", "url").to_s.end_with?("/auth-token/") &&
    login.dig("ansible.builtin.uri", "body", "username") == "{{ vault_seafile_admin_email }}" &&
    login.dig("ansible.builtin.uri", "body", "password") == "{{ vault_seafile_admin_password }}"
  # GET /api2/ping/ returns a constant from a view that touches nothing and
  # answers exactly as happily with both databases down. It is the right probe
  # for the post-restart wait in reconcile_seafevents.yml and the wrong one here.
  failures << "Seafile verification must not settle for an endpoint its databases cannot fail" if
    task_strings(verification).any? { |value| value.include?("/ping/") }

  # --- redaction, defaults and the two roots --------------------------------

  everything = ROLE_TASK_FILES.flat_map { |file| role_tasks(root, file) }
  credential_tasks = everything.select do |task|
    task_strings(task).any? { |value| value.include?("vault_seafile_") }
  end
  failures << "every Seafile task naming a vault credential must be redacted" unless
    credential_tasks.length >= 2 && credential_tasks.all? { |task| task["no_log"] == true }
  # seafevents.conf opens with a [DATABASE] section carrying the Seafile database
  # account and its password, and that credential arrives as file content rather
  # than as a vault_ name, so the rule above cannot see it.
  seafevents_io = reconcile.select do |task|
    task.key?("ansible.builtin.slurp") || task.key?("ansible.builtin.copy")
  end
  failures << "the Seafile event configuration carries a database password and must be redacted" unless
    seafevents_io.length == 2 && seafevents_io.all? { |task| task["no_log"] == true }

  defaults = YAML.safe_load_file(File.join(root, "roles/seafile/defaults/main.yml"))
  failures << "Seafile must keep its data and database roots under the Docker root" unless
    defaults["seafile_data_host_path"] == "{{ nas_docker_root }}/seafile/data" &&
    defaults["seafile_db_host_path"] == "{{ nas_docker_root }}/seafile/db"
  # /shared is the bind mount and the server lays out /shared/seafile/conf/, so
  # the file the reconciliation owns lands exactly here. The runtime half proves
  # the same path against a running container.
  failures << "the Seafile event configuration must be the file the server writes inside the volume" unless
    defaults["seafile_seafevents_config_path"] == "{{ seafile_data_host_path }}/seafile/conf/seafevents.conf"
  failures << "this platform must own file indexing as switched off" unless
    defaults["seafile_index_files_enabled"] == false
  # The audit log is a #445 requirement rather than a preference, and it is
  # declared rather than left alone for a reason the value alone does not carry:
  # seafevents' own reader falls through to enable_audit = False when the key is
  # absent, so an image that stopped writing it would switch auditing off in
  # silence. Owning the key is what turns that into a repair.
  failures << "this platform must own the Seafile audit log as switched on" unless
    defaults["seafile_audit_log_enabled"] == true
  # Every owned setting names its section. A row without one is the line-scoped
  # repair this file exists to refuse, arriving as data instead of as code.
  managed = Array(defaults["seafile_seafevents_managed_settings"])
  failures << "every owned Seafile event setting must name its section, key and value" unless
    managed.any? &&
    managed.all? { |setting| %w[section key value].all? { |field| setting[field].to_s != "" } }
  owned = managed.map { |setting| [setting["section"], setting["key"]] }
  failures << "this platform must own [INDEX FILES] enabled and [AUDIT] enabled" unless
    owned.include?(["INDEX FILES", "enabled"]) && owned.include?(["AUDIT", "enabled"])

  # seafile.conf sits beside seafevents.conf in the same generated conf/
  # directory, and the same first-run-only argument makes the same repair
  # converge there.
  failures << "the Seafile server configuration must be the file the server writes inside the volume" unless
    defaults["seafile_server_config_path"] == "{{ seafile_data_host_path }}/seafile/conf/seafile.conf"
  # A decimal number with an optional k/kb/m/mb/g/gb/t/tb suffix, because
  # seaf-server logs "Invalid default quota" for every other spelling and falls
  # back to unlimited -- a silent no-quota rather than an error.
  failures << "the Seafile quota must be spelled the way seaf-server parses it" unless
    defaults["seafile_default_user_quota"].to_s.match?(/\A[0-9]+([kmgt]b?)?\z/)

  quota = role_tasks(root, "reconcile_quota")
  # The generated seafile.conf carries no [quota] section at all, so what this
  # writes is a whole section rather than a key. A marked block is what can be
  # found again, changed in place and told apart from a line an operator added;
  # a lineinfile keyed on `default` would match a key of that name under any
  # section, which is the same class of defect the section-scoping above exists
  # to refuse, in a different file.
  block = quota.select { |task| task.key?("ansible.builtin.blockinfile") }
  failures << "the Seafile quota must be written as one owned block" unless
    block.length == 1 &&
    block.first.dig("ansible.builtin.blockinfile", "marker").to_s.include?("nas-platform seafile") &&
    block.first.dig("ansible.builtin.blockinfile", "block").to_s.include?("[quota]")
  failures << "the Seafile quota must not claim a literal mode" unless
    block.length == 1 &&
    block.first.dig("ansible.builtin.blockinfile", "mode").to_s
         .include?("seafile_server_config_stat.stat.mode")
  # seafile.conf opens with a [database] section carrying the Seafile database
  # account and its password, and that credential arrives as file content rather
  # than as a vault_ name, so the repository's own no_log rule cannot see it.
  quota_io = quota.select { |task| task.key?("ansible.builtin.blockinfile") || task.key?("ansible.builtin.slurp") }
  failures << "the Seafile server configuration carries a database password and must be redacted" unless
    quota_io.length >= 1 && quota_io.all? { |task| task["no_log"] == true }
  # A refusal before the write, because the value it refuses is one seaf-server
  # accepts and then ignores: an unparseable quota is logged and replaced with
  # unlimited, so shipping one is shipping no quota at all.
  guard = quota.select { |task| task.key?("ansible.builtin.assert") }
  failures << "the Seafile quota must be refused before it is written" unless
    guard.length == 1 &&
    Array(guard.first.dig("ansible.builtin.assert", "that"))
      .any? { |value| value.to_s.include?("seafile_default_user_quota is match") } &&
    quota.index(guard.first).to_i < quota.index(block.first).to_i

  # --- what watches the volume Seafile fills ---------------------------------
  #
  # Seafile is the only stack here whose stored volume is chosen by a person, and
  # it stores on /volume1 -- the volume every other stack keeps its database on.
  # The quota above is the bound; this is the backstop, and it is Beszel's
  # system-level Disk alert rather than anything Seafile-specific. Beszel's
  # managed alerts are per-system with no container dimension, and roles/beszel's
  # own reconciliation refuses a duplicate (user, system, name), so ONE Disk
  # alert per system is the whole of what can exist: there is no warn-then-page
  # tier and no per-service alert to add. What makes the one alert the right one
  # is that the agent's FILESYSTEM names volume1, which services/beszel's compose
  # file declares and tests/contracts/beszel covers.
  #
  # Asserted here rather than in roles/beszel's own tests because this is where
  # the dependency is: removing the Disk alert would leave Seafile's unbounded
  # growth watched by nothing, and nothing in roles/beszel knows that.
  beszel_defaults = YAML.safe_load_file(File.join(root, "roles/beszel/defaults/main.yml"))
  disk_alert = Array(beszel_defaults["beszel_alerts"]).find { |alert| alert["name"] == "Disk" }
  failures << "Seafile's unbounded growth must leave a managed Beszel disk alert behind it" unless
    disk_alert && disk_alert["value"].to_i.positive? && disk_alert["value"].to_i <= 90

  # The wrapper beside this program is read out of the INSPECTED tree, like
  # tests/policy_support.rb above and for the same reason: it is that tree's own
  # contract default that has to agree with that tree's own role default. It is
  # also why tests/seafile_contract_test.rb's two-roots rows delete the sibling
  # programs from the inspected tree rather than the whole tests/contracts
  # directory -- the property being proven there is that the PROGRAMS come from
  # the checkout, and removing the wrapper as well would only be removing this
  # assertion's own input.
  wrapper = File.read(File.join(root, "tests/contracts/seafile.sh"))
  wrapper_port = wrapper[/PLATFORM_SEAFILE_PORT:=(\d+)/, 1]
  failures << "the Seafile contract's default port must be the port the role publishes" unless
    wrapper_port && Integer(wrapper_port, 10) == defaults["seafile_port"] &&
    Array(server["ports"]) == ["#{defaults['seafile_port']}:80"]

  options = YAML.safe_load_file(File.join(root, "roles/seafile/meta/argument_specs.yml"))
                .dig("argument_specs", "main", "options")
  failures << "every Seafile vault credential must be a required role argument" unless
    VAULT_CREDENTIALS.all? do |name|
      options.dig(name, "required") == true && options.dig(name, "type") == "str"
    end
  # Declared bool rather than left to a truthy string: the teardown branch and
  # the deploy branch are selected by this one value, and the string "false" is
  # true in Jinja.
  failures << "the Seafile operator switch must be a required declared boolean" unless
    options.dig("seafile_deployment_enabled", "type") == "bool" &&
    options.dig("seafile_deployment_enabled", "required") == true
  # Bounded at one recreate, and the bound is a declared integer because the
  # rescue turns it into range(1, limit + 1): a string there is a Jinja error at
  # the one moment the role is already recovering from a failure. A wedge that
  # survives one recreate from an untouched image against an untouched volume is
  # a broken deployment rather than an unlucky one, so raising this default is a
  # policy change rather than a tuning knob, and 0 stays meaningful -- detect,
  # report the health log and touch nothing.
  failures << "the Seafile wedged-boot recreate budget must be one declared integer recreate" unless
    options.dig("seafile_wedged_boot_recreate_limit", "type") == "int" &&
    defaults["seafile_wedged_boot_recreate_limit"] == 1

  # Compose interpolates $ in an env file and silently truncates what follows. A
  # cut database password produces a server that cannot reach its database and a
  # cut admin password an account nobody can log into, and neither says so.
  template = File.read(File.join(root, "roles/seafile/templates/env.j2"))
  interpolations = template.scan(/\{\{[^}]*vault_seafile_[^}]*\}\}/)
  failures << "every Seafile credential must survive Compose's own interpolation" unless
    interpolations.length == VAULT_CREDENTIALS.length &&
    interpolations.all? { |value| value.include?("replace('$', '$$')") }

  # Files on disk are not the files: content is stored as content-addressed
  # blocks and the mapping back to filenames lives in the database, so a
  # filesystem copy taken without a consistent dump restores an unreadable pile
  # of blocks. Neither root is recoverable without the other.
  inventory = YAML.safe_load_file(File.join(root, "inventory/group_vars/all/main.yml"))
  declarations = Array(inventory["nas_storage"]).select do |entry|
    entry.is_a?(Hash) && entry["path"].to_s.include?("/seafile/")
  end
  failures << "every Seafile storage root must be declared unrecoverable without the others" unless
    declarations.length == 3 && declarations.all? { |entry| entry["recovery"] == "critical" }
  # 0700, and it is the one Seafile path whose mode is asserted here rather than
  # left to nas_storage's own conventions. A mariadb-dump of ccnet_db and
  # seahub_db is every account row Seafile holds in plain readable SQL and the
  # conf/ copy beside it carries the database account and the JWT signing key,
  # so this directory is secret-bearing in a way the two live trees are not --
  # inside those the container manages access, and inside this one nothing does.
  backup_declaration = declarations.find { |entry| entry["path"].to_s.end_with?("/seafile/backups") }
  failures << "the Seafile backup root must be declared private" unless
    backup_declaration && backup_declaration["mode"] == "0700"

  # --- the pre-upgrade backup -----------------------------------------------
  #
  # An upgrade migrates ccnet_db, seafile_db and seahub_db one way and rewrites
  # conf/ as it goes, and MARIADB_AUTO_UPGRADE migrates the datadir in place
  # before the database container reports healthy. By the time either has
  # answered once there is nothing left to copy, so the whole of what follows is
  # about the backup happening BEFORE Compose is asked to do anything, in the
  # right internal order, and failing loudly rather than quietly.

  backup_include = deploy.index do |task|
    task["ansible.builtin.include_tasks"] == "pre_upgrade_backup.yml"
  end
  # The first Compose task that BRINGS THE STACK UP, not the first Compose task:
  # the teardown branch above it is a `state: absent` that runs only with the
  # switch off, and comparing against that would let the backup sit after the
  # data services and still pass.
  first_deployment = deploy.index do |task|
    task.dig("community.docker.docker_compose_v2", "state") == "present"
  end
  # Before BOTH Compose phases rather than merely before the application one:
  # the data phase is where a MariaDB image change lands, and its datadir
  # migration is exactly as one-way as the server's schema migration.
  failures << "the Seafile pre-upgrade backup must run before Compose touches the stack" unless
    backup_include && first_deployment && backup_include < first_deployment
  # Gated on the include rather than inside the file. A conditional include
  # applies to every task it brings in, so the switched-off branch reads and
  # writes nothing -- and a gate repeated per task is one a later task forgets.
  failures << "the Seafile pre-upgrade backup must be gated on the operator switch" unless
    backup_include &&
    Array(deploy.fetch(backup_include)["when"]).include?("seafile_deployment_enabled | bool")

  dump = backup.select do |task|
    task_strings(task["community.docker.docker_compose_v2_exec"]).any? do |value|
      value.include?("mariadb-dump")
    end
  end
  dump_argv = Array(dump.first&.dig("community.docker.docker_compose_v2_exec", "argv")).join(" ")
  # --single-transaction is what makes "the service does not have to be stopped"
  # true rather than hopeful: without it the three schemas are dumped one after
  # another against a server that is still writing, and the restore is a set of
  # rows that never coexisted. The three database names come from the role's own
  # list so the contract cannot drift from what the dump actually names.
  backup_defaults = YAML.safe_load_file(File.join(root, "roles/seafile/defaults/main.yml"))
  declared_databases = Array(backup_defaults["seafile_backup_databases"])
  failures << "the Seafile dump must name ccnet_db, seafile_db and seahub_db" unless
    declared_databases.sort == %w[ccnet_db seafile_db seahub_db]
  # The argv interpolates the list rather than spelling the three names, which is
  # the point: the dump, the manifest and this contract all read one declaration,
  # so a fourth schema added to the role reaches the dump without anybody having
  # to remember this file.
  failures << "the Seafile pre-upgrade dump must be one consistent snapshot of all three databases" unless
    dump.length == 1 &&
    dump_argv.include?("--single-transaction") &&
    dump_argv.include?("--databases {{ seafile_backup_databases | join(' ') }}")
  # Over TCP as root for the reason tasks/deploy.yml's probe is: only root@% can
  # answer through the network stack, and the Seafile account holds grants on
  # the three schemas rather than the server-wide read a dump of all three needs.
  failures << "the Seafile pre-upgrade dump must authenticate over TCP as root" unless
    dump_argv.include?("--protocol=tcp") && dump_argv.include?("--user=root") &&
    !dump_argv.include?("localhost")
  # --result-file rather than a redirect, so database contents never pass
  # through the module's stdout: a dump captured into a registered variable
  # would force no_log onto this task and censor the failure an operator reads.
  failures << "the Seafile pre-upgrade dump must write to a file rather than through Ansible" unless
    dump_argv.include?("--result-file")
  # The refusal. `failed_when: false` anywhere on the dump would turn the whole
  # guard into a report, and the upgrade would proceed over a backup that never
  # landed.
  failures << "the Seafile pre-upgrade dump must be allowed to fail the run" if
    dump.any? { |task| task.key?("failed_when") }
  # Exit status is not enough on its own: mariadb-dump has exited 0 having
  # written a diagnostic and an empty file, and an empty file is a backup only in
  # the sense that something is there.
  dump_assertions = backup.select do |task|
    Array(task.dig("ansible.builtin.assert", "that")).any? do |condition|
      condition.to_s.include?("seafile_database_dump_file.stat")
    end
  end
  failures << "the Seafile upgrade must be refused unless the dump landed and is not empty" unless
    dump_assertions.length == 1 &&
    Array(dump_assertions.first.dig("ansible.builtin.assert", "that")).any? do |condition|
      condition.to_s.include?("size > 0")
    end

  # THE ORDERING, and it is the claim this whole file exists to keep. Seafile
  # keeps the mapping from content-addressed blocks back to filenames in the
  # database and nowhere else, so anything copied out of the volume BEFORE the
  # dump can only be missing what the dump then names. Compared by index rather
  # than grepped, because both tasks would still be present in a file that ran
  # them the wrong way round.
  conf_copy = backup.index { |task| task.key?("ansible.builtin.copy") }
  dump_index = backup.index do |task|
    task_strings(task["community.docker.docker_compose_v2_exec"]).any? do |value|
      value.include?("mariadb-dump")
    end
  end
  failures << "the Seafile database dump must be taken before anything is copied out of the volume" unless
    dump_index && conf_copy && dump_index < conf_copy
  # conf/ carries the Seafile database account, its password and the JWT signing
  # key as file content rather than as vault_ names, which is the same case
  # tasks/reconcile_seafevents.yml already carries no_log for.
  failures << "the Seafile configuration copy carries a database password and must be redacted" unless
    conf_copy && backup.fetch(conf_copy)["no_log"] == true
  # admin.txt, excluded by name. /scripts/start.py writes the administrator
  # password there in plaintext on every container start and removes it in a
  # finally:, so a container killed mid-start leaves it on disk -- and a backup
  # that swept conf/ blindly would preserve that plaintext for as long as the
  # backup is kept.
  conf_find = backup.find do |task|
    task.key?("ansible.builtin.find") &&
      task_strings(task["ansible.builtin.find"]).any? { |value| value.include?("conf") }
  end
  failures << "the Seafile configuration backup must exclude the plaintext administrator handoff" unless
    conf_find && Array(conf_find.dig("ansible.builtin.find", "excludes")).include?("admin.txt")
  failures << "admin.txt must be named in the exclusions every Seafile backup records" unless
    Array(backup_defaults["seafile_backup_excluded_paths"]).sort ==
      ["conf/admin.txt", "logs", "pro-data/search"]

  # A third root, and separate from both trees it protects. A backup inside the
  # library is lost with the library, and a .sql file under /var/lib/mysql is a
  # directory MariaDB scans as if it were a schema.
  failures << "the Seafile backup must land on a root of its own under the Docker root" unless
    backup_defaults["seafile_backup_host_path"] == "{{ nas_docker_root }}/seafile/backups"
  # The mount is on the database container because mariadb-dump lives there, and
  # !override replaces a volume list rather than extending it, so the Mac
  # override has to spell both mounts or the dump lands nowhere.
  failures << "the Seafile database container must mount the backup root" unless
    Array(database["volumes"]).any? { |volume| volume.to_s.start_with?("${SEAFILE_BACKUP_PATH:?}:") }
  mac_database_volumes = Array(
    YAML.safe_load_file(File.join(root, "services/seafile/compose.mac.yml"))
        .dig("services", "db", "volumes")
  )
  failures << "the Mac Seafile override must keep the backup mount its !override replaces" unless
    mac_database_volumes.any? { |volume| volume.to_s.start_with?("${SEAFILE_BACKUP_PATH:?}:") }
  failures << "the Seafile environment must render the backup root Compose mounts" unless
    template.include?("SEAFILE_BACKUP_PATH={{ seafile_backup_host_path }}")

  # --- Go templates, and the trap #492 fell into ----------------------------
  #
  # `{% raw %}` is a Jinja TAG, and a tag is only a tag in template context. Put
  # one inside a `{{ }}` expression -- as the string literal of a list this role
  # then joined into an argv -- and Jinja is lexing a string, so the tag is
  # characters. Measured against ansible-core 2.21.3: the expression form renders
  # with `{% raw %}` still in it, and `docker container inspect --format` then
  # prints that wrapper around every value (Docker 29.7.2). The image census came
  # back as `{% raw %}seafile=...`, matched nothing, and this role reported
  # `stack-not-running` against a stack that was serving its API -- silently, on
  # every converge, which on a NAS is a backup guard that never fires.
  #
  # roles/seafile is the only role in this repository that writes Go templates
  # today, so the guard lives here rather than in tests/policy_test.rb; the defect
  # class is not Seafile's and the next role to need a `--format` inherits this
  # comment along with the trap.
  #
  # Scope, stated because the diagnostic does not carry it: this reads the task
  # files ROLE_TASK_FILES names -- pre_upgrade_backup among them, which is where
  # the defect was -- and not templates/. env.j2 and backup_manifest.j2 are Jinja
  # too and neither writes a Go template today; a template that starts to would
  # need this widened rather than assumed covered.
  raw_inside_expression = ROLE_TASK_FILES.flat_map do |file|
    task_strings(role_tasks(root, file)).select do |value|
      jinja_expression_regions(value).any? { |region| region.include?("{%") }
    end
  end
  failures << "no Seafile Jinja expression may contain a raw tag, which Jinja will not process" unless
    raw_inside_expression.empty?

  # THE GENERAL LESSON, pinned so the next classifier cannot repeat it. A read
  # that finds containers and cannot parse one of them is a broken read, not a
  # stopped stack, and every way of being broken -- a format that did not render,
  # a label Compose stopped setting, a Docker whose output shape moved -- makes
  # this whole file a no-op that reports success. It has to fail instead.
  census_guard = backup.find do |task|
    Array(task.dig("ansible.builtin.assert", "that")).any? do |condition|
      condition.to_s.include?("seafile_stack_containers.stdout_lines") &&
        condition.to_s.include?("seafile_stateful_deployed")
    end
  end
  failures << "a Seafile stack census that parsed nothing must fail rather than read as stopped" unless
    census_guard
  # A forced backup is an explicit request, so a request that cannot be honoured
  # is a failure rather than a debug line. `stack-not-running` still outranks
  # `forced` -- no flag can dump a database that is not up -- and what is refused
  # is the silence, which is what made #492 cost a whole lane run to find.
  force_guard = backup.find do |task|
    Array(task["when"]).any? { |value| value.to_s.include?("seafile_pre_upgrade_backup_force") } &&
      Array(task.dig("ansible.builtin.assert", "that")).any? do |condition|
        condition.to_s.include?("stack-not-running")
      end
  end
  failures << "a forced Seafile backup with no stack to dump must fail rather than report itself away" unless
    force_guard
end

unless failures.empty?
  # Every violation, one per line, each line naming the contract that authored
  # it. The prefix is not decoration: tests/seafile_contract_test.rb requires a
  # row that says "this must be refused" to see it, so a Ruby backtrace or a
  # shell diagnostic can no longer stand in for a refusal (#352).
  warn failures.map { |failure| "Seafile contract failed: #{failure}" }.join("\n")
  exit 1
end
