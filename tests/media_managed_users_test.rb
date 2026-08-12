#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "json"
require "open3"
require "socket"
require "tmpdir"
require "uri"
require "yaml"

ROOT = File.expand_path("..", __dir__)
SERVICES = %w[audiobookshelf jellyfin komga].freeze
VALIDATE_POLICY = File.join(ROOT, "tests", "validate-policy.sh")
JELLYFIN_AVATAR_SHA256 = "bf12ac53a05f1db64f3d00440315a6626e7c2dd12dd41867c93c9ac7aeccc792"
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

def nested_task_names(tasks)
  Array(tasks).flat_map do |task|
    [task_name(task)] + %w[block rescue always].flat_map { |key| nested_task_names(task[key]) }
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

def basic_credentials(request)
  encoded = request.fetch("headers").fetch("authorization", "").delete_prefix("Basic ")
  Base64.decode64(encoded).split(":", 2)
end

def basic_identity(request)
  basic_credentials(request).first
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
      credentials = { "reader" => "reader-secret", "new-reader" => "new-secret" }
      credentials[body["username"]] == body["password"] ?
        [200, { "user" => { "username" => body["username"] } }] : [401, {}]
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
    failures << "Audiobookshelf newly created user did not prove its vault password" unless
      requests.any? { |request| request["target"] == "/login" &&
        request["json"] == { "username" => "new-reader", "password" => "new-secret" } }
    failures << "Audiobookshelf unmanaged user was not preserved" unless
      users.any? { |user| user["username"] == "friend" }
    failures << "Audiobookshelf final verification did not re-list users" unless
      requests.count { |request| request["target"] == "/api/users" && request["method"] == "GET" } == 3
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
      credentials = { "reader" => "reader-secret", "new-reader" => "new-secret" }
      authenticated = users.find { |user| user["Name"] == body["Username"] }
      credentials[body["Username"]] == body["Pw"] ?
        [200, { "User" => authenticated, "AccessToken" => "reader-token" }] : [401, {}]
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
    failures << "Jellyfin newly created user did not prove its vault password" unless
      requests.any? { |request| request["target"] == "/Users/AuthenticateByName" &&
        request["json"] == { "Username" => "new-reader", "Pw" => "new-secret" } }
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
    { "id" => "komga-reader", "email" => "reader@example.invalid", "password" => "reader-secret",
      "roles" => %w[USER KOBO_SYNC] },
    { "id" => "komga-friend", "email" => "friend@example.invalid", "password" => "friend-secret",
      "roles" => %w[USER KOBO_SYNC] }
  ]
  managed = [
    { "email" => "reader@example.invalid", "password" => "reader-secret",
      "roles" => ["PAGE_STREAMING"] },
    { "email" => "new@example.invalid", "password" => "new-secret", "roles" => ["KOREADER_SYNC"] }
  ]
  responder = lambda do |request|
    case [request["method"], request["target"]]
    when ["GET", "/api/v2/users"]
      [200, users.map { |user| user.reject { |key, _| key == "password" } }]
    when ["GET", "/api/v2/users/me"]
      email, password = basic_credentials(request)
      authenticated = users.find { |user| user["email"] == email && user["password"] == password }
      authenticated ? [200, authenticated.reject { |key, _| key == "password" }] : [401, {}]
    when ["POST", "/api/v2/users"]
      body = request.fetch("json")
      users << body.merge("id" => "komga-created",
                          "roles" => body.fetch("roles").intersection(supported_roles) + ["USER"])
      [201, users.last.reject { |key, _| key == "password" }]
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
    failures << "Komga newly created user did not prove its vault password" unless
      requests.any? { |request| request["target"] == "/api/v2/users/me" &&
        basic_credentials(request) == ["new@example.invalid", "new-secret"] }
    failures << "Komga existing user did not authenticate with its own credential" unless
      requests.any? { |request| request["target"] == "/api/v2/users/me" &&
        basic_credentials(request) == ["reader@example.invalid", "reader-secret"] }
    failures << "Komga unmanaged user was not preserved" unless users.any? { |user| user["email"] == "friend@example.invalid" }
    failures << "Komga final verification did not re-list users" unless
      requests.count { |request| request["target"] == "/api/v2/users" && request["method"] == "GET" } == 3
  end
end

