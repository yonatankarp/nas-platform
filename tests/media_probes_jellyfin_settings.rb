#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Jellyfin acceleration, plugin and restart probes (the jellyfin_settings group).
#
# Required by media_managed_users_test.rb, which owns the probe selection so the
# MEDIA_MANAGED_USERS_PROBES contract keeps naming one group rather than a file set.
# Fixtures and helpers come from media_managed_users_support.rb.

def exercise_jellyfin_settings(failures)
  desired_encoding = {
    "HardwareAccelerationType" => "none", "QsvDevice" => "",
    "HardwareDecodingCodecs" => [], "EnableDecodingColorDepth10Hevc" => false,
    "EnableDecodingColorDepth10Vp9" => false, "EnableHardwareEncoding" => false,
    "AllowHevcEncoding" => false, "AllowAv1Encoding" => false,
    "EnableIntelLowPowerH264HwEncoder" => false,
    "EnableIntelLowPowerHevcHwEncoder" => false,
    "EnableVppTonemapping" => false, "EnableTonemapping" => false
  }
  encoding = desired_encoding.merge("EnableHardwareEncoding" => true, "EnableAudioVbr" => true)
  desired_repositories = [
    { "Name" => "Jellyfin Stable",
      "Url" => "https://repo.jellyfin.org/files/plugin/manifest.json", "Enabled" => true },
    { "Name" => "Intro Skipper", "Url" => "https://intro-skipper.org/manifest.json",
      "Enabled" => true }
  ]
  repositories = [
    { "Name" => "Stable Drifted",
      "Url" => "https://repo.jellyfin.org/files/plugin/manifest.json/", "Enabled" => false },
    { "Name" => "Jellyfin Stable",
      "Url" => JELLYFIN_RETIRED_STABLE_REPOSITORY, "Enabled" => true },
    { "Name" => "Unmanaged Sentinel", "Url" => "https://example.invalid/sentinel.json",
      "Enabled" => false }
  ]
  plugins = [
    { "Name" => "Intro Skipper", "Id" => JELLYFIN_INTRO_SKIPPER_ID, "Version" => "1.2.3.4",
      "Status" => "Active" },
    { "Name" => "Open Subtitles", "Id" => "4b9ed42f518548b598036ff2989014c4",
      "Version" => "24.0.0.0", "Status" => "Active" },
    { "Name" => "Unmanaged Plugin", "Id" => "2" * 32, "Version" => "9.8.7.6",
      "Status" => "Active" }
  ]
  opensubtitles = { "Username" => "old", "Password" => "old",
                    "CredentialsInvalid" => true }
  responder = lambda do |request|
    case [request["method"], request["target"]]
    when ["GET", "/System/Configuration/encoding"] then [200, encoding]
    when ["POST", "/System/Configuration/encoding"]
      encoding.replace(request.fetch("json"))
      [204, nil]
    when ["GET", "/Repositories"] then [200, repositories]
    when ["POST", "/Repositories"]
      repositories.replace(request.fetch("json"))
      [204, nil]
    when ["GET", "/Plugins"] then [200, plugins]
    when ["GET", "/System/Info"] then [200, { "HasPendingRestart" => false }]
    when ["GET", "/Plugins/4b9ed42f-5185-48b5-9803-6ff2989014c4/Configuration"]
      [200, opensubtitles]
    when ["POST", "/Plugins/4b9ed42f-5185-48b5-9803-6ff2989014c4/Configuration"]
      opensubtitles.replace(request.fetch("json"))
      [204, nil]
    when ["POST", "/Jellyfin.Plugin.OpenSubtitles/ValidateLoginInfo"]
      request.fetch("json") == { "Username" => "subtitle-user", "Password" => "subtitle-secret" } ?
        [200, { "Downloads" => 10 }] : [401, {}]
    else [500, {}]
    end
  end
  variables = {
    "jellyfin_client_header" => "MediaBrowser Fixture",
    "jellyfin_encoding_policy" => desired_encoding,
    "jellyfin_plugin_repositories" => desired_repositories,
    "jellyfin_plugins" => ["Intro Skipper", "Open Subtitles"],
    "jellyfin_plugin_packages" => JELLYFIN_PLUGIN_PACKAGES,
    "jellyfin_opensubtitles_plugin_id" => JELLYFIN_OPENSUBTITLES_ID,
    "vault_jellyfin_opensubtitles_username" => "subtitle-user",
    "vault_jellyfin_opensubtitles_password" => "subtitle-secret"
  }
  with_http_service(responder) do |port, requests|
    variables["jellyfin_api"] = "http://127.0.0.1:#{port}"
    stdout, stderr, status = run_playbook(
      jellyfin_settings_includes(
        "preflight", "prepare", "activate", "finalize", "reconcile", "verify"
      ), variables
    )
    failures << "Jellyfin settings fixture failed: #{failure_tail(stdout + stderr)}" unless status.success?
    failures << "Jellyfin encoding repair lost an unrelated field" unless
      encoding["EnableAudioVbr"] == true && desired_encoding.all? { |key, value| encoding[key] == value }
    failures << "Jellyfin repository merge lost the unrelated repository" unless
      repositories.any? { |entry| entry["Name"] == "Unmanaged Sentinel" && entry["Enabled"] == false }
    failures << "Jellyfin repository merge retained the previously owned retired stable URL" if
      repositories.any? { |entry| entry["Url"] == JELLYFIN_RETIRED_STABLE_REPOSITORY }
    failures << "Jellyfin repository merge did not normalize and repair owned URLs" unless
      desired_repositories.all? { |desired| repositories.count { |entry| entry["Url"] == desired["Url"] && entry["Name"] == desired["Name"] && entry["Enabled"] } == 1 }
    failures << "Jellyfin reconciliation installed an already present plugin" if
      requests.any? { |request| request["target"].start_with?("/Packages/Installed/") }
    failures << "Jellyfin reconciliation changed an installed plugin version" unless
      plugins.map { |plugin| plugin.values_at("Name", "Version") } == [
        ["Intro Skipper", "1.2.3.4"], ["Open Subtitles", "24.0.0.0"],
        ["Unmanaged Plugin", "9.8.7.6"]
      ]
    failures << "Open Subtitles configuration was not validated and persisted" unless
      opensubtitles == { "Username" => "subtitle-user", "Password" => "subtitle-secret",
                         "CredentialsInvalid" => false }
  end

  duplicate_repositories = [
    { "Name" => "one", "Url" => "HTTPS://EXAMPLE.INVALID/catalog/", "Enabled" => true },
    { "Name" => "two", "Url" => " https://example.invalid/catalog ", "Enabled" => false }
  ]
  duplicate_responder = lambda do |request|
    case request["target"]
    when "/System/Configuration/encoding" then [200, desired_encoding]
    when "/Repositories" then [200, duplicate_repositories]
    else [500, {}]
    end
  end
  with_http_service(duplicate_responder) do |port, requests|
    variables["jellyfin_api"] = "http://127.0.0.1:#{port}"
    _stdout, _stderr, status = run_playbook(jellyfin_settings_includes("preflight"), variables)
    failures << "Jellyfin duplicate normalized repository URLs were accepted" if status.success?
    failures << "Jellyfin duplicate repository preflight reached a mutation" if
      requests.any? { |request| %w[POST PUT PATCH DELETE].include?(request["method"]) }
  end
