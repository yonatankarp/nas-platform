#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Jellyfin primary-administrator identity and library-shape probes.
#
# Required by media_managed_users_test.rb, which owns the probe selection so the
# MEDIA_MANAGED_USERS_PROBES contract keeps naming one group rather than a file set.
# Fixtures and helpers come from media_managed_users_support.rb.

def exercise_jellyfin_recovery_marker_safety(failures)
  main = YAML.safe_load_file(
    File.join(ROOT, "roles", "jellyfin", "tasks", "main.yml"), aliases: false
  )
  inspect_name = "Inspect Jellyfin primary administrator recovery marker"
  require_name = "Require safe Jellyfin primary administrator recovery marker file"
  read_name = "Read Jellyfin primary administrator recovery marker"
  setup = {
    "name" => "Gather effective Jellyfin marker owner",
    "ansible.builtin.setup" => { "gather_subset" => ["!all", "min"] }
  }
  sentinel = {
    "name" => "Sentinel Jellyfin mutation after marker preflight",
    "ansible.builtin.uri" => {
      "url" => "{{ jellyfin_api }}/sentinel", "method" => "POST", "status_code" => [204]
    },
    "changed_when" => true,
    "no_log" => true
  }
  with_http_service(->(_request) { [204, nil] }) do |port, requests|
    Dir.mktmpdir("jellyfin-marker-mode-") do |directory|
      marker = File.join(directory, "recovery.json")
      File.write(marker, JSON.generate("id" => "a" * 32, "original_name" => "yonatan"))
      File.chmod(0o644, marker)
      marker_tasks = main.select do |task|
        [inspect_name, require_name, read_name].include?(task_name(task))
      end
      stdout, stderr, status = run_playbook(
        [setup, *marker_tasks, sentinel],
        { "jellyfin_api" => "http://127.0.0.1:#{port}",
          "jellyfin_primary_recovery_marker" => marker }
      )
      failures << "Jellyfin mode-drifted recovery marker was accepted: #{failure_tail(stdout + stderr)}" if
        status.success?
      failures << "Jellyfin mode-drifted recovery marker reached an API mutation" unless requests.empty?
    end
  end

  with_http_service(->(_request) { [204, nil] }) do |port, requests|
    require_task = main.find { |task| task_name(task) == require_name }
    marker_state = {
      "stat" => {
        "exists" => true, "isreg" => true, "islnk" => false,
        "mode" => "0600", "pw_name" => "definitely-not-the-effective-user"
      }
    }
    stdout, stderr, status = run_playbook(
      [setup, require_task, sentinel],
      { "jellyfin_api" => "http://127.0.0.1:#{port}",
        "jellyfin_primary_recovery_marker_state" => marker_state }
    )
    failures << "Jellyfin owner-drifted recovery marker was accepted: #{failure_tail(stdout + stderr)}" if
      status.success?
    failures << "Jellyfin owner-drifted recovery marker reached an API mutation" unless requests.empty?
  end
end

