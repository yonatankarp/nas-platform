#!/usr/bin/env ruby
# frozen_string_literal: true

# Reconciliation behaviour for Bazarr provider and settings.
# Shared fixtures live in media_acquisition_reconciliation_support.rb.

require_relative "media_acquisition_reconciliation_support"

failures = []

# The core file's dedicated production probe establishes the fingerprint
# algorithm for this gate run; if it regresses, that file fails. This file can
# therefore seed equivalent private baselines instead of running another setup
# playbook before every scenario, exactly as the single-file fixture did once
# the probe had passed.
FINGERPRINT_BASELINE_CACHE["enabled"] = true

bazarr_state = { "bazarr" => deep_copy(BAZARR) }
bazarr_mutations = {
  "auth.type" => ->(state) { state.dig("bazarr", "auth")["type"] = "basic" },
  "auth.type nullable default" => ->(state) { state.dig("bazarr", "auth")["type"] = nil },
  "auth.username" => ->(state) { state.dig("bazarr", "auth")["username"] = "legacy" },
  "general.use_radarr" => ->(state) { state.dig("bazarr", "general")["use_radarr"] = false },
  "general.use_sonarr" => ->(state) { state.dig("bazarr", "general")["use_sonarr"] = false },
  "radarr.ip" => ->(state) { state.dig("bazarr", "radarr")["ip"] = "legacy-radarr" },
  "radarr.port" => ->(state) { state.dig("bazarr", "radarr")["port"] = 9999 },
  "radarr.base_url" => ->(state) { state.dig("bazarr", "radarr")["base_url"] = "/legacy" },
  "radarr.ssl" => ->(state) { state.dig("bazarr", "radarr")["ssl"] = true },
  "sonarr.ip" => ->(state) { state.dig("bazarr", "sonarr")["ip"] = "legacy-sonarr" },
  "sonarr.port" => ->(state) { state.dig("bazarr", "sonarr")["port"] = 9999 },
  "sonarr.base_url" => ->(state) { state.dig("bazarr", "sonarr")["base_url"] = "/legacy" },
  "sonarr.ssl" => ->(state) { state.dig("bazarr", "sonarr")["ssl"] = true },
  "identical series paths" => ->(state) { state.dig("bazarr", "general")["path_mappings"] = [["/old", "/new"]] },
  "identical movie paths" => ->(state) { state.dig("bazarr", "general")["path_mappings_movie"] = [["/old", "/new"]] },
  "sorted languages" => ->(state) { state.dig("bazarr", "languages")["enabled"] = ["fr"] }
}
bazarr_connection_write = lambda do |request|
  request["method"] == "POST" && request["target"] == "/api/system/settings" &&
    Array(request["form"]).any? { |key, _value| key == "settings-auth-type" }
end
bazarr_current = ->(state) { state.fetch("bazarr") }
exercise_mutations(
  failures, relationship: "Bazarr connection", kind: :bazarr,
  baseline: bazarr_state, mutations: bazarr_mutations,
  write_matcher: bazarr_connection_write, projection: method(:bazarr_projection),
  desired: BAZARR, current: bazarr_current
)
exercise_stable(
  failures, relationship: "Bazarr connection", kind: :bazarr,
  state: bazarr_state, write_matcher: bazarr_connection_write,
  projection: method(:bazarr_projection), desired: BAZARR,
  current: bazarr_current,
  safe_request_body: ->(request) { canonical_bazarr_connection_body?(request, []) }
)
{
  "series mapping entry is not a pair" => ["path_mappings", ["/old"]],
  "movie mapping entry has extra fields" => [
    "path_mappings_movie", ["/old", "/new", "/extra"]
  ],
  "series mapping entry is not a sequence" => [
    "path_mappings", { "from" => "/old", "to" => "/new" }
  ],
  "movie mapping source is not a string" => ["path_mappings_movie", [7, "/new"]],
  "series mapping target is not a string" => ["path_mappings", ["/old", false]]
}.each_case(failures) do |(label, (field, entry)), failures|
  malformed_mapping_state = deep_copy(bazarr_state)
  malformed_mapping_state.dig("bazarr", "general")[field] = [entry]
  exercise_duplicate(
    failures,
    relationship: "Bazarr malformed #{label}",
    kind: :bazarr,
    state: malformed_mapping_state,
    variables: {},
    write_matcher: ->(request) { request["target"] == "/api/system/settings" }
  )
