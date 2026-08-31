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
- [Media acquisition Phase 1 handoff](docs/media-acquisition-phase1.md)
- [Ansible concepts used here](docs/ansible-basics.md)
- [Adding a service](docs/adding-a-service.md)

The [`services/manifest.yml`](services/manifest.yml) catalog distinguishes
thirteen implemented service projects from two planned media-acquisition
projects. Runtime role and service directories exist only for the implemented
projects; the planned entries remain inert and intentionally have no runtime
role or Compose directory.
Prove the implemented platform on the Mac before preparing a fresh production NAS
installation.

## Design

### Container CPU policy

Production containers are restricted to logical CPUs `0-2` on the four-core
AS6704T, leaving one logical CPU free of container processes. Every Compose
service also has a workload-specific hard ceiling between 0.5 and 3.0 CPUs.
Compute-heavy services may use the full three-CPU container set when it is idle;
lighter services cannot monopolize it. Docker's default equal CPU shares remain
unchanged.

Ansible derives and validates the effective CPU set before deployment, then
checks Docker's applied CPU set and quota after each stack starts. Inspect one
container manually with:

```sh
docker inspect --format '{{json .HostConfig}}' immich_server
```

Change the production budget only through
`inventory/group_vars/nas_hosts/main.yml`; the next Ansible run recreates and
verifies affected containers.

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
before deploying. Use the generator only for a truly brand-new platform with no
identities or state to preserve.

```sh
ansible-galaxy collection install -r requirements.yml

# Review, then apply.
ansible-playbook -i inventory/remote.yml site.yml --check --diff --ask-vault-pass
ansible-playbook -i inventory/remote.yml site.yml --ask-vault-pass
```

## Secrets and the vault

Follow the [complete secrets and encrypted-vault guide](docs/secrets.md) for
fresh generation, validation, private review, and backup.

An encrypted file starts with `$ANSIBLE_VAULT;1.1;AES256` followed by hex
ciphertext. Plays read it directly given the password, so it never has to be
decrypted on disk to run anything.

**If you lose the password the vault is unrecoverable.** There is no backdoor.
Recovery means regenerating every credential and running again, which this design
survives because everything is authored in vault rather than read back from
running services, but you would be reprovisioning ntfy, Beszel and every
administrator account. Keep the password in a password manager.

