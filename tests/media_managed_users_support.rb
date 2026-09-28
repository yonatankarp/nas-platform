#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Shared fixtures and helpers for the media managed-user probes (real task files run
# against a stub HTTP service).
# frozen_string_literal: true

require "base64"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "uri"
require "yaml"

require_relative "policy_support"
require_relative "http_fixture_support"

include HttpFixtureSupport
include TestScaffold

SERVICES = %w[audiobookshelf jellyfin komga].freeze
VALIDATE_POLICY = File.join(ROOT, "tests", "validate-policy.sh")
JELLYFIN_AVATAR_SHA256 = "bf12ac53a05f1db64f3d00440315a6626e7c2dd12dd41867c93c9ac7aeccc792"
JELLYFIN_INTRO_SKIPPER_ID = "c83d86bb-a1e0-4c35-a113-e2101cf4ee6b"
JELLYFIN_OPENSUBTITLES_ID = "4b9ed42f-5185-48b5-9803-6ff2989014c4"
JELLYFIN_RETIRED_STABLE_REPOSITORY =
  "https://repo.jellyfin.org/releases/plugin/manifest-stable.json"
JELLYFIN_PLUGIN_PACKAGES = [
  { "Name" => "Intro Skipper", "AssemblyGuid" => JELLYFIN_INTRO_SKIPPER_ID,
    "RepositoryUrl" => "https://intro-skipper.org/manifest.json" },
  { "Name" => "Open Subtitles", "AssemblyGuid" => JELLYFIN_OPENSUBTITLES_ID,
    "RepositoryUrl" => "https://repo.jellyfin.org/files/plugin/manifest.json" }
].freeze
# Komga, Audiobookshelf and Jellyfin run roles/managed_users behind a shim (#647), so
# the contract reads the shared role with the service's title substituted.
SHARED_MANAGED_USER_ROLE = File.join(ROOT, "roles", "managed_users", "tasks", "main.yml")
SHARED_MANAGED_USER_TITLES = { "audiobookshelf" => "Audiobookshelf", "jellyfin" => "Jellyfin",
                               "komga" => "Komga" }.freeze
KOMGA_SHIM = File.join(ROOT, "roles", "komga", "tasks", "managed_users.yml")

# The password route in two halves: the shared role reads `item.password` literally and
# the shim binds `item` to the vault's set. Either alone proves nothing.
KOMGA_AUTH_PASSWORD_EXPRESSIONS = {
  "Authenticate existing managed users: Komga" =>
    "{{ item.password if managed_users_authenticate_basic else omit }}",
  "Authenticate newly created managed users: Komga" =>
    "{{ item.item.password if managed_users_authenticate_basic else omit }}"
}.freeze
KOMGA_SHIM_PARAMETERS = {
  "managed_users_phase" => "{{ komga_managed_users_phase }}",
  "managed_users_service" => "komga",
  "managed_users_title" => "Komga",
  "managed_users_declared" => "{{ vault_managed_komga_users }}",
  "managed_users_api" => "{{ komga_api }}",
  "managed_users_admin_username" => "{{ vault_komga_admin_email }}",
  "managed_users_admin_password" => "{{ vault_komga_admin_password }}"
}.freeze
AUDIOBOOKSHELF_SHIM_PARAMETERS = {
  "managed_users_phase" => "{{ audiobookshelf_managed_users_phase }}",
  "managed_users_service" => "audiobookshelf",
  "managed_users_title" => "Audiobookshelf",
  "managed_users_declared" => "{{ vault_managed_audiobookshelf_users }}",
  "managed_users_api" => "{{ audiobookshelf_api }}",
  "managed_users_admin_headers" => {
    "Authorization" => "Bearer {{ audiobookshelf_managed_users_token }}"
  },
  "managed_users_authenticate_basic" => false,
  "managed_users_authenticate_body" => "{{ audiobookshelf_managed_users_authenticate_body }}"
}.freeze
# Jellyfin's hooks keep its policy refusals inside the lifecycle.
JELLYFIN_SHIM_PARAMETERS = {
  "managed_users_phase" => "{{ jellyfin_managed_users_phase }}",
  "managed_users_service" => "jellyfin",
  "managed_users_title" => "Jellyfin",
  "managed_users_declared" => "{{ vault_managed_jellyfin_users }}",
  "managed_users_api" => "{{ jellyfin_api }}",
  "managed_users_admin_headers" => {
    "Authorization" => "{{ jellyfin_client_header }}, Token=\"{{ jellyfin_managed_users_token }}\""
  },
  "managed_users_admin_basic" => false,
  "managed_users_authenticate_basic" => false,
  "managed_users_authenticate_headers" => { "Authorization" => "{{ jellyfin_client_header }}" },
  "managed_users_authenticate_body" => "{{ jellyfin_managed_users_authenticate_body }}",
  "managed_users_reresolve_after_creation" => true,
  "managed_users_before_create_tasks" => "{{ jellyfin_managed_users_before_create_tasks }}",
  "managed_users_after_creation_tasks" => "{{ jellyfin_managed_users_after_creation_tasks }}"
}.freeze
SHIM_PARAMETERS = {
  "audiobookshelf" => AUDIOBOOKSHELF_SHIM_PARAMETERS,
  "jellyfin" => JELLYFIN_SHIM_PARAMETERS,
  "komga" => KOMGA_SHIM_PARAMETERS
}.freeze

