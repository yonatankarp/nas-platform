# Physical NAS walkthrough

This path targets production. Complete the
[disposable Mac proof](getting-started-mac.md), back up application data, and
confirm every required service is `implemented` or `accepted` in
[`services/manifest.yml`](../services/manifest.yml) before cutover. All nine
current services are implemented: Audiobookshelf, Beszel, Dozzle, Immich,
Jellyfin, Komga, ntfy, Paperless-ngx, and tinyMediaManager. Implementation and
the Mac proof do not replace the service-specific production cutover packets.

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

## 2. Back up before deploying

Back up all application data, databases, media metadata, the current Compose
definitions, and the current password-manager entries to encrypted storage away
from the NAS. Test a restore. Keep a record of currently running image
versions. An encrypted Ansible vault is not
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

These commands are read-only. `PLATFORM_PUBLIC_HOST` is required and separate
from the SSH address: it is the address clients use to reach published services,
and ntfy hashes it into the topic it registers for mobile push, so it must be
the address your devices actually use. Leaving it unset now fails preflight
instead of silently publishing to a topic nothing subscribes to.
`PLATFORM_CALLBACK_HOST` is only needed when containers must reach the host at
a different address than the SSH one.

```sh
export PLATFORM_NAS_ADDRESS=nas.example.internal
export PLATFORM_NAS_USER=nasadmin
export PLATFORM_PUBLIC_HOST=nas.example.ts.net
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
unchanged for all nine services. Repeat the service-specific credential checks
from the [Mac manual review](getting-started-mac.md#4-perform-the-manual-review)
against the production deployment without exercising external integrations; for
ntfy, use only an agreed disposable topic when verifying alerts from Beszel and
Dozzle.

## Recover after loss of `/volume1`

Use this procedure when the service-state volume was recreated or wiped but the
NAS-managed files on `/volume2` survived. This is not a complete disaster
recovery procedure: `/volume1` contains application databases, configuration,
indexes, profiles, and other critical state. A successful Ansible run recreates
the declared platform, but it does not restore an application database.

### Establish the loss boundary

First prove that both real volumes are mounted. A directory named `/volume1` or
`/volume2` can exist on the system filesystem even when the corresponding array
is not mounted, so directory existence alone is insufficient. These checks are
read-only:

```sh
df -h /volume1 /volume2
grep -E '[[:space:]]/volume(1|2)[[:space:]]' /proc/mounts
sudo docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
sudo find /volume2 -mindepth 1 -maxdepth 1 -type d -print
```

On the ASUSTOR production layout, `/volume1` is the NVMe service-state volume
and `/volume2` is the NAS-managed media volume. Stop if either mount is absent.
Do not create service directories until the mount boundary is proven. Record
which `/volume2` trees survived before making changes; important examples are
`Media`, `Books`, `Immich`, `Immich-backups`, and `Documents`.

### Rebuild the local controller prerequisites

The controller can run directly on the NAS from a user-owned, non-service
location. Keeping the checkout outside `/volume1/Docker` separates deployment
source from rendered service state:

```sh
mkdir -p ~/.local/share/nas-platform
git clone git@github.com:yonatankarp/nas-platform.git \
  ~/.local/share/nas-platform/controller
cd ~/.local/share/nas-platform/controller
git switch main
git pull --ff-only origin main

python3 -m venv .venv
. .venv/bin/activate
python3 -m pip install --upgrade pip
python3 -m pip install 'ansible-core==2.21.2' 'ansible-lint==26.6.0'
ansible-galaxy collection install -r requirements.yml
```

On this ASUSTOR, Python multiprocessing requires the real shared-memory
directory to be mode `1777`. The `/dev/shm` symlink can itself report `777`
while its `/run/shm` target is only `755`, causing Ansible to fail before it
runs a task. Diagnose the target and repair the current boot only if the
semaphore probe fails:

```sh
ls -ldL /dev/shm
stat -L -c '%a %U %G %n' /dev/shm
python3 -c 'from multiprocessing import Semaphore; Semaphore(1); print("multiprocessing works")'

