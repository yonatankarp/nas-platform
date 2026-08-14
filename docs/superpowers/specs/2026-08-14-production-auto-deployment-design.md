# Production Auto-Deployment Design

## Objective

Automatically deploy each new `main` commit to the physical NAS after the exact
commit's GitHub Actions `CI` push workflow succeeds. The NAS polls GitHub every
five minutes, runs Ansible locally, verifies the result, and publishes a
best-effort `nas-critical` notification. The design requires no inbound GitHub
connection, self-hosted Actions runner, Portainer control plane, GitHub token,
or continuously available Mac.

The first production installation remains manual because it installs the
poller. Every later eligible commit is deployed automatically.

## Non-goals

- Portainer Git polling or direct Compose-only updates.
- Deploying pull-request, scheduled, or manually dispatched workflow runs.
- Deploying a commit whose CI is pending, failed, cancelled, or absent.
- Automatically retrying a failed deployment of the same commit.
- Migration, adoption, legacy seeding, database writes outside supported
  application APIs, or automatic rollback.
- Exposing the NAS to inbound GitHub traffic.
- Storing a GitHub personal access token while the repository is public.

## Chosen architecture

A native NAS-side poller runs from the dedicated non-root deployment account's
crontab every five minutes. It uses outbound anonymous HTTPS for the public Git
repository and GitHub Actions API, then runs the repository's supported Ansible
playbooks with `inventory/local.yml`.

This is preferable to a self-hosted Actions runner because it does not leave a
general-purpose remote workflow executor on the NAS. It is preferable to a
Portainer polling container because the deployment includes host preparation,
immutable bundle publication, user and credential reconciliation, application
API configuration, and verification that Compose alone cannot perform.

The deployment account owns the controller checkout, Ansible environment,
encrypted deployment vault, password provider, poller state, and protected
logs. It has only the NAS permissions already required to run the platform
playbook and Docker Compose. The poller never runs as `root` and never uses
`sudo` internally.

## Components

### Stable launcher

A small launcher is installed atomically into the deployment account's private
local binary directory. Cron invokes only this stable launcher. It validates
the configured paths, acquires a non-blocking deployment lock, and invokes the
polling implementation from the owned controller checkout.

The launcher contains no credentials. An in-progress launcher continues using
the bytes it started with; a successful candidate deployment may atomically
install the next reviewed launcher version for subsequent polls.

### Polling implementation

The repository owns the polling implementation and its tests. It supports:

- normal poll mode, used by cron;
- `--status`, which reports only non-secret deployment state;
- `--retry-failed SHA`, which retries one explicitly named quarantined SHA.

Unknown arguments, ambient path overrides, embedded Git credentials, relative
paths, symlinked protected inputs, or unsafe state fail before Git, Ansible, or
notification mutations.

### Controller checkout and tooling

The controller checkout lives under the deployment account's private data
directory, outside `/volume1/Docker/nas-platform`. The latter remains solely
owned by the immutable deployment-bundle role. The checkout is a clean,
dedicated clone of:

`https://github.com/yonatankarp/nas-platform.git`

The poller fetches `main`, resolves its exact 40-character commit SHA, and
checks out that SHA detached. It refuses local changes, unexpected remotes,
submodules, alternate object stores, or a controller path outside its owned
root.

Pinned Ansible tooling is installed in a private virtual environment owned by
the deployment account. Bootstrap installs it before the first play. The
automatic deployment validates the required versions before mutation and
fails safely if the controller tooling no longer satisfies the candidate's
declared pins. Tooling-pin changes therefore require a separately tested,
atomic tooling reconciliation step in the same poller before candidate
playbooks execute; partial tooling environments are never published as active.

### State, lock, and logs

The deployment account owns a private state root containing:

- a non-followed lock file;
- `last-successful`, holding exactly one deployed SHA;
- `last-failed`, holding the quarantined SHA and attempt timestamp;
- one protected log per attempt;
- a stable pointer to the most recent attempt log.

State files are regular, non-symlink files written by temporary-file plus
atomic rename. Directories are mode `0700`; state and logs are mode `0600`.
Logs never contain vault contents, password-provider output, Authorization
headers, or notification tokens. Ansible tasks handling credentials retain
their existing `no_log` guarantees. Notifications contain only outcome, SHA,
timestamps, and the local log path.

