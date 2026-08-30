#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Shared fixtures and helpers for the media managed-user probes.
#
# Every probe drives real Ansible task files through ansible-playbook against a
# stub HTTP service, so the playbook runner, the stub server and the per-service
# task expectations live here and the probe files stay a statement of what each
# service must do.
# frozen_string_literal: true

require "base64"
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
KOMGA_AUTH_PASSWORD_EXPRESSIONS = {
  "Authenticate existing Komga managed users" => "{{ item.password }}",
  "Authenticate newly created Komga managed users" => "{{ item.item.password }}"
}.freeze

REQUIRED_TASKS = {
  "audiobookshelf" => [
    "List complete Audiobookshelf users for managed-user reconciliation",
    "Refuse incomplete Audiobookshelf managed-user listing",
    "Refuse ambiguous normalized Audiobookshelf managed identities",
    "Authenticate existing Audiobookshelf managed users",
    "Require preserved Audiobookshelf managed-user credentials",
    "Create absent Audiobookshelf managed users",
    "Authenticate newly created Audiobookshelf managed users",
    "Require newly created Audiobookshelf managed-user credentials",
    "Repair Audiobookshelf managed-user non-secret properties",
    "Verify exact Audiobookshelf managed users"
  ],
  "jellyfin" => [
    "List complete Jellyfin users for managed-user reconciliation",
    "Refuse incomplete Jellyfin managed-user listing",
    "Refuse ambiguous normalized Jellyfin managed identities",
    "Authenticate existing Jellyfin managed users",
    "Require preserved Jellyfin managed-user credentials",
    "Create absent Jellyfin managed users with initial passwords",
    "Authenticate newly created Jellyfin managed users",
    "Require newly created Jellyfin managed-user credentials",
    "Repair Jellyfin managed-user policies",
    "Verify exact Jellyfin managed users"
  ],
  "komga" => [
    "List complete Komga users for managed-user reconciliation",
    "Refuse incomplete Komga managed-user listing",
    "Refuse ambiguous normalized Komga managed identities",
    "Authenticate existing Komga managed users",
    "Require preserved Komga managed-user credentials",
    "Create absent Komga managed users",
    "Authenticate newly created Komga managed users",
    "Require newly created Komga managed-user credentials",
    "Repair Komga managed-user roles",
    "Verify exact Komga managed users"
  ]
}.freeze


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

# Every scalar mapping entry the parsed task tree carries, at any depth. The
# absence invariants below need whole-file reach, because a forbidden shape
# introduced by any task is a violation, but reading the source text instead made
# a comment that merely mentions the shape indistinguishable from the shape
# itself, and made an unrelated key that happens to end in the same word match.
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

# The probes lift task files out of the roles and run them in a synthetic play,
# so Ansible loads neither inventory/group_vars/all/main.yml nor the defaults
# beside those tasks, and every timing keyword the tasks read would be undefined.
# The values are taken from the real files rather than restated here, so a probe
# waits exactly as production does and a retimed platform stays one edit. A probe
# that declares its own value still wins, because these are merged underneath it.
TIMING_VARIABLE = /\A(?:platform|#{SERVICES.join('|')})_\w*(?:_retries|_delay|_wait_timeout)\z/
HARNESS_TIMING_DEFAULTS = (
  [File.join(ROOT, "inventory", "group_vars", "all", "main.yml")] +
  SERVICES.map { |service| File.join(ROOT, "roles", service, "defaults", "main.yml") }
).each_with_object({}) do |path, defaults|
  YAML.safe_load_file(path).each do |name, value|
    defaults[name] = value if name.match?(TIMING_VARIABLE)
  end
end.freeze

# Named the same as the shared runner it wraps: every probe passes its own
# variables and the harness timings underneath them, which is the one thing this
# suite adds to the shared runner.
def run_playbook(tasks, variables, *arguments)
  HttpFixtureSupport.run_playbook(tasks, HARNESS_TIMING_DEFAULTS.merge(variables), *arguments,
                                  prefix: "nas-platform-media-managed-users-")
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

# The probes include the role task file directly, so Ansible never loads
# roles/jellyfin/defaults/main.yml. Every role default the task file reads has to
# be declared here, the way the per-probe fixtures already declare the encoding
# policy and the plugin inventory. jellyfin_retired_plugin_repository_urls is
# pinned to the same retired URL the role asserts, so the probes exercise the
# production value instead of a harness-only substitute.
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

def basic_credentials(request)
  encoded = request.fetch("headers").fetch("authorization", "").delete_prefix("Basic ")
  Base64.decode64(encoded).split(":", 2)
end

def basic_identity(request)
  basic_credentials(request).first
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

  repair = tasks.find { |task| task_name(task).match?(/Repair .* managed-user/) && uri_task?(task) }
  if service == "audiobookshelf"
    body = repair&.dig("ansible.builtin.uri", "body")
    failures << "audiobookshelf repair does not split the pinned permission fields" unless
      body.is_a?(Hash) && body.keys.sort ==
        %w[isActive itemTagsSelected librariesAccessible permissions type]
  elsif service == "jellyfin"
    body = repair&.dig("ansible.builtin.uri", "body").to_s
    failures << "jellyfin repair does not merge into the complete current policy" unless
      body.include?(".Policy") && body.include?("combine(item.policy")
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
  main_tasks = YAML.safe_load_file(role_path, aliases: false)
  identity_tasks = File.file?(identity_path) ?
    YAML.safe_load_file(identity_path, aliases: false) : []
  inventory_tasks = YAML.safe_load_file(inventory_path, aliases: false)
  # The whole role as parsed task structure, in the same order the two files were
  # previously concatenated as text. Every assertion below reads this rather than
  # the source, so a task name in a comment is no longer a task and a byte offset
  # is no longer a position.
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
    defaults["jellyfin_server_name"] == "Yonflix 2.0"
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
  # The endpoint and the verb have to belong to the same request. Asserting them
  # independently over the source accepted a DELETE declared by any other task.
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
  # The digest has to be computed by a stat and compared by an assertion. Two
  # loose substrings could be satisfied by an unrelated stat and a stray mention.
  failures << "Jellyfin role has no authoritative image byte verification" unless
    role_tasks.any? { |task| task.dig("ansible.builtin.stat", "checksum_algorithm") == "sha256" } &&
      role_tasks.any? do |task|
        Array(task.dig("ansible.builtin.assert", "that")).any? do |condition|
          condition.to_s.match?(/stat\.checksum == jellyfin_admin_avatar_sha256/)
        end
      end

  failures
end
