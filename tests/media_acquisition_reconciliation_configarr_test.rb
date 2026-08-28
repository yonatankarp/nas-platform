#!/usr/bin/env ruby
# frozen_string_literal: true

# Reconciliation behaviour for Configarr profiles and quality definitions.
# Shared fixtures live in media_acquisition_reconciliation_support.rb.

require_relative "media_acquisition_reconciliation_support"

failures = []

# The core file's dedicated production probe establishes the fingerprint
# algorithm for this gate run; if it regresses, that file fails. This file can
# therefore seed equivalent private baselines instead of running another setup
# playbook before every scenario, exactly as the single-file fixture did once
# the probe had passed.
FINGERPRINT_BASELINE_CACHE["enabled"] = true

configarr_state = { "configarr" => deep_copy(CONFIGARR), "configarr_desired" => deep_copy(CONFIGARR) }
%w[radarr sonarr].each_case(failures) do |service, failures; before, result, sane, variables|
  colliding_profile_tree_state = deep_copy(configarr_state)
  colliding_definition = colliding_profile_tree_state.dig(
    "configarr", service, "qualitydefinition"
  ).find { |definition| definition.dig("quality", "name") == "WEBDL-1080p" }
  colliding_definition.fetch("quality")["id"] = 1001
  colliding_profile_tree_state.dig(
    "configarr", service, "qualityprofile", 0
  )["minFormatScore"] = 99

  other_service = service == "radarr" ? "sonarr" : "radarr"
  colliding_profile_tree_state.dig("configarr", other_service, "customformat").reject! do |format|
    format["name"] == CONFIGARR_FORMAT_NAME
  end
  colliding_profile_tree_state.dig(
    "configarr", other_service, "qualityprofile", 0, "formatItems"
  ).reject! { |assignment| assignment["name"] == CONFIGARR_FORMAT_NAME }

  Dir.mktmpdir("media-acquisition-configarr-profile-tree-id-") do |runtime|
    FileUtils.mkdir_p(File.join(runtime, "services", "arr"))
    with_api(colliding_profile_tree_state) do |api|
      variables = base_variables(api.port)
      seed_fingerprint_baseline(
        runtime, variables, kind: :configarr, state: configarr_state
      )
      File.unlink(File.join(runtime, "services", "arr", CONFIGARR_OPAQUE_FINGERPRINT_FILE))
      before = fingerprint_snapshot(runtime)
      result = run_tasks(
        :configarr, api, {}, runtime: runtime, prepare_fingerprints: false
      )
      sane = check_sanity(
        failures,
        "Configarr #{service} recursive profile-tree numeric identity",
        result,
        api,
        kind: :configarr
      )
      next unless sane

      failures << "Configarr #{service} recursive profile-tree numeric identity was accepted" if
        result.fetch("status").success?
      failures << "Configarr #{service} recursive profile-tree numeric identity reached mutation" unless
        mutation_requests(api, ->(_request) { true }).empty?
      failures << "Configarr #{service} recursive profile-tree numeric identity reached fingerprint recording" if
        result.fetch("recorder_started")
      failures << "Configarr #{service} recursive profile-tree numeric identity advanced a fingerprint" unless
        fingerprint_snapshot(runtime) == before
    end
  end
end
[
  ["radarr", "string", "corrupt"],
  ["sonarr", "boolean", true],
  ["radarr", "list", []],
  ["sonarr", "number", 7]
].each_case(failures) do |(service, label, invalid_quality), failures; before, other_service, result, sane, variables|
  malformed_quality_state = deep_copy(configarr_state)
  profile_group = malformed_quality_state.dig(
    "configarr", service, "qualityprofile", 0, "items"
  ).find { |item| item["name"] == "WEB 1080p" }
  profile_group["quality"] = invalid_quality
  other_service = service == "radarr" ? "sonarr" : "radarr"
  malformed_quality_state.dig(
    "configarr", other_service, "customformat"
  ).reject! { |format| format["name"] == CONFIGARR_FORMAT_NAME }

  Dir.mktmpdir("media-acquisition-configarr-quality-discriminator-") do |runtime|
    FileUtils.mkdir_p(File.join(runtime, "services", "arr"))
    with_api(malformed_quality_state) do |api|
      variables = base_variables(api.port)
      seed_fingerprint_baseline(
        runtime, variables, kind: :configarr, state: configarr_state
      )
      before = fingerprint_snapshot(runtime)
      result = run_tasks(
        :configarr, api, {}, runtime: runtime, prepare_fingerprints: false
      )
      sane = check_sanity(
        failures, "Configarr #{service} non-mapping quality #{label}",
        result, api, kind: :configarr
      )
      next unless sane

      failures << "Configarr #{service} non-mapping quality #{label} was accepted" if
        result.fetch("status").success?
      failures << "Configarr #{service} non-mapping quality #{label} reached mutation" unless
        mutation_requests(api, ->(_request) { true }).empty?
      failures << "Configarr #{service} non-mapping quality #{label} reached fingerprint recording" if
        result.fetch("recorder_started")
      failures << "Configarr #{service} non-mapping quality #{label} advanced a fingerprint" unless
        fingerprint_snapshot(runtime) == before
    end
  end
end
if API_BOUNDARY_TARGETED_ONLY
  abort failures.join("\n") unless failures.empty?
  puts "acquisition API boundary behavior holds"
  exit
end
if PROFILE_TREE_ID_TARGETED_ONLY
  abort failures.join("\n") unless failures.empty?
  puts "Configarr recursive profile-tree identity preflight behavior holds"
  exit
