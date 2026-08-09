#!/bin/sh
set -eu
set +x

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
IMPORTER="$ROOT/scripts/import-portainer-parity.sh"
PARSER="$ROOT/scripts/portainer-parity.rb"
MAPPING="$ROOT/config/portainer-parity.yml"
COMMIT=400f03f276ae1bb69f5460c175b9fb923d620f1a
CANARY=PORTAINER-PARITY-IMPORT-CANARY-DO-NOT-LEAK
ANSIBLE_BIN=/var/folders/z6/qvbh9dlx2_s98lt4__4fwg9m0000gn/T/nas-platform-task14-ansible.qp6qkn/bin
[ -x "$ANSIBLE_BIN/ansible-vault" ] && PATH="$ANSIBLE_BIN:$PATH"
export PATH

fail() { printf '%s\n' "portainer import test: $1" >&2; exit 1; }
assert() { [ "$1" = "$2" ] || fail "$3"; }
mode() { stat -f '%Lp' "$1"; }
sum() { shasum -a 256 "$1" | awk '{print $1}'; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-parity-import.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT HUP INT TERM
INPUT="$TMP/input"
OUTDIR="$TMP/output"
PASSWORD="$TMP/password"
mkdir -m 700 "$INPUT" "$OUTDIR"
printf '%s\n' 'correct horse battery staple' > "$PASSWORD"
chmod 600 "$PASSWORD"

ruby -ryaml -e '
  map = YAML.safe_load_file(ARGV[0], aliases: false)
  map.fetch("stacks").each do |stack, rules|
    File.write(File.join(ARGV[1], "#{stack}.env"), rules.keys.map { |key| "#{key}=#{ARGV[2]}-#{stack}-#{key}" }.join("\n") + "\n")
  end
' "$MAPPING" "$INPUT" "$CANARY"
chmod 600 "$INPUT"/*.env
before=$(for file in "$INPUT"/*.env; do sum "$file"; mode "$file"; done)

assert_failure() {
  label=$1
  target=$2
  shift 2
  state_before=$(for file in "$INPUT"/*.env; do sum "$file"; mode "$file"; done)
  "$@" >"$stdout" 2>"$stderr" && fail "$label: unexpectedly succeeded"
  [ ! -e "$target" ] && [ ! -L "$target" ] || fail "$label: output exists"
  [ ! -s "$stdout" ] || fail "$label: stdout is not empty"
  [ "$(wc -l < "$stderr" | tr -d ' ')" -eq 1 ] || fail "$label: stderr is not one line"
  if grep -F "$CANARY" "$stdout" "$stderr" >/dev/null; then fail "$label: canary leaked"; fi
  after_failure=$(for file in "$INPUT"/*.env; do sum "$file"; mode "$file"; done)
  assert "$state_before" "$after_failure" "$label: source inputs changed"
  [ -z "$(find "$OUTDIR" -name '.portainer-parity-*' -print)" ] || fail "$label: temporary files remain"
}

assert_race_failure() {
  label=$1
  target=$2
  record=$3
  shift 3
  state_before=$(for file in "$INPUT"/*.env; do sum "$file"; mode "$file"; done)
  "$@" >"$stdout" 2>"$stderr" && fail "$label: unexpectedly succeeded"
  [ -f "$target" ] || fail "$label: racer output was deleted"
  assert "$(cat "$record")" "$(stat -f '%d:%i:%Lp' "$target")" "$label: racer output changed"
  [ ! -s "$stdout" ] || fail "$label: stdout is not empty"
  [ "$(wc -l < "$stderr" | tr -d ' ')" -eq 1 ] || fail "$label: stderr is not one line"
  if grep -F "$CANARY" "$stdout" "$stderr" >/dev/null; then fail "$label: canary leaked"; fi
  assert "$state_before" "$(for file in "$INPUT"/*.env; do sum "$file"; mode "$file"; done)" "$label: source inputs changed"
  [ -z "$(find "$OUTDIR" -name '.portainer-parity-*' -print)" ] || fail "$label: temporary files remain"
}

assert_validate_failure() {
  label=$1
  source=$2
  printf '%b' "$source" > "$TMP/invalid.yml"
  ruby "$PARSER" --validate-stdin --mapping "$MAPPING" --legacy-commit "$COMMIT" < "$TMP/invalid.yml" >"$stdout" 2>"$stderr" && fail "$label: validation passed"
  [ ! -s "$stdout" ] || fail "$label: validation stdout is not empty"
  [ "$(wc -l < "$stderr" | tr -d ' ')" -eq 1 ] || fail "$label: validation stderr differs"
  if grep -F "$CANARY" "$stdout" "$stderr" >/dev/null; then fail "$label: validation leaked canary"; fi
}

assert_validate_file_failure() {
  label=$1
  source=$2
  ruby "$PARSER" --validate-stdin --mapping "$MAPPING" --legacy-commit "$COMMIT" < "$source" >"$stdout" 2>"$stderr" && fail "$label: validation passed"
  [ ! -s "$stdout" ] || fail "$label: validation stdout is not empty"
  [ "$(wc -l < "$stderr" | tr -d ' ')" -eq 1 ] || fail "$label: validation stderr differs"
  if grep -F "$CANARY" "$stdout" "$stderr" >/dev/null; then fail "$label: validation leaked canary"; fi
}

stdout="$TMP/stdout" stderr="$TMP/stderr" output="$OUTDIR/parity.vault"
"$IMPORTER" --input-dir "$INPUT" --output "$output" --vault-password-file "$PASSWORD" >"$stdout" 2>"$stderr" || fail "valid import failed"
[ -f "$output" ] || fail "output missing"
assert "$(mode "$output")" 600 "output mode differs"
head -n 1 "$output" | grep '^\$ANSIBLE_VAULT;' >/dev/null || fail "vault header missing"
grep -F "$CANARY" "$stdout" "$stderr" >/dev/null && fail "canary leaked"
grep -E 'sha256=[0-9a-f]{64}' "$stdout" >/dev/null || fail "checksum missing"
ansible-vault view --vault-password-file "$PASSWORD" "$output" | ruby "$PARSER" --validate-stdin --mapping "$MAPPING" --legacy-commit "$COMMIT" >/dev/null || fail "decrypted document invalid"
printf 'schema: 1\nlegacy_commit: %s\nstacks: {}\nextra: %s\n' "$COMMIT" "$CANARY" | ruby "$PARSER" --validate-stdin --mapping "$MAPPING" --legacy-commit "$COMMIT" >"$stdout" 2>"$stderr" && fail "invalid decrypted schema accepted"
grep -F "$CANARY" "$stdout" "$stderr" >/dev/null && fail "parser failure leaked canary"
after=$(for file in "$INPUT"/*.env; do sum "$file"; mode "$file"; done)
assert "$before" "$after" "source inputs changed"

existing_output="$OUTDIR/preexisting.vault"
printf '%s\n' 'distinct preexisting parity output sentinel' > "$existing_output"
chmod 600 "$existing_output"
existing_sum=$(sum "$existing_output")
existing_mode=$(mode "$existing_output")
existing_inode=$(stat -f '%d:%i' "$existing_output")
existing_sources=$(for file in "$INPUT"/*.env; do sum "$file"; mode "$file"; done)
"$IMPORTER" --input-dir "$INPUT" --output "$existing_output" --vault-password-file "$PASSWORD" >"$stdout" 2>"$stderr" && fail "existing output was overwritten"
grep -F "$CANARY" "$stdout" "$stderr" >/dev/null && fail "failure leaked canary"
assert "$existing_sources" "$(for file in "$INPUT"/*.env; do sum "$file"; mode "$file"; done)" "existing output changed sources"
assert "$existing_sum" "$(sum "$existing_output")" "existing output bytes changed"
assert "$existing_mode" "$(mode "$existing_output")" "existing output mode changed"
assert "$existing_inode" "$(stat -f '%d:%i' "$existing_output")" "existing output inode changed"
[ -z "$(find "$OUTDIR" -name '.portainer-parity-*' -print)" ] || fail "existing output left temporary files"

bad="$TMP/bad-mode"
cp -R "$INPUT" "$bad"
chmod 755 "$bad"
assert_failure unsafe-input-mode "$OUTDIR/bad.vault" "$IMPORTER" --input-dir "$bad" --output "$OUTDIR/bad.vault" --vault-password-file "$PASSWORD"

link="$TMP/input-link"
ln -s "$INPUT" "$link"
assert_failure input-symlink "$OUTDIR/link.vault" "$IMPORTER" --input-dir "$link" --output "$OUTDIR/link.vault" --vault-password-file "$PASSWORD"

repo_password="$ROOT/.parity-test-password"
repo_output="$ROOT/.parity-test-output"
rm -f "$repo_password" "$repo_output"
printf x > "$repo_password"; chmod 600 "$repo_password"
trap 'rm -f "$repo_password" "$repo_output"; cleanup' EXIT HUP INT TERM
assert_failure repository-password "$OUTDIR/repo-password.vault" "$IMPORTER" --input-dir "$INPUT" --output "$OUTDIR/repo-password.vault" --vault-password-file "$repo_password"
assert_failure repository-output "$repo_output" "$IMPORTER" --input-dir "$INPUT" --output "$repo_output" --vault-password-file "$PASSWORD"

chmod 644 "$INPUT/dozzle.env"
assert_failure unsafe-file-mode "$OUTDIR/file-mode.vault" "$IMPORTER" --input-dir "$INPUT" --output "$OUTDIR/file-mode.vault" --vault-password-file "$PASSWORD"
chmod 600 "$INPUT/dozzle.env"
printf x > "$INPUT/.unexpected"
chmod 600 "$INPUT/.unexpected"
assert_failure extra-hidden-source "$OUTDIR/extra.vault" "$IMPORTER" --input-dir "$INPUT" --output "$OUTDIR/extra.vault" --vault-password-file "$PASSWORD"
rm -f "$INPUT/.unexpected"

password_link="$TMP/password-link"
ln -s "$PASSWORD" "$password_link"
assert_failure password-symlink "$OUTDIR/password-link.vault" "$IMPORTER" --input-dir "$INPUT" --output "$OUTDIR/password-link.vault" --vault-password-file "$password_link"
parent_link="$TMP/output-link"
ln -s "$OUTDIR" "$parent_link"
assert_failure output-parent-symlink "$OUTDIR/symlink-parent.vault" "$IMPORTER" --input-dir "$INPUT" --output "$parent_link/symlink-parent.vault" --vault-password-file "$PASSWORD"

password_exec="$TMP/password-command"
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "correct horse battery staple"' > "$password_exec"
chmod 700 "$password_exec"
"$IMPORTER" --input-dir "$INPUT" --output "$OUTDIR/executable-password.vault" --vault-password-file "$password_exec" >"$stdout" 2>"$stderr" || fail "executable password source failed"
[ -f "$OUTDIR/executable-password.vault" ] || fail "executable password output missing"

fake="$TMP/fake-bin"
mkdir -m 700 "$fake"
printf '%s\n' '#!/bin/sh' 'exit 1' > "$fake/ansible-vault"
chmod 700 "$fake/ansible-vault"
assert_failure encryption-failure "$OUTDIR/encrypt-failure.vault" env PATH="$fake:$PATH" "$IMPORTER" --input-dir "$INPUT" --output "$OUTDIR/encrypt-failure.vault" --vault-password-file "$PASSWORD"

real_vault=$(command -v ansible-vault)
race_output="$OUTDIR/race.vault"
race_record="$TMP/race-record"
printf '%s\n' '#!/bin/sh' 'printf racer > "$RACE_OUTPUT"' 'stat -f "%d:%i:%Lp" "$RACE_OUTPUT" > "$RACE_RECORD"' 'exec "$REAL_VAULT" "$@"' > "$fake/ansible-vault"
chmod 700 "$fake/ansible-vault"
assert_race_failure publication-race "$race_output" "$race_record" env RACE_OUTPUT="$race_output" RACE_RECORD="$race_record" REAL_VAULT="$real_vault" PATH="$fake:$PATH" "$IMPORTER" --input-dir "$INPUT" --output "$race_output" --vault-password-file "$PASSWORD"
[ "$(cat "$race_output")" = racer ] || fail "publication race content changed"

directory_race="$OUTDIR/race-directory"
printf '%s\n' '#!/bin/sh' 'mkdir "$RACE_OUTPUT" 2>/dev/null || :' 'printf sentinel > "$RACE_OUTPUT/sentinel"' 'exec "$REAL_VAULT" "$@"' > "$fake/ansible-vault"
chmod 700 "$fake/ansible-vault"
state_before=$(for file in "$INPUT"/*.env; do sum "$file"; mode "$file"; done)
RACE_OUTPUT="$directory_race" REAL_VAULT="$real_vault" PATH="$fake:$PATH" "$IMPORTER" --input-dir "$INPUT" --output "$directory_race" --vault-password-file "$PASSWORD" >"$stdout" 2>"$stderr" && fail "directory race unexpectedly succeeded"
[ -d "$directory_race" ] && [ "$(cat "$directory_race/sentinel")" = sentinel ] || fail "directory racer changed"
[ -z "$(find "$directory_race" -type f ! -name sentinel -print)" ] || fail "directory racer contains ciphertext"
[ ! -s "$stdout" ] && [ "$(wc -l < "$stderr" | tr -d ' ')" -eq 1 ] || fail "directory race diagnostics differ"
if grep -F "$CANARY" "$stdout" "$stderr" >/dev/null; then fail "directory race leaked canary"; fi
assert "$state_before" "$(for file in "$INPUT"/*.env; do sum "$file"; mode "$file"; done)" "directory race changed sources"
[ -z "$(find "$OUTDIR" -name '.portainer-parity-*' -print)" ] || fail "directory race left temporary files"

assert_failure duplicate-arguments "$OUTDIR/duplicate.vault" "$IMPORTER" --input-dir "$INPUT" --output "$OUTDIR/duplicate.vault" --vault-password-file "$PASSWORD" --mapping "$MAPPING" --mapping "$MAPPING"
assert_failure unknown-argument "$OUTDIR/unknown.vault" "$IMPORTER" --unknown

grep -F "$CANARY" "$stdout" "$stderr" >/dev/null && fail "late failure leaked canary"
after=$(for file in "$INPUT"/*.env; do sum "$file"; mode "$file"; done)
assert "$before" "$after" "source inputs changed after failures"
[ -z "$(find "$OUTDIR" -name '.portainer-parity-*' -print)" ] || fail "temporary import files remain"

# --validate-stdin accepts only one exact YAML document and never echoes values.
assert_validate_failure multi-document "schema: 1\\nlegacy_commit: $COMMIT\\nstacks: {}\\n---\\n{}\\n"
assert_validate_failure alias "schema: 1\\nlegacy_commit: $COMMIT\\nstacks: &stacks {}\\n"
assert_validate_failure duplicate-key "schema: 1\\nschema: 1\\nlegacy_commit: $COMMIT\\nstacks: {}\\n"
assert_validate_failure commit-mismatch "schema: 1\\nlegacy_commit: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\\nstacks: {}\\n"
assert_validate_failure missing-stack "schema: 1\\nlegacy_commit: $COMMIT\\nstacks: {}\\n"
assert_validate_failure extra-root "schema: 1\\nlegacy_commit: $COMMIT\\nstacks: {}\\nextra: $CANARY\\n"
assert_validate_failure non-string-value "schema: 1\\nlegacy_commit: $COMMIT\\nstacks: {dozzle: {TZ: 1}}\\n"
printf '%b' "schema: 1\\nlegacy_commit: $COMMIT\\nstacks: {}\\n" > "$TMP/invalid.yml"
ruby "$PARSER" --validate-stdin --input-dir "$INPUT" --mapping "$MAPPING" --legacy-commit "$COMMIT" < "$TMP/invalid.yml" >"$stdout" 2>"$stderr" && fail "validate stdin accepted input-dir"
[ ! -s "$stdout" ] && [ "$(wc -l < "$stderr" | tr -d ' ')" -eq 1 ] || fail "exclusive parser options are not sanitized"
ansible-vault view --vault-password-file "$PASSWORD" "$output" > "$TMP/valid.yml"
ruby -ryaml -e 'd = YAML.safe_load_file(ARGV[0], aliases: false); d.fetch("stacks").delete("dozzle"); File.write(ARGV[1], YAML.dump(d))' "$TMP/valid.yml" "$TMP/missing-stack.yml"
assert_validate_file_failure missing-stack-from-valid "$TMP/missing-stack.yml"
ruby -ryaml -e 'd = YAML.safe_load_file(ARGV[0], aliases: false); d.fetch("stacks")["replacement"] = d.fetch("stacks").delete("dozzle"); File.write(ARGV[1], YAML.dump(d))' "$TMP/valid.yml" "$TMP/replaced-stack.yml"
assert_validate_file_failure replaced-stack "$TMP/replaced-stack.yml"
ruby -ryaml -e 'd = YAML.safe_load_file(ARGV[0], aliases: false); d.fetch("stacks")["dozzle"].delete("TZ"); File.write(ARGV[1], YAML.dump(d))' "$TMP/valid.yml" "$TMP/missing-key.yml"
assert_validate_file_failure missing-key "$TMP/missing-key.yml"
ruby -ryaml -e 'd = YAML.safe_load_file(ARGV[0], aliases: false); d.fetch("stacks")["dozzle"]["REPLACED"] = d.fetch("stacks")["dozzle"].delete("TZ"); File.write(ARGV[1], YAML.dump(d))' "$TMP/valid.yml" "$TMP/replaced-key.yml"
assert_validate_file_failure replaced-key "$TMP/replaced-key.yml"
ruby -ryaml -e 'd = YAML.safe_load_file(ARGV[0], aliases: false); d.fetch("stacks")["dozzle"]["EXTRA"] = "x"; File.write(ARGV[1], YAML.dump(d))' "$TMP/valid.yml" "$TMP/extra-key.yml"
assert_validate_file_failure extra-key "$TMP/extra-key.yml"
ruby -ryaml -e 'd = YAML.safe_load_file(ARGV[0], aliases: false); d.fetch("stacks")["dozzle"]["TZ"] = 1; File.write(ARGV[1], YAML.dump(d))' "$TMP/valid.yml" "$TMP/non-string.yml"
assert_validate_file_failure non-string-from-valid "$TMP/non-string.yml"

# A committed disposable repository lets provenance failures avoid touching this worktree.
FIXTURE_REPO="$TMP/repo"
mkdir -p "$FIXTURE_REPO/scripts" "$FIXTURE_REPO/config"
cp "$IMPORTER" "$PARSER" "$FIXTURE_REPO/scripts/"
cp "$MAPPING" "$FIXTURE_REPO/config/portainer-parity.yml"
git -C "$FIXTURE_REPO" init -q
git -C "$FIXTURE_REPO" config user.email test@example.invalid
git -C "$FIXTURE_REPO" config user.name test
git -C "$FIXTURE_REPO" add scripts config && git -C "$FIXTURE_REPO" commit -qm fixture
FIXTURE_IMPORTER="$FIXTURE_REPO/scripts/import-portainer-parity.sh"
printf '# modified fixture\\n' >> "$FIXTURE_REPO/config/portainer-parity.yml"
assert_failure modified-mapping "$OUTDIR/modified-mapping.vault" "$FIXTURE_IMPORTER" --input-dir "$INPUT" --output "$OUTDIR/modified-mapping.vault" --vault-password-file "$PASSWORD"
git -C "$FIXTURE_REPO" add config/portainer-parity.yml
assert_failure staged-mapping "$OUTDIR/staged-mapping.vault" "$FIXTURE_IMPORTER" --input-dir "$INPUT" --output "$OUTDIR/staged-mapping.vault" --vault-password-file "$PASSWORD"
cp "$MAPPING" "$FIXTURE_REPO/config/untracked.yml"
assert_failure untracked-mapping "$OUTDIR/untracked-mapping.vault" "$FIXTURE_IMPORTER" --input-dir "$INPUT" --output "$OUTDIR/untracked-mapping.vault" --vault-password-file "$PASSWORD" --mapping "$FIXTURE_REPO/config/untracked.yml"

# A failing checksum utility is checked before publication.
checksum_fake="$TMP/checksum-fake"
mkdir -m 700 "$checksum_fake"
printf '%s\n' '#!/bin/sh' 'exit 1' > "$checksum_fake/shasum"
chmod 700 "$checksum_fake/shasum"
vault_clean="$TMP/vault-clean"
mkdir -m 700 "$vault_clean"
printf '%s\n' '#!/bin/sh' 'PATH=$CLEAN_PATH' 'export PATH' 'exec "$REAL_VAULT" "$@"' > "$vault_clean/ansible-vault"
chmod 700 "$vault_clean/ansible-vault"
real_vault=$(command -v ansible-vault)
assert_failure checksum-failure "$OUTDIR/checksum-failure.vault" env PATH="$checksum_fake:$vault_clean:$PATH" CLEAN_PATH="$PATH" REAL_VAULT="$real_vault" "$IMPORTER" --input-dir "$INPUT" --output "$OUTDIR/checksum-failure.vault" --vault-password-file "$PASSWORD"
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "${SHA_OUTPUT-}"' > "$checksum_fake/shasum"
chmod 700 "$checksum_fake/shasum"
for malformed in '' 'xyz  file' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  file' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa extra field' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  x\nsecond"; do
  assert_failure malformed-checksum "$OUTDIR/malformed-checksum.vault" env PATH="$checksum_fake:$vault_clean:$PATH" CLEAN_PATH="$PATH" REAL_VAULT="$real_vault" SHA_OUTPUT="$malformed" "$IMPORTER" --input-dir "$INPUT" --output "$OUTDIR/malformed-checksum.vault" --vault-password-file "$PASSWORD"
done

# A failed unlink after link(2) must roll back only the importer-owned output.
cleanup_fake="$TMP/cleanup-fake"
mkdir -m 700 "$cleanup_fake"
printf '%s\n' '#!/bin/sh' 'case "$*" in *portainer-parity-cipher*) exit 1 ;; *) exec /bin/rm "$@" ;; esac' > "$cleanup_fake/rm"
chmod 700 "$cleanup_fake/rm"
assert_failure ciphertext-unlink-failure "$OUTDIR/unlink-failure.vault" env PATH="$cleanup_fake:$vault_clean:$PATH" CLEAN_PATH="$PATH" REAL_VAULT="$real_vault" "$IMPORTER" --input-dir "$INPUT" --output "$OUTDIR/unlink-failure.vault" --vault-password-file "$PASSWORD"

sanitize_fake="$TMP/sanitize-fake"
mkdir -m 700 "$sanitize_fake"
real_ruby=$(command -v ruby)
printf '%s\n' '#!/bin/sh' 'case "${1-}" in -e) exit 1 ;; *) exec "$REAL_RUBY" "$@" ;; esac' > "$sanitize_fake/ruby"
chmod 700 "$sanitize_fake/ruby"
assert_failure sanitize-failure "$OUTDIR/sanitize-failure.vault" env PATH="$sanitize_fake:$PATH" REAL_RUBY="$real_ruby" "$IMPORTER" --input-dir "$INPUT" --output "$OUTDIR/sanitize-failure.vault" --vault-password-file "$PASSWORD"

printf '%s\n' 'Portainer parity importer: encrypted external input is safe'