def exercise_jellyfin_primary_identity_recovery(failures)
  identity_tasks = File.join(ROOT, "roles", "jellyfin", "tasks", "primary_identity.yml")
  original_id = "a" * 32
  cases = [
    ["second rename failure", "yonatan", true, lambda do |request, state|
      body = request.fetch("json")
      if body.fetch("Name") == "Yonatan"
        state[:exact_attempts] += 1
        next [500, {}] if state[:exact_attempts] == 1
      end
      state[:name] = body.fetch("Name")
      [204, nil]
    end, "yonatan", false],
    ["interrupted prior run", "nas-platform-admin-#{original_id[0, 12]}", true,
     lambda do |request, state|
       state[:name] = request.fetch("json").fetch("Name")
       [204, nil]
     end, "Yonatan", true]
  ]
  cases.each do |label, initial_name, rename_required, rename_behavior, expected_name, expected_success|
    state = { name: initial_name, exact_attempts: 0 }
    responder = lambda do |request|
      case request["method"]
      when "POST" then rename_behavior.call(request, state)
      when "GET"
        [200, { "Id" => original_id, "Name" => state.fetch(:name),
                "Configuration" => {}, "Policy" => { "IsAdministrator" => true } }]
      else [500, {}]
      end
    end
    Dir.mktmpdir("jellyfin-primary-recovery-") do |directory|
      with_http_service(responder) do |port, requests|
      variables = {
        "jellyfin_api" => "http://127.0.0.1:#{port}",
        "jellyfin_client_header" => "MediaBrowser Fixture",
        "jellyfin_reconcile_token" => "admin-token",
        "jellyfin_primary_authenticated_id" => original_id,
        "jellyfin_primary_temporary_name" => "nas-platform-admin-#{original_id[0, 12]}",
        "jellyfin_admin_username" => "Yonatan",
        "jellyfin_primary_user_before" => {
          "Id" => original_id, "Name" => initial_name,
          "Configuration" => {}, "Policy" => { "IsAdministrator" => true }
        },
        "jellyfin_primary_rename_required" => rename_required,
        "jellyfin_primary_temporary_recovery" => initial_name.start_with?("nas-platform-admin-"),
        "jellyfin_primary_recovery_name" =>
          (initial_name.start_with?("nas-platform-admin-") ? "Yonatan" : initial_name),
        "jellyfin_primary_recovery_marker" => File.join(directory, "recovery.json")
      }
      tasks = [{ "name" => "Exercise Jellyfin primary identity recovery",
                 "ansible.builtin.include_tasks" => identity_tasks }]
      stdout, stderr, status = run_playbook(tasks, variables)
      if expected_success
        failures << "Jellyfin #{label} did not converge: #{failure_tail(stdout + stderr)}" unless status.success?
      else
        failures << "Jellyfin #{label} unexpectedly succeeded" if status.success?
      end
      failures << "Jellyfin #{label} left the primary identity at #{state[:name]}: #{failure_tail(stdout + stderr)}" unless
        state[:name] == expected_name
      failures << "Jellyfin #{label} omitted authoritative ID read-back" unless
        requests.any? { |request| request["method"] == "GET" && request["target"] == "/Users/#{original_id}" }
      end
    end
  end
end

