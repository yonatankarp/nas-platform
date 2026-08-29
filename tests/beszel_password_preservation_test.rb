#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "socket"
require "timeout"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)
DEFAULT_TASKS_PATH = File.join(ROOT, "roles", "beszel", "tasks", "main.yml")
TASKS_PATH = ENV.fetch(
  "BESZEL_PASSWORD_TASKS_PATH",
  DEFAULT_TASKS_PATH
)

class FixtureTimeout < StandardError; end
class FixtureServerError < StandardError; end

def check(failures, condition, message)
  failures << message unless condition
end

def normalized(value)
  value.to_s.split.join(" ")
end

def terminate_process_group(pid, signal)
  Process.kill(signal, -pid)
rescue Errno::ESRCH
  nil
end

def capture3_with_timeout(environment, *command, chdir:, timeout_seconds:)
  Open3.popen3(environment, *command, chdir: chdir, pgroup: true) do |stdin, stdout, stderr, wait_thread|
    stdin.close
    stdout_reader = Thread.new { stdout.read }
    stderr_reader = Thread.new { stderr.read }
    begin
      status = Timeout.timeout(timeout_seconds) { wait_thread.value }
    rescue Timeout::Error
      terminate_process_group(wait_thread.pid, "TERM")
      unless wait_thread.join(1)
        terminate_process_group(wait_thread.pid, "KILL")
        wait_thread.join
      end
      stdout_reader.join
      stderr_reader.join
      unit = timeout_seconds == 1 ? "second" : "seconds"
      raise FixtureTimeout, "Ansible fixture timed out after #{timeout_seconds} #{unit}"
    end
    [stdout_reader.value, stderr_reader.value, status]
  end
end

def with_superuser_auth_service(state_path, responder: :normal)
  server = TCPServer.new("127.0.0.1", 0)
  shutdown_reader, shutdown_writer = IO.pipe
  requests = []
  thread_error = nil
  thread = Thread.new do
    Thread.current.report_on_exception = false
    loop do
      ready = IO.select([server, shutdown_reader], nil, nil, 0.05)
      next unless ready
      break if ready.first.include?(shutdown_reader)

      client = server.accept
      begin
        if responder == :blocked
          IO.select([shutdown_reader])
          break
        end
        raise "fixture responder failure" if responder == :broken

        client.gets
        headers = {}
        while (line = client.gets)
          line = line.chomp
          break if line == "\r" || line.empty?

          key, value = line.split(":", 2)
          headers[key.downcase] = value.to_s.strip
        end
        body = JSON.parse(client.read(headers.fetch("content-length", "0").to_i))
        state = JSON.parse(File.read(state_path))
        authenticated = state["identity"] == body["identity"] && state["password"] == body["password"]
        requests << body
        response = authenticated ? { "token" => "fixture-token" } : {}
        payload = JSON.generate(response)
        status = authenticated ? "200 OK" : "400 Bad Request"
        client.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\n" \
                     "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      ensure
        client.close unless client.closed?
      end
    end
  rescue IOError, Errno::EBADF
    nil
  rescue StandardError => error
    thread_error = error
  end
  yield server.addr.fetch(1), requests
ensure
  begin
    shutdown_writer&.write("x")
  rescue IOError, Errno::EPIPE
    nil
  end
  shutdown_writer&.close
  server&.close
  thread&.join(1)
  thread&.kill if thread&.alive?
  thread&.join
  shutdown_reader&.close
  raise FixtureServerError, "superuser auth fixture responder failed" if thread_error
end

