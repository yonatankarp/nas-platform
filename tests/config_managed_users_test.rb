#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "json"
require "open3"
require "shellwords"
require "tmpdir"
require "uri"
require "yaml"

require_relative "policy_support"
require_relative "http_fixture_support"

include HttpFixtureSupport
include TestScaffold

DOZZLE_TASKS = File.join(ROOT, "roles", "dozzle", "tasks", "managed_users.yml")
DOZZLE_MAIN = File.join(ROOT, "roles", "dozzle", "tasks", "main.yml")
DOZZLE_TEMPLATE = File.join(ROOT, "roles", "dozzle", "templates", "users.yml.j2")
NTFY_TASKS = File.join(ROOT, "roles", "ntfy", "tasks", "managed_users.yml")
NTFY_SUBSCRIPTION_TASKS = File.join(ROOT, "roles", "ntfy", "tasks", "subscription.yml")
NTFY_MAIN = File.join(ROOT, "roles", "ntfy", "tasks", "main.yml")
NTFY_DEFAULTS = File.join(ROOT, "roles", "ntfy", "defaults", "main.yml")
NTFY_ARGUMENT_SPECS = File.join(ROOT, "roles", "ntfy", "meta", "argument_specs.yml")
STATE_FILTER = File.join(ROOT, "filter_plugins", "managed_user_state.py")
SAFE_SLURP = File.join(ROOT, "library", "atomic_safe_slurp.py")
VALIDATE_POLICY = File.join(ROOT, "tests", "validate-policy.sh")

BCRYPT_A = "$2b$12$aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
BCRYPT_B = "$2b$12$bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
TOKEN_A = "tk_aaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
TOKEN_B = "tk_bbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

SOURCE_REQUIREMENTS = {
  "Dozzle safe load" => ["dozzle_tasks", "managed_users_yaml"],
  "Dozzle atomic read" => ["dozzle_tasks", "atomic_safe_slurp"],
  "Dozzle explicit presence" => ["dozzle_tasks", "dozzle_existing_key_present"],
  "Dozzle hash refusal" => ["dozzle_tasks", "will not replace"],
  "Dozzle unmanaged preservation" => ["dozzle_tasks", "dozzle_unmanaged_users"],
  "Dozzle rendered loop" => ["dozzle_template", "{% for"],
  "Dozzle managed authentication" => ["dozzle_main", "vault_managed_dozzle_users"],
  "strict YAML alias refusal" => ["state_filter", "yaml.tokens.AnchorToken"],
  "strict YAML duplicate refusal" => ["state_filter", "duplicate normalized user identities"],
  "ntfy prior ownership preflight" => ["ntfy_main", "Inspect existing ntfy declarative ownership and users"],
  "ntfy authoritative CLI" => ["ntfy_main", "community.docker.docker_compose_v2_run"],
  "ntfy user provisioning" => ["ntfy_tasks", "ntfy_auth_users"],
  "ntfy owned hash refusal" => ["ntfy_tasks", "Refuse password hash replacement for owned ntfy identities"],
  "ntfy unmanaged adoption refusal" => ["ntfy_tasks", "Refuse automatic adoption of unmanaged ntfy identities"],
  "ntfy token ownership" => ["ntfy_tasks", "Refuse duplicate ntfy token ownership"],
  "ntfy Basic authentication" => ["ntfy_tasks", "force_basic_auth: true"],
  "ntfy declared access verification" => ["ntfy_tasks", "Verify managed ntfy declared write access"],
  "ntfy account subscription preflight" => ["ntfy_tasks", "Read all eligible managed ntfy accounts before subscription mutation"],
  "ntfy account subscription mutation" => ["ntfy_subscription_tasks", "Create missing managed ntfy account subscriptions"],
  "ntfy account subscription post-read" => ["ntfy_subscription_tasks", "Re-read managed ntfy accounts after subscription creation"],
  "policy registration" => ["validate_policy", "config_managed_users_test.rb --self-test"],
  "filter behavior registration" => ["validate_policy", "managed_user_state_filter_test.py"]
}.freeze

def read(path)
  File.read(path)
rescue Errno::ENOENT
  ""
end

def command_available?(name)
  ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
    File.executable?(File.join(directory, name))
  end
end

def command_path(name)
  ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map do |directory|
    File.join(directory, name)
  end.find { |path| File.executable?(path) }
end

def ansible_python
  shebang = Shellwords.split(
    File.open(command_path("ansible-playbook"), &:readline).delete_prefix("#!").strip
  )
  if File.basename(shebang.first.to_s) == "env"
    shebang.shift
    shebang.shift if shebang.first == "-S"
    shebang.shift while shebang.first&.match?(/\A[A-Za-z_][A-Za-z0-9_]*=/)
    interpreter = command_path(shebang.first.to_s)
  else
    interpreter = shebang.first
  end
  raise "ansible-playbook interpreter is unavailable" unless File.executable?(interpreter)

  interpreter
end

def source_fragment_failures(sources)
  SOURCE_REQUIREMENTS.filter_map do |label, (source_name, fragment)|
    label unless sources.fetch(source_name).include?(fragment)
  end
end

def run_playbook(source, extra_vars = {})
  Dir.mktmpdir("nas-platform-config-managed-users-") do |directory|
    playbook = File.join(directory, "playbook.yml")
    File.write(playbook, source, mode: "w", perm: 0o600)
    stdout, stderr, status = Open3.capture3(
      { "ANSIBLE_NOCOLOR" => "1" },
      "ansible-playbook", "-i", "localhost,", "-c", "local", playbook,
      "-e", JSON.generate(extra_vars), chdir: ROOT
    )
    yield directory, stdout + stderr, status
  end
end

# A responder answers either a full {status, body, content_type} record or a
# bare status, which is how the refusal cases stay a single number.
def with_http_probe(expected_count, responder, &block)
  requests = []
  reasons = { 200 => "OK", 403 => "Forbidden", 409 => "Conflict" }.freeze
  with_http_fixture(->(port) { block.call(port, requests) },
                    reason: reasons) do |method, target, headers, body|
    request = { "method" => method, "target" => target, "headers" => headers, "body" => body }
    requests << request
    response = responder.call(request)
    next [response, "", "text/plain"] unless response.is_a?(Hash)

    [response.fetch("status"), response.fetch("body", ""),
     response.fetch("content_type", "application/json")]
  end
  raise "HTTP probe request count differs" unless requests.length == expected_count
end

def task_playbook(tasks, variables)
  YAML.dump([
    {
      "hosts" => "localhost",
      "gather_facts" => false,
      "vars" => variables,
      "tasks" => tasks
    }
  ])
end

def ntfy_main_order_valid?(tasks)
  names = tasks.map { |task| task["name"] }
  preflight = names.index("Inspect existing ntfy declarative ownership and users")
  provision = names.index("Resolve declarative ntfy managed-user provisioning")
  render = names.index("Render the ntfy environment")
  deploy = names.index("Deploy ntfy")
  preflight && provision && render && deploy &&
    preflight < provision && provision < render && provision < deploy
end

def ntfy_cli_probe_valid?(tasks)
  probe = tasks.find { |task| task["name"] == "List authoritative existing ntfy users" }
  run = probe&.fetch("community.docker.docker_compose_v2_run", nil)
  run && run["service"] == "ntfy" && run["cleanup"] == true &&
    run["no_deps"] == true && run["tty"] == false && run["interactive"] == true &&
    !run.key?("stdin") &&
    probe["changed_when"] == false && probe["failed_when"] == false &&
    probe["check_mode"] != false && probe["no_log"] == true &&
    Array(probe["when"]).include?("not ansible_check_mode") &&
    run["argv"] == [
      "user", "--auth-file=/var/lib/ntfy/auth.db",
      "--auth-default-access=deny-all", "list"
    ]
