#!/usr/bin/env ruby
# What a service must already have before its deployment gate is allowed to be on.
#
# THE HOLE THIS CLOSES (#512). Flipping `<role>_deployment_enabled` to true in
# inventory is what converges a stack on the NAS, and until this file no check
# read that value at all. The registrations that make a service *provable* --
# an integration lane that converges it, a Mac lifecycle that recreates and
# verifies it -- were held only by pairwise agreement between hand-maintained
# literals: tests/ci/suites.conf against SERVICE_NAMES in
# tests/ci/classify_changes.rb, against the LANES/NTFY_LANES/expected-output
# blocks in tests/ci/classify_changes_test.rb, against INTEGRATION_SUITES in
# tests/ci/workflow_test.rb. Every one of those agrees with its neighbour and
# none of them is anchored to services/manifest.yml, so a service that was never
# written into any of them is invisible to all of them rather than failing any.
#
# That was demonstrated rather than argued, on this tree: removing Nextcloud
# consistently from all four literals -- leaving `status: implemented` and
# `nextcloud_deployment_enabled: true` exactly as they are -- left
# tests/policy_test.rb, tests/policy_ci_test.rb, tests/policy_mac_test.rb,
# tests/policy_platform_test.rb, tests/ci/workflow_test.rb and
# tests/gate_manifest_coverage_test.rb all green. The one objection came from
# tests/ci/classify_changes_test.rb's harness-closure check, and it was
# incidental: it fires because tests/expected/nextcloud.yml is reached from a
# contract, so a service with no contract escapes it. ntfy is the control that
# proves so -- it is implemented, deployed on every lane, and
# `ClassifyChanges.suites(classify(["tests/expected/ntfy.yml"]))` is `[]` today
# with every check green.
#
# THE SUBJECT IS THE GATE, NOT THE MANIFEST, and that distinction is the whole
# design. Requiring a lane of every implemented service would forbid the
# land-dark-then-flip idiom that .claude/skills/implement-issue/SKILL.md
# prefers and that both Seafile and Nextcloud were promoted through: step 1
# lands the entire stack with the gate false and no registrations anywhere,
# step 2 adds the lane and the contract, step 3 flips the gate. What was missing
# was any reason step 2 had to happen before step 3. So a service whose gate is
# off is deliberately out of scope here, and a service with no gate variable at
# all is in scope: no gate means it converges unconditionally, which is the same
# position as a gate that is on.
#
# WHAT IS REQUIRED, AND WHY EACH ONE AND NOT THE OTHERS.
#
#   1. An integration lane converges its Ansible tag. This is the property that
#      means "CI has deployed this and watched it come up": tests/integration.sh
#      asserts of every lane that the run converges, that a second run changes
#      nothing, and that --check --diff works. Membership is by *tag* rather than
#      by a lane of its own, because ntfy has no lane and needs none -- every
#      service lane converges it, since each service role reports its deployment
#      there. Deriving the requirement from the tags rather than from lane names
#      is what lets ntfy pass without an exemption list, and an exemption list is
#      the defect this file exists to remove.
#
#   2. The Mac lifecycle accounts for it. tests/mac/lib.sh builds every coverage
#      roster as `mac_registry_services + MAC_UNREGISTERED_SERVICES`, and
#      MAC_UNREGISTERED_SERVICES is the literal string 'ntfy' with nothing tying
#      either half to the manifest. Asserting that roster against the gate-on
#      services closes it in both directions: a gate-on service missing from both
#      halves fails, and a name in either half that is not an implemented service
#      fails too.
#
#   3. Its role default declares the gate OFF. Not a coverage requirement like
#      the two above -- it holds of every gate, lit or dark -- but the same
#      subject read from the same scan, so it lives here rather than in a
#      per-service contract that two of the three gates do not have. The reason
#      is at the check itself.
#
# NOT REQUIRED HERE, deliberately, because each is already closed elsewhere and a
# second copy of an assertion is a second thing to keep true:
#
#   - tests/expected/<service>.yml. tests/policy_support.rb pins those against
#     the service roster in both directions already.
#   - A contract of its own. tests/policy_test.rb requires every implemented
#     service to carry `role_verification || contract_verification`, and
#     demanding a registry row specifically would fail ntfy, which has neither a
#     contract nor any need of one -- and would therefore need the exemption list
#     this file is here to delete. Requirement 2 above reaches the registry
#     anyway: a gate-on service absent from MAC_UNREGISTERED_SERVICES has to be
#     registered to satisfy it.
#
# WHY A FILE OF ITS OWN rather than a section of one of the eight scripts in
# POLICY_SCRIPTS. The same reason tests/gate_manifest_coverage_test.rb states for
# itself, and it is measured rather than aesthetic: this check reads
# services/manifest.yml, tests/contracts/registry.yml, tests/ci/suites.conf,
# tests/integration.sh and tests/mac/lib.sh, and tests/policy_mutation_support.rb
# plants defects in several of those. Inside one of the eight, every such
# mutation would newly be detected by that script, the per-site declared sets in
# tests/policy_manifest_test.rb would drift, and `--audit` would fail. Outside
# them, it cannot happen. The cost is one line in tests/validate-policy.sh and
# the matching entry in tests/gate_manifest_coverage_test.rb's shard list.