def run_superuser_lifecycle(tasks, state_path, creator_path, port, *arguments, timeout_seconds: 20)
  fixture = Marshal.load(Marshal.dump(tasks))
  fixture.each do |task|
    uri = task["ansible.builtin.uri"]
    uri["timeout"] = 2 if uri.is_a?(Hash)
  end
  create = fixture.find { |task| task["name"] == "Create the superuser without updating an existing identity" }
  create.delete("community.docker.docker_compose_v2_exec")
  create["ansible.builtin.command"] = {
    "argv" => [RbConfig.ruby, creator_path, state_path,
               "{{ vault_beszel_superuser_email }}", "{{ vault_beszel_superuser_password }}"]
  }
  playbook = [{
    "hosts" => "localhost", "gather_facts" => false,
    "vars" => {
      "beszel_api" => "http://127.0.0.1:#{port}",
      "beszel_no_log" => true,
      "vault_beszel_superuser_email" => "admin@example.invalid",
      "vault_beszel_superuser_password" => "vault-superuser-secret"
    },
    "tasks" => fixture
  }]
  Dir.mktmpdir("beszel-superuser-playbook-") do |directory|
    path = File.join(directory, "playbook.yml")
    File.write(path, YAML.dump(playbook), mode: "w", perm: 0o600)
    capture3_with_timeout(
      { "ANSIBLE_NOCOLOR" => "1" }, "ansible-playbook", "-i", "localhost,", "-c", "local",
      path, *arguments, chdir: ROOT, timeout_seconds: timeout_seconds
    )
  end
end

def changed_count(output)
  output.scan(/changed=(\d+)/).flatten.last.to_i
end

tasks = YAML.safe_load_file(TASKS_PATH, aliases: false)
failures = []

exec_tasks = tasks.filter_map do |task|
  command = task["community.docker.docker_compose_v2_exec"]
  [task, command] if command.is_a?(Hash)
end
forbidden_superuser_commands = exec_tasks.filter_map do |task, command|
  argv = Array(command["argv"])
  task["name"] if argv.include?("superuser") && (argv & %w[upsert update]).any?
end
check(failures, forbidden_superuser_commands.empty?,
      "Beszel must never invoke superuser upsert/update: #{forbidden_superuser_commands.join(', ')}")

superuser_create = tasks.find { |task| task["name"] == "Create the superuser without updating an existing identity" }
create_command = superuser_create&.fetch("community.docker.docker_compose_v2_exec", nil)
create_argv = create_command.is_a?(Hash) ? Array(create_command["argv"]) : []
check(failures,
      create_argv == ["/beszel", "superuser", "create",
                      "{{ vault_beszel_superuser_email }}",
                      "{{ vault_beszel_superuser_password }}"],
      "Beszel superuser provisioning must use the exact atomic create-only command")
check(failures, superuser_create&.fetch("register", nil) == "beszel_superuser_create",
      "Beszel must capture the atomic superuser create result")
check(failures, superuser_create&.fetch("failed_when", nil) == false,
      "Beszel must defer create-result classification until exact authentication")
check(failures, superuser_create&.fetch("changed_when", nil) == false,
      "Beszel atomic command must defer truthful change classification until post-authentication")
check(failures, Array(superuser_create&.fetch("when", nil)) == [
        "not ansible_check_mode", "beszel_superuser_pre_auth.status | int != 200"
      ], "Beszel atomic create must run only when exact credentials do not already authenticate")
check(failures,
      superuser_create&.fetch("no_log", nil) == "{{ beszel_no_log | default(true) }}",
      "Beszel atomic superuser creation must use the repository redaction contract")
check(failures, superuser_create && !superuser_create.key?("tags"),
      "Beszel atomic superuser creation must not run during verify-only execution")
check(failures, superuser_create && !superuser_create.key?("check_mode"),
      "Beszel atomic superuser creation must obey Ansible check mode")

superuser_pre_auth = tasks.find { |task| task["name"] == "Check for an existing Beszel superuser with vault credentials" }
superuser_auth = tasks.find { |task| task["name"] == "Authenticate as the superuser" }
expected_superuser_auth = {
  "url" => "{{ beszel_api }}/api/collections/_superusers/auth-with-password",
  "method" => "POST",
  "body_format" => "json",
  "body" => {
    "identity" => "{{ vault_beszel_superuser_email }}",
    "password" => "{{ vault_beszel_superuser_password }}"
  },
  "status_code" => [200, 400, 403]
}
check(failures, superuser_auth&.fetch("ansible.builtin.uri", nil) == expected_superuser_auth,
      "Beszel must use the exact captured superuser authentication request")
