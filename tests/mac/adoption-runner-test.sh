#!/bin/sh
set -eu
set +x
umask 077

mac_test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_dir=$(CDPATH= cd -- "$mac_test_dir/../.." && pwd -P)
runner=$mac_test_dir/run.sh
reporter=$mac_test_dir/report.rb

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

temporary_input=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-adoption-runner.XXXXXX")
temporary_parent=$(CDPATH= cd -- "$temporary_input" && pwd -P)
in_repo_input=
cleanup_fixture() {
  fixture_status=$?
  trap - EXIT HUP INT TERM
  if [ -n "$in_repo_input" ] && [ -f "$in_repo_input" ] && [ ! -L "$in_repo_input" ]; then
    rm -f -- "$in_repo_input"
  fi
  if [ -d "$temporary_parent" ] && [ ! -L "$temporary_parent" ]; then
    find "$temporary_parent" -depth -mindepth 1 -delete
    rmdir -- "$temporary_parent"
  fi
  exit "$fixture_status"
}
trap cleanup_fixture EXIT HUP INT TERM

vault_file=$temporary_parent/deployment-vault.yml
parity_vault_file=$temporary_parent/parity-vault.yml
password_file=$temporary_parent/deployment-password
parity_password_file=$temporary_parent/parity-password
printf '%s\n' '$ANSIBLE_VAULT;1.1;AES256' > "$vault_file"
printf '%s\n' '$ANSIBLE_VAULT;1.1;AES256' > "$parity_vault_file"
printf '%s\n' disposable > "$password_file"
printf '%s\n' parity-disposable > "$parity_password_file"
chmod 0600 "$vault_file" "$parity_vault_file" "$password_file" "$parity_password_file"

expect_failure() {
  label=$1
  expected=$2
  shift 2
  output=$temporary_parent/output
  if "$@" >"$output" 2>&1; then
    fail "$label was accepted"
  fi
  grep -F "$expected" "$output" >/dev/null || fail "$label emitted the wrong diagnostic"
}

ruby - "$runner" <<'RUBY'
source = File.read(ARGV.fetch(0))
fresh = "preflight deploy seed verify idempotence drift reconcile recreate persistence report cleanup"
adoption = "preflight legacy-deploy legacy-seed capture-baseline snapshot cutover verify " \
           "idempotence recreate persistence rollback report cleanup"
raise "fresh phase graph differs" unless source.match?(/^FRESH_PHASES=' #{Regexp.escape(fresh)} '$/)
raise "adoption phase graph differs" unless source.match?(/^ADOPTION_PHASES=' #{Regexp.escape(adoption)} '$/)
parser = source.index("while [ \"$#\" -gt 0 ]")
fresh_definition = source.index("FRESH_PHASES=")
adoption_definition = source.index("ADOPTION_PHASES=")
lane_validation = source.index("case $lane in")
phase_assignment = source.index("PHASES=$FRESH_PHASES")
raise "phase constants must precede parsing" unless [fresh_definition, adoption_definition].all? { |index| index && index < parser }
raise "phase selection must follow lane validation" unless lane_validation && phase_assignment && lane_validation < phase_assignment
RUBY

help_output=$temporary_parent/help
"$runner" --help > "$help_output"
grep -F -- '--parity-vault-file FILE' "$help_output" >/dev/null || fail 'usage omits parity vault option'
grep -F -- '--parity-vault-password-file FILE_OR_EXECUTABLE' "$help_output" >/dev/null ||
  fail 'usage omits parity password option'

expect_failure 'adoption without parity vault' 'adoption requires --parity-vault-file' \
  "$runner" --lane adoption --vault-file "$vault_file" --vault-password-file "$password_file"
expect_failure 'adoption without parity password' 'adoption requires --parity-vault-password-file' \
  "$runner" --lane adoption --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_vault_file"
expect_failure 'fresh parity options' 'fresh lane rejects parity vault options' \
  "$runner" --lane fresh --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_vault_file" --parity-vault-password-file "$parity_password_file"
expect_failure 'same explicit password path' 'unknown phase: not-a-phase' \
  "$runner" --lane adoption --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_vault_file" --parity-vault-password-file "$password_file" \
    --phase not-a-phase

parity_link=$temporary_parent/parity-link.yml
ln -s "$parity_vault_file" "$parity_link"
expect_failure 'symlink parity vault' 'parity vault file must be a readable, regular encrypted file' \
  "$runner" --lane adoption --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_link" --parity-vault-password-file "$parity_password_file"

in_repo_input=$(mktemp "$mac_test_dir/.adoption-parity.XXXXXX")
printf '%s\n' '$ANSIBLE_VAULT;1.1;AES256' > "$in_repo_input"
chmod 0600 "$in_repo_input"
expect_failure 'repository parity vault' 'parity vault file must remain outside the repository' \
  "$runner" --lane adoption --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$in_repo_input" --parity-vault-password-file "$parity_password_file"
expect_failure 'repository parity password' 'parity vault password input must remain outside the repository' \
  "$runner" --lane adoption --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_vault_file" --parity-vault-password-file "$in_repo_input"
rm -f -- "$in_repo_input"
in_repo_input=

git_revision=$(git -C "$repo_dir" rev-parse HEAD)
vault_checksum=$(shasum -a 256 "$vault_file" | awk '{print $1}')
parity_checksum=$(shasum -a 256 "$parity_vault_file" | awk '{print $1}')
legacy_commit=$(ruby -ryaml -e 'print YAML.safe_load_file(ARGV.fetch(0)).fetch("legacy_source").fetch("commit")' \
  "$repo_dir/services/manifest.yml")