REQUIRED_TASKS = {
  "audiobookshelf" => [
    "List complete users for managed-user reconciliation: Audiobookshelf",
    "Refuse incomplete managed-user listing: Audiobookshelf",
    "Refuse ambiguous normalized managed identities: Audiobookshelf",
    "Authenticate existing managed users: Audiobookshelf",
    "Require preserved managed-user credentials: Audiobookshelf",
    "Create absent managed users: Audiobookshelf",
    "Authenticate newly created managed users: Audiobookshelf",
    "Require newly created managed-user credentials: Audiobookshelf",
    "Repair non-secret managed-user properties: Audiobookshelf",
    "Verify exact managed users: Audiobookshelf"
  ],
  "jellyfin" => [
    "List complete users for managed-user reconciliation: Jellyfin",
    "Refuse incomplete managed-user listing: Jellyfin",
    "Refuse ambiguous normalized managed identities: Jellyfin",
    "Authenticate existing managed users: Jellyfin",
    "Require preserved managed-user credentials: Jellyfin",
    "Run the caller's refusals before managed-user creation: Jellyfin",
    "Create absent managed users: Jellyfin",
    "Run the caller's refusals after managed-user creation: Jellyfin",
    "Authenticate newly created managed users: Jellyfin",
    "Require newly created managed-user credentials: Jellyfin",
    "Repair non-secret managed-user properties: Jellyfin",
    "Verify exact managed users: Jellyfin"
  ],
  "komga" => [
    "List complete users for managed-user reconciliation: Komga",
    "Refuse incomplete managed-user listing: Komga",
    "Refuse ambiguous normalized managed identities: Komga",
    "Authenticate existing managed users: Komga",
    "Require preserved managed-user credentials: Komga",
    "Create absent managed users: Komga",
    "Authenticate newly created managed users: Komga",
    "Require newly created managed-user credentials: Komga",
    "Repair non-secret managed-user properties: Komga",
    "Verify exact managed users: Komga"
  ]
}.freeze


# {{ managed_users_title }} is substituted in the source text before parsing.
def contract_source_tasks(service)
  title = SHARED_MANAGED_USER_TITLES[service]
  path = title ? SHARED_MANAGED_USER_ROLE : File.join(ROOT, "roles", service, "tasks",
                                                      "managed_users.yml")
  source = File.read(path)
  source = source.gsub("{{ managed_users_title }}", title) if title
  YAML.safe_load(source, aliases: false)
end

