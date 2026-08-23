#!/bin/sh
set -eu
set +x
umask 077

mac_test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_dir=$(CDPATH= cd -- "$mac_test_dir/../.." && pwd -P)
runner=$mac_test_dir/run.sh
. "$mac_test_dir/lib.sh"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

temporary_input=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-manual-validation.XXXXXX")
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

vault_file=$temporary_parent/vault.yml
password_file=$temporary_parent/password
printf '%s\n' '$ANSIBLE_VAULT;1.1;AES256' > "$vault_file"
printf '%s\n' 'VAULT-PASSWORD-DO-NOT-LEAK' > "$password_file"
chmod 0600 "$vault_file" "$password_file"

expect_pre_mutation_failure() {
  label=$1
  expected=$2
  shift 2
  output=$temporary_parent/invalid-output
  if PLATFORM_MAC_TMPDIR="$temporary_parent" "$@" > "$output" 2>&1; then
    fail "$label was accepted"
  fi
  grep -F -- "$expected" "$output" >/dev/null ||
    fail "$label emitted the wrong diagnostic"
  [ ! -e "$temporary_parent/nas-platform-integration.lock" ] ||
    fail "$label acquired the integration lock"
  [ -z "$(find "$temporary_parent" -maxdepth 1 -type d -name 'nas-platform-mac.??????' -print -quit)" ] ||
    fail "$label created a sandbox"
}

help_output=$temporary_parent/help
"$runner" --help > "$help_output"
grep -F -- '--manual-validation' "$help_output" >/dev/null ||
  fail 'usage omits --manual-validation'

expect_pre_mutation_failure 'non-fresh manual validation' \
  '--manual-validation requires --lane fresh' \
  "$runner" --lane adoption --manual-validation \
    --vault-file "$vault_file" --vault-password-file "$password_file"
expect_pre_mutation_failure 'selected manual validation phase' \
  '--manual-validation requires a full run without --phase' \
  "$runner" --lane fresh --manual-validation --phase verify \
    --vault-file "$vault_file" --vault-password-file "$password_file"
expect_pre_mutation_failure 'manual validation keep-on-failure mode' \
  '--manual-validation is incompatible with --keep-on-failure' \
  "$runner" --lane fresh --manual-validation --keep-on-failure \
    --vault-file "$vault_file" --vault-password-file "$password_file"

# Exercise the complete runner boundary with command/script fixtures. The
# fixture root deliberately contains spaces, an apostrophe, and shell
# metacharacters so the printed commands must be safely copy/pasteable.
fixture_repo="$temporary_parent/manual runner's [fixture]"
fixture_mac=$fixture_repo/tests/mac
fixture_bin=$fixture_repo/fake-bin
mkdir -p "$fixture_mac" "$fixture_repo/tests" \
  "$fixture_repo/services" "$fixture_repo/inventory/group_vars/all" "$fixture_bin"
cp "$runner" "$fixture_mac/run.sh"
cp "$mac_test_dir/lib.sh" "$fixture_mac/lib.sh"
cp "$mac_test_dir/report.rb" "$fixture_mac/report.rb"
cp "$mac_test_dir/generate-immich-fixture-vars.rb" \
  "$fixture_mac/generate-immich-fixture-vars.rb"
cp "$mac_test_dir/manual-validation-handoff.rb" \
  "$fixture_mac/manual-validation-handoff.rb"
cp "$repo_dir/tests/integration_lock.sh" "$fixture_repo/tests/integration_lock.sh"
cat > "$fixture_repo/services/manifest.yml" <<'YAML'
---
services:
  - name: source-only-service
YAML
cp "$repo_dir/inventory/group_vars/all/main.yml" \
  "$fixture_repo/inventory/group_vars/all/main.yml"
chmod 0755 "$fixture_mac/run.sh" "$fixture_mac/report.rb" \
  "$fixture_mac/generate-immich-fixture-vars.rb" \
  "$fixture_mac/manual-validation-handoff.rb"