initialize_adoption_state() {
  sandbox=$1
  recorded_parity_checksum=$2
  recorded_legacy_commit=$3
  recorded_vault_checksum=${4:-$vault_checksum}
  report_root=$sandbox.reports
  suffix=$(printf '%s' "${sandbox##*.}" | tr '[:upper:]' '[:lower:]')
  project_name=nas-platform-mac-$suffix
  mkdir -m 0700 "$sandbox" "$report_root"
  printf 'schema=1\nproject=%s\n' "$project_name" > "$sandbox/.nas-platform-mac-owned"
  chmod 0600 "$sandbox/.nas-platform-mac-owned"
  printf 'schema=1\nsandbox=%s\n' "$(basename -- "$sandbox")" \
    > "$report_root/.nas-platform-mac-report-owned"
  chmod 0600 "$report_root/.nas-platform-mac-report-owned"
  "$reporter" --init "$report_root/phase-input.json" --lane adoption \
    --sandbox-id "$(basename -- "$sandbox")" --git-revision "$git_revision" \
    --vault-checksum "$recorded_vault_checksum" --parity-vault-checksum "$recorded_parity_checksum" \
    --legacy-commit "$recorded_legacy_commit" --project-name "$project_name" \
    --beszel-port 38090 --ntfy-port 32586 --dozzle-port 38080 \
    --audiobookshelf-port 33378 --komga-port 35600 \
    --tinymediamanager-web-port 34000 --tinymediamanager-api-port 37878 \
    --jellyfin-port 38096 --immich-port 32283 --paperless-port 38000
}

deployment_sandbox=$temporary_parent/nas-platform-mac.Dep123
initialize_adoption_state "$deployment_sandbox" "$parity_checksum" "$legacy_commit" "$(printf '%064d' 0)"
expect_failure 'resumed adoption deployment checksum mismatch' \
  'resume vault checksum does not match the recorded run' \
  env PLATFORM_MAC_TMPDIR="$temporary_parent" "$runner" --lane adoption \
    --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_vault_file" --parity-vault-password-file "$parity_password_file" \
    --phase report --sandbox "$deployment_sandbox"

checksum_sandbox=$temporary_parent/nas-platform-mac.Chk123
initialize_adoption_state "$checksum_sandbox" "$(printf '%064d' 0)" "$legacy_commit"
expect_failure 'resumed adoption parity checksum mismatch' \
  'resume parity vault checksum does not match the recorded run' \
  env PLATFORM_MAC_TMPDIR="$temporary_parent" "$runner" --lane adoption \
    --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_vault_file" --parity-vault-password-file "$parity_password_file" \
    --phase report --sandbox "$checksum_sandbox"

legacy_sandbox=$temporary_parent/nas-platform-mac.Leg123
initialize_adoption_state "$legacy_sandbox" "$parity_checksum" "$(printf '%040d' 0)"
expect_failure 'resumed adoption legacy commit mismatch' \
  'resume legacy commit does not match the recorded run' \
  env PLATFORM_MAC_TMPDIR="$temporary_parent" "$runner" --lane adoption \
    --vault-file "$vault_file" --vault-password-file "$password_file" \
    --parity-vault-file "$parity_vault_file" --parity-vault-password-file "$parity_password_file" \
    --phase report --sandbox "$legacy_sandbox"

matching_sandbox=$temporary_parent/nas-platform-mac.OkA123
initialize_adoption_state "$matching_sandbox" "$parity_checksum" "$legacy_commit"
env PLATFORM_MAC_TMPDIR="$temporary_parent" "$runner" --lane adoption \
  --vault-file "$vault_file" --vault-password-file "$password_file" \
  --parity-vault-file "$parity_vault_file" --parity-vault-password-file "$parity_password_file" \
  --phase report --sandbox "$matching_sandbox" >/dev/null 2>&1 ||
  fail 'matching resumed adoption identity was rejected'

report_input=$temporary_parent/report-input.json
report_json=$temporary_parent/report.json
report_markdown=$temporary_parent/report.md
"$reporter" --init "$report_input" --lane adoption \
  --sandbox-id nas-platform-mac.Report1 --git-revision "$git_revision" \
  --vault-checksum "$vault_checksum" --parity-vault-checksum "$parity_checksum" \
  --legacy-commit "$legacy_commit" --project-name nas-platform-mac-report1 \
  --beszel-port 38090 --ntfy-port 32586 --dozzle-port 38080 \
  --audiobookshelf-port 33378 --komga-port 35600 \
  --tinymediamanager-web-port 34000 --tinymediamanager-api-port 37878 \
  --jellyfin-port 38096 --immich-port 32283 --paperless-port 38000
"$reporter" --input "$report_input" --json "$report_json" --markdown "$report_markdown"
ruby -rjson - "$report_json" "$parity_checksum" "$legacy_commit" <<'RUBY'
report, parity_checksum, legacy_commit = JSON.parse(File.read(ARGV.fetch(0))), ARGV.fetch(1), ARGV.fetch(2)
raise "JSON parity checksum differs" unless report["parity_vault_checksum"] == parity_checksum
raise "JSON legacy commit differs" unless report["legacy_commit"] == legacy_commit
RUBY
grep -F -- "- Parity vault checksum: $parity_checksum" "$report_markdown" >/dev/null ||
  fail 'Markdown omits parity vault checksum'
grep -F -- "- Legacy commit: $legacy_commit" "$report_markdown" >/dev/null ||
  fail 'Markdown omits legacy commit'

printf '%s\n' 'Mac adoption runner: lane phases and protected resume identity hold'
