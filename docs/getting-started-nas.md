# Physical NAS walkthrough

This path targets a fresh production installation. Complete the
[disposable Mac proof](getting-started-mac.md), protect any media already on the
NAS, and confirm every required service is `implemented` or `accepted` in
[`services/manifest.yml`](../services/manifest.yml) before installation. The
fifteen implemented service projects are Audiobookshelf, Beszel, Bindery,
Dozzle, Immich, Jellyfin, Kapowarr, Komga, ntfy, Paperless-ngx, Pinchflat,
Seerr, Trailarr, and the Arr and downloader projects, which this host runs because it
enables Usenet. The
production retirement checkpoint has passed and the retired metadata manager
declarations have been removed from the repository.

Commands are labelled **read-only**, **check mode**, or **changes production**.

## Retired metadata manager cleanup checkpoint

Former metadata manager application state remains preserved outside repository
management; the repository cleanup did not delete it or any media. Phase 1
implements Arr and the Usenet downloader project. Both transport flags default
to `false`, but
[`inventory/group_vars/nas_hosts/main.yml`](../inventory/group_vars/nas_hosts/main.yml)
sets `media_usenet_enabled: true`, so a run against this host starts Radarr,
Sonarr, Prowlarr, Bazarr, Configarr, SABnzbd, and Unpackerr;
`media_torrent_enabled` stays `false`, so no torrent client is deployed. Three
later projects remain planned. Open Subtitles remains configured in Jellyfin
until the
[Phase 1 operator handoff](media-acquisition-phase1.md) records physical-NAS
Bazarr proof.

## 1. Prepare the NAS and workstation

The NAS needs Docker, the Docker Compose plugin 2.18.0 or newer, Python 3 with
the `requests` package available to Ansible's managed interpreter, SSH access,
and enough space under the configured storage roots. From your
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
python3 -c 'import requests'
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