phase_log=$temporary_parent/phase-log
cleanup_log=$temporary_parent/cleanup-log
decrypted_vault=$temporary_parent/decrypted-vault.yml
cat > "$decrypted_vault" <<'YAML'
vault_audiobookshelf_admin_username: audio-admin
vault_audiobookshelf_admin_password: AUDIO-PASSWORD-DO-NOT-LEAK
vault_beszel_superuser_email: beszel-admin@example.invalid
vault_beszel_superuser_password: BESZEL-PASSWORD-DO-NOT-LEAK
vault_dozzle_admin_username: dozzle-admin
vault_dozzle_admin_password: DOZZLE-PASSWORD-DO-NOT-LEAK
vault_immich_admin_email: immich-admin@example.invalid
vault_immich_admin_password: IMMICH-PASSWORD-DO-NOT-LEAK
vault_jellyfin_admin_username: jellyfin-admin
vault_jellyfin_admin_password: JELLYFIN-PASSWORD-DO-NOT-LEAK
vault_komga_admin_email: komga-admin@example.invalid
vault_komga_admin_password: KOMGA-PASSWORD-DO-NOT-LEAK
vault_ntfy_admin_user: ntfy-admin
vault_ntfy_admin_password: NTFY-PASSWORD-DO-NOT-LEAK
vault_ntfy_dozzle_token: tk_DO_NOT_LEAK_DOZZLE
vault_paperless_admin_username: paperless-admin
vault_paperless_admin_password: PAPERLESS-PASSWORD-DO-NOT-LEAK
vault_managed_users:
  audiobookshelf:
    - username: audio-reader
      password: AUDIO-READER-PASSWORD-DO-NOT-LEAK
  beszel:
    - email: beszel-reader@example.invalid
      password: BESZEL-READER-PASSWORD-DO-NOT-LEAK
  dozzle:
    - username: dozzle-reader
      password: DOZZLE-READER-PASSWORD-DO-NOT-LEAK
  immich:
    - email: immich-reader@example.invalid
      password: IMMICH-READER-PASSWORD-DO-NOT-LEAK
  jellyfin:
    - username: jellyfin-reader
      password: JELLYFIN-READER-PASSWORD-DO-NOT-LEAK
  komga:
    - email: komga-reader@example.invalid
      password: KOMGA-READER-PASSWORD-DO-NOT-LEAK
  ntfy:
    - username: ntfy-reader
      password: NTFY-READER-PASSWORD-DO-NOT-LEAK
  paperless_ngx:
    - username: paperless-reader
      password: PAPERLESS-READER-PASSWORD-DO-NOT-LEAK
YAML
chmod 0600 "$decrypted_vault"

deployed_manifest=$temporary_parent/deployed-manifest.yml
cat > "$deployed_manifest" <<'YAML'
---
git_sha: 0123456789abcdef0123456789abcdef01234567
platform_kind: mac
platform_compose_kind: mac
services:
  - name: paperless-ngx
    compose_files: []
    images: {}
  - name: audiobookshelf
    compose_files: []
    images: {}
  - name: beszel
    compose_files: []
    images: {}
  - name: dozzle
    compose_files: []
    images: {}
  - name: immich
    compose_files: []
    images: {}
  - name: jellyfin
    compose_files: []
    images: {}
  - name: komga
    compose_files: []
    images: {}
  - name: ntfy
    compose_files: []
    images: {}
YAML
chmod 0644 "$deployed_manifest"