end

def exercise_jellyfin_server_configuration_refresh(failures)
  main = YAML.safe_load_file(
    File.join(ROOT, "roles", "jellyfin", "tasks", "main.yml"), aliases: false
  )
  selected_names = [
    "Refresh Jellyfin server configuration before name update",
    "Require complete refreshed Jellyfin server configuration",
    "Update the Jellyfin server name"
  ]
  tasks = main.select { |task| selected_names.include?(task_name(task)) }
  desired_repositories = [
    { "Name" => "Jellyfin Stable",
      "Url" => "https://repo.jellyfin.org/files/plugin/manifest.json", "Enabled" => true },
    { "Name" => "Intro Skipper", "Url" => "https://intro-skipper.org/manifest.json",
      "Enabled" => true }
  ]
  current_configuration = {
    "ServerName" => "Yonflix Drifted", "PluginRepositories" => desired_repositories,
    "UnmanagedSentinel" => true
  }
  stale_configuration = Marshal.load(Marshal.dump(current_configuration))
  stale_configuration.fetch("PluginRepositories").last["Enabled"] = false
  responder = lambda do |request|
    case [request["method"], request["target"]]
    when ["GET", "/System/Configuration"]
      [200, current_configuration]
    when ["POST", "/System/Configuration"]
      current_configuration.replace(request.fetch("json"))
      [204, nil]
    else
      [500, {}]
    end
  end
  with_http_service(responder) do |port, requests|
    variables = {
      "jellyfin_api" => "http://127.0.0.1:#{port}",
      "jellyfin_client_header" => "MediaBrowser Fixture",
      "jellyfin_reconcile_token" => "admin-token",
      "jellyfin_server_configuration_before" => { "json" => stale_configuration },
      "jellyfin_server_name_update_required" => true,
      "jellyfin_server_name" => "Yonflix 2.0"
    }
    stdout, stderr, status = run_playbook(tasks, variables)
    failures << "Jellyfin refreshed server-name update failed: #{failure_tail(stdout + stderr)}" unless
      status.success?
    failures << "Jellyfin server-name update overwrote a freshly repaired plugin repository" unless
      current_configuration.fetch("PluginRepositories") == desired_repositories
    failures << "Jellyfin server-name update did not preserve unrelated fresh configuration" unless
      current_configuration["UnmanagedSentinel"] == true
    failures << "Jellyfin server-name update did not refresh immediately before mutation" unless
      requests.map { |request| request.values_at("method", "target") } == [
        ["GET", "/System/Configuration"], ["POST", "/System/Configuration"]
      ]
  end
end

