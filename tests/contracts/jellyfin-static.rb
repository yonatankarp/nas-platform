# The static half of the Jellyfin service contract: the properties of the
# repository that can be judged without a running Jellyfin. It was 354 lines
# inside a <<'RUBY' heredoc in tests/contracts/jellyfin.sh until issue #147
# gave it a file, so that sh -n, a linter and tests/jellyfin_contract_test.rb
# can all reach it.
#
# Invoked as `ruby -ryaml -rdigest jellyfin-static.rb <root> <platform>`. Both
# preloads are load-bearing and moved verbatim from the heredoc: this program
# calls YAML.safe_load_file and Digest::SHA256 without requiring either, so run
# bare it raises NameError on the first repository it looks at.
#
# ARGV[0] is the tree to INSPECT, which is not the checkout this file lives in.
# Every path below is resolved from it, the read of the runtime half's own
# source included -- tests/contracts/jellyfin.sh passes PLATFORM_CONTRACT_REPO_DIR
# through, and a caller may point that at a fixture repository.
root, platform = ARGV
compose_path = File.join(root, "services", "jellyfin", "compose.yml")
compose = YAML.safe_load_file(compose_path, aliases: true)
service = compose.fetch("services").fetch("jellyfin")
argument_specs = YAML.safe_load_file(File.join(root, "roles", "jellyfin", "meta", "argument_specs.yml"))
environment_assignments = File.readlines(
  File.join(root, "roles", "jellyfin", "templates", "env.j2")
).filter_map do |line|
  name, _separator, value = line.strip.partition("=")
  [name, value] if line.strip.match?(/\A[A-Z][A-Z0-9_]*=/)
end

def refuse(message)
  abort "Jellyfin contract failed: #{message}"
end

avatar = File.join(root, "roles", "jellyfin", "files", "yonatan-avatar.jpeg")
refuse("approved administrator avatar hash differs") unless
  Digest::SHA256.file(avatar).hexdigest ==
    "bf12ac53a05f1db64f3d00440315a6626e7c2dd12dd41867c93c9ac7aeccc792"
refuse("platform identity differs") unless service.fetch("user") == "${NAS_UID:?}:${NAS_GID:?}"
refuse("NAS port differs") unless service.fetch("ports") == ["8096:8096/tcp"]
refuse("storage contract differs") unless service.fetch("volumes") == [
  "${JELLYFIN_CONFIG_PATH:?}:/config",
  "${JELLYFIN_CACHE_PATH:?}:/cache",
  "${JELLYFIN_MEDIA_PATH:?}:/media:ro"
]
refuse("media control network membership differs") unless
  service.fetch("networks") == %w[default media-control] && compose.fetch("networks") == {
    "default" => {},
    "media-control" => { "external" => true, "name" => "${PLATFORM_MEDIA_NETWORK:?}" }
  }
refuse("media network environment is absent") unless
  environment_assignments.select { |name, _value| name == "PLATFORM_MEDIA_NETWORK" } == [
    ["PLATFORM_MEDIA_NETWORK", "{{ platform_media_control_network }}"]
  ]
refuse("media control network argument validation is absent") unless
  argument_specs.dig("argument_specs", "main", "options", "platform_media_control_network") == {
    "type" => "str", "required" => true
  }
refuse("restart policy differs") unless service.fetch("restart") == "unless-stopped"
refuse("logging policy differs") unless service.fetch("logging") == {
  "driver" => "json-file", "options" => { "max-size" => "10m", "max-file" => "3" }
}

# The NAS-only capability contract. These three keys are the production
# definition and must never be weakened to make another platform work.
refuse("NAS render device mapping is absent") unless
  service.fetch("devices") == ["/dev/dri/renderD128:/dev/dri/renderD128"]
refuse("NAS render device group access is absent") unless service.fetch("group_add") == ["0"]
refuse("NAS stop grace period differs") unless service.fetch("stop_grace_period") == "1m"
refuse("health check is absent") unless service.fetch("healthcheck").fetch("test").is_a?(Array)

# Every platform that lacks /dev/dri must remove the device and the root group
# explicitly. Compose appends sequences, so a bare empty list would silently
# keep the NAS device: the !override tag is what actually replaces it.
override_path = File.join(root, "services", "jellyfin", "compose.#{platform}.yml")
if platform == "nas"
  refuse("the NAS runs the production definition unmodified") if File.exist?(override_path)