end
{
  "auth.password" => ["auth", "password"],
  "radarr.apikey" => ["radarr", "apikey"],
  "sonarr.apikey" => ["sonarr", "apikey"]
}.each_case(failures) do |(label, (section, field)), failures; old_secret, secret_state, variable|
  secret_state = deep_copy(bazarr_state)
  old_secret = "private-stale-#{section}-#{field}"
  secret_state.dig("bazarr", section)[field] = old_secret
  variable = {
    "auth.password" => "vault_arr_bazarr_admin_password",
    "radarr.apikey" => "vault_arr_radarr_api_key",
    "sonarr.apikey" => "vault_arr_sonarr_api_key"
  }.fetch(label)
  exercise_secret_change(
    failures, relationship: "Bazarr connection", kind: :bazarr,
    state: secret_state, field: label,
    variables: {}, old_variables: { variable => old_secret },
    write_matcher: bazarr_connection_write, projection: method(:bazarr_projection),
    desired: BAZARR, current: bazarr_current,
    safe_request_body: ->(request) { canonical_bazarr_connection_body?(request, []) },
    expected_fingerprint_kinds:
      (%w[radarr.apikey sonarr.apikey].include?(label) ? %i[bazarr configarr] : nil)
  )
end

language_input_state = deep_copy(bazarr_state)
language_input_state.dig("bazarr", "languages")["enabled"] = ["fr"]
exercise_secret_change(
  failures, relationship: "Bazarr connection", kind: :bazarr,
  state: language_input_state, field: "language desired input",
  variables: {}, old_variables: { "media_bazarr_languages" => ["fr"] },
  write_matcher: bazarr_connection_write, projection: method(:bazarr_projection),
  desired: BAZARR, current: bazarr_current,
  safe_request_body: ->(request) { canonical_bazarr_connection_body?(request, []) }
)

provider_state = { "bazarr" => deep_copy(BAZARR_WITH_PROVIDER) }
provider_variables = { "media_bazarr_providers" => [deep_copy(BAZARR_PROVIDER)] }
provider_mutations = {
  "provider.username" => ->(state) { state.dig("bazarr", "providers", "opensubtitlescom")["username"] = "legacy" },
  "provider.use_hash" => lambda do |state|
    state.dig("bazarr", "providers", "opensubtitlescom")["use_hash"] = false
  end,
  "provider.include_ai_translated" => lambda do |state|
    state.dig("bazarr", "providers", "opensubtitlescom")["include_ai_translated"] = true
  end,
  "provider.include_machine_translated" => lambda do |state|
    state.dig("bazarr", "providers", "opensubtitlescom")["include_machine_translated"] = true
  end
}
provider_write = lambda do |request|
  request["method"] == "POST" && request["target"] == "/api/system/settings" &&
    Array(request["form"]).any? { |key, _value| key.start_with?("settings-opensubtitlescom-") }
end
provider_projection = lambda do |settings|
  bazarr_projection(settings, [BAZARR_PROVIDER])
end
exercise_mutations(
  failures, relationship: "Bazarr provider", kind: :bazarr,
  baseline: provider_state, mutations: provider_mutations, variables: provider_variables,
  write_matcher: provider_write, projection: provider_projection,
  desired: BAZARR_WITH_PROVIDER, current: bazarr_current
)
provider_enablement_mutation = {
  "declared provider enablement" => lambda do |state|
    state.dig("bazarr", "general")["enabled_providers"] = []
  end
}
exercise_mutations(
  failures, relationship: "Bazarr provider", kind: :bazarr,
  baseline: provider_state, mutations: provider_enablement_mutation,
  variables: provider_variables, write_matcher: bazarr_connection_write,
  projection: provider_projection, desired: BAZARR_WITH_PROVIDER, current: bazarr_current
)
duplicate_provider_variables = {
  "media_bazarr_providers" => [deep_copy(BAZARR_PROVIDER), deep_copy(BAZARR_PROVIDER)]
}
exercise_duplicate(
  failures, relationship: "Bazarr provider", kind: :bazarr,
  state: provider_state, variables: duplicate_provider_variables,
  write_matcher: ->(request) { request["target"] == "/api/system/settings" }
)
exercise_stable(
  failures, relationship: "Bazarr provider", kind: :bazarr,
  state: provider_state, variables: provider_variables, write_matcher: provider_write,
  projection: provider_projection, desired: BAZARR_WITH_PROVIDER,
  current: bazarr_current,
  safe_request_body: ->(request) { canonical_bazarr_provider_body?(request) }
)
boolean_provider = deep_copy(BAZARR_PROVIDER)
boolean_provider.fetch("settings").merge!(
  "settings-opensubtitlescom-use_hash" => true,
  "settings-opensubtitlescom-include_ai_translated" => false,
  "settings-opensubtitlescom-include_machine_translated" => false
)
boolean_variables = { "media_bazarr_providers" => [boolean_provider] }
boolean_state = deep_copy(provider_state)
boolean_state.dig("bazarr", "providers", "opensubtitlescom")["use_hash"] = false