check(failures, superuser_auth&.fetch("register", nil) == "beszel_auth" &&
                superuser_auth&.fetch("changed_when", nil) == false &&
                superuser_auth&.fetch("check_mode", nil) == false &&
                superuser_auth&.fetch("no_log", nil) == "{{ beszel_no_log | default(true) }}",
      "Beszel superuser authentication must preserve its exact result and redaction contract")
check(failures,
      superuser_pre_auth&.fetch("ansible.builtin.uri", nil) == expected_superuser_auth &&
        superuser_pre_auth&.fetch("register", nil) == "beszel_superuser_pre_auth" &&
        superuser_pre_auth&.fetch("changed_when", nil) == false &&
        superuser_pre_auth&.fetch("check_mode", nil) == false &&
        superuser_pre_auth&.fetch("no_log", nil) == "{{ beszel_no_log | default(true) }}",
      "Beszel must capture exact pre-create authentication without exposing credentials")

superuser_assert = tasks.find { |task| task["name"] == "Require created or preserved Beszel superuser credentials" }
superuser_conditions = Array(superuser_assert&.dig("ansible.builtin.assert", "that"))
check(failures,
      superuser_conditions == ["ansible_check_mode or beszel_auth.status | int == 200"],
      "superuser preservation must require exact post-create authentication outside check mode")
check(failures, !superuser_conditions.join(" ").match?(/std(out|err)/),
      "superuser create-result classification must not parse brittle command output")
# The assertion itself renders nothing but its own condition source and a static
# fail_msg, so redacting it would only hide which condition failed. The reads it
# gates carry the redaction; see the no_log contracts checked above.
check(failures, superuser_assert && !superuser_assert.key?("no_log"),
      "the superuser preservation assertion must stay readable on failure")
check(failures, Array(superuser_assert&.fetch("tags", nil)).include?("platform_verify_beszel"),
      "Beszel verify-only must enforce the superuser credential assertion")

pre_auth_index = superuser_pre_auth && tasks.index(superuser_pre_auth)
create_index = superuser_create && tasks.index(superuser_create)
auth_index = superuser_auth && tasks.index(superuser_auth)
assert_index = superuser_assert && tasks.index(superuser_assert)
check(failures,
      pre_auth_index && create_index && auth_index && assert_index &&
        pre_auth_index < create_index && create_index < auth_index && auth_index < assert_index,
      "Beszel must pre-authenticate, atomically create if needed, and post-authenticate in order")

superuser_created = tasks.find { |task| task["name"] == "Report newly created Beszel superuser" }
check(failures,
      superuser_created&.fetch("changed_when", nil) == true &&
        Array(superuser_created&.fetch("when", nil)) == [
          "not ansible_check_mode", "beszel_superuser_pre_auth.status | int != 200",
          "beszel_superuser_create.stdout | default('') == " \
          "'Successfully created new superuser \"' ~ vault_beszel_superuser_email ~ '\"!'",
          "beszel_auth.status | int == 200"
        ],
      "Beszel must report changed only for the exact pinned create-success signal and post-authentication")
check(failures, superuser_created&.fetch("no_log", nil) == true,
      "Beszel create-success classification must redact the captured CLI result")
superuser_planned = tasks.find { |task| task["name"] == "Report planned Beszel superuser creation" }
check(failures,
      superuser_planned&.fetch("changed_when", nil) == true &&
        Array(superuser_planned&.fetch("when", nil)) == [
          "ansible_check_mode", "beszel_superuser_pre_auth.status | int != 200"
        ],
      "Beszel check mode must plan absent superuser creation without invoking the CLI")

lifecycle_names = [
  "Check for an existing Beszel superuser with vault credentials",
  "Create the superuser without updating an existing identity",
  "Authenticate as the superuser",
  "Require created or preserved Beszel superuser credentials",
  "Report newly created Beszel superuser",
  "Report planned Beszel superuser creation"
]
lifecycle_tasks = lifecycle_names.filter_map do |name|
  tasks.find { |task| task["name"] == name }
