#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"
require "json"
require "fileutils"
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
    preserved = tasks.find { |task| task_name(task) == "Require preserved Immich managed-user credentials" }
    created = tasks.find { |task| task_name(task) == "Require newly created Immich managed-user credentials" }
    failures << "Immich existing auth is not bound to the listed user ID" unless
      preserved&.dig("ansible.builtin.assert", "that").to_s.include?("userId") &&
      preserved&.dig("ansible.builtin.assert", "that").to_s.include?(".id")
    failures << "Immich new auth is not bound to the re-resolved user ID" unless
      created&.dig("ansible.builtin.assert", "that").to_s.include?("userId") &&
      created&.dig("ansible.builtin.assert", "that").to_s.include?(".id")
    failures << "Immich omits stable authenticated-ID enforcement before repair" unless
      names.include?("Require stable authenticated Immich managed identities")
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
    create_script = Array(create&.dig("community.docker.docker_compose_v2_exec", "argv")).last.to_s
    create_lines = create_script.lines
    atomic_index = create_lines.index { |line| line.strip == "with transaction.atomic():" }
    create_index = create_lines.index { |line| line.include?("objects.create(") }
    password_index = create_lines.index { |line| line.include?("user.set_password(") }
    save_index = create_lines.index { |line| line.include?("user.save()") }
    atomic_indent = atomic_index && create_lines[atomic_index][/^\s*/].length
    nested_indexes = [create_index, password_index, save_index]
    atomic_creation = create_script.include?("from django.db import transaction") && atomic_index &&
                      nested_indexes.all? && nested_indexes == nested_indexes.sort &&
                      nested_indexes.all? do |index|
                        index > atomic_index && create_lines[index][/^\s*/].length > atomic_indent
                      end
    failures << "Paperless create is not atomic across identity and password persistence" unless atomic_creation
    failures << "Paperless creation is not limited to reconciliation" unless
      create&.fetch("when", [])&.include?("paperless_managed_users_phase == 'reconcile'")
    failures << "Paperless existing-user repair calls set_password" if
      repair&.dig("community.docker.docker_compose_v2_exec", "argv").to_s.include?("set_password")
    repair_env = repair&.dig("community.docker.docker_compose_v2_exec", "env") || {}
    repair_script = repair&.dig("community.docker.docker_compose_v2_exec", "argv").to_s
    failures << "Paperless repair lacks token and expected-PK binding inputs" unless
      repair_env.key?("MANAGED_TOKEN") && repair_env.key?("MANAGED_ID")
    failures << "Paperless repair lacks atomic token-owner identity binding" unless
      repair_script.include?("transaction.atomic") && repair_script.include?("Token") &&
      repair_script.include?("select_for_update") && repair_script.include?("token.user_id")
    failures << "Paperless omits stable authenticated-PK enforcement before repair" unless
      names.include?("Require stable authenticated Paperless managed identities")
    failures << "Paperless omits effective post-list reauthentication" unless
      names.include?("Authenticate effective Paperless managed users after re-list")
  elsif service == "beszel"
    create = tasks.find { |task| task_name(task) == "Create absent Beszel managed users" }
    repair = tasks.find { |task| task_name(task) == "Repair Beszel managed-user role and verification" }
    failures << "Beszel absent-user creation must set the pinned authentication prerequisite" unless
      create&.dig("ansible.builtin.uri", "body", "verified") == true
    failures << "Beszel absent-user creation grants privilege before credential proof" unless
      create&.dig("ansible.builtin.uri", "body")&.keys&.map(&:to_s)&.sort ==
        %w[email password passwordConfirm verified].sort
    failures << "Beszel repair must contain only role and verified" unless
      repair&.dig("ansible.builtin.uri", "body")&.keys&.map(&:to_s)&.sort == %w[role verified]
    ownership_words = tasks.to_s.scan(/universal_tokens|user_settings|systems|alerts/)
    failures << "Beszel additional-user tasks cross the primary ownership boundary" unless ownership_words.empty?
    preserved = tasks.find { |task| task_name(task) == "Require preserved Beszel managed-user credentials" }
    created = tasks.find { |task| task_name(task) == "Require newly created Beszel managed-user credentials" }
    failures << "Beszel existing auth is not bound to the listed record ID" unless
      preserved&.dig("ansible.builtin.assert", "that").to_s.include?("record.id") &&
      preserved&.dig("ansible.builtin.assert", "that").to_s.include?(".id")
    failures << "Beszel new auth is not bound to the re-resolved record ID" unless
      created&.dig("ansible.builtin.assert", "that").to_s.include?("record.id") &&
      created&.dig("ansible.builtin.assert", "that").to_s.include?(".id")
    failures << "Beszel omits stable authenticated-ID enforcement before repair" unless
      names.include?("Require stable authenticated Beszel managed identities")
  end
  failures
