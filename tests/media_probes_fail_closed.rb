#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Fail-closed probes: a managed-user run must refuse rather than half-apply.
#
# Required by media_managed_users_test.rb, which owns the probe selection so the
# MEDIA_MANAGED_USERS_PROBES contract keeps naming one group rather than a file set.
# Fixtures and helpers come from media_managed_users_support.rb.

def exercise_komga_fail_closed(failures)
  managed = [{ "email" => "reader@example.invalid", "password" => "reader-secret",
               "roles" => ["PAGE_STREAMING"] }]
  variables = {
    "vault_komga_admin_email" => "admin@example.invalid",
    "vault_komga_admin_password" => "admin-secret",
    "vault_managed_komga_users" => managed
  }
  scenarios = {
    "incomplete listing" => lambda { |_request| [200, { "content" => [], "last" => false }] },
    "duplicate identity" => lambda do |_request|
      [200, [{ "id" => "one", "email" => "reader@example.invalid", "roles" => %w[USER KOBO_SYNC] },
             { "id" => "two", "email" => "reader@example.invalid", "roles" => %w[USER KOBO_SYNC] }]]
    end,
    "authentication failure" => lambda do |request|
      if request["target"] == "/api/v2/users"
        [200, [{ "id" => "reader", "email" => "reader@example.invalid", "roles" => %w[USER KOBO_SYNC] }]]
      else
        [401, {}]
      end
    end
  }
  scenarios.each do |label, responder|
    with_http_service(responder) do |port, requests|
      fixture_vars = variables.merge("komga_api" => "http://127.0.0.1:#{port}")
      stdout, stderr, status = run_playbook([includes_for("komga").first], fixture_vars)
      failures << "Komga #{label} fixture unexpectedly succeeded" if status.success?
      failures << "Komga #{label} fixture reached a mutation" if
        requests.any? { |request| %w[POST PATCH DELETE].include?(request["method"]) }
      failures << "Komga #{label} fixture did not fail in managed-user tasks: #{failure_tail(stdout + stderr)}" unless
        (stdout + stderr).include?("roles/komga/tasks/managed_users.yml")
    end
  end
end

def exercise_media_fail_closed(failures)
  jellyfin_policy = {
    "AuthenticationProviderId" => "DefaultAuthenticationProvider",
    "PasswordResetProviderId" => "DefaultPasswordResetProvider",
    "IsAdministrator" => false
  }
  cases = [
    ["Audiobookshelf", "audiobookshelf",
     { "vault_managed_audiobookshelf_users" => [
       { "username" => "reader", "password" => "wrong", "type" => "user",
         "is_active" => true,
         "permissions" => { "flags" => { "accessAllLibraries" => false },
                              "librariesAccessible" => [], "itemTagsSelected" => [] } }
     ] },
     lambda do |request|
       request["target"] == "/api/users" ?
         [200, { "users" => [{ "id" => "reader", "username" => "reader", "type" => "user",
                               "isActive" => true, "permissions" => { "accessAllLibraries" => false },
                               "librariesAccessible" => [], "itemTagsSelected" => [] }] }] : [401, {}]
     end],
    ["Jellyfin", "jellyfin",
     { "jellyfin_client_header" => "MediaBrowser Fixture",
       "vault_managed_jellyfin_users" => [
         { "username" => "reader", "password" => "wrong",
           "policy" => { "IsAdministrator" => false } }
       ] },
     lambda do |request|
       request["target"] == "/Users" ?
         [200, [{ "Id" => "a" * 32, "Name" => "reader", "Policy" => jellyfin_policy }]] : [401, {}]
     end]
  ]
  cases.each do |label, service, variables, responder|
    with_http_service(responder) do |port, requests|
      variables["#{service}_api"] = "http://127.0.0.1:#{port}"
      stdout, stderr, status = run_playbook(
        [includes_for(service, service == "audiobookshelf" ? "fixture-token" : "admin-token").first],
        variables
      )
      failures << "#{label} authentication-failure fixture unexpectedly succeeded" if status.success?
      failures << "#{label} authentication failure reached a mutation" if
        requests.any? { |request| %w[PATCH DELETE].include?(request["method"]) ||
          (request["method"] == "POST" && !request["target"].match?(/login|AuthenticateByName/)) }
      failures << "#{label} authentication failure did not stop at preserved credential assertion" unless
        (stdout + stderr).include?("Require preserved #{label} managed-user credentials")
    end
  end
end

def exercise_media_listing_fail_closed(failures)
  cases = [
    ["Audiobookshelf incomplete listing", "audiobookshelf",
     { "vault_managed_audiobookshelf_users" => [
       { "username" => "reader", "password" => "secret", "type" => "user",
         "is_active" => true,
         "permissions" => { "flags" => {}, "librariesAccessible" => [], "itemTagsSelected" => [] } }
     ] },
     ->(_request) { [200, { "users" => [], "hasMore" => true }] }],
    ["Audiobookshelf normalized duplicate", "audiobookshelf",
     { "vault_managed_audiobookshelf_users" => [
       { "username" => "reader", "password" => "secret", "type" => "user",
         "is_active" => true,
         "permissions" => { "flags" => {}, "librariesAccessible" => [], "itemTagsSelected" => [] } }
     ] },
     lambda do |_request|
       [200, { "users" => [
         { "id" => "one", "username" => "reader" },
         { "id" => "two", "username" => "Reader" }
       ] }]
     end],
    ["Jellyfin unsupported listing", "jellyfin",
     { "jellyfin_client_header" => "MediaBrowser Fixture",
       "vault_managed_jellyfin_users" => [
         { "username" => "reader", "password" => "secret",
           "policy" => { "IsAdministrator" => false } }
       ] },
     ->(_request) { [200, { "Items" => [], "TotalRecordCount" => 1 }] }],
    ["Jellyfin normalized duplicate", "jellyfin",
     { "jellyfin_client_header" => "MediaBrowser Fixture",
       "vault_managed_jellyfin_users" => [
         { "username" => "reader", "password" => "secret",
           "policy" => { "IsAdministrator" => false } }
       ] },
     lambda do |_request|
       [200, [{ "Id" => "a" * 32, "Name" => "reader" },
              { "Id" => "b" * 32, "Name" => "Reader" }]]
     end]
  ]
  cases.each do |label, service, variables, responder|
    with_http_service(responder) do |port, requests|
      variables["#{service}_api"] = "http://127.0.0.1:#{port}"
      _stdout, _stderr, status = run_playbook(
        [includes_for(service, service == "audiobookshelf" ? "fixture-token" : "admin-token").first],
        variables
      )
      failures << "#{label} fixture unexpectedly succeeded" if status.success?
      failures << "#{label} fixture reached a mutation" if
        requests.any? { |request| %w[POST PATCH DELETE].include?(request["method"]) }
    end
  end
