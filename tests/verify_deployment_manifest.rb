#!/usr/bin/env ruby
require "digest"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"

if ARGV == ["--self-test"]
  Dir.mktmpdir("deployment-manifest-self-test") do |root|
    repository = File.join(root, "repository")
    release = File.join(root, "release")
    %w[config services/arr roles/arr/files/configarr].each do |relative|
      FileUtils.mkdir_p(File.join(repository, relative))
    end
    FileUtils.mkdir_p(File.join(release, "config"))

    image = "example.invalid/configarr:1.0@sha256:#{'a' * 64}"
    compose_path = File.join(repository, "services/arr/compose.yml")
    catalog_path = File.join(repository, "config/media-acquisition.yml")
    runtime_path = File.join(repository, "roles/arr/files/configarr/config.yml")
    source_manifest_path = File.join(repository, "services/manifest.yml")
    File.write(compose_path, YAML.dump("services" => {
      "configarr" => { "profiles" => ["jobs"], "image" => image }
    }))
    File.write(catalog_path, YAML.dump("projects" => {}))
    File.write(runtime_path, YAML.dump("config" => true))
    File.write(source_manifest_path, YAML.dump("services" => [{
      "name" => "arr", "role" => "arr", "status" => "implemented"
    }]))
    FileUtils.install(catalog_path, File.join(release, "config/media-acquisition.yml"), mode: 0o644)

    git_sha = "b" * 40
    manifest_path = File.join(release, "manifest.yml")
    manifest = {
      "git_sha" => git_sha,
      "platform_kind" => "nas",
      "platform_compose_kind" => "nas",
      "platform_inputs" => [{
        "path" => "config/media-acquisition.yml",
        "mode" => "0644",
        "checksum_sha256" => Digest::SHA256.file(catalog_path).hexdigest
      }],
      "services" => [{
        "name" => "arr",
        "compose_files" => [{
          "path" => "compose.yml",
          "checksum_sha256" => Digest::SHA256.file(compose_path).hexdigest
        }],
        "runtime_files" => [{
          "path" => "configarr.yml",
          "mode" => "0644",
          "checksum_sha256" => Digest::SHA256.file(runtime_path).hexdigest
        }],
        "images" => { "configarr" => image }
      }]
    }
    File.write(manifest_path, YAML.dump(manifest))

    command = [RbConfig.ruby, __FILE__, manifest_path, repository,
               source_manifest_path, "nas", "nas", git_sha]
    _stdout, stderr, status = Open3.capture3(*command)
    abort "manifest self-test baseline failed: #{stderr.lines.first&.strip}" unless status.success?

    manifest.dig("services", 0, "images").delete("configarr")
    File.write(manifest_path, YAML.dump(manifest))
    _stdout, stderr, status = Open3.capture3(*command)
    abort "manifest self-test accepted missing canonical Configarr image" if status.success?
    abort "manifest self-test mutation failed imprecisely" unless
      stderr.include?("deployment manifest differs from exact controller inputs")
  end
  puts "deployment manifest self-test: canonical Configarr discovery holds"
  exit 0
end

manifest_path, repository_root, source_manifest_path, platform_kind, compose_kind, git_sha, merge_mode = ARGV
unless git_sha
  abort "usage: verify_deployment_manifest.rb MANIFEST REPO SOURCE_MANIFEST PLATFORM COMPOSE_KIND SHA [require-image-merge]"
end
abort "unknown manifest verification mode #{merge_mode}" if merge_mode && merge_mode != "require-image-merge"
require_image_merge = merge_mode == "require-image-merge"
RUNTIME_FILES = {
  "arr" => ["configarr.yml"],
  "dozzle" => ["alert_relay.py"],
  "immich" => ["classify_restore.py"]
}.freeze
RUNTIME_FILE_SOURCES = {
  ["arr", "configarr.yml"] => "roles/arr/files/configarr/config.yml"
}.freeze

load_yaml = ->(path) { YAML.safe_load_file(path, aliases: true) }
source_manifest = load_yaml.call(source_manifest_path)
implemented = source_manifest.fetch("services").select do |service|
  %w[implemented accepted].include?(service.fetch("status"))
end
catalog_relative_path = "config/media-acquisition.yml"
catalog_source_path = File.join(repository_root, catalog_relative_path)
expected_platform_inputs = [{
  "path" => "config/media-acquisition.yml",
  "mode" => "0644",
  "checksum_sha256" => Digest::SHA256.file(catalog_source_path).hexdigest
}]

