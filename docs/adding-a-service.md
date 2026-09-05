# Adding a service

This guide assumes you can read Python and have never written Ansible. It walks
through adding one service to the platform, using Navidrome as a worked example
that was actually run against this repository's checks.

Read [Ansible concepts used here](ansible-basics.md) first if the words *role*,
*play* and *inventory* are new. This guide is about the mechanics of adding a
service on top of those concepts.

It is not about the service. What the image actually contains, what a fresh
install does before anyone configures it, and which of its API calls are safe to
repeat are questions only that service can answer, and answering them wrongly
costs more than any registry on this page. The
[service investigation dossiers](service-dossiers.md) are what that investigation
looks like when it has already been done.

## The mental model, in Python terms

A **role** is a function. `roles/komga/` is one function named `komga`, and
`site.yml` is the script that calls every function in order.

`roles/<name>/defaults/main.yml` holds the default arguments. `meta/argument_specs.yml`
is the type signature, and it is enforced: a missing or wrongly typed variable
fails before the first task instead of halfway through with a stack trace.
`tasks/main.yml` is the body. `templates/env.j2` is an f-string that renders a
real file on the target machine.

The important difference from a Python function is that tasks are **declarative
and idempotent**. A task states the end state, not the steps to reach it, and
running it twice must report a change only the first time. The test harness
enforces this by converging twice and requiring `changed=0` on the second run.
This is why deployment goes through `community.docker.docker_compose_v2` rather
than a shell command: a shell-out always claims a change and cannot simulate
itself under `--check`.

You do not need to know Ruby. The tests are written in Ruby, and you will edit a
dozen or so of them, but every edit is the same edit: a literal list of service
names, a literal expected string, or a spelled-out count. In each one you are
copying the line above yours and changing the name.

## The loop that teaches you the rest

Do not try to memorise the checklist below. Make a change, then run:

```sh
bash tests/validate-policy.sh
```

It accumulates every violation and prints them all at once, in the repository's
own words. The workflow is: declare the service, run the check, fix what it
names, run it again. The checklist in this guide was produced by exactly that
loop, not by reading the test.

### Backing out

A half-added service leaves edits scattered across dozens of tracked files and
several new ones, so `git checkout` alone will not clean it up, and enumerating
the edited files by hand is exactly the thing this guide has historically got
wrong. Revert both halves wholesale, with `navidrome` as the example:

```sh
git checkout -- .
rm -rf services/navidrome roles/navidrome
rm -f tests/expected/navidrome.yml tests/contracts/navidrome.sh \
  tests/mac/hooks/drift/*-navidrome.sh
```

Then confirm you are back to a passing baseline with `git status --porcelain`
and `bash tests/validate-policy.sh`. Do this freely; the edit loop is cheap and
nothing outside the repository has changed yet.

## Anatomy of a service

Earlier versions of this guide said fifteen places, and then 55. The first was
wrong in the direction that costs an afternoon; the second was the right diff
counted one short. The honest figure is measured rather than remembered:
**promoting Pinchflat changed 56 files** — `git show --name-status 683e0c1`
counts 56, and so does GitHub's own tally for #137. Re-measure it against a newer
service if you like, but update `CLAUDE.md` in the same commit:
`tests/docs_links_test.rb` reads this figure out of this sentence and fails when
the summary there quotes a different one.

Only nine of those were new files, and all nine are the service itself and its
own proof. The other forty-seven are existing files that had to be told the
platform is one service larger. A handful are wiring and prose; most are
*registries* — files that pin a list, a count or a literal string describing the
platform as it currently is, and that fail when it grows without them. Sometimes
loudly, sometimes with a Ruby stack trace, occasionally not at all.

That the registries are stated rather than derived is deliberate: a derived list
would let a new service authorize itself by the arrival of its own files. The
price is paid here, once per service.

Do not read the groups below as a checklist to work down. Read them to tell
which ones apply to you, then go back to the edit loop, which will name the rest
in the repository's own words.

### 1. The service itself

Seven new files, always:

```
services/<name>/compose.yml
services/<name>/compose.mac.yml         (see below)
services/<name>/compose.integration.yml (see below)
roles/<role>/defaults/main.yml
roles/<role>/meta/argument_specs.yml
roles/<role>/templates/env.j2
roles/<role>/tasks/main.yml
```

### 2. Wiring it into the platform

Four existing files, always:

```
services/manifest.yml              the service, its role and its status
inventory/group_vars/all/main.yml  its directories, under nas_storage
site.yml                           the role, with tags
verify.yml                         the role, with tags: [never]
```

### 3. The roster and its expectations

Three files. Every one of these already exists for a service being **promoted**
from `planned`; all three are new work only for a greenfield service.

```
tests/policy_support.rb           EXPECTED_SERVICES, the roster
tests/policy_mutation_support.rb  EXPECTED_FIXTURE_ROLES, the sandbox identity
tests/expected/<service>.yml      its role, CPU ceilings and vault keys
```

Pinchflat's diff only *edited* `tests/expected/pinchflat.yml`, swapping
`vault_keys: []` for its two real keys. A planned service is already on the
roster and already has an expectations file, because the policy scripts read one
per rostered service regardless of status.

### 4. Proof that it works

Either verification tasks inside the role (the contract in step 5 of the worked
example below), or an executable contract script and its registration:

```
tests/contracts/<name>.sh       new, executable, passes sh -n
tests/contracts/registry.yml    the service and its path
```

### 5. The verification tag, and its three literal copies

`platform_verify_<service>` is not just a tag on your tasks. Three separate files
carry the platform's whole tag list as a literal:

```
roles/production_auto_deploy/defaults/main.yml  production_auto_deploy_verify_tags
docs/getting-started-nas.md                     the operator's manual command
tests/mac/verify.sh                             the Mac lane's --tags argument
```

`tests/production_auto_deploy_role_test.rb` parses every
`roles/*/{tasks,handlers}/*.yml`, collects each `platform_verify_*` tag the roles
actually declare, and requires the poller's list to **equal** that set — it
reports `missing=` and `stale=` separately, so neither a forgotten service nor a
leftover one passes. It then requires `docs/getting-started-nas.md` to carry the
same set. `tests/secrets_docs_test.rb` requires the guide's shell block to contain
that exact comma-joined string — *order* included — but reads the string out of
the poller's own defaults rather than keeping a fourth copy of it.

`tests/mac/verify.sh` is the one copy nothing compares against the roles:
`tests/policy_mac_test.rb` only checks that it mentions the foundation tag. Omit
your service there and the Mac lifetime proof quietly verifies one service
fewer. Add it by hand.

### 6. Sandbox identity: cleanup, container names, namespaces