require "yaml"

require_relative "policy_support"

include TestScaffold

ROOT = File.expand_path("..", __dir__)

# The floors. Every list below is derived from the tree, so each one can go quiet
# and take its assertions with it: a renamed variable empties the gate scan, a
# regex that stops matching empties the roster, and the run reports success.
#
# They are today's counts rather than something comfortably below them, which is
# the opposite of what TestScaffold.check_floor's own comment advises, and the
# reason is that these lists have a second guard and mac_port_roster did not.
# #512 objected to `mac_port_roster.length >= 15` over nineteen entries precisely
# because the floor was the only thing holding that list, so four names could go
# and nothing would say. Every list here is also closed in both directions
# below, so a single deletion fails by name whatever the floor is; the floor's
# job is only the collapse a set comparison cannot report usefully. Holding it at
# the real count costs one visible edit when a service is genuinely removed --
# #501 removed Seafile and rewrote some forty files to do it -- and buys a
# failure that names the number rather than one that lists fifteen missing
# services.
#
# SUBJECT_FLOOR is the one exception, and it is deliberate: it sits at the
# implemented count minus the gated services, because turning a stack dark is an
# operation this repository performs -- #528 switched Seafile's gate off four
# days before this was written -- and a guard that refused it would be fighting
# the very idiom the rest of this file exists to protect. It therefore does not
# move when a service lands dark, and it does not move when one is turned on
# either: #547 landed Vaultwarden dark and #548 flipped AdGuard on, which took
# the implemented count to 18 and the gate count to 3, and 18 - 3 is the 15 that
# was already there. #577 removed AdGuard again, taking those to 17 and 2, and
# 17 - 2 is the same 15 -- so the rule has now survived a service arriving, a
# gate flipping both ways and a service leaving without the number moving once.
# It is 15 by that rule and not by coincidence -- it is the same arithmetic the
# `subjects.length >= implemented.length - gate_names.length` check two hundred
# lines below applies -- so do not "correct" it to today's subject count: that
# would be a guard against turning a stack off, which is a thing this repository
# does on purpose.
#
# THE FLOORS ARE `>=`, WHICH IS WHY THEY GO STALE QUIETLY, and it has now
# happened twice, the second time in a merge. #548 landed AdGuard with the first
# three left at their pre-AdGuard values and this file stayed green -- exactly
# the collapse the paragraph above says the floor exists to report, since today's
# counts are the point and a floor comfortably below them buys nothing. Fixing
# those three left the other four: the registry had gained a sixteenth contract,
# suites.conf a sixteenth tagged row and its seventeenth service tag, site.yml
# more role tags, and every one of those floors went on passing over a larger
# tree. Then #547 and #548 met in a merge and NEITHER SIDE'S NUMBERS WERE RIGHT
# FOR THE MERGED TREE -- three each. #548 had the Mac roster, the tagged lanes
# and the lane tags right at 17/16/17 and counted 17 implemented services behind
# 2 gates; #547 had the implemented count, the gate count and the site tags right
# at 18/3/33 and counted a 16-name Mac roster over 15 tagged lanes. Resolving
# that conflict by picking a side would have shipped four stale floors whichever
# side was picked. Every number below is therefore read off the merged tree
# rather than carried over from either. Re-read this whole block when a service
# is added, removed, gated or ungated, and re-derive rather than reason: the
# summary line at the foot of this file prints four of the seven live counts, and
# the other three are one instrumented run away.
#
# THE THIRD TIME, AND IT WAS THE SAME MERGE AGAIN. #547's second chunk rebased
# onto the AdGuard flip above, and neither side's numbers were right for the
# tree that came out: this file's own Mac roster, tagged lanes and lane tags
# were AdGuard's counts, one short each, because Vaultwarden brings a lane, a
# tag and a roster entry of its own. They were re-derived the way the paragraph
# above prescribes rather than incremented -- each floor set to an impossible
# value and the check run, which prints the count it found: 18 implemented, 3
# gate variables, 18 subjects, an 18-name Mac roster, 17 tagged rows, 18 lane
# tags, 33 site tags. SUBJECT_FLOOR is the one that did not move and the one
# that must not: its rule is implemented minus gated, 18 - 3 is 15, and the
# count being 18 today only means no stack is dark at the moment.
#
# THE FOURTH TIME WAS A REMOVAL, and it moved six of the seven. #577 deleted
# AdGuard: the six below were each set to an impossible value and the check run,
# which prints the count it found -- 17 implemented, 2 gate variables, a 17-name
# Mac roster, 16 tagged rows, 17 lane tags, 31 site tags. Two of those are not
# the decrement a reader would guess: the site tags fell by TWO, because
# `network` was AdGuard's tag alone and went with it, and the Mac roster fell by
# one rather than two because AdGuard held one registry entry and no
# MAC_UNREGISTERED_SERVICES name. SUBJECT_FLOOR is again the one that did not
# move, by the rule above.
IMPLEMENTED_FLOOR = 17       # services/manifest.yml holds 17 implemented services
GATE_VARIABLE_FLOOR = 2      # nextcloud and vaultwarden _deployment_enabled
SUBJECT_FLOOR = 15           # 17 implemented, of which at most the 2 gated ones may be dark
MAC_ROSTER_FLOOR = 17        # 15 registered contracts plus ntfy and vaultwarden
TAGGED_LANE_FLOOR = 16       # the acquisition and service rows of tests/ci/suites.conf
LANE_TAG_FLOOR = 17          # the distinct manifest service tags those rows converge
SITE_TAG_FLOOR = 31          # the role tags site.yml declares

