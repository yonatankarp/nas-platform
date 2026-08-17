#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "yaml"
require "zlib"

ROOT = File.expand_path("..", __dir__)
MAIN = YAML.safe_load_file(
  File.join(ROOT, "roles", "immich", "tasks", "main.yml"), aliases: true
)
RESTORE = YAML.safe_load_file(
  File.join(ROOT, "roles", "immich", "tasks", "restore.yml"), aliases: true
)
DEFAULTS = YAML.safe_load_file(
  File.join(ROOT, "roles", "immich", "defaults", "main.yml")
)
PYTHON = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map do |directory|
  candidate = File.join(directory, "python3")
  candidate if File.executable?(candidate)
end.compact.first.to_s
GIT_COMMON_DIR = File.expand_path(
  Open3.capture2("git", "rev-parse", "--git-common-dir", chdir: ROOT).first.strip,
  ROOT
)
ANSIBLE_ON_PATH = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map do |directory|
  candidate = File.join(directory, "ansible-playbook")
  candidate if File.executable?(candidate)
end.compact.first.to_s
ANSIBLE = if ANSIBLE_ON_PATH.empty?
            File.join(File.dirname(GIT_COMMON_DIR), ".venv", "bin", "ansible-playbook")
          else
            ANSIBLE_ON_PATH
          end
BACKUP_NAME = "immich-db-backup-20260815T010000-v3.1.0-pg14.19.sql.gz"
CLASSIFIER = File.join(ROOT, "services", "immich", "classify_restore.py")
PREFLIGHT_TASK_NAMES = [
  "Derive the effective Immich storage roots",
  "Require exact Immich effective storage roots",
  "Verify Immich restore classifier before storage classification",
  "Classify Immich storage before startup",
  "Resolve sanitized Immich storage classification status",
  "Require successful Immich storage classification",
  "Parse the Immich storage classification",
  "Require exact Immich storage classification",
  "Resolve the Immich database restore decision"
].freeze

def fail_test(message)
  abort "Immich restore lifecycle failed: #{message}"
end

def source_task(name)
  task = MAIN.find { |candidate| candidate["name"] == name }
  fail_test("source task is absent: #{name}") unless task
  Marshal.load(Marshal.dump(task))
end

def flatten_tasks(tasks)
  tasks.flat_map do |candidate|
    [candidate] + %w[block rescue always].flat_map do |section|
      flatten_tasks(Array(candidate[section]))
    end
  end
end

def source_restore_task(name)
  task = flatten_tasks(RESTORE).find { |candidate| candidate["name"] == name }
  fail_test("source restore task is absent: #{name}") unless task
  Marshal.load(Marshal.dump(task))
end

def log_task(name, event, when_conditions: nil)
  task = {
    "name" => name,
    "ansible.builtin.shell" => {
      "cmd" => "printf '%s\\n' #{event} >> \"$IMMICH_FIXTURE_EVENT_LOG\"",
      "executable" => "/bin/sh"
    },
    "environment" => { "IMMICH_FIXTURE_EVENT_LOG" => "{{ fixture_event_log }}" },
    "changed_when" => true
  }
  task["when"] = when_conditions if when_conditions
  task
end

