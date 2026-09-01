#!/usr/bin/env ruby
# The static half of the Immich service contract: every property it can decide
# from the repository alone, with nothing deployed.
#
# usage: ruby -ryaml immich-static.rb REPOSITORY PLATFORM
#
# PLATFORM is mac, nas or integration, and selects which capability contract
# applies. Silent apart from one success line and exit 0 when the repository
# holds; one `Immich contract failed: ...` line on stderr and exit 1 when it does
# not. Callers grep those lines, so they are the interface --
# tests/immich_contract_test.rb asserts them by their exact text.
#
# The `-ryaml` preload is not decoration. Until #147 this was a `<<'RUBY'`
# heredoc inside tests/contracts/immich.sh invoked as `ruby -ryaml - "$repo_dir"
# "$platform"`, and the body below never requires yaml itself. #250 blessed
# carrying the preload verbatim into the sibling form rather than rewriting the
# body, so the invocation keeps it and the body stays as it was. Run bare, this
# program raises NameError on YAML.
#
# Two roots, deliberately separate. The tree this program inspects arrives as
# ARGV[0]; the checkout it was loaded from is wherever its caller found it. They
# are usually the same and must not be assumed to be: a caller may point
# PLATFORM_CONTRACT_REPO_DIR at a fixture repository, and every path read below
# is resolved from ARGV[0] so that it inspects that fixture rather than itself.
#
# `sh -n` reads a quoted heredoc as opaque text, so before #147 nothing but an
# integration run with a converged Immich ever looked at these 936 lines. The
# body is what that heredoc rendered, with exactly one change: the
# `contract_source` read below named tests/contracts/immich.sh, which is where
# the runtime half used to live. It now names tests/contracts/immich-runtime.rb,
# because that is where it lives. Leaving it alone would not have failed loudly;
# it would have gone on reading a file that no longer contains what it is
# looking for, and refused every repository forever.
root, platform = ARGV
compose_path = File.join(root, "services", "immich", "compose.yml")
compose = YAML.safe_load_file(compose_path, aliases: true)
containers = compose.fetch("services")

def refuse(message)
  abort "Immich contract failed: #{message}"
end

# What a role does is its parsed task list, not the file's bytes. A task name, a
# module, or a variable that survives only inside a comment is not something the
# role executes, and every role assertion below that reads text is negative: it
# says the role does not reach into PostgreSQL. Read from source text those were
# satisfied by the comments explaining why it does not.
#
# role_strings yields the strings one at a time rather than joining them, because
# a pattern matched against a joined blob spans two unrelated tasks and reports a
# violation that neither of them contains.
def role_strings(node)
  case node
  when Hash then node.flat_map { |key, value| [key.to_s] + role_strings(value) }
  when Array then node.flat_map { |value| role_strings(value) }
  when String then [node]
  else []
  end
end

# The complete pinned stack. Immich is one application spread across four
# containers, so a partial migration is a broken migration.
EXPECTED_CONTAINERS = %w[
  immich-server immich-machine-learning redis database
].freeze

refuse("stack composition differs: #{containers.keys.sort.join(', ')}") unless
  containers.keys.sort == EXPECTED_CONTAINERS.sort

# The server and the machine learning worker ship as one release and must never
# drift apart. Asserting that relationship survives an image update; asserting
# either version would not.
coupled_tags = %w[immich-server immich-machine-learning].map do |name|
  containers.fetch(name).fetch("image")[%r{:([^:@/]+)@sha256:}, 1]
end
refuse("Immich server and machine learning versions differ: #{coupled_tags.join(', ')}") unless
  coupled_tags.compact.uniq.length == 1

containers.each do |name, spec|
  refuse("#{name} restart policy differs") unless spec.fetch("restart") == "unless-stopped"
  refuse("#{name} logging policy differs") unless spec.fetch("logging") == {
    "driver" => "json-file", "options" => { "max-size" => "10m", "max-file" => "3" }
  }
end

server = containers.fetch("immich-server")
refuse("NAS port differs") unless server.fetch("ports") == ["2283:2283"]

# Only the application is reachable. The database, the cache and the machine
# learning helper are reached over the Compose network and must never publish a
# host port, on any platform.
%w[immich-machine-learning redis database].each do |name|
  refuse("#{name} must not publish a host port") if containers.fetch(name).key?("ports")
end

# The nested bind layout of the source deployment. /data holds the originals on
# the media volume, while the regenerable and profile trees are redirected onto
# the Docker root. Both roots are parameterized so the storage inventory
# cross-check in tests/policy_test.rb applies to every Docker-root path.
refuse("storage contract differs") unless server.fetch("volumes") == [
  "${NAS_MEDIA_ROOT:?}/Immich:/data",
  "${NAS_DOCKER_ROOT:?}/immich/data/thumbs:/data/thumbs",
  "${NAS_DOCKER_ROOT:?}/immich/data/encoded-video:/data/encoded-video",
  "${NAS_DOCKER_ROOT:?}/immich/data/profile:/data/profile",
  "${NAS_MEDIA_ROOT:?}/Immich-backups/database:/data/backups"
]
refuse("model cache storage differs") unless
  containers.fetch("immich-machine-learning").fetch("volumes") ==
  ["${NAS_DOCKER_ROOT:?}/immich/data/model-cache:/cache"]
refuse("database storage differs") unless
  containers.fetch("database").fetch("volumes") ==
  [
    "${NAS_DOCKER_ROOT:?}/immich/postgres:/var/lib/postgresql/data",
    "${NAS_MEDIA_ROOT:?}/Immich-backups/database:/immich-backups:ro"
  ]