The disposable lanes delete a container only when both its Compose ownership
labels and its exact namespaced name say the sandbox created it, so every
sandbox register has to learn the new name:

```
tests/sandbox_cleanup.sh                the project list, the service list, the dispatch case
tests/mac/lib.sh                        mac_target_container_names
tests/mac/integration-context-test.sh   the expected name list AND a hard-coded count
```

`tests/mac/integration-context-test.sh` is the one that catches you: it asserts
the identity set has exactly N entries, so adding the name without bumping the
number fails, and bumping the number without adding the name also fails.

### 7. The Mac lane's port allocation chain

If the service publishes a port — and if it has a web interface, it does —
`tests/mac/run.sh` has to allocate one for it. This is the single most
error-prone edit in the repository, and it gets its own section below.

Along with `run.sh`, a published port lands in:

```
inventory/group_vars/mac_hosts/main.yml               <service>_port from the environment
tests/mac/report.rb                                   six sites: ROOT_KEYS, the
                                                      validator's port-field list, the
                                                      markdown key order, the initializer,
                                                      the self-test, and the option parser
tests/mac/config-isolation.sh                         a render() positional, a compose
                                                      render, two call sites
tests/mac/config-isolation.rb                         the two parsed documents and
                                                      three collision assertions
tests/mac/run-phase-status-test.sh                    the pinned report.rb invocation
tests/mac/media-acquisition-foundation-report-test.rb the report fixture
```

### 8. The Mac hook tables and their pinned counts

Four of the five hook groups are one table-driven file each, driven from the
same registry:

```
tests/mac/hooks/verify/30-services.sh                one line per service
tests/mac/hooks/fixtures-seed/00-services.sh         one line per service
tests/mac/hooks/fixtures-persistence/00-services.sh  one line per service
tests/mac/hooks/fixtures-recreate/00-services.sh     one line per service
```

Add the service to each table, or, if its behaviour does not fit the table, give
it its own `tests/mac/hooks/<group>/<NN>-<service>.sh` and the collapsed hook
will credit it automatically from the filename. `tests/mac/hooks/drift/` is still
one file per service throughout, because no two services drift alike — expect to
write a new `tests/mac/hooks/drift/<NN>-<service>.sh` for yours.

The runner discovers hooks by globbing and only fails when a group is empty, so
the collapsed hooks assert their own coverage against
`tests/contracts/registry.yml` and print an `N of M` line: a service the registry
knows and no hook runs fails the group instead of being verified one fewer
without saying so. A service that genuinely has no work in a group needs a named
exemption in the hook's `mac_assert_service_coverage` call, which is how ntfy,
the alerting sink with no user data to seed, is accounted for, and how Pinchflat
is accounted for in `fixtures-seed`: its only real fixture would be a YouTube
download, which the lane must not make. The Mac lane also covers ntfy, which the
registry does not list because it has no contract of its own;
`MAC_UNREGISTERED_SERVICES` in `tests/mac/lib.sh` is where such a service is
named.

Those `N of M` lines are then pinned, verbatim, in
`tests/mac/hook-coverage-test.sh` — every summary string, plus the expected hook
execution log for each group, plus the recreate table's bundle-and-container
listing. Pinchflat changed ten separate expectations in that one file. Nothing
derives them; run the test, read the diff it prints, and update each pinned
string to match.

`tests/mac/run-contract.sh` needs no new file: it resolves any registered service
through the registry. Give it the service's port variable and any container
identities the contract reads, in the `case` at the bottom of that script. A
registered service with no arm there is refused rather than run with an
incomplete environment.

### 9. CI routing and the integration runner

```
tests/ci/suites.conf               one row: the suite, its kind, and the tags it
                                   converges. LANES, SUITES and SERVICE_TAGS in
                                   the classifier, and --list-suites and the
                                   fixed tags in the runner, all derive from it
tests/ci/classify_changes.rb       SERVICE_NAMES
tests/ci/classify_changes_test.rb  the pinned tag plan for the lane, and NTFY_LANES
tests/integration.sh               the service/directory table and the fixture
                                   pre-seeding the launcher does before the
                                   controller container starts
tests/integration_controller.sh    the suite dispatch, inside the container
tests/integration_controller_lib.sh  the contract runner case arm and the
                                   verify-only wrapper
tests/integration_suite_test.sh    the pinned --describe-suite line and pre-pull set
```

`.github/workflows/ci.yml` needs **no** edit. The `suites` job is a matrix fed by
the classifier's `suites` output and `validate` covers every leg through one
`needs` entry, so a new lane flows through the existing workflow unchanged. Only
`INTEGRATION_SUITES` in `tests/ci/workflow_test.rb`, which pins the list the
workflow is allowed to produce, has to learn the name.

### 10. If it has any user identity at all

```
config/managed-user-capabilities.yml     the service's contract
tests/managed_user_capabilities_test.rb  the same contract, restated, plus a
                                         spelled-out count in its success line
```

Pinchflat has no managed users and no user API — its whole identity is one
basic-authentication pair in its environment — and it still needed both files,
because the register describes how every service handles identity, including by
declaring `mode: declarative_environment` and refusing rotation. The success
string is spelled in English (`all eleven service contracts are pinned`), so the
number is also a literal you have to change.

### 11. The prose

`README.md` describes what is deployed. `docs/getting-started-nas.md` carries the
operator's verify command. `docs/secrets.md` carries the credential. All three
are checked by tests, not left to courtesy.

### What of this is Pinchflat's own problem

The 56 files are one service's measured diff, not a universal law, and some of
them were Pinchflat's circumstances rather than yours. Read the groups above with
these caveats:

- Groups 1, 2, 5, 6, 8 and 11 apply to every service, with or without a port.
- Group 3 is greenfield-only; a promotion edits those files rather than growing
  them. Group 4 is a choice between two ways of proving the service.
- Group 7 applies only to a service that publishes a host port, which in practice
  means one with a web interface.
- Group 9 assumes the service gets a CI lane of its own. Every implemented
  service currently does, and that is the normal arrangement, but it is a choice
  rather than a rule; a service folded into an existing lane edits fewer of the
  files that group lists. The count is deliberately not restated here: the group
  named four files when this caveat was written, `tests/ci/suites.conf` and the
  two `tests/integration_controller*.sh` files split out of `tests/integration.sh`
  have joined it since, and the restatement stayed at four throughout.
- Group 10 applies to every service, but the *content* of the entry depends
  entirely on what identity the service has — Pinchflat's says, in effect, "none
  that can be reconciled".
- Everything in the promotion section below — `config/media-acquisition.yml`, the
  `media_acquisition_*` tests, the foundation contract and hook — exists only
  because Pinchflat came from the media-acquisition catalog. A service added
  directly touches none of it.