cat > "$fixture_mac/fixtures.sh" <<'STUB'
#!/bin/sh
printf 'fixtures:%s\n' "$1" >> "${PLATFORM_TEST_PHASE_LOG:?}"
STUB
cat > "$fixture_mac/verify.sh" <<'STUB'
#!/bin/sh
printf '%s\n' verify >> "${PLATFORM_TEST_PHASE_LOG:?}"
STUB
cat > "$fixture_mac/drift.sh" <<'STUB'
#!/bin/sh
printf '%s\n' drift >> "${PLATFORM_TEST_PHASE_LOG:?}"
STUB
cat > "$fixture_mac/cleanup.sh" <<'STUB'
#!/bin/sh
set -eu
target=$1
printf '%s\n' "$target" >> "${PLATFORM_TEST_CLEANUP_LOG:?}"
ruby - "$target" "${PLATFORM_TEST_PHASE_LOG:?}" <<'RUBY'
target, log = ARGV
paths = %w[deployment-vault.yml deployment-password immich-fixture-vars.yml]
inodes = paths.map { |name| File.stat(File.join(target, "protected-inputs", name)).ino }
File.open(log, "a") { |output| output.puts("protected-inodes:#{inodes.join(':')}") }
RUBY
find "$target" -depth -mindepth 1 -delete
rmdir -- "$target"
STUB
chmod 0755 "$fixture_mac/fixtures.sh" "$fixture_mac/verify.sh" \
  "$fixture_mac/drift.sh" "$fixture_mac/cleanup.sh"

cat > "$fixture_bin/uname" <<'STUB'
#!/bin/sh
printf '%s\n' Darwin
STUB
cat > "$fixture_bin/stat" <<'STUB'
#!/bin/sh
case ${1-}:${2-} in
  -f:%u)
    if /usr/bin/stat -f '%u' "$3" >/dev/null 2>&1; then
      exec /usr/bin/stat -f '%u' "$3"
    else
      exec /usr/bin/stat -c '%u' "$3"
    fi
    ;;
  -f:%Lp)
    if /usr/bin/stat -f '%Lp' "$3" >/dev/null 2>&1; then
      exec /usr/bin/stat -f '%Lp' "$3"
    else
      exec /usr/bin/stat -c '%a' "$3"
    fi
    ;;
  *) exec /usr/bin/stat "$@" ;;
esac
STUB
cat > "$fixture_bin/git" <<'STUB'
#!/bin/sh
printf '%s\n' 0123456789abcdef0123456789abcdef01234567
STUB
cat > "$fixture_bin/ansible-vault" <<'STUB'
#!/bin/sh
/bin/cat "${PLATFORM_TEST_DECRYPTED_VAULT:?}"
[ "${PLATFORM_TEST_VAULT_VIEW_FAILURE:-false}" != true ] || exit 86
STUB
cat > "$fixture_bin/ansible-playbook" <<'STUB'
#!/bin/sh
case $* in
  *'/site.yml'*)
    release_root=${PLATFORM_DOCKER_ROOT:?}/nas-platform/releases/0123456789abcdef0123456789abcdef01234567
    mkdir -p "$release_root"
    case ${PLATFORM_TEST_UNSAFE_DEPLOYED_MANIFEST:-none} in
      manifest-symlink)
        ln -sf "${PLATFORM_TEST_DEPLOYED_MANIFEST:?}" "$release_root/manifest.yml"
        ;;
      current-escape)
        release_root=${PLATFORM_MAC_SANDBOX:?}/escaped-release
        mkdir -p "$release_root"
        cp "${PLATFORM_TEST_DEPLOYED_MANIFEST:?}" "$release_root/manifest.yml"
        chmod 0644 "$release_root/manifest.yml"
        ;;
      none)
        cp "${PLATFORM_TEST_DEPLOYED_MANIFEST:?}" "$release_root/manifest.yml"
        chmod 0644 "$release_root/manifest.yml"
        ;;
      *) exit 91 ;;
    esac
    mkdir -p "${PLATFORM_DOCKER_ROOT:?}/nas-platform"
    ln -sfn "$release_root" "${PLATFORM_DOCKER_ROOT:?}/nas-platform/current"
    ;;
esac
printf 'ansible:%s\n' "$*" >> "${PLATFORM_TEST_PHASE_LOG:?}"
printf '%s\n' 'localhost : ok=1 changed=0 unreachable=0 failed=0 skipped=0 rescued=0 ignored=0 '
STUB
cat > "$fixture_bin/docker" <<'STUB'
#!/bin/sh
case ${1-}:${2-} in
  info:*) exit 0 ;;
  ps:*) exit 0 ;;
  network:ls|volume:ls) exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod 0755 "$fixture_bin/uname" "$fixture_bin/stat" "$fixture_bin/git" \
  "$fixture_bin/ansible-vault" "$fixture_bin/ansible-playbook" "$fixture_bin/docker"

