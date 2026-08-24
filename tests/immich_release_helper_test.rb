#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)
SOURCE_HELPER = File.join(ROOT, "services", "immich", "classify_restore.py")
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

def fail_test(message)
  abort "Immich release helper failed: #{message}"
end

def run_command(*argv, chdir:)
  stdout, stderr, status = Open3.capture3(*argv, chdir: chdir)
  fail_test("command failed: #{argv.join(' ')}\n#{stdout}#{stderr}") unless status.success?
  stdout.strip
end

def run_bundle(playbook)
  Open3.capture3(
    { "ANSIBLE_NOCOLOR" => "1" }, ANSIBLE, "-i", "localhost,", playbook,
    chdir: ROOT
  )
end

def write_playbook(path, storage_root, media_root, release_id)
  deploy_root = File.join(storage_root, "nas-platform")
  playbook = [{
    "hosts" => "localhost", "connection" => "local", "gather_facts" => true,
    "roles" => [{ "role" => "deployment_bundle" }],
    "vars" => {
      "deployment_bundle_controller_validated" => true,
      "deployment_bundle_test_mode" => true,
      "platform_kind" => "nas",
      "platform_compose_kind" => "fixture",
      "platform_release_id" => release_id,
      "nas_docker_root" => storage_root,
      "nas_media_root" => media_root,
      "platform_deploy_root" => deploy_root,
      "platform_release_dir" => File.join(deploy_root, "releases", release_id),
      "platform_current_dir" => File.join(deploy_root, "current"),
      "platform_runtime_dir" => File.join(deploy_root, "runtime")
    }
  }]
  File.write(path, YAML.dump(playbook), mode: "w", perm: 0o600)
end

fail_test("pinned ansible-playbook is unavailable") unless File.executable?(ANSIBLE)
fail_test("canonical classifier is absent") unless File.file?(SOURCE_HELPER)

Dir.mktmpdir("nas-platform-immich-release-helper-") do |temporary|
  root = File.realpath(temporary)
  controller = File.join(root, "controller")
  storage_root = File.join(root, "storage")
  media_root = File.join(root, "media")
  FileUtils.mkdir_p(controller)
  FileUtils.mkdir_p(storage_root)
  FileUtils.mkdir_p(media_root)
  FileUtils.cp_r(File.join(ROOT, "services"), controller)
  FileUtils.mkdir_p(File.join(controller, "config"))
  FileUtils.cp(
    File.join(ROOT, "config", "media-acquisition.yml"),
    File.join(controller, "config", "media-acquisition.yml")
  )
  run_command("git", "init", "-q", chdir: controller)
  run_command("git", "config", "user.name", "NAS platform test", chdir: controller)
  run_command("git", "config", "user.email", "test@example.invalid", chdir: controller)
  run_command("git", "add", ".", chdir: controller)
  run_command("git", "commit", "-qm", "immutable release fixture", chdir: controller)
  release_id = run_command("git", "rev-parse", "HEAD", chdir: controller)
  playbook = File.join(controller, "release-helper.yml")
  write_playbook(playbook, storage_root, media_root, release_id)

  controller_helper = File.join(controller, "services", "immich", "classify_restore.py")
  held_helper = File.join(root, "classify_restore.py.held")
  FileUtils.mv(controller_helper, held_helper)
  missing_output, missing_error, missing_status = run_bundle(playbook)
  fail_test("missing controller helper was accepted") if missing_status.success?
  fail_test("missing controller helper mutated the target") if
    File.exist?(File.join(storage_root, "nas-platform"))
  fail_test("missing controller helper emitted no safe refusal") unless
    (missing_output + missing_error).include?("required file does not exist")
  FileUtils.mv(held_helper, controller_helper)

  output, error, status = run_bundle(playbook)
  fail_test("initial immutable release failed: #{output.lines.last(8).join}#{error}") unless
    status.success?

  deploy_root = File.join(storage_root, "nas-platform")
  release_root = File.join(deploy_root, "releases", release_id)
  current = File.join(deploy_root, "current")
  deployed_helper = File.join(release_root, "services", "immich", "classify_restore.py")
  source_bytes = File.binread(controller_helper)
  fail_test("deployed helper bytes differ") unless File.binread(deployed_helper) == source_bytes
  fail_test("deployed helper mode differs") unless File.stat(deployed_helper).mode & 0o777 == 0o644
  fail_test("current pointer does not select the immutable release") unless
    File.realpath(current) == release_root

  manifest = YAML.safe_load_file(File.join(release_root, "manifest.yml"))
  catalog_source = File.join(controller, "config", "media-acquisition.yml")
  expected_platform_inputs = [{
    "path" => "config/media-acquisition.yml",
    "mode" => "0644",
    "checksum_sha256" => Digest::SHA256.file(catalog_source).hexdigest
  }]
  fail_test("manifest omits exact platform input integrity") unless
    manifest.fetch("platform_inputs") == expected_platform_inputs
  immich = manifest.fetch("services").find { |service| service.fetch("name") == "immich" }
  expected_runtime_files = [{
    "path" => "classify_restore.py",
    "mode" => "0644",
    "checksum_sha256" => Digest::SHA256.hexdigest(source_bytes)
  }]
  fail_test("manifest omits exact classifier integrity") unless
    immich.fetch("runtime_files") == expected_runtime_files
  verify_output, verify_error, verify_status = Open3.capture3(
    RbConfig.ruby, File.join(ROOT, "tests", "verify_deployment_manifest.rb"),
    File.join(release_root, "manifest.yml"), controller,
    File.join(controller, "services", "manifest.yml"), "nas", "fixture", release_id
  )
  fail_test("deployment manifest verifier rejected the release: #{verify_output}#{verify_error}") unless
    verify_status.success?

  File.binwrite(deployed_helper, "tampered-release-helper\n")
  File.chmod(0o644, deployed_helper)
  tamper_output, tamper_error, tamper_status = run_bundle(playbook)
  fail_test("tampered active helper was silently repaired") if tamper_status.success?
  fail_test("tampered active helper changed during refusal") unless
    File.binread(deployed_helper) == "tampered-release-helper\n"
  fail_test("tampered helper refusal moved current") unless File.realpath(current) == release_root
  fail_test("tampered helper emitted no immutable-release refusal") unless
    (tamper_output + tamper_error).include?("Refuse to mutate an active immutable release")

  File.binwrite(deployed_helper, source_bytes)
  File.chmod(0o644, deployed_helper)
  FileUtils.rm(deployed_helper)
  absent_output, absent_error, absent_status = run_bundle(playbook)
  fail_test("missing active helper was silently repaired") if absent_status.success?
  fail_test("missing active helper was recreated during refusal") if File.exist?(deployed_helper)
  fail_test("missing helper refusal moved current") unless File.realpath(current) == release_root
  fail_test("missing helper emitted no immutable-release refusal") unless
    (absent_output + absent_error).include?("Refuse to mutate an active immutable release")
end

puts "Immich immutable release helper packaging passed"