# The application must not start against an uninitialized database or cache;
# both are declared healthy-gated in the source definition.
refuse("startup ordering differs") unless server.fetch("depends_on") == {
  "redis" => { "condition" => "service_healthy" },
  "database" => { "condition" => "service_healthy" }
}
%w[immich-server immich-machine-learning database].each do |name|
  refuse("#{name} health check is disabled") if
    containers.fetch(name).fetch("healthcheck").fetch("disable", false)
end
refuse("cache health check is absent") unless
  containers.fetch("redis").fetch("healthcheck").key?("test")

database = containers.fetch("database")
refuse("database shared memory differs") unless database.fetch("shm_size") == "128mb"
refuse("database checksums are not requested") unless
  database.fetch("environment").fetch("POSTGRES_INITDB_ARGS") == "--data-checksums"

# The NAS-only capability contract. Hardware transcoding is the production
# capability and must never be weakened to make another platform work.
refuse("NAS render device mapping is absent") unless
  server.fetch("devices") == ["/dev/dri:/dev/dri"]

# Every platform that lacks /dev/dri must remove the device explicitly. Compose
# appends sequences, so a bare empty list would silently keep the NAS device:
# the !override tag is what actually replaces it.
override_path = File.join(root, "services", "immich", "compose.#{platform}.yml")
if platform == "nas"
  refuse("the NAS runs the production definition unmodified") if File.exist?(override_path)
else
  refuse("services/immich/compose.#{platform}.yml is absent") unless File.file?(override_path)
  override_text = File.read(override_path)
  override = YAML.safe_load_file(override_path, aliases: true)
  override_containers = override.fetch("services")
  surplus_services = override_containers.keys - EXPECTED_CONTAINERS
  refuse("#{platform} override may not add services: #{surplus_services.join(', ')}") unless
    surplus_services.empty?
  override_server = override_containers.fetch("immich-server")
  # Deliberately source text, both here and for ports below. safe_load erases the
  # tag, so `devices: !override []` and `devices: []` parse to the same empty
  # list — and the difference between them is exactly the bug this guards. Only
  # the source says which one was written.
  refuse("#{platform} override must reset devices with an explicit tag") unless
    override_text.match?(/^\s+devices: !override(\s|$)/)
  refuse("#{platform} override must reset devices to empty") unless
    override_server.fetch("devices") == []
  override_containers.each do |name, spec|
    surplus = spec.keys - %w[container_name devices ports]
    refuse("#{platform} override may not redefine #{surplus.join(', ')} on #{name}") unless
      surplus.empty?
    refuse("#{platform} override must not redefine the #{name} image") if spec.key?("image")
    # Renaming a Compose service would break machineLearning.urls, which Immich
    # stores as http://immich-machine-learning:3003. Only container_name moves.
    refuse("#{platform} override must not publish a host port on #{name}") if
      spec.key?("ports") && name != "immich-server"
  end
  if override_server.key?("ports")
    refuse("#{platform} override must replace published ports with an explicit tag") unless
      override_text.match?(/^\s+ports: !override(\s|$)/)
  end
end

defaults = YAML.safe_load_file(File.join(root, "roles", "immich", "defaults", "main.yml"))
settings = defaults.fetch("immich_managed_settings")
refuse("managed settings must disable the outbound version check") unless
  settings.dig("newVersionCheck", "enabled") == false
refuse("managed settings must keep machine learning enabled") unless
  settings.dig("machineLearning", "enabled") == true
refuse("managed settings must keep the database backup enabled") unless
  settings.dig("backup", "database", "enabled") == true

expected_standard_preferences = {
  "albums" => { "defaultAssetOrder" => "desc" },
  "avatar" => { "color" => "primary" },
  "cast" => { "gCastEnabled" => false },
  "download" => { "archiveSize" => 4_294_967_296, "includeEmbeddedVideos" => false },
  "emailNotifications" => { "enabled" => true, "albumInvite" => true, "albumUpdate" => true },
  "folders" => { "enabled" => false, "sidebarWeb" => false },
  "memories" => { "enabled" => true, "duration" => 5 },
  "people" => { "enabled" => true, "sidebarWeb" => false, "minimumFaces" => 3 },
  "purchase" => {
    "showSupportBadge" => true, "hideBuyButtonUntil" => "2022-02-12T00:00:00.000Z"
  },
  "ratings" => { "enabled" => false },
  "recentlyAdded" => { "sidebarWeb" => false },
  "sharedLinks" => { "enabled" => true, "sidebarWeb" => false },
  "tags" => { "enabled" => false, "sidebarWeb" => false }
}.freeze
refuse("standard managed-user preference profile differs from pinned v3.1.0 policy") unless
  defaults.dig("immich_managed_user_preference_profiles", "standard") == expected_standard_preferences
refuse("production inventory must not select the test-only compact profile") unless
  defaults.fetch("immich_managed_user_preference_profile_by_email").empty? &&
  defaults.fetch("immich_managed_user_preference_overrides").empty? &&
  defaults.fetch("immich_managed_user_preference_profiles").keys == ["standard"]
# The one line #147 changed rather than moved. This reads the runtime half's
# source out of the tree under inspection -- not out of this program's own
# checkout -- and requires the supported-unowned-preference sentinel logic to be
# live in it. Until the extraction the runtime half was a heredoc inside
# tests/contracts/immich.sh, so that was the file to read; it is
# tests/contracts/immich-runtime.rb now.
contract_source = File.read(File.join(root, "tests", "contracts", "immich-runtime.rb"))
refuse("runtime contract permits a dormant supported preference sentinel") unless
  contract_source.include?(
    "designated partial profile has no supported unowned preference sentinel"
  ) && contract_source.include?("supported unowned managed preference")

