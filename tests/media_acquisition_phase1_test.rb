#!/usr/bin/env ruby

require "yaml"

ROOT = File.expand_path("..", __dir__)

def check(failures, condition, message)
  failures << message unless condition
end

def strict_yaml(relative_path)
  path = File.join(ROOT, relative_path)
  source = File.read(path)
  stream = Psych.parse_stream(source)
  raise "#{relative_path} must contain exactly one YAML document" unless
    stream.children.length == 1

  duplicates = []
  walk = lambda do |node|
    if node.is_a?(Psych::Nodes::Mapping)
      seen = {}
      node.children.each_slice(2) do |key, value|
        if key.is_a?(Psych::Nodes::Scalar)
          duplicates << key.value if seen[key.value]
          seen[key.value] = true
        end
        walk.call(value)
      end
    elsif node.respond_to?(:children) && node.children
      node.children.each { |child| walk.call(child) }
    end
  end
  walk.call(stream)
  raise "#{relative_path} contains duplicate keys: #{duplicates.uniq.join(', ')}" unless
    duplicates.empty?

  YAML.safe_load(source, aliases: false)
end

failures = []
catalog = strict_yaml("config/media-acquisition.yml")
manifest = strict_yaml("services/manifest.yml")
all_vars = strict_yaml("inventory/group_vars/all/main.yml")

expected_status = {
  "arr" => "implemented",
  "downloaders" => "implemented",
  "bindery" => "planned",
  "kapowarr" => "planned",
  "pinchflat" => "planned",
  "trailarr" => "planned",
  "seerr" => "planned"
}

expected_status.each do |name, status|
  check(failures, catalog.dig("projects", name, "status") == status,
        "#{name} catalog status must be #{status}")
  manifest_entry = manifest.fetch("services").find { |entry| entry["name"] == name }
  check(failures, manifest_entry&.fetch("status") == status,
        "#{name} manifest status must be #{status}")
end

expected_safe_defaults = {
  "media_acquisition_adopt_existing_libraries" => false,
  "media_arr_automatic_monitoring_enabled" => false,
  "media_arr_automatic_rename_enabled" => false,
  "media_bazarr_handoff_accepted" => false,
  "media_arr_indexers" => [],
  "media_bazarr_languages" => [],
  "media_bazarr_providers" => []
}
expected_safe_defaults.each do |name, value|
  check(failures, all_vars[name] == value,
        "#{name} must default to #{value.inspect}")
end

%w[nas_hosts mac_hosts].each do |host_group|
  vars = strict_yaml("inventory/group_vars/#{host_group}/main.yml")
  %w[media_usenet_enabled media_torrent_enabled].each do |flag|
    check(failures, vars[flag] == false,
          "#{host_group} #{flag} must remain literal false")
  end
end

if failures.empty?
  puts "media acquisition phase 1: activation contract holds"
else
  warn failures.join("\n")
  exit 1
end
