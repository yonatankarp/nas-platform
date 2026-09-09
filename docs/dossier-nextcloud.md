# Nextcloud dossier — the seventeenth service, and the first written to replace another

Derived from the images
[`services/nextcloud/compose.yml`](../services/nextcloud/compose.yml) pins — the
application and its cron sidecar share one, and a Postgres and a Valkey sit
beside them. The digests are not copied here on purpose: they move when Renovate
moves the deployment, and a copy in prose is a copy nothing bumps.

Read [the marker convention](service-dossiers.md#how-to-read-the-evidence-markers)
first: **Confirmed** was executed, **Inferred** was reasoned, **Unverified** was
not settled.

This is the second dossier written alongside an implementation rather than
before or after one, and the first written about a service intended to *replace*
a service this platform already runs. [Seafile](dossier-seafile.md) is the
incumbent, it was deployed days earlier, and #500's whole premise is that it
holds no user files yet — which makes the migration free now and a project
later. That premise is the reason this stack landed switched off: both file-sync
services are meant to run side by side while the choice between them is
evaluated with real files, and the teardown is deliberately a separate issue
that must not start until that evaluation has happened.

It records six slices — the service gated off, the CI lane and contract, the Mac
lifecycle proof, the app policy, the Renovate rule, and this file — and what
they found. One slice #500 asked for is **absent by decision**: there is no
pre-upgrade backup and no rehearsed restore. That is not an omission and the
section below states what it costs.

## Calibrate the evidence first, because it is stronger here than Seafile's

The Seafile dossier's most valuable paragraph is the one admitting its evidence
came from four places of unequal strength, and that the strongest of them —
a container the author could restart at will — was the smallest. **That is not
true of this file, and the difference should be used rather than assumed away.**

- **Throwaway stacks on the authoring machine.** The largest source here, and
  genuinely Confirmed. Nextcloud's stack runs on Docker Desktop, so the
  install path, the `occ` semantics, the app census, the trusted-domain
  reconciliation and the idempotence of every stage were exercised against real
  containers on the pinned digest. Seafile could not do this at all — its lane
  needs `chown` on bind mounts, which Docker Desktop ignores.
- **The CI `nextcloud` lane.** Real containers on a Linux runner. It is what
  proved the four-container stack converges, serves, and passes verification
  against a real database, and it is the only place the whole role has run end
  to end.
- **Reading `nextcloud:34.0.3-apache` itself** — `/entrypoint.sh`, the PHP under
  `lib/private/`, `core/shipped.json`, `core/Command/App/*`. Inferred, however
  precise.
- **Contract rows against stubbed `docker` and HTTP fixtures.** Not Confirmed,
  and marked where it appears. It covers the whole of the Mac coverage.

And the flat statement the rest of this file should be read against:
**as of this dossier, Nextcloud has never run on the NAS.**
`nextcloud_deployment_enabled` is `false` in
[`inventory/group_vars/all/main.yml`](../inventory/group_vars/all/main.yml), and
only the two disposable lanes turn it on — CI through a per-suite override, the
Mac lane through `-e` on its own `ansible-playbook`.

## The one thing the first converge fixes forever

Everything else on this platform is push-able or repairable. This is not, and it
is the finding that most justifies having investigated before deploying.

**Nextcloud's Postgres installer discards the database credentials it is
given.** `lib/private/Setup/PostgreSQL.php` checks whether the supplied user can
create roles, and if so sets `dbUser = 'oc_admin'`, generates its own random
password, and writes that pair into `config.php`:

```php
if ($canCreateRoles) {
    $this->dbUser = 'oc_admin';
    // Create a new password so we don't need to store the admin config in the config file
    $this->dbPassword = $this->generateDbPassword();
```

The official `postgres` image always grants `POSTGRES_USER` SUPERUSER, so
`canCreateRoles` is **always** true. Confirmed on a default install: `config.php`
held `dbuser => 'oc_admin'` with a generated password, and `\du` showed a second
role the vault had never heard of. A vault-authored database password would have
been dead on arrival — present in the environment, ignored by the installation,
and diverging silently.

`NC_setup_create_db_user: "false"` closes it. `AbstractDatabase::initialize()`
reads that setting and explicitly accepts the *string* `'false'`, because
"setting config values from env will result in a string". Confirmed on a fresh
stack with it set: `\du` showed only the vault's role, and `config.php` held
exactly the pushed credential.

**The part that makes this a landmine rather than a configuration detail is
timing.** `/entrypoint.sh` gates its whole init block on
`installed_version = 0.0.0.0`, read from `version.php`. On a converged
deployment none of it executes. So the variable must be right at the *first*
install; adding it later changes nothing, and recovery is manual — rewriting
`config.php` through `occ` and dropping the stray role. This is the same shape as
Seafile's `check_init_admin.py` acting only while the user table is empty, which
is what taught this platform to ask the question before the first converge rather
than after it.

## What is fixed at install, and what a converge can still push

Measured by rotating each value and recreating the stack, not read from
documentation. This table is the reason the role has the stages it has.

| Setting | Applied | Rotatable by a converge |
|---|---|---|
| `NEXTCLOUD_ADMIN_USER` / `_PASSWORD` | install only | **no** — `occ user:resetpassword` |
| `NEXTCLOUD_TRUSTED_DOMAINS` | install only | **no** — `occ config:system:set` |
| `POSTGRES_*` | install only; `config.php` is authoritative | **no** — push `NC_db*` |
| `OVERWRITE*`, `TRUSTED_PROXIES` | every start | yes |
| `REDIS_HOST*` | every start | yes |

The mechanism behind the right-hand column is worth stating, because it is what
makes a single-pass converge possible at all. `NC_`-prefixed environment
variables override any system config **on read** and are never written to disk —
`lib/private/Config.php` consults an environment cache before its file cache, and
`writeData()` serialises only the file cache. So pushing `NC_dbpassword`,
`NC_dbuser`, `NC_dbhost` and `NC_dbname` on every converge makes `config.php`
advisory and the vault authoritative, and rotation becomes an ordinary
environment change with no read-back.

**`NC_trusted_domains` is the exception, and it fails destructively.** Confirmed:
set to a space-separated string it makes `trusted_domains` a scalar, and *every*
request then answers **HTTP 400** — `/status.php` included, whatever `Host`
header it carries. An array-valued system setting cannot survive arriving as an
environment string. That is why the role reconciles the list with `occ` instead,
and why the compose file says so at the line that would otherwise invite the
shortcut.

## Verification proves the database link, not a port

`/status.php` requires `lib/base.php`, and booting builds the memcache factory,
which calls `AppConfig->getAppInstalledVersions()` — a database query. Confirmed
both ways:

| condition | `/status.php` |
|---|---|
| healthy | **200**, `{"installed":true,"maintenance":false,...}` |
| Postgres stopped, web up | **500**, zero-byte body, in 0.022 s |
| maintenance mode | **200**, `"maintenance":true` |
| `Host` not in `trusted_domains` | **400** |

So a `uri` with `status_code: 200` plus an assert on `installed`, `maintenance`
and `needsDbUpgrade` fails exactly where a port check or an Apache-only probe
would pass. #445 established the rule that verification must prove the link; this
is the cheapest endpoint on this platform that satisfies it, and it needs no
credential.

## Four containers, and why the fourth is not optional

The application, a cron sidecar on the **same image** and the **same**
`/var/www/html` volume, Postgres, and Valkey.

Nextcloud needs a background job runner, and the AJAX default fires only on a
browser request — on an idle instance, never. This platform manages no host
timers, so the runner has to be a container. The image ships `/cron.sh`
(`exec busybox crond -f -L /dev/stdout`) and a `www-data` crontab running
`php -f /var/www/html/cron.php` every five minutes; `entrypoint: /cron.sh`
replaces the installing entrypoint, so the sidecar runs no install or upgrade
logic of its own.

The shared volume is a correctness requirement rather than an optimisation, and
`compose.mac.yml` names the failure: a `!override` that replaces the volume list
instead of extending it would leave the sidecar with its own empty
`/var/www/html` and a crontab running `cron.php` against an installation that is
not there.

**The Postgres mount is `/var/lib/postgresql`, not `/var/lib/postgresql/data`,
and the difference is a data-loss shape rather than a preference.** The image
declares `PGDATA=/var/lib/postgresql/18/docker` and a `VOLUME` at
`/var/lib/postgresql`; mounting one level deeper — correct for PG ≤ 17, which
[`services/immich/compose.yml`](../services/immich/compose.yml) still does on its
pinned 14 — puts the cluster where the bind mount does not reach.
[`services/paperless-ngx/compose.yml`](../services/paperless-ngx/compose.yml) is
the precedent that had already solved it, and its mode is `0755` rather than
`0700` for the same reason: PG18 creates its own versioned directory beneath the
mount at `0700`, so the parent must stay traversable after the entrypoint drops
privileges.

## A Jinja escape that made a reconciler run forever

This one is worth the whole section, because it is a defect class this
repository has now been bitten by twice and the second bite was not caught by
anything the first added.

`roles/nextcloud/tasks/reconcile_trusted_domains.yml` read the live domain list
and appended what was missing. It appended **everything, on every converge**.
CI's second run reported `changed=1` with all three domains re-added, which is
what caught it — the integration lane's idempotence property, not any static
check.

The cause:

```
split('\n')  -> ['127.0.0.1\nlocalhost\n172.17.0.1']   count=1
splitlines() -> count=3
```

**Inside a Jinja `{{ }}` expression, `'\n'` is two literal characters.**
`AnsibleLexer` pre-escapes every backslash in an expression's string constants —
which is exactly what makes `regex_replace('^(.*)_x$', '\1')` a backreference
here rather than a control character — so the split never split, the live list
parsed as one blob, and `difference` reported every managed domain missing.

Two things about this are easy to get wrong and were, in this issue's own
history. **Quote style is irrelevant**: folded, single-quoted and double-quoted
all behave identically; only a `{% %}` statement unescapes. And plain Jinja 3.1.6
*does* unescape, so this is Ansible-specific and cannot be reproduced in a bare
Jinja console. Confirmed by measuring all four forms.

`.splitlines()` is the house pattern —
[`roles/trailarr/tasks/reconcile_env.yml`](../roles/trailarr/tasks/reconcile_env.yml)
already used it — and `tests/contracts/nextcloud-static.rb` now scans every
`{{ }}` region of the role's task files for Python escape sequences. That guard
had a real subject when it was written, which distinguishes it from the
`{% raw %}` guard beside it: that one is carried deliberately with **no subject
in this role today**, and says so, rather than letting a green check imply
coverage it does not have.

The kinship with #492 is the point. There, a `{% raw %}` inside a `{{ }}` was a
string literal rather than a tag, reached `docker --format` verbatim, and made a
backup classifier report `stack-not-running` against a serving stack — with a
clean `PLAY RECAP` and no error. Both are Jinja expressions that are silently
*wrong* rather than failing, and both produced a converge that reported success
while doing the wrong thing.

## The app policy, and the question it closes

Nextcloud ships 56 apps and enables 50 on a fresh install; 14 of those are
`alwaysEnabled` and cannot be disabled at all. Confirmed against
`core/shipped.json` and by asking the running server.

[`roles/nextcloud/defaults/main.yml`](../roles/nextcloud/defaults/main.yml)
declares an **off-set** and nothing else. The reasoning per entry lives beside
each name; what matters here is the shape of the argument:

- **One entry is derived** from #500's own scope — `photos`, because Immich is
  this platform's photo service. It is the only shipped app that overlaps an
  existing service; nothing shipped does OCR, document management or media
  transcoding, so there is no Paperless or Jellyfin overlap to act on.
- **Two follow a principle stated elsewhere in this repository** —
  `updatenotification` and `survey_client`, against
  [`roles/immich/defaults/main.yml`](../roles/immich/defaults/main.yml)'s "The
  NAS is not permitted to phone home for release announcements". Every
  notification the first raises is about an upgrade an operator here cannot
  perform in band, because the digest pin is the only upgrade path.
- **Five are judgement**, and are labelled as such so a later reader can
  overrule them without unpicking the two that are not taste.

**`text` deliberately stays on.** Collaborative document editing is one of the
three features #500 names as the *reason* to adopt Nextcloud, and Paperless is
archival OCR rather than editing, so there is no overlap. An assertion in the
contract forbids its addition to the off-set, because it is the entry a later
prune would most plausibly reach for.

**There is no on-set, and that is deliberate.** Re-asserting an off-set repairs a
hand-disable in the web UI and a reinstalled volume, which is this platform's
whole model. Declaring an on-set would mean copying ~38 app names out of the
image's own `defaultEnabled` — a value restated in prose that nothing bumps —
and fighting the image on every version bump that adds or removes one.

### The stated reason for re-asserting was wrong, and the shape is still right

An early draft justified re-assertion by claiming `occ upgrade` can re-enable a
disabled app. **It cannot.** `lib/private/Installer.php`'s `installShippedApps()`
touches an app only when its `installed_version` is empty *and* its `enabled` is
not `no` — a disabled shipped app fails both — and `lib/private/Updater.php`
re-enables only `getAutoDisabledApps()`, populated solely by
`disableApp($id, true)`, while `core/Command/App/Disable.php` calls it with one
argument. Inferred, from reading the image.

Worth recording because the correction did not change the design: re-asserting
every converge is right for the reasons above, and the justification simply named
a mechanism that does not exist. A comment that argues from a false premise
survives review exactly as well as one that argues from a true one.

### Whether app versions can be pinned: no

`occ app:install` takes one argument, `app-id`, and three flags —
`--keep-disabled`, `--force`, `--allow-unstable`. There is no version argument,
and the installer resolves the newest appstore release compatible with the
server. Confirmed by reading `core/Command/App/Install.php` and by running
`occ app:install --help`.

So #500's question — "whether their versions are pinned at all" — has a definite
answer. **Shipped apps are pinned by the image digest and by nothing else;
third-party apps cannot be pinned through `occ` at all.** That is the argument
for restricting this stack to shipped apps: an appstore install would reach
`apps.nextcloud.com` at converge time, land an unpinnable version into
`custom_apps` on the persistent volume, and own its upgrade path across image
bumps — which is unmanaged configuration of exactly the kind this repository
exists to prevent.

### One trap in the disable path

`occ app:disable` on an `alwaysEnabled` app exits **2** with its message on
**stdout**, not stderr. Confirmed: `dav can't be disabled.`, `rc=2`, empty
stderr. And `community.docker.docker_compose_v2_exec` **does not fail on a
nonzero exit code** — it sets `check_rc` only when `detach` is true — so without
an explicit `failed_when` the module reports success, `changed_when` evaluates
true, and the stage claims a change it did not make on every five-minute poller
tick behind a clean `PLAY RECAP`. The same assumption is filed against
`reconcile_admin.yml` as its own issue.

## There is no pre-upgrade backup, and what that costs

#500 dropped it deliberately: the server holds no user files, so a rebuild costs
minutes and a backup would protect nothing. Recorded here rather than left as an
unticked box, because the absence is a decision and reads as an oversight
otherwise.

What it costs, stated plainly. `/entrypoint.sh` runs `occ upgrade` **itself** on
any version increase, unattended, at container start. That migration is one-way;
the same entrypoint refuses to start once the volume's `version.php` is newer
than the image's. So there is nothing to go back to: reverting the merge does not
restore the service, it keeps the stack down until the pin goes forward again.

[`renovate.json`](../renovate.json) holds Nextcloud **majors** behind
`dependencyDashboardApproval` for that reason — the pull request is withheld
until a human ticks the box, rather than merely labelled. Note what is *not* the
reason: the entrypoint's refusal to skip a major is nested under
`installed_version != 0.0.0.0`, so a volume with no `version.php` — which is what
a gated-off stack has — takes the fresh-install path and installs cleanly at
whatever major is pinned. That refusal binds an installed volume only.

**And the open consequence, which this dossier names rather than resolves.**
Minors and patches still automerge, and `version_greater` sends *every* version
increase through that same unattended one-way `occ upgrade`; the production
poller converges the newest released `main` within five minutes. Dropping the
backup made minors irreversible too, not only majors. That matches how Seafile is
treated and it was inherited rather than chosen, which is precisely why it
deserves a deliberate decision the day this stack holds files somebody would
miss. Unverified: whether any minor has ever needed a rollback here.

## Seafile compared, honestly

#500's case for preferring Nextcloud is not about sync quality, and the issue
concedes the point that matters most: **Seafile is better at sync.** That is not
in dispute and should not be quietly dropped from the comparison.

What the comparison actually rests on:

- **Files are plain files.** Nextcloud's data tree can be read with `ls` and `cp`
  whatever state the database is in. Seafile stores content-addressed blocks
  under `seafile-data/storage` with the mapping in the database, so losing the
  database makes the blocks unreadable. That risk is *mitigated* there —
  `recovery: critical`, dump-before-blocks ordering, a backup that refuses the
  upgrade when it fails, a rehearsed restore — but Nextcloud does not have it at
  all. Which is also why dropping the backup here is a smaller decision than
  dropping Seafile's would have been.
- **Postgres rather than MariaDB.** `immich` and `paperless-ngx` already run
  Postgres, so this stack inherits an established pinning pattern and reuses
  paperless's exact image and digest. Seafile's MariaDB is the platform's only
  one, and it was forced rather than chosen — Seafile has no Postgres backend.
- **`trusted_domains` is a list.** Seafile derives one `SERVICE_URL` and one
  `FILE_SERVER_ROOT` from a single hostname on every start, so reaching the NAS
  over both a mesh VPN and the LAN means one value serving both. Nextcloud
  accepts several natively.

The counterweight beyond sync: Nextcloud's install-only settings are a larger
surface than Seafile's, and the `oc_admin` landmine has no Seafile equivalent.
The platform's answer is the same in both cases — establish what is one-shot
before the first converge — and this stack needed more of that answer, not less.

## What remains unsettled

- **No line of the Mac coverage has ever executed.** `tests/mac/run.sh` needs
  hours and a real Docker Desktop, and **no CI job runs it**. The four hooks the
  Mac slice added — verify, persistence, recreate, and a drift hook with its own
  mutation — are proved only in the sense that their dispatch tables, rosters,
  pinned counts and review documents agree. The drift mutation has never touched
  a live container and the recreate row has never rebuilt four containers. Only
  an operator's `run.sh --lane fresh` proves any of it.
- **The drift hook proves re-addition, not reversion**, and is the only hook in
  its group that does. `reconcile_trusted_domains` never removes an entry —
  an operator's hand-added domain is not drift this role can distinguish from a
  deliberate addition — so a planted `nextcloud-drift.invalid` **survives** the
  converge while the platform's own `127.0.0.1` is re-added. Every sibling hook
  proves the planted edit is undone. Worth knowing before reading it as parity.
- **The drift hook accepts either of two diagnostics**, because removing
  `127.0.0.1` also makes `/status.php` answer 400 if the image gates it, so the
  readiness refusal may fire before the trusted-domain one. What excludes a
  container that never started is neither message but the four-container health
  census that runs before both. Unverified: which branch a real run takes.
- **`occ config:system:delete` leaves PHP's array sparse.** Measured: on a dense
  array of four, deleting index 1 makes `get` print three while index 3 is still
  live, so a later converge would write a managed domain over it. Nothing this
  role does creates such a gap, so it is recorded rather than guarded.
- **The 300-second `start_period` has been measured on CI hardware but not on
  the NAS.** The AS6704T's Celeron N5105 at a 2.0-CPU ceiling is slower than a
  GitHub runner, and first install rsyncs the whole PHP tree into the volume
  before installing. Unverified.
- **Whether the cron sidecar's five-minute schedule is right for this
  deployment.** It is the image's default. Nothing here has measured what
  Nextcloud's background jobs cost on this hardware.
- **There is no TLS**, as everywhere else on this platform, and Nextcloud raises
  the stakes the same way Seafile did: it is the second service whose login
  guards the operator's own files. The Seafile dossier's paragraph on this is not
  restated here because nothing about it changed — a platform decision is owed,
  and adopting a reverse proxy for one service leaves the rest where they are.
- **The evaluation #500 exists for has not happened.** The stack has never run on
  the NAS, no real file has been put into it, and the teardown issue must not be
  opened until it has. This dossier records what building the service found; it
  does not record whether the service is better, and nothing here should be read
  as having answered that.