def fixture_tasks
  tasks = PREFLIGHT_TASK_NAMES.map { |name| source_task(name) }

  tasks << log_task(
    "Stop Immich application services before database restore", "server-stop",
    when_conditions: ["immich_restore_required | bool", "not ansible_check_mode"]
  )
  tasks << source_task("Protect an in-progress Immich database restore")
  tasks << log_task(
    "Deploy the Immich data services", "data-start",
    when_conditions: "not ansible_check_mode"
  )
  tasks << {
    "name" => "Restore and verify the Immich database",
    "block" => [
      source_restore_task("Record the Immich Redis reset stage"),
      log_task("Simulate clearing stale Immich Redis state", "redis-reset"),
      {
        "name" => "Interrupt during Immich Redis reset",
        "ansible.builtin.fail" => { "msg" => "fixture-redis-reset-failed" },
        "when" => "fixture_failure_stage == 'redis-reset'"
      },
      source_restore_task("Record the Immich database restore stage"),
      {
        "name" => "Simulate committed Immich SQL restore",
        "ansible.builtin.shell" => {
          "cmd" => <<~'SH'.chomp,
            set -eu
            printf '%s\n' sql-restore >> "$IMMICH_FIXTURE_EVENT_LOG"
            mkdir -p -- "$IMMICH_FIXTURE_DATABASE_ROOT"
            printf '14\n' > "$IMMICH_FIXTURE_DATABASE_ROOT/PG_VERSION"
          SH
          "executable" => "/bin/sh"
        },
        "environment" => {
          "IMMICH_FIXTURE_EVENT_LOG" => "{{ fixture_event_log }}",
          "IMMICH_FIXTURE_DATABASE_ROOT" => "{{ immich_restore_database_root }}"
        },
        "changed_when" => true
      },
      {
        "name" => "Interrupt after committed Immich SQL restore",
        "ansible.builtin.fail" => { "msg" => "fixture-interrupted-after-sql" },
        "when" => "fixture_failure_stage == 'after-sql'"
      },
      log_task("Record completed Immich restore verification", "restore-verified")
    ],
    "rescue" => [
      source_restore_task("Record sanitized Immich restore failure stage"),
      source_restore_task("Refuse startup after an Immich restore failure")
    ],
    "when" => ["immich_restore_required | bool", "not ansible_check_mode"]
  }
  tasks << log_task("Deploy Immich", "server-start")
  tasks << {
    "name" => "Interrupt after Immich server startup",
    "ansible.builtin.fail" => { "msg" => "fixture-interrupted-after-server-start" },
    "when" => "fixture_failure_stage == 'server-start'"
  }
  tasks << {
    "name" => "Read Immich initialization state",
    "ansible.builtin.set_fact" => {
      "immich_public_config" => {
        "json" => { "isInitialized" => "{{ fixture_initialized | bool }}" }
      }
    }
  }
  tasks << source_task("Resolve Immich initialization state")
  tasks << source_task("Require initialized Immich after database restore")
  tasks << source_task("Remove successful Immich restore provenance")
  tasks << log_task(
    "Create the vault Immich administrator", "admin-signup",
    when_conditions: ["not ansible_check_mode", "not immich_initialized | bool"]
  )
  tasks
end

def write_backup(path)
  FileUtils.mkdir_p(File.dirname(path))
  Zlib::GzipWriter.open(path) do |stream|
    stream.write("SELECT 1;\n")
  end
end

def prepare_roots(root)
  docker_root = File.join(root, "docker")
  media_root = File.join(root, "media")
  database_root = File.join(docker_root, "immich", "postgres")
  originals_root = File.join(media_root, "Immich")
  backup_root = File.join(media_root, "Immich-backups", "database")
  marker = File.join(docker_root, "immich", ".restore-failed")
  FileUtils.mkdir_p(database_root)
  FileUtils.mkdir_p(File.join(originals_root, "upload"))
  File.binwrite(File.join(originals_root, "upload", "asset.jpg"), "asset")
  write_backup(File.join(backup_root, BACKUP_NAME))
  {
    docker_root: docker_root, media_root: media_root,
    database_root: database_root, originals_root: originals_root,
    backup_root: backup_root, marker: marker
  }
end

