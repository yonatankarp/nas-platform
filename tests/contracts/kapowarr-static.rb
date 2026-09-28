#!/usr/bin/env ruby
# Static half of the Kapowarr service contract, decided from the repository alone.
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
  roles/pre_upgrade_backup/tasks/main.yml
  roles/pre_upgrade_backup/tasks/pending.yml
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

# Flattened so rescue/always tasks still count as tasks the role executes.
require File.join(ENV.fetch("PLATFORM_CONTRACT_REPO_DIR"), "tests", "nas_storage_support")
require File.join(ENV.fetch("PLATFORM_CONTRACT_REPO_DIR"), "tests", "policy_support")
include PolicySupport

# Parsed as assignments: a commented-out sample would satisfy a substring search.
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

  # Self-contained: no indexer or download client, so no shared control network.
  failures << "Kapowarr must not join the shared media control network" if
    compose.key?("networks") || service.key?("networks")

  failures << "Kapowarr must not override the container user" if service.key?("user")
  {
    "PUID" => "${NAS_UID:?}",
    "PGID" => "${NAS_GID:?}"
  }.each do |name, expected|
    failures << "Kapowarr must take the platform identity as #{name}" unless
      service.dig("environment", name) == expected
  end

  # Library and staging must share one bind mount: rename(2) refuses to cross a
  # mount boundary, so a mount per leaf turns every import into a full copy.
  failures << "Kapowarr must mount its database and one parent of its library and staging" unless
    Array(service["volumes"]) == [
      "${KAPOWARR_CONFIG_PATH:?}:/app/db",
      "${KAPOWARR_BOOKS_PATH:?}:/data/books",
      "${PLATFORM_CURRENT_DIR:?}/services/kapowarr/tasks.py:/app/backend/features/tasks.py:ro"
    ]

  # The carried patch (#696) must match the Compose pin exactly and revert to the
  # recorded upstream sha256, so a bump fails here until the patch is re-derived.
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

  failures << "Kapowarr must publish the catalog web UI port" unless
    Array(service["ports"]) == ["5656:5656"]
  mac = YAML.safe_load_file(File.join(root, "services/kapowarr/compose.mac.yml"))
  failures << "the Mac override must republish the web UI on the harness port" unless
    mac.dig("services", "kapowarr", "ports") == ["${KAPOWARR_HOST_PORT:?}:5656"]

  # The image ships neither curl nor wget.
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
  # Both paths must sit under the one mount and resolve to a nas_storage path;
  # Kapowarr answers a missing download folder with FolderNotFound.
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
  # Otherwise downloads stage into /app/temp_downloads in the writable layer.
  # Stored force-suffixed with a separator, and literal: the runtime half compares
  # this YAML to the live value, so a Jinja reference could never match.
  failures << "Kapowarr must declare the download folder the parent mount moved" unless
    defaults.dig("kapowarr_settings", "download_folder") == "#{defaults['kapowarr_staging_root']}/"

  env_assignments = environment_assignments(
    File.join(root, "roles/kapowarr/templates/env.j2")
  )
  failures << "Kapowarr env must render the CPU set exactly once" unless
    env_assignments.select { |name, _value| name == "PLATFORM_CONTAINER_CPUSET" } ==
      [["PLATFORM_CONTAINER_CPUSET", "{{ platform_effective_container_cpuset }}"]]
  failures << "Kapowarr env must export the host share as the single media bind source" unless
    env_assignments.select { |name, _value| name.start_with?("KAPOWARR_") && name.end_with?("_PATH") } ==
      [["KAPOWARR_CONFIG_PATH", "{{ kapowarr_config_host_path }}"],
       ["KAPOWARR_BOOKS_PATH", "{{ kapowarr_books_host_path }}"]]
  # A changed label recreates the container; a changed bind source does not.
  failures << "Kapowarr must label its container with the carried patch's sha256" unless
    service.dig("labels", "dev.nas-platform.kapowarr.task-patch-sha256") == "${KAPOWARR_TASK_PATCH_SHA256:?}"
  failures << "Kapowarr env must export the carried patch's release sha256 exactly once" unless
    env_assignments.select { |name, _value| name == "KAPOWARR_TASK_PATCH_SHA256" } ==
      [["KAPOWARR_TASK_PATCH_SHA256", "{{ kapowarr_task_patch_sha256 }}"]]
  failures << "Kapowarr env must export the release root the patch is mounted from exactly once" unless
    env_assignments.select { |name, _value| name == "PLATFORM_CURRENT_DIR" } ==
      [["PLATFORM_CURRENT_DIR", "{{ platform_current_dir }}"]]
  # Every Kapowarr credential lives in its own database.
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
  # Deployment and the shared recovery include are counted separately (#646).
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

  # The identity pair is a request body, which a module result renders in full.
  credential_tasks = tasks.select do |task|
    task.to_s.match?(/vault_kapowarr_admin_(?:username|password)/)
  end
  failures << "every Kapowarr task naming the administrator must use no_log" unless
    credential_tasks.length >= 4 && credential_tasks.all? { |task| task["no_log"] == true }

  # Kapowarr validates a ComicVine key against comicvine.gamespot.com, so no
  # converge may submit it.
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

  # Unconditional, it would rewrite the login on every converge.
  identity_write = tasks.find do |task|
    task.dig("ansible.builtin.uri", "method") == "PUT" &&
      task.to_s.include?("auth_password")
  end
  identity_conditions = Array(identity_write&.fetch("when", nil)).join(" ")
  failures << "the Kapowarr identity write must be gated on the deployed identity" unless
    identity_write && identity_conditions.include?("kapowarr_identity_current") &&
    identity_conditions.include?("ansible_check_mode")

  # Kapowarr masks stored credentials on read, so declaring one never converges.
  # The service order is the GetComics indexer's gc_service_preference since
  # v1.3.2 (#671), not a setting.
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
    # The runtime half compares this mapping as parsed YAML, so a Jinja reference
    # converges on the target but never matches in the lane.
    templated = declared_settings.select { |_key, value| value.to_s.include?("{{") }
    failures << "the declared Kapowarr settings must name values, not templates: " \
                "#{templated.keys.join(', ')}" unless templated.empty?
    # Komga indexes the directory these name.
    failures << "the declared Kapowarr settings must own the library naming templates" unless
      (%w[volume_folder_naming file_naming] - declared_settings.keys).empty?
  end
  failures << "Kapowarr must declare its download service order" if
    Array(defaults["kapowarr_service_preference"]).empty?

  # #671: Kapowarr migrates its own store one-way, so an older pin is refused
  # before Compose recreates the container.
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

  # The store is copied from a stopped container, between the guard and the
  # deployment (#836).
  backup_import = tasks.index do |task|
    task.dig("ansible.builtin.include_role", "name") == "pre_upgrade_backup"
  end
  failures << "Kapowarr must copy its store aside between the downgrade guard and the deployment" unless
    backup_import && guard_index && deploy_index &&
    guard_index < backup_import && backup_import < deploy_index
  backup_vars = backup_import ? (tasks[backup_import]["vars"] || {}) : {}
  failures << "the Kapowarr pre-upgrade copy must take Kapowarr's own store" unless
    backup_vars["pre_upgrade_backup_service_name"] == "kapowarr" &&
    backup_vars["pre_upgrade_backup_compose_service"] == "kapowarr" &&
    backup_vars["pre_upgrade_backup_project_name"] == "{{ kapowarr_compose_project_name }}" &&
    backup_vars["pre_upgrade_backup_store_dir"] == "{{ kapowarr_config_host_path }}" &&
    backup_vars["pre_upgrade_backup_store_file"] == "Kapowarr.db" &&
    backup_vars["pre_upgrade_backup_path"] == "{{ kapowarr_pre_upgrade_backup_path }}" &&
    # The role reads Kapowarr's pin itself (#858); a pin handed in would outrank it.
    !backup_vars.key?("pre_upgrade_backup_pinned_image")
  backup_document = YAML.safe_load_file(File.join(root, "roles/pre_upgrade_backup/tasks/main.yml"),
                                        aliases: true)
  backup_tasks = flatten_tasks(backup_document)
  # Rescue tasks run only after a failure, so they are checked separately.
  backup_unit = Array(backup_document).find do |task|
    task.is_a?(Hash) && Array(task["block"]).any? { |inner| inner.is_a?(Hash) && inner.key?("ansible.builtin.copy") }
  end
  backup_rescue = flatten_tasks(backup_unit&.fetch("rescue", nil))
  pending_include = backup_tasks.any? { |task| task["ansible.builtin.include_tasks"] == "pending.yml" }
  pending_tasks = flatten_tasks(YAML.safe_load_file(File.join(root, "roles/pre_upgrade_backup/tasks/pending.yml"),
                                                    aliases: true))
  failures << "the Kapowarr pre-upgrade copy must decide its upgrade in tasks/pending.yml" unless pending_include
  pending_fact = pending_tasks.find do |task|
    task.dig("ansible.builtin.set_fact")&.key?("pre_upgrade_backup_upgrade_pending")
  end.to_s
  failures << "the Kapowarr pre-upgrade copy must key on the image the container was created from" unless
    pending_fact.include?("pre_upgrade_backup_deployed_image != pre_upgrade_backup_pinned_image")
  backup_mutations = (backup_tasks - backup_rescue).select do |task|
    %w[community.docker.docker_compose_v2 ansible.builtin.find ansible.builtin.file ansible.builtin.copy]
      .any? { |name| task.key?(name) }
  end
  failures << "the Kapowarr pre-upgrade copy must act only on a pending upgrade outside --check" unless
    backup_mutations.length >= 5 && backup_mutations.all? do |task|
      conditions = Array(task["when"]).join(" ")
      conditions.include?("pre_upgrade_backup_upgrade_pending") && conditions.include?("not ansible_check_mode")
    end
  failures << "the Kapowarr pre-upgrade copy must be reported under --check" unless
    backup_tasks.any? do |task|
      conditions = Array(task["when"])
      task.key?("ansible.builtin.debug") && conditions.include?("ansible_check_mode") &&
        conditions.join(" ").include?("pre_upgrade_backup_upgrade_pending")
    end
  # Without recreate: never the stop replaces the container with the new pin.
  backup_stop = backup_tasks.find { |task| task.key?("community.docker.docker_compose_v2") }
  failures << "the Kapowarr pre-upgrade stop must stop the old container rather than recreate it" unless
    backup_stop && backup_stop.dig("community.docker.docker_compose_v2", "state") == "stopped" &&
    backup_stop.dig("community.docker.docker_compose_v2", "recreate") == "never"
  backup_copy = backup_tasks.find { |task| task.key?("ansible.builtin.copy") }
  backup_directory = backup_tasks.find { |task| task.dig("ansible.builtin.file", "state") == "directory" }
  failures << "the Kapowarr pre-upgrade copy must be private" unless
    backup_copy && backup_copy.dig("ansible.builtin.copy", "mode") == "0600" &&
    backup_directory && backup_directory.dig("ansible.builtin.file", "mode") == "0700"
  # The rescue restarts the old image so a failed copy never leaves Kapowarr exited.
  rescue_start = backup_rescue.find do |task|
    start = task["community.docker.docker_compose_v2"]
    start.is_a?(Hash) && start["state"] == "present" &&
      Array(start["services"]) == ["{{ pre_upgrade_backup_compose_service }}"]
  end
  start_index = rescue_start ? backup_rescue.index(rescue_start) : 0
  failures << "the Kapowarr pre-upgrade copy must start the old container again when it fails" unless
    backup_unit && Array(backup_unit["block"]).include?(backup_stop) &&
    backup_unit["always"].nil? &&
    rescue_start && rescue_start.dig("community.docker.docker_compose_v2", "recreate") == "never" &&
    start_index < backup_rescue.length - 1 &&
    backup_rescue.first(start_index).none? { |task| task.key?("ansible.builtin.fail") } &&
    backup_rescue.all? { |task| !task.key?("community.docker.docker_compose_v2") || task.dig("community.docker.docker_compose_v2", "recreate") == "never" }
  # The rescue re-reads the store before starting the old image, which would
  # otherwise create an empty store the next converge upgrades over. Each looser
  # reading of this shape was measured to let that back in.
  rescue_store_read = backup_rescue.find { |task| task.key?("ansible.builtin.stat") }
  failures << "the Kapowarr pre-upgrade copy must not start the old container over a missing store" unless
    rescue_start.nil? || (
      rescue_store_read && backup_rescue.index(rescue_store_read) < start_index &&
      rescue_store_read.dig("ansible.builtin.stat", "path") == "{{ pre_upgrade_backup_store_dir }}/{{ pre_upgrade_backup_store_file }}" &&
      rescue_store_read["failed_when"] == false &&
      Array(rescue_start["when"]) == ["#{rescue_store_read['register']}.stat.isreg | default(false)"]
    )
  failures << "the Kapowarr pre-upgrade copy must still fail the run after starting the old container" unless
    backup_rescue.last&.key?("ansible.builtin.fail")

  # The indexer read must be a real read under --check, or the write decides from nothing.
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
  # Under --check before the upgrade the older image has no indexer interface, so
  # a 404 is tolerated only then. An assert, because a redacted failure says "censored".
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
  failures << "the Kapowarr indexer read must refuse a 200 whose body is not a list of indexers" unless
    Array(indexer_read_assert&.dig("ansible.builtin.assert", "that")).join(" ")
      .include?("kapowarr_indexers.json.result | reject('mapping') | list | length == 0")
  # The indexer interface requires every field, so the write restates the record
  # read and changes only the order. It reaches getcomics.org, so never when converged.
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
  # Kapowarr tests the indexer with its own 30s timeout inside this request.
  write_timeout = indexer_write&.dig("ansible.builtin.uri", "timeout")
  failures << "the Kapowarr service order write must bound the call Kapowarr makes to getcomics.org" unless
    write_timeout.is_a?(Integer) && write_timeout.between?(31, 120)
  write_assert = tasks.find do |task|
    Array(task.dig("ansible.builtin.assert", "that")).any? do |value|
      value.to_s.include?("kapowarr_service_order_write.status")
    end
  end
  write_message = [write_assert&.dig("ansible.builtin.assert", "fail_msg"),
                   *Array((write_assert || {})["vars"]&.values)].join(" ")
  failures << "the Kapowarr service order write must fail with its status and the getcomics.org cause" unless
    indexer_write && indexer_write["failed_when"] == false && write_assert &&
    write_message.include?("kapowarr_service_order_write.status") && write_message.include?("ClientNotWorking") &&
    Array(write_assert["when"]).join(" ").include?("kapowarr_service_preference_declared") &&
    tasks.index(indexer_write) < tasks.index(write_assert)
  # A -1 at the bound is Kapowarr still testing getcomics.org; a shorter one never
  # reached that test.
  failures << "the Kapowarr service order write must tell a refused connection from its own timeout" unless
    write_assert.nil? || write_message.include?("kapowarr_service_order_write.elapsed | default(0) | int >= #{write_timeout}")
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
  # The read carries the API key in its query string.
  failures << "the Kapowarr settings read must be a redacted, real, changeless read" unless
    settings_read && settings_read["changed_when"] == false &&
    settings_read["check_mode"] == false && settings_read["no_log"] == true

  # A no-op write and a real one answer identically, so the write is gated on a diff.
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

  # The only mutation that moves a directory inside a media library.
  failures << "the Kapowarr volume folder migration must be pinned closed" unless
    defaults.fetch("kapowarr_volume_folder_migration_allowed", nil) == false
  # group_vars/all outranks role defaults, so the inventory must not hold true
  # either (#343). The move is taken with -e kapowarr_volume_folder_migration_allowed=true.
  failures << "the Kapowarr volume folder migration must be pinned closed in the inventory" unless
    YAML.safe_load_file(File.join(root, "inventory/group_vars/all/service_kapowarr.yml"))
        .fetch("kapowarr_volume_folder_migration_allowed", false) == false
  migration_option = YAML.safe_load_file(
    File.join(root, "roles/kapowarr/meta/argument_specs.yml")
  ).dig("argument_specs", "main", "options", "kapowarr_volume_folder_migration_allowed")
  failures << "the Kapowarr volume folder migration input must be a declared bool" unless
    migration_option.is_a?(Hash) && migration_option["type"] == "bool"

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
  # A volume marked as a custom folder is one Kapowarr stops re-deriving.
  migration_body = folder_migration&.dig("ansible.builtin.uri", "body") || {}
  failures << "the Kapowarr volume folder move must take the derived folder" unless
    migration_body["volume_folder"].nil? && migration_body["custom_folder"] == false
  rename_reads = tasks.select do |task|
    task.dig("ansible.builtin.uri", "url").to_s.include?("/rename?api_key=")
  end
  failures << "Kapowarr must read the application's own rename plan per volume" if
    rename_reads.length < 2
  rename_reads.each do |task|
    failures << "#{task.fetch('name')} must be a redacted, real, changeless read" unless
      task["changed_when"] == false && task["check_mode"] == false && task["no_log"] == true
  end
  # Confinement: the migration must not touch anything outside the comics library.
  # Naming the library runs deployment_bundle's containment check (symlinks).
  target_paths = tasks.find do |task|
    task.dig("vars", "deployment_target_service") == "kapowarr"
  end&.dig("vars", "deployment_target_extra_paths")
  failures << "Kapowarr must name the comics library among the paths it touches" unless
    Array(target_paths).include?("{{ kapowarr_comics_host_path }}")
  # Both the held and the previewed folder must be under the declared root.
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
  # A silent exclusion is indistinguishable from a converged library.
  unconfined_report = tasks.find do |task|
    task.key?("ansible.builtin.debug") &&
      task["loop"].to_s.include?("kapowarr_volume_folders_unconfined")
  end
  failures << "Kapowarr must report each volume folder it refuses as unconfined" if
    unconfined_report.nil?
  # The request names no path, so it is confined only while Kapowarr owns exactly
  # the declared root folder.
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
  if root_refusal && folder_migration
    failures << "the Kapowarr library root refusal must precede the volume folder move" unless
      tasks.index(root_refusal) < tasks.index(folder_migration)
  end

  migration_report = tasks.find do |task|
    task.key?("ansible.builtin.debug") &&
      task["loop"].to_s.include?("kapowarr_volume_folder_migrations")
  end
  failures << "Kapowarr must report each volume folder it would move" unless
    migration_report &&
    migration_report.dig("ansible.builtin.debug", "msg").to_s.include?("item.folder") &&
    migration_report.dig("ansible.builtin.debug", "msg").to_s.include?("item.target")

  # Kapowarr v1.3.1 cannot relabel a stored root prefix whose files no longer
  # resolve, so a superseded prefix fails the run unconditionally rather than
  # converging a new root beside the old one.
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
  # Kapowarr itself creates the empty directory on read of a stored root.
  failures << "the superseded library root refusal must say the host library is intact" unless
    root_migration_refusal.to_s.match?(/no comic has been deleted/i)
  root_create = tasks.find do |task|
    task.dig("ansible.builtin.uri", "method") == "POST" &&
      task.dig("ansible.builtin.uri", "url").to_s.include?("/api/rootfolder")
  end
  failures << "Kapowarr must create the declared library root when it owns none" if root_create.nil?
  if root_migration_refusal && root_create
    failures << "the superseded library root refusal must precede the root folder create" unless
      tasks.index(root_migration_refusal) < tasks.index(root_create)
  end

  # Kapowarr logs a credential-free auth POST as a failed login, so anonymous
  # probes are gated on the authentication mode already read.
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

  # Probes accept any status so the assertion can diagnose outside the redaction.
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
  failures << "the Kapowarr outcome assertion must stay readable" if
    outcome_assertion && outcome_assertion["no_log"]

  # Verified, not only migrated: later volumes or web-UI renames drift silently.
  folder_assertion = verification.select { |task| task.key?("ansible.builtin.assert") }.find do |task|
    Array(task.dig("ansible.builtin.assert", "that")).any? do |value|
      value.to_s.include?("kapowarr_verify_volume_folder_drift")
    end
  end
  failures << "Kapowarr verification must assert every volume folder is the derived one" if
    folder_assertion.nil?
  # Empty drift is a verdict only when both reads answered for every volume.
  folder_conditions = Array(folder_assertion&.dig("ansible.builtin.assert", "that")).join(" ")
  failures << "the Kapowarr volume folder assertion must require both reads to have answered" unless
    folder_assertion && folder_conditions.include?("kapowarr_verify_volumes.status") &&
    folder_conditions.include?("kapowarr_verify_rename_plans.results")
  # An unauthorized Kapowarr answers `result: {}`, which a loop cannot iterate.
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
  # The prefix lets tests/<service>_contract_test.rb tell a refusal from a crash (#352).
  warn failures.map { |failure| "Kapowarr contract failed: #{failure}" }.join("\n")
  exit 1
end