def exercise_jellyfin_policy_preflight(failures)
  main = YAML.safe_load_file(
    File.join(ROOT, "roles", "jellyfin", "tasks", "main.yml"), aliases: false
  )
  policy_task = main.find do |task|
    task_name(task) == "Require explicit Jellyfin acceleration and plugin policy"
  end
  sentinel = {
    "name" => "Sentinel mutation after Jellyfin policy preflight",
    "ansible.builtin.uri" => {
      "url" => "{{ jellyfin_api }}/sentinel", "method" => "POST", "status_code" => [204]
    },
    "changed_when" => true
  }
  defaults = YAML.safe_load_file(
    File.join(ROOT, "roles", "jellyfin", "defaults", "main.yml"), aliases: false
  )
  base = defaults.merge(
    "vault_jellyfin_opensubtitles_username" => "subtitle-user",
    "vault_jellyfin_opensubtitles_password" => "subtitle-secret",
    "platform_kind" => "mac",
    "platform_compose_kind" => "mac",
    "deployment_bundle_test_mode" => false,
    # The render-device inspection below stats this path. Without it the stat
    # itself would fail on an undefined variable and the production-NAS case
    # would report a failure without ever reaching the assert it exists to
    # exercise. platform_render_device_available is deliberately left undefined,
    # because that is the capability the assert must refuse to assume.
    "platform_render_device_path" => "/dev/dri/renderD128"
  )
  base["jellyfin_encoding_policy"] = base.dig("jellyfin_encoding_profiles", "mac")

  integration = Marshal.load(Marshal.dump(base))
  integration["platform_kind"] = "nas"
  integration["platform_compose_kind"] = "integration"
  integration["deployment_bundle_test_mode"] = true
  with_http_service(->(_request) { [204, nil] }) do |port, requests|
    integration["jellyfin_api"] = "http://127.0.0.1:#{port}"
    _stdout, _stderr, status = run_playbook([policy_task, sentinel], integration)
    failures << "Jellyfin integration CPU policy was rejected" unless status.success?
    failures << "Jellyfin integration CPU policy did not reach the sentinel" unless requests.length == 1
  end

  [
    ["integration without test mode", "integration", false],
    ["test mode outside integration", "nas", true]
  ].each do |label, compose_kind, test_mode|
    variables = Marshal.load(Marshal.dump(integration))
    variables["platform_compose_kind"] = compose_kind
    variables["deployment_bundle_test_mode"] = test_mode
    with_http_service(->(_request) { [204, nil] }) do |port, requests|
      variables["jellyfin_api"] = "http://127.0.0.1:#{port}"
      _stdout, _stderr, status = run_playbook([policy_task, sentinel], variables)
      failures << "Jellyfin #{label} CPU bypass was accepted" if status.success?
      failures << "Jellyfin #{label} CPU bypass reached mutation" unless requests.empty?
    end
  end

  render_tasks = main.select do |task|
    ["Inspect the exact NAS Jellyfin render device",
     "Require the exact NAS Jellyfin render device"].include?(task_name(task))
  end
  _stdout, _stderr, status = run_playbook(render_tasks, integration)
  failures << "Jellyfin integration still required a host render device" unless status.success?

  production_nas = Marshal.load(Marshal.dump(integration))
  production_nas["platform_compose_kind"] = "nas"
  production_nas["deployment_bundle_test_mode"] = false
  _stdout, _stderr, status = run_playbook(render_tasks, production_nas)
  failures << "Jellyfin production NAS accepted an absent render device" if status.success?
  mutations = {
    "wrong codec list" => lambda do |variables|
      variables.dig("jellyfin_encoding_profiles", "nas", "HardwareDecodingCodecs") << "av1"
    end,
    "wrong NAS hardware boolean" => lambda do |variables|
      variables.dig("jellyfin_encoding_profiles", "nas")["AllowAv1Encoding"] = true
    end,
    "numeric NAS hardware boolean" => lambda do |variables|
      variables.dig("jellyfin_encoding_profiles", "nas")["EnableHardwareEncoding"] = 1
    end,
    "numeric Mac hardware boolean" => lambda do |variables|
      variables.dig("jellyfin_encoding_profiles", "mac")["EnableHardwareEncoding"] = 0
      variables["jellyfin_encoding_policy"] = variables.dig("jellyfin_encoding_profiles", "mac")
    end,
    "numeric effective true hardware boolean" => lambda do |variables|
      variables["platform_kind"] = "nas"
      variables["jellyfin_encoding_policy"] =
        Marshal.load(Marshal.dump(variables.dig("jellyfin_encoding_profiles", "nas")))
      variables.fetch("jellyfin_encoding_policy")["EnableHardwareEncoding"] = 1
    end,
    "numeric effective false hardware boolean" => lambda do |variables|
      variables["jellyfin_encoding_policy"] =
        Marshal.load(Marshal.dump(variables.dig("jellyfin_encoding_profiles", "mac")))
      variables.fetch("jellyfin_encoding_policy")["EnableHardwareEncoding"] = 0
    end,
    "wrong NAS device" => lambda do |variables|
      variables.dig("jellyfin_encoding_profiles", "nas")["QsvDevice"] = "/dev/dri/card0"
    end,
    "wrong Mac hardware boolean" => lambda do |variables|
      variables.dig("jellyfin_encoding_profiles", "mac")["EnableHardwareEncoding"] = true
      variables["jellyfin_encoding_policy"] = variables.dig("jellyfin_encoding_profiles", "mac")
    end,
    "platform policy mismatch" => lambda do |variables|
      variables["jellyfin_encoding_policy"] = variables.dig("jellyfin_encoding_profiles", "nas")
    end,
    "wrong repository URL" => lambda do |variables|
      variables.fetch("jellyfin_plugin_repositories")[0]["Url"] = "https://example.invalid/stable.json"
    end,
    "repository URL surrounding whitespace" => lambda do |variables|
      variables.fetch("jellyfin_plugin_repositories")[0]["Url"] =
        " https://repo.jellyfin.org/files/plugin/manifest.json "
    end,
    "repository URL case variant" => lambda do |variables|
      variables.fetch("jellyfin_plugin_repositories")[0]["Url"] =
        "HTTPS://REPO.JELLYFIN.ORG/files/plugin/manifest.json"
    end,
    "repository URL trailing slash" => lambda do |variables|
      variables.fetch("jellyfin_plugin_repositories")[1]["Url"] =
        "https://intro-skipper.org/manifest.json/"
    end,
    "wrong repository name" => lambda do |variables|
      variables.fetch("jellyfin_plugin_repositories")[1]["Name"] = "Intro Drifted"
    end,
    "disabled required repository" => lambda do |variables|
      variables.fetch("jellyfin_plugin_repositories")[1]["Enabled"] = false
    end,
    "numeric required repository enabled flag" => lambda do |variables|
      variables.fetch("jellyfin_plugin_repositories")[1]["Enabled"] = 1
    end,
    "missing required repository" => lambda do |variables|
      variables.fetch("jellyfin_plugin_repositories").pop
    end,
    "extra required repository" => lambda do |variables|
      variables.fetch("jellyfin_plugin_repositories") << {
        "Name" => "Extra", "Url" => "https://example.invalid/extra.json", "Enabled" => true
      }
    end,
    "duplicate required repository URL" => lambda do |variables|
      variables.fetch("jellyfin_plugin_repositories")[1]["Url"] =
        "HTTPS://REPO.JELLYFIN.ORG/files/plugin/manifest.json/"
    end
  }
  mutations.each do |label, mutate|
    variables = Marshal.load(Marshal.dump(base))
    mutate.call(variables)
    with_http_service(->(_request) { [204, nil] }) do |port, requests|
      variables["jellyfin_api"] = "http://127.0.0.1:#{port}"
      _stdout, _stderr, status = run_playbook([policy_task, sentinel], variables)
      failures << "Jellyfin #{label} policy was accepted" if status.success?
      failures << "Jellyfin #{label} policy reached mutation" unless requests.empty?
    end
  end
end