def run_fixture(root, roots, initialized:, failure_stage: "none")
  event_log = File.join(root, "events.log")
  release_root = File.join(root, "release")
  release_helper = File.join(release_root, "services", "immich", "classify_restore.py")
  controller_helper = File.join(root, "services", "immich", "classify_restore.py")
  FileUtils.mkdir_p(File.dirname(controller_helper))
  FileUtils.cp(CLASSIFIER, controller_helper)
  FileUtils.chmod(0o644, controller_helper)
  FileUtils.cp(
    File.join(ROOT, "roles", "immich", "tasks", "verify_classifier.yml"),
    File.join(root, "verify_classifier.yml")
  )
  FileUtils.mkdir_p(File.dirname(release_helper))
  FileUtils.cp(CLASSIFIER, release_helper)
  FileUtils.chmod(0o644, release_helper)
  variables = {
    "ansible_facts" => {
      "python" => { "executable" => PYTHON },
      "user_uid" => Process.uid,
      "user_gid" => Process.gid
    },
    "platform_kind" => "mac",
    "platform_manage_linux_ownership" => false,
    "nas_docker_root" => roots.fetch(:docker_root),
    "nas_media_root" => roots.fetch(:media_root),
    "immich_restore_failure_marker" => DEFAULTS.fetch("immich_restore_failure_marker"),
    "immich_restore_backup_uid" => DEFAULTS.fetch("immich_restore_backup_uid"),
    "immich_restore_backup_gid" => DEFAULTS.fetch("immich_restore_backup_gid"),
    "immich_restore_expected_immich_version" =>
      DEFAULTS.fetch("immich_restore_expected_immich_version"),
    "immich_restore_expected_postgres_major" =>
      DEFAULTS.fetch("immich_restore_expected_postgres_major"),
    "nas_uid" => Process.uid,
    "nas_gid" => Process.gid,
    "platform_current_dir" => release_root,
    "fixture_event_log" => event_log,
    "fixture_initialized" => initialized,
    "fixture_failure_stage" => failure_stage
  }
  playbook = [{
    "hosts" => "localhost", "connection" => "local", "gather_facts" => false,
    "vars" => variables, "tasks" => fixture_tasks
  }]
  playbook_path = File.join(root, "fixture.yml")
  File.write(playbook_path, YAML.dump(playbook), mode: "w", perm: 0o600)
  stdout, stderr, status = Open3.capture3(
    { "ANSIBLE_NOCOLOR" => "1" }, ANSIBLE, "-i", "localhost,", playbook_path,
    chdir: ROOT
  )
  events = File.file?(event_log) ? File.readlines(event_log, chomp: true) : []
  [stdout + stderr, status, events]
end

def assert_sanitized(output, roots)
  protected_paths = roots.values_at(
    :database_root, :originals_root, :backup_root, :marker
  )
  fail_test("failure output leaked a protected storage path") if
    protected_paths.any? { |path| output.include?(path) }
  fail_test("failure output leaked the backup filename") if output.include?(BACKUP_NAME)
end

def assert_marker(path, expected_stage)
  fail_test("marker is absent for stage #{expected_stage}") unless File.file?(path)
  content = File.binread(path)
  fail_test("marker has no real final newline for stage #{expected_stage}") unless
    content.end_with?("\n") && !content.end_with?("\\n")
  document = JSON.parse(content)
  fail_test("marker schema differs for stage #{expected_stage}") unless
    document.keys.sort == %w[stage version] && document["version"] == 1 &&
    document["stage"] == expected_stage
  metadata = File.stat(path)
  fail_test("native marker owner changed for stage #{expected_stage}") unless
    metadata.uid == Process.uid && metadata.gid == Process.gid
end

fail_test("pinned ansible-playbook is unavailable") unless File.executable?(ANSIBLE)
fail_test("python3 is unavailable") if PYTHON.empty?

Dir.mktmpdir("nas-platform-immich-lifecycle-") do |temporary|
  root = File.realpath(temporary)
  roots = prepare_roots(root)
  output, status, events = run_fixture(
    root, roots, initialized: true
  )
  fail_test("initialized restore failed: #{output.lines.last(8).join}") unless
    status.success?
  expected = %w[server-stop data-start redis-reset sql-restore restore-verified server-start]
  fail_test("restore lifecycle differs: #{events.inspect}") unless events == expected
  fail_test("restore did not write its active database") unless
    File.read(File.join(roots.fetch(:database_root), "PG_VERSION")) == "14\n"
  fail_test("successful restore retained its marker") if File.exist?(roots.fetch(:marker))

  repeat_output, repeat_status, repeat_events = run_fixture(
    root, roots, initialized: true
  )
  fail_test("repeat convergence failed: #{repeat_output.lines.last(8).join}") unless
    repeat_status.success?
  fail_test("repeat convergence restored or signed up an admin") unless
    repeat_events == expected + %w[data-start server-start]
  fail_test("repeat convergence created a marker") if File.exist?(roots.fetch(:marker))
