#!/usr/bin/env ruby
# Static half of the Nextcloud service contract, decided from the repository alone.
# usage: nextcloud-static.rb REPOSITORY
# Reads parsed YAML, not source text: the role's comments name what its tasks avoid.
require "yaml"

root = ARGV.fetch(0)
failures = []
required = %w[
  roles/nextcloud/defaults/main.yml
  roles/nextcloud/meta/argument_specs.yml
  roles/nextcloud/tasks/main.yml
  roles/nextcloud/tasks/storage.yml
  roles/nextcloud/tasks/deploy.yml
  roles/nextcloud/tasks/reconcile_trusted_domains.yml
  roles/nextcloud/tasks/reconcile_admin.yml
  roles/nextcloud/tasks/reconcile_apps.yml
  roles/nextcloud/tasks/report.yml
  roles/nextcloud/tasks/verify.yml
  roles/nextcloud/templates/env.j2
  services/nextcloud/compose.yml
  services/nextcloud/compose.mac.yml
  services/nextcloud/compose.integration.yml
  tests/expected/nextcloud.yml
  tests/contracts/nextcloud.sh
  inventory/group_vars/all/service_nextcloud.yml
]
required.each do |relative|
  failures << "missing #{relative}" unless File.file?(File.join(root, relative))
end

require File.join(ENV.fetch("PLATFORM_CONTRACT_REPO_DIR"), "tests", "nas_storage_support")
require File.join(ENV.fetch("PLATFORM_CONTRACT_REPO_DIR"), "tests", "policy_support")
include PolicySupport

ROLE_TASK_FILES = %w[
  main storage deploy reconcile_trusted_domains reconcile_admin reconcile_apps report verify
].freeze
VAULT_CREDENTIALS = %w[
  vault_nextcloud_admin_password
  vault_nextcloud_admin_username
  vault_nextcloud_cache_password
  vault_nextcloud_db_name
  vault_nextcloud_db_password
  vault_nextcloud_db_username
].freeze
# repo:tag@sha256:<64 hex>.
IMAGE_PIN = %r{\A[a-z0-9][a-z0-9._/-]*:[A-Za-z0-9_][A-Za-z0-9_.-]*@sha256:[0-9a-f]{64}\z}

def role_tasks(root, file)
  flatten_tasks(
    YAML.safe_load_file(File.join(root, "roles/nextcloud/tasks/#{file}.yml"), aliases: true)
  )
end

# `300s` -> 300; Compose also accepts a bare integer as seconds.
def duration_seconds(value)
  text = value.to_s.strip
  return nil if text.empty?

  case text
  when /\A(\d+)s\z/ then Regexp.last_match(1).to_i
  when /\A(\d+)m\z/ then Regexp.last_match(1).to_i * 60
  when /\A(\d+)\z/ then text.to_i
  end
end

