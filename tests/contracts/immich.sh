#!/bin/sh
set -eu
set +x

repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)}
compose=$repo_dir/services/immich/compose.yml
role=$repo_dir/roles/immich/tasks/main.yml
user_onboarding_role=$repo_dir/roles/immich/tasks/user_onboarding.yml
configured_password_role=$repo_dir/roles/immich/tasks/configured_password.yml
defaults=$repo_dir/roles/immich/defaults/main.yml

fail_contract() {
  printf 'Immich contract failed: %s\n' "$1" >&2
  exit 1
}

usage() {
  printf '%s\n' 'usage: immich.sh [--platform mac|nas|integration] [MODE]' >&2
  exit 2
}

# The platform decides which capability contract applies. It defaults to the
# contract environment ABI so the integration lane needs no extra argument.
platform=${PLATFORM_KIND:-nas}
mode=
while [ "$#" -gt 0 ]; do
  case $1 in
    --platform)
      [ "$#" -ge 2 ] || usage
      platform=$2
      shift 2
      ;;
    --) shift; break ;;
    -*) usage ;;
    *) mode=$1; shift; break ;;
  esac
done
: "${mode:=run}"
case $platform in
  mac|nas|integration) ;;
  *) fail_contract "unknown platform: $platform" ;;
esac

[ -f "$role" ] || fail_contract 'roles/immich/tasks/main.yml is absent'
[ -f "$user_onboarding_role" ] ||
  fail_contract 'roles/immich/tasks/user_onboarding.yml is absent'
[ -f "$configured_password_role" ] ||
  fail_contract 'roles/immich/tasks/configured_password.yml is absent'
[ -f "$defaults" ] || fail_contract 'roles/immich/defaults/main.yml is absent'
[ -f "$compose" ] || fail_contract 'services/immich/compose.yml is absent'

ruby -ryaml - "$repo_dir" "$platform" <<'RUBY'
root, platform = ARGV
compose_path = File.join(root, "services", "immich", "compose.yml")
compose = YAML.safe_load_file(compose_path, aliases: true)
containers = compose.fetch("services")

def refuse(message)
  abort "Immich contract failed: #{message}"
end

# The complete pinned stack. Immich is one application spread across four
# containers, so a partial migration is a broken migration.
EXPECTED_IMAGES = {
  "immich-server" =>
    "ghcr.io/immich-app/immich-server:v3.1.0@" \
    "sha256:b434cb9287eea1471c9974845914d4dd328c9c2d652e446ed4930f99944f0ceb",
  "immich-machine-learning" =>
    "ghcr.io/immich-app/immich-machine-learning:v3.1.0@" \
    "sha256:5a0839dc5303cd7215bcd2180a26aed3af41675aefb3e75e5157e9f10ad16e6e",
  "redis" =>
    "docker.io/valkey/valkey:9@" \
    "sha256:3acc0687f2a2e1091fae6450d7842dd658c941338cf0a873ddd9e14b9e4ea4dd",
  "database" =>
    "ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0@" \
    "sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23"
}.freeze

refuse("stack composition differs: #{containers.keys.sort.join(', ')}") unless
  containers.keys.sort == EXPECTED_IMAGES.keys.sort
EXPECTED_IMAGES.each do |name, image|
  refuse("#{name} legacy image pin differs") unless containers.fetch(name).fetch("image") == image
end

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
  surplus_services = override_containers.keys - EXPECTED_IMAGES.keys
  refuse("#{platform} override may not add services: #{surplus_services.join(', ')}") unless
    surplus_services.empty?
  override_server = override_containers.fetch("immich-server")
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
contract_source = File.read(File.join(root, "tests", "contracts", "immich.sh"))
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
  File.read(File.join(root, "roles", "immich", "tasks", "user_onboarding.yml"))
      .match?(/\bpsql\b|\buser_metadata\b|community\.postgresql|docker_compose_v2_exec/i)
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

role = File.read(File.join(root, "roles", "immich", "tasks", "main.yml"))
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
  refuse("missing #{name}") unless role.include?("- name: #{name}")
end

role_tasks = YAML.safe_load_file(
  File.join(root, "roles", "immich", "tasks", "main.yml"),
  aliases: true
)

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
  role.include?("community.docker.docker_container_exec")
