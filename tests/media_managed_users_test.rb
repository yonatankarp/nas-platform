#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "json"
require "open3"
require "socket"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)
SERVICES = %w[audiobookshelf jellyfin komga].freeze
VALIDATE_POLICY = File.join(ROOT, "tests", "validate-policy.sh")

REQUIRED_TASKS = {
  "audiobookshelf" => [
    "List complete Audiobookshelf users for managed-user reconciliation",
    "Refuse incomplete Audiobookshelf managed-user listing",
    "Refuse ambiguous normalized Audiobookshelf managed identities",
    "Authenticate existing Audiobookshelf managed users",
    "Require preserved Audiobookshelf managed-user credentials",
    "Create absent Audiobookshelf managed users",
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
    "Repair Komga managed-user roles",
    "Verify exact Komga managed users"
  ]
}.freeze

def task_name(task)
  task.fetch("name", "")
end

def uri_task?(task)
  task.key?("ansible.builtin.uri")
end

def command_available?(name)
  ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
    File.executable?(File.join(directory, name))
  end
end

def run_playbook(tasks, variables, *arguments)
  Dir.mktmpdir("nas-platform-media-managed-users-") do |directory|
    playbook = File.join(directory, "playbook.yml")
    File.write(
      playbook,
      YAML.dump([{ "hosts" => "localhost", "gather_facts" => false,
                   "vars" => variables, "tasks" => tasks }]),
      mode: "w", perm: 0o600
    )
    Open3.capture3(
      { "ANSIBLE_NOCOLOR" => "1" }, "ansible-playbook", "-i", "localhost,",
      "-c", "local", playbook, *arguments, chdir: ROOT
    )
  end
end

