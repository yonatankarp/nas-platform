#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Behaviour of the Paperless service contract's three Ruby programs.
#
# Until #147 all three lived in `<<'RUBY'` heredocs inside
# tests/contracts/paperless.sh -- 1,000 of that file's 1,132 lines. `sh -n` reads
# a quoted heredoc as opaque text, so nothing but an integration lane with
# Docker, a converged Paperless stack and a real vault ever executed any of them.
# tests/contracts/paperless-render.rb, tests/contracts/paperless-static.rb and
# tests/contracts/paperless-runtime.rb are files now, so all three are reachable
# here.
#
# Four layers, because the contract has four kinds of property:
#
#   Render -- the properties that can only be decided on the config Compose
#   actually merges. The wrapper renders each of the three variants with `docker
#   compose config` and hands the JSON over in one environment variable, so the
#   program itself fixtures completely: no Docker, no compose files, one canned
#   render per row. That is the whole point of the split -- the assertion is
#   about a merged document, not about an override's source text.
#
#   Static -- build a fixture repository out of the files the contract reads,
#   break exactly one thing in it, and require the program to name that thing.
#   The rows are chosen so that every one of the eleven arguments the wrapper
#   passes has a row that breaks only the file it names: an argument nothing
#   reads is an argument that can be dropped without anything noticing.
#
#   Runtime -- `seed-fixture-only` is the one mode that reaches the runtime
#   half's own code with no vault, no container and no network. It is what
#   tests/integration.sh runs on the Docker host before the stack starts. This
#   layer deliberately stops there: everything past the vault read needs a served
#   Paperless, and fixturing the token, the document index, OCR, the portable
#   export and the persistence assertions is a separate piece of work.
#
#   Wrapper -- tests/contracts/paperless.sh is what turns a mode into three
#   invocations. Its rows prove all three programs are reached, that each is
#   resolved from the script's own checkout while the tree to inspect is passed
#   in, that the three greps which read the runtime program's own text still
#   bite, and that none of the three can consume the caller's stdin.
#
# Run with --self-test to plant a regression in each program and prove the rows
# above detect it.

require "digest"
require "etc"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)
CONTRACT = File.join(ROOT, "tests", "contracts", "paperless.sh")
RENDER_PROGRAM = File.join(ROOT, "tests", "contracts", "paperless-render.rb")
STATIC_PROGRAM = File.join(ROOT, "tests", "contracts", "paperless-static.rb")
RUNTIME_PROGRAM = File.join(ROOT, "tests", "contracts", "paperless-runtime.rb")

# The preloads tests/contracts/paperless.sh carries, transcribed rather than
# re-derived. -rjson and -ryaml are load-bearing: neither program requires the
# library it uses, so run bare each raises NameError on the first repository it
# looks at, and every invocation here has to carry the same preload or every row
# fails identically on an uninitialized constant -- which reads as the extraction
# having broken everything. -rpathname is carried because the heredoc declared
# it, and is reported in the pull request as inert rather than quietly dropped.
RENDER_COMMAND = [RbConfig.ruby, "-rjson", "-rpathname"].freeze
STATIC_COMMAND = [RbConfig.ruby, "-ryaml"].freeze

# Exactly what the contract reads out of the tree it inspects: the eleven
# arguments the static half receives, the role stages main.yml imports, and
# tests/policy_support.rb, which the static half requires through
# PLATFORM_CONTRACT_REPO_DIR. A fixture holding only these is the proof that the
# list is the list the contract actually needs.
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
  inventory/group_vars/all/main.yml
  generate-secrets.yml
  tests/mac/snapshot-paperless.sh
  tests/mac/snapshot-paperless.rb
  tests/fixtures/paperless-ocr.png.base64
  tests/integration.sh
  tests/integration_controller.sh
  tests/policy_support.rb
].freeze