def exercise_jellyfin_extra_path_recovery(failures)
  main = YAML.safe_load_file(
    File.join(ROOT, "roles", "jellyfin", "tasks", "main.yml"), aliases: false
  )
  selected_names = [
    "Initialize normalized Jellyfin library inventory",
    "Resolve normalized Jellyfin library inventory",
    "Initialize Jellyfin managed library targets",
    "Resolve Jellyfin managed library targets",
    "Refuse unsafe Jellyfin managed library path representation",
    "Refuse ambiguous Jellyfin managed library ownership",
    "Rename adopted Jellyfin managed libraries",
    "Create absent Jellyfin managed libraries",
    "Remove extra paths from Jellyfin managed libraries",
    "Repair Jellyfin managed library options"
  ]
  tasks = main.select { |task| selected_names.include?(task_name(task)) }
  library_id = "1" * 32
  unmanaged_id = "2" * 32
  state = {
    paths: ["/media/Movies", "/media/Extra-A", "/media/Extra-B"],
    fail_once: true,
    unmanaged_paths: ["/media/Unmanaged"]
  }
  responder = lambda do |request|
    uri = URI("http://fixture#{request.fetch('target')}")
    if request["method"] == "DELETE"
      path = URI.decode_www_form(uri.query).to_h.fetch("path")
      if path == "/media/Extra-B" && state[:fail_once]
        state[:fail_once] = false
        next [500, {}]
      end
      state[:paths].delete(path)
      [204, nil]
    elsif request["method"] == "POST" && request["target"] == "/Library/VirtualFolders/LibraryOptions"
      state[:paths] = request.fetch("json").fetch("LibraryOptions").fetch("PathInfos").map do |entry|
        entry.fetch("Path")
      end
      [204, nil]
    else
      [500, {}]
    end
  end
  with_http_service(responder) do |port, requests|
    2.times do |attempt|
      libraries = [
        { "Name" => "Movies", "ItemId" => library_id, "CollectionType" => "movies",
          "Locations" => state[:paths].dup,
          "LibraryOptions" => { "PathInfos" => state[:paths].map { |path| { "Path" => path } } } },
        { "Name" => "Unmanaged", "ItemId" => unmanaged_id, "CollectionType" => "books",
          "Locations" => state[:unmanaged_paths].dup,
          "LibraryOptions" => { "PathInfos" => state[:unmanaged_paths].map { |path| { "Path" => path } } } }
      ]
      variables = {
        "jellyfin_api" => "http://127.0.0.1:#{port}",
        "jellyfin_client_header" => "MediaBrowser Fixture",
        "jellyfin_reconcile_token" => "admin-token",
        "jellyfin_libraries_before" => { "json" => libraries },
        "jellyfin_libraries" => [
          { "name" => "Movies", "collection_type" => "movies", "path" => "/media/Movies" }
        ],
        "jellyfin_library_options" => {}
      }
      stdout, stderr, status = run_playbook(tasks, variables)
      failures << "Jellyfin extra-path first failure unexpectedly succeeded" if attempt.zero? && status.success?
      failures << "Jellyfin extra-path retry failed: #{failure_tail(stdout + stderr)}" if
        attempt == 1 && !status.success?
    end
    failures << "Jellyfin desired library path was removed" unless state[:paths] == ["/media/Movies"]
    failures << "Jellyfin unmanaged library paths changed" unless state[:unmanaged_paths] == ["/media/Unmanaged"]
    removed = requests.select { |request| request["method"] == "DELETE" }.map do |request|
      URI.decode_www_form(URI("http://fixture#{request.fetch('target')}").query).to_h.fetch("path")
    end
    failures << "Jellyfin path removal targeted the desired or unmanaged path" unless
      removed.all? { |path| ["/media/Extra-A", "/media/Extra-B"].include?(path) }
  end
end

def exercise_jellyfin_primary_preflight(failures)
  main = YAML.safe_load_file(
    File.join(ROOT, "roles", "jellyfin", "tasks", "main.yml"), aliases: false
  )
  selected_names = [
    "Initialize Jellyfin primary administrator matches",
    "Resolve Jellyfin primary administrator matches",
    "Refuse ambiguous Jellyfin primary administrator identity",
    "Resolve the existing Jellyfin primary administrator",
    "Reconcile Jellyfin primary administrator identity"
  ]
  tasks = main.select { |task| selected_names.include?(task_name(task)) }
  tasks.find { |task| task_name(task) == "Reconcile Jellyfin primary administrator identity" }
       .fetch("ansible.builtin.include_tasks")
       .replace(File.join(ROOT, "roles", "jellyfin", "tasks", "primary_identity.yml"))
  primary_id = "a" * 32
  temporary_name = "nas-platform-admin-#{primary_id[0, 12]}"
  base = { "Id" => primary_id, "Configuration" => {},
           "Policy" => { "IsAdministrator" => true } }
  cases = [
    ["interrupted identity", [base.merge("Name" => temporary_name)], true, true],
    ["case-variant temporary identity",
     [base.merge("Name" => temporary_name.upcase)], false, false],
    ["whitespace-variant temporary identity",
     [base.merge("Name" => " #{temporary_name} ")], false, false],
    ["exact temporary identity with wrong ID",
     [base.merge("Id" => "b" * 32, "Name" => temporary_name)], false, false],
    ["temporary-name collision",
     [base.merge("Name" => "yonatan"),
      base.merge("Id" => "b" * 32, "Name" => temporary_name)], false, false]
  ]
  cases.each do |label, users, expected_success, expected_mutation|
    state = { name: (users.find { |user| user["Id"] == primary_id } || users.first).fetch("Name") }
    responder = lambda do |request|
      if request["method"] == "POST"
        state[:name] = request.fetch("json").fetch("Name")
        [204, nil]
      else
        [200, base.merge("Name" => state.fetch(:name))]
      end
    end
    Dir.mktmpdir("jellyfin-primary-preflight-") do |directory|
      with_http_service(responder) do |port, requests|
        variables = {
          "jellyfin_api" => "http://127.0.0.1:#{port}",
          "jellyfin_client_header" => "MediaBrowser Fixture",
          "jellyfin_reconcile_token" => "admin-token",
          "jellyfin_primary_users_before" => { "json" => users },
          "jellyfin_primary_authenticated_id" => primary_id,
          "jellyfin_primary_temporary_name" => temporary_name,
          "jellyfin_admin_username" => "Yonatan",
          "jellyfin_primary_recovery_marker" => File.join(directory, "recovery.json"),
          "jellyfin_primary_recovery_state" =>
            (label == "interrupted identity" ?
              { "id" => primary_id, "original_name" => "yonatan" } : {})
        }
        stdout, stderr, status = run_playbook(tasks, variables)
        failures << "Jellyfin #{label} preflight status differs: #{failure_tail(stdout + stderr)}" unless
          status.success? == expected_success
        mutations = requests.select { |request| %w[POST PUT PATCH DELETE].include?(request["method"]) }
        failures << "Jellyfin #{label} mutation behavior differs" unless
          mutations.any? == expected_mutation
      end
    end
  end
