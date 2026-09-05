#!/usr/bin/env ruby
# The static half of the Bindery service contract: the Compose definition, the
# Mac override, the role's task order, its declared inputs and its rendered
# environment, all decided from the repository alone with nothing deployed.
#
# usage: bindery-static.rb REPOSITORY
#
require "yaml"

root = ARGV.fetch(0)
failures = []
required = %w[
  roles/bindery/defaults/main.yml
  roles/bindery/meta/argument_specs.yml
  roles/bindery/tasks/main.yml
  roles/bindery/tasks/pre_upgrade_backup.yml
  roles/bindery/tasks/reconcile_usenet.yml
  roles/bindery/tasks/resolve_api_key.yml
  roles/bindery/templates/env.j2
  services/bindery/compose.yml
  services/bindery/compose.mac.yml
  services/bindery/compose.integration.yml
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

# The environment file is a line-oriented grammar, so it is read as the
# assignments it declares: a commented-out sample of the right assignment
# satisfies a substring search while the live line exports something else.
def environment_assignments(path)
  File.readlines(path, chomp: true).filter_map do |line|
    stripped = line.strip
    next unless stripped.match?(/\A[A-Z][A-Z0-9_]*=/)

    name, _separator, value = stripped.partition("=")
    [name, value]
  end
end

if failures.empty?
  compose = YAML.safe_load_file(File.join(root, "services/bindery/compose.yml"), aliases: true)
  service = compose.fetch("services").fetch("bindery")

  # Bindery is the first Phase 2 project that reaches another platform service.
  # Both of its integration writes resolve the submitted host at write time and
  # answer 400 when the lookup fails, so it has to sit on the shared control
  # network; the two existing acquisition contracts assert the absence of a
  # networks key and neither of those assertions may be copied here.
  failures << "Bindery must join the shared media control network" unless
    Array(service["networks"]) == %w[default media-control]
  failures << "the shared media control network must be the external one" unless
    compose.dig("networks", "media-control") ==
      { "external" => true, "name" => "${PLATFORM_MEDIA_NETWORK:?}" }

  # The runtime stage is distroless: no shell, no entrypoint script, no root
  # phase and no gosu, so nothing in the container can remap or chown. `user:`
  # is the only mechanism, and BINDERY_PUID/BINDERY_PGID are boot-time
  # assertions that exit 1 rather than a remap, so both have to agree with it.
  failures << "Bindery must take the platform identity as the container user" unless
    service["user"] == "${NAS_UID:?}:${NAS_GID:?}"
  {
    "BINDERY_PUID" => "${NAS_UID:?}",
    "BINDERY_PGID" => "${NAS_GID:?}"
  }.each do |name, expected|
    failures << "Bindery must assert the platform identity as #{name}" unless
      service.dig("environment", name) == expected
  end

  # One bind mount per host share, not one per leaf: each library and its own
  # staging directory have to land inside a single mount, because rename(2)
  # refuses to cross a mount boundary even when both sides are the same
  # filesystem. The container paths below are still the absolute paths SABnzbd
  # uses for the same host directories, because SABnzbd reports a finished
  # download by its own container path and Bindery reads that path off the
  # filesystem.
  failures << "Bindery must mount its database and each library's whole host share" unless
    Array(service["volumes"]) == [
      "${BINDERY_CONFIG_PATH:?}:/config",
      "${BINDERY_BOOKS_PATH:?}:/data/books",
      "${BINDERY_MEDIA_PATH:?}:/data/media"
    ]

  # Omitting either audiobook variable silently falls back to its ebook
  # equivalent and collapses the two libraries into one, which is the single
  # failure the design forbids and which no other reading would notice.
  {
    "BINDERY_LIBRARY_DIR" => "/data/books/Ebooks",
    "BINDERY_AUDIOBOOK_DIR" => "/data/media/Audiobooks",
    "BINDERY_DOWNLOAD_DIR" => "/data/books/.acquisition/usenet/ebooks",
    "BINDERY_AUDIOBOOK_DOWNLOAD_DIR" => "/data/media/.acquisition/usenet/audiobooks"
  }.each do |name, expected|
    failures << "Bindery must keep #{name} separate from its ebook equivalent" unless
      service.dig("environment", name) == expected
  end
  failures << "Bindery must disable telemetry in the environment" unless
    service.dig("environment", "BINDERY_TELEMETRY_DISABLED") == "true"
  # An over-broad trusted-proxy entry disables the per-IP login rate limiter,
  # and a URL base the platform does not serve breaks every published link.
  %w[BINDERY_TRUSTED_PROXY BINDERY_URL_BASE].each do |name|
    failures << "Bindery must leave #{name} unset" if
      service.fetch("environment", {}).key?(name)
  end

  failures << "Bindery must publish the acquisition web UI port" unless
    Array(service["ports"]) == ["8787:8787"]
  mac = YAML.safe_load_file(File.join(root, "services/bindery/compose.mac.yml"))
  failures << "the Mac override must republish the web UI on the harness port" unless
    mac.dig("services", "bindery", "ports") == ["${BINDERY_HOST_PORT:?}:8787"]

  # /bin, /sbin, /usr/bin and /usr/sbin all exist in the image and are all
  # empty; the only executable is /bindery. A CMD-SHELL probe cannot run at all,
  # and because deployment waits for health the failure surfaces as a timeout
  # that says nothing about the cause.
  probe = Array(service.dig("healthcheck", "test"))
  failures << "the Bindery health probe must be the binary's own exec-form subcommand" unless
    probe == %w[CMD /bindery healthcheck]

  defaults = YAML.safe_load_file(File.join(root, "roles/bindery/defaults/main.yml"))
  {
    "bindery_books_host_path" => "{{ nas_media_root }}/Books",
    "bindery_media_host_path" => "{{ nas_media_root }}/Media",
    "bindery_config_host_path" => "{{ nas_docker_root }}/bindery/config",
    "bindery_ebooks_root" => "/data/books/Ebooks",
    "bindery_audiobooks_root" => "/data/media/Audiobooks"
  }.each do |name, expected|
    failures << "Bindery must declare #{name} as #{expected}" unless defaults[name] == expected
  end
  failures << "Bindery must declare exactly the two destination roots" unless
    defaults["bindery_library_roots"] ==
      ["{{ bindery_ebooks_root }}", "{{ bindery_audiobooks_root }}"]
  # The auto-grab kill switch fails open: a missing row, a read error and an
  # unattached repository all read as enabled, so silence means grabbing.
  failures << "Bindery must pin the auto-grab kill switch and telemetry off" unless
    defaults["bindery_pinned_settings"] ==
      { "autoGrab.enabled" => "false", "telemetry.enabled" => "false" }
  failures << "Bindery must address Prowlarr and SABnzbd by their control-network alias" unless
    defaults["bindery_prowlarr_internal_url"] == "http://prowlarr:9696" &&
    defaults["bindery_sabnzbd_host"] == "sabnzbd"
  # One client serves both libraries only because the two categories differ;
  # SABnzbd's own category map is what lands each in its library's staging root.
  failures << "Bindery must keep the ebook and audiobook download categories distinct" unless
    defaults["bindery_sabnzbd_ebook_category"] == "ebooks" &&
    defaults["bindery_sabnzbd_audiobook_category"] == "audiobooks"
  failures << "Bindery must leave the Usenet integrations disabled by default" unless
    defaults["media_usenet_enabled"] == false

  env_assignments = environment_assignments(
    File.join(root, "roles/bindery/templates/env.j2")
  )
  failures << "Bindery env must render the CPU set exactly once" unless
    env_assignments.select { |name, _value| name == "PLATFORM_CONTAINER_CPUSET" } ==
      [["PLATFORM_CONTAINER_CPUSET", "{{ platform_effective_container_cpuset }}"]]
  # The API-key seed is the only credential Bindery reads from its environment,
  # and it is the one that closes the anonymous first-run setup window. Any
  # other would be a copy nothing consumes.
  failures << "the Bindery environment must carry exactly the API-key seed" unless
    env_assignments.select { |_name, value| value.include?("vault_") } ==
      [["BINDERY_API_KEY", "{{ vault_bindery_api_key }}"]]

  role_tasks = %w[
    roles/bindery/tasks/main.yml
    roles/bindery/tasks/pre_upgrade_backup.yml
    roles/bindery/tasks/reconcile_usenet.yml
    roles/bindery/tasks/resolve_api_key.yml
  ].flat_map do |relative|
    flatten_tasks(YAML.safe_load_file(File.join(root, relative), aliases: true))
  end
  tasks = flatten_tasks(
    YAML.safe_load_file(File.join(root, "roles/bindery/tasks/main.yml"), aliases: true)
  )

  failures << "Bindery must deploy through docker_compose_v2" unless
    tasks.count { |task| task.dig("community.docker.docker_compose_v2", "state") == "present" } == 1
  failures << "Bindery must verify its effective project CPU policy" unless
    tasks.count { |task| task.dig("vars", "container_cpu_service_name") == "bindery" } == 1

  # The state guard has to precede the deploy: Bindery applies its schema
  # migrations on startup, so by the time the new image answers the old schema
  # is already gone.
  backup_include = tasks.index do |task|
    task["ansible.builtin.include_tasks"] == "pre_upgrade_backup.yml"
  end
  deploy_index = tasks.index { |task| task.key?("community.docker.docker_compose_v2") }
  failures << "the Bindery pre-upgrade state guard must run before the deployment" unless
    backup_include && deploy_index && backup_include < deploy_index

  backup_tasks = flatten_tasks(
    YAML.safe_load_file(File.join(root, "roles/bindery/tasks/pre_upgrade_backup.yml"),
                        aliases: true)
  )
  backup_request = backup_tasks.find do |task|
    task.dig("ansible.builtin.uri", "url").to_s.end_with?("/backup")
  end
  # POST /backup is VACUUM INTO, which is the whole point: the database runs in
  # WAL mode, so a plain file copy silently omits what is still in the WAL. The
  # request accepts only 201, so a failed backup fails the play with the new
  # image still unstarted.
  failures << "the Bindery pre-upgrade backup must accept only a created backup" unless
    backup_request && backup_request.dig("ansible.builtin.uri", "method") == "POST" &&
    backup_request.dig("ansible.builtin.uri", "status_code") == [201]
  backup_conditions = Array(backup_request&.fetch("when", nil)).join(" ")
  failures << "the Bindery pre-upgrade backup must be gated on an actual image change" unless
    backup_conditions.include?("bindery_upgrade_pending") &&
    backup_conditions.include?("ansible_check_mode")

  # Nothing in Bindery is create-if-absent: a duplicate user or root folder is a
  # 500, and a duplicate Prowlarr instance or download client is a silent second
  # row. Every mutation is therefore read-then-decide.
  identity_write = tasks.find do |task|
    task.dig("ansible.builtin.uri", "url") == "{{ bindery_api }}/auth/users" &&
      task.dig("ansible.builtin.uri", "method") == "POST"
  end
  identity_conditions = Array(identity_write&.fetch("when", nil)).join(" ")
  failures << "the Bindery administrator write must be gated on the deployed users" unless
    identity_write && identity_conditions.include?("bindery_administrator_present") &&
    identity_conditions.include?("ansible_check_mode")
  failures << "the Bindery administrator must be declared as an administrator" unless
    identity_write && identity_write.dig("ansible.builtin.uri", "body", "role") == "admin"

  root_write = tasks.find do |task|
    task.dig("ansible.builtin.uri", "url") == "{{ bindery_api }}/rootfolder" &&
      task.dig("ansible.builtin.uri", "method") == "POST"
  end
  failures << "the Bindery destination roots must be created only where missing" unless
    root_write && root_write["loop"] == "{{ bindery_missing_roots }}" &&
    Array(root_write["when"]).join(" ").include?("ansible_check_mode")

  usenet_include = tasks.find do |task|
    task["ansible.builtin.include_tasks"] == "reconcile_usenet.yml"
  end
  failures << "the Bindery Usenet integrations must be gated on the transport flag" unless
    usenet_include && Array(usenet_include["when"]).join(" ").include?("media_usenet_enabled")

  usenet_tasks = flatten_tasks(
    YAML.safe_load_file(File.join(root, "roles/bindery/tasks/reconcile_usenet.yml"),
                        aliases: true)
  )
  {
    "prowlarr" => "bindery_prowlarr",
    "downloadclient" => "bindery_client"
  }.each do |resource, prefix|
    create = usenet_tasks.find do |task|
      task.dig("ansible.builtin.uri", "url") == "{{ bindery_api }}/#{resource}" &&
        task.dig("ansible.builtin.uri", "method") == "POST"
    end
    failures << "the Bindery #{resource} row must be created only when absent" unless
      create && Array(create["when"]).join(" ").include?("#{prefix}_create")
    repair = usenet_tasks.find do |task|
      task.dig("ansible.builtin.uri", "method") == "PUT" &&
        task.dig("ansible.builtin.uri", "url").to_s.include?("/#{resource}/")
    end
    failures << "the Bindery #{resource} row must be repaired rather than duplicated" unless
      repair && Array(repair["when"]).join(" ").include?("#{prefix}_repair")
    duplicate_guard = usenet_tasks.find do |task|
      task.key?("ansible.builtin.assert") &&
        task.to_s.include?("#{prefix}_matches | length <= 1")
    end
    failures << "Bindery must refuse an ambiguous #{resource} match" if duplicate_guard.nil?
  end

  # The login limiter records five failures per fifteen minutes per IP and then
  # answers 429 to the correct password too, so no probe anywhere in this role
  # may submit a password it expects to be refused.
  wrong_password_probe = role_tasks.find do |task|
    body = task.dig("ansible.builtin.uri", "body")
    body.is_a?(Hash) && body.key?("password") &&
      body["password"].to_s != "{{ vault_bindery_admin_password }}"
  end
  failures << "no Bindery request may submit a password the platform expects to be wrong" if
    wrong_password_probe

  # Every request, render and fact naming a credential must stay redacted: the
  # bodies, headers and resolved values are what a module result renders in
  # full. Assertions are judged separately below, because redacting one costs
  # the diagnostic that is the entire reason it exists.
  credential_tasks = role_tasks
                     .reject { |task| task.key?("ansible.builtin.assert") }
                     .select do |task|
    task.to_s.match?(/vault_bindery_(?:api_key|admin_username|admin_password)|bindery_api_key/)
  end
  failures << "every Bindery request naming a credential must use no_log" unless
    credential_tasks.length >= 10 && credential_tasks.all? { |task| task["no_log"] == true }

  # The shape guard compares the authored values themselves, so it is redacted.
  # The recoverability guard only measures the resolved key's length, and its
  # whole purpose is the diagnostic it prints when Bindery is holding an
  # identity this platform did not author, so it must stay readable.
  shape_guard = role_tasks.find do |task|
    task.key?("ansible.builtin.assert") && task.to_s.include?("vault_bindery_api_key")
  end
  failures << "the Bindery credential shape guard must use no_log" unless
    shape_guard && shape_guard["no_log"] == true
  recovery_guard = role_tasks.find do |task|
    task.key?("ansible.builtin.assert") && task.to_s.include?("bindery_api_key | length")
  end
  failures << "the Bindery recoverability guard must stay readable" unless
    recovery_guard && !recovery_guard["no_log"]

  environment_render = tasks.find do |task|
    task.dig("ansible.builtin.template", "src") == "env.j2"
  end
  failures << "the Bindery environment render must be private" unless
    environment_render && environment_render.dig("ansible.builtin.template", "mode") == "0600"

  verification = tasks.select { |task| Array(task["tags"]).include?("platform_verify_bindery") }
  verification_urls = verification.filter_map { |task| task.dig("ansible.builtin.uri", "url") }
  %w[/health /auth/status /rootfolder /auth/login /system/storage].each do |suffix|
    failures << "Bindery verification must read #{suffix}" unless
      verification_urls.any? { |url| url.to_s.include?(suffix) }
  end
  # The refusal probe is a credential-free read of a protected route, never a
  # deliberately wrong password.
  anonymous = verification.find do |task|
    task.dig("ansible.builtin.uri", "url") == "{{ bindery_api }}/rootfolder" &&
      !task.dig("ansible.builtin.uri").key?("headers")
  end
  failures << "Bindery verification must probe a protected route with no credential" if
    anonymous.nil?
  failures << "the Bindery anonymous refusal probe must stay readable" if
    anonymous && anonymous["no_log"]
  logins = verification.select do |task|
    task.dig("ansible.builtin.uri", "url") == "{{ bindery_api }}/auth/login"
  end
  failures << "Bindery verification must spend exactly one login attempt" unless
    logins.length == 1
  failures << "Bindery verification must authenticate as the vault administrator" unless
    logins.first&.dig("ansible.builtin.uri", "body", "password") ==
      "{{ vault_bindery_admin_password }}"

  # Every probe accepts any status and defers to the assertion, so a drifted
  # credential fails with a diagnosis rather than inside a redacted request.
  verification.each do |task|
    next unless task.key?("ansible.builtin.uri")
    next unless task["failed_when"] == false

    failures << "#{task.fetch('name')} must accept any status and defer to the assertion" unless
      task.dig("ansible.builtin.uri", "status_code") == "{{ range(100, 600) | list }}"
  end
  outcome_assertion = verification.find { |task| task.key?("ansible.builtin.assert") }
  conditions = Array(outcome_assertion&.dig("ansible.builtin.assert", "that"))
  {
    "the enforced authentication mode" => ["bindery_verify_auth_status", "enabled"],
    "the closed first-run setup" => ["bindery_verify_auth_status", "setupRequired"],
    "the refused anonymous caller" => ["bindery_verify_anonymous.status", "401"],
    "the accepted vault administrator" => ["bindery_verify_identity.status", "200"],
    "the owned destination roots" => ["bindery_verify_roots", "bindery_library_roots"],
    "the writable configured storage" => ["bindery_verify_storage", "writable"],
    # The service's own EXDEV probe, and the only reading that tells one bind
    # mount per host share from one per directory: everything else about the
    # four paths is identical either way and an import still reports success.
    "the hardlinkable staging layout" => ["bindery_verify_storage", "hardlinkable"]
  }.each do |label, (needle, value)|
    failures << "Bindery verification must assert #{label}" unless
      conditions.any? { |condition| condition.include?(needle) && condition.include?(value) }
  end
  # The diagnosis is the point of deferring, so it must not be redacted away.
  failures << "the Bindery outcome assertion must stay readable" if
    outcome_assertion && outcome_assertion["no_log"]

  failures << "Bindery verification reads must not claim a change" unless
    verification.all? do |task|
      !task.key?("ansible.builtin.uri") ||
        (task["changed_when"] == false && task["check_mode"] == false)
    end
end

unless failures.empty?
  # Every violation, one per line, each line naming the contract that authored it.
  # The prefix is not decoration: tests/<service>_contract_test.rb requires a row
  # that says "this must be refused" to see it, so a Ruby backtrace or a shell
  # diagnostic can no longer stand in for a refusal (#352).
  warn failures.map { |failure| "Bindery contract failed: #{failure}" }.join("\n")
  exit 1
end