# Deliberately absent from that list: tests/contracts/paperless.sh and all three
# of its programs. None of them is read out of the inspected tree -- the three
# self-read greps read the checkout's copy, which is what "$0" named while the
# code lived in one file -- and a fixture that carried them would shadow the
# defect #251 shipped: a program resolved from $repo_dir finds a copy there and
# nothing looks wrong. The wrapper layer plants an impostor at those paths inside
# the inspected tree instead, and requires it never to run.

# The arguments tests/contracts/paperless.sh passes the static half, in its
# order. Kept here rather than spelled out at each call site so a row cannot
# silently drift from the wrapper's own invocation, and asserted against the
# wrapper's text by the wrapper layer below.
STATIC_ARGUMENT_VARIABLES = {
  "services/paperless-ngx/compose.yml" => "compose",
  "services/paperless-ngx/compose.mac.yml" => "mac_compose",
  "services/paperless-ngx/compose.integration.yml" => "integration_compose",
  "roles/paperless_ngx/tasks/main.yml" => "role",
  "roles/paperless_ngx/defaults/main.yml" => "defaults",
  "roles/paperless_ngx/meta/argument_specs.yml" => "argument_specs",
  "inventory/group_vars/all/main.yml" => "storage_inventory",
  "roles/host_prep/tasks/main.yml" => "host_prep",
  "generate-secrets.yml" => "generator",
  "roles/paperless_ngx/templates/env.j2" => "environment_template",
  "tests/mac/snapshot-paperless.sh" => "snapshot",
  "tests/mac/snapshot-paperless.rb" => "snapshot_program"
}.freeze
STATIC_ARGUMENTS = STATIC_ARGUMENT_VARIABLES.keys.freeze

# Runs independent cases through a worker pool, capped at the core count. The
# same shape and the same reasoning as in_parallel_cases in
# tests/media_acquisition_reconciliation_support.rb: a check that spawns a
# subprocess per case, serially, becomes the floor for the whole policy gate, and
# oversubscribing a four-core CI runner trades wall time for contention. Never
# more workers than cores.
CASE_WORKER_LIMIT = Integer(
  ENV.fetch("PAPERLESS_CONTRACT_CASE_WORKERS") { [Etc.nprocessors, 8].min.to_s }, 10
)

def in_parallel_cases(items)
  items = items.to_a
  workers = [CASE_WORKER_LIMIT, items.length].min
  return items.flat_map { |item| yield item } if workers <= 1

  pending = Queue.new
  items.each_with_index { |item, index| pending << [index, item] }
  collected = {}
  lock = Mutex.new
  Array.new(workers) do
    Thread.new do
      loop do
        index, item = begin
                        pending.pop(true)
                      rescue ThreadError
                        break
                      end
        # A row whose fixture edit raises is a broken row, not a crashed suite:
        # without this the worker thread dies and the pool reports nothing about
        # the other rows it was carrying.
        local = begin
          yield item
        rescue StandardError => error
          ["#{item.is_a?(Hash) ? item.fetch(:name, item) : item}: fixture raised " \
           "#{error.class}: #{error.message}"]
        end
        lock.synchronize { collected[index] = local }
      end
    end
  end.each(&:join)
  collected.keys.sort.flat_map { |index| collected.fetch(index) }
end

# Substitutes text and asserts its own match count. Two of the literals this file
# plants occur more than once across the contract, so a plain sub can hit the
# wrong copy, plant nothing and report a pass -- which is what a mutation row
# that proves nothing looks like from the outside.
def substitute(text, from, to, count: 1)
  found = text.scan(from).length
  raise "#{from.inspect} matched #{found} times, expected #{count}" unless found == count

  count == 1 ? text.sub(from, to) : text.gsub(from, to)
end