managed_user_tasks = YAML.safe_load_file(
  File.join(root, "roles", "immich", "tasks", "managed_users.yml"), aliases: true
)
configured_password_path = File.join(
  root, "roles", "immich", "tasks", "configured_password.yml"
)
configured_password_tasks = YAML.safe_load_file(configured_password_path, aliases: true)
onboarding_tasks = YAML.safe_load_file(
  File.join(root, "roles", "immich", "tasks", "user_onboarding.yml"), aliases: true
)
onboarding_names = onboarding_tasks.map { |task| task.fetch("name") }
required_onboarding_names = [
  "Authenticate every configured Immich onboarding account",
  "Require every configured Immich onboarding account",
  "Read every configured Immich user onboarding state before mutation",
  "Require every configured Immich user onboarding response before mutation",
  "Complete configured Immich user onboarding",
  "Read back every configured Immich user onboarding state",
  "Require completed onboarding for every configured Immich user"
]
refuse("configured Immich user onboarding lifecycle is incomplete") unless
  required_onboarding_names.all? { |name| onboarding_names.include?(name) }
onboarding_positions = required_onboarding_names.map { |name| onboarding_names.index(name) }
refuse("configured Immich user onboarding lifecycle is out of order") unless
  onboarding_positions == onboarding_positions.sort
onboarding_update = onboarding_tasks.find do |task|
  task["name"] == "Complete configured Immich user onboarding"
end
refuse("configured Immich onboarding must use only the supported self API") unless
  onboarding_update&.dig("ansible.builtin.uri", "url") ==
    "{{ immich_api }}/users/me/onboarding" &&
    onboarding_update.dig("ansible.builtin.uri", "method") == "PUT" &&
    onboarding_update.dig("ansible.builtin.uri", "body") == { "isOnboarded" => true } &&
    Array(onboarding_update["when"]).include?("immich_user_onboarding_phase == 'reconcile'")
refuse("Immich user onboarding role contains a database write path") if
  role_strings(onboarding_tasks).any? do |value|
    value.match?(/\bpsql\b|\buser_metadata\b|community\.postgresql|docker_compose_v2_exec/i)
  end
managed_task = lambda do |name|
  managed_user_tasks.find { |task| task["name"] == name }
end
preference_read = managed_task.call("Read Immich managed user preferences")
preference_repair = managed_task.call("Repair Immich managed user preferences")
preference_verify = managed_task.call("Verify exact Immich managed user preferences")
avatar_repair = managed_task.call("Repair Immich managed user avatar preference")
avatar_verify = managed_task.call("Verify exact Immich managed user avatar preference")
user_read = managed_task.call("Read Immich managed user avatar preferences")
preference_guard = managed_task.call("Require supported Immich managed user preference responses")
user_guard = managed_task.call("Require supported Immich managed user avatar responses")
nonadmin_guard = managed_task.call("Require non-administrator Immich managed preference targets")
refuse("managed user preference non-administrator guard is absent") unless
  nonadmin_guard&.dig("ansible.builtin.assert", "that").to_s.include?("isAdmin")
refuse("managed user preference read is absent") unless preference_read
refuse("managed user preference read does not address a target through the admin API") unless
  preference_read.dig("ansible.builtin.uri", "url").to_s.include?("/admin/users/") &&
  preference_read.dig("ansible.builtin.uri", "url").to_s.end_with?("/preferences")
refuse("managed user preference repair must use the pinned v3 PATCH") unless
  preference_repair&.dig("ansible.builtin.uri", "method") == "PATCH"
refuse("managed user preference repair does not send the desired owned leaves") unless
  preference_repair&.dig("ansible.builtin.uri", "body").to_s.include?(
    "immich_managed_user_desired_preferences"
  )
refuse("managed user preference repair must not send avatar") if
  preference_repair&.dig("ansible.builtin.uri", "body").to_s.match?(/avatar/i)
refuse("managed user preference authoritative verification is absent") unless preference_verify
refuse("avatar preference translation must use a separate pinned v3 PATCH") unless
  avatar_repair&.dig("ansible.builtin.uri", "method") == "PATCH" &&
  avatar_repair&.dig("ansible.builtin.uri", "body") == {
    "avatarColor" => "{{ immich_managed_user_desired_avatar_colors[item.item.email] }}"
  }
refuse("avatar repair must be conditional on effective avatar ownership") unless
  Array(avatar_repair["when"]).any? do |condition|
    condition.include?("item.item.email in immich_managed_user_desired_avatar_colors")
  end
refuse("avatar preference authoritative admin-user verification is absent") unless avatar_verify
refuse("authoritative admin-user pre-read must cover profiles without avatar ownership") if
  Array(user_read["when"]).to_s.include?("desired_avatar_colors")
task_positions = managed_user_tasks.each_with_index.to_h { |task, index| [task["name"], index] }
first_managed_mutation = task_positions.fetch("Repair Immich managed-user non-secret properties")
create_position = task_positions.fetch("Create absent Immich managed users")
[
  "Validate effective Immich managed user preference policies",
  "Read existing Immich managed user preferences before creation",
  "Read existing Immich managed users before creation",
  "Require supported existing Immich managed user preference responses",
  "Require non-administrator Immich managed preference targets"
].each do |name|
  refuse("#{name} must precede the batch creation boundary") unless
    task_positions.fetch(name) < create_position
end
{
  "preference read" => preference_read,
  "preference schema guard" => preference_guard,
  "administrator user read" => user_read,
  "administrator user schema guard" => user_guard
}.each do |label, task|
  refuse("#{label} must precede every managed-user PATCH") unless
    task && task_positions.fetch(task.fetch("name")) < first_managed_mutation
end
managed_user_tasks.select { |task| task.key?("ansible.builtin.uri") }.each do |task|
  refuse("secret-bearing managed-user API task is not redacted: #{task['name']}") unless
    task["no_log"] == true
end