compose_probe = probe["community.docker.docker_compose_v2_exec"]
refuse("database credential probe must use Compose exec") unless compose_probe
{
  "project_src" => "{{ platform_current_dir }}/services/immich",
  "project_name" => "{{ immich_compose_project_name }}",
  "files" => "{{ immich_compose_files }}",
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
refuse("role still references immich_postgres_container") if
  role.include?("immich_postgres_container")

# Immich owns its schema through its own migrations. A role that reaches into
# PostgreSQL to fix application state is editing an opaque database.
refuse("role must not mutate the application schema") if
  role.match?(/\b(?:INSERT|UPDATE|DELETE|ALTER|DROP)\s+(?:INTO|FROM|TABLE)?/i)
puts "Immich static contract passed (#{platform})"
RUBY

[ "$mode" = static ] && exit 0
. "${PLATFORM_LEGACY_FIXTURE_HELPER_FILE:-$repo_dir/tests/contracts/legacy-fixture-paths.sh}"
legacy_fixture_validate PLATFORM_IMMICH_UPLOAD_ROOT legacy/immich/data/upload ||
  fail_contract 'legacy upload root is unsafe'
legacy_fixture_validate PLATFORM_IMMICH_THUMBNAIL_ROOT legacy/immich/thumbs ||
  fail_contract 'legacy thumbnail root is unsafe'

: "${PLATFORM_CONTRACT_VAULT_FILE:=${PLATFORM_MAC_VAULT_FILE:-}}"
: "${PLATFORM_CONTRACT_VAULT_PASSWORD_FILE:=${PLATFORM_MAC_VAULT_PASSWORD_FILE:-}}"
: "${PLATFORM_MEDIA_ROOT:?}"
: "${PLATFORM_DOCKER_ROOT:?}"
: "${PLATFORM_REPORT_ROOT:?}"
: "${PLATFORM_IMMICH_PORT:=2283}"
: "${PLATFORM_IMMICH_SERVER_CONTAINER:=immich_server}"
: "${PLATFORM_IMMICH_MACHINE_LEARNING_CONTAINER:=immich_machine_learning}"
: "${PLATFORM_IMMICH_REDIS_CONTAINER:=immich_redis}"
: "${PLATFORM_IMMICH_POSTGRES_CONTAINER:=immich_postgres}"
PLATFORM_IMMICH_PLATFORM=$platform
PLATFORM_CONTRACT_REPO_DIR=$repo_dir
export PLATFORM_CONTRACT_VAULT_FILE PLATFORM_CONTRACT_VAULT_PASSWORD_FILE
export PLATFORM_CONTRACT_REPO_DIR
export PLATFORM_MEDIA_ROOT PLATFORM_DOCKER_ROOT PLATFORM_REPORT_ROOT
export PLATFORM_IMMICH_PORT PLATFORM_IMMICH_PLATFORM
export PLATFORM_IMMICH_SERVER_CONTAINER PLATFORM_IMMICH_MACHINE_LEARNING_CONTAINER
export PLATFORM_IMMICH_REDIS_CONTAINER PLATFORM_IMMICH_POSTGRES_CONTAINER

exec ruby - "$mode" "$@" <<'RUBY'
require "json"
require "digest"
require "net/http"
require "open3"
require "pathname"
require "timeout"
require "uri"
require "yaml"

MODE = ARGV.fetch(0)
PLATFORM = ENV.fetch("PLATFORM_IMMICH_PLATFORM")
BASE = URI("http://127.0.0.1:#{Integer(ENV.fetch('PLATFORM_IMMICH_PORT'), 10)}")
DOCKER_ROOT = Pathname.new(ENV.fetch("PLATFORM_DOCKER_ROOT")).expand_path
MEDIA_ROOT = Pathname.new(ENV.fetch("PLATFORM_MEDIA_ROOT")).expand_path
REPORT_ROOT = Pathname.new(ENV.fetch("PLATFORM_REPORT_ROOT")).expand_path
SERVER_CONTAINER = ENV.fetch("PLATFORM_IMMICH_SERVER_CONTAINER")
HELPER_CONTAINERS = [
  ENV.fetch("PLATFORM_IMMICH_MACHINE_LEARNING_CONTAINER"),
  ENV.fetch("PLATFORM_IMMICH_REDIS_CONTAINER"),
  ENV.fetch("PLATFORM_IMMICH_POSTGRES_CONTAINER")
].freeze
STATE_PATH = REPORT_ROOT.join("immich-persistence.json")
CLEAN_RESTORE_STATE_PATH = REPORT_ROOT.join("immich-clean-restore.json")
REPO_DIR = Pathname.new(ENV.fetch("PLATFORM_CONTRACT_REPO_DIR")).expand_path
MANAGED_SENTINEL = "nas-platform-unowned-sentinel"
SUPPORTED_UNOWNED_PREFERENCE_SENTINELS = [
  [%w[albums defaultAssetOrder], "asc"],
  [%w[folders enabled], true],
  [%w[ratings enabled], true],
  [%w[tags sidebarWeb], true]
].freeze

DEVICE_ID = "nas-platform-immich-contract"
MANAGED_SETTINGS = {
  ["newVersionCheck", "enabled"] => false,
  ["machineLearning", "enabled"] => true,
  ["backup", "database", "enabled"] => true
}.freeze

# Both fixtures are produced by the pinned server image's own ffmpeg with
# bitexact flags, so regenerating them yields these exact bytes. They are
# deliberately tiny: the contract proves that the pipeline ran, not that the
# encoder is fast. unpack1 rather than the base64 library, which is not a
# default gem on the Ruby 3.4 the integration lane runs.
PHOTO_FIXTURE = (
  "/9j/4AAQSkZJRgABAgAAAQABAAD/2wBDAAgICAkICQsLCwsLCw0MDQ0NDQ0NDQ0NDQ0ODg4REREO" \
  "Dg4NDQ4OEBARERITEhERERETExQUFBgYFxccHB0iIin/xABNAAEBAAAAAAAAAAAAAAAAAAAABgEB" \
  "AQEAAAAAAAAAAAAAAAAAAAYHEAEAAAAAAAAAAAAAAAAAAAAAEQEAAAAAAAAAAAAAAAAAAAAA/8AA" \
  "EQgAMABAAwEiAAIRAAMRAP/aAAwDAQACEQMRAD8AiwEo38AAAAAAAAAAAAAAAAAAAAAB/9k="
).unpack1("m0").freeze
VIDEO_FIXTURE = (
  "AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAANsbW9vdgAAAGxtdmhkAAAAAAAAAAAA" \
  "AAAAAAAD6AAAB9AAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAA" \
  "AABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAArt0cmFrAAAAXHRraGQAAAADAAAA" \
  "AAAAAAAAAAABAAAAAAAAB9AAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAA" \
  "AAAAAAAAAABAAAAAAEAAAAAwAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAfQAAAgAAABAAAA" \
  "AAIzbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAABAAAAAgABVxAAAAAAALWhkbHIAAAAAAAAAAHZp" \
  "ZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAAB3m1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAA" \
  "ACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAZ5zdGJsAAAAvnN0c2QAAAAAAAAA" \
  "AQAAAK5hdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAEAAMABIAAAASAAAAAAAAAABDExhdmMg" \
  "bGlieDI2NAAAAAAAAAAAAAAAAAAAAAAAAAAAGP//AAAANGF2Y0MBZAAK/+EAGGdkAAqs2UR7ARAA" \
  "AAMAEAAAAwCA8SJZYAEABWjvgZcs/fj4AAAAABBwYXNwAAAAAQAAAAEAAAAUYnRydAAAAAAAABC0" \
  "AAAAAAAAABhzdHRzAAAAAAAAAAEAAAAIAAAQAAAAABRzdHNzAAAAAAAAAAEAAAABAAAASGN0dHMA" \
  "AAAAAAAABwAAAAEAACAAAAAAAQAAUAAAAAABAAAgAAAAAAEAAAAAAAAAAQAAEAAAAAABAABAAAAA" \
  "AAIAABAAAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAAIAAAAAQAAADRzdHN6AAAAAAAAAAAAAAAIAAAD" \
  "dwAAAEUAAAALAAAACwAAAA4AAAAyAAAAEAAAAAsAAAAUc3RjbwAAAAAAAAABAAADnAAAAD11ZHRh" \
  "AAAANW1ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAG1kaXJhcHBsAAAAAAAAAAAAAAAACGlsc3QAAAAI" \
  "ZnJlZQAABDVtZGF0AAACrAYF//+o3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NCByMzEw" \
  "OCAzMWUxOWY5IC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyMyAt" \
  "IGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTEgcmVm" \
  "PTEgZGVibG9jaz0xOjA6MCBhbmFseXNlPTB4MzoweDExMyBtZT1oZXggc3VibWU9MiBwc3k9MSBw" \
  "c3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0wIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxs" \
  "aXM9MCA4eDhkY3Q9MSBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3Fw" \
  "X29mZnNldD0wIHRocmVhZHM9MSBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAg" \
  "bnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRf" \
  "aW50cmE9MCBiZnJhbWVzPTMgYl9weXJhbWlkPTIgYl9hZGFwdD0xIGJfYmlhcz0wIGRpcmVjdD0x" \
  "IHdlaWdodGI9MSBvcGVuX2dvcD0wIHdlaWdodHA9MSBrZXlpbnQ9MjUwIGtleWludF9taW49NCBz" \
  "Y2VuZWN1dD00MCBpbnRyYV9yZWZyZXNoPTAgcmNfbG9va2FoZWFkPTEwIHJjPWNyZiBtYnRyZWU9" \
  "MSBjcmY9NTEuMCBxY29tcD0wLjYwIHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89" \
  "MS40MCBhcT0xOjEuMDAAgAAAAMNliIQD/3pWed2t18PhusYM6x+bWCrbRWvvGc7zWFLUNP4P/jm9" \
  "kBxLrrbb562/M9iZACUP0oV330y8jPggUuS4+0xfLbnfM43H9ekXN+BE6YOsseYMK5DDGRjIIRl0" \
  "RYcwJadqcTpL89ot/gK/b8xYfs9BotEQPtUe+4FK9T/ppjvirrhFQ+u3DKTOvoS28+cNo2vmH1SA" \
  "uSEd1nJwn7pDeuzQXJhUv4Y0PATCN97EJhPQLwB4koN9mzDlOZckO6Wa5jUAAABBQZokGP+huC9W" \
  "FveGiokDD7lglt6vcViI/j5WXk/RdrP//sPAVs+79xaVLBaCf8ne+XXtlDuP/utSmGg+7E0q5UoA" \
  "AAAHQZ5CQ/+7gQAAAAcBnmFH/7uAAAAACgGeY0f/zv28EGEAAAAuQZpnNEx/oYCQbyVK3Uwaw77h" \
  "zTDiQJGbHHdUO7detW/5kya7IbaTm/NHZ8AtQQAAAAxBnoVFES//v/3RtEEAAAAHAZ6mR/+7gQ=="
).unpack1("m0").freeze

FIXTURES = [
  { name: "nas-platform-contract-photo.jpg", type: "image/jpeg",
    bytes: PHOTO_FIXTURE, kind: "IMAGE" },
  { name: "nas-platform-contract-video.mp4", type: "video/mp4",
    bytes: VIDEO_FIXTURE, kind: "VIDEO" }
].freeze

def fail_contract(message)
  warn "Immich contract failed: #{message}"
  exit 1
end

def request(method, path, token: nil, body: nil, expected: [200], raw: false,
            headers: {}, form: nil)
  uri = URI.join(BASE.to_s, path)
  request = Net::HTTP.const_get(method.capitalize).new(uri)
  request["Authorization"] = "Bearer #{token}" if token
  headers.each { |name, value| request[name] = value }
  if form
    boundary = "nasplatformimmichcontractboundary"
    request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
    request.body = multipart_body(form, boundary)
  elsif body
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body)
  end
  response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 180) do |http|
    http.request(request)
  end
  fail_contract("#{method.upcase} #{uri.path} returned HTTP #{response.code}") unless
    expected.include?(response.code.to_i)
  return response if raw

  parsed = response.body.to_s.empty? ? nil : JSON.parse(response.body)
  [response, parsed]
