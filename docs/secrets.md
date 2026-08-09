# Secrets and encrypted vault

This is the canonical operator guide for the portable credential vault. The
normal path is migration or adoption: preserve every deployed identity and
integration exactly. The encrypted vault is configuration, not a credential
rotation mechanism.

## Migration workflow

Run every repository command from the Task 13 worktree root. Prepare the pinned
Ansible environment before handling any private material:

```sh
. .venv/bin/activate
ansible-galaxy collection install -r requirements.yml
ansible-playbook --version
```

Stop if the virtual environment, required collections, or playbook command is
unavailable. Collect the existing private values from the password manager,
Portainer, deployed Compose environment and configuration, application and
database configuration, ntfy, Beszel, and Paperless. Copy identities, hashes,
tokens, database values, keys, and external integrations exactly; do not
normalize, rotate, or regenerate them. A missing deployed value is a stop
condition: recover it or resolve the migration source before proceeding.

`generate-secrets.yml` is forbidden for migration. It creates new identities
that will not match existing applications, databases, agents, or integrations.

Handle values only in the password manager and the encrypted-vault editor. Do
not put credentials in chat, command-line `-e` arguments, shell history, logs,
tickets, or pull requests. Do not paste them into diagnostic output.

### Vault contract inventory

Use `inventory/group_vars/all/vault.yml.example` as the schema, never as a
source of values. Every key below is required.

- Audiobookshelf: `vault_audiobookshelf_admin_username`, `vault_audiobookshelf_admin_password`. Preserve the deployed administrator login.
- Dozzle: `vault_dozzle_admin_username`, `vault_dozzle_admin_password`, `vault_dozzle_admin_password_hash`. The clear password and stored hash must describe the same deployed login. The hash is a 60-character bcrypt value: a `$2a$`, `$2b$`, or `$2y$` marker, a two-digit cost, and the bcrypt payload.
- Immich: `vault_immich_admin_email`, `vault_immich_admin_password`, `vault_immich_db_name`, `vault_immich_db_username`, `vault_immich_db_password`. The email must contain a nonempty local and domain part. Database identifiers must start with a letter or underscore and then contain only letters, digits, underscores, or hyphens. Preserve the database identity and password together with its existing data.
- Jellyfin: `vault_jellyfin_admin_username`, `vault_jellyfin_admin_password`. Preserve the deployed administrator login.
- Komga: `vault_komga_admin_email`, `vault_komga_admin_password`. Use the deployed account; the email must contain a nonempty local and domain part.
- ntfy: `vault_ntfy_admin_user`, `vault_ntfy_admin_password`, `vault_ntfy_admin_password_hash`, `vault_ntfy_dozzle_password_hash`, `vault_ntfy_dozzle_token`, `vault_ntfy_beszel_password_hash`, `vault_ntfy_beszel_token`. Each hash has the bcrypt shape described above and must match its deployed password relationship. Each access token is `tk_` followed by 29 lowercase letters or digits, and the Dozzle and Beszel tokens must be distinct. Copy all of them from the deployed ntfy configuration.
- Beszel: `vault_beszel_superuser_email`, `vault_beszel_superuser_password`, `vault_beszel_app_user_email`, `vault_beszel_app_user_password`, `vault_beszel_agent_key`, `vault_beszel_universal_token`, `vault_beszel_hub_private_key`. Both emails need nonempty local and domain parts. The universal token must be a lowercase RFC 4122 UUID. The agent key and OpenSSH Ed25519 private key must be the matching deployed pair; the agent key contains exactly two whitespace-separated fields, the `ssh-ed25519` type and its base64 public key, with no comment.
- Paperless: `vault_paperless_admin_username`, `vault_paperless_admin_password`, `vault_paperless_admin_email`, `vault_paperless_db_name`, `vault_paperless_db_username`, `vault_paperless_db_password`, `vault_paperless_django_secret_key`, `vault_paperless_gmail_account`, `vault_paperless_gmail_app_password`, `vault_paperless_mail_account_name`, `vault_paperless_mail_rule_name`. Preserve the administrator, database, Django signing key, and mail automation as one deployed identity set. The email fields need nonempty local and domain parts; database identifiers follow the Immich rules. The Gmail credential must be an app password for the named account, handled according to [Google's app-password guidance](https://support.google.com/accounts/answer/185833), not the normal account password.
- tinyMediaManager: `vault_tinymediamanager_password`. Copy the deployed API password; changing it breaks existing clients.

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

umask 077
mkdir -p "$PLATFORM_VAULT_DIR"
chmod 700 "$PLATFORM_VAULT_DIR"
```

Refuse to overwrite either artifact. If either check stops, identify and back
up the existing file; do not bypass the refusal.

```sh
if [ -e "$PLATFORM_VAULT_PASSWORD_FILE" ]; then
  echo "Refusing to overwrite existing vault password file" >&2
  exit 1
fi
if [ -e "$PLATFORM_VAULT_FILE" ]; then
  echo "Refusing to overwrite existing encrypted vault" >&2
  exit 1
fi
```

Generate a strong, unique password in the password manager, then enter that
password as one line through an editor. Do not supply it on a command line.

```sh
${EDITOR:-vi} "$PLATFORM_VAULT_PASSWORD_FILE"
chmod 600 "$PLATFORM_VAULT_PASSWORD_FILE"
```

Create the external vault directly in encrypted form:

```sh
ansible-vault create \
  --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE" \
  "$PLATFORM_VAULT_FILE"
chmod 600 "$PLATFORM_VAULT_FILE"
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

### Validate without disclosure

Check only metadata and the encryption header:

```sh
test "$(stat -f '%Lp' "$PLATFORM_VAULT_PASSWORD_FILE")" = 600
test "$(stat -f '%Lp' "$PLATFORM_VAULT_FILE")" = 600
IFS= read -r vault_header < "$PLATFORM_VAULT_FILE"
case "$vault_header" in
  '$ANSIBLE_VAULT;'*) ;;
  *) echo "Vault is not encrypted" >&2; exit 1 ;;
esac
unset vault_header
```

Run the redacted contract validation from the worktree root:

```sh
ansible-playbook validate-vault.yml \
  --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE" \
  -e @"$PLATFORM_VAULT_FILE" \
  -e "platform_vault_file=$PLATFORM_VAULT_FILE"
```

This proves required fields and shapes without printing values. It cannot prove
that an email is the deployed identity, a password matches its application, a
hash matches its password, or a keypair and integration work. Use this for a
private manual review against each authoritative source:

```sh
ansible-vault edit \
  --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE" \
  "$PLATFORM_VAULT_FILE"
```

Never decrypt a vault onto disk.

### Identify, back up, and prove

A SHA-256 of ciphertext is safe to record as the identity of the encrypted
artifact; it is not a checksum of plaintext values:

```sh
shasum -a 256 "$PLATFORM_VAULT_FILE"
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

Before production use, run the complete disposable Mac proof:

```sh
tests/mac/run.sh \
  --lane fresh \
  --vault-file "$PLATFORM_VAULT_FILE" \
  --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE"
```

Only after validation, private review, and the complete proof pass, copy the
ciphertext into the repository location for NAS deployment:

```sh
install -m 600 "$PLATFORM_VAULT_FILE" inventory/group_vars/all/vault.yml
IFS= read -r vault_header < inventory/group_vars/all/vault.yml
case "$vault_header" in
  '$ANSIBLE_VAULT;'*) ;;
  *) echo "Repository vault is not encrypted" >&2; exit 1 ;;
