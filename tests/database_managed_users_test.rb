#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"
require "json"
require "open3"
require "socket"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
SERVICES = %w[immich paperless_ngx beszel].freeze
REQUIRED_TASKS = {
  "immich" => [
    "List complete Immich users for managed-user reconciliation",
    "Refuse incomplete Immich managed-user listing",
    "Refuse ambiguous normalized Immich managed identities",
    "Authenticate existing Immich managed users",
    "Require preserved Immich managed-user credentials",
    "Create absent Immich managed users",
    "Require exact newly created Immich managed identities",
    "Authenticate newly created Immich managed users",
    "Require newly created Immich managed-user credentials",
    "Repair Immich managed-user non-secret properties",
    "Verify exact Immich managed users"
  ],
  "paperless_ngx" => [
    "List complete sanitized Paperless users for managed-user reconciliation",
    "Refuse ambiguous normalized Paperless managed identities",
    "Authenticate existing Paperless managed users",
    "Require preserved Paperless managed-user credentials",
    "Create absent Paperless managed users",
    "Require exact newly created Paperless managed identities",
    "Authenticate newly created Paperless managed users",
    "Require newly created Paperless managed-user credentials",
    "Repair Paperless managed-user non-secret properties",
    "Verify exact Paperless managed users"
  ],
  "beszel" => [
    "List complete Beszel users for managed-user reconciliation",
    "Refuse incomplete Beszel managed-user listing",
    "Refuse ambiguous normalized Beszel managed identities",
    "Authenticate existing Beszel managed users",
    "Require preserved Beszel managed-user credentials",
    "Create absent Beszel managed users",
    "Require exact newly created Beszel managed identities",
    "Authenticate newly created Beszel managed users",
    "Require newly created Beszel managed-user credentials",
    "Repair Beszel managed-user role and verification",
    "Verify exact Beszel managed users"
  ]
}.freeze

def task_name(task)
  task.fetch("name", "")
end

def contract_failures(service, tasks)
  failures = []
  names = tasks.map { |task| task_name(task) }
  REQUIRED_TASKS.fetch(service).each do |name|
    failures << "#{service} omits #{name}" unless names.include?(name)
  end
  positions = REQUIRED_TASKS.fetch(service).map { |name| names.index(name) }
  failures << "#{service} managed-user lifecycle is out of order" unless
    positions.none?(&:nil?) && positions == positions.sort

  tasks.each do |task|
    module_name = %w[ansible.builtin.uri community.docker.docker_compose_v2_exec].find { |key| task.key?(key) }
    next unless module_name

    failures << "#{service} secret-bearing task lacks no_log: #{task_name(task)}" unless task["no_log"] == true
  end

  tasks.select { |task| task_name(task).start_with?("Repair") }.each do |task|
    payload = task.dig("ansible.builtin.uri", "body") ||
              task.dig("community.docker.docker_compose_v2_exec", "env") || {}
    forbidden = payload.to_s.scan(/password|passwordConfirm|set_password/i)
    failures << "#{service} existing-user repair contains a password path" unless forbidden.empty?
  end

  tasks.select { |task| task_name(task).start_with?("Authenticate") }.each do |task|
    failures << "#{service} authentication is not disabled in check mode" unless
      Array(task["when"]).include?("not ansible_check_mode") && task["check_mode"] != false
  end
  tasks.select { |task| task_name(task).match?(/^(Create|Repair)/) }.each do |task|
    failures << "#{service} mutation is not disabled in check mode: #{task_name(task)}" unless
      Array(task["when"]).include?("not ansible_check_mode")
  end

  auth_assert = tasks.find { |task| task_name(task).start_with?("Require preserved") }
  guidance = auth_assert&.dig("ansible.builtin.assert", "fail_msg").to_s
  failures << "#{service} auth failure omits reviewed credential-migration guidance" unless
    guidance.include?("reviewed credential-migration procedure") && guidance.include?("not reset")

  failures << "#{service} contains destructive managed-user deletion" if tasks.any? do |task|
    task_name(task).match?(/delete|remove.*managed.user/i) ||
      task.dig("ansible.builtin.uri", "method").to_s.upcase == "DELETE"
  end

  if service == "immich"
    repair = tasks.find { |task| task_name(task) == "Repair Immich managed-user non-secret properties" }
    failures << "Immich repair must use the pinned PUT endpoint" unless
      repair&.dig("ansible.builtin.uri", "method") == "PUT"
    failures << "Immich repair must contain only name and quotaSizeInBytes" unless
      repair&.dig("ansible.builtin.uri", "body")&.keys&.map(&:to_s)&.sort == %w[name quotaSizeInBytes]
    create = tasks.find { |task| task_name(task) == "Create absent Immich managed users" }
    failures << "Immich allowlist must not set administrator status" if
      create&.dig("ansible.builtin.uri", "body")&.key?("isAdmin")
  elsif service == "paperless_ngx"
    commands = tasks.filter_map { |task| task["community.docker.docker_compose_v2_exec"] }
    commands.each do |command|
      argv = Array(command["argv"])
      failures << "Paperless command interpolates a vault value into argv" if argv.any? { |arg| arg.to_s.include?("{{") }
    end
    create = tasks.find { |task| task_name(task) == "Create absent Paperless managed users" }
    repair = tasks.find { |task| task_name(task) == "Repair Paperless managed-user non-secret properties" }
    failures << "Paperless create must pass secrets through environment" unless
      create&.dig("community.docker.docker_compose_v2_exec", "env")&.key?("MANAGED_PASSWORD")
    failures << "Paperless create grants non-secret privileges before credential proof" unless
      create&.dig("community.docker.docker_compose_v2_exec", "env")&.keys&.sort ==
        %w[MANAGED_EMAIL MANAGED_PASSWORD MANAGED_USERNAME]
    failures << "Paperless create must set the initial password" unless
      create&.dig("community.docker.docker_compose_v2_exec", "argv").to_s.include?("set_password")
    failures << "Paperless existing-user repair calls set_password" if
      repair&.dig("community.docker.docker_compose_v2_exec", "argv").to_s.include?("set_password")
  elsif service == "beszel"
    repair = tasks.find { |task| task_name(task) == "Repair Beszel managed-user role and verification" }
    failures << "Beszel repair must contain only role and verified" unless
      repair&.dig("ansible.builtin.uri", "body")&.keys&.map(&:to_s)&.sort == %w[role verified]
    ownership_words = tasks.to_s.scan(/universal_tokens|user_settings|systems|alerts/)
    failures << "Beszel additional-user tasks cross the primary ownership boundary" unless ownership_words.empty?
  end
  failures
