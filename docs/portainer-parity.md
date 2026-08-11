# Portainer parity vault lifecycle

The Portainer parity vault is temporary migration evidence. It preserves the
exact environment inputs from the nine legacy Portainer stacks so an adoption
proof can compare them with the target platform. Production roles never consume
this vault; permanent platform credentials belong in the
[deployment vault](secrets.md).

## Prepare protected external inputs

Create a protected directory outside the checkout with exactly these regular
files:

```text
portainer-env/
├── audiobookshelf.env
├── beszel.env
├── dozzle.env
├── immich.env
├── jellyfin.env
├── komga.env
├── ntfy.env
├── paperless-ngx.env
└── tinymediamanager.env
```

The input directory must have mode `0700`, and every environment file must have
mode `0600`. Symlinks, missing files, and extra files are rejected. Create a
vault password file with mode `0600` and a protected output directory that is
not writable by group or other users.

Use external absolute paths throughout the procedure. The following guarded
setup runs in a subshell, so a failure stops the setup without terminating the
operator's interactive shell. If `EDITOR` is set, it must be one executable
name or path without arguments.

```sh
export PORTAINER_PROTECTED_DIR="$HOME/.config/nas-platform/portainer-adoption"
export PORTAINER_ENV_DIR="$PORTAINER_PROTECTED_DIR/portainer-env"
export PORTAINER_PARITY_FILE="$PORTAINER_PROTECTED_DIR/portainer-parity.yml"
export PORTAINER_PARITY_PASSWORD_FILE="$PORTAINER_PROTECTED_DIR/vault-password"

(
  set -eu
  umask 077

  if [ -L "$PORTAINER_PROTECTED_DIR" ] || \
     { [ -e "$PORTAINER_PROTECTED_DIR" ] && [ ! -d "$PORTAINER_PROTECTED_DIR" ]; }; then
    printf 'STOP: protected parent is not a regular directory\n' >&2
    exit 1
  fi
  if [ -e "$PORTAINER_ENV_DIR" ] || [ -L "$PORTAINER_ENV_DIR" ] || \
     [ -e "$PORTAINER_PARITY_FILE" ] || [ -L "$PORTAINER_PARITY_FILE" ] || \
     [ -e "$PORTAINER_PARITY_PASSWORD_FILE" ] || [ -L "$PORTAINER_PARITY_PASSWORD_FILE" ]; then
    printf 'STOP: refusing to overwrite a protected path\n' >&2
    exit 1
  fi

  mkdir -p "$PORTAINER_PROTECTED_DIR"
  mkdir "$PORTAINER_ENV_DIR"
  chmod 700 "$PORTAINER_PROTECTED_DIR" "$PORTAINER_ENV_DIR"

  if [ -n "${EDITOR:-}" ]; then parity_editor=$EDITOR; else parity_editor=vi; fi
  case "$parity_editor" in
    *[![:graph:]]*) printf 'STOP: EDITOR must be one executable without arguments\n' >&2; exit 1 ;;
  esac
  if ! "$parity_editor" "$PORTAINER_PARITY_PASSWORD_FILE"; then
    printf 'STOP: password editor failed; inspect the protected path\n' >&2
    exit 1
  fi
  chmod 600 "$PORTAINER_PARITY_PASSWORD_FILE"
  password_lines=$(awk 'END { print NR }' "$PORTAINER_PARITY_PASSWORD_FILE")
  if [ "$password_lines" -ne 1 ] || [ ! -s "$PORTAINER_PARITY_PASSWORD_FILE" ] || \
     ! awk 'NR == 1 && length($0) > 0 { valid=1 } END { exit !valid }' \
       "$PORTAINER_PARITY_PASSWORD_FILE"; then
    printf 'STOP: parity password must be one non-empty line\n' >&2
    exit 1
  fi
  unset password_lines parity_editor
  printf 'Protected Portainer paths are ready\n'
)
```

The four exported paths remain available to the shell that will run the
importer. Stop if setup prints `STOP`. Populate only the nine named environment
files through a protected editor, then set every file to mode `0600`. Do not
reuse the setup block after a partial failure: inspect the paths it reports and
resolve them explicitly.

All three paths must remain outside the repository: `PORTAINER_ENV_DIR`,
`PORTAINER_PARITY_FILE`, and `PORTAINER_PARITY_PASSWORD_FILE`. Do not copy the
plaintext exports, parity ciphertext, or password into the checkout.

Each environment file contains one literal `KEY=value` record per line. Blank
lines and full-line comments are allowed. Values may contain spaces, `$`, `#`,
and additional `=` characters. The importer does not source or evaluate the
files: it performs no shell expansion, command substitution, interpolation,
quote removal, or escape processing. Do not pre-process the exports with a
shell.

## Import and validate

Run from the repository root:

```sh
scripts/import-portainer-parity.sh \
  --input-dir "$PORTAINER_ENV_DIR" \
  --output "$PORTAINER_PARITY_FILE" \
  --vault-password-file "$PORTAINER_PARITY_PASSWORD_FILE"
```

