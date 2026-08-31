#!/bin/sh
set -eu
set +x
umask 077

FRESH_PHASES=' preflight deploy seed verify idempotence drift reconcile recreate persistence report cleanup '

mac_script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_script_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"
. "$mac_repo_dir/tests/integration_lock.sh"

usage() {
  printf '%s\n' \
    'usage: run.sh --lane fresh --vault-file FILE --vault-password-file FILE_OR_EXECUTABLE' \
    '              [--platform mac|integration] [--integration-ports-file FILE]' \
    '              [--keep-on-failure] [--manual-validation] [--phase NAME] [--sandbox PATH]' \
    '--manual-validation stops a fresh full run after verify and prints a resumable handoff.' \
    'Executable password providers must use the exact #!/bin/sh shebang without options or NUL bytes.'
}

lane=
vault_file=
vault_password_file=
selected_phase=
requested_sandbox=
integration_ports_file=
keep_on_failure=false
manual_validation=false
[ -z "${PLATFORM_PROOF_PLATFORM+x}" ] ||
  mac_die 'reserved proof platform environment must be unset'
proof_platform=mac
[ -z "${RUBYOPT+x}" ] && [ -z "${RUBYLIB+x}" ] &&
  [ -z "${RUBYGEMS_GEMDEPS+x}" ] && [ -z "${GEM_HOME+x}" ] && [ -z "${GEM_PATH+x}" ] &&
  [ -z "${BUNDLE_GEMFILE+x}" ] && [ -z "${BUNDLE_BIN_PATH+x}" ] &&
  [ -z "${BUNDLE_PATH+x}" ] && [ -z "${BUNDLE_APP_CONFIG+x}" ] &&
  [ -z "${BUNDLE_WITH+x}" ] && [ -z "${BUNDLE_WITHOUT+x}" ] ||
  mac_die 'reserved language startup environment must be unset'
  [ -z "${PLATFORM_PROOF_CALLBACK_HOST+x}" ] &&
  [ -z "${PLATFORM_CALLBACK_HOST+x}" ] &&
  [ -z "${PLATFORM_MAC_FIXTURE_VARS_FILE+x}" ] &&
  [ -z "${PLATFORM_CONTRACT_REPO_DIR+x}" ] &&
  [ -z "${PLATFORM_KOMGA_CONFIG_PATH+x}" ] &&
  [ -z "${PLATFORM_SNAPSHOT_ESCAPE+x}" ] ||
  mac_die 'reserved proof environment must be unset'
while [ "$#" -gt 0 ]; do
  case $1 in
    --lane|--vault-file|--vault-password-file|--phase|--sandbox|--platform|--integration-ports-file)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      case $1 in
        --lane) lane=$2 ;;
        --vault-file) vault_file=$2 ;;
        --vault-password-file) vault_password_file=$2 ;;
        --phase) selected_phase=$2 ;;
        --sandbox) requested_sandbox=$2 ;;
        --platform) proof_platform=$2 ;;
        --integration-ports-file) integration_ports_file=$2 ;;
      esac
      shift 2
      ;;
    --keep-on-failure) keep_on_failure=true; shift ;;
    --manual-validation) manual_validation=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

if [ "$manual_validation" = true ]; then
  [ "$lane" = fresh ] || mac_die '--manual-validation requires --lane fresh'
  [ -z "$selected_phase" ] ||
    mac_die '--manual-validation requires a full run without --phase'
  [ "$keep_on_failure" = false ] ||
    mac_die '--manual-validation is incompatible with --keep-on-failure'
fi

case $proof_platform in
  mac) ;;
  integration)
    [ -n "$integration_ports_file" ] ||
      mac_die 'integration platform requires --integration-ports-file'
    ;;
  *) mac_die 'unknown proof platform' ;;
esac
[ "$proof_platform" = integration ] || [ -z "$integration_ports_file" ] ||
  mac_die 'integration ports are available only with the integration platform'
export PLATFORM_PROOF_PLATFORM=$proof_platform

case $lane in
  fresh) PHASES=$FRESH_PHASES ;;
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

