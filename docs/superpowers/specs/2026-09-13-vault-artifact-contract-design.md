# Make the vault artifact contract file-count-agnostic

Status: design, 2026-09-13. This is the first of two changes. It ships with the
vault still a single file and changes no credential. The per-service split of
`inventory/group_vars/all/vault.yml` is the second, and depends on this one.

## Why this order, which is the reverse of the obvious one

Splitting the vault first does not work, and the reason is worth stating because
it is not obvious until you look at the harness.

`tests/integration_controller.sh:160` does
`install -m 0600 "$vault_file" /repo/inventory/group_vars/all/vault.yml`, and
`tests/generate-ephemeral-vault.sh` emits exactly one encrypted file. The moment
credentials live in `vault_immich.yml` and friends, a suite installs an ephemeral
`vault.yml` encrypted under the harness password while the repository's committed
per-service vaults sit beside it encrypted under the operator's. Ansible loads
every file in `group_vars/all/`, tries to decrypt all of them with the one
password it was given, and the run dies. The split *is* the contract change.

So the contract is made to accept N first, while N is 1 and nothing can be lost,
and the split lands second against a contract that already handles it.

## What `platform_vault_file` actually is

It is not how credentials reach Ansible. Credentials reach Ansible because
`group_vars/all/` is loaded and decrypted by `--vault-password-file`;
`roles/vault_contract` reads them **by variable name**, and `validate-vault.yml`
merely includes that role with no `-e @` and no `vars_files`. Verified
2026-09-13. That is what makes this change small: the credential path is
untouched.

`platform_vault_file` exists for **report identity** alone. `vault_contract`
(`tasks/main.yml:198-255`) stats the path, reads its first 15 bytes, requires
them to match `$ANSIBLE_VAULT;`, computes a SHA-256, and records
`platform_encrypted_vault_sha256`. Nothing else in the repository reads that
fact. Its whole job is to say *which* encrypted artifact a run was made against.

## The change

`platform_vault_file` accepts a **directory** as well as a file, and the default
becomes `inventory/group_vars/all/`.

- Selection: every regular file directly in the directory whose content
  **starts** with `$ANSIBLE_VAULT;`, skipping dotfiles and `~` backups. No
  extension filter: `group_vars` loads `.yml`, `.yaml`, `.json` and extensionless
  files and skips dotfiles and backups, so this is the set Ansible actually
  decrypted, no more and no less. The header rule excludes `vault.yml.example`,
  which is plaintext and sits in the same directory, without naming it; the
  file-start anchor excludes a plaintext file quoting the header on a later line.
- Identity: for each selected file, sorted by basename, compute its SHA-256;
  then the run identifier is the SHA-256 over NUL-delimited
  `<basename>\0<digest>\0` records. NUL rather than `:` and newline because a
  basename may contain either, and the join would then be ambiguous. One
  64-character value, as before, so the recorded fact keeps its shape and its
  consumers keep working.
- A path that is a regular file keeps working exactly as today. That is not
  kindness to callers; the mac lane and the integration harness pass
  `-e platform_vault_file="$vault_file"` pointing at one file, and this change
  must not require them to move in the same commit.

The recorded digest **changes value** for the same vault, because a digest over
one named file is not the file's own digest. That is acceptable precisely
because nothing compares it across runs today; it is an identifier, not a
baseline. Stated here so a future reader does not mistake the change for a
corrupted artifact.

## What this must not become

Not a second way for credentials to reach Ansible. The directory is read for
`stat` and for 15 bytes of header, never decrypted and never loaded as vars.
`no_log: true` stays on every task that touches it.

Not a rename. `platform_vault_file` keeps its name. Renaming it would reach
`site.yml`, `verify.yml`, `install-production-auto-deploy.yml`,
`tests/integration_controller_lib.sh`, `tests/generate-ephemeral-vault.sh`,
`tests/mac/run.sh`, `tests/production_auto_deploy_test.py`,
`tests/policy_integration_test.rb` and `tests/policy_platform_test.rb` for no
gain.

## Guards this needs

The lesson the storage split paid for applies unchanged: a rule that selects its
own subjects is silent when it selects none.

- **A floor.** An empty directory, or a directory holding no encrypted file,
  must fail rather than produce the digest of an empty list. `vault_contract`
  asserts at least one selected artifact, and says how many it found.
- **Every selected file encrypted.** The existing header assertion becomes a
  per-file one. A plaintext file that somehow matched selection cannot slip in,
  because selection *is* the header test; the assertion covers the case where a
  file is selected by name-based fallback in some future edit.
- **Determinism.** The same directory must produce the same digest across runs
  and across machines, so the sort is by basename and stated, not incidental.

## Not in this change

The split itself. `.gitignore`'s literal `vault-plain.yml`, `generate-secrets.yml`
emitting N files, `integration_controller.sh`'s single-file `install`,
`generate-ephemeral-vault.sh`'s single-file emission, and `docs/secrets.md` with
its pinned assertions in `tests/secrets_docs_test.rb` all stay as they are. They
are correct for a one-file vault and they are PR 2's subject.

## Verification

- `roles/vault_contract` unit coverage through `tests/policy_vault_test.rb`,
  which already pins the task names this touches
  (`Compute the encrypted vault artifact SHA-256`).
- A planted defect per guard: an empty directory, a directory whose only file is
  plaintext, and two files in a different on-disk order producing the same digest.
- `tests/validate-policy.sh` in full, and the integration suites, which are the
  only thing that runs `vault_contract` against a real ephemeral vault.