# The shim must name the shared role and bind managed_users_declared, which makes `item`
# a vault-declared user.
def shim_failures(service, shim_tasks, defaults)
  failures = []
  include = shim_tasks.find { |task| task.key?("ansible.builtin.include_role") }
  failures << "#{service} shim does not include the shared managed-user role" unless
    include&.dig("ansible.builtin.include_role", "name") == "managed_users"
  supplied = include&.fetch("vars", nil) || {}
  SHIM_PARAMETERS.fetch(service).each do |name, value|
    failures << "#{service} shim does not pass #{name} as #{value}" unless supplied[name] == value
  end

  # The declared repair body must never carry a credential.
  repair_body = defaults["#{service}_managed_users_repair_body"]
  if service == "jellyfin"
    # Jellyfin's body is a template (whole-policy replace), still never a credential.
    body = repair_body.to_s
    failures << "jellyfin existing-user repair contains secret fields" if
      body.match?(/password|passwd|secret|token/i)
    failures << "jellyfin repair does not merge into the complete current policy" unless
      body.include?(".Policy") && body.include?("combine(item.policy")
    failures.concat(jellyfin_hook_failures(defaults))
  elsif repair_body.is_a?(Hash)
    failures << "#{service} existing-user repair contains secret fields" unless
      repair_body.keys.map(&:to_s).grep(/password|passwd|secret|token/i).empty?
    failures << "audiobookshelf repair does not split the pinned permission fields" if
      service == "audiobookshelf" &&
      repair_body.keys.sort != %w[isActive itemTagsSelected librariesAccessible permissions type]
  else
    failures << "#{service} existing-user repair body is not a declared mapping"
  end
  failures
end

JELLYFIN_HOOK_TASKS = {
  "jellyfin_managed_users_before_create_tasks" => [
    "managed_users_existing_policies.yml",
    ["Require complete safe existing Jellyfin managed-user policies"]
  ],
  "jellyfin_managed_users_after_creation_tasks" => [
    "managed_users_refreshed_policies.yml",
    ["Require safe newly created Jellyfin managed-user identifiers",
     "Refuse incomplete refreshed Jellyfin managed-user listing",
     "Require complete safe refreshed Jellyfin managed-user policies"]
  ]
}.freeze

JELLYFIN_TASKS = File.join(ROOT, "roles", "jellyfin", "tasks")

# Only the self-test moves hook_directory, to read a planted copy.
def jellyfin_hook_failures(defaults, hook_directory = JELLYFIN_TASKS)
  shared_tasks = File.dirname(SHARED_MANAGED_USER_ROLE)
  JELLYFIN_HOOK_TASKS.flat_map do |parameter, (file, names)|
    path = File.expand_path(defaults[parameter].to_s, shared_tasks)
    next ["jellyfin #{parameter} does not name roles/jellyfin/tasks/#{file}"] unless
      path == File.join(JELLYFIN_TASKS, file) && File.file?(path)

    hook = Array(YAML.safe_load_file(File.join(hook_directory, file), aliases: false))
    present = hook.map { |task| task_name(task) }
    failures = (names - present).map { |name| "jellyfin #{file} omits #{name}" }
    failures << "jellyfin #{file} refusals are out of order" unless
      failures.any? || (present & names) == names
    Array(hook).each do |task|
      failures << "jellyfin #{file} loops without no_log: #{task_name(task)}" if
        task.key?("loop") && task["no_log"] != true
    end
    failures
  end
end

def task_name(task)
  task.fetch("name", "")
end

def nested_tasks(tasks)
  Array(tasks).flat_map do |task|
    [task] + %w[block rescue always].flat_map { |key| nested_tasks(task[key]) }
  end
end

def nested_task_names(tasks)
  nested_tasks(tasks).map { |task| task_name(task) }
end

# Parsed rather than source text, so a comment mentioning a shape is not the shape.
def nested_task_entries(node)
  case node
  when Hash
    node.flat_map do |key, value|
      (value.is_a?(Hash) || value.is_a?(Array) ? [] : [[key.to_s, value.to_s]]) +
        nested_task_entries(value)
    end
  when Array then node.flat_map { |value| nested_task_entries(value) }
  else []
  end
