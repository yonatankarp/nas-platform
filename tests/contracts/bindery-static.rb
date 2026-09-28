#!/usr/bin/env ruby
# Static half of the Bindery contract, decided from the repository alone.
# usage: bindery-static.rb REPOSITORY
require "yaml"

root = ARGV.fetch(0)
failures = []
required = %w[
  roles/bindery/defaults/main.yml
  roles/bindery/meta/argument_specs.yml
  roles/bindery/tasks/main.yml
  roles/bindery/tasks/pre_upgrade_backup.yml
  roles/bindery/tasks/reconcile_authors.yml
  roles/bindery/tasks/reconcile_audiobookshelf.yml
  roles/bindery/tasks/reconcile_usenet.yml
  roles/bindery/tasks/resolve_api_key.yml
  roles/bindery/templates/env.j2
  roles/image_downgrade_guard/tasks/main.yml
  services/bindery/compose.yml
  services/bindery/compose.mac.yml
  services/bindery/compose.integration.yml
]
required.each do |relative|
  failures << "missing #{relative}" unless File.file?(File.join(root, relative))
end

# Flattened so rescue/always tasks count too.
def flatten_tasks(tasks)
  Array(tasks).flat_map do |task|
    next [] unless task.is_a?(Hash)

    [task] + flatten_tasks(task["block"]) + flatten_tasks(task["rescue"]) +
      flatten_tasks(task["always"])
  end
end

