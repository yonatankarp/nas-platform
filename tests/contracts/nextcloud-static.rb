#!/usr/bin/env ruby
# The static half of the Nextcloud service contract: what a gated four-container
# document store owes this platform, decided from the repository alone with
# nothing deployed.
#
# usage: nextcloud-static.rb REPOSITORY
#
# PLATFORM_CONTRACT_REPO_DIR names the same repository and is read below for
# tests/policy_support.rb, so this program carries no copy of flatten_tasks.
#
# Structure is read from parsed YAML rather than from source text throughout,
# for the reason the Seafile contract records: roles/nextcloud's comments spell
# out `NC_trusted_domains`, `oc_admin` and `/var/lib/postgresql/data` while
# explaining why the tasks beside them use none of those, so a source-text
# assertion for "this must not name oc_admin" fails against the correct role.
#
# WHAT THIS FILE DOES NOT COVER, stated because the absence is a decision.
# roles/nextcloud has no pre-upgrade backup and no wedged-boot recovery, so
# roughly a third of tests/contracts/seafile-static.rb has no counterpart here.
# The backup is #500's own later phase. The recovery is a considered absence:
# Seafile needs one because enterpoint.sh launches start.py and then idles, so a
# failed setup leaves a container running for ever, while Nextcloud's entrypoint
# runs install and upgrade in the foreground and then execs apache -- a failure
# exits PID 1, which `restart: unless-stopped` and Compose already report.
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
  inventory/group_vars/all/main.yml
]
required.each do |relative|
  failures << "missing #{relative}" unless File.file?(File.join(root, relative))
end

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
# repo:tag@sha256:<64 hex>. Both halves, because the tag is what a human and
# Renovate read and the digest is what makes the deployment reproducible.
IMAGE_PIN = %r{\A[a-z0-9][a-z0-9._/-]*:[A-Za-z0-9_][A-Za-z0-9_.-]*@sha256:[0-9a-f]{64}\z}