end
configarr_mutations = {}
%w[radarr sonarr].each do |service|
  service_name = service.dup
  profile_mutations = {
    "name" => ->(profile) { profile["name"] = "Legacy Profile" },
    "upgradeAllowed" => ->(profile) { profile["upgradeAllowed"] = true },
    "cutoff" => ->(profile) { profile["cutoff"] = 9 },
    "minFormatScore" => ->(profile) { profile["minFormatScore"] = 100 },
    "cutoffFormatScore" => ->(profile) { profile["cutoffFormatScore"] = 100 },
    "minUpgradeFormatScore" => ->(profile) { profile["minUpgradeFormatScore"] = 100 },
    "reset unmatched scores outcome" => ->(profile) { profile["formatItems"].last["score"] = 99 },
    "quality sort/order outcome" => ->(profile) { profile["items"].reverse! },
    "quality structure" => lambda do |profile|
      profile.fetch("items").find { |item| item["name"] == "WEB 1080p" }.fetch("items").pop
    end,
    "non-cutoff nested item id" => lambda do |profile|
      profile.fetch("items").find { |item| item["name"] == "WEB 1080p" }
        .fetch("items").find { |item| item.dig("quality", "name") == "WEBDL-1080p" }
        .fetch("quality")["id"] = 999
    end,
    "format assignment name" => ->(profile) { profile["formatItems"].first["name"] = "Legacy Format" },
    "format assignment score" => ->(profile) { profile["formatItems"].first["score"] = 0 }
  }
  profile_mutations.each do |field, mutate_profile|
    configarr_mutations["#{service_name}.quality_profile.#{field}"] = lambda do |state|
      mutate_profile.call(state.dig("configarr", service_name, "qualityprofile").first)
    end
  end
  [
    ["HDTV-1080p", 0], ["Raw-HD", 1], ["Bluray-1080p", 3],
    ["WEB 1080p", 2], ["WEBRip-1080p", 2, 0], ["WEBDL-1080p", 2, 1]
  ].each do |quality_name, item_index, child_index|
    configarr_mutations["#{service_name}.quality_profile.#{quality_name}.name"] = lambda do |state|
      item = state.dig("configarr", service_name, "qualityprofile").first.fetch("items")[item_index]
      item = item.fetch("items")[child_index] unless child_index.nil?
      if item["quality"].is_a?(Hash)
        item.fetch("quality")["name"] = "Legacy Quality"
      else
        item["name"] = "Legacy Quality Group"
      end
    end
    configarr_mutations["#{service_name}.quality_profile.#{quality_name}.allowed"] = lambda do |state|
      item = state.dig("configarr", service_name, "qualityprofile").first.fetch("items")[item_index]
      item = item.fetch("items")[child_index] unless child_index.nil?
      item["allowed"] = !item.fetch("allowed")
    end
  end

  CONFIGARR.dig(service_name, "qualitydefinition").each_with_index do |definition, index|
    quality_name = definition.dig("quality", "name")
    # Configarr v1.28.0 only applies the three numeric TRaSH leaves in this
    # bundled configuration. Identity metadata, title and weight are retained
    # in the verified state hash and fail closed if they drift.
    definition_mutations = if QUALITY_SIZES.fetch(service_name).key?(quality_name)
      {
      "minSize" => ->(item) { item["minSize"] = item["minSize"].nil? ? 1 : item["minSize"] + 1 },
      "preferredSize" => lambda do |item|
        item["preferredSize"] = item["preferredSize"].nil? ? 1 : item["preferredSize"] + 1
      end,
      "maxSize" => ->(item) { item["maxSize"] = item["maxSize"].nil? ? 1 : item["maxSize"] + 1 }
      }
    else
      {}
    end
    definition_mutations.each do |field, mutate_definition|
      label = "#{service_name}.quality_definition.#{quality_name}.#{field}"
      configarr_mutations[label] = lambda do |state|
        item = state.dig("configarr", service_name, "qualitydefinition").fetch(index)
        mutate_definition.call(item)
      end
    end
  end

  {
    "name" => ->(format) { format["name"] = "Legacy Format" },
    "includeWhenRenaming" => ->(format) { format["includeCustomFormatWhenRenaming"] = true },
    "specification.name" => ->(format) { format.dig("specifications", 0)["name"] = "Legacy" },
    "specification.implementation" => lambda do |format|
      format.dig("specifications", 0)["implementation"] = "LegacySpecification"
    end,
    "specification.negate" => ->(format) { format.dig("specifications", 0)["negate"] = true },
    "specification.required" => ->(format) { format.dig("specifications", 0)["required"] = true },
    "specification.regex" => lambda do |format|
      format.dig("specifications", 0, "fields", 0)["value"] = "legacy-regex"
    end
  }.each do |field, mutate_format|
    configarr_mutations["#{service_name}.custom_format.#{field}"] = lambda do |state|
      mutate_format.call(state.dig("configarr", service_name, "customformat").first)
    end
  end
end
{
  "radarr.naming.renameMovies" => ["radarr", "renameMovies", true],
  "radarr.naming.standardMovieFormat" => ["radarr", "standardMovieFormat", "Legacy"],
  "radarr.naming.movieFolderFormat" => ["radarr", "movieFolderFormat", "Legacy"],
  "sonarr.naming.renameEpisodes" => ["sonarr", "renameEpisodes", true],
  "sonarr.naming.standardEpisodeFormat" => ["sonarr", "standardEpisodeFormat", "Legacy"],
  "sonarr.naming.dailyEpisodeFormat" => ["sonarr", "dailyEpisodeFormat", "Legacy"],
  "sonarr.naming.animeEpisodeFormat" => ["sonarr", "animeEpisodeFormat", "Legacy"],
  "sonarr.naming.seriesFolderFormat" => ["sonarr", "seriesFolderFormat", "Legacy"],
  "sonarr.naming.seasonFolderFormat" => ["sonarr", "seasonFolderFormat", "Legacy"]
}.each do |label, (service, field, value)|
  configarr_mutations[label] = lambda do |state|
    state.dig("configarr", service, "config/naming")[field] = value
  end
end
{
  "radarr.naming.nullable standard format" => ["radarr", "standardMovieFormat"],
  "sonarr.naming.nullable daily format" => ["sonarr", "dailyEpisodeFormat"]
}.each do |label, (service, field)|
  configarr_mutations[label] = lambda do |state|
    state.dig("configarr", service, "config/naming")[field] = nil
  end
