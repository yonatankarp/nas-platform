#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "pathname"

ROOT = Pathname(__dir__).join("../..").realpath
SERVICES = %w[audiobookshelf beszel dozzle immich jellyfin komga ntfy paperless-ngx tinymediamanager].freeze
ADOPTION_ROOT = "/private/tmp/nas-platform-adoption-root"
COMMITTED_BINDINGS = <<~BINDINGS.lines(chomp: true).map { |line| line.split("\t", 4) }.freeze
  audiobookshelf\tlegacy/audiobookshelf/config\t/config
  audiobookshelf\tlegacy/audiobookshelf/metadata\t/metadata
  audiobookshelf\tlegacy/audiobookshelf/media\t/audiobooks
  audiobookshelf\tlegacy/audiobookshelf/backups\t/metadata/backups
  beszel\tlegacy/beszel/hub\t/beszel_data
  beszel\tlegacy/beszel/agent\t/var/lib/beszel-agent
  beszel\tlegacy/beszel/volume1\t/extra-filesystems/volume1
  beszel\tlegacy/beszel/volume2\t/extra-filesystems/volume2
  dozzle\tlegacy/dozzle/data\t/data
  immich\tlegacy/immich/data\t/data
  immich\tlegacy/immich/thumbs\t/data/thumbs
  immich\tlegacy/immich/encoded-video\t/data/encoded-video
  immich\tlegacy/immich/profile\t/data/profile
  immich\tlegacy/immich/backups\t/data/backups
  immich\tlegacy/immich/model-cache\t/cache
  immich\tlegacy/immich/postgres\t/var/lib/postgresql/data
  jellyfin\tlegacy/jellyfin/config\t/config
  jellyfin\tlegacy/jellyfin/cache\t/cache
  jellyfin\tlegacy/jellyfin/media\t/media
  komga\tlegacy/komga/config\t/config
  komga\tlegacy/komga/library\t/data
  ntfy\tlegacy/ntfy/cache\t/var/cache/ntfy
  ntfy\tlegacy/ntfy/data\t/var/lib/ntfy
  paperless-ngx\tlegacy/paperless-ngx/redis\t/data
  paperless-ngx\tlegacy/paperless-ngx/postgres\t/var/lib/postgresql
  paperless-ngx\tlegacy/paperless-ngx/data\t/usr/src/paperless/data
  paperless-ngx\tlegacy/paperless-ngx/cache\t/usr/src/paperless/cache
  paperless-ngx\tlegacy/paperless-ngx/export\t/usr/src/paperless/export
  paperless-ngx\tlegacy/paperless-ngx/tessdata/heb.traineddata\t/usr/share/tesseract-ocr/5/tessdata/heb.traineddata
  paperless-ngx\tlegacy/paperless-ngx/media\t/usr/src/paperless/media
  paperless-ngx\tlegacy/paperless-ngx/consume\t/usr/src/paperless/consume
  tinymediamanager\tlegacy/tinymediamanager/data\t/data
  tinymediamanager\tlegacy/tinymediamanager/movies\t/media/Movies
  tinymediamanager\tlegacy/tinymediamanager/series\t/media/Series
BINDINGS

READ_ONLY_BINDINGS = %w[
  audiobookshelf:legacy/audiobookshelf/media
  beszel:legacy/beszel/volume1
  beszel:legacy/beszel/volume2
  jellyfin:legacy/jellyfin/media
  komga:legacy/komga/library
  paperless-ngx:legacy/paperless-ngx/tessdata/heb.traineddata
].freeze
COMMITTED_BINDINGS.each do |binding|
  binding << (READ_ONLY_BINDINGS.include?("#{binding[0]}:#{binding[1]}") ? "ro" : "rw")
end
TARGET_BINDINGS = (
  COMMITTED_BINDINGS + [["dozzle", "legacy/dozzle/data", "/state", "rw"]]
).freeze

def refuse(message)
  warn "Adoption target override failed: #{message}"
  exit 1
end

def required_environment(paths)
  names = paths.flat_map { |path| path.binread.scan(/\$\{([A-Z][A-Z0-9_]*)(?::[-?][^}]*)?\}/).flatten }.uniq
  names.to_h do |name|
    value = case name
            when "PLATFORM_ADOPTION_ROOT" then ADOPTION_ROOT
            when "PLATFORM_CURRENT_DIR" then "/private/tmp/unused-platform-current-dir"
            when "NAS_DOCKER_ROOT" then "/private/tmp/unused-docker-root"
            when "NAS_MEDIA_ROOT" then "/private/tmp/unused-media-root"
            when /(?:PATH|ROOT)\z/ then "/private/tmp/unused-#{name.downcase.tr('_', '-')}"
            when /PORT/ then "39000"
            when /(?:UID|GID|USER_ID|GROUP_ID)/ then "501"
            when "PLATFORM_PROJECT_NAME" then "nas-platform-adoption-test"
            else "fixture"
            end
    [name, value]
  end
end

reviewed = SERVICES.flat_map do |service|
  ROOT.join("tests/mac/legacy-overrides/#{service}.yml").each_line.filter_map do |line|
    match = line.match(%r{\$\{PLATFORM_MAC_SANDBOX:\?\}/(?<source>legacy/[^:]+):(?<target>/[^:]+?)(?::(?<mode>ro|rw))?\s*$})
    [service, match[:source], match[:target], match[:mode] || "rw"] if match
  end
