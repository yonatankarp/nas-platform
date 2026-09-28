# Shared strict-YAML and owned-path primitives for repository policy scripts.

require "pathname"
require "yaml"

module PolicySupport
  CONTRACT_BASENAME_EXCEPTIONS = { "paperless-ngx" => "paperless" }.freeze

  # The service roster, stated rather than derived from tests/expected/, so a new
  # service cannot approve itself by dropping in an expectations file.
  EXPECTED_SERVICES = %w[
    audiobookshelf beszel dozzle immich jellyfin komga nextcloud
    paperless-ngx arr downloaders bindery kapowarr pinchflat trailarr seerr
    vaultwarden karakeep
  ].freeze
  # Platform-wide vault keys no single service's `vault_<name>_` prefix fits:
  # the managed-user lists (their names invert the prefix), the Pushover user key
  # and application tokens, and the healthchecks.io ping URLs.
  GLOBAL_VAULT_KEYS = %w[
    vault_managed_audiobookshelf_users vault_managed_beszel_users
    vault_managed_dozzle_users vault_managed_immich_users
    vault_managed_jellyfin_users vault_managed_komga_users
    vault_managed_paperless_ngx_users
    vault_pushover_alerts_token vault_pushover_containers_token
    vault_pushover_deployments_token vault_pushover_media_token
    vault_pushover_golem_token
    vault_pushover_user_key
    vault_healthchecks_poller_ping_url vault_healthchecks_verify_ping_url
  ].freeze
  # Services that hold no credential at all, by design; closed in both
  # directions (see expectation_problems).
  CREDENTIAL_FREE_SERVICES = %w[vaultwarden].freeze
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

  # The manifest's statuses, read once; EXPECTED_SERVICES stays the authorization
  # gate, and what follows from a status is derived here, not restated. Malformed
  # input yields {} because other scripts name that defect.
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

  # "accepted" counts as deployed.
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
  # Loads the pinned per-service expectations named by the roster, returning the
  # documents and a problem list. Type-checked on entry, since a mistyped YAML
  # value would otherwise read like a Compose bug.
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
      problems.concat(expectation_problems(name, expectation, service_statuses[name], root))
    end

    # The third direction: a stale or invented name here is visited by neither
    # check below (#501 removed seafile), so hold the list to the roster.
    stray_credential_free = CREDENTIAL_FREE_SERVICES - service_names
    unless stray_credential_free.empty?
      problems << "CREDENTIAL_FREE_SERVICES names #{stray_credential_free.join(', ')}, which " \
                  "no service on the roster accounts for: an exemption that outlives its " \
                  "subject exempts nothing and hides the next service that takes the name"
    end

    # A file for an unrostered service would pin expectations nothing reads.
    present = Dir.glob(File.join(root, "tests", "expected", "*.yml"))
                 .map { |path| File.basename(path, ".yml") }.sort
    unless present == service_names.sort
      problems << "tests/expected must hold exactly one file per rostered service " \
                  "(missing: #{(service_names - present).join(', ')}; " \
                  "unknown: #{(present - service_names).join(', ')})"
    end

    [documents.freeze, problems]
  end

  def expectation_problems(service_name, expectation, service_status, root = ROOT)
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
    # Vaultwarden (#547) is credential-free by design: master passwords are
    # user-owned and Ansible owns only the door. The secrets guide is named in
    # prose, not by path: a literal path here would route every policy script to
    # that document. Closed both ways: a listed service with keys fails too.
    credential_free = CREDENTIAL_FREE_SERVICES.include?(service_name)
    # Checked against the role: a role whose argument spec declares a required
    # vault credential cannot be listed as credential-free.
    if credential_free && role.is_a?(String) && !role.empty?
      spec_path = File.join(root, "roles", role, "meta", "argument_specs.yml")
      spec = begin
        YAML.safe_load_file(spec_path)
      rescue Errno::ENOENT, Psych::Exception
        nil
      end
      options = spec.is_a?(Hash) ? spec.dig("argument_specs", "main", "options") : nil
      declared = options.is_a?(Hash) ? options.keys.grep(/\Avault_/).sort : []
      unless declared.empty?
        problems << "#{service_name} is registered in CREDENTIAL_FREE_SERVICES but " \
                    "roles/#{role}/meta/argument_specs.yml declares #{declared.join(', ')}: " \
                    "a role that reads a vault credential is not credential-free, and the " \
                    "registration would otherwise be a one-line route past the rule"
      end
    end
    if credential_free && vault_keys.is_a?(Array) && !vault_keys.empty?
      problems << "#{relative_path} is registered credential-free in " \
                  "CREDENTIAL_FREE_SERVICES but lists #{vault_keys.length} vault key(s): " \
                  "either the service gained a credential and the registration must go, " \
                  "or the keys belong to another service"
    end
    if vault_keys.is_a?(Array) &&
       (!vault_keys.empty? || service_status == "planned" || credential_free)
      # contract_basename doubles as the vault prefix alias (paperless-ngx); the
      # two namings are independent, so a change to one must be checked against both.
      prefix = "vault_#{contract_basename(service_name)}_"
      vault_keys.each do |key|
        unless key.is_a?(String) && key.start_with?(prefix)
          problems << "#{relative_path} vault_keys entries must be prefixed for this service, got #{key.inspect}"
        end
      end
    else
      problems << "#{relative_path} vault_keys must be a nonempty list unless the service " \
                  "is planned or is named in CREDENTIAL_FREE_SERVICES"
    end
    problems
  end

  def pinned_vault_keys(documents, global_keys = GLOBAL_VAULT_KEYS)
    (global_keys + documents.values.flat_map { |expectation| expectation.fetch("vault_keys") }).sort.freeze
  end

  # A role's task list as Ansible statically assembles it: `import_tasks` of a
  # sibling spliced in place; dynamic `include_tasks` deliberately not followed.
  # Not a directory walk: the vaultwarden mutation rows replace main.yml, and a
  # walk would let tasks/verify.yml satisfy the check on the mutant's behalf.
  # +aliases+ applies to every file read; false like YAML.safe_load_file.
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

  # Every string a parsed task carries, keys included: a commented-out match or a
  # match spanning two tasks is not something the role runs.
  def task_strings(node)
    case node
    when Hash then node.flat_map { |key, value| [key.to_s] + task_strings(value) }
    when Array then node.flat_map { |value| task_strings(value) }
    when String then [node]
    else []
    end
  end

  # Every `{{ ... }}` region as Jinja's lexer finds it: the FIRST `}}` closes it,
  # so a nested Go template closes the expression early (#492). Shared (#530).
  def jinja_expression_regions(value)
    regions = []
    index = 0
    while (opened = value.index("{{", index))
      closed = value.index("}}", opened + 2)
      break if closed.nil?

      regions << value[(opened + 2)...closed]
      index = closed + 2
    end
    regions
  end

  # env.j2 as NAME=value pairs, ignoring commented-out samples.
  def environment_assignments(path)
    File.readlines(path, chomp: true).filter_map do |line|
      stripped = line.strip
      next unless stripped.match?(/\A[A-Z][A-Z0-9_]*=/)

      name, _separator, value = stripped.partition("=")
      [name, value]
    end
  end

  # The paths tasks act on, wherever the module spells them.
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
  # Structural wiring only; static policy does not interpret arbitrary Jinja.
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

  # Reads the assembled role, not the one file named: its caller ORs this with
  # contract verification, so a narrower view would fail silently.
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

  # tests/validate-policy.sh's shard heredocs as { id => [command, ...] }, or {}
  # when no boundary is found -- which every caller must refuse. Shared by three
  # readers; the declaration guard keeps its own independent awk reading.
  SHARD_OPEN = /\A  cat <<'POLICY_CHECKS_(\d+)'\z/
  def gate_shards(manifest_path)
    return {} unless File.file?(manifest_path)

    shards = {}
    current = nil
    File.readlines(manifest_path, chomp: true).each do |line|
      if current
        if line == "POLICY_CHECKS_#{current}"
          current = nil
        else
          shards[current] << line
        end
        next
      end
      match = SHARD_OPEN.match(line)
      next unless match

      current = match[1]
      shards[current] = []
    end
    # An unterminated heredoc ran off the end of the file; refuse the whole reading.
    return {} if current

    shards
  end

  # The dispatched shard ids (POLICY_SHARD_IDS), compared with the heredocs so an
  # uncatted shard is caught.
  def gate_shard_ids(manifest_path)
    return [] unless File.file?(manifest_path)

    line = File.readlines(manifest_path, chomp: true)
                .find { |candidate| candidate.start_with?("POLICY_SHARD_IDS=") }
    return [] if line.nil?

    match = /\APOLICY_SHARD_IDS='([^']*)'\z/.match(line)
    return [] if match.nil?

    match[1].split
  end