def exercise_jellyfin_plugin_versions(failures)
  desired_encoding = {
    "HardwareAccelerationType" => "none", "QsvDevice" => "",
    "HardwareDecodingCodecs" => [], "EnableDecodingColorDepth10Hevc" => false,
    "EnableDecodingColorDepth10Vp9" => false, "EnableHardwareEncoding" => false,
    "AllowHevcEncoding" => false, "AllowAv1Encoding" => false,
    "EnableIntelLowPowerH264HwEncoder" => false,
    "EnableIntelLowPowerHevcHwEncoder" => false,
    "EnableVppTonemapping" => false, "EnableTonemapping" => false
  }
  desired_repositories = [
    { "Name" => "Jellyfin Stable",
      "Url" => "https://repo.jellyfin.org/files/plugin/manifest.json", "Enabled" => true },
    { "Name" => "Intro Skipper", "Url" => "https://intro-skipper.org/manifest.json",
      "Enabled" => true }
  ]
  variables = {
    "jellyfin_client_header" => "MediaBrowser Fixture",
    "jellyfin_encoding_policy" => desired_encoding,
    "jellyfin_plugin_repositories" => desired_repositories,
    "jellyfin_plugins" => ["Intro Skipper", "Open Subtitles"],
    "jellyfin_plugin_packages" => JELLYFIN_PLUGIN_PACKAGES,
    "jellyfin_opensubtitles_plugin_id" => JELLYFIN_OPENSUBTITLES_ID,
    "vault_jellyfin_opensubtitles_username" => "subtitle-user",
    "vault_jellyfin_opensubtitles_password" => "subtitle-secret"
  }
  cases = {
    "active plus disabled old" => [
      { "Name" => "Intro Skipper", "Id" => JELLYFIN_INTRO_SKIPPER_ID, "Version" => "2.0.0.0", "Status" => "Active" },
      { "Name" => "Intro Skipper", "Id" => JELLYFIN_INTRO_SKIPPER_ID, "Version" => "1.0.0.0", "Status" => "Disabled" },
      { "Name" => "Open Subtitles", "Id" => "4b9ed42f-5185-48b5-9803-6ff2989014c4",
        "Version" => "24.0.0.0", "Status" => "Active" }
    ],
    "multiple active" => [
      { "Name" => "Intro Skipper", "Id" => JELLYFIN_INTRO_SKIPPER_ID, "Version" => "2.0.0.0", "Status" => "Active" },
      { "Name" => "Intro Skipper", "Id" => JELLYFIN_INTRO_SKIPPER_ID, "Version" => "1.0.0.0", "Status" => "Active" },
      { "Name" => "Open Subtitles", "Id" => "4b9ed42f-5185-48b5-9803-6ff2989014c4",
        "Version" => "24.0.0.0", "Status" => "Active" }
    ],
    "restart pending plus disabled old" => [
      { "Name" => "Intro Skipper", "Id" => JELLYFIN_INTRO_SKIPPER_ID, "Version" => "2.0.0.0", "Status" => "Restart" },
      { "Name" => "Intro Skipper", "Id" => JELLYFIN_INTRO_SKIPPER_ID, "Version" => "1.0.0.0", "Status" => "Disabled" },
      { "Name" => "Open Subtitles", "Id" => "4b9ed42f-5185-48b5-9803-6ff2989014c4",
        "Version" => "24.0.0.0", "Status" => "Active" }
    ],
    "multiple disabled" => [
      { "Name" => "Intro Skipper", "Id" => JELLYFIN_INTRO_SKIPPER_ID, "Version" => "2.0.0.0", "Status" => "Disabled" },
      { "Name" => "Intro Skipper", "Id" => JELLYFIN_INTRO_SKIPPER_ID, "Version" => "1.0.0.0", "Status" => "Disabled" },
      { "Name" => "Open Subtitles", "Id" => "4b9ed42f-5185-48b5-9803-6ff2989014c4",
        "Version" => "24.0.0.0", "Status" => "Active" }
    ]
  }
  cases.each do |label, plugins|
    requests_after_preflight = []
    responder = lambda do |request|
      case [request["method"], request["target"]]
      when ["GET", "/System/Configuration/encoding"] then [200, desired_encoding]
      when ["GET", "/Repositories"] then [200, desired_repositories]
      when ["GET", "/Plugins"] then [200, plugins]
      when ["GET", "/System/Info"] then [200, { "HasPendingRestart" => false }]
      when ["GET", "/Plugins/4b9ed42f-5185-48b5-9803-6ff2989014c4/Configuration"]
        [200, { "Username" => "subtitle-user", "Password" => "subtitle-secret",
                "CredentialsInvalid" => false }]
      when ["POST", "/Jellyfin.Plugin.OpenSubtitles/ValidateLoginInfo"]
        [200, { "Downloads" => 10 }]
      else
        requests_after_preflight << request
        [204, nil]
      end
    end
    with_http_service(responder) do |port, requests|
      fixture_variables = Marshal.load(Marshal.dump(variables))
      fixture_variables["jellyfin_api"] = "http://127.0.0.1:#{port}"
      phases = %w[preflight prepare activate finalize reconcile]
      phases = ["preflight"] if
        ["multiple active", "restart pending plus disabled old", "multiple disabled"].include?(label)
      tasks = jellyfin_settings_includes(*phases)
      if label == "restart pending plus disabled old"
        tasks << {
          "name" => "Require restart-pending plugin to remain installed",
          "ansible.builtin.assert" => { "that" => ["jellyfin_missing_plugins == []"] }
        }
      end
      stdout, stderr, status = run_playbook(tasks, fixture_variables)
      if ["multiple active", "multiple disabled"].include?(label)
        failures << "Jellyfin #{label} plugin versions were accepted" if status.success?
        failures << "Jellyfin #{label} plugin versions reached mutation" unless
          requests.none? { |request| %w[POST PUT PATCH DELETE].include?(request["method"]) }
      elsif label == "restart pending plus disabled old"
        failures << "Jellyfin restart-pending plugin was treated as absent: #{failure_tail(stdout + stderr)}" unless
          status.success?
        failures << "Jellyfin restart-pending plugin preflight reached mutation" unless
          requests.none? do |request|
            %w[POST PUT PATCH DELETE].include?(request["method"]) &&
              request["target"] != "/Jellyfin.Plugin.OpenSubtitles/ValidateLoginInfo"
          end
      else
        failures << "Jellyfin active plus disabled old fixture failed: #{failure_tail(stdout + stderr)}" unless
          status.success?
        failures << "Jellyfin enabled or installed an old disabled plugin version" if
          requests.any? do |request|
            request["target"].include?("/Enable") ||
              request["target"].start_with?("/Packages/Installed/Intro%20Skipper")
          end
      end
    end
  end

  plugins = [
    { "Name" => "Intro Skipper", "Id" => JELLYFIN_INTRO_SKIPPER_ID, "Version" => "1.0.0.0",
      "Status" => "Disabled" },
    { "Name" => "Open Subtitles", "Id" => "4b9ed42f-5185-48b5-9803-6ff2989014c4",
      "Version" => "24.0.0.0", "Status" => "Active" }
  ]
  fresh_repositories = [desired_repositories.first.merge("Enabled" => false)]
  responder = lambda do |request|
    case [request["method"], request["target"]]
    when ["GET", "/System/Configuration/encoding"] then [200, desired_encoding]
    when ["GET", "/Repositories"] then [200, fresh_repositories]
    when ["POST", "/Repositories"]
      fresh_repositories.replace(request.fetch("json"))
      [204, nil]
    when ["GET", "/Plugins"] then [200, plugins]
    when ["GET", "/System/Info"] then [200, { "HasPendingRestart" => false }]
    when ["POST", "/Plugins/#{JELLYFIN_INTRO_SKIPPER_ID}/1.0.0.0/Enable"]
      plugins.fetch(0)["Status"] = "Active"
      [204, nil]
    when ["GET", "/Plugins/4b9ed42f-5185-48b5-9803-6ff2989014c4/Configuration"]
      [200, { "Username" => "subtitle-user", "Password" => "subtitle-secret",
              "CredentialsInvalid" => false }]
    when ["POST", "/Jellyfin.Plugin.OpenSubtitles/ValidateLoginInfo"]
      [200, { "Downloads" => 10 }]
    else [500, {}]
    end
  end
  with_http_service(responder) do |port, requests|
    fixture_variables = Marshal.load(Marshal.dump(variables))
    fixture_variables["jellyfin_api"] = "http://127.0.0.1:#{port}"
    stdout, stderr, status = run_playbook(
      jellyfin_settings_includes(
        "preflight", "prepare", "activate", "finalize", "reconcile"
      ), fixture_variables
    )
    failures << "Jellyfin single disabled plugin fixture failed: #{failure_tail(stdout + stderr)}" unless
      status.success?
    installs = requests.select { |request| request["target"].start_with?("/Packages/Installed/") }
    failures << "Jellyfin single disabled plugin triggered package installation" unless installs.empty?
    enables = requests.select { |request| request["target"].include?("/Enable") }
    failures << "Jellyfin single disabled plugin did not enable its exact installed ID/version" unless
      enables.map { |request| request["target"] } ==
        ["/Plugins/#{JELLYFIN_INTRO_SKIPPER_ID}/1.0.0.0/Enable"]
  end

  plugins = [
    { "Name" => "Open Subtitles", "Id" => "4b9ed42f-5185-48b5-9803-6ff2989014c4",
      "Version" => "24.0.0.0", "Status" => "Active" }
  ]
  fresh_repositories = [desired_repositories.first.merge("Enabled" => false)]
  responder = lambda do |request|
    target = URI.parse(request["target"])
    if request["method"] == "POST" && target.path == "/Packages/Installed/Intro%20Skipper"
      plugins << { "Name" => "Intro Skipper", "Id" => JELLYFIN_INTRO_SKIPPER_ID,
                   "Version" => "3.0.0.0", "Status" => "Active" }
      next [204, nil]
    end
    case [request["method"], request["target"]]
    when ["GET", "/System/Configuration/encoding"] then [200, desired_encoding]
    when ["GET", "/Repositories"] then [200, fresh_repositories]
    when ["POST", "/Repositories"]
      fresh_repositories.replace(request.fetch("json"))
      [204, nil]
    when ["GET", "/Plugins"] then [200, plugins]
    when ["GET", "/Packages"]
      intro_ready = fresh_repositories.any? do |repository|
        repository == desired_repositories.last
      end
      intro_ready ?
        [200, [{ "name" => "Intro Skipper", "guid" => JELLYFIN_INTRO_SKIPPER_ID.delete("-"),
                 "versions" => [{ "version" => "3.0.0.0", "targetAbi" => "10.11.11.0",
                                   "repositoryUrl" => "https://intro-skipper.org/manifest.json" }] }]] :
        [200, []]
    when ["GET", "/Plugins/4b9ed42f-5185-48b5-9803-6ff2989014c4/Configuration"]
      [200, { "Username" => "subtitle-user", "Password" => "subtitle-secret",
              "CredentialsInvalid" => false }]
    when ["POST", "/Jellyfin.Plugin.OpenSubtitles/ValidateLoginInfo"]
      [200, { "Downloads" => 10 }]
    else [500, {}]
    end
  end
  with_http_service(responder) do |port, requests|
    fixture_variables = Marshal.load(Marshal.dump(variables))
    fixture_variables["jellyfin_api"] = "http://127.0.0.1:#{port}"
    stdout, stderr, status = run_playbook(
      jellyfin_settings_includes(
        "preflight", "prepare", "activate", "finalize", "reconcile"
      ), fixture_variables
    )
    failures << "Jellyfin absent plugin fixture failed: #{failure_tail(stdout + stderr)}" unless
      status.success?
    installs = requests.select { |request| request["target"].start_with?("/Packages/Installed/") }
    install_query = installs.length == 1 ? URI.decode_www_form(URI.parse(installs[0]["target"]).query.to_s).to_h : {}
    failures << "Jellyfin absent plugin install did not use exact catalog identity without version" unless
      installs.length == 1 &&
        URI.parse(installs[0]["target"]).path == "/Packages/Installed/Intro%20Skipper" &&
        install_query == {
          "assemblyGuid" => JELLYFIN_INTRO_SKIPPER_ID,
          "repositoryUrl" => "https://intro-skipper.org/manifest.json"
        }
    failures << "Jellyfin absent plugin unexpectedly used the enable endpoint" if
      requests.any? { |request| request["target"].include?("/Enable") }
    repository_write = requests.index do |request|
      request["method"] == "POST" && request["target"] == "/Repositories"
    end
    catalog_read = requests.index { |request| request["target"] == "/Packages" }
    failures << "Jellyfin absent plugin catalog was read before required repositories were ready" unless
      repository_write && catalog_read && repository_write < catalog_read
  end

  plugins = [
    { "Name" => "Open Subtitles", "Id" => JELLYFIN_OPENSUBTITLES_ID,
      "Version" => "24.0.0.0", "Status" => "Active" }
  ]
  colliding_catalog = [
    { "name" => "Intro Skipper", "guid" => JELLYFIN_INTRO_SKIPPER_ID,
      "versions" => [{ "version" => "3.0.0.0", "targetAbi" => "10.11.11.0",
                        "repositoryUrl" => "https://intro-skipper.org/manifest.json" }] },
    { "name" => "Intro Skipper", "guid" => "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
      "versions" => [{ "version" => "99.0.0.0", "targetAbi" => "10.11.11.0",
                        "repositoryUrl" => "https://example.invalid/collision.json" }] }
  ]
  responder = lambda do |request|
    case [request["method"], request["target"]]
    when ["GET", "/System/Configuration/encoding"] then [200, desired_encoding]
    when ["GET", "/Repositories"] then [200, desired_repositories]
    when ["GET", "/Plugins"] then [200, plugins]
    when ["GET", "/Packages"] then [200, colliding_catalog]
    when ["GET", "/Plugins/#{JELLYFIN_OPENSUBTITLES_ID}/Configuration"]
      [200, { "Username" => "subtitle-user", "Password" => "subtitle-secret",
              "CredentialsInvalid" => false }]
    when ["POST", "/Jellyfin.Plugin.OpenSubtitles/ValidateLoginInfo"]
      [200, { "Downloads" => 10 }]
    else [204, nil]
    end
  end
  with_http_service(responder) do |port, requests|
    fixture_variables = Marshal.load(Marshal.dump(variables))
    fixture_variables["jellyfin_api"] = "http://127.0.0.1:#{port}"
    _stdout, _stderr, status = run_playbook(
      jellyfin_settings_includes(
        "preflight", "prepare", "activate", "finalize", "reconcile"
      ), fixture_variables
    )
    failures << "Jellyfin colliding package name/source catalog was accepted" if status.success?
    failures << "Jellyfin colliding package catalog reached installation" if
      requests.any? { |request| request["target"].start_with?("/Packages/Installed/") }
  end
