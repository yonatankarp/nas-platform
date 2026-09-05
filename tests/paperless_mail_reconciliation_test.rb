#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "yaml"

require_relative "policy_support"
require_relative "http_fixture_support"

include HttpFixtureSupport
include TestScaffold

ROLE = File.join(ROOT, "roles", "paperless_ngx", "tasks", "main.yml")

ACCOUNT = {
  "id" => 7, "name" => "managed-gmail", "imap_server" => "imap.gmail.com",
  "imap_port" => 993, "imap_security" => 2, "username" => "gmail@example.invalid",
  "is_token" => false, "account_type" => 1, "character_set" => "UTF-8", "owner" => 1
}.freeze
RULE = {
  "id" => 9, "name" => "managed-inbox", "account" => 7, "enabled" => true,
  "folder" => "INBOX", "filter_from" => nil, "filter_to" => nil, "filter_subject" => nil,
  "filter_body" => nil, "filter_attachment_filename_include" => nil,
  "filter_attachment_filename_exclude" => nil, "maximum_age" => 30,
  "action" => 3, "action_parameter" => nil, "assign_title_from" => 1, "assign_tags" => [],
  "assign_correspondent_from" => 1, "assign_correspondent" => nil,
  "assign_document_type" => nil, "assign_owner_from_rule" => true, "order" => 0,
  "attachment_type" => 1, "consumption_scope" => 1, "pdf_layout" => 0,
  "stop_processing" => false, "owner" => 1
}.freeze
VERIFY_SECRET_SENTINELS = [
  "fixture-admin-secret", "fixture-reader-secret", "fixture-db-secret",
  "fixture gmail secret", "fixturegmailsecret", "fixture-django-secret"
].freeze
MAIL_ITEM_IDENTITY_SENTINELS = [
  ACCOUNT.fetch("name"), ACCOUNT.fetch("username"), RULE.fetch("name")
].freeze
MAIL_ITEM_VALIDATION_TASKS = [
  "Validate every existing Paperless mail account before mutation",
  "Validate every existing Paperless mail rule before mutation"
].freeze
PYTHON = ENV.fetch("PATH").split(File::PATH_SEPARATOR).map do |directory|
  File.join(directory, "python3")
end.find { |path| File.executable?(path) }.freeze

# The role is one stage per file; static_role_tasks assembles it the way Ansible
# does, imports spliced in where they stand. The mail block this fixture runs is
# contiguous in that assembly and split across mail_state.yml, mail_probe.yml and
# mail_reconcile.yml in the tree, so reading main.yml alone would find neither
# endpoint and raise rather than pass.
def selected_mail_tasks
  tasks = PolicySupport.static_role_tasks(ROLE, aliases: true)
  first = tasks.index { |task| task["name"] == "List Paperless mail accounts for reconciliation" }
  last = tasks.index do |task|
    task["name"] == "Require exact Paperless administrator, mail account, and mail rule"
  end
  raise "Paperless mail task block is unavailable" unless first && last && first < last

  Marshal.load(Marshal.dump(tasks[first..last]))
end

def missing_mail_item_output_guards(tasks)
  MAIL_ITEM_VALIDATION_TASKS.reject do |name|
    tasks.find { |task| task["name"] == name }&.fetch("no_log", false) == true
  end
end

# The fixture answers a status and an already-serialised body; the shared
# fixture server puts them on the wire. Paperless answers text/plain for the
# errors it reports, which is what the role has to read.
def response(status, body, content_type: "application/json")
  [status, body, content_type]
end