end

def run_playbook(tasks, variables, *arguments)
  Dir.mktmpdir("nas-platform-database-managed-users-") do |directory|
    playbook = File.join(directory, "playbook.yml")
    File.write(playbook, YAML.dump([{ "hosts" => "localhost", "gather_facts" => false,
                                     "vars" => variables, "tasks" => tasks }]), mode: "w", perm: 0o600)
    Open3.capture3({ "ANSIBLE_NOCOLOR" => "1" }, "ansible-playbook", "-i", "localhost,",
                   "-c", "local", playbook, *arguments, chdir: ROOT)
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
      client.write("HTTP/1.1 #{status} Fixture\r\nContent-Type: application/json\r\n")
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

def managed_includes(service, extra_vars = {})
  path = File.join(ROOT, "roles", service, "tasks", "managed_users.yml")
  [
    { "name" => "Reconcile fixture #{service}", "ansible.builtin.include_tasks" => path,
      "vars" => extra_vars.merge("#{service}_managed_users_phase" => "reconcile") },
    { "name" => "Verify fixture #{service}", "ansible.builtin.include_tasks" => path,
      "vars" => extra_vars.merge("#{service}_managed_users_phase" => "verify") }
  ]
end

def failure_tail(output)
  output.lines.map(&:strip).reject(&:empty?).last(8).join(" | ")
end