def with_http_service(responder)
  server = TCPServer.new("127.0.0.1", 0)
  requests = []
  stopped = false
  error = nil
  thread = Thread.new do
    until stopped
      next unless IO.select([server], nil, nil, 0.05)

      client = server.accept
      method, target, = client.gets.to_s.strip.split(" ", 3)
      headers = {}
      while (line = client.gets)
        line = line.chomp
        break if line == "\r" || line.empty?

        key, value = line.split(":", 2)
        headers[key.downcase] = value.to_s.strip
      end
      body = client.read(headers.fetch("content-length", "0").to_i)
      request = { "method" => method, "target" => target, "headers" => headers,
                  "json" => body.empty? ? nil : JSON.parse(body) }
      requests << request
      status, response = responder.call(request)
      payload = response.nil? ? "" : JSON.generate(response)
      reason = { 200 => "OK", 201 => "Created", 204 => "No Content",
                 401 => "Unauthorized" }.fetch(status, "Error")
      client.write("HTTP/1.1 #{status} #{reason}\r\n")
      client.write("Content-Type: application/json\r\n") unless payload.empty?
      client.write("Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      client.close
    end
  rescue IOError, Errno::EBADF
    nil
  rescue StandardError => caught
    error = caught
  end
  yield server.addr.fetch(1), requests
ensure
  stopped = true
  server&.close
  thread&.join
  raise error if error
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

def basic_identity(request)
  encoded = request.fetch("headers").fetch("authorization", "").delete_prefix("Basic ")
  Base64.decode64(encoded).split(":", 2).first
end

def failure_tail(output)
  output.lines.map(&:strip).reject(&:empty?).last(8).join(" | ")
end

def exercise_audiobookshelf(failures)
  default_permissions = {
    "download" => true, "update" => false, "delete" => false, "upload" => false,
    "createEreader" => false, "accessAllLibraries" => true, "accessAllTags" => true,
    "accessExplicitContent" => false, "selectedTagsNotAccessible" => false
  }
  users = [
    { "id" => "abs-reader", "username" => "reader", "type" => "guest",
      "isActive" => false, "permissions" => default_permissions.dup,
      "librariesAccessible" => ["legacy-library"], "itemTagsSelected" => ["legacy-tag"] },
    { "id" => "abs-unmanaged", "username" => "friend", "type" => "user",
      "isActive" => true, "permissions" => default_permissions.dup,
      "librariesAccessible" => [], "itemTagsSelected" => [] }
  ]
  managed = [
    { "username" => "reader", "password" => "reader-secret", "type" => "user",
      "is_active" => true,
      "permissions" => { "flags" => { "accessAllLibraries" => false },
                           "librariesAccessible" => ["library-a"],
                           "itemTagsSelected" => ["tag-a"] } },
    { "username" => "new-reader", "password" => "new-secret", "type" => "guest",
      "is_active" => true,
      "permissions" => { "flags" => { "accessAllLibraries" => false },
                           "librariesAccessible" => [], "itemTagsSelected" => [] } }
  ]
  responder = lambda do |request|
    case [request["method"], request["target"]]
    when ["GET", "/api/users"] then [200, { "users" => users }]
    when ["POST", "/login"]
      body = request.fetch("json")
      body == { "username" => "reader", "password" => "reader-secret" } ?
        [200, { "user" => { "username" => "reader" } }] : [401, {}]
    when ["POST", "/api/users"]
      body = request.fetch("json")
      users << body.reject { |key, _| key == "password" }
                   .merge("id" => "abs-created",
                          "permissions" => default_permissions.merge(body.fetch("permissions")))
      [200, users.last]
    when ["PATCH", "/api/users/abs-reader"]
      body = request.fetch("json")
      users[0].merge!(body.reject { |key, _| key == "permissions" })
      users[0]["permissions"].merge!(body.fetch("permissions"))
      [200, users[0]]
    else [500, {}]
    end
  end
  with_http_service(responder) do |port, requests|
    variables = {
      "audiobookshelf_api" => "http://127.0.0.1:#{port}",
      "vault_managed_audiobookshelf_users" => managed
    }
    stdout, stderr, status = run_playbook(includes_for("audiobookshelf", "fixture-token"), variables)
    failures << "Audiobookshelf behavior fixture failed: #{failure_tail(stdout + stderr)}" unless status.success?
    patch = requests.find { |request| request["method"] == "PATCH" }
    failures << "Audiobookshelf repair payload is not non-secret and exact" unless
      patch && patch["json"].keys.sort == %w[isActive itemTagsSelected librariesAccessible permissions type]
    failures << "Audiobookshelf repair did not split pinned array fields" unless
      patch&.dig("json", "permissions") == { "accessAllLibraries" => false } &&
        patch&.dig("json", "librariesAccessible") == ["library-a"] &&
        patch&.dig("json", "itemTagsSelected") == ["tag-a"]
    failures << "Audiobookshelf repair overwrote an undeclared expanded permission" unless
      users[0].dig("permissions", "download") == true
    failures << "Audiobookshelf absent creation omitted its initial password" unless
      requests.any? { |request| request["target"] == "/api/users" &&
        request["method"] == "POST" && request.dig("json", "password") == "new-secret" }
    failures << "Audiobookshelf unmanaged user was not preserved" unless
      users.any? { |user| user["username"] == "friend" }
    failures << "Audiobookshelf final verification did not re-list users" unless
      requests.count { |request| request["target"] == "/api/users" && request["method"] == "GET" } == 2
  end
end

def exercise_jellyfin(failures)
  default_policy = {
    "AuthenticationProviderId" => "Jellyfin.Server.Implementations.Users.DefaultAuthenticationProvider",
    "PasswordResetProviderId" => "Jellyfin.Server.Implementations.Users.DefaultPasswordResetProvider",
    "IsAdministrator" => false, "EnableAllFolders" => true,
    "IsHidden" => true, "EnableMediaPlayback" => true
  }
  users = [
    { "Id" => "a" * 32, "Name" => "reader",
      "Policy" => default_policy.dup },
    { "Id" => "b" * 32, "Name" => "friend", "Policy" => default_policy.dup }
  ]
  managed = [
    { "username" => "reader", "password" => "reader-secret",
      "policy" => { "IsAdministrator" => false, "EnableAllFolders" => false } },
    { "username" => "new-reader", "password" => "new-secret",
      "policy" => { "IsAdministrator" => false, "EnableAllFolders" => false } }
  ]
  responder = lambda do |request|
    case [request["method"], request["target"]]
    when ["GET", "/Users"] then [200, users]
    when ["POST", "/Users/New"]
      body = request.fetch("json")
      created = { "Id" => "c" * 32, "Name" => body.fetch("Name"), "Policy" => default_policy.dup }
      users << created
      [200, created]
    when ["POST", "/Users/#{'c' * 32}/Policy"]
      body = request.fetch("json")
      required = %w[AuthenticationProviderId PasswordResetProviderId]
      next [400, {}] unless body.keys.sort == users[2]["Policy"].keys.sort &&
                            required.all? { |key| !body[key].to_s.empty? }
      users[2]["Policy"] = body
      [204, nil]
    when ["POST", "/Users/AuthenticateByName"]
      body = request.fetch("json")
      body == { "Username" => "reader", "Pw" => "reader-secret" } ?
        [200, { "User" => users[0], "AccessToken" => "reader-token" }] : [401, {}]
    when ["POST", "/Users/#{'a' * 32}/Policy"]
      body = request.fetch("json")
      required = %w[AuthenticationProviderId PasswordResetProviderId]
      next [400, {}] unless body.keys.sort == users[0]["Policy"].keys.sort &&
                            required.all? { |key| !body[key].to_s.empty? }
      users[0]["Policy"] = body
      [204, nil]
    else [500, {}]
    end
  end
  with_http_service(responder) do |port, requests|
    variables = {
      "jellyfin_api" => "http://127.0.0.1:#{port}", "jellyfin_client_header" => "MediaBrowser Fixture",
      "vault_managed_jellyfin_users" => managed
    }
    stdout, stderr, status = run_playbook(includes_for("jellyfin", "admin-token"), variables)
    failures << "Jellyfin behavior fixture failed: #{failure_tail(stdout + stderr)}" unless status.success?
    create = requests.find { |request| request["target"] == "/Users/New" }
    failures << "Jellyfin absent creation omitted its initial password" unless
      create&.dig("json") == { "Name" => "new-reader", "Password" => "new-secret" }
    policy_requests = requests.select { |request| request["target"].end_with?("/Policy") }
    failures << "Jellyfin policy update contains a secret field" unless policy_requests.all? do |request|
      request.fetch("json").keys.none? do |key|
        key != "PasswordResetProviderId" && key.match?(/password|secret|token/i)
      end
    end
    failures << "Jellyfin complete policy update did not preserve provider IDs" unless
      policy_requests.all? do |request|
        request.dig("json", "AuthenticationProviderId") == default_policy["AuthenticationProviderId"] &&
          request.dig("json", "PasswordResetProviderId") == default_policy["PasswordResetProviderId"]
      end
    failures << "Jellyfin complete policy update reset undeclared policy state" unless
      users[0].dig("Policy", "IsHidden") == true && users[2].dig("Policy", "EnableMediaPlayback") == true
    failures << "Jellyfin unmanaged user was not preserved" unless users.any? { |user| user["Name"] == "friend" }
    failures << "Jellyfin final verification did not re-list users" unless
      requests.count { |request| request["target"] == "/Users" } == 3
  end
end

def exercise_komga(failures)
  supported_roles = %w[ADMIN FILE_DOWNLOAD PAGE_STREAMING KOBO_SYNC KOREADER_SYNC]
  users = [
    { "id" => "komga-reader", "email" => "reader@example.invalid", "roles" => %w[USER KOBO_SYNC] },
    { "id" => "komga-friend", "email" => "friend@example.invalid", "roles" => %w[USER KOBO_SYNC] }
  ]
  managed = [
    { "email" => "reader@example.invalid", "password" => "reader-secret",
      "roles" => ["PAGE_STREAMING"] },
    { "email" => "new@example.invalid", "password" => "new-secret", "roles" => ["KOREADER_SYNC"] }
  ]
  responder = lambda do |request|
    case [request["method"], request["target"]]
    when ["GET", "/api/v2/users"] then [200, users]
    when ["GET", "/api/v2/users/me"]
      basic_identity(request) == "reader@example.invalid" ? [200, users[0]] : [401, {}]
    when ["POST", "/api/v2/users"]
      body = request.fetch("json")
      users << body.reject { |key, _| key == "password" }
                   .merge("id" => "komga-created",
                          "roles" => body.fetch("roles").intersection(supported_roles) + ["USER"])
      [201, users.last]
    when ["PATCH", "/api/v2/users/komga-reader"]
      users[0]["roles"] = request.fetch("json").fetch("roles").intersection(supported_roles) + ["USER"]
      [204, nil]
    else [500, {}]
    end
  end
  with_http_service(responder) do |port, requests|
    variables = {
      "komga_api" => "http://127.0.0.1:#{port}", "vault_komga_admin_email" => "admin@example.invalid",
      "vault_komga_admin_password" => "admin-secret", "vault_managed_komga_users" => managed
    }
    stdout, stderr, status = run_playbook(includes_for("komga"), variables)
    failures << "Komga behavior fixture failed: #{failure_tail(stdout + stderr)}" unless status.success?
    patch = requests.find { |request| request["method"] == "PATCH" }
    failures << "Komga repair payload is not roles-only" unless patch&.dig("json") == { "roles" => ["PAGE_STREAMING"] }
    create = requests.find { |request| request["method"] == "POST" }
    failures << "Komga absent creation omitted its initial password" unless create&.dig("json", "password") == "new-secret"
    failures << "Komga existing user did not authenticate with its own credential" unless
      requests.any? { |request| request["target"] == "/api/v2/users/me" &&
        basic_identity(request) == "reader@example.invalid" }
    failures << "Komga unmanaged user was not preserved" unless users.any? { |user| user["email"] == "friend@example.invalid" }
    failures << "Komga final verification did not re-list users" unless
      requests.count { |request| request["target"] == "/api/v2/users" && request["method"] == "GET" } == 2
  end
end

def exercise_check_mode(failures)
  users = [
    { "id" => "komga-reader", "email" => "reader@example.invalid", "roles" => %w[USER KOBO_SYNC] }
  ]
  responder = lambda do |request|
    case [request["method"], request["target"]]
    when ["GET", "/api/v2/users"] then [200, users]
    when ["GET", "/api/v2/users/me"] then [200, users[0]]
    else [500, {}]
    end
  end
  with_http_service(responder) do |port, requests|
    variables = {
      "komga_api" => "http://127.0.0.1:#{port}", "vault_komga_admin_email" => "admin@example.invalid",
      "vault_komga_admin_password" => "admin-secret",
      "vault_managed_komga_users" => [
        { "email" => "reader@example.invalid", "password" => "reader-secret",
          "roles" => ["PAGE_STREAMING"] },
        { "email" => "new@example.invalid", "password" => "new-secret", "roles" => ["KOREADER_SYNC"] }
      ]
    }
    tasks = [includes_for("komga").first]
    stdout, stderr, status = run_playbook(tasks, variables, "--check")
    failures << "Komga check-mode fixture failed: #{failure_tail(stdout + stderr)}" unless status.success?
    failures << "check mode performed a managed-user mutation" if
      requests.any? { |request| %w[POST PATCH DELETE].include?(request["method"]) }
  end
end

def exercise_verify_tag_selection(failures)
  services = %w[audiobookshelf jellyfin komga]
  tags = services.map { |service| "platform_verify_#{service}" }.join(",")
  stdout, stderr, status = Open3.capture3(
    { "ANSIBLE_NOCOLOR" => "1" }, "ansible-playbook", "-i", "localhost,", "-c", "local",
    File.join(ROOT, "verify.yml"), "--tags", tags, "--list-tasks", chdir: ROOT
  )
  output = stdout + stderr
  failures << "media verify tag listing failed: #{failure_tail(output)}" unless status.success?
  services.each do |service|
    failures << "#{service} verify tag omits managed-user verification" unless
      output.include?("Verify managed #{service.capitalize} users")
    failures << "#{service} verify tag selected managed-user reconciliation" if
      output.include?("Reconcile managed #{service.capitalize} users")
  end
end

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

  failures << "#{service} task file mentions unmanaged deletion" if tasks.any? do |task|
    task_name(task).match?(/delete|remove|absent.*unmanaged/i)
  end

  failures
end

failures = []

SERVICES.each do |service|
  managed_path = File.join(ROOT, "roles", service, "tasks", "managed_users.yml")
  main_path = File.join(ROOT, "roles", service, "tasks", "main.yml")

  failures << "#{service} managed-user tasks are absent" unless File.file?(managed_path)
  next unless File.file?(managed_path)

  begin
    tasks = YAML.safe_load_file(managed_path, aliases: false)
    failures << "#{service} managed-user tasks must be a task list" unless tasks.is_a?(Array)
    failures.concat(contract_failures(service, tasks)) if tasks.is_a?(Array)
  rescue Psych::SyntaxError => error
    failures << "#{service} managed-user tasks are invalid YAML: #{error.message.lines.first.strip}"
  end

  main = File.read(main_path)
  failures << "#{service} main tasks omit managed-user reconciliation" unless
    main.include?("managed_users.yml")
end

policy = File.read(VALIDATE_POLICY)
failures << "media managed-user normal test is not registered" unless
  policy.lines.include?("ruby tests/media_managed_users_test.rb\n")
failures << "media managed-user mutation self-test is not registered" unless
  policy.lines.include?("ruby tests/media_managed_users_test.rb --self-test\n")

if ARGV == ["--self-test"] && failures.empty?
  SERVICES.each do |service|
    tasks = YAML.safe_load_file(
      File.join(ROOT, "roles", service, "tasks", "managed_users.yml"), aliases: false
    )
    repair = tasks.find { |task| task_name(task).match?(/Repair .* managed-user/) }
    mutant = Marshal.load(Marshal.dump(tasks))
    mutant_repair = mutant.find { |task| task_name(task) == task_name(repair) }
    mutant_repair.fetch("ansible.builtin.uri")["body"] = { "password" => "forbidden" }
    unless contract_failures(service, mutant).any? { |failure| failure.include?("secret fields") }
      failures << "#{service} password-update mutant survived"
    end

    if %w[audiobookshelf jellyfin].include?(service) &&
       !contract_failures(service, mutant).any? { |failure| failure.match?(/split|complete current policy/) }
      failures << "#{service} pinned merge/body mutant survived"
    end

    missing_verify = tasks.reject { |task| task_name(task) == REQUIRED_TASKS.fetch(service).last }
    unless contract_failures(service, missing_verify).any? { |failure| failure.include?("Verify exact") }
      failures << "#{service} final-verification mutant survived"
    end
  end
end

if ARGV.empty? && failures.empty?
  unless command_available?("ansible-playbook")
    failures << "ansible-playbook is required for media managed-user behavior fixtures"
  else
    selected_probes = ENV.fetch("MEDIA_MANAGED_USERS_PROBES", "all").split(",")
    exercise_audiobookshelf(failures) if selected_probes.intersect?(%w[all audiobookshelf])
    exercise_jellyfin(failures) if selected_probes.intersect?(%w[all jellyfin])
    exercise_komga(failures) if selected_probes.intersect?(%w[all komga])
    exercise_check_mode(failures) if selected_probes.intersect?(%w[all check_mode])
    exercise_verify_tag_selection(failures) if selected_probes.intersect?(%w[all verify_tags])
    exercise_komga_fail_closed(failures) if selected_probes.intersect?(%w[all fail_closed])
    exercise_media_fail_closed(failures) if selected_probes.intersect?(%w[all fail_closed])
    exercise_media_listing_fail_closed(failures) if selected_probes.intersect?(%w[all fail_closed])
  end
elsif ARGV != ["--self-test"] && !ARGV.empty?
  failures << "usage: media_managed_users_test.rb [--self-test]"
end

if failures.empty?
  puts "media managed users: lifecycle, mutation, and registration contracts passed"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} media managed-user contract violation(s)"
end
