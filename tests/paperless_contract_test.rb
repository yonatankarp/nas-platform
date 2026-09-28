#!/usr/bin/env ruby
# frozen_string_literal: true

# Behaviour of the Paperless contract's render, static and runtime programs and
# its wrapper, one layer each. Render rows judge a canned `docker compose config`
# merge; static rows break one file per wrapper argument; runtime reaches only
# seed-fixture-only. --self-test plants a regression per guard.

require "digest"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"

require_relative "case_pool_support"
require_relative "policy_support"
require_relative "contract_test_support"

include TestScaffold
include ContractTestSupport

ROOT = File.expand_path("..", __dir__)
DIAGNOSTIC_PREFIX = "Paperless contract failed: "
CONTRACT = File.join(ROOT, "tests", "contracts", "paperless.sh")
RENDER_PROGRAM = File.join(ROOT, "tests", "contracts", "paperless-render.rb")
STATIC_PROGRAM = File.join(ROOT, "tests", "contracts", "paperless-static.rb")
RUNTIME_PROGRAM = File.join(ROOT, "tests", "contracts", "paperless-runtime.rb")

# The wrapper's preloads: neither program requires json/yaml itself.
RENDER_COMMAND = [RbConfig.ruby, "-rjson", "-rpathname"].freeze
STATIC_COMMAND = [RbConfig.ruby, "-ryaml"].freeze

# Exactly what the contract reads from the inspected tree.
FIXTURE_FILES = %w[
  services/paperless-ngx/compose.yml
  services/paperless-ngx/compose.mac.yml
  services/paperless-ngx/compose.integration.yml
  roles/paperless_ngx/tasks/main.yml
  roles/paperless_ngx/tasks/storage.yml
  roles/paperless_ngx/tasks/deploy.yml
  roles/paperless_ngx/tasks/administrator.yml
  roles/paperless_ngx/tasks/authentication.yml
  roles/paperless_ngx/tasks/managed_users.yml
  roles/paperless_ngx/tasks/identity.yml
  roles/paperless_ngx/tasks/mail_state.yml
  roles/paperless_ngx/tasks/mail_probe.yml
  roles/paperless_ngx/tasks/mail_reconcile.yml
  roles/paperless_ngx/tasks/record_fingerprint.yml
  roles/paperless_ngx/defaults/main.yml
  roles/paperless_ngx/meta/argument_specs.yml
  roles/paperless_ngx/templates/env.j2
  roles/host_prep/tasks/main.yml
  inventory/group_vars/all/service_paperless_ngx.yml
  generate-secrets.yml
  tests/mac/snapshot-paperless.sh
  tests/mac/snapshot-paperless.rb
  tests/fixtures/paperless-ocr.png.base64
  tests/integration.sh
  tests/integration_controller.sh
  tests/policy_support.rb
].freeze

# Deliberately absent: the wrapper and its programs. Carrying them would shadow
# #251; the wrapper layer plants an impostor there instead.

STATIC_ARGUMENT_VARIABLES = {
  "services/paperless-ngx/compose.yml" => "compose",
  "services/paperless-ngx/compose.mac.yml" => "mac_compose",
  "services/paperless-ngx/compose.integration.yml" => "integration_compose",
  "roles/paperless_ngx/tasks/main.yml" => "role",
  "roles/paperless_ngx/defaults/main.yml" => "defaults",
  "roles/paperless_ngx/meta/argument_specs.yml" => "argument_specs",
  "inventory/group_vars/all/service_paperless_ngx.yml" => "storage_inventory",
  "roles/host_prep/tasks/main.yml" => "host_prep",
  "generate-secrets.yml" => "generator",
  "roles/paperless_ngx/templates/env.j2" => "environment_template",
  "tests/mac/snapshot-paperless.sh" => "snapshot",
  "tests/mac/snapshot-paperless.rb" => "snapshot_program"
}.freeze
STATIC_ARGUMENTS = STATIC_ARGUMENT_VARIABLES.keys.freeze


# Asserts its own match count: some literals occur twice, and a missed sub plants nothing.
def substitute(text, from, to, count: 1)
  found = text.scan(from).length
  raise "#{from.inspect} matched #{found} times, expected #{count}" unless found == count

  count == 1 ? text.sub(from, to) : text.gsub(from, to)
end

# --- render layer ----------------------------------------------------------
# A Hash so a row can break one property of the merged document.

STATE_ROOT = "/volume1/Docker/paperless-ngx"
DOCUMENT_ROOT = "/volume2/Documents"

def rendered_config(variant)
  {
    "services" => {
      "webserver" => {
        "ports" => [{ "published" => variant == "mac" ? "38000" : "8000", "target" => 8000 }],
        "volumes" => [
          { "target" => "/usr/src/paperless/data", "source" => "#{STATE_ROOT}/data" },
          { "target" => "/usr/src/paperless/cache", "source" => "#{STATE_ROOT}/cache" },
          { "target" => "/usr/share/tesseract-ocr/5/tessdata/heb.traineddata",
            "source" => "#{STATE_ROOT}/tessdata/heb.traineddata", "read_only" => true },
          { "target" => "/usr/src/paperless/media", "source" => "#{DOCUMENT_ROOT}/archive" },
          { "target" => "/usr/src/paperless/consume", "source" => "#{DOCUMENT_ROOT}/inbox" },
          { "target" => "/usr/src/paperless/export", "source" => "#{DOCUMENT_ROOT}/export" }
        ]
      },
      "broker" => { "volumes" => [{ "target" => "/data", "source" => "#{STATE_ROOT}/redis" }] },
      "db" => {
        "volumes" => [
          { "target" => "/var/lib/postgresql/data", "source" => "#{STATE_ROOT}/postgres" }
        ]
      },
      "gotenberg" => {},
      "tika" => {}
    }
  }
end

def webserver_mount(config, target)
  config.fetch("services").fetch("webserver").fetch("volumes")
        .find { |mount| mount.fetch("target") == target }
end

