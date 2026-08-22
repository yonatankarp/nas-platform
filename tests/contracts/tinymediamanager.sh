#!/bin/sh
set -eu
set +x

mode=${1:-static}
repo_dir=${PLATFORM_CONTRACT_REPO_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)}
compose=$repo_dir/services/tinymediamanager/compose.yml
role=$repo_dir/roles/tinymediamanager/tasks/main.yml
storage=$repo_dir/inventory/group_vars/all/main.yml
host_prep=$repo_dir/roles/host_prep/tasks/main.yml

fail_contract() {
  printf 'tinyMediaManager contract failed: %s\n' "$1" >&2
  exit 1
}

[ -f "$role" ] || fail_contract 'roles/tinymediamanager/tasks/main.yml is absent'
[ -f "$compose" ] || fail_contract 'services/tinymediamanager/compose.yml is absent'
[ -f "$storage" ] || fail_contract 'inventory/group_vars/all/main.yml is absent'
[ -f "$host_prep" ] || fail_contract 'roles/host_prep/tasks/main.yml is absent'

ruby -ryaml - "$compose" "$role" "$storage" "$host_prep" <<'RUBY'
compose_path, role_path, storage_path, host_prep_path = ARGV
compose = YAML.safe_load_file(compose_path, aliases: true)
role_tasks = YAML.safe_load_file(role_path, aliases: true)
storage_entries = YAML.safe_load_file(storage_path, aliases: true).fetch("nas_storage")
host_prep_tasks = YAML.safe_load_file(host_prep_path, aliases: true)
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

preserved_path = "{{ nas_docker_root }}/tinymediamanager/data"
preserved_entries = storage_entries.select { |entry| entry["path"] == preserved_path }
refuse("preserved state storage must be declared exactly once") unless preserved_entries.length == 1
refuse("preserved state storage must be preservation-only") unless
  preserved_entries.first["preserve_only"] == true

marker_index = host_prep_tasks.index do |task|
  task["name"] == "Validate preservation-only storage declarations"
end
inspect_index = host_prep_tasks.index do |task|
  task["name"] == "Inspect preservation-only service state directories"
end
require_index = host_prep_tasks.index do |task|
  task["name"] == "Require safe preservation-only service state directories"
end
create_index = host_prep_tasks.index { |task| task["name"] == "Create service state directories" }
refuse("preservation-only state is not validated before ordinary storage creation") unless
  marker_index && inspect_index && require_index && create_index &&
  marker_index < inspect_index && inspect_index < require_index && require_index < create_index

marker_assert = host_prep_tasks.fetch(marker_index).fetch("ansible.builtin.assert")
marker_conditions = Array(marker_assert["that"]).map(&:to_s)
refuse("preservation-only marker does not fail closed") unless
  marker_conditions.any? do |condition|
    condition.include?("item.preserve_only is not defined") && condition.include?("item.preserve_only")
  end

preservation_inspect = host_prep_tasks.fetch(inspect_index)
preservation_stat = preservation_inspect.fetch("ansible.builtin.stat")
refuse("preservation-only inspection path differs") unless preservation_stat["path"] == "{{ item.path }}"
refuse("preservation-only inspection follows symlinks") unless preservation_stat["follow"] == false
refuse("preservation-only inspection does not select marked entries") unless
  preservation_inspect["loop"].to_s.include?("selectattr('preserve_only', 'defined')")
preservation_register = preservation_inspect["register"]
refuse("preservation-only inspection is not registered") unless preservation_register.is_a?(String)

preservation_require = host_prep_tasks.fetch(require_index)
preservation_conditions = Array(
  preservation_require.dig("ansible.builtin.assert", "that")
).map(&:to_s)
%w[exists isdir islnk].each do |property|
  refuse("preservation-only state does not validate #{property}") unless
    preservation_conditions.any? { |condition| condition.include?("item.stat.#{property}") }
end
refuse("preservation-only state does not reject symlinks") unless
  preservation_conditions.any? { |condition| condition.include?("not item.stat.islnk") }
refuse("preservation-only assertion does not consume the fresh inspection") unless
  preservation_require["loop"].to_s.include?("#{preservation_register}.results")

ordinary_creation = host_prep_tasks.fetch(create_index)
refuse("ordinary storage creation can create preservation-only paths") unless
  ordinary_creation["loop"].to_s.include?("rejectattr('preserve_only', 'defined')")

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
retirement_index = role_tasks.index(retirement_task)

post_retirement_state_task = role_tasks.find do |task|
  task["name"] == "Inspect preserved tinyMediaManager state after retirement"