The importer must exit successfully and print exactly one
`Portainer parity encrypted: sha256=... output=...` result. Any other result is
a stop condition.

The importer validates the exact file set, permissions, mapping, encryption
header, and decrypted schema without printing values. It publishes only a new
mode-`0600` encrypted artifact and never overwrites an existing parity vault.
If the output path already exists, stop and inspect it; do not rename or delete
it as part of this procedure. The importer never changes or deletes the source
exports.

A successful import prints the SHA-256 checksum of the ciphertext. Record that
line as the identity of the encrypted artifact, then independently confirm the
permissions, Ansible Vault header, and checksum on the operator workstation:

```sh
(
  set -eu
  umask 077
  parity_view=
  parity_view_cleanup() {
    [ -z "$parity_view" ] || /bin/rm -f -- "$parity_view"
    parity_view=
  }
  trap parity_view_cleanup EXIT
  trap 'parity_view_cleanup; exit 1' HUP INT TERM

  ls -ld "$PORTAINER_ENV_DIR" "$(dirname "$PORTAINER_PARITY_FILE")"
  ls -l "$PORTAINER_ENV_DIR"/*.env \
    "$PORTAINER_PARITY_FILE" "$PORTAINER_PARITY_PASSWORD_FILE"
  IFS= read -r parity_header < "$PORTAINER_PARITY_FILE"
  case "$parity_header" in
    '$ANSIBLE_VAULT;'*) printf 'Encrypted parity header confirmed\n' ;;
    *) printf 'STOP: parity artifact is not encrypted\n' >&2; exit 1 ;;
  esac
  shasum -a 256 "$PORTAINER_PARITY_FILE"
  if ! parity_view=$(mktemp "$(dirname "$PORTAINER_PARITY_FILE")/.portainer-parity-view.XXXXXX"); then
    printf 'STOP: protected parity verification file could not be created\n' >&2
    exit 1
  fi
  if ! chmod 600 "$parity_view"; then
    printf 'STOP: protected parity verification file mode could not be set\n' >&2
    exit 1
  fi
  if ! ansible-vault view \
       --vault-password-file "$PORTAINER_PARITY_PASSWORD_FILE" \
       "$PORTAINER_PARITY_FILE" >"$parity_view" 2>/dev/null; then
    printf 'STOP: encrypted parity verification failed\n' >&2
    exit 1
  fi
  if ! ruby scripts/portainer-parity.rb --validate-stdin \
       --mapping config/portainer-parity.yml \
       --legacy-commit 400f03f276ae1bb69f5460c175b9fb923d620f1a \
       <"$parity_view" 2>/dev/null; then
    printf 'STOP: decrypted parity schema validation failed\n' >&2
    exit 1
  fi
  parity_view_cleanup
  trap - EXIT HUP INT TERM
  unset parity_header parity_view
)
```

On GNU/Linux, use `sha256sum` in place of `shasum -a 256`. Confirm that the
fresh checksum equals the importer's recorded checksum. Back up the ciphertext
and password separately with the same access controls used for production
secrets. Do not retain decrypted parity content or plaintext-derived checksums.
Do not delete any plaintext export unless the importer succeeded, the header
check printed `Encrypted parity header confirmed`, the independent checksum
matched, and the final command printed
`Portainer parity: decrypted schema is valid`.
The owned temporary view exists only during these two separately checked
commands. Normal completion, either command failure, shell exit, and handled
signals remove it; do not retain or copy the decrypted view.

## Run the adoption proof

After the importer and independent validation both succeed, keep the parity
vault and its password outside the checkout. Prepare the separate deployment
vault and password from the [secrets guide](secrets.md), and use a clean
checkout of the pinned legacy repository. From the platform repository root,
run exactly:

```sh
NAS_INFRASTRUCTURE_DIR=/absolute/clean/nas-infrastructure \
tests/mac/run.sh --lane adoption \
  --vault-file /external/deployment-vault.yml \
  --vault-password-file /external/vault-password \
  --parity-vault-file /external/portainer-parity.yml \
  --parity-vault-password-file /external/vault-password
```

The command uses disposable local state and does not contact or modify the
physical NAS. Synthetic CI is not production-parity evidence; its generated
credentials and parity export prove only the contained workflow. Reports
retain only ciphertext checksums and no values. Never place either ciphertext,
either password input, decrypted content, or plaintext exports in a report.

## Remove plaintext and retire the vault

Only after verification of the encrypted header, permissions, ciphertext
checksum, backup, and adoption-input validation, the operator explicitly
removes the protected plaintext exports. Use the workstation's approved secret
disposal procedure and confirm that all nine files and any plaintext backups
are gone. Tooling never deletes these protected sources automatically.

Retain the encrypted parity vault, its password, and protected backups while
the migration can still be rolled back. After production adoption is accepted
and the rollback window expires, the operator explicitly destroys the parity
vault and every backup, then removes the parity password if no other vault uses
it. Tooling never performs this retirement automatically. Retain only the
recorded ciphertext checksum and non-secret pass/fail evidence.