def with_paperless_api(probe:, initial_accounts:, initial_rules:, listing: :complete, &block)
  requests = []
  state = { "accounts" => initial_accounts, "rules" => initial_rules }
  with_http_fixture(->(port) { block.call(port, requests) }) do |method, target, _headers, body|
    requests << [method, target, body]

    case [method, target]
    when ["POST", "/api/token/"]
      username = JSON.parse(body).fetch("username")
      response(200, JSON.generate("token" => "fixture-token-#{username}"))
    when ["GET", "/api/users/?page_size=1000"]
      users = [{
        "id" => 1, "username" => "admin", "email" => "admin@example.invalid",
        "is_superuser" => true, "is_staff" => true, "is_active" => true
      }]
      response(200, JSON.generate("count" => users.length, "next" => nil,
                                          "previous" => nil, "results" => users))
    when ["GET", "/api/mail_accounts/?page_size=1000"]
      count = listing == :count_mismatch ? state["accounts"].length + 1 : state["accounts"].length
      count += 1 if listing == :next_page_duplicate
      next_page = listing == :next_page_duplicate ? "http://127.0.0.1/hidden-page" : nil
      count = count.to_s if listing == :malformed_count
      response(200, JSON.generate("count" => count, "next" => next_page, "previous" => nil,
                                          "results" => state["accounts"]))
    when ["GET", "/api/mail_rules/?page_size=1000"]
      count = listing == :count_mismatch ? state["rules"].length + 1 : state["rules"].length
      count += 1 if listing == :next_page_duplicate
      next_page = listing == :next_page_duplicate ? "http://127.0.0.1/hidden-page" : nil
      count = count.to_s if listing == :malformed_count
      response(200, JSON.generate("count" => count, "next" => next_page, "previous" => nil,
                                          "results" => state["rules"]))
    when ["POST", "/api/mail_accounts/test/"]
      if probe == :failure
        response(400, "Unable to connect to server", content_type: "text/plain")
      else
        if probe == :managed_alteration
          state["rules"] = state["rules"].map do |rule|
            rule["name"] == "managed-inbox" ? rule.merge("enabled" => false) : rule
          end
        end
        response(200, JSON.generate("success" => true))
      end
    when ["POST", "/api/mail_accounts/"]
      payload = JSON.parse(body)
      state["accounts"] << ACCOUNT.merge(payload.reject { |key, _| key == "password" })
      response(201, JSON.generate(state["accounts"].last))
    when ["POST", "/api/mail_rules/"]
      payload = JSON.parse(body)
      state["rules"] << RULE.merge(payload)
      response(201, JSON.generate(state["rules"].last))
    else
      if method == "PATCH" && target.match?(%r{\A/api/mail_accounts/\d+/\z})
        payload = JSON.parse(body).reject { |key, _| key == "password" }
        state["accounts"] = state["accounts"].map do |account|
          account["id"] == target.split("/").fetch(3).to_i ? account.merge(payload) : account
        end
        response(200, JSON.generate(state["accounts"].find { |account| account["id"] == 7 }))
      elsif method == "PATCH" && target.match?(%r{\A/api/mail_rules/\d+/\z})
        payload = JSON.parse(body)
        state["rules"] = state["rules"].map do |rule|
          rule["id"] == target.split("/").fetch(3).to_i ? rule.merge(payload) : rule
        end
        response(200, JSON.generate(state["rules"].find { |rule| rule["id"] == 9 }))
      else
        response(400, "unexpected fixture request", content_type: "text/plain")
      end
    end
  end
end

def run_fixture(port)
  variables = {
    "paperless_api" => "http://127.0.0.1:#{port}", "paperless_api_token" => "fixture-token",
    "platform_compose_kind" => "mac", "paperless_mail_account_name" => "managed-gmail",
    "paperless_mail_rule_name" => "managed-inbox",
    "paperless_managed_administrators" => [{ "id" => 1 }],
    "paperless_mail_account" => ACCOUNT.slice(
      "imap_server", "imap_port", "imap_security", "is_token", "account_type", "character_set"
    ),
    "paperless_mail_account_payload" => ACCOUNT.reject { |key, _| key == "id" }.merge(
      "password" => "fixture-secret"
    ),
    "paperless_mail_rule" => RULE.reject { |key, _| %w[id name account owner].include?(key) },
    "paperless_installed_mail_account_credential_fingerprint" => "same",
    "paperless_mail_account_credential_fingerprint" => "same"
  }
  run_playbook(selected_mail_tasks, variables, prefix: "paperless-mail-reconciliation-")
end

def run_storage_policy_fixture(effective_paths)
  task_names = [
    "Require exact Paperless host storage policy",
    "Validate canonical Paperless storage source separation"
  ]
  tasks = PolicySupport.static_role_tasks(ROLE, aliases: true).select do |candidate|
    task_names.include?(candidate["name"])
  end
  raise "Paperless storage policy tasks are unavailable" unless tasks.map { |task| task["name"] } == task_names

  variables = {
    "paperless_archive_host_path" => "/volume2/Documents/archive",
    "paperless_consume_host_path" => "/volume2/Documents/inbox",
    "paperless_export_host_path" => "/volume2/Documents/export",
    "paperless_state_host_path" => "/volume1/Docker/paperless-ngx",
    "role_path" => File.dirname(File.dirname(ROLE)),
    "ansible_facts" => { "python" => { "executable" => PYTHON } }
  }.merge(effective_paths)
  state_root = variables.fetch("paperless_effective_state_host_path")
  variables["paperless_effective_document_host_paths"] ||= %w[archive consume export].map do |kind|
    variables.fetch("paperless_effective_#{kind}_host_path")
  end
  variables["paperless_effective_state_host_paths"] ||= %w[postgres redis data tessdata].map do |kind|
    File.join(state_root, kind)
  end + [variables.fetch("paperless_effective_cache_host_path", File.join(state_root, "cache"))]
  run_playbook(tasks, variables, prefix: "paperless-storage-policy-")