- One file is misleadingly named:
  `tests/mac/media-acquisition-foundation-report-test.rb` is a fixture for
  `tests/mac/report.rb`, so *any* service adding a Mac port has to update it,
  acquisition project or not.

## Where policy checks live

The policy suite is several scripts rather than one, each policing the artifact it
changes with. Add a check to the script that owns the thing it checks:

```
tests/policy_support.rb           the roster, the expectations loader, shared helpers
tests/policy_test.rb              docs, services, the manifest, image and digest pinning
tests/policy_platform_test.rb     inventory, host-scoped facts, preflight, storage
tests/policy_vault_test.rb        the vault contract and secret containment
tests/policy_deployment_test.rb   roles/deployment_bundle
tests/policy_beszel_test.rb       beszel identity and host_prep
tests/policy_integration_test.rb  tests/integration.sh, locking, sandboxing
tests/policy_mac_test.rb          the tests/mac/ orchestration contract
tests/policy_ci_test.rb           runner registration, ci.yml, the classifier tables
```

A new script must be added to `tests/validate-policy.sh`, and to `POLICY_SCRIPTS`
and `BASE_FIXTURE_PATHS` in `tests/policy_mutation_support.rb`, which is where the
mutation harness's shared registers live — `EXPECTED_FIXTURE_ROLES` is in that
file too, not in `tests/policy_manifest_test.rb` as this guide used to say.
`tests/policy_ci_test.rb` asserts the runner runs every one of them, which is what
stops a check from being written and then never run.

The service name and the role name may differ. Paperless is `paperless-ngx` as a
service and `paperless_ngx` as a role, because directory names use hyphens and
Ansible role names cannot. Keep them identical unless you have that problem.

## Promoting a planned service is not the same job

The media-acquisition catalog is an exception to this implementation workflow.
While its entries are `planned`, planned acquisition projects' role and Compose
directories must remain absent. Moving one project to implementation requires a
separate phase with its own failing contracts and manifest transition; do not
create a placeholder role or `services/<project>/` directory during Phase 0.

That absence is enforced, and it constrains how you commit. `planned_tree_problems`
in `tests/media_acquisition_foundation_test.rb` reads every project whose status is
`planned` and fails with `planned role tree exists prematurely` the moment
`roles/<role>/` or `services/<project>/` appears on disk. So **the role tree cannot
exist while the manifest still says `planned`**: creating the directories and
flipping the status in `services/manifest.yml` and `config/media-acquisition.yml`
have to land in one commit. There is no intermediate state where the repository is
green. Plan the branch accordingly; do not try to scaffold first and wire up after.

In exchange, Phase 0 has already done real work for you. A planned project
already has:

- its entry in `services/manifest.yml` and in `config/media-acquisition.yml`,
  including its declared port, CPU class and service names. You flip
  `status: planned` to `status: implemented` in both, and both flips are pinned:
  `tests/media_acquisition_phase1_test.rb` reads the catalog and the manifest
  together, and `tests/media_acquisition_foundation_test.rb` pins the catalog entry
  whole — so becoming implemented also means adding the service's published port to
  its `EXPECTED_IMPLEMENTED_PORTS` list
- its name in `EXPECTED_SERVICES` and `EXPECTED_FIXTURE_ROLES`
- a `tests/expected/<name>.yml` to edit rather than create
- its storage already declared under `nas_storage` as foundation storage. Pinchflat
  added only `media_acquisition_writer: true` to the `Media/YouTube` entry that
  already existed, and a matching line in `EXPECTED_INTEGRATION_WRITERS`
- a placeholder CI lane in `tests/ci/classify_changes.rb`, `tests/integration.sh`
  and `tests/integration_suite_test.sh`, whose tags you repoint from the shared
  inert foundation to your own role
- `tests/contracts/<name>-foundation.sh`, which **stays**

That last point is worth stating plainly, because the instinct is to delete it.
The foundation contract proves the project is *inert* — that no container by that
name is running and nothing has been provisioned. It is a different claim from the
runtime contract and it does not stop being true or useful once the service is
implemented. Both `arr` and `downloaders` kept theirs through Phase 1, and
`tests/contracts/pinchflat-foundation.sh` survives the Pinchflat promotion
alongside the new `tests/contracts/pinchflat.sh`. What changes is the dispatch:
the promoted project leaves the shared foundation dispatch in
`tests/integration.sh` for whichever project is still planned, and
`tests/integration_suite_test.sh` pins both that arm and the new lane. With the
acquisition catalog fully implemented there is no planned project left, so that
arm now sits in the last promoted project's own lane: it runs the shared
foundation's runtime proof and then falls through to the lane's service proof
rather than exiting there.

Promotion also removes the service from the registers that asserted its absence:
the catalog loop in `tests/mac/hooks/verify/15-media-acquisition-foundation.sh`
that requires no container by that name to exist. `tests/policy_ci_test.rb` used
to carry two more such lists; it now derives the planned and implemented
acquisition lanes from `config/media-acquisition.yml` and the manifest, so the
status flip alone moves your lane from "must converge only the inert foundation
tags and ship no service image" to "must converge ntfy, its own role and a second
enabled convergence". A greenfield service never touches any of those.

## Worked example: Navidrome

### 1. Declare it

Add to `services/manifest.yml`:

```yaml
  - name: navidrome
    role: navidrome
    status: implemented
```

Then run `bash tests/validate-policy.sh`:

```
FAIL service manifest must list the complete source platform
FAIL service manifest contains unknown services: navidrome
FAIL navidrome: service must be a real directory within services
FAIL navidrome: compose.yml must be a regular file within its service root
FAIL navidrome: role must be a real directory within roles
FAIL navidrome: argument_specs.yml must be a regular file within its role root
FAIL navidrome: tasks/main.yml must be a regular file within its role root
FAIL navidrome: implemented service has no storage declaration
FAIL navidrome: implemented service has no automated verification or service contract
9 policy violation(s)
```

That is the task list `policy_test.rb` can see. It is not the whole task list.
The registries in groups 5 through 10 above fail in other scripts, later in the
run, and some of them — `tests/mac/verify.sh`, the `allocate_service_port` chain —
fail nowhere at all. Work the failures the loop names, then walk the anatomy
groups deliberately.

The example roster below is Navidrome's; the real one is longer, and the
manifest, the roster and the fixture roles have grown considerably since. Copy
the shape, not the contents.

### 2. Register the name in the two Ruby lists and pin its expectations

The first two failures come from a pinned list. The comment at the top of
`tests/policy_support.rb` explains why the list is pinned rather than derived:
deriving it from the manifest would let a service silently disappear from the
platform scope without any test noticing.

