#!/bin/sh
set -eu
set +x
umask 077

FRESH_PHASES=' preflight deploy seed verify idempotence drift reconcile recreate persistence report cleanup '
ADOPTION_PHASES=' preflight legacy-deploy legacy-seed capture-baseline snapshot cutover verify idempotence recreate persistence rollback report cleanup '

mac_script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_script_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"
. "$mac_repo_dir/tests/integration_lock.sh"

usage() {
  printf '%s\n' \
    'usage: run.sh --lane fresh|adoption --vault-file FILE --vault-password-file FILE_OR_EXECUTABLE' \
    '              [--parity-vault-file FILE --parity-vault-password-file FILE_OR_EXECUTABLE]' \
    '              [--keep-on-failure] [--phase NAME] [--sandbox PATH]' \
    'Executable password providers must use the exact #!/bin/sh shebang without options or NUL bytes.'
}

lane=
vault_file=
vault_password_file=
parity_vault_file=
parity_vault_password_file=
selected_phase=
requested_sandbox=
keep_on_failure=false
[ -z "${RUBYOPT+x}" ] && [ -z "${RUBYLIB+x}" ] &&
  [ -z "${RUBYGEMS_GEMDEPS+x}" ] && [ -z "${GEM_HOME+x}" ] && [ -z "${GEM_PATH+x}" ] &&
  [ -z "${BUNDLE_GEMFILE+x}" ] && [ -z "${BUNDLE_BIN_PATH+x}" ] &&
  [ -z "${BUNDLE_PATH+x}" ] && [ -z "${BUNDLE_APP_CONFIG+x}" ] &&
  [ -z "${BUNDLE_WITH+x}" ] && [ -z "${BUNDLE_WITHOUT+x}" ] ||
  mac_die 'reserved language startup environment must be unset'
[ -z "${PLATFORM_ADOPTION_ROOT+x}" ] && [ -z "${PLATFORM_ADOPTION_MARKER+x}" ] &&
  [ -z "${PLATFORM_ADOPTION_ENABLED+x}" ] &&
  [ -z "${PLATFORM_ADOPTION_SNAPSHOT_SELF_TEST+x}" ] &&
  [ -z "${PLATFORM_ADOPTION_COMPARE_SELF_TEST+x}" ] &&
  [ -z "${PLATFORM_ADOPTION_COMPARE_STAGE_MUTATION+x}" ] &&
  [ -z "${PLATFORM_ADOPTION_COMPARE_STAGE_PAYLOAD+x}" ] &&
  [ -z "${PLATFORM_ADOPTION_COMPARE_DEPENDENCY_MUTATION+x}" ] &&
  [ -z "${PLATFORM_ADOPTION_COMPARE_DEPENDENCY_TARGET+x}" ] &&
  [ -z "${PLATFORM_ADOPTION_COMPARE_DEPENDENCY_PAYLOAD+x}" ] &&
  [ -z "${PLATFORM_ADOPTION_PROBE_TARGET+x}" ] &&
  [ -z "${PLATFORM_ADOPTION_NTFY_CONTAINER+x}" ] &&
  [ -z "${PLATFORM_ADOPTION_NTFY_ENV_FILE+x}" ] &&
  [ -z "${PLATFORM_ADOPTION_SCRIPT_DIR+x}" ] &&
  [ -z "${PLATFORM_ADOPTION_BASELINE_FILE+x}" ] &&
  [ -z "${PLATFORM_ADOPTION_BASELINE_SELF_TEST+x}" ] &&
  [ -z "${PLATFORM_ADOPTION_BASELINE_EXPECTED_MUTATION+x}" ] &&
  [ -z "${PLATFORM_ADOPTION_ROLLBACK_SELF_TEST+x}" ] &&
  [ -z "${PLATFORM_ADOPTION_ROLLBACK_FAULT+x}" ] &&
  [ -z "${PLATFORM_ADOPTION_ROLLBACK_SNAPSHOT_COMMAND+x}" ] &&
  [ -z "${PLATFORM_ADOPTION_ROLLBACK_BASELINE_COMMAND+x}" ] &&
  [ -z "${PLATFORM_ADOPTION_ROLLBACK_RENDER_COMMAND+x}" ] &&
  [ -z "${PLATFORM_ADOPTION_ROLLBACK_OVERRIDE_ROOT+x}" ] &&
  [ -z "${PLATFORM_ADOPTION_ROLLBACK_CHALLENGE_FAULT+x}" ] &&
  [ -z "${PLATFORM_ADOPTION_CONTRACT_FILE+x}" ] &&
  [ -z "${PLATFORM_CONTRACT_REPO_DIR+x}" ] &&
  [ -z "${PLATFORM_LEGACY_FIXTURE_HELPER_FILE+x}" ] &&
  [ -z "${PLATFORM_ADOPTION_TMM_MOVIE_TEMPLATE_CONF+x}" ] &&
  [ -z "${PLATFORM_ADOPTION_TMM_MOVIE_LIST_JMTE+x}" ] &&
  [ -z "${PLATFORM_ADOPTION_TMM_TVSHOW_TEMPLATE_CONF+x}" ] &&
  [ -z "${PLATFORM_ADOPTION_TMM_TVSHOW_LIST_JMTE+x}" ] &&
  [ -z "${PLATFORM_SNAPSHOT_ESCAPE+x}" ] ||
  mac_die 'reserved adoption mapping environment must be unset'
while [ "$#" -gt 0 ]; do
  case $1 in
    --lane|--vault-file|--vault-password-file|--parity-vault-file|--parity-vault-password-file|--phase|--sandbox)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      case $1 in
        --lane) lane=$2 ;;
        --vault-file) vault_file=$2 ;;
        --vault-password-file) vault_password_file=$2 ;;
        --parity-vault-file) parity_vault_file=$2 ;;
        --parity-vault-password-file) parity_vault_password_file=$2 ;;
        --phase) selected_phase=$2 ;;
        --sandbox) requested_sandbox=$2 ;;
      esac
      shift 2
      ;;
    --keep-on-failure) keep_on_failure=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