rescue JSON::ParserError
  fail_contract("#{method.upcase} #{uri.path} returned malformed JSON")
rescue SystemCallError, Timeout::Error, EOFError => error
  fail_contract("#{method.upcase} #{uri.path} failed: #{error.class}")
end

# Hand-built because no multipart encoder is a Ruby default gem.
def multipart_body(fields, boundary)
  body = +""
  fields.each do |field|
    body << "--#{boundary}\r\n"
    if field.key?(:filename)
      body << %(Content-Disposition: form-data; name="#{field.fetch(:name)}"; ) <<
              %(filename="#{field.fetch(:filename)}"\r\n)
      body << "Content-Type: #{field.fetch(:content_type)}\r\n\r\n"
      body << field.fetch(:value).dup.force_encoding(Encoding::BINARY)
    else
      body << %(Content-Disposition: form-data; name="#{field.fetch(:name)}"\r\n\r\n)
      body << field.fetch(:value)
    end
    body << "\r\n"
  end
  body << "--#{boundary}--\r\n"
  body.force_encoding(Encoding::BINARY)
end

# /api/server/ping answers before the container health check reports healthy, so
# readiness here is the application answering for its own initialization state.
def wait_for_application
  deadline = Time.now + 300
  loop do
    uri = URI.join(BASE.to_s, "/api/server/config")
    response = Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 15) do |http|
      http.request(Net::HTTP::Get.new(uri))
    end
    payload = JSON.parse(response.body)
    return if response.code.to_i == 200 && payload["isInitialized"] == true
  rescue JSON::ParserError, SystemCallError, Timeout::Error, EOFError
    nil
  ensure
    fail_contract("Immich never reported an initialized server") if Time.now >= deadline
    sleep 2
  end
