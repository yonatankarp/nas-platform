#!/usr/bin/env ruby
# The static half of the Audiobookshelf service contract: every property it can
# decide from the repository alone, with nothing deployed.
#
# usage: ruby -ryaml audiobookshelf-static.rb COMPOSE MAC_COMPOSE ROLE DEFAULTS \
#          ARGUMENT_SPECS ENV_TEMPLATE INTEGRATION STORAGE_INVENTORY \
#          RUNTIME_SOURCE MODE
#
# The -ryaml preload is load-bearing: the body calls YAML.safe_load_file without
# requiring yaml itself, exactly as the heredoc it came from did, and raises
# NameError run bare. RUNTIME_SOURCE is audiobookshelf-runtime.rb in the tree
# being inspected -- the drift-commit branch below is read out of it -- and MODE
# is the contract's mode, which selects one extra block of deployment-order
# assertions.
#
# Silent and exit 0 when the repository holds; one `Audiobookshelf contract
# failed: ...` line on stderr and exit 1 when it does not. Callers grep those
# lines, so they are the interface -- tests/audiobookshelf_contract_test.rb
# asserts each one by its exact text.
compose_path, mac_path, role_path, defaults_path, argument_specs_path,
  environment_template_path, integration_path, storage_inventory_path,
  contract_source_path, mode = ARGV
compose = YAML.safe_load_file(compose_path, aliases: true)
mac = YAML.safe_load_file(mac_path, aliases: true)
defaults = YAML.safe_load_file(defaults_path)
argument_specs = YAML.safe_load_file(argument_specs_path)
integration = File.read(integration_path)
storage = YAML.safe_load_file(storage_inventory_path)

# What the role does is its parsed task list, not the file's bytes. A task name
# or a repaired field that survives only inside a comment is not something the
# role executes. role_strings collects the strings one at a time rather than
# joining them, so a pattern cannot match across two unrelated tasks.
def role_strings(node)
  case node
  when Hash then node.flat_map { |key, value| [key.to_s] + role_strings(value) }
  when Array then node.flat_map { |value| role_strings(value) }
  when String then [node]
  else []
  end
end
# The role wraps its marker handling in a block, whose children are tasks too.
require File.join(ENV.fetch("PLATFORM_CONTRACT_REPO_DIR"), "tests", "policy_support")
include PolicySupport
# The role is one stage per file, imported from main.yml. static_role_tasks
# assembles them the way Ansible does -- imports spliced in where they stand --
# so the ordering assertions below still compare positions across the whole role
# and not within whichever stage happens to hold both tasks.
role_tasks = static_role_tasks(role_path)
all_role_tasks = flatten_tasks(role_tasks)
role_task_names = all_role_tasks.filter_map { |task| task["name"] }
# The environment file has its own grammar, so it is read as the assignments it
# declares rather than as a substring of the template. A commented-out sample of
# the right assignment satisfies a substring check while the live line exports
# something else, and a duplicated assignment silently wins on the last one.
environment_assignments = File.readlines(environment_template_path).filter_map do |line|
  name, _separator, value = line.strip.partition("=")
  [name, value] if line.strip.match?(/\A[A-Z][A-Z0-9_]*=/)
end
service = compose.fetch("services").fetch("audiobookshelf")
abort "Audiobookshelf contract failed: platform identity differs" unless
  service.fetch("user") == "${NAS_UID:?}:${NAS_GID:?}"
abort "Audiobookshelf contract failed: NAS port differs" unless service.fetch("ports") == ["13378:80"]
abort "Audiobookshelf contract failed: storage contract differs" unless service.fetch("volumes") == [
  "${AUDIOBOOKSHELF_CONFIG_PATH:?}:/config",
  "${AUDIOBOOKSHELF_METADATA_PATH:?}:/metadata",
  "${AUDIOBOOKSHELF_MEDIA_PATH:?}:/audiobooks:ro",
  "${AUDIOBOOKSHELF_BACKUP_PATH:?}:/metadata/backups"
]
abort "Audiobookshelf contract failed: media control network membership differs" unless
  service.fetch("networks") == %w[default media-control] && compose.fetch("networks") == {
    "default" => {},
    "media-control" => { "external" => true, "name" => "${PLATFORM_MEDIA_NETWORK:?}" }
  }
health = service.fetch("healthcheck")
abort "Audiobookshelf contract failed: legacy health check differs" unless
  health == {
    "test" => ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:80/healthcheck"],
    "interval" => "30s", "timeout" => "10s", "retries" => 4, "start_period" => "30s"
  }
abort "Audiobookshelf contract failed: restart policy differs" unless service.fetch("restart") == "unless-stopped"
abort "Audiobookshelf contract failed: logging policy differs" unless service.fetch("logging") == {
  "driver" => "json-file", "options" => { "max-size" => "10m", "max-file" => "3" }
}
mac_service = mac.fetch("services").fetch("audiobookshelf")
abort "Audiobookshelf contract failed: Mac override differs" unless
  mac_service.keys.sort == %w[container_name ports volumes] && !mac_service.key?("image") &&
    mac_service.fetch("volumes") == [
      "${PLATFORM_DOCKER_ROOT:?}/audiobookshelf/backups:/metadata/backups"
    ]
