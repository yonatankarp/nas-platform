#!/usr/bin/env ruby
# What a service must have before its deployment gate may be on (#512): an integration
# lane converging its tag, a Mac lifecycle entry, a role default of false, and the
# inventory decision in its own service_<role>.yml (#680). A gate-off service is out of
# scope, so land-dark-then-flip still works; no gate means always on. A file of its own
# so policy mutations do not drift the manifest test's declared sets.

# Explicit: on some psych versions `require "yaml"` does not define Date.
require "date"
require "yaml"

require_relative "policy_support"

include TestScaffold

ROOT = File.expand_path("..", __dir__)

# Today's counts, not a margin below: every list is also closed both ways, so the floor
# only has to report a collapse. Re-derive them (set to 9999, read the printed count)
# whenever a service is added, removed or gated. SUBJECT_FLOOR is implemented minus gate
# variables by rule, so a stack going dark never trips it; do not "correct" it.
IMPLEMENTED_FLOOR = 17       # services/manifest.yml holds 17 implemented services
GATE_VARIABLE_FLOOR = 3      # nextcloud, vaultwarden and karakeep _deployment_enabled
SUBJECT_FLOOR = 14           # 17 implemented, of which at most the 3 gated ones may be dark
MAC_ROSTER_FLOOR = 17         # 15 registered contracts plus vaultwarden and karakeep
TAGGED_LANE_FLOOR = 17        # the acquisition and service rows of tests/ci/suites.conf
LANE_TAG_FLOOR = 17           # the distinct manifest service tags those rows converge
SITE_TAG_FLOOR = 31           # the role tags site.yml declares

failures = []

# The roster, and each service's role and Ansible tag.

manifest_document = begin
  YAML.safe_load_file(File.join(ROOT, "services", "manifest.yml"))
rescue Errno::ENOENT, Psych::Exception
  nil
end
manifest_entries = manifest_document.is_a?(Hash) && manifest_document["services"].is_a?(Array) ?
                     manifest_document["services"] : []
service_roles = manifest_entries.each_with_object({}) do |entry, roles|
  next unless entry.is_a?(Hash) && entry["name"].is_a?(String) && entry["role"].is_a?(String)

  roles[entry["name"]] = entry["role"]
end
implemented = PolicySupport.implemented_services(ROOT)
check_floor(failures, implemented.length, IMPLEMENTED_FLOOR,
            "implemented services in services/manifest.yml")
role_of = implemented.to_h { |name| [name, service_roles[name]] }
missing_roles = role_of.select { |_name, role| role.nil? }.keys
check(failures, missing_roles.empty?,
      "services/manifest.yml names no role for #{missing_roles.inspect}: this check resolves a " \
      "service's deployment gate through its role, and a service with no role has no gate to read")

# Read from tests/integration.sh, which tests/policy_ci_test.rb pins against the manifest.
integration_path = File.join(ROOT, "tests", "integration.sh")
integration_body = File.file?(integration_path) ? File.read(integration_path) : ""
service_tags = integration_body[/^service_image_sources='\n(.*?)'$/m].to_s
                                .scan(/^([a-z0-9_-]+) ([a-z0-9-]+)$/)
                                .to_h { |tag, directory| [directory, tag] }
check(failures, !service_tags.empty?,
      "tests/integration.sh: service_image_sources could not be read, so no service's Ansible " \
      "tag is known and every lane requirement below would pass vacuously")

# The gates: role default overridden by inventory. A gate set in two inventory files
# with different values is reported, not resolved.
GATE_SUFFIX = "_deployment_enabled"
GATE_KEY = /\A([a-z][a-z0-9_]*)#{GATE_SUFFIX}\z/

# Any depth: inventory/*.yml nest variables under a group's `vars`.
def gate_keys(node, found = {})
  case node
  when Hash
    node.each do |key, value|
      found[key] = value if key.is_a?(String) && key.match?(GATE_KEY)
      gate_keys(value, found)
    end
  when Array
    node.each { |element| gate_keys(element, found) }
  end
  found
