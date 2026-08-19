# NAS platform

Ansible-owned infrastructure for an ASUSTOR AS6704T NAS. Ansible is the only
control plane: it prepares storage, renders configuration from an encrypted vault,
deploys the Compose stacks, provisions first-run identities, wires services to one
another, and verifies the result.

This repository recreates service *configuration*. It is not a backup of photos,
media, databases or application state. Keep those in a separate encrypted,
off-site backup. RAID is not a backup.

## New to Ansible?

- [Beginner starting point](docs/getting-started.md)
- [Disposable Mac walkthrough](docs/getting-started-mac.md)
- [Physical NAS walkthrough](docs/getting-started-nas.md)
- [Ansible concepts used here](docs/ansible-basics.md)
- [Adding a service](docs/adding-a-service.md)

All nine service stacks in [`services/manifest.yml`](services/manifest.yml) are
implemented. Prove the complete platform on the Mac before preparing a
production NAS cutover.

## Design

**Nothing is manual after the first run.** Two residues are irreducible and are
stated rather than engineered around: someone must author the vault once and hold
its password, because that is the root of trust; and credentials issued by a third
party, such as a Gmail app password, must be obtained by a human.

**Vault is always first.** Every credential is authored in vault and flows one
direction. Nothing is read back from a running service, so a run converges in a
single pass. Where a service would normally hand you a generated value to
copy-paste, we supply ours instead: ntfy accepts declarative users, ACL entries
and tokens, and Beszel uses a hub keypair placed on disk before first start.

**Ansible converges on every run.** Configuration changed in a web UI is reverted
by the next run, which is what makes the repository describe reality. Review with
`--check --diff` before applying.

**Definitions are portable.** Compose files reference `${NAS_DOCKER_ROOT:?}` and
`${NAS_MEDIA_ROOT:?}` rather than absolute paths, so the same definitions run
unmodified against the NAS, a workstation sandbox and CI. Required-variable
syntax means an unset value fails loudly instead of silently creating a relative
bind mount.

**Run location does not matter.** One inventory host with the connection switched:
`inventory/local.yml` on the NAS, `inventory/remote.yml` from a workstation. Every
task, including HTTP calls, runs on that host, so loopback addresses are correct
in both modes.

## Layout

```
site.yml                inventory/            services/<name>/compose.yml
verify.yml              roles/<name>/         tests/
generate-secrets.yml    requirements.yml      docs/
```

## First run

Prerequisites on the NAS: Docker with the Compose plugin 2.18.0 or newer, and
python3, which Ansible needs in both run modes.

Complete the [complete secrets and encrypted-vault guide](docs/secrets.md)
before deploying. Migrations must reuse every current credential value; use the
generator only for a truly brand-new platform with no identities or state to
preserve.

```sh
ansible-galaxy collection install -r requirements.yml

# Review, then apply.
ansible-playbook -i inventory/remote.yml site.yml --check --diff --ask-vault-pass
ansible-playbook -i inventory/remote.yml site.yml --ask-vault-pass
```

## Secrets and the vault

Follow the [complete secrets and encrypted-vault guide](docs/secrets.md) for
migration, validation, review, backup, and the separate brand-new-platform path.

An encrypted file starts with `$ANSIBLE_VAULT;1.1;AES256` followed by hex
ciphertext. Plays read it directly given the password, so it never has to be
decrypted on disk to run anything.

**If you lose the password the vault is unrecoverable.** There is no backdoor.
Recovery means regenerating every credential and running again, which this design
survives because everything is authored in vault rather than read back from
running services, but you would be reprovisioning ntfy, Beszel and every
administrator account. Keep the password in a password manager.

At runtime, plaintext exists in protected service `.env` files, Dozzle's users
file, Beszel's private key, and application or database configuration and data.
Treat those locations and their backups as secret-bearing. The repository vault
remains ciphertext and may be committed, so its safety rests on the strength of
the password.

### Unattended runs

`--vault-password-file` accepts an **executable**, not only a file, so the
password can be fetched from a password manager at run time with no plaintext
copy on disk:

