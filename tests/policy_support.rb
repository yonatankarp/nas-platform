# Shared strict-YAML and owned-path primitives for repository policy scripts.

require "pathname"
require "yaml"

module PolicySupport
  CONTRACT_BASENAME_EXCEPTIONS = { "paperless-ngx" => "paperless" }.freeze

  # The service roster. Stated here rather than derived from whichever files exist
  # under tests/expected/, because a derived roster would let a new service approve
  # itself: dropping in an expectations file would be the only authorization it ever
  # needed. It lives in this module rather than in one policy script because several
  # of them check different properties of the same roster.
  EXPECTED_SERVICES = %w[
    audiobookshelf beszel dozzle immich jellyfin komga ntfy paperless-ngx
    tinymediamanager
  ].freeze
  # Not every vault key belongs to a service; this one is platform-wide.
  GLOBAL_VAULT_KEYS = %w[vault_managed_users].freeze
  EXPECTATION_FIELDS = %w[container_cpus role vault_keys].freeze
  EMPTY_EXPECTATION = { "role" => nil, "container_cpus" => {}, "vault_keys" => [] }.freeze

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
  # Loads the pinned per-service expectations named by the roster. Returns the
  # documents keyed by service name and a list of problems, so each caller reports
  # them through its own accumulator rather than this module deciding how a policy
  # failure is phrased.
  #
  # These values were Ruby literals, where a typo was a NameError at load time. As
  # YAML a mistyped CPU limit parses as a string instead, and a check comparing it
  # against the Compose file would report a mismatch that reads like a Compose bug,
  # so the data is type-checked where it enters rather than where it is consumed.
  def pinned_service_expectations(root, service_names = EXPECTED_SERVICES)
    problems = []
    documents = service_names.to_h do |service_name|
      relative_path = File.join("tests", "expected", "#{service_name}.yml")
      path = File.join(root, relative_path)
      document = begin
        duplicate_yaml_keys(Psych.parse_stream(File.read(path))).uniq.each do |key|
          problems << "#{relative_path} contains duplicate mapping key #{key}"
        end
        YAML.safe_load_file(path)
      rescue Errno::ENOENT
        problems << "pinned service expectations are missing: #{relative_path}"
        nil
      rescue Psych::Exception => e
        problems << "#{relative_path} is malformed: #{e.message.lines.first.strip}"
        nil
      end

      unless document.nil?
        unless document.is_a?(Hash) && document.keys.sort == EXPECTATION_FIELDS
          problems << "#{relative_path} must define exactly #{EXPECTATION_FIELDS.join(', ')}"
          document = nil
        end
      end
      [service_name, document || EMPTY_EXPECTATION]
    end

    documents.each { |name, expectation| problems.concat(expectation_problems(name, expectation)) }

    # A file for a service the roster does not name would pin expectations nothing
    # reads, so an extra file is rejected rather than ignored.
    present = Dir.glob(File.join(root, "tests", "expected", "*.yml"))
                 .map { |path| File.basename(path, ".yml") }.sort
    unless present == service_names.sort
      problems << "tests/expected must hold exactly one file per rostered service " \
                  "(missing: #{(service_names - present).join(', ')}; " \
                  "unknown: #{(present - service_names).join(', ')})"
    end

    [documents.freeze, problems]
  end

  def expectation_problems(service_name, expectation)
    relative_path = "tests/expected/#{service_name}.yml"
    problems = []
    role = expectation.fetch("role")
    problems << "#{relative_path} role must be a nonempty string" unless role.is_a?(String) && !role.empty?

    container_cpus = expectation.fetch("container_cpus")
    if container_cpus.is_a?(Hash) && !container_cpus.empty?
      container_cpus.each do |container, limit|
        unless limit.is_a?(Numeric)
          problems << "#{relative_path} container_cpus.#{container} must be numeric, got #{limit.class}"
        end
      end
    else
      problems << "#{relative_path} container_cpus must be a nonempty mapping"
    end

    vault_keys = expectation.fetch("vault_keys")
    if vault_keys.is_a?(Array) && !vault_keys.empty?
      # contract_basename is reused for the vault prefix because paperless-ngx is the
      # one service whose keys drop the suffix, and it is the same alias. The two
      # namings are independent concepts that happen to agree, so a change to one must
      # be checked against the other.
      prefix = "vault_#{contract_basename(service_name)}_"
      vault_keys.each do |key|
        unless key.is_a?(String) && key.start_with?(prefix)
          problems << "#{relative_path} vault_keys entries must be prefixed for this service, got #{key.inspect}"
        end
      end
    else
      problems << "#{relative_path} vault_keys must be a nonempty list"
    end
    problems
  end

  def pinned_vault_keys(documents, global_keys = GLOBAL_VAULT_KEYS)
    (global_keys + documents.values.flat_map { |expectation| expectation.fetch("vault_keys") }).sort.freeze
  end

  # Ansible task lists nest through block/rescue/always, so a policy check that
  # looks for a task by name has to see through those sections.
  def flatten_tasks(tasks, flattened = [])
    Array(tasks).each do |task|
      next unless task.is_a?(Hash)

      flattened << task
      %w[block rescue always].each { |section| flatten_tasks(task[section], flattened) }
    end
    flattened
  end
end