def exercise_immich(failures)
  users = [
    { "id" => "11111111-1111-4111-8111-111111111111", "email" => "reader@example.invalid",
      "name" => "Old", "quotaSizeInBytes" => nil, "status" => "active", "isAdmin" => false,
      "password" => "reader-secret" },
    { "id" => "22222222-2222-4222-8222-222222222222", "email" => "friend@example.invalid",
      "name" => "Friend", "quotaSizeInBytes" => nil, "status" => "active", "isAdmin" => false,
      "password" => "friend-secret" }
  ]
  managed = [
    { "email" => "reader@example.invalid", "password" => "reader-secret", "name" => "Reader",
      "quota_size" => 1024 },
    { "email" => "new@example.invalid", "password" => "new-secret", "name" => "New",
      "quota_size" => 2048 }
  ]
  responder = lambda do |request|
    case [request["method"], request["target"]]
    when ["GET", "/api/admin/users?withDeleted=true"]
      [200, users.map { |user| user.reject { |key, _| key == "password" } }]
    when ["POST", "/api/auth/login"]
      body = request.fetch("json")
      user = users.find { |candidate| candidate["email"] == body["email"] && candidate["password"] == body["password"] }
      user ? [201, { "userEmail" => user["email"], "accessToken" => "user-token" }] : [401, {}]
    when ["POST", "/api/admin/users"]
      body = request.fetch("json")
      users << body.merge("id" => "33333333-3333-4333-8333-333333333333",
                          "quotaSizeInBytes" => nil, "status" => "active", "password" => body["password"])
      [201, users.last.reject { |key, _| key == "password" }]
    else
      if request["method"] == "PUT" && request["target"].start_with?("/api/admin/users/")
        user = users.find { |candidate| request["target"].end_with?(candidate["id"]) }
        user&.merge!(request.fetch("json"))
        [200, user]
      else
        [500, {}]
      end
    end
  end
  with_http_service(responder) do |port, requests|
    vars = { "immich_api" => "http://127.0.0.1:#{port}/api",
             "immich_managed_users_token" => "admin-token", "vault_managed_immich_users" => managed }
    stdout, stderr, status = run_playbook(managed_includes("immich", "immich_managed_users_token" => "admin-token"), vars)
    failures << "Immich behavior fixture failed: #{failure_tail(stdout + stderr)}" unless status.success?
    failures << "Immich unmanaged user was not preserved" unless users.any? { |user| user["email"] == "friend@example.invalid" }
    failures << "Immich existing user did not authenticate with its own credential" unless
      requests.any? { |request| request["target"] == "/api/auth/login" &&
        request.dig("json", "email") == "reader@example.invalid" }
    failures << "Immich newly created user was not authenticated before repair" unless
      requests.index { |request| request["target"] == "/api/auth/login" && request.dig("json", "email") == "new@example.invalid" }.to_i <
      requests.index { |request| request["method"] == "PUT" && request["target"].end_with?("33333333-3333-4333-8333-333333333333") }.to_i
    failures << "Immich repair escaped the non-secret projection" if requests.any? do |request|
      request["method"] == "PUT" && request.fetch("json").keys.sort != %w[name quotaSizeInBytes]
    end
    failures << "Immich final verification did not freshly list users" unless
      requests.count { |request| request["target"] == "/api/admin/users?withDeleted=true" } >= 3
  end
end

def exercise_beszel(failures)
  users = [
    { "id" => "reader123456789", "email" => "reader@example.invalid", "password" => "reader-secret",
      "role" => "user", "verified" => false },
    { "id" => "friend123456789", "email" => "friend@example.invalid", "password" => "friend-secret",
      "role" => "user", "verified" => true }
  ]
  managed = [
    { "email" => "reader@example.invalid", "password" => "reader-secret", "role" => "admin", "verified" => true },
    { "email" => "new@example.invalid", "password" => "new-secret", "role" => "user", "verified" => true }
  ]
  listing = -> { { "items" => users.map { |user| user.reject { |key, _| key == "password" } },
                   "totalPages" => 1, "totalItems" => users.length } }
  responder = lambda do |request|
    case [request["method"], request["target"]]
    when ["GET", "/api/collections/users/records?perPage=500"] then [200, listing.call]
    when ["POST", "/api/collections/users/auth-with-password"]
      body = request.fetch("json")
      user = users.find { |candidate| candidate["email"] == body["identity"] && candidate["password"] == body["password"] }
      user ? [200, { "record" => user.reject { |key, _| key == "password" }, "token" => "user-token" }] : [400, {}]
    when ["POST", "/api/collections/users/records"]
      body = request.fetch("json")
      users << { "id" => "newuser12345678", "email" => body["email"], "password" => body["password"],
                 "role" => "user", "verified" => false }
      [200, users.last.reject { |key, _| key == "password" }]
    else
      if request["method"] == "PATCH" && request["target"].start_with?("/api/collections/users/records/")
        user = users.find { |candidate| request["target"].end_with?(candidate["id"]) }
        user&.merge!(request.fetch("json"))
        [200, user]
      else
        [500, {}]
      end
    end
  end
  with_http_service(responder) do |port, requests|
    vars = { "beszel_api" => "http://127.0.0.1:#{port}", "beszel_auth" => { "json" => { "token" => "admin" } },
             "beszel_complete_users" => { "json" => listing.call }, "vault_managed_beszel_users" => managed }
    stdout, stderr, status = run_playbook(managed_includes("beszel"), vars)
    failures << "Beszel behavior fixture failed: #{failure_tail(stdout + stderr)}" unless status.success?
    failures << "Beszel unmanaged user was not preserved" unless users.any? { |user| user["email"] == "friend@example.invalid" }
    failures << "Beszel repair escaped role and verified" if requests.any? do |request|
      request["method"] == "PATCH" && request.fetch("json").keys.sort != %w[role verified]
    end
    forbidden = %r{/api/collections/(universal_tokens|user_settings|systems|alerts)/}
    failures << "Beszel additional users crossed the primary ownership boundary" if
      requests.any? { |request| request["target"].match?(forbidden) }
  end
