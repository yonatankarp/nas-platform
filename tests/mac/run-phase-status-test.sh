#!/bin/sh
set -eu
set +x

mac_test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_dir=$(CDPATH= cd -- "$mac_test_dir/../.." && pwd -P)

# This test drives run.sh, which refuses to run anywhere but Darwin, so on any
# other platform it can only ever fail at its first phase. It is the one entry in
# validate-policy.sh with that property; the other Mac tests exercise their hooks
# directly and are portable. Skipping keeps the Linux policy run honest instead of
# reporting a failure that says nothing about the code under test.
if [ "$(uname -s)" != Darwin ]; then
  printf '%s\n' 'Mac phase status: skipped, run.sh requires Darwin'
  exit 0
fi

temporary_input=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-phase-status.XXXXXX")
temporary_parent=$(CDPATH= cd -- "$temporary_input" && pwd -P)

cleanup_fixture() {
  fixture_status=$?
  trap - EXIT HUP INT TERM
  if [ -d "$temporary_parent" ] && [ ! -L "$temporary_parent" ]; then
    find "$temporary_parent" -depth -mindepth 1 -delete
    rmdir -- "$temporary_parent"
  fi
  exit "$fixture_status"
}
trap cleanup_fixture EXIT HUP INT TERM

sandbox=$temporary_parent/nas-platform-mac.FaIl42
report_root=$sandbox.reports
state_input=$report_root/phase-input.json
project_name=nas-platform-mac-fail42
vault_file=$temporary_parent/vault.yml
password_file=$temporary_parent/password
failure_marker=$temporary_parent/ansible-invoked
preflight_failure_marker=$temporary_parent/docker-info-invoked
fake_bin=$temporary_parent/tools

mkdir -m 0700 "$sandbox" "$report_root" "$fake_bin"
printf 'schema=1\nproject=%s\n' "$project_name" > "$sandbox/.nas-platform-mac-owned"
chmod 0600 "$sandbox/.nas-platform-mac-owned"
printf 'schema=1\nsandbox=%s\n' "$(basename -- "$sandbox")" \
  > "$report_root/.nas-platform-mac-report-owned"
chmod 0600 "$report_root/.nas-platform-mac-report-owned"
printf '%s\n' '$ANSIBLE_VAULT;1.1;AES256' > "$vault_file"
printf '%s\n' disposable > "$password_file"
chmod 0600 "$vault_file" "$password_file"

cat > "$fake_bin/ansible-playbook" <<'STUB'
#!/bin/sh
if [ "${PLATFORM_PHASE_ANSIBLE_FAILURE:-false}" != true ]; then
  exit 0
fi
printf '%s\n' '[ERROR]: couldn'\''t resolve module/action '\''community.docker.docker_compose_v2'\''.' >&2
: > "${PLATFORM_PHASE_FAILURE_MARKER:?}"
exit 4
STUB
chmod 0755 "$fake_bin/ansible-playbook"

cat > "$fake_bin/ansible-vault" <<'STUB'
#!/bin/sh
cat <<'YAML'
vault_managed_users:
  immich:
    - email: fixture@example.invalid
YAML
STUB
chmod 0755 "$fake_bin/ansible-vault"

cat > "$fake_bin/docker" <<'STUB'
#!/bin/sh
if [ "${1-}" = info ]; then
  : > "${PLATFORM_PREFLIGHT_FAILURE_MARKER:?}"
  exit 5
fi
exit 0
STUB
chmod 0755 "$fake_bin/docker"

git_revision=$(git -C "$repo_dir" rev-parse HEAD)
vault_checksum=$(shasum -a 256 "$vault_file" | awk '{print $1}')
"$mac_test_dir/report.rb" --init "$state_input" --lane fresh \
  --sandbox-id "$(basename -- "$sandbox")" --git-revision "$git_revision" \
  --vault-checksum "$vault_checksum" --project-name "$project_name" \
  --beszel-port 38090 --ntfy-port 32586 --dozzle-port 38080 \
  --audiobookshelf-port 33378 --komga-port 35600 \
  --jellyfin-port 38096 \
  --immich-port 32283 --paperless-port 38000 \
  --radarr-port 37878 --sonarr-port 38989 --prowlarr-port 36969 \
  --bazarr-port 36767 --sabnzbd-port 38082 --pinchflat-port 38945 \
  --kapowarr-port 35656 \
  --bindery-port 38787 \
  --trailarr-port 37889 \
  --seerr-port 35055