end

def docker_capture(*argv)
  stdout, stderr, status = Open3.capture3("docker", *argv)
  fail_contract("docker #{argv.first} failed: #{argv.join(' ')}") unless status.success?
  stderr.replace("\0" * stderr.bytesize)
  stdout
end

def safe_id(value)
  fail_contract("Immich returned an unsafe API identifier") unless
    value.is_a?(String) && value.match?(/\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/)
  value
end

def inspect_container(name)
  JSON.parse(docker_capture("inspect", name)).fetch(0)
end

# The plan's containment requirement: only the application is reachable from the
# host. A published database or cache port is a LAN-facing database.
def assert_container_capabilities
  server = inspect_container(SERVER_CONTAINER)
  bindings = server.dig("HostConfig", "PortBindings") || {}
  published = bindings.reject { |_port, hosts| hosts.nil? || hosts.empty? }
  fail_contract("the application must publish exactly its own port, got #{published.keys.inspect}") unless
    published.keys == ["2283/tcp"]

  devices = server.dig("HostConfig", "Devices") || []
  if PLATFORM == "nas"
    fail_contract("the NAS render device is not mapped") unless
      devices.any? { |device| device["PathInContainer"].to_s.start_with?("/dev/dri") }
  else
    fail_contract("#{PLATFORM} must expose no host device: #{devices.inspect}") unless devices.empty?
  end

  HELPER_CONTAINERS.each do |name|
    helper = inspect_container(name)
    helper_bindings = helper.dig("HostConfig", "PortBindings") || {}
    exposed = helper_bindings.reject { |_port, hosts| hosts.nil? || hosts.empty? }
    fail_contract("#{name} publishes host ports #{exposed.keys.inspect}") unless exposed.empty?
  end
end

def read_settings(token)
  _response, config = request("get", "/api/system-config", token: token)
  config
end

def assert_user_onboarding(token)
  _response, onboarding = request("get", "/api/users/me/onboarding", token: token)
  fail_contract("configured Immich user onboarding is incomplete") unless
    onboarding == { "isOnboarded" => true }
end

def managed_leaves(config)
  MANAGED_SETTINGS.keys.to_h { |path| [path.join("."), config.dig(*path)] }
end

def assert_managed_settings(config)
  MANAGED_SETTINGS.each do |path, value|
    fail_contract("managed setting #{path.join('.')} differs") unless config.dig(*path) == value
  end
end

def deep_merge(left, right)
  left.merge(right) do |_key, old_value, new_value|
    old_value.is_a?(Hash) && new_value.is_a?(Hash) ? deep_merge(old_value, new_value) : new_value
  end
end

def managed_user_policy
  base = YAML.safe_load_file(
    REPO_DIR.join("inventory", "group_vars", "all", "main.yml"), aliases: false
  )
  fixture_path = Pathname.new(ENV.fetch("PLATFORM_MAC_FIXTURE_VARS_FILE")).expand_path
  stat = fixture_path.lstat
  fail_contract("protected Immich fixture policy is unsafe") unless
    fixture_path.absolute? && stat.file? && !stat.symlink? && stat.uid == Process.uid &&
    (stat.mode & 0o777) == 0o600
  fixture = YAML.safe_load_file(fixture_path, aliases: false)
  deep_merge(base, fixture)
rescue SystemCallError, KeyError, Psych::Exception
  fail_contract("protected Immich fixture policy is unavailable")
end

def desired_managed_user_profile(policy, email)
  normalized = email.strip.downcase
  profile_by_email = policy.fetch("immich_managed_user_preference_profile_by_email").to_h do |key, value|
    [key.strip.downcase, value]
  end
  overrides = policy.fetch("immich_managed_user_preference_overrides").to_h do |key, value|
    [key.strip.downcase, value]
  end
  profile_name = profile_by_email.fetch(
    normalized, policy.fetch("immich_managed_user_preference_profile_default")
  )
  profile = policy.fetch("immich_managed_user_preference_profiles").fetch(profile_name)
  deep_merge(profile, overrides.fetch(normalized, {}))
end