end

# Scaffolding every check script used to retype. Lives beside PolicySupport
# because the mutation sandbox already copies this file.
module TestScaffold
  # Resolved from this file, so tests/, tests/ci/ and tests/mac/ share one root.
  ROOT = File.expand_path("..", __dir__)

  module_function

  def check(failures, condition, message)
    failures << message unless condition
  end

  # A cardinality floor under a derived subject list, so a collapsed list cannot
  # pass vacuously. Size +minimum+ well under today's count and say why beside it.
  def check_floor(failures, count, minimum, subject)
    check(failures, count >= minimum,
          "#{subject}: #{count} found, expected at least #{minimum}; the subject list has " \
          "narrowed and every property asserted over it now passes vacuously")
  end

  # The tail of a subprocess's output as one grep-able line, blanks dropped.
  def failure_tail(output, lines = 10)
    output.lines.map(&:strip).reject(&:empty?).last(lines).join(" | ")
  end

  # +subject+ is what a passing run prints; +summary+ the noun a failure aborts with.
  def report(failures, subject, summary)
    if failures.empty?
      puts subject
      return
    end

    failures.each { |failure| warn "FAIL #{failure}" }
    abort "#{failures.length} #{summary}"
  end

  # Judges one contract mutation case: it must refuse, on a line carrying
  # +prefix+ and naming +expects+ (provenance, #352). stdout and stderr are split
  # before joining so an unterminated line cannot hide the prefix.
  # +expects_crash+ is for a row whose refusal is an uncaught exception.
  # Returns a fresh list rather than appending to an accumulator.
  def judge(label, expects, stdout, stderr, status, prefix:, expects_crash: nil)
    output = stdout + stderr
    failures = []
    if expects_crash
      # A successful run is the whole story; missing fragments are its consequence.
      if status.success?
        failures << "#{label}: accepted what it must refuse"
        return failures
      end

      Array(expects_crash).each do |fragment|
        failures << "#{label}: did not name #{fragment}, got #{output.strip.inspect}" unless
          output.include?(fragment)
      end
      return failures
    end
    if expects.nil?
      failures << "#{label}: expected success, got exit #{status.exitstatus}: #{output.strip}" unless
        status.success?
      return failures
    end

    if status.success?
      failures << "#{label}: accepted what it must refuse"
    elsif (stdout.lines + stderr.lines).none? { |line| line.start_with?(prefix) && line.include?(expects) }
      failures << "#{label}: refused for the wrong reason, wanted #{expects.inspect} " \
                  "under #{prefix.inspect}, got #{output.strip.inspect}"
    end
    failures
  end
end