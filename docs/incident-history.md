# Incident history

The evidence behind rules in `CLAUDE.md`: the incidents that produced them, the
measurements they rest on, and the reasoning that was weighed and rejected. It
was moved out of `CLAUDE.md` by #838, in the same way
[ci-performance-history.md](ci-performance-history.md) was by #652.

This file never restates a rule. Each section names the `CLAUDE.md` section that
states the rule, and carries only what that section no longer says. Every figure
below is a reading on the date it names, not a statement about the tree today.
Add evidence here rather than to `CLAUDE.md`.

## The default inventory and the toolchain lock

Rule: `CLAUDE.md`, *What this repository is* and *Commands*.

`ansible.cfg` used to name `inventory/remote.yml`, so a bare
`ansible-playbook site.yml` converged the live NAS. With no default,
`platform_hosts` matches nothing, and the run ends on an empty `PLAY RECAP`
having touched no host.

The lock is universal and hashed on every entry. Transitive versions exist only
in the generated lock and move only when it is recompiled. The command in the
lock's header is also what Renovate's `pip-compile` manager runs.

## The policy gate manifest and mutation fixtures

Rule: `CLAUDE.md`, *The test ladder* and *Running one test*.

Three things hold the manifest, and they hold different amounts:
- `tests/gate_manifest_coverage_test.rb` makes a prune show up as a visible diff
  rather than as a quieter gate, but nothing in it exercises the check itself.
- `tests/policy_ci_test.rb` and `tests/policy_test.rb` each give the reason
  every line they require has to keep running.
- `tests/policy_manifest_test.rb` proves that deleting one of those lines is
  caught.

Until #469, about forty lines were required by nothing at all. Deleting any one
of them left every check green, and the gate got faster.