end

def exercise_jellyfin_restart_decision(failures)
  settings = YAML.safe_load_file(
    File.join(ROOT, "roles", "jellyfin", "tasks", "settings.yml"), aliases: false
  )
  resolve = settings.find { |task| task_name(task) == "Resolve Jellyfin plugin restart requirement" }
  restart = Marshal.load(Marshal.dump(
    settings.find { |task| task_name(task) == "Restart Jellyfin once for pending plugins" }
  ))
  failures << "Jellyfin settings contain more than one controlled restart block" unless
    settings.count { |task| task_name(task) == "Restart Jellyfin once for pending plugins" } == 1
  restart.delete("community.docker.docker_compose_v2")
  restart["ansible.builtin.uri"] = {
    "url" => "{{ jellyfin_api }}/restart", "method" => "POST", "status_code" => [204]
  }
  cases = [
    ["both plugins pending", %w[Restart Restart], 1],
    ["one plugin pending", %w[Restart Active], 1],
    ["neither plugin pending", %w[Active Active], 0]
  ]
  cases.each do |label, statuses, expected_restarts|
    with_http_service(->(_request) { [204, nil] }) do |port, requests|
      variables = {
        "jellyfin_api" => "http://127.0.0.1:#{port}",
        "jellyfin_settings_phase" => "finalize",
        "jellyfin_plugins" => ["Intro Skipper", "Open Subtitles"],
        "jellyfin_plugins_after_install" => { "json" => [
          { "Name" => "Intro Skipper", "Status" => statuses[0] },
          { "Name" => "Open Subtitles", "Status" => statuses[1] }
        ] }
      }
      stdout, stderr, status = run_playbook([resolve, restart], variables)
      failures << "Jellyfin #{label} restart fixture failed: #{failure_tail(stdout + stderr)}" unless status.success?
      restart_count = requests.count { |request| request["target"] == "/restart" }
      failures << "Jellyfin #{label} performed #{restart_count} restart(s), expected #{expected_restarts}" unless
        restart_count == expected_restarts
    end
  end