```sh
PLATFORM_NAS_ADDRESS=nas.example.internal \
PLATFORM_NAS_USER=nasadmin \
PLATFORM_PUBLIC_HOST=nas.example.ts.net \
ansible-playbook -i inventory/remote.yml site.yml \
  --vault-password-file ~/.nas-vault-pass
```

where that file is a script that prints the password, for example via the
password-manager CLI. Keep the executable outside this repository and make it
print only the vault password.

Three coordinates are separate inputs because they answer to different
audiences. `PLATFORM_NAS_ADDRESS` is how this run reaches the NAS, over SSH or
locally. `PLATFORM_PUBLIC_HOST` is the address clients use to reach published
services; it is required and has no fallback, because ntfy hashes it into the
topic it registers for mobile push, so a value inherited from the connection
address routes notifications to a topic no device subscribes to and nothing
reports an error. `PLATFORM_CALLBACK_HOST` is how containers reach
host-published callbacks and does default to the connection address, which is
the right answer for that audience. Connection coordinates stay in inventory
inputs and are not portable vault credentials.

## Testing

```sh
ruby tests/policy_test.rb      # property checks, no service-specific literals
ansible-lint --strict          # production profile
tests/integration.sh site.yml  # converge, re-converge, then --check --diff
```

The integration harness runs Ansible in a Linux container against a disposable
sandbox, so the plays meet a real `/proc/mounts`, real numeric uid and gid, and a
real Docker socket. It asserts three properties: the run converges, a second run
changes nothing, and a dry run works. Two of the worst bugs found so far, a fact
that exists only on Linux and `command` being skipped under `--check`, both passed
syntax checking and were caught only by running.

The current Mac proof covers ntfy, Beszel, Dozzle, Audiobookshelf, Komga,
Jellyfin, tinyMediaManager, Immich, and Paperless-ngx. NAS-only GPU,
host-networking, native-mount and production-scale behavior remain outside the
Mac proof.

### Disposable Mac platform proof

The Mac lifecycle harness creates a unique Docker Desktop sandbox, reuses an
encrypted portable vault without decrypting it on disk, and records sanitized
JSON and Markdown evidence outside the service-data tree. Run a fresh proof with:

```sh
tests/mac/run.sh \
  --lane fresh \
  --vault-file /absolute/path/to/vault.yml \
  --vault-password-file /absolute/path/to/password-command
```

For this harness, executable password providers are POSIX shell text with the
exact `#!/bin/sh` shebang, no shebang options, and no NUL bytes. The harness
streams inspected provider bytes through an anonymous pipe and executes them
once in the provider's original directory context, so sibling-helper wrappers
remain supported without creating a plaintext script file. Other executable
formats fail closed. Regular password files remain supported unchanged.

The ordered phases are `preflight`, `deploy`, `seed`, `verify`, `idempotence`,
`drift`, `reconcile`, `recreate`, `persistence`, `report`, and `cleanup`. Select
one with `--phase NAME`. Resume a preserved run with `--sandbox ABSOLUTE_PATH`;
completed phases remain recorded and are not repeated. A later phase is refused
until its predecessors have passed, except that `report` and `cleanup` remain
available after a failure.

Failed sandboxes are preserved by default, and `--keep-on-failure` is accepted
for automation that wants to state that policy explicitly. A failed run prints
exactly one validated cleanup command. Cleanup removes only the marked sandbox;
the sibling `.reports` directory remains as sanitized evidence. Optional report
copies under `mac-proof-reports/` are ignored by Git. Complete
`tests/mac/manual-review.md` against the generated manifest and report.

Failure evidence includes label-scoped container state and bounded log summaries.
Log message bodies and unparseable lines are always replaced with `[REDACTED]`;
only validated timestamps, counts, capture status, and container identity remain.
Raw log content is never written to a temporary file, report, or console.

## Manual escape hatch

Ansible owns deployment, but a stack can be brought up by hand if needed, using
the environment file Ansible rendered:

```sh
docker compose --env-file services/ntfy/.env -f services/ntfy/compose.yml up -d
```

## Security boundary

Safe to commit: Compose definitions, pinned image digests, port and volume
mappings, roles, the **encrypted** vault, and documentation.

Never commit: the vault password, any decrypted vault copy, rendered `.env` files,
plaintext credentials, or application data.