end

def run_full_verify_tag_fixture(port, fingerprint: true)
  Dir.mktmpdir("paperless-full-verify-tag-") do |directory|
    runtime = File.join(directory, "runtime")
    fingerprint_directory = File.join(runtime, "services", "paperless-ngx")
    FileUtils.mkdir_p(fingerprint_directory)
    gmail_secret = "fixture gmail secret"
    django_secret = "fixture-django-secret"
    expected_fingerprint = Digest::SHA256.hexdigest("#{django_secret}:#{gmail_secret.delete(' ')}")
    if fingerprint
      File.write(
        File.join(fingerprint_directory, ".gmail-credential-fingerprint"),
        "#{expected_fingerprint}\n", mode: "w", perm: 0o600
      )
    end

    collection_root = File.join(directory, "collections")
    module_directory = File.join(
      collection_root, "ansible_collections", "community", "docker", "plugins", "modules"
    )
    FileUtils.mkdir_p(module_directory)
    File.write(File.join(module_directory, "docker_compose_v2_exec.py"), <<~PYTHON, mode: "w", perm: 0o700)
      #!/usr/bin/python
      from ansible.module_utils.basic import AnsibleModule
      import json

      module = AnsibleModule(
          argument_spec={
              "project_src": {"type": "str"}, "project_name": {"type": "str"},
              "files": {"type": "list"}, "env_files": {"type": "list"},
              "service": {"type": "str"}, "argv": {"type": "list"},
              "tty": {"type": "bool"}, "env": {"type": "dict"},
          },
          supports_check_mode=True,
      )
      users = [{
          "id": 11, "username": "reader", "email": "reader@example.invalid",
          "is_active": True, "is_staff": False, "is_superuser": False, "groups": []
      }]
      output = json.dumps(users, sort_keys=True)
      module.exit_json(changed=False, rc=0, stdout=output, stdout_lines=[output])
    PYTHON
    File.write(File.join(module_directory, "docker_compose_v2.py"), <<~PYTHON, mode: "w", perm: 0o700)
      #!/usr/bin/python
      from ansible.module_utils.basic import AnsibleModule

      module = AnsibleModule(argument_spec={}, supports_check_mode=True)
      module.exit_json(changed=False)
    PYTHON

    variables = {
      "platform_compose_kind" => "mac", "platform_project_name" => "paperless-verify-fixture",
      "platform_current_dir" => ROOT, "platform_runtime_dir" => runtime,
      # verify.yml resolves this in pre_tasks; this play stands in for that.
      "platform_service_compose_files" => { "paperless-ngx" => ["compose.yml"] },
      "paperless_port" => port,
      # The AI settings live only in inventory group_vars, which this synthetic play
      # does not load, so the fixture supplies them the way it supplies every other
      # argument the role declares required.
      "paperless_ai_enabled" => false,
      "paperless_ai_llm_endpoint" => "http://ollama.example.invalid:11434",
      "paperless_ai_llm_model" => "fixture-model",
      "vault_paperless_admin_username" => "admin",
      "vault_paperless_admin_password" => "fixture-admin-secret",
      "vault_paperless_admin_email" => "admin@example.invalid",
      "vault_paperless_db_name" => "paperless", "vault_paperless_db_username" => "paperless",
      "vault_paperless_db_password" => "fixture-db-secret",
      "vault_paperless_django_secret_key" => django_secret,
      "vault_paperless_gmail_account" => "gmail@example.invalid",
      "vault_paperless_gmail_app_password" => gmail_secret,
      "paperless_mail_account_name" => "managed-gmail",
      "paperless_mail_rule_name" => "managed-inbox",
      "vault_managed_paperless_ngx_users" => [{
        "username" => "reader", "password" => "fixture-reader-secret",
        "email" => "reader@example.invalid", "is_active" => true, "is_staff" => false,
        "is_superuser" => false, "groups" => []
      }]
    }
    playbook = [{
      "hosts" => "localhost", "gather_facts" => false, "vars" => variables,
      "roles" => [{ "role" => "paperless_ngx", "tags" => ["never"] }]
    }]
    path = File.join(directory, "playbook.yml")
    File.write(path, YAML.dump(playbook), mode: "w", perm: 0o600)
    collections_path = [
      collection_root, File.expand_path("~/.ansible/collections"), "/usr/share/ansible/collections"
    ].join(File::PATH_SEPARATOR)
    Open3.capture3(
      { "ANSIBLE_NOCOLOR" => "1", "ANSIBLE_COLLECTIONS_PATH" => collections_path },
      "ansible-playbook", "-i", "localhost,", "-c", "local", path,
      "--tags", "platform_verify_paperless", chdir: ROOT
    )
  end
