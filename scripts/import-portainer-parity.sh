#!/bin/sh
# Encrypt a one-time Portainer parity import without reading values into shell.
set -eu
set +x
umask 077

die() {
  printf '%s\n' "portainer-parity-import-error: $1" >&2
  exit 1
}

mode() {
  ruby -e 's = File.lstat(ARGV.fetch(0)); abort unless s; puts((s.mode & 0o777).to_s(8))' "$1" 2>/dev/null || die "path metadata is unavailable"
}

physical_dir() {
  [ -d "$1" ] && [ ! -L "$1" ] || die "unsafe directory"
  (CDPATH= cd -- "$1" && pwd -P) || die "directory is unavailable"
}

physical_file() {
  raw=$1
  [ -f "$raw" ] && [ ! -L "$raw" ] || die "unsafe file"
  parent=$(physical_dir "$(dirname -- "$raw")")
  base=$(basename -- "$raw")
  [ -f "$parent/$base" ] && [ ! -L "$parent/$base" ] || die "unsafe file"
  printf '%s/%s\n' "$parent" "$base"
}

outside_repo() {
  case "$1" in
    "$ROOT"|"$ROOT"/*) die "path must be outside the repository" ;;
  esac
}

sanitize() {
  ruby -e 'print ARGV.fetch(0).encode("UTF-8", invalid: :replace, undef: :replace, replace: "?").gsub(/[[:cntrl:]]/, "?")' "$1"
}

identity() {
  ruby -e 's = File.lstat(ARGV.fetch(0)); puts "#{s.dev}:#{s.ino}"' "$1" 2>/dev/null
}

cleanup() {
  [ -n "${PLAIN:-}" ] && /bin/rm -f -- "$PLAIN"
  [ -n "${CIPHER:-}" ] && /bin/rm -f -- "$CIPHER"
  [ -n "${VIEW:-}" ] && /bin/rm -f -- "$VIEW"
}
ACTIVE_PID=
run_child() {
  exec 9<&0 || return 1
  "$@" <&9 9<&- &
  ACTIVE_PID=$!
  exec 9<&-
  if wait "$ACTIVE_PID"; then
    status=0
  else
    status=$?
  fi
  ACTIVE_PID=
  return "$status"
}
handle_signal() {
  status=$1
  trap - HUP INT TERM
  if [ -n "$ACTIVE_PID" ]; then
    kill -TERM "$ACTIVE_PID" 2>/dev/null || true
    wait "$ACTIVE_PID" 2>/dev/null || true
    ACTIVE_PID=
  fi
  cleanup
  trap - EXIT
  exit "$status"
}
trap cleanup EXIT
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) || die "repository is unavailable"
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P) || die "repository is unavailable"
ROOT=$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null) || die "repository is unavailable"
ROOT=$(CDPATH= cd -- "$ROOT" && pwd -P) || die "repository is unavailable"

INPUT=
OUTPUT=
PASSWORD=
MAPPING="$ROOT/config/portainer-parity.yml"
MAPPING_SET=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --input-dir|--output|--vault-password-file|--mapping)
      [ "$#" -ge 2 ] || die "command line is invalid"
      key=$1 value=$2
      shift 2
      case "$key" in
        --input-dir) [ -z "$INPUT" ] || die "command line is invalid"; INPUT=$value ;;
        --output) [ -z "$OUTPUT" ] || die "command line is invalid"; OUTPUT=$value ;;
        --vault-password-file) [ -z "$PASSWORD" ] || die "command line is invalid"; PASSWORD=$value ;;
        --mapping) [ "$MAPPING_SET" = false ] || die "command line is invalid"; MAPPING_SET=true; MAPPING=$value ;;
      esac
      ;;
    *) die "command line is invalid" ;;
  esac
done
[ -n "$INPUT" ] && [ -n "$OUTPUT" ] && [ -n "$PASSWORD" ] || die "required argument is missing"

# All pathname and permission checks complete before the parser reads exports.
INPUT=$(physical_dir "$INPUT")
outside_repo "$INPUT"
[ "$(mode "$INPUT")" = 700 ] || die "input directory mode is unsafe"

MAPPING=$(physical_file "$MAPPING")
case "$MAPPING" in "$ROOT"/*) ;; *) die "mapping must be inside the repository" ;; esac
MAPPING_REL=${MAPPING#"$ROOT/"}
git -C "$ROOT" ls-files --error-unmatch -- "$MAPPING_REL" >/dev/null 2>&1 || die "mapping is not tracked"
git -C "$ROOT" diff --quiet -- "$MAPPING_REL" || die "mapping has unstaged changes"
git -C "$ROOT" diff --cached --quiet -- "$MAPPING_REL" || die "mapping has staged changes"
MAPPING_ID=$(identity "$MAPPING") || die "mapping metadata is unavailable"

PASSWORD=$(physical_file "$PASSWORD")
outside_repo "$PASSWORD"
password_mode=$(mode "$PASSWORD")
if [ -x "$PASSWORD" ]; then
  [ $((0$password_mode & 077)) -eq 0 ] || die "password executable mode is unsafe"
else
  [ "$password_mode" = 600 ] || die "password file mode is unsafe"
fi

OUTPUT_PARENT=$(physical_dir "$(dirname -- "$OUTPUT")")
outside_repo "$OUTPUT_PARENT"
[ -w "$OUTPUT_PARENT" ] || die "output directory is not writable"
[ $((0$(mode "$OUTPUT_PARENT") & 022)) -eq 0 ] || die "output directory mode is unsafe"
OUTPUT_BASE=$(basename -- "$OUTPUT")
[ "$OUTPUT_BASE" != . ] && [ "$OUTPUT_BASE" != .. ] && [ -n "$OUTPUT_BASE" ] || die "output path is unsafe"
OUTPUT="$OUTPUT_PARENT/$OUTPUT_BASE"
[ ! -e "$OUTPUT" ] && [ ! -L "$OUTPUT" ] || die "output already exists"

expected_files='audiobookshelf.env beszel.env dozzle.env immich.env jellyfin.env komga.env ntfy.env paperless-ngx.env tinymediamanager.env'
count=0
for entry in "$INPUT"/.[!.]* "$INPUT"/..?* "$INPUT"/*; do
  [ -e "$entry" ] || continue
  [ ! -L "$entry" ] && [ -f "$entry" ] || die "unsafe environment file"
  case "$(basename -- "$entry")" in
    audiobookshelf.env|beszel.env|dozzle.env|immich.env|jellyfin.env|komga.env|ntfy.env|paperless-ngx.env|tinymediamanager.env) ;;
    *) die "input file set differs" ;;
  esac
  [ "$(mode "$entry")" = 600 ] || die "environment file mode is unsafe"
  count=$((count + 1))
done
[ "$count" -eq 9 ] || die "input file set differs"
for name in $expected_files; do
  [ -f "$INPUT/$name" ] && [ ! -L "$INPUT/$name" ] || die "input file set differs"
done

PLAIN=$(mktemp "$OUTPUT_PARENT/.portainer-parity-plain.XXXXXX") || die "temporary file creation failed"
CIPHER=$(mktemp "$OUTPUT_PARENT/.portainer-parity-cipher.XXXXXX") || die "temporary file creation failed"
VIEW=$(mktemp "$OUTPUT_PARENT/.portainer-parity-view.XXXXXX") || die "temporary file creation failed"
chmod 600 "$PLAIN" "$CIPHER" "$VIEW" || die "temporary file setup failed"

[ "$(identity "$MAPPING")" = "$MAPPING_ID" ] && git -C "$ROOT" diff --quiet -- "$MAPPING_REL" && git -C "$ROOT" diff --cached --quiet -- "$MAPPING_REL" || die "mapping changed during import"
run_child ruby "$ROOT/scripts/portainer-parity.rb" --input-dir "$INPUT" --mapping "$MAPPING" --legacy-commit 400f03f276ae1bb69f5460c175b9fb923d620f1a >"$PLAIN" 2>/dev/null || die "parity rendering failed"
PASSWORD_ID=$(identity "$PASSWORD") || die "password metadata is unavailable"
run_child ansible-vault encrypt --vault-password-file "$PASSWORD" --output "$CIPHER" "$PLAIN" >/dev/null 2>/dev/null || die "vault encryption failed"
[ "$(identity "$PASSWORD")" = "$PASSWORD_ID" ] && [ "$(mode "$PASSWORD")" = "$password_mode" ] || die "password changed during import"
[ -f "$CIPHER" ] && [ ! -L "$CIPHER" ] && [ "$(mode "$CIPHER")" = 600 ] || die "ciphertext is unsafe"
IFS= read -r header < "$CIPHER" || die "ciphertext is invalid"
case "$header" in '$ANSIBLE_VAULT;'*) ;; *) die "ciphertext is invalid" ;; esac

# A separate owned file lets each command's status be checked without pipefail.
PASSWORD_ID=$(identity "$PASSWORD") || die "password metadata is unavailable"
run_child ansible-vault view --vault-password-file "$PASSWORD" "$CIPHER" >"$VIEW" 2>/dev/null || die "vault verification failed"
[ "$(identity "$PASSWORD")" = "$PASSWORD_ID" ] && [ "$(mode "$PASSWORD")" = "$password_mode" ] || die "password changed during import"
[ "$(identity "$MAPPING")" = "$MAPPING_ID" ] && git -C "$ROOT" diff --quiet -- "$MAPPING_REL" && git -C "$ROOT" diff --cached --quiet -- "$MAPPING_REL" || die "mapping changed during import"
run_child ruby "$ROOT/scripts/portainer-parity.rb" --validate-stdin --mapping "$MAPPING" --legacy-commit 400f03f276ae1bb69f5460c175b9fb923d620f1a <"$VIEW" >/dev/null 2>/dev/null || die "decrypted schema is invalid"

# link(2) publishes only if OUTPUT is still absent; unlike mv it never replaces.
if ! checksum_line=$(shasum -a 256 -- "$CIPHER"); then
  die "checksum failed"
fi
checksum=${checksum_line%%[!0-9a-f]*}
[ "${#checksum}" -eq 64 ] || die "checksum is invalid"
[ "$checksum_line" = "$checksum  $CIPHER" ] || die "checksum is invalid"
if ! safe_output=$(sanitize "$OUTPUT"); then
  die "output path formatting failed"
fi
ruby -e '
  source, destination = ARGV
  before = File.lstat(source)
  File.link(source, destination)
  begin
    File.unlink(source)
  rescue SystemCallError
    after = File.lstat(destination)
    if before.dev == after.dev && before.ino == after.ino
      begin File.unlink(destination); rescue SystemCallError; abort "catastrophic cleanup failure"; end
    end
    abort "ciphertext cleanup failed"
  end
' "$CIPHER" "$OUTPUT" >/dev/null 2>&1 || die "output publication or cleanup failed"
CIPHER=
printf 'Portainer parity encrypted: sha256=%s output=%s\n' "$checksum" "$safe_output"
