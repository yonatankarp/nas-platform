#!/bin/sh
set -eu
set +x

mode=${1:-run}
repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)}
compose=$repo_dir/services/audiobookshelf/compose.yml
mac_compose=$repo_dir/services/audiobookshelf/compose.mac.yml
role=$repo_dir/roles/audiobookshelf/tasks/main.yml
defaults=$repo_dir/roles/audiobookshelf/defaults/main.yml
argument_specs=$repo_dir/roles/audiobookshelf/meta/argument_specs.yml
environment_template=$repo_dir/roles/audiobookshelf/templates/env.j2
integration=$repo_dir/tests/integration.sh
storage_inventory=$repo_dir/inventory/group_vars/all/main.yml
contract_source=$repo_dir/tests/contracts/audiobookshelf.sh

fail_contract() {
  printf 'Audiobookshelf contract failed: %s\n' "$1" >&2
  exit 1
}

[ -f "$role" ] || fail_contract 'roles/audiobookshelf/tasks/main.yml is absent'
[ -f "$defaults" ] || fail_contract 'roles/audiobookshelf/defaults/main.yml is absent'
[ -f "$compose" ] || fail_contract 'services/audiobookshelf/compose.yml is absent'
[ -f "$mac_compose" ] || fail_contract 'services/audiobookshelf/compose.mac.yml is absent'
[ -f "$argument_specs" ] || fail_contract 'roles/audiobookshelf/meta/argument_specs.yml is absent'
[ -f "$environment_template" ] || fail_contract 'roles/audiobookshelf/templates/env.j2 is absent'

ruby -ryaml - "$compose" "$mac_compose" "$role" "$defaults" \
  "$argument_specs" "$environment_template" "$integration" "$storage_inventory" \
  "$contract_source" "$mode" <<'RUBY'
compose_path, mac_path, role_path, defaults_path, argument_specs_path,
  environment_template_path, integration_path, storage_inventory_path,
  contract_source_path, mode = ARGV
compose = YAML.safe_load_file(compose_path, aliases: true)
mac = YAML.safe_load_file(mac_path, aliases: true)
role_tasks = YAML.safe_load_file(role_path)
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
def flatten_tasks(tasks)
  Array(tasks).flat_map do |task|
    next [] unless task.is_a?(Hash)
    [task] + %w[block rescue always].flat_map { |key| flatten_tasks(task[key]) }
  end
end
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
abort "Audiobookshelf contract failed: NAS UID/GID differs" unless service.fetch("user") == "1000:100"
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
RUBY

[ "$mode" = static ] && { printf '%s\n' 'Audiobookshelf static contract passed'; exit 0; }

: "${PLATFORM_CONTRACT_VAULT_FILE:=${PLATFORM_MAC_VAULT_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:=${PLATFORM_MAC_VAULT_PASSWORD_FILE:-}}"
: "${PLATFORM_MEDIA_ROOT:?}"
: "${PLATFORM_REPORT_ROOT:?}"
: "${PLATFORM_AUDIOBOOKSHELF_PORT:=13378}"
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
export PLATFORM_MEDIA_ROOT PLATFORM_REPORT_ROOT PLATFORM_AUDIOBOOKSHELF_PORT
PLATFORM_REPO_ROOT=$repo_dir
export PLATFORM_REPO_ROOT

shift || true
exec ruby - "$mode" "$@" <<'RUBY'
require "digest"
require "json"
require "net/http"
require "open3"
require "pathname"
require "timeout"
require "uri"
require "yaml"

MODE = ARGV.fetch(0)
BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_AUDIOBOOKSHELF_PORT'), 10)}")
MEDIA_ROOT = Pathname.new(ENV.fetch("PLATFORM_MEDIA_ROOT")).expand_path
REPORT_ROOT = Pathname.new(ENV.fetch("PLATFORM_REPORT_ROOT")).expand_path
LIBRARY_NAME = "Audiobooks"
FIXTURE_TITLE = "Task 9 Contract Book"
MEDIA_LIBRARY = Pathname.new(
  ENV.fetch("PLATFORM_AUDIOBOOKSHELF_MEDIA_LIBRARY", MEDIA_ROOT.join("Media", "Audiobooks").to_s)
).expand_path
FIXTURE_DIRECTORY = MEDIA_LIBRARY.join("task-9-contract-book")
FIXTURE_PATH = FIXTURE_DIRECTORY.join("task-9-contract-book.wav")
FIXTURE_COVER_PATH = FIXTURE_DIRECTORY.join("cover.png")
FIXTURE_REL_PATH = "task-9-contract-book"
FIXTURE_COVER_BYTES = [
  "89504e470d0a1a0a0000000d4948445200000001000000010804000000b51c0c02" \
  "0000000b4944415478da6364f80f00010501012718e3660000000049454e44ae426082"
].pack("H*").freeze
PROGRESS_SECONDS = 1.25
SAFE_ID = /\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/
DESIRED_SETTINGS = {
  "coverAspectRatio" => 1,
  "disableWatcher" => false,
  "autoScanCronExpression" => nil,
  "skipMatchingMediaWithAsin" => false,
  "skipMatchingMediaWithIsbn" => false,
  "audiobooksOnly" => false,
  "epubsAllowScriptedContent" => false,
  "hideSingleBookSeries" => false,
  "onlyShowLaterBooksInContinueSeries" => false,
  "metadataPrecedence" => %w[folderStructure audioMetatags nfoFile txtFiles opfFile absMetadata],
  "markAsFinishedPercentComplete" => nil,
  "markAsFinishedTimeRemaining" => 10
}.freeze
DRIFT_SETTINGS = DESIRED_SETTINGS.merge("disableWatcher" => true).freeze
OWNED_SERVER_SETTINGS = {
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
  "language" => "en-us",
  "backupPath" => "/metadata/backups",
  "backupSchedule" => "0 3 * * *",
  "backupsToKeep" => 7
}.freeze
DRIFT_SERVER_SETTINGS = {
  "scannerParseSubtitle" => false,
  "backupSchedule" => "0 4 * * *",
  "backupsToKeep" => 2
}.freeze
UNOWNED_SERVER_SETTINGS_SENTINEL = "loggerDailyLogsToKeep"
AUTHORITATIVE_SERVER_TIME_ZONE = "Europe/Berlin"
LIBRARY_STATE_KEYS = %w[folders icon mediaType name provider settings].freeze
LIBRARY_FOLDER_STATE_KEYS = %w[addedAt fullPath id libraryId].freeze
SERVER_SETTINGS_STATE_KEYS = (OWNED_SERVER_SETTINGS.keys + [UNOWNED_SERVER_SETTINGS_SENTINEL]).sort.freeze
DRIFT_SNAPSHOT_KIND = "audiobookshelf-library-drift-snapshot"
VAULT_CREDENTIAL_KEY = /_(?:password|hash|token|key)\z/

def fail_contract(message)
  warn "Audiobookshelf contract failed: #{message}"
  exit 1
end

def endpoint(path)
  URI.join(BASE.to_s, path)
end

def response_kind(response)
  media_type = response["Content-Type"].to_s.split(";", 2).first.to_s.strip.downcase
  return "json" if media_type == "application/json" || media_type.end_with?("+json")
  return "text" if media_type.start_with?("text/")
  return "binary" if media_type.start_with?("audio/") || media_type == "application/octet-stream"

  "other"
end

def unexpected_response_message(method, path, response)
  "#{method.upcase} #{path} returned HTTP #{response.code.to_i} (#{response_kind(response)} response)"
end

def request(method, path, token: nil, body: nil, expected: [200], range: nil)
  uri = endpoint(path)
  request = Net::HTTP.const_get(method.capitalize).new(uri)
  request["Authorization"] = "Bearer #{token}" if token
  request["Range"] = range if range
  if body
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body)
  end
  response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 30) do |http|
    http.request(request)
  end
  fail_contract(unexpected_response_message(method, uri.path, response)) unless
    expected.include?(response.code.to_i)
  parsed = if response.body.to_s.empty? || !response["Content-Type"].to_s.include?("json")
             nil
           else
             JSON.parse(response.body)
           end
  [response, parsed]