end
check(failures, lifecycle_tasks.length == lifecycle_names.length,
      "Beszel stateful superuser lifecycle task selection is incomplete")

if lifecycle_tasks.length == lifecycle_names.length && TASKS_PATH == DEFAULT_TASKS_PATH
  Dir.mktmpdir("beszel-superuser-state-") do |directory|
    state_path = File.join(directory, "state.json")
    creator_path = File.join(directory, "create.rb")
    File.write(creator_path, <<~RUBY, mode: "w", perm: 0o700)
      #!/usr/bin/env ruby
      require "json"
      state_path, identity, password = ARGV
      state = JSON.parse(File.read(state_path))
      if state["identity"].nil?
        concurrent = state.delete("concurrent_create")
        state = { "identity" => identity, "password" => password }
        File.write(state_path, JSON.generate(state), mode: "w", perm: 0o600)
        if concurrent
          puts "Error: failed to create new superuser account: email: Value must be unique."
        else
          puts %(Successfully created new superuser "\#{identity}"!)
        end
      else
        puts "Error: failed to create new superuser account: email: Value must be unique."
      end
    RUBY
    desired_state = {
      "identity" => "admin@example.invalid", "password" => "vault-superuser-secret"
    }
    File.write(state_path, JSON.generate({ "identity" => nil, "password" => nil }), mode: "w", perm: 0o600)
    with_superuser_auth_service(state_path) do |port, requests|
      first_stdout, first_stderr, first_status = run_superuser_lifecycle(
        lifecycle_tasks, state_path, creator_path, port
      )
      check(failures, first_status.success? && changed_count(first_stdout) == 1,
            "Beszel first superuser creation was not the sole truthful change")
      check(failures, JSON.parse(File.read(state_path)) == desired_state,
            "Beszel first superuser creation did not persist exact credentials")

      second_stdout, second_stderr, second_status = run_superuser_lifecycle(
        lifecycle_tasks, state_path, creator_path, port
      )
      check(failures, second_status.success? && changed_count(second_stdout) == 0,
            "Beszel existing exact superuser credentials were not idempotent")
      check(failures, JSON.parse(File.read(state_path)) == desired_state,
            "Beszel idempotent superuser run mutated persisted credentials")

      File.write(
        state_path,
        JSON.generate({ "identity" => nil, "password" => nil, "concurrent_create" => true }),
        mode: "w", perm: 0o600
      )
      concurrent_stdout, concurrent_stderr, concurrent_status = run_superuser_lifecycle(
        lifecycle_tasks, state_path, creator_path, port
      )
      check(failures,
            concurrent_status.success? && changed_count(concurrent_stdout) == 0 &&
              JSON.parse(File.read(state_path)) == desired_state,
            "Beszel concurrent duplicate creation was incorrectly attributed to this controller")

      wrong_state = desired_state.merge("password" => "deployed-other-secret")
      File.write(state_path, JSON.generate(wrong_state), mode: "w", perm: 0o600)
      wrong_stdout, wrong_stderr, wrong_status = run_superuser_lifecycle(
        lifecycle_tasks, state_path, creator_path, port
      )
      wrong_output = wrong_stdout + wrong_stderr
      check(failures, !wrong_status.success? && JSON.parse(File.read(state_path)) == wrong_state,
            "Beszel wrong existing credentials did not fail without mutation")
      check(failures,
            !wrong_output.include?(desired_state.fetch("password")) &&
              !wrong_output.include?(wrong_state.fetch("password")),
            "Beszel wrong-credential diagnostics leaked a password")
      wrong_verify_stdout, wrong_verify_stderr, wrong_verify_status = run_superuser_lifecycle(
        lifecycle_tasks, state_path, creator_path, port, "--tags", "platform_verify_beszel"
      )
      check(failures,
            !wrong_verify_status.success? && JSON.parse(File.read(state_path)) == wrong_state &&
              !(wrong_verify_stdout + wrong_verify_stderr).include?(wrong_state.fetch("password")),
            "Beszel verify-only accepted or exposed wrong superuser credentials")

      File.write(state_path, JSON.generate({ "identity" => nil, "password" => nil }), mode: "w", perm: 0o600)
      check_stdout, check_stderr, check_status = run_superuser_lifecycle(
        lifecycle_tasks, state_path, creator_path, port, "--check"
      )
      check(failures,
            check_status.success? && changed_count(check_stdout) == 1 &&
              JSON.parse(File.read(state_path))["identity"].nil?,
            "Beszel check mode did not plan creation without mutation")

      File.write(state_path, JSON.generate(desired_state), mode: "w", perm: 0o600)
      verify_stdout, verify_stderr, verify_status = run_superuser_lifecycle(
        lifecycle_tasks, state_path, creator_path, port, "--tags", "platform_verify_beszel"
      )
      check(failures,
            verify_status.success? && changed_count(verify_stdout) == 0 &&
              JSON.parse(File.read(state_path)) == desired_state,
            "Beszel verify-only superuser authentication was not non-mutating")
      check(failures, requests.length == 12,
            "Beszel superuser lifecycle did not execute the exact authentication sequence")
      [first_stderr, second_stderr, concurrent_stderr, check_stderr, verify_stderr].each do |output|
        check(failures, !output.include?(desired_state.fetch("password")),
              "Beszel lifecycle diagnostics leaked the vault password")
      end
    end

    begin
      with_superuser_auth_service(state_path, responder: :blocked) do |port, _requests|
        run_superuser_lifecycle(
          lifecycle_tasks, state_path, creator_path, port, timeout_seconds: 1
        )
      end
      failures << "blocked Beszel auth fixture did not time out diagnostically"
    rescue FixtureTimeout => error
      check(failures, error.message == "Ansible fixture timed out after 1 second",
            "blocked Beszel auth fixture timeout diagnostic differs")
    end

    begin
      with_superuser_auth_service(state_path, responder: :broken) do |port, _requests|
        run_superuser_lifecycle(lifecycle_tasks, state_path, creator_path, port)
      end
      failures << "broken Beszel auth fixture error was not propagated"
    rescue FixtureServerError => error
      check(failures, error.message == "superuser auth fixture responder failed",
            "broken Beszel auth fixture exposed an unsafe diagnostic")
    end
  end