end
configarr_write = lambda do |request|
  request["method"] == "POST" && request["target"] == "/_fixture/configarr/apply"
end
configarr_any_write = ->(_request) { true }
configarr_current = ->(state) { state.fetch("configarr") }
configarr_unmanaged_preserved = lambda do |state, before|
  %w[radarr sonarr].all? do |service|
    current = state.dig("configarr", service)
    previous = before.dig("configarr", service)
    previous_profile = previous.fetch("qualityprofile").find do |item|
      item["name"] == CONFIGARR_PROFILE_NAME
    end
    current_profile = current.fetch("qualityprofile").find do |item|
      item["name"] == CONFIGARR_PROFILE_NAME
    end
    unrelated_profile_fields_preserved = previous_profile.nil? ||
      %w[unmanagedProfileField language].all? do |field|
        !previous_profile.key?(field) || current_profile&.fetch(field, nil) == previous_profile[field]
      end

    previous.fetch("qualityprofile")
      .reject { |item| item["name"] == CONFIGARR_PROFILE_NAME }
      .all? { |item| current.fetch("qualityprofile").include?(item) } &&
      previous.fetch("customformat")
        .reject { |item| item["name"] == CONFIGARR_FORMAT_NAME }
        .all? { |item| current.fetch("customformat").include?(item) } &&
      unrelated_profile_fields_preserved
  end
end
if COMPLETE_PROFILE_TREE_TARGETED_ONLY
  %w[radarr sonarr].each do |service|
    id_drift_state = deep_copy(configarr_state)
    profile = id_drift_state.dig("configarr", service, "qualityprofile").first
    profile.fetch("items").find { |item| item["name"] == "WEB 1080p" }
      .fetch("items").find { |item| item.dig("quality", "name") == "WEBDL-1080p" }
      .fetch("quality")["id"] = 999

    Dir.mktmpdir("media-acquisition-configarr-complete-profile-tree-") do |runtime|
      FileUtils.mkdir_p(File.join(runtime, "services", "arr"))
      with_api(id_drift_state) do |api|
        variables = base_variables(api.port)
        seed_fingerprint_baseline(
          runtime, variables, kind: :configarr, state: configarr_state
        )
        before = fingerprint_snapshot(runtime)
        first = run_tasks(
          :configarr, api, {}, runtime: runtime, prepare_fingerprints: false
        )
        sane = check_sanity(
          failures, "Configarr #{service} non-cutoff profile-tree ID drift",
          first, api, kind: :configarr
        )
        next unless sane

        failures << "Configarr #{service} non-cutoff profile-tree ID drift did not converge" unless
          first.fetch("status").success?
        profile_puts = mutation_requests(
          api,
          ->(request) do
            request["method"] == "PUT" &&
              request["target"].start_with?("/#{service}/api/v3/qualityprofile/")
          end
        )
        failures << "Configarr #{service} non-cutoff profile-tree ID drift was not repaired exactly once" unless
          profile_puts.length == 1
        jobs = mutation_requests(api, configarr_write)
        failures << "Configarr #{service} non-cutoff profile-tree ID drift did not run Configarr exactly once" unless
          jobs.length == 1
        after_first = fingerprint_snapshot(runtime)
        failures << "Configarr #{service} non-cutoff profile-tree ID drift changed desired input bytes" unless
          before.fetch(FINGERPRINT_FILE_BY_KIND.fetch(:configarr)) ==
            after_first.fetch(FINGERPRINT_FILE_BY_KIND.fetch(:configarr))
        failures << "Configarr #{service} non-cutoff profile-tree ID drift changed opaque continuity" unless
          before.fetch(CONFIGARR_OPAQUE_FINGERPRINT_FILE) ==
            after_first.fetch(CONFIGARR_OPAQUE_FINGERPRINT_FILE)
        failures << "Configarr #{service} non-cutoff profile-tree repair recorded stale full state" unless
          after_first.fetch(CONFIGARR_STATE_FINGERPRINT_FILE)&.fetch("content", nil) ==
            "#{configarr_state_fingerprint(api.state.fetch('configarr'))}\n"

        request_count = api.requests.length
        second = run_tasks(
          :configarr, api, {}, runtime: runtime, prepare_fingerprints: false
        )
        sane = check_sanity(
          failures, "Configarr #{service} stable repaired profile-tree IDs",
          second, api, kind: :configarr
        )
        next unless sane

        second_mutations = api.requests.drop(request_count).select do |request|
          %w[POST PUT PATCH DELETE].include?(request.fetch("method"))
        end
        failures << "Configarr #{service} stable repaired profile-tree IDs mutated again" unless
          second_mutations.empty?
        failures << "Configarr #{service} stable repaired profile-tree IDs reported changed" unless
          second.fetch("reconciliation_changed") == 0
        failures << "Configarr #{service} stable repaired profile-tree IDs rewrote fingerprints" unless
          fingerprint_snapshot(runtime) == after_first
      end
    end
  end

  invalid_profile_trees = {
    "zero ID" => lambda do |profile|
      profile.fetch("items").first.fetch("quality")["id"] = 0
    end,
    "negative ID" => lambda do |profile|
      profile.fetch("items").first.fetch("quality")["id"] = -1
    end,
    "boolean ID" => lambda do |profile|
      profile.fetch("items").first.fetch("quality")["id"] = true
    end,
    "string ID" => lambda do |profile|
      profile.fetch("items").first.fetch("quality")["id"] = "4"
    end,
    "over-depth tree" => lambda do |profile|
      leaf = {
        "quality" => { "id" => 3, "name" => "WEBDL-1080p" },
        "allowed" => true, "items" => []
      }
      16.downto(1) do |depth|
        leaf = {
          "id" => 2000 + depth, "name" => "level-#{depth}",
          "allowed" => true, "items" => [leaf]
        }
      end
      profile["items"] = [leaf]
      profile["cutoff"] = 3
    end,
    "over-count tree" => lambda do |profile|
      profile["items"] = 513.times.map do |index|
        {
          "quality" => { "id" => 3000 + index, "name" => "quality-#{index}" },
          "allowed" => true, "items" => []
        }
      end
      profile["cutoff"] = 3000
    end
  }
  invalid_profile_trees.each_case(failures) do |(label, mutate), failures; before, invalid_state, result, sane, variables|
    invalid_state = deep_copy(configarr_state)
    mutate.call(invalid_state.dig("configarr", "radarr", "qualityprofile").first)
    invalid_state.dig("configarr", "sonarr", "customformat").reject! do |format|
      format["name"] == CONFIGARR_FORMAT_NAME
    end

    Dir.mktmpdir("media-acquisition-configarr-invalid-profile-tree-") do |runtime|
      FileUtils.mkdir_p(File.join(runtime, "services", "arr"))
      with_api(invalid_state) do |api|
        variables = base_variables(api.port)
        seed_fingerprint_baseline(
          runtime, variables, kind: :configarr, state: configarr_state
        )
        before = fingerprint_snapshot(runtime)
        result = run_tasks(
          :configarr, api, {}, runtime: runtime, prepare_fingerprints: false
        )
        sane = check_sanity(
          failures, "Configarr invalid #{label}", result, api, kind: :configarr
        )
        next unless sane

        failures << "Configarr invalid #{label} was accepted" if
          result.fetch("status").success?
        failures << "Configarr invalid #{label} reached mutation" unless
          mutation_requests(api, ->(_request) { true }).empty?
        failures << "Configarr invalid #{label} reached fingerprint recording" if
          result.fetch("recorder_started")
        failures << "Configarr invalid #{label} advanced a fingerprint" unless
          fingerprint_snapshot(runtime) == before
      end
    end
  end

  abort failures.join("\n") unless failures.empty?
  puts "complete Configarr profile-tree identity behavior holds"
  exit
