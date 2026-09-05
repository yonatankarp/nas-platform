#!/usr/bin/env ruby
# The static half of the Kapowarr service contract: the Compose definition, the
# Mac override, the role's task order, its declared inputs and the confinement
# of its volume folder migration, all decided from the repository alone with
# nothing deployed.
#
# usage: kapowarr-static.rb REPOSITORY
#
require "yaml"

root = ARGV.fetch(0)
failures = []
required = %w[
  roles/kapowarr/defaults/main.yml
  roles/kapowarr/meta/argument_specs.yml
  roles/kapowarr/tasks/main.yml
  roles/kapowarr/templates/env.j2
  services/kapowarr/compose.yml
  services/kapowarr/compose.mac.yml
  services/kapowarr/compose.integration.yml
  inventory/group_vars/all/main.yml
]
required.each do |relative|
  failures << "missing #{relative}" unless File.file?(File.join(root, relative))
end

# Task files are flattened so a task on a block's rescue or always path is still
# a task the role executes.
require File.join(ENV.fetch("PLATFORM_CONTRACT_REPO_DIR"), "tests", "policy_support")
include PolicySupport

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
  compose = YAML.safe_load_file(File.join(root, "services/kapowarr/compose.yml"), aliases: true)
  service = compose.fetch("services").fetch("kapowarr")

  # Kapowarr is declared self-contained in this slice: no Prowlarr indexer and no
  # download client are configured for it, so it must not sit on the shared
  # control network, where it would be reachable by every acquisition project
  # for no purpose.
  failures << "Kapowarr must not join the shared media control network" if
    compose.key?("networks") || service.key?("networks")

  # The entrypoint has to start as root to remap its own account, so the
  # platform identity arrives under the linuxserver.io names instead of `user:`.
  failures << "Kapowarr must not override the container user" if service.key?("user")
  {
    "PUID" => "${NAS_UID:?}",
    "PGID" => "${NAS_GID:?}"
  }.each do |name, expected|
    failures << "Kapowarr must take the platform identity as #{name}" unless
      service.dig("environment", name) == expected
  end

  # The comics library and the staging directory that feeds it must arrive inside
  # one bind mount of their common host share. rename(2) refuses to cross a mount
  # boundary even when both sides are the same filesystem, so the mount per leaf
  # this replaces made every import a full byte copy plus unlink and put
  # hardlinking out of reach. tests/policy_test.rb derives the same property from
  # a container's environment paths and cannot see Kapowarr, which reads neither
  # path from its environment, so the mount list is pinned exactly here instead.
  failures << "Kapowarr must mount its database and one parent of its library and staging" unless
    Array(service["volumes"]) == [
      "${KAPOWARR_CONFIG_PATH:?}:/app/db",
      "${KAPOWARR_BOOKS_PATH:?}:/data/books"
    ]

  # The published port and the container port are both pinned by
  # config/media-acquisition.yml, and the Mac override republishes only the host
  # half, so the container half is the one a drifting image tag would move.
  failures << "Kapowarr must publish the catalog web UI port" unless
    Array(service["ports"]) == ["5656:5656"]
  mac = YAML.safe_load_file(File.join(root, "services/kapowarr/compose.mac.yml"))
  failures << "the Mac override must republish the web UI on the harness port" unless
    mac.dig("services", "kapowarr", "ports") == ["${KAPOWARR_HOST_PORT:?}:5656"]

  # The runtime image ships neither curl nor wget, so a health probe written
  # against either would report unhealthy forever.
  health = Array(service.dig("healthcheck", "test")).join(" ")
  failures << "the Kapowarr health probe must use the interpreter the image ships" unless
    health.include?("python3") && health.include?("/api/public")

  defaults = YAML.safe_load_file(File.join(root, "roles/kapowarr/defaults/main.yml"))
  failures << "Kapowarr must mount the one host share its library and staging share" unless
    defaults["kapowarr_books_host_path"] == "{{ nas_media_root }}/Books"
  failures << "Kapowarr must write the declared comics library root" unless
    defaults["kapowarr_comics_host_path"] == "{{ nas_media_root }}/Books/Comics"
  failures << "Kapowarr must keep its database in the declared config root" unless
    defaults["kapowarr_config_host_path"] == "{{ nas_docker_root }}/kapowarr/config"
  # Both container paths are asserted as offsets of the one bind mount, because
  # that relation is the whole fix: a path that is not below the mount is not in
  # the mount, however it is spelled. Each is then followed back through the
  # mount to the host directory it resolves to, and that directory must be one
  # nas_storage declares -- which is what keeps the container's view of the pair
  # and the inventory that creates them from drifting apart. A container offset
  # naming a directory host_prep does not create is a mount that resolves to
  # nothing, and Kapowarr answers a download folder that is not a directory with
  # FolderNotFound rather than by creating it.
  declared_paths = YAML.safe_load_file(
    File.join(root, "inventory/group_vars/all/main.yml")
  ).fetch("nas_storage").map { |entry| entry.fetch("path") }
  {
    "kapowarr_library_root" => ["/Comics", "the comics library"],
    "kapowarr_staging_root" => ["/.acquisition/usenet/comics", "the download staging root"]
  }.each do |key, (suffix, description)|
    failures << "#{description} must sit at #{suffix} inside the bind mount, not #{defaults[key]}" unless
      defaults[key] == "/data/books#{suffix}"
    host_path = "#{defaults['kapowarr_books_host_path']}#{suffix}"
    failures << "#{description} resolves to #{host_path}, which nas_storage does not declare" unless
      declared_paths.include?(host_path)
  end
  # Kapowarr's own default download folder is /app/temp_downloads, a directory
  # inside the image that the mount this replaces used to cover. Leaving it
  # undeclared would stage every direct download into the container's writable
  # layer, so the import would stay a cross-device copy and the file would vanish
  # on the next recreate. Settings.__format_value() stores the value
  # force-suffixed, so a declaration without the trailing separator could never
  # equal what is read back and the settings write would run on every converge.
  # Written as the literal path rather than as a reference to the variable above,
  # and the relation between the two is asserted here instead. The runtime half
  # of this contract compares this mapping to what a live Kapowarr returns and
  # reads it with a YAML parser, so a Jinja reference would be compared as
  # template text and could never match a path -- which is how this shipped once
  # and failed only in the lane.
  failures << "Kapowarr must declare the download folder the parent mount moved" unless
    defaults.dig("kapowarr_settings", "download_folder") == "#{defaults['kapowarr_staging_root']}/"

  env_assignments = environment_assignments(
    File.join(root, "roles/kapowarr/templates/env.j2")
  )
  failures << "Kapowarr env must render the CPU set exactly once" unless
    env_assignments.select { |name, _value| name == "PLATFORM_CONTAINER_CPUSET" } ==
      [["PLATFORM_CONTAINER_CPUSET", "{{ platform_effective_container_cpuset }}"]]
  # One bind mount reaches the target only if the environment exports its source,
  # and only that one: an environment still exporting a leaf path is an
  # environment a reintroduced leaf mount would resolve.
  failures << "Kapowarr env must export the host share as the single media bind source" unless
    env_assignments.select { |name, _value| name.start_with?("KAPOWARR_") && name.end_with?("_PATH") } ==
      [["KAPOWARR_CONFIG_PATH", "{{ kapowarr_config_host_path }}"],
       ["KAPOWARR_BOOKS_PATH", "{{ kapowarr_books_host_path }}"]]
  # Kapowarr reads no credential from its environment: every one lives in its own
  # database. A credential appearing here would be a copy nothing consumes.
  failures << "the Kapowarr environment must carry no vault credential" if
    env_assignments.any? { |_name, value| value.include?("vault_") }

  tasks = flatten_tasks(
    YAML.safe_load_file(File.join(root, "roles/kapowarr/tasks/main.yml"), aliases: true)
  )
  failures << "Kapowarr must deploy through docker_compose_v2" unless
    tasks.count { |task| task.dig("community.docker.docker_compose_v2", "state") == "present" } == 1
  failures << "Kapowarr must verify its effective project CPU policy" unless
    tasks.count { |task| task.dig("vars", "container_cpu_service_name") == "kapowarr" } == 1

  # Every task naming either half of the administrator identity must stay
  # redacted: the pair is submitted as a request body, which a module result
  # renders in full.
  credential_tasks = tasks.select do |task|
    task.to_s.match?(/vault_kapowarr_admin_(?:username|password)/)
  end
  failures << "every Kapowarr task naming the administrator must use no_log" unless
    credential_tasks.length >= 4 && credential_tasks.all? { |task| task["no_log"] == true }

  # Kapowarr validates a ComicVine key against comicvine.gamespot.com before it
  # will store one, so no converge may submit it: doing so would make the run
  # depend on a third party. The vault authors it, and the role only guards its
  # shape.
  comicvine_requests = tasks.select do |task|
    task.key?("ansible.builtin.uri") &&
      task.to_s.include?("vault_kapowarr_comicvine_api_key")
  end
  failures << "no Kapowarr request may submit the ComicVine credential" unless
    comicvine_requests.empty?
  comicvine_guard = tasks.find do |task|
    task.key?("ansible.builtin.assert") &&
      task.to_s.include?("vault_kapowarr_comicvine_api_key")
  end
  failures << "Kapowarr must still guard the shape of the authored ComicVine credential" if
    comicvine_guard.nil?

  environment_render = tasks.find do |task|
    task.dig("ansible.builtin.template", "src") == "env.j2"
  end
  failures << "the Kapowarr environment render must be private" unless
    environment_render && environment_render.dig("ansible.builtin.template", "mode") == "0600"

  # The identity write is the one mutation the role performs against a service
  # whose settings interface accepts anything. It must be conditional on the
  # probes, or every converge would rewrite the login and never report a
  # converged state.
  identity_write = tasks.find do |task|
    task.dig("ansible.builtin.uri", "method") == "PUT" &&
      task.to_s.include?("auth_password")
  end
  identity_conditions = Array(identity_write&.fetch("when", nil)).join(" ")
  failures << "the Kapowarr identity write must be gated on the deployed identity" unless
    identity_write && identity_conditions.include?("kapowarr_identity_current") &&
    identity_conditions.include?("ansible_check_mode")

  # The settings declaration is this platform's ownership of Kapowarr's
  # configuration, and its shape is what keeps that ownership convergent.
  # Kapowarr masks every stored credential on read -- both halves of the
  # administrator identity answer as literal asterisks -- so a declaration
  # naming one could never match what comes back, and the write would run on
  # every converge. The service order is excluded for a different reason: the
  # application validates it as a permutation of its own service list, so it is
  # declared as a partial ordering and merged over the deployed order instead.
  declared_settings = defaults["kapowarr_settings"]
  credential_keys = Array(defaults["kapowarr_settings_credential_keys"])
  failures << "Kapowarr must declare the application settings it owns" unless
    declared_settings.is_a?(Hash) && !declared_settings.empty?
  failures << "the Kapowarr credential key list must name every masked credential" unless
    (%w[api_key auth_username auth_password comicvine_api_key] - credential_keys).empty?
  if declared_settings.is_a?(Hash)
    named_credentials = declared_settings.keys & credential_keys
    failures << "the declared Kapowarr settings must name no credential: " \
                "#{named_credentials.join(', ')}" unless named_credentials.empty?
    failures << "the declared Kapowarr settings must not carry the service order" if
      declared_settings.key?("service_preference")
    # No declared value may be a Jinja reference, and this is the general form of
    # a defect that reached CI once. Ansible renders this mapping; the runtime
    # half of this contract reads it with a YAML parser and compares it to what a
    # live Kapowarr returns. A reference is therefore correct on the target and
    # unequal to every possible stored value in the comparison that proves the
    # target holds it -- so the role converges, the lane fails, and the two
    # disagree about what "the application holds this" means. Declare the value.
    templated = declared_settings.select { |_key, value| value.to_s.include?("{{") }
    failures << "the declared Kapowarr settings must name values, not templates: " \
                "#{templated.keys.join(', ')}" unless templated.empty?
    # Komga indexes the directory these name, so a change that drops them hands
    # a second service's view of the library back to the web interface.
    failures << "the declared Kapowarr settings must own the library naming templates" unless
      (%w[volume_folder_naming file_naming] - declared_settings.keys).empty?
  end
  failures << "Kapowarr must declare its download service order" if
    Array(defaults["kapowarr_service_preference"]).empty?

  settings_read = tasks.find do |task|
    task.dig("ansible.builtin.uri", "method") == "GET" &&
      task.dig("ansible.builtin.uri", "url").to_s.include?("/api/settings") &&
      !Array(task["tags"]).include?("platform_verify_kapowarr")
  end
  failures << "Kapowarr must read its deployed settings before declaring them" if settings_read.nil?
  # The read carries the API key in its query string and is a read: it must be
  # redacted, must not claim a change, and must really run under --check, or the
  # write decides from nothing.
  failures << "the Kapowarr settings read must be a redacted, real, changeless read" unless
    settings_read && settings_read["changed_when"] == false &&
    settings_read["check_mode"] == false && settings_read["no_log"] == true

  # The interface answers a no-op write and a real write identically, so the
  # write has to be gated on a difference computed before it, or the role
  # reports a change on every converge.
  settings_write = tasks.find do |task|
    task.dig("ansible.builtin.uri", "method") == "PUT" &&
      task.dig("ansible.builtin.uri", "url").to_s.include?("/api/settings") &&
      task.dig("ansible.builtin.uri", "body").to_s.include?("kapowarr_settings_declared")
  end
  settings_conditions = Array(settings_write&.fetch("when", nil)).join(" ")
  failures << "the Kapowarr settings write must be gated on the resolved drift" unless
    settings_write && settings_conditions.include?("kapowarr_settings_drift_keys") &&
    settings_conditions.include?("ansible_check_mode")
  failures << "the Kapowarr settings write must stay redacted" unless
    settings_write && settings_write["no_log"] == true

  # The volume folder migration is the only mutation in this repository that
  # moves a directory inside a media library, and the one the operator reviews
  # with --check --diff before it runs. Three properties keep that reviewable.
  failures << "the Kapowarr volume folder migration must be pinned closed" unless
    defaults.fetch("kapowarr_volume_folder_migration_allowed", nil) == false
  # And pinned closed at the layer that decides the run: group_vars/all declares
  # the same flag and outranks role defaults, so a true left behind there moves
  # directories on every converge while the check above stays green -- a guard
  # reading the losing layer, which is worse than no guard (#343). Absence is
  # safe, because the default asserted above then decides; anything but false is
  # not. The move itself is taken with
  # `-e kapowarr_volume_folder_migration_allowed=true`, which outranks both
  # layers and leaves nothing committed to forget.
  failures << "the Kapowarr volume folder migration must be pinned closed in the inventory" unless
    YAML.safe_load_file(File.join(root, "inventory/group_vars/all/main.yml"))
        .fetch("kapowarr_volume_folder_migration_allowed", false) == false
  migration_option = YAML.safe_load_file(
    File.join(root, "roles/kapowarr/meta/argument_specs.yml")
  ).dig("argument_specs", "main", "options", "kapowarr_volume_folder_migration_allowed")
  failures << "the Kapowarr volume folder migration input must be a declared bool" unless
    migration_option.is_a?(Hash) && migration_option["type"] == "bool"

  # First: the move is gated on both the one-convergence input and check mode,
  # so neither an ordinary converge nor a review can move a directory.
  folder_migration = tasks.find do |task|
    body = task.dig("ansible.builtin.uri", "body")
    task.dig("ansible.builtin.uri", "method") == "PUT" &&
      body.is_a?(Hash) && body.key?("volume_folder")
  end
  migration_conditions = Array(folder_migration&.fetch("when", nil)).join(" ")
  failures << "Kapowarr must migrate volume folders through the application" if
    folder_migration.nil?
  failures << "the Kapowarr volume folder move must be gated on the one-convergence input" unless
    folder_migration &&
    migration_conditions.include?("kapowarr_volume_folder_migration_allowed") &&
    migration_conditions.include?("ansible_check_mode")
  # Second: it asks for the folder the application derives rather than naming
  # one, and repairs the custom-folder flag the same call would otherwise set --
  # a volume marked as carrying an operator-chosen folder is one Kapowarr stops
  # re-deriving, so the next template change would converge silently wrong.
  migration_body = folder_migration&.dig("ansible.builtin.uri", "body") || {}
  failures << "the Kapowarr volume folder move must take the derived folder" unless
    migration_body["volume_folder"].nil? && migration_body["custom_folder"] == false
  # Third: the plan is read from the application's own rename preview, and that
  # read must really run under --check, or the review reports nothing.
  rename_reads = tasks.select do |task|
    task.dig("ansible.builtin.uri", "url").to_s.include?("/rename?api_key=")
  end
  failures << "Kapowarr must read the application's own rename plan per volume" if
    rename_reads.length < 2
  rename_reads.each do |task|
    failures << "#{task.fetch('name')} must be a redacted, real, changeless read" unless
      task["changed_when"] == false && task["check_mode"] == false && task["no_log"] == true
  end
  # Confinement. The comics library is the only tree a restore of this data
  # covers, so the migration must be unable to move, empty or remove anything
  # outside it. Four properties carry that, and each is asserted here because a
  # comment cannot fail a run.
  #
  # First: the role names the comics library among the paths it touches, which is
  # what runs deployment_bundle's containment check against it -- a symlink
  # between the media root and the library would otherwise let a rename follow
  # the link out of the tree.
  target_paths = tasks.find do |task|
    task.dig("vars", "deployment_target_service") == "kapowarr"
  end&.dig("vars", "deployment_target_extra_paths")
  failures << "Kapowarr must name the comics library among the paths it touches" unless
    Array(target_paths).include?("{{ kapowarr_comics_host_path }}")
  # Second: a volume enters the plan only if the folder it holds and the folder
  # Kapowarr previews for it are both under the declared library root. The first
  # is the directory the move empties and Kapowarr then removes; the second is
  # where the files land.
  migration_plan = tasks.find do |task|
    task.dig("ansible.builtin.set_fact")&.key?("kapowarr_volume_folder_migrations") &&
      task.key?("when")
  end
  plan_conditions = Array(migration_plan&.fetch("when", nil))
  failures << "the Kapowarr migration plan must confine the folder it moves from" unless
    plan_conditions.any? do |value|
      value.to_s.include?("item.folder is match") &&
        value.to_s.include?("kapowarr_library_root | regex_escape")
    end
  failures << "the Kapowarr migration plan must confine the folder it moves to" unless
    plan_conditions.any? do |value|
      value.to_s.include?("item.target is match") &&
        value.to_s.include?("kapowarr_library_root | regex_escape")
    end
  # Third: a volume refused by either test is named rather than dropped, because
  # a silent exclusion is indistinguishable from a converged library.
  unconfined_report = tasks.find do |task|
    task.key?("ansible.builtin.debug") &&
      task["loop"].to_s.include?("kapowarr_volume_folders_unconfined")
  end
  failures << "Kapowarr must report each volume folder it refuses as unconfined" if
    unconfined_report.nil?
  # Fourth, and the one the other three rest on: the request names no path, so
  # the folder it installs is the one Kapowarr derives from the root folder that
  # *volume* is attached to. That is the declared root only while Kapowarr owns
  # exactly the declared one, so a second root folder must refuse the migration
  # rather than run it.
  root_refusal = tasks.find do |task|
    task.key?("ansible.builtin.assert") &&
      Array(task.dig("ansible.builtin.assert", "that")).any? do |value|
        value.to_s.include?("kapowarr_root_folders") &&
          value.to_s.include?("kapowarr_library_root")
      end
  end
  failures << "a second Kapowarr library root must refuse the volume folder migration" unless
    root_refusal &&
    Array(root_refusal["when"]).join(" ").include?("kapowarr_volume_folder_migrations")
  # The refusal is worthless after the fact, so it must precede the move.
  if root_refusal && folder_migration
    failures << "the Kapowarr library root refusal must precede the volume folder move" unless
      tasks.index(root_refusal) < tasks.index(folder_migration)
  end

  # And the review itself: one report per volume, naming the folder it holds and
  # the folder the migration would move it to.
  migration_report = tasks.find do |task|
    task.key?("ansible.builtin.debug") &&
      task["loop"].to_s.include?("kapowarr_volume_folder_migrations")
  end
  failures << "Kapowarr must report each volume folder it would move" unless
    migration_report &&
    migration_report.dig("ansible.builtin.debug", "msg").to_s.include?("item.folder") &&
    migration_report.dig("ansible.builtin.debug", "msg").to_s.include?("item.target")

  # The parent mount moved the container path Kapowarr stores as its root folder
  # and as the prefix of every volume's folder, and Kapowarr v1.3.1 exposes no
  # route that can relabel a stored prefix whose files no longer resolve --
  # RootFolders.rename() moves every file with shutil.move. So a deployment
  # holding the superseded prefix must fail the run, not be migrated and not be
  # converged around: without the refusal the role would declare the new root
  # *beside* the old one and report success over a library no volume is attached
  # to. The refusal is unconditional by design; a one-convergence input would
  # authorize a migration that cannot be performed.
  root_migration_plan = tasks.find do |task|
    task.dig("ansible.builtin.set_fact")&.key?("kapowarr_library_root_migrations")
  end
  failures << "Kapowarr must resolve the library roots the declared one supersedes" if
    root_migration_plan.nil?
  failures << "the superseded library roots must be derived from what the deployment holds" unless
    root_migration_plan.to_s.include?("kapowarr_root_folders") &&
    root_migration_plan.to_s.include?("kapowarr_library_root")
  root_migration_refusal = tasks.find do |task|
    task.key?("ansible.builtin.assert") &&
      Array(task.dig("ansible.builtin.assert", "that")).any? do |value|
        value.to_s.include?("kapowarr_library_root_migrations")
      end
  end
  failures << "a superseded Kapowarr library root must refuse the run" if root_migration_refusal.nil?
  failures << "the superseded library root refusal must take no one-convergence input" if
    root_migration_refusal.to_s.include?("kapowarr_library_root_migration_allowed")
  # An operator whose library reads as empty after this deployment has to be told
  # the comics are untouched, because Kapowarr itself created the empty directory:
  # RootFolders.__gather_extra_data() calls create_folder() on a stored root that
  # is no longer a directory, so the role's own read conjures it.
  failures << "the superseded library root refusal must say the host library is intact" unless
    root_migration_refusal.to_s.match?(/no comic has been deleted/i)
  # Worthless after the fact: the create is the mutation it exists to prevent.
  root_create = tasks.find do |task|
    task.dig("ansible.builtin.uri", "method") == "POST" &&
      task.dig("ansible.builtin.uri", "url").to_s.include?("/api/rootfolder")
  end
  failures << "Kapowarr must create the declared library root when it owns none" if root_create.nil?
  if root_migration_refusal && root_create
    failures << "the superseded library root refusal must precede the root folder create" unless
      tasks.index(root_migration_refusal) < tasks.index(root_create)
  end

  # Kapowarr records a credential-free auth POST as a failed login, so every
  # anonymous probe is gated on the authentication mode the role has already
  # read. At mode 2 the authored pair is in force and an empty body can only be
  # refused, so an ungated probe writes a WARNING into the application's own
  # security log on every converge and buries a real attempt among its own. The
  # gate is asserted here because a comment cannot fail a run: the probe still
  # has to exist for the instance that is genuinely open.
  anonymous_probes = tasks.select do |task|
    task.dig("ansible.builtin.uri", "url") == "{{ kapowarr_api }}/api/auth" &&
      task.dig("ansible.builtin.uri", "body") == {}
  end
  failures << "Kapowarr must probe the login without a credential" if anonymous_probes.empty?
  anonymous_probes.each do |task|
    probe_conditions = Array(task["when"]).join(" ")
    failures << "#{task.fetch('name')} must be gated on the authentication mode already read" unless
      probe_conditions.include?("authentication_method") && probe_conditions.include?("2")
  end

  verification = tasks.select { |task| Array(task["tags"]).include?("platform_verify_kapowarr") }
  verification_urls = verification.filter_map { |task| task.dig("ansible.builtin.uri", "url") }
  failures << "Kapowarr verification must read its unauthenticated public endpoint" unless
    verification_urls.include?("{{ kapowarr_api }}/api/public")
  authenticated = verification.find do |task|
    task.dig("ansible.builtin.uri", "body", "password") == "{{ vault_kapowarr_admin_password }}"
  end
  failures << "Kapowarr verification must authenticate as the vault administrator" if
    authenticated.nil?
  anonymous = verification.find do |task|
    body = task.dig("ansible.builtin.uri", "body")
    task.dig("ansible.builtin.uri", "url") == "{{ kapowarr_api }}/api/auth" && body == {}
  end
  failures << "Kapowarr verification must probe the login without a credential" if anonymous.nil?
  roots = verification.find do |task|
    task.dig("ansible.builtin.uri", "url").to_s.include?("/api/rootfolder")
  end
  failures << "Kapowarr verification must read the library roots it owns" if roots.nil?
  settings_verification = verification.find do |task|
    task.dig("ansible.builtin.uri", "url").to_s.include?("/api/settings")
  end
  failures << "Kapowarr verification must read the settings it declares" if
    settings_verification.nil?

  # Every probe accepts any status and defers to the assertion, so a drifted
  # credential fails with a diagnosis rather than inside the redacted request.
  # The assertion is what pins the outcomes.
  [authenticated, anonymous, roots].compact.each do |task|
    label = task.fetch("name")
    failures << "#{label} must accept any status and defer to the assertion" unless
      task.dig("ansible.builtin.uri", "status_code") == "{{ range(100, 600) | list }}" &&
      task["failed_when"] == false
  end
  outcome_assertion = verification.find { |task| task.key?("ansible.builtin.assert") }
  conditions = Array(outcome_assertion&.dig("ansible.builtin.assert", "that"))
  failures << "Kapowarr verification must assert its exact access and ownership outcomes" unless
    conditions.any? do |value|
      value.include?("kapowarr_verify_public") && value.include?("authentication_method") &&
        value.include?("2")
    end &&
    conditions.any? do |value|
      value.include?("kapowarr_verify_identity.status") && value.include?("200")
    end &&
    conditions.any? do |value|
      value.include?("kapowarr_verify_anonymous.status") && value.include?("401")
    end &&
    conditions.any? do |value|
      value.include?("kapowarr_verify_roots") && value.include?("kapowarr_library_root")
    end &&
    conditions.any? do |value|
      value.include?("kapowarr_verify_settings") && value.include?("kapowarr_settings")
    end &&
    conditions.any? do |value|
      value.include?("kapowarr_verify_settings") &&
        value.include?("kapowarr_service_preference")
    end
  # The diagnosis is the point of deferring, so it must not be redacted away.
  failures << "the Kapowarr outcome assertion must stay readable" if
    outcome_assertion && outcome_assertion["no_log"]

  # The folder shape is verified, not merely migrated: a volume added while a
  # hand-edited template was in force, or a folder renamed in the web interface,
  # puts a series back under a name Komga titles wrongly, and nothing in
  # Kapowarr reports it. The migration alone would fix the library once and go
  # quiet.
  folder_assertion = verification.select { |task| task.key?("ansible.builtin.assert") }.find do |task|
    Array(task.dig("ansible.builtin.assert", "that")).any? do |value|
      value.to_s.include?("kapowarr_verify_volume_folder_drift")
    end
  end
  failures << "Kapowarr verification must assert every volume folder is the derived one" if
    folder_assertion.nil?
  # The drift list is resolved from a loop over what the application reported, so
  # an empty list is a real verdict only when both reads answered for every
  # volume. Without that floor a 401 verifies a library of nothing.
  folder_conditions = Array(folder_assertion&.dig("ansible.builtin.assert", "that")).join(" ")
  failures << "the Kapowarr volume folder assertion must require both reads to have answered" unless
    folder_assertion && folder_conditions.include?("kapowarr_verify_volumes.status") &&
    folder_conditions.include?("kapowarr_verify_rename_plans.results")
  # An unauthorized Kapowarr answers `result: {}` where the library was, and a
  # loop over that mapping dies with a type error instead of with the assertion's
  # diagnosis. The per-volume verification read loops the normalized list for
  # that reason, not for tidiness.
  failures << "the Kapowarr verification must loop a normalized volume list" unless
    rename_reads.any? do |task|
      Array(task["tags"]).include?("platform_verify_kapowarr") &&
        task["loop"].to_s.include?("kapowarr_verify_volume_list")
    end

  failures << "Kapowarr verification reads must not claim a change" unless
    verification.all? do |task|
      !task.key?("ansible.builtin.uri") ||
        (task["changed_when"] == false && task["check_mode"] == false)
    end
end

unless failures.empty?
  warn failures.join("\n")
  exit 1
end