In `tests/policy_support.rb`, add the name to `EXPECTED_SERVICES`:

```ruby
EXPECTED_SERVICES = %w[
  audiobookshelf beszel dozzle immich jellyfin komga navidrome ntfy
  paperless-ngx
].freeze
```

Then create `tests/expected/navidrome.yml` with everything the policy checks pin
about this one service. The roster stays in Ruby because it is the authorization
tripwire, and a roster derived from whichever files exist under `tests/expected/`
would let a new service approve itself by the arrival of its own file. Everything
the roster authorizes lives in the per-service file, so adding a service edits its
own file rather than four tables shared with every other service:

```yaml
---
role: navidrome
container_cpus:
  navidrome: 1.5
vault_keys:
- vault_navidrome_admin_password
- vault_navidrome_admin_username
```

All three fields are required and are checked for type, so a mistyped CPU ceiling
is reported against this file rather than surfacing later as a Compose mismatch.
The `container_cpus` values must equal the `cpus:` keys in the service's
`compose.yml`, and `vault_keys` must be prefixed for this service and must list
every key the service adds to the vault.

This file is where a CPU ceiling is pinned, and the checks read it rather than
keeping copies: `services/<name>/compose.yml` is asserted equal to it, and
`tests/media_acquisition_phase1_test.rb`, `tests/configarr_job_test.rb` and
`tests/media_acquisition_foundation_test.rb` load it instead of restating the
numbers. An ordinary service therefore holds its ceiling in two places — its
Compose file and this one — and changing it is two edits. A media-acquisition
service holds a third in `config/media-acquisition.yml`, which is deployed to the
target rather than read by a test; `tests/policy_test.rb` asserts that copy
declares a ceiling for exactly the containers pinned here and that each one is
equal, so it is a restatement to keep in step rather than a number of its own.

Each ceiling must be **no greater than** `platform_container_cpu_budget` in
`inventory/group_vars/nas_hosts/main.yml`, and `tests/policy_test.rb` fails by
name when one is not. The budget is the width of the cpuset every managed
container shares, not a pool divided between them: `cpus:` is a ceiling on that
shared set rather than a reservation carved out of it, so the ceilings across the
platform are deliberately oversubscribed and sum to many times the budget. These
workloads are idle almost all the time, so that sum is not a quantity anything
has to fit into. A single ceiling wider than the cpuset is the real error —
Docker clamps the container to the cpuset anyway, so the number constrains
nothing while reading as a deliberate limit. Equal to the budget is allowed and
four containers use it, on the reasoning that whichever one is busy may have the
whole set, so pick a ceiling from what the workload actually needs rather than
from what is left over.

There is a second list, `EXPECTED_FIXTURE_ROLES`, in
`tests/policy_mutation_support.rb` — the shared harness the mutation checks build
their sandboxes from. It is easy to miss because `policy_test.rb` will pass
without it, and the mutation checks do not report a policy failure when it is
missing. They raise instead:

```
tests/policy_mutation_support.rb:183:in 'block in Object#fixture_paths':
  unsafe manifest fixture identity (RuntimeError)
```

Add the same pair there. Note that the harness raises twice over the same list:
once for the manifest identity of an implemented service, and once, a few lines
below, for `unsafe expectation fixture identity` on *every* rostered service
regardless of status — which is why a planned service already needs both the
roster entry and its `tests/expected/<name>.yml`.

### 3. Write the Compose definition

`services/navidrome/compose.yml`:

```yaml
---
# Platform fragments. Compose resolves a YAML anchor only inside the file that
# declares it, so every stack carries its own copy; tests/policy_test.rb pins the
# copies equal and records there why cross-file sharing was not taken. A
# container needing different health-check timing overrides only the fields it
# changes, so a deviation reads as a deviation.
x-logging: &default-logging
  driver: json-file
  options:
    max-size: 10m
    max-file: "3"

x-service-defaults: &service-defaults
  cpuset: ${PLATFORM_CONTAINER_CPUSET:?}
  security_opt:
    - no-new-privileges:true
  restart: unless-stopped
  logging: *default-logging

x-healthcheck-defaults: &healthcheck-defaults
  interval: 30s
  timeout: 10s
  retries: 5
  start_period: 60s

services:
  navidrome:
    <<: *service-defaults
    container_name: navidrome
    image: docker.io/deluan/navidrome:0.58.0@sha256:2ae037d464de9f802d047165a13b1c9dc2bdbb14920a317ae4aef1233adc0a3c
    labels:
      dev.dozzle.name: navidrome
    user: "${NAS_UID:?}:${NAS_GID:?}"
    ports:
      - "4533:4533"
    volumes:
      - ${NAVIDROME_DATA_PATH:?}:/data
      - ${NAVIDROME_MUSIC_PATH:?}:/music:ro
    environment:
      TZ: ${TZ:?}
    healthcheck:
      <<: *healthcheck-defaults
      test: [CMD-SHELL, "wget -q -O - http://127.0.0.1:4533/ping | grep -q '\"status\":\"ok\"'"]
```

Copy the three `x-` fragments verbatim from any existing stack. They are the
platform's log rotation, the container defaults every long-running service
shares, and the health-check timing default; `tests/policy_test.rb` compares
each copy against the values it pins, so a stack that retypes one of them
differently fails by name. The comment there records why the fragments are
repeated per file rather than shared through `extends:`.

A container whose health check genuinely needs different timing merges the
fragment and then overrides only the fields it changes, so the diff from
platform policy is what the file shows. State the reason beside the override; if
the value predates the default and no reason is recorded, say that rather than
inventing one, and preserve the value.

The policy test enforces every one of these properties:

- The image must be digest-pinned **and** carry a readable version tag, in the
  form `repo:1.2.3@sha256:<64 hex>`. The tag is what tells a human what is
  deployed and lets Renovate propose an update; the digest is what makes the
  deployment reproducible. Get it with
  `docker buildx imagetools inspect docker.io/deluan/navidrome:0.58.0` and take
  the top-level `Digest:` field, not one of the per-platform entries under
  `Manifests:`. The top-level value is the manifest-list digest, which is what
  lets one pin resolve correctly on both the NAS and an arm64 Mac.
- No `build:` key. Published images only.
- No `privileged: true`.
- `security_opt: [no-new-privileges:true]`, on every container in the stack,
  one-shot jobs included. `privileged` says the container starts without extra
  power; this says it cannot acquire any afterwards by executing a setuid
  binary. Entrypoints that drop to a service account — linuxserver.io's
  `s6-setuidgid`, `gosu`, the Postgres and Valkey entrypoints — call `setuid(2)`
  as root, which `no_new_privs` does not restrict, so they keep working. If an
  image ever does need the escalation, it belongs in an allowlist beside the
  check in `tests/policy_test.rb` with the reason stated, never omitted in
  silence.