end
%w[radarr sonarr].each do |service|
  configarr_mutations["#{service}.missing quality profile among unrelated profiles"] = lambda do |state|
    state.dig("configarr", service, "qualityprofile").reject! do |profile|
      profile["name"] == CONFIGARR_PROFILE_NAME
    end
  end
  configarr_mutations["#{service}.missing custom format among unrelated formats"] = lambda do |state|
    state.dig("configarr", service, "customformat").reject! do |format|
      format["name"] == CONFIGARR_FORMAT_NAME
    end
  end
  configarr_mutations["#{service}.missing format assignment among unrelated assignments"] = lambda do |state|
    profile = state.dig("configarr", service, "qualityprofile").find do |candidate|
      candidate["name"] == CONFIGARR_PROFILE_NAME
    end
    profile.fetch("formatItems").reject! { |item| item["name"] == CONFIGARR_FORMAT_NAME }
  end
  configarr_mutations["#{service}.empty format-score assignments"] = lambda do |state|
    profile = state.dig("configarr", service, "qualityprofile").find do |candidate|
      candidate["name"] == CONFIGARR_PROFILE_NAME
    end
    profile["formatItems"] = []
  end
end
if CONFIGARR_MUTATION_PATTERN
  selector = Regexp.new(CONFIGARR_MUTATION_PATTERN)
  configarr_mutations.select! { |field, _mutation| field.match?(selector) }
  abort "Configarr mutation selector matched no scenarios" if configarr_mutations.empty?
end
exercise_mutations(
  failures, relationship: "Configarr", kind: :configarr,
  baseline: configarr_state, mutations: configarr_mutations,
  write_matcher: configarr_write, projection: method(:configarr_projection),
  desired: CONFIGARR, current: configarr_current,
  preserved: configarr_unmanaged_preserved
)
if CONFIGARR_MUTATION_PATTERN
  abort failures.join("\n") unless failures.empty?
  puts "selected Configarr mutation reconciliation behavior holds"
  exit
end

# Configarr cannot restore server-owned qdef identity metadata, weight, title,
# or values for definitions absent from the pinned TRaSH input. An independent
# continuity hash must reject that drift before any mutation, even if a desired
# input changed or the broader owned-state hash is absent.
context_state = deep_copy(configarr_state)
%w[radarr sonarr].each do |service|
  definition = context_state.dig("configarr", service, "qualitydefinition").find do |item|
    item.dig("quality", "name") == "Raw-HD"
  end
  definition["id"] += 100
  definition.fetch("quality")["id"] += 100
  definition.fetch("quality")["source"] = "legacy"
  definition.fetch("quality")["resolution"] = 720
  definition.fetch("quality")["modifier"] = "legacy" if service == "radarr"
  definition["title"] = "Legacy Raw-HD"
  definition["weight"] += 100
  definition["minSize"] = 1
  definition["preferredSize"] = 2
  definition["maxSize"] = 3
end
{
  "existing opaque continuity" => {},
  "desired input transition plus opaque drift" => {
    "vault_arr_radarr_api_key" => "private-stale-radarr-apikey",
    "vault_arr_sonarr_api_key" => "private-stale-sonarr-apikey"
  },
  "missing full state plus opaque drift" => :remove_full_state
}.each_case(failures) do |(label, seed_input), failures; before, fingerprint_variables, result, sane, variables|
  Dir.mktmpdir("media-acquisition-configarr-context-") do |runtime|
    FileUtils.mkdir_p(File.join(runtime, "services", "arr"))
    with_api(deep_copy(context_state)) do |api|
      variables = base_variables(api.port)
      fingerprint_variables = deep_copy(variables)
      fingerprint_variables.merge!(seed_input) if seed_input.is_a?(Hash)
      seed_fingerprint_baseline(
        runtime, fingerprint_variables, kind: :configarr, state: context_state
      )
      if seed_input == :remove_full_state
        File.unlink(File.join(runtime, "services", "arr", CONFIGARR_STATE_FINGERPRINT_FILE))
      end
      before = fingerprint_snapshot(runtime)
      result = run_tasks(
        :configarr, api, {}, runtime: runtime, prepare_fingerprints: false
      )
      sane = check_sanity(
        failures, "Configarr #{label}", result, api,
        kind: :configarr
      )
      next unless sane

      failures << "Configarr #{label} accepted non-repairable qdef context drift" if
        result.fetch("status").success?
      failures << "Configarr #{label} reached a mutation" unless
        mutation_requests(api, configarr_any_write).empty?
      failures << "Configarr #{label} advanced a reconciliation hash" unless
        fingerprint_snapshot(runtime) == before
      failures << "Configarr #{label} reached fingerprint recording" if
        result.fetch("recorder_started")
    end
  end