role_tasks = YAML.safe_load_file(
  File.join(root, "roles", "immich", "tasks", "main.yml"),
  aliases: true
)
# What the role does is its parsed task list, not the file's bytes. A task name,
# a module, or a variable that survives only inside a comment is not something
# the role executes, and this file's remaining role assertions are all negative:
# they say the role no longer reaches into PostgreSQL. Read from source text they
# were satisfied by the comment that explains why it does not.
#
# role_strings yields the strings one at a time rather than joining them, because
# a pattern matched against a joined blob spans two unrelated tasks and reports a
# violation neither of them contains.
def role_strings(node)
  case node
  when Hash then node.flat_map { |key, value| [key.to_s] + role_strings(value) }
  when Array then node.flat_map { |value| role_strings(value) }
  when String then [node]
  else []
  end
end
role_task_names = role_tasks.filter_map { |task| task["name"] if task.is_a?(Hash) }
required_tasks = [
  "Read Immich initialization state",
  "Refuse a rotated Immich database credential",
  "Create the vault Immich administrator",
  "Authenticate the vault Immich administrator",
  "Require the vault Immich administrator",
  "Read the Immich system configuration",
  "Repair the Immich system configuration",
  "Complete Immich administrator onboarding",
  "Reconcile configured Immich user onboarding",
  "Verify configured Immich user onboarding",
  "Require the managed Immich settings"
]
required_tasks.each do |name|
  refuse("missing #{name}") unless role_task_names.include?(name)
end

role_task = lambda do |name|
  role_tasks.find { |task| task["name"] == name }
end
reconcile_passwords = role_task.call("Reconcile configured Immich password state")
verify_passwords = role_task.call("Verify configured Immich password state")
configured_password_includes = role_tasks.select do |task|
  include_spec = task["ansible.builtin.include_tasks"]
  include_spec == "configured_password.yml" ||
    include_spec.is_a?(Hash) && include_spec["file"] == "configured_password.yml"
end
refuse("main role must contain exactly the reconcile and verify configured-password includes") unless
  configured_password_includes == [reconcile_passwords, verify_passwords]
refuse("configured-password reconcile include is absent") unless reconcile_passwords
refuse("configured-password reconcile include differs") unless
  reconcile_passwords["ansible.builtin.include_tasks"] == "configured_password.yml" &&
  reconcile_passwords["vars"] == {
    "immich_configured_password_phase" => "reconcile",
    "immich_configured_password_token" => "{{ immich_reconcile_token }}"
  } && reconcile_passwords["when"] ==
    "not ansible_check_mode or immich_initialized | bool"
refuse("configured-password verify include is absent") unless verify_passwords
refuse("configured-password verify include differs") unless
  verify_passwords["ansible.builtin.include_tasks"] == {
    "file" => "configured_password.yml",
    "apply" => { "tags" => ["platform_verify_immich"] }
  } &&
  verify_passwords["tags"] == ["platform_verify_immich"] &&
  verify_passwords["vars"] == {
    "immich_configured_password_phase" => "verify",
    "immich_configured_password_token" => "{{ immich_verification_token }}"
  } && verify_passwords["when"] == "not ansible_check_mode"
main_role_positions = role_tasks.each_with_index.to_h do |task, index|
  [task.fetch("name"), index]
end
refuse("configured-password reconcile include is outside the managed-user lifecycle") unless
  main_role_positions.fetch("Reconcile managed Immich users") <
    main_role_positions.fetch("Reconcile configured Immich password state") &&
  main_role_positions.fetch("Reconcile configured Immich password state") <
    main_role_positions.fetch("Reconcile configured Immich user onboarding")
refuse("configured-password verify include is outside the managed-user lifecycle") unless
  main_role_positions.fetch("Verify managed Immich users") <
    main_role_positions.fetch("Verify configured Immich password state") &&
  main_role_positions.fetch("Verify configured Immich password state") <
    main_role_positions.fetch("Verify configured Immich user onboarding")

configured_task = lambda do |name|
  configured_password_tasks.find { |task| task["name"] == name }
end
configured_names = configured_password_tasks.map { |task| task.fetch("name") }
configured_positions = configured_password_tasks.each_with_index.to_h do |task, index|
  [task.fetch("name"), index]
end
required_configured_names = [
  "Validate configured Immich password phase and inputs",
  "Validate configured Immich managed identities",
  "Initialize desired configured Immich password targets",
  "Add desired managed Immich password targets",
  "Require unique desired configured Immich identities",
  "List complete Immich users for configured-password preflight",
  "Require a complete configured-password Immich user listing",
  "Require indexable configured-password Immich user records",
  "Initialize configured-password Immich user index",
  "Index configured-password Immich users by normalized email",
  "Initialize resolved configured-password Immich targets",
  "Resolve configured-password Immich targets",
  "Require exact configured-password Immich identities",
  "Require safe active configured-password Immich targets",
  "Require unique configured-password Immich target identifiers",
  "Initialize configured Immich password plan count",
  "Count configured Immich password repairs",
  "Report planned configured Immich password repair",
  "Repair configured Immich password state",
  "Re-list complete Immich users after configured-password reconciliation",
  "Require a complete authoritative configured-password user listing",
  "Require indexable authoritative configured-password user records",
  "Initialize authoritative configured-password Immich user index",
  "Index authoritative configured-password users by normalized email",
  "Initialize authoritative configured-password Immich targets",
  "Resolve authoritative configured-password Immich targets",
  "Require exact authoritative configured-password identities",
  "Require safe active authoritative configured-password targets",
  "Require unique authoritative configured-password target identifiers",
  "Require configured Immich passwords to be accepted"
]
required_configured_names.each do |name|
  refuse("configured-password milestone is not unique: #{name}") unless
    configured_names.count(name) == 1
end
required_configured_positions = required_configured_names.map do |name|
  configured_names.index(name)
end
refuse("configured-password milestone ordering differs") unless
  required_configured_positions == required_configured_positions.sort