- `restart: unless-stopped`.
- `logging` with the `json-file` driver and both `max-size` and `max-file`, and
  the same two values every other container uses. Presence alone would let
  twelve stacks each pick their own ceiling, which is the drift the shared
  fragment exists to prevent.
- Volume sources must be `${VARIABLE:?}` references, never absolute paths. The
  `:?` suffix makes an unset variable fail loudly instead of silently creating a
  relative bind mount. Hardcoding `/volume1/...` is rejected outright, because
  the same file has to run unmodified on the NAS, on a Mac sandbox and in CI.

A container that owns state — anything mounting a `recovery: critical` path, or
writing into the media tree — declares `stop_grace_period` with the reason beside
it, because Docker's undeclared ten seconds is a default nobody chose. The number
comes from what that particular software has to flush: a Postgres fast shutdown
checkpoints every dirty buffer and gets one to two minutes, a Valkey snapshot or
a SQLite commit gets thirty seconds, an importer gets long enough to finish the
file it is writing but not long enough to wait on work that is simply re-queued.
Containers that hold nothing — renderers, parsers, socket proxies, model caches —
declare nothing and keep the default. This is judgement, not a policy check:
there is no property that can tell the two apart, so state the reasoning in the
comment. For the same reason `stop_grace_period` never goes into a shared
fragment: an omitted key means ten seconds, so inheriting one would quietly
extend the shutdown window of every container that had deliberately declared
nothing. The one exception is a fragment whose every consumer already wanted the
same window, as in `services/arr/compose.yml`.

A service that runs as a direct numeric user takes the shared platform identity,
`user: "${NAS_UID:?}:${NAS_GID:?}"`, never a literal pair — even one that happens
to equal today's `nas_uid` and `nas_gid`. The two variables reach the container
through the role's `env.j2`, so one inventory change moves every container at
once and a Compose file cannot drift from the identity the storage declarations
grant. Images that read `PUID`/`PGID` instead — the linuxserver.io family — take
the same two variables under those names.
`tests/reader_platform_identity_test.rb` proves the identity resolves by
rendering the effective Compose document with a uid and gid the repository never
mentions.

Platform overrides live in `services/<name>/compose.<kind>.yml`. They may add
host-specific wiring such as devices, mounts and per-project container names,
but they **must not contain an `image:` key**.

A service that names its containers needs both disposable-lane overrides, and
both must give a container the same name:

```yaml
---
services:
  navidrome:
    container_name: ${PLATFORM_PROJECT_NAME:?}-navidrome
```

This is not cosmetic. The Mac and integration lanes deploy into a disposable
project namespace, and their cleanup deletes a container or network only when
its Compose ownership labels and its exact namespaced name both say the sandbox
created it. A service left with its production container name is never cleaned
up: it survives the run and collides with the next one. `tests/sandbox_cleanup.sh`
registers the namespaced identity of every service, and
`tests/policy_integration_test.rb` checks that register against these overrides,
so a new or renamed service fails there rather than leaking a container.

You do not select the override yourself. `deployment_bundle` stats every manifest
service against the deployed release once per run and publishes the result as
`platform_service_compose_files`, keyed by the service name in
`services/manifest.yml`. Read it in your role; do not restat the override.

### 4. Write the role

`roles/navidrome/defaults/main.yml`:

```yaml
---
navidrome_port: 4533
navidrome_api: "http://127.0.0.1:{{ navidrome_port }}"
navidrome_health_retries: 60
navidrome_health_delay: 3
navidrome_compose_project_name: >-
  {{ (platform_project_name ~ '-navidrome')
     if platform_project_name | default('') | length > 0 else 'navidrome' }}
```

The API address is a loopback address because every task, including HTTP calls,
executes on the target host. The project name is derived so that a disposable
sandbox can run several isolated copies of the platform side by side.

`roles/navidrome/meta/argument_specs.yml`:

```yaml
---
argument_specs:
  main:
    short_description: Deploy Navidrome and verify that it serves its music library
    options:
      platform_compose_kind:
        type: str
        required: true
      platform_project_name:
        type: str
        required: false
      navidrome_port:
        type: int
        required: false
      navidrome_health_retries:
        type: int
        required: false
      navidrome_health_delay:
        type: int
        required: false
```

Every role must have this file with at least one option, and every vault
credential the role reads belongs here as `required: true`.

`roles/navidrome/templates/env.j2` renders the variables the Compose file
demands:

```jinja
{# Rendered on the target from vault and inventory facts. #}
TZ={{ nas_timezone }}
NAS_UID={{ nas_uid }}
NAS_GID={{ nas_gid }}
NAVIDROME_DATA_PATH={{ nas_docker_root }}/navidrome/data
NAVIDROME_MUSIC_PATH={{ nas_media_root }}/Media/Music
NAVIDROME_HOST_PORT={{ navidrome_port }}
PLATFORM_PROJECT_NAME={{ platform_project_name | default('') }}
```

`roles/navidrome/tasks/main.yml` is the body. This is the minimal shape, and it
is worth understanding one thing before reading it: **the role never runs against
this repository on the target machine.** `deployment_bundle` assembles an
immutable release from the controller checkout and installs it at
`platform_current_dir`, with rendered secrets kept separately under
`platform_runtime_dir`. The first task validates exactly the paths this role is
about to touch, and nothing else does: containment is checked once per distinct
set of paths, not again beside each write, so a path your role names here and
nowhere else is a path nobody checked. `deployment_target_require_current_release:
true` additionally refuses to run unless `current` resolves to the release this
run installed, which is what makes a lone `--tags navidrome` converge safe.

`deployment_target_service` is the **manifest service directory**, not the role
name — `services/manifest.yml` is the mapping, and it differs for
`paperless-ngx`. From it `deployment_bundle` derives the five paths every service
role touches: the service directory in the current release, both Compose files,
the runtime directory and its rendered `.env`. Naming a service the role does not
deploy fails the run, so `deployment_target_extra_paths` stays what it says it
is — exactly the paths beyond those five. A role with none writes `[]`.