end

app_auth = tasks.find do |task|
  task["name"] == "Check whether the managed application user accepts vault credentials"
end
expected_app_auth = {
  "url" => "{{ beszel_api }}/api/collections/users/auth-with-password",
  "method" => "POST",
  "body_format" => "json",
  "body" => {
    "identity" => "{{ vault_beszel_app_user_email }}",
    "password" => "{{ vault_beszel_app_user_password }}"
  },
  "status_code" => [200, 400, 403]
}
check(failures, app_auth&.fetch("ansible.builtin.uri", nil) == expected_app_auth,
      "Beszel must use the exact captured application-user authentication request")
check(failures, app_auth&.fetch("register", nil) == "beszel_app_user_auth" &&
                app_auth&.fetch("changed_when", nil) == false &&
                app_auth&.fetch("check_mode", nil) == false &&
                app_auth&.fetch("no_log", nil) == "{{ beszel_no_log | default(true) }}" &&
                app_auth&.fetch("when", nil) == "beszel_user_id | length > 0",
      "Beszel application-user authentication must preserve its exact result, redaction, and presence contract")

app_create = tasks.find { |task| task["name"] == "Create the application user" }
app_create_uri = app_create&.fetch("ansible.builtin.uri", nil)
app_create_body = app_create&.dig("ansible.builtin.uri", "body")
check(failures,
      app_create_uri.is_a?(Hash) &&
        app_create_uri["url"] == "{{ beszel_api }}/api/collections/users/records" &&
        app_create_uri["method"] == "POST" && app_create_uri["body_format"] == "json" &&
        app_create_uri["status_code"] == [200],
      "Beszel must use the exact fail-closed application-user creation request")
check(failures, app_create_body.is_a?(Hash) &&
                app_create_body["email"] == "{{ vault_beszel_app_user_email }}" &&
                app_create_body["password"] == "{{ vault_beszel_app_user_password }}" &&
                app_create_body["passwordConfirm"] == "{{ vault_beszel_app_user_password }}",
      "Beszel must use the exact vault identity and credentials for absent application-user creation")
