#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "yaml"
require "zlib"

require_relative "policy_support"

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
# Both versions come from the fixture filename, not the image-derived role
# defaults, or the fixture would refuse itself on the next bump (#560).
BACKUP_IMMICH_VERSION = BACKUP_NAME[/-v([0-9.]+)-pg/, 1]
BACKUP_POSTGRES_MAJOR = BACKUP_NAME[/-pg([0-9]+)\./, 1].to_i
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

def source_restore_task(name)
  task = PolicySupport.flatten_tasks(RESTORE).find { |candidate| candidate["name"] == name }
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
    "immich_restore_expected_immich_version" => BACKUP_IMMICH_VERSION,
    "immich_restore_expected_postgres_major" => BACKUP_POSTGRES_MAJOR,
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

# --- #907: the hourly originals check -----------------------------------------
# Runs verify_originals.yml against the real helper with only the psql read stubbed.
ORIGINALS_TAG = "platform_verify_immich_originals"
ORIGINALS_MARKER = "IMMICH-ORIGINALS-MISSING"
ORIGINALS_PATH = File.join(ROOT, "roles", "immich", "tasks", "verify_originals.yml")
fail_test("verify_originals.yml is absent") unless File.file?(ORIGINALS_PATH)
ORIGINALS = YAML.safe_load_file(ORIGINALS_PATH, aliases: true)
ORIGINALS_SAMPLE_TASK = "Read a random sample of Immich asset rows"
IMMICH_GROUP_VARS = YAML.safe_load_file(
  File.join(ROOT, "inventory", "group_vars", "all", "service_immich.yml"), aliases: true
)

def originals_sample_task(tasks)
  tasks.find { |candidate| candidate["name"] == ORIGINALS_SAMPLE_TASK } ||
    fail_test("originals task is absent: #{ORIGINALS_SAMPLE_TASK}")
end

# Random, so repeated hours cover the library rather than rereading its first
# rows; restore.yml's ORDER BY id is the shape this must not take.
def random_sample?(tasks)
  sql = Array(originals_sample_task(tasks).dig("community.docker.docker_compose_v2_exec", "argv"))
        .join("\n").gsub(/\s+/, " ")
  sql.include?(%(ORDER BY random() LIMIT :'sample_limit')) && !sql.match?(/ORDER BY (id|"id")/i)
end

fail_test("the originals sample must be ORDER BY random() LIMIT :'sample_limit'") unless
  random_sample?(ORIGINALS)
planted = Marshal.load(Marshal.dump(ORIGINALS))
originals_sample_task(planted).dig("community.docker.docker_compose_v2_exec", "argv")
  .map! { |argument| argument.gsub("ORDER BY random()", "ORDER BY id") }
fail_test("planted: an ORDER BY id sample was not refused") if random_sample?(planted)
fail_test("the sample read must stay under no_log") unless
  originals_sample_task(ORIGINALS)["no_log"] == true
fail_test("every originals task must carry #{ORIGINALS_TAG}") unless
  ORIGINALS.all? { |candidate| Array(candidate["tags"]).include?(ORIGINALS_TAG) }
fail_test("the originals root must be derived exactly as main.yml derives it") unless
  ORIGINALS.any? do |candidate|
    candidate.dig("ansible.builtin.set_fact", "immich_restore_originals_root") ==
      source_task("Derive the effective Immich storage roots")
        .dig("ansible.builtin.set_fact", "immich_restore_originals_root")
  end

def run_originals(root, sample)
  media_root = File.join(root, "media")
  release_root = File.join(root, "release")
  [File.join(release_root, "services", "immich"), File.join(root, "services", "immich")].each do |directory|
    FileUtils.mkdir_p(directory)
    FileUtils.cp(CLASSIFIER, File.join(directory, "classify_restore.py"))
    FileUtils.chmod(0o644, File.join(directory, "classify_restore.py"))
  end
  FileUtils.cp(File.join(ROOT, "roles", "immich", "tasks", "verify_classifier.yml"),
               File.join(root, "verify_classifier.yml"))
  real = originals_sample_task(ORIGINALS)
  stub = {
    "name" => ORIGINALS_SAMPLE_TASK,
    "ansible.builtin.command" => { "argv" => ["printf", "%s", "{{ fixture_sample | to_json }}"] },
    "register" => real.fetch("register"),
    "changed_when" => false,
    "tags" => real.fetch("tags")
  }
  tasks = ORIGINALS.map { |candidate| candidate["name"] == ORIGINALS_SAMPLE_TASK ? stub : candidate }
  variables = {
    "ansible_facts" => { "python" => { "executable" => PYTHON } },
    "nas_media_root" => media_root,
    "platform_current_dir" => release_root,
    "immich_originals_verify_sample_size" => DEFAULTS.fetch("immich_originals_verify_sample_size"),
    "immich_originals_missing_ceiling_percent" =>
      IMMICH_GROUP_VARS.fetch("immich_originals_missing_ceiling_percent"),
    "fixture_sample" => sample
  }
  playbook_path = File.join(root, "originals.yml")
  File.write(playbook_path, YAML.dump([{ "hosts" => "localhost", "connection" => "local",
                                         "gather_facts" => false, "vars" => variables,
                                         "tasks" => tasks }]))
  stdout, stderr, status = Open3.capture3({ "ANSIBLE_NOCOLOR" => "1" }, ANSIBLE, "-i", "localhost,",
                                          playbook_path, "--tags", ORIGINALS_TAG, chdir: ROOT)
  [stdout + stderr, status]
