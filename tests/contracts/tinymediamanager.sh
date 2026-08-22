#!/bin/sh
set -eu
set +x

mode=${1:-static}
repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)}
compose=$repo_dir/services/tinymediamanager/compose.yml
role=$repo_dir/roles/tinymediamanager/tasks/main.yml

fail_contract() {
  printf 'tinyMediaManager contract failed: %s\n' "$1" >&2
  exit 1
}

[ -f "$role" ] || fail_contract 'roles/tinymediamanager/tasks/main.yml is absent'
[ -f "$compose" ] || fail_contract 'services/tinymediamanager/compose.yml is absent'

ruby -ryaml - "$compose" "$role" <<'RUBY'
compose_path, role_path = ARGV
compose = YAML.safe_load_file(compose_path, aliases: true)
role_tasks = YAML.safe_load_file(role_path, aliases: true)
service = compose.fetch("services").fetch("tinymediamanager")

def refuse(message)
  abort "tinyMediaManager contract failed: #{message}"
end

def state_root_reference?(value)
  case value
  when Hash then value.any? { |key, child| state_root_reference?(key) || state_root_reference?(child) }
  when Array then value.any? { |child| state_root_reference?(child) }
  else value.to_s.include?("tinymediamanager_state_root")
  end
end

refuse("canonical storage contract differs") unless service.fetch("volumes") == [
  "${TINYMEDIAMANAGER_DATA_PATH:?}:/data",
  "${TINYMEDIAMANAGER_MOVIES_PATH:?}:/media/Movies",
  "${TINYMEDIAMANAGER_SERIES_PATH:?}:/media/Series"
]
refuse("canonical logging policy differs") unless service.fetch("logging") == {
  "driver" => "json-file", "options" => { "max-size" => "10m", "max-file" => "3" }
}

retirement_task = role_tasks.find { |task| task["name"] == "Retire tinyMediaManager without deleting state" }
abort "tinyMediaManager retirement contract failed: retirement task is absent" unless retirement_task
retirement_compose = retirement_task["community.docker.docker_compose_v2"]
refuse("retirement task does not use docker_compose_v2") unless retirement_compose.is_a?(Hash)
expected_compose = {
  "project_src" => "{{ platform_current_dir }}/services/tinymediamanager",
  "project_name" => "{{ tinymediamanager_compose_project_name }}",
  "files" => "{{ platform_service_compose_files['tinymediamanager'] }}",
  "state" => "absent",
  "remove_volumes" => false,
  "remove_orphans" => false
}
expected_compose.each do |key, value|
  refuse("retirement Compose #{key} differs") unless retirement_compose[key] == value
end

if role_tasks.any? do |task|
     compose_task = task["community.docker.docker_compose_v2"]
     compose_task.is_a?(Hash) && compose_task["state"] == "present"
   end
  refuse("role must not start tinyMediaManager")
end

if role_tasks.any? do |task|
     %w[ansible.builtin.copy ansible.builtin.file ansible.builtin.template].any? do |module_name|
       task.key?(module_name) && state_root_reference?(task.fetch(module_name))
     end
   end
  refuse("retirement role must not mutate tinymediamanager_state_root")
end

inspect_task = role_tasks.find { |task| task["name"] == "Inspect the retired tinyMediaManager container" }
refuse("missing Inspect the retired tinyMediaManager container") unless inspect_task
container_info = inspect_task["community.docker.docker_container_info"]
refuse("retirement inspection does not use docker_container_info") unless container_info.is_a?(Hash)
inspect_register = inspect_task["register"]
refuse("retirement inspection does not register container state") unless inspect_register.is_a?(String)

absence_task = role_tasks.find { |task| task["name"] == "Require tinyMediaManager to remain retired" }
refuse("missing Require tinyMediaManager to remain retired") unless absence_task
assertion = absence_task["ansible.builtin.assert"]
refuse("retirement assertion is absent") unless assertion.is_a?(Hash)
conditions = Array(assertion["that"]).map(&:to_s)
refuse("retirement assertion does not inspect the retired container") unless
  conditions.any? { |condition| condition.include?(inspect_register) }