end
refuse("fresh post-retirement state inspection is absent") unless post_retirement_state_task
post_retirement_state_index = role_tasks.index(post_retirement_state_task)
refuse("preserved state is not inspected after Compose retirement") unless
  retirement_index < post_retirement_state_index
post_retirement_stat = post_retirement_state_task["ansible.builtin.stat"]
refuse("post-retirement state inspection does not use stat") unless post_retirement_stat.is_a?(Hash)
refuse("post-retirement state inspection path differs") unless
  post_retirement_stat["path"] == "{{ tinymediamanager_state_root }}"
refuse("post-retirement state inspection follows symlinks") unless
  post_retirement_stat["follow"] == false
post_retirement_state_register = post_retirement_state_task["register"]
refuse("post-retirement state inspection is not distinctly registered") unless
  post_retirement_state_register.is_a?(String) &&
    post_retirement_state_register != "tinymediamanager_preserved_state"

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
refuse("retirement inspection retains a managed-host Python dependency") if
  inspect_task.key?("community.docker.docker_container_info")
container_inspection = inspect_task["ansible.builtin.command"]
refuse("retirement inspection does not use the guaranteed Docker CLI") unless
  container_inspection.is_a?(Hash)
refuse("retirement inspection does not enumerate container names literally") unless
  container_inspection["argv"] == [
    "docker", "container", "ls", "--all", "--format", "{{ '{{.Names}}' }}"
  ]
refuse("retirement inspection can report a change") unless inspect_task["changed_when"] == false
refuse("retirement inspection is skipped in check mode") unless inspect_task["check_mode"] == false
inspect_register = inspect_task["register"]
refuse("retirement inspection does not register container state") unless inspect_register.is_a?(String)

absence_task = role_tasks.find { |task| task["name"] == "Require tinyMediaManager to remain retired" }
refuse("missing Require tinyMediaManager to remain retired") unless absence_task
assertion = absence_task["ansible.builtin.assert"]
refuse("retirement assertion is absent") unless assertion.is_a?(Hash)
conditions = Array(assertion["that"]).map(&:to_s)
refuse("retirement assertion does not inspect the retired container") unless
  conditions.any? do |condition|
    condition.include?("tinymediamanager_container_name not in") &&
      condition.include?("#{inspect_register}.stdout_lines")
  end
refuse("retirement assertion does not use fresh preserved state") unless
  conditions.count { |condition| condition.include?(post_retirement_state_register) } == 3
refuse("retirement assertion reuses stale preserved state") if
  conditions.any? { |condition| condition.include?("tinymediamanager_preserved_state") }
refuse("retirement assertion must tolerate check mode") unless
  conditions.any? { |condition| condition.include?("ansible_check_mode") && condition.match?(/\bor\b/) }
RUBY

case $mode in
  static)
    printf '%s\n' 'tinyMediaManager retirement static contract passed'
    exit 0
    ;;
  seed-retirement-fixture|validate-retirement-fixture|assert-retired) ;;
  *) fail_contract "unknown mode: $mode" ;;
esac

: "${PLATFORM_DOCKER_ROOT:?}"
: "${PLATFORM_REPORT_ROOT:?}"
if [ "$mode" = assert-retired ]; then
  : "${PLATFORM_TINYMEDIAMANAGER_CONTAINER:=tinymediamanager}"
else
  : "${PLATFORM_KIND:?}"
  : "${PLATFORM_CONTRACT_SANDBOX_ROOT:?}"
  : "${PLATFORM_CONTRACT_SANDBOX_OWNER_UID:?}"
  : "${PLATFORM_MEDIA_ROOT:?}"
  : "${PLATFORM_COMPOSE_KIND:?}"
  : "${PLATFORM_PROJECT_NAME:?}"
  : "${PLATFORM_TINYMEDIAMANAGER_WEB_PORT:?}"
  : "${PLATFORM_TINYMEDIAMANAGER_API_PORT:?}"
fi
export PLATFORM_DOCKER_ROOT PLATFORM_REPORT_ROOT
export PLATFORM_TINYMEDIAMANAGER_CONTAINER="${PLATFORM_TINYMEDIAMANAGER_CONTAINER:-tinymediamanager}"

exec ruby - "$mode" <<'RUBY'
require "digest"
require "json"
require "open3"
require "pathname"