# Read as assignments: a commented-out sample would satisfy a substring search.
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

  # Its integration writes resolve hosts at write time, so it joins the control network.
  failures << "Bindery must join the shared media control network" unless
    Array(service["networks"]) == %w[default media-control]
  failures << "the shared media control network must be the external one" unless
    compose.dig("networks", "media-control") ==
      { "external" => true, "name" => "${PLATFORM_MEDIA_NETWORK:?}" }

  # Distroless: nothing can remap or chown, so `user:` is the only mechanism and
  # BINDERY_PUID/PGID (boot-time assertions) must agree with it.
  failures << "Bindery must take the platform identity as the container user" unless
    service["user"] == "${NAS_UID:?}:${NAS_GID:?}"
  {
    "BINDERY_PUID" => "${NAS_UID:?}",
    "BINDERY_PGID" => "${NAS_GID:?}"
  }.each do |name, expected|
    failures << "Bindery must assert the platform identity as #{name}" unless
      service.dig("environment", name) == expected
  end

  # One mount per host share, since rename(2) will not cross a mount boundary;
  # container paths match SABnzbd's, which reports finished downloads by its own path.
  failures << "Bindery must mount its database and each library's whole host share" unless
    Array(service["volumes"]) == [
      "${BINDERY_CONFIG_PATH:?}:/config",
      "${BINDERY_BOOKS_PATH:?}:/data/books",
      "${BINDERY_MEDIA_PATH:?}:/data/media"
    ]

  # A missing audiobook variable falls back to the ebook one, collapsing the libraries.
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
  # A broad trusted proxy disables the login rate limiter.
  %w[BINDERY_TRUSTED_PROXY BINDERY_URL_BASE].each do |name|
    failures << "Bindery must leave #{name} unset" if
      service.fetch("environment", {}).key?(name)
  end

  # The upgrade lane's stop assertion proves this window (#845).
  failures << "Bindery holds its SQLite store and must declare a stop grace period" unless
    service["stop_grace_period"] == "10s"

  failures << "Bindery must publish the acquisition web UI port" unless
    Array(service["ports"]) == ["8787:8787"]
  mac = YAML.safe_load_file(File.join(root, "services/bindery/compose.mac.yml"))
  failures << "the Mac override must republish the web UI on the harness port" unless
    mac.dig("services", "bindery", "ports") == ["${BINDERY_HOST_PORT:?}:8787"]

  # The only executable is /bindery, so a CMD-SHELL probe cannot run.
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
  # autoGrabEnabled fails open, so its row repairs a manual disable; telemetry is on
  # by default, so its row is the guarantee.
  failures << "Bindery must pin auto-grab on and telemetry off" unless
    defaults["bindery_pinned_settings"] ==
      { "autoGrab.enabled" => "true", "telemetry.enabled" => "false" }
  # `Any`: an author routinely has both editions.
  failures << "Bindery must default an author to the Any quality profile" unless
    defaults["bindery_default_quality_profile_name"] == "Any"
  failures << "Bindery must address Prowlarr and SABnzbd by their control-network alias" unless
    defaults["bindery_prowlarr_internal_url"] == "http://prowlarr:9696" &&
    defaults["bindery_sabnzbd_host"] == "sabnzbd"
  # SABnzbd's category map lands each library in its own staging root.
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
  # The API-key seed is the only credential Bindery reads from its environment.
  failures << "the Bindery environment must carry exactly the API-key seed" unless
    env_assignments.select { |_name, value| value.include?("vault_") } ==
      [["BINDERY_API_KEY", "{{ vault_bindery_api_key }}"]]

  role_tasks = %w[
    roles/bindery/tasks/main.yml
    roles/bindery/tasks/pre_upgrade_backup.yml
    roles/bindery/tasks/reconcile_authors.yml
    roles/bindery/tasks/reconcile_audiobookshelf.yml
    roles/bindery/tasks/reconcile_usenet.yml
    roles/bindery/tasks/resolve_api_key.yml
  ].flat_map do |relative|
    flatten_tasks(YAML.safe_load_file(File.join(root, relative), aliases: true))
  end
  tasks = flatten_tasks(
    YAML.safe_load_file(File.join(root, "roles/bindery/tasks/main.yml"), aliases: true)
  )

  # Deployment and bounded recovery (#509), told apart by `recreate`.
  compose_ups = tasks.select { |task| task.dig("community.docker.docker_compose_v2", "state") == "present" }
  failures << "Bindery must deploy through docker_compose_v2" unless
    compose_ups.count { |task| !task["community.docker.docker_compose_v2"].key?("recreate") } == 1
  failures << "Bindery must force-recreate a stuck container exactly once per converge" unless
    compose_ups.count { |task| task["community.docker.docker_compose_v2"]["recreate"] == "always" } == 1
  failures << "Bindery must verify its effective project CPU policy" unless
    tasks.count { |task| task.dig("vars", "container_cpu_service_name") == "bindery" } == 1

  # Before the deploy: Bindery migrates its schema on start.
  backup_include = tasks.index do |task|
    task["ansible.builtin.include_tasks"] == "pre_upgrade_backup.yml"
  end
  deploy_index = tasks.index { |task| task.key?("community.docker.docker_compose_v2") }
  failures << "the Bindery pre-upgrade state guard must run before the deployment" unless
    backup_include && deploy_index && backup_include < deploy_index

  # #509: the health refusal must sit right after the deployment, since a
  # `Restarting` container still passes `docker container ls`. Each check is
  # presence-guarded so each names one defect.
  health_indexes = tasks.each_index.select do |index|
    tasks[index].dig("vars", "container_health_service_name") == "bindery"
  end
  failures << "Bindery must detect and then refuse a container that runs but never serves" unless
    health_indexes.length == 2

  recreate = tasks.find { |task| task.dig("community.docker.docker_compose_v2", "recreate") }
  recreate_options = recreate ? recreate["community.docker.docker_compose_v2"] : {}
  failures << "Bindery must force-recreate only the services Docker reports as stuck" unless
    recreate_options["recreate"] == "always" &&
    recreate_options["dependencies"] == false &&
    recreate_options["services"] == "{{ container_health_stuck_services }}"
  # THE idempotence property: the force-recreate is gated on a list that is empty
  # on a converged host and under --check.
  failures << "the Bindery force-recreate must be conditional on a container actually being stuck" unless
    recreate && recreate["when"].to_s.include?("container_health_stuck_services")
  recreate_block = tasks.find do |task|
    task["block"].is_a?(Array) &&
      flatten_tasks(task["block"]).any? { |inner| inner.dig("community.docker.docker_compose_v2", "recreate") }
  end
  failures << "the Bindery force-recreate must catch its own failure" unless
    recreate_block && flatten_tasks(recreate_block["rescue"]).any? do |task|
      task.dig("ansible.builtin.set_fact", "bindery_recreate_failure_message")
    end

  if health_indexes.length == 2
    detect_index, verdict_index = health_indexes
    detect = tasks[detect_index]
    verdict = tasks[verdict_index]
    recreate_index = recreate ? tasks.index(recreate) : nil
    cpu_index = tasks.index { |task| task.dig("vars", "container_cpu_service_name") == "bindery" }
    failures << "the Bindery container health passes must bracket the force-recreate" unless
      cpu_index && deploy_index && recreate_index &&
      deploy_index < detect_index && detect_index < recreate_index &&
      recreate_index < verdict_index && verdict_index < cpu_index
    failures << "the Bindery container health detection must not refuse before the recreate" unless
      detect["vars"]["container_health_refuse"] == false
    failures << "the Bindery container health verdict must be the one that refuses" unless
      verdict["vars"].fetch("container_health_refuse", true) == true
    failures << "each Bindery container health pass must name the deployed Compose project" unless
      [detect, verdict].all? do |pass|
        pass["vars"]["container_health_project_name"] == "{{ bindery_compose_project_name }}"
      end
    # Each pass carries the previous operation's message; Compose's own says nothing.
    failures << "the Bindery container health detection must be handed the deployment's own failure" unless
      detect["vars"]["container_health_deploy_failure_message"]
            .to_s.include?("bindery_deploy_failure_message")
    failures << "the Bindery container health verdict must be handed the recreate's own failure" unless
      verdict["vars"]["container_health_deploy_failure_message"]
             .to_s.include?("bindery_recreate_failure_message")
    # The verdict must say the retry was already spent.
    failures << "the Bindery container health verdict must say whether a recreate was spent" unless
      verdict["vars"]["container_health_retried"].to_s.include?("bindery_recreate_spent")
  end

  # The deploy sits in a block whose rescue records its message and hands it on.
  deploy_block = tasks.find do |task|
    task["block"].is_a?(Array) &&
      flatten_tasks(task["block"]).any? do |inner|
        compose = inner["community.docker.docker_compose_v2"]
        compose.is_a?(Hash) && !compose.key?("recreate")
      end
  end
  failures << "the Bindery deployment must catch its own failure" unless
    deploy_block && flatten_tasks(deploy_block["rescue"]).any? do |task|
      task.dig("ansible.builtin.set_fact", "bindery_deploy_failure_message")
    end
  # #511: the downgrade guard must precede the backup and the deployment: a
  # migrated store refuses an older image inside the container.
  guard_include = tasks.index do |task|
    task.dig("ansible.builtin.include_role", "name") == "image_downgrade_guard"
  end
  failures << "Bindery must refuse an image older than the store already on disk" unless guard_include
  failures << "the Bindery downgrade guard must run before the backup and the deployment" unless
    guard_include && backup_include && deploy_index &&
    guard_include < backup_include && guard_include < deploy_index

  # Both halves: the manifest directory and the Compose service key.
  guard_vars = guard_include ? (tasks[guard_include]["vars"] || {}) : {}
  failures << "the Bindery downgrade guard must judge Bindery's own containers" unless
    guard_vars["image_downgrade_guard_service_name"] == "bindery" &&
    guard_vars["image_downgrade_guard_compose_service"] == "bindery" &&
    guard_vars["image_downgrade_guard_project_name"] == "{{ bindery_compose_project_name }}"

  guard_tasks = flatten_tasks(
    YAML.safe_load_file(File.join(root, "roles/image_downgrade_guard/tasks/main.yml"),
                        aliases: true)
  )
  # Reads must neither claim a change nor skip under --check.
  guard_reads = guard_tasks.select { |task| task.key?("ansible.builtin.command") }
  failures << "the downgrade guard must read the daemon without claiming a change or deferring" unless
    guard_reads.length == 2 &&
    guard_reads.all? { |task| task["changed_when"] == false && task["check_mode"] == false }

  # Without --all it misses the exited container it exists for.
  failures << "the downgrade guard must list stopped containers too" unless
    Array(guard_reads.first&.dig("ansible.builtin.command", "argv")).include?("--all")

  # An assert, not a debug (#511).
  guard_refusal = guard_tasks.find { |task| task.key?("ansible.builtin.assert") }
  failures << "the downgrade guard must refuse rather than report" unless
    guard_refusal &&
    Array(guard_refusal.dig("ansible.builtin.assert", "that")).join(" ")
      .include?("image_downgrade_guard_newer_versions")

  backup_tasks = flatten_tasks(
    YAML.safe_load_file(File.join(root, "roles/bindery/tasks/pre_upgrade_backup.yml"),
                        aliases: true)
  )
  backup_request = backup_tasks.find do |task|
    task.dig("ansible.builtin.uri", "url").to_s.end_with?("/backup")
  end
  # POST /backup is VACUUM INTO: a file copy would omit the WAL. Only 201 passes.
  failures << "the Bindery pre-upgrade backup must accept only a created backup" unless
    backup_request && backup_request.dig("ansible.builtin.uri", "method") == "POST" &&
    backup_request.dig("ansible.builtin.uri", "status_code") == [201]
  backup_conditions = Array(backup_request&.fetch("when", nil)).join(" ")
  failures << "the Bindery pre-upgrade backup must be gated on an actual image change" unless
    backup_conditions.include?("bindery_upgrade_pending") &&
    backup_conditions.include?("ansible_check_mode")
  # #858: under --check read the pin from the controller checkout, since `current`
  # still names the release being replaced.
  pin_read = backup_tasks.find { |task| task.key?("ansible.builtin.slurp") }
  pin_fact = backup_tasks.find { |task| task.dig("ansible.builtin.set_fact")&.key?("bindery_pinned_image") }
                         &.dig("ansible.builtin.set_fact", "bindery_pinned_image").to_s
  failures << "the Bindery pre-upgrade backup must read the candidate's pin under --check" unless
    pin_read && Array(pin_read["when"]) == ["not ansible_check_mode"] &&
    pin_fact.include?("lookup('ansible.builtin.file', playbook_dir ~ '/services/bindery/compose.yml')") &&
    pin_fact.include?("if ansible_check_mode")

  # Nothing is create-if-absent (duplicates 500 or add rows), so read-then-decide.
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

  # Nothing gives an author a destination root, so this repair must be included.
  author_include = tasks.find do |task|
    task["ansible.builtin.include_tasks"] == "reconcile_authors.yml"
  end
  failures << "Bindery must reconcile its author destinations" if author_include.nil?
  failures << "the Bindery author reconciliation must not be gated on the transport flag" if
    author_include && Array(author_include["when"]).join(" ").include?("media_usenet_enabled")

  author_tasks = flatten_tasks(
    YAML.safe_load_file(File.join(root, "roles/bindery/tasks/reconcile_authors.yml"),
                        aliases: true)
  )
  author_write = author_tasks.find do |task|
    task.dig("ansible.builtin.uri", "url").to_s.start_with?("{{ bindery_api }}/author/") &&
      task.dig("ansible.builtin.uri", "method") == "PUT"
  end
  failures << "Bindery must repair an author destination in place" if author_write.nil?
  failures << "the Bindery author repair must write only the authors missing a value" unless
    author_write && author_write["loop"] == "{{ bindery_authors_to_repair }}"
  # Never overwrite a set value or write `monitored`.
  body = author_write&.dig("ansible.builtin.uri", "body").to_s
  %w[rootFolderId audiobookRootFolderId qualityProfileId].each do |field|
    failures << "the Bindery author repair must leave a set #{field} alone" unless
      body.include?("if item.#{field} is none else item.#{field}")
  end
  failures << "the Bindery author repair must not own the monitored state" if
    body.include?("'monitored'")

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

  # Ungated: site.yml converges Audiobookshelf first on every host.
  abs_include = tasks.find do |task|
    task["ansible.builtin.include_tasks"] == "reconcile_audiobookshelf.yml"
  end
  failures << "Bindery must reconcile its Audiobookshelf integration unconditionally" unless
    abs_include && !abs_include.key?("when")

  abs_tasks = flatten_tasks(
    YAML.safe_load_file(File.join(root, "roles/bindery/tasks/reconcile_audiobookshelf.yml"),
                        aliases: true)
  )
  abs_writes = abs_tasks.select do |task|
    task.dig("ansible.builtin.uri", "url") == "{{ bindery_api }}/abs/config" &&
      task.dig("ansible.builtin.uri", "method") == "PUT"
  end
  failures << "Bindery must both declare and repair its Audiobookshelf integration" unless
    abs_writes.length == 2

  # Upstream keeps omitted fields, so send exactly the compared fields.
  declared_fields = %w[baseUrl label enabled libraryIds pathRemap].freeze
  abs_declare = abs_writes.find do |task|
    task.dig("ansible.builtin.uri", "body").is_a?(Hash) &&
      task.dig("ansible.builtin.uri", "body").key?("apiKey")
  end
  abs_repair = (abs_writes - [abs_declare]).first
  failures << "the Bindery Audiobookshelf declaration must send every declared field" unless
    abs_declare &&
    abs_declare.dig("ansible.builtin.uri", "body").keys.sort == (declared_fields + %w[apiKey]).sort
  # The repair leaves the credential alone but sends every other field.
  failures << "the Bindery Audiobookshelf repair must not touch the credential" unless
    abs_repair && !abs_repair.dig("ansible.builtin.uri", "body").key?("apiKey")
  failures << "the Bindery Audiobookshelf repair must send every declared field" unless
    abs_repair &&
    (abs_repair.dig("ansible.builtin.uri", "body").keys - %w[apiKey]).sort == declared_fields.sort

  failures << "the Bindery Audiobookshelf declaration must be gated on a mint" unless
    abs_declare && Array(abs_declare["when"]).join(" ").include?("bindery_abs_mint")
  repair_conditions = Array(abs_repair&.fetch("when", nil)).join(" ")
  failures << "the Bindery Audiobookshelf repair must be gated on drift alone" unless
    abs_repair && repair_conditions.include?("bindery_abs_drifted") &&
    repair_conditions.include?("not bindery_abs_mint")

  # Neither end reveals its key; POST /abs/test with no key uses the stored one.
  abs_probe = abs_tasks.find do |task|
    task.dig("ansible.builtin.uri", "url") == "{{ bindery_api }}/abs/test"
  end
  failures << "Bindery must probe the credential it holds for Audiobookshelf" unless
    abs_probe && abs_probe.dig("ansible.builtin.uri", "body") == {} &&
    abs_probe["changed_when"] == false && abs_probe["check_mode"] == false
  failures << "the Bindery Audiobookshelf mint must answer the credential probe" unless
    abs_tasks.any? do |task|
      task.dig("ansible.builtin.set_fact", "bindery_abs_mint").to_s.include?("bindery_abs_probe")
    end

  # No expiresIn, and isActive explicitly: an omitted flag is a key refused everywhere.
  abs_mint = abs_tasks.find do |task|
    task.dig("ansible.builtin.uri", "url") == "{{ bindery_audiobookshelf_api }}/api/api-keys" &&
      task.dig("ansible.builtin.uri", "method") == "POST"
  end
  mint_body = abs_mint&.dig("ansible.builtin.uri", "body")
  failures << "the Audiobookshelf key Bindery mints must be active and never expire" unless
    mint_body.is_a?(Hash) && mint_body["isActive"] == true && !mint_body.key?("expiresIn")

  # Retire last, after the replacement exists: revoking first can strand Bindery
  # with a dead credential. Audiobookshelf permits duplicate key names.
  abs_retire_index = abs_tasks.find_index do |task|
    task.dig("ansible.builtin.uri", "method") == "DELETE" &&
      task.dig("ansible.builtin.uri", "url").to_s
          .start_with?("{{ bindery_audiobookshelf_api }}/api/api-keys/")
  end
  abs_retire = abs_retire_index && abs_tasks[abs_retire_index]
  if abs_retire.nil?
    failures << "Bindery must retire the superseded Audiobookshelf API key"
  else
    abs_mint_index = abs_mint && abs_tasks.find_index { |task| task.equal?(abs_mint) }
    abs_declare_index = abs_declare && abs_tasks.find_index { |task| task.equal?(abs_declare) }
    failures << "the superseded Audiobookshelf API key must be retired only after its " \
                "replacement is declared" unless
      abs_mint_index && abs_declare_index &&
      abs_retire_index > abs_mint_index && abs_retire_index > abs_declare_index
    # Loop over the keys read before the mint, or it revokes the new one.
    failures << "the Audiobookshelf retirement must loop over the keys read before the mint" unless
      abs_retire["loop"] == "{{ bindery_audiobookshelf_key_matches }}"
  end

  # The name must select exactly one library.
  failures << "Bindery must refuse an ambiguous Audiobookshelf library" unless
    abs_tasks.any? do |task|
      task.key?("ansible.builtin.assert") &&
        task.to_s.include?("bindery_audiobookshelf_library_matches | length == 1")
    end
  failures << "Bindery must refuse an ambiguous Audiobookshelf API key" unless
    abs_tasks.any? do |task|
      task.key?("ansible.builtin.assert") &&
        task.to_s.include?("bindery_audiobookshelf_key_matches | length <= 1")
    end

  # The limiter 429s the correct password after five failures, so every login this
  # role spends must be one it expects to succeed.
  authored_passwords = [
    "{{ vault_bindery_admin_password }}",
    "{{ vault_audiobookshelf_admin_password }}"
  ].freeze
  wrong_password_probe = role_tasks.find do |task|
    body = task.dig("ansible.builtin.uri", "body")
    body.is_a?(Hash) && body.key?("password") &&
      !authored_passwords.include?(body["password"].to_s)
  end
  failures << "no Bindery request may submit a password the platform expects to be wrong" if
    wrong_password_probe

  # Everything naming a credential is redacted; assertions are judged below.
  credential_tasks = role_tasks
                     .reject { |task| task.key?("ansible.builtin.assert") }
                     .select do |task|
    task.to_s.match?(
      /vault_bindery_(?:api_key|admin_username|admin_password)|bindery_api_key|
       vault_audiobookshelf_admin_(?:username|password)|bindery_audiobookshelf_token/x
    )
  end
  failures << "every Bindery request naming a credential must use no_log" unless
    credential_tasks.length >= 16 && credential_tasks.all? { |task| task["no_log"] == true }

  shape_guard = role_tasks.find do |task|
    task.key?("ansible.builtin.assert") && task.to_s.include?("vault_bindery_api_key")
  end
  failures << "the Bindery credential shape guard must use no_log" unless
    shape_guard && shape_guard["no_log"] == true

  # #510: the classification must read every probe's status (429 vs 401) and stay
  # readable, so an unreachable Bindery is never told to drop its database.
  key_classification = role_tasks.find do |task|
    task.dig("ansible.builtin.set_fact", "bindery_key_resolution")
  end
  failures << "the Bindery API-key refusal must classify what its probes saw" unless
    key_classification
  if key_classification
    classification = key_classification.dig("ansible.builtin.set_fact", "bindery_key_resolution").to_s
    %w[bindery_key_probe bindery_identity_login bindery_session_config].each do |probe|
      failures << "the Bindery API-key classification must read #{probe}.status" unless
        classification.include?("#{probe}.status")
    end
    failures << "the Bindery API-key classification must stay readable" if
      key_classification["no_log"]
  end

  recovery_guard = role_tasks.find do |task|
    task.key?("ansible.builtin.assert") &&
      Array(task.dig("ansible.builtin.assert", "that")).any? do |condition|
        condition.to_s.include?("bindery_key_resolution")
      end
  end
  failures << "the Bindery recoverability guard must stay readable" unless
    recovery_guard && !recovery_guard["no_log"]
  if recovery_guard
    refusals = recovery_guard.dig("vars", "bindery_key_refusals")
    refusals = {} unless refusals.is_a?(Hash)
    %w[unreachable rate-limited rejected-identity unexpected].each do |cause|
      failures << "the Bindery API-key refusal must carry a #{cause} message" unless
        refusals.key?(cause)
    end
    # The destructive remedy only where the identity fault is established.
    destructive = refusals.select { |_cause, text| text.to_s.match?(/remove the Bindery database/i) }
    failures << "only a refused Bindery identity may propose removing its database" unless
      destructive.keys == ["rejected-identity"]
    %w[unreachable rate-limited rejected-identity unexpected].each do |cause|
      text = refusals.fetch(cause, "").to_s
      next if text.empty?

      failures << "the Bindery #{cause} refusal must report the statuses it saw" unless
        text.include?("bindery_observed_statuses")
    end
  end

  environment_render = tasks.find do |task|
    task.dig("ansible.builtin.template", "src") == "env.j2"
  end
  failures << "the Bindery environment render must be private" unless
    environment_render && environment_render.dig("ansible.builtin.template", "mode") == "0600"

  verification = tasks.select { |task| Array(task["tags"]).include?("platform_verify_bindery") }
  verification_urls = verification.filter_map { |task| task.dig("ansible.builtin.uri", "url") }
  %w[/health /auth/status /rootfolder /auth/login /system/storage
     /abs/config /abs/test].each do |suffix|
    failures << "Bindery verification must read #{suffix}" unless
      verification_urls.any? { |url| url.to_s.include?(suffix) }
  end
  # Credential-free read of a protected route, never a wrong password.
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

  # Probes accept any status and defer to the assertion.
  verification.each do |task|
    next unless task.key?("ansible.builtin.uri")
    next unless task["failed_when"] == false

    failures << "#{task.fetch('name')} must accept any status and defer to the assertion" unless
      task.dig("ansible.builtin.uri", "status_code") == "{{ range(100, 600) | list }}"
  end
  # Every assertion, not the first: the indexer half is gated separately.
  outcome_assertions = verification.select { |task| task.key?("ansible.builtin.assert") }
  conditions = outcome_assertions.flat_map do |task|
    Array(task.dig("ansible.builtin.assert", "that"))
  end
  {
    "the enforced authentication mode" => ["bindery_verify_auth_status", "enabled"],
    "the closed first-run setup" => ["bindery_verify_auth_status", "setupRequired"],
    "the refused anonymous caller" => ["bindery_verify_anonymous.status", "401"],
    "the accepted vault administrator" => ["bindery_verify_identity.status", "200"],
    "the owned destination roots" => ["bindery_verify_roots", "bindery_library_roots"],
    "the writable configured storage" => ["bindery_verify_storage", "writable"],
    # The service's own EXDEV probe.
    "the hardlinkable staging layout" => ["bindery_verify_storage", "hardlinkable"],
    # #425: indexers sync from Prowlarr, and a null root leaves books ungrabbable.
    # The needle is the enabled-count projection, not a bare `length`.
    "the synced indexers" => ["bindery_verify_indexers", "selectattr('enabled')"],
    "the author destinations" => ["bindery_verify_authors", "rootFolderId"],
    "the author quality profiles" => ["bindery_verify_authors", "qualityProfileId"],
    # The post-import scan swallows its failures, so these rows are the only place a
    # broken Audiobookshelf handoff shows.
    "the enabled Audiobookshelf handoff" => ["bindery_verify_abs_config", "enabled"],
    "the configured Audiobookshelf credential" =>
      ["bindery_verify_abs_config", "apiKeyConfigured"],
    "the Audiobookshelf credential that still authenticates" =>
      ["bindery_verify_abs_probe.status", "200"]
  }.each do |label, (needle, value)|
    failures << "Bindery verification must assert #{label}" unless
      # `to_s`: `- true` parses as a boolean.
      conditions.any? do |condition|
        condition.to_s.include?(needle) && condition.to_s.include?(value)
      end
  end
  # Gated on the indexer declaration, not the transport: sandboxes declare none.
  indexer_assertion = outcome_assertions.find do |task|
    Array(task.dig("ansible.builtin.assert", "that"))
      .any? { |condition| condition.to_s.include?("bindery_verify_indexers") }
  end
  failures << "the Bindery indexer assertion must be gated on the declared indexers" unless
    indexer_assertion &&
    Array(indexer_assertion["when"]).join(" ").include?("media_arr_indexers")

  failures << "the Bindery outcome assertion must stay readable" if
    outcome_assertions.any? { |task| task["no_log"] }

  failures << "Bindery verification reads must not claim a change" unless
    verification.all? do |task|
      !task.key?("ansible.builtin.uri") ||
        (task["changed_when"] == false && task["check_mode"] == false)
    end
end

unless failures.empty?
  # One line per violation with the contract's prefix, which contract tests
  # match on (#352).
  warn failures.map { |failure| "Bindery contract failed: #{failure}" }.join("\n")
  exit 1
end