```yaml
---
- name: Revalidate deployment paths before Navidrome runtime use
  ansible.builtin.include_role:
    name: deployment_bundle
    tasks_from: target
  vars:
    deployment_target_service: navidrome
    deployment_target_require_current_release: true
    deployment_target_extra_paths: []

- name: Render the Navidrome environment
  ansible.builtin.template:
    src: env.j2
    dest: "{{ platform_runtime_dir }}/services/navidrome/.env"
    mode: "0600"

- name: Deploy Navidrome
  community.docker.docker_compose_v2:
    project_src: "{{ platform_current_dir }}/services/navidrome"
    project_name: "{{ navidrome_compose_project_name }}"
    files: "{{ platform_service_compose_files['navidrome'] }}"
    env_files: ["{{ platform_runtime_dir }}/services/navidrome/.env"]
    state: present
    wait: true
    wait_timeout: "{{ platform_compose_wait_timeout }}"

- name: Wait for Navidrome application health
  ansible.builtin.uri:
    url: "{{ navidrome_api }}/ping"
    method: GET
    status_code: [200]
    return_content: true
  register: navidrome_health
  until:
    - navidrome_health.json | default(none) is mapping
    - navidrome_health.json.status | default(none) == 'ok'
  retries: "{{ navidrome_health_retries }}"
  delay: "{{ navidrome_health_delay }}"
  changed_when: false
  check_mode: false

- name: Verify the Navidrome service endpoint
  tags: [platform_verify_navidrome]
  ansible.builtin.uri:
    url: "{{ navidrome_api }}/ping"
    method: GET
    status_code: [200]
    return_content: true
  register: navidrome_verify_ping
  changed_when: false
  check_mode: false

- name: Require the exact Navidrome verification response
  tags: [platform_verify_navidrome]
  ansible.builtin.assert:
    that:
      - navidrome_verify_ping.json.status == 'ok'
    fail_msg: Navidrome did not report a healthy service status.
```

`.env` is rendered with mode `0600` because it holds plaintext credentials at
runtime. `changed_when: false` marks a read as a read, which is what keeps the
second converge at `changed=0`. `check_mode: false` lets a read run for real
during a `--check` review, where a simulated read would return nothing to assert
against.

### 5. Satisfy the verification contract exactly

The failure `implemented service has no automated verification or service
contract` has a precise contract behind it, and it is the one most likely to
waste your afternoon. A role satisfies it when it contains a task where all
three of the following hold:

1. The task name contains the word `verify` or `verification`.
2. The task carries the tag `platform_verify_<service-name>`.
3. The task is either a `uri` task whose URL names the service, through a
   `<service>_*` variable or the literal service name, and which declares
   `status_code:`; or an `assert` task whose every `that:` condition is a real
   comparison against a register produced by such a `uri` task.

The two tasks at the end of the role above satisfy points 3a and 3b
respectively. A `debug` task named "verify" satisfies nothing, and an `assert`
whose conditions do not reference a registered HTTP result satisfies nothing.

The alternative is a service contract: an executable `tests/contracts/<name>.sh`
that passes `sh -n`, registered in `tests/contracts/registry.yml`. Either one
satisfies the policy. Use a contract when proving the service means driving a
real workflow (Paperless ingests a PDF and reads back its checksum) rather than
reading one endpoint.

A contract that runs a play of its own — to prove the platform *refuses*
something, which needs a failing convergence — is a second entry point into the
same sandbox, so it must converge into the same disposable project. Pass
`-e platform_project_name=` from the `PLATFORM_PROJECT_NAME` the harness exports
to the contract, never a name of the contract's own: without it the play renders
an empty namespace, the integration override's `${PLATFORM_PROJECT_NAME:?}`
refuses the deployment, and the run dies before it reaches the refusal under
test. `tests/policy_integration_test.rb` requires both halves of that
propagation.

### 6. Declare the storage

The remaining failure is `implemented service has no storage declaration`. Add
the directories to `nas_storage` in `inventory/group_vars/all/main.yml`:

```yaml
  # Navidrome. Its database and cache are critical service state; the music
  # files remain NAS-owned user media mounted read-only by the service.
  - path: "{{ nas_docker_root }}/navidrome/data"
    owner: "{{ nas_uid }}"
    group: "{{ nas_gid }}"
    mode: "0755"
    recovery: critical
  - path: "{{ nas_media_root }}/Media/Music"
    mode: "0755"
    recovery: user
```

This list is the single source of truth for three separate things: `host_prep`
creates the directories with these permissions, the policy test requires every
implemented service to declare at least one path containing its name, and the
`recovery` class drives the disaster-recovery documentation.

Be precise about how much that policy check buys you. It only asserts that
*some* declared path mentions the service. A stricter cross-check against the
Compose volume sources exists, but it fires only when the source string spells
out `${NAS_DOCKER_ROOT:?}` inline. Navidrome's `${NAVIDROME_DATA_PATH:?}` is
indirected through the env template, so nothing statically compares the path the
template renders against the path declared here. Getting that pair wrong is
caught by the integration run, not by the policy test. The three classes are `critical` for
irreplaceable service state that must be backed up, `user` for NAS-managed files
owned outside this repository, and `cache` for anything regenerable.

Omit `owner` and `group` under the media root. The NAS owns those files and
grants access through its own permission controls, so claiming ownership there
is a claim the first upload falsifies.

At this point:

```
$ bash tests/validate-policy.sh
policy validation: all 107 checks passed
```

That total is whatever the manifest in `tests/validate-policy.sh` currently holds;
it grows, so read it as "no failures", not as a number to match.

## What the policy test does not catch

The service now satisfies every static property and is still never deployed.
Nothing statically asserts that a manifest entry appears in `site.yml`, so this
step is silent. Add the role, in dependency order, with tags:

```yaml
    - role: navidrome
      tags: [navidrome]
```

Then add it to `verify.yml` with `tags: [never]`:

```yaml
    - role: navidrome
      tags: [never]
```

`never` means the role's tasks are inert unless something explicitly selects one
of their other tags. That is what makes `verify.yml` safe: it can only ever run
the read and assert tasks you marked `platform_verify_<name>`, never a
deployment or reconciliation task. Confirm the wiring:

```sh
ansible-playbook -i inventory/local.yml verify.yml \
  --tags platform_verify_navidrome --list-tasks
```

You should see exactly your verification tasks listed under the role and nothing
else from it.

### CI routing

CI fails open, so forgetting this costs time rather than correctness. An
unrecognised path makes `service_lane` return nil, which runs every lane:

```
roles/navidrome/... unmapped -> static, reconciliation, foundation, arr,
                                downloaders, bindery, kapowarr, pinchflat,
                                trailarr, seerr, smoke, beszel, dozzle,
                                audiobookshelf, komga, jellyfin, immich,
                                paperless, idempotence-check
roles/komga/...     mapped   -> static, smoke, komga, idempotence-check
```