end

# An unparseable file is not an empty one (#593): +unparsed+ records it and the run is
# refused. Rescues all Psych::Exception, hence the permitted classes (an unquoted date is
# valid YAML). Unopenable files are not rescued.
def load_plain_yaml(path, unparsed)
  source = File.read(path)
  return nil if source.start_with?("$ANSIBLE_VAULT")

  YAML.safe_load(source, aliases: true, permitted_classes: [Date, Time])
rescue Errno::ENOENT, Psych::Exception
  unparsed << path.delete_prefix("#{ROOT}/")
  nil
end

unparsed_yaml = []

role_gates = {}
Dir[File.join(ROOT, "roles", "*", "defaults", "main.yml")].sort.each do |path|
  role = File.basename(File.dirname(File.dirname(path)))
  gate_keys(load_plain_yaml(path, unparsed_yaml)).each do |key, value|
    role_gates[key] = { "role" => role, "value" => value, "path" => path }
  end
end

inventory_gates = Hash.new { |hash, key| hash[key] = [] }
Dir[File.join(ROOT, "inventory", "**", "*.yml")].sort.each do |path|
  gate_keys(load_plain_yaml(path, unparsed_yaml)).each do |key, value|
    inventory_gates[key] << { "value" => value, "path" => path.delete_prefix("#{ROOT}/") }
  end
end
# Either refusal below invalidates the rest of this report: later checks resolve against
# role-default `false` and some invert to a pass. When one fires, it is THE finding.
check(failures, unparsed_yaml.empty?,
      "#{unparsed_yaml.uniq.inspect} could not be parsed, so no gate can be resolved from the " \
      "file that sets it and every requirement below would pass vacuously. A gate that is dark " \
      "because inventory says so and a gate that is dark because its file could not be parsed " \
      "are different states, and only the first is a reason to assert nothing. Fix the file and " \
      "re-run: nothing else this run reports about a gate can be trusted")

# The decision files must exist and be non-empty (a missing or 0-byte file once passed).
# Derived from the manifest, not a literal (#635). Proves only that each survived, not
# that it declares a gate. main.yml stays in the set.
DECISION_FILES = ["main.yml"]
                 .concat(role_of.values.compact.uniq.sort.map { |role| "service_#{role}.yml" })
                 .map { |name| File.join("inventory", "group_vars", "all", name) }
# No floor of its own: derived from role_of, which IMPLEMENTED_FLOOR guards.
DECISION_FILES.each do |relative|
  # Accumulator discarded: the inventory scan already recorded a parse failure.
  decision_document = load_plain_yaml(File.join(ROOT, relative), [])
  check(failures, decision_document.is_a?(Hash) && !decision_document.empty?,
        "#{relative} is one of the files a deployment decision on this platform is made and " \
        "won in, and it parsed to an empty #{decision_document.class} -- missing, empty or " \
        "holding nothing. Any gate it declared then resolves from its role default, which this " \
        "check requires to ship OFF, so that stack reads as dark and every requirement below " \
        "holds for it vacuously. Fix the file and re-run: nothing else this run reports about " \
        "a gate can be trusted")
end

gate_names = (role_gates.keys + inventory_gates.keys).uniq.sort
check_floor(failures, gate_names.length, GATE_VARIABLE_FLOOR,
            "#{GATE_SUFFIX} variables found under roles/ and inventory/")