check(failures, app_create&.fetch("when", nil) == "beszel_matching_users | length == 0",
      "Beszel must create the primary application user only when it is absent")

app_assert = tasks.find do |task|
  task["name"] == "Require preserved Beszel application-user credentials"
end
expected_guidance = <<~TEXT
  Existing Beszel application user does not accept its preserved vault
  password. Run the reviewed credential-migration procedure; Ansible will
  not reset it automatically.
TEXT
check(failures,
      app_assert&.dig("ansible.builtin.assert", "that") ==
        ["beszel_app_user_auth.status | int == 200"],
      "existing Beszel application users must assert successful authentication")
check(failures,
      normalized(app_assert&.dig("ansible.builtin.assert", "fail_msg")) == normalized(expected_guidance),
      "failed application-user authentication must give exact credential-migration guidance")
check(failures, app_assert&.fetch("when", nil) == "beszel_user_id | length > 0",
      "the application-user preservation assertion must apply only to an existing identity")
check(failures, app_assert && !app_assert.key?("no_log"),
      "the application-user preservation assertion must stay readable on failure")

existing_user_patches = tasks.select do |task|
  uri = task["ansible.builtin.uri"]
  uri.is_a?(Hash) && uri["method"] == "PATCH" &&
    uri["url"].to_s.include?("/api/collections/users/records/")
end
check(failures, !existing_user_patches.empty?,
      "Beszel must retain non-secret application-user reconciliation")
existing_user_patches.each do |task|
  body = task.dig("ansible.builtin.uri", "body")
  check(failures, body.is_a?(Hash), "#{task['name']}: PATCH body must be a mapping")
  next unless body.is_a?(Hash)

  forbidden = body.keys & %w[password passwordConfirm]
  check(failures, forbidden.empty?,
        "#{task['name']}: existing-user PATCH must not contain #{forbidden.join(', ')}")
  check(failures, body.keys.sort == %w[role verified],
        "#{task['name']}: existing-user PATCH must contain only role and verified")
end

app_assert_index = app_assert && tasks.index(app_assert)
app_auth_index = app_auth && tasks.index(app_auth)
patch_indexes = existing_user_patches.map { |task| tasks.index(task) }
check(failures,
      app_auth_index && app_assert_index && app_auth_index < app_assert_index &&
        patch_indexes.all? { |index| app_assert_index < index },
      "Beszel must authenticate and assert preserved credentials before any existing-user PATCH")