def role_tasks(root, file)
  flatten_tasks(
    YAML.safe_load_file(File.join(root, "roles/nextcloud/tasks/#{file}.yml"), aliases: true)
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

# "300s" -> 300. Compose accepts a bare integer as seconds too, which is why this
# is not a bare to_i on a string that might have no suffix.
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

  # The application and its cron sidecar are ONE image, spelled twice. They share
  # /var/www/html, and the entrypoint rsyncs its PHP tree into that volume on
  # every version bump, so a Renovate bump that landed on one and not the other
  # would leave the cron container executing a tree the application had already
  # replaced. Byte-identical rather than merely both-pinned: same tag, same
  # digest.
  failures << "the Nextcloud application and its cron sidecar must pin one identical image" unless
    application["image"].to_s == cron["image"].to_s && !application["image"].to_s.empty?

  expected = YAML.safe_load_file(File.join(root, "tests/expected/nextcloud.yml"))
  declared_cpus = expected.fetch("container_cpus")
  # Deliberately no assertion about what the four ceilings add up to. The
  # ceilings are a per-container limit on one shared cpuset rather than
  # reservations carved out of it, so they oversubscribe that set on purpose;
  # tests/policy_test.rb records that model at length and enforces the rule that
  # does mean something -- no single ceiling wider than the set -- against
  # platform_container_cpu_budget.
  failures << "each Nextcloud container must take the CPU ceiling tests/expected/nextcloud.yml declares" unless
    services.transform_values { |service| service["cpus"] } == declared_cpus

  base_names = {
    "nextcloud" => "nextcloud", "cron" => "nextcloud-cron",
    "db" => "nextcloud-db", "cache" => "nextcloud-cache"
  }
  failures << "each Nextcloud container must carry its production name" unless
    services.transform_values { |service| service["container_name"] } == base_names
  # Sandbox cleanup finds these containers by the namespaced prefix, so the two
  # disposable overrides have to spell all four names identically. A name in one
  # override and not the other leaves a container nothing tears down.
  namespaced = base_names.transform_values { |name| "${PLATFORM_PROJECT_NAME:?}-#{name}" }
  overrides = %w[mac integration].to_h do |kind|
    document = YAML.safe_load_file(File.join(root, "services/nextcloud/compose.#{kind}.yml"))
    [kind, document.fetch("services").transform_values { |service| service["container_name"] }]
  end
  failures << "both disposable Nextcloud overrides must name the same four sandbox containers" unless
    overrides.values.all? { |names| names == namespaced }

  # apache serves everything on one port; the database and the cache join the
  # stack's own network and the cron sidecar serves nothing at all. A published
  # port on any of those three is an unauthenticated database, cache or second
  # PHP tree on the LAN.
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

  # The cron sidecar runs `php -f cron.php` out of the volume the application
  # installs into, so it must mount the SAME source at the SAME target. Upstream
  # says so in its own example compose file and the failure mode is quiet: a
  # cron container with its own copy runs background jobs against a tree nothing
  # upgrades.
  application_html = Array(application["volumes"]).find { |volume| volume.to_s.end_with?(":/var/www/html") }
  failures << "the Nextcloud cron sidecar must mount the application's own installation" unless
    application_html && Array(cron["volumes"]) == [application_html]
  # /cron.sh replaces /entrypoint.sh, which is what keeps the sidecar out of the
  # install and upgrade logic entirely: the entrypoint's main block is gated on
  # its first argument being apache or php-fpm, so a cron container started
  # through it would be a second writer racing the first.
  failures << "the Nextcloud cron sidecar must bypass the installing entrypoint" unless
    cron["entrypoint"].to_s == "/cron.sh"

  # postgres:18 declares PGDATA=/var/lib/postgresql/18/docker and a volume at
  # /var/lib/postgresql, so the bind mount belongs at the parent. Mounting
  # /var/lib/postgresql/data instead -- which is correct for 17 and earlier, and
  # is what services/immich/compose.yml still does on its pinned 14 -- puts the
  # cluster somewhere the bind mount does not reach, so the data survives in the
  # container layer and vanishes with it. A data-loss shape rather than a
  # preference, which is why it is asserted rather than left to review.
  # Split on ":/" rather than on ":", because the source half is a ${VAR:?}
  # reference and carries a colon of its own.
  database_targets = Array(database["volumes"]).map do |volume|
    "/#{volume.to_s.split(':/', 2).last}"
  end
  failures << "the Nextcloud cluster must be bound where postgres:18 puts it" unless
    database_targets == ["/var/lib/postgresql"]

  failures << "the Nextcloud application must wait for a healthy database and cache" unless
    application.dig("depends_on", "db", "condition") == "service_healthy" &&
    application.dig("depends_on", "cache", "condition") == "service_healthy"
  # The sidecar waits on the application rather than on the database, because
  # what it needs is the installed tree and not merely a reachable cluster.
  failures << "the Nextcloud cron sidecar must wait for an installed application" unless
    cron.dig("depends_on", "nextcloud", "condition") == "service_healthy"

  # --- THE ONE THAT CANNOT BE FIXED LATER -----------------------------------
  #
  # Nextcloud's installer does not use the database account it is given. If the
  # supplied user can create roles -- and docker.io/library/postgres always grants
  # POSTGRES_USER SUPERUSER, so it always can -- lib/private/Setup/PostgreSQL.php
  # replaces it: it sets dbUser to `oc_admin`, generates a password of its own and
  # writes both into config.php. The vault's database account is then a thing
  # nothing uses and the real one is a secret the vault has never seen.
  #
  # setup_create_db_user false is what refuses that, and it is consumed on the
  # FIRST converge only -- the entrypoint's install block runs while
  # installed_version is 0.0.0.0 and never again. So this is not a setting that
  # can be added later to repair a stack: adding it after the fact changes
  # nothing, and the recovery is manual (occ config:system:set dbuser/dbpassword,
  # then dropping the stray role). The string "false" rather than the boolean is
  # deliberate and upstream's own AbstractDatabase::initialize accepts it,
  # "since setting config values from env will result in a string".
  application_environment = application.fetch("environment")
  failures << "Nextcloud must refuse to mint a database account the vault does not know" unless
    application_environment["NC_setup_create_db_user"].to_s == "false"
  # The NC_ prefix overrides any system config on read and is never written to
  # disk, so these four are what keep config.php advisory and the vault
  # authoritative -- and what makes a rotated database credential an ordinary
  # converge rather than an occ repair. POSTGRES_* beside them are install-only.
  %w[NC_dbhost NC_dbname NC_dbuser NC_dbpassword].each do |name|
    failures << "Nextcloud must push #{name} so the vault outranks config.php" unless
      application_environment.key?(name)
  end
  # NC_trusted_domains is the one system setting this mechanism cannot carry, and
  # it fails closed rather than quietly: trusted_domains is an array, an NC_
  # override arrives as a string, and Nextcloud then answers HTTP 400 to every
  # request -- /status.php included, and for Host: 127.0.0.1 as much as for
  # anything else. roles/nextcloud reconciles the list with occ for that reason.
  failures << "Nextcloud must not push an array-valued system setting through NC_" if
    application_environment.key?("NC_trusted_domains")

  database_environment = database.fetch("environment")
  failures << "the Nextcloud cluster must declare the vault's own database and owner" unless
    database_environment["POSTGRES_DB"].to_s.include?("NEXTCLOUD_DB_NAME") &&
    database_environment["POSTGRES_USER"].to_s.include?("NEXTCLOUD_DB_USERNAME")
  # pg_isready against the stack's own role and database rather than the image
  # defaults: a probe that asks about `postgres`@`postgres` reports healthy on a
  # cluster where the account Nextcloud actually connects as does not exist.
  probe = Array(database.dig("healthcheck", "test")).join(" ")
  failures << "the Nextcloud database probe must name the role and database the stack uses" unless
    probe.include?("pg_isready") && probe.include?("POSTGRES_USER") && probe.include?("POSTGRES_DB")

  # --- the health budgets, as arithmetic ------------------------------------
  #
  # Compose's --wait fails a converge the moment a container is unhealthy, so
  # each wait must outlast the worst case its own probe can take to give a first
  # verdict: start_period plus retries times interval. A wait shorter than that
  # fails a boot that was merely slow, and on this stack the application's first
  # boot has never been measured on CI hardware -- which is exactly why the
  # relationship is asserted rather than the numbers.
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
  # Static imports throughout, and it is load-bearing twice over: verify.yml is
  # reachable from verify.yml's `tags: [never]` only through a static import, and
  # tests/policy_mutation_support.rb derives the fixture paths it copies by
  # following imports, so a dynamic include would put a task file outside the
  # sandbox and crash every check that reads it.
  failures << "every Nextcloud stage must be statically imported" unless
    role_tasks(root, "main").all? { |task| task.key?("ansible.builtin.import_tasks") }
  # Both reconciliations run against a server the deployment brought up, so both
  # must sit after it. Compared by index rather than grepped.
  failures << "both Nextcloud reconciliations must run after the deployment" unless
    imports.index("reconcile_trusted_domains.yml").to_i > imports.index("deploy.yml").to_i &&
    imports.index("reconcile_admin.yml").to_i > imports.index("deploy.yml").to_i
  # The trusted domain repair before the administrator probe, and the ordering is
  # the whole of whether the probe means anything: the probe is an HTTP request
  # to this server, and a Host header the server does not trust answers 400 --
  # which the classifier reads as `unavailable`, not as `rotated`. So an
  # administrator reconciliation placed first would silently decline to repair a
  # rotated password on exactly the stack that needed it.
  failures << "the Nextcloud trusted domains must be repaired before the administrator is probed" unless
    imports.index("reconcile_admin.yml").to_i > imports.index("reconcile_trusted_domains.yml").to_i
  # The app policy after the administrator probe and before the report. Disabling
  # an app dispatches AppDisableEvent and clears the application cache, so it
  # perturbs request handling -- and reconcile_admin.yml's classifier reads
  # anything that is neither 200 nor 401 as `unavailable` rather than `rotated`,
  # so a policy stage placed first could make a rotated password look like an
  # unreachable server. Before the report because an app this platform switched
  # back off is a change the deployment report has to carry.
  failures << "the Nextcloud application policy must run after the administrator probe and before the report" unless
    imports.index("reconcile_apps.yml").to_i > imports.index("reconcile_admin.yml").to_i &&
    imports.index("reconcile_apps.yml").to_i < imports.index("report.yml").to_i

  deploy = role_tasks(root, "deploy")
  compose_tasks = deploy.select { |task| task.key?("community.docker.docker_compose_v2") }
  teardown = compose_tasks.select do |task|
    task.dig("community.docker.docker_compose_v2", "state") == "absent"
  end
  # Switched off means removed, not merely left alone: flipping the flag back has
  # to undo the deployment rather than leave four containers nothing claims.
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
  #
  # THE RULE THAT CI TAUGHT THIS ROLE, and it is asserted rather than reviewed
  # because it already failed once. Every task reading or writing the running
  # stack must be gated on BOTH the operator switch and check mode: on the switch
  # because smoke and idempotence-check converge every role with this stack off,
  # and on check mode because a --check run starts nothing. The verify assert
  # shipped without either and reported an absent Nextcloud as a broken one, in
  # two lanes, on a stack that was correctly switched off.
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

  # occ is the application's own CLI and it writes into the volume, so it runs as
  # the account that owns that tree. As root it writes root-owned files into
  # /var/www/html and the next request cannot read them.
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
  # Appended at an index past the end of the live list rather than written at a
  # fixed one. `occ config:system:set trusted_domains N` replaces index N, so a
  # constant there would overwrite an entry the server already trusts -- and the
  # entry it would overwrite first is the one the installer put at 0.
  failures << "the Nextcloud trusted domain repair must append rather than overwrite" unless
    repair &&
    Array(repair.dig("community.docker.docker_compose_v2_exec", "argv")).join(" ")
      .include?("nextcloud_trusted_domains_live | length + index") &&
    repair["loop"].to_s.include?("nextcloud_trusted_domains_missing")
  # 127.0.0.1 is what this role's own verification polls and localhost is what
  # the container's health check requests, so a list without them fails the
  # converge that wrote it.
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
  # Both exec tasks state failed_when, and neither is decoration.
  # docker_compose_v2_exec sets check_rc only when `detach` is true, so without
  # it the module reports success on any exit code: a census that failed would
  # read as an empty app set and report a converged deployment, and a name in
  # the list that can never be disabled would exit 2 on every poller tick behind
  # a clean recap.
  failures << "the Nextcloud application census must refuse a nonzero exit rather than read it as an empty set" unless
    census && census["failed_when"].to_s.include?("rc")
  failures << "the Nextcloud application disable must refuse a nonzero exit rather than report a change it did not make" unless
    disable && disable["failed_when"].to_s.include?("rc")
  # The loop runs over the intersection with the live census, not over the
  # declared list, which is what makes a converged deployment skip it entirely
  # and report no change.
  failures << "the Nextcloud application disable must loop over what is still enabled rather than over the declared list" unless
    disable && disable["loop"].to_s.include?("nextcloud_apps_still_enabled")
  # THE OTHER END OF THAT LOOP, and it was pinned by nothing until this line.
  # The loop reads `nextcloud_apps_still_enabled | default([])`, so a stage that
  # binds the name nowhere loops zero times for ever: eight apps stay enabled
  # behind a clean recap, and the `| default([])` that makes the stage inert
  # when the operator switch is off is the same expression that makes that
  # silent. Deleting the set_fact outright was planted and every other property
  # in this program still held.
  binder = apps.find do |task|
    task["ansible.builtin.set_fact"].is_a?(Hash) &&
      task["ansible.builtin.set_fact"].key?("nextcloud_apps_still_enabled")
  end
  failures << "the Nextcloud application policy must bind the set its disable loop reads" unless binder
  # What that name is bound TO, asserted separately from whether it is bound at
  # all so that each break is caught by its own line rather than by the other.
  # Two halves, both of them a defect that went undetected here. The list must be
  # the EFFECTIVE one: reading `nextcloud_disabled_apps` orphans the
  # nextcloud_additional_disabled_apps escape hatch while defaults/main.yml, the
  # argument_specs and the check-mode debug all still describe it as live, and
  # the plain name is a prefix of the effective one, so this has to match the
  # longer spelling to tell them apart. And it must be intersected with the
  # census this stage just read, which is the whole of why a converged
  # deployment skips the loop instead of reporting a change it did not make.
  if binder
    bound = binder.fetch("ansible.builtin.set_fact").fetch("nextcloud_apps_still_enabled").to_s
    intersected = bound.include?("nextcloud_disabled_apps_effective") &&
                  bound.include?("intersect") && bound.include?("nextcloud_app_census")
    failures << "the Nextcloud applications still to disable must be the effective list intersected with the live census" unless intersected
  end
  # `occ app:disable` exits 0 on an app that is already off and prints "No such
  # app enabled", so a task without this line reports a change it did not make
  # and the platform's idempotence check catches it a lane later rather than
  # this contract catching it here. Negative on purpose, and the role says why:
  # the success line embeds the app's version, which every image bump moves.
  failures << "the Nextcloud application disable must not report a change on an app that was already off" unless
    disable && disable["changed_when"].to_s.include?("No such app enabled")
  # The one entry #500's own scope derives rather than chooses: "Photos,
  # documents and media are already covered by Immich, Paperless and
  # Jellyfin/Audiobookshelf/Komga". Immich is this platform's photo service.
  failures << "the Nextcloud application policy must disable the photo app Immich already serves" unless
    Array(defaults["nextcloud_disabled_apps"]).include?("photos")
  # The other two entries defaults/main.yml marks as principle rather than as
  # taste, pinned here because that file says the taxonomy exists so a later
  # reader overruling taste "should not have to re-derive the three that are not
  # taste" -- and a distinction that pins one of the three and leaves the other
  # two droppable behind a green gate is decorative. The principle is
  # roles/immich/defaults/main.yml's, stated there as "The NAS is not permitted
  # to phone home for release announcements": updatenotification fetches release
  # announcements this deployment cannot act on in band, since the digest pin is
  # its only upgrade path, and survey_client is the stricter case because it
  # sends rather than fetches.
  #
  # THE FIVE MARKED JUDGEMENT ARE DELIBERATELY LEFT UNPINNED. Taste is exactly
  # what a later reader is entitled to overrule with an argument in the file
  # rather than an edit in this program, and pinning it here would move the
  # argument out of the file that makes it.
  phoning_home = %w[updatenotification survey_client]
  failures << "the Nextcloud application policy must disable the two applications that phone home" unless
    (phoning_home - Array(defaults["nextcloud_disabled_apps"])).empty?
  # An off-set, and `text` is the app a later prune would most plausibly reach
  # for -- it is collaborative editing, which is one of the three features #500
  # names as the reason to adopt Nextcloud at all.
  failures << "the Nextcloud application policy must not disable the collaborative editor it was adopted for" if
    Array(defaults["nextcloud_disabled_apps"]).include?("text")

  # --- the administrator credential -----------------------------------------

  admin = role_tasks(root, "reconcile_admin")
  reset = admin.find do |task|
    Array(task.dig("community.docker.docker_compose_v2_exec", "argv"))
      .map(&:to_s).any? { |value| value.include?("user:resetpassword") }
  end
  # The one credential with no environment path at all: the administrator
  # password is a row in oc_users, not a system setting, and NEXTCLOUD_ADMIN_PASSWORD
  # is read only while the installation is incomplete. occ is the only way to
  # rotate it, and --password-from-env is the only spelling that keeps the value
  # off the process table where `ps` would print it.
  failures << "the rotated Nextcloud administrator must be reset through the environment" unless
    reset &&
    Array(reset.dig("community.docker.docker_compose_v2_exec", "argv")).join(" ")
      .include?("--password-from-env")
  # Repaired only on a literal 401. occ user:resetpassword always succeeds and
  # always re-hashes, which invalidates every session the account holds, so an
  # unconditional reset would log every client out on every five-minute poller
  # tick. The probe is what makes the repair conditional, and `unavailable` --
  # anything that is neither 200 nor 401 -- must not trigger it either.
  failures << "the Nextcloud administrator must be repaired only when the server refuses the vault" unless
    reset && Array(reset["when"]).any? { |value| value.to_s.include?("== 'rotated'") }

  # --- the deployment report ------------------------------------------------
  #
  # DERIVED RATHER THAN LISTED, which is the whole of why this pair is here. The
  # report's changed-expression named six results and all six were right, and
  # deleting any one of its terms failed nothing in this program: a repair that
  # stopped being announced would have converged silently for ever. Two of the
  # six -- the trusted-domain repair and the administrator repair -- had been
  # unguarded since they were written.
  #
  # The rule the six satisfy is stated instead of copied, so a stage added later
  # is carried into the report by the same sentence that carries these: every
  # result this role registers whose task does not declare `changed_when: false`.
  # That discriminator is not a proxy for the property -- it IS the property.
  # A task that declares `changed_when: false` is one this repository has already
  # said cannot move anything, and there are four of them here: the app census,
  # the administrator probe, the live trusted-domain read and the verification
  # poll. Everything else this role registers can come back changed, and a
  # changed result the report does not read is a converge that moved something
  # and said nothing.
  named = role_tasks(root, "report")
          .filter_map { |task| task.dig("vars", "ntfy_deployment_report_changed") }
          .join(" ").scan(/\bnextcloud_[a-z0-9_]+\b/).uniq
  movers = ROLE_TASK_FILES.flat_map { |file| role_tasks(root, file) }
                          .select { |task| task["register"] && task["changed_when"].to_s != "false" }
                          .map { |task| task["register"].to_s }.uniq
  # Tokenised, not matched with include?, and that is not fastidiousness:
  # `nextcloud_deploy` is a substring of `nextcloud_deployment_enabled`, which
  # this role's every gated task spells, so a membership test over the raw
  # expression would read the operator switch as the register and accept a
  # report that names neither. `\b` at both ends is what tells the two apart,
  # and it keeps `nextcloud_data_deploy` one token rather than two.
  #
  # Both directions, one line each, because they are two different defects and a
  # single set comparison would report whichever fired first. A term dropped is
  # a change that stops being announced; a term kept for a register nobody
  # writes any more is not an error but a permanent false, since
  # `(gone | default({})) is changed` evaluates quite happily.
  failures << "the Nextcloud deployment report must name every result that can report a change" unless
    (movers - named).empty?
  failures << "the Nextcloud deployment report must not name a result this role no longer registers" unless
    (named - movers).empty?

  # --- verification ---------------------------------------------------------

  verify = role_tasks(root, "verify")
  verification = verify.select { |task| Array(task["tags"]).include?("platform_verify_nextcloud") }
  status = verification.find { |task| task.dig("ansible.builtin.uri", "url").to_s.include?("/status.php") }
  # /status.php cannot answer without the database. It is not a static file: it
  # requires lib/base.php, and OC::init boots the server, which builds the
  # memcache factory, which calls AppConfig#getAppInstalledVersions -- a query.
  # With the cluster gone apache is up and this returns HTTP 500 with a zero-byte
  # body, which is why a port check passes where this fails.
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
  # The occ reset reads the administrator password out of the rendered
  # environment rather than out of a vault_ name, so the rule above cannot see
  # it: it is redacted for what it carries, not for what it spells.
  failures << "the Nextcloud administrator repair carries a credential and must be redacted" unless
    reset && reset["no_log"] == true

  failures << "Nextcloud must keep its installation and cluster roots under the Docker root" unless
    defaults["nextcloud_data_host_path"] == "{{ nas_docker_root }}/nextcloud/data" &&
    defaults["nextcloud_postgres_host_path"] == "{{ nas_docker_root }}/nextcloud/postgres"
  # Declared bool rather than left to a truthy string: the teardown branch and
  # the deploy branch are selected by this one value, and the string "false" is
  # true in Jinja.
  options = YAML.safe_load_file(File.join(root, "roles/nextcloud/meta/argument_specs.yml"))
                .dig("argument_specs", "main", "options")
  failures << "every Nextcloud vault credential must be a required role argument" unless
    VAULT_CREDENTIALS.all? do |name|
      options.dig(name, "required") == true && options.dig(name, "type") == "str"
    end
  failures << "the Nextcloud operator switch must be a required declared boolean" unless
    options.dig("nextcloud_deployment_enabled", "type") == "bool" &&
    options.dig("nextcloud_deployment_enabled", "required") == true

  # The wrapper beside this program is read out of the INSPECTED tree, like
  # tests/policy_support.rb above and for the same reason: it is that tree's own
  # contract default that has to agree with that tree's own role default.
  wrapper = File.read(File.join(root, "tests/contracts/nextcloud.sh"))
  wrapper_port = wrapper[/PLATFORM_NEXTCLOUD_PORT:=(\d+)/, 1]
  failures << "the Nextcloud contract's default port must be the port the role publishes" unless
    wrapper_port && Integer(wrapper_port, 10) == defaults["nextcloud_port"] &&
    Array(application["ports"]) == ["#{defaults['nextcloud_port']}:80"]

  # Compose interpolates $ in an env file and silently truncates what follows. A
  # cut database password produces a server that cannot reach its database and a
  # cut admin password an account nobody can log into, and neither says so.
  template = File.read(File.join(root, "roles/nextcloud/templates/env.j2"))
  interpolations = template.scan(/\{\{[^}]*vault_nextcloud_[^}]*\}\}/)
  failures << "every Nextcloud credential must survive Compose's own interpolation" unless
    interpolations.length == VAULT_CREDENTIALS.length &&
    interpolations.all? { |value| value.include?("replace('$', '$$')") }

  # Files on disk ARE the files here, which is the single biggest reason #500
  # prefers this stack to the one beside it: the tree can be read with ls and cp
  # whatever state the cluster is in. Both roots are still critical -- the tree
  # is the user's documents and the cluster is the account, sharing and
  # versioning state that says what those documents mean -- but neither depends
  # on the other to be readable, which is what Seafile's block store cannot say.
  inventory = YAML.safe_load_file(File.join(root, "inventory/group_vars/all/main.yml"))
  declarations = Array(inventory["nas_storage"]).select do |entry|
    entry.is_a?(Hash) && entry["path"].to_s.include?("/nextcloud/")
  end
  failures << "every Nextcloud storage root must be declared irreplaceable" unless
    declarations.length == 2 && declarations.all? { |entry| entry["recovery"] == "critical" }

  failures << "the Nextcloud restart must be a task rather than a deferred handler" if
    Dir.exist?(File.join(root, "roles/nextcloud/handlers"))

  # --- Go templates, and the trap #492 fell into ----------------------------
  #
  # `{% raw %}` is a Jinja TAG, and a tag is only a tag in template context. Put
  # one inside a `{{ }}` expression and Jinja is lexing a string, so the tag is
  # characters: the expression renders with `{% raw %}` still in it and
  # `docker inspect --format` prints that wrapper around every value. In
  # roles/seafile that made a backup classifier report `stack-not-running`
  # against a serving stack, silently, on every converge.
  #
  # THIS GUARD HAS NO SUBJECT IN roles/nextcloud TODAY, and that is worth stating
  # plainly rather than letting a green check imply otherwise: this role writes
  # no Go template, no `--format` and no `docker inspect` at all, so there is no
  # defect here for it to catch and no mutation that could prove it bites. It is
  # carried because the class is cheap to close before the first `--format`
  # arrives, not because it is currently doing work.
  #
  # The option this makes live, recorded rather than taken: roles/seafile and
  # roles/nextcloud are now two roles carrying the same scanner, and a third
  # would be the moment to promote the class to tests/policy_test.rb and sweep
  # every role once instead of copying it again.
  raw_inside_expression = ROLE_TASK_FILES.flat_map do |file|
    task_strings(role_tasks(root, file)).select do |value|
      jinja_expression_regions(value).any? { |region| region.include?("{%") }
    end
  end
  failures << "no Nextcloud Jinja expression may contain a raw tag, which Jinja will not process" unless
    raw_inside_expression.empty?

  # --- Python escape sequences, and the trap #500 fell into -----------------
  #
  # A backslash escape inside a `{{ }}` expression is never an escape under
  # Ansible. AnsibleLexer pre-escapes every backslash in an expression's string
  # constants before Jinja's own lexer can run its unicode_escape pass over
  # them, so YAML is the only layer that processes a backslash and
  # regex_replace('^(.*)_x$', '\1') means a backreference here rather than the
  # byte \x01 it would mean under Jinja alone. The price is that '\n' inside an
  # expression stays two characters, and a split on it finds no separator.
  #
  # UNLIKE THE RAW-TAG GUARD ABOVE, THIS ONE HAD A SUBJECT. Until the commit
  # that added it, roles/nextcloud/tasks/reconcile_trusted_domains.yml split
  # occ's output on '\n': the live trusted_domains array read as one blob, every
  # managed domain read as missing, and the repair loop re-set all three on
  # every converge. CI found it -- the nextcloud lane's second converge reported
  # changed=1 -- and no check in this repository would have. It is the same
  # shape as #492: an expression that is silently wrong rather than an error,
  # producing a clean PLAY RECAP and a wrong answer.
  #
  # Scoped to `{{ }}` regions rather than to every string this role writes,
  # because the pre-escaping is scoped that way too: AnsibleLexer exempts `{% %}`
  # statements, and a folded `{% set p = raw.split('\n') %}` really does split on
  # a newline while the `{{ }}` beside it does not. Measured on ansible-core
  # 2.21.4, along with the fact that the YAML quoting does not decide it: folded,
  # single-quoted and double-quoted scalars all read one element.
  #
  # Restricted to the whitespace escapes \n, \t and \r rather than to every
  # backslash -- which is why the message says whitespace and not backslash,
  # since Ansible processes none of them and this refuses only the three.
  # Banning every backslash would ban the backreference the pre-escaping exists
  # to make work. WHAT THAT LEAVES UNCOVERED, stated rather than discovered later: an
  # escape handed to a regex filter is processed by Python's own re module, so
  # regex_replace('\t', ' ') is correct and this guard would refuse it. No task
  # here does that; the exemption belongs on this assertion when one arrives.
  #
  # The option this makes live, recorded rather than taken: this is the second
  # scanner in this file reading the same regions, and a second ROLE needing
  # either of them is the moment to promote the class to tests/policy_test.rb
  # and sweep every role once instead of copying it a third time -- the same
  # choice tests/contracts/seafile-static.rb records for the raw-tag half.
  python_escape_in_expression = ROLE_TASK_FILES.flat_map do |file|
    task_strings(role_tasks(root, file)).select do |value|
      jinja_expression_regions(value).any? { |region| region.match?(/\\[ntr]/) }
    end
  end
  failures << "no Nextcloud Jinja expression may contain a whitespace backslash escape, which Ansible will not process" unless
    python_escape_in_expression.empty?

  # A bare `docker inspect` prints .Config.Env, which for this stack is the
  # rendered environment file: the PostgreSQL password, the Nextcloud
  # administrator password and the Valkey password in full. Every inspection this
  # role performs must narrow its output with --format. Vacuous today -- the role
  # inspects nothing -- and it stops being vacuous the moment one is added, which
  # is the only time it matters.
  unformatted_inspects = everything.select do |task|
    argv = Array(task.dig("ansible.builtin.command", "argv")).map(&:to_s)
    argv.include?("inspect") && !argv.include?("--format")
  end
  failures << "Nextcloud diagnostics must narrow every inspection rather than print the container environment" unless
    unformatted_inspects.empty?
end

unless failures.empty?
  # Every violation, one per line, each line naming the contract that authored
  # it. The prefix is not decoration: tests/nextcloud_contract_test.rb requires a
  # row that says "this must be refused" to see it, so a Ruby backtrace or a
  # shell diagnostic can no longer stand in for a refusal (#352).
  warn failures.map { |failure| "Nextcloud contract failed: #{failure}" }.join("\n")
  exit 1
end
