#!/bin/sh
set -eu
set +x
umask 077

PHASES=' preflight deploy seed verify idempotence drift reconcile recreate persistence report cleanup '

mac_script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
mac_repo_dir=$(CDPATH= cd -- "$mac_script_dir/../.." && pwd -P)
. "$mac_script_dir/lib.sh"
. "$mac_repo_dir/tests/integration_lock.sh"

usage() {
  printf '%s\n' \
    'usage: run.sh --lane fresh|adoption --vault-file FILE --vault-password-file FILE_OR_EXECUTABLE [--keep-on-failure] [--phase NAME] [--sandbox PATH]'
}

lane=
vault_file=
vault_password_file=
selected_phase=
requested_sandbox=
keep_on_failure=false
while [ "$#" -gt 0 ]; do
  case $1 in
    --lane|--vault-file|--vault-password-file|--phase|--sandbox)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      case $1 in
        --lane) lane=$2 ;;
        --vault-file) vault_file=$2 ;;
        --vault-password-file) vault_password_file=$2 ;;
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

case $lane in fresh|adoption) ;; *) usage >&2; exit 2 ;; esac
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
state_input=$report_root/phase-input.json

git_revision=$(git -C "$mac_repo_dir" rev-parse HEAD)
vault_checksum=$(shasum -a 256 "$vault_file" | awk '{print $1}')
if [ ! -f "$state_input" ]; then
  beszel_port=$(ruby -rsocket -e 'server = TCPServer.new("127.0.0.1", 0); print server.addr[1]; server.close')
  ntfy_port=$(ruby -rsocket -e 'server = TCPServer.new("127.0.0.1", 0); print server.addr[1]; server.close')
  while [ "$ntfy_port" = "$beszel_port" ]; do
    ntfy_port=$(ruby -rsocket -e 'server = TCPServer.new("127.0.0.1", 0); print server.addr[1]; server.close')
  done
  "$mac_script_dir/report.rb" --init "$state_input" --lane "$lane" \
    --sandbox-id "$(basename -- "$sandbox")" --git-revision "$git_revision" \
    --vault-checksum "$vault_checksum" --project-name "$project_name" \
    --beszel-port "$beszel_port" --ntfy-port "$ntfy_port"
else
  state_lane=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("lane")' "$state_input")
  state_git_revision=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("git_revision")' "$state_input")
  state_vault_checksum=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("vault_checksum")' "$state_input")
  state_project_name=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("project_name")' "$state_input")
  beszel_port=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("beszel_port")' "$state_input")
  ntfy_port=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("ntfy_port")' "$state_input")
  [ "$state_lane" = "$lane" ] || mac_die 'resume lane does not match the recorded lane'
  [ "$state_project_name" = "$project_name" ] ||
    mac_die 'resume project namespace does not match the recorded run'
  [ "$state_git_revision" = "$git_revision" ] ||
    mac_die 'resume Git revision does not match the recorded run'
  [ "$state_vault_checksum" = "$vault_checksum" ] ||
    mac_die 'resume vault checksum does not match the recorded run'
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
export COMPOSE_PROJECT_NAME=$project_name
export PLATFORM_MAC_VAULT_FILE=$vault_file
export PLATFORM_MAC_VAULT_PASSWORD_FILE=$vault_password_file
export PLATFORM_VAULT_FILE=$vault_file

run_site() {
  ansible-playbook -i "$mac_repo_dir/inventory/mac.yml" "$mac_repo_dir/site.yml" \
    --vault-password-file "$vault_password_file" -e @"$vault_file" \
    -e "platform_vault_file=$vault_file" "$@"
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
  if for diagnostic_project in "$project_name-beszel" "$project_name-ntfy"; do
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

    diagnostic_container_ids=$(for diagnostic_project in "$project_name-beszel" "$project_name-ntfy"; do
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
      [ "$(uname -s)" = Darwin ] || mac_die 'Mac proof harness requires Darwin'
      command -v docker >/dev/null 2>&1 || mac_die 'Docker is required'
      command -v ansible-playbook >/dev/null 2>&1 || mac_die 'ansible-playbook is required'
      docker info >/dev/null 2>&1 || mac_die 'Docker Desktop is unavailable'
      for reserved_name in \
        "$project_name-beszel" "$project_name-beszel-agent-intel" \
        "$project_name-beszel-agent-portable" "$project_name-beszel-socket-proxy" \
        "$project_name-ntfy"; do
        [ -z "$(docker ps -aq --filter "name=^/$reserved_name$")" ] ||
          mac_die "reserved container name is already in use: $reserved_name"
      done
      for reserved_port in "$beszel_port" "$ntfy_port"; do
        [ -z "$(docker ps -q --filter "publish=$reserved_port")" ] ||
          mac_die "reserved host port is already in use: $reserved_port"
      done
      ruby -rsocket -e '
        ARGV.each do |value|
          server = TCPServer.new("127.0.0.1", Integer(value, 10))
          server.close
        rescue SystemCallError
          warn "reserved host port is already in use: #{value}"
          exit 1
        end
      ' "$beszel_port" "$ntfy_port"
      ansible-playbook "$mac_repo_dir/validate-vault.yml" \
        --vault-password-file "$vault_password_file" -e @"$vault_file" \
        -e "platform_vault_file=$vault_file"
      ;;
    deploy)
      [ "$lane" = fresh ] || mac_run_hooks adoption-deploy
      run_site
      [ "$lane" = fresh ] || "$mac_script_dir/verify.sh"
      ;;
    seed) "$mac_script_dir/fixtures.sh" seed ;;
    verify) "$mac_script_dir/verify.sh" ;;
    idempotence) run_idempotence ;;
    drift) "$mac_script_dir/drift.sh" ;;
    reconcile) run_site && "$mac_script_dir/verify.sh" ;;
    recreate) "$mac_script_dir/fixtures.sh" recreate && "$mac_script_dir/verify.sh" ;;
    persistence) "$mac_script_dir/fixtures.sh" persistence ;;
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