end

def ntfy_verify_contract_valid?(tasks)
  auth = tasks.find { |task| task["name"] == "Basic-authenticate each managed ntfy user" }
  read_access = tasks.find { |task| task["name"] == "Verify managed ntfy declared read access" }
  write_access = tasks.find { |task| task["name"] == "Verify managed ntfy declared write access" }
  return false unless auth && read_access && write_access

  auth_request = auth["ansible.builtin.uri"]
  read_request = read_access["ansible.builtin.uri"]
  write_request = write_access["ansible.builtin.uri"]
  common_safe = [auth, read_access, write_access].all? do |task|
    request = task["ansible.builtin.uri"]
    request["force_basic_auth"] == true && task["changed_when"] == false &&
      task["check_mode"] != false && task["no_log"] == true
  end
  common_safe &&
    auth_request == {
      "url" => "{{ ntfy_account_api }}", "url_username" => "{{ item.username }}",
      "url_password" => "{{ item.password }}", "force_basic_auth" => true,
      "status_code" => [200]
    } &&
    read_request["url"] == "http://127.0.0.1:{{ ntfy_port }}/{{ item.1.topic }}/json?poll=1" &&
    read_request["url_username"] == "{{ item.0.username }}" &&
    read_request["url_password"] == "{{ item.0.password }}" &&
    write_request["url"] == "http://127.0.0.1:{{ ntfy_port }}/{{ item.1.topic }}" &&
    write_request["method"] == "POST" &&
    write_request["body"] == "Managed-user provisioning verification" &&
    write_request["url_username"] == "{{ item.0.username }}" &&
    write_request["url_password"] == "{{ item.0.password }}" &&
    Array(write_access["when"]).include?("not ansible_check_mode")
end

def with_ntfy_task_removed(task_name)
  tasks = YAML.safe_load_file(NTFY_TASKS, aliases: false)
  removed = tasks.reject { |task| task["name"] == task_name }
  return yield(nil, false) if removed.length == tasks.length

  Dir.mktmpdir("nas-platform-ntfy-mutant-") do |directory|
    path = File.join(directory, "managed_users.yml")
    File.write(path, YAML.dump(removed), mode: "w", perm: 0o600)
    yield(path, true)
  end
end

def dozzle_playbook(users_path, output_path)
  <<~YAML
    ---
    - hosts: localhost
      gather_facts: false
      vars:
        dozzle_users_path: #{users_path.to_json}
        vault_dozzle_admin_username: admin
        vault_dozzle_admin_password_hash: #{BCRYPT_A.to_json}
        vault_managed_dozzle_users:
          - username: reader
            password: managed-plaintext
            password_hash: #{BCRYPT_B.to_json}
            email: reader@example.invalid
            name: Managed Reader
            filter: status=running
            roles: user
        dozzle_managed_users_phase: reconcile
      tasks:
        - ansible.builtin.include_tasks: #{DOZZLE_TASKS.to_json}
        - ansible.builtin.template:
            src: #{DOZZLE_TEMPLATE.to_json}
            dest: #{output_path.to_json}
            mode: "0600"
  YAML
end

def run_dozzle_fixture(source)
  result = nil
  Dir.mktmpdir("nas-platform-dozzle-users-") do |directory|
    users_path = File.join(directory, "users.yml")
    output_path = File.join(directory, "rendered.yml")
    File.write(users_path, source, mode: "w", perm: 0o600)
    run_playbook(dozzle_playbook(users_path, output_path)) do |_tmp, output, status|
      rendered = if status.success? && File.file?(output_path)
                   YAML.safe_load_file(output_path, aliases: false)
                 end
      result = [rendered, output, status]
    end
  end
  result
end