canonical_input_path() {
  input_parent=$(CDPATH= cd -- "$(dirname -- "$1")" 2>/dev/null && pwd -P) ||
    mac_die "$2 parent is unavailable"
  printf '%s/%s\n' "${input_parent%/}" "$(basename -- "$1")"
}

vault_file=$(canonical_input_path "$vault_file" 'vault file')
vault_password_file=$(canonical_input_path "$vault_password_file" 'vault password input')


if [ -n "$selected_phase" ]; then
  case "$PHASES" in *" $selected_phase "*) ;; *) mac_die "unknown phase: $selected_phase" ;; esac
fi

temporary_parent=$(mac_temporary_parent)
acquire_integration_lock "$temporary_parent"
sandbox=
preserve_sandbox_on_exit=false
manual_vault_plaintext=

remove_manual_vault_plaintext() {
  [ -n "$manual_vault_plaintext" ] || return 0
  case $manual_vault_plaintext in
    "${protected_input_root-}"/.manual-validation-vault.??????) ;;
    *) mac_die 'refusing to remove unsafe manual-validation plaintext path'; return 1 ;;
  esac
  if [ -e "$manual_vault_plaintext" ] || [ -L "$manual_vault_plaintext" ]; then
    unlink "$manual_vault_plaintext" || return 1
  fi
  manual_vault_plaintext=
}

release_run_lock() {
  [ -z "$integration_lock_path" ] || release_integration_lock
}