configured_metadata_keys = %w[
  changed_when check_mode loop loop_control name no_log register when
]
allowed_configured_actions = %w[
  ansible.builtin.assert ansible.builtin.debug ansible.builtin.set_fact ansible.builtin.uri
]
configured_password_tasks.each do |task|
  action_keys = task.keys - configured_metadata_keys
  refuse("configured-password task action differs: #{task['name']}") unless
    action_keys.length == 1 && allowed_configured_actions.include?(action_keys.fetch(0))
end

normalize_configured_value = lambda do |value|
  case value
  when Hash
    value.to_h { |key, nested| [key, normalize_configured_value.call(nested)] }
  when Array
    value.map { |nested| normalize_configured_value.call(nested) }
  when String
    value.gsub(/\s+/, " ").strip
  else
    value
  end
end
expected_set_fact_by_task = {
  "Initialize desired configured Immich password targets" => {
    "immich_configured_password_desired_targets" => [{
      "normalized_email" => "{{ vault_immich_admin_email | trim | lower }}",
      "administrator" => true
    }]
  },
  "Add desired managed Immich password targets" => {
    "immich_configured_password_desired_targets" =>
      "{{ immich_configured_password_desired_targets + " \
      "[{ 'normalized_email': (item.email | trim | lower), 'administrator': false }] }}"
  },
  "Initialize configured-password Immich user index" => {
    "immich_configured_password_users_by_normalized_email" => {}
  },
  "Index configured-password Immich users by normalized email" => {
    "immich_configured_password_users_by_normalized_email" =>
      "{{ immich_configured_password_users_by_normalized_email | " \
      "combine(dict([( item.email | trim | lower, " \
      "immich_configured_password_users_by_normalized_email.get( " \
      "item.email | trim | lower, [] ) + [item] )])) }}"
  },
  "Initialize resolved configured-password Immich targets" => {
    "immich_configured_password_targets" => []
  },
  "Resolve configured-password Immich targets" => {
    "immich_configured_password_targets" =>
      "{{ immich_configured_password_targets + [item | combine({ " \
      "'matches': immich_configured_password_users_by_normalized_email.get( " \
      "item.normalized_email, [] ) })] }}"
  },
  "Initialize configured Immich password plan count" => {
    "immich_configured_password_plan_count" => 0
  },
  "Count configured Immich password repairs" => {
    "immich_configured_password_plan_count" =>
      "{{ immich_configured_password_plan_count | int + 1 }}"
  },
  "Initialize authoritative configured-password Immich user index" => {
    "immich_configured_password_authoritative_users_by_normalized_email" => {}
  },
  "Index authoritative configured-password users by normalized email" => {
    "immich_configured_password_authoritative_users_by_normalized_email" =>
      "{{ immich_configured_password_authoritative_users_by_normalized_email | " \
      "combine(dict([( item.email | trim | lower, " \
      "immich_configured_password_authoritative_users_by_normalized_email.get( " \
      "item.email | trim | lower, [] ) + [item] )])) }}"
  },
  "Initialize authoritative configured-password Immich targets" => {
    "immich_configured_password_authoritative_targets" => []
  },
  "Resolve authoritative configured-password Immich targets" => {
    "immich_configured_password_authoritative_targets" =>
      "{{ immich_configured_password_authoritative_targets + [item | combine({ " \
      "'preflight_id': ( immich_configured_password_targets | " \
      "selectattr('normalized_email', 'equalto', item.normalized_email) | " \
      "map(attribute='matches') | first | first ).id, " \
      "'matches': " \
      "immich_configured_password_authoritative_users_by_normalized_email.get( " \
      "item.normalized_email, [] ) })] }}"
  }
}
set_fact_tasks = configured_password_tasks.select do |task|
  task.key?("ansible.builtin.set_fact")
end
refuse("configured-password set-fact producer inventory differs") unless
  set_fact_tasks.map { |task| task.fetch("name") } == expected_set_fact_by_task.keys
expected_set_fact_by_task.each do |name, expected_facts|
  actual_facts = configured_task.call(name)["ansible.builtin.set_fact"]
  refuse("configured-password set-fact projection differs: #{name}") unless
    normalize_configured_value.call(actual_facts) ==
      normalize_configured_value.call(expected_facts)
end

expected_register_by_task = {
  "List complete Immich users for configured-password preflight" =>
    "immich_configured_password_listing",
  "Re-list complete Immich users after configured-password reconciliation" =>
    "immich_configured_password_authoritative_listing"
}
configured_password_tasks.each do |task|
  expected_register = expected_register_by_task[task.fetch("name")]
  if expected_register
    refuse("configured-password listing register differs: #{task['name']}") unless
      task["register"] == expected_register
  else
    refuse("configured-password task has an unexpected register: #{task['name']}") if
      task.key?("register")
  end
end

plan_marker = configured_task.call("Report planned configured Immich password repair")
refuse("configured-password check marker differs") unless
  plan_marker&.dig("ansible.builtin.debug", "msg") == "IMMICH_PLAN_CONFIGURED_PASSWORD" &&
  plan_marker["changed_when"] == true &&
  Array(plan_marker["when"]) == [
    "immich_configured_password_phase == 'reconcile'", "ansible_check_mode"
  ] &&
  plan_marker["loop"] ==
    "{{ range(0, immich_configured_password_plan_count | int) | list }}" &&
  plan_marker["loop_control"] == {
    "label" => "immich-configured-password-plan"
  }

# This focused lifecycle handles vault identities and a bearer token throughout.
# Keep every data-bearing task redacted; only the constant plan marker is safe.
configured_password_tasks.each do |task|
  next if task.equal?(plan_marker)

  refuse("configured-password task is not redacted: #{task['name']}") unless
    task["no_log"] == true
end