rescue JSON::ParserError
  fail_contract("#{method.upcase} #{uri.path} returned malformed JSON")
rescue SystemCallError, Timeout::Error => error
  fail_contract("#{method.upcase} #{uri.path} failed: #{error.class}")
end

def safe_id(value)
  id = value.to_s
  fail_contract("API returned an unsafe identifier") unless id.match?(SAFE_ID)
  id
end

def exact_vault_named_administrator(users, username, type:, active:)
  fail_contract("administrator user listing is malformed") unless users.is_a?(Array)
  matches = users.select { |user| user.is_a?(Hash) && user["username"] == username }
  fail_contract("vault-named administrator identity is absent or duplicated") unless matches.length == 1
  administrator = matches.fetch(0)
  fail_contract("vault-named administrator privilege or active state differs") unless
    administrator["type"] == type && administrator["isActive"] == active
  safe_id(administrator.fetch("id"))
  administrator
rescue KeyError
  fail_contract("vault-named administrator state is malformed")
end

def exact_library_folders(folders, library_id)
  fail_contract("library state must contain exactly one folder") unless folders.is_a?(Array) && folders.length == 1
  folder = folders.fetch(0)
  fail_contract("library folder state shape is unsafe") unless
    folder.is_a?(Hash) && folder.keys.sort == LIBRARY_FOLDER_STATE_KEYS
  folder_id = safe_id(folder.fetch("id"))
  folder_library_id = safe_id(folder.fetch("libraryId"))
  fail_contract("library folder ownership is ambiguous") unless folder_library_id == library_id
  fail_contract("library folder root differs") unless folder.fetch("fullPath") == "/audiobooks"
  added_at = folder.fetch("addedAt")
  fail_contract("library folder creation time is unsafe") unless added_at.is_a?(Integer) && added_at >= 0
  [{
    "id" => folder_id,
    "fullPath" => "/audiobooks",
    "libraryId" => folder_library_id,
    "addedAt" => added_at
  }]
end

def exact_library_state(library, library_id: nil)
  resolved_library_id = safe_id(library_id || library.fetch("id"))
  folders = exact_library_folders(library.fetch("folders"), resolved_library_id)
  state = {
    "name" => library.fetch("name"),
    "folders" => folders,
    "mediaType" => library.fetch("mediaType"),
    "provider" => library.fetch("provider"),
    "icon" => library.fetch("icon"),
    "settings" => library.fetch("settings")
  }
  fail_contract("library state shape is unsafe") unless
    state["name"].is_a?(String) && !state["name"].empty? &&
      !folders.empty? && state["mediaType"].is_a?(String) &&
      (state["provider"].nil? || state["provider"].is_a?(String)) &&
      (state["icon"].nil? || state["icon"].is_a?(String)) &&
      state["settings"].is_a?(Hash)
  JSON.parse(JSON.generate(state))
end

def drifted_library_state(state)
  state.merge("provider" => "audible", "icon" => "podcast", "settings" => DRIFT_SETTINGS)
end

def authoritative_server_settings(token)
  payload = request("post", "/api/authorize", token: token).last
  fail_contract("authoritative server settings response is malformed") unless
    payload.is_a?(Hash) && payload["serverSettings"].is_a?(Hash)
  settings = payload.fetch("serverSettings")
  fail_contract("authoritative server timezone differs") unless
    settings["timeZone"] == AUTHORITATIVE_SERVER_TIME_ZONE
  settings
end

def selected_server_settings(settings)
  fail_contract("server settings state is malformed") unless settings.is_a?(Hash)
  selected = SERVER_SETTINGS_STATE_KEYS.to_h do |key|
    fail_contract("server settings state is missing #{key}") unless settings.key?(key)
    [key, settings.fetch(key)]
  end
  OWNED_SERVER_SETTINGS.each do |key, expected|
    actual = selected.fetch(key)
    type_matches = if expected == true || expected == false
                     actual == true || actual == false
                   else
                     actual.class == expected.class
                   end
    fail_contract("server settings type differs for #{key}") unless
      type_matches
  end
  fail_contract("unowned server settings sentinel type differs") unless
    selected.fetch(UNOWNED_SERVER_SETTINGS_SENTINEL).is_a?(Integer)
  selected
end

def drift_snapshot_path
  drift_snapshot_directory.join("snapshot.json")
end

def drift_snapshot_directory
  REPORT_ROOT.join(".audiobookshelf-drift-state")
end

def require_report_root!
  fail_contract("report root is unavailable or unsafe") unless REPORT_ROOT.directory? && !REPORT_ROOT.symlink?
rescue Errno::ENOENT, Errno::EACCES
  fail_contract("report root is unavailable or unsafe")
end

def require_owned_drift_snapshot_directory!
  path = drift_snapshot_directory
  stat = path.lstat
  fail_contract("drift snapshot directory ownership is unsafe") unless
    stat.directory? && !path.symlink? && stat.uid == Process.uid && (stat.mode & 0o777) == 0o700
  path
rescue Errno::ENOENT, Errno::EACCES
  fail_contract("drift snapshot directory is unavailable or unsafe")
end

def require_owned_drift_snapshot!
  require_owned_drift_snapshot_directory!
  path = drift_snapshot_path
  stat = path.lstat
  fail_contract("drift snapshot ownership is unsafe") unless
    stat.file? && !path.symlink? && stat.uid == Process.uid && (stat.mode & 0o777) == 0o600
  path
rescue Errno::ENOENT, Errno::EACCES
  fail_contract("drift snapshot is unavailable or unsafe")
end