on_run_exit() {
  mac_exit_status=$?
  trap - EXIT HUP INT TERM
  if ! remove_manual_vault_plaintext; then
    [ "$mac_exit_status" -ne 0 ] || mac_exit_status=1
  fi
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

state_input=$report_root/phase-input.json
manual_resume_marker=$report_root/manual-validation-resume.json
reuse_protected_inputs=false
if [ -e "$manual_resume_marker" ] || [ -L "$manual_resume_marker" ]; then
  "$mac_script_dir/manual-validation-handoff.rb" --validate-resume \
    --state "$state_input" --marker "$manual_resume_marker" --lane "$lane" \
    --sandbox "$sandbox" --report-root "$report_root" \
    --vault-file "$vault_file" --vault-password-file "$vault_password_file" ||
    mac_die 'manual-validation resume binding is invalid'
  reuse_protected_inputs=true
fi

pin_protected_input() {
  pin_source=$1
  pin_destination=$2
  pin_label=$3
  pin_kind=$4
  pin_external=$5
  pin_reuse=$6
  # The 313-line Ruby program this used to pipe in from a quoted heredoc is now
  # pin-protected-input.rb, where sh -n, a linter and a unit test can all reach
  # it. Its stdin was that heredoc, exhausted by the time the program ran; keep
  # stdin at end-of-file so the pin can never consume the caller's.
  "$mac_script_dir/pin-protected-input.rb" "$pin_source" "$pin_destination" "$pin_label" \
    "$pin_kind" "$pin_external" "$mac_repo_dir" "$protected_input_root" "$pin_reuse" \
    </dev/null
}

deployment_vault_source=$vault_file
deployment_password_source=$vault_password_file
pin_protected_input "$deployment_vault_source" "$protected_input_root/deployment-vault.yml" \
  'deployment vault' vault false "$reuse_protected_inputs" ||
  mac_die 'protected deployment vault input could not be pinned'
pin_protected_input "$deployment_password_source" "$protected_input_root/deployment-password" \
  'deployment password' password true "$reuse_protected_inputs" ||
  mac_die 'protected deployment password input could not be pinned'
vault_file=$protected_input_root/deployment-vault.yml
vault_password_file=$protected_input_root/deployment-password
generate_immich_fixture_vars() {
  fixture_output=$1
  fixture_temporary=$(mktemp "$protected_input_root/.immich-fixture-vars.XXXXXX") || return 1
  if ! ansible-vault view --vault-password-file "$vault_password_file" "$vault_file" 2>/dev/null |
      ruby "$mac_script_dir/generate-immich-fixture-vars.rb" \
        "$fixture_temporary" "$mac_repo_dir/inventory/group_vars/all/main.yml" 2>/dev/null
  then
    unlink "$fixture_temporary" >/dev/null 2>&1 || true
    return 1
  fi
  chmod 0600 "$fixture_temporary" || {
    unlink "$fixture_temporary" >/dev/null 2>&1 || true
    return 1
  }
  mv -f -- "$fixture_temporary" "$fixture_output"
}

fixture_vars_file=$protected_input_root/immich-fixture-vars.yml
immich_fixture_vars_verified=false
ensure_immich_fixture_vars() {
  [ "$immich_fixture_vars_verified" = false ] || return 0
  if [ -e "$fixture_vars_file" ]; then
    expected_fixture_vars=$(mktemp "$protected_input_root/.immich-fixture-expected.XXXXXX") || return 1
    if ! generate_immich_fixture_vars "$expected_fixture_vars" ||
       ! cmp -s "$expected_fixture_vars" "$fixture_vars_file"; then
      unlink "$expected_fixture_vars" >/dev/null 2>&1 || true
      mac_die 'protected Immich fixture policy differs from the pinned deployment vault'
      return 1
    fi
    unlink "$expected_fixture_vars" >/dev/null 2>&1 || true
  else
    generate_immich_fixture_vars "$fixture_vars_file" ||
      mac_die 'protected Immich fixture policy could not be generated'
  fi
  [ -f "$fixture_vars_file" ] && [ ! -L "$fixture_vars_file" ] &&
    [ "$(mac_owner_id "$fixture_vars_file")" = "$(id -u)" ] &&
    [ "$(mac_file_mode "$fixture_vars_file")" = 600 ] ||
    mac_die 'protected Immich fixture policy is unsafe'
  immich_fixture_vars_verified=true
}
git_revision=$(git -C "$mac_repo_dir" rev-parse HEAD)
vault_checksum=$(shasum -a 256 "$vault_file" | awk '{print $1}')
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

# Emits one decimal port per roster service, in roster order, from a validated
# ports file. The roster arrives as arguments rather than as a literal list so
# that the emission order and the order the caller unpacks are the same list.
read_integration_ports() {
  # shellcheck disable=SC2086
  ruby -rjson - "$integration_ports_file" "$mac_repo_dir" $MAC_SERVICE_PORT_ORDER <<'RUBY'
path, repository, *services = ARGV
expected = services.map { |service| "#{service}_port" }
raise "unsafe" if expected.empty? || expected.uniq.length != expected.length
flags = File::RDONLY
flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
raise "unsafe" unless File.absolute_path(path) == path && !File.symlink?(path)
parent = File.realpath(File.dirname(path))
repository = File.realpath(repository)
raise "unsafe" if parent == repository || parent.start_with?(repository + File::SEPARATOR)
before = File.lstat(path)
raise "unsafe" unless before.file? && before.uid == Process.uid &&
  (before.mode & 0o777) == 0o600 && before.size <= 4096
bytes = File.open(path, flags) do |input|
  held = input.stat
  raise "unsafe" unless [held.dev, held.ino, held.size, held.mode, held.uid] ==
    [before.dev, before.ino, before.size, before.mode, before.uid]
  value = input.read(4097)
  raise "unsafe" if value.bytesize > 4096
  after = input.stat
  raise "unsafe" unless [after.dev, after.ino, after.size, after.mode, after.uid, after.mtime.to_r, after.ctime.to_r] ==
    [held.dev, held.ino, held.size, held.mode, held.uid, held.mtime.to_r, held.ctime.to_r]
  value
end
document = JSON.parse(bytes)
raise "unsafe" unless document.is_a?(Hash) && document.keys.sort == (["schema"] + expected).sort &&
  document["schema"] == 1
ports = expected.map { |name| document.fetch(name) }
raise "unsafe" unless ports.all? { |port| port.is_a?(Integer) && port.between?(1024, 65_535) } &&
  ports.uniq.length == ports.length
puts ports.join(" ")
RUBY
}

if [ "$proof_platform" = integration ]; then
  integration_ports=$(read_integration_ports) || mac_die 'integration ports input is invalid'
  # The validated representation contains one decimal integer per roster service,
  # in roster order, because read_integration_ports emitted it from this same
  # list. The length check keeps a short list from binding services to nothing.
  # shellcheck disable=SC2086
  set -- $integration_ports
  [ "$#" -eq "$(mac_service_port_count)" ] || mac_die 'integration ports input is invalid'
  for mac_roster_service in $MAC_SERVICE_PORT_ORDER; do
    eval "expected_${mac_roster_service}_port=\$1"
    shift
  done
  callback_host=$(mac_integration_gateway) || mac_die 'integration callback host is invalid'
else
  callback_host=host.docker.internal
fi

# report.rb names one --<service>-port option per roster service, so the flag
# list is the roster spelled with hyphens. The caller's own arguments are
# appended to, never replaced: OptionParser is order-insensitive across distinct
# options, so they may sit before the port flags.
initialize_report_input() {
  for mac_roster_service in $MAC_SERVICE_PORT_ORDER; do
    eval "set -- \"\$@\" --$mac_roster_service-port \"\${${mac_roster_service}_port:?${mac_roster_service}_port is required}\""
  done
  "$mac_script_dir/report.rb" --init "$state_input" --lane "$lane" \
    --proof-platform "$proof_platform" \
    --callback-host "$callback_host" \
    --sandbox-id "$(basename -- "$sandbox")" --git-revision "$git_revision" \
    --vault-checksum "$vault_checksum" --project-name "$project_name" "$@"
}

if [ ! -f "$state_input" ]; then
  if [ "$proof_platform" = integration ]; then
    for mac_roster_service in $MAC_SERVICE_PORT_ORDER; do
      eval "${mac_roster_service}_port=\$expected_${mac_roster_service}_port"
    done
  else
    # Each allocation is told every port already handed out, so the cascade that
    # used to repeat the growing argument list by hand -- fourteen arguments on
    # the last call -- is now one accumulator threaded through the roster.
    mac_allocated_ports=
    for mac_roster_service in $MAC_SERVICE_PORT_ORDER; do
      # shellcheck disable=SC2086
      mac_next_port=$(allocate_service_port $mac_allocated_ports)
      eval "${mac_roster_service}_port=\$mac_next_port"
      mac_allocated_ports="$mac_allocated_ports $mac_next_port"
    done
  fi
  initialize_report_input
else
  state_lane=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("lane")' "$state_input")
  state_proof_platform=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("proof_platform", "mac")' "$state_input")
  state_platform_kind=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("platform_kind", "mac")' "$state_input")
  state_platform_compose_kind=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("platform_compose_kind", "mac")' "$state_input")
  state_callback_host=$(ruby -rjson -e 'input = JSON.parse(File.read(ARGV.fetch(0))); print input.fetch("callback_host", input.fetch("proof_platform", "mac") == "mac" ? "host.docker.internal" : "")' "$state_input")
  state_git_revision=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("git_revision")' "$state_input")
  state_vault_checksum=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("vault_checksum")' "$state_input")
  state_project_name=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("project_name")' "$state_input")
  # One interpreter start-up for every roster port, instead of one per service.
  # `set --` rather than a pipe: in POSIX sh the right side of a pipe is a
  # subshell and the assignments would evaporate with it.
  state_ports=$(
    # shellcheck disable=SC2086
    ruby -rjson - "$state_input" $MAC_SERVICE_PORT_ORDER <<'RUBY'
path, *services = ARGV
document = JSON.parse(File.read(path))
puts services.map { |service| document.fetch("#{service}_port") }.join(" ")
RUBY
  ) || mac_die 'resume state input does not record the service ports'
  # shellcheck disable=SC2086
  set -- $state_ports
  [ "$#" -eq "$(mac_service_port_count)" ] ||
    mac_die 'resume state input does not record the service ports'
  for mac_roster_service in $MAC_SERVICE_PORT_ORDER; do
    eval "${mac_roster_service}_port=\$1"
    shift
  done
  [ "$state_lane" = "$lane" ] || mac_die 'resume lane does not match the recorded lane'
  [ "$state_proof_platform" = "$proof_platform" ] ||
    mac_die 'resume proof platform does not match the recorded run'
  [ "$state_platform_kind" = mac ] && [ "$state_platform_compose_kind" = "$proof_platform" ] ||
    mac_die 'resume platform capabilities do not match the recorded run'
  [ "$state_callback_host" = "$callback_host" ] ||
    mac_die 'resume callback host does not match the recorded run'
  [ "$state_project_name" = "$project_name" ] ||
    mac_die 'resume project namespace does not match the recorded run'
  [ "$state_git_revision" = "$git_revision" ] ||
    mac_die 'resume Git revision does not match the recorded run'
  [ "$state_vault_checksum" = "$vault_checksum" ] ||
    mac_die 'resume vault checksum does not match the recorded run'
  if [ "$proof_platform" = integration ]; then
    for mac_roster_service in $MAC_SERVICE_PORT_ORDER; do
      eval "[ \"\$${mac_roster_service}_port\" = \"\$expected_${mac_roster_service}_port\" ]" ||
        mac_die 'resume integration ports do not match the recorded run'
    done
  fi
fi

export PLATFORM_MAC_SANDBOX=$sandbox
export PLATFORM_CONTRACT_SANDBOX_ROOT=$sandbox
export PLATFORM_CONTRACT_SANDBOX_OWNER_UID=$(id -u)
export PLATFORM_DOCKER_ROOT=$sandbox/service-data/docker
export PLATFORM_MEDIA_ROOT=$sandbox/service-data/media
export PLATFORM_FIXTURE_ROOT=$sandbox/fixtures
export PLATFORM_REPORT_ROOT=$report_root
export PLATFORM_PROOF_LANE=$lane
export PLATFORM_CALLBACK_HOST=$callback_host
export PLATFORM_COMPOSE_KIND=$proof_platform
export PLATFORM_KIND=$proof_platform
export PLATFORM_PROJECT_NAME=$project_name
export PLATFORM_MEDIA_NETWORK=$project_name-media-control
mac_export_service_ports
export COMPOSE_PROJECT_NAME=$project_name
export PLATFORM_MAC_VAULT_FILE=$vault_file
export PLATFORM_MAC_VAULT_PASSWORD_FILE=$vault_password_file
export PLATFORM_VAULT_FILE=$vault_file
export PLATFORM_MAC_FIXTURE_VARS_FILE=$fixture_vars_file

run_site() {
  ensure_immich_fixture_vars || return $?
  run_site_status=0
  mac_ansible_playbook -i "$mac_repo_dir/inventory/mac.yml" "$mac_repo_dir/site.yml" \
    --vault-password-file "$vault_password_file" -e @"$vault_file" \
    -e @"$fixture_vars_file" \
    -e "platform_vault_file=$vault_file" "$@" || run_site_status=$?
  return "$run_site_status"
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
    return 1
  fi
  rm -f -- "$idempotence_output"
}

run_persistence() {
  ensure_immich_fixture_vars || return $?
  persistence_status=0
  "$mac_script_dir/fixtures.sh" persistence || persistence_status=$?
  return "$persistence_status"
}

verify_target_state() {
  ensure_immich_fixture_vars || return $?
  target_verify_status=0
  "$mac_script_dir/verify.sh" || target_verify_status=$?
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
      "$project_name-audiobookshelf" "$project_name-komga" \
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
        "$project_name-audiobookshelf" "$project_name-komga" \
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
      case $proof_platform:$(uname -s) in
        mac:Darwin|integration:Linux) ;;
        mac:*)
          mac_die 'Mac proof harness requires Darwin'
          return 1
          ;;
        integration:*)
          mac_die 'integration proof harness requires Linux'
          return 1
          ;;
      esac
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
      for reserved_name in $(mac_target_container_names "$project_name"); do
        reserved_container_ids=$(docker ps -aq --filter "name=^/$reserved_name$") || {
          mac_die "could not inspect reserved container name: $reserved_name"
          return 1
        }
        [ -z "$reserved_container_ids" ] || {
          mac_die "reserved container name is already in use: $reserved_name"
          return 1
        }
      done
      # Resolved once, into a variable, so that a roster service without a port
      # aborts here rather than collapsing the substitution to nothing and
      # letting both reservation checks pass over an empty list.
      reserved_ports=$(mac_service_ports) || {
        mac_die 'reserved host ports are unresolved'
        return 1
      }
      [ "$(printf '%s\n' "$reserved_ports" | wc -l | tr -d ' ')" \
        -eq "$(mac_service_port_count)" ] || {
        mac_die 'reserved host ports are unresolved'
        return 1
      }
      # shellcheck disable=SC2086
      for reserved_port in $reserved_ports; do
        reserved_port_container_ids=$(docker ps -q --filter "publish=$reserved_port") || {
          mac_die "could not inspect reserved host port: $reserved_port"
          return 1
        }
        [ -z "$reserved_port_container_ids" ] || {
          mac_die "reserved host port is already in use: $reserved_port"
          return 1
        }
      done
      # shellcheck disable=SC2086
      ruby -rsocket -e '
        ARGV.each do |value|
          server = TCPServer.new("127.0.0.1", Integer(value, 10))
          server.close
        rescue SystemCallError
          warn "reserved host port is already in use: #{value}"
          exit 1
        end
      ' $reserved_ports || return 1
      ensure_immich_fixture_vars || return $?
      ansible-playbook "$mac_repo_dir/validate-vault.yml" \
        --vault-password-file "$vault_password_file" -e @"$vault_file" \
        -e @"$fixture_vars_file" \
        -e "platform_vault_file=$vault_file"
      ;;
    deploy)
      [ "$lane" = fresh ] || mac_die 'deploy phase is available only in the fresh lane'
      mac_run_hooks pre-converge
      run_site
      ;;
    seed) ensure_immich_fixture_vars && "$mac_script_dir/fixtures.sh" seed ;;
    verify) verify_target_state ;;
    idempotence) run_idempotence ;;
    drift) ensure_immich_fixture_vars && "$mac_script_dir/drift.sh" ;;
    reconcile) run_site && "$mac_script_dir/verify.sh" ;;
    recreate) ensure_immich_fixture_vars && "$mac_script_dir/fixtures.sh" recreate && verify_target_state ;;
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

