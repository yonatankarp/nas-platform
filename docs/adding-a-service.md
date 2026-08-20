# Adding a service

This guide assumes you can read Python and have never written Ansible. It walks
through adding one service to the platform, using Navidrome as a worked example
that was actually run against this repository's checks.

Read [Ansible concepts used here](ansible-basics.md) first if the words *role*,
*play* and *inventory* are new. This guide is about the mechanics of adding a
service on top of those concepts.

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

You do not need to know Ruby. The tests are written in Ruby, but the only two
Ruby files you will edit contain literal lists of service names, and you will be
copying the line above yours.

## The loop that teaches you the rest

Do not try to memorise the checklist below. Make a change, then run:

```sh
ruby tests/policy_test.rb
```

It accumulates every violation and prints them all at once, in the repository's
own words. The workflow is: declare the service, run the check, fix what it
names, run it again. The checklist in this guide was produced by exactly that
loop, not by reading the test.

### Backing out

A half-added service leaves edits in tracked files and two new directories, so
`git checkout` alone will not clean it up. Both halves, with `navidrome` as the
example:

```sh
git checkout -- services/manifest.yml tests/policy_test.rb \
  tests/policy_manifest_test.rb inventory/group_vars/all/main.yml \
  site.yml verify.yml
rm -rf services/navidrome roles/navidrome
```

Then confirm you are back to a passing baseline with `git status --porcelain`
and `ruby tests/policy_test.rb`. Do this freely; the edit loop is cheap and
nothing outside the repository has changed yet.

## Anatomy of a service

A service with no credentials of its own touches thirteen places. Six are new
files, seven are existing files that gain an entry.

New files:

```
services/<name>/compose.yml
services/<name>/compose.mac.yml       (optional, see below)
roles/<role>/defaults/main.yml
roles/<role>/meta/argument_specs.yml
roles/<role>/templates/env.j2
roles/<role>/tasks/main.yml
```

Existing files that need an entry:

```
services/manifest.yml                  the service and its role
inventory/group_vars/all/main.yml      its directories, under nas_storage
site.yml                               the role, with tags
verify.yml                             the role, with tags: [never]
tests/policy_test.rb                   EXPECTED_SERVICES, EXPECTED_SERVICE_MAPPINGS
tests/policy_manifest_test.rb          EXPECTED_FIXTURE_ROLES
tests/ci/classify_changes.rb           the CI lane that owns it
```

The service name and the role name may differ. Paperless is `paperless-ngx` as a
service and `paperless_ngx` as a role, because directory names use hyphens and
Ansible role names cannot. Keep them identical unless you have that problem.

## Worked example: Navidrome

### 1. Declare it

Add to `services/manifest.yml`:

```yaml
  - name: navidrome
    role: navidrome
    status: implemented
```

Then run `ruby tests/policy_test.rb`:

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

That is the whole remaining task list.

### 2. Register the name in the two Ruby lists

The first two failures come from a pinned list. The comment at the top of
`tests/policy_test.rb` explains why the list is pinned rather than derived:
deriving it from the manifest would let a service silently disappear from the
platform scope without any test noticing.

In `tests/policy_test.rb`, add the name to `EXPECTED_SERVICES` and the mapping to
`EXPECTED_SERVICE_MAPPINGS`:

```ruby
EXPECTED_SERVICES = %w[
  audiobookshelf beszel dozzle immich jellyfin komga navidrome ntfy
  paperless-ngx tinymediamanager
].freeze
```

```ruby
  "navidrome" => { "role" => "navidrome" },
```

There is a second list in `tests/policy_manifest_test.rb`, `EXPECTED_FIXTURE_ROLES`.
It is easy to miss because `policy_test.rb` will pass without it, and
`policy_manifest_test.rb` does not report a policy failure when it is missing.
It raises instead:

```
tests/policy_manifest_test.rb:123:in 'block in Object#fixture_paths':
  unsafe manifest fixture identity (RuntimeError)
```

Add the same pair there.

### 3. Write the Compose definition

`services/navidrome/compose.yml`:

```yaml
---
x-logging: &default-logging
  driver: json-file
  options:
    max-size: 10m
    max-file: "3"

services:
  navidrome:
    container_name: navidrome
    image: docker.io/deluan/navidrome:0.58.0@sha256:2ae037d464de9f802d047165a13b1c9dc2bdbb14920a317ae4aef1233adc0a3c
    labels:
      dev.dozzle.name: navidrome
    user: "1000:100"
    ports:
      - "4533:4533"
    volumes:
      - ${NAVIDROME_DATA_PATH:?}:/data
      - ${NAVIDROME_MUSIC_PATH:?}:/music:ro
    environment:
      TZ: ${TZ:?}
    healthcheck:
      test: [CMD-SHELL, "wget -q -O - http://127.0.0.1:4533/ping | grep -q '\"status\":\"ok\"'"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
    restart: unless-stopped
    logging: *default-logging
```

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
- `restart: unless-stopped`.
- `logging` with the `json-file` driver and both `max-size` and `max-file`.
- Volume sources must be `${VARIABLE:?}` references, never absolute paths. The
  `:?` suffix makes an unset variable fail loudly instead of silently creating a
  relative bind mount. Hardcoding `/volume1/...` is rejected outright, because
  the same file has to run unmodified on the NAS, on a Mac sandbox and in CI.