RENDER_ROWS = [
  { name: "an intact NAS render", variant: "nas", break: ->(_config) {}, expects: nil },
  { name: "an intact Mac render", variant: "mac", break: ->(_config) {}, expects: nil },
  {
    name: "an intact integration render", variant: "integration",
    break: ->(_config) {}, expects: nil
  },
  {
    name: "a webserver that went back to host networking",
    variant: "nas",
    break: ->(config) { config.fetch("services").fetch("webserver")["network_mode"] = "host" },
    expects: "nas effective config must not use host networking"
  },
  {
    name: "the documented NAS port renumbered",
    variant: "nas",
    break: lambda { |config|
      config.fetch("services").fetch("webserver").fetch("ports").first["published"] = "8001"
    },
    expects: "nas effective webserver publication differs"
  },
  {
    # Compose appends `ports:` lists, so an override without !override also
    # publishes 8000; only the merged list shows it.
    name: "a Mac override that publishes its port without replacing the production one",
    variant: "mac",
    break: lambda { |config|
      config.fetch("services").fetch("webserver").fetch("ports")
            .unshift("published" => "8000", "target" => 8000)
    },
    expects: "mac effective webserver publication differs"
  },
  {
    name: "a dependency that publishes a host port",
    variant: "nas",
    break: lambda { |config|
      config.fetch("services").fetch("broker")["ports"] =
        [{ "published" => "6379", "target" => 6379 }]
    },
    expects: "nas broker publishes a host port"
  },
  {
    name: "a duplicated webserver mount target",
    variant: "nas",
    break: lambda { |config|
      volumes = config.fetch("services").fetch("webserver").fetch("volumes")
      volumes << volumes.first.dup
    },
    expects: "nas duplicate or missing webserver mount targets"
  },
  {
    name: "a document mount pointed somewhere else",
    variant: "nas",
    break: lambda { |config|
      webserver_mount(config, "/usr/src/paperless/media")["source"] = "#{DOCUMENT_ROOT}/elsewhere"
    },
    expects: "nas document mount /usr/src/paperless/media source differs"
  },
  {
    name: "a document mount made read-only",
    variant: "nas",
    break: lambda { |config|
      webserver_mount(config, "/usr/src/paperless/consume")["read_only"] = true
    },
    expects: "nas document mount /usr/src/paperless/consume is read-only"
  },
  # Unpinned: these refusals are unreachable behind the per-target literal
  # comparison above; they are defence in depth.
  {
    name: "a state source escaping its isolated root",
    variant: "nas",
    break: lambda { |config|
      config.fetch("services").fetch("db").fetch("volumes").first["source"] = "/volume1/Docker/postgres"
    },
    expects: "nas state source escapes its isolated root"
  },
  {
    name: "a state source renamed inside its isolated root",
    variant: "nas",
    break: lambda { |config|
      webserver_mount(config, "/usr/src/paperless/cache")["source"] = "#{STATE_ROOT}/caches"
    },
    expects: "nas effective state source list differs"
  }
].freeze

def render_failures(program = RENDER_PROGRAM, rows = RENDER_ROWS)
  in_parallel_case_results(rows) do |row|
    variant = row.fetch(:variant)
    config = rendered_config(variant)
    row.fetch(:break).call(config)
    stdout, stderr, status = Open3.capture3(
      { "PAPERLESS_RENDERED_COMPOSE" => JSON.generate(config) },
      *RENDER_COMMAND, program, variant
    )
    judge("render: #{row.fetch(:name)}", row.fetch(:expects), stdout, stderr, status,
          prefix: DIAGNOSTIC_PREFIX, expects_crash: row[:expects_crash])
  end
end

# --- static layer ----------------------------------------------------------

def build_fixture_repository(root)
  FIXTURE_FILES.each do |relative|
    destination = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(destination))
    FileUtils.cp(File.join(ROOT, relative), destination)
    # The wrapper refuses a non-executable snapshot (two files since #315).
    File.chmod(File.executable?(File.join(ROOT, relative)) ? 0o755 : 0o644, destination)
  end
end

def edit_yaml(root, relative, aliases: true)
  path = File.join(root, relative)
  document = YAML.safe_load_file(path, aliases: aliases)
  yield document
  File.write(path, YAML.dump(document))
end

def edit_text(root, relative, from, to, count: 1)
  path = File.join(root, relative)
  File.write(path, substitute(File.read(path), from, to, count: count))
end

ROLE_STAGES = FIXTURE_FILES.grep(%r{\Aroles/paperless_ngx/tasks/}).freeze

# Finds a task by name anywhere in the role, so a row survives stage splits.
def edit_role_task(root, name)
  ROLE_STAGES.each do |relative|
    path = File.join(root, relative)
    document = YAML.safe_load_file(path, aliases: false)
    next unless document.is_a?(Array)

    found = find_task(document, name)
    next unless found

    yield found
    File.write(path, YAML.dump(document))
    return relative
  end
  raise "fixture has no task named #{name.inspect} anywhere in the role"
end

def find_task(tasks, name)
  Array(tasks).each do |task|
    next unless task.is_a?(Hash)
    return task if task["name"] == name

    %w[block rescue always].each do |section|
      nested = find_task(task[section], name)
      return nested if nested
    end
  end
  nil
end

