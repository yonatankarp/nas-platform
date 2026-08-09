# Canonical Secrets Guide Design

**Date:** 2026-08-09

## Goal

Give operators one complete, safe procedure for collecting every required
credential, authoring the portable Ansible vault directly as ciphertext,
validating it without disclosure, and carrying the reviewed artifact from the
Mac proof to the NAS deployment.

## Documentation structure

Create `docs/secrets.md` as the canonical source. Keep the README and the Mac
and NAS getting-started guides concise: each retains its context-specific safety
boundary and links to the canonical guide instead of duplicating the full
procedure.

The canonical guide will present the migration workflow first because this
repository adopts existing application and database state. A separate final
section will document `generate-secrets.yml` only for a genuinely brand-new
platform with no identities, integrations, or data to preserve.

## Required content

The guide will:

- enumerate all 40 keys from `inventory/group_vars/all/vault.yml.example`,
  grouped by service;
- identify whether each value comes from the password manager, Portainer,
  existing service configuration, database configuration, or key material;
- document format constraints for bcrypt hashes, ntfy tokens, UUIDs, email
  addresses, database identifiers, and the Beszel Ed25519 keypair;
- explain Paperless Gmail app-password handling without embedding credentials;
- create the vault and its password input outside the checkout with restrictive
  permissions;
- use `ansible-vault create` so operators never deliberately create a plaintext
  migration-vault artifact;
- cover YAML quoting and private-key block indentation;
- verify the encrypted header, permissions, vault contract, and ciphertext
  checksum without printing values;
- explain encrypted backup and password recovery boundaries;
- show the Mac proof command and the later ciphertext-only installation into the
  repository inventory;
- clearly prohibit secrets in chat, shell arguments, logs, tickets, PRs, and
  plaintext Git artifacts.

## Cross-document changes

- `README.md`: link the secrets section to `docs/secrets.md` and preserve a
  short warning that generation is for brand-new platforms only.
- `docs/getting-started-mac.md`: replace the detailed password/vault authoring
  steps with a Mac-specific setup summary and link, while retaining the external
  vault paths used by subsequent commands.
- `docs/getting-started-nas.md`: replace the duplicated migration-vault procedure
  with a link and retain the requirement to reuse the Mac-reviewed ciphertext.

## Safety and error handling

Commands must refuse or tell the operator to stop when vault material already
exists. The guide must never suggest passing a credential through `-e`, placing
one in shell history, or decrypting a vault onto disk. Validation must use
`validate-vault.yml` with `no_log` protections. The guide must state that shape
validation cannot distinguish a realistic placeholder from a real credential,
so a private manual review remains mandatory.

## Verification

After editing:

1. Check all local Markdown links and referenced paths.
2. Confirm the documented vault keys exactly match
   `inventory/group_vars/all/vault.yml.example`.
3. Run the repository policy tests and Markdown/shell-relevant checks available
   in the project.
4. Inspect the final diff for accidental credential-like values and run
   `git diff --check`.

No actual vault, vault password, application credential, token, hash, or private
key will be created or committed as part of this documentation change.