The repository vault remains ciphertext and may be committed, so its safety
rests on the strength of the password — and, once unattended deployment is
installed, on the protection of the copy of that password the poller requires on
the NAS. Deployment also writes plaintext into three trees on the target; the
[security boundary](#security-boundary) enumerates them, and a backup that
reaches any of them is a backup of credentials.

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

### Automatic NAS deployments

After the first NAS-local deployment and full verification, the repository can
install a five-minute, non-root poller on the NAS. It anonymously resolves
`main`, requires the exact commit's successful GitHub `CI` push run, and then
runs the local Ansible deployment and verification. It uses no PAT, deploy key,
GitHub write permission, inbound webhook, or self-hosted runner. A failed commit
is quarantined until an operator explicitly retries that exact current SHA; a
newer successful commit may proceed normally.

The same installer schedules a weekly Docker image prune, because every image is
pinned by digest and each bump otherwise leaves its predecessor on disk forever.
It removes only images no container references, holds the poller's own
deployment lock while Docker runs so it can never race a deployment, and reports
what it reclaimed. Rollback is unaffected: images are pinned by digest, so an
earlier revision re-pulls exactly what it names.

The complete bootstrap, status, manual retry, protected-log, ntfy, SSH, prune,
and disable/removal procedures are in the
[physical NAS walkthrough](docs/getting-started-nas.md#automatic-deployment-from-the-nas).

## Media acquisition foundation

The production retirement checkpoint has passed, and the retired metadata
manager declarations have been removed from this repository. Former metadata
manager application state is preserved outside repository management and was
not deleted.

Phase 1 implements the `arr` and `downloaders` projects for Radarr, Sonarr,
Prowlarr, Bazarr, Configarr, SABnzbd, and Unpackerr. Both transport flags
default to false in the role defaults, as do automatic monitoring, rename, and
the Bazarr handoff. Provider, indexer, and subtitle preferences default to empty
operator-owned lists. Inventory decides the rest, and the two inventories
disagree deliberately:
[`inventory/group_vars/nas_hosts/main.yml`](inventory/group_vars/nas_hosts/main.yml)
sets `media_usenet_enabled: true`, so a normal deployment to the physical NAS
starts the Phase 1 Usenet acquisition containers, while
[`inventory/group_vars/mac_hosts/main.yml`](inventory/group_vars/mac_hosts/main.yml)
leaves both flags false, so the Mac proof starts no acquisition containers or
downloads. Torrent enablement is false on every host, so no torrent client is
deployed anywhere.

Phase 2 adds Pinchflat, which writes the `Media/YouTube` library that Jellyfin
reads, and Kapowarr, which writes the `Books/Comics` library that Komga reads.
Both are self-contained: they consume no platform API, join no control network,
and need neither transport flag, so they deploy unconditionally. Each one's web
interface is the writer, and its only access control is the administrator
identity authored in vault; nothing is downloaded until an operator declares a
source in the application. Kapowarr additionally needs the vault-authored
ComicVine key entered in the application before it can identify anything, which
is the deliberate reason a fresh deployment acquires nothing.

Phase 2 also adds Bindery, which writes the `Books/Ebooks` library Komga reads
and the `Media/Audiobooks` library Audiobookshelf reads. Bindery is not
self-contained: it stores a Prowlarr instance and a SABnzbd download client, and
it resolves the host in both URLs at write time, so it joins `media-control` and
converges after those two projects. Those two rows follow the same transport
flag Phase 1 does, so the NAS declares them and the Mac proof does not, but the
container itself deploys unconditionally on both. Unattended auto-grabbing is
pinned off explicitly, because Bindery's kill switch fails open and a missing
setting reads as enabled, and telemetry is disabled; a deployment that has been
given no author to monitor therefore downloads nothing. The remaining two
acquisition projects — Trailarr and Seerr — stay planned.

Each of the later phases was investigated before it was planned, against
upstream source and a running container. The
[service investigation dossiers](docs/service-dossiers.md) record what those
investigations found, marking every claim as measured or reasoned, so a
promotion starts from evidence rather than from the beginning. Pinchflat and
Kapowarr have dossiers of their own written after the fact, recording which
parts of each application Ansible does not own — because for these two,
configuration made in the web interface is *not* reverted by the next run.

Open Subtitles remains configured in Jellyfin until Bazarr is proven on the
physical NAS. Follow the
[Phase 1 operator handoff](docs/media-acquisition-phase1.md) before enabling a
transport or changing any media writer.

## Testing

```sh
bash tests/validate-policy.sh # every policy script, run concurrently
ansible-lint --strict          # production profile
tests/integration.sh site.yml  # converge, re-converge, then --check --diff
```

The integration harness runs Ansible in a Linux container against a disposable
sandbox, so the plays meet a real `/proc/mounts`, real numeric uid and gid, and a
real Docker socket. It asserts three properties: the run converges, a second run
changes nothing, and a dry run works. Two of the worst bugs found so far, a fact
that exists only on Linux and `command` being skipped under `--check`, both passed
syntax checking and were caught only by running.

The controller that container runs is a published image
(`tests/integration.Dockerfile`), tagged with a digest of the harness's pins,
`requirements.yml` and the Dockerfile itself, so a bumped pin is a new image
rather than a stale one. Nothing requires it: a run that cannot pull the image
builds it locally and reuses it afterwards, and a run that cannot build it
installs the same toolchain inside the container the way the harness always did.
`INTEGRATION_TOOLCHAIN=off` forces that last path.

The current Mac proof covers ntfy, Beszel, Dozzle, Audiobookshelf, Komga,
Jellyfin, Immich, Paperless-ngx, Pinchflat, and Kapowarr — every implemented
service except `arr` and `downloaders`, whose Phase 1 runtime is
default-disabled in that lane and proved by its Docker integration suite.
NAS-only GPU, host-networking, native-mount and production-scale behavior remain
outside the Mac proof.

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

A failed run preserves its sandbox by default; `--keep-on-failure` states that
policy explicitly for automation that wants it in writing.

[docs/getting-started-mac.md](docs/getting-started-mac.md) owns the rest of the
contract, so that it is stated once: the password-provider rules and the
[ordered phases](docs/getting-started-mac.md#3-run-the-complete-fresh-proof),
[the manual review](docs/getting-started-mac.md#4-perform-the-manual-review),
and [what a failure preserves, together with the single validated cleanup
command](docs/getting-started-mac.md#5-resume-or-clean-a-failed-proof).

## Manual escape hatch

Ansible owns deployment, but a stack can be brought up by hand if needed. Run it
against what the target actually runs, not against this checkout: the target
never runs from a clone. `deployment_bundle` installs an immutable release at
`platform_current_dir` and keeps the rendered secrets separately under
`platform_runtime_dir`, so the Compose file and the environment file come from
two different trees, and `services/<name>/.env` exists in neither.

On the NAS, with the production defaults of
`inventory/group_vars/all/main.yml`:

```sh
cd /volume1/Docker/nas-platform/current/services/ntfy
docker compose \
  --project-name ntfy \
  --env-file /volume1/Docker/nas-platform/runtime/services/ntfy/.env \
  -f compose.yml up -d
```

The project name matters: Ansible derives it from `platform_project_name`, which
is empty on the NAS, so the production project is the bare service name. A
sandbox sets that variable and its projects are prefixed, which is what lets
several copies of the platform run side by side.

One `-f` is right for production because no service ships a `compose.nas.yml`.
The disposable lanes do ship overrides, so a sandbox release holds
`compose.mac.yml` or `compose.integration.yml` beside `compose.yml` and needs
both, override second. That is the pair Ansible itself reads from
`platform_service_compose_files`; check the release directory rather than
assuming.

The checkout under `services/` is the source those releases are built from, not
the release the target runs. Anything started by hand is reverted by the next
Ansible run, which is the point.

## Security boundary

Safe to commit: Compose definitions, pinned image digests, port and volume
mappings, roles, the **encrypted** vault, and documentation.

Never commit: the vault password, any decrypted vault copy, rendered `.env` files,
plaintext credentials, or application data.

### Where plaintext lives at runtime

Deployment writes plaintext into three trees on the NAS. A backup that reaches
any of them is a backup of credentials, whatever the vault's own encryption
says.

- **The platform runtime directory**, `/volume1/Docker/nas-platform/runtime` in
  production: one mode-0600 `services/<name>/.env` per stack, rendered from
  vault by each role's `templates/env.j2`.
- **Service data under the Docker root**, `/volume1/Docker` in production:
  Dozzle's data directory as a whole, Beszel's hub private key, and the
  first-run configuration Ansible seeds and then leaves alone — SABnzbd's
  `sabnzbd/config/sabnzbd.ini` (administrator username, password and API key),
  the Radarr, Sonarr and Prowlarr `config/config.xml` files (API keys), and
  Bazarr's `bazarr/config/config/config.yaml` (API key, administrator identity).
  Each is seeded mode 0600 with `force: false`, so the application owns it
  afterwards; applications and databases keep further copies of their own.
  Dozzle's directory is secret-bearing past its users file: Ansible POSTs a
  notification dispatcher into Dozzle's API, and Dozzle persists that
  dispatcher there complete with the `Authorization: Bearer` header it
  carries.
- **The deploy account's home**, once `install-production-auto-deploy.yml` has
  run. `~/.config/nas-platform` is mode 0700 and holds the mode-0600
  `vault-password` file the poller requires, plus two protected ntfy publisher
  files, `ntfy.curl` and `ntfy-prune.curl`, each carrying the deployment token.
  The sibling `~/.local/share/nas-platform` is mode 0700 and holds the
  controller checkout, the recorded deployment state, and the mode-0600 attempt
  and prune logs; those logs are written without credentials, because every task
  that handles one sets `no_log` and the vault password is passed to Ansible as
  a path rather than a value.

**Unattended production deployment places the vault password on the NAS.** The
installer refuses to proceed unless `~/.config/nas-platform/vault-password`
already exists as a regular mode-0600 file, so from that point the deploy
account — and root — can decrypt the committed vault without knowing anything
else. Exclude that account's home from ordinary backups, or protect the backup
exactly as you protect the password manager entry. The vault's ciphertext is not
a second line of defence once its password sits beside it.