end

def exercise_fail_closed_and_check_mode(failures)
  immich_user = { "id" => "11111111-1111-4111-8111-111111111111",
                  "email" => "reader@example.invalid", "name" => "Old",
                  "quotaSizeInBytes" => 0, "status" => "active", "isAdmin" => false }
  immich_managed = [{ "email" => "reader@example.invalid", "password" => "wrong",
                      "name" => "Reader", "quota_size" => 1024 }]
  with_http_service(lambda { |request|
    request["target"] == "/api/admin/users?withDeleted=true" ? [200, [immich_user]] : [401, {}]
  }) do |port, requests|
    vars = { "immich_api" => "http://127.0.0.1:#{port}/api",
             "immich_managed_users_token" => "admin", "vault_managed_immich_users" => immich_managed }
    task = managed_includes("immich", "immich_managed_users_token" => "admin").first
    stdout, stderr, status = run_playbook([task], vars)
    failures << "Immich authentication-failure fixture unexpectedly succeeded" if status.success?
    failures << "Immich authentication failure missed credential-migration assertion" unless
      (stdout + stderr).include?("Require preserved Immich managed-user credentials")
    failures << "Immich authentication failure reached a mutation" if
      requests.any? { |request| %w[PUT PATCH DELETE].include?(request["method"]) ||
        (request["method"] == "POST" && request["target"] != "/api/auth/login") }
  end
  with_http_service(->(_request) { [200, [immich_user]] }) do |port, requests|
    vars = { "immich_api" => "http://127.0.0.1:#{port}/api",
             "immich_managed_users_token" => "admin", "vault_managed_immich_users" => immich_managed }
    _stdout, _stderr, status = run_playbook(
      [managed_includes("immich", "immich_managed_users_token" => "admin").first], vars, "--check"
    )
    failures << "Immich check-mode fixture failed" unless status.success?
    failures << "Immich check mode authenticated or mutated" if
      requests.any? { |request| request["target"] == "/api/auth/login" ||
        %w[POST PUT PATCH DELETE].include?(request["method"]) }
  end

  beszel_user = { "id" => "reader123456789", "email" => "reader@example.invalid",
                  "role" => "user", "verified" => false }
  listing = { "items" => [beszel_user], "totalPages" => 1, "totalItems" => 1 }
  beszel_vars = { "beszel_api" => "http://127.0.0.1:1",
                  "beszel_auth" => { "json" => { "token" => "admin" } },
                  "beszel_complete_users" => { "json" => listing },
                  "vault_managed_beszel_users" => [
                    { "email" => "reader@example.invalid", "password" => "wrong",
                      "role" => "admin", "verified" => true }
                  ] }
  with_http_service(->(_request) { [400, {}] }) do |port, requests|
    vars = beszel_vars.merge("beszel_api" => "http://127.0.0.1:#{port}")
    stdout, stderr, status = run_playbook([managed_includes("beszel").first], vars)
    failures << "Beszel authentication-failure fixture unexpectedly succeeded" if status.success?
    failures << "Beszel authentication failure missed credential-migration assertion" unless
      (stdout + stderr).include?("Require preserved Beszel managed-user credentials")
    failures << "Beszel authentication failure reached a mutation" if
      requests.any? { |request| request["method"] != "POST" ||
        request["target"] != "/api/collections/users/auth-with-password" }
  end
  with_http_service(->(_request) { [500, {}] }) do |port, requests|
    vars = beszel_vars.merge("beszel_api" => "http://127.0.0.1:#{port}")
    _stdout, _stderr, status = run_playbook([managed_includes("beszel").first], vars, "--check")
    failures << "Beszel check-mode fixture failed" unless status.success?
    failures << "Beszel check mode authenticated or mutated" unless requests.empty?
  end