end

def exercise_post_create_credential_failures(failures)
  cases = [
    ["Audiobookshelf", "audiobookshelf", "fixture-token",
     { "vault_managed_audiobookshelf_users" => [
       { "username" => "new-reader", "password" => "expected-secret", "type" => "user",
         "is_active" => true,
         "permissions" => { "flags" => { "accessAllLibraries" => false },
                              "librariesAccessible" => [], "itemTagsSelected" => [] } }
     ] },
     lambda do |request, users|
       case [request["method"], request["target"]]
       when ["GET", "/api/users"] then [200, { "users" => users }]
       when ["POST", "/api/users"]
         users << request.fetch("json").reject { |key, _| key == "password" }.merge("id" => "created")
         [200, users.last]
       when ["POST", "/login"] then [401, {}]
       else [500, {}]
       end
     end],
    ["Jellyfin", "jellyfin", "admin-token",
     { "jellyfin_client_header" => "MediaBrowser Fixture",
       "vault_managed_jellyfin_users" => [
         { "username" => "new-reader", "password" => "expected-secret",
           "policy" => { "IsAdministrator" => true } }
       ] },
     lambda do |request, users|
       case [request["method"], request["target"]]
       when ["GET", "/Users"] then [200, users]
       when ["POST", "/Users/New"]
         users << { "Id" => "c" * 32, "Name" => "new-reader",
                    "Policy" => { "AuthenticationProviderId" => "auth",
                                  "PasswordResetProviderId" => "reset",
                                  "IsAdministrator" => false } }
         [200, users.last]
       when ["POST", "/Users/AuthenticateByName"] then [401, {}]
       when ["POST", "/Users/#{'c' * 32}/Policy"] then [204, nil]
       else [500, {}]
       end
     end],
    ["Komga", "komga", nil,
     { "vault_komga_admin_email" => "admin@example.invalid",
       "vault_komga_admin_password" => "admin-secret",
       "vault_managed_komga_users" => [
         { "email" => "new@example.invalid", "password" => "expected-secret", "roles" => ["ADMIN"] }
       ] },
     lambda do |request, users|
       case [request["method"], request["target"]]
       when ["GET", "/api/v2/users"] then [200, users]
       when ["POST", "/api/v2/users"]
         users << { "id" => "created", "email" => "new@example.invalid", "roles" => %w[USER ADMIN] }
         [201, users.last]
       when ["GET", "/api/v2/users/me"] then [401, {}]
       else [500, {}]
       end
     end]
  ]
  cases.each do |label, service, token, variables, behavior|
    users = []
    responder = ->(request) { behavior.call(request, users) }
    with_http_service(responder) do |port, requests|
      variables["#{service}_api"] = "http://127.0.0.1:#{port}"
      stdout, stderr, status = run_playbook(includes_for(service, token), variables)
      failures << "#{label} mangled-created-password fixture unexpectedly succeeded" if status.success?
      failures << "#{label} mangled-created-password fixture omitted migration guidance assertion" unless
        (stdout + stderr).include?("Require newly created #{label} managed-user credentials")
      failures << "#{label} mangled-created-password fixture reached a privilege repair" if
        requests.any? { |request| request["method"] == "PATCH" || request["target"].end_with?("/Policy") }
    end
  end
end

def exercise_disabled_target_rejection(failures)
  example = YAML.safe_load_file(
    File.join(ROOT, "inventory", "group_vars", "all", "vault.yml.example"), aliases: false
  )
  cases = [
    ["Audiobookshelf", "audiobookshelf", "fixture-token", lambda do |vault|
      vault.dig("vault_managed_users", "audiobookshelf", 0)["is_active"] = false
    end],
    ["Jellyfin", "jellyfin", "admin-token", lambda do |vault|
      vault.dig("vault_managed_users", "jellyfin", 0, "policy")["IsDisabled"] = true
    end]
  ]
  cases.each do |label, service, token, mutate|
    variables = Marshal.load(Marshal.dump(example))
    mutate.call(variables)
    with_http_service(->(_request) { [500, {}] }) do |port, requests|
      variables["#{service}_api"] = "http://127.0.0.1:#{port}"
      variables["jellyfin_client_header"] = "MediaBrowser Fixture" if service == "jellyfin"
      tasks = [
        { "name" => "Validate managed-user vault fixture",
          "ansible.builtin.include_role" => { "name" => "vault_contract" } },
        includes_for(service, token).first
      ]
      _stdout, _stderr, status = run_playbook(tasks, variables)
      failures << "#{label} disabled target unexpectedly passed vault validation" if status.success?
      failures << "#{label} disabled target reached the service API" unless requests.empty?
    end
  end
end
