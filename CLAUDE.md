# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Rules only: what to do, what not to do, and a line of why. Evidence goes in
[docs/incident-history.md](docs/incident-history.md) and
[docs/ci-performance-history.md](docs/ci-performance-history.md), host runbooks
in [docs/host-cleanup.md](docs/host-cleanup.md) — never here.

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

`ansible.cfg` deliberately names no default inventory, so a bare
`ansible-playbook site.yml` matches no host rather than converging the live NAS.
Always pass `-i`.

## Commands

Ansible tooling is authored in `controller-requirements.in` and installed from
`controller-requirements.txt`, the hash-locked output of `uv pip compile` (CI and
the poller use `--require-hashes`); collections in `requirements.yml`. Versions
live in the `.in` alone: never restate one in prose (`tests/docs_links_test.rb`
refuses it here, `tests/policy_test.rb` in the beginner guides) and never edit the
lock by hand — re-run the command in its header (#827). The lock keeps the `.txt`
path because the poller that runs is the previously installed one (#327).

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

`tests/validate-policy.sh` runs every unit check concurrently from a literal
manifest, one bare command per line, declared both ways by
`tests/gate_manifest_coverage_test.rb` (so a check is added or removed in two
places) and required line by line by `tests/policy_ci_test.rb` and
`tests/policy_test.rb` (#469). **Do not wrap or prefix those lines**; doing so
silently disables the guards while leaving the script working. `POLICY_JOBS=1`
restores serial order when bisecting a load-dependent failure.

### Running one test

Any line of `tests/validate-policy.sh` is a runnable single test, e.g.
`ruby tests/komga_library_reconciliation_test.rb`. Tests that must run under
Ansible's own interpreter use `"$ansible_python"`: read the `python version = ...
(path)` field of `ansible-playbook --version`. Several Ruby tests accept
`--self-test`, which proves the test itself detects a planted regression.

Run `ruby tests/policy_manifest_test.rb --audit` after adding a check to a policy
script: each mutation row runs only the policy scripts it declares, and `--audit`
runs all eight and fails on a row whose declared set has drifted. Only the
nightly and `workflow_dispatch` run it (#727), so drift reds the nightly a day
late rather than the pull request that caused it.

A new file that a policy check *reads* goes in `BASE_FIXTURE_PATHS` in
`tests/policy_mutation_support.rb`; the mutation sandbox copies only that stated
list, deliberately, so nothing derives the entry for you. The symptom of the
omission is every `expect_success` row going red at once, usually printing
another script's success line rather than the crash naming the missing path.

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
`tests/integration.sh --list-suites` prints. `smoke` and `full` are local-only:
smoke is a prefix of `idempotence-check`, and a whole-site single-play converge
runs only in the nightly `--full` (#832). Every service lane also converges
`host_prep` and `deployment_bundle`, whose changes fall open to every lane. The
harness runs Ansible in a pinned Linux container against a disposable sandbox and
asserts converge, a no-change second run, and a working `--check --diff`. Bugs
that pass syntax check and lint — a fact that only exists on Linux, a `command`
task silently skipped under `--check` — are caught only here.

**`upgrade` is the only lane that can see a migration (#773)**: it converges the
base branch's pin of one service, seeds rows, repins to the head image, converges
again and reads them back ([why](docs/incident-history.md#the-upgrade-lane)).

- **Subject and base pin are inputs, not tags** (`INTEGRATION_UPGRADE_SERVICE`,
  `INTEGRATION_UPGRADE_BASE_IMAGE`, emitted by `tests/ci/classify_changes.rb`,
  refused rather than clamped), and **its tags come from an `upgrade_tags`
  output**, never `selected_tags`; the workflow refuses an empty value.
- **A repin is two commits**, not two file writes: `deployment_bundle` refuses
  to mutate a release `current` already points at.
- **Subjects are derived** from `tests/contracts/<svc>-upgrade.rb` (Bindery and
  Kapowarr today); there is no shared seeder to build. **Adding a third subject
  is four edits**:
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
- **Only a missing base revision switches it off** (`--full`, `--files`); a
  fall-open that moved a subject's pin dispatches it. **One subject per run**,
  the first in `UPGRADE_SUBJECTS` order.
- **It ends by stopping the head container (#781)**: exit 137 fails, 0 and 143
  pass; nothing is asserted on the clock.
- **A rollback reds this lane by design**: `roles/image_downgrade_guard` refuses
  the older head. Add no direction check to the classifier; merging past it takes
  the admin ruleset bypass.

### Deploying / reviewing

**The NAS deploys itself.** `roles/production_auto_deploy` installs a poller that
converges the newest CI-released `main` **every five minutes** under an flock. A
hand-run `ansible-playbook` takes no lock and races it (#326), so on the NAS
converge through the launcher, which takes the poller's lock and passes
everything after `--` to `ansible-playbook`. It runs the controller checkout's
own `.venv` `ansible-playbook` from inside that checkout (#902), so relative
paths resolve there, and it prints the checkout's HEAD first: that is the
revision the poller last left it at, so read it before trusting the run. The
launcher is not on the login PATH; use its full path:

```sh
$HOME/.local/bin/nas-platform-deploy --converge -- -i inventory/local.yml site.yml --check --diff --ask-vault-pass
$HOME/.local/bin/nas-platform-deploy --converge -- -i inventory/local.yml site.yml --ask-vault-pass
$HOME/.local/bin/nas-platform-deploy --status   # what the poller last did, and what it would do next
$HOME/.local/bin/nas-platform-deploy --verify   # verify.yml against the deployed revision; cron runs it hourly
```

From a workstation the plays still run over SSH, and these two cannot hold a lock
that lives on the NAS:

```sh
ansible-playbook -i inventory/remote.yml site.yml --check --diff --ask-vault-pass
ansible-playbook -i inventory/remote.yml site.yml --ask-vault-pass
ansible-playbook -i inventory/local.yml verify.yml --tags platform_verify_<name>
```

`deployment_bundle` probes that lock at every role's first task, check mode
included, and refuses with *"A deployment is already running on this host"*: a
scheduling conflict, not an integrity refusal. Wait and re-run once. A holder
that recorded no identity is tolerated.

**`site.yml` must never depend on anything `install-production-auto-deploy.yml`
installs.** The poller runs `validate-vault.yml`, `site.yml`, `verify.yml`, and
only then the install play, so every play meets the *previously* installed
poller: anything a new play needs on the target must tolerate its absence for one
deployment, or be installed by `site.yml` itself (#327). The poller runs the
candidate's own checkout, so a fix merged to `main` heals the host on the next
tick; a broken `site.yml` is never a reason to change anything by hand on the NAS.

**`scripts/production_auto_deploy.py` and `scripts/image_prune.py` stay single
files**: a shared module that failed to land would kill them at `import` on every
tick, beyond any merge's reach. `services/dozzle/alert_relay.py` mirrors the same
helpers; `tests/policy_test.rb` keeps the copies of `_write_private` identical,
because divergence is the harm (#354).

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
is authored in the encrypted vault under `inventory/group_vars/all/`
(`vault_<role>.yml` with its `vault_managed_<role>_users`, `vault_pushover.yml`,
`vault_healthchecks.yml`) and pushed outward. Nothing is ever read back from a
running service, which is why a run converges in a single pass. Where a service
would normally hand a human a generated value to copy-paste, this platform
supplies its own instead (Beszel's hub keypair). `roles/vault_contract` validates
the whole set, redacted, before any mutation — roles do not repeat that check.

**Roles are functions; `site.yml` calls them in order.** `defaults/main.yml` are
the default arguments, `meta/argument_specs.yml` is the enforced type signature
(every role needs one; every vault credential it reads belongs there as
`required: true`), `tasks/main.yml` is the body, `templates/env.j2` renders the
`.env` on the target at mode `0600`. Service and role names may differ —
`paperless-ngx` / `paperless_ngx` — and `services/manifest.yml` is the mapping.

**Never declare an option whose value templates over a loop variable**, a
task-scoped register or a fact the role sets later: argument validation templates
every declared option at role entry and fails with `'item' is undefined`. Leave
it undeclared and assert its presence with `q('varnames', '^<name>$')` — never
`is defined`, which reads *false* on a perfectly defined per-item value
([why](docs/incident-history.md#argument-specs-and-loop-variables)).

**The target never runs against this checkout.** `roles/deployment_bundle`
installs an immutable release at `platform_current_dir`, rendered secrets under
`platform_runtime_dir`. Every service role's first task re-includes it with
`tasks_from: target` and `deployment_target_require_current_release: true`,
naming what it will touch: `deployment_target_service` is the **manifest service
directory** (`paperless-ngx`, not `paperless_ngx`), from which the release
directory, both Compose files, the runtime directory and its `.env` are derived,
and `deployment_target_extra_paths` is anything more (`[]` when nothing); naming
a service the role does not deploy fails the run. Read
`platform_service_compose_files`; never restat an override yourself.

**`verify.yml` is structurally incapable of converging**: every role is
`tags: [never]`, so only tasks tagged `platform_verify_<service>` run.

**Compose definitions are portable**: `${NAS_DOCKER_ROOT:?}` /
`${NAS_MEDIA_ROOT:?}`-derived variables, never absolute paths, and the `:?` makes
an unset value fail loudly instead of creating a relative bind mount. Overrides
in `services/<name>/compose.<kind>.yml` add devices, mounts and profiles; **an
`image:` key in one must equal the canonical `compose.yml` image exactly**
(`tests/policy_test.rb`, no allowlist) — simplest is to omit it. **Compose
project names are derived** from `platform_project_name`, so a sandbox can run
several copies side by side.

**A pin is not freely reversible where the container migrates its own store.**
Each such image says so beside its `image:`, and
`SELF_MIGRATING_APPLICATION_IMAGES` in `tests/renovate_policy_test.rb` is where
that set is authored — read it instead of a list here. The older image declines
the newer schema *inside the container*, so a rollback shows as a crash loop
rather than a failed play (#511). `renovate.json` withholds `major`, `minor` and
`patch` for those images **from automerge**; a digest refresh on an unchanged tag
stays automerged, except Immich, which its own manual-coupling rule withholds for
every update type. **Bindery is the exception (#781)**: the `upgrade` lane proves
its minors and patches, so they automerge on a green lane and its majors wait for
a human. Kapowarr stays withheld
([why](docs/incident-history.md#self-migrating-images-and-one-way-pins)).

**Every rule here withholds the *merge*, never the pull request, and that is now
enforced rather than conventional.** `tests/renovate_policy_test.rb` refuses
`dependencyDashboardApproval` and `enabled: false` anywhere in `renovate.json`:
withholding the pull request is a decision nobody gets to make, because nothing
raises the dashboard row again. The pull request is the notification.

Immich's Postgres is the instructive one, because replacing `enabled: false`
took a **version ceiling** rather than a plain enable. Its extension versions
are coupled to the Immich schema, and the registry publishes higher majors under
the *identical* suffix — so a plain enable proposes a major, an on-disk format
change Ansible cannot migrate, offered as though it were routine.
`allowedVersions` admits only the pinned major while leaving the dependency
enabled, so the digest refresh on an unchanged tag — which moves no version,
breaks no coupling, and is how that tag's Postgres minors arrive — opens a pull
request where it used to be invisible. The pin no longer copies Immich's own
compose (#839): upstream still ships a pgvecto.rs tag whose builds stopped, so
its digest froze, and this one is a maintained build bounded by the ranges the
pinned server enforces at startup. The ceiling is raised by hand in the pull
request that performs the next major's dump and restore, whose procedure is
[docs/immich-postgres-17-cutover.md](docs/immich-postgres-17-cutover.md); nothing
tests the ceiling's value. Renovate never proposes a newer VectorChord or
pgvector for it either, because that is a suffix change — the tag-shape trap
described under the policy conventions below. And `roles/image_downgrade_guard`, included by a
service role before its backup and its Compose deployment, reads the image
reference Docker recorded for that service's own containers, running or not, and
refuses a pin older than one that has already run. It compares image versions
rather than schema versions because the schema lives in a store only the
application can open; the role names the three routes to the real version and
why each was rejected. **Every self-migrating image is guarded, and that is
enforced rather than conventional (#826)**: `tests/renovate_policy_test.rb`
derives the call sites from `roles/*/tasks`, requires one on the Compose
service running each image in `SELF_MIGRATING_APPLICATION_IMAGES`, and refuses
a call guarding anything else unless `DOWNGRADE_GUARD_EXCEPTIONS` names it --
Bindery, whose pin is still one-way though the set no longer withholds it, and
Vaultwarden, whose call site records a second reason, a CVE floor under the pin
that this guard does not read. `EXPECTED_DOWNGRADE_GUARD_CALLS` beside them is
the stated floor, and it is what to read instead of a list here. Immich,
Paperless-ngx and Nextcloud adopted it only there, after #784 and #797 had
already moved two of those pins with nothing refusing a way back.

**Container CPU policy.** Containers are pinned to logical CPUs `0-2` of four,
each with a 0.5–3.0 CPU ceiling, validated before deployment and checked against
Docker after each stack starts. Change the budget only in
`inventory/group_vars/nas_hosts/main.yml`.

**Container memory has no policy, by decision, and headroom is the only reason
that has been safe.** Only a runtime that sizes its
own memory gets `mem_limit` (#447); nothing declares `memswap_limit` or
`deploy.resources`, because a limit would cap page cache rather than a leak.
Dozzle's `die` rule pages on exit 137 (#493), so a host-level OOM kill is
reported. If a memory policy lands, the RAM figure goes beside
`platform_container_cpu_budget` with a preflight assert against Docker. The
dated measurements are an observation, not a budget, and are stale — take a
fresh one ([measurements](docs/incident-history.md#container-memory-and-stop-behaviour)).

**A container must stop inside its grace period.** Databases and caches declare a
`stop_grace_period` well above Docker's ten-second default. A PID 1 with no
SIGTERM handler, or an ignored `STOPSIGNAL`, is SIGKILLed at the end of the grace
(exit 137): `alert-relay` (fixed by #516) and `nextcloud-cron`. **Declaring a
grace period is not evidence of stopping inside one**; `init: true` with
`stop_signal: SIGTERM` answers both. Of the twelve long-running services on the
default, `alert-relay` is the one measured; for the other eleven, exiting inside
ten seconds is an expectation rather than a measurement.

**`nas_storage` is one source of truth for three things**: `host_prep` creates the
directories with those permissions, the policy test requires every implemented
service to declare a path naming it, and the `recovery` class (`critical` /
`user` / `cache`) drives disaster-recovery docs. Omit `owner`/`group` under the
media root — the NAS owns those files.

**It is composed, and `main.yml` is not where a service's settings go.**
`inventory/group_vars/all/` holds `main.yml` for cross-cutting facts, one
`service_<role>.yml` per service (settings *and* storage), and
`media_libraries.yml` / `media_acquisition.yml` for unowned media paths, so
adding a service adds one file:

```yaml
platform_storage_names: "{{ q('varnames', '^nas_storage_') | sort }}"
nas_storage: "{{ q('vars', *platform_storage_names) | flatten(levels=1) | sort(attribute='path') }}"
```

Do not simplify that back: the `vars` dictionary is **removed in ansible-core
2.24**; the path sort makes `host_prep` create parents before children; and an
empty composition is silent, so `host_prep` asserts a collapse floor and
`tests/nas_storage_support.rb` (the one Ruby reader) holds contributors against
`services/manifest.yml`, with `SHARED_CONTRIBUTORS` and `STORAGE_FREE_SERVICES`
closed both ways. **Nothing outside `inventory/group_vars/all/` may define a
`nas_storage_*` variable** (`tests/policy_test.rb`;
[why](docs/incident-history.md#why-nas_storage-is-composed)).

Custom Ansible code lives in `library/` (modules), `module_utils/` and
`filter_plugins/`, wired through `ansible.cfg`. Note `inject_facts_as_vars =
False`: write `ansible_facts[...]`, never bare `ansible_*` variables.

## Conventions the policy test enforces

`ruby tests/policy_test.rb` is the fast feedback loop — make a change, run it,
fix what it names by its own words. It enforces, among others:

- Images pinned as `repo:1.2.3@sha256:<64 hex>` — a readable tag and a
  manifest-list digest. Take the top-level `Digest:` from
  `docker buildx imagetools inspect`, not a per-platform entry. **Write the tag at
  the precision upstream publishes its releases at, and nothing checks this.**
  Renovate offers a docker tag only at the precision and suffix of the current
  value, so a pin is silently unupdatable the moment upstream changes tag shape:
  a dashboard row with no `→ Updates:` beside it *looks* exactly like a current
  pin. Compare tag shape against the registry's own tag list, not upstream
  releases ([cases](docs/incident-history.md#policy-conventions)).
- No `build:`, no `privileged: true`, `restart: unless-stopped`, `json-file`
  logging with both `max-size` and `max-file`.
- Volume sources are `${VARIABLE:?}` references; a literal `/volume1/...` is
  rejected.
- A container on an image whose runtime sizes its own memory declares
  `mem_limit`, and a container declaring a JVM heap declares a limit at least
  twice it. `MEMORY_SELF_SIZING_IMAGES` is the stated list and
  `EXPECTED_SELF_SIZING_CONTAINERS` pins its reach both ways; Tika is the only
  member (#447). Nothing declares a heap yet, so four mutations in
  `tests/policy_manifest_test.rb` are that half's only proof.
- A container that bind-mounts a file out of `${PLATFORM_CURRENT_DIR:?}` carries
  a label holding that file's own sha256, keyed on content rather than release
  id, so a changed file recreates the container instead of leaving it on a stale
  inode (#810). `EXPECTED_RELEASE_MOUNT_CONTAINERS` pins its reach both ways.
- Every implemented service has either a verification task — name containing
  `verify`/`verification`, tag `platform_verify_<service>`, and either a `uri`
  task naming the service with `status_code:` or an `assert` whose every
  condition compares against such a registered result — or an executable
  `tests/contracts/<name>.sh` registered in `tests/contracts/registry.yml`.
  A `debug` named "verify" satisfies nothing.
- A `community.docker.docker_compose_v2_exec` task that is not `detach: true`
  states `failed_when`, because the module checks rc only when detached (#521);
  `failed_when: false` satisfies it, so a task that tolerates failure says so.
  The rc default is `1`, not `0`: a module that refuses before it runs sets no
  `rc`, and `default(0)` would report that refusal as a successful change.

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

Which job a check lands in is a routing decision
([why](docs/incident-history.md#ci-jobs-and-routing)):

- `mutation` and `reconciliation` are extractions: the gate no longer runs them
  and CI must, which `tests/policy_ci_test.rb` and `tests/ci/workflow_test.rb`
  assert. `docs` is a cheaper second route to checks the gate still runs.
- `vault` decrypts the vault with the `ANSIBLE_VAULT_PASSWORD` secret and runs
  `validate-vault.yml` (#559); no manifest line corresponds to it and none
  should. A fork's pull request reds it deliberately — no
  skip-with-notice — and the workflow stays on `pull_request`, never
  `pull_request_target`.
- `lint` runs once what cannot vary by shard (#653); `tests/ci/workflow_test.rb`
  refuses an `if:` on any `static` step, which would silently run a third as often.
- A check goes in the manifest if the repository owns the program, and in a
  `lint` step if it does not. `renovate-config-validator` is the example (#775):
  its step plants #775's `matchPackageNames` and requires it still rejected.

`static`, `reconciliation` and `suites` are matrices; `validate` names each once
because `needs.<job>.result` aggregates its legs. A pull request classifies its
base/head diff, a push to `main` the merge it landed, and the nightly,
`workflow_dispatch` and a baseless push request `--full`. **Routing fails open**:
an unmapped path runs every lane, costing time rather than correctness. The
workflow file is routed for one leg of every job (#395); read the suites matrix
size off `tests/ci/classify_changes.rb --full`, never from prose. Any other file
under `.github/` falls open. Only a pull request cancels its superseded runs;
each push to `main` keeps its own concurrency group. `tests/ci/workflow_test.rb`
pins the workflow's shape.

Documentation is routed, not inert. This file is itself a gate input —
`tests/policy_test.rb` sweeps it for retired declarations and
`tests/docs_links_test.rb` checks the lane roster and the stack count above
against the tree — so editing it selects `static` and `docs`. A `docs/` file a
gate check reads fails `tests/ci/classify_changes_test.rb` until routed, and
unclaimed root Markdown falls open to every lane (#346).

### CodeRabbit is green whether or not it reviewed anything

CodeRabbit posts `state: success` for reviews it declined, and automatic review
is off here, so **a green CodeRabbit check is not evidence that a review
happened**. Only the status `description` says which; read it on purpose:

```sh
gh api repos/yonatankarp/nas-platform/commits/<sha>/statuses \
  --jq '.[] | select(.context | test("coderabbit"; "i")) | "\(.state) :: \(.description)"'
```

Ask for a review by commenting `@coderabbitai review`; it is rate limited and
skipped on a draft. It is deliberately not a gate (#403) — do not reopen it as
one ([observations](docs/incident-history.md#coderabbit)).

### CI performance: the rules

The rules the `static` budget and the `suites` matrix were learned at. The
evidence -- dated occurrences, run IDs, per-check seconds -- is in
[docs/ci-performance-history.md](docs/ci-performance-history.md); read it before
arguing with a rule here, and add to it rather than to this file.

- **A check that spawns a subprocess per case, serially, becomes the floor for
  the whole job.** `static` is expected to finish in 10–15 minutes on `nproc`
  workers (four on a runner) and cannot beat its longest item. Run such cases
  through `in_parallel_cases` in `tests/case_pool_support.rb`, the one copy.
- **The gate prints its own slowest checks** -- wall time, total check time and
  the ten slowest. Read that first; its seconds are wall time under contention.
- **`time`'s user+sys column separates a wait from work**: a low CPU-to-elapsed
  ratio is a wait. Confirm by varying `POLICY_JOBS` or `CASE_POOL_WORKERS`; a
  cost that does not move is a wait. Never parallelise a wait: find the timeout
  and make it an input the harness shortens. `POLICY_JOBS=1` serialises both pools.
- **Extraction fixes a floor; sharding fixes a work-bound pool; which applies is a
  measurement.** Extraction costs four files kept in agreement: the manifest in
  `tests/validate-policy.sh`, `tests/policy_ci_test.rb` (that the gate no longer
  runs it *and* CI still does), `tests/ci/workflow_test.rb`, and the `validate`
  job's `needs` and `validate_results.rb` arguments.
- **The `static` shards are three literal heredocs in `tests/validate-policy.sh`**,
  restated in `tests/gate_manifest_coverage_test.rb` (union equals the manifest,
  no check twice, a floor per shard). Adding a check means one shard in both
  places. A fourth shard buys nothing; read floors and counts off the gate's
  report and that test's summary line, never from prose.
- **Spread the waits across shards**: a waiting check holds a worker slot. Runner
  variance is about 30%, so judge a rebalance by whether the worst leg fell.
- **Budget against the gate's own printed wall**, not the job's.
- **Pooled cases declare their block-locals** (`do |item, failures; status|`), or
  threads share one binding and a sibling's failure reads as this case's.
- **Show an AST checker a real defect before trusting it**, and claim in a
  self-test only what a planted defect demonstrated.
- **The `suites` matrix has no budget** beyond `timeout-minutes: 90`; quote queue
  and run time separately. The nightly is the only unconditional sweep, and its
  `cron` is a lower bound on when it lands.
- **`--full` keeps the single unsharded `idempotence-check`**, the only proof the
  site is idempotent as a whole; a fall-open runs the `idempotence-<n>` shards,
  whose coverage `tests/idempotence_shard_partition_test.rb` derives from `site.yml`.
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
screenshots beside it are user data rather than credentials; since #826
`pre-upgrade-backup/` beside it holds a 0600 copy of `db.db` and `queue.db`
taken before each pinned upgrade, which carries the same hashes and is exactly
as secret-bearing), the `pre-upgrade-backup/database.sql.gz` that Nextcloud and
Paperless-ngx write beside their PostgreSQL clusters before each pinned upgrade
(#826: a whole-database dump holding every account's password hash, and for
Paperless its mail account passwords in clear too, root-owned 0600 in a 0700
directory), Nextcloud's `pre-upgrade-backup/code.tar.gz` beside that dump
(#884: its data root minus `data/`, so `config.php` in clear, same modes), and application
data — treat those and their backups as secret-bearing. Losing the vault
password means regenerating every credential; there is no backdoor.

**The vault password also lives in the `ANSIBLE_VAULT_PASSWORD` repository
secret (#561)**, so a leaked secret is answered as a lost password is: regenerate
every credential and re-encrypt (`docs/secrets.md` has the steps).

**A removed service does not take its files with it**: `host_prep` never deletes,
so retired data stays on the NAS until an operator removes it
([docs/host-cleanup.md](docs/host-cleanup.md) has AdGuard, #577, and ntfy, #558).

**Vaultwarden's store is client-side encrypted, but `rsa_key.pem` signs every
token**, so its directory is 0700 and the `pre-upgrade-backup/` copy is
secret-bearing. Keep `/admin` off by setting neither `ADMIN_TOKEN` nor
`DISABLE_ADMIN_TOKEN` (the second serves it unauthenticated); `roles/vaultwarden`
asserts `config.json` absent — one that appears is a credential and a
configuration outranking the rendered `.env`. Credentials flow the other way here: master
passwords are user-owned, so `roles/vault_contract` must never grow a key for one
and `tests/expected/vaultwarden.yml` carries `vault_keys: []`
(`CREDENTIAL_FREE_SERVICES`, both ways). **`SIGNUPS_ALLOWED` is `true`**, so the
tailnet is the whole control: it is the only login service published on
`127.0.0.1`, so Tailscale Serve is the only route to it, and that binding is
asserted both ways on every converge and stated wherever the perimeter is. `docs/secrets.md` has the full
argument; its one copy (`recovery: critical`, backup parked) is irreplaceable.

**A Docker socket proxy must never leave the host**: it serves every container's
environment (#829). Beszel's is on `127.0.0.1` only because host-networked
`beszel_agent` cannot join its internal network; the hub has no route to it. `SOCKET_PROXY_CONSUMERS` in `tests/policy_test.rb` states who
may share its network in `compose.yml`, and refuses an override of that stack
declaring networks.

**The Dozzle alert relay is the third `127.0.0.1` publication, for golem**:
Dozzle's hub pushes the relay's URL and bearer header to golem's agent, which
dispatches from golem. golem maps `alert-relay` to the NAS's tailnet address, and
a Tailscale Serve TCP forward on `dozzle_alert_relay_port`
(`roles/dozzle/tasks/serve.yml`) hands the connection to the loopback port, so the
tailnet reaches the relay, the LAN does not, and the bearer token is still its
authentication. Serve, not a bind to the tailnet address, because that address
may not exist when Docker starts the container at boot. The relay sends events
from host `golem` on the Golem Pushover application.

**`beszel_agent` is effectively root on the host, by choice (#607)**: `:r` on its
devices refuses a write-open and contains nothing else, and `:ro` on
`docker.sock` restricts nothing at the Docker API. The containment is on the
image: `renovate.json` withholds automerge, digests
included, from every Beszel image and every image mounting
`/var/run/docker.sock` (#828), a set `tests/renovate_policy_test.rb` derives and
holds both ways — so mount the socket by its literal path. Detail:
[docs/incident-history.md](docs/incident-history.md#vaultwarden-socket-proxies-and-beszel_agent).