Falling open is the right answer for a role, because a role is converged by a
play. It is the wrong answer for a check: a file under `tests/` that no suite
executes cannot change what a suite does, so the classifier routes it to the
policy gate alone. The exception is the integration harness itself and
everything it reaches -- `tests/integration.sh`, the contracts under
`tests/contracts/`, the document fixtures under `tests/fixtures/` and the Mac
hooks under `tests/mac/hooks/`. Add a file there and
`tests/ci/classify_changes_test.rb` walks the harness's reference closure and
fails until `INTEGRATION_HARNESS_PATHS` names it, so the narrower routing cannot
quietly skip a suite that reads it.

Each service should normally own its own lane. The tag list is stated once, in
`tests/ci/suites.conf`, and two tests pin it back:

```
tests/ci/suites.conf                the suite, its kind, and its tags -- one row
tests/ci/classify_changes.rb        SERVICE_NAMES
tests/ci/classify_changes_test.rb   the pinned expected tag string
tests/integration_suite_test.sh     the pinned --describe-suite output
```

The row is what makes the lane exist: `LANES`, `SUITES` and `SERVICE_TAGS` in
`tests/ci/classify_changes.rb` are derived from the table, and so are the
runner's `--list-suites` roster and the tags a suite converges when the caller
passes none. The lane name is the suite name with hyphens written as
underscores. The suite still needs its name in the `INTEGRATION_SUITES` list that
`tests/ci/workflow_test.rb` pins. The workflow itself needs no change: the
`suites` job is a matrix fed by the `suites` output, and `validate` covers every
leg through one `needs` entry.

`tests/integration.sh` no longer restates the tags -- `tests/policy_ci_test.rb`
fails if it does -- but it still wants the service in its service/directory table
for image pre-pulling, a `run_<service>_contract` wrapper if the service has a
contract, a `run_<service>_verify_only` wrapper, and an arm in the suite dispatch
that says what the lane actually does. Both wrappers are three lines: they name
the service and delegate to `run_contract` / `run_verification`, the two shared
launchers that hold the environment ABI and the verification play. Anything the
service needs beyond the shared block belongs in a case arm of `run_contract`,
not in a wrapper body -- `tests/policy_integration_test.rb` rejects a
verification wrapper that is anything other than a delegation. `tests/integration_suite_test.sh` pins both
the `--describe-suite` line and the exact set of images the lane pre-pulls, so a
lane that converges a new stack fails there until you say which images it needs.

`tests/ci/classify_changes_test.rb` additionally keeps `NTFY_LANES`: every lane
whose tags start the alerting sink. If your lane converges `ntfy` — and it does if
the role publishes a deployment report — add it there as well, in both the
classifier and the test, which state the list separately on purpose.

## The Mac lane's port chain

The Mac lifecycle proof runs several isolated copies of the platform, so it cannot
use the service's production port. `tests/mac/run.sh` allocates a free host port
per service, exports it as `PLATFORM_<NAME>_PORT`, and
`inventory/group_vars/mac_hosts/main.yml` reads it back into `<service>_port`.
`tests/policy_platform_test.rb` no longer names those facts one by one: it accepts
a Mac host variable called `<something>_port` only when its value is nothing but a
`PLATFORM_*` environment lookup, and rejects anything else in that group as
portable configuration. So the inventory line is the whole edit here.

Adding one port to `run.sh` is twelve separate edits in that one file — eleven if
you count the prose comment above the guard as part of the guard. Previous
attempts at this work believed it was eight, which is how ports get half-added.
They are, in file order:

```
1   the port-name list in read_integration_ports's embedded Ruby
2   the comment stating how many integers the validated input holds
3   the [ "$#" -eq N ] argument-count guard
4   the positional unpack, expected_<service>_port=${N}
5   initialize_report_input's --<service>-port flag
6   the integration branch's <service>_port=$expected_<service>_port
7   the nested allocate_service_port chain in the non-integration branch
8   the resume read, fetching "<service>_port" out of the state JSON
9   the resume comparison against the recorded run
10  export PLATFORM_<NAME>_PORT
11  the preflight `for reserved_port in ...` reservation loop
12  the preflight embedded Ruby's duplicate-port argument list
```

Site 7 is the dangerous one, and the reason this section exists.
`allocate_service_port` asks the kernel for an ephemeral port and rejects it only
if it equals one of the ports passed as arguments. Every allocation therefore has
to name every port allocated before it, so the chain grows quadratically and each
new line is the longest:

```sh
sabnzbd_port=$(allocate_service_port \
  "$beszel_port" ... "$bazarr_port")
pinchflat_port=$(allocate_service_port \
  "$beszel_port" ... "$bazarr_port" "$sabnzbd_port")
```

The exclusion set is positional and implicit. Nothing states the invariant, no
test asserts it, and a line that omits a port is syntactically perfect. Two
branches that each add a service each write a final line whose argument list ends
at the last port *that existed on `main`*, so once both land — merged, rebased, or
resolved by hand by keeping both lines, which is the natural resolution — neither
knows about the other. The two services can then be handed the same free port, and
the failure is a container that will not bind, appearing at converge time, in one
lane, sometimes.

The same trap sits in sites 3 and 4. Two branches each bump the argument-count
guard from 13 to 14; the merged file needs 15, has 14, and the positional unpack
silently drops the last port into nothing.

So: when you add a port, read the whole chain top to bottom rather than copying
the line above, and check that the last line names every port declared before it.
Then propagate the port to the five files that carry it outside `run.sh` —
`tests/mac/report.rb` (six sites of its own), `tests/mac/config-isolation.sh`
and the `tests/mac/config-isolation.rb` beside it,
`tests/mac/run-phase-status-test.sh`,
`tests/mac/media-acquisition-foundation-report-test.rb` and
`inventory/group_vars/mac_hosts/main.yml`.

## When the service has credentials

Everything above covers a service that proves itself over an unauthenticated
endpoint. A service with its own identity has one absolute rule: **credentials
are authored in vault and flow one direction.** Nothing is ever read back from a
running service, which is what lets a run converge in a single pass. Where a
service would normally hand you a generated value to copy, this platform
supplies its own value instead.

This guide used to say a credential touches six files. It touches **ten**, and the
ones it omitted are those that fail last and least clearly. Pinchflat's two keys
landed in every one of these:

```
inventory/group_vars/all/vault.yml.example    a sanitized placeholder
roles/vault_contract/meta/argument_specs.yml  {type: str, required: true}
roles/vault_contract/tasks/main.yml           the redacted validation map
filter_plugins/vault_credential_schema.py     CREDENTIAL_RULES: its shape rule
roles/<role>/meta/argument_specs.yml          required: true
tests/expected/<service>.yml                  vault_keys
generate-secrets.yml                          generation, and a second edit in
                                              the assertion block below it
templates/vault-plain.yml.j2                  what generate-secrets renders
tests/generate-ephemeral-vault.sh             the integration and Mac lanes' vault
docs/secrets.md                               enforced by secrets_docs_test.rb
```