def judge(label, expects, stdout, stderr, status, expects_crash: nil)
  output = stdout + stderr
  failures = []
  if expects_crash
    failures << "#{label}: accepted what it must refuse" if status.success?
    Array(expects_crash).each do |fragment|
      failures << "#{label}: did not name #{fragment}, got #{output.strip.inspect}" unless
        output.include?(fragment)
    end
    return failures
  end
  if expects.nil?
    failures << "#{label}: expected success, got exit #{status.exitstatus}: #{output.strip}" unless
      status.success?
    return failures
  end

  if status.success?
    failures << "#{label}: accepted what it must refuse"
  elsif !output.include?("Paperless contract failed: #{expects}")
    failures << "#{label}: refused for the wrong reason, wanted #{expects.inspect}, " \
                "got #{output.strip.lines.first.to_s.strip.inspect}"
  end
  failures
end

# --- render layer ----------------------------------------------------------
#
# The canned render. Built as a Hash so a row can break exactly one property of
# the merged document, which is the thing the program judges -- `docker compose
# config` output, not a compose file.

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
    # The failure the render program exists for: Compose appends two `ports:`
    # lists, so a sandbox override without !override publishes the production
    # 8000 alongside its own and two sandboxes collide on it again. The
    # override's source text reads correctly; only the merged list shows it.
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
  # Deliberately unpinned, and recorded here rather than left unexplained: the
  # program's "document sources alias or overlap" and "document source resolves
  # below volume1" refusals are unreachable while the three document sources are
  # each compared against a pinned literal a few lines above. Any render that
  # could reach them fails the per-target source comparison first. They are
  # defence in depth against a later change to that literal map, not assertions
  # this file can move -- and a row that expected the earlier diagnostic would
  # pin the redundancy in place rather than describe it.
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
  in_parallel_cases(rows) do |row|
    variant = row.fetch(:variant)
    config = rendered_config(variant)
    row.fetch(:break).call(config)
    stdout, stderr, status = Open3.capture3(
      { "PAPERLESS_RENDERED_COMPOSE" => JSON.generate(config) },
      *RENDER_COMMAND, program, variant
    )
    judge("render: #{row.fetch(:name)}", row.fetch(:expects), stdout, stderr, status,
          expects_crash: row[:expects_crash])
  end
end

# --- static layer ----------------------------------------------------------

def build_fixture_repository(root)
  FIXTURE_FILES.each do |relative|
    destination = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(destination))
    FileUtils.cp(File.join(ROOT, relative), destination)
    # The mode matters, not just the bytes: tests/contracts/paperless.sh refuses
    # a coordinated snapshot that is not executable, and since #315 that is two
    # files rather than one, only one of which ends in .sh.
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

# Finds one task by name anywhere in the role -- any stage file, and through the
# block/rescue/always sections a task list nests into -- and hands it to the
# caller to edit in place. Locating the task rather than naming its file keeps a
# row honest when a stage file is split again.
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

