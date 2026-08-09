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

Use external absolute paths throughout the procedure:

```sh
export PORTAINER_ENV_DIR="$HOME/.config/nas-platform/portainer-env"
export PORTAINER_PARITY_FILE="$HOME/.config/nas-platform/parity/portainer-parity.yml"
export PORTAINER_PARITY_PASSWORD_FILE="$HOME/.config/nas-platform/parity/vault-password"
```

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
ls -ld "$PORTAINER_ENV_DIR" "$(dirname "$PORTAINER_PARITY_FILE")"
ls -l "$PORTAINER_ENV_DIR"/*.env \
  "$PORTAINER_PARITY_FILE" "$PORTAINER_PARITY_PASSWORD_FILE"
IFS= read -r parity_header < "$PORTAINER_PARITY_FILE"
case "$parity_header" in
  '$ANSIBLE_VAULT;'*) printf 'Encrypted parity header confirmed\n' ;;
  *) printf 'STOP: parity artifact is not encrypted\n' >&2 ;;
esac
shasum -a 256 "$PORTAINER_PARITY_FILE"
unset parity_header
```

On GNU/Linux, use `sha256sum` in place of `shasum -a 256`. Confirm that the
fresh checksum equals the importer's recorded checksum. Back up the ciphertext
and password separately with the same access controls used for production
secrets. Do not retain decrypted parity content or plaintext-derived checksums.

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
