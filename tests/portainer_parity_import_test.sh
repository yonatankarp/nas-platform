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

"$IMPORTER" --input-dir "$INPUT" --output "$output" --vault-password-file "$PASSWORD" >"$stdout" 2>"$stderr" && fail "existing output was overwritten"
grep -F "$CANARY" "$stdout" "$stderr" >/dev/null && fail "failure leaked canary"

bad="$TMP/bad-mode"
cp -R "$INPUT" "$bad"
chmod 755 "$bad"
"$IMPORTER" --input-dir "$bad" --output "$OUTDIR/bad.vault" --vault-password-file "$PASSWORD" >"$stdout" 2>"$stderr" && fail "unsafe input mode accepted"
[ ! -e "$OUTDIR/bad.vault" ] || fail "failure left output"

link="$TMP/input-link"
ln -s "$INPUT" "$link"
"$IMPORTER" --input-dir "$link" --output "$OUTDIR/link.vault" --vault-password-file "$PASSWORD" >"$stdout" 2>"$stderr" && fail "symlink input accepted"

repo_password="$ROOT/.parity-test-password"
repo_output="$ROOT/.parity-test-output"
rm -f "$repo_password" "$repo_output"
printf x > "$repo_password"; chmod 600 "$repo_password"
trap 'rm -f "$repo_password" "$repo_output"; cleanup' EXIT HUP INT TERM
"$IMPORTER" --input-dir "$INPUT" --output "$OUTDIR/repo-password.vault" --vault-password-file "$repo_password" >"$stdout" 2>"$stderr" && fail "repository password accepted"
[ ! -e "$OUTDIR/repo-password.vault" ] || fail "repository password failure left output"
"$IMPORTER" --input-dir "$INPUT" --output "$repo_output" --vault-password-file "$PASSWORD" >"$stdout" 2>"$stderr" && fail "repository output accepted"
[ ! -e "$repo_output" ] || fail "repository output failure left output"

chmod 644 "$INPUT/dozzle.env"
"$IMPORTER" --input-dir "$INPUT" --output "$OUTDIR/file-mode.vault" --vault-password-file "$PASSWORD" >"$stdout" 2>"$stderr" && fail "unsafe file mode accepted"
[ ! -e "$OUTDIR/file-mode.vault" ] || fail "unsafe file mode failure left output"
chmod 600 "$INPUT/dozzle.env"
printf x > "$INPUT/.unexpected"
chmod 600 "$INPUT/.unexpected"
"$IMPORTER" --input-dir "$INPUT" --output "$OUTDIR/extra.vault" --vault-password-file "$PASSWORD" >"$stdout" 2>"$stderr" && fail "extra hidden source accepted"
rm -f "$INPUT/.unexpected"

password_link="$TMP/password-link"
ln -s "$PASSWORD" "$password_link"
"$IMPORTER" --input-dir "$INPUT" --output "$OUTDIR/password-link.vault" --vault-password-file "$password_link" >"$stdout" 2>"$stderr" && fail "password symlink accepted"
parent_link="$TMP/output-link"
ln -s "$OUTDIR" "$parent_link"
"$IMPORTER" --input-dir "$INPUT" --output "$parent_link/symlink-parent.vault" --vault-password-file "$PASSWORD" >"$stdout" 2>"$stderr" && fail "output-parent symlink accepted"

password_exec="$TMP/password-command"
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "correct horse battery staple"' > "$password_exec"
chmod 700 "$password_exec"
"$IMPORTER" --input-dir "$INPUT" --output "$OUTDIR/executable-password.vault" --vault-password-file "$password_exec" >"$stdout" 2>"$stderr" || fail "executable password source failed"
[ -f "$OUTDIR/executable-password.vault" ] || fail "executable password output missing"

fake="$TMP/fake-bin"
mkdir -m 700 "$fake"
printf '%s\n' '#!/bin/sh' 'exit 1' > "$fake/ansible-vault"
chmod 700 "$fake/ansible-vault"
PATH="$fake:$PATH" "$IMPORTER" --input-dir "$INPUT" --output "$OUTDIR/encrypt-failure.vault" --vault-password-file "$PASSWORD" >"$stdout" 2>"$stderr" && fail "encryption failure accepted"
[ ! -e "$OUTDIR/encrypt-failure.vault" ] || fail "encryption failure left output"

real_vault=$(command -v ansible-vault)
race_output="$OUTDIR/race.vault"
printf '%s\n' '#!/bin/sh' 'touch "$RACE_OUTPUT"' 'exec "$REAL_VAULT" "$@"' > "$fake/ansible-vault"
chmod 700 "$fake/ansible-vault"
RACE_OUTPUT="$race_output" REAL_VAULT="$real_vault" PATH="$fake:$PATH" "$IMPORTER" --input-dir "$INPUT" --output "$race_output" --vault-password-file "$PASSWORD" >"$stdout" 2>"$stderr" && fail "publication race overwrote output"
[ -f "$race_output" ] || fail "race fixture did not create output"
[ "$(wc -c < "$race_output" | tr -d ' ')" -eq 0 ] || fail "publication race clobbered competitor"

"$IMPORTER" --input-dir "$INPUT" --output "$OUTDIR/duplicate.vault" --vault-password-file "$PASSWORD" --mapping "$MAPPING" --mapping "$MAPPING" >"$stdout" 2>"$stderr" && fail "duplicate arguments accepted"
"$IMPORTER" --unknown >"$stdout" 2>"$stderr" && fail "unknown argument accepted"

grep -F "$CANARY" "$stdout" "$stderr" >/dev/null && fail "late failure leaked canary"
after=$(for file in "$INPUT"/*.env; do sum "$file"; mode "$file"; done)
assert "$before" "$after" "source inputs changed after failures"
[ -z "$(find "$OUTDIR" -name '.portainer-parity-*' -print)" ] || fail "temporary import files remain"

printf '%s\n' 'Portainer parity importer: encrypted external input is safe'