end

{
  "clean first opaque baseline" => nil,
  "repairable source qdef drift before first opaque baseline" => lambda do |state|
    state.dig("configarr", "radarr", "qualitydefinition").first["minSize"] += 1
  end
}.each_case(failures) do |(label, mutate), failures; result, sane, variables|
  baseline_state = deep_copy(configarr_state)
  mutate&.call(baseline_state)
  Dir.mktmpdir("media-acquisition-configarr-first-opaque-") do |runtime|
    FileUtils.mkdir_p(File.join(runtime, "services", "arr"))
    with_api(baseline_state) do |api|
      variables = base_variables(api.port)
      seed_fingerprint_baseline(runtime, variables, kind: :configarr, state: baseline_state)
      File.unlink(File.join(runtime, "services", "arr", CONFIGARR_OPAQUE_FINGERPRINT_FILE))
      result = run_tasks(
        :configarr, api, {}, runtime: runtime, prepare_fingerprints: false
      )
      sane = check_sanity(failures, "Configarr #{label}", result, api, kind: :configarr)
      next unless sane

      failures << "Configarr #{label} failed" unless result.fetch("status").success?
      failures << "Configarr #{label} did not run exactly one job" unless
        mutation_requests(api, configarr_write).length == 1
      failures << "Configarr #{label} did not converge" unless
        configarr_projection(api.state.fetch("configarr")) == configarr_projection(CONFIGARR)
      # A snapshot stores nil for a file that does not exist, so fetch's default
      # never applies and an absent fingerprint crashed the case instead of
      # reporting it.
      opaque_file = result.fetch("fingerprints")[CONFIGARR_OPAQUE_FINGERPRINT_FILE] || {}
      failures << "Configarr #{label} did not record opaque continuity" unless
        opaque_file["content"] == "#{configarr_opaque_fingerprint(CONFIGARR)}\n"
    end
  end
end

exercise_stable(
  failures, relationship: "Configarr", kind: :configarr,
  state: configarr_state, write_matcher: configarr_any_write,
  projection: method(:configarr_projection), desired: CONFIGARR,
  current: configarr_current, preserved: configarr_unmanaged_preserved
)
reordered_definition_state = deep_copy(configarr_state)
%w[radarr sonarr].each do |service|
  reordered_definition_state.dig("configarr", service, "qualitydefinition").reverse!
end
exercise_stable(
  failures, relationship: "Configarr quality-definition API ordering", kind: :configarr,
  state: reordered_definition_state, write_matcher: configarr_any_write,
  projection: method(:configarr_projection), desired: CONFIGARR,
  current: configarr_current
)
configarr_secret_variables = {}
exercise_secret_change(
  failures, relationship: "Configarr", kind: :configarr,
  state: configarr_state, field: "API key input fingerprint",
  variables: configarr_secret_variables,
  old_variables: {
    "vault_arr_radarr_api_key" => "private-stale-radarr-apikey",
    "vault_arr_sonarr_api_key" => "private-stale-sonarr-apikey"
  }, write_matcher: configarr_any_write,
  projection: method(:configarr_projection), desired: CONFIGARR, current: configarr_current,
  expected_fingerprint_kinds: %i[configarr bazarr]
)
%w[radarr sonarr].each do |service|
  {
    "quality profile" => ["qualityprofile", 900],
    "custom format" => ["customformat", 901]
  }.each_case(failures) do |(identity, (resource, duplicate_id)), failures|
    duplicate_state = deep_copy(configarr_state)
    duplicate_state.dig("configarr", service, resource) <<
      deep_copy(CONFIGARR.dig(service, resource).first).merge("id" => duplicate_id)
    exercise_duplicate(
      failures, relationship: "Configarr #{service} #{identity}", kind: :configarr,
      state: duplicate_state, variables: {}, write_matcher: configarr_any_write
    )
  end
  duplicate_definition_state = deep_copy(configarr_state)
  duplicate_definition_state.dig("configarr", service, "qualitydefinition") <<
    deep_copy(CONFIGARR.dig(service, "qualitydefinition").first)
  exercise_duplicate(
    failures, relationship: "Configarr #{service} quality definition", kind: :configarr,
    state: duplicate_definition_state, variables: {}, write_matcher: configarr_any_write
  )

  duplicate_score_state = deep_copy(configarr_state)
  profile = duplicate_score_state.dig("configarr", service, "qualityprofile").first
  profile.fetch("formatItems") << deep_copy(profile.fetch("formatItems").first)
  exercise_duplicate(
    failures, relationship: "Configarr #{service} format-score assignment", kind: :configarr,
    state: duplicate_score_state, variables: {}, write_matcher: configarr_any_write
  )

  duplicate_score_id_state = deep_copy(configarr_state)
  score_items = duplicate_score_id_state.dig(
    "configarr", service, "qualityprofile", 0, "formatItems"
  )
  score_items.last["format"] = score_items.first.fetch("format")
  other_service = service == "radarr" ? "sonarr" : "radarr"
  duplicate_score_id_state.dig("configarr", other_service, "customformat").reject! do |format|
    format["name"] == CONFIGARR_FORMAT_NAME
  end
  exercise_duplicate(
    failures,
    relationship: "Configarr #{service} format-score numeric identity",
    kind: :configarr,
    state: duplicate_score_id_state,
    variables: {},
    write_matcher: configarr_any_write
  )

  {
    "quality-profile numeric identity" => ["qualityprofile", 0, 1, "id"],
    "custom-format numeric identity" => ["customformat", 0, 1, "id"],
    "quality-definition numeric identity" => ["qualitydefinition", 0, -1, "id"]
  }.each_case(failures) do |(identity, (resource, source_index, target_index, field)), failures; other_service|
    duplicate_numeric_state = deep_copy(configarr_state)
    collection = duplicate_numeric_state.dig("configarr", service, resource)
    collection.fetch(target_index)[field] = collection.fetch(source_index).fetch(field)
    other_service = service == "radarr" ? "sonarr" : "radarr"
    duplicate_numeric_state.dig("configarr", other_service, "customformat").reject! do |format|
      format["name"] == CONFIGARR_FORMAT_NAME
    end
    duplicate_numeric_state.dig(
      "configarr", other_service, "qualityprofile", 0, "formatItems"
    ).reject! do |assignment|
      assignment["name"] == CONFIGARR_FORMAT_NAME
    end
    exercise_duplicate(
      failures,
      relationship: "Configarr #{service} #{identity}",
      kind: :configarr,
      state: duplicate_numeric_state,
      variables: {},
      write_matcher: configarr_any_write
    )
  end
  duplicate_quality_id_state = deep_copy(configarr_state)
  definitions = duplicate_quality_id_state.dig(
    "configarr", service, "qualitydefinition"
  )
  definitions.last.fetch("quality")["id"] = definitions.first.dig("quality", "id")
  other_service = service == "radarr" ? "sonarr" : "radarr"
  duplicate_quality_id_state.dig("configarr", other_service, "customformat").reject! do |format|
    format["name"] == CONFIGARR_FORMAT_NAME
  end
  exercise_duplicate(
    failures,
    relationship: "Configarr #{service} quality-definition quality numeric identity",
    kind: :configarr,
    state: duplicate_quality_id_state,
    variables: {},
    write_matcher: configarr_any_write
  )
