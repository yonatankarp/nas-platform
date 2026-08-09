# Physical NAS walkthrough

This path targets production. Complete the
[disposable Mac proof](getting-started-mac.md), back up application data, and
confirm every required service is `implemented` or `accepted` in
[`services/manifest.yml`](../services/manifest.yml) before cutover. Today only
ntfy, Beszel, Dozzle, and Audiobookshelf are implemented; this is not yet a
complete replacement for the legacy NAS platform.

Commands are labelled **read-only**, **check mode**, or **changes production**.

## 1. Prepare the NAS and workstation

The NAS needs Docker, the Docker Compose plugin 2.18.0 or newer, Python 3, SSH
access, and enough space under the configured storage roots. From your
workstation, confirm ordinary SSH access first. These are read-only checks:

```sh
export PLATFORM_NAS_ADDRESS=nas.example.internal
export PLATFORM_NAS_USER=nasadmin
ssh "$PLATFORM_NAS_USER@$PLATFORM_NAS_ADDRESS"
```

Exit the SSH session after confirming the host identity. Do not disable SSH host
key checking. On the NAS, verify:

```sh
python3 --version
docker version
docker compose version
```

On the workstation, follow the shared installation in
[`getting-started.md`](getting-started.md). Keep the virtual environment active.
Review [`inventory/group_vars/nas_hosts/main.yml`](../inventory/group_vars/nas_hosts/main.yml)
and [`inventory/group_vars/all/main.yml`](../inventory/group_vars/all/main.yml)
against the real NAS paths, UID/GID, timezone, ports, and capabilities before
continuing.

## 2. Back up before migration

Back up all application data, databases, media metadata, current Compose/Portainer
definitions, and the current password-manager entries to encrypted storage away
from the NAS. Test a restore. Keep the legacy deployment definitions and a
record of currently running image versions. An encrypted Ansible vault is not
an application-data backup, and RAID is not a backup.

Do not stop or remove the legacy stacks yet. The final service-specific cutover
and rollback packet is a later migration deliverable.

## 3. Reuse the reviewed migration vault

The migration requirement is credential continuity: every login, database
password, hash, ntfy token, Beszel key, Gmail setting, and other deployed value
must remain exactly current. The preparation, validation, private-review, and
Mac-proof portions of the
[secrets and encrypted-vault guide](secrets.md) must be complete before
continuing.

Now resume the canonical workflow at
[Install reviewed vault for NAS](secrets.md#install-reviewed-vault-for-nas)
section exactly once. Its guarded mutation copies only the reviewed Mac
ciphertext and refuses to overwrite an existing repository vault. If the
repository vault already exists, stop and inspect it, then explicitly decide to
reuse it or follow a separate backed-up replacement procedure.

After that canonical step installs a new vault, or after you explicitly confirm
that the existing vault is the reviewed artifact to reuse, verify its header and
repository status without showing its contents:

```sh
head -n 1 inventory/group_vars/all/vault.yml
git status --short inventory/group_vars/all/vault.yml
```

The first line must start with `$ANSIBLE_VAULT;`. The encrypted vault may be
committed. Never commit its password, a plaintext or decrypted vault, rendered
`.env` files, plaintext credentials, or private keys.

## 4. Validate inventory and connectivity

These commands are read-only. Set public or callback coordinates separately
only if applications must advertise addresses different from the SSH address.

```sh
export PLATFORM_NAS_ADDRESS=nas.example.internal
export PLATFORM_NAS_USER=nasadmin
ansible-inventory -i inventory/remote.yml --graph
ansible -i inventory/remote.yml platform_hosts -m ansible.builtin.ping
```

Success shows one `nas` host and a `pong`. `UNREACHABLE` means fix SSH, address,
username, host keys, or NAS Python before running a playbook.

## 5. Review the predicted production changes

**Check mode: intended not to change production.** It still connects to the NAS
and evaluates the entire play. Review every predicted change and diff:

```sh
ansible-playbook -i inventory/remote.yml site.yml \
  --check --diff --ask-vault-pass
```

Stop on any unexpected path, deletion, credential rotation, service replacement,
or secret-looking output. Check mode cannot simulate every external system, so
it is a review gate rather than a backup or rollback mechanism.

## 6. Apply the platform

**Changes production.** Run only in an agreed maintenance window with a tested
backup and a service-specific rollback decision already written down:

```sh
ansible-playbook -i inventory/remote.yml site.yml --ask-vault-pass
```

Success requires `failed=0` and `unreachable=0`. Do not start manual repairs
after a failure. Preserve the first failing task and its message, check the
affected container without exposing secrets, and decide whether to fix forward
or execute the pre-agreed rollback.

## 7. Verify and prove idempotence

`verify.yml` performs application checks without deploying or reconciling:

```sh
ansible-playbook -i inventory/remote.yml verify.yml --ask-vault-pass
```

Then rerun the deployment playbook. This can change production if drift exists;
under normal conditions it should report `changed=0`:

```sh
ansible-playbook -i inventory/remote.yml site.yml --ask-vault-pass
```

Record the Git commit, encrypted vault checksum, recap, application checks, and
operator decision without recording secrets. Existing NAS credentials must work
unchanged. Verify ntfy authentication plus alerts from Beszel and Dozzle.

## Recovery and rollback boundary

Ansible converges configuration; it is not a database rollback tool. A failed
deployment does not authorize deleting volumes, regenerating credentials,
decrypting the vault into the repository, or broadly removing Docker data.

Before each service cutover, its migration packet must name the old stack,
new stack, data snapshot, acceptance checks, maximum outage, and exact rollback
trigger. Until that packet and the remaining service roles exist, keep the
legacy deployment recoverable and stop before production cutover. If a run
fails, capture the first failure, container state, and bounded logs; then use
the tested service-specific backup/rollback procedure or fix forward with a
reviewed Ansible change.
