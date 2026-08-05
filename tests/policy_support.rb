# Shared strict-YAML and owned-path primitives for repository policy scripts.

require "pathname"
require "yaml"

module PolicySupport
  CONTRACT_BASENAME_EXCEPTIONS = { "paperless-ngx" => "paperless" }.freeze

  module_function

  def contract_basename(service_name)
    CONTRACT_BASENAME_EXCEPTIONS.fetch(service_name, service_name)
  end

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

  def owned_directory?(path, parent)
    return false if File.symlink?(parent)
    return false unless File.directory?(path) && !File.symlink?(path)
    return false unless symlink_free_below?(parent, path)

    File.realpath(path) == File.join(File.realpath(parent), File.basename(path))
  rescue SystemCallError
    false
  end

  def owned_file?(path, root)
    return false unless File.file?(path) && !File.symlink?(path)
    return false unless owned_directory?(root, File.dirname(root)) && symlink_free_below?(root, path)

    File.realpath(path).start_with?(File.realpath(root) + File::SEPARATOR)
  rescue SystemCallError
    false
  end
end