refuse("retirement assertion must tolerate check mode") unless
  conditions.any? { |condition| condition.include?("ansible_check_mode") && condition.match?(/\bor\b/) }
RUBY

case $mode in
  static)
    printf '%s\n' 'tinyMediaManager retirement static contract passed'
    exit 0
    ;;
  seed-retirement-fixture|assert-retired) ;;
  *) fail_contract "unknown mode: $mode" ;;
esac

: "${PLATFORM_DOCKER_ROOT:?}"
: "${PLATFORM_REPORT_ROOT:?}"
: "${PLATFORM_TINYMEDIAMANAGER_CONTAINER:=tinymediamanager}"
export PLATFORM_DOCKER_ROOT PLATFORM_REPORT_ROOT PLATFORM_TINYMEDIAMANAGER_CONTAINER

exec ruby - "$mode" <<'RUBY'
require "digest"
require "json"
require "open3"
require "pathname"

MODE = ARGV.fetch(0)
DOCKER_ROOT = Pathname.new(ENV.fetch("PLATFORM_DOCKER_ROOT")).expand_path
REPORT_ROOT = Pathname.new(ENV.fetch("PLATFORM_REPORT_ROOT")).expand_path
CONTAINER = ENV.fetch("PLATFORM_TINYMEDIAMANAGER_CONTAINER")
SENTINEL_NAME = ".nas-platform-retirement-sentinel"
DIGEST_ARTIFACT_NAME = "tinymediamanager-retirement.sha256"
MARKER = "tinyMediaManager retirement state preserved\n".freeze
NOFOLLOW = File.const_defined?(:NOFOLLOW) ? File::NOFOLLOW : 0
DIRECTORY_OPEN_FLAGS = File::RDONLY | File::NONBLOCK | NOFOLLOW
FILE_READ_FLAGS = File::RDONLY | File::NONBLOCK | NOFOLLOW

def fail_contract(message)
  warn "tinyMediaManager contract failed: #{message}"
  exit 1
end

def open_safe_directory(path, label)
  directory = File.open(path, DIRECTORY_OPEN_FLAGS)
  fail_contract("#{label} is unavailable or unsafe") unless directory.stat.directory?
  directory
rescue Errno::ENOENT, Errno::ELOOP, Errno::ENOTDIR, Errno::EACCES
  fail_contract("#{label} is unavailable or unsafe")
end

def in_directory(directory, &block)
  Dir.fchdir(directory.fileno, &block)
end

def open_safe_child_directory(parent, name, label, create: false)
  if create
    begin
      in_directory(parent) { Dir.mkdir(name, 0o755) }
    rescue Errno::EEXIST
      nil
    end
  end
  directory = in_directory(parent) { File.open(name, DIRECTORY_OPEN_FLAGS) }
  fail_contract("#{label} is unavailable or unsafe") unless directory.stat.directory?
  directory
rescue Errno::ENOENT, Errno::ELOOP, Errno::ENOTDIR, Errno::EACCES
  fail_contract("#{label} is unavailable or unsafe")
end

def with_contract_directories(create: false)
  docker_root = open_safe_directory(DOCKER_ROOT, "Docker root")
  state_parent = open_safe_child_directory(
    docker_root, "tinymediamanager", "retirement state parent", create: create
  )
  state_root = open_safe_child_directory(
    state_parent, "data", "retirement state directory", create: create
  )
  report_root = open_safe_directory(REPORT_ROOT, "report root")
  yield state_root, report_root
ensure
  [report_root, state_root, state_parent, docker_root].compact.each(&:close)
end

