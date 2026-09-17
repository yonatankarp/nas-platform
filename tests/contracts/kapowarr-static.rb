#!/usr/bin/env ruby
# The static half of the Kapowarr service contract: the Compose definition, the
# Mac override, the role's task order, its declared inputs and the confinement
# of its volume folder migration, all decided from the repository alone with
# nothing deployed.
#
# usage: kapowarr-static.rb REPOSITORY
#
require "digest"
require "yaml"

root = ARGV.fetch(0)
failures = []
required = %w[
  roles/kapowarr/defaults/main.yml
  roles/kapowarr/meta/argument_specs.yml
  roles/kapowarr/tasks/main.yml
  roles/kapowarr/tasks/pre_upgrade_backup.yml
  roles/kapowarr/templates/env.j2
  services/kapowarr/compose.yml
  services/kapowarr/compose.mac.yml
  services/kapowarr/compose.integration.yml
  services/kapowarr/tasks.py
  inventory/group_vars/all/service_kapowarr.yml
  inventory/group_vars/all/media_libraries.yml
  inventory/group_vars/all/media_acquisition.yml
]
required.each do |relative|
  failures << "missing #{relative}" unless File.file?(File.join(root, relative))
end

# Task files are flattened so a task on a block's rescue or always path is still
# a task the role executes.
require File.join(ENV.fetch("PLATFORM_CONTRACT_REPO_DIR"), "tests", "nas_storage_support")
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
      "${KAPOWARR_BOOKS_PATH:?}:/data/books",
      "${PLATFORM_CURRENT_DIR:?}/services/kapowarr/tasks.py:/app/backend/features/tasks.py:ro"
    ]

  # The carried task handler patch (#696) is upstream code mounted over the
  # image's own, so it is only correct against the image it was derived from. Its
  # trailer records that image and the sha256 of the upstream file; the image must
  # be the Compose pin exactly, and reverting the two guarded joins must give back
  # that upstream file byte for byte. A Renovate bump fails here until the patch
  # is derived again or deleted, rather than mounting old code over new.
  patch_source = File.read(File.join(root, "services/kapowarr/tasks.py"))
  patch_marker = "\n# --- nas-platform carried patch (#696) ---\n"
  patch_body, _marker, patch_trailer = patch_source.partition(patch_marker)
  patch_record = patch_trailer.lines.filter_map do |line|
    match = line.match(/\A# (upstream_sha256|image): (\S+)\n?\z/)
    match && [match[1], match[2]]
  end.to_h
  failures << "the Kapowarr patch must record the image it was derived from as the Compose pin" unless
    !patch_trailer.empty? && patch_record["image"] == service["image"]
  patch_guards = {
    "            if self.queue[0]['thread'].is_alive(): self.queue[0]['thread'].join()\n" =>
      "            self.queue[0]['thread'].join()\n",
    "        if task['thread'].is_alive(): task['thread'].join()\n" =>
      "        task['thread'].join()\n"
  }
  failures << "the Kapowarr patch must guard both task thread joins exactly once" unless
    patch_guards.keys.all? { |guarded| patch_body.scan(guarded).length == 1 }
  reverted = patch_guards.reduce(patch_body) { |body, (guarded, upstream)| body.sub(guarded, upstream) }
  failures << "the Kapowarr patch must be the recorded upstream file with only the two joins guarded" unless
    patch_record["upstream_sha256"].to_s.match?(/\A\h{64}\z/) &&
    Digest::SHA256.hexdigest(reverted) == patch_record["upstream_sha256"]

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
  # The composed inventory, not one file: the two paths checked below are the
  # comics library and its staging root, which are shared media groups rather
  # than anything kapowarr declares for itself.
  declared_paths = NasStorage.entries(root).map { |entry| entry.fetch("path") }
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
  # A changed bind source does not recreate a container; a changed label does.
  # So the patch's own sha256, read from the release on the target, reaches a
  # label, and editing the patch recreates Kapowarr instead of leaving the old
  # file loaded (the alert relay's arrangement in services/dozzle).
  failures << "Kapowarr must label its container with the carried patch's sha256" unless
    service.dig("labels", "dev.nas-platform.kapowarr.task-patch-sha256") == "${KAPOWARR_TASK_PATCH_SHA256:?}"
  failures << "Kapowarr env must export the carried patch's release sha256 exactly once" unless
    env_assignments.select { |name, _value| name == "KAPOWARR_TASK_PATCH_SHA256" } ==
      [["KAPOWARR_TASK_PATCH_SHA256", "{{ kapowarr_task_patch_sha256 }}"]]
  failures << "Kapowarr env must export the release root the patch is mounted from exactly once" unless
    env_assignments.select { |name, _value| name == "PLATFORM_CURRENT_DIR" } ==
      [["PLATFORM_CURRENT_DIR", "{{ platform_current_dir }}"]]
  # Kapowarr reads no credential from its environment: every one lives in its own
  # database. A credential appearing here would be a copy nothing consumes.
  failures << "the Kapowarr environment must carry no vault credential" if
    env_assignments.any? { |_name, value| value.include?("vault_") }

  tasks = flatten_tasks(
    YAML.safe_load_file(File.join(root, "roles/kapowarr/tasks/main.yml"), aliases: true)
  )
  patch_stat_index = tasks.index do |task|
    stat = task["ansible.builtin.stat"]
    task["register"] == "kapowarr_task_patch" && stat.is_a?(Hash) &&
      stat["path"] == "{{ platform_current_dir }}/services/kapowarr/tasks.py" &&
      stat["follow"] == false && stat["get_checksum"] == true && stat["checksum_algorithm"] == "sha256"
  end
  env_render_index = tasks.index { |task| task.dig("ansible.builtin.template", "src") == "env.j2" }
  failures << "Kapowarr must checksum the release's carried patch before rendering its environment" unless
    patch_stat_index && env_render_index && patch_stat_index < env_render_index
  # One `up` here since #646, which is the deployment. The bounded recovery that
  # #537 bracketed it with moved to roles/container_health/tasks/recover.yml --
  # this role held 114 lines of it byte-identical with five others -- so what is
  # counted here is the include that spends it rather than the force-recreate
  # itself. Counted separately from the deployment rather than as a total, so a
  # second plain deployment is still refused and a recovery included twice in one
  # converge is still refused; roles/container_health/tasks/recover.yml holding
  # exactly one force-recreate is tests/container_health_wiring_test.rb's.
  compose_ups = tasks.select { |task| task.dig("community.docker.docker_compose_v2", "state") == "present" }
  failures << "Kapowarr must deploy through docker_compose_v2" unless
    compose_ups.count { |task| !task["community.docker.docker_compose_v2"].key?("recreate") } == 1
  failures << "Kapowarr must force-recreate a stuck container exactly once per converge" unless
    tasks.count { |task|
      task.dig("ansible.builtin.include_role", "name") == "container_health" &&
        task.dig("ansible.builtin.include_role", "tasks_from") == "recover"
    } == 1
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
  # every converge. The service order is excluded for a different reason: since
  # v1.3.2 it is not a setting at all but the GetComics indexer's
  # gc_service_preference (#671), still validated as a permutation of the
  # deployed version's service list, so it is declared as a partial ordering and
  # merged over the order that indexer holds.
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

  # #671: Kapowarr migrates its own store on start, and v1.3.2 took a v1.3.1
  # store from database version 45 to 51 with no way back. So a pin older than
  # one that has already run must be refused before Compose recreates the
  # container from it, and the guard must judge Kapowarr's own containers.
  deploy_index = tasks.index do |task|
    compose = task["community.docker.docker_compose_v2"]
    compose.is_a?(Hash) && compose["state"] == "present" && !compose.key?("recreate")
  end
  guard_index = tasks.index do |task|
    task.dig("ansible.builtin.include_role", "name") == "image_downgrade_guard"
  end
  failures << "Kapowarr must refuse an image older than the store already on disk" unless
    guard_index && deploy_index && guard_index < deploy_index
  guard_vars = guard_index ? (tasks[guard_index]["vars"] || {}) : {}
  failures << "the Kapowarr downgrade guard must judge Kapowarr's own containers" unless
    guard_vars["image_downgrade_guard_service_name"] == "kapowarr" &&
    guard_vars["image_downgrade_guard_compose_service"] == "kapowarr" &&
    guard_vars["image_downgrade_guard_project_name"] == "{{ kapowarr_compose_project_name }}"

  # The guard refuses going back; the pre-upgrade copy is what makes going back
  # possible at all. Neither image offers an on-demand backup, so the store is
  # copied from a stopped container, between the guard and the deployment.
  backup_import = tasks.index do |task|
    task["ansible.builtin.import_tasks"] == "pre_upgrade_backup.yml"
  end
  failures << "Kapowarr must copy its store aside between the downgrade guard and the deployment" unless
    backup_import && guard_index && deploy_index &&
    guard_index < backup_import && backup_import < deploy_index
  backup_document = YAML.safe_load_file(File.join(root, "roles/kapowarr/tasks/pre_upgrade_backup.yml"),
                                        aliases: true)
  backup_tasks = flatten_tasks(backup_document)
  # The block that stops the container and copies the store, and its rescue. The
  # rescue's tasks run only after a failure inside the block, so they are held to
  # their own properties below rather than to the pending-upgrade gate.
  backup_unit = Array(backup_document).find do |task|
    task.is_a?(Hash) && Array(task["block"]).any? { |inner| inner.is_a?(Hash) && inner.key?("ansible.builtin.copy") }
  end
  backup_rescue = flatten_tasks(backup_unit&.fetch("rescue", nil))
  pending_fact = backup_tasks.find do |task|
    task.dig("ansible.builtin.set_fact")&.key?("kapowarr_upgrade_pending")
  end.to_s
  failures << "the Kapowarr pre-upgrade copy must key on the image the container was created from" unless
    pending_fact.include?("kapowarr_deployed_image != kapowarr_pinned_image")
  # A copy on every converge would never report a converged run, and --check
  # must stop and copy nothing.
  backup_mutations = (backup_tasks - backup_rescue).select do |task|
    %w[community.docker.docker_compose_v2 ansible.builtin.find ansible.builtin.file ansible.builtin.copy]
      .any? { |name| task.key?(name) }
  end
  failures << "the Kapowarr pre-upgrade copy must act only on a pending upgrade outside --check" unless
    backup_mutations.length >= 5 && backup_mutations.all? do |task|
      conditions = Array(task["when"]).join(" ")
      conditions.include?("kapowarr_upgrade_pending") && conditions.include?("not ansible_check_mode")
    end
  failures << "the Kapowarr pre-upgrade copy must be reported under --check" unless
    backup_tasks.any? do |task|
      conditions = Array(task["when"])
      task.key?("ansible.builtin.debug") && conditions.include?("ansible_check_mode") &&
        conditions.join(" ").include?("kapowarr_upgrade_pending")
    end
  # Without recreate: never the stop first replaces the container with one on the
  # new pin, and a failed copy no longer reads as a pending upgrade next time.
  backup_stop = backup_tasks.find { |task| task.key?("community.docker.docker_compose_v2") }
  failures << "the Kapowarr pre-upgrade stop must stop the old container rather than recreate it" unless
    backup_stop && backup_stop.dig("community.docker.docker_compose_v2", "state") == "stopped" &&
    backup_stop.dig("community.docker.docker_compose_v2", "recreate") == "never"
  # The copy carries every credential the store holds, the ComicVine key among them.
  backup_copy = backup_tasks.find { |task| task.key?("ansible.builtin.copy") }
  backup_directory = backup_tasks.find { |task| task.dig("ansible.builtin.file", "state") == "directory" }
  failures << "the Kapowarr pre-upgrade copy must be private" unless
    backup_copy && backup_copy.dig("ansible.builtin.copy", "mode") == "0600" &&
    backup_directory && backup_directory.dig("ansible.builtin.file", "mode") == "0700"
  # A stop with no completed copy after it used to leave Kapowarr exited on every
  # later converge. The rescue starts the same container again, which is only the
  # old image under recreate: never, and still fails, so no upgrade is taken
  # without a copy.
  rescue_start = backup_rescue.find do |task|
    start = task["community.docker.docker_compose_v2"]
    start.is_a?(Hash) && start["state"] == "present" && Array(start["services"]) == ["kapowarr"]
  end
  start_index = rescue_start ? backup_rescue.index(rescue_start) : 0
  failures << "the Kapowarr pre-upgrade copy must start the old container again when it fails" unless
    backup_unit && Array(backup_unit["block"]).include?(backup_stop) &&
    backup_unit["always"].nil? &&
    rescue_start && rescue_start.dig("community.docker.docker_compose_v2", "recreate") == "never" &&
    start_index < backup_rescue.length - 1 &&
    backup_rescue.first(start_index).none? { |task| task.key?("ansible.builtin.fail") } &&
    backup_rescue.all? { |task| !task.key?("community.docker.docker_compose_v2") || task.dig("community.docker.docker_compose_v2", "recreate") == "never" }
  # The check ahead of the stop does not cover a store lost after it, and the old
  # image started over a missing store creates an empty one that the next
  # converge copies and upgrades over -- measured. So the rescue reads the store
  # again first and the start is conditional on exactly that read.
  # Exactly this shape, because every looser reading was measured to let the
  # original bug back in: a condition naming the read taken before the stop, an
  # `or true`, `exists` (true for a directory and a dangling symlink), a read of
  # the write-ahead log, and a read that fails the rescue on a permission error.
  rescue_store_read = backup_rescue.find { |task| task.key?("ansible.builtin.stat") }
  failures << "the Kapowarr pre-upgrade copy must not start the old container over a missing store" unless
    rescue_start.nil? || (
      rescue_store_read && backup_rescue.index(rescue_store_read) < start_index &&
      rescue_store_read.dig("ansible.builtin.stat", "path") == "{{ kapowarr_config_host_path }}/Kapowarr.db" &&
      rescue_store_read["failed_when"] == false &&
      Array(rescue_start["when"]) == ["#{rescue_store_read['register']}.stat.isreg | default(false)"]
    )
  failures << "the Kapowarr pre-upgrade copy must still fail the run after starting the old container" unless
    backup_rescue.last&.key?("ansible.builtin.fail")

  # Since v1.3.2 the service order is gc_service_preference on the GetComics
  # indexer, not a setting (#671). The indexer read must be a redacted, real,
  # changeless read, or the write decides from nothing under --check.
  indexer_read = tasks.find do |task|
    task.dig("ansible.builtin.uri", "method") == "GET" &&
      task.dig("ansible.builtin.uri", "url").to_s.include?("/api/indexers") &&
      !Array(task["tags"]).include?("platform_verify_kapowarr")
  end
  failures << "Kapowarr must read its deployed indexers before declaring the service order" if
    indexer_read.nil?
  failures << "the Kapowarr indexer read must be a redacted, real, changeless read" unless
    indexer_read && indexer_read["changed_when"] == false &&
    indexer_read["check_mode"] == false && indexer_read["no_log"] == true
  # Compose's dry run recreates nothing, so --check before the upgrade reaches
  # the older image, which has no indexer interface. That 404 is the review and
  # must not fail it; on a live run the pinned image is running and a 404 must.
  # The verdict is an assert rather than the redacted read's own status list,
  # because a redacted task that fails says only "censored".
  indexer_read_assert = tasks.find do |task|
    Array(task.dig("ansible.builtin.assert", "that")).any? do |value|
      value.to_s.include?("kapowarr_indexers.status")
    end
  end
  failures << "the Kapowarr indexer read may accept a 404 only under --check" unless
    Array(indexer_read_assert&.dig("ansible.builtin.assert", "that")).join(" ")
      .include?("or (ansible_check_mode and kapowarr_indexers.status | default(0) | int == 404)")
  failures << "the Kapowarr indexer read must fail with its status rather than redacted" unless
    indexer_read && indexer_read["failed_when"] == false && indexer_read_assert &&
    indexer_read_assert.dig("ansible.builtin.assert", "fail_msg").to_s.include?("kapowarr_indexers.status") &&
    tasks.index(indexer_read) < tasks.index(indexer_read_assert)
  # A 200 whose body is not a list of records would otherwise count as zero
  # GetComics indexers and tell the operator to add one back.
  failures << "the Kapowarr indexer read must refuse a 200 whose body is not a list of indexers" unless
    Array(indexer_read_assert&.dig("ansible.builtin.assert", "that")).join(" ")
      .include?("kapowarr_indexers.json.result | reject('mapping') | list | length == 0")
  # The indexer interface is not a partial merge: it reads every field out of the
  # body and refuses a missing one. A write must restate the record it read,
  # replacing only the order, or it would own fields nothing declares. It reaches
  # getcomics.org, so it must also stay off a converged host.
  indexer_write = tasks.find do |task|
    task.dig("ansible.builtin.uri", "method") == "PUT" &&
      task.dig("ansible.builtin.uri", "url").to_s.include?("/api/indexers/")
  end
  indexer_conditions = Array(indexer_write&.fetch("when", nil)).join(" ")
  failures << "the Kapowarr service order write must be gated on the resolved order" unless
    indexer_write && indexer_conditions.include?("kapowarr_service_preference_declared") &&
    indexer_conditions.include?("kapowarr_service_preference_deployed") &&
    indexer_conditions.include?("ansible_check_mode")
  failures << "the Kapowarr service order write must restate the indexer it read" unless
    indexer_write &&
    indexer_write.dig("ansible.builtin.uri", "body").to_s.include?("kapowarr_getcomics_indexers[0]") &&
    indexer_write.dig("ansible.builtin.uri", "body").to_s.include?("combine")
  failures << "the Kapowarr service order write must stay redacted" unless
    indexer_write && indexer_write["no_log"] == true
  # Kapowarr tests the indexer against getcomics.org inside this request, with a
  # 30s timeout of its own, so the request needs a bound above that and below an
  # unbounded wait, and its failure has to say so where the redacted task cannot.
  write_timeout = indexer_write&.dig("ansible.builtin.uri", "timeout")
  failures << "the Kapowarr service order write must bound the call Kapowarr makes to getcomics.org" unless
    write_timeout.is_a?(Integer) && write_timeout.between?(31, 120)
  write_assert = tasks.find do |task|
    Array(task.dig("ansible.builtin.assert", "that")).any? do |value|
      value.to_s.include?("kapowarr_service_order_write.status")
    end
  end
  # The message and the task vars it selects its explanation from.
  write_message = [write_assert&.dig("ansible.builtin.assert", "fail_msg"),
                   *Array((write_assert || {})["vars"]&.values)].join(" ")
  failures << "the Kapowarr service order write must fail with its status and the getcomics.org cause" unless
    indexer_write && indexer_write["failed_when"] == false && write_assert &&
    write_message.include?("kapowarr_service_order_write.status") && write_message.include?("ClientNotWorking") &&
    Array(write_assert["when"]).join(" ").include?("kapowarr_service_preference_declared") &&
    tasks.index(indexer_write) < tasks.index(write_assert)
  # A -1 at the bound is Kapowarr still testing getcomics.org; a shorter one is a
  # connection to Kapowarr that never reached that test. Anchored on the task's
  # own timeout, so moving the bound without the message fails here. A missing
  # assertion is the legible-failure check's to name.
  failures << "the Kapowarr service order write must tell a refused connection from its own timeout" unless
    write_assert.nil? || write_message.include?("kapowarr_service_order_write.elapsed | default(0) | int >= #{write_timeout}")
  # None means the indexer was deleted and two means the database was edited
  # outside the application; either is refused, and before the write.
  indexer_refusal = tasks.find do |task|
    Array(task.dig("ansible.builtin.assert", "that")).any? do |value|
      value.to_s.include?("kapowarr_getcomics_indexers | length == 1")
    end
  end
  failures << "Kapowarr must refuse anything but exactly one GetComics indexer" unless
    indexer_refusal && indexer_write && tasks.index(indexer_refusal) < tasks.index(indexer_write)

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
    YAML.safe_load_file(File.join(root, "inventory/group_vars/all/service_kapowarr.yml"))
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
  indexers_verification = verification.find do |task|
    task.dig("ansible.builtin.uri", "url").to_s.include?("/api/indexers")
  end
  failures << "Kapowarr verification must read the GetComics indexer holding the service order" if
    indexers_verification.nil?

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
      value.include?("kapowarr_verify_getcomics_indexers") && value.include?("length == 1")
    end &&
    conditions.any? do |value|
      value.include?("kapowarr_verify_getcomics_indexers") &&
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
  # Every violation, one per line, each line naming the contract that authored it.
  # The prefix is not decoration: tests/<service>_contract_test.rb requires a row
  # that says "this must be refused" to see it, so a Ruby backtrace or a shell
  # diagnostic can no longer stand in for a refusal (#352).
  warn failures.map { |failure| "Kapowarr contract failed: #{failure}" }.join("\n")
  exit 1
end