esac
unset vault_header
git status --short inventory/group_vars/all/vault.yml
```

Repository policy may permit committing that encrypted artifact. Never commit
the vault password, plaintext or decrypted vaults, rendered environment files,
temporary private keys, application/database configuration containing secrets,
or secret-bearing logs. `generate-secrets.yml` remains forbidden for this
migration path.

## Brand-new platform

This exception is allowed only when there is no existing state, identity,
credential, database, agent key, or external integration to adopt. If any such
material exists—or its status is uncertain—stop and follow the migration
workflow. Never use this generator for migration or credential rotation.

After exporting the protected paths and creating only the password file as
described above, confirm that neither the external vault nor either repository
output exists. Then explicitly opt in:

```sh
ansible-playbook generate-secrets.yml -e generate_brand_new_platform=true
```

The generator writes `inventory/group_vars/all/vault-plain.yml` as mode 0600.
That output is plaintext. Do not inspect it in a terminal, attach it anywhere,
or leave it in the checkout. Immediately move and encrypt it with the prepared
password file:

```sh
if [ -e "$PLATFORM_VAULT_FILE" ]; then
  echo "Refusing to overwrite existing encrypted vault" >&2
  exit 1
fi
mv inventory/group_vars/all/vault-plain.yml "$PLATFORM_VAULT_FILE"
chmod 600 "$PLATFORM_VAULT_FILE"
ansible-vault encrypt \
  --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE" \
  "$PLATFORM_VAULT_FILE"
```

Use `ansible-vault edit` for the private manual review. Replace the generated
identity defaults with the intended administrator emails and usernames, verify
the Paperless Gmail account and its Google app password, and preserve the
generated internal relationships. Then rerun the exact redacted validation and
the header, permission, backup, and Mac proof checks above. This path creates a
new platform identity set and is forbidden for migration.