def supported_unowned_preference_sentinel(profile)
  preferences = profile.reject { |key, _value| key == "avatar" }
  SUPPORTED_UNOWNED_PREFERENCE_SENTINELS.find do |path, _value|
    !preferences.fetch(path.fetch(0), {}).key?(path.fetch(1))
  end
end

def nested_preference_patch(path, value)
  { path.fetch(0) => { path.fetch(1) => value } }
end

def designated_partial_profile_email(policy)
  designated = policy.fetch("immich_contract_partial_profile_email").strip.downcase
  selected = policy.fetch("immich_managed_user_preference_profile_by_email").filter_map do |email, name|
    email.strip.downcase if name == "compact"
  end
  fail_contract("test-only compact profile must select exactly the designated managed account") unless
    selected == [designated]
  designated
end

def list_managed_user_records(token, managed_users)
  _response, users = request("get", "/api/admin/users?withDeleted=true", token: token)
  fail_contract("Immich returned an unsupported administrator user listing") unless users.is_a?(Array)
  managed_users.to_h do |managed|
    normalized = managed.fetch("email").strip.downcase
    matches = users.select { |user| user.fetch("email", "").strip.downcase == normalized }
    fail_contract("managed Immich identity does not resolve uniquely") unless matches.length == 1
    user = matches.first
    fail_contract("managed Immich preference target is not an active non-administrator") unless
      user["status"] == "active" && user["isAdmin"] == false
    [normalized, user]
  end
end

def seed_managed_user_state(token, managed_users, policy)
  _response, users = request("get", "/api/admin/users?withDeleted=true", token: token)
  designated = designated_partial_profile_email(policy)
  managed_users.each do |managed|
    normalized = managed.fetch("email").strip.downcase
    matches = users.select { |user| user.fetch("email", "").strip.downcase == normalized }
    fail_contract("managed Immich seed identity is ambiguous") if matches.length > 1
    if matches.empty?
      _response, created = request(
        "post", "/api/admin/users", token: token, expected: [201],
        body: managed.slice("email", "password", "name").merge(
          "shouldChangePassword" => false
        )
      )
      users << created
      target = created
    else
      target = matches.first
    end
    fail_contract("refusing to seed an administrator as a managed user") unless target["isAdmin"] == false
    id = safe_id(target.fetch("id"))
    profile = desired_managed_user_profile(policy, managed.fetch("email"))
    user_patch = {
      "name" => managed.fetch("name"), "quotaSizeInBytes" => managed.fetch("quota_size"),
      "storageLabel" => MANAGED_SENTINEL
    }
    user_patch["avatarColor"] = profile.dig("avatar", "color") if
      profile.fetch("avatar", {}).key?("color")
    request(
      "patch", "/api/admin/users/#{id}", token: token,
      body: user_patch
    )
    request(
      "patch", "/api/admin/users/#{id}/preferences", token: token,
      body: profile.reject { |key, _value| key == "avatar" }
    )
    sentinel = supported_unowned_preference_sentinel(profile)
    if normalized == designated
      fail_contract("designated partial profile has no supported unowned preference sentinel") unless
        sentinel
      path, value = sentinel
      request(
        "patch", "/api/admin/users/#{id}/preferences", token: token,
        body: nested_preference_patch(path, value)
      )
    end
  end
end

def assert_managed_user_profiles(token, managed_users, policy, require_sentinel: false)
  records = list_managed_user_records(token, managed_users)
  designated = designated_partial_profile_email(policy)
  managed_users.map do |managed|
    normalized = managed.fetch("email").strip.downcase
    user = records.fetch(normalized)
    id = safe_id(user.fetch("id"))
    _response, authoritative_user = request("get", "/api/admin/users/#{id}", token: token)
    fail_contract("managed Immich authoritative user response is not an object") unless
      authoritative_user.is_a?(Hash)
    authoritative_id = authoritative_user["id"]
    authoritative_email = authoritative_user["email"]
    authoritative_admin = authoritative_user["isAdmin"]
    authoritative_password_state = authoritative_user["shouldChangePassword"]
    fail_contract("managed Immich authoritative user response has unsupported schema") unless
      authoritative_id.is_a?(String) && authoritative_email.is_a?(String) &&
      [true, false].include?(authoritative_admin) &&
      [true, false].include?(authoritative_password_state)
    fail_contract("managed Immich authoritative user read changed identity") unless
      authoritative_id == id && authoritative_email.strip.downcase == normalized &&
      authoritative_user["status"] == "active" && authoritative_admin.equal?(false)
    fail_contract("managed Immich authoritative user still requires a password change") unless
      authoritative_password_state.equal?(false)
    profile = desired_managed_user_profile(policy, managed.fetch("email"))
    if profile.fetch("avatar", {}).key?("color")
      fail_contract("managed Immich avatar preference differs") unless
        authoritative_user["avatarColor"] == profile.dig("avatar", "color")
    end
    fail_contract("managed Immich unowned sentinel was not preserved") if
      require_sentinel && authoritative_user["storageLabel"] != MANAGED_SENTINEL
    _response, preferences = request(
      "get", "/api/admin/users/#{id}/preferences", token: token
    )
    profile.reject { |key, _value| key == "avatar" }.each do |scope, leaves|
      leaves.each do |leaf, expected|
        fail_contract("managed preference #{scope}.#{leaf} differs for #{id}") unless
          preferences.dig(scope, leaf) == expected
      end
    end
    sentinel = supported_unowned_preference_sentinel(profile)
    if normalized == designated
      fail_contract("designated partial profile has no supported unowned preference sentinel") unless
        sentinel
    end
    if normalized == designated && require_sentinel
      path, expected = sentinel
      fail_contract("supported unowned managed preference #{path.join('.')} was not preserved") unless
        preferences.dig(*path) == expected
    end
    _response, managed_session = request(
      "post", "/api/auth/login", expected: [201],
      body: { "email" => managed.fetch("email"), "password" => managed.fetch("password") }
    )
    fail_contract("managed Immich authentication resolved a different identity or role") unless
      managed_session["userId"] == id && managed_session["userId"] == authoritative_user["id"] &&
      managed_session.fetch("userEmail").strip.downcase == normalized &&
      managed_session.fetch("userEmail").strip.downcase ==
        authoritative_user.fetch("email").strip.downcase &&
      managed_session["isAdmin"] == false
    managed_session_password_state = managed_session.fetch("shouldChangePassword") do
      fail_contract("managed Immich login omitted shouldChangePassword")
    end
    fail_contract("managed Immich login still requires a password change") unless
      managed_session_password_state.equal?(false)
    assert_user_onboarding(managed_session.fetch("accessToken"))
    {
      "id" => id, "email" => normalized, "name" => authoritative_user["name"],
      "quotaSizeInBytes" => authoritative_user["quotaSizeInBytes"],
      "isAdmin" => authoritative_user["isAdmin"], "avatarColor" => authoritative_user["avatarColor"],
      "storageLabel" => authoritative_user["storageLabel"],
      "preferences" => profile.reject { |key, _value| key == "avatar" },
      "supportedUnownedPreference" => sentinel && { "path" => sentinel.first.join("."),
                                                      "value" => sentinel.last }
    }
  end.sort_by { |record| record.fetch("email") }