end

Dir.mktmpdir("nas-platform-immich-lifecycle-sql-failure-") do |temporary|
  root = File.realpath(temporary)
  roots = prepare_roots(root)
  output, status, events = run_fixture(
    root, roots, initialized: true, failure_stage: "after-sql"
  )
  fail_test("post-SQL interruption unexpectedly succeeded") if status.success?
  fail_test("post-SQL interruption reached server/admin: #{events.inspect}") unless
    events == %w[server-stop data-start redis-reset sql-restore]
  assert_marker(roots.fetch(:marker), "database-restore")

  retry_output, retry_status, retry_events = run_fixture(
    root, roots, initialized: true
  )
  fail_test("post-SQL retry bypassed provenance") if retry_status.success?
  fail_test("post-SQL retry reached mutation") unless retry_events == events
  assert_sanitized(retry_output, roots)
  fail_test("post-SQL retry did not report prior provenance") unless
    retry_output.include?("previous-failed-restore")
end

Dir.mktmpdir("nas-platform-immich-lifecycle-server-failure-") do |temporary|
  root = File.realpath(temporary)
  roots = prepare_roots(root)
  output, status, events = run_fixture(
    root, roots, initialized: true, failure_stage: "server-start"
  )
  fail_test("post-startup interruption unexpectedly succeeded") if status.success?
  expected = %w[server-stop data-start redis-reset sql-restore restore-verified server-start]
  fail_test("post-startup interruption lifecycle differs: #{events.inspect}") unless events == expected
  assert_marker(roots.fetch(:marker), "dependencies-start")
  assert_sanitized(output, roots)

  retry_output, retry_status, retry_events = run_fixture(
    root, roots, initialized: true
  )
  fail_test("post-startup retry bypassed provenance") if retry_status.success?
  fail_test("post-startup retry reached server/admin mutation") unless retry_events == events
  assert_sanitized(retry_output, roots)
  fail_test("post-startup retry did not report prior provenance") unless
    retry_output.include?("previous-failed-restore")
end

Dir.mktmpdir("nas-platform-immich-lifecycle-redis-failure-") do |temporary|
  root = File.realpath(temporary)
  roots = prepare_roots(root)
  output, status, events = run_fixture(
    root, roots, initialized: true, failure_stage: "redis-reset"
  )
  fail_test("Redis reset failure unexpectedly succeeded") if status.success?
  fail_test("Redis reset failure reached SQL/server/admin: #{events.inspect}") unless
    events == %w[server-stop data-start redis-reset]
  assert_marker(roots.fetch(:marker), "redis-reset")
  assert_sanitized(output, roots)
end

Dir.mktmpdir("nas-platform-immich-lifecycle-uninitialized-") do |temporary|
  root = File.realpath(temporary)
  roots = prepare_roots(root)
  output, status, events = run_fixture(
    root, roots, initialized: false
  )
  fail_test("uninitialized restored server unexpectedly succeeded") if status.success?
  fail_test("uninitialized restore invoked administrator signup") if events.include?("admin-signup")
  fail_test("uninitialized restore did not reach full stack") unless events.last == "server-start"
  assert_marker(roots.fetch(:marker), "dependencies-start")

  retry_output, retry_status, retry_events = run_fixture(
    root, roots, initialized: false
  )
  fail_test("uninitialized retry bypassed provenance") if retry_status.success?
  fail_test("uninitialized retry reached server/admin") unless retry_events == events
  assert_sanitized(retry_output, roots)
  fail_test("uninitialized retry did not report prior provenance") unless
    retry_output.include?("previous-failed-restore")
end

puts "Immich restore crash-provenance lifecycle fixtures passed"