end

failures = []

mail_tasks = selected_mail_tasks
missing_mail_item_output_guards(mail_tasks).each do |name|
  failures << "Paperless per-item validation can disclose its loop record: #{name}"
end
MAIL_ITEM_VALIDATION_TASKS.each do |name|
  mutant = Marshal.load(Marshal.dump(mail_tasks))
  task = mutant.find { |candidate| candidate["name"] == name }
  task["no_log"] = false if task
  failures << "Paperless mail output-guard mutation survived: #{name}" if
    missing_mail_item_output_guards(mutant).empty?
end

with_paperless_api(probe: :success, initial_accounts: [ACCOUNT.dup], initial_rules: [RULE.dup]) do |port, requests|
  stdout, stderr, status = run_fixture(port)
  failures << "concurrent global activity fixture failed: #{stderr.lines.last&.strip}" unless status.success?
  failures << "mail reconciliation consulted concurrent global resources" if
    requests.any? { |_method, target, _body| target.match?(%r{\A/api/(?:tasks|documents|processed_mail)/}) }
  failures << "idempotent mail reconciliation persisted managed state" if
    requests.any? { |method, target, _body| %w[POST PATCH DELETE].include?(method) && target != "/api/mail_accounts/test/" }
  failures << "mail reconciliation disclosed the credential" if (stdout + stderr).include?("fixture-secret")
  failures << "mail reconciliation disclosed a synthetic mail identity" if
    MAIL_ITEM_IDENTITY_SENTINELS.any? { |identity| (stdout + stderr).include?(identity) }
end

with_paperless_api(probe: :managed_alteration,
                   initial_accounts: [ACCOUNT.dup], initial_rules: [RULE.dup]) do |port, requests|
  _stdout, _stderr, status = run_fixture(port)
  failures << "managed record alteration was accepted" if status.success?
  failures << "managed alteration fixture reached persistence" if
    requests.any? { |method, target, _body| %w[POST PATCH DELETE].include?(method) && target != "/api/mail_accounts/test/" }
end

with_paperless_api(probe: :failure, initial_accounts: [], initial_rules: []) do |port, requests|
  stdout, stderr, status = run_fixture(port)
  failures << "failed credential was accepted" if status.success?
  failures << "failed credential caused managed persistence mutation" if
    requests.any? { |method, target, _body| %w[POST PATCH DELETE].include?(method) && target != "/api/mail_accounts/test/" }
  failures << "failed credential disclosed the credential" if (stdout + stderr).include?("fixture-secret")
end

%i[next_page_duplicate count_mismatch malformed_count].each do |listing|
  with_paperless_api(
    probe: :success, initial_accounts: [ACCOUNT.dup], initial_rules: [RULE.dup], listing: listing
  ) do |port, requests|
    _stdout, _stderr, status = run_fixture(port)
    failures << "#{listing} mail listing was accepted" if status.success?
    failures << "#{listing} mail listing reached persistence" if
      requests.any? do |method, target, _body|
        %w[POST PATCH DELETE].include?(method) && target != "/api/mail_accounts/test/"
      end
  end
end

base_paths = {
  "paperless_effective_archive_host_path" => "/sandbox/Documents/archive",
  "paperless_effective_consume_host_path" => "/sandbox/Documents/inbox",
  "paperless_effective_export_host_path" => "/sandbox/Documents/export",
  "paperless_effective_state_host_path" => "/sandbox/Docker/paperless-ngx"
}
%w[archive consume export].each do |kind|
  nested = base_paths.merge(
    "paperless_effective_state_host_path" =>
      "#{base_paths.fetch("paperless_effective_#{kind}_host_path")}/state"
  )
  _stdout, _stderr, status = run_storage_policy_fixture(nested)
  failures << "state nested under #{kind} documents was accepted" if status.success?
end
%w[postgres redis data tessdata cache].each do |kind|
  document_nested_under_state = base_paths.merge(
    "paperless_effective_archive_host_path" =>
      File.join(base_paths.fetch("paperless_effective_state_host_path"), kind, "archive")
  )
  _stdout, _stderr, status = run_storage_policy_fixture(document_nested_under_state)
  failures << "archive documents nested under #{kind} state were accepted" if status.success?