failures = []

# ---------------------------------------------------------------------------
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

# The tag each service converges under. Read out of tests/integration.sh rather
# than restated, because tests/policy_ci_test.rb already pins that table against
# the manifest in both directions -- so it is the one tag/service mapping in the
# repository that cannot drift from the roster, and a copy here would be a second
# one that can.
integration_path = File.join(ROOT, "tests", "integration.sh")
integration_body = File.file?(integration_path) ? File.read(integration_path) : ""
service_tags = integration_body[/^service_image_sources='\n(.*?)'$/m].to_s
                                .scan(/^([a-z0-9_-]+) ([a-z0-9-]+)$/)
                                .to_h { |tag, directory| [directory, tag] }
check(failures, !service_tags.empty?,
      "tests/integration.sh: service_image_sources could not be read, so no service's Ansible " \
      "tag is known and every lane requirement below would pass vacuously")

# ---------------------------------------------------------------------------
# The gates themselves, and how each one resolves.
#
# A gate is a role default that inventory may override, so both homes are read
# and inventory wins. Nothing here reproduces Ansible's full precedence ladder:
# what it needs to know is whether a stack converges, and a variable set in two
# inventory files with different values is reported rather than resolved, because
# guessing which one Ansible would pick is exactly the kind of quiet answer this
# file exists to stop giving.
GATE_SUFFIX = "_deployment_enabled"
GATE_KEY = /\A([a-z][a-z0-9_]*)#{GATE_SUFFIX}\z/

# Walks a loaded document for gate keys at any depth. Depth matters because
# inventory/*.yml are inventory files whose variables sit under a group's `vars`
# mapping, while group_vars and role defaults are flat: a scan that only read top
# level keys would miss the first home entirely and report "no gates found",
# which the floor below would catch but only after the reason had been lost.
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

def load_plain_yaml(path)
  source = File.read(path)
  # An encrypted vault is not YAML and is not where a nonsecret policy switch
  # belongs; tests/policy_vault_test.rb is what says it stays encrypted.
  return nil if source.start_with?("$ANSIBLE_VAULT")

  YAML.safe_load(source, aliases: true)
rescue Errno::ENOENT, Psych::Exception
  nil
end

role_gates = {}
Dir[File.join(ROOT, "roles", "*", "defaults", "main.yml")].sort.each do |path|
  role = File.basename(File.dirname(File.dirname(path)))
  gate_keys(load_plain_yaml(path)).each do |key, value|
    role_gates[key] = { "role" => role, "value" => value, "path" => path }
  end