# Both directions: a gate whose prefix is not a manifest role is read by nothing; one
# with no role default has no declared off position.
roles_by_name = role_of.values.compact.to_h { |role| [role, true] }
gated_off = []
gate_states = {}
gate_names.each do |name|
  prefix = name[GATE_KEY, 1]
  check(failures, roles_by_name.key?(prefix),
        "#{name} names no implemented role in services/manifest.yml: a deployment gate whose " \
        "prefix is not a role is a switch nothing reads")
  declaration = role_gates[name]
  check(failures, !declaration.nil? && declaration["role"] == prefix,
        "#{name} must be declared in roles/#{prefix}/defaults/main.yml: a gate that only " \
        "inventory sets has no declared off position")

  # The role default must be false: it is the floor under the inventory decision, so
  # turning the gate off in inventory really stops the stack. Repo-wide, so every gate is
  # reached; argue a true default here rather than routing around it.
  check(failures, declaration.nil? || declaration["value"] == false,
        "roles/#{prefix}/defaults/main.yml ships #{name}: #{declaration&.fetch('value').inspect}, " \
        "and a role default must ship the gate OFF. It is the floor under the deployment " \
        "decision, not a copy of it: inventory/group_vars/all/service_#{prefix}.yml is where " \
        "the decision " \
        "is made and won, and a true default means a caller with no inventory -- or an " \
        "inventory that turned the stack back off -- converges the stack anyway. Set it false " \
        "here and leave inventory to say what this platform runs")

  overrides = inventory_gates[name]

  # Inventory must decide in the service's own file (#680), built from the prefix like
  # DECISION_FILES, or gutting another file reproduces #635 silently. Silent for a gate
  # inventory does not set: that is dark-by-deletion, which is legitimate.
  decision_file = File.join("inventory", "group_vars", "all", "service_#{prefix}.yml")
  stray_declarations = overrides.map { |entry| entry["path"] }.reject { |path| path == decision_file }
  check(failures, stray_declarations.empty?,
        "#{name} is declared by #{stray_declarations.inspect}, and the deployment decision for a " \
        "service is made in #{decision_file}. A gate resolves from wherever inventory sets it, so " \
        "the stack converges either way and nothing else here objects -- but every check that " \
        "reads the decision looks at the service's own file, so emptying the file it was moved to " \
        "would leave the gate on its role default with this run reporting the stack as " \
        "deliberately dark. Move the declaration back")

  values = overrides.empty? ? [declaration&.fetch("value")] : overrides.map { |entry| entry["value"] }
  check(failures, values.uniq.length == 1,
        "#{name} is set to conflicting values by #{overrides.map { |entry| entry['path'] }.inspect}: " \
        "which stack converges must not depend on reproducing Ansible's precedence ladder here")
  value = values.first
  # Non-boolean values stop the run by name rather than reading as "off".
  check(failures, value == true || value == false,
        "#{name} resolves to #{value.inspect}, which is not a YAML boolean; this check cannot " \
        "say whether the stack converges and will not guess")
  gate_states[prefix] = value
  gated_off << prefix if value == false
end

subjects = implemented.reject { |name| gate_states[role_of[name]] == false }
check_floor(failures, subjects.length, SUBJECT_FLOOR,
            "implemented services whose deployment gate is on")
check(failures, subjects.length >= implemented.length - gate_names.length,
      "#{implemented.length - subjects.length} of #{implemented.length} implemented services " \
      "read as gated off, but only #{gate_names.length} gate variable(s) exist: the resolution " \
      "above has broken rather than that many stacks having been turned dark")

# Requirement 1: an integration lane converges the service's tag.

