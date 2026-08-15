#!/bin/sh

legacy_fixture_unset_controls() {
  unset PLATFORM_LEGACY_FIXTURE_MODE PLATFORM_LEGACY_FIXTURE_SANDBOX \
    PLATFORM_FIXTURE_COMPOSE_PROJECT PLATFORM_FIXTURE_COMPOSE_SERVICE \
    PLATFORM_AUDIOBOOKSHELF_MEDIA_LIBRARY PLATFORM_KOMGA_LIBRARY_PATH \
    PLATFORM_KOMGA_CONFIG_PATH PLATFORM_KOMGA_RUNTIME_CONTEXT \
    PLATFORM_KOMGA_CONTAINER PLATFORM_KOMGA_DOCKER_HEALTH_REQUIRED \
    PLATFORM_TINYMEDIAMANAGER_MOVIES_ROOT PLATFORM_TINYMEDIAMANAGER_SERIES_ROOT \
    PLATFORM_TINYMEDIAMANAGER_SETTINGS_ROOT PLATFORM_JELLYFIN_MEDIA_ROOT \
    PLATFORM_JELLYFIN_TRANSCODE_ROOT PLATFORM_IMMICH_UPLOAD_ROOT \
    PLATFORM_IMMICH_THUMBNAIL_ROOT PLATFORM_PAPERLESS_CONSUME_ROOT \
    PLATFORM_PAPERLESS_EXPORT_ROOT PLATFORM_TINYMEDIAMANAGER_CONTAINER \
    PLATFORM_JELLYFIN_CONTAINER PLATFORM_IMMICH_SERVER_CONTAINER \
    PLATFORM_IMMICH_MACHINE_LEARNING_CONTAINER PLATFORM_IMMICH_REDIS_CONTAINER \
    PLATFORM_IMMICH_POSTGRES_CONTAINER PLATFORM_PAPERLESS_WEBSERVER_CONTAINER || true
}

legacy_fixture_validate() {
  legacy_fixture_variable=$1
  legacy_fixture_suffix=$2
  ruby - "$legacy_fixture_variable" "$legacy_fixture_suffix" <<'RUBY'
variable, suffix = ARGV
value = ENV[variable]
exit 0 unless value
abort "legacy fixture mode is invalid" unless
  ENV["PLATFORM_LEGACY_FIXTURE_MODE"] == "nas-platform-owned-legacy-v1"

sandbox = ENV.fetch("PLATFORM_LEGACY_FIXTURE_SANDBOX")
temporary_parent = ENV.fetch("PLATFORM_MAC_TMPDIR")
abort "sandbox is not normalized" unless sandbox.start_with?("/") &&
  File.expand_path(sandbox) == sandbox && !sandbox.split("/").include?("..")
abort "temporary parent is unsafe" unless File.realpath(temporary_parent) == temporary_parent
abort "sandbox parent differs" unless File.dirname(sandbox) == temporary_parent
abort "sandbox name differs" unless File.basename(sandbox).match?(/\Anas-platform-mac\.[A-Za-z0-9]{6}\z/)
stat = File.lstat(sandbox)
abort "sandbox is unsafe" unless stat.directory? && !stat.symlink? &&
  stat.uid == Process.uid && (stat.mode & 0o777) == 0o700 && File.realpath(sandbox) == sandbox
marker = File.join(sandbox, ".nas-platform-mac-owned")
marker_stat = File.lstat(marker)
abort "marker is unsafe" unless marker_stat.file? && !marker_stat.symlink? &&
  marker_stat.uid == Process.uid && (marker_stat.mode & 0o777) == 0o600
lines = File.readlines(marker, chomp: true)
suffix_id = File.basename(sandbox).split(".", 2).fetch(1).downcase
abort "marker differs" unless lines.include?("schema=1") &&
  lines.include?("project=nas-platform-mac-#{suffix_id}")

abort "suffix is unsafe" unless suffix.match?(/\A[A-Za-z0-9_.\/-]+\z/) &&
  !suffix.start_with?("/") && !suffix.split("/").include?("..")
expected = File.join(sandbox, suffix)
abort "fixture root differs" unless value == expected
current = sandbox
components = suffix.split("/")
components.each_with_index do |component, index|
  current = File.join(current, component)
  begin
    component_stat = File.lstat(current)
    abort "fixture component is unsafe" unless component_stat.directory? &&
      !component_stat.symlink? && component_stat.uid == Process.uid &&
      (component_stat.mode & 0o022).zero?
  rescue Errno::ENOENT
    abort "fixture parent is absent" unless index == components.length - 1
  end
end
RUBY
}