end

def exercise_jellyfin_library_shape_preflight(failures)
  main = YAML.safe_load_file(
    File.join(ROOT, "roles", "jellyfin", "tasks", "main.yml"), aliases: false
  )
  selected_names = [
    "Initialize Jellyfin primary administrator matches",
    "Resolve Jellyfin primary administrator matches",
    "Refuse ambiguous Jellyfin primary administrator identity",
    "Resolve the existing Jellyfin primary administrator",
    "Require complete Jellyfin server configuration",
    "Resolve Jellyfin server name repair requirement",
    "Require complete Jellyfin library preflight response",
    "Initialize normalized Jellyfin library inventory",
    "Resolve normalized Jellyfin library inventory",
    "Initialize Jellyfin managed library targets",
    "Resolve Jellyfin managed library targets",
    "Refuse unsafe Jellyfin managed library path representation",
    "Refuse ambiguous Jellyfin managed library ownership",
    "Reconcile Jellyfin primary administrator identity",
    "Update the Jellyfin server name"
  ]
  tasks = main.select { |task| selected_names.include?(task_name(task)) }
  tasks.find { |task| task_name(task) == "Reconcile Jellyfin primary administrator identity" }
       .fetch("ansible.builtin.include_tasks")
       .replace(File.join(ROOT, "roles", "jellyfin", "tasks", "primary_identity.yml"))
  primary_id = "a" * 32
  base_user = { "Id" => primary_id, "Name" => "yonatan", "Configuration" => {},
                "Policy" => { "IsAdministrator" => true } }
  desired = { "Name" => "Movies", "ItemId" => "1" * 32, "CollectionType" => "movies" }
  path_info = ->(path) { { "Path" => path } }
  verification_names = [
    "Initialize exact Jellyfin library inventory",
    "Resolve exact Jellyfin library inventory",
    "Verify exact Jellyfin owned state"
  ]
  verification_tasks = main.select { |task| verification_names.include?(task_name(task)) }
  shapes = {
    "Locations-only desired path" => [["/media/Movies"], [], false],
    "PathInfos-only desired path" => [[], [path_info.call("/media/Movies")], false],
    "duplicate desired Locations" => [
      ["/media/Movies", "/media/Movies/"], [path_info.call("/media/Movies")], false
    ],
    "duplicate desired PathInfos" => [
      ["/media/Movies"], [path_info.call("/media/Movies"), path_info.call("/media/Movies/")], false
    ],
    "mismatched extra paths" => [
      ["/media/Movies", "/media/Extra-A"],
      [path_info.call("/media/Movies"), path_info.call("/media/Extra-B")], false
    ],
    "fresh missing managed library" => [nil, nil, true],
    "valid managed shape with malformed unrelated library" => [
      ["/media/Movies"], [path_info.call("/media/Movies")], true
    ]
  }
  shapes.each do |label, (locations, path_infos, expected_success)|
    libraries = []
    unless locations.nil?
      libraries << desired.merge(
        "Locations" => locations,
        "LibraryOptions" => { "PathInfos" => path_infos }
      )
    end
    if label == "valid managed shape with malformed unrelated library"
      libraries << { "Name" => "Unmanaged", "ItemId" => "2" * 32,
                     "CollectionType" => "books", "Locations" => "opaque",
                     "LibraryOptions" => nil }
    end
    responder = lambda do |request|
      if request["target"].start_with?("/Users?")
        [204, nil]
      elsif request["target"].start_with?("/Users/")
        [200, base_user.merge("Name" => "Yonatan")]
      elsif request["target"] == "/System/Configuration"
        [204, nil]
      else
        [500, {}]
      end
    end
    Dir.mktmpdir("jellyfin-library-shape-") do |directory|
      with_http_service(responder) do |port, requests|
        variables = {
          "jellyfin_api" => "http://127.0.0.1:#{port}",
          "jellyfin_client_header" => "MediaBrowser Fixture",
          "jellyfin_reconcile_token" => "admin-token",
          "jellyfin_primary_users_before" => { "json" => [base_user] },
          "jellyfin_primary_authenticated_id" => primary_id,
          "jellyfin_primary_temporary_name" => "nas-platform-admin-#{primary_id[0, 12]}",
          "jellyfin_admin_username" => "Yonatan",
          "jellyfin_primary_recovery_marker" => File.join(directory, "recovery.json"),
          "jellyfin_primary_recovery_state" => {},
          "jellyfin_server_configuration_before" => { "json" => { "ServerName" => "Drifted" } },
          "jellyfin_server_name" => "Yonflix 2.0",
          "jellyfin_libraries_before" => { "json" => libraries },
          "jellyfin_libraries" => [
            { "name" => "Movies", "collection_type" => "movies", "path" => "/media/Movies" }
          ]
        }
        stdout, stderr, status = run_playbook(tasks, variables)
        failures << "Jellyfin #{label} preflight status differs: #{failure_tail(stdout + stderr)}" unless
          status.success? == expected_success
        mutations = requests.select { |request| %w[POST PUT PATCH DELETE].include?(request["method"]) }
        failures << "Jellyfin #{label} reached mutation before global preflight" if
          !expected_success && !mutations.empty?
        next unless label == "valid managed shape with malformed unrelated library" && status.success?

        verification_variables = variables.merge(
          "jellyfin_verified_libraries" => { "json" => libraries },
          "jellyfin_verified_users" => { "json" => [base_user.merge("Name" => "Yonatan")] },
          "jellyfin_verified_primary_user" => base_user.merge("Name" => "Yonatan"),
          "jellyfin_verified_server_configuration" => { "json" => { "ServerName" => "Yonflix 2.0" } },
          "jellyfin_verified_admin_avatar_state" => { "stat" => { "checksum" => JELLYFIN_AVATAR_SHA256 } },
          "jellyfin_admin_avatar_sha256" => JELLYFIN_AVATAR_SHA256,
          "jellyfin_library_options" => {}
        )
        verify_stdout, verify_stderr, verify_status = run_playbook(
          verification_tasks, verification_variables
        )
        failures << "Jellyfin malformed unrelated library broke exact verification: #{failure_tail(verify_stdout + verify_stderr)}" unless
          verify_status.success?
      end
    end
  end
end