end

def upload_fixture(token, fixture)
  _response, payload = request(
    "post", "/api/assets", token: token, expected: [200, 201],
    form: [
      { name: "assetData", filename: fixture.fetch(:name),
        content_type: fixture.fetch(:type), value: fixture.fetch(:bytes) },
      { name: "deviceAssetId", value: "#{DEVICE_ID}-#{fixture.fetch(:name)}" },
      { name: "deviceId", value: DEVICE_ID },
      { name: "fileCreatedAt", value: "2026-01-01T00:00:00.000Z" },
      { name: "fileModifiedAt", value: "2026-01-01T00:00:00.000Z" }
    ]
  )
  # An identical re-upload answers 200 "duplicate" with the same identifier, so
  # seeding is naturally re-runnable and both answers are correct here.
  fail_contract("unexpected upload status #{payload['status'].inspect}") unless
    %w[created duplicate].include?(payload["status"])
  safe_id(payload.fetch("id"))
end

def wait_for_thumbnail(token, id, timeout:)
  deadline = Time.now + timeout
  loop do
    _response, asset = request("get", "/api/assets/#{id}", token: token)
    thumbnail = request(
      "get", "/api/assets/#{id}/thumbnail?size=preview", token: token,
      raw: true, expected: (100..599).to_a
    )
    if asset["thumbhash"] && thumbnail.code.to_i == 200 && !thumbnail.body.to_s.empty?
      return asset
    end

    fail_contract("no thumbnail was generated for #{id} within #{timeout}s") if Time.now >= deadline
    sleep 3
  end
end

# Smart search is the only assertion that proves the machine learning container
# actually ran an inference: the query text is embedded by CLIP on the CPU and
# matched against embeddings the same stack produced for the fixtures.
def assert_cpu_machine_learning(token, expected_ids)
  deadline = Time.now + 600
  loop do
    _response, payload = request(
      "post", "/api/search/smart", token: token, body: { "query" => "a photograph" }
    )
    found = payload.fetch("assets").fetch("items").map { |item| item["id"] }
    return if (expected_ids - found).empty?

    if Time.now >= deadline
      fail_contract("smart search never returned the fixtures; " \
                    "machine learning produced #{found.length} embedded asset(s)")
    end
    sleep 5
  end
end

def assert_originals_open(token, records)
  records.each do |record|
    fixture = FIXTURES.find { |candidate| candidate.fetch(:name) == record.fetch("name") }
    response = request(
      "get", "/api/assets/#{record.fetch('id')}/original", token: token, raw: true
    )
    fail_contract("the original for #{record.fetch('name')} returned HTTP #{response.code}") unless
      response.code.to_i == 200
    fail_contract("the original for #{record.fetch('name')} is not the uploaded bytes") unless
      response.body == fixture.fetch(:bytes)
  end
end

def clean_restore_records(token)
  FIXTURES.map do |fixture|
    id = upload_fixture(token, fixture)
    _response, asset = request("get", "/api/assets/#{id}", token: token)
    {
      "name" => fixture.fetch(:name),
      "id" => id,
      "checksum" => asset.fetch("checksum"),
      "bytes_sha256" => Digest::SHA256.hexdigest(fixture.fetch(:bytes))
    }
  end.sort_by { |record| record.fetch("name") }
end

def wait_for_routine_backup(root, timeout:)
  pattern = /\Aimmich-db-backup-\d{8}T\d{6}-v\d+(?:\.\d+)*-pg\d+(?:\.\d+)*\.sql\.gz\z/
  deadline = Time.now + timeout
  previous = nil
  loop do
    candidates = root.children.select do |path|
      path.basename.to_s.match?(pattern) && path.file? && !path.symlink?
    end
    if candidates.length == 1 && candidates.first.size.positive?
      current = [candidates.first.basename.to_s, candidates.first.size]
      return candidates.first if current == previous
      previous = current
    else
      previous = nil
    end
    fail_contract("routine database backup did not complete") if Time.now >= deadline
    sleep 2
  end
end

