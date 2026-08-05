#!/bin/sh
set -eu
set +x

mode=${1:-run}
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
compose=$repo_dir/services/audiobookshelf/compose.yml
mac_compose=$repo_dir/services/audiobookshelf/compose.mac.yml
role=$repo_dir/roles/audiobookshelf/tasks/main.yml
defaults=$repo_dir/roles/audiobookshelf/defaults/main.yml
integration=$repo_dir/tests/integration.sh

fail_contract() {
  printf 'Audiobookshelf contract failed: %s\n' "$1" >&2
  exit 1
}

[ -f "$role" ] || fail_contract 'roles/audiobookshelf/tasks/main.yml is absent'
[ -f "$defaults" ] || fail_contract 'roles/audiobookshelf/defaults/main.yml is absent'
[ -f "$compose" ] || fail_contract 'services/audiobookshelf/compose.yml is absent'
[ -f "$mac_compose" ] || fail_contract 'services/audiobookshelf/compose.mac.yml is absent'

ruby -ryaml - "$compose" "$mac_compose" "$role" "$defaults" "$integration" "$mode" <<'RUBY'
compose_path, mac_path, role_path, defaults_path, integration_path, mode = ARGV
compose = YAML.safe_load_file(compose_path, aliases: true)
mac = YAML.safe_load_file(mac_path, aliases: true)
role = File.read(role_path)
defaults = YAML.safe_load_file(defaults_path)
integration = File.read(integration_path)
service = compose.fetch("services").fetch("audiobookshelf")
expected_image = "ghcr.io/advplyr/audiobookshelf:2.36.0@sha256:180acad33d69c99ed208676465d8edcb268fa46967735579a7810859885b1a8e"
abort "Audiobookshelf contract failed: legacy image pin differs" unless service.fetch("image") == expected_image
abort "Audiobookshelf contract failed: NAS UID/GID differs" unless service.fetch("user") == "1000:100"
abort "Audiobookshelf contract failed: NAS port differs" unless service.fetch("ports") == ["13378:80"]
abort "Audiobookshelf contract failed: storage contract differs" unless service.fetch("volumes") == [
  "${AUDIOBOOKSHELF_CONFIG_PATH:?}:/config",
  "${AUDIOBOOKSHELF_METADATA_PATH:?}:/metadata",
  "${AUDIOBOOKSHELF_MEDIA_PATH:?}:/audiobooks:ro"
]
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
abort "Audiobookshelf contract failed: Mac override may only replace container name and ports" unless
  mac_service.keys.sort == %w[container_name ports] && !mac_service.key?("image")
abort "Audiobookshelf contract failed: managed library must be rooted at /audiobooks" unless
  defaults.fetch("audiobookshelf_library_folders") == [{ "path" => "/audiobooks" }]

if mode == "static"
  required_tasks = [
    "Refuse duplicate managed Audiobookshelf administrators",
    "Refuse unavailable Audiobookshelf administrator authentication",
    "Refuse unexpected Audiobookshelf administrator authentication responses",
    "Report planned Audiobookshelf administrator creation",
    "Report planned Audiobookshelf library creation",
    "Report planned Audiobookshelf library repair",
    "Require exactly the managed Audiobookshelf administrator",
    "Require exactly the managed Audiobookshelf library"
  ]
  required_tasks.each do |name|
    abort "Audiobookshelf contract failed: missing #{name}" unless role.include?("- name: #{name}")
  end
  abort "Audiobookshelf contract failed: role still claims inactive administrator repair" if
    role.include?("not audiobookshelf_existing_admin.isActive") ||
      role.include?("isActive: true\n    status_code: [200]\n  when:\n    - not ansible_check_mode\n    - audiobookshelf_admin_repair_required")
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
MEDIA_LIBRARY = MEDIA_ROOT.join("Media", "Audiobooks")
FIXTURE_DIRECTORY = MEDIA_LIBRARY.join("task-9-contract-book")
FIXTURE_PATH = FIXTURE_DIRECTORY.join("task-9-contract-book.wav")
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
LIBRARY_STATE_KEYS = %w[folders icon mediaType name provider settings].freeze
LIBRARY_FOLDER_STATE_KEYS = %w[addedAt fullPath id libraryId].freeze
DRIFT_SNAPSHOT_KIND = "audiobookshelf-library-drift-snapshot"

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