else
  refuse("services/jellyfin/compose.#{platform}.yml is absent") unless File.file?(override_path)
  override_text = File.read(override_path)
  override = YAML.safe_load_file(override_path, aliases: true)
  override_service = override.fetch("services").fetch("jellyfin")
  %w[devices group_add].each do |key|
    refuse("#{platform} override must reset #{key} with an explicit tag") unless
      override_text.match?(/^\s+#{key}: !override(\s|$)/)
    refuse("#{platform} override must reset #{key} to empty") unless
      override_service.fetch(key) == []
  end
  allowed = %w[container_name devices group_add ports]
  surplus = override_service.keys - allowed
  refuse("#{platform} override may not redefine #{surplus.join(', ')}") unless surplus.empty?
  refuse("#{platform} override must not redefine the image") if override_service.key?("image")
  if override_service.key?("ports")
    refuse("#{platform} override must replace published ports with an explicit tag") unless
      override_text.match?(/^\s+ports: !override(\s|$)/)
  end
end

defaults = YAML.safe_load_file(File.join(root, "roles", "jellyfin", "defaults", "main.yml"))
refuse("primary administrator differs") unless defaults.fetch("jellyfin_admin_username") == "Yonatan"
refuse("server name differs") unless defaults.fetch("jellyfin_server_name") == "Yonflix 2.0"
refuse("administrator avatar hash differs") unless
  defaults.fetch("jellyfin_admin_avatar_sha256") ==
    "bf12ac53a05f1db64f3d00440315a6626e7c2dd12dd41867c93c9ac7aeccc792"
refuse("managed libraries differ") unless defaults.fetch("jellyfin_libraries") == [
  { "name" => "Movies", "collection_type" => "movies", "path" => "/media/Movies" },
  { "name" => "Shows", "collection_type" => "tvshows", "path" => "/media/Series" }
]
refuse("Collections must remain application-managed") if
  defaults.fetch("jellyfin_libraries").any? { |library| library.fetch("name") == "Collections" }
refuse("managed library must not write metadata into read-only media") unless
  defaults.fetch("jellyfin_library_options").fetch("SaveLocalMetadata") == false

# The role is asserted as parsed task structure rather than as source text. A
# task name that also occurs in a comment or a when: expression is not a task,
# and a byte offset into concatenated files is not a task position, so both the
# presence and the ordering checks below were previously approximations.
def load_tasks(path)
  File.file?(path) ? Array(YAML.safe_load_file(path, aliases: true)) : []
end

# block/rescue/always nest their tasks one level deeper. primary_identity.yml is
# entirely a block/rescue pair, so flattening is required rather than optional:
# a plain load would silently hide every task the recovery path declares.
require File.join(ENV.fetch("PLATFORM_CONTRACT_REPO_DIR"), "tests", "policy_support")
include PolicySupport

# The absence invariants further down must stay scoped to a whole file: a
# forbidden primitive introduced in some task other than the one an assertion
# names has to trip them too. Harvesting every string in the parsed tree keeps
# that whole-file reach while dropping the source-text false positives, since a
# comment that merely mentions the primitive is no longer a violation.
def deep_strings(node)
  case node
  when Hash then node.flat_map { |key, value| [key.to_s] + deep_strings(value) }
  when Array then node.flat_map { |value| deep_strings(value) }
  when String then [node]
  when nil then []
  else [node.to_s]
  end
end

tasks_dir = File.join(root, "roles", "jellyfin", "tasks")
identity_top = load_tasks(File.join(tasks_dir, "primary_identity.yml"))
settings_top = load_tasks(File.join(tasks_dir, "settings.yml"))
settings_path = File.join(tasks_dir, "settings.yml")
settings = File.file?(settings_path) ? File.read(settings_path) : ""
inventory_top = load_tasks(File.join(tasks_dir, "library_inventory.yml"))
# The concatenation order mirrors the order main.yml declares its includes in.
# It is deliberately not execution order: main.yml includes settings.yml from
# the middle of its own body, so resolving includes would interleave the
# settings phases with the identity and library phases that the preflight
# before mutation ordering assertion exists to keep apart.
#
# main.yml is read through static_role_tasks, which splices a statically
# imported stage file in where its import stands and leaves a dynamic include
# alone -- exactly what Ansible does, and exactly the distinction the paragraph
# above depends on. Reading the index alone would leave role_tasks holding its
# fifteen entries plus the four sibling files, and none of the tasks the seven
# stage files carry, so the required-task and ordering assertions below would be
# checking the wrong list.
role_tasks = flatten_tasks(PolicySupport.static_role_tasks(
  File.join(tasks_dir, "main.yml"), aliases: true
)) +
  flatten_tasks(identity_top) + flatten_tasks(settings_top) +
  flatten_tasks(load_tasks(File.join(tasks_dir, "qsv_probe.yml"))) +
  flatten_tasks(inventory_top)
settings_tasks = flatten_tasks(settings_top)
role_names = role_tasks.filter_map { |task| task["name"] }
role_at = lambda { |name| role_tasks.index { |task| task["name"] == name } }
role_task = lambda { |name| role_tasks.find { |task| task["name"] == name } || {} }
settings_task = lambda { |name| settings_tasks.find { |task| task["name"] == name } || {} }
uri_urls = lambda { |tasks| tasks.filter_map { |task| task.dig("ansible.builtin.uri", "url") } }
role_urls = uri_urls.call(role_tasks)
settings_urls = uri_urls.call(settings_tasks)
contract = File.read(File.join(root, "tests", "contracts", "jellyfin-runtime.rb"))
runtime_query = ["fields=Path,MediaSources", "RunTimeTicks"].join(",")
refuse("fixture query does not request its runtime field") unless contract.include?(runtime_query)
runtime_readiness = /ready = found\s*&&\s*found\["RunTimeTicks"\]\.is_a\?\(Integer\)\s*&&\s*Array\(found\["MediaSources"\]\)\.any\?/
refuse("fixture polling does not wait for probed media metadata") unless
  contract.match?(runtime_readiness)
required_tasks = [
  "Wait for the Jellyfin startup API",
  "Read Jellyfin startup state",
  "Materialize the Jellyfin first user",
  "Create the vault Jellyfin administrator",
  "Complete the Jellyfin startup wizard",
  "Report planned Jellyfin administrator image upload after startup",
  "Report planned Jellyfin managed library creation after startup",
  "Preflight Jellyfin managed users",
  "List Jellyfin users for primary administrator preflight",
  "Refuse ambiguous Jellyfin primary administrator identity",
  "Read Jellyfin server configuration for preflight",
  "List Jellyfin libraries for preflight",
  "Refuse unsafe Jellyfin managed library path representation",
  "Refuse ambiguous Jellyfin managed library ownership",
  "Reconcile the Jellyfin primary administrator name safely",
  "Recover the Jellyfin primary administrator name after rename failure",
  "Require recovered Jellyfin primary administrator identity",
  "Update the Jellyfin server name",
  "Upload the Jellyfin primary administrator image",
  "Rename adopted Jellyfin managed libraries",
  "Create absent Jellyfin managed libraries",
  "Remove extra paths from Jellyfin managed libraries",
  "Repair Jellyfin managed library options",
  "Require the vault Jellyfin administrator",
  "Verify exact Jellyfin owned state"
]
required_tasks.each do |name|
  refuse("missing #{name}") unless role_names.include?(name)
end
preflight_names = [
  "Preflight Jellyfin managed users",
  "List Jellyfin users for primary administrator preflight",
  "Refuse ambiguous Jellyfin primary administrator identity",
  "Read Jellyfin server configuration for preflight",
  "List Jellyfin libraries for preflight",
  "Validate and resolve Jellyfin managed library inventory"
]
mutation_names = [
  "Reconcile the Jellyfin primary administrator name safely",
  "Update the Jellyfin server name",
  "Upload the Jellyfin primary administrator image",
  "Rename adopted Jellyfin managed libraries",
  "Create absent Jellyfin managed libraries",
  "Remove extra paths from Jellyfin managed libraries",
  "Repair Jellyfin managed library options"
]
preflight = preflight_names.map(&role_at)
mutations = mutation_names.map(&role_at)
refuse("all identity/library preflight must precede mutation") unless
  preflight.none?(&:nil?) && mutations.none?(&:nil?) && preflight.max < mutations.min
refuse("current user update API is absent") unless
  role_urls.any? { |url| url.include?("/Users?userId=") }
refuse("current user image API is absent") unless
  role_urls.any? { |url| url.include?("/UserImage?userId=") }
# Both halves must belong to the same request. Asserting the path and the verb
# independently over the source accepted a DELETE declared by any other task.
extra_path_removal = role_task.call("Remove extra paths from Jellyfin managed libraries")
  .fetch("ansible.builtin.uri", {})
refuse("current path removal API is absent") unless
  extra_path_removal["url"].to_s.include?("/Library/VirtualFolders/Paths?name=") &&
    extra_path_removal["method"] == "DELETE"
primary_rename = identity_top.find do |task|
  task["name"] == "Reconcile the Jellyfin primary administrator name safely"
end || {}
refuse("primary identity rename lacks recovery") unless
  Array(primary_rename["block"]).any? && Array(primary_rename["rescue"]).any?
refuse("temporary recovery name match is not byte-exact") unless
  role_task.call("Resolve Jellyfin primary administrator matches")
    .dig("ansible.builtin.set_fact", "jellyfin_primary_temporary_matches").to_s
    .include?("if item.Name == jellyfin_primary_temporary_name else")
marker_guard_name = "Require safe Jellyfin primary administrator recovery marker file"
marker_guard_at = role_at.call(marker_guard_name)
marker_read_at = role_at.call("Read Jellyfin primary administrator recovery marker")
marker_conditions = Array(
  role_task.call(marker_guard_name).dig("ansible.builtin.assert", "that")
).map(&:to_s)
refuse("recovery marker privacy is not checked before reading") unless
  marker_guard_at && marker_read_at && marker_guard_at < marker_read_at &&
    marker_conditions.any? { |that| that.include?("stat.mode == '0600'") } &&
    marker_conditions.any? { |that| that.include?("stat.pw_name == ansible_facts.user_id") }
server_name_update_body =
  role_task.call("Update the Jellyfin server name").dig("ansible.builtin.uri", "body").to_s
refuse("server configuration update does not preserve unrelated fields") unless
  server_name_update_body.include?("jellyfin_server_configuration_for_update.json") &&
    server_name_update_body.include?("combine({'ServerName': jellyfin_server_name})")
refuse("avatar upload is unconditional") unless
  Array(role_task.call("Upload the Jellyfin primary administrator image")["when"])
    .map(&:to_s).any? { |that| that.include?("jellyfin_admin_avatar_upload_required") }
expected_nas_encoding = {
  "HardwareAccelerationType" => "qsv",
  "QsvDevice" => "/dev/dri/renderD128",
  "HardwareDecodingCodecs" => %w[h264 hevc mpeg2video vc1 vp8 vp9],
  "EnableDecodingColorDepth10Hevc" => true,
  "EnableDecodingColorDepth10Vp9" => true,
  "EnableHardwareEncoding" => true,
  "AllowHevcEncoding" => true,
  "AllowAv1Encoding" => false,
  "EnableIntelLowPowerH264HwEncoder" => true,
  "EnableIntelLowPowerHevcHwEncoder" => true,
  "EnableVppTonemapping" => true,
  "EnableTonemapping" => false
}
refuse("NAS encoding policy differs") unless
  defaults.dig("jellyfin_encoding_profiles", "nas") == expected_nas_encoding
refuse("Mac encoding policy is not explicit CPU fallback") unless
  defaults.dig("jellyfin_encoding_profiles", "mac") == expected_nas_encoding.merge(
    "HardwareAccelerationType" => "none",
    "QsvDevice" => "",
    "HardwareDecodingCodecs" => [],
    "EnableDecodingColorDepth10Hevc" => false,
    "EnableDecodingColorDepth10Vp9" => false,
    "EnableHardwareEncoding" => false,
    "AllowHevcEncoding" => false,
    "EnableIntelLowPowerH264HwEncoder" => false,
    "EnableIntelLowPowerHevcHwEncoder" => false,
    "EnableVppTonemapping" => false
  )
refuse("managed plugin repositories differ") unless defaults["jellyfin_plugin_repositories"] == [
  { "Name" => "Jellyfin Stable", "Url" => "https://repo.jellyfin.org/files/plugin/manifest.json", "Enabled" => true },
  { "Name" => "Intro Skipper", "Url" => "https://intro-skipper.org/manifest.json", "Enabled" => true }
]
refuse("retired managed plugin repositories differ") unless
  defaults["jellyfin_retired_plugin_repository_urls"] ==
    ["https://repo.jellyfin.org/releases/plugin/manifest-stable.json"]
refuse("managed plugins differ") unless defaults["jellyfin_plugins"] == ["Intro Skipper", "Open Subtitles"]
refuse("managed plugin package identities differ") unless defaults["jellyfin_plugin_packages"] == [
  { "Name" => "Intro Skipper", "AssemblyGuid" => "c83d86bb-a1e0-4c35-a113-e2101cf4ee6b",
    "RepositoryUrl" => "https://intro-skipper.org/manifest.json" },
  { "Name" => "Open Subtitles", "AssemblyGuid" => "4b9ed42f-5185-48b5-9803-6ff2989014c4",
    "RepositoryUrl" => "https://repo.jellyfin.org/files/plugin/manifest.json" }
]
[
  "Require the exact NAS Jellyfin render device",
  "Probe the Jellyfin QSV hardware device",
  "Read Jellyfin encoding configuration for preflight",
  "Refuse duplicate Jellyfin plugin repository URLs",
  "Update Jellyfin encoding configuration",
  "Merge Jellyfin plugin repositories",
  "Install absent Jellyfin plugins without a version pin",
  "Restart Jellyfin once for pending plugins",
  "Validate the Open Subtitles vault credentials",
  "Update Open Subtitles plugin configuration",
  "Verify exact Jellyfin acceleration and plugins"
].each do |name|
  refuse("missing #{name}") unless role_names.include?(name)
end
settings_strings = deep_strings(settings_top)
refuse("encoding update does not preserve unrelated fields") unless
  settings_task.call("Resolve Jellyfin encoding repair requirement")
    .dig("ansible.builtin.set_fact", "jellyfin_encoding_reconciled_document").to_s
    .include?("jellyfin_encoding_before.json | combine(jellyfin_encoding_policy)")
# A folded URL expression keeps its line breaks, so both this absence check and
# the enable-endpoint check below need the multiline flag to span one URL.
refuse("plugin install must not supply a version") if
  settings_strings.any? { |value| value.match?(%r{Packages/Installed/.*[?&]version=}m) }
plugin_install_url = settings_task
  .call("Install absent Jellyfin plugins without a version pin")
  .dig("ansible.builtin.uri", "url").to_s
refuse("plugin install is not assembly and repository scoped") unless
  plugin_install_url.include?("?assemblyGuid=") &&
    plugin_install_url.include?("&repositoryUrl=")
refuse("compatible package catalog preflight is absent") unless
  settings_urls.include?("{{ jellyfin_api }}/Packages")
refuse("disabled plugin enable endpoint is absent") unless
  settings_task.call("Enable a uniquely disabled installed Jellyfin plugin version")
    .dig("ansible.builtin.uri", "url").to_s.match?(%r{/Plugins/.*Version.*?/Enable}m)
refuse("global pending restart must not trigger a container restart") if
  settings_strings.any? { |value| value.include?("jellyfin_system_after_install") }
refuse("Open Subtitles configuration API GUID differs") unless
  settings_urls.any? { |url|
    url.include?("/Plugins/{{ jellyfin_opensubtitles_plugin_id }}/Configuration")
  } && defaults["jellyfin_opensubtitles_plugin_id"] == "4b9ed42f-5185-48b5-9803-6ff2989014c4"
refuse("Open Subtitles validation endpoint differs") unless
  settings_urls.any? { |url| url.include?("/Jellyfin.Plugin.OpenSubtitles/ValidateLoginInfo") }
refuse("integration contract does not isolate synthetic Open Subtitles credentials") unless
  contract.include?('VALIDATE_EXTERNAL_OPENSUBTITLES = PLATFORM != "integration"') &&
    contract.include?("if VALIDATE_EXTERNAL_OPENSUBTITLES\n    _response, validation = request(")
refuse("runtime Open Subtitles identity verification does not normalize GUID representation") unless
  contract.include?('opensubtitles.fetch("Id").delete("-").casecmp?(OPENSUBTITLES_ID.delete("-"))')
# Deliberately a source-text count. no_log is a per-task directive with no
# runtime observable in a static contract, and counting parsed keys would not
# distinguish the credential-carrying tasks from the rest, so the cheap
# redaction floor stays as it is.
refuse("Open Subtitles secret operations are not suppressed") unless
  settings.scan(/no_log: true/).length >= 5
refuse("seed does not verify that owned plugin and encoding policy survived") unless
  contract.include?("assert_acceleration_and_plugins(token, opensubtitles_username, opensubtitles_password)")
refuse("role must not edit an opaque database") if
  deep_strings(role_tasks).any? { |value| value.match?(/sqlite|library\.db|jellyfin\.db/i) }
puts "Jellyfin static contract passed (#{platform})"
