#!/usr/bin/env ruby

require "fileutils"
require "open3"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)

def executable_on_path(name, path)
  path.to_s.split(File::PATH_SEPARATOR).each do |directory|
    next if directory.empty?

    candidate = File.expand_path(File.join(directory, name))
    return candidate if File.file?(candidate) && File.executable?(candidate)
  end
  nil
end

def resolve_ansible_runtime(path:, exported_python:)
  playbook = executable_on_path("ansible-playbook", path)
  raise "ansible-playbook is unavailable on PATH" unless playbook

  if exported_python && File.file?(exported_python) && File.executable?(exported_python)
    return [playbook, File.expand_path(exported_python)]
  end

  stdout, stderr, status = Open3.capture3({ "PATH" => path }, playbook, "--version")
  unless status.success?
    detail = stderr.lines.first&.strip
    message = "ansible-playbook --version failed"
    message += ": #{detail}" unless detail.to_s.empty?
    raise message
  end
  managed_python = stdout.lines.filter_map do |line|
    line[/ \((\/[^()\r\n]+)\)\s*\z/, 1] if line.start_with?("  python version = ")
  end.first
  unless managed_python && File.file?(managed_python) && File.executable?(managed_python)
    detail = managed_python || "ansible-playbook --version did not report an executable path"
    raise "Ansible managed Python interpreter is unavailable: #{detail}"
  end

  [playbook, managed_python]
end

begin
  ANSIBLE_PLAYBOOK, ANSIBLE_PYTHON = resolve_ansible_runtime(
    path: ENV.fetch("PATH", ""), exported_python: ENV["ansible_python"]
  )
rescue RuntimeError => e
  abort e.message
end
TASKS = YAML.safe_load_file(File.join(ROOT, "roles", "host_prep", "tasks", "main.yml"))

def deep_copy(value)
  Marshal.load(Marshal.dump(value))
end

def production_task(name)
  task = TASKS.find { |entry| entry["name"] == name }
  task && deep_copy(task)
end

def assertion_task(name, condition)
  {
    "name" => name,
    "ansible.builtin.assert" => { "that" => [condition] },
    "changed_when" => false
  }
end

def run_play(fixture, label, tasks, variables)
  @play_index = @play_index.to_i + 1
  play_path = File.join(fixture, format("play-%02d.yml", @play_index))
  play = [{
    "name" => label,
    "hosts" => "localhost",
    "connection" => "local",
    "gather_facts" => false,
    "vars" => variables.merge("ansible_python_interpreter" => ANSIBLE_PYTHON),
    "tasks" => tasks
  }]
  File.write(play_path, YAML.dump(play))
  local_temp = File.join(fixture, "ansible-local")
  FileUtils.mkdir_p(local_temp)
  stdout, stderr, status = Open3.capture3(
    { "ANSIBLE_NOCOLOR" => "1", "ANSIBLE_LOCAL_TEMP" => local_temp },
    ANSIBLE_PLAYBOOK, "-i", "localhost,", play_path, chdir: ROOT
  )
  [stdout + stderr, status]
end

def expect_success(failures, label, output, status)
  return if status.success?

  failures << "#{label}: unexpectedly failed: #{output.lines.grep(/FAILED!|fatal:/).first&.strip}"
end

def expect_failure(failures, label, output, status)
  return unless status.success?

  failures << "#{label}: unexpectedly passed"
end