# One row per wrapper argument, each breaking only its file, plus two family rows.
STATIC_ROWS = [
  { name: "an intact repository", argument: nil, break: ->(_root) {}, expects: nil },
  {
    name: "the documented NAS port renumbered in the stack definition",
    argument: "services/paperless-ngx/compose.yml",
    break: lambda { |root|
      edit_yaml(root, "services/paperless-ngx/compose.yml") do |document|
        document.fetch("services").fetch("webserver")["ports"] = ["8001:8000"]
      end
    },
    expects: "NAS webserver must publish its documented port"
  },
  {
    name: "a Mac override that stopped covering every service",
    argument: "services/paperless-ngx/compose.mac.yml",
    break: lambda { |root|
      edit_text(root, "services/paperless-ngx/compose.mac.yml", "\n  tika:\n", "\n  tika_disabled:\n")
    },
    expects: "Mac override must provide all services"
  },
  {
    name: "an integration override that stopped covering every service",
    argument: "services/paperless-ngx/compose.integration.yml",
    break: lambda { |root|
      edit_text(root, "services/paperless-ngx/compose.integration.yml",
                "\n  tika:\n", "\n  tika_disabled:\n")
    },
    expects: "integration override must provide all services"
  },
  {
    name: "a required role task renamed",
    argument: "roles/paperless_ngx/tasks/main.yml",
    break: lambda { |root|
      edit_role_task(root, "Refuse a rotated Paperless database credential") do |task|
        task["name"] = "Refuse a rotated Paperless database credential, eventually"
      end
    },
    expects: "missing Refuse a rotated Paperless database credential"
  },
  {
    name: "the Gmail IMAP settings changed",
    argument: "roles/paperless_ngx/defaults/main.yml",
    break: lambda { |root|
      edit_yaml(root, "roles/paperless_ngx/defaults/main.yml", aliases: false) do |document|
        document.fetch("paperless_mail_account")["imap_server"] = "imap.example.invalid"
      end
    },
    expects: "Gmail IMAP settings differ"
  },
  {
    name: "the managed mail rule made destructive",
    argument: "roles/paperless_ngx/defaults/main.yml",
    break: lambda { |root|
      edit_yaml(root, "roles/paperless_ngx/defaults/main.yml", aliases: false) do |document|
        document.fetch("paperless_mail_rule")["action"] = 1
      end
    },
    expects: "managed mail rule must be enabled and non-destructive"
  },
  {
    name: "a state path argument that accepts any value",
    argument: "roles/paperless_ngx/meta/argument_specs.yml",
    break: lambda { |root|
      edit_yaml(root, "roles/paperless_ngx/meta/argument_specs.yml") do |document|
        document.dig("argument_specs", "main", "options", "paperless_state_host_path")
                .delete("choices")
      end
    },
    expects: "paperless_state_host_path argument validation differs"
  },
  {
    name: "a central storage directory declared with the wrong recovery class",
    argument: "inventory/group_vars/all/service_paperless_ngx.yml",
    break: lambda { |root|
      edit_yaml(root, "inventory/group_vars/all/service_paperless_ngx.yml") do |document|
        entry = document.fetch("nas_storage_paperless_ngx").find do |candidate|
          candidate["path"] == "{{ nas_docker_root }}/paperless-ngx/data"
        end
        entry["recovery"] = "cache"
      end
    },
    expects: "central storage declaration differs for {{ nas_docker_root }}/paperless-ngx/data"
  },
  {
    name: "central storage targets no longer validated before mkdir",
    argument: "roles/host_prep/tasks/main.yml",
    break: lambda { |root|
      edit_text(root, "roles/host_prep/tasks/main.yml",
                "Validate central storage targets before directory creation",
                "Validate central storage targets, at some point")
    },
    expects: "central storage targets are not validated before mkdir"
  },
  {
    name: "a generator whose Gmail sentinel stopped being the documented one",
    argument: "generate-secrets.yml",
    break: lambda { |root|
      edit_text(root, "generate-secrets.yml",
                "paperless_gmail_app_password: replace-with-google-app-password",
                "paperless_gmail_app_password: put-a-google-app-password-here")
    },
    expects: "Gmail app password must be a visible sentinel in the new-platform generator"
  },
  # Unpinned: unreachable behind the sentinel equality check.
  {
    name: "a secret-bearing environment assignment left open to Compose interpolation",
    argument: "roles/paperless_ngx/templates/env.j2",
    break: lambda { |root|
      edit_text(root, "roles/paperless_ngx/templates/env.j2",
                "PAPERLESS_SECRET_KEY={{ vault_paperless_django_secret_key | replace('$', '$$') }}",
                "PAPERLESS_SECRET_KEY={{ vault_paperless_django_secret_key }}")
    },
    expects: "vault_paperless_django_secret_key is not protected from Compose interpolation"
  },
  {
    name: "a dependency endpoint that stopped naming its Compose service",
    argument: "roles/paperless_ngx/templates/env.j2",
    break: lambda { |root|
      edit_text(root, "roles/paperless_ngx/templates/env.j2",
                "PAPERLESS_DBHOST=db", "PAPERLESS_DBHOST=127.0.0.1")
    },
    expects: "PAPERLESS_DBHOST must address its Compose service by name on every platform"
  },
  {
    name: "a snapshot recovery deadline shortened below its default",
    argument: "tests/mac/snapshot-paperless.sh",
    break: lambda { |root|
      edit_text(root, "tests/mac/snapshot-paperless.sh",
                ': "${PLATFORM_PAPERLESS_RECOVERY_DEADLINE:=60}"',
                ': "${PLATFORM_PAPERLESS_RECOVERY_DEADLINE:=30}"')
    },
    expects: "Paperless recovery deadline default differs"
  },
  # The wrapper/program split pair (#315): one plants in the shell, one in Ruby.
  {
    name: "a one-shot flushall that races the valkey socket again",
    argument: "tests/mac/snapshot-paperless.rb",
    break: lambda { |root|
      edit_text(root, "tests/mac/snapshot-paperless.rb",
                '[["docker", "exec", REDIS, "valkey-cli", "flushall"], :until_ready]',
                '[["docker", "exec", REDIS, "valkey-cli", "flushall"], :once]')
    },
    expects: "Paperless recovery must wait for valkey rather than one-shot the flushall"
  },
  {
    name: "a drill poll that logs in on every pass again",
    argument: "tests/mac/snapshot-paperless.rb",
    break: lambda { |root|
      edit_text(root, "tests/mac/snapshot-paperless.rb",
                "break if catalogue(drill_token).empty?",
                "break if catalogue(authenticate(admin_username, admin_password)).empty?")
    },
    expects: "Paperless drill poll must reuse the drill token rather than log in again"
  },
  {
    name: "a secret-bearing role task that stopped being redacted",
    argument: nil,
    break: lambda { |root|
      edit_role_task(root, "Create the managed Paperless mail account") do |task|
        task["no_log"] = false
      end
    },
    expects: "secret-bearing task Create the managed Paperless mail account is not redacted"
  }
].freeze