case $lane in
  fresh)
    PHASES=$FRESH_PHASES
    [ -z "$parity_vault_file" ] && [ -z "$parity_vault_password_file" ] ||
      mac_die 'fresh lane rejects parity vault options'
    ;;
  adoption)
    PHASES=$ADOPTION_PHASES
    [ -n "$parity_vault_file" ] || mac_die 'adoption requires --parity-vault-file'
    [ -n "$parity_vault_password_file" ] || mac_die 'adoption requires --parity-vault-password-file'
    ;;
  *) usage >&2; exit 2 ;;
esac
[ -f "$vault_file" ] && [ ! -L "$vault_file" ] && [ -r "$vault_file" ] ||
  mac_die 'vault file must be a readable, regular encrypted file'
IFS= read -r vault_header < "$vault_file" || mac_die 'vault file has no Ansible Vault header'
case $vault_header in
  '$ANSIBLE_VAULT;'*) ;;
  *) mac_die 'vault file is not Ansible Vault encrypted' ;;
esac
[ -f "$vault_password_file" ] && [ ! -L "$vault_password_file" ] &&
  { [ -r "$vault_password_file" ] || [ -x "$vault_password_file" ]; } ||
  mac_die 'vault password input must be a readable file or executable'
case $(CDPATH= cd -- "$(dirname -- "$vault_password_file")" 2>/dev/null && pwd -P)/ in
  "$mac_repo_dir"/*) mac_die 'vault password input must remain outside the repository' ;;
esac

if [ "$lane" = adoption ]; then
  [ -f "$parity_vault_file" ] && [ ! -L "$parity_vault_file" ] && [ -r "$parity_vault_file" ] ||
    mac_die 'parity vault file must be a readable, regular encrypted file'
  IFS= read -r parity_vault_header < "$parity_vault_file" ||
    mac_die 'parity vault file has no Ansible Vault header'
  case $parity_vault_header in
    '$ANSIBLE_VAULT;'*) ;;
    *) mac_die 'parity vault file is not Ansible Vault encrypted' ;;
  esac
  parity_vault_parent=$(CDPATH= cd -- "$(dirname -- "$parity_vault_file")" 2>/dev/null && pwd -P) ||
    mac_die 'parity vault file parent is unavailable'
  case "$parity_vault_parent/$(basename -- "$parity_vault_file")" in
    "$mac_repo_dir"/*) mac_die 'parity vault file must remain outside the repository' ;;
  esac
  [ -f "$parity_vault_password_file" ] && [ ! -L "$parity_vault_password_file" ] &&
    { [ -r "$parity_vault_password_file" ] || [ -x "$parity_vault_password_file" ]; } ||
    mac_die 'parity vault password input must be a readable file or executable'
  case $(CDPATH= cd -- "$(dirname -- "$parity_vault_password_file")" 2>/dev/null && pwd -P)/ in
    "$mac_repo_dir"/*) mac_die 'parity vault password input must remain outside the repository' ;;
  esac
fi

if [ -n "$selected_phase" ]; then
  case "$PHASES" in *" $selected_phase "*) ;; *) mac_die "unknown phase: $selected_phase" ;; esac
fi

temporary_parent=$(mac_temporary_parent)
acquire_integration_lock "$temporary_parent"
sandbox=
preserve_sandbox_on_exit=false

release_run_lock() {
  [ -z "$integration_lock_path" ] || release_integration_lock
}

on_run_exit() {
  mac_exit_status=$?
  trap - EXIT HUP INT TERM
  if ! release_run_lock; then
    [ "$mac_exit_status" -ne 0 ] || mac_exit_status=1
  fi
  if { [ "$mac_exit_status" -ne 0 ] || [ "$preserve_sandbox_on_exit" = true ]; } &&
     [ -n "$sandbox" ] && mac_validate_sandbox "$sandbox" >/dev/null 2>&1; then
    printf 'Cleanup command: '
    mac_shell_quote "$mac_script_dir/cleanup.sh"
    printf ' '
    mac_shell_quote "$sandbox"
    printf '\n'
  elif [ "$mac_exit_status" -ne 0 ] && [ -n "$sandbox" ] && [ -d "$sandbox" ]; then
    printf 'Sandbox cleanup is incomplete and requires manual inspection: %s\n' \
      "$sandbox" >&2
  fi
  exit "$mac_exit_status"
}
trap on_run_exit EXIT
trap 'exit 130' HUP INT TERM

if [ -n "$requested_sandbox" ]; then
  sandbox=$(mac_validate_sandbox "$requested_sandbox")
else
  sandbox=$(mktemp -d "$temporary_parent/nas-platform-mac.XXXXXX")
  chmod 0700 "$sandbox"
  sandbox=$(CDPATH= cd -- "$sandbox" && pwd -P)
  suffix=$(printf '%s' "${sandbox##*.}" | tr '[:upper:]' '[:lower:]')
  project_name=nas-platform-mac-$suffix
  printf 'schema=1\nproject=%s\n' "$project_name" > "$sandbox/.nas-platform-mac-owned"
  chmod 0600 "$sandbox/.nas-platform-mac-owned"
  mkdir -p "$sandbox/service-data/docker" "$sandbox/service-data/media" \
    "$sandbox/fixtures"
fi

suffix=$(printf '%s' "${sandbox##*.}" | tr '[:upper:]' '[:lower:]')
project_name=nas-platform-mac-$suffix
report_root=$sandbox.reports
if [ ! -e "$report_root" ]; then
  mkdir "$report_root"
  chmod 0700 "$report_root"
  printf 'schema=1\nsandbox=%s\n' "$(basename -- "$sandbox")" \
    > "$report_root/.nas-platform-mac-report-owned"
  chmod 0600 "$report_root/.nas-platform-mac-report-owned"
fi
[ -d "$report_root" ] && [ ! -L "$report_root" ] &&
  [ "$(mac_owner_id "$report_root")" = "$(id -u)" ] &&
  [ "$(mac_file_mode "$report_root")" = 700 ] ||
  mac_die 'report root is unavailable or unsafe'
report_marker=$report_root/.nas-platform-mac-report-owned
[ -f "$report_marker" ] && [ ! -L "$report_marker" ] &&
  [ "$(mac_owner_id "$report_marker")" = "$(id -u)" ] &&
  [ "$(mac_file_mode "$report_marker")" = 600 ] &&
  grep -qx 'schema=1' "$report_marker" &&
  grep -qx "sandbox=$(basename -- "$sandbox")" "$report_marker" ||
  mac_die 'report root ownership marker is missing or invalid'

protected_input_root=$sandbox/protected-inputs
if [ ! -e "$protected_input_root" ]; then
  mkdir -m 0700 "$protected_input_root"
fi
[ -d "$protected_input_root" ] && [ ! -L "$protected_input_root" ] &&
  [ "$(mac_owner_id "$protected_input_root")" = "$(id -u)" ] &&
  [ "$(mac_file_mode "$protected_input_root")" = 700 ] ||
  mac_die 'protected input directory is unavailable or unsafe'

pin_protected_input() {
  pin_source=$1
  pin_destination=$2
  pin_label=$3
  pin_kind=$4
  pin_external=$5
  ruby - "$pin_source" "$pin_destination" "$pin_label" "$pin_kind" \
    "$pin_external" "$mac_repo_dir" "$protected_input_root" <<'RUBY'
source_path, destination_path, label, kind, external, repository, protected_root = ARGV
require "open3"
require "rbconfig"
require "timeout"

maximum_size = kind == "vault" ? 16 * 1024 * 1024 : 1024 * 1024

def fail_pin(label, detail)
  warn "protected #{label} input #{detail}"
  exit 1
end

def signature(stat)
  [stat.dev, stat.ino, stat.size, stat.mode, stat.mtime.to_r, stat.ctime.to_r]
end

def identity(stat)
  [stat.dev, stat.ino, stat.mode, stat.uid]
end

def terminate_group(pid, signal)
  Process.kill(signal, -pid)
rescue Errno::ESRCH
  nil
end

def bounded_read(stream, maximum_size)
  bytes = stream.read(maximum_size + 1) || ""
  stream.close if bytes.bytesize > maximum_size
  { bytes: bytes, failed: false }
rescue IOError
  { bytes: "", failed: true }
end

def execute_provider(directory, basename, provider_bytes, maximum_size)
  result = {
    output: "", success: false, timed_out: false, oversized: false,
    capture_failed: false, unsupported: false, contains_nul: false
  }
  unless provider_bytes.lines.first == "#!/bin/sh\n"
    result[:unsupported] = true
    return result
  end
  if provider_bytes.include?("\0")
    result[:contains_nul] = true
    return result
  end
  directory_descriptor = directory.fileno
  directory.close_on_exec = false
  # Buffer the inspected bytes from an anonymous pipe before evaluating them.
  # The sentinel prevents command substitution from stripping trailing newlines.
  provider_command = <<~'PROVIDER_COMMAND'
    provider_script=$(cat && printf '\036') || exit 70
    provider_script=${provider_script%?}
    exec </dev/null || exit 70
    eval "$provider_script"
  PROVIDER_COMMAND
  launcher = <<~'PROVIDER_LAUNCHER'
    directory_descriptor = Integer(ARGV.fetch(0), 10)
    basename = ARGV.fetch(1)
    provider_command = ARGV.fetch(2)
    directory = IO.for_fd(directory_descriptor)
    Dir.fchdir(directory.fileno)
    directory.close
    exec(["/bin/sh", "/bin/sh"], "-c", provider_command, "./#{basename}")
  PROVIDER_LAUNCHER
  spawn_options = { pgroup: true, directory_descriptor => directory_descriptor }
  Open3.popen3(
    [RbConfig.ruby, RbConfig.ruby], "-e", launcher,
    directory_descriptor.to_s, basename, provider_command, spawn_options
  ) do |stdin, stdout, stderr, wait_thread|
    writer = Thread.new do
      begin
        stdin.write(provider_bytes)
        { failed: false }
      rescue IOError, SystemCallError
        { failed: true }
      ensure
        stdin.close unless stdin.closed?
      end
    end
    stdout_reader = Thread.new { bounded_read(stdout, maximum_size) }
    stderr_reader = Thread.new { bounded_read(stderr, 64 * 1024) }
    stdout_reader.report_on_exception = false
    stderr_reader.report_on_exception = false
    writer.report_on_exception = false
    reader_cleanup_failed = false
    writer_cleanup_failed = false
    begin
      status = Timeout.timeout(5) { wait_thread.value }
      result[:success] = status.success?
    rescue Timeout::Error
      result[:timed_out] = true
      terminate_group(wait_thread.pid, "TERM")
      unless wait_thread.join(1)
        terminate_group(wait_thread.pid, "KILL")
        wait_thread.join
      end
    ensure
      unless writer.join(1)
        writer_cleanup_failed = true
        stdin.close unless stdin.closed?
        terminate_group(wait_thread.pid, "TERM")
        terminate_group(wait_thread.pid, "KILL") unless writer.join(1)
      end
      readers = [[stdout_reader, stdout], [stderr_reader, stderr]]
      readers.each do |reader, _stream|
        next if reader.join(1)

        reader_cleanup_failed = true
        terminate_group(wait_thread.pid, "TERM")
        readers.each { |_capture, stream| stream.close unless stream.closed? }
        terminate_group(wait_thread.pid, "KILL")
        break
      end
      readers.each do |reader, stream|
        stream.close unless stream.closed?
        reader.kill unless reader.join(1)
        reader.join
      end
      writer.kill unless writer.join(1)
      writer.join
    end
    writer_capture = writer.value || { failed: true }
    stdout_capture = stdout_reader.value || { bytes: "", failed: true }
    stderr_capture = stderr_reader.value || { bytes: "", failed: true }
    result[:output] = stdout_capture[:bytes]
    result[:capture_failed] = writer_cleanup_failed || writer_capture[:failed] ||
                              reader_cleanup_failed || stdout_capture[:failed] || stderr_capture[:failed]
    result[:oversized] = result[:output].bytesize > maximum_size ||
                         stderr_capture[:bytes].bytesize > 64 * 1024
  end
  result
rescue SystemCallError, IOError
  result
end

temporary_path = nil
parent_directory = nil
source = nil
begin
  fail_pin(label, "cannot be pinned safely") unless
    File.const_defined?(:NOFOLLOW) && File.const_defined?(:NONBLOCK) && Dir.respond_to?(:fchdir)
  source_path = File.expand_path(source_path)
  repository = File.realpath(repository)
  protected_root = File.expand_path(protected_root)
  destination_parent = File.expand_path(File.dirname(destination_path))
  protected_root_before = File.lstat(protected_root)
  fail_pin(label, "destination is unsafe") unless
    destination_parent == protected_root && protected_root_before.directory? &&
      protected_root_before.uid == Process.uid && (protected_root_before.mode & 0o777) == 0o700 &&
      File.realpath(protected_root) == protected_root
  parent_path = File.dirname(source_path)
  basename = File.basename(source_path)
  fail_pin(label, "cannot be pinned safely") if [".", ".."].include?(basename)
  parent_before = File.realpath(parent_path)
  if external == "true" &&
     (parent_before == repository || parent_before.start_with?(repository + File::SEPARATOR))
    fail_pin(label, "must remain outside the repository")
  end

  flags = File::RDONLY | File::NOFOLLOW | File::NONBLOCK
  parent_path_before = File.lstat(parent_path)
  canonical_parent_before = File.lstat(parent_before)
  parent_directory = File.open(parent_before, flags)
  parent_descriptor_before = parent_directory.stat
  fail_pin(label, "changed while being pinned") unless
    parent_descriptor_before.directory? &&
      identity(canonical_parent_before) == identity(parent_descriptor_before)
  path_before = File.lstat(source_path)
  held_path_before = Dir.fchdir(parent_directory.fileno) { File.lstat("./#{basename}") }
  fail_pin(label, "must be a regular non-symlink file") unless
    path_before.file? && held_path_before.file?
  fail_pin(label, "changed while being pinned") unless
    signature(path_before) == signature(held_path_before)
  bytes = nil
  executable = false
  source = Dir.fchdir(parent_directory.fileno) { File.open("./#{basename}", flags) }
  descriptor_before = source.stat
  fail_pin(label, "changed while being pinned") unless
    descriptor_before.file? && signature(path_before) == signature(descriptor_before)
  fail_pin(label, "exceeds the size limit") if descriptor_before.size > maximum_size
  executable = (descriptor_before.mode & 0o111).positive?
  bytes = source.read(maximum_size + 1)
  fail_pin(label, "exceeds the size limit") if bytes.bytesize > maximum_size
  descriptor_after = source.stat
  fail_pin(label, "changed while being pinned") unless
    signature(descriptor_before) == signature(descriptor_after)

  parent_after = File.realpath(parent_path)
  parent_path_after = File.lstat(parent_path)
  canonical_parent_after = File.lstat(parent_before)
  parent_descriptor_after = parent_directory.stat
  path_after = File.lstat(source_path)
  held_path_after = Dir.fchdir(parent_directory.fileno) { File.lstat("./#{basename}") }
  fail_pin(label, "changed while being pinned") unless
    parent_before == parent_after &&
      identity(parent_path_before) == identity(parent_path_after) &&
      identity(canonical_parent_before) == identity(canonical_parent_after) &&
      identity(parent_descriptor_before) == identity(parent_descriptor_after) &&
      signature(path_before) == signature(path_after) &&
      signature(path_before) == signature(held_path_after)
  if kind == "password" && executable
    source.close
    source = nil
    provider = execute_provider(parent_directory, basename, bytes, maximum_size)
    provider_parent_after = File.realpath(parent_path)
    provider_parent_path_after = File.lstat(parent_path)
    provider_canonical_parent_after = File.lstat(parent_before)
    provider_parent_descriptor_after = parent_directory.stat
    provider_path_after = File.lstat(source_path)
    provider_held_path_after = Dir.fchdir(parent_directory.fileno) { File.lstat("./#{basename}") }
    fail_pin(label, "changed while being pinned") unless
      parent_before == provider_parent_after &&
        identity(parent_path_before) == identity(provider_parent_path_after) &&
        identity(canonical_parent_before) == identity(provider_canonical_parent_after) &&
        identity(parent_descriptor_before) == identity(provider_parent_descriptor_after) &&
        signature(path_before) == signature(provider_path_after) &&
        signature(path_before) == signature(provider_held_path_after)
    fail_pin(label, "provider timed out") if provider[:timed_out]
    fail_pin(label, "provider output exceeds the size limit") if provider[:oversized]
    fail_pin(label, "provider must use the exact #!/bin/sh executable format") if provider[:unsupported]
    fail_pin(label, "provider contains unsupported NUL bytes") if provider[:contains_nul]
    fail_pin(label, "provider failed") unless provider[:success] && !provider[:capture_failed]
    bytes = provider[:output]
  end
  if source
    source.close
    source = nil
  end
  parent_directory.close
  parent_directory = nil
  if kind == "vault" && !bytes.start_with?("$ANSIBLE_VAULT;")
    fail_pin(label, "is not Ansible Vault encrypted")
  end

  protected_root_after = File.lstat(protected_root)
  fail_pin(label, "destination is unsafe") unless
    signature(protected_root_before) == signature(protected_root_after) &&
      File.realpath(protected_root) == protected_root
  mode = 0o600
  temporary_path = "#{destination_path}.tmp.#{Process.pid}"
  output_flags = File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW
  File.open(temporary_path, output_flags, mode) do |output|
    output.write(bytes)
    output.flush
    output.fsync
  end
  File.chmod(mode, temporary_path)
  File.rename(temporary_path, destination_path)
  temporary_path = nil
  protected_root_final = File.lstat(protected_root)
  destination_final = File.lstat(destination_path)
  fail_pin(label, "destination is unsafe") unless
    [protected_root_final.dev, protected_root_final.ino, protected_root_final.mode,
     protected_root_final.uid] ==
      [protected_root_before.dev, protected_root_before.ino, protected_root_before.mode,
       protected_root_before.uid] &&
      File.realpath(protected_root) == protected_root && destination_final.file? &&
      (destination_final.mode & 0o777) == mode && destination_final.uid == Process.uid
rescue SystemCallError, IOError, ArgumentError
  fail_pin(label, "changed while being pinned")
ensure
  source.close if source && !source.closed?
  parent_directory.close if parent_directory && !parent_directory.closed?
  File.unlink(temporary_path) if temporary_path && File.file?(temporary_path) && !File.symlink?(temporary_path)
end
RUBY
}

deployment_vault_source=$vault_file
deployment_password_source=$vault_password_file
pin_protected_input "$deployment_vault_source" "$protected_input_root/deployment-vault.yml" \
  'deployment vault' vault false || mac_die 'protected deployment vault input could not be pinned'
pin_protected_input "$deployment_password_source" "$protected_input_root/deployment-password" \
  'deployment password' password true || mac_die 'protected deployment password input could not be pinned'
vault_file=$protected_input_root/deployment-vault.yml
vault_password_file=$protected_input_root/deployment-password
if [ "$lane" = adoption ]; then
  parity_vault_source=$parity_vault_file
  parity_password_source=$parity_vault_password_file
  pin_protected_input "$parity_vault_source" "$protected_input_root/parity-vault.yml" \
    'parity vault' vault true || mac_die 'protected parity vault input could not be pinned'
  if [ "$parity_password_source" = "$deployment_password_source" ]; then
    pin_protected_input "$vault_password_file" "$protected_input_root/parity-password" \
      'parity password' password false || mac_die 'protected parity password input could not be pinned'
  else
    pin_protected_input "$parity_password_source" "$protected_input_root/parity-password" \
      'parity password' password true || mac_die 'protected parity password input could not be pinned'
  fi
  parity_vault_file=$protected_input_root/parity-vault.yml
  parity_vault_password_file=$protected_input_root/parity-password
fi
state_input=$report_root/phase-input.json

git_revision=$(git -C "$mac_repo_dir" rev-parse HEAD)
vault_checksum=$(shasum -a 256 "$vault_file" | awk '{print $1}')
parity_vault_checksum=
legacy_commit=
if [ "$lane" = adoption ]; then
  parity_vault_checksum=$(shasum -a 256 "$parity_vault_file" | awk '{print $1}')
  legacy_commit=$(ruby -ryaml -e '
    manifest = YAML.safe_load_file(ARGV.fetch(0))
    print manifest.fetch("legacy_source").fetch("commit")
  ' "$mac_repo_dir/services/manifest.yml") || mac_die 'could not read the pinned legacy commit'
  [ "${#legacy_commit}" -eq 40 ] ||
    mac_die 'pinned legacy commit must be a lowercase 40-character Git SHA'
  case $legacy_commit in
    *[!0123456789abcdef]*) mac_die 'pinned legacy commit must be a lowercase 40-character Git SHA' ;;
  esac
fi

allocate_service_port() {
  while :; do
    candidate_port=$(ruby -rsocket -e 'server = TCPServer.new("127.0.0.1", 0); print server.addr[1]; server.close')
    candidate_available=true
    for allocated_port in "$@"; do
      [ "$candidate_port" = "$allocated_port" ] && candidate_available=false
    done
    if [ "$candidate_available" = true ]; then
      printf '%s\n' "$candidate_port"
      return 0
    fi
  done
}

initialize_report_input() {
  "$mac_script_dir/report.rb" --init "$state_input" --lane "$lane" \
    --sandbox-id "$(basename -- "$sandbox")" --git-revision "$git_revision" \
    --vault-checksum "$vault_checksum" --project-name "$project_name" \
    --beszel-port "$beszel_port" --ntfy-port "$ntfy_port" --dozzle-port "$dozzle_port" \
    --audiobookshelf-port "$audiobookshelf_port" --komga-port "$komga_port" \
    --tinymediamanager-web-port "$tinymediamanager_web_port" \
    --tinymediamanager-api-port "$tinymediamanager_api_port" \
    --jellyfin-port "$jellyfin_port" --immich-port "$immich_port" \
    --paperless-port "$paperless_port" "$@"
}

if [ ! -f "$state_input" ]; then
  beszel_port=$(allocate_service_port)
  ntfy_port=$(allocate_service_port "$beszel_port")
  dozzle_port=$(allocate_service_port "$beszel_port" "$ntfy_port")
  audiobookshelf_port=$(allocate_service_port "$beszel_port" "$ntfy_port" "$dozzle_port")
  komga_port=$(allocate_service_port \
    "$beszel_port" "$ntfy_port" "$dozzle_port" "$audiobookshelf_port")
  tinymediamanager_web_port=$(allocate_service_port \
    "$beszel_port" "$ntfy_port" "$dozzle_port" "$audiobookshelf_port" "$komga_port")
  tinymediamanager_api_port=$(allocate_service_port \
    "$beszel_port" "$ntfy_port" "$dozzle_port" "$audiobookshelf_port" "$komga_port" \
    "$tinymediamanager_web_port")
  jellyfin_port=$(allocate_service_port \
    "$beszel_port" "$ntfy_port" "$dozzle_port" "$audiobookshelf_port" "$komga_port" \
    "$tinymediamanager_web_port" "$tinymediamanager_api_port")
  immich_port=$(allocate_service_port \
    "$beszel_port" "$ntfy_port" "$dozzle_port" "$audiobookshelf_port" "$komga_port" \
    "$tinymediamanager_web_port" "$tinymediamanager_api_port" "$jellyfin_port")
  paperless_port=$(allocate_service_port \
    "$beszel_port" "$ntfy_port" "$dozzle_port" "$audiobookshelf_port" "$komga_port" \
    "$tinymediamanager_web_port" "$tinymediamanager_api_port" "$jellyfin_port" "$immich_port")
  if [ "$lane" = adoption ]; then
    initialize_report_input --parity-vault-checksum "$parity_vault_checksum" \
      --legacy-commit "$legacy_commit"
  else
    initialize_report_input
  fi
else
  state_lane=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("lane")' "$state_input")
  state_git_revision=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("git_revision")' "$state_input")
  state_vault_checksum=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("vault_checksum")' "$state_input")
  state_parity_vault_checksum=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("parity_vault_checksum")' "$state_input")
  state_legacy_commit=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("legacy_commit")' "$state_input")
  state_project_name=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("project_name")' "$state_input")
  beszel_port=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("beszel_port")' "$state_input")
  ntfy_port=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("ntfy_port")' "$state_input")
  dozzle_port=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("dozzle_port")' "$state_input")
  audiobookshelf_port=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("audiobookshelf_port")' "$state_input")
  komga_port=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("komga_port")' "$state_input")
  tinymediamanager_web_port=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("tinymediamanager_web_port")' "$state_input")
  tinymediamanager_api_port=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("tinymediamanager_api_port")' "$state_input")
  jellyfin_port=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("jellyfin_port")' "$state_input")
  immich_port=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("immich_port")' "$state_input")
  paperless_port=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("paperless_port")' "$state_input")
  [ "$state_lane" = "$lane" ] || mac_die 'resume lane does not match the recorded lane'
  [ "$state_project_name" = "$project_name" ] ||
    mac_die 'resume project namespace does not match the recorded run'
  [ "$state_git_revision" = "$git_revision" ] ||
    mac_die 'resume Git revision does not match the recorded run'
  [ "$state_vault_checksum" = "$vault_checksum" ] ||
    mac_die 'resume vault checksum does not match the recorded run'
  [ "$state_parity_vault_checksum" = "$parity_vault_checksum" ] ||
    mac_die 'resume parity vault checksum does not match the recorded run'
  [ "$state_legacy_commit" = "$legacy_commit" ] ||
    mac_die 'resume legacy commit does not match the recorded run'
fi

export PLATFORM_MAC_SANDBOX=$sandbox
export PLATFORM_DOCKER_ROOT=$sandbox/service-data/docker
export PLATFORM_MEDIA_ROOT=$sandbox/service-data/media
export PLATFORM_FIXTURE_ROOT=$sandbox/fixtures
export PLATFORM_REPORT_ROOT=$report_root
export PLATFORM_PROOF_LANE=$lane
export PLATFORM_PROJECT_NAME=$project_name
export PLATFORM_BESZEL_PORT=$beszel_port
export PLATFORM_NTFY_PORT=$ntfy_port
export PLATFORM_DOZZLE_PORT=$dozzle_port
export PLATFORM_AUDIOBOOKSHELF_PORT=$audiobookshelf_port
export PLATFORM_KOMGA_PORT=$komga_port
export PLATFORM_TINYMEDIAMANAGER_WEB_PORT=$tinymediamanager_web_port
export PLATFORM_TINYMEDIAMANAGER_API_PORT=$tinymediamanager_api_port
export PLATFORM_JELLYFIN_PORT=$jellyfin_port
export PLATFORM_IMMICH_PORT=$immich_port
export PLATFORM_PAPERLESS_PORT=$paperless_port
export COMPOSE_PROJECT_NAME=$project_name
export PLATFORM_MAC_VAULT_FILE=$vault_file
export PLATFORM_MAC_VAULT_PASSWORD_FILE=$vault_password_file
export PLATFORM_MAC_PARITY_VAULT_FILE=$parity_vault_file
export PLATFORM_MAC_PARITY_VAULT_PASSWORD_FILE=$parity_vault_password_file
export PLATFORM_VAULT_FILE=$vault_file

run_site() {
  run_site_status=0
  ansible-playbook -i "$mac_repo_dir/inventory/mac.yml" "$mac_repo_dir/site.yml" \
    --vault-password-file "$vault_password_file" -e @"$vault_file" \
    -e "platform_vault_file=$vault_file" "$@" || run_site_status=$?
  if [ "$lane" = adoption ]; then
    attestation_status=0
    "$mac_script_dir/adoption-container-attest.sh" || attestation_status=$?
    if [ "$run_site_status" -eq 0 ] && [ "$attestation_status" -ne 0 ]; then
      run_site_status=$attestation_status
    fi
    if [ "$run_site_status" -ne 0 ]; then
      "$mac_script_dir/adoption-stop-targets.sh" >/dev/null 2>&1 || true
    fi
  fi
  return "$run_site_status"
}

enable_adoption_mapping() {
  adoption_mapping_stage=$1
  case $adoption_mapping_stage in
    cutover)
      "$mac_script_dir/adoption.sh" cutover || return $?
      adoption_marker_action=marker-post-cutover
      ;;
    resume) adoption_marker_action=marker-post-cutover ;;
    *) mac_die 'invalid adoption mapping stage' ;;
  esac
  export PLATFORM_ADOPTION_ENABLED=true
  export PLATFORM_ADOPTION_ROOT=$sandbox
  PLATFORM_ADOPTION_MARKER=$("$mac_script_dir/adoption-snapshot.sh" "$adoption_marker_action" \
    --override-root "$mac_script_dir/legacy-overrides" \
    --baseline "$sandbox/baseline.json" --run-state "$report_root/phase-input.json") ||
    { mac_die 'could not bind the adoption mapping marker'; return 1; }
  case $PLATFORM_ADOPTION_MARKER in
    ''|*[!0123456789abcdef]*)
      mac_die 'adoption mapping marker is invalid'
      return 1
      ;;
  esac
  [ "${#PLATFORM_ADOPTION_MARKER}" -eq 64 ] || {
    mac_die 'adoption mapping marker is invalid'
    return 1
  }
  export PLATFORM_ADOPTION_MARKER
}

run_idempotence() {
  idempotence_output=$(mktemp "$report_root/idempotence.XXXXXX")
  if run_site >"$idempotence_output" 2>&1; then
    idempotence_status=0
  else
    idempotence_status=$?
  fi
  cat "$idempotence_output"
  if [ "$idempotence_status" -ne 0 ] ||
     ! grep -qE 'changed=0 .*failed=0 ' "$idempotence_output"; then
    rm -f -- "$idempotence_output"
    if [ "$lane" = adoption ]; then
      "$mac_script_dir/adoption-stop-targets.sh" >/dev/null 2>&1 || true
    fi
    return 1
  fi
  rm -f -- "$idempotence_output"
}

run_persistence() {
  persistence_status=0
  "$mac_script_dir/fixtures.sh" persistence || persistence_status=$?
  if [ "$persistence_status" -eq 0 ] && [ "$lane" = adoption ]; then
    "$mac_script_dir/adoption.sh" verify || persistence_status=$?
  fi
  if [ "$persistence_status" -ne 0 ] && [ "$lane" = adoption ]; then
    "$mac_script_dir/adoption-stop-targets.sh" >/dev/null 2>&1 || true
  fi
  return "$persistence_status"
}

verify_target_state() {
  target_verify_status=0
  "$mac_script_dir/verify.sh" || target_verify_status=$?
  if [ "$target_verify_status" -eq 0 ] && [ "$lane" = adoption ]; then
    "$mac_script_dir/adoption.sh" verify || target_verify_status=$?
  fi
  if [ "$target_verify_status" -ne 0 ] && [ "$lane" = adoption ]; then
    "$mac_script_dir/adoption-stop-targets.sh" >/dev/null 2>&1 || true
  fi
  return "$target_verify_status"
}

render_report() {
  deployment_manifest=$PLATFORM_DOCKER_ROOT/nas-platform/current/manifest.yml
  if [ -f "$deployment_manifest" ] && [ ! -L "$deployment_manifest" ]; then
    "$mac_script_dir/report.rb" --input "$state_input" \
      --json "$report_root/report.json" --markdown "$report_root/report.md" \
      --manifest "$deployment_manifest"
  else
    "$mac_script_dir/report.rb" --input "$state_input" \
      --json "$report_root/report.json" --markdown "$report_root/report.md"
  fi
}

capture_diagnostics() {
  diagnostic_name=container-state.jsonl
  diagnostic_temporary=$(mktemp "$report_root/container-state.XXXXXX") || return 1
  : > "$diagnostic_temporary"
  if for diagnostic_project in \
      "$project_name-beszel" "$project_name-ntfy" "$project_name-dozzle" \
      "$project_name-audiobookshelf" "$project_name-komga" "$project_name-tinymediamanager" \
      "$project_name-jellyfin" "$project_name-immich" "$project_name-paperless"; do
      docker ps -a --filter "label=com.docker.compose.project=$diagnostic_project" \
        --format '{"id":"{{.ID}}","image":"{{.Image}}","name":"{{.Names}}","status":"{{.Status}}"}' \
        >> "$diagnostic_temporary" || exit 1
    done; then
    mv -f -- "$diagnostic_temporary" "$report_root/$diagnostic_name" || {
      unlink "$diagnostic_temporary" >/dev/null 2>&1 || true
      return 1
    }
    "$mac_script_dir/report.rb" --diagnostic "$state_input" \
      --location "$diagnostic_name" || return 1

    diagnostic_container_ids=$(for diagnostic_project in \
        "$project_name-beszel" "$project_name-ntfy" "$project_name-dozzle" \
        "$project_name-audiobookshelf" "$project_name-komga" "$project_name-tinymediamanager" \
        "$project_name-jellyfin" "$project_name-immich" "$project_name-paperless"; do
      docker ps -aq --filter "label=com.docker.compose.project=$diagnostic_project" || exit 1
    done) || return 1
    for diagnostic_container_id in $diagnostic_container_ids; do
      diagnostic_container_name=$(docker inspect --format '{{.Name}}' \
        "$diagnostic_container_id" 2>/dev/null) || diagnostic_container_name=$diagnostic_container_id
      diagnostic_container_name=${diagnostic_container_name#/}
      diagnostic_log_name=container-log-$diagnostic_container_id.json
      if "$mac_script_dir/sanitize-logs.rb" \
          --container-id "$diagnostic_container_id" \
          --container-name "$diagnostic_container_name" \
          --output "$report_root/$diagnostic_log_name" --tail 200; then
        "$mac_script_dir/report.rb" --diagnostic "$state_input" \
          --location "$diagnostic_log_name" || return 1
      fi
    done
  else
    unlink "$diagnostic_temporary" >/dev/null 2>&1 || true
    return 1
  fi
}

execute_phase() {
  case $1 in
    preflight)
      [ "$(uname -s)" = Darwin ] || {
        mac_die 'Mac proof harness requires Darwin'
        return 1
      }
      command -v docker >/dev/null 2>&1 || {
        mac_die 'Docker is required'
        return 1
      }
      command -v ansible-playbook >/dev/null 2>&1 || {
        mac_die 'ansible-playbook is required'
        return 1
      }
      docker info >/dev/null 2>&1 || {
        mac_die 'Docker Desktop is unavailable'
        return 1
      }
      for reserved_name in \
        "$project_name-beszel" "$project_name-beszel-agent-intel" \
        "$project_name-beszel-agent-portable" "$project_name-beszel-socket-proxy" \
        "$project_name-ntfy" "$project_name-dozzle" "$project_name-dozzle-socket-proxy" \
        "$project_name-audiobookshelf" "$project_name-komga" \
        "$project_name-tinymediamanager" "$project_name-jellyfin" \
        "$project_name-immich-server" "$project_name-immich-machine-learning" \
        "$project_name-immich-redis" "$project_name-immich-postgres" \
        "$project_name-paperless-redis" "$project_name-paperless-postgres" \
        "$project_name-paperless-webserver" "$project_name-paperless-gotenberg" \
        "$project_name-paperless-tika"; do
        reserved_container_ids=$(docker ps -aq --filter "name=^/$reserved_name$") || {
          mac_die "could not inspect reserved container name: $reserved_name"
          return 1
        }
        [ -z "$reserved_container_ids" ] || {
          mac_die "reserved container name is already in use: $reserved_name"
          return 1
        }
      done
      for reserved_port in \
        "$beszel_port" "$ntfy_port" "$dozzle_port" "$audiobookshelf_port" "$komga_port" \
        "$tinymediamanager_web_port" "$tinymediamanager_api_port" "$jellyfin_port" \
        "$immich_port" "$paperless_port"; do
        reserved_port_container_ids=$(docker ps -q --filter "publish=$reserved_port") || {
          mac_die "could not inspect reserved host port: $reserved_port"
          return 1
        }
        [ -z "$reserved_port_container_ids" ] || {
          mac_die "reserved host port is already in use: $reserved_port"
          return 1
        }
      done
      ruby -rsocket -e '
        ARGV.each do |value|
          server = TCPServer.new("127.0.0.1", Integer(value, 10))
          server.close
        rescue SystemCallError
          warn "reserved host port is already in use: #{value}"
          exit 1
        end
      ' "$beszel_port" "$ntfy_port" "$dozzle_port" "$audiobookshelf_port" "$komga_port" \
        "$tinymediamanager_web_port" "$tinymediamanager_api_port" "$jellyfin_port" \
        "$immich_port" "$paperless_port" || return 1
      ansible-playbook "$mac_repo_dir/validate-vault.yml" \
        --vault-password-file "$vault_password_file" -e @"$vault_file" \
        -e "platform_vault_file=$vault_file"
      if [ "$lane" = adoption ]; then
        "$mac_script_dir/adoption.sh" render
      fi
      ;;
    deploy)
      [ "$lane" = fresh ] || mac_die 'deploy phase is available only in the fresh lane'
      run_site
      ;;
    legacy-deploy|legacy-seed|capture-baseline|snapshot|rollback)
      "$mac_script_dir/adoption.sh" "$1"
      ;;
    cutover)
      enable_adoption_mapping cutover || return $?
      run_site || return $?
      cutover_verify_status=0
      "$mac_script_dir/verify.sh" || cutover_verify_status=$?
      if [ "$cutover_verify_status" -ne 0 ]; then
        "$mac_script_dir/adoption-stop-targets.sh" >/dev/null 2>&1 || true
        return "$cutover_verify_status"
      fi
      ;;
    seed) "$mac_script_dir/fixtures.sh" seed ;;
    verify) verify_target_state ;;
    idempotence) run_idempotence ;;
    drift) "$mac_script_dir/drift.sh" ;;
    reconcile) run_site && "$mac_script_dir/verify.sh" ;;
    recreate) "$mac_script_dir/fixtures.sh" recreate && verify_target_state ;;
    persistence) run_persistence ;;
    report) render_report ;;
    cleanup) release_run_lock && "$mac_script_dir/cleanup.sh" "$sandbox" ;;
    *) mac_die "unknown phase: $1" ;;
  esac
}

phase_status() {
  ruby -rjson -e '
    input = JSON.parse(File.read(ARGV.fetch(0)))
    phase = input.fetch("phases").find { |entry| entry["name"] == ARGV.fetch(1) }
    print phase.fetch("status", "") if phase
  ' "$state_input" "$1"
}

require_predecessors() {
  [ "$1" = report ] || [ "$1" = cleanup ] || {
    for predecessor in $PHASES; do
      [ "$predecessor" = "$1" ] && break
      [ "$(phase_status "$predecessor")" = passed ] ||
        mac_die "phase $1 requires passed phase $predecessor"
    done
  }
}

run_phase() {
  current_phase=$1
  if [ "$(phase_status "$current_phase")" = passed ]; then
    printf 'Skipping completed phase: %s\n' "$current_phase"
    return 0
  fi
  require_predecessors "$current_phase"
  "$mac_script_dir/report.rb" --record "$state_input" \
    --phase "$current_phase" --status running
  printf '\n=== %s ===\n' "$current_phase"
  if execute_phase "$current_phase"; then
    "$mac_script_dir/report.rb" --record "$state_input" \
      --phase "$current_phase" --status passed
    if [ "$current_phase" = report ] || [ "$current_phase" = cleanup ]; then
      render_report
    fi
  else
    phase_exit_status=$?
    capture_diagnostics || true
    "$mac_script_dir/report.rb" --record "$state_input" \
      --phase "$current_phase" --status failed
    render_report
    return "$phase_exit_status"
  fi
}

if [ "$lane" = adoption ] && [ "$(phase_status cutover)" = passed ]; then
  enable_adoption_mapping resume
fi

if [ -n "$selected_phase" ]; then
  run_phase "$selected_phase"
else
  for phase in $PHASES; do
    run_phase "$phase"
  done
fi

if [ -d "$sandbox" ]; then
  printf 'Sandbox preserved at %s\n' "$sandbox"
  preserve_sandbox_on_exit=true
fi

# Preservation is already the default. Keeping the parsed flag explicit makes
# the CLI contract stable for automation that requests it defensively.
: "$keep_on_failure"