end

{
  "HTTP failure" => { fail_custom_format_service: "radarr" },
  "malformed duplicate numeric identity" => { malformed_custom_format_service: "radarr" }
}.each_case(failures) do |(label, api_options), failures; before, result, sane, variables|
  missing_state = deep_copy(configarr_state)
  missing_state.dig("configarr", "radarr", "customformat").reject! do |format|
    format["name"] == CONFIGARR_FORMAT_NAME
  end
  missing_state.dig("configarr", "radarr", "qualityprofile").first
    .fetch("formatItems").reject! { |item| item["name"] == CONFIGARR_FORMAT_NAME }
  Dir.mktmpdir("media-acquisition-configarr-create-failure-") do |runtime|
    FileUtils.mkdir_p(File.join(runtime, "services", "arr"))
    with_api(missing_state, **api_options) do |api|
      variables = base_variables(api.port)
      seed_fingerprint_baseline(runtime, variables, kind: :configarr, state: missing_state)
      before = fingerprint_snapshot(runtime)
      result = run_tasks(
        :configarr, api, {}, runtime: runtime, prepare_fingerprints: false
      )
      sane = check_sanity(
        failures, "Configarr absent custom format #{label}", result, api,
        kind: :configarr
      )
      next unless sane

      failures << "Configarr absent custom format #{label} was accepted" if
        result.fetch("status").success?
      creates = mutation_requests(api, lambda do |request|
        request["method"] == "POST" &&
          request["target"] == "/radarr/api/v3/customformat"
      end)
      failures << "Configarr absent custom format #{label} did not attempt one exact create" unless
        creates.length == 1
      failures << "Configarr absent custom format #{label} reached the job" unless
        mutation_requests(api, configarr_write).empty?
      failures << "Configarr absent custom format #{label} advanced reconciliation hashes" unless
        fingerprint_snapshot(runtime) == before
      failures << "Configarr absent custom format #{label} reached fingerprint recording" if
        result.fetch("recorder_started")
    end
  end
end

{
  "quality-profile collection" => lambda do |state|
    state.dig("configarr", "radarr")["qualityprofile"] = {}
  end,
  "quality-definition object" => lambda do |state|
    state.dig("configarr", "sonarr", "qualitydefinition")[0] = "invalid"
  end,
  "custom-format collection" => lambda do |state|
    state.dig("configarr", "radarr")["customformat"] = nil
  end,
  "naming object" => lambda do |state|
    state.dig("configarr", "sonarr")["config/naming"] = []
  end,
  "quality item boolean" => lambda do |state|
    state.dig("configarr", "radarr", "qualityprofile", 0, "items", 0)["allowed"] = "false"
  end
}.each_case(failures) do |(label, mutate), failures|
  malformed_state = deep_copy(configarr_state)
  mutate.call(malformed_state)
  exercise_duplicate(
    failures, relationship: "Configarr malformed #{label}", kind: :configarr,
    state: malformed_state, variables: {}, write_matcher: configarr_any_write
  )
end