end

def run_playbook(tasks, variables, *arguments, env: {})
  Dir.mktmpdir("nas-platform-database-managed-users-") do |directory|
    playbook = File.join(directory, "playbook.yml")
    File.write(playbook, YAML.dump([{ "hosts" => "localhost", "gather_facts" => false,
                                     "vars" => variables, "tasks" => tasks }]), mode: "w", perm: 0o600)
    Open3.capture3({ "ANSIBLE_NOCOLOR" => "1" }.merge(env), "ansible-playbook", "-i", "localhost,",
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

def managed_includes(service, extra_vars = {}, path: nil)
  path ||= File.join(ROOT, "roles", service, "tasks", "managed_users.yml")
  phase_prefix = service == "paperless_ngx" ? "paperless" : service
  [
    { "name" => "Reconcile fixture #{service}", "ansible.builtin.include_tasks" => path,
      "vars" => extra_vars.merge("#{phase_prefix}_managed_users_phase" => "reconcile") },
    { "name" => "Verify fixture #{service}", "ansible.builtin.include_tasks" => path,
      "vars" => extra_vars.merge("#{phase_prefix}_managed_users_phase" => "verify") }
  ]
end

def failure_tail(output)
  output.lines.map(&:strip).reject(&:empty?).last(8).join(" | ")
end

PAPERLESS_EXECUTOR_MODULE = <<~'PYTHON'
  #!/usr/bin/python
  import json
  import os
  from ansible.module_utils.basic import AnsibleModule

  module = AnsibleModule(
      argument_spec={
          "project_src": {"type": "str"},
          "project_name": {"type": "str"},
          "files": {"type": "list"},
          "env_files": {"type": "list"},
          "service": {"type": "str"},
          "env": {"type": "dict", "default": {}},
          "argv": {"type": "list", "elements": "str", "required": True},
          "tty": {"type": "bool"},
      },
      supports_check_mode=True,
  )
  path = os.environ["PAPERLESS_FIXTURE_STATE"]
  with open(path, encoding="utf-8") as handle:
      state = json.load(handle)
  argv = module.params["argv"]
  command_env = module.params["env"]
  script = argv[-1]
  state.setdefault("commands", []).append({"argv": argv, "env_keys": sorted(command_env)})
  state.setdefault("events", [])
  changed = False
  stdout = ""

  if "objects.all()" in script:
      state["events"].append("list")
      state["list_count"] = state.get("list_count", 0) + 1
      if state.get("swap_on_second_list") and state["list_count"] == 2:
          for user in state["users"]:
              if user["username"] == state["swap_username"]:
                  user["id"] = state["replacement_id"]
      sanitized = [
          {key: value for key, value in user.items() if key != "password"}
          for user in state["users"]
      ]
      stdout = json.dumps(sanitized, sort_keys=True)
  elif "set_password" in script:
      state["events"].append("create:" + command_env["MANAGED_USERNAME"])
      user_id = state["next_id"]
      state["next_id"] += 1
      created_user = {
          "id": user_id,
          "username": command_env["MANAGED_USERNAME"],
          "email": command_env["MANAGED_EMAIL"],
          "password": None,
          "is_active": True,
          "is_staff": False,
          "is_superuser": False,
          "groups": [],
      }
      state["users"].append(created_user)
      if state.get("fail_after_identity_create"):
          if "with transaction.atomic():" in script:
              state["users"].pop()
              state["events"].append("rollback:" + command_env["MANAGED_USERNAME"])
          else:
              state["events"].append("partial-commit:" + command_env["MANAGED_USERNAME"])
          with open(path, "w", encoding="utf-8") as handle:
              json.dump(state, handle)
          module.fail_json(msg="managed user creation failed")
      created_user["password"] = (
          "mangled" if state.get("mangle_create") else command_env["MANAGED_PASSWORD"]
      )
      changed = True
  else:
      event = "repair:" if "MANAGED_EMAIL" in command_env else "bind:"
      state["events"].append(event + command_env["MANAGED_USERNAME"])
      username = command_env["MANAGED_USERNAME"]
      user = next((entry for entry in state["users"] if entry["username"] == username), None)
      if user is None:
          module.fail_json(msg="managed identity binding invalid")
      if "token.user_id" in script:
          token_owner = state.get("tokens", {}).get(command_env.get("MANAGED_TOKEN"))
          if token_owner != int(command_env["MANAGED_ID"]) or user["id"] != int(command_env["MANAGED_ID"]):
              module.fail_json(msg="managed identity binding invalid")
      if "MANAGED_EMAIL" in command_env:
          user.update({
              "email": command_env["MANAGED_EMAIL"],
              "is_active": command_env["MANAGED_ACTIVE"] == "true",
              "is_staff": command_env["MANAGED_STAFF"] == "true",
              "is_superuser": command_env["MANAGED_SUPERUSER"] == "true",
              "groups": sorted(json.loads(command_env["MANAGED_GROUPS"])),
          })
          changed = True

  with open(path, "w", encoding="utf-8") as handle:
      json.dump(state, handle)
  module.exit_json(changed=changed, stdout=stdout, stdout_lines=stdout.splitlines())
PYTHON

def with_paperless_executor(state)
  Dir.mktmpdir("nas-platform-paperless-executor-") do |directory|
    module_directory = File.join(
      directory, "ansible_collections", "community", "docker", "plugins", "modules"
    )
    FileUtils.mkdir_p(module_directory)
    module_path = File.join(module_directory, "docker_compose_v2_exec.py")
    File.write(module_path, PAPERLESS_EXECUTOR_MODULE, mode: "w", perm: 0o700)
    state_path = File.join(directory, "state.json")
    File.write(state_path, JSON.generate(state), mode: "w", perm: 0o600)
    yield directory, state_path
  end
end

def read_fixture_state(path)
  JSON.parse(File.read(path))
end

def write_fixture_state(path, state)
  File.write(path, JSON.generate(state), mode: "w", perm: 0o600)
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
      user ? [201, { "userId" => user["id"], "userEmail" => user["email"],
                     "accessToken" => "user-token" }] : [401, {}]
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
    stdout, stderr, status = run_playbook(
      managed_includes("immich", { "immich_managed_users_token" => "admin-token" }), vars
    )
    failures << "Immich behavior fixture failed: #{failure_tail(stdout + stderr)}" unless status.success?
    failures << "Immich unmanaged user was not preserved" unless users.any? { |user| user["email"] == "friend@example.invalid" }
    failures << "Immich existing user did not authenticate with its own credential" unless
      requests.any? { |request| request["target"] == "/api/auth/login" &&
        request.dig("json", "email") == "reader@example.invalid" }
    new_auth_index = requests.index do |request|
      request["target"] == "/api/auth/login" &&
        request.dig("json", "email") == "new@example.invalid"
    end
    new_repair_index = requests.index do |request|
      request["method"] == "PUT" &&
        request["target"].end_with?("33333333-3333-4333-8333-333333333333")
    end
    failures << "Immich newly created user was not authenticated before repair" unless
      new_auth_index && new_repair_index && new_auth_index < new_repair_index
    failures << "Immich repair escaped the non-secret projection" if requests.any? do |request|
      request["method"] == "PUT" && request.fetch("json").keys.sort != %w[name quotaSizeInBytes]
    end
    failures << "Immich final verification did not freshly list users" unless
      requests.count { |request| request["target"] == "/api/admin/users?withDeleted=true" } >= 3
  end
end

def exercise_beszel(failures, task_path: nil)
  users = [
    { "id" => "reader123456789", "email" => "reader@example.invalid", "password" => "reader-secret",
      "role" => "user", "verified" => true },
    { "id" => "friend123456789", "email" => "friend@example.invalid", "password" => "friend-secret",
      "role" => "user", "verified" => true }
  ]
  managed = [
    { "email" => "reader@example.invalid", "password" => "reader-secret", "role" => "admin", "verified" => true },
    { "email" => "new@example.invalid", "password" => "new-secret", "role" => "admin", "verified" => true }
  ]
  listing = -> { { "items" => users.map { |user| user.reject { |key, _| key == "password" } },
                   "totalPages" => 1, "totalItems" => users.length } }
  responder = lambda do |request|
    case [request["method"], request["target"]]
    when ["GET", "/api/collections/users/records?perPage=500"] then [200, listing.call]
    when ["POST", "/api/collections/users/auth-with-password"]
      body = request.fetch("json")
      user = users.find do |candidate|
        candidate["verified"] && candidate["email"] == body["identity"] &&
          candidate["password"] == body["password"]
      end
      user ? [200, { "record" => user.reject { |key, _| key == "password" }, "token" => "user-token" }] : [400, {}]
    when ["POST", "/api/collections/users/records"]
      body = request.fetch("json")
      users << { "id" => "newuser12345678", "email" => body["email"], "password" => body["password"],
                 "role" => "user", "verified" => body.fetch("verified", false) }
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
    stdout, stderr, status = run_playbook(managed_includes("beszel", {}, path: task_path), vars)
    failures << "Beszel behavior fixture failed: #{failure_tail(stdout + stderr)}" unless status.success?
    failures << "Beszel unmanaged user was not preserved" unless users.any? { |user| user["email"] == "friend@example.invalid" }
    failures << "Beszel repair escaped role and verified" if requests.any? do |request|
      request["method"] == "PATCH" && request.fetch("json").keys.sort != %w[role verified]
    end
    %w[reader@example.invalid new@example.invalid].each do |email|
      user = users.find { |candidate| candidate["email"] == email }
      auth_index = requests.index do |request|
        request["target"] == "/api/collections/users/auth-with-password" &&
          request.dig("json", "identity") == email
      end
      patch_index = requests.index do |request|
        request["method"] == "PATCH" && request["target"].end_with?(user["id"])
      end
      failures << "Beszel #{email} was not authenticated before PATCH" unless
        auth_index && patch_index && auth_index < patch_index
    end
    failures << "Beszel final verification did not freshly list users" unless
      requests.count { |request| request["target"] == "/api/collections/users/records?perPage=500" } >= 2
    forbidden = %r{/api/collections/(universal_tokens|user_settings|systems|alerts)/}
    failures << "Beszel additional users crossed the primary ownership boundary" if
      requests.any? { |request| request["target"].match?(forbidden) }
  end
end

def exercise_paperless(failures, scenario: :normal, task_path: nil)
  state = {
    "users" => [
      { "id" => 1, "username" => "reader", "email" => "old@example.invalid",
        "password" => "reader-secret", "is_active" => true, "is_staff" => false,
        "is_superuser" => false, "groups" => ["Legacy"] },
      { "id" => 2, "username" => "friend", "email" => "friend@example.invalid",
        "password" => "friend-secret", "is_active" => true, "is_staff" => false,
        "is_superuser" => false, "groups" => ["Friends"] }
    ],
    "next_id" => 3, "tokens" => {}, "commands" => [], "events" => []
  }
  state["mangle_create"] = true if scenario == :mangled
  state["fail_after_identity_create"] = true if scenario == :create_failure
  state["users"][0]["password"] = "deployed-other-secret" if scenario == :auth_failure
  if scenario == :swap
    state["swap_on_second_list"] = true
    state["swap_username"] = "reader"
    state["replacement_id"] = 99
  end
  managed = [
    { "username" => "reader", "password" => "reader-secret", "email" => "reader@example.invalid",
      "is_active" => true, "is_staff" => true, "is_superuser" => false, "groups" => ["Readers"] },
    { "username" => "new", "password" => "new-secret", "email" => "new@example.invalid",
      "is_active" => true, "is_staff" => false, "is_superuser" => false, "groups" => ["Readers"] }
  ]
  managed = [managed.first] if scenario == :swap
  with_paperless_executor(state) do |collection_path, state_path|
    responder = lambda do |request|
      current = read_fixture_state(state_path)
      body = request.fetch("json")
      user = current["users"].find do |candidate|
        candidate["username"] == body["username"] && candidate["password"] == body["password"] &&
          candidate["is_active"]
      end
      if user
        token = "fixture-token-#{user['id']}"
        current["tokens"][token] = user["id"]
        current["events"] << "auth:#{user['username']}"
        write_fixture_state(state_path, current)
        [200, { "token" => token }]
      else
        [400, {}]
      end
    end
    with_http_service(responder) do |port, requests|
      variables = {
        "paperless_api" => "http://127.0.0.1:#{port}",
        "platform_current_dir" => "/fixture/current",
        "platform_runtime_dir" => "/fixture/runtime",
        "paperless_compose_project_name" => "fixture-paperless",
        "paperless_compose_files" => ["compose.yml"],
        "vault_managed_paperless_ngx_users" => managed
      }
      executor_env = {
        "ANSIBLE_COLLECTIONS_PATH" => collection_path,
        "PAPERLESS_FIXTURE_STATE" => state_path
      }
      arguments = scenario == :check ? ["--check"] : []
      includes = managed_includes("paperless_ngx", {}, path: task_path)
      includes = [includes.first] if %i[check create_failure].include?(scenario)
      stdout, stderr, status = run_playbook(
        includes, variables, *arguments, env: executor_env
      )
      final = read_fixture_state(state_path)
      if scenario == :create_failure
        failures << "Paperless injected create failure unexpectedly succeeded" if status.success?
        failures << "Paperless failed create left a partial managed user" if
          final["users"].any? { |user| user["username"] == "new" }
        failures << "Paperless failed create omitted rollback evidence" unless
          final["events"].include?("rollback:new")
        failures << "Paperless create failure disclosed a password" if
          ["reader-secret", "new-secret"].any? { |secret| (stdout + stderr).include?(secret) }

        final["fail_after_identity_create"] = false
        write_fixture_state(state_path, final)
        retry_stdout, retry_stderr, retry_status = run_playbook(
          managed_includes("paperless_ngx", {}, path: task_path), variables, env: executor_env
        )
        retried = read_fixture_state(state_path)
        failures << "Paperless retry after rolled-back create failed: #{failure_tail(retry_stdout + retry_stderr)}" unless
          retry_status.success?
        failures << "Paperless retry did not create exactly one managed user" unless
          retried["users"].count { |user| user["username"] == "new" } == 1
        failures << "Paperless retry diagnostics disclosed a password" if
          ["reader-secret", "new-secret"].any? do |secret|
            (retry_stdout + retry_stderr).include?(secret)
          end
      elsif scenario == :normal
        failures << "Paperless behavior fixture failed: #{failure_tail(stdout + stderr)}" unless status.success?
        reader = final["users"].find { |user| user["username"] == "reader" }
        created = final["users"].find { |user| user["username"] == "new" }
        failures << "Paperless exact non-secret repair failed" unless
          reader&.slice("email", "is_active", "is_staff", "is_superuser", "groups") == {
            "email" => "reader@example.invalid", "is_active" => true, "is_staff" => true,
            "is_superuser" => false, "groups" => ["Readers"]
          }
        failures << "Paperless absent user was not created and repaired" unless
          created && created["groups"] == ["Readers"] && created["password"] == "new-secret"
        failures << "Paperless unmanaged user was not preserved" unless
          final["users"].any? { |user| user["username"] == "friend" }
        failures << "Paperless existing user was not reauthenticated after re-list" unless
          final["events"].count("auth:reader") >= 2
        paperless_new_auth_index = final["events"].index("auth:new")
        paperless_new_repair_index = final["events"].index("repair:new")
        failures << "Paperless new user was not authenticated before repair" unless
          paperless_new_auth_index && paperless_new_repair_index &&
          paperless_new_auth_index < paperless_new_repair_index
        managed_values = managed.flat_map do |entry|
          [entry["username"], entry["email"], entry["password"], *entry["groups"]]
        end + final["tokens"].keys
        failures << "Paperless command argv contains a secret or managed value" if final["commands"].any? do |command|
          managed_values.any? { |value| command["argv"].join(" ").include?(value) }
        end
        failures << "Paperless final verification did not freshly list users" unless
          final["events"].count("list") >= 3
      elsif scenario == :mangled
        failures << "Paperless mangled-created-password fixture unexpectedly succeeded" if status.success?
        failures << "Paperless mangled-created-password fixture reached repair" if
          final["events"].include?("repair:new")
        failures << "Paperless mangled-created-password fixture missed credential assertion" unless
          (stdout + stderr).include?("Require newly created Paperless managed-user credentials")
      elsif scenario == :swap
        failures << "Paperless identity-swap fixture unexpectedly succeeded" if status.success?
        failures << "Paperless identity-swap fixture reached replacement repair" if
          final["events"].include?("repair:reader")
        failures << "Paperless identity-swap fixture missed stable-PK assertion" unless
          (stdout + stderr).include?("Require stable authenticated Paperless managed identities")
      elsif scenario == :auth_failure
        failures << "Paperless authentication-failure fixture unexpectedly succeeded" if status.success?
        failures << "Paperless authentication failure reached a mutation" if
          final["events"].any? { |event| event.start_with?("create:", "repair:") }
        failures << "Paperless authentication failure missed credential assertion" unless
          (stdout + stderr).include?("Require preserved Paperless managed-user credentials")
      else
        failures << "Paperless check-mode fixture failed: #{failure_tail(stdout + stderr)}" unless status.success?
        failures << "Paperless check mode authenticated" unless requests.empty?
        failures << "Paperless check mode mutated users" unless final["users"] == state["users"]
        failures << "Paperless check mode ran a mutation command" if
          final["events"].any? { |event| event.start_with?("create:", "repair:") }
      end
      failures << "Paperless auth fixture did not use only token endpoint" if
        requests.any? { |request| request["target"] != "/api/token/" }
    end
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
    task = managed_includes("immich", { "immich_managed_users_token" => "admin" }).first
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
      [managed_includes("immich", { "immich_managed_users_token" => "admin" }).first], vars, "--check"
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
                    { "email" => "reader@example.invalid", "password" => "reader-secret",
                      "role" => "admin", "verified" => true }
                  ] }
  with_http_service(->(_request) { [400, {}] }) do |port, requests|
    vars = beszel_vars.merge("beszel_api" => "http://127.0.0.1:#{port}")
    stdout, stderr, status = run_playbook([managed_includes("beszel").first], vars)
    failures << "Beszel existing-unverified fixture unexpectedly succeeded" if status.success?
    failures << "Beszel existing-unverified failure missed credential-migration assertion" unless
      (stdout + stderr).include?("Require preserved Beszel managed-user credentials")
    failures << "Beszel existing-unverified failure reached a mutation" if
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
      [managed_includes("immich", { "immich_managed_users_token" => "admin" }).first], vars
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