end

def originals_sample(root, present:, missing:)
  library = File.join(root, "media", "Immich", "library", "admin")
  FileUtils.mkdir_p(library)
  (0...present).map do |index|
    File.write(File.join(library, "present-#{index}.jpg"), "x")
    { "id" => "present-#{index}", "originalPath" => "/data/library/admin/present-#{index}.jpg" }
  end + (0...missing).map do |index|
    { "id" => "missing-#{index}", "originalPath" => "/data/library/admin/moved-away-#{index}.jpg" }
  end
end

fail_test("the declared ceiling must be 0 percent") unless
  IMMICH_GROUP_VARS["immich_originals_missing_ceiling_percent"] == 0
{
  "all present" => [20, 0, true],
  "one missing original" => [19, 1, false],
  "several missing originals" => [17, 3, false]
}.each do |label, (present, missing, passes)|
  Dir.mktmpdir("nas-platform-immich-originals-") do |temporary|
    root = File.realpath(temporary)
    output, status = run_originals(root, originals_sample(root, present: present, missing: missing))
    fail_test("originals check, #{label}: expected #{passes ? 'pass' : 'fail'}: " \
              "#{output.lines.last(8).join}") unless status.success? == passes
    fail_test("originals check, #{label}: the marker must appear exactly when it fails") unless
      output.include?("#{ORIGINALS_MARKER}:") == !passes
    fail_test("originals check, #{label}: the count must be reported") unless
      output.include?("#{missing} of #{present + missing} sampled")
    fail_test("originals check, #{label}: a path left the check: #{output}") if
      output.include?("moved-away") || output.include?(File.join(root, "media"))
  end
end

Dir.mktmpdir("nas-platform-immich-originals-empty-") do |temporary|
  root = File.realpath(temporary)
  output, status = run_originals(root, [])
  fail_test("originals check, empty sample: must skip cleanly: #{output.lines.last(8).join}") unless
    status.success? && output.include?("no asset rows to sample")
  fail_test("originals check, empty sample: the helper must not run") if
    output.match?(/Check the sampled Immich originals.*\n(ok|changed|fatal)/)
end

# A refused path is a check that could not run, never a missing original, so
# its failure must not carry the marker the poller pages "missing" on.
Dir.mktmpdir("nas-platform-immich-originals-refused-") do |temporary|
  root = File.realpath(temporary)
  sample = originals_sample(root, present: 1, missing: 0) +
           [{ "id" => "escape", "originalPath" => "/data/../etc/passwd" }]
  output, status = run_originals(root, sample)
  fail_test("originals check, refused path: must fail") if status.success?
  fail_test("originals check, refused path: must not page as missing originals") if
    output.include?("#{ORIGINALS_MARKER}:")
  fail_test("originals check, refused path: a path left the check") if
    output.include?(File.join(root, "media")) || output.include?("/etc/passwd")
end

verify_playbook = YAML.safe_load_file(File.join(ROOT, "verify.yml"), aliases: true)
include_task = verify_playbook.flat_map { |play| Array(play["tasks"]) }.find do |candidate|
  candidate.dig("ansible.builtin.include_role", "tasks_from") == "verify_originals"
end
fail_test("verify.yml must include verify_originals under [never, #{ORIGINALS_TAG}] with apply") unless
  include_task && include_task.dig("ansible.builtin.include_role", "name") == "immich" &&
  Array(include_task["tags"]).sort == ["never", ORIGINALS_TAG].sort &&
  include_task.dig("ansible.builtin.include_role", "apply", "tags") == [ORIGINALS_TAG]

puts "Immich restore crash-provenance lifecycle fixtures passed"