def static_failures(program = STATIC_PROGRAM, rows = STATIC_ROWS)
  in_parallel_case_results(rows) do |row|
    Dir.mktmpdir("nas-platform-paperless-static.") do |raw|
      root = File.realpath(raw)
      build_fixture_repository(root)
      row.fetch(:break).call(root)
      arguments = STATIC_ARGUMENTS.map { |relative| File.join(root, relative) }
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => root }, *STATIC_COMMAND, program, *arguments
      )
      judge("static: #{row.fetch(:name)}", row.fetch(:expects), stdout, stderr, status,
            prefix: DIAGNOSTIC_PREFIX, expects_crash: row[:expects_crash])
    end
  end
end

# --- runtime layer ---------------------------------------------------------

CONSUME_FIXTURES = %w[task-13-contract.pdf task-13-contract.png task-13-contract.docx].freeze

RUNTIME_ROWS = [
  {
    name: "the document fixture pre-seed on an empty inbox",
    mode: "seed-fixture-only", break: ->(_root, _media) {}, expects: nil,
    reports: "Paperless document fixtures prepared before deployment",
    # Masked by the umask, as the environment will.
    fixture_mode: 0o644 & ~File.umask
  },
  {
    name: "the pre-seed run a second time over its own output",
    mode: "seed-fixture-only", repeat: true, break: ->(_root, _media) {}, expects: nil,
    reports: "Paperless document fixtures prepared before deployment"
  },
  {
    name: "a document fixture whose bytes drifted",
    mode: "seed-fixture-only",
    break: lambda { |_root, media|
      path = File.join(media, "Documents", "inbox", "task-13-contract.pdf")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "not the contract's own bytes")
    },
    expects: "fixture bytes drifted: task-13-contract.pdf"
  },
  {
    name: "a document fixture replaced by a directory",
    mode: "seed-fixture-only",
    break: lambda { |_root, media|
      FileUtils.mkdir_p(File.join(media, "Documents", "inbox", "task-13-contract.docx"))
    },
    expects: "fixture bytes drifted: task-13-contract.docx"
  },
  {
    name: "the OCR fixture absent from the inspected tree",
    mode: "seed-fixture-only",
    break: ->(root, _media) { FileUtils.rm_f(File.join(root, "tests/fixtures/paperless-ocr.png.base64")) },
    expects_crash: "paperless-ocr.png.base64"
  },
  {
    name: "a service port that is not a number",
    mode: "seed-fixture-only", port: "eight-thousand",
    break: ->(_root, _media) {},
    expects_crash: "eight-thousand"
  }
].freeze

def runtime_failures(program = RUNTIME_PROGRAM, rows = RUNTIME_ROWS)
  in_parallel_case_results(rows) do |row|
    Dir.mktmpdir("nas-platform-paperless-runtime.") do |raw|
      root = File.realpath(raw)
      build_fixture_repository(root)
      media = File.join(root, "media")
      reports = File.join(root, "reports")
      FileUtils.mkdir_p([File.join(media, "Documents", "inbox"), reports])
      row.fetch(:break).call(root, media)
      environment = {
        "PLATFORM_CONTRACT_REPO_DIR" => root,
        "PLATFORM_MEDIA_ROOT" => media,
        "PLATFORM_REPORT_ROOT" => reports,
        "PLATFORM_PAPERLESS_PORT" => row.fetch(:port, "38000"),
        "PLATFORM_PAPERLESS_WEBSERVER_CONTAINER" => "paperless-contract-webserver"
      }
      command = [RbConfig.ruby, program, row.fetch(:mode)]
      Open3.capture3(environment, *command) if row[:repeat]
      stdout, stderr, status = Open3.capture3(environment, *command)
      label = "runtime: #{row.fetch(:name)}"
      failures = judge(label, row.fetch(:expects, nil), stdout, stderr, status,
                       prefix: DIAGNOSTIC_PREFIX, expects_crash: row[:expects_crash])
      next failures unless failures.empty?

      if row[:reports] && !stdout.include?(row.fetch(:reports))
        failures << "#{label}: did not report #{row.fetch(:reports).inspect}, " \
                    "got #{stdout.strip.inspect}"
      end
      if row[:fixture_mode]
        inbox = File.join(media, "Documents", "inbox")
        CONSUME_FIXTURES.each do |name|
          path = File.join(inbox, name)
          unless File.file?(path) && File.size?(path)
            failures << "#{label}: #{name} was not written"
            next
          end
          mode = File.stat(path).mode & 0o777
          failures << "#{label}: #{name} is mode #{format('%04o', mode)}, wanted " \
                      "#{format('%04o', row.fetch(:fixture_mode))}" unless
            mode == row.fetch(:fixture_mode)
        end
      end
      failures
    end
  end
end

# --- wrapper layer ---------------------------------------------------------
# The wrapper resolves programs from its own checkout, so a copy is a working
# contract; a `docker` stub answers with the canned render.