Logs use a bounded count and age policy. Rotation operates only on validated
regular log files inside the exact owned log directory.

## CI eligibility

Each poll first resolves the exact SHA currently at anonymous HTTPS
`origin/main`. It then queries the public GitHub Actions API for the repository
workflow `.github/workflows/ci.yml` and accepts a run only when every property
matches:

- repository: `yonatankarp/nas-platform`;
- workflow: `CI` at `.github/workflows/ci.yml`;
- branch: `main`;
- event: `push`;
- head SHA: the exact current `origin/main` SHA;
- status: `completed`;
- conclusion: `success`.

The API response must have the expected JSON types and exactly one acceptable
run for the candidate. Malformed, ambiguous, rate-limited, unavailable, or
unexpected responses cause a no-change exit and a bounded local diagnostic.
They do not quarantine the commit because no deployment was attempted.

The poller uses no PAT for the public repository. It makes a bounded number of
requests, respects GitHub rate-limit responses, and does not retry within the
same cron invocation. If the repository becomes private, a future design may
add a fine-grained token limited to this repository with only Contents: read
and Actions: read.

## Deployment flow

After a candidate passes CI eligibility:

1. Acquire the non-blocking deployment lock. If held, exit successfully without
   work.
2. Revalidate every configured directory, file, owner, mode, and remote.
3. Skip a SHA already recorded as successful.
4. Skip a SHA recorded as failed unless explicit retry mode names that exact
   SHA.
5. Fetch and detach-checkout the exact eligible SHA in the clean controller.
6. Revalidate that `HEAD`, `origin/main`, and the successful CI `head_sha` are
   byte-identical.
7. Validate the encrypted vault contract using the fixed local vault and
   password-provider paths.
8. Run `site.yml` with `inventory/local.yml`, the external encrypted vault, and
   the fixed public/callback address configuration.
9. Run `verify.yml` with the same inventory and vault inputs.
10. Reconcile and atomically activate the candidate's poller assets through the
    dedicated auto-deployer installation playbook.
11. On complete success, atomically record `last-successful`, clear an older
    failure record for the same SHA, rotate logs, and send a success
    notification.
12. On deployment, verification, or poller activation failure, atomically record that SHA as
    failed, preserve the protected log, send a best-effort failure
    notification, and return nonzero.

The automatic command line contains no adoption or migration inputs. The
poller also rejects adoption variables from its fixed environment. Production
playbooks continue to enforce their own target and controller safety checks.

If commit A fails, A is quarantined and receives no automatic retry. If a newer
commit B reaches `main` and its exact push CI succeeds, B receives its own one
automatic attempt. This allows a reviewed fix-forward commit to recover
production without manually clearing A.

## Manual retry

The documented retry command names the exact quarantined SHA:

```sh
nas-platform-deploy --retry-failed 0123456789abcdef0123456789abcdef01234567
```

Retry mode rechecks the lock, protected state, Git remote, current `origin/main`,
and successful push CI. It accepts the retry only when the named SHA is the
recorded failed SHA and is still the current `main` SHA. It cannot be used to
deploy an older commit or bypass CI. If a newer successful commit exists, the
normal poll path deploys that commit instead.

## Notifications

The installation role renders a protected curl configuration containing the
existing least-privilege ntfy publisher credential. The token never appears in
process arguments or logs. Notifications are sent to the configured
`nas-critical` topic only after attempt state is durably recorded.

Notification delivery is best-effort. An ntfy outage cannot turn a successful
deployment into a failure or hide the authoritative local failure state. The
poller records only a fixed notification-delivery diagnostic when publishing
fails.

## Installation and lifecycle

A dedicated NAS-only installation playbook owns the auto-deployer role. It is
not part of `site.yml`: this prevents an otherwise successful convergence that
later fails verification from prematurely activating new poller code. The
initial bootstrap runs this playbook manually only after the first `site.yml`
and `verify.yml` succeed. Later automatic runs invoke it only after the
candidate's convergence and verification succeed. The role atomically installs
or reconciles the launcher, configuration, protected notification material,
cron entry, state directories, and documentation-visible status command. Mac,
integration, and adoption inventories cannot install or execute the production
poller.