uri_tasks = configured_password_tasks.select { |task| task.key?("ansible.builtin.uri") }
allowed_uri_keys = %w[body body_format headers method return_content status_code url]
forbidden_executable_value =
  /\b(?:psql|sqlite3?|mysql(?:admin|dump|pump|sh)?|mariadb(?:-admin|-dump)?|\
     pgcli|createdb|dropdb|pg_dump|pg_restore|sqlcmd|isql|duckdb|mongo(?:sh)?|\
     redis-cli|docker\s+exec|shell|command|raw)\b/ix
scalar_strings = lambda do |value|
  case value
  when Hash
    value.flat_map do |key, nested|
      scalar_strings.call(key) + scalar_strings.call(nested)
    end
  when Array
    value.flat_map { |nested| scalar_strings.call(nested) }
  when String
    [value]
  else
    []
  end
end
forbidden_jinja_lookup = /\b(?:lookup|query|q)\s*\(/i
configured_password_tasks.each do |task|
  refuse("configured-password task contains an executable lookup: #{task['name']}") if
    scalar_strings.call(task).any? do |value|
      value.match?(forbidden_jinja_lookup)
    end
end
uri_tasks.each do |task|
  request = task.fetch("ansible.builtin.uri")
  refuse("configured-password URI action has unsupported fields: #{task['name']}") unless
    (request.keys - allowed_uri_keys).empty?
  refuse("configured-password URI action leaves the Immich API: #{task['name']}") unless
    request["url"].is_a?(String) && request["url"].start_with?("{{ immich_api }}/")
  refuse("configured-password URI action contains an execution path: #{task['name']}") if
    scalar_strings.call(request).any? { |value| value.match?(forbidden_executable_value) }
end
listing_tasks = uri_tasks.select do |task|
  task.dig("ansible.builtin.uri", "url") ==
    "{{ immich_api }}/admin/users?withDeleted=true"
end
refuse("configured-password lifecycle must use two complete user listings") unless
  listing_tasks.map { |task| task.fetch("name") } == [
    "List complete Immich users for configured-password preflight",
    "Re-list complete Immich users after configured-password reconciliation"
  ]
listing_tasks.each do |task|
  request = task.fetch("ansible.builtin.uri")
  refuse("configured-password listing request differs: #{task['name']}") unless
    request.fetch("headers") == {
      "Authorization" => "Bearer {{ immich_configured_password_token }}"
    } && request.fetch("status_code") == [200] && request["return_content"] == true &&
    request.fetch("method", "GET") == "GET" && !task.key?("loop") && !task.key?("when")
end

unique_targets = configured_task.call("Require unique desired configured Immich identities")
unique_condition = unique_targets&.dig("ansible.builtin.assert", "that").to_a
                       .join(" ").gsub(/\s+/, " ")
refuse("configured-password desired identities lack normalized uniqueness preflight") unless
  unique_condition ==
    "immich_configured_password_desired_targets | " \
    "map(attribute='normalized_email') | unique | length == " \
    "immich_configured_password_desired_targets | length" &&
  !unique_targets.key?("loop") && !unique_targets.key?("when")

preflight_listing = configured_task.call(
  "List complete Immich users for configured-password preflight"
)
listing_schema = configured_task.call(
  "Require a complete configured-password Immich user listing"
)
record_schema = configured_task.call(
  "Require indexable configured-password Immich user records"
)
exact_targets = configured_task.call("Require exact configured-password Immich identities")
safe_targets = configured_task.call("Require safe active configured-password Immich targets")
unique_target_ids = configured_task.call(
  "Require unique configured-password Immich target identifiers"
)
repair_passwords = configured_task.call("Repair configured Immich password state")
preflight_names = [
  "Initialize desired configured Immich password targets",
  "Add desired managed Immich password targets",
  unique_targets.fetch("name"),
  preflight_listing.fetch("name"),
  listing_schema.fetch("name"),
  record_schema.fetch("name"),
  "Initialize configured-password Immich user index",
  "Index configured-password Immich users by normalized email",
  "Initialize resolved configured-password Immich targets",
  "Resolve configured-password Immich targets",
  exact_targets.fetch("name"),
  safe_targets.fetch("name"),
  unique_target_ids.fetch("name")
]
refuse("configured-password global preflight does not precede the first PATCH") unless
  preflight_names.each_cons(2).all? do |left, right|
    configured_positions.fetch(left) < configured_positions.fetch(right)
  end && configured_positions.fetch(safe_targets.fetch("name")) <
         configured_positions.fetch(repair_passwords.fetch("name"))
refuse("configured-password listing schema guard differs") unless
  listing_schema&.dig("ansible.builtin.assert", "that") == [
    "immich_configured_password_listing.json | type_debug == 'list'"
  ]
refuse("configured-password user-record schema guard differs") unless
  record_schema&.dig("ansible.builtin.assert", "that") == [
    "item | type_debug == 'dict'", "item.email is defined",
    "item.email | type_debug == 'str'"
  ]
refuse("configured-password exact-presence guard differs") unless
  exact_targets&.dig("ansible.builtin.assert", "that") == ["item.matches | length == 1"]

full_loop_without_guard = {
  "Validate configured Immich managed identities" => "{{ vault_managed_immich_users }}",
  "Add desired managed Immich password targets" => "{{ vault_managed_immich_users }}",
  "Require indexable configured-password Immich user records" =>
    "{{ immich_configured_password_listing.json }}",
  "Index configured-password Immich users by normalized email" =>
    "{{ immich_configured_password_listing.json }}",
  "Resolve configured-password Immich targets" =>
    "{{ immich_configured_password_desired_targets }}",
  "Require exact configured-password Immich identities" =>
    "{{ immich_configured_password_targets }}",
  "Require safe active configured-password Immich targets" =>
    "{{ immich_configured_password_targets }}"
}
full_loop_without_guard.each do |name, expected_loop|
  task = configured_task.call(name)
  refuse("configured-password full-target scope differs: #{name}") unless
    task["loop"] == expected_loop && !task.key?("when")
end
refuse("configured-password listing guard has an escape condition") if
  listing_schema.key?("loop") || listing_schema.key?("when")

required_safety_conditions = [
  "item.matches[0].id | string is " \
    "match('^[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$')",
  "item.matches[0].deletedAt is not defined or item.matches[0].deletedAt is none",
  "item.matches[0].status is defined",
  "item.matches[0].status | type_debug == 'str'",
  "item.matches[0].status == 'active'",
  "item.matches[0].isAdmin is defined",
  "item.matches[0].isAdmin | type_debug == 'bool'",
  "item.matches[0].shouldChangePassword is defined",
  "item.matches[0].shouldChangePassword | type_debug == 'bool'",
  "item.matches[0].isAdmin == item.administrator"
]
actual_safety_conditions = safe_targets&.dig("ansible.builtin.assert", "that").to_a.map do |value|
  value.to_s.gsub(/\s+/, " ").strip
end
refuse("configured-password safety preflight is incomplete") unless
  actual_safety_conditions == required_safety_conditions

uuid_uniqueness_guard = lambda do |task, collection|
  name = task.fetch("name")
  expected_condition =
    "#{collection} | map(attribute='matches') | map('first') | " \
    "map(attribute='id') | unique | length == #{collection} | length"
  conditions = task.dig("ansible.builtin.assert", "that").to_a.map do |value|
    value.to_s.gsub(/\s+/, " ").strip
  end
  refuse("configured-password UUID uniqueness guard differs: #{name}") unless
    task.keys - configured_metadata_keys == ["ansible.builtin.assert"] &&
    conditions == [expected_condition] && !task.key?("loop") &&
    !task.key?("when") && !task.key?("register")
end
uuid_uniqueness_guard.call(
  unique_target_ids, "immich_configured_password_targets"
)

mutation_tasks = uri_tasks.select do |task|
  task.fetch("ansible.builtin.uri").fetch("method", "GET").upcase != "GET"
end
refuse("configured-password lifecycle must have exactly one API mutation") unless
  mutation_tasks == [repair_passwords]
repair_request = repair_passwords&.fetch("ansible.builtin.uri", {})
refuse("configured-password repair is not the exact pinned v3 projection") unless
  repair_request == {
    "url" => "{{ immich_api }}/admin/users/{{ item.matches[0].id | urlencode }}",
    "method" => "PATCH",
    "headers" => {
      "Authorization" => "Bearer {{ immich_configured_password_token }}"
    },
    "body_format" => "json",
    "body" => { "shouldChangePassword" => false },
    "status_code" => [200]
  }
refuse("configured-password mutation is reachable during verification") unless
  Array(repair_passwords["when"]) == [
    "immich_configured_password_phase == 'reconcile'",
    "not ansible_check_mode",
    "item.matches[0].shouldChangePassword"
  ] && repair_passwords["loop"] == "{{ immich_configured_password_targets }}"

initialize_plan_count = configured_task.call("Initialize configured Immich password plan count")
refuse("configured-password plan count initialization has an escape condition") if
  initialize_plan_count.key?("loop") || initialize_plan_count.key?("when")

count_repairs = configured_task.call("Count configured Immich password repairs")
refuse("configured-password plan count scope differs") unless
  count_repairs["loop"] == "{{ immich_configured_password_targets }}" &&
  Array(count_repairs["when"]) == [
    "immich_configured_password_phase == 'reconcile'",
    "ansible_check_mode",
    "item.matches[0].shouldChangePassword"
  ]

authoritative_listing = configured_task.call(
  "Re-list complete Immich users after configured-password reconciliation"
)
authoritative_listing_schema = configured_task.call(
  "Require a complete authoritative configured-password user listing"
)
authoritative_record_schema = configured_task.call(
  "Require indexable authoritative configured-password user records"
)
authoritative_exact = configured_task.call(
  "Require exact authoritative configured-password identities"
)
authoritative_safe = configured_task.call(
  "Require safe active authoritative configured-password targets"
)
authoritative_unique_target_ids = configured_task.call(
  "Require unique authoritative configured-password target identifiers"
)
accepted = configured_task.call("Require configured Immich passwords to be accepted")
authoritative_names = [
  authoritative_listing, authoritative_listing_schema, authoritative_record_schema,
  configured_task.call("Initialize authoritative configured-password Immich user index"),
  configured_task.call("Index authoritative configured-password users by normalized email"),
  configured_task.call("Initialize authoritative configured-password Immich targets"),
  configured_task.call("Resolve authoritative configured-password Immich targets"),
  authoritative_exact, authoritative_safe, authoritative_unique_target_ids, accepted
].map { |task| task.fetch("name") }
refuse("configured-password authoritative verification is out of order") unless
  configured_positions.fetch(repair_passwords.fetch("name")) <
    configured_positions.fetch(authoritative_names.first) &&
  authoritative_names.each_cons(2).all? do |left, right|
    configured_positions.fetch(left) < configured_positions.fetch(right)
  end
refuse("configured-password authoritative listing schema guard differs") unless
  authoritative_listing_schema&.dig("ansible.builtin.assert", "that") == [
    "immich_configured_password_authoritative_listing.json | type_debug == 'list'"
  ]
refuse("configured-password authoritative record schema guard differs") unless
  authoritative_record_schema&.dig("ansible.builtin.assert", "that") ==
    record_schema&.dig("ansible.builtin.assert", "that")
refuse("configured-password authoritative exact-presence guard differs") unless
  authoritative_exact&.dig("ansible.builtin.assert", "that") ==
    exact_targets&.dig("ansible.builtin.assert", "that")
authoritative_full_loop_without_guard = {
  "Require indexable authoritative configured-password user records" =>
    "{{ immich_configured_password_authoritative_listing.json }}",
  "Index authoritative configured-password users by normalized email" =>
    "{{ immich_configured_password_authoritative_listing.json }}",
  "Resolve authoritative configured-password Immich targets" =>
    "{{ immich_configured_password_desired_targets }}",
  "Require exact authoritative configured-password identities" =>
    "{{ immich_configured_password_authoritative_targets }}",
  "Require safe active authoritative configured-password targets" =>
    "{{ immich_configured_password_authoritative_targets }}"
}
authoritative_full_loop_without_guard.each do |name, expected_loop|
  task = configured_task.call(name)
  refuse("authoritative configured-password full-target scope differs: #{name}") unless
    task["loop"] == expected_loop && !task.key?("when")
end
refuse("authoritative configured-password listing guard has an escape condition") if
  authoritative_listing_schema.key?("loop") || authoritative_listing_schema.key?("when")
authoritative_safety_conditions = authoritative_safe&.dig(
  "ansible.builtin.assert", "that"
).to_a.map { |value| value.to_s.gsub(/\s+/, " ").strip }
required_authoritative_safety_conditions = required_safety_conditions.dup.insert(
  1, "item.matches[0].id == item.preflight_id"
)
refuse("configured-password authoritative safety checks omit preflight identity binding") unless
  authoritative_safety_conditions == required_authoritative_safety_conditions
uuid_uniqueness_guard.call(
  authoritative_unique_target_ids,
  "immich_configured_password_authoritative_targets"
)
refuse("configured-password authoritative false assertion differs") unless
  accepted&.dig("ansible.builtin.assert", "that") == [
    "not item.matches[0].shouldChangePassword"
  ] && accepted["loop"] == "{{ immich_configured_password_authoritative_targets }}" &&
  accepted["when"] ==
    "immich_configured_password_phase == 'verify' or not ansible_check_mode"

environment_render = role_tasks.find do |task|
  task["name"] == "Render the Immich environment"
end
refuse("Immich environment render is absent") unless environment_render
refuse("Immich environment render must remain redacted") unless
  environment_render["no_log"] == true

classifier = role_tasks.find do |task|
  task["name"] == "Classify the Immich database credential probe"
end
refuse("missing secret-safe database probe classifier") unless classifier
classifier_text = classifier.to_s
%w[execution-failed connection-rejected identity-mismatch verified].each do |status|
  refuse("database probe classifier omits #{status}") unless classifier_text.include?(status)
end
refuse("database probe classifier must remain redacted") unless classifier["no_log"] == true

assertion = role_tasks.find do |task|
  task["name"] == "Require the managed Immich database credential"
end
refuse("database credential assertion is absent") unless assertion
refuse("database credential assertion still censors its safe category") if assertion["no_log"] == true
assertion_text = assertion.to_s
refuse("database credential assertion omits the safe status") unless
  assertion_text.include?("immich_database_probe_status")
%w[vault_immich_db_password immich_database_identity stderr stdout].each do |secret_source|
  refuse("database credential assertion exposes #{secret_source}") if
    assertion_text.include?(secret_source)
end

probe = role_tasks.find do |task|
  task["name"] == "Refuse a rotated Immich database credential"
end
refuse("database credential probe is absent") unless probe
refuse("role must not use the Docker API exec module") if
  role_tasks.any? { |task| task.is_a?(Hash) && task.key?("community.docker.docker_container_exec") }
compose_probe = probe["community.docker.docker_compose_v2_exec"]
refuse("database credential probe must use Compose exec") unless compose_probe
{
  "project_src" => "{{ platform_current_dir }}/services/immich",
  "project_name" => "{{ immich_compose_project_name }}",
  "files" => "{{ platform_service_compose_files['immich'] }}",
  "env_files" => ["{{ platform_runtime_dir }}/services/immich/.env"],
  "service" => "database",
  "tty" => false
}.each do |field, expected|
  refuse("database credential Compose probe #{field} differs") unless
    compose_probe[field] == expected
end
refuse("database credential Compose probe must not supply host environment") if
  compose_probe.key?("env")
refuse("database credential Compose probe command differs") unless
  compose_probe["argv"] == [
    "sh",
    "-ec",
    "exec env PGPASSWORD=\"$POSTGRES_PASSWORD\" PGCONNECT_TIMEOUT=15 " \
      "psql --host=database --username=\"$1\" --dbname=\"$2\" " \
      "--no-align --tuples-only " \
      "--command=\"select current_user || '/' || current_database()\"",
    "immich-database-probe",
    "{{ vault_immich_db_username }}",
    "{{ vault_immich_db_name }}"
  ]
{
  "register" => "immich_database_identity",
  "when" => "not ansible_check_mode",
  "failed_when" => false,
  "changed_when" => false,
  "check_mode" => false,
  "no_log" => true
}.each do |field, expected|
  refuse("database credential Compose probe #{field} differs") unless
    probe[field] == expected
end
probe_text = probe.to_s
refuse("database credential Compose probe exposes the vault password") if
  probe_text.include?("vault_immich_db_password")
refuse("database credential Compose probe uses a host --env path") if
  probe_text.include?("--env")
refuse("database credential assertion must identify the Compose service") unless
  assertion_text.include?("Compose service database")
refuse("database credential assertion still identifies a container variable") if
  assertion_text.include?("immich_postgres_container")
role_values = role_strings(role_tasks)
refuse("role still references immich_postgres_container") if
  role_values.any? { |value| value.include?("immich_postgres_container") }

# Immich owns its schema through its own migrations. A role that reaches into
# PostgreSQL to fix application state is editing an opaque database.
refuse("role must not mutate the application schema") if
  role_values.any? { |value| value.match?(/\b(?:INSERT|UPDATE|DELETE|ALTER|DROP)\s+(?:INTO|FROM|TABLE)?/i) }
puts "Immich static contract passed (#{platform})"