def exercise_check_mode(failures)
  cases = [
    ["Audiobookshelf", "audiobookshelf", "fixture-token",
     { "vault_managed_audiobookshelf_users" => [
       { "username" => "reader", "password" => "secret", "type" => "user", "is_active" => true,
         "permissions" => { "flags" => {}, "librariesAccessible" => [], "itemTagsSelected" => [] } }
     ] },
     lambda do |request|
       request["target"] == "/api/users" ?
         [200, { "users" => [{ "id" => "reader", "username" => "reader", "type" => "user",
                               "isActive" => true, "permissions" => {},
                               "librariesAccessible" => [], "itemTagsSelected" => [] }] }] : [200, {}]
     end],
    ["Jellyfin", "jellyfin", "admin-token",
     { "jellyfin_client_header" => "MediaBrowser Fixture",
       "vault_managed_jellyfin_users" => [
         { "username" => "reader", "password" => "secret", "policy" => { "IsAdministrator" => false } }
       ] },
     lambda do |request|
       request["target"] == "/Users" ?
         [200, [{ "Id" => "a" * 32, "Name" => "reader",
                  "Policy" => { "AuthenticationProviderId" => "auth",
                                "PasswordResetProviderId" => "reset",
                                "IsAdministrator" => false } }]] : [200, {}]
     end],
    ["Komga", "komga", nil,
     { "vault_komga_admin_email" => "admin@example.invalid",
       "vault_komga_admin_password" => "admin-secret",
       "vault_managed_komga_users" => [
         { "email" => "reader@example.invalid", "password" => "secret", "roles" => ["PAGE_STREAMING"] }
       ] },
     lambda do |request|
       request["target"] == "/api/v2/users" ?
         [200, [{ "id" => "reader", "email" => "reader@example.invalid", "roles" => ["USER"] }]] :
         [200, { "id" => "reader", "email" => "reader@example.invalid", "roles" => ["USER"] }]
     end]
  ]
  cases.each do |label, service, token, variables, responder|
    with_http_service(responder) do |port, requests|
      variables["#{service}_api"] = "http://127.0.0.1:#{port}"
      stdout, stderr, status = run_playbook([includes_for(service, token).first], variables, "--check")
      failures << "#{label} check-mode fixture failed: #{failure_tail(stdout + stderr)}" unless status.success?
      auth_targets = %w[/login /Users/AuthenticateByName /api/v2/users/me]
      failures << "#{label} check mode performed authentication or mutation" if
        requests.any? { |request| auth_targets.include?(request["target"]) ||
          %w[POST PATCH DELETE].include?(request["method"]) }
    end
  end
end

def exercise_jellyfin_fresh_check_mode(failures)
  main = YAML.safe_load_file(
    File.join(ROOT, "roles", "jellyfin", "tasks", "main.yml"), aliases: false
  )
  first_application_task = main.index do |task|
    task_name(task) == "Wait for the Jellyfin startup API"
  end
  tasks = main.drop(first_application_task)
  defaults = YAML.safe_load_file(
    File.join(ROOT, "roles", "jellyfin", "defaults", "main.yml"), aliases: false
  )
  responder = lambda do |request|
    case request["target"]
    when "/Startup/Configuration" then [200, {}]
    when "/System/Info/Public" then [200, { "StartupWizardCompleted" => false }]
    else [500, {}]
    end
  end
  Dir.mktmpdir("jellyfin-fresh-check-") do |directory|
    with_http_service(responder) do |port, requests|
      variables = defaults.merge(
        "jellyfin_api" => "http://127.0.0.1:#{port}",
        "jellyfin_client_header" => "MediaBrowser Fixture",
        "vault_jellyfin_admin_username" => "Yonatan",
        "vault_jellyfin_admin_password" => "secret",
        "vault_managed_jellyfin_users" => [],
        "jellyfin_primary_recovery_marker" => File.join(directory, "recovery.json"),
        "jellyfin_admin_avatar_source" =>
          File.join(ROOT, "roles", "jellyfin", "files", "yonatan-avatar.jpeg"),
        "jellyfin_admin_avatar_probe" => File.join(directory, "avatar-probe.jpeg"),
        "jellyfin_admin_avatar_remote" => File.join(directory, "avatar.jpeg")
      )
      stdout, stderr, status = run_playbook(tasks, variables, "--check")
      output = stdout + stderr
      failures << "Jellyfin fresh full-role check mode failed: #{failure_tail(output)}" unless
        status.success?
      expected_plans = [
        "JELLYFIN_PLAN_WIZARD",
        "JELLYFIN_PLAN_ADMIN_IMAGE",
        "JELLYFIN_PLAN_LIBRARY_CREATE Movies",
        "JELLYFIN_PLAN_LIBRARY_CREATE Shows"
      ]
      expected_plans.each do |plan|
        failures << "Jellyfin fresh check mode omits #{plan}" unless output.include?(plan)
      end
      failures << "Jellyfin fresh check mode performed a mutation" if requests.any? do |request|
        %w[POST PUT PATCH DELETE].include?(request["method"])
      end
    end
  end