def resolver_contract_problems
  problems = []
  parent_venv_assumption = %w[.. .. .venv bin].join("/")
  problems << "Ansible resolution must not assume a parent repository virtualenv" if
    File.read(__FILE__).include?(parent_venv_assumption)
  unless respond_to?(:resolve_ansible_runtime, true)
    problems << "Ansible runtime resolver is unavailable"
    return problems
  end

  Dir.mktmpdir("host-prep-writer-resolver-") do |fixture|
    bin = File.join(fixture, "bin")
    FileUtils.mkdir_p(bin)
    exported_python = File.join(fixture, "exported-python")
    derived_python = File.join(fixture, "derived-python")
    [exported_python, derived_python].each do |path|
      File.write(path, "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, path)
    end
    playbook = File.join(bin, "ansible-playbook")
    File.write(playbook, <<~SH)
      #!/bin/sh
      printf '%s\n' 'ansible-playbook [core test]' \
        '  python version = 3.14.0 (test build) (#{derived_python})'
    SH
    File.chmod(0o755, playbook)

    exported_resolution = resolve_ansible_runtime(
      path: bin, exported_python: exported_python
    )
    problems << "resolver did not select ansible-playbook from PATH" unless
      exported_resolution.first == playbook
    problems << "resolver did not prefer the exported managed Python" unless
      exported_resolution.last == exported_python

    derived_resolution = resolve_ansible_runtime(
      path: bin, exported_python: File.join(fixture, "missing-exported-python")
    )
    problems << "resolver did not derive managed Python from ansible-playbook --version" unless
      derived_resolution == [playbook, derived_python]

    File.chmod(0o644, derived_python)
    begin
      resolve_ansible_runtime(path: bin, exported_python: nil)
      problems << "resolver accepted a non-executable managed Python"
    rescue RuntimeError => e
      problems << "resolver gave an imprecise managed-Python diagnostic" unless
        e.message == "Ansible managed Python interpreter is unavailable: #{derived_python}"
    ensure
      File.chmod(0o755, derived_python)
    end

    empty_path = File.join(fixture, "empty-path")
    FileUtils.mkdir_p(empty_path)
    begin
      resolve_ansible_runtime(path: empty_path, exported_python: exported_python)
      problems << "resolver accepted PATH without ansible-playbook"
    rescue RuntimeError => e
      problems << "resolver gave an imprecise missing-playbook diagnostic" unless
        e.message == "ansible-playbook is unavailable on PATH"
    end
  end
  problems
end

failures = []
failures.concat(resolver_contract_problems)

writer_mode = production_task("Select synthetic integration writer ownership")
writer_boundary = production_task("Require the exact integration media sandbox")
writer_preserve_refusal = production_task("Refuse preservation-only synthetic integration writers")
directory_task = production_task("Create service state directories")
writer_inspection = production_task("Inspect synthetic integration writer directories")
writer_assertion = production_task("Require synthetic integration writer ownership")
{
  "writer mode" => writer_mode,
  "sandbox boundary" => writer_boundary,
  "writer/preserve refusal" => writer_preserve_refusal,
  "directory creation" => directory_task,
  "writer inspection" => writer_inspection,
  "writer assertion" => writer_assertion
}.each do |label, task|
  failures << "production #{label} task is missing" unless task
end

Dir.mktmpdir("host-prep-writer-") do |fixture|
  exact_root = File.join(fixture, "nas-platform-integration.A1b2C3", "volume2")
  FileUtils.mkdir_p(exact_root)
  base_variables = {
    "platform_kind" => "nas",
    "platform_compose_kind" => "integration",
    "deployment_bundle_test_mode" => true,
    "nas_media_root" => exact_root,
    "nas_storage" => [],
    "nas_uid" => Process.uid,
    "nas_gid" => Process.gid,
    "platform_manage_linux_ownership" => false
  }

  {
    "exact valid root activates writer mode" => [{}, true],
    "non-NAS platform disables writer mode" => [{ "platform_kind" => "mac" }, false],
    "non-integration compose disables writer mode" => [
      { "platform_compose_kind" => "nas" }, false
    ],
    "false test mode disables writer mode" => [{ "deployment_bundle_test_mode" => false }, false]
  }.each do |label, (overrides, expected)|
    next unless writer_mode

    expected_literal = expected ? "true" : "false"
    tasks = [
      deep_copy(writer_mode),
      assertion_task(
        "Require expected writer activation",
        "(host_prep_integration_writer_enabled | bool) == #{expected_literal}"
      )
    ]
    output, status = run_play(fixture, label, tasks, base_variables.merge(overrides))
    expect_success(failures, label, output, status)
  end

  {
    "wrong root refuses before mutation" => File.join(fixture, "wrong-root"),
    "terminal-newline root refuses before mutation" => "#{exact_root}\n"
  }.each do |label, root|
    next unless writer_mode && writer_boundary

    sentinel = File.join(fixture, label.tr("^A-Za-z0-9", "_"))
    sentinel_task = {
      "name" => "Record forbidden mutation reachability",
      "ansible.builtin.copy" => { "content" => "reached\n", "dest" => sentinel, "mode" => "0600" }
    }
    output, status = run_play(
      fixture, label, [writer_mode, writer_boundary, sentinel_task],
      base_variables.merge("nas_media_root" => root)
    )
    expect_failure(failures, label, output, status)
    failures << "#{label}: mutation sentinel was created" if File.exist?(sentinel)
  end

  stable_path = File.join(fixture, "stable-ownerless")
  FileUtils.mkdir_p(stable_path)
  File.chmod(0o755, stable_path)
  alternate_uid = Process.uid + 1
  alternate_gid = Process.gid + 1
  ownership_cases = {
    "literal true marker activates ownership" => [true, {}, true],
    "integer one marker does not activate ownership" => [1, {}, false],
    "string one marker does not activate ownership" => ["1", {}, false],
    "string true marker does not activate ownership" => ["true", {}, false],
    "string yes marker does not activate ownership" => ["yes", {}, false],
    "production NAS ownerless path preserves ownership" => [
      nil,
      { "platform_compose_kind" => "nas", "deployment_bundle_test_mode" => false },
      false
    ],
    "Mac ownerless path preserves ownership" => [
      nil,
      { "platform_kind" => "mac", "platform_compose_kind" => "mac",
        "deployment_bundle_test_mode" => false },
      false
    ]
  }
  ownership_cases.each do |label, (marker, overrides, expected_change)|
    next unless writer_mode && writer_boundary && directory_task

    storage = { "path" => stable_path, "mode" => "0755", "recovery" => "cache" }
    storage["media_acquisition_writer"] = marker unless marker.nil?
    predicted_file = deep_copy(directory_task)
    predicted_file["check_mode"] = true
    predicted_file["register"] = "writer_file_prediction"
    tasks = [
      deep_copy(writer_mode),
      deep_copy(writer_boundary),
      assertion_task(
        "Require expected literal writer collection",
        "(host_prep_integration_writer_storage | length) == #{marker.equal?(true) ? 1 : 0}"
      ),
      predicted_file,
      assertion_task(
        "Require expected ownership prediction",
        "(writer_file_prediction.changed | bool) == #{expected_change}"
      )
    ]
    variables = base_variables.merge(
      "nas_storage" => [storage], "nas_uid" => alternate_uid, "nas_gid" => alternate_gid
    ).merge(overrides)
    output, status = run_play(fixture, label, tasks, variables)
    expect_success(failures, label, output, status)
  end

  preserve_sentinel = File.join(fixture, "preserve-sentinel")
  preserve_storage = [{
    "path" => File.join(exact_root, "preserved-writer"),
    "mode" => "0755",
    "recovery" => "cache",
    "media_acquisition_writer" => true,
    "preserve_only" => true
  }]
  if writer_mode && writer_boundary
    preserve_tasks = [writer_mode, writer_boundary, writer_preserve_refusal].compact << {
      "name" => "Record forbidden preserve mutation reachability",
      "ansible.builtin.copy" => {
        "content" => "reached\n", "dest" => preserve_sentinel, "mode" => "0600"
      }
    }
    output, status = run_play(
      fixture, "writer preserve-only conflict refuses before mutation", preserve_tasks,
      base_variables.merge("nas_storage" => preserve_storage)
    )
    expect_failure(failures, "writer preserve-only conflict refuses before mutation", output, status)
    failures << "writer preserve-only conflict: mutation sentinel was created" if
      File.exist?(preserve_sentinel)
  end

  positive_path = File.join(exact_root, "positive-writer")
  positive_storage = [{
    "path" => positive_path,
    "mode" => "0755",
    "recovery" => "cache",
    "media_acquisition_writer" => true
  }]
  positive_tasks = [
    writer_mode, writer_boundary, writer_preserve_refusal, directory_task,
    writer_inspection, writer_assertion
  ].compact
  if positive_tasks.length >= 5
    output, status = run_play(
      fixture, "positive writer identity and mode converge", positive_tasks,
      base_variables.merge("nas_storage" => positive_storage)
    )
    expect_success(failures, "positive writer identity and mode converge", output, status)
    if File.directory?(positive_path)
      stat = File.lstat(positive_path)
      failures << "positive writer UID differs" unless stat.uid == Process.uid
      failures << "positive writer GID differs" unless stat.gid == Process.gid
      failures << "positive writer mode differs" unless (stat.mode & 0o7777) == 0o755
    else
      failures << "positive writer directory was not created"
    end
  end

  if writer_inspection && writer_assertion
    symlink_target = File.join(fixture, "symlink-target")
    symlink_path = File.join(fixture, "writer-symlink")
    FileUtils.mkdir_p(symlink_target)
    File.symlink(symlink_target, symlink_path)
    wrong_mode_path = File.join(fixture, "wrong-mode")
    FileUtils.mkdir_p(wrong_mode_path)
    File.chmod(0o700, wrong_mode_path)

    {
      "symlink writer state is rejected" => symlink_path,
      "wrong writer mode is rejected" => wrong_mode_path
    }.each do |label, path|
      storage = [{
        "path" => path,
        "mode" => "0755",
        "recovery" => "cache",
        "media_acquisition_writer" => true
      }]
      output, status = run_play(
        fixture, label, [writer_inspection, writer_assertion],
        base_variables.merge(
          "nas_storage" => storage,
          "host_prep_integration_writer_storage" => storage,
          "host_prep_integration_writer_enabled" => true
        )
      )
      expect_failure(failures, label, output, status)
    end
  end
end

if failures.empty?
  puts "host prep integration writer: executable safety boundary holds"
else
  failures.each { |failure| warn "FAIL #{failure}" }
  abort "#{failures.length} host prep integration writer regression(s)"
end