end

def exercise_jellyfin_restart_readiness(failures)
  settings = YAML.safe_load_file(
    File.join(ROOT, "roles", "jellyfin", "tasks", "settings.yml"), aliases: false
  )
  names = [
    "Restart Jellyfin once for pending plugins",
    "Wait for the Jellyfin startup API after plugin restart",
    "Reauthenticate Jellyfin after plugin restart",
    "Adopt the post-restart Jellyfin token"
  ]
  tasks = names.map do |name|
    Marshal.load(Marshal.dump(settings.find { |task| task_name(task) == name }))
  end
  tasks.fetch(0).delete("community.docker.docker_compose_v2")
  tasks.fetch(0)["ansible.builtin.uri"] = {
    "url" => "{{ jellyfin_api }}/restart", "method" => "POST", "status_code" => [204]
  }
  tasks.fetch(1)["delay"] = 0
  tasks.fetch(2)["delay"] = 0
  variables = {
    "jellyfin_settings_phase" => "finalize", "jellyfin_plugin_restart_required" => true,
    "jellyfin_client_header" => "MediaBrowser Fixture", "jellyfin_settings_token" => "old-token",
    "jellyfin_reconcile_login" => { "json" => { "User" => { "Name" => "Yonatan" } } },
    "vault_jellyfin_admin_password" => "admin-secret"
  }

  auth_attempts = 0
  responder = lambda do |request|
    case [request["method"], request["target"]]
    when ["POST", "/restart"] then [204, nil]
    when ["GET", "/health"] then [200, nil]
    when ["GET", "/Startup/Configuration"] then [200, {}]
    when ["POST", "/Users/AuthenticateByName"]
      auth_attempts += 1
      auth_attempts < 3 ? [503, {}] : [200, { "AccessToken" => "new-token" }]
    else [500, {}]
    end
  end
  with_http_service(responder) do |port, requests|
    fixture_variables = variables.merge("jellyfin_api" => "http://127.0.0.1:#{port}")
    stdout, stderr, status = run_playbook(tasks, fixture_variables)
    failures << "Jellyfin restart readiness/auth retry fixture failed: #{failure_tail(stdout + stderr)}" unless
      status.success?
    failures << "Jellyfin restart readiness did not use the supported startup API" unless
      requests.any? { |request| request["target"] == "/Startup/Configuration" }
    failures << "Jellyfin restart readiness still relies on the shallow health endpoint" if
      requests.any? { |request| request["target"] == "/health" }
    failures << "Jellyfin restart authentication was not retried to success" unless auth_attempts == 3
  end

  auth_attempts = 0
  timeout_responder = lambda do |request|
    case [request["method"], request["target"]]
    when ["POST", "/restart"] then [204, nil]
    when ["GET", "/health"], ["GET", "/Startup/Configuration"] then [200, {}]
    when ["POST", "/Users/AuthenticateByName"]
      auth_attempts += 1
      [503, {}]
    else [500, {}]
    end
  end
  timeout_tasks = Marshal.load(Marshal.dump(tasks))
  timeout_tasks.fetch(2)["retries"] = 3
  timeout_tasks.fetch(2)["delay"] = 0
  with_http_service(timeout_responder) do |port, _requests|
    fixture_variables = variables.merge("jellyfin_api" => "http://127.0.0.1:#{port}")
    _stdout, _stderr, status = run_playbook(timeout_tasks, fixture_variables)
    failures << "Jellyfin restart authentication timeout was accepted" if status.success?
    failures << "Jellyfin restart authentication timeout was not bounded (#{auth_attempts})" unless
      auth_attempts == 4
  end

  deferred_names = [
    "Initialize the Jellyfin settings reconciliation token",
    "Read installed Jellyfin plugins after reconciliation",
    "Resolve Jellyfin plugin restart requirement",
    "Restart Jellyfin once for pending plugins",
    "Wait for the Jellyfin startup API after plugin restart",
    "Reauthenticate Jellyfin after plugin restart",
    "Adopt the post-restart Jellyfin token",
    "Reread installed Jellyfin plugins after controlled restart",
    "Require active reconciled Jellyfin plugins",
    "Require deferred Open Subtitles validation after the restart barrier",
    "Read Open Subtitles plugin configuration",
    "Require the pinned Open Subtitles plugin configuration schema",
    "Preserve activated Open Subtitles configuration for reconciliation",
    "Validate the Open Subtitles vault credentials",
    "Require successful Open Subtitles credential validation"
  ]
  deferred_tasks = deferred_names.map do |name|
    Marshal.load(Marshal.dump(settings.find { |task| task_name(task) == name }))
  end
  deferred_restart = deferred_tasks.find do |task|
    task_name(task) == "Restart Jellyfin once for pending plugins"
  end
  deferred_restart.delete("community.docker.docker_compose_v2")
  deferred_restart["ansible.builtin.uri"] = {
    "url" => "{{ jellyfin_api }}/restart", "method" => "POST", "status_code" => [204]
  }
  deferred_tasks.each { |task| task["delay"] = 0 if task.key?("delay") }
  plugin_state = "Restart"
  deferred_responder = lambda do |request|
    case [request["method"], request["target"]]
    when ["GET", "/Plugins"]
      [200, [
        { "Name" => "Intro Skipper", "Status" => plugin_state },
        { "Name" => "Open Subtitles", "Status" => plugin_state }
      ]]
    when ["POST", "/restart"]
      plugin_state = "Active"
      [204, nil]
    when ["GET", "/Startup/Configuration"] then [200, {}]
    when ["POST", "/Users/AuthenticateByName"] then [200, { "AccessToken" => "new-token" }]
    when ["GET", "/Plugins/#{JELLYFIN_OPENSUBTITLES_ID}/Configuration"]
      [200, { "Username" => "old", "Password" => "old", "CredentialsInvalid" => true }]
    when ["POST", "/Jellyfin.Plugin.OpenSubtitles/ValidateLoginInfo"] then [401, {}]
    else [500, {}]
    end
  end
  with_http_service(deferred_responder) do |port, requests|
    fixture_variables = variables.merge(
      "jellyfin_api" => "http://127.0.0.1:#{port}",
      "jellyfin_plugins" => ["Intro Skipper", "Open Subtitles"],
      "jellyfin_opensubtitles_credentials_validated" => false,
      "jellyfin_opensubtitles_plugin_id" => JELLYFIN_OPENSUBTITLES_ID,
      "vault_jellyfin_opensubtitles_username" => "invalid-user",
      "vault_jellyfin_opensubtitles_password" => "invalid-password"
    )
    _stdout, _stderr, status = run_playbook(deferred_tasks, fixture_variables)
    failures << "Jellyfin deferred invalid Open Subtitles credentials were accepted" if status.success?
    restart_index = requests.index { |request| request["target"] == "/restart" }
    validation_index = requests.index do |request|
      request["target"] == "/Jellyfin.Plugin.OpenSubtitles/ValidateLoginInfo"
    end
    failures << "Jellyfin deferred credentials were not validated immediately after one restart" unless
      requests.count { |request| request["target"] == "/restart" } == 1 &&
        restart_index && validation_index && restart_index < validation_index
    failures << "Jellyfin deferred invalid credentials reached Open Subtitles configuration mutation" if
      requests.any? do |request|
        request["method"] == "POST" &&
          request["target"] == "/Plugins/#{JELLYFIN_OPENSUBTITLES_ID}/Configuration"
      end
  end
