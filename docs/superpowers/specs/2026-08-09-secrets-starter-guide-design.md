# Secrets Starter Guide Expansion Design

## Goal

Make `docs/secrets.md` a complete operator guide for someone starting with no
vault artifacts, while retaining a safe migration path for an existing
deployment and documenting how to add a new secret later.

The primary fresh-platform path will use the repository's existing
`generate-secrets.yml` playbook. Individual commands will remain available as a
reference for understanding generated values and for adding a new secret type.

## Scope

The guide will document:

- creation and protection of the Ansible Vault password;
- the project virtual environment and pinned Ansible installation;
- generation of the complete current vault contract for a brand-new platform;
- the purpose and safe generation of passwords, bcrypt hashes, ntfy tokens,
  UUIDs, OpenSSH Ed25519 keypairs, and Django signing keys;
- the service-specific meaning of ntfy, Dozzle, Beszel, and Paperless values;
- YAML quoting rules for secret-bearing scalars and multiline private keys;
- encryption, redacted validation, backup, and safe editing;
- workstation-to-NAS and NAS-local playbook invocation; and
- the repository changes required when introducing a new vault variable.

The guide will not document future service functionality such as provisioning
an Immich family account or changing Beszel authentication mechanisms after
cutover. It will not provide credential-rotation instructions.

## Guide Structure

### 1. Choose the correct starting condition

The opening will distinguish two mutually exclusive cases:

1. A brand-new platform with no application state or deployed identities may
   generate a new credential set.
2. An existing platform with users, databases, agents, or integrations must
   recover the deployed values and must not run the generator.

The fresh-platform walkthrough will be the main linear path. Migration rules
will remain explicit and will point to the service inventory of authoritative
sources.

### 2. Prepare the project and protected files

The guide will use the repository `.venv`, not `pipx`, for operator commands.
It will show how to install the pinned Ansible versions when `.venv` does not
exist and how to activate the environment in later shells.

The Vault password will be a strong, unique random password rather than an SSH
or application key. The recommended generation command will write directly to
`$HOME/.config/nas-platform/vault-password` under a `umask 077`, avoiding
terminal output and shell-history exposure. Guards will prevent accidental
overwrite. Directory and file modes will be `0700` and `0600`, respectively.
The password must also be stored in a password manager before it protects the
only vault copy.

### 3. Generate a complete fresh vault

The primary path will invoke `generate-secrets.yml` with its explicit
brand-new-platform gate. It will describe the plaintext output as temporary
secret material, immediately move it to the protected external location,
encrypt it with `ansible-vault encrypt`, and validate it without disclosure.

The guide will explain what the generator creates and why:

- independent random application and database passwords;
- matching clear-password and bcrypt-hash pairs for ntfy and Dozzle;
- separate ntfy integration tokens;
- a permanent Beszel universal token;
- an OpenSSH Ed25519 Beszel hub keypair, with the private half installed at
  `/beszel_data/id_ed25519` and the public half passed to the agent;
- a random Paperless Django signing key; and
- initial identities and integration labels that require operator review.

The operator will review the encrypted vault through `ansible-vault edit` and
replace generated identity defaults with intended usernames, email addresses,
and external-integration values before deployment.

### 4. Individual value recipes

A reference section will give non-disclosing commands and decision rules for
individual secret types. It will resolve the questions discovered during setup:

- ntfy requires bcrypt hashes because declarative provisioning consumes hashes;
  the clear administrator password remains necessary for login and verification;
- Dozzle's users file also consumes a bcrypt hash, and its clear password and
  hash must match;
- the pinned ntfy image is the canonical bcrypt generator used by this
  repository for both services;
- ntfy tokens come from ntfy's own token generator and must be distinct;
- Beszel uses a superuser and an application user, a permanent universal token,
  the agent's public key, and the hub's matching private key;
- the current Ansible contract has no separate Beszel agent API-secret field;
- an existing Beszel private key is recovered from the host path mounted at
  `/beszel_data`, discoverable with `docker inspect`, without printing it;
- `vault_paperless_django_secret_key` is Paperless/Django signing material,
  generated only for a fresh service and recovered from `PAPERLESS_SECRET_KEY`
  during migration; and
- Paperless mail account and rule names are stable configuration identifiers,
  while the Gmail app password is the credential.

The recipes will make generated output land in protected files or an encrypted
editor wherever possible. They will warn when a command necessarily displays a
single generated value that must be transferred immediately.

### 5. YAML and encryption rules

All secret-bearing YAML scalars will be single-quoted by default. Apostrophes
will be doubled inside single-quoted scalars. Bcrypt dollar signs will remain
literal. OpenSSH private keys will use an indented YAML block scalar.

The guide will show in-place encryption of a prepared plaintext vault,
encryption-header and permission checks, redacted `validate-vault.yml`
execution, and future changes through `ansible-vault edit`. It will continue to
forbid decrypted-on-disk copies.

### 6. Use the vault from either controller

For workstation-controlled deployment, the password remains on the workstation
and `inventory/remote.yml` is used. The NAS does not receive the Vault password
as a file.

For a playbook running directly on the NAS, `inventory/local.yml` is used. The
recommended interactive path is `--ask-vault-pass`. Unattended NAS-local runs
may use a mode-`0600` password file or an executable password-manager provider
outside the repository, with the explicit trade-off that the NAS account and
root can then decrypt the vault.

### 7. Add a new secret later

Adding a vault value is a schema change, not merely editing ciphertext. The
guide will require operators to update all applicable locations:

- `inventory/group_vars/all/vault.yml.example`;
- `roles/vault_contract/meta/argument_specs.yml` and shape checks;
- the consuming role's argument specification, templates, and tasks;
- `generate-secrets.yml` and `templates/vault-plain.yml.j2` when fresh-platform
  generation should support the value;
- ephemeral test-vault generation and relevant contracts; and
- the canonical inventory in `docs/secrets.md`.

After the code contract exists, the operator will use `ansible-vault edit` to
append the value, run the redacted validator and policy suite, and commit only
the encrypted artifact and reviewed code/documentation changes. Existing
deployments must source the value from their deployed state; a new integration
may generate it according to the individual recipe.

## Safety and Failure Handling

Every mutating command will guard against overwriting an existing password,
plaintext vault, encrypted vault, or private key. A failed prerequisite or
ambiguous migration source is a stop condition. Commands will not accept secret
values through `-e`, command arguments, or shell variables that are likely to
leak through history or process listings.

The guide will distinguish safe metadata—file mode, Vault header, ciphertext
checksum, and redacted validation status—from secret-bearing output. It will
also state that encryption does not remove plaintext rendered into runtime
service configuration.

## Testing

The existing documentation contract will be extended before the guide changes.
It will assert the new starter, individual-recipe, append-secret, and dual
controller sections and their critical safety language. The test will avoid
coupling to incidental prose while continuing to require exact agreement
between the documented vault inventory and `vault.yml.example`.

Implementation verification will run:

```sh
ruby tests/secrets_docs_test.rb
tests/validate-policy.sh
find tests -type f -name '*.sh' -exec sh -n {} +
```

No test or diagnostic command may print decrypted vault values.