override_changed_image = false
override_added_image = false
expected_services = implemented.map do |service|
  name = service.fetch("name")
  service_root = File.join(repository_root, "services", name)
  canonical_path = File.join(service_root, "compose.yml")
  override_path = File.join(service_root, "compose.#{compose_kind}.yml")
  compose_paths = [canonical_path]
  compose_paths << override_path if File.file?(override_path)

  canonical_services = load_yaml.call(canonical_path).fetch("services")
  override_services = File.file?(override_path) ? load_yaml.call(override_path).fetch("services", {}) : {}
  images = (canonical_services.keys | override_services.keys).sort.each_with_object({}) do |compose_name, result|
    canonical = canonical_services.fetch(compose_name, {})
    override = override_services.fetch(compose_name, {})
    effective_image = if override.key?("image")
                        override["image"]
                      else
                        canonical["image"]
                      end
    result[compose_name] = effective_image if effective_image
    override_changed_image ||= override.key?("image") && canonical["image"] != override["image"]
    override_added_image ||= override.key?("image") && !canonical_services.key?(compose_name)
  end

  {
    "name" => name,
    "compose_files" => compose_paths.map do |path|
      {
        "path" => File.basename(path),
        "checksum_sha256" => Digest::SHA256.file(path).hexdigest
      }
    end,
    "runtime_files" => RUNTIME_FILES.fetch(name, []).map do |runtime_file|
      source = RUNTIME_FILE_SOURCES.fetch([name, runtime_file], File.join("services", name, runtime_file))
      path = File.join(repository_root, source)
      {
        "path" => runtime_file,
        "mode" => "0644",
        "checksum_sha256" => Digest::SHA256.file(path).hexdigest
      }
    end,
    "images" => images
  }
end

expected = {
  "git_sha" => git_sha,
  "platform_kind" => platform_kind,
  "platform_compose_kind" => compose_kind,
  "platform_inputs" => expected_platform_inputs,
  "services" => expected_services
}
actual = load_yaml.call(manifest_path)
abort "deployment manifest differs from exact controller inputs" unless actual == expected

begin
  release_root = File.realpath(File.dirname(manifest_path))
rescue SystemCallError
  abort "deployment release root cannot be resolved safely"
end
catalog_parent_path = File.join(release_root, "config")
staged_catalog_path = File.join(catalog_parent_path, "media-acquisition.yml")
safe_lstat = lambda do |path, diagnostic|
  File.lstat(path)
rescue SystemCallError
  abort diagnostic
end
stat_identity = ->(stat) { [stat.dev, stat.ino, stat.mode] }
release_root_stat = safe_lstat.call(
  release_root, "deployment release root must be a real directory"
)
abort "deployment release root must be a real directory" unless
  release_root_stat.directory? && !release_root_stat.symlink?
catalog_parent_stat = safe_lstat.call(
  catalog_parent_path, "staged acquisition catalog parent must be a real directory"
)
abort "staged acquisition catalog parent must be a real directory" unless
  catalog_parent_stat.directory? && !catalog_parent_stat.symlink?
staged_catalog_stat = safe_lstat.call(
  staged_catalog_path, "staged acquisition catalog is missing"
)
abort "staged acquisition catalog must be a regular non-symlink file" unless
  staged_catalog_stat.file? && !staged_catalog_stat.symlink?
abort "staged acquisition catalog mode must be 0644" unless
  staged_catalog_stat.mode & 0o7777 == 0o644

staged_catalog_digest = Digest::SHA256.new
begin
  File.open(staged_catalog_path, File::RDONLY | File::NOFOLLOW) do |file|
    opened_stat = file.stat
    abort "staged acquisition catalog changed before hashing" unless
      opened_stat.file? && stat_identity.call(opened_stat) == stat_identity.call(staged_catalog_stat)
    while (chunk = file.read(16 * 1024))
      staged_catalog_digest << chunk
    end
  end
rescue SystemCallError
  abort "staged acquisition catalog could not be read safely"
end

release_root_after = safe_lstat.call(
  release_root, "deployment release root changed during verification"
)
catalog_parent_after = safe_lstat.call(
  catalog_parent_path, "staged acquisition catalog path changed during verification"
)
staged_catalog_after = safe_lstat.call(
  staged_catalog_path, "staged acquisition catalog path changed during verification"
)
abort "staged acquisition catalog path changed during verification" unless
  stat_identity.call(release_root_after) == stat_identity.call(release_root_stat) &&
    stat_identity.call(catalog_parent_after) == stat_identity.call(catalog_parent_stat) &&
    stat_identity.call(staged_catalog_after) == stat_identity.call(staged_catalog_stat)
staged_catalog_checksum = staged_catalog_digest.hexdigest
abort "staged acquisition catalog differs from manifest checksum" unless
  staged_catalog_checksum == expected_platform_inputs.first.fetch("checksum_sha256")
if require_image_merge
  abort "platform fixture did not replace an image" unless override_changed_image
  abort "platform fixture did not add an image" unless override_added_image
end

puts "MANIFEST_EXACT: services, files, checksums, and images match"
puts "MANIFEST_EFFECTIVE_IMAGES: platform replacements and additions recorded" if require_image_merge