hostile_input="$temporary_parent/operator inputs' [safe]"
mkdir "$hostile_input"
hostile_vault="$hostile_input/vault file; safe.yml"
hostile_password="$hostile_input/password file & safe"
cp "$vault_file" "$hostile_vault"
cp "$password_file" "$hostile_password"
chmod 0600 "$hostile_vault" "$hostile_password"

manual_output=$temporary_parent/manual-output
runner_env() {
  env PLATFORM_MAC_TMPDIR="$temporary_parent" \
    PLATFORM_TEST_PHASE_LOG="$phase_log" \
    PLATFORM_TEST_CLEANUP_LOG="$cleanup_log" \
    PLATFORM_TEST_DECRYPTED_VAULT="$decrypted_vault" \
    PLATFORM_TEST_DEPLOYED_MANIFEST="$deployed_manifest" \
    PLATFORM_TEST_UNSAFE_DEPLOYED_MANIFEST="${PLATFORM_TEST_UNSAFE_DEPLOYED_MANIFEST:-none}" \
    PLATFORM_TEST_VAULT_VIEW_FAILURE="${PLATFORM_TEST_VAULT_VIEW_FAILURE:-false}" \
    PATH="$fixture_bin:$PATH" "$@"
}

runner_env "$fixture_mac/run.sh" --lane fresh --manual-validation \
  --vault-file "$hostile_vault" --vault-password-file "$hostile_password" \
  > "$manual_output" 2>&1 || {
    sed -n '1,120p' "$manual_output" >&2
    fail 'manual validation run failed'
  }

sandbox=$(sed -n 's/^Sandbox root: //p' "$manual_output")
report_root=$(sed -n 's/^Report root: //p' "$manual_output")
[ -n "$sandbox" ] && [ -d "$sandbox" ] || fail 'manual validation did not retain the sandbox'
[ "$report_root" = "$sandbox.reports" ] && [ -d "$report_root" ] ||
  fail 'manual validation omitted the canonical report root'
[ ! -e "$temporary_parent/nas-platform-integration.lock" ] ||
  fail 'manual validation retained the integration lock'
[ ! -e "$report_root/report.json" ] && [ ! -e "$report_root/report.md" ] ||
  fail 'manual validation created a misleading final report'

ruby -rjson - "$report_root/phase-input.json" <<'RUBY'
state = JSON.parse(File.read(ARGV.fetch(0)))
expected = %w[preflight deploy seed verify]
actual = state.fetch("phases").map { |phase| phase.fetch("name") }
raise "manual stop boundary differs: #{actual.inspect}" unless actual == expected
raise "manual stop did not durably pass verify" unless
  state.fetch("phases").all? { |phase| phase.fetch("status") == "passed" }
RUBY
grep -F 'fixtures:seed' "$phase_log" >/dev/null || fail 'manual run omitted seed'
grep -F 'verify' "$phase_log" >/dev/null || fail 'manual run omitted verify'
if grep -Eq 'idempotence|drift|recreate|persistence|cleanup' "$phase_log"; then
  fail 'manual run executed a phase after verify'
fi