The setup guide documents:

1. creating or selecting the dedicated non-root NAS deployment account;
2. granting only the existing Docker and platform storage permissions;
3. placing the encrypted vault and password provider in its private config
   directory;
4. cloning the controller repository into its private data directory;
5. installing the pinned controller tooling;
6. validating the vault and running the first manual `site.yml` and
   `verify.yml`;
7. running the dedicated installation playbook to bootstrap the poller;
8. confirming the installed cron entry, status output, protected paths, and
   first no-op poll;
9. disabling SSH after bootstrap if desired;
10. reading status and protected logs;
11. explicitly retrying the current quarantined SHA;
12. safely disabling and removing the poller without deleting application
    data or deployment releases.

The dedicated installation playbook updates poller assets atomically only after
later convergence and verification have succeeded. An installer failure leaves
the previous launcher active and quarantines the candidate. Removing the cron
entry stops future automation but does not stop services or delete application
state.

## Failure handling

- CI pending, failed, absent, ambiguous, or unreachable: no deployment and no
  quarantine.
- Lock already held: no deployment and no error notification.
- Unsafe path, ownership, file type, mode, checkout, remote, or state: fail
  before deployment and preserve a fixed diagnostic.
- Vault or tooling validation failure after CI eligibility: quarantine the SHA
  because its production attempt began.
- `site.yml` failure: quarantine the SHA; do not run verification.
- `verify.yml` failure: quarantine the SHA even if convergence succeeded, and
  leave the previous poller active.
- Poller installation/activation failure: quarantine the SHA and retain the
  previous complete poller installation.
- Notification failure: retain the deployment outcome unchanged.
- Power loss: atomic state writes leave either the prior complete state or the
  new complete state. A stale lock does not persist because locking is tied to
  the live process rather than a mere marker file.

No failure path authorizes automatic rollback, volume deletion, Docker-wide
cleanup, vault regeneration, or deployment of a CI-unverified commit.

## Test strategy

Tests run without contacting GitHub or a NAS. Disposable fakes cover GitHub API,
Git transport, Ansible, curl, time, process locking, filesystem state, and
signals. Required cases include:

- exact successful `main` push deploys once;
- pending, failed, cancelled, scheduled, manual, wrong-branch, wrong-workflow,
  wrong-repository, wrong-SHA, malformed, ambiguous, and rate-limited CI never
  deploy;
- anonymous HTTPS is required and embedded credentials are rejected;
- simultaneous polls result in exactly one deployment attempt;
- successful deployment runs vault validation, `site.yml`, and `verify.yml` in
  order with exact fixed inputs;
- site failure skips verification and quarantines the SHA;
- verification failure quarantines the SHA;
- a quarantined SHA is not retried automatically;
- explicit retry accepts only the exact current quarantined successful-CI SHA;
- newer successful B deploys after failed A without clearing A manually;
- successful and failed state writes survive interruption boundaries;
- unsafe symlinks, paths, owners, permissions, state, remotes, dirty checkouts,
  and alternate Git object configuration fail before mutation;
- vault values, provider output, authorization material, and ntfy tokens never
  appear in output, state, or logs;
- notification success and failure do not alter the authoritative deployment
  result;
- log rotation cannot escape or follow links;
- Mac and integration runs do not install the production cron job;
- the installed cron schedule is exactly every five minutes and invokes only
  the stable launcher;
- policy and CI mutation tests require the poller suite and documentation checks
  to remain registered.

An isolated integration test performs two synthetic commits and CI responses:
the first fails its fake deployment and is quarantined, while the second passes
and deploys exactly once. Production verification remains the normal
`verify.yml` execution performed by the poller after convergence.

## Success criteria

- A new `main` SHA with exact successful push CI begins one NAS deployment
  within five minutes while the NAS has GitHub connectivity.
- The exact reviewed SHA becomes the immutable deployment release and passes
  `verify.yml` before being recorded successful.
- The same SHA never deploys automatically twice.
- A failed SHA requires explicit retry, while a newer successful SHA proceeds.
- The workflow needs no inbound NAS access, always-on Mac, GitHub runner, PAT,
  or Portainer deployment authority.
- Operators can bootstrap, inspect, retry, disable, and remove the automation
  using the committed setup guide without exposing secrets.