suite_table_path = File.join(ROOT, "tests", "ci", "suites.conf")
suite_rows = []
if File.file?(suite_table_path)
  File.readlines(suite_table_path, chomp: true).each do |line|
    fields = line.sub(/#.*/, "").split
    next unless fields.length == 3

    suite, kind, tags = fields
    suite_rows << [suite, kind, tags == "-" ? [] : tags.split(",")]
  end
end
tagged_rows = suite_rows.select { |_suite, kind, _tags| %w[acquisition service].include?(kind) }
check_floor(failures, tagged_rows.length, TAGGED_LANE_FLOOR,
            "acquisition and service rows of tests/ci/suites.conf")
lane_tags = tagged_rows.flat_map(&:last).uniq
manifest_tags = manifest_entries.filter_map { |entry| entry["name"] }
                                .filter_map { |name| service_tags[name] }
check_floor(failures, (lane_tags & manifest_tags).length, LANE_TAG_FLOOR,
            "distinct service tags converged by the lanes of tests/ci/suites.conf")

subjects.each do |name|
  tag = service_tags[name]
  # Reported rather than skipped, so a subject with no tag cannot drop out silently.
  check(failures, !tag.nil?,
        "#{name} has no tests/integration.sh service_image_sources entry, so this check " \
        "cannot say which lane would converge it and would otherwise pass it over in silence")
  next if tag.nil?

  check(failures, lane_tags.include?(tag),
        "#{name} deploys -- its gate is on -- and no integration lane in tests/ci/suites.conf " \
        "converges its `#{tag}` tag, so nothing has ever proved the stack comes up. Give it a " \
        "lane before turning it on, or turn the gate back off")
end

# The other direction: a lane tag no site.yml role carries runs a shorter play and still
# passes. Checked for every manifest service, since a lane may land before the flip.
site_play = begin
  Array(YAML.safe_load_file(File.join(ROOT, "site.yml"))).first
rescue Errno::ENOENT, Psych::Exception
  nil
end
site_tags = Array(site_play.is_a?(Hash) ? site_play["roles"] : nil)
            .select { |role| role.is_a?(Hash) }
            .flat_map { |role| Array(role["tags"]) }.uniq
check_floor(failures, site_tags.length, SITE_TAG_FLOOR, "role tags declared by site.yml")
tagged_rows.each do |suite, _kind, tags|
  stray = tags - site_tags
  check(failures, stray.empty?,
        "the #{suite} lane converges #{stray.inspect}, which site.yml applies to no role: the " \
        "lane runs a shorter play than its row claims and reports success anyway")
end

# Requirement 2: the Mac lifecycle accounts for the service.

registry_document = begin
  YAML.safe_load_file(File.join(ROOT, "tests", "contracts", "registry.yml"))
rescue Errno::ENOENT, Psych::Exception
  nil
end
registry_entries = registry_document.is_a?(Hash) && registry_document["contracts"].is_a?(Array) ?
                     registry_document["contracts"] : []
registry_services = registry_entries.filter_map do |entry|
  entry["service"] if entry.is_a?(Hash) && entry["service"].is_a?(String)
end
mac_lib_path = File.join(ROOT, "tests", "mac", "lib.sh")
mac_lib = File.file?(mac_lib_path) ? File.read(mac_lib_path) : ""
unregistered = mac_lib[/^MAC_UNREGISTERED_SERVICES='([^']*)'/m, 1].to_s.split
mac_roster = (registry_services.map { |name| PolicySupport.contract_basename(name) } +
              unregistered).uniq
check_floor(failures, mac_roster.length, MAC_ROSTER_FLOOR,
            "the Mac coverage roster (tests/contracts/registry.yml plus MAC_UNREGISTERED_SERVICES)")

subjects.each do |name|
  alias_name = PolicySupport.contract_basename(name)
  check(failures, mac_roster.include?(alias_name),
        "#{name} deploys -- its gate is on -- and the Mac lifecycle accounts for it nowhere: " \
        "`#{alias_name}` is in neither tests/contracts/registry.yml nor MAC_UNREGISTERED_SERVICES " \
        "in tests/mac/lib.sh, so every Mac coverage roster is built without it and a full pass " \
        "reports clean having skipped the service entirely")
end

# Requirement 3: CI converges the DISABLED path too, via a lane step
# `run_play --tags <tag> -e <gate>=false`; otherwise turning a gate on leaves the way back
# untested (#569). A controller-wide narrowing no longer counts (#564). Both controller
# files are read, since run_play lives in integration_controller_lib.sh.
INTEGRATION_CONTROLLER = [File.join(ROOT, "tests", "integration_controller.sh"),
                          File.join(ROOT, "tests", "integration_controller_lib.sh")].freeze
