# NAS platform

Ansible-owned infrastructure for an ASUSTOR AS6704T NAS. Ansible is the only
control plane: it prepares storage, renders configuration from an encrypted vault,
deploys the Compose stacks, provisions first-run identities, wires services to one
another, and verifies the result.

This repository recreates service *configuration*. It is not a backup of photos,
media, databases or application state. Keep those in a separate encrypted,
off-site backup. RAID is not a backup.

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

```sh
ansible-galaxy collection install -r requirements.yml

# Author credentials once, review the identity fields, then encrypt.
ansible-playbook generate-secrets.yml
mv inventory/group_vars/all/vault-plain.yml inventory/group_vars/all/vault.yml
ansible-vault encrypt inventory/group_vars/all/vault.yml

# Review, then apply.
ansible-playbook -i inventory/remote.yml site.yml --check --diff --ask-vault-pass
ansible-playbook -i inventory/remote.yml site.yml --ask-vault-pass
```

## Secrets and the vault

`generate-secrets.yml` writes **plaintext**. Encryption is a separate step you
run, and you choose the password: nothing encrypts it for you, and no copy of
that password exists anywhere else.

```sh
ansible-vault encrypt inventory/group_vars/all/vault.yml   # set the password
ansible-vault view    inventory/group_vars/all/vault.yml   # read, nothing written to disk
ansible-vault edit    inventory/group_vars/all/vault.yml   # edit in place, stays encrypted
ansible-vault decrypt inventory/group_vars/all/vault.yml   # back to plaintext on disk
ansible-vault rekey   inventory/group_vars/all/vault.yml   # change the password
```

An encrypted file starts with `$ANSIBLE_VAULT;1.1;AES256` followed by hex
ciphertext. Plays read it directly given the password, so it never has to be
decrypted on disk to run anything.

**If you lose the password the vault is unrecoverable.** There is no backdoor.
Recovery means regenerating every credential and running again, which this design
survives because everything is authored in vault rather than read back from
running services, but you would be reprovisioning ntfy, Beszel and every
administrator account. Keep the password in a password manager.

### Where plaintext exists

Only in two places, both mode `0600` on the NAS, both gitignored and neither ever
committed:

- `services/<name>/.env`, rendered by Ansible from vault
- `${NAS_DOCKER_ROOT}/beszel/hub/id_ed25519`, the hub keypair written from vault

Everything else is ciphertext. The encrypted vault **is** committed, so its
safety rests entirely on the strength of that one password.

### Unattended runs

`--vault-password-file` accepts an **executable**, not only a file, so the
password can be fetched from a password manager at run time with no plaintext
copy on disk:

```sh
ansible-playbook -i inventory/remote.yml site.yml --vault-password-file ~/.nas-vault-pass
```

where that file is a script that prints the password, for example via the
1Password CLI. Keep it outside this repository. `.gitignore` covers
`.vault-password` and `vault-password*` so an in-repo copy cannot be committed by
accident.

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

Jellyfin and Immich cannot be exercised anywhere but the NAS, because both map
`/dev/dri` and Compose merges `devices` by appending, so no override can remove
them.

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
