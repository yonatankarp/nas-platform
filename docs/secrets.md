# Secrets and encrypted vault

This is the canonical operator guide for the portable credential vault. The
encrypted vault protects configuration at rest; encryption is not credential
rotation and does not change credentials already used by applications.

Handle secret values only in the password manager and the encrypted-vault
editor. Do not put credentials in chat, command-line `-e` arguments, shell
history, logs, tickets, or pull requests. Do not paste them into diagnostic
output.

## Start here: choose fresh or recovery

A fresh platform has no deployed users, databases, agents, tokens, keys, or
integrations. Only that completely new platform may use the starter generator.

If any deployed user, database, agent, token, key, or integration exists—or if
you are unsure—go to [Existing deployment recovery](#existing-deployment-recovery)
and **do not run the generator**. Recover every identity and integration
exactly. Encryption protects the configuration file; it does not rotate or
replace any deployed credential.

## Brand-new platform starter

Run repository commands from the repository root. Create a project-local
operator environment, install the exact supported Ansible tools and repository
collections, and confirm the playbook executable:

```sh
prepare_operator_environment() {
  if [ ! -d .venv ]; then
    python3 -m venv .venv || {
      printf 'STOP: could not create .venv\n' >&2
      return 1
    }
  fi
  if [ ! -f .venv/bin/activate ]; then
    printf 'STOP: .venv is not a usable Python virtual environment\n' >&2
    return 1
  fi
  . .venv/bin/activate || {
    printf 'STOP: could not activate .venv\n' >&2
    return 1
  }
  .venv/bin/python -m pip install --upgrade pip || return 1
  .venv/bin/python -m pip install \
    -r controller-requirements.txt || return 1
  .venv/bin/ansible-galaxy collection install -r requirements.yml || return 1
  .venv/bin/ansible-playbook --version || return 1
}

if ! prepare_operator_environment; then
  printf 'STOP: operator environment setup failed; do not continue\n' >&2
fi
unset -f prepare_operator_environment
```

`.venv` is the operator environment for this project. `pipx` is not required.
Stop if any setup command fails.

Prepare protected paths outside the checkout, and generate the Ansible Vault
password only when none of the protected or repository artifacts already
exists:

```sh
export PLATFORM_VAULT_DIR="$HOME/.config/nas-platform"
export PLATFORM_VAULT_FILE="$PLATFORM_VAULT_DIR/vault.yml"
export PLATFORM_VAULT_PASSWORD_FILE="$PLATFORM_VAULT_DIR/vault-password"

create_vault_password() {
  umask 077
  if [ -L "$PLATFORM_VAULT_DIR" ] || \
     { [ -e "$PLATFORM_VAULT_DIR" ] && [ ! -d "$PLATFORM_VAULT_DIR" ]; }; then
    printf 'STOP: protected directory is not a real directory: %s\n' \
      "$PLATFORM_VAULT_DIR" >&2
    return 1
  fi
  mkdir -p "$PLATFORM_VAULT_DIR" || return 1
  chmod 700 "$PLATFORM_VAULT_DIR" || return 1

  if [ -e "$PLATFORM_VAULT_PASSWORD_FILE" ] || \
     [ -L "$PLATFORM_VAULT_PASSWORD_FILE" ] || \
     [ -e "$PLATFORM_VAULT_FILE" ] || \
     [ -L "$PLATFORM_VAULT_FILE" ] || \
     [ -e inventory/group_vars/all/vault-plain.yml ] || \
     [ -L inventory/group_vars/all/vault-plain.yml ] || \
     [ -e inventory/group_vars/all/vault.yml ] || \
     [ -L inventory/group_vars/all/vault.yml ]; then
    printf 'STOP: existing vault material found; inspect it without overwriting it\n' >&2
    return 1
  fi

  platform_vault_password_tmp=$(mktemp \
    "$PLATFORM_VAULT_DIR/vault-password.tmp.XXXXXX") || return 1
  if ! openssl rand -base64 48 > "$platform_vault_password_tmp" || \
     [ ! -s "$platform_vault_password_tmp" ] || \
     ! chmod 600 "$platform_vault_password_tmp"; then
    printf 'STOP: password generation failed; final path was not created\n' >&2
    rm -f "$platform_vault_password_tmp"
    unset platform_vault_password_tmp
    return 1
  fi

  if [ -e "$PLATFORM_VAULT_PASSWORD_FILE" ] || \
     [ -L "$PLATFORM_VAULT_PASSWORD_FILE" ]; then
    printf 'STOP: vault password target appeared; refusing to overwrite it\n' >&2
    rm -f "$platform_vault_password_tmp"
    unset platform_vault_password_tmp
    return 1
  fi
  if ! mv -n "$platform_vault_password_tmp" "$PLATFORM_VAULT_PASSWORD_FILE" || \
     [ -e "$platform_vault_password_tmp" ] || \
     [ -L "$platform_vault_password_tmp" ]; then
    printf 'STOP: password could not be published without overwriting a target\n' >&2
    rm -f "$platform_vault_password_tmp"
    unset platform_vault_password_tmp
    return 1
  fi
  unset platform_vault_password_tmp

  if [ ! -f "$PLATFORM_VAULT_PASSWORD_FILE" ] || \
     [ -L "$PLATFORM_VAULT_PASSWORD_FILE" ] || \
     [ ! -s "$PLATFORM_VAULT_PASSWORD_FILE" ]; then
    printf 'STOP: final vault password file is not a nonempty regular file\n' >&2
    return 1
  fi
}

if ! create_vault_password; then
  printf 'STOP: vault password preparation failed; do not continue\n' >&2
fi
unset -f create_vault_password
```

The vault password is not an SSH key. Before generating any secrets or
encrypting the vault, store this password in the password manager and confirm
that backup can be retrieved. Never overwrite or regenerate it: losing every
copy makes the encrypted vault unrecoverable.

Run the generator only after confirming the password backup and checking again
that no external vault artifact, repository plaintext output, or repository
vault artifact exists:

```sh
brand_new_generation_ready=false
generate_brand_new_secrets() {
  if [ ! -f "$PLATFORM_VAULT_PASSWORD_FILE" ] || \
     [ -L "$PLATFORM_VAULT_PASSWORD_FILE" ] || \
     [ ! -s "$PLATFORM_VAULT_PASSWORD_FILE" ]; then
    printf 'STOP: vault password must be a nonempty regular, non-symlink file\n' >&2
    return 1
  fi
  if [ -e "$PLATFORM_VAULT_FILE" ] || \
     [ -L "$PLATFORM_VAULT_FILE" ] || \
     [ -e inventory/group_vars/all/vault-plain.yml ] || \
     [ -L inventory/group_vars/all/vault-plain.yml ] || \
     [ -e inventory/group_vars/all/vault.yml ] || \
     [ -L inventory/group_vars/all/vault.yml ]; then
    printf 'STOP: existing external, plaintext, or repository vault material found\n' >&2
    return 1
  fi
  if ansible-playbook generate-secrets.yml -e generate_brand_new_platform=true; then
    brand_new_generation_ready=true
    printf 'Plaintext generation completed; encrypt it immediately\n'
  else
    printf 'STOP: secret generation failed; do not continue\n' >&2
    return 1
  fi
}

generate_brand_new_secrets
unset -f generate_brand_new_secrets
```

The generator creates independent passwords, matching clear-password/bcrypt
pairs where both forms are required, distinct ntfy integration tokens, a
permanent Beszel universal token, an Ed25519 public/private keypair, and a
Paperless Django secret key. Its output is temporary mode-0600 plaintext. Do
not inspect that plaintext in a terminal, attach it anywhere, or leave it in
the checkout.

In the same shell, move that plaintext into a protected temporary directory,
encrypt its task-specific child file, and only then publish it at the external
vault path. This guard refuses to replace an external vault and will not proceed
without a successful generator, the protected password file, or generated
plaintext:

```sh
platform_vault_encryption_dir=
platform_vault_encryption_input=

report_platform_vault_encryption_temp() {
  printf 'STOP: protected temporary directory remains for manual inspection: %s\n' \
    "$platform_vault_encryption_dir" >&2
}

protect_generated_vault() {
  if [ "${brand_new_generation_ready:-false}" != true ]; then
    printf 'STOP: generation did not complete successfully in this shell\n' >&2
    return 1
  fi
  if [ ! -f "$PLATFORM_VAULT_PASSWORD_FILE" ] || \
     [ -L "$PLATFORM_VAULT_PASSWORD_FILE" ] || \
     [ ! -s "$PLATFORM_VAULT_PASSWORD_FILE" ]; then
    printf 'STOP: vault password must be a nonempty regular, non-symlink file\n' >&2
    return 1
  fi
  if [ -e "$PLATFORM_VAULT_FILE" ] || [ -L "$PLATFORM_VAULT_FILE" ]; then
    printf 'STOP: external vault path already exists: %s\n' \
      "$PLATFORM_VAULT_FILE" >&2
    return 1
  fi
  if [ ! -f inventory/group_vars/all/vault-plain.yml ] || \
     [ -L inventory/group_vars/all/vault-plain.yml ] || \
     [ ! -s inventory/group_vars/all/vault-plain.yml ]; then
    printf 'STOP: generated plaintext must be a nonempty regular, non-symlink file\n' >&2
    return 1
  fi
  if ! platform_vault_encryption_dir=$(mktemp -d "$PLATFORM_VAULT_DIR/.vault-encryption.XXXXXX"); then
    printf 'STOP: protected temporary encryption directory was not created\n' >&2
    return 1
  fi
  if ! chmod 700 "$platform_vault_encryption_dir" || \
     [ ! -d "$platform_vault_encryption_dir" ] || \
     [ -L "$platform_vault_encryption_dir" ]; then
    printf 'STOP: temporary encryption directory is not a protected real directory: %s\n' \
      "$platform_vault_encryption_dir" >&2
    report_platform_vault_encryption_temp
    return 1
  fi
  platform_vault_encryption_input="$platform_vault_encryption_dir/vault.yml"
  if [ -e "$platform_vault_encryption_input" ] || \
     [ -L "$platform_vault_encryption_input" ]; then
    printf 'STOP: temporary encryption child already exists or is a symlink\n' >&2
    report_platform_vault_encryption_temp
    return 1
  fi
  if ! mv -n inventory/group_vars/all/vault-plain.yml \
       "$platform_vault_encryption_input" || \
     [ -e inventory/group_vars/all/vault-plain.yml ] || \
     [ -L inventory/group_vars/all/vault-plain.yml ] || \
     [ ! -f "$platform_vault_encryption_input" ] || \
     [ -L "$platform_vault_encryption_input" ] || \
     [ ! -s "$platform_vault_encryption_input" ] || \
     ! chmod 600 "$platform_vault_encryption_input"; then
    printf 'STOP: plaintext was not safely moved into %s\n' \
      "$platform_vault_encryption_input" >&2
    report_platform_vault_encryption_temp
    return 1
  fi
  if ! ansible-vault encrypt \
       --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE" \
       "$platform_vault_encryption_input"; then
    printf 'STOP: encryption failed; protected plaintext remains at %s\n' \
      "$platform_vault_encryption_input" >&2
    report_platform_vault_encryption_temp
    return 1
  fi
  if ! chmod 600 "$platform_vault_encryption_input" || \
     [ ! -f "$platform_vault_encryption_input" ] || \
     [ -L "$platform_vault_encryption_input" ] || \
     [ ! -s "$platform_vault_encryption_input" ]; then
    printf 'STOP: encrypted artifact permissions could not be secured\n' >&2
    report_platform_vault_encryption_temp
    return 1
  fi
  if ! IFS= read -r platform_vault_header < "$platform_vault_encryption_input"; then
    printf 'STOP: cannot read encrypted temporary vault header\n' >&2
    report_platform_vault_encryption_temp
    return 1
  fi
  case "$platform_vault_header" in
    '$ANSIBLE_VAULT;'*) ;;
    *)
      printf 'STOP: temporary vault did not pass the encrypted header check\n' >&2
      unset platform_vault_header
      report_platform_vault_encryption_temp
      return 1
      ;;
  esac
  unset platform_vault_header
  if ! mv -n "$platform_vault_encryption_input" "$PLATFORM_VAULT_FILE" || \
     [ -e "$platform_vault_encryption_input" ] || \
     [ -L "$platform_vault_encryption_input" ] || \
     [ ! -f "$PLATFORM_VAULT_FILE" ] || \
     [ -L "$PLATFORM_VAULT_FILE" ] || \
     [ ! -s "$PLATFORM_VAULT_FILE" ]; then
    printf 'STOP: encrypted vault was not safely published; inspect both paths\n' >&2
    report_platform_vault_encryption_temp
    return 1
  fi
  printf 'Encrypted vault header confirmed and published at %s\n' \
    "$PLATFORM_VAULT_FILE"
  if ! rmdir -- "$platform_vault_encryption_dir"; then
    printf 'WARNING: published vault is valid, but its empty temporary directory could not be removed: %s\n' \
      "$platform_vault_encryption_dir" >&2
  fi
}

if ! protect_generated_vault; then
  printf 'STOP: vault protection failed; do not review or continue\n' >&2
fi
unset -f protect_generated_vault
unset -f report_platform_vault_encryption_temp
unset brand_new_generation_ready
unset platform_vault_encryption_input
unset platform_vault_encryption_dir
```

Only after that encrypted-header confirmation, review the result privately.
This independent guard prevents the editor from opening an unconfirmed
artifact:

```sh
if [ ! -f "$PLATFORM_VAULT_PASSWORD_FILE" ] || \
   [ -L "$PLATFORM_VAULT_PASSWORD_FILE" ] || \
   [ ! -s "$PLATFORM_VAULT_PASSWORD_FILE" ] || \
   [ ! -f "$PLATFORM_VAULT_FILE" ] || \
   [ -L "$PLATFORM_VAULT_FILE" ]; then
  printf 'STOP: protected vault inputs are unavailable or unsafe\n' >&2
elif ! IFS= read -r platform_vault_header < "$PLATFORM_VAULT_FILE"; then
  printf 'STOP: cannot read external vault header\n' >&2
else
  case "$platform_vault_header" in
    '$ANSIBLE_VAULT;'*)
      ansible-vault edit \
        --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE" \
        "$PLATFORM_VAULT_FILE"
      ;;
    *) printf 'STOP: vault is not confirmed encrypted; editor did not open\n' >&2 ;;
  esac
  unset platform_vault_header
fi
```

Review and replace the generated identity defaults with the intended
administrator usernames and emails. Also review every external integration
value, especially the Paperless Gmail account and Google app password. Quote
all YAML text scalars with single quotes by default. Represent apostrophes
inside them as doubled apostrophes. Keep every bcrypt `$` literal. Enter the
OpenSSH private key as a YAML `|` block with each key line indented by two
spaces.

Continue with [Validate without disclosure](#validate-without-disclosure), then
complete the checksum, backup, Mac proof, and repository-install steps below.

## Individual secret recipes

These recipes are for preparing an individual value for a completely new
service. They do not authorize rotating or replacing a value in an existing
deployment. Transfer generated values directly to the encrypted-vault editor
and password manager, and do not copy them through chat, logs, tickets, or
command arguments.

### Password and bcrypt-hash pairs

Read the repository's pinned ntfy image directly from its Compose YAML, without
evaluating the runtime environment interpolation in the rest of that file, then
use ntfy's own interactive password hasher:

```sh
resolve_ntfy_image() {
  .venv/bin/python - <<'PY'
import sys
from pathlib import Path

import yaml

try:
    document = yaml.safe_load(Path("services/ntfy/compose.yml").read_text())
    image = document["services"]["ntfy"]["image"]
except (OSError, KeyError, TypeError, yaml.YAMLError):
    print("STOP: could not read the pinned ntfy image", file=sys.stderr)
    raise SystemExit(1)

if not isinstance(image, str) or not image.strip():
    print("STOP: the pinned ntfy image is empty or invalid", file=sys.stderr)
    raise SystemExit(1)

print(image.strip())
PY
}

if platform_ntfy_image=$(resolve_ntfy_image) && \
   [ -n "$platform_ntfy_image" ]; then
  docker run --rm -it "$platform_ntfy_image" user hash
else
  printf 'STOP: pinned ntfy image was not resolved; hasher did not run\n' >&2
fi
unset platform_ntfy_image
unset -f resolve_ntfy_image
```

The command runs one interactive prompt sequence and requires the same password
to be entered twice. Run it separately for each clear-password/hash pair. ntfy
declarative configuration requires bcrypt hashes, and the Dozzle protected users
file also requires bcrypt. The clear administrator passwords remain necessary
for login and verification. Never replace only one side of a deployed
clear-password and hash pair.

The pinned ntfy hasher is intentionally used for Dozzle too, so both services
receive bcrypt values produced by the same repository-controlled tool. Do not
put the clear password in the command or redirect the interactive exchange to
a log.

### ntfy integration tokens

Resolve that same pinned image directly from the Compose YAML and ask ntfy to
generate a token:

```sh
resolve_ntfy_image() {
  .venv/bin/python - <<'PY'
import sys
from pathlib import Path

import yaml

try:
    document = yaml.safe_load(Path("services/ntfy/compose.yml").read_text())
    image = document["services"]["ntfy"]["image"]
except (OSError, KeyError, TypeError, yaml.YAMLError):
    print("STOP: could not read the pinned ntfy image", file=sys.stderr)
    raise SystemExit(1)

if not isinstance(image, str) or not image.strip():
    print("STOP: the pinned ntfy image is empty or invalid", file=sys.stderr)
    raise SystemExit(1)

print(image.strip())
PY
}

if platform_ntfy_image=$(resolve_ntfy_image) && \
   [ -n "$platform_ntfy_image" ]; then
  docker run --rm "$platform_ntfy_image" token generate
else
  printf 'STOP: pinned ntfy image was not resolved; token generator did not run\n' >&2
fi
unset platform_ntfy_image
unset -f resolve_ntfy_image
```

For a fresh platform, run the recipe three times: once each for the Dozzle,
Beszel, and deployment-poller integrations. All three tokens must be distinct. The command
displays each token, so transfer its output immediately to the encrypted editor
and password manager without putting it in shell history, logs, or chat.
Existing deployments must recover both deployed tokens from their authoritative
sources instead of generating replacements.

### Beszel token and Ed25519 keypair

The current contract has two hub users, a **permanent** universal token, the
agent's two-field Ed25519 public key, and the matching hub private key. There is
no separate Beszel agent API secret. The role uses the universal token plus the
public key for the agent; separate old or deprecated authentication mechanisms
are outside the current secret contract.

Generate the two hub-user clear passwords in the password manager whenever
possible: one for the superuser and a different one for the application user.
These are clear login passwords, not bcrypt hashes. If the password manager
cannot generate them, this guarded CLI recipe uses existing tooling and refuses
to display empty or identical results:

```sh
if platform_beszel_superuser_password=$(openssl rand -base64 48) && \
   platform_beszel_app_user_password=$(openssl rand -base64 48) && \
   [ -n "$platform_beszel_superuser_password" ] && \
   [ -n "$platform_beszel_app_user_password" ] && \
   [ "$platform_beszel_superuser_password" != \
     "$platform_beszel_app_user_password" ]; then
  printf 'Beszel superuser clear password:\n%s\n' \
    "$platform_beszel_superuser_password"
  printf 'Beszel application-user clear password:\n%s\n' \
    "$platform_beszel_app_user_password"
else
  printf 'STOP: two distinct Beszel hub-user passwords were not generated\n' >&2
fi
unset platform_beszel_superuser_password platform_beszel_app_user_password
```

The commands necessarily display the generated clear passwords. Transfer each
one immediately to the password manager and encrypted editor; never copy the
output into logs or chat. No password is supplied in a command argument.

The universal token is deliberately permanent rather than ephemeral. Its
persistence across service restarts makes Ansible reconciliation stable and
restart-safe. For a fresh platform, author a lowercase RFC 4122 UUID with the
documented Python environment and its standard library:

```sh
generate_beszel_universal_token() {
  .venv/bin/python - <<'PY'
import sys
import uuid

token = str(uuid.uuid4())
parsed = uuid.UUID(token)
if (not token or token != token.lower() or str(parsed) != token or
        parsed.variant != uuid.RFC_4122):
    print("STOP: generated Beszel universal token is invalid", file=sys.stderr)
    raise SystemExit(1)

print(token)
PY
}

if platform_beszel_universal_token=$(generate_beszel_universal_token) && \
   [ -n "$platform_beszel_universal_token" ]; then
  printf '%s\n' "$platform_beszel_universal_token"
else
  printf 'STOP: Beszel universal token was not generated; nothing was displayed\n' >&2
fi
unset platform_beszel_universal_token
unset -f generate_beszel_universal_token
```

Transfer the displayed token immediately to the encrypted editor and password
manager, never to logs or chat. This authored vault value is what the Ansible
role uses to create and reconcile the hub's permanent universal-token record;
creating an unrelated token only in the hub UI is not sufficient. Do not
generate a new token during ordinary reconciliation. Existing deployments must
retain and recover their deployed permanent token rather than replacing it.

Generate a keypair only for a new Beszel deployment. A task-specific protected
temporary directory keeps both files private while they are transferred:

```sh
umask 077
platform_beszel_key_dir=
platform_beszel_key_dir_created=
if platform_beszel_key_dir=$(mktemp -d) && \
   [ -n "$platform_beszel_key_dir" ] && \
   [ -d "$platform_beszel_key_dir" ]; then
  platform_beszel_key_dir_created=$platform_beszel_key_dir
  if ! ssh-keygen -t ed25519 -N '' -C 'beszel hub' \
       -f "$platform_beszel_key_dir/id_ed25519"; then
    printf 'STOP: Beszel key generation failed; inspect the protected directory\n' >&2
  fi
else
  printf 'STOP: protected Beszel temporary directory was not created\n' >&2
fi
```

For the agent public value, copy only fields 1 and 2 of the `.pub` file: the
`ssh-ed25519` type and its base64 payload, without the comment. Enter the hub
private value in the encrypted editor as an indented YAML block scalar. Never
print the private key.

Only after both the two-field public agent key and the private hub key have been
transferred into the encrypted vault, the vault has been validated, and its
backup has been confirmed, remove exactly the two generated files and the
now-empty directory:

```sh
if [ -z "${platform_beszel_key_dir:-}" ] || \
   [ -z "${platform_beszel_key_dir_created:-}" ] || \
   [ "$platform_beszel_key_dir" != "$platform_beszel_key_dir_created" ] || \
   [ ! -d "$platform_beszel_key_dir" ]; then
  printf 'STOP: Beszel temporary directory is not the created directory\n' >&2
elif [ ! -f "$platform_beszel_key_dir/id_ed25519" ] || \
     [ ! -f "$platform_beszel_key_dir/id_ed25519.pub" ]; then
  printf 'STOP: expected Beszel key files are unavailable; cleanup did not run\n' >&2
elif rm -f -- \
       "$platform_beszel_key_dir/id_ed25519" \
       "$platform_beszel_key_dir/id_ed25519.pub" && \
     rmdir -- "$platform_beszel_key_dir"; then
  unset platform_beszel_key_dir platform_beszel_key_dir_created
else
  printf 'STOP: narrow Beszel temporary-key cleanup failed\n' >&2
fi
```

For an existing deployment, discover the actual host source without displaying
the key:

```sh
sudo docker inspect beszel \
  --format '{{range .Mounts}}{{println .Type .Name .Source "->" .Destination}}{{end}}'
```

The actual source mounted at `/beszel_data` is authoritative for the hub private
key. For example, an observed source of `/volume1/Docker/beszel/hub` means that
the existing private key is `/volume1/Docker/beszel/hub/id_ed25519`. Recover it;
never print, regenerate, or replace it.

The first authoritative choice for the public half is the deployed agent's
public KEY value or its protected agent configuration. Read only that named
value; do not dump all container environment variables. If that public value is
unavailable, it is safe to derive—not regenerate—the public half from the
recovered private key. This public-only command locates the actual private path
from the inspected mount, derives its public half, and normalizes it to fields 1
and 2:

```sh
platform_beszel_data_source=$(
  sudo docker inspect beszel \
    --format '{{range .Mounts}}{{if eq .Destination "/beszel_data"}}{{println .Source}}{{end}}{{end}}'
)
if [ -z "$platform_beszel_data_source" ]; then
  printf 'STOP: Beszel data source was not resolved; derivation did not run\n' >&2
else
  platform_beszel_private_key=$platform_beszel_data_source/id_ed25519
  if platform_beszel_public_key=$(
       sudo ssh-keygen -y -f "$platform_beszel_private_key"
     ); then
    if ! printf '%s\n' "$platform_beszel_public_key" | \
         awk '$1 == "ssh-ed25519" && NF >= 2 { print $1, $2; found=1; exit }
              END { if (!found) exit 1 }'; then
      printf 'STOP: derived Beszel public key was not valid Ed25519 output\n' >&2
    fi
  else
    printf 'STOP: Beszel public-key derivation failed\n' >&2
  fi
fi
unset platform_beszel_public_key platform_beszel_private_key
unset platform_beszel_data_source
```

If both the deployed agent value and the derived public value are available,
compare their normalized two-field forms and stop on any mismatch. Preserve the
existing pair; deriving a public half from its recovered private half does not
create a new keypair.

### Paperless signing and mail values

The Django signing key becomes `PAPERLESS_SECRET_KEY`; it is application
signing material, not a Paperless login password. For a fresh service, generate
it with:

```sh
openssl rand -base64 48
```

This command displays the new value. Move it immediately into the encrypted
editor and password manager without copying it into logs or chat. An existing
Paperless service must recover its current `PAPERLESS_SECRET_KEY` from its
protected Compose environment or environment file rather than generating a new
one.

Paperless mail account and rule names are stable labels from the Paperless UI,
not passwords. The Gmail address identifies the account. The Google app
password is the credential for that identity and is not the account's normal
Google password.

## Existing deployment recovery

Run every repository command from the repository root. Use the guarded operator
environment setup block from the starter before handling any private material,
and stop if it reports `STOP`. Do not run any of the starter's generation
blocks. Collect the existing private values from the password manager,
the deployed Compose environment and configuration, application and
database configuration, ntfy, Beszel, and Paperless. Copy identities, hashes,
tokens, database values, keys, and external integrations exactly; do not
normalize, rotate, or regenerate them. A missing deployed value is a stop
condition: recover it or resolve the migration source before proceeding.

`generate-secrets.yml` is forbidden for migration. It creates new identities
that will not match existing applications, databases, agents, or integrations;
do not run the generator.

### Vault contract inventory

Use `inventory/group_vars/all/vault.yml.example` as the schema, never as a
source of values. Every key below is required.

- Audiobookshelf: `vault_audiobookshelf_admin_username`, `vault_audiobookshelf_admin_password`. Recover the deployed administrator identity from the current application and its matching password from the password manager; preserve the pair unchanged.
- Dozzle: `vault_dozzle_admin_username`, `vault_dozzle_admin_password`, `vault_dozzle_admin_password_hash`. Recover the administrator identity and clear password from the password manager/current Dozzle login, and recover its stored bcrypt hash from the deployed protected users file or the deployed Compose configuration. The clear password and hash must be the matching pair for that login; do not replace one independently. The hash is a 60-character bcrypt value: a `$2a$`, `$2b$`, or `$2y$` marker, a two-digit cost, and the bcrypt payload.
- Immich: `vault_immich_admin_email`, `vault_immich_admin_password`, `vault_immich_db_name`, `vault_immich_db_username`, `vault_immich_db_password`. Recover the administrator identity from the current application and password manager. Recover the database name, user, and password together from the deployed Compose environment and database stack, checking them against the database that owns the existing data. The email must contain a nonempty local and domain part. Database identifiers must start with a letter or underscore and then contain only letters, digits, underscores, or hyphens.
- Jellyfin: `vault_jellyfin_admin_username`, `vault_jellyfin_admin_password`, `vault_jellyfin_opensubtitles_username`, `vault_jellyfin_opensubtitles_password`. The managed administrator username is exactly `Yonatan`; recover its matching password from the password manager. Recover the existing OpenSubtitles account credentials from the password manager or deployed Jellyfin plugin configuration. Preserve both credential pairs unchanged; the example and generated plaintext placeholders are not valid deployment values.
- Komga: `vault_komga_admin_email`, `vault_komga_admin_password`. Recover the deployed administrator identity from the current application and its matching password from the password manager. The email must contain a nonempty local and domain part.
- ntfy: `vault_ntfy_admin_user`, `vault_ntfy_admin_password`, `vault_ntfy_admin_password_hash`, `vault_ntfy_dozzle_password_hash`, `vault_ntfy_dozzle_token`, `vault_ntfy_beszel_password_hash`, `vault_ntfy_beszel_token`, `vault_ntfy_deploy_password_hash`, `vault_ntfy_deploy_token`. Recover the administrator name and clear password from the password manager/current login, and recover the administrator hash, integration-user hashes, and access tokens from the deployed ntfy configuration and authentication data. The administrator password and hash must be the matching deployed pair. Preserve each Dozzle, Beszel or deploy hash with that same integration identity's token; do not infer a clear password from a hash or create a replacement token. Each hash has the bcrypt shape described above. Each access token is `tk_` followed by 29 lowercase letters or digits, and the Dozzle, Beszel and deploy tokens must all be distinct.
- Beszel: `vault_beszel_superuser_email`, `vault_beszel_superuser_password`, `vault_beszel_app_user_email`, `vault_beszel_app_user_password`, `vault_beszel_agent_key`, `vault_beszel_universal_token`, `vault_beszel_hub_private_key`. Recover both deployed hub identities from the current Beszel hub and their matching passwords from the password manager. Recover the universal token and public agent key from the deployed agent configuration, and recover the matching OpenSSH Ed25519 private key from the hub's protected key file. If the agent's public value is unavailable, derive its public half from the recovered private key as described above; if both sources exist, compare them. Never regenerate or replace the pair. Both emails need nonempty local and domain parts. The universal token must be a lowercase RFC 4122 UUID. The agent key contains exactly two whitespace-separated fields, the `ssh-ed25519` type and its base64 public key, with no comment.
- Paperless: `vault_paperless_admin_username`, `vault_paperless_admin_password`, `vault_paperless_admin_email`, `vault_paperless_db_name`, `vault_paperless_db_username`, `vault_paperless_db_password`, `vault_paperless_django_secret_key`, `vault_paperless_gmail_account`, `vault_paperless_gmail_app_password`, `vault_paperless_mail_account_name`, `vault_paperless_mail_rule_name`. Recover the administrator identity from the current Paperless application and its password from the password manager. Recover the database name, user, and password together from the deployed Compose environment and database stack; recover the Django signing key from the deployed application/Compose environment. Recover the mail account and rule names plus Gmail account from current Paperless mail configuration, and recover the matching Gmail app password from the password manager or protected deployed mail configuration. Use the Google account only to confirm the named account and existing app-password registration; do not create a replacement. Preserve these as one deployed identity set. The email fields need nonempty local and domain parts; database identifiers follow the Immich rules. The Gmail credential must be an app password for the named account, handled according to [Google's app-password guidance](https://support.google.com/accounts/answer/185833), not the normal account password.
- tinyMediaManager: `vault_tinymediamanager_password`. Recover the deployed API password from the current tinyMediaManager configuration and confirm it against an existing client; changing it breaks those clients.
- Managed application users: `vault_managed_users`. This mapping has exactly the eight service lists documented below. Identity comparisons trim surrounding whitespace and ignore case. Every list entry needs a non-empty preserved password, must be unique within its service, and must not duplicate that service's primary administrator. Beszel entries also differ from the primary Beszel application user; ntfy entries differ from the Dozzle and Beszel publishers. Do not add tinyMediaManager here because it retains its single shared-login contract.

### Managed application-user fields

These lists declare only identities the platform owns. They do not authorize
deleting users outside the lists, and they do not authorize replacing the
password of an existing identity. During migration, recover each existing
identity and matching password from its authoritative source. The examples are
synthetic schema illustrations, not deployable credentials.

The portable vault contract validates bcrypt shape only; it does not attempt a
portable cryptographic password/hash comparison on the Ansible controller. The
service-specific reconciliation authenticates the plaintext password and
compares the stored hash before mutation through the pinned application
interface. A newly created identity immediately authenticates with its vault
password before any later non-secret or privilege repair. A mismatch stops
reconciliation rather than rotating credentials.

#### audiobookshelf managed users

`username` is the login identity; `password` is its preserved clear credential;
`type` is `admin`, `user`, or `guest`; `is_active` must be `true` so every run
can prove the preserved password before reconciliation; and `permissions`
contains `flags`, `librariesAccessible`, and `itemTagsSelected`. `flags` is an
exact subset of the pinned boolean permission fields; the two lists map to the
top-level fields returned by Audiobookshelf 2.36.0. Undeclared expanded flags
remain unchanged. Managed identities cannot duplicate the root administrator.

#### beszel managed users

`email` is the normalized login identity; `password` is its preserved clear
credential; `role` is `user` or `admin`; and `verified` must be `true`.
Beszel 0.18.7 password authentication requires verified users, so an existing
unverified identity fails with credential-migration guidance and is never
auto-verified. A managed identity cannot duplicate either the Beszel superuser
or the existing primary application user.

#### dozzle managed users

`username` is the login identity; `password` is its preserved clear credential;
`password_hash` is the matching 60-character bcrypt value; `email` is either
empty or a syntactically valid address; `name` is the displayed name; `filter`
is the native container filter string; and `roles` is one supported Dozzle role:
`none`, `user`, or `admin`. Never replace one half of the clear-password/hash
pair independently. Before reconciliation, the role opens the existing users
file once in nonblocking mode with no symlink following, validates that opened
descriptor as a regular file, and enforces a 1 MiB read limit. The subsequent
template update uses Ansible's atomic writer with unsafe writes disabled.

#### immich managed users

`email` is the normalized login identity; `password` is its preserved clear
credential; `name` is the displayed name; and `quota_size` is a non-negative
integer in the units expected by the pinned Immich API. Administrator status is
not part of this allowlist contract.

#### jellyfin managed users

`username` is the login identity; `password` is its preserved clear credential;
and `policy` is an exact mapping of declared, supported boolean Jellyfin policy
fields. Reconciliation merges those fields into the complete policy returned by
Jellyfin so required provider IDs and every undeclared field remain unchanged.
Password, provider, credential, token, and server-maintained fields are not part
of the vault policy contract. `IsDisabled: true` is rejected because it would
prevent mandatory password proof on later runs; an already-disabled account
fails authentication with migration guidance and is never enabled before that
proof. Keep administrative access disabled unless a separately reviewed policy
explicitly requires it.

#### komga managed users

`email` is the normalized login identity; `password` is its preserved clear
credential; and `roles` is a non-empty unique list drawn from `ADMIN`,
`FILE_DOWNLOAD`, `PAGE_STREAMING`, `KOBO_SYNC`, and `KOREADER_SYNC`. The administrator
identity remains under the separate primary credential contract.

#### ntfy managed users

`username` is the login identity; `password` is its preserved clear credential;
`password_hash` is the matching bcrypt value; `role` is exactly `user` because
managed entries are interactive nonadministrative accounts; `access` is a list
of exact literal `topic` and `permission` mappings; and
`tokens` is a unique list of owned `tk_` tokens, which may be empty. Supported
permissions are `read-only`, `write-only`, `read-write`, and `deny`. Managed
topics use only letters, digits, `_`, and `-`, with a maximum of 64 characters;
wildcards, URL separators, whitespace, commas, and colons are not supported by
this exact verifier. Usernames follow ntfy's native letters, digits, `_`, `-`,
`.`, `+`, and `@` contract. Publisher and administrator identities remain under
their separate noninteractive and primary-credential contracts. Managed
identities cannot duplicate the administrator or the Dozzle, Beszel, and deploy
publishers. The role treats the
prior rendered ntfy `.env` as the declarative ownership record and confirms
database identities with the pinned `ntfy user list` command before rendering a
replacement. An owned identity must retain its exact prior hash; a same-name
database identity outside that record is refused for automatic adoption. A
server-config identity absent from that record is also refused, preventing ntfy
from deleting state outside reviewed ownership. Removing an identity already
present in the prior ownership record remains an explicit declarative removal
from the reviewed desired configuration. If an existing authentication database
has no prior ownership record, restore reviewed migration evidence instead of
regenerating credentials.

#### paperless_ngx managed users

`username` is the normalized login identity; `password` is its preserved clear
credential; `email` is the account address; `is_active`, `is_staff`, and
`is_superuser` are booleans; and `groups` is a unique list of exact Django group
names, which may be empty. `is_active` must be true because every managed user
must prove its preserved password before reconciliation; disabling a user would
make the next converge unable to perform that proof. The separately managed
Paperless administrator may not appear in this list.

These requirements describe relationships as well as syntax. Do not fabricate
values merely to satisfy the contract.

### Prepare protected external files

Keep the working vault and its password outside the checkout. These variable
names are used throughout this guide; `HOME` remains the user's real home and
is never reassigned.

```sh
export PLATFORM_VAULT_DIR="$HOME/.config/nas-platform"
export PLATFORM_VAULT_FILE="$PLATFORM_VAULT_DIR/vault.yml"
export PLATFORM_VAULT_PASSWORD_FILE="$PLATFORM_VAULT_DIR/vault-password"

prepare_recovery_vault_dir() {
  umask 077
  if [ -L "$PLATFORM_VAULT_DIR" ] || \
     { [ -e "$PLATFORM_VAULT_DIR" ] && [ ! -d "$PLATFORM_VAULT_DIR" ]; }; then
    printf 'STOP: protected directory is a symlink or non-directory: %s\n' \
      "$PLATFORM_VAULT_DIR" >&2
    return 1
  fi
  mkdir -p "$PLATFORM_VAULT_DIR" || return 1
  if [ -L "$PLATFORM_VAULT_DIR" ] || [ ! -d "$PLATFORM_VAULT_DIR" ]; then
    printf 'STOP: protected directory changed during preparation: %s\n' \
      "$PLATFORM_VAULT_DIR" >&2
    return 1
  fi
  chmod 700 "$PLATFORM_VAULT_DIR" || return 1
  platform_vault_dir_check=$(find "$PLATFORM_VAULT_DIR" -prune \
    -type d -perm 0700 -print 2>/dev/null)
  if [ -L "$PLATFORM_VAULT_DIR" ] || \
     [ "$platform_vault_dir_check" != "$PLATFORM_VAULT_DIR" ]; then
    printf 'STOP: protected directory is not a real mode-0700 directory\n' >&2
    unset platform_vault_dir_check
    return 1
  fi
  unset platform_vault_dir_check
  printf 'Protected mode-0700 directory confirmed\n'
}

if ! prepare_recovery_vault_dir; then
  printf 'STOP: protected directory preparation failed; do not continue\n' >&2
fi
unset -f prepare_recovery_vault_dir
```

Refuse to overwrite either artifact. This block reports every conflicting path
without terminating an interactive shell. If it prints `STOP`, inspect and back
up the existing files, then stop this procedure; do not run the creation blocks.

```sh
platform_vault_dir_check=$(find "$PLATFORM_VAULT_DIR" -prune \
  -type d -perm 0700 -print 2>/dev/null)
if [ -L "$PLATFORM_VAULT_DIR" ] || \
   [ "$platform_vault_dir_check" != "$PLATFORM_VAULT_DIR" ]; then
  printf 'STOP: protected directory is not a real mode-0700 directory\n' >&2
elif [ -e "$PLATFORM_VAULT_PASSWORD_FILE" ] || \
   [ -L "$PLATFORM_VAULT_PASSWORD_FILE" ] || \
   [ -e "$PLATFORM_VAULT_FILE" ] || \
   [ -L "$PLATFORM_VAULT_FILE" ]; then
  { [ ! -e "$PLATFORM_VAULT_PASSWORD_FILE" ] && \
    [ ! -L "$PLATFORM_VAULT_PASSWORD_FILE" ]; } || \
    printf 'Existing vault password file: %s\n' "$PLATFORM_VAULT_PASSWORD_FILE" >&2
  { [ ! -e "$PLATFORM_VAULT_FILE" ] && [ ! -L "$PLATFORM_VAULT_FILE" ]; } || \
    printf 'Existing external vault path: %s\n' "$PLATFORM_VAULT_FILE" >&2
  printf 'STOP: refusing to overwrite protected files\n' >&2
else
  printf 'Protected paths are available for new files\n'
fi
unset platform_vault_dir_check
```

Generate a strong, unique password in the password manager, then enter that
password as one line through an editor. Do not supply it on a command line. If
set, `EDITOR` must be a single executable name or path with no arguments; a
multiword value such as `code --wait` is not supported. Use an executable
wrapper when an editor needs arguments. The same rule applies when Ansible Vault
opens the vault editor.

```sh
platform_vault_dir_check=$(find "$PLATFORM_VAULT_DIR" -prune \
  -type d -perm 0700 -print 2>/dev/null)
if [ -L "$PLATFORM_VAULT_DIR" ] || \
   [ "$platform_vault_dir_check" != "$PLATFORM_VAULT_DIR" ]; then
  printf 'STOP: protected directory is not a real mode-0700 directory\n' >&2
elif [ -e "$PLATFORM_VAULT_PASSWORD_FILE" ] || \
   [ -L "$PLATFORM_VAULT_PASSWORD_FILE" ] || \
   [ -e "$PLATFORM_VAULT_FILE" ] || \
   [ -L "$PLATFORM_VAULT_FILE" ]; then
  printf 'STOP: protected path appeared; inspect it before continuing\n' >&2
else
  if [ -n "${EDITOR:-}" ]; then
    vault_editor=$EDITOR
  else
    vault_editor=vi
  fi
  if "$vault_editor" "$PLATFORM_VAULT_PASSWORD_FILE"; then
    chmod 600 "$PLATFORM_VAULT_PASSWORD_FILE"
    password_lines=$(awk 'END { print NR }' "$PLATFORM_VAULT_PASSWORD_FILE")
    if [ "$password_lines" -ne 1 ] || [ ! -s "$PLATFORM_VAULT_PASSWORD_FILE" ] || \
       ! awk 'NR == 1 && length($0) > 0 { valid=1 } END { exit !valid }' \
         "$PLATFORM_VAULT_PASSWORD_FILE"; then
      printf 'STOP: password must be one non-empty line; inspect the protected file\n' >&2
    else
      printf 'Vault password file is ready\n'
    fi
    unset password_lines
  else
    printf 'STOP: editor failed; password file is not ready\n' >&2
  fi
  unset vault_editor
fi
unset platform_vault_dir_check
```

Confirm the password file now exists and the vault still does not. Then create
the external vault directly in encrypted form; the mutation is inside the safe
branch and cannot run when either precondition fails:

```sh
platform_vault_dir_check=$(find "$PLATFORM_VAULT_DIR" -prune \
  -type d -perm 0700 -print 2>/dev/null)
if [ -L "$PLATFORM_VAULT_DIR" ] || \
   [ "$platform_vault_dir_check" != "$PLATFORM_VAULT_DIR" ]; then
  printf 'STOP: protected directory is not a real mode-0700 directory\n' >&2
elif [ ! -f "$PLATFORM_VAULT_PASSWORD_FILE" ] || \
   [ -L "$PLATFORM_VAULT_PASSWORD_FILE" ] || \
   [ ! -s "$PLATFORM_VAULT_PASSWORD_FILE" ]; then
  printf 'STOP: vault password must be a nonempty regular, non-symlink file\n' >&2
elif [ "$(awk 'END { print NR }' "$PLATFORM_VAULT_PASSWORD_FILE")" -ne 1 ] || \
     ! awk 'NR == 1 && length($0) > 0 { valid=1 } END { exit !valid }' \
       "$PLATFORM_VAULT_PASSWORD_FILE"; then
  printf 'STOP: vault password must be exactly one non-empty line\n' >&2
elif [ -e "$PLATFORM_VAULT_FILE" ] || [ -L "$PLATFORM_VAULT_FILE" ]; then
  printf 'STOP: external vault path already exists: %s\n' "$PLATFORM_VAULT_FILE" >&2
else
  if ansible-vault create \
       --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE" \
       "$PLATFORM_VAULT_FILE"; then
    chmod 600 "$PLATFORM_VAULT_FILE"
  else
    printf 'STOP: encrypted vault creation failed\n' >&2
  fi
fi
unset platform_vault_dir_check
```

Both protected files must remain mode 0600.

In the editor, reproduce the schema and enter only recovered deployed values.
Single-quote YAML scalars by default; represent an apostrophe inside a
single-quoted scalar by doubling it. A bcrypt hash's `$` characters are literal
data and must not be shell-expanded or changed. Enter the OpenSSH private key as
a YAML `|` block and indent every key line beneath it by two spaces.

Remove every sanitized placeholder family before saving: `example-*` values,
addresses under the reserved invalid domain, `replace-with-*` prompts,
repeated-zero hashes, tokens and UUIDs, abbreviated SSH public keys, and dummy
PEM bodies. None is deployed credential material.

## Validate without disclosure

Check only metadata and the encryption header. `ls` is portable across macOS
and GNU/Linux; both files must display as `-rw-------` and the directory as
`drwx------`.

```sh
ls -ld "$PLATFORM_VAULT_DIR"
ls -l "$PLATFORM_VAULT_PASSWORD_FILE" "$PLATFORM_VAULT_FILE"
IFS= read -r vault_header < "$PLATFORM_VAULT_FILE"
case "$vault_header" in
  '$ANSIBLE_VAULT;'*) printf 'Encrypted vault header confirmed\n' ;;
  *) printf 'STOP: vault is not encrypted: %s\n' "$PLATFORM_VAULT_FILE" >&2 ;;
esac
unset vault_header
```

If the header check prints `STOP`, do not continue. Otherwise run the redacted
contract validation from the repository root:

```sh
ansible-playbook validate-vault.yml \
  --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE" \
  -e @"$PLATFORM_VAULT_FILE" \
  -e "platform_vault_file=$PLATFORM_VAULT_FILE"
```

This proves required fields and shapes without printing values. It cannot prove
that an email is the intended fresh identity or recovered deployed identity,
that a password matches its application, that a hash matches its password, or
that a keypair and integration work. Privately review fresh values against the
intended platform identities and integrations; for recovery, review values
against the authoritative deployed sources:

```sh
if [ ! -f "$PLATFORM_VAULT_PASSWORD_FILE" ] || \
   [ -L "$PLATFORM_VAULT_PASSWORD_FILE" ] || \
   [ ! -s "$PLATFORM_VAULT_PASSWORD_FILE" ] || \
   [ ! -f "$PLATFORM_VAULT_FILE" ] || \
   [ -L "$PLATFORM_VAULT_FILE" ]; then
  printf 'STOP: protected vault inputs are unavailable or unsafe\n' >&2
elif ! IFS= read -r platform_vault_header < "$PLATFORM_VAULT_FILE"; then
  printf 'STOP: cannot read external vault header\n' >&2
else
  case "$platform_vault_header" in
    '$ANSIBLE_VAULT;'*)
      ansible-vault edit \
        --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE" \
        "$PLATFORM_VAULT_FILE"
      ;;
    *) printf 'STOP: vault is not confirmed encrypted; editor did not open\n' >&2 ;;
  esac
  unset platform_vault_header
fi
```

## Record and back up the encrypted vault

A SHA-256 of ciphertext is safe to record as the identity of the encrypted
artifact; it is not a checksum of plaintext values. Use the command for the
operator workstation:

macOS:

```sh
shasum -a 256 "$PLATFORM_VAULT_FILE"
```

GNU/Linux:

```sh
sha256sum "$PLATFORM_VAULT_FILE"
```

Back up the encrypted artifact and the vault password separately, with access
controls appropriate to each. The password belongs in the password manager;
loss of every password copy makes the ciphertext unrecoverable. An encrypted
vault is not a backup of application databases or state.

Deployment renders plaintext into protected runtime locations. In particular,
service environment files live beneath the configured platform runtime
directory's `services/*/.env`; Dozzle also writes its protected users file,
Beszel installs the hub private key in its protected data directory, and
applications and databases retain credentials in their own data/configuration.
Treat those runtime paths and all backups as secret-bearing even though the
repository vault remains encrypted.

## Preparation and validation handoff

The external vault is ready for the disposable proof only after its permissions
and header pass, the redacted contract validation succeeds, the private review
confirms the intended fresh values or recovered deployed values as applicable,
and both protected inputs are backed up as described above. Operators following
the Mac walkthrough should now return to [step 3, Run the complete fresh
proof](getting-started-mac.md#3-run-the-complete-fresh-proof).

## Run the complete Mac proof

Before production use, complete the disposable Mac proof and its manual review,
starting at
[step 3 of the Mac walkthrough](getting-started-mac.md#3-run-the-complete-fresh-proof).
The complete fresh-proof command is:

```sh
tests/mac/run.sh \
  --lane fresh \
  --vault-file "$PLATFORM_VAULT_FILE" \
  --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE"
```

Do not continue to NAS installation until the complete proof and its review
pass.

## Install reviewed vault for NAS

Only after validation, private review, and the complete proof pass, copy the
ciphertext into the repository location for NAS deployment. The destination
gate prevents `install` from overwriting an existing repository vault. If one
exists, stop and inspect it; decide explicitly whether to reuse it or back it up
before beginning a separate replacement procedure.

```sh
if [ -e inventory/group_vars/all/vault.yml ] || \
   [ -L inventory/group_vars/all/vault.yml ]; then
  printf 'STOP: repository vault already exists; inspect or reuse it: %s\n' \
    inventory/group_vars/all/vault.yml >&2
else
  install -m 600 "$PLATFORM_VAULT_FILE" inventory/group_vars/all/vault.yml
fi
```

Only when the preceding block installs a new file, check its header and status:

```sh
IFS= read -r vault_header < inventory/group_vars/all/vault.yml
case "$vault_header" in
  '$ANSIBLE_VAULT;'*) printf 'Encrypted repository vault header confirmed\n' ;;
  *) printf 'STOP: repository vault is not encrypted: %s\n' \
       inventory/group_vars/all/vault.yml >&2 ;;
esac
unset vault_header
git status --short inventory/group_vars/all/vault.yml
```

Repository policy may permit committing that encrypted artifact. Never commit
the vault password, plaintext or decrypted vaults, rendered environment files,
temporary private keys, application/database configuration containing secrets,
or secret-bearing logs. For an existing-deployment recovery,
`generate-secrets.yml` remains forbidden.

Git preserves only the executable bit, not owner-only mode `0600`. After every
clone, checkout, or rebase that materializes the committed vault, restore its
local permissions before using it:

```sh
chmod 600 inventory/group_vars/all/vault.yml
```

## Add a new secret

Adding ciphertext to the vault is not enough. A new secret is a coordinated
schema, consumer, generation, test, and documentation change. Update the full
contract before editing the encrypted value:

- Add the field and safe placeholder to
  `inventory/group_vars/all/vault.yml.example`.
- Declare and validate it in `roles/vault_contract/meta/argument_specs.yml` and
  `roles/vault_contract/tasks/main.yml`.
- Wire it through the consuming role's `meta/argument_specs.yml`, templates,
  and tasks. Update the service contract and policy tests that prove the value
  reaches its intended protected destination without disclosure.
- When fresh-platform generation supports the value, update
  `generate-secrets.yml`, `templates/vault-plain.yml.j2`, and
  `tests/generate-ephemeral-vault.sh`. Keep those generator, template, and
  ephemeral-vault changes together so a newly generated platform satisfies the
  same contract.
- Update `docs/secrets.md` with the value's source, format, relationships,
  recovery rule, and any applicable generation recipe.

After the schema and consumer changes are complete, edit the existing encrypted
repository vault in place:

```sh
ansible-vault edit \
  --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE" \
  inventory/group_vars/all/vault.yml
```

Add the value as safely quoted YAML: single-quote text scalars by default,
double any apostrophe inside a single-quoted scalar, preserve literal `$`
characters, and use an indented `|` block for multiline private keys. An
existing integration must recover its deployed value from the authoritative
source. A genuinely new integration may use the applicable recipe in
[Individual secret recipes](#individual-secret-recipes); do not regenerate an
existing credential merely because the schema is new.

Run the redacted contract validation and policy suite after the edit:

```sh
ansible-playbook validate-vault.yml \
  --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE"
tests/validate-policy.sh
```

Privately verify that the consumer works with the intended integration. Commit
only the encrypted `inventory/group_vars/all/vault.yml`, along with its schema,
consumer, test, and documentation changes. Never commit a plaintext vault,
password file, generated secret, rendered secret-bearing file, or secret log.

## Use the vault

Keep the controller vault password outside the repository, whether the
controller is a workstation or the NAS itself.

Never decrypt a vault onto disk.

### Workstation controller

The workstation is the Ansible controller: it opens and decrypts the vault
locally, then sends only the required rendered configuration over the managed
connection. The NAS does not need the vault password file.

Use the encrypted editor for safe changes:

```sh
ansible-vault edit \
  --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE" \
  inventory/group_vars/all/vault.yml
```

Export the target address and SSH user, then run a remote check. Review the
diff carefully before applying it. `nasadmin` matches the installation-guide
example; replace it with the operator's actual NAS SSH account when different:

```sh
export PLATFORM_NAS_ADDRESS='nas.example.internal'
export PLATFORM_NAS_USER='nasadmin'
export PLATFORM_PUBLIC_HOST='nas.example.ts.net'
ansible-playbook -i inventory/remote.yml site.yml \
  --check --diff \
  --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE"
```

After the check and diff are approved, apply the same playbook without
`--check` or `--diff`:

```sh
ansible-playbook -i inventory/remote.yml site.yml \
  --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE"
```

As an interactive alternative, omit the password-file option and let Ansible
prompt for the vault password. Do not combine the two password methods:

```sh
ansible-playbook -i inventory/remote.yml site.yml \
  --check --diff --ask-vault-pass
```

### NAS-local controller

For local execution, the NAS is the Ansible controller. The recommended
one-off workflow is interactive: the NAS receives the vault password at the
prompt and does not need to store it. Set the platform address used by the
roles, then check and review the local run:

```sh
export PLATFORM_NAS_ADDRESS='nas.example.internal'
export PLATFORM_PUBLIC_HOST='nas.example.ts.net'
ansible-playbook -i inventory/local.yml site.yml \
  --check --diff --ask-vault-pass
```

After review, apply without the check and diff flags:

```sh
ansible-playbook -i inventory/local.yml site.yml --ask-vault-pass
```

For unattended runs, use either a mode-0600 regular, non-symlink password file
or an executable password-manager provider, always outside the repository.
Keep its containing directory mode 0700. If a password is stored on the NAS,
both the NAS account that owns it and root can decrypt the vault; restrict and
audit those accounts accordingly. Use the provider with
`--vault-password-file` only after that storage and access decision has been
reviewed. Do not transfer a password through a shell command or write it with
`echo`.

### Production auto-deployment inputs

The NAS poller requires the reviewed encrypted vault at
`$HOME/.config/nas-platform/vault.yml` and its provider at
`$HOME/.config/nas-platform/vault-password`. Both live outside the controller
checkout, because the poller rewrites that checkout on every deployment. Copy
the encrypted vault there from the checkout's
`inventory/group_vars/all/vault.yml`, which is committed. The password provider
is never committed, and both inputs are never logged.
The containing `$HOME/.config/nas-platform` directory must be mode `0700`.

Each input must be a mode-0600 regular, non-symlink file owned by the dedicated
deployment account. The password input may be the protected one-line password
file used during bootstrap. Do not pass either value through argv, an
environment variable, cron source, or notification. The installer validates
the paths before activation, and the poller reads them only for the local
Ansible runs described in the
[physical NAS walkthrough](getting-started-nas.md#automatic-deployment-from-the-nas).

## Vault password rotation boundary

Do not rekey one vault artifact ad hoc. Password rotation requires a separately
reviewed procedure that covers every operational encrypted-vault copy, the
password-provider cutover, validation, backup, and rollback. Retain the old
password until every copy and provider has completed that procedure
successfully. A partial rotation can leave operators or automation unable to
open the vault, so this guide intentionally provides no command recipe.