controller_source = INTEGRATION_CONTROLLER
                    .map { |path| File.file?(path) ? File.read(path) : "" }.join("\n")
unreadable_controller = INTEGRATION_CONTROLLER.reject { |path| File.file?(path) }
                                              .map { |path| path.delete_prefix("#{ROOT}/") }
check(failures, unreadable_controller.empty?,
      "#{unreadable_controller.inspect} could not be read, so no service's disabled path can be " \
      "shown to run and every requirement below would pass vacuously")

subjects.each do |name|
  role = role_of[name]
  tag = service_tags[name]
  next if role.nil? || tag.nil?

  gate = "#{role}#{GATE_SUFFIX}"
  next unless gate_names.include?(gate)

  check(failures, controller_source.include?("run_play --tags #{tag} -e #{gate}=false"),
        "#{name} deploys and nothing in the integration controller ever converges it with " \
        "#{gate} false, so the way back is claimed and never run. While the stack was dark every " \
        "lane converged that branch for free; turning the gate on took the proof with it. Add " \
        "`run_play --tags #{tag} -e #{gate}=false` to its lane, with the container asserted " \
        "present before and absent after, and converge it back on afterwards")
end

# Narrowing is forbidden to any gate (#564). Looped over gate_names, not over narrowings
# found, so a clean tree is a non-empty pass. Any assignment `integration_<gate>=` counts,
# since -e outranks group_vars whichever value it sets.
gate_names.each do |name|
  assignment = "integration_#{name}="
  next unless controller_source.include?(assignment)

  check(failures, gate_states[name[GATE_KEY, 1]] == false,
        "inventory turns #{name} ON and the integration controller still assigns " \
        "`#{assignment}...`, which reaches ansible-playbook as `-e` and outranks it. Whichever " \
        "value it holds, CI then converges something other than what the NAS runs: `false` " \
        "keeps the stack out of every lane but the service's own -- idempotence-check " \
        "included, the only lane that converges the whole site -- and `true` " \
        "keeps converging it the day the switch is turned back off. Delete the assignment and " \
        "give the service `run_play --tags <tag> -e #{name}=false` in its own lane instead: " \
        "that converges the disabled path without taking the enabled path away from every " \
        "other lane, and leaves inventory the single source of which stacks exist")
end

# The other direction: a narrowing of an undeclared variable. Scanned, so it can go
# quiet if the regex rots; the loop above cannot.
narrowed_gates = controller_source
                 .scan(/\bintegration_([a-z][a-z0-9_]*#{GATE_SUFFIX})\s*=/)
                 .flatten.uniq
stray_narrowings = narrowed_gates - gate_names
check(failures, stray_narrowings.empty?,
      "the integration controller narrows #{stray_narrowings.inspect}, which no role " \
      "default and no inventory file declares as a #{GATE_SUFFIX} variable. The controller is " \
      "setting a switch nothing reads, so the lane converges whatever inventory says and the " \
      "narrowing reports nothing")

implemented_aliases = implemented.map { |name| PolicySupport.contract_basename(name) }
stray_roster = mac_roster - implemented_aliases
check(failures, stray_roster.empty?,
      "the Mac coverage roster names #{stray_roster.inspect}, which no implemented service in " \
      "services/manifest.yml accounts for. MAC_UNREGISTERED_SERVICES is a literal list and this " \
      "is the only thing holding it to the roster in that direction")

report(failures,
       "deployment gates: #{subjects.length} of #{implemented.length} implemented services " \
       "converge (#{gate_names.length} gate variable(s), #{gated_off.length} dark), and every " \
       "one of them has an integration lane and Mac coverage",
       "deployment gate coverage violation(s)")