invalid_source_documents = {
  "unparseable pinned document" => "{\"qualities\":",
  "non-numeric pinned size" => JSON.generate(
    deep_copy(CONFIGARR_QUALITY_DEFINITION_DOCUMENTS.fetch("radarr")).tap do |document|
      document.fetch("qualities").first["min"] = true
    end
  )
}
invalid_source_documents.each_case(failures) do |(label, invalid_source), failures; before, result, sane, variables|
  Dir.mktmpdir("media-acquisition-configarr-source-") do |runtime|
    FileUtils.mkdir_p(File.join(runtime, "services", "arr"))
    with_api(deep_copy(configarr_state)) do |api|
      variables = base_variables(api.port)
      seed_fingerprint_baseline(runtime, variables, kind: :configarr, state: configarr_state)
      before = fingerprint_snapshot(runtime)
      task_mutator = lambda do |tasks|
        source_task = tasks.find do |task|
          task["name"] == "Load pinned Configarr quality-definition source documents"
        end
        source_task.fetch("ansible.builtin.set_fact")
          .fetch("arr_configarr_quality_definition_sources")["radarr"] = invalid_source
      end
      result = run_tasks(
        :configarr, api, {}, runtime: runtime, prepare_fingerprints: false,
        task_mutator: task_mutator
      )
      sane = check_sanity(
        failures, "Configarr #{label}", result, api, kind: :configarr
      )
      next unless sane

      failures << "Configarr #{label} was accepted" if result.fetch("status").success?
      failures << "Configarr #{label} reached a mutation" unless
        mutation_requests(api, configarr_any_write).empty?
      failures << "Configarr #{label} changed reconciliation hashes" unless
        fingerprint_snapshot(runtime) == before
      failures << "Configarr #{label} reached fingerprint recording" if
        result.fetch("recorder_started")
    end
  end
end

%w[radarr sonarr].each_case(failures) do |service, failures; result, sane, writes|
  empty_profile_state = deep_copy(configarr_state)
  empty_profile_state.dig("configarr", service)["qualityprofile"] = []
  exercise_duplicate(
    failures,
    relationship: "Configarr #{service} empty quality-profile collection",
    kind: :configarr,
    state: empty_profile_state,
    variables: {},
    write_matcher: configarr_any_write
  )

  expected_state = deep_copy(CONFIGARR)
  expected_state.dig(service, "customformat").select! do |format|
    format["name"] == CONFIGARR_FORMAT_NAME
  end
  expected_profile = expected_state.dig(service, "qualityprofile").find do |profile|
    profile["name"] == CONFIGARR_PROFILE_NAME
  end
  expected_profile.fetch("formatItems").select! do |assignment|
    assignment["name"] == CONFIGARR_FORMAT_NAME
  end
  bootstrap_state = {
    "configarr" => deep_copy(CONFIGARR),
    "configarr_desired" => expected_state
  }
  bootstrap_state.dig("configarr", service)["customformat"] = []
  bootstrap_profile = bootstrap_state.dig("configarr", service, "qualityprofile").find do |profile|
    profile["name"] == CONFIGARR_PROFILE_NAME
  end
  bootstrap_profile["formatItems"] = []
  with_api(bootstrap_state) do |api|
    result = run_tasks(:configarr, api, {}, prepare_fingerprints: false)
    sane = check_sanity(
      failures, "Configarr #{service} empty custom-format bootstrap", result, api,
      kind: :configarr
    )
    next unless sane

    failures << "Configarr #{service} empty custom-format bootstrap failed" unless
      result.fetch("status").success?
    writes = mutation_requests(api, configarr_any_write)
    expected_writes = [
      ["POST", "/#{service}/api/v3/customformat"],
      ["PUT", "/#{service}/api/v3/qualityprofile/#{101 + %w[radarr sonarr].index(service)}"],
      ["POST", "/_fixture/configarr/apply"]
    ]
    failures << "Configarr #{service} empty custom-format bootstrap write set differs" unless
      writes.map { |request| [request["method"], request["target"]] } == expected_writes
    create_index = api.requests.index do |request|
      request["method"] == "POST" &&
        request["target"] == "/#{service}/api/v3/customformat"
    end
    profile_put_index = api.requests.index do |request|
      request["method"] == "PUT" &&
        request["target"].start_with?("/#{service}/api/v3/qualityprofile/")
    end
    immediate_reads = api.requests.each_index.count do |index|
      request = api.requests[index]
      create_index && profile_put_index && index > create_index && index < profile_put_index &&
        request["method"] == "GET" && request["target"].match?(
          %r{\A/(radarr|sonarr)/api/v3/(qualityprofile|qualitydefinition|customformat|config/naming)\z}
        )
    end
    failures << "Configarr #{service} empty custom-format bootstrap skipped immediate reread" unless
      immediate_reads == 8
    created_format = api.state.dig("configarr", service, "customformat").find do |format|
      format["name"] == CONFIGARR_FORMAT_NAME
    end
    expected_state.dig(service, "customformat").first["id"] = created_format.fetch("id")
    expected_profile.fetch("formatItems").first["format"] = created_format.fetch("id")
    failures << "Configarr #{service} empty custom-format bootstrap did not converge" unless
      configarr_projection(api.state.fetch("configarr")) == configarr_projection(expected_state)
    unrelated_resources = %w[qualitydefinition config/naming]
    unrelated_resources.each do |resource|
      failures << "Configarr #{service} empty custom-format bootstrap changed #{resource}" unless
        api.state.dig("configarr", service, resource) == expected_state.dig(service, resource)
    end
    failures << "Configarr #{service} empty custom-format bootstrap did not record verified hashes" unless
      result.fetch("recorder_started")
  end
end

Dir.mktmpdir("media-acquisition-fingerprint-failure-") do |runtime|
  fingerprint_directory = File.join(runtime, "services", "arr")
  FileUtils.mkdir_p(fingerprint_directory)
  with_api(deep_copy(configarr_state), fail_configarr: true) do |api|
    stale_variables = base_variables(api.port).merge(
      "vault_arr_radarr_api_key" => "private-stale-radarr-apikey",
      "vault_arr_sonarr_api_key" => "private-stale-sonarr-apikey"
    )
    seed_fingerprint_baseline(
      runtime, stale_variables, kind: :configarr, state: configarr_state
    )
    before = fingerprint_snapshot(runtime)
    result = run_tasks(
      :configarr, api, configarr_secret_variables, runtime: runtime,
      prepare_fingerprints: false
    )
    sane = check_sanity(
      failures, "failed reconciliation fingerprint ordering", result, api, kind: :configarr
    )
    if sane
      failures << "failed reconciliation was accepted" if result.fetch("status").success?
      unless mutation_requests(api, configarr_write).length == 1
        failures << "failed reconciliation did not attempt exactly one applicable write"
      end
      after = fingerprint_snapshot(runtime)
      failures << "failed reconciliation advanced future fingerprint files" unless after == before
      failures << "failed reconciliation reached future fingerprint recording" if
        result.fetch("recorder_started")
    end
  end