One of those deserves naming. `filter_plugins/vault_credential_schema.py` is where
the credential's *shape* is stated — `NONEMPTY`, a hex pattern, a UUID — and a key
declared in `vault_contract` without a rule here is validated only for presence.

`tests/secrets_docs_test.rb` used to carry a literal total on top of that list —
`vault example must contain exactly 59 vault_* keys` — which nothing derived and
which named the count rather than your service, so it read like an unrelated
breakage. It now counts the keys the `tests/expected/*.yml` files pin, so adding
the key in the ten places above is the whole edit.

`roles/vault_contract/tasks/main.yml` matters for the same reason: the argument
spec makes Ansible require the variable, but the map in the tasks file is what
actually feeds it to the schema filter. A key in the spec and not in the map is
required but never shape-checked.

The `docs/secrets.md` edit is mandatory, not courtesy. `tests/secrets_docs_test.rb`
checks the guide against the vault contract and fails when they diverge. Write the
entry as a recovery instruction — where an operator rebuilding the vault finds the
existing value — not as a description of the field.

### A third-party credential lands in one more place than that

The eleven above are for a credential this platform *generates*. A credential
that belongs to somebody else — an account at an external service, the way the
Open Subtitles pair does — needs a `NOT_PLACEHOLDER` rule in
`filter_plugins/vault_credential_schema.py`, so the vault contract refuses to
converge against the documented example value instead of failing later at the
provider. That rule is correct, and it breaks a test that nothing about your
service will make you think of.

`tests/managed_users_vault_test.rb` loads
`inventory/group_vars/all/vault.yml.example`, substitutes **only** the Open
Subtitles placeholders with runtime-shaped values, and requires the result to
pass `vault_contract` evaluation. Every rejection case below it is built from
that same runtime vault by mutating one field, so they inherit the failure: a
second `NOT_PLACEHOLDER` key whose example value is still a placeholder makes the
whole file fail, and it fails naming *your* key inside an assertion about managed
users. The fail-closed probes in `tests/media_probes_fail_closed.rb` and
`tests/database_managed_users_test.rb` build a working vault out of the same
example file the same way.

So a third-party credential has a choice to make in the example vault, and it is
a real one: either give it a placeholder and teach every test that builds a
runtime vault to substitute it, or give it a syntactically valid non-placeholder
value and lose the "you forgot to replace this" guard. Whichever you pick, make
it deliberately — the tests will not explain the trade-off, they will just fail
somewhere that looks unrelated.

In the role itself, mark every task that touches a credential `no_log: true`.
The vault contract validation in `site.yml` and `verify.yml` is already wired
and redacted; you do not repeat it per role. Read
`roles/komga/tasks/main.yml` for the full pattern of provisioning an
administrator through an API and then asserting the result back, including how
it reports planned mutations under `--check` with a `debug` task rather than
performing them.

Managed non-administrator users are a separate mechanism: they live under
`vault_managed_users.<role>` and are converged by a `tasks/managed_users.yml`
included twice, once with a `reconcile` phase and once with a `verify` phase.
`roles/komga/tasks/managed_users.yml` and `config/managed-user-capabilities.yml`
are the reference.

Any task file gated on such a phase must open with an unconditional `assert`
naming exactly the phases it implements. `include_tasks` never applies
`meta/argument_specs.yml`, so without that assert a phase string matching no gate
skips the entire file and the run still reports success — and `verify.yml` reaches
every verification it owns through this mechanism. `ruby tests/policy_test.rb`
enforces it: the phases the file declares must equal the phases its callers pass.

`config/managed-user-capabilities.yml` is not optional for services that skip that
mechanism. It is the register of how *every* service handles identity, so a service
with no managed users still needs an entry saying so. Pinchflat has no user API at
all — its whole identity is one basic-authentication pair in its environment — and
it still declares `mode: declarative_environment`, `password_rotation: refuse` and
its four interface strings. Restate the same contract in `EXPECTED_SERVICES` in
`tests/managed_user_capabilities_test.rb`. That file's success line spells the
number of pinned contracts in English (`all twelve service contracts are pinned`)
but counts `EXPECTED_SERVICES` to do it, so the entry is the whole edit.

## The test ladder

Run these in order and stop at the first failure. The times are from a Mac
laptop.

```sh
# seconds
ruby tests/policy_test.rb
ansible-playbook -i inventory/local.yml site.yml --syntax-check
ansible-playbook -i inventory/local.yml verify.yml \
  --tags platform_verify_<name> --list-tasks

# about a minute
ansible-lint --strict

# minutes; the checks run concurrently and the script reports its own wall
# time and its ten slowest checks when it finishes. POLICY_JOBS=1 restores the
# serial order (15m28s) for bisecting a failure that only appears under load.
tests/validate-policy.sh

# needs Docker; converges a disposable Linux sandbox
tests/integration.sh --suite smoke site.yml
tests/integration.sh --suite <lane> site.yml

# the full lifecycle proof, including idempotence, drift and persistence
tests/mac/run.sh --lane fresh \
  --vault-file /absolute/path/to/vault.yml \
  --vault-password-file /absolute/path/to/password-command
```

`tests/validate-policy.sh` is the gate CI runs, and it runs almost every check in
the repository including the Ruby, Python and shell unit tests. Run it before
opening a pull request, not during the edit loop. The exceptions are the checks
that grew a case list large enough to become the gate's floor and now run in CI
jobs of their own — `tests/policy_manifest_test.rb` and the three
`tests/media_acquisition_reconciliation_*_test.rb` files — so run those directly
when you touch what they cover.

The integration harness runs Ansible inside a Linux container against a
temporary sandbox, so the plays meet a real `/proc/mounts`, real numeric uid and
gid and a real Docker socket. It asserts three properties: the run converges, a
second identical run changes nothing, and `--check --diff` works. The two worst
bugs found in this repository so far, a fact that exists only on Linux and a
`command` task silently skipped under `--check`, both passed syntax checking and
lint and were caught only here.

If the service publishes a port, the Mac harness needs to know about it, and that
is a larger job than it looks: see "The Mac lane's port
chain" above. The policy test asserts that the exports and per-project container names
exist for the services it knows about, but it cannot tell you that one allocation
forgot to exclude another.

## Reviewing before you apply

Never apply a new service to the NAS without reading the diff first:

```sh
ansible-playbook -i inventory/remote.yml site.yml \
  --tags navidrome --check --diff --ask-vault-pass
```

`--check` asks each module to predict its changes without applying them, and
`--diff` shows the before and after for files. It is a review, not a guarantee:
some external systems cannot be simulated, which is why the role reports planned
API mutations as explicit `debug` tasks under check mode.
