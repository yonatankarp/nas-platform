# Seafile dossier — the sixteenth service, written alongside its implementation

Derived from the three images
[`services/seafile/compose.yml`](../services/seafile/compose.yml) pins, which
move when Renovate moves the deployment:

```
docker.io/seafileltd/seafile-pro-mc:13.0.27@sha256:021127a3b98d39665cad335d165f7c28748d28441898bb01c169cecb8a8f9d70
docker.io/library/mariadb:10.11.19@sha256:ce66c7be32a03aabe7241d0a10993a2db827ef652a35d25727d92a832ac8ef73
docker.io/valkey/valkey:9.1.2-alpine@sha256:a0dbf4c1d5708782907c10e2c72deff317518518b5288a58416981d9db95d30b
```

Read [the marker convention](service-dossiers.md#how-to-read-the-evidence-markers)
first: **Confirmed** was executed, **Inferred** was reasoned, **Unverified** was
not settled.

This is a different kind of document from the six beside it. Those were written
either before a promotion, to decide one, or after a promotion, to name what the
running application holds that Ansible does not own. This one was written
alongside an implementation that landed in five slices — #460 the service gated
off, #477 the CI lane and contract, #492 the pre-upgrade backup and rehearsed
restore, #495 the Mac lifecycle proof, #496 quota, audit log and the disk alert —
and it records what those five found: what surprised us, where the image
contradicts its own documentation, and which decisions were forced rather than
chosen.

**Calibrate the markers before reading, because this dossier's evidence came
from four places of unequal strength and the other six drew on one.** Every other
dossier's Confirmed claims were requests issued against a container the author
ran on a workstation. Only the last of the four below is that, and it is the
smallest of them here. The difference is load-bearing:

- **The CI `seafile` lane.** Real containers, a real Docker socket, a Linux
  runner. This is genuinely Confirmed and it is where every runtime number below
  comes from — but nobody can reproduce it at a shell, so the run is named
  instead. Two are cited throughout: `13a00da`, which passed, and `e727d80`,
  which wedged.
- **Contract rows against stubbed `docker` and HTTP fixtures.** This is **not**
  Confirmed and is marked wherever it appears. It covers the wedged-boot
  recovery, the restore rehearsal's first authoring pass, and the whole of the
  Mac coverage.
- **Reading `seafileltd/seafile-pro-mc:13.0.27` itself.** Inferred, however
  precise — parts of it were taken at instruction level out of a compiled
  `seaf-server`, and it is still reading.
- **Measurements taken on the authoring machine against a single container**, not
  against the stack — the authoring machine cannot run this stack at all, because
  Docker Desktop ignores `chown` on bind mounts. What it can measure is what one
  image does with one argument: how `docker inspect` reports a field, what
  `mariadb-dump` does with an option it rejects. Those bullets name the image and
  the Docker version where they appear.

And the flat statement the rest of this file should be read against, scoped to
when it was written because it is expected to stop being true:
**as of this dossier, Seafile has never run on the NAS.**
`seafile_deployment_enabled` was `false` in
[`inventory/group_vars/all/main.yml`](../inventory/group_vars/all/main.yml)
through all five slices, and nothing but the two disposable lanes turned it on —
the CI `seafile` suite through a per-suite override, the Mac lane through `-e` on
its own `ansible-playbook`. The flip is deliberately its own change, and the
change immediately after this one: the first converge permanently fixes
credentials no later converge can move, which is why it is worth watching rather
than merging and walking away from.

Read every "has never executed" in this file against that date rather than
against the tree you are holding. **The one that does not expire is the
distinction itself** — the lane, the stub and the image are three different
strengths of evidence whatever the flag says, and a converge on the NAS upgrades
some of these claims without touching the rest. What it upgrades first is
narrower than it looks: a single converge exercises the boot path, the
credential probe and the verification, and it exercises neither the wedged-boot
recovery nor the forced backup, because both need a failure or a flag that a
routine converge does not supply.

## Three decisions that were forced rather than chosen

**MariaDB, because Seafile has no PostgreSQL backend.** Both existing
multi-container stacks here run Postgres — `immich` and `paperless-ngx` — so
this is the platform's first and only MariaDB, and it inherits none of their
shape. Confirmed by reading the three Compose files: `mariadb:10.11.19` is the
only non-Postgres database image in the repository. The cost is not one dump
verb versus another. It is that a second engine arrives with its own upgrade
semantics (`MARIADB_AUTO_UPGRADE=1` migrates the datadir **in place**, before the
health check goes green, which is why the backup below runs before *both* Compose
phases rather than between them), its own health command
(`healthcheck.sh --connect --mariadbupgrade --innodb_initialized`, taken verbatim
from upstream so the check stays red through an in-place upgrade), and its own
Renovate exposure.

That last one had already gone wrong before Seafile arrived, and the arrival is
what found it. `renovate.json`'s rule holding database majors back from automerge
named `postgres` and `valkey` **by name**, against a package list nothing
compared to the Compose files — so a MariaDB major would have ridden routine
automerge into `main`. Fixed in #460, and `docker.io/library/mariadb` is the
third name in that rule today. A rule that enumerates its subjects is a rule that
silently stops covering the next one, and nothing here compares the enumeration
to the tree.

**Pro edition, because it costs nothing at this size and the audit log is a
requirement.** Seafile Professional is free to three users and needs no license
file at that size, and since v12.0 upstream publishes the Pro images on Docker
Hub. That second half is what made the decision cheap: earlier versions sat
behind `docker.seadrive.org` with Customer Center credentials, and some of
Seafile's own pages still document that flow, so the alternative was
authenticated pulls in every CI lane, Renovate host rules, and a `docker login`
on the NAS that Ansible would have had to own. Confirmed in #460, and confirmed
in the stronger form: an anonymous registry token against `registry-1.docker.io`
rather than a successful `docker pull`, which on a machine that has pulled the
image before proves nothing.

**The three-user cap is a hard ceiling, counted on activated accounts.** Above
it, Pro is a paid subscription, and the alternative at user four is either paying
or migrating to CE and losing the audit log this edition was chosen for. Worth
being sure three is genuinely enough before building further on it. One related
thing is worth writing down so nobody later reads it as an incident: a missing or
unreadable license degrades Seafile to "trailer mode", capped at three users — at
this size indistinguishable from normal operation, so there is no cliff to
monitor and the phrase in a log means nothing here.

## What the documentation says, and what the image does

This is the richest section. Every item in it was checked against the image, the
manual or the running stack rather than assumed, and each carries the marker that
says which of the three. Several of them contradict #445's own premises, which is
the point of writing them down.

### The tag the issue named has no stable sibling

#445 proposed `seafileltd/seafile-pro-mc:14.0.6-testing` and said "pick a stable
tag, not `-testing`". There is none: **14.x is testing-only, and no stable 14.0.x
has ever been published.** 13.0.27 is the stable head and is what
`services/seafile/compose.yml` pins. Recorded in #460 against the tag list at the
time; a reader checking it again should check the tag list again, because this is
the one finding here that a single upstream release retires.

### "Seafile cannot skip major versions" is documented nowhere, and the image contradicts it

The claim appears in #445 as the reason Seafile needs an Immich-style
non-automerge rule. It could not be found in Seafile's documentation, and
`/scripts/upgrade.py` inside the image does the opposite of what it asserts: it
collects every intervening migration script and runs them in order, down to 6.0.
Inferred — read out of the image, not exercised by an actual multi-major upgrade.

**The Renovate exception is still right, and its stated reason was wrong.** A
Seafile series change needs out-of-band steps a digest bump cannot perform —
re-fetching upstream's `seafile-server.yml` for the new series, changing
`COMPOSE_FILE` to match it, hand-editing `seafile.conf` and `seahub_settings.py`
inside the volume — and the migrations are one-way with no documented downgrade.
The rule's `description` now says that, and says out loud what is *not* the
reason, which matters because the next person to revisit the exception will read
the reason and not the rule. An exception whose reason is wrong survives exactly
until somebody checks the reason.

Where that rule's scope falls was read out of the image rather than assumed, and
it is not where Renovate's vocabulary would put it. `/scripts/upgrade.py` decides
with `is_minor_upgrade`, which compares only the **first two** components of the
version, so 13.0.27 → 13.0.28 is Seafile-minor — the container runs
`upgrade/minor-upgrade.sh` itself on the next start, symlink and avatar
housekeeping, nothing for an operator to do — and is a Renovate *patch*, which
falls through to routine automerge where it belongs. 13.0 → 13.1 takes
`upgrade.py`'s major branch and needs `upgrade_13.0_13.1.sh` and every manual
step above, and is a Renovate *minor*. So the exception covers minor as well as
major, because Seafile's own terminology inverts Renovate's. Inferred, from the
image.

### `vm.max_map_count` was probably never necessary, and requiring it would have been harmful

#445 made a host sysctl a definition-of-done item and called its persistence
across an ADM firmware update "the part that bites". Three separate findings
retire it, all Inferred:

- Elasticsearch skips `MaxMapCountCheck` outright when
  `node.store.allow_mmap=false`, so the requirement is conditional on a
  configuration nobody had chosen yet.
- The check fires in the CI sandbox and on the Mac as much as on the NAS. A pull
  request whose correctness depended on a **host** sysctl could therefore never
  have had a green integration lane — the harness runs against a disposable
  sandbox, not a host it is allowed to reconfigure. That is not a Seafile fact;
  it is a statement about what this repository can prove, and it is the reason to
  notice a host-level requirement early rather than at the first red lane.
- `vm.max_map_count` has never been namespaced — a global `int` in `mm/util.c`,
  traced v5.15 to master — and runc's allowlist never included `vm.*`, so there
  is no container-side route at any kernel version and ADM's kernel is
  irrelevant. Separately, ADM's `/etc` is a ramdisk rebuilt every boot, so
  `/etc/sysctl.conf` was dead on arrival; the hook that survives is
  `/usr/local/etc/init.d/SXXname.sh`.

Two smaller corrections in the same area, both Inferred and both recorded so
whoever picks up #497 does not re-derive them. The image to use is stock
`elasticsearch:8.15.0` — `seafileltd/elasticsearch-with-ik` is historical, and
Seafile 13.0's own `.env` pins the upstream one. And `discovery.type=single-node`
**downgrades** bootstrap failures to warnings rather than skipping them, so
upstream's own compose file starts while logging a failure on every boot for
ever. `pro-data/search` is a relic in this version: 13.0.27 ships no Java and no
bundled Elasticsearch, which dissolves what would otherwise have been a
`recovery: cache` subtree living inside a `recovery: critical` root.

### The MariaDB `unix_socket` hazard does not exist for this image

MariaDB's `unix_socket` plugin authorises `root@localhost` by the connecting
process's uid and ignores the password entirely, so a credential probe over the
container's socket would report success whatever the vault said. Three files in
this repository justified the TCP probe partly on that claim, and it is wrong
here: against `docker.io/library/mariadb:10.11.19`,
[`tests/contracts/seafile-runtime.rb`](../tests/contracts/seafile-runtime.rb)
measured the socket **refusing** a password nothing wrote. Confirmed in the
`seafile` lane. The plugin default is Debian and Ubuntu packaging rather than a
property of the upstream image.

The three comments were corrected and the probe was not moved, because TCP is
right for the other reason it was always right for: addressing the service by
name forces the connection through the network stack, where only `root@%` — the
account MariaDB's own entrypoint creates with `CREATE USER ... IDENTIFIED BY` —
can answer, and only a matching password gets in. The contract **reports** the
socket measurement rather than asserting it, deliberately: it is upstream's
behaviour, not this repository's, and failing a lane on it would fail for
something nobody here controls.

### The administrator password is first-run-only, with no push path at all

`/scripts/start.py` writes `conf/admin.txt` from `INIT_SEAFILE_ADMIN_EMAIL` and
`INIT_SEAFILE_ADMIN_PASSWORD` on **every** container start, but
`check_init_admin.py` consumes that file only when `need_create_admin()` is true
— that is, only while the user table is empty. So rotating
`vault_seafile_admin_password` and converging is a silent no-op for as long as
the account exists, and the documented remedy, `reset-admin.sh`, is interactive
and cannot be driven from a play. Inferred from the image; the consequence is
Confirmed, because the lane authenticates as exactly that pair.

This collides head-on with what [`CLAUDE.md`](../CLAUDE.md) promises — every
credential authored in the vault and pushed outward, configuration changed by
hand reverted by the next run — and the role does not paper over it. It pushes
the credential once and then **proves** it:
[`roles/seafile/tasks/verify.yml`](../roles/seafile/tasks/verify.yml)
authenticates against `POST /api2/auth-token/` and fails naming both causes, so
drift is loud at verification time rather than silently "reconciled". That
endpoint choice is itself a finding: `GET /api2/ping/` returns a constant from a
view that touches nothing and answers just as happily with both databases down,
and `GET /accounts/login/` reads `constance_config` from cache, so on a warm
cache it proves only that Valkey is up. `POST /api2/auth-token/` is the one
endpoint on the unauthenticated surface that cannot answer without the
databases: it authenticates against `ccnet_db` and `seahub_db` and then
get-or-creates a token row in `seahub_db`.

The other half of `conf/admin.txt` is a security-boundary fact. The file
materialises the administrator password in plaintext inside the bind-mounted
volume on every start and is removed in a `finally:`, so a container killed
mid-start leaves it on disk. `CLAUDE.md` names Seafile's whole `conf/` directory
for that reason, the pre-upgrade backup excludes `admin.txt` **by name** rather
than by luck, and finding it during a backup is reported rather than deleted —
because a start in progress writes exactly that file, and a play racing it would
be removing the file the server is about to read.

### `[quota] default` looks dead to a byte-level search, and is what every account resolves to

The first implementation of the quota concluded the key was dead in 13.0.27 and
shipped a `seahub_settings.py` role quota instead. That was wrong, and the
mistake is easy enough to repeat that it belongs here: **a byte-level search of
the image for `"default"` finds nothing, because the literal exists only as the
tail of `is-default`.** Following the reference out of the user-quota resolver
settles it. Read out of `quota-mgr.c` at instruction level — Inferred, and about
as strong as Inferred gets:

```
SELECT quota FROM UserQuota WHERE "user"=?   →   returned if positive or -2
SELECT quota FROM RoleQuota  WHERE role=?    →   returned if positive or -2
                                             →   [quota] default in seafile.conf
```

The platform sets neither of the first two, so the third is what every account
resolves to, and it is the only one of the three a converge can push. The role
quota was rejected on evidence rather than preference: every `set_role_quota`
call site in the image is a **login** path — the web form, the remote-user and
Shibboleth backends, the OAuth and ADFS handlers — and none of them is the path
`POST /api2/auth-token/` takes. A quota declared there would not exist until
somebody signed into the web interface, which is the "works when a human happens
to have logged in" behaviour this repository exists to avoid.

**A wrong spelling makes seaf-server fall back to unlimited.** Its parser takes a
decimal number and an optional `k/kb/m/mb/g/gb/t/tb` suffix, a bare number means
gigabytes, and a value it cannot parse is not an error: it logs
`Invalid default quota` and grants no quota at all. A mistyped quota is a silent
no-quota, which is precisely the failure the setting exists to prevent, so
`reconcile_quota.yml` refuses a spelling matching `^[0-9]+([kmgt]b?)?$` before
the run reaches the target. `20g` is the shipped value, chosen from asymmetry
rather than measurement — raising a quota is free, lowering one below existing
usage strands a user with data the platform cannot delete — and three users cap
the worst case at 60 GB.

### There is no configurable audit retention, and `enabled` is not a unique key

`[AUDIT] enabled = true` is what pro.py's first-run template writes, so the
audit log is on today by coincidence of an upstream default. The platform owns
the key anyway, because `is_audit_enabled` and `init_message_handlers` both fall
through to `False` on a **missing** key — an image that stopped writing it would
switch auditing off silently and nothing here would notice.

Retention is not a decision this image offers. The only cleanup is
`clean_db_records`, whose 90-day cutoff is hardcoded in its SQL, and nothing in
the image invokes it — grep scope `/opt/seafile`, `/scripts` and `/etc`, stated
as that scope rather than as "anywhere". It is deliberately not scheduled here,
because it also deletes `FileTrash`, `FileHistory` and `Activity` rows: a
different decision about different data, which should be taken on its own rather
than as a side effect of wanting audit retention. Records stay in `seahub_db`
(`FileAudit`, `FileUpdate`, `PermAudit`) and are surfaced to no channel.

The trap beside it is worth more than the setting. **`enabled` appears under
every one of the five sections** pro.py's template generates — `[SEAHUB EMAIL]`,
`[STATISTICS]` (written `enabled=true`, no spaces), `[AUDIT]`, `[INDEX FILES]`
and `[FILE HISTORY]` — so a transform that rewrites `enabled` per line switches
off four features to change one and reports itself converged having done it. That
is not hypothetical: it is what the line-scoped first draft of this
reconciliation did to the audit log, the feature the Pro edition was chosen for.
The repair is now driven by a declared list of `(section, key, value)` with every
pattern built from `item.section`, which makes a line-scoped repair unreachable
by construction rather than merely avoided. Rehearsed under real
`ansible-playbook` against pro.py's own generated template: `[AUDIT]` false→true,
`[INDEX FILES]` true→false, and the other three byte-identical.

One related question was genuinely open until CI answered it. `[INDEX FILES]` is
written by `pro.py setup`, reachable only through `init_seafile_server()`, which
returns early once `seafile-data` exists — so the server does not rewrite it on
every start and repair-then-restart converges rather than flapping for ever. That
was a derivation when #460 shipped and is **Confirmed** by the `seafile` lane,
which is the strongest single reason the lane was worth building: had it gone the
other way, the platform's hard idempotence requirement would have been broken by
construction.

## The block store and the database are one artifact

#445 called this the single most important thing to get right, and it is the
constraint the whole backup story is shaped by. Seafile stores content as
content-addressed blocks under `seafile-data/storage`; the mapping from blocks to
filenames, libraries and owners lives in the database and nowhere else. **A
filesystem copy taken without a database dump consistent with it restores an
unreadable pile of blocks.** Both trees are `recovery: critical` in `nas_storage`
for that reason, together rather than separately, and the primary artifact here
is the user's own documents — not metadata that could be re-fetched, which is
what every other stack's critical state amounts to.

Three consequences follow, and only the first two are settled.

**The dump comes first, and the argument runs in both directions.** A filesystem
half taken *before* the dump can only be missing blocks the dump then names,
which restores as a library whose files cannot be read. Taken *after*, the
filesystem half is a superset of what the dump names and the surplus is merely
unreferenced. Seafile's own manual states the same order for the same reason, and
[`tests/contracts/seafile-static.rb`](../tests/contracts/seafile-static.rb) pins
it by task index so the ordering cannot drift into a comment.

**The service is not stopped.** `--single-transaction` gives the dump a
consistent InnoDB snapshot, so the three schemas are consistent with each other
and with the store as of that instant while seahub keeps serving. A backup that
required an outage is a backup nobody takes.

**The pre-upgrade backup deliberately does not copy the block store, and that
boundary was never measured.** The argument is that an upgrade migrates schemas
and rewrites `conf/`; it does not rewrite immutable content-addressed blocks, and
copying the users' whole library on every Renovate digest bump is an outage
rather than a safeguard. The full DB-first-then-blocks procedure, with the
`pro-data/search`, `logs/` and `conf/admin.txt` exclusions, lives in
[Recover Seafile](getting-started-nas.md#recover-seafile) and is named by every
backup's own manifest. **This rests on reading the storage model, not on watching
a real major upgrade.** It is the one claim in #492 that could not be tested, and
if it is wrong the boundary is wrong — not the implementation of it.

Four things in this area were established by measurement rather than argued, and
each of them changed the code. All four were measured on the authoring machine
against a single container rather than in the lane, which is the weaker of the
two Confirmed strengths this file uses and is why each says which image and which
Docker:

- **`.Config.Image` on a Compose-created container is byte-identical to the
  digest-pinned `image:` key**, digest included. `.Image` and the
  `com.docker.compose.image` label both report the image *ID*. Had the upgrade
  classifier read either of those, every converge would have found a difference,
  taken a backup and reported `changed` — and the platform's idempotence check
  would have failed on the second run of a stack nobody had touched. Confirmed
  against Docker 29.7.2.
- **`mariadb-dump` in `mariadb:10.11.19` rejects `--connect-timeout`, and creates
  an empty result file before refusing it.** That is why the guard asserts on the
  file existing and being non-empty rather than on the exit status. Confirmed.
- **A database-level `GRANT` survives `DROP DATABASE`** on that image and works
  again after a restore, which is why the documented procedure has two cases and
  only the datadir-loss one recreates the Seafile account. Confirmed.
- **`--databases` dumps carry `CREATE DATABASE` and `USE`**, so a restore
  recreates schemas that were dropped. Confirmed.

The restore rehearsal that runs in the `seafile` lane is worth one note of its
own, because the shape generalises. It drops the three databases and **asserts
the server stops issuing administrator tokens** before restoring anything.
Without that negative control every later assertion in the sequence is about a
server that was working the whole time, and would pass against a restore that did
nothing at all.

## The boot wedge

The most important operational finding, and the one that is not about Seafile's
API at all. **Seafile's own image can boot into a state nothing recovers from.**

`/scripts/enterpoint.sh` launches `/scripts/start.py` in the background and then
idles in `while [ 1 ]; do sleep 60 & wait $!; done` for ever. Nothing in that
loop ever looks at `start.py` again, so a `start.py` that stops making progress
leaves PID 1 perfectly happy. Two routes reach it, and from outside they are
identical: `utils.call` defaults to `subprocess.check_call`, so anything raising
inside `init_seafile_server()` ends `start.py` outright; and `wait_for_mysql()`
and `wait_for_nginx()` are unbounded `while True` loops with `time.sleep(2)` and
no attempt limit, so it can equally still be alive and stuck. Inferred from the
image. Either way the container reports `State: running`, `ExitCode: 0`, and
never serves.

The health check reports this correctly, and that too was measured rather than
assumed. nginx is listening on 80 for the whole boot — `enterpoint.sh` blocks
until it appears in the process table before launching `start.py` at all — so
there is a listener that is not the application. It is still not a port check:
the bundled site proxies `/` to gunicorn on `127.0.0.1:8000`, so before seahub
binds, nginx answers **502** and `curl --fail` turns that into a failure.
Confirmed against 13.0.27 with the database host pointed at a name that does not
resolve, so `start.py` stayed in `wait_for_mysql()` and seahub never started: `/`
returned 502 and the probe exited 22 on every attempt for as long as the
container ran. A narrower endpoint would prove nothing this does not.

**Nothing self-heals, and each of the three obvious remedies was measured against
a throwaway always-failing-healthcheck container rather than reasoned about:**

- `restart: unless-stopped` **never fires**. A restart policy acts on a container
  that *exits*, and a wedged container does not exit. `RestartCount` stayed 0.
- `docker compose up -d` on unchanged configuration reports `Running`, keeps the
  **same container id**, and does not recreate. `up -d --wait` waits, reports
  unhealthy, and still does not recreate.
- Only *changed* configuration recreates — and there is none, because the
  revision being converged is the one that produced the wedge.

So the next converge meets the same wedged container. On the NAS that is worse
than in CI: `scripts/production_auto_deploy.py` records the attempt **before** the
play, a wedge is not a `TransientDeploymentError`, so `forget_attempt()` is never
reached and the revision is never retried on its own. Recovery is an operator
running `--retry-failed <sha>`, and there is no rollback.

The numbers, both from the `seafile` lane and therefore Confirmed. A clean first
boot reported healthy **13.6 seconds** after the container was created (run
`13a00da`), from a genuinely empty `/shared` and an empty MariaDB datadir. The
wedge sat unhealthy for **424 seconds** (run `e727d80`, container created
13:04:09, Compose gave up 13:11:13) — `start_period` 300s plus four probes 30s
apart plus one probe's own runtime, the fifth consecutive failure landing at
420s. Compose aborts the moment Docker says unhealthy, which is why
`seafile_compose_wait_timeout: 600` never bound and can only ever be the backstop
for a stage that returns no verdict at all. **The budget already grants roughly
thirty times the only successful boot anyone has measured**, so raising it would
have made the red leg later rather than green.

How often is the one number this dossier cannot state cleanly. The record
disagrees with itself: #445's progress comment says the wedge appeared in **1 of
3** lane runs, and the comment in
[`roles/seafile/tasks/deploy.yml`](../roles/seafile/tasks/deploy.yml) says **1 of
2**. What is not in doubt is that it happened once, on a named run, and that the
lane has been green since. Treat it as observed and rare, not as a rate — and
note that neither record is large enough to be one.

#477 added a **bounded recovery** for exactly this shape and nothing wider: on
`running AND unhealthy` only, capture the container's Docker health verdict —
before the recreate, because the evidence dies with the container — force-recreate
the `seafile` service alone at most `seafile_wedged_boot_recreate_limit` times
(default 1), and otherwise fail loudly with a message that says it *already*
retried. A container that exited, one Docker still calls `starting`, one with no
health check and one that was never created are all classified `other`, and
`other` re-raises the deployment's own error unchanged — the rescue must not
become a general retry, or a Compose file that does not parse stops failing on
the first converge. `0` is a supported value and is the one to set while
debugging a live wedge: the converge still detects the state and still prints the
health log, then fails without touching the evidence.

**This path has never actually fired.** It is verified by design review and by
contract rows against a stubbed `docker` — not Confirmed, and marked so here for
the same reason the code says it: a remediation nobody has watched work is a
hypothesis with a `rescue:` around it.

And it is bounded in a second sense the failure message has to be read for.
**A recreate does not clear `/shared`.** If `start.py` died partway through
`init_seafile_server()`, `seafile-data` already exists, so the next start takes
`bootstrap.py`'s "skip running setup-seafile-mysql.py" early return and the
server can come back **healthy but half-configured**. Docker's health verdict
cannot tell that from a real recovery and neither can the rescue. What catches it
is the `POST /api2/auth-token/` verification, which authenticates against
`ccnet_db` and `seahub_db` and fails by name when they are not there.

## Healthy is not the same as working

The wedge is the loud case. The quiet one is worse, and it is a platform finding
rather than a Seafile one.

**Seahub serving its cached login page while the database link is broken reads
*healthy* to everything that watches containers here.** Docker's health check
passes, because the login page renders from cached `constance_config` and does
not touch the database. Dozzle sees a healthy container. Beszel sees a healthy
system.

What is actually deployed against that: `roles/dozzle` carries an `Unhealthy`
rule with `containerExpression: "true"`, which `alert_relay.py` relays to ntfy at
priority 5, so a *wedge* does page. But the rule fires on a `health_status`
**event** with no periodic sweep behind it, and no remediation is possible as
configured — `DOZZLE_ENABLE_ACTIONS` is `"false"` and the socket proxy sets
`POST: "0"`. Beszel's managed alerts are per-system with no container dimension
at all. The quiet case trips none of it. The only thing in this platform that
catches a Seafile serving pages against a dead database is `verify.yml`'s
auth-token POST, **and that runs on deploy ticks only.**

One thing follows that this dossier states rather than resolves. Seafile is where
the gap was noticed because it is the first service whose web tier caches enough
to keep answering convincingly, and because it is the first whose contents are
the operator's own documents — but nothing about the mechanism is Seafile's.
Whether the other fifteen share the shape has not been surveyed, and the survey is
the work rather than the conclusion.

Two things are worth knowing before somebody tries to close it in the health
check. Embedding a credential in a `test:` is not the obstacle — the Valkey probe
beside it does exactly that, taking the password from the environment so it never
reaches the process table, and grepping for a literal `PONG` because `valkey-cli`
exits 0 after printing `NOAUTH` too. And a health check that authenticated would
be writing the platform's own administrator credential into a probe Docker
re-runs every 30 seconds for the life of the container, which is a different
trade from a verification that runs on a converge.

## The backup that took no backup, and how three agreeing copies hid it

The defect worth the most space in this file, because the lesson is general and
Seafile is incidental to it.

The first `seafile` lane run of #492 failed with `this platform took no Seafile
backup`. Every converge before it had classified itself `stack-not-running` and
taken the quietest branch, with a clean `PLAY RECAP` of
`ok=137 changed=0 failed=0`. **Twenty-six seconds earlier the rehearsal had
seeded a file into a library and read it back over the API**, so the stack was
demonstrably serving: the classifier's premise was false, not its policy.

The cause was not the container naming everybody reaches for first. It was a
Jinja lexing trap. The image census built its argv inside a `{{ … }}` expression
and wrapped the Go template in `{% raw %}`:

```yaml
argv: >-
  {{ ['docker', 'container', 'inspect', '--format',
      '{% raw %}{{index .Config.Labels "..."}}={{.Config.Image}}{% endraw %}']
     + seafile_stack_containers.stdout_lines }}
```

**`{% raw %}` is a *tag*, and a tag is only a tag in template context.** Inside a
variable block, Jinja's lexer is tokenising a string literal, so the wrapper is
just characters. It reached `docker --format` verbatim, every census line came
back wearing a `{% raw %}` prefix, `select('match', '^(seafile|db)=')` matched
nothing, and the classifier reported `stack-not-running` against a stack that was
serving its API.

Proven three ways rather than argued, which is the standard this repository
holds a mechanism claim to: a probe playbook on ansible-core 2.21.3 rendering the
expression form against the plain-scalar form `deploy.yml` already used;
`docker container inspect --format` on Docker 29.7.2 printing the wrapper back
around a real value; and the corrected task parsing cleanly against a real
container. Confirmed.

**On the NAS this would have failed silently for ever** — no backup, no error,
and a pinned upgrade migrating all three schemas with no copy anywhere. The exact
failure the slice exists to prevent, living inside the thing meant to prevent it.

Three things about how it survived are worth more than the fix.

**Three copies of the expression existed and all three agreed.** The classifier,
the guard and the manifest each rebuilt the census independently, and they were
perfectly consistent with each other and all wrong. Agreement between copies is
not evidence; it is what makes a defect look reviewed. They are now one fact
resolved once and read three times.

**The correct form was already in the repository, one file away, with a comment
saying it had been verified.** `deploy.yml` writes the same Go template as a
plain scalar in an argv list, where there is no expression for a raw tag to be
swallowed by, and its comment says so. What was missing was anything making that
verification apply to the *role* rather than to the one task somebody remembered.
The guard in `seafile-static.rb` now refuses any `{%` tag inside a Jinja
expression across every task file the role has, with the row planting the exact
argv that shipped.

**The first guard is deliberately static rather than stubbed.** A Docker stub
returns the name the code expects and proves nothing about a format string that
did not render; only reading the shipped text catches this class. The other two
guards generalise the policy rather than patching the instance: a census that
found containers and parsed none of them must **fail** rather than read as
stopped — `stack-not-running` may now only mean Docker found nothing running —
and a *forced* backup with no stack to dump now fails at the converge naming the
cause, rather than surfacing 6m40s later as a missing directory.

A fourth check was written and then removed, and its removal is the last part of
the lesson. It overlapped the raw-tag guard exactly, so either alone still caught
the mutation and neither could name a single cause; the self-test reported it as
"caught by the wrong assertion". Two guards that fire together on the same defect
are one guard and one false confidence.

## Credentials, sorted by what a rotation actually does

Seven vault credentials, and they do not behave alike. Sorting them by mechanism
is more useful than counting them, because the platform's one-directional
credential flow means something different in each case. Read out of
[`roles/seafile/templates/env.j2`](../roles/seafile/templates/env.j2), which is
where each lifetime is argued beside the line it renders.

- **A rotation reconciles.** The JWT signing key and the cache password. Both are
  read on every start — the cache persists nothing, so there is no stored copy to
  diverge from — and Compose recreating the container puts the new value in
  force. Two of seven.
- **A rotation is detected and refused.** The MariaDB root password. Two
  consumers with different lifetimes: the db container reads it as
  `MYSQL_ROOT_PASSWORD` on every start, but MariaDB only *applies* it while the
  data directory is empty. So a rotation changes what the container is told and
  not what the datadir stores. `deploy.yml` probes for exactly that drift over
  TCP as `root@%` before the application phase and refuses the converge naming
  it, rather than letting it surface later as an unexplained connection failure.
- **A rotation is a silent no-op the platform cannot fix.** The administrator
  email and password, for the `check_init_admin.py` reason above. Verification
  makes the divergence loud; nothing makes it repairable.
- **Created once by the server's own setup.** The Seafile database account and
  its password. MariaDB is given no `MYSQL_USER` deliberately — Seafile's setup
  connects as root and creates the three schemas and the account that owns them,
  so declaring any of it in the Compose environment would create a second,
  divergent owner. What a rotation of this pair does on a converged deployment
  has not been tested here, and is marked Unverified rather than assumed to match
  either of the two cases above.

The practical consequence is why the deployment flag was held off through all
five slices rather than flipped in one of them. **The first converge on the NAS
permanently fixes the one-shot half of that list.** After it, those credentials
are no longer things the vault decides — they are things the vault records, and
the vault is only still correct because nothing has diverged yet. The root
password is the one exception worth holding onto, because it is the only member
of that half whose divergence something actually detects.

## What remains unsettled

- **Search is deferred, not merely undecided, and it is #497 now.** Seafile ships
  without full-text search over content: filename search works, content search
  does not. The engine choice — Elasticsearch or SeaSearch, and `pro.py` raises
  if both are enabled, so it is exclusive — was split out of #445 so the rest
  could ship and be used. Nothing here should be read as a slice about to land.
  What the dossier contributes to that decision: SeaSearch needs no host sysctl,
  no `mem_limit`, no ulimits and no JVM tuning, but ships on a floating
  `1.0-latest` tag that this repository's `repo:1.2.3@sha256:` rule has no shape
  for — so the lighter option may need a policy exception before it is lighter.
  If Elasticsearch: `bootstrap.py` already writes `es_host = elasticsearch`
  unconditionally on first run, so naming the Compose service `elasticsearch`
  reduces the change to one key. One of #445's two original objections has gone
  away — the memory-limit policy it asked for landed under #447, and the list of
  images that must declare a limit (`MEMORY_SELF_SIZING_IMAGES` in
  `tests/policy_test.rb`) holds exactly one entry today, `docker.io/apache/tika`
  — so an Elasticsearch `mem_limit` would now be policy-compliant rather than the
  repository's first.
- **The wedged-boot recovery has never fired.** Verified by design and by stubbed
  contract rows only. A first real occurrence should be read as this remediation
  running, not as a new symptom — the failure message says so, and the run will
  be slower than a normal failure by exactly the health budget it spent.
- **The forced backup path has never executed end to end.** Dump, `conf/` copy,
  manifest render, prune. The classifier now demonstrably works against a running
  container and the dump argv was proved locally against `mariadb:10.11.19`
  (a 5.3 MB result file), but the sequence as a whole has not run. If a future
  lane fails in this role, this is the likeliest place.
- **No line of the Mac Seafile coverage has ever executed.** `tests/mac/run.sh`
  needs a vault file and password provider the authoring machine does not have,
  and the coverage harness stubs `run-contract.sh`, so what #495 proved is the
  dispatch tables and not the behaviour. The Mac lane also runs no restore
  rehearsal — the contract's pair needs a forced-backup converge between its
  halves and no Mac phase performs one — so the CI `seafile` lane remains the only
  place that executes.
- **The block-store boundary was never measured against a real major upgrade**,
  as stated above. It is the single claim whose failure would invalidate the
  design of the backup rather than its implementation.
- **Nobody has measured `/volume1`.** `20g` is an asymmetry argument, not a
  sizing one, and `df -h /volume1` on the NAS would settle it.
- **The NAS RAM figure is recorded, and the repository disagrees with itself
  about whether it is.** [`CLAUDE.md`](../CLAUDE.md) states 16 GB, Docker
  reporting 15.4 GiB, and thirty running containers holding 4.9 GiB between them,
  measured 2026-09-08 — while #497, filed after that paragraph landed, says the
  figure is "Still recorded nowhere in this repository". The paragraph is the
  correct one on the narrow question and **neither settles the decision that
  needs it**, which is why this is listed as unsettled rather than closed. Three
  reasons: `CLAUDE.md` says of its own numbers, "These figures are an
  observation, not a budget, and nothing validates them"; they were taken with
  Seafile gated off, and that file says so explicitly; and what an Elasticsearch
  path needs is not the total but the *headroom* under a co-resident JVM, which
  nobody has measured at all. `free -h` on the NAS is still the thing to run, and
  #497 is where the answer belongs.
- **An untested edge in the quota reconciliation.** If a future image ships its
  own `[quota]` section, the marked block appends a second one. GKeyFile's
  duplicate-group behaviour was not verified.
- **The quota knob lives in `roles/seafile/defaults/main.yml`, not beside
  `seafile_deployment_enabled` in `inventory/group_vars/all/main.yml`.**
  Defensible — the group_vars rule contrasts with the *vault*, and role defaults
  are this repository's home for role arguments — but an operator will look in
  the inventory first.
- **There is no TLS, here or anywhere on this platform**, and Seafile raises the
  stakes rather than introducing them. Zero occurrences of 443 across
  `services/`, `roles/` and `inventory/`, and `SEAFILE_SERVER_PROTOCOL: http`
  bakes `http://` into every share link and every `seafhttp` URL the server hands
  a client. This is the first service whose login guards the operator's own
  files. A platform decision is owed; adopting a reverse proxy for one service
  would leave the other fifteen exactly where they are, and choosing one means
  choosing a certificate story for a network with no public DNS.
- **Whether the healthy-but-broken gap exists for other services here.** Seafile
  is where it was found. Nothing has surveyed the other fifteen.

There is no "Reproducing the confirmations" section in this file, and its absence
is deliberate. Every runtime confirmation above was produced inside the CI
`seafile` lane or by the contract programs it runs, against a stack no shell on a
workstation can start —
[`tests/integration.sh --suite seafile`](../tests/integration.sh) is the
reproduction, and
[`tests/contracts/seafile.sh`](../tests/contracts/seafile.sh) with its static and
runtime halves is where each assertion is written down. A block of copy-pasteable
`docker run` lines would be a fabrication of provenance this dossier does not
have.
