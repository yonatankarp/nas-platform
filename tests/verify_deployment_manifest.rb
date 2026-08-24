#!/usr/bin/env ruby
require "digest"
require "yaml"

manifest_path, repository_root, source_manifest_path, platform_kind, compose_kind, git_sha, merge_mode = ARGV
unless git_sha
  abort "usage: verify_deployment_manifest.rb MANIFEST REPO SOURCE_MANIFEST PLATFORM COMPOSE_KIND SHA [require-image-merge]"
end
abort "unknown manifest verification mode #{merge_mode}" if merge_mode && merge_mode != "require-image-merge"
require_image_merge = merge_mode == "require-image-merge"
RUNTIME_FILES = {
  "dozzle" => ["alert_relay.py"],
  "immich" => ["classify_restore.py"]
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
    effective_image = override.key?("image") ? override["image"] : canonical["image"]
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
      path = File.join(service_root, runtime_file)
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
staged_catalog_path = File.join(File.dirname(manifest_path), catalog_relative_path)
abort "staged acquisition catalog is missing" unless File.file?(staged_catalog_path)
staged_catalog_checksum = Digest::SHA256.file(staged_catalog_path).hexdigest
abort "staged acquisition catalog differs from manifest checksum" unless
  staged_catalog_checksum == expected_platform_inputs.first.fetch("checksum_sha256")
if require_image_merge
  abort "platform fixture did not replace an image" unless override_changed_image
  abort "platform fixture did not add an image" unless override_added_image
end

puts "MANIFEST_EXACT: services, files, checksums, and images match"
puts "MANIFEST_EFFECTIVE_IMAGES: platform replacements and additions recorded" if require_image_merge
