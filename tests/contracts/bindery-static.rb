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
  roles/bindery/tasks/reconcile_authors.yml
  roles/bindery/tasks/reconcile_audiobookshelf.yml
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
  # Auto-grab is on by policy, and the row is still written. `autoGrabEnabled`
  # fails open -- a missing row, a read error and an unattached repository all
  # read as enabled -- so absence already means on and this row is a repair of a
  # manual disable rather than a guarantee of enablement. Telemetry is the
  # opposite: on by default, so its row is the guarantee.
  failures << "Bindery must pin auto-grab on and telemetry off" unless
    defaults["bindery_pinned_settings"] ==
      { "autoGrab.enabled" => "true", "telemetry.enabled" => "false" }
  # `Any` rather than `E-Book` or `Audiobook`: an author here routinely has both
  # editions and each narrower profile refuses one of them.
  failures << "Bindery must default an author to the Any quality profile" unless
    defaults["bindery_default_quality_profile_name"] == "Any"
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

  # Nothing supplies an author with a destination -- `library.defaultRootFolderId`
  # does not exist on a live install -- so an author arrives with a null root
  # folder and profile and its books are wanted and unactionable. The
  # verification block asserts the outcome; this asserts the repair that
  # produces it, so deleting the include fails here rather than on the NAS.
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
  # A repair that overwrote a set value would fight a deliberate per-author
  # choice on every converge; a repair that wrote `monitored` would make
  # unfollowing an author impossible.
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

  # The Audiobookshelf handoff. Unlike the Usenet pair it is gated on nothing:
  # site.yml converges Audiobookshelf before Bindery on every host and the
  # integration needs no transport, so a `when:` here would be a lane in which
  # it silently does not exist.
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

  # Upstream keeps every field the request omits and substitutes its own default
  # for an empty label, so the fields the reconciliation *sends* are exactly the
  # fields it can hold to a declared value. A field compared but never sent
  # never settles; a field sent but never compared is written on every converge.
  # Both writes therefore carry the same five, and only the declare carries the
  # credential.
  declared_fields = %w[baseUrl label enabled libraryIds pathRemap].freeze
  abs_declare = abs_writes.find do |task|
    task.dig("ansible.builtin.uri", "body").is_a?(Hash) &&
      task.dig("ansible.builtin.uri", "body").key?("apiKey")
  end
  abs_repair = (abs_writes - [abs_declare]).first
  failures << "the Bindery Audiobookshelf declaration must send every declared field" unless
    abs_declare &&
    abs_declare.dig("ansible.builtin.uri", "body").keys.sort == (declared_fields + %w[apiKey]).sort
  # The repair leaves the credential alone, which is what makes a drift in the
  # address or the library id repairable without re-minting a key neither side
  # can read back -- and it still has to send every other field, or the one it
  # omits is a hand edit that outlives every converge.
  failures << "the Bindery Audiobookshelf repair must not touch the credential" unless
    abs_repair && !abs_repair.dig("ansible.builtin.uri", "body").key?("apiKey")
  failures << "the Bindery Audiobookshelf repair must send every declared field" unless
    abs_repair &&
    (abs_repair.dig("ansible.builtin.uri", "body").keys - %w[apiKey]).sort == declared_fields.sort

  # Read-then-decide, as everything else in this role is. The declaration is the
  # replace path and runs only when a credential has to be minted; the repair
  # runs only when it does not and something else drifted.
  failures << "the Bindery Audiobookshelf declaration must be gated on a mint" unless
    abs_declare && Array(abs_declare["when"]).join(" ").include?("bindery_abs_mint")
  repair_conditions = Array(abs_repair&.fetch("when", nil)).join(" ")
  failures << "the Bindery Audiobookshelf repair must be gated on drift alone" unless
    abs_repair && repair_conditions.include?("bindery_abs_drifted") &&
    repair_conditions.include?("not bindery_abs_mint")

  # Neither end reveals what it holds, so "both report a credential" is not "the
  # two are the same one". POST /abs/test sent with no key of its own falls back
  # to the stored one, which is the only reading that separates a working pair
  # from a restored database on either side.
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

  # Audiobookshelf mints an API key that never expires only when the create
  # carries no expiresIn, and one that authenticates anything only when it
  # carries isActive explicitly: the route stores `!!req.body.isActive`, so an
  # omitted flag is a key that is refused everywhere and says nothing about why.
  abs_mint = abs_tasks.find do |task|
    task.dig("ansible.builtin.uri", "url") == "{{ bindery_audiobookshelf_api }}/api/api-keys" &&
      task.dig("ansible.builtin.uri", "method") == "POST"
  end
  mint_body = abs_mint&.dig("ansible.builtin.uri", "body")
  failures << "the Audiobookshelf key Bindery mints must be active and never expire" unless
    mint_body.is_a?(Hash) && mint_body["isActive"] == true && !mint_body.key?("expiresIn")

  # The identifier is a UUID Audiobookshelf mints at library-creation time, so
  # the name has to select exactly one library or the handoff is configured
  # against nothing, and a surplus key of the platform's own name cannot be told
  # from the live one.
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

  # The login limiter records five failures per fifteen minutes per IP and then
  # answers 429 to the correct password too, so no probe anywhere in this role
  # may submit a password it expects to be refused. Two passwords are authored
  # rather than one since the role signs in to Audiobookshelf as well, and the
  # property is the same for both: every login this role spends must be one it
  # expects to succeed.
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

  # Every request, render and fact naming a credential must stay redacted: the
  # bodies, headers and resolved values are what a module result renders in
  # full. Assertions are judged separately below, because redacting one costs
  # the diagnostic that is the entire reason it exists.
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
  %w[/health /auth/status /rootfolder /auth/login /system/storage
     /abs/config /abs/test].each do |suffix|
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
  # Every assertion in the block, not the first one: the acquisition properties
  # below are asserted separately from the deployment ones because the indexer
  # half is gated on `media_usenet_enabled` and the rest is not, and a `find`
  # here silently stopped reading at whichever happened to come first.
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
    # The service's own EXDEV probe, and the only reading that tells one bind
    # mount per host share from one per directory: everything else about the
    # four paths is identical either way and an import still reports success.
    "the hardlinkable staging layout" => ["bindery_verify_storage", "hardlinkable"],
    # The acquisition half. Both went wrong at once in #425 and every reading
    # above stayed correct: indexers are synced from Prowlarr rather than
    # written here, and an author with a null destination root holds books that
    # read `wanted` and can never be grabbed.
    # The needle is the enabled-count projection rather than a bare `length`,
    # because the status probe and the total count both carry that word and a
    # plant that drops one of them would still satisfy the other.
    "the synced indexers" => ["bindery_verify_indexers", "selectattr('enabled')"],
    "the author destinations" => ["bindery_verify_authors", "rootFolderId"],
    "the author quality profiles" => ["bindery_verify_authors", "qualityProfileId"],
    # The post-import scan logs its own failures at WARN and swallows them, so
    # the import still succeeds and nothing else in the platform reads
    # differently. These three rows are the only place a broken handoff is
    # visible: the switch, the credential's presence, and -- because a stored
    # credential that no longer authenticates reads exactly like a working one
    # -- whether it still authenticates at all.
    "the enabled Audiobookshelf handoff" => ["bindery_verify_abs_config", "enabled"],
    "the configured Audiobookshelf credential" =>
      ["bindery_verify_abs_config", "apiKeyConfigured"],
    "the Audiobookshelf credential that still authenticates" =>
      ["bindery_verify_abs_probe.status", "200"]
  }.each do |label, (needle, value)|
    failures << "Bindery verification must assert #{label}" unless
      # `to_s` because a condition can be parsed as a boolean rather than a
      # string -- `- true` is valid YAML and a valid assertion -- and the
      # contract must name that as a missing property, not crash on it.
      conditions.any? do |condition|
        condition.to_s.include?(needle) && condition.to_s.include?(value)
      end
  end
  # The indexer assertion is gated on the indexer *declaration*, not on the
  # transport flag. Every sandbox converges the acquisition stack with
  # `media_arr_indexers: []`, so a transport-only gate fails the `bindery`
  # integration lane against a host behaving exactly as declared -- which is
  # what it did before this check existed.
  indexer_assertion = outcome_assertions.find do |task|
    Array(task.dig("ansible.builtin.assert", "that"))
      .any? { |condition| condition.to_s.include?("bindery_verify_indexers") }
  end
  failures << "the Bindery indexer assertion must be gated on the declared indexers" unless
    indexer_assertion &&
    Array(indexer_assertion["when"]).join(" ").include?("media_arr_indexers")

  # The diagnosis is the point of deferring, so it must not be redacted away.
  failures << "the Bindery outcome assertion must stay readable" if
    outcome_assertions.any? { |task| task["no_log"] }

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