MODE = ARGV.fetch(0)
DOCKER_ROOT = Pathname.new(ENV.fetch("PLATFORM_DOCKER_ROOT")).expand_path
REPORT_ROOT = Pathname.new(ENV.fetch("PLATFORM_REPORT_ROOT")).expand_path
CONTAINER = ENV.fetch("PLATFORM_TINYMEDIAMANAGER_CONTAINER")
SENTINEL_NAME = "retirement-contract.txt"
DIGEST_ARTIFACT_NAME = "tinymediamanager-retirement.sha256"
ENV_ARTIFACT_NAME = "tinymediamanager-retirement.env"
MARKER = "tinyMediaManager retirement state preserved\n".freeze
# The retained Compose health check waits for the legacy API port. A fresh
# disposable state root has no legacy settings to enable it, so fixture setup
# adds only this fixed non-secret bootstrap. Existing safe settings are left
# opaque and untouched; assert-retired proves preservation from the sentinel.
FIXTURE_SETTINGS_NAME = "tmm.json"
FIXTURE_SETTINGS = JSON.generate(
  "enableHttpServer" => true,
  "httpServerPort" => 7878,
  "httpApiKey" => "retirement-fixture-only"
) + "\n"
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

def canonical_absolute_path(environment_name)
  raw_path = ENV.fetch(environment_name)
  path = Pathname.new(raw_path)
  fail_contract("#{environment_name} must be a canonical absolute path") unless
    path.absolute? && path.cleanpath.to_s == raw_path && raw_path != "/"
  path
end

def open_verified_absolute_directory(path, label)
  current = File.open("/", DIRECTORY_OPEN_FLAGS)
  path.each_filename do |component|
    child = open_safe_child_directory(current, component, label)
    current.close
    current = child
  end
  current
rescue Errno::ENOENT, Errno::ELOOP, Errno::ENOTDIR, Errno::EACCES
  current&.close
  fail_contract("#{label} is unavailable or unsafe")
end

def open_verified_descendant(sandbox, sandbox_path, candidate_path, label)
  prefix = "#{sandbox_path}#{File::SEPARATOR}"
  fail_contract("#{label} is outside the disposable sandbox") unless
    candidate_path.to_s.start_with?(prefix)
  relative_path = candidate_path.to_s.delete_prefix(prefix)
  fail_contract("#{label} is not a sandbox descendant") if relative_path.empty?
  current = sandbox.dup
  Pathname.new(relative_path).each_filename do |component|
    child = open_safe_child_directory(current, component, label)
    current.close
    current = child
  end
  current
rescue Errno::ENOENT, Errno::ELOOP, Errno::ENOTDIR, Errno::EACCES
  current&.close
  fail_contract("#{label} is unavailable or unsafe")
end

def validate_fixture_identity
  fail_contract("safe descriptor flags are unavailable") unless
    File.const_defined?(:NOFOLLOW) && File.const_defined?(:NONBLOCK)
  fail_contract("PLATFORM_KIND is not disposable") unless
    %w[test integration mac].include?(ENV.fetch("PLATFORM_KIND"))
  fail_contract("PLATFORM_COMPOSE_KIND is not disposable") unless
    %w[integration mac].include?(ENV.fetch("PLATFORM_COMPOSE_KIND"))
  project_name = ENV.fetch("PLATFORM_PROJECT_NAME")
  fail_contract("PLATFORM_PROJECT_NAME is unsafe") unless
    project_name.match?(/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/)
  %w[PLATFORM_TINYMEDIAMANAGER_WEB_PORT PLATFORM_TINYMEDIAMANAGER_API_PORT].each do |name|
    value = ENV.fetch(name)
    fail_contract("#{name} is unsafe") unless value.match?(/\A[0-9]+\z/) &&
      value.to_i.between?(1, 65_535)
  end
end

def with_validated_fixture_roots
  validate_fixture_identity
  sandbox_path = canonical_absolute_path("PLATFORM_CONTRACT_SANDBOX_ROOT")
  docker_path = canonical_absolute_path("PLATFORM_DOCKER_ROOT")
  media_path = canonical_absolute_path("PLATFORM_MEDIA_ROOT")
  report_path = canonical_absolute_path("PLATFORM_REPORT_ROOT")
  sandbox = open_verified_absolute_directory(sandbox_path, "contract sandbox root")
  owner_uid = ENV.fetch("PLATFORM_CONTRACT_SANDBOX_OWNER_UID")
  fail_contract("PLATFORM_CONTRACT_SANDBOX_OWNER_UID is unsafe") unless
    owner_uid.match?(/\A[0-9]+\z/)
  sandbox_stat = sandbox.stat
  fail_contract("contract sandbox root owner differs") unless
    sandbox_stat.uid == owner_uid.to_i
  fail_contract("contract sandbox root mode differs") unless
    (sandbox_stat.mode & 0o777) == 0o700
  docker_root = open_verified_descendant(sandbox, sandbox_path, docker_path, "Docker root")
  media_root = open_verified_descendant(sandbox, sandbox_path, media_path, "media root")
  report_root = open_verified_descendant(sandbox, sandbox_path, report_path, "report root")
  yield docker_root, media_root, report_root