vault_yaml, vault_error, vault_status = Open3.capture3(
  "ansible-vault", "view", "--vault-password-file",
  ENV.fetch("PLATFORM_CONTRACT_VAULT_PASSWORD_FILE"),
  ENV.fetch("PLATFORM_CONTRACT_VAULT_FILE")
)
fail_contract("encrypted vault could not be read") unless vault_status.success?
vault = YAML.safe_load(vault_yaml)
vault_yaml.replace("\0" * vault_yaml.bytesize)
vault_error.replace("\0" * vault_error.bytesize)
email = vault.fetch("vault_immich_admin_email")
password = vault.fetch("vault_immich_admin_password")
managed_users = vault.fetch("vault_managed_users").fetch("immich")
policy = managed_user_policy

wait_for_application
# A rejected login answers JSON here, unlike some other services in this
# platform, so the parsed body is safe to ask for.
request(
  "post", "/api/auth/login", expected: [401],
  body: { "email" => email, "password" => "contract-wrong-password" }
)
# A successful login answers 201, not 200.
_response, session = request(
  "post", "/api/auth/login", expected: [201],
  body: { "email" => email, "password" => password }
)
token = session.fetch("accessToken")
user_id = safe_id(session.fetch("userId"))
fail_contract("the vault administrator identity or role differs") unless
  session.fetch("userEmail") == email && session.fetch("isAdmin") == true
administrator_session_password_state = session.fetch("shouldChangePassword") do
  fail_contract("the vault administrator login omitted shouldChangePassword")
end
fail_contract("the vault administrator login still requires a password change") unless
  administrator_session_password_state.equal?(false)
_response, administrator_record = request(
  "get", "/api/admin/users/#{user_id}", token: token
)
fail_contract("the authoritative vault administrator response is not an object") unless
  administrator_record.is_a?(Hash)
administrator_record_id = administrator_record["id"]
administrator_record_email = administrator_record["email"]
administrator_record_admin = administrator_record["isAdmin"]
administrator_record_password_state = administrator_record["shouldChangePassword"]
fail_contract("the authoritative vault administrator response has unsupported schema") unless
  administrator_record_id.is_a?(String) && administrator_record_email.is_a?(String) &&
  [true, false].include?(administrator_record_admin) &&
  [true, false].include?(administrator_record_password_state)
fail_contract("the authoritative vault administrator identity or role differs") unless
  administrator_record_id == user_id && administrator_record_email == session["userEmail"] &&
  administrator_record_email == email && administrator_record_admin.equal?(true)
fail_contract("the authoritative vault administrator still requires a password change") unless
  administrator_record_password_state.equal?(false)
assert_user_onboarding(token)

seed_managed_user_state(token, managed_users, policy) if MODE == "seed"

# Creating a second administrator must be refused by the server itself, which is
# what makes the role's create-once behavior safe to rerun.
request(
  "post", "/api/auth/admin-sign-up", expected: [400],
  body: { "email" => "contract-intruder@example.invalid",
          "password" => "contract-wrong-password", "name" => "Contract Intruder" }
)

assert_container_capabilities
config = read_settings(token)

if MODE == "drift-verify"
  fail_contract("the Immich drift fixture was not installed") unless
    config.dig("newVersionCheck", "enabled") == true
  target = list_managed_user_records(token, managed_users).fetch(
    managed_users.first.fetch("email").strip.downcase
  )
  target_id = safe_id(target.fetch("id"))
  _response, drifted_user = request("get", "/api/admin/users/#{target_id}", token: token)
  _response, drifted_preferences = request(
    "get", "/api/admin/users/#{target_id}/preferences", token: token
  )
  desired = desired_managed_user_profile(policy, managed_users.first.fetch("email"))
  fail_contract("the Immich managed preference drift fixture was not installed") unless
    drifted_preferences.dig("folders", "enabled") != desired.dig("folders", "enabled") &&
    drifted_preferences.dig("people", "sidebarWeb") != desired.dig("people", "sidebarWeb") &&
    drifted_preferences.dig("people", "minimumFaces") != desired.dig("people", "minimumFaces") &&
    drifted_preferences.dig("albums", "defaultAssetOrder") == "asc"
  fail_contract("the Immich unowned sentinel did not survive drift installation") unless
    drifted_user["storageLabel"] == MANAGED_SENTINEL && drifted_user["isAdmin"] == false
  if STATE_PATH.file?
    seeded = JSON.parse(STATE_PATH.binread).fetch("managed_users").find do |record|
      record.fetch("email") == managed_users.first.fetch("email").strip.downcase
    end
    fail_contract("the Immich unowned avatar changed during drift installation") unless
      seeded && drifted_user["avatarColor"] == seeded["avatarColor"]
  end
  puts "Immich settings and managed-user preference drift are present"
  exit
end

assert_managed_settings(config)
managed_user_state = assert_managed_user_profiles(
  token, managed_users, policy, require_sentinel: STATE_PATH.file? || MODE == "seed"
)