ruby -rjson -e '
  input = JSON.parse(File.read(ARGV.fetch(0)))
  abort "report retained retired migration identity" if
    input.key?("parity_vault_checksum") || input.key?("legacy_commit")
' "$state_input"
"$mac_test_dir/report.rb" --record "$state_input" --phase preflight --status running
"$mac_test_dir/report.rb" --record "$state_input" --phase preflight --status passed

runner_status=0
PLATFORM_MAC_TMPDIR="$temporary_parent" PLATFORM_PHASE_ANSIBLE_FAILURE=true \
  PLATFORM_PHASE_FAILURE_MARKER="$failure_marker" \
  PATH="$fake_bin:$PATH" "$mac_test_dir/run.sh" --lane fresh \
    --vault-file "$vault_file" --vault-password-file "$password_file" \
    --phase deploy --sandbox "$sandbox" >/dev/null 2>&1 || runner_status=$?

[ -f "$failure_marker" ] || {
  printf '%s\n' 'Mac phase status test did not exercise the failing Ansible command' >&2
  exit 1
}
[ "$runner_status" -ne 0 ] || {
  printf '%s\n' 'Mac runner returned success after a pre-execution Ansible failure' >&2
  exit 1
}
phase_status=$(ruby -rjson -e '
  input = JSON.parse(File.read(ARGV.fetch(0)))
  phase = input.fetch("phases").find { |entry| entry["name"] == "deploy" }
  print phase.fetch("status", "") if phase
' "$state_input")
[ "$phase_status" = failed ] || {
  printf 'Mac runner recorded failing deploy phase as %s\n' "${phase_status:-absent}" >&2
  exit 1
}

preflight_sandbox=$temporary_parent/nas-platform-mac.PrFl42
preflight_report_root=$preflight_sandbox.reports
preflight_state=$preflight_report_root/phase-input.json
preflight_project=nas-platform-mac-prfl42
mkdir -m 0700 "$preflight_sandbox" "$preflight_report_root"
printf 'schema=1\nproject=%s\n' "$preflight_project" \
  > "$preflight_sandbox/.nas-platform-mac-owned"
chmod 0600 "$preflight_sandbox/.nas-platform-mac-owned"
printf 'schema=1\nsandbox=%s\n' "$(basename -- "$preflight_sandbox")" \
  > "$preflight_report_root/.nas-platform-mac-report-owned"
chmod 0600 "$preflight_report_root/.nas-platform-mac-report-owned"

preflight_status=0
PLATFORM_MAC_TMPDIR="$temporary_parent" \
  PLATFORM_PREFLIGHT_FAILURE_MARKER="$preflight_failure_marker" \
  PATH="$fake_bin:$PATH" "$mac_test_dir/run.sh" --lane fresh \
    --vault-file "$vault_file" --vault-password-file "$password_file" \
    --phase preflight --sandbox "$preflight_sandbox" >/dev/null 2>&1 || preflight_status=$?
[ -f "$preflight_failure_marker" ] || {
  printf '%s\n' 'Mac phase status test did not exercise the failing Docker preflight' >&2
  exit 1
}
[ "$preflight_status" -ne 0 ] || {
  printf '%s\n' 'Mac runner returned success after a Docker preflight failure' >&2
  exit 1
}
preflight_phase_status=$(ruby -rjson -e '
  input = JSON.parse(File.read(ARGV.fetch(0)))
  phase = input.fetch("phases").find { |entry| entry["name"] == "preflight" }
  print phase.fetch("status", "") if phase
' "$preflight_state")
[ "$preflight_phase_status" = failed ] || {
  printf 'Mac runner recorded failing preflight phase as %s\n' \
    "${preflight_phase_status:-absent}" >&2
  exit 1
}

printf '%s\n' 'Mac phase status: Ansible and preflight failures propagate'