ensure
  [report_root, media_root, docker_root, sandbox].compact.each(&:close)
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

def require_safe_existing_file(directory, name, label)
  in_directory(directory) do
    File.open(name, FILE_READ_FLAGS) do |file|
      stat = file.stat
      fail_contract("#{label} is unavailable or unsafe") unless stat.file?
      fail_contract("#{label} mode differs") unless (stat.mode & 0o777) == 0o600
    end
  end
rescue Errno::ENOENT, Errno::ELOOP, Errno::ENOTDIR, Errno::EISDIR, Errno::ENXIO
  fail_contract("#{label} is unavailable or unsafe")
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

def dotenv_value(name)
  value = ENV.fetch(name)
  fail_contract("#{name} is unsafe for the retirement environment") if value.match?(/[\r\n]/)
  value
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
  retirement_environment = {
    "TZ" => "UTC",
    "PLATFORM_CONTAINER_CPUSET" => "0",
    "USER_ID" => "1000",
    "GROUP_ID" => "100",
    "TINYMEDIAMANAGER_PASSWORD" => "retirement-fixture-only",
    "TINYMEDIAMANAGER_DATA_PATH" => File.join(
      dotenv_value("PLATFORM_DOCKER_ROOT"), "tinymediamanager", "data"
    ),
    "TINYMEDIAMANAGER_MOVIES_PATH" => File.join(
      dotenv_value("PLATFORM_MEDIA_ROOT"), "Media", "Movies"
    ),
    "TINYMEDIAMANAGER_SERIES_PATH" => File.join(
      dotenv_value("PLATFORM_MEDIA_ROOT"), "Media", "Series"
    ),
    "TINYMEDIAMANAGER_WEB_HOST_PORT" => dotenv_value(
      "PLATFORM_TINYMEDIAMANAGER_WEB_PORT"
    ),
    "TINYMEDIAMANAGER_API_HOST_PORT" => dotenv_value(
      "PLATFORM_TINYMEDIAMANAGER_API_PORT"
    ),
    "PLATFORM_PROJECT_NAME" => dotenv_value("PLATFORM_PROJECT_NAME")
  }
  with_validated_fixture_roots do |docker_root, _media_root, report_root|
    state_parent = open_safe_child_directory(
      docker_root, "tinymediamanager", "retirement state parent", create: true
    )
    state_root = open_safe_child_directory(
      state_parent, "data", "retirement state directory", create: true
    )
    settings_root = open_safe_child_directory(
      state_root, "data", "retirement fixture settings directory", create: true
    )
    settings_exist = path_entry_exists?(settings_root, FIXTURE_SETTINGS_NAME)
    if settings_exist
      require_safe_existing_file(
        settings_root, FIXTURE_SETTINGS_NAME, "existing tinyMediaManager settings"
      )
    end
    environment_contents = retirement_environment.map { |key, value| "#{key}=#{value}" }.join("\n")
    artifacts = [
      [state_root, SENTINEL_NAME, MARKER, "retirement sentinel"],
      [
        report_root,
        DIGEST_ARTIFACT_NAME,
        "#{Digest::SHA256.hexdigest(MARKER)}\n",
        "retirement digest artifact"
      ],
      [report_root, ENV_ARTIFACT_NAME, "#{environment_contents}\n", "retirement environment"]
    ]
    artifact_presence = artifacts.map do |directory, name, _contents, _label|
      path_entry_exists?(directory, name)
    end
    if artifact_presence.any?
      fail_contract("retirement fixture artifacts are incomplete") unless artifact_presence.all?
      artifacts.each do |directory, name, contents, label|
        fail_contract("#{label} contents differ") unless
          read_safe_file(directory, name, label) == contents
      end
    else
      artifacts.each do |directory, name, contents, label|
        create_exclusive(directory, name, contents, label)
      end
    end
    unless settings_exist
      create_exclusive(
        settings_root,
        FIXTURE_SETTINGS_NAME,
        FIXTURE_SETTINGS,
        "retirement fixture settings"
      )
    end
    settings_root.close
    state_root.close
    state_parent.close
  end
  puts "tinyMediaManager retirement fixture prepared"
when "validate-retirement-fixture"
  with_validated_fixture_roots { |_docker_root, _media_root, _report_root| nil }
  puts "tinyMediaManager retirement fixture context is disposable"
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
