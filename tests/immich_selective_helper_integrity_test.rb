#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)
MAIN = YAML.safe_load_file(
  File.join(ROOT, "roles", "immich", "tasks", "main.yml"), aliases: true
)
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
INTEGRITY_TASK_NAME = "Verify Immich restore classifier before storage classification"
CLASSIFIER_TASK_NAME = "Classify Immich storage before startup"
FIXED_REFUSAL = "Immich restore classifier integrity check failed."

def fail_test(message)
  abort "Immich selective helper integrity failed: #{message}"
end

def source_task(name)
  task = MAIN.find { |candidate| candidate["name"] == name }
  fail_test("source task is absent: #{name}") unless task
  Marshal.load(Marshal.dump(task))
end

def write_playbook(path, variables)
  playbook = [{
    "hosts" => "localhost", "connection" => "local", "gather_facts" => false,
    "vars" => variables,
    "tasks" => [source_task(INTEGRITY_TASK_NAME), source_task(CLASSIFIER_TASK_NAME)]
  }]
  File.write(path, YAML.dump(playbook), mode: "w", perm: 0o600)
end

def tripwire_count(path)
  File.file?(path) ? File.readlines(path).length : 0
end

fail_test("pinned ansible-playbook is unavailable") unless File.executable?(ANSIBLE)

Dir.mktmpdir("nas-platform-immich-selective-helper-") do |temporary|
  controller = File.realpath(temporary)
  controller_helper = File.join(controller, "services", "immich", "classify_restore.py")
  release_root = File.join(controller, "release")
  deployed_helper = File.join(release_root, "services", "immich", "classify_restore.py")
  tripwire = File.join(controller, "python-executed.log")
  FileUtils.mkdir_p(File.dirname(controller_helper))
  FileUtils.mkdir_p(File.dirname(deployed_helper))
  FileUtils.cp(
    File.join(ROOT, "roles", "immich", "tasks", "verify_classifier.yml"),
    File.join(controller, "verify_classifier.yml")
  )

  helper_source = <<~PYTHON
    import os
    with open(os.environ["IMMICH_CLASSIFIER_TRIPWIRE"], "a", encoding="utf-8") as stream:
        stream.write("executed\\n")
  PYTHON
  File.write(controller_helper, helper_source, mode: "w", perm: 0o644)
  FileUtils.cp(controller_helper, deployed_helper)
  FileUtils.chmod(0o644, deployed_helper)

  variables = {
    "ansible_facts" => { "python" => { "executable" => "python3" } },
    "platform_current_dir" => release_root,
    "immich_restore_database_root" => File.join(controller, "postgres"),
    "immich_restore_originals_root" => File.join(controller, "originals"),
    "immich_restore_backup_root" => File.join(controller, "backups"),
    "immich_restore_effective_failure_marker" => File.join(controller, ".restore-failed"),
    "immich_restore_backup_uid" => Process.uid,
    "immich_restore_backup_gid" => Process.gid,
    "immich_restore_expected_immich_version" => "3.1.0",
    "immich_restore_expected_postgres_major" => 14
  }
  playbook = File.join(controller, "selective-helper.yml")
  write_playbook(playbook, variables)

  valid_output, valid_error, valid_status = Open3.capture3(
    { "ANSIBLE_NOCOLOR" => "1", "IMMICH_CLASSIFIER_TRIPWIRE" => tripwire },
    ANSIBLE, "-i", "localhost,", playbook, chdir: ROOT
  )
  fail_test("valid helper did not execute: #{valid_output.lines.last(8).join}#{valid_error}") unless
    valid_status.success?
  fail_test("valid helper did not execute exactly once") unless tripwire_count(tripwire) == 1

  scenarios = {
    "missing" => lambda { FileUtils.rm_f(deployed_helper) },
    "tampered" => lambda { File.write(deployed_helper, "tampered\n", mode: "w", perm: 0o644) },
    "symlink" => lambda do
      FileUtils.rm_f(deployed_helper)
      deployed_helper_target = File.join(controller, "outside-helper.py")
      File.write(deployed_helper_target, helper_source, mode: "w", perm: 0o644)
      File.symlink(deployed_helper_target, deployed_helper)
    end,
    "mode" => lambda { FileUtils.chmod(0o600, deployed_helper) }
  }

  scenarios.each do |label, mutate|
    FileUtils.rm_f(deployed_helper)
    FileUtils.cp(controller_helper, deployed_helper)
    FileUtils.chmod(0o644, deployed_helper)
    mutate.call
    before = tripwire_count(tripwire)
    output, error, status = Open3.capture3(
      { "ANSIBLE_NOCOLOR" => "1", "IMMICH_CLASSIFIER_TRIPWIRE" => tripwire },
      ANSIBLE, "-i", "localhost,", playbook, chdir: ROOT
    )
    combined = output + error
    fail_test("#{label} helper unexpectedly executed") if status.success?
    fail_test("#{label} helper reached Python") unless tripwire_count(tripwire) == before
    fail_test("#{label} helper emitted no fixed refusal") unless combined.include?(FIXED_REFUSAL)
    fail_test("#{label} helper leaked a protected path") if combined.include?(release_root)
  end
end

puts "Immich selective helper integrity fixture passed"