# One row per argument the wrapper passes, each breaking only the file that
# argument names, plus two family rows. An argument nothing reads is an argument
# that could be dropped silently, which is what this shape refuses to allow.
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
    argument: "inventory/group_vars/all/main.yml",
    break: lambda { |root|
      edit_yaml(root, "inventory/group_vars/all/main.yml") do |document|
        entry = document.fetch("nas_storage").find do |candidate|
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
  # Deliberately unpinned, for the same reason as the two render refusals above:
  # "generator must not synthesize a Gmail app password" is unreachable, because
  # a value containing `{{` is by definition not equal to the sentinel and the
  # equality check refuses first. It guards against a later change to that
  # sentinel, and a row expecting the earlier diagnostic would freeze the
  # redundancy instead of describing it.
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
  # The pair that pins the wrapper/program split #315 created. The row above
  # plants its defect in the shell wrapper and the one below in the Ruby program,
  # so a static half that read only one of the two files would leave one of them
  # passing on a planted regression. Before the split both were one file and one
  # `snapshot_text`; a repoint that moved every assertion to the program would
  # have made the deadline default above a positive grep that can no longer
  # match.
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
  in_parallel_cases(rows) do |row|
    Dir.mktmpdir("nas-platform-paperless-static.") do |raw|
      root = File.realpath(raw)
      build_fixture_repository(root)
      row.fetch(:break).call(root)
      arguments = STATIC_ARGUMENTS.map { |relative| File.join(root, relative) }
      stdout, stderr, status = Open3.capture3(
        { "PLATFORM_CONTRACT_REPO_DIR" => root }, *STATIC_COMMAND, program, *arguments
      )
      judge("static: #{row.fetch(:name)}", row.fetch(:expects), stdout, stderr, status,
            expects_crash: row[:expects_crash])
    end
  end
end

# --- runtime layer ---------------------------------------------------------
#
# `seed-fixture-only` writes the three document fixtures the integration lane
# consumes and returns before the vault read, so it is the whole runtime half
# this layer can reach without a served Paperless. It is also the mode the
# launcher runs on the Docker host, which makes it the one worth pinning.

CONSUME_FIXTURES = %w[task-13-contract.pdf task-13-contract.png task-13-contract.docx].freeze

RUNTIME_ROWS = [
  {
    name: "the document fixture pre-seed on an empty inbox",
    mode: "seed-fixture-only", break: ->(_root, _media) {}, expects: nil,
    reports: "Paperless document fixtures prepared before deployment",
    # The mode the program asks for, masked the way the environment will mask
    # it. Pinning a literal 0o644 would be pinning this machine's umask.
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
  in_parallel_cases(rows) do |row|
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
                       expects_crash: row[:expects_crash])
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
#
# tests/contracts/paperless.sh resolves all three programs from its own checkout
# rather than from the tree it is inspecting, so a copy of the four files into a
# throwaway tests/contracts/ is a whole working contract. That is what lets a row
# point PLATFORM_CONTRACT_REPO_DIR at a broken fixture and still exercise the
# real wrapper.
#
# The wrapper renders each variant with `docker compose config` before it reaches
# any program, so every row here puts a `docker` stub first on PATH that answers
# with the same canned render the render layer uses. That keeps these rows
# hermetic and sub-second; the real render is exercised by the paperless
# integration lane and by tests/contract_structure_mutation_test.rb.

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
  Dir.mktmpdir("nas-platform-paperless-wrapper.") do |raw|
    root = File.realpath(raw)
    build_fixture_repository(root)
    contracts = File.join(root, "tests", "contracts")
    FileUtils.mkdir_p(contracts)
    {
      "paperless.sh" => wrapper,
      "paperless-render.rb" => render,
      "paperless-static.rb" => static,
      "paperless-runtime.rb" => runtime
    }.each do |name, content|
      destination = File.join(contracts, name)
      File.write(destination, content)
      File.chmod(name.end_with?(".sh") ? 0o755 : 0o644, destination)
    end
    renders = File.join(root, "renders")
    FileUtils.mkdir_p(renders)
    %w[nas mac integration].each do |variant|
      File.write(File.join(renders, "#{variant}.json"), JSON.generate(rendered_config(variant)))
    end
    stub_dir = File.join(root, "stub-bin")
    FileUtils.mkdir_p(stub_dir)
    File.write(File.join(stub_dir, "docker"), DOCKER_STUB)
    File.chmod(0o755, File.join(stub_dir, "docker"))
    yield File.join(contracts, "paperless.sh"), root, {
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

# The three literals the wrapper greps out of the runtime program's own source,
# with the diagnostic each one owns. Two of them were vacuous while the runtime
# half shared the wrapper's file: `grep -F` matches a substring and the grep line
# spells its own pattern, so the assertion was satisfied by itself. The
# extraction is what makes them bite, so they are pinned here in both directions.
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
    # The literal is the call site, not the def's signature -- `def request`
    # declares `read_timeout: 60`. A sentinel that quoted a signature would hold
    # whether or not anything called it, which is the sixth-sentinel weakness
    # #285 left unpinned in the Jellyfin contract.
    name: "the Gmail probe's use of that constant",
    from: "read_timeout: MAIL_PROBE_READ_TIMEOUT", to: "read_timeout: 180",
    expects: "runtime Gmail probe lacks its explicit bounded timeout"
  }
].freeze

def wrapper_failures(wrapper_source: File.read(CONTRACT))
  failures = []

  # The wrapper's own invocation must agree with what this file drives directly.
  # Both directions: every argument is bound to the inspected tree, and the
  # static invocation passes them in this order. STATIC_ARGUMENTS drifting from
  # the wrapper would silently move every static row onto the wrong file.
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
    # Static mode, with the tree to inspect defaulted to the copy the wrapper
    # lives in. Every program has to be found and every grep has to pass.
    stdout, stderr, status = Open3.capture3(stub_env, contract, "static")
    unless status.success? && stdout.include?("Paperless static contract passed")
      failures << "wrapper: static mode failed against its own checkout: #{(stdout + stderr).strip}"
    end

    # The inspected tree is an argument; the programs are not. A broken fixture
    # must be judged by the programs in the copy.
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

    # An impostor at the sibling paths inside the inspected tree must never run.
    # Absence cannot decide this: the fixture deliberately carries no
    # tests/contracts, so a program resolved from $repo_dir would simply be
    # missing. A different program there is what separates the two roots.
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

    # PLATFORM_CONTRACT_REPO_DIR stays bound to the inspected tree, because the
    # static half requires tests/policy_support from it. Proven by taking that
    # one file out of the inspected tree and requiring the failure to name it.
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

    # The runtime half is reached, and the mode reaches its own success line.
    sandbox = runtime_sandbox(copy_root)
    stdout, stderr, status = Open3.capture3(
      stub_env.merge(sandbox), contract, "seed-fixture-only"
    )
    unless status.success? &&
           stdout.include?("Paperless document fixtures prepared before deployment")
      failures << "wrapper: seed-fixture-only did not reach the runtime program: " \
                  "#{(stdout + stderr).strip}"
    end

    # Two `:?` guards refuse before the runtime program can start against an
    # empty path. The wording of that refusal belongs to the shell -- bash says
    # "parameter null or not set" and dash says "parameter not set or null" -- so
    # only the portable prefix is asserted, and the substantive property is
    # stated separately: the runtime program must never have run.
    # Set to the empty string rather than removed: `${VAR:?}` refuses null as
    # well as unset, and removing the key would leave the row passing silently
    # for a developer who happens to have the variable exported. Same class as
    # deriving the fixture mode from the umask instead of pinning a literal.
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

  # Each of the three greps that read the runtime program's own text, planted one
  # at a time in the copy the wrapper will actually run. Each literal must also
  # resolve to exactly one site in that program, and the grep must name the
  # program rather than the wrapper: a literal with two homes, or a grep pointed
  # at "$0", is how the second and third of these came to be vacuous.
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
#
# A heredoc consumes the caller's stdin by construction; a sibling program does
# not, so each invocation carries `</dev/null`. None of the three programs reads
# stdin today, so dropping a redirect changes no outcome -- which is exactly why
# the rule cannot be proven by the contract passing, and why each row swaps in a
# probe program that does read.

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
  # Every probe keeps the real program's bytes below it. The render and static
  # halves have to finish their run; the runtime probe reports and stops before
  # the vault read, but its source still has to carry the three constants the
  # wrapper greps out of it -- a stub there is refused by the contract itself,
  # which is #285's finding about impostor programs and applies to probes too.
  render = probe_program("render", File.read(RENDER_PROGRAM))
  static = probe_program("static", File.read(STATIC_PROGRAM))
  runtime = probe_program(
    "runtime", %(puts "runtime probe reached with an empty stdin"\nexit 0\n) +
               File.read(RUNTIME_PROGRAM)
  )
  with_contract_copy(render: render, static: static, runtime: runtime,
                     wrapper: wrapper_source) do |contract, copy_root, stub_env|
    stdout, stderr, status = Open3.capture3(stub_env, contract, "static", stdin_data: "caller-payload\n")
    output = stdout + stderr
    unless status.success?
      failures << "stdin: a program was handed the caller's input: #{output.strip.inspect}"
    end
    sandbox = runtime_sandbox(copy_root)
    stdout, stderr, status = Open3.capture3(
      stub_env.merge(sandbox), contract, "run", stdin_data: "caller-payload\n"
    )
    output = stdout + stderr
    unless status.success? && stdout.include?("runtime probe reached with an empty stdin")
      failures << "stdin: the runtime program was handed the caller's input: #{output.strip.inspect}"
    end
  end
  failures
end

# --- planted regressions ---------------------------------------------------
#
# Each entry removes one guard from one program and names the rows that must
# catch it. A row that survives its own guard being deleted is proving nothing.
# Every plant asserts its own match count, so a substitution that hits nothing
# aborts instead of reporting a pass.

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
    # A recorded cascade, not a tolerated mess: a source outside the isolated
    # root is also absent from the expected list, so with this guard gone the
    # list comparison two lines below refuses instead. The row still moves --
    # what changes is which sentence it gets -- and naming the sentence is what
    # keeps that fact from being rediscovered as a mystery.
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
    # A recorded cascade. This coverage check is what makes the per-service
    # fetches below it safe, so deleting it does not accept the repository -- it
    # raises KeyError on the first service the override no longer names. The row
    # still refuses; the sentence is a stack trace rather than a diagnostic.
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
    # Both rows plant a path whose bytes are wrong rather than absent, so with
    # the guard gone the mode reaches its own success line instead of refusing.
    detects: "accepted what it must refuse"
  },
  {
    label: "the exclusive fixture creation mode",
    program: :runtime,
    from: "path.open(File::WRONLY | File::CREAT | File::EXCL, 0o644)",
    # 0o755 rather than a near neighbour on purpose: 0o666 masks to 0o644 under
    # the common umask 022 and the plant would be invisible, which is the same
    # class of mistake as pinning the mode literal in the first place.
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

def rows_named(rows, names)
  selected = rows.select { |row| names.include?(row.fetch(:name)) }
  abort "self-test names a row that does not exist: #{names.inspect}" unless
    selected.length == names.length

  selected
end

if ARGV.include?("--self-test")
  in_parallel_cases(PROGRAM_MUTATIONS) do |mutation|
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

  # The three stdin redirects, one per invocation. The runtime one is `exec`ed and
  # cannot be covered by either of the others.
  planted_redirects = 0
  [
    ["\"$render_program\" \"$variant\" </dev/null\n", "\"$render_program\" \"$variant\"\n"],
    ["\"$generator\" \"$environment_template\" \"$snapshot\" \"$snapshot_program\" </dev/null\n",
     "\"$generator\" \"$environment_template\" \"$snapshot\" \"$snapshot_program\"\n"],
    ["exec ruby \"$runtime_program\" \"$mode\" \"$@\" </dev/null\n",
     "exec ruby \"$runtime_program\" \"$mode\" \"$@\"\n"]
  ].each do |from, to|
    unredirected = substitute(File.read(CONTRACT), from, to)
    leaked = stdin_failures(wrapper_source: unredirected)
    abort "self-test failed: a dropped stdin redirect was accepted: #{from.strip.inspect}" if
      leaked.empty?
    planted_redirects += 1
  end

  # The defect #251 shipped one version of, at every site paperless has: the
  # three program paths, which must come from the checkout, and the two things
  # bound to the inspected tree on purpose. Both directions.
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

  puts "paperless contract: self-test detects " \
       "#{PROGRAM_MUTATIONS.length + planted_redirects + planted_roots} planted regressions"
  exit
end

failures = render_failures + static_failures + runtime_failures + wrapper_failures + stdin_failures
unless failures.empty?
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} Paperless contract violation(s)"
end

puts "paperless contract: #{RENDER_ROWS.length} render, #{STATIC_ROWS.length} static and " \
     "#{RUNTIME_ROWS.length} runtime properties hold, and the wrapper reaches all three " \
     "programs with an empty stdin"