Dir.mktmpdir("media-acquisition-bazarr-boolean-boundary-") do |runtime|
  FileUtils.mkdir_p(File.join(runtime, "services", "arr"))
  with_api(boolean_state) do |api|
    variables = base_variables(api.port).merge(boolean_variables)
    seed_fingerprint_baseline(runtime, variables, kind: :bazarr, state: boolean_state)
    first = run_tasks(
      :bazarr, api, boolean_variables,
      runtime: runtime, prepare_fingerprints: false
    )
    sane = check_sanity(
      failures, "Bazarr actual boolean provider declaration", first, api, kind: :bazarr
    )
    if sane
      failures << "Bazarr actual boolean provider declaration did not converge" unless
        first.fetch("status").success?
      writes = mutation_requests(api, provider_write)
      failures << "Bazarr actual boolean provider declaration did not write exactly once" unless
        writes.length == 1
      expected_values = {
        "settings-opensubtitlescom-use_hash" => "true",
        "settings-opensubtitlescom-include_ai_translated" => "false",
        "settings-opensubtitlescom-include_machine_translated" => "false"
      }
      submitted = Array(writes.first&.fetch("form", nil)).to_h
      failures << "Bazarr actual boolean provider declaration was not serialized canonically" unless
        submitted.slice(*expected_values.keys) == expected_values
      after_first = fingerprint_snapshot(runtime)
      failures << "Bazarr actual boolean provider declaration did not record fingerprints" unless
        first.fetch("recorder_started")
      failures << "Bazarr actual boolean provider declaration did not apply true" unless
        api.state.dig("bazarr", "providers", "opensubtitlescom", "use_hash") == true

      request_count = api.requests.length
      second = run_tasks(
        :bazarr, api, boolean_variables,
        runtime: runtime, prepare_fingerprints: false
      )
      sane = check_sanity(
        failures, "Bazarr stable actual boolean provider declaration",
        second, api, kind: :bazarr
      )
      if sane
        second_mutations = api.requests.drop(request_count).select do |request|
          %w[POST PUT PATCH DELETE].include?(request.fetch("method"))
        end
        failures << "Bazarr stable actual boolean provider declaration mutated again" unless
          second_mutations.empty?
        failures << "Bazarr stable actual boolean provider declaration reported changed" unless
          second.fetch("reconciliation_changed") == 0
        failures << "Bazarr stable actual boolean provider declaration rewrote fingerprints" unless
          fingerprint_snapshot(runtime) == after_first
      end
    end
  end
