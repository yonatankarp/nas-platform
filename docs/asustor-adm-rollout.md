# Automatic deployment on ASUSTOR ADM

The [physical NAS walkthrough](getting-started-nas.md#automatic-deployment-from-the-nas)
describes the general installation. This page records what ADM does differently,
because four of its choices each break the poller in a way that is not obvious
from the failure message. It was written from a real first rollout on ADM with a BusyBox userland.

Read this before installing, not after a failure.

Placeholders below: `<account>` is the dedicated non-root deployment account,
`<nas-lan-address>` its address on the local network, and
`<nas-hostname>.<tailnet>.ts.net` the machine's Tailscale domain name.

## What ADM does differently

**An unprivileged account cannot use cron.** `/usr/bin/crontab` is a symlink to
BusyBox without the setuid bit, and `/var/spool/cron/crontabs` is a symlink into
`/usr/builtin/etc/crontabs/` containing only a root-owned mode-0600 file. Even
`crontab -l` fails with `must be suid to work properly`. Scheduling therefore has
to come from root, which is what `production_auto_deploy_external_scheduler`
exists for.

**Tools are not in `/usr/bin`.** On the host this was written from, `git` and
`docker` were in `/usr/local/bin` and only `curl` was in `/usr/bin`. The login `PATH` spans eleven
directories including `/usr/builtin` and `/opt`. The installer discovers each
tool and records its absolute path, so nothing needs to be configured, but a
missing tool fails the install with its name rather than a confusing error later.

**There is no `C.UTF-8` locale.** Ansible refuses to start unless
`locale.getlocale()` reports UTF-8, `LC_ALL=C.UTF-8` is rejected as an
unsupported locale setting, and `locale -a` prints nothing at all so it cannot be
used to find out what exists. `en_US.UTF-8` works. The installer probes
candidates with the real interpreter and records the first that succeeds.

**`/home` and `/volume1/home` are the same directory.** They share an inode
through a bind mount, so paths recorded by the installer under `/home/<account>`
and paths you type under `/volume1/home/<account>` reach the same files. This
looks like a misconfiguration and is not one.

## First installation

Run everything as the dedicated non-root deployment account.

Clone the controller. Keep it outside `/volume1/Docker/nas-platform`, which holds
service state rather than deployment source:

```sh
mkdir -p "$HOME/.local/share/nas-platform"
chmod 700 "$HOME/.local/share/nas-platform"
git clone https://github.com/yonatankarp/nas-platform.git "$HOME/.local/share/nas-platform/controller"
cd "$HOME/.local/share/nas-platform/controller"
```

Create the virtualenv the poller runs Ansible from. The installer refuses to
proceed without it:

```sh
python3 -m venv .venv
. .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r controller-requirements.txt
```

Place the credentials. The encrypted vault is committed, so every run reads it
from the checkout; only the password provider has to be placed by hand:

```sh
mkdir -p "$HOME/.config/nas-platform" && chmod 700 "$HOME/.config/nas-platform"
```

Copy the vault password file to `$HOME/.config/nas-platform/vault-password` and
`chmod 600` it, then confirm it opens the committed vault before going further:

```sh
ansible-vault view --vault-password-file "$HOME/.config/nas-platform/vault-password" inventory/group_vars/all/vault.yml | head -3
```

Export the environment. `inventory/local.yml` reads these through `lookup('env')`,
so they are required rather than convenient. `PLATFORM_PUBLIC_HOST` is the
address your devices use to reach published services. On a Tailscale network
that is the machine's tailnet domain name, not an address: ntfy hashes this value
into the topic it registers for mobile push, and the domain is what the devices
resolve. Setting it to a LAN or tailnet IP publishes to a topic nothing is
subscribed to, and nothing reports an error:

```sh
export PLATFORM_NAS_ADDRESS=<nas-lan-address>
export PLATFORM_PUBLIC_HOST=<nas-hostname>.<tailnet>.ts.net
export PLATFORM_CALLBACK_HOST=<nas-lan-address>
export PLATFORM_VAULT_PASSWORD_FILE="$HOME/.config/nas-platform/vault-password"
```

Install the collections for this first manual run, then validate, deploy and
verify by hand. Each must end `failed=0`. The poller installs its own copy of
the collections later, so this step is only for the manual runs:

```sh
ansible-galaxy collection install -r requirements.yml
```

Run `validate-vault.yml`, `site.yml`, and `verify.yml` with the tag list from the
[walkthrough](getting-started-nas.md#automatic-deployment-from-the-nas). Only
then install the poller, declaring that scheduling is external:

```sh
ansible-playbook -i inventory/local.yml install-production-auto-deploy.yml --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE" -e production_auto_deploy_vault_password_file="$PLATFORM_VAULT_PASSWORD_FILE" -e production_auto_deploy_external_scheduler=true
```

One flag covers both schedules. The weekly image prune this playbook also
installs runs as the same account from the same crond, so it takes its
scheduling mode from `production_auto_deploy_external_scheduler` rather than
needing a second declaration; `-e image_prune_external_scheduler=` overrides it
only if the two ever have to differ.

Then confirm the poller runs at all, before scheduling anything:

```sh
$HOME/.local/bin/nas-platform-deploy --status
```

## Scheduling from root

ADM has no task scheduler in its interface, so the entry goes in root's crontab
and drops back to the deployment account. Running the poller as root would leave
root-owned files under `/volume1/Docker` and the private state root, which then
break every later run as the account, so the `su` is not optional.

Confirm the invocation works before installing it, because BusyBox `su` differs
from the GNU one:

```sh
sudo su - <account> -c '/home/<account>/.local/bin/nas-platform-deploy --status'
```

Build the line, review it, then append it. Do this in separate commands: a
multi-line paste over SSH is easy to truncate into something that runs
partially:

```sh
printf '%s\n' "*/5 * * * * su - <account> -c '/home/<account>/.local/bin/nas-platform-deploy --poll' > /home/<account>/.local/share/nas-platform/logs/cron.out 2>&1" > /tmp/nas-cron.line
```

```sh
cat /tmp/nas-cron.line
```

```sh
sudo sh -c 'cat /tmp/nas-cron.line >> /usr/builtin/etc/crontabs/root'
```

```sh
sudo /etc/init.d/S41crond stop
```

```sh
sudo /etc/init.d/S41crond start
```

Output goes to a file rather than `/dev/null` because ADM has no local mail, so
a discarded stream would lose the poller's own warnings. A single `>` keeps it
bounded to the most recent run. The file ends up owned by `root`, because crond
performs the redirect before `su` drops privileges; it is harmless inside a
mode-0700 directory and log rotation ignores it.

### The weekly image prune

The same installer also installs a weekly Docker image prune, and on ADM it
needs a second root crontab line for exactly the same reason. Confirm it runs
before scheduling it:

```sh
sudo su - <account> -c '/home/<account>/.local/bin/nas-platform-prune --status'
```

Build the line, review it, then append it, in separate commands as above:

```sh
printf '%s\n' "0 4 * * 0 su - <account> -c '/home/<account>/.local/bin/nas-platform-prune --prune' > /home/<account>/.local/share/nas-platform/prune-logs/cron.out 2>&1" > /tmp/nas-prune.line
```

```sh
cat /tmp/nas-prune.line
```

```sh
sudo sh -c 'cat /tmp/nas-prune.line >> /usr/builtin/etc/crontabs/root'
```

Restart crond as above. The two entries share one account and one Docker daemon
but never overlap: the prune takes the poller's deployment lock for its whole
run, so whichever starts first makes the other wait or skip. The prune waits
fifteen minutes for a deployment and then leaves the work to the following
Sunday.

What each pass removes, and why the age filter is not what makes it safe, is in
the [physical NAS walkthrough](getting-started-nas.md#the-weekly-image-prune).

## Verifying a real cycle

The poller records an attempt before deploying, so the attempt count rising is
the signal that work has started:

```sh
watch -n 30 "$HOME/.local/bin/nas-platform-deploy --status"
```

`--status` also reports the current branch head and what the next poll would do,
so an idle poller can be told apart from a broken one without leaving the NAS:

```
last successful: <sha> at 2026-08-21T12:33:13Z
attempted revisions: 4
current main: <sha>
next poll: nothing to do: <sha> is deployed
```

The `next poll` line distinguishes the cases that otherwise all look like
silence: waiting on CI, a revision already attempted and quarantined with the
exact retry command, more than one successful run for the same commit, and a
branch or API that cannot be reached.

`logs/latest` is a symlink repointed at each attempt. Note that it survives a
failed attempt, so tailing it after a fix can show the previous failure and look
like the fix did nothing. Trust the attempt count, not the file's presence.

A successful cycle ends with `last successful: <sha>`, an ntfy notification, and
a mode-0600 log. Polling again should print nothing: a revision is attempted at
most once, which is what stops a broken deployment from repeating every five
minutes. Recovering one explicitly, while it is still the branch head:

```sh
$HOME/.local/bin/nas-platform-deploy --retry-failed <sha>
```

## After an ADM firmware update

Firmware updates are reported to overwrite `/usr/builtin/etc/crontabs/root`. The
loss is silent: deployments simply stop, the prune simply stops, and neither has
any way to know it is no longer being called. Check both after every update:

```sh
grep nas-platform- /usr/builtin/etc/crontabs/root
```

Two lines must come back, the five-minute `nas-platform-deploy --poll` and the
weekly `nas-platform-prune --prune`.

## Troubleshooting

`no eligible revision` on `--poll` means an error, not an idle poll. An idle poll
prints nothing. The usual cause is that `git` or the GitHub API could not be
reached with the poller's narrow environment; reproduce it with the recorded tool
path from `$HOME/.config/nas-platform/deployer.json`.

Silence with no deployment usually means the current branch head has no completed
successful `push` run of the CI workflow. Exactly one such run is required, so a
second run for the same commit makes that revision permanently ineligible without
reporting anything. Prefer re-running only failed jobs.

`crontab: must be suid to work properly` during installation means
`production_auto_deploy_external_scheduler=true` was omitted.

An assertion about `production_auto_deploy_public_host` during installation means
`PLATFORM_PUBLIC_HOST` was not exported in the shell that ran the playbook. The
role reads the same inventory variable every other role reads, so nothing has to
be passed twice; unset, it fails here rather than publishing to a push topic
nothing subscribes to.