def ntfy_playbook(output_path, tasks_path = NTFY_TASKS)
  <<~YAML
    ---
    - hosts: localhost
      gather_facts: false
      vars:
        ntfy_topic: nas-critical
        ntfy_containers_topic: nas-containers
        ntfy_verification_topic: nas-verification
        ntfy_topics: [nas-critical, nas-deployment, nas-containers]
        ntfy_publishable_topics:
          [nas-critical, nas-deployment, nas-containers, nas-verification]
        vault_ntfy_admin_user: admin
        vault_ntfy_admin_password_hash: #{BCRYPT_A.to_json}
        ntfy_publishers:
          - name: dozzle
            password_hash: #{BCRYPT_A.to_json}
            token: #{TOKEN_A}
            topics: [nas-critical, nas-containers, nas-verification]
        vault_managed_ntfy_users:
          - username: reader
            password: managed-plaintext
            password_hash: #{BCRYPT_B.to_json}
            role: user
            access:
              - topic: nas-critical
                permission: read-only
              - topic: private
                permission: deny
            tokens: [#{TOKEN_B}]
        ntfy_prior_provisioned_users:
          admin: {username: admin, password_hash: #{BCRYPT_A.to_json}, role: admin}
          dozzle: {username: dozzle, password_hash: #{BCRYPT_A.to_json}, role: user}
          reader: {username: reader, password_hash: #{BCRYPT_B.to_json}, role: user}
        ntfy_existing_user_records:
          '*': {username: '*', role: anonymous, provisioned: false}
          admin: {username: admin, role: admin, provisioned: true}
          dozzle: {username: dozzle, role: user, provisioned: true}
          reader: {username: reader, role: user, provisioned: true}
        ntfy_authoritative_absence_established: true
        ntfy_managed_users_phase: provision
      tasks:
        - ansible.builtin.include_tasks: #{tasks_path.to_json}
        - ansible.builtin.copy:
            dest: #{output_path.to_json}
            mode: "0600"
            content: >-
              {{ {'users': ntfy_auth_users, 'access': ntfy_auth_access,
                  'tokens': ntfy_auth_tokens} | to_json }}
  YAML
end

def run_ntfy_fixture(extra_vars = {}, tasks_path = NTFY_TASKS)
  result = nil
  Dir.mktmpdir("nas-platform-ntfy-users-") do |directory|
    output_path = File.join(directory, "provisioning.json")
    run_playbook(ntfy_playbook(output_path, tasks_path), extra_vars) do |_tmp, output, status|
      rendered = JSON.parse(File.read(output_path)) if status.success? && File.file?(output_path)
      result = [rendered, output, status]
    end
  end
  result
end

def run_ntfy_subscription_fixture(
  users:, subscriptions:, expected_requests:, conflict_modes: {}, malformed_accounts: {},
  create_responses: {}, post_read_subscriptions: {}, runs: 1
)
  result = nil
  requests_by_user = []
  with_http_probe(expected_requests, proc do |request|
    encoded = request.dig("headers", "authorization").to_s.delete_prefix("Basic ")
    username = Base64.strict_decode64(encoded).split(":", 2).first
    requests_by_user << [username, request["method"], request["target"]]
    if request["method"] == "GET" && request["target"] == "/v1/account"
      account = malformed_accounts.fetch(username) do
        {
          "username" => username,
          "role" => "user",
          "subscriptions" => subscriptions.fetch(username, [])
        }
      end
      { "status" => 200, "body" => JSON.generate(account) }
    elsif request["method"] == "POST" && request["target"] == "/v1/account/subscription"
      requested = JSON.parse(request["body"])
      desired = requested.merge("display_name" => nil)
      case conflict_modes[username]
      when :create
        subscriptions[username] = subscriptions.fetch(username, []) + [desired]
        {
          "status" => 409,
          "body" => JSON.generate(
            "code" => 40903, "http" => 409,
            "error" => "conflict: topic subscription already exists"
          )
        }
      when :reject
        {
          "status" => 409,
          "body" => JSON.generate(
            "code" => 40903, "http" => 409,
            "error" => "conflict: topic subscription already exists"
          )
        }
      when :duplicate
        subscriptions[username] = subscriptions.fetch(username, []) + [desired, desired.dup]
        {
          "status" => 409,
          "body" => JSON.generate(
            "code" => 40903, "http" => 409,
            "error" => "conflict: topic subscription already exists"
          )
        }
      when :wrong_code
        {
          "status" => 409,
          "body" => JSON.generate(
            "code" => 40901, "http" => 409, "error" => "conflict: user already exists"
          )
        }
      else
        subscriptions[username] = subscriptions.fetch(username, []) + [desired]
        response = { "status" => 200, "body" => JSON.generate(create_responses.fetch(username, desired)) }
        subscriptions[username] = post_read_subscriptions.fetch(username) if
          post_read_subscriptions.key?(username)
        response
      end
    else
      { "status" => 500, "body" => JSON.generate("unexpected" => true) }
    end
  end) do |port, requests|
    base_url = "http://127.0.0.1:#{port}"
    subscriptions.each_value do |entries|
      next unless entries.is_a?(Array)

      entries.each do |entry|
        entry["base_url"] = base_url if entry["base_url"] == "DESIRED_BASE_URL"
      end
    end
    variables = {
      "ntfy_account_api" => "#{base_url}/v1/account",
      "ntfy_account_subscription_api" => "#{base_url}/v1/account/subscription",
      "ntfy_base_url" => base_url,
      "ntfy_topics" => %w[nas-critical nas-deployment nas-containers],
      "ntfy_managed_users_phase" => "subscription_sync",
      "vault_managed_ntfy_users" => users
    }
    include_task = { "ansible.builtin.include_tasks" => NTFY_TASKS }
    outputs = []
    statuses = []
    runs.times do
      run_playbook(task_playbook([include_task], variables)) do |_tmp, output, status|
        outputs << output
        statuses << status
      end
    end
    result = [subscriptions, requests.dup, requests_by_user, outputs, statuses, base_url]
  end
  result
end

failures = []
abort "Config managed users: ansible-playbook is required for behavior coverage" unless
  command_available?("ansible-playbook")

dozzle_tasks = read(DOZZLE_TASKS)
dozzle_main = read(DOZZLE_MAIN)
dozzle_template = read(DOZZLE_TEMPLATE)
ntfy_tasks = read(NTFY_TASKS)
ntfy_subscription_tasks = read(NTFY_SUBSCRIPTION_TASKS)
ntfy_main = read(NTFY_MAIN)
ntfy_defaults = read(NTFY_DEFAULTS)
ntfy_argument_specs = read(NTFY_ARGUMENT_SPECS)
state_filter = read(STATE_FILTER)
safe_slurp = read(SAFE_SLURP)

check(failures, !dozzle_tasks.empty?, "Dozzle managed-user tasks are missing")
check(failures, dozzle_main.include?("managed_users.yml"), "Dozzle main tasks do not include managed-user reconciliation")
check(failures, dozzle_tasks.include?("managed_users_yaml"),
      "Dozzle does not strictly safe-load the existing users file")
check(failures,
      dozzle_tasks.include?("atomic_safe_slurp:") &&
        dozzle_tasks.include?("max_bytes: 1048576") &&
        !dozzle_tasks.include?("ansible.builtin.slurp") &&
        !dozzle_tasks.include?("dozzle_existing_users_stat"),
      "Dozzle does not atomically read a bounded regular users file")
check(failures, dozzle_tasks.include?("rescue:"), "Dozzle does not reject malformed YAML explicitly")
check(failures, dozzle_tasks.include?("dozzle_existing_normalized_names") &&
                dozzle_tasks.include?("unique | length"),
      "Dozzle does not reject duplicate normalized existing names")
check(failures, dozzle_tasks.include?("password") && dozzle_tasks.include?("password_hash") &&
                dozzle_tasks.include?("will not replace"),
      "Dozzle does not refuse stored hash replacement")
check(failures, dozzle_tasks.include?("dozzle_unmanaged_users") &&
                dozzle_tasks.include?("dozzle_reconciled_users"),
      "Dozzle does not preserve and merge unmanaged users")
check(failures, dozzle_template.include?("{% for") && dozzle_template.include?("to_json"),
      "Dozzle users template does not safely loop over reconciled users")
check(failures, dozzle_main.include?("when: dozzle_users_file.changed"),
      "Dozzle restart is not conditional on users file change")
check(failures, dozzle_main.include?("{{ dozzle_api }}/token") &&
                dozzle_main.include?("vault_managed_dozzle_users"),
      "Dozzle does not authenticate every managed plaintext password at api/token")
dozzle_main_tasks = YAML.safe_load(dozzle_main, aliases: false) || []
dozzle_health_index = dozzle_main_tasks.index { |task| task["name"] == "Wait for Dozzle to report healthy" }
dozzle_auth_index = dozzle_main_tasks.index { |task| task["name"] == "Authenticate each managed Dozzle user" }
dozzle_auth_task = dozzle_main_tasks[dozzle_auth_index] if dozzle_auth_index
dozzle_auth_request = dozzle_auth_task&.fetch("ansible.builtin.uri", nil)
check(failures,
      dozzle_health_index && dozzle_auth_index && dozzle_health_index < dozzle_auth_index &&
        dozzle_auth_request == {
          "url" => "{{ dozzle_api }}/token", "method" => "POST",
          "body_format" => "form-urlencoded",
          "body" => { "username" => "{{ item.username }}", "password" => "{{ item.password }}" },
          "status_code" => [200]
        } && dozzle_auth_task["loop"] == "{{ vault_managed_dozzle_users }}" &&
        dozzle_auth_task["changed_when"] == false && dozzle_auth_task["check_mode"] == false &&
        dozzle_auth_task["no_log"] == true,
      "Dozzle managed authentication request or health ordering differs")

if dozzle_auth_task
  responder = proc { |_request| 200 }
  with_http_probe(1, responder) do |port, requests|
    variables = {
      "dozzle_api" => "http://127.0.0.1:#{port}/api",
      "vault_managed_dozzle_users" => [
        { "username" => "reader", "password" => "managed-plaintext" }
      ]
    }
    run_playbook(task_playbook([dozzle_auth_task], variables)) do |_tmp, output, status|
      check(failures, status.success?, "Dozzle authentication fixture failed: #{output.lines.last&.strip}")
    end
    request = requests.first || {}
    check(failures,
          request["method"] == "POST" && request["target"] == "/api/token" &&
            request["body"] == URI.encode_www_form(
              "username" => "reader", "password" => "managed-plaintext"
            ),
          "Dozzle authentication fixture sent a different method, endpoint, or body")
  end
end

if !dozzle_tasks.empty?
  existing = {
    "users" => {
      "admin" => { "email" => "old", "name" => "Wrong", "password" => BCRYPT_A,
                     "filter" => "old", "roles" => "admin" },
      "reader" => { "email" => "old", "name" => "Wrong", "password" => BCRYPT_B,
                      "filter" => "old", "roles" => "none", "stale" => true },
      "unmanaged" => { "password" => "opaque", "custom" => { "nested" => [1, "two"] } }
    },
    "outside" => { "preserved" => true }
  }
  rendered, output, status = run_dozzle_fixture(YAML.dump(existing))
  check(failures, status.success?, "Dozzle merge fixture failed: #{output.lines.last&.strip}")
  if rendered
    check(failures, rendered["outside"] == existing["outside"], "Dozzle did not preserve root keys outside users")
    check(failures, rendered.dig("users", "unmanaged") == existing.dig("users", "unmanaged"),
          "Dozzle did not preserve an unmanaged user verbatim")
    check(failures, rendered.dig("users", "reader") == {
            "email" => "reader@example.invalid", "name" => "Managed Reader",
            "password" => BCRYPT_B, "filter" => "status=running", "roles" => "user"
          }, "Dozzle did not render the exact managed non-secret fields")
  end

  _rendered, _output, status = run_dozzle_fixture("users: [malformed mapping]\n")
  check(failures, !status.success?, "Dozzle accepted a malformed users document")
  hash_change = Marshal.load(Marshal.dump(existing))
  hash_change["users"]["reader"]["password"] = BCRYPT_A
  _rendered, output, status = run_dozzle_fixture(YAML.dump(hash_change))
  check(failures, !status.success? && output.include?("will not replace"),
        "Dozzle accepted a hash change for an existing allowlisted identity")
  duplicate_names = Marshal.load(Marshal.dump(existing))
  duplicate_names["users"][" Reader "] = duplicate_names["users"]["reader"]
  _rendered, _output, status = run_dozzle_fixture(YAML.dump(duplicate_names))
  check(failures, !status.success?, "Dozzle accepted duplicate normalized existing identities")

  {
    "empty scalar" => "",
    "empty list" => [],
    "null" => nil,
    "missing password" => {}
  }.each do |label, unsafe_entry|
    unsafe_existing = Marshal.load(Marshal.dump(existing))
    unsafe_existing["users"]["reader"] = unsafe_entry
    _rendered, unsafe_output, unsafe_status = run_dozzle_fixture(YAML.dump(unsafe_existing))
    check(failures, !unsafe_status.success? && unsafe_output.include?("will not replace"),
          "Dozzle treated an existing #{label} allowlisted entry as absent")
  end

  unsafe_yaml_documents = {
    "malformed syntax" => "users: [unterminated\n",
    "alias" => "shared: &shared {password: #{BCRYPT_B}}\nusers: {reader: *shared}\n",
    "exact duplicate" => (
      "users:\n  reader: {password: wrong}\n" \
      "  reader: {password: #{BCRYPT_B}}\n"
    ),
    "multiple documents" => "users: {}\n---\nusers: {}\n"
  }
  unsafe_yaml_documents.each do |label, unsafe_source|
    _rendered, _unsafe_output, unsafe_status = run_dozzle_fixture(unsafe_source)
    check(failures, !unsafe_status.success?, "Dozzle accepted #{label} YAML")
  end
end

check(failures, !ntfy_tasks.empty?, "ntfy managed-user tasks are missing")
check(failures, ntfy_main.include?("managed_users.yml"), "ntfy main tasks do not include managed-user provisioning")
check(failures, ntfy_tasks.include?("ntfy_auth_users") && ntfy_tasks.include?("ntfy_auth_access") &&
                ntfy_tasks.include?("ntfy_auth_tokens"),
      "ntfy does not derive all three declarative provisioning values")
check(failures, ntfy_tasks.include?("Refuse duplicate ntfy identities") &&
                ntfy_tasks.include?("Refuse duplicate ntfy token ownership"),
      "ntfy does not refuse identity and token collisions")
check(failures, ntfy_tasks.include?("vault_ntfy_admin_user") && ntfy_tasks.include?("ntfy_publishers"),
      "ntfy does not separate the administrator and publishers")
check(failures, ntfy_tasks.include?("url_username") && ntfy_tasks.include?("force_basic_auth: true") &&
                ntfy_tasks.include?("vault_managed_ntfy_users"),
      "ntfy does not Basic-authenticate every managed user")
check(failures, ntfy_tasks.include?("Verify managed ntfy declared read access") &&
                ntfy_tasks.include?("Verify managed ntfy declared write access"),
      "ntfy does not verify each declared topic permission")
check(failures,
      ntfy_defaults.include?("ntfy_account_subscription_api:") &&
        ntfy_argument_specs.include?("ntfy_account_subscription_api:"),
      "ntfy does not declare the pinned account-subscription endpoint")
ntfy_managed_tasks = YAML.safe_load(ntfy_tasks, aliases: false) || []
managed_subscription_task_names = [
  "Validate managed ntfy subscription eligibility",
  "Read all eligible managed ntfy accounts before subscription mutation",
  "Validate all eligible managed ntfy account responses",
  "Refuse duplicate desired ntfy account subscriptions",
  "Read eligible managed ntfy accounts for subscription verification",
  "Verify synchronized managed ntfy account subscriptions"
]
atomic_subscription_task_names = [
  "Create missing managed ntfy account subscriptions",
  "Validate provisional managed ntfy duplicate-subscription conflicts",
  "Re-read managed ntfy accounts after subscription creation",
  "Validate synchronized managed ntfy account subscriptions"
]
check(failures,
      managed_subscription_task_names.all? { |name| ntfy_tasks.include?(name) } &&
        atomic_subscription_task_names.all? { |name| ntfy_subscription_tasks.include?(name) },
      "ntfy account subscription synchronization is incomplete")
check(failures,
      begin
        parsed_subscription_tasks = YAML.safe_load(ntfy_subscription_tasks, aliases: false) || []
        create_task = parsed_subscription_tasks.find do |task|
          task["name"] == "Create missing managed ntfy account subscriptions"
        end
        request = create_task&.fetch("ansible.builtin.uri", nil)
        request && request["url"] == "{{ ntfy_account_subscription_api }}" &&
          request["method"] == "POST" && request["body_format"] == "json" &&
          request["body"] == {
            "base_url" => "{{ ntfy_base_url }}",
            "topic" => "{{ ntfy_subscription_pair.topic }}"
          } && request["status_code"] == [200, 409]
      end,
      "ntfy account subscription request differs from the pinned v2.27 interface")
check(failures,
      ntfy_tasks.include?("read-only") && ntfy_tasks.include?("read-write") &&
        ntfy_tasks.include?("item.role == 'user'") &&
        !ntfy_tasks.include?("web-push") && !ntfy_tasks.include?("local-storage"),
      "ntfy subscription eligibility or browser-state boundary differs")
check(failures,
      ntfy_subscription_tasks.include?("ntfy_subscription_create.json.code == 40903") &&
        ntfy_subscription_tasks.include?("['code', 'error', 'http']"),
      "ntfy provisional conflict validation differs from pinned v2.27 error 40903")

subscription_users = [
  {
    "username" => "reader", "password" => "reader-password", "role" => "user",
    "access" => [{ "topic" => "nas-critical", "permission" => "read-only" }]
  },
  {
    "username" => "writer", "password" => "writer-password", "role" => "user",
    "access" => [{ "topic" => "nas-critical", "permission" => "write-only" }]
  },
  {
    "username" => "private-reader", "password" => "private-password", "role" => "user",
    "access" => [{ "topic" => "private", "permission" => "read-write" }]
  },
  {
    "username" => "read-writer", "password" => "rw-password", "role" => "user",
    "access" => [{ "topic" => "nas-critical", "permission" => "read-write" }]
  }
]
unrelated = {
  "base_url" => "https://unrelated.invalid", "topic" => "other-topic", "display_name" => "Other"
}
initial_subscriptions = {
  "reader" => [unrelated.dup],
  "read-writer" => [{
    "base_url" => "DESIRED_BASE_URL", "topic" => "nas-critical", "display_name" => "Critical"
  }],
  "publisher" => [{
    "base_url" => "DESIRED_BASE_URL", "topic" => "nas-critical", "display_name" => "Critical"
  }]
}
state, requests, requests_by_user, outputs, statuses, base_url = run_ntfy_subscription_fixture(
  users: subscription_users,
  subscriptions: initial_subscriptions,
  expected_requests: 6,
  runs: 2
)
check(failures, statuses.all?(&:success?),
      "ntfy eligible subscription synchronization or idempotence failed: #{outputs.last&.lines&.last&.strip}")
check(failures, requests_by_user == [
        ["reader", "GET", "/v1/account"],
        ["read-writer", "GET", "/v1/account"],
        ["reader", "POST", "/v1/account/subscription"],
        ["reader", "GET", "/v1/account"],
        ["reader", "GET", "/v1/account"],
        ["read-writer", "GET", "/v1/account"]
      ], "ntfy synchronized ineligible users or was not idempotent")
desired = { "base_url" => base_url, "topic" => "nas-critical", "display_name" => nil }
check(failures, state.fetch("reader") == [unrelated, desired],
      "ntfy did not preserve the unrelated subscription while adding the desired one")
post = requests.find { |request| request["method"] == "POST" }
check(failures, post && JSON.parse(post["body"]) == desired.reject { |key, _value| key == "display_name" },
      "ntfy subscription create body differs from the exact supported pair")

duplicate_subscriptions = {
  "reader" => [],
  "read-writer" => [
    { "base_url" => "DESIRED_BASE_URL", "topic" => "nas-critical", "display_name" => "" },
    { "base_url" => "DESIRED_BASE_URL", "topic" => "nas-critical", "display_name" => "" }
  ]
}
_state, _requests, duplicate_calls, _outputs, duplicate_statuses, =
  run_ntfy_subscription_fixture(
    users: subscription_users,
    subscriptions: duplicate_subscriptions,
    expected_requests: 2
  )
check(failures,
      !duplicate_statuses.first.success? && duplicate_calls == [
        ["reader", "GET", "/v1/account"],
        ["read-writer", "GET", "/v1/account"]
      ], "ntfy mutated an earlier user before rejecting a later duplicate subscription")

# Two provisioned topics, and an account that may read both. Each topic is a
# separate subscription, and a topic the account cannot read is never created.
both_topics_user = [
  {
    "username" => "reader", "password" => "reader-password", "role" => "user",
    "access" => [
      { "topic" => "nas-critical", "permission" => "read-only" },
      { "topic" => "nas-containers", "permission" => "read-only" }
    ]
  },
  {
    "username" => "critical-only", "password" => "critical-password", "role" => "user",
    "access" => [{ "topic" => "nas-critical", "permission" => "read-only" }]
  }
]
both_state, _requests, both_calls, both_outputs, both_statuses, both_base =
  run_ntfy_subscription_fixture(
    users: both_topics_user,
    subscriptions: { "reader" => [], "critical-only" => [] },
    expected_requests: 8
  )
check(failures, both_statuses.all?(&:success?),
      "ntfy multi-topic subscription synchronization failed: " \
      "#{both_outputs.last&.lines&.last&.strip}")
check(failures,
      both_state.fetch("reader") == [
        { "base_url" => both_base, "topic" => "nas-critical", "display_name" => nil },
        { "base_url" => both_base, "topic" => "nas-containers", "display_name" => nil }
      ],
      "ntfy did not subscribe a both-topic reader to both topics")
check(failures,
      both_state.fetch("critical-only") == [
        { "base_url" => both_base, "topic" => "nas-critical", "display_name" => nil }
      ],
      "ntfy subscribed an account to a topic it may not read")
check(failures,
      both_calls.count { |call| call[0] == "critical-only" && call[1] == "POST" } == 1,
      "ntfy did not create exactly one subscription for the critical-only reader")

malformed_account = {
  "username" => "read-writer", "role" => "user", "subscriptions" => "invalid"
}
_state, _requests, malformed_calls, _outputs, malformed_statuses, =
  run_ntfy_subscription_fixture(
    users: subscription_users,
    subscriptions: { "reader" => [], "read-writer" => [] },
    malformed_accounts: { "read-writer" => malformed_account },
    expected_requests: 2
  )
check(failures,
      !malformed_statuses.first.success? && malformed_calls.none? { |call| call[1] == "POST" },
      "ntfy mutated an earlier user before rejecting a later account schema")

accepted_state, _requests, accepted_calls, accepted_outputs, accepted_statuses, accepted_base =
  run_ntfy_subscription_fixture(
    users: [subscription_users.first],
    subscriptions: { "reader" => [] },
    conflict_modes: { "reader" => :create },
    expected_requests: 3
  )
check(failures,
      accepted_statuses.first.success? && accepted_calls.map { |call| call[1] } == %w[GET POST GET] &&
        accepted_state.fetch("reader") == [{
          "base_url" => accepted_base, "topic" => "nas-critical", "display_name" => nil
        }],
      "ntfy did not accept a provisional 409 only after an authoritative exact match")

_state, _requests, rejected_calls, rejected_outputs, rejected_statuses, =
  run_ntfy_subscription_fixture(
    users: [subscription_users.first],
    subscriptions: { "reader" => [] },
    conflict_modes: { "reader" => :reject },
    expected_requests: 3
  )
check(failures,
      !rejected_statuses.first.success? && rejected_calls.map { |call| call[1] } == %w[GET POST GET],
      "ntfy accepted a 409 without an authoritative desired subscription")

%i[reject duplicate].each do |mode|
  _state, _requests, blocked_calls, _outputs, blocked_statuses, =
    run_ntfy_subscription_fixture(
      users: [subscription_users.first, subscription_users.last],
      subscriptions: { "reader" => [], "read-writer" => [] },
      conflict_modes: { "reader" => mode },
      expected_requests: 4
    )
  check(failures,
        !blocked_statuses.first.success? && blocked_calls == [
          ["reader", "GET", "/v1/account"],
          ["read-writer", "GET", "/v1/account"],
          ["reader", "POST", "/v1/account/subscription"],
          ["reader", "GET", "/v1/account"]
        ], "ntfy mutated a later user after an unresolved #{mode} 409")
end

_state, _requests, wrong_code_calls, _outputs, wrong_code_statuses, =
  run_ntfy_subscription_fixture(
    users: [subscription_users.first, subscription_users.last],
    subscriptions: { "reader" => [], "read-writer" => [] },
    conflict_modes: { "reader" => :wrong_code },
    expected_requests: 3
  )
check(failures,
      !wrong_code_statuses.first.success? && wrong_code_calls.last == [
        "reader", "POST", "/v1/account/subscription"
      ], "ntfy accepted or re-read a non-40903 conflict")

_state, _requests, continued_calls, continued_outputs, continued_statuses, =
  run_ntfy_subscription_fixture(
    users: [subscription_users.first, subscription_users.last],
    subscriptions: { "reader" => [], "read-writer" => [] },
    conflict_modes: { "reader" => :create },
    expected_requests: 6
  )
check(failures,
      continued_statuses.first.success? && continued_calls.map { |call| [call[0], call[1]] } == [
        ["reader", "GET"], ["read-writer", "GET"], ["reader", "POST"],
        ["reader", "GET"], ["read-writer", "POST"], ["read-writer", "GET"]
      ], "ntfy did not resolve each missing user before mutating the next")

subscription_schema_mutations = {
  "missing display_name" => { "base_url" => "DESIRED_BASE_URL", "topic" => "nas-critical" },
  "extra field" => {
    "base_url" => "DESIRED_BASE_URL", "topic" => "nas-critical", "display_name" => "", "extra" => true
  },
  "wrong display_name type" => {
    "base_url" => "DESIRED_BASE_URL", "topic" => "nas-critical", "display_name" => 7
  },
  "wrong base_url type" => {
    "base_url" => 7, "topic" => "nas-critical", "display_name" => ""
  }
}
subscription_schema_mutations.each do |label, invalid_subscription|
  _state, _requests, schema_calls, _outputs, schema_statuses, =
    run_ntfy_subscription_fixture(
      users: [subscription_users.first, subscription_users.last],
      subscriptions: { "reader" => [], "read-writer" => [invalid_subscription] },
      expected_requests: 2
    )
  check(failures,
        !schema_statuses.first.success? && schema_calls.none? { |call| call[1] == "POST" },
        "ntfy accepted #{label} in a preflight subscription entry")
end

invalid_create_response = {
  "base_url" => "wrong", "topic" => "nas-critical", "display_name" => nil, "extra" => true
}
_state, _requests, create_schema_calls, _outputs, create_schema_statuses, =
  run_ntfy_subscription_fixture(
    users: [subscription_users.first],
    subscriptions: { "reader" => [] },
    create_responses: { "reader" => invalid_create_response },
    expected_requests: 2
  )
check(failures,
      !create_schema_statuses.first.success? && create_schema_calls.map { |call| call[1] } == %w[GET POST],
      "ntfy accepted an invalid HTTP 200 subscription response")

invalid_post_read = [{
  "base_url" => "DESIRED_BASE_URL", "topic" => "nas-critical", "display_name" => "", "extra" => true
}]
_state, _requests, post_schema_calls, _outputs, post_schema_statuses, =
  run_ntfy_subscription_fixture(
    users: [subscription_users.first],
    subscriptions: { "reader" => [] },
    post_read_subscriptions: { "reader" => invalid_post_read },
    expected_requests: 3
  )
check(failures,
      !post_schema_statuses.first.success? && post_schema_calls.map { |call| call[1] } == %w[GET POST GET],
      "ntfy accepted an invalid authoritative post-create subscription schema")

admin_user = Marshal.load(Marshal.dump(subscription_users.first))
admin_user["role"] = "admin"
_state, _requests, admin_calls, _outputs, admin_statuses, = run_ntfy_subscription_fixture(
  users: [admin_user], subscriptions: {}, expected_requests: 0
)
check(failures, !admin_statuses.first.success? && admin_calls.empty?,
      "ntfy accepted or authenticated a managed administrator")

duplicate_users = [subscription_users.first, Marshal.load(Marshal.dump(subscription_users.first))]
duplicate_users.last["username"] = " Reader "
_state, _requests, identity_calls, _outputs, identity_statuses, = run_ntfy_subscription_fixture(
  users: duplicate_users, subscriptions: {}, expected_requests: 0
)
check(failures, !identity_statuses.first.success? && identity_calls.empty?,
      "ntfy authenticated duplicate normalized managed usernames")

ntfy_main_tasks = YAML.safe_load(ntfy_main, aliases: false) || []
check(failures, ntfy_main_order_valid?(ntfy_main_tasks),
      "ntfy ownership preflight does not precede environment rendering and deployment")
check(failures, ntfy_cli_probe_valid?(ntfy_main_tasks),
      "ntfy authoritative CLI probe differs from the pinned v2.27 user-list contract")
check(failures, !ntfy_main.include?("change-pass") && !ntfy_main.include?("change-role") &&
                !ntfy_tasks.include?("change-pass"),
      "ntfy reconciliation invokes a forbidden credential or identity mutation command")
check(failures,
      ntfy_tasks.include?("ntfy_prior_provisioned_users") &&
        ntfy_tasks.include?("ntfy_existing_user_records") &&
        ntfy_tasks.include?("reviewed credential-migration procedure"),
      "ntfy does not enforce prior ownership, existing-user refusal, and hash preservation")
ntfy_auth_index = ntfy_managed_tasks.index { |task| task["name"] == "Basic-authenticate each managed ntfy user" }
ntfy_read_index = ntfy_managed_tasks.index { |task| task["name"] == "Verify managed ntfy declared read access" }
ntfy_write_index = ntfy_managed_tasks.index { |task| task["name"] == "Verify managed ntfy declared write access" }
ntfy_verify_tasks = [ntfy_auth_index, ntfy_read_index, ntfy_write_index].compact.map do |index|
  ntfy_managed_tasks.fetch(index)
end
check(failures,
      ntfy_verify_tasks.length == 3 && ntfy_auth_index < ntfy_read_index && ntfy_read_index < ntfy_write_index &&
        ntfy_verify_contract_valid?(ntfy_managed_tasks),
      "ntfy verification tasks do not pin Basic credentials, safety flags, and ordering")

if ntfy_verify_tasks.length == 3
  responder = proc do |request|
    if request["target"] == "/v1/account"
      200
    elsif request["method"] == "GET" && request["target"].start_with?("/nas-critical/")
      200
    else
      403
    end
  end
  with_http_probe(5, responder) do |port, requests|
    variables = {
      "ntfy_account_api" => "http://127.0.0.1:#{port}/v1/account",
      "ntfy_port" => port,
      "ntfy_managed_users_phase" => "verify",
      "vault_managed_ntfy_users" => [
        {
          "username" => "reader", "password" => "managed-plaintext", "role" => "user",
          "access" => [
            { "topic" => "nas-critical", "permission" => "read-only" },
            { "topic" => "private", "permission" => "deny" }
          ]
        }
      ]
    }
    run_playbook(task_playbook(ntfy_verify_tasks, variables)) do |_tmp, output, status|
      check(failures, status.success?, "ntfy verification fixture failed: #{output.lines.last&.strip}")
    end
    expected_basic = "Basic #{Base64.strict_encode64('reader:managed-plaintext')}"
    check(failures, requests.length == 5 && requests.all? do |request|
      request.dig("headers", "authorization") == expected_basic
    end, "ntfy verification did not use the managed user's Basic credentials on every request")
    check(failures,
          requests.map { |request| [request["method"], request["target"], request["body"]] } == [
            ["GET", "/v1/account", ""],
            ["GET", "/nas-critical/json?poll=1", ""],
            ["GET", "/private/json?poll=1", ""],
            ["POST", "/nas-critical", "Managed-user provisioning verification"],
            ["POST", "/private", "Managed-user provisioning verification"]
          ],
          "ntfy verification endpoints, methods, or bodies differ")
  end

  with_http_probe(3, proc { |_request| 200 }) do |port, requests|
    variables = {
      "ntfy_account_api" => "http://127.0.0.1:#{port}/v1/account",
      "ntfy_port" => port,
      "ntfy_managed_users_phase" => "verify",
      "vault_managed_ntfy_users" => [{
        "username" => "auditor", "password" => "admin-plaintext", "role" => "admin",
        "access" => [{ "topic" => "admin-topic", "permission" => "read-write" }]
      }]
    }
    run_playbook(task_playbook(ntfy_verify_tasks, variables)) do |_tmp, output, status|
      check(failures, status.success?,
            "ntfy administrator verification fixture failed: #{output.lines.last&.strip}")
    end
    expected_basic = "Basic #{Base64.strict_encode64('auditor:admin-plaintext')}"
    check(failures,
          requests.all? { |request| request.dig("headers", "authorization") == expected_basic } &&
            requests.map { |request| [request["method"], request["target"]] } == [
              ["GET", "/v1/account"],
              ["GET", "/admin-topic/json?poll=1"],
              ["POST", "/admin-topic"]
            ],
          "ntfy administrator verification did not prove effective read-write access")
  end
end

if !ntfy_tasks.empty?
  provisioned, output, status = run_ntfy_fixture
  check(failures, status.success?, "ntfy provisioning fixture failed: #{output.lines.last&.strip}")
  if provisioned
    check(failures, provisioned["users"].split(",") == [
            "admin:#{BCRYPT_A}:admin", "dozzle:#{BCRYPT_A}:user", "reader:#{BCRYPT_B}:user"
          ], "ntfy user provisioning entries differ")
    check(failures, provisioned["access"].split(",") == [
            "dozzle:nas-critical:write-only", "dozzle:nas-containers:write-only",
            "dozzle:nas-verification:write-only",
            "reader:nas-critical:read-only", "reader:private:deny"
          ], "ntfy access provisioning entries differ")
    check(failures, provisioned["tokens"].split(",") == ["dozzle:#{TOKEN_A}", "reader:#{TOKEN_B}"],
          "ntfy token ownership entries differ")
  end

  _provisioned, _output, status = run_ntfy_fixture("vault_ntfy_admin_user" => "reader")
  check(failures, !status.success?, "ntfy accepted an administrator/managed-user collision")
  _provisioned, _output, status = run_ntfy_fixture(
    "ntfy_publishers" => [
      { "name" => "dozzle", "password_hash" => BCRYPT_A, "token" => TOKEN_A,
        "topics" => ["nas-critical"] },
      { "name" => "beszel", "password_hash" => BCRYPT_A, "token" => TOKEN_A,
        "topics" => ["nas-critical"] }
    ]
  )
  check(failures, !status.success?, "ntfy accepted duplicate token ownership")

  mismatched_owned = {
    "admin" => { "username" => "admin", "password_hash" => BCRYPT_A, "role" => "admin" },
    "dozzle" => { "username" => "dozzle", "password_hash" => BCRYPT_A, "role" => "user" },
    "reader" => { "username" => "reader", "password_hash" => BCRYPT_A, "role" => "user" }
  }
  _provisioned, mismatch_output, status = run_ntfy_fixture(
    "ntfy_prior_provisioned_users" => mismatched_owned
  )
  check(failures, !status.success? && mismatch_output.include?("credential-migration"),
        "ntfy accepted a hash change for an owned declarative identity")

  unmanaged_records = {
    "*" => { "username" => "*", "role" => "anonymous", "provisioned" => false },
    "admin" => { "username" => "admin", "role" => "admin", "provisioned" => true },
    "dozzle" => { "username" => "dozzle", "role" => "user", "provisioned" => true },
    "reader" => { "username" => "reader", "role" => "user", "provisioned" => false }
  }
  prior_without_reader = mismatched_owned.reject { |identity, _entry| identity == "reader" }
  _provisioned, adoption_output, status = run_ntfy_fixture(
    "ntfy_prior_provisioned_users" => prior_without_reader,
    "ntfy_existing_user_records" => unmanaged_records
  )
  check(failures, !status.success? && adoption_output.include?("will not adopt"),
        "ntfy accepted automatic adoption of an unmanaged same-name identity")

  absent_records = unmanaged_records.reject { |identity, _entry| identity == "reader" }
  _provisioned, _absence_output, status = run_ntfy_fixture(
    "ntfy_prior_provisioned_users" => prior_without_reader,
    "ntfy_existing_user_records" => absent_records,
    "ntfy_authoritative_absence_established" => false
  )
  check(failures, !status.success?, "ntfy provisioned an identity without authoritative absence")

  orphaned_records = unmanaged_records.merge(
    "orphan" => { "username" => "orphan", "role" => "user", "provisioned" => true }
  )
  _provisioned, orphan_output, status = run_ntfy_fixture(
    "ntfy_existing_user_records" => orphaned_records
  )
  check(failures,
        !status.success? && orphan_output.include?("outside the prior declarative ownership record") &&
          !orphan_output.include?("orphan"),
        "ntfy accepted or disclosed an out-of-ownership provisioned identity")

  admin_user = {
    "username" => "auditor", "password" => "admin-plaintext",
    "password_hash" => BCRYPT_B, "role" => "admin",
    "access" => [{ "topic" => "admin-topic", "permission" => "read-write" }],
    "tokens" => [TOKEN_B]
  }
  admin_prior = mismatched_owned.reject { |identity, _entry| identity == "reader" }.merge(
    "auditor" => { "username" => "auditor", "password_hash" => BCRYPT_B, "role" => "admin" }
  )
  admin_records = absent_records.merge(
    "auditor" => { "username" => "auditor", "role" => "admin", "provisioned" => true }
  )
  _provisioned, _admin_output, status = run_ntfy_fixture(
    "vault_managed_ntfy_users" => [admin_user],
    "ntfy_prior_provisioned_users" => admin_prior,
    "ntfy_existing_user_records" => admin_records
  )
  check(failures, !status.success?, "ntfy accepted a managed administrator account")

  %w[read-only write-only deny].each do |permission|
    restricted_admin = Marshal.load(Marshal.dump(admin_user))
    restricted_admin["access"][0]["permission"] = permission
    _provisioned, _restricted_output, restricted_status = run_ntfy_fixture(
      "vault_managed_ntfy_users" => [restricted_admin],
      "ntfy_prior_provisioned_users" => admin_prior,
      "ntfy_existing_user_records" => admin_records
    )
    check(failures, !restricted_status.success?,
          "ntfy accepted administrator #{permission} semantics it cannot enforce")
  end

  hostile_usernames = ["bad,user", "bad:user", "bad user", "bad/user", "bad\nuser"]
  hostile_usernames.each do |username|
    hostile_user = Marshal.load(Marshal.dump(admin_user))
    hostile_user["username"] = username
    _provisioned, hostile_output, hostile_status = run_ntfy_fixture(
      "vault_managed_ntfy_users" => [hostile_user],
      "ntfy_prior_provisioned_users" => prior_without_reader,
      "ntfy_existing_user_records" => absent_records
    )
    check(failures, !hostile_status.success? && !hostile_output.include?(username),
          "ntfy accepted or disclosed a delimiter-unsafe managed username")
  end

  ["bad,topic", "bad:topic", "bad topic", "bad/topic", "bad*topic", "bad\ntopic"].each do |topic|
    hostile_topic_user = Marshal.load(Marshal.dump(admin_user))
    hostile_topic_user["access"][0]["topic"] = topic
    _provisioned, hostile_output, hostile_status = run_ntfy_fixture(
      "vault_managed_ntfy_users" => [hostile_topic_user],
      "ntfy_prior_provisioned_users" => admin_prior,
      "ntfy_existing_user_records" => admin_records
    )
    check(failures, !hostile_status.success? && !hostile_output.include?(topic),
          "ntfy accepted or disclosed a non-literal managed topic")
  end

  _provisioned, publisher_topic_output, publisher_topic_status = run_ntfy_fixture(
    "ntfy_topic" => "bad/topic"
  )
  check(failures,
        !publisher_topic_status.success? && !publisher_topic_output.include?("bad/topic"),
        "ntfy accepted or disclosed a non-literal publisher topic")
end

validate_policy = read(VALIDATE_POLICY)
check(failures, validate_policy.lines.include?("ruby tests/config_managed_users_test.rb --self-test\n"),
      "policy validation does not run the config managed-user self-test")
check(failures, validate_policy.include?("tests/managed_user_state_filter_test.py"),
      "policy validation does not run the managed-user state filter behavior test")

unless [[], ["--self-test"]].include?(ARGV)
  abort "usage: config_managed_users_test.rb [--self-test]"
end

if ARGV == ["--self-test"]
  sources = {
    "dozzle_tasks" => dozzle_tasks,
    "dozzle_main" => dozzle_main,
    "dozzle_template" => dozzle_template,
    "ntfy_tasks" => ntfy_tasks,
    "ntfy_subscription_tasks" => ntfy_subscription_tasks,
    "ntfy_main" => ntfy_main,
    "ntfy_defaults" => ntfy_defaults,
    "ntfy_argument_specs" => ntfy_argument_specs,
    "state_filter" => state_filter,
    "safe_slurp" => safe_slurp,
    "validate_policy" => validate_policy
  }
  source_fragment_failures(sources).each do |label|
    failures << "self-test baseline rejected #{label}"
  end
  SOURCE_REQUIREMENTS.each do |label, (source_name, fragment)|
    mutated_source = sources.fetch(source_name).gsub(fragment, "removed-by-self-test")
    mutated = sources.merge(source_name => mutated_source)
    check(failures, source_fragment_failures(mutated).include?(label),
          "self-test did not reject the #{label} mutation")
  end

  reordered_main = YAML.safe_load(ntfy_main, aliases: false)
  provision_task = reordered_main.delete_at(
    reordered_main.index { |task| task["name"] == "Resolve declarative ntfy managed-user provisioning" }
  )
  preflight_index = reordered_main.index do |task|
    task["name"] == "Inspect existing ntfy declarative ownership and users"
  end
  reordered_main.insert(preflight_index, provision_task)
  check(failures, !ntfy_main_order_valid?(reordered_main),
        "behavioral self-test did not reject ntfy preflight reordering")

  unsupported_interaction = Marshal.load(Marshal.dump(ntfy_main_tasks))
  unsupported_interaction.find do |task|
    task["name"] == "List authoritative existing ntfy users"
  end.fetch("community.docker.docker_compose_v2_run")["interactive"] = false
  check(failures, !ntfy_cli_probe_valid?(unsupported_interaction),
        "behavioral self-test did not reject the unsupported Compose interaction flag")

  {
    "wrong auth status" => proc do |tasks|
      tasks.find { |task| task["name"] == "Basic-authenticate each managed ntfy user" }
        .fetch("ansible.builtin.uri")["status_code"] = [201]
    end,
    "missing auth redaction" => proc do |tasks|
      tasks.find { |task| task["name"] == "Basic-authenticate each managed ntfy user" }["no_log"] = false
    end,
    "auth check-mode forcing" => proc do |tasks|
      tasks.find { |task| task["name"] == "Basic-authenticate each managed ntfy user" }["check_mode"] = false
    end,
    "wrong write method" => proc do |tasks|
      tasks.find { |task| task["name"] == "Verify managed ntfy declared write access" }
        .fetch("ansible.builtin.uri")["method"] = "PUT"
    end
  }.each do |label, mutate|
    mutant = Marshal.load(Marshal.dump(ntfy_managed_tasks))
    mutate.call(mutant)
    check(failures, !ntfy_verify_contract_valid?(mutant),
          "behavioral self-test did not reject #{label}")
  end

  collision_vars = {
    "vault_ntfy_admin_user" => "reader",
    "vault_ntfy_admin_password_hash" => BCRYPT_B,
    "ntfy_prior_provisioned_users" => {
      "admin" => { "username" => "admin", "password_hash" => BCRYPT_A, "role" => "admin" },
      "dozzle" => { "username" => "dozzle", "password_hash" => BCRYPT_A, "role" => "user" },
      "reader" => { "username" => "reader", "password_hash" => BCRYPT_B, "role" => "admin" }
    }
  }
  mismatched_vars = {
    "ntfy_prior_provisioned_users" => {
      "admin" => { "username" => "admin", "password_hash" => BCRYPT_A, "role" => "admin" },
      "dozzle" => { "username" => "dozzle", "password_hash" => BCRYPT_A, "role" => "user" },
      "reader" => { "username" => "reader", "password_hash" => BCRYPT_A, "role" => "user" }
    }
  }
  prior_without_reader = mismatched_vars.fetch("ntfy_prior_provisioned_users").reject do |identity, _entry|
    identity == "reader"
  end
  unmanaged_records = {
    "*" => { "username" => "*", "role" => "anonymous", "provisioned" => false },
    "admin" => { "username" => "admin", "role" => "admin", "provisioned" => true },
    "dozzle" => { "username" => "dozzle", "role" => "user", "provisioned" => true },
    "reader" => { "username" => "reader", "role" => "user", "provisioned" => false }
  }
  behavior_mutations = {
    "identity collision guard" => ["Refuse duplicate ntfy identities", collision_vars],
    "owned hash guard" => ["Refuse password hash replacement for owned ntfy identities", mismatched_vars],
    "adoption guard" => ["Refuse automatic adoption of unmanaged ntfy identities", {
      "ntfy_prior_provisioned_users" => prior_without_reader,
      "ntfy_existing_user_records" => unmanaged_records
    }],
    "orphan provisioned guard" => ["Refuse out-of-ownership provisioned ntfy identities", {
      "ntfy_existing_user_records" => unmanaged_records.merge(
        "orphan" => { "username" => "orphan", "role" => "user", "provisioned" => true }
      )
    }],
    "delimiter guard" => ["Validate ntfy provisioning encodings", {
      "vault_managed_ntfy_users" => [{
        "username" => "bad,user", "password" => "plain", "password_hash" => BCRYPT_B,
        "role" => "user", "access" => [], "tokens" => []
      }],
      "ntfy_prior_provisioned_users" => prior_without_reader,
      "ntfy_existing_user_records" => unmanaged_records.reject { |identity, _entry| identity == "reader" }
    }],
    "managed administrator guard" => ["Require managed ntfy accounts to remain nonadministrative", {
      "vault_managed_ntfy_users" => [{
        "username" => "auditor", "password" => "plain", "password_hash" => BCRYPT_B,
        "role" => "admin", "access" => [{ "topic" => "admin-topic", "permission" => "deny" }],
        "tokens" => []
      }],
      "ntfy_prior_provisioned_users" => prior_without_reader,
      "ntfy_existing_user_records" => unmanaged_records.reject { |identity, _entry| identity == "reader" }
    }]
  }
  behavior_mutations.each do |label, (task_name, variables)|
    with_ntfy_task_removed(task_name) do |mutant_path, found|
      unless found
        failures << "behavioral self-test baseline is missing #{task_name}"
        next
      end
      _rendered, _output, mutant_status = run_ntfy_fixture(variables, mutant_path)
      check(failures, mutant_status.success?,
            "behavioral self-test #{label} mutation did not escape its negative fixture")
    end
  end

  {
    "duplicate YAML parser" => ["if duplicate:", "if False:"],
    "YAML alias parser" => [
      "(yaml.tokens.AnchorToken, yaml.tokens.AliasToken)", "()"
    ]
  }.each do |label, (before, after)|
    Dir.mktmpdir("nas-platform-filter-mutant-") do |directory|
      mutant = File.join(directory, "managed_user_state.py")
      mutated_source = state_filter.sub(before, after)
      File.write(mutant, mutated_source, mode: "w", perm: 0o600)
      _stdout, _stderr, status = Open3.capture3(
        { "MANAGED_USER_STATE_PLUGIN" => mutant, "PYTHONDONTWRITEBYTECODE" => "1" },
        ansible_python,
        File.join(ROOT, "tests", "managed_user_state_filter_test.py"), chdir: ROOT
      )
      check(failures, mutated_source != state_filter && !status.success?,
            "behavioral self-test did not reject #{label} mutation")
    end
  end

  {
    "no-follow reader" => ["os.O_NOFOLLOW", "0"],
    "nonblocking reader" => ["os.O_NONBLOCK", "0"]
  }.each do |label, (before, after)|
    Dir.mktmpdir("nas-platform-safe-slurp-mutant-") do |directory|
      mutant = File.join(directory, "atomic_safe_slurp.py")
      mutated_source = safe_slurp.sub(before, after)
      File.write(mutant, mutated_source, mode: "w", perm: 0o600)
      _stdout, _stderr, status = Open3.capture3(
        {
          "ATOMIC_SAFE_SLURP_MODULE" => mutant,
          "PYTHONDONTWRITEBYTECODE" => "1"
        },
        ansible_python, File.join(ROOT, "tests", "safe_slurp_test.py"), chdir: ROOT
      )
      check(failures, mutated_source != safe_slurp && !status.success?,
            "behavioral self-test did not reject the #{label} mutation")
    end
  end
end

report(failures, "Config managed users: Dozzle preservation and ntfy provisioning contracts hold",
       "config managed-user violation(s)")
