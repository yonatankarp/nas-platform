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
  stat -f '%Lp' "$1" 2>/dev/null || die "path metadata is unavailable"
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
  stat -f '%d:%i' "$1" 2>/dev/null
}

cleanup() {
  [ -n "${PLAIN:-}" ] && /bin/rm -f -- "$PLAIN"
  [ -n "${CIPHER:-}" ] && /bin/rm -f -- "$CIPHER"
  [ -n "${VIEW:-}" ] && /bin/rm -f -- "$VIEW"
}
trap cleanup EXIT HUP INT TERM

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

ruby "$ROOT/scripts/portainer-parity.rb" --input-dir "$INPUT" --mapping "$MAPPING" --legacy-commit 400f03f276ae1bb69f5460c175b9fb923d620f1a >"$PLAIN" 2>/dev/null || die "parity rendering failed"
ansible-vault encrypt --vault-password-file "$PASSWORD" --output "$CIPHER" "$PLAIN" >/dev/null 2>/dev/null || die "vault encryption failed"
[ -f "$CIPHER" ] && [ ! -L "$CIPHER" ] && [ "$(mode "$CIPHER")" = 600 ] || die "ciphertext is unsafe"
IFS= read -r header < "$CIPHER" || die "ciphertext is invalid"
case "$header" in '$ANSIBLE_VAULT;'*) ;; *) die "ciphertext is invalid" ;; esac

# A separate owned file lets each command's status be checked without pipefail.
ansible-vault view --vault-password-file "$PASSWORD" "$CIPHER" >"$VIEW" 2>/dev/null || die "vault verification failed"
ruby "$ROOT/scripts/portainer-parity.rb" --validate-stdin --mapping "$MAPPING" --legacy-commit 400f03f276ae1bb69f5460c175b9fb923d620f1a <"$VIEW" >/dev/null 2>/dev/null || die "decrypted schema is invalid"

# link(2) publishes only if OUTPUT is still absent; unlike mv it never replaces.
if ! checksum_line=$(shasum -a 256 -- "$CIPHER"); then
  die "checksum failed"
fi
checksum=${checksum_line%%[!0-9a-f]*}
[ "${#checksum}" -eq 64 ] || die "checksum is invalid"
[ "$checksum_line" = "$checksum  $CIPHER" ] || die "checksum is invalid"
ln "$CIPHER" "$OUTPUT" 2>/dev/null || die "output publication failed"
if ! rm -f -- "$CIPHER"; then
  if output_identity=$(identity "$OUTPUT") && cipher_identity=$(identity "$CIPHER") &&
     [ "$output_identity" = "$cipher_identity" ]; then
    /bin/rm -f -- "$OUTPUT" || die "output rollback failed"
  fi
  die "ciphertext cleanup failed"
fi
CIPHER=
if ! safe_output=$(sanitize "$OUTPUT"); then
  die "output path formatting failed"
fi
printf 'Portainer parity encrypted: sha256=%s output=%s\n' "$checksum" "$safe_output"