def exercise_identity_swap_refusal(failures, task_paths: {})
  immich_reads = 0
  old_immich = { "id" => "11111111-1111-4111-8111-111111111111",
                 "email" => "reader@example.invalid", "name" => "Old",
                 "quotaSizeInBytes" => 0, "status" => "active" }
  replacement_immich = old_immich.merge("id" => "22222222-2222-4222-8222-222222222222")
  with_http_service(lambda { |request|
    case [request["method"], request["target"]]
    when ["GET", "/api/admin/users?withDeleted=true"]
      immich_reads += 1
      [200, [immich_reads == 1 ? old_immich : replacement_immich]]
    when ["POST", "/api/auth/login"]
      [201, { "userId" => old_immich["id"], "userEmail" => old_immich["email"],
              "accessToken" => "user-token" }]
    else [200, {}]
    end
  }) do |port, requests|
    vars = { "immich_api" => "http://127.0.0.1:#{port}/api",
             "immich_managed_users_token" => "admin", "vault_managed_immich_users" => [
               { "email" => "reader@example.invalid", "password" => "secret",
                 "name" => "Reader", "quota_size" => 1024 }
             ] }
    stdout, stderr, status = run_playbook(
      [managed_includes("immich", { "immich_managed_users_token" => "admin" },
                        path: task_paths["immich"]).first], vars
    )
    failures << "Immich identity-swap fixture unexpectedly succeeded" if status.success?
    failures << "Immich identity-swap fixture reached replacement mutation" if
      requests.any? { |request| request["method"] == "PUT" }
    failures << "Immich identity-swap fixture missed stable-ID assertion" unless
      (stdout + stderr).include?("Require stable authenticated Immich managed identities")
  end

  old_beszel = { "id" => "reader123456789", "email" => "reader@example.invalid",
                 "role" => "user", "verified" => false }
  replacement_beszel = old_beszel.merge("id" => "replace123456789")
  with_http_service(lambda { |request|
    case [request["method"], request["target"]]
    when ["POST", "/api/collections/users/auth-with-password"]
      [200, { "record" => old_beszel, "token" => "user-token" }]
    when ["GET", "/api/collections/users/records?perPage=500"]
      [200, { "items" => [replacement_beszel], "totalPages" => 1, "totalItems" => 1 }]
    else [200, {}]
    end
  }) do |port, requests|
    vars = { "beszel_api" => "http://127.0.0.1:#{port}",
             "beszel_auth" => { "json" => { "token" => "admin" } },
             "beszel_complete_users" => {
               "json" => { "items" => [old_beszel], "totalPages" => 1, "totalItems" => 1 }
             },
             "vault_managed_beszel_users" => [
               { "email" => "reader@example.invalid", "password" => "secret",
                 "role" => "admin", "verified" => true }
             ] }
    stdout, stderr, status = run_playbook(
      [managed_includes("beszel", {}, path: task_paths["beszel"]).first], vars
    )
    failures << "Beszel identity-swap fixture unexpectedly succeeded" if status.success?
    failures << "Beszel identity-swap fixture reached replacement mutation" if
      requests.any? { |request| request["method"] == "PATCH" }
    failures << "Beszel identity-swap fixture missed stable-ID assertion" unless
      (stdout + stderr).include?("Require stable authenticated Beszel managed identities")
  end
  exercise_paperless(failures, scenario: :swap, task_path: task_paths["paperless_ngx"])
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

    if service == "beszel"
      [nil, false].each do |verified_value|
        create_mutant = Marshal.load(Marshal.dump(tasks))
        create = create_mutant.find { |task| task_name(task) == "Create absent Beszel managed users" }
        body = create.fetch("ansible.builtin.uri").fetch("body")
        verified_value.nil? ? body.delete("verified") : body["verified"] = verified_value
        detected = contract_failures(service, create_mutant).any? do |failure|
          failure.include?("authentication prerequisite")
        end
        unless detected
          failures << "beszel create verified prerequisite mutant survived"
        end
      end
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
  if failures.empty?
    unless ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
      File.executable?(File.join(directory, "ansible-playbook"))
    end
      failures << "ansible-playbook is required for database managed-user mutation fixtures"
    else
      Dir.mktmpdir("nas-platform-database-binding-mutants-") do |directory|
        task_paths = {}
        SERVICES.each do |service|
          tasks = YAML.safe_load_file(
            File.join(ROOT, "roles", service, "tasks", "managed_users.yml"), aliases: false
          )
          tasks.reject! { |task| task_name(task).start_with?("Require stable authenticated") }
          if service == "paperless_ngx"
            tasks.each do |task|
              argv = task.dig("community.docker.docker_compose_v2_exec", "argv")
              next unless argv

              argv.map! { |argument| argument.to_s.gsub("token.user_id", "expected_id") }
            end
          end
          task_paths[service] = File.join(directory, "#{service}.yml")
          File.write(task_paths[service], YAML.dump(tasks), mode: "w", perm: 0o600)
        end
        mutant_failures = []
        exercise_identity_swap_refusal(mutant_failures, task_paths: task_paths)
        SERVICES.each do |service|
          label = service == "paperless_ngx" ? "Paperless" : service.capitalize
          unless mutant_failures.any? { |failure| failure == "#{label} identity-swap fixture unexpectedly succeeded" } &&
                 mutant_failures.any? { |failure| failure.include?("#{label} identity-swap fixture reached") }
            failures << "#{service} authenticated-ID binding mutant survived behavior fixtures"
          end
        end

        beszel_create_mutant = YAML.safe_load_file(
          File.join(ROOT, "roles", "beszel", "tasks", "managed_users.yml"), aliases: false
        )
        create = beszel_create_mutant.find do |task|
          task_name(task) == "Create absent Beszel managed users"
        end
        create.fetch("ansible.builtin.uri").fetch("body").delete("verified")
        create_mutant_path = File.join(directory, "beszel_create.yml")
        File.write(create_mutant_path, YAML.dump(beszel_create_mutant), mode: "w", perm: 0o600)
        create_mutant_failures = []
        exercise_beszel(create_mutant_failures, task_path: create_mutant_path)
        unless create_mutant_failures.any? { |failure| failure.start_with?("Beszel behavior fixture failed:") }
          failures << "beszel unverified-create mutant survived behavior fixtures"
        end

        paperless_create_mutant = YAML.safe_load_file(
          File.join(ROOT, "roles", "paperless_ngx", "tasks", "managed_users.yml"), aliases: false
        )
        create = paperless_create_mutant.find do |task|
          task_name(task) == "Create absent Paperless managed users"
        end
        argv = create.fetch("community.docker.docker_compose_v2_exec").fetch("argv")
        inside_atomic = false
        argv[-1] = argv.last.lines.filter_map do |line|
          next if line.include?("from django.db import transaction")
          if line.strip == "with transaction.atomic():"
            inside_atomic = true
            next
          end
          inside_atomic && line.start_with?("    ") ? line.delete_prefix("    ") : line
        end.join
        create_mutant_path = File.join(directory, "paperless_non_atomic_create.yml")
        File.write(create_mutant_path, YAML.dump(paperless_create_mutant), mode: "w", perm: 0o600)
        create_mutant_failures = []
        exercise_paperless(
          create_mutant_failures, scenario: :create_failure, task_path: create_mutant_path
        )
        partial_commit_detected = create_mutant_failures.include?(
          "Paperless failed create left a partial managed user"
        )
        unsafe_retry_detected = create_mutant_failures.any? do |failure|
          failure.start_with?("Paperless retry after rolled-back create failed:")
        end
        unless partial_commit_detected && unsafe_retry_detected
          failures << "paperless non-atomic-create mutant survived behavior fixtures"
        end
      end
    end
  end
elsif ARGV.empty?
  if ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? { |directory| File.executable?(File.join(directory, "ansible-playbook")) }
    exercise_immich(failures)
    exercise_beszel(failures)
    exercise_paperless(failures)
    exercise_paperless(failures, scenario: :mangled)
    exercise_paperless(failures, scenario: :create_failure)
    exercise_paperless(failures, scenario: :auth_failure)
    exercise_paperless(failures, scenario: :check)
    exercise_fail_closed_and_check_mode(failures)
    exercise_verify_tag_selection(failures)
    exercise_disabled_paperless_target_rejection(failures)
    exercise_mangled_created_credentials(failures)
    exercise_identity_swap_refusal(failures)
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
