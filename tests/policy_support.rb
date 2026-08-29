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
    arr downloaders bindery kapowarr pinchflat trailarr seerr
  ].freeze
  # Not every vault key belongs to a service; this one is platform-wide.
  GLOBAL_VAULT_KEYS = %w[vault_managed_users].freeze
  EXPECTATION_FIELDS = %w[container_cpus role vault_keys].freeze
# The manifest's status vocabulary. Shared because more than one script decides
# what to check based on whether a service is actually deployed.
REQUIRED_MANIFEST_FIELDS = %w[name role status].freeze
ALLOWED_SERVICE_STATUSES = %w[planned implemented accepted].freeze
IMPLEMENTED_STATUSES = %w[implemented accepted].freeze
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
  def pinned_service_expectations(root, service_statuses, service_names = EXPECTED_SERVICES)
    problems = []
    unless service_statuses.is_a?(Hash)
      problems << "service statuses must be a mapping"
      service_statuses = {}
    end
    status_keys = service_statuses.keys
    unless status_keys.all? { |key| key.is_a?(String) } && status_keys.sort == service_names.sort
      problems << "service statuses must have exactly the rostered service names"
    end
    service_statuses.each do |name, status|
      unless ALLOWED_SERVICE_STATUSES.include?(status)
        problems << "service status for #{name.inspect} must be planned, implemented, or accepted"
      end
    end

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

    documents.each do |name, expectation|
      problems.concat(expectation_problems(name, expectation, service_statuses[name]))
    end

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

  def expectation_problems(service_name, expectation, service_status)
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
    if vault_keys.is_a?(Array) && (!vault_keys.empty? || service_status == "planned")
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
      problems << "#{relative_path} vault_keys must be a nonempty list unless the service is planned"
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

  # Every string a parsed task actually carries, keys included, each one on its
  # own. Policy checks that used to match a pattern against a whole task file
  # read this instead: a module name or a variable that survives only inside a
  # comment is not something the role runs, and a pattern matched against the
  # joined text of a file can span two unrelated tasks and report a violation
  # that neither of them contains.
  def task_strings(node)
    case node
    when Hash then node.flat_map { |key, value| [key.to_s] + task_strings(value) }
    when Array then node.flat_map { |value| task_strings(value) }
    when String then [node]
    else []
    end
  end

  # An env.j2 template is not YAML, but it is not free text either: it is a list
  # of NAME=value assignments. Reading it as those pairs says which variable a
  # name is bound to, which a substring search over the file cannot — and it
  # ignores a commented-out sample of the right assignment sitting above a live
  # line that exports something else.
  def environment_assignments(path)
    File.readlines(path, chomp: true).filter_map do |line|
      stripped = line.strip
      next unless stripped.match?(/\A[A-Z][A-Z0-9_]*=/)

      name, _separator, value = stripped.partition("=")
      [name, value]
    end
  end

  # The paths tasks act on, wherever the module spells them. Used to check that
  # a set of tasks all address the same location, which a substring search over
  # the file cannot say.
  def task_path_arguments(node)
    case node
    when Hash
      node.flat_map do |key, value|
        named = %w[path paths dest].include?(key) && value.is_a?(String) ? [value] : []
        named + task_path_arguments(value)
      end
    when Array then node.flat_map { |value| task_path_arguments(value) }
    else []
    end
  end
  # These checks prove that verification is structurally wired to an observable,
  # service-specific result. The integration run supplies runtime semantic proof;
  # static policy intentionally does not interpret arbitrary Jinja expressions.
  def service_specific_uri?(task, prefixes, service_names)
    uri = task["ansible.builtin.uri"]
    return false unless uri.is_a?(Hash) && uri["url"].is_a?(String)

    url = uri.fetch("url")
    variable_reference = prefixes.any? { |prefix| url.match?(/\b#{Regexp.escape(prefix)}_[A-Za-z0-9_]+\b/) }
    literal_endpoint = service_names.any? do |name|
      url.match?(/(?<![A-Za-z0-9_-])#{Regexp.escape(name)}(?![A-Za-z0-9_-])/)
    end
    variable_reference || literal_endpoint
  end

  def uri_verifies_service?(task, prefixes, service_names)
    uri = task["ansible.builtin.uri"]
    return false unless service_specific_uri?(task, prefixes, service_names)

    return true if uri.key?("status_code")

    register = task["register"]
    register.is_a?(String) && %w[until failed_when].any? do |condition|
      task[condition].to_s.match?(/\b#{Regexp.escape(register)}\b/)
    end
  end

  def assert_verifies_service?(task, validated_registers)
    assertion = task["ansible.builtin.assert"]
    conditions = assertion.is_a?(Hash) ? Array(assertion["that"]) : []
    return false if conditions.empty?

    conditions.all? do |condition|
      next false unless condition.is_a?(String)

      producer = validated_registers.find do |register|
        condition.match?(/\b#{Regexp.escape(register)}(?:\.[A-Za-z_][A-Za-z0-9_]*|\[['"][^'"]+['"]\])/)
      end
      comparison = condition.match(/\A\s*(.+?)\s*(==|!=|>=|<=|>|<|\bin\b|\bis\b)\s*(.+?)\s*\z/m)
      producer && comparison && comparison[1].strip != comparison[3].strip
    end
  end

  def role_has_verification?(tasks_path, service_name, role_name)
    tasks = flatten_tasks(YAML.safe_load_file(tasks_path))
    canonical_name = contract_basename(service_name)
    prefixes = [service_name.tr("-", "_"), role_name, canonical_name.tr("-", "_")].uniq
    service_names = [service_name, role_name, canonical_name].uniq
    expected_tag = "platform_verify_#{canonical_name}"
    validated_registers = Set.new
    verified = false

    tasks.each do |task|
      named = task["name"].is_a?(String) && task["name"].match?(/\b(?:verify|verification)\b/i)
      tagged = Array(task["tags"]).include?(expected_tag)
      evidence = uri_verifies_service?(task, prefixes, service_names) ||
                 assert_verifies_service?(task, validated_registers)
      verified ||= named && tagged && evidence
      register = task["register"]
      if register.is_a?(String) && prefixes.any? { |prefix| register.start_with?("#{prefix}_") } &&
         service_specific_uri?(task, prefixes, service_names)
        validated_registers << register
      end
    end
    verified
  rescue Psych::Exception
    false
  end

  def contract_has_verification?(contract_path, contract_root, service_name, relative_contract_path, registry_entries)
    expected_entry = { "service" => service_name, "path" => relative_contract_path }
    return false unless registry_entries.include?(expected_entry)
    return false unless owned_file?(contract_path, contract_root)
    return false unless File.executable?(contract_path) && File.size?(contract_path)

    _stdout, _stderr, status = Open3.capture3("sh", "-n", contract_path)
    status.success?
  end
end