end
provider_secret_state = deep_copy(provider_state)
provider_secret_state.dig("bazarr", "providers", "opensubtitlescom")["password"] = "private-stale-provider-secret"
old_provider = deep_copy(BAZARR_PROVIDER)
old_provider.fetch("settings")["settings-opensubtitlescom-password"] = "private-stale-provider-secret"
exercise_secret_change(
  failures, relationship: "Bazarr provider", kind: :bazarr,
  state: provider_secret_state, field: "provider.password",
  variables: provider_variables,
  old_variables: { "media_bazarr_providers" => [old_provider] },
  write_matcher: ->(request) { request["target"] == "/api/system/settings" },
  projection: provider_projection,
  desired: BAZARR_WITH_PROVIDER, current: bazarr_current,
  expected_writes: 2, expected_changed: 2,
  write_set_validator: lambda do |requests|
    canonical_bazarr_complete_write_set?(requests, [BAZARR_PROVIDER])
  end
)
exercise_secret_change(
  failures, relationship: "Bazarr masked provider compatibility", kind: :bazarr,
  state: provider_secret_state, field: "provider.password",
  variables: provider_variables,
  old_variables: { "media_bazarr_providers" => [old_provider] },
  write_matcher: ->(request) { request["target"] == "/api/system/settings" },
  projection: provider_projection,
  desired: BAZARR_WITH_PROVIDER, current: bazarr_current,
  expected_writes: 2, expected_changed: 2,
  write_set_validator: lambda do |requests|
    canonical_bazarr_complete_write_set?(requests, [BAZARR_PROVIDER])
  end,
  api_options: { mask_bazarr_provider_secrets: true }
)
unmanaged_provider_state = deep_copy(provider_state)
unmanaged_provider_state.dig("bazarr", "general", "enabled_providers") << "unmanaged-provider"
unmanaged_provider_state.dig("bazarr", "providers")["unmanaged-provider"] = {
  "username" => "unmanaged-user", "unmanaged_option" => "preserve-unmanaged-provider"
}
unmanaged_provider_state.dig("bazarr", "providers", BAZARR_PROVIDER.fetch("name"))[
  "unmanaged_option"
] = "preserve-declared-provider-extra"
exercise_stable(
  failures, relationship: "Bazarr declared provider with unmanaged state", kind: :bazarr,
  state: unmanaged_provider_state, variables: provider_variables,
  write_matcher: ->(request) { request["target"] == "/api/system/settings" },
  projection: provider_projection,
  desired: BAZARR_WITH_PROVIDER, current: bazarr_current,
  preserved: lambda do |state, _before|
    settings = state.fetch("bazarr")
    settings.dig("providers", "unmanaged-provider") == {
      "username" => "unmanaged-user", "unmanaged_option" => "preserve-unmanaged-provider"
    } &&
      settings.dig("providers", BAZARR_PROVIDER.fetch("name"), "unmanaged_option") ==
        "preserve-declared-provider-extra" &&
      settings.dig("general", "enabled_providers").include?("unmanaged-provider")
  end
)
exercise_mutations(
  failures, relationship: "Bazarr declared provider with unmanaged state", kind: :bazarr,
  baseline: unmanaged_provider_state,
  mutations: {
    "declared readable setting" => lambda do |state|
      state.dig("bazarr", "providers", BAZARR_PROVIDER.fetch("name"))["username"] = "legacy"
    end
  },
  variables: provider_variables, write_matcher: provider_write,
  projection: provider_projection, desired: BAZARR_WITH_PROVIDER, current: bazarr_current,
  preserved: lambda do |state, _before|
    settings = state.fetch("bazarr")
    settings.dig("providers", "unmanaged-provider") == {
      "username" => "unmanaged-user", "unmanaged_option" => "preserve-unmanaged-provider"
    } &&
      settings.dig("providers", BAZARR_PROVIDER.fetch("name"), "unmanaged_option") ==
        "preserve-declared-provider-extra" &&
      settings.dig("general", "enabled_providers").include?("unmanaged-provider")
  end
)
exercise_mutations(
  failures, relationship: "Bazarr declared provider enablement with unmanaged state", kind: :bazarr,
  baseline: unmanaged_provider_state,
  mutations: {
    "declared enablement" => lambda do |state|
      state.dig("bazarr", "general", "enabled_providers").delete(BAZARR_PROVIDER.fetch("name"))
    end
  },
  variables: provider_variables, write_matcher: bazarr_connection_write,
  projection: provider_projection, desired: BAZARR_WITH_PROVIDER, current: bazarr_current,
  preserved: lambda do |state, _before|
    state.dig("bazarr", "general", "enabled_providers").include?("unmanaged-provider") &&
      state.dig("bazarr", "providers", "unmanaged-provider", "unmanaged_option") ==
        "preserve-unmanaged-provider"
  end
)

typed_provider_settings = deep_copy(BAZARR)
typed_provider_settings.dig("general", "enabled_providers") << "animetosho"
typed_provider_settings.fetch("providers")["animetosho"] = {
  "search_threshold" => 6, "exclude" => []
}
typed_provider_state = { "bazarr" => typed_provider_settings }
typed_provider_variables = {
  "media_bazarr_providers" => [deep_copy(BAZARR_TYPED_PROVIDER)]
}
typed_provider_write = lambda do |request|
  request["method"] == "POST" && request["target"] == "/api/system/settings" &&
    Array(request["form"]).any? { |key, _value| key.start_with?("settings-animetosho-") }
