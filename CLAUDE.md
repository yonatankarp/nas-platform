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
on any row whose declared set has drifted. It costs what the narrowing removed,
so it is deliberately not in CI.

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
nextcloud adguard idempotence-check idempotence-1 idempotence-2
idempotence-3 idempotence-4 idempotence-5 full` — the roster
is `tests/ci/suites.conf`, and
`tests/docs_links_test.rb` fails if this list disagrees with what
`tests/integration.sh --list-suites` prints. Every service and acquisition lane
converges `ntfy` as well, because each service role reports its own deployment
there; it is not a lane of its own. The harness runs Ansible
inside a pinned Linux container against a disposable sandbox so the plays meet a
real `/proc/mounts`, real numeric uid/gid and a real Docker socket. It asserts
three properties: the run converges, a second run changes nothing, and
`--check --diff` works. Bugs that pass syntax check and lint — a fact that only
exists on Linux, a `command` task silently skipped under `--check` — are caught
only here.

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
is authored in `inventory/group_vars/all/vault.yml` and pushed outward. Nothing
is ever read back from a running service, which is why a run converges in a
single pass. Where a service would normally hand a human a generated value to
copy-paste, this platform supplies its own instead (ntfy takes declarative
users/ACLs/tokens; Beszel gets a hub keypair placed before first start).
`roles/vault_contract` validates the whole credential set, redacted, before any
target mutation — roles do not repeat that check.

**Roles are functions; `site.yml` calls them in order.** `defaults/main.yml` are
the default arguments, `meta/argument_specs.yml` is the enforced type signature
(every role needs one; every vault credential it reads belongs there as
`required: true`), `tasks/main.yml` is the body, `templates/env.j2` renders the
`.env` on the target at mode `0600`. Service name and role name may differ —
`paperless-ngx` / `paperless_ngx` — because directories use hyphens and role
names cannot. `services/manifest.yml` is the mapping.

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
Bindery, Immich, Paperless-ngx and Nextcloud each apply their own schema
migrations when they start, and each documents it beside its `image:`. That
makes a version bump one-way: the newer image writes a schema the older one
declines to open, and it declines *inside the container*, so the symptom is a
crash loop rather than a failure a play reports. #511 is what that costs — a
Bindery application **minor** migrated the store to `schema_migrations` 81, the
release went back to a pin that knew 1..80, and the host sat behind it for three
days with every converge failing at that role and the poller not advancing. Two
controls, at opposite ends. `renovate.json` withholds `major`, `minor` and
`patch` for those images **from automerge** — a digest refresh on an unchanged
tag moves no version and stays automerged — which is a wider scope than the
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
why each was rejected. Bindery is its only caller today, and the role takes the
manifest directory, the Compose service key and the project name as arguments so
the other three can adopt it unchanged.

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
the reason `services/ntfy/compose.yml` records beside that key. For the other
eleven, exiting inside ten seconds is an expectation rather than a measurement. These figures are an observation, not a budget, and nothing
validates them: if a memory policy lands (#447) the RAM figure belongs beside
`platform_container_cpu_budget` with a preflight assert against what the Docker
daemon reports, the way the logical CPU capacity already is.

**`nas_storage` in `inventory/group_vars/all/main.yml` is one source of truth for
three things**: `host_prep` creates the directories with those permissions, the
policy test requires every implemented service to declare a path naming it, and
the `recovery` class (`critical` / `user` / `cache`) drives disaster-recovery
docs. Omit `owner`/`group` under the media root — the NAS owns those files.

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

Adding a service touches 59 files and is walked end to end in
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

Jobs: `changes static docs mutation reconciliation toolchain suites validate`

Read that roster before adding a check anywhere, because `static` is not the only
job one can land in and which job it lands in is a routing decision. `mutation`
and `reconciliation` are extractions in the sense the budget history below means:
`tests/validate-policy.sh` no longer runs them, which `tests/policy_ci_test.rb`
asserts for both. The other half of the extraction rule is split: that same file
requires CI to run the mutation harness, while `tests/ci/workflow_test.rb` owns
it for the reconciliation matrix. `docs` is not — it is a second and cheaper
route to checks the gate still runs, so those checks reach a Markdown-only
change in under a minute without also reaching for the Ansible toolchain.
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
for: `static`, `docs`, `reconciliation` and three suite legs instead of all
sixteen (#395). One leg stands for the rest because the matrix is uniform and
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

### The `static` budget, and the one way it keeps being blown

`static` is expected to finish in 10–15 minutes and has blown that budget four
times. Every time the cause was the same shape, so recognise it rather than
rediscovering it:

> **A check that spawns a subprocess per case, serially, becomes the floor for
> the whole job.** `tests/validate-policy.sh` packs its checks into a pool of
> `nproc` workers, and a GitHub `ubuntu-latest` runner has four. A pool cannot
> finish faster than its longest single item, so one check that grows a case
> list grows `static` no matter how well the other hundred are packed.

The occurrences, and what actually fixed each:

- **2026-08-27** — the media acquisition reconciliation contract landed and
  `static` was cancelled at 45 minutes. Raising the budget (`65adc2f`) unblocked
  CI and fixed nothing.
- **2026-08-28** — splitting that contract into three files (`2460800`) took
  `static` from 88 to 32 minutes "and no further"; sizing the pool *down* to
  leave room made it worse. Only moving it to its own job (`fc52071`), then one
  runner per file (`b0a0152`), removed it from the gate's floor.
- **2026-08-30** — `static` was ~26 minutes, of which the `Check policy
  properties` step was 24m32s (measured from the run's step timings, not
  estimated). The dominant check was `tests/policy_manifest_test.rb`: it plants a
  defect in a throwaway copy of the repository and runs the whole eight-script
  policy set against it, once per mutation, and over 150 mutations run the full
  set. One case cost 5.5s locally, of which 3.96s was `tests/policy_integration_test.rb`
  alone — which itself spends most of its time booting Ansible twice to render
  role defaults. Fixed by running the policy set concurrently inside `run_policy`
  (5.5s → 3.45s per case) and moving the harness to its own `mutation` job. The
  gate went from 1472s to **630s wall, 2122s of check time across 107 checks on
  four workers**, with the slowest single check at 307s.
- **2026-09-03** — `static` was 20m29s and the gate printed 1086s wall, 3955s of
  check time across 147 checks. Read against the entry above that looks like the
  total-work state — 3955s over four workers is a 989s floor, the run took 1086s,
  and the slowest single check was 414s, well under it — and #319 read it that
  way. It was wrong, and the arithmetic is why: **the seconds the gate records
  for a check are its wall time while three other checks are running**, so
  contention inflates the total and the floor derived from that total in the same
  breath. Those numbers cannot tell a hundred slow checks apart from one check
  waiting. Varying the pool width can: `tests/seerr_contract_test.rb --self-test`
  took 554s at one case worker and 368s at four, eight and sixteen, while the
  same file without `--self-test` took 10s. Two of its planted regressions drop a
  `${VAR:?}` requirement from `tests/contracts/seerr.sh`, so the wrapper stops
  refusing, execs the runtime half against a port nothing is listening on, and
  spends `READY_TIMEOUT_SECONDS` there — 180 of them, twice.
  `tests/trailarr_contract_test.rb --self-test` was the same shape at 120. Fixed
  by making that budget an environment input, which is how those programs already
  take every other input, and giving the run-mode environment rows ten seconds,
  because every invocation in that helper must end in a refusal: 368s → 26s and
  247s → 27s, both still detecting all 33 planted regressions. The rest of the
  ten slowest were genuinely subprocess-per-case and went through the worker pool
  the paragraph below prescribes, sharing one `tests/case_pool_support.rb` rather
  than adding eight more copies of it — measured alone on a 12-core Mac: media
  managed users 159s → 46s, contract structure mutations 231s → 42s, Dozzle
  quality 141s → 32s, Audiobookshelf initial scan 81s → 15s, database managed
  users 70s → 17s. On that Mac at `POLICY_JOBS=4` the gate went from **922s wall,
  3134s of check time** to **492s wall, 1922s of check time** — both over the same
  148 checks, measured an hour apart before `deployment_lock_probe_test.py` and
  `deployment_lock_refusal_test.sh` landed, so a run today prints 164 and is not
  comparable check-for-check — and no converted check is in its slowest ten any
  more.
- **2026-09-07** — the gate's largest wait and its hard floor, taken together
  (#485, #488), after #486's rebalance of the same shards won nothing measurable.
  Both were found in the first uncontended per-check table this repository has
  had, and both lower the gate's *total*, which no partition can do.
  `beszel_contract_test.rb` and its `--self-test` cost ~209s of check time
  between them, of which ~171s was one hardcoded literal: `beszel-runtime.rb`
  polled persisted telemetry for 90 seconds, and exactly one row per deadline
  reaches it and can never satisfy it — a fixture serving `system_stats: []`, so
  the record stays nil and the poll runs its deadline out at 3 seconds a sleep.
  The 403/404 rows raise instead, which is why they were always cheap. Both
  budgets became `PLATFORM_BESZEL_*` environment inputs defaulted to the
  deployment's own numbers, the #319 shape: 99.6s → 19.6s and 101.5s → 31.8s.
  `config_managed_users_test.rb --self-test` was the floor at 241-305s on CI and
  87.6s alone. Its issue scoped the fix to the mutation section, which is worth
  only 17s of that 87.6s: the manifest registers the `--self-test` line, and that
  invocation runs the whole main body first, so the check's cost is ~45 serial
  Ansible fixture runs and not the mutations. Converting all of it through
  `tests/case_pool_support.rb` gave 87.6s → 19.0s at eight workers and 27.6s at
  the four a runner has.

Three things that generalise, the first of which replaces the width sweep the
fourth occurrence prescribed:

- **`time`'s user+sys column separates a wait from work in one pair of runs.**
  Sleep consumes no CPU and contention does not change that, so a low ratio of
  CPU to elapsed names a wait however loaded the machine was. The beszel pair was
  14.5s of CPU in 99.6s elapsed and 19.1s in 101.5s before the fix, and 13.9s in
  19.6s and 18.5s in 31.8s after it: the same work, the sleep gone. A width sweep
  says the same thing in six runs and is confounded by a check's own pool cap.
  The converse identifies work just as well — the managed-users conversion took
  CPU *up*, 76.1s to 107.2s, because more of it now runs at once.
- **A pooled case that assigns a name the script already carries shares one
  binding across every thread.** Ruby resolves an already-declared local outward
  rather than making a fresh one, and an `if` body opens no scope, so four cases
  writing their subprocess result into a script-level `status` were writing and
  reading one variable. The loss is silent, not loud: every mutant those cases
  run is supposed to fail, so a sibling's failing status reads as this case's own
  detection and a mutation that stopped biting is still reported as detected.
  Declaring block-locals in the parameter list (`do |item, failures; status|`)
  makes the class impossible rather than avoided. An AST dump of the script's
  local table catches a case that *adds* a name; it cannot catch one that reuses
  a name already there, which needs the other question asked — for each case, is
  every name it assigns declared somewhere on the path from the case down to that
  assignment. Position, not set membership: a nested block's declarations shadow
  only inside that block, so a rule that unions every nested scope's table lets a
  case write outward to any name a nested block happens to take as a parameter.
  That is not hypothetical — it was this checker's second defect, and it masked
  exactly `status`, `output` and `_tmp`, the names of the bug above.
- **Show an AST checker a real defect before trusting it.** The analyzer written
  to answer that second question — `tests/case_pool_locals_test.rb` — passed the
  known-buggy revision on its first attempt, carrying two mistakes at once:
  inside a block Ruby emits `DASGN`, not `LASGN`, and a multiple assignment's
  targets hang off the `MASGN`'s second child. Running it against the commit
  whose bug is known is what makes its clean report mean anything. Only the first
  of those is observable in the shipped checker, and its self-test says so rather
  than claiming both: the second was planted back in and changed no verdict,
  because the subtree walk special-cases nothing and finds those targets anyway.
  A self-test that claims more coverage than a planted defect demonstrates is the
  same vacuous pass in miniature.

The fourth occurrence's `POLICY_JOBS=4` figures are still the useful baseline,
read with the caveat that occurrence paid for: the totals are sums of contended
wall times, so they cannot separate a gate bound by its **total** work from a
gate waiting on **one** item. Ask a suspect check's CPU column first, per the
occurrence above — it costs two runs. Vary the width when you need to confirm it
— `POLICY_JOBS` for the gate's own pool, `CASE_POOL_WORKERS` or a check's own
`*_CASE_WORKERS` for a check's — and a cost that does not move when the width
does is a wait, not work. There is nothing to parallelise in a wait: find the
timeout and let the harness shorten it. For the
work half, run the cases through a worker pool — `in_parallel_cases` in
`tests/media_acquisition_reconciliation_support.rb` is the pattern and its
comment records why the worker count must never exceed the core count;
`tests/case_pool_support.rb` is the copy the checks converted for #319 share,
joined by `tests/config_managed_users_test.rb` in #488. The fourteen contract
tests still carry their own copies, so a change there is still one careful change
per file.

Two consequences worth keeping:

- **The gate reports its own slowest checks.** `tests/validate-policy.sh` prints
  its wall time, its total check time and its ten slowest checks on every run,
  pass or fail. Read that first: the first three fixes above began by timing the
  checks by hand, because the gate printed nothing about where its time went, and
  the fourth began by reading that report and then varying the pool width to find
  out which kind of cost it was naming. `POLICY_JOBS=1` serialises the pool when
  a failure only appears under load, and reaches into `case_pool_support.rb` so
  the converted checks serialise with it.
- **Extraction is the fix when one check is the floor; sharding is the fix when
  nothing is.** Once a check is the floor, it moves to its own job so it gets a
  runner's four cores to itself. That costs four files kept in agreement: the
  manifest in `tests/validate-policy.sh`, `tests/policy_ci_test.rb` (which must
  assert both that the gate no longer runs it *and* that CI still does — a check
  in neither place is a guard that silently stopped running),
  `tests/ci/workflow_test.rb`, and the `needs` and `validate_results.rb`
  arguments of the `validate` job. Which of the two fixes applies is a
  measurement, not a preference, and the fifth occurrence below is the one where
  the reflex was wrong.

### The fifth occurrence, where extraction was the wrong reflex

**2026-09-07** — `static` was at or over the ceiling on four of five runs
(16m52s, 15m39s, 19m30s, 18m01s against one 11m48s), and none of the day's merges
had added work. The distinguishing measurement is that **the slowdown was uniform
across unrelated checks**: fast run against slow run, the slowest ten went
247→333, 160→195, 152→208, 125→168, 114→191. No check had gained work, so there
was no floor to extract — extracting one would have moved a single check to its
own runner and left the other 154 exactly as slow. And the pool had no slack to
tune: 2342s of check time on four workers is a 585s floor, and it finished in
611s, 4.4% overhead. **A pool at 96% efficiency is work-bound**, so the only
levers were fewer checks or more cores.

Fixed with more cores: `static` is a matrix of three shards, each a runner with
its own four workers running part of the manifest. Three is where it stops
paying, and the reason is a floor rather than a name: no shard finishes faster
than its own slowest check however finely the rest is divided, and the slowest
check runs about 290–325s on a runner, so a fourth shard buys nothing. **Do not
re-attach that claim to a check's name.** It was written naming
`config_managed_users_test.rb --self-test` at 247s, then 305s, and #488 converted
that check to 78–113s four hundred lines earlier in this file while the sentence
went on quoting it (#517). Today's floor is `immich_release_helper_test.rb` and
it will move again; the number is what the argument rests on, and the gate's own
report is where to read it.

That floor is also the ceiling on rebalancing, which is a different quantity from
the floor and moves on its own. #484 measured a perfect three-way split as worth
about 90s against a worst observed shard wall of 394s and declined to collect it.
By #517 the worst leg was a median 436s across four `main` runs, the shards were
53/54/57 checks carrying a 2.2x spread of work, and the gate's two slowest checks
were in the same shard — so the same split was worth about 110s, twice the 59s
of run-to-run range and five times its standard deviation, and it was collected.
The lesson is that a partition balancing *count* drifts as checks are added and
made faster, because nothing in it balances *cost*; expect to re-measure rather
than to trust the last verdict.

**The guard is the point, and it was written before the partition.** Sharding is
an unusually efficient way to manufacture the defect this repository keeps
closing: drop a line from the partition and it runs nowhere, the gate goes green,
and it goes green *faster* than before. So the manifest is partitioned as three
literal heredocs in `tests/validate-policy.sh`, restated as three literal lists
in `tests/gate_manifest_coverage_test.rb`, and that file asserts their union is
the whole manifest in both directions, that no check is claimed twice, and a
floor under each shard — a stated number, because a shard that should hold fifty
checks and holds one passes every non-emptiness test there is. The runner refuses
an undeclared shard identifier and refuses an empty one, both proved in
`tests/policy_runner_test.sh`; `tests/ci/workflow_test.rb` derives the expected
matrix from the manifest, so a matrix short of the partition fails rather than
silently dropping a third of the gate. `tests/validate-policy.sh` with no
argument still runs everything, which is what to run locally, and adding a check
now means one shard of the manifest and the matching shard of the declaration.

Rebalancing the partition as checks change is a manual act, informed by the
gate's own slowest-checks report. The current split was drawn by #517 against
four post-merge `main` runs, and those figures are recorded in
`tests/gate_manifest_coverage_test.rb` beside the lists they justify. It
balances cost rather than count, which is why the shards hold uneven numbers of
checks. Read that count off the gate's own report rather than from here: it was
53/53/61 over 167 when #517 drew the split and is 55/57/61 over 173 today, and
this sentence stood at 51/52/61 through both of those, then went stale twice
more inside #548 alone -- once within one pull request of being corrected, and
again in the pull request that corrected it. Three corrections in one issue is
the evidence for reading the gate's own report instead of this line. Three things constrain a future
rebalance, all three stated beside the
lists: a check's recorded seconds are its wall time at that shard's load rather
than work that can be carried elsewhere, so an arithmetic projection from that
report overshoots; each shard's leg is a *different runner*, so the three columns
of one run are three machines and only a shard's share of its own run's total
compares across them; and **waits must be spread**, because a waiting check holds
a worker slot without consuming the CPU the other three compete for, so two long
waits in one shard halve its effective pool. #484 carries the isolated per-check
table that separates work from wait, measured 2026-09-07; #517 adds that
contention only pushes the CPU-to-elapsed ratio down, so a high ratio proves work
whatever the load while a low one on a busy machine is a lower bound and not a
verdict. One run also cannot confirm a rebalance: shard-level runner variance is
around 30%, so read two or three and ask whether the *worst* leg fell.

The job wall exceeds the gate wall the report prints by 122 to 154 seconds
(mean 139) — checkout, tooling and collection install — so budget against the
gate's own figure rather than the job's.

### The suites carry no such budget, and their clock is mostly queue

Everything above is about `static`. **The `suites` matrix has never had a stated
budget** and carries `timeout-minutes: 90`; reading the 10–15 minutes at it is a
category error that has already been made once. What it does have is a shape
worth knowing before optimising anything, measured on the nightly sweep
`34454075921` of 2026-09-10 — 29 jobs, 246 runner-minutes, 45.2 minutes of run
wall:

- **A lane's elapsed time is mostly waiting to start.** Every suite leg queued
  12–18 minutes before it ran; `smoke` was 16.5 queued against 19.4 running and
  `idempotence-check` 12.4 against 20.6. Even `changes`, first in the run with
  nothing ahead of it, queued 4.7 minutes, which only happens when the account is
  already saturated — that morning the nightly was *created* at 08:14:15 and the
  merge run for #542 at 08:14:00. Peak concurrency across the overlapping runs
  was exactly 20. So quote a lane as queue and run separately, or the number
  names GitHub's scheduler rather than anything in this repository.
- **The nightly is the only unconditional sweep.** A push to `main` classifies
  the merge it landed, so it is routed like any pull request: the #544 merge ran
  four suite legs. `--full` comes from `schedule` and `workflow_dispatch` only.
  Deleting the nightly would leave nothing running the whole matrix against a
  tree no routing decision chose.
- **A `cron` is a lower bound on when the sweep lands, not a time.** GitHub has
  *created* this workflow's scheduled runs 4h21m to 5h22m after the cron on each
  of the last ten days, and 12h06m once (2026-08-28). At `23 3 * * *` that was
  07:44–08:45 UTC every day, squarely in the merge window; the cron is now
  `47 17 * * *`, which lands it at 22:08–23:09 under those delays, at 05:47 under
  the worst one observed, and at 17:47 if the delay ever disappears. Choosing an
  hour whose whole plausible fire window misses 07:00–10:00 UTC is the property;
  the hour itself is not. Check it rather than trusting it:
  `gh run list --workflow=ci.yml --event=schedule --json createdAt`.

Two costs were found inside a lane and both are fixed; the shape of each is the
part worth keeping.

- **The image pre-pull was serial.** `prepull_images` in `tests/integration.sh`
  ran one `docker pull` at a time: 272 seconds of `smoke`'s 1151 and 270 of
  `idempotence-check`'s 1222 — 33 images each, about 22% of the two longest
  lanes — and 18.5 runner-minutes across the run. It now fetches
  `image_pull_width` at once, defaulting to four and bounded like every other
  budget beside it, through `INTEGRATION_IMAGE_PULL_WIDTH`. Concurrency costs one
  property: under a rate limit the serial loop stopped at the refusing image, and
  a batch can now overshoot it by `image_pull_width - 1` pulls.

  **Four wide bought 26%, not 75%, and a wider one would buy less.** Measured on
  run `34467333883`: the same fourteen lanes went from 1112 seconds of pre-pull to
  828, and smoke's two longest-lane siblings from 272 and 270 to 200 and 192. The
  concurrency is not the part that fell short — smoke's completion timestamps show
  eight clean bursts of four — the arithmetic is. A runner pulls at a fixed network
  throughput, so overlapping pulls recovers per-request latency and leaves the
  bytes where they were. This is the shape to expect from any I/O-bound fan-out
  here, and it is why the width is capped at eight rather than left open.
  `tests/integration_suite_test.sh` asserts the width in both directions through a
  rendezvous in its `docker` stub rather than a clock, because a peak of four
  proves nothing unless a width of one is still observable as one.
- **`toolchain` no longer waits for `changes`.** Every lane's start is that job's
  finish, and it was spending 2.6 minutes of eighteen lanes' time to order a
  registry probe behind a classification: `changes` finished at 4.8 minutes, the
  toolchain job started at 7.4, and its publish step took **0 seconds** because
  the tag is a digest over the harness's own pins and was already published. The
  `suites != '[]'` term went with the edge, which is the whole cost: a run that
  dispatches no suite now probes too, and that probe is the same 0 seconds unless
  the pins changed — and a pin change routes to the suites anyway.

### The untagged idempotence lane is sharded; the tagged one never needed to be

`idempotence-check` converges the whole site, re-converges it and runs it under
`--check --diff`, so it costs three full passes and is the critical path of any
run that dispatches it untagged. Measured on run `34471042365`, which queued for
one second and so is nearly pure run time: **32.3 minutes**, against a
next-longest job of 16.5 and a run wall of 32.5. The lane *was* the run.

Its 1939 seconds divide as 189 setup and image pre-pull, 850 phase 1, 548 phase 2
and 348 phase 3. Read that before proposing a target: **deleting phases 2 and 3
outright still leaves about 17 minutes**, and a *routed* run of the same lane —
one service, 1289 task-results against 4280 — measured 13.05 minutes on run
`34464098157`. Both bound it from below, and 10 minutes is under both. The lane
is task-count-bound rather than hot-spot-bound: phase 3 does no container work at
all and still costs 324ms per task-result, which is the same slope phase 1 pays.
There is nothing to extract.

So the fix is the `static` one — more runners — with the difference that the
partition is over *site.yml tags* rather than over a check list, and that only
the untagged form is sharded:

- **A routed run was never the problem.** It already narrows to the changed
  service and lands at 8–14 minutes. It still dispatches the single
  `idempotence-check` and is untouched.
- **An unmapped path falls open to the shards.** That is the case that hurt: on
  2026-09-10, 8 of 29 `idempotence-check` jobs ran untagged, and every one of
  them was 32–37 minutes. Both sampled causes were legitimate rather than routing
  misses — one pull request changed `tests/integration.sh` and
  `tests/integration_controller.sh`, which are the harness every lane runs, and
  the other added a service and touched `site.yml`, `services/manifest.yml` and
  the vault schema. There was no one-line route to add. Four of the eight were
  pushes to `main`, which classify the merge they landed and inherit the cause.
- **`--full` keeps the single unsharded pass.** The nightly and
  `workflow_dispatch` are where nothing is waiting on the answer, and they are
  now the only place the site is proved idempotent *as a whole*. A role in one
  shard interfering with a role in another is invisible to every shard. That is
  the property the decomposition spends, and it is why it is spent where a
  35-minute job costs nobody anything.

`--full` is therefore no longer literally every lane, and that is the one
exception to it: the two forms cover the same ground by different routes, so
running both would converge the site six times to learn what three converges
already said. `everything(selection, sharded:)` in `tests/ci/classify_changes.rb`
is where the fork lives, and it is at the two `return` sites rather than threaded
through as a mode.

**The guard came before the partition, for the reason the static shards record.**
Sharding manufactures the defect this repository keeps closing: drop a tag and
nothing converges it, every shard passes, and the gate goes green *faster*.
`tests/idempotence_shard_partition_test.rb` derives the tag universe from
`site.yml`'s own roles and post_tasks and fails on any tag no shard converges, in
both directions, with a stated shard count under it. It is **derived** rather
than restated on purpose: adding a service already touches 59 files, and a
sixtieth list would be the one nobody edits. What it deliberately does *not*
assert is exclusivity — `arr` appears in more than one shard because seerr reads
it and jellyfin, so a prerequisite converges wherever it is needed. Duplication
costs time; omission costs coverage, and only one of those is silent. What it
also does not check is that a rebalance keeps a service *with* its prerequisites;
that failure is loud at runtime rather than silent, so it was left, and
`suites.conf`'s own service rows are already the dependency declaration a future
guard would read.

That guard's own `--self-test` is worth reading before writing another one. Its
first three plants were bare substring edits — `",immich\n"`, `",komga\n"`,
`"ntfy,beszel"` — and every one landed on the *service* row of the same name,
which appears earlier in `suites.conf`, so `sub` mangled a row the checker does
not read and the self-test reported three defects undetected. A checker that
passes its own plants has proved nothing until the plants are shown to bite.

**`smoke` binds the fall-open wall, and that caps what this change can buy.** A
fall-open selection turns `foundation` on, which empties `selected_tags`, which
sends the smoke leg down the untagged branch of the workflow's `case "$SUITE"` —
so smoke converges the whole site: 16.5 minutes on `34471042365` and **19.1 on
`34514486089`**, where it was the longest-running job in the run and every shard
beat it.
The wall of a fall-open run is therefore `max(slowest shard, 16.5)`, not the
shard wall. Smoke is a strict prefix of this lane — same workflow branch, same
arguments, `exit 0` at the line where phase 2 begins — and its routing is a
subset, so it proves nothing this lane does not. Reclaiming that leg is the next
move, and it costs edits to `suites.conf`, `classify_changes.rb`,
`tests/ci/workflow_test.rb`, `tests/policy_ci_test.rb` and the roster above.

**Measured on run `34514486089`, the first that dispatched them.** The shards
ran 14.1, 9.9, 9.7, 9.9 and 7.5 minutes, so the projected 14–16 held at the top
and was pessimistic everywhere else. Each converged real work and then reported
`changed=0`: phase 1 changed 43, 37, 19, 28 and 30 things against phase-1 task
counts of 697, 547, 375, 521 and 500. The run wall fell from 32.5 minutes to
**24.1**.

Two projections in the paragraph this replaces were wrong, and the shape of the
error is worth more than the numbers. The repeated prerequisites were estimated
at about 860 task-results per shard from the corrupted per-role table; the five
shards actually run 2640 phase-1 results against the unsharded lane's 1649, which
puts the repetition nearer **250** per shard — so the asymptote is around 6
minutes rather than the 10 claimed, and more shards would still buy something.
(The two runs are different trees, one before AdGuard and one after, so read that
as a magnitude and not a figure.) The estimate came from a table this file
already documents as unreliable, which is precisely the trap: a projection built
on data known to be corrupt reads exactly like a measurement once it is written
down.

**Queue is now a visible term.** `idempotence-1` finished last at 18:50:01
despite running only 14.1 minutes, because it did not start until 18:35:54 — the
matrix grew by four legs against an account that peaked at exactly 20 concurrent
jobs, so some of the shard win converts into waiting rather than into wall.

**The shards are numbered rather than named, and the split balances estimated
cost.** The three heavyweights by the phase-1 role table — paperless at 120.5s,
immich at 104.8 and jellyfin at 102.8 — have to land in three different shards,
and no honest category groups them that way: the first split put paperless,
nextcloud and immich together as "documents" at roughly 229s against 58 for the
lightest, a 3.9x spread in the one direction that sets the wall. Numbering makes
a rebalance free, which matters here because a named partition that stops
matching its names is the same stale claim this file has had to correct twice
already. The current spread is about 1.3x.

**The split is provisional and its weights are estimates rather than measurements.** The only
per-role timings available are corrupted: with `display_skipped_hosts = False`
the default callback prints no banner for a fully skipped task, so every visible
gap in the log absorbs the skips after it, and a task that reads 26 seconds can
be a loop measured at 1.5ms an item. Rebalance from the first sharded run's own
numbers the way #517 rebalanced the static shards, and read the caveats there
about contended wall times first. `ANSIBLE_DISPLAY_SKIPPED_HOSTS=true` passed
into the harness's `docker run` is the one-line way to make the log self-timing
when somebody needs real numbers; it is not set today.

### A guard that was green while proving 6% of what it claimed

`tests/integration_controller.sh` read `[ -n $INTEGRATION_TAGS ]` unquoted. On an
empty value that is `[ -n ]` — POSIX's one-argument `test`, true because the
string `-n` is non-empty (SC2070) — so the *untagged* path took the *tagged*
branch and ran `ansible-playbook --tags ""`, which selects only the `always`
pre_tasks. On nightly run `34454075921` phase 1 reported `ok=1495 changed=115`
and phases 2 and 3 reported `ok=88` each, then printed `IDEMPOTENT: second run
changed nothing` and `CHECK MODE OK`. The harness's other two promises were being
proved over 88 of 1495 tasks on every nightly and every `--full` push to `main`,
while the same lane under narrow routing was correct.

Three things about it generalise:

- **The bug was known and its consequence was not.** `tests/integration_controller_execution_test.sh`
  named the SC2070, pinned the behaviour deliberately rather than the correct one,
  and said it was waiting for the fix; the shellcheck exclusion listed the code.
  Nothing anywhere connected that to what the nightly was actually asserting. A
  defect with an owner and a comment is not a defect with a measurement.
- **Correct is slower.** A phase 2 that re-converges all 1495 tasks costs
  550–720 seconds and phase 3 another 420–580, so `idempotence-check` on a full
  run goes from ~20 minutes to roughly 35–45 — measured at 33.4 on run
  `34467333883`, whose phases now report `ok=1556` and `ok=1075` against the 88
  each of them reported before. The `suites` budget went from 60 to
  90 for it, because a lane killed at its ceiling would read as the fix
  regressing rather than as the guard working, and because the pre-pull's own
  retry ladder can add another five minutes on a rate-limited image. Any future
  reading of "the suites are slow" has to start after that, not before it.
- **`perform_initial_converge` was accidentally right, which is not the same as
  right.** Its `[ -z $INTEGRATION_TAGS ]` degenerated identically and happened to
  land on the branch that was already correct, so no plant can prove its quoting;
  the case comment says so rather than implying coverage a plant does not give.

## Security boundary

Safe to commit: Compose definitions, pinned digests, roles, the **encrypted**
vault, documentation. Never commit: the vault password, any decrypted vault
copy, rendered `.env` files, plaintext credentials, or application data. At
runtime plaintext lives in service `.env` files, Dozzle's whole data directory
(its users file, plus the dispatcher record whose `Authorization: Bearer`
header the platform POSTs in), Beszel's private key, Seerr's mode-0644
`settings.json` and the `settings.old.json` beside it, Bindery's whole
configuration root (its SQLite database keeps every credential it holds in
clear, the Audiobookshelf key it triggers library scans with included, and its
pre-upgrade backup is a copy of that database beside it), Nextcloud's
`config/config.php` inside its data root (the installer writes the database
password, the instance `secret` and `passwordsalt`, and the cache password into
it in clear at mode 0640, and it sits in the same `/var/www/html` tree as the
user's own documents), AdGuard Home's `work/data/sessions.db` (bearer tokens
for the web interface, so a copy of it is a login; its `AdGuardHome.yaml`
beside it holds the administrator's bcrypt hash rather than a clear password,
which is a hash and not a secret but is still what an offline guess would be
made against), and application
data — treat those and their backups as secret-bearing. Losing the vault
password means regenerating every credential; there is no backdoor.
