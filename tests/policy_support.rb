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

  # The manifest's own statuses, read once. EXPECTED_SERVICES above stays the
  # authorization gate — a service is admitted by being written there, and by the
  # cross-check that the manifest names exactly those services. What follows *from*
  # a status is derived through the three readers below instead of restated,
  # because a second copy of the roster is a copy no test says must agree with the
  # first: promoting one service used to mean hand-editing status literals in half
  # a dozen test files, and nothing failed when one was missed.
  #
  # Malformed or missing input yields an empty mapping rather than raising. The
  # manifest's shape is policed by policy_test.rb and policy_vault_test.rb, which
  # name the defect; a stack trace out of a caller that only wanted the roster
  # would bury that diagnosis under an unrelated suite.
  def service_statuses(root)
    document = begin
      YAML.safe_load_file(File.join(root, "services", "manifest.yml"))
    rescue Errno::ENOENT, Psych::Exception
      nil
    end
    entries = document.is_a?(Hash) && document["services"].is_a?(Array) ? document["services"] : []
    entries.each_with_object({}) do |entry, statuses|
      next unless entry.is_a?(Hash) && entry["name"].is_a?(String) && entry["status"].is_a?(String)

      statuses[entry["name"]] = entry["status"]
    end
  end

  def planned_services(root)
    service_statuses(root).select { |_name, status| status == "planned" }.keys.freeze
  end

  # "accepted" counts as deployed: the status vocabulary distinguishes a service
  # that has passed its operator handoff from one that has not, and both run.
  def implemented_services(root)
    service_statuses(root).select { |_name, status| IMPLEMENTED_STATUSES.include?(status) }.keys.freeze
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

  # A role's task list as Ansible statically assembles it: the named task file
  # with every `import_tasks` of a sibling file spliced in where the import
  # stands. Ansible inlines a static import at parse time, so an imported task
  # is the importing file's task -- same order, same position, same inherited
  # tags. A test that reads one file and calls that the role stops seeing
  # everything the role runs the moment a role is split into stage files, and it
  # stops silently, because the properties it checks are all of the "some task
  # does X" kind that a shorter list simply fails to contradict.
  #
  # Imports are followed and dynamic `ansible.builtin.include_tasks` is
  # deliberately not, which is the whole design and not a shortcut. Ansible
  # leaves an include alone too: it resolves at run time under its own `when:`
  # and `vars:`, its file is frequently phase-gated, and the callers here read
  # those files separately or not at all.
  #
  # The obvious alternative -- walk every *.yml under the role's tasks/ tree --
  # is wrong, and quietly so. `role_has_verification?` below is checked by ten
  # mutation rows in tests/policy_manifest_test.rb that replace
  # roles/ntfy/tasks/main.yml wholesale with a file that verifies nothing and
  # require the failure to be reported. ntfy reaches subscription.yml,
  # managed_users.yml and deployment_summary.yml through include_tasks, so a
  # directory walk would let one of those satisfy the check on behalf of the
  # mutant, and all ten rows would pass while proving nothing. Following the
  # imports says exactly what Ansible would run as one file, and nothing else.
  #
  # +aliases+ is passed through to every file the assembly reads, so a caller
  # that refuses YAML anchors refuses them in the stage files too. It defaults
  # to false because that is what YAML.safe_load_file defaults to, and every
  # caller here replaced a bare YAML.safe_load_file.
  def static_role_tasks(path, aliases: false, importing: [])
    real_path = File.expand_path(path)
    return [] if importing.include?(real_path)

    document = YAML.safe_load_file(real_path, aliases: aliases)
    return [] unless document.is_a?(Array)

    document.flat_map do |task|
      imported = task.is_a?(Hash) ? task["ansible.builtin.import_tasks"] : nil
      file_name = imported.is_a?(Hash) ? imported["file"] : imported
      next [task] unless file_name.is_a?(String)

      target = File.expand_path(File.join(File.dirname(real_path), file_name))
      next [task] unless File.file?(target)

      static_role_tasks(target, aliases: aliases, importing: importing + [real_path])
    end
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

  # Reads the role Ansible would run, not the one file named. This used to be a
  # bare YAML.safe_load_file(tasks_path), which was the same thing only for as
  # long as every service role kept all of its tasks in main.yml.
  #
  # Its one caller in tests/policy_test.rb spends this as
  # `role_verification || contract_verification`, so a role whose verification
  # moves out of main.yml does not fail: it goes on passing on the contract half
  # alone, with the role-side half returning false and nobody told. Anything that
  # narrows what this function can see half-kills that check silently, which is
  # why it reads the assembled role and why the assembly follows imports only.
  def role_has_verification?(tasks_path, service_name, role_name)
    tasks = flatten_tasks(static_role_tasks(tasks_path))
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

# The mechanical scaffolding every check script in this suite used to retype:
# where the repository root is, how one failure joins the accumulator, how a
# subprocess's output is quoted in a diagnostic, and how the run reports itself.
#
# It lives beside PolicySupport rather than in a file of its own because the
# reduced fixture sandbox in tests/policy_mutation_support.rb copies a stated
# list of paths. policy_support.rb is already on that list, so a script that
# starts requiring this module keeps working inside the sandbox; a second
# support file would fail there for a reason unrelated to the mutation the
# sandbox exists to check.
module TestScaffold
  # Resolved from this file, so a check under tests/, tests/ci/ or tests/mac/
  # all name the same root without each restating its own depth.
  ROOT = File.expand_path("..", __dir__)

  module_function

  def check(failures, condition, message)
    failures << message unless condition
  end

  # The tail of a subprocess's output as one grep-able line, blank lines
  # dropped. The copies of this picked 8, 10 or 12 lines for no recorded
  # reason; a caller that needs a particular depth still says so.
  def failure_tail(output, lines = 10)
    output.lines.map(&:strip).reject(&:empty?).last(lines).join(" | ")
  end

  # The epilogue. +subject+ is the line a passing run prints; +summary+ is the
  # counted noun a failing run aborts with. Both are stated by the caller rather
  # than derived, because what a check proves is the one part of this that is
  # never mechanical.
  def report(failures, subject, summary)
    if failures.empty?
      puts subject
      return
    end

    failures.each { |failure| warn "FAIL #{failure}" }
    abort "#{failures.length} #{summary}"
  end
end