end

partial_configarr_state = deep_copy(configarr_state)
partial_configarr_state.dig("configarr", "radarr", "qualitydefinition").first[
  "minSize"
] += 1
Dir.mktmpdir("media-acquisition-configarr-partial-") do |runtime|
  FileUtils.mkdir_p(File.join(runtime, "services", "arr"))
  with_api(deep_copy(partial_configarr_state), partial_configarr: true) do |api|
    variables = base_variables(api.port)
    seed_fingerprint_baseline(
      runtime, variables, kind: :configarr, state: partial_configarr_state
    )
    before = fingerprint_snapshot(runtime)
    result = run_tasks(
      :configarr, api, configarr_secret_variables, runtime: runtime,
      prepare_fingerprints: false
    )
    sane = check_sanity(
      failures, "partial Configarr success without repair", result, api, kind: :configarr
    )
    if sane
      failures << "partial Configarr success without repair was accepted" if
        result.fetch("status").success?
      unless mutation_requests(api, configarr_write).length == 1
        failures << "partial Configarr success did not run exactly one job"
      end
      failures << "partial Configarr success advanced verified hashes" unless
        fingerprint_snapshot(runtime) == before
      failures << "partial Configarr success reached fingerprint recording" if
        result.fetch("recorder_started")
    end
  end
end

# The fingerprint-safety matrix below is deliberately cross-cutting: it proves
# the same safety property for every relationship, not only Configarr's. The
# states are literal fixtures built from the shared constants, so this file
# rebuilds the ones it does not otherwise own rather than depending on another
# file having run first.
application_state = {
  "applications" => [
    deep_copy(APPLICATION), deep_copy(SONARR_APPLICATION),
    {
      "id" => 12, "name" => "Unmanaged", "enable" => true,
      "syncLevel" => "fullSync", "implementation" => "Unmanaged",
      "implementationName" => "Unmanaged", "configContract" => "UnmanagedSettings",
      "fields" => [], "tags" => []
    }
  ]
}
client_state = { "download_clients" => [deep_copy(DOWNLOAD_CLIENT)] }
indexer_state = { "indexers" => [deep_copy(INDEXER)] }
provider_state = { "bazarr" => deep_copy(BAZARR_WITH_PROVIDER) }
provider_variables = { "media_bazarr_providers" => [deep_copy(BAZARR_PROVIDER)] }

if fingerprint_tasks_available?
  fingerprint_safety_cases = [
    [:bazarr, provider_state, provider_variables, FINGERPRINT_FILE_BY_KIND.fetch(:bazarr)],
    [:configarr, configarr_state, configarr_secret_variables,
     FINGERPRINT_FILE_BY_KIND.fetch(:configarr)],
    [:configarr, configarr_state, configarr_secret_variables, CONFIGARR_STATE_FINGERPRINT_FILE],
    [:configarr, configarr_state, configarr_secret_variables, CONFIGARR_OPAQUE_FINGERPRINT_FILE]
  ]
  unless OPAQUE_TARGETED_ONLY
    fingerprint_safety_cases = [
      [:application, application_state, {}, FINGERPRINT_FILE_BY_KIND.fetch(:application)],
      [:download_client, client_state, {}, FINGERPRINT_FILE_BY_KIND.fetch(:download_client)],
      [:indexer, indexer_state, {}, FINGERPRINT_FILE_BY_KIND.fetch(:indexer)]
    ] + fingerprint_safety_cases
  end
  fingerprint_safety_cases.each_case(failures) do |(kind, state, variables, filename), failures; baseline, path, sane, target_before|
    Dir.mktmpdir("media-acquisition-fingerprint-safety-") do |runtime|
      with_api(deep_copy(state)) do |api|
        baseline = run_tasks(kind, api, variables, runtime: runtime)
        sane = check_sanity(
          failures, "#{kind} fingerprint safety baseline", baseline, api, kind: kind
        )
        if sane && !baseline.fetch("status").success?
          failures << "#{kind} fingerprint safety baseline failed"
        end
        next unless sane && baseline.fetch("status").success?

        path = File.join(runtime, "services", "arr", filename)
        if kind == :application
          baseline_content = baseline.fetch("fingerprints").fetch(filename).fetch("content")
          File.write(path, "#{baseline_content}\n", mode: "w", perm: 0o600)
          before_content = fingerprint_snapshot(runtime)
          assert_unsafe_fingerprint_rejected(
            failures, "invalid-content fingerprint", kind, api, variables, runtime,
            before_content
          )
          File.write(path, baseline_content, mode: "w", perm: 0o600)
        end

        File.chmod(0o644, path)
        before_mode = fingerprint_snapshot(runtime)
        assert_unsafe_fingerprint_rejected(
          failures, "#{kind} unsafe-mode fingerprint", kind, api, variables, runtime,
          before_mode
        )

        File.chmod(0o600, path)
        File.unlink(path)
        symlink_target = File.join(runtime, "#{kind}-unsafe-target")
        File.write(symlink_target, "#{'f' * 64}\n", mode: "w", perm: 0o600)
        File.symlink(symlink_target, path)
        before_symlink = fingerprint_snapshot(runtime)
        target_before = File.binread(symlink_target)
        assert_unsafe_fingerprint_rejected(
          failures, "#{kind} symlink fingerprint", kind, api, variables, runtime,
          before_symlink
        )
        failures << "#{kind} symlink fingerprint modified its target" unless
          File.binread(symlink_target) == target_before
      end
    end
  end
end


abort failures.join("\n") unless failures.empty?
puts "media acquisition reconciliation (configarr) behavior holds"