def read_safe_file(directory, name, label)
  in_directory(directory) do
    File.open(name, FILE_READ_FLAGS) do |file|
      stat = file.stat
      fail_contract("#{label} is unavailable or unsafe") unless stat.file?
      fail_contract("#{label} mode differs") unless (stat.mode & 0o777) == 0o600
      file.binmode
      file.read
    end
  end
rescue Errno::ENOENT, Errno::ELOOP, Errno::ENOTDIR, Errno::EISDIR, Errno::ENXIO
  fail_contract("#{label} is unavailable or unsafe")
end

def path_entry_exists?(directory, name)
  in_directory(directory) do
    File.lstat(name)
    true
  end
rescue Errno::ENOENT, Errno::ENOTDIR
  false
end

def refuse_existing_target(directory, name, label)
  fail_contract("refusing to replace #{label}") if path_entry_exists?(directory, name)
end

def create_exclusive(directory, name, contents, label)
  refuse_existing_target(directory, name, label)
  in_directory(directory) do
    File.open(name, File::WRONLY | File::CREAT | File::EXCL | NOFOLLOW, 0o600) do |file|
      stat = file.stat
      fail_contract("#{label} is unavailable or unsafe") unless stat.file?
      fail_contract("#{label} mode differs") unless (stat.mode & 0o777) == 0o600
      file.write(contents)
    end
  end
rescue Errno::EEXIST, Errno::ELOOP
  fail_contract("refusing to replace #{label}")
end

def run_docker(*arguments)
  Open3.capture3("docker", *arguments)
rescue Errno::ENOENT, Errno::EACCES
  fail_contract("Docker CLI is unavailable")
end

def empty_inspect_result?(stdout)
  return true if stdout.empty?
  JSON.parse(stdout) == []
rescue JSON::ParserError
  false
end

case MODE
when "seed-retirement-fixture"
  with_contract_directories(create: true) do |state_root, report_root|
    refuse_existing_target(state_root, SENTINEL_NAME, "retirement sentinel")
    refuse_existing_target(report_root, DIGEST_ARTIFACT_NAME, "retirement digest artifact")
    create_exclusive(state_root, SENTINEL_NAME, MARKER, "retirement sentinel")
    create_exclusive(
      report_root,
      DIGEST_ARTIFACT_NAME,
      "#{Digest::SHA256.hexdigest(MARKER)}\n",
      "retirement digest artifact"
    )
  end
  puts "tinyMediaManager retirement fixture prepared"
when "assert-retired"
  with_contract_directories do |state_root, report_root|
    _info_stdout, _info_stderr, info_status = run_docker("info", "--format", "{{.ServerVersion}}")
    fail_contract("Docker daemon is unavailable") unless info_status.success?
    inspect_stdout, inspect_stderr, inspect_status = run_docker("container", "inspect", CONTAINER)
    fail_contract("retired tinyMediaManager container still exists") if inspect_status.success?
    expected_not_found = [
      "Error: No such container: #{CONTAINER}",
      "Error response from daemon: No such container: #{CONTAINER}"
    ]
    expected_status = inspect_status.exited? && inspect_status.exitstatus == 1
    unless expected_status && empty_inspect_result?(inspect_stdout) &&
           expected_not_found.include?(inspect_stderr.strip)
      fail_contract("could not establish that the retired tinyMediaManager container is absent")
    end
    sentinel_contents = read_safe_file(state_root, SENTINEL_NAME, "retirement sentinel")
    digest_contents = read_safe_file(
      report_root, DIGEST_ARTIFACT_NAME, "retirement digest artifact"
    )
    fail_contract("retirement sentinel contents differ") unless sentinel_contents == MARKER
    expected_digest = "#{Digest::SHA256.hexdigest(sentinel_contents)}\n"
    fail_contract("retirement digest artifact differs") unless digest_contents == expected_digest
  end
  puts "tinyMediaManager remains retired and its state is preserved"
else
  fail_contract("unknown mode: #{MODE}")
end
RUBY