emit_manual_validation_handoff() {
  deployment_manifest=$PLATFORM_DOCKER_ROOT/nas-platform/current/manifest.yml
  manual_vault_plaintext=$(mktemp "$protected_input_root/.manual-validation-vault.XXXXXX") ||
    return 1
  chmod 0600 "$manual_vault_plaintext" || {
    remove_manual_vault_plaintext || true
    return 1
  }
  vault_view_status=0
  ansible-vault view --vault-password-file "$vault_password_file" "$vault_file" \
    > "$manual_vault_plaintext" 2>/dev/null || vault_view_status=$?
  if [ "$vault_view_status" -ne 0 ]; then
    remove_manual_vault_plaintext || return 1
    return "$vault_view_status"
  fi

  handoff_status=0
  ruby "$mac_script_dir/manual-validation-handoff.rb" \
    --state "$state_input" --manifest "$deployment_manifest" \
    --deployment-root "$PLATFORM_DOCKER_ROOT/nas-platform" \
    --marker "$manual_resume_marker" --lane "$lane" \
    --sandbox "$sandbox" --report-root "$report_root" \
    --runner "$mac_script_dir/run.sh" \
    --vault-file "$deployment_vault_source" \
    --vault-password-file "$deployment_password_source" \
    < "$manual_vault_plaintext" || handoff_status=$?
  if ! remove_manual_vault_plaintext; then
    [ "$handoff_status" -ne 0 ] || handoff_status=1
  fi
  return "$handoff_status"
}

if [ -n "$selected_phase" ]; then
  run_phase "$selected_phase"
else
  for phase in $PHASES; do
    run_phase "$phase"
    if [ "$manual_validation" = true ] && [ "$phase" = verify ]; then
      [ "$(phase_status verify)" = passed ] ||
        mac_die 'manual validation requires a durably passed verify phase'
      preserve_sandbox_on_exit=true
      emit_manual_validation_handoff || exit $?
      exit 0
    fi
  done
fi

if [ -d "$sandbox" ]; then
  printf 'Sandbox preserved at %s\n' "$sandbox"
  preserve_sandbox_on_exit=true
fi

# Preservation is already the default. Keeping the parsed flag explicit makes
# the CLI contract stable for automation that requests it defensively.
: "$keep_on_failure"