abort "Audiobookshelf contract failed: managed library must be rooted at /audiobooks" unless
  defaults.fetch("audiobookshelf_library_folders") == [{ "path" => "/audiobooks" }]

expected_owned_settings = {
  "storeCoverWithItem" => true,
  "storeMetadataWithItem" => true,
  "sortingIgnorePrefix" => false,
  "scannerParseSubtitle" => true,
  "scannerFindCovers" => true,
  "scannerCoverProvider" => "google",
  "scannerPreferMatchedMetadata" => true,
  "scannerDisableWatcher" => false,
  "chromecastEnabled" => true,
  "allowIframe" => true,
  "homeBookshelfView" => 1,
  "bookshelfView" => 1,
  "dateFormat" => "dd/MM/yyyy",
  "timeFormat" => "HH:mm",
  "language" => "en-us"
}
abort "Audiobookshelf contract failed: owned server settings differ" unless
  defaults.fetch("audiobookshelf_owned_server_settings") == expected_owned_settings
abort "Audiobookshelf contract failed: backup policy defaults differ" unless
  defaults.values_at(
    "audiobookshelf_backup_cron", "audiobookshelf_backup_retention",
    "audiobookshelf_backup_container_path", "audiobookshelf_backup_host_path"
  ) == ["0 3 * * *", 7, "/metadata/backups", "/volume1/Docker/audiobookshelf/backups"]
abort "Audiobookshelf contract failed: backup environment is absent" unless
  environment_assignments.select { |name, _value| name == "AUDIOBOOKSHELF_BACKUP_PATH" } ==
    [["AUDIOBOOKSHELF_BACKUP_PATH", "{{ audiobookshelf_effective_backup_host_path }}"]]
abort "Audiobookshelf contract failed: media network environment is absent" unless
  environment_assignments.select { |name, _value| name == "PLATFORM_MEDIA_NETWORK" } ==
    [["PLATFORM_MEDIA_NETWORK", "{{ platform_media_control_network }}"]]
backup_storage = storage.fetch("nas_storage").find do |entry|
  entry["path"] == "{{ nas_docker_root }}/audiobookshelf/backups"
end
abort "Audiobookshelf contract failed: backup storage inventory differs" unless
  backup_storage == {
    "path" => "{{ nas_docker_root }}/audiobookshelf/backups",
    "owner" => "{{ nas_uid }}", "group" => "{{ nas_gid }}",
    "mode" => "0755", "recovery" => "critical"
  }

argument_options = argument_specs.dig("argument_specs", "main", "options")
abort "Audiobookshelf contract failed: server settings argument validation is absent" unless
  argument_options.dig("platform_media_control_network", "type") == "str" &&
    argument_options.dig("platform_media_control_network", "required") == true &&
  argument_options.dig("audiobookshelf_owned_server_settings", "type") == "dict" &&
    argument_options.dig("audiobookshelf_backup_cron", "type") == "str" &&
    argument_options.dig("audiobookshelf_backup_retention", "type") == "int" &&
    argument_options.dig("audiobookshelf_backup_container_path", "type") == "str" &&
    argument_options.dig("audiobookshelf_backup_host_path", "type") == "str"