end
exercise_mutations(
  failures, relationship: "Bazarr typed provider", kind: :bazarr,
  baseline: typed_provider_state,
  mutations: {
    "numeric string canonicalization" => lambda do |state|
      state.dig("bazarr", "providers", "animetosho")["search_threshold"] = 7
    end,
    "empty array sentinel" => lambda do |state|
      state.dig("bazarr", "providers", "animetosho")["exclude"] = ["legacy"]
    end
  },
  variables: typed_provider_variables, write_matcher: typed_provider_write,
  projection: lambda { |settings| bazarr_projection(settings, [BAZARR_TYPED_PROVIDER]) },
  desired: typed_provider_settings, current: bazarr_current
)
exercise_stable(
  failures, relationship: "Bazarr typed provider", kind: :bazarr,
  state: typed_provider_state, variables: typed_provider_variables,
  write_matcher: typed_provider_write,
  projection: lambda { |settings| bazarr_projection(settings, [BAZARR_TYPED_PROVIDER]) },
  desired: typed_provider_settings, current: bazarr_current
)
exercise_duplicate(
  failures, relationship: "Bazarr language declaration", kind: :bazarr,
  state: bazarr_state, variables: { "media_bazarr_languages" => %w[en en] },
  write_matcher: ->(request) { request["target"] == "/api/system/settings" }
)
{
  "missing auth password" => lambda do |state|
    state.dig("bazarr", "auth").delete("password")
  end,
  "non-string Radarr host" => lambda do |state|
    state.dig("bazarr", "radarr")["ip"] = 1
  end,
  "non-integer Radarr port" => lambda do |state|
    state.dig("bazarr", "radarr")["port"] = "7878"
  end,
  "non-boolean Sonarr SSL" => lambda do |state|
    state.dig("bazarr", "sonarr")["ssl"] = "false"
  end
}.each_case(failures) do |(label, mutate), failures|
  invalid_state = deep_copy(bazarr_state)
  mutate.call(invalid_state)
  exercise_duplicate(
    failures, relationship: "Bazarr invalid current #{label}", kind: :bazarr,
    state: invalid_state, variables: {},
    write_matcher: ->(request) { request["target"] == "/api/system/settings" }
  )
end
{
  "language mapping" => { "media_bazarr_languages" => { "en" => true } },
  "language scalar" => { "media_bazarr_languages" => "en" },
  "language non-string" => { "media_bazarr_languages" => ["en", 1] },
  "language non-canonical" => { "media_bazarr_languages" => ["EN"] },
  "provider mapping" => { "media_bazarr_providers" => { "name" => "opensubtitlescom" } },
  "provider non-mapping" => { "media_bazarr_providers" => ["opensubtitlescom"] },
  "provider empty name" => {
    "media_bazarr_providers" => [{ "name" => "", "settings" => {} }]
  },
  "provider empty settings" => {
    "media_bazarr_providers" => [{ "name" => "opensubtitlescom", "settings" => {} }]
  },
  "provider wrong setting prefix" => {
    "media_bazarr_providers" => [{
      "name" => "opensubtitlescom",
      "settings" => { "settings-other-password" => "unsafe" }
    }]
  },
  "provider empty setting suffix" => {
    "media_bazarr_providers" => [{
      "name" => "opensubtitlescom",
      "settings" => { "settings-opensubtitlescom-" => "unsafe" }
    }]
  },
  "provider ambiguous hyphenated name" => {
    "media_bazarr_providers" => [{
      "name" => "open-subtitles",
      "settings" => { "settings-open-subtitles-password" => "unsafe" }
    }]
  },
  "provider ambiguous hyphenated setting suffix" => {
    "media_bazarr_providers" => [{
      "name" => "opensubtitlescom",
      "settings" => { "settings-opensubtitlescom-api-key" => "unsafe" }
    }]
  },
  "provider unsafe setting mapping" => {
    "media_bazarr_providers" => [{
      "name" => "opensubtitlescom",
      "settings" => { "settings-opensubtitlescom-password" => { "unsafe" => true } }
    }]
  },
  "provider unsafe nested list" => {
    "media_bazarr_providers" => [{
      "name" => "opensubtitlescom",
      "settings" => { "settings-opensubtitlescom-options" => [["unsafe"]] }
    }]
  }
}.each_case(failures) do |(label, variables), failures|
  exercise_duplicate(
    failures, relationship: "Bazarr invalid #{label}", kind: :bazarr,
    state: provider_state, variables: variables,
    write_matcher: ->(request) { request["target"] == "/api/system/settings" }
  )
end

abort failures.join("\n") unless failures.empty?
puts "media acquisition reconciliation (bazarr) behavior holds"