end

def exercise_jellyfin_qsv_probe(failures)
  probe_path = File.join(ROOT, "roles", "jellyfin", "tasks", "qsv_probe.yml")
  unless File.file?(probe_path)
    failures << "Jellyfin reusable QSV verification probe is absent"
    return
  end

  probe_tasks = YAML.safe_load_file(probe_path, aliases: false)
  info_task = probe_tasks.find do |task|
    task.key?("ansible.builtin.command") &&
      Array(task.dig("ansible.builtin.command", "argv")) == %w[docker container inspect jellyfin]
  end
  unless info_task
    failures << "Jellyfin reusable QSV probe does not inspect container existence in check mode"
    return
  end
  exec_task = probe_tasks.find do |task|
    task.key?("community.docker.docker_compose_v2_exec")
  end
  unless exec_task
    failures << "Jellyfin reusable QSV probe omits FFmpeg container execution"
    return
  end
  qsv_argv = Array(exec_task.dig("community.docker.docker_compose_v2_exec", "argv"))
  unless qsv_argv.each_cons(3).include?(["-f", "null", "-"])
    failures << "Jellyfin reusable QSV probe must pass the literal null muxer to FFmpeg"
  end
  exec_task.delete("community.docker.docker_compose_v2_exec")
  exec_task["ansible.builtin.uri"] = {
    "url" => "{{ jellyfin_api }}/qsv", "method" => "POST", "status_code" => [204]
  }
  info_task.delete("ansible.builtin.command")
  info_task.delete("register")
  info_task.delete("failed_when")
  info_task.delete("no_log")
  info_task["ansible.builtin.set_fact"] = {
    "jellyfin_qsv_container_info" => {
      "rc" => "{{ 0 if fixture_container_exists else 1 }}"
    }
  }
  variables = { "jellyfin_api" => nil,
                "platform_service_compose_files" => { "jellyfin" => ["compose.yml"] },
                "jellyfin_compose_project_name" => "fixture", "platform_current_dir" => ROOT,
                "platform_runtime_dir" => ROOT }
  cases = [
    ["nas", [], true, 1],
    ["mac", [], true, 0],
    ["nas", ["--check"], false, 0],
    ["nas", ["--check"], true, 1],
    ["integration", [], true, 0]
  ]
  cases.each do |platform, arguments, container_exists, expected|
    with_http_service(->(_request) { [204, nil] }) do |port, requests|
      fixture_variables = variables.merge(
        "jellyfin_api" => "http://127.0.0.1:#{port}",
        "platform_kind" => platform == "integration" ? "nas" : platform,
        "platform_compose_kind" => platform == "integration" ? "integration" : platform,
        "deployment_bundle_test_mode" => platform == "integration",
        "fixture_container_exists" => container_exists
      )
      stdout, stderr, status = run_playbook(probe_tasks, fixture_variables, *arguments)
      failures << "Jellyfin #{platform} QSV probe fixture failed: #{failure_tail(stdout + stderr)}" unless
        status.success?
      failures << "Jellyfin #{platform} QSV probe count differs in #{arguments.join(' ')}" unless
        requests.count { |request| request["target"] == "/qsv" } == expected
      if platform == "nas" && arguments == ["--check"] && !container_exists
        failures << "Jellyfin NAS check mode omits planned QSV proof" unless
          (stdout + stderr).include?("JELLYFIN_PLAN_QSV_PROBE")
      end
    end
  end

  main = YAML.safe_load_file(
    File.join(ROOT, "roles", "jellyfin", "tasks", "main.yml"), aliases: false
  )
  probe_includes = main.select do |task|
    include_value = task["ansible.builtin.include_tasks"]
    include_value == "qsv_probe.yml" ||
      (include_value.is_a?(Hash) && include_value["file"] == "qsv_probe.yml")
  end
  verify_include = probe_includes.find do |task|
    Array(task["tags"]).include?("platform_verify_jellyfin")
  end
  failures << "Jellyfin QSV probe is not invoked during convergence and tagged verification" unless
    probe_includes.length >= 2 && verify_include && verify_include["when"].to_s.include?("platform_kind == 'nas'")
end