service_port_fields='audiobookshelf:audiobookshelf_port beszel:beszel_port dozzle:dozzle_port immich:immich_port jellyfin:jellyfin_port komga:komga_port ntfy:ntfy_port paperless-ngx:paperless_port'
for service_field in $service_port_fields; do
  service=${service_field%%:*}
  field=${service_field#*:}
  port=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch(ARGV.fetch(1))' \
    "$report_root/phase-input.json" "$field")
  grep -F "$service URL: http://127.0.0.1:$port" "$manual_output" >/dev/null ||
    fail "handoff omitted $service URL"
done
grep -F 'source-only-service' "$manual_output" >/dev/null &&
  fail 'handoff enumerated a service from the controller source manifest'

vault_failure_output=$temporary_parent/vault-producer-failure-output
if PLATFORM_TEST_VAULT_VIEW_FAILURE=true \
    runner_env "$fixture_mac/run.sh" --lane fresh --manual-validation \
    --vault-file "$hostile_vault" --vault-password-file "$hostile_password" \
    > "$vault_failure_output" 2>&1; then
  fail 'manual validation accepted a failing vault producer after valid YAML output'
fi
grep -F 'Manual validation is ready.' "$vault_failure_output" >/dev/null &&
  fail 'failing vault producer emitted a successful handoff'
grep -F 'AUDIO-PASSWORD-DO-NOT-LEAK' "$vault_failure_output" >/dev/null &&
  fail 'failing vault producer leaked decrypted vault content'
[ ! -e "$temporary_parent/nas-platform-integration.lock" ] ||
  fail 'failing vault producer retained the integration lock'
failed_vault_sandbox=$(find "$temporary_parent" -maxdepth 1 -type d \
  -name 'nas-platform-mac.??????' ! -path "$sandbox" -print -quit)
[ -n "$failed_vault_sandbox" ] && [ -d "$failed_vault_sandbox" ] ||
  fail 'failing vault producer did not retain its sandbox'
[ -z "$(find "$failed_vault_sandbox/protected-inputs" -maxdepth 1 \
  -name '.manual-validation-vault.??????' -print -quit)" ] ||
  fail 'failing vault producer left decrypted vault plaintext behind'
runner_env "$fixture_mac/cleanup.sh" "$failed_vault_sandbox"
PLATFORM_TEST_VAULT_VIEW_FAILURE=false

active_deployment_root=$sandbox/service-data/docker/nas-platform
active_manifest=$active_deployment_root/current/manifest.yml
for missing_service in \
    audiobookshelf beszel dozzle immich jellyfin komga ntfy paperless-ngx; do
  ruby -ryaml - "$deployed_manifest" "$active_manifest" "$missing_service" <<'RUBY'
source, destination, missing = ARGV
manifest = YAML.safe_load_file(source, aliases: false)
manifest.fetch("services").reject! { |service| service.fetch("name") == missing }
File.write(destination, YAML.dump(manifest))
RUBY
  missing_output=$temporary_parent/missing-$missing_service-output
  if "$fixture_mac/manual-validation-handoff.rb" \
      --state "$report_root/phase-input.json" --manifest "$active_manifest" \
      --deployment-root "$active_deployment_root" \
      --marker "$report_root/missing-service-marker.json" --lane fresh \
      --sandbox "$sandbox" --report-root "$report_root" --runner "$fixture_mac/run.sh" \
      --vault-file "$hostile_vault" --vault-password-file "$hostile_password" \
      < "$decrypted_vault" > "$missing_output" 2>&1; then
    fail "handoff accepted deployed manifest without $missing_service"
  fi
  grep -F 'manual-validation service manifest is invalid' "$missing_output" >/dev/null ||
    fail "missing deployed service $missing_service emitted the wrong diagnostic"
  grep -F 'Manual validation is ready.' "$missing_output" >/dev/null &&
    fail "missing deployed service $missing_service emitted a successful handoff"
  [ ! -e "$report_root/missing-service-marker.json" ] ||
    fail "missing deployed service $missing_service created a resume marker"
done
cp "$deployed_manifest" "$active_manifest"

for username in \
  audio-admin audio-reader beszel-admin@example.invalid beszel-reader@example.invalid \
  dozzle-admin dozzle-reader immich-admin@example.invalid immich-reader@example.invalid \
  jellyfin-admin jellyfin-reader komga-admin@example.invalid komga-reader@example.invalid \
  ntfy-admin ntfy-reader paperless-admin paperless-reader; do
  grep -F "$username" "$manual_output" >/dev/null ||
    fail "handoff omitted username $username"
done
grep -F 'Passwords remain in the encrypted vault source.' "$manual_output" >/dev/null ||
  fail 'handoff omitted encrypted-password guidance'

resume_command=$(sed -n 's/^Resume command: //p' "$manual_output")
cleanup_command=$(sed -n 's/^Cleanup command: //p' "$manual_output")
[ -n "$resume_command" ] || fail 'handoff omitted resume command'
[ -n "$cleanup_command" ] || fail 'handoff omitted cleanup command'
case $resume_command in *--manual-validation*) fail 'resume command repeats --manual-validation' ;; esac