def write_drift_snapshot(library, server_settings)
  require_report_root!
  directory = drift_snapshot_directory
  fail_contract("refusing ambiguous drift snapshot ownership") if directory.exist? || directory.symlink?
  directory.mkdir(0o700)
  require_owned_drift_snapshot_directory!
  path = drift_snapshot_path
  snapshot = {
    "schema" => 1,
    "kind" => DRIFT_SNAPSHOT_KIND,
    "library_id" => safe_id(library.fetch("id")),
    "state" => exact_library_state(library),
    "server_settings" => selected_server_settings(server_settings)
  }
  path.open(File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
    file.write(JSON.generate(snapshot))
  end
  require_owned_drift_snapshot!
end

def read_drift_snapshot
  snapshot = JSON.parse(require_owned_drift_snapshot!.binread)
  fail_contract("drift snapshot schema is malformed") unless
    snapshot.is_a?(Hash) &&
      snapshot.keys.sort == %w[kind library_id schema server_settings state] &&
      snapshot["schema"] == 1 && snapshot["kind"] == DRIFT_SNAPSHOT_KIND &&
      snapshot["state"].is_a?(Hash) && snapshot["state"].keys.sort == LIBRARY_STATE_KEYS &&
      snapshot["server_settings"].is_a?(Hash) &&
      snapshot["server_settings"].keys.sort == SERVER_SETTINGS_STATE_KEYS
  snapshot["library_id"] = safe_id(snapshot.fetch("library_id"))
  snapshot["state"] = exact_library_state(
    snapshot.fetch("state"), library_id: snapshot.fetch("library_id")
  )
  snapshot["server_settings"] = selected_server_settings(snapshot.fetch("server_settings"))
  snapshot
rescue JSON::ParserError, KeyError, TypeError
  fail_contract("drift snapshot is malformed")
end

def snapshot_state_for_library(snapshot, library)
  fail_contract("drift snapshot library ownership is ambiguous") unless
    snapshot.fetch("library_id") == safe_id(library.fetch("id"))
  snapshot.fetch("state")
end

def exact_snapshot_recovered?(libraries, snapshot)
  libraries.length == 1 &&
    snapshot.fetch("library_id") == safe_id(libraries.fetch(0).fetch("id")) &&
    exact_library_state(libraries.fetch(0)) == snapshot.fetch("state")
end

def remove_drift_snapshot
  require_owned_drift_snapshot!.unlink
  require_owned_drift_snapshot_directory!.rmdir
end

def expect_contract_failure(message = "unsafe drift snapshot was accepted", timeout: 2)
  pid = fork do
    $stdout.reopen(File::NULL, "w")
    $stderr.reopen(File::NULL, "w")
    yield
    exit! 0
  end
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  status = nil
  until status || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    _waited, status = Process.wait2(pid, Process::WNOHANG)
    sleep 0.01 unless status
  end
  unless status
    Process.kill("KILL", pid)
    Process.wait(pid)
    fail_contract("#{message}; rejection blocked")
  end
  fail_contract(message) if status.success?
end

def exact_role_auth_model(main_tasks, managed_tasks)
  login_tasks = lambda do |tasks|
    tasks.each_with_index.filter_map do |task, index|
      uri = task.is_a?(Hash) ? task["ansible.builtin.uri"] : nil
      [task, index] if uri.is_a?(Hash) && uri["url"] == "{{ audiobookshelf_api }}/login"
    end
  end
  main_logins = login_tasks.call(main_tasks)
  managed_logins = login_tasks.call(managed_tasks)
  expected_main_names = [
    "Authenticate the Audiobookshelf administrator for reconciliation",
    "Authenticate to Audiobookshelf for exact verification"
  ]
  expected_managed_names = [
    "Authenticate existing Audiobookshelf managed users",
    "Authenticate newly created Audiobookshelf managed users"
  ]
  fail_contract("Audiobookshelf administrator authentication task model differs") unless
    main_logins.map { |task, _index| task["name"] } == expected_main_names
  fail_contract("Audiobookshelf managed-user authentication task model differs") unless
    managed_logins.map { |task, _index| task["name"] } == expected_managed_names

  reconcile, verify = main_logins.map(&:first)
  existing, created = managed_logins.map(&:first)
  fail_contract("Audiobookshelf administrator authentication guards differ") unless
    reconcile["when"] == "not ansible_check_mode or audiobookshelf_initialized | bool" &&
      verify["when"] == ["not ansible_check_mode", "audiobookshelf_reconcile_token is not defined"]
  fail_contract("Audiobookshelf managed-user authentication guards differ") unless
    existing["when"] == [
      "audiobookshelf_managed_users_phase == 'reconcile'",
      "not ansible_check_mode",
      "audiobookshelf_managed_user_matches[item.username] | length == 1"
    ] && existing["loop"] == "{{ vault_managed_audiobookshelf_users }}" &&
      created["when"] == [
        "audiobookshelf_managed_users_phase == 'reconcile'",
        "not ansible_check_mode"
      ] && created["loop"].to_s.include?("audiobookshelf_managed_user_creation.results")
  fail_contract("Audiobookshelf authentication tasks are not protected from disclosure") unless
    (main_logins + managed_logins).all? do |task, _index|
      task.dig("ansible.builtin.uri", "method") == "POST" && task["no_log"] == true
    end

  {
    reconcile_admin: main_logins.count { |task, _index| task["name"] == expected_main_names.fetch(0) },
    check_admin: main_logins.count { |task, _index| task["name"] == expected_main_names.fetch(0) },
    verify_admin: main_logins.count { |task, _index| task["name"] == expected_main_names.fetch(1) },
    managed_per_user: managed_logins.count do |task, _index|
      task["name"] == expected_managed_names.fetch(0)
    end,
    main_task_indexes: main_logins.map(&:last)
  }
end

def generated_audiobookshelf_user_count(generator)
  section = generator.match(/^  audiobookshelf:\n(?<body>.*?)(?=^  [a-z0-9_]+:\n)/m)
  fail_contract("ephemeral Audiobookshelf managed-user input is absent or ambiguous") unless section
  count = section[:body].scan(/^    - username:/).length
  fail_contract("ephemeral Audiobookshelf managed-user input is empty") unless count.positive?
  count
end

def exact_baseline_role_runs(integration)
  selector = integration.scan(
    /^\s*run_selected_play\(\) \{\n\s*if \[ -n "\\\$INTEGRATION_TAGS" \]; then\n\s*run_play --tags \\"\\\$INTEGRATION_TAGS\\" \\"\\\$@\\"\n\s*elif \[ "\\\$#" -eq 0 \]; then\n\s*run_play\n\s*else\n\s*run_play \\"\\\$@\\"\n\s*fi\n\s*\}$/
  ).length
  initial = integration.scan(
    /^\s*if \[ -z "\\\$INTEGRATION_TAGS" \] && \[ "\\\$#" -eq 0 \]; then\n\s*run_play\n\s*else\n\s*run_selected_play "\\\$@"\n\s*fi$/
  ).length
  idempotence = integration.scan(/^\s*run_selected_play "\\\$@" \| tee \/tmp\/second\.txt$/).length
  check = integration.scan(/^\s*if run_selected_play "\\\$@" --check --diff; then$/).length
  fail_contract("Audiobookshelf baseline role call sequence differs") unless
    selector == 1 && initial == 1 && idempotence == 1 && check == 1
  { normal: initial + idempotence, check: check }
end

def direct_harness_login_count(contract)
  count = contract.scan(/request\(\s*"post",\s*"\/login"/).length
  fail_contract("Audiobookshelf direct authentication proof is absent") unless count.positive?
  count
end

def owned_directory!(path, parent)
  fail_contract("fixture path escaped the media root") unless path.parent == parent
  fail_contract("fixture directory is a symlink") if path.symlink?
  path.mkdir(0o755) unless path.exist?
  fail_contract("fixture directory is unavailable") unless path.directory? && !path.symlink?
end

def tagged_wave
  sample_rate = 8_000
  sample_count = sample_rate * 2
  samples = (0...sample_count).map do |index|
    (Math.sin(2 * Math::PI * 440 * index / sample_rate) * 4_000).round
  end.pack("s<*")
  title = FIXTURE_TITLE.b
  info_data = "INAM".b + [title.bytesize + 1].pack("V") + title + "\0"
  info_data << "\0" if info_data.bytesize.odd?
  list_data = "INFO".b + info_data
  fmt = [1, 1, sample_rate, sample_rate * 2, 2, 16].pack("vvVVvv")
  chunks = "fmt ".b + [fmt.bytesize].pack("V") + fmt
  chunks << "LIST".b + [list_data.bytesize].pack("V") + list_data
  chunks << "data".b + [samples.bytesize].pack("V") + samples
  "RIFF".b + [chunks.bytesize + 4].pack("V") + "WAVE".b + chunks
end

def tagged_wave_title(bytes)
  return nil unless bytes.bytesize >= 12 && bytes.start_with?("RIFF") && bytes.byteslice(8, 4) == "WAVE"
  return nil unless bytes.byteslice(4, 4).unpack1("V") + 8 == bytes.bytesize

  offset = 12
  title = nil
  format_found = false
  audio_found = false
  while offset < bytes.bytesize
    return nil if offset + 8 > bytes.bytesize

    chunk_id = bytes.byteslice(offset, 4)
    chunk_size = bytes.byteslice(offset + 4, 4).unpack1("V")
    data_offset = offset + 8
    data_end = data_offset + chunk_size
    return nil if data_end > bytes.bytesize

    format_found = true if chunk_id == "fmt "
    audio_found = true if chunk_id == "data"
    if chunk_id == "LIST" && chunk_size >= 4 && bytes.byteslice(data_offset, 4) == "INFO"
      info_offset = data_offset + 4
      while info_offset < data_end
        return nil if info_offset + 8 > data_end

        info_id = bytes.byteslice(info_offset, 4)
        info_size = bytes.byteslice(info_offset + 4, 4).unpack1("V")
        value_offset = info_offset + 8
        value_end = value_offset + info_size
        return nil if value_end > data_end

        title = bytes.byteslice(value_offset, info_size).delete_suffix("\0") if info_id == "INAM"
        info_offset = value_end + (info_size.odd? ? 1 : 0)
      end
      return nil unless info_offset == data_end
    end
    offset = data_end + (chunk_size.odd? ? 1 : 0)
  end
  return nil unless offset == bytes.bytesize && format_found && audio_found

  title
end

def matching_fixture_item(items)
  matches = items.select do |candidate|
    candidate.is_a?(Hash) && candidate["relPath"] == FIXTURE_REL_PATH
  end
  fail_contract("fixture source identity is duplicated") if matches.length > 1
  matches.first
end

def container_fixture_state
  container = ENV["PLATFORM_AUDIOBOOKSHELF_CONTAINER"]
  return "unconfigured" if container.to_s.empty?

  expected_digest = Digest::SHA256.hexdigest(FIXTURE_PATH.binread)
  path = "/audiobooks/#{FIXTURE_REL_PATH}/#{FIXTURE_PATH.basename}"
  inspect_stdout, _inspect_stderr, inspect_status = Open3.capture3("docker", "inspect", container)
  return "inspect-failed" unless inspect_status.success?

  inspect = JSON.parse(inspect_stdout)
  mounts = inspect.is_a?(Array) && inspect.length == 1 ? inspect.fetch(0)["Mounts"] : nil
  return "inspect-malformed" unless mounts.is_a?(Array)

  media_mounts = mounts.select { |mount| mount.is_a?(Hash) && mount["Destination"] == "/audiobooks" }
  return "mount-cardinality" unless media_mounts.length == 1
  return "mount-source-mismatch" unless media_mounts.fetch(0)["Source"] == MEDIA_LIBRARY.to_s

  _stdout, _stderr, exists_status = Open3.capture3("docker", "exec", container, "test", "-f", path)
  return "missing" unless exists_status.success?

  stdout, _stderr, digest_status = Open3.capture3("docker", "exec", container, "sha256sum", path)
  return "digest-unavailable" unless digest_status.success?
  return "digest-mismatch" unless stdout.split.first == expected_digest

  "exact"
rescue JSON::ParserError, KeyError, TypeError
  "inspect-malformed"
end

def exact_playback?(source, full_body, range_body, content_range)
  full_body == source &&
    Digest::SHA256.hexdigest(full_body) == Digest::SHA256.hexdigest(source) &&
    range_body == source.byteslice(0, 128) &&
    content_range == "bytes 0-127/#{source.bytesize}"
end

def seed_fixture
  if ENV.key?("PLATFORM_AUDIOBOOKSHELF_MEDIA_LIBRARY")
    fail_contract("legacy media library is unavailable or unsafe") unless
      MEDIA_LIBRARY.directory? && !MEDIA_LIBRARY.symlink?
  else
    media_parent = MEDIA_ROOT.join("Media")
    owned_directory!(media_parent, MEDIA_ROOT)
    owned_directory!(MEDIA_LIBRARY, media_parent)
  end
  owned_directory!(FIXTURE_DIRECTORY, MEDIA_LIBRARY)
  fail_contract("fixture path is a symlink") if FIXTURE_PATH.symlink?
  bytes = tagged_wave
  fail_contract("fixture is not a valid RIFF/WAVE file with the exact tagged title") unless
    tagged_wave_title(bytes) == FIXTURE_TITLE
  if FIXTURE_PATH.exist?
    fail_contract("fixture path is not a regular file") unless FIXTURE_PATH.file?
    fail_contract("fixture bytes drifted") unless FIXTURE_PATH.binread == bytes
  else
    FIXTURE_PATH.open(File::WRONLY | File::CREAT | File::EXCL, 0o644) { |file| file.write(bytes) }
  end
  fail_contract("fixture cover path is a symlink") if FIXTURE_COVER_PATH.symlink?
  if FIXTURE_COVER_PATH.exist?
    fail_contract("fixture cover path is not a regular file") unless FIXTURE_COVER_PATH.file?
    fail_contract("fixture cover bytes drifted") unless FIXTURE_COVER_PATH.binread == FIXTURE_COVER_BYTES
  else
    FIXTURE_COVER_PATH.open(File::WRONLY | File::CREAT | File::EXCL, 0o644) do |file|
      file.write(FIXTURE_COVER_BYTES)
    end
  end
end

def artifact_path(name = "persistence")
  REPORT_ROOT.join("audiobookshelf-#{name}.json")
end

def session_token_path
  REPORT_ROOT.join(".audiobookshelf-contract-session")
end

def read_session_token(expected_uid: Process.uid)
  path = session_token_path
  fail_contract("nonblocking cached session reads are unsupported") unless File.const_defined?(:NONBLOCK)
  file = path.open(File::RDONLY | File::NOFOLLOW | File::NONBLOCK)
  stat = file.stat
  fail_contract("cached Audiobookshelf session is unavailable or unsafe") unless
    stat.file? && stat.uid == expected_uid && (stat.mode & 0o777) == 0o600 && stat.size <= 4096
  token = file.read(4097)
  fail_contract("cached Audiobookshelf session is malformed") unless
    token.match?(/\A[A-Za-z0-9._~-]{20,4096}\z/)
  token
rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, Errno::ENXIO
  fail_contract("cached Audiobookshelf session is unavailable or unsafe")
ensure
  file&.close
end

def write_session_token(token)
  fail_contract("report root is unavailable or unsafe") unless REPORT_ROOT.directory? && !REPORT_ROOT.symlink?
  fail_contract("Audiobookshelf session token is malformed") unless
    token.to_s.match?(/\A[A-Za-z0-9._~-]{20,4096}\z/)
  path = session_token_path
  fail_contract("refusing to replace cached Audiobookshelf session") if path.exist? || path.symlink?
  path.open(File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(token) }
end

def remove_session_token
  path = session_token_path
  read_session_token
  path.unlink
end

def write_artifact(item_id)
  fail_contract("report root is unavailable or unsafe") unless REPORT_ROOT.directory? && !REPORT_ROOT.symlink?
  fail_contract("refusing to replace persistence artifact") if artifact_path.exist? || artifact_path.symlink?
  artifact_path.open(File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
    file.write(JSON.generate({ "item_id" => safe_id(item_id), "current_time" => PROGRESS_SECONDS }))
  end
end

def read_artifact
  fail_contract("persistence artifact is unavailable or unsafe") unless
    artifact_path.file? && !artifact_path.symlink?
  JSON.parse(artifact_path.read)
rescue JSON::ParserError
  fail_contract("persistence artifact is malformed")
end

def canonical_library_state(libraries)
  JSON.generate(libraries.sort_by { |library| safe_id(library.fetch("id")) })
end

def write_state_artifact(name, libraries)
  path = artifact_path(name)
  fail_contract("report root is unavailable or unsafe") unless REPORT_ROOT.directory? && !REPORT_ROOT.symlink?
  fail_contract("refusing to replace state artifact") if path.exist? || path.symlink?
  path.open(File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
    file.write(canonical_library_state(libraries))
  end
end

def assert_state_artifact(name, libraries)
  path = artifact_path(name)
  fail_contract("state artifact is unavailable or unsafe") unless path.file? && !path.symlink?
  fail_contract("check mode mutated Audiobookshelf library state") unless
    path.binread == canonical_library_state(libraries)
end

def remove_state_artifact(name)
  path = artifact_path(name)
  fail_contract("state artifact is unavailable or unsafe") unless path.file? && !path.symlink?
  path.unlink
end

def audiobookshelf_playbook_command(playbook, tags)
  repo_root = Pathname.new(ENV.fetch("PLATFORM_REPO_ROOT")).expand_path
  vault_file = ENV.fetch("PLATFORM_CONTRACT_VAULT_FILE")
  vault_password_file = ENV.fetch("PLATFORM_CONTRACT_VAULT_PASSWORD_FILE")
  command = [
    "ansible-playbook", "-i", "inventory/local.yml",
    "--vault-password-file", vault_password_file,
    "-e", "@#{vault_file}",
    "-e", "platform_vault_file=#{vault_file}",
    "-e", "nas_docker_root=#{ENV.fetch('PLATFORM_DOCKER_ROOT')}",
    "-e", "nas_media_root=#{ENV.fetch('PLATFORM_MEDIA_ROOT')}",
    "-e", "platform_compose_kind=integration",
    "-e", "platform_beszel_agent_kind=portable",
    "-e", "deployment_bundle_test_mode=true",
    "-e", "deployment_bundle_allow_dirty_controller=true",
    repo_root.join(playbook).to_s, "--tags", tags
  ]
  Open3.capture3(
    { "PLATFORM_VAULT_FILE" => vault_file }, *command, chdir: repo_root.to_s
  )
end

def inactive_admin_diagnostic_leaked?(output, vault, username, password, retained_token)
  vault_credentials = vault.each_with_object([]) do |(key, value), credentials|
    credentials << value if
      key.to_s.match?(VAULT_CREDENTIAL_KEY) && value.is_a?(String) && !value.empty?
  end
  (vault_credentials + [username, password, retained_token]).uniq.any? do |secret|
    !secret.to_s.empty? && output.include?(secret)
  end
end

def inactive_admin_refusal!(username, password, retained_token, vault)
  limitation = "Managed Audiobookshelf administrator cannot authenticate. Pinned Audiobookshelf 2.36.0"
  recovery_username = "task9-contract-recovery-root"
  users = request("get", "/api/users", token: retained_token).last.fetch("users")
  original = exact_vault_named_administrator(users, username, type: "root", active: true)
  original_id = safe_id(original.fetch("id"))
  temporary_id = nil

  begin
    request(
      "patch", "/api/users/#{original_id}", token: retained_token,
      body: { username: recovery_username, type: "root", isActive: true }
    )
    request("post", "/login", body: { username: username, password: password }, expected: [401])
    request(
      "post", "/api/users", token: retained_token,
      body: { username: username, password: password, type: "admin", isActive: true }
    )
    fixture_users = request("get", "/api/users", token: retained_token).last.fetch("users")
    temporary = exact_vault_named_administrator(fixture_users, username, type: "admin", active: true)
    temporary_id = safe_id(temporary.fetch("id"))
    request(
      "patch", "/api/users/#{temporary_id}", token: retained_token,
      body: { type: "admin", isActive: false }
    )
    inactive_users = request("get", "/api/users", token: retained_token).last.fetch("users")
    exact_vault_named_administrator(inactive_users, username, type: "admin", active: false)
    request("post", "/login", body: { username: username, password: password }, expected: [401])

    [["site.yml", "audiobookshelf"], ["verify.yml", "platform_verify_audiobookshelf"]].each do |playbook, tags|
      stdout, stderr, status = audiobookshelf_playbook_command(playbook, tags)
      combined = stdout + stderr
      fail_contract("inactive administrator #{playbook} unexpectedly succeeded") if status.success?
      fail_contract("inactive administrator #{playbook} omitted the fixed product limitation") unless
        combined.include?(limitation)
      fail_contract("inactive administrator diagnostic leaked vault or bearer data") if
        inactive_admin_diagnostic_leaked?(combined, vault, username, password, retained_token)
      stdout.replace("\0" * stdout.bytesize)
      stderr.replace("\0" * stderr.bytesize)
      combined.replace("\0" * combined.bytesize)
    end
  ensure
    request("delete", "/api/users/#{temporary_id}", token: retained_token) if temporary_id
    request(
      "patch", "/api/users/#{original_id}", token: retained_token,
      body: { username: username, type: "root", isActive: true }
    )
    restored_login, restored = request("post", "/login", body: { username: username, password: password })
    restored_token = restored.dig("user", "accessToken")
    restored_users = request("get", "/api/users", token: restored_token).last.fetch("users")
    restored_root = exact_vault_named_administrator(restored_users, username, type: "root", active: true)
    fail_contract("inactive administrator fixture did not recover exact user state") unless
      restored_login.code.to_i == 200 && safe_id(restored_root.fetch("id")) == original_id
  end
end

case MODE
when "seed-fixture-only"
  seed_fixture
  puts "Audiobookshelf media fixture prepared before deployment"
  exit 0
when "authentication-budget-self-test"
  integration = Pathname.new(ENV.fetch("PLATFORM_REPO_ROOT")).join("tests/integration.sh").read
  contract_modes = integration.scan(/^\s*run_audiobookshelf_contract\s+([a-z0-9-]+)/).flatten
  expected_modes = %w[
    run inactive-admin-refusal duplicate-admin-api-refusal
    duplicate-library-create duplicate-library-verify duplicate-library-assert-output
    duplicate-library-cleanup run check-repair-seed assert-check-output
    check-repair-unchanged run check-repair-cleanup drift drift-verify run
    check-missing-seed assert-check-output check-missing-unchanged check-missing-cleanup
    run seed-progress assert-persistence authentication-session-cleanup
  ]
  fail_contract("Audiobookshelf integration contract call sequence differs") unless contract_modes == expected_modes

  tagged_role_calls = integration.scan(/run_play --tags audiobookshelf/).length
  check_role_calls = integration.scan(/run_play --tags audiobookshelf --check --diff/).length
  verify_role_calls = integration.scan(/^\s*if run_audiobookshelf_verify_only/).length
  fail_contract("Audiobookshelf integration role call sequence differs") unless
    tagged_role_calls == 7 && check_role_calls == 2 && verify_role_calls == 4
  fail_contract("Audiobookshelf integration session cleanup lifecycle differs") unless
    integration.include?("run_audiobookshelf_contract authentication-session-cleanup") &&
      integration.include?("trap cleanup_integration_on_exit EXIT") &&
      integration.include?("trap 'exit 130' HUP INT TERM") &&
      integration.include?('cleanup_sandbox "$sandbox"')

  repo_root = Pathname.new(ENV.fetch("PLATFORM_REPO_ROOT"))
  main_tasks = YAML.safe_load_file(repo_root.join("roles/audiobookshelf/tasks/main.yml"))
  managed_tasks = YAML.safe_load_file(repo_root.join("roles/audiobookshelf/tasks/managed_users.yml"))
  auth_model = exact_role_auth_model(main_tasks, managed_tasks)
  expect_contract_failure("an added Audiobookshelf role authentication call was accepted") do
    exact_role_auth_model(main_tasks + [main_tasks.fetch(auth_model.fetch(:main_task_indexes).first)], managed_tasks)
  end
  managed_user_count = generated_audiobookshelf_user_count(
    repo_root.join("tests/generate-ephemeral-vault.sh").read
  )
  baseline_runs = exact_baseline_role_runs(integration)
  normal_role_logins = auth_model.fetch(:reconcile_admin) +
                       auth_model.fetch(:managed_per_user) * managed_user_count
  check_role_logins = auth_model.fetch(:check_admin)
  verify_role_logins_per_run = auth_model.fetch(:verify_admin)
  initial_role_logins = baseline_runs.fetch(:normal) * normal_role_logins +
                        baseline_runs.fetch(:check) * check_role_logins
  scenario_role_logins = (tagged_role_calls - check_role_calls) * normal_role_logins +
                         check_role_calls * check_role_logins +
                         verify_role_calls * verify_role_logins_per_run +
                         auth_model.fetch(:reconcile_admin) + verify_role_logins_per_run
  harness_logins = direct_harness_login_count(repo_root.join("tests/contracts/audiobookshelf.sh").read)
  total_logins = initial_role_logins + scenario_role_logins + harness_logins
  fail_contract("Audiobookshelf integration authentication budget is exhausted") unless total_logins < 40

  test_token = "contract-session-token"
  write_session_token(test_token)
  fail_contract("Audiobookshelf cached session did not round-trip") unless read_session_token == test_token
  expect_contract_failure("Audiobookshelf cached session replacement was accepted") do
    write_session_token("replacement-session-token")
  end
  session_token_path.chmod(0o644)
  expect_contract_failure("Audiobookshelf cached session unsafe mode was accepted") { read_session_token }
  session_token_path.chmod(0o600)
  expect_contract_failure("Audiobookshelf cached session foreign ownership was accepted") do
    read_session_token(expected_uid: Process.uid + 1)
  end
  remove_session_token
  fail_contract("Audiobookshelf cached session cleanup failed") if session_token_path.exist?
  session_token_path.mkdir(0o700)
  expect_contract_failure("Audiobookshelf cached session directory was accepted") { read_session_token }
  session_token_path.rmdir
  fail_contract("Audiobookshelf FIFO fixture could not be created") unless
    system("mkfifo", session_token_path.to_s, out: File::NULL, err: File::NULL)
  expect_contract_failure("Audiobookshelf cached session FIFO was accepted") { read_session_token }
  session_token_path.unlink
  symlink_target = REPORT_ROOT.join(".audiobookshelf-contract-session-target")
  symlink_target.open(File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(test_token) }
  File.symlink(symlink_target, session_token_path)
  expect_contract_failure("Audiobookshelf cached session symlink was accepted") { read_session_token }
  session_token_path.unlink
  symlink_target.unlink
  puts "Audiobookshelf authentication budget self-test passed"
  exit 0
when "administrator-selection-self-test"
  username = "vault-root"
  root = { "id" => "root-id", "username" => username, "type" => "root", "isActive" => true }
  managed = { "id" => "reader-id", "username" => "managed-reader", "type" => "user", "isActive" => true }
  unmanaged = { "id" => "friend-id", "username" => "unmanaged-friend", "type" => "admin", "isActive" => true }
  users = [managed, root, unmanaged]
  fail_contract("vault-named root was not selected independently of other users") unless
    exact_vault_named_administrator(users, username, type: "root", active: true) == root

  duplicate = root.merge("id" => "duplicate-root-id")
  expect_contract_failure("duplicate vault-named root was accepted") do
    exact_vault_named_administrator(users + [duplicate], username, type: "root", active: true)
  end
  expect_contract_failure("absent vault-named root was accepted") do
    exact_vault_named_administrator([managed, unmanaged], username, type: "root", active: true)
  end
  expect_contract_failure("inactive vault-named root was accepted") do
    exact_vault_named_administrator(users.map { |user| user.equal?(root) ? user.merge("isActive" => false) : user },
                                    username, type: "root", active: true)
  end
  expect_contract_failure("non-root vault-named administrator was accepted") do
    exact_vault_named_administrator(users.map { |user| user.equal?(root) ? user.merge("type" => "admin") : user },
                                    username, type: "root", active: true)
  end
  puts "Audiobookshelf administrator selection self-test passed"
  exit 0
when "secret-redaction-self-test"
  vault = {
    "vault_immich_db_name" => "immich",
    "vault_immich_db_username" => "immich",
    "vault_password_policy" => "password-policy",
    "vault_monkey" => "ordinary-simian-value",
    "vault_service_password" => "credential-password-sentinel",
    "vault_service_password_hash" => "credential-hash-sentinel",
    "vault_service_token" => "credential-token-sentinel",
    "vault_service_private_key" => "credential-key-sentinel"
  }
  username = "explicit-audiobookshelf-username"
  password = "explicit-audiobookshelf-password"
  token = "runtime-bearer-token"
  begin
    classifier = method(:inactive_admin_diagnostic_leaked?)
  rescue NameError
    fail_contract("inactive administrator diagnostic secret classifier is absent")
  end
  ordinary_output = "TASK [immich : verify topology for ordinary-simian-value and password-policy]"
  fail_contract("ordinary topology or service data was classified as secret") if
    classifier.call(ordinary_output, vault, username, password, token)
  {
    "credential-password-sentinel" => "vault password",
    "credential-hash-sentinel" => "vault hash",
    "credential-token-sentinel" => "vault token",
    "credential-key-sentinel" => "vault key",
    username => "explicit Audiobookshelf username",
    password => "explicit Audiobookshelf password",
    token => "runtime bearer token"
  }.each do |secret, label|
    fail_contract("#{label} was not classified as secret") unless
      classifier.call("diagnostic contains #{secret}", vault, username, password, token)
  end
  puts "Audiobookshelf diagnostic secret redaction self-test passed"
  exit 0
when "drift-recovery-self-test"
  original_server_settings = OWNED_SERVER_SETTINGS.merge(UNOWNED_SERVER_SETTINGS_SENTINEL => 5)
  drifted_server_settings = selected_server_settings(
    original_server_settings.merge(DRIFT_SERVER_SETTINGS)
  )
  fail_contract("boolean drift was not accepted as typed server settings") unless
    drifted_server_settings.fetch("scannerParseSubtitle") == false
  original = {
    "id" => "contract-library",
    "name" => LIBRARY_NAME,
    "folders" => [{
      "id" => "contract-folder",
      "fullPath" => "/audiobooks",
      "libraryId" => "contract-library",
      "addedAt" => 1_725_000_000_000
    }],
    "mediaType" => "book",
    "provider" => "google",
    "icon" => "database",
    "settings" => DESIRED_SETTINGS.merge("metadataPrecedence" => %w[folderStructure audioMetatags])
  }
  write_drift_snapshot(original, original_server_settings)
  drifted = original.merge(
    "provider" => "audible", "icon" => "podcast", "settings" => DRIFT_SETTINGS
  )
  snapshot = read_drift_snapshot
  fail_contract("drift recovery self-test changed the unrelated settings sentinel") unless
    snapshot.fetch("server_settings").fetch(UNOWNED_SERVER_SETTINGS_SENTINEL) == 5
  recovered = drifted.merge(snapshot_state_for_library(snapshot, drifted))
  fail_contract("drift recovery self-test did not restore exact provider, icon, and settings") unless
    exact_snapshot_recovered?([recovered], snapshot) &&
      recovered["provider"] == "google" && recovered["icon"] == "database" &&
      recovered["settings"] == original["settings"]
  folder_identity_mutation = JSON.parse(JSON.generate(recovered))
  folder_identity_mutation.fetch("folders").fetch(0)["id"] = "replacement-folder"
  fail_contract("folder identity replacement was accepted as exact recovery") if
    exact_snapshot_recovered?([folder_identity_mutation], snapshot)
  remove_drift_snapshot
  expect_contract_failure { read_drift_snapshot }

  drift_snapshot_directory.mkdir(0o700)
  drift_snapshot_path.open(File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write("{") }
  expect_contract_failure { read_drift_snapshot }
  drift_snapshot_path.unlink
  drift_snapshot_directory.rmdir

  write_drift_snapshot(original, original_server_settings)
  drift_snapshot_path.chmod(0o644)
  expect_contract_failure { read_drift_snapshot }
  drift_snapshot_path.chmod(0o600)
  snapshot = read_drift_snapshot
  expect_contract_failure { snapshot_state_for_library(snapshot, drifted.merge("id" => "other-library")) }
  remove_drift_snapshot
  puts "Audiobookshelf exact drift snapshot recovery self-test passed"
  exit 0
when "audio-self-test"
  source = tagged_wave
  fail_contract("valid tagged RIFF/WAVE source was rejected") unless tagged_wave_title(source) == FIXTURE_TITLE
  broken_riff = source.dup
  broken_riff.setbyte(0, "X".ord)
  fail_contract("invalid RIFF signature was accepted") if tagged_wave_title(broken_riff)
  wrong_title = source.sub(FIXTURE_TITLE, "Task 9 Contract Faux")
  fail_contract("wrong embedded title was accepted") if tagged_wave_title(wrong_title) == FIXTURE_TITLE

  exact_item = { "relPath" => "task-9-contract-book", "media" => { "metadata" => { "title" => "Changed title" } } }
  fail_contract("exact fixture source identity was rejected") unless matching_fixture_item([exact_item]) == exact_item
  title_only = { "relPath" => "unrelated", "media" => { "metadata" => { "title" => FIXTURE_TITLE } } }
  fail_contract("mutable title-only fixture identity was accepted") if matching_fixture_item([title_only])
  expect_contract_failure do
    matching_fixture_item([exact_item, exact_item.merge("id" => "duplicate")])
  end
  range = source.byteslice(0, 128)
  content_range = "bytes 0-127/#{source.bytesize}"
  fail_contract("exact source playback proof was rejected") unless
    exact_playback?(source, source.dup, range.dup, content_range)
  wrong_full = source.dup
  wrong_full.setbyte(127, wrong_full.getbyte(127) ^ 1)
  fail_contract("mutated full response was accepted") if
    exact_playback?(source, wrong_full, range, content_range)
  wrong_range = range.dup
  wrong_range.setbyte(12, wrong_range.getbyte(12) ^ 1)
  fail_contract("mutated ranged response was accepted") if
    exact_playback?(source, source, wrong_range, content_range)
  fail_contract("wrong Content-Range was accepted") if
    exact_playback?(source, source, range, "bytes 0-127/#{source.bytesize + 1}")

  fake_response = Struct.new(:code, :content_type, :body) do
    def [](header)
      header == "Content-Type" ? content_type : nil
    end
  end
  secret = "contract-password-and-bearer-token"
  {
    "application/problem+json; charset=utf-8" => "json",
    "text/plain" => "text",
    "audio/wav" => "binary",
    "application/x-private-#{secret}" => "other"
  }.each do |content_type, kind|
    response = fake_response.new("503", content_type, secret)
    message = unexpected_response_message("get", "/safe", response)
    fail_contract("response classification differs") unless message == "GET /safe returned HTTP 503 (#{kind} response)"
    fail_contract("unexpected response diagnostic leaked sensitive content") if message.include?(secret)
    fail_contract("unexpected response diagnostic is unbounded") if message.bytesize > 96
  end
  puts "Audiobookshelf audio and diagnostic self-test passed"
  exit 0
when "duplicate-library-assert-output"
  output_path = ARGV.fetch(1)
  fail_contract("expected-failure output is unavailable or unsafe") unless
    File.file?(output_path) && !File.symlink?(output_path)
  ids = JSON.parse(artifact_path("duplicate-ids").read).map { |entry| safe_id(entry.fetch("id")) }.sort
  expected = "Managed Audiobookshelf library identity is duplicated at safe IDs: #{ids.join(', ')}"
  fail_contract("duplicate failure omitted safe library IDs") unless File.read(output_path).include?(expected)
  puts "Audiobookshelf duplicate library safe diagnostic passed"
  exit 0
when "assert-check-output"
  output_path = ARGV.fetch(1)
  scenario = ARGV.fetch(2)
  fail_contract("planned-change output is unavailable or unsafe") unless
    File.file?(output_path) && !File.symlink?(output_path)
  expected = case scenario
             when "repair"
               { "AUDIOBOOKSHELF_PLAN_ADMIN_CREATE" => 0,
                 "AUDIOBOOKSHELF_PLAN_ADMIN_REPAIR" => 0,
                 "AUDIOBOOKSHELF_PLAN_LIBRARY_CREATE" => 0,
                 "AUDIOBOOKSHELF_PLAN_LIBRARY_REPAIR" => 1,
                 "AUDIOBOOKSHELF_PLAN_INITIAL_SCAN" => 0 }
             when "missing"
               { "AUDIOBOOKSHELF_PLAN_ADMIN_CREATE" => 0,
                 "AUDIOBOOKSHELF_PLAN_ADMIN_REPAIR" => 0,
                 "AUDIOBOOKSHELF_PLAN_LIBRARY_CREATE" => 1,
                 "AUDIOBOOKSHELF_PLAN_LIBRARY_REPAIR" => 0,
                 "AUDIOBOOKSHELF_PLAN_INITIAL_SCAN" => 1 }
             else
               fail_contract("unknown planned-change scenario")
             end
  output = File.read(output_path)
  expected.each do |marker, count|
    fail_contract("planned-change marker count differs for #{marker}") unless output.scan(/\b#{marker}\b/).length == count
  end
  puts "Audiobookshelf planned-change output contract passed"
  exit 0
when "check-repair-cleanup"
  remove_state_artifact("check-repair")
  puts "Audiobookshelf repair check-mode artifact removed"
  exit 0
when "check-missing-cleanup"
  remove_state_artifact("check-missing")
  puts "Audiobookshelf create check-mode artifact removed"
  exit 0
when "authentication-session-cleanup"
  remove_session_token
  puts "Audiobookshelf cached contract session removed"
  exit 0
end

vault_yaml, vault_error, vault_status = Open3.capture3(
  "ansible-vault", "view", "--vault-password-file",
  ENV.fetch("PLATFORM_CONTRACT_VAULT_PASSWORD_FILE"),
  ENV.fetch("PLATFORM_CONTRACT_VAULT_FILE")
)
fail_contract("encrypted vault could not be read") unless vault_status.success?
vault = YAML.safe_load(vault_yaml)
vault_yaml.replace("\0" * vault_yaml.bytesize)
vault_error.replace("\0" * vault_error.bytesize)
username = vault.fetch("vault_audiobookshelf_admin_username")
password = vault.fetch("vault_audiobookshelf_admin_password")

reuse_integration_session = ENV["PLATFORM_KIND"] == "integration"
if reuse_integration_session && (session_token_path.exist? || session_token_path.symlink?)
  token = read_session_token
else
  wrong_login_response = if MODE == "run"
                           request(
                             "post", "/login",
                             body: { username: username, password: "contract-wrong-password" }, expected: [401]
                           ).first
                         end
  login_response, login = request("post", "/login", body: { username: username, password: password })
  token = login.dig("user", "accessToken")
  fail_contract("vault administrator login did not return a token") if token.to_s.empty?
  if MODE == "run"
    limit = Integer(login_response["RateLimit-Limit"], 10)
    wrong_remaining = Integer(wrong_login_response["RateLimit-Remaining"], 10)
    login_remaining = Integer(login_response["RateLimit-Remaining"], 10)
    fail_contract("pinned authentication rate contract differs") unless
      limit == 40 && wrong_remaining == login_remaining + 1
    puts "Audiobookshelf authentication call budget passed"
  end
  write_session_token(token) if reuse_integration_session
end

if MODE == "inactive-admin-refusal"
  inactive_admin_refusal!(username, password, token, vault)
  puts "Audiobookshelf inactive administrator refusal and recovery passed"
  exit 0
end

_response, library_payload = request("get", "/api/libraries", token: token)
libraries = library_payload.is_a?(Hash) ? library_payload.fetch("libraries", []) : library_payload
managed = libraries.select { |library| library["name"] == LIBRARY_NAME }
case MODE
when "duplicate-admin-api-refusal"
  request(
    "post", "/api/users", token: token,
    body: { username: username, password: "contract-duplicate-password", type: "admin", isActive: true },
    expected: [400]
  )
  puts "Audiobookshelf API duplicate administrator refusal passed"
  exit 0
when "duplicate-library-create"
  fail_contract("duplicate fixture requires exactly one managed library") unless managed.length == 1
  _duplicate_response, duplicate = request(
    "post", "/api/libraries", token: token,
    body: {
      name: LIBRARY_NAME, folders: [{ path: "/audiobooks" }], mediaType: "book",
      provider: "audible", icon: "podcast", settings: DESIRED_SETTINGS
    }
  )
  write_state_artifact("duplicate-ids", [managed.fetch(0), duplicate].map { |library| { "id" => safe_id(library.fetch("id")) } })
  puts "Audiobookshelf duplicate library fixture created"
  exit 0
when "duplicate-library-verify"
  fail_contract("duplicate managed library fixture is absent") unless managed.length == 2
  managed.each { |library| safe_id(library.fetch("id")) }
  puts "Audiobookshelf duplicate library fixture verified"
  exit 0
when "duplicate-library-cleanup"
  fail_contract("duplicate cleanup requires two managed libraries") unless managed.length == 2
  retained_id = safe_id(managed.min_by { |library| library.fetch("createdAt") }.fetch("id"))
  managed.reject { |library| safe_id(library.fetch("id")) == retained_id }.each do |library|
    request("delete", "/api/libraries/#{safe_id(library.fetch('id'))}", token: token)
  end
  remove_state_artifact("duplicate-ids")
  puts "Audiobookshelf duplicate library fixture removed"
  exit 0
when "check-missing-unchanged"
  assert_state_artifact("check-missing", libraries)
  fail_contract("missing library check-mode fixture was recreated") unless managed.empty? && libraries.empty?
  puts "Audiobookshelf create check-mode state remained immutable"
  exit 0
end

fail_contract("expected exactly one managed audiobook library") unless managed.length == 1 && libraries.length == 1
library = managed.fetch(0)
library_id = safe_id(library.fetch("id"))
fail_contract("managed library media type differs") unless library["mediaType"] == "book"
folders = library.fetch("folders").map { |folder| { "path" => folder["fullPath"] || folder.fetch("path") } }
fail_contract("managed library must be rooted exactly at /audiobooks") unless folders == [{ "path" => "/audiobooks" }]

if MODE == "run"
  server_settings = selected_server_settings(authoritative_server_settings(token))
  fail_contract("owned Audiobookshelf server settings differ") unless
    server_settings.slice(*OWNED_SERVER_SETTINGS.keys) == OWNED_SERVER_SETTINGS
  if drift_snapshot_directory.exist? || drift_snapshot_directory.symlink?
    snapshot = read_drift_snapshot
    fail_contract("reconciliation did not restore exact library drift state") unless
      exact_snapshot_recovered?(libraries, snapshot)
    fail_contract("reconciliation changed an unrelated server setting") unless
      server_settings.fetch(UNOWNED_SERVER_SETTINGS_SENTINEL) ==
        snapshot.fetch("server_settings").fetch(UNOWNED_SERVER_SETTINGS_SENTINEL)
    remove_drift_snapshot
  end
end

case MODE
when "drift"
  server_settings = selected_server_settings(authoritative_server_settings(token))
  fail_contract("server-settings drift fixture requires exact owned baseline") unless
    server_settings.slice(*OWNED_SERVER_SETTINGS.keys) == OWNED_SERVER_SETTINGS
  write_drift_snapshot(library, server_settings)
  request(
    "patch", "/api/libraries/#{library_id}", token: token,
    body: drifted_library_state(exact_library_state(library))
  )
  request("patch", "/api/settings", token: token, body: DRIFT_SERVER_SETTINGS)
  puts "Audiobookshelf library and server-settings drift seeded"
  exit 0
when "check-repair-seed"
  request(
    "patch", "/api/libraries/#{library_id}", token: token,
    body: drifted_library_state(exact_library_state(library))
  )
  current = request("get", "/api/libraries", token: token).last.fetch("libraries")
  write_state_artifact("check-repair", current)
  puts "Audiobookshelf library drift seeded"
  exit 0
when "drift-recover"
  snapshot = read_drift_snapshot
  original_state = snapshot_state_for_library(snapshot, library)
  request(
    "patch", "/api/libraries/#{library_id}", token: token,
    body: original_state
  )
  request("patch", "/api/settings", token: token, body: snapshot.fetch("server_settings"))
  recovered = request("get", "/api/libraries", token: token).last.fetch("libraries")
  recovered_server_settings = selected_server_settings(authoritative_server_settings(token))
  fail_contract("library drift recovery did not restore exact state") unless
    exact_snapshot_recovered?(recovered, snapshot)
  fail_contract("server-settings drift recovery did not restore exact state") unless
    recovered_server_settings == snapshot.fetch("server_settings")
  remove_drift_snapshot
  puts "Audiobookshelf library and server-settings drift recovered"
  exit 0
when "drift-verify"
  snapshot = read_drift_snapshot
  original_state = snapshot_state_for_library(snapshot, library)
  expected_server_settings = snapshot.fetch("server_settings").merge(DRIFT_SERVER_SETTINGS)
  drifted_server_settings = selected_server_settings(authoritative_server_settings(token))
  fail_contract("library drift fixture is absent") unless
    exact_library_state(library) == drifted_library_state(original_state)
  fail_contract("server-settings drift fixture or unrelated sentinel differs") unless
    drifted_server_settings == expected_server_settings
  puts "Audiobookshelf library and server-settings drift verified"
  exit 0
when "drift-commit"
  snapshot = read_drift_snapshot
  original_state = snapshot_state_for_library(snapshot, library)
  expected_server_settings = snapshot.fetch("server_settings").merge(DRIFT_SERVER_SETTINGS)
  drifted_server_settings = selected_server_settings(authoritative_server_settings(token))
  fail_contract("library drift fixture changed before snapshot finalization") unless
    exact_library_state(library) == drifted_library_state(original_state)
  fail_contract("server-settings drift fixture changed before snapshot finalization") unless
    drifted_server_settings == expected_server_settings
  puts "Audiobookshelf library and server-settings drift snapshot retained for reconciliation"
  exit 0
when "check-repair-unchanged"
  assert_state_artifact("check-repair", libraries)
  puts "Audiobookshelf repair check-mode state remained immutable"
  exit 0
when "check-missing-seed"
  request("delete", "/api/libraries/#{library_id}", token: token)
  current = request("get", "/api/libraries", token: token).last.fetch("libraries")
  write_state_artifact("check-missing", current)
  puts "Audiobookshelf missing library fixture seeded"
  exit 0
end

seed_fixture
container_state = container_fixture_state
fail_contract("fixture container state differs: #{container_state}") unless
  %w[unconfigured exact].include?(container_state)
_items_response, items_payload = request(
  "get", "/api/libraries/#{library_id}/items?limit=100&minified=0", token: token
)
fail_contract("managed library items response is malformed") unless
  items_payload.is_a?(Hash) && items_payload["results"].is_a?(Array)
item = matching_fixture_item(items_payload.fetch("results"))
fail_contract("role-owned initial scan did not discover the pre-deployment fixture") unless item
item_id = safe_id(item.fetch("id"))
_item_response, full_item = request("get", "/api/items/#{item_id}?expanded=1", token: token)
audio_file = full_item.dig("media", "audioFiles")&.first
fail_contract("fixture item has no playable audio file") unless audio_file
file_id = safe_id(audio_file.fetch("ino"))
full_response, = request("get", "/api/items/#{item_id}/file/#{file_id}", token: token)
range_response, = request(
  "get", "/api/items/#{item_id}/file/#{file_id}", token: token,
  range: "bytes=0-127", expected: [206]
)
source_bytes = FIXTURE_PATH.binread
fail_contract("source fixture title or RIFF/WAVE structure drifted") unless
  tagged_wave_title(source_bytes) == FIXTURE_TITLE
fail_contract("audio playback bytes or range metadata differ from the exact source") unless
  exact_playback?(
    source_bytes, full_response.body.to_s.b, range_response.body.to_s.b,
    range_response["Content-Range"].to_s
  )

case MODE
when "run"
  nil
when "seed-progress"
  request(
    "patch", "/api/me/progress/#{item_id}", token: token,
    body: { currentTime: PROGRESS_SECONDS, duration: 2.0, progress: 0.625, isFinished: false }
  )
  write_artifact(item_id)
when "assert-persistence"
  artifact = read_artifact
  fail_contract("fixture item identity changed after recreation") unless safe_id(artifact.fetch("item_id")) == item_id
  _progress_response, progress = request("get", "/api/me/progress/#{item_id}", token: token)
  current_time = progress.fetch("currentTime").to_f
  fail_contract("playback progress was not retained after recreation") unless
    (current_time - artifact.fetch("current_time").to_f).abs < 0.01
else
  fail_contract("unknown mode: #{MODE}")
end

puts "Audiobookshelf #{MODE} contract passed"
RUBY