end

def exercise_verify_tag_selection(failures)
  tags = %w[immich paperless beszel].map { |service| "platform_verify_#{service}" }.join(",")
  stdout, stderr, status = Open3.capture3(
    { "ANSIBLE_NOCOLOR" => "1" }, "ansible-playbook", "-i", "localhost,", "-c", "local",
    File.join(ROOT, "verify.yml"), "--tags", tags, "--list-tasks", chdir: ROOT
  )
  output = stdout + stderr
  failures << "database managed-user verify tag listing failed: #{failure_tail(output)}" unless status.success?
  { "Immich" => "immich", "Paperless" => "paperless", "Beszel" => "beszel" }.each do |label, service|
    failures << "#{label} verify tag omits managed-user verification" unless
      output.include?("Verify managed #{label} users")
    failures << "#{label} verify tag selected managed-user reconciliation" if
      output.include?("Reconcile managed #{label} users")
  end
end

def exercise_disabled_paperless_target_rejection(failures)
  variables = YAML.safe_load_file(
    File.join(ROOT, "inventory", "group_vars", "all", "vault.yml.example"), aliases: false
  )
  variables.dig("vault_managed_users", "paperless_ngx", 0)["is_active"] = false
  tasks = [{ "name" => "Validate disabled Paperless managed target",
             "ansible.builtin.include_role" => { "name" => "vault_contract" } }]
  _stdout, _stderr, status = run_playbook(tasks, variables)
  failures << "Paperless disabled managed target unexpectedly passed vault validation" if status.success?
end

def exercise_mangled_created_credentials(failures)
  immich_users = []
  with_http_service(lambda { |request|
    case [request["method"], request["target"]]
    when ["GET", "/api/admin/users?withDeleted=true"]
      [200, immich_users.map { |user| user.reject { |key, _| key == "password" } }]
    when ["POST", "/api/admin/users"]
      body = request.fetch("json")
      immich_users << body.merge("id" => "33333333-3333-4333-8333-333333333333",
                                 "password" => "mangled", "quotaSizeInBytes" => nil, "status" => "active")
      [201, immich_users.last.reject { |key, _| key == "password" }]
    when ["POST", "/api/auth/login"] then [401, {}]
    else [500, {}]
    end
  }) do |port, requests|
    vars = { "immich_api" => "http://127.0.0.1:#{port}/api",
             "immich_managed_users_token" => "admin", "vault_managed_immich_users" => [
               { "email" => "new@example.invalid", "password" => "expected",
                 "name" => "New", "quota_size" => 1024 }
             ] }
    stdout, stderr, status = run_playbook(
      [managed_includes("immich", "immich_managed_users_token" => "admin").first], vars
    )
    failures << "Immich mangled-created-password fixture unexpectedly succeeded" if status.success?
    failures << "Immich mangled-created-password fixture missed new credential assertion" unless
      (stdout + stderr).include?("Require newly created Immich managed-user credentials")
    failures << "Immich mangled-created-password fixture reached repair" if
      requests.any? { |request| request["method"] == "PUT" }
  end

  beszel_users = []
  initial = { "items" => [], "totalPages" => 1, "totalItems" => 0 }
  with_http_service(lambda { |request|
    case [request["method"], request["target"]]
    when ["POST", "/api/collections/users/records"]
      body = request.fetch("json")
      beszel_users << { "id" => "newuser12345678", "email" => body["email"],
                        "password" => "mangled", "role" => "user", "verified" => false }
      [200, beszel_users.last.reject { |key, _| key == "password" }]
    when ["GET", "/api/collections/users/records?perPage=500"]
      [200, { "items" => beszel_users.map { |user| user.reject { |key, _| key == "password" } },
              "totalPages" => 1, "totalItems" => beszel_users.length }]
    when ["POST", "/api/collections/users/auth-with-password"] then [400, {}]
    else [500, {}]
    end
  }) do |port, requests|
    vars = { "beszel_api" => "http://127.0.0.1:#{port}",
             "beszel_auth" => { "json" => { "token" => "admin" } },
             "beszel_complete_users" => { "json" => initial },
             "vault_managed_beszel_users" => [
               { "email" => "new@example.invalid", "password" => "expected",
                 "role" => "admin", "verified" => true }
             ] }
    stdout, stderr, status = run_playbook([managed_includes("beszel").first], vars)
    failures << "Beszel mangled-created-password fixture unexpectedly succeeded" if status.success?
    failures << "Beszel mangled-created-password fixture missed new credential assertion" unless
      (stdout + stderr).include?("Require newly created Beszel managed-user credentials")
    failures << "Beszel mangled-created-password fixture reached repair" if
      requests.any? { |request| request["method"] == "PATCH" }
  end