If the production auto-deploy poller is already installed on this NAS, it
converges the same host every five minutes and a run from a workstation cannot
hold the lock that serialises them, because that lock lives on the NAS. Such a
run is refused at the first task of the first role while a deployment is in
flight; a converge that must hold the lock is run on the NAS through
[the launcher](#converging-by-hand-while-the-poller-runs).

Direct Jellyfin-only or Audiobookshelf-only runs require a completed foundation
or full-site converge that created the external `media-control` network. This
prerequisite applies only to those two reader services.

Success requires `failed=0` and `unreachable=0`. Do not start manual repairs
after a failure. Preserve the first failing task and its message, check the
affected container without exposing secrets, and decide whether to fix forward
or execute the pre-agreed rollback.

Do not enable acquisition as part of this general platform apply. Complete the
default deployment and verification first, then use the separate
[Phase 1 operator handoff](media-acquisition-phase1.md) for one-target adoption,
proof downloads, ACL acceptance, and rollback ordering.

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
unchanged for all fifteen implemented service projects. Repeat the
service-specific credential checks from the
[Mac manual review](getting-started-mac.md#4-perform-the-manual-review)
against the production deployment without exercising external integrations; for
ntfy, use only an agreed disposable topic when verifying alerts from Beszel and
Dozzle.

Media acquisition also requires a NAS-only ADM share check that the platform
cannot make for you. Be precise about which half is which.

What the platform asserts, on every tagged verification run:

```sh
ansible-playbook -i inventory/local.yml verify.yml \
  --tags platform_verify_media_acquisition_foundation
```

Every classified `media_acquisition_foundation` path exists, is a real
directory rather than a symlink, and carries its declared mode `0755`. The two
directories this check names, `Media/.acquisition` and `Books/.acquisition`, are
asserted by name, and their ownership declaration is asserted to be absent
because the NAS owns everything under the media root.

What no part of the platform asserts: that an ordinary account is refused.
Mode `0755` grants `o+rx`, so every local account may list and traverse both
trees, and the verification run above proves exactly that rather than
contradicting it. The denial rests entirely on ADM share configuration, which
Ansible does not own and no test in this repository inspects. A check run from
an account in `administrators` proves nothing either way.

Verify it by hand, from a client signed in as a **non-administrator** SMB
account:

```sh
ls /Volumes/Media/.acquisition
ls /Volumes/Books/.acquisition
```

A pass is permission denied, or the path not being visible at all. Listing
`usenet torrents` is the finding, and the fix is in ADM share permissions rather
than in this repository. Record only pass/fail and the tested identity class,
never directory listings, ACL dumps containing private account details, or
secrets. Docker Desktop cannot prove this NAS ACL boundary at all; see
[what the Mac proof does not prove](getting-started-mac.md#what-this-does-not-prove).

The platform provisions three ntfy topics for humans, severity first then
subject, plus one nobody reads.

`nas-critical` cuts across every publisher and carries only what should get you
out of your chair: out of memory, an unexpected container exit, an unhealthy
container, a Beszel threshold breach, a failed deployment, a revision CI
refuses to release, and a deployment poller that has gone blind. The other two
are the routine record, one per subject, so deployment chatter can be muted
without also muting container events: `nas-deployment` for successful
deployments and poller recovery, and `nas-containers` for container recoveries.

A fourth topic, `nas-verification`, exists only for the provisioning proof:
every publisher token publishes there once per converge to prove it can still
write. It is deliberately absent from the topic list a managed user may declare
access to, so no account can subscribe and no device is notified. Refusing the
cache is not a substitute — ntfy forwards a poll request to its upstream push
server for every message once `upstream-base-url` is set, carrying the message
id alone, and the phone then fetches the body from your server. An uncached
proof therefore arrived as an empty "New message", once per publisher, on every
converge.

A service reports its own deployment on `nas-deployment` at priority 2 —
`Komga deployed (recreated)` — only when Compose actually replaced its
containers. The controller publishes it with the deploy publisher's token, so
no service needs a token of its own inside its image.

A service the run left running unchanged says nothing. It used to report
`already current` so that silence could not be mistaken for a service that was
never deployed, but a release usually moves one image: fifteen services then
published fifteen messages of which fourteen carried no information, and the
topic stopped being read. The run-level summary below already answers "did a
deployment happen, and what did it move", so the per-service report is now the
detail behind it rather than a roll call.

A run that recreates nothing therefore publishes nothing, which also keeps a
selective converge and a re-run of the installed revision silent.

After every service role, a single run-level summary follows on
`nas-deployment` at priority 3, above the per-service detail. It diffs the
manifest of the release the deployment replaced against the one it installed,
so it names the versions each image moved between and the commit subjects the
release carries — readable on a phone with no checkout at hand, where a
revision is a lookup you cannot perform. It is published only when the release
actually moved, and reaching it means the whole run converged. Since it
publishes with the deploy publisher's token, a broken write ACL fails the run
there rather than going unnoticed until an alert is missed.

Message bodies only appear on iOS when the phone can reach the ntfy server named
by `PLATFORM_PUBLIC_HOST` — over Tailscale, a VPN, or the LAN. That is the same
poll-request mechanism described above: off-network, every message shows as
"New message" regardless of what it says.

Each publisher may write only to the topics it reports on, so a leaked Beszel
token cannot reach either record topic, and a leaked deploy token cannot post
container events.

ntfy runs `deny-all`, so a reading account sees only the topics named in its
own `vault_managed_users.ntfy[].access` list, and the role subscribes it to
exactly those. Adding a topic to the platform therefore does not reach a phone
until that account's ACL names it; a topic left out is a 403, not a quiet
omission.

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

Place the vault password provider at the fixed protected path described in
[Production auto-deployment inputs](secrets.md#production-auto-deployment-inputs).
The encrypted vault itself needs no copy: it is committed, so the checkout
carries the candidate revision's own. The following values match the production
contract for this NAS:

```sh
export PLATFORM_NAS_ADDRESS=192.168.0.139
export PLATFORM_PUBLIC_HOST=nas.example.ts.net
export PLATFORM_CALLBACK_HOST=192.168.0.139
export PLATFORM_VAULT_PASSWORD_FILE="$HOME/.config/nas-platform/vault-password"
```

Before installing automation, manually validate the vault, deploy the platform,
and run the complete fail-closed verification set. Each command must finish
with `failed=0` and `unreachable=0`:

```sh
ansible-playbook -i inventory/local.yml validate-vault.yml \
  --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE"

ansible-playbook -i inventory/local.yml site.yml \
  --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE"

ansible-playbook -i inventory/local.yml verify.yml \
  --tags platform_verify_media_acquisition_foundation,platform_verify_ntfy,platform_verify_beszel,platform_verify_dozzle,platform_verify_audiobookshelf,platform_verify_komga,platform_verify_arr,platform_verify_downloaders,platform_verify_bindery,platform_verify_kapowarr,platform_verify_pinchflat,platform_verify_trailarr,platform_verify_jellyfin,platform_verify_seerr,platform_verify_immich,platform_verify_paperless \
  --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE"
```

Run this manual verification for the first foundation deployment: the installed
poller cannot select a verification tag that exists only in the candidate until
that candidate has been activated.

Only after those three commands pass, install the poller and its single
five-minute cron entry:

```sh
ansible-playbook -i inventory/local.yml install-production-auto-deploy.yml \
  --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE" \
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

### Converging by hand while the poller runs

Once the poller is installed, this host converges itself every five minutes, so
a hand-run converge that takes longer than that will overlap one. Deployments
are serialised by an flock on the poller's state directory, and a bare
`ansible-playbook` does not take it. Run converges through the launcher instead:
it acquires that same lock, so the poll that arrives in the middle does nothing
and tries again five minutes later, and passes everything after `--` to
`ansible-playbook` unchanged — inventory, tags, vault password provider and
working directory all stay yours.

```sh
cd /path/to/your/checkout
$HOME/.local/bin/nas-platform-deploy --converge -- \
  -i inventory/local.yml site.yml --check --diff --ask-vault-pass
$HOME/.local/bin/nas-platform-deploy --converge -- \
  -i inventory/local.yml site.yml --ask-vault-pass
```

A converge that starts while another one holds the lock is refused immediately,
naming the holder, rather than starting and failing later. The same is true of a
run started any other way, including over SSH from a workstation:
`deployment_bundle` probes the lock at the first task of every role and stops the
run with *"A deployment is already running on this host"*. Before this existed,
the loser of that race ran to the last role and then failed on the deployment
containment guard, reporting an unsafe deployment target — a message about
integrity, for what was only a collision. Wait for the running deployment,
confirm with `--status`, and then re-run.

Attempt logs are protected mode-0600 files under
`$HOME/.local/share/nas-platform/logs`, retained for 30 days. The controller
checkout, the installed poller, and the deployment state live under the same
private root. The record of attempted revisions -- the list `--status` prints
-- is bounded the same way, to the newest 50 within 90 days, and every poll
trims it alongside the logs rather than only when something ships. Deploying
one revision at a time fills that record faster than deploying only heads did,
and a platform that changes rarely is exactly the one whose expired entries
would otherwise sit there forever.

Failures are sent to ntfy using the deployer's own protected publisher token,
as rendered Markdown rather than a raw document, publishing to
`nas-critical` at priority 5. A successful deployment reports itself from inside
the run, through the summary above, which can say what shipped; the poller adds
nothing to it and stays quiet.

The poller deploys the newest revision of `main` that CI has released, which is
not always the head. A full run takes longer than the gap between merges, so the
head is often still running while the revision behind it has already passed;
waiting for the head would leave that revision undeployed for the length of a
run it has nothing to do with. A revision CI has not judged is therefore
stepped over rather than waited for, and deploys in its own right once its own
run concludes -- so a batch of merges reaches the NAS one revision at a time,
in order. Nothing ever moves backwards: the walk stops at the first revision
the poller has already attempted, and `--status` names the revision it would
deploy whenever that is not the head.

Being stepped over is also the right answer for a revision CI will *never*
judge. `CI` cancels only a pull request's own superseded runs; a push to `main`
queues behind the one before it, because a post-merge run is the only run that
will ever see the tree it merged. While `cancel-in-progress` was keyed on the
branch alone, merging twice inside one run's window left the first revision
`cancelled` -- neither a pass nor a failure -- and roughly a quarter of pushes
to `main` ended that way. A run cancelled by hand still ends the same way. The
poller walks past such revisions and stays silent; treating them as a red
`main` would raise a critical alert for a run that judged nothing.

A revision CI refuses is the other way a deployment never happens. The poller
requires exactly one completed, successful `CI` push run for the revision it is
about to deploy; when the run reached a verdict and that verdict was anything
else, or when several successful runs make the answer ambiguous, nothing
deploys until a human intervenes, and a refused revision blocks every revision
behind it, so a red `main` still stops every deployment. A conclusion this
poller does not recognise counts as a refusal rather than being waved through,
and a cancelled re-run does not bury the failure that prompted it: the newest
run that actually judged the revision is the one that counts. A refusal is
announced once on `nas-critical` at priority 4, naming the revision, the
conclusion and the run's URL. Once per revision and verdict, not once per
poll: a red `main` stays red, and the five-minute cadence would otherwise
repeat it twelve times an hour. A revision
whose CI has not finished yet is the ordinary case and is never reported.
`--status` says the same thing on demand.

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

### The weekly image prune

The same installer schedules a second, unrelated job: a weekly Docker image
prune, 04:00 on Sunday, as the same account. Every image is pinned as
`repo:tag@sha256:...`, so each Renovate bump pulls a new image and leaves the
superseded one on disk; nothing else on the NAS ever removes it.

Two passes run, in this order:

```sh
docker image prune --all --force --filter until=168h
docker image prune --force --filter until=24h
```

The first removes every image no container references and that was created more
than a week ago. The second removes untagged leftovers on a shorter window,
because nothing can name them at all. Neither can reach a volume, a network, a
stopped container, or anything else: `docker image prune` has no argument that
would, and the prune builds its own argument vectors rather than accepting one.

Two properties are worth being precise about, because the obvious reading of
each is wrong:

- **`until` compares an image's creation time, not when this host pulled it.** A
  release published upstream months ago and pulled a minute ago is already
  outside a 168h window. The window is a margin, not the thing that keeps a
  prune off a running deployment.
- **What keeps a prune off a running deployment is the poller's own lock.** The
  prune takes `state/deployment.lock` and holds it while Docker runs, so it
  cannot delete an image in the gap between a deployment pulling it and starting
  its container. If a deployment already holds the lock, the prune waits fifteen
  minutes and then skips: the same images are still there next Sunday. A poll
  that arrives while a prune holds the lock likewise does nothing and retries
  five minutes later.

Rollback does not depend on the local image cache. Images are pinned by digest,
so deploying an earlier revision re-pulls exactly the image that revision names.
A pruned image costs a pull, not availability.

#### Scheduling it

The prune is installed by the same play as the poller, so nothing new is cloned,
no credential is added, and no inventory value is required. Installing the
poller installs the prune with it:

```sh
ansible-playbook -i inventory/local.yml install-production-auto-deploy.yml \
  --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE" \
  -e production_auto_deploy_vault_password_file="$PLATFORM_VAULT_PASSWORD_FILE" \
  -e production_auto_deploy_public_host="$PLATFORM_PUBLIC_HOST"
```

On a host where this account manages its own crontab, that installs the weekly
entry as well, and there is nothing further to schedule. Both entries should be
present, and the installed prune should read its own configuration:

```sh
crontab -l
$HOME/.local/bin/nas-platform-prune --status
```

Where an unprivileged account cannot use cron — the ADM case above — the
installer takes its scheduling mode from
`production_auto_deploy_external_scheduler` and installs everything except the
cron entry, exactly as it does for the poller. Schedule
`$HOME/.local/bin/nas-platform-prune --prune` weekly with the firmware's own
scheduler, running as the deployment account. The concrete root crontab
procedure for ADM, and the crond restart it needs, are in
[the ADM rollout notes](asustor-adm-rollout.md#the-weekly-image-prune). One flag
covers both schedules; `-e image_prune_external_scheduler=` overrides it only if
the two ever have to differ.

Run the first prune by hand rather than leaving it to the first Sunday. It is
the only run with a backlog to clear — every later one is incremental — and
each pass has a fifteen-minute deadline, so watching the first tells you both
what the host was holding and whether the deadline is comfortable:

```sh
docker system df
$HOME/.local/bin/nas-platform-prune --prune
$HOME/.local/bin/nas-platform-prune --status
```

`docker system df` reports what a prune has to work with; there is no dry run,
because Docker offers no honest one. Nothing above needs doing before the
change that introduces the prune is deployed: the launcher does not exist until
the installer has run.

The schedule and both windows are role defaults, overridable from inventory:
`image_prune_cron_minute`, `image_prune_cron_hour` and
`image_prune_cron_weekday` for when it runs, `image_prune_retention_hours` and
`image_prune_dangling_retention_hours` for what it may remove, and
`image_prune_lock_wait_seconds` for how long it waits on a deployment. The
prune refuses a configuration that would remove same-day images, or a dangling
window wider than the unused one, rather than installing a schedule that fails
on its first run.

#### Operating it

Inspect and operate it the same way as the poller:

```sh
$HOME/.local/bin/nas-platform-prune --status
$HOME/.local/bin/nas-platform-prune --prune
```

`--status` reads the installed configuration and reports what the last run
reclaimed and which windows the next one will apply; it takes no lock and
touches no image. Prune logs are mode-0600 files under
`$HOME/.local/share/nas-platform/prune-logs`, retained for 30 days and kept
separate from the poller's attempt logs.

A run that reclaims something publishes to `nas-deployment`; a run that fails
publishes to `nas-critical` at priority 5, through the deployer's own write-only
token. A run that reclaims nothing stays quiet, because most weeks reclaim
nothing and a weekly no-op notification is noise. The recorded state under
`prune-state/last-prune` is what to read when the silence needs explaining.

Removing the `NAS platform Docker image prune` crontab entry disables it, the
same way the poller's entry is removed. Where this account manages its own
crontab, that entry is Ansible's: the poller replays the installer play on every
deployment, so it returns on the next successful one. Where scheduling is
external — an ADM firmware is the case that matters, see the
[ADM rollout notes](asustor-adm-rollout.md) — the entry belongs to root's
crontab, nothing replaces it, and removing it is permanent until it is added
back by hand.

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
search results in each active application.

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