end

inventory_gates = Hash.new { |hash, key| hash[key] = [] }
Dir[File.join(ROOT, "inventory", "**", "*.yml")].sort.each do |path|
  gate_keys(load_plain_yaml(path)).each do |key, value|
    inventory_gates[key] << { "value" => value, "path" => path.delete_prefix("#{ROOT}/") }
  end
end

gate_names = (role_gates.keys + inventory_gates.keys).uniq.sort
check_floor(failures, gate_names.length, GATE_VARIABLE_FLOOR,
            "#{GATE_SUFFIX} variables found under roles/ and inventory/")

# Both directions on the gate scan itself. A gate whose prefix is not a manifest
# role is either a typo -- in which case the switch the operator edits is read by
# nothing -- or a gate on something this file cannot reason about; and a gate
# that inventory sets with no role default behind it is a switch with no declared
# off position, which is how a role ends up depending on a variable that is
# simply undefined on some other host.
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

  # AND IT MUST BE DECLARED OFF. A role default is what a caller gets with no
  # inventory at all, so this line is the FLOOR under the deployment decision
  # rather than a mirror of it: the decision lives in
  # inventory/group_vars/all/main.yml, which wins on every run any playbook here
  # makes, and turning it back off there must not leave the stack converging on
  # the strength of a role default nobody edited.
  #
  # Stated repo-wide rather than per-service because the tree already satisfies
  # it in full -- nextcloud and vaultwarden are the two gates that exist, and
  # both ship false -- and because the harm is worst exactly where a per-service
  # check is most likely to be missing. AdGuard used to be the only one carrying
  # its own assertion, in tests/contracts/adguard-static.rb, and #577 removed
  # that contract with the service; neither survivor has a static contract to
  # carry one, and Vaultwarden is the starker case, since a caller with no
  # inventory would stand up a password manager whose registration door is open.
  # A rule that reaches every gate reaches the ones nobody thought to guard, and
  # after #577 it is the only thing reaching any of them.
  #
  # If a service ever needs a true role default, this is the check to argue with
  # rather than to route around: the argument belongs here, beside the other two
  # things a gate must be.
  check(failures, declaration.nil? || declaration["value"] == false,
        "roles/#{prefix}/defaults/main.yml ships #{name}: #{declaration&.fetch('value').inspect}, " \
        "and a role default must ship the gate OFF. It is the floor under the deployment " \
        "decision, not a copy of it: inventory/group_vars/all/main.yml is where the decision " \
        "is made and won, and a true default means a caller with no inventory -- or an " \
        "inventory that turned the stack back off -- converges the stack anyway. Set it false " \
        "here and leave inventory to say what this platform runs")

  overrides = inventory_gates[name]
  values = overrides.empty? ? [declaration&.fetch("value")] : overrides.map { |entry| entry["value"] }
  check(failures, values.uniq.length == 1,
        "#{name} is set to conflicting values by #{overrides.map { |entry| entry['path'] }.inspect}: " \
        "which stack converges must not depend on reproducing Ansible's precedence ladder here")
  value = values.first
  # Anything that is not a YAML boolean stops the run by name. Reading an
  # unrecognised value as "off" would drop the service out of the subject list,
  # and every requirement below would then hold for it vacuously -- the exact
  # failure the floors are here to make impossible.
  check(failures, value == true || value == false,
        "#{name} resolves to #{value.inspect}, which is not a YAML boolean; this check cannot " \
        "say whether the stack converges and will not guess")
  gate_states[prefix] = value
  gated_off << prefix if value == false
end

# A service with no gate variable converges unconditionally, so it is a subject.
subjects = implemented.reject { |name| gate_states[role_of[name]] == false }
check_floor(failures, subjects.length, SUBJECT_FLOOR,
            "implemented services whose deployment gate is on")
check(failures, subjects.length >= implemented.length - gate_names.length,
      "#{implemented.length - subjects.length} of #{implemented.length} implemented services " \
      "read as gated off, but only #{gate_names.length} gate variable(s) exist: the resolution " \
      "above has broken rather than that many stacks having been turned dark")