end

failures = []
SERVICES.each do |service|
  path = File.join(ROOT, "roles", service, "tasks", "managed_users.yml")
  failures << "#{service} managed-user tasks are absent" unless File.file?(path)
  next unless File.file?(path)

  tasks = YAML.safe_load_file(path, aliases: false)
  failures << "#{service} managed-user tasks must be a task list" unless tasks.is_a?(Array)
  failures.concat(contract_failures(service, tasks)) if tasks.is_a?(Array)
  main = File.read(File.join(ROOT, "roles", service, "tasks", "main.yml"))
  failures << "#{service} main tasks omit managed-user reconciliation" unless main.include?("managed_users.yml")
end

policy = File.read(File.join(ROOT, "tests", "validate-policy.sh"))
failures << "database managed-user normal test is not registered" unless
  policy.lines.include?("ruby tests/database_managed_users_test.rb\n")
failures << "database managed-user self-test is not registered" unless
  policy.lines.include?("ruby tests/database_managed_users_test.rb --self-test\n")

if ARGV == ["--self-test"]
  SERVICES.each do |service|
    next unless failures.empty?

    tasks = YAML.safe_load_file(
      File.join(ROOT, "roles", service, "tasks", "managed_users.yml"), aliases: false
    )
    missing_verify = tasks.reject { |task| task_name(task) == REQUIRED_TASKS.fetch(service).last }
    unless contract_failures(service, missing_verify).any? { |failure| failure.include?("Verify exact") }
      failures << "#{service} final-verification mutant survived"
    end
    mutant = Marshal.load(Marshal.dump(tasks))
    repair = mutant.find { |task| task_name(task).start_with?("Repair") }
    if service == "paperless_ngx"
      repair.fetch("community.docker.docker_compose_v2_exec").fetch("env")["MANAGED_PASSWORD"] = "forbidden"
    else
      repair.fetch("ansible.builtin.uri").fetch("body")["password"] = "forbidden"
    end
    unless contract_failures(service, mutant).any? { |failure| failure.include?("password path") }
      failures << "#{service} existing-password-update mutant survived"
    end

    visible_secret = Marshal.load(Marshal.dump(tasks))
    secret_task = visible_secret.find do |task|
      task.key?("ansible.builtin.uri") || task.key?("community.docker.docker_compose_v2_exec")
    end
    secret_task["no_log"] = false
    unless contract_failures(service, visible_secret).any? { |failure| failure.include?("lacks no_log") }
      failures << "#{service} no-log mutant survived"
    end
  end
elsif ARGV.empty?
  if ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? { |directory| File.executable?(File.join(directory, "ansible-playbook")) }
    exercise_immich(failures)
    exercise_beszel(failures)
    exercise_fail_closed_and_check_mode(failures)
    exercise_verify_tag_selection(failures)
    exercise_disabled_paperless_target_rejection(failures)
    exercise_mangled_created_credentials(failures)
  else
    failures << "ansible-playbook is required for database managed-user behavior fixtures"
  end
elsif !ARGV.empty?
  failures << "usage: database_managed_users_test.rb [--self-test]"
end

if failures.empty?
  puts "database managed users: lifecycle and mutation contracts passed"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} database managed-user contract violation(s)"
end