if failures.empty?
  compose = YAML.safe_load_file(File.join(root, "services/nextcloud/compose.yml"), aliases: true)
  services = compose.fetch("services")
  application = services.fetch("nextcloud")
  cron = services.fetch("cron")
  database = services.fetch("db")

  # --- the four containers --------------------------------------------------

  {
    "nextcloud" => "docker.io/library/nextcloud",
    "cron" => "docker.io/library/nextcloud",
    "db" => "docker.io/library/postgres",
    "cache" => "docker.io/valkey/valkey"
  }.each do |name, repository|
    image = services.fetch(name, {})["image"].to_s
    failures << "the Nextcloud #{name} image must pin #{repository} by tag and manifest digest" unless
      image.match?(IMAGE_PIN) && image.split(":").first == repository
  end

  # One image spelled twice: both share /var/www/html, which the entrypoint rsyncs on
  # every bump, so cron must never run a tree the application already replaced.
  failures << "the Nextcloud application and its cron sidecar must pin one identical image" unless
    application["image"].to_s == cron["image"].to_s && !application["image"].to_s.empty?

  expected = YAML.safe_load_file(File.join(root, "tests/expected/nextcloud.yml"))
  declared_cpus = expected.fetch("container_cpus")
  # No sum assertion: the ceilings share one cpuset and oversubscribe it on purpose.
  failures << "each Nextcloud container must take the CPU ceiling tests/expected/nextcloud.yml declares" unless
    services.transform_values { |service| service["cpus"] } == declared_cpus

  base_names = {
    "nextcloud" => "nextcloud", "cron" => "nextcloud-cron",
    "db" => "nextcloud-db", "cache" => "nextcloud-cache"
  }
  failures << "each Nextcloud container must carry its production name" unless
    services.transform_values { |service| service["container_name"] } == base_names
  # Sandbox cleanup finds containers by the namespaced prefix, so both overrides must match.
  namespaced = base_names.transform_values { |name| "${PLATFORM_PROJECT_NAME:?}-#{name}" }
  overrides = %w[mac integration].to_h do |kind|
    document = YAML.safe_load_file(File.join(root, "services/nextcloud/compose.#{kind}.yml"))
    [kind, document.fetch("services").transform_values { |service| service["container_name"] }]
  end
  failures << "both disposable Nextcloud overrides must name the same four sandbox containers" unless
    overrides.values.all? { |names| names == namespaced }

  # A published port on db, cache or cron is an unauthenticated service on the LAN.
  failures << "only the Nextcloud application may publish a port" unless
    services.select { |_name, service| service.key?("ports") }.keys == ["nextcloud"]

  volumes = services.values.flat_map { |service| Array(service["volumes"]) }
  volume_sources = volumes.map { |volume| volume.to_s.split(":/", 2).first }
  failures << "every Nextcloud volume source must be a required environment reference" unless
    !volume_sources.empty? &&
    volume_sources.all? { |source| source.match?(/\A\$\{[A-Z][A-Z0-9_]*:\?\}\z/) }

  failures << "every Nextcloud container must carry its Dozzle group and name" unless
    services.transform_values { |service| service["labels"] } == {
      "nextcloud" => { "dev.dozzle.group" => "nextcloud", "dev.dozzle.name" => "nextcloud" },
      "cron" => { "dev.dozzle.group" => "nextcloud", "dev.dozzle.name" => "cron" },
      "db" => { "dev.dozzle.group" => "nextcloud", "dev.dozzle.name" => "db" },
      "cache" => { "dev.dozzle.group" => "nextcloud", "dev.dozzle.name" => "cache" }
    }

  # cron runs cron.php out of the application's volume; its own copy would run jobs
  # against a tree nothing upgrades.
  application_html = Array(application["volumes"]).find { |volume| volume.to_s.end_with?(":/var/www/html") }
  failures << "the Nextcloud cron sidecar must mount the application's own installation" unless
    application_html && Array(cron["volumes"]) == [application_html]
  # /cron.sh bypasses /entrypoint.sh, which would make the sidecar a second installer.
  failures << "the Nextcloud cron sidecar must bypass the installing entrypoint" unless
    cron["entrypoint"].to_s == "/cron.sh"

  # postgres:18 puts PGDATA under /var/lib/postgresql; mounting .../data (right for <=17)
  # leaves the cluster in the container layer, lost on recreate. Split on `:/` because
  # the source is a ${VAR:?} reference with a colon of its own.
  database_targets = Array(database["volumes"]).map do |volume|
    "/#{volume.to_s.split(':/', 2).last}"
  end
  failures << "the Nextcloud cluster must be bound where postgres:18 puts it" unless
    database_targets == ["/var/lib/postgresql"]

  failures << "the Nextcloud application must wait for a healthy database and cache" unless
    application.dig("depends_on", "db", "condition") == "service_healthy" &&
    application.dig("depends_on", "cache", "condition") == "service_healthy"
  # The sidecar needs the installed tree, not merely a reachable cluster.
  failures << "the Nextcloud cron sidecar must wait for an installed application" unless
    cron.dig("depends_on", "nextcloud", "condition") == "service_healthy"

  # --- THE ONE THAT CANNOT BE FIXED LATER -----------------------------------
  # Without setup_create_db_user false the installer swaps the vault's account for a
  # generated oc_admin. It is read on the FIRST converge only; adding it later does nothing.
  application_environment = application.fetch("environment")
  failures << "Nextcloud must refuse to mint a database account the vault does not know" unless
    application_environment["NC_setup_create_db_user"].to_s == "false"
  # NC_ overrides are never written to disk, so the vault outranks config.php;
  # POSTGRES_* are install-only.
  %w[NC_dbhost NC_dbname NC_dbuser NC_dbpassword].each do |name|
    failures << "Nextcloud must push #{name} so the vault outranks config.php" unless
      application_environment.key?(name)
  end
  # trusted_domains is an array; an NC_ string override makes every request answer 400,
  # so roles/nextcloud reconciles it with occ.
  failures << "Nextcloud must not push an array-valued system setting through NC_" if
    application_environment.key?("NC_trusted_domains")

  database_environment = database.fetch("environment")
  failures << "the Nextcloud cluster must declare the vault's own database and owner" unless
    database_environment["POSTGRES_DB"].to_s.include?("NEXTCLOUD_DB_NAME") &&
    database_environment["POSTGRES_USER"].to_s.include?("NEXTCLOUD_DB_USERNAME")
  # Probe the stack's own role and db: postgres@postgres is healthy even when ours is missing.
  probe = Array(database.dig("healthcheck", "test")).join(" ")
  failures << "the Nextcloud database probe must name the role and database the stack uses" unless
    probe.include?("pg_isready") && probe.include?("POSTGRES_USER") && probe.include?("POSTGRES_DB")

  # --- the health budgets, as arithmetic ------------------------------------
  # Each --wait must outlast its probe's worst first verdict: start_period + retries * interval.
  defaults = YAML.safe_load_file(File.join(root, "roles/nextcloud/defaults/main.yml"))
  {
    "nextcloud" => "nextcloud_compose_wait_timeout",
    "db" => "nextcloud_data_compose_wait_timeout"
  }.each do |name, budget_name|
    health = services.fetch(name).fetch("healthcheck")
    worst = duration_seconds(health["start_period"]).to_i +
            (health["retries"].to_i * duration_seconds(health["interval"]).to_i)
    failures << "#{budget_name} must outlast the #{name} probe's own worst-case verdict" unless
      defaults[budget_name].to_i > worst
  end

  # --- the role -------------------------------------------------------------

  imports = role_tasks(root, "main").filter_map { |task| task["ansible.builtin.import_tasks"] }
  expected_stages = %w[
    storage.yml deploy.yml reconcile_trusted_domains.yml reconcile_admin.yml reconcile_apps.yml
    report.yml verify.yml
  ]
  failures << "the Nextcloud role must import every stage it owns" unless
    expected_stages.all? { |stage| imports.include?(stage) }
  # Static imports: verify.yml reaches tagged tasks only through them, and the mutation
  # harness follows imports to copy fixtures.
  failures << "every Nextcloud stage must be statically imported" unless
    role_tasks(root, "main").all? { |task| task.key?("ansible.builtin.import_tasks") }
  failures << "both Nextcloud reconciliations must run after the deployment" unless
    imports.index("reconcile_trusted_domains.yml").to_i > imports.index("deploy.yml").to_i &&
    imports.index("reconcile_admin.yml").to_i > imports.index("deploy.yml").to_i
  # Trusted domains first: an untrusted Host answers 400, which the admin probe reads as
  # `unavailable` and so would never repair a rotated password.
  failures << "the Nextcloud trusted domains must be repaired before the administrator is probed" unless
    imports.index("reconcile_admin.yml").to_i > imports.index("reconcile_trusted_domains.yml").to_i
  # After the admin probe (app:disable perturbs requests, masking `rotated`) and before
  # the report, which must carry the change.
  failures << "the Nextcloud application policy must run after the administrator probe and before the report" unless
    imports.index("reconcile_apps.yml").to_i > imports.index("reconcile_admin.yml").to_i &&
    imports.index("reconcile_apps.yml").to_i < imports.index("report.yml").to_i

  deploy = role_tasks(root, "deploy")
  compose_tasks = deploy.select { |task| task.key?("community.docker.docker_compose_v2") }
  teardown = compose_tasks.select do |task|
    task.dig("community.docker.docker_compose_v2", "state") == "absent"
  end
  # Switched off means removed, not left running unclaimed.
  failures << "the disabled Nextcloud project must be torn down rather than left running" unless
    teardown.length == 1 &&
    teardown.first.dig("community.docker.docker_compose_v2", "remove_orphans") == true &&
    Array(teardown.first["when"]).include?("not nextcloud_deployment_enabled | bool")
  deployments = compose_tasks.select do |task|
    task.dig("community.docker.docker_compose_v2", "state") == "present"
  end
  failures << "every Nextcloud deployment task must be gated on the operator switch" unless
    !deployments.empty? &&
    deployments.all? { |task| Array(task["when"]).include?("nextcloud_deployment_enabled | bool") }

  # --- everything that touches a container it did not start ------------------
  # Gated on the switch (most lanes converge with the stack off) and on check mode
  # (--check starts nothing).
  runtime_kinds = %w[
    community.docker.docker_compose_v2_exec ansible.builtin.uri
  ].freeze
  ungated = ROLE_TASK_FILES.flat_map { |file| role_tasks(root, file) }.select do |task|
    next false unless runtime_kinds.any? { |kind| task.key?(kind) }

    conditions = Array(task["when"]).map(&:to_s)
    !(conditions.include?("nextcloud_deployment_enabled | bool") &&
      conditions.include?("not ansible_check_mode"))
  end
  failures << "every Nextcloud task touching the running stack must be gated on the switch and check mode" unless
    ungated.empty?

  # occ as root writes root-owned files into /var/www/html the server cannot read.
  execs = ROLE_TASK_FILES.flat_map { |file| role_tasks(root, file) }.select do |task|
    task.key?("community.docker.docker_compose_v2_exec")
  end
  failures << "every Nextcloud occ invocation must run as the account that owns the installation" unless
    !execs.empty? &&
    execs.all? { |task| task.dig("community.docker.docker_compose_v2_exec", "user") == "www-data" }

  # --- the trusted domain list ----------------------------------------------

  trusted = role_tasks(root, "reconcile_trusted_domains")
  repair = trusted.find do |task|
    Array(task.dig("community.docker.docker_compose_v2_exec", "argv"))
      .map(&:to_s).include?("config:system:set")
  end
  # `config:system:set trusted_domains N` replaces index N, so append past the live end.
  failures << "the Nextcloud trusted domain repair must append rather than overwrite" unless
    repair &&
    Array(repair.dig("community.docker.docker_compose_v2_exec", "argv")).join(" ")
      .include?("nextcloud_trusted_domains_live | length + index") &&
    repair["loop"].to_s.include?("nextcloud_trusted_domains_missing")
  # 127.0.0.1 (role verification) and localhost (health check) must always be trusted.
  domains = defaults["nextcloud_trusted_domains"].to_s
  failures << "the Nextcloud trusted domains must carry the two hosts this platform itself requests" unless
    domains.include?("127.0.0.1") && domains.include?("localhost")

  # --- the application policy -----------------------------------------------

  apps = role_tasks(root, "reconcile_apps")
  census = apps.find do |task|
    Array(task.dig("community.docker.docker_compose_v2_exec", "argv"))
      .map(&:to_s).any? { |value| value.include?("app:list") }
  end
  disable = apps.find do |task|
    Array(task.dig("community.docker.docker_compose_v2_exec", "argv"))
      .map(&:to_s).any? { |value| value.include?("app:disable") }
  end
  # docker_compose_v2_exec checks rc only when detached, so failed_when is what stops a
  # failed census reading as an empty app set.
  failures << "the Nextcloud application census must refuse a nonzero exit rather than read it as an empty set" unless
    census && census["failed_when"].to_s.include?("rc")
  failures << "the Nextcloud application disable must refuse a nonzero exit rather than report a change it did not make" unless
    disable && disable["failed_when"].to_s.include?("rc")
  # Looping over the live intersection lets a converged deployment skip it with no change.
  failures << "the Nextcloud application disable must loop over what is still enabled rather than over the declared list" unless
    disable && disable["loop"].to_s.include?("nextcloud_apps_still_enabled")
  # The loop defaults to [], so with no binder it silently disables nothing.
  binder = apps.find do |task|
    task["ansible.builtin.set_fact"].is_a?(Hash) &&
      task["ansible.builtin.set_fact"].key?("nextcloud_apps_still_enabled")
  end
  failures << "the Nextcloud application policy must bind the set its disable loop reads" unless binder
  # Bound to the EFFECTIVE list (the plain name is a prefix of it and orphans the
  # additional-apps escape hatch), intersected with the live census.
  if binder
    bound = binder.fetch("ansible.builtin.set_fact").fetch("nextcloud_apps_still_enabled").to_s
    intersected = bound.include?("nextcloud_disabled_apps_effective") &&
                  bound.include?("intersect") && bound.include?("nextcloud_app_census")
    failures << "the Nextcloud applications still to disable must be the effective list intersected with the live census" unless intersected
  end
  # app:disable exits 0 with `No such app enabled` on an app already off; matched
  # negatively because the success line embeds the app's version.
  failures << "the Nextcloud application disable must not report a change on an app that was already off" unless
    disable && disable["changed_when"].to_s.include?("No such app enabled")
  # Immich is the platform's photo service (#500).
  failures << "the Nextcloud application policy must disable the photo app Immich already serves" unless
    Array(defaults["nextcloud_disabled_apps"]).include?("photos")
  # Both phone home, which this platform refuses. The other entries are taste and are
  # deliberately unpinned, so the argument stays in defaults/main.yml.
  phoning_home = %w[updatenotification survey_client]
  failures << "the Nextcloud application policy must disable the two applications that phone home" unless
    (phoning_home - Array(defaults["nextcloud_disabled_apps"])).empty?
  # `text` is collaborative editing, one of the reasons Nextcloud was adopted (#500).
  failures << "the Nextcloud application policy must not disable the collaborative editor it was adopted for" if
    Array(defaults["nextcloud_disabled_apps"]).include?("text")

  # --- the administrator credential -----------------------------------------

  admin = role_tasks(root, "reconcile_admin")
  reset = admin.find do |task|
    Array(task.dig("community.docker.docker_compose_v2_exec", "argv"))
      .map(&:to_s).any? { |value| value.include?("user:resetpassword") }
  end
  # The admin password lives in oc_users, so occ is the only way to rotate it;
  # --password-from-env keeps it off the process table.
  failures << "the rotated Nextcloud administrator must be reset through the environment" unless
    reset &&
    Array(reset.dig("community.docker.docker_compose_v2_exec", "argv")).join(" ")
      .include?("--password-from-env")
  # Reset only on a literal 401: resetpassword invalidates every session, so an
  # unconditional reset would log clients out on every poller tick.
  failures << "the Nextcloud administrator must be repaired only when the server refuses the vault" unless
    reset && Array(reset["when"]).any? { |value| value.to_s.include?("== 'rotated'") }

  # --- the deployment report ------------------------------------------------
  # Derived: every registered result whose task does not declare changed_when: false
  # must be named by the report, and nothing else may be.
  named = role_tasks(root, "report")
          .filter_map { |task| task.dig("vars", "deployment_report_changed") }
          .join(" ").scan(/\bnextcloud_[a-z0-9_]+\b/).uniq
  movers = ROLE_TASK_FILES.flat_map { |file| role_tasks(root, file) }
                          .select { |task| task["register"] && task["changed_when"].to_s != "false" }
                          .map { |task| task["register"].to_s }.uniq
  # Tokenised on word boundaries: `nextcloud_deploy` is a substring of
  # `nextcloud_deployment_enabled`. A stale term is a permanent false, hence both directions.
  failures << "the Nextcloud deployment report must name every result that can report a change" unless
    (movers - named).empty?
  failures << "the Nextcloud deployment report must not name a result this role no longer registers" unless
    (named - movers).empty?

  # --- verification ---------------------------------------------------------

  verify = role_tasks(root, "verify")
  verification = verify.select { |task| Array(task["tags"]).include?("platform_verify_nextcloud") }
  status = verification.find { |task| task.dig("ansible.builtin.uri", "url").to_s.include?("/status.php") }
  # /status.php boots the server and queries the database: HTTP 500 without it, where a
  # port check would pass.
  failures << "Nextcloud verification must read the endpoint that boots the server" unless status
  assertion = verification.find { |task| task.key?("ansible.builtin.assert") }
  conditions = Array(assertion&.dig("ansible.builtin.assert", "that")).map(&:to_s)
  failures << "Nextcloud verification must prove an installed, serving, migrated instance" unless
    conditions.any? { |value| value.include?("status") && value.include?("200") } &&
    conditions.any? { |value| value.include?("installed") } &&
    conditions.any? { |value| value.include?("maintenance") } &&
    conditions.any? { |value| value.include?("needsDbUpgrade") }

  # --- redaction, defaults and the two roots --------------------------------

  everything = ROLE_TASK_FILES.flat_map { |file| role_tasks(root, file) }
  credential_tasks = everything.select do |task|
    task_strings(task).any? { |value| value.include?("vault_nextcloud_") }
  end
  failures << "every Nextcloud task naming a vault credential must be redacted" unless
    credential_tasks.length >= 2 && credential_tasks.all? { |task| task["no_log"] == true }
  # The reset reads the password from the environment, not a vault_ name, so it is
  # checked separately.
  failures << "the Nextcloud administrator repair carries a credential and must be redacted" unless
    reset && reset["no_log"] == true

  failures << "Nextcloud must keep its installation and cluster roots under the Docker root" unless
    defaults["nextcloud_data_host_path"] == "{{ nas_docker_root }}/nextcloud/data" &&
    defaults["nextcloud_postgres_host_path"] == "{{ nas_docker_root }}/nextcloud/postgres"
  # Declared bool: the string `false` is true in Jinja.
  options = YAML.safe_load_file(File.join(root, "roles/nextcloud/meta/argument_specs.yml"))
                .dig("argument_specs", "main", "options")
  failures << "every Nextcloud vault credential must be a required role argument" unless
    VAULT_CREDENTIALS.all? do |name|
      options.dig(name, "required") == true && options.dig(name, "type") == "str"
    end
  failures << "the Nextcloud operator switch must be a required declared boolean" unless
    options.dig("nextcloud_deployment_enabled", "type") == "bool" &&
    options.dig("nextcloud_deployment_enabled", "required") == true

  # Read from the INSPECTED tree: its contract default must agree with its role default.
  wrapper = File.read(File.join(root, "tests/contracts/nextcloud.sh"))
  wrapper_port = wrapper[/PLATFORM_NEXTCLOUD_PORT:=(\d+)/, 1]
  failures << "the Nextcloud contract's default port must be the port the role publishes" unless
    wrapper_port && Integer(wrapper_port, 10) == defaults["nextcloud_port"] &&
    Array(application["ports"]) == ["#{defaults['nextcloud_port']}:80"]

  # Compose interpolates $ in an env file and silently truncates the credential.
  template = File.read(File.join(root, "roles/nextcloud/templates/env.j2"))
  interpolations = template.scan(/\{\{[^}]*vault_nextcloud_[^}]*\}\}/)
  failures << "every Nextcloud credential must survive Compose's own interpolation" unless
    interpolations.length == VAULT_CREDENTIALS.length &&
    interpolations.all? { |value| value.include?("replace('$', '$$')") }

  # Both roots are critical, and each is readable without the other.
  declarations = NasStorage.entries(root).select do |entry|
    entry.is_a?(Hash) && entry["path"].to_s.include?("/nextcloud/")
  end
  failures << "every Nextcloud storage root must be declared irreplaceable" unless
    declarations.length == 2 && declarations.all? { |entry| entry["recovery"] == "critical" }

  failures << "the Nextcloud restart must be a task rather than a deferred handler" if
    Dir.exist?(File.join(root, "roles/nextcloud/handlers"))

  # --- Go templates (#492) ---------------------------------------------------
  # `{% raw %}` inside `{{ }}` is literal text, not a tag. No subject in this role today;
  # kept until the class is promoted to tests/policy_test.rb.
  raw_inside_expression = ROLE_TASK_FILES.flat_map do |file|
    task_strings(role_tasks(root, file)).select do |value|
      jinja_expression_regions(value).any? { |region| region.include?("{%") }
    end
  end
  failures << "no Nextcloud Jinja expression may contain a raw tag, which Jinja will not process" unless
    raw_inside_expression.empty?

  # A bare `docker inspect` prints .Config.Env, i.e. every password. Vacuous today.
  unformatted_inspects = everything.select do |task|
    argv = Array(task.dig("ansible.builtin.command", "argv")).map(&:to_s)
    argv.include?("inspect") && !argv.include?("--format")
  end
  failures << "Nextcloud diagnostics must narrow every inspection rather than print the container environment" unless
    unformatted_inspects.empty?
end

unless failures.empty?
  # The prefix is required: tests/nextcloud_contract_test.rb looks for it (#352).
  warn failures.map { |failure| "Nextcloud contract failed: #{failure}" }.join("\n")
  exit 1
end
