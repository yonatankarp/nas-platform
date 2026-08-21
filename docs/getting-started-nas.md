# Physical NAS walkthrough

This path targets a fresh production installation. Complete the
[disposable Mac proof](getting-started-mac.md), protect any media already on the
NAS, and confirm every required service is `implemented` or `accepted` in
[`services/manifest.yml`](../services/manifest.yml) before installation. All nine
current services are implemented: Audiobookshelf, Beszel, Dozzle, Immich,
Jellyfin, Komga, ntfy, Paperless-ngx, and tinyMediaManager.

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

## 2. Protect existing storage before deploying

Even for a fresh install, back up any media or documents already present on the
NAS to encrypted storage away from it and test a restore. An encrypted Ansible
vault is not an application-data backup, and RAID is not a backup.

## 3. Prepare the reviewed deployment vault

Complete the brand-new-platform preparation, private review, validation, and
Mac-proof portions of the
[secrets and encrypted-vault guide](secrets.md) before continuing. Then follow
[Install reviewed vault for NAS](secrets.md#install-reviewed-vault-for-nas)
exactly once. Its guarded mutation copies only reviewed ciphertext and refuses
to overwrite an existing repository vault. If a vault already exists, stop and
inspect it instead of regenerating or overwriting it.

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

The platform provisions two ntfy topics and routes by severity, not by source.
`nas-critical` carries anything that should get you out of your chair: out of
memory, an unexpected container exit, an unhealthy container, a Beszel threshold
breach, and a failed deployment. `nas-containers` carries the record of what
happened: container recoveries and successful deployments. Each publisher may
write only to the topics it needs, so a leaked Beszel token cannot reach
`nas-containers` at all.

## Automatic deployment from the NAS

Automatic deployment is a second step after the first manual deployment and
verification above. It uses a dedicated non-root deployment account on the NAS;
do not install it as `root` or reuse a general interactive administrator. The
account's real home must be owned by that account, and the
account needs Docker access. The NAS must provide trusted, root-owned
`git`, `curl` and `docker` on the operator's PATH, and Python 3.12 or newer
with pip. The installer records where each tool actually lives, because NAS
firmwares place them under `/usr/local`, `/usr/builtin` or `/opt` rather than
`/usr/bin`, and the poller runs from a scheduler without the operator's PATH. The
installer fails closed when any of these prerequisites is absent or unsafe, and
it checks them before creating anything.

Firmware-specific findings from a real rollout, including hosts where cron,
tool locations and locales all differ from the assumptions above, are recorded in
[Automatic deployment on ASUSTOR ADM](asustor-adm-rollout.md).

The poller prefers working effective-user `crontab` support, but that is not
universal: some firmwares ship BusyBox `crontab` without the setuid bit and keep
the spool root-owned, so an unprivileged account cannot schedule anything. The installer detects this and
stops with an explanation. Schedule
`$HOME/.local/bin/nas-platform-deploy --poll` every five minutes with the
firmware's own task scheduler, running as the deployment account, then re-run
the installer with `-e production_auto_deploy_external_scheduler=true` so it
installs everything except the cron entry.

Clone anonymously over HTTPS. Keep the controller outside
`/volume1/Docker/nas-platform`, which is service state rather than deployment
source. No PAT, deploy key, GitHub secret, or inbound self-hosted runner is
required:

```sh
mkdir -p "$HOME/.local/share/nas-platform"
chmod 700 "$HOME/.local/share/nas-platform"
git clone https://github.com/yonatankarp/nas-platform.git \
  "$HOME/.local/share/nas-platform/controller"
cd "$HOME/.local/share/nas-platform/controller"
git switch main
git pull --ff-only origin main
```

Create the controller environment with the repository's current exact pins:

```sh
python3 -m venv .venv
. .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r controller-requirements.txt
ansible-galaxy collection install -r requirements.yml
```

`PLATFORM_PUBLIC_HOST` is the name your devices actually use to reach published
services. On a Tailscale network that is the machine's tailnet domain name rather
than an address. ntfy hashes it into
the mobile push topic, so setting it to the LAN address publishes where nothing
is subscribed and reports no error. The installer requires it explicitly rather
than defaulting it.

Place the already reviewed encrypted vault and its password provider at the
fixed protected paths described in
[Production auto-deployment inputs](secrets.md#production-auto-deployment-inputs).
The following values match the production contract for this NAS:

```sh
export PLATFORM_NAS_ADDRESS=192.168.0.139
export PLATFORM_PUBLIC_HOST=nas.example.ts.net
export PLATFORM_CALLBACK_HOST=192.168.0.139
export PLATFORM_VAULT_FILE="$HOME/.config/nas-platform/vault.yml"
export PLATFORM_VAULT_PASSWORD_FILE="$HOME/.config/nas-platform/vault-password"
```

Before installing automation, manually validate the vault, deploy the platform,
and run the complete fail-closed verification set. Each command must finish
with `failed=0` and `unreachable=0`:

```sh
ansible-playbook -i inventory/local.yml validate-vault.yml \
  --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE" \
  -e @"$PLATFORM_VAULT_FILE" \
  -e platform_vault_file="$PLATFORM_VAULT_FILE"

ansible-playbook -i inventory/local.yml site.yml \
  --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE" \
  -e @"$PLATFORM_VAULT_FILE" \
  -e platform_vault_file="$PLATFORM_VAULT_FILE"

ansible-playbook -i inventory/local.yml verify.yml \
  --tags platform_verify_ntfy,platform_verify_beszel,platform_verify_dozzle,platform_verify_audiobookshelf,platform_verify_komga,platform_verify_tinymediamanager,platform_verify_jellyfin,platform_verify_immich,platform_verify_paperless \
  --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE" \
  -e @"$PLATFORM_VAULT_FILE" \
  -e platform_vault_file="$PLATFORM_VAULT_FILE"
```

Only after those three commands pass, install the poller and its single
five-minute cron entry:

```sh
ansible-playbook -i inventory/local.yml install-production-auto-deploy.yml \
  --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE" \
  -e @"$PLATFORM_VAULT_FILE" \
  -e platform_vault_file="$PLATFORM_VAULT_FILE" \
  -e production_auto_deploy_vault_password_file="$PLATFORM_VAULT_PASSWORD_FILE" \
  -e production_auto_deploy_public_host="$PLATFORM_PUBLIC_HOST"

crontab -l
$HOME/.local/bin/nas-platform-deploy --status
$HOME/.local/bin/nas-platform-deploy --poll
```

On a first installation the explicit `--poll` is not a no-op: nothing is
recorded yet, so it runs a full deployment cycle. It is a no-op on later runs,
once the current revision is already recorded as successful. After that, cron polls every five minutes. It
resolves the exact current `main` SHA anonymously, accepts exactly one completed
successful `push` run of the `CI` workflow for that same SHA, checks out that
exact commit, updates the controller virtualenv from that commit's
`controller-requirements.txt`, then runs vault validation, deployment,
verification, and the installer update locally. The installer update reinstalls
the poller itself, so a change to the poller takes effect on the following poll.
Because the virtualenv is synchronised before Ansible runs, a dependency bump
merged to `main` reaches the NAS on the next successful deployment.
GitHub access remains read-only and uses no PAT.

Each revision is attempted at most once.
The same failed SHA is not retried automatically, but a newer successful SHA
can proceed normally. After fixing the cause and
confirming that the failed commit is still current `main` with successful CI,
retry only that exact SHA manually:

```sh
FAILED_SHA=0123456789abcdef0123456789abcdef01234567
$HOME/.local/bin/nas-platform-deploy --retry-failed "$FAILED_SHA"
```

Attempt logs are protected mode-0600 files under
`$HOME/.local/share/nas-platform/logs`, retained for 30 days. The controller
checkout, the installed poller, and the deployment state live under the same
private root. Success and failure outcomes are sent to ntfy using the
deployer's own protected publisher token, as rendered Markdown rather than a
raw document. A failed deployment publishes to `nas-critical` at priority 5; a
successful one publishes to `nas-deployment` at priority 3, so a routine deploy
does not compete with a real problem for attention.

A poll that cannot establish a candidate revision at all -- Git unreachable,
the GitHub API failing, an unparsable response -- is a worse failure than a
failed deployment, because a silent poll is also what a healthy idle poll looks
like. After three consecutive blind polls, a quarter hour at the five-minute
cadence, the poller publishes once to `nas-critical` and stays quiet until the
condition changes; recovery is announced once on `nas-deployment`. A single
blip never alerts. An unusable configuration cannot be reported this way,
because the notifier credentials come from the same file; it remains a stderr
message and a non-zero exit.

Secrets stay out of the logs because the tasks that handle them set `no_log`,
and the vault password is passed to Ansible as a file path rather than a
value.

Once a local poll, cron inspection, and at least one automatic no-op have been
verified, you may optionally disable SSH for this account if the NAS has an
independent, tested break-glass administration path. Outbound HTTPS to GitHub
and local Docker/cron access must remain available.

To disable automation, first save `crontab -l`, then use `crontab -e` to remove
only the `NAS platform production auto-deploy` entry and its command. Do not use
broad recursive deletion as an uninstall procedure. Disabling or removing the
poller does not delete running services, application data, or attempt logs;
retaining the logs and the recorded deployment state preserves audit evidence.

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
git clone https://github.com/yonatankarp/nas-platform.git \
  ~/.local/share/nas-platform/controller
cd ~/.local/share/nas-platform/controller
git switch main
git pull --ff-only origin main

python3 -m venv .venv
. .venv/bin/activate
python3 -m pip install --upgrade pip
python3 -m pip install -r controller-requirements.txt
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

If a run fails, capture the first failure, container state, and bounded logs;
then use the tested service-specific backup/restore procedure or fix forward
with a reviewed Ansible change.
