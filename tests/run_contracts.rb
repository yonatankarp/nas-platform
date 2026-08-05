#!/usr/bin/env ruby
# Validate and execute every registered service contract.

require "open3"
require "pathname"
require "yaml"

ROOT = File.expand_path(ARGV.fetch(0, File.expand_path("..", __dir__)))
CONTRACT_ROOT = File.join(ROOT, "tests", "contracts")
REGISTRY_PATH = File.join(CONTRACT_ROOT, "registry.yml")
failures = []

def duplicate_yaml_keys(node, duplicates = [])
  if node.is_a?(Psych::Nodes::Mapping)
    seen = {}
    node.children.each_slice(2) do |key_node, value_node|
      if key_node.is_a?(Psych::Nodes::Scalar)
        key = key_node.value
        duplicates << key if seen[key]
        seen[key] = true
      end
      duplicate_yaml_keys(value_node, duplicates)
    end
  elsif node.respond_to?(:children) && node.children
    node.children.each { |child| duplicate_yaml_keys(child, duplicates) }
  end
  duplicates
end

def check(failures, condition, message)
  failures << message unless condition
end

def symlink_free_below?(root, path)
  relative = Pathname.new(path).relative_path_from(Pathname.new(root))
  return false if relative.each_filename.include?("..")

  current = root
  relative.each_filename do |component|
    current = File.join(current, component)
    return false if File.symlink?(current)
  end
  true
rescue ArgumentError
  false
end

def owned_contract?(path)
  return false unless File.directory?(CONTRACT_ROOT) && !File.symlink?(CONTRACT_ROOT)
  return false unless File.file?(path) && !File.symlink?(path)
  return false unless symlink_free_below?(ROOT, path)

  File.realpath(path).start_with?(File.realpath(CONTRACT_ROOT) + File::SEPARATOR)
rescue ArgumentError, SystemCallError
  false
end

registry = begin
  check(failures, File.file?(REGISTRY_PATH) && !File.symlink?(REGISTRY_PATH) &&
                  symlink_free_below?(ROOT, REGISTRY_PATH),
        "contract registry must be a regular non-symlink file")
  duplicate_yaml_keys(Psych.parse_stream(File.read(REGISTRY_PATH))).uniq.each do |key|
    check(failures, false, "contract registry contains duplicate mapping key #{key}")
  end
  YAML.safe_load_file(REGISTRY_PATH)
rescue Errno::ENOENT
  check(failures, false, "contract registry is missing")
  nil
rescue Psych::Exception => e
  check(failures, false, "contract registry is malformed: #{e.message.lines.first.strip}")
  nil
end

check(failures, registry.is_a?(Hash), "contract registry top level must be a mapping")
check(failures, registry.is_a?(Hash) && registry.keys == ["contracts"],
      "contract registry must contain exactly a contracts list")
entries = registry.is_a?(Hash) ? registry["contracts"] : nil
check(failures, entries.is_a?(Array), "contract registry must contain a contracts list")
entries = [] unless entries.is_a?(Array)

entries.each do |entry|
  unless entry.is_a?(Hash)
    check(failures, false, "each contract registry entry must be a mapping")
    next
  end
  check(failures, entry.keys.sort == %w[path service],
        "contract registry entries require exactly service and path")
  check(failures, entry["service"].is_a?(String) && !entry["service"].empty?,
        "contract registry service must be a nonempty string")
  check(failures, entry["path"].is_a?(String) && !entry["path"].empty?,
        "contract registry path must be a nonempty string")
end

%w[service path].each do |field|
  values = entries.filter_map { |entry| entry[field] if entry.is_a?(Hash) }
  duplicates = values.tally.select { |_value, count| count > 1 }.keys
  check(failures, duplicates.empty?, "contract registry #{field} values must be unique")
end

entries.each do |entry|
  next unless entry.is_a?(Hash) && entry["path"].is_a?(String)

  relative_path = Pathname.new(entry["path"])
  expected_parent = Pathname.new("tests/contracts")
  check(failures, relative_path.cleanpath == relative_path && relative_path.dirname == expected_parent &&
                  relative_path.extname == ".sh",
        "#{entry['service']}: contract path must be directly beneath tests/contracts")
  path = File.expand_path(entry["path"], ROOT)
  check(failures, owned_contract?(path),
        "#{entry['service']}: contract must be a regular non-symlink file")
  check(failures, File.executable?(path) && File.size?(path),
        "#{entry['service']}: contract must be executable and nonempty") if owned_contract?(path)
end

unless failures.empty?
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} contract registry violation(s)"
end

entries.each do |entry|
  path = File.expand_path(entry.fetch("path"), ROOT)
  _stdout, stderr, syntax = Open3.capture3("sh", "-n", path)
  unless syntax.success?
    warn "FAIL #{entry.fetch('service')}: contract shell syntax is invalid: #{stderr.lines.first&.strip}"
    exit 1
  end

  stdout, stderr, execution = Open3.capture3(path)
  next if execution.success?

  warn stdout unless stdout.empty?
  warn stderr unless stderr.empty?
  warn "FAIL #{entry.fetch('service')}: contract failed with exit #{execution.exitstatus}"
  exit execution.exitstatus || 1
end

puts "contracts: all registered contracts passed"