def exercise_jellyfin_opensubtitles_ordering(failures)
  main = YAML.safe_load_file(
    File.join(ROOT, "roles", "jellyfin", "tasks", "main.yml"), aliases: false
  )
  settings = YAML.safe_load_file(
    File.join(ROOT, "roles", "jellyfin", "tasks", "settings.yml"), aliases: false
  )
  [
    "Validate active Open Subtitles credentials during global preflight",
    "Validate the Open Subtitles vault credentials",
    "Validate exact Open Subtitles credentials"
  ].each do |name|
    task = settings.find { |candidate| task_name(candidate) == name }
    condition = Array(task && task["when"]).join(" ")
    failures << "Jellyfin #{name} is not restricted to non-synthetic credentials" unless
      condition.include?("platform_compose_kind") &&
        condition.include?("integration") &&
        condition.include?("deployment_bundle_test_mode")
  end
  opensubtitles_index = main.index do |task|
    task_name(task) == "Activate and validate the Open Subtitles plugin when immediately available" &&
      task.dig("vars", "jellyfin_activation_scope") == "opensubtitles"
  end
  prepare_index = main.index do |task|
    task_name(task) == "Prepare Jellyfin plugin repositories and package catalog"
  end
  remaining_index = main.index do |task|
    task_name(task) == "Activate remaining required Jellyfin plugins" &&
      task.dig("vars", "jellyfin_activation_scope") == "remaining"
  end
  reconcile_index = main.index do |task|
    task_name(task) == "Reconcile Jellyfin acceleration and plugins"
  end
  failures << "Jellyfin main flow does not validate Open Subtitles before unrelated settings" unless
    prepare_index && opensubtitles_index && remaining_index && reconcile_index &&
      prepare_index < opensubtitles_index && opensubtitles_index < remaining_index &&
      remaining_index < reconcile_index

  desired_encoding = {
    "HardwareAccelerationType" => "none", "QsvDevice" => "", "HardwareDecodingCodecs" => [],
    "EnableDecodingColorDepth10Hevc" => false, "EnableDecodingColorDepth10Vp9" => false,
    "EnableHardwareEncoding" => false, "AllowHevcEncoding" => false,
    "AllowAv1Encoding" => false, "EnableIntelLowPowerH264HwEncoder" => false,
    "EnableIntelLowPowerHevcHwEncoder" => false, "EnableVppTonemapping" => false,
    "EnableTonemapping" => false
  }
  desired_repositories = [
    { "Name" => "Jellyfin Stable",
      "Url" => "https://repo.jellyfin.org/files/plugin/manifest.json", "Enabled" => true },
    { "Name" => "Intro Skipper", "Url" => "https://intro-skipper.org/manifest.json",
      "Enabled" => true }
  ]
  variables = {
    "jellyfin_client_header" => "MediaBrowser Fixture",
    "jellyfin_encoding_policy" => desired_encoding,
    "jellyfin_plugin_repositories" => desired_repositories,
    "jellyfin_plugins" => ["Intro Skipper", "Open Subtitles"],
    "jellyfin_plugin_packages" => JELLYFIN_PLUGIN_PACKAGES,
    "jellyfin_opensubtitles_plugin_id" => JELLYFIN_OPENSUBTITLES_ID,
    "vault_jellyfin_opensubtitles_username" => "invalid-user",
    "vault_jellyfin_opensubtitles_password" => "invalid-password",
    "vault_jellyfin_admin_password" => "admin-secret",
    "jellyfin_reconcile_login" => { "json" => { "User" => { "Name" => "Yonatan" } } }
  }
  %w[active disabled absent].each do |state|
    repositories = desired_repositories.map(&:dup).tap { |items| items[0]["Enabled"] = false }
    plugins = [
      { "Name" => "Intro Skipper", "Id" => JELLYFIN_INTRO_SKIPPER_ID,
        "Version" => "3.0.0.0", "Status" => state == "active" ? "Active" : "Disabled" }
    ]
    unless state == "absent"
      plugins << { "Name" => "Open Subtitles", "Id" => JELLYFIN_OPENSUBTITLES_ID,
                   "Version" => "24.0.0.0", "Status" => state.capitalize }
    end
    responder = lambda do |request|
      target = URI.parse(request["target"])
      if request["method"] == "POST" && target.path == "/Packages/Installed/Open%20Subtitles"
        plugins << { "Name" => "Open Subtitles", "Id" => JELLYFIN_OPENSUBTITLES_ID,
                     "Version" => "24.0.0.0", "Status" => "Active" }
        next [204, nil]
      end
      case [request["method"], request["target"]]
      when ["GET", "/System/Configuration/encoding"]
        [200, desired_encoding.merge("EnableHardwareEncoding" => true)]
      when ["POST", "/System/Configuration/encoding"] then [204, nil]
      when ["GET", "/Repositories"]
        [200, repositories]
      when ["POST", "/Repositories"]
        repositories.replace(request.fetch("json"))
        [204, nil]
      when ["GET", "/Plugins"] then [200, plugins]
      when ["GET", "/Packages"]
        [200, [{ "name" => "Open Subtitles", "guid" => JELLYFIN_OPENSUBTITLES_ID,
                 "versions" => [{ "version" => "24.0.0.0", "targetAbi" => "10.11.11.0",
                                   "repositoryUrl" =>
                                     "https://repo.jellyfin.org/files/plugin/manifest.json" }] }]]
      when ["POST", "/Plugins/#{JELLYFIN_OPENSUBTITLES_ID}/24.0.0.0/Enable"]
        plugins.last["Status"] = "Active"
        [204, nil]
      when ["POST", "/Plugins/#{JELLYFIN_INTRO_SKIPPER_ID}/3.0.0.0/Enable"]
        plugins.first["Status"] = "Active"
        [204, nil]
      when ["GET", "/Plugins/#{JELLYFIN_OPENSUBTITLES_ID}/Configuration"]
        [200, { "Username" => "old", "Password" => "old", "CredentialsInvalid" => true }]
      when ["POST", "/Plugins/#{JELLYFIN_OPENSUBTITLES_ID}/Configuration"] then [204, nil]
      when ["POST", "/Jellyfin.Plugin.OpenSubtitles/ValidateLoginInfo"] then [401, {}]
      else [500, {}]
      end
    end
    with_http_service(responder) do |port, requests|
      fixture_variables = Marshal.load(Marshal.dump(variables))
      fixture_variables["jellyfin_api"] = "http://127.0.0.1:#{port}"
      _stdout, _stderr, status = run_playbook(
        jellyfin_settings_includes(
          "preflight", "prepare", "activate", "finalize", "reconcile"
        ), fixture_variables
      )
      failures << "Jellyfin #{state} invalid Open Subtitles credentials were accepted" if status.success?
      allowed = ["/Jellyfin.Plugin.OpenSubtitles/ValidateLoginInfo"]
      allowed << "/Repositories" if state == "absent"
      allowed << "/Plugins/#{JELLYFIN_OPENSUBTITLES_ID}/24.0.0.0/Enable" if state == "disabled"
      failures << "Jellyfin #{state} invalid credentials allowed unrelated mutation" if requests.any? do |request|
        %w[POST PUT PATCH DELETE].include?(request["method"]) &&
          !allowed.include?(request["target"]) &&
          !(state == "absent" && request["target"].start_with?("/Packages/Installed/Open%20Subtitles"))
      end
      if state != "active"
        activation_index = requests.index do |request|
          state == "disabled" ? request["target"].include?("/Enable") :
            request["target"].start_with?("/Packages/Installed/Open%20Subtitles")
        end
        validation_index = requests.index do |request|
          request["target"] == "/Jellyfin.Plugin.OpenSubtitles/ValidateLoginInfo"
        end
        failures << "Jellyfin #{state} invalid credentials were not checked after activation" unless
          activation_index && validation_index && activation_index < validation_index
      end
    end
  end
end
