# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

Ansible is the **only** control plane for an ASUSTOR AS6704T NAS running fifteen
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
script — one bare command per line, asserted by `tests/policy_test.rb` and
`tests/policy_manifest_test.rb`. **Do not wrap or prefix those lines**; doing so
silently disables the guards while leaving the script working. `POLICY_JOBS=1`
restores serial order when bisecting a load-dependent failure.

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

### Integration suites

```sh
tests/integration.sh --list-suites
tests/integration.sh --suite <lane> site.yml
tests/integration.sh --describe-suite <lane>   # prints the pinned suite/tags/scenarios line
```

Lanes: `foundation arr downloaders bindery kapowarr pinchflat trailarr seerr
smoke beszel dozzle audiobookshelf komga jellyfin immich paperless
idempotence-check full` — the roster is `tests/ci/suites.conf`, and
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

**Container CPU policy.** Production containers are pinned to logical CPUs `0-2`
of four, each with a workload-specific 0.5–3.0 CPU ceiling. Ansible derives and
validates the effective CPU set before deployment and checks Docker's applied
set and quota after each stack starts. Change the budget only in
`inventory/group_vars/nas_hosts/main.yml`.

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
- Every implemented service has either a verification task — name containing
  `verify`/`verification`, tag `platform_verify_<service>`, and either a `uri`
  task naming the service with `status_code:` or an `assert` whose every
  condition compares against such a registered result — or an executable
  `tests/contracts/<name>.sh` registered in `tests/contracts/registry.yml`.
  A `debug` named "verify" satisfies nothing.

Idempotence is a hard requirement: mark reads `changed_when: false`, and
`check_mode: false` where a read must really run during `--check`. Use
`community.docker.docker_compose_v2` rather than shelling out — a shell-out
always claims a change and cannot simulate itself.

Tasks touching credentials carry `no_log: true`.

Adding a service touches 57 files and is walked end to end in
[docs/adding-a-service.md](docs/adding-a-service.md) — including the two pinned
Ruby name lists, the files CI routing must agree on, and the ten places a new
vault credential lands (`docs/secrets.md` among them, enforced by
`tests/secrets_docs_test.rb`). Both figures come from the guide, which measured
56 against the Pinchflat promotion and keeps a ledger of the per-service
obligations added since; `tests/docs_links_test.rb` fails when this sentence and
that ledger disagree. Adding an obligation means adding a ledger row, not
bumping a number here.

## CI

`.github/workflows/ci.yml` classifies the diff with
`tests/ci/classify_changes.rb` into a `static` job and a matrix of integration
`suites`, then `tests/ci/validate_results.rb` decides pass/fail across all legs.
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
  `deployment_lock_refusal_test.sh` landed, so a run today prints 150 and is not
  comparable check-for-check — and no converted check is in its slowest ten any
  more.

That last measurement is the useful baseline. Read it with the caveat the fourth
occurrence paid for: the totals are sums of contended wall times, so they cannot
separate a gate bound by its **total** work from a gate waiting on **one** item.
Vary the width before believing either — `POLICY_JOBS` for the gate's own pool,
`CASE_POOL_WORKERS` or a check's own `*_CASE_WORKERS` for a check's — and a cost
that does not move when the width does is a wait, not work. There is nothing to
parallelise in a wait: find the timeout and let the harness shorten it. For the
work half, run the cases through a worker pool — `in_parallel_cases` in
`tests/media_acquisition_reconciliation_support.rb` is the pattern and its
comment records why the worker count must never exceed the core count;
`tests/case_pool_support.rb` is the copy the checks converted for #319 share. The
fourteen contract tests still carry their own copies, so a change there is still
one careful change per file.

Two consequences worth keeping:

- **The gate reports its own slowest checks.** `tests/validate-policy.sh` prints
  its wall time, its total check time and its ten slowest checks on every run,
  pass or fail. Read that first: the first three fixes above began by timing the
  checks by hand, because the gate printed nothing about where its time went, and
  the fourth began by reading that report and then varying the pool width to find
  out which kind of cost it was naming. `POLICY_JOBS=1` serialises the pool when
  a failure only appears under load, and reaches into `case_pool_support.rb` so
  the converted checks serialise with it.
- **Extraction is the fix, tuning is not.** Once a check is the floor, it moves
  to its own job so it gets a runner's four cores to itself. That costs four
  files kept in agreement: the manifest in `tests/validate-policy.sh`,
  `tests/policy_ci_test.rb` (which must assert both that the gate no longer runs
  it *and* that CI still does — a check in neither place is a guard that
  silently stopped running), `tests/ci/workflow_test.rb`, and the `needs` and
  `validate_results.rb` arguments of the `validate` job.

## Security boundary

Safe to commit: Compose definitions, pinned digests, roles, the **encrypted**
vault, documentation. Never commit: the vault password, any decrypted vault
copy, rendered `.env` files, plaintext credentials, or application data. At
runtime plaintext lives in service `.env` files, Dozzle's whole data directory
(its users file, plus the dispatcher record whose `Authorization: Bearer`
header the platform POSTs in), Beszel's private key, Seerr's mode-0644
`settings.json` and the `settings.old.json` beside it, and application data —
treat those and their backups as secret-bearing. Losing the vault password
means regenerating every credential; there is no backdoor.