if mode == "static"
  resolve_backup_index = role_tasks.index { |task| task["name"] == "Resolve the effective Audiobookshelf backup directory" }
  validate_target_index = role_tasks.index { |task| task["name"] == "Revalidate deployment paths before Audiobookshelf runtime use" }
  render_index = role_tasks.index { |task| task["name"] == "Render the Audiobookshelf environment" }
  validation_task = validate_target_index ? role_tasks.fetch(validate_target_index) : {}
  validation_paths = validation_task.fetch("vars", {}).fetch("deployment_target_extra_paths", [])
  abort "Audiobookshelf contract failed: backup path is not resolved and validated before mutation" unless
    resolve_backup_index && validate_target_index && render_index &&
      resolve_backup_index < validate_target_index && validate_target_index < render_index &&
      validation_paths.include?("{{ audiobookshelf_effective_backup_host_path }}")
  abort "Audiobookshelf contract failed: service role duplicates host_prep backup ownership" if
    role_tasks.any? do |task|
      file = task["ansible.builtin.file"]
      file.is_a?(Hash) && file["path"] == "{{ audiobookshelf_effective_backup_host_path }}"
    end
  required_tasks = [
    "Refuse duplicate managed Audiobookshelf administrators",
    "Refuse unavailable Audiobookshelf administrator authentication",
    "Refuse unexpected Audiobookshelf administrator authentication responses",
    "Report planned Audiobookshelf administrator creation",
    "Read Audiobookshelf server settings for reconciliation",
    "Validate current Audiobookshelf server settings schema",
    "Report planned Audiobookshelf server settings reconciliation",
    "Reconcile owned Audiobookshelf server settings",
    "Re-authorize after Audiobookshelf server settings reconciliation",
    "Require exact owned Audiobookshelf server settings after reconciliation",
    "Report planned Audiobookshelf library creation",
    "Report planned Audiobookshelf library repair",
    "Require exactly the managed Audiobookshelf administrator",
    "Require exactly the managed Audiobookshelf library"
  ]
  required_tasks.each do |name|
    abort "Audiobookshelf contract failed: missing #{name}" unless role_task_names.include?(name)
  end
  settings_reads = role_tasks.each_with_index.filter_map do |task, index|
    uri = task.is_a?(Hash) ? task["ansible.builtin.uri"] : nil
    [task, uri, index] if uri.is_a?(Hash) && uri["url"] == "{{ audiobookshelf_api }}/api/authorize"
  end
  settings_patch = role_tasks.each_with_index.filter_map do |task, index|
    uri = task.is_a?(Hash) ? task["ansible.builtin.uri"] : nil
    [task, uri, index] if uri.is_a?(Hash) && uri["url"] == "{{ audiobookshelf_api }}/api/settings"
  end
  abort "Audiobookshelf contract failed: unsupported GET /api/settings is assumed" if
    settings_patch.any? { |_task, uri, _index| uri.fetch("method", "GET") == "GET" }
  abort "Audiobookshelf contract failed: authoritative settings reads must re-authorize" unless
    settings_reads.length >= 2 && settings_reads.all? { |task, uri, _index| uri["method"] == "POST" && task["no_log"] == true }
  abort "Audiobookshelf contract failed: settings mutation must be one conditional partial PATCH" unless
    settings_patch.length == 1 && settings_patch.fetch(0).fetch(1)["method"] == "PATCH" &&
      settings_patch.fetch(0).fetch(0)["when"].include?("audiobookshelf_server_settings_drifted | bool")
  patch_index = settings_patch.fetch(0).fetch(2)
  post_patch_read = settings_reads.find do |task, _uri, index|
    index > patch_index && task["name"] == "Re-authorize after Audiobookshelf server settings reconciliation"
  end
  abort "Audiobookshelf contract failed: PATCH response is treated as final settings verification" unless
    post_patch_read && role_tasks[(post_patch_read.fetch(2) + 1)..].any? do |task|
      task.is_a?(Hash) && task["name"] == "Require exact owned Audiobookshelf server settings after reconciliation"
    end
  timezone_assertions = role_tasks.filter_map do |task|
    assertion = task["ansible.builtin.assert"]
    Array(assertion["that"]) if assertion.is_a?(Hash)
  end.flatten.grep(/serverSettings[.]timeZone.*Europe\/Berlin/)
  abort "Audiobookshelf contract failed: authoritative timezone is not checked on every settings read" unless
    timezone_assertions.length >= 3
  patch_body = settings_patch.fetch(0).fetch(1).fetch("body").to_s
  abort "Audiobookshelf contract failed: non-persisted timezone is included in PATCH" if
    patch_body.include?("timeZone") || defaults.fetch("audiobookshelf_owned_server_settings").key?("timeZone")
  drift_commit_branch = File.read(contract_source_path)
                            .rpartition(%q{when "drift-commit"}).last
                            .partition(%q{when "check-repair-unchanged"}).first
  abort "Audiobookshelf contract failed: drift commit consumes reconciliation evidence" if
    drift_commit_branch.include?("remove_drift_snapshot")
  # Repair is a type change, never a reactivation. Read from the structure this
  # holds however the role is formatted, where the old two-literal check only
  # recognized the one layout the role happened to have when it was written.
  repair_bodies = all_role_tasks.filter_map do |task|
    uri = task["ansible.builtin.uri"]
    uri["body"] if uri.is_a?(Hash) && uri["body"].is_a?(Hash)
  end
  abort "Audiobookshelf contract failed: role still claims inactive administrator repair" if
    role_strings(all_role_tasks).any? { |value| value.include?("audiobookshelf_existing_admin.isActive") } ||
      repair_bodies.any? { |body| body.key?("isActive") }
  markers = %w[
    AUDIOBOOKSHELF_INACTIVE_ADMIN_REFUSED_AND_RECOVERED
    AUDIOBOOKSHELF_DUPLICATE_ADMIN_REFUSED
    AUDIOBOOKSHELF_DUPLICATE_LIBRARY_REFUSED_WITH_SAFE_IDS
    AUDIOBOOKSHELF_DRIFT_REPAIRED
    AUDIOBOOKSHELF_CHECK_CREATE_PLANNED_IMMUTABLE
    AUDIOBOOKSHELF_CHECK_REPAIR_PLANNED_IMMUTABLE
  ]
  markers.each do |marker|
    abort "Audiobookshelf contract failed: integration is missing #{marker}" unless integration.include?(marker)
  end
end