`--audit` costs what the narrowing saved. That was about half an hour on a runner
before its rows were pooled, which is why only the nightly and
`workflow_dispatch` run it (#727).

`BASE_FIXTURE_PATHS` is stated rather than derived on purpose. A sandbox built
from whatever happens to be on disk would stop proving that a check reads the
file it claims to read. When a file is left out of the list, the check that reads
it crashes instead of running. The symptom misleads because `expect_success`
reports only the first line of the combined output of every policy script it
ran.

## What the integration harness proves

Rule: `CLAUDE.md`, *Integration suites*.

The harness runs in a Linux container so the plays meet a real `/proc/mounts`,
real numeric uid/gid and a real Docker socket. The `roles/deployment_bundle`
fall-open exists because the deployment report every service role sends lives
there. Every selection that carried `smoke` also ran `idempotence-check` or, on
a fall-open, the `idempotence-<n>` shards, which is why CI stopped dispatching
it (#832).

## The upgrade lane

Rule: `CLAUDE.md`, *Integration suites*, the `upgrade` bullets.

Every other lane builds a disposable sandbox, `host_prep` creates the service
directories empty, and the service initialises fresh. So every lane takes the
fresh-install path, and nothing anywhere opens a store a previous version wrote.
That is the whole class #511 and #671 fell into, invisible by construction until
#773. Bindery and Kapowarr are the subjects because they are the two with actual
incidents.

**Why the inputs, tags and refusals are shaped as they are.**
- The base cannot be read from inside the lane. The `suites` job checks out at
  `actions/checkout`'s default depth of 1, unlike `changes`, `static`,
  `mutation` and `reconciliation`.
- `selected_tags` is the union of every tagged lane, and a fall-open empties it.
  An empty value would send this lane down the untagged branch and converge the
  whole site twice for a one-service proof.
- `deployment_bundle` keys its immutable release on `platform_release_id`.
  Rewriting `compose.yml` without moving HEAD therefore hits the "release
  `current` already points at" refusal instead of repinning.
- A subject with no seed program is refused because a lane that converges,
  migrates and asserts nothing is green while proving less than the
  fresh-install lanes it exists to complement.
- The four-edit list is written out because the sentence that introduced it used
  to claim one edit.

**Why a fall-open still dispatches it.** A fall-open already runs every suite
leg, so one more is marginal. Forcing the lane off there made it undispatchable
on every pull request that also touched an unmapped path, including the one that
introduced it.

**One subject per run.** Renovate is unlikely to move two subjects' pins in one
diff. #771's batch group excludes Kapowarr. It has included Bindery only since
#781, when Bindery's automerge hold came off and it rejoined the batch. So a
batch can now move Bindery's pin, but Kapowarr's never travels with it. A
hand-written pull request bumping both would prove only one of them.

**Why it ends on the exit code (#781).** This is the shutdown half of #671. A
patch whose migration was correct shipped a handler that raised, and every stop
was waited out to Docker's SIGKILL: 30.46s and exit 137 on the NAS. The first
report came from Dozzle's `die` rule after the poller had deployed it. 137 is
128+SIGKILL and means exactly "the grace expired". The value is measured rather
than read off `stop_grace_period`, for the reasons in
[Container memory and stop behaviour](#container-memory-and-stop-behaviour).

Two limits sit under that:
- The **base** container's stop is unobservable, because Compose removes it
  inside the same recreate.
- This would have caught #671 only by luck. That raise needed a task at the head
  of the queue that had been created and never started. `services/kapowarr/tasks.py`
  shows `_process_queue()` starts `queue[0]` inside every `add()`, so an
  unstarted head exists only in the window between a finishing task's `pop(0)`
  and its `_process_queue()`. Upstream reproduced it with 300 concurrent
  submissions.

What it does cover deterministically is this regression class:
- a PID 1 with no handler;
- an ignored `STOPSIGNAL`;
- a handler that hangs;
- a carried patch that has stopped applying to the image it is mounted over.

**Why a rollback stays red.** A revert makes the base newer than the head, so the
second converge meets `roles/image_downgrade_guard`. The lane then goes red on
the pull request that is the *correct* fix for a bad migration, with a message
about that guard rather than the store. Comparing versions across arbitrary tags
is exactly what that role exists to do, so a direction check in the classifier
would be a second, worse copy of it. `validate` aggregates the `suites` result
and is the required check on `main`, and the repository-admin bypass on that
ruleset is `always`. Merging past the lane therefore costs the same as merging
past any other red leg.

## The poller and hand-run converges

Rule: `CLAUDE.md`, *Deploying / reviewing*.

**#326.** A manual converge ran past one five-minute tick. The poller repointed
`current` under it while it was still converging services, and the run died at
its *last* role on a containment guard reporting an unsafe deployment target.
The lock refusal that now prevents this used to be mistaken for an integrity
refusal. A holder that recorded no identity is tolerated because of #327.

**#327.** It added a guard to `deployment_bundle` that refused a lock whose
holder wrote no record, and it shipped the record-writing poller in the same
commit. On the NAS the old poller took the lock and wrote nothing. `site.yml`
refused after 38 seconds, the install play never ran, and every five-minute tick
afterwards failed the same way: the upgrade deadlocked on itself. It was
recoverable only because the poller checks out the candidate revision and runs
the plays from that checkout, so the fix merged to `main` healed the host on the
next tick with nobody touching it.

**Why the poller scripts stay single files.** Each is installed by an
`ansible.builtin.copy` of exactly one file, from the target's own checkout. A
script that arrived without its shared module would die at `import`, before any
handler could report it. Ordering the copy tasks does not close that gap: an
operator running the install play from a checkout older than the module would
install the importing script from a role that has no task for the module.
`services/dozzle/alert_relay.py` runs inside a container, where a module in the
deploy account's home is not reachable at all. The copies of `_write_private`
once drifted until one fsynced without repairing the mode and the other repaired
the mode without fsyncing. Each carried the bug the other had fixed (#354).

## Argument specs and loop variables

Rule: `CLAUDE.md`, *Architecture*.

Validation runs before any loop binds, so the failure is reported from the
variable's definition site rather than from the task that would have used it.
That is what makes it hard to recognise. Leaving the option undeclared works
because lazy templating then resolves it per item at the point of use. `is
defined` fails in the worse direction. Evaluating it templates the value, the
undefined `item` raises inside that, and the test swallows the error and reads
*false*. The guard then refuses a parameter that is perfectly well defined, and
reports the parameter rather than the loop as the problem.
`q('varnames', ...)` matches variable *names* without resolving them, the way
`roles/vault_contract` already collects the managed-user lists.

## Self-migrating images and one-way pins

Rule: `CLAUDE.md`, *Architecture*.

**#511.** A Bindery application **minor** migrated the store to
`schema_migrations` 81. The release then went back to a pin that knew 1..80, and
the host sat behind it for three days: every converge failed at that role and
the poller did not advance.

**Why Bindery automerges and Kapowarr does not (#781).** Bindery's pin is as
one-way as the rest. What changed is that the `upgrade` lane now runs #511's
exact failure mode on the pull request that proposes the bump: base pin, seeded
row, repin, migrate, read back, and a clean stop. Kapowarr stays withheld
although the lane can take it as a subject, because it never has been one: every
real execution has been Bindery, and #671's shutdown race is uncovered for both.

Immich's all-update-types rule is wider than the database-major rule beside it,
deliberately.

**Why the merge and not the pull request.** The database-major and
Nextcloud-major rules used to carry `dependencyDashboardApproval` until they were
converted to `automerge: false`. Immich's Postgres carried `enabled: false`: it
was the one dependency in this repository that no pull request could ever reach.
Both refusals in `tests/renovate_policy_test.rb` are proven against planted
defects.

## Container memory and stop behaviour

Rule: `CLAUDE.md`, *Architecture*, the memory and grace-period paragraphs.

**Measured 2026-09-08.** The NAS has 16 GB of RAM, which Docker reports as
15.4 GiB.
- The thirty running containers held 4.9 GiB between them. The largest were
  Jellyfin at 785 MiB, `immich_server` at 595 MiB and SABnzbd at 484 MiB.
- Host memory sat at 27%, with PSI reporting about 1% stall.
- The two workloads that could be large, Immich's ML container and Jellyfin
  transcoding, read 93 MiB and 785 MiB, because they are bursty rather than
  resident.
- Swap is 2 GB and was entirely consumed at a swappiness of 60: about 2.4 GB
  paged out over 23 hours of uptime, which is a trickle and not pressure.

Those figures predate two changes to the file-sync stack. Seafile was gated off
at the time; #499 turned it on and #501 removed it. Nextcloud replaced it (#500),
so its four containers are not in these numbers either, and a PostgreSQL cluster
plus a PHP application is the workload most likely to move them.

**The memory controls.**
- `paperless_tika` got `mem_limit` because it is a JVM and sized its own heap off
  the host without one (#447).
- Page cache dominates the per-container high-water marks, so a limit on an
  I/O-heavy container would cap its cache rather than a leak.
- `/sys/fs/cgroup/memory/memory.memsw.limit_in_bytes` exists despite cgroup v1
  and no `swapaccount=1`, so both controls are available whenever one is wanted.

**The alerts.**
- Beszel warns above 90% of host memory sustained for ten minutes.
- Dozzle's `oom` rule names the container. Whether it fires for a host-level
  kill on a container with no limit set is untested. It is cgroup-scoped by
  construction, so it probably cannot report one.
- The `die` rule stopped excluding exit 137 in #493, so an OOM kill pages
  whatever the `oom` rule does. The deliberate stops that exclusion protected
  stay quiet regardless, because a stop inside its grace period exits 0 or 143,
  and both are still excluded.

**Twelve services take the default grace.** They are long-running services in
`services/*/compose.yml`, none of them a database or a cache. Both Beszel agents
are among them (a host runs at most one). The `configarr` job is not, because it
exits on its own.

**`alert-relay`.** It ran Python as PID 1 with no SIGTERM handler, and PID 1 is
the one process the kernel applies no default signal disposition to.
- The stop was discarded and Docker SIGKILLed it: 10.14s and exit 137, on every
  recreation. It paged through the container that had just exited, which
  therefore could not deliver the page.
- #516 blocks both stop signals before any thread exists and waits for one with
  `sigwait`. A raising signal handler cannot do that reliably: socketserver
  swallows an exception raised while it dispatches a request, and a raising
  handler was observed losing a stop that way once in eight attempts.
- Measured again after the fix: 0.61s and exit 0, while `docker kill -s KILL`
  still exits 137, which keeps a host-level OOM kill reportable.
- Interpreter start-up is still unprotected, before the process blocks anything.
  `init: true` would close that gap and was not taken, for the reason
  `services/dozzle/alert_relay.py` records beside its stop handling.

**`nextcloud-cron`, measured 2026-09-12.** It declared a 30s grace and still
exited 137 on every recreate. Two independent problems each swallow the stop:
- Its image is the application's, so it carries php:apache's
  `STOPSIGNAL SIGWINCH`, a signal whose default disposition is to be ignored.
- `/cron.sh` execs busybox crond as PID 1, which installs no handler.

This is the second reason to reach for an init shim, besides the process reaping
that `init: true` was originally reserved for.

## Why nas_storage is composed

Rule: `CLAUDE.md`, *Architecture*, the `nas_storage` paragraphs.

Nineteen media paths belong to no service: seven `recovery: user` library roots
in `media_libraries.yml` and twelve `recovery: cache` staging paths in
`media_acquisition.yml`. They sit in two files because the recovery class drives
the disaster-recovery documentation, and one file would mix what can be rebuilt
with what cannot. `tests/nas_storage_support.rb` is the only reader because a
sixtieth list of contributors is the one nobody edits.

- `hostvars` is undefined while group_vars are still being assembled, so the
  varnames/vars pair is the only supported form, not a style choice.
- `host_prep` loops in order, and `ansible.builtin.file` applies a declared mode
  to an intermediate parent only when it creates it. A leaf reached before its
  root therefore leaves that root holding the umask. A lexicographic path sort
  puts every parent first, because a parent path is a prefix of its children.
- Measured 2026-09-12: deleting every contributor leaves `nas_storage` as `[]`,
  and the play reports `ok`.
- `q('varnames')` reads whatever is in scope when it evaluates. A
  `nas_storage_*` variable in a role default would join the composition partway
  through a run, and `nas_storage` would then mean different things in different
  places.

## Policy conventions

Rule: `CLAUDE.md`, *Conventions the policy test enforces*.

**Tag precision.** Jellyfin's three-part `10.11.11` could never be offered the
two-part `12.1`. It sat unproposed from 2026-09-08 until the 12.1 bump, while
the dependency dashboard listed it as detected with no update available.

A sweep on 2026-09-24 found Jellyfin was the only pin in that state. Docker Hub
pins were compared by tag shape against the registry's own tag list, which is
the check that detects this. The ghcr and lscr pins were compared against
upstream GitHub *releases* instead, which only answers whether a newer version
exists at all. Pinchflat is where the two methods diverge. It is three months
behind upstream, yet neither frozen by this rule nor fixable here, because its
`v2025.9.26` release was never pushed to ghcr, where `v2025.6.6` is still the
newest tag.

**Self-sizing memory (#447).** `MEMORY_SELF_SIZING_IMAGES` is stated because a
Compose file does not say what runtime an image holds. Tika satisfies the rule
with a limit alone, letting the JVM derive its heap from that limit rather than
from the host's RAM, which it used to do.

**Release-mount labels (#810).** Docker resolves a bind-mount source once, when
the container starts. A container that Compose has no reason to recreate keeps
the inode from whichever release was current then, while `current` moves on.
#810 found SABnzbd executing a four-day-old `clamav_gate.py`, and nothing
compared the two. Only a changed *definition* causes a recreate. The label is
keyed on content because the stale inode matters exactly when the bytes differ,
and recreating on every release would interrupt an active download for a merge
that changed nothing here. The subject set is derived from the volumes, and an
ordinary refactor can empty it silently.

**`docker_compose_v2_exec` (#521).** Twelve tasks paired a missing `failed_when`
with `changed_when: true`, asserting a change they never verified.
`failed_when` replaces the module's own failure verdict and re-enables
`changed_when`. Refusals that set no `rc` include an unreadable `project_src`, a
non-string `env` value and a Compose that is too old. Under the `no_log` these
tasks carry, such a refusal shows as a green line and nothing else.

## CI jobs and routing

Rule: `CLAUDE.md`, *CI*.

**`docs`.** It lets the checks it carries reach a Markdown-only change in under a
minute, without installing the Ansible toolchain.

**`vault` (#559).** It is the one job the local gate cannot hold. #559 failed
`validate-vault.yml`, the play the poller runs first, on every five-minute tick
while every check here stayed green. The gate's own check on that file,
`tests/policy_vault_test.rb`, asserts only that the artifact is still encrypted,
and it needs no password. A skip-with-notice for forks was considered and
refused, because it is a green run that decrypted nothing. `pull_request_target`
would run this job with the base repository's secrets against a head its author
controls.

**`lint` (#653).** Its checks used to run once per `static` shard, three times
per pull request, all charged to the budgeted job; the measurement is in
[ci-performance-history.md](ci-performance-history.md). An `if:` on each step was
the obvious trim. It is refused because it is #469's silent-coverage-loss shape.
The three single-command checks beside them moved into the manifest instead.

**`renovate-config-validator` (#775).** #775 stopped Renovate opening pull
requests repository-wide, its own dependency updates included. The cause was a
`renovate.json` that parsed and satisfied every property
`tests/renovate_policy_test.rb` asserts, so only Renovate's own validator could
have caught it. It is npm's program and resolves `extends` presets over the
network, which rules it out of the manifest. Its pin is the only version literal
in `ci.yml` that is not an action SHA, and a custom manager tracks it.

**Classification of a push.** A push to `main` classifies the merge it landed
(`github.event.before`, falling back to the first parent) rather than sweeping
the repository a second time. Each push is keyed on its own commit because its
run is the only one that will ever see the tree it merged. A shared group
serialises merges, and GitHub holds at most one *pending* run per group, so a
third merge cancels the waiting run before it starts a single job. That is a
different failure from cancelling an in-flight run, and disabling in-flight
cancellation does not prevent it. Repeat `workflow_dispatch` runs of one commit
are the remaining shared group, and evicting a run there takes three of them.

**The workflow file (#395).** It defines the jobs rather than being read by
them, so it is routed for job coverage: `static`, `docs`, `vault`,
`reconciliation` and two suite legs. One leg can stand for the rest because the
matrix stays uniform under test:
- `tests/ci/workflow_test.rb` executes the suites job's `case "$SUITE"` for
  every suite.
- `tests/ci/classify_changes_test.rb` fails unless each job's
  `needs.changes.outputs.*` gate is turned on by its route.

The matrix size once sat in prose as a literal, through sixteen and then
seventeen, while a full run dispatched more than either. #652 removed those
copies.

**Documentation (#346).** The document routing is derived from the registered
checks. Root Markdown falls open to every lane, which is the half a derived
guard cannot catch, because a run of everything satisfies it.

## CodeRabbit

Rule: `CLAUDE.md`, *CodeRabbit is green whether or not it reviewed anything*.

Observed on 2026-09-05: three causes, two of them on the same commit. They are
examples rather than the whole set:
- `Review skipped: manual review required for this OSS repository`
- `Review skipped: draft pull request`
- `Review rate limited`

The first is repo-wide. It stays that way while the repository sits below
CodeRabbit's eligibility threshold for automatic review of open-source
repositories.

Seventeen pull requests merged that day with a green CodeRabbit leg that had
reviewed nothing. Every one read `pass` in the state column of `gh pr checks`,
which prints the description only in its trailing column and under
`--json description`. `--watch` exits zero, and the pull request shows a tick.

A second review request made soon after the first waits behind the rate limit.
A request on a draft waits until the draft is marked ready.

A check that failed on a skipped review was considered and rejected, because it
would promote a second opinion into a required gate (#403). The defect-catching
checks are `static`, `mutation`, the suites and `validate`, and all of them
genuinely ran on those seventeen.

## The vault password as a repository secret

Rule: `CLAUDE.md`, *Security boundary*.

Since #561, the `ANSIBLE_VAULT_PASSWORD` secret is the only copy of the password
outside an operator's machine and the NAS. The `vault` job writes it to a file
under `$RUNNER_TEMP`. That makes *disclosure* a failure mode beside loss, and the
two cost the same, because the vault's contents are what an attacker keeps.
GitHub redacts the value from logs, and the play is `no_log: true` throughout,
but neither is a containment boundary. The boundary is who may dispatch a
workflow.

## Vaultwarden, socket proxies and beszel_agent

Rule: `CLAUDE.md`, *Security boundary*; the full Vaultwarden argument is in
[secrets.md](secrets.md).

**Vaultwarden's store.** The vault items are encrypted under keys derived from
master passwords the server never learns. `db.sqlite3`, `attachments/` and
`sends/` therefore bear no plaintext credentials, unlike the data directories of
Bindery, Nextcloud, Seerr and Dozzle.
- Losing `rsa_key.pem` logs every client out and voids every API key.
  *Disclosing* it lets anyone mint those tokens.
- Every other service's directory takes 0755; this one takes 0700.
- The pre-upgrade copy sits at 0600 inside a 0700 parent.
- `config.json` is asserted absent because the admin panel being its only writer
  is an upstream claim, not something this platform can see.
- `DISABLE_ADMIN_TOKEN` is what Vaultwarden's own warning recommends when it
  finds an empty token.
- Nothing, not even the household, can reconstruct a client-side-encrypted item
  from anywhere else.

**Signups.** With no admin panel and no SMTP, a closed signup door leaves a fresh
database with no route to a first account at all. So anything that joins the
tailnet can register. The service shipped with a wildcard binding, and an
uninvited registration from a LAN address succeeded.
`inventory/group_vars/all/service_vaultwarden.yml` carries that argument and its
cost.

**Beszel's socket proxy.** It is on port 2375. The internal network it shares is
shared with the portable agent alone, and the hub takes the wildcard like every
other service. The proxy refuses writes but still serves every container's
environment, and with it every rendered `.env` value, to any process on the NAS
(#829).

**`beszel_agent` (#607).** It runs as root with:
- host networking;
- `CAP_SYS_RAWIO` and `CAP_SYS_ADMIN`, the platform's first `SYS_ADMIN`;
- raw access to the three SATA bays and the NVMe pair.

SG_IO can send WRITE through a read-only handle, and NVMe admin passthrough
reaches Format and Sanitize. It was accepted because the NVMe pair is `/volume1`,
whose `recovery: critical` data has exactly one copy, and pre-failure S.M.A.R.T.
on it was judged worth that risk. The automerge hold covers digests because a
re-pushed tag arrives as a digest, and the poller would deploy it within five
minutes of a merge. `lscr.io/linuxserver/socket-proxy` in the Beszel and Dozzle
stacks mounts the Docker socket, so it is root on the host by another route
(#828). No Compose file here uses a variable socket source or a parent-directory
mount.
