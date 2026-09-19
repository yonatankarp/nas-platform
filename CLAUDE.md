# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

Ansible is the **only** control plane for an ASUSTOR AS6704T NAS running seventeen
Compose service stacks. The repository recreates service *configuration*, not
data. Configuration changed by hand in a service's web UI is reverted by the
next run — that is what makes the repository describe reality.

Ansible runs against one inventory host with the connection switched:
`inventory/local.yml` on the NAS, `inventory/remote.yml` from a workstation,
`inventory/mac.yml` for the disposable Mac proof. Every task, HTTP calls
included, executes on that host, so roles address services over `127.0.0.1`
and are correct in both modes.

`ansible.cfg` deliberately names no default inventory: it used to name
`inventory/remote.yml`, so a bare `ansible-playbook site.yml` converged the live
NAS. Without it, `platform_hosts` matches nothing and the run ends on an empty
`PLAY RECAP` having touched no host. Always pass `-i`.

## Commands

Ansible tooling is pinned in `controller-requirements.txt`, which every CI job
that needs the toolchain installs from as well; collections in `requirements.yml`.
The versions live there and nowhere else — a version restated in prose is a copy
nothing bumps, which is what `tests/docs_links_test.rb` refuses here and
`tests/policy_test.rb` refuses in the beginner guides.

```sh
pip install -r controller-requirements.txt
ansible-galaxy collection install -r requirements.yml
```

### The test ladder — run in order, stop at the first failure

```sh
ruby tests/policy_test.rb                    # seconds; accumulates every violation
ruby tests/policy_manifest_test.rb
ansible-playbook -i inventory/local.yml site.yml --syntax-check
ansible-lint --strict                        # ~1 min, production profile
tests/validate-policy.sh                     # the full CI gate; slow (>10 min serial)
tests/integration.sh --suite smoke site.yml  # needs Docker
```

`tests/validate-policy.sh` runs every Ruby/Python/shell unit check in the
repository, concurrently. Its check list is a literal manifest inside the
script — one bare command per line. Three things hold it, and they hold
different amounts. `tests/gate_manifest_coverage_test.rb` declares that whole
list and refuses any line it does not name, in either direction, so adding or
removing a check costs an edit in two places; what that buys is that a prune
lands as a visible diff instead of as a quieter gate, not that anything
exercises the check itself. `tests/policy_ci_test.rb` and `tests/policy_test.rb`
require about ninety lines individually, each with the reason it has to keep
running. `tests/policy_manifest_test.rb` proves that deleting one of those
individually named lines is caught. The two-place cost is deliberate: until
#469 about forty of these lines were required by nothing at all, so deleting
any one of them left every check green and the gate faster than before. **Do
not wrap or prefix those lines**; doing so silently disables the guards while
leaving the script working. `POLICY_JOBS=1` restores serial order when bisecting
a load-dependent failure.

### Running one test

Any line of `tests/validate-policy.sh` is a runnable single test, e.g.
`ruby tests/komga_library_reconciliation_test.rb`. Tests that must run under
Ansible's own interpreter use `"$ansible_python"`; resolve it with
`ansible-playbook --version` and read the `python version = ... (path)` field.
Several Ruby tests accept `--self-test`, which proves the test itself detects a
planted regression.

