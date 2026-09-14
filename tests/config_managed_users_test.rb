#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "shellwords"
require "tmpdir"
require "uri"
require "yaml"
require_relative "policy_support"

require_relative "policy_support"
require_relative "http_fixture_support"
require_relative "case_pool_support"

include HttpFixtureSupport
include TestScaffold

DOZZLE_TASKS = File.join(ROOT, "roles", "dozzle", "tasks", "managed_users.yml")
DOZZLE_MAIN = File.join(ROOT, "roles", "dozzle", "tasks", "main.yml")
DOZZLE_TEMPLATE = File.join(ROOT, "roles", "dozzle", "templates", "users.yml.j2")
STATE_FILTER = File.join(ROOT, "filter_plugins", "managed_user_state.py")
SAFE_SLURP = File.join(ROOT, "library", "atomic_safe_slurp.py")
VALIDATE_POLICY = File.join(ROOT, "tests", "validate-policy.sh")

BCRYPT_A = "$2b$12$aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
BCRYPT_B = "$2b$12$bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# Every property these roles must have, stated against the parsed thing Ansible
# would run rather than against the text of the file that spells it. A module
# key, a `when`, a `no_log`, a loop, or a rescue attached to one particular
# block are things the role acts on; a substring is not. "Dozzle rejects
# malformed YAML" used to be satisfied by `rescue:` appearing anywhere in the
# file -- inside a comment, or inside some other task's name -- and never said
# the rescue guarded the safe-load block at all.
#
# Each entry is a predicate over the parsed context assembled below, so
# --self-test can mutate that context the way a regression would (retarget a
# module, drop a `when`, unset a `no_log`, detach a rescue) and watch the
# predicate fire. That is the difference from the loop this replaced, which
# deleted the very substring it then searched for.
STRUCTURAL_PROPERTIES = {
  "Dozzle safe load" => lambda do |context|
    parse = named_task(
      dozzle_safe_load_block(context), "Parse the existing Dozzle users document"
    )
    document = parse&.dig("ansible.builtin.set_fact", "dozzle_existing_document").to_s
    !parse.nil? && parse["no_log"] == true &&
      document.match?(/\|\s*b64decode\s*\|\s*managed_users_yaml/)
  end,
  "Dozzle malformed refusal" => lambda do |context|
    safe_load = named_task(
      context.fetch(:dozzle), "Safely load the existing Dozzle users document"
    )
    guarded = Array(safe_load&.fetch("block", nil)).map { |task| task["name"] }
    refusals = Array(safe_load&.fetch("rescue", nil))
    # The rescue has to belong to the block that does the reading and parsing.
    guarded.include?("Atomically read the existing Dozzle users document") &&
      guarded.include?("Parse the existing Dozzle users document") &&
      refusals.length == 1 && refusals.first.key?("ansible.builtin.fail") &&
      refusals.first.dig("ansible.builtin.fail", "msg").to_s.include?("no users were changed")
  end,
  "Dozzle atomic read" => lambda do |context|
    read = named_task(
      dozzle_safe_load_block(context), "Atomically read the existing Dozzle users document"
    )
    arguments = read&.fetch("atomic_safe_slurp", nil)
    tasks = PolicySupport.flatten_tasks(context.fetch(:dozzle))
    arguments.is_a?(Hash) && arguments["max_bytes"] == 1_048_576 &&
      arguments["path"] == "{{ dozzle_users_path }}" && read["no_log"] == true &&
      # Neither a plain slurp nor a stat-then-read: the read is the whole check.
      tasks.none? { |task| task.key?("ansible.builtin.slurp") } &&
      tasks.none? { |task| task["register"] == "dozzle_existing_users_stat" }
  end,
  "Dozzle explicit presence" => lambda do |context|
    refusal = dozzle_hash_refusal(context)
    conditions = Array(refusal&.dig("ansible.builtin.assert", "that"))
    # Absence is decided by one named fact, and every condition is guarded by it,
    # so a missing entry can never be read as a matching one.
    refusal&.fetch("vars", nil).is_a?(Hash) &&
      refusal.fetch("vars").key?("dozzle_existing_key_present") &&
      conditions.length >= 3 &&
      conditions.all? { |condition| condition.include?("dozzle_existing_key_present") }
  end,
  "Dozzle hash refusal" => lambda do |context|
    refusal = dozzle_hash_refusal(context)
    !refusal.nil? &&
      refusal.dig("ansible.builtin.assert", "fail_msg").to_s.include?("will not replace") &&
      refusal["loop"] == "{{ dozzle_desired_users | dict2items }}" &&
      refusal["no_log"] == true
  end,
  "Dozzle unmanaged preservation" => lambda do |context|
    preserve = named_task(context.fetch(:dozzle), "Preserve unmanaged Dozzle users verbatim")
    reconcile = named_task(context.fetch(:dozzle), "Resolve the reconciled Dozzle users document")
    merged = reconcile&.dig("ansible.builtin.set_fact", "dozzle_reconciled_users").to_s
    !preserve.nil? && preserve["loop"] == "{{ dozzle_existing_users | dict2items }}" &&
      # Without this `when` the loop would also copy the managed identities back
      # over their reconciled values.
      preserve["when"].to_s.include?("not in dozzle_desired_normalized_names") &&
      preserve.dig("ansible.builtin.set_fact", "dozzle_unmanaged_users").to_s
            .include?("combine({item.key: item.value})") &&
      merged.include?("dozzle_unmanaged_users | combine(dozzle_desired_users)")
  end,
  "Dozzle rendered loop" => lambda do |context|
    # users.yml.j2 is a template, not YAML: read it as its sequence of Jinja
    # tags and the line they enclose, which says what it renders per user.
    tags = context.fetch(:dozzle_template).scan(/\{%-?\s*(.*?)\s*-?%\}/).flatten
    emitted = context.fetch(:dozzle_template).lines.map(&:strip).select do |line|
      line.start_with?("{{")
    end
    tags.length == 2 && tags.last == "endfor" &&
      tags.first.match?(/\Afor\s+key,\s*value\s+in\s+dozzle_reconciled_document\s*\|\s*dictsort\z/) &&
      emitted == ["{{ key | to_json }}: {{ value | to_json }}"]
  end,
  "Dozzle managed authentication" => lambda do |context|
    auth = named_task(context.fetch(:dozzle_main), "Authenticate each managed Dozzle user")
    auth&.fetch("loop", nil) == "{{ vault_managed_dozzle_users }}" &&
      auth.dig("ansible.builtin.uri", "url") == "{{ dozzle_api }}/token" &&
      auth["no_log"] == true && auth["changed_when"] == false &&
      auth["check_mode"] == false
  end,
  # The two filter properties are stated as the behaviour itself: the parser is
  # handed the document it must refuse and asked what it did. A substring saying
  # the token class is mentioned somewhere in the plugin proves far less.
  "strict YAML alias refusal" => lambda do |context|
    managed_users_yaml_outcome(
      "shared: &shared {password: #{BCRYPT_B}}\nusers: {reader: *shared}\n",
      context.fetch(:state_filter_path)
    ).include?("anchors and aliases are forbidden")
  end,
  "strict YAML duplicate refusal" => lambda do |context|
    managed_users_yaml_outcome(
      "users:\n  reader: {password: #{BCRYPT_A}}\n  ' Reader ': {password: #{BCRYPT_B}}\n",
      context.fetch(:state_filter_path)
    ).include?("duplicate normalized user identities")
  end,
  "policy registration" => lambda do |context|
    context.fetch(:validate_policy_lines).include?(
      "ruby tests/config_managed_users_test.rb --self-test\n"
    )
  end,
  "filter behavior registration" => lambda do |context|
    context.fetch(:validate_policy_lines).include?(
      "PYTHONDONTWRITEBYTECODE=1 \"$ansible_python\" tests/managed_user_state_filter_test.py\n"
    )
  end
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

# Ansible task lists nest through block/rescue/always, so finding a task by name
# has to see through those sections.
def named_task(tasks, name)
  PolicySupport.flatten_tasks(tasks).find { |task| task["name"] == name }
end

def dozzle_safe_load_block(context)
  named_task(
    context.fetch(:dozzle), "Safely load the existing Dozzle users document"
  )&.fetch("block", nil)
end

def dozzle_hash_refusal(context)
  named_task(
    context.fetch(:dozzle), "Refuse password hash replacement for existing Dozzle identities"
  )
end

# Hand the strict parser a document and report what it did with it. The plugin
# path is a parameter so --self-test can ask the same question of a mutant.
def managed_users_yaml_outcome(document, plugin_path)
  script = <<~PYTHON
    import importlib.util, sys
    spec = importlib.util.spec_from_file_location("managed_user_state", sys.argv[1])
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    try:
        module.managed_users_yaml(sys.stdin.read())
    except Exception as error:
        print(type(error).__name__ + ": " + str(error))
    else:
        print("accepted")
  PYTHON
  stdout, stderr, _status = Open3.capture3(
    { "PYTHONDONTWRITEBYTECODE" => "1" },
    ansible_python, "-c", script, plugin_path, stdin_data: document, chdir: ROOT
  )
  stdout.empty? ? stderr : stdout
end

def structural_property_failures(context)
  STRUCTURAL_PROPERTIES.reject { |_label, property| property.call(context) }.keys
end

# Freezes a fixture input the pooled cases below only read.
#
# Every one of them deep-copies before it changes anything, and this is what
# says so: a case that forgets raises FrozenError in its own case instead of
# handing the next case a corrupted input, which is a failure that would
# reproduce only under load. Nested rather than a bare `freeze` because these
# structures are two and three levels deep and every write in this file reaches
# past the first.
#
# An input only one case uses is not frozen -- it is built inside that case, so
# there is nothing to share.
def deep_freeze(value)
  case value
  when Hash then value.each { |pair| pair.each { |item| deep_freeze(item) } }
  when Array then value.each { |nested| deep_freeze(nested) }
  end
  value.freeze
end

# Deep-copy one parsed structure out of the context and let the caller change it
# the way a regression would, leaving the baseline the other properties are
# still measured against untouched.
def mutate_structure(context, key)
  mutant = Marshal.load(Marshal.dump(context.to_h))
  yield mutant.fetch(key)
  mutant
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
  reasons = { 200 => "OK" }.freeze
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

failures = []
abort "Config managed users: ansible-playbook is required for behavior coverage" unless
  command_available?("ansible-playbook")

dozzle_tasks = read(DOZZLE_TASKS)
dozzle_main = read(DOZZLE_MAIN)
dozzle_template = read(DOZZLE_TEMPLATE)
state_filter = read(STATE_FILTER)
safe_slurp = read(SAFE_SLURP)
validate_policy = read(VALIDATE_POLICY)

check(failures, !dozzle_tasks.empty?, "Dozzle managed-user tasks are missing")

dozzle_main_tasks = YAML.safe_load(dozzle_main, aliases: false) || []
structural_context = {
  dozzle: YAML.safe_load(dozzle_tasks, aliases: false) || [],
  dozzle_main: dozzle_main_tasks,
  dozzle_template: dozzle_template,
  state_filter_path: STATE_FILTER,
  validate_policy_lines: validate_policy.lines
}.freeze
structural_property_failures(structural_context).each do |label|
  failures << "#{label} does not hold"
end

check(failures, dozzle_main.include?("managed_users.yml"), "Dozzle main tasks do not include managed-user reconciliation")
check(failures, dozzle_tasks.include?("dozzle_existing_normalized_names") &&
                dozzle_tasks.include?("unique | length"),
      "Dozzle does not reject duplicate normalized existing names")
check(failures, dozzle_main.include?("when: dozzle_users_file.changed"),
      "Dozzle restart is not conditional on users file change")
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

# The fixtures from here to the end of the file are what this check spends its
# wall time on, and each one is a case that owns everything it touches:
# `run_dozzle_fixture` takes its own `Dir.mktmpdir` for the users document and
# the rendered output, `run_playbook` takes another for the playbook it writes,
# and `with_http_probe` binds a loopback `TCPServer` on an OS-assigned port with
# its own accept thread. No two cases share a directory, a port, an output path
# or an environment variable, and none of them touches the repository.
#
# Result locals are declared block-local -- the names after the `;` in each
# parameter list -- rather than renamed. None of `status`, `output` or
# `rendered` is a script-level name in this file today, but the moment one is
# assigned at top level -- and an `if` body opens no scope -- a case that
# assigned it without declaring it would share a single binding with its
# siblings instead of getting its own. That loss is silent: most of these fixtures are
# expected to fail, so a sibling's failing status reads as this case's own
# result and the guard passes vacuously.
#
# A fixture input that more than one case reads is frozen; one that a single
# case uses is built inside that case, so there is nothing to share.
dozzle_cases = []

if dozzle_auth_task
  dozzle_cases << lambda do |collected; responder, variables, request|
    responder = proc { |_request| 200 }
    with_http_probe(1, responder) do |port, requests|
      variables = {
        "dozzle_api" => "http://127.0.0.1:#{port}/api",
        "vault_managed_dozzle_users" => [
          { "username" => "reader", "password" => "managed-plaintext" }
        ]
      }
      run_playbook(task_playbook([dozzle_auth_task], variables)) do |_tmp, output, status|
        check(collected, status.success?, "Dozzle authentication fixture failed: #{output.lines.last&.strip}")
      end
      request = requests.first || {}
      check(collected,
            request["method"] == "POST" && request["target"] == "/api/token" &&
              request["body"] == URI.encode_www_form(
                "username" => "reader", "password" => "managed-plaintext"
              ),
            "Dozzle authentication fixture sent a different method, endpoint, or body")
    end
  end
end

if !dozzle_tasks.empty?
  existing = deep_freeze({
    "users" => {
      "admin" => { "email" => "old", "name" => "Wrong", "password" => BCRYPT_A,
                     "filter" => "old", "roles" => "admin" },
      "reader" => { "email" => "old", "name" => "Wrong", "password" => BCRYPT_B,
                      "filter" => "old", "roles" => "none", "stale" => true },
      "unmanaged" => { "password" => "opaque", "custom" => { "nested" => [1, "two"] } }
    },
    "outside" => { "preserved" => true }
  })
  dozzle_cases << lambda do |collected; rendered, output, status|
    rendered, output, status = run_dozzle_fixture(YAML.dump(existing))
    check(collected, status.success?, "Dozzle merge fixture failed: #{output.lines.last&.strip}")
    if rendered
      check(collected, rendered["outside"] == existing["outside"], "Dozzle did not preserve root keys outside users")
      check(collected, rendered.dig("users", "unmanaged") == existing.dig("users", "unmanaged"),
            "Dozzle did not preserve an unmanaged user verbatim")
      check(collected, rendered.dig("users", "reader") == {
              "email" => "reader@example.invalid", "name" => "Managed Reader",
              "password" => BCRYPT_B, "filter" => "status=running", "roles" => "user"
            }, "Dozzle did not render the exact managed non-secret fields")
    end
  end

  dozzle_cases << lambda do |collected; _rendered, _output, status|
    _rendered, _output, status = run_dozzle_fixture("users: [malformed mapping]\n")
    check(collected, !status.success?, "Dozzle accepted a malformed users document")
  end
  dozzle_cases << lambda do |collected; hash_change, _rendered, output, status|
    hash_change = Marshal.load(Marshal.dump(existing))
    hash_change["users"]["reader"]["password"] = BCRYPT_A
    _rendered, output, status = run_dozzle_fixture(YAML.dump(hash_change))
    check(collected, !status.success? && output.include?("will not replace"),
          "Dozzle accepted a hash change for an existing allowlisted identity")
  end
  dozzle_cases << lambda do |collected; duplicate_names, _rendered, _output, status|
    duplicate_names = Marshal.load(Marshal.dump(existing))
    duplicate_names["users"][" Reader "] = duplicate_names["users"]["reader"]
    _rendered, _output, status = run_dozzle_fixture(YAML.dump(duplicate_names))
    check(collected, !status.success?, "Dozzle accepted duplicate normalized existing identities")
  end

  dozzle_cases += {
    "empty scalar" => "",
    "empty list" => [],
    "null" => nil,
    "missing password" => {}
  }.map do |label, unsafe_entry|
    lambda do |collected; unsafe_existing, _rendered, unsafe_output, unsafe_status|
      unsafe_existing = Marshal.load(Marshal.dump(existing))
      unsafe_existing["users"]["reader"] = unsafe_entry
      _rendered, unsafe_output, unsafe_status = run_dozzle_fixture(YAML.dump(unsafe_existing))
      check(collected, !unsafe_status.success? && unsafe_output.include?("will not replace"),
            "Dozzle treated an existing #{label} allowlisted entry as absent")
    end
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
  dozzle_cases += unsafe_yaml_documents.map do |label, unsafe_source|
    lambda do |collected; _rendered, _unsafe_output, unsafe_status|
      _rendered, _unsafe_output, unsafe_status = run_dozzle_fixture(unsafe_source)
      check(collected, !unsafe_status.success?, "Dozzle accepted #{label} YAML")
    end
  end
end

in_parallel_cases(failures, dozzle_cases) { |fixture, collected| fixture.call(collected) }

unless [[], ["--self-test"]].include?(ARGV)
  abort "usage: config_managed_users_test.rb [--self-test]"
end

if ARGV == ["--self-test"]
  structural_property_failures(structural_context).each do |label|
    failures << "self-test baseline rejected #{label}"
  end

  # Every mutation below changes something the role would act on -- a module
  # key, a `when`, a `no_log`, the block a rescue hangs off, the order of two
  # tasks -- and the matching property has to notice. None of them edits the
  # text its property looks for, which is exactly what made the substring loop
  # this replaced circular: it proved only that deleting a fragment defeats a
  # search for that fragment.
  Dir.mktmpdir("nas-platform-managed-user-state-mutant-") do |mutant_directory|
    alias_mutant = File.join(mutant_directory, "alias_managed_user_state.py")
    File.write(
      alias_mutant,
      state_filter.sub("(yaml.tokens.AnchorToken, yaml.tokens.AliasToken)", "()"),
      mode: "w", perm: 0o600
    )
    duplicate_mutant = File.join(mutant_directory, "duplicate_managed_user_state.py")
    File.write(
      duplicate_mutant,
      state_filter.sub("if len(set(normalized)) != len(normalized):", "if False:"),
      mode: "w", perm: 0o600
    )

    structural_mutations = {
      "Dozzle safe load" => lambda do |context|
        mutate_structure(context, :dozzle) do |tasks|
          named_task(tasks, "Parse the existing Dozzle users document")
            .fetch("ansible.builtin.set_fact")["dozzle_existing_document"] =
              "{{ dozzle_existing_users_source.content | b64decode | from_yaml }}"
        end
      end,
      "Dozzle malformed refusal" => lambda do |context|
        # Detach the rescue from the block it guards -- the defect the old
        # `dozzle_tasks.include?("rescue:")` check could never have seen.
        mutate_structure(context, :dozzle) do |tasks|
          named_task(tasks, "Safely load the existing Dozzle users document").delete("rescue")
        end
      end,
      "Dozzle atomic read" => lambda do |context|
        mutate_structure(context, :dozzle) do |tasks|
          read = named_task(tasks, "Atomically read the existing Dozzle users document")
          read["ansible.builtin.slurp"] = { "src" => read.delete("atomic_safe_slurp")["path"] }
        end
      end,
      "Dozzle explicit presence" => lambda do |context|
        mutate_structure(context, :dozzle) do |tasks|
          dozzle_hash_refusal({ dozzle: tasks }).fetch("vars").delete("dozzle_existing_key_present")
        end
      end,
      "Dozzle hash refusal" => lambda do |context|
        mutate_structure(context, :dozzle) do |tasks|
          dozzle_hash_refusal({ dozzle: tasks })["no_log"] = false
        end
      end,
      "Dozzle unmanaged preservation" => lambda do |context|
        mutate_structure(context, :dozzle) do |tasks|
          named_task(tasks, "Preserve unmanaged Dozzle users verbatim").delete("when")
        end
      end,
      "Dozzle rendered loop" => lambda do |context|
        context.merge(
          dozzle_template: context.fetch(:dozzle_template).sub(
            "{{ key | to_json }}: {{ value | to_json }}", "{{ key }}: {{ value }}"
          )
        )
      end,
      "Dozzle managed authentication" => lambda do |context|
        mutate_structure(context, :dozzle_main) do |tasks|
          named_task(tasks, "Authenticate each managed Dozzle user").delete("loop")
        end
      end,
      "strict YAML alias refusal" => lambda do |context|
        context.merge(state_filter_path: alias_mutant)
      end,
      "strict YAML duplicate refusal" => lambda do |context|
        context.merge(state_filter_path: duplicate_mutant)
      end,
      "policy registration" => lambda do |context|
        context.merge(
          validate_policy_lines: context.fetch(:validate_policy_lines) -
            ["ruby tests/config_managed_users_test.rb --self-test\n"]
        )
      end,
      "filter behavior registration" => lambda do |context|
        context.merge(
          validate_policy_lines: context.fetch(:validate_policy_lines) -
            ["PYTHONDONTWRITEBYTECODE=1 \"$ansible_python\" tests/managed_user_state_filter_test.py\n"]
        )
      end
    }

    missing_mutations = STRUCTURAL_PROPERTIES.keys - structural_mutations.keys
    check(failures, missing_mutations.empty?,
          "structural properties without a self-test mutation: #{missing_mutations.join(', ')}")
    # Each case deep-copies its own mutant out of the frozen baseline and asks
    # every property about it, and two of the properties spawn a Python
    # interpreter to answer. They share nothing but the failure list, so they go
    # through the pool and are still reported in the order written above. The
    # `missing_mutations` check stays outside it: the pool is not the place for
    # anything a case would have to `abort` over, and that one is about the
    # table, not about any single mutation.
    structural_cases = structural_mutations.map do |label, mutate|
      lambda do |collected|
        mutant = mutate.call(structural_context)
        check(collected, mutant != structural_context,
              "the #{label} self-test mutation did not change anything")
        check(collected, structural_property_failures(mutant).include?(label),
              "self-test did not reject the #{label} mutation")
      end
    end
    in_parallel_cases(failures, structural_cases) { |mutation, collected| mutation.call(collected) }
  end

  # Each case below stands up its own mutant plugin or module in its own
  # temporary directory and waits on a Python interpreter running that file's
  # behaviour test against it. They share nothing but the failure list, so they
  # go through one pool and are still reported in the order written here.
  behavior_cases = {
    "duplicate YAML parser" => ["if duplicate:", "if False:"],
    "YAML alias parser" => [
      "(yaml.tokens.AnchorToken, yaml.tokens.AliasToken)", "()"
    ]
  }.map do |label, (before, after)|
    lambda do |collected|
      Dir.mktmpdir("nas-platform-filter-mutant-") do |directory|
        mutant = File.join(directory, "managed_user_state.py")
        mutated_source = state_filter.sub(before, after)
        File.write(mutant, mutated_source, mode: "w", perm: 0o600)
        _stdout, _stderr, mutant_status = Open3.capture3(
          { "MANAGED_USER_STATE_PLUGIN" => mutant, "PYTHONDONTWRITEBYTECODE" => "1" },
          ansible_python,
          File.join(ROOT, "tests", "managed_user_state_filter_test.py"), chdir: ROOT
        )
        check(collected, mutated_source != state_filter && !mutant_status.success?,
              "behavioral self-test did not reject #{label} mutation")
      end
    end
  end

  behavior_cases += {
    "no-follow reader" => ["os.O_NOFOLLOW", "0"],
    "nonblocking reader" => ["os.O_NONBLOCK", "0"]
  }.map do |label, (before, after)|
    lambda do |collected|
      Dir.mktmpdir("nas-platform-safe-slurp-mutant-") do |directory|
        mutant = File.join(directory, "atomic_safe_slurp.py")
        mutated_source = safe_slurp.sub(before, after)
        File.write(mutant, mutated_source, mode: "w", perm: 0o600)
        _stdout, _stderr, mutant_status = Open3.capture3(
          {
            "ATOMIC_SAFE_SLURP_MODULE" => mutant,
            "PYTHONDONTWRITEBYTECODE" => "1"
          },
          ansible_python, File.join(ROOT, "tests", "safe_slurp_test.py"), chdir: ROOT
        )
        check(collected, mutated_source != safe_slurp && !mutant_status.success?,
              "behavioral self-test did not reject the #{label} mutation")
      end
    end
  end

  in_parallel_cases(failures, behavior_cases) { |mutation, collected| mutation.call(collected) }
end

report(failures, "Config managed users: Dozzle preservation and managed-user parsing contracts hold",
       "config managed-user violation(s)")