end
overlapping_documents = base_paths.merge(
  "paperless_effective_consume_host_path" => "/sandbox/Documents/archive/inbox"
)
_stdout, _stderr, status = run_storage_policy_fixture(overlapping_documents)
failures << "overlapping document sources were accepted" if status.success?

Dir.mktmpdir("paperless-adoption-storage-") do |root|
  paperless = File.join(root, "legacy", "paperless-ngx")
  %w[media consume export postgres redis data tessdata cache].each do |relative|
    FileUtils.mkdir_p(File.join(paperless, relative))
  end
  adoption_paths = {
    "paperless_effective_archive_host_path" => File.join(paperless, "media"),
    "paperless_effective_consume_host_path" => File.join(paperless, "consume"),
    "paperless_effective_export_host_path" => File.join(paperless, "export"),
    "paperless_effective_state_host_path" => paperless,
    "paperless_effective_cache_host_path" => File.join(paperless, "cache")
  }
  stdout, stderr, status = run_storage_policy_fixture(adoption_paths)
  failures << "legitimate sibling Paperless adoption storage was rejected: #{stdout}\n#{stderr}" unless status.success?

  FileUtils.rm_rf(adoption_paths.fetch("paperless_effective_archive_host_path"))
  File.symlink(File.join(paperless, "data"), adoption_paths.fetch("paperless_effective_archive_host_path"))
  _stdout, _stderr, status = run_storage_policy_fixture(adoption_paths)
  failures << "document-to-state canonical alias was accepted" if status.success?

  File.unlink(adoption_paths.fetch("paperless_effective_archive_host_path"))
  FileUtils.mkdir_p(adoption_paths.fetch("paperless_effective_archive_host_path"))
  FileUtils.rm_rf(adoption_paths.fetch("paperless_effective_consume_host_path"))
  File.symlink(
    adoption_paths.fetch("paperless_effective_archive_host_path"),
    adoption_paths.fetch("paperless_effective_consume_host_path")
  )
  _stdout, _stderr, status = run_storage_policy_fixture(adoption_paths)
  failures << "document canonical alias was accepted" if status.success?
end

with_paperless_api(probe: :success, initial_accounts: [ACCOUNT.dup], initial_rules: [RULE.dup]) do |port, requests|
  stdout, stderr, status = run_full_verify_tag_fixture(port)
  failures << "tagged Paperless verification failed: #{stdout}\n#{stderr}" unless status.success?
  verify_reads = requests.select { |method, _target, _body| method == "GET" }.map { |_method, target, _body| target }
  failures << "tagged Paperless verification did not authoritatively reread account then rule" unless
    verify_reads == [
      "/api/users/?page_size=1000", "/api/users/?page_size=1000",
      "/api/mail_accounts/?page_size=1000", "/api/mail_rules/?page_size=1000",
      "/api/mail_accounts/?page_size=1000", "/api/mail_rules/?page_size=1000"
    ]
  failures << "tagged Paperless verification attempted persistence" if
    requests.any? do |method, target, _body|
      %w[PATCH DELETE].include?(method) || (method == "POST" && target != "/api/token/")
    end
  failures << "tagged Paperless verification reported a mutation" unless stdout.match?(/changed=0\s/)
  failures << "tagged Paperless verification disclosed a secret" if
    VERIFY_SECRET_SENTINELS.any? do |secret|
      (stdout + stderr).include?(secret)
    end
  failures << "tagged Paperless verification disclosed a synthetic mail identity" if
    MAIL_ITEM_IDENTITY_SENTINELS.any? { |identity| (stdout + stderr).include?(identity) }
end

with_paperless_api(probe: :success, initial_accounts: [ACCOUNT.dup], initial_rules: [RULE.dup]) do |port, requests|
  stdout, stderr, status = run_full_verify_tag_fixture(port, fingerprint: false)
  failures << "tagged Paperless verification accepted a missing credential fingerprint" if status.success?
  failures << "missing fingerprint verification attempted persistence" if
    requests.any? do |method, target, _body|
      %w[PATCH DELETE].include?(method) || (method == "POST" && target != "/api/token/")
    end
  failures << "missing fingerprint verification disclosed a secret" if
    VERIFY_SECRET_SENTINELS.any? do |secret|
      (stdout + stderr).include?(secret)
    end
end

abort failures.join("\n") unless failures.empty?
puts "Paperless deterministic mail reconciliation fixtures passed"
