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

def exercise_jellyfin_library_inventory_global_gate(failures)
  main = YAML.safe_load_file(
    File.join(ROOT, "roles", "jellyfin", "tasks", "main.yml"), aliases: false
  )
  mutation_names = [
    "Rename adopted Jellyfin managed libraries",
    "Create absent Jellyfin managed libraries",
    "Remove extra paths from Jellyfin managed libraries",
    "Repair Jellyfin managed library options"
  ]
  tasks = [
    jellyfin_library_inventory_include(
      "Validate fixture Jellyfin library inventory", "{{ jellyfin_libraries_before.json }}"
    )
  ] + main.select { |task| mutation_names.include?(task_name(task)) }
  library = lambda do |name:, id:, collection_type:, path:|
    {
      "Name" => name, "ItemId" => id, "CollectionType" => collection_type,
      "Locations" => [path],
      "LibraryOptions" => {
        "PathInfos" => [{ "Path" => path }], "EnableRealtimeMonitor" => false
      }
    }
  end
  movies = library.call(
    name: "Movies Drifted", id: "1" * 32, collection_type: "movies", path: "/media/Movies"
  )
  shows = library.call(
    name: "Shows", id: "2" * 32, collection_type: "tvshows", path: "/media/Series"
  )
  cases = {
    "mapping response" => {},
    "string response" => "opaque",
    "duplicate ItemId" => [movies, shows.merge("ItemId" => movies.fetch("ItemId"))],
    "non-string ItemId" => [movies.merge("ItemId" => 7), shows],
    "duplicate current name" => [movies.merge("Name" => "Legacy"), shows.merge("Name" => "Legacy")],
    "empty current name" => [movies.merge("Name" => ""), shows],
    "non-string current name" => [movies.merge("Name" => 7), shows],
    "unsafe current name" => [movies.merge("Name" => "Movies\u0001Drifted"), shows]
  }
  responder = ->(_request) { [204, nil] }
  with_http_service(responder) do |port, requests|
    cases.each do |label, inventory|
      boundary = requests.length
      variables = {
        "jellyfin_api" => "http://127.0.0.1:#{port}",
        "jellyfin_client_header" => "MediaBrowser Fixture",
        "jellyfin_reconcile_token" => "admin-token",
        "jellyfin_libraries_before" => { "json" => inventory },
        "jellyfin_libraries" => [
          { "name" => "Movies", "collection_type" => "movies", "path" => "/media/Movies" },
          { "name" => "Shows", "collection_type" => "tvshows", "path" => "/media/Series" }
        ],
        "jellyfin_library_options" => { "EnableRealtimeMonitor" => true }
      }
      stdout, stderr, status = run_playbook(tasks, variables)
      failures << "Jellyfin #{label} inventory was accepted: #{failure_tail(stdout + stderr)}" if
        status.success?
      mutations = requests.drop(boundary).select do |request|
        %w[POST PUT PATCH DELETE].include?(request["method"])
      end
      failures << "Jellyfin #{label} inventory reached mutation" unless mutations.empty?
    end
  end
end