end

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
  identity = File.file?(identity_path) ? File.read(identity_path) : ""
  role = File.read(role_path) + identity
  names = nested_task_names(YAML.safe_load_file(role_path, aliases: false))
  names += nested_task_names(YAML.safe_load_file(identity_path, aliases: false)) if
    File.file?(identity_path)
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
      role.match?(/(?:name|collection_type|path):\s*Collections/i)
  failures << "Jellyfin approved administrator avatar is absent" unless File.file?(avatar)
  if File.file?(avatar)
    require "digest"
    failures << "Jellyfin approved administrator avatar hash differs" unless
      Digest::SHA256.file(avatar).hexdigest == JELLYFIN_AVATAR_SHA256
  end
  failures << "Jellyfin avatar hash contract differs" unless
    defaults["jellyfin_admin_avatar_sha256"] == JELLYFIN_AVATAR_SHA256

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
    "Verify exact Jellyfin owned state"
  ]
  required.each { |name| failures << "Jellyfin main role omits #{name}" unless names.include?(name) }
  check_plans = [
    "Report planned Jellyfin administrator image upload after startup",
    "Report planned Jellyfin managed library creation after startup"
  ]
  check_plans.each { |name| failures << "Jellyfin main role omits #{name}" unless names.include?(name) }
  preflight = required.first(7).filter_map { |name| names.index(name) }
  first_mutation = required.drop(7).filter_map { |name| names.index(name) }.min
  failures << "Jellyfin identity/library preflight does not precede every mutation" unless
    preflight.length == 7 && first_mutation && preflight.max < first_mutation
  failures << "Jellyfin primary rename does not use the supported current endpoint" unless
    role.include?("/Users?userId=")
  failures << "Jellyfin primary rename is not guarded by block/rescue recovery" unless
    role.include?("primary_identity.yml") &&
      identity.include?("rescue:")
  failures << "Jellyfin temporary recovery match is not byte-exact" unless
    role.include?("if item.Name == jellyfin_primary_temporary_name else")
  failures << "Jellyfin extra library paths do not use the supported removal endpoint" unless
    role.include?("/Library/VirtualFolders/Paths?name=") && role.include?("method: DELETE")
  failures << "Jellyfin image upload does not use the supported current endpoint" unless
    role.include?("/UserImage?userId=")
  failures << "Jellyfin server update does not preserve the full configuration" unless
    role.include?("jellyfin_server_configuration_before.json | combine")
  failures << "Jellyfin role has no authoritative image byte verification" unless
    role.include?("jellyfin_admin_avatar_sha256") && role.include?("checksum_algorithm: sha256")

  failures
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

failures = []
failures.concat(jellyfin_identity_contract_failures)

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

    next unless service == "komga"

    KOMGA_AUTH_PASSWORD_EXPRESSIONS.each do |auth_name, expected_password|
      wrong_password = Marshal.load(Marshal.dump(tasks))
      wrong_password.find { |task| task_name(task) == auth_name }
                    .fetch("ansible.builtin.uri")["url_password"] = "{{ wrong_password }}"
      unless contract_failures(service, wrong_password).any? do |failure|
        failure.include?("vault password expression") && failure.include?(auth_name)
      end
        failures << "Komga #{auth_name} wrong-password mutant survived (expected #{expected_password})"
      end
    end
  end
end

if ARGV.empty?
  unless command_available?("ansible-playbook")
    failures << "ansible-playbook is required for media managed-user behavior fixtures"
  else
    selected_probes = ENV.fetch("MEDIA_MANAGED_USERS_PROBES", "all").split(",")
    exercise_audiobookshelf(failures) if selected_probes.intersect?(%w[all audiobookshelf])
    exercise_jellyfin(failures) if selected_probes.intersect?(%w[all jellyfin])
    exercise_jellyfin_primary_identity_recovery(failures) if
      selected_probes.intersect?(%w[all jellyfin_identity])
    exercise_jellyfin_primary_preflight(failures) if
      selected_probes.intersect?(%w[all jellyfin_identity])
    exercise_jellyfin_extra_path_recovery(failures) if
      selected_probes.intersect?(%w[all jellyfin_libraries])
    exercise_jellyfin_library_shape_preflight(failures) if
      selected_probes.intersect?(%w[all jellyfin_libraries])
    exercise_komga(failures) if selected_probes.intersect?(%w[all komga])
    exercise_check_mode(failures) if selected_probes.intersect?(%w[all check_mode])
    exercise_jellyfin_fresh_check_mode(failures) if
      selected_probes.intersect?(%w[all check_mode])
    exercise_jellyfin_recovery_marker_safety(failures) if
      selected_probes.intersect?(%w[all jellyfin_identity])
    exercise_verify_tag_selection(failures) if selected_probes.intersect?(%w[all verify_tags])
    exercise_komga_fail_closed(failures) if selected_probes.intersect?(%w[all fail_closed])
    exercise_media_fail_closed(failures) if selected_probes.intersect?(%w[all fail_closed])
    exercise_media_listing_fail_closed(failures) if selected_probes.intersect?(%w[all fail_closed])
    exercise_post_create_credential_failures(failures) if selected_probes.intersect?(%w[all credentials])
    exercise_disabled_target_rejection(failures) if selected_probes.intersect?(%w[all disabled])
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