expected_resume=$(ruby -rshellwords -e 'puts ARGV.map { |value| Shellwords.shellescape(value) }.join(" ")' \
  "$fixture_mac/run.sh" --lane fresh --vault-file "$hostile_vault" \
  --vault-password-file "$hostile_password" --sandbox "$sandbox")
expected_cleanup=$(
  mac_shell_quote "$fixture_mac/cleanup.sh"
  printf ' '
  mac_shell_quote "$sandbox"
)
[ "$resume_command" = "$expected_resume" ] || fail 'resume command is not exact or safely quoted'
[ "$cleanup_command" = "$expected_cleanup" ] || {
  printf 'expected cleanup: %s\nactual cleanup: %s\n' "$expected_cleanup" "$cleanup_command" >&2
  fail 'cleanup command is not exact or safely quoted'
}

for secret in \
  VAULT-PASSWORD-DO-NOT-LEAK AUDIO-PASSWORD-DO-NOT-LEAK BESZEL-PASSWORD-DO-NOT-LEAK \
  DOZZLE-PASSWORD-DO-NOT-LEAK IMMICH-PASSWORD-DO-NOT-LEAK \
  JELLYFIN-PASSWORD-DO-NOT-LEAK KOMGA-PASSWORD-DO-NOT-LEAK \
  NTFY-PASSWORD-DO-NOT-LEAK tk_DO_NOT_LEAK_DOZZLE PAPERLESS-PASSWORD-DO-NOT-LEAK \
  TMM-PASSWORD-DO-NOT-LEAK READER-PASSWORD-DO-NOT-LEAK; do
  if grep -R -F "$secret" "$manual_output" "$report_root" "$fixture_repo/services/manifest.yml" \
      >/dev/null 2>&1; then
    fail "manual validation leaked recognizable secret $secret"
  fi
done

for unsafe_manifest_mode in manifest-symlink current-escape; do
  handoff_failure_output=$temporary_parent/handoff-failure-$unsafe_manifest_mode-output
  if PLATFORM_TEST_UNSAFE_DEPLOYED_MANIFEST=$unsafe_manifest_mode \
      runner_env "$fixture_mac/run.sh" --lane fresh --manual-validation \
      --vault-file "$hostile_vault" --vault-password-file "$hostile_password" \
      > "$handoff_failure_output" 2>&1; then
    fail "manual validation accepted unsafe deployed manifest mode $unsafe_manifest_mode"
  fi
  grep -F 'manual-validation deployed manifest is unsafe' "$handoff_failure_output" >/dev/null || {
    sed -n '1,120p' "$handoff_failure_output" >&2
    fail "unsafe deployed manifest mode $unsafe_manifest_mode emitted the wrong diagnostic"
  }
  [ ! -e "$temporary_parent/nas-platform-integration.lock" ] ||
    fail "unsafe deployed manifest mode $unsafe_manifest_mode retained the integration lock"
  failed_handoff_sandbox=$(find "$temporary_parent" -maxdepth 1 -type d \
    -name 'nas-platform-mac.??????' ! -path "$sandbox" -print -quit)
  [ -n "$failed_handoff_sandbox" ] && [ -d "$failed_handoff_sandbox" ] ||
    fail "unsafe deployed manifest mode $unsafe_manifest_mode did not retain its sandbox"
  ruby -rjson - "$failed_handoff_sandbox.reports/phase-input.json" <<'RUBY'
state = JSON.parse(File.read(ARGV.fetch(0)))
raise "handoff failure happened before durable verify" unless
  state.fetch("phases").map { |phase| [phase.fetch("name"), phase.fetch("status")] } ==
    %w[preflight deploy seed verify].map { |name| [name, "passed"] }
RUBY
  runner_env "$fixture_mac/cleanup.sh" "$failed_handoff_sandbox"
done