def write_drift_snapshot(library)
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
    "state" => exact_library_state(library)
  }
  path.open(File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
    file.write(JSON.generate(snapshot))
  end
  require_owned_drift_snapshot!
end

def read_drift_snapshot
  snapshot = JSON.parse(require_owned_drift_snapshot!.binread)
  fail_contract("drift snapshot schema is malformed") unless
    snapshot.is_a?(Hash) && snapshot.keys.sort == %w[kind library_id schema state] &&
      snapshot["schema"] == 1 && snapshot["kind"] == DRIFT_SNAPSHOT_KIND &&
      snapshot["state"].is_a?(Hash) && snapshot["state"].keys.sort == LIBRARY_STATE_KEYS
  snapshot["library_id"] = safe_id(snapshot.fetch("library_id"))
  snapshot["state"] = exact_library_state(
    snapshot.fetch("state"), library_id: snapshot.fetch("library_id")
  )
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

def expect_contract_failure
  pid = fork do
    $stdout.reopen(File::NULL, "w")
    $stderr.reopen(File::NULL, "w")
    yield
    exit! 0
  end
  _waited, status = Process.wait2(pid)
  fail_contract("unsafe drift snapshot was accepted") if status.success?
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
  items.find { |candidate| candidate.dig("media", "metadata", "title") == FIXTURE_TITLE }
end

def exact_playback?(source, full_body, range_body, content_range)
  full_body == source &&
    Digest::SHA256.hexdigest(full_body) == Digest::SHA256.hexdigest(source) &&
    range_body == source.byteslice(0, 128) &&
    content_range == "bytes 0-127/#{source.bytesize}"
end

def seed_fixture
  media_parent = MEDIA_ROOT.join("Media")
  owned_directory!(media_parent, MEDIA_ROOT)
  owned_directory!(MEDIA_LIBRARY, media_parent)
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
end

def artifact_path(name = "persistence")
  REPORT_ROOT.join("audiobookshelf-#{name}.json")
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

def inactive_admin_refusal!(username, password, retained_token, vault_secrets)
  limitation = "Managed Audiobookshelf administrator cannot authenticate. Pinned Audiobookshelf 2.36.0"
  recovery_username = "task9-contract-recovery-root"
  users = request("get", "/api/users", token: retained_token).last.fetch("users")
  original = users.select { |user| user["username"] == username }
  fail_contract("inactive fixture requires exactly one active vault-named root") unless
    users.length == 1 && original.length == 1 && original.fetch(0)["type"] == "root" &&
      original.fetch(0)["isActive"] == true
  original_id = safe_id(original.fetch(0).fetch("id"))
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
    temporary = fixture_users.select { |user| user["username"] == username }
    fail_contract("temporary inactive administrator fixture was not created exactly once") unless temporary.length == 1
    temporary_id = safe_id(temporary.fetch(0).fetch("id"))
    request(
      "patch", "/api/users/#{temporary_id}", token: retained_token,
      body: { type: "admin", isActive: false }
    )
    request("post", "/login", body: { username: username, password: password }, expected: [401])

    [["site.yml", "audiobookshelf"], ["verify.yml", "platform_verify_audiobookshelf"]].each do |playbook, tags|
      stdout, stderr, status = audiobookshelf_playbook_command(playbook, tags)
      combined = stdout + stderr
      fail_contract("inactive administrator #{playbook} unexpectedly succeeded") if status.success?
      fail_contract("inactive administrator #{playbook} omitted the fixed product limitation") unless
        combined.include?(limitation)
      (vault_secrets + [username, password, retained_token]).uniq.each do |secret|
        fail_contract("inactive administrator diagnostic leaked vault or bearer data") if
          !secret.to_s.empty? && combined.include?(secret)
      end
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
    fail_contract("inactive administrator fixture did not recover exact user state") unless
      restored_login.code.to_i == 200 && restored_users.length == 1 &&
        restored_users.fetch(0)["username"] == username && restored_users.fetch(0)["type"] == "root" &&
        restored_users.fetch(0)["isActive"] == true
  end
end

case MODE
when "drift-recovery-self-test"
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
  write_drift_snapshot(original)
  drifted = original.merge(
    "provider" => "audible", "icon" => "podcast", "settings" => DRIFT_SETTINGS
  )
  snapshot = read_drift_snapshot
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

  write_drift_snapshot(original)
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

  path_only = [{ "relPath" => "task-9-contract-book/task-9-contract-book.wav", "media" => {} }]
  fail_contract("path-only fixture identity was accepted") if matching_fixture_item(path_only)
  exact_item = { "relPath" => "unrelated", "media" => { "metadata" => { "title" => FIXTURE_TITLE } } }
  fail_contract("exact extracted title was rejected") unless matching_fixture_item([exact_item]) == exact_item

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
                 "AUDIOBOOKSHELF_PLAN_LIBRARY_REPAIR" => 1 }
             when "missing"
               { "AUDIOBOOKSHELF_PLAN_ADMIN_CREATE" => 0,
                 "AUDIOBOOKSHELF_PLAN_ADMIN_REPAIR" => 0,
                 "AUDIOBOOKSHELF_PLAN_LIBRARY_CREATE" => 1,
                 "AUDIOBOOKSHELF_PLAN_LIBRARY_REPAIR" => 0 }
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

if MODE == "inactive-admin-refusal"
  vault_secrets = vault.values.select { |value| value.is_a?(String) && !value.empty? }
  inactive_admin_refusal!(username, password, token, vault_secrets)
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

case MODE
when "drift"
  write_drift_snapshot(library)
  request(
    "patch", "/api/libraries/#{library_id}", token: token,
    body: drifted_library_state(exact_library_state(library))
  )
  puts "Audiobookshelf library drift seeded"
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
  recovered = request("get", "/api/libraries", token: token).last.fetch("libraries")
  fail_contract("library drift recovery did not restore exact state") unless
    exact_snapshot_recovered?(recovered, snapshot)
  remove_drift_snapshot
  puts "Audiobookshelf library drift recovered"
  exit 0
when "drift-verify"
  snapshot = read_drift_snapshot
  original_state = snapshot_state_for_library(snapshot, library)
  fail_contract("library drift fixture is absent") unless
    exact_library_state(library) == drifted_library_state(original_state)
  puts "Audiobookshelf library drift verified"
  exit 0
when "drift-commit"
  snapshot = read_drift_snapshot
  original_state = snapshot_state_for_library(snapshot, library)
  fail_contract("library drift fixture changed before snapshot finalization") unless
    exact_library_state(library) == drifted_library_state(original_state)
  remove_drift_snapshot
  puts "Audiobookshelf library drift snapshot finalized"
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
request("post", "/api/libraries/#{library_id}/scan", token: token, expected: [200])
deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 45
item = nil
loop do
  _items_response, items_payload = request(
    "get", "/api/libraries/#{library_id}/items?limit=100&minified=0", token: token
  )
  items = items_payload.is_a?(Hash) ? items_payload.fetch("results", []) : items_payload
  item = matching_fixture_item(items)
  break if item
  fail_contract("fixture scan did not discover the tagged audiobook") if
    Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
  sleep 1
end
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