# Changes the current NAS boot when the target is not 1777.
sudo chmod 1777 /run/shm
```

Confirm the permission again after every NAS reboot until an ADM-supported boot
configuration is known to preserve it. Do not weaken permissions on a broader
directory such as `/run`.

Docker access is independent of NAS administrator membership. The Unix socket
must use the Docker group, and the controller user must belong to that group:

```sh
getent group docker
id
ls -ln /var/run/docker.sock
docker ps
```

After adding group membership or restarting Docker, end the SSH session and
start a new one before retesting; the ASUSTOR shell may not provide `newgrp`.
Do not make the Docker socket world-writable. Finally recreate only the mounted
Docker state root with the declared production ownership:

```sh
sudo mkdir -p /volume1/Docker
sudo chown 1000:100 /volume1/Docker
sudo chmod 0755 /volume1/Docker
```

### Validate the recovered control plane

The password requested by `--ask-vault-pass` is the Ansible Vault password,
not the NAS login password. It decrypts the repository's symmetric encrypted
vault in memory. Validate the vault and local connection before mutation:

```sh
export PLATFORM_NAS_ADDRESS=nas.example.internal
export PLATFORM_PUBLIC_HOST=nas.example.ts.net

ansible-playbook -i inventory/local.yml validate-vault.yml --ask-vault-pass
ansible -i inventory/local.yml platform_hosts \
  -m ansible.builtin.ping --ask-vault-pass
```

Vault validation must end with `failed=0`, and the ping must return `pong`.
Keep the vault password outside the repository and never print decrypted values
while diagnosing a schema failure.

### Converge in recovery stages

When both application databases on `/volume1` are absent, converge the rest of
the platform first and keep Immich and Paperless out of that run:

```sh
ansible-playbook -i inventory/local.yml site.yml \
  --skip-tags immich,paperless \
  --ask-vault-pass
```

Success requires `failed=0` and `unreachable=0`. A nonzero `changed` count is
expected while rebuilding an empty service-state volume. Rerun the same command
after a corrected failure; Ansible is designed to continue converging existing
safe state.

Restore Immich and Paperless separately because their surviving files and lost
databases have different recovery boundaries:

- Immich publishes `http://<nas-address>:2283`. Originals under
  `/volume2/Immich` and SQL dumps under `/volume2/Immich-backups/database` can
  survive `/volume1` loss, but the PostgreSQL data directory does not. Validate
  and restore a compatible dump before normal use. Running with `--tags immich`
  provisions the stack; it does not import a dump or reconnect originals to a
  newly initialized database.
- Paperless publishes `http://<nas-address>:8000`. The archive and inbox under
  `/volume2/Documents` can survive while PostgreSQL and Paperless's data/index
  directory do not. A fresh deployment will not reconstruct document metadata,
  tags, correspondents, or search state merely because archive files exist.
  Use a tested Paperless export or coordinated database recovery when available;
  otherwise treat re-import from surviving originals as a separate recovery
  operation and preserve the archive before attempting it.

After its database recovery decision is complete, converge one service at a
time so failures remain attributable:

```sh
ansible-playbook -i inventory/local.yml site.yml \
  --tags immich \
  --ask-vault-pass

ansible-playbook -i inventory/local.yml site.yml \
  --tags paperless \
  --ask-vault-pass
```

Do not interpret a clean play recap as proof that old application records were
restored. Verify representative photos, users, albums, documents, metadata, and
search results in each application. tinyMediaManager's web UI is on port `4000`
and its API is on port `7878`; these are useful independent media-service checks
during the same recovery window.

## Recovery and rollback boundary

Ansible converges configuration; it is not a database rollback tool. A failed
deployment does not authorize deleting volumes, regenerating credentials,
decrypting the vault into the repository, or broadly removing Docker data.
When only the service-state volume is lost, follow the bounded
[`/volume1` recovery procedure](#recover-after-loss-of-volume1) above instead
of treating surviving `/volume2` data as a fresh installation.

Before each service cutover, its migration packet must name the old stack,
new stack, data snapshot, acceptance checks, maximum outage, and exact rollback
trigger. Until that packet exists for a service, keep its legacy deployment
recoverable and stop before its production cutover. If a run
fails, capture the first failure, container state, and bounded logs; then use
the tested service-specific backup/rollback procedure or fix forward with a
reviewed Ansible change.