end

def uri_task?(task)
  task.key?("ansible.builtin.uri")
end

def command_available?(name)
  ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
    File.executable?(File.join(directory, name))
  end
end

# Probes load no defaults, so timing variables are read from the real files (a probe's
# own value still wins).
TIMING_VARIABLE = /\A(?:platform|#{SERVICES.join('|')})_\w*(?:_retries|_delay|_wait_timeout)\z/
HARNESS_TIMING_DEFAULTS = (
  [File.join(ROOT, "inventory", "group_vars", "all", "main.yml")] +
  SERVICES.map { |service| File.join(ROOT, "roles", service, "defaults", "main.yml") }
).each_with_object({}) do |path, defaults|
  YAML.safe_load_file(path).each do |name, value|
    defaults[name] = value if name.match?(TIMING_VARIABLE)
  end
end.freeze

# Likewise the shim's *_managed_users_* parameters, read from real defaults.
MANAGED_USER_PARAMETER = /\A(?:#{SERVICES.join('|')})_managed_users_\w+\z/
HARNESS_MANAGED_USER_DEFAULTS = SERVICES.each_with_object({}) do |service, defaults|
  YAML.safe_load_file(File.join(ROOT, "roles", service, "defaults", "main.yml")).each do |name, value|
    defaults[name] = value if name.match?(MANAGED_USER_PARAMETER)
  end
end.freeze

# roles/managed_users reads config/managed-user-capabilities.yml from the deployed
# release; defaulting it here keeps a probe that forgot it out of the skip branch.
HARNESS_RELEASE_DEFAULTS = { "platform_current_dir" => ROOT }.freeze

def run_playbook(tasks, variables, *arguments)
  HttpFixtureSupport.run_playbook(
    tasks,
    HARNESS_TIMING_DEFAULTS.merge(HARNESS_MANAGED_USER_DEFAULTS)
                           .merge(HARNESS_RELEASE_DEFAULTS).merge(variables),
    *arguments, prefix: "nas-platform-media-managed-users-"
  )
end

def with_http_service(responder, &block)
  requests = []
  reasons = { 200 => "OK", 201 => "Created", 204 => "No Content",
              401 => "Unauthorized" }.freeze
  with_http_fixture(->(port) { block.call(port, requests) },
                    reason: reasons) do |method, target, headers, body|
    request = { "method" => method, "target" => target, "headers" => headers,
                "json" => body.empty? ? nil : JSON.parse(body) }
    requests << request
    status, response = responder.call(request)
    payload = response.nil? ? "" : JSON.generate(response)
    [status, payload, payload.empty? ? nil : "application/json"]
  end
end

def includes_for(service, token_variable = nil)
  managed = File.join(ROOT, "roles", service, "tasks", "managed_users.yml")
  reconcile_vars = { "#{service}_managed_users_phase" => "reconcile" }
  verify_vars = { "#{service}_managed_users_phase" => "verify" }
  if token_variable
    reconcile_vars["#{service}_managed_users_token"] = token_variable
    verify_vars["#{service}_managed_users_token"] = token_variable
  end
  [
    { "name" => "Reconcile fixture #{service}", "ansible.builtin.include_tasks" => managed,
      "vars" => reconcile_vars },
    { "name" => "Verify fixture #{service}", "ansible.builtin.include_tasks" => managed,
      "vars" => verify_vars }
  ]
end

# Probes include task files directly, so every role default they read is declared here,
# with production values.
def jellyfin_settings_includes(*phases)
  settings = File.join(ROOT, "roles", "jellyfin", "tasks", "settings.yml")
  phases.flat_map do |phase|
    scopes = phase == "activate" ? %w[opensubtitles remaining] : [nil]
    scopes.map do |scope|
      label = [phase.capitalize, scope&.capitalize].compact.join(" ")
      variables = { "jellyfin_settings_phase" => phase,
                    "jellyfin_retired_plugin_repository_urls" =>
                      [JELLYFIN_RETIRED_STABLE_REPOSITORY],
                    "jellyfin_settings_token" => "{{ jellyfin_reconcile_token | default('admin-token') }}" }
      variables["jellyfin_activation_scope"] = scope if scope
      { "name" => "#{label} fixture Jellyfin settings",
        "ansible.builtin.include_tasks" => settings,
        "vars" => variables }
    end
  end
end

def jellyfin_library_inventory_include(name, response)
  {
    "name" => name,
    "ansible.builtin.include_tasks" =>
      File.join(ROOT, "roles", "jellyfin", "tasks", "library_inventory.yml"),
    "vars" => { "jellyfin_library_inventory_response" => response }
  }
end

# The whole role with static imports spliced in; reading only the index would select
# nothing and pass vacuously.
def jellyfin_role_tasks
  PolicySupport.static_role_tasks(
    File.join(ROOT, "roles", "jellyfin", "tasks", "main.yml"), aliases: false
  )
end

def basic_credentials(request)
  encoded = request.fetch("headers").fetch("authorization", "").delete_prefix("Basic ")
  Base64.decode64(encoded).split(":", 2)
end

def contract_failures(service, tasks)
  failures = []
  names = tasks.map { |task| task_name(task) }
  REQUIRED_TASKS.fetch(service).each do |name|
    failures << "#{service} omits #{name}" unless names.include?(name)
  end
  lifecycle = REQUIRED_TASKS.fetch(service)
  positions = lifecycle.map { |name| names.index(name) }
  failures << "#{service} managed-user lifecycle is out of order" unless
    positions.none?(&:nil?) && positions == positions.sort

  failures << "#{service} contains a destructive user deletion" if tasks.any? do |task|
    uri_task?(task) && task.dig("ansible.builtin.uri", "method").to_s.upcase == "DELETE"
  end
  tasks.select { |task| uri_task?(task) }.each do |task|
    failures << "#{service} URI task lacks no_log: #{task_name(task)}" unless task["no_log"] == true
  end

  updates = tasks.select do |task|
    task_name(task).match?(/Repair .* managed-user/) && uri_task?(task)
  end
  updates.each do |task|
    body = task.dig("ansible.builtin.uri", "body")
    next unless body.is_a?(Hash)

    forbidden = body.keys.map(&:to_s).grep(/password|passwd|secret|token/i)
    failures << "#{service} existing-user repair contains secret fields" unless forbidden.empty?
  end

  auth_assert = tasks.find { |task| task_name(task).start_with?("Require preserved") }
  guidance = auth_assert&.dig("ansible.builtin.assert", "fail_msg").to_s
  failures << "#{service} auth failure omits reviewed credential-migration guidance" unless
    guidance.include?("reviewed credential-migration procedure") && guidance.include?("not reset")

  create = tasks.find { |task| task_name(task).start_with?("Create absent") }
  repair = tasks.find { |task| task_name(task).start_with?("Repair") }
  [create, repair].compact.each do |task|
    conditions = Array(task["when"])
    failures << "#{service} mutation is not disabled in check mode: #{task_name(task)}" unless
      conditions.include?("not ansible_check_mode")
  end

  tasks.select { |task| task_name(task).start_with?("Authenticate") }.each do |task|
    failures << "#{service} authentication is not disabled in check mode: #{task_name(task)}" unless
      Array(task["when"]).include?("not ansible_check_mode") && task["check_mode"] != false
  end
  if service == "komga"
    KOMGA_AUTH_PASSWORD_EXPRESSIONS.each do |auth_name, expected_password|
      auth_task = tasks.find { |task| task_name(task) == auth_name }
      failures << "komga vault password expression differs for #{auth_name}" unless
        auth_task&.dig("ansible.builtin.uri", "url_password") == expected_password
    end
  end

  failures << "#{service} task file mentions unmanaged deletion" if tasks.any? do |task|
    task_name(task).match?(/delete|remove|absent.*unmanaged/i)
  end

  failures
end

def jellyfin_identity_contract_failures
  failures = []
  defaults = YAML.safe_load_file(
    File.join(ROOT, "roles", "jellyfin", "defaults", "main.yml"), aliases: false
  )
  role_path = File.join(ROOT, "roles", "jellyfin", "tasks", "main.yml")
  identity_path = File.join(ROOT, "roles", "jellyfin", "tasks", "primary_identity.yml")
  inventory_path = File.join(ROOT, "roles", "jellyfin", "tasks", "library_inventory.yml")
  main_tasks = PolicySupport.static_role_tasks(role_path, aliases: false)
  identity_tasks = File.file?(identity_path) ?
    YAML.safe_load_file(identity_path, aliases: false) : []
  inventory_tasks = YAML.safe_load_file(inventory_path, aliases: false)
  # Parsed structure, so a task name in a comment is not a task.
  role_tasks = nested_tasks(main_tasks) + nested_tasks(identity_tasks) +
    nested_tasks(inventory_tasks)
  role_urls = role_tasks.filter_map { |task| task.dig("ansible.builtin.uri", "url") }
  role_task = ->(name) { role_tasks.find { |task| task_name(task) == name } || {} }
  names = nested_task_names(main_tasks) + nested_task_names(identity_tasks) +
    nested_task_names(inventory_tasks)
  avatar = File.join(ROOT, "roles", "jellyfin", "files", "yonatan-avatar.jpeg")

  failures << "Jellyfin primary administrator is not exact" unless
    defaults["jellyfin_admin_username"] == "Yonatan"
  failures << "Jellyfin server name is not exact" unless
    defaults["jellyfin_server_name"] == "Yonflix 2.1"
  failures << "Jellyfin managed libraries are not exact" unless
    defaults["jellyfin_libraries"] == [
      { "name" => "Movies", "collection_type" => "movies", "path" => "/media/Movies" },
      { "name" => "Shows", "collection_type" => "tvshows", "path" => "/media/Series" }
    ]
  failures << "Jellyfin must not explicitly manage Collections" if
    defaults.fetch("jellyfin_libraries", []).any? { |library| library["name"] == "Collections" } ||
      nested_task_entries(role_tasks).any? do |key, value|
        %w[name collection_type path].include?(key) && value.match?(/\ACollections/i)
      end
  failures << "Jellyfin approved administrator avatar is absent" unless File.file?(avatar)
  if File.file?(avatar)
    require "digest"
    failures << "Jellyfin approved administrator avatar hash differs" unless
      Digest::SHA256.file(avatar).hexdigest == JELLYFIN_AVATAR_SHA256
  end
  failures << "Jellyfin avatar hash contract differs" unless
    defaults["jellyfin_admin_avatar_sha256"] == JELLYFIN_AVATAR_SHA256
  inventory_response_gate = inventory_tasks.first
  failures << "Jellyfin library inventory response type is not gated before iteration" unless
    task_name(inventory_response_gate) == "Require complete Jellyfin library inventory response" &&
      !inventory_response_gate.key?("loop") &&
      inventory_response_gate.dig("ansible.builtin.assert", "that")&.include?(
        "jellyfin_library_inventory_response | type_debug == 'list'"
      )

  rename_wait = role_task.call("Wait for renamed Jellyfin managed library identities")
  item_id_gate = rename_wait.dig("vars", "jellyfin_library_identity_inventory_globally_settled").to_s
  failures << "Jellyfin renamed-library ItemId validation must type-filter before regex matching" unless
    item_id_gate.match?(/map\(attribute='ItemId'\)\s*\|\s*select\('string'\)\s*\|\s*select\('match'/m)

  required = [
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
    "Refresh Jellyfin after managed library changes",
    "Verify exact Jellyfin owned state"
  ]
  required.each { |name| failures << "Jellyfin main role omits #{name}" unless names.include?(name) }
  check_plans = [
    "Report planned Jellyfin administrator image upload after startup",
    "Report planned Jellyfin managed library creation after startup"
  ]
  check_plans.each { |name| failures << "Jellyfin main role omits #{name}" unless names.include?(name) }
  preflight_names = required.first(5) + ["Validate and resolve Jellyfin managed library inventory"]
  preflight = preflight_names.filter_map { |name| names.index(name) }
  first_mutation = required.drop(7).filter_map { |name| names.index(name) }.min
  failures << "Jellyfin identity/library preflight does not precede every mutation" unless
    preflight.length == preflight_names.length && first_mutation && preflight.max < first_mutation
  failures << "Jellyfin primary rename does not use the supported current endpoint" unless
    role_urls.any? { |url| url.include?("/Users?userId=") }
  primary_rename = Array(identity_tasks).find do |task|
    task_name(task) == "Reconcile the Jellyfin primary administrator name safely"
  end || {}
  failures << "Jellyfin primary rename is not guarded by block/rescue recovery" unless
    nested_tasks(main_tasks).any? do |task|
      task["ansible.builtin.include_tasks"].to_s.include?("primary_identity.yml")
    end && Array(primary_rename["block"]).any? && Array(primary_rename["rescue"]).any?
  failures << "Jellyfin temporary recovery match is not byte-exact" unless
    role_task.call("Resolve Jellyfin primary administrator matches")
             .dig("ansible.builtin.set_fact", "jellyfin_primary_temporary_matches").to_s
             .include?("if item.Name == jellyfin_primary_temporary_name else")
  # Endpoint and verb must belong to the same request.
  extra_path_removal = role_task.call("Remove extra paths from Jellyfin managed libraries")
                                .fetch("ansible.builtin.uri", {})
  failures << "Jellyfin extra library paths do not use the supported removal endpoint" unless
    extra_path_removal["url"].to_s.include?("/Library/VirtualFolders/Paths?name=") &&
      extra_path_removal["method"] == "DELETE"
  create_library = main_tasks.find do |task|
    task_name(task) == "Create absent Jellyfin managed libraries"
  end
  rename_library = main_tasks.find do |task|
    task_name(task) == "Rename adopted Jellyfin managed libraries"
  end
  refresh_library = main_tasks.find do |task|
    task_name(task) == "Refresh Jellyfin after managed library changes"
  end
  failures << "Jellyfin library rename does not request identity refresh" unless
    rename_library&.dig("ansible.builtin.uri", "url").to_s.include?("refreshLibrary=true")
  failures << "Jellyfin library creation starts a scan before reconciliation completes" unless
    create_library&.dig("ansible.builtin.uri", "url").to_s.include?("refreshLibrary=false")
  failures << "Jellyfin managed library reconciliation does not trigger one deferred refresh" unless
    refresh_library&.dig("ansible.builtin.uri", "url").to_s.include?("/Library/Refresh") &&
      refresh_library&.dig("ansible.builtin.uri", "method") == "POST" &&
      refresh_library&.fetch("when", []).any? { |condition| condition.to_s.include?("is changed") }
  failures << "Jellyfin image upload does not use the supported current endpoint" unless
    role_urls.any? { |url| url.include?("/UserImage?userId=") }
  server_name_update_body =
    role_task.call("Update the Jellyfin server name").dig("ansible.builtin.uri", "body").to_s
  failures << "Jellyfin server update does not preserve the full configuration" unless
    server_name_update_body.include?("jellyfin_server_configuration_for_update.json") &&
      server_name_update_body.include?("combine({'ServerName': jellyfin_server_name})")
  failures << "Jellyfin role has no authoritative image byte verification" unless
    role_tasks.any? { |task| task.dig("ansible.builtin.stat", "checksum_algorithm") == "sha256" } &&
      role_tasks.any? do |task|
        Array(task.dig("ansible.builtin.assert", "that")).any? do |condition|
          condition.to_s.match?(/stat\.checksum == jellyfin_admin_avatar_sha256/)
        end
      end

  failures
end