if ARGV == ["--self-test"] && failures.empty?
  mutations = {
    "missing post-create superuser authentication requirement" => [
      "superuser preservation must require exact post-create authentication outside check mode",
      lambda do |fixture|
        assertion = fixture.find do |task|
          task["name"] == "Require created or preserved Beszel superuser credentials"
        end
        assertion.fetch("ansible.builtin.assert")["that"] = ["ansible_check_mode"]
      end
    ],
    "verify-only superuser assertion omission" => [
      "Beszel verify-only must enforce the superuser credential assertion",
      lambda do |fixture|
        assertion = fixture.find do |task|
          task["name"] == "Require created or preserved Beszel superuser credentials"
        end
        assertion.delete("tags")
      end
    ],
    "wrong pre-create superuser authentication password" => [
      "Beszel must capture exact pre-create authentication without exposing credentials",
      lambda do |fixture|
        auth = fixture.find do |task|
          task["name"] == "Check for an existing Beszel superuser with vault credentials"
        end
        auth.dig("ansible.builtin.uri", "body")["password"] = "wrong"
      end
    ],
    "wrong superuser authentication endpoint" => [
      "Beszel must use the exact captured superuser authentication request",
      lambda do |fixture|
        auth = fixture.find { |task| task["name"] == "Authenticate as the superuser" }
        auth.fetch("ansible.builtin.uri")["url"] = "{{ beszel_api }}/api/collections/users/auth-with-password"
      end
    ],
    "wrong application-user authentication password" => [
      "Beszel must use the exact captured application-user authentication request",
      lambda do |fixture|
        auth = fixture.find do |task|
          task["name"] == "Check whether the managed application user accepts vault credentials"
        end
        auth.dig("ansible.builtin.uri", "body")["password"] = "wrong"
      end
    ],
    "wrong absent application-user confirmation" => [
      "Beszel must use the exact vault identity and credentials for absent application-user creation",
      lambda do |fixture|
        create = fixture.find { |task| task["name"] == "Create the application user" }
        create.dig("ansible.builtin.uri", "body")["passwordConfirm"] = "wrong"
      end
    ],
    "unconditional atomic superuser creation" => [
      "Beszel atomic create must run only when exact credentials do not already authenticate",
      lambda do |fixture|
        create = fixture.find do |task|
          task["name"] == "Create the superuser without updating an existing identity"
        end
        create.delete("when")
      end
    ],
    "rc-based superuser change classification" => [
      "Beszel atomic command must defer truthful change classification until post-authentication",
      lambda do |fixture|
        create = fixture.find do |task|
          task["name"] == "Create the superuser without updating an existing identity"
        end
        create["changed_when"] = "beszel_superuser_create.rc == 0"
      end
    ],
    "missing post-authenticated change classification" => [
      "Beszel must report changed only for the exact pinned create-success signal and post-authentication",
      lambda do |fixture|
        report = fixture.find { |task| task["name"] == "Report newly created Beszel superuser" }
        report["when"].delete("beszel_auth.status | int == 200")
      end
    ],
    "drifted create-success signal" => [
      "Beszel must report changed only for the exact pinned create-success signal and post-authentication",
      lambda do |fixture|
        report = fixture.find { |task| task["name"] == "Report newly created Beszel superuser" }
        report["when"][2] = "beszel_superuser_create.stdout | default('') is search('Successfully')"
      end
    ],
    "unredacted create-success classification" => [
      "Beszel create-success classification must redact the captured CLI result",
      lambda do |fixture|
        report = fixture.find { |task| task["name"] == "Report newly created Beszel superuser" }
        report.delete("no_log")
      end
    ],
    "unredacted atomic superuser creation" => [
      "Beszel atomic superuser creation must use the repository redaction contract",
      lambda do |fixture|
        create = fixture.find do |task|
          task["name"] == "Create the superuser without updating an existing identity"
        end
        create["no_log"] = false
      end
    ],
    "verify-tagged atomic superuser creation" => [
      "Beszel atomic superuser creation must not run during verify-only execution",
      lambda do |fixture|
        create = fixture.find do |task|
          task["name"] == "Create the superuser without updating an existing identity"
        end
        create["tags"] = ["platform_verify_beszel"]
      end
    ],
    "check-mode-forced atomic superuser creation" => [
      "Beszel atomic superuser creation must obey Ansible check mode",
      lambda do |fixture|
        create = fixture.find do |task|
          task["name"] == "Create the superuser without updating an existing identity"
        end
        create["check_mode"] = false
      end
    ]
  }

  Dir.mktmpdir("beszel-password-preservation") do |directory|
    mutations.each do |label, (expected_failure, mutate)|
      fixture = Marshal.load(Marshal.dump(tasks))
      mutate.call(fixture)
      path = File.join(directory, "tasks.yml")
      File.write(path, YAML.dump(fixture))
      _stdout, stderr, status = capture3_with_timeout(
        { "BESZEL_PASSWORD_TASKS_PATH" => path },
        RbConfig.ruby, __FILE__, chdir: ROOT, timeout_seconds: 20
      )
      check(failures, !status.success? && stderr.include?(expected_failure),
            "self-test mutation was not rejected precisely: #{label}")
    end
  end
end

if failures.empty?
  message = if ARGV == ["--self-test"]
              "Beszel password preservation mutation self-test passed"
            else
              "Beszel password preservation contract passed"
            end
  puts message
  exit 0
end

warn failures.map { |failure| "FAIL: #{failure}" }.join("\n")
exit 1