different_vault="$hostile_input/different vault.yml"
cp "$hostile_vault" "$different_vault"
chmod 0600 "$different_vault"
different_path_output=$temporary_parent/different-path-output
if runner_env "$fixture_mac/run.sh" --lane fresh --vault-file "$different_vault" \
    --vault-password-file "$hostile_password" --sandbox "$sandbox" \
    > "$different_path_output" 2>&1; then
  fail 'resume accepted a different vault path with identical bytes'
fi
grep -F 'resume vault path does not match the manual-validation handoff' \
  "$different_path_output" >/dev/null || fail 'different vault path emitted the wrong diagnostic'
[ -d "$sandbox" ] && [ ! -e "$temporary_parent/nas-platform-integration.lock" ] ||
  fail 'different-path refusal mutated the sandbox or retained the lock'

state_backup=$temporary_parent/phase-input.backup.json
cp "$report_root/phase-input.json" "$state_backup"
ruby -rjson - "$report_root/phase-input.json" <<'RUBY'
path = ARGV.fetch(0)
state = JSON.parse(File.read(path))
state.fetch("phases").find { |phase| phase.fetch("name") == "verify" }["status"] = "failed"
File.write(path, JSON.pretty_generate(state) + "\n")
RUBY
tamper_output=$temporary_parent/tamper-output
if runner_env /bin/sh -c "$resume_command" > "$tamper_output" 2>&1; then
  fail 'resume accepted tampered manual-validation status'
fi
grep -F 'manual-validation resume status is invalid' "$tamper_output" >/dev/null ||
  fail 'tampered status emitted the wrong diagnostic'
[ -d "$sandbox" ] && [ ! -e "$temporary_parent/nas-platform-integration.lock" ] ||
  fail 'tampered-status refusal mutated the sandbox or retained the lock'
cp "$state_backup" "$report_root/phase-input.json"
chmod 0600 "$report_root/phase-input.json"

vault_inode=$(ruby -e 'print File.stat(ARGV.fetch(0)).ino' \
  "$sandbox/protected-inputs/deployment-vault.yml")
password_inode=$(ruby -e 'print File.stat(ARGV.fetch(0)).ino' \
  "$sandbox/protected-inputs/deployment-password")
fixture_inode=$(ruby -e 'print File.stat(ARGV.fetch(0)).ino' \
  "$sandbox/protected-inputs/immich-fixture-vars.yml")
resume_output=$temporary_parent/resume-output
runner_env /bin/sh -c "$resume_command" > "$resume_output" 2>&1 ||
  fail 'printed resume command failed'
first_resumed_phase=$(sed -n 's/^=== \(.*\) ===$/\1/p' "$resume_output" | head -n 1)
[ "$first_resumed_phase" = idempotence ] || fail 'resume did not begin at idempotence'
grep -F 'Skipping completed phase: verify' "$resume_output" >/dev/null ||
  fail 'resume did not skip the completed verification prefix'
[ ! -e "$sandbox" ] || fail 'resumed proof did not clean the sandbox'
[ -f "$report_root/report.json" ] && [ -f "$report_root/report.md" ] ||
  fail 'resumed proof did not render final reports'
grep -F "$sandbox" "$cleanup_log" >/dev/null || fail 'resume did not invoke cleanup for the sandbox'
ruby -rjson - "$report_root/phase-input.json" <<'RUBY'
state = JSON.parse(File.read(ARGV.fetch(0)))
phases = state.fetch("phases")
raise "resumed proof did not pass cleanup" unless
  phases.map { |phase| phase.fetch("name") }.last == "cleanup" &&
    phases.all? { |phase| phase.fetch("status") == "passed" }
RUBY

# The cleanup removes the protected files. The handoff run's inode evidence was
# therefore recorded in its phase log by the resume validator before cleanup.
grep -F "protected-inodes:$vault_inode:$password_inode:$fixture_inode" "$phase_log" >/dev/null ||
  fail 'resume did not byte-validate and reuse protected inputs'

printf '%s\n' 'Mac manual validation runner: handoff, retention, resume, and cleanup verified'