DOCKER_STUB = <<~STUB
  #!/bin/sh
  # Answers `docker compose ... --project-name paperless-contract-<variant> ... config`
  # with the canned render for that variant, and nothing else.
  variant=nas
  for argument in "$@"; do
    case $argument in
      paperless-contract-*) variant=${argument#paperless-contract-} ;;
    esac
  done
  cat "$PAPERLESS_STUB_RENDERS/$variant.json"
STUB

def with_contract_copy(render: File.read(RENDER_PROGRAM), static: File.read(STATIC_PROGRAM),
                       runtime: File.read(RUNTIME_PROGRAM), wrapper: File.read(CONTRACT))
  programs = { "render" => render, "static" => static, "runtime" => runtime }
  with_contract_sandbox("paperless", wrapper, programs) do |contract, root|
    renders = File.join(root, "renders")
    FileUtils.mkdir_p(renders)
    %w[nas mac integration].each do |variant|
      File.write(File.join(renders, "#{variant}.json"), JSON.generate(rendered_config(variant)))
    end
    stub_dir = File.join(root, "stub-bin")
    FileUtils.mkdir_p(stub_dir)
    File.write(File.join(stub_dir, "docker"), DOCKER_STUB)
    File.chmod(0o755, File.join(stub_dir, "docker"))
    yield contract, root, {
      "PATH" => "#{stub_dir}:#{ENV.fetch('PATH')}",
      "PAPERLESS_STUB_RENDERS" => renders
    }
  end
end

def broken_fixture_repository
  Dir.mktmpdir("nas-platform-paperless-broken.") do |raw|
    root = File.realpath(raw)
    build_fixture_repository(root)
    edit_yaml(root, "roles/paperless_ngx/defaults/main.yml", aliases: false) do |document|
      document.fetch("paperless_mail_account")["imap_server"] = "imap.example.invalid"
    end
    yield root
  end
end

def runtime_sandbox(root)
  media = File.join(root, "media")
  reports = File.join(root, "reports")
  FileUtils.mkdir_p([File.join(media, "Documents", "inbox"), reports])
  {
    "PLATFORM_MEDIA_ROOT" => media, "PLATFORM_REPORT_ROOT" => reports,
    "PLATFORM_PAPERLESS_PORT" => "38000",
    "PLATFORM_PAPERLESS_WEBSERVER_CONTAINER" => "paperless-contract-webserver",
    "PLATFORM_CONTRACT_VAULT_FILE" => File.join(reports, "absent-vault.yml"),
    "PLATFORM_CONTRACT_VAULT_PASSWORD_FILE" => File.join(reports, "absent-password")
  }
end

# The literals the wrapper greps out of the runtime program; vacuous while they
# shared a file (a grep matched its own pattern), so pinned both ways.
SELF_READ_ROWS = [
  {
    name: "the document indexing timeout",
    from: "DOCUMENT_INDEX_TIMEOUT_SECONDS = 600", to: "DOCUMENT_INDEX_TIMEOUT_SECONDS = 601",
    expects: "document indexing timeout differs"
  },
  {
    name: "the Gmail probe timeout constant",
    from: "MAIL_PROBE_READ_TIMEOUT = 180", to: "MAIL_PROBE_READ_TIMEOUT = 181",
    expects: "runtime Gmail probe timeout constant differs"
  },
  {
    # The call site, not the def's signature (#285).
    name: "the Gmail probe's use of that constant",
    from: "read_timeout: MAIL_PROBE_READ_TIMEOUT", to: "read_timeout: 180",
    expects: "runtime Gmail probe lacks its explicit bounded timeout"
  }
].freeze

def wrapper_failures(wrapper_source: File.read(CONTRACT))
  failures = []

  # Both directions, so STATIC_ARGUMENTS cannot drift from the wrapper.
  STATIC_ARGUMENT_VARIABLES.each do |relative, variable|
    failures << "wrapper: does not bind #{variable} to #{relative} in the inspected tree" unless
      wrapper_source.include?("#{variable}=$repo_dir/#{relative}")
  end
  static_invocation = wrapper_source[/^ruby -ryaml "\$static_program".*?\n\n/m].to_s
  passed = static_invocation.scan(/\$\{?(\w+)/).flatten - ["static_program"]
  failures << "wrapper: the static invocation passes #{passed.inspect}, not " \
              "#{STATIC_ARGUMENT_VARIABLES.values.inspect}" unless
    passed == STATIC_ARGUMENT_VARIABLES.values

  with_contract_copy(wrapper: wrapper_source) do |contract, copy_root, stub_env|
    stdout, stderr, status = Open3.capture3(stub_env, contract, "static")
    unless status.success? && stdout.include?("Paperless static contract passed")
      failures << "wrapper: static mode failed against its own checkout: #{(stdout + stderr).strip}"
    end

    broken_fixture_repository do |broken|
      stdout, stderr, status = Open3.capture3(
        stub_env.merge("PLATFORM_CONTRACT_REPO_DIR" => broken), contract, "static"
      )
      output = stdout + stderr
      if status.success?
        failures << "wrapper: static mode accepted a broken inspected tree"
      elsif !output.include?("Paperless contract failed: Gmail IMAP settings differ")
        failures << "wrapper: static mode did not report the broken inspected tree: " \
                    "#{output.strip.inspect}"
      end
    end

    # An impostor at the sibling paths must never run; absence cannot decide this.
    Dir.mktmpdir("nas-platform-paperless-impostor.") do |raw|
      impostor_root = File.realpath(raw)
      build_fixture_repository(impostor_root)
      contracts = File.join(impostor_root, "tests", "contracts")
      FileUtils.mkdir_p(contracts)
      %w[render static runtime].each do |half|
        File.write(File.join(contracts, "paperless-#{half}.rb"),
                   %(warn "impostor #{half} program ran"\nexit 0\n))
      end
      File.write(File.join(contracts, "paperless.sh"), "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, File.join(contracts, "paperless.sh"))
      stdout, stderr, status = Open3.capture3(
        stub_env.merge("PLATFORM_CONTRACT_REPO_DIR" => impostor_root), contract, "static"
      )
      output = stdout + stderr
      failures << "wrapper: a program planted in the inspected tree ran: #{output.strip.inspect}" if
        output.include?("impostor")
      failures << "wrapper: static mode failed with an impostor beside the inspected tree: " \
                  "#{output.strip.inspect}" unless status.success?
    end

    # PLATFORM_CONTRACT_REPO_DIR stays bound to the inspected tree.
    Dir.mktmpdir("nas-platform-paperless-nosupport.") do |raw|
      stripped = File.realpath(raw)
      build_fixture_repository(stripped)
      FileUtils.rm_f(File.join(stripped, "tests/policy_support.rb"))
      stdout, stderr, status = Open3.capture3(
        stub_env.merge("PLATFORM_CONTRACT_REPO_DIR" => stripped), contract, "static"
      )
      output = stdout + stderr
      if status.success?
        failures << "wrapper: the static program did not read policy_support from the inspected tree"
      elsif !output.include?("policy_support")
        failures << "wrapper: a missing policy_support in the inspected tree was not named: " \
                    "#{output.strip.inspect}"
      end
    end

    sandbox = runtime_sandbox(copy_root)
    stdout, stderr, status = Open3.capture3(
      stub_env.merge(sandbox), contract, "seed-fixture-only"
    )
    unless status.success? &&
           stdout.include?("Paperless document fixtures prepared before deployment")
      failures << "wrapper: seed-fixture-only did not reach the runtime program: " \
                  "#{(stdout + stderr).strip}"
    end

    # Only the portable prefix of the shell's `:?` message is asserted. Set to ""
    # rather than removed, so an exported variable cannot make the row pass.
    %w[PLATFORM_MEDIA_ROOT PLATFORM_REPORT_ROOT].each do |name|
      stdout, stderr, status = Open3.capture3(
        stub_env.merge(sandbox).merge(name => ""), contract, "run"
      )
      output = stdout + stderr
      failures << "wrapper: #{name} unset was accepted" if status.success?
      failures << "wrapper: #{name} unset was refused without naming it: #{output.strip.inspect}" unless
        output.include?("#{name}: parameter")
      %w[Paperless\ documents Paperless\ contract\ failed:\ encrypted\ vault].each do |sentence|
        failures << "wrapper: the runtime program started with #{name} unset" if
          output.include?(sentence)
      end
    end
  end

  # Each literal must have exactly one site, and the grep must name the program, not "$0".
  SELF_READ_ROWS.each do |row|
    occurrences = File.read(RUNTIME_PROGRAM).scan(row.fetch(:from)).length
    failures << "wrapper: #{row.fetch(:name)} occurs #{occurrences} times in the runtime " \
                "program, so the grep for it cannot name one site" unless occurrences == 1
    failures << "wrapper: #{row.fetch(:name)} is not grepped out of the runtime program" unless
      wrapper_source.match?(/grep [^\n]*#{Regexp.escape(row.fetch(:from))}[^\n]*"\$runtime_program"/)
  end
  SELF_READ_ROWS.each do |row|
    mutant = substitute(File.read(RUNTIME_PROGRAM), row.fetch(:from), row.fetch(:to))
    with_contract_copy(runtime: mutant, wrapper: wrapper_source) do |contract, _root, stub_env|
      stdout, stderr, status = Open3.capture3(stub_env, contract, "static")
      output = stdout + stderr
      label = "wrapper: #{row.fetch(:name)}"
      if status.success?
        failures << "#{label}: a changed runtime constant was accepted"
      elsif !output.include?("Paperless contract failed: #{row.fetch(:expects)}")
        failures << "#{label}: refused for the wrong reason: #{output.strip.lines.first.to_s.strip.inspect}"
      end
    end
  end

  failures
end

# --- stdin -----------------------------------------------------------------
# No program reads stdin, so each row swaps in a probe that does.

PROBE = <<~'PROBE'
  payload = $stdin.read
  abort "Paperless contract failed: %<half>s program was handed #{payload.bytesize} B on stdin" unless
    payload.empty?
PROBE

def probe_program(half, tail)
  format(PROBE, half: half) + tail
end

def stdin_failures(wrapper_source: File.read(CONTRACT))
  failures = []
  # Probes keep the real program's bytes; the runtime one must still carry the
  # three grepped constants (#285).
  render = probe_program("render", File.read(RENDER_PROGRAM))
  static = probe_program("static", File.read(STATIC_PROGRAM))
  runtime = probe_program(
    "runtime", %(puts "runtime probe reached with an empty stdin"\nexit 0\n) +
               File.read(RUNTIME_PROGRAM)
  )
  with_contract_copy(render: render, static: static, runtime: runtime,
                     wrapper: wrapper_source) do |contract, copy_root, stub_env|
    stdout, stderr, status, survived = run_with_caller_stdin(stub_env, contract, %w[static])
    output = stdout + stderr
    unless status.success?
      failures << "stdin: a program was handed the caller's input: #{output.strip.inspect}"
    end
    failures << "stdin: the caller's input did not survive the contract: #{output.strip.inspect}" unless survived
    sandbox = runtime_sandbox(copy_root)
    stdout, stderr, status, survived = run_with_caller_stdin(stub_env.merge(sandbox), contract, %w[run])
    output = stdout + stderr
    unless status.success? && stdout.include?("runtime probe reached with an empty stdin")
      failures << "stdin: the runtime program was handed the caller's input: #{output.strip.inspect}"
    end
    failures << "stdin: the caller's input did not survive the contract: #{output.strip.inspect}" unless survived
  end
  failures
end

# --- planted regressions ---------------------------------------------------
# Each entry removes one guard and names the rows that must catch it.

PROGRAM_MUTATIONS = [
  {
    label: "the host networking check",
    program: :render,
    from: 'if\n  webserver_networking.key?("network_mode")',
    to: "if\n  false",
    rows: ["a webserver that went back to host networking"]
  },
  {
    label: "the effective publication check",
    program: :render,
    from: "webserver_networking.fetch(\"ports\").map { |port| port.fetch(\"published\").to_s } == expected_published",
    to: "true",
    rows: ["the documented NAS port renumbered",
           "a Mac override that publishes its port without replacing the production one"]
  },
  {
    label: "the dependency host-port check",
    program: :render,
    from: 'Array(services.fetch(name)["ports"]).empty?',
    to: "true",
    rows: ["a dependency that publishes a host port"]
  },
  {
    label: "the duplicate mount target check",
    program: :render,
    from: "by_target.keys.sort == expected_targets.sort && by_target.values.all? { |entries| entries.length == 1 }",
    to: "by_target.keys.sort == expected_targets.sort",
    rows: ["a duplicated webserver mount target"]
  },
  {
    label: "the document mount source check",
    program: :render,
    from: "source == expected_source",
    to: "true",
    rows: ["a document mount pointed somewhere else"]
  },
  {
    label: "the read-only document mount check",
    program: :render,
    from: 'mount["read_only"] == true',
    to: "false",
    rows: ["a document mount made read-only"]
  },
  {
    label: "the isolated state root check",
    program: :render,
    from: "source.start_with?(expected_state_root + File::SEPARATOR)",
    to: "true",
    rows: ["a state source escaping its isolated root"],
    # Recorded cascade: the list comparison below refuses instead, with a different sentence.
    detects: "refused for the wrong reason"
  },
  {
    label: "the effective state source list check",
    program: :render,
    from: "state_sources.sort == expected_state_sources.sort",
    to: "true",
    rows: ["a state source renamed inside its isolated root"]
  },
  {
    label: "the documented NAS port check",
    program: :static,
    from: 'web.fetch("ports") == ["8000:8000"]',
    to: "true",
    rows: ["the documented NAS port renumbered in the stack definition"]
  },
  {
    label: "the Mac override coverage check",
    program: :static,
    from: "override_services.keys.sort == services.keys.sort",
    to: "true",
    rows: ["a Mac override that stopped covering every service"],
    # Recorded cascade: without this check the fetches below raise KeyError.
    detects: "key not found"
  },
  {
    label: "the integration override coverage check",
    program: :static,
    from: "integration_services.keys.sort == services.keys.sort",
    to: "true",
    rows: ["an integration override that stopped covering every service"]
  },
  {
    label: "the required role task sweep",
    program: :static,
    from: "required_tasks.each { |name| refuse(\"missing \#{name}\") unless role_task_names.include?(name) }",
    to: "required_tasks.each { |name| name }",
    rows: ["a required role task renamed"]
  },
  {
    label: "the Gmail IMAP settings check",
    program: :static,
    from: 'refuse("Gmail IMAP settings differ") unless account == {',
    to: 'refuse("Gmail IMAP settings differ") unless true || account == {',
    rows: ["the Gmail IMAP settings changed"]
  },
  {
    label: "the managed mail rule check",
    program: :static,
    from: 'rule.fetch("enabled") == true && rule.fetch("folder") == "INBOX" &&',
    to: "true ||",
    rows: ["the managed mail rule made destructive"]
  },
  {
    label: "the state path argument validation check",
    program: :static,
    from: 'argument_options.dig(name, "type") == "str" &&',
    to: "true ||",
    rows: ["a state path argument that accepts any value"]
  },
  {
    label: "the central storage declaration check",
    program: :static,
    from: 'matches.length == 1 && matches.first["mode"] == "0755" &&',
    to: "true ||",
    rows: ["a central storage directory declared with the wrong recovery class"]
  },
  {
    label: "the mkdir ordering check",
    program: :static,
    from: "storage_validation_index && storage_creation_index && storage_validation_index < storage_creation_index &&",
    to: "true ||",
    rows: ["central storage targets no longer validated before mkdir"]
  },
  {
    label: "the generator sentinel check",
    program: :static,
    from: 'generator_vars["paperless_gmail_app_password"] == "replace-with-google-app-password"',
    to: "true",
    rows: ["a generator whose Gmail sentinel stopped being the documented one"]
  },
  {
    label: "the Compose interpolation protection check",
    program: :static,
    from: "environment_assignments.select { |assignment, _| assignment == name } ==\n      [[name, \"{{ \#{variable} | replace('$', '$$') }}\"]]",
    to: "true",
    rows: ["a secret-bearing environment assignment left open to Compose interpolation"]
  },
  {
    label: "the dependency endpoint naming check",
    program: :static,
    from: "environment_assignments.select { |assignment, _| assignment == name } == [[name, value]]",
    to: "true",
    rows: ["a dependency endpoint that stopped naming its Compose service"]
  },
  {
    label: "the snapshot recovery deadline default check",
    program: :static,
    from: %(snapshot_text.include?(': "${PLATFORM_PAPERLESS_RECOVERY_DEADLINE:=60}"')),
    to: "true",
    rows: ["a snapshot recovery deadline shortened below its default"]
  },
  {
    label: "the secret-bearing task redaction sweep",
    program: :static,
    from: 'refuse("secret-bearing task #{task[\'name\']} is not redacted") unless task["no_log"] == true',
    to: 'task["no_log"]',
    rows: ["a secret-bearing role task that stopped being redacted"]
  },
  {
    label: "the fixture drift check",
    program: :runtime,
    from: "fail_contract(\"fixture bytes drifted: \#{path.basename}\") unless path.file? && path.binread == bytes",
    to: "path.file?",
    rows: ["a document fixture whose bytes drifted", "a document fixture replaced by a directory"],
    detects: "accepted what it must refuse"
  },
  {
    label: "the exclusive fixture creation mode",
    program: :runtime,
    from: "path.open(File::WRONLY | File::CREAT | File::EXCL, 0o644)",
    # 0o755 because 0o666 masks to 0o644 under umask 022.
    to: "path.open(File::WRONLY | File::CREAT | File::EXCL, 0o755)",
    rows: ["the document fixture pre-seed on an empty inbox"],
    detects: "is mode"
  }
].freeze

def canonical_program(kind)
  { render: RENDER_PROGRAM, static: STATIC_PROGRAM, runtime: RUNTIME_PROGRAM }.fetch(kind)
end

def with_mutant(mutation)
  canonical = canonical_program(mutation.fetch(:program))
  source = substitute(File.read(canonical), mutation.fetch(:from), mutation.fetch(:to),
                      count: mutation.fetch(:count, 1))
  Dir.mktmpdir("nas-platform-paperless-mutant.") do |directory|
    path = File.join(directory, File.basename(canonical))
    File.write(path, source)
    yield path
  end
end

# The SVG is the legible source of paperless-ocr.png.base64 (#657). The strings
# are read out of the runtime program, so this asserts the shipped image still
# says what the OCR rows claim.
OCR_SOURCE = File.join(ROOT, "tests", "fixtures", "paperless-ocr.svg")
# Stated, so an extraction that finds nothing fails loudly.
OCR_REQUIRED_STRINGS = 3

# Explicit encoding: default_external may be US-ASCII on a runner.
def ocr_fixture_failures(runtime_source: File.read(RUNTIME_PROGRAM, encoding: "UTF-8"))
  return ["ocr fixture: #{OCR_SOURCE} is absent, so nothing in the tree records what " \
          "tests/fixtures/paperless-ocr.png.base64 says"] unless File.exist?(OCR_SOURCE)

  required = runtime_source.scan(
    /image_document\.fetch\("content", ""\)(?:\.downcase)?\.include\?\("([^"]+)"\)/
  ).flatten
  marker = runtime_source[/^IMAGE_MARKER\s*=\s*"([^"]+)"/, 1]
  required << marker if marker
  unless required.length == OCR_REQUIRED_STRINGS
    return ["ocr fixture: read #{required.length} required strings out of " \
            "tests/contracts/paperless-runtime.rb, wanted #{OCR_REQUIRED_STRINGS}: the " \
            "assertions moved and this check is now proving nothing"]
  end

  # Comments stripped so a header quoting a string cannot satisfy the row.
  rendered = File.read(OCR_SOURCE, encoding: "UTF-8").gsub(/<!--.*?-->/m, "").downcase
  required.reject { |string| rendered.include?(string.downcase) }.map do |missing|
    "ocr fixture: the runtime requires #{missing.inspect} in the OCR text, and the source " \
      "tests/fixtures/paperless-ocr.svg the image was rendered from does not contain it"
  end
end

if ARGV.include?("--self-test")
  in_parallel_case_results(PROGRAM_MUTATIONS) do |mutation|
    with_mutant(mutation) do |mutant|
      caught = case mutation.fetch(:program)
               when :render then render_failures(mutant, rows_named(RENDER_ROWS, mutation.fetch(:rows)))
               when :static then static_failures(mutant, rows_named(STATIC_ROWS, mutation.fetch(:rows)))
               else runtime_failures(mutant, rows_named(RUNTIME_ROWS, mutation.fetch(:rows)))
               end
      abort "self-test failed: removing #{mutation.fetch(:label)} was accepted" if caught.empty?
      detects = mutation.fetch(:detects, "accepted what it must refuse")
      unless caught.all? { |failure| failure.include?(detects) }
        abort "self-test failed: removing #{mutation.fetch(:label)} was caught by the wrong " \
              "assertion: #{caught.join(' | ')}"
      end
    end
    []
  end

  planted_redirects = 0
  [
    ["\"$render_program\" \"$variant\" </dev/null\n", "\"$render_program\" \"$variant\"\n"],
    ["\"$generator\" \"$environment_template\" \"$snapshot\" \"$snapshot_program\" </dev/null\n",
     "\"$generator\" \"$environment_template\" \"$snapshot\" \"$snapshot_program\"\n"],
    ["exec ruby \"$runtime_program\" \"$mode\" \"$@\" </dev/null\n",
     "exec ruby \"$runtime_program\" \"$mode\" \"$@\"\n"],
    ["exec ruby \"$runtime_program\" \"$mode\" \"$@\" </dev/null\n",
     "cat >/dev/null\nexec ruby \"$runtime_program\" \"$mode\" \"$@\" </dev/null\n"]
  ].each do |from, to|
    unredirected = substitute(File.read(CONTRACT), from, to)
    leaked = stdin_failures(wrapper_source: unredirected)
    abort "self-test failed: a dropped stdin redirect was accepted: #{from.strip.inspect}" if
      leaked.empty?
    planted_redirects += 1
  end

  # #251, at every paperless site, both directions.
  planted_roots = 0
  [
    ['render_program=$contract_repo_dir/tests/contracts/paperless-render.rb',
     'render_program=$repo_dir/tests/contracts/paperless-render.rb'],
    ['static_program=$contract_repo_dir/tests/contracts/paperless-static.rb',
     'static_program=$repo_dir/tests/contracts/paperless-static.rb'],
    ['runtime_program=$contract_repo_dir/tests/contracts/paperless-runtime.rb',
     'runtime_program=$repo_dir/tests/contracts/paperless-runtime.rb'],
    ["PLATFORM_CONTRACT_REPO_DIR=$repo_dir\nexport PLATFORM_CONTRACT_REPO_DIR\n",
     "PLATFORM_CONTRACT_REPO_DIR=$contract_repo_dir\nexport PLATFORM_CONTRACT_REPO_DIR\n"],
    ["defaults=$repo_dir/roles/paperless_ngx/defaults/main.yml\n",
     "defaults=$contract_repo_dir/roles/paperless_ngx/defaults/main.yml\n"]
  ].each do |from, to|
    misrooted = substitute(File.read(CONTRACT), from, to)
    caught = wrapper_failures(wrapper_source: misrooted)
    abort "self-test failed: #{from.strip.inspect} rerooted to the wrong tree was accepted" if
      caught.empty?
    planted_roots += 1
  end

  planted_fixtures = 0
  runtime_text = File.read(RUNTIME_PROGRAM, encoding: "UTF-8")
  # The German and Hebrew anchors are %{}: '\u' in single quotes is literal.
  [
    [%{image_document.fetch("content", "").include?("\u05E2\u05D1\u05E8\u05D9\u05EA")},
     %{image_document.fetch("content", "").include?("\u05E9\u05DC\u05D5\u05DD")}, 1],
    [%{.downcase.include?("\u00FCberpr\u00FCfung")}, %{.downcase.include?("kontrolle")}, 1],
    ['IMAGE_MARKER = "paperless contract image ocr"',
     'IMAGE_MARKER = "paperless contract scanned page"', 1],
    ['image_document.fetch("content", "")', 'image_document.fetch("contents", "")', 2]
  ].each do |from, to, occurrences|
    broken = substitute(runtime_text, from, to, count: occurrences)
    abort "self-test failed: #{from.inspect} mutated to #{to.inspect} was accepted" if
      ocr_fixture_failures(runtime_source: broken).empty?
    planted_fixtures += 1
  end

  puts "paperless contract: self-test detects " \
       "#{PROGRAM_MUTATIONS.length + planted_redirects + planted_roots + planted_fixtures} " \
       "planted regressions"
  exit
end

failures = render_failures + static_failures + runtime_failures + wrapper_failures +
           stdin_failures + ocr_fixture_failures
unless failures.empty?
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} Paperless contract violation(s)"
end

puts "paperless contract: #{RENDER_ROWS.length} render, #{STATIC_ROWS.length} static and " \
     "#{RUNTIME_ROWS.length} runtime properties hold, the OCR image still says the " \
     "#{OCR_REQUIRED_STRINGS} things the runtime requires of it, and the wrapper reaches all " \
     "three programs with an empty stdin"