`ruby tests/policy_manifest_test.rb --audit` is the one to run after adding a
check to a policy script. Each mutation row names the policy scripts that detect
its planted defect and runs only those; `--audit` runs all eight again and fails
on any row whose declared set has drifted. It costs what the narrowing removed
-- about half an hour on a runner before its rows were pooled -- so pull
requests and pushes run the narrow form and only the nightly and
`workflow_dispatch` run `--audit`, in place of it (#727). Drift therefore reds the nightly a day late rather than the pull request
that caused it.

Adding a file that a policy check *reads* carries an obligation of its own: list
it in `BASE_FIXTURE_PATHS` in `tests/policy_mutation_support.rb`. The mutation
harness copies a curated subset of the repository into each sandbox, so a file it
does not copy is absent there, and the check that reads it crashes instead of
running. That list is stated rather than derived on purpose, because a sandbox
built from whatever happens to be on disk would stop proving that a check reads
the file it claims to read; nothing will derive the entry for you. Recognise the
omission by its symptom, which is not one check failing: every `expect_success`
row goes red at once, and because `expect_success` reports only the first line of
the combined output of every policy script it ran, the line it prints is usually
another script's success message rather than the crash that names the missing
path.

### Integration suites

```sh
tests/integration.sh --list-suites
tests/integration.sh --suite <lane> site.yml
tests/integration.sh --describe-suite <lane>   # prints the pinned suite/tags/scenarios line
```

Lanes: `foundation arr downloaders bindery kapowarr pinchflat trailarr seerr
smoke beszel dozzle audiobookshelf komga jellyfin immich paperless
nextcloud vaultwarden karakeep upgrade idempotence-check idempotence-1 idempotence-2
idempotence-3 idempotence-4 idempotence-5 idempotence-6 full` — the roster
is `tests/ci/suites.conf`, and
`tests/docs_links_test.rb` fails if this list disagrees with what
`tests/integration.sh --list-suites` prints. Every service and acquisition lane
converges `host_prep` and `deployment_bundle` as well; neither is a lane of its
own. The deployment report every service role sends lives in
`roles/deployment_bundle`, whose changes fall open to every lane. The harness runs Ansible
inside a pinned Linux container against a disposable sandbox so the plays meet a
real `/proc/mounts`, real numeric uid/gid and a real Docker socket. It asserts
three properties: the run converges, a second run changes nothing, and
`--check --diff` works. Bugs that pass syntax check and lint — a fact that only
exists on Linux, a `command` task silently skipped under `--check` — are caught
only here.

**`upgrade` is the one lane that does not start from an empty store, and it is
the only one that can see a migration at all (#773).** Every other lane builds a
disposable sandbox, `host_prep` creates the service directories empty and the
service initialises fresh — so every one of them takes the fresh-install path and
nothing anywhere opens a store a previous version wrote. That is the entire class
#511 and #671 fell into, invisible here by construction. This lane converges the
**base** branch's pin of one service, writes rows through that service's own HTTP
API, repins to the head image and converges again, so the head container runs its
own migration against a store the base container wrote, and then reads those rows
back.

Three things about it are worth knowing before changing it:

- **Its subject and base pin are inputs, not tags.** `INTEGRATION_UPGRADE_SERVICE`
  and `INTEGRATION_UPGRADE_BASE_IMAGE`, refused rather than clamped, and emitted
  by `tests/ci/classify_changes.rb` from the same diff it routes on. The base
  cannot be read from inside the lane: the `suites` job checks out at
  `actions/checkout`'s default depth of 1, unlike `changes`, `static`, `mutation`
  and `reconciliation`. **Its tags are its subject's, on an `upgrade_tags` output
  of their own**, never the run's `selected_tags`: that is the union of every
  tagged lane, and a fall-open empties it — which would send this lane down the
  untagged branch and converge the whole site twice for a one-service proof. The
  workflow refuses an empty value rather than degrading to it.
- **A repin is two commits, not two file writes.** `deployment_bundle` keys its
  immutable release on `platform_release_id` and refuses to mutate a release
  `current` already points at, so rewriting `compose.yml` without moving HEAD is
  that refusal rather than a repin.
- **Which services it can take as a subject is derived**, from which ones carry a
  `tests/contracts/<svc>-upgrade.rb`. Bindery and Kapowarr today, being the two
  with actual incidents. A subject with no such program is refused, because a
  lane that converges, migrates and asserts nothing is green while proving less
  than the fresh-install lanes it exists to complement. Per-service seeds are
  irreducibly bespoke — different stores behind different APIs — so there is no
  shared seeder to build. **Adding a third subject is four edits**, and they are
  named here because this sentence used to claim one:
  1. `tests/contracts/<svc>-upgrade.rb`, the seed and verify program.
  2. `EXPECTED_UPGRADE_SUBJECTS` in `tests/contract_upgrade_seed_test.rb` — the
     stated floor under the derivation, closed both ways. It also requires each
     basename to be all three of the names it is used as: a `services/`
     directory, a `tests/contracts/<name>.sh` wrapper and a manifest service
     directory. Those diverge for `paperless-ngx`, and a subject that diverged
     would resolve nothing and never dispatch.
  3. `tests/contracts/<svc>.sh` — the mode guard widened to `seed|verify`, the
     static half skipped in those modes, and the dispatch arm.
  4. `tests/<svc>_contract_test.rb` — `MODE_REFUSAL`, the refused-mode sweep
     (`verify` becomes an accepted mode and has to leave it), and the
     `"  static|run) ;;"` plant string, all of which the wrapper edit moves.

**What switches it off is the absence of a base revision, and nothing else.**
`--full` and a `--files` classification have none, so the nightly and
`workflow_dispatch` do not run it. A **fall-open does** have one, and a
fall-open whose diff moved a subject's pin dispatches the lane like any other
selection — it already runs 25 legs, so one more is marginal, and forcing it off
there is what made the lane undispatchable on every pull request that also
touched an unmapped path, including the one that introduced it.

**One subject per run, and a human pull request can exceed that.** The
classifier emits the first subject whose pin moved, in `UPGRADE_SUBJECTS` order,
so a diff moving two of them proves the first. Renovate cannot produce such a
diff — #771's batch group excludes both of these images — but a hand-written
pull request bumping Bindery and Kapowarr together can, and it would prove one
of them.

**The lane ends by stopping the head container and reading its exit code
(#781).** That is the shutdown half of #671, where a patch whose migration was
correct shipped a handler that raised, and every stop was waited out to Docker's
SIGKILL — 30.46s and exit 137 on the NAS, with the first report coming from
Dozzle's `die` rule after the poller had deployed it. 137 is 128+SIGKILL and
means exactly "the grace expired"; 0 and 143 mean exactly that it did not, so the
exit code is the whole assertion and nothing is asserted on the clock. It is
measured rather than read off `stop_grace_period`, because a *declared* grace is
not evidence of stopping inside one — `alert-relay` and `nextcloud-cron` both
declared one and were killed anyway, for the two independent reasons the
container-memory section records.

Two limits sit under that. The **base** container's stop is still unobservable:
Compose removes it inside the same recreate, so nothing here can read it first.
And this would have caught #671 only by luck — that raise needed a task at the
head of the queue that had been created and never started, and
`services/kapowarr/tasks.py` shows `_process_queue()` starts `queue[0]` inside
every `add()`, so an unstarted head exists only in the window between a finishing
task's `pop(0)` and its `_process_queue()`. Upstream reproduced it with 300
concurrent submissions. What the assertion does cover deterministically is the
regression class those two recorded containers are in: a PID 1 with no handler,
an ignored `STOPSIGNAL`, a handler that hangs, and — the one specific to this
lane's own subjects — a carried patch that has stopped applying to the image it
is mounted over.

**A rollback reds this lane, and that is the guard rather than a defect.** A
revert or a Renovate rollback makes the base newer than the head, so the
classifier selects the lane — the pins differ — the first converge runs the newer
image, and the second meets `roles/image_downgrade_guard`, which both Bindery and
Kapowarr call before their backup and their Compose deployment and which refuses
a pin older than one that has already run. The lane therefore goes red on the
pull request that is the *correct* fix for a bad migration, with a message about
that guard and not about the store. It is left that way deliberately: comparing
versions across arbitrary tags is exactly what that role exists to do, and a
direction check in the classifier would be a second, worse copy of it. **What
that costs is a ruleset bypass, not a click**: `validate` aggregates the
`suites` result, `validate` is the required check on `main`, and the
repository-admin bypass on that ruleset is `always` — so merging past this lane
means an admin taking that bypass, which is the same cost as merging past any
other red leg.

### Deploying / reviewing

**The NAS deploys itself.** `roles/production_auto_deploy` installs a poller that
converges the newest CI-released `main` revision **every five minutes**, and it
serialises deployments with an flock on its state directory. A hand-run
`ansible-playbook` takes no such lock, so a manual converge outliving one tick
races the poller — which is exactly what happened in #326: the poller repointed
`current` under a run still converging services, and that run died at its *last*
role on a containment guard reporting an unsafe deployment target. So converge on
the NAS through the launcher, which takes the poller's own lock and passes
everything after `--` to `ansible-playbook` unchanged:

```sh
nas-platform-deploy --converge -- -i inventory/local.yml site.yml --check --diff --ask-vault-pass
nas-platform-deploy --converge -- -i inventory/local.yml site.yml --ask-vault-pass
nas-platform-deploy --status                 # what the poller last did, and what it would do next
nas-platform-deploy --verify                 # verify.yml against the deployed revision; cron runs it hourly
```

From a workstation the plays still run over SSH, and these two cannot hold a lock
that lives on the NAS:

```sh
ansible-playbook -i inventory/remote.yml site.yml --check --diff --ask-vault-pass
ansible-playbook -i inventory/remote.yml site.yml --ask-vault-pass
ansible-playbook -i inventory/local.yml verify.yml --tags platform_verify_<name>
```

What protects them is `deployment_bundle`, which probes that lock at the first
task of every role and refuses — in check mode too — with *"A deployment is
already running on this host"*, naming the holder. Read that message literally:
it is a scheduling conflict, not the integrity refusal it used to be mistaken
for. Wait for the running deployment and re-run; re-running immediately only adds
a third converge. A holder that recorded no identity is reported and tolerated
rather than refused, for the reason below.

**`site.yml` must never depend on anything `install-production-auto-deploy.yml`
installs.** The poller runs `validate-vault.yml`, `site.yml`, `verify.yml`, and
only then `install-production-auto-deploy.yml`, so every play but the last meets
the *previously* installed poller, not the one shipping in the revision being
deployed. #327 crossed that line: it added a guard to `deployment_bundle` that
refused a lock whose holder wrote no record, and shipped the record-writing
poller in the same commit. On the NAS the old poller took the lock, wrote
nothing, `site.yml` refused after 38 seconds, the install play never ran, and
every five-minute tick afterwards failed identically — the upgrade deadlocked on
itself. Anything a new play needs on the target must therefore tolerate its
absence for one deployment, or be installed by `site.yml` itself.

What made that recoverable is worth knowing before you need it: the poller checks
out the candidate revision and runs the plays *from that checkout*, so a fix
merged to `main` is picked up on the next tick and heals the host with nobody
touching it. A broken `site.yml` is never a reason to change anything by hand on
the NAS — the repository is still the only way in.

**The two poller-adjacent scripts stay single files, and that is a design rule
rather than an accident.** `scripts/production_auto_deploy.py` and
`scripts/image_prune.py` are installed by an `ansible.builtin.copy` of exactly
one file each, from the target's own checkout. A shared module would be a second
file that has to land too, and a script that arrived without it would die at
`import` — before any handler could report it, on every five-minute tick, with no
merge able to heal the host. Ordering the two copy tasks does not close it: an
operator running the install play from a checkout older than the module's would
install the importing script from a role that has no task for the module.
`services/dozzle/alert_relay.py` mirrors the same helpers from inside a
container, where a module in the deploy account's home is not reachable at all.
So the helpers are duplicated on purpose; what `tests/policy_test.rb` enforces
instead is that the copies of `_write_private` stay textually identical, because
divergence is the harm — the two drifted until one fsynced without repairing the
mode and the other repaired the mode without fsyncing, each carrying the bug the
other had fixed (#354).

Never apply to the NAS without reading `--check --diff` first. `--check` is a
review, not a guarantee: external systems that cannot be simulated are reported
by roles as explicit `debug` tasks under check mode.

Full Mac lifecycle proof (phases `preflight deploy seed verify idempotence drift
reconcile recreate persistence report cleanup`, selectable with `--phase`):

```sh
tests/mac/run.sh --lane fresh \
  --vault-file /absolute/path/to/vault.yml \
  --vault-password-file /absolute/path/to/password-command
```

## Architecture

**Vault is always first, and credentials flow one direction.** Every credential
is authored in the encrypted vault under `inventory/group_vars/all/` — each
service's own keys and its `vault_managed_<role>_users` list in
`vault_<role>.yml`, the Pushover user key with its four application tokens in
`vault_pushover.yml`, and the two healthchecks.io ping URLs in
`vault_healthchecks.yml` — and pushed
outward. Nothing
is ever read back from a running service, which is why a run converges in a
single pass. Where a service would normally hand a human a generated value to
copy-paste, this platform supplies its own instead (Beszel gets a hub keypair
placed before first start).
`roles/vault_contract` validates the whole credential set, redacted, before any
target mutation — roles do not repeat that check.

**Roles are functions; `site.yml` calls them in order.** `defaults/main.yml` are
the default arguments, `meta/argument_specs.yml` is the enforced type signature
(every role needs one; every vault credential it reads belongs there as
`required: true`), `tasks/main.yml` is the body, `templates/env.j2` renders the
`.env` on the target at mode `0600`. Service name and role name may differ —
`paperless-ngx` / `paperless_ngx` — because directories use hyphens and role
names cannot. `services/manifest.yml` is the mapping.

**An option whose value templates over a loop variable cannot be declared, and
that is Ansible's rule rather than a style choice.** Role argument validation
templates every *declared* option at role entry, before any loop binds, so an
option whose value is a template over `item` — or over a task-scoped register,
or a fact the role itself sets later — fails the run there: `'item' is
undefined`, reported from the variable's definition site rather than from the
task that would have used it, which is what makes it hard to recognise. Leaving
it undeclared is correct, because lazy templating then resolves it per item at
the point of use. **`is defined` is not the workaround, and it fails in the
worse direction**: evaluating it templates the value, the undefined `item`
raises inside that, and the test swallows it and reads *false* — so the guard
refuses a parameter that is perfectly well defined, and says so about the
parameter rather than about the loop. Assert such a parameter's presence with
`q('varnames', '^<name>$')`, which matches variable *names* without resolving
them, the way `roles/vault_contract` already collects the managed-user lists.
The `required: true` half above is unaffected: a vault credential that is not a
per-item template still belongs in the spec.

**The target never runs against this checkout.** `roles/deployment_bundle`
assembles an immutable release from the controller checkout, installs it at
`platform_current_dir`, and keeps rendered secrets separately under
`platform_runtime_dir`. Every service role's first task re-includes
`deployment_bundle` with `tasks_from: target` and
`deployment_target_require_current_release: true`, naming exactly the paths it
is about to touch. It names them in two parts: `deployment_target_service` is
the **manifest service directory** (`paperless-ngx`, not `paperless_ngx`), from
which `deployment_bundle` derives the five paths every service role touches —
the release directory, both Compose files, the runtime directory and its `.env`
— and `deployment_target_extra_paths` is everything beyond those five, `[]` when
there is nothing. Naming a service the role does not deploy fails the run rather
than quietly widening what the role claims to touch.
`deployment_bundle` also stats each service's platform
override once per run and publishes `platform_service_compose_files` keyed by
service name — read that, never restat the override yourself.

**`verify.yml` is structurally incapable of converging.** Every role is listed
with `tags: [never]`, so only tasks separately tagged `platform_verify_<service>`
can run. Deployment and reconciliation tasks are unreachable from that playbook
by construction.

**Compose definitions are portable.** They reference `${NAS_DOCKER_ROOT:?}` /
`${NAS_MEDIA_ROOT:?}`-derived variables rather than absolute paths, so the same
file runs unmodified on the NAS, a Mac sandbox and CI. The `:?` suffix makes an
unset value fail loudly instead of silently creating a relative bind mount.
Platform overrides live in `services/<name>/compose.<kind>.yml`. They add
host-specific capabilities — devices, mounts, profiles — and **an `image:` key in
one must equal the canonical `compose.yml` image exactly**, so the version is
still written in only one place; a differing or newly introduced image fails
`tests/policy_test.rb`. There is no allowlist and no override currently carries
the key, so the simplest override is one that omits it.

**Compose project names are derived** from `platform_project_name` so a sandbox
can run several isolated copies of the platform side by side.

**A pin is not freely reversible where the container migrates its own store.**
Bindery, Immich, Paperless-ngx, Nextcloud, Karakeep and Kapowarr each apply their
own schema migrations when they start, and each documents it beside its `image:`.
`SELF_MIGRATING_APPLICATION_IMAGES` in `tests/renovate_policy_test.rb` is where
that set is authored — it keys each image by the `services/` directory that pins
it, so a name no longer appearing as an `image:` fails rather than guarding
nothing, and it is what to read instead of this sentence. That
makes a version bump one-way: the newer image writes a schema the older one
declines to open, and it declines *inside the container*, so the symptom is a
crash loop rather than a failure a play reports. #511 is what that costs — a
Bindery application **minor** migrated the store to `schema_migrations` 81, the
release went back to a pin that knew 1..80, and the host sat behind it for three
days with every converge failing at that role and the poller not advancing. Two
controls, at opposite ends. `renovate.json` withholds `major`, `minor` and
`patch` for those images **from automerge** — a digest refresh on an unchanged
tag moves no version and stays automerged, except for Immich, which is withheld
not by that rule but by its own manual-coupling rule, for every update type and
so digests too — which is a wider scope than the
database-major rule beside it and deliberately so. It withholds the *merge*, not
the pull request, and that is the one place it departs from the two major-only
rules beside it, which carry `dependencyDashboardApproval` and suppress the pull
request itself. Those match majors, where a checkbox nobody ticks for a month
costs nothing; this one reaches minor and patch on services that ship them
continuously, and there a suppressed pull request is not a decision deferred but
an update nobody ever sees. The pull request is the notification. And `roles/image_downgrade_guard`, included by a
service role before its backup and its Compose deployment, reads the image
reference Docker recorded for that service's own containers, running or not, and
refuses a pin older than one that has already run. It compares image versions
rather than schema versions because the schema lives in a store only the
application can open; the role names the three routes to the real version and
why each was rejected. It has already spread past the set above: Bindery,
Kapowarr (#671), Karakeep — twice, once for Meilisearch's index — and Vaultwarden
call it today, and the Vaultwarden call site records a second reason for it, a
CVE floor under the pin that this guard does not read. The role takes the
manifest directory, the Compose service key and the project name as arguments, so
the self-migrating images that have not adopted it can do so unchanged.

**Container CPU policy.** Production containers are pinned to logical CPUs `0-2`
of four, each with a workload-specific 0.5–3.0 CPU ceiling. Ansible derives and
validates the effective CPU set before deployment and checks Docker's applied
set and quota after each stack starts. Change the budget only in
`inventory/group_vars/nas_hosts/main.yml`.

**Container memory has no policy, and headroom is the only reason that has been
safe.** The NAS has 16 GB of RAM, which Docker reports as 15.4 GiB. Measured
2026-09-08: the thirty running containers held 4.9 GiB between them, the largest
being Jellyfin at 785 MiB, `immich_server` at 595 and SABnzbd at 484; host
memory sat at 27% with PSI reporting about 1% stall; and the two workloads that
could be large, Immich's ML container and Jellyfin transcoding, read 93 MiB and
785 MiB because they are bursty rather than resident. Swap is 2 GB and was
entirely consumed at a swappiness of 60, about 2.4 GB paged out over 23 hours of
uptime, which is a trickle and not pressure. Those figures were taken before
this host's file-sync stack changed twice over -- Seafile was gated off then,
#499 turned it on, and #501 removed it -- so the measurement is behind the host
it describes and the next one has to be taken fresh rather than adjusted.
Nextcloud replaced it (#500), so its four containers are not in
these numbers either, and a PostgreSQL cluster plus a PHP application is the
workload most likely to move them. Only `paperless_tika` declares `mem_limit`, and only
because it is a JVM and sized its own heap off the host without one (the
convention below, #447); nothing declares `memswap_limit` or
`deploy.resources`, so every other container may still take the whole host,
which is a decision rather than an omission. Beyond a self-sizing runtime there
is nothing here to contain: page cache dominates the per-container high-water
marks, so a limit on an I/O-heavy container would cap its cache rather than a
leak. `/sys/fs/cgroup/memory/memory.memsw.limit_in_bytes` exists despite
cgroup v1 and no `swapaccount=1`, so both controls are available whenever one is
wanted. Two alerts sit under that, neither of them a limit: Beszel warns above
90% of host memory sustained ten minutes, and Dozzle carries an `OOM` rule that
names the container. Whether that rule fires for a host-level kill on a
container with no limit set is still untested, and it is cgroup-scoped by
construction, so it probably cannot report one. The `die` rule beside it no
longer excludes exit 137 (#493), which is what a SIGKILL produces, so a
host-level OOM kill now pages with the container named whatever the `oom` rule
does. The deliberate stops that exclusion was protecting stay quiet regardless:
a stop that completes inside its grace period exits 0 or 143, both still
excluded, and every database and cache declares a `stop_grace_period` well above
Docker's ten-second default. Twelve containers, none of them a database or a
cache, declare none and take that default, and one was measured and did not make
it: `alert-relay` ran Python as PID 1 with no SIGTERM handler, and PID 1 is the
one process the kernel applies no default disposition to, so the stop was
discarded and Docker SIGKILLed it — measured at 10.14s and exit 137, on every
recreation, paging through the container that had just exited and so unable to
deliver it. #516 blocks both stop signals before any thread exists and waits for
one with `sigwait`, which is what a raising signal handler cannot do reliably:
socketserver swallows an exception raised while it dispatches a request, and a
raising handler was observed losing a stop there once in eight attempts. Measured again after: 0.61s and exit 0, with a
`docker kill -s KILL` still exiting 137, which is what keeps a host-level
out-of-memory kill reportable. What is left open is interpreter start-up, before
the process blocks anything; `init: true` would close it and was not taken, for
the reason `services/dozzle/alert_relay.py` records beside its stop handling. For the other
eleven, exiting inside ten seconds is an expectation rather than a measurement.
**Declaring a grace period is not evidence of stopping inside one either**, which
is the half `alert-relay` did not show: `nextcloud-cron` declared 30s and still
exited 137 on every recreate, measured 2026-09-12, because its image is the
application's and so carries php:apache's `STOPSIGNAL SIGWINCH` -- a signal whose
default disposition is to be ignored -- while `/cron.sh` execs busybox crond as
PID 1, which installs no handler and is the one process the kernel gives no
default disposition to. Two independent swallows of the same stop, either
sufficient. `init: true` with `stop_signal: SIGTERM` is what answers both, and it
is the second reason to reach for an init shim rather than the reaping one that
key was reserved for. These figures are an observation, not a budget, and nothing
validates them: if a memory policy lands (#447) the RAM figure belongs beside
`platform_container_cpu_budget` with a preflight assert against what the Docker
daemon reports, the way the logical CPU capacity already is.

**`nas_storage` is one source of truth for three things**: `host_prep` creates the
directories with those permissions, the policy test requires every implemented
service to declare a path naming it, and the `recovery` class (`critical` /
`user` / `cache`) drives disaster-recovery docs. Omit `owner`/`group` under the
media root — the NAS owns those files.

**It is no longer written in one place, and `main.yml` is no longer where a
service's settings go.** `inventory/group_vars/all/` holds `main.yml` for the
cross-cutting facts, one `service_<role>.yml` per service carrying that service's
settings *and* the storage it owns, and two shared files for the nineteen media
paths no service owns: `media_libraries.yml` for the seven `recovery: user`
library roots and `media_acquisition.yml` for the twelve `recovery: cache`
staging paths. The two are separate because the recovery class drives the
disaster-recovery documentation, so one file holding both would mix what can be
rebuilt with what cannot. `main.yml` composes whatever is present:

```yaml
platform_storage_names: "{{ q('varnames', '^nas_storage_') | sort }}"
nas_storage: "{{ q('vars', *platform_storage_names) | flatten(levels=1) | sort(attribute='path') }}"
```

Adding a service means adding one file. Nothing else lists the contributors —
`tests/nas_storage_support.rb` applies the same rule on the Ruby side and every
static reader goes through it, because a sixtieth list is the one nobody edits.

Four things are what that shape is paying for, and they are the reason not to
simplify it back. The `vars` dictionary is deprecated and **removed in ansible-core
2.24**, and `hostvars` is undefined while group_vars are still being assembled,
so the varnames/vars lookup pair is not a style choice but the only supported
form. The `sort(attribute='path')` is load-bearing: `host_prep` loops in order
and `ansible.builtin.file` applies a declared mode to an intermediate parent only
when it creates it, so a leaf reached before its root leaves that root holding
the umask; a lexicographic path sort puts every parent ahead of its children
because a parent path is a prefix of them. **The composition is silent when it
matches nothing** — measured 2026-09-12, deleting every contributor leaves
`nas_storage` as `[]` and the play reports `ok` — so `host_prep` asserts a
collapse floor and `tests/nas_storage_support.rb` holds contributors against
`services/manifest.yml` in both directions, with `SHARED_CONTRIBUTORS` and
`STORAGE_FREE_SERVICES` closed both ways like `CREDENTIAL_FREE_SERVICES`. And
`q('varnames')` reads whatever is in scope when it evaluates, so **nothing
outside `inventory/group_vars/all/` may define a `nas_storage_*` variable**: one
in a role default would join the composition partway through a run and make
`nas_storage` mean different things in different places. `tests/policy_test.rb`
refuses that prefix everywhere else.

Custom Ansible code lives in `library/` (modules), `module_utils/` and
`filter_plugins/`, wired through `ansible.cfg`. Note `inject_facts_as_vars =
False`: write `ansible_facts[...]`, never bare `ansible_*` variables.

## Conventions the policy test enforces

`ruby tests/policy_test.rb` is the fast feedback loop — make a change, run it,
fix what it names by its own words. It enforces, among others:

- Images pinned as `repo:1.2.3@sha256:<64 hex>` — both a readable tag (for
  humans and Renovate) and a manifest-list digest (for reproducibility). Take the
  top-level `Digest:` from `docker buildx imagetools inspect`, not a per-platform
  entry.
- No `build:`, no `privileged: true`, `restart: unless-stopped`, `json-file`
  logging with both `max-size` and `max-file`.
- Volume sources are `${VARIABLE:?}` references; a literal `/volume1/...` is
  rejected.
- A container on an image whose runtime sizes its own memory declares
  `mem_limit`, and a container declaring a JVM heap declares a limit at least
  twice it. `MEMORY_SELF_SIZING_IMAGES` is the stated list, because a Compose
  file does not say what runtime an image holds; `EXPECTED_SELF_SIZING_CONTAINERS`
  pins which containers it reaches, in both directions, so the subject list
  cannot empty quietly. Tika is the only member today and satisfies it with a
  limit alone, letting the JVM derive its heap from that limit rather than from
  the host's RAM, which is what it did before (#447). Nothing declares a heap
  yet, so four mutations in `tests/policy_manifest_test.rb` are that half's only
  proof.
- Every implemented service has either a verification task — name containing
  `verify`/`verification`, tag `platform_verify_<service>`, and either a `uri`
  task naming the service with `status_code:` or an `assert` whose every
  condition compares against such a registered result — or an executable
  `tests/contracts/<name>.sh` registered in `tests/contracts/registry.yml`.
  A `debug` named "verify" satisfies nothing.
- A `community.docker.docker_compose_v2_exec` task that is not `detach: true`
  states `failed_when`. The module sets `check_rc` only in the `detach` branch,
  so without that line the task reports success on any exit code — and paired
  with `changed_when: true` it asserts a change it never verified. Twelve tasks
  were in that state until #521. `failed_when: false` satisfies the rule, which
  is the point: a task that tolerates failure says so, because deleting the line
  would not make it fail. The rc default is `1`, not `0`: `failed_when` replaces
  the module's own failure verdict and re-enables `changed_when`, so a module
  that refuses before it runs anything — an unreadable `project_src`, a
  non-string `env` value, a compose too old — sets no `rc` at all, and
  `default(0)` would report that refusal as a successful change. Under the
  `no_log` these tasks carry, that is a green line and nothing else.

Idempotence is a hard requirement: mark reads `changed_when: false`, and
`check_mode: false` where a read must really run during `--check`. Use
`community.docker.docker_compose_v2` rather than shelling out — a shell-out
always claims a change and cannot simulate itself.

Tasks touching credentials carry `no_log: true`.

Adding a service touches 62 files and is walked end to end in
[docs/adding-a-service.md](docs/adding-a-service.md) — including the two pinned
Ruby name lists, the files CI routing must agree on, and the ten places a new
vault credential lands (`docs/secrets.md` among them, enforced by
`tests/secrets_docs_test.rb`). Both figures come from the guide, which measured
56 against the Pinchflat promotion and keeps a ledger of the per-service
obligations added since; `tests/docs_links_test.rb` fails when this sentence and
that ledger disagree. Adding an obligation means adding a ledger row, not
bumping a number here.

## CI

`.github/workflows/ci.yml` classifies the diff in its `changes` job with
`tests/ci/classify_changes.rb`, and every job except `changes` and `validate` is
gated on one of that job's outputs; `validate` runs under `if: ${{ always() }}`
and lets `tests/ci/validate_results.rb` decide pass/fail across all legs.

Jobs: `changes static lint docs vault mutation reconciliation toolchain suites validate`

Read that roster before adding a check anywhere, because `static` is not the only
job one can land in and which job it lands in is a routing decision. `mutation`
and `reconciliation` are extractions in the sense the rules below mean:
`tests/validate-policy.sh` no longer runs them, which `tests/policy_ci_test.rb`
asserts for both. The other half of the extraction rule is split: that same file
requires CI to run the mutation harness, while `tests/ci/workflow_test.rb` owns
it for the reconciliation matrix. `docs` is not — it is a second and cheaper
route to checks the gate still runs, so those checks reach a Markdown-only
change in under a minute without also reaching for the Ansible toolchain.
`vault` is neither an extraction nor a cheaper route: it is the one job the local
gate cannot hold, because it decrypts the vault in `inventory/group_vars/all/` with
the `ANSIBLE_VAULT_PASSWORD` repository secret and runs `validate-vault.yml`
against it — the play the poller runs first, and the one #559 failed on every
five-minute tick while every check here stayed green. No manifest line
corresponds to it and none should: the gate's own check on that file
(`tests/policy_vault_test.rb`, that the artifact is still encrypted) needs no
password and is unchanged. Two consequences follow from the secret rather than
from the check. A pull request from a fork holds no secret and reds this job,
deliberately — a skip-with-notice was considered and refused, because it is a
green run that decrypted nothing. And the workflow stays on `pull_request`:
`pull_request_target` would run this job with the base repository's secrets
against a head its author controls.
`lint` is a fourth kind again, and the one to understand before adding a step to
`static`: it holds what `static` used to run *per shard* for a verdict that
cannot vary by shard — `ansible-lint`, the three `--syntax-check` invocations and
the ephemeral vault self-test — so each of them ran three times per pull request
and all three were charged to the job with the budget below (#653; the
measurement is in `docs/ci-performance-history.md`). The obvious
trim was an `if:` on the step, and `tests/ci/workflow_test.rb` refuses one on any
`static` step precisely so that it cannot be taken: a shard-conditioned step is a
check that runs a third as often, which is #469's silent-coverage-loss shape. The
three single-command checks that stood beside them went the other way, into
`tests/validate-policy.sh`, where they run once and gain the manifest
declaration. Which direction a check goes is the same question as always — a
manifest line if the repository owns the program, a `lint` step if it does not.
`renovate-config-validator` is the worked example of the second: #775 stopped
Renovate opening pull requests repository-wide, its own dependency updates
included, on a `renovate.json` that parsed and satisfied every hand-written
property `tests/renovate_policy_test.rb` asserts, so only Renovate's own
validator could have caught it — and it is npm's program resolving `extends`
presets over the network, which is the gate's manifest ruled out. Its pin is the
only version literal in `ci.yml` that is not an action SHA, tracked by a custom
manager like every other pin here, and the step plants #775's exact
`matchPackageNames` and requires the validator to still reject it.

`static`, `reconciliation` and `suites` are matrices, so each contributes a leg
per matrix entry rather than a single check — `static` one per shard of the
policy gate's manifest, which is why its legs report as `static (1)` and not as
`static`. `validate` still names each of them once, because `needs.<job>.result`
for a matrix job is the aggregate of its legs.

A pull request classifies its own base/head diff; a push to `main` classifies
the merge it just landed — `github.event.before`, falling back to the first
parent — rather than sweeping the whole repository a second time against a tree
its pull request already tested. `--full` is what the nightly `schedule` and
`workflow_dispatch` request, and what a push falls back to when it has no base
to diff against, because routing fails open: an unmapped path runs every lane,
so a missed CI entry costs time rather than correctness. Only a pull request
cancels its own superseded runs. Each push to `main` is keyed on its own commit,
because its run is the only one that will ever see the tree it merged: a shared
group serialises merges, and GitHub holds at most one *pending* run per group, so
a third merge arriving cancels the waiting one before it runs a single job. That
is not the same failure as cancelling an in-flight run and is not prevented by
disabling that. Repeat `workflow_dispatch` runs of the same commit are the one
remaining shared group, and evicting there needs three of them.
`tests/ci/workflow_test.rb` pins the workflow's own shape, and
`tests/ci/classify_changes_test.rb` runs the classify step's own shell against
synthetic histories.

The workflow file itself is the one routed path no check reads — it *defines*
the jobs everything else is routed to — so it is routed for **job coverage**,
one leg of every job, rather than for the readers every other entry is routed
for: `static`, `docs`, `vault`, `reconciliation` and three suite legs instead of
the whole matrix (#395). Read the size of that matrix off
`tests/ci/classify_changes.rb --full`, whose `suites` array is it, rather than
from any prose: this sentence carried a literal through sixteen, then seventeen,
while a full run dispatched more than either, and the comments under `tests/ci/`
that restated it went stale the same way. Nothing bumps such a copy, so #652
removed them rather than correcting them again. One leg stands for the
rest because the matrix is uniform and
stays so under test: `tests/ci/workflow_test.rb` executes the suites job's own
`case "$SUITE"` for every suite and asserts the argv, and
`tests/ci/classify_changes_test.rb` reads each job's `needs.changes.outputs.*`
gate out of the workflow and fails unless that route turns the job on, so a new
job gated on a new output cannot land unrouted. Any *other* file under
`.github/` is unmapped and still falls open to every lane.

Documentation is routed, not inert. This file is itself a gate input —
`tests/policy_test.rb` sweeps it for retired declarations and
`tests/docs_links_test.rb` checks the lane roster and the stack count above
against the tree — so editing it selects `static` and `docs`, the two jobs those
checks run in. Which documents owe which job is derived from the registered
checks rather than listed, so a document under `docs/` that a gate check reads
fails `tests/ci/classify_changes_test.rb` until it is routed — and repository-root
Markdown no lane map claims falls open to every lane rather than to none, which
is the half a derived guard cannot catch because a run of everything satisfies
it (#346).

### CodeRabbit is green whether or not it reviewed anything

CodeRabbit posts a commit status of `state: success` for reviews it declined to
perform, and the bucket cannot express the difference: the status `description`
is the only place it exists. Three causes were observed on 2026-09-05, two of
them on the same commit, and they are examples rather than the whole set:
`Review skipped: manual review required for this OSS repository`,
`Review skipped: draft pull request`, and `Review rate limited`. The first is
repo-wide and stays that way for as long as the repository sits below
CodeRabbit's eligibility threshold for automatic review of open-source
repositories, so **automatic review is off here** and no pull request is read
unless somebody asks for it. Seventeen pull requests merged that day with a
green CodeRabbit leg that had reviewed nothing, and every one of them read
`pass` in the state column of `gh pr checks`.

A green CodeRabbit check is therefore not evidence that a review happened. The
description is the only field that says which it was, and nothing acts on it:
`gh pr checks` does print it, in the trailing column of its table and under
`--json description`, but beside a state that reads `pass`, and every consumer
that decides anything reads the state instead. `--watch` exits zero, the pull
request shows a tick, and a merge is not held up. So read the description on
purpose rather than expecting it to stop you:

```sh
gh api repos/yonatankarp/nas-platform/commits/<sha>/statuses \
  --jq '.[] | select(.context | test("coderabbit"; "i")) | "\(.state) :: \(.description)"'
```

Asking for a review means posting `@coderabbitai review` as a comment on the
pull request, by hand. It queues behind a rate limit, so a second request made
soon after the first waits rather than running, and a request on a draft is
skipped until the draft is marked ready.

None of this is a gate, and that is a decision rather than an oversight (#403).
Branch protection requires nothing from CodeRabbit, a skipped review has never
blocked a merge, and the checks that actually catch defects here are the
`static` gate, the `mutation` harness, the integration suites and `validate`,
all of which genuinely ran on those seventeen. A check that failed on a skipped review was
considered and rejected for this repository, because it would promote a second
opinion into a required gate; what was worth fixing was only that its absence
read as a pass. Do not reopen it as one.

### CI performance: the rules

These are the rules the `static` job's budget and the `suites` matrix were
learned at. The evidence for each -- dated occurrences, run IDs, per-check
seconds and the measurements that separated one cause from another -- is in
[docs/ci-performance-history.md](docs/ci-performance-history.md); read it before
arguing with a rule here, and add to it rather than to this file.

- **A check that spawns a subprocess per case, serially, becomes the floor for
  the whole job.** `static` is expected to finish in 10–15 minutes; its pool has
  `nproc` workers, four on a runner, and cannot finish faster than its longest
  item. Run such cases through `in_parallel_cases` in `tests/case_pool_support.rb`,
  the one copy, whose comment says why workers never exceed cores.
- **The gate prints its own slowest checks** -- wall time, total check time and
  the ten slowest, pass or fail. Read that first. The seconds it records are wall
  time under contention, so totals cannot tell total work from one check waiting.
- **`time`'s user+sys column separates a wait from work in one pair of runs.**
  A low CPU-to-elapsed ratio is a wait whatever the load; a high one proves work.
  To confirm, vary the width -- `POLICY_JOBS` for the gate's pool,
  `CASE_POOL_WORKERS` for a check's -- and a cost that does not move is a wait.
  A wait is never parallelised: find the timeout and make it an input the harness
  shortens. `POLICY_JOBS=1` serialises both pools when bisecting a load failure.
- **Extraction fixes a floor; sharding fixes a work-bound pool; which applies is a
  measurement.** Uniform slowdown across unrelated checks with a pool near full
  efficiency is work-bound, and extracting one check buys nothing. Extraction
  costs four files kept in agreement: the manifest in `tests/validate-policy.sh`,
  `tests/policy_ci_test.rb` (that the gate no longer runs it *and* CI still does),
  `tests/ci/workflow_test.rb`, and the `validate` job's `needs` and
  `validate_results.rb` arguments.
- **The `static` shards are three literal heredocs in `tests/validate-policy.sh`**,
  restated in `tests/gate_manifest_coverage_test.rb`, which asserts their union
  is the manifest both ways, no check claimed twice and a stated floor per shard.
  Adding a check means one shard in both places. No shard beats its own slowest
  check, which is why a fourth shard buys nothing; read the floor and the counts
  off the gate's report and that test's summary line, never from prose.
- **Spread the waits across shards**: a waiting check holds a worker slot without
  using CPU, so two long waits in one shard halve its pool. One run cannot confirm
  a rebalance -- runner variance is about 30% -- so ask whether the worst leg fell.
- **Budget against the gate's own printed wall**, not the job's; the difference
  tracks the toolchain install and is read off the run.
- **Pooled cases declare their block-locals** (`do |item, failures; status|`). A
  case assigning a name the script already carries shares one binding across
  threads, and a sibling's failure then reads as this case's detection.
- **Show an AST checker a real defect before trusting it**, and claim in a
  self-test only what a planted defect demonstrated. A checker that passes its own
  plants proves nothing until the plants are shown to bite.
- **The `suites` matrix has no budget** beyond `timeout-minutes: 90`, and a lane's
  clock is mostly queue: quote queue and run separately. The nightly is the only
  unconditional sweep, and its `cron` is a lower bound on when it lands.
- **`--full` keeps the single unsharded `idempotence-check`**, the only proof the
  site is idempotent as a whole; a fall-open selection runs the
  `idempotence-<n>` shards instead. `tests/idempotence_shard_partition_test.rb`
  derives the tag universe from `site.yml` and fails on any tag no shard
  converges, so that guard is derived, not a list to keep in step.
- **A guard's green is only as good as what it ran over.** An unquoted
  `[ -n $VAR ]` is true on an empty value (SC2070); read the task counts a phase
  reports, not only its verdict line.

## Security boundary

Safe to commit: Compose definitions, pinned digests, roles, the **encrypted**
vault, documentation. Never commit: the vault password, any decrypted vault
copy, rendered `.env` files, plaintext credentials, or application data. At
runtime plaintext lives in service `.env` files, the deployment poller's
`deployer.json` (since #606 it carries the two healthchecks.io ping URLs, whose
path tokens are those checks' whole authentication), Dozzle's whole data directory
(its users file, plus the dispatcher record whose `Authorization: Bearer`
header the platform POSTs in), Beszel's private key, Seerr's mode-0644
`settings.json` and the `settings.old.json` beside it, Bindery's whole
configuration root (its SQLite database keeps every credential it holds in
clear, the Audiobookshelf key it triggers library scans with included, and its
pre-upgrade backup is a copy of that database beside it), Kapowarr's
configuration root (its SQLite database holds the ComicVine key and the
administrator's salted hash, and since #671 `pre-upgrade-backup/` beside it holds
a 0600 copy of that database taken before each pinned upgrade), Nextcloud's
`config/config.php` inside its data root (the installer writes the database
password, the instance `secret` and `passwordsalt`, and the cache password into
it in clear at mode 0640, and it sits in the same `/var/www/html` tree as the
user's own documents), Karakeep's `db.db` in its data root (every account's
bcrypt password hash, which is what an offline guess is made against; API keys
are stored as a key ID beside a SHA-256 hash of their secret, and sessions are
encrypted JWTs keyed from the `NEXTAUTH_SECRET` in its `.env` with no session
row written, so a copy of the database mints no API access and no login by
itself -- all three measured against the pin; the archived pages, assets and
screenshots beside it are user data rather than credentials), and application
data — treat those and their backups as secret-bearing. Losing the vault
password means regenerating every credential; there is no backdoor.

**Since #561 the vault password lives in a second place**, and it is the only
copy outside an operator's own machine and the NAS: the `ANSIBLE_VAULT_PASSWORD`
repository secret, which the `vault` CI job writes to a file under `$RUNNER_TEMP`
so `validate-vault.yml` can open the committed vault the way the poller does.
That makes *disclosure* a failure mode beside loss, and the two cost the same
thing. Anyone who can run a workflow in this repository can read what the secret
decrypts, so re-keying is the answer to a leaked secret exactly as it is to a
lost password: regenerate every credential and re-encrypt, because the vault's
contents and not the password are what an attacker keeps. GitHub redacts a
secret's value from logs, and the play is `no_log: true` throughout, but neither
of those is a containment boundary — the boundary is who may dispatch a workflow.
`docs/secrets.md` carries the rotation steps and how the secret is set.

**A removed service does not take its files with it, and AdGuard Home is the
worked example.** #577 deleted that stack -- role, Compose, contract, lane and
the `nas_storage` entries -- but `host_prep` creates directories and never
deletes them, so `{{ nas_docker_root }}/adguard` is still on the NAS and so are
the two secret-bearing files inside it: `work/data/sessions.db`, whose bearer
tokens for the web interface make a copy of it a login, and the 0600
`AdGuardHome.yaml` beside it, which holds the administrator's bcrypt hash --
a hash rather than a secret, but still what an offline guess would be made
against. Nothing in this repository will remove either, and the service they
belonged to is no longer described here at all, so the usual route of reading
the role is gone too. `rm -rf {{ nas_docker_root }}/adguard` on the host is the
whole tidy-up; both directories are `recovery: cache`, so nothing is lost by
it. The general rule this records is that removing a service is a repository
change and leaving its data is a host one, and only the first of them happens
on merge.

**ntfy is the second worked example, and its data was not a cache.** #558
turned the stack off in stage 4a and deleted it in stage 4c -- role, Compose,
the eleven `vault_ntfy_*` credentials and `vault_managed_ntfy_users`, the lane
tag, the poller's and the prune's publisher configs and the `nas_storage`
entries -- and the same rule holds: nothing in this repository removes what it
left on the host. `{{ nas_docker_root }}/ntfy/data` was `recovery: critical`: it
holds `auth.db`, every account's bcrypt hash and every access token.
`{{ nas_docker_root }}/ntfy/cache` beside it was `recovery: cache`. The rendered
`.env` under `nas-platform/runtime/services/ntfy` carries those hashes and the
publisher tokens in clear, and the deploy account's
`~/.config/nas-platform/ntfy.curl` and `ntfy-prune.curl` each carry the deploy
publisher's bearer token at mode 0600. The operator has decided to delete all
of it rather than archive it, since nothing any longer runs that those
credentials open. Once `docker ps -a --filter
label=com.docker.compose.project=ntfy` on the NAS prints nothing, the tidy-up is,
as the deploy account:

```sh
rm -rf /volume1/Docker/nas-platform/runtime/services/ntfy
rm -rf /volume1/Docker/ntfy
rm -f "$HOME/.config/nas-platform/ntfy.curl" "$HOME/.config/nas-platform/ntfy-prune.curl"
```

**Vaultwarden is the exception the list above needs, and it is a narrow one.**
Unlike Bindery, Nextcloud, Seerr and Dozzle, whose data directories hold
readable credentials, Vaultwarden's store holds client-side-encrypted blobs: the
vault items are encrypted under keys derived from master passwords the server
never learns, so `db.sqlite3`, `attachments/` and `sends/` are not
plaintext-credential-bearing and the whole directory does not become another
"treat this as secret". Two things inside it are, and for different reasons.
`rsa_key.pem` signs every session and token the server issues — losing it logs
every client out and voids every API key, and *disclosing* it lets anyone mint
those tokens — so it is secret-bearing in the ordinary sense, which is why
`nas_storage` gives that directory 0700 rather than the 0755 every other service
takes. **The pre-upgrade copy inherits that exactly**, the way Bindery's does in
the list above: `roles/vaultwarden/tasks/pre_upgrade_backup.yml` copies the store
and `rsa_key*` into `pre-upgrade-backup/` under the same data root before a
pinned upgrade, so that directory holds a second copy of the one file in this
service that is a credential — at mode 0600 inside a 0700 parent, and treated as
secret-bearing wherever it is copied to next. And `config.json` would be, if it existed: it is written only by the
`/admin` panel, which this deployment disables by setting neither `ADMIN_TOKEN`
nor `DISABLE_ADMIN_TOKEN` — the second is the worse door, serving the whole panel
unauthenticated, and it is what Vaultwarden's own warning recommends when it
finds an empty token — and `roles/vaultwarden` asserts the file absent on every
converge because the panel being its only writer is an upstream claim rather than
something this platform can see. A `config.json` that appears is both a credential to treat as
secret and a configuration that has silently started outranking the rendered
`.env`.

That store is still the most irreplaceable data on the platform, which is a
different claim from being secret-bearing: `recovery: critical` with backup
parked means one copy, and nothing — not even the household — can reconstruct a
client-side-encrypted item from anywhere else.

**Vaultwarden also inverts the credential direction, and there it is correct.**
Every other service takes its identity from the vault and is pushed outward. A
password manager must not: master passwords are user-owned by construction, and
that zero-knowledge property is the entire reason to run it. So Ansible owns
`SIGNUPS_ALLOWED`, `INVITATIONS_ALLOWED`, `DOMAIN` and org policy, and
`roles/vault_contract` must never grow a key for a master password. **And
`SIGNUPS_ALLOWED` is `true`**, permanently, which is the one place that inversion
costs something: with no admin panel and no SMTP, a closed door leaves a fresh
database with no route to a first account at all, so registration stays open and
the tailnet is the whole of the control — anything that joins the tailnet can
register here. What makes that a perimeter rather than a wish is one Compose
line: this is the only service anyone logs in to that is published on
`127.0.0.1` rather than the wildcard, so Tailscale Serve is the only route to
the door. One other container is bound there — Beszel's `socket-proxy` sidecar,
on 2375 — and it is not a counter-example but the same decision: it publishes no
door, only a read-only Docker socket that must never leave the host, and the
Beszel hub beside it takes the wildcard like every other service. It shipped
as a wildcard and an uninvited registration from a LAN address succeeded, which
is why the binding is stated wherever the perimeter is.
`inventory/group_vars/all/service_vaultwarden.yml` carries that argument and its
cost, and `roles/vaultwarden/tasks/verify.yml` asserts the observed door against
the declared one in *both* directions on every converge, so the value is proved
rather than pushed.
`tests/expected/vaultwarden.yml` therefore carries `vault_keys: []`, which
`CREDENTIAL_FREE_SERVICES` in `tests/policy_support.rb` admits by name and in
both directions — a service listed there that *gains* a key fails as loudly as
one that lost its last. `docs/secrets.md` carries the argument in full.

**`beszel_agent` is effectively root on the host, and that was chosen (#607).**
It runs as root with host networking, `CAP_SYS_RAWIO` and `CAP_SYS_ADMIN` — the
platform's first `SYS_ADMIN` — and raw access to the three SATA bays and the
NVMe pair. The `:r` on those devices refuses a write-open and contains nothing
else: SG_IO can send WRITE through a read-only handle, and NVMe admin
passthrough reaches Format and Sanitize. It was accepted because the NVMe pair is
`/volume1`, whose `recovery: critical` data has exactly one copy, and pre-failure
S.M.A.R.T. on it was judged worth that. The containment is on the image rather
than the host: `renovate.json` withholds automerge from every Beszel image for
every update type, digest refreshes included, because a re-pushed tag arrives as
a digest and the poller would deploy it within five minutes of a merge.
`tests/renovate_policy_test.rb` holds that property.