def exercise_jellyfin_library_rename_identity_refresh(failures)
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
    "Wait for renamed Jellyfin managed library identities",
    "Refresh Jellyfin managed library targets after renames",
    "Refuse unsafe refreshed Jellyfin managed library identity",
    "Revalidate complete Jellyfin library inventory after renames",
    "Create absent Jellyfin managed libraries",
    "Remove extra paths from Jellyfin managed libraries",
    "Repair Jellyfin managed library options"
  ]
  tasks = main.select { |task| selected_names.include?(task_name(task)) }
  tasks.find { |task| task_name(task) == "Revalidate complete Jellyfin library inventory after renames" }
       .fetch("ansible.builtin.include_tasks")
       .replace(File.join(ROOT, "roles", "jellyfin", "tasks", "library_inventory.yml"))
  tasks.unshift(
    jellyfin_library_inventory_include(
      "Validate fixture Jellyfin library inventory", "{{ jellyfin_libraries_before.json }}"
    )
  )
  old_id = "1" * 32
  new_id = "2" * 32
  shows_id = "3" * 32
  old_library = {
    "Name" => "Movies Drifted", "ItemId" => old_id, "CollectionType" => "movies",
    "Locations" => ["/media/Movies"],
    "LibraryOptions" => {
      "PathInfos" => [{ "Path" => "/media/Movies" }], "EnableRealtimeMonitor" => false
    }
  }
  new_library = Marshal.load(Marshal.dump(old_library)).merge(
    "Name" => "Movies", "ItemId" => new_id
  )
  shows_library = {
    "Name" => "Shows", "ItemId" => shows_id, "CollectionType" => "tvshows",
    "Locations" => ["/media/Series"],
    "LibraryOptions" => {
      "PathInfos" => [{ "Path" => "/media/Series" }], "EnableRealtimeMonitor" => false
    }
  }
  incomplete_shows_library = {
    "Name" => "Shows", "CollectionType" => "tvshows", "Locations" => ["/media/Series"]
  }
  state = {
    renamed: false, rename_refresh: false, observations: 0, refreshed_libraries: nil,
    premature_post_rename_mutation: false
  }
  responder = lambda do |request|
    uri = URI("http://fixture#{request.fetch('target')}")
    if state[:renamed] && state[:observations] == 1 &&
       %w[POST PUT PATCH DELETE].include?(request["method"])
      state[:premature_post_rename_mutation] = true
    end
    case [request["method"], uri.path]
    when ["POST", "/Library/VirtualFolders/Name"]
      state[:renamed] = true
      state[:rename_refresh] = URI.decode_www_form(uri.query).to_h["refreshLibrary"] == "true"
      [204, nil]
    when ["GET", "/Library/VirtualFolders"]
      state[:observations] += 1
      observed = if state[:refreshed_libraries]
                   state[:refreshed_libraries]
                 elsif state[:rename_refresh] && state[:observations] > 1
                   [new_library, shows_library]
                 else
                   [new_library, incomplete_shows_library]
                 end
      [200, observed]
    when ["POST", "/Library/VirtualFolders/LibraryOptions"]
      repaired = { new_id => new_library, shows_id => shows_library }[request.dig("json", "Id")]
      if repaired
        repaired["LibraryOptions"] = request.fetch("json").fetch("LibraryOptions")
        [204, nil]
      else
        [404, {}]
      end
    else
      [500, {}]
    end
  end
  with_http_service(responder) do |port, requests|
    variables = {
      "jellyfin_api" => "http://127.0.0.1:#{port}",
      "jellyfin_client_header" => "MediaBrowser Fixture",
      "jellyfin_reconcile_token" => "admin-token",
      "jellyfin_libraries_before" => { "json" => [old_library, shows_library] },
      "jellyfin_libraries" => [
        { "name" => "Movies", "collection_type" => "movies", "path" => "/media/Movies" },
        { "name" => "Shows", "collection_type" => "tvshows", "path" => "/media/Series" }
      ],
      "jellyfin_library_options" => { "EnableRealtimeMonitor" => true }
    }
    stdout, stderr, status = run_playbook(tasks, variables)
    failures << "Jellyfin renamed-library identity refresh failed: #{failure_tail(stdout + stderr)}" unless
      status.success?
    option_ids = requests.filter_map do |request|
      request.dig("json", "Id") if
        request["method"] == "POST" && request["target"] == "/Library/VirtualFolders/LibraryOptions"
    end
    failures << "Jellyfin renamed/skipped target rebuilding used wrong ItemIds" unless
      option_ids == [new_id, shows_id]
    failures << "Jellyfin mixed renamed/skipped inventory recreated an existing library" if
      requests.any? { |request| request["method"] == "POST" &&
        URI("http://fixture#{request.fetch('target')}").path == "/Library/VirtualFolders" }
    failures << "Jellyfin renamed-library identity was not polled to completion" unless
      state[:renamed] && state[:rename_refresh] && state[:observations] >= 2
    failures << "Jellyfin mutated library state before the full rename inventory settled" if
      state[:premature_post_rename_mutation]

    persistent_tasks = Marshal.load(Marshal.dump(tasks))
    persistent_wait = persistent_tasks.find do |task|
      task_name(task) == "Wait for renamed Jellyfin managed library identities"
    end
    persistent_wait["retries"] = 2
    persistent_wait["delay"] = 0
    persistent_rename = persistent_tasks.find do |task|
      task_name(task) == "Rename adopted Jellyfin managed libraries"
    end
    persistent_rename.fetch("ansible.builtin.uri")["url"] =
      persistent_rename.dig("ansible.builtin.uri", "url").sub("refreshLibrary=true", "refreshLibrary=false")
    state.update(
      renamed: false,
      rename_refresh: false,
      observations: 0,
      refreshed_libraries: nil,
      premature_post_rename_mutation: false
    )
    persistent_boundary = requests.length
    persistent_stdout, persistent_stderr, persistent_status =
      run_playbook(persistent_tasks, variables)
    failures << "Jellyfin persistent incomplete sibling did not time out: #{failure_tail(persistent_stdout + persistent_stderr)}" if
      persistent_status.success?
    persistent_mutations = requests.drop(persistent_boundary).select do |request|
      %w[POST PUT PATCH DELETE].include?(request["method"]) &&
        URI("http://fixture#{request.fetch('target')}").path != "/Library/VirtualFolders/Name"
    end
    failures << "Jellyfin persistent incomplete sibling reached a post-rename mutation" unless
      persistent_mutations.empty?

    unsafe_libraries = {
      "empty path" => {
        "Name" => "Unmanaged", "ItemId" => "3" * 32, "CollectionType" => "books",
        "Locations" => [""], "LibraryOptions" => { "PathInfos" => [{ "Path" => "" }] }
      },
      "slash-only path" => {
        "Name" => "Unmanaged", "ItemId" => "3" * 32, "CollectionType" => "books",
        "Locations" => ["/"], "LibraryOptions" => { "PathInfos" => [{ "Path" => "/" }] }
      },
      "non-string path" => {
        "Name" => "Unmanaged", "ItemId" => "3" * 32, "CollectionType" => "books",
        "Locations" => [7], "LibraryOptions" => { "PathInfos" => [{ "Path" => 7 }] }
      },
      "malformed unrelated entry" => {
        "Name" => "Unmanaged", "ItemId" => "3" * 32, "CollectionType" => "books",
        "Locations" => "opaque", "LibraryOptions" => nil
      },
      "normalized cross-library duplicate" => {
        "Name" => "Unmanaged", "ItemId" => "3" * 32, "CollectionType" => "books",
        "Locations" => ["/media/Movies/"],
        "LibraryOptions" => { "PathInfos" => [{ "Path" => "/media/Movies/" }] }
      },
      "inconsistent PathInfos" => {
        "Name" => "Unmanaged", "ItemId" => "3" * 32, "CollectionType" => "books",
        "Locations" => ["/media/Unmanaged"],
        "LibraryOptions" => { "PathInfos" => [{ "Path" => "/media/Different" }] }
      },
      "raw trailing-slash representation mismatch" => {
        "Name" => "Unmanaged", "ItemId" => "3" * 32, "CollectionType" => "books",
        "Locations" => ["/media/Unmanaged"],
        "LibraryOptions" => { "PathInfos" => [{ "Path" => "/media/Unmanaged/" }] }
      }
    }
    unsafe_tasks = Marshal.load(Marshal.dump(tasks))
    rename_index = unsafe_tasks.index do |task|
      task_name(task) == "Rename adopted Jellyfin managed libraries"
    end
    unsafe_tasks[rename_index] = {
      "name" => "Record fixture Jellyfin library rename",
      "ansible.builtin.debug" => { "msg" => "fixture rename already completed" },
      "changed_when" => true,
      "register" => "jellyfin_library_renames"
    }
    unsafe_wait = unsafe_tasks.find do |task|
      task_name(task) == "Wait for renamed Jellyfin managed library identities"
    end
    unsafe_wait["retries"] = 2
    unsafe_wait["delay"] = 0
    unsafe_libraries.each do |label, unsafe_library|
      drifted_target = Marshal.load(Marshal.dump(new_library))
      drifted_target["LibraryOptions"]["EnableRealtimeMonitor"] = false
      state.update(
        renamed: false,
        rename_refresh: false,
        observations: 0,
        refreshed_libraries: [drifted_target, shows_library, unsafe_library],
        premature_post_rename_mutation: false
      )
      request_boundary = requests.length
      unsafe_stdout, unsafe_stderr, unsafe_status = run_playbook(unsafe_tasks, variables)
      failures << "Jellyfin refreshed #{label} was accepted: #{failure_tail(unsafe_stdout + unsafe_stderr)}" if
        unsafe_status.success?
      unsafe_mutations = requests.drop(request_boundary).select do |request|
        %w[POST PUT PATCH DELETE].include?(request["method"])
      end
      failures << "Jellyfin refreshed #{label} reached mutation" unless unsafe_mutations.empty?
    end
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
  tasks.unshift(
    jellyfin_library_inventory_include(
      "Validate fixture Jellyfin library inventory", "{{ jellyfin_libraries_before.json }}"
    )
  )
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
    "Refresh Jellyfin server configuration before name update",
    "Require complete refreshed Jellyfin server configuration",
    "Update the Jellyfin server name"
  ]
  tasks = main.select { |task| selected_names.include?(task_name(task)) }
  inventory_index = tasks.index do |task|
    task_name(task) == "Reconcile Jellyfin primary administrator identity"
  end
  tasks.insert(
    inventory_index,
    jellyfin_library_inventory_include(
      "Validate fixture Jellyfin library inventory", "{{ jellyfin_libraries_before.json }}"
    )
  )
  tasks.find { |task| task_name(task) == "Reconcile Jellyfin primary administrator identity" }
       .fetch("ansible.builtin.include_tasks")
       .replace(File.join(ROOT, "roles", "jellyfin", "tasks", "primary_identity.yml"))
  primary_id = "a" * 32
  base_user = { "Id" => primary_id, "Name" => "yonatan", "Configuration" => {},
                "Policy" => { "IsAdministrator" => true } }
  desired = { "Name" => "Movies", "ItemId" => "1" * 32, "CollectionType" => "movies" }
  path_info = ->(path) { { "Path" => path } }
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
      ["/media/Movies"], [path_info.call("/media/Movies")], false
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
        request["method"] == "GET" ? [200, { "ServerName" => "Drifted" }] : [204, nil]
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
      end
    end
  end
end