if MODE == "clean-restore-seed"
  backup_root = MEDIA_ROOT.join("Immich-backups", "database")
  fail_contract("database backup root is unavailable or unsafe") unless
    backup_root.directory? && !backup_root.symlink?
  fail_contract("clean-restore backup root is not empty") unless backup_root.children.empty?
  records = clean_restore_records(token)
  assert_originals_open(token, records)
  request(
    "post", "/api/jobs", token: token, expected: [204],
    body: { "name" => "backup-database" }
  )
  backup = wait_for_routine_backup(backup_root, timeout: 180)
  state = {
    "user_id" => user_id,
    "assets" => records,
    "settings" => managed_leaves(config),
    "managed_users" => managed_user_state,
    "backup_filename" => backup.basename.to_s
  }
  fail_contract("report root is unavailable or unsafe") unless
    REPORT_ROOT.directory? && !REPORT_ROOT.symlink?
  fail_contract("refusing to replace clean-restore state") if
    CLEAN_RESTORE_STATE_PATH.exist? || CLEAN_RESTORE_STATE_PATH.symlink?
  CLEAN_RESTORE_STATE_PATH.open(File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
    file.write(JSON.generate(state))
  end
  puts "Immich clean-restore assets and routine backup seeded"
  exit
end

if MODE == "clean-restore-assert"
  fail_contract("clean-restore state is unavailable or unsafe") unless
    CLEAN_RESTORE_STATE_PATH.file? && !CLEAN_RESTORE_STATE_PATH.symlink?
  expected = JSON.parse(CLEAN_RESTORE_STATE_PATH.binread)
  records = expected.fetch("assets")
  actual_records = records.map do |record|
    id = safe_id(record.fetch("id"))
    _response, asset = request("get", "/api/assets/#{id}", token: token)
    original = request("get", "/api/assets/#{id}/original", token: token, raw: true)
    {
      "name" => record.fetch("name"),
      "id" => id,
      "checksum" => asset.fetch("checksum"),
      "bytes_sha256" => Digest::SHA256.hexdigest(original.body)
    }
  end.sort_by { |record| record.fetch("name") }
  actual = {
    "user_id" => user_id,
    "assets" => actual_records,
    "settings" => managed_leaves(config),
    "managed_users" => managed_user_state,
    "backup_filename" => expected.fetch("backup_filename")
  }
  fail_contract("Immich clean restore changed protected state") unless actual == expected
  marker = DOCKER_ROOT.join("immich", ".restore-failed")
  fail_contract("Immich restore failure marker remains") if marker.exist? || marker.symlink?
  puts "Immich clean restore recovered exact assets, users, and settings"
  exit
end

if MODE == "drift"
  drifted = config.merge("newVersionCheck" => config.fetch("newVersionCheck").merge("enabled" => true))
  request("put", "/api/system-config", token: token, body: drifted)
  first_managed = managed_users.first
  target = list_managed_user_records(token, [first_managed]).fetch(
    first_managed.fetch("email").strip.downcase
  )
  target_id = safe_id(target.fetch("id"))
  desired = desired_managed_user_profile(policy, first_managed.fetch("email"))
  request(
    "patch", "/api/admin/users/#{target_id}/preferences", token: token,
    body: {
      "folders" => { "enabled" => !desired.dig("folders", "enabled") },
      "people" => {
        "sidebarWeb" => !desired.dig("people", "sidebarWeb"),
        "minimumFaces" => desired.dig("people", "minimumFaces") + 1
      }
    }
  )
  puts "Immich settings and managed-user preference drift installed"
  exit
end

if MODE == "run"
  puts "Immich login, containment, and settings contract passed"
  exit
end
fail_contract("unknown mode: #{MODE}") unless %w[seed assert-persistence].include?(MODE)

records = FIXTURES.map do |fixture|
  id = upload_fixture(token, fixture)
  asset = wait_for_thumbnail(token, id, timeout: MODE == "seed" ? 300 : 120)
  fail_contract("#{fixture.fetch(:name)} was stored as #{asset['type'].inspect}") unless
    asset.fetch("type") == fixture.fetch(:kind)
  { "name" => fixture.fetch(:name), "id" => id, "checksum" => asset.fetch("checksum") }
end

assert_originals_open(token, records)
assert_cpu_machine_learning(token, records.map { |record| record.fetch("id") }) if MODE == "seed"

# Generated derivatives must land on the redirected Docker-root volume rather
# than beside the originals, which is the whole point of the nested bind layout.
thumbnail_root = DOCKER_ROOT.join("immich", "data", "thumbs")
thumbnail_root = Pathname.new(ENV.fetch("PLATFORM_IMMICH_THUMBNAIL_ROOT", thumbnail_root.to_s)).expand_path
fail_contract("the generated asset volume is unavailable or unsafe") unless
  thumbnail_root.directory? && !thumbnail_root.symlink?
fail_contract("no generated thumbnail reached the Docker-root volume") if
  Dir.glob(thumbnail_root.join("**", "*_thumbnail.webp").to_s).empty?
originals_root = MEDIA_ROOT.join("Immich", "upload")
originals_root = Pathname.new(ENV.fetch("PLATFORM_IMMICH_UPLOAD_ROOT", originals_root.to_s)).expand_path
fail_contract("the originals volume is unavailable or unsafe") unless
  originals_root.directory? && !originals_root.symlink?

state = JSON.generate(
  "user_id" => user_id,
  "assets" => records.sort_by { |record| record.fetch("name") },
  "settings" => managed_leaves(config),
  "managed_users" => managed_user_state
)

case MODE
when "seed"
  fail_contract("report root is unavailable or unsafe") unless
    REPORT_ROOT.directory? && !REPORT_ROOT.symlink?
  fail_contract("refusing to replace the Immich persistence artifact") if
    STATE_PATH.exist? || STATE_PATH.symlink?
  STATE_PATH.open(File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(state) }
  puts "Immich fixtures uploaded, thumbnailed, and matched by CPU machine learning"
when "assert-persistence"
  fail_contract("the Immich persistence artifact is unavailable or unsafe") unless
    STATE_PATH.file? && !STATE_PATH.symlink?
  fail_contract("Immich user, assets, or settings changed across recreation") unless
    STATE_PATH.binread == state
  puts "Immich user, assets, and settings persisted"
end
RUBY