end.sort
refuse("reviewed legacy mapping differs from committed policy") unless reviewed == COMMITTED_BINDINGS.sort
expected = TARGET_BINDINGS.map { |_, source, target, access| [source, target, access] }.sort

actual = []
SERVICES.each do |service|
  directory = ROOT.join("services", service)
  files = %w[compose.yml compose.mac.yml compose.adoption.yml].map { |name| directory.join(name) }
  refuse("#{service} adoption override is unavailable") unless files.all?(&:file?)
  env = required_environment(files)
  command = ["docker", "compose", *files.flat_map { |path| ["-f", path.to_s] }, "config", "--format", "json"]
  stdout, stderr, status = Open3.capture3(env, *command)
  refuse("#{service} target merge failed: #{stderr.strip}") unless status.success? && stderr.empty?
  merged = JSON.parse(stdout)

  base_stdout, base_stderr, base_status = Open3.capture3(
    required_environment(files.first(2)), "docker", "compose",
    "-f", files[0].to_s, "-f", files[1].to_s, "config", "--format", "json"
  )
  refuse("#{service} target base merge failed: #{base_stderr.strip}") unless base_status.success? && base_stderr.empty?
  target_owned = JSON.parse(base_stdout)
  [merged, target_owned].each do |document|
    document.fetch("services").each_value { |definition| definition.delete("volumes") }
    document.delete("name")
  end
  refuse("#{service} adoption override changes non-volume target semantics") unless merged == target_owned

  configured = JSON.parse(stdout).fetch("services")
  active_services = service == "beszel" ? %w[hub agent-portable socket-proxy] : configured.keys
  active_services.each do |name|
    configured.fetch(name).fetch("volumes", []).each do |mount|
      next unless mount.fetch("type") == "bind" && mount.fetch("source").start_with?("#{ADOPTION_ROOT}/legacy/")

      access = mount.fetch("read_only", false) ? "ro" : "rw"
      actual << [mount.fetch("source").delete_prefix("#{ADOPTION_ROOT}/"), mount.fetch("target"), access]
    end
  end
end

unless actual.sort == expected
  refuse("adoption target bind multiset differs: missing=#{expected - actual} extra=#{actual - expected}")
end

runner = ROOT.join("tests/mac/run.sh").binread
refuse("cutover does not export protected adoption mapping") unless
  runner.include?("PLATFORM_ADOPTION_ROOT") && runner.include?("PLATFORM_ADOPTION_MARKER")
refuse("fresh lane does not reject ambient adoption mapping") unless
  runner.include?("reserved adoption mapping environment")
roles = SERVICES.map { |service| service.tr("-", "_") }.map { |role| ROOT.join("roles", role, "tasks/main.yml").binread }
refuse("not every target role selects the staged adoption override") unless
  roles.all? { |source| source.scan("compose.adoption.yml").length >= 2 }
bundle = ROOT.join("roles/deployment_bundle/tasks/main.yml").binread
refuse("deployment bundle does not stage the adoption override") unless
  bundle.include?("deployment_bundle_adoption_sources") && bundle.include?("compose.adoption.yml")
inputs = ROOT.join("roles/deployment_bundle/tasks/inputs.yml").binread
target = ROOT.join("roles/deployment_bundle/tasks/target.yml").binread
target_validator = ROOT.join("roles/deployment_bundle/files/validate_target.py").binread
refuse("controller validation omits adoption inputs") unless inputs.include?("compose.adoption.yml")
refuse("target validation does not bind root, marker bytes, and checksum") unless
  target.include?("deployment_adoption_root") && target.include?("deployment_adoption_binding_content") &&
  target.include?("deployment_adoption_binding.stat.checksum == platform_adoption_marker")
hooks = ROOT.join("tests/mac/hooks/fixtures-recreate").children.select do |path|
  path.extname == ".sh" && path.binread.include?("docker compose")
end
refuse("adoption recreation hooks cannot discover the staged override") unless
  hooks.all? { |path| path.binread.include?("mac_compose_files") } &&
    ROOT.join("tests/mac/lib.sh").binread.include?('set -- "$@" -f "$mac_current/compose.adoption.yml"')

host_paths = {
  "beszel" => ["beszel_state_root", "legacy/beszel/hub"],
  "dozzle" => ["dozzle_state_root", "legacy/dozzle/data"],
  "ntfy" => ["ntfy_state_root", "legacy/ntfy/data"],
  "paperless_ngx" => ["paperless_tessdata_root", "legacy/paperless-ngx/tessdata"],
  "tinymediamanager" => ["tinymediamanager_state_root", "legacy/tinymediamanager/data"]
}
host_paths.each do |role, (variable, adopted_source)|
  source = ROOT.join("roles", role, "tasks/main.yml").binread
  refuse("#{role} host operations do not select the adopted mounted root") unless
    source.include?(variable) && source.include?(adopted_source) &&
    source.include?("Require the internally derived")
  direct_root = role == "paperless_ngx" ? "paperless-ngx/tessdata" : role.tr("_", "-")
  refuse("#{role} still mutates the divergent fresh host root") if
    source.scan(%r{nas_docker_root[^\n]*#{Regexp.escape(direct_root)}}).length > 3
end
refuse("target containment does not whitelist only committed adoption roots") unless
  target.include?("role_path ~ '/files/validate_target.py'") &&
  target_validator.include?("ADOPTION_SOURCES = (") &&
  target_validator.include?('"legacy/ntfy/data"') &&
  target_validator.include?('"legacy/paperless-ngx/tessdata/heb.traineddata"')

puts "Adoption target overrides: exact legacy binds with target semantics hold"