If you need a platform override, add `services/<name>/compose.mac.yml`. Overrides
may add host-specific wiring such as devices, mounts and per-project container
names, but they **must not contain an `image:` key**. The allowlist of overrides
that may restate an image is exact and currently holds only tinyMediaManager,
which pins a platform out of a multi-platform manifest.

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
`platform_runtime_dir`. The first task re-validates exactly the paths this role
is about to touch.

```yaml
---
- name: Revalidate deployment paths before Navidrome runtime use
  ansible.builtin.include_role:
    name: deployment_bundle
    tasks_from: target
  vars:
    deployment_target_require_current_release: true
    deployment_target_extra_paths:
      - "{{ platform_current_dir }}/services/navidrome"
      - "{{ platform_current_dir }}/services/navidrome/compose.yml"
      - "{{ platform_current_dir }}/services/navidrome/compose.{{ platform_compose_kind }}.yml"
      - "{{ platform_runtime_dir }}/services/navidrome"
      - "{{ platform_runtime_dir }}/services/navidrome/.env"

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
    wait_timeout: 180

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
$ ruby tests/policy_test.rb
policy: all properties hold
```

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
roles/navidrome/... unmapped -> static, foundation, smoke, beszel, dozzle,
                                audiobookshelf, komga, tinymediamanager,
                                jellyfin, immich, paperless, idempotence-check
roles/komga/...     mapped   -> static, smoke, komga, idempotence-check
```

Each service should normally own its own lane. Four files must agree, and three
of them pin the tag list literally:

```
tests/ci/classify_changes.rb        SERVICE_TAGS and SERVICE_NAMES
tests/ci/classify_changes_test.rb   the pinned expected tag string
tests/integration.sh                the fixed_tags for that suite
tests/integration_suite_test.sh     the pinned --describe-suite output
```

A lane needs its name in `LANES` and its integration suite in `SUITES`, both in
`tests/ci/classify_changes.rb`, plus the suite in the
`INTEGRATION_SUITES` list that `tests/ci/workflow_test.rb` pins. The workflow
itself needs no change: the `suites` job is a matrix fed by the `suites` output,
and `validate` covers every leg through one `needs` entry.

## When the service has credentials

Everything above covers a service that proves itself over an unauthenticated
endpoint. A service with its own identity has one absolute rule: **credentials
are authored in vault and flow one direction.** Nothing is ever read back from a
running service, which is what lets a run converge in a single pass. Where a
service would normally hand you a generated value to copy, this platform
supplies its own value instead.

Adding one credential touches:

```
inventory/group_vars/all/vault.yml.example    a sanitized placeholder
roles/vault_contract/meta/argument_specs.yml  {type: str, required: true}
roles/<role>/meta/argument_specs.yml          required: true
tests/policy_test.rb                          EXPECTED_VAULT_KEYS
generate-secrets.yml                          brand-new-platform generation
docs/secrets.md                               enforced by secrets_docs_test.rb
```

The `docs/secrets.md` edit is mandatory, not courtesy. `tests/secrets_docs_test.rb`
checks the guide against the vault contract and fails when they diverge.

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

## The test ladder

Run these in order and stop at the first failure. The times are from a Mac
laptop.

```sh
# seconds
ruby tests/policy_test.rb
ruby tests/policy_manifest_test.rb
ansible-playbook -i inventory/local.yml site.yml --syntax-check
ansible-playbook -i inventory/local.yml verify.yml \
  --tags platform_verify_<name> --list-tasks

# about a minute
ansible-lint --strict

# slow; exceeded ten minutes without completing when this guide was written
tests/validate-policy.sh

# needs Docker; converges a disposable Linux sandbox
tests/integration.sh --suite smoke site.yml
tests/integration.sh --suite <lane> site.yml

# the full lifecycle proof, including idempotence, drift and persistence
tests/mac/run.sh --lane fresh \
  --vault-file /absolute/path/to/vault.yml \
  --vault-password-file /absolute/path/to/password-command
```

`tests/validate-policy.sh` is the gate CI runs, and it runs every check in the
repository including the Ruby, Python and shell unit tests. Run it before
opening a pull request, not during the edit loop.

The integration harness runs Ansible inside a Linux container against a
temporary sandbox, so the plays meet a real `/proc/mounts`, real numeric uid and
gid and a real Docker socket. It asserts three properties: the run converges, a
second identical run changes nothing, and `--check --diff` works. The two worst
bugs found in this repository so far, a fact that exists only on Linux and a
`command` task silently skipped under `--check`, both passed syntax checking and
lint and were caught only here.

If the service publishes a port, the Mac harness needs to know about it.
`tests/mac/run.sh` allocates a free port per service, exports it as
`PLATFORM_<NAME>_PORT`, and isolates each Compose project under a unique project
name. The policy test asserts that those exports and per-project container names
exist for the services it knows about.

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