# ---------------------------------------------------------------------------
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
  # Reported rather than skipped. A subject with no tag would otherwise drop out
  # of the requirement below and take its assertion with it -- the exact shape
  # this file exists to remove -- and the emptiness check above says nothing
  # about one missing row. tests/policy_ci_test.rb does hold that table against
  # the manifest, but a check that relies on another check to notice its own
  # subject going quiet is relying on a coupling nothing states.
  check(failures, !tag.nil?,
        "#{name} has no tests/integration.sh service_image_sources entry, so this check " \
        "cannot say which lane would converge it and would otherwise pass it over in silence")
  next if tag.nil?

  check(failures, lane_tags.include?(tag),
        "#{name} deploys -- its gate is on -- and no integration lane in tests/ci/suites.conf " \
        "converges its `#{tag}` tag, so nothing has ever proved the stack comes up. Give it a " \
        "lane before turning it on, or turn the gate back off")
end

# The other direction: a lane that converges a tag nothing answers to. A tag no
# role carries selects no role, so the lane runs a shorter play than its row
# claims and still reports success -- which is the same defect as a missing lane,
# arrived at from the other side. The comparison is against site.yml's own role
# tags rather than a list of foundation tags written here, so `host_prep`,
# `deployment_bundle` and the `media_acquisition_foundation` a planned
# acquisition lane converges are admitted by being real rather than by being
# named. Held against every manifest service and not only the gate-on ones,
# because a lane landed ahead of the flip -- the sequence this file exists to
# require -- is correct and must not fail here.
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

# ---------------------------------------------------------------------------
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
# The Mac lane's own spelling of a service, which tests/mac/lib.sh derives from
# the registry with exactly the paperless-ngx exception PolicySupport applies to
# a contract basename.
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

# ---------------------------------------------------------------------------
# Requirement 3: CI converges the service's DISABLED path too.
#
# A gate is a deployment decision in both directions -- every inventory comment
# beside one says so -- and while a stack is dark the `state: absent` branch is
# converged by every lane on every run without anybody asking for it. Turning the
# switch on takes that proof away, because CI then requests what production runs
# and nothing requests the other state. AdGuard hit it first and #569 closed it
# with a lane step; #547 rebased onto that and reintroduced it for Vaultwarden,
# which is what makes this a rule rather than a second copy of one service's fix.
#
# The cost of an unexercised way back is not hypothetical for this pair. The
# switch is the documented emergency exit -- for a resolver answering a whole
# household, and for a password manager whose door is open -- and
# roles/vaultwarden/tasks/deploy.yml shipped with its config.json refusal ahead
# of the tear-down, so the exit was blocked in precisely the state that motivates
# using it. Nothing noticed, because nothing ran it.
#
# TWO FORMS COUNT, and both are read out of the harness rather than listed here:
#
#   the step   `run_play --tags <tag> -e <gate>=false` inside the lane, which
#              converges the disabled path against a stack that exists. This is
#              the form to write today.
#   the narrow `integration_<role>_deployment_enabled=false` at the top of the
#              controller, which withholds the gate from every lane but the
#              service's own, so smoke and idempotence-check converge the
#              disabled branch on every run. It is the older form and the
#              controller's own comments say it has to be flipped or deleted the
#              day the platform switch turns on -- nextcloud is its last user.
#              It is admitted because it really does converge that branch, not
#              because it is tidy; when it goes, that service needs the step.
INTEGRATION_CONTROLLER = File.join(ROOT, "tests", "integration_controller.sh")
controller_source = File.file?(INTEGRATION_CONTROLLER) ? File.read(INTEGRATION_CONTROLLER) : ""
check(failures, !controller_source.empty?,
      "tests/integration_controller.sh could not be read, so no service's disabled path can be " \
      "shown to run and every requirement below would pass vacuously")

subjects.each do |name|
  role = role_of[name]
  tag = service_tags[name]
  next if role.nil? || tag.nil?

  gate = "#{role}#{GATE_SUFFIX}"
  next unless gate_names.include?(gate)

  step = controller_source.include?("run_play --tags #{tag} -e #{gate}=false")
  narrowed = controller_source.include?("integration_#{gate}=false")
  check(failures, step || narrowed,
        "#{name} deploys and nothing in tests/integration_controller.sh ever converges it with " \
        "#{gate} false, so the way back is claimed and never run. While the stack was dark every " \
        "lane converged that branch for free; turning the gate on took the proof with it. Add " \
        "`run_play --tags #{tag} -e #{gate}=false` to its lane, with the container asserted " \
        "present before and absent after, and converge it back on afterwards")
end

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
